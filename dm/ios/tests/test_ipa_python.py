"""build_ipa.sh's helper scripts run the Python DM_PYTHON names (the NSP script sets it to its own interpreter), and python3 on PATH without it, as before: an Intel Homebrew's python3 first on
PATH ran them, and the universal xcrun / metal-tt they start, as Intel code under Rosetta. The real script runs until its first check fails, before it writes anything."""
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
SCRIPT = REPO / 'dm/ios/tools/build_ipa.sh'
GAME = '010015100B514000'


class HelperPython(unittest.TestCase):
    def setUp(self):
        t = tempfile.TemporaryDirectory(); self.addCleanup(t.cleanup)
        self.d = Path(t.name); self.log = self.d / 'calls.log'
        (self.d / 'bin').mkdir()
        for name, tag in ((self.d / 'bin/python3', 'PATH'), (self.d / 'dm_python', 'DM')):   # each logs, then runs this Python
            name.write_text(f'#!/bin/sh\necho "{tag} $*" >> "{self.log}"\nexec "{sys.executable}" "$@"\n'); name.chmod(0o755)

    def run_script(self, **extra):
        env = {k: v for k, v in os.environ.items() if not k.startswith('DM_') and k not in ('FONT_PY', 'PATCHED', 'ROMFS', 'MSL_IOS', 'GFXAPI', 'AOC', 'PROGRAMS_TSV')}
        (self.d / 'patched').mkdir(exist_ok=True); (self.d / 'patched/main.fixups.tsv').write_text('# fixture\n')   # past the first check: the modules read through game.py
        env.update(PATH=f'{self.d}/bin:{os.environ["PATH"]}', GAME=GAME, W=str(self.d / 'w'), PATCHED=str(self.d / 'patched'), ROMFS=str(self.d / 'romfs'), MSL_IOS=str(self.d / 'msl'),
                   DM_DISPLAY_NAME='Fixture', DM_APP_VERSION='1.0', **extra)
        r = subprocess.run(['/bin/bash', str(SCRIPT)], env=env, capture_output=True, text=True, timeout=120)
        self.assertNotEqual(r.returncode, 0, r.stdout)   # it stops at the RomFS / module checks: nothing past them runs, nothing is written
        self.assertIn('FAIL: no', r.stdout)
        return self.log.read_text().splitlines() if self.log.exists() else []

    def test_dm_python_runs_every_helper(self):
        calls = self.run_script(DM_PYTHON=str(self.d / 'dm_python'))
        self.assertGreaterEqual(len(calls), 5, calls)   # game.py dir, gp package / ipa / romfs_marker / app_category, game.py modules
        self.assertEqual([c for c in calls if not c.startswith('DM ')], [], calls)
        self.assertTrue(any(c.startswith(f'DM {REPO}/dm/games/game.py dir {GAME}') for c in calls), calls)

    def test_by_hand_python3_on_path_as_before(self):
        calls = self.run_script()
        self.assertGreaterEqual(len(calls), 5, calls)
        self.assertEqual([c for c in calls if not c.startswith('PATH ')], [], calls)

    def test_every_python3_is_one_the_function_takes(self):   # exec, command, env or a path would go around it; FONT_PY's default names DM_PYTHON
        text = SCRIPT.read_text()
        code = [ln for ln in text.splitlines() if not ln.lstrip().startswith('#')]
        define = next(i for i, ln in enumerate(code) if ln.startswith('[ -z "${DM_PYTHON:-}" ] || python3() {'))
        first = next(i for i, ln in enumerate(code) if re.search(r'\bpython3\b', ln) and i != define)
        self.assertLess(define, first)
        for ln in code:
            self.assertIsNone(re.search(r'(\bexec|\bcommand|\benv|/)\s*"?python3\b', ln), ln)
        self.assertIn('exec "${FONT_PY:-${DM_PYTHON:-python3}}" "$DM/tools/make_ext_font.py"', text)

    def test_the_function_keeps_assignments_substitutions_and_pipes(self):   # the forms build_ipa.sh calls it in: VAR=value python3 …, $(python3 …), python3 … | …
        define = next(ln for ln in SCRIPT.read_text().splitlines() if ln.startswith('[ -z "${DM_PYTHON:-}" ] || python3() {'))
        body = (f'set -u\n{define}\nX=$(python3 -c "print(1)"); echo "sub $X"\nGFX=vk python3 -c "import os; print(\'env\', os.environ[\'GFX\'])"\necho "after ${{GFX-unset}}"\n'
                'python3 -c "print(2)" 9>&- | while read -r l; do echo "pipe $l"; done\n')
        env = {k: v for k, v in os.environ.items() if not k.startswith('DM_')} | {'PATH': f'{self.d}/bin:{os.environ["PATH"]}', 'DM_PYTHON': str(self.d / 'dm_python')}
        r = subprocess.run(['/bin/bash', '-c', body], env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual((r.returncode, r.stdout), (0, 'sub 1\nenv vk\nafter unset\npipe 2\n'), r.stderr)
        self.assertEqual([c.split()[0] for c in self.log.read_text().splitlines()], ['DM'] * 3)


if __name__ == '__main__':
    unittest.main()
