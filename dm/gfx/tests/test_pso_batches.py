"""The pipeline archive's groups of bases run base_jobs at a time, and the merge takes the pieces in the groups' order whatever order they finished in."""
import contextlib
import io
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

TOOLS = Path(__file__).resolve().parents[1] / 'tools'
sys.path.insert(0, str(TOOLS))
import pso_offline


class Batches(unittest.TestCase):
    def run_batches(self, nbases, ncompute, bjobs, jobs=4, fail=None):
        tmp = tempfile.TemporaryDirectory(); self.addCleanup(tmp.cleanup); work = Path(tmp.name)
        lock, running, peak, merged = threading.Lock(), [0], [0], []
        def compile_batch(lib_dir, group, folder, *args, **kwargs):
            with lock: running[0] += 1; peak[0] = max(peak[0], running[0])
            time.sleep(0.05 if group and int(folder.name) % 2 else 0.01)   # odd groups finish last
            with lock: running[0] -= 1
            if fail and folder.name == fail: raise SystemExit('[RED] failed')
            folder.mkdir(parents=True, exist_ok=True); piece = folder / 'piece'; piece.write_text(folder.name)
            return piece, False
        def run(cmd, **kwargs):
            merged.extend(Path(c).parent.name for c in cmd if c.endswith('piece')); Path(cmd[-1]).write_bytes(b'archive')
            return type('R', (), {'returncode': 0})()
        bases = [(f'v{i}', 'main0', f'p{i}', 'main0') for i in range(nbases)]
        computes = [object() for _ in range(ncompute)]
        with patch.object(pso_offline, 'compile_batch', compile_batch), patch.object(pso_offline.subprocess, 'run', run), \
                patch.object(pso_offline.vol_space, 'free_bytes', return_value=1 << 40), contextlib.redirect_stdout(io.StringIO()):
            pso_offline.compile_batches(None, bases, work, work / 'out.partial', 'applegpu_g19p', 'ios', '27.3', 'tv', 10, computes, jobs, compute_size=2, bjobs=bjobs)
        return merged, peak[0]

    def test_pieces_merge_in_group_order(self):
        for bjobs in (1, 3, 8):
            with self.subTest(bjobs=bjobs):
                merged, peak = self.run_batches(55, 5, bjobs)
                self.assertEqual(merged, ['00001', '00002', '00003', '00004', '00005', '00006', 'c00001', 'c00002', 'c00003'])
                self.assertLessEqual(peak, max(4, bjobs + 1))

    def test_one_at_a_time_on_a_small_mac(self):
        merged, peak = self.run_batches(40, 0, 1, jobs=1)
        self.assertEqual(peak, 1); self.assertEqual(merged, ['00001', '00002', '00003', '00004'])

    def test_a_failed_base_group_stops_the_build(self):
        with self.assertRaises(SystemExit): self.run_batches(80, 4, 2, fail='00002')

    def test_base_jobs_follow_cores_and_memory(self):
        self.assertEqual(pso_offline.base_jobs(8, 8 << 30), 1)    # an 8 GB M2: one at a time, as before
        self.assertEqual(pso_offline.base_jobs(10, 16 << 30), 2)
        self.assertEqual(pso_offline.base_jobs(16, 48 << 30), 5)
        self.assertEqual(pso_offline.base_jobs(2, 64 << 30), 1)


if __name__ == '__main__': unittest.main()
