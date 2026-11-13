// Yield storms (hle_thread.c ystorm_note, DM_YIELD_STORM), through real yield SVCs on one guest thread, on a test clock that only guest work, sleeps and yields advance (nanosleep moves
// it by the time asked, sched_yield by 0.5 µs), so where each storm starts and how often it sleeps is exact. A storm: yields with no other SVC and under 2 µs of guest work between two,
// for more than 500 µs. count (the default) counts them and changes nothing; sleep makes each further yield sleep up to 50 µs; 0 does neither. The clock moving by each sleep's
// length checks that the sleeps are taken, also those of 20 µs or less, which sleep_precise would skip
#include "../dm.h"
#include <assert.h>
#include <stdatomic.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

static _Atomic uint64_t clk = 1000000000ull;
static uint64_t test_now_ns(void) { return atomic_load(&clk); }
static int test_nanosleep(const struct timespec *ts, struct timespec *rem) { (void)rem; atomic_fetch_add(&clk, (uint64_t)ts->tv_sec * 1000000000ull + (uint64_t)ts->tv_nsec); return 0; }
static int test_sched_yield(void) { atomic_fetch_add(&clk, 500); return 0; }
#define now_ns test_now_ns
#define nanosleep test_nanosleep
#define sched_yield test_sched_yield
#include "../hle_thread.c"
#undef now_ns
#undef nanosleep
#undef sched_yield

static thr_t *self(void) { thr_t *me = pthread_getspecific(g_keythr); assert(me); return me; }
static void other_svc(void) { uint64_t r[32] = {0, self()->handle}; svc_thread(0x0C, r); }   // GetThreadPriority: other work between yields
// One pass of a loop: `work` ns of guest code, then a yield; `move` changes x19 at each pass (a spin counter: the yield returns at once), else the registers stay (a poll)
static uint64_t pass_n;
static void pass(uint64_t work, int move) {
    atomic_fetch_add(&clk, work);
    uint64_t r[32] = {0}; for (int i = 19; i <= 28; i++) r[i] = 0x1000 + (uint64_t)i;
    if (move) r[19] = ++pass_n;
    svc_thread(0x0B, r);
}
static void loop_for(uint64_t ns, uint64_t work, int move) { uint64_t t0 = test_now_ns(); while (test_now_ns() - t0 < ns) pass(work, move); }
typedef struct { uint64_t storms, storm_ns, sleeps, backoff, moved; } snap;
static snap now_counts(void) { thr_t *m = self(); return (snap){m->nstorm, m->storm_ns, m->nstsleep, m->nbackoff, m->nmoved}; }
static void mode(const char *v) { if (v) setenv("DM_YIELD_STORM", v, 1); else unsetenv("DM_YIELD_STORM"); g_ys_mode = -1; }

int main(void) {
    alarm(20);
    svc_thread_main_init();
    char line[512];

    // count (the default): a spin loop of 0.5 µs passes for 2 ms is one storm of 2 ms (from its first yield to its last), every yield moved on, and no sleep: the clock moved by the guest work alone
    mode(NULL); assert(ystorm_mode() == (DM_GAME_YIELD_STORM ? 2 : 1));
    if (ystorm_mode() == 1) {
        dm_yield_top(line, sizeof line);
        other_svc(); snap a = now_counts(); uint64_t t0 = test_now_ns(), n0 = self()->nyield;
        loop_for(2000000, 500, 1);
        snap b = now_counts(); uint64_t n = self()->nyield - n0;
        printf("  count: %llu yields, %llu storms, %.3f ms in storms\n", (unsigned long long)n, (unsigned long long)(b.storms - a.storms), (b.storm_ns - a.storm_ns) / 1e6);
        assert(b.storms - a.storms == 1);
        assert(b.storm_ns - a.storm_ns >= 1990000 && b.storm_ns - a.storm_ns <= 2000000);
        assert(b.sleeps == a.sleeps && b.backoff == a.backoff && b.moved - a.moved == n - 1);   // the first yield follows another SVC: a plain sched_yield, as before
        assert(test_now_ns() - t0 == n * 500 + 500);   // nothing but the guest work and that one sched_yield moved the clock: no sleep
        dm_yield_top(line, sizeof line); puts(line);
        assert(strstr(line, "yield storms 1, 2 ms") && !strstr(line, "storm sleeps"));
        puts("PASS: count mode counts a 2 ms spin of moving yields as one storm and changes nothing");

        // passes of 5 µs of work (a loop that works between yields), and runs that other SVCs cut every 100 µs: no storm
        other_svc(); a = now_counts();
        loop_for(2000000, 5000, 1);
        for (int i = 0; i < 20; i++) { other_svc(); loop_for(100000, 500, 1); }
        b = now_counts();
        assert(b.storms == a.storms && b.storm_ns == a.storm_ns);
        puts("PASS: yields 5 µs of work apart, or under 500 µs between other SVCs, are no storm");

        // a poll that keeps its registers: the back-off as before (plain yields for 2 ms, then its sleeps), and counted as a storm too
        other_svc(); a = now_counts();
        loop_for(3000000, 500, 0);
        b = now_counts();
        assert(b.storms - a.storms == 1 && b.backoff > a.backoff && b.sleeps == a.sleeps && b.moved == a.moved);
        puts("PASS: count mode leaves a poll's back-off as it was");
    }

    // sleep: after 500 µs each yield sleeps an eighth of the run, at most 50 µs, until other work; with these defaults every sleep is the cap (an eighth of 500 µs is 62.5 µs)
    mode("sleep"); assert(ystorm_mode() == 2);
    other_svc(); snap a = now_counts(); uint64_t t0 = test_now_ns(), first = 0, n0 = self()->nyield;
    while (test_now_ns() - t0 < 2000000) { uint64_t s0 = self()->nstsleep, before = test_now_ns(); pass(500, 1); if (!first && self()->nstsleep != s0) first = before - t0; }
    snap b = now_counts();
    printf("  sleep: first sleep %.1f µs into the run, %llu sleeps in 2 ms\n", first / 1e3, (unsigned long long)(b.sleeps - a.sleeps));
    assert(first >= 500000 && first < 501000);
    assert(b.sleeps - a.sleeps >= 25 && b.sleeps - a.sleeps <= 32);   // 1.5 ms at 50 µs and a pass each
    assert(test_now_ns() - t0 == (self()->nyield - n0) * 500 + 500 + (b.sleeps - a.sleeps) * 50000);   // the guest work, the first yield's sched_yield and 50 µs a sleep
    dm_yield_top(line, sizeof line); puts(line);
    assert(strstr(line, "; storm sleeps "));
    other_svc(); a = now_counts(); t0 = test_now_ns();
    loop_for(400000, 500, 1);
    assert(now_counts().sleeps == a.sleeps);
    puts("PASS: sleep mode sleeps from 500 µs into a storm, up to 50 µs a yield, and starts over after other work");

    // sleep: a poll that keeps its registers sleeps as a storm from 500 µs, and from 2 ms takes the back-off's longer sleeps instead
    other_svc(); a = now_counts();
    loop_for(4000000, 500, 0);
    b = now_counts();
    assert(b.sleeps > a.sleeps && b.backoff > a.backoff);
    puts("PASS: sleep mode leaves the back-off's sleeps to the back-off");

    // =<cap µs>:<start µs> (DM_YIELD_BACKOFF's order), with a cap of 20 µs, which sleep_precise alone would not sleep: each sleep moves the clock by the cap
    mode("20:200"); assert(ystorm_mode() == 2 && g_ys_start == 200000 && g_ys_cap == 20000);
    other_svc(); a = now_counts(); t0 = test_now_ns(); first = 0; n0 = self()->nyield;
    while (test_now_ns() - t0 < 1000000) { uint64_t s0 = self()->nstsleep, before = test_now_ns(); pass(500, 1); if (!first && self()->nstsleep != s0) first = before - t0; }
    b = now_counts();
    assert(first >= 200000 && first < 201000);
    assert(b.sleeps > a.sleeps && test_now_ns() - t0 == (self()->nyield - n0) * 500 + 500 + (b.sleeps - a.sleeps) * 20000);
    puts("PASS: =<cap>:<start> sets both, and a cap of 20 µs sleeps 20 µs a yield");

    // a start under 8 caps: the sleep is an eighth of the run so far, never under 10 µs, up to the cap (=40:40: 10 µs from 40 µs into the storm, 40 µs from 320 µs on)
    mode("40:40"); assert(ystorm_mode() == 2 && g_ys_start == 40000 && g_ys_cap == 40000);
    other_svc(); a = now_counts(); t0 = test_now_ns(); n0 = self()->nyield;
    uint64_t lo = UINT64_MAX, hi = 0;
    while (test_now_ns() - t0 < 1000000) {
        uint64_t s0 = self()->nstsleep, before = test_now_ns(); pass(500, 1);
        if (self()->nstsleep != s0) { uint64_t slept = test_now_ns() - before - 500; if (slept < lo) lo = slept; if (slept > hi) hi = slept; }
    }
    printf("  =40:40: sleeps from %.1f to %.1f µs\n", lo / 1e3, hi / 1e3);
    assert(lo == 10000 && hi == 40000);
    puts("PASS: a start under 8 caps ramps from 10 µs to the cap");

    // 0: no counting, no sleeping, the line as before
    mode("0"); assert(ystorm_mode() == 0);
    dm_yield_top(line, sizeof line);
    other_svc(); a = now_counts(); t0 = test_now_ns(); n0 = self()->nyield;
    loop_for(2000000, 500, 1);
    b = now_counts();
    assert(b.storms == a.storms && b.sleeps == a.sleeps && test_now_ns() - t0 == (self()->nyield - n0) * 500 + 500);
    dm_yield_top(line, sizeof line); puts(line);
    assert(!strstr(line, "yield storms") && strstr(line, "(back-off sleeps 0)"));
    puts("PASS: DM_YIELD_STORM=0 neither counts nor sleeps, and the line is as before");
    return 0;
}
