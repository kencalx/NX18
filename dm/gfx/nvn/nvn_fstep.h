// Frame step in whole vsyncs (pure function, shared by Mac / iOS; unit test tests/t_fstep.c). The rewriter's frame-step stubs (patch_nso.py FRAME_STEP: Tears of the Kingdom 1.4.3,
// Breath of the Wild 1.9.0) step the game by the vsyncs (1/60 s) the host hands them each frame, and the host keeps each frame on screen for k vsyncs (hle_nvn.c present_itv).
// At a steady rate the step is the time on screen: even motion, and only steps the games' own interval logic uses (60 / 30 / 20 fps). Real time the game falls behind (a late
// frame, a hitch) is a debt paid back one extra vsync per frame, so over time game time = real time. k follows the frames' cost: three late frames in a row step up to the cost
// (30 fps when 60 does not hold: no 40 fps steps on 120 Hz screens) when the frames at k also fall short of it on average (FSTEP_LATE over the last FSTEP_RUN frames); 30 frames
// in a row on time whose cost, or the mean cost of the hold's frames, would fit k − 1 try it, and a trial that fails waits twice as long before the next (1 s → 8 s), so a device
// on the edge does not flap.
// The average (upstream NXNative 1e3fd031, issue #1823): a frame late by FSTEP_LATE is the rate of a hold that does not hold (53 fps is not 60), but three such frames in a row
// among frames on time are not. Frames whose cost scatters around k (Mario Kart World on an M4 Max: 20–30% of them 1–5 ms late, 57.5–61 fps and game time 0.99–1.02 of real time
// with no holds) met three in a row about once a second and spent half the time at 30 or 20; a short hitch (pipeline compiles) stepped to 30 the same way. The late frames are
// paid back by the step, so only a rate that falls short of k is worth a longer hold. Where the step cannot pay them back (120 fps, where the game steps by its target: a late
// frame is slow motion, no_payback) three late frames still raise the hold. The step goes to the cheapest of the three late frames' cost: a hitch as the third no longer meant 20 fps.
// The average leaves out the window's longest frame (upstream edc07d34b): a lone stall (43-68 ms of texture streaming or a pipeline built in play) among near-misses filled two
// thirds of the limit and stepped to 30 for a second. Two stalls in 30 frames still count one.
// The fit by the mean (upstream 5b0f1372, PR #2367): a frame fits k − 1 when its own cost or the running mean of the hold's frames on time (ccur) does. Single frames over the fit
// among frames under it kept the trial from ever starting after a load had stepped up (Ocarina of Time on a Mac: 20 fps for 24.5 s after an area load). On the iPhone a trial
// the mean started (a frame among the FSTEP_RUN that started it fitted only through ccur, so X1.0's per-frame rule would not have started it on that frame: nvn_fstep.tbym)
// is judged by its run as on the Mac (tpend, below): held and reset to the 1 s wait, the next step up was no failed trial, and Ocarina of Time's run B (a scene at hold 2
// of 0.80 with a frame of 0.90 in every 20, a short burst at hold 1 every 1.3-2.3 s) went back and forth between 60 and 30 every 2-3 s, where the probes it took the place
// of doubled their waits (stays at hold 2 of 31, 61, 121 and 240 frames in the log). A trial X1.0's rule would have started on the same frame, each of its last FSTEP_RUN
// frames within the fit on its own cost, keeps X1.0's iPhone rule, also when a frame earlier in the run (60-240 frames long once the wait has doubled) fitted only through
// ccur: marked by such a frame, those trials failed at the next step up and kept the wait at 8 s (a scene at hold 2 of 0.70 with one frame of 0.90 early in each stay and a
// burst at hold 1 every 200 frames: 71% of the time at hold 2, now 32%, X1.0's header 28%).
// A game takes steps up to its stub's largest (smax, upstream 1e3fd031; Mario Kart World's interval logic stops at 2): k and the paid-back step stay within it, or the frames
// held longer than the game steps play in slow motion and the debt counted as paid is lost. On the Mac (FSTEP_FIT_WIDE) a trial that held is judged by its run as a probe is: a step up before the run lasts
// FSTEP_HOLD_MAX counts as a failed trial (with the wider fit an edge scene that steps up again within seconds went back and forth every few seconds, its trial wait 1 s each time).
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
#include <string.h>
#include <TargetConditionals.h>

#define FSTEP_MAX 3           // the largest step: both games' own interval logic uses 1–3 (BotW clamps to [2, 3], TOTK picks 2 or 3), so their integer readers never see 4
#define FSTEP_LATE 0.1        // a frame is late when it or its GPU work took this many vsyncs (1.7 ms) more than k: 53 fps is not 60 (start-to-start jitter on time is well below)
#define FSTEP_SHORT_MAX 2.0   // a frame counts at most this many vsyncs past its hold toward the average (a load's stall is one long frame, not a rate)
// The fit, from upstream NXNative 293b1d4db (issue #2400) on the Mac only: hold 1 keeps frames of up to about 1.03 vsyncs (three late in a row step up), so a fit of 0.85 left
// 0.85-1.0 between the two, and where the GPU clock barely follows the hold (Ocarina of Time on a base M5 and an M4 Pro, 15 ms at either hold) a scene there stayed at 30 for good
// after anything stepped it up. FSTEP_FIT_WIDE (the Mac) takes 0.95, judges a trial that held by its run (nvn_fstep.tpend) and calls the GPU slowed only when it does not fit kmin
// (nvn_fgpu_slow). The iPhone keeps 0.85 and the rest as it was: it lowers its GPU clock until the work fills most of the frame, so a GPU-bound cost sits near the fit at either
// hold (above), and a trial at 0.95 there would start where the clock that rises for hold 1 is not yet measured; that waits for an iPhone battery and frame-rate A/B
#ifndef FSTEP_FIT_WIDE
#if TARGET_OS_IPHONE
#define FSTEP_FIT_WIDE 0
#else
#define FSTEP_FIT_WIDE 1
#endif
#endif
#define FSTEP_FIT (FSTEP_FIT_WIDE ? 0.95 : 0.85)   // a frame would fit k − 1 when its cost is at most this share of it
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
// their GPU under the late line and asked for one vsync more (a short burst on the CPU side): the hold stays at kmin and the lateness is paid back as debt, as after a stay in the
// background; no step up, so no wait and nothing the probes measured is forgotten. Stepping up for each burst and back after 1 s instead switched between 60 and 30 every 1.3-2.3 s
// for as long as the bursts came (run B: 13 step ups in 30 s against 6 when doubling), and each probe back from 30 into a GPU-bound area (run A) failed. A burst is one at
// kmin, in a trial too (one in a probe's trial failed it and doubled its wait), not within FSTEP_RUN frames of the last, of FSTEP_BURST_N late frames at most: a longer one,
// one with the GPU over the late line or asking for more, and one soon after the last steps up as before, and a held probe's run at kmin that ends early that way fails
// and doubles the waits as without backoff. An earlier cap of those waits at 2 s (FSTEP_BURST_CAP) sent a probe every 2 s into the GPU-bound scene that had ended such a run
// (run A, log.prev.txt:944-971), each failing with its 30 frames of grace late: 16 step ups and 296 late frames at hold 1 against 8 and 24 when doubling (t_fstep oot_a_held).
// Probes that fail with late frames that are no burst, fit trials that fail, and the hold-off of failed probes over budget (nvn_fstep_pheld, the GPU-bound areas of run A)
// are as before (t_fstep: the run B and run A replays)
#define FSTEP_BURST_N 5       // late frames in a row a short burst on the CPU side may last (run B's: 3)
// A frame across a stay in the background (nvn_fstep.away, set by the caller for one call: the profile's fps_resume, DM_FPS_RESUME; Ocarina of Time, X1.0). The guest's clock is
// frozen while the app is away, so the stay is time the game never ran: before, that frame counted as late and as a debt, capped at FSTEP_DEBT_MAX, which the game then paid
// back by running 15 vsyncs fast; with the late frame at the focus loss before it and the first frame after it (page-ins), three late frames stepped up to hold 2 for a second
// (Ocarina of Time on an iPhone 18 Pro Max, run B: 41.3, 40,454.8 and 93.2 ms, then GPU frames of 26 ms; 15 vsyncs paid back). With away the frame is on time and owes nothing,
// and for FSTEP_GRACE frames after it lateness is paid back but does not step up (the clocks and the pages the system took come back): rgrace. A trial or probe in progress at the
// stay does not count its frames down in rgrace either, so the cost after the grace decides it (before, its countdown ran through late frames and it ended as held)

typedef struct {
    int k, step;              // vsyncs each frame stays on screen; the step handed to the game for the next frame (k, or k + 1 while paying back)
    int kmin;                 // the last call's kmin (a lower one takes effect at once)
    double debt;              // real time the game is behind, in vsyncs
    int late_run, fit_run, trial;   // late frames in a row; frames in a row whose cost fits k − 1; frames left of a trial at k − 1 (0 = none)
    int probe, grace;         // 1: the trial in progress is a probe; 2: a probe held and its run at kmin has not ended yet; frames left of the probe's grace
    int ramp;                 // set by the caller (kept): 1 = a probe's grace is renewed while its frames keep getting cheaper (FSTEP_RAMP; the host's DM_FSTEP_PROBE_RAMP)
    double pa, pb; int plate, ptotal;   // the current grace window: the cost of its first and second halves (sums), its late frames; grace frames this probe has taken in all
    double hold, since;       // vsyncs a trial waits for after a step up; vsyncs since the last step up
    int tpend; double tsince; // a trial that held and whose run at its hold has not lasted FSTEP_HOLD_MAX yet (a step up before then fails it), and vsyncs since it held: every fit
                              // trial with FSTEP_FIT_WIDE, on the iPhone one the mean started (tbym), until a trial whose every frame fitted holds below it
    int fbym, tbym;           // frames left of the FSTEP_RUN after the last in the fit run that fitted only through the mean (ccur, 0 = none among the last FSTEP_RUN); the trial
                              // in progress started so (fbym > 0 when it starts: X1.0's per-frame rule would not have started it on that frame)
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
    int away, rgrace;         // set by the caller for one call, then cleared: 1 = the frame spans a stay in the background; frames left after it whose lateness does not step up
    int backoff;              // set by the caller (kept): 1 = a short burst on the CPU side at kmin is paid back without a step up (FSTEP_BURST_N)
    int inburst, bwait;       // backoff: the late frames in a row are a burst let through; frames left before another may be
    double gpu, lgpu;         // set by the caller before each call: the frame's GPU time in vsyncs (0 = none finished yet); the most of it over the late frames in a row
    double over[FSTEP_RUN], over_sum; int over_i, over_k;   // the last FSTEP_RUN frames at the hold over_k: shown − k of each (clamped), their sum; the next slot
    double last_cost[3];      // the last three frames' costs, oldest first
    int smax;                 // set by the caller (kept): the largest step the game takes (its stub's STEP_MAX; 0 = FSTEP_MAX)
    int no_payback;           // set by the caller (kept): 1 = the game does not take the step (120 fps: it steps by its target), so three late frames raise the hold whatever the average
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
    const int away = s->away; s->away = 0;   // the caller's, for this call only
    if (kmin < 1) kmin = 1;
    const int smax = s->smax > 0 && s->smax < FSTEP_MAX ? s->smax : FSTEP_MAX;   // the game's largest step
    if (kmax > smax) kmax = smax;
    if (kmin > smax) kmin = smax;
    if (kmax < kmin) kmax = kmin;
    if (!s->hold) s->hold = hold0;
    if (!s->phold) s->phold = hold0;
    if (fixed > 0) {   // the game's own step: speed is right by construction, nothing to pay back
        s->k = s->step = fixed < smax ? fixed : smax;
        s->debt = 0; s->late_run = s->fit_run = s->trial = s->probe = s->grace = s->tpend = 0; s->run = 0;
        s->kmin = FSTEP_MAX + 1;   // when it ends, k starts again from kmin
        nvn_fstep_pforget(s, hold0);   // a cutscene: another scene, as a cap change is
        return s->step;
    }
    if (!s->k) { s->k = s->step = s->kmin = kmin; return s->step; }   // first frame: nothing measured yet
    int held = s->k;   // the frame that just ended stayed on screen this long
    const double sh = away ? held : shown;   // a frame across a stay in the background: on time, owing nothing, and the frames after it get rgrace
    if (held != s->over_k) { s->over_k = held; s->over_sum = 0; s->over_i = 0; memset(s->over, 0, sizeof s->over); }   // judged against the hold in force, not the frames before a step
    { double over = sh - held; if (over < -1) over = -1; if (over > FSTEP_SHORT_MAX) over = FSTEP_SHORT_MAX;
      s->over_sum += over - s->over[s->over_i]; s->over[s->over_i] = over; s->over_i = (s->over_i + 1) % FSTEP_RUN; }
    s->last_cost[0] = s->last_cost[1]; s->last_cost[1] = s->last_cost[2]; s->last_cost[2] = cost;
    s->debt += sh - s->step;
    if (s->debt > FSTEP_DEBT_MAX) { s->dropped += s->debt - FSTEP_DEBT_MAX; s->debt = FSTEP_DEBT_MAX; }
    if (s->debt < -1) s->debt = -1;   // ahead (a frame shorter than its step): nothing slows the game down, so at most one vsync is remembered
    s->since += sh; s->tsince += sh;
    if (s->tpend && s->tsince >= hold_max) { s->tpend = 0; s->hold = hold0; if (s->k <= kmin) nvn_fstep_pforget(s, hold0); }   // the trial's run lasted (FSTEP_FIT_WIDE, or the mean's trial)
    if (away) s->rgrace = FSTEP_GRACE;
    if (shown >= FSTEP_DEBT_MAX * (s->per_vsync ? s->per_vsync : 1)) nvn_fstep_pforget(s, hold0);   // a load or a trip to the background: another scene
    if (s->pin != s->pinned) {   // a fast movie starts or ends: another scene, and no trial or probe carries over it
        s->pinned = s->pin; s->trial = s->probe = s->grace = s->tpend = 0; s->late_run = s->fit_run = 0; s->upf = 0; s->run = 0; s->cn = 0;
        s->hold = hold0; nvn_fstep_pforget(s, hold0);
    }
    if (s->pinned) {   // while it plays: kmin, the cap's fastest hold, whatever the frames cost; only the debt is paid back
        s->k = s->kmin = kmin; s->screen = 0;
        s->step = s->k + (s->debt >= 1 && s->k < smax);
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
    int late = away ? 0 : scr ? scr == 2 : shown > held + FSTEP_LATE + s->shown_slack || cost > held + FSTEP_LATE, grace = s->grace > 0;
    int rg = !away && s->rgrace > 0; if (rg) s->rgrace--;
    if (grace && !cap_probe) {   // the completed frame at the old cap does not consume the new hold's grace
        if (s->grace > FSTEP_GRACE / 2) s->pa += cost; else s->pb += cost;
        s->plate += late; s->ptotal++;
        if (!--s->grace && s->ramp && s->plate && s->ptotal + FSTEP_GRACE <= FSTEP_PROBE_MAX && s->pb <= (1 - FSTEP_RAMP) * s->pa) { s->grace = FSTEP_GRACE; s->pa = s->pb = 0; s->plate = 0; }   // still getting cheaper: another window
    }
    int lagged = s->upf > 0 && scr == 2 && cost <= held + FSTEP_LATE;   // the screen's verdict on a frame before the last step up
    if (s->upf > 0) s->upf--;
    if (late) { s->late++; s->late_run = grace || lagged || rg ? 0 : s->late_run + 1; s->fit_run = 0; s->lgpu = s->late_run > 1 && s->lgpu > s->gpu ? s->lgpu : s->gpu; } else s->late_run = 0;
    if (!s->late_run) s->inburst = 0;
    if (s->bwait > 0 && !s->inburst) s->bwait--;
    if (s->probe == 1 && !grace && !cap_probe && held <= kmin && !away) { s->psum += cost; s->pn++; }   // the probe's frames after its grace: kmin's cost
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
    int fits = !away && (!scr || cost <= held);   // the frame across a stay measures the stay, not the scene
    if (held <= kmin) { s->run += sh; s->cn = 0; if (!late && fits && s->probe != 1) s->crun = s->crun > 0 ? s->crun + (cost - s->crun) / 32 : cost; }
    else {
        s->run = 0;
        if (held != s->ck) { s->ck = held; s->cn = 0; }
        if (!late && fits) { s->ccur = s->cn ? s->ccur + (cost - s->ccur) / 8 : cost; s->cn++; }
    }
    // A rate below k over the last FSTEP_RUN frames (the slots not filled yet since the hold changed count as on time), without the window's longest frame (one stall is
    // not a rate); the screen's verdict (present snapshots) is its own, and with no payback (120 fps) three late frames are enough
    double omax = 0; for (int i = 0; i < FSTEP_RUN; i++) if (s->over[i] > omax) omax = s->over[i];
    int short_of_k = scr || s->no_payback || s->over_sum - omax > FSTEP_LATE * FSTEP_RUN;
    double c3 = s->last_cost[0] < s->last_cost[1] ? s->last_cost[0] : s->last_cost[1]; if (s->last_cost[2] < c3) c3 = s->last_cost[2];
    int want = (int)ceil(c3 - 0.05);   // a step up goes to the cost of the cheapest of the three late frames, at least one vsync
    if (want < s->k + 1) want = s->k + 1;
    if (want > kmax) want = kmax;
    // backoff: late frames at kmin whose GPU fitted and that ask for one vsync more are a short burst on the CPU side: paid back, no step up (FSTEP_BURST_N of them at most).
    // Only where the average would step up: a burst the average already pays back is no burst
    int burst = s->backoff && s->late_run >= 3 && s->k < kmax && short_of_k && held <= kmin && s->late_run <= FSTEP_BURST_N && s->lgpu > 0 && s->lgpu <= held + FSTEP_LATE
                && want <= held + 1 && (s->inburst || !s->bwait);
    if (burst && !s->inburst) { s->bursts++; s->inburst = 1; s->bwait = FSTEP_RUN; }
    if (s->late_run >= 3 && s->k < kmax && short_of_k && !burst) {   // step up to the cost, at least one vsync
        s->inburst = 0;
        if (s->trial || s->tpend || (s->probe == 2 && s->since < hold_max)) {
            s->failed++; s->trial = 0; s->hold = s->hold * 2 < hold_max ? s->hold * 2 : hold_max;
            if (s->probe) {   // a failed probe: what it measured at kmin, and the probes' own hold-off
                s->phold = s->phold * 2 < FSTEP_PHOLD_MAX * (s->per_vsync ? s->per_vsync : 1) ? s->phold * 2 : FSTEP_PHOLD_MAX * (s->per_vsync ? s->per_vsync : 1);
                if (s->probe == 1) { s->pk = s->pn ? s->psum / s->pn : cost; s->pover = s->pk > FSTEP_OVER * kmin ? s->pover + 1 : 0; }
                else s->pover = 0;   // its run at kmin held for a while: kmin fits, at times
            }
        }
        else if (s->probe == 2) { s->hold = hold0; nvn_fstep_pforget(s, hold0); }   // the probe's run at kmin lasted
        if (held == kmin && s->run >= hold_max) s->cref = s->crun;   // kmin held 8 s at this cost
        s->k = want; s->ups++; s->late_run = s->fit_run = 0; s->since = 0; s->probe = 0; s->tpend = 0; s->upf = FSTEP_UP_LAG;
    } else if (s->trial && !grace && !rg && !--s->trial) {   // the trial held (a probe's run at kmin is judged at the next step up); not counted down in rgrace, whose late frames do not count
        if (s->probe) { s->probe = 2; s->since = 0; }
        else if (FSTEP_FIT_WIDE || s->tbym) { s->tpend = 1; s->tsince = 0; }   // its run is judged by how long it lasts (above); on the iPhone where the mean started it
        else { s->tpend = 0; s->hold = hold0; if (s->k <= kmin) nvn_fstep_pforget(s, hold0); }   // X1.0's iPhone rule; an earlier trial's pending run ended in this step down
    }
    double pe = nvn_fstep_pest(s);
    if (pe > 0 && pe <= FSTEP_FIT * kmin) { nvn_fstep_pforget(s, hold0); s->hold = hold0; }   // the longer hold's cost fell well under what kmin needs: the scene got light
    // A frame also fits k − 1 while the running mean of this hold's frames on time does (upstream 5b0f1372): single frames over the fit among frames under it are what the
    // shorter hold absorbs, and they kept the trial from ever starting
    double fitc = s->ck == s->k && s->cn && s->ccur < cost ? s->ccur : cost;
    if (!late) {
        int fit = s->k > kmin && fitc <= FSTEP_FIT * (s->k - 1);
        s->fit_run = fit ? s->fit_run + 1 : 0;
        // a frame that fitted only through the mean among this run's last FSTEP_RUN (frames left of them; a late frame ends the run, so the next frame on time starts it over)
        s->fbym = !fit ? 0 : cost > FSTEP_FIT * (s->k - 1) ? FSTEP_RUN : s->fit_run > 1 && s->fbym > 0 ? s->fbym - 1 : 0;
    }
    if (s->fit_run >= FSTEP_RUN && s->since >= s->hold && !s->trial) { s->k--; s->downs++; s->trial = FSTEP_RUN; s->tbym = s->fbym > 0; s->fit_run = 0; }
    else if ((slow || nvn_fstep_same(s)) && s->k > kmin && s->since >= s->hold && s->since >= s->phold && !s->trial && nvn_fstep_probe_ok(s, kmin)) {   // probe: straight to kmin, so the controller sees the whole deadline
        s->k = kmin; s->downs++; s->probes++; s->trial = FSTEP_RUN; s->probe = 1; s->grace = FSTEP_GRACE; s->fit_run = s->late_run = 0; s->pa = s->pb = 0; s->plate = s->ptotal = 0;
        nvn_fstep_pstart(s, cost);
    }
    s->step = s->k + (s->debt >= 1 && s->k < smax);
    s->paid += s->step > s->k;
    return s->step;
}

// The heat ladder's "60 not holding" (nvn_heat.h, heat-ladder.md §7.2), from the frame step's own state and not from late frames alone: with Hold frames on, three late frames
// step the hold up and the frames are then on time at the longer hold, which a late-frame share would read as holding. Called before nvn_fstep_next with the frame that just
// ended (s->k is the hold it stayed on screen; kmin the cap's): 0 holding, 1 not holding with the GPU over the frame (resolution helps), 2 not holding on the CPU side (it
// does not: the ladder skips 70% to 40 fps), -1 not counted (a stay in the background, a probe's or a stay's grace, a fast movie's pin, the first frame, a frame held at the
// game's own step: BotW's VFR override, marked kmin > FSTEP_MAX until the next call without it, so the frame just after it ends is left out too; the game chose that rate,
// and resolution or effects do not change it)
static inline int nvn_fstep_nothold(const nvn_fstep *s, int kmin, double shown, double cost, double gpu, int away) {
    if (away || !s->k || s->grace > 0 || s->rgrace > 0 || s->pinned || s->kmin > FSTEP_MAX) return -1;
    int held = s->k, bad = held > kmin || shown > held + FSTEP_LATE + s->shown_slack || cost > held + FSTEP_LATE;
    return !bad ? 0 : gpu > 0 && gpu >= 0.9 * cost ? 1 : 2;
}
// "60 would fit again" (the ladder's evidence exit, heat-ladder.md §7.2): the cost at the hold in force, at kmin the running cost of its frames (crun), at a longer hold the estimate
// from the last failed probe (nvn_fstep_pest) or the hold's own running cost (ccur), is within FSTEP_FIT of the 60 fps hold (k60: 1, or 2 in ticks of 1/120 s). Works while a 40
// or 30 cap is on, where kmin's frames are the 30 or 40 fps ones. Not while the game fixes its own step (kmin > FSTEP_MAX): the frame step measures nothing there
static inline int nvn_fstep_fit60(const nvn_fstep *s, int k60) {
    double c = !s->k || s->kmin > FSTEP_MAX ? 0 : s->k > s->kmin ? (nvn_fstep_pest(s) > 0 ? nvn_fstep_pest(s) : s->cn ? s->ccur : 0) : s->crun;
    return c > 0 && c <= FSTEP_FIT * (k60 > 0 ? k60 : 1);
}

// The GPU clock follows the hold too: Breath of the Wild on an iPhone went from 14.4 to about 25 ms of GPU time a frame at hold 2 with the same 4,900 draws, the CPU still on its
// performance cores, so its cost never fitted hold 1 again. The GPU counts as slowed (another reason for nvn_fstep_next's slow) when its time at a hold above kmin is at least
// FSTEP_GPU_SLOW times its time at kmin and it alone does not fit k − 1 (a GPU at 3 ms of 17, 6 times its time on a loading screen, is not what holds a frame back); with
// FSTEP_FIT_WIDE it must not fit kmin, the hold a probe goes to: with 0.95 a slowed GPU at hold 3 (1.87 vsyncs) fitted hold 2, took the fit trial there, where no ratio was
// learned, and stayed at 30 where the probe brought 60 (upstream NXNative 293b1d4db).
// The reference is not updated during a probe's trial (its frames run while the clock is still rising), so a failed probe leaves it as it was. It is kept for each kmin: one
// learned at a 30 fps cap is the GPU time at the clock that cap left (lowered for 30 fps, and under the thermal cap for the heat), and taken as hold 1's after the cap rose it
// made the same work at hold 2 look not slowed.
// The reference is another scene's time, though: the title screen's, or the light view's before a heavy one stepped up. A scene whose GPU time at kmin's own clock does not fit
// kmin was called slowed against it, and each probe failed after its grace (Ocarina of Time: 22 failed probes a minute in Hyrule Field at night on an M2 Pro, 159 frames at
// 20 fps, with the title screen's reference; Kokiri Forest at every turn of the camera on an Android port). A failed probe measures what the reference cannot: the scene's
// GPU time at kmin once the clock rose for it (post: the frames from the second half of its grace on, which nvn_fstep.ramp keeps while they still get cheaper), against its
// time at the longer hold before the probe and again after it: how much the longer hold slows the GPU here (ratio_at, for kmin and each hold). That time is the smaller of the
// running means of 8 and of 32 frames, and of the two where both are the same hold: a turn of the camera to or from a heavy view makes one of them another scene's (Kokiri
// Forest at 1.6 times the GPU time at hold 3: a ratio of 2.15 where the hold-3 stretch began in the heavy view, and the light view's 2.0 at hold 3 started a probe again). Once FSTEP_GPU_FAILS failed probes have given a hold's ratio, the GPU counts as slowed there when cur over it, the scene's time at kmin, fits kmin, in place
// of the reference: the scene that failed starts no probe while it costs what it did, and a lighter one starts one even when its cur is not FSTEP_GPU_SLOW times a reference
// learned in a heavier scene (a gate on the reference itself, which kmin's frames relearn only after a probe, would keep that lighter scene at the longer hold).
// The ratio is the largest the failed probes gave, and one probe alone does not set it: a probe can fail before the clock is at its top (the iOS thermal cap's end, where it
// took 1 s), which reads as a ratio too small, and one too small keeps a scene that fits kmin at the longer hold, where one too large costs a failed probe now and then, as
// before the ratio, spaced out by the hold's doubling. A probe that holds gives none: it needs no gate, and its frames may be a lighter scene (a menu) than the hold's
#define FSTEP_GPU_SLOW 1.3    // GPU time at the longer hold against its time at kmin
#define FSTEP_GPU_N 30        // frames at the longer hold before the comparison counts
#define FSTEP_GPU_PN 3        // a probe's frames at kmin after the first half of its grace before it gives a ratio
#define FSTEP_GPU_FAILS 2     // failed probes whose ratio a hold needs before the ratio decides
#define FSTEP_GPU_RMIN 0.75   // the smallest ratio a probe gives: hold 1 can take a little longer than the longer hold (Ocarina of Time on an M4 Pro, whose clock barely moves:
                              // 1.03–1.09 vsyncs at hold 1 after the grace, 0.99–1.00 at hold 2; with the ratio taken as 1 the estimate, 1.00, kept starting probes). Below it the
                              // probe's frames were another scene or a stall, and it gives none (a load's stall failed probes there at GPU 4.4 and 5.7 vsyncs, a ratio of 0.15)
typedef struct {
    double ref, cur, avg; int n, k, kmin; double ref_at[FSTEP_MAX + 1];   // GPU time at kmin (running mean; of every kmin in ref_at); at the current hold k (of 8 frames, of 32) and its frame count; kmin of the last frame
    double pre, post; int pre_k, pn, was, fail;   // the last probe: the time at the hold pre_k it started from (0: none to compare), its frames' GPU time at kmin and their count; nvn_fstep.probe last
                                                  // frame; it failed, and its ratio waits for FSTEP_GPU_N frames at the hold after it
    double ratio_at[FSTEP_MAX + 1][FSTEP_MAX + 1]; int ratio_n[FSTEP_MAX + 1][FSTEP_MAX + 1];   // [kmin][k]: GPU time at hold k against kmin's, the largest of the failed probes', and their count
    int noretry;              // set by the caller (kept): 1 = no probe each FSTEP_PHOLD_MAX by the reference where the ratio decides (upstream's rule; the host's DM_FSTEP_GPU_RETRY=0)
} nvn_fgpu;
// The hold's ratio when it decides (0: the reference does)
static inline double nvn_fgpu_ratio(const nvn_fgpu *g) {
    return g->kmin >= 1 && g->kmin <= FSTEP_MAX && g->k >= 1 && g->k <= FSTEP_MAX && g->ratio_n[g->kmin][g->k] >= FSTEP_GPU_FAILS ? g->ratio_at[g->kmin][g->k] : 0;
}
// NX 18: where the ratio says the scene does not fit kmin, the reference still starts a probe once FSTEP_PHOLD_MAX (32 s) has passed since the last step up (late), the bound
// nvn_fstep_probe_ok gives the failed probes over budget. A ratio learned in one scene is applied to the next, and a heavy scene as slow at either hold (ratio 1: Breath of the
// Wild's GPU-bound area on an iPhone, 22-24 ms at hold 2 and as much in each probe) would keep a later scene whose clock follows the hold (14.4 ms at hold 1, about 25 at hold
// 2) at the longer hold until a load: one probe each 32 s finds hold 1 again (t_fstep: the heavy stretch, then the GPU-slowed scene). noretry drops it, as upstream has it
static inline int nvn_fgpu_slow(const nvn_fgpu *g, int late) {
    if (g->n < FSTEP_GPU_N || g->cur <= FSTEP_FIT * (FSTEP_FIT_WIDE ? g->kmin : g->k - 1)) return 0;
    double r = nvn_fgpu_ratio(g); int by_ref = g->ref > 0 && g->cur >= FSTEP_GPU_SLOW * g->ref;
    return r > 0 ? g->cur / r <= g->kmin || (late && !g->noretry && by_ref) : by_ref;
}
static inline void nvn_fgpu_learn(nvn_fgpu *g, int kmin, int k, double t) {
    double r = t / g->post, *at = &g->ratio_at[kmin][k];
    if (r < FSTEP_GPU_RMIN) return;
    if (r > *at) *at = r;
    g->ratio_n[kmin][k]++;
}
// Once per frame, with the frame's GPU time (vsyncs; 0 = none finished yet) and the step's state the frame ran under (its hold, probe and grace)
static inline int nvn_fstep_gpu_slowed(nvn_fgpu *g, double gpu, const nvn_fstep *s, int kmin) {
    if (kmin < 1 || kmin > FSTEP_MAX) return 0;   // no reference slot for it (hle_nvn.c passes 1 or 2)
    int k = s->k ? s->k : kmin, probe = s->probe;
    if (kmin != g->kmin) g->fail = 0;   // another cap: the clocks the probe measured are not this one's
    if (probe == 1 && g->was != 1) { g->pre_k = g->kmin == kmin && g->k > kmin && g->k <= FSTEP_MAX && g->n >= FSTEP_GPU_N ? g->k : 0; g->pre = g->cur < g->avg ? g->cur : g->avg; g->post = 0; g->pn = 0; g->fail = 0; }   // a probe from hold g->k
    else if (probe != 1 && g->was == 1) g->fail = !probe && k > kmin && g->pn >= FSTEP_GPU_PN;   // it ended: failed when the hold went up again
    g->was = probe;
    if (probe == 1 && k <= kmin && gpu > 0 && s->grace <= FSTEP_GRACE / 2) { g->post = g->pn ? g->post + (gpu - g->post) / 4 : gpu; g->pn++; }   // weighted to the last frames: the clock at its highest
    g->ref = g->ref_at[kmin]; g->kmin = kmin;
    const int late = s->since >= FSTEP_PHOLD_MAX * (s->per_vsync ? s->per_vsync : 1);
    if (gpu <= 0) return nvn_fgpu_slow(g, late);
    if (k <= kmin) { if (probe != 1) g->ref = g->ref_at[kmin] = g->ref > 0 ? g->ref + (gpu - g->ref) / 32 : gpu; g->n = 0; g->k = k; g->fail = 0; return 0; }
    if (k != g->k) { g->k = k; g->n = 0; }
    g->n++; g->cur = g->n > 1 ? g->cur + (gpu - g->cur) / 8 : gpu; g->avg = g->n > 1 ? g->avg + (gpu - g->avg) / (g->n < 32 ? g->n : 32) : gpu;
    if (g->fail && g->n >= FSTEP_GPU_N && k <= FSTEP_MAX) {   // the failed probe's ratios: this hold's after it, and the hold it started from (the smaller time where they are one)
        double t = g->cur < g->avg ? g->cur : g->avg;
        if (k == g->pre_k) nvn_fgpu_learn(g, kmin, k, g->pre < t ? g->pre : t);
        else { nvn_fgpu_learn(g, kmin, k, t); if (g->pre_k) nvn_fgpu_learn(g, kmin, g->pre_k, g->pre); }
        g->fail = 0;
    }
    return nvn_fgpu_slow(g, late);
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
