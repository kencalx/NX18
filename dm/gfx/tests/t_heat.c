// The heat ladder's controller (nvn_heat.h; NX18-X2.0 heat-ladder.md §10's t_heat cases) and the frame step's "60 not holding" (nvn_fstep.h nvn_fstep_nothold, nvn_fstep_fit60).
// Samples are one a second on a test clock; the rungs a game can take are set per case (hle_nvn.c takes them from dm_heat_can: 85% and 70% where the render scale has a live
// lever). Also the render scale's setter state (nvn_scale) and the GPU time stretch of the reports (nvn_heat_stretch_ts), heat ladder step 4
#include "../nvn/nvn_fstep.h"
#include "../nvn/nvn_heat.h"
#include "../nvn/nvn_rescue.h"
#include <stdio.h>
#define RESCUE_SCALE_T ((double)RESCUE_SCALE)   // the clock rescue's factor as the setter takes it

static int fail, checks;
static void check(int ok, const char *what) { checks++; fail += !ok; printf("%-100s %s\n", what, ok ? "✓" : "✗"); }

typedef struct { nvn_heat h; nvn_heat_in in; int t; unsigned changes; } run_t;   // t: seconds; changes: rung and dim events so far
static void init(run_t *r, int steps, int r1, int r2, int re, int r3) {
    memset(r, 0, sizeof *r); nvn_heat_init(&r->h, steps, 1);
    r->h.can[HEAT_R1] = r1; r->h.can[HEAT_R2] = r2; r->h.can[HEAT_RE] = re; r->h.can[HEAT_R3] = r3;
    r->in.nothold = -1; r->in.ok40 = 1; r->t = 0;
}
// n samples at state th, one a second. A state counts from its first sample: R1 "after 10 s at state 1" goes on at the 11th sample at 1, as the heat hold's calm
// (the 30 s from its first calm sample) always did
static void at(run_t *r, int n, int th) {
    for (int i = 0; i < n; i++) {
        r->t++; r->in.now = (uint64_t)r->t * HEAT_S; r->in.th = th;
        nvn_heat_sample(&r->h, &r->in); r->in.away = 0;
        for (int e = 0; e < r->h.nev; e++) if (r->h.ev[e].rung != HEAT_NR + 3) r->changes++;
    }
}
static void stay(run_t *r, int s) { r->t += s; r->in.away = (uint64_t)s * HEAT_S; }   // s seconds away: nothing sampled, the next sample sees the stay
static int on(const run_t *r, int rung) { return nvn_heat_on(&r->h, rung); }
// A float multiply as the +0x14 stubs do it (fmul s8, s8, s0): through volatiles, so the compiler neither widens nor folds it
static float fmul_f(float a, float b) { volatile float x = a, y = b; volatile float r = x * y; return r; }
// One submission's reports as post_run writes them (nvn_mtl.m): the floor read once, each report stretched against it, and the latest time written the next one's floor
static void sub(const uint64_t *x, int n, uint64_t e, double k, uint64_t *floor, uint64_t *out) {
    const uint64_t lo = *floor; uint64_t hi = 0;
    for (int i = 0; i < n; i++) { out[i] = nvn_heat_stretch_ts(x[i], e, k, lo); if (out[i] > hi) hi = out[i]; }
    if (k > 0 && hi > *floor) *floor = hi;
}

int main(void) {
    char b[200];
    {   // debounce: R1 after 10 s at state 1, not before; dwell: it stays at least 60 s and comes back only after its wait at state 0
        run_t r; init(&r, 1, 1, 1, 0, 0);
        at(&r, 60, 0); at(&r, 10, 1);
        check(!on(&r, HEAT_R1), "debounce: 9 s at state 1 (10 samples), no rung");
        at(&r, 1, 1); check(on(&r, HEAT_R1) && nvn_heat_res(&r.h) == r.h.c.res1, "  10 s: resolution 85%");
        at(&r, 5, 1); at(&r, 50, 0);
        check(on(&r, HEAT_R1), "dwell: 50 s at state 0 within the minimum 60 s on and the 60 s wait: still on");
        at(&r, 10, 0); int kept = on(&r, HEAT_R1); at(&r, 1, 0); check(kept && !on(&r, HEAT_R1) && nvn_heat_res(&r.h) == 1.0, "  60 s after the first sample at state 0: back");
        at(&r, 20, 1); at(&r, 30, 0); at(&r, 2, 1); at(&r, 2, 0);
        check(on(&r, HEAT_R1), "  a hot sample restarts the calm");
    }
    {   // last in, first out: R1, then R2 (GPU-bound evidence), then RE, then R3 at state 1, each on 30 s of evidence gathered at the rung before it (it starts again at
        // each change: 31 s apart); they come back R3, RE, R2, R1, one wait apart
        run_t r; init(&r, 1, 1, 1, 1, 1);
        r.in.nothold = 0.20; r.in.gpu_bound = 1;
        at(&r, 11, 1); int r1 = on(&r, HEAT_R1) && r.h.depth == 1;
        at(&r, 30, 1); int gap = r.h.depth == 1;
        at(&r, 1, 1); int r2 = on(&r, HEAT_R2) && r.h.depth == 2;
        at(&r, 31, 1); int re = on(&r, HEAT_RE); at(&r, 31, 1); int r3 = on(&r, HEAT_R3) && nvn_heat_cap(&r.h) == 40;
        snprintf(b, sizeof b, "down at state 1: 85%% at 10 s, 70%% / effects / 40 fps each 30 s of evidence after the last (at %llu, %llu, %llu, %llu s)",
                 (unsigned long long)(r.h.on_at[HEAT_R1] / HEAT_S), (unsigned long long)(r.h.on_at[HEAT_R2] / HEAT_S), (unsigned long long)(r.h.on_at[HEAT_RE] / HEAT_S), (unsigned long long)(r.h.on_at[HEAT_R3] / HEAT_S));
        check(r1 && gap && r2 && re && r3 && r.h.depth == 4 && nvn_heat_res(&r.h) == r.h.c.res2 && nvn_heat_fx_off(&r.h) && r.h.on_at[HEAT_R3] == 104 * HEAT_S, b);
        r.in.nothold = 0; int order[4] = {-1, -1, -1, -1}, n = 0, last = r.h.depth;
        for (int i = 0; i < 1000 && r.h.depth; i++) { at(&r, 1, 0); if (r.h.depth < last) { order[n++] = r.h.nev ? r.h.ev[0].rung : -1; last = r.h.depth; } }
        snprintf(b, sizeof b, "  up at state 0: one at a time, last in first out (%d %d %d %d)", order[0], order[1], order[2], order[3]);
        check(n == 4 && order[0] == HEAT_R3 && order[1] == HEAT_RE && order[2] == HEAT_R2 && order[3] == HEAT_R1, b);
    }
    {   // the restore steps are a wait apart: R2 back 60 s after the calm began, R1 60 s after that
        run_t r; init(&r, 1, 1, 1, 0, 0); r.in.nothold = 0.2; r.in.gpu_bound = 1;
        at(&r, 100, 1); r.in.nothold = 0; int both = r.h.depth == 2;
        at(&r, 60, 0); int still = r.h.depth == 2; at(&r, 1, 0); int one = r.h.depth == 1 && on(&r, HEAT_R1);
        at(&r, 59, 0); int still1 = r.h.depth == 1; at(&r, 1, 0);
        check(both && still && one && still1 && r.h.depth == 0, "  each restore waits its own wait after the last one");
    }
    {   // a game with no frame-step page (nothing known about 60) and one at Frame rate off: dim still comes (the front end dims, step 3); no rung that needs evidence
        for (int v = 0; v < 2; v++) {
            run_t r; init(&r, 1, 0, 0, 0, 0); r.h.dim_ok = 1; r.in.nothold = -1;
            at(&r, 20, 1); int d1 = nvn_heat_dim(&r.h) == 1 && r.h.depth == 0;
            at(&r, 1, 2); int d2 = nvn_heat_dim(&r.h) == 2;
            at(&r, 30, 1); int keep2 = nvn_heat_dim(&r.h) == 2; at(&r, 1, 1); int back1 = nvn_heat_dim(&r.h) == 1;
            at(&r, 61, 0);
            snprintf(b, sizeof b, "%s: Dim 1 at state 1, Dim 2 at state 2, Dim 1 after 30 s at state <= 1, off after 60 s at 0", v ? "  Frame rate off" : "no frame-step page");
            check(d1 && d2 && keep2 && back1 && nvn_heat_dim(&r.h) == 0, b);
        }
        run_t c; init(&c, 1, 0, 0, 0, 0); c.h.dim_ok = 1; c.in.charging = 1;
        at(&c, 30, 1); int no1 = nvn_heat_dim(&c.h) == 0; at(&c, 1, 2);
        check(no1 && nvn_heat_dim(&c.h) == 2, "  charging: no Dim 1 (D8), Dim 2 still");
        run_t o; init(&o, 1, 0, 0, 0, 0); o.h.dim_ok = 0; at(&o, 30, 2);
        check(nvn_heat_dim(&o.h) == 0, "  a front end that cannot dim: no dim level");
    }
    {   // Ocarina of Time (R1 and R2 skipped: no resolution lever; 40 checked): holding 60 at state 1 only dims; 60 not holding for 30 s goes to 40
        run_t r; init(&r, 1, 0, 0, 0, 1); r.h.dim_ok = 1; r.in.nothold = 0.03;
        at(&r, 300, 1);
        check(r.h.depth == 0 && nvn_heat_dim(&r.h) == 1 && !nvn_heat_cap(&r.h), "OoT holding 60 at state 1: dim only, no 40 fps (D2)");
        r.in.nothold = 0.14; r.in.gpu_bound = 1; at(&r, 30, 1); int not_yet = !on(&r, HEAT_R3); at(&r, 1, 1);
        check(not_yet && on(&r, HEAT_R3) && nvn_heat_cap(&r.h) == 40, "  14% not holding for 30 s: 40 fps (R2 skipped)");
    }
    {   // "60 not holding" from the frame step: steady 22 ms frames with Hold frames on step to hold 2 and are on time there; nvn_fstep_nothold calls them not holding,
        // a late-frame share would not. A probe's grace and a stay are not counted; frames at 0.5 vsyncs hold
        nvn_fstep s = {0}; nvn_heat_win w = {0}; int late_share = 0, n2 = 0;
        for (int i = 0; i < 120; i++) { int v = nvn_fstep_nothold(&s, 1, 1, 0.5, 0.3, 0); nvn_heat_win_add(&w, v, 1); nvn_fstep_next(&s, 1, 0.5, 1, 3, 0, 0); }
        for (int i = 0; i < 1800; i++) {
            int k = s.k; double shown = 1.32 > k ? 1.32 : k;
            int v = nvn_fstep_nothold(&s, 1, shown, 1.32, 1.3, 0); nvn_heat_win_add(&w, v, shown); if (i % 60 == 59) nvn_heat_win_close(&w);
            late_share += shown > k + FSTEP_LATE; n2 += k == 2;
            nvn_fstep_next(&s, shown, 1.32, 1, 3, 0, 0);
        }
        int gb; double sh = nvn_heat_win_share(&w, &gb);
        snprintf(b, sizeof b, "a held 30 with Hold frames on: not holding %.0f%% of the window, GPU-bound %d (late frames %d of 1800)", 100 * sh, gb, late_share);
        check(n2 > 1700 && late_share < 20 && sh > 0.95 && gb, b);
        nvn_fstep g = s; g.grace = 5; check(nvn_fstep_nothold(&g, 1, 2, 1.32, 1.3, 0) == -1 && nvn_fstep_nothold(&s, 1, 2, 1.32, 1.3, 1) == -1, "  a probe's grace and the frame across a stay are not counted");
        nvn_fstep c = {0}; nvn_fstep_next(&c, 1, 0.5, 1, 3, 0, 0);
        check(nvn_fstep_nothold(&c, 1, 1.3, 1.3, 0.6, 0) == 2 && nvn_fstep_nothold(&c, 1, 1.3, 1.3, 1.3, 0) == 1 && nvn_fstep_nothold(&c, 1, 1.0, 0.5, 0.4, 0) == 0,
              "  a late frame at hold 1: CPU-bound when the GPU fits, GPU-bound when it does not; on time holds");
        check(!nvn_fstep_fit60(&s, 1), "  60 would not fit at 1.32 vsyncs");
        nvn_fstep f = {0}; for (int i = 0; i < 600; i++) nvn_fstep_next(&f, 2, 0.6, 2, 2, 0, 0);
        check(nvn_fstep_fit60(&f, 1), "  a 30 cap whose frames cost 0.6: 60 would fit again");
        // the game's own step (BotW's VFR override, fixed 2 at a 60 cap): the game chose 30, so its frames are not "60 not holding" (resolution or effects do not change
        // it), and the frame step measures nothing to say 60 would fit; the frame that ends the step is left out too, and the next is judged again
        nvn_fstep v = {0}; nvn_heat_win vw = {0}; int counted = 0;
        for (int i = 0; i < 120; i++) nvn_fstep_next(&v, 1, 0.5, 1, 3, 0, 0);
        for (int i = 0; i < 1800; i++) {   // the first verdict is the frame before the step (hold 1, on time)
            int vd = nvn_fstep_nothold(&v, 1, v.k, 0.6, 0.5, 0); counted += vd > 0; nvn_heat_win_add(&vw, vd, v.k); if (i % 30 == 29) nvn_heat_win_close(&vw); nvn_fstep_next(&v, v.k, 0.6, 1, 3, 2, 0);
        }
        double vs = nvn_heat_win_share(&vw, NULL); int vfit = nvn_fstep_fit60(&v, 1);
        int last = nvn_fstep_nothold(&v, 1, 2, 0.6, 0.5, 0); nvn_fstep_next(&v, 2, 0.6, 1, 3, 0, 0); int again = nvn_fstep_nothold(&v, 1, 1.0, 0.5, 0.4, 0);
        snprintf(b, sizeof b, "  the game's own step of 2 at a 60 cap (BotW's VFR override): %d of 1800 frames not holding, share %.2f, 60 fits %d", counted, vs, vfit);
        check(counted == 0 && vs < 0 && !vfit && last == -1 && again == 0, b);
    }
    {   // CPU-bound late frames skip 70% and effects (GPU work: neither would help, §3.1, §7.2) to 40 one gap after 85%; GPU-bound ones take 70%, then effects
        run_t c; init(&c, 1, 1, 1, 1, 1); c.in.nothold = 0.2; c.in.gpu_bound = 0; at(&c, 120, 1);
        run_t g; init(&g, 1, 1, 1, 1, 1); g.in.nothold = 0.2; g.in.gpu_bound = 1; at(&g, 80, 1);
        snprintf(b, sizeof b, "CPU-bound: 85%% then 40 fps at %llu s, no 70%% or effects; GPU-bound: 85%%, 70%%, then effects (depth %d / %d)",
                 (unsigned long long)(c.h.on_at[HEAT_R3] / HEAT_S), c.h.depth, g.h.depth);
        check(on(&c, HEAT_R1) && !on(&c, HEAT_R2) && !on(&c, HEAT_RE) && on(&c, HEAT_R3) && c.h.on_at[HEAT_R3] == 42 * HEAT_S && c.h.depth == 2
              && on(&g, HEAT_R2) && on(&g, HEAT_RE) && !on(&g, HEAT_R3) && g.h.on_at[HEAT_RE] == g.h.on_at[HEAT_R2] + 31 * HEAT_S, b);
    }
    {   // evidence gathered at state 0 (MKW's crowded stretches, 15-30 s at state 0) does not count: at the first sample at state 1 nothing, 85% at 10 s, and 70% or 40
        // only after 30 s of evidence at state 1 and at 85% (before, 40 s of late frames at state 0 put 40 or 70% on at the first state-1 sample, and 85% never after)
        for (int gpu = 0; gpu < 2; gpu++) {
            run_t r; init(&r, 1, 1, 1, 0, 1); r.in.nothold = 0.2; r.in.gpu_bound = gpu;
            at(&r, 40, 0); at(&r, 1, 1); int none = r.h.depth == 0;
            at(&r, 60, 1); int next = gpu ? HEAT_R2 : HEAT_R3;
            snprintf(b, sizeof b, "%s late frames for 40 s at state 0, then state 1: nothing at once, 85%% at %llu s, %s at %llu s", gpu ? "  GPU-bound" : "CPU-bound",
                     (unsigned long long)(r.h.on_at[HEAT_R1] / HEAT_S), gpu ? "70%" : "40 fps", (unsigned long long)(r.h.on_at[next] / HEAT_S));
            check(none && r.h.stack[0] == HEAT_R1 && r.h.on_at[HEAT_R1] == 51 * HEAT_S && on(&r, next) && r.h.on_at[next] == 82 * HEAT_S && r.h.depth == 2, b);
        }
        // a game without 85% (Ocarina of Time's class: R1 skipped) has no rung whose push starts the evidence again, so only gathering it at state 1 keeps the state-0 late
        // frames out: 40 (CPU-bound) or 70% (GPU-bound) 30 s after the first state-1 sample, not at it
        for (int gpu = 0; gpu < 2; gpu++) {
            run_t r; init(&r, 1, 0, gpu, 0, !gpu); r.in.nothold = 0.2; r.in.gpu_bound = gpu; int next = gpu ? HEAT_R2 : HEAT_R3;
            at(&r, 40, 0); at(&r, 30, 1); int none = r.h.depth == 0; at(&r, 1, 1);
            snprintf(b, sizeof b, "  no 85%% (OoT's class), %s late frames for 40 s at state 0: nothing for 30 s at state 1, %s at %llu s", gpu ? "GPU-bound" : "CPU-bound",
                     gpu ? "70%" : "40 fps", (unsigned long long)(r.h.on_at[next] / HEAT_S));
            check(none && on(&r, next) && r.h.on_at[next] == 71 * HEAT_S && r.h.depth == 1, b);
        }
        // and 85% first where the game can take it: with r1 longer than evid (DM_HEAT_TUNE r1=40), 30 s of evidence at state 1 come before 85% is due, and 40 waits for it
        run_t g; init(&g, 1, 1, 0, 0, 1); g.h.c.r1_on = 40 * HEAT_S; g.in.nothold = 0.2; at(&g, 40, 1); int none = g.h.depth == 0; at(&g, 40, 1);
        snprintf(b, sizeof b, "  r1=40, late frames from the first state-1 sample: 85%% at %llu s, then 40 fps at %llu s (none before 85%%)", (unsigned long long)(g.h.on_at[HEAT_R1] / HEAT_S),
                 (unsigned long long)(g.h.on_at[HEAT_R3] / HEAT_S));
        check(none && g.h.depth == 2 && g.h.stack[0] == HEAT_R1 && g.h.on_at[HEAT_R1] == 41 * HEAT_S && g.h.on_at[HEAT_R3] == 72 * HEAT_S, b);
    }
    {   // the evidence exit: at state 1, 2 min in 70% and 60 fitting again for 30 s brings it back; 85% stays at state 1 (D20)
        run_t r; init(&r, 1, 1, 1, 0, 0); r.in.nothold = 0.2; r.in.gpu_bound = 1; at(&r, 45, 1);
        int in2 = on(&r, HEAT_R2); r.in.nothold = 0.02; r.in.fit60 = 1;
        at(&r, 100, 1); int still = on(&r, HEAT_R2); at(&r, 30, 1);
        snprintf(b, sizeof b, "evidence exit: 70%% back at state 1 after 2 min with 60 fitting (depth %d)", r.h.depth);
        check(in2 && still && !on(&r, HEAT_R2) && on(&r, HEAT_R1), b);
        at(&r, 600, 1); check(on(&r, HEAT_R1), "  85% stays while the state is 1");
    }
    {   // Mario Kart World, run 2 (x2-round-all-on.md): state 0 to 174 s, then 1; 60 held (3% dropped). Only 85% (and dim), nothing past it. Run 4: state 1 at 153 s
        // and crowded stretches at 48-52 fps (about 15% late, GPU 14-17 ms, GPU-bound) for 30 s or more: 70% then
        run_t r; init(&r, 1, 1, 1, 0, 0); r.h.dim_ok = 1; r.in.nothold = 0.03;
        at(&r, 174, 0); at(&r, 600, 1);
        snprintf(b, sizeof b, "MKW run 2's timeline: state 1 read at 175 s, 85%% from 185 s, nothing more (depth %d, dim %d, cap %d)", r.h.depth, nvn_heat_dim(&r.h), nvn_heat_cap(&r.h));
        check(r.h.depth == 1 && on(&r, HEAT_R1) && r.h.on_at[HEAT_R1] == 185 * HEAT_S && nvn_heat_dim(&r.h) == 1 && !nvn_heat_cap(&r.h), b);
        run_t q; init(&q, 1, 1, 1, 0, 0); q.in.nothold = 0.03; at(&q, 153, 0); at(&q, 60, 1); q.in.nothold = 0.15; q.in.gpu_bound = 1; at(&q, 30, 1);
        int not_yet = !on(&q, HEAT_R2); at(&q, 1, 1);
        check(not_yet && on(&q, HEAT_R2), "  run 4's crowded stretch (15% late, GPU-bound) for 30 s at state 1: 70%");
    }
    {   // flapping: a 90 s / 90 s square wave between states 1 and 0 for 30 min: the doubling wait keeps 85% on after its first return; at most 4 changes in any 10 min.
        // A short flap (15 s at 1, 5 s at 0) never brings it back
        run_t r; init(&r, 1, 1, 0, 0, 0); unsigned c10[3] = {0};
        for (int p = 0; p < 10; p++) { unsigned c0 = r.changes; at(&r, 90, 1); at(&r, 90, 0); c10[(r.t - 1) / 600] += r.changes - c0; }
        snprintf(b, sizeof b, "1/0 square wave (90 s each) for 30 min: changes per 10 min %u, %u, %u; flaps %u", c10[0], c10[1], c10[2], r.h.flaps);
        check(c10[0] <= 4 && c10[1] <= 4 && c10[2] <= 4 && on(&r, HEAT_R1), b);
        run_t s; init(&s, 1, 1, 0, 0, 0); for (int p = 0; p < 60; p++) { at(&s, 15, 1); at(&s, 5, 0); }
        check(s.changes == 1 && on(&s, HEAT_R1), "  a 15 s / 5 s flap: 85% once, never back");
        // the 30 fps hold under OoT's 55-minute run's shape: state 2 for 60 s, then 1 for 51-391 s, eight times: its waits double 30 → 240 s, so fewer switches
        run_t o; init(&o, 1, 0, 0, 0, 0); static const int calm[8] = {51, 391, 120, 200, 90, 300, 60, 150}; unsigned h4 = 0;
        for (int p = 0; p < 8; p++) { at(&o, 60, 2); at(&o, calm[p], 1); }
        for (int e = 0; e < HEAT_NR; e++) h4 += o.h.entries[e];
        snprintf(b, sizeof b, "  OoT's field run (state 2 again 51-391 s after each calm): the 30 fps hold's waits doubled to %llu s, re-entries %u",
                 (unsigned long long)(o.h.wait[HEAT_R4] / HEAT_S), h4);
        check(o.h.wait[HEAT_R4] == o.h.c.r4_wait_max && h4 >= 3, b);
    }
    {   // a warm start straight to state 2: 85%, 70% and effects in one change, then 30 fps after 15 s (D15 (a): no 40); at once at state 3, and at once when frames are late at 70%
        run_t r; init(&r, 1, 1, 1, 1, 0); at(&r, 1, 2);
        int one = r.h.depth == 3 && r.changes == 3 && nvn_heat_res(&r.h) == r.h.c.res2;
        at(&r, 14, 2); int wait = !nvn_heat_cap(&r.h); at(&r, 1, 2);
        snprintf(b, sizeof b, "warm start at state 2: 85%%, 70%%, effects in one change, 30 fps 15 s later (depth %d, cap %d)", r.h.depth, nvn_heat_cap(&r.h));
        check(one && wait && nvn_heat_cap(&r.h) == 30 && (r.h.capped & HEAT_CAP_HEAT), b);
        run_t c; init(&c, 1, 1, 1, 0, 0); at(&c, 1, 3); check(nvn_heat_cap(&c.h) == 30, "  state 3: 30 fps at once");
        // frames late at 70%: judged on frames drawn at 70%. The sample that puts 70% on had none (its late frames were at 100%), and the caller's window starts again at
        // each rung (-1: under 10 s of frames); once 10 s at 70% are late, 30 before the 15 s wait ends. Here the shares are set by hand; t_thermal's T_THERMAL_LADDER
        // cases run the caller's window and its resets (hle_nvn.c heat_sample, nvn_heat_frame)
        run_t l; init(&l, 1, 1, 1, 0, 0); l.in.nothold = 0.3; at(&l, 1, 2); int no30 = on(&l, HEAT_R2) && !nvn_heat_cap(&l.h);
        l.in.nothold = -1; at(&l, 9, 2); int not_yet = !nvn_heat_cap(&l.h); l.in.nothold = 0.3; at(&l, 1, 2);
        check(no30 && not_yet && nvn_heat_cap(&l.h) == 30, "  frames late at 70%: 70% first, 30 once 10 s of frames at 70% are late (11 s, inside the 15 s)");
        run_t q; init(&q, 1, 1, 1, 0, 0); q.in.nothold = 0.3; at(&q, 10, 2); int stale = !nvn_heat_cap(&q.h); q.in.nothold = 0; at(&q, 5, 2); int wait15 = !nvn_heat_cap(&q.h); at(&q, 1, 2);
        check(stale && wait15 && nvn_heat_cap(&q.h) == 30, "  late frames read in 70%'s first 10 s do not skip the 15 s (HEAT_LATE_ON; the caller's reset covers the rest of its window)");
        run_t d; init(&d, 1, 0, 0, 0, 1); d.in.nothold = 0.2; at(&d, 31, 1); int at40 = nvn_heat_cap(&d.h) == 40;
        at(&d, 5, 2); int stale40 = nvn_heat_cap(&d.h) == 40; d.in.nothold = 0; at(&d, 25, 2); int held40 = nvn_heat_cap(&d.h) == 40; at(&d, 1, 2);
        check(at40 && stale40 && held40 && nvn_heat_cap(&d.h) == 30, "  40 on at state 1 on evidence, state 2 within 10 s, 40 holding: 30 only after the 30 s (D1)");
        run_t o; init(&o, 1, 1, 0, 1, 0); at(&o, 1, 2);
        check(on(&o, HEAT_R1) && on(&o, HEAT_RE) && nvn_heat_cap(&o.h) == 30, "  85% and effects alone: 30 at once, as today (it waits only behind 70% or 40, §8.5)");
        run_t n; init(&n, 1, 0, 0, 0, 0); at(&n, 1, 2); check(nvn_heat_cap(&n.h) == 30 && n.h.depth == 1, "  no lower rung (today's games in this build): 30 fps at once, as before");
        run_t f; init(&f, 1, 0, 0, 0, 1); at(&f, 1, 2); int forty = nvn_heat_cap(&f.h) == 40; at(&f, 29, 2); int still = nvn_heat_cap(&f.h) == 40; at(&f, 1, 2);
        check(forty && still && nvn_heat_cap(&f.h) == 30, "  40 fps checked (D1 (b)): 40 at once, 30 after 30 s at state 2");
        // frames late at the rung R4 waits behind are timed from that rung, not from the 70% or effects the state-2 jump pushes over it in the same sample: CPU-bound frames
        // late at 40 since state 1 (D1: 30 at once when 40 is not holding at state 2), and GPU-bound ones late at 70% (D15 (a)) when state 2 adds effects. Before, each push
        // restarted the 10 s and 30 came 10 s later
        for (int gpu = 0; gpu < 2; gpu++) {
            run_t s; init(&s, 1, 1, 1, 1, !gpu); s.in.nothold = 0.2; s.in.gpu_bound = gpu; at(&s, 60, 1);
            int below = gpu ? HEAT_R2 : HEAT_R3, was = on(&s, below) && !on(&s, HEAT_RE); at(&s, 1, 2);
            snprintf(b, sizeof b, "  %s late at %s since %llu s, state 2 at 61 s pushing %s: 30 at %llu s", gpu ? "GPU-bound" : "CPU-bound", gpu ? "70%" : "40",
                     (unsigned long long)(s.h.on_at[below] / HEAT_S), gpu ? "effects" : "70% and effects", (unsigned long long)(s.h.capped ? s.h.on_at[HEAT_R4] / HEAT_S : 0));
            check(was && on(&s, HEAT_RE) && (gpu || s.h.on_at[HEAT_R2] == 61 * HEAT_S) && nvn_heat_cap(&s.h) == 30 && s.h.on_at[HEAT_R4] == 61 * HEAT_S, b);
        }
    }
    {   // each event carries the rungs on right after it (the [heat] rung A → B lines, in order): a warm start to state 2 puts 85%, 70% and effects on in one sample
        run_t w; init(&w, 1, 1, 1, 1, 0); at(&w, 1, 2);
        int warm = w.h.nev == 3 && w.h.ev[0].depth == 1 && w.h.ev[1].depth == 2 && w.h.ev[2].depth == 3 && w.h.ev[0].res == w.h.c.res1 && w.h.ev[1].res == w.h.c.res2;
        run_t s; init(&s, 1, 1, 1, 0, 0); s.in.nothold = 0.2; s.in.gpu_bound = 1; at(&s, 50, 1); s.in.nothold = 0; at(&s, 5, 0); stay(&s, 300); at(&s, 1, 0);
        int away = s.h.nev == 2 && s.h.ev[0].rung == HEAT_R2 && s.h.ev[0].depth == 1 && s.h.ev[1].rung == HEAT_R1 && s.h.ev[1].depth == 0;
        run_t f; init(&f, 1, 1, 1, 0, 1); at(&f, 20, 2); f.in.ok40 = 0; at(&f, 1, 2);
        int lost = f.h.nev == 2 && f.h.ev[0].rung == HEAT_R3 && !f.h.ev[0].on && f.h.ev[0].depth == 2 && f.h.ev[1].rung == HEAT_R4 && f.h.ev[1].on && f.h.ev[1].depth == 3 && f.h.ev[1].cap == 30;
        check(warm && away && lost, "rung events in order: a warm start 1, 2, 3; a long stay ending two 1, 0; 40 losing its screen as 30 comes 2, then 3");
    }
    {   // a 40 that loses its screen (Low Power Mode, a TV): it ends at once, below state 2 no 30 for it, and its wait is not doubled by that end
        run_t r; init(&r, 1, 0, 0, 0, 1); r.in.nothold = 0.2; at(&r, 40, 1);
        int forty = nvn_heat_cap(&r.h) == 40; r.in.ok40 = 0; at(&r, 1, 1);
        check(forty && !nvn_heat_cap(&r.h) && r.h.off_at[HEAT_R3] == 0 && !r.h.capped, "a 40 that loses its screen at state 1: back to 60, no 30");
    }
    {   // return after a long stay: at state 0 after 5 min away every rung comes back in one change; after 100 s the calm goes on from where it was
        run_t r; init(&r, 1, 1, 1, 0, 0); r.in.nothold = 0.2; r.in.gpu_bound = 1; at(&r, 50, 1); r.in.nothold = 0;
        int two = r.h.depth == 2; at(&r, 5, 0); stay(&r, 300); at(&r, 1, 0);
        check(two && r.h.depth == 0, "return after 5 min away at state 0: all rungs back at once");
        run_t t; init(&t, 1, 1, 0, 0, 0); at(&t, 80, 1); at(&t, 30, 0); stay(&t, 100); at(&t, 30, 0); int kept = on(&t, HEAT_R1); at(&t, 1, 0);
        check(kept && !on(&t, HEAT_R1), "  a 100 s stay during a 60 s calm: the calm paused there, 30 + 30 s outside it");
        // the next rung's wait counts from the last restore, paused away too: R2 back at 111 s, 10 s more, a 100 s stay; R1's 60 s from R2's restore need 50 s more on return
        run_t u; init(&u, 1, 1, 1, 0, 0); u.in.nothold = 0.2; u.in.gpu_bound = 1; at(&u, 50, 1); u.in.nothold = 0;
        int both = u.h.depth == 2; for (int i = 0; i < 200 && u.h.depth == 2; i++) at(&u, 1, 0);
        int r2back = u.t == 111 && on(&u, HEAT_R1); at(&u, 10, 0); stay(&u, 100); at(&u, 49, 0); int kept1 = on(&u, HEAT_R1); at(&u, 1, 0);
        check(both && r2back && kept1 && !on(&u, HEAT_R1), "  R2 back, 10 s, a 100 s stay: R1 back 60 s of foreground after R2's restore (49 s after return kept, 50 back)");
    }
    {   // the restore wait doubles for a rung back within 10 min (60 → 120 → 240 → 300) and is 60 s again after 10 min without it
        run_t r; init(&r, 1, 1, 0, 0, 0); uint64_t w[5]; int n = 0;
        for (int p = 0; p < 5; p++) { at(&r, 70, 1); w[n++] = r.h.wait[HEAT_R1] / HEAT_S; for (int i = 0; i < 400 && on(&r, HEAT_R1); i++) at(&r, 1, 0); }
        at(&r, 700, 0); at(&r, 70, 1);
        snprintf(b, sizeof b, "restore waits %llu, %llu, %llu, %llu, %llu s; after 10 min calm %llu s", (unsigned long long)w[0], (unsigned long long)w[1], (unsigned long long)w[2],
                 (unsigned long long)w[3], (unsigned long long)w[4], (unsigned long long)(r.h.wait[HEAT_R1] / HEAT_S));
        check(w[0] == 60 && w[1] == 120 && w[2] == 240 && w[3] == 300 && w[4] == 300 && r.h.wait[HEAT_R1] == 60 * HEAT_S, b);
    }
    {   // DM_HEAT_STEPS=0: today's behaviour, the 30 fps hold at state 2 at once and nothing at state 1, whatever the game can take; its calm wait doubles 30 → 60 within 10 min
        run_t r; init(&r, 0, 1, 1, 1, 1); r.h.dim_ok = 1; r.in.nothold = 0.5;
        at(&r, 120, 1); int none = r.h.depth == 0 && !nvn_heat_dim(&r.h);
        at(&r, 1, 2); int hold = nvn_heat_cap(&r.h) == 30 && r.h.depth == 1;
        at(&r, 30, 1); int kept = nvn_heat_cap(&r.h) == 30; at(&r, 1, 1); int back = !nvn_heat_cap(&r.h);
        at(&r, 10, 2); at(&r, 60, 1); int kept2 = nvn_heat_cap(&r.h) == 30; at(&r, 1, 1);
        check(none && hold && kept && back && kept2 && !nvn_heat_cap(&r.h), "DM_HEAT_STEPS=0: only the hold, at once at state 2, its calm 30 s then 60 s");
    }
    {   // Low Power Mode: 30 at once, its own 30 s calm, apart from the ladder; its setting off ends it at once
        run_t r; init(&r, 1, 1, 0, 0, 0); r.in.lp = r.in.lp_set = 1; at(&r, 1, 0);
        int on30 = nvn_heat_cap(&r.h) == 30 && r.h.depth == 0; r.in.lp = 0; at(&r, 30, 0); int kept = nvn_heat_cap(&r.h) == 30; at(&r, 1, 0);
        int off = !nvn_heat_cap(&r.h); r.in.lp = 1; at(&r, 1, 0); r.in.lp = 0; r.in.lp_set = 0; at(&r, 1, 0);
        check(on30 && kept && off && !nvn_heat_cap(&r.h), "Low Power Mode: 30 at once, back 30 s after it ends, at once when its setting goes off");
    }
    {   // the render scale for the resolution rungs (step 4): the player's, the heat factor and the clock rescue's multiply, floored at 0.5 (D7)
        check(nvn_heat_scale(1.0, 0.85, 1.0) == 0.85 && nvn_heat_scale(0.75, 0.85, 1.0) > 0.637 && nvn_heat_scale(0.75, 0.85, 1.0) < 0.638 && nvn_heat_scale(0.75, 0.70, 0.75) == 0.5,
              "render scale: Battery Saver's 0.75 x 85% = 0.64; with 70% and the clock rescue's 0.75 under it, the 0.5 floor");
    }
    {   // the resolution rungs a player's Render scale leaves something to lower (nvn_heat_can_res; hle_nvn.c heat_sample for the +0x14 stubs), each scale as the loader writes
        // it (a float): 0.5 none, 0.55 and 0.60 85% alone (70% would give 0.50 under 0.50 or 0.51), from 0.65 both. A rung that is not offered is passed over, so at state 2
        // the 30 fps hold comes at once where 70% is not offered (it waits 15 s only behind 70%, D15)
        static const struct { float p; int r1, r2; } G[] = {{0.50f, 0, 0}, {0.55f, 1, 0}, {0.60f, 1, 0}, {0.65f, 1, 1}, {0.70f, 1, 1}, {0.75f, 1, 1}, {0.85f, 1, 1}, {1.0f, 1, 1}};
        int ok = 1; char got[96] = "";
        for (unsigned i = 0; i < sizeof G / sizeof *G; i++) {
            int can[HEAT_NR] = {1, 1, 0, 0, 1}; nvn_heat_can_res(can, (double)G[i].p, 0.85, 0.70);
            ok &= can[HEAT_R1] == G[i].r1 && can[HEAT_R2] == G[i].r2 && can[HEAT_R4] == 1;
            snprintf(got + strlen(got), sizeof got - strlen(got), " %.2f:%d%d", G[i].p, can[HEAT_R1], can[HEAT_R2]);
        }
        int none[HEAT_NR] = {0, 0, 0, 0, 1}; nvn_heat_can_res(none, 1.0, 0.85, 0.70); ok &= !none[HEAT_R1] && !none[HEAT_R2];
        snprintf(b, sizeof b, "resolution rungs by Render scale (85%% 70%%):%s; a rung the lever lacks stays off", got);
        check(ok, b);
        // at state 2: Render scale 0.5, R4 in the first sample; 0.55, 85% and R4 at once; 0.75, 85% and 70%, then R4 15 s later
        int first[3]; const float ps[3] = {0.50f, 0.55f, 0.75f};
        for (int i = 0; i < 3; i++) {
            run_t r; init(&r, 1, 1, 1, 0, 0); nvn_heat_can_res(r.h.can, (double)ps[i], r.h.c.res1, r.h.c.res2); r.in.nothold = 0;
            at(&r, 30, 0); first[i] = 0; for (int t = 1; t <= 20 && !on(&r, HEAT_R4); t++) { at(&r, 1, 2); first[i] = t; }
            if (i == 1) ok = on(&r, HEAT_R1) && !on(&r, HEAT_R2);
        }
        snprintf(b, sizeof b, "  at state 2: Render scale 0.5 holds 30 in sample %d, 0.55 in sample %d (85%% alone on), 0.75 in sample %d (behind 70%%)", first[0], first[1], first[2]);
        check(first[0] == 1 && first[1] == 1 && ok && first[2] == 16, b);
    }
    {   // the live setter's state (nvn_scale; hle_nvn.c scale_set): each owner sets its own factor, the composed scale is player x heat x rescue at least 0.5, and what reaches
        // the game (the +0x14 stubs' factor, a pre-LIVE_SCALE stub's +0x10, the stretch) follows it; the rescue's end leaves a heat rung that came meanwhile in force
        nvn_scale s; nvn_scale_init(&s, 1.0);
        int c1 = nvn_scale_set(&s, NVN_SCALE_HEAT, 0.85), c0 = nvn_scale_set(&s, NVN_SCALE_HEAT, 0.85);
        check(c1 && !c0 && nvn_scale_now(&s) == 0.85 && nvn_scale_live(&s) == 0.85f, "setter: 85% at Render scale 1.0 is 0.85, the +0x14 factor 0.85; the same factor again is no change");
        nvn_scale_set(&s, NVN_SCALE_RESCUE, RESCUE_SCALE_T);
        double both = nvn_scale_now(&s); nvn_scale_set(&s, NVN_SCALE_HEAT, 0.70); double during = nvn_scale_now(&s);
        nvn_scale_set(&s, NVN_SCALE_RESCUE, 1.0);
        check(both > 0.637 && both < 0.638 && fabs(during - 0.525) < 1e-12 && nvn_scale_now(&s) == 0.70,
              "  heat 85% x rescue 0.75 = 0.64; 70% during the rescue 0.525; the rescue's end leaves 70% (not the 85% it started on)");
        nvn_scale_set(&s, NVN_SCALE_RESCUE, RESCUE_SCALE_T);
        check(fabs(nvn_scale_now(&s) - 0.525) < 1e-12 && nvn_scale_set(&s, NVN_SCALE_HEAT, 0.5) && nvn_scale_now(&s) == 0.5, "  70% x 0.75 = 0.525; 0.5 x 0.75 held at the 0.5 floor");
        nvn_scale p; nvn_scale_init(&p, 0.75); nvn_scale_set(&p, NVN_SCALE_HEAT, 0.85);
        float lf = nvn_scale_live(&p);
        check(lf >= 0.85f && lf < 0.8501f && (double)fmul_f(0.75f, lf) >= nvn_scale_now(&p) - 3e-8, "  Battery Saver 0.75: the +0x14 factor is 0.85 (the stubs multiply it under the player's 0.75)");
        nvn_scale_set(&p, NVN_SCALE_HEAT, 0.70); nvn_scale_set(&p, NVN_SCALE_RESCUE, RESCUE_SCALE_T); lf = nvn_scale_live(&p);
        snprintf(b, sizeof b, "  0.75 x 70%% x 0.75 floors at 0.5: the +0x14 factor %.4f, the player's x it in float (the stubs' fmul) at least 0.5 (%.8f)", lf, (double)fmul_f(0.75f, lf));
        check(nvn_scale_now(&p) == 0.5 && fmul_f(0.75f, lf) >= 0.5f && lf < 0.6668f, b);
        // the float floor where the rounded quotient alone falls under it: Render scale 0.85 (as the loader writes it, a float) x 70% x the rescue's 0.75 is 0.446, floored to
        // 0.5; (float)(0.5 / 0.85f) is 0.58823526f, and the stubs' 0.85f x it 0.49999997f. nvn_scale_live's nextafterf loop takes the next float up
        nvn_scale f85; nvn_scale_init(&f85, (double)0.85f); nvn_scale_set(&f85, NVN_SCALE_HEAT, 0.70); nvn_scale_set(&f85, NVN_SCALE_RESCUE, RESCUE_SCALE_T);
        const float l85 = nvn_scale_live(&f85), q85 = (float)(nvn_scale_now(&f85) / (double)0.85f);
        snprintf(b, sizeof b, "  Render scale 0.85 x 70%% x 0.75 at the floor: the factor %.8f above the rounded quotient %.8f, 0.85 x it %.8f (the quotient's %.8f)", l85, q85,
                 (double)fmul_f(0.85f, l85), (double)fmul_f(0.85f, q85));
        check(nvn_scale_now(&f85) == 0.5 && l85 > q85 && fmul_f(0.85f, l85) >= 0.5f && fmul_f(0.85f, q85) < 0.5f && l85 <= nextafterf(nextafterf(q85, 2.0f), 2.0f), b);
        // and over the launcher's Render scale grid (settings.tsv: 0.5 to 1.0 in steps of 0.05), each heat factor and the rescue's: the float product at least 0.5, the composed
        // scale within float rounding, the factor at most 1 and at most two float steps above the exact quotient (raised only as far as the floor needs)
        int fl_ok = 1, raised = 0, cases = 0;
        for (int i = 0; i <= 10; i++)
            for (int h = 0; h < 3; h++)
                for (int rr = 0; rr < 2; rr++) {
                    const float pf = (float)(0.5 + 0.05 * i); const double heat = h == 0 ? 1 : h == 1 ? 0.85 : 0.70;
                    nvn_scale g; nvn_scale_init(&g, (double)pf); nvn_scale_set(&g, NVN_SCALE_HEAT, heat); nvn_scale_set(&g, NVN_SCALE_RESCUE, rr ? RESCUE_SCALE_T : 1);
                    const double want = nvn_scale_now(&g), q = want / (double)pf; const float l = nvn_scale_live(&g), prod = fmul_f(pf, l);
                    fl_ok &= prod >= 0.5f && fabs((double)prod - want) <= 2.5e-7 && l <= 1.0f && (double)nextafterf(nextafterf(l, 0), 0) < q;
                    raised += l > (float)q; cases++;
                }
        snprintf(b, sizeof b, "  the Render scale grid x {1, 85%%, 70%%} x {1, the rescue}: %d cases, the float floor held (%d raised past the rounded quotient)", cases, raised);
        check(fl_ok && raised > 0, b);
        nvn_scale q; nvn_scale_init(&q, 0.5); nvn_scale_set(&q, NVN_SCALE_HEAT, 0.85);
        check(nvn_scale_now(&q) == 0.5 && nvn_scale_live(&q) == 1.0f && !nvn_scale_set(&q, NVN_SCALE_RESCUE, RESCUE_SCALE_T), "  Render scale 0.5: nothing lower (factor 1.0); the rescue then changes nothing");
        nvn_scale z; nvn_scale_init(&z, 0);
        check(z.f[NVN_SCALE_PLAYER] == 1 && !nvn_scale_set(&z, NVN_SCALE_PLAYER, 0.5) && !nvn_scale_set(&z, NVN_SCALE_HEAT, 1.5) && !nvn_scale_set(&z, NVN_SCALE_HEAT, 0.2) && nvn_scale_now(&z) == 1,
              "  an unset player's scale is 1; the player's is not the setter's; a factor out of 0.5-1 is no factor");
        // the stretch (the Mario Kart World family): 1 / scale² of the heat and rescue factors, the player's not in it, at most 4 (the floor)
        nvn_scale k; nvn_scale_init(&k, 1.0);
        double k0 = nvn_scale_stretch(&k); nvn_scale_set(&k, NVN_SCALE_HEAT, 0.85); double k85 = nvn_scale_stretch(&k);
        nvn_scale_set(&k, NVN_SCALE_HEAT, 0.70); double k70 = nvn_scale_stretch(&k); nvn_scale_set(&k, NVN_SCALE_HEAT, 1.0); nvn_scale_set(&k, NVN_SCALE_RESCUE, RESCUE_SCALE_T);
        double kr = nvn_scale_stretch(&k); nvn_scale_set(&k, NVN_SCALE_HEAT, 0.85); double kb = nvn_scale_stretch(&k); nvn_scale_set(&k, NVN_SCALE_HEAT, 0.5); double kf = nvn_scale_stretch(&k);
        snprintf(b, sizeof b, "stretch: none %.2f, 85%% %.2f, 70%% %.2f, the rescue %.2f, 85%% and the rescue %.2f, at the floor %.2f", k0, k85, k70, kr, kb, kf);
        check(k0 == 1 && k85 > 1.38 && k85 < 1.39 && k70 > 2.04 && k70 < 2.05 && kr > 1.77 && kr < 1.78 && kb > 2.46 && kb < 2.47 && kf == 4, b);
        // DM_HEAT_GPU_STRETCH and the heat factor a rung gives the lever
        double kk[3] = {0, 0, 0};
        int n2 = nvn_heat_stretch_parse("1.5,2.5", kk), n3 = nvn_heat_stretch_parse("1.2,1.6,2", kk);
        check(n2 == 2 && n3 == 3 && kk[0] == 1.2 && kk[1] == 1.6 && kk[2] == 2, "DM_HEAT_GPU_STRETCH 1.5,2.5 and 1.2,1.6,2 taken");
        static const char *badk[] = {"", "1.5", "2,1.5", "0.9,2", "1.5,4.1", "1.5,2,", "1.5,2,3,4", "1.5;2", "nan,2", "1.5,inf", "1.5,2x"};
        int refused = 0; double keep[3] = {9, 9, 9};
        for (unsigned i = 0; i < sizeof badk / sizeof *badk; i++) refused += nvn_heat_stretch_parse(badk[i], keep) < 0;
        snprintf(b, sizeof b, "  %d of %d bad values refused, none taken (one value, out of order, under 1, over 4, a trailing comma, four, junk, nan, inf)", refused, (int)(sizeof badk / sizeof *badk));
        check(refused == (int)(sizeof badk / sizeof *badk) && keep[0] == 9 && keep[2] == 9, b);
        run_t r; init(&r, 1, 1, 1, 0, 0); r.in.nothold = 0.2; r.in.gpu_bound = 1;
        double l0 = nvn_heat_lever(&r.h, NULL); at(&r, 11, 1); double l1 = nvn_heat_lever(&r.h, NULL), l1k = nvn_heat_lever(&r.h, (double[3]){4, 4, 0});
        at(&r, 31, 1); double l2 = nvn_heat_lever(&r.h, NULL), l2k = nvn_heat_lever(&r.h, (double[3]){1.5, 2.25, 0});
        check(l0 == 1 && l1 == 0.85 && l1k == 0.5 && on(&r, HEAT_R2) && l2 == 0.70 && fabs(l2k - 1 / 1.5) < 1e-12,
              "  the lever's factor: 1, 85%, 70%; with DM_HEAT_GPU_STRETCH the factor whose stretch it is (k 4: 0.5; 2.25: 2/3)");
    }
    {   // the GPU time stretch of the reports (nvn_mtl.m post_run): a submission's reports move back from its end by k times their distance, the end stays, nothing reads later
        // than it was, and nothing earlier than the latest time written for the submissions before it (read once per submission, sub below), so a stretch longer than the
        // idle time before a submission stops there
        uint64_t fl = 0, o[8]; const double k = 1.5;
        // frame 1: reports at 100 (its start) and 110 (its end); frame 2: 116.7 to 126.7, its 5 of stretch within the 6.7 of idle before it
        sub((const uint64_t[]){100000, 110000}, 2, 110000, k, &fl, o); uint64_t a = o[0], e1 = o[1];
        sub((const uint64_t[]){116700, 126700}, 2, 126700, k, &fl, o); uint64_t c = o[0], e2 = o[1];
        check(a == 95000 && e1 == 110000 && c == 111700 && e2 == 126700, "stretch x1.5: a 10 span reads 15, its end where it was (95, 110; 111.7, 126.7)");
        // a heavier frame: 129 to 141.4 (12.4 of GPU, 2.3 of idle before it): 1.5 x 12.4 = 18.6 back from 141.4 is 122.8, before frame 2's end (126.7): held there
        sub((const uint64_t[]){129000, 135000, 141400}, 3, 141400, k, &fl, o);
        check(o[0] == 126700 && o[1] == 131800 && o[2] == 141400, "  not before the submission before it: the start held at its end (126.7), the rest still stretched");
        // a submission's ops are not in time order: rep_ticks gives a TIMESTAMP_TOP its segment's start and a BOTTOM its end, so TOP, BOTTOM, TOP, BOTTOM in one segment
        // (100 to 110) read S, E, S, E. Both pairs read k (E - S) = 13.8 at k 1.38; a floor taken report by report lifted the second TOP to the first BOTTOM's 110: a span of 0
        uint64_t f4 = 0; sub((const uint64_t[]){100000, 110000, 100000, 110000}, 4, 110000, 1.38, &f4, o);
        snprintf(b, sizeof b, "  TOP, BOTTOM, TOP, BOTTOM in one segment at x1.38: %llu %llu %llu %llu, both spans 13.8", (unsigned long long)o[0], (unsigned long long)o[1], (unsigned long long)o[2], (unsigned long long)o[3]);
        check(o[0] == o[2] && o[1] == 110000 && o[3] == 110000 && o[1] - o[0] >= 13799 && o[1] - o[0] <= 13800 && f4 == 110000, b);   // 10,000 x 1.38 in a double: 13,799.99
        f4 = 98000; sub((const uint64_t[]){100000, 110000, 100000, 110000}, 4, 110000, 1.38, &f4, o);
        check(o[0] == 98000 && o[2] == 98000 && o[1] == 110000 && o[3] == 110000, "  the same after a submission that ended at 98: both TOPs held at 98, neither lifted to the BOTTOM before it");
        // a record run early with c1 = now (post_early, or a later fence's handler) writes its end later than the next submission's own times: 105 against 100 to 110. The
        // next submission's start reads no later than it was (100, not 105), its end where it was
        uint64_t f5 = 0; sub((const uint64_t[]){90000, 105000}, 2, 105000, 1.5, &f5, o);
        sub((const uint64_t[]){100000, 110000}, 2, 110000, 1.5, &f5, o);
        check(o[0] == 100000 && o[1] == 110000 && f5 == 110000, "  after a submission written later than this one's own times: its start at its own time (100), not the floor (105)");
        // order and nothing in the future, over submissions of random spans and idle times, with k from 1 to 4 and back
        uint64_t t = 1000000, last = 0, fl2 = 0; int ordered = 1, past = 1, ends = 1, ident = 1; unsigned seed = 12345;
        for (int i = 0; i < 20000; i++) {
            seed = seed * 1103515245u + 12345u; uint64_t idle = (seed >> 8) % 9000, span = 1000 + (seed >> 4) % 15000; int nrep = 1 + (int)((seed >> 20) % 5);
            double kk2 = i % 3000 < 1000 ? 1.0 : 1.0 + (double)((seed >> 12) % 300) / 100;
            uint64_t s0 = t + idle, e = s0 + span, x[5];
            for (int j = 0; j < nrep; j++) x[j] = j == nrep - 1 ? e : s0 + span * (uint64_t)j / (uint64_t)nrep;
            sub(x, nrep, e, kk2, &fl2, o);
            for (int j = 0; j < nrep; j++) {
                uint64_t y = o[j];
                ordered &= y >= last; past &= y <= x[j]; if (j == nrep - 1) ends &= y == e; if (kk2 == 1.0) ident &= y == x[j];
                last = y;
            }
            t = e;
        }
        check(ordered && past && ends && ident, "  20,000 submissions, k 1 to 4 and back: in order, none later than it was, every end where it was, k 1 untouched");
        check(nvn_heat_stretch_ts(400, 0, 2.0, 500) == 400 && nvn_heat_stretch_ts(300, 1000, 1.0, 500) == 300 && nvn_heat_stretch_ts(300, 1000, 2.0, 500) == 300,
              "  no end known: not moved, and not lifted to the floor; k 1 never moves a report; a report before the floor reads its own time");
    }
    {   // the GPU time scale (profile gpu_time_scale: Donkey Kong Bananza 0.6144, DM_GPU_TIME_SCALE): k below 1 shortens a submission's spans toward its end, which stays; the
        // heat and rescue stretch multiply it (nvn_scale_stretch_at)
        const double base = 0.6144; uint64_t fl = 0, o[8];
        sub((const uint64_t[]){100000, 110000}, 2, 110000, base, &fl, o);
        check(o[0] == 103857 && o[1] == 110000 && fl == 110000, "time scale x0.6144: a 10 span reads 6.143 (10,000 x 0.6144 in a double: 6,143.99), its end where it was, the floor at the end");
        // TOP, BOTTOM, TOP, BOTTOM in one segment: both pairs 6.144; a report past the anchor (a time later than the last segment's end) stays where it was
        uint64_t f2 = 0; sub((const uint64_t[]){100000, 110000, 100000, 110000, 111000}, 5, 110000, base, &f2, o);
        check(o[0] == 103857 && o[2] == 103857 && o[1] == 110000 && o[3] == 110000 && o[4] == 111000 && f2 == 111000, "  TOP, BOTTOM, TOP, BOTTOM both 6.144; a report past the end not moved");
        check(nvn_heat_stretch_ts(400, 0, base, 500) == 400 && nvn_heat_stretch_ts(0, 1000, base, 0) == 386 && nvn_heat_stretch_ts(999, 1000, base, 0) == 1000,
              "  no end known: not moved; a report at 0 reads within its submission (386); one just before the end at the end, not past it");
        // composed: base x the heat or rescue stretch; base 1 is exactly the stretch as before (bit for bit)
        nvn_scale q; nvn_scale_init(&q, 1.0);
        double c0 = nvn_scale_stretch_at(&q, base); nvn_scale_set(&q, NVN_SCALE_HEAT, 0.85); double c85 = nvn_scale_stretch_at(&q, base);
        nvn_scale_set(&q, NVN_SCALE_HEAT, 0.70); double c70 = nvn_scale_stretch_at(&q, base); nvn_scale_set(&q, NVN_SCALE_HEAT, 1.0); nvn_scale_set(&q, NVN_SCALE_RESCUE, RESCUE_SCALE_T);
        double cr = nvn_scale_stretch_at(&q, base);
        snprintf(b, sizeof b, "  composed: at rest %.4f, 85%% %.3f, 70%% %.3f, the rescue %.3f (base x 1 / scale²)", c0, c85, c70, cr);
        check(c0 == base && c85 > 0.850 && c85 < 0.851 && c70 > 1.253 && c70 < 1.254 && cr > 1.092 && cr < 1.093, b);
        int same = 1; nvn_scale z; nvn_scale_init(&z, 1.0);
        static const double fs[] = {1.0, 0.85, 0.70, 0.75, 0.6375, 0.5};
        for (unsigned i = 0; i < sizeof fs / sizeof *fs; i++) {
            nvn_scale_set(&z, NVN_SCALE_HEAT, fs[i]); double k1 = nvn_scale_stretch_at(&z, 1.0), k = nvn_scale_stretch(&z);
            same &= memcmp(&k1, &k, sizeof k) == 0;
            for (uint64_t x = 90000; x <= 112000; x += 1700) same &= nvn_heat_stretch_ts(x, 110000, k1, 95000) == nvn_heat_stretch_ts(x, 110000, k, 95000);
        }
        check(same, "  base 1: k bit for bit the stretch's, and every report the same as before");
        // 85% on top of the scale: 6.144 x 1.38 = 8.5 of a 10 span; at 70% (k 1.25 > 1) the floor binds again as for any stretch
        uint64_t f3 = 0; sub((const uint64_t[]){100000, 110000}, 2, 110000, c85, &f3, o);
        check(o[0] >= 101496 && o[0] <= 101497 && o[1] == 110000, "  at 85% with the scale: a 10 span reads 8.50");
        f3 = 98000; sub((const uint64_t[]){100000, 110000}, 2, 110000, c70, &f3, o);
        check(o[0] == 98000 && o[1] == 110000, "  at 70% with the scale (k 1.25): the start held at the submission before it (98)");
        // order, the end, and nothing outside [x, end], over random submissions with k from 0.25 to 4 and back
        uint64_t t = 1000000, last = 0, fl2 = 0, prev_end = 0; int ordered = 1, inside = 1, ends = 1, ident = 1, floor_ok = 1, early_ok = 1; unsigned seed = 777;
        for (int i = 0; i < 20000; i++) {
            seed = seed * 1103515245u + 12345u; uint64_t idle = (seed >> 8) % 9000, span = 1000 + (seed >> 4) % 15000; int nrep = 1 + (int)((seed >> 20) % 5);
            double kk = i % 4000 < 1000 ? 1.0 : i % 4000 < 2500 ? NVN_TIME_SCALE_MIN + (double)((seed >> 12) % 75) / 100 : base * (1.0 + (double)((seed >> 12) % 300) / 100);
            uint64_t s0 = t + idle, e = s0 + span, x[5];
            for (int j = 0; j < nrep; j++) x[j] = j == nrep - 1 ? e : s0 + span * (uint64_t)j / (uint64_t)nrep;
            const uint64_t lo = fl2; sub(x, nrep, e, kk, &fl2, o);
            for (int j = 0; j < nrep; j++) {
                uint64_t y = o[j];
                ordered &= y >= last; if (j == nrep - 1) ends &= y == e; if (kk == 1.0) ident &= y == x[j];
                if (kk < 1) inside &= y >= x[j] && y <= e; else inside &= y <= x[j];
                floor_ok &= y >= (lo < x[j] ? lo : x[j]) && y >= prev_end;   // nothing before the submission before it ended
                last = y;
            }
            prev_end = e; t = e;
        }
        // a record run early: its end (105) later than the next submission's start (100); at k < 1 the next one's start stays within its own submission, its end where it was
        uint64_t f5 = 0; sub((const uint64_t[]){90000, 105000}, 2, 105000, base, &f5, o); early_ok &= o[1] == 105000 && o[0] <= 105000;
        sub((const uint64_t[]){100000, 110000}, 2, 110000, base, &f5, o); early_ok &= o[0] >= 100000 && o[0] <= 110000 && o[1] == 110000 && f5 == 110000;
        check(ordered && inside && ends && ident && floor_ok && early_ok,
              "  20,000 submissions, k 0.25 to 4 and back: in order, k < 1 within [x, end], k > 1 none later than it was, ends kept, never before the last end, k 1 untouched");
        double v = 0;
        check(nvn_gpu_time_scale_parse("0.6144", &v) == 0 && v == 0.6144 && nvn_gpu_time_scale_parse("1", &v) == 0 && v == 1 && nvn_gpu_time_scale_parse("0.25", &v) == 0,
              "DM_GPU_TIME_SCALE 0.6144, 1 and 0.25 taken");
        static const char *badv[] = {"", "0", "0.2", "1.01", "2", "-0.5", "nan", "inf", "0.6x", "0.6,1"};
        int refused = 0; v = 9;
        for (unsigned i = 0; i < sizeof badv / sizeof *badv; i++) refused += nvn_gpu_time_scale_parse(badv[i], &v) < 0;
        check(refused == (int)(sizeof badv / sizeof *badv) && v == 9, "  empty, 0, under 0.25, over 1, negative, nan, inf and junk refused, none taken");
    }
    {   // the switches' parsers
        nvn_heat_force f; nvn_heat_force_parse(&f, "1:60,2:240,0:420");
        check(nvn_heat_force_at(&f, 10) == -2 && nvn_heat_force_at(&f, 60) == 1 && nvn_heat_force_at(&f, 300) == 2 && nvn_heat_force_at(&f, 999) == 0, "DM_HEAT_FORCE timeline 1:60,2:240,0:420");
        check(nvn_heat_force_parse(&f, "2") == 1 && nvn_heat_force_at(&f, 0) == 2 && nvn_heat_force_parse(&f, "2:60,1:30") < 0 && nvn_heat_force_parse(&f, "x") < 0, "  a state alone; a timeline out of order and junk refused");
        nvn_heat_cfg c = nvn_heat_defaults();
        check(nvn_heat_tune(&c, "r1=20,share=15,res1=0.9,wait_max=600") == 4 && c.r1_on == 20 * HEAT_S && c.share > 0.149 && c.share < 0.151 && c.res1 == 0.9 && c.wait_max == 600 * HEAT_S,
              "DM_HEAT_TUNE r1=20,share=15,res1=0.9,wait_max=600");
        check(nvn_heat_tune(&c, "bogus=1") < 0 && nvn_heat_tune(&c, "res2=0.3") < 0, "  an unknown key or a scale under 0.5 refused");
        // Refused whole, nothing taken: an empty value (r4_wait= gave a 0 s wait, the hold off at the first calm sample, with no red line), one that is not a finite number
        // (nan passed the range checks, inf was a conversion out of range), a time over a day, a wait of 0, a first wait over its longest, a share over 100
        static const char *bad[] = {"r4_wait=", "r4_wait=,share=5", "share=", "res1=nan", "share=nan", "evid=inf", "r4_wait=nan", "r1=1e30", "evid=86401", "wait=0",
                                    "r4_wait_max=0", "r4_wait=60,r4_wait_max=30", "wait=400", "wait_max=10", "share=101", "res2=1.5", "gap=-1", "r1=5x"};
        nvn_heat_cfg d = nvn_heat_defaults(); int refused = 0, kept = 1;
        for (unsigned i = 0; i < sizeof bad / sizeof *bad; i++) { nvn_heat_cfg t = d; int r = nvn_heat_tune(&t, bad[i]); refused += r < 0; kept &= !memcmp(&t, &d, sizeof t); if (r >= 0) printf("  taken: %s\n", bad[i]); }
        snprintf(b, sizeof b, "  %d of %d bad values refused, nothing taken (empty, nan, inf, over a day, a 0 wait, wait over its _max, share, scale)", refused, (int)(sizeof bad / sizeof *bad));
        check(refused == (int)(sizeof bad / sizeof *bad) && kept, b);
        nvn_heat_cfg t = d; int ok = nvn_heat_tune(&t, "r1=0,share=0,wait=300,r4_wait=240,evid=86400") == 5 && t.r1_on == 0 && t.share == 0 && t.wait0 == t.wait_max && t.evid == 86400 * HEAT_S;
        check(ok, "  r1=0, share=0, a wait at its _max and a day are taken");
        // DM_HEAT_FORCE: a 17th entry was cut off with no red line, and a time of nan or inf was taken and never reached
        char tl[400] = ""; for (int i = 0; i < 17; i++) snprintf(tl + strlen(tl), sizeof tl - strlen(tl), "%s%d:%d", i ? "," : "", i % 4, 10 * i);
        int over = nvn_heat_force_parse(&f, tl), n17 = f.n;
        tl[strlen(tl) - strlen(",0:160")] = 0; int sixteen = nvn_heat_force_parse(&f, tl) == 16 && nvn_heat_force_at(&f, 150) == 3;
        check(over < 0 && n17 == 0 && sixteen, "  DM_HEAT_FORCE: 17 entries refused (none kept), 16 taken");
        check(nvn_heat_force_parse(&f, "2:nan") < 0 && f.n == 0 && nvn_heat_force_parse(&f, "1:60,2:inf") < 0 && nvn_heat_force_parse(&f, "1:") < 0 && nvn_heat_force_parse(&f, "1:-5") < 0,
              "  a time of nan, inf, none or below 0 refused");
    }
    printf("== %d checks, %d failed ==\n", checks, fail);
    return fail != 0;
}
