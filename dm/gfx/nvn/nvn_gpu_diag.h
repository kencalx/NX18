// GPU diagnostics of the NVN layer (nvn_mtl.m), the parts that are plain C and run on any machine (dm/gfx/tests/t_gpu_diag.c, make gpu-diag: plain, TSan, ASan).
// For now one part, ported from the old fork's batch-b (da1996ad), whose command-buffer error kinds and failed command buffer's pass ring are not on this main:
//   - The GPU's busy time from the Metal 4 command buffers' GPU start and end times, the union of those intervals (gd_busy_*): the power line's GPU ms/s (hle_nvn.c
//     power_line). It was task_power_info_v2's gpu_energy.task_gpu_utilisation, which iOS leaves at 0 for an app: every power line of 13 Sentinels and Luigi's Mansion 3 on an
//     iPhone 18 Pro Max read 'GPU 0.0 ms/s' (62 lines in the 13 Sentinels log alone), while the timing line's GPU p50 was up to 18-22 ms a frame. The Mac fills it, so it stays on the line
//     beside the host's own count there.
// Diagnostics only: the feedback handlers that already run when each command buffer completes add its interval (nvn_mtl.m gpu_busy_note), on the feedback queue. The two
// command buffers of the game's work that had no handler get one: the indirect-count wait's (mdi_wait), a commit the submit thread then waits on until the GPU is done, so
// the options object costs nothing the wait does not already cover; and the load-skip probe's commit of the open command buffer (lp_finish, only with DM_NVN_LOADPROBE).
// No encoder, barrier, wait or commit order changes.
#pragma once
#include <stdatomic.h>
#include <stdint.h>

// ---------- GPU busy time ----------
// The union of command buffers' GPU intervals, in ns: the part of an interval before the latest end seen so far is taken as already covered, so command buffers that overlap on
// the GPU (an upload batch running beside a game's segment, a present beside the next frame's first command buffer) count once, and the figure can never pass the wall clock.
// The total never passes the wall clock the intervals span; a window's share of it (the power line's ms/s) can pass the window's length a little, since an interval counts when
// its handler runs, all of it in that window: a long command buffer across the window's edge, or several reported at once after a stall, can read just over 1000 ms/s.
// One writer: every feedback handler of the Metal 4 queue runs on one serial dispatch queue (nvn_mtl.m g_feedback_q, the queue's feedbackQueue), so end needs no atomic. The
// handlers come in about the order the GPU ran the work (each host encoder starts with a queue barrier); one reported after a later one it did not overlap counts only past that
// one's end, an undercount, never a double count. Readers on any thread (hle_nvn.c power_line once per 300 frames) take busy with a relaxed load: a window boundary may land
// between two adds, which moves a few ms from one window into the next and loses nothing
typedef struct { uint64_t end; _Atomic uint64_t busy; } gd_busy;
static inline void gd_busy_add(gd_busy *b, uint64_t s0, uint64_t s1) {
    if (!s0 || s1 <= s0) return;   // a command buffer can complete with no start time (nvn_mtl.m gpu_tag_done: a movie's uploads in Big Brain Academy), and a failed one with none at all
    uint64_t from = s0 > b->end ? s0 : b->end;
    if (s1 > from) atomic_store_explicit(&b->busy, atomic_load_explicit(&b->busy, memory_order_relaxed) + (s1 - from), memory_order_relaxed);
    if (s1 > b->end) b->end = s1;
}
static inline uint64_t gd_busy_ns(gd_busy *b) { return atomic_load_explicit(&b->busy, memory_order_relaxed); }
// The feedback handlers' way in (nvn_mtl.m gpu_busy_note): gd_busy_add only after a check that the interval can be real. now is the clock when the report came, on the same
// base (CACurrentMediaTime, in ns). Every interval counts only past the latest end seen, so one bad GPU end time far in the future (a command buffer that failed or was lost
// with a garbage time) would move that end forward and leave every later interval counting 0 for the rest of the run: the power line would quietly read 'GPU 0.0 ms/s busy'
// again, the fault this count was made to end. So an interval is left out when it ends after the report came, beyond GD_BUSY_SLACK_NS (a completed command buffer cannot end
// later than its completion is reported; the slack only absorbs clock rounding), or runs longer than GD_BUSY_LONGEST_NS (no real command buffer runs a minute: the system's GPU
// watchdog ends it long before; a start time of 0 or near it, already skipped above, is the usual source). Returns 1 when it counted, 0 when it was left out
#define GD_BUSY_SLACK_NS 1000000000ull      // 1 s
#define GD_BUSY_LONGEST_NS 60000000000ull   // 60 s
static inline int gd_busy_add_checked(gd_busy *b, uint64_t s0, uint64_t s1, uint64_t now) {
    if (!s0 || s1 <= s0) return 0;
    if (s1 > now + GD_BUSY_SLACK_NS || s1 - s0 > GD_BUSY_LONGEST_NS) return 0;
    gd_busy_add(b, s0, s1);
    return 1;
}
