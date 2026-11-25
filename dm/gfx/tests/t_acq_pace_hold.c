// Stand-ins linked into t_acq_pace in place of the weak ones (hle_nvn.c dm_thread_display_wait, nvn_mtl.m dm_detclock_enabled): the host's display wait takes the thread
// lock G, which every SVC takes, so entering it can wait as long as another thread holds G; hold_us stands for that wait. hold_det is the deterministic clock's switch
// (usleep can take longer than asked: hold_end_ns is when the entry's wait really ended)
#include <stdint.h>
#include <time.h>
#include <unistd.h>
int hold_enters, hold_leaves, hold_det; unsigned hold_us; uint64_t hold_end_ns;
void dm_thread_display_wait(int entering) {
    if (!entering) { hold_leaves++; return; }
    hold_enters++;
    if (hold_us) usleep(hold_us);
    hold_end_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
}
int dm_detclock_enabled(void) { return hold_det; }
