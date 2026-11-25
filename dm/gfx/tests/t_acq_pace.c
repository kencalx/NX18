// The acquire's pacing sleep (hle_nvn.c sleep_until_ns: the host's own 60 Hz clock with no display link, the snapshot path while the link is stalled, the link's timeout
// fallback, the DM_DETCLOCK_PACE floor) with the acquire's display wait (nvn_acquire_block), whose entry can wait for the thread lock (t_acq_pace_hold.c holds it):
//   the wake asked of the kernel is the texture's slot time, not later by the time the entry took (the time left was read before it, and the sleep overshot by that wait).
// The deadline is read where sleep_until_ns hands it to mach_wait_until (test_wait_until), not from when the thread woke: the kernel's timer slack for a test process of low
// QoS is several milliseconds on its own.
//   Under the deterministic clock the acquire takes no display wait, even when the DM_DETCLOCK_PACE floor sleeps: whether that wall-clock floor sleeps depends on the host's
//   load, and with it whether a same-core waker would be let go at the acquire, which the screenshot gate's capture must not depend on
#include <mach/mach_time.h>
#include <time.h>
static uint64_t test_deadline_ns;
static kern_return_t test_wait_until(uint64_t deadline) {
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    test_deadline_ns = deadline * tb.numer / tb.denom;
    return mach_wait_until(deadline);
}
#define mach_wait_until test_wait_until
#include "../nvn/hle_nvn.c"
#undef mach_wait_until
void *front_metal_layer(void) { return NULL; }   // no window in unit tests
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }

extern int hold_enters, hold_leaves, hold_det; extern unsigned hold_us; extern uint64_t hold_end_ns;
static int checks, failed;
#define CHECK(c, ...) do { checks++; int ok_ = (c); printf("%s ", ok_ ? "✓" : "✗"); printf(__VA_ARGS__); printf("\n"); if (!ok_) failed++; } while (0)

static win_t win = {.ntex = 2, .interval = 1};
static void acquire(void) { int idx; h_nvnWindowAcquireTexture((NVNwindow *)&win, NULL, &idx); }
static void slots_at(uint64_t at) { for (int i = 0; i < 4; i++) win.avail[i] = at; }

int main(void) {
    setenv("DM_RT", "0", 1); setenv("DM_FRAME_WG", "0", 1); setenv("DM_PRESENT_SNAP", "0", 1); unsetenv("DM_DETCLOCK"); unsetenv("DM_DETCLOCK_PACE");
    nvn_present_config(60, 0); dm_fps_state = NULL;
    CHECK(!mtl_link_active() && !mtl_snap_on(), "no display link, no snapshots: the acquire paces on the host's own clock");

    // The host's own clock: the texture's slot 40 ms ahead, the display wait's entry held 15 ms or more (a thread holding G). The old wake was the slot time plus the hold
    {
        hold_us = 15000; int e0 = hold_enters, l0 = hold_leaves, asked = 0; uint64_t b0 = g_acq_blocks, worst = 0, held = 0;
        for (int i = 0; i < 5; i++) {
            uint64_t t0 = now_ns(), at = t0 + 40000000ull; slots_at(at); test_deadline_ns = 0;
            acquire();
            if (test_deadline_ns) { asked++; uint64_t off = test_deadline_ns > at ? test_deadline_ns - at : at - test_deadline_ns; if (off > worst) worst = off; }
            if (hold_end_ns - t0 > held) held = hold_end_ns - t0;
        }
        CHECK(hold_enters - e0 == 5 && hold_leaves - l0 == 5 && g_acq_blocks - b0 == 5, "each acquire that sleeps takes the display wait once and leaves it (%d / %d)", hold_enters - e0, hold_leaves - l0);
        CHECK(asked == 5 && worst < 1000000ull, "the wake asked for is the slot time: the entry's wait (up to %.1f ms) is not added to the sleep (%d sleeps, worst %.3f ms off it)", held / 1e6, asked, worst / 1e6);
    }
    // A slot time the entry's wait has passed (10 ms ahead, held 15 ms or more): no sleep after it. The old wake was 10 ms after the hold ended
    {
        hold_us = 15000; uint64_t at = now_ns() + 10000000ull; slots_at(at); test_deadline_ns = 0;
        acquire();
        CHECK(hold_end_ns >= at && !test_deadline_ns, "a slot time passed while the entry waited: no sleep after it");
    }
    // The deterministic clock with its pace floor (50 ms steps): the second acquire, right after the first, sleeps up to the floor and takes no display wait
    {
        hold_us = 0; hold_det = 1; setenv("DM_DETCLOCK", "50000000", 1); setenv("DM_DETCLOCK_PACE", "1", 1); slots_at(0);
        acquire();
        int e0 = hold_enters; uint64_t b0 = g_acq_blocks; test_deadline_ns = 0;
        acquire();
        CHECK(test_deadline_ns != 0, "the pace floor slept (the second acquire came inside its step)");
        CHECK(hold_enters == e0 && g_acq_blocks == b0 && !t_acq_blocked, "and took no display wait: under the deterministic clock the acquire never gives its core away");
        hold_det = 0; unsetenv("DM_DETCLOCK"); unsetenv("DM_DETCLOCK_PACE");
    }
    hold_us = 0;
    printf("t_acq_pace: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
