"""The cheats the iPhone's in-game menu reads (GameMenu.swift's Cheats submenu, through DmGameMenu.h) only once the host has loaded them (hle_cheats.c), checked in the
sources off the device. On the iPhone dm_cheats_init runs on the preload thread while the menu may already be open; every accessor and action answers "nothing" until init
publishes g_ready with a release store at its end, and the accessors take no lock, so a cheat pass, which only tries the lock, never skips for a menu."""
from pathlib import Path
import re
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


class Cheats(unittest.TestCase):
    def test_the_menus_read_only_once_init_has_published(self):   # the iPhone runs dm_cheats_init on the preload thread while the in-game menu may be open
        c = read('dm/host/hle_cheats.c')
        init = body(c, 'void dm_cheats_init(void) {')
        self.assertTrue(init.rstrip('}').rstrip().endswith('atomic_store_explicit(&g_ready, 1, memory_order_release);   // the menus read the state from here on '
                                                          "(the iPhone's in-game menu may be open while this runs: menus_ready)"))
        self.assertIn('return atomic_load_explicit(&g_ready, memory_order_acquire);', body(c, 'static int menus_ready(void) {'))
        api = c[c.index('static int menus_ready(void) {'):]
        for decl in re.findall(r'^(?:int|void|const char \*)(?:dm_cheat_\w+|dm_cheats_\w+)\([^)]*\) \{', api, re.M):
            if decl.startswith(('int dm_cheats_master(void)',)): continue   # an atomic, on by default before init as after
            with self.subTest(fn=decl): self.assertRegex(body(api, decl), r'menus_ready\(\)|entry_listed\(|other_listed\(')
        self.assertNotIn('pthread_mutex_lock(&g_lock)', body(api, 'int dm_cheats_ncheats(void) {') + body(api, 'const char *dm_cheat_name_at(int i) {'))   # a pass only trylocks
        self.assertIn('if (pthread_mutex_trylock(&g_lock)) return;', body(c, 'static void cheats_pass(void) {'))

    def test_the_menu_declares_what_the_host_defines(self):   # DmGameMenu.h's cheats are hle_cheats.c's, and the Duo harness stubs each so GameMenu.swift links there
        h = read('dm/ios/Sources/DmGameMenu.h'); c = read('dm/host/hle_cheats.c'); stubs = read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m')
        names = re.findall(r'^[\w ]+?\**\s*\b(dm_cheats?_\w+)\(', h, re.M)
        self.assertGreaterEqual(len(names), 10)
        for n in names:
            with self.subTest(fn=n):
                self.assertRegex(c, r'(?m)^[\w ]+?\**\s*\b%s\([^)]*\) \{' % n)
                self.assertRegex(stubs, r'\b%s\(' % n)
        self.assertIn('cheatsMenu()', read('dm/ios/Sources/GameMenu.swift'))


if __name__ == '__main__':
    unittest.main()
