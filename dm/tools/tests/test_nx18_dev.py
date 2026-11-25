"""NX18_DEV, the owner's developer switch (dm/tools/nx18_dev.py, docs/development.md "The developer switch"): the rule (the environment, else ~/NX18-work/NX18_DEV), a build
without it exactly as before (no line names it, the stale-profile path is never taken), and with it the stale provisional profile kept and the version surveyed beside it, the warning
at the start and the end, build_ipa.sh's define and the player build's filter. A program other than an application's own (program 1 to 0xFF) of a NUP, an NX or a dump folder:
off, pack_nup.py, pack_nx.py, pack_dump.py and the NSP script stop with a line that says it is not supported yet and never names the switch; on, it is packed under its own ID with
its DLC numbered from the application (the owner's decision of 2026-11-13; the choice of program and the art: test_nsp_programs.py, run with the switch on). No game files, keys or
Xcode needed."""
import contextlib
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(REPO / 'dm/tools'))
sys.path.insert(0, str(HERE))
import nx18_dev
import programs
import romfs_image
import test_nsp_nup as nuptest   # its NUP writer, and the NSP script it loaded
import test_nsp_dump as dumptest
import test_pack_nx as nxtest

nsp = nuptest.nsp
pack_nup, pack_dump, pack_nx = nsp.pack_nup, nsp.pack_dump, nsp.pack_nx
APP = 0x0400000000123000   # an application no profile has
PROG = APP + 1   # its program 1: the title ID a multi-program application's second program has
DLC = APP + 0x1001   # the application's DLC 1
NOTE = programs.note('', {1: PROG}, 1, '')
assert NOTE is not None, 'programs.note says nothing of a program packed alone'
NOTE = NOTE[2:]   # what a pack script says of a program packed alone, after the container's name


class Stop(Exception): pass


@contextlib.contextmanager
def switch(env=None, file=False):
    """os.environ with a home folder of its own (no ~/NX18-work/NX18_DEV unless file) and NX18_DEV unset, or set to env"""
    with tempfile.TemporaryDirectory() as home, mock.patch.dict(os.environ, {'HOME': home}):
        os.environ.pop('NX18_DEV', None)
        if env is not None: os.environ['NX18_DEV'] = env
        if file: (Path(home) / 'NX18-work').mkdir(); (Path(home) / 'NX18-work/NX18_DEV').write_text('')
        yield Path(home)


class Rule(unittest.TestCase):
    def test_environment_then_file(self):
        for env, file, want in ((None, False, None), ('', False, None), ('0', False, None), ('1', False, 'NX18_DEV=1'), ('yes', False, 'NX18_DEV=yes'),
                                (None, True, 'file'), ('', True, 'file'), ('0', True, None), ('00', True, None), ('1', True, 'NX18_DEV=1')):
            with self.subTest(env=env, file=file), switch(env, file) as home:
                got = nx18_dev.source()
                self.assertEqual(got, str(home / 'NX18-work/NX18_DEV') if want == 'file' else want)
                self.assertEqual(nx18_dev.on(), want is not None)
                r = subprocess.run([sys.executable, str(REPO / 'dm/tools/nx18_dev.py')], capture_output=True, text=True)
                self.assertEqual(r.returncode, 0 if want else 1, r.stderr)


UNSUPPORTED = "This program isn't supported yet"   # the line a build stops with off (programs.unsupported)


def refused(test, text):   # the off line: says the program is not supported yet, and never names the switch
    test.assertIn(UNSUPPORTED, text); test.assertIn(f'{PROG:016X} is program 1 of a multi-program application', text); test.assertNotIn('NX18_DEV', text)


class Nup(nuptest.Base):
    def write(self):
        nuptest.write_nup(self.path, [(0, PROG, 0, nuptest.version(tid=PROG), nuptest.META), (2, DLC, 0, {'romfs': {'dlcfile': b'dlc'}}, b'')])

    def test_off_refused(self):
        self.write()
        with switch(), pack_nup.Nup(self.path) as n, self.assertRaises(pack_nup.Error) as e: pack_nup.scan(n)
        refused(self, str(e.exception))
        with switch('1'), pack_nup.Nup(self.path) as n, self.assertRaises(pack_nup.Error): pack_nup.scan(n, dev=False)   # dev given: the caller's, not the environment's

    def test_on_packed_with_dlc_numbered_from_the_application(self):
        self.write()
        for env, dev in (('1', None), (None, True)):
            aoc = self.dir / f'aoc{env}'
            with self.subTest(env=env), switch(env), pack_nup.Nup(self.path) as n:
                app, base, vers, dlc = pack_nup.scan(n, dev=dev)
                self.assertEqual((app, base is not None, sorted(dlc)), (PROG, True, [DLC]))
                pack_nup.pack_dlc(n, app, dlc, aoc, say=lambda s: None)
            self.assertEqual(sorted(p.name for p in aoc.iterdir()), ['1.img', '1.img.inputs.json'])
            self.assertIn('dlcfile', romfs_image.read_index(aoc / '1.img'))

    def test_base_game_the_same_with_and_without_the_switch(self):
        nuptest.write_nup(self.path, [(0, APP, 0, nuptest.version(tid=APP), nuptest.META), (2, DLC, 0, {'romfs': {'dlcfile': b'dlc'}}, b'')])
        for env in (None, '1'):
            with self.subTest(env=env), switch(env), pack_nup.Nup(self.path) as n:
                app, base, vers, dlc = pack_nup.scan(n)
                self.assertEqual((app, sorted(dlc), n.notes), (APP, [DLC], []))

    def test_standalone_script(self):
        self.write()
        cmd = [sys.executable, str(REPO / 'scripts/pack_nup.py'), str(self.path), '--work-dir', str(self.dir / 'cli')]
        with switch():
            r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr); self.assertTrue(r.stderr.startswith('[RED] game.nup: '), r.stderr); self.assertNotIn('Traceback', r.stderr)
        refused(self, r.stdout + r.stderr)
        self.assertFalse((self.dir / 'cli').exists())
        with switch(file=True):
            r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn(NOTE, r.stdout)
        self.assertTrue((self.dir / 'cli/aoc/1.img').is_file())


class Dump(unittest.TestCase):
    def setUp(self):
        td = tempfile.TemporaryDirectory(); self.addCleanup(td.cleanup)
        self.dump = Path(td.name).resolve() / 'dump'
        dumptest.version(self.dump / 'base', tid=PROG)
        (self.dump / f'dlc/{DLC:016x}/0/romfs').mkdir(parents=True)
        (self.dump / f'dlc/{DLC:016x}/0/romfs/dlcfile').write_text('dlc')

    def test_off_refused_on_packed(self):
        with switch(), self.assertRaises(pack_dump.Error) as e: pack_dump.scan(self.dump)
        refused(self, str(e.exception))
        with switch('1'):
            app, vers, dlc = pack_dump.scan(self.dump)
            self.assertEqual((app, sorted(dlc)), (PROG, [DLC]))
            aoc = self.dump.parent / 'aoc'
            pack_dump.pack_dlc(app, dlc, aoc, say=lambda s: None)
        self.assertTrue((aoc / '1.img').is_file())

    def test_standalone_script(self):
        cmd = [sys.executable, str(REPO / 'scripts/pack_dump.py'), str(self.dump), '--work-dir', str(self.dump.parent / 'w')]
        with switch():
            r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr); self.assertTrue(r.stderr.startswith('[RED] dump: '), r.stderr)
        refused(self, r.stdout + r.stderr)
        with switch('1'):
            r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue((self.dump.parent / 'w/aoc/1.img').is_file())


class Nx(nxtest.Base):
    def write_program(self):
        self.write(nxtest.game({'type': 0, 'version': 0, 'tree': nxtest.version(tid=PROG), 'meta': nxtest.META},
                               {'type': 2, 'version': 0, 'addon': DLC, 'tree': {'romfs': {'dlcfile': b'dlc'}}}, tid=PROG))

    def test_off_refused_on_packed(self):
        self.write_program()
        with switch(), self.assertRaises(pack_nx.Error) as e: pack_nx.scan(self.open())
        refused(self, str(e.exception))
        with switch('1'):
            n = self.open()
            app, base, vers, dlc = pack_nx.scan(n)
            self.assertEqual((app, sorted(dlc)), (PROG, [DLC]))
            self.assertIn(f'game.nx: {NOTE}', n.notes)
            aoc = self.dir / 'aoc'
            pack_nx.pack_dlc(n, app, dlc, aoc, say=lambda s: None)
        self.assertTrue((aoc / '1.img').is_file())

    def test_standalone_script(self):
        self.write_program()
        cmd = [sys.executable, str(REPO / 'scripts/pack_nx.py'), str(self.path), '--work-dir', str(self.dir / 'w')]
        with switch():
            r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 1, r.stdout + r.stderr); self.assertTrue(r.stderr.startswith('[RED] game.nx: '), r.stderr)
        refused(self, r.stdout + r.stderr)
        with switch('1'):
            r = subprocess.run(cmd, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertTrue((self.dir / 'w/aoc/1.img').is_file())


class Build(nuptest.Base):
    """The NSP script's main: the same lines without the switch as before it, the switch's own lines with it"""
    def run_main(self, argv=(), survey=None):
        said, seen = [], {}
        def stop(env, *a): seen.update(env); raise Stop()
        with mock.patch.object(nsp, 'find_repo', return_value=REPO), mock.patch.object(nsp, 'WORK_DIR', ''), mock.patch.object(nsp, 'PROD_KEYS', ''), \
             mock.patch.object(nsp, 'check_prereqs', side_effect=stop), mock.patch.object(nsp, 'say', side_effect=said.append), \
             mock.patch.object(nsp, 'check_capstone'), mock.patch.object(nsp, 'survey', side_effect=survey or Stop), \
             mock.patch.object(nsp, 'find_nx_extract', side_effect=AssertionError('built nx_extract')), \
             mock.patch.object(nsp, 'ask', side_effect=AssertionError('asked for something')), mock.patch.object(nsp, 'package_reader', side_effect=AssertionError('read a package')):
            with self.assertRaises((Stop, nsp.BuildError)) as e: nsp.main(nsp.parse_args([str(self.path), *argv]))
        return e.exception, said, seen

    def test_without_the_switch_as_before(self):
        with switch(), mock.patch.object(nsp, 'dev_profile_folder', side_effect=AssertionError('the switch\'s path')):
            stopped, off, seen = self.run_main()   # a game with a profile: on to the prerequisite check
            self.assertIsInstance(stopped, Stop)
            self.assertEqual(Path(seen['DM_ROOT']), self.dir / f'{nuptest.TID:016X}_build')
            self.assertFalse([s for s in off if 'NX18_DEV' in s], off)
            end = []
            with mock.patch.object(nsp, 'say', side_effect=end.append): nsp.report_profile_status(None, None, 'v0', False, False)   # the end: no warning
            self.assertEqual(end, [])
        with switch('1'):
            _, on, _ = self.run_main()
        self.assertEqual(on[0], nx18_dev.WARNING.format(source='NX18_DEV=1'))
        stamp = lambda lines: [re.sub(r'build ID [0-9A-Z]{4}-[0-9A-Z]{4}', 'build ID ?', s) for s in lines]   # a new ID for every build (build_stamp, G17)
        self.assertEqual(stamp([s for s in on if 'NX18_DEV' not in s]), stamp(off))   # for a game with a profile the switch adds its warning and nothing else
        nuptest.write_nup(self.path, [(0, PROG, 0, nuptest.version(tid=PROG), nuptest.META)])
        with switch():
            stopped, said, _ = self.run_main()   # a program of an application: stops, not supported yet, as X1.0 stopped
        self.assertIsInstance(stopped, nsp.BuildError); refused(self, str(stopped))
        self.assertFalse([s for s in said if 'NX18_DEV' in s], said)

    def test_without_the_switch_a_program_of_an_nx_or_a_dump_stops(self):   # the NSP script on the other two containers
        nx = self.dir / 'nx'; nx.mkdir()
        nxtest.nx_writer.write(nx / 'game.nx', nxtest.game({'type': 0, 'version': 0, 'tree': nxtest.version(tid=PROG), 'meta': nxtest.META}, tid=PROG))
        dump = self.dir / 'dump'; dumptest.version(dump / 'base', tid=PROG)
        for path in (nx / 'game.nx', dump):
            with self.subTest(path=path.name), switch(), mock.patch.object(self, 'path', path):
                stopped, said, _ = self.run_main()
                self.assertIsInstance(stopped, nsp.BuildError); refused(self, str(stopped))
                self.assertFalse([s for s in said if 'NX18_DEV' in s], said)

    def test_with_the_switch_a_program_is_surveyed(self):
        nuptest.write_nup(self.path, [(0, PROG, 0, nuptest.version(tid=PROG), nuptest.META)])
        got = {}
        def survey(nsp_dir, app, fam, *a): got['app'] = app; raise Stop()
        with switch(file=True) as home:
            stopped, said, _ = self.run_main(survey=survey)
            self.assertIsInstance(stopped, Stop)
            self.assertEqual(got['app'], PROG)
            self.assertEqual(said[0], nx18_dev.WARNING.format(source=str(home / 'NX18-work/NX18_DEV')))
            self.assertIn(f'game.nup: {NOTE}', said)
            with mock.patch.object(nsp, 'DEV', nx18_dev.source()), mock.patch.object(nsp, 'say', side_effect=said.append):
                nsp.report_profile_status(None, None, 'v0', False, False)   # the end repeats the warning
            self.assertEqual(said[-1], said[0])

    def test_stale_provisional_profile_is_kept_and_the_version_surveyed_beside_it(self):
        nuptest.write_nup(self.path, [(0, APP, 0, nuptest.version(tid=APP), nuptest.META), (1, APP, nuptest.VER, nuptest.version(main=b'new', tid=APP), b'')])
        pdir = self.dir / f'{APP:016X}_build/profile'
        cached = pdir / f'{APP:016X}'; cached.mkdir(parents=True)
        tsv = f'title_id\t{APP:016X}\nshader_versions\tv0\nbuild\tv0\t1.0.0\tmain=00\n'
        (cached / 'game.tsv').write_text(tsv)
        got = {}
        def survey(nsp_dir, app, fam, *a): got['app'] = app; raise Stop()
        with switch():   # off: as before, the stale profile stops the build after loading it (provisional_version)
            stopped, said, _ = self.run_main(survey=survey)
            self.assertNotIn('app', got)
            self.assertIsInstance(stopped, nsp.BuildError); self.assertIn('cached provisional profile describes v0', str(stopped))
        with switch('1'):
            stopped, said, _ = self.run_main(survey=survey)
            self.assertIsInstance(stopped, Stop)
            self.assertEqual(got['app'], APP)   # surveyed again, for v<VER>
            alt = pdir.with_name(f'profile-v{nuptest.VER}')
            self.assertTrue(any(s.startswith('NX18_DEV: the provisional profile in') and str(alt) in s for s in said), said)
        self.assertEqual((cached / 'game.tsv').read_text(), tsv)   # kept as it was
        self.assertEqual(nsp.dev_profile_folder(pdir, APP, {'v0': None}, None), pdir)   # it describes the version
        self.assertEqual(nsp.dev_profile_folder(pdir, APP, {'v0': None, f'v{nuptest.VER}': 1}, 'v0'), pdir)
        self.assertEqual(nsp.dev_profile_folder(pdir, APP, {'v0': None, 'v9': 1}, 'v7'), pdir)   # not in the folder: provisional_version says so
        self.assertEqual(nsp.dev_profile_folder(self.dir / 'none', APP, {'v9': 1}, None), self.dir / 'none')


class IpaBuild(unittest.TestCase):
    """build_ipa.sh's lines that add the define, run on their own"""
    def run_block(self, env=None, file=False):
        text = (REPO / 'dm/ios/tools/build_ipa.sh').read_text()
        start = text.index('if NX18_DEV_SOURCE=$(python3 "$DM/tools/nx18_dev.py"); then')
        block = text[start:text.index('\nfi\n', start) + 4]
        with tempfile.TemporaryDirectory() as tmp, switch(env, file):
            (Path(tmp) / 'Gen').mkdir(); (Path(tmp) / 'Gen/dm.xcconfig').write_text('OTHER_CFLAGS = $(inherited) -DX\n')
            script = 't() { echo "[time] $*"; }\nDM=' + str(REPO / 'dm') + '\n' + block
            r = subprocess.run(['bash', '-c', script], cwd=tmp, capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            return (Path(tmp) / 'Gen/dm.xcconfig').read_text(), r.stdout

    def test_define_only_with_the_switch(self):
        config, out = self.run_block()
        self.assertEqual((config, out), ('OTHER_CFLAGS = $(inherited) -DX\n', ''))
        config, out = self.run_block(file=True)
        self.assertEqual(config, 'OTHER_CFLAGS = $(inherited) -DX\nGCC_PREPROCESSOR_DEFINITIONS = $(inherited) DM_DEV_BUILD=1\n')
        self.assertIn('[RED] NX18_DEV is on', out)


@unittest.skipUnless(shutil.which('cc'), 'no C compiler')
class PlayerFilter(unittest.TestCase):
    """player_env.h: a developer build keeps every DM_NVN_* switch and DM_SLOWFRAME; the test, validation and input switches stay filtered (test_player_env.py: without it)"""
    def test_developer_player_build(self):
        source = r'''
#include <assert.h>
#include "player_env.h"
int main(void) {
 const char *keep[]={"DM_NVN_PROF","DM_NVN_CPUPROF","DM_NVN_TSV","DM_NVN_WAITS","DM_NVN_ENC_THREAD","DM_SLOWFRAME","DM_SHOW_FPS"};
 const char *drop[]={"DM_TEST_UP_LOST","MTL_DEBUG_LAYER","MTL_SHADER_VALIDATION","DM_CTL","DM_KEYS","DM_PROBE","DM_MSL_DIR","DM_DETCLOCK"};
 for(unsigned i=0;i<sizeof keep/sizeof *keep;i++)assert(!dm_player_diagnostic_key(keep[i]));
 for(unsigned i=0;i<sizeof drop/sizeof *drop;i++)assert(dm_player_diagnostic_key(drop[i]));
 assert(!dm_player_env_dropped("DM_NVN_PROF","1")&&!dm_player_env_dropped("DM_SLOWFRAME","1")&&dm_player_env_dropped("DM_SLOWFRAME","0"));
 assert(DM_DEV_BUILD==1);
}
'''
        with tempfile.TemporaryDirectory() as tmp:
            c, exe = Path(tmp) / 'test.c', Path(tmp) / 'test'
            c.write_text(source)
            subprocess.run(['cc', '-Wall', '-Werror', '-DDM_DEV_BUILD=1', '-I', str(REPO / 'dm/ios/Sources'), str(c), '-o', str(exe)], check=True)
            subprocess.run([str(exe)], check=True)

    def test_not_in_player_docs(self):   # docs/development.md only: never the README, the building guide or the scripts' help
        for doc in ('README.md', 'docs/building.md'):
            self.assertNotIn('NX18_DEV', (REPO / doc).read_text(encoding='utf-8'), doc)
        self.assertIn('### The developer switch (`NX18_DEV`)', (REPO / 'docs/development.md').read_text(encoding='utf-8'))
        r = subprocess.run([sys.executable, str(REPO / 'scripts/build_ipa_from_nsp.py'), '--help'], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertNotIn('NX18_DEV', r.stdout)


if __name__ == '__main__':
    unittest.main()
