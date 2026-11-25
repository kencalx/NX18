// DM_AUDIO_IO_MS: the audio I/O buffer duration the host asks of the system (the iOS audio session's preferred I/O buffer duration, front_ios.m front_ios_audio_session; the
// Mac's device buffer frames, hle_audio.c au_buffer). Unset: 5 ms, as before (about 190 device callbacks a second on an iPhone, which grants 256 frames, 5.33 ms). A longer buffer
// wakes the device's I/O thread less often (10 ms: about 94 a second; 20 ms: about 47), at the cost of that much more output latency, for a power A/B.
// A device callback takes the buffer's frames from the output's queue at once, so the queue must hold more than a buffer's worth when it comes: the host's own audio renderer
// (hle_audren.c render_main) keeps audio_io_blocks(granted frames) blocks of 5 ms in flight instead of 4 while the switch is set (4 at 5.33 ms, 5 at 10.67 ms, 7 at 21.33 ms).
// A game that plays through its own AudioOut (FMOD's or Wwise's output) keeps the queue it chose (often 4 blocks of 5 ms, 20 ms): a 20 ms buffer, which iOS grants as 21.33 ms,
// cannot be filled from it and underruns at every callback; the audio statistics line ("device callbacks N: ... underruns") shows it.
// The range is 5-20 ms: the audio watchdog (DM_AUDIO_WD_MS) suspects a stall when the last callback of a healthy tick is over 50 ms old, which a callback interval must stay well under.
// Pure C: dm/host/tests/t_audio_io.c tests it
#pragma once
#include <stdint.h>
#include <stdlib.h>

enum { AUDIO_IO_MS_DEFAULT = 5, AUDIO_IO_MS_MIN = 5, AUDIO_IO_MS_MAX = 20, AUDIO_IO_BLOCK_FRAMES = 240, AUDIO_IO_BLOCKS = 4, AUDIO_IO_BLOCKS_MAX = 8 };

// The duration DM_AUDIO_IO_MS asks for (value: the variable's, NULL when unset): 0 when unset or empty (the default, 5 ms, and nothing else changes), else AUDIO_IO_MS_MIN-MAX,
// clamped; *bad is set when the value is not a whole number of milliseconds (then 0: the default)
static inline int audio_io_ms_parse(const char *value, int *bad) {
    if (bad) *bad = 0;
    if (!value || !*value) return 0;
    char *end; long v = strtol(value, &end, 10);
    if (end == value || *end) { if (bad) *bad = 1; return 0; }
    return v < AUDIO_IO_MS_MIN ? AUDIO_IO_MS_MIN : v > AUDIO_IO_MS_MAX ? AUDIO_IO_MS_MAX : (int)v;
}
// Blocks of AUDIO_IO_BLOCK_FRAMES the host's audio renderer keeps in flight for device callbacks of frames frames each: a callback's worth, rounded up, and two more (one the
// renderer is making, one of margin); 0 frames (the switch unset, nothing granted yet): AUDIO_IO_BLOCKS, as before. AUDIO_IO_BLOCKS to AUDIO_IO_BLOCKS_MAX
static inline int audio_io_blocks(uint32_t frames) {
    if (!frames) return AUDIO_IO_BLOCKS;
    int n = (int)((frames + AUDIO_IO_BLOCK_FRAMES - 1) / AUDIO_IO_BLOCK_FRAMES) + 2;
    return n < AUDIO_IO_BLOCKS ? AUDIO_IO_BLOCKS : n > AUDIO_IO_BLOCKS_MAX ? AUDIO_IO_BLOCKS_MAX : n;
}

// hle_audio.c: DM_AUDIO_IO_MS read once (0: unset); the front end hands it the duration the system granted (seconds), which the renderer reads as frames at 48 kHz (0 while the switch
// is unset, so the renderer keeps its 4 blocks whatever a route grants)
int dm_audio_io_ms(void);
void dm_audio_io_granted(double seconds);
uint32_t dm_audio_io_frames(void);
