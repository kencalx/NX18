"""scripts/drop_build.sh, what the Drag Here droplet runs (scripts/make_drag_here.sh): the NSP script's command for a dropped game folder, its keys and device (DRY_RUN=1)"""
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
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

    def test_mods_folder_is_named(self):
        (self.game / 'prod.keys').write_text('k'); (self.game / 'mods').mkdir()
        _, out, _ = self.run_drop(self.game)
        self.assertIn('mods:', out)


if __name__ == '__main__':
    unittest.main()
