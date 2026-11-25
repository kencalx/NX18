"""Several programs of one application in a NUP, an NX or a dump folder (dm/tools/programs.py, docs/reference/packing.md "A NUP holding several programs of one application"): a
Nintendo Switch 2 Edition's NUP holds the Switch 1 game as program 0 and the Switch 2 one as program 1, whose title ID starts 04 where the application's starts 01 (Xenoblade Chronicles
X: Definitive Edition's is the case this was written for). The program packed and its title ID, its versions, its DLC numbered from the application, the choices (--program, --title-id,
a game profile, the Switch 2 one by default), the refusals, pack_nup.py --list and --program, and the NSP script's lines. A program other than program 0 builds only with NX18_DEV on
(the owner's decision of 2026-11-13), so these run with it on (dev), and Off checks that, without it, the same choices stop with the not-supported line while program 0 still builds
(test_nx18_dev.py: the line in every script). The containers are written here: no game files, keys or Xcode."""
import contextlib
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO / 'dm/tools'))
sys.path.insert(0, str(HERE))
import programs
import romfs_image
import test_nsp_nup as nuptest   # its NUP writer, and the NSP script it loaded
import test_nsp_dump as dumptest
import test_pack_nx as nxtest

nsp = nuptest.nsp
pack_nup, pack_dump, pack_nx = nsp.pack_nup, nsp.pack_dump, nsp.pack_nx
APP = 0x0100000000ABC000   # a Switch 1 application no profile has: program 0, the Switch 1 game
S2 = 0x0400000000ABC001   # its Nintendo Switch 2 Edition's Switch 2 program, program 1
DLC = 0x0100000000ABD001   # the application's DLC 1
VER = nuptest.VER


class Stop(Exception): pass


def dev(test, value='1'):   # NX18_DEV for the test: '1' on, '0' off even with ~/NX18-work/NX18_DEV there (subprocesses inherit it)
    p = mock.patch.dict(os.environ, {'NX18_DEV': value}); p.start(); test.addCleanup(p.stop)


UNSUPPORTED = "This program isn't supported yet"


class Ids(unittest.TestCase):
    def test_index_and_application(self):
        self.assertEqual([programs.index(t) for t in (APP, APP + 1, S2, APP + 0xFF, APP + 0x100, APP + 0x800, DLC)], [0, 1, 1, 0xFF, None, None, 1])
        self.assertTrue(programs.same_application(APP, S2))   # the platform byte aside, the same application
        self.assertFalse(programs.same_application(APP, 0x0100000000ABE001))
        self.assertFalse(programs.same_application(APP, APP + 0x800))   # an update's ID is no program
        self.assertEqual((programs.switch2(S2), programs.switch2(APP)), (True, False))

    def test_dlc_index_from_the_application(self):
        self.assertEqual([programs.dlc_index(DLC, p) for p in (APP, APP + 1, S2)], [1, 1, 1])   # the 01 DLC of a 04 program: the platform byte is left out
        self.assertEqual(programs.dlc_index(0x040074A01BF13002, 0x040074A01BF12000), 2)   # a Switch 2 game's own, as before
        self.assertIsNone(programs.dlc_index(APP, APP)); self.assertIsNone(programs.dlc_index(APP + 0x1000 + 2001, APP)); self.assertIsNone(programs.dlc_index(0x0100000000DEF001, APP))

    def test_pick(self):
        edition, three = {0: APP, 1: S2}, {0: 0x0100000000123000, 1: 0x0100000000123001, 2: 0x0100000000123002}
        self.assertEqual(programs.edition(edition), 1)
        self.assertIsNone(programs.edition(three)); self.assertIsNone(programs.edition({0: 0x0400000000123000, 1: 0x0400000000123001}))   # all Switch 2: no edition
        self.assertEqual(programs.pick(edition), (1, 'the Nintendo Switch 2 Edition\'s Switch 2 program'))
        self.assertEqual(programs.pick(edition, known=lambda t: t == APP), (0, 'the one with a game profile'))
        self.assertEqual(programs.pick(edition, known=lambda t: True)[0], 1)   # both have one: the Switch 2 one
        self.assertEqual(programs.pick(edition, 0), (0, '')); self.assertEqual(programs.pick(edition, 5), (None, ''))
        self.assertEqual(programs.pick(three), (0, 'the application\'s own'))   # Super Mario 3D All-Stars: program 0, as the NSPs
        self.assertEqual(programs.pick(three, known=lambda t: t == three[2])[0], 0)   # a profile of another program does not move it
        self.assertEqual(programs.pick({1: S2}), (1, ''))


def edition_nup(path, s2_update=True, **kw):
    """A Switch 2 Edition's NUP: program 0's base and update, program 1 in the update only (a full program, as an update that adds one carries it), and a DLC of the application"""
    pk = [(0, APP, 0, nuptest.version(main=b's1 base', marker='s1base', tid=APP), nuptest.META), (1, APP + 0x800, VER, nuptest.version(main=b's1 new', marker='s1new', tid=APP), b'')]
    if s2_update: pk.append((1, S2 + 0x800, VER, nuptest.version(main=b's2 code', marker='s2', tid=S2), b''))
    pk.append((2, DLC, 0, {'romfs': {'dlcfile': b'dlc'}}, b''))
    nuptest.write_nup(path, pk, **kw)


@unittest.skipIf(nuptest.zstd is None, 'no zstd module')
class Nup(unittest.TestCase):
    def setUp(self):
        dev(self)
        td = tempfile.TemporaryDirectory(); self.addCleanup(td.cleanup)
        self.dir = Path(td.name).resolve() / 'game'; self.dir.mkdir()
        self.path = self.dir / 'game.nup'
        edition_nup(self.path)

    def open(self):
        n = pack_nup.Nup(self.path); self.addCleanup(n.close); return n

    def test_switch_2_program_by_default(self):
        n = self.open(); app, base, vers, dlc = pack_nup.scan(n)
        self.assertEqual((app, base, sorted(vers), sorted(dlc), n.programs, n.program), (S2, None, [VER], [DLC], {0: APP, 1: S2}, 1))
        self.assertEqual(len(n.notes), 1)
        self.assertIn(f'holds 2 programs of application {APP:016X}: 0 ({APP:016X}), 1 ({S2:016X}, Switch 2). Packing program 1 ({S2:016X}, the Nintendo Switch 2 Edition\'s Switch 2 program)', n.notes[0])
        self.assertIn('program 1 has no base package of its own', n.no_base)
        self.assertEqual(vers[VER].name, 'game.nup (update 458752, program 1)')
        out = self.dir / 'out'
        pack_nup.pack_version(n, vers[VER], base, app, out, say=lambda s: None)
        self.assertEqual((out / 'ExeFS/main').read_bytes(), b's2 code')
        self.assertIn('dir/s2', romfs_image.read_index(out / 'RomFS.img'))
        self.assertNotIn('dir/s1new', romfs_image.read_index(out / 'RomFS.img'))
        pack_nup.pack_dlc(n, app, dlc, self.dir / 'aoc', say=lambda s: None)   # the application's DLC 1, from a 04 program
        self.assertEqual(sorted(p.name for p in (self.dir / 'aoc').iterdir()), ['1.img', '1.img.inputs.json'])

    def test_program_0_on_request_or_with_a_profile(self):
        for args in ((0,), (None, lambda t: t == APP)):
            with self.subTest(args=args):
                n = self.open(); app, base, vers, _ = pack_nup.scan(n, *args)
                self.assertEqual((app, n.program, base.name, vers[VER].name), (APP, 0, 'game.nup (base, program 0)', 'game.nup (update 458752, program 0)'))
                out = self.dir / f'out{len(args)}'
                pack_nup.pack_version(n, vers[VER], base, app, out, say=lambda s: None)
                self.assertEqual((out / 'ExeFS/main').read_bytes(), b's1 new')
        self.assertIn('the one with a game profile', n.notes[0])

    def test_named_program_missing(self):
        with self.assertRaisesRegex(pack_nup.Error, rf'no program 2 \(--program / PROGRAM_INDEX\): it holds programs 0 \({APP:016X}\), 1'): pack_nup.scan(self.open(), 2)

    def test_scan_twice_names_once(self):
        n = self.open(); pack_nup.scan(n); pack_nup.scan(n, 0)
        self.assertEqual(n.packages[1].name, 'game.nup (update 458752, program 0)')

    def test_refusals(self):
        other = 0x0400000000DEF001   # a program of another application
        for pk, error in (([(0, APP, 0, nuptest.version(tid=APP), b''), (1, APP, VER, nuptest.version(tid=other), b'')], 'different program IDs'),
                          ([(0, APP + 1, 0, nuptest.version(tid=APP + 1), b''), (1, APP, VER, nuptest.version(tid=S2), b'')], 'different program IDs'),   # one index, two IDs
                          ([(0, APP + 0x800, 0, nuptest.version(tid=APP + 0x800), b'')], 'not a base title ID'),
                          ([(0, APP, 0, nuptest.version(tid=APP), b''), (1, S2, VER, nuptest.version(tid=S2), b''), (1, S2, VER, nuptest.version(main=b'x', tid=S2), b'')],
                           'two updates of version 458752 of program 1'),
                          ([(0, APP, 0, nuptest.version(tid=APP), b''), (0, S2, 0, nuptest.version(tid=S2), b''), (0, S2, 0, nuptest.version(main=b'x', tid=S2), b'')],
                           '2 base packages of program 1'),
                          ([(0, S2, 0, nuptest.version(tid=S2), b''), (2, 0x0100000000ABE001, 0, {'romfs': {'f': b'd'}}, b'')], 'not a DLC of')):
            with self.subTest(error=error):
                nuptest.write_nup(self.path, pk)
                with pack_nup.Nup(self.path) as n, self.assertRaisesRegex(pack_nup.Error, error): pack_nup.scan(n)

    def test_a_program_alone(self):   # the Switch 2 program dumped and packed by itself: its own ID, its DLC numbered from the application
        nuptest.write_nup(self.path, [(0, S2, 0, nuptest.version(tid=S2), nuptest.META), (2, DLC, 0, {'romfs': {'dlcfile': b'dlc'}}, b'')])
        n = self.open(); app, base, vers, dlc = pack_nup.scan(n)
        self.assertEqual((app, base is not None, sorted(dlc), n.programs), (S2, True, [DLC], {1: S2}))
        self.assertEqual(n.notes, [f'game.nup: {S2:016X} is program 1 of an application: its title ID names the profile and the build folder; its DLC are the application\'s'])

    def test_one_program_as_before(self):
        nuptest.write_nup(self.path, [(0, nuptest.TID, 0, nuptest.version(), nuptest.META), (1, nuptest.TID, VER, nuptest.version(main=b'new'), b'')])
        n = self.open(); app, base, vers, _ = pack_nup.scan(n)
        self.assertEqual((app, n.programs, n.notes, base.name, vers[VER].name), (nuptest.TID, {0: nuptest.TID}, [], 'game.nup (base)', 'game.nup (update 458752)'))

    def test_package_without_code_goes_by_its_record(self):   # an update with only a RomFS: the program its record's title ID names, else the lowest
        nuptest.write_nup(self.path, [(0, APP, 0, nuptest.version(tid=APP), b''), (1, S2, VER, nuptest.version(tid=S2), b''), (1, S2 + 0x800, VER + 1, {'romfs': {'f': b'x'}}, b''),
                                      (1, 0, VER + 2, {'romfs': {'f': b'y'}}, b'')])
        n = self.open(); _, _, vers, _ = pack_nup.scan(n)
        self.assertEqual(sorted(vers), [VER, VER + 1])
        _, _, vers, _ = pack_nup.scan(n, 0)
        self.assertEqual(sorted(vers), [VER + 2])

    def test_script(self):
        script = [sys.executable, str(REPO / 'scripts/pack_nup.py'), str(self.path)]
        r = subprocess.run(script + ['--list'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        rows = r.stdout.splitlines()
        self.assertEqual(len(rows), 4)
        self.assertIn(f'program {APP:016X}', rows[0]); self.assertIn(f'program {S2:016X}', rows[2]); self.assertIn('program -', rows[3])
        self.assertFalse((self.dir / f'{S2:016X}_build').exists())   # --list packs nothing
        r = subprocess.run(script, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('Packing program 1', r.stdout); self.assertIn('program 1 has no base package of its own', r.stdout)
        self.assertEqual((self.dir / f'{S2:016X}_build/extract/v{VER}/ExeFS/main').read_bytes(), b's2 code')
        self.assertTrue((self.dir / f'{S2:016X}_build/aoc/1.img').is_file())
        r = subprocess.run(script + ['--program', '0', '--version', '0'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.dir / f'{APP:016X}_build/extract/v0/ExeFS/main').read_bytes(), b's1 base')
        r = subprocess.run(script + ['--program', '3'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1); self.assertIn('[RED]', r.stderr); self.assertIn('no program 3', r.stderr); self.assertNotIn('Traceback', r.stderr)

    def test_script_prefers_a_profile_as_the_nsp_script(self):   # program 0 has a game profile (DM_GAMES_DIR): pack_nup.py packs it by default, as the NSP script's scan_nup does
        games = self.dir.parent / 'profiles'; (games / f'{APP:016X}').mkdir(parents=True)
        (games / f'{APP:016X}/game.tsv').write_text(f'title_id\t{APP:016X}\n')
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nup.py'), str(self.path)], capture_output=True, text=True, env={**os.environ, 'DM_GAMES_DIR': str(games)})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn('Packing program 0', r.stdout); self.assertIn('the one with a game profile', r.stdout)
        self.assertEqual((self.dir / f'{APP:016X}_build/extract/v{VER}/ExeFS/main').read_bytes(), b's1 new')
        self.assertFalse((self.dir / f'{S2:016X}_build').exists())


def run_main(test, path, argv=(), on=True):
    """The NSP script's main on path, up to the survey (no profile has these IDs), with NX18_DEV on or off: (what stopped it, its lines, the title ID it surveyed)"""
    said, got = [], {}
    def survey(nsp_dir, app, fam, *a): got['app'] = app; got['fam'] = fam; raise Stop()
    with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {'HOME': home}), \
         mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
         mock.patch.object(nsp, 'PROGRAM_INDEX', None), mock.patch.object(nsp, 'check_prereqs', side_effect=AssertionError('past the survey')), \
         mock.patch.object(nsp, 'say', side_effect=said.append), mock.patch.object(nsp, 'check_capstone'), mock.patch.object(nsp, 'survey', side_effect=survey), \
         mock.patch.object(nsp, 'find_nx_extract', side_effect=AssertionError('built nx_extract')), \
         mock.patch.object(nsp, 'ask', side_effect=AssertionError('asked for something')), mock.patch.object(nsp, 'package_reader', side_effect=AssertionError('read a package')):
        os.environ['NX18_DEV'] = '1' if on else '0'
        with test.assertRaises((Stop, nsp.BuildError)) as e: nsp.main(nsp.parse_args([str(path), *argv]))
    if got.get('fam', {}).get('nup'): got['fam']['nup'].close()
    return e.exception, said, got.get('app')


@unittest.skipIf(nuptest.zstd is None, 'no zstd module')
class Build(unittest.TestCase):
    """The NSP script on a Switch 2 Edition's NUP: which program it scans and the lines it says, up to the survey (no profile has these IDs)"""
    def setUp(self):
        dev(self)
        td = tempfile.TemporaryDirectory(); self.addCleanup(td.cleanup)
        self.dir = Path(td.name).resolve() / 'game'; self.dir.mkdir()
        self.path = self.dir / 'game.nup'
        edition_nup(self.path)

    def run_main(self, argv=(), on=True): return run_main(self, self.path, argv, on)

    def test_switch_2_program_by_default(self):
        stopped, said, app = self.run_main()
        self.assertIsInstance(stopped, Stop, stopped)
        self.assertEqual(app, S2)
        self.assertTrue(said[0].startswith('[RED] NX18_DEV is on'), said)
        self.assertIn(f'a NUP: game.nup, {S2:016X}, 1 update(s), 1 DLC', said)
        self.assertTrue(any('Packing program 1' in s for s in said), said)
        self.assertTrue(any('program 1 has no base package of its own' in s for s in said), said)
        stopped, said, app = self.run_main(on=False)   # off: the same choice, then the not-supported line, with program 0 named
        self.assertIsInstance(stopped, nsp.BuildError, stopped); self.assertIsNone(app)
        self.assertEqual(str(stopped), programs.unsupported('game.nup', S2, {0: APP, 1: S2}))
        self.assertIn('--program 0', str(stopped))
        self.assertFalse([s for s in said + [str(stopped)] if 'NX18_DEV' in s], said)

    def test_program_or_title_id_picks_another(self):
        for argv, on in ((a, on) for a in (['--program', '0'], ['--title-id', f'{APP:016X}']) for on in (True, False)):   # program 0 builds without the switch too
            with self.subTest(argv=argv, on=on):
                stopped, said, app = self.run_main(argv, on)
                self.assertIsInstance(stopped, Stop, stopped)
                self.assertEqual(app, APP)
                self.assertTrue(any('Packing program 0' in s for s in said), said)
        stopped, _, _ = self.run_main(['--program', '4'])
        self.assertIsInstance(stopped, nsp.BuildError); self.assertIn('no program 4', str(stopped))
        stopped, _, _ = self.run_main(['--title-id', '0100000000DEF000'])
        self.assertIsInstance(stopped, nsp.BuildError); self.assertIn(f'which holds {S2:016X}', str(stopped))
        for argv in (['--program', '1'], ['--title-id', f'{S2:016X}']):   # the Switch 2 program asked for by name: off, not supported yet
            with self.subTest(argv=argv):
                stopped, _, app = self.run_main(argv, on=False)
                self.assertIsInstance(stopped, nsp.BuildError); self.assertIn(UNSUPPORTED, str(stopped)); self.assertIsNone(app)

    def test_program_index_setting_0_picks_program_0(self):   # Spyder: PROGRAM_INDEX = 0 asks for program 0, as --program 0 does; None (the default) lets the scan choose
        for setting, want, on in ((0, APP, True), (1, S2, True), (None, S2, True), (0, APP, False), (1, None, False), (None, None, False)):   # off: program 0 only
            with self.subTest(setting=setting, on=on), mock.patch.object(nsp, 'PROGRAM_INDEX', setting):
                said, got = [], {}
                def survey(nsp_dir, app, fam, *a, got=got): got['app'] = app; fam['nup'].close(); raise Stop()
                with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {'HOME': home}), mock.patch.object(nsp, 'find_repo', return_value=REPO), \
                     mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), mock.patch.object(nsp, 'say', side_effect=said.append), \
                     mock.patch.object(nsp, 'check_capstone'), mock.patch.object(nsp, 'survey', side_effect=survey), mock.patch.object(nsp, 'ask', side_effect=AssertionError('asked')), \
                     mock.patch.object(nsp, 'check_prereqs', side_effect=AssertionError('past the survey')):
                    os.environ['NX18_DEV'] = '1' if on else '0'
                    with self.assertRaises((Stop, nsp.BuildError)) as e: nsp.main(nsp.parse_args([str(self.path)]))
                self.assertEqual(got.get('app'), want)
                if want is None: self.assertIn(UNSUPPORTED, str(e.exception)); continue
                self.assertTrue(any(f'Packing program {programs.index(want)}' in s for s in said), said)
                self.assertEqual(nsp.PROGRAM_INDEX, setting)   # the setting is as it was: the build took None as 0 only while it ran

    def test_art_and_icon_go_by_the_application(self):   # titledb and NX Play list the application: a Switch 2 Edition's 04 program finds the 01 application's art and icon
        for program in (None, 0, 1):
            with self.subTest(program=program):
                app, fam = nsp.scan_nup(self.path, program=program)
                fam['nup'].close()
                self.assertEqual(nsp.art_application(app, fam), APP)
        self.assertEqual(nsp.art_application(APP + 2, {}), APP)   # a dump of program 2 alone
        self.assertEqual(nsp.art_application(S2, {}), APP)   # the Switch 2 Edition's Switch 2 program alone: the Switch 1 application's
        self.assertEqual(nsp.art_application(0x0400000000123000 + 1, {'nup': type('N', (), {'programs': {0: 0x0400000000123000, 1: 0x0400000000123001}})()}), 0x0400000000123000)   # a Switch 2 game's own programs
        self.assertEqual(nsp.art_application(nuptest.TID, {}), nuptest.TID)
        nuptest.write_nup(self.path, [(0, S2, 0, nuptest.version(tid=S2), nuptest.META), (2, DLC, 0, {'romfs': {'dlcfile': b'dlc'}}, b'')])   # a NUP of the Switch 2 program alone
        app, fam = nsp.scan_nup(self.path); fam['nup'].close()
        self.assertEqual((app, nsp.art_application(app, fam)), (S2, APP))

    def test_scan_nup_prefers_a_profile(self):
        app, fam = nsp.scan_nup(self.path, known=lambda t: t == APP)
        fam['nup'].close()
        self.assertEqual((app, fam['base'].name), (APP, 'game.nup (base, program 0)'))

    def test_dump_folder_still_refuses_program(self):
        d = self.dir.parent / 'dump'; dumptest.version(d / 'base', tid=APP)
        with mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
             mock.patch.object(nsp, 'PROGRAM_INDEX', None), mock.patch.object(nsp, 'say'), mock.patch.object(nsp, 'ask', side_effect=AssertionError('asked')):
            with self.assertRaisesRegex(nsp.BuildError, 'a dump folder is read as one program'): nsp.main(nsp.parse_args([str(d), '--program', '1']))


class Dump(unittest.TestCase):
    def setUp(self): dev(self)

    def test_a_program_alone_with_the_applications_dlc(self):
        with tempfile.TemporaryDirectory() as td:
            dump = Path(td) / 'dump'
            dumptest.version(dump / 'base', tid=S2)
            (dump / f'dlc/{DLC:016x}/0/romfs').mkdir(parents=True); (dump / f'dlc/{DLC:016x}/0/romfs/dlcfile').write_text('dlc')
            app, vers, dlc = pack_dump.scan(dump)
            self.assertEqual((app, sorted(dlc)), (S2, [DLC]))
            pack_dump.pack_dlc(app, dlc, Path(td) / 'aoc', say=lambda s: None)
            self.assertTrue((Path(td) / 'aoc/1.img').is_file())
            r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_dump.py'), str(dump), '--work-dir', str(Path(td) / 'w')], capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
            self.assertIn(f'dump: {S2:016X} is program 1 of an application', r.stdout)
            stopped, said, app = run_main(self, dump)
            self.assertIsInstance(stopped, Stop, stopped)
            self.assertEqual(app, S2)
            self.assertIn(f'dump: {S2:016X} is program 1 of an application: its title ID names the profile and the build folder; its DLC are the application\'s', said)


@unittest.skipIf(nxtest.zstd is None, 'no zstd module')
class Nx(nxtest.Base):
    def setUp(self):
        dev(self)
        super().setUp()
        self.write([{'id': APP, 'platform': 1, 'programs': [APP, S2], 'snapshots': [
            {'type': 0, 'version': 0, 'program': 0, 'tree': nxtest.version(main=b's1', tid=APP), 'meta': nxtest.META},
            {'type': 1, 'version': VER, 'program': 1, 'tree': nxtest.version(main=b's2', tid=S2)},
            {'type': 2, 'version': 0, 'addon': DLC, 'tree': {'romfs': {'dlcfile': b'dlc'}}}]}])

    def test_art_goes_by_the_application(self):   # --program 1 of an NX: the art and NX Play's icon are the application's
        n = self.open(); app, _, _, _ = pack_nx.scan(n, program=1)
        self.assertEqual((app, nsp.art_application(app, {'nx': n})), (S2, APP))

    def test_own_program_by_default_another_on_request(self):
        n = self.open(); app, base, vers, _ = pack_nx.scan(n)
        self.assertEqual((app, base is not None, sorted(vers)), (APP, True, []))   # as before: the application's own
        self.assertIn(f'2 programs: packing {APP:016X}, its own; --program N packs another', ' '.join(n.notes))
        n = self.open(); app, base, vers, dlc = pack_nx.scan(n, program=1)
        self.assertEqual((app, base, sorted(vers), sorted(dlc)), (S2, None, [VER], [DLC]))
        pack_nx.pack_dlc(n, app, dlc, self.dir / 'aoc', say=lambda s: None)
        self.assertTrue((self.dir / 'aoc/1.img').is_file())
        with self.assertRaisesRegex(pack_nx.Error, 'has no program 2'): pack_nx.scan(self.open(), program=2)

    def test_script_program(self):
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--program', '1'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.dir / f'{S2:016X}_build/extract/v{VER}/ExeFS/main').read_bytes(), b's2')

    def test_off_program_0_only(self):   # without the switch: the application's own by default, --program 1 stops with the not-supported line naming program 0
        os.environ['NX18_DEV'] = '0'
        app, _, _, _ = pack_nx.scan(self.open())
        self.assertEqual(app, APP)
        with self.assertRaises(pack_nx.Error) as e: pack_nx.scan(self.open(), program=1)
        self.assertEqual(str(e.exception), programs.unsupported('game.nx', S2, {0: APP, 1: S2}))
        r = subprocess.run([sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--program', '1'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr); self.assertIn(UNSUPPORTED, r.stderr); self.assertNotIn('NX18_DEV', r.stdout + r.stderr)
        self.assertFalse((self.dir / f'{S2:016X}_build').exists())


@unittest.skipIf(nuptest.zstd is None, 'no zstd module')
class Off(unittest.TestCase):
    """Without NX18_DEV: a Switch 2 Edition's NUP is read and its program chosen as with it, then the Switch 2 program stops with the not-supported line; program 0 packs"""
    def setUp(self):
        dev(self, '0')
        td = tempfile.TemporaryDirectory(); self.addCleanup(td.cleanup)
        self.dir = Path(td.name).resolve() / 'game'; self.dir.mkdir()
        self.path = self.dir / 'game.nup'
        edition_nup(self.path)

    def test_scan(self):
        with pack_nup.Nup(self.path) as n, self.assertRaises(pack_nup.Error) as e: pack_nup.scan(n)
        self.assertEqual(str(e.exception), programs.unsupported('game.nup', S2, {0: APP, 1: S2}))
        with pack_nup.Nup(self.path) as n:
            app, _, vers, dlc = pack_nup.scan(n, 0)
            self.assertEqual((app, sorted(vers), sorted(dlc)), (APP, [VER], [DLC]))
            self.assertEqual(pack_nup.scan(n, dev=True)[0], S2)   # the caller's dev over the environment's

    def test_script(self):
        script = [sys.executable, str(REPO / 'scripts/pack_nup.py'), str(self.path)]
        r = subprocess.run(script, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr)
        self.assertEqual(r.stderr.strip(), '[RED] ' + programs.unsupported('game.nup', S2, {0: APP, 1: S2}))
        self.assertNotIn('NX18_DEV', r.stdout + r.stderr)
        self.assertFalse((self.dir / f'{S2:016X}_build').exists())
        self.assertEqual(subprocess.run(script + ['--list'], capture_output=True, text=True).returncode, 0)   # --list reads it as before
        r = subprocess.run(script + ['--program', '0'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertEqual((self.dir / f'{APP:016X}_build/extract/v{VER}/ExeFS/main').read_bytes(), b's1 new')

    def test_a_program_alone(self):   # Xenoblade Chronicles X: Definitive Edition's NUP: the Switch 2 program alone, no program 0 to name
        nuptest.write_nup(self.path, [(0, S2, 0, nuptest.version(tid=S2), nuptest.META), (2, DLC, 0, {'romfs': {'dlcfile': b'dlc'}}, b'')])
        with pack_nup.Nup(self.path) as n, self.assertRaises(pack_nup.Error) as e: pack_nup.scan(n)
        self.assertEqual(str(e.exception), f'game.nup: {S2:016X} is program 1 of a multi-program application, a Switch 2 program. {UNSUPPORTED}: '
                                           'NX 18 builds an application\'s own program (program 0)')


class Docs(unittest.TestCase):
    def test_documented(self):
        ref = (REPO / 'docs/reference/packing.md').read_text(encoding='utf-8')
        self.assertIn('### A NUP holding several programs of one application', ref)
        self.assertIn('test_nsp_programs', ref)
        self.assertIn('--program 0', (REPO / 'docs/building.md').read_text(encoding='utf-8'))
        with contextlib.redirect_stdout(io.StringIO()) as out, self.assertRaises(SystemExit):
            with mock.patch.object(sys, 'argv', ['pack_nup.py', '--help']): pack_nup.main()
        self.assertIn('--program', out.getvalue()); self.assertIn('--list', out.getvalue())


if __name__ == '__main__':
    unittest.main()
