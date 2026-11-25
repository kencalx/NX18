// Stand-ins linked into t_gpu_wait in place of the weak ones (hle_nvn.c dm_thread_gpu_wait and dm_thread_display_wait, nvn_mtl.m dm_detclock_enabled): the host's waits
// (hle_thread.c) make the calling guest thread blocked and end its part in a same-core handoff; here they only count, and note when the GPU wait was entered.
// gw_det is the deterministic clock's switch. The host's GPU wait takes the thread lock G, which every SVC takes, so entering it can wait as long as another thread holds G;
// gw_hold_us stands for that wait (as t_acq_pace_hold.c's hold_us for the display wait)
#include <stdatomic.h>
#include <stdint.h>
#include <time.h>
#include <unistd.h>
_Atomic int gw_enter, gw_leave, dw_enter, dw_leave, gw_det; _Atomic unsigned gw_hold_us; _Atomic uint64_t gw_enter_ns;
void dm_thread_gpu_wait(int entering) {
    if (!entering) { gw_leave++; return; }
    gw_enter++; gw_enter_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (gw_hold_us) usleep(gw_hold_us);
}
void dm_thread_display_wait(int entering) { if (entering) dw_enter++; else dw_leave++; }
int dm_detclock_enabled(void) { return gw_det; }
