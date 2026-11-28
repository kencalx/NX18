"""The key art's framing (dm/ios/Sources/ArtFocus.swift): its crop math, clamping, stored forms and precedence (art_focus_check.swift), and where the apps draw and keep it."""
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SOURCES = REPO / 'dm/ios/Sources'


@unittest.skipUnless(sys.platform == 'darwin' and shutil.which('xcrun'), 'needs the macOS Swift toolchain')
class ArtFocusMath(unittest.TestCase):
    def test_crop_clamp_forms_and_precedence(self):
        with tempfile.TemporaryDirectory() as tmp:
            exe = Path(tmp) / 'art_focus_check'
            r = subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-swift-version', '6', '-parse-as-library', '-module-cache-path', str(Path(tmp) / 'module-cache'), '-o', str(exe),
                                str(SOURCES / 'ArtFocus.swift'), str(Path(__file__).with_name('art_focus_check.swift'))], capture_output=True, text=True, timeout=300)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn('art focus: 0 failed', r.stdout)


class ArtFocusWiring(unittest.TestCase):
    def test_every_gate_draws_the_framing(self):   # no art side left on the plain centre crop; the wash and the tint keep the whole picture
        for path in ('dm/ios/Sources/Launcher.swift', 'dm/ios/Sources/NX18Welcome.swift', 'dm/ios/Sources/GuideViewer.swift', 'dm/mac/Launcher.swift'):
            with self.subTest(path=path):
                text = (REPO / path).read_text()
                self.assertIsNone(re.search(r'Image\((?:uiImage|nsImage): art\)\.resizable\(\)\.scaledToFill\(\)', text), 'key art drawn without its framing')
                self.assertIn('FramedArt(', text)
        art = (SOURCES / 'LauncherArt.swift').read_text()
        self.assertIn('c.artFocus = file(ArtFocus.file)', art)   # dm/art_focus.json, looked for beside the art
        self.assertIn('w.packedFocus = ArtFocus.packed(at: content.artFocus)', art); self.assertIn('ArtFocus.resolve(saved: ArtFocus.saved(), packed: w.packedFocus)', art)
        self.assertIn('NX18Palette.average', art); self.assertIn('wash(w.art ?? w.icon)', art)   # the whole picture's colours, not the framed part
        mac = (REPO / 'dm/mac/Launcher.swift').read_text()
        self.assertIn('x.focus = ArtFocus.resolve(saved: ArtFocus.saved(), packed: x.packedFocus)', mac)   # the Mac app's own preferences, which NX 18 Beam may write, then Resources/dm/art_focus.json

    def test_framing_reaches_voiceover_and_ends_under_a_sheet(self):
        gate = (SOURCES / 'Launcher.swift').read_text()
        art = gate[gate.index('FramedArt(image: Image(uiImage: art), natural: art.size, focus: artFocus)'):gate.index('else if let icon = artwork.icon')]
        self.assertIn('.onLongPressGesture(minimumDuration: 0.6) { beginFraming() }', art)
        self.assertIn('.accessibilityAction(named: "Adjust art") { beginFraming() }', art, 'the long press has a VoiceOver equivalent on the art itself')
        self.assertNotIn('.accessibilityHidden(true)', art)
        sheet = gate[gate.index('.onChange(of: sheet) {'):gate.index('.onChange(of: cloudPicking)')]
        self.assertIn('if sheet != nil, framing != nil { endFraming(save: false) }', sheet, 'a Guide or About sheet over the framing ends it, as Cancel')

    def test_the_shared_file_is_compiled_wherever_the_gate_is(self):
        self.assertIn("ios/Sources/ArtFocus.swift", (REPO / 'dm/mac/pack_app.py').read_text())
        self.assertIn('../dm/ios/Sources/ArtFocus.swift', (REPO / 'beam/project.yml').read_text())
        self.assertIn('../../Sources/ArtFocus.swift', (REPO / 'dm/ios/tests/duo/project.yml').read_text())

    def test_the_build_packs_the_default(self):   # DM_ART_FOCUS (the NSP script's --art-focus): dm/art_focus.json beside dm/art.jpg, only with art, never stopping the build
        sh = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        line = next(ln for ln in sh.splitlines() if ln.startswith('if [ -n "${DM_ART_FOCUS:-}" ]'))
        self.assertIn('Gen/dm/art_focus.json', line); self.assertIn('-f Gen/dm/art.jpg', line); self.assertNotIn('die', line)
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); (t / 'Gen/dm').mkdir(parents=True)
            def run(value, art=True):
                (t / 'Gen/dm/art_focus.json').unlink(missing_ok=True)
                if art: (t / 'Gen/dm/art.jpg').write_bytes(b'jpg')
                else: (t / 'Gen/dm/art.jpg').unlink(missing_ok=True)
                r = subprocess.run(['bash', '-c', 't() { echo "$*"; }; die() { echo "FAIL: $*"; exit 1; }\n' + line], cwd=t, env={'PATH': '/usr/bin:/bin', 'DM_ART_FOCUS': value},
                                   capture_output=True, text=True)
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                f = t / 'Gen/dm/art_focus.json'
                return f.read_text() if f.exists() else None, r.stdout
            got, said = run('0.25,0.5,1.5')
            self.assertEqual(got, '{"x": 0.25, "y": 0.5, "zoom": 1.5}\n'); self.assertIn('launcher art framing: 0.25,0.5,1.5', said)
            self.assertEqual(run('0.3,0.7')[0], '{"x": 0.3, "y": 0.7, "zoom": 1}\n')
            got, said = run('0.3,0.7', art=False); self.assertIsNone(got); self.assertIn('no art', said)
            for bad in ('left', '0.5', '1,2,3,4', '0.5,0.5;rm -rf /'):
                with self.subTest(bad=bad):
                    got, said = run(bad); self.assertIsNone(got); self.assertIn('[RED]', said)


if __name__ == '__main__':
    unittest.main()
