"""The iOS audio session's route, latency and lifecycle handling (front_ios.m), checked in the sources off the device: the route-change observer, delivered on the main
queue, that logs one line and asks for 48 kHz and 5 ms again (DM_AUDIO_ROUTE_REAPPLY), the output latency on the session line, the once-per-route warning against the audio
renderer's queue as hle_audren.c keeps it (audio_route.h), and every audio notice and scene event (the interruption notice, iOS 27's lifecycle notices under
DM_AUDIO_LIFECYCLE, the media services reset, the background, the return, the focus) going through audio_lifecycle.h's state machine to the one dm_audio_suspend call.

The plain-C rules run in dm/host/tests/t_audio_route.c (make audio-route), the lifecycle's transitions in t_audio_lifecycle.c (make audio-lifecycle), both also here, and
the Mac device's latency in t_audio_device.c. What none of them runs: which notices iOS 27.3 actually posts, in what order, and what it grants on each route (the device
test in docs/reference/audio.md)."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the function or block whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


def c_compiler():
    return os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc') or ''


def code(src):
    """src without its // comments"""
    return re.sub(r'//[^\n]*', '', src)


def observer(src, name):
    """The block of the observer for notification name, and the queue it is delivered on"""
    m = re.search(r'\[nc addObserverForName:' + name + r' object:nil queue:(\S+) usingBlock:\^\(NSNotification \*n\) ', src)
    assert m, name
    return body(src, m.group(0)), m.group(1)


class AudioSession(unittest.TestCase):
    def setUp(self):
        self.front = read('dm/ios/Sources/front_ios.m')
        self.watch = code(body(self.front, 'static void front_ios_audio_watch(void) {'))

    def test_route_changes_are_observed_on_the_main_queue_and_ask_again(self):
        block, queue = observer(self.watch, 'AVAudioSessionRouteChangeNotification')
        self.assertEqual(queue, 'NSOperationQueue.mainQueue')   # iOS posts it on a secondary thread
        self.assertIn('front_ios_audio_route([n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue]);', block)
        route = code(body(self.front, 'static void front_ios_audio_route(NSUInteger reason) {'))
        self.assertIn('getenv("DM_AUDIO_ROUTE_REAPPLY")', route)
        self.assertIn('[s setPreferredSampleRate:48000 error:nil];', route)
        self.assertIn('ok = [s setPreferredIOBufferDuration:0.005 error:&err];', route)
        self.assertLess(route.index('s.IOBufferDuration * 1000, lat = s.outputLatency'), route.index('setPreferredIOBufferDuration'))   # read before asking again: the line has both
        self.assertEqual(route.count('LOG('), 1)   # one line per route change
        self.assertIn('if (g_route_lines < ROUTE_LINES) {', route)   # and a bound on them
        line = re.search(r'LOG\("(%saudio route changed[^"]*)"', route).group(1)
        for part in ('(%s)', 'output %s', 'sample rate %.0f Hz', 'I/O buffer %.2f ms', 'output latency %.1f ms'): self.assertIn(part, line)
        self.assertIn('route_reason(reason)', route); self.assertIn('route_outputs(s.currentRoute)', route)
        self.assertIn('now - g_route_asked < 1.0', route)   # a request that itself changes the route does not ask again
        self.assertTrue(route.rstrip('}\n ').endswith('front_ios_audio_settle(s.IOBufferDuration * 1000);'))
        outputs = body(self.front, 'static NSString *route_outputs(AVAudioSessionRouteDescription *r) {')
        self.assertIn('p.portType', outputs); self.assertNotIn('portName', outputs)   # a port's name can be its owner's
        self.assertIn('p.UID', body(self.front, 'static NSString *route_key(AVAudioSessionRouteDescription *r) {'))

    def test_session_line_has_the_output_latency_and_settles(self):
        session = code(body(self.front, 'void front_ios_audio_session(void) {'))
        self.assertIn('"audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for 5 ms), output latency %.1f ms", s.sampleRate, s.IOBufferDuration * 1000, s.outputLatency * 1000', session)
        self.assertIn('front_ios_audio_settle(s.IOBufferDuration * 1000);', session)
        # the activation's outcome goes to the lifecycle, which may end an interruption with it (a reset, a deactivation no other app caused)
        self.assertIn('BOOL ok = [s setActive:YES error:&e];\n    int ended = audio_life_activated(&g_life, ok);', session)
        self.assertIn('if (ended) LOG("audio session: active again after %s; resuming"', session)

    def test_a_buffer_longer_than_the_renderer_queue_is_red_once_per_route(self):
        settle = code(body(self.front, 'static void front_ios_audio_settle(double granted_ms) {'))
        self.assertIn('dispatch_get_main_queue()', settle)
        # not while the session is not the one playing: the buffer is then another session's
        self.assertIn('if (!audio_life_quiet(&g_life) && audren_buffer_over_queue(io) && audio_route_first(&g_route_warned, route_key(r).UTF8String)) {', settle)
        self.assertIn('g_route_lines == ROUTE_LINES ? "; route lines not logged from here on" : ""', settle)   # the settle line can take the last of the route lines
        self.assertIn('LOG("[RED] audio session: the I/O buffer of %.2f ms on %s is longer than %s:', settle)
        self.assertIn('#include "audio_route.h"', self.front)
        # the queue the warning names is the one the renderer keeps: hle_audren.c takes its block count and its silent block's length from audio_route.h
        audren = read('dm/host/hle_audren.c')
        self.assertIn('#include "audio_route.h"', audren)
        self.assertIn('NBUF = AUDREN_NBUF };', audren)
        self.assertIn('int n = got ? got : AUDREN_BLOCK_FRAMES;', audren)
        self.assertNotRegex(code(audren), r'\b240\b')
        self.assertRegex(read('dm/host/audio_route.h'), r'enum \{ AUDREN_NBUF = 4, AUDREN_BLOCK_FRAMES = 240, AUDREN_RATE = 48000 \};')

    def test_every_notice_goes_through_the_lifecycle(self):
        self.assertIn('#include "audio_lifecycle.h"', self.front)
        self.assertIn('static audio_life_do front_ios_audio_on(int ev) { return audio_life_on(&g_life, ev, NSProcessInfo.processInfo.systemUptime); }', self.front)
        do = code(body(self.front, 'static void front_ios_audio_do(audio_life_do d) {'))
        order = [do.index(x) for x in ('if (d.act & AUDIO_LIFE_ACTIVATE) front_ios_audio_session();', 'if (d.act & AUDIO_LIFE_RESET_UNITS) dm_audio_reset();',
                                       'if (d.act & AUDIO_LIFE_APPLY) dm_audio_suspend(audio_life_suspended(&g_life));')]
        self.assertEqual(order, sorted(order))   # in the header's order: the session, the units, then real output or the silent sink
        calls = re.findall(r'dm_audio_suspend\(([^;]*)\);', code(self.front))   # nothing else switches real output but the game's end, for good
        self.assertEqual(sorted(calls), ['1', 'audio_life_suspended(&g_life)'])
        self.assertEqual(code(self.front).count('dm_audio_reset()'), 1)
        self.assertNotRegex(code(self.front), r'\bg_(audio_bg|audio_intr|session_off)\b')   # the state is the lifecycle's alone
        # the interruption notice stays, on its two events; each notice logs, then does what the lifecycle said
        legacy, q = observer(self.watch, 'AVAudioSessionInterruptionNotification')
        self.assertEqual(q, 'NSOperationQueue.mainQueue')
        self.assertIn('{ audio_life_do d = front_ios_audio_on(AUDIO_LIFE_BEGAN); LOG("audio session: interrupted (reason %lu)", (unsigned long)reason); front_ios_audio_do(d); }', legacy)
        self.assertIn('{ audio_life_do d = front_ios_audio_on(AUDIO_LIFE_ENDED); LOG("audio session: interruption ended"); front_ios_audio_do(d); }', legacy)
        # iOS 27's lifecycle notices: the deployment target, no SDK guard that could leave them out silently; observed unless DM_AUDIO_LIFECYCLE=0
        self.assertNotIn('__IPHONE_27_0', self.watch)
        self.assertRegex(read('dm/ios/project.yml'), r'deploymentTarget:\n    iOS: "27\.0"')
        self.assertIn('const char *lc = getenv("DM_AUDIO_LIFECYCLE");\n    g_life.lifecycle = !lc || atoi(lc);', self.watch)
        gate = self.watch.index('if (g_life.lifecycle) {'); gated = body(self.watch, 'if (g_life.lifecycle) {')
        inactive, q = observer(self.watch, 'AVAudioSessionDidBecomeInactiveNotification')
        self.assertEqual(q, 'NSOperationQueue.mainQueue'); self.assertIn(inactive, gated)
        self.assertIn('n.userInfo[AVAudioSessionDeactivationContextKey]', inactive)
        self.assertIn('[c isKindOfClass:AVAudioSessionDeactivationContext.class]', inactive)
        self.assertIn('BOOL app = dc && dc.source == AVAudioSessionDeactivationSourceApp;', inactive)
        self.assertIn('front_ios_audio_on(app ? AUDIO_LIFE_INACTIVE_APP : ic ? AUDIO_LIFE_INACTIVE_SYSTEM : AUDIO_LIFE_INACTIVE_NO_CONTEXT);', inactive)
        self.assertIn('"audio session: deactivated by the system (lifecycle notice, reason %lu)%s%s", (unsigned long)ic.reason', inactive)
        self.assertIn('"audio session: deactivated by the system (lifecycle notice, no interruption context)%s%s"', inactive)   # no dummy reason
        resume, q = observer(self.watch, 'AVAudioSessionResumptionRecommendationNotification')
        self.assertEqual(q, 'NSOperationQueue.mainQueue'); self.assertIn(resume, gated)
        self.assertIn('n.userInfo[AVAudioSessionResumptionContextKey]', resume)
        self.assertIn('BOOL should = rc && rc.recommendation == AVAudioSessionResumptionRecommendationShouldResume;', resume)
        self.assertIn('front_ios_audio_on(should ? AUDIO_LIFE_RESUME : AUDIO_LIFE_RESUME_NOT);', resume)
        active, q = observer(self.watch, 'AVAudioSessionDidBecomeActiveNotification')
        self.assertEqual(q, 'NSOperationQueue.mainQueue'); self.assertIn(active, gated)
        self.assertIn('front_ios_audio_on(AUDIO_LIFE_ACTIVE);', active)
        for kind, b in enumerate((inactive, resume, active)):   # one line per notice, from its own capped budget, then the actions
            with self.subTest(kind=kind):
                self.assertIn(f'int k = life_line({kind});', b)
                self.assertEqual(len(re.findall(r'\bLOG\(', b)), 3 if b is inactive else 1)
                self.assertTrue(b.rstrip('}\n ').endswith('front_ios_audio_do(d);'))
        self.assertEqual(len(re.findall(r'if \(k(?: && \w+)?\) LOG', inactive)), 3)
        self.assertEqual(len(re.findall(r'\belse if \(k', inactive)), 2)   # one of the three
        self.assertIn('enum { LIFE_LINES = 32 };', self.front)
        self.assertIn('static int life_line(int kind) { return g_life_lines[kind] < LIFE_LINES ? ++g_life_lines[kind] : 0; }', self.front)
        # the media services reset and the scene events take the same path
        reset, q = observer(self.watch, 'AVAudioSessionMediaServicesWereResetNotification')
        self.assertLess(gate, self.watch.index('AVAudioSessionMediaServicesWereResetNotification'))
        self.assertNotIn(reset, gated)   # observed with the switch off too
        self.assertIn('audio_life_do d = front_ios_audio_on(AUDIO_LIFE_RESET);', reset); self.assertTrue(reset.rstrip('}\n ').endswith('front_ios_audio_do(d);'))
        focus = body(self.front, 'void front_ios_focus_event(int ev) {')
        cases = dict(re.findall(r'case (\d):(.*?)break;', focus, re.S))
        self.assertIn('front_ios_audio_do(front_ios_audio_on(AUDIO_LIFE_BACKGROUND));', cases['1'])
        self.assertIn('front_ios_audio_do(front_ios_audio_on(AUDIO_LIFE_FOREGROUND));', cases['2'])
        self.assertIn('front_ios_audio_focus();', cases['3'])
        fb = body(self.front, 'static void front_ios_audio_focus(void) {')
        self.assertIn('audio_life_do d = front_ios_audio_on(AUDIO_LIFE_FOCUS);', fb)
        self.assertIn('if (d.note == AUDIO_LIFE_NOTE_FALLBACK) LOG("audio session: active again with no interruption-ended notice%s", audio_life_note(d.note));', fb)

    def test_the_c_tests_run(self):
        """t_audio_lifecycle.c and t_audio_route.c: plain, and under ASan and UBSan where this compiler has them; and the host tests' run target runs them"""
        mk = read('dm/host/tests/Makefile')
        cc = c_compiler()
        if not cc: self.skipTest('no C compiler')
        with tempfile.TemporaryDirectory() as tmp:
            for name, done in (('t_audio_lifecycle', 'audio lifecycle: '), ('t_audio_route', 'audio route: ')):
                self.assertRegex(mk, rf'(?m)^run: \$\(B\)/{name}$'); self.assertRegex(mk, rf'(?m)^\t\$\(B\)/{name}$')
                for flags in ([], ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']):
                    with self.subTest(name=name, flags=flags):
                        exe = Path(tmp) / (name + ('_asan' if flags else ''))
                        r = subprocess.run([cc, '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', *flags, '-o', str(exe), str(REPO / 'dm/host/tests' / (name + '.c'))],
                                           capture_output=True, text=True)
                        if r.returncode and flags: self.skipTest(f'no sanitizers here: {r.stderr.strip()[:200]}')
                        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                        r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=120,
                                           env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1' if sys.platform.startswith('linux') else '', UBSAN_OPTIONS='halt_on_error=1'))
                        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                        self.assertIn(done, r.stdout)

    def test_switches_and_harness(self):
        rows = {l.split('\t')[0]: l.split('\t') for l in read('docs/env_switches.tsv').splitlines()}
        for env in ('DM_AUDIO_LIFECYCLE', 'DM_AUDIO_ROUTE_REAPPLY'):
            with self.subTest(env=env):
                self.assertEqual(rows[env][1], 'switch')
                self.assertIn(f'getenv("{env}")', self.front)
        stubs = read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m')   # the Duo harness links front_ios.m alone
        for decl in ('void dm_audio_suspend(int on) {', 'void dm_audio_reset(void) {'): self.assertIn(decl, stubs)

    def test_each_new_line_is_in_the_audio_reference(self):
        doc = read('docs/reference/audio.md')
        for text in ('audio route changed (', 'audio session: the I/O buffer settled at', '[RED] audio session: the I/O buffer of', 'audio session: deactivated by the system',
                     'audio session: deactivated by the app', 'audio session: resumption recommended', 'audio session: became active (lifecycle notice)',
                     '(lifecycle notice, no interruption context)', 'audio session: active again after', 'audio device N latency', '[RED] audio device N buffer of',
                     'no other app interrupted: taking the session back', 'the last activation was rejected: left to the becoming-active retry',
                     'the activations after the last 3 recommendations were rejected',
                     'lines of this notice not logged from here on'):
            with self.subTest(text=text):
                self.assertIn(text, doc)


if __name__ == '__main__':
    unittest.main()
