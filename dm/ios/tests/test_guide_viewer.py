"""The game guide viewer's pieces without a simulator (dm/ios/Sources/GuideViewer.swift, LauncherGuideFiles.swift, dm/mac/Launcher.swift MacGuideWindow, dm/host/web_apple.m).

The console's guides are 1280x720 pages driven by the Switch browser: they cancel every touch when window.nx exists (so WebKit sends no click), wait for NXFirstPaintEndAfterLoad
before setting up, put Back and page turning on nx.footer.setAssign, and end by going to http://localhost/. These checks keep what the viewers do about it in place: the shims'
first paint, tap fallback and footer registry (and that their JavaScript parses), the fitted 1280x720 layout, the end URL, the controller routing and the placeholder guide fixture.
The page itself is run by dm/ios/tests/duo (DuoGuideTests: the iPhone, in the Simulator) and test_mac_guide.py (the Mac)."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SRC = REPO / 'dm/ios/Sources'
FIXTURE = REPO / 'dm/ios/tests/fixtures/guide'


def swift_shim():
    """The launcher shim's JavaScript, as the Swift string literal gives it."""
    s = (SRC / 'LauncherGuideFiles.swift').read_text()
    m = re.search(r'static let shim = """\n(.*?)\n\s*"""', s, re.S)
    assert m, 'no shim in LauncherGuideFiles.swift'
    return m.group(1).replace('\\\\', '\\')


def host_shim():
    s = (REPO / 'dm/host/web_apple.m').read_text()
    return s[s.index('@R"JS(') + 6:s.index(')JS"')]


class GuideViewerTests(unittest.TestCase):
    def test_shims_do_what_the_console_browser_does(self):
        for name, js in (('launcher', swift_shim()), ('host', host_shim())):
            with self.subTest(name):
                self.assertIn("new Event('NXFirstPaintEndAfterLoad')", js, 'the first paint the guides wait for')
                self.assertIn('elementFromPoint', js, 'a tap the page cancelled is clicked')
                self.assertIn('defaultPrevented', js)
                self.assertIn("addEventListener('touchend'", js)
                self.assertIn('setAssign: function (b, label, fn)', js, 'the footer buttons are kept')
                self.assertIn('elementsFromPoint', js, 'a tap is for what shows there, under invisible stacked pages')
                self.assertIn("st.opacity === '0'", js)
                self.assertIn("new FocusEvent(type", js, 'focus and blur events WebKit does not send in a view that is not focused')
                self.assertIn("HTMLElement.prototype[m] = function", js)
                self.assertIn('if (e.persisted) location.reload()', js, 'a page back from the back-forward cache is loaded again')
        js = swift_shim()
        self.assertIn("post('nx18State'", js, 'the launcher hears the footer buttons')
        self.assertIn('__nx18 = {', js)
        for k in ('footer:', 'key:', 'a:'):
            self.assertIn(k, js)
        self.assertIn('data-dm-focus', js, ':focus mirrored')

    @unittest.skipUnless(sys.platform == 'darwin' and shutil.which('osascript'), 'needs JavaScriptCore (osascript -l JavaScript)')
    def test_shims_parse(self):
        for name, js in (('launcher', swift_shim()), ('host', host_shim())):
            with self.subTest(name), tempfile.TemporaryDirectory() as tmp:
                f = Path(tmp) / 'shim.js'
                f.write_text(js)
                r = subprocess.run(['osascript', '-l', 'JavaScript', '-e', 'ObjC.import("Foundation");'
                                    f'var s = $.NSString.stringWithContentsOfFileEncodingError({str(f)!r}, 4, null).js;'
                                    'try { new Function(s); "parsed" } catch (e) { "error " + e }'], capture_output=True, text=True, timeout=60)
                self.assertEqual(r.stdout.strip(), 'parsed', r.stdout + r.stderr)

    def test_offline_protections_stay(self):
        s = (SRC / 'LauncherGuideFiles.swift').read_text()
        self.assertIn('static let policy = "default-src nx18guide: data: blob:', s)
        self.assertIn('"^https?:", "^wss?:", "^ftp:", "^file:"', s, 'the block list')
        self.assertIn('if isEnd(url)', s)
        end = s[s.index('static func isEnd'):s.index('enum Navigation')]
        self.assertIn('scheme == "http" || scheme == "https"', end, 'only the web localhost is the end')
        self.assertIn('== "localhost"', end)
        for f in (SRC / 'GuideViewer.swift', REPO / 'dm/mac/Launcher.swift'):
            t = f.read_text()
            self.assertIn('LauncherGuideFiles.navigation(action.request.url)', t, f'{f.name}: the end and the refusals')
            self.assertIn('case .end: close(); return .cancel', t, f'{f.name}: the end closes and loads nothing')
            self.assertNotIn('LauncherGuideFiles.allows(action.request.url) ? .allow', t)

    def test_page_is_fitted_at_the_console_size(self):
        g = (SRC / 'GuideViewer.swift').read_text()
        self.assertIn('web.bounds = CGRect(origin: .zero, size: size)', g, 'laid out at 1280x720')
        self.assertIn('CGAffineTransform(scaleX: r.width / size.width, y: r.height / size.height)', g, 'and scaled')
        self.assertIn('UIScreenEdgePanGestureRecognizer', g, 'the swipe back')
        self.assertIn('UISwipeGestureRecognizer', g, 'a swipe across the page turns it')
        self.assertIn('swipe.require(toFail: edge)', g)
        self.assertIn('circleButton("chevron.backward", label: "Back", glyph: closeGlyph)', g, 'the header Back, with B beside it as B goes back there')
        self.assertIn('glyph: (onGuide && model.hasBack) ? nil : closeGlyph', g, 'B beside Close only when nothing is left to go back to')
        self.assertIn('sv.bounces = false', g)
        m = (REPO / 'dm/mac/Launcher.swift').read_text()
        self.assertIn('web.pageZoom = zoom', m)
        self.assertIn('w.contentAspectRatio = LauncherGuideFiles.pageSize', m)
        s = (SRC / 'LauncherGuideFiles.swift').read_text()
        self.assertIn('static let pageSize = CGSize(width: 1280, height: 720)', s)

    def test_controller_reaches_the_page(self):
        launcher = (SRC / 'Launcher.swift').read_text()
        self.assertIn('if scroller.pad?(e) == true { return }', launcher, 'the open guide takes its buttons first')
        c = (SRC / 'LauncherController.swift').read_text()
        self.assertIn('case up, down, left, right, a, b, x, y, plus, minus, l, r, zl, zr', c)
        self.assertIn('g.leftTrigger.isPressed', c)
        g = (SRC / 'GuideViewer.swift').read_text()
        for e, act in (('.b', 'back()'), ('.l', 'press("L")'), ('.r', 'press("R")'), ('.a', 'pressA()'), ('.down', 'key(40)')):
            self.assertIn(f'case {e}: {act}', g)

    def test_placeholder_guide_is_made_up_and_shaped_like_a_console_guide(self):
        htdocs = FIXTURE / 'html1/html-document/htmlcontents.htdocs'
        index = htdocs / 'html/USen/index.html'
        self.assertTrue(index.is_file(), 'where a game guide sits in an app')
        page = index.read_text()
        self.assertIn('width=device-width,height=device-height,user-scalable=no', page)
        self.assertIn('href="javascript:void(0)"', page, 'menu items that act through onclick only')
        js = (htdocs / 'js/guide.js').read_text()
        self.assertIn('onfocus="preview(1)"', page, 'items that act on their focus')
        self.assertIn('class="later-page"', page, 'an invisible page stacked over the menu')
        for needle in ("document.body.className = 'is-leaving'", 'if (i < 0) return;', 'e.preventDefault()', "addEventListener('NXFirstPaintEndAfterLoad'", "nx.footer.setAssign('B'", "nx.footer.setAssign('L'", "' http://localhost/ '", 'nx.endApplet()'):
            self.assertIn(needle, js)
        css = (htdocs / 'css/guide.css').read_text()
        self.assertIn('width: 1280px; height: 720px;', css)
        names = re.compile(r'mario|luigi|zelda|kart|nintendo|odyssey|mansion|copyright|©', re.I)
        for f in FIXTURE.rglob('*'):
            if f.is_file():
                self.assertLess(f.stat().st_size, 8000, f'{f}: a small made-up file')
                self.assertIsNone(names.search(f.read_text(errors='replace')), f'{f}: no game content')


if __name__ == '__main__':
    unittest.main()
