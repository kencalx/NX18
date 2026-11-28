#!/usr/bin/env python3
# scripts/devlog.py: the long frames the frame step's own holds make (not counted), those made under the in-game menu or out of focus (counted apart), and memory read as plateaus between the steps an area load makes, the graphics ledger and guest charged among them, and the power line's GPU busy time, from logs written here; the movie lines (AAC channel order) from the host's own formats
import importlib.util, re, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('devlog', REPO / 'scripts/devlog.py')
assert spec is not None and spec.loader is not None
devlog = importlib.util.module_from_spec(spec); spec.loader.exec_module(devlog)

V = 1000 / 60


def lf(f: int, ms: float, *, gpu: float = 15.0, submit: float = 1.0, pso: int = 0, make: float = 0.0, hold: int | None = None, away: float = 0.0) -> str:   # a long-frame line as hle_nvn.c writes it
    return (f'[dm] [longframe] frame {f} ({f / 60:.2f} s) whole frame {ms:.1f} ms, submit+present {submit:.1f} ms, GPU {gpu:.1f} ms; new pipelines {pso} + shader libraries 0, '
            f'{make:.1f} ms in all; texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms; draws with a hybrid pipeline 0' + (f'; hold {hold} × {V:.1f} ms' if hold else '')
            + (f'; {away:.0f} ms of it in the background' if away else ''))


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
        main = re.search(r'snprintf\(b, sizeof b, "(frame %llu \(%\.2f s\) whole frame[^"]*)"', src); tail = re.search(r'snprintf\(b \+ n, sizeof b - \(size_t\)n, "(; hold [^"]*)"', src)   # the hold's tail (others come before it: the submit scopes, page-ins)
        self.assertTrue(main and tail, 'the long-frame format strings in hle_nvn.c')
        assert main and tail
        line = main.group(1).replace('%llu', '%d').replace('%u', '%d') % (1234, 20.5, 45.0, 1.0, 15.0, 0, 0, 0.0, 0, 0, 0.0, 0.0, 0)
        m = devlog.RX['longframe'].search('[longframe] ' + line)
        self.assertTrue(m); assert m
        self.assertIsNone(m.group(13))
        m = devlog.RX['longframe'].search('[longframe] ' + line + tail.group(1).replace('%u', '%d') % (2, V))
        self.assertTrue(m); assert m
        self.assertEqual((m.group(1), m.group(13), m.group(14)), ('1234', '2', '16.7'))

    def test_replay_split(self):   # the replay's split (nvn_lft.h) names what a long frame spent its submit on besides the uploads, by the producer's names
        names = re.search(r'name\[LFT_N\] = \{([^}]*)\}', (REPO / 'dm/gfx/nvn/nvn_lft.h').read_text())
        self.assertTrue(names); assert names
        self.assertEqual(re.findall(r'"([^"]*)"', names.group(1)), devlog.LF_PART.pattern.split('(')[1].split(')')[0].split('|'))
        line = (lf(116, 473.7, gpu=3.5, submit=415.9).replace('texture uploads 0 first + 0 re-uploads, 0.0 MB / 0.0 ms', 'texture uploads 42 first + 0 re-uploads, 131.3 MB / 82.6 ms')
                + '; replay split: textures made 5, 150.0 ms (2.0 in uploads); CPU deswizzle 2, 40.0 ms (40.0 in uploads); lock waits 3, 200.0 ms; encode-thread waits 1.2 ms; hold 1 × 16.7 ms')
        s = read([line, lf(200, 40.0, submit=30.0)])
        top = {r['frame']: r for r in s['long_frames']['top']}
        self.assertEqual(top[116]['causes'], ['textures made (5, 148 ms)', 'lock waits (3, 200 ms)'])
        self.assertEqual(top[116]['split']['CPU deswizzle'], {'n': 2, 'ms': 40.0, 'in_uploads': 40.0})
        self.assertEqual(top[116]['split']['encode-thread waits']['ms'], 1.2)
        self.assertNotIn('split', top[200]); self.assertEqual(top[200]['causes'], ['submit+present 30 ms'])
        self.assertEqual(s['long_frames']['by_cause'], {'textures': 1, 'submit': 1})

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
        # a failed probe's line with what it measured at hold 1, and the line that ends the probes' hold-off: the cut is the present each names
        failed = ('[dm] [nvn] frame step: the probe failed at present 300 (CPU 56% on performance cores; cost 1.45 at hold 1, 2 in a row over 1.15: '
                  'no probe for 32 s while hold 2 costs over 1.11); further changes only counted below')
        allowed = '[dm] [nvn] frame step: probes back to hold 1 allowed again at present 300 (cost 0.80 at hold 2, about 0.83 at hold 1); further changes only counted below'
        for cut in (failed, allowed):
            s = read([step(1, 2, 111), step(2, 1, 142), step(1, 2, 250), lf(280, 33.4), cut, *late])
            self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (3, 1))

    def test_the_marker_matches_the_producer(self):   # every kind of frame step line the host counts toward its 40 carries the marker devlog reads (X1.0's, DM_FIELD_LOG=0)
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        self.assertEqual(src.count('++*nl == 40 ? cutm'), 6)   # a change of hold, a probe's end, a short run after one, a short CPU burst paid back at hold 1 (fps_hold_backoff), a frame across a stay (fps_resume), probes allowed again
        self.assertIn('"' + devlog.FSTEP_CUT + '"', src)
        self.assertIn('"; further changes in this window only counted in its game time line"', src)   # the field log's marker, per window of 1800 presents

    def test_window_marker_is_no_cut(self):   # the field log stops a window's change lines at 40 and starts again in the next: its marker does not end the change lines, and its long frames say their hold
        win = '[dm] [nvn] frame step: hold 2 → 1 vsyncs at present 300 (probe; cost 0.80, GPU 0.80); further changes in this window only counted in its game time line'
        s = read([step(1, 2, 111), win, lf(500, 33.4, hold=1), lf(900, 33.3, hold=2)])
        self.assertEqual((s['long_frames']['count'], s['long_frames']['held']), (1, 1))

    def test_background_frame(self):   # a frame whose line says it spanned a stay in the background is not a long frame: named apart, not in the count, the causes or the top
        line = lf(3998, 40454.8, gpu=26.2, submit=6.5, hold=1, away=39300)
        m = devlog.RX['longframe'].search(line[5:]); self.assertTrue(m); assert m
        self.assertEqual((m.group(13), m.group(15)), ('1', '39300'))
        s = read([lf(3000, 45.0, hold=1), line, lf(3999, 93.2, submit=75.8, hold=1)])
        lfs = s['long_frames']
        self.assertEqual((lfs['count'], lfs['held']), (2, 0))
        self.assertEqual([r['frame'] for r in lfs['top']], [3999, 3000])
        self.assertEqual([(r['frame'], r['away_ms']) for r in lfs['away']], [(3998, 39300.0)])
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('not counted: ', text); self.assertIn('frame 3998: 40454.8 ms across a stay in the background (39.3 s of it away)', text)
        self.assertNotIn('background 1', text)
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        self.assertIn('"; %.0f ms of it in the background"', src)   # the host's format

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


def timing(f: int, note: str = '') -> str:   # a timing window line as tsummary writes it; note: front_ui_note's tail, without its leading ";" (the items end with one)
    return (f'[dm] [nvn] timing up to frame {f}: frame time p50 16.67 / p95 17.20 / max 40.00 ms (300 frames); GPU p50 7.00 / p95 9.00 / max 50.00 ms (300 frames);'
            + (f' {note}' if note else ''))


def onscreen(f: int, dropped: int, note: str = '') -> str:   # an on-screen window line; note: front_ui_note's tail, as written
    return f'[dm] [nvn] on-screen up to frame {f}: 300 frames, dropped {dropped} (discarded 0), p99 {16.7 + dropped:.2f} ms; footprint 2000 MiB; brightness 0.50; thermal 0{note}'


def ui_note(menu: int, away: int) -> str: return f'; in-game menu open {menu} frames, not in focus {away} frames'


class FrontEnd(unittest.TestCase):   # frames made while the in-game menu (or a Mac menu) was over the game, or out of focus (hle_nvn.c front_ui): counted apart from the game's
    def test_formats_match_the_producer(self):   # the tags and the window note hle_nvn.c writes are what devlog reads; the long-frame line still reads with a hold and a tag
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        tag = re.search(r'static const char \*front_ui_tag\(unsigned ui\) \{ return ([^;]*);', src); note = re.search(r'snprintf\(b, cap, "(; in-game menu open %u frames, not in focus %u frames)"', src)
        self.assertTrue(tag and note, 'front_ui_tag and front_ui_note in hle_nvn.c')
        assert tag and note
        tags = [t for t in re.findall(r'"([^"]*)"', tag.group(1)) if t]
        self.assertEqual(tags, [' (in-game menu open, not in focus)', ' (in-game menu open)', ' (not in focus)'])
        base = lf(1234, 45.0, hold=1)
        for t in tags:
            m = devlog.RX['longframe'].search(base[len('[dm] '):] + t)
            self.assertTrue(m); assert m
            self.assertEqual((m.group(1), m.group(13)), ('1234', '1'))
            u = devlog.LF_UI.search(m.string)
            self.assertTrue(u); assert u
            self.assertEqual(' (' + u.group(1) + ')', t)
        self.assertIsNone(devlog.LF_UI.search(base))
        w = devlog.WIN_UI.search(note.group(1) % (42, 7)); self.assertTrue(w); assert w
        self.assertEqual((w.group(1), w.group(2)), ('42', '7'))
        self.assertIn('LOG("[nvn] timing up to frame %llu:%s%s", frame, line, uin + (*uin ? 1 : 0));', src)   # the note after the items' last ";"
        self.assertIn('brightness %.2f; thermal %d%s"', src)   # and at the end of the on-screen line
        for line, kind in ((timing(600, ui_note(42, 7)[2:]), 'timing'), (onscreen(600, 3, ui_note(42, 7)), 'onscreen')):
            m = devlog.RX[kind].search(line[len('[dm] '):])
            self.assertTrue(m, line); assert m
            self.assertEqual(m.group(1), '600')

    def test_long_frames_apart(self):   # a tagged long frame is not the game's: not in the count, the causes or the longest, but counted apart by its tag
        s = read([lf(100, 80.0), lf(200, 60.0, gpu=50.0) + ' (in-game menu open)', lf(201, 45.0, gpu=40.0) + ' (in-game menu open)', lf(300, 50.0, hold=1) + ' (not in focus)',
                  lf(400, 33.0, hold=2) + ' (in-game menu open, not in focus)'])
        lfs = s['long_frames']
        self.assertEqual((lfs['count'], lfs['held'], lfs['front_end']), (1, 1, 3))   # the frame at its hold of 2 is the hold's, tagged or not
        self.assertEqual(lfs['front_end_by'], {'in-game menu open': 2, 'not in focus': 1})
        self.assertEqual([r['frame'] for r in lfs['top']], [100]); self.assertEqual(lfs['by_cause'], {'game': 1})
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('long frames  1 (', text)
        self.assertIn('not counted: 3 frames made with the in-game menu open or out of focus (in-game menu open 2; not in focus 1)', text)   # "; ": a tag has a comma of its own
        both = read([lf(200, 60.0) + ' (in-game menu open, not in focus)', lf(201, 45.0) + ' (in-game menu open)'])
        self.assertIn('(in-game menu open, not in focus 1; in-game menu open 1)', '\n'.join(devlog.render(both, 5)))
        rows = {r['label']: r for r in devlog.compare(s, read([lf(100, 80.0), lf(200, 60.0), lf(201, 45.0), lf(300, 50.0)]))['rows']}
        self.assertEqual((rows['long frames under the menu / out of focus']['a'], rows['long frames under the menu / out of focus']['b']), (3, 0))
        # a log from before the tags counts every long frame as the game's: the row with the tagged ones in compares like for like (4 and 4 for the same play)
        self.assertEqual((rows['long frames']['a'], rows['long frames']['b']), (1, 4))
        self.assertEqual((rows['long frames, menu / focus ones too']['a'], rows['long frames, menu / focus ones too']['b']), (4, 4))

    def test_windows_and_drops(self):   # the windows' counts, and the dropped frames given without the windows that had such frames
        s = read([timing(300), onscreen(300, 1), timing(600, ui_note(120, 0)[2:]), onscreen(600, 30, ui_note(118, 0)), timing(900, ui_note(0, 40)[2:]), onscreen(900, 9, ui_note(0, 42)),
                  timing(1200), onscreen(1200, 2)])
        f = s['frames']
        self.assertEqual((f['dropped'], f['menu_frames'], f['unfocused_frames'], f['front_end_windows'], f['dropped_front_end']), (42, 120, 40, 2, 39))
        self.assertEqual((f['dropped_pct'], f['dropped_clean_pct']), (3.5, 0.5))
        self.assertEqual([(w['frame'], w['front_end']) for w in f['worst']], [(600, True), (900, True), (1200, False), (300, False)])
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('120 frames made with the in-game menu open, 40 out of focus: 39 of the dropped frames are in the 2 windows that had any; 0.5% dropped without those windows', text)
        self.assertIn('30 dropped (p99 46.7 ms, in-game menu or out of focus)', text)

    def test_background_stay_with_a_tag(self):   # X1.0's background note comes before the tag (hle_nvn.c): such a frame is named as a stay in the background, not counted apart as well
        line = lf(3998, 40454.8, gpu=26.2, submit=6.5, hold=1, away=39300) + ' (not in focus)'
        m = devlog.RX['longframe'].search(line[len('[dm] '):]); self.assertTrue(m); assert m
        self.assertEqual(m.group(15), '39300')
        s = read([lf(3000, 45.0, hold=1), line, lf(4100, 60.0, gpu=50.0, hold=1) + ' (not in focus)'])
        lfs = s['long_frames']
        self.assertEqual((lfs['count'], lfs['front_end'], lfs['front_end_by']), (1, 1, {'not in focus': 1}))
        self.assertEqual([r['frame'] for r in lfs['away']], [3998]); self.assertEqual([r['frame'] for r in lfs['top']], [3000])
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        self.assertLess(src.index('"; %.0f ms of it in the background"'), src.index('front_ui_tag(r->ui | fui)'))   # the background note first, the tag last

    def test_frame_rate_controller(self):   # the game's own interval changes, and the host's probes of its controller (hle_fctl.c's formats), counted from its event lines
        src = (REPO / 'dm/host/hle_fctl.c').read_text() + (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text()
        for text in ('frame-rate controller: probe back to interval 1 at frame', 'frame-rate controller: interval %d → 1 at frame %llu by the probe', 'frame-rate controller: interval 1 held',
                     'frame-rate controller: the probe failed', 'frame-rate controller: no return within', 'frame-rate controller up to frame %llu: probes %llu (%llu on a light scene), back at interval 1 %llu, held 8 s %llu, failed %llu, dropped %llu',
                     'the game sets present interval %d → %d (from %s+%#llx%s)', '", change %llu"',
                     # the probes' numbers and the time at each interval (X2.0): each probe's line, the summary's tail, the game's own rule's summary
                     'frame-rate controller: probe of frame %llu %s (frame %llu): %d frames%s%s; late %d, %.0f ms over%s', '"; grace %d: %.1f ms mean, %.1f max"', '"; after it %d: %.1f ms mean"',
                     '[FCTL_EV_HELD] = "held 8 s", [FCTL_EV_FAILED] = "failed", [FCTL_EV_ABORTED] = "dropped", [FCTL_EV_UP] = "cut short"', '"time at interval 1 %.1f s, 2 %.1f s, 3+ %.1f s"',
                     'probes wait %.0f s; %s; failed probes: %llu late frames, %.0f ms over', 'frame-rate controller up to frame %llu (DM_FPS_CTL=%s): %s', 'hold ? "hold30" : "game"'):
            self.assertIn(text, src)
        itv = lambda a, b: f'[dm] [nvn] the game sets present interval {a} → {b} (from main+0x204c20)'
        s = read([itv(1, 2), '[dm] [nvn] frame-rate controller: probe back to interval 1 at frame 100: interval 2 for 1.0 s, measure 21.6 ms a frame',
                  '[dm] [nvn] frame-rate controller: interval 2 → 1 at frame 107 by the probe; the next 30 frames are judged at most 18.3 ms', itv(2, 1),
                  '[dm] [nvn] frame-rate controller: interval 1 held 8 s after the probe (frame 600): failures forgotten', itv(1, 2),
                  '[dm] [nvn] frame-rate controller: probe back to interval 1 at frame 700: a light scene, 6 frames in a row under 16.7 ms at interval 2', itv(2, 1),
                  '[dm] [nvn] frame-rate controller: interval 2 → 1 at frame 707 by the probe; the next 30 frames', itv(1, 2),
                  '[dm] [nvn] frame-rate controller: the probe failed: the game stepped up to interval 2 0.7 s after it came back'])
        fr = s['frame_rate']
        self.assertEqual((fr['game_changes'], fr['up'], fr['to_1'], fr['from']), (5, 3, 2, ['main+0x204c20']))
        self.assertEqual((fr['probes'], fr['down'], fr['held'], fr['failed'], fr['dropped']), (2, 2, 1, 1, 0))
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn("the game set its present interval 5 times (3 up, 2 back to 1; from main+0x204c20)", text)
        self.assertIn("the host's probes of the game's controller 2: back at interval 1 2, held 8 s 1, failed 1, dropped 0", text)
        # past the 60th event line the summary lines carry the counts
        s = read(['[dm] [nvn] frame-rate controller up to frame 3600: probes 7 (1 on a light scene), back at interval 1 7, held 8 s 2, failed 5, dropped 0; frames whose return the host held 10',
                  '[dm] [nvn] frame-rate controller up to frame 7200: probes 3 (0 on a light scene), back at interval 1 2, held 8 s 0, failed 2, dropped 1; frames whose return the host held 4'])
        self.assertEqual({k: s['frame_rate'][k] for k in ('probes', 'down', 'held', 'failed', 'dropped')}, {'probes': 10, 'down': 9, 'held': 2, 'failed': 7, 'dropped': 1})
        self.assertIsNone(s['frame_rate']['at1_pct'])   # older summary lines: no time
        # past the 8th change the host writes only the powers of two, with their count (upstream 5cf87e305): the count is the total, the caller stays one
        s = read([itv(1, 2), itv(2, 1), '[dm] [nvn] the game sets present interval 1 → 2 (from main+0x204c20, change 16)', '[dm] [nvn] the game sets present interval 1 → 2 (from main+0x204c20, change 32)'])
        self.assertEqual((s['frame_rate']['game_changes'], s['frame_rate']['from']), (32, ['main+0x204c20']))

    def test_frame_rate_failed_cost_from_an_older_build(self):   # a log from before the probes' numbers (X2.0) has no failed probes' cost: none, not 0, also against a newer log
        ctl = '[dm] [nvn] frame-rate controller'
        tail = 'frames whose return the host held 10, grace frames kept at interval 1 3; interval 2 now, probes wait 2 s'
        old = read([f'{ctl}: probe back to interval 1 at frame 100: interval 2 for 1.0 s, measure 21.6 ms a frame', f'{ctl}: interval 2 → 1 at frame 107 by the probe; the next 30 frames',
                    f'{ctl}: the probe failed: the game stepped up to interval 2 0.6 s after it came back (frame 140, measure 27.0 ms)',
                    f'{ctl} up to frame 3600: probes 7 (1 on a light scene), back at interval 1 7, held 8 s 2, failed 5, dropped 0; {tail}'])
        fr = old['frame_rate']
        self.assertEqual((fr['failed'], fr['failed_late'], fr['failed_over_ms']), (5, None, None))
        self.assertNotIn('failed probes cost', '\n'.join(devlog.render(old, 5)))
        new = read([f'{ctl}: probe of frame 100 failed (frame 140): 40 frames; grace 30: 27.9 ms mean, 33.3 max; after it 3: 26.7 ms mean; late 32, 533 ms over'])
        rows = {r['label']: r for r in devlog.compare(old, new)['rows']}
        self.assertEqual((rows['failed probes: late frames']['a'], rows['failed probes: late frames']['b'], rows['failed probes: ms over']['a']), (None, 32, None))
        # a newer build's summary line says 0 when no probe failed
        held = read([f'{ctl} up to frame 3600: probes 1 (0 on a light scene), back at interval 1 1, held 8 s 1, failed 0, dropped 0; {tail}; time at interval 1 58.0 s, 2 2.0 s, 3+ 0.5 s; '
                     'failed probes: 0 late frames, 0 ms over'])['frame_rate']
        self.assertEqual((held['failed_late'], held['failed_over_ms']), (0, 0))

    def test_frame_rate_time_and_probe_numbers(self):   # X2.0's lines: the time at each interval (both rules: the A/B), what failed probes cost, each probe's numbers
        ctl = '[dm] [nvn] frame-rate controller'
        host = read([f'{ctl}: probe back to interval 1 at frame 100: a light scene, 6 frames in a row under 16.7 ms at interval 2 (the controller\'s own return is at 20.0 ms); the run 5.0 ms mean, '
                     '5.0 max, the scene before it 33.3 ms',
                     f'{ctl}: probe of frame 368 held 8 s (frame 845): 478 frames; grace 30: 19.1 ms mean, 25.0 max; after it 441: 17.8 ms mean; late 9, 150 ms over; GPU probe 3.20x → 2.41x',
                     f'{ctl}: probe of frame 1072 failed (frame 1112): 40 frames; grace 30: 27.9 ms mean, 33.3 max; after it 3: 26.7 ms mean; late 32, 533 ms over; GPU probe 3.20x → no newer',
                     f'{ctl}: probe of frame 1200 dropped (frame 1231): 31 frames; late 0, 0 ms over',
                     f'{ctl} up to frame 3634: probes 7 (1 on a light scene), back at interval 1 7, held 8 s 2, failed 5, dropped 0; frames whose return the host held 5, grace frames kept '
                     'at interval 1 182; interval 1 now, probes wait 1 s; time at interval 1 40.0 s, 2 46.0 s, 3+ 0.0 s; failed probes: 160 late frames, 2667 ms over',
                     f'{ctl} up to frame 7234: probes 1 (0 on a light scene), back at interval 1 1, held 8 s 1, failed 0, dropped 0; frames whose return the host held 0, grace frames kept '
                     'at interval 1 3; interval 1 now, probes wait 1 s; time at interval 1 58.0 s, 2 2.0 s, 3+ 0.5 s; failed probes: 0 late frames, 0 ms over'])
        fr = host['frame_rate']
        self.assertEqual((fr['at1_s'], fr['at2_s'], fr['at3_s'], fr['at1_pct'], fr['failed_late'], fr['failed_over_ms']), (98.0, 48.0, 0.5, 66.9, 160, 2667))
        self.assertEqual(fr['ends'], {'held 8 s': {'n': 1, 'grace_mean_ms': 19.1, 'grace_max_ms': 25.0, 'after_mean_ms': 17.8, 'frames': 478.0},
                                      'failed': {'n': 1, 'grace_mean_ms': 27.9, 'grace_max_ms': 33.3, 'after_mean_ms': 26.7, 'frames': 40.0},
                                      'dropped': {'n': 1, 'grace_mean_ms': None, 'grace_max_ms': None, 'after_mean_ms': None, 'frames': 31.0}})
        text = '\n'.join(devlog.render(host, 5))
        self.assertIn('time at interval 1 (60 fps) 98 s, 2 (30 fps) 48 s, 3 or more 0 s: 66.9% at 60', text)
        self.assertIn('failed probes cost 160 late frames, 2667 ms over their vsync', text)
        self.assertIn('probes that held 8 s 1: 478 frames, grace 19.1 ms mean, 25 max, after it 17.8 ms; failed 1: 40 frames, grace 27.9 ms mean, 33.3 max, after it 26.7 ms; dropped 1: 31 frames (medians)', text)
        # before the first summary line the probes' own lines give the failed probes' cost
        one = read([f'{ctl}: probe of frame 1072 failed (frame 1112): 40 frames; grace 30: 27.9 ms mean, 33.3 max; late 32, 533 ms over'])['frame_rate']
        self.assertEqual({k: one[k] for k in ('failed_late', 'failed_over_ms', 'at1_pct')}, {'failed_late': 32, 'failed_over_ms': 533, 'at1_pct': None})
        # DM_FPS_CTL=game: the time only, and the A/B rows against the host's rule
        game = read([f'{ctl}: DM_FPS_CTL=game, the game\'s own measure (its rule alone decides 30 or 60; the summary lines still give the time at each interval)',
                     f'{ctl} up to frame 3600 (DM_FPS_CTL=game): time at interval 1 41.7 s, 2 36.7 s, 3+ 0.0 s', f'{ctl} up to frame 7200 (DM_FPS_CTL=game): time at interval 1 20.0 s, 2 49.3 s, 3+ 1.0 s'])
        fg = game['frame_rate']
        self.assertEqual((fg['at1_s'], fg['at2_s'], fg['at3_s'], fg['at1_pct'], fg['failed_late'], fg['probes']), (61.7, 86.0, 1.0, 41.5, None, 0))
        self.assertIn('time at interval 1 (60 fps) 62 s, 2 (30 fps) 86 s, 3 or more 1 s: 41.5% at 60', '\n'.join(devlog.render(game, 5)))
        rows = {r['label']: r for r in devlog.compare(game, host)['rows']}
        self.assertEqual((rows['time at interval 1 (%)']['a'], rows['time at interval 1 (%)']['b']), (41.5, 66.9))
        self.assertTrue(rows['time at interval 1 (%)']['change'].endswith('better'))
        self.assertEqual((rows['failed probes: late frames']['a'], rows['failed probes: late frames']['b']), (None, 160))
        # DM_FPS_CTL=hold30 (Battery Saver; hle_fctl.c fctl_summary names the mode in the same line): its time is read as the game's own rule's
        hold = read([f'{ctl} up to frame 3600 (DM_FPS_CTL=hold30): time at interval 1 0.0 s, 2 60.0 s, 3+ 0.0 s'])['frame_rate']
        self.assertEqual((hold['at1_s'], hold['at2_s'], hold['at1_pct']), (0.0, 60.0, 0.0))

    def test_menu_events(self):   # the front end's open and close lines are events, on the Mac with the menu bar named
        s = read(['[dm] front end: in-game menu open', '[dm] front end: in-game menu closed after 2.4 s', '[dm] front end: in-game menu open (menu bar)',
                  '[dm] front end: in-game menu closed (menu bar) after 0.8 s'])
        self.assertEqual([e['what'] for e in s['events']['list']], ['in-game menu open', 'in-game menu closed', 'in-game menu open (menu bar)', 'in-game menu closed (menu bar)'])
        self.assertEqual(s['events']['menu_long'], [])

    def test_rt_pressure_events(self):   # nvn_mtl.m's DM_NVN_RT_DEAD_PRESSURE lines as it prints them (tu_low_now's spell start, tu_press_line's release; formats filled in) are memory events beside the warning
        src = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')
        low = re.search(r'MLOG\("(render targets drawn over \(DM_NVN_RT_DEAD_PRESSURE\): headroom to the system memory limit %llu MB, under [^"]*)"', src)
        rel = re.search(r'MLOG\("(render targets drawn over and unused for %\.1f s, released at %s \(DM_NVN_RT_DEAD_PRESSURE\)[^"]*)"\s*"([^"]*)"', src)
        self.assertTrue(low and rel, "the pressure lines' formats in nvn_mtl.m")
        assert low and rel
        def fill(f: str, strs: list[str], nums: list[str]) -> str:
            si, ni = iter(strs), iter(nums)
            return re.sub(r'%(?:\.1f|llu|lu|u|d|s)', lambda m: next(si) if m.group(0) == '%s' else next(ni), f)
        lines = ['[dm] [nvn-mtl] ' + fill(low.group(1), [], ['1900', '2048', '144760', '0.3', '4']),
                 '[dm] front end: iOS memory warning (3091 s after launch): footprint 6611 MiB, 1580 MiB left (critical)',
                 '[dm] [nvn-mtl] ' + fill(rel.group(1) + rel.group(2), ['a memory warning', '1580 → 2037 MB', 'es'], ['0.3', '237', '457', '45', '3', '12.0', '6611', '6150', '144830', '2']),
                 '[dm] [nvn-mtl] ' + fill(rel.group(1) + rel.group(2), ['low memory headroom', 'none', ''], ['0.3', '4', '1', '0', '0', '0.0', '340', '339', '1018', '1'])]
        self.assertEqual([e['what'] for e in read(lines)['events']['list']],
                         ['headroom under 2048 MB (1900 MB): render targets drawn over released sooner', 'memory warning, 1580 MiB left',
                          'render targets released at a memory warning: 237, 469 MB (headroom 1580 → 2037 MB)', 'render targets released at low memory headroom: 4, 1 MB'])

    def test_heat_and_low_power_holds(self):   # hle_nvn.c thermal_capped and nvn_engine_hold_tick: the hold, the engine limit's two changes, the in-game menu's switch and the end, in that order
        s = read(['[dm] [nvn] Low Power Mode: the game holds 30 fps until it has been off for 30 s (the Low Power Mode at 30 fps setting, DM_LOW_POWER_CAP)',
                  '[dm] [nvn] engine frame limit 60 → 30 fps at present 120 (Low Power Mode)', '[dm] [nvn] Low Power Mode at 30 fps off (in-game menu)',
                  '[dm] [nvn] Low Power Mode at 30 fps turned off: back to the frame rate cap', '[dm] [nvn] engine frame limit 30 → 60 fps at present 300 (the cause has ended)',
                  '[dm] [nvn] thermal state 2: the frame step holds 30 fps until the device is fair again for 30 s (DM_THERMAL_CAP=0 turns this off)'])   # a log from before X2.0
        self.assertEqual([e['what'] for e in s['timeline']],
                         ['the game held at 30 fps', 'the engine frame limit held at 30 fps', 'Low Power Mode at 30 fps turned off',
                          'the chosen frame rate again', 'the engine frame limit at 60 again', 'the frame step held at 30 fps (thermal state 2, calm wait 30 s)'])

    def test_present_cap_hold(self):   # nvn_engine_hold_tick for a display-mode cap without a limiter (Red Dead Redemption): the present cap alone
        s = read(['[dm] [nvn] present cap 60 fps (game profile fps_target) applied by the present interval alone: display mode, and this main has no engine frame limit the host writes',
                  '[dm] [nvn] thermal state 2: the game holds 30 fps until the device is fair again for 30 s (DM_THERMAL_CAP=0 turns this off)',
                  '[dm] [nvn] present cap 60 → 30 fps at present 120 (thermal state serious)', '[dm] [nvn] thermal state 1 for 30 s: back to the frame rate cap',
                  '[dm] [nvn] present cap 30 → 60 fps at present 2000 (the cause has ended)'])
        self.assertEqual([e['what'] for e in s['timeline']],
                         ['the game held at 30 fps (thermal state 2, calm wait 30 s)', 'the present cap held at 30 fps', 'the chosen frame rate again (thermal state 1 for 30 s)',
                          'the present cap at 60 again'])

    def test_holds_where_nothing_is_paced(self):   # hle_nvn.c heat_sample: a game the host does not pace logs its heat and Low Power Mode holds as [heat] lines, no cap event
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        fmts = re.findall(r'LOG\("(\[heat\] [^"]*(?:nothing goes to 30 fps|nothing was held in this game)[^"]*)"', src)
        self.assertEqual(len(fmts), 5, fmts)   # the heat hold on and over; Low Power Mode on, over after its calm, and its setting turned off
        lines = ['[dm] ' + f.replace('%d', '2').replace('%llu', '30').replace('%s', 'x') for f in fmts]
        s = read([onscreen(300, 0)] + lines + [onscreen(600, 0)])
        self.assertEqual(s['timeline'], [])
        self.assertEqual(s['heat_holds']['count'], 0)

    def test_heat_ladder_rungs(self):   # hle_nvn.c heat_sample (nvn_heat.h): the ladder's rung lines and the forced state on the timeline, counted, and the formats the host writes match
        s = read(['[dm] [heat] DM_HEAT_FORCE: thermal state 1 at 60 s (the device reads 0)',
                  '[dm] [heat] rung 0 → 1 (resolution 85%): thermal 1 for 10 s, 60 not holding (3%, GPU-bound), present 4000; scale 0.85, cap 60, probe 1.10, restore wait 60 s, re-entries 0, flaps 0',
                  '[dm] [heat] rung 1 → 2 (resolution 70%): thermal 1 for 50 s, 60 not holding (14%, GPU-bound), present 6400; scale 0.70, cap 60, probe 1.60, restore wait 60 s, re-entries 0, flaps 0',
                  '[dm] [heat] rung 2 → 1 (resolution 70% back): thermal 0 for 60 s (wait 60 s, re-entries 0, flaps 0)'])
        self.assertEqual([e['what'] for e in s['timeline']],
                         ['DM_HEAT_FORCE: thermal state 1', 'heat ladder: resolution 85% (rung 0 → 1)', 'heat ladder: resolution 70% (rung 1 → 2)', 'heat ladder: resolution 70% back (rung 2 → 1)'])
        self.assertEqual(s['heat_ladder'], {'changes': 3, 'deepest': 2})
        self.assertIn('heat ladder: 3 rung changes, at most 2 rungs on', '\n'.join(devlog.render(s, 5)))
        cool = read([onscreen(300, 0)])
        self.assertEqual(cool['heat_ladder'], {'changes': 0, 'deepest': 0})
        self.assertNotIn('heat ladder', '\n'.join(devlog.render(cool, 5)))
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        fmts = re.findall(r'LOG\("(\[heat\] rung %d → %d \(%s[^"]*)"', src)
        self.assertEqual(len(fmts), 2, fmts)   # a rung on, a rung back
        for f in fmts:
            line = f.replace('%d', '1').replace('%llu', '60').replace('%.0f', '5').replace('%.2f', '0.85').replace('%u', '0').replace('%s', 'x')
            self.assertTrue(devlog.RX['heat_rung'].search(line), f)
        force = re.search(r'LOG\("(\[heat\] DM_HEAT_FORCE: thermal state %s at %.0f s[^"]*)"', src); assert force
        self.assertTrue(devlog.RX['heat_force'].search(force.group(1).replace('%s', '2').replace('%.0f', '60').replace('%d', '0')))

    def test_render_scale_and_clock_rescue(self):   # hle_nvn.c scale_set and clock_rescue_tick: each render scale change and the rescue's start and end on the timeline, the host's formats matched
        s = read(['[dm] [heat] render scale 0.85 = player 1.00 × heat 0.85 × clock rescue 1.00 (heat ladder: resolution 85%): state +0x14 0.850',
                  "[dm] [nvn] GPU clock rescue #1 at frame 19500: 39.3 fps against 60 with the GPU probe at 2.89x its fastest: 3D views at 0.64 of the game's size for 3 s (next no sooner than 10 s after)",
                  '[dm] [heat] render scale 0.64 = player 1.00 × heat 0.85 × clock rescue 0.75 (the GPU clock rescue): state +0x14 0.637',
                  "[dm] [nvn] GPU clock rescue #1 over at frame 19680: 60.0 fps, GPU probe 1.10x; 3D views at 0.85 of the game's size",
                  "[dm] [nvn] GPU clock cool-down #2 at frame 21000: 38.0 fps against 60 with the GPU probe at 3.20x its fastest: the views at their smallest for 8 s (next no sooner than 10 s after)",
                  "[dm] [nvn] GPU clock cool-down #2 over at frame 21480: 60.0 fps, GPU probe 1.30x; the views back"])
        self.assertEqual([e['what'] for e in s['timeline']],
                         ['render scale 0.85 (heat ladder: resolution 85%): state +0x14 0.850', 'GPU clock rescue #1 (39.3 fps, GPU probe 2.89x)',
                          'render scale 0.64 (the GPU clock rescue): state +0x14 0.637', 'GPU clock rescue #1 over',
                          'GPU clock cool-down #2 (38.0 fps, GPU probe 3.20x)', 'GPU clock cool-down #2 over'])
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        found = re.search(r'LOG\("(\[heat\] render scale %\.2f = [^"]*)"', src); assert found
        fmt = found.group(1)
        self.assertTrue(devlog.RX['render_scale'].search(fmt.replace('%.2f', '0.85').replace('%s', 'x')), fmt)
        fmts = re.findall(r'LOG\("(\[nvn\] GPU clock %s #%u [^"]*)"', src)
        self.assertEqual(len(fmts), 2, fmts)   # its start and its end, for the rescue and the cool-down (%s)
        for kind in ('rescue', 'cool-down'):
            for f in fmts: self.assertTrue(devlog.RX['clock_rescue'].search(f.replace('%s #', kind + ' #', 1).replace('%u', '1').replace('%llu', '100').replace('%.1f', '40.0').replace('%.0f', '60').replace('%.2f', '2.90').replace('%s', 'x').replace('%d', '3')), f)

    def test_heat_hold_calm_waits(self):   # thermal_capped's back-off: a heat hold's line says its calm wait (30 s, doubled up to 240 s for one back within 10 min), its end the wait it used
        s = read([onscreen(300, 0),
                  '[dm] [nvn] thermal state 2: the game holds 30 fps until the device is fair again for 30 s (the first heat hold: calm wait 30 s, doubled up to 240 s for each hold '
                  'that comes back within 10 min; DM_THERMAL_CAP=0 turns this off)', onscreen(2100, 0),
                  "[dm] [nvn] thermal state 1 for 30 s, this heat hold's calm wait: back to the frame rate cap (a heat hold within the next 10 min waits 60 s)", onscreen(3900, 0),
                  '[dm] [nvn] thermal state 2: the game holds 30 fps until the device is fair again for 60 s (the heat hold came back 30 s after the last one ended: calm wait doubled; '
                  'DM_THERMAL_CAP=0 turns this off)', onscreen(7500, 0),
                  "[dm] [nvn] thermal state 1 for 60 s, this heat hold's calm wait: the heat hold ends, Low Power Mode still holds 30 fps (a heat hold within the next 10 min waits 120 s)",
                  '[dm] [nvn] Low Power Mode off for 30 s: back to the frame rate cap', onscreen(9000, 0),
                  '[dm] [nvn] thermal state 2: the game holds 30 fps until the device is fair again for 120 s (the heat hold came back 25 s after the last one ended: calm wait doubled; '
                  'DM_THERMAL_CAP=0 turns this off)', onscreen(10800, 0)])
        self.assertEqual([e['what'] for e in s['timeline']],
                         ['the game held at 30 fps (thermal state 2, calm wait 30 s)', 'the chosen frame rate again (thermal state 1 for 30 s)',
                          'the game held at 30 fps (thermal state 2, calm wait 60 s)', 'the heat hold over, Low Power Mode still at 30 fps (thermal state 1 for 60 s)',
                          'the chosen frame rate again', 'the game held at 30 fps (thermal state 2, calm wait 120 s)'])
        # 5-35 s, 65-125 s, and 150 s to the log's end at 180 s (frames at 60 fps: no power lines)
        self.assertEqual(s['heat_holds'], {'count': 3, 'calm_waits_s': [30, 60, 120], 'held_s': 120.0, 'held_pct': 66.7})
        self.assertIn('3 heat holds, 2.0 min at 30 fps (66.7% of the run); calm waits 30, 60, 120 s', '\n'.join(devlog.render(s, 5)))
        cool = read([onscreen(300, 0)])   # no heat hold: 0, and no heat summary in the row
        self.assertEqual(cool['heat_holds'], {'count': 0, 'calm_waits_s': [], 'held_s': 0.0, 'held_pct': 0.0})
        self.assertNotIn('heat hold', '\n'.join(devlog.render(cool, 5)))
        # compared with a log that held, the two rows read a change, not 'differs'
        rows = {r['label']: r for r in devlog.compare(s, cool)['rows']}
        self.assertEqual((rows['heat holds']['b'], rows['heat holds']['change']), (0, '-3 (-100%)'))
        self.assertEqual((rows['time at the heat hold (%)']['b'], rows['time at the heat hold (%)']['change']), (0.0, '-66.7 (-100%)'))
        # the lines thermal_capped writes are the ones read here
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        fmts = re.findall(r'LOG\("\[nvn\] (thermal state %d[^"]*)"', src)
        self.assertEqual(len(fmts), 5, fmts)   # the start, two ends after the calm wait, two after a long stay away
        for f in fmts:
            line = '[nvn] ' + f.replace('%d', '2').replace('%llu', '60').replace('%s', '')
            self.assertTrue(devlog.RX['heat_hold'].search(line) or devlog.RX['heat_end'].search(line), f)

    def test_heat_hold_ends_after_a_stay_away(self):   # thermal_capped: back at state 0 from a stay of the longest calm wait or more, the heat hold ends at once
        s = read([onscreen(300, 0),
                  '[dm] [nvn] thermal state 2: the game holds 30 fps until the device is fair again for 240 s (the heat hold came back 9 s after the last one ended: calm wait doubled; '
                  'DM_THERMAL_CAP=0 turns this off)', onscreen(2100, 0),
                  '[dm] [nvn] thermal state 0 after 1800 s away, the longest calm wait (240 s) or more: back to the frame rate cap (the next heat hold waits 30 s)', onscreen(3900, 0),
                  '[dm] [nvn] thermal state 2: the game holds 30 fps until the device is fair again for 30 s (the last heat hold ended 1839 s ago, 10 min or more: calm wait back '
                  'to 30 s; DM_THERMAL_CAP=0 turns this off)', onscreen(5700, 0),
                  '[dm] [nvn] thermal state 0 after 300 s away, the longest calm wait (240 s) or more: the heat hold ends, Low Power Mode still holds 30 fps (a heat hold within '
                  'the next 300 s waits 60 s)', onscreen(7500, 0)])
        self.assertEqual([e['what'] for e in s['timeline']],
                         ['the game held at 30 fps (thermal state 2, calm wait 240 s)', 'the chosen frame rate again (thermal state 0 after 1800 s away)',
                          'the game held at 30 fps (thermal state 2, calm wait 30 s)', 'the heat hold over, Low Power Mode still at 30 fps (thermal state 0 after 300 s away)'])
        self.assertEqual((s['heat_holds']['count'], s['heat_holds']['calm_waits_s'], s['heat_holds']['held_s']), (2, [240, 30], 60.0))   # 5-35 s and 65-95 s

    def test_touch_draw_events(self):   # front_ios.m says which draws the touch controls: in the frame, on their layers (a refresh of latency more), or hidden
        s = read(["[dm] front end: touch controls drawn on their layers over the game's layer (until the game's first picture)",
                  "[dm] front end: touch controls drawn into the game's frame by the present (canvas 956x440 points, drawable 2868x1320; DM_TOUCH_DRAW=layer draws them on their layers)",
                  '[dm] front end: touch controls hidden (a controller is in use)', "[dm] front end: touch controls drawn on their layers over the game's layer (DM_TOUCH_DRAW=layer)"])
        self.assertEqual([e['what'] for e in s['events']['list']], ["touch controls on their layers (until the game's first picture)", 'touch controls in the frame',
                                                                    'touch controls hidden (a controller is in use)', 'touch controls on their layers (DM_TOUCH_DRAW=layer)'])

    def test_menu_open_too_long(self):   # a close the log may have missed: open a minute or more, or never closed in a log that ran a minute past the open, is flagged
        pw = lambda f: lf(f, 20.0)   # a long-frame line gives the log's clock: frame f at f / 60 s
        s = read([pw(60), '[dm] front end: in-game menu open', '[dm] front end: in-game menu closed after 75.0 s', pw(6000), '[dm] front end: in-game menu open', pw(12000)])
        self.assertEqual([(x['open_s'], x['closed']) for x in s['events']['menu_long']], [(75.0, True), (100.0, False)])
        text = '\n'.join(devlog.render(s, 5))
        self.assertIn('the in-game menu was open 75 s from 1 s: a close may have been missed', text)
        self.assertIn('was open 100 s from 100 s and never closed in the log', text)
        short = read([pw(60), '[dm] front end: in-game menu open', '[dm] front end: in-game menu closed after 2.4 s', '[dm] front end: in-game menu open', pw(1200)])
        self.assertEqual(short['events']['menu_long'], [])   # a log that ends soon after an open (the player shares it from the menu) is not flagged

    def test_old_logs_read_as_before(self):   # no tag and no note: nothing apart, the rate without such windows is the rate, no line of text for it
        s = read([timing(300), onscreen(300, 3), lf(100, 80.0)])
        f, lfs = s['frames'], s['long_frames']
        self.assertEqual((f['menu_frames'], f['front_end_windows'], f['dropped_clean_pct'], f['dropped_pct']), (0, 0, 1.0, 1.0))
        self.assertEqual((lfs['count'], lfs['front_end']), (1, 0))
        text = '\n'.join(devlog.render(s, 5))
        self.assertNotIn('in-game menu', text); self.assertNotIn('drawing over the game', text)


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


class PowerGpu(unittest.TestCase):   # the power line's GPU: the host's own busy time ('GPU x ms/s busy (…)'), the system's count beside it only where it moved (the Mac), and an older log's lone system count
    def fmt(self) -> tuple[str, str]:   # the power line and its system's-count part as hle_nvn.c power_line prints them, as Python formats
        src = (REPO / 'dm/gfx/nvn/hle_nvn.c').read_text(errors='replace')
        main = re.search(r'LOG\("\[nvn\] (power up to frame %llu: [^"]*)"', src); gt = re.search(r'snprintf\(gt, sizeof gt, "([^"]*)"', src)
        self.assertTrue(main and gt, 'the power line\'s format strings in hle_nvn.c')
        assert main and gt
        return main.group(1).replace('%llu', '%d'), gt.group(1)

    def line(self, frame: int, busy: float, system: float | None = None, thermal: int = 0) -> str:
        main, gt = self.fmt()
        return '[dm] [nvn] ' + main % (frame, 1.2, 20.0, 60.0, 120, 80, 7000, 300, busy, gt % system if system is not None else '', thermal, 'none')

    def test_line_format_matches_the_producer(self):
        for system in (None, 480.5):   # iOS: no system's count; the Mac: the count beside the busy time
            x = devlog.RX['power'].search(self.line(600, 512.3, system, 2)[len('[dm] '):])
            self.assertIsNotNone(x)
            assert x
            self.assertEqual((x.group(1), x.group(9), x.group(10), x.group(11), x.group(12)), ('600', '512.3', ' busy', None if system is None else '480.5', '2'))

    def test_read_and_shown(self):   # the busy time's median, and the system's count, 0 where the line has none
        s = read([self.line(f, b) for f, b in ((300, 400.0), (600, 500.0), (900, 600.0))])
        self.assertEqual((s['power']['gpu_busy_ms_s_p50'], s['power']['gpu_ms_s_p50']), (500.0, 0.0))
        self.assertIn('GPU 500 ms/s busy (the system\'s count 0; iOS leaves it at 0)', '\n'.join(devlog.render(s, 5)))
        s = read([self.line(f, b, b - 20) for f, b in ((300, 400.0), (600, 500.0), (900, 600.0))])   # the Mac
        self.assertEqual((s['power']['gpu_busy_ms_s_p50'], s['power']['gpu_ms_s_p50']), (500.0, 480.0))
        shown = '\n'.join(devlog.render(s, 5))   # the Mac's count is not 0: no 'iOS leaves it at 0' beside it
        self.assertIn('GPU 500 ms/s busy (the system\'s count 480)', shown)
        self.assertNotIn('iOS leaves it at 0', shown)

    def test_an_older_log(self):   # before the busy time: the line's lone GPU figure is the system's count, and there is no busy time to compare
        old = '[dm] [nvn] power up to frame %d: CPU energy 1.20 W, 20.0 mJ per frame (60.0 fps); CPU 120%% (100 = one core), 80%% of it on performance cores; wakeups 7000/s (out of platform idle 300); GPU 0.0 ms/s; thermal 1; top yielders: none'
        a = read([old % f for f in (300, 600, 900)])
        self.assertEqual((a['power']['gpu_busy_ms_s_p50'], a['power']['gpu_ms_s_p50'], a['power']['thermal_max']), (None, 0.0, 1))
        self.assertIn('an older log, before the host\'s own busy time', '\n'.join(devlog.render(a, 5)))
        b = read([self.line(f, 500.0) for f in (300, 600, 900)])
        rows = {r['label']: r for r in devlog.compare(a, b)['rows']}
        self.assertEqual((rows['GPU ms/s busy']['a'], rows['GPU ms/s busy']['b']), (None, 500.0))   # no better or worse from nothing
        self.assertEqual(rows['GPU ms/s, the system\'s count']['change'], '')   # 0 against 0: the system's count of an iPhone, before and after


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



class PrepareLine(unittest.TestCase):   # nvn_mtl.m's prepare line, with the bundled archive's layout bases (X1.0) and without (no bundle, an older log)
    HEAD = ('[dm] [nvn-mtl] pipeline prepare: 120 lines (10 shaders, 100 render pipelines, 10 compute pipelines) in 0.80 s on 12 workers before the first frame, progress screen shown; '
            'bases 2 compiled, 90 from the archive, 8 reused; 100 specializations')

    def test_line_format_matches_the_producer(self):
        src = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')
        self.assertIn('"bases %llu compiled, %llu from the archive%s, %llu reused; %llu specializations%s"', src)
        self.assertIn('"; %llu layout bases from the archive bundled with the app"', src)

    def test_layout_bases_from_the_bundle(self):
        pr = devlog.read(self.HEAD + '; 70 layout bases from the archive bundled with the app\n')['pipelines']['prepare']
        self.assertEqual((pr['lines'], pr['bases_compiled'], pr['bases_from_archive'], pr['reused'], pr['bundle_layout']), (120, 2, 90, 8, 70))
        pr = devlog.read(self.HEAD + '\n')['pipelines']['prepare']
        self.assertEqual((pr['bases_from_archive'], pr['bundle_layout']), (90, None))
        # the shader-only lines left to after the first frame (warm_split_late) come after, in the same part
        self.assertIn('"; %ld shader-only lines left to after the first frame"', (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace'))
        pr = devlog.read(self.HEAD + '; 70 layout bases from the archive bundled with the app; 30357 shader-only lines left to after the first frame\n')['pipelines']['prepare']
        self.assertEqual((pr['lines'], pr['bundle_layout']), (120, 70))
        pr = devlog.read(self.HEAD + '; 30357 shader-only lines left to after the first frame\n')['pipelines']['prepare']
        self.assertEqual((pr['lines'], pr['bundle_layout']), (120, None))


class PrepareLater(unittest.TestCase):   # nvn_mtl.m's later start (warm_later_bg): the lists handed to the background and the line at their end; a waiting start has neither
    SRC = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')

    def fill(self, name: str, vals: list[str]) -> str:   # the producer's format string, filled in
        m = re.search(r'MLOG\("(pipeline prepare' + name + r'[^"]*)"\s*\n?\s*"([^"]*)"', self.SRC) or re.search(r'MLOG\("(pipeline prepare' + name + r'[^"]*)"()', self.SRC)
        self.assertIsNotNone(m, name)
        assert m
        it = iter(vals)
        return '[dm] [nvn-mtl] ' + re.sub(r'%(?:\.\d+f|llu|ld|d|s)', lambda _: next(it), m.group(1) + m.group(2))

    def test_line_format_matches_the_producer(self):
        later = self.fill(': a later start: ', ['30357', '3', ''])
        bg = self.fill(' in the background: ', ['30357', '12.50', '3', '2', '29000', '40', '900'])
        pl = devlog.read(later + '\n' + bg + '\n')['pipelines']['prepare_later']
        self.assertEqual(pl, {'lines': 30357, 'workers': 3, 'background_s': 12.5, 'bases_compiled': 2, 'bases_from_archive': 29000})
        pl = devlog.read(later + '\n')['pipelines']['prepare_later']   # a run that ended first
        self.assertEqual((pl['lines'], pl['background_s']), (30357, None))

    def test_a_waiting_start_has_none(self):
        pr = devlog.read(PrepareLine.HEAD + '\n')['pipelines']
        self.assertIsNone(pr['prepare_later'])
        self.assertEqual(pr['prepare']['lines'], 120)   # and the waiting line reads as before


class MipDrop(unittest.TestCase):   # nvn_mtl.m's DM_NVN_MIP_DROP start line and its line after the memory line, read for the phone's A/B (memory.md, Top mip levels left out on the phone)
    def test_line_format_matches_the_producer(self):   # the formats md_k and mtl_mem_stat print, filled in, are what the patterns read
        src = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')
        line = re.search(r'MLOG\("(mip drop up to frame %llu: [^"]*)"', src); start = re.search(r'MLOG\("(DM_NVN_MIP_DROP=%d: [^"]*)"', src)
        self.assertTrue(line and start, 'the mip drop\'s format strings in nvn_mtl.m')
        assert line and start
        vals = iter(['1800', '412', '2', 's', '930', '1650', '2900', '3', '; uploads that kept every level in all, by reason (the MB of their top levels): not block-compressed 2041 (310.2 MB), below the size floor 812 (96.0 MB)', '; of those held now, through DM_NVN_MIP_DROP_COMPRESSIBLE 120 (95 MB)'])
        x = devlog.RX['mipdrop'].search('[nvn-mtl] ' + re.sub(r'%(?:llu|u|d|s)', lambda _: next(vals), line.group(1)))
        self.assertIsNotNone(x)
        assert x
        self.assertEqual(x.groups(), ('1800', '412', '2', '930', '1650', '2900', '3'))
        vals = iter(['2', '1024', '2', 's'])
        x = devlog.RX['mipdrop_on'].search('[nvn-mtl] ' + re.sub(r'%(?:llu|u|d|s)', lambda _: next(vals), start.group(1)))
        self.assertIsNotNone(x)
        assert x
        self.assertEqual(x.groups(), ('2', '1024'))

    def test_read_shown_and_compared(self):
        ls = ['[dm] [nvn-mtl] DM_NVN_MIP_DROP=1: block-compressed 2D textures uploaded from their storage, 2048 texels or larger, with a whole mip chain, are made without their top 1 level while only texture IDs sample them',
              *(f'[dm] [nvn-mtl] mip drop up to frame {f}: {n} textures held without their top 1 level now ({mb} MB not allocated); {u} such uploads in total ({u * 3} MB of levels not uploaded); {w} made whole again'
                for f, n, mb, u, w in ((300, 10, 40, 10, 0), (600, 90, 400, 120, 2), (900, 60, 250, 140, 2)))]
        m = read(ls)['mip_drop']
        self.assertEqual((m['levels'], m['min_texels'], m['held_last'], m['held_max'], m['mb_last'], m['mb_max'], m['uploads'], m['upload_mb'], m['whole']), (1, 2048, 60, 90, 250, 400, 140, 420, 2))
        self.assertIsNone(read([])['mip_drop'])


class GhostTable(unittest.TestCase):   # nvn_mtl.m's finalized-texture table: its start line (size and source) and its line every 300 frames, read for the DM_NVN_GHOST A/B (frame-rate.md)
    def lines(self, cap: int, why: str, windows: list[tuple[int, str, str, str]]) -> list[str]:
        return [f'[dm] [nvn-mtl] finalized-texture table: up to {cap} textures that finalized texture objects still resolve to, the least recently used going when a new one comes, idle ones drained back to 512 ({why})',
                *(f'[dm] [nvn-mtl] finalized-texture table up to frame {f} ({cap} held, up to {cap}), per frame: {put} put, {thr} of them pushed out in the last 4 frames, '
                  f'{ev} pushed out; 0.400 ms in the texture misses that put, 0.900 ms patching pool tables; texture ID epochs started 0.50' for f, put, thr, ev in windows)]

    def test_line_format_matches_the_producer(self):   # the formats mtl_ghost_stat and ghost_cap print, filled in, are what the patterns read
        src = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')
        line = re.search(r'MLOG\("(finalized-texture table up to frame %llu [^"]*)"', src); start = re.search(r'MLOG\("(finalized-texture table: up to %u [^"]*)"', src)
        self.assertTrue(line and start, 'the finalized-texture table\'s format strings in nvn_mtl.m')
        assert line and start
        vals = iter(['3600', '64', '64', '0.33', '0.02', '4', '0.12', '0.010', '0.250', '0.07', '32', '56', '0.07 sparse mappings changed; 0.00 syncs kept by their notes with sparse mappings unchanged (DM_NVN_SPARSE_EPOCH on)'])
        x = devlog.RX['ghost'].search('[nvn-mtl] ' + re.sub(r'%(?:llu|u|d|s)', lambda _: next(vals), line.group(1)))
        self.assertIsNotNone(x)
        assert x
        self.assertEqual(x.groups(), ('3600', '64', '64', '0.33', '0.02', '0.12', '0.010', '0.250', '0.07', '32', '56'))
        x = devlog.RX['ghost_cap'].search('[nvn-mtl] ' + start.group(1).replace('%u', '4096').replace('%s', 'game profile ghost_table'))
        self.assertIsNotNone(x)
        assert x
        self.assertEqual(x.groups(), ('4096', 'game profile ghost_table'))

    def test_read_shown_and_compared(self):   # the 512 side of Ocarina's A/B against the profile's 4096: thrash read per window and compared lower-better
        a = read(self.lines(512, 'DM_NVN_GHOST', [(300, '2.10', '0.00', '0.00'), (600, '800.00', '640.00', '790.00'), (900, '364.00', '300.00', '360.00')]))
        b = read(self.lines(4096, 'game profile ghost_table', [(300, '2.10', '0.00', '0.00'), (600, '800.00', '0.00', '0.00'), (900, '20.00', '0.00', '0.00')]))
        ga, gb = a['ghost'], b['ghost']
        self.assertEqual((ga['cap'], ga['source'], ga['windows'], ga['put'], ga['thrash'], ga['thrash_max'], ga['evicted'], ga['miss_ms'], ga['patch_ms'], ga['epochs']),
                         (512, 'DM_NVN_GHOST', 3, 364.0, 300.0, 640.0, 360.0, 0.4, 0.9, 0.5))
        self.assertEqual((gb['cap'], gb['thrash'], gb['put_max'], gb['drained'], gb['low_headroom']), (4096, 0.0, 800.0, 0, 0))   # lines without the drain's part (before it) read as none
        text = '\n'.join(devlog.render(a, 5))
        self.assertIn('finalized-texture table of 512 (DM_NVN_GHOST)', text)
        self.assertIn('300 pushed out in the last 4 frames (most 640)', text)
        rows = {r['label']: r for r in devlog.compare(a, b)['rows']}
        self.assertTrue(rows['finalized-texture thrash, most']['change'].endswith('better'), rows['finalized-texture thrash, most'])
        self.assertEqual((rows['finalized-texture table']['a'], rows['finalized-texture table']['b']), (512, 4096))

    def test_drained_summed(self):   # the drain and the low-headroom drop counted per window and summed for the run
        ls = self.lines(4096, 'game profile ghost_table', [(300, '800.00', '0.00', '0.00'), (600, '0.00', '0.00', '0.00')])
        ls[1] += '; in the window 0 idle entries drained, 0 let go at low memory headroom'; ls[2] += '; in the window 640 idle entries drained, 988 let go at low memory headroom'
        g = read(ls)['ghost']
        self.assertEqual((g['windows'], g['drained'], g['low_headroom']), (2, 640, 988))
        self.assertIn('in all 640 idle entries drained, 988 let go at low memory headroom', '\n'.join(devlog.render(read(ls), 5)))

    def test_start_line_only(self):   # a run whose table never put: its size, no window
        g = read(self.lines(512, 'the default', []))['ghost']
        self.assertEqual((g['cap'], g['windows'], g['thrash']), (512, 0, None))
        self.assertIn('no window with a put or an eviction', '\n'.join(devlog.render(read(self.lines(512, 'the default', [])), 5)))
        self.assertIsNone(read([])['ghost'])


class BundledArchive(unittest.TestCase):   # the pipeline archive bundled with the app: opened, or left out, the crash guard's verdicts among them (nvn_mtl.m, pso_guard_begin)
    G = '[dm] [nvn-mtl] [RED] pipeline archive bundled with the app: '
    ID = 'applegpu_g19p.metallib (12 MB, 0123abcd, app 89ab)'

    def bundled(self, line: str):
        return read([line])['pipelines']['bundled']

    def test_opened(self):   # at the first submission (an older host, a small archive, DM_PSO_PREOPEN=0): all of the open is waited for there
        self.assertEqual(self.bundled(f'[dm] [nvn-mtl] pipeline archive bundled with the app: /a/{self.ID}, 12.0 MB, opened in 3.5 ms'),
                         {'mb': 12.0, 'open_ms': 3.5, 'wait_ms': 3.5, 'early': False})

    def test_opened_at_the_hosts_start(self):   # mtl_pso_bundle_preopen: the open's own time and what the first submission waited for, the format filled from nvn_mtl.m
        src = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')
        m = re.search(r'MLOG\("(pipeline archive bundled with the app: %s, %\.1f MB, opened in %\.1f ms; opened at the game\'s start[^"]*)"', src)
        self.assertTrue(m)
        assert m
        vals = iter(('/a/applegpu_g19p.mtl4a', '4617.3', '2361.5', '120.4'))
        line = '[dm] [nvn-mtl] ' + re.sub(r'%(?:s|\.1f)', lambda _m: next(vals), m.group(1))
        s = read([line])
        self.assertEqual(s['pipelines']['bundled'], {'mb': 4617.3, 'open_ms': 2361.5, 'wait_ms': 120.4, 'early': True})
        self.assertIn("the app's own archive 4617.3 MB (opened in 2361.5 ms at the game's start, 120.4 ms of it waited for at the first submission)", '\n'.join(devlog.render(s, 5)))
        old = read(['[dm] [nvn-mtl] pipeline archive bundled with the app: /a/applegpu_g19p.mtl4a, 4617.3 MB, opened in 2361.5 ms'])
        rows = {r['label']: r for r in devlog.compare(old, s)['rows']}
        self.assertEqual((rows['bundled archive open waited for (ms)']['a'], rows['bundled archive open waited for (ms)']['b']), (2361.5, 120.4))

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

class PipelineLines(unittest.TestCase):   # nvn_mtl.m's 'pipelines up to frame' line with the pulling-base kicks of the hybrid lookups, and the bundled archive's probe line with its cover note
    SRC = (REPO / 'dm/gfx/nvn/nvn_mtl.m').read_text(errors='replace')

    @staticmethod
    def c_fmt(fmt: str, *vals: object) -> str:   # a C format string filled as the host prints it (%llu and %d as integers, %.1f, %s)
        it = iter(vals)
        return re.sub(r'%(?:llu|d|\.1f|s)', lambda _m: str(next(it)), fmt)

    def pso_fmt(self) -> str:   # mtl_pso_line's first snprintf, its adjacent literals joined
        body = self.SRC[self.SRC.index('void mtl_pso_line('):]
        call = body[body.index('snprintf(o, n, '):]
        lits = re.findall(r'"((?:[^"\\]|\\.)*)"', call[:call.index(',\n             d[0]')])
        return ''.join(lits)

    def probe_fmt(self) -> str:
        m = re.search(r'MLOG\("(pipeline archive bundled with the app: %s \(%d of %d probed pairs from %s found, %\.1f ms\)%s)"', self.SRC)
        self.assertTrue(m, "pso_bundle_covers' probe line in nvn_mtl.m")
        assert m
        return m.group(1)

    def pso_line(self, frame: int, compiled: int, kicked: int, unkicked: int = 0, look: tuple = (0, 0, 0.0, 0, 0.0, 0, 0.0), pred: tuple = (0, 0.0)) -> str:
        unk = f', {unkicked} not kicked (DM_PSO_HYBRID_KICK=0)' if unkicked else ''
        # the fifth value (0) is X1.0's 'builds admitted' after the predictions; look: the background base lookups (handed over, found, ms), the archive lookups on the submit
        # thread (n, ms) and the draws that waited for another thread's lookup (n, ms), the port of upstream 9d3a58364 + edc7eff9c
        vals = [1.0, 0.5, pred[0], pred[1], 0, 3, 1.0, 2, 0.5, 0, 0.0, compiled, 70.0 * compiled, 4, 1, 9, kicked, unk, 0, 0, 0, 0, *look]
        return f'[dm] [nvn] pipelines up to frame {frame}: ' + self.c_fmt(self.pso_fmt(), *vals)

    def test_readahead_and_address_space_lines(self):   # DM_PSO_READAHEAD=1's summary and the archives' address-space line, as nvn_mtl.m writes them
        ra = re.search(r'MLOG\("(pipeline archive read-ahead %s: [^"]*)"', self.SRC); vm = re.search(r'MLOG\("(pipeline archives\' address space: [^"]*)"', self.SRC)
        self.assertTrue(ra and vm); assert ra and vm
        lines = ['[dm] [nvn-mtl] ' + self.c_fmt(ra.group(1), 'done', 1800.5, 1800.5, 12.5, 6.0, 2, 3.5),
                 '[dm] [nvn-mtl] ' + self.c_fmt(vm.group(1), 4700.0, 12.0, 4712.0, 'task address space free 9000.0 MB, largest free gap 6000.0 MB')]
        p = read(lines)['pipelines']
        self.assertEqual(p['readahead'], {'end': 'done', 'mb': 1800.5, 'of_mb': 1800.5, 's': 12.5, 'reading_s': 6.0, 'holds': 2})
        self.assertEqual(p['address_space'], {'mapped_mb': 4712.0, 'free_mb': 9000.0, 'largest_gap_mb': 6000.0})
        text = devlog.render(read(lines), 5)
        self.assertTrue([x for x in text if 'read-ahead (DM_PSO_READAHEAD=1) done' in x] and [x for x in text if 'largest free gap 6000 MB' in x], text)
        none = read(['[dm] [nvn-mtl] ' + self.c_fmt(vm.group(1), 1.0, 0.0, 1.0, "the task's address map could not be read")])['pipelines']
        self.assertEqual((none['readahead'], none['address_space']['largest_gap_mb']), (None, None))

    def test_lookup_split_read_from_the_producer_format(self):   # where the archive lookups ran, summed over every window, and the A/B rows
        a = read([self.pso_line(300, 1, 0, look=(21, 21, 900.5, 2, 100.0, 1, 40.0), pred=(19, 3.5)),
                  self.pso_line(600, 1, 0, look=(4, 3, 200.0, 1, 50.0, 0, 0.0), pred=(5, 1.0)) + '; draws that waited: pulling base not made yet 1 / 95.0 ms,'])
        lk = a['pipelines']['lookups']
        self.assertEqual((lk['predictions'], lk['predictions_ms'], lk['background'], lk['background_found'], lk['background_ms']), (24, 4.5, 25, 24, 1100.5))
        self.assertEqual((lk['submit'], lk['submit_ms'], lk['waited'], lk['waited_ms'], lk['no_pulling_base'], lk['no_pulling_base_ms']), (3, 150.0, 1, 40.0, 1, 95.0))
        self.assertTrue([x for x in devlog.render(a, 5) if 'handed to the background 25' in x])
        old = ('[dm] [nvn] pipelines up to frame 600: on the submit thread pipelines 1.0 ms, shader libraries 0.5 ms, predictions 398 / 23178.0 ms; all threads: archive lookups found 470 / 23524.0 ms, '
               'found none 2 / 0.5 ms, specializations 0 / 0.0 ms, bases compiled 6 / 400.0 ms; draws with a hybrid pipeline 4 (1 pulling pipelines made, 9 misses with no pulling base ready); '
               'background builds kicked 26, done 20, made by the draw 6, in flight 0')
        self.assertIsNone(read([old])['pipelines']['lookups'])   # an X1.0 log: no split
        rows = {r['label']: r for r in devlog.compare(a, read([self.pso_line(300, 1, 0, look=(0, 0, 0.0, 30, 1500.0, 0, 0.0))]))['rows']}
        self.assertEqual((rows['archive lookups on the submit thread']['a'], rows['archive lookups on the submit thread']['b']), (3, 30))

    def test_kicks_read_from_the_producer_format(self):
        s = read([self.pso_line(300, 1, 5), self.pso_line(600, 20, 7), self.pso_line(900, 3, 0, unkicked=4)])
        p = s['pipelines']
        self.assertEqual(p['in_play'], {'bases': 23, 'ms': 1610.0})   # the first window is left out, as before
        self.assertEqual((p['pulling_kicked'], p['pulling_not_kicked']), (12, 4))   # every window: distinct pulling bases, kicked by draws' misses and the prediction scan
        text = [x for x in devlog.render(s, 5) if 'pulling base builds kicked' in x]
        self.assertTrue(text and '12' in text[0] and '4 not kicked' in text[0], text)
        rows = {r['label']: r for r in devlog.compare(s, read([self.pso_line(600, 2, 1)]))['rows']}
        self.assertEqual((rows['pulling base builds kicked']['a'], rows['pulling base builds kicked']['b']), (12, 1))

    def test_an_older_line_has_no_kicks(self):   # before the count: the same bases, no kick figure
        old = ('[dm] [nvn] pipelines up to frame 600: on the submit thread pipelines 1.0 ms, shader libraries 0.5 ms, predictions 0 / 0.0 ms; all threads: archive lookups found 3 / 1.0 ms, '
               'found none 2 / 0.5 ms, specializations 0 / 0.0 ms, bases compiled 6 / 400.0 ms; draws with a hybrid pipeline 4 (1 pulling pipelines made, 9 misses with no pulling base ready); '
               'background builds kicked 26, done 20, made by the draw 6, in flight 0')
        p = read([old])['pipelines']
        self.assertEqual((p['in_play'], p['pulling_kicked']), ({'bases': 6, 'ms': 400.0}, None))

    def test_probe_line_and_cover_note(self):
        fmt = self.probe_fmt()
        cover = re.search(r'"(; cover pairs only: [^"]*)"', self.SRC)
        self.assertTrue(cover)
        assert cover
        for tail, want in (('', False), (cover.group(1), True)):
            line = '[dm] [nvn-mtl] ' + self.c_fmt(fmt, 'holds the bases of the listed shader pairs', 16, 16, 'shader_pairs.tsv', 26.0, tail)
            with self.subTest(cover=want):
                self.assertNotIn('every shader pair', line)
                bp = read([line])['pipelines']['bundle_probe']
                self.assertEqual(bp, {'taken': True, 'found': 16, 'probed': 16, 'cover_only': want, 'standins': None})
        refused = '[dm] [nvn-mtl] ' + self.c_fmt(fmt, 'this system does not take its bases', 0, 16, 'shader_pairs.tsv and pso_pairs.tsv', 3.0, ': the device builds them')
        self.assertEqual(read([refused])['pipelines']['bundle_probe'], {'taken': False, 'found': 0, 'probed': 16, 'cover_only': False, 'standins': None})
        older = '[dm] [nvn-mtl] pipeline archive bundled with the app: holds the bases of every shader pair (16 of 16 probed bases found, 26.0 ms)'
        self.assertEqual(read([older])['pipelines']['bundle_probe'], {'taken': True, 'found': 16, 'probed': 16, 'cover_only': False, 'standins': None})

    def test_probe_line_with_standins(self):   # the stand-in note (pso_bundle_covers: their count), after the cover note with stand-ins or alone; their lookups' own line (standin_probe_bg)
        fmt = self.probe_fmt()
        note = re.search(r'@"(; stand-ins for the pairs [^"]*)"', self.SRC)
        cover = re.search(r'"(; cover pairs only: the listed pairs [^"]*)"', self.SRC)
        bg = re.search(r'MLOG\("(pipeline archive bundled with the app: stand-ins for the pairs [^"]*)"', self.SRC)
        self.assertTrue(note and cover and bg)
        assert note and cover and bg
        st = self.c_fmt(note.group(1), 976)
        looked = '[dm] [nvn-mtl] ' + self.c_fmt(bg.group(1), 7, 8, 9.6)
        for tail, want in ((st, False), (cover.group(1) + st, True)):
            line = '[dm] [nvn-mtl] ' + self.c_fmt(fmt, 'holds the bases of the listed shader pairs', 16, 16, 'shader_pairs.tsv', 26.0, tail)
            with self.subTest(cover=want):
                s = read([line, looked])
                self.assertEqual(s['pipelines']['bundle_probe'], {'taken': True, 'found': 16, 'probed': 16, 'cover_only': want, 'standins': {'n': 976, 'found': 7, 'probed': 8}})
                self.assertTrue(any('stand-ins for 976 pairs the prewarm rows draw with (7 of 8 probed found)' in x for x in devlog.render(s, 5)))
                self.assertIsNone(read([looked])['pipelines']['bundle_probe'])   # the lookups' line alone is no probe line
                s = read([line])   # a log that ends before the lookups' line
                self.assertEqual(s['pipelines']['bundle_probe']['standins'], {'n': 976, 'found': None, 'probed': None})
                self.assertTrue(any('stand-ins for 976 pairs the prewarm rows draw with (their lookups not in the log)' in x for x in devlog.render(s, 5)))
        # the host before the lookups moved to the background: the count and the lookups on the probe line
        older = '[dm] [nvn-mtl] ' + self.c_fmt(fmt, 'holds the bases of the listed shader pairs', 16, 16, 'shader_pairs.tsv', 26.0,
                                               "; stand-ins for the pairs the prewarm list's R rows draw with: 976 (7 of 8 probed found)")
        self.assertEqual(read([older])['pipelines']['bundle_probe']['standins'], {'n': 976, 'found': 7, 'probed': 8})

class MovieLines(unittest.TestCase):   # hle_movie.c's AAC channel order lines, their formats filled in, read into the movies summary
    def fmt(self, rel: str, start: str) -> str:
        src = (REPO / rel).read_text(errors='replace')
        m = re.search(r'"(' + re.escape(start) + r'(?:[^"\\]|\\.)*)"', src)
        self.assertTrue(m, f'{start} in {rel}')
        assert m
        return m.group(1).replace("\\'", "'")

    def fill(self, f: str, strs: tuple) -> str:
        it = iter(strs)
        return re.sub(r'%(?:#x|zu|d|s)', lambda k: {'%d': '6', '%#x': '0x7c0006', '%zu': '32'}.get(k.group(0)) or next(it), f)

    def test_aac_order_lines(self):
        aac = "[movie] AAC: %d channels in AudioToolbox's order %s (layout tag %#x), "
        lines = ['[dm] ' + self.fill(self.fmt('dm/host/hle_movie.c', aac + 'handed out'), ('C L R Ls Rs LFE', 'L R C LFE Ls Rs')),
                 '[dm] ' + self.fill(self.fmt('dm/host/hle_movie.c', aac + 'already'), ('L R C LFE Ls Rs',)),
                 '[dm] ' + self.fill(self.fmt('dm/host/hle_movie.c', aac + 'kept'), ('C L R Ls Rs LFE', 'L R C LFE Ls Rs'))]
        mv = read(lines)['movies']
        self.assertEqual([(a['channels'], a['audiotoolbox'], a['console'], a['set']) for a in mv['aac']],
                         [(6, 'C L R Ls Rs LFE', 'L R C LFE Ls Rs', 'reordered'), (6, 'L R C LFE Ls Rs', 'L R C LFE Ls Rs', 'already'),
                          (6, 'C L R Ls Rs LFE', 'L R C LFE Ls Rs', 'kept (DM_AAC_LAYOUT=0)')])
        self.assertEqual(mv['vt_rebuilds'], 0)   # X1.0 restarts a lost session at the next key frame (movie_restart) instead of making it again



class StartLines(unittest.TestCase):   # the start's Play line and its first-frame line (dm/host/start_line.h), their formats filled in, read into the start summary and compared
    def formats(self) -> tuple[str, str]:
        src = (REPO / 'dm/host/start_line.h').read_text(errors='replace')
        play = re.search(r'"(start: Play at %04d-[^"]*)"', src); first = re.search(r'"(start: first frame [^"]*)"', src)
        self.assertTrue(play and first, 'the start lines\' format strings in start_line.h')
        assert play and first
        return play.group(1), first.group(1)

    def test_lines_read(self):
        play, first = self.formats()
        p = '[dm] ' + play % (2026, 11, 15, 20, 15, 31, 204, "the launcher's Play")
        f = '[dm] ' + first % (9.84, 0.21, 8.09, 1.54)
        st = read([p, lf(200, 40.0), f])['start']
        self.assertEqual(st, {'play_at': '2026-11-15 20:15:31.204', 'play_from': "the launcher's Play", 'first_frame_s': 9.84, 'host_load_s': 0.21, 'prepare_s': 8.09, 'rest_s': 1.54})
        text = '\n'.join(devlog.render(read([p, f]), 5))
        self.assertIn("start        Play at 2026-11-15 20:15:31.204 (the launcher's Play), first frame on screen 9.84 s after Play: host load 0.21 s, prepare 8.09 s, first frame 1.54 s", text)
        self.assertIsNone(read([lf(200, 40.0)])['start'], 'an older log has neither line')
        self.assertIn('no first frame in the log', '\n'.join(devlog.render(read([p]), 5)))

    def test_compared(self):
        play, first = self.formats()
        a = read(['[dm] ' + play % (2026, 11, 15, 20, 15, 31, 204, "the launcher's Play"), '[dm] ' + first % (9.84, 0.21, 8.09, 1.54)])
        b = read(['[dm] ' + play % (2026, 11, 16, 9, 1, 2, 5, "the launcher's Play"), '[dm] ' + first % (3.10, 0.20, 1.40, 1.50)])
        rows = {r['label']: r for r in devlog.compare(a, b)['rows']}
        self.assertEqual((rows['Play to first frame (s)']['a'], rows['Play to first frame (s)']['b']), (9.84, 3.1))
        self.assertTrue(rows['Play to first frame (s)']['change'].endswith('better'))
        self.assertTrue(rows['  prepare (s)']['change'].endswith('better'))
        self.assertFalse(rows['  host load (s)']['change'].endswith(('better', 'worse')), 'under half a second: the noise of a start')
        self.assertEqual(rows['Play at']['change'], 'differs')


if __name__ == '__main__':
    unittest.main()
