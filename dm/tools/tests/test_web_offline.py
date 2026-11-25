"""Offline HTML pages reach nothing on the internet (dm/host/web_apple.m offline_rules, docs/reference/services.md, "An offline HTML page could load from the internet").

The content rule list as WebKit reads it (a JSON array of triggers and actions, url-filter a regular expression matched against the whole URL, letter case ignored): it
blocks every http(s) and ws(s) URL and nothing a page is served from (dmweb://, data:, blob:, about:). The page's first load waits for the list, the page's end at its
callback URL stays with the navigation delegate, and DM_WEB_OFFLINE_RULES=0 leaves the list out. On a Mac, WebKit itself compiles the list."""
from pathlib import Path
import codecs
import json
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
WEB = REPO / 'dm/host/web_apple.m'


def rules_text(src):
    """OFFLINE_RULES's value: its adjacent Objective-C string literals joined, C escapes undone"""
    decl = src[src.index('static NSString *const OFFLINE_RULES = '):]
    decl = decl[:decl.index(';\n')]
    return ''.join(codecs.decode(m, 'unicode_escape') for m in re.findall(r'"((?:[^"\\]|\\.)*)"', decl))


def body(src, head):
    i = src.index(head) + len(head)
    return src[i:src.index('\n}\n', i)]


class Rules(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.src = WEB.read_text()
        cls.rules = json.loads(rules_text(cls.src))

    def blocked(self, url):
        return any(r['action'] == {'type': 'block'} and re.search(r['trigger']['url-filter'], url, re.I) for r in self.rules)

    def test_rules_block_every_internet_load(self):
        for r in self.rules:
            self.assertEqual(set(r), {'trigger', 'action'}); self.assertEqual(set(r['trigger']), {'url-filter'})   # every resource type, every frame
        for url in ('http://localhost/', 'https://example.com/pixel.gif', 'HTTPS://example.com/a.js', 'ws://example.com/socket', 'wss://example.com:443/s',
                    'http://127.0.0.1:8080/collect?x=1'):
            self.assertTrue(self.blocked(url), url)

    def test_rules_leave_the_document_alone(self):
        for url in ('dmweb://doc/launcher_pause_menu.htdocs/index.html', 'dmweb://doc/__dm_font/nintendo_ext.ttf', 'data:image/png;base64,AAAA',
                    'blob:dmweb://doc/1234', 'about:blank', 'dmweb://doc/http://not-a-scheme'):
            self.assertFalse(self.blocked(url), url)

    def test_first_load_waits_for_the_rules(self):
        open_ = body(self.src, 'int front_web_open(const char *dir, const char *path, const char *callback, int hidden, const dm_web_opts *opts) {')
        self.assertEqual(self.src.count('loadRequest:'), 1)   # the page's one load, inside the rules' then()
        self.assertRegex(open_, r'offline_rules\(box\.web\.configuration\.userContentController, \^\{ if \(g_box == box && !box\.closed\) \[box\.web loadRequest:req\]; \}\);')
        self.assertIn('q ?: @""', open_); self.assertIn('NOLINT(clang-analyzer-nullability.NullablePassedToNonnull)', open_)
        rules = body(self.src, 'static void offline_rules(WKUserContentController *uc, void (^then)(void)) {')
        self.assertEqual(rules.count('then();'), 3)   # switched off, compiled before, compiled now or failed: the page always loads
        self.assertIn('addContentRuleList:g_offline_rules', rules); self.assertIn('dispatch_get_main_queue()', rules)
        self.assertIn('getenv("DM_WEB_OFFLINE_RULES")', rules)

    def test_page_end_is_decided_before_any_load(self):
        nav = body(self.src, '- (void)webView:(WKWebView *)wv decidePolicyForNavigationAction:(WKNavigationAction *)a decisionHandler:(void (^)(WKNavigationActionPolicy))done {')
        self.assertLess(nav.index('[u hasPrefix:_callback]'), nav.index('WKNavigationActionPolicyAllow'))

    def test_switch_is_documented(self):
        rows = dict(ln.split('\t')[:2] for ln in (REPO / 'docs/env_switches.tsv').read_text().splitlines()[1:])
        self.assertEqual(rows.get('DM_WEB_OFFLINE_RULES'), 'switch')


@unittest.skipUnless(sys.platform == 'darwin', 'WebKit required')
class WebKitCompiles(unittest.TestCase):
    def test_webkit_compiles_the_list(self):
        rules = rules_text(WEB.read_text())
        with tempfile.TemporaryDirectory() as t:
            src = Path(t) / 'rules.m'
            src.write_text('#import <WebKit/WebKit.h>\n#include <stdio.h>\n'
                           'int main(int argc, char **argv) { @autoreleasepool { if (argc < 2) return 2;\n'
                           '    __block int done = 0, ok = 0;\n'
                           '    WKContentRuleListStore *store = [WKContentRuleListStore storeWithURL:[NSURL fileURLWithPath:@(argv[1]) isDirectory:YES]];\n'
                           '    [store compileContentRuleListForIdentifier:@"dm-offline-pages" encodedContentRuleList:@' + json.dumps(rules) +
                           ' completionHandler:^(WKContentRuleList *l, NSError *e) {\n'
                           '        ok = l != nil; if (e) fprintf(stderr, "%s\\n", e.localizedDescription.UTF8String); done = 1; }];\n'
                           '    for (int i = 0; !done && i < 600; i++) [NSRunLoop.mainRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];\n'
                           '    return ok ? 0 : 1; }}\n')
            exe = Path(t) / 'rules'
            subprocess.run(['clang', '-fobjc-arc', '-Wall', '-Werror', str(src), '-framework', 'WebKit', '-framework', 'Foundation', '-o', str(exe)], check=True)
            store = Path(t) / 'store'; store.mkdir()
            r = subprocess.run([str(exe), str(store)], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)


if __name__ == '__main__':
    unittest.main()
