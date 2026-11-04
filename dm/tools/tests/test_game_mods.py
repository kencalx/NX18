"""dm/tools/game_mods.py: a game's mods folder (code patches, RomFS file replacements, cheats) on synthetic modules and images; no game files or keys needed"""
import hashlib
import importlib.util
import os
from pathlib import Path
import struct
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools'))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import game_mods as gm
import nso
import romfs
import romfs_image
from test_nso import make_nso, TEXT, RO

TITLE = 0x0100ABCD12340000
BUILD = bytes(range(0x20))   # make_nso's build ID
BID = BUILD.hex().upper()


def ips(records, rle=()):
    body = b''.join(o.to_bytes(3, 'big') + len(d).to_bytes(2, 'big') + d for o, d in records)
    body += b''.join(o.to_bytes(3, 'big') + b'\0\0' + n.to_bytes(2, 'big') + bytes([v]) for o, n, v in rle)
    return b'PATCH' + body + b'EOF'


def ips32(records):
    return b'IPS32' + b''.join(o.to_bytes(4, 'big') + len(d).to_bytes(2, 'big') + d for o, d in records) + b'EEOF'


class Formats(unittest.TestCase):
    def test_ips_records_and_rle(self):
        recs = gm.parse_ips(ips([(0x100, b'\x1f\x20\x03\xd5')], rle=[(0x200, 4, 0xaa)]))
        self.assertEqual(recs, [(0x100, b'\x1f\x20\x03\xd5'), (0x200, b'\xaa' * 4)])

    def test_ips32_and_damaged_files(self):
        self.assertEqual(gm.parse_ips(ips32([(0x01000100, b'\x01\x02')])), [(0x01000100, b'\x01\x02')])
        with self.assertRaises(gm.ModError): gm.parse_ips(b'NOTIPS')
        with self.assertRaises(gm.ModError): gm.parse_ips(ips([(0x100, b'\x01\x02\x03')])[:-5])   # cut short inside a record

    def test_pchtxt_as_yuzu_reads_it(self):
        text = f'''@nsobid-{BID[:40]}
@flag offset_shift 0x100
@flag print_values

// 60 FPS
@enabled
00000010 1F2003D5 // nop
00000020 "hi\\n"

[Disabled one]
@disabled
00000030 FFFFFFFF

@little-endian
// Swapped
@enabled
00000040 D503201F
@stop
00000050 00000000
'''
        bid, patches = gm.parse_pchtxt(text)
        self.assertEqual(bid, BID[:40])
        self.assertEqual([(p.name, p.enabled) for p in patches], [('60 FPS', True), ('Disabled one', False), ('Swapped', True)])
        self.assertEqual(patches[0].records, [(0x110, bytes.fromhex('1F2003D5')), (0x120, b'hi\n')])
        self.assertEqual(patches[2].records, [(0x140, bytes.fromhex('1F2003D5'))], 'little-endian reverses the value; @stop ends the file')
        with self.assertRaises(gm.ModError): gm.parse_pchtxt('@nsobid-00\n// x\n@enabled\n00000010 XYZ\n')

    def test_build_ids_match_by_prefix(self):
        self.assertTrue(gm.build_matches(BID[:40], BUILD))
        self.assertTrue(gm.build_matches(BID.lower(), BUILD))
        self.assertTrue(gm.build_matches(BID[:16], BUILD))
        self.assertFalse(gm.build_matches(BID[:15], BUILD), 'too short to name a build')
        self.assertFalse(gm.build_matches('FF' + BID[2:40], BUILD))

    def test_records_skip_the_header_and_stop_at_the_end(self):
        img = bytearray(16)
        self.assertEqual(gm.apply_records(img, [(0xfe, b'\x01\x02\x03\x04'), (0x10e, b'\x05\x06\x07\x08')]), (4, 1))
        self.assertEqual(bytes(img), b'\x03\x04' + b'\0' * 12 + b'\x05\x06')

    def test_patched_module_loads_as_horizon_would(self):
        d = bytes(make_nso())
        m = nso.load(d)
        img = bytearray(m.image); img[0x10:0x14] = b'\x1f\x20\x03\xd5'; img[m.segments[2][0]:m.segments[2][0] + 2] = b'\xee\xee'
        out = gm.nso_with_image(d, img)
        back = nso.load(out)
        self.assertEqual(back.image, img)
        self.assertEqual(back.build_id, m.build_id)
        self.assertEqual(back.bss, m.bss)
        flags = struct.unpack_from('<I', out, 0xc)[0]
        self.assertEqual(flags & 7, 0, 'stored uncompressed')
        self.assertEqual(flags & 0x38, 0x38, 'with hashes nso.py checks')
        self.assertEqual(out[0xa0:0xc0], hashlib.sha256(bytes(img[:len(TEXT)])).digest())


class Folder(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name)
        self.mods = self.root / 'mods'

    def put(self, rel, data: bytes | str = b'x'):
        p = self.mods / rel; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data if isinstance(data, bytes) else data.encode())
        return p

    def test_scan_keeps_this_game_and_skips_turned_off_mods(self):
        self.put(f'atmosphere/exefs_patches/fps/{BID[:40]}.ips', ips([(0x100, b'\0' * 4)]))
        self.put(f'atmosphere/contents/{TITLE:016X}/romfs/Data/a.bin')
        self.put(f'atmosphere/contents/{TITLE:016X}/cheats/{BID[:16]}.txt', '[Max HP]\n04000000 00000010 000003E7\n')
        self.put(f'atmosphere/contents/{TITLE + 0x800:016X}/romfs/Data/update.bin')   # the update's title ID: the same game
        self.put('atmosphere/contents/0100000000AAAA00/romfs/Data/b.bin')   # another game
        self.put(f'yuzu/{TITLE:016X}/-Off/romfs/Data/c.bin')   # turned off
        self.put(f'yuzu/{TITLE:016X}/Mod/exefs/main')   # a whole module: not applied
        self.put('.DS_Store')
        f = gm.scan(self.mods, TITLE)
        self.assertEqual([p.name for p in f.ips], [f'{BID[:40]}.ips'])
        self.assertEqual(sorted(str(p.relative_to(self.mods)) for p in f.romfs),
                         [f'atmosphere/contents/{TITLE:016X}/romfs', f'atmosphere/contents/{TITLE + 0x800:016X}/romfs'])
        self.assertEqual([p.name for p in f.cheats], [f'{BID[:16]}.txt'])
        why = {p.name: w for p, w in f.ignored}
        self.assertIn('-Off', why); self.assertIn('main', why)
        self.assertTrue(f.any())
        self.assertFalse(gm.scan(self.root / 'missing', TITLE).any())

    def test_exefs_patches_reach_the_module_they_name(self):
        exefs = self.root / 'ExeFS'; exefs.mkdir()
        (exefs / 'main').write_bytes(bytes(make_nso()))
        (exefs / 'main.npdm').write_bytes(b'META')
        self.put(f'exefs_patches/a/{BID[:40]}.ips', ips([(0x110, b'\x1f\x20\x03\xd5')]))
        self.put('exefs_patches/b/0000000000000000000000000000000000000000.ips', ips([(0x100, b'\xff')]))   # another build
        self.put('Mod/exefs/fps.pchtxt', f'@nsobid-{BID[:40]}\n@flag offset_shift 0x100\n// Fast\n@enabled\n00000020 AABBCCDD\n// Off\n@disabled\n00000030 11223344\n')
        dst = self.root / 'out'
        report, changed = gm.patch_exefs(exefs, dst, gm.scan(self.mods, TITLE))
        self.assertEqual(changed, ['main'])
        img = nso.read(dst / 'main').image
        self.assertEqual(img[0x10:0x14], b'\x1f\x20\x03\xd5')
        self.assertEqual(img[0x20:0x24], bytes.fromhex('AABBCCDD'))
        self.assertEqual(img[0x30:0x34], TEXT[0x30:0x34], 'a @disabled patch stays off')
        ro = nso.read(exefs / 'main').segments[1][0]
        self.assertEqual(img[ro:ro + 10], RO[:10], 'the other segments as they were')
        self.assertEqual((dst / 'main.npdm').read_bytes(), b'META')
        self.assertEqual(nso.read(exefs / 'main').image[0x10:0x14], TEXT[0x10:0x14], 'the extraction is never written')
        self.assertTrue(any('not for this version' in r for r in report))
        self.assertTrue(any('@disabled' in r for r in report))

    def test_romfs_files_replace_and_add_in_the_image(self):
        src = self.root / 'RomFS'
        for rel, content in (('Data/a.bin', b'game a'), ('Data/b.bin', b'game b'), ('Movie/m.mp4', b'movie'), ('top.txt', b'top')):
            (src / rel).parent.mkdir(parents=True, exist_ok=True); (src / rel).write_bytes(content)
        img = self.root / 'RomFS.img'
        romfs_image.pack(src, img)
        self.put('m1/romfs/Data/a.bin', b'MOD A')
        self.put('m1/romfs/data/B.BIN', b'MOD B (other case)')   # a Windows-made mod: the game's own names are kept
        self.put('m2/romfs/New/deep/n.bin', b'new file')
        self.put('m2/romfs/Data/a.bin', b'MOD A from m2')   # a later folder wins
        dst = self.root / 'modded.img'
        report = gm.overlay_image(img, dst, gm.scan(self.mods, TITLE).romfs, self.mods)
        self.assertIn('3 files replaced, 1 added', report[0])
        im = romfs.Image(dst)   # its own checks: sorted names, breadth-first tree, ranges inside the data
        idx = romfs_image.read_index(dst)
        def data(rel):
            _, off, size = idx[rel]
            with open(dst, 'rb') as f: f.seek(off); return f.read(size)
        self.assertEqual(data('Data/a.bin'), b'MOD A from m2')
        self.assertEqual(data('Data/b.bin'), b'MOD B (other case)')
        self.assertEqual(data('New/deep/n.bin'), b'new file')
        self.assertEqual(data('Movie/m.mp4'), b'movie')
        self.assertEqual(data('top.txt'), b'top')
        self.assertNotIn('data/B.BIN', idx)
        self.assertEqual(im.count, len(idx) + 1)
        self.assertEqual(romfs_image.read_index(img)['Data/a.bin'][2], 6, 'the game\'s image is unchanged')
        with romfs.open(str(dst / 'Data/b.bin'), 'rb') as f: self.assertEqual(f.read(), b'MOD B (other case)')

    def test_romfs_folder_of_an_older_extraction(self):
        src = self.root / 'RomFS'; (src / 'Data').mkdir(parents=True); (src / 'Data/a.bin').write_bytes(b'game a')
        self.put('m/romfs/Data/a.bin', b'MOD A'); self.put('m/romfs/Data/new.bin', b'new')
        dst = self.root / 'out'
        gm.overlay_folder(src, dst, gm.scan(self.mods, TITLE).romfs, self.mods)
        self.assertEqual((dst / 'Data/a.bin').read_bytes(), b'MOD A')
        self.assertEqual((dst / 'Data/new.bin').read_bytes(), b'new')
        self.assertEqual((src / 'Data/a.bin').read_bytes(), b'game a', 'a hard link is replaced, never written into')

    def test_cheats_are_packed_by_build(self):
        self.put(f'cheats/{BID[:16]}.txt', '[Max HP]\n04000000 00000010 000003E7\n')
        self.put('cheats/downloaded.txt', '[Moon Jump]\n80000040\n04000000 00000020 00000001\n20000000\n')
        self.put('cheats/0123456789ABCDEF.txt', '[Old]\n04000000 00000010 00000001\n')
        out = self.root / 'packed'
        report, files = gm.pack_cheats(gm.scan(self.mods, TITLE), BID[:16], out)
        self.assertEqual(sorted(p.name for p in files), sorted(['0123456789ABCDEF.txt', f'{BID[:16]}.txt']))
        mine = (out / f'{BID[:16]}.txt').read_text()
        self.assertIn('[Max HP]', mine); self.assertIn('[Moon Jump]', mine)
        self.assertTrue(any('not named after a build ID' in r for r in report))


class NspScript(unittest.TestCase):
    """build_ipa_from_nsp.py's mods stage: the modded extraction it packs from, reused while nothing changed"""
    def setUp(self):
        spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        assert spec and spec.loader
        self.nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.nsp)
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name)
        for cm in (mock.patch.object(self.nsp, 'PROG', mock.Mock()), mock.patch.object(self.nsp, 'say', lambda m: None)):
            cm.start(); self.addCleanup(cm.stop)
        self.ext = self.root / 'extract/v0'
        (self.ext / 'ExeFS').mkdir(parents=True)
        (self.ext / 'ExeFS/main').write_bytes(bytes(make_nso()))
        (self.ext / 'control.nacp').write_bytes(b'NACP')
        src = self.root / 'src'; (src / 'Data').mkdir(parents=True); (src / 'Data/a.bin').write_bytes(b'game a')
        romfs_image.pack(src, self.ext / 'RomFS.img')
        self.mods = self.root / 'mods'
        for rel, data in ((f'exefs_patches/fps/{BID[:40]}.ips', ips([(0x110, b'\x1f\x20\x03\xd5')])),
                          (f'contents/{TITLE:016X}/romfs/Data/a.bin', b'MOD A'),
                          (f'contents/{TITLE:016X}/cheats/{BID[:16]}.txt', b'[Max HP]\n04000000 00000010 000003E7\n')):
            (self.mods / rel).parent.mkdir(parents=True, exist_ok=True); (self.mods / rel).write_bytes(data)

    def test_modded_extraction_and_reuse(self):
        work = self.root / 'work'
        modded, cheats = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(modded, work / 'mods/v0')
        self.assertEqual(nso.read(modded / 'ExeFS/main').image[0x10:0x14], b'\x1f\x20\x03\xd5')
        idx = romfs_image.read_index(modded / 'RomFS.img')
        with open(modded / 'RomFS.img', 'rb') as f: f.seek(idx['Data/a.bin'][1]); self.assertEqual(f.read(5), b'MOD A')
        self.assertEqual(os.stat(modded / 'control.nacp').st_ino, os.stat(self.ext / 'control.nacp').st_ino, 'the other files are hard links')
        self.assertEqual(sorted(p.name for p in cheats.iterdir()), [f'{BID[:16]}.txt'])
        self.assertEqual(nso.read(self.ext / 'ExeFS/main').image[0x10:0x14], TEXT[0x10:0x14], 'the extraction is never written')
        stamp = os.stat(modded / 'ExeFS/main').st_mtime_ns
        self.assertEqual(self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE), (modded, cheats))
        self.assertEqual(os.stat(modded / 'ExeFS/main').st_mtime_ns, stamp, 'reused while nothing changed')
        self.nsp.PROG.end.assert_called_with('reused (the mods and the game files unchanged)')

    def test_cheats_alone_need_no_modded_extraction(self):
        for p in sorted(self.mods.rglob('*'), reverse=True):
            if p.is_file() and p.suffix != '.txt': p.unlink()
        modded, cheats = self.nsp.apply_mods(self.mods, self.ext, self.root / 'work', 'v0', TITLE)
        self.assertIsNone(modded)
        self.assertTrue((cheats / f'{BID[:16]}.txt').is_file())

    def test_folder_setting(self):
        args = self.nsp.parse_args(['x'])
        self.assertIsNone(self.nsp.mods_folder(args, self.root / 'none'))
        (self.root / 'game/mods').mkdir(parents=True)
        self.assertEqual(self.nsp.mods_folder(args, self.root / 'game'), self.root / 'game/mods', 'the folder named mods beside the game\'s files')
        self.assertIsNone(self.nsp.mods_folder(self.nsp.parse_args(['x', '--no-mods']), self.root / 'game'))
        self.assertEqual(self.nsp.mods_folder(self.nsp.parse_args(['x', '--mods', str(self.mods)]), self.root / 'game'), self.mods)
        with self.assertRaises(self.nsp.BuildError): self.nsp.mods_folder(self.nsp.parse_args(['x', '--mods', str(self.root / 'missing')]), self.root)


if __name__ == '__main__':
    unittest.main()
