#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Publish checksummed public artifacts as a GitHub prerelease using Actions."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.error import HTTPError
from urllib.parse import quote, urlsplit
from urllib.request import Request, urlopen

REPOSITORY = 'leonxxrdo/LostGoose'
API = 'https://api.github.com/repos/' + REPOSITORY


def read_url(url):
    request = Request(url, headers={'User-Agent': 'LostGoose-release-publisher', 'Accept-Encoding': 'identity'})
    with urlopen(request, timeout=90) as response:
        return response.read()


def validate_manifest(manifest):
    if manifest['repository'] != REPOSITORY:
        raise ValueError('Unexpected repository')
    if not re.fullmatch(r'v\d+\.\d+\.\d+', manifest['tag']):
        raise ValueError('Unexpected tag')
    names = set()
    for artifact in manifest['assets']:
        name = artifact['name']
        if not re.fullmatch(r'[A-Za-z0-9_.-]+', name) or name in names:
            raise ValueError('Unsafe or duplicate asset name')
        names.add(name)
        url = urlsplit(artifact['url'])
        if url.scheme != 'https' or url.netloc != 'repo.leonardx.wtf' or url.query or url.fragment:
            raise ValueError('Unexpected artifact origin')
        if not re.fullmatch(r'[0-9a-f]{64}', artifact['sha256']):
            raise ValueError('Invalid SHA256')
    if not names or 'SHA256SUMS' not in names:
        raise ValueError('Missing artifacts/checksums')


def api_request(url, method='GET', payload=None, content_type='application/json', allow_missing=False):
    if urlsplit(url).netloc not in {'api.github.com', 'uploads.github.com'}:
        raise ValueError('Refusing to send GitHub credentials to another host')
    data = json.dumps(payload).encode() if isinstance(payload, dict) else payload
    request = Request(url, data=data, method=method, headers={
        'Authorization': 'Bearer ' + os.environ['GH_TOKEN'],
        'Accept': 'application/vnd.github+json',
        'Content-Type': content_type,
        'User-Agent': 'LostGoose-release-publisher',
    })
    try:
        # API endpoints used here return JSON without redirects.
        with urlopen(request, timeout=120) as response:
            return json.load(response)
    except HTTPError as error:
        if error.code == 404 and allow_missing:
            return None
        raise RuntimeError(f'GitHub {method} failed: HTTP {error.code}') from None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--manifest', type=Path)
    parser.add_argument('--manifest-url')
    parser.add_argument('--commit')
    parser.add_argument('--asset-dir', type=Path)
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    if bool(args.manifest) == bool(args.manifest_url):
        parser.error('Supply one manifest source')
    if args.manifest_url:
        if not args.commit or not re.fullmatch(r'[0-9a-f]{40}', args.commit):
            parser.error('An exact commit SHA is required')
        expected = f'https://raw.githubusercontent.com/{REPOSITORY}/{args.commit}/release/'
        if not args.manifest_url.startswith(expected):
            parser.error('Manifest must come from this exact repository commit')
        manifest = json.loads(read_url(args.manifest_url))
    else:
        manifest = json.loads(args.manifest.read_text())
    validate_manifest(manifest)
    with tempfile.TemporaryDirectory(prefix='lostgoose-release-') as directory:
        folder = Path(directory)
        for artifact in manifest['assets']:
            data = ((args.asset_dir/artifact['name']).read_bytes() if args.asset_dir
                    else read_url(artifact['url']))
            if hashlib.sha256(data).hexdigest() != artifact['sha256']:
                raise ValueError('Artifact SHA256 mismatch: ' + artifact['name'])
            (folder/artifact['name']).write_bytes(data)
        if args.check_only:
            print(json.dumps({'hashes_verified': len(manifest['assets']), 'published': False}))
            return
        if os.environ.get('GITHUB_REPOSITORY') != REPOSITORY:
            parser.error('Publishing is restricted to the expected Actions repository')
        if not args.commit or not re.fullmatch(r'[0-9a-f]{40}', args.commit):
            parser.error('An exact commit SHA is required')
        release = api_request(API+'/releases/tags/'+manifest['tag'], allow_missing=True)
        if release and not release['draft']:
            raise RuntimeError('Release already published; never overwrite an existing release')
        if release is None:
            release = api_request(API+'/releases', 'POST', {
                'tag_name': manifest['tag'], 'target_commitish': args.commit,
                'name': manifest['name'], 'body': manifest['body'],
                'draft': True, 'prerelease': True,
            })
        if release['target_commitish'] != args.commit:
            raise RuntimeError('Existing draft points to a different commit')
        existing = {asset['name']: asset for asset in release['assets']}
        if set(existing) - {asset['name'] for asset in manifest['assets']}:
            raise RuntimeError('Unexpected assets in existing draft')
        for artifact in manifest['assets']:
            name = artifact['name']
            if name in existing:
                if existing[name].get('digest') != 'sha256:'+artifact['sha256']:
                    raise RuntimeError('Existing draft asset differs: '+name)
                continue
            url = release['upload_url'].split('{',1)[0]+'?name='+quote(name)
            result = api_request(url, 'POST', (folder/name).read_bytes(), 'application/octet-stream')
            if result['size'] != (folder/name).stat().st_size:
                raise RuntimeError('Uploaded asset size mismatch: '+name)
            if result.get('digest') and result['digest'] != 'sha256:'+artifact['sha256']:
                raise RuntimeError('Uploaded asset digest mismatch: '+name)
        result = api_request(API+'/releases/'+str(release['id']), 'PATCH', {'draft':False})
        print(json.dumps({'release_url':result['html_url'], 'assets':len(manifest['assets']), 'prerelease':True}))


if __name__ == '__main__':
    main()
