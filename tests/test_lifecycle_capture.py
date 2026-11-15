#!/usr/bin/env python3
"""Regression: an unacknowledged signal must not discard the owner's cleanup report."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


class CaptureTimeoutTest(unittest.TestCase):
    def test_signal_timeout_preserves_cleanup_and_uncertain_delivery(self):
        source = Path(__file__).resolve().parents[1] / 'scripts/capture_lifecycle_case.py'
        spec = importlib.util.spec_from_file_location('lifecycle_capture', source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        original_popen = subprocess.Popen
        replay = '''import json,time
print(json.dumps({'event':'launcher_pid','pid':12345}),flush=True)
print(json.dumps({'action':'start','state':'activation_requested_unverified'}),flush=True)
time.sleep(1.3)
print(json.dumps({'action':'stop','stop_reason':'signal','request_sent':True}),flush=True)
'''
        def run(command, **kwargs):
            if command[-1].startswith('sha256sum '):
                return subprocess.CompletedProcess(command, 0,
                    'a792ded3ae8e0d595565b45e2b25da4f24e6bab94b8f4d4a62d90c8dea0a9695  fake\n', '')
            self.assertEqual(command[-1], 'kill -TERM 12345')
            raise subprocess.TimeoutExpired(command, kwargs['timeout'])
        def popen(command, **kwargs):
            return original_popen([sys.executable, '-u', '-c', replay], **kwargs)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            module.__file__ = str(root / 'scripts/capture_lifecycle_case.py')
            argv = ['capture', '--host', 'unused', '--control', str(root / 'unused'),
                    '--case', 'sigterm', '--fake']
            with patch.object(sys, 'argv', argv), patch.object(module.subprocess, 'run', run), \
                    patch.object(module.subprocess, 'Popen', popen):
                self.assertEqual(module.main(), 1)  # unknown signal acknowledgement stays inconclusive
            folder = root / 'build/lifecycle/sigterm-fake'
            record = json.loads((folder / 'session.json').read_text())
            self.assertTrue(record['signal_result']['timed_out'])
            self.assertFalse(record['signal_sent'])
            self.assertEqual(record['exit_code'], 0)
            self.assertEqual(record['stdout_reports'][-1]['stop_reason'], 'signal')
            self.assertIn('"action": "stop"', (folder / 'stdout.log').read_text())


if __name__ == '__main__':
    unittest.main()
