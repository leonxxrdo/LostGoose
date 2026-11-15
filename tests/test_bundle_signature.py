# SPDX-License-Identifier: GPL-3.0-only
import pathlib,sys,unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'scripts'))
from package_app import inspect_app_deb,APP_PREFIX
from verify_app_signature import verify_signature
ROOT=pathlib.Path(__file__).resolve().parents[1]
class BundleSignatureTests(unittest.TestCase):
    def setUp(self):
        self.files,_=inspect_app_deb(ROOT/'build/lostgoose-0.3.7/org.lostgoose.app_0.3.7_iphoneos-arm64.deb')
        self.resources={key[len(APP_PREFIX)+1:]:value for key,value in self.files.items() if key.startswith(APP_PREFIX+'/')}
        self.executable=self.resources['LocationLabDiagnostic'];self.info=self.resources['Info.plist'];self.seal=self.resources['_CodeSignature/CodeResources']
    def test_entire_bundle_identity_pages_and_resources_verify(self):
        result=verify_signature(self.executable,self.info,self.seal,self.resources)
        self.assertEqual(result['identifier'],'org.ioslocationlab.diagnostic')
        self.assertGreaterEqual(result['sealed_resources_verified'],15)
    def test_changed_info_resource_and_code_are_rejected(self):
        with self.assertRaisesRegex(ValueError,'hash mismatch'):
            verify_signature(self.executable,self.info+b'\n',self.seal,self.resources)
        changed=dict(self.resources);changed['Branding.plist']+=b'\n'
        with self.assertRaisesRegex(ValueError,'Sealed resource hash mismatch'):
            verify_signature(self.executable,self.info,self.seal,changed)
        changed_code=bytearray(self.executable);changed_code[4096]^=1
        with self.assertRaisesRegex(ValueError,'code page hash mismatch'):
            verify_signature(bytes(changed_code),self.info,self.seal,self.resources)
if __name__=='__main__':unittest.main()
