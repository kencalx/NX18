// The iPhone's and iPad's touch controls drawn into the game's frame (docs/reference/frame-rate.md, "Touch controls over the game's layer cost a refresh of latency"): what the
// front end hands the present thread. A visible layer over the game's CAMetalLayer makes iOS composite the game's layer with it instead of sending its drawables straight to the
// display, which costs one refresh between the present and the screen. So while the touch controls show, the front end (DmGamepad.m) keeps its control layers hidden, as it does
// while a controller is in use, and hands the present a picture of each control once (an atlas: normal and pressed) and, at each change, where each one goes and which look it
// has (a touch_frame). The present thread (nvn_mtl.m present_encode_m4) draws them over the picture into the drawable, in the same render pass.
// One writer (the main thread), one reader (the present thread): a sequence lock whose words are copied one by one with relaxed atomics (touch_publish, touch_read), so neither
// side waits for the other and the reader never sees half a frame. Pure C, no Metal or UIKit: dm/host/tests/t_touch_draw.c tests it
#pragma once
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <math.h>
#include <stdlib.h>

enum { TOUCH_OFF = 0, TOUCH_ON = 1, TOUCH_PLACE = 2 };   // touch_frame on
#define TOUCH_QUADS 32   // the left stick's ring and knob and the 16 keys draw 18 at most
// One control: dst, where it goes on the canvas (x, y, w, h normalized on the canvas, y down); src, its look in the atlas (normalized on the atlas)
typedef struct { float dst[4], src[4]; } touch_quad;
typedef struct {
    uint32_t canvas_w, canvas_h;   // the drawable's pixels this frame is laid out for (the game view's points times its scale): a present into a drawable of another size draws no
                                   // control and keeps the picture's own fit (a drawable made before or after a layout change); 0: none
    uint32_t on;                   // TOUCH_ON: the controls are drawn (quads); TOUCH_PLACE: the canvas places the picture, no control drawn yet (the front end is making them for
                                   // a new layout); TOUCH_OFF: the canvas places the picture for the drawables made before the front end left it (touch_frame_places), nothing drawn
    uint32_t atlas;                // the generation of the atlas the quads' src rectangles are in: a present whose atlas is another one draws no control
    uint32_t n;                    // quads used
    float pic[4];                  // the game's picture on the canvas, normalized x, y, w, h (y down); w 0: the present's own centred fit (present_viewport)
    touch_quad q[TOUCH_QUADS];     // in the order Core Animation composited the layers: each over the ones before
} touch_frame;
#define TOUCH_WORDS (sizeof(touch_frame) / sizeof(uint32_t))
_Static_assert(sizeof(touch_frame) % sizeof(uint32_t) == 0, "touch_frame is copied in 32-bit words");
typedef struct { _Atomic uint32_t seq; _Atomic uint32_t w[TOUCH_WORDS]; } touch_box;

// The writer (one thread only): an odd sequence while the words change, the next even one once they are all written. Returns that even number, the frame's sequence (never 0:
// a wrap skips it), which the reader returns with it: the front end asks to hear when the present has drawn a frame from a given one on (mtl_present_touch_ack)
static inline uint32_t touch_publish(touch_box *b, const touch_frame *f) {
    uint32_t w[TOUCH_WORDS]; memcpy(w, f, sizeof w);
    uint32_t s = atomic_load_explicit(&b->seq, memory_order_relaxed), next = s + 2 ? s + 2 : 2;
    atomic_store_explicit(&b->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    for (size_t i = 0; i < TOUCH_WORDS; i++) atomic_store_explicit(&b->w[i], w[i], memory_order_relaxed);
    atomic_store_explicit(&b->seq, next, memory_order_release);
    return next;
}
// Whether sequence a is b or later (sequences wrap)
static inline int touch_seq_since(uint32_t a, uint32_t b) { return (int32_t)(a - b) >= 0; }
// The reader: the last whole frame written in f and its sequence (not 0), 0 when none has been written or the writer was in the middle of one each of the tries (the caller keeps
// its last copy)
static inline uint32_t touch_read(touch_box *b, touch_frame *f) {
    uint32_t w[TOUCH_WORDS];
    for (int tries = 0; tries < 16; tries++) {
        uint32_t s0 = atomic_load_explicit(&b->seq, memory_order_acquire);
        if (!s0) return 0;
        if (s0 & 1) continue;
        for (size_t i = 0; i < TOUCH_WORDS; i++) w[i] = atomic_load_explicit(&b->w[i], memory_order_relaxed);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&b->seq, memory_order_relaxed) == s0) { memcpy(f, w, sizeof w); return s0; }
    }
    return 0;
}

// Whether a frame was laid out for a drawable of dw x dh pixels (a pixel either way: the layer rounds the drawable's size)
static inline int touch_frame_fits(const touch_frame *f, double dw, double dh) {
    return f->canvas_w && f->canvas_h && fabs(dw - f->canvas_w) <= 1 && fabs(dh - f->canvas_h) <= 1;
}
// Whether the live present places the picture by frame f (sequence seq) on a drawable it fits (fits: touch_frame_fits). A frame that is on or placing: always. One that is off is the
// front end leaving (DmGamepad.m touchDraw:): it places the picture only for the drawables made before the game view left the canvas, so once a live present had a drawable it
// does not fit, that frame is dead (*dead, the present thread's) and places nothing again, even on a later drawable of its size (a later layout whose drawable happens to have the
// canvas's pixels: DM_DRAWABLE_NATIVE, Picture Stretch after Fit with a controller in use), which takes the present's own fit
static inline int touch_frame_places(const touch_frame *f, uint32_t seq, uint32_t *dead, int fits) {
    if (f->on) return fits;
    if (!fits) { if (f->canvas_w) *dead = seq; return 0; }
    return seq != *dead;
}
// The live presents in a row whose drawable a frame that is on does not fit (run, the present thread's): 1 once, at the TOUCH_UNFIT-th (the front end shows the layers again and
// lays the view out, DmGamepad.m touchUnfit), then 0 until one fits again. A layout change leaves a few drawables of the old size: fewer than TOUCH_UNFIT
#define TOUCH_UNFIT 30
static inline int touch_unfit_step(uint32_t *run, const touch_frame *f, int fits) {
    if (!f->on || fits) { *run = 0; return 0; }
    return ++*run == TOUCH_UNFIT;
}
// The picture's rectangle in whole pixels of a dw x dh drawable (x, y, w, h) from its normalized one, inside the drawable; 0 when it has none (the present's own fit)
static inline int touch_picture_px(const touch_frame *f, double dw, double dh, double out[4]) {
    if (!(f->pic[2] > 0 && f->pic[3] > 0)) return 0;
    double x0 = fmax(0, round(f->pic[0] * dw)), y0 = fmax(0, round(f->pic[1] * dh));
    double x1 = fmin(dw, round((f->pic[0] + f->pic[2]) * dw)), y1 = fmin(dh, round((f->pic[1] + f->pic[3]) * dh));
    if (x1 <= x0 || y1 <= y0) return 0;
    out[0] = x0; out[1] = y0; out[2] = x1 - x0; out[3] = y1 - y0;
    return 1;
}

// DM_PRESENT_DRAWABLE (front_ios.m): "game" sizes the drawable at the picture's render size while the touch controls are drawn into the frame too, and Core Animation scales the
// layer to the screen; "screen" or unset keeps the screen's pixels there, as before (elsewhere the drawable already takes the picture's render size where MetalFX does not run).
// 1 for game, 0 for screen or unset; *bad when the value is neither (then 0)
static inline int touch_drawable_game(const char *v, int *bad) {
    if (bad) *bad = 0;
    if (!v || !*v || !strcmp(v, "screen")) return 0;
    if (!strcmp(v, "game")) return 1;
    if (bad) *bad = 1;
    return 0;
}
// The drawable's pixels a point for a canvas whose picture rectangle is gw x gh points, the picture rendered at pw x ph pixels, on a screen of scale pixels a point: one scale for
// both directions (the touch controls are pictured at one scale, and a frame fits a drawable of the canvas's points times it, touch_frame_fits), just enough that the picture's
// rectangle gets all of its pixels in the direction that needs more (Picture Stretch to a wider screen: the picture's height), never more than the screen's. No render size yet,
// or no rectangle: the screen's
static inline double touch_drawable_scale(double gw, double gh, double pw, double ph, double scale) {
    if (!(gw > 0 && gh > 0 && pw > 0 && ph > 0 && scale > 0)) return scale;
    double s = fmax(pw / gw, ph / gh);
    return s < scale ? s : scale;
}

// The atlas's layout: n pictures of w[i] x h[i] pixels on shelves, tallest first, gap pixels around each (bilinear sampling of a knob between pixels reads none of its
// neighbours), at most width pixels across. Writes each one's x[i], y[i]; returns the atlas's height, 0 when one is wider than width
static inline int touch_pack(int n, const int *w, const int *h, int width, int gap, int *x, int *y) {
    int order[64]; if (n > 64) return 0;
    for (int i = 0; i < n; i++) order[i] = i;
    for (int i = 1; i < n; i++) { int k = order[i], j = i - 1; while (j >= 0 && h[order[j]] < h[k]) { order[j + 1] = order[j]; j--; } order[j + 1] = k; }
    int cx = gap, cy = gap, shelf = 0;
    for (int k = 0; k < n; k++) {
        int i = order[k];
        if (w[i] + 2 * gap > width) return 0;
        if (cx + w[i] + gap > width) { cx = gap; cy += shelf + gap; shelf = 0; }
        x[i] = cx; y[i] = cy; cx += w[i] + gap; if (h[i] > shelf) shelf = h[i];
    }
    return n ? cy + shelf + gap : 0;
}

// The atlas as grey and alpha (rg: two bytes a pixel, w * 2 a row) from BGRA bytes (premultiplied, row bytes a row), when every pixel is a grey (its three colours within one of
// each other: what antialiasing leaves of white and black); 0 when one is not, and the atlas stays BGRA
static inline int touch_grey(const uint8_t *bgra, int w, int h, size_t row, uint8_t *rg) {
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *p = bgra + (size_t)y * row + (size_t)x * 4;
        if (abs(p[0] - p[1]) > 1 || abs(p[1] - p[2]) > 1) return 0;
        rg[((size_t)y * w + x) * 2] = p[1]; rg[((size_t)y * w + x) * 2 + 1] = p[3];
    }
    return 1;
}

// nvn_mtl.m: the front end's latest frame, published for the present thread (any one thread; the iOS front end's main thread); its sequence (touch_publish)
uint32_t mtl_present_touch(const touch_frame *f);
// nvn_mtl.m: call front_touch_drawn once a live present that drew the controls from a frame of sequence seq or later has completed on the GPU (0: none wanted). The front end
// keeps the control layers showing until then (a change of layout, the controls coming back, presents resuming after a stall), so the controls are never missing from the screen
void mtl_present_touch_ack(uint32_t seq);
// nvn_mtl.m: the present stops drawing the controls (the front end turned them off): it lets the atlas in use go (out of the residency set once the presents that sampled it
// completed) until a new one comes (mtl_present_touch_atlas)
void mtl_present_touch_release(void);
// nvn_mtl.m: nanoseconds since the last live present (UINT64_MAX before one): the front end shows the layers while the game presents nothing (a load, a hitch), as the controls in
// the frame would not follow a press until the next present
uint64_t mtl_present_touch_idle_ns(void);
// nvn_mtl.m: a picture of the controls (premultiplied alpha, row bytes a row; channels 4: BGRA8, 2: grey and alpha, touch_grey) for the frames of atlas generation gen; the
// present thread takes it at its next live present. 0 when Metal could not make it
int mtl_present_touch_atlas(const void *px, int w, int h, size_t row, int channels, uint32_t gen);
// The front end's (front_ios.m; a weak default in nvn_mtl.m): the present cannot draw the controls (its pipeline failed), so they go back to their layers. Any thread
void front_touch_draw_failed(void);
// The front end's (DmGamepad.m; weak defaults in nvn_mtl.m), from the present's completion handler: a live present drew the controls from frame seq or later (mtl_present_touch_ack),
// so the layers can hide
void front_touch_drawn(uint32_t seq);
// The same, from the present thread: TOUCH_UNFIT live presents in a row had a drawable the frame is not laid out for (the drawable changed size without a layout of the root:
// a display scale change), so the controls are drawn nowhere: the layers show and the root lays out again
void front_touch_unfit(void);
