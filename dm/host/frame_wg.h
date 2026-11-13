// The frame workgroup (frame_wg.c; profile key frame_wg, DM_FRAME_WG=1, armed by hle_nvn.c frame_wg_on): one os_workgroup interval told each frame's start and deadline by the thread
// that acquires the window texture, which the replay threads ('NVN queue replay', 'dm-encode') join too (docs/reference/frame-rate.md, A frame deadline told through a work interval).
// hle_nvn.c has weak stand-ins for these that do nothing, for the graphics unit tests, which do not link AudioToolbox
#pragma once
#include <stdint.h>
typedef struct {
    uint64_t started, finished;   // intervals started and finished
    uint64_t late;                // of those finished, finished past their deadline
    uint64_t skipped;             // frames whose finish and start were not made: the acquiring thread is not a member (no present period yet to set its policy, or its policy or its join failed). With DM_RT=0 or DM_DETCLOCK nothing is called, so nothing is skipped either
    uint64_t start_err, finish_err;   // os_workgroup_interval_start / _finish returned an error
    int last_err;                 // the last of those errors (an errno value)
} dm_frame_wg_counts;
int dm_frame_wg_join(const char *who);        // the calling thread joins the interval, once per thread (later calls return the first answer); 0 = a member, else the error (-1: no interval). Logs the result once per thread
void dm_frame_wg_end(void);                   // before the pacing wait: the open interval finished, by a member thread (nothing on any other)
void dm_frame_wg_begin(uint64_t period_ns);   // after it: a new interval starts now, deadline period_ns on (in mach_absolute_time ticks), by a member thread (a frame skipped on any other)
void dm_frame_wg_counts_read(dm_frame_wg_counts *c);
