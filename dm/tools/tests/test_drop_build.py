"""scripts/drop_build.sh, what the Drag Here droplet runs (scripts/make_drag_here.sh): the NSP script's command for a dropped game folder, its keys and device (DRY_RUN=1);
the droplet's AppleScript, which builds several dropped folders one after another; and build_ipa.sh's lock, which lets one IPA build at a time use the checkout's dm/ios/Gen"""
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import tempfile
import time
import unittest

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / 'scripts/drop_build.sh'


class DropBuild(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.root = Path(t.name)
        self.home = self.root / 'home'; self.home.mkdir()
        self.game = self.root / 'Games/Persona 5'; self.game.mkdir(parents=True)
        (self.game / 'Persona 5 Royal [01005CA01580E000][v0].nsp').write_bytes(b'')

    def run_drop(self, *args, env=None):
        e = dict(os.environ, DRY_RUN='1', HOME=str(self.home)); e.pop('DEVICE', None); e.update(env or {})
        r = subprocess.run(['bash', str(SCRIPT), *map(str, args)], capture_output=True, text=True, env=e, stdin=subprocess.DEVNULL)
        return r.returncode, r.stdout, r.stderr

    def command(self, out):
        return shlex.split(out.strip().splitlines()[-1])

    def test_keys_in_the_folder_and_a_name_with_spaces(self):
        (self.game / 'prod.keys').write_text('k')
        rc, out, err = self.run_drop(str(self.game) + '/')
        self.assertEqual(rc, 0, err)
        cmd = self.command(out)
        self.assertEqual(cmd[1], str(REPO / 'scripts/build_ipa_from_nsp.py'))
        self.assertEqual(cmd[2], str(self.game), 'the folder as one argument, without its trailing slash')
        self.assertEqual(cmd[cmd.index('-k') + 1], str(self.game / 'prod.keys'))
        self.assertEqual(cmd[cmd.index('--device') + 1], 'iphone', 'the iPhone by default')

    def test_keys_beside_the_folder_then_the_home_folder(self):
        (self.game.parent / 'prod.keys').write_text('k')
        _, out, _ = self.run_drop(self.game)
        self.assertIn(str(self.game.parent / 'prod.keys'), self.command(out))
        (self.game.parent / 'prod.keys').unlink(); (self.home / '.switch').mkdir(); (self.home / '.switch/prod.keys').write_text('k')
        _, out, _ = self.run_drop(self.game)
        self.assertIn(str(self.home / '.switch/prod.keys'), self.command(out))

    def test_one_other_keys_file(self):
        (self.game / 'my.keys').write_text('k'); (self.game / 'title.keys').write_text('t')
        _, out, _ = self.run_drop(self.game)
        self.assertIn(str(self.game / 'my.keys'), self.command(out))

    def test_device_and_errors(self):
        (self.game / 'prod.keys').write_text('k')
        _, out, _ = self.run_drop(self.game, 'ipad')
        self.assertEqual(self.command(out)[self.command(out).index('--device') + 1], 'ipad')
        _, out, _ = self.run_drop(self.game, env={'DEVICE': 'both'})
        self.assertIn('both', self.command(out))
        rc, _, err = self.run_drop(self.game, 'watch'); self.assertNotEqual(rc, 0); self.assertIn('iphone, ipad or both', err)
        (self.game / 'prod.keys').unlink()
        rc, _, err = self.run_drop(self.game); self.assertNotEqual(rc, 0); self.assertIn('no prod.keys', err)
        rc, _, err = self.run_drop(self.root / 'missing'); self.assertNotEqual(rc, 0); self.assertIn('not a folder', err)

    def test_dump_folder_needs_no_keys(self):   # pack_dump.is_dump's layout: base/exefs/main.npdm and a RomFS in base/ or updates/<version>/
        for romfs in ('base/romfs', 'updates/65536/romfs'):
            with self.subTest(romfs=romfs):
                dump = self.root / 'Dumps' / romfs.split('/')[0]
                (dump / 'base/exefs').mkdir(parents=True); (dump / 'base/exefs/main.npdm').write_bytes(b''); (dump / romfs).mkdir(parents=True)
                rc, out, err = self.run_drop(dump)
                self.assertEqual(rc, 0, err)
                self.assertNotIn('-k', self.command(out))
        half = self.root / 'Dumps/no-romfs'; (half / 'base/exefs').mkdir(parents=True); (half / 'base/exefs/main.npdm').write_bytes(b'')
        rc, _, err = self.run_drop(half); self.assertNotEqual(rc, 0); self.assertIn('no prod.keys', err)   # no RomFS: not a dump, so its NSPs need keys
        (self.game / 'exefs').mkdir()   # an exefs folder at the top is no dump either
        rc, _, err = self.run_drop(self.game); self.assertNotEqual(rc, 0); self.assertIn('no prod.keys', err)

    def test_mods_folder_is_named(self):
        (self.game / 'prod.keys').write_text('k'); (self.game / 'mods').mkdir()
        _, out, _ = self.run_drop(self.game)
        self.assertIn('mods:', out)


class DragHere(unittest.TestCase):
    """scripts/make_drag_here.sh: the droplet's AppleScript, with osacompile replaced by a copy of its source, made from a checkout whose path has a double quote and a backslash"""

    def make(self, osacompile):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        root = Path(t.name); self.repo = root / 'my "games" \\ checkout'; (self.repo / 'scripts').mkdir(parents=True)
        for f in ('make_drag_here.sh', 'drop_build.sh'): shutil.copy(REPO / 'scripts' / f, self.repo / 'scripts' / f)
        (root / 'bin').mkdir(); (root / 'tmp').mkdir(); (root / 'out').mkdir()
        (root / 'bin/osacompile').write_text('#!/bin/sh\n' + osacompile); (root / 'bin/osacompile').chmod(0o755)
        env = dict(os.environ, PATH=f'{root}/bin:{os.environ["PATH"]}', TMPDIR=str(root / 'tmp'))
        r = subprocess.run(['bash', str(self.repo / 'scripts/make_drag_here.sh'), 'ipad', str(root / 'out')], env=env, capture_output=True, text=True)
        self.assertEqual(list((root / 'tmp').iterdir()), [], 'no temporary file left behind')
        return r, root / 'out/Drag Here (iPad).app'

    def test_applescript(self):
        r, app = self.make('[ "$1" = -o ] || exit 2\ncp "$3" "$2"\n')
        self.assertEqual(r.returncode, 0, r.stderr)
        src = app.read_text()
        m = re.search(r'^property buildScript : "((?:[^"\\]|\\.)*)"$', src, re.M)
        self.assertTrue(m, src)
        self.assertEqual(re.sub(r'\\(.)', r'\1', m.group(1)), str(self.repo / 'scripts/drop_build.sh'), 'the path as one AppleScript string')
        self.assertIn('property targetDevice : "ipad"', src)
        self.assertEqual(src.count('do script'), 1, 'one Terminal window for every folder dropped together')
        self.assertIn('" </dev/null ; "', src)   # one after another; all but the last do not wait for Return

    def test_failed_compile_leaves_no_temporary_file(self):
        r, app = self.make('exit 1\n')
        self.assertNotEqual(r.returncode, 0)


class IpaBuildLock(unittest.TestCase):
    """build_ipa.sh's ipa_lock, run by itself: a second IPA build waits, naming the first, until the first closes the lock's fd; a killed build releases it; DM_IPA_LOCK=0 does not wait"""

    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.d = Path(t.name); self.log = self.d / 'order.log'
        self.lines = (REPO / 'dm/ios/tools/build_ipa.sh').read_text().splitlines()
        i = next(n for n, ln in enumerate(self.lines) if ln.startswith('ipa_lock() {'))
        j = next(n for n, ln in enumerate(self.lines) if n > i and ln == '}')
        self.fn = '\n'.join(self.lines[i:j + 1])
        self.procs = []

    def tearDown(self):
        for p in self.procs:
            if p.poll() is None: os.killpg(p.pid, signal.SIGKILL)
            p.communicate()

    def start(self, game, hold, **env):   # a build that takes the lock, holds it for the hold command, then closes fd 9 as build_ipa.sh does after xcodebuild
        script = ('set -u\nt() { echo "$*"; }\ndie() { echo "FAIL: $*"; exit 1; }\n' + self.fn +
                  f'\nGAME={game}; DM_DISPLAY_NAME="Game {game}"; IOS_SOURCE="{self.d}"\nipa_lock\necho "{game} got" >> "{self.log}"\n{hold}\n'
                  f'echo "{game} release" >> "{self.log}"\nexec 9>&-\n')
        p = subprocess.Popen(['bash', '-c', script], env=dict(os.environ, **env), stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, start_new_session=True)
        self.procs.append(p); return p

    def order(self): return self.log.read_text().split('\n')[:-1] if self.log.exists() else []

    def held(self, game):
        for _ in range(500):
            if f'{game} got' in self.order(): return
            time.sleep(0.01)
        self.fail(f'{game} did not take the lock')

    def test_second_build_waits_for_the_first(self):
        a = self.start('A', 'sleep 0.6 9>&-'); self.held('A')
        self.assertIn('A (Game A), pid ', (self.d / '.ipa-build.lock').read_text())
        out, _ = self.start('B', ':').communicate(timeout=30)
        a.communicate(timeout=30)
        self.assertEqual(self.order(), ['A got', 'A release', 'B got', 'B release'])
        self.assertIn('waiting for another IPA build in this checkout to finish its app build: A (Game A), pid ', out)
        self.assertIn('DM_IPA_LOCK=0', out)

    def test_a_killed_build_releases_the_lock(self):   # kill -9, or a closed Terminal window: the fd closes with the process
        a = self.start('A', 'sleep 30 9>&-'); self.held('A')
        b = self.start('B', ':')
        time.sleep(0.3); self.assertEqual(self.order(), ['A got'])
        os.killpg(a.pid, signal.SIGKILL)
        b.communicate(timeout=30)
        self.assertEqual(self.order(), ['A got', 'B got', 'B release'])

    def test_off_does_not_wait(self):
        self.start('A', 'sleep 30 9>&-'); self.held('A')
        out, _ = self.start('B', ':', DM_IPA_LOCK='0').communicate(timeout=30)
        self.assertEqual(self.order(), ['A got', 'B got', 'B release'])
        self.assertIn('build lock: off (DM_IPA_LOCK=0)', out)

    def test_a_volume_without_flock_builds_without_it(self):   # some network shares: a line, and the build goes on
        (self.d / 'bin').mkdir(); (self.d / 'bin/python3').write_text('#!/bin/sh\necho "Operation not supported" >&2; exit 1\n'); (self.d / 'bin/python3').chmod(0o755)
        out, _ = self.start('A', ':', PATH=f'{self.d}/bin:{os.environ["PATH"]}').communicate(timeout=30)
        self.assertIn('build lock: none, flock does not work on ', out); self.assertIn('(Operation not supported): building without it', out)
        self.assertEqual(self.order(), ['A got', 'A release'])

    def test_held_from_gen_to_the_end_of_xcodebuild(self):   # IPA mode only; nothing after the release reads the shared Gen/
        at = lambda prefix: next(n for n, ln in enumerate(self.lines) if ln.startswith(prefix))
        take, gen, build, release = at('[ "$PREPARE_XCODE" = YES ] || ipa_lock'), at('rm -rf Gen'), at('xcodebuild -project'), at('exec 9>&-')
        self.assertLess(take, gen); self.assertLess(build, release)
        self.assertTrue(any('9>&-' in ln for ln in self.lines[build:release]), 'xcodebuild runs without the lock fd')
        self.assertFalse([ln for ln in self.lines[release + 1:] if 'Gen/' in ln])
        r = subprocess.run(['git', 'check-ignore', '-q', 'dm/ios/.ipa-build.lock'], cwd=REPO)
        self.assertEqual(r.returncode, 0, 'git ignores the lock file')


if __name__ == '__main__':
    unittest.main()
