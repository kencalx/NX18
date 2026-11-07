"""Where the iPhone and Mac apps' Swift meets their C and Objective-C, checked in the sources off the device.

The four Swift functions C calls (Launcher.swift dm_show_launcher, GameMenu.swift dm_game_menu, Metrics.swift dm_metrics_modern_start, dm/mac/Launcher.swift dm_mac_launcher) are each
@c @implementation of the one C declaration in a header that the Swift side reads (the bridging header; -import-objc-header for the Mac launcher) and every C and Objective-C caller and
stand-in includes, so the compiler checks the Swift signature against what C calls. The compiles that do the checking are the app's (CI's Unsigned iOS app), the Mac app's pack and
test_launcher_storage.py on a Mac, and test_metrics_bgprepare.py's typecheck of Metrics.swift wherever a swiftc is found. Also here: the log on descriptor 2 (main.m) and Swift's
writes to it, the cloud-save folder's security scope (CloudSaves.m), and the cheats the in-game menu reads only once the host has loaded them (hle_cheats.c)."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / 'dm/ios/Sources'
# entry, its Swift file, its header, the C and Objective-C files that call it or stand in for it
ENTRIES = (('dm_show_launcher', 'dm/ios/Sources/Launcher.swift', 'dm/ios/Sources/DmLauncher.h', ('dm/ios/Sources/front_ios.m', 'dm/ios/tests/duo/Sources/DuoRuntimeStubs.m')),
           ('dm_game_menu', 'dm/ios/Sources/GameMenu.swift', 'dm/ios/Sources/DmGameMenu.h', ('dm/ios/Sources/DmGamepad.m',)),
           ('dm_metrics_modern_start', 'dm/ios/Sources/Metrics.swift', 'dm/ios/Sources/DmMetrics.h', ('dm/ios/Sources/DmMetrics.m',)),
           ('dm_mac_launcher', 'dm/mac/Launcher.swift', 'dm/mac/launcher_window.h', ('dm/mac/launcher.c',)))


DECL = r'(?m)^\s*(?:extern\s+)?(?:const\s+)?\w+[\s*]+{}\s*\([^{{;]*\)\s*;'   # a prototype of the entry: a type, the name, its parameters, no body


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


def c_sources():
    for d in ('dm/ios/Sources', 'dm/ios/tests/duo/Sources', 'dm/ios/tests/duo/Tests', 'dm/mac', 'dm/host', 'dm/gfx/nvn'):
        yield from sorted(p for p in (REPO / d).iterdir() if p.suffix in ('.c', '.m', '.h'))


class Entries(unittest.TestCase):
    def test_no_swift_uses_the_underscored_cdecl(self):   # @c (Swift 6.3) replaced it: Xcode 27.2's Swift 6.4 has it
        for p in sorted([*REPO.glob('dm/**/*.swift'), *REPO.glob('builder/**/*.swift')]):
            if 'third_party' not in p.parts:
                with self.subTest(path=p.relative_to(REPO)): self.assertNotIn('@_cdecl', p.read_text(encoding='utf-8'))

    def test_each_entry_implements_its_one_declaration(self):
        for name, swift, header, callers in ENTRIES:
            with self.subTest(entry=name):
                self.assertRegex(read(swift), r'\n@c @implementation\npublic func ' + name + r'\(')   # the C name: @c(name) on another Swift name finds no declaration
                self.assertEqual(len(re.findall(r'^[^/\n]*\b' + name + r'\(', read(header), re.M)), 1)
                inc = Path(header).name
                for c in callers:
                    self.assertRegex(read(c), r'#(include|import) "' + re.escape(inc) + '"', c)
                for p in c_sources():   # no other declaration that the compiler would not hold to the header's
                    if str(p.relative_to(REPO)) not in (header, *callers):
                        self.assertNotRegex(p.read_text(encoding='utf-8', errors='replace'), DECL.format(name), p.name)

    def test_the_swift_side_reads_the_headers(self):
        bridging = read('dm/ios/Sources/DmIOS-Bridging-Header.h')
        for h in ('DmLauncher.h', 'DmGameMenu.h', 'DmMetrics.h', 'CloudSaves.h'): self.assertIn(f'#import "{h}"', bridging)
        self.assertIn('SWIFT_OBJC_BRIDGING_HEADER: Sources/DmIOS-Bridging-Header.h', read('dm/ios/project.yml'))
        self.assertIn('SWIFT_OBJC_BRIDGING_HEADER: $(SRCROOT)/../../Sources/DmIOS-Bridging-Header.h', read('dm/ios/tests/duo/project.yml'))
        pack = read('dm/mac/pack_app.py')
        self.assertIn("return HERE / 'launcher_window.h'", pack)
        self.assertIn("'-import-objc-header', swift_header()", pack)
        self.assertIn("HERE / 'launcher.c', swift_header()", pack)   # in the app's reuse key with the sources

    def test_main_thread_entries_assert_it(self):   # a C entry point is not isolated to the main actor
        for name, swift, _, _ in ENTRIES:
            if name != 'dm_metrics_modern_start':   # the metrics queue's
                with self.subTest(entry=name): self.assertIn('MainActor.assumeIsolated', body(read(swift), f'public func {name}('))
        # AppKit's delegate protocols are not main-actor protocols (only their methods are), so the Mac launcher's delegate class says it itself: its NSWindow and NSApp uses in
        # init, fit and finish are then checked as main-actor code in Swift 6
        self.assertIn('\n@MainActor private final class Launcher: NSObject, NSApplicationDelegate, NSWindowDelegate {', read('dm/mac/Launcher.swift'))

    def test_the_menu_crosses_at_plus_one(self):   # passRetained in Swift, one CFBridgingRelease in C, and the header says so
        self.assertIn('Unmanaged.passRetained(menu)', body(read('dm/ios/Sources/GameMenu.swift'), 'public func dm_game_menu('))
        self.assertIn('CFBridgingRelease', read('dm/ios/Sources/DmGameMenu.h'))
        self.assertEqual(read('dm/ios/Sources/DmGamepad.m').count('CFBridgingRelease(dm_game_menu())'), 1)

    def test_headers_have_c_linkage_and_import_outside_it(self):   # a C++ reader (C++ interoperability, should it ever be on) may not import a module inside extern "C"
        for h in ('dm/ios/Sources/CloudSaves.h', 'dm/ios/Sources/DmMetrics.h', 'dm/ios/Sources/DmGameMenu.h', 'dm/ios/Sources/DmLauncher.h', 'dm/mac/launcher_window.h'):
            with self.subTest(header=h):
                t = read(h); block = t[t.index('extern "C" {'):]
                self.assertIn('#ifdef __cplusplus\nextern "C" {\n#endif', t)
                self.assertNotIn('#import', block); self.assertNotIn('#include', block)

    def test_nullability_matches_what_swift_passes(self):   # Swift's signatures are non-optional; GameMenu.swift asks dm_setting_live with nil
        self.assertIn('bool dm_show_launcher(void *_Nonnull view_controller, void (*_Nonnull done)(void));', read('dm/ios/Sources/DmLauncher.h'))
        menu = read('dm/ios/Sources/DmGameMenu.h')
        self.assertLess(menu.index('#pragma clang assume_nonnull begin'), menu.index('void *dm_game_menu(void);'))
        self.assertIn('bool dm_setting_live(const char *env, const char *_Nullable value);', menu)
        self.assertIn('dm_setting_live(s.env, nil)', read('dm/ios/Sources/GameMenu.swift'))


class Logging(unittest.TestCase):
    def test_swift_logs_with_the_throwing_write(self):   # FileHandle.write(_:) raises an Objective-C exception on a failed write (a full disk), which Swift cannot catch
        swift = read('dm/ios/Sources/LauncherSettings.swift')
        self.assertIn('func launcherLog(_ line: String) { try? FileHandle.standardError.write(contentsOf: Data(line.utf8)) }', swift)
        for p in [*SRC.glob('*.swift'), REPO / 'dm/mac/Launcher.swift']:
            with self.subTest(path=p.name):
                t = p.read_text(encoding='utf-8')
                self.assertNotRegex(t, r'\.write\(Data\('); self.assertNotIn('fputs(', t); self.assertNotIn('stderr)', t)

    def test_the_log_is_moved_onto_descriptor_2_never_left_free(self):   # freopen closed it first, and left it closed when the open failed
        main = read('dm/ios/Sources/main.m')
        self.assertNotIn('freopen(', main)
        log = body(main, 'static void log_open(NSString *log) {')
        self.assertIn('open(log.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0666)', log)
        self.assertIn('dup2(fd, STDERR_FILENO)', log); self.assertIn('open("/dev/null", O_WRONLY)', log)
        self.assertIn('setvbuf(stderr, NULL, _IOLBF, 0)', log)
        env = body(main, 'static int boot_env(void) {')
        self.assertLess(env.index('log_open(log);'), env.index('dm_host_preload_start('))   # before the preload thread starts


class CloudScope(unittest.TestCase):
    def test_each_started_scope_is_stopped_once(self):
        m = read('dm/ios/Sources/CloudSaves.m')
        hold = body(m, 'static void scope_hold(NSURL *url) {')
        self.assertIn('[opened stopAccessingSecurityScopedResource]', hold)
        self.assertIn('if (url && [url startAccessingSecurityScopedResource]) opened = url;', hold)   # only a started URL is held
        path = body(m, 'NSString *dm_cloud_saves_path(BOOL *stale) {')
        self.assertIn('scope_hold(url);', path)
        self.assertRegex(path, r'if \(!url\) \{[^}]*\n\s*scope_hold\(nil\);')   # a bookmark that no longer resolves: cloud saves are off, and an earlier start is stopped
        self.assertIn('scope_hold(nil);', body(m, 'void dm_clear_cloud_saves(void) {'))
        self.assertEqual(m.count('startAccessingSecurityScopedResource]'), 2)   # scope_hold's, and fresh_bookmark's, which it stops itself
        self.assertIn('if (scoped) [url stopAccessingSecurityScopedResource];', body(m, 'static NSData *fresh_bookmark(NSURL *url) {'))


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


if __name__ == '__main__':
    unittest.main()
