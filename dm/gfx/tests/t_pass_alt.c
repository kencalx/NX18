// Passes drawn every other frame (../nvn/nvn_pass_alt.h): alternates on one texture, a reopened pass keeps its frame's decision, a new texture or a gap in frames draws; several targets at
// once (each level of a cube); the profile's shapes: <W>x<H>:<colour>/<depth> and cube:<colour>
#include "../nvn/nvn_pass_alt.h"
#include <stdio.h>
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
int main(void) {
    pa_state s = {0};
    int d1 = pa_decide(&s, 7, 100), d2 = pa_decide(&s, 7, 101), d3 = pa_decide(&s, 7, 102), d4 = pa_decide(&s, 7, 103);
    CHECK("draw, keep, draw, keep on one texture", d1 == PA_DRAW && d2 == PA_KEEP && d3 == PA_DRAW && d4 == PA_KEEP);
    CHECK("a pass reopened in a kept frame is kept", pa_decide(&s, 7, 103) == PA_KEEP);
    CHECK("a pass reopened in a drawn frame is drawn", pa_decide(&s, 7, 104) == PA_DRAW && pa_decide(&s, 7, 104) == PA_DRAW);
    CHECK("a new texture draws", pa_decide(&s, 8, 105) == PA_DRAW);
    CHECK("and then alternates", pa_decide(&s, 8, 106) == PA_KEEP);
    CHECK("a gap in frames (the view came back) draws", pa_decide(&s, 8, 110) == PA_DRAW && pa_decide(&s, 8, 111) == PA_KEEP);
    pa_state z = {0}; CHECK("the first pass ever draws", pa_decide(&z, 1, 0) == PA_DRAW);
    // The table: one texture alone behaves as one state (the <W>x<H> shape, sub 0)
    pa_table t = {0};
    int t1 = pa_decide_in(&t, 7, 0, 100, 1), t2 = pa_decide_in(&t, 7, 0, 101, 1), t3 = pa_decide_in(&t, 7, 0, 102, 1), t4 = pa_decide_in(&t, 7, 0, 103, 1);
    CHECK("table: draw, keep, draw, keep on one texture", t1 == PA_DRAW && t2 == PA_KEEP && t3 == PA_DRAW && t4 == PA_KEEP);
    CHECK("table: a reopened pass keeps its frame's decision", pa_decide_in(&t, 7, 0, 103, 1) == PA_KEEP && pa_decide_in(&t, 7, 0, 104, 1) == PA_DRAW && pa_decide_in(&t, 7, 0, 104, 1) == PA_DRAW);
    // A cube's mip chain (levels 1-7 of texture 20) and a second cube (texture 21, level 0 and 1) every frame: each target alternates, all in step, and a second texture between two levels
    // of the first does not reset them (one state would have drawn every frame)
    pa_table c = {0}; int step = 1;
    for (uint64_t f = 200; f < 208; f++) {
        int want = (f - 200) % 2 ? PA_KEEP : PA_DRAW;
        for (uint32_t lv = 1; lv < 8; lv++) { step &= pa_decide_in(&c, 20, lv << 16, f, PA_CUBE_GAP) == want; if (lv == 4) step &= pa_decide_in(&c, 21, 0, f, PA_CUBE_GAP) == want; }
        step &= pa_decide_in(&c, 21, 1 << 16, f, PA_CUBE_GAP) == want;
    }
    CHECK("cube levels and a second cube each alternate, in step", step);
    // One face a frame, round robin over six (a game that time-slices its filter): each face comes back after six frames, past PA_CUBE_GAP, so each always draws and none is left
    // longer than the game leaves it
    pa_table r = {0}; int all = 1;
    for (uint64_t f = 300; f < 336; f++) all &= pa_decide_in(&r, 30, (uint32_t)(f % 6), f, PA_CUBE_GAP) == PA_DRAW;
    CHECK("a face updated once every six frames always draws", all);
    // Ocarina of Time: faces 0-1, 2-3 and 4-5 with their levels 1-7 on three frames in turn: each target draws on every other visit (every sixth frame), every face is redrawn once in
    // six frames, and the faces of one frame keep one decision
    pa_table g = {0}; int half = 1, drawn = 0, kept = 0;
    for (uint64_t f = 600; f < 636; f++) {
        uint32_t f0 = (uint32_t)((f - 600) % 3) * 2; int want = (f - 600) % 6 < 3 ? PA_DRAW : PA_KEEP;
        for (uint32_t face = f0; face < f0 + 2; face++) for (uint32_t lv = 0; lv < 8; lv++) { int d = pa_decide_in(&g, 60, lv << 16 | face, f, PA_CUBE_GAP); half &= d == want; drawn += d == PA_DRAW; kept += d == PA_KEEP; }
    }
    CHECK("a cube spread over three frames: each target on every other visit, half drawn", half && drawn == kept);
    CHECK("and the same three-frame cube with the next-frame rule (gap 1) always draws", ({ pa_table h = {0}; int a1 = 1; for (uint64_t f = 700; f < 712; f++) a1 &= pa_decide_in(&h, 70, (uint32_t)(f % 3), f, 1) == PA_DRAW; a1; }));
    // Two cubes on alternate frames: each comes back after two frames, within PA_CUBE_GAP: each draws on every other visit
    pa_table a = {0}; int alt = 1;
    for (uint64_t f = 400; f < 412; f++) alt &= pa_decide_in(&a, 40 + f % 2, 0, f, PA_CUBE_GAP) == ((f - 400) % 4 < 2 ? PA_DRAW : PA_KEEP);
    CHECK("two cube textures drawn on alternate frames each draw on every other visit", alt);
    // More targets than slots: the oldest goes and draws when it comes back
    pa_table o = {0}; for (uint64_t k = 0; k < PA_SLOTS; k++) pa_decide_in(&o, 50 + k, 0, 500, 1);
    CHECK("a full table: the first target still alternates", pa_decide_in(&o, 50, 0, 501, 1) == PA_KEEP);
    pa_decide_in(&o, 999, 0, 501, 1); pa_decide_in(&o, 998, 0, 501, 1);   // two new targets take the two oldest slots, 50's (drawn at 500, kept at 501) and 51's
    CHECK("a replaced target draws when it comes back, though it ran the frame before", pa_decide_in(&o, 50, 0, 502, 1) == PA_DRAW);
    // Shapes: Bananza's 128x128 view and its cubes
    const pa_shape sh[2] = {{128, 128, 92, 252, 0}, {0, 0, 92, 0, 1}};
    CHECK("the view's size and formats match the first shape", pa_match(sh, 2, 128, 128, 92, 252, 0) == 0);
    CHECK("the view's size with another depth format matches nothing", pa_match(sh, 2, 128, 128, 92, 260, 0) == -1);
    CHECK("the view's size and colour with no depth matches nothing (a <W>x<H> shape needs its depth)", pa_match(sh, 2, 128, 128, 92, 0, 0) == -1);
    CHECK("a cube in the format with no depth matches the cube shape, any size", pa_match(sh, 2, 128, 128, 92, 0, 1) == 1 && pa_match(sh, 2, 32, 32, 92, 0, 1) == 1);
    CHECK("a cube with a depth attachment matches nothing (a scene capture)", pa_match(sh, 2, 64, 64, 92, 252, 1) == -1);
    CHECK("a cube in another format matches nothing", pa_match(sh, 2, 128, 128, 115, 0, 1) == -1);
    CHECK("a 2D texture in the format with no depth matches nothing", pa_match(sh, 2, 64, 64, 92, 0, 0) == -1);
    CHECK("no shapes: nothing matches", pa_match(sh, 0, 128, 128, 92, 252, 0) == -1);
    printf("t_pass_alt: %d of %d checks passed\n", checks - failed, checks);
    return failed != 0;
}
