#!/usr/bin/env python3
# scripts/devlog.py: the long frames the frame step's own holds make (not counted), and memory read as plateaus between the steps an area load makes, the graphics ledger and guest charged among them, from logs written here; the movie lines (AAC channel order, VideoToolbox sessions made again) from the host's own formats
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


def mem(f: int, res: float, gpu: float, tex: int, head: float, ledger: float | None = None, guest: float | None = None) -> str:   # ledger and guest: the memory audit's two fields (None: an older log)
    extra = (f'graphics ledger {ledger:.0f} MB, ' if ledger is not None else '') + (f'guest charged {guest:.0f} MB, ' if ledger is not None and guest is not None else '')   # guest charged only with DM_MEM_GUEST=1
    return (f'[dm] [nvn-mtl] memory up to frame {f}: resident {res:.0f} MB, GPU allocated {gpu:.0f} MB, {extra}deferred-release queue 0, residency set 1, serial objects 1, '
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
        self.assertNotIn('ledger_mb', m); self.assertNotIn('guest_charged_mb', m)   # an older log: neither series

    def test_ledger_and_guest(self):   # the graphics ledger and guest charged after GPU allocated (nvn_mtl.m, the memory audit): read as series of their own, shown and compared; the fields around them as before
        lines = [mem(f, 3800, 4020, 120, 7400, 1477 if f < 3000 else 1900, 1800) for f in range(300, 6001, 300)]
        s = read(lines); m = s['memory']
        self.assertEqual((m['ledger_mb']['min'], m['ledger_mb']['max'], m['guest_charged_mb']['max'], m['gpu_mb']['max'], m['headroom_mb']['min'], m['shared_textures']['max']), (1477, 1900, 1800, 4020, 7400, 120))
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('graphics ledger 1477 → 1900 MB', text); self.assertIn('guest charged 1800 → 1800 MB', text)
        rows = {r[0] for r in devlog.METRICS}
        self.assertTrue({'graphics ledger, most (MB)', 'guest charged, most (MB)'} <= rows)
        self.assertEqual((devlog.dig(s, 'memory.ledger_mb.max'), devlog.dig(s, 'memory.guest_charged_mb.max')), (1900, 1800))

    def test_memory_line_format_matches_the_producer(self):   # the memory line as nvn_mtl.m prints it (its MLOG format and the tail's asprintf format, filled in) is what the pattern reads, both new fields included
        src = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')
        main = re.search(r'MLOG\("(memory up to frame %llu: [^"]*)"', src); tail = re.search(r'asprintf\(&tail, "(deferred-release queue [^"]*)"', src)
        self.assertTrue(main and tail, 'the memory line\'s format strings in nvn_mtl.m')
        assert main and tail
        n = iter(range(1, 1000))
        fill = lambda f: re.sub(r'%(?:llu|lu|u|d)', lambda _: str(100 + next(n)), f)
        gst = re.search(r'snprintf\(gst, sizeof gst, "(guest charged %llu MB, )"', src)
        self.assertTrue(gst, 'the guest charged field\'s format in nvn_mtl.m (DM_MEM_GUEST=1)')
        assert gst
        for with_guest in (True, False):   # DM_MEM_GUEST=1, and the default line without the field
            n = iter(range(1, 1000))
            head = fill(main.group(1)).split('%s')
            g = fill(gst.group(1)) if with_guest else ''
            line = '[dm] [nvn-mtl] ' + head[0] + g + fill(tail.group(1)).replace('%s', '7400 MB')
            x = devlog.RX['memory'].search(line[len('[dm] '):])
            self.assertIsNotNone(x, line)
            assert x
            self.assertEqual([x.group(i) for i in (1, 2, 3, 4)], [str(v) for v in (101, 102, 103, 104)])
            self.assertEqual(x.group(5), str(105) if with_guest else None)
            self.assertEqual(x.group(7), '7400')
            self.assertRegex(line, rf'shared textures {x.group(6)} \(')


class LedgerFields(unittest.TestCase):   # the memory line's graphics ledger and guest charged (after GPU allocated, which counts the guest's pools twice): read, shown first, compared lower-better
    def run_of(self, ledger: float | None, guest: float | None) -> dict:
        return read([mem(f, 2600, 4000, 300, 5500, None if ledger is None else ledger + (f > 3000) * 100, guest) for f in range(300, 6001, 300)])

    def test_read_and_shown_first(self):
        s = self.run_of(1400, 1500); m = s['memory']
        self.assertEqual((m['ledger_mb']['first'], m['ledger_mb']['last'], m['guest_charged_mb']['last'], m['gpu_mb']['last']), (1400, 1500, 1500, 4000))
        self.assertEqual(s['memory']['footprint_mb']['last'], 2600)   # the line's other fields read as before
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('graphics ledger 1400 → 1500 MB', text); self.assertIn('guest charged 1500 → 1500 MB', text)
        self.assertLess(text.index('graphics ledger'), text.index('guest charged')); self.assertLess(text.index('guest charged'), text.index('GPU allocated (counts the guest\'s pools again)'))

    def test_ledger_without_guest(self):   # the default line (no DM_MEM_GUEST): the ledger read, shown and compared; no guest charged series or row
        s = self.run_of(1400, None); m = s['memory']
        self.assertEqual((m['ledger_mb']['first'], m['ledger_mb']['last']), (1400, 1500)); self.assertNotIn('guest_charged_mb', m)
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('graphics ledger 1400 → 1500 MB', text); self.assertNotIn('guest charged', text)
        rows = {r['label'] for r in devlog.compare(s, s)['rows']}
        self.assertIn('graphics ledger, last (MB)', rows); self.assertNotIn('guest charged, last (MB)', rows)

    def test_old_logs_have_no_rows(self):   # a log from before the fields: no entry, no row, and GPU allocated as before
        s = self.run_of(None, None); m = s['memory']
        self.assertNotIn('ledger_mb', m); self.assertNotIn('guest_charged_mb', m); self.assertEqual(m['gpu_mb']['last'], 4000)
        text = '\n'.join(devlog.render(s, 5))
        self.assertNotIn('graphics ledger', text); self.assertNotIn('counts the guest', text); self.assertIn('GPU allocated 4000 → 4000 MB', text)
        rows = {r['label'] for r in devlog.compare(s, s)['rows']}
        self.assertNotIn('graphics ledger, last (MB)', rows); self.assertNotIn('guest charged, last (MB)', rows); self.assertIn('GPU allocated, last (MB)', rows)

    def test_compared_lower_is_better(self):
        a, b = self.run_of(1400, 1500), self.run_of(1000, 1200)
        rows = {r['label']: r for r in devlog.compare(a, b)['rows']}
        self.assertEqual((rows['graphics ledger, last (MB)']['a'], rows['graphics ledger, last (MB)']['b']), (1500, 1100))
        self.assertTrue(rows['graphics ledger, last (MB)']['change'].endswith('better')); self.assertTrue(rows['guest charged, last (MB)']['change'].endswith('better'))
        self.assertTrue(devlog.compare(b, a)['rows'][[r['label'] for r in devlog.compare(b, a)['rows']].index('graphics ledger, most (MB)')]['change'].endswith('worse'))
        labels = [r['label'] for r in devlog.compare(a, b)['rows']]
        self.assertLess(labels.index('graphics ledger, last (MB)'), labels.index('GPU allocated, last (MB)'))   # preferred: listed before GPU allocated
        rows = {r['label']: r for r in devlog.compare(self.run_of(None, None), b)['rows']}   # an old log against a new one: the row, empty on the old side
        self.assertEqual((rows['graphics ledger, last (MB)']['a'], rows['graphics ledger, last (MB)']['b']), (None, 1100))


class AudioLine(unittest.TestCase):   # hle_audio.c's statistics line, before and after it carried the watchdog's passes: the same underruns and callbacks
    def test_watchdog_suffix(self):
        base = '[dm] audio #3 device callbacks 4000: 240–240 frames each, 1.0 blocks queued on average at callback; in these 2000, 2 underruns, 10.0 ms zero-padded'
        for line in (base, base + '; watchdog passes so far (all outputs) 120 on the 50 ms tick, 64 on the healthy one',
                     base + '; watchdog passes so far (all outputs) 120 on the 50 ms tick, 64 on the healthy one (3 of them found the last callback over 50 ms old)'):
            au = read([line])['audio']
            self.assertEqual((au['callbacks'], au['underruns'], au['zero_padded_ms']), (2000, 2, 10.0))



class BundledArchive(unittest.TestCase):   # the pipeline archive bundled with the app: opened, or left out, the crash guard's verdicts among them (nvn_mtl.m, pso_guard_begin)
    G = '[dm] [nvn-mtl] [RED] pipeline archive bundled with the app: '
    ID = 'applegpu_g19p.metallib (12 MB, 0123abcd, app 89ab)'

    def bundled(self, line: str):
        return read([line])['pipelines']['bundled']

    def test_opened(self):
        self.assertEqual(self.bundled(f'[dm] [nvn-mtl] pipeline archive bundled with the app: /a/{self.ID}, 12.0 MB, opened in 3.5 ms'), {'mb': 12.0, 'open_ms': 3.5})

    def test_left_out_by_the_guard(self):   # two early ends in a row, and one with the one-end rule: the start that leaves the archive out, the one an A/B most needs to see
        for line in (f'{self.G}two starts in a row with {self.ID} on this system build (23A100) did not get past their first frames (they crashed, or iOS ended them in the '
                     'foreground): this start leaves the archive out and the device builds the bases itself (Preparing pipelines, once). (crash guard: /d/pso_bundle_guard.tsv).',
                     f'{self.G}a start with {self.ID} on this system build (23A100) did not get past its first frames (it crashed, or iOS ended it in the foreground): this start '
                     'leaves the archive out and the device builds the bases itself (Preparing pipelines, once). (crash guard: /d/pso_bundle_guard.tsv).',
                     f'{self.G}{self.ID} is left out on this system build (23A100): starts with it did not get past their first frames and the start without it did (crash guard: '
                     '/d/pso_bundle_guard.tsv), so the device\'s own archive serves the bases.'):
            self.assertEqual(self.bundled(line), 'left out', line)
        self.assertIn("the app's own archive left out", '\n'.join(devlog.render(read([line]), 5)))

    def test_used_again(self):   # one early end: this start uses it again, so not left out (its open line says the rest)
        line = (f'{self.G}a start with {self.ID} on this system build (23A100) did not get past its first frames (it crashed, or iOS ended it in the foreground): this start uses it '
                'again, watched, since one such start can have another cause; only a second such start in a row leaves it out (crash guard: /d/pso_bundle_guard.tsv)')
        self.assertIsNone(self.bundled(line))

    def test_the_producer_says_it(self):   # the words the pattern reads are in the guard's [RED] lines
        src = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')
        self.assertGreaterEqual(src.count('foreground): this start leaves the archive out and the device builds the bases itself'), 1)
        self.assertGreaterEqual(src.count('"in the foreground): this start leaves the archive out and the device builds the bases itself'), 1)   # PSG_WITH2's line

class MovieLines(unittest.TestCase):   # hle_movie.c's AAC channel order lines and hle_movie_vt_rebuild.h's session line, their formats filled in, read into the movies summary
    def fmt(self, rel: str, start: str) -> str:
        src = (REPO / rel).read_text(errors='replace')
        m = re.search(r'"(' + re.escape(start) + r'(?:[^"\\]|\\.)*)"', src)
        self.assertTrue(m, f'{start} in {rel}')
        assert m
        return m.group(1).replace("\\'", "'")

    def fill(self, f: str, strs: tuple) -> str:
        it = iter(strs)
        return re.sub(r'%(?:#x|zu|d|s)', lambda k: {'%d': '6', '%#x': '0x7c0006', '%zu': '32'}.get(k.group(0)) or next(it), f)

    def test_aac_order_and_session_lines(self):
        aac = "[movie] AAC: %d channels in AudioToolbox's order %s (layout tag %#x), "
        lines = ['[dm] ' + self.fill(self.fmt('dm/host/hle_movie.c', aac + 'handed out'), ('C L R Ls Rs LFE', 'L R C LFE Ls Rs')),
                 '[dm] ' + self.fill(self.fmt('dm/host/hle_movie.c', aac + 'already'), ('L R C LFE Ls Rs',)),
                 '[dm] ' + self.fill(self.fmt('dm/host/hle_movie.c', aac + 'kept'), ('C L R Ls Rs LFE', 'L R C LFE Ls Rs'))]
        vt = self.fmt('dm/host/hle_movie_vt_rebuild.h', '%s: VideoToolbox session made again after')
        lines.append('[dm] [movie] ' + self.fill(vt, ('H.264', 'kVTInvalidSessionErr', 'IDR')))
        mv = read(lines)['movies']
        self.assertEqual([(a['channels'], a['audiotoolbox'], a['console'], a['set']) for a in mv['aac']],
                         [(6, 'C L R Ls Rs LFE', 'L R C LFE Ls Rs', 'reordered'), (6, 'L R C LFE Ls Rs', 'L R C LFE Ls Rs', 'already'),
                          (6, 'C L R Ls Rs LFE', 'L R C LFE Ls Rs', 'kept (DM_AAC_LAYOUT=0)')])
        self.assertEqual((mv['vt_rebuilds'], mv['vt_refed']), (1, 6))


if __name__ == '__main__':
    unittest.main()
