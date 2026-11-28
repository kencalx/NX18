"""Logs a player shares (Share log, bug reports) carry no folder the player chose and no Mac account name: the cloud-save folder is logged by its role (CloudSaves.m, as
dm/mac/launcher.c cloud_saves_folder), the iPhone's cloud copies by the save's file name and an error's domain and code (SaveSync.m), and the Mac launcher's paths under the
home folder as ~ (launcher.c logged_path)."""
from pathlib import Path
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SOURCES = REPO / 'dm/ios/Sources'


def log_calls(text):
    """Each fprintf / fputs call's text, joined across lines up to its closing ');'."""
    out = []
    for m in re.finditer(r'\b(fprintf|fputs)\(', text):
        end = text.find(');', m.end())
        out.append(text[m.start():end + 2])
    return out


class LogPathWiring(unittest.TestCase):
    def test_cloud_saves_logs_the_role(self):
        for call in log_calls((SOURCES / 'CloudSaves.m').read_text()):
            with self.subTest(call=call[:90]):
                for bad in ('.path', 'fileSystemRepresentation', 'localizedDescription'):
                    self.assertNotIn(bad, call, 'a cloud-save log line prints the folder (or an error naming it)')
        text = (SOURCES / 'CloudSaves.m').read_text()
        self.assertIn('"boot: cloud saves through %s\\n", viaNX18 ? "the NX 18 folder" : "this game\'s own folder"', text)

    def test_save_sync_logs_the_file_name(self):
        text = (SOURCES / 'SaveSync.m').read_text()
        for call in log_calls(text):
            with self.subTest(call=call[:90]):
                self.assertNotIn('localizedDescription', call)
                self.assertIsNone(re.search(r'(?:,|(?<!shown)\()\s*(cloud|local)\s*[,)]', call), 'a save sync line prints the full path')

    def test_mac_launcher_paths_go_through_logged_path(self):
        text = (REPO / 'dm/mac/launcher.c').read_text()
        for call in log_calls(text):
            with self.subTest(call=call[:90]):
                self.assertIsNone(re.search(r'(?:,|(?<!logged_path)\()\s*(path|out|log|host|sup|home|save|logs)\s*[,)]', call), 'a launcher line prints a path that may be under the home folder')

    def test_mac_and_ios_swift_lines(self):
        mac = (REPO / 'dm/mac/Launcher.swift').read_text()
        self.assertNotIn('no report on \\(String(cString: save))', mac); self.assertNotIn('game guide \\(page.index.path)\\n', mac); self.assertNotIn('acknowledgements \\(url.path)', mac)
        ios = (SOURCES / 'Launcher.swift').read_text() + (SOURCES / 'GameMenu.swift').read_text()
        self.assertNotIn('no report on \\(String(cString: save))', ios); self.assertNotIn('share log: \\(dir.path)', ios)


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('clang'), 'needs the macOS toolchain')
class LogPathsAtRunTime(unittest.TestCase):
    def test_launcher_logged_path_puts_home_as_tilde(self):
        text = (REPO / 'dm/mac/launcher.c').read_text()
        fn = text[text.index('static const char *logged_path(const char *path)'):text.index('static void env_file(')]
        with tempfile.TemporaryDirectory() as t:
            src = Path(t) / 'shown.c'
            src.write_text('#include <limits.h>\n#include <stdio.h>\n#include <stdlib.h>\n#include <string.h>\n' + fn +
                           'int main(int argc, char **argv) { for (int i = 1; i < argc; i++) puts(logged_path(argv[i])); return 0; }\n')
            exe = Path(t) / 'shown'
            subprocess.run(['clang', '-Wall', '-Werror', str(src), '-o', str(exe)], check=True)
            def run(home, *paths):
                env = {'PATH': '/usr/bin:/bin'}
                if home is not None: env['HOME'] = home
                return subprocess.run([str(exe), *paths], capture_output=True, text=True, env=env, check=True).stdout.splitlines()
            self.assertEqual(run('/Users/pat', '/Users/pat/Library/Logs/nxnative/x.log', '/Users/pat', '/Users/patrick/a', '/Applications/G.app/Contents/MacOS/dmhost'),
                             ['~/Library/Logs/nxnative/x.log', '~', '/Users/patrick/a', '/Applications/G.app/Contents/MacOS/dmhost'])
            self.assertEqual(run('/Users/pat/', '/Users/pat/x'), ['~/x'])
            self.assertEqual(run(None, '/Users/pat/x'), ['/Users/pat/x'])

    def test_save_sync_failure_names_no_folder(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t)
            src = t / 'run.m'
            src.write_text('#import <Foundation/Foundation.h>\nint front_save_sync_store(const char *local, const char *cloud);\nint front_save_sync_fetch(const char *cloud, const char *local);\n'
                           'int main(int argc, char **argv) { @autoreleasepool { printf("%d %d\\n", front_save_sync_store(argv[1], argv[2]), front_save_sync_fetch(argv[3], argv[4])); } return 0; }\n')
            exe = t / 'run'
            subprocess.run(['clang', '-fobjc-arc', '-Wall', '-I', str(REPO / 'dm/host'), str(SOURCES / 'SaveSync.m'), str(src), '-framework', 'Foundation', '-o', str(exe)], check=True)
            chosen = t / 'Pat Example Saves'; chosen.mkdir()
            local = t / 'save.zip'; local.write_bytes(b'save')
            (chosen / 'unreadable.zip').write_bytes(b'x'); os.chmod(chosen / 'unreadable.zip', 0)
            os.chmod(chosen, stat.S_IRUSR | stat.S_IXUSR)   # the copy beside the cloud's file cannot be written
            try:
                r = subprocess.run([str(exe), str(local), str(chosen / 'save.zip'), str(chosen / 'unreadable.zip'), str(t / 'back.zip')], capture_output=True, text=True, timeout=60)
            finally:
                os.chmod(chosen, stat.S_IRWXU); os.chmod(chosen / 'unreadable.zip', stat.S_IRWXU)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(r.stdout.split(), ['0', '-1'])
            self.assertIn('save sync: writing beside save.zip failed: NSCocoaErrorDomain', r.stderr)
            self.assertIn('save sync: copying unreadable.zip from the cloud failed', r.stderr)
            self.assertNotIn('Pat Example', r.stderr); self.assertNotIn(str(t), r.stderr)


if __name__ == '__main__':
    unittest.main()
