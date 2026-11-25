"""DM_MEMSTAT and DM_THRCPU (dm/host/memstat.m) start from the host's loading, after the iOS front end has set what Documents/env.txt holds: checked in the sources off the device.
Constructors run before the app's main() (dm/ios/Sources/main.m) reads the env files, so a sampler started from one never saw a switch set there (upstream addbe8d62)."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the C function whose definition starts with header, through its closing brace"""
    i = src.index(header)
    j = src.index('{', i)
    depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth:
            return src[j:k + 1]
    raise AssertionError(header)


class Wiring(unittest.TestCase):
    def setUp(self):
        self.memstat = read('dm/host/memstat.m')
        self.main = read('dm/host/main.c')
        self.ios = read('dm/ios/Sources/main.m')

    def test_no_sampler_starts_from_a_constructor(self):
        self.assertNotIn('__attribute__((constructor))', self.memstat)

    def test_both_samplers_start_once_from_one_entry(self):
        start = body(self.memstat, 'void dm_diag_samplers_start(void)')
        self.assertIn('atomic_exchange', start)
        self.assertLess(start.index('atomic_exchange'), start.index('memstat_start()'))
        self.assertIn('thrcpu_start()', start)

    def test_the_hosts_loading_starts_them(self):
        self.assertIn('dm_diag_samplers_start()', body(self.main, 'static void host_preload(int argc, char **argv)'))

    def test_ios_sets_the_env_files_before_the_loading_starts(self):
        env = self.ios.index('stringByAppendingPathComponent:@"env.txt"')
        start = [m.start() for m in re.finditer(r'\bdm_host_preload_start\(g_argc, g_argv\)', self.ios)]
        self.assertTrue(start)
        self.assertTrue(all(s > env for s in start))


if __name__ == '__main__':
    unittest.main()
