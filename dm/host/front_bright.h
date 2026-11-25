// The iOS front end's brightness lines (front_ios.m), logging only, for the X2.0 heat ladder's first phone runs (M1): a line for every
// brightness change of the device's own screen, and DM_BRIGHT_PROBE, which sets the brightness once to answer whether an app's own set posts UIScreenBrightnessDidChangeNotification,
// whether iOS keeps the app's value with Auto-Brightness on, and whether a low value holds. Pure helpers, so the Mac's unit tests run them (tests/t_front_bright.c); the front end
// calls them on the main thread only
#pragma once
#include <math.h>
#include <stdlib.h>

// DM_BRIGHT_PROBE=<value>: the brightness the probe sets, 0.05 to 1.0. Returns it; 0 when unset, empty or 0 (no probe, the repository's off); -1 for any other value (not a number,
// trailing text, out of range), which the front end refuses with a red line
static inline double front_bright_probe_value(const char *v) {
    if (!v || !*v) return 0;
    char *end; double x = strtod(v, &end);
    while (*end == ' ' || *end == '\t' || *end == '\r' || *end == '\n') end++;
    if (end == v || *end) return -1;
    if (x == 0) return 0;
    return x >= 0.05 && x <= 1.0 ? x : -1;   // a NaN fails both tests
}

// The change lines' guard against a storm (Auto-Brightness moves every 1-3 min, a drag of Control Center's slider posts many): at most FRONT_BRIGHT_BURST lines in a window of
// FRONT_BRIGHT_WINDOW_S seconds from the first of them. A change past that gets no line; the next line says how many were not logged. So that the value a storm settles on is not left
// to the next change (minutes later after a slider drag), the first change skipped while no trailing line is pending asks for one: the caller runs front_bright_rate_flush
// FRONT_BRIGHT_WINDOW_S later, which logs the screen's value then with the changes not logged, unless a line since has already counted them
enum { FRONT_BRIGHT_BURST = 4 };
#define FRONT_BRIGHT_WINDOW_S 1.0
typedef struct { double t0; unsigned n, skipped; int trailing; } front_bright_rate;
// Whether the change at t (seconds since launch) gets its line; when it does, *skipped is the changes not logged since the line before (0 almost always), and that count starts again.
// *trail is 1 when the caller is to schedule the trailing line (a skipped change with none pending), else 0
static inline int front_bright_rate_take(front_bright_rate *r, double t, unsigned *skipped, int *trail) {
    *trail = 0;
    if (!r->n || t - r->t0 >= FRONT_BRIGHT_WINDOW_S || t < r->t0) { r->t0 = t; r->n = 0; }
    if (r->n >= FRONT_BRIGHT_BURST) { r->skipped++; if (!r->trailing) r->trailing = *trail = 1; return 0; }
    r->n++; *skipped = r->skipped; r->skipped = 0;
    return 1;
}
// The trailing line, FRONT_BRIGHT_WINDOW_S after the skipped change that asked for it: the changes not logged since the last line (0: a line since has counted them, so no trailing
// line), and that count starts again. The next skipped change asks for a trailing line again
static inline unsigned front_bright_rate_flush(front_bright_rate *r) {
    unsigned k = r->skipped; r->skipped = 0; r->trailing = 0;
    return k;
}

// A notification that matches the probe's own set: at most FRONT_BRIGHT_OWN_S seconds after it (or during the set call itself, dt 0) and within 0.01 of its value. The heat ladder's
// planned own-change rule takes 0.5 s; the probe counts within 1 s and logs each notification's delay, so M1 can set the real window
#define FRONT_BRIGHT_OWN_S 1.0
static inline int front_bright_ours(double value, double target, double dt) { return dt >= 0 && dt <= FRONT_BRIGHT_OWN_S && fabs(value - target) <= 0.01; }
