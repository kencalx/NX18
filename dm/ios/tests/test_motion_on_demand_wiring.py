"""The phone's motion sensors on demand (DmGamepad.m, DM_MOTION_ON_DEMAND; hle_hid.c dm_six_axis_wanted), checked in the sources off the device. dm/host/tests t_hid
t_six_axis_wanted runs the host's side (starts, stops, the IMU, the read before any start, the hook); here: that the streams start only where the switch allows, that the hook is
set, that leaving and coming back reach the gate, that the old side keeps the streams on, and the switch's row."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def first_statement(fn):
    """The function's first line of code (after the line that opens it, which may carry a comment)"""
    return fn.split('\n', 1)[1].strip()


def body(src, header):
    """The text of the function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


class MotionOnDemand(unittest.TestCase):
    def setUp(self):
        self.pad = read('dm/ios/Sources/DmGamepad.m'); self.hid = read('dm/host/hle_hid.c')

    def test_streams_start_only_in_the_gate(self):
        # Every start of a Core Motion stream is in sensors_set (on demand) or motion_sensors_begin's old side, never in the setup functions
        starts = [m.start() for m in re.finditer(r'start(Accelerometer|DeviceMotion)UpdatesToQueue', self.pad)]
        self.assertEqual(len(starts), 4, 'two streams, each started in sensors_set and in the old side')
        gate = body(self.pad, 'static void sensors_set(BOOL on)'); begin = body(self.pad, 'static void motion_sensors_begin(void)')
        old = begin[begin.index('if (!g_on_demand) {'):begin.index('dm_six_axis_hook')]
        for name in ('Accelerometer', 'DeviceMotion'):
            self.assertIn(f'start{name}UpdatesToQueue', gate); self.assertIn(f'start{name}UpdatesToQueue', old)
            self.assertIn(f'stop{name}Updates', gate)
        self.assertNotIn('UpdatesToQueue', body(self.pad, 'static void motion_start(void)'))
        self.assertNotIn('UpdatesToQueue', body(self.pad, 'static void phone_motion_start(UIView *body)'))

    def test_gate_reads_the_host(self):
        apply = body(self.pad, 'static void sensors_apply(void)')
        self.assertTrue(first_statement(apply).startswith('if (!g_on_demand) return;'), 'DM_MOTION_ON_DEMAND=0: the gate does nothing')
        self.assertIn('g_sens_active && dm_six_axis_wanted()', apply)
        self.assertIn('dispatch_after', apply, 'a stop waits, a start does not')
        begin = body(self.pad, 'static void motion_sensors_begin(void)')
        self.assertIn('getenv("DM_MOTION_ON_DEMAND")', begin); self.assertIn('dm_six_axis_hook(six_axis_changed)', begin)
        self.assertIn('dispatch_async(dispatch_get_main_queue()', body(self.pad, 'static void six_axis_changed(void)'))
        self.assertIn('motion_start();\n        phone_motion_start(self);\n        motion_sensors_begin();', self.pad)

    def test_leaving_and_coming_back(self):
        active = self.pad[self.pad.index('void dm_gamepad_active(void)'):]; active = active[:active.index('\n')]
        reset = body(self.pad, 'void dm_gamepad_reset(void)')
        self.assertIn('sensors_active(YES)', active); self.assertIn('sensors_active(NO)', reset)
        self.assertTrue(first_statement(body(self.pad, 'static void sensors_active(BOOL active)')).startswith('if (!g_on_demand) return;'))

    def test_host_calls(self):
        for name in ('h_hid_SixStart', 'h_hid_SixStop'):
            line = next(l for l in self.hid.splitlines() if f', {name},' in l)
            self.assertIn('six_started(*h,', line)
        self.assertIn('six_imu_want(1)', body(self.hid, 'Result, h_hid_ImuEnable, void *buf, uint64_t size)'))
        self.assertIn('six_imu_want(0)', body(self.hid, 'Result, h_hid_ImuDisable, void)'))
        self.assertIn('six_read_note(h);', body(self.hid, 'static int six_states(SixAxisState *out, int n, uint32_t h)'))
        self.assertIn('int dm_six_axis_wanted(void);', read('dm/host/dm_input.h'))
        self.assertIn('int dm_six_axis_wanted(void)', read('dm/ios/tests/duo/Sources/DuoRuntimeStubs.m'))

    def test_stop_shuts_out_queued_samples(self):
        # Core Motion still runs samples queued before a stop: the shake's handler may set the shake only while the stream is live, and the stop shuts it out and clears the
        # shake in one locked step before stopping the streams (else a sample queued mid-shake leaves it held with no sample to come and clear it)
        gate = body(self.pad, 'static void sensors_set(BOOL on)')
        off = gate[gate.index('} else {'):]
        self.assertIn('pthread_mutex_lock(&g_mu); g_acc_live = NO; BOOL held = g_shake_btn != 0; g_shake_btn = 0; pthread_mutex_unlock(&g_mu);', off)
        self.assertLess(off.index('g_acc_live = NO'), off.index('stopAccelerometerUpdates'))
        on = gate[:gate.index('} else {')]
        self.assertLess(on.index('g_acc_live = YES'), on.index('startAccelerometerUpdatesToQueue'))
        acc = body(self.pad, 'static void motion_start(void)')
        self.assertIn('BOOL live = !g_on_demand || g_acc_live, changed = live && g_shake_btn != want;', acc)
        self.assertIn('if (live) g_shake_btn = want;', acc)
        # A pending stop that finds the streams already stopped (the app left meanwhile) does nothing, so it logs no second stop
        self.assertIn('gen != g_sens_stop_gen || !g_sens_on ||', body(self.pad, 'static void sensors_apply(void)'))

    def test_switch_row(self):
        row = next((l for l in read('docs/env_switches.tsv').splitlines() if l.startswith('DM_MOTION_ON_DEMAND\t')), '')
        self.assertIn('\tswitch\t', row)


if __name__ == '__main__':
    unittest.main()
