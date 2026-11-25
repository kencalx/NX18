// The frame workgroup's calls from hle_nvn.c (frame_wg_on; docs/reference/frame-rate.md, A frame deadline told through a work interval), counted by t_framewg_count.c's stand-ins.
// Three runs (check_t_nvn_framewg): with DM_FRAME_WG=1 the thread that acquires the window texture joins when its policy is set, acquires within one frame finish and start
// once, the start's deadline is the real-time period, an acquire that moves to another thread with the same period sets the policy and joins there (before, it only skipped),
// one that comes back to a thread that joined calls no join, and a replay thread joins at its first declaration only. With DM_FRAME_WG=1 DM_RT=0 (--rt-off) and with
// DM_FRAME_WG=0 (--off) nothing is called. DM_FRAME_WG_PERIOD (frame_wg_period): its parse in every run; unset, the deadline at the game's interval 2 is 33.333 ms as before; with
// DM_FRAME_WG_PERIOD=16 (--period) it is 16.667 ms at interval 2 and 1, and the present thread's policy and the replay threads' period follow it; with the workgroup off
// (--period-off) the switch is ignored and the period follows the interval
#include "../nvn/hle_nvn.c"
#include <dispatch/dispatch.h>
#include <time.h>
void *front_metal_layer(void) { return NULL; }   // no window in unit tests
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

extern int fwg_joins, fwg_ends, fwg_begins;
extern uint64_t fwg_last_period;
extern char fwg_last_who[64], fwg_end_on[64], fwg_begin_on[64];

static int g_fail;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got);                          \
    printf("%-72s expected %-10lld → got %-10lld %s\n", name, w_, g_, w_ == g_ ? "✓" : "✗"); if (w_ != g_) g_fail++; } while (0)

static win_t win = {.ntex = 2, .interval = 1};
static void acquire(void) { int idx; h_nvnWindowAcquireTexture((NVNwindow *)&win, NULL, &idx); }
static void acquire_twice(void) { acquire(); acquire(); }
static nvn_rtw rtw = {.name = "NVN queue replay"};
static void declare_twice(void) { rtw_declare(&rtw, 16666667ull, 4.0); rtw_declare(&rtw, 16666667ull, 5.0); }

// A thread kept alive between steps, so that an acquire can come back to it
static dispatch_semaphore_t a_go, a_done; static void (*a_fn)(void);
static void *thread_a(void *arg) {
    (void)arg; pthread_setname_np("0x1001 main thread");
    for (;;) { dispatch_semaphore_wait(a_go, DISPATCH_TIME_FOREVER); if (!a_fn) return NULL; a_fn(); dispatch_semaphore_signal(a_done); }
}
static void on_a(void (*fn)(void)) { a_fn = fn; dispatch_semaphore_signal(a_go); dispatch_semaphore_wait(a_done, DISPATCH_TIME_FOREVER); }
typedef struct { const char *name; void (*fn)(void); } job;
static void *run_job(void *arg) { job *j = arg; pthread_setname_np(j->name); j->fn(); return NULL; }
static void on_new_thread(const char *name, void (*fn)(void)) { job j = {name, fn}; pthread_t t; pthread_create(&t, NULL, run_job, &j); pthread_join(t, NULL); }
static void next_frame(void) { atomic_fetch_add(&g_frame, 1); }

int main(int argc, char **argv) {
    int rt_off = argc > 1 && !strcmp(argv[1], "--rt-off"), off = argc > 1 && !strcmp(argv[1], "--off");
    int period = argc > 1 && !strcmp(argv[1], "--period"), period_off = argc > 1 && !strcmp(argv[1], "--period-off");
    if (period || period_off) {
        setenv("DM_FRAME_WG", period ? "1" : "0", 1); setenv("DM_FRAME_WG_PERIOD", "16", 1); unsetenv("DM_RT"); unsetenv("DM_DETCLOCK"); unsetenv("DM_RT_COMP");
        nvn_present_config(60, 0); dm_fps_state = NULL;
        printf("t_nvn_framewg: DM_FRAME_WG=%s DM_FRAME_WG_PERIOD=16\n", period ? "1" : "0");
        EXPECT("the period reads (ns)", period ? 16666666 : 0, frame_wg_period());
        win.interval = 2; const uint64_t own = rt_period_ns(&win, present_period(&win));   // 33.333 ms, or 16.667 where a frame step keeps the cap's deadline (Ocarina of Time)
        on_new_thread("0x1001 main thread", acquire);
        EXPECT("interval 2: the policy's period (us)", period ? 16667 : llround(own / 1e3), llround(g_rt_period_ms * 1000));
        EXPECT("  the replay threads' period (ns)", period ? 16666666 : (long long)own, atomic_load(&g_rt_frame_ns));
        if (period) {
            EXPECT("  the workgroup's deadline (ns)", 16666666, fwg_last_period);
            EXPECT("  counted as a frame at a longer present interval where its own period is longer", own > 16666666, atomic_load(&g_wg_longer));
            win.interval = 1; next_frame(); on_new_thread("0x1001 main thread", acquire);
            EXPECT("interval 1: the same deadline (ns)", 16666666, fwg_last_period);
            EXPECT("  not counted as longer", own > 16666666, atomic_load(&g_wg_longer));
        } else EXPECT("  nothing called", 0, fwg_begins + fwg_joins);
        printf(g_fail ? "t_nvn_framewg: %d failed\n" : "t_nvn_framewg: all passed\n", g_fail);
        return g_fail != 0;
    }
    // DM_FRAME_WG_PERIOD's parse: 8, 11, 16 and 33 name 120, 90, 60 and 30 Hz's period; other values in 8-34 are milliseconds; the rest refused (UINT64_MAX), unset 0
    EXPECT("parse: unset", 0, nvn_frame_wg_period_parse(NULL) + nvn_frame_wg_period_parse(""));
    EXPECT("parse: 16 is 60 Hz's period (ns)", 16666666, nvn_frame_wg_period_parse("16"));
    EXPECT("parse: 8, 11, 33 are 120, 90, 30 Hz's", 1, nvn_frame_wg_period_parse("8") == 8333333 && nvn_frame_wg_period_parse("11") == 11111111 && nvn_frame_wg_period_parse("33") == 33333333);
    EXPECT("parse: 20 and 16.7 as written (us)", 1, nvn_frame_wg_period_parse("20") == 20000000 && nvn_frame_wg_period_parse("16.7") == 16700000);
    EXPECT("parse: 7, 35, 16ms, x refused", 1, nvn_frame_wg_period_parse("7") == UINT64_MAX && nvn_frame_wg_period_parse("35") == UINT64_MAX && nvn_frame_wg_period_parse("16ms") == UINT64_MAX && nvn_frame_wg_period_parse("x") == UINT64_MAX);
    unsetenv("DM_FRAME_WG_PERIOD");
    setenv("DM_FRAME_WG", off ? "0" : "1", 1);
    if (rt_off) setenv("DM_RT", "0", 1); else unsetenv("DM_RT");
    unsetenv("DM_DETCLOCK"); unsetenv("DM_RT_COMP");
    nvn_present_config(60, 0); dm_fps_state = NULL;
    a_go = dispatch_semaphore_create(0); a_done = dispatch_semaphore_create(0);
    pthread_t a; pthread_create(&a, NULL, thread_a, NULL);
    printf("t_nvn_framewg: %s\n", off ? "DM_FRAME_WG=0" : rt_off ? "DM_FRAME_WG=1 DM_RT=0" : "DM_FRAME_WG=1");

    if (off || rt_off) {   // nothing is armed: no join, finish or start anywhere
        EXPECT("the switch reads off", 0, frame_wg_on());
        on_a(acquire_twice); next_frame(); on_a(acquire);
        next_frame(); on_new_thread("Presentation Thread", acquire);
        set_time_constraint_comp(16666667ull, 2000000ull);
        on_new_thread("NVN queue replay", declare_twice);
        EXPECT("  joins", 0, fwg_joins);
        EXPECT("  finishes", 0, fwg_ends);
        EXPECT("  starts", 0, fwg_begins);
    } else {
        EXPECT("armed", 1, frame_wg_on());
        uint64_t rtp = rt_period_ns(&win, present_period(&win));
        on_a(acquire);
        EXPECT("first acquire: the acquiring thread joins at its policy", 1, fwg_joins);
        EXPECT("  under its own name", 0, strcmp(fwg_last_who, "0x1001 main thread"));
        EXPECT("  the open interval finished and a new one started, once each", 1, fwg_ends == 1 && fwg_begins == 1);
        EXPECT("  on that thread", 1, !strcmp(fwg_end_on, "0x1001 main thread") && !strcmp(fwg_begin_on, "0x1001 main thread"));
        EXPECT("  the deadline is the real-time period (ns)", (long long)rtp, fwg_last_period);
        EXPECT("  which is 60 Hz's at interval 1 (ns)", 16666666, rtp);
        on_a(acquire);
        EXPECT("a second acquire in the same frame: no finish or start", 1, fwg_ends == 1 && fwg_begins == 1);
        next_frame(); on_a(acquire_twice);
        EXPECT("the next frame, two acquires: one finish and one start", 1, fwg_ends == 2 && fwg_begins == 2);
        EXPECT("  no second join", 1, fwg_joins);
        next_frame(); on_new_thread("Presentation Thread", acquire);
        EXPECT("the acquire moves to another thread, same period: it joins there", 2, fwg_joins);
        EXPECT("  under that thread's name", 0, strcmp(fwg_last_who, "Presentation Thread"));
        EXPECT("  which took the policy", 0, strcmp(g_rt_name, "Presentation Thread"));
        EXPECT("  and finishes and starts there", 1, fwg_ends == 3 && fwg_begins == 3 && !strcmp(fwg_end_on, "Presentation Thread") && !strcmp(fwg_begin_on, "Presentation Thread"));
        next_frame(); on_a(acquire);
        EXPECT("back on the first thread: no join (it joined)", 2, fwg_joins);
        EXPECT("  one finish and one start there", 1, fwg_ends == 4 && fwg_begins == 4 && !strcmp(fwg_begin_on, "0x1001 main thread"));
        on_new_thread("NVN queue replay", declare_twice);
        EXPECT("a replay thread joins at its first declaration only", 3, fwg_joins);
        EXPECT("  under its name", 0, strcmp(fwg_last_who, "NVN queue replay"));
        EXPECT("  and calls no finish or start", 1, fwg_ends == 4 && fwg_begins == 4);
        win.interval = 2; next_frame(); on_a(acquire);
        EXPECT("DM_FRAME_WG_PERIOD unset: at interval 2 the deadline is the real-time period, as before (ns)", (long long)rt_period_ns(&win, present_period(&win)), fwg_last_period);
        printf("  (%.3f ms: 33.333 unless a frame step keeps its cap's deadline)\n", fwg_last_period / 1e6);
        EXPECT("  and no frame counted at a longer interval", 0, atomic_load(&g_wg_longer));
        win.interval = 1;
    }
    a_fn = NULL; dispatch_semaphore_signal(a_go); pthread_join(a, NULL);
    printf(g_fail ? "t_nvn_framewg: %d failed\n" : "t_nvn_framewg: all passed\n", g_fail);
    return g_fail != 0;
}
