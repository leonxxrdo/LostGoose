#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Package the signed app for rootless without installing or executing it."""
import argparse
import hashlib
import io
import json
from pathlib import Path, PurePosixPath
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
from build_test_repo import read_deb
from verify_app_signature import verify_signature

ROOT = Path(__file__).resolve().parent.parent
PACKAGE = 'org.lostgoose.app'
APP_PREFIX = 'var/jb/Applications/LostGoose.app'
SCRIPTS = {'preinst', 'postinst', 'prerm'}
STORAGE_KEY='com.apple.security.exception.files.absolute-path.read-write'

def scoped_template(base):
    return {**base,STORAGE_KEY:['@LOSTGOOSE_DATA_CONTAINER@','@LOSTGOOSE_DATA_CONTAINER@/',
                              '@LOSTGOOSE_DATA_CONTAINER_ALIAS@','@LOSTGOOSE_DATA_CONTAINER_ALIAS@/']}


def inspect_app_deb(path):
    members = read_deb(path)
    if set(members) != {'debian-binary', 'control.tar.gz', 'data.tar.gz'}:
        raise ValueError('Unexpected deb archive members')
    inventory = {}
    for name in ('control.tar.gz', 'data.tar.gz'):
        with tarfile.open(fileobj=io.BytesIO(members[name]), mode='r:gz') as archive:
            for item in archive:
                relative = str(PurePosixPath(item.name))
                if PurePosixPath(relative).is_absolute() or '..' in PurePosixPath(relative).parts or not (item.isdir() or item.isfile()):
                    raise ValueError('Unsafe path or link')
                if item.uid or item.gid:
                    raise ValueError('Expected numeric root ownership')
                if item.isdir():
                    continue
                if name == 'control.tar.gz':
                    if relative not in SCRIPTS | {'control'}:
                        raise ValueError('Unexpected control file')
                    if relative in SCRIPTS and archive.extractfile(item).read() != (ROOT / 'packaging' / relative).read_bytes():
                        raise ValueError('Maintainer script differs from reviewed source')
                    if relative in SCRIPTS and item.mode & 0o777 != 0o755:
                        raise ValueError('Maintainer script permissions')
                else:
                    if not relative.startswith(APP_PREFIX + '/') and not relative.startswith('var/jb/usr/share/doc/' + PACKAGE + '/'):
                        raise ValueError('Payload outside app or documentation')
                    expected_mode = 0o755 if relative == APP_PREFIX + '/LocationLabDiagnostic' else 0o644
                    if item.mode & 0o7777 != expected_mode:
                        raise ValueError('Unexpected payload permissions: ' + relative)
                inventory[relative] = archive.extractfile(item).read()
    for script in SCRIPTS:
        if script not in inventory:
            raise ValueError('Missing maintainer script')
    info = plistlib.loads(inventory[APP_PREFIX + '/Info.plist'])
    if info['CFBundleIdentifier'] != 'org.ioslocationlab.diagnostic' or info['CFBundleLocalizations'] != ['en']:
        raise ValueError('Unexpected bundle identity/language')
    if not inventory[APP_PREFIX + '/LocationLabDiagnostic'].startswith(b'\xcf\xfa\xed\xfe'):
        raise ValueError('Expected thin arm64 Mach-O')
    # Keep the original 0.3.1 profile readable when verifying preserved assets.
    version=info['CFBundleShortVersionString']
    if version in {'0.3.1','0.3.2','0.3.3'}:
        expected=plistlib.loads((ROOT/'diagnostic/entitlements.plist').read_bytes())
        if version!='0.3.1':expected['jb.pmap_cs.custom_trust']='PMAP_CS_APP_STORE'
    else:
        expected=plistlib.loads((ROOT/'diagnostic/entitlements-native.plist').read_bytes())
        if version in {'0.3.4','0.3.5'}:
            expected.pop('com.apple.private.security.container-required',None)
    with tempfile.TemporaryDirectory(prefix='lostgoose-signature-check-') as temporary:
        executable=Path(temporary)/'app';executable.write_bytes(inventory[APP_PREFIX+'/LocationLabDiagnostic'])
        actual=plistlib.loads(subprocess.check_output([str(ROOT/'.tooling/ldid/ldid'),'-e',str(executable)]))
    if actual != expected:
        raise ValueError('Embedded native entitlements differ from the approved profile')
    if info['CFBundleShortVersionString']=='0.3.5':
        template=plistlib.loads(inventory['var/jb/usr/share/doc/'+PACKAGE+'/native-profile.plist.in'])
        if template!=scoped_template(expected):raise ValueError('Unsafe native storage template')
    if info['CFBundleShortVersionString'] not in {'0.3.1','0.3.2'}:
        verify_signature(inventory[APP_PREFIX+'/LocationLabDiagnostic'],inventory[APP_PREFIX+'/Info.plist'],
                         inventory[APP_PREFIX+'/_CodeSignature/CodeResources'],
                         {key[len(APP_PREFIX)+1:]:value for key,value in inventory.items() if key.startswith(APP_PREFIX+'/')})
    return inventory, info


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error('Refusing to overwrite an existing package')
    info = plistlib.loads((args.app / 'Info.plist').read_bytes())
    version = info['CFBundleShortVersionString']
    entitlements = plistlib.loads(subprocess.check_output([str(ROOT / '.tooling/ldid/ldid'), '-e', str(args.app / info['CFBundleExecutable'])]))
    if entitlements != plistlib.loads((ROOT / 'diagnostic/entitlements.plist').read_bytes()):
        parser.error('App entitlements differ from the approved engine entitlements')
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='lostgoose-app-deb-') as temporary:
        stage = Path(temporary)
        app = stage / APP_PREFIX
        shutil.copytree(args.app, app)
        native_profile=ROOT/'diagnostic/entitlements-native.plist'
        subprocess.run([str(ROOT/'.tooling/ldid/ldid'),'-S'+str(native_profile),str(app)],check=True)
        native_entitlements=plistlib.loads(subprocess.check_output([str(ROOT/'.tooling/ldid/ldid'),'-e',str(app/info['CFBundleExecutable'])]))
        if native_entitlements != plistlib.loads(native_profile.read_bytes()):
            raise ValueError('Native signing failed')
        signature_check=verify_signature((app/info['CFBundleExecutable']).read_bytes(),(app/'Info.plist').read_bytes(),
                                         (app/'_CodeSignature/CodeResources').read_bytes(),
                                         {str(p.relative_to(app)):p.read_bytes() for p in app.rglob('*') if p.is_file()})
        doc = stage / 'var/jb/usr/share/doc' / PACKAGE
        doc.mkdir(parents=True)
        shutil.copyfile(ROOT / 'LICENSE', doc / 'copyright')
        (doc / 'README').write_text('LostGoose ' + version + '\nExperimental native rootless package; device validation pending.\nActive jailbreak required. Turn OFF before closing, updating or removing.\nTrollStore Lite migration: https://repo.leonardx.wtf/migration.html\nCorresponding source: https://repo.leonardx.wtf/sources/LostGoose-' + version + '-source.tar.xz\n')
        control = stage / 'DEBIAN'
        control.mkdir()
        size = (sum(p.stat().st_size for p in stage.rglob('*') if p.is_file()) + 1023) // 1024
        (control / 'control').write_text(f'Package: {PACKAGE}\nName: LostGoose\nVersion: {version}\nArchitecture: iphoneos-arm64\nMaintainer: leonxxrdo <contact@leonardx.wtf>\nAuthor: leonxxrdo\nSection: Utilities\nPriority: optional\nDepends: firmware (>= 16.0)\nPre-Depends: uikittools (>= 2.1)\nInstalled-Size: {size}\nDescription: Experimental fixed-location app for an active rootless jailbreak.\n Native deb validation pending. Turn OFF before closing or uninstalling.\nHomepage: https://leonardx.wtf\nIcon: https://repo.leonardx.wtf/LostGooseIcon@2x.png\nDepiction: https://repo.leonardx.wtf/lostgoose.html\n')
        for script in SCRIPTS:
            shutil.copyfile(ROOT / 'packaging' / script, control / script)
        for path in [stage, *stage.rglob('*')]:
            if path.is_symlink():
                raise ValueError('Symlinks not allowed')
            path.chmod(0o755 if path.is_dir() or path.name in SCRIPTS or path == app / info['CFBundleExecutable'] else 0o644)
        wrapper = '''import os,pathlib,subprocess,sys
stage=pathlib.Path(sys.argv[1])
for path in [stage,*stage.rglob('*')]: os.chown(path,0,0)
subprocess.run(sys.argv[2:],check=True)
'''
        subprocess.run(['fakeroot', '--', 'python3', '-c', wrapper, str(stage), 'perl', str(ROOT / '.tooling/theos/bin/dm.pl'), '-Zgzip', '-b', str(stage), str(args.output.resolve())], check=True, capture_output=True)
    inventory, checked = inspect_app_deb(args.output)
    result = {'package': PACKAGE, 'version': version, 'build': checked['CFBundleVersion'], 'architecture': 'iphoneos-arm64', 'bundle_identifier': checked['CFBundleIdentifier'], 'app_path': '/' + APP_PREFIX, 'deb_sha256': hashlib.sha256(args.output.read_bytes()).hexdigest(), 'files': {k: hashlib.sha256(v).hexdigest() for k,v in inventory.items()}, 'entitlements': native_entitlements, 'input_ipa_entitlements':entitlements,'physical_native_deb_validation': False, 'installed_on_device_by_tools': False, 'tooling': {'theos_revision': subprocess.check_output(['git', '-C', str(ROOT / '.tooling/theos'), 'rev-parse', 'HEAD'],text=True).strip(), 'dm_sha256':hashlib.sha256((ROOT / '.tooling/theos/bin/dm.pl').read_bytes()).hexdigest()}}
    args.report.parent.mkdir(parents=True,exist_ok=True)
    result['bundle_signature']=signature_check
    result['postinstall_scoped_storage_signing']=False
    result['storage_scope']='Explicit container-required binding to own bundle; no filesystem path exceptions'
    args.report.write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps({k:result[k] for k in ['package','version','deb_sha256','physical_native_deb_validation']}))

if __name__ == '__main__':
    main()
