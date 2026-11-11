"""The UI font (the NSP script's --ui-font / UI_FONT) is the player's own file and never part of the repository: no font that names a console maker's or console's UI font
(by its path or its name records) is tracked or about to be added, no tracked text names such a font, local/ (where one may be kept in a checkout) is ignored, and the build refuses a
font inside the checkout that git does not ignore. The text NX 18 draws goes through one place per language: NXFont.swift (SwiftUI) and dm/host/ui_font.h (UIKit, AppKit, CoreText).
Every font used here is made by the test with fontTools' FontBuilder."""
import importlib.util
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
FONT_SUFFIXES = ('.ttf', '.otf', '.ttc', '.woff', '.woff2', '.dfont')
FONT_MAGIC = (b'\x00\x01\x00\x00', b'OTTO', b'true', b'ttcf', b'wOFF', b'wOF2')
PRIVATE = re.compile(r'nintendo|switch', re.I)
NAME_IDS = (1, 4, 6, 16, 21)   # family, full name, PostScript name, typographic family, WWS family
HAS_FONTTOOLS = importlib.util.find_spec('fontTools') is not None


def checkout_files():
    """Tracked files and new files git would add (not ignored), relative to the checkout"""
    out = subprocess.run(['git', 'ls-files', '-z', '-co', '--exclude-standard'], cwd=REPO, capture_output=True, check=True).stdout
    return sorted({p for p in out.decode('utf-8', 'surrogateescape').split('\0') if p})


def font_files():
    """The files that are fonts: by their suffix, or by their first bytes (a font under another name)"""
    found = []
    for rel in checkout_files():
        p = REPO / rel
        if not p.is_file() or p.is_symlink(): continue
        if p.suffix.lower() in FONT_SUFFIXES: found.append(rel); continue
        try:
            with open(p, 'rb') as f: head = f.read(4)
        except OSError: continue
        if head in FONT_MAGIC: found.append(rel)
    return found


def make_font(path, family='NX Test UI', ps='NXTestUI-Regular'):
    """A small TrueType font (one glyph) with these names"""
    from fontTools.fontBuilder import FontBuilder
    from fontTools.pens.ttGlyphPen import TTGlyphPen
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(['.notdef', 'A'])
    fb.setupCharacterMap({0x41: 'A'})
    pen = TTGlyphPen(None); pen.moveTo((100, 0)); pen.lineTo((500, 700)); pen.lineTo((900, 0)); pen.closePath()
    fb.setupGlyf({'.notdef': TTGlyphPen(None).glyph(), 'A': pen.glyph()})
    fb.setupHorizontalMetrics({'.notdef': (500, 0), 'A': (1000, 100)})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({'familyName': family, 'styleName': 'Regular', 'psName': ps})
    fb.setupOS2(sTypoAscender=800, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    fb.save(str(path))
    return path


class NoPrivateFonts(unittest.TestCase):
    def test_no_font_named_for_a_console_is_tracked_or_added(self):
        bad = [rel for rel in font_files() if PRIVATE.search(rel)]
        self.assertEqual(bad, [], 'a font file whose path names Nintendo or Switch is tracked or about to be added: keep it outside the repository (or in local/, which git ignores)')

    @unittest.skipUnless(HAS_FONTTOOLS, 'needs fontTools')
    def test_no_tracked_font_has_such_a_name(self):
        from fontTools.ttLib import TTCollection, TTFont
        bad = []
        for rel in font_files():
            p = REPO / rel
            try:
                with open(p, 'rb') as f: coll = f.read(4) == b'ttcf'
                fonts = TTCollection(str(p), lazy=True).fonts if coll else [TTFont(str(p), lazy=True)]
            except Exception: continue   # not a font after all (four bytes that happen to match)
            for font in fonts:
                names = font['name'] if 'name' in font else None
                for nid in NAME_IDS:
                    v = names.getDebugName(nid) if names else None
                    if v and PRIVATE.search(v): bad.append(f'{rel}: name ID {nid}')
        self.assertEqual(bad, [], 'a tracked font names Nintendo or Switch in its name table')

    def test_no_tracked_text_names_the_font(self):
        # the font's names, written in two parts so this file does not match itself
        words = ['Nintendo' + 'SwitchUI', 'Nintendo ' + 'Switch UI', 'Nintendo_' + 'Switch_UI', 'NINTENDO' + 'SWITCHUI']
        args = ['git', 'grep', '-I', '-l', '-i', '--untracked']
        for w in words: args += ['-e', w]
        r = subprocess.run(args, cwd=REPO, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, f'a tracked or new file names the UI font; examples and docs stay generic: {r.stdout.split()}')

    def test_local_folder_is_ignored(self):
        for rel in ('local/fonts/MyUIFont.ttf', 'local/x.otf', 'scripts/MyUIFont.private.ttf'):
            with self.subTest(rel=rel):
                r = subprocess.run(['git', 'check-ignore', '-q', '--no-index', rel], cwd=REPO)
                self.assertEqual(r.returncode, 0, f'.gitignore does not ignore {rel}')

    def test_release_script_names_no_font(self):   # the public release script: an empty setting with a generic example, passed on as --ui-font
        sh = (REPO / 'scripts/release/nx18-build.sh').read_text()
        self.assertIn('\nUI_FONT=""\n', sh)
        self.assertIn('UI_FONT="${NX18_UI_FONT:-$UI_FONT}"', sh)
        self.assertIn('[ -n "$UI_FONT" ] && ARGS+=(--ui-font "$UI_FONT")', sh)
        nsp = (REPO / 'scripts/build_ipa_from_nsp.py').read_text()
        self.assertRegex(nsp, r"\nUI_FONT = ''\s+#")


class OneFontPath(unittest.TestCase):
    """NX 18's text names its fonts only through NXFont.swift and dm/host/ui_font.h; what stays on the system font is tagged or listed here"""
    SWIFT = re.compile(r'\.font\(\s*\.|Font\.system|\.system\(size:|font:\s*\.system')
    OBJC = re.compile(r'systemFontOfSize|monospacedDigitSystemFontOfSize|boldSystemFontOfSize|monospacedSystemFontOfSize|kCTFontUIFont\w+|CTFontCreateUIFontForLanguage')
    OBJC_KEPT = ('_details.font = [NSFont monospacedSystemFontOfSize',)   # the Cheats window's details: code and hex, in a monospaced font

    def test_swift_text_styles_go_through_nxfont(self):
        files = sorted((REPO / 'dm/ios/Sources').glob('*.swift')) + sorted((REPO / 'dm/mac').glob('*.swift'))
        bad = []
        for p in files:
            if p.name == 'NXFont.swift': continue
            for n, ln in enumerate(p.read_text().splitlines(), 1):
                if self.SWIFT.search(ln) and '// system: symbol' not in ln: bad.append(f'{p.relative_to(REPO)}:{n}: {ln.strip()}')
        self.assertEqual(bad, [], 'a system font outside NXFont.swift: use .nxFont(...) / NXFont, or tag an SF Symbol\'s size "// system: symbol"')

    def test_objc_fonts_go_through_ui_font_h(self):
        files = [p for d in ('dm/ios/Sources', 'dm/host', 'dm/mac') for p in sorted((REPO / d).iterdir()) if p.suffix in ('.m', '.h', '.c') and p.name != 'ui_font.h']
        bad = []
        for p in files:
            for n, ln in enumerate(p.read_text(errors='replace').splitlines(), 1):
                if self.OBJC.search(ln) and not any(k in ln for k in self.OBJC_KEPT): bad.append(f'{p.relative_to(REPO)}:{n}: {ln.strip()}')
        self.assertEqual(bad, [], 'a system font outside dm/host/ui_font.h: use dm_ui_font / dm_ui_mono_digits / dm_ui_ctfont')

    def test_every_swift_list_compiles_nxfont(self):   # the Mac app's launcher and the tests that build it list their Swift sources by name
        for rel in ('dm/mac/pack_app.py', 'dm/ios/tests/test_launcher_storage.py', 'dm/ios/tests/test_mac_guide.py', 'dm/ios/tests/duo/project.yml'):
            with self.subTest(rel=rel): self.assertIn('NXFont.swift', (REPO / rel).read_text())

    def test_ui_font_is_not_the_games_shared_font_folder(self):   # dm/font holds the game's shared-font stand-ins (hle_sdk16.c reads every file there)
        for rel in ('dm/ios/tools/build_ipa.sh', 'dm/mac/pack_app.py', 'dm/host/ui_font.h'):
            with self.subTest(rel=rel):
                text = (REPO / rel).read_text()
                self.assertIn('dm/uifont', text); self.assertNotRegex(text, r'dm/font/ui\.')


@unittest.skipUnless(HAS_FONTTOOLS and shutil.which('git'), 'needs fontTools and git')
class UiFontInfo(unittest.TestCase):
    """build_ipa_from_nsp.py ui_font_info: the checks --ui-font / UI_FONT gets before the extraction"""
    @classmethod
    def setUpClass(cls):
        spec = importlib.util.spec_from_file_location('build_ipa_from_nsp_fonts', REPO / 'scripts/build_ipa_from_nsp.py')
        assert spec and spec.loader
        cls.nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(cls.nsp)

    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix='ui-font-')).resolve(); self.addCleanup(shutil.rmtree, self.tmp)
        self.repo = self.tmp / 'checkout'; self.repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        shutil.copyfile(REPO / '.gitignore', self.repo / '.gitignore')   # the checkout's own rules

    def info(self, p): return self.nsp.ui_font_info(str(p), self.repo)

    def test_a_font_outside_the_checkout(self):
        f = make_font(self.tmp / 'My UI.TTF')
        path, ps, family = self.info(f)
        self.assertEqual((path, ps, family), (f, 'NXTestUI-Regular', 'NX Test UI'))

    def test_a_collection_takes_its_first_face(self):
        from fontTools.ttLib import TTCollection, TTFont
        a, b = make_font(self.tmp / 'a.ttf'), make_font(self.tmp / 'b.ttf', 'Other UI', 'OtherUI-Regular')
        c = TTCollection(); c.fonts = [TTFont(str(a)), TTFont(str(b))]; c.save(str(self.tmp / 'ui.ttc'))
        self.assertEqual(self.info(self.tmp / 'ui.ttc')[1:], ('NXTestUI-Regular', 'NX Test UI'))

    def test_what_is_refused(self):
        BuildError = self.nsp.BuildError
        with self.assertRaisesRegex(BuildError, r'no such UI font file \(--ui-font / UI_FONT\)'): self.info(self.tmp / 'missing.ttf')
        (self.tmp / 'notes.txt').write_text('a font?')
        with self.assertRaisesRegex(BuildError, 'must be a .ttf, .otf or .ttc file'): self.info(self.tmp / 'notes.txt')
        png = self.tmp / 'picture.ttf'; png.write_bytes(b'\x89PNG\r\n\x1a\n' + b'\0' * 64)
        with self.assertRaisesRegex(BuildError, 'is not a TrueType or OpenType font'): self.info(png)
        broken = self.tmp / 'broken.otf'; broken.write_bytes(b'OTTO' + b'\0' * 8)
        with self.assertRaisesRegex(BuildError, 'cannot be read'): self.info(broken)
        noname = make_font(self.tmp / 'noname.ttf', ps='Bad Name')   # a space: no PostScript name the apps can look it up by
        with self.assertRaisesRegex(BuildError, 'no usable PostScript name'): self.info(noname)

    def test_inside_the_checkout_only_where_git_ignores_it(self):
        (self.repo / 'dm').mkdir()
        tracked = make_font(self.repo / 'dm/MyUI.ttf')
        with self.assertRaisesRegex(self.nsp.BuildError, 'inside the checkout where git would track it'): self.info(tracked)
        (self.repo / 'local/fonts').mkdir(parents=True)
        ok = make_font(self.repo / 'local/fonts/MyUI.ttf')
        self.assertEqual(self.info(ok)[1], 'NXTestUI-Regular')

    def test_option_and_setting(self):
        a = self.nsp.parse_args(['/games/x'])
        self.assertIsNone(a.ui_font)   # the UI_FONT setting decides (empty: the system font)
        self.assertEqual(self.nsp.parse_args(['/games/x', '--ui-font', '~/f.ttf']).ui_font, '~/f.ttf')
        self.assertEqual(self.nsp.UI_FONT, '')


if __name__ == '__main__':
    unittest.main()
