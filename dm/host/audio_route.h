// What the front ends report about the audio output's route and latency, against the audio renderer's queue: the queue's size (hle_audren.c render_main keeps
// AUDREN_NBUF blocks of AUDREN_BLOCK_FRAMES in flight), whether a device buffer is longer than that queue, a route warned about once, and the Mac device's latency
// line. Plain C, so dm/host/tests/t_audio_route.c runs it on any machine; front_ios.m and hle_audio.c (Mac) log with it. Nothing here changes what a game sees
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

// The renderer's output queue: its render thread keeps AUDREN_NBUF blocks appended to its output and renders one more as each comes back. A block is one renderer
// frame, 5 ms: 240 samples at 48 kHz (a 32 kHz renderer's 160, upsampled 3:2). hle_audren.c takes NBUF and its silent block's length from here
enum { AUDREN_NBUF = 4, AUDREN_BLOCK_FRAMES = 240, AUDREN_RATE = 48000 };
static inline double audren_queue_ms(void) { return AUDREN_NBUF * AUDREN_BLOCK_FRAMES * 1000.0 / AUDREN_RATE; }
// The queue as the log names it: "the audio renderer's queue (4 blocks of 240 frames, 20 ms)"
static inline int audren_queue_text(char *out, size_t n) {
    return snprintf(out, n, "the audio renderer's queue (%d blocks of %d frames, %.0f ms)", AUDREN_NBUF, AUDREN_BLOCK_FRAMES, audren_queue_ms());
}
// 1 when a device buffer of `seconds` (iOS: AVAudioSession's IOBufferDuration; Mac: the device's buffer frames over its rate) holds more than the renderer's whole
// queue: each callback then asks for more than the renderer has in flight, and every one is zero-padded (crackling: docs/reference/audio.md, RemoteIO's default I/O
// buffer duration, 1999 underruns in 2000 callbacks at 1024 frames). Half a frame of tolerance: a buffer of exactly the queue (960 frames) still fits
static inline int audren_buffer_over_queue(double seconds) {
    return seconds * AUDREN_RATE > AUDREN_NBUF * AUDREN_BLOCK_FRAMES + 0.5;
}

// Routes already warned about, so a warning comes once per route: a route's key (its outputs' port types and UIDs on iOS, the device on the Mac) is kept as a 64-bit
// FNV-1a hash; the last 16 are kept, which is more routes than one run sees
typedef struct { uint64_t seen[16]; unsigned n; } audio_route_once;
static inline uint64_t audio_route_hash(const char *key) {
    uint64_t h = 14695981039346656037ull;
    for (const unsigned char *p = (const unsigned char *)(key ? key : ""); *p; p++) h = (h ^ *p) * 1099511628211ull;
    return h;
}
// 1 the first time a key is seen (and remembers it), 0 after that
static inline int audio_route_first(audio_route_once *o, const char *key) {
    uint64_t h = audio_route_hash(key);
    unsigned kept = o->n < 16 ? o->n : 16;
    for (unsigned i = 0; i < kept; i++) if (o->seen[i] == h) return 0;
    o->seen[o->n++ % 16] = h;
    return 1;
}

// The Mac output device's latency as Core Audio's HAL gives its parts (AudioHardwareBase.h): the device's own latency and its output stream's, which add up; the
// safety offset, how far ahead of the hardware the HAL writes; and the buffer, one I/O cycle. All in device frames at the device's rate. A part the HAL did not
// answer is marked in `missing` and left out of the sum
enum { AL_DEVICE = 1, AL_SAFETY = 2, AL_STREAM = 4 };
typedef struct { uint32_t device, safety, buffer, stream; double rate; unsigned missing; } audio_latency;
static inline uint32_t audio_latency_frames(const audio_latency *l) {
    return (l->missing & AL_DEVICE ? 0 : l->device) + (l->missing & AL_SAFETY ? 0 : l->safety) + l->buffer + (l->missing & AL_STREAM ? 0 : l->stream);
}
static inline double audio_latency_ms(const audio_latency *l) { return l->rate > 0 ? audio_latency_frames(l) * 1000.0 / l->rate : 0; }
static inline int audio_latency_same(const audio_latency *a, const audio_latency *b) {
    return a->device == b->device && a->safety == b->safety && a->buffer == b->buffer && a->stream == b->stream && a->rate == b->rate && a->missing == b->missing;
}
// "12.6 ms (device 64 + safety offset 24 + buffer 240 + stream 276 frames at 48000 Hz)"; a part the HAL did not answer reads "?"
static inline int audio_latency_text(char *out, size_t n, const audio_latency *l) {
    char d[16], s[16], st[16];
    if (l->missing & AL_DEVICE) snprintf(d, sizeof d, "?"); else snprintf(d, sizeof d, "%u", (unsigned)l->device);
    if (l->missing & AL_SAFETY) snprintf(s, sizeof s, "?"); else snprintf(s, sizeof s, "%u", (unsigned)l->safety);
    if (l->missing & AL_STREAM) snprintf(st, sizeof st, "?"); else snprintf(st, sizeof st, "%u", (unsigned)l->stream);
    return snprintf(out, n, "%.1f ms (device %s + safety offset %s + buffer %u + stream %s frames at %.0f Hz)", audio_latency_ms(l), d, s, (unsigned)l->buffer, st, l->rate);
}
