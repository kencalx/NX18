#!/usr/bin/env python3
# scripts/devlog.py: the summary of an iPhone or iPad log.txt from short made-up excerpts (an NVN run with a stay in the background, a Vulkan and an OpenGL game, a Mac memory line),
# two logs compared, the command line, and the host's own format strings: each line kind devlog reads is filled in from the C source that prints it and must still be read
import contextlib, importlib.util, io, json, re, statistics, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location('devlog', REPO / 'scripts/devlog.py')
assert spec is not None and spec.loader is not None
devlog = importlib.util.module_from_spec(spec); spec.loader.exec_module(devlog)

LIT = re.compile(r'"((?:[^"\\]|\\.)*)"\s*')
CONV = re.compile(r'%([-+ #0]*\d*(?:\.\d+)?)(?:ll|l|z|h)?([diuxXfgs%])')


def c_format(path: str, start: str) -> str:
    """The C format string that starts with `start` in a source file, its adjacent literals joined, as a Python %-format (C's length modifiers dropped, %u as %d)"""
    text = (REPO / path).read_text()
    i = text.index('"' + start); out = ''
    while m := LIT.match(text, i): out += m.group(1); i = m.end()
    out = out.removesuffix('\\n')   # fprintf's own newline
    return CONV.sub(lambda m: '%' + m.group(1) + ('d' if m.group(2) in 'iu' else m.group(2)), out.replace('\\"', '"'))


def sample(fmt: str, strs: tuple[str, ...] = ()) -> str:   # the format filled in: 7 for each integer, 1.5 for each float, the strings in turn
    it = iter(strs)
    return fmt % tuple(7 if c in 'dxX' else 1.5 if c in 'fg' else next(it) for c in (m.group(2) for m in CONV.finditer(fmt)) if c != '%')


# The made-up NVN run (the formats as hle_nvn.c, nvn_mtl.m, hle_audio.c, hle_fs.c, save_sync.c, front_ios.m, main.m and the launcher print them): 60 fps, 300-frame windows, the first
# power line at frame 600; between the windows of frames 1200 and 1500 a stay of 5 s in the background (that window: 30 fps over its 10 s), after which the display link's latency
# is a frame longer for two windows. A long-frame stamp at frame 450 (9.5 s) puts frame 300 at 7 s.
def window(k: int) -> list[str]:
    f = 300 * k; bg = k == 5
    out = [f'[dm] [nvn] timing up to frame {f}: frame time p50 16.67 / p95 {25.0 if bg else 17.0:.2f} / max {900.0 if bg else 20.0:.2f} ms (300 frames); '
           f'frame work p50 16.60 / p95 16.90 / max 19.00 ms (300 frames); NVN submit+present p50 0.22 / p95 1.41 / max 3.79 ms (300 frames); GPU p50 5.00 / p95 6.00 / max 7.00 ms (292 frames);',
           f'[dm] [nvn] pipelines up to frame {f}: on the submit thread pipelines 0.0 ms, shader libraries 0.0 ms, predictions 0 / 0.0 ms; all threads: archive lookups found 1 / 0.1 ms, '
           f'found none 0 / 0.0 ms, specializations 1 / 0.1 ms, bases compiled {5 if k == 1 else 1} / {400.0 if k == 1 else 10.0:.1f} ms; draws with a hybrid pipeline 0 (0 pulling '
           f'pipelines made, 0 misses with no pulling base ready); background builds kicked 0, done 0, made by the draw 0, in flight 0; draws that waited:',
           f'[dm] [nvn] frame interval up to frame {f}: >16.7ms 2 / 300 frames, p99 17.10 ms',
           f'[dm] [nvn] on-screen up to frame {f}: {290 if bg else 300} frames, dropped {12 if bg else 0} (discarded {10 if bg else 0}), p99 {33.33 if bg else 16.67:.2f} ms; '
           f'footprint {1000 + 50 * (k - 1)} MiB; brightness 0.35; thermal {2 if k == 8 else 0}']
    if k > 1: out.append(f'[dm] [nvn] power up to frame {f}: CPU energy {0.3 if bg else 0.7:.2f} W, 11.7 mJ per frame ({30.0 if bg else 60.0:.1f} fps); CPU 111% (100 = one core), 9% of it on '
                         f"performance cores; wakeups 4533/s (out of platform idle 0); GPU 2.5 ms/s busy (the host's command buffers, overlaps merged); thermal {2 if k == 8 else 0}; top yielders: none")
    if k % 2: out.append(f'[dm] [nvn-mtl] memory up to frame {f}: resident {1000 + 50 * (k - 1)} MB, GPU allocated {475 + 25 * k} MB, deferred-release queue 0, residency set 723, serial objects 642, '
                         f'memory pools 94 (resident 97; peak 94 / tracking table capacity 262144; freed but alive 0, 0 MB), shared textures {50 * (k + 1)} (0 of them unreferenced; evicted with pools 0, '
                         f'on storage takeover 5 in total), texture re-uploads 0 in total, per-frame arena blocks created 1 in total, idle upload staging released 0 times (0 MB, DM_UPLOAD_TRIM), '
                         f'finalized textures still referenced 0 (small table, 0 put in total); headroom to the system memory limit {6050 - 50 * k} MB')
    p50 = 49.3 if k in (5, 6) else 32.6 if k < 5 else 32.7
    out.append(f'[dm] [nvn-mtl] display link up to tick {f + 4}: ticks 300, presents {f}, empty ticks 4 (held for the present interval 0), old frames dropped by merging 0; '
               f'submission ahead of target display p50 16.284 ms / min 15.890 ms; game enqueue to target display p50 {p50:.3f} ms / min 32.428 / max {p50 + 5:.3f} ms')
    return out


def longframe(f: int, t: float, ms: float, pso: int = 0, lib: int = 0, make: float = 0.0, up: int = 0, rup: int = 0, mb: float = 0.0, up_ms: float = 0.0) -> str:
    return (f'[dm] [longframe] frame {f} ({t:.2f} s) whole frame {ms:.1f} ms, submit+present 0.9 ms, GPU 5.0 ms; new pipelines {pso} + shader libraries {lib}, {make:.1f} ms in all; '
            f'texture uploads {up} first + {rup} re-uploads, {mb:.1f} MB / {up_ms:.1f} ms; draws with a hybrid pipeline 0')


def nvn_log(red: str = 'SetRenderEnableConditional: the host draws anyway for now', fit: str = 'stretch', mtl4: str = '1', drop5: int = 12) -> str:
    head = ['Go ahead, here is the log',   # a line of chat around the log: skipped
            'boot: env DM_PRESENT_INTERVAL=display (env.txt)',
            'boot: memory: 6.00 GB available to the app (more with Increased Memory Limit), an 8 GB address reservation succeeds (Extended Virtual Addressing in effect)',
            '[dm] build: commit c886066f3176, shader chain 52f8ddbfc269, profile 010015100B514000',
            '[dm] front end: thermal state 0, brightness 0.35, Low Power Mode off',
            'launcher: DM_PRESENT_INTERVAL kept at display (env file)', f'launcher: DM_PICTURE_FIT={fit} (changed)', f'launcher: DM_PSO_MTL4={mtl4}',
            "[dm] controller 'Pad' connected: player 1 (npad No1)",
            '[dm] [nvn-mtl] GPU Apple M4 GPU, architecture applegpu_g16g: highest Apple GPU family Apple9, Metal 4 yes; CPU FEAT_* LSE; without MTE3; not reported none',
            '[dm] [nvn] present tick 60 Hz, interval mode display (one frame per tick, a cut) (game profile present_interval; present interval set by the game 2; window)',
            '[dm] [nvn-mtl] pipeline archive /var/mobile/Containers/Data/Application/X/Documents/pso_archive: 3 files (1 of bases without a vertex layout), 12.5 MB, opened in 4.0 ms',
            '[dm] [nvn-mtl] pipeline prepare: 100 lines (90 shaders, 9 render pipelines, 1 compute pipelines) in 1.25 s on 6 workers before the first frame, progress screen shown; '
            'bases 5 compiled, 4 from the archive, 0 reused; 9 specializations',
            '[dm] [nvn-mtl] pipeline prebuild done: 20 pairs, 18 bases built, 2 already archived, 0 left to the draws, 0 failed, 3.5 s',
            '[dm] [nvn-mtl] pipeline archive: 18 new pipeline bases written to p00004.mtl4a (2.0 MB, 30 ms)',
            longframe(5, 2.08, 60.0),   # 295 frames before frame 300 at 60 fps
            '[dm] audio #0 device callbacks 2000: 256–256 frames each, 2.7 blocks queued on average at callback; in these 2000, 0 underruns, 0.0 ms zero-padded']
    body: list[str] = []
    for k in range(1, 9):
        if k == 2: body += [longframe(450, 9.5, 120.0, pso=12, lib=1, make=110.0), '[dm] [nvn-mtl] [RED] primitive type 14 not implemented (vertex cea345eed2407c9a_b; draw skipped)',
                            '[dm] [nvn-mtl] [RED] primitive type 14 not implemented (vertex 1c08f44c6f55a642_b; draw skipped)']
        if k == 5: body += ['[dm] oe focus state → 3', '[dm] audio suspended (background / interruption)',
                            '[dm] [nvn-mtl] entering the background: dropping 1 queued frames not yet displayed (the display link does not fire in the background)',
                            '[dm] [nvn] graphics suspended: in-flight GPU work drained', '[dm] [nvn] graphics resumed', '[dm] oe focus state → 1', longframe(1290, 25.0, 900.0)]
        if k == 6: body += [f'[dm] audio #0 device callbacks 4000: 256–256 frames each, 2.7 blocks queued on average at callback; in these 2000, {drop5 * 5} underruns, 283.3 ms zero-padded',
                            '[dm] save commit #1: /var/x/Documents/save.work swapped atomically into /var/x/Documents/save (3 save writes so far) (clone + swap 890 us, since this transaction\'s first write 1036 us)',
                            '[dm] save sync: sent: 2 files, saved 2026-11-05 20:19:52, to /private/var/mobile/Library/Mobile Documents/x/save.dmsync', '[dm] save sync: in step with the cloud']
        if k == 7: body += ['launcher: DM_PICTURE_FIT=fill (in-game menu)', longframe(2000, 40.33, 40.0, up=3, rup=1, mb=8.0, up_ms=30.0)]
        if k == 8: body += ['[dm] front end: thermal state → 2 (40 s after launch)',
                            '[dm] [nvn] thermal state 2: the frame step holds 30 fps until the device is fair again for 30 s (DM_THERMAL_CAP=0 turns this off)', f'[dm] [nvn] [RED] {red}']
        lines = window(k)
        if k == 5: lines[3] = lines[3].replace('dropped 12 (discarded 10)', f'dropped {drop5} (discarded 10)')
        body += lines
    return '\n'.join(head + body + ['[dm] [nvn] power up to frame 2700: CPU ener'])   # the app ended while it wrote this line


class Summary(unittest.TestCase):
    def test_nvn_run(self):
        s = devlog.read(nvn_log(), top=2)
        name = next(ln.split('\t', 1)[1] for ln in (REPO / 'dm/games/010015100B514000/game.tsv').read_text().splitlines() if ln.startswith('name\t'))
        self.assertEqual(s['build'], {'commit': 'c886066f3176', 'chain': '52f8ddbfc269', 'profile': '010015100B514000', 'name': name})
        self.assertEqual((s['device']['gpu'], s['device']['arch'], s['device']['family'], s['device']['memory_gb'], s['device']['eva']), ('Apple M4 GPU', 'applegpu_g16g', 'Apple9', 6.0, True))
        self.assertEqual((s['api'], s['present'], s['controllers']), ('nvn', '60 Hz, interval mode display', ['Pad (player 1)']))
        self.assertEqual(s['env'], {'DM_PRESENT_INTERVAL': 'display', 'DM_PICTURE_FIT': 'stretch', 'DM_PSO_MTL4': '1'})
        self.assertEqual(s['env_from'], {'DM_PRESENT_INTERVAL': 'env file', 'DM_PICTURE_FIT': 'changed', 'DM_PSO_MTL4': 'default'})
        self.assertEqual(s['env_changes'], [{'t_s': 37.0, 'key': 'DM_PICTURE_FIT', 'value': 'fill'}])   # after the window of frame 1800
        # the clock: the power windows, put on the long-frame stamps' start (frame 450 at 9.5 s), the 10 s window of the stay in the background included
        self.assertEqual(s['time_basis'], 'the power lines and the long-frame stamps')
        self.assertEqual((s['last_frame'], s['duration_s']), (2400, 47.0))
        p = s['pipelines']
        self.assertEqual((p['prepare_s'], p['prebuild']['secs'], p['prebuild']['built'], p['prebuild']['done']), (1.25, 3.5, 18.0, True))   # regress.py's read_log
        self.assertEqual(p['prepare'], {'lines': 100, 'progress_screen': True, 'bases_compiled': 5, 'bases_from_archive': 4, 'reused': 0})
        self.assertEqual((p['archive'], p['written'], p['in_play']), ({'files': 3, 'mb': 12.5, 'open_ms': 4.0}, {'files': 1, 'bases': 18, 'mb': 2.0}, {'bases': 7, 'ms': 70.0}))
        f = s['frames']
        self.assertEqual((f['windows'], f['p50_ms'], f['p95_ms'], f['p95_worst_ms'], f['max_ms'], f['p99_onscreen_ms'], f['p99_onscreen_worst_ms']), (8, 16.67, 17.0, 25.0, 900.0, 16.67, 33.33))
        self.assertEqual((f['on_screen'], f['dropped'], f['discarded'], f['dropped_pct'], f['fps'], f['gpu_p50_ms']), (2390, 12, 10, 0.5, 60.0, 5.0))
        self.assertEqual(f['worst'], [{'t_s': 32.0, 'frame': 1500, 'dropped': 12, 'p99_ms': 33.33}])
        pw = s['power']
        self.assertEqual((pw['windows'], pw['watts_p50'], pw['watts_mean'], pw['mj_per_frame_p50'], pw['wakeups_p50'], pw['gpu_ms_s_p50'], pw['thermal_max']), (7, 0.7, 0.6, 11.7, 4533.0, 2.5, 2))
        self.assertEqual(s['timeline'], [{'t_s': 0.0, 'what': 'thermal state 0, Low Power Mode off'}, {'t_s': 40.0, 'what': 'thermal state 2'},
                                         {'t_s': 42.0, 'what': 'the frame step held at 30 fps'}])
        m = s['memory']
        self.assertEqual((m['footprint_mb']['first'], m['footprint_mb']['last'], m['footprint_mb']['max']), (1000.0, 1350.0, 1350.0))
        self.assertEqual((m['gpu_mb']['first'], m['gpu_mb']['last'], m['headroom_mb']['min'], m['shared_textures']['last']), (500.0, 650.0, 5700.0, 400.0))
        self.assertIsNone(m['gpu_mb']['per_10min'])   # 35 s between the first memory line and the last: no slope under two minutes
        dl = s['display_link']
        self.assertEqual((dl['windows'], dl['enqueue_p50_ms'], dl['frame_ms'], dl['empty_ticks']), (8, 32.65, 16.67, 4))
        self.assertEqual(dl['raised'], [{'from_s': 22.0, 'to_s': 37.0, 'windows': 2, 'p50_max_ms': 49.3, 'to_the_end': False,
                                         'before': ['focus 3', 'audio suspended', 'background', 'graphics suspended', 'resumed', 'focus 1', '1 long frame']}])
        lf = s['long_frames']
        self.assertEqual((lf['count'], lf['per_min'], lf['by_cause']), (4, 5.11, {'game': 1, 'pipelines': 1, 'background': 1, 'uploads': 1}))   # 4 in 47 s
        self.assertEqual([(r['frame'], r['causes']) for r in lf['top']], [(1290, ['return from the background']), (450, ['new pipelines (12 + 1 libraries, 110 ms)'])])
        ev = s['events']
        self.assertEqual((ev['background'], ev['resumed'], ev['focus_changes'], ev['ended_in_background']), (1, 1, 2, False))
        self.assertIn({'t_s': 37.0, 'what': 'DM_PICTURE_FIT=fill (in-game menu)'}, ev['list'])
        self.assertEqual((s['audio']['underruns'], s['audio']['zero_padded_ms'], len(s['audio']['windows'])), (60, 283.3, 1))
        self.assertEqual(s['saves'], {'commits': 1, 'commit_us_max': 890, 'sync': {'sent': 1, 'in step with the cloud': 1}})
        self.assertEqual(s['red'], {'lines': 3, 'kinds': {'primitive type # not implemented (vertex <key>_b; draw skipped)': 2, 'SetRenderEnableConditional: the host draws anyway for now': 1}})
        text = '\n'.join(devlog.render(s, 2))
        for want in ('applegpu_g16g', 'prepare 1.25 s', '12 dropped (0.5%)', '22–37 s: 2 windows up to 49.3 ms', 'return from the background', '2× primitive type'):
            self.assertIn(want, text)
        self.assertNotIn('/var/', text)   # no path from the device
        json.dumps(s)   # JSON types only

    def test_vulkan_and_opengl_games(self):   # no NVN present lines: no frames, power, display link or long frames, and the clock is the frame numbers
        vk = devlog.read('\n'.join(['[dm] build: commit abc, shader chain def, profile 0100FFFF0000A000'] + [
            f'[dm] [vk] frame {f}: draws 3, passes 1, submits 1, copies 0 (since the last record, 300 frames); pipelines so far 2, buffer memory {mb:.1f} MB' for f, mb in ((1, 10.0), (300, 50.0), (9000, 60.0))] + [
            '[dm] [vk] pipelines: 40 compiled concurrently in 1.50 s from the first create to the last finish, 0.20 s inside vkCreateGraphicsPipelines summed over the creating threads, 3.0 ms each '
            'from create to finish, at most 8 in flight and 4 handed to Metal at once, 1 failed; submissions waited for a compile 3 times, 12.5 ms in all (longest 6.0 ms); 40 since the start',
            '[dm] [nvn] graphics suspended: in-flight GPU work drained']))
        self.assertEqual((vk['api'], vk['frames'], vk['power'], vk['display_link'], vk['long_frames'], vk['time_basis']), ('vk', None, None, None, None, 'frame numbers at 60 fps'))
        self.assertEqual(vk['pipelines']['vk'], {'compiled': 40, 'failed': 1, 'waits': 3, 'wait_ms': 12.5})
        self.assertEqual((vk['memory']['vk_buffer_mb']['last'], vk['memory']['vk_buffer_mb']['per_10min']), (60.0, round(600 * statistics.linear_regression([0.0, 5.0, 150.0], [10.0, 50.0, 60.0]).slope, 1)))
        self.assertTrue(vk['events']['ended_in_background'])
        self.assertIn('no on-screen or timing lines', '\n'.join(devlog.render(vk, 5)))
        gl = devlog.read('\n'.join([
            '[dm] [gl] frame 300: draws 100, passes 3, uploads 2 (1 by blit), command buffers 300 (since the last record, 300 frames); pipelines so far 12',
            '[dm] [gl] frame 300: pipeline builds since the last record 12, 30.0 ms; in all 12, 30.0 ms, the longest 8.0 ms; 2 of them after the first frame, 9.0 ms',
            '[dm] [gl] memory at frame 1800: footprint 900 MB, Metal allocated 300 MB; 50 textures, 20 buffers (40 MB), 4 transient blocks']))
        self.assertEqual((gl['api'], gl['build'], gl['pipelines']['gl']['built'], gl['pipelines']['gl']['after_first_frame']), ('gl', None, 12, 2))
        self.assertEqual((gl['memory']['footprint_mb']['first'], gl['memory']['gpu_mb']['first'], gl['memory']['gl_textures']['first']), (900.0, 300.0, 50.0))
        devlog.render(gl, 5)
        empty = devlog.read('')
        self.assertEqual((empty['api'], empty['last_frame'], empty['memory'], empty['red']['lines']), (None, 0, None, 0))
        devlog.render(empty, 5)

    def test_mac_memory_line(self):   # the Mac writes no headroom
        s = devlog.read('[dm] [nvn-mtl] memory up to frame 300: resident 1745 MB, GPU allocated 584 MB, deferred-release queue 0, residency set 723, serial objects 642, memory pools 94 '
                        '(resident 97; peak 94 / tracking table capacity 262144; freed but alive 0, 0 MB), shared textures 612 (0 of them unreferenced; evicted with pools 0, on storage '
                        'takeover 5 in total), texture re-uploads 0 in total, per-frame arena blocks created 1 in total, idle upload staging released 0 times (0 MB, DM_UPLOAD_TRIM), '
                        'finalized textures still referenced 0 (small table, 0 put in total); headroom to the system memory limit none')
        self.assertEqual((s['memory']['footprint_mb']['first'], s['memory']['gpu_mb']['first'], 'headroom_mb' in s['memory']), (1745.0, 584.0, False))

    def test_spread(self):
        self.assertEqual(devlog.spread([(0.0, 100.0), (300.0, 120.0), (600.0, 200.0)]), {'first': 100.0, 'last': 200.0, 'min': 100.0, 'max': 200.0, 'per_10min': 100.0, 'samples': 3})
        self.assertIsNone(devlog.spread([]))

    def test_clock(self):
        c = devlog.Clock([(600, 60.0), (900, 30.0)], [])   # no stamps: frames before the first window at its rate
        self.assertEqual((c.at(300), c.at(600), c.at(900), c.at(1200)), (5.0, 10.0, 20.0, 30.0))
        self.assertEqual(devlog.Clock([], [(60, 2.0), (120, 3.0)]).at(90), 2.5)
        self.assertEqual(devlog.Clock([], []).at(600), 10.0)

    def test_a_path_switch_prints_its_last_part(self):   # a diagnostic switch's file in env.txt: no path from the device
        s = devlog.read('boot: env DM_NVN_PASSGPU=/var/mobile/Containers/Data/Application/X/Documents/gpu.tsv (env.txt)\nlauncher: DM_NVN_BARRIER=ab:0,1/3')
        self.assertEqual(s['env'], {'DM_NVN_PASSGPU': '…/gpu.tsv', 'DM_NVN_BARRIER': 'ab:0,1/3'})


class Compare(unittest.TestCase):
    def test_verdicts(self):   # beyond a tenth of A; from 0 only a count; a start's seconds under 0.5 are noise
        self.assertEqual(devlog.change(0, 0.21, -1, 'prepare (s)'), '+0.21')
        self.assertEqual(devlog.change(0.21, 0, -1, 'prepare (s)'), '-0.21 (-100%)')
        self.assertEqual(devlog.change(0, 2.5, -1, 'GPU ms/s'), '+2.5')
        self.assertEqual(devlog.change(0, 9, -1, '[RED] lines'), '+9 worse')
        self.assertEqual(devlog.change(3.775, 4.545, -1, 'GPU p50 (ms)'), '+0.77 (+20%) worse')
        self.assertEqual(devlog.change(10.0, 10.5, -1, 'GPU p50 (ms)'), '+0.5 (+5%)')

    def test_two_runs(self):
        a, b = devlog.read(nvn_log()), devlog.read(nvn_log(red='WindowCrop 1,2 3x4', mtl4='0', drop5=60))
        c = devlog.compare(a, b)
        rows = {r['label']: r for r in c['rows']}
        self.assertEqual((rows['dropped (%)']['a'], rows['dropped (%)']['b']), (0.5, 2.51))
        self.assertTrue(rows['dropped (%)']['change'].endswith('worse'))
        self.assertEqual(rows['frame time p50 (ms)']['change'], '')
        self.assertEqual(c['switches'], {'DM_PSO_MTL4': ['1', '0']})
        self.assertEqual(c['red']['only_a'], {'SetRenderEnableConditional: the host draws anyway for now': 1})
        self.assertEqual(c['red']['only_b'], {'WindowCrop #,# #x#': 1})
        text = '\n'.join(devlog.render_pair(a, b, c, ('a.txt', 'b.txt'), 5))
        self.assertIn('switches that differ (A | B):\n  DM_PSO_MTL4: 1 | 0', text)
        self.assertIn('[RED] kinds only in B:\n  1× WindowCrop #,# #x#', text)

    def test_command_line(self):
        with tempfile.TemporaryDirectory() as d:
            pa, pb = Path(d) / 'log.txt', Path(d) / 'log.prev.txt'
            pa.write_text(nvn_log()); pb.write_text(nvn_log(drop5=30))
            out = io.StringIO()
            with contextlib.redirect_stdout(out): self.assertEqual(devlog.main([str(pa), str(pb), '--json', '--top', '1']), 0)
            j = json.loads(out.getvalue())
            self.assertEqual(sorted(j), ['a', 'b', 'red', 'rows', 'switches'])
            self.assertEqual(len(j['a']['long_frames']['top']), 1)
            out = io.StringIO()
            with contextlib.redirect_stdout(out): self.assertEqual(devlog.main([str(pa)]), 0)
            self.assertTrue(out.getvalue().startswith(f"{j['a']['build']['name']} (010015100B514000): "))
            err = io.StringIO()
            with contextlib.redirect_stderr(err): self.assertEqual(devlog.main([str(Path(d) / 'missing.txt')]), 2)
            self.assertIn('cannot read', err.getvalue())


class Formats(unittest.TestCase):
    """The host's format strings, filled in, are still the lines devlog reads (a changed format fails here: change devlog's pattern with it)"""
    LINES = (  # kind, source, the format's start, the prefix its log macro adds, its strings
        ('build', 'dm/host/main.c', 'build: commit %s', '[dm] ', ('c886066f3176', '52f8ddbfc269', '0100AAAA0000B000')),
        ('gpu', 'dm/gfx/nvn/nvn_mtl.m', 'GPU %s, architecture', '[dm] [nvn-mtl] ', ('Apple M4 GPU', 'applegpu_g16g', 'Apple9', 'yes', 'LSE', 'MTE3', 'none')),
        ('mem_boot', 'dm/ios/Sources/main.m', 'boot: memory: ', '', ('an 8 GB address reservation succeeds (Extended Virtual Addressing in effect)',)),
        ('as_boot', 'dm/ios/Sources/main.m', 'boot: address space: ', '', ('at least ', 'fits', 'none')),
        ('env_file', 'dm/ios/Sources/main.m', 'boot: env %s=%s (%s)', '', ('DM_PRESENT_INTERVAL', 'display', 'env.txt')),
        ('controller', 'dm/ios/Sources/DmGamepad.m', "controller '%s' connected", '[dm] ', ('Pad', 'No1', '')),
        ('tick', 'dm/gfx/nvn/hle_nvn.c', '[nvn] present tick', '[dm] ', ('display (one frame per tick, a cut)', 'game profile', 'window')),
        ('onscreen', 'dm/gfx/nvn/hle_nvn.c', '[nvn] on-screen up to frame', '[dm] ', ()),
        ('power', 'dm/gfx/nvn/hle_nvn.c', '[nvn] power up to frame', '[dm] ', ('', 'none')),
        ('memory', 'dm/gfx/nvn/nvn_mtl.m', 'memory up to frame %llu: resident', '[dm] [nvn-mtl] ', ('6446 MB',)),
        ('memory', 'dm/gfx/nvn/nvn_mtl.m', 'memory up to frame %llu: resident', '[dm] [nvn-mtl] ', ('none',)),
        ('link', 'dm/gfx/nvn/nvn_mtl.m', 'display link up to tick %llu', '[dm] [nvn-mtl] ', ()),
        ('longframe', 'dm/gfx/nvn/hle_nvn.c', 'frame %llu (%.2f s) whole frame', '[dm] [longframe] ', ()),
        ('archive', 'dm/gfx/nvn/nvn_mtl.m', 'pipeline archive %s: %lu files', '[dm] [nvn-mtl] ', ('/x/pso_archive',)),
        ('bundled', 'dm/gfx/nvn/nvn_mtl.m', 'pipeline archive bundled with the app: %s, %.1f MB', '[dm] [nvn-mtl] ', ('/x/g16g.mtl4a',)),
        ('written', 'dm/gfx/nvn/nvn_mtl.m', 'pipeline archive: %d new pipeline bases', '[dm] [nvn-mtl] ', ('00004.mtl4a',)),
        ('prepare', 'dm/gfx/nvn/nvn_mtl.m', 'pipeline prepare: %ld lines', '[dm] [nvn-mtl] ', ('shown',)),
        ('audio', 'dm/host/hle_audio.c', 'audio #%d device callbacks', '[dm] ', ()),
        ('save_commit', 'dm/host/hle_fs.c', 'save commit #%d', '[dm] ', ('/a/save.work', '/a/save')),
        ('front_start', 'dm/ios/Sources/front_ios.m', 'front end: thermal state %d, brightness', '[dm] ', ('off',)),
        ('front_change', 'dm/ios/Sources/front_ios.m', 'front end: thermal state → %d', '[dm] ', ()),
        ('front_change', 'dm/ios/Sources/front_ios.m', 'front end: Low Power Mode → %s', '[dm] ', ('on',)),
        ('mem_warning', 'dm/ios/Sources/front_ios.m', '[RED] front end: iOS memory warning', '[dm] ', ()),
        ('focus', 'dm/host/hle_oe.c', 'oe focus state → %d%s', '[dm] ', (' (library applet open)',)),
        ('vkframe', 'dm/gfx/vk/hle_vk.m', 'frame %llu: draws %llu, passes %llu, submits', '[dm] [vk] ', ()),
        ('vkpso', 'dm/gfx/vk/hle_vk.m', 'pipelines: %llu compiled %s', '[dm] [vk] ', ('concurrently', '')),   # the second %s: the archive's part (DM_VK_ARCHIVE), empty without it
        ('glpso', 'dm/gfx/gl/hle_gl.m', 'frame %llu: pipeline builds since', '[dm] [gl] ', ()),
        ('glframe', 'dm/gfx/gl/hle_gl.m', 'frame %llu: draws %llu, passes %llu, uploads', '[dm] [gl] ', ()),
        ('glmem', 'dm/gfx/gl/hle_gl.m', 'memory at frame %llu', '[dm] [gl] ', ()))

    def test_each_line_is_read(self):
        for kind, src, start, prefix, strs in self.LINES:
            with self.subTest(kind=kind, start=start):
                line = prefix + sample(c_format(src, start), strs)
                g, _, _ = devlog.scan([line])
                self.assertTrue(g[kind], f'{kind} not read from {line!r}')

    def test_composed_lines(self):   # the timing and pipelines lines are built from pieces (hle_nvn.c tsummary, nvn_mtl.m mtl_pso_line)
        piece = sample(c_format('dm/gfx/nvn/hle_nvn.c', ' %s p50 %.2f / p95'), ('frame time',)) + sample(c_format('dm/gfx/nvn/hle_nvn.c', ' %s p50 %.2f / p95'), ('GPU',))
        g, _, _ = devlog.scan(['[dm] ' + c_format('dm/gfx/nvn/hle_nvn.c', '[nvn] timing up to frame %llu:%s') % (300, piece),
                               '[dm] ' + c_format('dm/gfx/nvn/hle_nvn.c', '[nvn] pipelines up to frame %llu: %s') % (300, sample(c_format('dm/gfx/nvn/nvn_mtl.m', 'on the submit thread'))),
                               '[dm] [nvn-mtl] ' + sample(c_format('dm/gfx/nvn/nvn_mtl.m', 'pipeline prebuild done:'))])
        self.assertEqual((g['timing'][0][1].group(2), g['timing'][0][1].group(6), g['psoline'][0][1].group(2)), ('1.50', '1.50', '7'))
        red, _, prep, pb = devlog.regress.read_log('[dm] [nvn-mtl] ' + sample(c_format('dm/gfx/nvn/nvn_mtl.m', 'pipeline prepare: %ld lines'), ('shown',)) + '\n'
                                                   + '[dm] [nvn-mtl] ' + sample(c_format('dm/gfx/nvn/nvn_mtl.m', 'pipeline prebuild done:')))
        self.assertEqual((prep, pb['done'], pb['secs']), (1.5, True, 1.5))

    def test_audio_output_lines(self):   # the iOS session, route and settle lines (front_ios.m) and the Mac device's latency (hle_audio.c, its text from audio_route.h)
        front = 'dm/ios/Sources/front_ios.m'
        got = sample(c_format(front, 'asked again for 48 kHz and 5 ms: %.0f Hz'))
        lines = ['[dm] ' + sample(c_format(front, 'audio session: sample rate %.0f Hz')),
                 '[dm] ' + sample(c_format(front, '%saudio route changed (%s)'), ('', 'new device available', 'BluetoothA2DPOutput', got, '')),
                 '[dm] ' + sample(c_format(front, '%saudio route changed (%s)'), ('', 'override', 'Speaker', sample(c_format(front, 'not asked again (DM_AUDIO_ROUTE_REAPPLY=0)')), '')),
                 '[dm] ' + sample(c_format(front, 'audio session: the I/O buffer settled at'), ('',)),
                 '[dm] ' + sample(c_format('dm/host/hle_audio.c', 'audio device %u latency: %s%s%s'),
                                  (sample(c_format('dm/host/audio_route.h', '%.1f ms (device %s'), ('64', '24', '276')), '', '')),
                 '[dm] ' + sample(c_format(front, 'audio session: deactivated by the system (lifecycle notice, reason'), ('', '')),
                 '[dm] ' + sample(c_format(front, 'audio session: deactivated by the system (lifecycle notice, no interruption context)'),
                                  (sample(c_format('dm/host/audio_lifecycle.h', '; no other app interrupted')), '')),
                 '[dm] ' + sample(c_format(front, 'audio session: resumption recommended'), ('should resume', '; resuming', '')),
                 # asking again failed: a red line, still a route change (the asked-again part is not there)
                 '[dm] ' + sample(c_format(front, '%saudio route changed (%s)'), ('[RED] ', 'old device unavailable', 'HDMIOutput', sample(c_format(front, 'asking again for 5 ms failed: %s'), ('no reason given',)), ''))]
        g, events, _ = devlog.scan(lines)
        for kind in ('au_session', 'au_route', 'au_settle', 'au_device'): self.assertTrue(g[kind], kind)
        self.assertEqual(len(g['au_route']), 3)
        self.assertEqual([e['what'] for e in events], ['audio route: BluetoothA2DPOutput (new device available)', 'audio route: Speaker (override)',
                                                       'audio deactivated by the system (lifecycle notice)', 'audio deactivated by the system (lifecycle notice)',
                                                       'audio resumption recommended (lifecycle notice)', 'audio route: HDMIOutput (old device unavailable)'])
        out = devlog.read('\n'.join(lines))['audio_output']
        self.assertEqual((out['io_buffer_ms_max'], out['output_latency_ms_max'], out['route_changes'], out['device_latency_ms_max']), (1.5, 1.5, 3, 1.5))
        self.assertEqual(out['routes'], ['BluetoothA2DPOutput', 'Speaker', 'HDMIOutput'])

    def test_event_texts_are_in_the_sources(self):
        src = ''.join(p.read_text(errors='replace') for d in ('dm/host', 'dm/gfx/nvn', 'dm/ios/Sources') for p in (REPO / d).glob('*.[cm]'))
        for needle, _, _ in devlog.EVENTS: self.assertTrue(needle.split('] ')[-1].removeprefix('audio ') in src, needle)   # hle_audio.c: "audio %s", "suspended (background …"
        swift = (REPO / 'dm/ios/Sources/LauncherSettings.swift').read_text()
        for t in ('(in-game menu)', 'kept at', '" (changed)"'): self.assertIn(t, swift)


if __name__ == '__main__':
    unittest.main()
