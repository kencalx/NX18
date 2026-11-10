"""NX archives (scripts/pack_nx.py, https://github.com/fab918/nxformat, NXFormat 1.0.2): the reader against the format's own conformance fixtures (dm/tools/tests/fixtures/nx, each accepted or
refused with the error code upstream's index names), hostile archives made here (cut short, counts past the limits, unsafe names, zstd frames that break the rules or expand past their block),
the packing of versions, DLC and control data, and the NSP script's NX path up to extraction. The archives besides the fixtures are written by nx_writer.py, test code with its own record
layouts. No network, game files, keys or Xcode needed."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
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
import dnca_writer
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

    def test_native_snapshots_checked_before_anything_runs(self):   # an NCA snapshot's root and kind, before nx_extract is needed (none is set up here)
        dnca = bytes(0x200) + b'DNCA' + bytes(0xA00)
        self.write(game({'type': 0, 'version': 0, 'tree': {'0123456789abcdef0123456789abcdef.nca': dnca, 'aa.cnmt.nca': dnca}}))
        n = self.open()
        self.assertEqual(n.snapshots[0].kind, 'native')
        with self.assertRaises(pack_nx.Error) as e: pack_nx.scan(n)
        self.assertEqual(e.exception.code, 'nca')
        self.assertIn("'aa.cnmt.nca' is not a decrypted NCA's file name", str(e.exception))
        self.write(game({'type': 0, 'version': 0, 'tree': {'0123456789abcdef0123456789abcdef.nca': dnca}}, platform=2))
        with self.assertRaises(pack_nx.Error) as e: pack_nx.scan(self.open())
        self.assertEqual(e.exception.code, 'native')
        self.assertIn('NCA snapshots of a Switch 2 game are not supported', str(e.exception)); self.assertIn('nxconvert pack-tree', str(e.exception))


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
                        {'type': 2, 'version': 0, 'content_id': b'\x11' * 16, 'tree': {'romfs': {'v': b'x'}}}))
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
        self.assertEqual(nacp.name(u / 'control.nacp'), 'Test Game')   # the update has none: its exact base game's, as the console inherits an unchanged Control
        self.assertEqual((u / 'icon.jpg').read_bytes(), b'\xff\xd8 icon')
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

    def test_standalone_update_without_base_never_takes_another_updates_metadata(self):   # SPEC §4: native metadata is never attributed to another snapshot
        for older, newer in ((3, 3), (1, 1)):
            with self.subTest(types=(older, newer)):
                self.write(game({'type': older, 'version': VER, 'tree': version(), 'meta': META}, {'type': newer, 'version': VER + 1, 'tree': version(main=b'newest', marker='newest')}))
                n = self.open(); app, base, vers, _ = pack_nx.scan(n)
                self.assertIsNone(base)
                app2, fam = nsp.scan_nx(self.path); self.addCleanup(fam['nx'].close)
                self.assertEqual(set(nsp.nsp_versions(fam)), {f'v{VER}', f'v{VER + 1}'})
                said = []
                pack_nx.pack_version(n, vers[VER + 1], base, app, self.out() / 'new', say=said.append)
                self.assertEqual((self.out() / 'new/ExeFS/main').read_bytes(), b'newest')
                self.assertIn('dir/newest', romfs_image.read_index(self.out() / 'new/RomFS.img'))
                self.assertFalse((self.out() / 'new/control.nacp').exists())   # no NACP of its own and no base: none, not the older update's
                self.assertFalse((self.out() / 'new/icon.jpg').exists())
                self.assertTrue(any('no NACP for this version or its base game' in s for s in said), said)
                pack_nx.pack_version(n, vers[VER], base, app, self.out() / 'old', say=lambda s: None)
                self.assertEqual(nacp.name(self.out() / 'old/control.nacp'), 'Test Game')   # its own
                self.write(game({'type': older, 'version': VER, 'tree': version()}, {'type': newer, 'version': VER + 1, 'tree': version(main=b'newest'), 'meta': META}))
                n = self.open(); app, base, vers, _ = pack_nx.scan(n)
                pack_nx.pack_version(n, vers[VER], base, app, self.out() / 'old2', say=lambda s: None)
                self.assertFalse((self.out() / 'old2/control.nacp').exists())   # the older one never shows the newer update's NACP (display version) either

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


class Review(Base):
    """The review of the NX reader (scratchpad nxfmt/review-*): each case an archive the reader once took or mishandled"""
    def cat(self, data):   # (Catalog offset, its header fields by name)
        off, _ = nx_writer.catalog_span(data)
        nexts, = struct.unpack_from('<I', data, off + 40)
        app_off, ext_off, pool_off, pool_size = (struct.unpack_from('<Q', data, off + at)[0] for at in (48, 88, 96, 104))
        return off, {'nexts': nexts, 'app_off': app_off, 'ext_off': ext_off, 'pool_off': pool_off, 'pool_size': pool_size}

    def test_verify_checks_every_blocks_crc(self):   # SPEC §12 level 4: an integrity table that disagrees with the data fails verification, with or without --crc
        data = bytearray(self.one_file(b'bytes whose file SHA-256 stays right ' * 30, compress=False))
        integ = struct.unpack_from('<Q', data, 104)[0]
        data[integ] ^= 1
        self.path.write_bytes(nx_writer.reseal(bytes(data)))
        n = self.open()
        self.assertEqual(n.read(0)[:5], b'bytes')   # packing reads files by their SHA-256 (CRC-32C only with --crc)
        for kw in ({}, {'crc': False}, {'crc': True}):
            with self.subTest(kw=kw), self.assertRaises(pack_nx.Error) as e: n.verify(**kw)
            self.assertEqual(e.exception.code, 'block_hash')
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--verify'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout); self.assertIn('CRC-32C', r.stderr); self.assertNotIn('verified', r.stdout)

    def test_extensions_sorted_and_their_padding_zero(self):
        snaps = ({'type': 0, 'version': 0, 'tree': version(), 'display': '1.0'},)   # a 3-byte string pool: 5 bytes of padding before the first payload
        exts = [(0x7F000001, 0, 1, 0, b'first'), (0x7F000002, 0, 1, 0, b'secnd')]
        good = self.write(game(*snaps), extensions=exts)
        self.open()
        off, c = self.cat(good)
        self.assertEqual((c['nexts'], c['pool_size']), (2, 3))
        rec = off + c['ext_off']
        for what, a, b, code in (('unsorted', 0x7F000002, 0x7F000001, 'catalog'), ('twice', 0x7F000001, 0x7F000001, 'catalog')):
            with self.subTest(what=what):
                d = bytearray(good); struct.pack_into('<I', d, rec, a); struct.pack_into('<I', d, rec + 32, b)
                self.refused(nx_writer.reseal(bytes(d)), code, 'not sorted')
        pad = off + c['pool_off'] + c['pool_size']
        d = bytearray(good); self.assertEqual(d[pad:pad + 5], bytes(5)); d[pad:pad + 5] = b'\xaa' * 5
        self.refused(nx_writer.reseal(bytes(d)), 'padding', 'extension')

    def test_opaque_media_range_bounded_before_it_is_walked(self):
        good = self.write(game({'type': 0, 'version': 0, 'tree': version(), 'meta': META}))
        off, c = self.cat(good)
        for first, count in ((0, 0xFFFFFFFF), (0, 0xBCBCE95A), (0xFFFF, 1)):
            with self.subTest(count=count):
                d = bytearray(good); struct.pack_into('<II', d, off + c['app_off'] + 60, first, count)
                t = time.monotonic()
                self.refused(nx_writer.reseal(bytes(d)), 'catalog', 'opaque media range')
                self.assertLess(time.monotonic() - t, 2)
        d = bytearray(good); struct.pack_into('<II', d, off + c['app_off'] + 60, 0, 5)   # within the limit: refused by the Media check, as before
        self.refused(nx_writer.reseal(bytes(d)), 'catalog', 'media reference')

    def test_main_npdm_read_only_at_the_size_of_one(self):
        tree = version(); tree['exefs']['main.npdm'] = npdm(TID) + bytes(2 << 20)   # 2 MiB of deduplicated zeros after a valid NPDM
        self.write(game({'type': 0, 'version': 0, 'tree': tree}))
        n = self.open()
        with mock.patch.object(n, 'copy', side_effect=AssertionError('read whole')), self.assertRaises(pack_nx.Error) as e: pack_nx.scan(n)
        self.assertEqual(e.exception.code, 'resource'); self.assertIn('exefs/main.npdm', str(e.exception))

    def test_short_or_cut_npdm_is_an_error(self):
        cut = bytearray(npdm(TID)); struct.pack_into('<I', cut, 0x70, 0xF8); cut[0xF8:0xFC] = b'ACI0'
        for what, data, msg in (('8 bytes', b'META1234', 'not an NPDM'), ('ACI0 at its end', bytes(cut), 'no ACI0')):
            with self.subTest(what=what):
                tree = version(); tree['exefs']['main.npdm'] = data
                self.write(game({'type': 0, 'version': 0, 'tree': tree}))
                with self.assertRaisesRegex(pack_nx.Error, msg): pack_nx.scan(self.open())
                with self.assertRaisesRegex(nsp.BuildError, msg): nsp.scan_nx(self.path)
                r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--work-dir', str(self.dir / 'w')], capture_output=True, text=True)
                self.assertEqual(r.returncode, 1); self.assertIn('[RED]', r.stderr); self.assertNotIn('Traceback', r.stderr)

    def test_a_file_cut_while_open_is_an_io_error(self):   # read with pread: no SIGBUS
        n = self.open()
        i = n.child(n.snapshots[0].exefs, b'main')
        os.truncate(self.path, 8192)
        with self.assertRaises(pack_nx.Error) as e: n.read(i)
        self.assertEqual(e.exception.code, 'io'); self.assertIn('before the', str(e.exception))

    def test_control_characters_escaped_when_printed(self):
        title = 'Game\x1b]0;TERMINAL TITLE SET BY ARCHIVE\x07\x1b[2K\rfake line\u202e'
        self.write(game({'type': 0, 'version': 0, 'tree': version(), 'meta': dict(META, title=title)}))
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--list'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('Game\\x1b]0;TERMINAL', r.stdout)
        self.assertFalse(any(c in r.stdout for c in '\x1b\x07\r\u202e'))
        self.assertEqual(pack_nx.shown('a\tb\x9b\u2066'), 'a\\x09b\\x9b\\u2066')

    def test_host_names_of_exefs_modules(self):
        nfc, nfd = 'sdké', 'sdké'
        for what, files, msg in (('NFC and NFD', {nfc: b'NFC-CONTENT', nfd: b'NFD-CONTENT'}, 'normalization'), ('case', {'main2': b'1', 'MAIN2': b'2'}, 'differ only in case'),
                                 ('300 bytes', {'L' * 300: b'x'}, 'longer than a host file name'), ('control character', {'sdk\n': b'x'}, 'control characters')):
            with self.subTest(what=what):
                tree = version(); tree['exefs'].update(files)
                self.write(game({'type': 0, 'version': 0, 'tree': tree}))
                n = self.open()
                with self.assertRaises(pack_nx.Error) as e: pack_nx.exefs(n, n.snapshots[0], self.dir / 'out/ExeFS')
                self.assertEqual(e.exception.code, 'path'); self.assertRegex(str(e.exception), msg)
                with self.assertRaisesRegex(nsp.BuildError, msg): nsp.code_modules({'nx': n}, n.snapshots[0], self.dir / 'out/ExeFS')
                self.assertFalse((self.dir / 'out').exists())

    def test_code_module_and_nro_size_capped_and_space_checked(self):
        tree = version(); tree['exefs']['subsdk9'] = bytes(5000)
        tree['romfs']['m.nro'] = b'\0' * 16 + b'NRO0' + bytes(5000)
        self.write(game({'type': 0, 'version': 0, 'tree': tree}))
        n = self.open(); k = n.snapshots[0]
        with mock.patch.object(pack_nx, 'MODULE_MAX', 4096):
            with self.assertRaises(pack_nx.Error) as e: pack_nx.exefs(n, k, self.dir / 'out/ExeFS')
            self.assertEqual(e.exception.code, 'resource'); self.assertIn('subsdk9', str(e.exception))
            with self.assertRaisesRegex(nsp.BuildError, 'larger than any NRO'): nsp.survey_nup(n, k, k, self.dir / 's1', pack_nx)
        with mock.patch.object(nsp, 'free_gb', return_value=0.5):
            with self.assertRaisesRegex(nsp.BuildError, 'GB free'): nsp.survey_nup(n, k, k, self.dir / 's2', pack_nx)
        self.assertFalse((self.dir / 's2/ExeFS').exists())
        self.assertEqual(nsp.exefs_size(n, k), sum(len(v) for v in tree['exefs'].values()))
        with mock.patch.object(sys, 'argv', ['pack_nx.py', str(self.path), '--work-dir', str(self.dir / 'w')]), mock.patch.object(pack_nx, 'free_bytes', return_value=1 << 29), \
             self.assertRaises(SystemExit) as e: pack_nx.main()
        self.assertRegex(str(e.exception.code), r'^\[RED\] .* GB to write and 0.5 GB free')
        self.assertFalse((self.dir / 'w/extract').exists())

    def survey(self, romfs):
        self.write(game({'type': 0, 'version': 0, 'tree': {'exefs': version()['exefs'], 'romfs': romfs}}))
        n = self.open(); out = self.dir / 'survey'
        import shutil; shutil.rmtree(out, ignore_errors=True)
        return nsp.survey_nup(n, n.snapshots[0], n.snapshots[0], out, pack_nx)

    def test_survey_refuses_names_it_cannot_list_or_write_apart(self):
        nro = b'\0' * 16 + b'NRO0' + b'x' * 64
        for what, romfs, msg in (('forged row', {'x\t1\t00\nfake/Engine/UE4Game.pak': b'1'}, 'control characters'), ('tab', {'a\tb': b'1'}, 'control characters'),
                                 ('case', {'mod.nro': nro, 'MOD.nro': nro + b'2'}, 'differ only in case'), ('NFC and NFD', {'é.nro': nro, 'é.nro': nro + b'2'}, 'normalization'),
                                 ('file and folder', {'d.nro': nro, 'D.NRO/e.nro': nro}, 'differ only in case'), ('long name', {'n' * 300 + '.nro': nro}, 'longer than a host file name')):
            with self.subTest(what=what), self.assertRaisesRegex(nsp.BuildError, msg): self.survey(romfs)
        self.assertEqual(self.survey({'Mod.nro': nro, 'sub/mod.nro': nro, 'a b.txt': b'1'}), 3)   # one name per folder is fine
        self.assertEqual((self.dir / 'survey/romfs_nro/sub/mod.nro').read_bytes(), nro)

    def test_empty_base_is_no_base(self):   # as a NUP's empty base record (test_nsp_nup.py); its metadata still serves the update
        for tree in ({'exefs': {}}, {}, {'exefs': {}, 'romfs': {}}, {'exefs': {'.listing': b'not a file of the game'}}):
            with self.subTest(tree=tree):
                self.write(game({'type': 0, 'version': 0, 'tree': tree, 'meta': META}, {'type': 1, 'version': VER, 'tree': version()}))
                n = self.open()
                app, base, vers, _ = pack_nx.scan(n)
                self.assertIsNone(base); self.assertEqual(app, TID)
                self.assertTrue(any('no base game' in s for s in n.notes), n.notes)
                self.assertEqual(set(nsp.nsp_versions({'base': base, 'updates': sorted(vers.items())})), {f'v{VER}'})
                pack_nx.pack_version(n, vers[VER], base, app, self.dir / 'out', say=lambda s: None)
                self.assertIn('dir/marker', romfs_image.read_index(self.dir / 'out/RomFS.img'))
                self.assertEqual(nacp.name(self.dir / 'out/control.nacp'), 'Test Game')   # the exact base's metadata
        for tree in ({'romfs': {'shared': b'data'}}, {'exefs': version()['exefs']}):   # a base with game files stays a base
            with self.subTest(tree=tree):
                self.write(game({'type': 0, 'version': 0, 'tree': tree}, {'type': 1, 'version': VER, 'tree': version()}))
                self.assertIsNotNone(pack_nx.scan(self.open())[1])
        self.write(game({'type': 0, 'version': 0, 'tree': {'exefs': {}}, 'meta': META}))
        with self.assertRaisesRegex(pack_nx.Error, 'holds the game\'s files'): pack_nx.scan(self.open())

    def test_one_title_id_on_two_platforms(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version(), 'meta': META}, platform=1) + game({'type': 0, 'version': 0, 'tree': version(main=b'two'), 'meta': META}, platform=2))
        n = self.open()
        for want in (None, TID):
            with self.subTest(want=want), self.assertRaises(pack_nx.Error) as e: pack_nx.scan(n, want)
            self.assertIn(f'{TID:016X}:switch1 (Switch 1, Test Game), {TID:016X}:switch2 (Switch 2', str(e.exception))
            self.assertIn('platform after the ID', str(e.exception))
        for plat in (1, 2):
            self.assertEqual((pack_nx.scan(n, TID, plat)[0], n.selected.platform, pack_nx.platform_tag(n, n.selected)), (TID, plat, pack_nx.SELECTORS[plat]))
        with self.assertRaisesRegex(pack_nx.Error, f'no game {TID:016X}:unknown'): pack_nx.scan(n, TID, 0)
        self.assertEqual(pack_nx.parse_title_id(f'{TID:016x}:Switch2'), (TID, 2))
        self.assertEqual(pack_nx.parse_title_id(f'{TID:016X}'), (TID, None))
        self.assertEqual(pack_nx.parse_title_id(f'{TID:016X}:1'), (TID, 1))
        self.assertIsNone(pack_nx.parse_title_id(f'{TID:016X}:switch3'))
        with fixture('same_application_id_cross_platform.nx') as f:
            with self.assertRaisesRegex(pack_nx.Error, ':switch2') as e: pack_nx.scan(f, 0x0100000000000001)
            try: pack_nx.scan(f, 0x0100000000000001, 2)
            except pack_nx.Error as e2: self.assertNotIn('holds 2 games', str(e2))   # picked; what it holds may still not be a game's
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--title-id', f'{TID:016X}:switch2'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual((self.dir / f'{TID:016X}-switch2_build/extract/v0/ExeFS/main').read_bytes(), b'two')

    def test_notes_printed_once(self):
        good = bytearray(self.path.read_bytes())
        h = bytearray(good[:256]); struct.pack_into('<Q', h, 216, 1); h[120] ^= 1   # generation 1, its Catalog digest wrong
        struct.pack_into('<I', h, 252, nx_writer.crc32c(h[:252])); good[4096:4352] = h; self.path.write_bytes(good)
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--work-dir', str(self.dir / 'w')], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.count('generation 1 is damaged'), 1, r.stdout)


KINDS = {dnca_writer.APPLICATION: 'Application', dnca_writer.PATCH: 'Patch', dnca_writer.ADDON: 'AddOnContent'}


class FakeTool:
    """nx_extract as pack_nx runs it, without the executable (pack_nx._run replaced): --contents reads the staged meta NCAs' content metas (dnca_writer.cnmt_of); an extraction lists
    the staged folder and writes the layout. code/text: an extraction's exit code and output; title, build: its title and main build ID lines (default: the program asked for and
    build); control: whether it writes control.nacp and icon.jpg; fail: an exception it raises once it has listed the staged files"""
    def __init__(self, build=b'', code=0, text='', title=None, control=True, fail=None):
        self.build, self.code, self.text, self.title, self.control, self.fail = build, code, text, title, control, fail
        self.calls, self.staged, self.envs = [], [], []

    def __call__(self, n, args, log=None, timeout=None):
        args = [str(a) for a in args]; self.calls.append(args)
        if args[1] == '--contents':
            out = []
            for j, d in enumerate(args[2:]):
                out.append(f'package {j} {Path(d).name}')
                for f in sorted(Path(d).iterdir()):
                    kind, tid, ver = dnca_writer.cnmt_of(f.read_bytes()); out.append(f'content {KINDS[kind]} {tid:016x} {ver}')
            return 0, '\n'.join(out) + '\n'
        src = Path(args[2] if args[1] == '--aoc' else args[1])
        self.staged.append(sorted(p.name for p in src.iterdir()))
        if self.fail: raise self.fail
        if args[1] == '--aoc':
            img = Path(args[3]); img.parent.mkdir(parents=True, exist_ok=True); img.write_bytes(b'dlc image')
            return 0, f'add-on content {args[4]}\n'
        out = Path(args[3])
        if '--html' in args:
            (out / 'html0').mkdir(parents=True); (out / 'html0/index.html').write_bytes(b'page')
            return 0, '1 HtmlDocument NCAs\n'
        if self.code: return self.code, self.text
        (out / 'ExeFS').mkdir(parents=True)
        (out / 'ExeFS/main').write_bytes(b'NSO0 main'); (out / 'ExeFS/main.npdm').write_bytes(npdm(TID))
        (out / 'RomFS.img').write_bytes(b'image')
        if self.control: (out / 'control.nacp').write_bytes(control_nacp('From Control', '1.2.0')); (out / 'icon.jpg').write_bytes(b'control icon')
        pid = args[args.index('--app') + 2].split('=')[1]
        title = self.title or f'title {pid}' + (f', update {pid}' if args[2] != '-' else '')
        return 0, f'{title}\nmain build id {self.build[:16].hex()}\n{self.text}'


class NativeBase(Base):
    def setUp(self):
        super().setUp()
        self.g = dnca_writer.Game(TID)
        self.write_game()

    def write_game(self, g=None, meta=META, **kw):
        g = g or self.g
        return self.write([{'id': TID, 'platform': 1, 'snapshots': g.snapshots(meta)}], **kw)

    def opened(self, fake=None, **kw):   # the archive, scanned with nx_extract replaced by fake
        n = self.open()
        n.nca_tool = pack_nx.Native(tool=lambda: Path('/nonexistent/nx_extract'), **kw)
        if fake is not None:
            p = mock.patch.object(pack_nx, '_run', side_effect=fake); p.start(); self.addCleanup(p.stop)
        return n, pack_nx.scan(n)

    def work(self):
        return self.dir / 'work'


class Native(NativeBase):
    """pack_nx's NCA snapshots with nx_extract replaced by a fake: what is checked before anything runs, what is staged, the exit codes, cross-checks, stamps and clean-up"""
    def pack(self, n, k, base=None):
        out = self.work() / 'extract' / f'v{k.version}'
        return pack_nx.pack_version(n, k, base, TID, out, say=lambda s: None), out

    def test_listing_and_scan(self):
        fake = FakeTool()
        n, (app, base, vers, dlc) = self.opened(fake)
        self.assertTrue(all(' native ' in line for line in pack_nx.listing(n)[2:]))
        self.assertEqual((app, base.version, list(vers), list(dlc)), (TID, 0, [VER], [TID + 0x1001]))
        self.assertEqual([c[1] for c in fake.calls], ['--contents'])   # one run reads every snapshot's content meta
        self.assertEqual(len(fake.calls[0]) - 2, 3)

    def test_root_checks_before_staging(self):
        for extra, why in (({'A' * 32 + '.nca': b'x' * 0xC00}, "is not a decrypted NCA's file name"), ({'ticket.tik': b'x'}, "'ticket.tik' is not"),
                           ({'sub': {'f': b'x'}}, "'sub' is not"), ({'0' * 32 + '.nca': b'x' * 100}, 'shorter than an NCA header')):
            with self.subTest(extra=list(extra)):
                g = dnca_writer.Game(TID, dlc=False); g.base = dict(g.base, **extra)
                self.write_game(g)
                fake = FakeTool()
                with self.assertRaises(pack_nx.Error) as e: self.opened(fake)
                self.assertEqual(e.exception.code, 'nca'); self.assertIn(why, str(e.exception))
                self.assertEqual(fake.calls, [])

    def test_header_checked_before_staging(self):
        prog = bytearray(self.g.base_prog.data); prog[0x200:0x204] = b'NCA3'
        self.g.base = {k: (bytes(prog) if v == self.g.base_prog.data else v) for k, v in self.g.base.items()}
        self.g.update = dict(self.g.update, **self.g.base)
        self.write_game()
        fake = FakeTool(build=self.g.bid1)
        n, (_, base, vers, _) = self.opened(fake)
        with self.assertRaises(pack_nx.Error) as e: self.pack(n, vers[VER])
        self.assertEqual(e.exception.code, 'nca')
        self.assertIn(f'{dnca_writer.content_id(self.g.base_prog.data).hex()}.nca: a plaintext NCA without the DNCA marker', str(e.exception))
        self.assertEqual(len(fake.calls), 1)   # the scan's only
        self.assertFalse((self.work() / 'tmp/nca').exists() and any((self.work() / 'tmp/nca').iterdir()))

    def test_damaged_block_found_while_staging(self):
        self.write_game(compress=False)
        n = self.open()
        cid = dnca_writer.content_id(self.g.upd_prog.data).hex() + '.nca'
        i = n.child(n.snapshots[1].root, cid.encode())
        _, first, count, _, _ = n.files[i]
        at, stored, _, _, _ = next(b for k in range(1, count) if (b := n._block(n.refs[first + k]))[3] == 0)   # a block after the header's, stored raw
        n.close()
        data = bytearray(self.path.read_bytes()); data[at + stored // 2] ^= 0xFF; self.path.write_bytes(data)
        fake = FakeTool(build=self.g.bid1)
        n, (_, base, vers, _) = self.opened(fake)
        with self.assertRaises(pack_nx.Error) as e: self.pack(n, vers[VER])
        self.assertEqual(e.exception.code, 'block_hash'); self.assertIn(cid, str(e.exception))
        self.assertEqual(len(fake.calls), 1)
        self.assertFalse((self.work() / 'tmp/nca/v458752').exists())

    def test_what_is_staged(self):
        data = dnca_writer.data_nca(TID, {'x': b'data'}, content_type=dnca_writer.DATA, seed=71)
        g = dnca_writer.Game(TID, manual=True)
        own = {k: v for k, v in g.update.items() if k not in g.base}
        g.base, g.base_id = dnca_writer.snapshot(dnca_writer.APPLICATION, TID, 0, [g.base_prog, dnca_writer.control_nca(TID), data,
                                                                                   dnca_writer.manual_nca(TID, g.html0)], other=TID | 0x800, seed=12)
        g.update = dict(own, **g.base)
        self.write_game(g)
        fake = FakeTool(build=g.bid1)
        n, (_, base, vers, dlc) = self.opened(fake)
        self.pack(n, vers[VER])
        types = {name: b[0x205] for name, b in g.update.items()}
        self.assertEqual(sorted(types[x] for x in fake.staged[0]), [0, 0, 1, 1, 2, 2, 3, 3])   # no Data NCA; the update's and the base's Meta, Program, Control, Manual
        self.assertEqual(sorted(types[x] for x in fake.staged[1]), [0, 0, 1, 1, 2, 2, 3, 3])   # the HTML pages, from the same folder
        self.assertNotIn(dnca_writer.content_id(data.data).hex() + '.nca', fake.staged[0])
        pack_nx.pack_dlc(n, TID, dlc, self.work() / 'aoc', say=lambda s: None)
        self.assertEqual(sorted(g.dlc), fake.staged[2])   # the DLC: its Meta and data NCAs
        self.assertEqual((self.work() / 'aoc/1.img').read_bytes(), b'dlc image')
        self.assertTrue((self.work() / 'aoc/1.img.inputs.json').is_file())

    def test_disk_checked_before_staging(self):
        fake = FakeTool(build=self.g.bid1)
        n, (_, base, vers, _) = self.opened(fake)
        need = pack_nx.staging_bytes(n, vers[VER]) + pack_nx.version_bytes(n, vers[VER])
        self.assertEqual(pack_nx.staging_bytes(n, vers[VER]), sum(len(b) for b in self.g.update.values()))
        with mock.patch.object(pack_nx, 'free_bytes', return_value=need + (1 << 30) - 1), self.assertRaises(pack_nx.Error) as e: self.pack(n, vers[VER])
        self.assertEqual(e.exception.code, 'io'); self.assertIn('to stage and write', str(e.exception))
        self.assertEqual(len(fake.calls), 1)

    def test_exit_codes(self):
        red = '[RED] x\x1b[2Jy: why\n'
        for code, want, msg in ((2, 'tool', 'nx_extract refused its arguments: x\\\\x1b\\[2Jy'), (3, 'nca_hash', 'fail the NCA\'s own hash check'),
                                (4, 'sparse', 'runs only with its update'), (5, 'nca', 'its content meta cannot be read'), (6, 'nca', 'still asks for keys'),
                                (7, 'nca', r'\(update 458752\): x\\x1b\[2Jy: why'), (8, 'nca', r'x\\x1b\[2Jy'), (-9, 'tool', 'exit code -9')):
            with self.subTest(code=code):
                fake = FakeTool(code=code, text=red + ('[RED] hash check failed: /a.bin\n' if code == 3 else ''))
                n, (_, base, vers, _) = self.opened(fake)
                with self.assertRaises(pack_nx.Error) as e: self.pack(n, vers[VER])
                self.assertEqual(e.exception.code, want, str(e.exception)); self.assertRegex(str(e.exception), msg)
                self.assertNotIn('\x1b', str(e.exception))
                self.assertFalse((self.work() / 'extract/v458752.partial').exists())
        self.assertIn('1 file(s) fail', str(self.exit3()))

    def exit3(self):
        fake = FakeTool(code=3, text='[RED] hash check failed: /a.bin\n')
        n, (_, base, vers, _) = self.opened(fake)
        try: self.pack(n, vers[VER])
        except pack_nx.Error as e: return e

    def test_cross_checks(self):
        for fake, why in ((FakeTool(build=self.g.bid0), 'the archive says main is build 8182838485868788'),
                          (FakeTool(build=self.g.bid1, title=f'title {TID + 1:016x}, update {TID + 1:016x}'), f'the archive says program {TID:016X}'),
                          (FakeTool(build=self.g.bid1, title=f'title {TID:016x}'), 'nx_extract read title')):
            with self.subTest(why):
                n, (_, base, vers, _) = self.opened(fake)
                with self.assertRaises(pack_nx.Error) as e: self.pack(n, vers[VER])
                self.assertEqual(e.exception.code, 'nca'); self.assertIn(why, str(e.exception))

    def test_control_data_from_the_archive_when_the_tool_gives_none(self):
        fake = FakeTool(build=self.g.bid1, control=False)
        n, (_, base, vers, _) = self.opened(fake)
        _, out = self.pack(n, vers[VER])   # the update has no Media record: its exact base's
        self.assertEqual(((out / 'control.nacp').read_bytes(), (out / 'icon.jpg').read_bytes()), (META['nacp'], META['icon']))
        fake2 = FakeTool(build=self.g.bid1)
        n, (_, base, vers, _) = self.opened(fake2)
        shutil.rmtree(out)
        _, out = self.pack(n, vers[VER])   # what the Control NCA gives comes first
        self.assertEqual(nacp.name(out / 'control.nacp'), 'From Control')

    def test_stamp_keeps_the_output(self):
        fake = FakeTool(build=self.g.bid1)
        n, (_, base, vers, _) = self.opened(fake)
        self.assertEqual(self.pack(n, vers[VER])[0], 'packed')
        out = self.work() / 'extract/v458752'
        self.assertEqual(sorted(p.name for p in out.iterdir()), ['ExeFS', 'RomFS.img', 'control.nacp', 'html', 'icon.jpg', 'native.inputs.json'])
        calls = len(fake.calls)
        self.assertEqual(self.pack(n, vers[VER])[0], 'kept'); self.assertEqual(len(fake.calls), calls)   # nothing staged, the tool not started
        (out / 'ExeFS/main').write_bytes(b'changed')
        self.assertEqual(self.pack(n, vers[VER])[0], 'packed')
        self.assertEqual(self.pack(n, vers[VER])[0], 'kept')
        with mock.patch.object(pack_nx, 'nx_extract_source_sha', return_value='0' * 16): self.assertEqual(self.pack(n, vers[VER])[0], 'packed')
        n.nca_tool.allow_damaged = True
        self.assertEqual(self.pack(n, vers[VER])[0], 'packed')
        n.nca_tool.allow_damaged = False
        self.assertEqual(self.pack(n, vers[VER])[0], 'packed')
        n.close()
        self.write_game(generation=1)   # an edit that appended a generation with the same files: kept
        n, (_, base, vers, _) = self.opened(fake)
        self.assertEqual(self.pack(n, vers[VER])[0], 'kept')
        g = dnca_writer.Game(TID); g.update = dict(g.update, **{'f' * 32 + '.nca': g.base_prog.data})   # another file in the snapshot
        self.write_game(g)
        n, (_, base, vers, _) = self.opened(FakeTool(build=self.g.bid1))
        self.assertEqual(self.pack(n, vers[VER])[0], 'packed')

    def test_clean_up(self):
        for fake in (FakeTool(build=self.g.bid1), FakeTool(code=7, text='[RED] no\n'), FakeTool(fail=KeyboardInterrupt())):
            with self.subTest(code=fake.code, fail=fake.fail):
                n, (_, base, vers, _) = self.opened(fake)
                try: self.pack(n, vers[VER])
                except (pack_nx.Error, KeyboardInterrupt): pass
                self.assertEqual(list((self.work() / 'tmp/nca').iterdir()), [])
                self.assertFalse((self.work() / 'extract/v458752.partial').exists())

    def test_tool_missing_or_not_built_from_the_sources(self):
        with self.assertRaises(pack_nx.Error) as e: pack_nx.find_tool(self.dir)
        self.assertEqual(e.exception.code, 'tool'); self.assertIn('does not start', str(e.exception)); self.assertIn('native_tools.sh nx_extract', str(e.exception))
        exe = self.dir / pack_nx.NX_EXTRACT; exe.parent.mkdir(parents=True)
        exe.write_text('#!/bin/sh\necho 0123456789abcdef\n'); exe.chmod(0o755)
        for f in ('Program.cs', 'nx_extract.csproj'): (self.dir / 'dm/tools/nx_extract').mkdir(parents=True, exist_ok=True); (self.dir / 'dm/tools/nx_extract' / f).write_text(f)
        with self.assertRaises(pack_nx.Error) as e: pack_nx.find_tool(self.dir)
        self.assertEqual(e.exception.code, 'tool'); self.assertIn('was built from source 0123456789abcdef', str(e.exception))
        n = self.open()   # no tool set up: refused once the snapshots' files pass their checks
        with self.assertRaises(pack_nx.Error) as e: pack_nx.scan(n)
        self.assertEqual(e.exception.code, 'tool')

    def test_scan_refusals(self):
        self.write([{'id': TID, 'platform': 1, 'snapshots': [{'type': 3, 'version': VER, 'tree': self.g.update, 'content_id': self.g.update_id}]}])
        with self.assertRaises(pack_nx.Error) as e: self.opened(FakeTool())
        self.assertEqual(e.exception.code, 'native'); self.assertIn('type 3 (standalone update)', str(e.exception))
        self.write([{'id': TID, 'platform': 1, 'snapshots': [{'type': 0, 'version': 0, 'tree': self.g.base, 'content_id': self.g.base_id},
                                                            {'type': 1, 'version': VER + 1, 'tree': self.g.update, 'content_id': self.g.update_id}]}])
        with self.assertRaises(pack_nx.Error) as e: self.opened(FakeTool())
        self.assertEqual(e.exception.code, 'nca'); self.assertIn('its catalog row says Patch 040074A01BF12800 version 458753, its content meta says Patch 040074A01BF12800 version 458752',
                                                             str(e.exception))
        self.write([{'id': TID, 'platform': 1, 'snapshots': [{'type': 0, 'version': 0, 'tree': self.g.base, 'content_id': self.g.update_id}]}])
        with self.assertRaises(pack_nx.Error) as e: self.opened(FakeTool())
        self.assertEqual(e.exception.code, 'nca'); self.assertIn('the content meta its catalog row names', str(e.exception))


NX_OK = sys.platform == 'darwin' and (REPO / pack_nx.NX_EXTRACT).is_file()
try: NX_OK = NX_OK and pack_nx.find_tool() is not None
except pack_nx.Error: NX_OK = False


@unittest.skipUnless(NX_OK, 'needs the committed nx_extract built from the sources beside it, on a Mac')
class NativeTool(NativeBase):
    """pack_nx with the real nx_extract on synthetic NCA snapshots (dnca_writer.py)"""
    def scanned(self, **kw):
        n = self.open(); n.nca_tool = pack_nx.Native(tmp=self.work() / 'tmp', logs=self.work() / 'logs', **kw)
        return n, pack_nx.scan(n)

    def test_scan_reads_the_content_metas(self):
        n, (app, base, vers, dlc) = self.scanned()
        self.assertEqual((app, base.version, list(vers), list(dlc)), (TID, 0, [VER], [TID + 0x1001]))
        self.assertEqual(n.snapshots[2].title_id, TID + 0x1001)

    def test_base_update_and_dlc(self):
        g = dnca_writer.Game(TID, manual=True); self.write_game(g)
        n, (app, base, vers, dlc) = self.scanned()
        for k, exefs, romfs, display in ((base, g.exefs0, g.romfs0, '1.0.0'), (vers[VER], g.exefs1, g.romfs1, '1.2.0')):
            with self.subTest(version=k.version):
                out = self.work() / 'extract' / f'v{k.version}'
                self.assertEqual(pack_nx.pack_version(n, k, base, app, out, say=lambda s: None), 'packed')
                self.assertEqual({p.name: p.read_bytes() for p in (out / 'ExeFS').iterdir()}, exefs)
                img = (out / 'RomFS.img').read_bytes()
                self.assertEqual({p: img[a:a + b] for p, (d, a, b) in romfs_image.read_index(out / 'RomFS.img').items() if not d}, romfs)
                self.assertEqual(nacp.version(out / 'control.nacp'), display)
                self.assertIn(f'display version {display}', (self.work() / f'logs/extract_v{k.version}.log').read_text())
                self.assertEqual(sorted(p.name for p in (out / 'html').iterdir()), ['html0', 'html1'] if k is not base else ['html0'])
                self.assertEqual(pack_nx.pack_version(n, k, base, app, out, say=lambda s: None), 'kept')
        self.assertEqual(list((self.work() / 'tmp/nca').iterdir()), [])
        pack_nx.pack_dlc(n, app, dlc, self.work() / 'aoc', say=lambda s: None)
        self.assertEqual(set(romfs_image.read_index(self.work() / 'aoc/1.img')), {'dlcfile', 'more', 'more/x.bin'})
        self.assertTrue(romfs_image.reusable(str(self.work() / 'aoc/1.img'), json.loads((self.work() / 'aoc/1.img.inputs.json').read_text())['source']))

    def test_sparse_base(self):
        g = dnca_writer.Game(TID, sparse_base=True)
        self.write([{'id': TID, 'platform': 1, 'snapshots': g.snapshots(META, base_build=False)}])   # a sparse base has no build ID of its own
        n, (app, base, vers, dlc) = self.scanned()
        with self.assertRaises(pack_nx.Error) as e: pack_nx.pack_version(n, base, base, app, self.work() / 'extract/v0', say=lambda s: None)
        self.assertEqual(e.exception.code, 'sparse'); self.assertIn('pack an update version', str(e.exception))
        self.assertEqual(pack_nx.pack_version(n, vers[VER], base, app, self.work() / f'extract/v{VER}', say=lambda s: None), 'packed')
        self.assertEqual(set(romfs_image.read_index(self.work() / f'extract/v{VER}/RomFS.img')), {'data', 'data/same.bin', 'data/changed.txt', 'new', 'new/added.bin', 'empty'})

    def test_two_programs(self):
        g = dnca_writer.Game(TID, program2=True, dlc=False)
        self.write([{'id': TID, 'platform': 1, 'programs': [TID, TID + 1], 'snapshots': g.snapshots(META) + [
            {'type': 0, 'version': 0, 'program': 1, 'tree': g.base, 'content_id': g.base_id}]}])
        n, (app, base, vers, dlc) = self.scanned()
        self.assertIn('2 programs: packing 040074A01BF12000', ' '.join(n.notes))
        out = self.work() / f'extract/v{VER}'
        pack_nx.pack_version(n, vers[VER], base, app, out, say=lambda s: None)
        self.assertEqual((out / 'ExeFS/main').read_bytes(), g.exefs1['main'])

    def test_damaged_nca(self):
        prog = bytearray(self.g.base_prog.data)
        start, _ = dnca_writer.section_span(prog, 1)
        off, _ = dnca_writer.ivfc_data_level(prog[0x600 + 8:0x600 + 0x100])
        prog[start + off + 0x5000] ^= 0xFF   # base_only.bin, in an IVFC block of its own: the archive's SHA-256 is of these bytes, the NCA's own hash is not
        self.g.base = {k: (bytes(prog) if v == self.g.base_prog.data else v) for k, v in self.g.base.items()}
        self.write_game()
        n, (app, base, vers, dlc) = self.scanned()
        with self.assertRaises(pack_nx.Error) as e: pack_nx.pack_version(n, base, base, app, self.work() / 'extract/v0', say=lambda s: None)
        self.assertEqual(e.exception.code, 'nca_hash'); self.assertIn("1 file(s) fail the NCA's own hash check (/base_only.bin)", str(e.exception))
        n, (app, base, vers, dlc) = self.scanned(allow_damaged=True)
        said = []
        self.assertEqual(pack_nx.pack_version(n, base, base, app, self.work() / 'extract/v0', say=said.append), 'packed')
        self.assertTrue(any('hash check failed: /base_only.bin' in s for s in said), said)

    def test_cli(self):
        g = dnca_writer.Game(TID, sparse_base=True)
        self.write([{'id': TID, 'platform': 1, 'snapshots': g.snapshots(META, base_build=False)}])
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--work-dir', str(self.work())], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr); self.assertIn('done:', r.stdout)
        self.assertEqual(set(romfs_image.read_index(self.work() / 'aoc/1.img')), {'dlcfile', 'more', 'more/x.bin'})
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--work-dir', str(self.work()), '--version', '0'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertRegex(r.stderr, r'^\[RED\] game.nx \(base\): the base game\'s program is sparse'); self.assertNotIn('Traceback', r.stderr)


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
    def run_main(self, target, *, extract=False, package=None, argv=()):
        seen, said = {}, []
        def stop(env, *a):
            seen.update(env)
            if not extract: raise Stop()
        with mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
             mock.patch.object(nsp, 'check_prereqs', side_effect=stop), mock.patch.object(nsp, 'say', side_effect=said.append), \
             mock.patch.object(nsp, 'check_versions_aarch64', side_effect=Stop), mock.patch.object(nsp, 'find_nx_extract', side_effect=AssertionError('built nx_extract')), \
             mock.patch.object(nsp, 'ask', side_effect=AssertionError('asked for something')), mock.patch.object(nsp, 'package_reader', side_effect=AssertionError('read a package')):
            with self.assertRaises(Stop): nsp.main(nsp.parse_args([str(target)] + (['--package', package] if package else []) + list(argv)))
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

    def test_empty_base_and_no_base_pack_alike(self):   # Mario's profile needs v0 and registers the update: without a base game it is packed from a derived profile (test_nsp_nup.py's twin)
        tid, ver = 0x010015100B514000, 327680
        for snaps in (({'type': 3, 'version': ver, 'tree': version(tid=tid), 'meta': META},),
                      ({'type': 0, 'version': 0, 'tree': {}, 'meta': META}, {'type': 1, 'version': ver, 'tree': version(tid=tid)}),
                      ({'type': 0, 'version': 0, 'tree': {'exefs': {'.listing': b'x'}}, 'meta': META}, {'type': 1, 'version': ver, 'tree': version(tid=tid)})):
            with self.subTest(types=[x['type'] for x in snaps]):
                self.write(game(*snaps, tid=tid))
                work, said = self.run_main(self.path, extract=True)
                self.assertFalse((work / 'extract/v0').exists())
                self.assertEqual((work / f'extract/v{ver}/ExeFS/main').read_bytes(), b'code')
                self.assertEqual(nacp.name(work / f'extract/v{ver}/control.nacp'), 'Test Game')
                self.assertTrue(any('the folder has no v0' in s for s in said), said)

    def test_update_alone_takes_its_base_games_control_data(self):   # the profile packs only the update: the base snapshot's NACP and icon still reach its folder (docs/development.md)
        work, _ = self.run_main(self.path, extract=True)
        self.assertFalse((work / 'extract/v0').exists())
        self.assertEqual(nacp.name(work / f'extract/v{VER}/control.nacp'), 'Test Game')
        self.assertEqual((work / f'extract/v{VER}/icon.jpg').read_bytes(), b'\xff\xd8 icon')

    def test_platform_picks_the_game_and_keeps_its_build_apart(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version(), 'meta': META}, platform=1) + game({'type': 0, 'version': 0, 'tree': version(), 'meta': META}, platform=2))
        self.assertRegex(self.red([str(self.path), '--title-id', f'{TID:016X}']), f'{TID:016X}:switch2 .*platform after the ID')
        self.assertRegex(self.red([str(self.path), '--title-id', f'{TID:016X}:switch3']), 'takes a title ID')
        for plat in ('switch1', 'switch2'):
            work, said = self.run_main(self.path, argv=['--title-id', f'{TID:016X}:{plat}'])
            self.assertEqual(work, self.dir / f'{TID:016X}-{plat}_build')
            self.assertTrue(any(s.startswith(f'an NX: game.nx, {TID:016X}, Switch {plat[-1]}') for s in said), said)

    def test_disk_check_counts_the_code_modules(self):
        n = self.open(); k = n.snapshots[1]
        romfs, code = n.tree_bytes(k.romfs), nsp.exefs_size(n, k)
        self.assertGreater(code, 0)
        n.close()
        with mock.patch.object(nsp, 'free_gb', return_value=6 + (romfs + code / 2) / 2**30):   # room for the RomFS and the 6 GB of slack, not for the code too
            self.assertRegex(self.red([str(self.path)]), r'^\[RED\] less than 6 GB free')

    def red(self, argv):
        with mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
             mock.patch.object(nsp, 'check_prereqs'), mock.patch.object(nsp, 'say'), mock.patch.object(nsp.PROG, 'say') as red:
            self.assertEqual(nsp.cli(argv), 1)
        return red.call_args.args[0]

    def test_errors_are_red_lines(self):
        self.write(game({'type': 0, 'version': 0, 'tree': version()}, {'type': 1, 'version': VER, 'tree': {'exefs': version()['exefs']}}))
        self.assertRegex(self.red([str(self.path)]), r'^\[RED\] .*no romfs/')   # the newest version, read for the disk check before extraction
        self.write(game({'type': 0, 'version': 0, 'tree': {'0123.nca': b'nca'}}))
        self.assertRegex(self.red([str(self.dir)]), r"^\[RED\] game.nx \(base\): '0123.nca' is not a decrypted NCA's file name")
        good = self.path.read_bytes()
        data = bytearray(good); struct.pack_into('<H', data, 6, 9); self.path.write_bytes(nx_writer.reseal(bytes(data)))
        self.assertRegex(self.red([str(self.path)]), r'^\[RED\] game.nx: NX format version 0.9 .*newer NX 18')
        self.path.write_bytes(good[:-1])
        self.assertRegex(self.red([str(self.path)]), r'^\[RED\] game.nx: .* bytes, its header says')
        (self.dir / 'b.nx').write_bytes(b'')
        self.assertRegex(self.red([str(self.dir)]), r'^\[RED\] more than one game container')


if __name__ == '__main__':
    unittest.main()
