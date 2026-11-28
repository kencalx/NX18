"""Log privacy in nvn_mtl.m (code check 2026-11-28 #19): the start lines that name the prewarm lists, the pipeline archive folder, the bundled archive, Metal's build
folders and the shader library folder give the file or folder by its last component (log_tail), not its whole path: /Users/<account> on a Mac, the app container's
UUID on iOS. A source check: every MLOG line about those files is read, and none may print an NSString path's UTF8String or the crash guard's C path whole."""
from pathlib import Path
import re
import unittest

SRC = Path(__file__).resolve().parents[1] / 'nvn' / 'nvn_mtl.m'
# the lines about these files (an MLOG call and its continuation lines up to the closing ");")
TOPICS = re.compile(r'pipeline prewarm|prewarm list|pipeline archive|pipeline prepare: every line|pipeline prebuild: %d shader pairs|readable-tile version|shader route B|shader librar|metallib')
# a path printed whole: an NSString path variable's UTF8String, or the crash guard's C path
WHOLE = re.compile(r'\b(?:path|p|pp|pp2|image|seed|user|gd|g_arch_dir|g_msl_dir)\.UTF8String\b|(?<!log_tail_c\()g_psg\.path\b')


def mlog_calls(text):
    """Each MLOG call's text, from MLOG( to the end of its statement (a call may run over several lines)."""
    for m in re.finditer(r'\bMLOG\(', text):
        depth, i = 0, m.end() - 1
        while i < len(text):
            c = text[i]
            if c == '"':   # skip a string literal
                i += 1
                while text[i] != '"': i += 2 if text[i] == '\\' else 1
            elif c == '(':
                depth += 1
            elif c == ')':
                depth -= 1
                if not depth: break
            i += 1
        yield text.count('\n', 0, m.start()) + 1, text[m.start():i + 1]


class LogPaths(unittest.TestCase):
    def setUp(self):
        self.text = SRC.read_text()

    def test_helper(self):
        self.assertIn('static const char *log_tail(NSString *p) { return p.lastPathComponent.UTF8String ?: ""; }', self.text)

    def test_start_lines_give_last_component(self):
        calls = [(n, c) for n, c in mlog_calls(self.text) if TOPICS.search(c)]
        self.assertGreater(len(calls), 30)   # the parser found the lines
        bad = [f'nvn_mtl.m:{n}: {c[:140]}' for n, c in calls if WHOLE.search(c)]
        self.assertEqual(bad, [], 'start lines that print a whole path')

    def test_named_lines(self):
        for line in ('MLOG("pipeline prewarm list %s: %lu lines", log_tail(path), nl);',
                     'user ? log_tail(user) : "");',
                     'MLOG("[RED] pipeline prewarm: seed list does not exist: %s", log_tail(seed));',
                     'metallib directory %s", (unsigned long)g_shmap.count, log_tail(path), log_tail(g_msl_dir));',
                     'opened in %.1f ms", log_tail(g_arch_dir),',
                     '%d workers (%s)", n, log_tail(pp), txt2 ? " and " : "", txt2 ? log_tail(pp2) : "",'):   # the prebuild's pair lists: on iOS in the app bundle, outside HOME
            self.assertIn(line, self.text)


if __name__ == '__main__':
    unittest.main()
