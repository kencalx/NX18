// The frame workgroup (frame_wg.c; DM_FRAME_WG) on this Mac's libdispatch and kernel, the run the plan asks for before an iPhone: the interval is made, a thread with a
// time-constraint policy joins it (once: a second join of its own would be EALREADY), runs frames of a finish before a short wait and a start after it with no errors, and its
// deadlines are in mach ticks (a start in nanoseconds would be EINVAL on a machine whose ticks are not nanoseconds). A frame that runs past its short deadline counts as late. A
// thread that is not a member counts its frame as skipped (once) instead of calling start or finish, which would end the process. A finish that gets EINVAL (no interval
// started) clears the open mark, so the next begin starts one. One member can finish what another started (an acquire that moved). The member then ends without leaving: frame_wg.c's key destructor
// leaves for it before libdispatch's check, which would also end the process
#include "../frame_wg.c"
#include <assert.h>
#include <mach/mach.h>
#include <mach/thread_policy.h>
#include <unistd.h>
#include <dispatch/dispatch.h>

static int fails;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL "); } else printf("ok   "); printf(__VA_ARGS__); printf("\n"); } while (0)
static void spin_us(unsigned us) { uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); while (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0 < us * 1000ull) {} }
static int set_rt(uint64_t period_ns, uint64_t comp_ns) {   // as hle_nvn.c set_time_constraint_comp declares the acquiring thread
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    thread_time_constraint_policy_data_t p = {.period = (uint32_t)(period_ns * tb.denom / tb.numer), .computation = (uint32_t)(comp_ns * tb.denom / tb.numer),
                                              .constraint = (uint32_t)(period_ns * tb.denom / tb.numer), .preemptible = 1};
    return thread_policy_set(pthread_mach_thread_np(pthread_self()), THREAD_TIME_CONSTRAINT_POLICY, (thread_policy_t)&p, THREAD_TIME_CONSTRAINT_POLICY_COUNT);
}

static dispatch_semaphore_t open_now, outsider_done;
static int join_r, join_again, raw_again, period_ticks_ok;
static dm_frame_wg_counts after_frames, after_late, after_einval; static int open_after_einval = -1, raw_finish = -1;
static void *member(void *arg) {
    (void)arg; pthread_setname_np("0x1001 main thread");
    assert(set_rt(16666667ull, 4000000ull) == KERN_SUCCESS);
    join_r = dm_frame_wg_join("0x1001 main thread");
    join_again = dm_frame_wg_join("0x1001 main thread");   // the first answer again, no second join
    os_workgroup_join_token_s tok; raw_again = os_workgroup_join(g_wg, &tok);   // what a second join of its own gives
    for (int f = 0; f < 8; f++) {   // frames: finish, the pacing wait, start, the frame's work
        dm_frame_wg_end(); usleep(2000);
        uint64_t s = mach_absolute_time(); dm_frame_wg_begin(16666667ull);
        if (f == 0) { uint64_t want = 16666667ull * g_tb.denom / g_tb.numer, got = atomic_load(&g_deadline) - s; period_ticks_ok = got >= want && got < want + want / 100; }
        spin_us(1000);
    }
    dm_frame_wg_end(); dm_frame_wg_counts_read(&after_frames);
    dm_frame_wg_begin(500000ull); spin_us(3000); dm_frame_wg_end(); dm_frame_wg_counts_read(&after_late);   // a 0.5 ms deadline and 3 ms of work: finished late
    dm_frame_wg_begin(16666667ull); raw_finish = os_workgroup_interval_finish(g_wg, NULL);   // finished behind frame_wg.c's back: its finish then gets EINVAL (no interval started)
    dm_frame_wg_end(); open_after_einval = atomic_load(&g_open);
    dm_frame_wg_begin(16666667ull); dm_frame_wg_counts_read(&after_einval);   // so the next begin starts one; left open for the outsider
    dispatch_semaphore_signal(open_now); dispatch_semaphore_wait(outsider_done, DISPATCH_TIME_FOREVER);
    dm_frame_wg_end();
    return NULL;   // ends a member: frame_wg.c's key destructor leaves
}
static dm_frame_wg_counts outsider_c;
static void *outsider(void *arg) {   // no join: its finish and start are skipped, not called
    (void)arg; dispatch_semaphore_wait(open_now, DISPATCH_TIME_FOREVER);
    dm_frame_wg_end(); dm_frame_wg_begin(16666667ull); dm_frame_wg_counts_read(&outsider_c);
    dispatch_semaphore_signal(outsider_done); return NULL;
}
static void *standard(void *arg) {   // a thread without a time-constraint policy: Apple says only real-time threads join; logged, not required
    (void)arg; int r = dm_frame_wg_join("standard thread");
    printf("info a thread without a time-constraint policy: join %d (%s)\n", r, r ? strerror(r) : "joined");
    return NULL;
}

// The acquire that moves to another thread (hle_nvn.c sets the policy and joins there): one member starts the interval, another finishes it
static dispatch_semaphore_t m2_started, m3_done;
static int m2_join = -1, m3_join = -1, m3_finished = -1;
static void *member2(void *arg) {
    (void)arg; assert(set_rt(16666667ull, 4000000ull) == KERN_SUCCESS);
    m2_join = dm_frame_wg_join("0x1001 main thread"); dm_frame_wg_begin(16666667ull);
    dispatch_semaphore_signal(m2_started); dispatch_semaphore_wait(m3_done, DISPATCH_TIME_FOREVER); return NULL;
}
static void *member3(void *arg) {
    (void)arg; dispatch_semaphore_wait(m2_started, DISPATCH_TIME_FOREVER); assert(set_rt(16666667ull, 4000000ull) == KERN_SUCCESS);
    m3_join = dm_frame_wg_join("Presentation Thread");
    dm_frame_wg_counts c0, c1; dm_frame_wg_counts_read(&c0); dm_frame_wg_end(); dm_frame_wg_counts_read(&c1);
    m3_finished = c1.finished == c0.finished + 1 && c1.finish_err == c0.finish_err && c1.skipped == c0.skipped;
    dispatch_semaphore_signal(m3_done); return NULL;
}

static void *raw_member(void *arg) {   // joins without frame_wg.c and ends without leaving
    (void)arg; assert(set_rt(16666667ull, 4000000ull) == KERN_SUCCESS);
    static os_workgroup_join_token_s tok; int r = os_workgroup_join(g_wg, &tok); fprintf(stderr, "raw join %d\n", r); return NULL;
}

int main(int argc, char **argv) {
    if (argc > 1 && !strcmp(argv[1], "--raw-exit")) {   // the case frame_wg.c's key destructor is there for, in a process of its own
        pthread_once(&g_once, create); pthread_t t; pthread_create(&t, NULL, raw_member, NULL); pthread_join(t, NULL); return 0;
    }
    open_now = dispatch_semaphore_create(0); outsider_done = dispatch_semaphore_create(0);
    pthread_t m, o; pthread_create(&m, NULL, member, NULL); pthread_create(&o, NULL, outsider, NULL);
    pthread_join(o, NULL); pthread_join(m, NULL);
    CHECK(g_wg != NULL, "AudioWorkIntervalCreate made the interval");
    CHECK(join_r == 0, "a real-time thread joins it (%d)", join_r);
    CHECK(join_again == 0, "a second call on that thread keeps the first answer (%d)", join_again);
    CHECK(raw_again == EALREADY, "a second os_workgroup_join of its own would be EALREADY (%d)", raw_again);
    CHECK(period_ticks_ok, "the deadline is the period in mach ticks (timebase %u/%u)", g_tb.numer, g_tb.denom);
    CHECK(after_frames.started == 8 && after_frames.finished == 8, "8 frames: started %llu, finished %llu", after_frames.started, after_frames.finished);
    CHECK(!after_frames.start_err && !after_frames.finish_err && !after_frames.skipped, "no errors or skips (start %llu, finish %llu, last %d, skipped %llu)", after_frames.start_err, after_frames.finish_err, after_frames.last_err, after_frames.skipped);
    CHECK(after_frames.late == 0, "none of them past its 16.7 ms deadline (%llu)", after_frames.late);
    CHECK(after_late.finished == 9 && after_late.late == 1, "a frame past its 0.5 ms deadline counts as late (finished %llu, late %llu)", after_late.finished, after_late.late);
    CHECK(raw_finish == 0 && after_einval.finish_err == 1 && after_einval.last_err == EINVAL && open_after_einval == 0 && after_einval.started == 11 && !after_einval.start_err,
          "a finish with no interval started (EINVAL) clears the open mark, and the next begin starts one (finish errors %llu, last %d, open %d, started %llu)",
          after_einval.finish_err, after_einval.last_err, open_after_einval, after_einval.started);
    CHECK(outsider_c.skipped == 1 && outsider_c.finished == 9 && outsider_c.started == 11, "a thread that is not a member calls neither, and counts its frame skipped once (skipped %llu)", outsider_c.skipped);
    dm_frame_wg_counts c; dm_frame_wg_counts_read(&c);
    CHECK(c.finished == 10 && !c.start_err && c.finish_err == 1, "the member finished the interval left open (finished %llu)", c.finished);
    printf("info the member ended without leaving and the process lives on: the key destructor left for it\n");
    m2_started = dispatch_semaphore_create(0); m3_done = dispatch_semaphore_create(0);
    pthread_t m2, m3; pthread_create(&m2, NULL, member2, NULL); pthread_create(&m3, NULL, member3, NULL); pthread_join(m3, NULL); pthread_join(m2, NULL);
    CHECK(m2_join == 0 && m3_join == 0 && m3_finished == 1, "an interval one member started, another member finishes (an acquire that moved; joins %d, %d)", m2_join, m3_join);
    if (getenv("DM_TEST_FRAMEWG_CRASH")) {   // opt in: the crash leaves a crash report each run (checked 2026-11-12 on macOS 27.3: a trap, status 0x8500)
        char cmd[1200]; snprintf(cmd, sizeof cmd, "exec 2>/dev/null; '%s' --raw-exit", argv[0]); int st = system(cmd);
        CHECK(st != 0, "without it a member that ends ends the process (status %#x)", st);
    }
    pthread_t s; pthread_create(&s, NULL, standard, NULL); pthread_join(s, NULL);
    printf(fails ? "t_framewg: %d failed\n" : "t_framewg: all passed\n", fails);
    return fails != 0;
}
