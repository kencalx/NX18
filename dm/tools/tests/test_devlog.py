#!/usr/bin/env python3
# scripts/devlog.py: the long frames the frame step's own holds make (not counted), and memory read as plateaus between the steps an area load makes, from logs written here
import importlib.util, re, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('devlog', REPO / 'scripts/devlog.py')
assert spec is not None and spec.loader is not None
devlog = importlib.util.module_from_spec(spec); spec.loader.exec_module(devlog)

V = 1000 / 60


def lf(f: int, ms: float, *, gpu: float = 15.0, submit: float = 1.0, pso: int = 0, make: float = 0.0, hold: int | None = None) -> str:   # a long-frame line as hle_nvn.c writes it
    return (f'[dm] [longframe] frame {f} ({f / 60:.2f} s) whole frame {ms:.1f} ms, submit+present {submit:.1f} ms, GPU {gpu:.1f} ms; new pipelines {pso} + shader libraries 0, '
            f'{make:.1f} ms in all; texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms; draws with a hybrid pipeline 0' + (f'; hold {hold} × {V:.1f} ms' if hold else ''))


def step(a: int, b: int, present: int, last: bool = False) -> str:
    return (f'[dm] [nvn] frame step: hold {a} → {b} vsyncs at present {present} (3 late frames; cost 1.20, GPU 1.00)'
            + ('; further changes only counted below' if last else ''))


def mem(f: int, res: float, gpu: float, tex: int, head: float) -> str:
    return (f'[dm] [nvn-mtl] memory up to frame {f}: resident {res:.0f} MB, GPU allocated {gpu:.0f} MB, deferred-release queue 0, residency set 1, serial objects 1, '
            f'memory pools 1 (resident 1; peak 1 / tracking table capacity 262144; freed but alive 0, 0 MB), shared textures {tex} (0 of them unreferenced; evicted with pools 0, '
            f'on storage takeover 0 in total), texture re-uploads 0 in total; headroom to the system memory limit {head:.0f} MB')


def read(lines: list[str]) -> dict:   # every long frame in 'top'
    return devlog.read('\n'.join(['[dm] [nvn] present tick 60 Hz, interval mode game (game profile present_interval; present interval set by the game 1; window)', *lines]) + '\n', 50)


class HoldFrames(unittest.TestCase):
    def test_line_format_matches_the_producer(self):   # the format hle_nvn.c prints, with and without the hold, is what the pattern reads
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        main = re.search(r'snprintf\(b, sizeof b, "(frame %llu \(%\.2f s\) whole frame[^"]*)"', src); tail = re.search(r'snprintf\(b \+ n, sizeof b - \(size_t\)n, "([^"]*)"', src)
        self.assertTrue(main and tail, 'the long-frame format strings in hle_nvn.c')
        assert main and tail
        line = main.group(1).replace('%llu', '%d').replace('%u', '%d') % (1234, 20.5, 45.0, 1.0, 15.0, 0, 0, 0.0, 0, 0, 0.0, 0.0, 0)
        m = devlog.RX['longframe'].search('[longframe] ' + line)
        self.assertTrue(m); assert m
        self.assertIsNone(m.group(13))
        m = devlog.RX['longframe'].search('[longframe] ' + line + tail.group(1).replace('%u', '%d') % (2, V))
        self.assertTrue(m); assert m
        self.assertEqual((m.group(1), m.group(13), m.group(14)), ('1234', '2', '16.7'))

    def test_from_the_frame_step_lines(self):   # an older log: the frames after a step up to 2, as long as it asked, are not counted; one before it and one past the hold are
        s = read([lf(60, 33.0), step(1, 2, 111), lf(110, 25.0), *(lf(f, 33.3 + (f % 3 - 1)) for f in range(112, 121)), lf(121, 45.0), step(2, 1, 142)])
        lfs = s['long_frames']
        self.assertEqual((lfs['count'], lfs['held']), (3, 9))
        self.assertEqual(lfs['by_cause'], {'game': 3})
        self.assertEqual(sorted(r['frame'] for r in lfs['top']), [60, 110, 121])
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('long frames  3 (', text); self.assertIn("not counted: 9 frames as long as the frame step's hold of 2 or 3 vsyncs asked", text)

    def test_other_causes_stay(self):   # a frame at the hold that compiled pipelines for most of it is still the pipelines'
        s = read([step(1, 2, 111), lf(112, 33.0, pso=2, make=25.0), lf(113, 33.0, submit=20.0), lf(114, 33.0)])
        self.assertEqual(s['long_frames']['by_cause'], {'pipelines': 1, 'submit': 1}); self.assertEqual(s['long_frames']['held'], 1)

    def test_past_the_last_step_line(self):   # the log names no more changes: runs of three or more frames of 2 or 3 vsyncs are holds, a single one or a pair is not
        s = read([step(1, 2, 111), step(2, 1, 142, last=True), lf(500, 33.4), *(lf(f, 33.3) for f in (900, 901, 903, 904)), *(lf(f, 50.0) for f in (1200, 1201, 1202)),
                  lf(1500, 33.2), lf(1501, 33.4), lf(1800, 66.7), lf(1801, 66.7), lf(1802, 66.7)])
        lfs = s['long_frames']
        self.assertEqual(lfs['held'], 7)
        self.assertEqual(sorted(r['frame'] for r in lfs['top']), [500, 1500, 1501, 1800, 1801, 1802])   # a run of 4 vsyncs is longer than the frame step holds
        self.assertEqual(lfs['count'], 6)

    def test_the_cut_on_a_probe_line(self):   # the host's 40th frame step line can be a probe's: past it, a game's own isolated frames are long, not at the last logged hold of 2
        probe = '[dm] [nvn] frame step: the probe failed at present 300 (CPU 80% on performance cores); further changes only counted below'
        late = [lf(f, ms) for f, ms in ((5000, 33.5), (7000, 36.0), (9000, 38.0))]
        s = read([step(1, 2, 111), step(2, 1, 142), step(1, 2, 250), probe, *late])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (3, 0))
        # before the cut the logged hold still applies: a frame at hold 2 between the last change and the probe line is not counted
        s = read([step(1, 2, 111), step(2, 1, 142), step(1, 2, 250), lf(280, 33.4), probe, *late])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (3, 1))
        # the short run after a probe names no present: the cut is the frame the log was at
        run = '[dm] [nvn] frame step: the run at hold 1 after the probe lasted under 10 s, counted as a failed probe (CPU 80% on performance cores); further changes only counted below'
        s = read([step(1, 2, 111), step(2, 1, 142), step(1, 2, 250), lf(400, 33.4), run, *late])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (3, 1))

    def test_the_marker_matches_the_producer(self):   # every kind of frame step line the host counts toward its 40 carries the marker devlog reads
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        self.assertEqual(src.count('++nlog == 40 ? "' + devlog.FSTEP_CUT + '"'), 3)

    def test_without_step_lines(self):   # no frame step line and no hold (a game without fps_target, or the step off): runs of 33 ms frames are the game's own dips, all counted
        s = read([*(lf(f, 33.6, gpu=9.0, submit=2.0) for f in range(200, 206)), lf(400, 33.3), lf(700, 90.0)])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (8, 0))
        self.assertEqual([x for x in devlog.render(s, 5) if 'not counted' in x], [])

    def test_hold_1_said(self):   # a log that says each line's hold: a run of hold-1 frames of two vsyncs past the last step line is long, a hold-2 frame is not
        s = read([step(1, 2, 111), step(2, 1, 142, last=True), *(lf(f, 33.3, hold=1) for f in range(900, 905)), lf(1200, 33.3, hold=2)])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (5, 1))

    def test_not_at_120_fps(self):   # past the last change of a 120 fps game's step (ticks of 1/120 s) a run of 33 ms frames is no hold
        tick = '[dm] [nvn] frame step: hold 1 → 2 ticks of 1/120 s at present 111 (3 late frames; cost 1.20, GPU 1.00); further changes only counted below'
        s = read([tick, *(lf(f, 33.3) for f in range(500, 505))])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (5, 0))

    def test_the_lines_own_hold(self):   # a newer log says each frame's hold; a frame within 1.25 of it is not counted (the host no longer prints those), one past it is
        s = read([lf(300, 40.0, hold=2), lf(301, 45.0, hold=2), lf(302, 33.4)])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (2, 1))

    def test_unchanged_without_holds(self):   # a log whose long frames are no holds reads as before
        s = read([lf(100, 80.0), lf(200, 26.0, pso=1, make=20.0), lf(300, 90.0, submit=70.0)])
        lfs = s['long_frames']
        self.assertEqual((lfs['count'], lfs['held'], lfs['by_cause']), (3, 0, {'game': 1, 'pipelines': 1, 'submit': 1}))
        text = [x for x in devlog.render(s, 5) if 'not counted' in x]
        self.assertEqual(text, [])

    def test_compare_counts_the_holds(self):
        a = read([step(1, 2, 111), *(lf(f, 33.3) for f in range(112, 120))]); b = read([lf(100, 80.0)])
        rows = {r['label']: r for r in devlog.compare(a, b)['rows']}
        self.assertEqual((rows["frames at the step's hold"]['a'], rows["frames at the step's hold"]['b']), (8, 0))
        self.assertEqual((rows['long frames']['a'], rows['long frames']['b']), (0, 1))


class Plateaus(unittest.TestCase):
    def test_steps(self):   # memory that steps at three area loads and stays flat between them: three plateaus, no drift, where the run's slope is large
        pts = [(t, 700.0 + (t % 3)) for t in range(0, 200, 20)] + [(t, 2600.0 + (t % 5)) for t in range(200, 400, 20)] + [(t, 3800.0 - (t % 4)) for t in range(400, 600, 20)]
        x = devlog.spread(pts)
        assert x is not None
        self.assertEqual([p['median'] for p in x['plateaus']], [701, 2600, 3800])
        self.assertEqual([(p['from_s'], p['to_s']) for p in x['plateaus']], [(0, 180), (200, 380), (400, 580)])
        self.assertGreater(x['per_10min'], 3000); self.assertLess(abs(x['drift_per_10min']), 20)
        t = devlog.spread_text(x)
        self.assertIn('3 plateaus', t); self.assertNotIn(f"{x['per_10min']:+g}", t)
        self.assertEqual(devlog.plateau_text(x, 10), ['  0–180 s 701 MB, 200–380 s 2600 MB, 400–580 s 3800 MB'])

    def test_a_leak_within_plateaus(self):   # each plateau rises 10 MB a minute: the drift is that rise, not the steps
        pts = [(t, 700.0 + 10 * t / 60) for t in range(0, 300, 20)] + [(t, 2600.0 + 10 * t / 60) for t in range(300, 600, 20)]
        x = devlog.spread(pts)
        assert x is not None
        self.assertEqual(len(x['plateaus']), 2); self.assertAlmostEqual(x['drift_per_10min'], 100, delta=1)
        # a faster leak leaves its band within a plateau and cuts it in more pieces, but each piece rises as fast: the drift is still the leak
        x = devlog.spread([(t, 700.0 + 50 * t / 60) for t in range(0, 300, 20)] + [(t, 2600.0 + 50 * t / 60) for t in range(300, 600, 20)])
        assert x is not None
        self.assertGreater(len(x['plateaus']), 2); self.assertAlmostEqual(x['drift_per_10min'], 500, delta=1)

    def test_one_spike_is_no_plateau(self):   # a sample off the plateau with the next one back on it stays in the plateau; at the end, too
        x = devlog.spread([(0, 1000.0), (20, 1010.0), (40, 1600.0), (60, 1005.0), (80, 1000.0), (100, 2000.0)])
        assert x is not None
        self.assertEqual(len(x['plateaus']), 1); self.assertEqual(x['drift_per_10min'], x['per_10min'])

    def test_flat_reads_as_before(self):   # a single plateau: the text is the old one, with the run's slope
        x = devlog.spread([(t, 900.0 + t / 10) for t in range(0, 300, 30)])
        assert x is not None
        self.assertEqual(devlog.spread_text(x), f"900 → 927 MB (least 900, most 927, {x['per_10min']:+g} MB per 10 min)")
        self.assertEqual(devlog.plateau_text(x, 10), [])

    def test_memory_lines(self):   # through the log: the footprint read from both memory and on-screen lines once per moment, the shared textures with the wider band
        lines = [mem(f, 700 if f < 3000 else 2600, 2500 if f < 3000 else 9600, 40 if f < 3000 else 300, 7400 if f < 3000 else 5500) for f in range(300, 6001, 300)]
        s = read(lines)
        m = s['memory']
        self.assertEqual([len(m[k]['plateaus']) for k in ('footprint_mb', 'gpu_mb', 'headroom_mb', 'shared_textures')], [2, 2, 2, 2])
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('footprint 700 → 2600 MB (least 700, most 2600), 2 plateaus', text)


if __name__ == '__main__':
    unittest.main()
