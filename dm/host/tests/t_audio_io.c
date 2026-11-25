// DM_AUDIO_IO_MS (audio_io.h): the value's range, and the blocks of 5 ms the host's audio renderer keeps in flight for the device buffer the system granted, so a callback never
// finds less than its frames queued
#include "../audio_io.h"
#include <stdio.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

int main(void) {
    int bad;
    CHECK(audio_io_ms_parse(NULL, &bad) == 0 && !bad, "unset: the default (0)");
    CHECK(audio_io_ms_parse("", &bad) == 0 && !bad, "empty: the default");
    CHECK(audio_io_ms_parse("10", &bad) == 10 && !bad, "10 ms");
    CHECK(audio_io_ms_parse("20", &bad) == 20 && !bad, "20 ms");
    CHECK(audio_io_ms_parse("5", &bad) == 5 && !bad, "5 ms, the default's value, set");
    CHECK(audio_io_ms_parse("2", &bad) == AUDIO_IO_MS_MIN && !bad, "below the range: 5");
    CHECK(audio_io_ms_parse("100", &bad) == AUDIO_IO_MS_MAX && !bad, "above the range: 20 (the watchdog's 50 ms suspicion)");
    CHECK(audio_io_ms_parse("10ms", &bad) == 0 && bad, "not a number: the default, said");
    CHECK(audio_io_ms_parse("x", &bad) == 0 && bad, "not a number: the default, said");

    CHECK(audio_io_blocks(0) == 4, "the switch unset: 4 blocks, as before");
    CHECK(audio_io_blocks(256) == 4, "5.33 ms (an iPhone's grant for 5 ms): 4 blocks, as before");
    CHECK(audio_io_blocks(240) == 4, "5 ms exactly: 4");
    CHECK(audio_io_blocks(512) == 5, "10.67 ms (10 ms asked): 5");
    CHECK(audio_io_blocks(480) == 4, "10 ms exactly (the Mac): 4");
    CHECK(audio_io_blocks(1024) == 7, "21.33 ms (20 ms asked): 7");
    CHECK(audio_io_blocks(4096) == AUDIO_IO_BLOCKS_MAX, "a route granting far more: the most the renderer has");
    // Every grant up to the most: a callback's frames are queued when it comes, with a block being made and one of margin
    for (uint32_t f = 1; f <= 1440; f++) {
        int n = audio_io_blocks(f);
        if ((uint32_t)(n - 2) * AUDIO_IO_BLOCK_FRAMES < f) { CHECK(0, "a callback's worth queued"); break; }
    }
    printf("t_audio_io: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
