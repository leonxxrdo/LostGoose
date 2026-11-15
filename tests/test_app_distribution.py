# SPDX-License-Identifier: GPL-3.0-only
"""Exercise package lifecycle scripts with a fake uicache, never the phone."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

class AppPackageTests(unittest.TestCase):
    def run_script(self, name, action, listing='', fail=False):
        with tempfile.TemporaryDirectory() as directory:
            folder = Path(directory)
            calls = folder / 'calls'
            fake = folder / 'uicache'
            fake.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\nif [ "$1" = -l ]; then printf "%s\\n" "$LISTING"; exit "$LIST_FAIL"; fi\n')
            fake.chmod(0o755)
            script = (ROOT / 'packaging' / name).read_text().replace('PATH=/var/jb/usr/bin:/var/jb/bin:/usr/bin:/bin', 'PATH=' + str(folder) + ':/usr/bin:/bin')
            env = dict(os.environ, CALLS=str(calls), LISTING=listing, LIST_FAIL='1' if fail else '0')
            result = subprocess.run(['/bin/sh', '-c', script, name, action], env=env, capture_output=True, text=True)
            return result, calls.read_text().splitlines() if calls.exists() else []

    def test_first_install_and_native_upgrade_are_allowed(self):
        for listing in ['', 'org.ioslocationlab.diagnostic : /var/jb/Applications/LostGoose.app']:
            result, calls = self.run_script('preinst', 'install', listing)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, ['-l'])

    def test_container_copy_and_unknown_location_are_blocked_without_mutation(self):
        for path in ['/private/var/containers/Bundle/Application/UUID/LocationLabDiagnostic.app', '/another/installation/LostGoose.app']:
            result, calls = self.run_script('preinst', 'install', 'org.ioslocationlab.diagnostic : ' + path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn('protect', result.stderr)
            self.assertEqual(calls, ['-l'])

    def test_enumeration_failure_blocks_installation(self):
        result, calls = self.run_script('preinst', 'install', fail=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, ['-l'])

    def test_registration_and_removal_only_touch_this_bundle(self):
        for script, action, expected in [('postinst', 'configure', ['-p /var/jb/Applications/LostGoose.app']), ('postinst', 'abort-upgrade', []), ('prerm', 'remove', ['-u /var/jb/Applications/LostGoose.app']), ('prerm', 'upgrade', [])]:
            result, calls = self.run_script(script, action)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, expected)

if __name__ == '__main__':
    unittest.main()
