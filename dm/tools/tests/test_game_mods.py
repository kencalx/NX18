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

    def test_title_folders_of_this_program(self):
        for tid in (TITLE, TITLE + 0x800, TITLE + 1, TITLE + 2, TITLE + 0x802, TITLE + 0x1001, 0x0100000000AAAA00):
            self.put(f'atmosphere/contents/{tid:016X}/romfs/Data/a.bin'); self.put(f'atmosphere/contents/{tid:016X}/cheats/inf.txt', '[Inf]\n')
        def got(tid):
            f = gm.scan(self.mods, tid)
            self.assertEqual([p.parent.parent.name for p in f.cheats], [p.parent.name for p in f.romfs], 'cheats from the same folders')
            return [p.parent.name for p in f.romfs], {p.name: w for p, w in f.ignored}
        # a game of one program: its base and its update, not another game's or a DLC's (base + 0x1000 + its index), which the report names
        names, why = got(TITLE)
        self.assertEqual(names, [f'{TITLE:016X}', f'{TITLE + 0x800:016X}'])
        self.assertEqual(list(why), [f'{TITLE + 0x1001:016X}']); self.assertIn('DLC', why[f'{TITLE + 0x1001:016X}'])
        # a game of several programs (Super Mario 3D All-Stars): each program takes its own folders alone
        self.assertEqual(got(TITLE + 2)[0], [f'{TITLE + 2:016X}', f'{TITLE + 0x802:016X}'])
        self.assertEqual(got(TITLE + 1)[0], [f'{TITLE + 1:016X}'])
        self.assertTrue(gm.same_title(f'{TITLE:016x}', TITLE)); self.assertTrue(gm.same_title(f'{TITLE + 0x800:016X}', TITLE))
        self.assertFalse(gm.same_title(f'{TITLE + 1:016X}', TITLE)); self.assertFalse(gm.same_title(f'{TITLE:016X}', TITLE + 1))
        self.assertFalse(gm.same_title(f'{TITLE + 0x1000:016X}', TITLE)); self.assertTrue(gm.dlc_title(f'{TITLE + 0x1001:016X}', TITLE + 2))

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


class Switchable(unittest.TestCase):
    """the launcher's High frame rate and Ultrawide: which mods are switchable, and the bytes a variant rewrite changes"""
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name)

    def test_roles_by_folder_name(self):
        for n, r in (('60FPS', 'fps'), ('120 FPS', 'fps'), ('Frame Rate Unlock', 'fps'), ('Ultrawide', 'ultrawide'), ('21:9', 'ultrawide'),
                     ('32.9 Ryujinx', 'ultrawide'), ('Pack/21x9', 'ultrawide'), ('Remove Bloom', None), ('fps/../Bloom', None)):
            self.assertEqual(gm.role_of(n), r, n)

    def test_one_mod_per_role(self):
        mods = self.root / 'mods'
        for rel in ('exefs_patches/30FPS/a.ips', 'exefs_patches/60FPS/a.ips', 'exefs_patches/60FPS Ryujinx/a.ips', 'exefs_patches/120FPS/a.ips',
                    'exefs_patches/32.9/a.ips', 'exefs_patches/21.9/a.ips', 'exefs_patches/Bloom/a.ips'):
            (mods / rel).parent.mkdir(parents=True, exist_ok=True); (mods / rel).write_bytes(ips([]))
        found = gm.scan(mods, TITLE)
        keep, chosen, report = gm.split_roles(found)
        self.assertEqual([p.parent.name for p in keep], ['Bloom'])
        self.assertEqual(chosen['fps'][0], 'exefs_patches/60FPS')
        self.assertEqual(chosen['ultrawide'][0], 'exefs_patches/21.9', 'the shape nearest the device\'s')
        self.assertEqual(sum('left out' in r for r in report), 4)
        keep, chosen, report = gm.split_roles(found, fps_ok=False)
        self.assertNotIn('fps', chosen); self.assertEqual(len(keep), 1)

    def test_aspect_value(self):
        recs = [(0x10, struct.pack('<f', 21 / 9)), (0x20, struct.pack('<f', 16 / 9)), (0x30, b'\x1f\x20\x03\xd5\x00\x00')]
        report = []
        out = gm.adapt_aspect(recs, 'uw', report)
        self.assertAlmostEqual(struct.unpack('<f', out[0][1])[0], gm.DEVICE_ASPECT, places=5)
        self.assertEqual(out[1:], recs[1:]); self.assertIn('aspect value set', report[0])
        gm.adapt_aspect(recs[1:], 'uw', report); self.assertIn('no aspect value', report[1])

    def test_reloc_slots(self):
        img = bytearray(0x400)
        struct.pack_into('<I', img, 4, 0x100); img[0x100:0x104] = b'MOD0'; struct.pack_into('<i', img, 0x104, 0x100)   # dynamic at 0x200
        dyn = [(7, 0x300), (8, 48), (36, 0x340), (35, 16), (0, 0)]
        for i, (t, v) in enumerate(dyn): struct.pack_into('<qQ', img, 0x200 + 16 * i, t, v)
        struct.pack_into('<QQ', img, 0x300, 0x1000, 0); struct.pack_into('<QQ', img, 0x318, 0x1008, 0)
        struct.pack_into('<QQ', img, 0x340, 0x2000, 0b101)   # 0x2000, then bitmap bit 0 -> 0x2008, bit 1 -> 0x2010
        self.assertEqual(gm.reloc_slots(img), {0x1000, 0x1008, 0x2000, 0x2010})
        self.assertEqual(gm.reloc_slots(bytes(0x40)), set())

    def test_file_pieces(self):
        f = self.root / 'f.tsv'
        f.write_text('# TEXT_END 0x4100\n# PATCH_OFF 0x10000\nrow\t1\n')
        self.assertEqual(gm.file_pieces(f, 0x14000), [(0, 0x8000, 0, True), (0x8000, 0x10000, 0x8000, False), (0x10000, 0x14000, 0x10000, True)])
        f.write_text('# TEXT_END 0x4000\n# PATCH_OFF -0x8000\n# FILE_IMAGE_LEN 0x10000\n# BACK_LEN 0x4000\n# BACK_OFF 0x20000\n')
        self.assertEqual(gm.file_pieces(f, 0x1c000), [(0, 0x4000, 0, True), (0x4000, 0x10000, 0x4000, False), (0x10000, 0x18000, -0x8000, True), (0x18000, 0x1c000, 0x20000, True)])

    def test_variant_runs(self):
        a, b = self.root / 'a', self.root / 'b'; a.mkdir(); b.mkdir()
        hdr = '# TEXT_END 0x4000\n# PATCH_OFF 0x20000\n'
        x = bytearray(0x24000); y = bytearray(x)
        y[0x8] = 1; y[0x3fff:0x4001] = b'\x02\x03'; y[0xfffe:0x10002] = b'\x04' * 4; y[0x21000] = 5
        for d, data in ((a, x), (b, y)): (d / 'main.patched.bin').write_bytes(data); (d / 'main.fixups.tsv').write_text(hdr)
        runs = gm.variant_runs(a, b, 'main', bytes(0x40))
        self.assertEqual(runs, [('c', 0x8, 0x8, b'\x01'), ('c', 0x3fff, 0x3fff, b'\x02'), ('w', 0x4000, 0x4000, b'\x03'), ('w', 0xfffe, 0xfffe, b'\x04' * 4), ('c', 0x21000, 0x21000, b'\x05')])
        rows = [('fps', r) for r in runs]; gm.write_variants(self.root / 'm.variants', rows)
        self.assertEqual(gm.read_variants(self.root / 'm.variants'), [('fps', *r) for r in runs])
        with mock.patch.object(gm, 'reloc_slots', lambda img: {0xfff8}):
            with self.assertRaises(gm.ModError): gm.variant_runs(a, b, 'main', bytes(0x40))
        (b / 'main.gates.tsv').write_text('x')
        with self.assertRaises(gm.ModError): gm.variant_runs(a, b, 'main', bytes(0x40))


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
        (self.mods / 'exefs_patches/fps').rename(self.mods / 'exefs_patches/speed')   # a mod that is not switchable: written in for good
        work = self.root / 'work'
        modded, cheats, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(modded, work / 'mods/v0')
        self.assertEqual(nso.read(modded / 'ExeFS/main').image[0x10:0x14], b'\x1f\x20\x03\xd5')
        idx = romfs_image.read_index(modded / 'RomFS.img')
        with open(modded / 'RomFS.img', 'rb') as f: f.seek(idx['Data/a.bin'][1]); self.assertEqual(f.read(5), b'MOD A')
        self.assertEqual(os.stat(modded / 'control.nacp').st_ino, os.stat(self.ext / 'control.nacp').st_ino, 'the other files are hard links')
        self.assertEqual(sorted(p.name for p in cheats.iterdir()), [f'{BID[:16]}.txt'])
        self.assertEqual(nso.read(self.ext / 'ExeFS/main').image[0x10:0x14], TEXT[0x10:0x14], 'the extraction is never written')
        stamp = os.stat(modded / 'ExeFS/main').st_mtime_ns
        self.assertEqual(self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE), (modded, cheats, variants))
        self.assertEqual(os.stat(modded / 'ExeFS/main').st_mtime_ns, stamp, 'reused while nothing changed')
        self.nsp.PROG.end.assert_called_with('reused (the mods and the game files unchanged)')

    def test_a_renamed_mod_folder_is_built_again(self):   # the folder's name decides whether a mod is switchable
        (self.mods / 'exefs_patches/fps').rename(self.mods / 'exefs_patches/speed')
        work = self.root / 'work'
        _, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(variants, {})
        (self.mods / 'exefs_patches/speed').rename(self.mods / 'exefs_patches/60 FPS')
        modded, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(set(variants), {'fps'})
        self.assertEqual(nso.read(modded / 'ExeFS/main').image[0x10:0x14], TEXT[0x10:0x14], 'no longer written in for good')

    def test_a_cheat_change_makes_nothing_else_again(self):
        (self.mods / 'exefs_patches/fps').rename(self.mods / 'exefs_patches/60 FPS')
        work = self.root / 'work'; cheat = self.mods / f'contents/{TITLE:016X}/cheats/{BID[:16]}.txt'
        modded, cheats, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        rw = work / 'mods/v0_fps/rewrite'; rw.mkdir(); (rw / 'main.key').write_text('the variant rewrite\'s cache\n')   # as build_variants leaves it
        img = os.stat(modded / 'RomFS.img'); main = os.stat(modded / 'ExeFS/main'); packed = os.stat(cheats / f'{BID[:16]}.txt')
        self.assertEqual(self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE), (modded, cheats, variants))
        self.nsp.PROG.end.assert_called_with('reused (the mods and the game files unchanged)')
        self.assertEqual(os.stat(cheats / f'{BID[:16]}.txt').st_mtime_ns, packed.st_mtime_ns, 'the same cheats: the packed file is kept')
        cheat.write_text('[Max HP]\n04000000 00000010 000003E7\n[Max MP]\n04000000 00000020 000003E7\n')
        self.assertEqual(self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE), (modded, cheats, variants))
        self.nsp.PROG.end.assert_called_with('reused (the code and RomFS mods and the game files unchanged); the cheats packed again')
        self.assertIn('[Max MP]', (cheats / f'{BID[:16]}.txt').read_text())
        report = (work / 'mods/v0.txt').read_text()
        self.assertIn('2 entries', report); self.assertNotIn('1 entries', report); self.assertIn('switchable', report, 'the report keeps the code mods\' lines')
        now = os.stat(modded / 'RomFS.img')
        self.assertEqual((now.st_ino, now.st_mtime_ns, now.st_ctime_ns), (img.st_ino, img.st_mtime_ns, img.st_ctime_ns), 'the RomFS image is not linked again (the IPA packer keys on its ctime)')
        self.assertEqual(os.stat(modded / 'ExeFS/main').st_mtime_ns, main.st_mtime_ns)
        cheat.rename(cheat.with_name('-' + cheat.name))   # the Builder turns a cheat file off this way
        self.assertEqual(self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE), (modded, None, variants))
        self.assertFalse(cheats.exists()); self.assertNotIn('cheats: ', (work / 'mods/v0.txt').read_text())
        (self.mods / f'contents/{TITLE:016X}/romfs/Data/a.bin').write_bytes(b'MOD A, longer')   # a change that makes the modded extraction again
        self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertNotEqual(os.stat(modded / 'RomFS.img').st_ino, img.st_ino)
        self.assertTrue((rw / 'main.key').is_file(), 'the variant rewrite\'s cache is kept: its own key says when it is stale')

    def test_a_stopped_rebuild_leaves_no_key(self):
        work = self.root / 'work'
        self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        extra = self.mods / f'contents/{TITLE:016X}/B/romfs/Data/b.bin'; extra.parent.mkdir(parents=True); extra.write_bytes(b'B')
        with mock.patch.object(gm, 'patch_exefs', side_effect=KeyboardInterrupt), self.assertRaises(KeyboardInterrupt):
            self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertFalse((work / 'mods/v0.key').exists())
        extra.unlink()   # back to the first run's mods: made again, not taken for that run's
        modded, _, _ = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertNotEqual(self.nsp.PROG.end.call_args.args[0], 'reused (the mods and the game files unchanged)')
        self.assertNotIn('Data/b.bin', romfs_image.read_index(modded / 'RomFS.img'))

    def test_the_romfs_mods_key_the_shader_stages(self):   # a file of the same size leaves the image's names and sizes as they were
        work = self.root / 'work'; rk = work / 'mods/v0.romfs.key'; mod = self.mods / f'contents/{TITLE:016X}/romfs/Data/a.bin'
        self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        first = rk.read_text()
        mod.write_bytes(b'MOD B'); st = mod.stat(); os.utime(mod, ns=(st.st_atime_ns, st.st_mtime_ns + 1_000_000_000))
        self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertNotEqual(rk.read_text(), first)
        mod.unlink()
        self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertFalse(rk.exists(), 'no RomFS mods: the shader stages keep their keys')

    def test_a_profile_with_its_own_frame_rate_takes_no_frame_rate_mod(self):
        sys.path.insert(0, str(REPO / 'dm/games')); import game
        self.assertFalse(self.nsp.frame_rate_mods_ok(game.load('01005CA01580E000')), 'Persona 5 Royal: present_interval_choice on')
        self.assertFalse(self.nsp.frame_rate_mods_ok(game.load('0100B04011742000')), 'Monster Hunter Rise: fps_target 60')
        self.assertTrue(self.nsp.frame_rate_mods_ok({'fps_target': '0'}))
        (self.mods / 'exefs_patches/fps').rename(self.mods / 'exefs_patches/60FPS')
        work = self.root / 'work'
        _, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE, fps_ok=self.nsp.frame_rate_mods_ok({'present_interval_choice': 'on'}))
        self.assertEqual(variants, {})
        self.assertIn('left out: exefs_patches/60FPS', (work / 'mods/v0.txt').read_text())

    def test_an_ipad_only_app_has_no_ultrawide(self):
        both = lambda: {'fps': {'mod': '60FPS'}, 'ultrawide': {'mod': '21.9'}}
        self.assertEqual(set(self.nsp.device_variants(both(), 'ipad', False)), {'fps'})
        self.assertEqual(set(self.nsp.device_variants(both(), 'iphone', False)), {'fps', 'ultrawide'})
        self.assertEqual(set(self.nsp.device_variants(both(), 'both', False)), {'fps', 'ultrawide'})
        self.assertEqual(set(self.nsp.device_variants(both(), 'ipad', True)), {'fps', 'ultrawide'}, 'the Mac keeps it (DM_MOD_ULTRAWIDE=1 checks its bytes)')

    def test_programs_cheats_in_one_folder(self):   # a game of several programs: each program's packed cheats, under its builds' IDs
        a, b = self.root / 'a', self.root / 'b'; a.mkdir(); b.mkdir()
        (a / '0000000000000001.txt').write_text('[A]\n'); (b / '0000000000000002.txt').write_text('[B]\n')
        (a / 'FFFFFFFFFFFFFFFF.txt').write_text('[same]\n'); (b / 'FFFFFFFFFFFFFFFF.txt').write_text('[same]\n')
        dst = self.nsp.merge_cheats([(a, '0000000000000001'), (b, '0000000000000002')], self.root / 'all')
        self.assertEqual(sorted(p.name for p in dst.iterdir()), ['0000000000000001.txt', '0000000000000002.txt', 'FFFFFFFFFFFFFFFF.txt'])
        ino = os.stat(dst / '0000000000000002.txt').st_ino
        self.nsp.merge_cheats([(a, '0000000000000001'), (b, '0000000000000002')], self.root / 'all')
        self.assertEqual(os.stat(dst / '0000000000000002.txt').st_ino, ino, 'unchanged: kept')

    def test_a_programs_own_build_file_comes_from_that_program(self):   # a later program's own title folder adds codes to its build's file that the first program does not pack
        a, b = self.root / 'a', self.root / 'b'; a.mkdir(); b.mkdir()
        (a / '0000000000000002.txt').write_text('[loose]\n'); (b / '0000000000000002.txt').write_text('[own]\n\n[loose]\n')
        (a / 'FFFFFFFFFFFFFFFF.txt').write_text('[first]\n'); (b / 'FFFFFFFFFFFFFFFF.txt').write_text('[later]\n')
        dst = self.nsp.merge_cheats([(a, '0000000000000001'), (b, '0000000000000002')], self.root / 'all')
        self.assertEqual((dst / '0000000000000002.txt').read_text(), '[own]\n\n[loose]\n', "program 2's own build: its copy")
        self.assertEqual((dst / 'FFFFFFFFFFFFFFFF.txt').read_text(), '[first]\n', "no program's build: the first program's copy")

    def test_the_cleanup_keeps_the_players_mods_folder(self):   # --work-dir the NSP folder, the mods beside the game: the extraction's mods/ is the player's
        nsp_dir = self.root / 'nsp'; work, other = nsp_dir, nsp_dir / 'p1_build'
        for d in (work / 'extract', work / 'mods/cheats', other / 'extract', other / 'mods/v0_cheats'): d.mkdir(parents=True)
        programs = {1: {'ex': other / 'extract'}}
        left = lambda mods_root: self.nsp.extracted_leftovers(work / 'extract', work, programs, mods_root)
        self.assertEqual(left(work / 'mods'), [work / 'extract', other / 'extract', other / 'mods'], 'the mods folder itself stays')
        self.assertEqual(left(work / 'mods/cheats'), [work / 'extract', other / 'extract', other / 'mods'], 'and a folder holding it')
        self.assertEqual(left(self.root / 'elsewhere'), [work / 'extract', work / 'mods', other / 'extract', other / 'mods'])
        self.assertEqual(left(None), [work / 'extract', work / 'mods', other / 'extract', other / 'mods'])

    def test_a_later_program_leaves_loose_cheats_to_the_first(self):   # a cheat file not named after a build ID was made for one program's build: the first's, as before
        for rel in ('cheats/inf.txt', f'contents/{TITLE:016X}/cheats/own.txt', 'cheats/0000000000000001.txt'): (self.mods / rel).parent.mkdir(parents=True, exist_ok=True); (self.mods / rel).write_text('[Inf]\n')
        packed = lambda first: sorted(p.name for p in self.nsp.apply_mods(self.mods, self.ext, self.root / f'work{first}', 'v0', TITLE, first=first)[1].iterdir())
        self.assertEqual(packed(True), ['0000000000000001.txt', f'{BID[:16]}.txt'])
        self.assertEqual(packed(False), ['0000000000000001.txt', f'{BID[:16]}.txt'])
        first, later = ((self.root / f'work{b}/mods/v0_cheats/{BID[:16]}.txt').read_text() for b in (True, False))
        self.assertEqual(first.count('[Inf]'), 2, 'the first program: the loose file and its own title folder\'s')
        self.assertEqual(later.count('[Inf]'), 1, 'a later program: only its own title folder\'s')
        self.assertIn('cheats/inf.txt is not named after a build ID: left to the first program', (self.root / 'workFalse/mods/v0.txt').read_text())

    def test_settings_are_checked_before_the_build(self):
        game = self.root / 'game'; game.mkdir()
        with mock.patch.object(self.nsp, 'DEVICE', 'iPad Pro'), self.assertRaisesRegex(self.nsp.BuildError, '--device / DEVICE'):
            self.nsp.main(self.nsp.parse_args([str(game)]))
        with self.assertRaisesRegex(self.nsp.BuildError, 'GPU architectures'):
            self.nsp.main(self.nsp.parse_args([str(game), '--gpu', 'g19p g16g']))
        with self.assertRaisesRegex(self.nsp.BuildError, 'not a folder'):
            self.nsp.main(self.nsp.parse_args([str(game), '--mods', str(self.root / 'missing')]))

    def test_cheats_alone_need_no_modded_extraction(self):
        for p in sorted(self.mods.rglob('*'), reverse=True):
            if p.is_file() and p.suffix != '.txt': p.unlink()
        modded, cheats, variants = self.nsp.apply_mods(self.mods, self.ext, self.root / 'work', 'v0', TITLE)
        self.assertIsNone(modded); self.assertEqual(variants, {})
        self.assertTrue((cheats / f'{BID[:16]}.txt').is_file())

    def test_switchable_mods_stay_out_of_the_modded_modules(self):
        (self.mods / 'exefs_patches/fps').rename(self.mods / 'exefs_patches/60 FPS')
        work = self.root / 'work'
        modded, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(nso.read(modded / 'ExeFS/main').image[0x10:0x14], TEXT[0x10:0x14], 'the base build is the game without the mod')
        self.assertEqual(set(variants), {'fps'}); self.assertEqual(variants['fps']['modules'], ['main'])
        self.assertEqual(nso.read(Path(variants['fps']['exefs']) / 'main').image[0x10:0x14], b'\x1f\x20\x03\xd5')
        _, _, none = self.nsp.apply_mods(self.mods, self.ext, self.root / 'work2', 'v0', TITLE, fps_ok=False)
        self.assertEqual(none, {}, 'a profile with its own Frame rate takes no frame-rate mod')

    def test_a_frame_rate_mod_of_the_sdk_alone_is_flagged(self):
        sdk = self.ext / 'ExeFS/sdk'; d = bytearray(make_nso()); d[0x40:0x60] = bytes(range(0x20, 0x40)); sdk.write_bytes(bytes(d))
        sid = bytes(range(0x20, 0x40)).hex().upper()
        (self.mods / 'exefs_patches/fps').rename(self.mods / 'exefs_patches/speed')
        p = self.mods / f'60FPS/exefs/{sid[:40]}.ips'; p.parent.mkdir(parents=True); p.write_bytes(ips([(0x110, b'\x28\x00\x80\x52')]))
        work = self.root / 'work'
        _, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(variants['fps']['modules'], ['sdk'])
        self.assertIn('patches only the sdk module', (work / 'mods/v0.txt').read_text())

    def test_build_variants(self):
        patched = self.root / 'patched'; patched.mkdir()
        hdr = '# TEXT_END 0x4000\n# PATCH_OFF 0x8000\n'
        base = bytes(0xc000)
        (patched / 'main.patched.bin').write_bytes(base); (patched / 'main.fixups.tsv').write_text(hdr)
        (patched / 'old.variants').write_text('stale')
        exefs = self.root / 'v/ExeFS'; exefs.mkdir(parents=True); (exefs / 'main').write_bytes(bytes(make_nso()))
        def fake_run(cmd, log, env=None, fatal=True, **kw):
            rw = Path(cmd[3]); v = bytearray(base); v[0x10:0x14] = b'\x1f\x20\x03\xd5'; v[0x5000:0x5002] = b'\x01\x02'
            (rw / 'main.patched.bin').write_bytes(v); (rw / 'main.fixups.tsv').write_text(hdr); return 0
        with mock.patch.object(self.nsp, 'run', fake_run):
            self.nsp.build_variants(sys.executable, REPO, {'fps': {'mod': '60 FPS', 'exefs': str(exefs), 'modules': ['main']}}, patched, {}, self.root / 'logs')
        self.assertFalse((patched / 'old.variants').exists(), 'earlier variants are removed')
        self.assertEqual(gm.read_variants(patched / 'main.variants'), [('fps', 'c', 0x10, 0x10, b'\x1f\x20\x03\xd5'), ('fps', 'w', 0x5000, 0x5000, b'\x01\x02')])
        self.assertIn('fps\t60 FPS\t2', (patched / 'mods.tsv').read_text())
        with mock.patch.object(self.nsp, 'run', lambda *a, **k: 1):
            for f in (exefs.parent / 'rewrite').iterdir(): f.unlink()
            self.nsp.build_variants(sys.executable, REPO, {'fps': {'mod': '60 FPS', 'exefs': str(exefs), 'modules': ['main']}}, patched, {}, self.root / 'logs')
        self.assertFalse((patched / 'mods.tsv').exists(), 'a mod the rewriter refuses is not offered')

    def test_variant_rewrite_key(self):   # the variant rewrite is reused while the rewriter's inputs are as at its last run, as the base rewrite is
        patched = self.root / 'patched'; patched.mkdir()
        hdr = '# TEXT_END 0x4000\n# PATCH_OFF 0x8000\n'
        (patched / 'main.patched.bin').write_bytes(bytes(0xc000)); (patched / 'main.fixups.tsv').write_text(hdr)
        exefs = self.root / 'v/ExeFS'; exefs.mkdir(parents=True); (exefs / 'main').write_bytes(bytes(make_nso()))
        tool = self.root / 'fps_target.py'; tool.write_text('v1')
        runs = []
        def fake_run(cmd, log, env=None, fatal=True, **kw):
            runs.append(cmd); rw = Path(cmd[3]); v = bytearray(0xc000); v[0x10:0x14] = b'\x1f\x20\x03\xd5'
            (rw / 'main.patched.bin').write_bytes(v); (rw / 'main.fixups.tsv').write_text(hdr)
            if tool.read_text() == 'stops': raise KeyboardInterrupt
            return 0
        build = lambda: self.nsp.build_variants(sys.executable, REPO, {'fps': {'mod': '60 FPS', 'exefs': str(exefs), 'modules': ['main']}}, patched, {}, self.root / 'logs')
        with mock.patch.object(self.nsp, 'run', fake_run), mock.patch.object(self.nsp, 'rewrite_tools', lambda repo: [tool]):
            build(); build(); self.assertEqual(len(runs), 1)
            tool.write_text('v2'); build(); self.assertEqual(len(runs), 2, 'a module patch_nso.py imports')
            with mock.patch('capstone.__version__', '0.0'): build()
            self.assertEqual(len(runs), 3, 'capstone')
            tool.write_text('stops')
            with self.assertRaises(KeyboardInterrupt): build()
            self.assertFalse((exefs.parent / 'rewrite/main.key').exists(), 'a rewrite that stopped leaves no key over its outputs')
            tool.write_text('v2'); build(); self.assertEqual(len(runs), 5, 'back to the inputs of a finished run: rewritten again all the same')
        self.assertIn('fps\t60 FPS', (patched / 'mods.tsv').read_text())

    def test_folder_setting(self):
        args = self.nsp.parse_args(['x'])
        self.assertIsNone(self.nsp.mods_folder(args, self.root / 'none'))
        (self.root / 'game/mods').mkdir(parents=True)
        self.assertEqual(self.nsp.mods_folder(args, self.root / 'game'), self.root / 'game/mods', 'the folder named mods beside the game\'s files')
        self.assertIsNone(self.nsp.mods_folder(self.nsp.parse_args(['x', '--no-mods']), self.root / 'game'))
        self.assertEqual(self.nsp.mods_folder(self.nsp.parse_args(['x', '--mods', str(self.mods)]), self.root / 'game'), self.mods.resolve())   # resolved: on macOS the temporary folder is under /var, a link to /private/var
        with self.assertRaises(self.nsp.BuildError): self.nsp.mods_folder(self.nsp.parse_args(['x', '--mods', str(self.root / 'missing')]), self.root)


if __name__ == '__main__':
    unittest.main()
