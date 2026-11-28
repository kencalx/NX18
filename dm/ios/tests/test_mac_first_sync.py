"""The Mac's first sync of a game through a cloud folder waits for iCloud (dm/mac/MacFirstSync.swift, FirstSyncGate in dm/mac/Launcher.swift, dm/mac/launcher.c, save_sync.c's
DM_SAVE_SYNC_CHOICE=hold).

The rules run in mac_first_sync_check.swift, compiled with MacFirstSync.swift alone, over temporary folders with a stand-in iCloud and a clock the test moves (nothing waits
for real, nothing touches iCloud Drive). The wiring is checked in the sources: the check comes before the host acts on DM_SAVE_SYNC (launcher.c after cloud_saves_folder and
before the host starts; Play and the start without the window before their save check; the card's move before save_sync_move), a held start sets hold, and the host keeps
to it. That the host sends nothing on a held start runs in dm/host/tests/t_save_sync.c (37)."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the declaration whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class FirstSyncRules(unittest.TestCase):
    def test_rules_over_temporary_folders(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp); exe = tmp / 'mac_first_sync_check'
            c = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(tmp / 'module-cache'), '-o', str(exe),
                                str(REPO / 'dm/mac/MacFirstSync.swift'), str(Path(__file__).with_name('mac_first_sync_check.swift'))], capture_output=True, text=True, timeout=300)
            self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60, env={'HOME': str(tmp), 'TMPDIR': str(tmp) + '/', 'PATH': '/usr/bin:/bin'})
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(', 0 failed', r.stdout)


class FirstSyncWiring(unittest.TestCase):
    def setUp(self):
        self.mac = read('dm/mac/Launcher.swift'); self.c = read('dm/mac/launcher.c'); self.sync = read('dm/host/save_sync.c')

    def test_launcher_checks_before_the_host_acts_on_the_folder(self):
        main = body(self.c, 'int main(int argc, char **argv)')
        folder, first, spawn = main.index('cloud_saves_folder();'), main.index('dm_mac_first_sync()'), main.index('posix_spawn(')
        self.assertLess(folder, first); self.assertLess(first, spawn)   # the folder is known, then iCloud is asked, then the host starts
        self.assertIn('if (!dm_mac_first_sync()) {', main)   # Quit at its alert: no game
        self.assertIn('@_cdecl("dm_mac_first_sync")', self.mac)
        self.assertIn('FirstSyncGate.withoutWindow()', body(self.mac, 'public func dmMacFirstSync()'))

    def test_play_and_the_start_without_the_window_check_before_comparing(self):
        start = body(self.mac, 'private func start()')
        self.assertLess(start.index('FirstSyncGate.prepare()'), start.index('compare(mine)'))
        self.assertNotIn('SaveCheck.report()', start)   # the comparison is compare's, after the check
        self.assertIn('SaveCheck.report()', body(self.mac, 'private func compare(_ mine: Int)'))
        without = body(self.mac, '@MainActor static func withoutWindow() -> Bool {\n        guard FirstSyncGate')
        self.assertLess(without.index('FirstSyncGate.withoutWindow()'), without.index('report()'))
        self.assertIn('"hold"', without)   # held: nothing to compare
        self.assertIn('Button("Play Anyway")', self.mac); self.assertIn('FirstSyncGate.hold(.playAnyway)', self.mac)
        self.assertIn("Checking iCloud for this game's save…", self.mac)

    def test_held_start_and_record(self):
        gate = body(self.mac, 'enum FirstSyncGate')
        self.assertIn('SaveCheck.apply("hold")', body(gate, 'static func hold('))
        # the record is written only when the game starts through the folder or the card's move has switched to it, never at the check's end or on a held start
        self.assertNotIn('FirstSyncRecord.key', body(gate, 'static func finish('))
        self.assertIn('pending = FirstSyncRecord.identity(', body(gate, 'static func finish('))
        self.assertIn('FirstSyncRecord.key', body(gate, 'static func commit('))
        self.assertIn('pending = nil', body(gate, 'static func hold('))
        self.assertIn('pending = nil', body(gate, 'static func prepare('))
        first = body(self.mac, 'public func dmMacFirstSync()')
        self.assertLess(first.index('FirstSyncGate.withoutWindow()'), first.index('FirstSyncGate.commit()'))
        after = body(self.mac, 'private func afterMove(')
        self.assertLess(after.index('case 0, 1:'), after.index('FirstSyncGate.commit()')); self.assertLess(after.index('FirstSyncGate.commit()'), after.index('case 2:'))
        self.assertIn("iCloud hasn't finished bringing this game's save from your other devices. This start keeps your save on this Mac; it syncs at a later start.", gate)
        prepare = body(gate, 'static func prepare(')
        self.assertIn('save_sync_synced(', prepare); self.assertIn('FirstSyncRecord.needed(', prepare)
        for line in [l for l in gate.splitlines() if 'fputs(' in l]:   # no folder in the log
            self.assertNotIn('folder)', line); self.assertNotIn('paths', line)

    def test_card_move_checks_the_folder_it_goes_to(self):
        move = body(self.mac, 'func move(toShared: Bool, how: UInt32 = 0)')
        self.assertLess(move.index('FirstSyncGate.prepare(folder: to)'), move.index('save_sync_move('))
        self.assertLess(move.index('first.run()'), move.index('save_sync_move('))

    def test_host_keeps_to_a_held_start(self):
        self.assertIn('if (!strcmp(v, "hold")) return CH_HOLD;', self.sync)
        mount = body(self.sync, 'static int mount_once(')
        held, sender = mount.index('== CH_HOLD'), mount.index('pthread_create(&th, NULL, sender')
        self.assertLess(held, mount.index('fetch_timed(')); self.assertLess(held, sender)
        self.assertIn('== CH_HOLD', body(self.sync, 'int save_sync_after_exit('))


if __name__ == '__main__':
    unittest.main()
