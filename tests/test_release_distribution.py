# SPDX-License-Identifier: GPL-3.0-only
import functools
import hashlib
import http.server
import json
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import unittest
sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'scripts'))
from verify_release_repo import verify
ROOT=Path(__file__).resolve().parents[1]
class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self,*args): pass
class ReleaseTests(unittest.TestCase):
    def test_full_release_then_changed_corresponding_source_is_rejected(self):
        manifest=json.loads((ROOT/'build/release-repo-0.3.7-manifest.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            folder=Path(temporary)/'repo';shutil.copytree(ROOT/'build/release-repo-0.3.7',folder)
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),functools.partial(QuietHandler,directory=str(folder)))
            thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                base=f'http://127.0.0.1:{server.server_port}/'
                result=verify(base,manifest)
                self.assertEqual(set(result['packages']),{'org.lostgoose.app','org.lostgoose.repository-test'})
                self.assertTrue(result['source_archive_verified'])
                # Permit only an explicitly hashed removal of Cloudflare's
                # control comments, not arbitrary HTML rewriting.
                page=folder/'lostgoose.html';original=page.read_bytes()
                marked=b'<!--email_off-->'+original+b'<!--/email_off-->'
                manifest['files']['lostgoose.html']={'bytes':len(marked),'sha256':hashlib.sha256(marked).hexdigest(),
                    'cloudflare_email_comments_removed':{'bytes':len(original),'sha256':hashlib.sha256(original).hexdigest()}}
                self.assertEqual(verify(base,manifest)['cloudflare_html_email_comments_removed'],['lostgoose.html'])
                page.write_bytes(original+b' unexpected change')
                with self.assertRaisesRegex(ValueError,'Remote/local mismatch: lostgoose.html'):
                    verify(base,manifest)
                page.write_bytes(original)
                (folder/manifest['source_archive']).write_bytes(b'wrong corresponding source archive')
                with self.assertRaisesRegex(ValueError,'Remote/local mismatch'):
                    verify(base,manifest)
            finally:
                server.shutdown();server.server_close();thread.join()
if __name__=='__main__':unittest.main()
