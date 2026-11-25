// The iOS front end's brightness lines (../front_bright.h, front_ios.m), logging only: DM_BRIGHT_PROBE's value (0.05 to 1.0; unset, empty or 0 is no probe; anything else is
// refused), the change lines' storm guard (at most FRONT_BRIGHT_BURST lines a second, the next line or a trailing one counting those not logged) and the probe's own-set match
#include "../front_bright.h"
#include <stdio.h>
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)
int main(void) {
    CHECK(front_bright_probe_value(NULL) == 0 && front_bright_probe_value("") == 0, "unset or empty: no probe");
    CHECK(front_bright_probe_value("0") == 0 && front_bright_probe_value("0.0") == 0, "0: no probe, the repository's off");
    CHECK(front_bright_probe_value("0.27") == 0.27 && front_bright_probe_value("1") == 1.0 && front_bright_probe_value("0.05") == 0.05, "a value from 0.05 to 1.0 is taken");
    CHECK(front_bright_probe_value("0.27\r\n") == 0.27 && front_bright_probe_value(" 0.5 ") == 0.5, "spaces and an env.txt line's end around it are fine");
    CHECK(front_bright_probe_value("0.04") == -1 && front_bright_probe_value("1.01") == -1 && front_bright_probe_value("-0.3") == -1 && front_bright_probe_value("27") == -1, "out of range: refused");
    CHECK(front_bright_probe_value("abc") == -1 && front_bright_probe_value("0.27x") == -1 && front_bright_probe_value("0.2 7") == -1, "not a number, or trailing text: refused");
    CHECK(front_bright_probe_value("nan") == -1 && front_bright_probe_value("inf") == -1, "NaN and infinity: refused");

    front_bright_rate r = {0}; unsigned sk = 99; int logged = 0, tr = 0, trails = 0;
    CHECK(front_bright_rate_take(&r, 10.0, &sk, &tr) && sk == 0 && !tr, "the first change gets its line");
    for (int i = 1; i < 10; i++) { logged += front_bright_rate_take(&r, 10.0 + i * 0.05, &sk, &tr); trails += tr; }   // a slider drag: 9 more changes in 0.45 s
    CHECK(logged == FRONT_BRIGHT_BURST - 1, "a storm: at most FRONT_BRIGHT_BURST lines in the window");
    CHECK(trails == 1, "the storm's first skipped change asks for one trailing line, the others none");
    CHECK(front_bright_rate_take(&r, 11.0, &sk, &tr) && sk == 10 - FRONT_BRIGHT_BURST && !tr, "the next window's first line counts the changes not logged");
    CHECK(front_bright_rate_flush(&r) == 0, "the trailing line after a line that counted them: nothing to log");
    CHECK(front_bright_rate_take(&r, 11.1, &sk, &tr) && sk == 0, "and the count starts again");

    for (int i = 0; i < 8; i++) front_bright_rate_take(&r, 50.0 + i * 0.05, &sk, &tr);   // a drag that ends: its last 4 values not logged
    CHECK(front_bright_rate_flush(&r) == 4, "the trailing line, a window later: the 4 changes not logged, the value the drag settled on");
    CHECK(front_bright_rate_take(&r, 200.0, &sk, &tr) && sk == 0, "the next change starts with no count: the trailing line had it");
    for (int i = 0; i < 5; i++) front_bright_rate_take(&r, 300.0, &sk, &tr);
    CHECK(tr, "after a trailing line, the next storm asks for another");
    front_bright_rate_flush(&r);

    CHECK(front_bright_rate_take(&r, 400.0, &sk, &tr) && sk == 0, "Auto-Brightness, minutes apart: every change logged");
    for (int i = 0; i < 4; i++) front_bright_rate_take(&r, 500.0, &sk, &tr);
    CHECK(!front_bright_rate_take(&r, 500.0, &sk, &tr), "several in the same instant: past the burst, none");
    CHECK(front_bright_rate_take(&r, 499.0, &sk, &tr) && sk == 1, "a clock that went back starts a window, never stalls the lines");

    CHECK(front_bright_ours(0.27, 0.27, 0) && front_bright_ours(0.275, 0.27, 0.4), "the set's own: its value within 0.01, inside the set call or soon after");
    CHECK(!front_bright_ours(0.27, 0.27, FRONT_BRIGHT_OWN_S + 0.1) && !front_bright_ours(0.29, 0.27, 0.1) && !front_bright_ours(0.27, 0.27, -0.1), "late, another value, or before the set: not ours");
    printf("t_front_bright: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
