// The touch controls drawn into the game's frame (touch_draw.h): the sequence lock between the main thread and the present thread (a reader never sees half a frame, and gets the
// last one written), the canvas test against the drawable's size, the picture's rectangle in pixels, and the atlas's shelves (none overlapping, all inside it)
#include "../touch_draw.h"
#include <pthread.h>
#include <stdio.h>

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)

static touch_box g_box;
static _Atomic int g_stop;
static void fill(touch_frame *f, uint32_t k) {   // every word follows from k, so a frame mixed from two writes shows
    memset(f, 0, sizeof *f);
    f->canvas_w = k; f->canvas_h = k ^ 0x5a5a5a5a; f->on = k & 1; f->atlas = k * 3; f->n = k % TOUCH_QUADS;
    for (int i = 0; i < TOUCH_QUADS; i++) for (int j = 0; j < 4; j++) { f->q[i].dst[j] = (float)(k % 1000) + i; f->q[i].src[j] = (float)(k % 777) - j; }
}
static int whole(const touch_frame *f) { touch_frame g; fill(&g, f->canvas_w); return !memcmp(&g, f, sizeof g); }
static void *writer(void *a) {
    (void)a; touch_frame f;
    for (uint32_t k = 9; k <= 200000; k++) { fill(&f, k); touch_publish(&g_box, &f); }   // after the 8 published before the writer starts
    atomic_store(&g_stop, 1); return NULL;
}

int main(void) {
    touch_frame f, r;
    CHECK(!touch_read(&g_box, &r), "nothing published: no frame");
    fill(&f, 7); touch_publish(&g_box, &f);
    CHECK(touch_read(&g_box, &r) && !memcmp(&f, &r, sizeof f), "one write: read back as written");
    fill(&f, 8); touch_publish(&g_box, &f);
    CHECK(touch_read(&g_box, &r) && r.canvas_w == 8, "the last write wins");

    pthread_t t; pthread_create(&t, NULL, writer, NULL);
    unsigned long reads = 0, torn = 0, back = 0; uint32_t last = 0;
    while (!atomic_load(&g_stop)) if (touch_read(&g_box, &r)) { reads++; if (!whole(&r)) torn++; if (r.canvas_w < last) back++; last = r.canvas_w; }
    pthread_join(t, NULL);
    CHECK(reads > 0, "the reader got frames while the writer ran");
    CHECK(!torn, "no frame read mixes two writes");
    CHECK(!back, "frames are read in the order written");
    CHECK(touch_read(&g_box, &r) && r.canvas_w == 200000 && whole(&r), "after the writer: its last frame");
    printf("t_touch_draw: %lu frames read during 200000 writes\n", reads);

    memset(&f, 0, sizeof f);
    CHECK(!touch_frame_fits(&f, 2868, 1320), "no canvas: fits no drawable");
    f.canvas_w = 2868; f.canvas_h = 1320;
    CHECK(touch_frame_fits(&f, 2868, 1320), "its own drawable");
    CHECK(touch_frame_fits(&f, 2867, 1321), "within a pixel (the layer rounds)");
    CHECK(!touch_frame_fits(&f, 2346, 1320), "the Fit picture's drawable before the layout: not this frame's");
    // The sequence a frame is published with comes back with it; a later one is "since" an earlier one, across the wrap too
    { touch_box b2 = {0}; touch_frame g = {0}; g.canvas_w = 5;
      uint32_t s1 = touch_publish(&b2, &g), s2 = touch_publish(&b2, &g);
      CHECK(s1 && s2 && touch_seq_since(s2, s1) && !touch_seq_since(s1, s2) && touch_read(&b2, &r) == s2, "a frame's sequence: returned by the writer and the reader");
      atomic_store(&b2.seq, 0xfffffffeu); uint32_t s3 = touch_publish(&b2, &g);
      CHECK(s3 == 2 && touch_seq_since(s3, 0xfffffffeu), "the sequence skips 0 at the wrap (0 is no frame)"); }

    // An off frame (the front end leaving) places the picture on a drawable of its canvas only until a live present had another one; on and placing frames always do
    { touch_frame g = {0}; uint32_t dead = 0; g.canvas_w = 2868; g.canvas_h = 1320; g.pic[0] = 0.09f; g.pic[2] = 0.82f; g.pic[3] = 1;
      g.on = TOUCH_OFF;
      CHECK(touch_frame_places(&g, 10, &dead, 1), "off: a drawable made before the game view left the canvas still places the picture there");
      CHECK(!touch_frame_places(&g, 10, &dead, 0) && dead == 10, "off: the first drawable of another size kills it");
      CHECK(!touch_frame_places(&g, 10, &dead, 1), "off: a later drawable of the canvas's size (Stretch, DM_DRAWABLE_NATIVE) takes the present's own fit");
      CHECK(touch_frame_places(&g, 12, &dead, 1), "a frame published since is not the dead one");
      g.on = TOUCH_ON; CHECK(touch_frame_places(&g, 10, &dead, 1) && !touch_frame_places(&g, 10, &dead, 0), "on: by the size alone");
      g.on = TOUCH_PLACE; dead = 0; CHECK(!touch_frame_places(&g, 14, &dead, 0) && dead == 0 && touch_frame_places(&g, 14, &dead, 1), "placing: a drawable from before the layout does not kill it");
      touch_frame z = {0}; dead = 0; CHECK(!touch_frame_places(&z, 16, &dead, 0) && !dead, "no canvas: nothing"); }

    // The live presents in a row that a frame that is on does not fit: reported once, at TOUCH_UNFIT, again only after one fitted
    { touch_frame g = {0}; uint32_t run = 0; int said = 0; g.on = TOUCH_ON; g.canvas_w = 100; g.canvas_h = 50;
      for (int i = 0; i < TOUCH_UNFIT - 1; i++) said += touch_unfit_step(&run, &g, 0);
      CHECK(!said, "a layout change's few drawables of the old size: not reported");
      said += touch_unfit_step(&run, &g, 0); for (int i = 0; i < 100; i++) said += touch_unfit_step(&run, &g, 0);
      CHECK(said == 1, "reported once while it lasts");
      touch_unfit_step(&run, &g, 1); for (int i = 0; i < TOUCH_UNFIT; i++) said += touch_unfit_step(&run, &g, 0);
      CHECK(said == 2, "again after a fitting present");
      g.on = TOUCH_OFF; run = 0; for (int i = 0; i < 2 * TOUCH_UNFIT; i++) said += touch_unfit_step(&run, &g, 0);
      CHECK(said == 2, "a frame that is off is not the controls missing"); }

    double px[4];
    CHECK(!touch_picture_px(&f, 2868, 1320, px), "no picture rectangle: the present's own fit");
    // Fit on an iPhone 18 Pro Max in landscape: the 782 x 440 point picture at x 87 of 956 points, at 3 pixels a point
    f.pic[0] = 87 / 956.f; f.pic[1] = 0; f.pic[2] = 782 / 956.f; f.pic[3] = 1;
    CHECK(touch_picture_px(&f, 2868, 1320, px) && px[0] == 261 && px[1] == 0 && px[2] == 2346 && px[3] == 1320, "Fit: the picture where the view had it, in whole pixels");
    // A portrait split: the picture above the controls, on a canvas that is the whole screen
    f.canvas_w = 1320; f.canvas_h = 2868; f.pic[0] = 0; f.pic[1] = 62 / 956.f; f.pic[2] = 1; f.pic[3] = 247.5f / 956.f;
    CHECK(touch_picture_px(&f, 1320, 2868, px) && px[0] == 0 && px[1] == 186 && px[2] == 1320 && fabs(px[3] - 742) <= 1, "portrait: the picture at the top, the rest below");
    f.pic[0] = -0.1f; f.pic[1] = -0.1f; f.pic[2] = 1.2f; f.pic[3] = 1.2f;
    CHECK(touch_picture_px(&f, 100, 100, px) && px[0] == 0 && px[1] == 0 && px[2] == 100 && px[3] == 100, "a rectangle past the canvas is cut to it");

    // DM_PRESENT_DRAWABLE=game: the canvas at the picture's render size, the controls laid out on the smaller drawable
    { int bad;
      CHECK(touch_drawable_game("game", &bad) && !bad, "game: the picture's render size");
      CHECK(!touch_drawable_game(NULL, &bad) && !bad && !touch_drawable_game("", &bad) && !bad && !touch_drawable_game("screen", &bad) && !bad, "unset, empty or screen: the screen's pixels");
      CHECK(!touch_drawable_game("1", &bad) && bad, "another value: the screen's pixels, said");
      // Fit in landscape on an iPhone 18 Pro Max: a 956 x 440 point canvas, the picture 782 x 440 points at x 87, rendered at 1920 x 1080
      double s = touch_drawable_scale(782, 440, 1920, 1080, 3);
      CHECK(fabs(s - fmax(1920.0 / 782, 1080.0 / 440)) < 1e-9 && s < 3, "Fit: the direction that needs more takes all of its pixels, below the screen's 3");
      touch_frame g = {0}; g.canvas_w = (uint32_t)lround(956 * s); g.canvas_h = (uint32_t)lround(440 * s);   // DmGamepad.m touchFrameHead
      double dw = round(956 * s), dh = round(440 * s);   // front_ios.m DmGameView layoutSubviews
      CHECK(dw == 2347 && dh == 1080, "a 2347 x 1080 drawable instead of 2868 x 1320");
      CHECK(touch_frame_fits(&g, dw, dh), "the frame fits the smaller drawable");
      CHECK(!touch_frame_fits(&g, 2868, 1320), "and not the screen's (a drawable from before the switch draws no control)");
      g.pic[0] = 87 / 956.f; g.pic[2] = 782 / 956.f; g.pic[3] = 1;
      CHECK(touch_picture_px(&g, dw, dh, px) && px[0] == 214 && px[1] == 0 && fabs(px[2] - 1920) <= 1 && px[3] == 1080, "the picture 1:1 at 1920 x 1080 on it");
      // A control at 40, 300 points, 80 x 80: its quad is normalized on the canvas, so it lands at the same place on the screen, at the drawable's pixels
      touch_quad q = {{40 / 956.f, 300 / 440.f, 80 / 956.f, 80 / 440.f}, {0, 0, 1, 1}};
      double qx = q.dst[0] * dw, qy = q.dst[1] * dh, qw = q.dst[2] * dw, qh = q.dst[3] * dh;
      CHECK(fabs(qx - 40 * s) < 1 && fabs(qy - 300 * s) < 1 && fabs(qw - 80 * s) < 1 && fabs(qh - 80 * s) < 1, "a control at its points times the drawable's scale, within a pixel");
      CHECK(fabs(qw / qh - 1) < 0.002, "and keeps its shape (one scale both ways)");
      // Picture Stretch over a 956 x 440 screen: one scale both ways, the height's
      CHECK(fabs(touch_drawable_scale(956, 440, 1920, 1080, 3) - 1080.0 / 440) < 1e-9, "Stretch: the picture's height");
      // A portrait split: the picture 440 x 247.5 points above the controls; its width needs more than the screen has: the screen's
      CHECK(touch_drawable_scale(440, 247.5, 1920, 1080, 3) == 3, "portrait: never above the screen's scale");
      CHECK(touch_drawable_scale(782, 440, 0, 0, 3) == 3 && touch_drawable_scale(0, 0, 1920, 1080, 3) == 3, "no render size or rectangle yet: the screen's");
      CHECK(fabs(touch_drawable_scale(782, 440, 1280, 720, 3) - 1280.0 / 782) < 1e-9, "a 720p picture: a smaller drawable still"); }

    int w[20], h[20], x[20], y[20], n = 0;
    for (int i = 0; i < 18; i++) { w[n] = 60 + (i * 37) % 450; h[n] = 50 + (i * 53) % 470; n++; }
    int H = touch_pack(n, w, h, 1024, 2, x, y);
    CHECK(H > 0, "18 pictures fit 1024 pixels across");
    int overlap = 0, outside = 0;
    for (int i = 0; i < n; i++) {
        if (x[i] < 2 || y[i] < 2 || x[i] + w[i] + 2 > 1024 || y[i] + h[i] + 2 > H) outside++;
        for (int j = i + 1; j < n; j++)
            if (x[i] < x[j] + w[j] + 2 && x[j] < x[i] + w[i] + 2 && y[i] < y[j] + h[j] + 2 && y[j] < y[i] + h[i] + 2) overlap++;
    }
    CHECK(!overlap, "no two pictures overlap, each with its gap");
    CHECK(!outside, "each inside the atlas, its gap too");
    int wide = 2000; CHECK(!touch_pack(1, &wide, h, 1024, 2, x, y), "a picture wider than the atlas: none");
    CHECK(!touch_pack(0, w, h, 1024, 2, x, y), "nothing to pack: no atlas");

    uint8_t bgra[3 * 4 * 2] = {10, 10, 10, 20, 11, 10, 11, 30, 255, 255, 255, 255,  0, 0, 0, 0, 100, 101, 100, 128, 7, 7, 7, 9}, rg[3 * 2 * 2];
    CHECK(touch_grey(bgra, 3, 2, 12, rg) && rg[0] == 10 && rg[1] == 20 && rg[2] == 10 && rg[3] == 30 && rg[8] == 101 && rg[9] == 128, "greys (within a level) become grey and alpha");
    bgra[4] = 40;
    CHECK(!touch_grey(bgra, 3, 2, 12, rg), "a colour keeps the atlas BGRA");

    printf("t_touch_draw: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
