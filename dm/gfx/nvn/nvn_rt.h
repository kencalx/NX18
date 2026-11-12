// Time-constraint (real-time) declarations for the NVN layer's own worker threads: the queue replay ('NVN queue replay', nvn_queue.inc nq_worker) and the encode thread ('dm-encode',
// nvn_rec.h rec_thread). The profile key replay_rt, DM_REPLAY_RT=1 / 0 overriding it (nvn_replay_rt); off by default, so every other game's threads keep their QoS alone.
// Each thread ticks itself once a frame (nvn_rtw_tick, hle_nvn.c): it measures its own CPU time per frame and declares period = the present thread's period (rt_period_ns at the
// acquire), constraint = period, preemptible, computation = max(1.25 x the 90th percentile, 1.1 x the peak) of its last 120 frames, between NVN_RTW_FLOOR and NVN_RTW_CAP of the
// period (nvn_rtw_size_ms); half the period until the first 120 frames are measured, and declared again when the size moves by more than 15%, as the present thread's (rt_comp_tick).
// Both threads sleep between their nodes or blocks: XNU gives a real-time thread a new deadline and its whole computation at each wakeup, so a thread that blocks often (the replay
// waits for the encode thread about 20 times a frame in Ocarina of Time) starts each run with its full budget; sizing to the whole frame's CPU covers the case where the nodes run back to
// back without blocking. A run past the computation is what stalled Dark Souls Remastered's render thread for 30-60 ms (docs/reference/frame-rate.md, Time-constraint computation declared
// below the thread's peaks), hence the peak in the size
#pragma once
#include <stdint.h>
#include <mach/mach.h>
enum { NVN_RTW_WIN = 120 };
#define NVN_RTW_FLOOR 0.1   // of the period, and at least 1 ms
#define NVN_RTW_CAP 0.8     // of the period: the acquiring thread may declare 0.9 of it beside these two
#define NVN_RTW_START 0.5   // of the period, until the first window is measured
typedef struct nvn_rtw {
    const char *name;           // the thread's name, for the log
    int started, failed, logged;
    uint64_t frame, cpu;        // the frame and this thread's CPU time (ns) at the last tick
    double win[NVN_RTW_WIN]; int n;   // CPU ms per frame, this window
    double comp_ms, period_ms;  // what is declared (0: nothing yet)
    mach_port_t port;           // this thread, a send right of our own: the thread policy line reads it (rt_policy_line)
} nvn_rtw;
int nvn_replay_rt(void);                                     // the profile's replay_rt, DM_REPLAY_RT overriding it; logs once when on
void nvn_rtw_tick(nvn_rtw *w, uint64_t frame);               // on the thread itself, at each new frame it works on (a frame that goes back is ignored)
double nvn_rtw_size_ms(const double *v, int n, double period_ms);   // the computation for n per-frame CPU times (ms), sorted or not; floor and cap applied
