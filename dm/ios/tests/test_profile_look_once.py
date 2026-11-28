"""One look at the NX 18 folder's Profile per start (NX18Profile.swift, DM_PROFILE_LOOK_ONCE), checked in the sources: the Gate's Play looks and marks it, startGame's
dm_profile_env (front_ios.m) skips its look only after that mark and within 5 minutes, the env is applied either way, the switch at 0 never marks, and a look while a read is
still running uses the local copy only with the switch on. The look itself (NX18ProfileSync.pull) is unchanged."""
from pathlib import Path
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


class ProfileLookOnce(unittest.TestCase):
    def setUp(self):
        self.profile = read('dm/ios/Sources/NX18Profile.swift'); self.launcher = read('dm/ios/Sources/Launcher.swift'); self.front = read('dm/ios/Sources/front_ios.m')

    def test_play_marks_after_its_look(self):
        play = body(self.profile, 'func envForPlay()')
        self.assertLess(play.index('lookAtFolder()'), play.index('lookedForPlayAt ='), 'the mark after the look')
        self.assertIn('NX18Profile.applyEnv()', play)
        self.assertIn('Self.lookOnce ? CFAbsoluteTimeGetCurrent() : 0', play, 'the switch at 0 never marks')
        start = body(self.launcher, 'private func start()')
        self.assertIn('NX18Profile.shared.envForPlay()', start); self.assertNotIn('dm_profile_env()', start)

    def test_start_game_skips_only_after_the_mark(self):
        env = body(self.profile, 'public func dm_profile_env()')
        self.assertIn('NX18Profile.lookedForPlayAt = 0', env, 'the mark is used once')
        self.assertIn('if at > 0, CFAbsoluteTimeGetCurrent() - at < 300', env)
        self.assertIn('else { NX18Profile.shared.lookAtFolder() }', env)
        self.assertTrue(env.rstrip('}').rstrip().endswith('NX18Profile.applyEnv()'), 'the env either way')
        self.assertIn('dm_profile_env();', body(self.front, '- (void)startGame {'))

    def test_one_read_in_flight(self):
        look = body(self.profile, 'func lookAtFolder(budget: TimeInterval = 1.0)')
        self.assertIn('if once, !Self.pullInFlight.withLock', look)
        self.assertIn('if once { NX18Profile.pullInFlight.withLock { $0 = false } }', look)
        self.assertLess(look.index('pullInFlight.withLock { $0 = false }'), look.index('done.signal()'), 'cleared before the waiter can look again')

    def test_switch_row(self):
        self.assertTrue(any(l.startswith('DM_PROFILE_LOOK_ONCE\tswitch\t') for l in read('docs/env_switches.tsv').splitlines()))


if __name__ == '__main__':
    unittest.main()
