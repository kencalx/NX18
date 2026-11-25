// The present crop's size line (../nvn/nvn_crop_area.h, nvn_mtl.m present_crop_note), logging only: the mean, smallest and largest share of the window texture the crop covered,
// the side length the mean and the smallest come to, the smallest and largest crop in pixels, the crop moves, the thermal state and the time since launch; no line for a game that
// never showed less than its whole texture with a crop that never moved, or with no presents; each interval starts empty and the session keeps its crop
#include "../nvn/nvn_crop_area.h"
#include <string.h>

static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)

int main(void) {
    char b[384]; nvn_crop_area a = {0};
    // A dynamic resolution in a 1920x1080 window texture: 100 presents at the whole texture, 200 at 70% a side (1344x756, 49% of it)
    for (int i = 0; i < 100; i++) nvn_crop_area_add(&a, 1920, 1080, 1920, 1080);
    for (int i = 0; i < 200; i++) nvn_crop_area_add(&a, 1920, 1080, 1344, 756);
    CHECK("NVN_CROP_AREA_PRESENTS presents in the window", a.n == NVN_CROP_AREA_PRESENTS);
    CHECK("a line once the crop has moved", nvn_crop_area_text(b, sizeof b, &a, 2, 7, 1, 812.3)); puts(b);
    CHECK("the mean share and its side", strstr(b, "present crop over 300 presents: 66.0% of the 1920x1080 window texture on average (81% a side)") != NULL);
    CHECK("the smallest: 70% a side is 49% of the texture, in pixels too", strstr(b, "smallest 49.0% (70% a side, 1344x756), largest 100.0% (1920x1080)") != NULL);
    CHECK("the moves in the window and so far", strstr(b, "crop moved 2 times in them, 7 so far") != NULL);
    CHECK("the thermal state and the time since launch", strstr(b, "; thermal 1, 812 s after launch") != NULL);
    nvn_crop_area_next(&a);
    CHECK("the next interval starts empty", a.n == 0 && a.sum == 0 && a.min_w == 0 && a.max_w == 0);

    nvn_crop_area w = {0};
    for (int i = 0; i < 10; i++) nvn_crop_area_add(&w, 1920, 1080, 1920, 1080);
    b[0] = 0;
    CHECK("no line for a game that sets no crop: every present the whole texture, no move", !nvn_crop_area_text(b, sizeof b, &w, 0, 0, 0, 10) && !b[0]);
    CHECK("no line with no presents", !nvn_crop_area_text(b, sizeof b, &a, 0, 5, 0, 10));
    nvn_crop_area f = {0};   // a fixed crop at 85% a side that never moves (or one that holds still until the phone heats up)
    for (int i = 0; i < NVN_CROP_AREA_PRESENTS; i++) nvn_crop_area_add(&f, 1920, 1080, 1632, 918);
    CHECK("a fixed sub-texture crop with no moves gets its line", nvn_crop_area_text(b, sizeof b, &f, 0, 0, 0, 5)); puts(b);
    CHECK("its share: 85% a side", strstr(b, "72.2% of the 1920x1080 window texture on average (85% a side), smallest 72.2% (85% a side, 1632x918), largest 72.2% (1632x918)")
          && strstr(b, "crop moved 0 times in them, 0 so far; thermal 0, 5 s after launch"));
    nvn_crop_area_next(&f); nvn_crop_area_add(&f, 1920, 1080, 1920, 1080);
    CHECK("the session keeps its crop: a later interval at the whole texture still gets its line", nvn_crop_area_text(b, sizeof b, &f, 0, 0, 2, 900) && strstr(b, "100.0% of the 1920x1080"));

    // The handheld vi layer crop: 1280x720 of a 1920x1080 texture at full resolution reads 44.4%; the pixels show the full size
    nvn_crop_area h = {0};
    nvn_crop_area_add(&h, 1920, 1080, 1280, 720);
    CHECK("a full-resolution crop of a larger texture: its pixels", nvn_crop_area_text(b, sizeof b, &h, 0, 0, -1, 3) && strstr(b, "44.4% of the 1920x1080") && strstr(b, "largest 44.4% (1280x720)")
          && strstr(b, "thermal -1, 3 s after launch"));

    for (int i = 0; i < 4; i++) nvn_crop_area_add(&a, 1920, 1080, 1600, 900);
    CHECK("a crop that holds still keeps its line once it has moved", nvn_crop_area_text(b, sizeof b, &a, 0, 7, 0, 60)); puts(b);
    CHECK("its share", strstr(b, "69.4% of the 1920x1080 window texture on average (83% a side), smallest 69.4% (83% a side, 1600x900), largest 69.4% (1600x900); crop moved 0 times in them, 7 so far") != NULL);
    nvn_crop_area_next(&a);

    nvn_crop_area_add(&a, 0, 0, 0, 0);
    CHECK("a texture with no size adds nothing", a.n == 0);
    nvn_crop_area_add(&a, 1280, 720, 1280, 720); nvn_crop_area_add(&a, 1920, 1080, 960, 540);
    CHECK("each present's share of its own texture; the line names the last texture", nvn_crop_area_text(b, sizeof b, &a, 1, 1, 0, 70) && strstr(b, "62.5% of the 1920x1080") && strstr(b, "smallest 25.0% (50% a side, 960x540), largest 100.0% (1280x720)"));
    nvn_crop_area z = {0};   // a long line: an 8K texture, a long session
    nvn_crop_area_add(&z, 16384, 16384, 16383, 16383); nvn_crop_area_add(&z, 16384, 16384, 1, 1);
    CHECK("a long line fits the buffer present_crop_note gives it", nvn_crop_area_text(b, sizeof b, &z, 999999999ull, 9999999999ull, 3, 9999999.0) && strlen(b) < 300);
    printf("t_crop_area: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
