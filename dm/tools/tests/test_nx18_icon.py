"""The NX 18 icon an app gets when its game has none (scripts/build_ipa_from_nsp.py NX18_ICON, dm/ios/tools/build_ipa.sh): the file is where both look for it,
an opaque 1024x1024 PNG as Xcode wants an app icon, and the build's line says which icon the app got. Run: python3 -m unittest dm/tools/tests/test_nx18_icon.py"""
import importlib.util
from pathlib import Path
import struct
import unittest

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
assert spec and spec.loader
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)


class NX18Icon(unittest.TestCase):
    def test_file(self):
        self.assertEqual(nsp.NX18_ICON, REPO / 'docs/images/nx18/nx18-icon-square-1024.png')
        b = nsp.NX18_ICON.read_bytes()
        self.assertEqual(b[:8], b'\x89PNG\r\n\x1a\n')
        w, h, depth, colour = struct.unpack('>IIBB', b[16:26])
        self.assertEqual((w, h), (1024, 1024))
        self.assertIn(colour, (0, 2), 'an app icon without alpha: greyscale or RGB, no alpha channel')
        self.assertNotIn(b'tRNS', b, 'no transparency chunk either')
        self.assertIn('NX18_ICON="$DM/../docs/images/nx18/nx18-icon-square-1024.png"', (REPO / 'dm/ios/tools/build_ipa.sh').read_text())

    def test_line(self):
        icon = nsp.NX18_ICON
        self.assertEqual(nsp.no_game_icon_line(True, True, icon, 'home-screen icon'),
                         "no game icon: the NUP carries none; the app gets the NX 18 icon (nx18-icon-square-1024.png); --icon / ICON gives it the game's, "
                         "--fallback-icon / FALLBACK_ICON a stand-in of your own")
        self.assertEqual(nsp.no_game_icon_line(False, True, None, "app's icon"),
                         "no game icon: a dump folder has no control data; the app's icon will be blank; --icon / ICON or --fallback-icon / FALLBACK_ICON gives it one")
        line = nsp.no_game_icon_line(False, False, icon, 'home-screen icon')
        self.assertTrue(line.startswith('[RED] no game icon in the extraction'))
        self.assertTrue(line.endswith('the app gets the NX 18 icon (nx18-icon-square-1024.png)'))


if __name__ == '__main__':
    unittest.main()
