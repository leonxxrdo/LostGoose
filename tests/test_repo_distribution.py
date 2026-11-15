# SPDX-License-Identifier: GPL-3.0-only
import functools
import http.server
import io
from pathlib import Path
import shutil
import sys
import tarfile
import tempfile
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'scripts'))
from verify_test_repo import verify
from build_test_repo import read_deb, validate_canary

ROOT = Path(__file__).resolve().parents[1]

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass

class RepositoryTests(unittest.TestCase):
    def test_valid_http_then_tampered_package_and_html_index(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary) / 'repo'
            shutil.copytree(ROOT / 'build/sileo-repo', folder)
            handler = functools.partial(QuietHandler, directory=str(folder))
            server = http.server.ThreadingHTTPServer(('127.0.0.1', 0), handler)
            thread = threading.Thread(target=server.serve_forever, daemon=True)
            thread.start()
            try:
                base = f'http://127.0.0.1:{server.server_port}/'
                self.assertTrue(verify(base)['canary_payload_verified'])
                package = next((folder / 'pool').glob('*.deb'))
                original = package.read_bytes()
                package.write_bytes(original[:-1] + bytes([original[-1] ^ 1]))
                with self.assertRaisesRegex(ValueError, 'Package checksum'):
                    verify(base)
                package.write_bytes(original)
                (folder / 'Packages').write_text('<html>SPA fallback instead of index</html>')
                with self.assertRaisesRegex(ValueError, 'Release checksum'):
                    verify(base)
            finally:
                server.shutdown(); server.server_close(); thread.join()

    def test_package_scripts_and_traversal_rejected_without_execution(self):
        source = next((ROOT / 'build/sileo-repo/pool').glob('*.deb'))
        original = read_deb(source)
        for name in ['postinst', '../escape']:
            stream = io.BytesIO()
            with tarfile.open(fileobj=stream, mode='w:gz') as archive:
                member = tarfile.TarInfo(name)
                payload = b'not executable; validation fixture only\n'
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
            members = dict(original, **{'control.tar.gz': stream.getvalue()})
            blob = b'!<arch>\n'
            for member_name, payload in members.items():
                header = f'{member_name + "/":<16}{0:<12}{0:<6}{0:<6}{0o100644:<8o}{len(payload):<10}`\n'.encode()
                blob += header + payload + (b'\n' if len(payload) % 2 else b'')
            with tempfile.TemporaryDirectory() as directory:
                fixture = Path(directory) / 'unsafe.deb'
                fixture.write_bytes(blob)
                with self.assertRaises(ValueError):
                    validate_canary(fixture)

if __name__ == '__main__':
    unittest.main()
