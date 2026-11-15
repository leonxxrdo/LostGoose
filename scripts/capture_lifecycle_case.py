#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""One agreed lifecycle session; never infers location from backend reports.

sigterm sends TERM to the exact PID returned by our exec launcher, 20 seconds
after its start report (lease 30 seconds). screen-lock leaves the lease intact.
The fake mode uses the separate fake binary/namespace for verifying the runner.
"""
import argparse
import datetime
import hashlib
import json
import os
from pathlib import Path
import selectors
import shlex
import subprocess
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', required=True)
    parser.add_argument('--control', required=True, type=Path)
    parser.add_argument('--case', required=True, choices=['sigterm', 'screen-lock', 'relaunch'])
    parser.add_argument('--fake', action='store_true')
    parser.add_argument('--attempt', type=int, choices=range(1, 11), default=1)
    parser.add_argument('--manual-signal', action='store_true',
                        help='SIGTERM only: wait for send-term file after observer sees Tokyo (60 s lease)')
    args = parser.parse_args()
    if args.manual_signal and args.case != 'sigterm':
        parser.error('--manual-signal requires --case sigterm')
    root = Path(__file__).resolve().parent.parent
    name = 'console-fake' if args.fake else 'location-lab'
    binary = '/var/mobile/Library/Caches/ios-location-lab/engine-v2-timing/' + name
    expected = ('a792ded3ae8e0d595565b45e2b25da4f24e6bab94b8f4d4a62d90c8dea0a9695' if args.fake
                else 'd6898cd4af13979221e14822f83f0b2c558b8c7b44a01ff11fa0c88f0fa4bddf')
    ssh = ['ssh', '-T', '-S', str(args.control.resolve()), '-o', 'BatchMode=yes',
           '-o', 'UserKnownHostsFile=' + str(root / '.tooling/ssh/known_hosts'),
           '-o', 'StrictHostKeyChecking=yes', '-o', 'ConnectTimeout=5', 'mobile@' + args.host]
    digest = subprocess.run(ssh + ['sha256sum ' + binary], capture_output=True, text=True,
                            check=True, timeout=15).stdout.split()[0]
    if digest != expected:
        raise SystemExit('Unexpected executable hash; no simulation requested')
    os.umask(0o077)
    label = args.case + ('-fake' if args.fake else '')
    if args.attempt != 1:
        label += f'-attempt-{args.attempt:02}'
    folder = root / 'build/lifecycle' / label
    folder.mkdir(parents=True, exist_ok=False)
    utc = lambda: datetime.datetime.now(datetime.timezone.utc).isoformat()
    duration = (10 if args.fake else 60) if args.manual_signal else (5 if args.fake else 30)
    signal_after = 1 if args.fake else 20
    record = {'case': args.case, 'attempt': args.attempt, 'manual_signal': args.manual_signal,
              'fake_only': args.fake, 'started_utc': utc(),
              'requested_lease_seconds': duration, 'engine_sha256_verified': digest,
              'observed_activation': None, 'observed_restoration': None,
              'target': {'latitude': 35.68126, 'longitude': 139.76671},
              'signal_sent': False, 'stdout_reports': []}
    save = lambda: (folder / 'session.json').write_text(json.dumps(record, indent=2) + '\n')
    save()
    # exec keeps this shell's PID for the exact application being tested.
    launcher = 'printf \'{"event":"launcher_pid","pid":%d}\\n\' "$$"\nexec ' + shlex.join([
        'env', '_MSSafeMode=1', '_SafeMode=1', binary, 'run', '35.68126', '139.76671',
        '--seconds', str(duration)])
    command = ssh + [shlex.join(['/var/jb/bin/sh', '-c', launcher])]
    began = time.monotonic()
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    selector = selectors.DefaultSelector()
    for stream, label in [(process.stdout, 'stdout'), (process.stderr, 'stderr')]:
        selector.register(stream, selectors.EVENT_READ, label)
    due, pid, stopped = None, None, False
    pending = b''
    with (folder / 'stdout.log').open('wb') as out, (folder / 'stderr.log').open('wb') as err, \
            (folder / 'arrivals.jsonl').open('w') as arrivals:
        logs = {'stdout': out, 'stderr': err}
        while selector.get_map():
            for key, _ in selector.select(timeout=0.1):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                logs[key.data].write(chunk); logs[key.data].flush()
                arrivals.write(json.dumps({'stream': key.data, 'received_utc': utc(),
                    'host_elapsed_seconds': time.monotonic() - began, 'bytes': len(chunk)}) + '\n')
                arrivals.flush()
                if key.data == 'stdout':
                    pending += chunk
                    while b'\n' in pending:
                        line, pending = pending.split(b'\n', 1)
                        event = json.loads(line)
                        record['stdout_reports'].append(event)
                        if event.get('event') == 'launcher_pid':
                            pid = event['pid']
                            if not isinstance(pid, int) or pid <= 1:
                                raise RuntimeError('Invalid launcher PID')
                        if event.get('action') == 'start':
                            print('START_REPORT: ' + event['state'], flush=True)
                            if event['state'] == 'activation_requested_unverified':
                                due = time.monotonic() + signal_after
                        if event.get('action') == 'stop':
                            stopped = True
                            print('STOP_REPORT: ' + str(event.get('stop_reason')), flush=True)
                        save()
            signal_ready = ((folder / 'send-term').exists() if args.manual_signal
                            else due is not None and time.monotonic() >= due)
            if (args.case == 'sigterm' and due is not None and signal_ready and pid
                    and not stopped and not record['signal_sent'] and process.poll() is None):
                record['signal_attempted_utc'] = utc()
                try:
                    result = subprocess.run(ssh + ['kill -TERM ' + str(pid)], capture_output=True,
                                            text=True, timeout=10)
                    record['signal_sent'] = result.returncode == 0
                    record['signal_result'] = {'exit_code': result.returncode,
                        'stdout': result.stdout, 'stderr': result.stderr, 'pid': pid}
                except subprocess.TimeoutExpired:
                    # Command delivery is unknown. Keep collecting the owner report
                    # and preserve the original lease instead of aborting capture.
                    record['signal_result'] = {'exit_code': None, 'timed_out': True,
                        'delivery': 'unknown', 'pid': pid}
                # Do not repeat signals if transport fails; the original lease remains.
                due = None
                save()
                print('TERM_COMMAND_EXIT=' + str(record['signal_result']['exit_code']), flush=True)
    selector.close()
    process.stdout.close()
    process.stderr.close()
    record['exit_code'] = process.wait()
    record['finished_utc'] = utc()
    record['elapsed_host_seconds'] = time.monotonic() - began
    record['stderr_empty'] = (folder / 'stderr.log').stat().st_size == 0
    record['log_hashes'] = {name: hashlib.sha256((folder / name).read_bytes()).hexdigest()
                            for name in ['stdout.log', 'stderr.log', 'arrivals.jsonl']}
    save()
    stops = [e for e in record['stdout_reports'] if e.get('action') == 'stop']
    expected_reason = 'signal' if args.case == 'sigterm' else 'lease_expired'
    passed = (record['exit_code'] == 0 and len(stops) == 1
              and stops[0].get('stop_reason') == expected_reason
              and stops[0].get('request_sent') and (args.case != 'sigterm' or record['signal_sent']))
    print('BACKEND_LIFECYCLE_CHECK=' + ('PASS' if passed else 'FAIL'), flush=True)
    return 0 if passed else 1


if __name__ == '__main__':
    raise SystemExit(main())
