"""docs/env_switches.tsv lists every DM_* switch the code reads, each with a class and a meaning (dm/tools/env_switches.py writes it; class and meaning are kept by hand).
A switch the code reads that the table does not list, a row for a switch nothing reads any more, or a row without a meaning fails here."""
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

REPO = Path(__file__).resolve().parents[3]


class EnvSwitches(unittest.TestCase):
    def test_table_is_current_and_complete(self):
        r = subprocess.run([sys.executable, str(REPO / 'dm/tools/env_switches.py'), '--check'], cwd=REPO, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)


    def test_launcher_art_paths(self):   # the launcher's art, logo, About text and manual: paths build_ipa.sh takes once per app (the NSP script's ipa_env), into Gen/dm
        rows = {r.split('\t')[0]: r.split('\t')[1] for r in (REPO / 'docs/env_switches.tsv').read_text().splitlines()[1:] if r}
        sh = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        for name, dst in (('DM_ART', 'Gen/dm/art.jpg'), ('DM_LOGO', 'Gen/dm/logo.png'), ('DM_ABOUT', 'Gen/dm/about.json'), ('DM_MANUAL', 'Gen/dm/manual.pdf')):
            with self.subTest(name=name):
                self.assertEqual(rows.get(name), 'path')
                line = next(ln for ln in sh.splitlines() if ln.startswith(f'if [ -n "${{{name}:-}}" ]'))
                self.assertIn(dst, line)
                self.assertNotIn('$PN', line)   # not per program
        art = sh[sh.index('if [ -n "${DM_ART:-}" ]'):]; art = art[:art.index('; fi\n')]
        self.assertIn('cp "$DM_ART" Gen/dm/art.jpg', art, 'the NSP script\'s art.jpg as it is, no second lossy pass')
        self.assertNotIn('die', art, 'optional art never stops the build')
        logo = sh[sh.index('if [ -n "${DM_LOGO:-}" ]'):]; logo = logo[:logo.index('; fi\n')]
        self.assertIn('cp "$DM_LOGO" Gen/dm/logo.png', logo, 'the NSP script\'s logo.png as it is')
        self.assertIn('fit png 1200 "$DM_LOGO" Gen/dm/logo.png', logo, 'a WebP: a PNG keeping its alpha, at most 1200 a side')
        self.assertIn('fit jpeg 1920 "$DM_ART" Gen/dm/art.jpg', art)
        self.assertNotIn('die', logo, 'an optional logo never stops the build')

    def test_ui_font(self):   # DM_UI_FONT: Gen/dm/uifont/ui.<ext> (never Gen/dm/font, the game's shared fonts), DMUIFontFile / DMUIFontName, and no stale dm/uifont in a later IPA without it
        rows = {r.split('\t')[0]: r.split('\t')[1] for r in (REPO / 'docs/env_switches.tsv').read_text().splitlines()[1:] if r}
        self.assertEqual((rows.get('DM_UI_FONT'), rows.get('DM_UI_FONT_NAME')), ('path', 'switch'))
        sh = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        copy = sh[sh.index('UI_FONT_FILE=\n'):]; copy = copy[:copy.index('\nfi\n') + 4]
        stale = next(ln for ln in sh.splitlines() if ln.startswith('if [ -z "$UI_FONT_FILE" ]; then rm -rf "$APP/dm/uifont"'))
        plist = sh[sh.index('if [ -n "$UI_FONT_FILE" ]; then /usr/libexec/PlistBuddy'):]; plist = plist[:plist.index('; fi\n') + 5]
        self.assertIn('Add :DMUIFontFile string $UI_FONT_FILE', plist); self.assertIn('Add :DMUIFontName string $DM_UI_FONT_NAME', plist)
        self.assertLess(sh.index(stale), sh.index('python3 tools/pack_ipa.py'))
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); (t / 'Gen/dm').mkdir(parents=True); (t / 'My Font.TTF').write_bytes(b'font'); (t / 'notes.txt').write_text('x')
            def run(env, script):
                return subprocess.run(['bash', '-c', 'set -u; t() { echo "$*"; }; die() { echo "FAIL: $*"; exit 1; }\n' + script + '\necho "file=$UI_FONT_FILE"'],
                                      cwd=t, env={'PATH': '/usr/bin:/bin', **env}, capture_output=True, text=True)
            r = run({'DM_UI_FONT': str(t / 'My Font.TTF'), 'DM_UI_FONT_NAME': 'NXTestUI-Regular'}, copy)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr); self.assertIn('file=dm/uifont/ui.ttf', r.stdout)
            self.assertEqual(sorted(p.name for p in (t / 'Gen/dm/uifont').iterdir()), ['ui.ttf']); self.assertFalse((t / 'Gen/dm/font').exists())
            self.assertIn('UI font: NXTestUI-Regular', r.stdout)
            for bad in (str(t / 'missing.ttf'), str(t / 'notes.txt')):
                with self.subTest(bad=bad): self.assertIn('FAIL:', run({'DM_UI_FONT': bad}, copy).stdout)
            r = run({}, copy); self.assertEqual(r.returncode, 0); self.assertIn('file=\n', r.stdout + '\n')
            app = t / 'DmIOS.app'; (app / 'dm/uifont').mkdir(parents=True); (app / 'dm/uifont/ui.ttf').write_bytes(b'old'); (app / 'dm/uifont/ui.otf').write_bytes(b'new')
            run({'APP': str(app)}, f'UI_FONT_FILE=dm/uifont/ui.otf; APP={app}\n{stale}')
            self.assertEqual(sorted(p.name for p in (app / 'dm/uifont').iterdir()), ['ui.otf'])   # the build's own file only
            run({'APP': str(app)}, f'UI_FONT_FILE=; APP={app}\n{stale}')
            self.assertFalse((app / 'dm/uifont').exists())   # an IPA without a UI font carries none

    @unittest.skipUnless(shutil.which('sips'), 'sips is macOS\'s')
    def test_fit_never_enlarges(self):   # build_ipa.sh's fit(): sips -Z also enlarges, so a smaller image keeps its size and a larger one is brought down to the limit
        sh = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        fit = sh[sh.index('fit() {'):]; fit = fit[:fit.index('; }\n') + 3]
        with tempfile.TemporaryDirectory() as t:
            for w, h, want in ((100, 40, '100 40'), (1600, 40, '1200 30')):
                with self.subTest(size=(w, h)):
                    src = Path(t) / f'{w}.png'
                    raw = b''.join(b'\0' + b'\x80\x40\x20\x80' * w for _ in range(h))
                    chunk = lambda k, d: struct.pack('>I', len(d)) + k + d + struct.pack('>I', zlib.crc32(k + d))
                    src.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(raw)) + chunk(b'IEND', b''))
                    r = subprocess.run(['bash', '-c', f'set -u; {fit}\nfit png 1200 "$1" "$2" && sips -g pixelWidth -g pixelHeight "$2"', 'fit', str(src), str(Path(t) / 'out.png')], capture_output=True, text=True)
                    self.assertEqual(r.returncode, 0, r.stderr)
                    self.assertEqual(' '.join(ln.split(':')[1].strip() for ln in r.stdout.splitlines() if 'pixel' in ln), want)


if __name__ == '__main__':
    unittest.main()
