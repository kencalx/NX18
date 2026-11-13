"""The app's third-party notices (dm/ios/Resources/ThirdPartyNotices.txt, made by dm/tools/third_party_notices.py): the committed file is what the license files make, it names
every vendored library the app compiles, and both packers put it into the app where the launchers read it (dm/ios/tools/build_ipa.sh, dm/mac/pack_app.py)."""
from pathlib import Path
import subprocess
import sys
import unittest

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
import third_party_notices as notices


class ThirdPartyNotices(unittest.TestCase):
    def test_committed_file_is_up_to_date(self):
        r = subprocess.run([sys.executable, str(REPO / 'dm/tools/third_party_notices.py'), '--check'], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)

    def test_every_compiled_library_and_license_is_there(self):
        text = notices.OUT.read_text(encoding='utf-8')
        names = [c[0] for c in notices.components()]
        # the libraries dm/host/Makefile builds into the host (and the iOS build compiles), the shaders' ports, the code nxnative started from, the glyphs
        for want in ('nxnative', 'd2r-mobile', 'MacNativeGames', 'dav1d', 'libvpx', 'stb_vorbis', 'nvn.h', 'deko3d', 'CMAA2', 'MiniEngine', 'FidelityFX FSR', 'AstralChain-Dynamic-FPS',
                     'Ryujinx', 'SPIRV-Cross', 'Switch Button Icons and Controls'):
            with self.subTest(component=want):
                self.assertTrue(any(n.startswith(want) for n in names))
        for want in ('Copyright (c) 2026 seedds', 'Copyright (c) 2026 jhaizhou', 'Copyright (c) 2026 MacNativeGames contributors', 'VideoLAN and dav1d authors',
                     'The WebM Project authors', 'Additional IP Rights Grant (Patents)', 'Copyright (c) 2017 Sean Barrett', 'Copyright (c) 2020 h1k421',
                     'Copyright (C) 2018-2020 fincs', 'Copyright (c) 2018, Intel Corporation', 'Apache License', 'Copyright (c) 2015 Microsoft',
                     'Copyright (c) 2021 Advanced Micro Devices', 'Copyright (c) 2026 yogesh1239', 'Copyright (c) Ryujinx Team and Contributors',
                     'Button Icons and Controls by Zacksly (CC BY 3.0 Licensed | zacksly.itch.io), modified: recoloured', 'creativecommons.org/licenses/by/3.0'):
            with self.subTest(text=want):
                self.assertIn(want, text)
        # only what a game app has: not the build tools' own libraries, not the image metric of the checks
        for absent in ('LibHac', '.NET', 'FLIP'):
            with self.subTest(absent=absent):
                self.assertNotIn(absent, text)

    def test_a_moved_notice_stops_the_generator(self):
        with self.assertRaises(SystemExit):
            notices.notice('dm/gfx/msl/present.metal', 'no such notice line', 'THE SOFTWARE.')

    def test_both_packers_put_it_where_the_launchers_read_it(self):
        ipa = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        self.assertIn('Resources/ThirdPartyNotices.txt" Gen/dm/ThirdPartyNotices.txt', ipa)   # → DmIOS.app/dm/ThirdPartyNotices.txt, the IPA and the prepared Xcode project alike
        mac = (REPO / 'dm/mac/pack_app.py').read_text()
        self.assertIn("return HERE.parent / 'ios/Resources/ThirdPartyNotices.txt'", mac)
        self.assertIn("dm / 'ThirdPartyNotices.txt'", mac)
        self.assertIn('"ThirdPartyNotices", withExtension: "txt", subdirectory: "dm"', (REPO / 'dm/ios/Sources/GuideViewer.swift').read_text())
        self.assertIn('dm/ThirdPartyNotices.txt', (REPO / 'dm/mac/Launcher.swift').read_text())


if __name__ == '__main__':
    unittest.main()
