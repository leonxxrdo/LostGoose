#!/usr/bin/env python3
"""Run only fake-backend lifecycle tests and nonmutating production commands.

Uses an existing SSH control session; never handles or stores passwords. The
production binary is never passed run/stop. Fake console has separate locks.
"""
import argparse
import json
import select
import shlex
import subprocess
from pathlib import Path

parser = argparse.ArgumentParser()
parser.add_argument('--host', required=True)
parser.add_argument('--control', required=True)
parser.add_argument('--remote-directory', default='/var/mobile/Library/Caches/ios-location-lab/engine-v1/')
parser.add_argument('--output', type=Path, default=Path('build/engine/device-tests.json'))
args = parser.parse_args()
base = args.remote_directory.rstrip('/') + '/'
ssh = ['ssh', '-S', args.control, '-o', 'BatchMode=yes', 'mobile@' + args.host]
records = []


def command(binary, *arguments):
    assert binary in ['console-fake', 'engine-tests', 'location-lab']
    if binary == 'location-lab':
        assert not arguments or arguments[0] in ['inspect', 'plan']
    return ssh + [shlex.join(['env', '_MSSafeMode=1', '_SafeMode=1', base + binary, *arguments])]


def run(name, binary, *arguments, expected=0):
    result = subprocess.run(command(binary, *arguments), text=True, capture_output=True, timeout=15)
    record = {'test': name, 'exit_code': result.returncode, 'stdout': result.stdout, 'stderr': result.stderr}
    records.append(record)
    assert result.returncode == expected, record
    return result


result = run('engine-unit-tests', 'engine-tests')
unit = json.loads(result.stdout)
assert unit['backend'] == 'fake_only' and unit['count'] == 8 and not unit['private_api_invoked']
inspection = json.loads(run('production-inspect', 'location-lab', 'inspect').stdout)
assert inspection['signature_shapes_match'] and not inspection['manager_instantiated']
assert not inspection['injection_related_images']
plan = json.loads(run('production-plan', 'location-lab', 'plan', '10', '20', '--seconds', '30').stdout)
assert plan['state'] == 'plan_only' and not plan['simulation_requested']
run('invalid-coordinate', 'location-lab', 'plan', '91', '20', '--seconds', '30', expected=1)
run('nonfinite-coordinate', 'location-lab', 'plan', 'nan', '20', '--seconds', '30', expected=1)
run('invalid-duration', 'location-lab', 'plan', '10', '20', '--seconds', '0', expected=1)
run('missing-command', 'location-lab', expected=2)

lease = run('fake-lease-expiry', 'console-fake', 'run', '10', '20', '--seconds', '5')
events = [json.loads(line) for line in lease.stdout.splitlines()]
assert all(e['backend'] == 'fake_only' for e in events)
assert events[0]['state'] == 'activation_requested_unverified'
assert events[-1]['state'] == 'deactivation_requested_unverified'
assert events[-1]['stop_reason'] == 'lease_expired'
stopped = events[-1]
assert stopped['stop_requested_monotonic_seconds'] >= stopped['lease_deadline_monotonic_seconds'] - 0.05
assert stopped['stop_requested_monotonic_seconds'] < stopped['lease_deadline_monotonic_seconds'] + 2
assert stopped['worker_started_monotonic_seconds'] >= stopped['stop_requested_monotonic_seconds']
assert stopped['emitted_monotonic_seconds'] >= stopped['step_timings'][-1]['ended_monotonic_seconds']

owner = subprocess.Popen(command('console-fake', 'run', '10', '20', '--seconds', '20'),
                         stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    ready, _, _ = select.select([owner.stdout], [], [], 8)
    assert ready, 'Fake owner did not start'
    first = owner.stdout.readline()
    assert json.loads(first)['backend'] == 'fake_only'
    run('fake-exclusive-owner', 'console-fake', 'run', '11', '21', '--seconds', '5', expected=1)
    reply = json.loads(run('fake-independent-stop', 'console-fake', 'stop').stdout)
    assert reply['request_sent'] and reply['stop_reason'] == 'control_command'
    rest, stderr = owner.communicate(timeout=12)
    records.append({'test': 'fake-owner-cleanup', 'exit_code': owner.returncode,
                    'stdout': first + rest, 'stderr': stderr})
    assert owner.returncode == 0
    final = json.loads(rest.splitlines()[-1])
    assert final['state'] == 'deactivation_requested_unverified'
    assert final['stop_reason'] == 'control_command'
finally:
    if owner.poll() is None:
        # Only the fake backend, using its own namespace; never the production engine.
        subprocess.run(command('console-fake', 'stop'), capture_output=True, timeout=15)
        owner.communicate(timeout=25)
run('fake-standalone-stop', 'console-fake', 'stop')

output = args.output
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text(json.dumps({'schema': 'ios-location-lab.engine-validation.v1',
    'production_mutating_commands_run': False, 'unit_tests': unit['count'],
    'records': records}, indent=2) + '\n')
print(f"PASS: {unit['count']} engine tests, {len(records)-1} CLI checks; no live simulation calls")
