"""Compaction and the following start use fresh processes and disk-built shaders. Each run drops the GPU capture variables, which run the capture profile (no archive)."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


@unittest.skipUnless(__name__ == '__main__', 'run test_pso_archive.py with the native t_pso_archive path')
class ArchiveRestartTests(unittest.TestCase):
    def test_cold_start_then_next(self):
        with tempfile.TemporaryDirectory(prefix='pso-cold-') as folder:
            env = dict(os.environ, MTL_DEBUG_LAYER='1')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            # nine new bases with a timer flush after each: a file per full period of 4 and one for the rest, which the next start does not compact
            stale, fresh = Path(folder) / '00042-900.mtl4a.tmp', Path(folder) / 'p00043.mtl4a.tmp'
            for phase, files in (('seed', 3), ('next', 3)):
                if phase == 'next':   # writes cut short (a process killed while writing): the start removes one older than ten minutes, not one that may be under way
                    stale.write_bytes(b'x'); fresh.write_bytes(b'x'); os.utime(stale, (0, os.path.getmtime(stale) - 3600))
                result = subprocess.run([executable, '--cold-' + phase, folder],
                                        env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase)
            self.assertFalse(stale.exists())
            self.assertTrue(fresh.exists())

    def test_unusable_file_removed(self):
        with tempfile.TemporaryDirectory(prefix='pso-unusable-') as folder:
            env = dict(os.environ, MTL_DEBUG_LAYER='1')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            def run(phase):
                result = subprocess.run([executable, '--cold-' + phase, folder], env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                return result.stdout + result.stderr
            run('seed')
            # a prebuild file Metal will not open, as every file is after a major OS update: the start removes it with its index and the prebuild's stamp, so the
            # prebuild runs again instead of leaving its bases to the draws; the indexed files still serve every base. A file the start cannot open (an open()
            # error, not a refusal) is left alone (NX 18)
            root = Path(folder)
            first = sorted(root.glob('*.mtl4a'))[0]
            (root / 'p00009.mtl4a').write_bytes(b'not a pipeline archive')
            (root / 'p00009.keys').write_bytes(first.with_suffix('.keys').read_bytes())
            (root / 'prebuilt.tsv').write_text('chain\tx\n')
            empty = root / 'p00011.mtl4a'   # an empty file is no archive: removed as a refused one is (upstream's rule), not kept as unreadable
            empty.write_bytes(b'')
            locked = root / 'p00010.mtl4a'
            locked.write_bytes(b'not a pipeline archive either'); locked.chmod(0)
            try:
                log = run('next')   # every base from the archive
            finally:
                locked.chmod(0o600)
            self.assertIn('p00009.mtl4a not usable', log)
            self.assertIn('p00010.mtl4a not usable (could not be read): its bases are built again', log)
            self.assertFalse((root / 'p00009.mtl4a').exists() or (root / 'p00009.keys').exists() or (root / 'prebuilt.tsv').exists())
            self.assertTrue(locked.exists())
            self.assertIn('p00011.mtl4a not usable (not a pipeline archive): removed, its bases are built again', log)
            self.assertFalse(empty.exists())
            self.assertEqual(len([f for f in root.glob('*.mtl4a') if f != locked]), 3)

    def test_cold_start_cut_short(self):
        with tempfile.TemporaryDirectory(prefix='pso-cold-cut-') as folder:
            env = dict(os.environ, MTL_DEBUG_LAYER='1')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            # ended in its prewarm after 6 new bases: the full period's file alone; the next start takes those 4 and builds the other 5
            for phase, files in (('cut-seed', 1), ('after-cut', 3)):
                result = subprocess.run([executable, '--cold-' + phase, folder],
                                        env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase)

    def test_cold_start_quit(self):
        with tempfile.TemporaryDirectory(prefix='pso-cold-quit-') as folder:
            env = dict(os.environ, MTL_DEBUG_LAYER='1')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            # quit in its prewarm after 6 new bases: the full period's file and one of the 2 after it; the next start takes all 6 and builds the other 3.
            # An earlier run's compaction marker stays
            for phase, files in (('quit-seed', 2), ('after-quit', 3)):
                result = subprocess.run([executable, '--cold-' + phase, folder],
                                        env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase)
                self.assertTrue((Path(folder) / 'compacting').exists(), phase)

    def _end_in_prewarm(self, mode, extra, seed_files, after_files=None):
        with tempfile.TemporaryDirectory(prefix='pso-' + mode + '-') as folder:
            env = dict(os.environ, DM_PSO_MTL4='1', MTL_DEBUG_LAYER='1', **extra)
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            if 'DM_TEST_STUCK_DRAW' not in extra:
                env.pop('DM_TEST_STUCK_DRAW', None)
            for phase, files in (('seed', seed_files), ('after', seed_files if after_files is None else after_files)):
                result = subprocess.run([executable, '--' + mode + '-' + phase, folder],
                                        env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase + '\n' + result.stderr)
                self.assertEqual(list(Path(folder).glob('*.tmp')), [], phase)
                if phase == 'seed' and mode == 'exec':
                    # the next program started after the write: the file was there when it did
                    self.assertEqual((Path(folder) / 'exec.txt').read_text().strip(), '1', result.stdout + result.stderr)

    def test_prewarm_timer_flush_then_killed(self):
        # five new bases in a prewarm, the timer's flush after DM_PSO_ARCH_WARM_FLUSH_MS, then _exit: one file, and the next start compiles none
        self._end_in_prewarm('warmflush', {'DM_PSO_ARCH_WARM_FLUSH_MS': '300'}, 1)

    def test_prepare_step_timer_flush_waits(self):
        # the same in the prepare step (before the first frame): the timer's flush hands nothing over, and the run killed meanwhile left no file
        self._end_in_prewarm('warmprep', {'DM_PSO_ARCH_WARM_FLUSH_MS': '300'}, 0, 1)

    def test_sigterm_in_prewarm(self):
        # SIGTERM in the prewarm: the graceful exit writes the five bases
        self._end_in_prewarm('term', {'DM_PSO_ARCH_WARM_FLUSH_MS': '0'}, 1)

    def test_sigterm_with_a_draw_under_way(self):
        # SIGTERM while a draw holds the graphics layer (its suspend never returns): the five bases are written all the same
        self._end_in_prewarm('term', {'DM_PSO_ARCH_WARM_FLUSH_MS': '0', 'DM_TEST_STUCK_DRAW': '1'}, 1)

    def test_hand_over_with_a_draw_under_way(self):
        # oe::ExecuteProgram's hand-over while a draw holds the graphics layer: the next program starts after the five bases are written
        self._end_in_prewarm('exec', {'DM_PSO_ARCH_WARM_FLUSH_MS': '0', 'DM_TEST_STUCK_DRAW': '1'}, 1)

    def test_write_cut_short_keeps_the_archive(self):
        # a write a killed run left (its .tmp, ten minutes old, its index without the file) and a file that is not an archive: the next start removes the leftovers, skips the bad file and
        # takes every base from the good one
        with tempfile.TemporaryDirectory(prefix='pso-torn-') as folder:
            env = dict(os.environ, DM_PSO_MTL4='1', MTL_DEBUG_LAYER='1', DM_PSO_ARCH_WARM_FLUSH_MS='0')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED', 'DM_TEST_STUCK_DRAW'):
                env.pop(name, None)
            result = subprocess.run([executable, '--term-seed', folder], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            good = list(Path(folder).glob('*.mtl4a'))
            self.assertEqual(len(good), 1)
            data = good[0].read_bytes()
            (Path(folder) / '00090-5.mtl4a.tmp').write_bytes(data[:len(data) // 2])
            # NX 18 removes a .tmp only once it is ten minutes old (a younger one may be another copy's write under way, pso4_init): this one is eleven
            old = Path(folder) / '00090-5.mtl4a.tmp'; t = old.stat().st_mtime - 660; os.utime(old, (t, t))
            (Path(folder) / '00091-5.keys').write_bytes(b'\0' * 64)
            (Path(folder) / '00092-5.mtl4a').write_bytes(data[:len(data) // 3])
            result = subprocess.run([executable, '--term-after', folder], env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertFalse((Path(folder) / '00090-5.mtl4a.tmp').exists())
            self.assertFalse((Path(folder) / '00091-5.keys').exists())

    def test_compaction_with_fresh_bases_and_restart(self):
        for constants in (False, True):
            with self.subTest(constants=constants), tempfile.TemporaryDirectory(prefix='pso-restart-') as folder:
                env = dict(os.environ, MTL_DEBUG_LAYER='1', DM_TEST_ARCHIVE_MIXED='1')
                for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS'):
                    env.pop(name, None)
                if constants:
                    env['DM_TEST_ARCHIVE_CONSTANTS'] = '1'
                for phase, files in (('seed', 9), ('replay', 1), ('verify', 1)):
                    result = subprocess.run([executable, '--compact-' + phase, folder],
                                            env=env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                    self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase)
                    # every file has its index beside it, and a compacted file's index goes with it
                    self.assertEqual(sorted(path.stem for path in Path(folder).glob('*.keys')), sorted(path.stem for path in Path(folder).glob('*.mtl4a')), phase)
                    self.assertEqual((Path(folder) / 'compacting').exists(), phase == 'seed', phase)


    def test_deferred_compaction_quit_then_next(self):
        with tempfile.TemporaryDirectory(prefix='pso-defer-') as folder:
            env = dict(os.environ, MTL_DEBUG_LAYER='1')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            # nine files of one base; a start whose compaction (after the first frame) captured 5 of them when the player quit: the old files stay beside the two new ones;
            # the next start completes it (the 5 from the newer files, the rest again) and removes the old files; then nothing to compact
            old = None
            for phase, files in (('seed', 9), ('quit', 11), ('replay', 3), ('verify', 3)):
                result = subprocess.run([executable, '--defer-' + phase, folder], env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                names = sorted(p.name for p in Path(folder).glob('*.mtl4a'))
                self.assertEqual(len(names), files, phase + ' ' + str(names))
                self.assertEqual(sorted(p.stem for p in Path(folder).glob('*.keys')), sorted(Path(n).stem for n in names), phase)
                if phase == 'seed':
                    old = names
                elif phase == 'quit':
                    self.assertTrue(set(old) <= set(names), names)   # nothing lost: every old file stays until the new files hold its bases
                    self.assertIn('pipeline archive compaction stopped: the process is ending', result.stdout + result.stderr)
                    self.assertFalse((Path(folder) / 'compact_failed.tsv').exists())
                    self.assertFalse((Path(folder) / 'compacting').exists())
                elif phase == 'replay':
                    self.assertFalse(set(old) & set(names), names)
                    self.assertIn('pipeline archive compacted:', result.stdout + result.stderr)

    def test_old_names_compacted_once(self):
        with tempfile.TemporaryDirectory(prefix='pso-oldname-') as folder:
            env = dict(os.environ, MTL_DEBUG_LAYER='1')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            # nine files of one base, renamed as an archive from before the count; one compaction, then none
            for phase, files in (('seed', 9), ('replay', 1), ('verify', 1)):
                if phase == 'replay':
                    for path in Path(folder).glob('*-*.mtl4a'):
                        path.rename(path.with_name(path.name.split('-')[0] + '.mtl4a'))
                    self.assertEqual(len(list(Path(folder).glob('*-*.mtl4a'))), 0)
                result = subprocess.run([executable, '--oldname-' + phase, folder],
                                        env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase)

    def test_tier_compaction_restart(self):
        with tempfile.TemporaryDirectory(prefix='pso-tier-') as folder:
            env = dict(os.environ, MTL_DEBUG_LAYER='1')
            for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED'):
                env.pop(name, None)
            # a full period's file and nine of one base; the nine become a file per period of 4; then nothing to compact
            for phase, files in (('seed', 10), ('replay', 4), ('verify', 4)):
                result = subprocess.run([executable, '--tier-' + phase, folder],
                                        env=env, capture_output=True, text=True, timeout=60)
                self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase)

    def test_stale_chain_files(self):
        for keep in (False, True):
            with self.subTest(keep=keep), tempfile.TemporaryDirectory(prefix='pso-stale-') as folder:
                env = dict(os.environ, MTL_DEBUG_LAYER='1')
                for name in ('DM_GPU_CAPTURE', 'MTL_CAPTURE_ENABLED', 'DM_TEST_ARCHIVE_CONSTANTS', 'DM_TEST_ARCHIVE_MIXED', 'DM_PSO_KEEP_OLD'):
                    env.pop(name, None)
                # six one-base files; then one of another chain, two without a stamp with an index and two without an index: the open and the probe keep 3, DM_PSO_KEEP_OLD=1 all 6
                for phase, files in (('seed', 6), ('open', 6 if keep else 3)):
                    if phase == 'open' and keep:
                        env['DM_PSO_KEEP_OLD'] = '1'
                    result = subprocess.run([executable, '--stale-' + phase, folder],
                                            env=env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(result.returncode, 0, phase + '\n' + result.stdout + result.stderr)
                    self.assertEqual(len(list(Path(folder).glob('*.mtl4a'))), files, phase)
                    self.assertEqual(sorted(p.stem for p in Path(folder).glob('*.keys')),
                                     sorted(p.stem for p in Path(folder).glob('*.mtl4a') if (phase == 'open' and not keep) or p.stem not in ('00004-1', '00005-1')), phase)
                if not keep:
                    self.assertIn('1 files of another shader chain removed without opening them', result.stdout + result.stderr)
                    self.assertIn('4 files without a chain stamp probed: 2 served', result.stdout + result.stderr)


if __name__ == '__main__':
    executable = sys.argv.pop(1)
    unittest.main()
