"""scripts/crashlog.py and the crash summary the app logs (dm/host/crash_summary.h, run_layout.h; DmMetrics.m, loader.c), on a synthetic MetricKit crash report of each shape.

The report is made here in the shape iOS 27's MetricManager writes (crashDiagnostic, environment, timeRange; callStackThreads, rootFrames, binaryInfo, each frame's caller in its
subFrames) and in MXMetricManager's (crashDiagnostics, diagnosticMetaData, callStacks, callStackRootFrames, binaryName in each frame), with the game's frames under the all-zero
binary UUID and offsetIntoBinaryTextSegment equal to the address, as iOS reports code that is in no image it knows. Its run's layout record names every part a frame can be in.
The C core is compiled with a small driver and must print the same lines as the script; dm/host/tests/t_crash_summary.c runs too, plain and under ASan where the compiler has it."""
import copy, importlib.util, json, os, re, shutil, subprocess, sys, tempfile, unittest
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
HOST = REPO / 'dm/host'
SCRIPT = REPO / 'scripts/crashlog.py'
spec = importlib.util.spec_from_file_location('crashlog', SCRIPT)
assert spec and spec.loader
crashlog = importlib.util.module_from_spec(spec); spec.loader.exec_module(crashlog)

ZERO = '00000000-0000-0000-0000-000000000000'
DMIOS, PTHREAD = '2D26ACD9-0000-3EC2-83D2-000000000001', 'FE570F09-0000-384B-B7AA-000000000002'
MAIN, SDK, NRO = 0x200000000, 0x201400000, 0x202000000
PID, WHEN = 4242, '2026-11-06T02:15:36Z'

# The crashed thread, newest first: (address, binary UUID or None for the game's code, offset into the image) and the line each gets with the run's record
FRAMES = [
    (MAIN + 0xfd8fa0, None, None, "main+0xfd8fa0, main's writable part (not executable), 0x7060 below its patch area"),
    (MAIN + 0x7f0648, None, None, "main+0x7f0648, main's text"),
    (MAIN + 0x64010, None, None, "main+0x64010, main's text, in a switchable mod's code page (Ultrawide)"),
    (MAIN + 0xfe4100, None, None, "main+0xfe4100, main's patch area, in a switchable mod's code page (High frame rate and Ultrawide)"),
    (SDK - 0x1ff000, None, None, "sdk-0x1ff000, sdk's patch area"),
    (SDK + 0x750000, None, None, "sdk+0x750000, sdk's back patch area"),
    (SDK + 0x5f8010, None, None, "sdk+0x5f8010, sdk's key page (read-only)"),
    (SDK + 0x5fc020, None, None, "sdk+0x5fc020, sdk's frame step state page (writable, not executable)"),
    (SDK + 0x400000, None, None, "sdk+0x400000, sdk's writable part (not executable)"),
    (SDK - 0x80000, None, None, "sdk-0x80000, sdk's gap before its base (not code: read-write on the iPhone, inaccessible on the Mac)"),
    (NRO + 0x1000, None, None, "nro0+0x1000, nro0's text"),
    (0x300000000, None, None, 'game code in no module of the run'),
    (MAIN + 0x900010, None, None, "main+0x900010, main's writable part (not executable), in a switchable mod's data (High frame rate), 0x6dfff0 below its patch area"),
    (0x104d1ec3c, DMIOS, 0x166a3c, 'DmIOS+0x166a3c'),
    (0x104d00010, 'DEADBEEF-0000-0000-0000-000000000003', 0x10, 'image DEADBEEF+0x10'),
    (0x104d1e000, DMIOS, 0x166000, 'DmIOS+0x166000'),
    (0x104d1f000, DMIOS, 0x167000, 'DmIOS+0x167000'),
    (0x104d20000, DMIOS, 0x168000, 'DmIOS+0x168000'),
    (0x18dfb9000, PTHREAD, 0x3ef0, 'libsystem_pthread.dylib+0x3ef0'),
    (0x18dfb991c, PTHREAD, 0x91c, 'libsystem_pthread.dylib+0x91c'),
]
REGION = ('0x200fd8fa0 is in 0x2007f4000-0x200fdc000;  bytes after start: 8105888  bytes before end: 12383\n'
          '      REGION TYPE                   START - END        [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n'
          '      mapped file                2006f4000-2007f4000   [ 1024K] r-x/r-x SM=COW  Object_id=11111111\n'
          '--->  mapped file                2007f4000-200fdc000   [  7.9M] rw-/rw- SM=COW  Object_id=22222222\n'
          '      mapped file                200fdc000-200fe0000   [   16K] r--/rw- SM=COW  Object_id=22222222')
RECORD = f'''# Module layouts of this app's newest runs, newest last (dm/host/run_layout.h); the crash summary in log.txt and scripts/crashlog.py read them
run pid={PID} start=1793931200 utc=2026-11-06T02:13:20Z commit=0ld0ld title=0100000000010000 mods=none
module name=main base=0x300000000 size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000
end
run pid=17 start=1793931300 utc=2026-11-06T02:15:00Z commit=557cb3b0 title=0100000000010000 mods=none
module name=main base=0x210000000 size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000
end
run pid={PID} start=1793931330 utc=2026-11-06T02:15:30Z commit=557cb3b0 title=0100000000010000 mods=fps+ultrawide
module name=main base=0x{MAIN:x} size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000 build=00112233445566778899aabbccddeeff
module name=sdk base=0x{SDK:x} size=0x800000 text_end=0x300000 patch=-0x200000 patch_len=0x100000 key=0x5f8000 fps=0x5fc000 back=0x700000 back_len=0x100000
module name=nro0 base=0x{NRO:x} size=0x100000 text_end=0x40000 patch=0xe0000 patch_len=0x20000 key=0xdc000 nro=1
module name=bad base=0x1 size=0xffffffffffffffff text_end=0x10 patch=-0x8000000000000000 patch_len=0x1 key=0x0
piece module=main off=0x64000 len=0x4000 kind=code roles=ultrawide
piece module=main off=0x7f0000 len=0xffffffffffffffff kind=code roles=ultrawide
piece module=main off=0xfe4000 len=0x4000 kind=code roles=fps+ultrawide
piece module=main off=0x900010 len=0x8 kind=data roles=fps
end
run pid={PID} start=1793991200 utc=2026-11-06T18:53:20Z commit=557cb3b0 title=0100000000010000 mods=none
module name=main base=0x400000000 size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000
end
run pid=99 start=1
module name=cut base=0x1
'''   # the crashed run is the third block: the first has its pid but is older, the fourth has it again after a restart, the last was cut off partway. The crashed run's 'bad'
#       module and last piece have numbers past any address, so both readers leave them out (or every game frame below would be in them)
# The crashed run left no record, and an older run had its pid: a run of another pid started between them, more than a minute before the crash
EARLIER = f'''# header
run pid={PID} start=1793931200 utc=2026-11-06T02:13:20Z commit=0ld0ld title=0100000000010000 mods=ultrawide
module name=main base=0x300000000 size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000
piece module=main off=0x64000 len=0x4000 kind=code roles=ultrawide
end
run pid=17 start=1793931250 utc=2026-11-06T02:14:10Z commit=557cb3b0 title=0100000000010000 mods=none
module name=main base=0x210000000 size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000
end
'''
# A run with the JIT layout: its code memory, the served image in its first 0x1a4000 bytes
JIT_RECORD = f'''run pid={PID} start=1793931330 utc=2026-11-06T02:15:30Z commit=557cb3b0 title=010049900F546001 mods=none
module name=main base=0x{MAIN:x} size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000
jit base=0x203000000 size=0x2000000 image=0x1a4000
end
'''
LOG_OTHER = '''boot: game language en-US
[dm] build: commit 557cb3b0, shader chain 1, profile 0100000000010000
[dm] main: gates 3 patch_off 0xfe0000 keys 1/2/3/4
[dm] main: base 0x210000000 size 0x1000000
[dm] sdk: gates 3 patch_off 0xffffffffffe00000 keys 1/2/3/4
[dm] sdk: base 0x211400000 size 0x800000
[dm] main: switchable mods put in place: Ultrawide (2 pieces)
[dm] run layout: pid 999, started 2026-11-06T03:00:00Z: 2 modules and 2 switchable-mod pieces in run_layouts.txt beside this log (the crash summary reads it)
'''
# The same from a build that logs each module's key page and text end on its gates line (loader.c register_gates)
LOG_NEW = (LOG_OTHER.replace('main: gates 3 patch_off 0xfe0000 keys 1/2/3/4', 'main: gates 3 patch_off 0xfe0000 keys 1/2/3/4 key_page 0xfdc000 text_end 0x7f1234')
           .replace('sdk: gates 3 patch_off 0xffffffffffe00000 keys 1/2/3/4', 'sdk: gates 3 patch_off 0xffffffffffe00000 keys 1/2/3/4 key_page 0x5f8000 text_end 0x300000'))


def frame_chain(frames, old=False):
    """The frames as MetricKit nests them: the newest is the root, each frame's subFrames holds its caller"""
    node = None
    for a, uuid, off, _ in reversed(frames):
        f = {'address': a, 'binaryUUID': uuid or ZERO, 'offsetIntoBinaryTextSegment': off if uuid else a, 'sampleCount': 1, 'subFrames': [node] if node else []}
        if old: f['binaryName'] = {DMIOS: 'DmIOS', PTHREAD: 'libsystem_pthread.dylib'}.get(uuid or '', '???')
        node = f
    return node


def modern(frames=FRAMES, pid: int | None = PID):
    """A report in MetricManager's shape (Metrics.swift: JSONEncoder, sorted keys)"""
    other = {'threadAttributed': False, 'rootFrames': [frame_chain([(0x18dfb0010, PTHREAD, 0x10, '')])]}
    env = {'applicationBuildVersion': '1.4.1', 'applicationVersion': '1.4.1', 'bundleIdentifier': 'org.example.game', 'deviceType': 'iPhone19,3', 'isTestFlightApp': False,
           'osVersion': {'buildNumber': '24C5037i', 'number': '27.3', 'platform': 'iPhone OS'}, 'platformArchitecture': 'arm64e', 'signpostData': [], 'states': []}
    if pid is not None: env['pid'] = pid
    return {'crashDiagnostic': {'callStackTree': {'binaryInfo': [{'name': 'DmIOS', 'uuid': DMIOS}, {'name': 'libsystem_pthread.dylib', 'uuid': PTHREAD}], 'callStackPerThread': True,
                                                  'callStackThreads': [other, {'threadAttributed': True, 'rootFrames': [frame_chain(frames)]}, other]},
                                'exceptionCode': 2, 'exceptionType': 1, 'signal': 9, 'terminationReason': 'Namespace CODESIGNING, Code 0x2', 'virtualMemoryRegionInfo': REGION},
            'environment': env, 'timeRange': {'begin': WHEN, 'end': WHEN}, 'version': '2.0.0'}


def probe(region, frames):
    """A report of MetricManager's shape with other memory rows and frames"""
    r = modern(frames=frames); r['crashDiagnostic']['virtualMemoryRegionInfo'] = region
    return r


JIT_FRAMES = [(0x203010040, None, None, "jit+0x10040, the JIT code memory, in its served image (code made by the game's JIT plugin, built on the Mac)"),
              (0x203400000, None, None, 'jit+0x400000, the JIT code memory, past its served image (not code)'), (0x205000000, None, None, 'game code in no module of the run'),
              FRAMES[1], FRAMES[13]]
# The report's rows when the writable part goes on past the key page (key page at 0xfd4000, patch area at 0xfe0000: the row after the key page is not listed)
K_REGION = ('0x200fd0fa0 is in 0x2007f4000-0x200fd4000;  bytes after start: 1  bytes before end: 1\n'
            '      REGION TYPE                   START - END        [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n'
            '      mapped file                2006f4000-2007f4000   [ 1024K] r-x/r-x SM=COW  Object_id=11111111\n'
            '--->  mapped file                2007f4000-200fd4000   [  7.9M] rw-/rw- SM=COW  Object_id=22222222\n'
            '      mapped file                200fd4000-200fd8000   [   16K] r--/rw- SM=COW  Object_id=22222222')
K_FRAMES = [(MAIN + 0xfd0fa0, None, None, ''), (MAIN + 0x7f0648, None, None, ''), FRAMES[13]]
# A fault in the text: the next row is the writable part, without the key page
B_REGION = ('0x2007f0648 is in 0x2006f4000-0x2007f4000;  bytes after start: 1  bytes before end: 1\n'
            '      REGION TYPE                   START - END        [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n'
            '      mapped file                2005f4000-2006f4000   [ 1024K] r-x/r-x SM=COW  Object_id=11111110\n'
            '--->  mapped file                2006f4000-2007f4000   [ 1024K] r-x/r-x SM=COW  Object_id=11111111\n'
            '      mapped file                2007f4000-200fdc000   [  7.9M] rw-/rw- SM=COW  Object_id=22222222')
B_FRAMES = [(MAIN + 0x7f0648, None, None, ''), (MAIN + 0x5f0000, None, None, ''), FRAMES[13]]
# A fault in a heap region: no row of a module
H_REGION = ('0x280004000 is in 0x280000000-0x280400000;  bytes after start: 16384  bytes before end: 1\n'
            '      REGION TYPE                   START - END        [ VSIZE] PRT/MAX SHRMOD  REGION DETAIL\n'
            '      VM_ALLOCATE                27fc00000-280000000   [ 4096K] rw-/rwx SM=PRV\n'
            '--->  VM_ALLOCATE                280000000-280400000   [ 4096K] rw-/rwx SM=PRV\n'
            '      GAP OF 0x1000000 BYTES     280400000-281400000   [   16M] ---/--- SM=NUL')
H_FRAMES = [(0x280004000, None, None, ''), (MAIN + 0x7f0648, None, None, ''), FRAMES[13]]


def payload():
    """An MXDiagnosticPayload (DM_METRICS=mx) of two crashes: the run above, and one of an older system that names no pid"""
    def crash(meta):
        return {'version': '1.0.0', 'callStackTree': {'callStackPerThread': True, 'callStacks': [{'threadAttributed': True, 'callStackRootFrames': [frame_chain(FRAMES[:3] + FRAMES[13:14], old=True)]}]},
                'diagnosticMetaData': meta}
    base = {'appBuildVersion': '1.4.1', 'appVersion': '1.4.1', 'deviceType': 'iPhone19,3', 'osVersion': 'iPhone OS 27.3 (24C5037i)', 'platformArchitecture': 'arm64e',
            'regionFormat': 'US', 'exceptionType': 1, 'exceptionCode': 1, 'signal': 11, 'terminationReason': 'Namespace SIGNAL, Code 0xb', 'virtualMemoryRegionInfo': REGION}
    return {'timeStampBegin': '2026-11-06 02:15:36 +0000', 'timeStampEnd': '2026-11-06 02:15:36 +0000',
            'crashDiagnostics': [crash(dict(base, pid=PID)), crash({k: v for k, v in base.items() if k not in ('exceptionCode', 'virtualMemoryRegionInfo')})]}


HEAD = ["EXC_BAD_ACCESS (1), KERN_PROTECTION_FAILURE (2); signal SIGKILL (9); termination reason Namespace CODESIGNING, Code 0x2 (code signing: an invalid page, the run executed a "
        "page that is not signed code, such as a writable one)",
        'memory: 0x200fd8fa0 is in 0x2007f4000-0x200fdc000; bytes after start: 8105888 bytes before end: 12383',
        'memory: REGION TYPE START - END [ VSIZE] PRT/MAX SHRMOD REGION DETAIL',
        'memory: mapped file 2006f4000-2007f4000 [ 1024K] r-x/r-x SM=COW Object_id=11111111',
        'memory: ---> mapped file 2007f4000-200fdc000 [ 7.9M] rw-/rw- SM=COW Object_id=22222222',
        'memory: mapped file 200fdc000-200fe0000 [ 16K] r--/rw- SM=COW Object_id=22222222',
        f'run: pid {PID}, app build 1.4.1, iPhone19,3, iPhone OS 27.3 (24C5037i), at {WHEN}']
MODS = ('switchable mods in place in that run: High frame rate: 1 piece (main data +0x900010 (8 bytes)); Ultrawide: 1 piece (main code page +0x64000); High frame rate and '
        'Ultrawide: 1 piece (main code page +0xfe4000); frames #2, #3, #12 are in them. Turning High frame rate and Ultrawide off in the launcher is the first thing to try (one at a time, to tell which)')


def expected_with_record():
    return HEAD + ["layout: the run's record in run_layouts.txt: started 2026-11-06T02:15:30Z, commit 557cb3b0, title 0100000000010000, switchable mods on: High frame rate and Ultrawide",
                   "crashed thread (the report's thread 1 of 3), newest frame first:"] \
        + [f'#{k} 0x{a:x} {text}' for k, (a, _u, _o, text) in enumerate(FRAMES[:16])] \
        + [f'... 4 more frames; the oldest, #19: 0x{FRAMES[19][0]:x} {FRAMES[19][3]}', MODS]


def run_script(*args):
    return subprocess.run([sys.executable, '-I', str(SCRIPT), *map(str, args)], capture_output=True, text=True, timeout=60)


class Summary(unittest.TestCase):
    """crashlog.py's lines, which are the app's (the C core is held to them below)"""

    def test_the_crashed_runs_record_names_every_part(self):
        self.assertEqual(crashlog.summary_lines(modern(), RECORD), expected_with_record())

    def test_no_record_of_the_pid_gives_raw_addresses_and_the_reports_own_regions(self):
        lines = crashlog.summary_lines(modern(pid=31337), RECORD)
        self.assertIn('layout: run_layouts.txt has no record of pid 31337 (it holds the runs of pids 4242, 17, 4242, 4242): game frames are raw addresses', lines)
        self.assertIn(f'#0 0x{MAIN + 0xfd8fa0:x} game code, in the report\'s region 0x2007f4000-0x200fdc000 rw- mapped file (not executable)', lines)
        self.assertIn(f"#1 0x{MAIN + 0x7f0648:x} game code, in the report's region 0x2006f4000-0x2007f4000 r-x mapped file", lines)
        self.assertIn(f'#2 0x{MAIN + 0x64010:x} game code', lines)   # in no region the report lists
        self.assertFalse(any(l.startswith('switchable mods') for l in lines))
        self.assertIn('layout: no run_layouts.txt (a build from before it, or it could not be read): game frames are raw addresses', crashlog.summary_lines(modern(), None))
        self.assertIn("layout: the report names no pid, so no run's record can be matched: game frames are raw addresses", crashlog.summary_lines(modern(pid=None), RECORD))

    def test_an_earlier_run_of_the_pid_is_not_taken_for_the_crashed_one(self):
        lines = crashlog.summary_lines(modern(), EARLIER)
        self.assertIn(f"layout: run_layouts.txt's record of pid {PID} is of an earlier run (started 2026-11-06T02:13:20Z): pid 17 started after it, before the crash, so the crashed "
                      'run left no record (it ended before writing one, or the write failed): game frames are raw addresses', lines)
        self.assertIn(f'#2 0x{MAIN + 0x64010:x} game code', lines)
        self.assertFalse(any(l.startswith('switchable mods') for l in lines))
        # a run of another pid within the minute before the crash proves nothing (the clocks)
        self.assertIn("layout: the run's record in run_layouts.txt: started 2026-11-06T02:13:20Z, commit 0ld0ld, title 0100000000010000, switchable mods on: Ultrawide",
                      crashlog.summary_lines(modern(), EARLIER.replace('start=1793931250', 'start=1793931300')))

    def test_the_jit_code_memory(self):
        lines = crashlog.summary_lines(modern(frames=JIT_FRAMES), JIT_RECORD)
        for k, (a, _u, _o, text) in enumerate(JIT_FRAMES): self.assertIn(f'#{k} 0x{a:x} {text}', lines)

    def test_mxmetricmanager_payload_of_two_crashes(self):
        lines = crashlog.summary_lines(payload(), RECORD)
        self.assertEqual(lines[0], 'crash 1 of 2 in this report:')
        self.assertEqual(lines[1], 'EXC_BAD_ACCESS (1), KERN_INVALID_ADDRESS (1); signal SIGSEGV (11); termination reason Namespace SIGNAL, Code 0xb')
        self.assertIn(f'run: pid {PID}, app build 1.4.1, iPhone19,3, iPhone OS 27.3 (24C5037i), at 2026-11-06 02:15:36 +0000', lines)
        self.assertIn("#2 0x200064010 main+0x64010, main's text, in a switchable mod's code page (Ultrawide)", lines)
        self.assertIn('#3 0x104d1ec3c DmIOS+0x166a3c', lines)
        second = lines[lines.index('crash 2 of 2 in this report:') + 1:]
        self.assertEqual(second[0], 'EXC_BAD_ACCESS (1); signal SIGSEGV (11); termination reason Namespace SIGNAL, Code 0xb')
        self.assertEqual(second[1], 'run: app build 1.4.1, iPhone19,3, iPhone OS 27.3 (24C5037i), at 2026-11-06 02:15:36 +0000')
        self.assertIn("layout: the report names no pid, so no run's record can be matched: game frames are raw addresses", second)

    def test_names_and_times(self):
        self.assertEqual(crashlog.parse_time('2026-11-06T02:15:36Z'), 1793931336)
        self.assertEqual(crashlog.parse_time('2026-11-06 03:15:36 +0100'), 1793931336)
        self.assertEqual(crashlog.parse_time('2026-11-06T02:15:36.250-00:30'), 1793933136)
        self.assertEqual(crashlog.parse_time('yesterday'), -1)
        self.assertEqual(crashlog.term_hint('Namespace FRONTBOARD, Code 0x8badf00d'), "the system's watchdog: the app did not answer in time")
        self.assertEqual((crashlog.exc_name(12), crashlog.code_name(1, 50), crashlog.signal_name(6)), ('EXC_GUARD', 'KERN_CODESIGN_ERROR', 'SIGABRT'))
        self.assertEqual((crashlog.code_name(1, 0x103), crashlog.code_name(1, 0x105), crashlog.code_name(1, 0x106)), ('EXC_ARM_SP_ALIGN', 'EXC_ARM_PAC_FAIL', None))
        self.assertEqual(crashlog.ctext('a\ud800b', 64), 'a\ufffdb')   # a lone surrogate, as the app reads it


class Script(unittest.TestCase):
    """The command: its inputs, the layout it finds, its exit codes"""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(); self.d = Path(self.tmp.name)
        (self.d / 'metrics').mkdir()
        self.report = self.d / 'metrics' / '20261106-021540-000-diagnostic-crash.json'
        self.report.write_text(json.dumps(modern(), indent=2, sort_keys=True))

    def tearDown(self):
        self.tmp.cleanup()

    def test_with_the_record(self):
        (self.d / 'run_layouts.txt').write_text(RECORD)
        r = run_script(self.report, self.d / 'run_layouts.txt')
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertEqual(r.stdout.splitlines()[1:], expected_with_record())

    def test_finds_the_record_in_the_folder_above_the_report(self):
        (self.d / 'run_layouts.txt').write_text(RECORD)
        r = run_script(self.report)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('run_layouts.txt (found beside the report)', r.stdout.splitlines()[0])
        self.assertEqual(r.stdout.splitlines()[1:], expected_with_record())

    def layout_line(self, report, log, name='log.txt'):
        self.report.write_text(json.dumps(report))
        (self.d / name).write_text(log)
        r = run_script(self.report, self.d / name)
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout.splitlines()
        return next(l for l in out if l.startswith('layout: ')), out

    def test_a_log_of_another_run_gives_inferred_bases(self):
        lay, out = self.layout_line(modern(), LOG_OTHER)
        self.assertEqual(lay, "layout: inferred, not recorded: log.txt is of another run (it is the log of pid 999); from its modules' sizes and patch_off: main at 0x200000000, "
                              "because the report's writable region 0x2007f4000-0x200fe0000 ends with main's key page (its 16 KB read-only row) and main's patch area begins 0xfe0000 "
                              "from its base, if the patch area follows the key page directly; the report lists nothing after the key page, and writable pages between the two (an "
                              "image that does not end in the last 16 KB of a 64 KB block) would put main at 0x200004000, 0x200008000 or 0x20000c000, making each offset below 0x4000 to "
                              "0xc000 smaller; the other modules moved with it (-0x10000000); 11 of 13 game frames fall in them; the log's run had switchable mods in place (main: "
                              "Ultrawide (2 pieces)), whether the crashed run did is not known")
        self.assertIn(f"#0 0x{MAIN + 0xfd8fa0:x} main+0xfd8fa0, main's writable part (not executable), 0x7060 below its patch area", out)
        self.assertIn(f"#1 0x{MAIN + 0x7f0648:x} main+0x7f0648, main's text", out)   # the text end taken from where the writable region starts
        self.assertIn(f"#4 0x{SDK - 0x1ff000:x} sdk-0x1ff000, sdk's patch area", out)
        self.assertIn(f"#8 0x{SDK + 0x400000:x} sdk+0x400000, sdk's text or writable part (the layout gives no text end)", out)

    def test_a_log_with_key_pages_and_text_ends_gives_exact_bases(self):
        lay, out = self.layout_line(modern(), LOG_NEW)
        self.assertIn("from its modules' sizes and patch_off, key pages and text ends: main at 0x200000000, because the report's writable row 0x2007f4000-0x200fdc000 begins where "
                      "main's text ends (0x7f4000 from its base), and the report's 16 KB read-only row 0x200fdc000-0x200fe0000 is main's key page (0xfdc000 from its base); the "
                      'other modules moved with it (-0x10000000); 11 of 13 game frames fall in them', lay)
        self.assertIn(f"#8 0x{SDK + 0x400000:x} sdk+0x400000, sdk's writable part (not executable)", out)   # the sdk's text end, from the log
        parsed = crashlog.parse_log('[dm] main: gates 3 patch_off 0xfe0000 keys 1/2/3/4 key_page 0xfdc000 text_end 0x7f1234\n[dm] main: base 0x210000000 size 0x1000000\n')
        self.assertEqual((parsed[1][0]['key'], parsed[1][0]['text_end']), (0xfdc000, 0x7f1234))

    def test_a_writable_tail_after_the_key_page(self):
        """The patch area 0x8000 past the key page: a log without key pages gives the base only with that doubt, one with them gives it exactly"""
        lay, _out = self.layout_line(probe(K_REGION, K_FRAMES), LOG_OTHER)
        self.assertIn('main at 0x1ffff8000, because the report\'s writable region 0x2007f4000-0x200fd8000 ends with main\'s key page', lay)
        self.assertIn('would put main at 0x1ffffc000, 0x200000000 or 0x200004000, making each offset below 0x4000 to 0xc000 smaller', lay)
        lay, out = self.layout_line(probe(K_REGION, K_FRAMES), LOG_NEW.replace('key_page 0xfdc000', 'key_page 0xfd4000'))
        self.assertIn("main at 0x200000000, because the report's writable row 0x2007f4000-0x200fd4000 begins where main's text ends (0x7f4000 from its base), and the report's "
                      "16 KB read-only row 0x200fd4000-0x200fd8000 is main's key page (0xfd4000 from its base)", lay)
        self.assertIn(f"#0 0x{MAIN + 0xfd0fa0:x} main+0xfd0fa0, main's writable part (not executable), 0xf060 below its patch area", out)

    def test_a_fault_in_the_text_or_the_heap_gives_no_base_without_more(self):
        lay, _out = self.layout_line(probe(B_REGION, B_FRAMES), LOG_OTHER)
        self.assertEqual(lay, "layout: log.txt is of another run (it is the log of pid 999), and no base could be inferred from the report's memory regions (its 'gates' lines give "
                              'no key pages or text ends, which a later build logs): game frames are raw addresses')
        lay, out = self.layout_line(probe(B_REGION, B_FRAMES), LOG_NEW)
        self.assertIn("main at 0x200000000, because the report's writable row 0x2007f4000-0x200fdc000 begins where main's text ends", lay)
        self.assertIn(f"#0 0x{MAIN + 0x7f0648:x} main+0x7f0648, main's text", out)
        for log in (LOG_OTHER, LOG_NEW):
            lay, _out = self.layout_line(probe(H_REGION, H_FRAMES), log)
            self.assertIn("and no base could be inferred from the report's memory regions", lay)

    def test_a_log_that_names_no_pid(self):
        nopid = '\n'.join(l for l in LOG_OTHER.splitlines() if 'run layout' not in l and 'sdk' not in l) + '\n'
        frames = [FRAMES[0], FRAMES[1], FRAMES[13]]
        lay, _out = self.layout_line(probe(REGION, frames), nopid.replace('0x210000000', f'0x{MAIN:x}'))
        self.assertEqual(lay, "layout: assumed, not recorded: log.txt names no pid; its 'base' lines fit every game frame and the report's memory regions do not contradict them, "
                              "so they are taken as that run's (no text ends); that log's run had switchable mods in place: main: Ultrawide (2 pieces)")
        lay, _out = self.layout_line(probe(REGION, frames), LOG_NEW.replace('0x210000000', f'0x{MAIN:x}').replace('[dm] run layout', 'x'))
        self.assertTrue(lay.startswith("layout: log.txt names no pid; its 'base' lines fit every game frame and the report's memory regions confirm them; that log's"), lay)
        # 8 MB off: every frame still falls in main, but the writable row would run across its base
        lay, out = self.layout_line(probe(REGION, frames), nopid.replace('0x210000000', '0x200800000'))
        self.assertTrue(lay.startswith("layout: inferred, not recorded: log.txt is of another run (its bases contradict the report's memory regions: its rw- row "
                                       "0x2007f4000-0x200fdc000 would run across main's base); from its modules' sizes and patch_off: main at 0x200000000"), lay)
        self.assertIn(f"#0 0x{MAIN + 0xfd8fa0:x} main+0xfd8fa0, main's writable part (not executable), 0x7060 below its patch area", out)

    def test_a_log_of_that_run_gives_its_bases(self):
        log = LOG_OTHER.replace('0x210000000', f'0x{MAIN:x}').replace('0x211400000', f'0x{SDK:x}').replace('pid 999', f'pid {PID}')
        (self.d / 'log.prev.txt').write_text(log)
        r = run_script(self.report)   # found beside the report's folder
        self.assertEqual(r.returncode, 0, r.stderr)
        out = r.stdout.splitlines()
        self.assertIn(f"layout: log.prev.txt of that run (pid {PID}): bases from its 'base' lines, which give no text ends; that log's run had switchable mods in place: "
                      'main: Ultrawide (2 pieces)', out)
        self.assertIn(f"#0 0x{MAIN + 0xfd8fa0:x} main+0xfd8fa0, main's text or writable part (the layout gives no text end), in the report's region 0x2007f4000-0x200fdc000 rw- mapped "
                      'file (not executable)', out)

    def test_another_runs_record_gives_inferred_bases(self):
        (self.d / 'run_layouts.txt').write_text(RECORD)
        self.report.write_text(json.dumps(modern(pid=31337)))
        out = run_script(self.report).stdout.splitlines()
        lay = next(l for l in out if l.startswith('layout: '))
        self.assertTrue(lay.startswith('layout: inferred, not recorded: run_layouts.txt has no record of pid 31337; from the module layout of its run of pid 4242 (started '
                                       '2026-11-06T18:53:20Z, commit 557cb3b0): main at 0x200000000'), lay)
        self.assertIn(f"#1 0x{MAIN + 0x7f0648:x} main+0x7f0648, main's text", out)
        self.report.write_text(json.dumps(modern(pid=None)))
        lay = next(l for l in run_script(self.report).stdout.splitlines() if l.startswith('layout: '))
        self.assertTrue(lay.startswith('layout: inferred, not recorded: the report names no pid; from the module layout of its run of pid 4242'), lay)

    def test_an_earlier_run_of_the_pid_gives_way_to_inferred_bases(self):
        lay, out = self.layout_line(modern(), EARLIER, 'run_layouts.txt')
        self.assertEqual(lay, f"layout: inferred, not recorded: run_layouts.txt's record of pid {PID} is of an earlier run (pid 17 started after it, before the crash); from the module "
                              "layout of its run of pid 17 (started 2026-11-06T02:14:10Z, commit 557cb3b0): main at 0x200000000, because the report's writable row "
                              "0x2007f4000-0x200fdc000 begins where main's text ends (0x7f4000 from its base), and the report's 16 KB read-only row 0x200fdc000-0x200fe0000 is main's "
                              "key page (0xfdc000 from its base); the other modules moved with it (-0x10000000); 5 of 13 game frames fall in them")   # that record has main alone
        self.assertFalse(any(l.startswith('switchable mods') for l in out))   # the older run's mods are not this one's

    def test_raw_without_any_layout(self):
        r = run_script(self.report)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('no run_layouts.txt or log.txt given or found beside it', r.stdout.splitlines()[0])
        self.assertIn(crashlog.NO_LAYOUT, r.stdout.splitlines())
        self.assertIn(f'#2 0x{MAIN + 0x64010:x} game code', r.stdout.splitlines())

    def test_odd_texts(self):
        """A frame chain nested deeper than Python's JSON reader goes is a clean error; a lone surrogate prints"""
        n = 30000
        deep = self.d / 'deep.json'
        deep.write_text('{"crashDiagnostic": {"callStackTree": {"callStackThreads": [{"threadAttributed": true, "rootFrames": ['
                        + '{"address": 1, "subFrames": [' * n + '{"address": 1}' + ']}' * n + ']}]}}, "environment": {"pid": 1}}')
        r = run_script(deep)
        self.assertEqual(r.returncode, 1); self.assertIn("is nested deeper than Python's JSON reader goes", r.stderr); self.assertNotIn('Traceback', r.stderr)
        odd = modern(); odd['crashDiagnostic']['terminationReason'] = 'Namespace X, Code 0x1 \ud800'
        self.report.write_text(json.dumps(odd))
        r = run_script(self.report)
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertIn('termination reason Namespace X, Code 0x1 \ufffd', r.stdout)

    def test_exit_codes(self):
        bad = self.d / 'bad.json'; bad.write_text('{"crashDiagnostic": ')
        self.assertEqual(run_script(bad).returncode, 1)
        none = self.d / 'none.json'; none.write_text('{"hangDiagnostics": []}')
        self.assertEqual(run_script(none).returncode, 1)
        self.assertEqual(run_script().returncode, 2)
        other = self.d / 'other.txt'; other.write_text('hello\n')
        self.assertEqual(run_script(self.report, other).returncode, 1)
        self.assertEqual(run_script(self.report, self.d / 'missing.txt').returncode, 1)


def c_compiler():
    return os.environ.get('CC') or shutil.which('cc') or shutil.which('clang') or shutil.which('gcc') or ''


DRIVER = r'''
#include "crash_summary.h"
static char *slurp(const char *p, size_t *n) {
    FILE *f = fopen(p, "rb"); if (!f) return NULL;
    fseek(f, 0, SEEK_END); long L = ftell(f); fseek(f, 0, SEEK_SET);
    char *b = malloc((size_t)L + 1); *n = fread(b, 1, (size_t)L, f); b[*n] = 0; fclose(f); return b;
}
static void line(void *ctx, const char *l) { (void)ctx; printf("%s\n", l); }
int main(int argc, char **argv) {
    if (argc >= 3 && !strcmp(argv[1], "summary")) {
        size_t n = 0, ln = 0; char *j = slurp(argv[2], &n), *lay = argc > 3 ? slurp(argv[3], &ln) : NULL;
        int r = j ? dm_crash_summary(j, n, lay, ln, line, NULL) : -2;
        free(j); free(lay); return r < 0 ? 1 : 0;
    }
    if (argc == 2 && !strcmp(argv[1], "block")) {   // a run as loader.c fills it, one of each kind of field
        dm_runlog_mod m[2] = {{.name = "main", .build = "00112233", .base = 0x200000000ull, .size = 0x1000000, .text_end = 0x7f1234, .key = 0xfdc000, .patch = 0xfe0000, .patch_len = 0x20000},
                              {.name = "sdk", .base = 0x201400000ull, .size = 0x800000, .text_end = 0x300000, .key = 0x5f8000, .fps = 0x5fc000, .back = 0x700000, .back_len = 0x100000,
                               .patch = -0x200000, .patch_len = 0x100000, .nro = 1}};
        dm_runlog_piece p[2] = {{.module = "main", .off = 0x64000, .len = 0x4000, .code = 1, .roles = 2}, {.module = "sdk", .off = -0x1fc000, .len = 8, .code = 0, .roles = 3}};
        dm_runlog_run r = {.pid = 4242, .start = 1793931330, .commit = "557cb3b0 dirty", .title = "0100000000010000/p1", .mods = 3, .nmod = 2, .npiece = 2, .mod = m, .piece = p};
        char buf[2048]; size_t n = dm_runlog_block(buf, sizeof buf, &r);
        fwrite(buf, 1, n, stdout); return n == strlen(buf) ? 0 : 1;
    }
    return 2;
}
'''


@unittest.skipUnless(c_compiler(), 'needs a C compiler')
class Core(unittest.TestCase):
    """The C core the app runs prints what the script prints, and writes the record the script reads"""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.TemporaryDirectory(); t = Path(cls.tmp.name)
        (t / 'drv.c').write_text(DRIVER)
        cls.exe = t / 'drv'
        r = subprocess.run([c_compiler(), '-std=gnu11', '-O1', '-Wall', '-Wextra', '-Werror', '-I', str(HOST), '-o', str(cls.exe), str(t / 'drv.c')], capture_output=True, text=True)
        assert r.returncode == 0, r.stdout + r.stderr

    @classmethod
    def tearDownClass(cls):
        cls.tmp.cleanup()

    def c_lines(self, report, record):
        with tempfile.TemporaryDirectory() as d:
            j = Path(d) / 'r.json'; j.write_text(json.dumps(report, indent=2, sort_keys=True))
            args = [str(self.exe), 'summary', str(j)]
            if record is not None: (Path(d) / 'l.txt').write_text(record); args.append(str(Path(d) / 'l.txt'))
            r = subprocess.run(args, capture_output=True, text=True, timeout=60)
            self.assertEqual(r.returncode, 0, r.stderr)
            return r.stdout.splitlines()

    def test_the_app_logs_the_scripts_lines(self):
        cases = {'record': (modern(), RECORD), 'no record': (modern(pid=31337), RECORD), 'no file': (modern(), None), 'no pid': (modern(pid=None), RECORD),
                 'payload': (payload(), RECORD), 'few frames': (modern(frames=FRAMES[:2]), RECORD)}
        odd = copy.deepcopy(modern()); odd['crashDiagnostic']['exceptionType'] = 99; odd['crashDiagnostic']['exceptionCode'] = -5; odd['crashDiagnostic']['signal'] = 77
        odd['crashDiagnostic']['terminationReason'] = 'Namespace JETSAM, Code 0xé\U0001F600 \ud800.\udc00'; odd['environment']['osVersion'] = 'iPhone OS 27.3'
        odd['crashDiagnostic']['callStackTree']['callStackThreads'][1]['threadAttributed'] = False
        cases['odd fields'] = (odd, RECORD)
        cases['earlier run'] = (modern(), EARLIER)
        cases['jit'] = (modern(frames=JIT_FRAMES), JIT_RECORD)
        cases['writable tail'] = (probe(K_REGION, K_FRAMES), RECORD.replace('key=0xfdc000 build=', 'key=0xfd4000 build='))
        for name, (report, record) in cases.items():
            with self.subTest(name):
                self.assertEqual(self.c_lines(report, record), crashlog.summary_lines(report, record))

    def test_the_record_the_loader_writes_reads_back(self):
        r = subprocess.run([str(self.exe), 'block'], capture_output=True, text=True, timeout=30)
        self.assertEqual(r.returncode, 0)
        self.assertEqual(r.stdout.splitlines(), [
            'run pid=4242 start=1793931330 utc=2026-11-06T02:15:30Z commit=557cb3b0_dirty title=0100000000010000/p1 mods=fps+ultrawide',
            'module name=main base=0x200000000 size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000 build=00112233',
            'module name=sdk base=0x201400000 size=0x800000 text_end=0x300000 patch=-0x200000 patch_len=0x100000 key=0x5f8000 fps=0x5fc000 back=0x700000 back_len=0x100000 nro=1',
            'piece module=main off=0x64000 len=0x4000 kind=code roles=ultrawide',
            'piece module=sdk off=-0x1fc000 len=0x8 kind=data roles=fps+ultrawide',
            'end'])
        run = crashlog.parse_layouts(r.stdout)[0]
        self.assertEqual((run['pid'], run['start'], run['mods'], run['title']), (4242, 1793931330, 3, '0100000000010000/p1'))
        self.assertEqual([(m['name'], m['base'], m['patch'], m['nro']) for m in run['modules']], [('main', 0x200000000, 0xfe0000, 0), ('sdk', 0x201400000, -0x200000, 1)])
        self.assertEqual([(p['module'], p['off'], p['len'], p['code'], p['roles']) for p in run['pieces']], [('main', 0x64000, 0x4000, True, 2), ('sdk', -0x1fc000, 8, False, 3)])

    def test_the_c_unit_test(self):
        """dm/host/tests/t_crash_summary.c (the host tests run it on the Mac): plain, and under ASan and UBSan where this compiler has them"""
        src = HOST / 'tests/t_crash_summary.c'
        for flags in ([], ['-fsanitize=address,undefined', '-fno-omit-frame-pointer']):
            with self.subTest(flags=flags):
                exe = Path(self.tmp.name) / ('t_crash_summary' + ('_asan' if flags else ''))
                r = subprocess.run([c_compiler(), '-std=gnu11', '-O1', '-g', '-Wall', '-Wextra', '-Werror', *flags, '-o', str(exe), str(src)], capture_output=True, text=True)
                if r.returncode and flags: self.skipTest(f'no sanitizers here: {r.stderr.strip()[:200]}')
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                r = subprocess.run([str(exe)], capture_output=True, text=True, timeout=300, env=dict(os.environ, ASAN_OPTIONS='detect_leaks=1', UBSAN_OPTIONS='halt_on_error=1'))
                self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
                self.assertIn('crash summary: OK', r.stdout)


class Wiring(unittest.TestCase):
    """The app runs the pieces where they are meant to run (nothing here runs them)"""

    def test_the_summary_follows_the_crash_line_on_the_metrics_queue(self):
        m = (REPO / 'dm/ios/Sources/DmMetrics.m').read_text()
        self.assertIn('#include "crash_summary.h"', m)
        store = m[m.index('void dm_metrics_store('):]
        store = store[:store.index('\n}\n')]
        self.assertIn('dispatch_async(g_metrics_q, ^{', store)
        self.assertRegex(store, r'metrics_log\(k, name, [^\n]*\);\n\s*if \(\[k isEqualToString:@"diagnostic-crash"\]\) metrics_crash_summary\(data\);')
        self.assertIn('stringByAppendingPathComponent:@"run_layouts.txt"', m)
        summ = m[m.index('static void metrics_crash_summary(NSData *json) {'):]
        summ = summ[:summ.index('\n}\n')]
        for rc, text in (('n == 0', 'the report holds no crash diagnostic the summary knows'), ('n == -2', 'the report is larger or nested deeper than the summary reads'),
                         ('n < 0', 'the report is not JSON the summary can read')):   # every outcome of dm_crash_summary but a summary gets a line
            self.assertRegex(summ, rf'if \({re.escape(rc)}\) LOG\("\[RED\] front end: crash: {re.escape(text)};')
        self.assertIn('dm_metrics_store(try encoder.encode(report), kind)', (REPO / 'dm/ios/Sources/Metrics.swift').read_text())   # MetricManager's reports take the same path

    def test_the_record_is_written_after_the_mods_and_waited_for_before_guest_code(self):
        loader, main = (HOST / 'loader.c').read_text(), (HOST / 'main.c').read_text()
        apply = loader[loader.index('void dm_mod_variants_apply(void) {'):]
        apply = apply[:apply.index('\n}\n')]
        self.assertRegex(apply, r'\n    run_layout_write\(on\);[^\n]*$')
        self.assertIn('dispatch_group_async_f(g_rl_group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), j, rl_write);', loader)
        guest = main[main.index('static void guest_main(void) {'):]
        self.assertRegex(guest, r'^static void guest_main\(void\) \{\n    \{ void dm_run_layout_wait\(void\); dm_run_layout_wait\(\); \}')
        self.assertLess(main.index('dm_mod_variants_apply(); }'), main.index('front_run(guest_main);'))

    def test_the_loader_logs_what_the_script_reads(self):
        loader = (HOST / 'loader.c').read_text()
        self.assertIn('LOG("%s: gates %d patch_off %#llx keys %lu/%lu/%lu/%lu key_page %#llx text_end %#llx"', loader)   # crashlog.py parse_log
        self.assertIn('run.jit_base = (uint64_t)(uintptr_t)g_jit_base; run.jit_size = g_jit_rx; run.jit_image = g_jit_img;', loader)
        self.assertIn('LOG("jit::CreateJitEnvironment: served from %s: code memory %p + %#llx (the image\'s first %#llx bytes)', (HOST / 'hle_jit.c').read_text())

    def test_the_host_tests_run_the_c_test(self):
        mk = (HOST / 'tests/Makefile').read_text()
        self.assertRegex(mk, r'(?m)^run: \$\(B\)/t_crash_summary$')
        self.assertRegex(mk, r'(?m)^\t\$\(B\)/t_crash_summary$')


if __name__ == '__main__':
    unittest.main()
