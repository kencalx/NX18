"""The Mac app's Game guide (dm/mac/Launcher.swift MacGuideWindow): compile the settings window with mac_guide_check.swift and load a guide folder written here into its web view.
The guide's pages read their other files with XMLHttpRequest and fetch and call window.nx, which a browser opening them from file: URLs refuses or lacks; the window serves them
through nx18guide:// with the shim, as the iPhone's GuideViewer.swift does (LauncherGuideFiles.swift). No window is shown and nothing goes to the network."""
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]

INDEX = '<!doctype html><html><head><meta charset="utf-8"><script src="../../js/app.js"></script></head><body>guide</body></html>\n'
SCRIPT = r"""
var out = {nx: typeof window.nx};
try { nx.footer.setAssign('B', '', function () {}); nx.playSystemSe('SeBtnDecide'); out.footer = 'ok'; } catch (e) { out.footer = 'threw ' + e; }
var x = new XMLHttpRequest();
x.open('GET', '../../data/text.json');
x.onload = function () { out.xhr = x.status + ':' + x.responseText.trim(); next(); };
x.onerror = function () { out.xhr = 'error'; next(); };
x.send();
function next() {
  fetch('page2.html').then(function (r) { return r.text(); }).then(function (t) { out.fetch = t.indexOf('second page') >= 0 ? 'ok' : 'wrong'; }, function (e) { out.fetch = 'error ' + e; })
  .then(function () { return fetch('../../link.txt').then(function (r) { out.link = r.status; }, function () { out.link = 'error'; }); })
  .then(function () { return fetch('file:///etc/hosts').then(function () { out.file = 'loaded'; }, function () { out.file = 'refused'; }); })
  .then(function () { window.__result = JSON.stringify(out); });
}
"""


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain and WebKit')
class MacGuideTests(unittest.TestCase):
    def test_guide_pages_read_their_files_offline(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp = Path(tmp)
            htdocs = tmp / 'html-document/htmlcontents.htdocs'
            for rel, text in (('html/USen/index.html', INDEX), ('html/USen/page2.html', '<p>second page</p>\n'), ('js/app.js', SCRIPT), ('data/text.json', '{"text":"sibling"}\n')):
                (htdocs / rel).parent.mkdir(parents=True, exist_ok=True); (htdocs / rel).write_text(text)
            (tmp / 'outside.txt').write_text('outside the guide\n')
            (htdocs / 'link.txt').symlink_to(tmp / 'outside.txt')   # inside the folder by name, outside it on disk
            exe = tmp / 'mac_guide_check'
            sources = [REPO / 'dm/ios/Sources/LauncherSettings.swift', REPO / 'dm/ios/Sources/LauncherRow.swift', REPO / 'dm/mac/Launcher.swift',
                       REPO / 'dm/ios/Sources/LauncherGuideFiles.swift', REPO / 'dm/ios/Sources/NXFont.swift', Path(__file__).with_name('mac_guide_check.swift')]
            c = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '5', '-parse-as-library', '-module-cache-path', str(tmp / 'module-cache'),
                                '-o', str(exe), *map(str, sources)], capture_output=True, text=True, timeout=300)
            self.assertEqual(c.returncode, 0, c.stdout + c.stderr)
            r = subprocess.run([str(exe), str(htdocs)], capture_output=True, text=True, timeout=120)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('mac guide: 0 failed', r.stdout)


if __name__ == '__main__':
    unittest.main()
