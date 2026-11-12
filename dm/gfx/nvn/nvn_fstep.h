// Frame step in whole vsyncs (pure function, shared by Mac / iOS; unit test tests/t_fstep.c). The rewriter's frame-step stubs (patch_nso.py FRAME_STEP: Tears of the Kingdom 1.4.3,
// Breath of the Wild 1.9.0) step the game by the vsyncs (1/60 s) the host hands them each frame, and the host keeps each frame on screen for k vsyncs (hle_nvn.c present_itv).
// At a steady rate the step is the time on screen: even motion, and only steps the games' own interval logic uses (60 / 30 / 20 fps). Real time the game falls behind (a late
// frame, a hitch) is a debt paid back one extra vsync per frame, so over time game time = real time. k follows the frames' cost: three late frames in a row step up to the cost
// (30 fps when 60 does not hold: no 40 fps steps on 120 Hz screens); 30 frames in a row whose cost would fit k − 1 try it, and a trial that fails waits twice as long before
// the next (1 s → 8 s), so a device on the edge does not flap.
// A probe is a trial back to kmin that the cost does not justify: while the caller reports the CPU slowed for reasons other than heat (an iPhone's performance controller
// parks a game that waits out a long hold on the efficiency cores at half the clock, where its cost never fits k − 1 again), the hold-off alone starts one. Its first
// FSTEP_GRACE frames may be late without failing it, the time the controller needs to raise the clock for the shorter deadline; after them it is judged like a trial.
// A probe that holds leaves the hold-off as it is, and the run at kmin it starts must last FSTEP_HOLD_MAX (8 s) before the hold-off returns to 1 s: a shorter one counts as
// a failed probe, so a CPU that really cannot hold kmin is not probed every second.
// A step up after a run at kmin of FSTEP_HOLD_MAX keeps the cost that held there, and a cost at the longer hold of at most FSTEP_SAME times it starts a probe too: the scene
// costs what it did, so the step up came from a hitch (Breath of the Wild on an iPhone: pipeline compiles after a cutscene). The fit trial alone does not bring such a game
// back: an iPhone lowers its GPU clock until the work fills most of the frame, so a GPU-bound game's cost sits near FSTEP_FIT at either hold (BotW: GPU 12.8–15.2 ms at hold
// 2, p50, where hold 1 had held for minutes; the same 4,900 draws took 5.8 ms after a trip to the background and 13.5 ms half a minute later).
// A cap that falls and rises again (a movie, hle_movie.c dm_movie_playing; the iOS thermal cap in hle_nvn.c) keeps what was learned at each kmin: the cost that held it
// (cref) and the GPU reference (nvn_fgpu below); and the frames after the cap rises are a probe with its grace, as the clocks are still set for the longer hold. Before, the
// rise set k to kmin with no grace, so three frames late while the clock rose stepped up again, with cref dropped at the cap change and a GPU reference taken at the 30 fps
// cap: neither the fit trial (a GPU-bound cost near FSTEP_FIT) nor a probe brought kmin back (t_fstep: the movie and thermal cap cases). A cref kept from before the cap
// starts a probe only when the cost at the longer hold is within FSTEP_SAME of it, and a failed probe doubles the hold-off as any other does.
#pragma once
#include <math.h>
#include <stdint.h>

#define FSTEP_MAX 3           // the largest step: both games' own interval logic uses 1–3 (BotW clamps to [2, 3], TOTK picks 2 or 3), so their integer readers never see 4
#define FSTEP_LATE 0.1        // a frame is late when it or its GPU work took this many vsyncs (1.7 ms) more than k: 53 fps is not 60 (start-to-start jitter on time is well below)
#define FSTEP_FIT 0.85        // a frame would fit k − 1 when its cost is at most this share of it
#define FSTEP_RUN 30          // frames in a row that fit k − 1 before a trial, and frames a trial must hold
#define FSTEP_DEBT_MAX 15.0   // debt kept at most (0.25 s): the rest of a long stall (a load) is dropped, not replayed
#define FSTEP_HOLD0 60.0      // vsyncs since the last step up before a trial: 1 s, doubled after each failed trial up to 8 s
#define FSTEP_HOLD_MAX 480.0
#define FSTEP_GRACE 30        // a probe's first frames, whose lateness neither fails it nor counts toward a step up (the controller lowered the clock within 10 frames of a step to 30)
#define FSTEP_SAME 1.1        // the cost at the longer hold against the cost that held kmin: at most this much is the same scene (BotW at hold 2: 1.0–1.07 times its hold-1 GPU time)
// The grace is renewed (nvn_fstep.ramp) while the probe's frames keep getting cheaper: a controller that raises the clock slowly is still raising it. macOS raises the GPU clock
// of a game that misses its deadline at 85–100% GPU occupancy by about 100 MHz a second (Breath of the Wild on an M5 Pro: 338 → 432 MHz over a 33-frame probe, GPU 24.8 → 18.5 ms,
// then the probe failed at 22 ms frames; hold 1 needs about 560 MHz there), where the iPhone's controller settles within the 30 frames. A window of FSTEP_GRACE frames whose
// second half cost at most 1 − FSTEP_RAMP of its first half, and had a late frame (a window on time is judged as a trial), starts another, up to FSTEP_PROBE_MAX frames in all
#define FSTEP_RAMP 0.05       // the fall in cost from one half of a grace window to the next that shows the clock still rising (the per-frame noise of a 25 ms frame is 4%, of 15 frames 1%)
#define FSTEP_PROBE_MAX 180   // grace frames a probe may take in all (3 s at 60 fps): a clock that keeps rising without reaching the hold is not waited for longer
// What a failed probe measured at kmin: the cost of its frames after the grace (pk), against the cost at the longer hold it started from (pfrom). The cost at the longer hold now,
// scaled by pk / pfrom, is the estimate of kmin's cost (nvn_fstep_pest). Breath of the Wild on an iPhone 18 Pro Max: an area whose GPU work took 22–24 ms at hold 2, 1.6–1.7 times
// its hold-1 reference, took as much in each probe back to hold 1 (cost 1.3–1.9), and a probe failed every 2–3 s for as long as the area lasted, each 3 late frames on screen.
// After FSTEP_OVER_N failed probes in a row whose cost at kmin was over FSTEP_OVER times its budget, no probe starts while the estimate stays over it, for at most
// FSTEP_PHOLD_MAX since the last step up (two, not one: a clock slower to come back after a cap fails the first probe and holds the second). An estimate of at most
// FSTEP_FIT of the budget (the scene got light), a stall of FSTEP_DEBT_MAX or more (a load, a trip to the background), a cap change, a step the game fixes itself, or a run
// at kmin that holds forgets the measurement and the hold-offs. Probes that fail within the margin back off exponentially (phold, 1 s doubled up to FSTEP_PHOLD_MAX),
// beside the trials' FSTEP_HOLD_MAX
#define FSTEP_OVER 1.15       // a failed probe's cost at kmin against kmin: above it, clearly over (the probes in the BotW area took 1.3–1.9; 1.12 is within the noise of a clock still rising)
#define FSTEP_OVER_N 2        // failed probes in a row clearly over before the estimate holds the probes off
#define FSTEP_PEST_N 8        // frames on time at the longer hold before its cost counts for the estimate
#define FSTEP_PHOLD_MAX 1920.0   // the probes' hold-off at most, and the longest two failed probes over budget hold them off: 32 s
// A movie above 30 pictures a second (nvn_fstep.pin, set by the caller: hle_nvn.c while hle_movie.c dm_movie_fps is over 30, Ocarina of Time's 60 fps nn::codec movies) holds kmin
// while it plays: no step up, trial or probe, and the debt of late frames is paid back as ever. Its player takes one picture a frame and the host hands out the picture the
// movie's clock is at (hle_codec_video.c CV_PACE), so the movie keeps its speed at any hold; kmin is for smoothness. Ocarina of Time's opening on an iPhone 18 Pro Max cost about
// 16.5 ms of GPU a frame, right at the 60 fps budget: at thermal state 1 the frame step stepped to hold 2 and its probes back to 1 kept failing. The cap still decides kmin (a 30 fps
// target, the thermal cap). The movie's start and end forget what failed probes measured and both hold-offs, as a cap change does: another scene
// The screen's verdicts lag the frames (hle_nvn.c judges the frame FSTEP_UP_LAG presents back, with present snapshots): for that many frames after a step up, a frame the screen
// calls late whose own cost fits the new hold is one made before the step, and does not count toward another (opening a menu in BotW: six frames of 34 ms at a cost of 0.72–0.76
// stepped 1 → 2 → 3 within 3 presents)
#define FSTEP_UP_LAG 8
// The back-off after a held probe's short run (nvn_fstep.backoff, set by the caller: the profile's fps_hold_backoff burst, DM_FPS_HOLD_BACKOFF; Ocarina of Time, X1.0). Ocarina of
// Time on an iPhone 18 Pro Max (X1.0, run B, 90-120 s) had a short burst on the CPU side every 1.3-2.3 s at hold 1: 3 frames late at a cost of 1.12-1.23 with the GPU at 0.81-1.05
// (the late line 1.1), beside 11-21 ms of submit against a usual 5-7. Each probe back to hold 1 held its 60 frames, the next burst ended its run under FSTEP_HOLD_MAX, and the
// failures doubled the waits at hold 2: 31, 61, 121 and 240 frames, 453 of 1,800 at hold 2. With backoff such a run is not kmin's failure when the late frames that ended it had
// their GPU under the late line and asked for one vsync more (a short burst on the CPU side): the hold-offs go back to 1 s, as after a run that lasted; any other early end still
// fails and doubles them, but to FSTEP_BURST_CAP (2 s) at most. Probes that fail in their own trial, fit trials that fail, and the hold-off of failed probes over budget
// (nvn_fstep_pheld, the GPU-bound areas of run A) are as before (t_fstep: the run B and run A replays)
#define FSTEP_BURST_CAP 120.0

typedef struct {
    int k, step;              // vsyncs each frame stays on screen; the step handed to the game for the next frame (k, or k + 1 while paying back)
    int kmin;                 // the last call's kmin (a lower one takes effect at once)
    double debt;              // real time the game is behind, in vsyncs
    int late_run, fit_run, trial;   // late frames in a row; frames in a row whose cost fits k − 1; frames left of a trial at k − 1 (0 = none)
    int probe, grace;         // 1: the trial in progress is a probe; 2: a probe held and its run at kmin has not ended yet; frames left of the probe's grace
    int ramp;                 // set by the caller (kept): 1 = a probe's grace is renewed while its frames keep getting cheaper (FSTEP_RAMP; the host's DM_FSTEP_PROBE_RAMP)
    double pa, pb; int plate, ptotal;   // the current grace window: the cost of its first and second halves (sums), its late frames; grace frames this probe has taken in all
    double hold, since;       // vsyncs a trial waits for after a step up; vsyncs since the last step up
    int per_vsync;            // set by the caller: the ticks a 1/60 s vsync is (0 = 1). At 120 fps the unit is 1/120 s (hle_nvn.c fps_high), and the waits between trials stay the same real time
    double shown_slack;       // vsyncs a frame on time may show longer than k (set by the caller): one refresh on screens whose rate is not a multiple of 60; the cost keeps FSTEP_LATE
    int screen;               // set by the caller before each call, then cleared: 0 = judge lateness by shown and cost; 1 = the screen showed a recent frame on time, 2 = late. With present
                              // snapshots (nvn_mtl.m) the game runs ahead of the screen and a frame that runs long is absorbed, so only what the screen shows counts
    double run, crun, cref;   // vsyncs at kmin in a row; the cost of its frames on time (running mean; not during a probe's trial, whose frames run while the clock rises);
                              // crun when the last run of FSTEP_HOLD_MAX or more ended in a step up or a cap change (0 = none yet)
    double ccur; int ck, cn;  // the cost of the frames on time at the longer hold ck (running mean) and their count
    int ckmin;                // the kmin run, crun and cref belong to
    double cref_at[FSTEP_MAX + 1];   // cref of each kmin, kept while another kmin is in force
    double pk, pfrom, psum; int pn, pover;   // a failed probe's cost at kmin and the cost at the longer hold it started from (0 = none); the cost and count of the probe in
                              // progress's frames after its grace; failed probes in a row whose cost at kmin was over FSTEP_OVER of it
    double phold;             // vsyncs a probe waits for after a step up (at least hold): FSTEP_HOLD0, doubled after each failed probe up to FSTEP_PHOLD_MAX
    int upf;                  // frames left after a step up whose late screen verdicts are about frames before it (FSTEP_UP_LAG)
    int pin, pinned;          // set by the caller (kept): 1 = a movie above 30 fps plays, hold kmin; the last call's pin
    int backoff;              // set by the caller (kept): 1 = a held probe's run at kmin that a short burst on the CPU side ended is no failure, other early ends wait FSTEP_BURST_CAP at most
    double gpu, lgpu;         // set by the caller before each call: the frame's GPU time in vsyncs (0 = none finished yet); the most of it over the late frames in a row
    uint64_t late, paid, ups, downs, failed, probes, bursts; double dropped;   // statistics for the log (bursts: runs at kmin ended by a short burst on the CPU side, with backoff)
} nvn_fstep;

// Whether the cost at the longer hold is the cost that held kmin (a probe without a slowed report)
static inline int nvn_fstep_same(const nvn_fstep *s) { return s->cref > 0 && s->cn >= FSTEP_RUN && s->ccur <= FSTEP_SAME * s->cref; }
// kmin's cost estimated from the last failed probe and the cost at the longer hold now (0 = no estimate: no failed probe measured, or too few frames at the longer hold)
static inline double nvn_fstep_pest(const nvn_fstep *s) { return s->pk > 0 && s->pfrom > 0 && s->cn >= FSTEP_PEST_N ? s->pk * s->ccur / s->pfrom : 0; }
// Whether two failed probes in a row measured kmin clearly over and the cost at the longer hold has not fallen since (no estimate yet counts as not fallen)
static inline int nvn_fstep_pheld(const nvn_fstep *s, int kmin) { double e = nvn_fstep_pest(s); return s->pover >= FSTEP_OVER_N && !(e > 0 && e <= FSTEP_OVER * kmin); }
// Whether a probe may start: not while held off as above, for at most FSTEP_PHOLD_MAX since the last step up. The cost at the longer hold alone does not tell a scene kmin
// cannot hold from one it can, as the GPU clock follows the hold: BotW's heavy area took 22–24 ms at hold 2, and a scene that held hold 1 at 14.4 ms took about 25 there.
// Held off for good, a game that left the heavy area for such a scene stayed at 30 fps until a load (t_fstep: the heavy stretch, then the GPU-slowed scene)
static inline int nvn_fstep_probe_ok(const nvn_fstep *s, int kmin) { return !nvn_fstep_pheld(s, kmin) || s->since >= FSTEP_PHOLD_MAX * (s->per_vsync ? s->per_vsync : 1); }
// Forget what failed probes measured, and their hold-offs (the scene changed). pfrom stays: each probe sets its own (a cap's rise starts one and forgets in the same frame)
static inline void nvn_fstep_pforget(nvn_fstep *s, double hold0) { s->pk = 0; s->pover = 0; s->phold = hold0; }
static inline void nvn_fstep_pstart(nvn_fstep *s, double cost) { s->pfrom = s->cn ? s->ccur : cost; s->psum = 0; s->pn = 0; }   // what the probe starts from

// Once per frame. shown: real time since the previous frame's start, in vsyncs; cost: the frame's work, max(CPU, GPU), in vsyncs (a GPU that cannot keep up makes frames late too); kmin: 1 at a 60 fps cap, 2 at 30;
// kmax: the longest hold (FSTEP_MAX; 2 at a 30 fps cap, where the display link runs at 30 Hz and holds only even counts); fixed: a step the game has set itself (BotW's
// VFR override; 0 = none), which the host then holds as it is; slow: the CPU runs below its speed for reasons other than heat, so a cost above k − 1 is no evidence
// against kmin (probes). Returns the step for the next frame; s->k is how long that frame stays on screen
static inline int nvn_fstep_next(nvn_fstep *s, double shown, double cost, int kmin, int kmax, int fixed, int slow) {
    const double hold0 = FSTEP_HOLD0 * (s->per_vsync ? s->per_vsync : 1), hold_max = FSTEP_HOLD_MAX * (s->per_vsync ? s->per_vsync : 1);
    if (kmin < 1) kmin = 1;
    if (kmax > FSTEP_MAX) kmax = FSTEP_MAX;
    if (kmax < kmin) kmax = kmin;
    if (!s->hold) s->hold = hold0;
    if (!s->phold) s->phold = hold0;
    if (fixed > 0) {   // the game's own step: speed is right by construction, nothing to pay back
        s->k = s->step = fixed < FSTEP_MAX ? fixed : FSTEP_MAX;
        s->debt = 0; s->late_run = s->fit_run = s->trial = s->probe = s->grace = 0; s->run = 0;
        s->kmin = FSTEP_MAX + 1;   // when it ends, k starts again from kmin
        nvn_fstep_pforget(s, hold0);   // a cutscene: another scene, as a cap change is
        return s->step;
    }
    if (!s->k) { s->k = s->step = s->kmin = kmin; return s->step; }   // first frame: nothing measured yet
    int held = s->k;   // the frame that just ended stayed on screen this long
    s->debt += shown - s->step;
    if (s->debt > FSTEP_DEBT_MAX) { s->dropped += s->debt - FSTEP_DEBT_MAX; s->debt = FSTEP_DEBT_MAX; }
    if (s->debt < -1) s->debt = -1;   // ahead (a frame shorter than its step): nothing slows the game down, so at most one vsync is remembered
    s->since += shown;
    if (shown >= FSTEP_DEBT_MAX * (s->per_vsync ? s->per_vsync : 1)) nvn_fstep_pforget(s, hold0);   // a load or a trip to the background: another scene
    if (s->pin != s->pinned) {   // a fast movie starts or ends: another scene, and no trial or probe carries over it
        s->pinned = s->pin; s->trial = s->probe = s->grace = 0; s->late_run = s->fit_run = 0; s->upf = 0; s->run = 0; s->cn = 0;
        s->hold = hold0; nvn_fstep_pforget(s, hold0);
    }
    if (s->pinned) {   // while it plays: kmin, the cap's fastest hold, whatever the frames cost; only the debt is paid back
        s->k = s->kmin = kmin; s->screen = 0;
        s->step = s->k + (s->debt >= 1 && s->k < FSTEP_MAX);
        s->paid += s->step > s->k;
        return s->step;
    }
    int cap_probe = kmin < s->kmin && s->kmin <= FSTEP_MAX && s->k > kmin;
    if (cap_probe) {   // the cap rose: a probe at once, whose grace covers the clocks still set for the longer hold
        s->k = kmin; s->probes++; s->trial = FSTEP_RUN; s->probe = 1; s->grace = FSTEP_GRACE; s->fit_run = s->late_run = 0; s->pa = s->pb = 0; s->plate = s->ptotal = 0;
        nvn_fstep_pstart(s, cost);
    } else if (kmin < s->kmin || s->k < kmin) s->k = kmin;   // the game's own step ended, or the cap fell
    if (s->k > kmax) s->k = kmax;
    s->kmin = kmin;
    int scr = s->screen; s->screen = 0;
    int late = scr ? scr == 2 : shown > held + FSTEP_LATE + s->shown_slack || cost > held + FSTEP_LATE, grace = s->grace > 0;
    if (grace && !cap_probe) {   // the completed frame at the old cap does not consume the new hold's grace
        if (s->grace > FSTEP_GRACE / 2) s->pa += cost; else s->pb += cost;
        s->plate += late; s->ptotal++;
        if (!--s->grace && s->ramp && s->plate && s->ptotal + FSTEP_GRACE <= FSTEP_PROBE_MAX && s->pb <= (1 - FSTEP_RAMP) * s->pa) { s->grace = FSTEP_GRACE; s->pa = s->pb = 0; s->plate = 0; }   // still getting cheaper: another window
    }
    int lagged = s->upf > 0 && scr == 2 && cost <= held + FSTEP_LATE;   // the screen's verdict on a frame before the last step up
    if (s->upf > 0) s->upf--;
    if (late) { s->late++; s->late_run = grace || lagged ? 0 : s->late_run + 1; s->fit_run = 0; s->lgpu = s->late_run > 1 && s->lgpu > s->gpu ? s->lgpu : s->gpu; } else s->late_run = 0;
    if (s->probe == 1 && !grace && !cap_probe && held <= kmin) { s->psum += cost; s->pn++; }   // the probe's frames after its grace: kmin's cost
    // The cost of the frames on time (a hitch is not what the scene costs): at kmin, and at the longer hold
    if (kmin != s->ckmin) {   // another cap: its run starts over, and what held it before comes back
        if (s->ckmin >= 1 && s->ckmin <= FSTEP_MAX) {
            // A cap can end a sustained run before any hitch saved its cost. Short runs keep the earlier proven reference.
            if (s->run >= hold_max && s->crun > 0) s->cref = s->crun;
            s->cref_at[s->ckmin] = s->cref;
        }
        s->ckmin = kmin; s->run = s->crun = 0; s->cref = kmin <= FSTEP_MAX ? s->cref_at[kmin] : 0;
        nvn_fstep_pforget(s, hold0);
    }
    // A frame the screen showed on time while its cost did not fit (absorbed by present snapshots) is not what the hold costs: the probes would take it for the scene that held kmin
    int fits = !scr || cost <= held;
    if (held <= kmin) { s->run += shown; s->cn = 0; if (!late && fits && s->probe != 1) s->crun = s->crun > 0 ? s->crun + (cost - s->crun) / 32 : cost; }
    else {
        s->run = 0;
        if (held != s->ck) { s->ck = held; s->cn = 0; }
        if (!late && fits) { s->ccur = s->cn ? s->ccur + (cost - s->ccur) / 8 : cost; s->cn++; }
    }
    if (s->late_run >= 3 && s->k < kmax) {   // step up to the cost, at least one vsync
        int want = (int)ceil(cost - 0.05);
        if (want < s->k + 1) want = s->k + 1;
        if (want > kmax) want = kmax;
        // backoff: a held probe's run at kmin ended early by three frames whose GPU fitted and that ask for one vsync more is a short burst on the CPU side, not kmin's failure
        int burst = s->backoff && s->probe == 2 && s->since < hold_max && s->lgpu > 0 && s->lgpu <= held + FSTEP_LATE && want <= held + 1;
        if (burst) { s->bursts++; s->hold = hold0; nvn_fstep_pforget(s, hold0); }
        else if (s->trial || (s->probe == 2 && s->since < hold_max)) {
            s->failed++; s->trial = 0; s->hold = s->hold * 2 < hold_max ? s->hold * 2 : hold_max;
            if (s->probe) {   // a failed probe: what it measured at kmin, and the probes' own hold-off
                s->phold = s->phold * 2 < FSTEP_PHOLD_MAX * (s->per_vsync ? s->per_vsync : 1) ? s->phold * 2 : FSTEP_PHOLD_MAX * (s->per_vsync ? s->per_vsync : 1);
                if (s->probe == 1) { s->pk = s->pn ? s->psum / s->pn : cost; s->pover = s->pk > FSTEP_OVER * kmin ? s->pover + 1 : 0; }
                else s->pover = 0;   // its run at kmin held for a while: kmin fits, at times
            }
            if (s->backoff && s->probe == 2) {   // backoff: a run at kmin after a held probe waits FSTEP_BURST_CAP at most, however often it ended early
                const double cap = FSTEP_BURST_CAP * (s->per_vsync ? s->per_vsync : 1);
                if (s->hold > cap) s->hold = cap;
                if (s->phold > cap) s->phold = cap;
            }
        }
        else if (s->probe == 2) { s->hold = hold0; nvn_fstep_pforget(s, hold0); }   // the probe's run at kmin lasted
        if (held == kmin && s->run >= hold_max) s->cref = s->crun;   // kmin held 8 s at this cost
        s->k = want; s->ups++; s->late_run = s->fit_run = 0; s->since = 0; s->probe = 0; s->upf = FSTEP_UP_LAG;
    } else if (s->trial && !grace && !--s->trial) {   // the trial held (a probe's run at kmin is judged at the next step up)
        if (s->probe) { s->probe = 2; s->since = 0; } else { s->hold = hold0; if (s->k <= kmin) nvn_fstep_pforget(s, hold0); }
    }
    double pe = nvn_fstep_pest(s);
    if (pe > 0 && pe <= FSTEP_FIT * kmin) { nvn_fstep_pforget(s, hold0); s->hold = hold0; }   // the longer hold's cost fell well under what kmin needs: the scene got light
    if (!late) s->fit_run = s->k > kmin && cost <= FSTEP_FIT * (s->k - 1) ? s->fit_run + 1 : 0;
    if (s->fit_run >= FSTEP_RUN && s->since >= s->hold && !s->trial) { s->k--; s->downs++; s->trial = FSTEP_RUN; s->fit_run = 0; }
    else if ((slow || nvn_fstep_same(s)) && s->k > kmin && s->since >= s->hold && s->since >= s->phold && !s->trial && nvn_fstep_probe_ok(s, kmin)) {   // probe: straight to kmin, so the controller sees the whole deadline
        s->k = kmin; s->downs++; s->probes++; s->trial = FSTEP_RUN; s->probe = 1; s->grace = FSTEP_GRACE; s->fit_run = s->late_run = 0; s->pa = s->pb = 0; s->plate = s->ptotal = 0;
        nvn_fstep_pstart(s, cost);
    }
    s->step = s->k + (s->debt >= 1 && s->k < FSTEP_MAX);
    s->paid += s->step > s->k;
    return s->step;
}

// The GPU clock follows the hold too: Breath of the Wild on an iPhone went from 14.4 to about 25 ms of GPU time a frame at hold 2 with the same 4,900 draws, the CPU still on its
// performance cores, so its cost never fitted hold 1 again. The GPU counts as slowed (another reason for nvn_fstep_next's slow) when its time at a hold above kmin is at least
// FSTEP_GPU_SLOW times its time at kmin and it alone does not fit k − 1 (a GPU at 3 ms of 17, 6 times its time on a loading screen, is not what holds a frame back).
// The reference is not updated during a probe's trial (its frames run while the clock is still rising), so a failed probe leaves it as it was. It is kept for each kmin: one
// learned at a 30 fps cap is the GPU time at the clock that cap left (lowered for 30 fps, and under the thermal cap for the heat), and taken as hold 1's after the cap rose it
// made the same work at hold 2 look not slowed
#define FSTEP_GPU_SLOW 1.3    // GPU time at the longer hold against its time at kmin
#define FSTEP_GPU_N 30        // frames at the longer hold before the comparison counts
typedef struct { double ref, cur; int n, k; double ref_at[FSTEP_MAX + 1]; } nvn_fgpu;   // GPU time at kmin (running mean; of every kmin in ref_at); at the current hold k and its frame count
static inline int nvn_fgpu_slow(const nvn_fgpu *g) { return g->n >= FSTEP_GPU_N && g->ref > 0 && g->cur >= FSTEP_GPU_SLOW * g->ref && g->cur > FSTEP_FIT * (g->k - 1); }
// Once per frame, with the frame's GPU time (vsyncs; 0 = none finished yet) and the hold and probe state (nvn_fstep.probe) it ran under
static inline int nvn_fstep_gpu_slowed(nvn_fgpu *g, double gpu, int k, int kmin, int probe) {
    if (kmin < 1 || kmin > FSTEP_MAX) return 0;   // no reference slot for it (hle_nvn.c passes 1 or 2)
    g->ref = g->ref_at[kmin];
    if (gpu <= 0) return nvn_fgpu_slow(g);
    if (k <= kmin) { if (probe != 1) g->ref = g->ref_at[kmin] = g->ref > 0 ? g->ref + (gpu - g->ref) / 32 : gpu; g->n = 0; g->k = k; return 0; }
    if (k != g->k) { g->k = k; g->n = 0; }
    g->cur = g->n ? g->cur + (gpu - g->cur) / 8 : gpu; g->n++;
    return nvn_fgpu_slow(g);
}

// The long-frame log (hle_nvn.c, the [longframe] lines): a frame is long when the whole frame takes over 20 ms and 1.4 times the running mean of recent frames (ef), or its GPU work
// over 16.7 ms and 1.3 times theirs (eg), and either is longer than the hold the frame was made under asked for. held is that hold in ms (its vsyncs times 1/60 s, or ticks of
// 1/120 s at 120 fps), 0 at a hold of one: the mean alone judges those. The mean takes a sixteenth of each frame, so after a step up from hold 1 to 2 it needs 8–9 frames before
// 33.3 ms is under 1.4 times it, and each of those frames, as long as the step asked, read as a long frame of the game's own: 412 of the 486 that scripts/devlog.py put on the
// game's side in a 9.6-minute run of Ocarina of Time at 60 fps on an iPhone 18 Pro Max, whose hold went from 1 to 2 or 3 and back 86 times. A frame now has to run past its
// hold by more than its pacing jitter (FSTEP_LF_SLACK: frames at hold 2 took 31–36 ms there) and its GPU work past the hold itself. Every frame still feeds the means
#define FSTEP_LF_SLACK 1.25
typedef struct { double ef, eg; } nvn_lfmean;   // running means of the whole frame and its GPU time (ms); hle_nvn.c starts them at 16.7 and 8
static inline int nvn_lf_long(nvn_lfmean *m, double fr, double gpu, double held) {
    int lf = fr > 20.0 && fr > 1.4 * m->ef && fr > FSTEP_LF_SLACK * held, lg = gpu > 16.7 && gpu > 1.3 * m->eg && gpu > held;
    m->ef += ((fr < 3 * m->ef ? fr : 3 * m->ef) - m->ef) / 16; m->eg += ((gpu < 3 * m->eg ? gpu : 3 * m->eg) - m->eg) / 16;
    return lf || lg;
}
