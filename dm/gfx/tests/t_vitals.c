// Vitals' formatting (../nvn/nvn_vitals.h, NX18-X2.0 vitals.md): the strings, the "cap" rule, stale "--", the drop order, the hysteresis and the seqlock reader.
// make -C dm/gfx/tests GAME=<id> check_t_vitals
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "../nvn/nvn_vitals.h"

static int fails;
#define EQ(got, want) do { if (strcmp((got), (want))) { fprintf(stderr, "FAIL line %d: got \"%s\", want \"%s\"\n", __LINE__, (got), (want)); fails++; } } while (0)
#define TRUE(c) do { if (!(c)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); fails++; } } while (0)

static nvn_vitals_pub g_pub;
static _Atomic int g_stop, g_torn;
static void *writer(void *a) {
    (void)a;
    for (int i = 1; !atomic_load(&g_stop); i++) {
        nvn_vitals v = {.stamp_ns = (uint64_t)i, .cpu_mw = i, .pshare_pm = (int16_t)(i & 0x7fff), .gpu_busy_pm = (int16_t)(i & 0x7fff), .fps10 = i, .max_gap_100us = i, .gen10 = i, .shown10 = i};
        nvn_vitals_publish(&g_pub, &v);
    }
    return NULL;
}

int main(void) {
    char b[160];
    const uint64_t now = 10000000000ull;
    nvn_vitals v = {.stamp_ns = now - 500000000ull, .cpu_mw = 2140, .pshare_pm = 823, .gpu_busy_pm = 641, .fps10 = 600, .max_gap_100us = 330};
    nvn_vitals_dev d = {.thermal = 1, .bat_pct = 82, .bat_state = 2, .lpm = 0, .time = "9:41"};

    // Standard, both halves, every drop
    TRUE(nvn_vitals_fresh(&v, now));
    nvn_vitals_left(b, sizeof b, &v, 60, 0, 21, 1, 0, 0); EQ(b, "60 fps · CPU 2.1 W");
    nvn_vitals_left(b, sizeof b, &v, 60, 0, 21, 1, 0, 1); EQ(b, "60 fps · 2.1 W");
    nvn_vitals_left(b, sizeof b, &v, 60, 0, 21, 1, 0, 2); EQ(b, "60 fps");
    nvn_vitals_left(b, sizeof b, &v, 60, 0, 124, 1, 0, 0); EQ(b, "60 fps · CPU 12.4 W");
    nvn_vitals_left(b, sizeof b, &v, 60, 0, -1, 1, 0, 0); EQ(b, "60 fps");
    nvn_vitals_right(b, sizeof b, &d, 0); EQ(b, "🌡 Warm · ▮82% ⚡ · 9:41");
    nvn_vitals_right(b, sizeof b, &d, 1); EQ(b, "🌡 Warm · ▮82% ⚡");
    nvn_vitals_right(b, sizeof b, &d, 2); EQ(b, "🌡 · ▮82% ⚡");
    nvn_vitals_dev d2 = d; d2.thermal = 3; d2.time = "21:41"; nvn_vitals_right(b, sizeof b, &d2, 0); EQ(b, "🌡 Too hot · ▮82% ⚡ · 21:41");
    d2.thermal = 0; d2.bat_state = 1; nvn_vitals_right(b, sizeof b, &d2, 0); EQ(b, "🌡 Cool · ▮82% · 21:41");   // unplugged: no bolt
    d2.bat_state = 3; nvn_vitals_right(b, sizeof b, &d2, 0); EQ(b, "🌡 Cool · ▮82% ⚡ · 21:41");   // full and plugged in
    d2.thermal = 2; nvn_vitals_right(b, sizeof b, &d2, 0); EQ(b, "🌡 Hot · ▮82% ⚡ · 21:41");
    d2.bat_pct = -1; d2.time = ""; nvn_vitals_right(b, sizeof b, &d2, 0); EQ(b, "🌡 Hot");   // no battery (a Mac without one), no time
    d2.thermal = -1; nvn_vitals_right(b, sizeof b, &d2, 0); EQ(b, "");

    // Stale: "--", and Detailed's lines go empty
    nvn_vitals old = v; old.stamp_ns = now - 2500000000ull;
    TRUE(!nvn_vitals_fresh(&old, now));
    nvn_vitals none = {0}; TRUE(!nvn_vitals_fresh(&none, now));
    nvn_vitals_left(b, sizeof b, &old, 60, 0, 21, nvn_vitals_fresh(&old, now), 0, 0); EQ(b, "-- fps");
    nvn_vitals_left2(b, sizeof b, &old, 0); EQ(b, "");

    // The cap: only a paced game with a target above 30, no movie, not the menu's hold
    TRUE(!nvn_vitals_capped(60, 0, 0, 1, 60, 0));
    TRUE(nvn_vitals_capped(60, 0, 0, 2, 60, 0));     // 60 did not hold
    TRUE(nvn_vitals_capped(60, 0, 1, 1, 60, 0));     // heat
    TRUE(nvn_vitals_capped(60, 0, 2, 2, 60, 0));     // Low Power Mode
    TRUE(!nvn_vitals_capped(30, 0, 1, 2, 60, 0));    // a 30 fps target never says cap
    TRUE(!nvn_vitals_capped(60, 1, 1, 2, 60, 0));    // a movie
    TRUE(!nvn_vitals_capped(60, 0, 0, 2, 60, 1));    // the in-game menu's hold
    TRUE(!nvn_vitals_capped(0, 0, 0, 2, 60, 0));     // a game NX 18 does not pace
    TRUE(!nvn_vitals_capped(120, 0, 0, 1, 120, 0)); TRUE(nvn_vitals_capped(120, 0, 0, 2, 120, 0));   // 120 fps: hold 2 is 60
    nvn_vitals c = v; c.capped = 1; c.cause = 1;
    nvn_vitals_left(b, sizeof b, &c, 30, 0, 12, 1, 0, 0); EQ(b, "30 fps cap · CPU 1.2 W");
    nvn_vitals_left(b, sizeof b, &c, 30, 0, 12, 1, 1, 0); EQ(b, "30 fps cap · hot · CPU 1.2 W");
    c.cause = 2; nvn_vitals_left(b, sizeof b, &c, 30, 0, 12, 1, 1, 2); EQ(b, "30 fps cap · Low Power");
    c.cause = 0; nvn_vitals_left(b, sizeof b, &c, 30, 0, 12, 1, 1, 2); EQ(b, "30 fps cap");

    // Frame generation: the pictures on screen with the rendered rate beside them, never the generated frames alone; under 0.5 generated a second says nothing
    nvn_vitals fg = v; fg.fps10 = 300; fg.gen10 = 300; fg.shown10 = nvn_vitals_shown10(fg.fps10, fg.gen10, 60);
    nvn_vitals_smooth fs = {0}; int sh = nvn_vitals_shown_step(&fs, &fg, 1);
    TRUE(fg.shown10 == 600 && sh == 60);
    nvn_vitals_left(b, sizeof b, &fg, 30, sh, 24, 1, 0, 0); EQ(b, "60 fps, 30 rendered · CPU 2.4 W");
    nvn_vitals_left(b, sizeof b, &fg, 30, sh, 24, 1, 1, 2); EQ(b, "60 fps, 30 rendered");
    // The generated pictures' window edge falls apart from the rendered frames': 29 and 31 by turns never read 59, 61 or anything over the link's 60 ticks
    for (int i = 0; i < 12; i++) {
        fg.gen10 = i % 3 == 0 ? 290 : i % 3 == 1 ? 310 : 300; fg.shown10 = nvn_vitals_shown10(fg.fps10, fg.gen10, 60);
        TRUE(fg.shown10 == 600);
        sh = nvn_vitals_shown_step(&fs, &fg, 1); nvn_vitals_left(b, sizeof b, &fg, 30, sh, 24, 1, 0, 2); EQ(b, "60 fps, 30 rendered");
    }
    TRUE(nvn_vitals_shown10(300, 310, 60) == 600 && nvn_vitals_shown10(300, 400, 120) == 600 && nvn_vitals_shown10(600, 600, 60) == 600);   // never more than the link's ticks, nor a generated picture per frame rendered
    fg.gen10 = 151; fg.shown10 = nvn_vitals_shown10(fg.fps10, fg.gen10, 60); sh = nvn_vitals_shown_step(&fs, &fg, 1);
    nvn_vitals_left(b, sizeof b, &fg, 30, sh, 24, 1, 0, 2); EQ(b, "45 fps, 30 rendered");   // half the frames generated (the rest real only, e.g. a movie): a move past ±1 shows at once
    fg.gen10 = 4; fg.shown10 = nvn_vitals_shown10(fg.fps10, fg.gen10, 60); sh = nvn_vitals_shown_step(&fs, &fg, 1);
    TRUE(fg.shown10 == 0 && sh == 0); nvn_vitals_left(b, sizeof b, &fg, 30, sh, 24, 1, 0, 2); EQ(b, "30 fps");
    fg.gen10 = 300; fg.shown10 = nvn_vitals_shown10(fg.fps10, fg.gen10, 60); sh = nvn_vitals_shown_step(&fs, &fg, 0);
    TRUE(sh == 0); nvn_vitals_left(b, sizeof b, &fg, 30, sh, 24, 0, 0, 2); EQ(b, "-- fps");   // stale
    sh = nvn_vitals_shown_step(&fs, &fg, 1);
    nvn_vitals_compact(b, sizeof b, &fg, 30, sh, 1, &d, 1); EQ(b, "60 fps, 30 rendered · 🌡 Warm · ▮82%");
    // The reader as DmVitals.m runs it (the frame rate's hold, then the shown figure's): the shown figure holds as the rendered one does. A frame rendered and its generated
    // picture move it by 2, so a window that loses one frame to a hitch (58 of 60) reads as the second before, and it never shows more than one generated picture per frame rendered
    nvn_vitals_smooth hs = {0}; int hf, hw;
    #define STEP(f10, s10) do { fg.fps10 = (f10); fg.shown10 = (s10); nvn_vitals_smooth_step(&hs, (fg.fps10 + 5) / 10, 24, &hf, &hw); \
                                sh = nvn_vitals_shown_step(&hs, &fg, 1); nvn_vitals_left(b, sizeof b, &fg, hf, sh, hw, 1, 0, 2); } while (0)
    STEP(300, 600); EQ(b, "60 fps, 30 rendered");
    STEP(290, 580); EQ(b, "60 fps, 30 rendered");   // a one-frame dip: the rendered count holds at 30, and the shown at 60 with it (no "58 fps, 30 rendered")
    STEP(300, 600); EQ(b, "60 fps, 30 rendered");
    STEP(300, 590); EQ(b, "60 fps, 30 rendered");   // one generated picture fewer
    STEP(290, 580); EQ(b, "60 fps, 30 rendered");
    const int dip[] = {300, 270, 290, 300, 300, 310, 300};
    for (unsigned i = 0; i < sizeof dip / sizeof *dip; i++) {   // a longer dip and back: whatever each second reads, never more than one generated picture per frame rendered
        STEP(dip[i], nvn_vitals_shown10(dip[i], dip[i], 60)); int x = 0, y = 0;
        TRUE(sscanf(b, "%d fps, %d rendered", &x, &y) == 2 && x <= 2 * y && x > y);
    }
    STEP(300, 600); EQ(b, "60 fps, 31 rendered");   // the dip's 310 moved the rendered figure (29 to 31) and the shown one with it, to what is on screen: 60, not the 58 the dip left
    STEP(300, 600); STEP(284, nvn_vitals_shown10(284, 300, 60)); EQ(b, "56 fps, 28 rendered");   // rounded apart (28.4 rendered, 56.8 shown): the shown figure alone would read 57
    STEP(300, 600); STEP(270, 270 + 140); EQ(b, "41 fps, 27 rendered");   // half generated after a drop: the move shows at once
    #undef STEP

    // Detailed's second lines
    nvn_vitals_left2(b, sizeof b, &v, 1); EQ(b, "GPU busy 64% · max 33 ms");
    nvn_vitals_right2(b, sizeof b, &v, 1); EQ(b, "P-cores 82%");
    nvn_vitals u = v; u.gpu_busy_pm = -1; u.max_gap_100us = 0; u.pshare_pm = -1;
    nvn_vitals_left2(b, sizeof b, &u, 1); EQ(b, ""); nvn_vitals_right2(b, sizeof b, &u, 1); EQ(b, "");

    // The menu header's compact line: no bolt; time then heat word drop; shown with stale figures as heat, battery and time
    nvn_vitals_compact(b, sizeof b, &v, 60, 0, 1, &d, 0); EQ(b, "60 fps · 🌡 Warm · ▮82% · 9:41");
    nvn_vitals_compact(b, sizeof b, &v, 60, 0, 1, &d, 1); EQ(b, "60 fps · 🌡 Warm · ▮82%");
    nvn_vitals_compact(b, sizeof b, &v, 60, 0, 1, &d, 2); EQ(b, "60 fps · 🌡 · ▮82%");
    nvn_vitals_compact(b, sizeof b, &old, 60, 0, 0, &d, 0); EQ(b, "🌡 Warm · ▮82% · 9:41");

    // Truncation keeps the buffer terminated, and the length says what was wanted
    char small[8]; size_t want = nvn_vitals_left(small, sizeof small, &v, 60, 0, 21, 1, 0, 0);
    TRUE(want == strlen("60 fps · CPU 2.1 W")); TRUE(strlen(small) < sizeof small);

    // Hysteresis: ±1 fps holds, a 0.2 W move must last two ticks
    nvn_vitals_smooth s = {0}; int f, w;
    nvn_vitals_smooth_step(&s, 60, 21, &f, &w); TRUE(f == 60 && w == 21);
    nvn_vitals_smooth_step(&s, 59, 22, &f, &w); TRUE(f == 60 && w == 21);   // within ±1 and under 0.2 W
    nvn_vitals_smooth_step(&s, 57, 25, &f, &w); TRUE(f == 57 && w == 21);   // fps moves at once; W waits a tick
    nvn_vitals_smooth_step(&s, 57, 25, &f, &w); TRUE(f == 57 && w == 25);   // two ticks: it moves
    nvn_vitals_smooth_step(&s, 58, 28, &f, &w); TRUE(f == 57 && w == 25);   // a new move starts its own wait
    nvn_vitals_smooth_step(&s, 58, 21, &f, &w); TRUE(w == 25);              // a different value: still waiting, now for 2.1
    nvn_vitals_smooth_step(&s, 58, 21, &f, &w); TRUE(w == 21);
    nvn_vitals_smooth_step(&s, -1, -1, &f, &w); TRUE(f == -1 && w == -1);   // unknown passes through

    // The seqlock: a reader never mixes two windows
    pthread_t th; pthread_create(&th, NULL, writer, NULL);
    int reads = 0;
    for (int i = 0; i < 200000; i++) {
        nvn_vitals r;
        if (!nvn_vitals_read(&g_pub, &r)) continue;
        reads++;
        if (r.stamp_ns && ((uint64_t)r.cpu_mw != r.stamp_ns || (uint64_t)r.fps10 != r.stamp_ns || (uint64_t)r.max_gap_100us != r.stamp_ns || (uint64_t)r.gen10 != r.stamp_ns || (uint64_t)r.shown10 != r.stamp_ns)) atomic_store(&g_torn, 1);
    }
    atomic_store(&g_stop, 1); pthread_join(th, NULL);
    TRUE(!atomic_load(&g_torn)); TRUE(reads > 0);

    if (fails) { fprintf(stderr, "t_vitals: %d failures\n", fails); return 1; }
    printf("t_vitals: ok (%d seqlock reads)\n", reads);
    return 0;
}
