#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build an app release repository and its corresponding source archive."""
import argparse
import bz2
from datetime import datetime, timezone
from email.utils import format_datetime
import hashlib
import html
import json
import lzma
from pathlib import Path
import shutil
import tarfile
from build_test_repo import read_deb
from package_app import inspect_app_deb

ROOT = Path(__file__).resolve().parent.parent
BASE = 'https://repo.leonardx.wtf/'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--deb', type=Path, required=True)
    parser.add_argument('--ipa', type=Path, help='Include a version-matching IPA as an experimental download')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--previous-repo', type=Path, help='Preserve previous public package/source downloads, but index only the current app')
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Use a new output directory; never overwrite a published release')
    _, info = inspect_app_deb(args.deb)
    version = info['CFBundleShortVersionString']
    out = args.output
    shutil.copytree(ROOT / 'build/sileo-repo', out)
    if args.previous_repo:
        for name in ['pool','sources']:
            if (args.previous_repo/name).is_dir():
                shutil.copytree(args.previous_repo/name,out/name,dirs_exist_ok=True)
    shutil.copyfile(args.deb, out / 'pool' / args.deb.name)
    (out / 'sources').mkdir(exist_ok=True)
    source_name = f'LostGoose-{version}-source.tar.xz'
    source_paths = []
    for directory in ['engine', 'diagnostic', 'console', 'tests', 'packaging', 'probes']:
        source_paths.extend(p for p in (ROOT / directory).rglob('*') if p.is_file() and p.suffix in {'.m','.h','.plist','.py'} or p.is_file() and p.parent.name == 'packaging')
    source_paths.extend(ROOT / name for name in ['LICENSE', 'icon.png', 'requirements-build.txt', 'Makefile', 'control', 'docs/BUILD.md', 'assets/repository.jpg'])
    source_paths.extend(ROOT / 'scripts' / name for name in ['build_diagnostic.sh', 'build_app_icons.py', 'build_engine.sh', 'build_sdk_smoke.sh', 'sign_sdk_smoke.sh', 'package_app.py', 'build_test_repo.py', 'verify_test_repo.py', 'build_release_repo.py', 'verify_release_repo.py', 'verify_app_signature.py'])
    archive_prefix = f'LostGoose-{version}'
    with tarfile.open(out / 'sources' / source_name, 'w:xz') as archive:
        for path in sorted(set(source_paths)):
            if path.is_symlink():
                raise ValueError('Source paths must not be symlinks')
            archive.add(path, arcname=archive_prefix + '/' + str(path.relative_to(ROOT)), recursive=False)
        import io
        instructions = f'''# LostGoose {version} corresponding source

GPL-3.0-only; see LICENSE. This archive contains the preferred source for the
published native app, its packaging scripts, user-provided icon and build scripts.
No iOS SDK, proprietary software, credentials or user location logs are included.

Build on Linux with clang/LLVM and ld64.lld 23.1.4, Python 3.14.9, fakeroot and
Pillow 13.0.0 (requirements-build.txt). Details and SDK provenance: docs/BUILD.md.
The compiled executable targets arm64-apple-ios16.0, SDK archive label 16.5
(internal SDK version 16.4). Obtain the SDK under its own applicable terms.

Tool revisions used:
- Theos: 8167f59de02fd32cf45b16bfcb1330dfa5c9974c, https://github.com/theos/theos
- ldid: see the pinned revision and hash in BUILD-TOOLS.json alongside this source.
- SDK URL: https://github.com/theos/sdks/releases/download/master-146e41f/iPhoneOS16.5.sdk.tar.xz
- SDK SHA256: 5e0fd3f01266cce4ce012d4a99b38eb56578fca40d09edc81cd83dee958202fb

Place Theos in .tooling/theos, SDK in .tooling/theos/sdks/iPhoneOS16.5.sdk,
and build ldid to .tooling/ldid/ldid. Then:

    python3 -m pip install -r requirements-build.txt
    ILL_DIAGNOSTIC_OUTPUT_DIR="$PWD/build/lostgoose-{version}" bash scripts/build_diagnostic.sh
    python3 scripts/package_app.py --app build/lostgoose-{version}/Payload/LocationLabDiagnostic.app --output build/lostgoose-{version}/org.lostgoose.app_{version}_iphoneos-arm64.deb --report build/lostgoose-{version}/deb-build.json
    python3 tests/test_app_distribution.py

No command above installs or runs the application on an iPhone. Native .deb
0.3.6 passed a native timed activation/restoration cycle; this new build has not
been device-tested. The exact 0.3.7 IPA has not yet been tested through Lite.
Jailbreak must remain active. Turn OFF before closing, updating or removing.
Do not replace an existing TrollStore Lite installation without backing up data
and planning migration. The preinst script rejects another registered location.

Project: https://github.com/leonxxrdo/LostGoose
Website: https://leonardx.wtf
Support: contact@leonardx.wtf
'''.encode()
        entry = tarfile.TarInfo(archive_prefix + '/README.md'); entry.mode = 0o644; entry.size = len(instructions)
        archive.addfile(entry, io.BytesIO(instructions))
        import subprocess
        tools = {'theos_revision':subprocess.check_output(['git','-C',str(ROOT/'.tooling/theos'),'rev-parse','HEAD'],text=True).strip(),'ldid_revision':subprocess.check_output(['git','-C',str(ROOT/'.tooling/ldid'),'rev-parse','HEAD'],text=True).strip(),'ldid_sha256':hashlib.sha256((ROOT/'.tooling/ldid/ldid').read_bytes()).hexdigest(),'dm_sha256':hashlib.sha256((ROOT/'.tooling/theos/bin/dm.pl').read_bytes()).hexdigest()}
        data=json.dumps(tools,indent=2).encode(); entry=tarfile.TarInfo(archive_prefix+'/BUILD-TOOLS.json');entry.mode=0o644;entry.size=len(data);archive.addfile(entry,io.BytesIO(data))
    if args.ipa:
        import zipfile
        import plistlib
        from verify_app_signature import verify_signature
        with zipfile.ZipFile(args.ipa) as archive:
            prefix = 'Payload/LocationLabDiagnostic.app/'
            resources = {name[len(prefix):]:archive.read(name) for name in archive.namelist() if name.startswith(prefix) and not name.endswith('/')}
        ipa_info = plistlib.loads(resources['Info.plist'])
        if (ipa_info['CFBundleShortVersionString'], ipa_info['CFBundleVersion'], ipa_info['CFBundleIdentifier']) != (version, info['CFBundleVersion'], info['CFBundleIdentifier']):
            raise ValueError('IPA and deb identity/version differ')
        verify_signature(resources[ipa_info['CFBundleExecutable']], resources['Info.plist'], resources['_CodeSignature/CodeResources'], resources)
        (out/'downloads').mkdir(exist_ok=True)
        shutil.copyfile(args.ipa, out/'downloads'/f'LostGoose-{version}.ipa')
        artifacts = [out/'downloads'/f'LostGoose-{version}.ipa', out/'pool'/args.deb.name, out/'sources'/source_name]
        (out/'downloads'/'SHA256SUMS').write_text(''.join(hashlib.sha256(path.read_bytes()).hexdigest()+'  '+path.name+'\n' for path in artifacts))
    index = '' 
    for deb in sorted((out / 'pool').glob('*.deb')):
        members = read_deb(deb)
        import io
        with tarfile.open(fileobj=io.BytesIO(members['control.tar.gz']), mode='r:gz') as archive:
            control = archive.extractfile(next(x for x in archive.getmembers() if x.name.lstrip('./') == 'control')).read().decode()
        blob = deb.read_bytes()
        fields={line.split(':',1)[0]:line.split(':',1)[1].strip() for line in control.splitlines() if ':' in line and not line.startswith(' ')}
        if fields.get('Package')=='org.lostgoose.app' and fields.get('Version')!=version:
            continue
        index += control.rstrip() + '\n' + f'Filename: pool/{deb.name}\nSize: {len(blob)}\n'
        for label, algorithm in [('MD5sum','md5'),('SHA256','sha256'),('SHA512','sha512')]:
            index += f'{label}: {hashlib.new(algorithm,blob).hexdigest()}\n'
        index += '\n'
    raw = index.encode()
    indices = {'Packages':raw,'Packages.bz2':bz2.compress(raw),'Packages.xz':lzma.compress(raw)}
    for name, data in indices.items(): (out / name).write_bytes(data)
    release = 'Origin: Leonardx\nLabel: Leonardx Repository\nSuite: testing\nCodename: ios\nArchitectures: iphoneos-arm64\nComponents: main\nDescription: Rootless packages by Leonardx.\n' + f'Date: {format_datetime(datetime.now(timezone.utc),usegmt=True)}\n'
    for label,algorithm in [('MD5Sum','md5'),('SHA256','sha256'),('SHA512','sha512')]:
        release += label + ':\n'
        for name,data in indices.items():release += f' {hashlib.new(algorithm,data).hexdigest()} {len(data)} {name}\n'
    (out / 'Release').write_text(release)
    # This preview keeps the previously tested unsigned metadata policy.
    for name in ['InRelease','Release.gpg']:
        if (out / name).exists(): (out / name).unlink()
    # Repository identity is independent of the LostGoose application icon.
    from PIL import Image, ImageOps
    for source, prefix in [(ROOT/'assets/repository.jpg', 'CydiaIcon'), (ROOT/'icon.png', 'LostGooseIcon')]:
        with Image.open(source) as image:
            image = ImageOps.exif_transpose(image).convert('RGB')
            for scale in [1, 2, 3]:
                icon = ImageOps.fit(image, (60*scale, 60*scale), method=Image.Resampling.LANCZOS)
                icon.info.clear()
                icon.save(out/(prefix+('' if scale==1 else f'@{scale}x')+'.png'))
    style = '<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><style>body{font:17px system-ui;background:#202124;color:#eee;max-width:720px;margin:6vh auto;padding:24px}a{color:#ffa52f}p,li{line-height:1.65}code{word-break:break-all}img{width:80px;border-radius:18px}</style>'
    migration = '<h1>Switching installation methods</h1><p>Turn OFF and confirm your real location in Apple Maps and an independent reader before changing formats. Back up anything you need; exported diagnostics are not a complete app-data backup.</p><p>IPA and deb share bundle ID <code>org.ioslocationlab.diagnostic</code>. Do not install them side by side. The native installer blocks another registered copy without removing it. Removing the Lite app may delete data; migration has not been validated.</p><p>TrollStore Lite requires the active jailbreak. The exact current IPA is not yet device-tested. Force-quit cleanup is not guaranteed; turn OFF before closing, updating or removing.</p><p><!--email_off--><a href="mailto:contact@leonardx.wtf">Contact support</a><!--/email_off--> · <a href="lostgoose.html">Release details</a></p>'
    (out / '404.html').write_text('<!doctype html><html lang="en"><title>Not found</title><h1>404 · File not found</h1></html>')
    (out / 'migration.html').write_text('<!doctype html><html lang="en"><title>LostGoose migration</title>'+style+migration+'</html>')
    details = f'''<img src="LostGooseIcon@3x.png" alt="LostGoose icon"><h1>LostGoose {html.escape(version)}</h1><p><strong>Experimental release · current IPA device check pending</strong></p><p>Support now uses <!--email_off-->contact@leonardx.wtf<!--/email_off-->. The native signing profile and simulation engine are unchanged from 0.3.6, whose map, diagnostics, controls and one 30-second Tokyo/real-location cycle were confirmed in Apple Maps and Location Witness. This exact new build has not been device-tested.</p><p>Apple MapKit selection, place search that only moves the map, manual coordinates, ON/OFF, a separate 30-second test and English Map, Diagnostics and More tabs.</p><p>Native test environment: iPhone 14 Plus, iOS 17.3.1 (21D61), Dopamine 3.0.12. Other environments are unverified. Minimum build target 16.0 is not a compatibility guarantee. Active compatible jailbreak required. No respring is requested.</p><p>Turn OFF and confirm restoration before closing, updating or uninstalling. Force-quit may leave cleanup pending until LostGoose is reopened.</p><p><a href="migration.html">Read before switching from TrollStore Lite</a></p><p><a href="pool/{args.deb.name}">Download .deb</a> · <a href="sources/{source_name}">Corresponding source (GPL-3.0-only)</a> · <a href="https://github.com/leonxxrdo/LostGoose/releases">IPA releases</a></p><p><a href="https://leonardx.wtf">Website</a> · <a href="https://github.com/leonxxrdo/LostGoose">GitHub</a> · <!--email_off--><a href="mailto:contact@leonardx.wtf">Support</a><!--/email_off--></p>'''
    (out / 'lostgoose.html').write_text('<!doctype html><html lang="en"><title>LostGoose release</title>'+style+details+'</html>')
    (out / 'index.html').write_text('<!doctype html><html lang="en"><title>Leonardx Repository</title>'+style+'<img src="CydiaIcon@3x.png" alt="Leonardx repository icon"><h1>Leonardx Repository</h1><p>Packages by Leonardx. Add <code>https://repo.leonardx.wtf/</code> in Sileo → Sources.</p><p><a href="lostgoose.html">LostGoose '+html.escape(version)+'</a> — fixed-location app, experimental release.</p><p>Before changing installation formats, <a href="migration.html">read the migration notes</a>.</p><p><a href="Packages">Package index</a> · <a href="Release">Metadata</a> · <a href="https://leonardx.wtf">Website</a></p></html>')
    with (out / '_headers').open('a') as file:file.write('\n/sources/*\n  Content-Type: application/octet-stream\n  Cache-Control: public, max-age=31536000, immutable, no-transform\n')
    with (out / '_headers').open('a') as file:file.write('\n/downloads/*\n  Content-Type: application/octet-stream\n  Cache-Control: public, max-age=31536000, immutable, no-transform\n')
    report={'base_url':BASE,'version':version,'source_archive':'sources/'+source_name,'metadata_signed':False,'app_device_validation':False,'files':{str(p.relative_to(out)):{'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':p.stat().st_size} for p in sorted(out.rglob('*')) if p.is_file()}}
    for name, entry in report['files'].items():
        if name.endswith('.html'):
            raw=(out/name).read_bytes()
            if b'<!--email_off-->' in raw:
                stripped=raw.replace(b'<!--email_off-->',b'').replace(b'<!--/email_off-->',b'')
                entry['cloudflare_email_comments_removed']={'bytes':len(stripped),'sha256':hashlib.sha256(stripped).hexdigest()}
    args.report.write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps({'output':str(out),'version':version,'source':report['source_archive'],'files':len(report['files'])}))

if __name__ == '__main__':main()
