// A game's own frame-rate controller judged with the host's clocks (pure function, shared by Mac / iOS; unit test tests/t_fctl.c; the gate's callback is dm/host/hle_fctl.c, the gate
// itself the game's patches.py OBS row). Donkey Kong Bananza (v458752) picks its own present interval: its controller (main+0x204a18) measures each frame from its start to the
// later of its submission and the GPU's end, and wants interval n when that measure plus its margin (-0.2) is n − 1 vsyncs or more: 1 → 2 after three frames in a row over 1.2 vsyncs
// (20 ms), and back after six frames under it at the longer interval (a countdown that moves only on such frames), then one more. The game steps its time by the interval it set.
// On the Switch 2 the GPU clock does not follow the interval; on an iPhone it does. At interval 2 the phone lowers its GPU (and CPU) clocks until the work fills most of the 33 ms:
// GPU 13.6 → 17.7 ms a frame, the host's GPU clock probe 2.4 → 3.2 times its best (25 ms with the game's own upscaler), thermal state 0. The measure then stays over 1.2 vsyncs and
// the game held 30 fps until its pause menu (about 1 ms of GPU a frame) let the countdown run; or it came back at the lowered clock and stepped up three frames later, 60 ↔ 30
// every few frames (39-49 fps windows). The frame step solved the same loop for Breath of the Wild (nvn_fstep.h), but there the host hands the game its step; here the game's own
// step must stay the interval it chose, so the host only decides when the controller comes back, through the measure it hands the controller each frame:
//  - at interval 2 or more: at least the band of its own interval (its countdown does not move) until a probe starts: FSTEP_HOLD0 vsyncs (1 s) after the step up, doubled after
//    each failed probe up to FSTEP_PHOLD_MAX (32 s); or at once when FCTL_LIGHT_N frames in a row measured under FCTL_LIGHT vsyncs at the lowered clock (a light scene: a menu, as
//    the pause menu did) and, after a failed timed probe, at most FSTEP_FIT of what the scene measured when that probe started. may_probe (the caller's: thermal state nominal or fair,
//    Low Power Mode off) allows the timed probes; a light scene probes whatever the heat, as the game's own rule would come back there;
//  - during a probe: the band of interval 1, so the controller's own countdown brings it down (7 frames a step); FCTL_PROBE_MAX frames at most, as a listener of the controller
//    may hold it (then the probe is dropped and the wait starts again);
//  - for the FSTEP_GRACE frames after a probe brought interval 1: at most the band of interval 1, the time the phone needs to raise its clocks for the shorter deadline (the
//    frame step's grace). Frames late in the grace run the game slow, as any late frame at an interval does on the Switch: the hold-offs keep failed probes rare;
//  - otherwise the game's own measure, so frames that do not fit step it up by its own rule. A step up before FSTEP_HOLD_MAX (8 s) at interval 1 after a probe is a failed probe.
// A run of FSTEP_HOLD_MAX vsyncs at interval 1, or a frame of FSTEP_DEBT_MAX vsyncs or more (a load, a stay in the background), forgets the failures and their hold-off. The game's
// own steps up are never held back, and an interval the game fixes itself (its lowest interval above 1: a cutscene's 3) is left alone.
// One exception, only with DM_CLOCK_RESCUE_S (the caller sets nvn_fctl.pin while a GPU clock rescue is under way, hle_fctl.c dm_fctl_pin): at interval 1 every frame is handed
// at most the band of interval 1, as in the grace, so the game's steps up to 2 are blocked for the rescue's hold; the phone raised its GPU clock only after about 5 s of unbroken
// 60 (NX18-X2.0 gpu-clock-collapse.md), and in 3 of 7 rescues the game stepped back to 2 within the 3 s. pin_steps counts the steps it blocked (FCTL_UP_N frames in a row the
// controller would have stepped up on), pinned the frames it handed interval 1's band. The pin's frames at interval 1 count toward FSTEP_HOLD_MAX like any others.
// Two rules on the timed probes, with DM_FPS_CTL_PROBE (on by default; hle_fctl.c sets nvn_fctl.gate, 0 = off, the rules above alone). Donkey Kong Bananza's long run
// (NX18-X2.0 bananza-alldata-analysis.md, ranked fix 5): with the CPU capped, frames of about 19 ms at 60 fps, the timed probes failed again and again, each running the
// game at 60 with late frames until its own rule stepped it up, and frames of 18-20 ms are late at 60 but under the controller's own step at 1.2 vsyncs (20 ms):
//  - the gate: once an ordinary timed probe has failed in this scene (nvn_fctl.pfail set: no load, no 8 s at interval 1 since), the next timed probe waits while the mean of the
//    frames at the longer interval (8-frame running mean, at least 8 frames) is over gate vsyncs (FCTL_GATE: 1.25, 20.8 ms): the hold-off ends as before, the probe starts at the
//    first frame after it whose mean is at or under the gate. Not before a failure: at the first try the mean at 30 reads the lowered clocks (22-29 ms where 60 fits at the
//    full clock, the case this controller was written for), so only a failed try says the scene has no headroom. A light scene, a GPU clock rescue or kick (nvn_fctl.rescue,
//    hle_fctl.c dm_fctl_rescue) probe as before;
//  - the early end: in an ordinary timed probe after its grace (not a light one, not a rescue's, not under the pin), FCTL_CUT_N of the last FCTL_CUT_W frames whose own measure is
//    over 1 + FSTEP_LATE vsyncs (18.3 ms: late at 60) end it: every frame is handed interval 2's band until the controller steps up (FCTL_UP_N frames), a failed probe as any
//    other (its hold-off doubled, its start's measure kept for the gate and the light rule). cuts counts them, gated the hold-offs the gate kept waiting
#pragma once
#include "nvn_fstep.h"

#define FCTL_LIGHT 1.0      // a light frame at the longer interval: measured under one vsync at the lowered clock, so it fits interval 1 at any clock the phone raises it to
#define FCTL_LIGHT_N 6      // light frames in a row that start a probe at once: the controller's own count to come back
#define FCTL_PROBE_MAX 30   // frames a probe may take to bring interval 1 (the controller's countdown is 7 frames a step: 14 from interval 3)
#define FCTL_UP_N 3         // frames in a row at or over the next band the controller steps up on (Bananza: three over 1.2 vsyncs)
#define FCTL_GATE 1.25      // DM_FPS_CTL_PROBE's gate by default: the mean at the longer interval (vsyncs, 20.8 ms) over which a timed probe after a failure waits
#define FCTL_CUT_N 4        // late frames (over 1 + FSTEP_LATE by the game's own measure) among the last FCTL_CUT_W after a probe's grace that end it early
#define FCTL_CUT_W 8

enum { FCTL_EV_NONE, FCTL_EV_PROBE, FCTL_EV_DOWN, FCTL_EV_HELD, FCTL_EV_FAILED, FCTL_EV_ABORTED, FCTL_EV_UP, FCTL_EV_GATED, FCTL_EV_CUT };   // what a call did (nvn_fctl.ev), for the log;
// a probe ends HELD, FAILED, ABORTED or UP (nvn_fctl_obs); GATED (the gate kept a timed probe waiting) and CUT (the early end began) are events within a wait or a probe

typedef struct {
    int itv;                  // the controller's interval at the last call (0 = none yet)
    double hold, since, run;  // vsyncs a probe waits for after a step up; vsyncs of real time at the longer interval since the step up; at interval 1 since it came down
    int probe, grace, light;  // frames the probe in progress has run (0 = none); frames left of the grace; light frames in a row at the longer interval
    int probed, plight;       // 1 = the last return to interval 1 was a probe and its run has not reached FSTEP_HOLD_MAX; the probe in progress began on a light scene
    double mean, pmean, pfail; int n;   // the measure at the longer interval (running mean of 8 frames) and its count; at the probe's start; at the last failed probe's start (0 = none)
    int ev;                   // what the last call did (FCTL_EV_*)
    uint64_t probes, lights, downs, held, failed, aborted, kept, graced;   // statistics for the log: probes (of them on a light scene), probes that brought interval 1, held 8 s,
                              // failed, dropped; frames whose return the host held at the longer interval; grace frames it kept at interval 1
    int pin, pin_run;         // the caller's: 1 while a clock rescue holds interval 1 (DM_CLOCK_RESCUE_S); frames in a row at or over interval 2's band under it
    uint64_t pinned, pin_steps;   // frames the pin handed interval 1's band; steps up to interval 2 it blocked
    double gate; int rescue;      // the caller's: DM_FPS_CTL_PROBE's gate in vsyncs (0: its two rules off); 1 at a call whose probe is a GPU clock rescue's or kick's
    int presc, cut, cbits, gwait; // the probe in progress (or its run at interval 1) is a rescue's; frames the early end has handed interval 2's band (0: none); the late frames
                                  // after the grace, a bit a frame (the last FCTL_CUT_W); the gate keeps the hold-off that ended waiting
    uint64_t cuts, gated;         // probes the early end stepped back; hold-offs the gate kept waiting
} nvn_fctl;

// The measure (vsyncs) in the middle of the band the controller takes for interval n: it wants n when measure + margin is in [n − 1, n)
static inline double nvn_fctl_at(int n, double margin) { return n - 0.5 - margin; }

// Once per controller call that judges a frame. itv: the controller's interval now (what its last call chose); imin, imax: its range; margin: its margin; m: its measure of the
// frame, in vsyncs (> 0); shown: real time since the previous call, in vsyncs. Returns the measure the controller is to judge
static inline double nvn_fctl_next(nvn_fctl *s, int itv, int imin, int imax, double margin, double m, double shown, int may_probe) {
    s->ev = FCTL_EV_NONE;
    if (!s->hold) s->hold = FSTEP_HOLD0;
    if (shown >= FSTEP_DEBT_MAX) { s->hold = FSTEP_HOLD0; s->pfail = 0; }   // a load or a stay in the background: another scene
    if (imin != 1 || imax < 2 || itv < imin || itv > imax) {   // the game holds an interval itself (a cutscene's 3): no choice of the controller's to judge
        s->itv = itv; s->probe = s->grace = s->light = s->probed = 0; s->since = s->run = 0; s->n = 0; s->cut = s->cbits = s->gwait = 0;
        return m;
    }
    if (s->itv && itv > s->itv) {   // the controller stepped up at its last call, by its own rule
        s->ev = FCTL_EV_UP;
        if (s->probed) {   // a failed probe; one that began on a light scene (a menu) failed because the scene changed, and what it measured is no limit for the next light one
            s->failed++; s->hold = 2 * s->hold < FSTEP_PHOLD_MAX ? 2 * s->hold : FSTEP_PHOLD_MAX; s->ev = FCTL_EV_FAILED;
            if (!s->plight) s->pfail = s->pmean;
        }
        s->probed = s->probe = s->grace = s->light = 0; s->since = 0; s->n = 0; s->cut = s->cbits = s->gwait = 0;
    } else if (itv == 1 && s->itv > 1) {   // it came down
        s->run = 0;
        if (s->probe) { s->probe = 0; s->grace = FSTEP_GRACE; s->probed = 1; s->downs++; s->ev = FCTL_EV_DOWN; s->cut = s->cbits = 0; }
    }
    s->itv = itv;
    if (itv == 1) {
        s->run += shown;
        if (s->run >= FSTEP_HOLD_MAX && (s->probed || s->hold > FSTEP_HOLD0 || s->pfail)) {   // interval 1 held: what failed is forgotten
            if (s->probed) { s->held++; s->ev = FCTL_EV_HELD; }
            s->probed = 0; s->hold = FSTEP_HOLD0; s->pfail = 0; s->cut = 0;
        }
        if (s->cut) {   // DM_FPS_CTL_PROBE's early end: interval 2's band until the controller steps up (a listener that holds it: given up after FCTL_PROBE_MAX frames)
            if (s->probed && s->cut++ <= FCTL_PROBE_MAX) { s->pin_run = 0; return nvn_fctl_at(2, margin); }
            s->cut = s->cbits = 0; s->probed = 0;
        }
        const int ing = s->grace > 0;
        if (s->grace > 0) {
            s->grace--;
            const double v1 = nvn_fctl_at(1, margin);
            if (m > v1) { s->graced++; s->pin_run = 0; return v1; }
        }
        if (s->gate > 0 && !ing && s->probed && !s->plight && !s->presc && !s->pin) {   // DM_FPS_CTL_PROBE's early end: an ordinary probe past its grace whose frames do not hold 60
            s->cbits = (s->cbits << 1 | (m > 1 + FSTEP_LATE)) & ((1 << FCTL_CUT_W) - 1);
            if (__builtin_popcount((unsigned)s->cbits) >= FCTL_CUT_N) { s->cut = 1; s->cuts++; s->ev = FCTL_EV_CUT; return nvn_fctl_at(2, margin); }
        }
        if (s->pin) {   // a clock rescue's hold (DM_CLOCK_RESCUE_S): no step up to 2 until it ends
            const double v1 = nvn_fctl_at(1, margin);
            if (m + margin >= 1) { if (++s->pin_run >= FCTL_UP_N) { s->pin_steps++; s->pin_run = 0; } } else s->pin_run = 0;
            if (m > v1) { s->pinned++; return v1; }
        } else s->pin_run = 0;
        return m;
    }
    s->pin_run = 0;
    s->since += shown;
    if (s->probe) {   // the controller counts down to its return
        if (++s->probe <= FCTL_PROBE_MAX) return nvn_fctl_at(1, margin);
        s->probe = 0; s->aborted++; s->since = 0; s->ev = FCTL_EV_ABORTED;   // held by the game: wait again
    }
    s->mean = s->n++ ? s->mean + (m - s->mean) / 8 : m;
    s->light = m < FCTL_LIGHT && (!s->pfail || m <= FSTEP_FIT * s->pfail) ? s->light + 1 : 0;
    const int light = s->light >= FCTL_LIGHT_N;
    int timed = may_probe && s->since >= s->hold;
    if (timed && !light && !s->rescue && s->gate > 0 && s->pfail > 0 && s->n >= 8 && s->mean > s->gate) {   // DM_FPS_CTL_PROBE's gate: no headroom at the longer interval
        if (!s->gwait) { s->gwait = 1; s->gated++; s->ev = FCTL_EV_GATED; }
        timed = 0;
    }
    if (light || timed) {
        s->probe = 1; s->plight = light; s->presc = !light && s->rescue; s->probes++; s->lights += light; s->pmean = s->mean; s->light = 0; s->gwait = 0; s->ev = FCTL_EV_PROBE;
        return nvn_fctl_at(1, margin);
    }
    const double vh = nvn_fctl_at(itv, margin);
    if (m >= vh) return m;   // in its own band, or a step up the game's rule takes
    s->kept += m + margin < itv - 1;   // a frame that would have moved the controller's countdown
    return vh;
}

// Two states the same, field by field (the tests' replays with and without the log below; the struct has padding, so not memcmp)
static inline int nvn_fctl_same(const nvn_fctl *a, const nvn_fctl *b) {
    return a->itv == b->itv && a->hold == b->hold && a->since == b->since && a->run == b->run && a->probe == b->probe && a->grace == b->grace && a->light == b->light
        && a->probed == b->probed && a->plight == b->plight && a->mean == b->mean && a->pmean == b->pmean && a->pfail == b->pfail && a->n == b->n && a->ev == b->ev
        && a->probes == b->probes && a->lights == b->lights && a->downs == b->downs && a->held == b->held && a->failed == b->failed && a->aborted == b->aborted
        && a->kept == b->kept && a->graced == b->graced && a->pin == b->pin && a->pin_run == b->pin_run && a->pinned == b->pinned && a->pin_steps == b->pin_steps
        && a->gate == b->gate && a->rescue == b->rescue && a->presc == b->presc && a->cut == b->cut && a->cbits == b->cbits && a->gwait == b->gwait && a->cuts == b->cuts && a->gated == b->gated;
}

// What the log says of the probes and of the time at each interval (hle_fctl.c), so that a later change of the rules above can rest on measured numbers. Logging only:
// nvn_fctl_obs_next runs after nvn_fctl_next on the same frame and reads its state through a const pointer, so nothing here goes back into a decision (t_fctl replays the
// same frames with and without it and compares every measure handed and every state). Measures are the game's own (vsyncs), shown the real time since the last call
typedef struct {
    int light, n, gn, an, late, why;   // began on a light scene; frames it ran (from the call that started it); of them in its grace and after it, at interval 1; late frames at
                                       // interval 1 (shown over 1 + FSTEP_LATE after a frame at interval 1, and under FSTEP_DEBT_MAX: a longer one spans what the gate did not see, a
                                       // load, a stay in the background or frames the controller did not judge, and is at no interval in nvn_fctl_obs_time either); how it ended:
                                       // FCTL_EV_HELD, _FAILED, _ABORTED, or FCTL_EV_UP: cut short by the game (a step up before its return, or an interval the game fixes itself)
    double lmean, lmax, base;          // a light probe's start: its FCTL_LIGHT_N frames' mean and largest measure; the controller's mean just before them (0: none since the step up)
    double gsum, gmax, asum, over;     // the grace frames' measures: sum and largest; the frames' after it: sum; the vsyncs the late frames took over one
} nvn_fctl_pr;
typedef struct {
    nvn_fctl_pr cur, last; int on, ended;   // the probe in progress (on: one is); the last one that ended (ended: at this call)
    double rm[FCTL_LIGHT_N + 1], rmean[FCTL_LIGHT_N + 1]; int ri;   // the last frames nvn_fctl_next took into its mean at the longer interval: their measures and the mean after each
    int gprev, pitv; uint64_t fprev;   // nvn_fctl.grace, the interval and nvn_fctl.failed after the last call
    double t[3]; double flate_v; uint64_t flate;   // vsyncs at interval 1, 2 and 3 or more (nvn_fctl_obs_time); late frames in failed probes and the vsyncs they took over one
} nvn_fctl_obs;

static inline void nvn_fctl_obs_next(nvn_fctl_obs *o, const nvn_fctl *s, double m, double shown) {
    const int itv = s->itv, start = s->ev == FCTL_EV_PROBE;
    // A call that starts a probe while one is in progress ended that one first: the game stepped up on a frame as long as the hold-off or more (a stay in the background), and
    // FCTL_EV_PROBE overwrote the end's event: failed when nvn_fctl_next counted a failure at this call, otherwise cut short
    const int ev = o->on && start ? (s->failed != o->fprev ? FCTL_EV_FAILED : FCTL_EV_UP) : s->ev;
    o->ended = 0;
    if (o->on) {
        nvn_fctl_pr *p = &o->cur;
        const int fixed = ev == FCTL_EV_HELD || ev == FCTL_EV_FAILED || ev == FCTL_EV_ABORTED, end = fixed || start || (!s->probe && !s->probed);
        if (!end || ev == FCTL_EV_HELD) {   // a frame of the probe: the one that held 8 s is its last; after a step up or a drop the frame is the longer interval's
            p->n++;
            if (itv == 1) {
                if (o->gprev > 0 || s->grace > 0) { p->gn++; p->gsum += m; if (m > p->gmax) p->gmax = m; }   // the grace: nvn_fctl_next counted it down at this call
                else { p->an++; p->asum += m; }
                if (o->pitv == 1 && shown > 1 + FSTEP_LATE && shown < FSTEP_DEBT_MAX) { p->late++; p->over += shown - 1; }
            }
        }
        if (end) {
            p->why = fixed ? ev : FCTL_EV_UP;
            if (ev == FCTL_EV_FAILED) { o->flate += (uint64_t)p->late; o->flate_v += p->over; }
            o->last = *p; o->on = 0; o->ended = 1;
        }
    }
    if (itv >= 2 && s->n > 0 && (!s->probe || start)) {   // nvn_fctl_next took this frame into its mean and its light count
        o->ri = (o->ri + 1) % (FCTL_LIGHT_N + 1); o->rm[o->ri] = m; o->rmean[o->ri] = s->mean;
    }
    if (start) {
        nvn_fctl_pr *p = &o->cur;
        *p = (nvn_fctl_pr){.light = s->plight, .n = 1};
        if (s->plight) {   // its light frames are the last FCTL_LIGHT_N the mean took (the count starts again at each probe and step up)
            for (int i = 0; i < FCTL_LIGHT_N; i++) { const double x = o->rm[(o->ri + FCTL_LIGHT_N + 1 - i) % (FCTL_LIGHT_N + 1)]; p->lmean += x / FCTL_LIGHT_N; if (x > p->lmax) p->lmax = x; }
            p->base = s->n > FCTL_LIGHT_N ? o->rmean[(o->ri + 1) % (FCTL_LIGHT_N + 1)] : 0;
        }
        o->on = 1;
    }
    o->gprev = s->grace; o->pitv = itv; o->fprev = s->failed;
}
// The time at each interval, for every frame the controller judges (with the host's measure or the game's own: DM_FPS_CTL=game). A frame across a load or a stay in the
// background (FSTEP_DEBT_MAX vsyncs or more) is at neither
static inline void nvn_fctl_obs_time(nvn_fctl_obs *o, int itv, double shown) {
    if (itv >= 1 && shown < FSTEP_DEBT_MAX) o->t[itv < 3 ? itv - 1 : 2] += shown;
}
