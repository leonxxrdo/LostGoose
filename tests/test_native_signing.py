# SPDX-License-Identifier: GPL-3.0-only
"""Check real native packaging and reject broad sandbox entitlements."""
import io
from pathlib import Path
import plistlib
import subprocess
import sys
import tarfile
import tempfile
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from build_test_repo import read_deb
from package_app import inspect_app_deb, APP_PREFIX
ROOT=Path(__file__).resolve().parents[1]
DEB=ROOT/'build/lostgoose-0.3.7/org.lostgoose.app_0.3.7_iphoneos-arm64.deb'
class NativeSigningTests(unittest.TestCase):
    def test_native_profile_added_without_changing_ipa_profile(self):
        inventory,info=inspect_app_deb(DEB)
        base=plistlib.loads((ROOT/'diagnostic/entitlements.plist').read_bytes())
        native=plistlib.loads((ROOT/'diagnostic/entitlements-native.plist').read_bytes())
        self.assertEqual(native,{**base,'jb.pmap_cs.custom_trust':'PMAP_CS_APP_STORE','application-identifier':'org.ioslocationlab.diagnostic','com.apple.private.security.container-required':'org.ioslocationlab.diagnostic','com.apple.security.iokit-user-client-class':['AGXDeviceUserClient','AGXCommandQueue','AGXDevice','AGXSharedUserClient','AGXGLContext','IOSurfaceRootUserClient','IOSurfaceAcceleratorClient']})
        ipa_binary=ROOT/'build/lostgoose-0.3.7/Payload/LocationLabDiagnostic.app/LocationLabDiagnostic'
        self.assertEqual(plistlib.loads(subprocess.check_output([str(ROOT/'.tooling/ldid/ldid'),'-e',str(ipa_binary)])),base)
        self.assertEqual(info['CFBundleIdentifier'],'org.ioslocationlab.diagnostic')
        self.assertEqual(info['CFBundleVersion'],'12')
    def test_package_with_no_sandbox_entitlement_is_rejected(self):
        parts=read_deb(DEB)
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary);executable=folder/'app';bad=folder/'bad.plist'
            native=plistlib.loads((ROOT/'diagnostic/entitlements-native.plist').read_bytes());native['com.apple.private.security.no-sandbox']=True
            bad.write_bytes(plistlib.dumps(native))
            output=io.BytesIO()
            with tarfile.open(fileobj=io.BytesIO(parts['data.tar.gz']),mode='r:gz') as source,tarfile.open(fileobj=output,mode='w:gz') as dest:
                for member in source:
                    data=source.extractfile(member).read() if member.isfile() else None
                    if str(Path(member.name))==APP_PREFIX+'/LocationLabDiagnostic':
                        executable.write_bytes(data)
                        subprocess.run([str(ROOT/'.tooling/ldid/ldid'),'-S'+str(bad),str(executable)],check=True)
                        data=executable.read_bytes();member.size=len(data)
                    dest.addfile(member,io.BytesIO(data) if data is not None else None)
            parts['data.tar.gz']=output.getvalue();archive=b'!<arch>\n'
            for name,data in parts.items():
                archive+=f'{name+"/":<16}{0:<12}{0:<6}{0:<6}{0o100644:<8o}{len(data):<10}`\n'.encode()+data+(b'\n' if len(data)%2 else b'')
            artifact=folder/'bad.deb';artifact.write_bytes(archive)
            with self.assertRaisesRegex(ValueError,'Embedded native entitlements'):
                inspect_app_deb(artifact)
if __name__=='__main__':unittest.main()
