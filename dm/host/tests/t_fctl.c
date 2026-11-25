// The frame-rate controller gate's callback (hle_fctl.c): registers as the controller (main+0x204a18) has them at the gate (x20 the controller, x8 its measure in system ticks,
// w9 its off switch) and a controller block with its settings (+0 lowest interval, +4 highest, +8 margin, +0x40 the interval now). The decisions themselves are nvn_fctl.h's
// (dm/gfx/tests/t_fctl.c); this checks what the gate reads and writes: ticks at the Switch 2's 31.25 MHz, frames left alone, DM_FPS_CTL=game
#define DM_LOG_IMPL   // the log lines are kept here (dm_log below) for the checks of the probe and summary lines
#include "../hle_fctl.c"
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>

static char g_log[400][640]; static int g_nlog;
void dm_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsnprintf(g_log[g_nlog % 400], sizeof g_log[0], fmt, ap); va_end(ap); g_nlog++; }
static int logged_at(const char *a, const char *b, int from) {   // the first line since line `from` holding a and b (b may be NULL): its number, or -1
    for (int i = from > g_nlog - 400 ? from : g_nlog - 400; i < g_nlog; i++) { const char *l = g_log[i % 400]; if (strstr(l, a) && (!b || strstr(l, b))) return i; }
    return -1;
}
static const char *logged(const char *a, const char *b, int from) { const int i = logged_at(a, b, from); return i < 0 ? NULL : g_log[i % 400]; }

static uint64_t t_now = 1000000000ull, t_frame;
uint64_t now_ns(void) { return t_now; }
uint64_t guest_tick_hz(void) { return 31250000; }
uint64_t dm_nvn_frame_count(void) { return t_frame; }
int dm_thermal_now(void) { return 0; }
int dm_low_power_now(void) { return 0; }
static void (*g_cb)(uint64_t *, int); static int g_cb_id;
void gate_obs_set(int id, void (*fn)(uint64_t *regs, int param)) { g_cb_id = id; g_cb = fn; }

static int checks, fails;
#define CHECK(c, s) do { checks++; int ok_ = !!(c); fails += !ok_; printf("%s %s\n", ok_ ? "✓" : "✗", s); } while (0)
typedef struct { int32_t imin, imax; float margin; int32_t up_n, down_n; uint8_t pad[0x40 - 0x14]; int32_t cur; } ctl_block;
static const double TPV = 31250000.0 / 60;   // ticks a vsync
// One gate hit, a vsync per interval after the last; returns the measure the controller is handed, in vsyncs
static double hit(ctl_block *c, double vsyncs, int off) {
    uint64_t r[32] = {0}; r[20] = (uint64_t)(uintptr_t)c; r[8] = (uint64_t)llround(vsyncs * TPV); r[9] = off ? 0x101 : 0x100;   // w9: only the byte counts (ldrb)
    t_now += (uint64_t)(c->cur * 1e9 / 60); t_frame++;
    g_cb(r, 0);
    return (int64_t)r[8] / TPV;
}

int main(void) {
    CHECK(g_cb == fctl_gate && g_cb_id == OBS_FPS_CTL, "the callback is attached to OBS_FPS_CTL");
    ctl_block c = {.imin = 1, .imax = 3, .margin = -0.2f, .up_n = 2, .down_n = 6, .cur = 1};
    double v = hit(&c, 1.05, 0);
    CHECK(fabs(v - 1.05) < 1e-6, "interval 1 outside a grace: the game's own measure, the same ticks");
    c.cur = 2; v = hit(&c, 1.1, 0);   // the game stepped up: its return is held at interval 2
    CHECK(fabs(v - nvn_fctl_at(2, -0.2)) < 1e-6, "interval 2: a measure under its band is handed in the middle of it (the countdown does not move)");
    v = hit(&c, 1.1, 1);
    CHECK(fabs(v - 1.1) < 1e-6, "the controller switched off (w9's byte): left alone");
    uint64_t r[32] = {0}; r[20] = (uint64_t)(uintptr_t)&c; r[8] = 0; g_cb(r, 0);
    CHECK(r[8] == 0, "no measure (0 ticks): left alone, as the controller skips it");
    // the hold-off (1 s) ends: the probe hands the band of interval 1, in ticks the game reads as that
    int probed = 0;
    for (int i = 0; i < 40 && !probed; i++) { v = hit(&c, 1.3, 0); probed = fabs(v - nvn_fctl_at(1, -0.2)) < 1e-6; }
    CHECK(probed && g_fc.probes == 1, "after 1 s at interval 2 a probe hands the band of interval 1");
    CHECK((int)(float)(v - 0.2) + 1 == 1, "the ticks it wrote are interval 1 to the controller's own arithmetic");
    // settings that are not the controller's: left alone, one red line
    ctl_block bad = c; bad.margin = 3.0f; v = hit(&bad, 1.3, 0);
    CHECK(fabs(v - 1.3) < 1e-6, "a margin out of range: left alone");
    // DM_FPS_CTL=game: the game's own measure
    {
        nvn_fctl before = g_fc; ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .cur = 2};
        setenv("DM_FPS_CTL", "game", 1); g_fc_mode = -1; v = hit(&d, 1.1, 0);
        CHECK(fabs(v - 1.1) < 1e-6 && g_fc.probes == before.probes, "DM_FPS_CTL=game: the game's own measure, nothing decided");
        unsetenv("DM_FPS_CTL"); g_fc_mode = -1;
    }
    // Logging only: a replayed run through the gate (with the probe and summary lines) hands the controller what nvn_fctl_next alone decides on the same frames, frame for
    // frame. The controller is modelled roughly (three frames that want more step it up, a countdown of 6 frames that want less steps it down); the phone lowers its clocks at
    // interval 2 (a scene of 1.07 vsyncs at 1 measures 1.5 there) and raises them over the 10 frames after a return
    // Twice: with DM_FPS_CTL_PROBE=0 (the rules before it), then by default (its gate and early end on: the decision alone is handed the same gate)
    for (int pass = 0; pass < 2; pass++) {
        if (!pass) setenv("DM_FPS_CTL_PROBE", "0", 1); else unsetenv("DM_FPS_CTL_PROBE");
        g_fc_gate = -1;
        memset(&g_fc, 0, sizeof g_fc); memset(&g_fc_last, 0, sizeof g_fc_last); memset(&g_fo, 0, sizeof g_fo); memset(&g_fo_last, 0, sizeof g_fo_last);
        g_fc_prev = 0; g_fc_sum_at = t_frame; g_fc_lines = 0; const int from = g_nlog; const uint64_t f0 = t_frame;
        nvn_fctl bare; memset(&bare, 0, sizeof bare); bare.gate = pass ? FCTL_GATE : 0; uint64_t bprev = 0;
        ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .up_n = 2, .down_n = 6, .cur = 1};
        int late = 0, cd = 0, since1 = 99, same = 1, n = 0;
        // phases: frames, the scene's measure at interval 1 (vsyncs), at 2; a load's frame of 20 vsyncs once
        const struct { int frames; double at1, at2; } ph[] = {{300, 1.07, 1.5}, {4, 1.6, 2.0}, {700, 1.07, 1.5}, {1500, 1.6, 2.0}, {40, 0.3, 0.3}, {1300, 1.07, 1.5}};
        for (unsigned k = 0; k < sizeof ph / sizeof *ph; k++)
            for (int i = 0; i < ph[k].frames; i++, n++) {
                const double m = d.cur == 1 ? (since1 < 10 && ph[k].at1 > 1 ? ph[k].at2 - (ph[k].at2 - ph[k].at1) * since1 / 10 : ph[k].at1) : ph[k].at2;
                const double shown = d.cur == 1 ? (m > 1.1 ? 2 : 1) : d.cur;
                uint64_t r[32] = {0}; r[20] = (uint64_t)(uintptr_t)&d; r[8] = (uint64_t)llround(m * TPV); r[9] = 0x100;
                t_now += (uint64_t)(shown * 1e9 / 60); t_frame++;
                const double mb = (int64_t)r[8] / TPV, sb = bprev ? (t_now - bprev) / (1e9 / 60) : 1; bprev = t_now;   // the decision alone, as the gate computes its inputs
                const double vb = nvn_fctl_next(&bare, d.cur, d.imin, d.imax, d.margin, mb, sb, 1);
                long long tb = llround(vb * TPV); const uint64_t want = vb != mb ? (uint64_t)(tb > 0 ? tb : 1) : r[8];
                g_cb(r, 0);
                same &= r[8] == want && nvn_fctl_same(&g_fc, &bare);
                const double v = (int64_t)r[8] / TPV; const int w = (int)(float)(v + d.margin) + 1 > 3 ? 3 : (int)(float)(v + d.margin) + 1;
                since1 = d.cur == 1 ? since1 + 1 : 0;
                if (w > d.cur) { if (++late >= 3) { d.cur = w; cd = 6; late = 0; } } else { late = 0; if (w < d.cur) { if (cd) cd--; else { d.cur--; cd = 6; since1 = 0; } } }
            }
        char b[240]; snprintf(b, sizeof b, "%s: the gate with its log lines hands what nvn_fctl_next alone decides, %d frames (probes %llu: held %llu, failed %llu, %llu on a light scene; %llu waits the gate held)",
                              pass ? "DM_FPS_CTL_PROBE on" : "DM_FPS_CTL_PROBE=0", n, (unsigned long long)g_fc.probes, (unsigned long long)g_fc.held, (unsigned long long)g_fc.failed,
                              (unsigned long long)g_fc.lights, (unsigned long long)g_fc.gated);
        CHECK(same && g_fc.held >= 1 && g_fc.failed >= 1 && (pass ? g_fc.gated >= 1 && g_fc.probes < 5 : g_fc.lights >= 1 && g_fc.gated == 0), b);
        if (pass) {   // the heavy stretch after the failure: one wait held, its line; the scene that lightens then probes by the mean (before the sixth light frame) and holds
            const char *w = logged("frame-rate controller: the probe waits (DM_FPS_CTL_PROBE, frame ", "measure 33.3 ms a frame, over the gate's 20.8 ms since the probe that failed", from);
            const char *on = logged("frame-rate controller: DM_FPS_CTL_PROBE on: after a failed probe", "over 20.8 ms", from), *sm = logged("frame-rate controller up to frame", "; DM_FPS_CTL_PROBE: probes ended early 0, waits the gate held 1", from);
            CHECK(w && on && sm, "  its lines: the switch at the first frame, the wait the gate held, the summary's counts");
            if (w) printf("  %s\n", w);
            continue;
        }
        CHECK(!logged("DM_FPS_CTL_PROBE: probes ended early", NULL, from) && logged("DM_FPS_CTL_PROBE=0: the probes' gate and early end off", NULL, from), "  DM_FPS_CTL_PROBE=0: its line, and the summary without its counts");
        const char *held = logged("frame-rate controller: probe of frame", " held 8 s (frame ", from), *failed = logged("frame-rate controller: probe of frame", " failed (frame ", from);
        const char *light = logged("a light scene, 6 frames in a row", "; the run ", from), *sum = logged("frame-rate controller up to frame", "time at interval 1 ", from);
        CHECK(held && strstr(held, "; grace 30: ") && strstr(held, "; after it ") && strstr(held, " ms over"), "a held probe's line: its frames, the grace's measures and the rest's, its late frames");
        CHECK(failed && strstr(failed, "; grace 30: ") && !strstr(failed, "; late 0,"), "a failed probe's line: its late frames");
        CHECK(light && strstr(light, "the run 5.0 ms mean, 5.0 max, the scene before it 33.3 ms"), "a light probe's start: the run's measures and the scene's before it");
        CHECK(sum && strstr(sum, ", 3+ 0.0 s; failed probes: ") && !strstr(sum, "failed probes: 0 late"), "the summary line: the time at each interval and the failed probes' late frames");
        double t1 = 0, t2 = 0; if (sum) sscanf(strstr(sum, "time at interval 1 "), "time at interval 1 %lf s, 2 %lf s", &t1, &t2);
        snprintf(b, sizeof b, "the summary's time: %.1f s at interval 1, %.1f s at 2, after %llu frames", t1, t2, (unsigned long long)(t_frame - f0)); CHECK(t1 > 30 && t2 > 5, b);
        const char *ex[] = {light, held, failed, sum}; for (int i = 0; i < 4; i++) if (ex[i]) printf("  %s\n", ex[i]);
    }
    // DM_FPS_CTL=game: no measure handed, the summary line gives the time at each interval
    {
        setenv("DM_FPS_CTL", "game", 1); g_fc_mode = -1; const int from = g_nlog; g_fc_sum_at = t_frame; g_fo_last = g_fo; int same = 1;
        ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .cur = 1};
        for (int i = 0; i < 3700; i++) { d.cur = i < 2500 ? 1 : 2; double v = hit(&d, d.cur == 1 ? 1.07 : 1.5, 0); same &= fabs(v - (d.cur == 1 ? 1.07 : 1.5)) < 1e-6; }
        const char *sum = logged("frame-rate controller up to frame", "(DM_FPS_CTL=game): time at interval 1 ", from);
        CHECK(same && sum && strstr(sum, "time at interval 1 41.7 s, 2 36.7 s, 3+ 0.0 s"), "DM_FPS_CTL=game: the game's own measure every frame, and the summary's time at each interval");
        if (sum) printf("  %s\n", sum);
        unsetenv("DM_FPS_CTL"); g_fc_mode = -1;
    }
    // A probe that fails on the frame that starts the next (the game steps up across a 3 s stay in the background: the next probe waits 2 s): its line, failed, with its
    // late frames, before the next probe's start
    {
        memset(&g_fc, 0, sizeof g_fc); memset(&g_fc_last, 0, sizeof g_fc_last); memset(&g_fo, 0, sizeof g_fo); memset(&g_fo_last, 0, sizeof g_fo_last);
        g_fc_prev = 0; g_fc_sum_at = t_frame; g_fc_lines = 0; const int from = g_nlog;
        ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .cur = 1};
        hit(&d, 1.0, 0); d.cur = 2;
        for (int i = 0; i < 40 && g_fc.ev != FCTL_EV_PROBE; i++) hit(&d, 1.5, 0);
        const uint64_t f0 = t_frame;
        for (int i = 0; i < 7; i++) hit(&d, 1.5, 0);
        d.cur = 1; hit(&d, 1.3, 0);
        for (int i = 0; i < 5; i++) { t_now += (uint64_t)(1e9 / 60); hit(&d, 1.3, 0); }   // 5 frames of 2 vsyncs in the grace
        d.cur = 2; t_now += (uint64_t)(178 * 1e9 / 60); hit(&d, 1.5, 0);
        char end[96], start[96]; snprintf(end, sizeof end, "frame-rate controller: probe of frame %llu failed (frame %llu): ", (unsigned long long)f0, (unsigned long long)t_frame);
        snprintf(start, sizeof start, "frame-rate controller: probe back to interval 1 at frame %llu: ", (unsigned long long)t_frame);
        const int ie = logged_at(end, "; late 5, 83 ms over", from), is = logged_at(start, NULL, from);
        CHECK(g_fc.ev == FCTL_EV_PROBE && g_fc.failed == 1 && ie >= 0 && is > ie, "a probe failed on the frame that starts the next: its line (failed, its 5 late frames), then the next one's start");
        if (ie >= 0) printf("  %s\n", g_log[ie % 400]);
    }
    // The GPU clock rescue (hle_nvn.c clock_rescue_tick): the controller's top rate is its target (60 over its lowest interval: a cutscene's fixed 3 reads 20), and a rescue's
    // start makes the next judged frame at a longer interval a probe at once, whatever the hold-off (still only where a timed probe may start), with a line that says so
    {
        memset(&g_fc, 0, sizeof g_fc); memset(&g_fo, 0, sizeof g_fo); g_fc_prev = 0; g_fc_lines = 0; const int from = g_nlog;
        ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .cur = 1};
        hit(&d, 1.0, 0); int top60 = dm_fctl_top_fps() == 60;
        d.cur = 2; hit(&d, 1.5, 0); g_fc.hold = FSTEP_PHOLD_MAX;   // at 30 after failed probes: the next timed probe 32 s away
        int none = 1; for (int i = 0; i < 10; i++) { hit(&d, 1.5, 0); none &= g_fc.ev != FCTL_EV_PROBE; }
        dm_fctl_rescue(); v = hit(&d, 1.5, 0);
        CHECK(top60 && none && g_fc.ev == FCTL_EV_PROBE && fabs(v - nvn_fctl_at(1, -0.2)) < 1e-6 && logged("probe back to interval 1 at frame", "for the GPU clock rescue", from),
              "a clock rescue at 30 with the hold-off at 32 s: a probe at the next judged frame, its line says the rescue");
        for (int i = 0; i < 3; i++) hit(&d, 1.5, 0);
        CHECK(g_fc.probe > 1 && !logged("for the GPU clock rescue", NULL, logged_at("for the GPU clock rescue", NULL, from) + 1), "  one probe, one rescue line");
        memset(&g_fc, 0, sizeof g_fc); d.cur = 1; hit(&d, 1.0, 0);
        dm_fctl_rescue(); hit(&d, 1.0, 0); d.cur = 2; hit(&d, 1.5, 0); hit(&d, 1.5, 0);
        CHECK(g_fc.probes == 0, "  a rescue that finds the controller at interval 1 is spent there: no probe after it at 30");
        ctl_block cs = {.imin = 3, .imax = 3, .margin = -0.2f, .cur = 3}; hit(&cs, 2.5, 0);
        CHECK(dm_fctl_top_fps() == 20, "  a cutscene's fixed interval 3: the top rate 20, so the rescue (target below 60) leaves it alone");
    }
    // DM_CLOCK_RESCUE_S (hle_nvn.c clock_rescue_tick): dm_fctl_pin(hold) while a rescue is under way keeps the controller at interval 1 (every frame at most interval 1's band,
    // its steps up to 2 blocked and counted), dm_fctl_pin(0) releases it; the rescue's probe line names the hold. Nothing is pinned with DM_FPS_CTL=game or hold30
    {
        memset(&g_fc, 0, sizeof g_fc); memset(&g_fo, 0, sizeof g_fo); g_fc_prev = 0; g_fc_lines = 0; const int from = g_nlog;
        ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .cur = 1};
        hit(&d, 1.0, 0);
        const int gated = dm_fctl_pin(10); int band = 1;
        for (int i = 0; i < 9; i++) band &= fabs(hit(&d, 1.3, 0) - nvn_fctl_at(1, -0.2)) < 1e-6;
        uint64_t pf, ps; dm_fctl_pin_counts(&pf, &ps);
        CHECK(gated && band && pf == 9 && ps == 3, "pinned (DM_CLOCK_RESCUE_S): 9 heavy frames at interval 1 handed interval 1's band, 3 steps up to 2 blocked");
        CHECK(fabs(hit(&d, 0.5, 0) - 0.5) < 1e-6, "  a frame that fits: its own measure");
        dm_fctl_pin(0); v = hit(&d, 1.3, 0); dm_fctl_pin_counts(&pf, &ps);
        CHECK(fabs(v - 1.3) < 1e-6 && pf == 9 && ps == 3, "  released: the game's own measure again, the counts kept");
        d.cur = 2; hit(&d, 1.5, 0); g_fc.hold = FSTEP_PHOLD_MAX;
        dm_fctl_pin(10); dm_fctl_rescue(); hit(&d, 1.5, 0);
        CHECK(logged("for the GPU clock rescue (its frames drawn smaller for 10 s, interval 1 held through it)", NULL, from) != NULL, "  the rescue's probe line names the 10 s hold");
        dm_fctl_pin(0);
        setenv("DM_FPS_CTL", "game", 1); g_fc_mode = -1;
        const int game = dm_fctl_pin(10); v = hit(&d, 1.3, 0); dm_fctl_pin(0);
        CHECK(!game && fabs(v - 1.3) < 1e-6, "  DM_FPS_CTL=game: dm_fctl_pin says nothing is gated, the game's own measure");
        setenv("DM_FPS_CTL", "hold30", 1); g_fc_mode = -1;
        CHECK(!dm_fctl_pin(10), "  DM_FPS_CTL=hold30: nothing gated (the rescue stays off there anyway)");
        dm_fctl_pin(0); unsetenv("DM_FPS_CTL"); g_fc_mode = -1; g_fc_mode_at = 0;
    }
    // DM_FPS_CTL=hold30 (Battery Saver): interval 2's band every judged frame, so the controller steps up to 2 and stays; no probe, light scenes and rescues included; the
    // top rate 30 (the clock rescue's target); a cutscene's own interval 3 left alone; the menu's change back to host read within a second, the host's probe wait from there
    {
        memset(&g_fc, 0, sizeof g_fc); memset(&g_fo, 0, sizeof g_fo); g_fc_prev = 0; g_fc_lines = 0; const int from = g_nlog;
        setenv("DM_FPS_CTL", "hold30", 1); g_fc_mode = -1; g_fc_mode_at = 0;
        ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .cur = 1};
        int late = 0, cd = 6, band = 1, ever1 = 0; const uint64_t p0 = g_fc.probes;
        for (int i = 0; i < 4000; i++) {   // light frames (a menu), an ordinary scene and a heavy one, a rescue now and then
            const double m = i < 1000 ? 0.3 : i < 3000 ? 1.05 : 1.6;
            if (i % 500 == 499) dm_fctl_rescue();
            const double v = hit(&d, m, 0); band &= fabs(v - nvn_fctl_at(2, -0.2)) < 1e-6;
            const int w = (int)(float)(v + d.margin) + 1;
            if (w > d.cur) { if (++late >= 3) { d.cur = w; cd = 6; late = 0; } } else { late = 0; if (w < d.cur) { if (cd) cd--; else { d.cur--; cd = 6; } } }
            if (i > 3) ever1 |= d.cur == 1;
        }
        CHECK(band && d.cur == 2 && !ever1 && g_fc.probes == p0 && dm_fctl_hold30() && dm_fctl_top_fps() == 30,
              "hold30: interval 2's band every frame, the controller at 2 from its fourth frame for good, no probe (light scenes and rescues too), top rate 30");
        CHECK(logged("frame-rate controller: DM_FPS_CTL=hold30 (Battery Saver)", "no probes back to 60", from) != NULL, "  one line naming the mode");
        ctl_block cs = {.imin = 3, .imax = 3, .margin = -0.2f, .cur = 3}; double v3 = hit(&cs, 2.5, 0);
        CHECK(fabs(v3 - 2.5) < 1e-6, "  a cutscene's own interval 3: its own measure");
        setenv("DM_FPS_CTL", "host", 1);   // the in-game menu's preset change back to Balanced
        int back = 0; for (int i = 0; i < 61 && !back; i++) { hit(&d, 1.05, 0); back = !dm_fctl_hold30(); }
        CHECK(back && logged("frame-rate controller: now DM_FPS_CTL=host", "the in-game menu's preset", from) && dm_fctl_top_fps() == 60, "  the menu's change to host read within a second, with a line; top rate 60 again");
        int probed = 0; for (int i = 0; i < 70 && !probed; i++) { hit(&d, 1.3, 0); probed = g_fc.ev == FCTL_EV_PROBE; }
        CHECK(probed && g_fc.probes == p0 + 1, "  then the host's rule: a probe after its 1 s wait from the change");
        unsetenv("DM_FPS_CTL"); g_fc_mode = -1;
    }
    // DM_FPS_CTL_PROBE through the gate (on by default): a CPU-capped scene (19 ms frames at 60, under the controller's own step) ends its probe early, with a line; the next
    // timed probe waits while the mean at 30 is over 20.8 ms; a GPU clock rescue or kick (dm_fctl_rescue: hle_nvn.c's clock_kick_tick after its hold, clock_rescue_tick)
    // still probes at once and its run is not ended early; the values of the switch
    {
        memset(&g_fc, 0, sizeof g_fc); memset(&g_fc_last, 0, sizeof g_fc_last); memset(&g_fo, 0, sizeof g_fo); memset(&g_fo_last, 0, sizeof g_fo_last);
        g_fc_prev = 0; g_fc_lines = 0; g_fc_gate = -1; unsetenv("DM_FPS_CTL_PROBE"); const int from = g_nlog;
        ctl_block d = {.imin = 1, .imax = 3, .margin = -0.2f, .cur = 1};
        hit(&d, 1.0, 0); d.cur = 2;
        for (int i = 0; i < 80 && g_fc.ev != FCTL_EV_PROBE; i++) hit(&d, 1.5, 0);
        for (int i = 0; i < 7; i++) hit(&d, 1.5, 0);
        d.cur = 1; for (int i = 0; i < FSTEP_GRACE; i++) hit(&d, 1.15, 0);
        double v4 = 0; for (int i = 0; i < 4; i++) v4 = hit(&d, 1.15, 0);
        const char *cl = logged("frame-rate controller: the probe is ended early (DM_FPS_CTL_PROBE, frame ", "4 of the last 8 frames after its grace over 18.3 ms (this one 19.2 ms)", from);
        CHECK(g_fc.cuts == 1 && fabs(v4 - nvn_fctl_at(2, -0.2)) < 1e-6 && cl, "a capped probe (19.2 ms frames after its grace): ended early, interval 2's band handed, its line");
        if (cl) printf("  %s\n", cl);
        for (int i = 0; i < 2; i++) hit(&d, 1.15, 0);
        d.cur = 2; hit(&d, 1.5, 0);
        CHECK(g_fc.failed == 1 && logged("frame-rate controller: the probe failed", NULL, from) && logged("frame-rate controller: probe of frame", " failed (frame ", from), "  then the step up: a failed probe, its lines as any other");
        uint64_t p0 = g_fc.probes; for (int i = 0; i < 200; i++) hit(&d, 1.5, 0);
        CHECK(g_fc.probes == p0 && g_fc.gated == 1, "  3.3 s at 30 with the mean at 25 ms: the next probe waits (one wait held)");
        dm_fctl_rescue(); double v = hit(&d, 1.5, 0);   // the clock kick's call after its hold (or the rescue's start)
        CHECK(g_fc.ev == FCTL_EV_PROBE && g_fc.presc && fabs(v - nvn_fctl_at(1, -0.2)) < 1e-6 && logged("probe back to interval 1 at frame", "for the GPU clock rescue", from),
              "  the clock kick's dm_fctl_rescue: a probe at once over the gate, its rescue line");
        for (int i = 0; i < 7; i++) hit(&d, 1.5, 0);
        d.cur = 1; int own = 1; for (int i = 0; i < FSTEP_GRACE; i++) hit(&d, 1.15, 0); for (int i = 0; i < 40; i++) own &= fabs(hit(&d, 1.15, 0) - 1.15) < 1e-6;
        CHECK(own && g_fc.cuts == 1, "  its run after the grace: the game's own measure, not ended early");
        // the switch's values
        const struct { const char *e; double g; int red; } vs[] = {{"0", 0, 0}, {"1", FCTL_GATE, 0}, {"22", 22 * 60 / 1000.0, 0}, {"abc", FCTL_GATE, 1}, {"0.5", FCTL_GATE, 1}, {"90", FCTL_GATE, 1}};
        int ok = 1; for (unsigned i = 0; i < sizeof vs / sizeof *vs; i++) {
            const int f = g_nlog; setenv("DM_FPS_CTL_PROBE", vs[i].e, 1); g_fc_gate = -1;
            ok &= fabs(fctl_gate_vsyncs() - vs[i].g) < 1e-9 && (logged("[RED] DM_FPS_CTL_PROBE=", NULL, f) != NULL) == vs[i].red;
        }
        CHECK(ok, "DM_FPS_CTL_PROBE: 0 off, 1 the 20.8 ms gate, 22 a 22 ms gate; anything else a red line and the default");
        unsetenv("DM_FPS_CTL_PROBE"); g_fc_gate = -1;
    }
    printf("%d checks, %d failed\n", checks, fails);
    return fails != 0;
}
