// The window textures' render area (../nvn/nvn_win_area.h, nvn_mtl.m present_enqueue and rp_begin_ex_): the largest crop presented, active after WA_HOLD presents, off at once when
// the crop grows and on again once the new one has held, none for a crop of (nearly) the whole texture, and the pass rule (window textures only, the same area, level 0 slice 0,
// a depth attachment no smaller than the area)
#include "../nvn/nvn_win_area.h"
#include <stdio.h>
#include <string.h>

static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
#define AREA(w, h) ((uint32_t)(w) << 16 | (uint32_t)(h))

int main(void) {
    static wa_table t; int crop[4] = {0, 0, 1920, 1080}, act = 0;
    // Bananza on the iPhone: three 2880x1620 window textures presented in turn, a 1920x1080 crop at the origin
    for (int i = 0; i < 3 * WA_HOLD; i++) act += wa_present(&t, 100 + i % 3, 2880, 1620, crop);
    CHECK("not before WA_HOLD presents of each texture", wa_area(&t, 100) == 0 && act == 0);
    for (int i = 0; i < 3; i++) act += wa_present(&t, 100 + i, 2880, 1620, crop);
    CHECK("each texture's area is the crop once held, one activation each", wa_area(&t, 100) == AREA(1920, 1080) && wa_area(&t, 101) == AREA(1920, 1080) && wa_area(&t, 102) == AREA(1920, 1080) && act == 3);
    CHECK("an unknown texture has none", wa_area(&t, 7) == 0);
    // A smaller crop keeps the largest; a larger one turns the area off at once, and it comes back at the new size after WA_HOLD presents
    int small[4] = {0, 0, 1280, 720}; wa_present(&t, 100, 2880, 1620, small);
    CHECK("a smaller crop keeps the largest crop's area", wa_area(&t, 100) == AREA(1920, 1080));
    int big[4] = {0, 0, 2048, 1152}; wa_present(&t, 100, 2880, 1620, big);
    CHECK("a larger crop: the whole texture at once", wa_area(&t, 100) == 0);
    for (int i = 0; i < WA_HOLD; i++) wa_present(&t, 100, 2880, 1620, crop);
    CHECK("the new largest crop once it has held", wa_area(&t, 100) == AREA(2048, 1152));
    // An offset crop counts to its far edge; a crop past the texture is clamped; no crop is the whole texture: no area
    static wa_table u; int off[4] = {100, 60, 1920, 1080};
    for (int i = 0; i <= WA_HOLD; i++) wa_present(&u, 5, 2880, 1620, off);
    CHECK("an offset crop counts to its far edge", wa_area(&u, 5) == AREA(2020, 1140));
    for (int i = 0; i <= WA_HOLD; i++) wa_present(&u, 6, 1920, 1080, NULL);
    CHECK("no crop: none", wa_area(&u, 6) == 0);
    int most[4] = {0, 0, 1900, 1070}; for (int i = 0; i <= WA_HOLD; i++) wa_present(&u, 8, 1920, 1080, most);
    CHECK("a crop of over 90% of the texture: none", wa_area(&u, 8) == 0);
    // The pass rule
    uint64_t s1[2] = {101, 0}, s2[2] = {101, 102}, s3[2] = {101, 999}; uint32_t lv0[2] = {0, 0}, lv1[2] = {1, 0}, sl[2] = {0, 0};
    CHECK("a window texture with its depth-stencil of the same size", wa_pass(&t, 2, s1, lv0, sl, 2880, 1620) == AREA(1920, 1080));
    CHECK("no depth", wa_pass(&t, 1, s1, lv0, sl, 0, 0) == AREA(1920, 1080));
    CHECK("two window textures of one area", wa_pass(&t, 2, s2, lv0, sl, 0, 0) == AREA(1920, 1080));
    CHECK("a window texture beside another target: the whole pass", wa_pass(&t, 2, s3, lv0, sl, 0, 0) == 0);
    CHECK("a mip level: the whole pass", wa_pass(&t, 1, s1, lv1, sl, 0, 0) == 0);
    CHECK("a depth attachment smaller than the area: the whole pass", wa_pass(&t, 1, s1, lv0, sl, 1280, 720) == 0);
    uint64_t none[1] = {0}; CHECK("no colour attachment: the whole pass", wa_pass(&t, 1, none, lv0, sl, 2880, 1620) == 0);
    // Slots are reused oldest first: a ninth texture evicts the first
    static wa_table v; for (uint64_t s = 1; s <= WA_N + 1; s++) for (int i = 0; i <= WA_HOLD; i++) wa_present(&v, s, 2880, 1620, crop);
    CHECK("the oldest texture's slot taken by a new one", wa_area(&v, 1) == 0 && wa_area(&v, WA_N + 1) == AREA(1920, 1080) && wa_area(&v, 2) == AREA(1920, 1080));
    // A full-size boot present, then a 1920x1080 crop: the area comes after the smaller crop has held WA_SHRINK presents (Bananza's composite texture)
    static wa_table w; int full[4] = {0, 0, 2880, 1620};
    for (int i = 0; i <= WA_HOLD; i++) wa_present(&w, 50, 2880, 1620, full);
    CHECK("a full-size crop: no area", wa_area(&w, 50) == 0);
    for (int i = 0; i < WA_SHRINK - 1; i++) wa_present(&w, 50, 2880, 1620, crop);
    CHECK("the smaller crop not yet held long enough", wa_area(&w, 50) == 0);
    for (int i = 0; i < 2; i++) wa_present(&w, 50, 2880, 1620, crop);
    CHECK("the smaller crop, held WA_SHRINK presents, is the area", wa_area(&w, 50) == AREA(1920, 1080));
    wa_present(&w, 50, 2880, 1620, full);
    CHECK("it grows again: the whole texture at once", wa_area(&w, 50) == 0);
    // A moving crop (dynamic resolution) does not shrink the largest
    static wa_table m; int a[4] = {0, 0, 1920, 1080}, b2[4] = {0, 0, 1600, 900};
    for (int i = 0; i < 3 * WA_SHRINK; i++) wa_present(&m, 60, 2880, 1620, i % 7 < 3 ? a : b2);
    CHECK("a crop moving every few presents keeps its largest", wa_area(&m, 60) == AREA(1920, 1080));
    printf("t_win_area: %d of %d checks passed\n", checks - failed, checks);
    return failed != 0;
}
