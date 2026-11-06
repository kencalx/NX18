// The front ends' audio route and latency rules (../audio_route.h, plain C, no game profile or sound device): the audio renderer's queue and whether a device buffer
// is longer than it, the once-per-route warning, and the Mac device's latency line. make -C dm/host/tests GAME=<id> audio-route (also in run)
#include "../audio_route.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

int main(void) {
    // the queue: 4 blocks of 240 frames at 48 kHz, as hle_audren.c's render thread keeps them
    assert(AUDREN_NBUF == 4 && AUDREN_BLOCK_FRAMES == 240 && AUDREN_RATE == 48000);
    assert(audren_queue_ms() == 20.0);
    char q[96]; audren_queue_text(q, sizeof q);
    assert(!strcmp(q, "the audio renderer's queue (4 blocks of 240 frames, 20 ms)"));

    // a buffer longer than the queue: iOS's 1024-frame default (21.33 ms, 1999 underruns in 2000 callbacks), the 1104 frames iOS 18.0.1 granted with Sound
    // Recognition on (23 ms), 1024 frames at 44.1 kHz; not the 5 ms asked for, iOS's 256-frame minimum, 15 ms, or exactly the queue (960 frames)
    assert(audren_buffer_over_queue(1024 / 48000.0));
    assert(audren_buffer_over_queue(1104 / 48000.0));
    assert(audren_buffer_over_queue(1024 / 44100.0));
    assert(audren_buffer_over_queue(961 / 48000.0));
    assert(!audren_buffer_over_queue(0.005));
    assert(!audren_buffer_over_queue(256 / 48000.0));
    assert(!audren_buffer_over_queue(0.015));
    assert(!audren_buffer_over_queue(960 / 48000.0));
    assert(!audren_buffer_over_queue(0.020));
    assert(!audren_buffer_over_queue(0));

    // once per route: a key warns the first time only; 16 are kept, so the oldest of 17 warns again
    audio_route_once o = {{0}, 0};
    assert(audio_route_first(&o, "Speaker/Built-In Speaker"));
    assert(!audio_route_first(&o, "Speaker/Built-In Speaker"));
    assert(audio_route_first(&o, "BluetoothA2DPOutput/00-11-22-33-44-55-tacl"));
    assert(!audio_route_first(&o, "BluetoothA2DPOutput/00-11-22-33-44-55-tacl"));
    assert(audio_route_first(&o, "BluetoothA2DPOutput/66-77-88-99-AA-BB-tacl"));   // a second pair of headphones is a route of its own
    assert(audio_route_first(&o, ""));
    assert(!audio_route_first(&o, NULL));   // no key reads as the empty one
    assert(audio_route_hash("a") != audio_route_hash("b") && audio_route_hash("ab") != audio_route_hash("ba"));
    audio_route_once r = {{0}, 0};
    char k[32];
    for (int i = 0; i < 17; i++) { snprintf(k, sizeof k, "device %d", i); assert(audio_route_first(&r, k)); }
    snprintf(k, sizeof k, "device %d", 16); assert(!audio_route_first(&r, k));
    snprintf(k, sizeof k, "device %d", 1); assert(!audio_route_first(&r, k));
    snprintf(k, sizeof k, "device %d", 0); assert(audio_route_first(&r, k));   // pushed out by the 17th

    // the Mac device's latency: device + safety offset + buffer + stream, at the device's rate; a part the HAL did not answer is "?" and left out
    audio_latency l = {.device = 64, .safety = 24, .buffer = 240, .stream = 276, .rate = 48000};
    assert(audio_latency_frames(&l) == 604);
    char t[160]; audio_latency_text(t, sizeof t, &l);
    assert(!strcmp(t, "12.6 ms (device 64 + safety offset 24 + buffer 240 + stream 276 frames at 48000 Hz)"));
    audio_latency m = l;
    assert(audio_latency_same(&l, &m));
    m.missing = AL_STREAM | AL_SAFETY;
    assert(!audio_latency_same(&l, &m));
    assert(audio_latency_frames(&m) == 304);
    audio_latency_text(t, sizeof t, &m);
    assert(!strcmp(t, "6.3 ms (device 64 + safety offset ? + buffer 240 + stream ? frames at 48000 Hz)"));
    m = l; m.rate = 44100; assert(!audio_latency_same(&l, &m));
    m = l; m.buffer = 221; assert(!audio_latency_same(&l, &m));
    audio_latency z = {.buffer = 512};
    assert(audio_latency_ms(&z) == 0);   // no rate: no time
    audio_latency_text(t, sizeof t, &z);
    assert(!strcmp(t, "0.0 ms (device 0 + safety offset 0 + buffer 512 + stream 0 frames at 0 Hz)"));
    puts("audio route: renderer queue, buffer over the queue, once per route and the device latency line passed");
    return 0;
}
