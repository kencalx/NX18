// Frame generation end to end on the DLSS path (DM_FRAMEGEN=1, nvn_framegen.inc), with synthetic inputs and the display link's callback called by hand (no window, no game
// files): a "game" at the 30 fps cap evaluates NVN2's DLSS (dlss_eval) on a red square moving over a grey background, with its depth and its motion (input pixels to the previous
// frame, as the game passes them), draws the exact picture into its window texture after the upscale (its post-processing), and presents it with a period of two ticks. Checked:
// the capture at the upscale reaches the present; the tick that takes a frame shows the generated frame and the next tick the real one, so every tick shows a picture; after the
// interpolator's warm-up the generated frame's square sits at the midpoint between the two real frames (within 2 px) and the real frame's at its own place; the real frame's
// ticket completes only with the real frame, and its link record and its one-tick shift follow it, which hle_nvn.c's screen intervals take out (pres_shifted_ms, exact with frame
// generation off); the in-game menu's hold, a 60 fps period, a suspend between a generated frame and its real one, the display link's stall with that real frame pending and the
// next frame queued, the Battery Saver preset and heat (real frames, no captures, the 30 Hz link, heat's calm before it comes back; on the Mac the system's own, from
// NSProcessInfo; a rung of the heat ladder, hle_nvn.c's, through its restore wait), the 30 Hz link before any capture and in variable-refresh fullscreen (no captures there),
// edge smoothing kept for a generated frame still on the GPU, and what frame generation made let go after a long step-aside, at a memory trim and going to the background, and
// made again; a long menu with captures coming lets it go once and makes no interpolator meanwhile; a trim's request for the link's side taken back once generation runs again;
// going to the background with a generated frame still on the GPU. "repeat": DM_PRESENT_REPEAT=1 turns frame generation off altogether (the snapshots stay, for the present repeat, t_present_repeat); "repeat off": any other value leaves it on
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <objc/runtime.h>
// t_present_rescue_focus.c's strong focus and screen hooks (fullscreen, variable refresh, the screen's rate) read these
int test_focus = 1, test_fullscreen, test_variable_refresh, test_game_fps = 30, test_screen_hz, test_match_fps; uint64_t test_focus_since;
// The front end's thermal state and Low Power Mode (front_ios.m's; hle_nvn.c's weak ones are the Mac's -1 and 0, which would read this Mac's own). test_mac: they answer as the
// Mac's do, so fg_power_why reads the system's own from NSProcessInfo, whose getters the test replaces (test_mac_thermal, test_mac_lpm) rather than read this Mac's
static _Atomic int test_thermal, test_low_power, test_mac, test_mac_thermal, test_mac_lpm;
int dm_thermal_now(void) { return atomic_load(&test_mac) ? -1 : atomic_load(&test_thermal); }
int dm_low_power_now(void) { return atomic_load(&test_mac) ? 0 : atomic_load(&test_low_power); }
// The heat ladder (hle_nvn.c, linked here, with the nvn_heat_rung frame generation reads) samples on now_cont_ns, the host stubs' weak now_ns: here now_ns plus
// test_cont_skip, so the heat hold's 30 s calm wait passes without waiting for it. nvn_heat_tick: the ladder's present call site, which samples it (once a second on that clock)
static _Atomic uint64_t test_cont_skip;
uint64_t now_cont_ns(void) { return now_ns() + atomic_load(&test_cont_skip); }
void nvn_heat_tick(uint64_t presents);
static NSProcessInfoThermalState test_pi_thermal(id self, SEL cmd) { (void)self; (void)cmd; return (NSProcessInfoThermalState)atomic_load(&test_mac_thermal); }
static BOOL test_pi_lpm(id self, SEL cmd) { (void)self; (void)cmd; return atomic_load(&test_mac_lpm) != 0; }
@interface FakeLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@property CFTimeInterval targetTimestamp;   // the callback's deadline (the display link line reads it)
@end
@implementation FakeLinkUpdate
@end
static CAMetalLayer *g_test_layer;
void *front_metal_layer(void) { return (__bridge void *)g_test_layer; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } else printf("ok: %s\n", label); } while (0)
enum { IW = 480, IH = 270, OW = 960, OH = 540, SQ = 64, DX = 40, DY = 20 };   // the square moves DX, DY output pixels a frame
static tex_t texture(uint64_t serial, unsigned w, unsigned h, int format) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .off = serial << 24};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1, .flags = NVN_TEXTURE_FLAGS_IMAGE};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static void upload(id<MTLTexture> t, const void *p, NSUInteger bpp) {
    NSUInteger row = t.width * bpp, n = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared]; memcpy(b.contents, p, n);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, b); t4_use(cb, t);
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:n sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    t4_end(cb, e); t4_wait(cb);
}
static int sq_x(int k) { return 200 + k * DX; }
static int sq_y(int k) { return 150 + k * DY; }
// Frame k's inputs at the input size (colour, depth reversed: far 0, the square 0.5; motion at the square) and its picture at the output size
static void frame_inputs(int k, id<MTLTexture> col, id<MTLTexture> dep, id<MTLTexture> mot, id<MTLTexture> win) {
    static __fp16 *c, *w, *m; static float *d;
    if (!c) { c = malloc((size_t)IW * IH * 8); w = malloc((size_t)OW * OH * 8); m = malloc((size_t)IW * IH * 4); d = malloc((size_t)IW * IH * 4); }
    int x = sq_x(k), y = sq_y(k);
    for (int j = 0; j < OH; j++) for (int i = 0; i < OW; i++) {
        int in = i >= x && i < x + SQ && j >= y && j < y + SQ; __fp16 *q = w + 4 * (j * OW + i);
        q[0] = in ? 1 : 0.1f; q[1] = q[2] = in ? 0 : 0.1f; q[3] = 1;
    }
    for (int j = 0; j < IH; j++) for (int i = 0; i < IW; i++) {
        int in = i >= x / 2 && i < (x + SQ) / 2 && j >= y / 2 && j < (y + SQ) / 2; __fp16 *q = c + 4 * (j * IW + i);
        q[0] = in ? 1 : 0.1f; q[1] = q[2] = in ? 0 : 0.1f; q[3] = 1;
        d[j * IW + i] = in ? 0.5f : 0; m[2 * (j * IW + i)] = in && k ? -DX / 2 : 0; m[2 * (j * IW + i) + 1] = in && k ? -DY / 2 : 0;
    }
    upload(col, c, 8); upload(dep, d, 4); upload(mot, m, 4);
    (void)win; (void)w;
}
static void window_picture(int k, id<MTLTexture> win) {   // the game's post-processing after the upscale: the exact picture
    static __fp16 *w; if (!w) w = malloc((size_t)OW * OH * 8);
    int x = sq_x(k), y = sq_y(k);
    for (int j = 0; j < OH; j++) for (int i = 0; i < OW; i++) {
        int in = i >= x && i < x + SQ && j >= y && j < y + SQ; __fp16 *q = w + 4 * (j * OW + i);
        q[0] = in ? 1 : 0.1f; q[1] = q[2] = in ? 0 : 0.1f; q[3] = 1;
    }
    NSUInteger row = OW * 8, n = row * OH;   // the picture into the crop at the texture's origin
    id<MTLBuffer> b = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared]; memcpy(b.contents, w, n);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, b); t4_use(cb, win);
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:n sourceSize:MTLSizeMake(OW, OH, 1) toTexture:win destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    t4_end(cb, e); t4_wait(cb);
}
static CAMetalLayer *offscreen_layer(void) {
    CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.framebufferOnly = NO; l.drawableSize = CGSizeMake(OW, OH); return l;
}
static id<CAMetalDrawable> drawable(void) {   // from four layers in turn (a queue takes at most 32 residency sets); each present completes before its layer comes round again
    static CAMetalLayer *ls[4]; static int k;
    CAMetalLayer *l = ls[k % 4]; if (!l) { l = ls[k % 4] = offscreen_layer(); [g_q4 addResidencySet:l.residencySet]; }
    k++; return [l nextDrawable];
}
static NvMetalDisplayLinkDelegate *g_delegate; static double g_ts; static int g_tick;
static id<CAMetalDrawable> tick(void) {
    id<CAMetalDrawable> dr = drawable();
    FakeLinkUpdate *u = [FakeLinkUpdate new]; u.drawable = dr; u.targetPresentationTimestamp = g_ts + g_tick++ / 60.0;
    @autoreleasepool { [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u]; }
    return dr;
}
static void settle(void) {
    pthread_mutex_lock(&g_pq_mu); struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 5;
    while (g_pq_inflight && pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT) {}
    pthread_mutex_unlock(&g_pq_mu);
}
// The red square's centre in a BGRA8 drawable (-1 when none)
static void centre(id<MTLTexture> t, double *cx, double *cy, double *n) {
    NSUInteger row = t.width * 4, sz = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:sz options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, t); t4_use(cb, b);
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:sz];
    t4_end(cb, e); t4_wait(cb);
    const uint8_t *p = b.contents; double sx = 0, sy = 0, c = 0;
    for (NSUInteger j = 0; j < t.height; j++) for (NSUInteger i = 0; i < t.width; i++) { const uint8_t *q = p + 4 * (j * t.width + i); if (q[2] > 128 && q[1] < 80) { sx += i; sy += j; c++; } }
    *n = c; *cx = c ? sx / c + 0.5 : -1; *cy = c ? sy / c + 0.5 : -1;
}
static int g_crop;   // "crop": the window texture is larger and the present crops the picture out of it (Ocarina of Time's 2048x1152 of 2560x1440)
static int ring_empty(void) { int e = 1; os_unfair_lock_lock(&g_fg_lk); for (int i = 0; i < FG_RING; i++) e &= !g_fg_cap[i].dep && !g_fg_cap[i].v; os_unfair_lock_unlock(&g_fg_lk); return e; }
static int interp_state(void) { os_unfair_lock_lock(&g_fg_lk); int st = g_fg_fi.state; os_unfair_lock_unlock(&g_fg_lk); return st; }
// The log lines (stderr, where MLOG writes) between log_capture and log_release, which writes them to stderr again and returns them for counting (the caller frees)
static int g_log_fd = -1, g_log_saved = -1; static char g_log_path[512];
static void log_capture(void) {
    fflush(stderr); const char *tmp = getenv("TMPDIR"); snprintf(g_log_path, sizeof g_log_path, "%s/t_framegen_dlss.%d.log", tmp && *tmp ? tmp : "/tmp", getpid());
    g_log_fd = open(g_log_path, O_CREAT | O_TRUNC | O_RDWR, 0600); g_log_saved = dup(2); dup2(g_log_fd, 2);
}
static char *log_release(void) {
    fflush(stderr); dup2(g_log_saved, 2); close(g_log_saved);
    off_t n = lseek(g_log_fd, 0, SEEK_END); char *t = calloc((size_t)n + 1, 1); if (pread(g_log_fd, t, (size_t)n, 0) < 0) t[0] = 0;
    close(g_log_fd); unlink(g_log_path); fputs(t, stderr); return t;
}
static int count_of(const char *t, const char *what) { int c = 0; for (const char *p = t; (p = strstr(p, what)); p += strlen(what)) c++; return c; }
// The fence a deferred release of obj waits for (defer_obj_at's queue); 0 when it is not queued
static uint64_t deferred_fence(id obj) {
    uint64_t f = 0; pthread_mutex_lock(&g_deferred_mu); for (NvDeferredRelease *d in g_deferred) if (d->object == obj) f = d->fence; pthread_mutex_unlock(&g_deferred_mu);
    return f;
}
int main(int argc, char **argv) { @autoreleasepool {
    g_crop = argc > 1 && !strcmp(argv[1], "crop");
    // DM_PRESENT_SNAP=0 on every path: the game profile's present_snap (on for Ocarina of Time and Breath of the Wild) must not decide what frame generation turns on
    if (argc > 1 && !strcmp(argv[1], "repeat")) {   // DM_PRESENT_REPEAT=1: frame generation off altogether, nothing turned on for it (the repeat's own snapshots aside); any other value: on
        int off = argc > 2 && !strcmp(argv[2], "off");
        setenv("DM_FRAMEGEN", "1", 1); setenv("DM_PRESENT_REPEAT", off ? "off" : "1", 1); setenv("DM_PRESENT_SNAP", "0", 1); mtl_init();
        if (off) CHECK(fg_on() && mtl_snap_on(), "DM_PRESENT_REPEAT=off: only 1 counts; frame generation is on, with its present snapshots");
        else CHECK(!fg_on() && mtl_snap_on() && rep_on(), "DM_PRESENT_REPEAT=1: frame generation is off; present snapshots are on for the present repeat, not for it");
        if (!off) {   // frame generation off: hle_nvn.c's screen intervals are a - b exactly, even for a ticket with a shift recorded
            fg_shift_note(5); double a = 4321.0 + 1 / 7.0 + 3 / 60.0, b = 4321.0 + 1 / 7.0, raw = (a - b) * 1e3, x = pres_shifted_ms(5, a, b), y = pres_shifted_ms(6, a, b);
            CHECK(!memcmp(&x, &raw, sizeof x) && !memcmp(&y, &raw, sizeof y), "frame generation off: the screen's intervals are (a - b) * 1e3 exactly (pres_shifted_ms)");
        }
        printf("t_framegen_dlss repeat%s: %d checks, %d failed\n", off ? " off" : "", checks, failed); return failed != 0;
    }
    alarm(180); setbuf(stdout, NULL);
    setenv("DM_PRESENT_REPEAT", "0", 1);   // a profile with present_repeat on (Bananza) would turn frame generation off
    setenv("DM_FRAMEGEN", "1", 1); setenv("DM_FPS", "30", 1); setenv("DM_PRESENT_HZ", "0", 1); setenv("DM_PRESENT_TRIM", "0", 1); setenv("DM_PRESENT_SNAP", "0", 1);
    setenv("DM_PRESENT_SHARPEN", "0", 1); setenv("DM_PRESENT_UPSCALE", "off", 1); setenv("DM_POST_AA", "off", 1); setenv("DM_PSO_PREPARE", "0", 1);   // no pipeline prewarm (it reads a shader map): the test layer would turn it on
    unsetenv("DM_PRESET");
    // The heat ladder's state, forced for the ladder alone (the front end's thermal state, which frame generation reads itself, stays test_thermal): 3 for the first 100 s
    // after its first sample, the heat ladder section's (nothing samples the ladder before it), then 0. Its other switches at their defaults
    setenv("DM_HEAT_FORCE", "3:0,0:100", 1); unsetenv("DM_THERMAL_CAP"); unsetenv("DM_HEAT_STEPS"); unsetenv("DM_HEAT_TUNE");
    mtl_init();
    if (!fg_supported()) { printf("t_framegen_dlss: no Metal 4 MetalFX frame interpolator on %s; skipped\n", g_dev.name.UTF8String); return 0; }
    CHECK(mtl_snap_on(), "frame generation turns present snapshots on (DM_PRESENT_SNAP=0, and a profile's present_snap alike)");
    CHECK(!fg_keeps_60hz(), "before the game's upscaler gave a capture: the 30 fps cap keeps its 30 Hz link");
    g_test_layer = offscreen_layer(); mtl_present_layer(OW, OH);
    g_dm_present_link = 1; g_link_started = 1; g_link_owns_layer = 1; g_delegate = [NvMetalDisplayLinkDelegate new];
    g_ts = CACurrentMediaTime() + 1;
    tex_t col = texture(95001, IW, IH, NVN_FORMAT_RGBA16F), dep = texture(95002, IW, IH, NVN_FORMAT_DEPTH32F), mot = texture(95003, IW, IH, NVN_FORMAT_RG16F), win = texture(95004, OW + (g_crop ? 128 : 0), OH + (g_crop ? 72 : 0), NVN_FORMAT_RGBA16F);
    mtl_tex_init(&col); mtl_tex_init(&dep); mtl_tex_init(&mot); mtl_tex_init(&win);
    __block p_dlss c = {.tex = {&col, &dep, &mot, &win}, .net = 1, .iw = IW, .ih = IH, .ow = OW, .oh = OH, .mv = {1, 1}, .pre_exposure = 1, .flags = DLSS_F_MV_LOW_RES | DLSS_F_DEPTH_INVERTED, .reset = 1};
    const double per = 2.0 / 60; static const int crop[4] = {0, 0, OW, OH};
    // One game frame: DLSS, the picture after it, the present; then the link's two ticks. Returns the two drawables
    __block uint64_t last_ticket = 0;
    id<CAMetalDrawable> (^frame)(int, id<CAMetalDrawable> *) = ^id<CAMetalDrawable>(int k, id<CAMetalDrawable> *second) {
        atomic_fetch_add(&g_cur_frame, 1);   // the game's frame (fg_cap_idle counts frames)
        frame_inputs(k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
        mtl_sub_begin(); dlss_eval(&c); uint64_t f = mtl_sub_commit(); mtl_wait(f, 5000000000ull); c.reset = 0;
        window_picture(k, tex_mtl(&win));
        last_ticket = present_enqueue(&win, per, g_crop ? crop : NULL, NULL);
        id<CAMetalDrawable> a = tick(); *second = tick(); settle(); return a;
    };
    // Frames until the interpolator is made (again) and then n generated in a row; returns whether they were
    __block int k = 0;
    int (^generating)(int) = ^int(int n) {
        id<CAMetalDrawable> d;
        for (int i = 0; i < 500 && interp_state() != 2; i++) { frame(++k, &d); usleep(10000); }
        uint64_t g0 = g_fg_gate.gen;
        for (int i = 0; i < n + 1; i++) frame(++k, &d);   // the first may have no history (fg_link_release starts it over)
        return interp_state() == 2 && g_fg_gate.gen >= g0 + n;
    };
    id<CAMetalDrawable> d1, d0 = frame(0, &d1);
    CHECK(atomic_load(&g_fg_cap_v) == 1, "the DLSS evaluation was captured");
    CHECK(fg_keeps_60hz(), "a capture came: the 60 Hz link for the generated frames");
    CHECK(g_fg_gate.real == 1 && g_fg_gate.why[FG_MAKING] == 1, "the first frame is real: the interpolator is being made");
    for (int i = 0; i < 500; i++) { if (interp_state() >= 2) break; usleep(10000); }
    CHECK(g_fg_fi.state == 2, "MetalFX made the interpolator");
    double cx, cy, n;
    for (k = 1; k < 8; k++) {
        d0 = frame(k, &d1);
        pthread_mutex_lock(&g_pq_mu); uint64_t done = g_pq_done; pthread_mutex_unlock(&g_pq_mu);
        if (k == 1) {
            CHECK(g_fg_gate.gen == 1 && done == last_ticket, "a generated frame, then the real frame on the next tick, which completes its ticket");
            // hle_nvn.c's screen accounting (the frame step's verdict, @presented_ms, the window line's drops, Vitals' gap, the perf record) takes the shift out: the first real
            // frame after its generated one reaches the screen three ticks after the real frame before it, and the next frame (shown on its own tick) one after it; both read two
            const double b = 4321.0 + 1 / 7.0, tk2 = 2000.0 / 60;
            CHECK(fabs(pres_shifted_ms(last_ticket, b + 3 / 60.0, b) - tk2) < 1e-6 && fabs(pres_shifted_ms(last_ticket + 1, b + 1 / 60.0, b) - tk2) < 1e-6,
                  "the screen's intervals less the shift: three ticks to the shifted frame and one after it both read two (pres_shifted_ms)");
            double a0 = b + 0.0333, raw = (a0 - b) * 1e3, got = pres_shifted_ms(last_ticket - 1, a0, b);
            CHECK(mtl_presented_shift(last_ticket - 1) == 0 && !memcmp(&got, &raw, sizeof got), "an unshifted pair reads (a - b) * 1e3 exactly");
        }
        if (k == 2) {
            double lt = 0, ll, lg; int lk; int have = mtl_link_tick(last_ticket, &lt, &ll, &lk, &lg);
            CHECK(have && fabs(lt - (g_ts + (g_tick - 1) / 60.0)) < 1e-6, "the real frame's link record is the tick that showed it, after its generated frame's (@link_target_ms)");
            CHECK(fabs(mtl_presented_shift(last_ticket) - 1.0 / 60) < 1e-9 && mtl_presented_shift(last_ticket + 1) == 0, "the real frame is recorded as shown one tick after its own, for the interval checks");
        }
    }
    k--;
    centre(d0.texture, &cx, &cy, &n);
    double mx = sq_x(k) - DX / 2.0 + SQ / 2.0, my = sq_y(k) - DY / 2.0 + SQ / 2.0;
    printf("frame %d: generated frame's square at %.1f, %.1f (midpoint %.1f, %.1f), %.0f pixels\n", k, cx, cy, mx, my, n);
    CHECK(fabs(cx - mx) <= 2 && fabs(cy - my) <= 2 && fabs(n - SQ * SQ) < SQ * 4, "the generated frame shows the square at the midpoint");
    centre(d1.texture, &cx, &cy, &n);
    printf("frame %d: real frame's square at %.1f, %.1f (%.1f, %.1f)\n", k, cx, cy, sq_x(k) + SQ / 2.0, sq_y(k) + SQ / 2.0);
    CHECK(fabs(cx - (sq_x(k) + SQ / 2.0)) <= 1 && fabs(cy - (sq_y(k) + SQ / 2.0)) <= 1, "the real frame shows its own picture on the tick after");
    CHECK(g_fg_gate.gen == 7 && g_fg_gate.real == 1, "every frame after the first was generated");
    printf("generated frame command buffers: %d timed\n", g_fg_gpu_n);
    // The in-game menu: that frame real, its hold kept (the second tick shows nothing new)
    mtl_framegen_hold(1); uint64_t real0 = g_fg_gate.real, empty0 = g_link_empty, held0 = g_link_held;
    frame(++k, &d1);
    CHECK(g_fg_gate.real == real0 + 1 && g_fg_gate.why[FG_MENU] == 1 && g_link_held + g_link_empty > held0 + empty0, "the in-game menu: the frame is real and held its two ticks");
    CHECK(mtl_presented_shift(last_ticket) == 0, "a real frame shown on its own tick has no shift");
    // Edge smoothing a generated frame's present pass ran stays while that frame is on the GPU: a memory trim's request waits for it, as for a real present (present_fx_idle)
    {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:16 mipmapped:NO]; td.storageMode = MTLStorageModePrivate;
        id<MTLTexture> fake = [g_dev newTextureWithDescriptor:td]; res_add(fake); res_commit();
        g_aa_present.tex = fake; g_aa_ran = 0; g_aa_idle = 5;
        pthread_mutex_lock(&g_pq_mu); uint64_t d0n = g_fg_done[0]; g_fg_aa_ai = 0; g_fg_aa_seq = d0n + 1; pthread_mutex_unlock(&g_pq_mu);   // as if a G on allocator 0 were still on the GPU
        atomic_store(&g_fx_trim_req, 1); present_fx_idle(0, last_ticket, 0);
        CHECK(g_aa_present.tex == fake && atomic_load(&g_fx_trim_req) == 1, "edge smoothing that a generated frame still on the GPU uses is kept; the trim's request waits for the next present");
        pthread_mutex_lock(&g_pq_mu); g_fg_aa_seq = d0n; pthread_mutex_unlock(&g_pq_mu);   // it completed
        present_fx_idle(0, last_ticket, 0);
        CHECK(!g_aa_present.tex && !atomic_load(&g_fx_trim_req), "once it completed, the trim releases it");
        pthread_mutex_lock(&g_pq_mu); g_fg_aa_seq = 0; pthread_mutex_unlock(&g_pq_mu);
    }
    // A memory trim while it is not generating (the menu's frame was real): the capture ring now, the display link's side at its next frame without a generated one
    fg_trim(1, g_fence);
    CHECK(ring_empty() && atomic_load(&g_fg_trim_req) == atomic_load(&g_fg_gen_n) + 1, "a memory trim while it is not generating: the capture ring goes, the display link's side is asked");
    frame(++k, &d1);
    CHECK(!g_fg_out && !g_fg_alloc[0] && interp_state() == 0 && !atomic_load(&g_fg_trim_req), "and at the next real frame its output, command allocators and interpolator go");
    mtl_framegen_hold(0);
    CHECK(generating(2), "after the menu: the interpolator made again, generated again");
    // A long stretch with captures and no generated frame (the menu held past the idle frames; a movie, the 30 Hz link alike): what the display link's side made goes once, and
    // no interpolator is made for a frame that would not be generated, so none is made and let go over and over (two log lines a cycle) while the captures keep coming
    {
        g_fg_idle_frames = 3; mtl_framegen_hold(1); uint64_t cap0 = atomic_load(&g_fg_cap_v); log_capture();
        uint64_t until = now_ns() + 600000000ull;
        for (int i = 0; i < 12 || now_ns() < until; i++) { frame(++k, &d1); usleep(10000); }
        for (int i = 0; i < 200 && interp_state() == 1; i++) usleep(10000);
        char *t = log_release(); int made = count_of(t, "MetalFX frame interpolator"), let = count_of(t, "no generated frame for"); free(t);
        printf("a long menu with captures: interpolators made %d, let go %d\n", made, let);
        CHECK(atomic_load(&g_fg_cap_v) > cap0 + 10 && made == 0 && let == 1 && interp_state() == 0 && !g_fg_out && !g_fg_alloc[0],
              "a long stretch with captures and no generated frame: the link's side goes once and no interpolator is made again during it");
        mtl_framegen_hold(0); g_fg_idle_frames = FG_IDLE_FRAMES;
        log_capture(); int ok = generating(2); t = log_release(); made = count_of(t, "MetalFX frame interpolator"); free(t);
        CHECK(ok && made == 1, "once generation can run again: the interpolator made once, generated again");
    }
    // A 60 fps period: real frames, one a tick
    real0 = g_fg_gate.real; frame_inputs(++k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
    mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); window_picture(k, tex_mtl(&win));
    present_enqueue(&win, 1.0 / 60, g_crop ? crop : NULL, NULL); g_tick++; tick(); settle();
    CHECK(g_fg_gate.real == real0 + 1 && g_fg_gate.why[FG_PERIOD] == 1, "a frame of one tick is shown real");
    // A memory trim after that real frame, then generation runs again: the request is taken back, so a frame without a generated one later does not let the display link's side
    // go long after the pressure passed; and one made from a g_fg_idle read before a generated frame (the trim on the submit thread, that frame on the link's) lapses
    void (^one_tick)(void) = ^{
        frame_inputs(++k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
        mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); window_picture(k, tex_mtl(&win));
        present_enqueue(&win, 1.0 / 60, g_crop ? crop : NULL, NULL); g_tick++; tick(); settle();
    };
    {
        fg_trim(1, g_fence);
        CHECK(atomic_load(&g_fg_trim_req) == atomic_load(&g_fg_gen_n) + 1, "a memory trim after a real frame: the display link's side is asked");
        uint64_t g0 = g_fg_gate.gen; frame(++k, &d1);
        CHECK(g_fg_gate.gen == g0 + 1 && !atomic_load(&g_fg_trim_req), "generated again: the trim's request is taken back");
        uint64_t r0 = g_fg_gate.real; one_tick();
        CHECK(g_fg_gate.real == r0 + 1 && g_fg_out && g_fg_alloc[0] && interp_state() == 2, "a real frame after it lets nothing go: generation used it all again");
        atomic_store(&g_fg_trim_req, atomic_load(&g_fg_gen_n));   // made when one generated frame fewer was counted
        one_tick();
        CHECK(!atomic_load(&g_fg_trim_req) && g_fg_out && g_fg_alloc[0] && interp_state() == 2, "a request made before the last generated frame lapses at the next real frame");
    }
    // A suspend between a generated frame and its real one: the real one is dropped, its ticket completed
    frame_inputs(++k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
    mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); window_picture(k, tex_mtl(&win));
    uint64_t gen0 = g_fg_gate.gen, tk = present_enqueue(&win, per, g_crop ? crop : NULL, NULL); g_tick++; tick(); settle();
    CHECK(g_fg_gate.gen == gen0 + 1 && g_fg_seq.has && g_fg_seq.ticket == tk, "generated, its real frame pending");
    present_drop_for_suspend();
    pthread_mutex_lock(&g_pq_mu); int ok = !g_fg_seq.has && g_pq_done >= tk; pthread_mutex_unlock(&g_pq_mu);
    CHECK(ok, "a suspend drops the pending real frame and completes its ticket");
    // The next frame after it: no history (the interpolator's last colour is the dropped frame's), so real; the one after generated again with the history reset
    uint64_t nh0 = g_fg_gate.why[FG_NO_HISTORY]; frame(++k, &d1);
    CHECK(g_fg_gate.why[FG_NO_HISTORY] == nh0 + 1, "after a dropped real frame the next frame has no history: real");
    gen0 = g_fg_gate.gen; frame(++k, &d1);
    CHECK(g_fg_gate.gen == gen0 + 1, "and the one after is generated again");
    // The display link silent with a real frame pending behind its generated one and the game's next frame queued after it (present_wait_at's stall): the stall drops the
    // pending real frame with the queued one, under the same lock, so its ticket is not done while it still points at its texture and the link's return does not show it after
    // the newer frame; both count as dropped, and the frame after has no history
    {
        if (g_fg_seq.has) { tick(); settle(); }   // the last frame's real one, when the frames run a tick out of step with frame()'s pair since the suspend
        frame_inputs(++k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
        mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); window_picture(k, tex_mtl(&win));
        uint64_t g0 = g_fg_gate.gen, tk1 = present_enqueue(&win, per, g_crop ? crop : NULL, NULL); tick(); settle();   // the tick that takes it shows its generated frame
        CHECK(g_fg_gate.gen == g0 + 1 && g_fg_seq.has && g_fg_seq.ticket == tk1 && g_pq_read == tk1, "generated, its real frame pending (a stall next)");
        frame_inputs(++k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
        mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); window_picture(k, tex_mtl(&win));
        uint64_t tk2 = present_enqueue(&win, per, g_crop ? crop : NULL, NULL);   // the game's next frame; no tick comes
        pthread_mutex_lock(&g_pq_mu); uint64_t drop0 = g_link_dropped; g_stall_drop = 0; g_link_tick_ns = now_ns() - 2 * STALL_NS; g_stall_t0 = g_link_tick_ns; pthread_mutex_unlock(&g_pq_mu);   // silent for 200 ms, the stall already seen
        mtl_present_wait(tk2);
        pthread_mutex_lock(&g_pq_mu);
        int ok = !g_fg_seq.has && g_pq_done >= tk2 && g_pq_read == tk2 && g_link_dropped == drop0 + 2; uint64_t sd = g_stall_drop;
        g_stall_t0 = 0; g_link_tick_ns = now_ns(); pthread_mutex_unlock(&g_pq_mu);
        CHECK(ok, "the display link silent: the stall drops the pending real frame with the frame queued after it, both counted");
        CHECK(sd == 2, "and the stall's own count (the 'fallback dropped' line) has both");
        uint64_t nh0 = g_fg_gate.why[FG_NO_HISTORY]; frame(++k, &d1);
        CHECK(g_fg_gate.why[FG_NO_HISTORY] == nh0 + 1, "after the stall's drop the next frame has no history: real");
    }
    // The same stall reached in the snapshot ring's order (two slots): the game's acquire waits on the pending real frame's own ticket first, then the next frame's; the stall
    // starts at the first drop, so its 'fallback dropped' count has both, as the link's dropped count does
    {
        frame(++k, &d1);   // generating again (the frame before was real: no history after the last stall)
        if (g_fg_seq.has) { tick(); settle(); }
        frame_inputs(++k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
        mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); window_picture(k, tex_mtl(&win));
        uint64_t g0 = g_fg_gate.gen, tk1 = present_enqueue(&win, per, g_crop ? crop : NULL, NULL); tick(); settle();
        if (!(g_fg_gate.gen == g0 + 1 && g_fg_seq.has && g_fg_seq.ticket == tk1 && g_pq_read == tk1))
            printf("  (gen %llu -> %llu, pending %d ticket %llu, tk1 %llu, read %llu)\n", (unsigned long long)g0, (unsigned long long)g_fg_gate.gen, g_fg_seq.has, (unsigned long long)g_fg_seq.ticket, (unsigned long long)tk1, (unsigned long long)g_pq_read);
        CHECK(g_fg_gate.gen == g0 + 1 && g_fg_seq.has && g_fg_seq.ticket == tk1 && g_pq_read == tk1, "generated, its real frame pending (a stall in ring order next)");
        frame_inputs(++k, tex_mtl(&col), tex_mtl(&dep), tex_mtl(&mot), tex_mtl(&win));
        mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); window_picture(k, tex_mtl(&win));
        uint64_t tk2 = present_enqueue(&win, per, g_crop ? crop : NULL, NULL);
        pthread_mutex_lock(&g_pq_mu); uint64_t drop0 = g_link_dropped, n0 = g_stall_n; g_stall_drop = 0; g_stall_t0 = 0; g_link_tick_ns = now_ns() - 2 * STALL_NS; pthread_mutex_unlock(&g_pq_mu);   // silent for 200 ms, no stall seen yet
        mtl_present_wait(tk1);
        pthread_mutex_lock(&g_pq_mu); int first = !g_fg_seq.has && g_stall_t0 && g_stall_drop == 1 && g_stall_n == n0 + 1; pthread_mutex_unlock(&g_pq_mu);
        CHECK(first, "the wait on the pending real frame's own ticket drops it and starts the stall with it counted");
        mtl_present_wait(tk2);
        pthread_mutex_lock(&g_pq_mu);
        int ok = g_pq_done >= tk2 && g_link_dropped == drop0 + 2 && g_stall_drop == 2 && g_stall_n == n0 + 1;
        g_stall_t0 = 0; g_link_tick_ns = now_ns(); pthread_mutex_unlock(&g_pq_mu);
        CHECK(ok, "then the queued frame: one stall, both drops in its 'fallback dropped' count, as in the link's");
    }
    // Variable-refresh fullscreen with no fixed-rate 60 Hz mode: the 60 Hz link would be the 120 Hz one, where nothing is generated: the 30 Hz link back; a window keeps 60
    test_fullscreen = 1; test_variable_refresh = 1; test_screen_hz = 120; link_sync();
    CHECK(g_link_mode == 3 && test_match_fps == 60, "variable-refresh fullscreen: the screen asked for 60 Hz first, then the 30 fps cap's 30 Hz link, not the 120 Hz one");
    {   // and no capture there: nothing is generated from it (an upscale evaluated alone)
        uint64_t v0 = atomic_load(&g_fg_cap_v); mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull);
        CHECK(!fg_cap_wanted() && atomic_load(&g_fg_cap_v) == v0, "  and no depth or motion copied at the upscale while that fallback holds");
    }
    test_fullscreen = 0; test_variable_refresh = 0; test_screen_hz = 0; link_sync();
    CHECK(g_link_mode == 1 && fg_cap_wanted(), "in a window: frame generation's 60 Hz link, and captures again");
    // Power first: the Battery Saver preset shows real frames only, copies no depth or motion and gives the 30 fps cap its 30 Hz link back; a long step-aside lets go of what
    // generation made; generation comes back with the preset gone (its interpolator made again, the history reset)
    setenv("DM_PRESET", "battery", 1); atomic_store(&g_fg_preset_at, 0);
    CHECK(!fg_keeps_60hz(), "Battery Saver: the 30 fps cap keeps its 30 Hz link");
    uint64_t bat0 = g_fg_gate.why[FG_BATTERY], cap0 = atomic_load(&g_fg_cap_v); frame(++k, &d1);
    CHECK(g_fg_gate.why[FG_BATTERY] == bat0 + 1 && atomic_load(&g_fg_cap_v) == cap0, "Battery Saver: the frame is real, and no depth or motion is copied for it");
    g_fg_idle_frames = 3; frame(++k, &d1); frame(++k, &d1); frame(++k, &d1);
    CHECK(ring_empty() && !g_fg_zero && !g_fg_out && !g_fg_alloc[0] && interp_state() == 0, "a long step-aside: the capture ring, the output, the command allocators and the interpolator go");
    g_fg_idle_frames = FG_IDLE_FRAMES;
    setenv("DM_PRESET", "balanced", 1); atomic_store(&g_fg_preset_at, 0);
    CHECK(generating(1) && fg_keeps_60hz(), "another preset: captured again, the interpolator made again, generated again");
    // MetalFX refused another key (a size since changed): the 30 Hz link came with the refusal, and this key is still tried, so the 60 Hz link and generation come back
    os_unfair_lock_lock(&g_fg_lk); g_fg_fi.fi = nil; for (int i = 0; i < 8; i++) g_fg_fi.key[i] = 7 + i; g_fg_fi.state = 3; os_unfair_lock_unlock(&g_fg_lk);
    link_sync();
    CHECK(!fg_keeps_60hz() && g_link_mode == 3, "an interpolator refused for another key: the 30 fps cap's 30 Hz link");
    CHECK(generating(1) && fg_keeps_60hz(), "this frame's key is tried: the interpolator made, generated again");
    link_sync();
    CHECK(g_link_mode == 1, "  and the 60 Hz link back");
    // Heat: thermal state serious steps aside at the next read and stays aside for the calm after it cools (the thermal cap's 30 s, shortened here: 3 s while a check needs it to
    // last, as one of this harness's ticks can wait a second for its layer's next drawable, and 0.3 s where it must run out); Low Power Mode too
    g_fg_calm_ns = 3000000000ull; atomic_store(&g_fg_hot_ns, 0);   // (a longer calm would also stretch an earlier read's heat: none is left over)
    atomic_store(&test_thermal, 2); atomic_store(&g_fg_preset_at, 0);
    CHECK(fg_power_why() == FG_THERMAL && !fg_keeps_60hz(), "heat: it steps aside at the next read (once a second), the 30 Hz link");
    uint64_t heat0 = g_fg_gate.why[FG_THERMAL]; cap0 = atomic_load(&g_fg_cap_v); frame(++k, &d1);
    CHECK(g_fg_gate.why[FG_THERMAL] == heat0 + 1 && atomic_load(&g_fg_cap_v) == cap0, "heat: real frames, no captures");
    atomic_store(&test_thermal, 1); atomic_store(&g_fg_preset_at, 0); frame(++k, &d1);
    CHECK(g_fg_gate.why[FG_THERMAL] == heat0 + 2, "cooled to fair: still aside for the calm");
    g_fg_calm_ns = 300000000ull; usleep(400000); atomic_store(&g_fg_preset_at, 0);
    CHECK(!fg_power_why() && generating(1), "after the calm: captures and generated frames again");
    g_fg_calm_ns = 3000000000ull; atomic_store(&g_fg_hot_ns, 0); atomic_store(&test_low_power, 1); atomic_store(&g_fg_preset_at, 0);
    heat0 = g_fg_gate.why[FG_THERMAL]; frame(++k, &d1);
    CHECK(g_fg_gate.why[FG_THERMAL] == heat0 + 1, "Low Power Mode: real frames");
    atomic_store(&test_low_power, 0); g_fg_calm_ns = 300000000ull; usleep(400000); atomic_store(&g_fg_preset_at, 0);
    CHECK(generating(1), "Low Power Mode off, after the calm: generated again");
    // A rung of the heat ladder (hle_nvn.c nvn_heat_rung): with the thermal state and Low Power Mode it reads itself calm, the ladder's 30 fps heat hold alone (its state 3,
    // DM_HEAT_FORCE) sets it aside, as its own reads would: real frames, no captures, the 30 Hz link. It stays aside through the hold's calm wait (30 s at state 0: the
    // ladder's clock jumps instead), longer than its own 30 s, and comes back once the ladder has no rung. With a hook returning 0 it would generate on
    {
        g_fg_calm_ns = 300000000ull; atomic_store(&g_fg_hot_ns, 0); atomic_store(&test_thermal, 0); atomic_store(&test_low_power, 0); atomic_store(&g_fg_preset_at, 0);
        CHECK(nvn_heat_rung() == 0 && !fg_power_why(), "the heat ladder not sampled yet: no rung, generation may run");
        log_capture(); nvn_heat_tick(1); int rung = nvn_heat_rung(), why = fg_power_why(), keeps = fg_keeps_60hz(); char *t = log_release();
        CHECK(rung >= 1 && why == FG_THERMAL && !keeps && count_of(t, "frame generation: steps aside for a rung of the heat ladder") == 1,
              "the ladder's 30 fps heat hold (forced state 3; its own reads calm; 85% and 70% under it where the game has the lever): it steps aside, the 30 Hz link");
        free(t);
        uint64_t heat0 = g_fg_gate.why[FG_THERMAL], cap0 = atomic_load(&g_fg_cap_v); frame(++k, &d1);
        CHECK(g_fg_gate.why[FG_THERMAL] == heat0 + 1 && atomic_load(&g_fg_cap_v) == cap0, "a rung of the heat ladder: real frames, no captures");
        atomic_fetch_add(&test_cont_skip, 101000000000ull); nvn_heat_tick(2);   // the ladder at state 0 (the timeline's 100 s): the hold's calm starts
        usleep(400000); atomic_store(&g_fg_preset_at, 0);   // past its own calm (0.3 s here)
        CHECK(nvn_heat_rung() >= 1 && fg_power_why() == FG_THERMAL, "the ladder cool, the hold in its calm wait: still aside, past its own calm");
        // The hold's 30 s calm, then (a game with the resolution lever: Bananza's GPU time stretch) 70% and 85% each after its own restore wait: aside until the last is back
        log_capture(); int ticks = 0, aside_while_rung = 1;
        do { atomic_fetch_add(&test_cont_skip, 31000000000ull); nvn_heat_tick(3 + ticks); rung = nvn_heat_rung(); why = fg_power_why(); if (rung) aside_while_rung &= why == FG_THERMAL; } while (rung && ++ticks < 40);
        t = log_release();
        CHECK(rung == 0 && !why && aside_while_rung && count_of(t, "frame generation: back, no rung of the heat ladder") == 1, "every rung back (the hold's 30 s calm, then any resolution rung's): back, once");
        free(t);
        CHECK(generating(1), "and generated again");
    }
    // The Mac, whose front end reports neither (hle_nvn.c's weak -1 and 0): the system's own thermal state and Low Power Mode, from NSProcessInfo (its getters replaced)
    {
        Class pic = object_getClass(NSProcessInfo.processInfo);
        method_setImplementation(class_getInstanceMethod(pic, @selector(thermalState)), (IMP)test_pi_thermal);
        method_setImplementation(class_getInstanceMethod(pic, @selector(isLowPowerModeEnabled)), (IMP)test_pi_lpm);
        atomic_store(&test_mac, 1); g_fg_calm_ns = 3000000000ull; atomic_store(&g_fg_hot_ns, 0);
        atomic_store(&test_mac_thermal, 2); atomic_store(&g_fg_preset_at, 0);
        CHECK(fg_power_why() == FG_THERMAL && !fg_keeps_60hz(), "the Mac hot (NSProcessInfo's thermal state serious): it steps aside, the 30 Hz link");
        atomic_store(&test_mac_thermal, 1); g_fg_calm_ns = 300000000ull; usleep(400000); atomic_store(&g_fg_preset_at, 0);
        CHECK(!fg_power_why(), "the Mac cooled to fair, after the calm: back");
        g_fg_calm_ns = 3000000000ull; atomic_store(&g_fg_hot_ns, 0); atomic_store(&test_mac_lpm, 1); atomic_store(&g_fg_preset_at, 0);
        uint64_t h0 = g_fg_gate.why[FG_THERMAL]; frame(++k, &d1);
        CHECK(g_fg_gate.why[FG_THERMAL] == h0 + 1 && fg_power_why() == FG_THERMAL, "the Mac in Low Power Mode (NSProcessInfo): real frames");
        atomic_store(&test_mac_lpm, 0); atomic_store(&test_mac_thermal, 0); g_fg_calm_ns = 300000000ull; usleep(400000); atomic_store(&g_fg_preset_at, 0);
        CHECK(!fg_power_why() && generating(1), "Low Power Mode off on the Mac, after the calm: generated again");
        atomic_store(&test_mac, 0);
    }
    // Going to the background with a generated frame still on the GPU (a display-link callback that took its frame before the drain looked and committed G after it): the ring
    // G reads goes only behind the next submission's fence, which the queue orders after G, and the link's side at its next frame without a generated one; a generated frame
    // that completes within the trim's short wait lets all of it go at once
    {
        settle(); present_drop_for_suspend();   // as mtl_drain does first: a real frame pending behind its generated one is dropped
        id<MTLTexture> rd = nil; os_unfair_lock_lock(&g_fg_lk); for (int i = 0; i < FG_RING && !rd; i++) rd = g_fg_cap[i].dep; os_unfair_lock_unlock(&g_fg_lk);
        pthread_mutex_lock(&g_pq_mu); __block uint64_t f0 = g_fg_fence[0]; g_fg_fence[0] = g_fg_done[0] + 1; pthread_mutex_unlock(&g_pq_mu);   // as if a G on allocator 0 were still on the GPU
        uint64_t fence = g_fence; fg_trim(3, fence);
        CHECK(rd && ring_empty() && deferred_fence(rd) == fence + 1 && g_fg_out && g_fg_alloc[0] && interp_state() == 2 && atomic_load(&g_fg_trim_req) == atomic_load(&g_fg_gen_n) + 1,
              "going to the background with a generated frame on the GPU: the ring it reads waits for the next submission's fence, the link's side for its next real frame");
        pthread_mutex_lock(&g_pq_mu); g_fg_fence[0] = f0; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);   // it completed
        uint64_t r0 = g_fg_gate.real; one_tick();
        CHECK(g_fg_gate.real == r0 + 1 && !g_fg_out && !g_fg_alloc[0] && interp_state() == 0 && !atomic_load(&g_fg_trim_req), "and the link's side goes at the next real frame");
        CHECK(generating(2), "generated again after it");
        settle(); present_drop_for_suspend();
        pthread_mutex_lock(&g_pq_mu); f0 = g_fg_fence[0]; g_fg_fence[0] = g_fg_done[0] + 1; pthread_mutex_unlock(&g_pq_mu);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
            pthread_mutex_lock(&g_pq_mu); g_fg_fence[0] = f0; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);   // it completes 10 ms into the wait
        });
        fg_trim(3, g_fence);
        CHECK(ring_empty() && !g_fg_out && !g_fg_alloc[0] && interp_state() == 0 && !atomic_load(&g_fg_trim_req), "a generated frame that completes within the wait: all of it goes at once");
        CHECK(generating(2), "and generated again");
    }
    // Going to the background: what it made goes at once, generating or not (the link calls back nothing there); the return makes it again
    settle(); fg_trim(3, g_fence);
    CHECK(ring_empty() && !g_fg_out && !g_fg_alloc[0] && interp_state() == 0 && !atomic_load(&g_fg_trim_req), "going to the background: the ring, the output, the allocators and the interpolator go at once");
    CHECK(generating(2), "back from the background: generated again");
    printf("t_framegen_dlss%s (encoding thread %s): %d checks, %d failed\n", g_crop ? " crop" : "", rec_on() ? "on" : "off", checks, failed);
    return failed != 0;
}}
