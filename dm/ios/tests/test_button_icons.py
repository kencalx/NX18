"""The controller hints' button glyphs (dm/ios/Resources/ButtonIcons, Zacksly's "Switch Button Icons and Controls", CC BY 3.0): the generated outlines match the SVGs, every
vendored SVG is drawn, the licence and the credit the licence asks for are where they must be, and the launchers' flowing rails stay a Core Animation slide that Reduce Motion
stops. Off the device: the glyphs' look and the pad rule run in the Duo harness (DuoButtonGlyphTests)."""
from pathlib import Path
import re
import subprocess
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
ICONS = REPO / 'dm/ios/Resources/ButtonIcons'
CREDIT = 'Button Icons and Controls by Zacksly (CC BY 3.0 Licensed | zacksly.itch.io)'
sys.path.insert(0, str(REPO / 'dm/ios/tools'))
import button_glyphs  # noqa: E402


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


class ButtonIcons(unittest.TestCase):
    def test_generated_outlines_match_the_svgs(self):
        r = subprocess.run([sys.executable, '-I', str(REPO / 'dm/ios/tools/button_glyphs.py'), '--check'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_only_the_glyphs_drawn_are_vendored(self):
        svgs = sorted(p.stem for p in ICONS.glob('*.svg'))
        self.assertEqual(svgs, sorted(button_glyphs.GLYPHS.values()))
        swift = read('dm/ios/Sources/NXButtonGlyph.swift')
        cases = re.search(r'enum NXButton: String, CaseIterable, Sendable \{\s*case ([a-z, ]+)\n', swift).group(1).replace(' ', '').split(',')
        self.assertEqual(sorted(cases), sorted(button_glyphs.GLYPHS))
        uses = read('dm/ios/Sources/Launcher.swift') + read('dm/ios/Sources/GuideViewer.swift') + read('dm/ios/Sources/GameMenuPanel.swift') + swift
        for case in ('a', 'b', 'y', 'plus'):   # x: an Xbox pad's X standing for the Switch's Y (NXPadGlyphs.of)
            self.assertRegex(uses, rf'(glyph\(\.{case}\)|: NXButton = [^\n]*\.{case}\b|pad: \.{case}\b)', case)
        self.assertIn('(.y, labelled ? pad.buttonY : pad.buttonX, .x)', swift)

    def test_svgs_are_one_colour_with_no_strokes(self):
        for p in ICONS.glob('*.svg'):
            text = p.read_text()
            self.assertEqual(set(re.findall(r'fill:\s*([^;}]+)', text)), {'#fff'}, p.name)
            self.assertNotIn('stroke:', text, p.name)
            self.assertNotIn('<image', text, p.name)
            self.assertNotIn('<script', text, p.name)

    def test_licence_and_credit(self):
        lic = (ICONS / 'LICENSE.txt').read_text(encoding='utf-8')
        self.assertIn('Creative Commons Attribution 3.0', lic)
        self.assertIn('Zacksly', lic)
        self.assertIn(CREDIT, lic)   # the licence's own short form, which the credits use word for word
        for rel in ('README.md', 'dm/ios/Resources/ButtonIcons/README.md', 'dm/ios/Sources/NXButtonGlyph.swift'):
            with self.subTest(rel=rel):
                text = read(rel)
                self.assertIn(CREDIT, text)
                self.assertIn('modified: recoloured', text)
        # the app shows it: under the settings (beside the version) and in About this game
        self.assertIn('Text(NX18Credits.buttonIcons)', read('dm/ios/Sources/Launcher.swift'))
        self.assertIn('Text(NX18Credits.buttonIcons)', read('dm/ios/Sources/GuideViewer.swift'))
        self.assertIn(f'static let buttonIcons = "{CREDIT}, modified: recoloured"', read('dm/ios/Sources/NXButtonGlyph.swift'))
        # CC BY 3.0 4(a): the licence's address goes with every copy; the app carries no LICENSE.txt, so About names it
        self.assertIn('creativecommons.org/licenses/by/3.0', read('dm/ios/Sources/NXButtonGlyph.swift'))
        self.assertIn('Text(NX18Credits.buttonIconsLicence)', read('dm/ios/Sources/GuideViewer.swift'))

    def test_every_list_of_the_harness_compiles_the_glyphs(self):
        yml = read('dm/ios/tests/duo/project.yml')
        for f in ('NXButtonGlyph.swift', 'NXButtonGlyphData.swift'):
            self.assertIn(f'../../Sources/{f}', yml)

    def test_parser_reads_what_the_pack_writes(self):
        steps = button_glyphs.path_steps('M10,10h5v5H10Zm1,1a2,2,0,0,1,2,2q1,0,2,1t2,0s1,1,2,2Z')
        self.assertEqual([s[0] for s in steps], ['M', 'L', 'L', 'L', 'Z', 'M', 'C', 'C', 'C', 'C', 'Z'])
        self.assertEqual(steps[1], ('L', 15.0, 10.0))
        self.assertEqual(steps[5], ('M', 11.0, 11.0))   # relative to the closed subpath's start
        self.assertAlmostEqual(steps[6][5], 13.0); self.assertAlmostEqual(steps[6][6], 13.0)   # the arc ends where it says
        with self.assertRaises(button_glyphs.GlyphError):
            button_glyphs.path_steps('M0,0 L1')

    def test_rails_flow_by_core_animation_and_stop_under_reduce_motion(self):
        row = read('dm/ios/Sources/LauncherRow.swift')
        self.assertIn('NX18RailsFlow(axis: axis, moving: !reduceMotion)', row)
        self.assertIn('CABasicAnimation(keyPath: path)', row)
        for banned in ('TimelineView', 'CADisplayLink', 'Timer.publish', 'repeatForever'):
            self.assertNotIn(banned, row)
        self.assertIn('NX18Rails(flowing: true)', read('dm/ios/Sources/Launcher.swift'))
        self.assertIn('NX18Rails(axis: .horizontal, flowing: true)', read('dm/ios/Sources/Launcher.swift'))
        self.assertIn('NX18Rails(axis: .horizontal, flowing: true)', read('dm/mac/Launcher.swift'))
        self.assertIn('NX18Rails(axis: .horizontal, thickness: 2)', read('dm/ios/Sources/GuideViewer.swift'))   # the guide's stays still


if __name__ == '__main__':
    unittest.main()
