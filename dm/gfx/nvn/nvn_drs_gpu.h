// GPU headroom for the game's dynamic resolution (DM_DRS_GPU_TARGET; hle_nvn.c drs_gpu_tick, which feeds it once a window). On the iPhone 18 Pro Max the SoC caps the
// performance cores to 1.44 GHz (from 4.4) once the GPU is busy about 85-96% of the time, with the thermal state at 0 and a cooler on the phone or not, and gives the clock
// back only when the GPU's load falls (NX18-X2.0 traces/oot-mst-1-findings.md, its last two sections). Ocarina of Time's frames are limited by the CPU (the serial main ->
// replay -> encode chain), so fps fell to 40-50 there while the game's own dynamic resolution, which steps on late frames, stayed at full size. This controller holds a floor
// under the game's level (a larger level is a smaller picture): it raises the floor one level past the level the game runs at when the GPU stays busy over a target, or when the
// performance cores sit at their floor clock while the GPU is still fairly busy, and lowers it one level at a time once the GPU has stayed well below the target. The game's
// own controller keeps choosing within the floor (it may go lower still, never higher).
//
// Busy is the host's GPU busy time over the window (mtl_gpu_busy_ns: every command buffer, overlaps merged), not the power tick's union of the frames' spans, which counts the
// gaps inside a frame and stayed at 780-890 ms/s through the capped stretches of the cooler run while the merged figure read 510-600: a target on the spans would hold the floor
// down for good once the CPU is the limit. In GPU-bound play the merged figure runs about 5-8 points under the spans, so the default target is 75% (about 80% of the spans).
//
// Late only when it lasts (nvn_drs_gpu_load, 2026-11-23): the load counts frames as late only after NVN_DRS_LATE_N windows (3 s) in a row under 95% of the target; before
// that it is the busy share. Donkey Kong Bananza's own controller drops to 30 fps for 20-200 frames at a time (its interval 2) and comes back: those blips read as a load of
// 94-106%, opened the clock-room gate (frames late) and took a step, and the load falling back to about 85% after the blip then read as a gain, so the floor walked down
// to 0.6 of the picture's side with the GPU at a low clock and no frame gained (c2bfbce88, about 8 min). A clock that collapses and stays down (Breath of the Wild, tens of
// seconds at about 40 fps) is late for longer than that and still steps. When the measure switches (late for 3 s, or on time again) a running check is dropped (its step
// stands) and the busy rule starts counting again: a check across the switch would compare the busy share with the load. A late window counts only with the GPU busy at
// least 75% of it (NVN_DRS_LATE_BUSY): Donkey Kong Bananza on c8351b8cf ran CPU-bound stretches of 48-56 fps for 10-45 s (frame time 19-20 ms, GPU p50 10-11 ms, busy
// 55-62%, the performance cores at 3.0-3.4 GHz), where the load read 76-79% and took steps to 0.9 that no frame followed; Breath of the Wild's collapsed clock runs 83-88%.
// Load (since the GPU-time-per-frame change, 2026-11-23): what the caller hands in as busy is the GPU time per frame over the target's frame time, busy x target / fps (fps
// at most the target), so at the target frame rate it is the busy share and below it more: frames that are late because of the GPU read as over 100%, and a smaller picture
// that lets more frames through reads as a gain even when the busy share stays (it did on the phone when the frames were late, and Breath of the Wild's GPU sits 83-88% busy
// whatever its clock as it waits for each frame's fence: gpu-clock-collapse.md). The log lines say "GPU load". Up to 2.0.
// Rules, each window (about 250 ms, NVN_DRS_WIN_NS; a longer gap starts a new window with no decision):
//   down, GPU busy:    busy > target in 2 windows in a row, the game at the floor or past it (it has followed the last step), 1 s since the last change
//   down, clock floor: the performance cores' clock at most 45% of the session's highest (1.44 of 4.4 GHz is 33%) with busy at least 50%, in 4 windows in a row, 2 s since
//                      the last change. The clock is the process's own performance-core cycles over its time there; no figure (no time there, or a platform without
//                      RUSAGE_INFO_V6) is not a floor. At most 3 such steps while the clock stays at its floor: a cap the GPU does not cause is not chased further
//   up:                busy < target - 15 points with the clock not at its floor, in 8 windows in a row (2 s), 3 s since the last change, and the level it returns to not
//                      stepped down from within its back-off: 5 s after the first step down from a level, doubled (to 60 s) each time the floor comes back down from that
//                      same level within 60 s of its last step. So a scene whose busy sits in the 15-point band moves nothing, and one that trips each time it goes back
//                      tries less and less often
//   no gain:           after each step down, once the game has followed (the first window at the new level skipped, as it holds frames of the old one), the busy of the next
//                      4 windows is compared with the busy that called the step (the mean of the 2 windows before it). Less than 2 points lower: the smaller picture bought
//                      nothing, the floor goes back up at once and no step down from that level is taken for 20 s, doubled (to 120 s) when it happens again there within
//                      120 s. No other step down is taken while a check runs (Ocarina of Time on the iPhone 18 Pro Max, 2026-11-23: 5 steps down in 7 s while the busy rose
//                      78 -> 87%, then 854x480 for most of the run: its scene passes took 228 us at 854x480 and 224 us at 1440x810). A check whose level the game has not
//                      reached in 5 s is dropped. A clock-floor step is judged by the clock instead: it gained if the performance cores left their floor in any of the
//                      12 windows (3 s) after it, whatever the busy (a clock that comes back raises the frame rate and with it the busy). The hold is per kind of step and
//                      covers the level and every smaller picture: the game also steps down on its own, and a step from a lower level after a no-gain verdict bought
//                      nothing either (Ocarina of Time on the phone, ea555d697: the cores held 1.44 GHz for 37 s with the game's own threads at about 1.9 cores, the
//                      floor went 0 -> 4 -> 5 -> 6 one verdict at a time and the clock never moved)
//   clock room:        a window over the target does not count toward the busy step while the caller says the GPU runs well under its top clock with the frames on
//                      time (gpu_room, nvn_drs_gpu_load: the GPU probe's fastest of its last two readings at least 1.5x the session's fastest, the frames not late for 3 s). iOS lowers the GPU clock
//                      until the GPU is busy most of the frame, so a high busy share at a low clock is the governor's own target, not a GPU short of time: a smaller
//                      picture only lets it lower the clock again and the busy stays (Mario Kart World on the iPhone 18 Pro Max, 136433517: 84-88% busy in races at
//                      60 fps with the probe at 2.4x, four steps down, each undone for no gain). Late frames at a low clock still count (a clock that collapsed and
//                      stays down: Breath of the Wild, gpu-clock-collapse.md)
// Each step moves one level; the floor never passes the game's lowest level (its level count less one, which the level stub writes at state +0x294).
// Battery Saver's lowest-resolution hold (DM_DRS_LOWEST=1, the profile's preset battery line; open-optimizations.md item 7): while the caller sets hold, the floor sits at
// the game's lowest level and none of the rules above runs: no step, no check, no no-gain verdict. Battery Saver is 30 fps at the lowest resolution: a smaller picture there is
// not judged by the frames it lets through (at 30 there are none to win) but by the GPU work it takes away, which iOS turns into a lower GPU clock even where the GPU time per
// frame hardly moves (Ocarina of Time's scene passes cost about the same at 854x480 and 1440x810, so the no-gain rule would undo every step). Ocarina of Time: the level stub's
// lowest level (its level count less one, +0x294: level 9, 0.333 of 2048x1152, the main scene passes 854x480), where the game's own controller sat for minutes on the Mac and
// the iPhone 18 Pro Max ran most of a Balanced run (b8a67e1d7, 59.8 fps, no red line); the stretch
// family: level DRS_SCALE_LEVELS - 1, 0.5 of the picture's side, the render scale's own floor (nvn_heat.h nvn_heat_scale), the GPU time its dynamic resolution reads x4, which takes
// Donkey Kong Bananza's own controller to its lowest step (1152x648 with its upscaler). The level count unknown (0): nothing moves until it is. When the caller clears hold (the
// in-game menu's preset change, or DM_DRS_LOWEST=0) the floor goes back to full size at once and the rules start again from there.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define NVN_DRS_WIN_NS      250000000ull
#define NVN_DRS_GAP_NS      2000000000ull   // a window longer than this (a pause, the background, a load with no presents): a new baseline, no decision
#define NVN_DRS_OVER_N      2
#define NVN_DRS_CLOCK_N     4
#define NVN_DRS_UNDER_N     8
#define NVN_DRS_DOWN_DWELL  1000000000ull
#define NVN_DRS_CLOCK_DWELL 2000000000ull
#define NVN_DRS_UP_DWELL    3000000000ull
#define NVN_DRS_BACKOFF0    5000000000ull
#define NVN_DRS_BACKOFF_MAX 60000000000ull
#define NVN_DRS_BAND_PM     150   // the step up's threshold: the target less 15 points
#define NVN_DRS_CLOCK_BUSY_PM 500
#define NVN_DRS_CLOCK_FLOOR 0.45  // of the session's highest performance-core clock
#define NVN_DRS_CLOCK_MIN_MAX 2.0 // GHz: a session that never ran its performance cores above this knows no floor
#define NVN_DRS_LEVELS      16
#define NVN_DRS_CLOCK_MAX   3   // clock-floor steps in a row while the clock stays at its floor: a cap the GPU does not cause is not chased to the lowest level
#define NVN_DRS_GAIN_N      4   // windows measured at the new level after a step down
#define NVN_DRS_GAIN_CLOCK_N 12 // after a clock-floor step: windows in which the cores may leave their floor
#define NVN_DRS_GAIN_PM     20  // the busy must fall at least this much (per mille) for the step to count
#define NVN_DRS_GAIN_WAIT   5000000000ull     // a check whose level the game has not reached by then is dropped
#define NVN_DRS_NOGAIN0     20000000000ull    // no step down from a level that gained nothing, for this long
#define NVN_DRS_NOGAIN_MAX  120000000000ull
#define NVN_DRS_LATE_N      12  // windows in a row under 95% of the target before frames count as late (the load, the clock-room gate)
#define NVN_DRS_LATE_BUSY   0.75 // a late window counts only with the GPU busy at least this share of it: late with the GPU idle a quarter of the time is the CPU's
#define NVN_DRS_ROOM_RATIO  1.5 // the GPU probe against the session's fastest at or over which the GPU runs well under its top clock

enum { NVN_DRS_NONE, NVN_DRS_DOWN_BUSY, NVN_DRS_DOWN_CLOCK, NVN_DRS_UP, NVN_DRS_UNDO, NVN_DRS_HOLD, NVN_DRS_RELEASE };

typedef struct {
    int target_pm;                  // busy target, per mille (0: off)
    int floor;                      // the host's floor level (0: none)
    int over_n, clock_n, under_n;   // windows in a row over the target, at the clock floor with busy, under the band
    int clock_steps;                // clock-floor steps since the clock was last off its floor
    uint64_t last_change;           // ns (0: never)
    double clk_max;                 // the session's highest performance-core clock, GHz
    uint64_t trip_at[NVN_DRS_LEVELS], backoff[NVN_DRS_LEVELS];   // the last step down from each level, and the wait before the floor goes back to it
    int prev_bpm;                   // the previous window's busy, per mille
    int chk_level, chk_busy, chk_n, chk_sum, chk_skip, chk_clock, chk_freed;   // the step down being checked: from level (-1: none), the busy that called it, windows measured,
                                                                               // their sum; a clock-floor step, and whether the cores left their floor since
    uint64_t chk_at;
    int late_n, late_held;          // windows in a row under 95% of the target, and whether the load counts them (nvn_drs_gpu_load)
    int gpu_room;                   // set by the caller before each window: the GPU runs well under its top clock with the frames on time (above: clock room)
    int settle_n;                   // windows skipped after a step before its check measures (1: the stub's game follows within its first window; the stretch family 4)
    uint64_t nogain_at[2][NVN_DRS_LEVELS], nogain_hold[2][NVN_DRS_LEVELS];   // per kind (0 GPU busy, 1 clock floor): the last no-gain verdict from each level, and its hold
    int hold, held;                 // hold: set by the caller before each window, Battery Saver's lowest-resolution hold (DM_DRS_LOWEST=1); held: the floor sits there now
    // the summary since the last nvn_drs_gpu_summary
    uint32_t s_win, s_room, s_down_busy, s_down_clock, s_up, s_undo, s_floor_lo, s_floor_hi, s_held;
    double s_busy_sum, s_busy_max, s_clk_min;
    char last_why[128];
} nvn_drs_gpu;

// DM_DRS_GPU_TARGET: unset or empty 75, 0 / off off, 50-95 the target in percent; anything else → -1 (the caller says so and keeps 75)
static inline int nvn_drs_gpu_parse(const char *e) {
    if (!e || !*e) return 75;
    if (!strcmp(e, "0") || !strcmp(e, "off")) return 0;
    char *end; long v = strtol(e, &end, 10);
    if (*end || v < 50 || v > 95) return -1;
    return (int)v;
}
// DM_DRS_LOWEST: unset, empty, 0 or off: no hold; 1 or on: the floor held at the game's lowest level (Battery Saver's preset line); anything else -> -1 (the caller says so, no hold)
static inline int nvn_drs_lowest_parse(const char *e) {
    if (!e || !*e || !strcmp(e, "0") || !strcmp(e, "off")) return 0;
    if (!strcmp(e, "1") || !strcmp(e, "on")) return 1;
    return -1;
}
static inline void nvn_drs_gpu_init(nvn_drs_gpu *c, int target_pct) {
    memset(c, 0, sizeof *c);
    c->target_pm = target_pct * 10; c->s_floor_lo = ~0u; c->s_clk_min = 1e9; c->chk_level = -1; c->settle_n = 1;
}
static inline void nvn_drs_gpu_trip(nvn_drs_gpu *c, int level, uint64_t now) {
    if (level < 0 || level >= NVN_DRS_LEVELS) return;
    uint64_t b = c->backoff[level];
    c->backoff[level] = c->trip_at[level] && now - c->trip_at[level] < NVN_DRS_BACKOFF_MAX && b ? (2 * b < NVN_DRS_BACKOFF_MAX ? 2 * b : NVN_DRS_BACKOFF_MAX) : NVN_DRS_BACKOFF0;
    c->trip_at[level] = now;
}
// The load handed to nvn_drs_gpu_window, and gpu_room, from the window's GPU busy share, its frames per second, the target (0: none) and the GPU probe's ratio to the
// session's fastest (0: none): the busy share times target / fps once the frames have been late for NVN_DRS_LATE_N windows, else the busy share; at most 2
static inline double nvn_drs_gpu_load(nvn_drs_gpu *c, double share, double fps, double tgt, double probe_ratio) {
    const int late = tgt > 0 && fps < 0.95 * tgt && share >= NVN_DRS_LATE_BUSY;   // late for the GPU: frames under the target with the GPU busy most of the time
    c->late_n = late ? c->late_n + 1 : 0;
    const int held = c->late_n >= NVN_DRS_LATE_N;
    if (held != c->late_held) { c->late_held = held; c->chk_level = -1; c->prev_bpm = 0; c->over_n = 0; }   // the measure changed: a check across it would compare the two
    double load = share;
    if (held && fps > 0) load = share * tgt / (fps < tgt ? fps : tgt);
    c->gpu_room = !held && probe_ratio >= NVN_DRS_ROOM_RATIO;
    return load > 2 ? 2 : load;
}
// The hold's window (nvn_drs_gpu_window while hold or held): the summary's figures, then the floor to the lowest level (NVN_DRS_HOLD, once) or, the hold cleared, back to
// full size (NVN_DRS_RELEASE); every rule's count and running check dropped either way, so the rules start fresh when the hold ends
static inline int nvn_drs_gpu_hold_window(nvn_drs_gpu *c, uint64_t now, double busy, double pclk, int nlevels, char *w, size_t n) {
    c->s_win++; c->s_busy_sum += busy; if (busy > c->s_busy_max) c->s_busy_max = busy;
    if (pclk > 0 && pclk < c->s_clk_min) c->s_clk_min = pclk;
    if (pclk > c->clk_max) c->clk_max = pclk;
    c->prev_bpm = (int)(busy * 1000 + 0.5);
    int kind = NVN_DRS_NONE;
    if (c->hold) {
        c->s_held++;
        if (nlevels > 0) {
            const int lowest = nlevels - 1 < NVN_DRS_LEVELS - 1 ? nlevels - 1 : NVN_DRS_LEVELS - 1;
            if (!c->held || c->floor != lowest) {
                c->floor = lowest; c->held = 1; kind = NVN_DRS_HOLD;
                snprintf(w, n, "held at the lowest level %d of %d (DM_DRS_LOWEST, Battery Saver)", lowest, nlevels);
            }
        }
    } else if (c->held) {
        c->floor = 0; c->held = 0; kind = NVN_DRS_RELEASE;
        snprintf(w, n, "lowest-resolution hold off (DM_DRS_LOWEST): back to full size, the GPU headroom rules again");
    }
    if (kind) {
        c->chk_level = -1; c->over_n = c->clock_n = c->under_n = c->clock_steps = 0; c->last_change = now;
        snprintf(c->last_why, sizeof c->last_why, "%s", w);
    }
    if ((uint32_t)c->floor < c->s_floor_lo) c->s_floor_lo = (uint32_t)c->floor;
    if ((uint32_t)c->floor > c->s_floor_hi) c->s_floor_hi = (uint32_t)c->floor;
    return kind;
}
// One window ending at now (ns): busy the GPU's load (above: the busy share times target / fps, 0..2), pclk the performance cores' clock in GHz (<= 0: no figure), level the level the game runs at (0 = full size),
// nlevels its level count (0: unknown, nothing moves). Returns NVN_DRS_NONE or the kind of step taken; c->floor is the new floor and why (if not NULL) the reason
static inline int nvn_drs_gpu_window(nvn_drs_gpu *c, uint64_t now, double busy, double pclk, int level, int nlevels, char *why, size_t n) {
    if (why && n) why[0] = 0;
    if (c->hold || c->held) {   // Battery Saver's lowest-resolution hold, or the window that ends it: no rule runs
        char hw[128] = ""; int k = nvn_drs_gpu_hold_window(c, now, busy, pclk, nlevels, hw, sizeof hw);
        if (k && why && n) snprintf(why, n, "%s", hw);
        return k;
    }
    if (!c->target_pm) return NVN_DRS_NONE;
    int bpm = (int)(busy * 1000 + 0.5);
    if (pclk > c->clk_max) c->clk_max = pclk;
    int pinned = pclk > 0 && c->clk_max >= NVN_DRS_CLOCK_MIN_MAX && pclk <= NVN_DRS_CLOCK_FLOOR * c->clk_max;
    if (bpm > c->target_pm && c->gpu_room) c->s_room++;
    c->over_n = bpm > c->target_pm && !c->gpu_room ? c->over_n + 1 : 0;
    c->clock_n = pinned && bpm >= NVN_DRS_CLOCK_BUSY_PM ? c->clock_n + 1 : 0;
    c->under_n = bpm < c->target_pm - NVN_DRS_BAND_PM && !pinned ? c->under_n + 1 : 0;
    if (!pinned) c->clock_steps = 0;
    c->s_win++; c->s_busy_sum += busy; if (busy > c->s_busy_max) c->s_busy_max = busy;
    if (pclk > 0 && pclk < c->s_clk_min) c->s_clk_min = pclk;
    int kind = NVN_DRS_NONE, lowest = nlevels > 0 ? (nlevels - 1 < NVN_DRS_LEVELS - 1 ? nlevels - 1 : NVN_DRS_LEVELS - 1) : 0;
    if (level < 0) level = 0;
    if (c->floor > lowest) c->floor = lowest;
    uint64_t since = c->last_change ? now - c->last_change : ~0ull;
    int followed = level >= c->floor;   // the game has reached the floor (it steps after its own counters)
    char w[128] = "";
    // the check of the last step down: measured once the game runs at the new level
    int undo = 0;
    if (c->chk_level >= 0) {
        if (level > c->chk_level) {
            if (c->chk_skip) c->chk_skip--;
            else {
                c->chk_n++; c->chk_sum += bpm; if (!pinned) c->chk_freed = 1;
                int k = c->chk_clock, from = c->chk_level, mean = (c->chk_sum + c->chk_n / 2) / c->chk_n;
                if (k && c->chk_freed) c->chk_level = -1;   // the clock came back: the step stands
                else if (c->chk_n >= (k ? NVN_DRS_GAIN_CLOCK_N : NVN_DRS_GAIN_N)) {
                    if ((k || mean > c->chk_busy - NVN_DRS_GAIN_PM) && c->floor == from + 1) {
                        uint64_t h = c->nogain_hold[k][from];
                        c->nogain_hold[k][from] = c->nogain_at[k][from] && now - c->nogain_at[k][from] < NVN_DRS_NOGAIN_MAX && h ? (2 * h < NVN_DRS_NOGAIN_MAX ? 2 * h : NVN_DRS_NOGAIN_MAX) : NVN_DRS_NOGAIN0;
                        c->nogain_at[k][from] = now; c->floor = from; undo = 1;
                        if (k) snprintf(w, sizeof w, "no gain: performance cores still at %.2f GHz %d windows after the step from level %d; no clock step from it or a smaller picture for %.0f s",
                                        pclk, c->chk_n, from, c->nogain_hold[k][from] / 1e9);
                        else snprintf(w, sizeof w, "no gain: GPU load %d%% at level %d against %d%% at level %d; no step down from it or a smaller picture for %.0f s",
                                      (mean + 5) / 10, from + 1, (c->chk_busy + 5) / 10, from, c->nogain_hold[k][from] / 1e9);
                    }
                    c->chk_level = -1;
                }
            }
        } else if (now - c->chk_at >= NVN_DRS_GAIN_WAIT) c->chk_level = -1;
    }
    int checking = c->chk_level >= 0, held[2] = {0, 0};
    for (int k = 0; k < 2; k++) for (int l = 0; l <= level && l < NVN_DRS_LEVELS; l++) if (c->nogain_at[k][l] && now - c->nogain_at[k][l] < c->nogain_hold[k][l]) held[k] = 1;
    if (undo) {
        kind = NVN_DRS_UNDO;
    } else if (nlevels > 0 && !checking && !held[0] && followed && level < lowest && c->over_n >= NVN_DRS_OVER_N && since >= NVN_DRS_DOWN_DWELL) {
        kind = NVN_DRS_DOWN_BUSY; nvn_drs_gpu_trip(c, level, now); c->floor = level + 1;
        c->chk_busy = c->prev_bpm > 0 ? (c->prev_bpm + bpm + 1) / 2 : bpm;
        snprintf(w, sizeof w, "GPU load %d%% > %d%%", (bpm + 5) / 10, c->target_pm / 10);
    } else if (nlevels > 0 && !checking && !held[1] && followed && level < lowest && c->clock_n >= NVN_DRS_CLOCK_N && since >= NVN_DRS_CLOCK_DWELL && c->clock_steps < NVN_DRS_CLOCK_MAX) {
        kind = NVN_DRS_DOWN_CLOCK; c->clock_steps++; nvn_drs_gpu_trip(c, level, now); c->floor = level + 1; c->chk_busy = bpm;
        snprintf(w, sizeof w, "CPU clock floor (performance cores %.2f of %.2f GHz) with GPU load %d%%", pclk, c->clk_max, (bpm + 5) / 10);
    } else if (c->floor > 0 && c->under_n >= NVN_DRS_UNDER_N && since >= NVN_DRS_UP_DWELL) {
        int to = c->floor - 1;
        if (!c->trip_at[to] || now - c->trip_at[to] >= c->backoff[to]) {
            kind = NVN_DRS_UP; c->floor = to;
            snprintf(w, sizeof w, "GPU load %d%% < %d%% for %d windows", (bpm + 5) / 10, (c->target_pm - NVN_DRS_BAND_PM) / 10, c->under_n);
        }
    }
    if (kind == NVN_DRS_DOWN_BUSY || kind == NVN_DRS_DOWN_CLOCK) { c->chk_level = level; c->chk_n = c->chk_sum = c->chk_freed = 0; c->chk_skip = c->settle_n; c->chk_at = now; c->chk_clock = kind == NVN_DRS_DOWN_CLOCK; }
    c->prev_bpm = bpm;
    if (kind) {
        c->last_change = now; c->over_n = c->clock_n = c->under_n = 0;
        if (kind == NVN_DRS_DOWN_BUSY) c->s_down_busy++; else if (kind == NVN_DRS_DOWN_CLOCK) c->s_down_clock++; else if (kind == NVN_DRS_UNDO) c->s_undo++; else c->s_up++;
        snprintf(c->last_why, sizeof c->last_why, "%s", w);
        if (why && n) snprintf(why, n, "%s", w);
    }
    if ((uint32_t)c->floor < c->s_floor_lo) c->s_floor_lo = (uint32_t)c->floor;
    if ((uint32_t)c->floor > c->s_floor_hi) c->s_floor_hi = (uint32_t)c->floor;
    return kind;
}
// The summary since the last call, for the dynamic-resolution line: "GPU headroom (target 75%): floor 2 (0–3), GPU busy mean 71% max 88%, performance cores down to
// 1.44 GHz; 3 down (2 GPU busy, 1 clock floor), 1 up; last: GPU busy 81% > 75%"; then a new summary window
static inline size_t nvn_drs_gpu_summary(nvn_drs_gpu *c, char *out, size_t n) {
    if (!n) return 0;
    size_t o;
    if (c->s_held && c->s_win) {   // the lowest-resolution hold for some of the window
        o = (size_t)snprintf(out, n, "GPU headroom %s at the lowest level (DM_DRS_LOWEST, Battery Saver) for %u of %u windows: floor %d (%u–%u), GPU load mean %.0f%% max %.0f%%",
                             c->held ? "held" : "was held", c->s_held, c->s_win, c->floor, c->s_floor_lo, c->s_floor_hi, 100 * c->s_busy_sum / c->s_win, 100 * c->s_busy_max);
        if (o < n && c->s_clk_min < 1e8) o += (size_t)snprintf(out + o, n - o, ", performance cores down to %.2f GHz", c->s_clk_min);
    }
    else if (!c->target_pm) o = (size_t)snprintf(out, n, "GPU headroom off (DM_DRS_GPU_TARGET=0)");
    else if (!c->s_win) o = (size_t)snprintf(out, n, "GPU headroom (target %d%%): floor %d, no window measured", c->target_pm / 10, c->floor);
    else {
        o = (size_t)snprintf(out, n, "GPU headroom (target %d%%): floor %d (%u–%u), GPU load mean %.0f%% max %.0f%%", c->target_pm / 10, c->floor, c->s_floor_lo, c->s_floor_hi,
                             100 * c->s_busy_sum / c->s_win, 100 * c->s_busy_max);
        if (o < n && c->s_clk_min < 1e8) o += (size_t)snprintf(out + o, n - o, ", performance cores down to %.2f GHz", c->s_clk_min);
        if (o < n) o += (size_t)snprintf(out + o, n - o, "; %u down (%u GPU load, %u clock floor), %u up, %u back for no gain", c->s_down_busy + c->s_down_clock, c->s_down_busy, c->s_down_clock, c->s_up, c->s_undo);
        if (o < n && c->s_room) o += (size_t)snprintf(out + o, n - o, "; %u windows over the target left alone with the GPU clock low and the frames on time", c->s_room);
        if (o < n && c->last_why[0]) o += (size_t)snprintf(out + o, n - o, "; last: %s", c->last_why);
    }
    c->s_win = c->s_room = c->s_down_busy = c->s_down_clock = c->s_up = c->s_undo = c->s_held = 0; c->s_floor_lo = ~0u; c->s_floor_hi = 0; c->s_busy_sum = c->s_busy_max = 0; c->s_clk_min = 1e9;
    return o < n ? o : n - 1;
}
