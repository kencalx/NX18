// The start's timeline in the log (hle_lifecycle.c): when the player pressed Play, and how long it took from there to the game's first frame on screen, in three parts.
// Two lines, after "[dm] ":
//   start: Play at 2026-11-15 20:15:31.204 local time (the launcher's Play)
//   start: first frame 9.84 s after Play: host load 0.21 s, prepare 8.09 s, first frame 1.54 s
// Play is DM_PLAY_AT, the wall clock (seconds since 1970) the launcher sets when Play is pressed (the iPhone's Launcher.swift, the Mac's Launcher.swift; front_ios.m and the Mac
// launcher set it themselves for a start without the settings screen, and a front end that runs the host may set it too); unset, the host counts from its own start.
// The parts: host load, from Play until the host runs the game's code (the front end's hand-over, the iPhone launcher's cloud-save check, the host's loading where it had
// not finished before Play: main.c); prepare, the prepare step that held the first frame (the prewarm lists and the pairs' prebuild, nvn_mtl.m warm_start); first frame,
// the rest, until the first present completed on the GPU (the game's own start-up and loading, its first frame's work). The log had no clock before these lines: devlog.py
// reads both. Pure, so tests/t_start_line.c checks it
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <time.h>

// DM_PLAY_AT's value: seconds since 1970, a fraction allowed; 0 when unset, empty or not such a time (2001 to 5138)
static inline double sl_play_at(const char *v) {
    if (!v || !*v) return 0;
    char *e; double t = strtod(v, &e);
    return *e || !(t > 1e9 && t < 1e11) ? 0 : t;
}

// The Play line (without the "[dm] "): the wall clock in local time, to the millisecond, and where it came from
static inline int sl_play_line(char *out, size_t n, double wall, const char *how) {
    time_t s = (time_t)wall; struct tm tm;
    int ms = (int)((wall - (double)s) * 1000.0 + 1e-3); if (ms > 999) ms = 999; if (ms < 0) ms = 0;   // + a µs: .204 is 203.99… in a double
    if (!localtime_r(&s, &tm)) return snprintf(out, n, "start: Play at %.3f s since 1970 (%s)", wall, how);
    return snprintf(out, n, "start: Play at %04d-%02d-%02d %02d:%02d:%02d.%03d local time (%s)", tm.tm_year + 1900, tm.tm_mon + 1, tm.tm_mday, tm.tm_hour, tm.tm_min, tm.tm_sec, ms, how);
}

// The parts in seconds, from three moments on one monotonic clock (ns) and the prepare step's time before the first frame. Each part is at least 0 and they add up to the total:
// the game's start before Play (a clock that went back) counts as 0 load, a prepare longer than what is left after the load is cut to it
typedef struct { double total, load, prepare, first; } sl_parts;
static inline sl_parts sl_split(uint64_t play_ns, uint64_t started_ns, uint64_t prepare_ns, uint64_t shown_ns) {
    sl_parts p;
    uint64_t total = shown_ns > play_ns ? shown_ns - play_ns : 0;
    uint64_t load = started_ns > play_ns ? started_ns - play_ns : 0; if (load > total) load = total;
    uint64_t prep = prepare_ns < total - load ? prepare_ns : total - load;
    p.total = total / 1e9; p.load = load / 1e9; p.prepare = prep / 1e9; p.first = (total - load - prep) / 1e9;
    return p;
}

// The first-frame line (without the "[dm] ")
static inline int sl_first_line(char *out, size_t n, sl_parts p) {
    return snprintf(out, n, "start: first frame %.2f s after Play: host load %.2f s, prepare %.2f s, first frame %.2f s", p.total, p.load, p.prepare, p.first);
}
