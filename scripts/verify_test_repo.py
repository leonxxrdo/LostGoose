#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify HTTP bytes, Release hashes and the harmless Sileo test package."""
import argparse
import bz2
import hashlib
import json
import lzma
from pathlib import Path, PurePosixPath
import tempfile
from urllib.parse import urljoin, urlsplit
from urllib.request import Request, urlopen
from build_test_repo import PACKAGE, ARCH, validate_canary


def verify(base):
    base = base.rstrip('/') + '/'
    def fetch(name):
        request = Request(urljoin(base, name), headers={'User-Agent': 'LostGooseRepoCheck/1.0', 'Accept-Encoding': 'identity'})
        with urlopen(request, timeout=20) as response:
            if response.status != 200 or 'text/html' in response.headers.get('Content-Type', '').lower():
                raise ValueError('Repository file returned HTML or non-200: ' + name)
            if response.headers.get('Content-Encoding', 'identity') != 'identity':
                raise ValueError('Unexpected HTTP content encoding: ' + name)
            data = response.read(32 * 1024 * 1024 + 1)
            if len(data) > 32 * 1024 * 1024:
                raise ValueError('Test repository file exceeds limit')
            return data
    release = fetch('Release').decode('utf-8')
    hashes = {}
    in_sha = False
    for line in release.splitlines():
        if not line.startswith(' '):
            in_sha = line == 'SHA256:'
        elif in_sha:
            digest, size, name = line.split()
            hashes[name] = (digest, int(size))
    needed = ['Packages', 'Packages.bz2', 'Packages.xz']
    if not all(name in hashes for name in needed):
        raise ValueError('Release lacks expected SHA256 records')
    content = {}
    for name in needed:
        blob = fetch(name)
        if (hashlib.sha256(blob).hexdigest(), len(blob)) != hashes[name]:
            raise ValueError('Release checksum/size mismatch: ' + name)
        content[name] = blob
    if bz2.decompress(content['Packages.bz2']) != content['Packages'] or lzma.decompress(content['Packages.xz']) != content['Packages']:
        raise ValueError('Compressed indices differ from Packages')
    fields = {}
    for line in content['Packages'].decode('utf-8').strip().splitlines():
        key, value = line.split(':', 1)
        if key in fields:
            raise ValueError('Duplicate package field')
        fields[key] = value.strip()
    if fields.get('Package') != PACKAGE or fields.get('Architecture') != ARCH:
        raise ValueError('Unexpected package or architecture')
    filename = fields['Filename']
    path = PurePosixPath(filename)
    if path.is_absolute() or '..' in path.parts or urlsplit(filename).scheme or urlsplit(filename).netloc or not filename.startswith('pool/'):
        raise ValueError('Unsafe package filename')
    package = fetch(filename)
    if len(package) != int(fields['Size']) or hashlib.sha256(package).hexdigest() != fields['SHA256']:
        raise ValueError('Package checksum/size mismatch')
    with tempfile.TemporaryDirectory(prefix='lostgoose-repo-check-') as directory:
        artifact = Path(directory) / 'test.deb'
        artifact.write_bytes(package)
        inventory = validate_canary(artifact)
    return {'base_url': base, 'http_checks_passed': True, 'release_sha256_checks_passed': True,
            'compressed_indices_match': True, 'package_sha256': fields['SHA256'],
            'package': fields['Package'], 'version': fields['Version'], 'architecture': fields['Architecture'],
            'canary_payload_verified': True, 'package_scripts_executed': False,
            'payload_files': [p for p in inventory if p != 'control']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('url')
    parser.add_argument('--report', type=Path)
    args = parser.parse_args()
    result = verify(args.url)
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
