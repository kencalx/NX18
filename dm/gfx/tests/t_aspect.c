// Ultrawide's camera on the graphics side (../nvn/nvn_aspect.h, nvn_mtl.m rp_begin_ex_ and draw_): which target is the final picture, which draws on it are the HUD, and how
// far they are squeezed. Cases adapted from ComicBit/nxnative eb9a42ba4 / c508572fa (MIT)
#include "../nvn/nvn_aspect.h"
#include <stdio.h>

static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
#define NEAR(a, b) (fabs((a) - (b)) < 1e-9)

int main(void) {
    // The final picture's shape and kind
    CHECK("a docked or handheld 16:9 packed / float target is a candidate", nvn_aspect_canvas_candidate(1920, 1080, 0, 0, 1) && nvn_aspect_canvas_candidate(1280, 720, 0, 0, 1));
    CHECK("a 16:9 target within 1 % (a width a multiple of 8) is a candidate", nvn_aspect_canvas_candidate(1928, 1080, 0, 0, 1));
    CHECK("a scene target with depth is not", !nvn_aspect_canvas_candidate(1600, 900, 0, 1, 1));
    CHECK("a mip level is not", !nvn_aspect_canvas_candidate(1920, 1080, 1, 0, 1));
    CHECK("an RGBA8 target is not", !nvn_aspect_canvas_candidate(1920, 1080, 0, 0, 0));
    CHECK("a taller picture (Picture shape 1.43) is not", !nvn_aspect_canvas_candidate(1920, 1344, 0, 0, 1));
    CHECK("a small or empty target is not", !nvn_aspect_canvas_candidate(320, 180, 0, 0, 1) && !nvn_aspect_canvas_candidate(1920, 0, 0, 0, 1));

    // The squeeze: 16:9 / ratio, none at 16:9 or narrower
    double r = 2868.0 / 1320;   // an iPhone 18 Pro Max in landscape
    CHECK("the iPhone's ratio squeezes by 16:9 / ratio", NEAR(nvn_aspect_ui_scale(r), (16.0 / 9.0) / r));
    CHECK("16:9, narrower, zero, NaN: no squeeze", nvn_aspect_ui_scale(16.0 / 9.0) == 1 && nvn_aspect_ui_scale(4.0 / 3.0) == 1 && nvn_aspect_ui_scale(0) == 1 && nvn_aspect_ui_scale(NAN) == 1);
    nvn_aspect_rect a = nvn_aspect_ui_rect((nvn_aspect_rect){0, 0, 1920, 1080}, 960, 0.5);
    CHECK("a full-width quad becomes the middle half, height kept", NEAR(a.x, 480) && NEAR(a.w, 960) && a.y == 0 && a.h == 1080);
    a = nvn_aspect_ui_rect((nvn_aspect_rect){1800, 40, 100, 50}, 960, 0.8);
    CHECK("a right-edge widget moves toward the centre and narrows", NEAR(a.x, 960 + 840 * 0.8) && NEAR(a.w, 80) && a.y == 40 && a.h == 50);
    a = nvn_aspect_ui_rect((nvn_aspect_rect){0, 0, 1280, 720}, 640, 0.5);
    CHECK("handheld content in the corner of a 1920 picture: about its own middle", NEAR(a.x, 320) && NEAR(a.w, 640));

    // Which draws are the HUD
    CHECK("a six-index quad on the final picture", nvn_aspect_ui_draw(1, 6, 0));
    CHECK("not a full-screen triangle, a mesh, a GPU-drawn scene picture or another target", !nvn_aspect_ui_draw(1, 3, 0) && !nvn_aspect_ui_draw(1, 3000, 0) && !nvn_aspect_ui_draw(1, 6, 1) && !nvn_aspect_ui_draw(0, 6, 0));
    CHECK("a packed picture's quads, a float picture's only by the profile's shaders", nvn_aspect_ui_shader(0, 0) && nvn_aspect_ui_shader(1, 1) && !nvn_aspect_ui_shader(1, 0));
    const char *pre = "7f2113e2 e9fd7b43 1469983f";
    CHECK("a key with a listed prefix (translated variants too)", nvn_aspect_ui_prefix("e9fd7b43aa001122", pre) && nvn_aspect_ui_prefix("1469983f00000000_bx", pre));
    CHECK("an unlisted key, a key that only contains one, an empty list, no key", !nvn_aspect_ui_prefix("00000000e9fd7b43", pre) && !nvn_aspect_ui_prefix("e9fd7b43aa", "")
          && !nvn_aspect_ui_prefix(NULL, pre) && !nvn_aspect_ui_prefix("e9fd7b4", pre));

    // The window textures and the final picture, pass by pass
    static nvn_aspect_wins w; static nvn_aspect_canvas c;
    uint32_t span = 0, ww = 0;
    nvn_aspect_win_note(&w, 900, 1920, 0, 0); nvn_aspect_win_note(&w, 901, 1920, 0, 1280); nvn_aspect_win_note(&w, 900, 1920, 0, 0);
    CHECK("presented textures are known, others not", nvn_aspect_is_win(&w, 900, NULL, NULL) && nvn_aspect_is_win(&w, 901, &span, &ww) && !nvn_aspect_is_win(&w, 50, NULL, NULL) && !nvn_aspect_is_win(&w, 0, NULL, NULL));
    CHECK("with the crop across and the width", span == 1280 && ww == 1920);
    nvn_aspect_win_note(&w, 902, 1920, 1000, 1280);
    CHECK("a crop past the texture counts as the whole width", nvn_aspect_is_win(&w, 902, &span, NULL) && span == 0);
    for (uint64_t s = 1000; s < 1000 + NVN_ASPECT_WINS; s++) nvn_aspect_win_note(&w, s, 1920, 0, 0);
    CHECK("the oldest is forgotten after NVN_ASPECT_WINS new ones", !nvn_aspect_is_win(&w, 900, NULL, NULL) && nvn_aspect_is_win(&w, 1000 + NVN_ASPECT_WINS - 1, NULL, NULL));
    nvn_aspect_canvas_pass(&c, 10, 0, 0, 0, 1, 1920, 1080);   // the scene's 16:9 target
    CHECK("no final picture before a window pass", c.canvas == 0);
    nvn_aspect_canvas_pass(&c, 11, 0, 0, 0, 0, 1600, 900);    // a depth pass: not a candidate
    nvn_aspect_canvas_pass(&c, 12, 0, 0, 0, 1, 1920, 1080);   // the HUD target
    nvn_aspect_canvas_pass(&c, 900, 1, 0, 1920, 0, 1920, 1080);   // the window texture, shown whole (docked)
    CHECK("the last candidate before a window pass is the final picture, its middle the HUD's centre", c.canvas == 12 && NEAR(c.cx, 960));
    nvn_aspect_canvas_pass(&c, 13, 0, 0, 0, 1, 1920, 1080);
    CHECK("a new target of its size takes its place at once (before its HUD is drawn)", c.canvas == 13);
    nvn_aspect_canvas_pass(&c, 900, 1, 1280, 1920, 0, 1920, 1080);   // handheld: 1280x720 drawn in the corner, the window's crop 1280 wide
    CHECK("a picture as wide as the window, shown cropped: the crop's middle", c.canvas == 13 && NEAR(c.cx, 640));
    nvn_aspect_canvas_pass(&c, 14, 0, 0, 0, 1, 1280, 720);
    CHECK("one of another size waits for the next window pass", c.canvas == 13);
    nvn_aspect_canvas_pass(&c, 900, 1, 1280, 1920, 0, 1920, 1080);
    CHECK("which makes it the final picture; narrower than the window: its own middle", c.canvas == 14 && c.w == 1280 && c.h == 720 && NEAR(c.cx, 640));

    printf("%d checks, %d failed\n", checks, failed);
    return failed != 0;
}
