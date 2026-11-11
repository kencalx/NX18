// GPU diagnostics of the NVN layer (nvn_mtl.m), the parts that are plain C and run on any machine (dm/gfx/tests/t_gpu_diag.c, make gpu-diag: plain, TSan, ASan).
// For now one part, ported from the old fork's batch-b (da1996ad), whose command-buffer error kinds and failed command buffer's pass ring are not on this main:
//   - The GPU's busy time from the Metal 4 command buffers' GPU start and end times, the union of those intervals (gd_busy_*): the power line's GPU ms/s (hle_nvn.c
//     power_line). It was task_power_info_v2's gpu_energy.task_gpu_utilisation, which iOS leaves at 0 for an app: every power line of 13 Sentinels and Luigi's Mansion 3 on an
//     iPhone 18 Pro Max read 'GPU 0.0 ms/s' (62 lines in the 13 Sentinels log alone), while the timing line's GPU p50 was up to 18-22 ms a frame. The Mac fills it, so it stays on the line
//     beside the host's own count there.
// Diagnostics only: the feedback handlers that already run when each command buffer completes add its interval (nvn_mtl.m gpu_busy_note), on the feedback queue. The one
// command buffer of the game's work that had no handler, the indirect-count wait's (mdi_wait), gets one; that adds an options object to a commit the submit thread then
// waits on until the GPU is done, so it costs nothing the wait does not already cover. No encoder, barrier, wait or commit order changes.
#pragma once
#include <stdatomic.h>
#include <stdint.h>

// ---------- GPU busy time ----------
// The union of command buffers' GPU intervals, in ns: the part of an interval before the latest end seen so far is taken as already covered, so command buffers that overlap on
// the GPU (an upload batch running beside a game's segment, a present beside the next frame's first command buffer) count once, and the figure can never pass the wall clock.
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
