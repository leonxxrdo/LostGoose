#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Verify a staged/published release against the local manifest, read-only."""
import argparse
import bz2
import hashlib
import io
import json
import lzma
from pathlib import Path, PurePosixPath
import tarfile
import tempfile
from urllib.parse import urljoin
from urllib.request import Request, urlopen
from package_app import inspect_app_deb
from build_test_repo import validate_canary


def verify(base, manifest):
    base=base.rstrip('/')+'/'
    blobs={}
    html_comment_transforms=[]
    for name, expected in manifest['files'].items():
        if name == '_headers':continue
        path=PurePosixPath(name)
        if path.is_absolute() or '..' in path.parts:raise ValueError('Unsafe manifest filename')
        request=Request(urljoin(base,name),headers={'User-Agent':'Sileo/2.5','Accept-Encoding':'identity'})
        with urlopen(request,timeout=25) as response:
            if response.status!=200:raise ValueError('HTTP failure: '+name)
            if name in ['Release','Packages','Packages.bz2','Packages.xz'] or name.startswith(('pool/','sources/')):
                if 'text/html' in response.headers.get('Content-Type','').lower():raise ValueError('HTML instead of repository asset')
            blob=response.read(25*1024*1024+1)
        digest=hashlib.sha256(blob).hexdigest()
        if len(blob)!=expected['bytes'] or digest!=expected['sha256']:
            # Cloudflare consumes its email_off comments on custom domains.
            # Accept only the exact independently recorded HTML variant; never
            # normalize or relax checks on APT metadata, packages or sources.
            variant=expected.get('cloudflare_email_comments_removed') if name.endswith('.html') else None
            if not variant or len(blob)!=variant['bytes'] or digest!=variant['sha256']:
                raise ValueError('Remote/local mismatch: '+name)
            html_comment_transforms.append(name)
        blobs[name]=blob
    if bz2.decompress(blobs['Packages.bz2'])!=blobs['Packages'] or lzma.decompress(blobs['Packages.xz'])!=blobs['Packages']:raise ValueError('Compressed indices disagree')
    sha=False
    for line in blobs['Release'].decode().splitlines():
        if not line.startswith(' '):sha=line=='SHA256:'
        elif sha:
            digest,size,name=line.split()
            if hashlib.sha256(blobs[name]).hexdigest()!=digest or len(blobs[name])!=int(size):raise ValueError('Release hashes disagree')
    packages=[]
    with tempfile.TemporaryDirectory() as directory:
        for stanza in blobs['Packages'].decode().strip().split('\n\n'):
            fields={}
            for line in stanza.splitlines():
                if line.startswith(' '):continue
                key,value=line.split(':',1);fields[key]=value.strip()
            blob=blobs[fields['Filename']]
            if len(blob)!=int(fields['Size']) or hashlib.sha256(blob).hexdigest()!=fields['SHA256']:raise ValueError('Package index disagrees')
            path=Path(directory)/'package.deb';path.write_bytes(blob)
            if fields['Package']=='org.lostgoose.app':inspect_app_deb(path)
            elif fields['Package']=='org.lostgoose.repository-test':validate_canary(path)
            else:raise ValueError('Unexpected package')
            packages.append(fields['Package'])
    with tarfile.open(fileobj=io.BytesIO(blobs[manifest['source_archive']]),mode='r:xz') as archive:
        names=set()
        for item in archive:
            path=PurePosixPath(item.name)
            if path.is_absolute() or '..' in path.parts or not item.isfile():raise ValueError('Unsafe source archive')
            names.add(str(path))
        prefix='LostGoose-'+manifest['version']+'/'
        for name in ['LICENSE','README.md','BUILD-TOOLS.json','diagnostic/LGMoreController.m','packaging/preinst','scripts/build_diagnostic.sh']:
            if prefix+name not in names:raise ValueError('Missing corresponding source: '+name)
    return {'base_url':base,'files_checked':len(blobs),'all_files_match_local_manifest':True,'cloudflare_html_email_comments_removed':html_comment_transforms,'release_and_package_hashes_verified':True,'packages':packages,'source_archive_verified':True,'package_scripts_executed':False,'physical_app_validation':False}

if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('url');parser.add_argument('--manifest',type=Path,required=True);parser.add_argument('--report',type=Path,required=True);args=parser.parse_args()
    result=verify(args.url,json.loads(args.manifest.read_text()));args.report.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result))
