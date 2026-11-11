#!/usr/bin/env python3
"""Read the log.txt of an iPhone or iPad game app: a summary of one run, or two runs side by side with what differs (before and after a change, two settings, two devices).

    python3 scripts/devlog.py LOG          the summary
    python3 scripts/devlog.py A B          both side by side, then what differs
    --top N    how many of the longest frames, [RED] kinds and worst windows to list (default 5)
    --json     the same as one JSON object (for two logs: {"a", "b", "rows", "switches", "red"})

LOG is the app's Documents/log.txt or log.prev.txt (Share log, on the start screen and in the gear's menu, sends both), or a Mac app's log, which has the same host lines.
What it reads (docs/development.md, Reading a device log):
  build, device      build: commit … (main.c); GPU …, architecture … (nvn_mtl.m); boot: memory / address space (main.m); the launcher: and boot: env lines (the switches in effect,
                     and those changed in the in-game menu); controller … connected
  pipelines          pipeline prepare and prebuild (read by scripts/regress.py's read_log, as in its Mac runs); pipeline archive … files, MB; bases written; bases compiled while
                     playing ([nvn] pipelines up to frame); a Vulkan game's [vk] pipelines lines, an OpenGL game's [gl] pipeline builds
  frames, power      [nvn] timing, on-screen and power up to frame N (one each per 300 frames): frame-time percentiles, dropped frames, frame rate, CPU watts, mJ per frame,
                     wakeups, GPU ms/s (busy: the host's command buffers, overlaps merged; and the system's count, which iOS leaves at 0), thermal state; a window that had frames made with the in-game menu open or out of focus says how many (in-game menu open N frames, not in
                     focus M frames): those frames, and the dropped frames of those windows, are given apart, and the dropped rate again without those windows
  memory             [nvn-mtl] memory up to frame N and the on-screen lines' footprint; [gl] memory at frame N; [vk] frame N … buffer memory: first, last, least, most, and the
                     plateaus it stays on between the steps an area load makes (a run of samples within a tolerance of their median), with the slope inside them per 10 min
                     (the run's own slope, which the steps make, only when there is a single plateau). A newer memory line's graphics ledger and guest charged come first: GPU
                     allocated counts the guest's memory pools a second time (NieR: about 4.0 GB where the real figure is about 2.6), so a log that has them is compared on them
  display link       [nvn-mtl] display link up to tick N: submission ahead of / game enqueue to target display; the stretches of windows whose enqueue p50 is more than half a frame
                     period above the run's median (the display link counts whole frames: a frame more latency), and what the log shows just before them
  long frames        [longframe] frame N (T s): the longest, and what each spent its time on (new pipelines, texture uploads, GPU, submit, the game's side, a return from the background).
                     A frame as long as the frame step's hold asked for (2 or 3 vsyncs, within 1.25 of it) is not counted: the host's own line says the hold (; hold K × V ms,
                     hold 1 too while the frame step runs) and no longer prints such frames; in an older log the hold comes from the [nvn] frame step: hold A → B lines, and past
                     their last one from runs of three or more such frames at most two frames apart. A log with no frame step line and no hold guesses none. A line that ends with
                     (in-game menu open), (not in focus) or both was made with the in-game menu over the game or out of focus: counted apart, not as the game's, and given
                     again with them in (long frames, menu / focus ones too) so a log from before the tags compares like for like
  events             background and resume, focus changes, thermal state and Low Power Mode changes and the caps they set, memory warnings, in-game menu changes, the in-game
                     menu opening and closing (front end: in-game menu open / closed; on the Mac a menu of the menu bar), and a menu open a minute or more or never closed
  audio, saves, RED  audio #N device callbacks … underruns; save commit, save sync; [RED] kinds, normalized as regress.py does (numbers, paths and keys taken out)
  audio output       the iOS audio session's I/O buffer and output latency (audio session:, audio route changed, settled at), its route changes (a [RED] one when asking
                     again failed) and lifecycle notices;
                     the Mac device's latency (audio device N latency)
  movies             [movie] VP9 in VideoToolbox (whether a VP9 hardware decoder is there, hle_movie_avc.c); [movie] AAC: … channels in AudioToolbox's order (the console's order
                     set or kept, hle_movie.c); [movie] H.264 / AV1: VideoToolbox session made again (after iOS lost it, hle_movie_vt_rebuild.h)
Only NVN games write the timing, on-screen, power, display-link and long-frame lines (hle_nvn.c, from the present path): a Vulkan or OpenGL game's summary has its pipeline and memory
lines and the events. Other lines are skipped, and so is a cut last line. The log has no clock: times are seconds from the start, from the long-frame lines' stamps and the power lines'
frame rates, or frame numbers at 60 fps where it has neither. Only the numbers and names above are printed (no paths: a switch value that is one prints as its last part;
no save contents).
Exit code: 0 done, 2 a log could not be read."""
import argparse, bisect, collections, importlib.util, json, re, statistics, sys
from pathlib import Path
from types import ModuleType
from typing import Any

REPO = Path(__file__).resolve().parent.parent
Rec = dict[str, Any]


def no_path(v: str) -> str:
    """A switch value that is a path (a file a diagnostic switch writes, in env.txt) as its last part: devlog prints no paths"""
    return '…/' + v.rstrip('/').rsplit('/', 1)[-1] if re.match(r'(/|~/|\.\.?/)', v) else v


def load_module(name: str, path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None: raise ImportError(f'cannot load {path}')
    mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
    return mod


regress = load_module('regress', REPO / 'scripts/regress.py')   # read_log: prepare and prebuild times, [RED] kinds, a crash line; normalize_red: numbers, paths and keys out of a text

# The host's lines, from their format strings, after a leading "[dm] ". The first pattern that matches a line takes it.
RX = {k: re.compile(v) for k, v in {
    'build': r'^build: commit (\S+), shader chain (\S+), profile (\w+)',
    'gpu': r'^\[nvn-mtl\] GPU (.+?), architecture (\S+): highest Apple GPU family (\S+), Metal 4 (\w+)',
    'device': r'^\[nvn-mtl\] Metal device (.+)',
    'mem_boot': r'^boot: memory: ([\d.]+) GB available to the app .*?, an 8 GB address reservation (succeeds|fails)',
    'as_boot': r'^boot: address space: the largest block iOS reserves for the app is (at least )?([\d.]+) GB',
    'sdk': r'^sdk: NintendoSDK (\S+)',
    'env_file': r'^boot: env (DM_\w+)=(.*) \(([^()]*)\)$',
    'launcher': r'^launcher: (DM_\w+)=(.*?)(?: \((changed|in-game menu|saved choice)\))?$',
    'kept': r'^launcher: (DM_\w+) kept at (.*) \((launch environment|env file)\)$',
    'controller': r"^controller '(.+?)' (?:\(HID\) )?(connected|disconnected)(?:: player (\d+))?",
    'tick': r'^\[nvn\] present tick (\d+) Hz, interval mode (\w+)',
    'timing': r'^\[nvn\] timing up to frame (\d+): frame time p50 ([\d.]+) / p95 ([\d.]+) / max ([\d.]+) ms \((\d+) frames\);(?:.*? GPU p50 ([\d.]+) / p95 ([\d.]+))?',
    'onscreen': r'^\[nvn\] on-screen up to frame (\d+): (\d+) frames, dropped (\d+) \(discarded (\d+)\), p99 ([\d.]+) ms; footprint (-?\d+) MiB; brightness (-?[\d.]+); thermal (-?\d+)',
    'power': r'^\[nvn\] power up to frame (\d+): CPU energy ([\d.]+) W, ([\d.]+) mJ per frame \(([\d.]+) fps\); CPU (\d+)% \(100 = one core\), (\d+)% of it on performance cores; '
             r'wakeups (\d+)/s \(out of platform idle (\d+)\); GPU ([\d.]+) ms/s( busy)?(?: \([^)]*\))?(?:, ([\d.]+) ms/s by the system\'s count)?[^;]*; thermal (-?\d+)',   # ' busy (…)' and the system's count since the host's own GPU busy time
    'psoline': r'^\[nvn\] pipelines up to frame (\d+): .*?bases compiled (\d+) / ([\d.]+) ms',
    'memory': r'^\[nvn-mtl\] memory up to frame (\d+): resident (\d+) MB, GPU allocated (\d+) MB, (?:graphics ledger (\d+) MB, (?:guest charged (\d+) MB, )?)?.*?shared textures (\d+) \(.*headroom to the system memory limit (?:(\d+) MB|none)',   # none: the Mac; the graphics ledger since the memory audit, guest charged only with DM_MEM_GUEST=1
    'glmem': r'^\[gl\] memory at frame (\d+): footprint ([\d.]+) MB, Metal allocated ([\d.]+) MB; (\d+) textures',
    'vkframe': r'^\[vk\] frame (\d+): draws .*? buffer memory ([\d.]+) MB',
    'glpso': r'^\[gl\] frame (\d+): pipeline builds since the last record (\d+), ([\d.]+) ms; in all (\d+), ([\d.]+) ms, the longest ([\d.]+) ms; (\d+) of them after the first frame, ([\d.]+) ms',
    'glframe': r'^\[gl\] frame (\d+): ',
    'vkpso': r'^\[vk\] pipelines: (\d+) compiled .*? in ([\d.]+) s from the first create .*?, (\d+) failed; submissions waited for a compile (\d+) times, ([\d.]+) ms in all .*?; (\d+) since the start',
    'archive': r'^\[nvn-mtl\] pipeline archive .*: (\d+) files \((\d+) of bases without a vertex layout(?:, \d+ with an index of \d+ pipelines)?\), ([\d.]+) MB, opened in ([\d.]+) ms',   # the index part since NXNative's 70b9a68a
    'bundled': r'^\[nvn-mtl\] pipeline archive bundled with the app: .*, ([\d.]+) MB, opened in ([\d.]+) ms',
    'bundle_out': r'^\[nvn-mtl\] (?:\[RED\] )?pipeline archive bundled with the app: (?:.* is left out|.*: this start leaves the archive out|none for this GPU|this system cannot open)',   # this start leaves it out: the crash guard's verdict (nvn_mtl.m, pso_guard_begin)
    'written': r'^\[nvn-mtl\] pipeline archive: (\d+) new pipeline bases(?: and \d+ compute pipelines)?(?: and \d+ task / mesh pipelines)? written to \S+ \(([\d.]+) MB, (\d+) ms\)',   # the compute part since NXNative's 30fb2136, the task / mesh part since bf420fda
    'prepare': r'^\[nvn-mtl\] pipeline prepare: (\d+) lines .*?progress screen (shown|not shown); bases (\d+) compiled, (\d+) from the archive, (\d+) reused',
    'link': r'^\[nvn-mtl\] display link up to tick (\d+): ticks \d+, presents (\d+), empty ticks (\d+) .*?merging (\d+); submission ahead of target display p50 ([\d.]+) ms / min ([\d.]+) ms; '
            r'game enqueue to target display p50 ([\d.]+) ms / min ([\d.]+) / max ([\d.]+) ms',
    'longframe': r'^\[longframe\] frame (\d+) \(([\d.]+) s\) whole frame ([\d.]+) ms, submit\+present ([\d.]+) ms, GPU (-?[\d.]+) ms; new pipelines (\d+) \+ shader libraries (\d+), '
                 r'([\d.]+) ms in all; texture uploads (\d+) first \+ (\d+) re-uploads, ([\d.]+) MB / ([\d.]+) ms(?:.*?; hold (\d+) × ([\d.]+) ms)?',   # the hold part since the hold-aware long-frame log
    'fstep': r'^\[nvn\] frame step: hold (\d+) → (\d+) (vsyncs|ticks of 1/120 s) at present (\d+)',
    'audio': r'^audio #(\d+) device callbacks (\d+): .*; in these (\d+), (\d+) underruns, ([\d.]+) ms zero-padded',
    'au_session': r'^audio session: sample rate (\d+) Hz, I/O buffer ([\d.]+) ms \(asked for 5 ms\)(?:, output latency ([\d.]+) ms)?',
    'au_route': r'^(?:\[RED\] )?audio route changed \(([^)]*)\): output ([^;]+); sample rate (\d+) Hz, I/O buffer ([\d.]+) ms, output latency ([\d.]+) ms; '
                r'(?:asked again for 48 kHz and 5 ms: (\d+) Hz, I/O buffer ([\d.]+) ms, output latency ([\d.]+) ms)?',
    'au_settle': r'^audio session: the I/O buffer settled at ([\d.]+) ms \(([\d.]+) ms right after the request\), output latency ([\d.]+) ms',
    'au_device': r'^audio device (\d+) latency: ([\d.]+) ms \(',
    'save_commit': r'^save commit #(\d+): .*\(clone \+ swap (\d+) us',
    'save_sync': r'^save sync: (.*)',
    'front_start': r'^front end: thermal state (-?\d+), brightness [\d.]+, Low Power Mode (on|off)',
    'front_change': r'^front end: (thermal state|Low Power Mode) → (\S+) \((\d+) s after launch\)',
    'mem_warning': r'front end: iOS memory warning \((\d+) s after launch\): footprint (\d+) MiB, (\d+) MiB left',
    'focus': r'^oe focus state → (\d+)( \(library applet (?:open|closed)\))?',
    'front_menu': r'^front end: in-game menu (open|closed)(?: \(([^()]*)\))?(?: after ([\d.]+) s)?',   # hle_oe.c dm_front_menu_set: the iPhone's gear menu, or a menu of the Mac's menu bar
    'vp9_vt': r'^\[movie\] VP9 in VideoToolbox: hardware decoder (yes|no) after VTRegisterSupplementalVideoDecoderIfAvailable \((yes|no) before\); (\w+) (\S*) \(([^()]*)\), ([^.]*)\.',
    'aac_order': r"^\[movie\] AAC: (\d+) channels in AudioToolbox's order (.+?) \(layout tag \S+\), (handed out in|already|kept)(?:.*? order (.+?) \(DM_AAC_LAYOUT\)|.*? is (.+)|.*)$",
    'vt_rebuild': r'^\[movie\] (H\.264|AV1): VideoToolbox session made again after (-?\d+) \((\w+)\): (\d+) packets since the last',
}.items()}
MARKS = {'timing': 1, 'onscreen': 1, 'power': 1, 'longframe': 1, 'vkframe': 1, 'glframe': 1, 'glpso': 1}   # lines that carry a frame number (its group): the "now" of the lines after them
# (not the display link's line: its count is of presents, not frames; its windows take the frame the log was at)
# Lines that only mark an event: text in the line, what the summary calls it, its kind
EVENTS = (('[nvn-mtl] entering the background', 'background', 'app'), ('[nvn] graphics suspended', 'graphics suspended', 'app'), ('[nvn] graphics resumed', 'resumed', 'app'),
          ('audio suspended (background', 'audio suspended', 'audio'), ('audio resumed (foreground', 'audio resumed', 'audio'),
          ('audio session: interrupted', 'audio interrupted', 'audio'), ('audio session: interruption ended', 'audio interruption ended', 'audio'),
          ('audio session: active again', 'audio session back', 'audio'),
          ('audio session: deactivated by the system', 'audio deactivated by the system (lifecycle notice)', 'audio'),
          ('audio session: resumption recommended', 'audio resumption recommended (lifecycle notice)', 'audio'),
          ('the frame step holds 30 fps', 'the frame step held at 30 fps', 'cap'), ('back to the frame rate cap', 'the chosen frame rate again', 'cap'),
          ('present upscaling: bilinear while the device is', 'MetalFX off (heat or Low Power Mode)', 'cap'), ('present upscaling: MetalFX again', 'MetalFX again', 'cap'))
CAUSE_KEY = (('return', 'background'), ('focus', 'focus'), ('new pipelines', 'pipelines'), ('texture', 'uploads'), ('GPU', 'gpu'), ('submit', 'submit'), ("the game's", 'game'),
             ('the hold', 'hold'))
# A frame the frame step held for k vsyncs is as long as asked within HOLD_SLACK times k vsyncs (nvn_fstep.h FSTEP_LF_SLACK: frames at hold 2 take 31–36 ms on an iPhone). The host's
# long-frame log judged a frame against a running mean that needs 8–9 frames to catch up with a step up, so before it took the hold into account it printed those frames: 412 of
# the 486 an Ocarina of Time run on an iPhone had on the game's side. An older log names the hold only in its frame step lines, which stop after 40 lines; past them, a run of
# HOLD_RUN or more frames of k vsyncs (k from 2 to FSTEP_MAX, HOLD_LOW of it at least), with nothing else in them and at most HOLD_GAP frames apart, is a hold too: a hitch of the
# game's own is one or two frames, and not a whole number of vsyncs each. Only past those lines: a log without them shows no frame step, and there such runs are the game's own
# 30 or 20 fps dips
HOLD_SLACK, HOLD_LOW, HOLD_RUN, HOLD_GAP, HOLD_KMAX, VSYNC_MS = 1.25, 0.9, 3, 2, 3, 1000 / 60
# The host stops logging the frame step's changes after its 40th line and says so on that line, whichever of its kinds it is: a change of hold, the end of a probe (held or failed),
# or a short run after a probe counted as failed. Only the first names its new hold (RX 'fstep'), so the marker is read from every kind (fstep_cut): a cut taken from the hold
# lines alone was missed when the 40th line was a probe's, and the last logged hold was then applied to every later frame, hiding a game's own 33-41 ms frames at a stale hold 2
FSTEP_CUT, FSTEP_AT = '; further changes only counted below', re.compile(r' at present (\d+)')
# What the front end had over the game (hle_nvn.c front_ui): the system draws the iPhone's in-game menu (or a Mac menu) and whatever takes the focus over the game on the same GPU,
# so a frame made then is not the game's to answer for. 13 Sentinels on an iPhone had GPU spikes of 19-56 ms (about 7 otherwise) and bursts of dropped frames while the menu was
# open, which the log could not tell apart. A long-frame line ends with the tag (LF_UI); a timing or on-screen window line says how many of its frames were made so (WIN_UI),
# and only when some were. Such long frames are counted apart, not with the game's, and the dropped frames are also given without the windows that had any
LF_UI = re.compile(r' \((in-game menu open(?:, not in focus)?|not in focus)\)$')
WIN_UI = re.compile(r'in-game menu open (\d+) frames, not in focus (\d+) frames')
# A menu open this long (or open at the end of a log that ran this long past it) is flagged: nobody reads the in-game menu for a minute, so its close was probably missed
# (the pad reports it from willEnd and from the next touch on the game, and a controller player may never touch the game), and every frame tagged since would hide the game's own
MENU_LONG_S = 60


def fstep_cut(cuts: list[tuple[int, Any, int]]) -> int | None:
    """The present after which the log names no more frame step changes: the one its marked line names, else (the short run after a probe names none) the frame the log was at"""
    if not cuts: return None
    _, m, f = cuts[-1]
    return int(m.group(1)) if m else f
API = {'nvn': 'NVN', 'vk': 'Vulkan', 'gl': 'OpenGL'}


def med(xs: list[float]) -> float | None: return round(statistics.median(xs), 3) if xs else None   # the median of an even count is a mean: no float noise in the output


def norm(text: str) -> str:   # a text with its numbers, paths and keys taken out, as regress.py normalizes a [RED] line
    return regress.normalize_red('[RED] ' + text)


def lerp(pts: list[tuple[int, float]], f: float, slope: bool = True) -> float:   # piecewise linear through (frame, value); beyond the ends the end segment's slope, or flat
    if len(pts) == 1 or not slope and (f <= pts[0][0] or f >= pts[-1][0]): return pts[0][1] if f <= pts[0][0] or len(pts) == 1 else pts[-1][1]
    i = min(max(bisect.bisect_left(pts, (f, float('-inf'))), 1), len(pts) - 1)   # the segment that holds f, or the nearest one at either end
    (f0, t0), (f1, t1) = pts[i - 1], pts[i]
    return t0 + (f - f0) * (t1 - t0) / (f1 - f0)


class Clock:
    """Seconds from the start for a frame number. A power line's window lasts its frames over its frame rate, in wall time, a stay in the background included (the first window
    starts 300 frames before its line: the first summary only takes the baselines). A long-frame line stamps a frame with its own time: the power windows' times are moved onto
    each stamp, by an offset taken linearly between stamps (the windows' frame rates are rounded, so their sum drifts). Without power lines, the stamps alone; without either,
    frame numbers at 60 fps."""
    def __init__(self, power: list[tuple[int, float]], stamps: list[tuple[int, float]]):
        self.pts: list[tuple[int, float]] = []; self.fix: list[tuple[int, float]] = []
        st = sorted(dict(stamps).items())
        self.basis = 'frame numbers at 60 fps'
        if power:
            prev, t = power[0][0] - 300, 0.0; self.pts.append((prev, 0.0))
            for f, fps in power:
                if f > prev and fps > 0: t += (f - prev) / fps; self.pts.append((f, t)); prev = f
            f0 = self.pts[0][0]
            self.fix = [(f, s - lerp(self.pts, f)) for f, s in st] or [(f0, f0 / power[0][1] if power[0][1] > 0 else f0 / 60)]   # no stamps: the frames before at the first window's rate
            self.basis = 'the power lines' + (' and the long-frame stamps' if st else '')
        elif st:
            for f, s in st:
                if not self.pts or s >= self.pts[-1][1]: self.pts.append((f, s))
            self.basis = 'the long-frame stamps'

    def at(self, f: float) -> float:
        if not self.pts: return round(f / 60, 1)
        t = lerp(self.pts, f) if len(self.pts) > 1 else self.pts[0][1] + (f - self.pts[0][0]) / 60
        return round(max(0.0, t + (lerp(self.fix, f, slope=False) if self.fix else 0.0)), 1)


# Memory rises in steps where the game loads an area and stays about flat until the next: Ocarina of Time on an iPhone went 765 → 2830 → 3830 → 4490 MB of footprint in a
# 9.6-minute run, which a single slope over the run gave as +5290 MB per 10 minutes, a leak it did not have. A plateau is a run of samples within PLATEAU_REL of their median (and
# at least PLATEAU_FLOOR, in the series' unit); a sample outside it starts the next plateau when the sample after it is outside on the same side too, so one spike does not.
# What drifts within the plateaus is the slope fitted to all of them at once with a level of their own each (the steps left out), over two minutes of plateaus or more.
# Counts of textures churn more than megabytes do (Ocarina of Time's shared textures went 1050 → 1648 → 880 within one area): their plateaus take a wider band
PLATEAU_REL, PLATEAU_FLOOR, PLATEAU_REL_COUNT, PLATEAU_FLOOR_COUNT = 0.08, 64.0, 0.2, 16.0


def plateaus(points: list[tuple[float, float]], floor: float = PLATEAU_FLOOR, rel: float = PLATEAU_REL) -> list[list[tuple[float, float]]]:
    out: list[list[tuple[float, float]]] = []; cur: list[tuple[float, float]] = []
    for k, (t, v) in enumerate(points):
        if cur:
            ref = statistics.median(x for _, x in cur); tol = max(floor, rel * abs(ref))
            nxt = points[k + 1][1] if k + 1 < len(points) else None
            if abs(v - ref) > tol and nxt is not None and abs(nxt - ref) > tol and (nxt - ref) * (v - ref) > 0: out.append(cur); cur = []
        cur.append((t, v))
    return out + [cur] if cur else out


def drift(phases: list[list[tuple[float, float]]]) -> float | None:   # the slope within the plateaus per 10 minutes: a common slope, a level of each plateau's own
    sxy = sxx = span = 0.0
    for ph in phases:
        if len(ph) < 2: continue
        tm = sum(t for t, _ in ph) / len(ph); vm = sum(v for _, v in ph) / len(ph)
        sxy += sum((t - tm) * (v - vm) for t, v in ph); sxx += sum((t - tm) ** 2 for t, _ in ph); span += ph[-1][0] - ph[0][0]
    return round(600 * sxy / sxx, 1) if sxx > 0 and span >= 120 else None


def spread(points: list[tuple[float, float]], floor: float = PLATEAU_FLOOR, rel: float = PLATEAU_REL) -> Rec | None:
    """(seconds, value) → first, last, least, most, the least-squares slope per 10 minutes over two minutes or more, the plateaus and the drift within them"""
    if not points: return None
    vs = [v for _, v in points]; ts = [t for t, _ in points]
    out: Rec = {'first': vs[0], 'last': vs[-1], 'min': min(vs), 'max': max(vs), 'per_10min': None, 'samples': len(vs)}
    if len(points) >= 3 and ts[-1] - ts[0] >= 120 and len(set(ts)) > 1: out['per_10min'] = round(600 * statistics.linear_regression(ts, vs).slope, 1)
    # one sample per time for the plateaus: two lines that read the same moment (the footprint of a memory line and of an on-screen line) would confirm each other's spike
    ph = plateaus(list(dict(reversed(points)).items())[::-1] if len(set(ts)) < len(ts) else points, floor, rel)
    whole = all(v == int(v) for v in vs)   # megabytes and counts the log gives whole: their medians too
    out['plateaus'] = [{'from_s': p[0][0], 'to_s': p[-1][0], 'median': (round if whole else lambda x: round(x, 1))(statistics.median(v for _, v in p)),
                        'min': min(v for _, v in p), 'max': max(v for _, v in p), 'samples': len(p)} for p in ph]
    out['drift_per_10min'] = drift(ph) if len(ph) > 1 else out['per_10min']
    return out


def lf_causes(r: Rec, after: list[str], frame_ms: float) -> list[str]:   # what a long frame spent its time on, most telling first
    c = []
    if {'resumed', 'background', 'graphics suspended'} & set(after): c.append('return from the background')
    elif any(a.startswith('focus') for a in after): c.append('focus change')
    if r['pipelines'] + r['libraries'] and r['make_ms'] >= max(2.0, 0.25 * r['ms']): c.append(f"new pipelines ({r['pipelines']} + {r['libraries']} libraries, {r['make_ms']:.0f} ms)")
    if r['uploads'] + r['reuploads'] and r['upload_ms'] >= max(2.0, 0.25 * r['ms']): c.append(f"texture uploads ({r['uploads'] + r['reuploads']}, {r['upload_mb']:.1f} MB, {r['upload_ms']:.0f} ms)")
    if r['gpu_ms'] > 1.5 * frame_ms: c.append(f"GPU {r['gpu_ms']:.0f} ms")
    if not c: c.append(f"submit+present {r['submit_ms']:.0f} ms" if r['submit_ms'] >= 0.5 * r['ms'] else "the game's side (its code or its waits)")
    return c


def hold_frames(lfs: list[Rec], steps: list[tuple[int, int, float, int]], cut: int | None = None) -> None:
    """Marks each long frame whose only cause was the game's side and that took what its hold asked for (r['held_ms']): from the line's own hold, else from the frame step lines
    (present, new hold, its vsync in ms, the hold before): the hold a frame was made under is the one the present before it set, and presents are counted like frames; past cut, the
    present after which the log names no more changes (fstep_cut), from runs of frames of a whole number of vsyncs. A log whose lines say a hold needs no guess: the host says it on every line while the
    frame step runs, hold 1 too, so a line without one there was made at no hold. A log with neither a hold nor a frame step line shows no frame step, and its frames of two or three
    vsyncs (a game's own 30 or 20 fps dips) are long frames"""
    last = cut if steps else None   # the log stops naming changes after this present
    said = any(r['hold'] is not None for r in lfs)   # the host writes the hold on its lines
    infer = bool(steps) and not said and steps[-1][2] == VSYNC_MS   # at 120 fps the step holds 1 or 2 ticks of 1/120 s: a run of 33 ms frames there is no hold
    cand: list[Rec] = []
    for r in lfs:
        if not r['causes'][0].startswith("the game's"): continue
        if r['hold'] is not None: k, v = r['hold'], r['vsync_ms']
        elif said: continue
        elif steps and (last is None or r['frame'] <= last + 1):
            i = bisect.bisect_left(steps, (r['frame'],)) - 1   # the last change at a present before this frame
            k, v = (steps[i][1], steps[i][2]) if i >= 0 else (steps[0][3], steps[0][2])   # before the first change: the hold it changed from
        else:
            k = round(r['ms'] / VSYNC_MS); v = VSYNC_MS
            if infer and 2 <= k <= HOLD_KMAX and HOLD_LOW * k * v <= r['ms'] <= HOLD_SLACK * k * v: cand.append(r)
            continue
        if k > 1 and r['ms'] <= HOLD_SLACK * k * v: r['held_ms'] = round(k * v, 1); r['held_k'] = k
    run: list[Rec] = []
    for r in sorted(cand, key=lambda x: x['frame']) + [None]:   # None ends the last run
        if r is not None and run and r['frame'] - run[-1]['frame'] <= HOLD_GAP: run.append(r); continue
        if len(run) >= HOLD_RUN:
            for x in run: k = round(x['ms'] / VSYNC_MS); x['held_ms'] = round(k * VSYNC_MS, 1); x['held_k'] = k
        run = [r] if r is not None else []
    for r in lfs:
        if 'held_ms' in r: r['causes'] = [f"the hold of {r['held_k']} vsyncs ({r['held_ms']:g} ms) it was made under"]


def scan(lines: list[str]) -> tuple[dict[str, list[tuple[int, Any, int]]], list[Rec], list[list[str]]]:
    """Every known line: kind → [(line index, match, the frame the log was at)]; the events [{i, frame, what, kind, t}]; per long-frame line, the events since the line before it that
    carried a frame number"""
    g: dict[str, list[tuple[int, Any, int]]] = collections.defaultdict(list); events: list[Rec] = []; lf_after: list[list[str]] = []
    cur, pending = 0, []
    for i, line in enumerate(lines):
        s = line[5:] if line.startswith('[dm] ') else line
        kind, m = None, None
        for k, rx in RX.items():
            m = rx.search(s)
            if m: kind = k; break
        if kind in MARKS and m:
            cur = max(cur, int(m.group(MARKS[kind])))
            if kind == 'longframe': lf_after.append(pending)
            pending = []
        if kind: g[kind].append((i, m, cur))
        ev: tuple[str, str, float | None] | None = None
        if kind == 'focus' and m: ev = (f'focus {m.group(1)}' + (' (applet)' if m.group(2) else ''), 'focus', None)
        elif kind == 'front_change' and m: ev = (f'{m.group(1)} {m.group(2)}', 'power', float(m.group(3)))
        elif kind == 'mem_warning' and m: ev = (f'memory warning, {m.group(3)} MiB left', 'memory', float(m.group(1)))
        elif kind == 'controller' and m: ev = (f"controller '{m.group(1)}' {m.group(2)}", 'controller', None)
        elif kind == 'au_route' and m: ev = (f'audio route: {m.group(2)} ({m.group(1)})', 'audio', None)
        elif kind == 'front_menu' and m: ev = (f'in-game menu {m.group(1)}' + (f' ({m.group(2)})' if m.group(2) else ''), 'menu', None)
        elif kind == 'launcher' and m and m.group(3) == 'in-game menu': ev = (f'{m.group(1)}={no_path(m.group(2))} (in-game menu)', 'menu', None)
        elif kind is None:
            hit = next(((what, k) for needle, what, k in EVENTS if needle in s), None)
            if hit: ev = (hit[0], hit[1], None)
            elif s.startswith('[game]') and 'underrun' in s: g['game_underrun'].append((i, None, cur))
        if s.startswith('[nvn] frame step: ') and s.rstrip().endswith(FSTEP_CUT): g['fstep_cut'].append((i, FSTEP_AT.search(s), cur))   # any of its kinds, besides its own match
        if ev: events.append({'i': i, 'frame': cur, 'what': ev[0], 'kind': ev[1], 't': ev[2]}); pending.append(ev[0])
    return g, events, lf_after


def menu_long(lines: list[tuple[int, Any, int]], clock: Clock, end_s: float | None) -> list[Rec]:
    """The front end's menu opens that lasted MENU_LONG_S or more: closed after that long (the close line says how long), or never closed in a log that ran that long past them"""
    out: list[Rec] = []; opened: float | None = None
    for _, m, f in lines:
        if m.group(1) == 'open': opened = clock.at(f); continue
        if m.group(3) and float(m.group(3)) >= MENU_LONG_S:
            out.append({'t_s': opened if opened is not None else max(0.0, round(clock.at(f) - float(m.group(3)), 1)), 'open_s': float(m.group(3)), 'closed': True})
        opened = None
    if opened is not None and end_s is not None and end_s - opened >= MENU_LONG_S: out.append({'t_s': opened, 'open_s': round(end_s - opened, 1), 'closed': False})
    return out


def read(text: str, top: int = 5) -> Rec:
    """The summary of one log, in JSON types"""
    lines = text.splitlines()
    red, crash, prepare_s, prebuild = regress.read_log(text)
    g, events, lf_after = scan(lines)
    one = {k: v[0][1] for k, v in g.items() if v and v[0][1] is not None}   # the first line of each kind

    def col(k: str, n: int) -> list[float]: return [float(m.group(n)) for _, m, _ in g[k]]
    power = [(int(m.group(1)), float(m.group(4))) for _, m, _ in g['power']]
    clock = Clock(power, [(int(m.group(1)), float(m.group(2))) for _, m, _ in g['longframe']])
    for e in events: e['t'] = e['t'] if e['t'] is not None else clock.at(e['frame'])
    last = max((f for v in g.values() for _, _, f in v), default=0)
    out: Rec = {'lines': len(lines), 'time_basis': clock.basis, 'last_frame': last, 'duration_s': clock.at(last) if last else None}
    # build, device, switches, controllers
    b, gp, mb, ab, tk = (one.get(k) for k in ('build', 'gpu', 'mem_boot', 'as_boot', 'tick'))
    name = None
    if b:
        tsv = REPO / 'dm/games' / b.group(3) / 'game.tsv'
        name = next((ln.split('\t', 1)[1].strip() for ln in (tsv.read_text(errors='replace').splitlines() if tsv.is_file() else []) if ln.startswith('name\t')), None)
    out['build'] = {'commit': b.group(1), 'chain': b.group(2), 'profile': b.group(3), 'name': name} if b else None
    out['device'] = {'gpu': gp.group(1) if gp else one['device'].group(1) if 'device' in one else None, 'arch': gp.group(2) if gp else None, 'family': gp.group(3) if gp else None,
                     'metal4': gp.group(4) if gp else None, 'memory_gb': float(mb.group(1)) if mb else None, 'eva': (mb.group(2) == 'succeeds') if mb else None,
                     'address_space_gb': float(ab.group(2)) if ab else None, 'sdk': one['sdk'].group(1) if 'sdk' in one else None}
    out['api'] = 'vk' if g['vkframe'] or g['vkpso'] else 'gl' if g['glframe'] or g['glmem'] or g['glpso'] else 'nvn' if g['timing'] or g['link'] or g['memory'] else None
    out['present'] = f'{tk.group(1)} Hz, interval mode {tk.group(2)}' if tk else None
    frame_ms = 1000 / int(tk.group(1)) if tk and int(tk.group(1)) else 1000 / 60
    env: Rec = {}; env_from: Rec = {}; changes: list[Rec] = []
    for _, m, f in sorted(g['env_file'] + g['kept'] + g['launcher'], key=lambda x: x[0]):
        if m.re is RX['launcher'] and m.group(3) == 'in-game menu': changes.append({'t_s': clock.at(f), 'key': m.group(1), 'value': no_path(m.group(2))}); continue
        env[m.group(1)] = no_path(m.group(2)); env_from[m.group(1)] = (m.group(3) or 'default') if m.re is RX['launcher'] else m.group(3)
    out['env'], out['env_from'], out['env_changes'] = env, env_from, changes
    out['controllers'] = list(dict.fromkeys(f'{m.group(1)} (player {m.group(3)})' if m.group(3) else m.group(1) for _, m, _ in g['controller'] if m.group(2) == 'connected'))
    # pipelines
    pp, ar, bu = one.get('prepare'), one.get('archive'), one.get('bundled')
    wr = [(int(m.group(1)), float(m.group(2))) for _, m, _ in g['written']]
    play = [(int(m.group(2)), float(m.group(3))) for _, m, _ in g['psoline'] if int(m.group(1)) > 300]   # the first window holds the prepare step's
    vk, gl = (g['vkpso'][-1][1] if g['vkpso'] else None), (g['glpso'][-1][1] if g['glpso'] else None)
    out['pipelines'] = {
        'prepare_s': prepare_s, 'prebuild': prebuild,
        'prepare': {'lines': int(pp.group(1)), 'progress_screen': pp.group(2) == 'shown', 'bases_compiled': int(pp.group(3)), 'bases_from_archive': int(pp.group(4)),
                    'reused': int(pp.group(5))} if pp else None,
        'archive': {'files': int(ar.group(1)), 'mb': float(ar.group(3)), 'open_ms': float(ar.group(4))} if ar else None,
        'bundled': {'mb': float(bu.group(1)), 'open_ms': float(bu.group(2))} if bu else 'left out' if 'bundle_out' in one else None,
        'written': {'files': len(wr), 'bases': sum(n for n, _ in wr), 'mb': round(sum(x for _, x in wr), 1)} if wr else None,
        'in_play': {'bases': sum(n for n, _ in play), 'ms': round(sum(x for _, x in play), 1)} if g['psoline'] else None,
        'vk': {'compiled': int(vk.group(6)), 'failed': sum(int(m.group(3)) for _, m, _ in g['vkpso']), 'waits': sum(int(m.group(4)) for _, m, _ in g['vkpso']),
               'wait_ms': round(sum(float(m.group(5)) for _, m, _ in g['vkpso']), 1)} if vk else None,
        'gl': {'built': int(gl.group(4)), 'ms': float(gl.group(5)), 'longest_ms': float(gl.group(6)), 'after_first_frame': int(gl.group(7)), 'after_ms': float(gl.group(8))} if gl else None}
    # frames on screen
    on = [m for _, m, _ in g['onscreen']]
    out['frames'] = None
    if g['timing'] or on:
        shown, dropped = sum(int(m.group(2)) for m in on), sum(int(m.group(3)) for m in on)
        ui_on = [WIN_UI.search(m.string) for m in on]; ui_t = [WIN_UI.search(m.string) for _, m, _ in g['timing']]   # the windows with frames made under the menu or out of focus
        sh_ui = sum(int(m.group(2)) for m, u in zip(on, ui_on) if u); dr_ui = sum(int(m.group(3)) for m, u in zip(on, ui_on) if u)
        out['frames'] = {'windows': len(g['timing']), 'p50_ms': med(col('timing', 2)), 'p95_ms': med(col('timing', 3)), 'p95_worst_ms': max(col('timing', 3), default=None),
                         'max_ms': max(col('timing', 4), default=None), 'p99_onscreen_ms': med(col('onscreen', 5)), 'p99_onscreen_worst_ms': max(col('onscreen', 5), default=None),
                         'gpu_p50_ms': med([float(m.group(6)) for _, m, _ in g['timing'] if m.group(6)]), 'on_screen': shown, 'dropped': dropped,
                         'discarded': sum(int(m.group(4)) for m in on), 'dropped_pct': round(100 * dropped / shown, 2) if shown else None, 'fps': med([fps for _, fps in power]),
                         'worst': [{'t_s': clock.at(int(m.group(1))), 'frame': int(m.group(1)), 'dropped': int(m.group(3)), 'p99_ms': float(m.group(5)), 'front_end': bool(WIN_UI.search(m.string))}
                                   for m in sorted(on, key=lambda m: -int(m.group(3)))[:top] if int(m.group(3))],
                         # the timing windows' counts (frames made), and the dropped frames of the on-screen windows that had any such frame, then the rate without those windows
                         'menu_frames': sum(int(u.group(1)) for u in ui_t if u), 'unfocused_frames': sum(int(u.group(2)) for u in ui_t if u),
                         'front_end_windows': sum(1 for u in ui_on if u), 'dropped_front_end': dr_ui,
                         'dropped_clean_pct': round(100 * (dropped - dr_ui) / (shown - sh_ui), 2) if shown - sh_ui else None}
    # power and heat
    out['power'] = None
    if power:
        starts = [power[0][0] - 300] + [f for f, _ in power]; dur = [(f - starts[k]) / fps if fps > 0 else 0.0 for k, (f, fps) in enumerate(power)]
        w = col('power', 2)
        out['power'] = {'windows': len(power), 'watts_p50': med(w), 'watts_mean': round(sum(a * d for a, d in zip(w, dur)) / sum(dur), 2) if sum(dur) else None,
                        'mj_per_frame_p50': med(col('power', 3)), 'cpu_pct_p50': med(col('power', 5)), 'pcore_pct_p50': med(col('power', 6)), 'wakeups_p50': med(col('power', 7)),
                        'gpu_busy_ms_s_p50': med([float(m.group(9)) for _, m, _ in g['power'] if m.group(10)]),
                        'gpu_ms_s_p50': med([float(m.group(11) or 0) if m.group(10) else float(m.group(9)) for _, m, _ in g['power']]),
                        'thermal_max': max(int(m.group(12)) for _, m, _ in g['power'])}
    fs = one.get('front_start')
    tl: list[Rec] = [{'t_s': 0.0, 'what': f'thermal state {fs.group(1)}, Low Power Mode {fs.group(2)}'}] if fs else []
    if not g['front_change']:   # a log without the front end's change lines (the Mac, an older app): the thermal state as the windows saw it
        th0 = int(fs.group(1)) if fs else 0
        for _, m, _ in g['onscreen'] or g['power']:
            th = int(m.group(8) if g['onscreen'] else m.group(12))
            if th != th0: tl.append({'t_s': clock.at(int(m.group(1))), 'what': f'thermal state {th} (a window\'s)'}); th0 = th
    tl += [{'t_s': e['t'], 'what': e['what']} for e in events if e['kind'] in ('power', 'cap')]
    out['timeline'] = sorted(tl, key=lambda x: x['t_s'])
    # memory
    fp = sorted([(int(m.group(1)), float(m.group(2))) for _, m, _ in g['memory']] + [(int(m.group(1)), float(m.group(6))) for m in on if int(m.group(6)) >= 0])

    def by_t(k: str, n: int, count: bool = False) -> Rec | None:
        return spread([(clock.at(int(m.group(1))), float(m.group(n))) for _, m, _ in g[k] if m.group(n) is not None],
                      *((PLATEAU_FLOOR_COUNT, PLATEAU_REL_COUNT) if count else (PLATEAU_FLOOR, PLATEAU_REL)))
    mem: Rec = {'footprint_mb': spread([(clock.at(f), v) for f, v in fp]), 'ledger_mb': by_t('memory', 4), 'guest_charged_mb': by_t('memory', 5),   # a newer line's fields (an older one: no samples, no entry)
                'gpu_mb': by_t('memory', 3), 'headroom_mb': by_t('memory', 7), 'shared_textures': by_t('memory', 6, True)}
    if g['glmem']: mem.update(footprint_mb=by_t('glmem', 2), gpu_mb=by_t('glmem', 3), gl_textures=by_t('glmem', 4, True))
    if g['vkframe']: mem['vk_buffer_mb'] = by_t('vkframe', 2)
    out['memory'] = {k: v for k, v in mem.items() if v} or None
    # long frames, read here: the display link's stretches count those before them
    lfs: list[Rec] = []
    for (i, m, _), after in zip(g['longframe'], lf_after):
        r: Rec = {'frame': int(m.group(1)), 't_s': float(m.group(2)), 'ms': float(m.group(3)), 'submit_ms': float(m.group(4)), 'gpu_ms': float(m.group(5)), 'pipelines': int(m.group(6)),
                  'libraries': int(m.group(7)), 'make_ms': float(m.group(8)), 'uploads': int(m.group(9)), 'reuploads': int(m.group(10)), 'upload_mb': float(m.group(11)),
                  'upload_ms': float(m.group(12)), 'hold': int(m.group(13)) if m.group(13) else None, 'vsync_ms': float(m.group(14)) if m.group(14) else None, 'i': i}
        ui = LF_UI.search(m.string.rstrip())
        if ui: r['front_end'] = ui.group(1)   # made with the in-game menu over the game or out of focus: counted apart
        r['causes'] = lf_causes(r, after, frame_ms); lfs.append(r)
    hold_frames(lfs, [(int(m.group(4)), int(m.group(2)), 1000 / 120 if m.group(3).startswith('ticks') else VSYNC_MS, int(m.group(1))) for _, m, _ in g['fstep']],
                fstep_cut(g['fstep_cut']))
    held_at = {r['i'] for r in lfs if 'held_ms' in r}
    ui_at = {r['i'] for r in lfs if 'front_end' in r and 'held_ms' not in r}
    for r in lfs: del r['i']
    # display-link latency
    win = [{'i': i, 't_s': clock.at(f or int(m.group(2))), 'p50': float(m.group(7)), 'max': float(m.group(9)), 'ahead': float(m.group(5)), 'ahead_min': float(m.group(6))}
           for i, m, f in g['link']]   # at the frame of the window's own lines before it (its presents only when none came before)
    out['display_link'] = None
    if win:
        base = round(statistics.median(x['p50'] for x in win), 3); lim = base + 0.5 * frame_ms; raised: list[Rec] = []; k = 0
        while k < len(win):
            if win[k]['p50'] <= lim: k += 1; continue
            j = k
            while j + 1 < len(win) and win[j + 1]['p50'] > lim: j += 1
            lo, hi = (win[k - 2]['i'] if k >= 2 else -1), win[k]['i']   # just before: since the window two before the first raised one
            nlf = sum(1 for i, _, _ in g['longframe'] if lo < i < hi and i not in held_at and i not in ui_at); nh = sum(1 for i in held_at if lo < i < hi)
            nui = sum(1 for i in ui_at if lo < i < hi)
            raised.append({'from_s': win[k - 1]['t_s'] if k else 0.0, 'to_s': win[j]['t_s'], 'windows': j - k + 1, 'p50_max_ms': max(x['p50'] for x in win[k:j + 1]),
                           'before': list(dict.fromkeys(e['what'] for e in events if lo < e['i'] < hi)) + ([nof(nlf, 'long frame')] if nlf else [])
                           + ([nof(nh, 'frame') + ' at the hold the frame step asked'] if nh else [])
                           + ([nof(nui, 'long frame') + ' with the in-game menu open or out of focus'] if nui else []), 'to_the_end': j == len(win) - 1})
            k = j + 1
        lm = g['link'][-1][1]
        out['display_link'] = {'windows': len(win), 'frame_ms': round(frame_ms, 2), 'enqueue_p50_ms': base, 'enqueue_max_ms': max(x['max'] for x in win),
                               'ahead_p50_ms': med([x['ahead'] for x in win]), 'ahead_min_ms': min(x['ahead_min'] for x in win),
                               'empty_ticks': int(lm.group(3)), 'merged': int(lm.group(4)), 'raised': raised, 'p50_by_window': [[x['t_s'], x['p50']] for x in win]}
    # long frames: the frames the frame step held as long as it asked are not counted (hold_frames), nor those made with the in-game menu over the game or out of focus (LF_UI):
    # those are counted apart, by what the front end had over the game
    game = [r for r in lfs if 'held_ms' not in r and 'front_end' not in r]
    by = collections.Counter(next(key for word, key in CAUSE_KEY if r['causes'][0].startswith(word)) for r in game)
    mins_run = (out['duration_s'] or 0) / 60
    nl = sum(by.values()); ui_by = collections.Counter(r['front_end'] for r in lfs if 'held_ms' not in r and 'front_end' in r)
    out['long_frames'] = {'count': nl, 'per_min': round(nl / mins_run, 2) if mins_run else None, 'by_cause': dict(by.most_common()), 'held': sum(1 for r in lfs if 'held_ms' in r),
                          'front_end': sum(ui_by.values()), 'front_end_by': dict(ui_by.most_common()), 'with_front_end': nl + sum(ui_by.values()),
                          'top': sorted(game, key=lambda r: -r['ms'])[:top]} if lfs else None
    # events
    sus = [e for e in events if e['what'] == 'graphics suspended'] or [e for e in events if e['what'] == 'background']
    res = [e for e in events if e['what'] == 'resumed']
    out['events'] = {'background': len(sus), 'resumed': len(res), 'focus_changes': sum(1 for e in events if e['kind'] == 'focus'),
                     'ended_in_background': bool(sus) and (not res or res[-1]['i'] < sus[-1]['i']),
                     'list': [{'t_s': e['t'], 'what': e['what']} for e in events if e['kind'] in ('app', 'focus', 'audio', 'menu', 'controller', 'memory')],
                     'menu_long': menu_long(g['front_menu'], clock, out['duration_s'])}
    # audio, saves, RED
    au = g['audio']
    out['audio'] = {'callbacks': sum(int(m.group(3)) for _, m, _ in au), 'underruns': sum(int(m.group(4)) for _, m, _ in au),
                    'zero_padded_ms': round(sum(float(m.group(5)) for _, m, _ in au), 1), 'game_reports': len(g['game_underrun']),
                    'windows': [{'t_s': clock.at(f), 'stream': int(m.group(1)), 'underruns': int(m.group(4)), 'ms': float(m.group(5))} for _, m, f in au if int(m.group(4))][:top]
                    } if au or g['game_underrun'] else None
    # the output's buffer and latency: what iOS granted (at boot and each return, after each route change and its re-request, as it settled) and the Mac device's latency
    io = [float(m.group(2)) for _, m, _ in g['au_session']] + [float(m.group(7) or m.group(4)) for _, m, _ in g['au_route']] + col('au_settle', 1)
    lat = [float(m.group(3)) for _, m, _ in g['au_session'] if m.group(3)] + [float(m.group(8) or m.group(5)) for _, m, _ in g['au_route']] + col('au_settle', 3)
    dev = col('au_device', 2)
    out['audio_output'] = {'io_buffer_ms_max': max(io, default=None), 'output_latency_ms_max': max(lat, default=None), 'route_changes': len(g['au_route']),
                           'routes': list(dict.fromkeys(m.group(2) for _, m, _ in g['au_route'])), 'device_latency_ms_max': max(dev, default=None)} if io or lat or dev else None
    sc, ss = g['save_commit'], g['save_sync']
    out['saves'] = {'commits': len(sc), 'commit_us_max': max((int(m.group(2)) for _, m, _ in sc), default=None),
                    'sync': dict(collections.Counter(re.split(r'[:,;]', norm(m.group(1)))[0] for _, m, _ in ss).most_common())} if sc or ss else None
    # movies: VideoToolbox's VP9 check, each AAC stream's channel order, sessions made again after iOS lost them (their red lines are in RED)
    vp, aac, vt = one.get('vp9_vt'), g['aac_order'], g['vt_rebuild']
    out['movies'] = {'vp9_hardware': vp.group(1) == 'yes' if vp else None, 'vp9_before_register': vp.group(2) == 'yes' if vp else None,
                     'os': f'{vp.group(3)} {vp.group(4)}'.strip() if vp else None, 'model': vp.group(6) if vp else None,
                     'aac': [{'channels': int(m.group(1)), 'audiotoolbox': m.group(2), 'console': m.group(4) or m.group(5) or m.group(2),
                              'set': {'handed out in': 'reordered', 'already': 'already', 'kept': 'kept (DM_AAC_LAYOUT=0)'}[m.group(3)]} for _, m, _ in aac],
                     'vt_rebuilds': len(vt), 'vt_refed': sum(int(m.group(4)) for _, m, _ in vt)} if vp or aac or vt else None
    out['red'] = {'lines': sum(red.values()), 'kinds': dict(red.most_common())}
    out['crash'] = crash
    return out


# ---------------------------------------------------------------- text

def g3(v: Any) -> str:   # a number as the log gives it, short
    if v is None: return '–'
    if isinstance(v, bool): return 'yes' if v else 'no'
    if isinstance(v, float): return f'{v:.4g}' if abs(v) < 1e4 else f'{v:.0f}'
    return str(v)


def nof(n: int, word: str) -> str: return f'{n} {word}' + ('' if n == 1 else 'es' if word.endswith('s') else 's')


def mins(s: float | None) -> str: return '–' if s is None else f'{s:.0f} s' if s < 120 else f'{s / 60:.1f} min'


def wrap(items: list[str], width: int = 120) -> list[str]:
    out, cur = [], ''
    for x in items:
        if cur and len(cur) + 2 + len(x) > width: out.append(cur + ','); cur = x
        else: cur = f'{cur}, {x}' if cur else x
    return out + ([cur] if cur else [])


def at_times(evs: list[Rec], limit: int) -> list[str]:   # events grouped by the second they came at: "1218 s: focus 2, background, …"
    groups: list[tuple[float, list[str]]] = []
    for e in evs:
        if groups and abs(groups[-1][0] - e['t_s']) < 1: groups[-1][1].append(e['what'])
        else: groups.append((e['t_s'], [e['what']]))
    out = [f"{t:.0f} s: {', '.join(dict.fromkeys(ws))}" for t, ws in groups[:limit]]
    return out + ([f'… {len(groups) - limit} more'] if len(groups) > limit else [])


def spread_text(x: Rec | None, unit: str = ' MB') -> str:
    if not x: return '–'
    if len(x.get('plateaus') or ()) > 1:   # in steps: the run's slope would be the steps'; the drift within the plateaus instead
        d = f", {x['drift_per_10min']:+g}{unit} per 10 min within them" if x['drift_per_10min'] is not None else ''
        return f"{x['first']:g} → {x['last']:g}{unit} (least {x['min']:g}, most {x['max']:g}), {len(x['plateaus'])} plateaus{d}:"
    slope = f", {x['per_10min']:+g}{unit} per 10 min" if x['per_10min'] is not None else ''
    return f"{x['first']:g} → {x['last']:g}{unit} (least {x['min']:g}, most {x['max']:g}{slope})"


def plateau_text(x: Rec | None, limit: int, unit: str = ' MB') -> list[str]:   # the plateaus of a series in steps, a line or more under it: "21–200 s 765 MB, 204–262 s 2830 MB, …"
    ps = (x or {}).get('plateaus') or []
    if len(ps) < 2: return []
    items = [(f"{p['from_s']:.0f}–{p['to_s']:.0f} s" if p['to_s'] > p['from_s'] else f"{p['from_s']:.0f} s") + f" {p['median']:g}{unit}"
             + (f" ({p['min']:g}–{p['max']:g})" if p['samples'] > 2 and p['max'] - p['min'] > 0.1 * p['median'] else '') for p in ps[:limit]]
    return ['  ' + t for t in wrap(items + ([f'… {len(ps) - limit} more'] if len(ps) > limit else []), 118)]


def title(s: Rec) -> str:
    b = s['build'] or {}
    return (f"{b.get('name') or 'game'} ({b.get('profile') or 'no build line'}): {s['lines']} lines, up to frame {s['last_frame']}, about {mins(s['duration_s'])} in "
            f"(times from {s['time_basis']})")


def render(s: Rec, top: int) -> list[str]:
    L = [title(s)]

    def row(label: str, *texts: str) -> None:
        for k, t in enumerate(x for x in texts if x): L.append(f"{label if k == 0 else '':<13}{t}")
    b, d, p, f = s['build'] or {}, s['device'], s['pipelines'], s['frames']
    row('build', f"commit {b['commit']}, shader chain {b['chain']}" + (f", {d['sdk']}" if d['sdk'] else '') if b else 'no build line')
    row('device', ', '.join(x for x in (d['gpu'], d['arch'], d['family'] and f"GPU family {d['family']}", d['metal4'] and f"Metal 4 {d['metal4']}") if x) or 'no GPU line',
        f"{d['memory_gb']:.2f} GB for the app, Extended Virtual Addressing {'in effect' if d['eva'] else 'not in effect'}"
        + (f", largest address block {d['address_space_gb']:.2f} GB" if d['address_space_gb'] else '') if d['memory_gb'] is not None else '')
    row('graphics', API.get(s['api'] or '', 'graphics API not in the log') + (f", present tick {s['present']}" if s['present'] else ''))
    row('controller', ', '.join(s['controllers']) or 'none connected (touch controls)')
    sw = [f'{k}={v}' + ('' if s['env_from'].get(k) == 'default' else f" ({s['env_from'][k]})") for k, v in sorted(s['env'].items())]
    row('switches', *(wrap(sw) or ['no launcher or env lines']), *(f"{c['t_s']:.0f} s: {c['key']}={c['value']} (in-game menu)" for c in s['env_changes']))
    pr, pb, ar, wr, ip = p['prepare'], p['prebuild'], p['archive'], p['written'], p['in_play']
    done = 'done' if not pb or pb.get('done') else f"not done in the log, at {pb.get('at', 0):.0f} of"
    ptexts = (
        f"prepare {p['prepare_s']:g} s" + (f" ({pr['lines']} lines, progress screen {'shown' if pr['progress_screen'] else 'not shown'}; bases {pr['bases_compiled']} compiled, "
                                          f"{pr['bases_from_archive']} from the archive, {pr['reused']} reused)" if pr else '') if p['prepare_s'] is not None else '',
        f"prebuild {done}: {pb['pairs']:.0f} pairs, {pb['built']:.0f} built, {pb['archived']:.0f} already archived, {pb['failed']:.0f} failed, "
        f"{pb['secs']:g} s" if pb else '',
        ', '.join(x for x in (f"archive {ar['files']} files, {ar['mb']:g} MB (opened in {ar['open_ms']:g} ms)" if ar else '',
                              f"the app's own archive {p['bundled']['mb']:g} MB" if isinstance(p['bundled'], dict) else "the app's own archive left out" if p['bundled'] else '',
                              f"written this run {wr['bases']} bases in {wr['files']} files, {wr['mb']:g} MB" if wr else '',
                              f"compiled while playing {ip['bases']} bases ({ip['ms'] / 1000:.3g} s of compiling, all threads)" if ip else '') if x),
        f"Vulkan: {p['vk']['compiled']} compiled, {p['vk']['failed']} failed, submissions waited {p['vk']['waits']} times, {p['vk']['wait_ms']:g} ms" if p['vk'] else '',
        f"OpenGL: {p['gl']['built']} built in {p['gl']['ms']:g} ms (longest {p['gl']['longest_ms']:g} ms), {p['gl']['after_first_frame']} after the first frame, {p['gl']['after_ms']:g} ms"
        if p['gl'] else '')
    row('pipelines', *([x for x in ptexts if x] or ['no pipeline lines']))
    if f:
        row('frames', f"{f['windows']} windows: frame time p50 {g3(f['p50_ms'])} ms, p95 {g3(f['p95_ms'])} (worst window {g3(f['p95_worst_ms'])}), on screen p99 {g3(f['p99_onscreen_ms'])} "
                      f"(worst {g3(f['p99_onscreen_worst_ms'])}), longest {g3(f['max_ms'])} ms; GPU p50 {g3(f['gpu_p50_ms'])} ms",
            f"{f['on_screen']} frames on screen, {f['dropped']} dropped ({g3(f['dropped_pct'])}%), {f['discarded']} of them discarded; {g3(f['fps'])} fps (the power windows' median)",
            f"{f['menu_frames']} frames made with the in-game menu open, {f['unfocused_frames']} out of focus: {f['dropped_front_end']} of the dropped frames are in the "
            f"{nof(f['front_end_windows'], 'window')} that had any; {g3(f['dropped_clean_pct'])}% dropped without those windows" if f['front_end_windows'] or f['menu_frames'] or f['unfocused_frames'] else '',
            'worst windows: ' + '; '.join(f"{w['t_s']:.0f} s {w['dropped']} dropped (p99 {w['p99_ms']:g} ms{', in-game menu or out of focus' if w['front_end'] else ''})" for w in f['worst']) if f['worst'] else '')
    else: row('frames', 'no on-screen or timing lines (they come from NVN\'s present: a Vulkan or OpenGL game has none)')
    pw = s['power']
    ios0 = '; iOS leaves it at 0' if pw and not pw['gpu_ms_s_p50'] else ''   # named only where the system's count is 0: the Mac fills it
    if pw: row('power', f"CPU {g3(pw['watts_p50'])} W (median; {g3(pw['watts_mean'])} W over the run), {g3(pw['mj_per_frame_p50'])} mJ per frame, CPU {g3(pw['cpu_pct_p50'])}% of a core "
                        f"({g3(pw['pcore_pct_p50'])}% on performance cores), wakeups {g3(pw['wakeups_p50'])}/s, "
                        + (f"GPU {g3(pw['gpu_busy_ms_s_p50'])} ms/s busy (the system's count {g3(pw['gpu_ms_s_p50'])}{ios0})" if pw.get('gpu_busy_ms_s_p50') is not None
                           else f"GPU {g3(pw['gpu_ms_s_p50'])} ms/s by the system's count ({ios0[2:] + '; ' if ios0 else ''}an older log, before the host's own busy time)")
                        + f"; thermal state at most {pw['thermal_max']}")
    row('heat', *(at_times([{'t_s': x['t_s'], 'what': x['what']} for x in s['timeline']], 3 * top) or ['no thermal or Low Power Mode lines']))
    mm = s['memory'] or {}
    gpu_label = 'GPU allocated (counts the guest\'s pools again)' if 'ledger_mb' in mm or 'guest_charged_mb' in mm else 'GPU allocated'   # the ledger and guest charged first, where the log has them
    row('memory', *(t for k, label, unit in (('footprint_mb', 'footprint', ' MB'), ('ledger_mb', 'graphics ledger', ' MB'), ('guest_charged_mb', 'guest charged', ' MB'),
                                             ('gpu_mb', gpu_label, ' MB'), ('headroom_mb', 'headroom to the limit', ' MB'),
                                             ('shared_textures', 'shared textures', ''), ('gl_textures', 'OpenGL textures', ''), ('vk_buffer_mb', 'Vulkan buffers', ' MB')) if k in mm
                    for t in [f'{label} {spread_text(mm[k], unit)}', *plateau_text(mm[k], 2 * top, unit)]))
    if not mm: row('memory', 'no memory lines')
    dl = s['display_link']
    if dl:
        row('display link', f"game enqueue to target display p50 {g3(dl['enqueue_p50_ms'])} ms (median of {dl['windows']} windows; most {g3(dl['enqueue_max_ms'])}), submission ahead "
                            f"{g3(dl['ahead_p50_ms'])} ms (least {g3(dl['ahead_min_ms'])}); {nof(dl['empty_ticks'], 'empty tick')}, {dl['merged']} merged",
            *(f"{r['from_s']:.0f}–{r['to_s']:.0f} s: {nof(r['windows'], 'window')} up to {g3(r['p50_max_ms'])} ms{', to the end' if r['to_the_end'] else ''}; just before: "
              f"{', '.join(r['before']) or 'nothing in the log'}" for r in dl['raised'][:3 * top]))
        if not dl['raised']: row('', f"no window more than half a frame ({g3(dl['frame_ms'] / 2)} ms) above the median")
    lf = s['long_frames']
    if lf:
        row('long frames', f"{lf['count']} ({g3(lf['per_min'])} a minute)" + (': ' + ', '.join(f'{k} {n}' for k, n in lf['by_cause'].items()) + ' (by what each spent its time on first)'
                                                                               if lf['by_cause'] else ''),
            f"not counted: {nof(lf['held'], 'frame')} as long as the frame step's hold of 2 or 3 vsyncs asked, just after a step up" if lf.get('held') else '',
            f"not counted: {nof(lf['front_end'], 'frame')} made with the in-game menu open or out of focus (" + '; '.join(f'{k} {n}' for k, n in lf['front_end_by'].items()) + ')'
            if lf.get('front_end') else '',
            *(f"{r['t_s']:.0f} s frame {r['frame']}: {r['ms']:g} ms, {'; '.join(r['causes'])}" for r in lf['top']))
    ev = s['events']
    row('events', f"in the background {nof(ev['background'], 'time')}, back {ev['resumed']}, {nof(ev['focus_changes'], 'focus change')}" + ('; the log ends in the background' if ev['ended_in_background'] else ''),
        *(f"the in-game menu was open {x['open_s']:g} s from {x['t_s']:.0f} s" + ('' if x['closed'] else ' and never closed in the log') + ': a close may have been missed, and the long'
          ' frames and windows tagged as made under it may be the game\'s' for x in ev.get('menu_long', [])),
        *at_times(ev['list'], 3 * top))
    au = s['audio']
    if au: row('audio', f"{au['underruns']} underruns in {au['callbacks']} device callbacks ({au['zero_padded_ms']:g} ms zero-padded)" + (f"; the game reported {au['game_reports']}" if au['game_reports'] else ''),
               *(f"{w['t_s']:.0f} s: {w['underruns']} (stream #{w['stream']}, {w['ms']:g} ms)" for w in au['windows']))
    ao = s['audio_output']
    if ao: row('audio output', ', '.join(x for x in (f"I/O buffer at most {ao['io_buffer_ms_max']:g} ms" if ao['io_buffer_ms_max'] is not None else '',
                                                     f"output latency at most {ao['output_latency_ms_max']:g} ms" if ao['output_latency_ms_max'] is not None else '',
                                                     f"{nof(ao['route_changes'], 'route change')} ({', '.join(ao['routes'])})" if ao['route_changes'] else '',
                                                     f"device latency at most {ao['device_latency_ms_max']:g} ms" if ao['device_latency_ms_max'] is not None else '') if x))
    sv = s['saves']
    if sv: row('saves', f"{nof(sv['commits'], 'commit')}" + (f" (longest clone + swap {sv['commit_us_max'] / 1000:g} ms)" if sv['commit_us_max'] else '')
               + (', save sync: ' + ', '.join(f'{k} {n}' for k, n in sv['sync'].items()) if sv['sync'] else ''))
    mv = s.get('movies')
    if mv:
        row('movies', f"VP9 hardware decoder in VideoToolbox: {'yes' if mv['vp9_hardware'] else 'no'} ({mv['os']}, {mv['model'] or 'model not given'}; VP9 decodes with libvpx)"
            if mv['vp9_hardware'] is not None else '',
            *(f"AAC {a['channels']} channels: AudioToolbox's order {a['audiotoolbox']}, " + (f"handed out as {a['console']}" if a['set'] == 'reordered' else
              'the console\'s already' if a['set'] == 'already' else f"kept (DM_AAC_LAYOUT=0), the console's {a['console']}") for a in mv['aac']),
            f"VideoToolbox sessions made again: {mv['vt_rebuilds']} ({mv['vt_refed']} packets decoded again)" if mv['vt_rebuilds'] else '')
    rd = s['red']
    row('RED', f"{nof(rd['lines'], 'line')} of {nof(len(rd['kinds']), 'kind')}" + (':' if rd['kinds'] else ''), *(f'{n}× {k}' for k, n in list(rd['kinds'].items())[:top]))
    if s['crash']: row('crash', s['crash'])
    return L


# ---------------------------------------------------------------- two logs

# (label, path in the summary, direction: -1 lower is better, +1 higher is better, 0 neither, as for the totals that grow with a run's length)
METRICS = (('commit', 'build.commit', 0), ('shader chain', 'build.chain', 0), ('profile', 'build.profile', 0), ('GPU', 'device.gpu', 0), ('architecture', 'device.arch', 0),
           ('GPU family', 'device.family', 0), ('memory for the app (GB)', 'device.memory_gb', 0), ('graphics', 'api', 0), ('present', 'present', 0),
           ('frames', 'last_frame', 0), ('duration (s)', 'duration_s', 0),
           ('prepare (s)', 'pipelines.prepare_s', -1), ('prebuild (s)', 'pipelines.prebuild.secs', -1), ('archive files', 'pipelines.archive.files', 0), ('archive (MB)', 'pipelines.archive.mb', 0),
           ('bases written', 'pipelines.written.bases', 0), ('bases compiled while playing', 'pipelines.in_play.bases', 0),
           ('frame time p50 (ms)', 'frames.p50_ms', -1), ('frame time p95 (ms)', 'frames.p95_ms', -1), ('worst window p95 (ms)', 'frames.p95_worst_ms', -1),
           ('on-screen p99 (ms)', 'frames.p99_onscreen_ms', -1), ('worst window p99 (ms)', 'frames.p99_onscreen_worst_ms', -1), ('longest frame (ms)', 'frames.max_ms', -1),
           ('dropped (%)', 'frames.dropped_pct', -1), ('dropped, menu / focus windows out (%)', 'frames.dropped_clean_pct', -1), ('frames per second', 'frames.fps', 1),
           ('GPU p50 (ms)', 'frames.gpu_p50_ms', -1), ('frames with the in-game menu open', 'frames.menu_frames', 0),
           ('CPU W (median)', 'power.watts_p50', -1), ('CPU W (over the run)', 'power.watts_mean', -1), ('mJ per frame', 'power.mj_per_frame_p50', -1), ('CPU % of a core', 'power.cpu_pct_p50', -1),
           ('on performance cores (%)', 'power.pcore_pct_p50', 0), ('wakeups per second', 'power.wakeups_p50', -1), ('GPU ms/s busy', 'power.gpu_busy_ms_s_p50', -1),
           ('GPU ms/s, the system\'s count', 'power.gpu_ms_s_p50', -1), ('thermal state at most', 'power.thermal_max', -1),
           ('footprint, last (MB)', 'memory.footprint_mb.last', 0), ('footprint, most (MB)', 'memory.footprint_mb.max', 0), ('footprint plateaus', 'memory.footprint_mb.plateaus', 0),
           ('footprint drift / 10 min (MB)', 'memory.footprint_mb.drift_per_10min', -1),   # within the plateaus: the steps of area loads are not a leak
           ('graphics ledger, last (MB)', 'memory.ledger_mb.last', -1), ('graphics ledger, most (MB)', 'memory.ledger_mb.max', -1),   # newer logs: the memory to compare (GPU allocated counts the guest twice)
           ('graphics ledger drift / 10 min', 'memory.ledger_mb.drift_per_10min', -1),
           ('guest charged, last (MB)', 'memory.guest_charged_mb.last', -1), ('guest charged, most (MB)', 'memory.guest_charged_mb.max', -1),
           ('guest charged drift / 10 min', 'memory.guest_charged_mb.drift_per_10min', -1),
           ('GPU allocated, last (MB)', 'memory.gpu_mb.last', 0), ('GPU allocated drift / 10 min', 'memory.gpu_mb.drift_per_10min', -1), ('headroom, least (MB)', 'memory.headroom_mb.min', 1),
           ('shared textures, last', 'memory.shared_textures.last', 0), ('shared textures drift / 10 min', 'memory.shared_textures.drift_per_10min', -1),
           ('enqueue to display p50 (ms)', 'display_link.enqueue_p50_ms', -1), ('enqueue to display, most (ms)', 'display_link.enqueue_max_ms', -1),
           ('submission ahead p50 (ms)', 'display_link.ahead_p50_ms', 0), ('stretches a frame above', 'display_link.raised', -1),
           ('long frames', 'long_frames.count', 0), ('long frames per minute', 'long_frames.per_min', -1), ('frames at the step\'s hold', 'long_frames.held', 0),
           ('long frames under the menu / out of focus', 'long_frames.front_end', 0),
           ('long frames, menu / focus ones too', 'long_frames.with_front_end', 0),   # like for like with a log from before the tags, whose long frames count them all
           ('background / back', 'events.background', 0), ('focus changes', 'events.focus_changes', 0),
           ('audio underruns', 'audio.underruns', -1), ('audio I/O buffer, most (ms)', 'audio_output.io_buffer_ms_max', -1),
           ('audio output latency, most (ms)', 'audio_output.output_latency_ms_max', -1), ('save commits', 'saves.commits', 0),
           ('VideoToolbox sessions made again', 'movies.vt_rebuilds', 0), ('[RED] lines', 'red.lines', -1), ('[RED] kinds', 'red.kinds', -1))


def dig(s: Any, path: str) -> Any:
    for k in path.split('.'): s = s.get(k) if isinstance(s, dict) else None
    return len(s) if isinstance(s, (list, dict)) else s


COUNTS = {'thermal state at most', 'stretches a frame above', 'audio underruns', 'VideoToolbox sessions made again', '[RED] lines', '[RED] kinds'}   # counts: from none, any is a change
FLOOR = {'prepare (s)': 0.5, 'prebuild (s)': 0.5}   # seconds under this are the noise of a start (an archive hit reads 0)


def change(a: Any, b: Any, sense: int, label: str = '') -> str:
    if a == b: return ''
    if isinstance(a, bool) or isinstance(b, bool) or not isinstance(a, (int, float)) or not isinstance(b, (int, float)): return 'differs'
    d = b - a; rel = d / abs(a) if a else None
    # a tenth: the noise of one run against another; from 0 there is no tenth, so only a count says better or worse
    noise = (abs(rel) < 0.1 if rel is not None else label not in COUNTS) or abs(d) < FLOOR.get(label, 0)
    word = '' if not sense or noise else ' better' if d * sense > 0 else ' worse'
    return f'{d:+.4g}' + (f' ({rel:+.0%})' if rel is not None else '') + word


def compare(a: Rec, b: Rec) -> Rec:
    rows = [{'label': lb, 'a': dig(a, p), 'b': dig(b, p), 'change': change(dig(a, p), dig(b, p), sense, lb)} for lb, p, sense in METRICS if dig(a, p) is not None or dig(b, p) is not None]
    keys = sorted(set(a['env']) | set(b['env']))
    sw = {k: [a['env'].get(k), b['env'].get(k)] for k in keys if a['env'].get(k) != b['env'].get(k)}
    ra, rb = a['red']['kinds'], b['red']['kinds']
    red = {'only_a': {k: n for k, n in ra.items() if k not in rb}, 'only_b': {k: n for k, n in rb.items() if k not in ra},
           'changed': {k: [ra[k], rb[k]] for k in ra if k in rb and ra[k] != rb[k]}}
    return {'rows': rows, 'switches': sw, 'red': red}


def render_pair(a: Rec, b: Rec, c: Rec, names: tuple[str, str], top: int) -> list[str]:
    w = max(16, min(30, max(len(g3(r[k])) for r in c['rows'] for k in ('a', 'b')) + 1))
    L = [f'A {names[0]}: {title(a)}', f'B {names[1]}: {title(b)}', '', f"{'':<32}{'A':>{w}}{'B':>{w}}  change"]
    L += [f"{r['label']:<32}{g3(r['a'])[:w - 1]:>{w}}{g3(r['b'])[:w - 1]:>{w}}  {r['change']}" for r in c['rows']]
    if c['switches']: L += ['', 'switches that differ (A | B):'] + [f'  {k}: {g3(va)} | {g3(vb)}' for k, (va, vb) in c['switches'].items()]
    else: L += ['', 'the same switches']
    for side, s in (('A', a), ('B', b)):
        if s['env_changes']: L.append(f'{side} in-game menu: ' + ', '.join(f"{x['t_s']:.0f} s {x['key']}={x['value']}" for x in s['env_changes']))
    rd = c['red']
    for label, d in (('[RED] kinds only in A', rd['only_a']), ('[RED] kinds only in B', rd['only_b'])):
        if d: L += ['', f'{label}:'] + [f'  {n}× {k}' for k, n in list(d.items())[:top]] + ([f'  … {len(d) - top} more'] if len(d) > top else [])
    if rd['changed']: L += ['', '[RED] kinds in both, other counts (A | B):'] + [f'  {na} | {nb}  {k}' for k, (na, nb) in list(rd['changed'].items())[:top]]
    for side, s in (('A', a), ('B', b)):
        dl, lf = s['display_link'], s['long_frames']
        for r in (dl or {}).get('raised', [])[:top]:
            L.append(f"{side} display link {r['from_s']:.0f}–{r['to_s']:.0f} s up to {r['p50_max_ms']:g} ms; just before: {', '.join(r['before']) or 'nothing in the log'}")
        if lf: L.append(f'{side} longest frames: ' + '; '.join(f"{r['t_s']:.0f} s {r['ms']:g} ms: {r['causes'][0]}" for r in lf['top']))
    return L


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description='Summarize an iPhone or iPad log.txt, or compare two.', epilog='Documented in docs/development.md, Reading a device log.')
    ap.add_argument('logs', nargs='+', metavar='LOG', help='one log for a summary, two to compare')
    ap.add_argument('--top', type=int, default=5, metavar='N', help='how many of the longest frames, [RED] kinds and worst windows to list (default 5)')
    ap.add_argument('--json', action='store_true', help='machine-readable output')
    a = ap.parse_args(argv)
    if len(a.logs) > 2: ap.error('one log, or two to compare')
    sums = []
    for p in a.logs:
        try: sums.append(read(Path(p).read_text(errors='replace'), max(1, a.top)))
        except OSError as e: print(f'devlog: cannot read {p}: {e.strerror or e}', file=sys.stderr); return 2
    if len(sums) == 1: print(json.dumps(sums[0], indent=1) if a.json else '\n'.join(render(sums[0], max(1, a.top))))
    else:
        c = compare(*sums)
        print(json.dumps({'a': sums[0], 'b': sums[1], **c}, indent=1) if a.json else '\n'.join(render_pair(sums[0], sums[1], c, (Path(a.logs[0]).name, Path(a.logs[1]).name), max(1, a.top))))
    return 0


if __name__ == '__main__':
    sys.exit(main())
