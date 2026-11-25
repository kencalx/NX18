// A game's frame-rate controller judged with the host's clocks (nvn_fctl.h): Donkey Kong Bananza's controller (main+0x204a18 in v458752) modelled as its code does it, on a phone
// whose GPU clock follows the interval. Frames are simulated in vsyncs: a frame's GPU time is the scene's time at the clock interval 1 needs (base) times the clock factor, which
// moves a fifth of the way to its target each frame (the phone settles within about 10-15 frames); the target is 1 at interval 1 and at interval k the clock that fills about 90 %
// of k vsyncs, at most `low` times slower. The controller's measure is the frame's latency before the GPU (lat) plus its GPU time; a frame stays on screen its interval, or the
// whole vsyncs its GPU time takes. The game steps by the interval it set (game time), real time is what the frames showed.
#include "../nvn/nvn_fctl.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int fail, checks;
static void check(int ok, const char *what) { checks++; fail += !ok; printf("%-100s %s\n", what, ok ? "✓" : "✗"); }

// The controller, as main+0x204a18 does it: settings (imin 1, imax 3, margin -0.2, 2 late frames before a step up, a countdown of 6 to come back), state +0x40 (cur), +0x44 (back),
// +0x48 (late), +0x4c (countdown). veto: a listener of the controller holds every step down
typedef struct { int imin, imax, up_n, down_n, cur, back, late, cd, veto; double margin; } ctl;
static ctl ctl_new(void) { return (ctl){.imin = 1, .imax = 3, .up_n = 2, .down_n = 6, .cur = 1, .back = 1, .margin = -0.2}; }
static int ctl_want(const ctl *c, double v) {
    int t = (int)(float)(v + c->margin), w = t + 1 >= c->imax ? c->imax : t + 1;
    return t + 1 < c->imin ? c->imin : w;
}
static void ctl_judge(ctl *c, double v) {
    int want = ctl_want(c, v), cur = c->cur;
    if (want > cur) {
        if (c->late >= c->up_n) { c->cd = c->down_n; c->back = want - 1 > c->imin ? want - 1 : c->imin; c->late = 0; c->cur = want; return; }
        c->late++;
    } else c->late = 0;
    if (c->cd) { if (want < cur && c->cd >= 1) c->cd--; return; }
    if (c->back >= cur || c->veto) return;
    int b = c->back;
    if (b > c->imin) { c->back = b - 1 > c->imin ? b - 1 : c->imin; c->cd = c->down_n; }
    c->cur = b;
}

typedef struct {
    ctl c; nvn_fctl s; nvn_fctl_obs o; int host, may, log; double f, low, real, game, at1, m; long frames, changes, late1, ends[FCTL_EV_UP + 1]; int last;
} sim;
// log: the host's logging (nvn_fctl_obs) runs beside the decisions, as hle_fctl.c has it; every check below runs with it
static sim sim_new(int host, double low) { sim x; memset(&x, 0, sizeof x); x.c = ctl_new(); x.host = host; x.may = 1; x.f = 1; x.low = low; x.last = 1; x.log = 1; return x; }
// One frame of a scene whose GPU time at interval 1's clock is base and whose latency before the GPU is lat (vsyncs). Returns the measure the controller judged
static double frame(sim *x, double base, double lat) {
    int k = x->c.cur;
    double tgt = k == 1 ? 1 : 0.9 * k / base; if (tgt < 1) tgt = 1; if (tgt > x->low) tgt = x->low;
    x->f += (tgt - x->f) / 5;
    double gpu = base * x->f, m = lat + gpu, shown = gpu > k + 0.05 ? (double)(int)(gpu + 0.95) : k;
    x->real += shown; x->game += k; x->frames++; x->m = m;
    if (k == 1) { x->at1 += shown; x->late1 += shown > 1; }
    double v = x->host ? nvn_fctl_next(&x->s, k, x->c.imin, x->c.imax, x->c.margin, m, shown, x->may) : m;
    if (x->host && x->log) { nvn_fctl_obs_next(&x->o, &x->s, m, shown); nvn_fctl_obs_time(&x->o, k, shown); x->ends[x->o.last.why] += x->o.ended; }
    ctl_judge(&x->c, v);
    x->changes += x->c.cur != x->last; x->last = x->c.cur;
    return v;
}
// Frames for t vsyncs of real time
static void run_for(sim *x, double t, double base, double lat) { double t0 = x->real; while (x->real - t0 < t) frame(x, base, lat); }
// A hitch: three frames of 1.5 vsyncs of GPU time at any clock (a load of a few textures), which steps the controller up
static void hitch(sim *x) { for (int i = 0; i < 3; i++) { double f = x->f; x->f = 1.5 / 0.82; frame(x, 0.82, 0.25); x->f = f; } }

int main(void) {
    char b[200];
    // The bands: the measure nvn_fctl_at gives for n is taken for n, with the game's margin and others
    {
        const double margins[] = {-0.2, 0.0, 0.3, -0.45}; int ok = 1;
        for (unsigned i = 0; i < sizeof margins / sizeof *margins; i++) { ctl c = ctl_new(); c.margin = margins[i]; for (int n = 1; n <= 3; n++) ok &= ctl_want(&c, nvn_fctl_at(n, c.margin)) == n; }
        check(ok, "nvn_fctl_at(n) is in the controller's band for n (margins -0.2, 0, 0.3, -0.45)");
    }
    // The bug: a scene that holds 60 at the phone's clock for it (GPU 13.6 ms, the measure 1.07 vsyncs) steps to 30 at a hitch; at 30 the phone lowers its clocks (1.3 times
    // slower: the MetalFX log's 13.6 → 17.7 ms; 1.84 with the game's own upscaler: 25 ms) and the measure stays over 1.2 vsyncs
    for (int u = 0; u < 2; u++) {
        double low = u ? 1.84 : 1.3;
        sim a = sim_new(0, low); run_for(&a, 600, 0.82, 0.25); hitch(&a); double t0 = a.at1; run_for(&a, 3600, 0.82, 0.25);
        snprintf(b, sizeof b, "clocks %.2fx slower at 30: without the host, interval 2 for the minute after the hitch (%.0f vsyncs at 1)", low, a.at1 - t0); check(a.c.cur == 2 && a.at1 - t0 < 10, b);
        sim h = sim_new(1, low); run_for(&h, 600, 0.82, 0.25); hitch(&h); double r0 = h.real; long c0 = h.changes;
        while (h.c.cur != 1 && h.real - r0 < 3600) frame(&h, 0.82, 0.25);
        double back = h.real - r0; long late0 = h.late1; double a0 = h.at1, rr = h.real; run_for(&h, 3600, 0.82, 0.25);
        snprintf(b, sizeof b, "clocks %.2fx: with the host, back to interval 1 %.0f vsyncs after the hitch (1 s hold-off + 7-frame countdown)", low, back); check(back > 60 && back < 100, b);
        snprintf(b, sizeof b, "clocks %.2fx: interval 1 held for the next minute: %.0f of %.0f vsyncs, %ld change (the return), 1 probe held", low, h.at1 - a0, h.real - rr, h.changes - c0);
        check(h.c.cur == 1 && h.at1 - a0 == h.real - rr && h.changes - c0 == 1 && h.s.probes == 1 && h.s.held == 1 && h.s.failed == 0, b);
        snprintf(b, sizeof b, "clocks %.2fx: frames late in the probe's grace while the clock rose: %ld (game slower than real time only then)", low, h.late1 - late0); check(h.late1 - late0 <= 12, b);
        // the log's numbers for that probe: held, its 30 grace frames and the run after them, its late frames among the sim's, all of real time at an interval
        const nvn_fctl_pr *p = &h.o.last; const double tt = h.o.t[0] + h.o.t[1] + h.o.t[2];
        snprintf(b, sizeof b, "clocks %.2fx: the log: probe held after %d frames (grace %d, %.2f mean, %.2f max; after it %d, %.2f mean), %d late", low, p->n, p->gn, p->gsum / p->gn, p->gmax, p->an,
                 p->an ? p->asum / p->an : 0, p->late);
        check(h.ends[FCTL_EV_HELD] == 1 && !h.o.on && p->why == FCTL_EV_HELD && !p->light && p->gn == FSTEP_GRACE && p->an > 400 && p->n - p->gn - p->an >= 1 && p->n - p->gn - p->an <= FCTL_PROBE_MAX
              && p->gmax >= p->gsum / p->gn && p->asum / p->an < 1.2 && p->late <= h.late1 - late0, b);
        snprintf(b, sizeof b, "clocks %.2fx: the log's time at an interval is the run's real time (%.0f of %.0f vsyncs; %.0f at 1)", low, tt, h.real, h.o.t[0]); check(fabs(tt - h.real) < 1e-6 && h.o.t[0] > 0.9 * tt, b);
    }
    // A scene that cannot hold 60 at any clock (GPU 1.3 vsyncs at the full clock): it stays at 30, the probes back off (1, 2, 4, 8, 16, 32 s) and never flap
    {
        sim h = sim_new(1, 1.84); run_for(&h, 600, 0.82, 0.25); double r0 = h.real, a0 = h.at1; long c0 = h.changes;
        run_for(&h, 7200, 1.3, 0.25);
        double share = (h.at1 - a0) / (h.real - r0);
        snprintf(b, sizeof b, "heavy scene for 2 min: %llu probes, all failed, %.1f%% of the time at interval 1, %ld changes", (unsigned long long)h.s.probes, 100 * share, h.changes - c0);
        check(h.c.cur == 2 && h.s.probes >= 6 && h.s.probes <= 8 && h.s.failed + (h.c.cur == 1) >= h.s.probes - 1 && h.s.held == 0 && share < 0.08 && h.changes - c0 <= 2 * (long)h.s.probes + 1, b);
        snprintf(b, sizeof b, "heavy scene: the hold-off reached its most, %.0f vsyncs", h.s.hold); check(h.s.hold == FSTEP_PHOLD_MAX, b);
        snprintf(b, sizeof b, "heavy scene, the log: %ld failed probes ended, %llu late frames in them (%.0f vsyncs over); %.0f vsyncs at interval 1, %.0f at 2, as the frames showed",
                 h.ends[FCTL_EV_FAILED], (unsigned long long)h.o.flate, h.o.flate_v, h.o.t[0], h.o.t[1]);
        check(h.ends[FCTL_EV_FAILED] == (long)h.s.failed && h.o.flate >= h.s.failed && h.o.flate_v >= (double)h.o.flate && fabs(h.o.t[0] - h.at1) < 1e-6 && fabs(h.o.t[1] - (h.real - h.at1)) < 1e-6, b);
        // then the pause menu (about 1 ms of GPU a frame): back to interval 1 by the light rule, whatever the hold-off
        double t1 = h.real; while (h.c.cur != 1 && h.real - t1 < 600) frame(&h, 0.06, 0.15);
        snprintf(b, sizeof b, "then the pause menu: interval 1 after %.0f vsyncs (light probe; the game's own rule took 7 frames)", h.real - t1); check(h.c.cur == 1 && h.real - t1 <= 30 && h.s.lights == 1, b);
        const nvn_fctl_pr *lp = &h.o.cur;
        snprintf(b, sizeof b, "the log of the light probe's start: its run %.2f mean, %.2f max; the heavy scene before it %.2f vsyncs", lp->lmean, lp->lmax, lp->base);
        check(h.o.on && lp->light && lp->lmean > 0.15 && lp->lmax >= lp->lmean && lp->lmax < FCTL_LIGHT && lp->base > 1.5, b);
        // and back in the game where the scene fits: interval 1 stays, and 8 s there forget the failures
        double a1 = h.at1, r1 = h.real; run_for(&h, 900, 0.82, 0.25);
        snprintf(b, sizeof b, "back in a scene that fits: interval 1 stays, the hold-off is 1 s again (%.0f vsyncs)", h.s.hold); check(h.at1 - a1 == h.real - r1 && h.s.hold == FSTEP_HOLD0 && h.s.pfail == 0, b);
    }
    // A light probe (the pause menu) whose run ends when the menu closes onto a heavy scene: a failure for the hold-off, but the menu's measure is no limit for the next light probe
    {
        sim h = sim_new(1, 1.3); run_for(&h, 600, 0.82, 0.25); hitch(&h);
        double t1 = h.real; while (h.c.cur != 1 && h.real - t1 < 600) frame(&h, 0.06, 0.15);
        run_for(&h, 60, 0.06, 0.15); run_for(&h, 60, 1.3, 0.25);   // the menu for 1 s, then a scene that cannot hold 60, at the clocks the menu left
        snprintf(b, sizeof b, "a light probe ended by the scene: failed %llu, hold-off %.0f vsyncs, no measure kept (%.2f)", (unsigned long long)h.s.failed, h.s.hold, h.s.pfail);
        check(h.c.cur == 2 && h.s.failed == 1 && h.s.hold == 2 * FSTEP_HOLD0 && h.s.pfail == 0, b);
        double t2 = h.real; while (h.c.cur != 1 && h.real - t2 < 600) frame(&h, 0.06, 0.15);
        check(h.c.cur == 1 && h.real - t2 <= 30, "the menu again: back at interval 1 at once");
    }
    // A scene on the edge after failures: once it is lighter than where the last probe failed, a light frame run probes before the hold-off ends
    {
        sim h = sim_new(1, 1.84); run_for(&h, 600, 0.82, 0.25); run_for(&h, 1500, 1.3, 0.25);
        double pf = h.s.pfail; check(pf > 1.5 && h.s.hold > 4 * FSTEP_HOLD0, "after failed probes the scene where the last one began is remembered");
        sim g = h; run_for(&g, 30, 0.6, 0.35);   // measure about 1.4 at the lowered clock: not light, waits out the hold-off
        check(g.c.cur == 2, "a lighter scene that is not light at the lowered clock waits out the hold-off");
    }
    // Heat: no timed probes while the caller forbids them (thermal state serious, Low Power Mode); a light scene still comes back
    {
        sim h = sim_new(1, 1.3); h.may = 0; run_for(&h, 600, 0.82, 0.25); hitch(&h); run_for(&h, 1800, 0.82, 0.25);
        check(h.c.cur == 2 && h.s.probes == 0, "may_probe 0: the scene stays at interval 2 for 30 s (no timed probe)");
        double t1 = h.real; while (h.c.cur != 1 && h.real - t1 < 600) frame(&h, 0.06, 0.15);
        check(h.c.cur == 1 && h.s.lights == 1, "may_probe 0: the pause menu still brings interval 1");
    }
    // The game's own step up is never held back: at interval 1 outside a grace the controller sees its own measure, and steps up as it would without the host
    {
        sim a = sim_new(0, 1.3), h = sim_new(1, 1.3); int same = 1;
        for (int i = 0; i < 600; i++) { frame(&a, 0.82, 0.25); frame(&h, 0.82, 0.25); }
        for (int i = 0; i < 5; i++) { frame(&a, 1.25, 0.25); double v = frame(&h, 1.25, 0.25); same &= a.c.cur == h.c.cur && v > 1.2; }
        check(same && h.c.cur == 2, "interval 1: the game's own step up after three late frames, frame for frame as without the host");
    }
    // An interval the game holds itself (a cutscene's 3, its lowest interval above 1): the measure goes through untouched
    {
        sim h = sim_new(1, 1.3); h.c.imin = 3; h.c.cur = 3; int same = 1;
        for (int i = 0; i < 300; i++) { double base = i % 50 < 25 ? 0.4 : 1.6, v = frame(&h, base, 0.25); same &= v == h.m; }
        check(same && h.s.probes == 0, "lowest interval 3 (cutscene): every measure goes through, no probe");
    }
    // A listener that holds the controller's return: the probe gives up after FCTL_PROBE_MAX frames and waits again; no failure counted
    {
        sim h = sim_new(1, 1.3); run_for(&h, 600, 0.82, 0.25); hitch(&h); h.c.veto = 1; run_for(&h, 300, 0.82, 0.25);
        snprintf(b, sizeof b, "a held return: %llu probes, %llu dropped, none failed, interval 2", (unsigned long long)h.s.probes, (unsigned long long)h.s.aborted);
        check(h.c.cur == 2 && h.s.aborted >= 1 && h.s.aborted <= h.s.probes && h.s.failed == 0, b);
        h.c.veto = 0; run_for(&h, 300, 0.82, 0.25); check(h.c.cur == 1, "the listener lets go: the next probe brings interval 1");
        check(h.ends[FCTL_EV_ABORTED] == (long)h.s.aborted && h.o.last.why == FCTL_EV_ABORTED && h.o.last.n == FCTL_PROBE_MAX && !h.o.last.gn && !h.o.last.an,
              "the log: each dropped probe ended once, after its 30 frames at interval 2");
    }
    // A load (a frame of 15 vsyncs or more) forgets the failures: the next probe waits 1 s
    {
        sim h = sim_new(1, 1.84); run_for(&h, 600, 0.82, 0.25); run_for(&h, 3000, 1.3, 0.25);
        check(h.s.hold >= 8 * FSTEP_HOLD0, "after failed probes the hold-off is 8 s or more");
        nvn_fctl_next(&h.s, h.c.cur, 1, 3, -0.2, 1.4, 20, 1);
        check(h.s.hold == FSTEP_HOLD0 && h.s.pfail == 0, "a frame of 20 vsyncs (a load) brings the hold-off back to 1 s");
    }
    // The probe's countdown: 7 frames a step, 14 from interval 3
    {
        nvn_fctl s; memset(&s, 0, sizeof s); ctl c = ctl_new(); c.cur = 3; c.back = 2; c.cd = 6; int n = 0;
        nvn_fctl_next(&s, 3, 1, 3, -0.2, 2.5, 3, 1); s.since = 1e9;   // first call: the hold-off is over
        while (c.cur != 1 && n < 40) { double v = nvn_fctl_next(&s, c.cur, 1, 3, -0.2, 2.5, c.cur, 1); ctl_judge(&c, v); n++; }
        snprintf(b, sizeof b, "a probe from interval 3 takes %d frames to bring interval 1", n); check(c.cur == 1 && n == 14, b);
        double v = nvn_fctl_next(&s, 1, 1, 3, -0.2, 2.5, 2, 1);
        check(s.ev == FCTL_EV_DOWN && s.grace == FSTEP_GRACE - 1 && v == nvn_fctl_at(1, -0.2), "it came down: the grace starts and holds the measure in interval 1's band");
    }
    // The log at frames that span real time the gate did not see (a stay in the background, a load, the controller switched off), called directly: each call also goes to a
    // state without the log, and the measure handed and the state must stay the same
    {
        nvn_fctl s, bare; nvn_fctl_obs o; long ends[FCTL_EV_UP + 1]; int same;
        #define FRESH() do { memset(&s, 0, sizeof s); memset(&bare, 0, sizeof bare); memset(&o, 0, sizeof o); memset(ends, 0, sizeof ends); same = 1; } while (0)
        #define CALL(itv, m, shown) do { const double v_ = nvn_fctl_next(&s, itv, 1, 3, -0.2, m, shown, 1); same &= v_ == nvn_fctl_next(&bare, itv, 1, 3, -0.2, m, shown, 1); \
                                         nvn_fctl_obs_next(&o, &s, m, shown); nvn_fctl_obs_time(&o, itv, shown); ends[o.last.why] += o.ended; same &= nvn_fctl_same(&s, &bare); } while (0)
        // A step up on a frame long enough to start the next probe at once (3 s: the hold-off is 1 s again, 2 s after the failure): the probe before it ends once, at that
        // call, failed (its late frames in the failed probes' cost) or cut short (a step up during its countdown), and the new one starts
        for (int u = 0; u < 2; u++) {
            FRESH(); CALL(1, 1.0, 1);
            for (int i = 0; i < 40 && s.ev != FCTL_EV_PROBE; i++) CALL(2, 1.5, 2);   // the step up; a timed probe 1 s later
            if (!u) { for (int i = 0; i < 7; i++) CALL(2, 1.5, 2); CALL(1, 1.3, 1); for (int i = 0; i < 5; i++) CALL(1, 1.3, 2); CALL(2, 1.5, 180); }   // back at 1, 5 late frames, up
            else { for (int i = 0; i < 3; i++) CALL(2, 1.5, 2); CALL(3, 2.5, 180); }   // up during its countdown
            const int why = u ? FCTL_EV_UP : FCTL_EV_FAILED; long all = 0; for (int k = 0; k <= FCTL_EV_UP; k++) all += ends[k];
            snprintf(b, sizeof b, "a step up across 3 s starts the next probe: the one before ended %s once (%ld ends; %d frames, late %d; failed probes' late %llu)", u ? "cut short" : "failed",
                     all, o.last.n, o.last.late, (unsigned long long)o.flate);
            check(same && s.ev == FCTL_EV_PROBE && s.probes == 2 && s.failed == (uint64_t)!u && o.ended && o.last.why == why && ends[why] == 1 && all == 1 && o.on && o.cur.n == 1
                  && o.last.n == (u ? 4 : 14) && o.last.late == (u ? 0 : 5) && o.flate == (uint64_t)o.last.late && o.flate_v == o.last.over, b);
        }
        // A long frame inside a probe is no late frame (the time at each interval leaves it out too): only the frame of 2 vsyncs after it is
        {
            FRESH(); CALL(1, 1.0, 1);
            for (int i = 0; i < 40 && s.ev != FCTL_EV_PROBE; i++) CALL(2, 1.5, 2);
            for (int i = 0; i < 7; i++) CALL(2, 1.5, 2);
            CALL(1, 0.9, 1); for (int i = 0; i < 40; i++) CALL(1, 0.9, 1);   // back at interval 1, on time past the grace
            CALL(1, 0.9, 200); CALL(1, 0.9, 2); for (int i = 0; i < 2; i++) CALL(1, 0.9, 1);   // 3.3 s the gate did not see, then one late frame
            CALL(2, 1.5, 2);   // the game steps up: the probe failed
            snprintf(b, sizeof b, "a 200-vsync frame inside a probe is no late frame: late %d, %.0f vsyncs over (failed probes: %llu, %.0f); %.0f vsyncs at interval 1", o.last.late, o.last.over,
                     (unsigned long long)o.flate, o.flate_v, o.t[0]);
            check(same && o.ended && o.last.why == FCTL_EV_FAILED && o.last.late == 1 && o.last.over == 1 && o.flate == 1 && o.flate_v == 1 && o.t[0] == 1 + 1 + 40 + 2 + 2, b);
        }
        #undef FRESH
        #undef CALL
    }
    // Logging only: the same frames with and without nvn_fctl_obs give the same measure handed and the same state at every frame, through every kind of probe and its end
    {
        sim a = sim_new(1, 1.84), l = sim_new(1, 1.84); a.log = 0; int same = 1; long n = 0;
        #define BOTH(call) do { { sim *x = &a; call; } { sim *x = &l; call; } } while (0)
        #define STEP(base, lat) do { double va = frame(&a, base, lat), vl = frame(&l, base, lat); same &= va == vl && a.c.cur == l.c.cur && nvn_fctl_same(&a.s, &l.s); n++; } while (0)
        #define RUN(t, base, lat) do { double t0 = a.real; while (a.real - t0 < (t)) STEP(base, lat); } while (0)
        RUN(600, 0.82, 0.25); BOTH(hitch(x)); RUN(3600, 0.82, 0.25);   // a probe held
        RUN(7200, 1.3, 0.25); RUN(120, 0.06, 0.15); RUN(900, 0.82, 0.25);   // failed probes, a light one, held
        BOTH(hitch(x)); a.c.veto = l.c.veto = 1; RUN(300, 0.82, 0.25); a.c.veto = l.c.veto = 0; RUN(300, 0.82, 0.25);   // dropped probes
        BOTH(hitch(x)); while (!a.s.probe && n < 100000) STEP(0.82, 0.25);   // a probe cut short: the game fixes interval 3 during its countdown (a cutscene)
        a.c.imin = l.c.imin = 3; a.c.cur = l.c.cur = 3; RUN(120, 1.6, 0.25); a.c.imin = l.c.imin = 1; RUN(600, 0.82, 0.25);
        STEP(20, 0.25); RUN(300, 0.82, 0.25);   // a load
        #undef BOTH
        #undef STEP
        #undef RUN
        snprintf(b, sizeof b, "with and without the log: %ld frames, the same measure handed and state every frame (%llu probes: held %ld, failed %ld, dropped %ld, cut short %ld)", n,
                 (unsigned long long)l.s.probes, l.ends[FCTL_EV_HELD], l.ends[FCTL_EV_FAILED], l.ends[FCTL_EV_ABORTED], l.ends[FCTL_EV_UP]);
        check(same && l.ends[FCTL_EV_HELD] >= 2 && l.ends[FCTL_EV_FAILED] >= 5 && l.ends[FCTL_EV_ABORTED] >= 1 && l.ends[FCTL_EV_UP] >= 1 && l.s.lights >= 1
              && l.ends[FCTL_EV_HELD] + l.ends[FCTL_EV_FAILED] + l.ends[FCTL_EV_ABORTED] + l.ends[FCTL_EV_UP] + l.o.on == (long)l.s.probes, b);
    }
    // DM_CLOCK_RESCUE_S's pin (nvn_fctl.pin, set by hle_fctl.c while a clock rescue is under way): at interval 1 every frame is handed at most interval 1's band, so the game's
    // steps up to 2 are blocked; each FCTL_UP_N frames in a row it would have stepped up on count as one blocked step. Off again, the game's own measure steps it up as before
    {
        sim x = sim_new(1, 1.84);
        run_for(&x, 600, 0.82, 0.25);   // settled at interval 1
        x.s.pin = 1; int stayed = 1; const uint64_t g0 = x.s.graced;
        for (int i = 0; i < 300; i++) { frame(&x, 1.3, 0.25); stayed &= x.c.cur == 1; }   // a heavy scene that fits no 16.7 ms: 5 s pinned
        snprintf(b, sizeof b, "pinned: a heavy scene stays at interval 1 for 300 frames, %llu frames handed interval 1's band, %llu steps up blocked",
                 (unsigned long long)x.s.pinned, (unsigned long long)x.s.pin_steps);
        check(stayed && x.s.pinned == 300 && x.s.pin_steps == 100 && x.s.graced == g0, b);
        x.s.pin = 0; int up = 0; for (int i = 0; i < 6 && !up; i++) { frame(&x, 1.3, 0.25); up = x.c.cur == 2; }
        check(up && x.s.pinned == 300 && x.s.pin_run == 0, "released: the game's own measure steps it up to 2 within a few frames, as before");
        // a light scene under the pin: nothing handed, nothing blocked
        sim y = sim_new(1, 1.84); run_for(&y, 600, 0.82, 0.25); y.s.pin = 1; run_for(&y, 300, 0.5, 0.1);
        check(y.s.pinned == 0 && y.s.pin_steps == 0 && y.c.cur == 1, "pinned on a scene that fits: its own measure, no step blocked");
        // pin unset: the same frames give the same state as before the field (the decisions read pin only when it is set)
        sim a = sim_new(1, 1.84), c = sim_new(1, 1.84); run_for(&a, 600, 0.82, 0.25); run_for(&c, 600, 0.82, 0.25);
        int ever2 = 0, same = 1; for (int i = 0; i < 300; i++) { double va = frame(&a, 1.3, 0.25), vc = frame(&c, 1.3, 0.25); same &= va == vc && nvn_fctl_same(&a.s, &c.s); ever2 |= a.c.cur == 2; }
        check(same && ever2 && a.s.pinned == 0 && a.s.pin_steps == 0, "no pin: the heavy scene steps up to 2 as before, nothing counted");
    }
    // DM_FPS_CTL_PROBE (nvn_fctl.gate): the gate on timed probes after a failure, and the early end of a probe whose frames after its grace do not hold 60. Called directly
    // (margin -0.2: the controller steps up when its measure is 1.2 vsyncs or more); P() takes the controller to interval 2 and runs a timed probe down to interval 1
    {
        nvn_fctl s; double v;
        #define NEXT(itv, m) nvn_fctl_next(&s, itv, 1, 3, -0.2, m, itv, 1)
        #define FRESH(g) do { memset(&s, 0, sizeof s); s.gate = (g); NEXT(1, 1.0); } while (0)
        // to interval 2 (frames of m2), the hold-off spent, the probe's countdown, back at 1: the call that came down
        #define P(m2) do { for (int i_ = 0; i_ < 400 && s.ev != FCTL_EV_PROBE; i_++) NEXT(2, m2); for (int i_ = 0; i_ < 7; i_++) NEXT(2, m2); NEXT(1, 1.0); } while (0)
        // a scene capped on the CPU: 1.5 vsyncs at 30 (the lowered clocks), 1.15 at 60 (19 ms: late, but under the controller's own step at 1.2)
        FRESH(FCTL_GATE); NEXT(2, 1.5); P(1.5);
        check(s.ev == FCTL_EV_DOWN && s.probes == 1 && s.gated == 0, "gate on: the first timed probe after a step up runs, whatever the measure at 30 (1.5 vsyncs: the lowered clocks)");
        int band1 = 1; for (int i = 1; i < FSTEP_GRACE; i++) band1 &= NEXT(1, 1.15) == nvn_fctl_at(1, -0.2);
        int at2 = 1, n = 0; for (; n < 3; n++) { v = NEXT(1, 1.15); if (n == 3 - 1) break; at2 &= v == 1.15; }
        v = NEXT(1, 1.15);
        snprintf(b, sizeof b, "early end: the grace as before, then 4 frames over 1.1 vsyncs after it: the fourth is handed interval 2's band (%llu cut)", (unsigned long long)s.cuts);
        check(band1 && at2 && s.ev == FCTL_EV_CUT && s.cuts == 1 && v == nvn_fctl_at(2, -0.2), b);
        at2 = 1; for (int i = 0; i < 3; i++) at2 &= NEXT(1, 1.15) == nvn_fctl_at(2, -0.2);
        NEXT(2, 1.5);   // the controller stepped up
        snprintf(b, sizeof b, "  then interval 2's band until the step up, a failed probe: failed %llu, hold-off %.0f vsyncs, its start's measure kept (%.2f)", (unsigned long long)s.failed, s.hold, s.pfail);
        check(at2 && s.ev == FCTL_EV_FAILED && s.failed == 1 && s.hold == 2 * FSTEP_HOLD0 && s.pfail > 1.4 && !s.cut && !s.probed, b);
        // the gate: the hold-off (2 s) ends with the mean at 1.5: no probe, one GATED event; the mean comes down under 1.25: the probe starts
        int none = 1, ev = 0; for (int i = 0; i < 300; i++) { NEXT(2, 1.5); none &= s.ev != FCTL_EV_PROBE; ev += s.ev == FCTL_EV_GATED; }
        snprintf(b, sizeof b, "gate: 5 s at 30 after the failure with the mean at 1.5 vsyncs: no probe, the gate held one wait (%llu, %d events), the hold-off %.0f", (unsigned long long)s.gated, ev, s.hold);
        check(none && s.gated == 1 && ev == 1 && s.probes == 1 && s.hold == 2 * FSTEP_HOLD0, b);
        int k = 0; while (s.ev != FCTL_EV_PROBE && k < 30) { NEXT(2, 1.1); k++; }
        snprintf(b, sizeof b, "  the scene gets lighter (1.1 vsyncs at 30): a probe once the mean is under the gate, %d frames later (mean %.3f)", k, s.pmean);
        check(s.ev == FCTL_EV_PROBE && s.probes == 2 && s.pmean <= FCTL_GATE && k >= 2 && k <= 8, b);
        // the same frames with DM_FPS_CTL_PROBE=0: the probe at the hold-off's end, the late frames after the grace handed through, no failure but the game's own
        FRESH(0); NEXT(2, 1.5); P(1.5); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.15);
        int same = 1; for (int i = 0; i < 500; i++) same &= NEXT(1, 1.15) == 1.15;
        check(same && s.cuts == 0 && s.failed == 0 && s.held == 1, "DM_FPS_CTL_PROBE=0: the frames of 1.15 after the grace go through (the game stays at 60 and the probe holds 8 s), nothing cut");
        FRESH(0); NEXT(2, 1.5); P(1.5); NEXT(2, 1.5); int pr = 0; for (int i = 0; i < 130; i++) { NEXT(2, 1.5); pr += s.ev == FCTL_EV_PROBE; }
        check(s.failed == 1 && pr == 1 && s.gated == 0, "DM_FPS_CTL_PROBE=0: after a failure the next probe at the hold-off's end, whatever the mean");
        // scattered late frames: 3 of every 8 never end the probe; 4 of 8 do
        FRESH(FCTL_GATE); NEXT(2, 1.5); P(1.5); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 0.9);
        for (int i = 0; i < 240; i++) NEXT(1, i % 8 < 3 ? 1.15 : 0.9);
        check(s.cuts == 0 && s.probed, "early end: 3 late frames in every 8 after the grace: the probe goes on");
        for (int i = 0; i < 8 && s.ev != FCTL_EV_CUT; i++) NEXT(1, i % 2 ? 1.15 : 0.9);
        check(s.cuts == 1, "  every other frame late: ended");
        // a frame in the grace counts for nothing: late frames there go through the grace's band, and the count starts after it
        FRESH(FCTL_GATE); NEXT(2, 1.5); P(1.5); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.4);
        for (int i = 0; i < 3; i++) NEXT(1, 1.15);
        check(s.cuts == 0 && s.ev != FCTL_EV_CUT, "  late frames in the grace do not count: 3 after it do not end it");
        // the pin (DM_CLOCK_RESCUE_S) holds interval 1: no early end under it
        FRESH(FCTL_GATE); NEXT(2, 1.5); P(1.5); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.15);
        s.pin = 1; for (int i = 0; i < 60; i++) NEXT(1, 1.15); s.pin = 0;
        check(s.cuts == 0, "  under the pin (DM_CLOCK_RESCUE_S): no early end");
        // a listener that holds the step up: interval 2's band for FCTL_PROBE_MAX frames, then the game's own measure and no more cut
        FRESH(FCTL_GATE); NEXT(2, 1.5); P(1.5); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.15);
        for (int i = 0; i < 4; i++) NEXT(1, 1.15);
        int held2 = 0; for (int i = 0; i < 60; i++) held2 += NEXT(1, 1.15) == nvn_fctl_at(2, -0.2);
        check(s.cuts == 1 && held2 == FCTL_PROBE_MAX && !s.cut && !s.probed && NEXT(1, 1.15) == 1.15, "  a step up held by a listener: interval 2's band for 30 frames, then the game's own measure");
        // the GPU clock rescue or kick (nvn_fctl.rescue, hle_fctl.c dm_fctl_rescue): its probe passes the gate and its run is never ended early
        FRESH(FCTL_GATE); NEXT(2, 1.5); P(1.5); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.15); for (int i = 0; i < 8; i++) NEXT(1, 1.15); NEXT(2, 1.5);
        for (int i = 0; i < 20; i++) NEXT(2, 1.5);
        check(s.failed == 1 && s.pfail > 1.4 && s.probes == 1, "rescue: a failed probe, the mean at 30 over the gate");
        nvn_fctl t = s; t.gate = 0;   // the same state with DM_FPS_CTL_PROBE=0, for the same rescue
        s.rescue = 1; if (s.since < s.hold) s.since = s.hold; v = NEXT(2, 1.5); s.rescue = 0;
        t.rescue = 1; if (t.since < t.hold) t.since = t.hold; nvn_fctl_next(&t, 2, 1, 3, -0.2, 1.5, 2, 1); t.rescue = 0;
        check(s.ev == FCTL_EV_PROBE && s.presc && v == nvn_fctl_at(1, -0.2) && t.ev == FCTL_EV_PROBE, "  a rescue's probe at once, over the gate, as with the switch off");
        for (int i = 0; i < 7; i++) NEXT(2, 1.5); NEXT(1, 1.0); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.15);
        same = 1; for (int i = 0; i < 60; i++) same &= NEXT(1, 1.15) == 1.15;
        check(same && s.cuts == 1 && s.probed, "  its run after the grace: the game's own measure, never ended early");
        // the light scene: its probe as before (heat forbids timed probes here, so only the light rule can start one), and its run is never ended early
        FRESH(FCTL_GATE); NEXT(2, 1.5); P(1.5); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.15); for (int i = 0; i < 8; i++) NEXT(1, 1.15); NEXT(2, 1.5);
        for (int i = 0; i < 20; i++) NEXT(2, 1.5);
        nvn_fctl u = s; u.gate = 0; int la = 0, lb = 0;
        for (int i = 0; i < FCTL_LIGHT_N; i++) { nvn_fctl_next(&s, 2, 1, 3, -0.2, 0.3, 2, 0); la += s.ev == FCTL_EV_PROBE; nvn_fctl_next(&u, 2, 1, 3, -0.2, 0.3, 2, 0); lb += u.ev == FCTL_EV_PROBE; }
        check(la == 1 && lb == 1 && s.plight && s.lights == 1 && s.ev == FCTL_EV_PROBE && u.ev == FCTL_EV_PROBE, "light scene after a failure: a probe on the sixth light frame, as with the switch off");
        for (int i = 0; i < 7; i++) NEXT(2, 0.3); NEXT(1, 1.0); for (int i = 1; i < FSTEP_GRACE; i++) NEXT(1, 1.15);
        same = 1; for (int i = 0; i < 60; i++) same &= NEXT(1, 1.15) == 1.15;
        check(same && s.cuts == 1, "  its run after the grace: the game's own measure, never ended early");
        #undef NEXT
        #undef FRESH
        #undef P
    }
    // The two rules on the phone model: a scene that cannot hold 60 at any clock (as above) for 2 minutes, and a scene capped near 60 (19 ms frames at the full clock, the
    // controller's measure 1.15: it never steps up by its own rule). The gate keeps the probes after the first failure; the early end cuts a capped probe, so 60 with late
    // frames gives way to a steady 30. The clocks-follow-the-interval case the controller was written for (a scene that fits 60 at the full clock) is unchanged
    {
        long late_on = 0, late_off = 0; uint64_t pr_on = 0, pr_off = 0;
        for (int g = 0; g < 2; g++) {
            sim h = sim_new(1, 1.84); h.s.gate = g ? FCTL_GATE : 0; run_for(&h, 600, 0.82, 0.25); long l0 = 0; double r0 = h.real;
            while (h.real - r0 < 7200) { frame(&h, 1.3, 0.25); l0 += h.c.cur == 1 && h.m > 1 + FSTEP_LATE; }
            if (g) { late_on = l0; pr_on = h.s.probes; } else { late_off = l0; pr_off = h.s.probes; }
        }
        snprintf(b, sizeof b, "heavy scene, 2 min: probes %llu with the rules, %llu without; frames at 60 over 18.3 ms %ld with, %ld without", (unsigned long long)pr_on, (unsigned long long)pr_off, late_on, late_off);
        check(pr_on == 1 && pr_off >= 6 && late_on * 4 < late_off, b);
        long cl[2] = {0}; double t1[2] = {0}; uint64_t cuts = 0, gated = 0;
        for (int g = 0; g < 2; g++) {
            sim h = sim_new(1, 1.3); h.s.gate = g ? FCTL_GATE : 0; run_for(&h, 600, 0.82, 0.25); hitch(&h); double r0 = h.real, a0 = h.at1;
            while (h.real - r0 < 7200) { frame(&h, 0.9, 0.25); cl[g] += h.c.cur == 1 && h.m > 1 + FSTEP_LATE; }
            t1[g] = (h.at1 - a0) / (h.real - r0); if (g) { cuts = h.s.cuts; gated = h.s.gated; }
        }
        snprintf(b, sizeof b, "capped scene (1.15 at 60), 2 min: at 60 %.0f%% of the time with %ld late frames without the rules; with them %.0f%%, %ld late (%llu ended early, %llu waits held)",
                 100 * t1[0], cl[0], 100 * t1[1], cl[1], (unsigned long long)cuts, (unsigned long long)gated);
        check(t1[0] > 0.9 && cl[0] > 3000 && t1[1] < 0.05 && cl[1] * 50 < cl[0] && cuts == 1 && gated == 1, b);
        for (int u = 0; u < 2; u++) {
            sim a = sim_new(1, u ? 1.84 : 1.3), c = sim_new(1, u ? 1.84 : 1.3); c.s.gate = FCTL_GATE; int same = 1;
            run_for(&a, 600, 0.82, 0.25); run_for(&c, 600, 0.82, 0.25); hitch(&a); hitch(&c);
            for (int i = 0; i < 4000; i++) { same &= frame(&a, 0.82, 0.25) == frame(&c, 0.82, 0.25) && a.c.cur == c.c.cur; }
            snprintf(b, sizeof b, "clocks %.2fx slower at 30, a scene that fits 60: the same measure handed every frame with the rules as without (back at 60, held)", u ? 1.84 : 1.3);
            check(same && c.s.held == 1 && c.s.cuts == 0 && c.s.gated == 0 && c.c.cur == 1, b);
        }
    }
    printf("%d checks, %d failed\n", checks, fail);
    return fail != 0;
}
