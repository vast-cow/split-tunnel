"""Offline route lifecycle tests; no host networking commands are executed."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "split-tunnel.sh"
MOCK_IP = r'''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
p = Path(os.environ['MOCK_STATE'])
s = json.loads(p.read_text())
a = [x for x in sys.argv[1:] if x not in ('-4', '-o')]
s['calls'].append(a)
def done(code=0):
    p.write_text(json.dumps(s))
    sys.exit(code)
if a[:2] == ['route', 'show']:
    print('\n'.join(s['routes'].get(a[-1], [])), end='')
    if s['routes'].get(a[-1]): print()
elif a[:2] == ['route', 'save']:
    print(json.dumps({a[-1]: s['routes'].get(a[-1], [])}))
elif a[:2] == ['route', 'replace']:
    if s.get('fail_replace'): done(1)
    cidr = a[2]
    others = [r for r in s['routes'].get(cidr, []) if ' metric ' in r]
    s['routes'][cidr] = others + [' '.join(a[2:])]
elif a[:2] == ['route', 'del']:
    if s.get('fail_delete'): done(1)
    s['routes'][a[2]].remove(' '.join(a[2:]))
elif a[:2] == ['route', 'restore']:
    if s.get('fail_restore'): done(1)
    for cidr, routes in json.load(sys.stdin).items():
        current = s['routes'].setdefault(cidr, [])
        for route in routes:
            if route not in current: current.append(route)
elif a == ['netns', 'list']:
    if s['namespace']: print('st')
elif a[:2] == ['netns', 'del']:
    s['namespace'] = False
elif a[:2] == ['link', 'show']:
    done(0 if s['link'] else 1)
elif a[:2] == ['link', 'del']:
    s['link'] = False
elif a[:2] == ['netns', 'exec']:
    pass
else:
    raise SystemExit('Unexpected mock ip arguments: ' + repr(a))
done()
'''


class RouteLifecycleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / 'mock.json'
        self.write_state({'routes': {}, 'calls': [], 'namespace': True, 'link': True})
        (self.root / 'ip').write_text(MOCK_IP)
        (self.root / 'ip').chmod(0o755)
        # Load definitions only, avoiding root checks and the CLI dispatch.
        (self.root / 'functions.sh').write_text(SCRIPT.read_text().split('\nrequire_root\n')[0])

    def read_state(self):
        return json.loads(self.state.read_text())

    def write_state(self, state):
        self.state.write_text(json.dumps(state))

    def update(self, **kwargs):
        state = self.read_state()
        state.update(kwargs)
        self.write_state(state)

    def run_shell(self, command, ranges='', success=True):
        env = dict(os.environ, PATH=f'{self.root}:{os.environ["PATH"]}',
                   MOCK_STATE=str(self.state), OUT_IF='eth0', NS='st',
                   VETH_HOST='st-host', VETH_NS='st-ns',
                   HOST_IP='10.200.0.1', NS_IP='10.200.0.2',
                   SPLITTUNNEL_VIP='192.0.2.10', SPLITTUNNEL_IPRANGELIST=ranges)
        setup = '''source "$1/functions.sh"
STATE_DIR="$1/state"
STATE_FILE="$STATE_DIR/st.state"
ROUTES_DIR="$STATE_DIR/st.routes"
del_rule() { :; }
'''
        result = subprocess.run(['bash', '-c', setup + command, 'test', str(self.root)],
                                env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result

    def test_restore_original_attributes_and_other_metrics(self):
        original = ['172.19.0.0/16 via 192.0.2.1 dev eth0 proto static src 192.0.2.2 mtu 1400',
                    '172.19.0.0/16 via 192.0.2.3 dev eth0 metric 100']
        self.update(routes={'172.19.0.0/16': original})
        self.run_shell('configure_routes', '172.19.0.0/16')
        self.run_shell('configure_routes', '172.19.2.3/16')
        self.run_shell('stop')  # No ranges required when stopping.
        state = self.read_state()
        self.assertEqual(sorted(state['routes']['172.19.0.0/16']), sorted(original))
        self.assertFalse(state['namespace'])
        self.assertFalse((self.root / 'state/st.routes').exists())
        calls = state['calls']
        self.assertLess(calls.index(['route', 'restore']), calls.index(['netns', 'del', 'st']))

    def test_new_routes_removed_and_repeated_alias_preserves_original(self):
        self.run_shell('configure_routes', '172.19.1.2/16,198.51.100.4/32')
        original_dump = (self.root / 'state/st.routes/172.19.0.0_16/original').read_bytes()
        self.run_shell('configure_routes', '172.19.0.0/16')
        self.assertEqual((self.root / 'state/st.routes/172.19.0.0_16/original').read_bytes(), original_dump)
        self.run_shell('stop')
        self.assertTrue(all(not routes for routes in self.read_state()['routes'].values()))
        self.run_shell('stop')

    def test_external_change_blocks_stop_and_routes(self):
        self.run_shell('configure_routes', '172.19.0.0/16')
        external = {'172.19.0.0/16': ['172.19.0.0/16 via 192.0.2.99 dev eth0']}
        self.update(routes=external)
        self.run_shell('configure_routes', '172.19.0.0/16', success=False)
        result = self.run_shell('stop', success=False)
        self.assertIn('changed outside this script', result.stderr)
        state = self.read_state()
        self.assertEqual(state['routes'], external)
        self.assertTrue(state['namespace'])
        self.assertTrue(state['link'])
        self.assertTrue((self.root / 'state/st.routes').exists())

    def test_restore_failure_retains_state_and_allows_retry(self):
        original = {'172.19.0.0/16': ['172.19.0.0/16 via 192.0.2.1 dev eth0']}
        self.update(routes=original)
        self.run_shell('configure_routes', '172.19.0.0/16')
        self.update(fail_restore=True)
        self.run_shell('stop', success=False)
        self.assertTrue(self.read_state()['namespace'])
        self.assertTrue((self.root / 'state/st.routes').exists())
        self.update(fail_restore=False)
        self.run_shell('stop')
        self.assertEqual(self.read_state()['routes'], original)

    def test_delete_failure_allows_retry(self):
        self.run_shell('configure_routes', '172.19.0.0/16')
        self.update(fail_delete=True)
        self.run_shell('stop', success=False)
        self.update(fail_delete=False)
        self.run_shell('stop')
        self.assertEqual(self.read_state()['routes']['172.19.0.0/16'], [])

    def test_replace_failure_leaves_original_and_stop_cleans_state(self):
        original = {'172.19.0.0/16': ['172.19.0.0/16 via 192.0.2.1 dev eth0']}
        self.update(routes=original, fail_replace=True)
        self.run_shell('configure_routes', '172.19.0.0/16', success=False)
        self.run_shell('stop')
        self.assertEqual(self.read_state()['routes'], original)

    def test_incomplete_snapshot_refuses_destructive_cleanup(self):
        self.run_shell('configure_routes', '172.19.0.0/16')
        (self.root / 'state/st.routes/172.19.0.0_16/after').unlink()
        self.run_shell('stop', success=False)
        self.assertTrue(self.read_state()['namespace'])

    def test_partial_configuration_can_be_stopped(self):
        self.run_shell('configure_routes', '172.19.0.0/16,invalid', success=False)
        self.run_shell('stop')
        self.assertEqual(self.read_state()['routes']['172.19.0.0/16'], [])

    def test_invalid_ranges_do_not_change_routes(self):
        for cidr in ['999.1.1.1/24', '1.2.3.4/33', '../../tmp', '1.2.3.4/24/1']:
            with self.subTest(cidr=cidr):
                self.run_shell('configure_routes', cidr, success=False)
                self.assertEqual(self.read_state()['routes'], {})

    def test_normalize_default_and_host(self):
        result = self.run_shell('normalize_cidr 1.2.3.4/0; normalize_cidr 192.0.2.1')
        self.assertEqual(result.stdout, '0.0.0.0/0\n192.0.2.1/32\n')


if __name__ == '__main__':
    unittest.main()
