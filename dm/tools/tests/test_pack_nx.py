"""NX archives (scripts/pack_nx.py, https://github.com/fab918/nxformat, NXFormat 1.0.2): the reader against the format's own conformance fixtures (dm/tools/tests/fixtures/nx, each accepted or
refused with the error code upstream's index names), hostile archives made here (cut short, counts past the limits, unsafe names, zstd frames that break the rules or expand past their block),
the packing of versions, DLC and control data, and the NSP script's NX path up to extraction. The archives besides the fixtures are written by nx_writer.py, test code with its own record
layouts. No network, game files, keys or Xcode needed."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
FIX = HERE / 'fixtures/nx'
sys.path.insert(0, str(REPO / 'dm/tools'))
sys.path.insert(0, str(HERE))
import nacp
import romfs_image
import nx_writer
spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
if spec is None or spec.loader is None: raise ImportError('scripts/build_ipa_from_nsp.py')
nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
pack_nx = nsp.pack_nx
zstd = pack_nx.zstd
INDEX = json.loads((FIX / 'fixture_index.json').read_text())['fixtures']

TID = 0x040074A01BF12000   # a game with a profile in dm/games, whose registered version is an update (as test_nsp_nup.py)
VER = 458752
NEW = 0x0400000000123000   # a title no profile has


def npdm(tid):
    d = bytearray(0x100)
    d[:4] = b'META'
    struct.pack_into('<II', d, 0x70, 0x80, 0x20)
    d[0x80:0x84] = b'ACI0'
    struct.pack_into('<Q', d, 0x90, tid)
    return bytes(d)


def control_nacp(name, display):
    b = bytearray(0x4000)
    b[:len(name)] = name.encode(); b[0x3060:0x3060 + len(display)] = display.encode()
    return bytes(b)


def version(main=b'code', marker='marker', tid=TID):
    return {'exefs': {'main': main, 'main.npdm': npdm(tid), '.listing': b'not a module'}, 'romfs': {f'dir/{marker}': b'data' * 100, 'empty': b''}}


META = {'nacp': control_nacp('Test Game', '1.2.3'), 'icon': b'\xff\xd8 icon', 'title': 'Test Game', 'publisher': 'Tester'}


def game(*snaps, tid=TID, platform=1):
    return [{'id': tid, 'platform': platform, 'snapshots': list(snaps)}]


def fixture(name):
    return pack_nx.Nx(FIX / name)


@unittest.skipIf(zstd is None, 'no zstd module')
class Fixtures(unittest.TestCase):
    """Upstream's conformance corpus: every file as the index says, each accepted or refused with the expected code"""
    def test_files_are_the_indexed_ones(self):
        self.assertEqual(len(INDEX), 61)
        for f in INDEX:
            with self.subTest(f=f['file']):
                b = (FIX / f['file']).read_bytes()
                self.assertEqual((len(b), hashlib.sha256(b).hexdigest()), (f['size'], f['sha256']))
        self.assertIn('MIT License', (FIX / 'LICENSE').read_text())

    def test_each_fixture_accepted_or_refused_as_expected(self):
        for f in INDEX:
            with self.subTest(f=f['file'], expected=f['expected']):
                if f['expected'] == 'reject':
                    with self.assertRaises(pack_nx.Error) as e: fixture(f['file'])
                    self.assertEqual(e.exception.code, f['expected_error'], str(e.exception))
                    self.assertIn(f['file'], str(e.exception))   # the message names the archive
                    continue
                with fixture(f['file']) as n:
                    if f['expected'] == 'accept': n.verify(crc=True); n.verify(crc=False)
                    else:   # reject_full_verify: opens, and full verification names the damaged block, with or without every CRC
                        for crc in (True, False):
                            with self.assertRaises(pack_nx.Error) as e: n.verify(crc=crc)
                            self.assertEqual(e.exception.code, f['expected_error'], str(e.exception))

    def file(self, n, path, snapshot=0):
        d = n.snapshots[snapshot].root
        *dirs, name = path.encode().split(b'/')
        for x in dirs: d = n.subdir(d, x)
        i = n.child(d, name)
        self.assertIsNotNone(i, path)
        return n.read(i)

    def test_contents(self):
        with fixture('raw_only.nx') as n: self.assertEqual(self.file(n, 'data.bin'), b'NX!?')
        with fixture('nested_vfs.nx') as n:
            self.assertEqual((self.file(n, 'root.txt'), self.file(n, 'folder/child.bin')), (b'root', b'nested child'))
        with fixture('zstd_single.nx') as n:
            self.assertEqual(self.file(n, 'compressed.bin'), b'A' * 4096)
            self.assertEqual(n._block(0)[1:4], (19, 4096, 1))   # one 19-byte frame
            self.assertEqual(n.snapshots[0].build_id.hex(), '00112233445566778899aabbccddeeff102132435465768798a9bacbdcedfe0f')
        with fixture('multi_block_file.nx') as n:
            self.assertEqual(self.file(n, 'large.bin'), bytes((i * 31 + 7) & 0xFF for i in range(65537)))
            self.assertEqual([n._block(b)[2] for b in range(n.nblocks)], [65536, 1])
        with fixture('mixed_raw_zstd.nx') as n:
            self.assertEqual(self.file(n, 'mixed.bin'), bytes((i * 31 + 7) & 0xFF for i in range(256 * 1024)) + b'Z' * (256 * 1024))
            self.assertEqual([n._block(b)[3] for b in range(n.nblocks)], [0, 1])
            self.assertEqual(n.head(n.child(n.snapshots[0].root, b'mixed.bin'), 4), bytes([7, 38, 69, 100]))
        with fixture('empty_files.nx') as n:
            i = n.child(n.snapshots[0].root, b'empty.bin')
            self.assertEqual((n.read(i), n.sha(i)), (b'', hashlib.sha256(b'').digest()))
        with fixture('shared_blocks.nx') as n:
            self.assertEqual((self.file(n, 'a.bin'), self.file(n, 'b.bin'), n.nblocks), (b'same', b'same', 1))
        with fixture('deleted_between_versions.nx') as n:
            names = [[x for x, _, _ in n.children(s.root)] for s in n.snapshots]
            self.assertEqual(names, [[b'keep.bin', b'remove.bin'], [b'keep.bin']])

    def test_snapshots_and_identities(self):
        with fixture('shared_snapshots.nx') as n:
            a, b = n.snapshots
            self.assertEqual(a.root, b.root); self.assertNotEqual(a.identity, b.identity)
        with fixture('dlc_without_program.nx') as n:
            self.assertEqual((n.snapshots[1].type, n.snapshots[1].program), (pack_nx.DLC, pack_nx.NO))
        with fixture('dlc_only_application.nx') as n, self.assertRaisesRegex(pack_nx.Error, 'no game, only DLC'): pack_nx.scan(n)
        with fixture('same_application_id_cross_platform.nx') as n:
            with self.assertRaisesRegex(pack_nx.Error, 'holds 2 games') as e: pack_nx.scan(n)
            self.assertEqual(e.exception.code, 'select')
            self.assertEqual(sorted(a.platform for a in n.apps), [0, 2])
        with fixture('multiple_programs.nx') as n:
            self.assertEqual(pack_nx.primary(n.apps[0]).id, n.apps[0].id)   # the application's own program of its two
            with self.assertRaisesRegex(pack_nx.Error, 'no snapshot of 0100000000000001 holds exefs/ or romfs/'): pack_nx.scan(n)   # its trees are not a game's

    def test_generations(self):
        for name, gen in (('appended_generation.nx', 1), ('appended_generation_2.nx', 2), ('interrupted_commit.nx', 0), ('lost_header_page_0.nx', 1),
                          ('lost_header_page_1.nx', 2), ('max_generation.nx', 2**64 - 1), ('damaged_slot_a.nx', 0), ('bad_header_page_padding_1.nx', 0)):
            with self.subTest(name=name), fixture(name) as n:
                self.assertEqual(n.generation, gen)
                self.assertIsNone(n.fell_back)

    def test_metadata_tied_to_its_snapshot(self):
        with fixture('metadata_snapshot_tie.nx') as n:
            self.assertEqual(n.apps[0].meta_snapshot, 1)
            old = n.meta(n.snapshots[0])
            self.assertEqual(old['nacp'], b'synthetic native NACP for snapshot zero')   # the history row's, never the application's
            self.assertTrue(old['icon'].startswith(b'\x89PNG'))
            self.assertIsNone(n.meta(n.snapshots[1])['nacp'])
        with fixture('jpeg_icon.nx') as n:
            icon = n.meta(n.snapshots[0])['icon']
            self.assertEqual((len(icon), icon[:2]), (285, b'\xff\xd8'))
            self.assertEqual(hashlib.sha256(icon).digest(), n.media_records[0][3])
        with fixture('switch2_localized_icons.nx') as n:
            self.assertEqual(n.apps[0].platform, 2)
            self.assertEqual([lang for lang, _, _ in n.apps[0].localized], ['fr', 'ja'])
            self.assertIsNotNone(n.meta(n.snapshots[0])['icon'])   # no default icon: the first localized one

    def test_history_row_naming_the_metadata_snapshot_is_refused(self):   # upstream's validator's extra mutation
        b = bytearray((FIX / 'metadata_snapshot_tie.nx').read_bytes())
        off, _ = nx_writer.catalog_span(b)
        nexts, ext_off, app_off = struct.unpack_from('<I', b, off + 40)[0], struct.unpack_from('<Q', b, off + 88)[0], struct.unpack_from('<Q', b, off + 48)[0]
        for e in range(nexts):
            t, _, kind, _, owner, p_off, _ = struct.unpack_from('<IIHHIQQ', b, off + ext_off + 32 * e)
            if (t, kind, owner) == (0x00010004, 1, 0): break
        else: self.fail('no history extension')
        struct.pack_into('<I', b, off + p_off + 24, struct.unpack_from('<I', b, off + app_off + 68)[0])
        with self.assertRaises(pack_nx.Error) as e: self.open_bytes(nx_writer.reseal(bytes(b)))
        self.assertEqual(e.exception.code, 'catalog')

    def open_bytes(self, data):
        td = tempfile.TemporaryDirectory(); self.addCleanup(td.cleanup)
        p = Path(td.name) / 'x.nx'; p.write_bytes(data)
        n = pack_nx.Nx(p); self.addCleanup(n.close); return n

    def test_crc32c(self):
        self.assertEqual(pack_nx.crc32c(b'123456789'), 0xE3069283)
        data = os.urandom(1000)
        self.assertEqual(pack_nx.crc32c(data), nx_writer.crc32c(data))
        self.assertEqual(pack_nx.crc32c(data[300:], pack_nx.crc32c(data[:300])), pack_nx.crc32c(data))

    def test_is_nx(self):
        self.assertTrue(pack_nx.is_nx(FIX / 'damaged_slot_a.nx'))   # slot B still says NXAR
        self.assertFalse(pack_nx.is_nx(FIX / 'damaged_both_slots.nx'))
        self.assertFalse(pack_nx.is_nx(FIX / 'nonexistent.nx'))


@unittest.skipIf(zstd is None, 'no zstd module')
class Base(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory(); self.addCleanup(td.cleanup)
        self.dir = Path(td.name).resolve() / 'game'; self.dir.mkdir()
        self.path = self.dir / 'game.nx'
        self.write(game({'type': 0, 'version': 0, 'tree': version(marker='old'), 'meta': META},
                        {'type': 1, 'version': VER, 'tree': version(main=b'new code', marker='new'), 'display': '1.2.3'},
                        {'type': 2, 'version': 0, 'addon': TID + 0x1001, 'tree': {'romfs': {'dlcfile': b'dlc'}}}))

    def write(self, apps, path=None, **kw):
        return nx_writer.write(path or self.path, apps, **kw)

    def open(self, path=None, **kw):
        n = pack_nx.Nx(path or self.path, **kw); self.addCleanup(n.close); return n

    def refused(self, data, code, msg='.'):
        self.path.write_bytes(data)
        with self.assertRaises(pack_nx.Error) as e: pack_nx.Nx(self.path)
        self.assertEqual(e.exception.code, code, str(e.exception))
        self.assertRegex(str(e.exception), msg)
        return e.exception

    def one_file(self, content, **kw):   # an archive of one base snapshot holding f.bin; returns its bytes
        return self.write(game({'type': 0, 'version': 0, 'tree': {'f.bin': content}}), **kw)


class Hostile(Base):
    def test_cut_short(self):
        good = self.path.read_bytes()
        for size, code in ((len(good) - 1, 'length'), (8191, 'length'), (5000, 'length'), (100, 'length'), (0, 'length')):
            with self.subTest(size=size): self.refused(good[:size], code)

    def test_counts_past_the_limits(self):
        good = self.path.read_bytes()
        off, _ = nx_writer.catalog_span(good)
        for field, value in ((20, 0xFFFFFFFF), (28, 70000), (40, 5000)):   # applications, snapshots, extensions
            with self.subTest(field=field):
                b = bytearray(good); struct.pack_into('<I', b, off + field, value)
                self.refused(nx_writer.reseal(bytes(b)), 'resource')
        man = struct.unpack_from('<Q', good, 72)[0]
        b = bytearray(good); struct.pack_into('<I', b, man + 16, 0xFFFFFFFF)   # Manifest folders
        self.refused(nx_writer.reseal(bytes(b)), 'resource')
        b = bytearray(good); struct.pack_into('<Q', b, 96, (1 << 32) + 1)   # header block count
        self.refused(nx_writer.reseal(bytes(b)), 'structure')
        b = bytearray(good); struct.pack_into('<Q', b, 16, 1 << 63)   # archive size past the file and INT64_MAX
        self.refused(nx_writer.reseal(bytes(b)), 'length')

    def test_budgets(self):
        for kw in ({'manifest': 100}, {'index': 10}, {'files': 1}, {'nodes': 3}, {'visits': 5}):
            with self.subTest(budget=kw), self.assertRaises(pack_nx.Error) as e: pack_nx.Nx(self.path, budgets=pack_nx.Budgets(**kw))
            self.assertEqual(e.exception.code, 'resource')
        with self.assertRaises(TypeError): pack_nx.Budgets(nonsense=1)

    def test_unsafe_names(self):
        for name in ('..', '.', 'a\\b', 'nul\0'):
            with self.subTest(name=name): self.refused(self.write(game({'type': 0, 'version': 0, 'tree': {'romfs': {name: b'x'}}})), 'path', 'unsafe name')
        b = bytearray(self.write(game({'type': 0, 'version': 0, 'tree': {'romfs': {'QQQQ': b'x'}}})))
        at = b.rindex(b'QQQQ'); b[at:at + 4] = b'\xff\xfe\xfd\xfc'   # not UTF-8
        self.refused(nx_writer.reseal(bytes(b)), 'path', 'not UTF-8')
        # ExeFS names that are fine in the archive but not as host files: two differing only in case
        self.write(game({'type': 0, 'version': 0, 'tree': {'exefs': {'main': b'1', 'MAIN': b'2', 'main.npdm': npdm(TID)}, 'romfs': {'a': b'1'}}}))
        n = self.open()
        with self.assertRaisesRegex(pack_nx.Error, 'differ only in case'): pack_nx.exefs(n, n.snapshots[0], self.dir / 'out/ExeFS')
        self.assertFalse((self.dir / 'out').exists())

    def test_unsorted_or_repeated_names(self):
        data = bytearray(self.write(game({'type': 0, 'version': 0, 'tree': {'romfs': {'aa': b'1', 'ab': b'2'}}})))
        at = data.rindex(b'aaab'); data[at:at + 4] = b'abaa'   # the two names swapped in the path pool: unsorted
        self.refused(nx_writer.reseal(bytes(data)), 'path', 'not sorted')
        data[at:at + 4] = b'aaaa'
        self.refused(nx_writer.reseal(bytes(data)), 'path', 'twice')

    def frame_case(self, frame, content, code='zstd'):
        self.one_file(nx_writer.Frame(frame, content))
        n = self.open()
        with self.assertRaises(pack_nx.Error) as e: n.read(n.child(n.snapshots[0].root, b'f.bin'))
        self.assertEqual(e.exception.code, code, str(e.exception))
        with self.assertRaises(pack_nx.Error): n.verify()
        return e.exception

    def test_zstd_frame_rules(self):
        content = bytes(range(256)) * 4
        good = zstd.compress(content)
        self.one_file(nx_writer.Frame(good, content))
        n = self.open(); self.assertEqual(n.read(n.child(n.snapshots[0].root, b'f.bin')), content); n.verify()
        raw_block = lambda b: struct.pack('<I', 1 | (len(b) << 3))[:3] + b
        def frame(fhd, window=b'', dict_id=b'', fcs=b'', body=content): return pack_nx.ZSTD_MAGIC + bytes([fhd]) + window + dict_id + fcs + raw_block(body)
        self.assertEqual(zstd.decompress(frame(0x80, bytes([7 << 3]), fcs=struct.pack('<I', len(content)))), content)   # the hand-made frame is a valid one
        for what, f in (('two frames', good + good), ('trailing bytes', good + b'\0'), ('skippable frame', struct.pack('<II', 0x184D2A50, 4) + b'skip' + good),
                        ('dictionary', frame(0x81, bytes([7 << 3]), b'\x07', struct.pack('<I', len(content)))),   # dictionary ID 7
                        ('window above 1 MiB', frame(0x80, bytes([12 << 3]), fcs=struct.pack('<I', len(content)))),   # window 4 MiB
                        ('no content size', frame(0x00, bytes([7 << 3]))),
                        ('content size differs', frame(0x80, bytes([7 << 3]), fcs=struct.pack('<I', len(content) + 1))),
                        ('not zstd', b'\0' * 64)):
            with self.subTest(what=what): self.frame_case(f, content)

    def test_decompression_bombs(self):
        content = b'x' * 4096
        rle = lambda n: struct.pack('<I', 1 << 1 | (n << 3))[:3] + b'y'   # an RLE block of n bytes 'y', 4 bytes stored
        lying = pack_nx.ZSTD_MAGIC + bytes([0x40, 7 << 3]) + struct.pack('<H', len(content) - 256) + rle(128 << 10) * 63 + struct.pack('<I', 1 | 1 << 1 | (128 << 13))[:3] + b'y'
        unsized = zstd.compress(bytes(64 << 20), options={zstd.CompressionParameter.content_size_flag: 0, zstd.CompressionParameter.window_log: 20})
        for what, f in (('declares 4 KiB, expands to 8 MiB', lying), ('no content size, 64 MiB of zeros', unsized)):
            with self.subTest(what=what):
                self.assertLess(len(f), 64 << 10)
                t = time.monotonic()
                self.frame_case(f, content)
                self.assertLess(time.monotonic() - t, 5)   # refused at the frame header or after one block's worth of output

    def test_damaged_block_named(self):
        data = bytearray(self.one_file(b'raw payload that stays raw: ' + os.urandom(64), compress=False))
        at = struct.unpack_from('<Q', data, struct.unpack_from('<Q', data, 88)[0])[0]   # block 0's data offset
        data[at + 3] ^= 1   # hashes and CRCs left as written
        self.path.write_bytes(data)
        n = self.open()
        with self.assertRaises(pack_nx.Error) as e: n.read(0)
        self.assertEqual(e.exception.code, 'block_hash')
        self.assertIn('game.nx (base): f.bin: block 0', str(e.exception))
        n.crc = True
        with self.assertRaises(pack_nx.Error) as e: n.read(0)
        self.assertEqual(e.exception.code, 'block_hash')

    def test_digests(self):
        good = self.path.read_bytes()
        off, size = nx_writer.catalog_span(good)
        man, idx = struct.unpack_from('<Q', good, 72)[0], struct.unpack_from('<Q', good, 88)[0]
        for at, code in ((off + 130, 'catalog_hash'), (man + 100, 'manifest_hash'), (idx + 1, 'index_hash')):
            with self.subTest(code=code):
                b = bytearray(good); b[at] ^= 1
                self.refused(bytes(b), code, 'damaged archive')

    def test_versions_and_features(self):
        good = self.path.read_bytes()
        for major, minor, code in ((0, 4, 'version'), (1, 0, 'version'), (0, 1, 'version')):
            with self.subTest(v=(major, minor)):
                b = bytearray(good); struct.pack_into('<HH', b, 4, major, minor)
                e = self.refused(nx_writer.reseal(bytes(b)), code, 'needs a newer NX 18|reads 0.2 and 0.3')
                self.assertIn(f'{major}.{minor}', str(e))
        b = bytearray(good); struct.pack_into('<H', b, 12, 5)
        self.refused(nx_writer.reseal(bytes(b)), 'feature', 'newer reader')

    def test_extensions(self):
        snaps = ({'type': 0, 'version': 0, 'tree': version()},)
        self.write(game(*snaps), extensions=[(0x00020001, 0, 1, 0, b'optional, skipped')])
        self.open()
        e = self.refused(self.write(game(*snaps), extensions=[(0x00020001, 1, 1, 0, b'required')]), 'feature', 'newer NXConvert')
        self.assertIn('0x00020001', str(e))

    def test_source_resources_belong_to_0_3(self):
        snaps = ({'type': 0, 'version': 0, 'tree': version()},)
        self.write(game(*snaps), minor=3, resources=[(1, {'partition.hfs0': b'HFS0' + bytes(60)}), (0, {'a': b'1', 'b': b'2'})])
        n = self.open()
        self.assertEqual((n.version, [k for k, _ in n.resource_dirs]), ((0, 3), [0, 1]))
        n.verify(); pack_nx.scan(n)
        self.refused(self.patch_minor(self.write(game(*snaps)), 3), 'catalog', 'without Source Resources')
        self.refused(self.patch_minor(self.write(game(*snaps), minor=3, resources=[(0, {'a': b'1'})]), 2), 'catalog', 'with Source Resources')
        self.refused(self.write(game(*snaps), minor=3, resources=[(1, {'other.bin': b'1'})]), 'manifest', 'partition.hfs0')

    def patch_minor(self, data, minor):
        b = bytearray(data); struct.pack_into('<H', b, 6, minor); return nx_writer.reseal(bytes(b))

    def test_damaged_newer_generation_falls_back(self):   # an edit whose new tail is damaged: the older generation, still whole, is read (SPEC §1)
        good = bytearray(self.path.read_bytes())
        h = bytearray(good[:256]); struct.pack_into('<Q', h, 216, 1); h[120] ^= 1   # generation 1, its Catalog digest wrong
        struct.pack_into('<I', h, 252, nx_writer.crc32c(h[:252]))
        good[4096:4352] = h; self.path.write_bytes(good)
        n = self.open()
        self.assertEqual((n.generation, n.fell_back[0], n.fell_back[1].code), (0, 1, 'catalog_hash'))
        self.assertTrue(any('generation 1 is damaged' in s for s in n.notes))
        struct.pack_into('<H', h, 4, 9); struct.pack_into('<I', h, 252, nx_writer.crc32c(h[:252]))   # a newer generation of an unknown version: refused, no fall back
        good[4096:4352] = h
        self.refused(bytes(good), 'version')

    def test_native_snapshots_refused_with_a_clear_line(self):
        dnca = bytes(0x200) + b'DNCA' + bytes(60)
        self.write(game({'type': 0, 'version': 0, 'tree': {'0123456789abcdef0123456789abcdef.nca': dnca, 'aa.cnmt.nca': dnca}}))
        n = self.open()
        self.assertEqual(n.snapshots[0].kind, 'native')
        with self.assertRaises(pack_nx.Error) as e: pack_nx.scan(n)
        self.assertEqual(e.exception.code, 'native')
        self.assertIn('decrypted NCA', str(e.exception))
        self.assertIn('nxconvert pack-nup', str(e.exception))


class Read(Base):
    def test_scan(self):
        n = self.open()
        app, base, vers, dlc = pack_nx.scan(n)
        self.assertEqual((app, base.type, sorted(vers), sorted(dlc)), (TID, 0, [VER], [TID + 0x1001]))
        self.assertEqual((base.name, vers[VER].name, dlc[TID + 0x1001].name), ('game.nx (base)', f'game.nx (update {VER})', f'game.nx (DLC {TID + 0x1001:016X})'))

    def test_title_id_picks_the_game(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version()}) + game({'type': 0, 'version': 0, 'tree': version(tid=NEW)}, tid=NEW))
        n = self.open()
        with self.assertRaisesRegex(pack_nx.Error, '2 games.*--title-id'): pack_nx.scan(n)
        self.assertEqual(pack_nx.scan(n, NEW)[0], NEW)
        with self.assertRaisesRegex(pack_nx.Error, 'no game 0100'): pack_nx.scan(n, 0x0100000000001000)

    def test_switch_2(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version()}, platform=2))
        n = self.open(); pack_nx.scan(n)
        self.assertEqual(pack_nx.PLATFORMS[n.selected.platform], 'Switch 2')

    def test_program_id_mismatch_and_version_clash(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version()}, {'type': 1, 'version': VER, 'tree': version(tid=TID + 0x2000)}))
        with self.assertRaisesRegex(pack_nx.Error, 'other program IDs'): pack_nx.scan(self.open())
        self.write(game({'type': 1, 'version': VER, 'tree': version()}, {'type': 3, 'version': VER, 'tree': version(main=b'other')}))
        with self.assertRaisesRegex(pack_nx.Error, 'two snapshots of version'): pack_nx.scan(self.open())

    def test_dlc_versions_and_dlc_without_add_on_id(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version()},
                        {'type': 2, 'version': 0, 'addon': TID + 0x1001, 'tree': {'romfs': {'v': b'old'}}},
                        {'type': 2, 'version': 65536, 'addon': TID + 0x1001, 'tree': {'romfs': {'v': b'new'}}},
                        {'type': 2, 'version': 0, 'content_id': b'\x11' * 16, 'tree': {'x.nca': b'nca'}}))
        n = self.open(); _, _, _, dlc = pack_nx.scan(n)
        self.assertEqual(dlc[TID + 0x1001].version, 65536)
        self.assertTrue(any('no add-on title ID' in s for s in n.notes))
        self.assertTrue(any('packing the newer' in s for s in n.notes))

    def test_head(self):
        n = self.open(); base = n.snapshots[0]
        big = n.child(n.subdir(base.romfs, b'dir'), b'old')
        self.assertEqual(n.head(big), (b'data' * 100)[:32])
        self.assertEqual(n.head(big, 1000), b'data' * 100)
        self.assertEqual(n.head(n.child(base.romfs, b'empty')), b'')

    def test_folder_or_file(self):
        self.assertEqual(nsp.nx_file(self.dir), self.path)
        self.assertEqual(nsp.nx_file(self.path), self.path)
        caps = self.dir / 'GAME.NX'; self.path.rename(caps)
        self.assertEqual(nsp.nx_file(self.dir), caps)
        (self.dir / 'other.nup').write_bytes(b'NUP\x01' + bytes(200))
        with self.assertRaisesRegex(nsp.BuildError, 'more than one game container.*GAME.NX.*other.nup'): nsp.nx_file(self.dir)
        (self.dir / 'other.nup').unlink(); (self.dir / 'second.nx').write_bytes(b'x')
        with self.assertRaisesRegex(nsp.BuildError, 'more than one game container'): nsp.nx_file(self.dir)
        (self.dir / 'game.nsp').write_bytes(b'x')
        self.assertIsNone(nsp.nx_file(self.dir))   # the packages win, as over a NUP or a dump's layout


class Pack(Base):
    def out(self): return self.dir / 'out'

    def test_update_packed_on_its_own_with_control_data(self):
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        self.assertEqual(pack_nx.pack_version(n, vers[VER], base, app, self.out() / 'u', say=lambda s: None), 'packed')
        u = self.out() / 'u'
        self.assertEqual((u / 'ExeFS/main').read_bytes(), b'new code')
        self.assertFalse((u / 'ExeFS/.listing').exists())
        names = romfs_image.read_index(u / 'RomFS.img')
        self.assertIn('dir/new', names); self.assertNotIn('dir/old', names); self.assertEqual(names['empty'][2], 0)
        self.assertFalse((u / 'control.nacp').exists())   # the update has none, and the base's is not borrowed: the script reads the base's
        pack_nx.pack_version(n, base, base, app, self.out() / 'b', say=lambda s: None)
        b = self.out() / 'b'
        self.assertEqual((nacp.name(b / 'control.nacp'), nacp.version(b / 'control.nacp')), ('Test Game', '1.2.3'))
        self.assertEqual((b / 'icon.jpg').read_bytes(), b'\xff\xd8 icon')
        with open(self.out() / 'u/RomFS.img', 'rb') as f: img = f.read()
        self.assertIn(b'data' * 100, img)

    def test_update_metadata_from_the_history(self):   # each version's NACP is its own: the base's NACP goes to the history, the newer one is the application's
        newer = dict(META, nacp=control_nacp('Test Game', '2.0.0'), icon=b'new icon')
        self.write(game({'type': 0, 'version': 0, 'tree': version(), 'meta': META}, {'type': 1, 'version': VER, 'tree': version(main=b'new'), 'meta': newer}))
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        for k, out, disp, icon in ((base, 'b', '1.2.3', b'\xff\xd8 icon'), (vers[VER], 'u', '2.0.0', b'new icon')):
            pack_nx.pack_version(n, k, base, app, self.out() / out, say=lambda s: None)
            self.assertEqual(nacp.version(self.out() / out / 'control.nacp'), disp)
            self.assertEqual((self.out() / out / 'icon.jpg').read_bytes(), icon)

    def test_standalone_update_without_base_takes_the_application_metadata(self):
        self.write(game({'type': 3, 'version': VER, 'tree': version(), 'meta': META}, {'type': 3, 'version': VER + 1, 'tree': version(main=b'newest', marker='newest')}))
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        self.assertIsNone(base)
        app2, fam = nsp.scan_nx(self.path); self.addCleanup(fam['nx'].close)
        self.assertEqual(set(nsp.nsp_versions(fam)), {f'v{VER}', f'v{VER + 1}'})
        pack_nx.pack_version(n, vers[VER + 1], base, app, self.out(), say=lambda s: None)
        self.assertEqual((self.out() / 'ExeFS/main').read_bytes(), b'newest')
        self.assertIn('dir/newest', romfs_image.read_index(self.out() / 'RomFS.img'))
        self.assertEqual(nacp.name(self.out() / 'control.nacp'), 'Test Game')   # no base: the application's metadata snapshot's

    def test_icon_choice_and_png(self):
        png = b'\x89PNG\r\n\x1a\n' + bytes(20)
        self.write(game({'type': 0, 'version': 0, 'tree': version(), 'meta': {'title': 'T', 'icon_type': 1, 'localized': [('ja', 'J', b'\x89PNG ja'), ('en-us', 'E', png)]}}))
        n = self.open(); app, base, _, _ = pack_nx.scan(n)
        pack_nx.pack_version(n, base, base, app, self.out(), say=lambda s: None)
        self.assertEqual((self.out() / 'icon.jpg').read_bytes(), png)   # American English's, written as icon.jpg (sips reads a PNG by its content)
        self.assertFalse((self.out() / 'control.nacp').exists())

    def test_version_without_romfs_or_main(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version()}, {'type': 1, 'version': VER, 'tree': {'exefs': version()['exefs']}}))
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        with self.assertRaisesRegex(pack_nx.Error, 'no romfs/ in this snapshot'): pack_nx.pack_version(n, vers[VER], base, app, self.out())
        with self.assertRaisesRegex(nsp.BuildError, 'no romfs/'): nsp.extract_nup(self.out(), f'v{VER}', vers[VER], base, app, n, pack_nx)
        tree = version(); del tree['exefs']['main']
        self.write(game({'type': 0, 'version': 0, 'tree': tree}))
        n = self.open(); app, base, _, _ = pack_nx.scan(n)
        with self.assertRaisesRegex(pack_nx.Error, 'no exefs/main'): pack_nx.pack_version(n, base, base, app, self.out())
        self.assertFalse(self.out().exists())

    def test_repeat_keeps_what_is_unchanged_and_survives_a_recompressed_archive(self):
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        pack_nx.pack_version(n, vers[VER], base, app, self.out(), say=lambda s: None)
        main, img = self.out() / 'ExeFS/main', self.out() / 'RomFS.img'
        before = main.stat().st_ino, img.stat().st_mtime_ns
        self.assertEqual(pack_nx.pack_version(n, vers[VER], base, app, self.out(), say=lambda s: None), 'kept')
        n.close()
        self.write(game({'type': 0, 'version': 0, 'tree': version(marker='old'), 'meta': META},   # the same trees, stored raw and with another chunk size, at generation 3
                        {'type': 1, 'version': VER, 'tree': version(main=b'new code', marker='new'), 'display': '1.2.3'}), compress=False, chunk_log2=17, generation=3)
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        with mock.patch.object(romfs_image, 'write', side_effect=AssertionError('unpacked')), mock.patch.object(romfs_image, 'verify_image', side_effect=AssertionError('checked')):
            self.assertEqual(pack_nx.pack_version(n, vers[VER], base, app, self.out(), say=lambda s: None), 'kept')
        self.assertEqual((main.stat().st_ino, img.stat().st_mtime_ns), before)

    def test_image_verified_after_a_packer_change_and_repacked_after_a_tree_change(self):
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        img = self.out() / 'RomFS.img'
        pack_nx.pack(n, vers[VER].romfs, img, say=lambda s: None)
        stamp = Path(str(img) + '.inputs.json'); row = json.loads(stamp.read_text()); row['source'] = 'previous-packer'; stamp.write_text(json.dumps(row))
        with mock.patch.object(n, 'copy', side_effect=AssertionError('unpacked')):
            self.assertEqual(pack_nx.pack(n, vers[VER].romfs, img, say=lambda s: None), 'verified')
        self.assertEqual(pack_nx.pack(n, vers[VER].romfs, img, say=lambda s: None), 'kept')
        self.assertEqual(pack_nx.pack(n, base.romfs, img, say=lambda s: None), 'packed')   # another tree
        self.assertIn('dir/old', romfs_image.read_index(img))

    def test_dlc(self):
        n = self.open(); app, _, _, dlc = pack_nx.scan(n)
        aoc = self.out() / 'aoc'; aoc.mkdir(parents=True); (aoc / '7.img').write_bytes(b'gone')
        pack_nx.pack_dlc(n, app, dlc, aoc, say=lambda s: None)
        self.assertEqual(sorted(p.name for p in aoc.iterdir()), ['1.img', '1.img.inputs.json'])
        self.assertIn('dlcfile', romfs_image.read_index(aoc / '1.img'))
        fam = {'dlc': [(t, None, k) for t, k in dlc.items()], 'nx': n}
        with mock.patch.object(nsp, 'PROG', mock.Mock()):
            self.assertEqual(nsp.extract_aoc('nx', None, REPO, self.out(), app, fam, self.out() / 'logs'), self.out() / 'aoc')

    def test_survey_files(self):   # as survey_nup leaves a NUP's: ExeFS, romfs_manifest.tsv, the NROs whole, control data (the update's, else the base game's)
        nro = b'\0' * 16 + b'NRO0' + b'x' * 300
        self.write(game({'type': 0, 'version': 0, 'tree': version(tid=NEW), 'meta': META},
                        {'type': 1, 'version': VER, 'tree': {'exefs': version(main=b'new', tid=NEW)['exefs'], 'romfs': {'a/big': b'z' * 500, 'nro/m.nro': nro, 'empty': b''}}}, tid=NEW))
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        out = self.dir / 'survey'
        self.assertEqual(nsp.survey_nup(n, vers[VER], base, out, pack_nx), 3)
        self.assertEqual((out / 'ExeFS/main').read_bytes(), b'new')
        rows = (out / 'romfs_manifest.tsv').read_text().splitlines()
        self.assertEqual(sorted(rows[1:]), sorted([f'/a/big\t500\t{(b"z" * 32).hex()}', '/empty\t0\t', f'/nro/m.nro\t{len(nro)}\t{nro[:32].hex()}']))
        self.assertEqual((out / 'romfs_nro/nro/m.nro').read_bytes(), nro)
        self.assertEqual(nacp.name(out / 'control.nacp'), 'Test Game')


class Stop(Exception): pass


class StandaloneCLI(Base):
    def run_cli(self, *args):
        return subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), *args], capture_output=True, text=True)

    def test_default_and_explicit_versions(self):
        work = self.dir / 'cli'
        for args, ver, main in (([], VER, b'new code'), (['--version', '0'], 0, b'code')):
            r = self.run_cli('--work-dir', str(work), *args)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertEqual((work / f'extract/v{ver}/ExeFS/main').read_bytes(), main)
            self.assertIn('dlcfile', romfs_image.read_index(work / 'aoc/1.img'))
        r = self.run_cli('--work-dir', str(work), '--version', '5')
        self.assertEqual(r.returncode, 1); self.assertIn('no version 5', r.stderr); self.assertNotIn('Traceback', r.stderr)

    def test_list_and_verify(self):
        r = self.run_cli('--list')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn(f'{TID:016X} Switch 1: Test Game (Tester)', r.stdout)
        self.assertIn(f'add-on {TID + 0x1001:016X}', r.stdout)
        r = self.run_cli('--verify', '--crc')
        self.assertEqual(r.returncode, 0, r.stderr); self.assertIn('verified', r.stdout)
        data = bytearray(self.path.read_bytes()); data[-1] ^= 1; self.path.write_bytes(data)   # the integrity table's last byte
        r = self.run_cli('--list')
        self.assertEqual(r.returncode, 1); self.assertRegex(r.stderr, r'^\[RED\] game.nx: the block index or integrity table does not match its SHA-256')


class Main(Base):
    def run_main(self, target, *, extract=False, package=None):
        seen, said = {}, []
        def stop(env, *a):
            seen.update(env)
            if not extract: raise Stop()
        with mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
             mock.patch.object(nsp, 'check_prereqs', side_effect=stop), mock.patch.object(nsp, 'say', side_effect=said.append), \
             mock.patch.object(nsp, 'check_versions_aarch64', side_effect=Stop), mock.patch.object(nsp, 'find_nx_extract', side_effect=AssertionError('built nx_extract')), \
             mock.patch.object(nsp, 'ask', side_effect=AssertionError('asked for something')), mock.patch.object(nsp, 'package_reader', side_effect=AssertionError('read a package')):
            with self.assertRaises(Stop): nsp.main(nsp.parse_args([str(target)] + (['--package', package] if package else [])))
        return Path(seen['DM_ROOT']), said

    def test_needs_no_keys_and_builds_beside_the_nx(self):
        for target in (self.dir, self.path):
            work, said = self.run_main(target)
            self.assertEqual(work, self.dir / f'{TID:016X}_build')
            self.assertTrue(any(s.startswith(f'an NX: game.nx, {TID:016X}, Switch 1, NX 0.2, generation 0, 1 update(s), 1 DLC') for s in said), said)

    def test_reaches_extraction(self):   # the update packed from the archive, with its RomFS image and the base game's control data beside it
        self.path = self.path.rename(self.dir / 'Game.NX')
        for target in (self.dir, self.path):
            work, said = self.run_main(target, extract=True)
            v = work / f'extract/v{VER}'
            self.assertEqual((v / 'ExeFS/main').read_bytes(), b'new code')
            self.assertIn('dir/new', romfs_image.read_index(v / 'RomFS.img'))
            self.assertTrue(any(s == f'update v{VER}: Game.NX (update {VER})' for s in said), said)

    def test_standalone_update_reaches_extraction_without_a_base(self):
        self.write(game({'type': 3, 'version': VER, 'tree': version(), 'meta': META}))
        work, said = self.run_main(self.path, extract=True)
        self.assertEqual(nacp.name(work / f'extract/v{VER}/control.nacp'), 'Test Game')
        self.assertFalse(any(s.startswith('base:') for s in said))
        with self.assertRaisesRegex(nsp.BuildError, 'version to pack .* is not in the folder'): self.run_main(self.path, package='v0')

    def test_a_game_without_a_profile_is_surveyed(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version(tid=NEW), 'meta': META}, tid=NEW))
        seen = {}
        def survey(nsp_dir, app, fam, keys, repo, py, env):
            seen.update(app=app, nx=fam['nx'], base=fam['base']); raise Stop()
        with mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
             mock.patch.object(nsp, 'survey', side_effect=survey), mock.patch.object(nsp, 'check_capstone'), \
             mock.patch.object(nsp, 'say'), mock.patch.object(nsp, 'find_nx_extract', side_effect=AssertionError('built nx_extract')), \
             mock.patch.object(nsp, 'ask', side_effect=AssertionError('asked for something')), mock.patch.object(nsp, 'package_reader', side_effect=AssertionError('read a package')):
            with self.assertRaises(Stop): nsp.main(nsp.parse_args([str(self.path), '--survey-only']))
        self.assertEqual(seen['app'], NEW)
        self.assertEqual(seen['base'].type, pack_nx.BASE)

    def red(self, argv):
        with mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
             mock.patch.object(nsp, 'check_prereqs'), mock.patch.object(nsp, 'say'), mock.patch.object(nsp.PROG, 'say') as red:
            self.assertEqual(nsp.cli(argv), 1)
        return red.call_args.args[0]

    def test_errors_are_red_lines(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version()}, {'type': 1, 'version': VER, 'tree': {'exefs': version()['exefs']}}))
        self.assertRegex(self.red([str(self.path)]), r'^\[RED\] .*no romfs/')   # the newest version, read for the disk check before extraction
        self.write(game({'type': 0, 'version': 0, 'tree': {'0123.nca': b'nca'}}))
        self.assertRegex(self.red([str(self.dir)]), r'^\[RED\] game.nx holds decrypted NCA files')
        good = self.path.read_bytes()
        data = bytearray(good); struct.pack_into('<H', data, 6, 9); self.path.write_bytes(nx_writer.reseal(bytes(data)))
        self.assertRegex(self.red([str(self.path)]), r'^\[RED\] game.nx: NX format version 0.9 .*newer NX 18')
        self.path.write_bytes(good[:-1])
        self.assertRegex(self.red([str(self.path)]), r'^\[RED\] game.nx: .* bytes, its header says')
        (self.dir / 'b.nx').write_bytes(b'')
        self.assertRegex(self.red([str(self.dir)]), r'^\[RED\] more than one game container')


if __name__ == '__main__':
    unittest.main()
