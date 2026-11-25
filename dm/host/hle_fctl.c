// A game's frame-rate controller judged with the host's clocks: the callback of observation gate OBS_FPS_CTL, which a game's patches.py places in its controller. Donkey Kong
// Bananza (v458752): at main+0x204a44, the controller's test of its off switch (main+0x204a18: x20 the controller, x8 its measure of the frame in system ticks, w9 the switch).
// The controller times frames on the wall clock, and an iPhone lowers its clocks at 30 fps, so it never saw 60 fit again (nvn_fctl.h has the whole story and the rules). The
// callback hands it the measure nvn_fctl_next decides, in the same ticks; a frame the controller does not judge (switched off, no measure) is left alone.
// DM_FPS_CTL=game gives the game's own measure back (an A/B; also from Documents/env.txt). docs/reference/frame-rate.md, A frame-rate controller timed by clocks that follow its interval
// DM_FPS_CTL=hold30 (the Battery Saver preset of a game whose profile has `preset battery DM_FPS_CTL=hold30`: Donkey Kong Bananza) holds the controller at interval 2 for good:
// each judged frame is handed the middle of interval 2's band, so it steps up to 2 three frames after it reads it and its countdown never moves; no probe back to 60, and
// the game's counter reports read their true times (hle_nvn.c nvn_gpu_time_scale_refresh: the profile's gpu_time_scale off), so its dynamic resolution has the whole 33 ms.
// The GPU clock rescue stays off under it (hle_nvn.c clock_rescue_tick), and its top rate reads 30. A cutscene's own fixed interval (lowest above 1) is left alone. The mode is
// read again once a second under the in-game menu's lock (front_env_copy), so the menu's preset change applies while the game runs: going back to the host's rule starts its
// probe wait afresh at the interval the game is at
// The log (logging only, nvn_fctl_obs; nothing in it goes back into a decision): per probe its start (a light one with its run's measures and the scene's before it), its return,
// how it ended and a line of its numbers (`probe of frame N held 8 s / failed / dropped / cut short`: its frames, the grace's and the rest's measures, its late frames, the GPU
// probe at its start and end); every 3,600 frames a summary with the time at each interval and what failed probes cost, in both modes (with DM_FPS_CTL=game the time only)
// DM_FPS_CTL_PROBE (on by default; =0 off): after a failed probe the next timed one waits while the measure at the longer interval is over 20.8 ms, and a probe whose frames after its
// grace do not hold 60 is ended at once (nvn_fctl.h has the rules; a rescue's or kick's probe and a light scene's are left as they were). Lines `the probe waits` and `the probe is
// ended early`; the summary line adds `DM_FPS_CTL_PROBE: probes ended early N, waits the gate held M`
#include "hle.h"
#include "../gfx/nvn/nvn_fctl.h"
#include <math.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include "front.h"

int dm_thermal_now(void);    // hle_nvn.c's weak default (-1, the Mac); the iOS front end's NSProcessInfo thermal state
int dm_low_power_now(void);  // Low Power Mode (iOS front end); off on the Mac
__attribute__((weak)) uint64_t mtl_gpu_probe_last(double *ratio) { (void)ratio; return 0; }   // nvn_mtl.m: the latest GPU probe against the session's fastest and the count; none here
__attribute__((weak)) void nvn_gpu_time_scale_refresh(void) {}   // hle_nvn.c: the GPU time scale follows the mode (hold30: the true times)
__attribute__((weak)) int front_env_copy(const char *name, char *out, size_t cap) { const char *e = getenv(name); if (cap) snprintf(out, cap, "%s", e ? e : ""); return e != NULL; }   // front_ios.m: under the menu's lock

#define FCTL_LINES 80   // event lines in a run (four a probe: its start, its return, how it ended, its numbers); the rest are counted in the summary lines
static nvn_fctl g_fc;     // the game's thread that runs the controller only
static uint64_t g_fc_prev, g_fc_sum_at, g_fc_up_at;   // the last call (now_ns); the frame of the last summary line; when the controller last came down by a probe
static int g_fc_lines, g_fc_said, g_fc_itv;
static nvn_fctl g_fc_last;   // the counts at the last summary line
static nvn_fctl_obs g_fo, g_fo_last;   // the probes' numbers and the time at each interval (logging only); at the last summary line
static double g_fo_r0; static uint64_t g_fo_n0, g_fo_at;   // at the start of the probe in progress: the GPU probe's ratio and count (0: none yet); the frame

// The GPU clock rescue (hle_nvn.c clock_rescue_tick) and this controller: its top rate for the rescue's target (60 over its lowest interval at its last judged frame: a
// cutscene's fixed 3 reads 20, which the rescue leaves alone; 0 before any), and a rescue's start, which makes the next judged frame at a longer interval a probe at once
// (the hold-off counted as spent; still only where a timed probe may start). The rescue's smaller frames are what such a try needs: Bananza's tries from 30 at full size
// were late at the lowered clock and failed (NX18-X2.0 gpu-clock-collapse.md)
static _Atomic int g_fc_top, g_fc_rescue;
static int g_fc_rescued;   // the controller's thread's: the probe this call started is the rescue's (its line says so)
void dm_fctl_rescue(void) { atomic_store_explicit(&g_fc_rescue, 1, memory_order_relaxed); }
// DM_CLOCK_RESCUE_S (hle_nvn.c clock_rescue_tick): while a rescue is under way the controller is kept at interval 1 (nvn_fctl.pin: its steps up to 2 blocked), for the rescue's
// hold; dm_fctl_pin(0) at its end releases it. Returns whether the host's rule gates a controller now (DM_FPS_CTL=host and a controller seen), so the rescue's line can say
// whether anything was held. The counts are the gate thread's, copied for the rescue's end line
static _Atomic int g_fc_pin;   // the rescue's hold in s while one is under way (0: none)
// The GPU clock cool-down (hle_nvn.c clock_rescue_tick, nvn_rescue.h): while one is under way the host's rule holds the controller at interval 3's band (20 fps; 2 where the
// controller has no 3), as the Battery Saver hold does at 2, with no probe back to 60, so the GPU's load drops by rate as well as by size; dm_fctl_cool(0) at its end hands the controller back to the host's rule
static _Atomic int g_fc_cool;
void dm_fctl_cool(int on) { atomic_store_explicit(&g_fc_cool, on ? 1 : 0, memory_order_relaxed); }
static _Atomic uint64_t g_fc_pinned, g_fc_pin_steps;
// DM_FPS_CTL: the host's rule (host, the default), the game's own (game) or the Battery Saver hold at interval 2 (hold30)
enum { FCTL_MODE_GAME, FCTL_MODE_HOST, FCTL_MODE_HOLD30 };
static _Atomic int g_fc_mode = -1;   // read at the first use, then again once a second by the gate (fctl_mode_poll)
static uint64_t g_fc_mode_at;        // the gate's thread: when it last read the mode
static int fctl_mode_parse(const char *e, int quiet) {
    if (e && !strcmp(e, "game")) return FCTL_MODE_GAME;
    if (e && !strcmp(e, "hold30")) return FCTL_MODE_HOLD30;
    if (e && *e && strcmp(e, "host") && !quiet) LOG("[RED] DM_FPS_CTL=%s: must be host, game or hold30; keeping host", e);
    return FCTL_MODE_HOST;
}
static int fctl_mode(void) {
    int m = atomic_load_explicit(&g_fc_mode, memory_order_relaxed);
    if (m < 0) { char e[16]; m = fctl_mode_parse(front_env_copy("DM_FPS_CTL", e, sizeof e) ? e : NULL, 0); atomic_store_explicit(&g_fc_mode, m, memory_order_relaxed); }
    return m;
}
static int fctl_on(void) { return fctl_mode() != FCTL_MODE_GAME; }   // the host hands the controller a measure (its rule or the hold)
int dm_fctl_hold30(void) { return fctl_mode() == FCTL_MODE_HOLD30; }   // hle_nvn.c: the GPU time scale and the clock rescue follow it
// The top rate: 60 over the lowest interval the controller may take, 30 under the hold (the clock rescue's target, so it leaves a game held at 30 alone)
int dm_fctl_top_fps(void) { int t = atomic_load_explicit(&g_fc_top, memory_order_relaxed); return t > 30 && dm_fctl_hold30() ? 30 : t; }
int dm_fctl_pin(int hold_s) { atomic_store_explicit(&g_fc_pin, hold_s > 0 ? hold_s : 0, memory_order_relaxed); return fctl_mode() == FCTL_MODE_HOST && atomic_load_explicit(&g_fc_top, memory_order_relaxed) > 0; }
void dm_fctl_pin_counts(uint64_t *frames, uint64_t *steps) { *frames = atomic_load_explicit(&g_fc_pinned, memory_order_relaxed); *steps = atomic_load_explicit(&g_fc_pin_steps, memory_order_relaxed); }
static const char *fctl_mode_words(int m) {
    return m == FCTL_MODE_HOLD30 ? "DM_FPS_CTL=hold30 (Battery Saver): the controller held at interval 2 (30 fps) for good, no probes back to 60; the game's counter reports read their true times"
         : m == FCTL_MODE_GAME ? "DM_FPS_CTL=game: the game's own measure (its rule alone decides 30 or 60)"
         : "DM_FPS_CTL=host: the host decides when the controller comes back from a longer interval";
}
// Once a second on the gate's thread: the mode again (the in-game menu's preset change). A change starts the host's rule afresh (its probe wait from the interval the game is at)
static void fctl_mode_poll(uint64_t now) {
    if (g_fc_mode_at && now - g_fc_mode_at < 1000000000ull) return;
    const int first = !g_fc_mode_at; g_fc_mode_at = now;
    if (first) return;
    char e[16]; const int m = fctl_mode_parse(front_env_copy("DM_FPS_CTL", e, sizeof e) ? e : NULL, 1), was = fctl_mode();
    if (m == was) return;
    atomic_store_explicit(&g_fc_mode, m, memory_order_relaxed);
    const nvn_fctl keep = g_fc; memset(&g_fc, 0, sizeof g_fc);   // the decisions start again; the counts stay for the summary
    g_fc.probes = keep.probes; g_fc.lights = keep.lights; g_fc.downs = keep.downs; g_fc.held = keep.held; g_fc.failed = keep.failed; g_fc.aborted = keep.aborted; g_fc.kept = keep.kept; g_fc.graced = keep.graced;
    g_fc.pinned = keep.pinned; g_fc.pin_steps = keep.pin_steps; g_fc.cuts = keep.cuts; g_fc.gated = keep.gated;
    memset(&g_fo.cur, 0, sizeof g_fo.cur);
    LOG("[nvn] frame-rate controller: now %s (the in-game menu's preset, frame %llu)", fctl_mode_words(m), (unsigned long long)dm_nvn_frame_count());
    nvn_gpu_time_scale_refresh();
}
static double ms(double vsyncs) { return vsyncs * 1000.0 / 60; }
// DM_FPS_CTL_PROBE (nvn_fctl.h, the two rules on the timed probes): unset or 1, on with the gate at FCTL_GATE (20.8 ms); <ms> (15 to 40), on with that gate; 0, off (the rules before
// them). Read once, at the first judged frame
static double g_fc_gate = -1;
static double fctl_gate_vsyncs(void) {
    if (g_fc_gate >= 0) return g_fc_gate;
    const char *e = getenv("DM_FPS_CTL_PROBE"); double g = FCTL_GATE;
    if (e && *e) {
        char *end; const double v = strtod(e, &end);
        if (*end || v < 0 || (v > 1 && (v < 15 || v > 40)) || (v > 0 && v < 1)) LOG("[RED] DM_FPS_CTL_PROBE=%s: must be 0, 1 or a gate in ms from 15 to 40; keeping 1 (%.1f ms)", e, ms(FCTL_GATE));
        else g = v == 0 ? 0 : v == 1 ? FCTL_GATE : v * 60 / 1000;
    }
    if (g > 0) LOG("[nvn] frame-rate controller: DM_FPS_CTL_PROBE on: after a failed probe the next timed one waits while the mean at the longer interval is over %.1f ms; a probe whose frames after its grace run %d of %d over %.1f ms is ended at once (=0 turns both off)",
                   ms(g), FCTL_CUT_N, FCTL_CUT_W, ms(1 + FSTEP_LATE));
    else LOG("[nvn] frame-rate controller: DM_FPS_CTL_PROBE=0: the probes' gate and early end off");
    return g_fc_gate = g;
}
static void fctl_summary(uint64_t frame, int host, int hold) {
    const nvn_fctl *s = &g_fc, *p = &g_fc_last; const nvn_fctl_obs *o = &g_fo, *q = &g_fo_last;
    const double t1 = (o->t[0] - q->t[0]) / 60, t2 = (o->t[1] - q->t[1]) / 60, t3 = (o->t[2] - q->t[2]) / 60;
    char tm[80]; snprintf(tm, sizeof tm, "time at interval 1 %.1f s, 2 %.1f s, 3+ %.1f s", t1, t2, t3);
    if (!host) { if (t1 + t2 + t3 > 0) LOG("[nvn] frame-rate controller up to frame %llu (DM_FPS_CTL=%s): %s", (unsigned long long)frame, hold ? "hold30" : "game", tm); g_fo_last = g_fo; return; }
    if (s->probes == p->probes && s->kept == p->kept && s->graced == p->graced && s->aborted == p->aborted && s->gated == p->gated && t1 + t2 + t3 <= 0) return;
    char pr[96] = "";
    if (s->gate > 0) snprintf(pr, sizeof pr, "; DM_FPS_CTL_PROBE: probes ended early %llu, waits the gate held %llu", (unsigned long long)(s->cuts - p->cuts), (unsigned long long)(s->gated - p->gated));
    LOG("[nvn] frame-rate controller up to frame %llu: probes %llu (%llu on a light scene), back at interval 1 %llu, held 8 s %llu, failed %llu, dropped %llu; frames whose return the host held %llu, grace frames kept at interval 1 %llu; interval %d now, probes wait %.0f s; %s; failed probes: %llu late frames, %.0f ms over%s",
        (unsigned long long)frame, (unsigned long long)(s->probes - p->probes), (unsigned long long)(s->lights - p->lights), (unsigned long long)(s->downs - p->downs),
        (unsigned long long)(s->held - p->held), (unsigned long long)(s->failed - p->failed), (unsigned long long)(s->aborted - p->aborted), (unsigned long long)(s->kept - p->kept),
        (unsigned long long)(s->graced - p->graced), s->itv, s->hold / 60, tm, (unsigned long long)(o->flate - q->flate), ms(o->flate_v - q->flate_v), pr);
    g_fc_last = *s; g_fo_last = *o;
}
static int fctl_line(void) {   // one more event line, or none past FCTL_LINES
    if (g_fc_lines >= FCTL_LINES) { if (g_fc_lines++ == FCTL_LINES) LOG("[nvn] frame-rate controller: further probes only counted in its summary lines"); return 0; }
    return ++g_fc_lines;
}
static void fctl_event(uint64_t frame, double m, double margin, int th) {
    const nvn_fctl *s = &g_fc;
    if (s->ev == FCTL_EV_NONE || s->ev == FCTL_EV_UP || !fctl_line()) return;
    switch (s->ev) {
    case FCTL_EV_PROBE:
        g_fc_itv = g_fc.itv;
        if (s->plight) {
            const nvn_fctl_pr *p = &g_fo.cur; char bs[48] = "";
            if (p->base > 0) snprintf(bs, sizeof bs, ", the scene before it %.1f ms", ms(p->base));
            LOG("[nvn] frame-rate controller: probe back to interval 1 at frame %llu: a light scene, %d frames in a row under %.1f ms at interval %d (the controller's own return is at %.1f ms); the run %.1f ms mean, %.1f max%s",
                (unsigned long long)frame, FCTL_LIGHT_N, ms(FCTL_LIGHT), s->itv, ms(s->itv - 1 - margin), ms(p->lmean), ms(p->lmax), bs);
        } else if (g_fc_rescued) {
            const int pin = atomic_load_explicit(&g_fc_pin, memory_order_relaxed);
            LOG("[nvn] frame-rate controller: probe back to interval 1 at frame %llu for the GPU clock rescue (its frames drawn smaller for %d s%s): interval %d, measure %.1f ms a frame (the controller's own return is under %.1f ms), thermal state %d",
                (unsigned long long)frame, pin > 0 ? pin : 3, pin > 0 ? ", interval 1 held through it" : "", s->itv, ms(s->pmean), ms(s->itv - 1 - margin), th);
        }
        else LOG("[nvn] frame-rate controller: probe back to interval 1 at frame %llu: interval %d for %.1f s, measure %.1f ms a frame (the controller's own return is under %.1f ms; its clocks are the lowered ones), thermal state %d",
                 (unsigned long long)frame, s->itv, s->since / 60, ms(s->pmean), ms(s->itv - 1 - margin), th);
        break;
    case FCTL_EV_DOWN:
        g_fc_up_at = now_ns();
        LOG("[nvn] frame-rate controller: interval %d → 1 at frame %llu by the probe; the next %d frames are judged at most %.1f ms while the clocks rise, then by the game's own measure",
            g_fc_itv, (unsigned long long)frame, FSTEP_GRACE, ms(nvn_fctl_at(1, margin)));
        break;
    case FCTL_EV_HELD:
        LOG("[nvn] frame-rate controller: interval 1 held %.0f s after the probe (frame %llu): failures forgotten, probes wait 1 s again", FSTEP_HOLD_MAX / 60, (unsigned long long)frame);
        break;
    case FCTL_EV_FAILED:
        LOG("[nvn] frame-rate controller: the probe failed: the game stepped up to interval %d %.1f s after it came back (frame %llu, measure %.1f ms); next probe after %.0f s, or a light scene under %.1f ms",
            s->itv, g_fc_up_at ? (now_ns() - g_fc_up_at) / 1e9 : 0.0, (unsigned long long)frame, ms(m), s->hold / 60, ms(fmin(FCTL_LIGHT, FSTEP_FIT * s->pfail)));
        break;
    case FCTL_EV_GATED:
        LOG("[nvn] frame-rate controller: the probe waits (DM_FPS_CTL_PROBE, frame %llu): interval %d for %.1f s, measure %.1f ms a frame, over the gate's %.1f ms since the probe that failed (at %.1f ms); it starts once the mean is under it, or on a light scene",
            (unsigned long long)frame, s->itv, s->since / 60, ms(s->mean), ms(s->gate), ms(s->pfail));
        break;
    case FCTL_EV_CUT:
        LOG("[nvn] frame-rate controller: the probe is ended early (DM_FPS_CTL_PROBE, frame %llu): %d of the last %d frames after its grace over %.1f ms (this one %.1f ms); the controller is handed interval 2's band until it steps up",
            (unsigned long long)frame, __builtin_popcount((unsigned)s->cbits), FCTL_CUT_W, ms(1 + FSTEP_LATE), ms(m));
        break;
    case FCTL_EV_ABORTED:
        LOG("[nvn] frame-rate controller: no return within %d frames (the game holds interval %d, frame %llu): the probe is dropped, the next one waits %.0f s", FCTL_PROBE_MAX, s->itv, (unsigned long long)frame, s->hold / 60);
        break;
    }
}
// The numbers of the probe that ended at this call (g_fo.last): its frames, the game's own measure in its grace and after it, its late frames, the GPU probe at its start and end
static void fctl_probe_end(uint64_t frame) {
    static const char *const why[] = {[FCTL_EV_HELD] = "held 8 s", [FCTL_EV_FAILED] = "failed", [FCTL_EV_ABORTED] = "dropped", [FCTL_EV_UP] = "cut short"};
    const nvn_fctl_pr *p = &g_fo.last;
    if (!fctl_line()) return;
    char g[64] = "", a[48] = "", gp[48] = ""; double r1 = 0; const uint64_t n1 = mtl_gpu_probe_last(&r1);
    if (p->gn) snprintf(g, sizeof g, "; grace %d: %.1f ms mean, %.1f max", p->gn, ms(p->gsum / p->gn), ms(p->gmax));
    if (p->an) snprintf(a, sizeof a, "; after it %d: %.1f ms mean", p->an, ms(p->asum / p->an));
    if (g_fo_n0) { if (n1 > g_fo_n0) snprintf(gp, sizeof gp, "; GPU probe %.2fx → %.2fx", g_fo_r0, r1); else snprintf(gp, sizeof gp, "; GPU probe %.2fx → no newer", g_fo_r0); }
    LOG("[nvn] frame-rate controller: probe of frame %llu %s (frame %llu): %d frames%s%s; late %d, %.0f ms over%s", (unsigned long long)g_fo_at,
        p->why >= 0 && p->why < (int)(sizeof why / sizeof *why) && why[p->why] ? why[p->why] : "ended", (unsigned long long)frame, p->n, g, a, p->late, ms(p->over), gp);
}
static void fctl_gate(uint64_t *r, int param) {
    (void)param;
    fctl_mode_poll(now_ns());
    const int mode = fctl_mode(), cool = mode == FCTL_MODE_HOST && atomic_load_explicit(&g_fc_cool, memory_order_relaxed);
    const int host = mode == FCTL_MODE_HOST && !cool, hold = mode == FCTL_MODE_HOLD30 || cool;   // a cool-down under way: the hold's band, the host's rule paused
    if (mode == FCTL_MODE_GAME) { static int said; if (!said++) LOG("[nvn] frame-rate controller: DM_FPS_CTL=game, the game's own measure (its rule alone decides 30 or 60; the summary lines still give the time at each interval)"); }
    if (hold && !cool) { static int said; if (!said++) LOG("[nvn] frame-rate controller: %s (the summary lines give the time at each interval)", fctl_mode_words(mode)); }
    const int64_t raw = (int64_t)r[8];
    if ((r[9] & 0xff) || raw <= 0) return;   // the controller does not judge this frame (switched off, or no measure): neither does the host
    const uint8_t *c = (const uint8_t *)(uintptr_t)r[20];
    int32_t imin, imax, itv; float margin;
    memcpy(&imin, c, 4); memcpy(&imax, c + 4, 4); memcpy(&margin, c + 8, 4); memcpy(&itv, c + 0x40, 4);
    if (imin < 1 || imax > 6 || imin > imax || itv < 1 || itv > 6 || !(margin > -1 && margin < 1)) {   // not the controller this was written for: leave it alone
        static int red; if (!red++) LOG("[RED] frame-rate controller: settings not as expected (intervals %d-%d, now %d, margin %.2f): the game's own measure stays", imin, imax, itv, margin);
        return;
    }
    atomic_store_explicit(&g_fc_top, 60 / imin, memory_order_relaxed);
    if (host && !g_fc_said) { g_fc_said = 1; LOG("[nvn] frame-rate controller (observation gate in the game's controller; its intervals %d-%d, margin %.2f): the host decides when it comes back from a longer interval (nvn_fctl.h; DM_FPS_CTL=game for the game's own rule)", imin, imax, margin); }
    const uint64_t now = now_ns(); const double shown = g_fc_prev ? (now - g_fc_prev) / (1e9 / 60) : 1; g_fc_prev = now;
    const uint64_t frame = dm_nvn_frame_count();
    if (hold && imin == 1 && imax >= 2) {   // the Battery Saver hold: interval 2's band, every judged frame (a game's own fixed interval, imin above 1, is left alone)
        // a cool-down holds interval 3's band (20 fps) where the controller has it: at 30 the GPU stayed 45-55% busy and the clock low through five cool-downs (Bananza, c7ab1aad);
        // the pause menu that brings it back runs 20-30% busy, and 20 fps of the same frames comes to about 33%
        const int at = cool && imax >= 3 ? 3 : 2;
        const double tpv = (double)guest_tick_hz() / 60;
        long long t = llround(nvn_fctl_at(at, margin) * tpv); r[8] = (uint64_t)(t > 0 ? t : 1);
        g_fc.itv = itv;
    }
    if (host) {
        const double tpv = (double)guest_tick_hz() / 60;   // system ticks a vsync
        const int th = dm_thermal_now(), may = th <= 1 && !dm_low_power_now();   // timed probes: the frame step's gates (thermal nominal or fair, Low Power Mode off)
        int rescue = 0;
        if (atomic_exchange_explicit(&g_fc_rescue, 0, memory_order_relaxed) && may && imin == 1 && itv > 1 && !g_fc.probe && g_fc.itv == itv) {   // a clock rescue: its hold-off spent
            if (g_fc.since < g_fc.hold) g_fc.since = g_fc.hold;
            rescue = 1;
        }
        g_fc.pin = atomic_load_explicit(&g_fc_pin, memory_order_relaxed) > 0;   // DM_CLOCK_RESCUE_S: a rescue under way keeps interval 1
        g_fc.gate = fctl_gate_vsyncs(); g_fc.rescue = rescue;   // DM_FPS_CTL_PROBE; a rescue's or kick's probe passes the gate, and its run is never ended early
        const double m = raw / tpv, v = nvn_fctl_next(&g_fc, itv, imin, imax, margin, m, shown, may);
        if (g_fc.pin) { atomic_store_explicit(&g_fc_pinned, g_fc.pinned, memory_order_relaxed); atomic_store_explicit(&g_fc_pin_steps, g_fc.pin_steps, memory_order_relaxed); }
        if (v != m) { long long t = llround(v * tpv); r[8] = (uint64_t)(t > 0 ? t : 1); }
        nvn_fctl_obs_next(&g_fo, &g_fc, m, shown);   // logging only: reads what nvn_fctl_next decided
        const int next = g_fo.ended && g_fc.ev == FCTL_EV_PROBE;   // a probe ended at the call that starts the next (a step up across a stay in the background): its line first
        if (next) fctl_probe_end(frame);
        g_fc_rescued = rescue && g_fc.ev == FCTL_EV_PROBE; fctl_event(frame, m, margin, th); g_fc_rescued = 0;
        if (g_fo.ended && !next) fctl_probe_end(frame);
        if (g_fc.ev == FCTL_EV_PROBE) { g_fo_n0 = mtl_gpu_probe_last(&g_fo_r0); g_fo_at = frame; }
    }
    nvn_fctl_obs_time(&g_fo, itv, shown);
    if (frame >= g_fc_sum_at + 3600) { fctl_summary(frame, host, hold); g_fc_sum_at = frame; }
}
__attribute__((constructor)) static void fctl_attach(void) { gate_obs_set(OBS_FPS_CTL, fctl_gate); }
