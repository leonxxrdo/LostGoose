# SPDX-License-Identifier: GPL-3.0-only
"""Historical 0.3.5 scope-signing experiment; container binding supersedes it."""
# Retained as history; 0.3.6 no longer derives or signs a per-device path.
import json,os
from pathlib import Path
import plistlib,shutil,subprocess,sys,tempfile,unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from package_app import scoped_template,STORAGE_KEY
from verify_app_signature import verify_signature
ROOT=Path(__file__).resolve().parents[1]
UUID='12345678-1234-1234-1234-123456789ABC'
CANONICAL='/private/var/mobile/Containers/Data/Application/'+UUID
@unittest.skip('0.3.5 path exception did not solve the physical storage denial; superseded by explicit container binding')
class ScopedPostinstallTests(unittest.TestCase):
    def run_case(self,container):
        temporary=tempfile.TemporaryDirectory();folder=Path(temporary.name)
        app=folder/'LostGoose.app';shutil.copytree(ROOT/'build/lostgoose-0.3.5/Payload/LocationLabDiagnostic.app',app)
        template=folder/'native-profile.plist.in';base=plistlib.loads((ROOT/'diagnostic/entitlements-native.plist').read_bytes());template.write_bytes(plistlib.dumps(scoped_template(base)))
        commands=folder/'commands';commands.mkdir();calls=folder/'calls'
        (commands/'ldid').symlink_to(ROOT/'.tooling/ldid/ldid')
        cache=commands/'uicache';cache.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\nif [ "$1" = -i ]; then printf "Container Path: %s\\n" "$CONTAINER"; fi\n');cache.chmod(0o755)
        script=(ROOT/'packaging/postinst').read_text().replace('PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin','PATH='+str(commands)+':/usr/bin:/bin').replace('app=/var/jb/Applications/LostGoose.app','app='+str(app)).replace('template=/var/jb/usr/share/doc/org.lostgoose.app/native-profile.plist.in','template='+str(template))
        result=subprocess.run(['/bin/sh','-c',script,'postinst','configure'],capture_output=True,text=True,env=dict(os.environ,CALLS=str(calls),CONTAINER=container))
        signature=plistlib.loads(subprocess.check_output([str(ROOT/'.tooling/ldid/ldid'),'-e',str(app/'LocationLabDiagnostic')]))
        return temporary,app,result,signature,calls.read_text().splitlines()
    def test_scoped_profile_and_full_signature_for_valid_container(self):
        temporary,app,result,signature,calls=self.run_case(CANONICAL)
        try:
            self.assertEqual(result.returncode,0,result.stderr)
            base=plistlib.loads((ROOT/'diagnostic/entitlements-native.plist').read_bytes())
            alias=CANONICAL.removeprefix('/private')
            self.assertEqual(signature,{**base,STORAGE_KEY:[CANONICAL,CANONICAL+'/',alias,alias+'/']})
            self.assertEqual(len(calls),3)
            self.assertTrue(calls[0].startswith('-p '));self.assertEqual(calls[1],'-i org.ioslocationlab.diagnostic');self.assertEqual(calls[2],calls[0])
            resources={str(p.relative_to(app)):p.read_bytes() for p in app.rglob('*') if p.is_file()}
            self.assertTrue(verify_signature(resources['LocationLabDiagnostic'],resources['Info.plist'],resources['_CodeSignature/CodeResources'],resources)['info_plist_hash_verified'])
        finally:temporary.cleanup()
    def test_broad_traversal_and_malformed_paths_are_rejected_before_signing(self):
        for path in ['/','/var/mobile','/private/var/mobile/Containers/Data/Application/../../..',CANONICAL+'-','/private/var/mobile/Containers/Data/Application/$(false)']:
            temporary,app,result,signature,calls=self.run_case(path)
            try:
                self.assertNotEqual(result.returncode,0,path)
                self.assertNotIn(STORAGE_KEY,signature)
                self.assertEqual(len(calls),2)
            finally:temporary.cleanup()
if __name__=='__main__':unittest.main()
