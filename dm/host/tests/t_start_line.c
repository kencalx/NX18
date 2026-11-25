// The start's timeline in the log (start_line.h): DM_PLAY_AT's value, the Play line in local time, the three parts of Play to the first frame (each at least 0, adding up to the
// total, the prepare step cut to what is left after the load) and the first-frame line, in the forms scripts/devlog.py reads (dm/tools/tests/test_devlog.py reads these lines too)
#include "../start_line.h"
#include <math.h>
#include <stdio.h>
#include <string.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)
static int near(double a, double b) { return fabs(a - b) < 1e-9; }

int main(void) {
    setenv("TZ", "UTC", 1); tzset();
    CHECK(sl_play_at(NULL) == 0 && sl_play_at("") == 0, "unset or empty: no Play time");
    CHECK(near(sl_play_at("1794791731.204000"), 1794791731.204), "seconds since 1970 with a fraction");
    CHECK(near(sl_play_at("1794791731"), 1794791731.0), "whole seconds");
    CHECK(sl_play_at("12.5") == 0 && sl_play_at("1794791731x") == 0 && sl_play_at("now") == 0 && sl_play_at("-1794791731") == 0, "not such a time: none");
    char line[200];
    sl_play_line(line, sizeof line, 1794791731.204, "the launcher's Play");
    CHECK(!strcmp(line, "start: Play at 2026-11-16 01:15:31.204 local time (the launcher's Play)"), "the Play line, to the millisecond (TZ=UTC here)");
    sl_play_line(line, sizeof line, 1794791731.9999, "x");
    CHECK(strstr(line, ":31.999 ") != NULL, "a fraction is cut, not rounded up into the next second");
    // Play at 0, the game's code at 0.21 s, a prepare of 8.09 s, the first frame on screen at 9.84 s
    sl_parts p = sl_split(1000000000ull, 1210000000ull, 8090000000ull, 10840000000ull);
    CHECK(near(p.total, 9.84) && near(p.load, 0.21) && near(p.prepare, 8.09) && near(p.first, 1.54), "the three parts");
    CHECK(near(p.load + p.prepare + p.first, p.total), "they add up to the total");
    sl_first_line(line, sizeof line, p);
    CHECK(!strcmp(line, "start: first frame 9.84 s after Play: host load 0.21 s, prepare 8.09 s, first frame 1.54 s"), "the first-frame line");
    p = sl_split(5000000000ull, 4000000000ull, 0, 6500000000ull);
    CHECK(near(p.load, 0) && near(p.total, 1.5) && near(p.first, 1.5), "the game started before Play (iOS: Play set after the host's start): no load");
    p = sl_split(1000000000ull, 2000000000ull, 9000000000ull, 4000000000ull);
    CHECK(near(p.load, 1) && near(p.prepare, 2) && near(p.first, 0) && near(p.total, 3), "a prepare longer than what is left after the load is cut to it");
    p = sl_split(5000000000ull, 6000000000ull, 0, 4000000000ull);
    CHECK(near(p.total, 0) && near(p.load, 0) && near(p.prepare, 0) && near(p.first, 0), "a first frame before Play (a clock that went back): all 0, nothing negative");
    printf("start line: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
