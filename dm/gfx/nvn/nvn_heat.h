// The heat ladder (NX18-X2.0 heat-ladder.md; unit test tests/t_heat.c): one controller samples the phone's heat once a second, for every game, and moves up and down a
// ladder whose rungs each give up one thing. Pure: no platform code, no clock of its own; hle_nvn.c heat_sample feeds it under thermal_capped's lock.
//
// Rungs, in the order they go on (R4 last, the owner's order, heat-ladder.md §3.1):
//   R1  resolution to 85%       state >= 1 for r1_on (10 s)
//   R2  resolution to 70%       state >= 1 and 60 not holding (GPU-bound) for evid (30 s); or state >= 2
//   RE  effects off (D13)       as R2 (GPU-bound evidence: MetalFX, edge smoothing and sharpening are GPU work), after it
//   R3  60 -> 40 fps            state >= 1 and 60 not holding for evid; or state >= 2. Only where the game is checked at 40 and the 40 gate passes now
//   R4  30 fps (today's hold)   state 3 at once; state 2 at once where neither 70% nor 40 went on (heat-ladder.md §8.5), else after s2_r4 behind 70% (D15 (a): 15 s)
//                               or s2_r4_40 behind 40 (D1 (b): 30 s) unless frames are late at that rung (judged on frames at it, timed from it: HEAT_LATE_ON)
// Each rung a game cannot take (can[], heat-ladder.md §3.3) is passed over; the next real rung still waits for its own trigger and its gap after the last real one.
// At state 1 the real down-steps are at least gap (30 s) apart, R1 first where the game can take it, and the evidence for each is gathered at state 1 at the rung in
// force: each rung change starts it again (and the caller's "60 not holding" window, hle_nvn.c). State 2 jumps to its target in one change. Rungs come back one at a time, last in first out (stack),
// each after its restore wait at state 0 (R4: at state <= 1), at least min_on after it went on; R2/RE/R3 also at state 1 once 60 would fit again for evid_exit (2 min)
// in the rung. The restore wait doubles each time the same rung comes back on within rearm (10 min) of its last end: 60 -> 120 -> 240 -> 300 s, R4 30 -> 60 -> 120 ->
// 240 s (claude/x2-heat-backoff's rule, which the controller takes over as it is). Any hot sample restarts the calm.
// Away (heat-ladder.md §3.4; the caller's away, the app's time in the background since the last sample): nothing is sampled there, so each calm pauses and goes on
// from where it was, with the last restore the next rung's wait counts from and the times the lower rungs went on (min_on, the evidence exit); a stay of a rung's longest
// wait or more that comes back at state 0 ends the rung at once, dated to the stay's start. The rearm's 10 min (off_at) count wall time, the stay too.
// Low Power Mode is a second cause of R4 (D3), apart from the ladder: 30 at once, back THERMAL_LP_CALM (30 s) after it ends, and at once when its setting goes off.
// steps = 0 (DM_HEAT_STEPS=0): only R4 and Low Power Mode, today's behaviour with the back-off. Hot-dim (dim, Dim 1 / Dim 2) is computed only where the front end can
// dim (dim_ok); the resolution, effects and 40 fps rungs only where the caller says the game can take them (can[]): 85% and 70% where the game has a live resolution lever
// (step 4, hle_nvn.c dm_heat_can: the +0x14 stubs of Breath of the Wild and Tears of the Kingdom, those that lower the player's scale (nvn_heat_can_res), and the Mario Kart
// World family's GPU time stretch); effects and 40 fps none yet.
// Times are nanoseconds on the caller's clock (hle_nvn.c: now_cont_ns, which counts the device's sleep).
#pragma once
#include <math.h>
#include <stddef.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

enum { HEAT_R1, HEAT_R2, HEAT_RE, HEAT_R3, HEAT_R4, HEAT_NR };
enum { HEAT_CAP_HEAT = 1, HEAT_CAP_LP = 2 };   // R4's causes (hle_nvn.c CAP_HEAT, CAP_LOW_POWER)
#define HEAT_S 1000000000ull
#define THERMAL_LP_CALM (30 * HEAT_S)

// The placeholders of heat-ladder.md, set from the round's phone logs (x2-round-all-on.md) and overridable by DM_HEAT_TUNE (nvn_heat_tune). Seconds, a share and two scales
typedef struct {
    uint64_t r1_on;        // state >= 1 this long before R1 and Dim 1: 10 s. Once reached, state 1 stayed (MKW run 2 from 174 s, OoT's field run from 280 s, LM3 537 s)
    uint64_t evid;         // 60 not holding this long at state 1 before R2, RE or R3: 30 s (MKW's crowded stretch at 50-55 fps lasted 15-30 s at state 0)
    uint64_t gap;          // between real down-steps at state 1: 30 s
    uint64_t s2_r4;        // D15 (a): state 2 with 70% on and no 40: R4 after 15 s (the note's 10-15 s, its upper end: OoT's field run sat at state 2 for minutes)
    uint64_t s2_r4_40;     // D1 (b): state 2 with 40 on: R4 after 30 s
    uint64_t wait0, wait_max;     // the ladder's restore wait: 60 s, doubled up to 300 s
    uint64_t r4_wait0, r4_wait_max;   // R4's: 30 s, doubled up to 240 s (OoT's 55-minute run was at state 2 again 51-391 s after each 30 s calm)
    uint64_t rearm;        // a rung back on within this of its last end doubles its wait: 10 min
    uint64_t min_on;       // each ladder rung stays on at least 60 s
    uint64_t evid_exit;    // R2/RE/R3 come back at state 1 once 60 fits again after 2 min in the rung
    uint64_t dim2_off;     // Dim 2 back to Dim 1 after 30 s at state <= 1
    double share;          // 60 not holding: over 10% of the last 30 s
    double res1, res2;     // R1, R2: 0.85, 0.70 of the player's render scale
} nvn_heat_cfg;

static inline nvn_heat_cfg nvn_heat_defaults(void) {
    nvn_heat_cfg c = { 10 * HEAT_S, 30 * HEAT_S, 30 * HEAT_S, 15 * HEAT_S, 30 * HEAT_S, 60 * HEAT_S, 300 * HEAT_S, 30 * HEAT_S, 240 * HEAT_S, 600 * HEAT_S, 60 * HEAT_S,
                       120 * HEAT_S, 30 * HEAT_S, 0.10, 0.85, 0.70 };
    return c;
}
// DM_HEAT_TUNE: key=value pairs separated by commas (seconds; share in percent; res in scale): r1, evid, gap, s2, s2_40, wait, wait_max, r4_wait, r4_wait_max, rearm,
// min_on, exit, dim2_off, share, res1, res2. Returns the pairs taken, or -1 when one is refused, and then none is taken (c as it was): an unknown key, an empty value, one that
// is not a finite number (nan, inf) or below 0, a time over HEAT_TUNE_MAX_S, a restore wait of 0 (its doubling would stay 0: the hold would end at the first calm sample),
// a share over 100%, a scale outside 0.5-1, and a first wait over its longest (wait > wait_max, r4_wait > r4_wait_max: a rung that came back would wait less). The range
// checks are written so a NaN fails them
#define HEAT_TUNE_MAX_S 86400.0   // a day: (uint64_t)(v * 1e9) stays defined, and a wait's doubling cannot wrap
static inline int nvn_heat_tune(nvn_heat_cfg *c, const char *s) {
    static const struct { const char *k; size_t off; int pos; } T[] = {   // pos: the restore waits, which must be above 0
        {"r1", offsetof(nvn_heat_cfg, r1_on), 0}, {"evid", offsetof(nvn_heat_cfg, evid), 0}, {"gap", offsetof(nvn_heat_cfg, gap), 0}, {"s2", offsetof(nvn_heat_cfg, s2_r4), 0},
        {"s2_40", offsetof(nvn_heat_cfg, s2_r4_40), 0}, {"wait", offsetof(nvn_heat_cfg, wait0), 1}, {"wait_max", offsetof(nvn_heat_cfg, wait_max), 1},
        {"r4_wait", offsetof(nvn_heat_cfg, r4_wait0), 1}, {"r4_wait_max", offsetof(nvn_heat_cfg, r4_wait_max), 1}, {"rearm", offsetof(nvn_heat_cfg, rearm), 0},
        {"min_on", offsetof(nvn_heat_cfg, min_on), 0}, {"exit", offsetof(nvn_heat_cfg, evid_exit), 0}, {"dim2_off", offsetof(nvn_heat_cfg, dim2_off), 0}};
    nvn_heat_cfg t = *c; int n = 0;
    while (s && *s) {
        while (*s == ' ' || *s == ',') s++;
        if (!*s) break;
        const char *eq = strchr(s, '='), *end = strchr(s, ','); if (!end) end = s + strlen(s);
        if (!eq || eq > end) return -1;
        size_t kl = (size_t)(eq - s); char *e; double v = strtod(eq + 1, &e);
        if (e == eq + 1 || e != end || !isfinite(v) || !(v >= 0)) return -1;   // empty, junk after the number, nan or inf, below 0
        int done = 0;
        if (kl == 5 && !strncmp(s, "share", 5)) { if (!(v <= 100)) return -1; t.share = v / 100; done = 1; }
        else if (kl == 4 && !strncmp(s, "res1", 4)) { if (!(v >= 0.5 && v <= 1)) return -1; t.res1 = v; done = 1; }
        else if (kl == 4 && !strncmp(s, "res2", 4)) { if (!(v >= 0.5 && v <= 1)) return -1; t.res2 = v; done = 1; }
        else for (unsigned i = 0; i < sizeof T / sizeof *T; i++)
            if (strlen(T[i].k) == kl && !strncmp(s, T[i].k, kl)) {
                if (!(v <= HEAT_TUNE_MAX_S)) return -1;
                uint64_t ns = (uint64_t)(v * 1e9);
                if (T[i].pos && !ns) return -1;
                *(uint64_t *)((char *)&t + T[i].off) = ns; done = 1; break;
            }
        if (!done) return -1;
        n++; s = end;
    }
    if (t.wait0 > t.wait_max || t.r4_wait0 > t.r4_wait_max) return -1;
    *c = t;
    return n;
}

// DM_HEAT_FORCE (the Mac's test bench, an A/B's behaviour sitting): a state (0-3) for the whole session, or a timeline "state:from_s,..." (the state from that many seconds
// after the first sample on; before the first entry, the device's own) of at most HEAT_FORCE_N entries, its times finite and in order. Anything else is refused whole (-1,
// no entry kept). nvn_heat_force_at returns the forced state at t_s, or -2 for none
#define HEAT_FORCE_N 16
typedef struct { int n; int st[HEAT_FORCE_N]; double from[HEAT_FORCE_N]; } nvn_heat_force;
static inline int nvn_heat_force_parse(nvn_heat_force *f, const char *s) {
    f->n = 0;
    if (!s || !*s) return 0;
    if (s[0] >= '0' && s[0] <= '3' && !s[1]) { f->n = 1; f->st[0] = s[0] - '0'; f->from[0] = 0; return 1; }
    while (*s) {
        if (f->n == HEAT_FORCE_N) { f->n = 0; return -1; }   // more entries than kept: refused, not cut short
        char *e; long st = strtol(s, &e, 10);
        if (e == s || *e != ':' || st < 0 || st > 3) { f->n = 0; return -1; }
        s = e + 1; double t = strtod(s, &e);
        if (e == s || !isfinite(t) || !(t >= 0) || (f->n && t < f->from[f->n - 1])) { f->n = 0; return -1; }
        f->st[f->n] = (int)st; f->from[f->n] = t; f->n++;
        s = e; if (*s == ',') s++; else if (*s) { f->n = 0; return -1; }
    }
    return f->n;
}
static inline int nvn_heat_force_at(const nvn_heat_force *f, double t_s) {
    int r = -2;
    for (int i = 0; i < f->n; i++) if (t_s >= f->from[i]) r = f->st[i];
    return r;
}

// "60 not holding" over the last 30 s (heat-ladder.md §7.2): the caller adds each frame's time (nvn_fstep_nothold's verdict, in vsyncs) and closes a bucket at each sample
#define HEAT_WIN 30
typedef struct { double tot[HEAT_WIN], bad[HEAT_WIN], gpu[HEAT_WIN]; double ctot, cbad, cgpu; int i, n; } nvn_heat_win;
static inline void nvn_heat_win_add(nvn_heat_win *w, int verdict, double vsyncs) {   // verdict: nvn_fstep_nothold's (-1 not counted)
    if (verdict < 0 || vsyncs <= 0) return;
    w->ctot += vsyncs; if (verdict) { w->cbad += vsyncs; if (verdict == 1) w->cgpu += vsyncs; }
}
static inline void nvn_heat_win_close(nvn_heat_win *w) { w->tot[w->i] = w->ctot; w->bad[w->i] = w->cbad; w->gpu[w->i] = w->cgpu; w->i = (w->i + 1) % HEAT_WIN; if (w->n < HEAT_WIN) w->n++; w->ctot = w->cbad = w->cgpu = 0; }
static inline void nvn_heat_win_reset(nvn_heat_win *w) { memset(w, 0, sizeof *w); }   // a stay away, a rung or cap change: another scene, or frames at another rung
// The share of time not holding (-1: under 10 s of frames, nothing to judge), and whether those frames were mostly GPU-bound
static inline double nvn_heat_win_share(const nvn_heat_win *w, int *gpu_bound) {
    double t = 0, b = 0, g = 0; for (int i = 0; i < HEAT_WIN; i++) { t += w->tot[i]; b += w->bad[i]; g += w->gpu[i]; }
    if (gpu_bound) *gpu_bound = b > 0 && g >= 0.5 * b;
    return t >= 600 ? b / t : -1;   // 600 vsyncs: 10 s
}
#define HEAT_LATE_ON (10 * HEAT_S)   // frames late at the rung R4 waits behind (40, else 70%) count once it has been on this long: the window's 10 s of frames at it (the caller resets it at each change)

typedef struct {   // one sample's inputs
    uint64_t now;      // the caller's clock
    uint64_t away;     // the app's time away since the last sample (nothing was sampled there)
    int th;            // thermal state 0-3, -1 none (the Mac), a forced one with DM_HEAT_FORCE
    int lp;            // Low Power Mode is on and its setting (DM_LOW_POWER_CAP) holds 30 in it
    int lp_set;        // that setting is on (off: a Low Power Mode hold ends at once)
    double nothold;    // 60 not holding: the share of the last 30 s (nvn_heat_win_share; -1 not known: no frame step, or too few frames)
    int gpu_bound;     // and its late time mostly GPU-bound (R2 helps only then: a CPU-bound game skips it to R3)
    int fit60;         // the frame step's cost would fit 60 again (nvn_fstep_fit60)
    int ok40;          // the 40 gate passes now (a 120 Hz screen, no Low Power Mode, no TV)
    int charging;      // Dim 1 is held off while charging (D8)
} nvn_heat_in;

typedef struct { int rung, on, depth, cap; double res; } nvn_heat_ev;   // a change: rung (HEAT_R1..HEAT_R4; HEAT_NR + 1/2: Dim 1/2; HEAT_NR + 3: Low Power Mode), on or
                                                                        // off; the rungs on, the cap and the resolution factor right after it (each event its own, in order)
typedef struct {
    // the caller's, set before the first sample (kept)
    int steps;                 // 1: the ladder (Auto scaling, DM_HEAT_STEPS); 0: only R4 and Low Power Mode
    int heat_on;               // 0: no heat cause at all (DM_THERMAL_CAP=0): no ladder, no dim, no heat hold
    int can[HEAT_NR];          // the rungs this game can take; R4 always counts (whether the hold is used is the caller's: fps_step_cap and the engine hold)
    int dim_ok;                // the front end can dim (hot-dim, step 3); 0 = no dim levels at all
    nvn_heat_cfg c;
    // state
    int stack[HEAT_NR], depth; // rungs on, in the order they went on (R4's heat cause included; Low Power Mode is apart, in capped)
    int capped;                // R4's causes now: HEAT_CAP_HEAT, HEAT_CAP_LP
    uint64_t since1, since2;   // when the state went >= 1 / >= 2 (0: it is not)
    uint64_t calm0, calm1;     // when the state went to 0 / to <= 1 (0: it is not); R4's calm is calm1, paused away
    uint64_t evid_since, fit_since;   // when 60 stopped holding (over the share) / started to fit again (0: not)
    uint64_t last_down, last_up;      // the last real down-step, the last restore
    uint64_t on_at[HEAT_NR], off_at[HEAT_NR], wait[HEAT_NR];   // when each rung went on, ended (0: never), and its restore wait now
    uint64_t lp_calm;          // when Low Power Mode went off while it held (0: on, or it holds nothing)
    int dim; uint64_t dim1_wait, dim1_off_at, dim_calm2;   // hot-dim level 0-2; Dim 1's restore wait and last end; when Dim 2's state <= 1 began
    int r4_delayed;            // R4 waits at state 2 behind 70% or 40 (D15 / D1)
    uint64_t r4_hot2;          // when that wait began
    int th, ended_away;        // the last sample's state; the last sample ended rungs after a long stay
    unsigned flaps, entries[HEAT_NR];   // re-entries within rearm, in all and per rung (the session's flap count)
    nvn_heat_ev ev[2 * HEAT_NR + 4]; int nev;   // the last sample's changes, for the caller's log lines
} nvn_heat;

static inline void nvn_heat_init(nvn_heat *h, int steps, int heat_on) {
    memset(h, 0, sizeof *h); h->steps = steps; h->heat_on = heat_on; h->c = nvn_heat_defaults(); h->can[HEAT_R4] = 1;
    for (int r = 0; r < HEAT_NR; r++) h->wait[r] = r == HEAT_R4 ? h->c.r4_wait0 : h->c.wait0;
    h->dim1_wait = h->c.wait0;
}
static inline int nvn_heat_on(const nvn_heat *h, int r) { for (int i = 0; i < h->depth; i++) if (h->stack[i] == r) return 1; return 0; }
static inline int nvn_heat_top(const nvn_heat *h) { return h->depth ? h->stack[h->depth - 1] : -1; }
// Outputs. The frame-rate cap the heat allows (30, 40, or 0: no cap from heat); the resolution factor under the player's render scale; effects off; the dim level
static inline int nvn_heat_cap(const nvn_heat *h) { return h->capped ? 30 : nvn_heat_on(h, HEAT_R3) ? 40 : 0; }
static inline double nvn_heat_res(const nvn_heat *h) { return nvn_heat_on(h, HEAT_R2) ? h->c.res2 : nvn_heat_on(h, HEAT_R1) ? h->c.res1 : 1.0; }
static inline int nvn_heat_fx_off(const nvn_heat *h) { return nvn_heat_on(h, HEAT_RE); }
static inline int nvn_heat_dim(const nvn_heat *h) { return h->dim; }
// The render scale a stub draws at, for the resolution rungs (step 4): the player's Render scale, the heat factor (nvn_heat_res) under it (D7) and the GPU clock rescue's
// factor (nvn_rescue.h, 0.75 for 3 s; 1 otherwise) under both, each its own factor so neither writes over the other's (nvn_scale below; the heat factor reaches the game at
// state +0x14, heat-ladder.md §6, not through the player's +0x10), clamped to 0.5 (no stub has a floor of its own)
static inline double nvn_heat_scale(double player, double heat, double rescue) { double v = player * heat * rescue; return v < 0.5 ? 0.5 : v; }
static inline uint64_t nvn_heat_maxwait(const nvn_heat *h, int r) { return r == HEAT_R4 ? h->c.r4_wait_max : h->c.wait_max; }
// The resolution rungs that lower this player's render scale (step 4; hle_nvn.c heat_sample, for a lever under the player's Render scale, the +0x14 stubs): 85% only where
// player x res1, floored, is at least HEAT_RES_STEP below the player's scale; 70% only where player x res2 is that far below what 85% gives (or the player's, without 85%).
// The 0.5 floor leaves Render scale 0.5 nothing to lower, and at 0.55 and 0.60 70% only 0.50 against 85%'s 0.50 and 0.51: a rung that changes nothing (or 0.51 → 0.50) is not
// offered, so at state 2 the 30 fps hold does not wait 15 s behind a 70% that did nothing (D15; it waits only behind 70% or 40). can[] as the caller set it, R1 and R2 cleared
#define HEAT_RES_STEP 0.02
static inline void nvn_heat_can_res(int can[HEAT_NR], double player, double res1, double res2) {
    const double s0 = nvn_heat_scale(player, 1, 1), s1 = nvn_heat_scale(player, res1, 1), s2 = nvn_heat_scale(player, res2, 1);
    if (!(s1 <= s0 - HEAT_RES_STEP)) can[HEAT_R1] = 0;
    if (!(s2 <= (can[HEAT_R1] ? s1 : s0) - HEAT_RES_STEP)) can[HEAT_R2] = 0;
}

// The render scale's live setter (step 4, heat-ladder.md §8.1; hle_nvn.c scale_set): three factors, each set by its owner alone and composed in one place by nvn_heat_scale,
// so the heat ladder and the GPU clock rescue never write over each other: the player's Render scale (DM_RENDER_SCALE as the loader wrote it to state +0x10; 1 = the game's
// own size), the heat factor (nvn_heat_res: 85%, 70%) and the rescue's (RESCUE_SCALE for its 3 s, nvn_rescue.h). What reaches the game:
//   nvn_scale_live: a build whose stubs read the host's factor at state +0x14 (LIVE_SCALE, Breath of the Wild and Tears of the Kingdom): the composed scale over the
//                   player's, so the stubs' player x it is the composed scale, floor included (they take the lower of it and the game's own dynamic scale at Render scale 1)
//   nvn_scale_now:  a build whose stub reads +0x10 alone (no LIVE_SCALE: a build from before it, or a stub with no live factor): the composed scale itself, written there
//                   (the clock rescue's way until then)
//   nvn_scale_stretch: the Mario Kart World engine family, whose own dynamic resolution steers by the GPU time its reports read (no player's scale there): 1 / scale² of the
//                   heat and rescue factors, so the time reads as long as the frame would take at full size if its cost follows its pixels (heat-ladder.md §6 point 4: 85%
//                   1.38, 70% 2.04, the rescue's 0.75 1.78, all three 2.46 at 85%; the 0.5 floor 4)
// A fourth owner, NVN_SCALE_HEADROOM: the GPU headroom controller's factor for the stretch family (nvn_drs_gpu.h, hle_nvn.c drs_gpu_tick; profile drs_gpu_scale on), composed
// with the heat factor (their product is the heat argument of nvn_heat_scale), so the 0.5 floor holds over all of them
enum { NVN_SCALE_PLAYER, NVN_SCALE_HEAT, NVN_SCALE_RESCUE, NVN_SCALE_HEADROOM, NVN_SCALE_N };
typedef struct { double f[NVN_SCALE_N]; } nvn_scale;
static inline void nvn_scale_init(nvn_scale *s, double player) { s->f[NVN_SCALE_PLAYER] = player > 0 ? player : 1; s->f[NVN_SCALE_HEAT] = s->f[NVN_SCALE_RESCUE] = s->f[NVN_SCALE_HEADROOM] = 1; }
static inline double nvn_scale_now(const nvn_scale *s) { return nvn_heat_scale(s->f[NVN_SCALE_PLAYER], s->f[NVN_SCALE_HEAT] * s->f[NVN_SCALE_HEADROOM], s->f[NVN_SCALE_RESCUE]); }
// One owner's factor (the heat ladder's or the rescue's, 0.5 to 1; anything else is 1, no factor): returns 1 when the composed scale changed
static inline int nvn_scale_set(nvn_scale *s, int who, double v) {
    if (who != NVN_SCALE_HEAT && who != NVN_SCALE_RESCUE && who != NVN_SCALE_HEADROOM) return 0;
    if (!(v >= 0.5 && v < 1)) v = 1;
    double was = nvn_scale_now(s); s->f[who] = v;
    return nvn_scale_now(s) != was;
}
static inline float nvn_scale_live(const nvn_scale *s) {
    double p = s->f[NVN_SCALE_PLAYER]; float v = (float)(nvn_scale_now(s) / p);
    while (v < 1 && (double)v * p < 0.5) v = nextafterf(v, 2.0f);   // rounded to a float, never under the floor: the stubs multiply it as a float
    return v > 1 ? 1 : v;
}
static inline double nvn_scale_stretch(const nvn_scale *s) { double v = nvn_heat_scale(1, s->f[NVN_SCALE_HEAT] * s->f[NVN_SCALE_HEADROOM], s->f[NVN_SCALE_RESCUE]); return 1 / (v * v); }
// The GPU time scale (profile gpu_time_scale, DM_GPU_TIME_SCALE; Donkey Kong Bananza 0.6144): the game's own factor on the spans its reports read, under the heat and rescue
// stretch: post_run's k is base × nvn_scale_stretch, so at rest the spans read base times their length (0.6144: what NVN2 games read before NVN2 timestamps were nanoseconds,
// 384 / 625) and a rung or the rescue still multiplies them by its own k. base 1 (every other game): k exactly as before (a product by 1.0 is exact)
static inline double nvn_scale_stretch_at(const nvn_scale *s, double base) { return base * nvn_scale_stretch(s); }
// DM_GPU_TIME_SCALE=<v>: the GPU time scale for an A/B, 0.25 to 1 (1: the reports' true times). Returns 0 with *v set, -1 with nothing taken
#define NVN_TIME_SCALE_MIN 0.25
static inline int nvn_gpu_time_scale_parse(const char *s, double *v) {
    if (!s || !*s) return -1;
    char *e; double t = strtod(s, &e);
    if (*e || !isfinite(t) || !(t >= NVN_TIME_SCALE_MIN && t <= 1)) return -1;
    *v = t; return 0;
}
// DM_HEAT_GPU_STRETCH=k85,k70[,k_rescue]: the stretch at 85%, at 70% and for the clock rescue, for an A/B (the defaults above assume the cost follows the pixels). Each from 1 to
// 4 (the 0.5 floor), k70 at least k85. The setter takes the factor whose stretch it is, 1 / sqrt(k), so the three still compose through nvn_heat_scale. Returns the values
// taken (2 or 3), or -1 with none taken
static inline int nvn_heat_stretch_parse(const char *s, double k[3]) {
    double t[3] = {0, 0, 0}; int n = 0;
    if (!s) return -1;
    for (;;) {
        char *e; double v = strtod(s, &e);
        if (e == s || n == 3 || !isfinite(v) || !(v >= 1 && v <= 4)) return -1;
        t[n++] = v; s = e;
        if (!*s) break;
        if (*s++ != ',') return -1;
    }
    if (n < 2 || t[1] < t[0]) return -1;
    memcpy(k, t, sizeof t);
    return n;
}
// The heat factor a rung gives a game's lever: nvn_heat_res, or with DM_HEAT_GPU_STRETCH's k for that rung, the factor whose stretch is k
static inline double nvn_heat_lever(const nvn_heat *h, const double k[3]) {
    int r = nvn_heat_on(h, HEAT_R2) ? 1 : nvn_heat_on(h, HEAT_R1) ? 0 : -1;
    return r < 0 ? 1.0 : k && k[r] >= 1 ? 1 / sqrt(k[r]) : r ? h->c.res2 : h->c.res1;
}
// A report's time as a game of that family reads it (the stretch, nvn_mtl.m post_run): a report at x of a submission whose last report reads e reads e - k (e - x), so
// every span inside the submission reads k times longer while its end (the time a frame-rate controller compares with its CPU clock: Donkey Kong Bananza's) stays where it was.
// The map is monotone in x, so a submission's reports keep the order their own times have, whatever order its ops write them in (rep_ticks gives a TIMESTAMP_TOP its segment's
// start and the other types its end: TOP, BOTTOM, TOP, BOTTOM in one segment read S, E, S, E, both pairs k (E - S)). floor: the latest time written for the submissions before
// (the caller's, read once per submission, the same for all its reports): no report reads earlier than min(floor, x), so a stretch longer than the GPU's idle time before the
// submission stops at the one before it, and none reads later than x: nothing in the future, also where an earlier submission's reports were written later than this one's
// own times (a record run early, with c1 = now: post_early, or by a later fence's handler). k = 1 (or not above 0): x. Units: any linear clock (the caller's are NVN's raw unit, nvn_timestamp.h: 614.4 MHz ticks, nanoseconds on NVN2; k and the span ratio it gives are the same in either)
// 0 < k < 1 (the GPU time scale, nvn_scale_stretch_at, with no rung or one that does not outweigh it): the same map compresses the spans toward the end, so a report reads
// later than x but never later than e (k (e - x) < e - x), and x itself where x >= e: every report stays within [x, max(x, e)] of its own submission, the order of its times
// kept, the end where it was, and the floor (at most x) never binds. Nothing passes the submission's end as its last segment reads it, so the next submission's reports, after
// that end on the GPU, keep their place after these
static inline uint64_t nvn_heat_stretch_ts(uint64_t x, uint64_t e, double k, uint64_t floor) {
    if (!(k > 0) || k == 1) return x;
    uint64_t t = x;
    if (e && x < e) { double d = (double)(e - x) * k; t = d >= (double)e ? 0 : e - (uint64_t)d; }
    const uint64_t lo = floor < x ? floor : x;
    return t < lo ? lo : t;
}

static inline void nvn_heat_ev_(nvn_heat *h, int rung, int on) {
    if (h->nev < (int)(sizeof h->ev / sizeof *h->ev)) { nvn_heat_ev *e = &h->ev[h->nev++]; e->rung = rung; e->on = on; e->depth = h->depth; e->cap = nvn_heat_cap(h); e->res = nvn_heat_res(h); }
}
// A rung changed: the frames from here on run at another rung, so the state-1 evidence (and the evidence exit's fit) start again there
static inline void nvn_heat_changed_(nvn_heat *h) { h->evid_since = h->fit_since = 0; }
static inline void nvn_heat_push_(nvn_heat *h, int r, uint64_t now) {   // r goes on: its wait doubles if it ended within rearm
    uint64_t w0 = r == HEAT_R4 ? h->c.r4_wait0 : h->c.wait0, wm = nvn_heat_maxwait(h, r);
    if (h->off_at[r] && now - h->off_at[r] < h->c.rearm) { h->wait[r] = h->wait[r] * 2 < wm ? h->wait[r] * 2 : wm; h->entries[r]++; h->flaps++; }
    else h->wait[r] = w0;
    h->stack[h->depth++] = r; h->on_at[r] = now;
    if (r == HEAT_R4) h->capped |= HEAT_CAP_HEAT;
    nvn_heat_changed_(h); nvn_heat_ev_(h, r, 1);
}
static inline void nvn_heat_pop_(nvn_heat *h, uint64_t when) {
    int r = h->stack[--h->depth]; h->off_at[r] = when ? when : 1; h->last_up = when;
    if (r == HEAT_R4) h->capped &= ~HEAT_CAP_HEAT;
    nvn_heat_changed_(h); nvn_heat_ev_(h, r, 0);
}
static inline void nvn_heat_remove_(nvn_heat *h, int r, uint64_t when) {   // r ends out of order (a rung that lost its screen, a long stay; dated when): kept in order otherwise
    int i = 0; while (i < h->depth && h->stack[i] != r) i++;
    if (i == h->depth) return;
    for (; i + 1 < h->depth; i++) h->stack[i] = h->stack[i + 1];
    h->depth--; h->off_at[r] = when ? when : 1;
    if (r == HEAT_R4) h->capped &= ~HEAT_CAP_HEAT;
    nvn_heat_changed_(h); nvn_heat_ev_(h, r, 0);
}

// Once a second (the caller's 1 s gate). Changes land in h->ev (h->nev)
static inline void nvn_heat_sample(nvn_heat *h, const nvn_heat_in *in) {
    const nvn_heat_cfg *c = &h->c; const uint64_t now = in->now, away = in->away;
    h->nev = 0; h->ended_away = 0;
    int th = h->heat_on ? in->th : -1; h->th = th;
    // Low Power Mode (D3): its own cause, apart from the ladder
    if (!in->lp_set && (h->capped & HEAT_CAP_LP)) { h->capped &= ~HEAT_CAP_LP; h->lp_calm = 0; nvn_heat_ev_(h, HEAT_NR + 3, 0); }
    if (in->lp) { h->lp_calm = 0; if (!(h->capped & HEAT_CAP_LP)) { h->capped |= HEAT_CAP_LP; nvn_heat_ev_(h, HEAT_NR + 3, 1); } }
    else if (h->capped & HEAT_CAP_LP) {
        if (!h->lp_calm) h->lp_calm = now;
        else if (now - h->lp_calm >= THERMAL_LP_CALM) { h->capped &= ~HEAT_CAP_LP; h->lp_calm = 0; nvn_heat_ev_(h, HEAT_NR + 3, 0); }
    }
    if (!h->heat_on) return;
    // Away: the calms pause, and a long stay that comes back at state 0 ends the rungs whose longest wait it covers, dated to its start
    if (h->calm0) h->calm0 += away;
    if (h->calm1) h->calm1 += away;
    if (h->since1) h->since1 += away;
    if (h->since2) h->since2 += away;
    if (h->dim_calm2) h->dim_calm2 += away;
    // and the other foreground-only times: the last restore (the next rung's wait counts from the later of it and calm0) and the lower rungs' times on (min_on, the evidence
    // exit, the 10 s at the rung R4 waits behind: HEAT_LATE_ON). Each is at or before the last sample, now - away at most, so none passes now. R4's on time stays: its calm
    // (calm1) counts alone, and the two shifted alike could meet, which reads as no calm. off_at stays: the rearm's 10 min count wall time
    if (h->last_up) h->last_up += away;
    for (int i = 0; i < h->depth; i++) if (h->stack[i] != HEAT_R4) h->on_at[h->stack[i]] += away;
    if (away) { h->evid_since = h->fit_since = 0; }
    if (th == 0 && away) {
        for (int i = h->depth - 1; i >= 0; i--) { int r = h->stack[i]; if (away >= nvn_heat_maxwait(h, r)) { nvn_heat_remove_(h, r, now - away); h->ended_away = 1; } }
        if (h->dim && away >= c->wait_max) { h->dim = 0; h->dim1_off_at = now - away; nvn_heat_ev_(h, HEAT_NR + 1, 0); }
    }
    // The state's timers (a state of -1, the Mac with nothing forced, is calm)
    if (th >= 1) { if (!h->since1) h->since1 = now; h->calm0 = 0; } else { h->since1 = 0; if (!h->calm0) h->calm0 = now; }
    if (th >= 2) { if (!h->since2) h->since2 = now; h->calm1 = 0; } else { h->since2 = 0; if (!h->calm1) h->calm1 = now; }
    int bad = in->nothold >= 0 && in->nothold > c->share;
    if (bad && th >= 1) { if (!h->evid_since) h->evid_since = now; } else h->evid_since = 0;   // the evidence is gathered at state 1 or above (§7.3), not before it
    if (in->fit60 && !bad) { if (!h->fit_since) h->fit_since = now; } else h->fit_since = 0;
    // A 40 that loses its screen (Low Power Mode, a TV) counts as skipped: it ends at once with no restore wait doubled for it (§7.3)
    if (nvn_heat_on(h, HEAT_R3) && !in->ok40) { nvn_heat_remove_(h, HEAT_R3, now); h->off_at[HEAT_R3] = 0; }
    // Down
    int can_r3 = h->can[HEAT_R3] && in->ok40;
    if (th >= 2 && h->steps) {   // state 2: its target in one change, then R4 (D1 / D15)
        int any = 0;
        for (int r = HEAT_R1; r <= HEAT_R3; r++) if ((r == HEAT_R3 ? can_r3 : h->can[r]) && !nvn_heat_on(h, r) && !nvn_heat_on(h, HEAT_R4)) { nvn_heat_push_(h, r, now); any = 1; }
        if (any) h->last_down = now;
        // R4 waits only behind 70% (D15) or 40 (D1), §8.5: behind 85% or effects alone it acts at once, as today
        int lower = nvn_heat_on(h, HEAT_R2) || nvn_heat_on(h, HEAT_R3);
        if (!nvn_heat_on(h, HEAT_R4)) {
            uint64_t delay = nvn_heat_on(h, HEAT_R3) ? c->s2_r4_40 : c->s2_r4;
            // critical, nothing it waits behind, or frames late at the rung it waits behind (40, else 70%: not holding there), judged on frames at that rung once it has been
            // on HEAT_LATE_ON (the window's frames before it ran at another rung, and the sample that pushed it had none at it). Timed from that rung, not from the 70% or
            // effects this jump pushes over it: the caller's share is of the frames before this sample's changes, which ran at that rung (CPU-bound frames late at 40 are
            // not helped by the GPU levers; GPU-bound ones late at 70% already asked for 30 under D15 (a))
            uint64_t below_at = nvn_heat_on(h, HEAT_R3) ? h->on_at[HEAT_R3] : h->on_at[HEAT_R2];
            int now4 = th >= 3 || !lower || (bad && now - below_at >= HEAT_LATE_ON);
            if (!h->r4_delayed) { h->r4_delayed = 1; h->r4_hot2 = now; }
            if (now4 || now - h->r4_hot2 >= delay) { nvn_heat_push_(h, HEAT_R4, now); h->r4_delayed = 0; }
        }
    } else if (th >= 2) {   // no ladder: the hold at once, as today
        if (!nvn_heat_on(h, HEAT_R4)) nvn_heat_push_(h, HEAT_R4, now);
    } else {
        h->r4_delayed = 0;
        if (th == 1 && h->steps) {
            int top = nvn_heat_top(h);
            if (h->can[HEAT_R1] && !nvn_heat_on(h, HEAT_R1) && top < HEAT_R1 && now - h->since1 >= c->r1_on && (!h->last_down || now - h->last_down >= c->gap)) {
                nvn_heat_push_(h, HEAT_R1, now); h->last_down = now;
            } else if (h->evid_since && now - h->evid_since >= c->evid && (!h->last_down || now - h->last_down >= c->gap) && (!h->can[HEAT_R1] || nvn_heat_on(h, HEAT_R1))) {
                // the next real rung above the top, 85% first where the game can take it: R2 and RE only when GPU-bound (D2; RE's MetalFX, edge smoothing and sharpening
                // are GPU work, as R2), else passed over to R3 (§3.1, §7.2). The 30/60 display choice's RE (display 60 → game 30, §3.3) is a frame-rate step that would help
                // CPU-bound frames: when step 5 offers it, it needs its own flag to be taken here on CPU-bound evidence
                for (int r = HEAT_R2; r <= HEAT_R3; r++) {
                    if (r <= top || nvn_heat_on(h, r)) continue;
                    int ok = r == HEAT_R2 || r == HEAT_RE ? h->can[r] && in->gpu_bound : can_r3;
                    if (!ok) continue;
                    nvn_heat_push_(h, r, now); h->last_down = now; break;
                }
            }
        }
    }
    // Up: the top rung only, one at a time
    if (h->depth && !(h->depth && h->on_at[nvn_heat_top(h)] == now)) {
        int r = nvn_heat_top(h);
        if (r == HEAT_R4) {   // R4: state <= 1 for its wait (the back-off's rule: the calm starts at the first calm sample, a hot one restarts it)
            uint64_t from = h->calm1 > h->on_at[r] ? h->calm1 : 0;
            if (th < 2 && from && now - from >= h->wait[r]) nvn_heat_pop_(h, now);
        } else if (now - h->on_at[r] >= c->min_on) {
            uint64_t from = h->calm0 > h->last_up ? h->calm0 : h->last_up;
            int cooled = th <= 0 && h->calm0 && now - from >= h->wait[r];
            int fits = th == 1 && r != HEAT_R1 && now - h->on_at[r] >= c->evid_exit && h->fit_since && now - h->fit_since >= c->gap && (!h->last_up || now - h->last_up >= c->gap);
            if (cooled || fits) nvn_heat_pop_(h, now);
        }
    }
    // Hot-dim (A6, step 3): Dim 1 at state >= 1 for r1_on, not while charging (D8); Dim 2 at state >= 2; back to Dim 1 after dim2_off at state <= 1, off after Dim 1's wait at state 0
    if (h->dim_ok && h->steps) {
        int was = h->dim;
        if (th >= 2) { h->dim = 2; h->dim_calm2 = 0; }
        else if (h->dim == 2) { if (!h->dim_calm2) h->dim_calm2 = now; else if (now - h->dim_calm2 >= c->dim2_off) h->dim = 1; }
        if (h->dim == 0 && th >= 1 && h->since1 && now - h->since1 >= c->r1_on && !in->charging) {
            h->dim = 1;
            if (h->dim1_off_at && now - h->dim1_off_at < c->rearm) h->dim1_wait = h->dim1_wait * 2 < c->wait_max ? h->dim1_wait * 2 : c->wait_max; else h->dim1_wait = c->wait0;
        }
        else if (h->dim == 1 && (in->charging || (th <= 0 && h->calm0 && now - h->calm0 >= h->dim1_wait))) { h->dim = 0; h->dim1_off_at = now; }
        if (h->dim != was) nvn_heat_ev_(h, HEAT_NR + (h->dim ? h->dim : was), h->dim > was);
        if (!was && h->dim == 2) h->dim1_wait = c->wait0;
    } else if (h->dim) { h->dim = 0; nvn_heat_ev_(h, HEAT_NR + 1, 0); }
}
