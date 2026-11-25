// sleep_precise (hle_thread.c) on a test clock whose nanosleep oversleeps by a set ratio, as macOS's timer slack does (1 ms sleeps take about 1.26 ms, 33 ms about 1.10 times):
// the loop (the default) and DM_SLEEP_STEP=one's one-step sleep, their nanosleep steps per call, their late ends, and the one-step sleep's fallback to the loop after a late wake.
#include "../dm.h"
#include <assert.h>
#include <stdatomic.h>
#include <stdio.h>
#include <string.h>
#include <time.h>

static _Atomic uint64_t clk = 1000000000ull;
static uint64_t slack_permille = 1260;   // what a nanosleep takes, per mille of what it asked
static uint64_t test_now_ns(void) { return atomic_load(&clk); }
static int test_nanosleep(const struct timespec *ts, struct timespec *rem) {
    (void)rem; uint64_t ns = (uint64_t)ts->tv_sec * 1000000000ull + (uint64_t)ts->tv_nsec;
    atomic_fetch_add(&clk, ns * slack_permille / 1000); return 0;
}
#define now_ns test_now_ns
#define nanosleep test_nanosleep
#include "../hle_thread.c"
#undef now_ns
#undef nanosleep

static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
// n sleeps of len ns; the steps per call and the late ends they took
static double run(int n, uint64_t len, uint64_t *late) {
    uint64_t s0 = g_sp_steps, c0 = g_sp_calls, l0 = g_sp_late;
    for (int i = 0; i < n; i++) sleep_precise(test_now_ns() + len);
    *late = g_sp_late - l0; return (double)(g_sp_steps - s0) / (double)(g_sp_calls - c0);
}

int main(void) {
    uint64_t late;
    // The switch's values
    static const struct { const char *v; int mode; } vs[] = {{NULL, 0}, {"", 0}, {"loop", 0}, {"0", 0}, {"one", 1}, {"1", 1}, {"ab", 0}, {"fast", 0}};
    for (unsigned i = 0; i < sizeof vs / sizeof vs[0]; i++) {
        if (vs[i].v) setenv("DM_SLEEP_STEP", vs[i].v, 1); else unsetenv("DM_SLEEP_STEP");
        sp_mode_init(); CHECK(g_sp_mode == vs[i].mode, vs[i].v ? vs[i].v : "unset");
    }
    unsetenv("DM_SLEEP_STEP"); CHECK(sp_mode() == 0, "unset: the loop, the default");

    // The loop: about 2-3 steps for a 1 ms sleep, never late
    double loop1 = run(1000, 1000000, &late);
    printf("loop: 1 ms sleeps at 1.26x slack take %.2f steps\n", loop1);
    CHECK(loop1 >= 2 && late == 0, "the loop takes two steps or more for 1 ms and is never late");
    slack_permille = 1100; double loop33 = run(200, 33000000, &late); slack_permille = 1260;
    printf("loop: 33 ms sleeps at 1.10x slack take %.2f steps\n", loop33);
    CHECK(loop33 >= 3 && late == 0, "and three or more for 33 ms");

    // DM_SLEEP_STEP=one: after the first sleeps, one step a sleep, and never late at a steady slack
    g_sp_mode = 1; uint64_t oc0 = g_sp_one_calls;
    run(20, 1000000, &late);   // learns this thread's overshoot
    double one1 = run(1000, 1000000, &late);
    printf("one: 1 ms sleeps at 1.26x slack take %.2f steps (%llu late)\n", one1, (unsigned long long)late);
    CHECK(one1 < 1.2 && late == 0, "one step for 1 ms, none late");
    CHECK(g_sp_one_calls - oc0 == 1020, "every call took the one-step sleep");
    slack_permille = 1100; double one33 = run(200, 33000000, &late);
    printf("one: 33 ms sleeps at 1.10x slack take %.2f steps (%llu late)\n", one33, (unsigned long long)late);
    CHECK(one33 < loop33 && late == 0, "fewer steps than the loop for 33 ms, none late");
    {   // mixed lengths: a sound thread's 1 ms and 33 ms sleeps, each at its own slack
        uint64_t s0 = g_sp_steps, c0 = g_sp_calls, l0 = g_sp_late;
        for (int i = 0; i < 400; i++) { int s = i & 1; slack_permille = s ? 1100 : 1260; sleep_precise(test_now_ns() + (s ? 33000000 : 1000000)); }
        double mix = (double)(g_sp_steps - s0) / (double)(g_sp_calls - c0);
        printf("one: mixed 1 and 33 ms sleeps take %.2f steps (%llu late)\n", mix, (unsigned long long)(g_sp_late - l0));
        CHECK(mix < (loop1 + loop33) / 2 && g_sp_late == l0, "mixed lengths: fewer steps than the loop, none late");
    }
    // A wake far later than planned: counted late, and the thread takes the loop alone for its next SP_FALLBACK sleeps
    slack_permille = 1260; run(50, 1000000, &late);
    uint64_t fb0 = g_sp_fallback, lm0 = g_sp_late_max;
    slack_permille = 2000; run(1, 1000000, &late); slack_permille = 1260;
    CHECK(late == 1 && g_sp_fallback == fb0 + 1 && t_sp_loop == SP_FALLBACK, "a late one-step wake is counted and sends the thread back to the loop");
    CHECK(g_sp_late_max > lm0 && g_sp_late_max >= SP_LATE_NS, "its lateness is the largest");
    oc0 = g_sp_one_calls; double fb = run(SP_FALLBACK, 1000000, &late);
    CHECK(g_sp_one_calls == oc0 && fb >= 2 && late == 0, "the next sleeps take the loop alone");
    run(1, 1000000, &late); CHECK(g_sp_one_calls == oc0 + 1, "then the one-step sleep again");
    CHECK(t_sp_q[sp_bucket(1000000)] >= 1024 * 19 / 10 && t_sp_q[sp_bucket(33000000)] < 1200, "planned for the larger overshoot it saw at that length alone");

    // A sleep under SP_ONE_MIN_NS takes no one-step: the loop sleeps it all, so it is not counted as a one-step call, and its late wake does not send the thread back to the loop
    {   uint64_t oc = g_sp_one_calls, os = g_sp_one_steps, fb1 = g_sp_fallback; CHECK(t_sp_loop == 0, "the one-step sleep is on before the short sleep");
        slack_permille = 4000; run(1, 50000, &late); slack_permille = 1260;
        CHECK(late == 1, "a 50 µs sleep woken 150 µs late is counted late");
        CHECK(g_sp_one_calls == oc && g_sp_one_steps == os, "but not as a one-step call");
        CHECK(g_sp_fallback == fb1 && t_sp_loop == 0, "and the one-step sleep stays on for the thread's next sleeps");
        run(1, 1000000, &late); CHECK(g_sp_one_calls == oc + 1, "its next 1 ms sleep takes the one-step sleep"); }

    // The threads line: precise sleeps, their late ends, and the one-step share
    { char out[4096]; dm_wake_stats(out, sizeof out, 1);
      CHECK(strstr(out, "precise sleeps") && strstr(out, "nanosleep steps") && strstr(out, "late by over 100 µs"), "the line keeps the counter and adds the late ends");
      CHECK(strstr(out, "DM_SLEEP_STEP=one: one-step") != NULL, "and the one-step share");
      g_sp_mode = 0; dm_wake_stats(out, sizeof out, 1);
      CHECK(!strstr(out, "DM_SLEEP_STEP") && strstr(out, "same-core handoffs"), "the default's line has no one-step share"); }
    printf("t_sleep_step: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
