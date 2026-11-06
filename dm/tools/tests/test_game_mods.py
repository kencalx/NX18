"""dm/tools/game_mods.py: a game's mods folder (code patches, RomFS file replacements, cheats) on synthetic modules and images; no game files or keys needed"""
import hashlib
import importlib.util
import os
import shutil
from pathlib import Path
import struct
import subprocess
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
from test_nso import make_nso, TEXT, RO, DATA

TITLE = 0x0100ABCD12340000
BUILD = bytes(range(0x20))   # make_nso's build ID
BID = BUILD.hex().upper()


def ips(records, rle=()):
    body = b''.join(o.to_bytes(3, 'big') + len(d).to_bytes(2, 'big') + d for o, d in records)
    body += b''.join(o.to_bytes(3, 'big') + b'\0\0' + n.to_bytes(2, 'big') + bytes([v]) for o, n, v in rle)
    return b'PATCH' + body + b'EOF'


def ips32(records):
    return b'IPS32' + b''.join(o.to_bytes(4, 'big') + len(d).to_bytes(2, 'big') + d for o, d in records) + b'EEOF'


def pchtxt(*blocks, bid=BID[:40]):
    """An IPSwitch text patch of @enabled blocks (name, [(image offset, bytes)]), with offset_shift 0x100 as mods write them, so an offset is the module image's"""
    out = [f'@nsobid-{bid}', '@flag offset_shift 0x100', '']
    for name, recs in blocks: out += [f'// {name}', '@enabled'] + [f'{at:08X} {d.hex().upper()}' for at, d in recs] + ['']
    return '\n'.join(out) + '\n'


# AArch64 words for synthetic patches
NOP, MOV_W0_1, MOV_W0_2, BR_X16 = (struct.pack('<I', w) for w in (0xd503201f, 0x52800020, 0x52800040, 0xd61f0200))
def enc_b(pc, to, link=False): return struct.pack('<I', (0x94000000 if link else 0x14000000) | ((to - pc) >> 2 & 0x3ffffff))
def enc_bcond(pc, to): return struct.pack('<I', 0x54000000 | ((to - pc) >> 2 & 0x7ffff) << 5)
def enc_cbz(pc, to): return struct.pack('<I', 0xb4000000 | ((to - pc) >> 2 & 0x7ffff) << 5)
def enc_tbz(pc, to): return struct.pack('<I', 0x36000000 | ((to - pc) >> 2 & 0x3fff) << 5)
def enc_adrp(pc, to, rd):
    imm = ((to & ~0xfff) - (pc & ~0xfff)) >> 12
    return struct.pack('<I', 0x90000000 | (imm & 3) << 29 | ((imm >> 2) & 0x7ffff) << 5 | rd)
def enc_add(rd, rn, lo): return struct.pack('<I', 0x91000000 | lo << 10 | rn << 5 | rd)
def enc_ldr_lit(pc, to, rt=0): return struct.pack('<I', 0x58000000 | ((to - pc) >> 2 & 0x7ffff) << 5 | rt)
def enc_ldr_d_lit(pc, to, rt=0): return struct.pack('<I', 0x5c000000 | ((to - pc) >> 2 & 0x7ffff) << 5 | rt)   # ldr d<rt>, a literal of 8 bytes
def enc_adr(pc, to, rd):
    imm = to - pc
    return struct.pack('<I', 0x10000000 | (imm & 3) << 29 | ((imm >> 2) & 0x7ffff) << 5 | rd)


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
        report, changed, left = gm.patch_exefs(exefs, dst, gm.scan(self.mods, TITLE))
        self.assertEqual(changed, ['main']); self.assertEqual(left, [])
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


class Guard(unittest.TestCase):
    """patch_exefs judges each patch before writing: records outside the module's text, ro and data (but a code cave its own code enters, taken out with its hook), a branch
    out of its text, or code that needs a patch left out"""
    TEXT = NOP * 0x500   # text 0..0x1400; make_nso puts ro at 0x2000..0x2bb8, data at 0x3000..0x4200, the bss after it to 0x9200 (0xa000 on whole pages)

    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name); self.mods = self.root / 'mods'
        self.exefs = self.root / 'ExeFS'; self.exefs.mkdir()
        (self.exefs / 'main').write_bytes(bytes(make_nso((self.TEXT, RO, DATA))))

    def put(self, rel, data: bytes | str):
        p = self.mods / rel; p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(data if isinstance(data, bytes) else data.encode())

    def patch(self, files):   # files: {path in the mods folder: its content}; returns the report, the modules changed, the patches left out, main's image
        for rel, data in files.items(): self.put(rel, data)
        dst = self.root / 'out'
        report, changed, left = gm.patch_exefs(self.exefs, dst, gm.scan(self.mods, TITLE))
        return report, changed, left, nso.read(dst / 'main').image

    def red(self, report): return [line for line in report if line.startswith('[RED]')]

    def test_a_record_in_the_bss_leaves_its_patch_out_whole(self):
        report, changed, left, img = self.patch({'Mod/exefs/p.pchtxt': pchtxt(('Cave', [(0x10, MOV_W0_1), (0x5000, NOP)]), ('Keep', [(0x20, MOV_W0_1)]))})
        self.assertEqual(changed, ['main'])
        self.assertEqual(img[0x10:0x14], NOP, 'none of the patch is written')
        self.assertEqual(img[0x20:0x24], MOV_W0_1, 'the other patch is')
        why = ("[RED] main: Mod/exefs/p.pchtxt: Cave: left out: 1 of its 2 records lie outside main's text, ro and data, the first at main+0x5000, in its bss, past its data "
               "(memory the module's file does not hold): Nintanium cannot carry a code cave or a bss write, which only an emulator runs")
        self.assertEqual(self.red(report), [why])
        self.assertEqual(left, [gm.LeftOut('main', 'Mod/exefs/p.pchtxt: Cave', 'Mod', why)])
        self.assertIn('main: Mod/exefs/p.pchtxt: Keep: 4 bytes in 1 records', report)

    def test_padding_and_past_the_module_no_longer_stop_the_build(self):   # nso_with_image keeps only the segments: a byte in the padding failed its check (AssertionError)
        report, changed, left, img = self.patch({f'{n}/{BID[:40]}.ips': ips([(0x100 + at, NOP)]) for n, at in (('a', 0x1400), ('b', 0x2c00), ('c', 0xa000), ('d', 0x13fe))})
        self.assertEqual(changed, [], 'every patch left out: the module is the game\'s own')
        self.assertEqual((self.root / 'out/main').read_bytes(), (self.exefs / 'main').read_bytes())
        self.assertEqual([lo.what for lo in left], [f'{n}/{BID[:40]}.ips' for n in 'abcd'])
        text = ("in the padding between its text and ro, which the module's file does not hold: a Switch runs code there, in the rest of its text's last page, but Nintanium "
                "carries only what the module's file holds")
        self.assertEqual([line.split(', the first at ')[1].split(', ', 1)[1] for line in self.red(report)],
                         [text, "in the padding between its ro and data, which the module's file does not hold: Nintanium carries only what the module's file holds",
                          "past the module's end (after its bss): Nintanium cannot carry a code cave or a bss write, which only an emulator runs", text])
        self.assertIn('the first at main+0x1400,', self.red(report)[3], 'a record that runs past the text: its first byte outside')
        self.assertEqual(img, nso.read(self.exefs / 'main').image)

    def test_zeros_outside_the_segments_change_nothing(self):   # zero bytes in the padding or the bss, where the memory is zero at start: written, or cut with the note, as before
        report, changed, left, img = self.patch({f'A/{BID[:40]}.ips': ips([(0x100 + 0x10, MOV_W0_1), (0x100 + 0x41f0, bytes(0x20)), (0x100 + 0x1400, bytes(0x10)), (0x100 + 0x6000, bytes(4))])})
        self.assertEqual((left, changed), ([], ['main']))
        self.assertEqual(report, [f"main: A/{BID[:40]}.ips: 36 bytes in 4 records, 2 records past the module's end ignored"])
        self.assertEqual(img[0x10:0x14], MOV_W0_1); self.assertEqual(img[0x41f0:0x4200], bytes(0x10))

    def test_the_hook_and_its_cave_in_one_block(self):   # Super Mario Odyssey's Ultrawide mod's shape: the mod, a hook into the bss and the cave's code there, in one block
        cave = 0x5000
        uw = [(0x40, MOV_W0_1), (0x100, enc_b(0x100, cave))] + [(cave + 4 * k, NOP) for k in range(16)] + [(cave + 0x40, enc_b(cave + 0x40, 0x104))]
        report, changed, left, img = self.patch({'UW/exefs/p.pchtxt': pchtxt(('Ultrawide and HUD', uw), ('Layout', [(0x80, MOV_W0_2)]))})
        why = ("[RED] main: UW/exefs/p.pchtxt: Ultrawide and HUD: left out of it: its code cave, 17 records outside main's text, ro and data from main+0x5000, in its bss, past "
               "its data (memory the module's file does not hold), and the record of its code in the text that leads there, at main+0x100: Nintanium cannot carry a code cave or "
               "a bss write, which only an emulator runs. The rest of it, 1 of its 19 records, is kept as a patch of its own")
        self.assertEqual(left, [gm.LeftOut('main', 'UW/exefs/p.pchtxt: Ultrawide and HUD: its code cave at main+0x5000 and the code that enters it', 'UW', why)])
        self.assertEqual(report, [why, 'main: UW/exefs/p.pchtxt: Ultrawide and HUD: 4 bytes in 1 of its 19 records', 'main: UW/exefs/p.pchtxt: Layout: 4 bytes in 1 records'])
        self.assertEqual((img[0x40:0x44], img[0x100:0x104], img[0x80:0x84]), (MOV_W0_1, NOP, MOV_W0_2), 'the hook is not written, the rest of its block and the other block are')
        self.assertEqual(changed, ['main'])

    def test_a_block_with_a_cave_is_left_out_whole_unless_the_rest_stands_apart(self):
        cave = [(0x5000 + 4 * k, NOP) for k in range(4)]
        blocks = (('Next to the hook', [(0x40, MOV_W0_1), (0x108, MOV_W0_2), (0x100, enc_b(0x100, 0x5000))] + cave),   # a record beside the hook may belong to it
                  ('Through a register', [(0x240, MOV_W0_1), (0x300, enc_adrp(0x300, 0x6000, 16)), (0x304, enc_add(16, 16, 0)), (0x308, BR_X16), (0x6000, NOP)]),   # no direct branch enters it
                  ('A run no branch enters', [(0x440, MOV_W0_1), (0x500, enc_b(0x500, 0x7000)), (0x7000, NOP), (0x8000, NOP)]),
                  ('Only the hook', [(0x600, enc_b(0x600, 0x8800)), (0x8800, NOP)]))
        report, _, left, img = self.patch({'M/exefs/p.pchtxt': pchtxt(*blocks)})
        self.assertEqual([lo.what.split(': ')[1] for lo in left], [b[0] for b in blocks])
        self.assertTrue(left[0].why.endswith("; its other records are left out with them, as its record at main+0x108 lies next to its code that enters them, at main+0x100, and "
                                             "may belong to it"), left[0].why)
        self.assertIn('left out: 1 of its 5 records lie outside', left[1].why); self.assertIn('left out: 2 of its 4 records lie outside', left[2].why)
        self.assertEqual(img[0:0x1400], self.TEXT)

    def test_a_patch_whose_code_needs_one_left_out(self):
        cave = 0x400   # a patch's own code in the text, with a record in the bss: left out, and every patch of its mod that goes there with it
        blocks = (('Cave', [(cave, MOV_W0_1), (cave + 4, enc_b(cave + 4, 0x104)), (0x6000, NOP)]),
                  ('Hook', [(0x100, enc_b(0x100, cave))]),                                                        # a branch into the cave's code
                  ('Far hook', [(0x200, enc_adrp(0x200, cave, 16)), (0x204, enc_add(16, 16, cave & 0xfff)), (0x208, BR_X16)]),   # adrp + add + br there
                  ('Chain', [(0x300, enc_b(0x300, 0x100))]),                                                       # into Hook's code: left out once Hook is
                  ('Other', [(0x500, enc_b(0x500, 0x600)), (0x504, enc_ldr_lit(0x504, 0x3000))]),                   # nothing of the cave's
                  ('Adr', [(0x340, enc_adr(0x340, cave + 4, 1))]), ('Literal', [(0x344, enc_ldr_lit(0x344, cave))]),
                  ('Page', [(0x348, enc_adrp(0x348, cave, 2)), (0x34c, MOV_W0_1)]),                                     # an adrp whose add is not found: its whole page
                  ('Prefetch', [(0x350, struct.pack('<I', 0xd8000000 | ((cave - 0x350) >> 2) << 5))]))                  # prfm (literal) reads nothing
        report, changed, left, img = self.patch({'Mod/exefs/p.pchtxt': pchtxt(*blocks), 'Mod2/exefs/q.pchtxt': pchtxt(('Another mod', [(0x700, enc_b(0x700, cave))]))})
        self.assertEqual([lo.what.split(': ')[1] for lo in left], ['Cave', 'Hook', 'Far hook', 'Chain', 'Adr', 'Literal', 'Page'])
        self.assertEqual(left[1].why, "[RED] main: Mod/exefs/p.pchtxt: Hook: left out: its code at main+0x100 refers to main+0x400, which Mod/exefs/p.pchtxt: Cave writes, "
                                      "and that is left out (this code may need it, as a hook needs its cave)")
        self.assertIn('its code at main+0x200 refers to main+0x400, which Mod/exefs/p.pchtxt: Cave writes', left[2].why, 'the address adrp and add make')
        self.assertIn('refers to main+0x100, which Mod/exefs/p.pchtxt: Hook writes', left[3].why)
        self.assertEqual([lo.why.split('its code at ')[1].split(', which')[0] for lo in left[4:]], ['main+0x340 refers to main+0x404', 'main+0x344 refers to main+0x400',
                                                                                                      'main+0x348 refers to main+0x0'])
        self.assertEqual(img[0x350:0x354], struct.pack('<I', 0xd8000000 | ((cave - 0x350) >> 2) << 5))
        self.assertEqual((img[0x100:0x104], img[0x200:0x204], img[0x300:0x304], img[cave:cave + 4]), (NOP,) * 4)
        self.assertEqual(img[0x500:0x504], enc_b(0x500, 0x600)); self.assertEqual(img[0x700:0x704], enc_b(0x700, cave), 'another mod\'s patch is not judged by this one\'s')
        self.assertEqual(report.index(left[0].why) + 1, report.index(left[1].why), 'each [RED] line in its patch\'s place')

    def test_a_branch_out_of_the_text(self):
        blocks = (('Into ro', [(0x100, enc_b(0x100, 0x2000))]), ('Into data', [(0x104, enc_b(0x104, 0x3000, link=True))]), ('B.cond', [(0x108, enc_bcond(0x108, 0x2100))]),
                  ('CBZ', [(0x10c, enc_cbz(0x10c, 0x4300))]), ('TBZ', [(0x110, enc_tbz(0x110, 0x1400))]), ('Before', [(0x114, enc_b(0x114, -0x10))]),
                  ('In the text', [(0x118, enc_b(0x118, 0x13fc)), (0x11c, enc_cbz(0x11c, 0)), (0x120, enc_tbz(0x120, 0x200))]))
        report, changed, left, img = self.patch({'Mod/exefs/p.pchtxt': pchtxt(*blocks)})
        self.assertEqual([lo.what.split(': ')[1] for lo in left], ['Into ro', 'Into data', 'B.cond', 'CBZ', 'TBZ', 'Before'])
        self.assertEqual(left[0].why, "[RED] main: Mod/exefs/p.pchtxt: Into ro: left out: the patch's code at main+0x100 branches to main+0x2000, outside the module's code (in its ro): "
                                      'the iPhone runs only signed pages')
        self.assertEqual([lo.why.split('code (')[1].split(')')[0] for lo in left[1:]],
                         ['in its data', 'in its ro', "in its bss, past its data (memory the module's file does not hold", "in the padding between its text and ro, which the module's file does not hold",
                          'before the module'])
        self.assertIn('branches to main-0x10,', left[5].why)
        self.assertEqual(img[0x118:0x124], enc_b(0x118, 0x13fc) + enc_cbz(0x11c, 0) + enc_tbz(0x120, 0x200)); self.assertEqual(img[0x100:0x118], NOP * 6)

    def test_a_branch_into_the_cave_of_a_patch_left_out_names_it(self):
        report, _, left, _ = self.patch({'Mod/exefs/p.pchtxt': pchtxt(('Cave', [(0x5000, NOP)]), ('Hook', [(0x100, enc_b(0x100, 0x5000))]))})
        self.assertIn("branches to main+0x5000, outside the module's code (in its bss, past its data (memory the module's file does not hold), where Mod/exefs/p.pchtxt: Cave puts its code)", left[1].why)

    def test_part_of_a_word_makes_the_branch(self):   # the words as they read with the patch in: a record of one byte or two can turn a word into a branch
        report, _, left, img = self.patch({'Mod/exefs/p.pchtxt': pchtxt(('Top byte', [(0x203, b'\x14')]), ('Halves', [(0x300, bytes.fromhex('0080')), (0x302, bytes.fromhex('0014'))]),
                                                                       ('A word kept', [(0x403, b'\x52')]))})
        self.assertEqual([lo.what.split(': ')[1] for lo in left], ['Top byte', 'Halves'])
        self.assertIn('code at main+0x200 branches to main+0xc827c', left[0].why)   # 1f 20 03 14: b +0x3201f words
        self.assertIn('code at main+0x300 branches to main+0x20300', left[1].why)
        self.assertEqual(img[0x200:0x204] + img[0x300:0x304], NOP * 2); self.assertEqual(img[0x400:0x404], NOP[:3] + b'\x52')

    def test_overwritten_bytes_belong_to_the_later_patch(self):   # a word the later patch writes whole is judged as its, not the earlier patch's
        report, _, left, img = self.patch({'A/exefs/p.pchtxt': pchtxt(('Out', [(0x100, enc_b(0x100, 0x2000))])), 'B/exefs/p.pchtxt': pchtxt(('Over it', [(0x100, MOV_W0_1)]))})
        self.assertEqual(left, []); self.assertEqual(img[0x100:0x104], MOV_W0_1)
        self.assertIn('[RED] B/exefs/p.pchtxt: Over it overwrites A/exefs/p.pchtxt: Out at main+0x100', report)

    def test_a_word_two_patches_write_is_blamed_on_the_one_that_makes_it_a_branch(self):
        report, _, left, img = self.patch({'A/exefs/p.pchtxt': pchtxt(('Move', [(0x100, MOV_W0_1)])), 'B/exefs/p.pchtxt': pchtxt(('Top byte', [(0x103, b'\x17')]))})
        self.assertEqual([lo.what for lo in left], ['B/exefs/p.pchtxt: Top byte'], 'the later patch made the move a branch: the earlier one is fine on its own')
        self.assertEqual(img[0x100:0x104], MOV_W0_1)
        out = enc_b(0x200, 0x2000)   # c0 07 00 14: a later byte that keeps it a branch out of the text leaves out the earlier patch, which made it one
        report, _, left, img = self.patch({'A/exefs/p.pchtxt': pchtxt(('Move', [(0x100, MOV_W0_1)]), ('Out', [(0x200, out)])), 'B/exefs/p.pchtxt': pchtxt(('Top byte', [(0x103, b'\x17')]), ('Low', [(0x202, b'\x01')]))})
        self.assertEqual([lo.what for lo in left], ['A/exefs/p.pchtxt: Out', 'B/exefs/p.pchtxt: Top byte'])
        self.assertEqual(img[0x200:0x204], NOP[:2] + b'\x01' + NOP[3:], 'judged again without it: its byte over the game\'s word is no branch')

    def test_the_check_on_its_own_says_what_is_left_out(self):   # game_mods.py <mods> <title ID> <ExeFS>: what patch_exefs would write, nothing written
        cave = [(0x5000 + 4 * k, NOP) for k in range(4)]
        for rel, data in {'UW/exefs/p.pchtxt': pchtxt(('Ultrawide', [(0x40, MOV_W0_1), (0x100, enc_b(0x100, 0x5000))] + cave), ('Out', [(0x200, enc_b(0x200, 0x2000))]))}.items():
            self.put(rel, data)
        r = subprocess.run([sys.executable, str(REPO / 'dm/tools/game_mods.py'), str(self.mods), f'{TITLE:016X}', str(self.exefs)], capture_output=True, text=True, timeout=60)
        self.assertEqual(r.returncode, 0, r.stderr)
        lines = r.stdout.splitlines()
        self.assertEqual([line.split(': left out')[0] for line in lines if line.startswith('[RED]')], ['[RED] main: UW/exefs/p.pchtxt: Ultrawide', '[RED] main: UW/exefs/p.pchtxt: Out'])
        self.assertIn('main: UW/exefs/p.pchtxt: Ultrawide: 1 of its 6 records', lines); self.assertNotIn('main: UW/exefs/p.pchtxt: Out: 1 records', lines)

    def test_a_literal_the_code_loads_is_data(self):   # the low word of the double 0.0333 reads as a BL far out of the text
        lit = struct.pack('<d', 0.0333); self.assertIsNotNone(gm.a64.direct_branch_target(struct.unpack('<I', lit[:4])[0], 0x108))
        report, _, left, img = self.patch({'M/exefs/p.pchtxt': pchtxt(('Pool', [(0x100, enc_ldr_d_lit(0x100, 0x108)), (0x104, enc_b(0x104, 0x110)), (0x108, lit)]),
                                                                      ('No load', [(0x200, lit)]))})
        self.assertEqual([lo.what.split(': ')[1] for lo in left], ['No load'], 'a word no literal load reads is taken for code')
        self.assertEqual(img[0x100:0x110], enc_ldr_d_lit(0x100, 0x108) + enc_b(0x104, 0x110) + lit)

    def test_in_text_branches_ro_and_data_patches_are_written_as_before(self):   # the module and the report byte for byte what patch_exefs wrote before the judge
        m = nso.read(self.exefs / 'main'); f = struct.pack('<f', 21 / 9)
        blocks = (('Branches', [(0x100, enc_b(0x100, 0x13fc)), (0x104, enc_b(0x104, 0, link=True)), (0x108, enc_bcond(0x108, 0x400)), (0x10c, enc_cbz(0x10c, 0x10)),
                                (0x110, enc_tbz(0x110, 0x120)), (0x114, enc_adrp(0x114, 0x3010, 1)), (0x118, enc_add(1, 1, 0x10)), (0x11c, enc_ldr_lit(0x11c, 0x2000))]),
                  ('ro', [(0x2000, b'Hello, ro'), (0x2bb0, b'\xaa' * 8)]), ('data', [(0x3000, f), (0x41fc, b'\x01\x02\x03\x04')]),
                  ('zeros', [(0x41f0, bytes(0x20)), (0x1400, bytes(0x10))]), ('empty', []))   # zeros into the bss and the padding; an @enabled block with no record
        files = {'Mod/exefs/p.pchtxt': pchtxt(*blocks),
                 f'Z/{BID[:40]}.ips': ips([(0x100 + 0x500, enc_b(0x500, 0x504)), (0x100 + 0x100, MOV_W0_2), (0xfe, b'\xee\xee' + MOV_W0_1[:2])])}   # its first two bytes in the NSO header, never patched
        report, changed, left, img = self.patch(files)
        self.assertEqual(left, []); self.assertEqual(changed, ['main'])
        ref, lines, written = bytearray(m.image), [], {}
        plan, _ = gm.code_patches(gm.scan(self.mods, TITLE), gm.nso_modules(self.exefs))
        for what, recs, _ in plan['main']:   # patch_exefs before the judge
            for off, data in recs:
                for k in range(off, off + len(data)):
                    if k in written and written[k] != what: lines.append(f'[RED] {what} overwrites {written[k]} at main+{k - 0x100:#x}'); break
                for k in range(off, off + len(data)): written[k] = what
            n, outside = gm.apply_records(ref, recs)
            lines.append(f'main: {what}: {n} bytes in {len(recs)} records' + (f', {outside} records past the module\'s end ignored' if outside else ''))
        self.assertEqual((self.root / 'out/main').read_bytes(), gm.nso_with_image((self.exefs / 'main').read_bytes(), ref))
        self.assertEqual(report, lines); self.assertIn("main: Mod/exefs/p.pchtxt: zeros: 32 bytes in 2 records, 1 records past the module's end ignored", lines)
        self.assertEqual(img[0x100:0x104], MOV_W0_2, 'the later file wins, as before'); self.assertEqual(img[0:2], MOV_W0_1[:2])


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

    def test_variant_runs_refuse_a_branch_out_of_the_code(self):   # the backstop behind patch_exefs: a changed word of the text that branches out of the signed code
        a, b = self.root / 'a', self.root / 'b'; a.mkdir(); b.mkdir()
        def runs(hdr, size, *edits):
            x = bytearray(size); y = bytearray(x)
            for at, w in edits: y[at:at + len(w)] = w
            for d, data in ((a, x), (b, y)): (d / 'main.patched.bin').write_bytes(data); (d / 'main.fixups.tsv').write_text(hdr)
            return gm.variant_runs(a, b, 'main', bytes(0x40))
        near = '# TEXT_END 0x3800\n# PATCH_OFF 0x20000\n'   # the text to 0x3800, its 16 KB page to 0x4000 (code too), the patch area from 0x20000
        self.assertTrue(runs(near, 0x24000, (0x10, enc_b(0x10, 0x37fc)), (0x14, enc_b(0x14, 0x20010)), (0x18, enc_b(0x18, 0x3f00, link=True))), 'into the code: kept')
        self.assertTrue(runs(near, 0x24000, (0x3900, enc_b(0x3900, 0x8000)), (0x21000, enc_b(0x21000, 0x8000))), 'the first ro page and the patch area are not decoded')
        with self.assertRaisesRegex(gm.ModError, r"main: the mod's code at \+0x10 branches to \+0x8000, outside the module's code \(its text and patch area\): the iPhone runs only signed pages"):
            runs(near, 0x24000, (0x10, enc_b(0x10, 0x8000)))
        with self.assertRaisesRegex(gm.ModError, r'at \+0x20 branches to \+0x400020'): runs(near, 0x24000, (0x22, b'\x10\x14'))   # two bytes that make a b +0x100000 words
        with self.assertRaisesRegex(gm.ModError, r'at \+0x30 branches'): runs(near, 0x24000, (0x30, enc_cbz(0x30, 0x5000)))
        far = '# TEXT_END 0x4000\n# PATCH_OFF -0x8000\n# FILE_IMAGE_LEN 0x10000\n'   # the patch area before the base
        self.assertTrue(runs(far, 0x18000, (0x10, enc_b(0x10, -0x7ff0))), 'into the patch area before the base')
        with self.assertRaisesRegex(gm.ModError, r'branches to -0x10000'): runs(far, 0x18000, (0x10, enc_b(0x10, -0x10000)))
        two = far + '# BACK_OFF 0x10000\n# BACK_LEN 0x4000\n'   # and a back one after the image: a run before the base is not the text, whatever its image offset reads in the file
        self.assertTrue(runs(two, 0x1c000, (0x10010, NOP), (0x14010, enc_b(0x14010, 0x8000))), 'a patch area word changed, a branch-like word elsewhere in it')
        lit = struct.pack('<d', 0.0333)   # a literal the changed code loads is data; the same word no load reads is taken for a branch
        self.assertTrue(runs(near, 0x24000, (0x100, enc_ldr_d_lit(0x100, 0x108) + enc_b(0x104, 0x110) + lit)))
        with self.assertRaisesRegex(gm.ModError, r'at \+0x200 branches'): runs(near, 0x24000, (0x200, lit))


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

    def test_a_switchable_mod_is_offered_without_the_patches_left_out(self):
        uw = self.mods / '21.9 Ultrawide/exefs/uw.pchtxt'; uw.parent.mkdir(parents=True)
        uw.write_text(pchtxt(('Aspect', [(0x20, MOV_W0_1)]), ('Joy-Con fix', [(0x24, enc_b(0x24, 0x4300)), (0x4300, NOP)])))   # the hook and its cave in the bss
        work = self.root / 'work'
        _, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(set(variants), {'fps', 'ultrawide'}); self.assertEqual(variants['ultrawide']['left_out'], ['21.9 Ultrawide/exefs/uw.pchtxt: Joy-Con fix'])
        self.assertNotIn('left_out', variants['fps'])
        img = nso.read(Path(variants['ultrawide']['exefs']) / 'main').image
        self.assertEqual(img[0x20:0x24], MOV_W0_1); self.assertEqual(img[0x24:0x28], TEXT[0x24:0x28], 'the hook is not written')
        report = (work / 'mods/v0.txt').read_text()
        self.assertIn("[RED] main: 21.9 Ultrawide/exefs/uw.pchtxt: Joy-Con fix: left out: 1 of its 2 records lie outside main's text, ro and data, the first at main+0x4300, in its bss", report)
        self.assertIn('21.9 Ultrawide/exefs/uw.pchtxt: Aspect: no aspect value found', report)
        self.assertNotIn('Joy-Con fix: no aspect value found', report, 'adapt_aspect\'s line goes with a patch left out whole')
        self.assertIn('[RED] ultrawide: 21.9 Ultrawide: left out of it (above): 21.9 Ultrawide/exefs/uw.pchtxt: Joy-Con fix. The rest of the mod is offered (Ultrawide in the launcher)\n', report)
        self.assertEqual(self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)[2], variants)
        self.assertIn('[RED] ultrawide: 21.9 Ultrawide: left out of it', (work / 'mods/v0.txt').read_text(), 'a reuse keeps the lines')
        uw.write_text(pchtxt(('Joy-Con fix', [(0x24, enc_b(0x24, 0x4300)), (0x4300, NOP)]), ('Header note', [])))   # nothing of it left to write: a block of no record is nothing
        _, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(set(variants), {'fps'}); self.assertFalse((work / 'mods/v0_ultrawide').exists())
        self.assertIn('[RED] ultrawide: 21.9 Ultrawide: nothing of it is left to write for this version once the patches above are left out: Ultrawide is not offered\n',
                      (work / 'mods/v0.txt').read_text())

    def test_a_mod_whose_code_cave_shares_its_block_is_offered_without_the_cave(self):   # Super Mario Odyssey's Ultrawide pack: the mod, the hook and the cave in one block
        uw = self.mods / '21.9 Ultrawide/exefs/uw.pchtxt'; uw.parent.mkdir(parents=True)
        uw.write_text(pchtxt(('Ultrawide, uses a codecave at 4300', [(0x20, MOV_W0_1), (0x80, enc_b(0x80, 0x4300))] + [(0x4300 + 4 * k, NOP) for k in range(4)])))
        work = self.root / 'work'
        _, _, variants = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual(variants['ultrawide']['left_out'], ['21.9 Ultrawide/exefs/uw.pchtxt: Ultrawide, uses a codecave at 4300: its code cave at main+0x4300 and the code that enters it'])
        img = nso.read(Path(variants['ultrawide']['exefs']) / 'main').image
        self.assertEqual((img[0x20:0x24], img[0x80:0x84]), (MOV_W0_1, TEXT[0x80:0x84]), 'the mod is offered, its hook not written')
        report = (work / 'mods/v0.txt').read_text()
        self.assertIn('main: 21.9 Ultrawide/exefs/uw.pchtxt: Ultrawide, uses a codecave at 4300: 4 bytes in 1 of its 6 records\n', report)
        self.assertIn('[RED] ultrawide: 21.9 Ultrawide: left out of it (above): 21.9 Ultrawide/exefs/uw.pchtxt: Ultrawide, uses a codecave at 4300: its code cave at main+0x4300 '
                      'and the code that enters it. The rest of the mod is offered (Ultrawide in the launcher)\n', report)

    def test_a_kept_mods_patch_left_out_is_not_written(self):
        (self.mods / 'exefs_patches/fps').rename(self.mods / 'exefs_patches/speed')   # written in for good: NOP at 0x10
        p = self.mods / 'HUD/exefs/hud.pchtxt'; p.parent.mkdir(parents=True)
        p.write_text(pchtxt(('Into ro', [(0x30, enc_b(0x30, 0x2000))]), ('Kept', [(0x40, MOV_W0_2)])))
        work = self.root / 'work'
        modded, _, _ = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        img = nso.read(modded / 'ExeFS/main').image
        self.assertEqual((img[0x10:0x14], img[0x30:0x34], img[0x40:0x44]), (b'\x1f\x20\x03\xd5', TEXT[0x30:0x34], MOV_W0_2))
        self.assertIn("[RED] main: HUD/exefs/hud.pchtxt: Into ro: left out: the patch's code at main+0x30 branches to main+0x2000", (work / 'mods/v0.txt').read_text())
        p.write_text(pchtxt(('Into ro', [(0x30, enc_b(0x30, 0x2000))])))
        (self.mods / 'exefs_patches/speed').rename(self.mods / 'exefs_patches/-speed')
        modded, _, _ = self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
        self.assertEqual((modded / 'ExeFS/main').read_bytes(), (self.ext / 'ExeFS/main').read_bytes(), 'nothing left: the game\'s own module')
        self.assertIn("code: nothing is left to write for this version once the patches above are left out: the code is the game's own", (work / 'mods/v0.txt').read_text())

    def test_the_mods_key_covers_the_code_that_judges_patches(self):   # a changed a64_words.py (the branch decoders) makes the modded modules again
        tools = self.root / 'tools'; tools.mkdir()
        for f in ('game_mods.py', 'a64_words.py', 'romfs_image.py', 'romfs.py', 'nso.py'): shutil.copy(Path(gm.__file__).parent / f, tools / f)
        work = self.root / 'work'
        with mock.patch.object(gm, '__file__', str(tools / 'game_mods.py')):
            self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE); self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
            self.nsp.PROG.end.assert_called_with('reused (the mods and the game files unchanged)')
            (tools / 'a64_words.py').write_text((tools / 'a64_words.py').read_text() + '\n# changed\n')
            self.nsp.apply_mods(self.mods, self.ext, work, 'v0', TITLE)
            self.assertNotIn('reused', self.nsp.PROG.end.call_args.args[0])

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
        def out_of_code(cmd, log, env=None, fatal=True, **kw):   # a variant whose text branches into the writable part: variant_runs refuses it
            rw = Path(cmd[3]); v = bytearray(base); v[0x10:0x14] = enc_b(0x10, 0x5000)
            (rw / 'main.patched.bin').write_bytes(v); (rw / 'main.fixups.tsv').write_text(hdr); return 0
        said = []
        with mock.patch.object(self.nsp, 'run', out_of_code), mock.patch.object(self.nsp, 'say', said.append):
            for f in (exefs.parent / 'rewrite').iterdir(): f.unlink()
            self.nsp.build_variants(sys.executable, REPO, {'fps': {'mod': '60 FPS', 'exefs': str(exefs), 'modules': ['main']}}, patched, {}, self.root / 'logs')
        self.assertFalse((patched / 'mods.tsv').exists()); self.assertFalse((patched / 'main.variants').exists())
        self.assertIn("mods: [RED] fps: 60 FPS: left out: main: the mod's code at +0x10 branches to +0x5000, outside the module's code (its text and patch area): the iPhone runs only "
                      'signed pages', said)
        said.clear()
        with mock.patch.object(self.nsp, 'run', fake_run), mock.patch.object(self.nsp, 'say', said.append):   # a role the mods stage offers without some of its patches
            for f in (exefs.parent / 'rewrite').iterdir(): f.unlink()
            self.nsp.build_variants(sys.executable, REPO, {'fps': {'mod': '60 FPS', 'exefs': str(exefs), 'modules': ['main'], 'left_out': ['60 FPS/exefs/a.pchtxt: Cave']}}, patched, {},
                                    self.root / 'logs')
        self.assertEqual((patched / 'mods.tsv').read_text().splitlines()[1:], ['fps\t60 FPS\t2'])
        self.assertIn('mods: [RED] High frame rate offered in the launcher without part of it: 60 FPS (2 changed byte runs); left out in the mods stage: 60 FPS/exefs/a.pchtxt: Cave', said)

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


FAKE_REWRITER = r"""# patch_nso.py as build_variants starts it (<module> <out folder> <name>): writes <ver>_<role>/want.bin as the rewrite, after a pause; no want.bin, or a refuse_<name>: refused (exit 3)
import os, shutil, sys, time
src, rw, m = sys.argv[1:4]
var = os.path.dirname(os.path.dirname(src)); role = os.path.basename(var).split('_', 1)[1]; rec = os.path.join(os.path.dirname(var), 'record.txt')
with open(rec, 'a') as f: f.write(f'{role} start {time.time()} {os.environ.get("DM_REWRITE_J")} {m}\n')
print(f'rewriting {m} with the {role} mod', flush=True)
time.sleep(0.6)
if not os.path.exists(os.path.join(var, 'want.bin')) or os.path.exists(os.path.join(var, 'refuse_' + m)): print('refused: a word the profile patches too'); sys.exit(3)
shutil.copyfile(os.path.join(var, 'want.bin'), os.path.join(rw, m + '.patched.bin'))
with open(os.path.join(rw, m + '.fixups.tsv'), 'w') as f: f.write('# TEXT_END 0x4000\n# PATCH_OFF 0x8000\n')
with open(rec, 'a') as f: f.write(f'{role} end {time.time()}\n')
"""


class VariantPool(unittest.TestCase):
    """build_variants' rewrites run together (DM_VARIANT_J), the byte runs kept beside each variant rewrite (DM_VARIANT_RUNS_CACHE), and the files they make, byte for byte those
    of rewriting one after another and computing the runs at every build, as before; a real process per rewrite (a fake patch_nso.py in a fake repository)"""
    HDR = '# TEXT_END 0x4000\n# PATCH_OFF 0x8000\n'

    def setUp(self):
        spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        assert spec and spec.loader
        self.nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.nsp)
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name); self.said = []
        for cm in (mock.patch.object(self.nsp, 'PROG', mock.Mock()), mock.patch.object(self.nsp, 'say', self.said.append)):
            cm.start(); self.addCleanup(cm.stop)
        self.repo = self.root / 'repo'; (self.repo / 'dm/tools').mkdir(parents=True); (self.repo / 'dm/tools/patch_nso.py').write_text(FAKE_REWRITER)
        self.patched = self.root / 'patched'; self.patched.mkdir()
        self.base = bytes(0xc000)
        (self.patched / 'main.patched.bin').write_bytes(self.base); (self.patched / 'main.fixups.tsv').write_text(self.HDR)
        self.mods = self.root / 'mods'; self.variants = {}
        for role, name, edits in (('fps', '60 FPS', ((0x10, b'\x1f\x20\x03\xd5'), (0x5000, b'\x01\x02'))), ('ultrawide', '21x9', ((0x5100, struct.pack('<f', 21 / 9)),))):
            exefs = self.mods / f'v0_{role}/ExeFS'; exefs.mkdir(parents=True); (exefs / 'main').write_bytes(bytes(make_nso()))
            v = bytearray(self.base)
            for at, b in edits: v[at:at + len(b)] = b
            (exefs.parent / 'want.bin').write_bytes(bytes(v))
            self.variants[role] = {'mod': name, 'exefs': str(exefs), 'modules': ['main']}
        self.env = {k: v for k, v in os.environ.items() if not k.startswith('DM_')}

    def build(self, **env):
        (self.mods / 'record.txt').unlink(missing_ok=True)
        self.nsp.build_variants(sys.executable, self.repo, json_copy(self.variants), self.patched, dict(self.env, **env), self.root / 'logs')
        rec = (self.mods / 'record.txt').read_text().splitlines() if (self.mods / 'record.txt').exists() else []
        return [l.split() for l in rec]

    def outputs(self):
        return {p.name: p.read_bytes() for p in sorted(self.patched.iterdir()) if p.suffix in ('.variants', '.tsv') and p.name != 'main.fixups.tsv'}

    def expected(self):   # what the serial build_variants of before wrote: each role's runs (game_mods.variant_runs) in role order, then mods.tsv
        rows, counts = [], []
        for role, v in self.variants.items():
            runs = gm.variant_runs(self.patched, Path(v['exefs']).parent / 'rewrite', 'main', nso.read(Path(v['exefs']) / 'main').image)
            rows += [(role, r) for r in runs]; counts.append((role, v['mod'], len(runs)))
        gm.write_variants(self.root / 'expected.variants', rows)
        return {'main.variants': (self.root / 'expected.variants').read_bytes(),
                'mods.tsv': ('# switchable mods the launcher offers (dm/games/settings.py mods:<role>): role\tmod\truns\n' + ''.join(f'{r}\t{n}\t{c}\n' for r, n, c in counts)).encode()}

    def test_rewrites_run_together_and_write_what_one_after_another_writes(self):
        cores = os.cpu_count() or 1
        cm = mock.patch.object(os, 'cpu_count', lambda: max(2, cores)); cm.start(); self.addCleanup(cm.stop)   # the default pool is at most one rewrite per core: a one-core runner would run them one after another
        rec = self.build()
        starts = [float(l[2]) for l in rec if l[1] == 'start']; ends = [float(l[2]) for l in rec if l[1] == 'end']
        self.assertEqual(len(starts), 2); self.assertLess(max(starts), min(ends), 'both rewrites ran at once')
        split = str(max(1, (os.cpu_count() or 1) // 2))
        self.assertEqual({l[3] for l in rec if l[1] == 'start'}, {split}, 'the cores split between them (DM_REWRITE_J)')
        together = self.outputs()
        self.assertEqual(together, self.expected())
        self.assertIn(b'ultrawide\tw\t0x5100\t0x5100\t', together['main.variants'])
        for role in ('fps', 'ultrawide'): self.assertIn(f'rewriting main with the {role} mod', (self.root / f'logs/rewrite_main_{role}.log').read_text())
        for f in (self.mods / 'v0_fps/rewrite', self.mods / 'v0_ultrawide/rewrite'): shutil.rmtree(f)
        rec = self.build(DM_VARIANT_J='1')
        starts = [float(l[2]) for l in rec if l[1] == 'start']; ends = [float(l[2]) for l in rec if l[1] == 'end']
        self.assertGreaterEqual(starts[1], ends[0], 'DM_VARIANT_J=1: one after another')
        self.assertEqual({l[3] for l in rec if l[1] == 'start'}, {'None'}, 'with the environment as it was')
        self.assertEqual(self.outputs(), together)
        rec = self.build(DM_REWRITE_J='3')
        self.assertEqual(rec, [], 'reused: nothing rewritten again')
        self.assertEqual(self.outputs(), together)

    def test_an_explicit_split_is_kept(self):
        rec = self.build(DM_REWRITE_J='3')
        self.assertEqual({l[3] for l in rec if l[1] == 'start'}, {'3'})

    def test_a_refused_role_alone_is_left_out(self):
        (self.mods / 'v0_ultrawide/want.bin').unlink()
        self.build()
        self.assertEqual((self.patched / 'mods.tsv').read_text().splitlines()[1:], ['fps\t60 FPS\t2'])
        self.assertTrue(any('ultrawide: 21x9: left out: the rewriter refused main' in m and 'rewrite_main_ultrawide.log' in m for m in self.said))
        self.assertIn('refused: a word the profile patches too', ''.join(str(c) for c in self.nsp.PROG.say.call_args_list), 'the log\'s last lines, as run() prints them')
        self.assertTrue((self.mods / 'v0_fps/rewrite/main.key').is_file()); self.assertFalse((self.mods / 'v0_ultrawide/rewrite/main.key').exists())
        self.assertEqual([l[0] for l in self.build() if l[1] == 'start'], ['ultrawide'], 'only the refused rewrite runs again')

    def test_one_after_another_a_roles_modules_stop_at_its_first_failure(self):   # DM_VARIANT_J=1, as before the pool: a module after the refused one is not rewritten
        (self.mods / 'v0_fps/ExeFS/sub').write_bytes(bytes(make_nso())); (self.mods / 'v0_fps/refuse_main').write_text('')
        self.variants['fps']['modules'] = ['main', 'sub']
        rec = self.build(DM_VARIANT_J='1')
        self.assertEqual([(l[0], l[4]) for l in rec if l[1] == 'start'], [('fps', 'main'), ('ultrawide', 'main')])
        self.assertTrue(any('fps: 60 FPS: left out: the rewriter refused main' in m for m in self.said))
        self.assertFalse((self.mods / 'v0_fps/rewrite/sub.key').exists()); self.assertEqual((self.patched / 'mods.tsv').read_text().splitlines()[1:], ['ultrawide\t21x9\t1'])
        pooled = self.build(DM_VARIANT_J='3')   # together, every planned rewrite has started before the first one is refused: the files written are the same
        self.assertEqual(sorted((l[0], l[4]) for l in pooled if l[1] == 'start'), [('fps', 'main'), ('fps', 'sub')])
        self.assertEqual((self.patched / 'mods.tsv').read_text().splitlines()[1:], ['ultrawide\t21x9\t1'])
        (self.mods / 'v0_fps/refuse_main').unlink(); self.build(DM_VARIANT_J='1')
        kept = (self.mods / 'v0_fps/rewrite/sub.key').read_text()
        (self.mods / 'v0_fps/refuse_main').write_text('')
        rec = self.build(DM_VARIANT_J='1', DM_PATCH_FRONT='1')   # every key misses; main is refused, so sub is not reached and keeps its key and rewrite, as before the pool
        self.assertEqual([(l[0], l[4]) for l in rec if l[1] == 'start'], [('fps', 'main'), ('ultrawide', 'main')])
        self.assertEqual((self.mods / 'v0_fps/rewrite/sub.key').read_text(), kept)
        (self.mods / 'v0_fps/refuse_main').unlink()
        rec = self.build(DM_VARIANT_J='1')   # the inputs of before: sub's kept rewrite is reused
        self.assertEqual([(l[0], l[4]) for l in rec if l[1] == 'start'], [('fps', 'main'), ('ultrawide', 'main')])

    def test_the_runs_are_kept_and_follow_their_inputs(self):
        self.build(); first = self.outputs()
        calls = []
        real = gm.variant_runs
        def counting(*a): calls.append(a[1].parent.name); return real(*a)
        with mock.patch.object(gm, 'variant_runs', counting), mock.patch.object(self.nsp.nso, 'read', wraps=self.nsp.nso.read) as read:
            self.build(); self.assertEqual(calls, []); read.assert_not_called()
            self.assertEqual(self.outputs(), first, 'the kept runs write the same bytes')
            self.build(DM_VARIANT_RUNS_CACHE='0'); self.assertEqual(calls, ['v0_fps', 'v0_ultrawide'], 'DM_VARIANT_RUNS_CACHE=0: computed at every build')
            self.assertEqual(self.outputs(), first); calls.clear()
            self.build(); self.assertEqual(calls, ['v0_fps', 'v0_ultrawide'], 'that build removed them'); calls.clear()
            self.build(); self.assertEqual(calls, []); self.assertEqual(self.outputs(), first)
            rw = self.mods / 'v0_ultrawide/rewrite'
            d = bytearray((rw / 'main.patched.bin').read_bytes()); d[0x5104] = 7; (rw / 'main.patched.bin').write_bytes(bytes(d))   # the variant's output written behind the step's back
            self.build(); self.assertEqual(calls, ['v0_ultrawide']); calls.clear()
            self.assertIn(b'ultrawide\tw\t0x5100\t0x5100\t' + struct.pack('<f', 21 / 9).hex().encode() + b'07', self.outputs()['main.variants'])
            (rw / 'main.runs.json').write_text('{not json'); self.build(); self.assertEqual(calls, ['v0_ultrawide'], 'a damaged file'); calls.clear()
            (self.mods / 'v0_fps/want.bin').write_bytes(bytes(self.base[:0x10]) + b'\x1f\x20\x03\xd5' + bytes(self.base[0x14:]))   # another mod: the variant key changes, so its rewrite and runs are made again
            (self.mods / 'v0_fps/ExeFS/main').write_bytes(bytes(make_nso()) + b'\0')
            rec = self.build(); self.assertEqual([l[0] for l in rec if l[1] == 'start'], ['fps']); self.assertEqual(calls, ['v0_fps']); calls.clear()
            self.assertEqual((self.patched / 'mods.tsv').read_text().splitlines()[1], 'fps\t60 FPS\t1')
            gmf = self.root / 'game_mods.py'; gmf.write_bytes(Path(gm.__file__).read_bytes())
            with mock.patch.object(gm, '__file__', str(gmf)):
                self.build(); self.assertEqual(calls, [], 'the same game_mods.py by content')
                gmf.write_text(gmf.read_text() + '\n# changed\n'); self.build(); self.assertEqual(calls, ['v0_fps', 'v0_ultrawide'], 'game_mods.py, which computes them'); calls.clear()
                self.build(); self.assertEqual(calls, [])
            before = self.outputs()
            (self.patched / 'main.gates.tsv').write_text('gate\n')   # the base rewrite's table changes alone (a base rewrite run again): its patched.bin is the same, so is the variant key
            rec = self.build(); self.assertEqual(rec, []); self.assertEqual(calls, ['v0_fps', 'v0_ultrawide'], 'the base rewrite\'s tables'); calls.clear()
            self.assertFalse((self.patched / 'mods.tsv').exists(), 'both refused: their rewrites differ in gates.tsv')
            refusals = [m for m in self.said if 'differs in gates.tsv' in m]; self.said.clear()
            self.build(); self.assertEqual(calls, [], 'a refusal is kept too'); self.assertEqual([m for m in self.said if 'differs in gates.tsv' in m], refusals, 'with its message')
            (self.patched / 'main.gates.tsv').unlink(); self.build(); self.assertEqual(self.outputs(), before)

    def test_the_cache_writes_what_computing_again_writes(self):   # every reuse state, the same bytes as rewriting and computing with the old behaviour (one after another, no kept runs)
        self.build(DM_VARIANT_J='1', DM_VARIANT_RUNS_CACHE='0'); old = self.outputs(); self.assertEqual(old, self.expected())
        for env in ({}, {}, {'DM_VARIANT_J': '1'}, {'DM_VARIANT_RUNS_CACHE': '0'}, {}):
            with self.subTest(env=env): self.build(**env); self.assertEqual(self.outputs(), old)

    def test_switch_values(self):
        for bad in ('0', '-1', 'two'):
            with self.subTest(bad=bad), self.assertRaisesRegex(self.nsp.BuildError, 'DM_VARIANT_J must be a positive integer'): self.nsp.variant_workers({'DM_VARIANT_J': bad}, 2)
        self.assertEqual(self.nsp.variant_workers({'DM_VARIANT_J': '8'}, 2), 2)
        self.assertEqual(self.nsp.variant_workers({}, 1), 1)
        self.assertEqual(self.nsp.variant_workers({}, 2), min(2, os.cpu_count() or 1))

    def test_fingerprint_memo_is_the_same_key(self):   # build_variants hashes the base rewrite once for all roles: the keys are those of before
        files = [self.patched / 'main.patched.bin', self.patched / 'main.fixups.tsv', self.root / 'missing']
        memo, plain = {}, self.nsp.fingerprint(('files', files), 'x')
        self.assertEqual(self.nsp.fingerprint(('files', files), 'x', memo=memo), plain)
        self.assertEqual(memo[str(files[2])], b'missing')
        with mock.patch.object(self.nsp.rfs.Path, 'read_bytes', side_effect=AssertionError('read again')):
            self.assertEqual(self.nsp.fingerprint(('files', files), 'x', memo=memo), plain, 'each file read once')


MAC_READER = r'''#include "mod_rows.h"
int main(int argc, char **argv) {   // the rows the Mac host puts in place from a .variants file with both roles on (loader.c), one per line: role, kind, image offset, bytes in hex
    FILE *f = argc > 1 ? fopen(argv[1], "r") : NULL;
    if (!f) return 2;
    dm_mod_rows rows; dm_mod_rows_read(f, 3, &rows); fclose(f);
    printf("bad %u %ld %ld\n", rows.bad, rows.bad_line[0], rows.bad_line[1]);
    for (size_t i = 0; i < rows.n; i++) {
        const dm_mod_row *r = &rows.row[i];
        if (rows.bad & r->role) continue;   // a role with a row it cannot read: none of it
        printf("%s\t%c\t%lld\t", r->role == DM_MOD_ROLE_FPS ? "fps" : "ultrawide", r->code ? 'c' : 'w', r->io);
        for (size_t k = 0; k < r->len; k++) printf("%02x", r->bytes[k]);
        putchar('\n');
    }
    dm_mod_rows_free(&rows);
    return 0;
}
'''


class MacReader(unittest.TestCase):
    """dm/host/mod_rows.h, the Mac host's reader of <module>.variants (loader.c mod_variants_one): what write_variants writes, read back as read_variants reads it, rows past
    64 KB included, and a role with a row it cannot read left out whole; and dm/host/tests/t_mod_rows.c (the host tests run it on the Mac), plain and under ASan and UBSan"""
    HOST = REPO / 'dm/host'

    def cc(self, out, src, *flags):
        c = os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc')
        if not c: self.skipTest('no C compiler')
        return subprocess.run([c, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', *flags, '-I', str(self.HOST), '-o', str(out), str(src)], capture_output=True, text=True)

    def test_what_write_variants_writes(self):
        with tempfile.TemporaryDirectory() as t:
            t = Path(t); (t / 'drv.c').write_text(MAC_READER)
            r = self.cc(t / 'drv', t / 'drv.c'); self.assertEqual(r.returncode, 0, r.stderr)
            rows = [('fps', ('c', 0x10, 0x10, NOP)), ('ultrawide', ('w', 0x24000, -0x8000, bytes(range(256)) * 400)), ('fps', ('w', 0x5000, 0x5000, b'\x01'))]
            gm.write_variants(t / 'main.variants', rows)
            def mac():
                out = subprocess.run([str(t / 'drv'), str(t / 'main.variants')], capture_output=True, text=True, timeout=60)
                self.assertEqual(out.returncode, 0, out.stderr)
                head, *lines = out.stdout.splitlines()
                return head, [(r, k, int(io), bytes.fromhex(h)) for r, k, io, h in (line.split('\t') for line in lines)]
            self.assertEqual(mac(), ('bad 0 0 0', [(r, k, io, d) for r, k, _, io, d in gm.read_variants(t / 'main.variants')]))
            self.assertGreater(len((t / 'main.variants').read_text().splitlines()[2]), 1 << 16, 'a row the fixed 64 KB buffer skipped')
            text = (t / 'main.variants').read_text().splitlines()
            (t / 'main.variants').write_text('\n'.join(text[:-1] + [text[-1][:-1]]) + '\n')   # the last fps row cut short: none of fps
            self.assertEqual(mac(), ('bad 1 4 0', [('ultrawide', 'w', -0x8000, bytes(range(256)) * 400)]))

    def test_the_host_unit_test(self):
        for flags in ([], ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']):
            with self.subTest(flags=flags), tempfile.TemporaryDirectory() as t:
                exe = Path(t) / 't_mod_rows'
                r = self.cc(exe, self.HOST / 'tests/t_mod_rows.c', *flags)
                if r.returncode and flags: self.skipTest(f'no sanitizers here: {r.stderr.strip()[:200]}')
                self.assertEqual(r.returncode, 0, r.stderr)
                r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1' if sys.platform.startswith('linux') else '', UBSAN_OPTIONS='halt_on_error=1'))
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr); self.assertIn(', 0 failed', r.stdout)


def json_copy(v):   # the variants as apply_mods hands them over (a JSON file's): build_variants never changes the caller's
    import json
    return json.loads(json.dumps(v))


if __name__ == '__main__':
    unittest.main()
