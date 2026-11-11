"""The front ends' log redirect and the iPhone app's cloud-save folder scope.

The log: main.m's log_open puts Documents/log.txt on descriptor 2 and launcher.c's puts the Mac app's log on 1 and 2, both through dm/host/log_redirect.h, which
dm/host/tests/t_log_redirect.c runs with every mix of closed descriptors (make -C dm/host/tests log-redirect). Here: that both front ends use it, as their only redirect, before
the iPhone's preload thread starts, and, on a Mac, main.m's very log_open compiled with Foundation and started with descriptor 2 closed and a log that cannot be created, as a
full disk leaves it (freopen left 2 free there, and the next file opened, possibly a save, got every later raw write to descriptor 2: a crash report, NSLog).

The scope: CloudSaves.m's scope_hold starts a folder's security scope once and stops it when another folder, or none, is picked."""
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel): return (REPO / rel).read_text()


def body(src, head):
    """The body of the function whose first line is head: up to the first closing brace at the start of a line (braces in its strings and comments do not count)"""
    i = src.index(head) + len(head)
    return src[i:src.index('\n}\n', i)]


class Wiring(unittest.TestCase):
    def test_iphone_log_goes_through_the_helper_before_the_preload_thread(self):
        main = read('dm/ios/Sources/main.m')
        self.assertNotIn('freopen(', re.sub(r'//.*', '', main))   # in code (the comment tells its story): freopen frees descriptor 2 when the open fails
        self.assertIn('#include "log_redirect.h"', main)
        log = body(main, 'static void log_open(NSString *log) {')
        self.assertIn('dm_log_redirect(log.fileSystemRepresentation, 0666, STDERR_FILENO)', log)   # freopen's "w" mode, onto 2 alone
        self.assertIn('setvbuf(stderr, NULL, _IOLBF, 0)', log)
        env = body(main, 'static int boot_env(void) {')
        self.assertEqual(env.count('log_open(log);'), 1)
        self.assertLess(env.index('log_open(log);'), env.index('dm_host_preload_start('))   # before the preload thread starts

    def test_mac_launcher_log_goes_through_the_helper(self):
        c = read('dm/mac/launcher.c')
        self.assertIn('#include "log_redirect.h"', c)
        self.assertIn('dm_log_redirect(log, 0644, STDOUT_FILENO)', body(c, 'static void log_open(const char *log) {'))
        m = body(c, 'int main(int argc, char **argv) {')
        self.assertEqual(m.count('log_open(log);'), 1)
        self.assertIsNone(re.search(r'dup2\([^)]*,\s*(1|2|STDOUT_FILENO|STDERR_FILENO)\)', m))   # no redirect of its own beside the helper's
        self.assertIn("'host/log_redirect.h'", read('dm/mac/pack_app.py'))   # in the app's reuse key: a change to it builds the launcher again

    def test_helper_never_leaves_a_standard_descriptor_free(self):
        h = body(read('dm/host/log_redirect.h'), 'static inline int dm_log_redirect(const char *path, mode_t mode, int first) {')
        self.assertNotIn('O_CLOEXEC', h)   # the Mac's host inherits 1 and 2
        self.assertIn('if (fd > STDERR_FILENO) close(fd);', h)   # its own descriptor only
        self.assertLess(h.index('open("/dev/null"'), h.index('open(path,'))   # closed standard descriptors filled first, so the log's own is above 2
        self.assertIn('log-redirect', read('dm/host/tests/Makefile').split('\nrun:', 1)[1])


class CloudScope(unittest.TestCase):
    def test_each_started_scope_is_stopped_once(self):
        m = read('dm/ios/Sources/CloudSaves.m')
        hold = body(m, 'static void scope_hold(NSURL *url) {')
        self.assertLess(hold.index('stopAccessingSecurityScopedResource'), hold.index('startAccessingSecurityScopedResource'))   # the old folder's stopped before the new one's starts
        self.assertIn('[opened.path isEqualToString:url.path]) return;', hold)   # the same folder keeps the URL that started it
        path = body(m, 'NSString *dm_cloud_saves_path(BOOL *stale) {')
        self.assertNotIn('startAccessingSecurityScopedResource', path); self.assertNotIn('opened =', path)   # only through scope_hold
        self.assertIn('scope_hold(url);', path)
        unresolved = path[path.index('if (!url) {'):path.index('scope_hold(url);')]
        self.assertIn('scope_hold(nil);', unresolved)   # a bookmark that no longer resolves: cloud saves are off, the scope is stopped
        self.assertIn('scope_hold(nil);', body(m, 'void dm_clear_cloud_saves(void) {'))
        fresh = body(m, 'static NSData *fresh_bookmark(NSURL *url) {')
        self.assertEqual(fresh.count('startAccessingSecurityScopedResource'), 1); self.assertIn('if (scoped) [url stopAccessingSecurityScopedResource];', fresh)


@unittest.skipUnless(sys.platform == 'darwin', 'Foundation required')
class IPhoneLogOpen(unittest.TestCase):
    """main.m's log_open, as written, in a program that then opens a stand-in save and writes through the stream stderr and descriptor 2"""
    @classmethod
    def setUpClass(cls):
        cls.tools = tempfile.TemporaryDirectory(); cls.addClassCleanup(cls.tools.cleanup)
        root = Path(cls.tools.name)
        main = read('dm/ios/Sources/main.m')
        fn = main[main.index('// Documents/log.txt onto descriptor 2'):main.index('static int boot_env(void) {')]
        source = root / 'log_open.m'
        source.write_text('#import <Foundation/Foundation.h>\n#include <fcntl.h>\n#include <stdio.h>\n#include <string.h>\n#include <unistd.h>\n#include "log_redirect.h"\n' + fn +
                          'int main(int argc, char **argv) { @autoreleasepool { if (argc < 3) return 2;\n'
                          '    log_open(@(argv[1]));\n'
                          '    int save = open(argv[2], O_WRONLY | O_CREAT | O_TRUNC, 0644);\n'
                          '    fprintf(stderr, "a line through the stream\\n"); (void)!write(2, "a line through descriptor 2\\n", 28);\n'
                          '    (void)!write(save, "save", 4); close(save);\n'
                          '    return save > 2 ? 0 : 3; }}\n')
        cls.program = root / 'log_open'
        subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Werror', '-I', str(REPO / 'dm/host'), str(source), '-framework', 'Foundation', '-o', str(cls.program)], check=True)

    def run_it(self, log, save, close_2):
        cmd = [str(self.program), str(log), str(save)]
        if close_2: cmd = ['/bin/sh', '-c', 'exec "$@" 2>&-', 'sh', *cmd]
        return subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    def test_log_that_cannot_be_created_with_descriptor_2_closed(self):
        with tempfile.TemporaryDirectory() as t:
            save = Path(t) / 'save.bin'
            r = self.run_it(Path(t) / 'no such folder/log.txt', save, close_2=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(save.read_bytes(), b'save')   # the log lines went to /dev/null, not into the save

    def test_log_that_cannot_be_created_leaves_stderr_where_it_was(self):
        with tempfile.TemporaryDirectory() as t:
            r = self.run_it(Path(t) / 'no such folder/log.txt', Path(t) / 'save.bin', close_2=False)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertIn('cannot be written', r.stderr); self.assertIn('a line through descriptor 2', r.stderr)

    def test_log_with_descriptor_2_closed(self):
        with tempfile.TemporaryDirectory() as t:
            log, save = Path(t) / 'log.txt', Path(t) / 'save.bin'
            log.write_text('the previous run\n')
            r = self.run_it(log, save, close_2=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(save.read_bytes(), b'save')
            text = log.read_text()
            self.assertIn('a line through the stream', text); self.assertIn('a line through descriptor 2', text); self.assertNotIn('previous run', text)


if __name__ == '__main__':
    unittest.main()
