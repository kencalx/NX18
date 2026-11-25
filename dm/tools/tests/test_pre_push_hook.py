"""The pre-push hook (.githooks/pre-push) runs the Python lint ratchet with the Python that git config nx18.lintPython names, on what the push sends: without it the push goes
on with a line saying so; with a Python that lacks a pin of lint.txt, or a failing ratchet, the push stops. A deletion, or a push with no Python or lint setting the remote side
lacks, is not checked; a commit other than a clean HEAD is checked in an export of its own files. Runs the hook in temporary repositories with a stub ratchet and stub tool
versions (dist-info folders on PYTHONPATH): no ruff, pyright or network needed."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]
HOOK = REPO / '.githooks/pre-push'
PINS = {'ruff': '0.17.2', 'pyright': '1.1.414'}
ZERO = '0' * 40
# the stub ratchet: notes where it ran and the Python files there, exits with LINT_RC
RATCHET = ("import json, os, pathlib, sys\n"
           "pathlib.Path(os.environ['MARK']).write_text(json.dumps({'cwd': os.getcwd(), 'py': sorted(p.as_posix() for p in pathlib.Path('.').rglob('*.py'))}))\n"
           "sys.exit(int(os.environ.get('LINT_RC', '0')))\n")


@unittest.skipUnless(shutil.which('git'), 'no git')
class PrePush(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name).resolve()
        self.env = {k: v for k, v in os.environ.items() if not k.startswith(('GIT_', 'PYTHON'))}
        self.env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1', MARK=str(self.tmp / 'ran'), TMPDIR=str(self.tmp))
        self.repo = self.tmp / 'repo'
        (self.repo / 'dm/tools').mkdir(parents=True)
        (self.repo / '.github/requirements').mkdir(parents=True)
        (self.repo / 'dm/tools/lint_python.py').write_text(RATCHET)
        (self.repo / 'pyproject.toml').write_text('[tool.ruff]\n')
        self.pin(PINS)
        site = self.tmp / 'site'
        for name, version in PINS.items():
            d = site / f'{name}-{version}.dist-info'
            d.mkdir(parents=True)
            (d / 'METADATA').write_text(f'Metadata-Version: 2.1\nName: {name}\nVersion: {version}\n')
        self.py = self.tmp / 'python3'
        self.py.write_text(f'#!/bin/sh\nPYTHONPATH="{site}" exec "{sys.executable}" "$@"\n')
        self.py.chmod(0o755)
        self.git('init', '-q', '-b', 'main')
        self.base = self.commit('base')

    def pin(self, pins):
        (self.repo / '.github/requirements/lint.txt').write_text('# pinned\n' + ''.join(f'{n}=={v}\n' for n, v in pins.items()))

    def git(self, *args, cwd=None):
        return subprocess.run(['git', '-c', 'user.name=t', '-c', 'user.email=t@example.invalid', *args], cwd=cwd or self.repo, env=self.env, check=True,
                              capture_output=True, text=True).stdout.strip()

    def commit(self, msg, cwd=None):
        self.git('add', '-A', cwd=cwd)
        self.git('commit', '-qm', msg, '--allow-empty', cwd=cwd)
        return self.git('rev-parse', 'HEAD', cwd=cwd)

    def push(self, *lines, cwd=None, **env):
        """lines: (local sha, remote sha) pairs, git's ref lines on stdin; none: this checkout's HEAD to a new branch"""
        lines = lines or ((self.git('rev-parse', 'HEAD', cwd=cwd), ZERO),)
        stdin = ''.join(f'refs/heads/x{i} {lsha} refs/heads/x{i} {rsha}\n' for i, (lsha, rsha) in enumerate(lines))
        r = subprocess.run([str(HOOK), 'origin', 'https://example.invalid/r.git'], cwd=cwd or self.repo / 'dm', env={**self.env, **env}, input=stdin,
                           capture_output=True, text=True, timeout=60)
        ran = self.tmp / 'ran'
        got = json.loads(ran.read_text()) if ran.exists() else None
        if ran.exists(): ran.unlink()
        return r, got

    def on(self):
        self.git('config', 'nx18.lintPython', str(self.py))

    def test_hook_is_executable_posix_sh(self):
        self.assertTrue(os.access(HOOK, os.X_OK), '.githooks/pre-push is not executable (git skips it)')
        self.assertEqual(HOOK.read_text().splitlines()[0], '#!/bin/sh')

    def test_unset_skips_and_lets_the_push_go(self):
        r, got = self.push()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('skipped', r.stderr)
        self.assertIn('git config nx18.lintPython', r.stderr)
        self.assertIsNone(got, 'the ratchet ran without nx18.lintPython')

    def test_passing_ratchet_pushes_from_the_repository_root(self):
        self.on()
        r, got = self.push()
        self.assertEqual(r.returncode, 0, r.stderr)
        assert got, 'the ratchet did not run'
        self.assertEqual(got['cwd'], str(self.repo))

    def test_failing_ratchet_stops_the_push(self):
        self.on()
        r, got = self.push(LINT_RC='1')
        self.assertNotEqual(r.returncode, 0)
        assert got, 'the ratchet did not run'
        self.assertEqual(got['cwd'], str(self.repo))
        self.assertIn('git push --no-verify', r.stderr)

    def test_unpinned_tools_stop_the_push_before_the_ratchet(self):
        self.on()
        self.pin({**PINS, 'ruff': '0.17.3'})
        self.commit('ruff raised')
        r, got = self.push()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(got)
        self.assertIn('ruff 0.17.2 (pinned 0.17.3)', r.stderr)
        self.pin({**PINS, 'nx18-test-absent': '1.0'})   # a pinned package the Python has not
        self.commit('absent pinned')
        r, got = self.push()
        self.assertNotEqual(r.returncode, 0)
        self.assertIn('nx18-test-absent missing', r.stderr)

    def test_python_that_does_not_run_stops_the_push(self):
        self.git('config', 'nx18.lintPython', str(self.tmp / 'nope/python3'))
        r, got = self.push()
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNone(got)
        self.assertIn('does not run', r.stderr)

    def test_tilde_in_the_python_path_is_expanded(self):
        self.git('config', 'nx18.lintPython', '~/python3')
        r, got = self.push(HOME=str(self.tmp))
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNotNone(got, 'the ratchet did not run')

    def test_runs_in_the_worktree_pushed_from(self):
        self.on()
        wt = self.tmp / 'wt'
        self.git('worktree', 'add', '-q', '-b', 'side', str(wt))
        r, got = self.push(cwd=wt / 'dm/tools')
        self.assertEqual(r.returncode, 0, r.stderr)
        assert got, 'the ratchet did not run'
        self.assertEqual(got['cwd'], str(wt))

    def test_deletion_is_not_checked(self):
        self.on()
        (self.repo / 'scripts').mkdir()
        (self.repo / 'scripts/wip.py').write_text('import os\n')   # untracked work in progress
        r, got = self.push((ZERO, self.base), LINT_RC='1')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(got, 'the ratchet ran for a deletion')
        self.assertIn('nothing to check', r.stderr)

    def test_nothing_new_in_the_lint_scope_is_not_checked(self):
        self.on()
        (self.repo / 'README.md').write_text('words\n')
        docs = self.commit('docs only')
        r, got = self.push((docs, self.base), LINT_RC='1')   # the remote has base: only a .md file is new
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(got)
        self.git('update-ref', 'refs/remotes/origin/main', docs)
        r, got = self.push((docs, ZERO), LINT_RC='1')   # a new ref (a tag, a branch) of commits a remote-tracking branch has
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIsNone(got)
        (self.repo / 'dm/tools/new.py').write_text('x = 1\n')
        new = self.commit('python')
        r, got = self.push((new, docs), LINT_RC='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIsNotNone(got)

    def test_another_commit_is_checked_in_its_own_files(self):
        self.on()
        self.git('checkout', '-q', '-b', 'side')
        (self.repo / 'dm/tools/side.py').write_text('x = 1\n')
        side = self.commit('side')
        self.git('checkout', '-q', 'main')
        (self.repo / 'dm/tools/wip.py').write_text('import os\n')   # untracked here: not part of what is pushed
        r, got = self.push((side, ZERO))
        self.assertEqual(r.returncode, 0, r.stderr)
        assert got, 'the ratchet did not run'
        self.assertNotEqual(got['cwd'], str(self.repo))
        self.assertIn('dm/tools/side.py', got['py'])
        self.assertNotIn('dm/tools/wip.py', got['py'])
        r, got = self.push((side, ZERO), LINT_RC='1')
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(self.git('rev-parse', '--short', side), r.stderr)
        self.assertEqual(sorted(p.name for p in self.tmp.iterdir()), ['python3', 'repo', 'site'], 'the export was left behind')

    def test_uncommitted_changes_are_not_checked(self):
        self.on()
        (self.repo / 'dm/tools/wip.py').write_text('import os\n')
        r, got = self.push()   # HEAD, with an untracked Python file: HEAD's own files are checked
        self.assertEqual(r.returncode, 0, r.stderr)
        assert got, 'the ratchet did not run'
        self.assertNotEqual(got['cwd'], str(self.repo))
        self.assertEqual(got['py'], ['dm/tools/lint_python.py'])


if __name__ == '__main__':
    unittest.main()
