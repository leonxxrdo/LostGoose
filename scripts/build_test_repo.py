#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build a static Sileo connectivity-test repo, without distributing the app."""
import argparse
import bz2
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import html
import io
import json
import lzma
from pathlib import Path, PurePosixPath
import subprocess
import tarfile
import tempfile
from urllib.parse import urlsplit

PACKAGE = 'org.lostgoose.repository-test'
VERSION = '0.0.1'
ARCH = 'iphoneos-arm64'
ROOT = Path(__file__).resolve().parent.parent


def read_deb(path):
    data = Path(path).read_bytes()
    if data[:8] != b'!<arch>\n':
        raise ValueError('Not a Debian ar archive')
    members = {}
    offset = 8
    while offset < len(data):
        header = data[offset:offset + 60]
        if len(header) != 60 or header[58:60] != b'`\n':
            raise ValueError('Invalid ar header')
        name = header[:16].decode('ascii').strip().rstrip('/')
        size = int(header[48:58])
        body = data[offset + 60:offset + 60 + size]
        if len(body) != size or name in members:
            raise ValueError('Truncated or duplicate ar member')
        members[name] = body
        offset += 60 + size + size % 2
    if members.get('debian-binary') != b'2.0\n':
        raise ValueError('Unsupported Debian package version')
    return members


def validate_canary(path):
    members = read_deb(path)
    if set(members) != {'debian-binary', 'control.tar.gz', 'data.tar.gz'}:
        raise ValueError('Unexpected package archive members')
    inventory = {}
    for archive in ['control.tar.gz', 'data.tar.gz']:
        with tarfile.open(fileobj=io.BytesIO(members[archive]), mode='r:gz') as tar:
            for member in tar:
                name = PurePosixPath(member.name)
                if name.is_absolute() or '..' in name.parts or not (member.isdir() or member.isfile()):
                    raise ValueError('Unsafe package path or link')
                if member.uid != 0 or member.gid != 0:
                    raise ValueError('Expected root ownership')
                if member.isfile():
                    relative = str(name)
                    if archive == 'control.tar.gz' and relative != 'control':
                        raise ValueError('Test package must have no maintainer scripts')
                    if archive == 'data.tar.gz' and relative != f'var/jb/usr/share/doc/{PACKAGE}/README.txt':
                        raise ValueError('Unexpected installed file')
                    if archive == 'data.tar.gz' and member.mode & 0o111:
                        raise ValueError('Test payload must not be executable')
                    inventory[relative] = tar.extractfile(member).read().decode('utf-8')
    if set(inventory) != {'control', f'var/jb/usr/share/doc/{PACKAGE}/README.txt'}:
        raise ValueError('Incomplete test package')
    return inventory


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base-url', default='https://repo.leonardx.wtf/')
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--report', required=True, type=Path)
    parser.add_argument('--signing-key', help='Existing GPG key fingerprint; no private keys are generated or copied')
    args = parser.parse_args()
    url = urlsplit(args.base_url)
    if url.scheme not in ('https', 'http') or not url.netloc or url.query or url.fragment or url.username or url.password:
        parser.error('Expected a plain public repository base URL')
    base = args.base_url.rstrip('/') + '/'
    output = args.output.resolve()
    if output.exists() and any(output.iterdir()):
        parser.error('Use a new empty output directory; never overwrite the live website')
    output.mkdir(parents=True, exist_ok=True)
    (output / 'pool').mkdir()
    control = (f'Package: {PACKAGE}\nName: LostGoose Repo Test\nVersion: {VERSION}\n'
               f'Architecture: {ARCH}\nMaintainer: LostGoose contributors\nSection: Development\n'
               'Priority: optional\nDepends: firmware (>= 16.0)\n'
               'Description: Text-only package to test the LostGoose Sileo repository.\n'
               f'Homepage: {base}\nIcon: {base}CydiaIcon@2x.png\nInstalled-Size: 1\n')
    filename = f'pool/{PACKAGE}_{VERSION}_{ARCH}.deb'
    package = output / filename
    with tempfile.TemporaryDirectory(prefix='lostgoose-repo-') as directory:
        stage = Path(directory)
        (stage / 'DEBIAN').mkdir()
        (stage / 'DEBIAN/control').write_text(control)
        doc = stage / f'var/jb/usr/share/doc/{PACKAGE}/README.txt'
        doc.parent.mkdir(parents=True)
        doc.write_text('LostGoose repository connectivity test\n\n'
                       'This package contains only this text file.\n'
                       'It does not install the LostGoose app, run scripts, or change location.\n'
                       'Remove it from Sileo when the installation test is complete.\n')
        # dm.pl follows numeric ownership when under fakeroot. Normalize the
        # staged files there, without requiring or changing real root ownership.
        wrapper = '''import os, pathlib, subprocess, sys
stage = pathlib.Path(sys.argv[1])
for path in [stage, *stage.rglob('*')]:
    os.chown(path, 0, 0)
subprocess.run(sys.argv[2:], check=True)
'''
        subprocess.run(['fakeroot', '--', 'python3', '-c', wrapper, str(stage), 'perl',
                        str(ROOT / '.tooling/theos/bin/dm.pl'), '-Zgzip', '-b', str(stage), str(package)],
                       check=True, capture_output=True)
    inventory = validate_canary(package)
    blob = package.read_bytes()
    index = control + f'Filename: {filename}\nSize: {len(blob)}\n'
    for key, algorithm in [('MD5sum', 'md5'), ('SHA256', 'sha256'), ('SHA512', 'sha512')]:
        index += f'{key}: {hashlib.new(algorithm, blob).hexdigest()}\n'
    index += '\n'
    raw = index.encode()
    indices = {'Packages': raw, 'Packages.bz2': bz2.compress(raw), 'Packages.xz': lzma.compress(raw)}
    for name, content in indices.items():
        (output / name).write_bytes(content)
    release = ('Origin: LostGoose\nLabel: LostGoose Test Repository\nSuite: testing\nCodename: ios\n'
               f'Architectures: {ARCH}\nComponents: main\nVersion: 1\n'
               'Description: Connectivity testing only; the LostGoose app is not included.\n'
               f'Date: {format_datetime(datetime.now(timezone.utc), usegmt=True)}\n')
    for label, algorithm in [('MD5Sum', 'md5'), ('SHA256', 'sha256'), ('SHA512', 'sha512')]:
        release += label + ':\n'
        for name, content in indices.items():
            release += f' {hashlib.new(algorithm, content).hexdigest()} {len(content)} {name}\n'
    (output / 'Release').write_text(release)
    if args.signing_key:
        subprocess.run(['gpg', '--batch', '--yes', '--armor', '--local-user', args.signing_key,
                        '--detach-sign', '--output', str(output / 'Release.gpg'), str(output / 'Release')], check=True)
        subprocess.run(['gpg', '--batch', '--yes', '--armor', '--local-user', args.signing_key,
                        '--clearsign', '--output', str(output / 'InRelease'), str(output / 'Release')], check=True)
    from PIL import Image, __version__ as pillow_version
    if pillow_version != '13.0.0':
        parser.error('Install the Pillow version pinned in requirements-build.txt')
    with Image.open(ROOT / 'icon.png') as image:
        for scale in (1, 2, 3):
            name = 'CydiaIcon' + ('' if scale == 1 else f'@{scale}x') + '.png'
            image.convert('RGB').resize((32 * scale, 32 * scale), Image.Resampling.LANCZOS).save(output / name)
    escaped = html.escape(base, quote=True)
    (output / 'index.html').write_text(f'''<!doctype html><html lang="es"><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>LostGoose · Repositorio de prueba</title>
<style>body{{font:17px system-ui;background:#202124;color:#eee;max-width:660px;margin:8vh auto;padding:24px}}img{{width:80px;border-radius:18px}}a{{color:#ffa52f}}code{{word-break:break-all}}h1{{font-size:32px}}p,li{{line-height:1.65}}.tag{{color:#ffa52f}}</style>
<img src="CydiaIcon@3x.png" alt="Icono de LostGoose"><p class="tag">REPOSITORIO DE PRUEBA</p><h1>LostGoose</h1>
<p>Dirección del repositorio: <code>{escaped}</code></p>
<ol><li>En Sileo abre Fuentes y añade esta dirección.</li><li>Busca <strong>LostGoose Repo Test</strong> e instala el paquete.</li><li>Comprueba que aparece instalado y elimínalo cuando termines.</li></ol>
<p>El paquete solo instala un archivo de texto. No contiene la app LostGoose, ejecutables, scripts ni un motor de ubicación.</p>
<p>La distribución de LostGoose como IPA y como aplicación nativa .deb se valida por separado. Este repositorio no anuncia compatibilidad adicional.</p>
<p><a href="Packages">Índice de paquetes</a> · <a href="Release">Metadatos</a></p></html>''')
    (output / '404.html').write_text('<!doctype html><title>No encontrado</title><h1>404 · Archivo no encontrado</h1>')
    rules = []
    for route in ['/Packages', '/Packages.bz2', '/Packages.xz', '/Release', '/Release.gpg', '/InRelease', '/pool/*']:
        rules.append(route + '\n  Content-Type: application/octet-stream\n  Cache-Control: public, max-age=60, no-transform\n')
    (output / '_headers').write_text('\n'.join(rules))
    report = {'base_url': base, 'output': str(output), 'package': PACKAGE, 'package_version': VERSION,
              'package_architecture': ARCH, 'package_sha256': hashlib.sha256(blob).hexdigest(),
              'installed_payload_files': [name for name in inventory if name != 'control'],
              'maintainer_scripts': False, 'executable_payload': False, 'lostgoose_app_included': False,
              'metadata_signed': bool(args.signing_key), 'theos_dm_sha256': hashlib.sha256((ROOT / '.tooling/theos/bin/dm.pl').read_bytes()).hexdigest(),
              'pillow_version': pillow_version,
              'files': {str(p.relative_to(output)): {'bytes': p.stat().st_size, 'sha256': hashlib.sha256(p.read_bytes()).hexdigest()} for p in sorted(output.rglob('*')) if p.is_file()}}
    args.report.parent.mkdir(parents=True, exist_ok=True)
    args.report.write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps({'output': str(output), 'package': PACKAGE, 'package_sha256': report['package_sha256'], 'app_included': False}))


if __name__ == '__main__':
    main()
