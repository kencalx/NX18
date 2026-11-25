// What MetalFX's Metal 4 frame interpolator (MTL4FXFrameInterpolator, macOS / iOS 27) takes and does, for frame generation (nvn_framegen.h, DM_FRAMEGEN): which colour,
// depth, motion and UI formats make one, the texture usage each input needs, its GPU time per generated frame, and on a synthetic scene (a square moving over a flat
// background, its depth and motion known, a static HUD box over its path) the motion convention it wants and how it treats the HUD. Standalone (no NVN host): t_mtl4.h's
// own queue. Exit 0 with a skip line on a device without Metal 4 MetalFX. The checks are what nvn_mtl.m relies on: motion in input pixels pointing to the previous frame
// at scale 1, the content rectangle and its offsets inside larger depth and motion textures (dynamic resolution), and an interpolator for the formats the host hands it.
// Everything else is printed for the record (docs/reference/rendering.md, Frame generation)
#define T4_STANDALONE 1
#import <MetalFX/MetalFX.h>
#include <math.h>
#include "t_mtl4.h"
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } else printf("ok: %s\n", label); } while (0)
enum { IW = 960, IH = 540, OW = 1920, OH = 1080, SQ = 128 };
static id<MTLTexture> tex(MTLPixelFormat pf, NSUInteger w, NSUInteger h, MTLTextureUsage u) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = u | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [t4_dev() newTextureWithDescriptor:d]; if (!t) T4_DIE("no %lux%lu texture of format %lu", (unsigned long)w, (unsigned long)h, (unsigned long)pf); return t;
}
static void upload(id<MTLTexture> t, const void *p, NSUInteger bpp) {
    NSUInteger row = t.width * bpp, n = row * t.height;
    id<MTLBuffer> b = [t4_dev() newBufferWithLength:n options:MTLResourceStorageModeShared]; memcpy(b.contents, p, n);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, b); t4_use(cb, t);
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:n sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    t4_end(cb, e); t4_wait(cb);
}
static __fp16 *readback(id<MTLTexture> t) {   // RGBA16F
    NSUInteger row = t.width * 8, n = row * t.height;
    id<MTLBuffer> b = [t4_dev() newBufferWithLength:n options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, b); t4_use(cb, t);
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:n];
    t4_end(cb, e); t4_wait(cb);
    __fp16 *p = malloc(n); memcpy(p, b.contents, n); return p;
}
// The scene at the output size: dark background, a red square at (x, y), and with hud a white box at the HUD's place
enum { HX = 640, HY = 470, HW = 200, HH = 48 };
static void scene(__fp16 *p, int x, int y, int hud, int ui_only) {
    for (int j = 0; j < OH; j++) for (int i = 0; i < OW; i++) {
        __fp16 *q = p + 4 * (j * OW + i); int in_sq = i >= x && i < x + SQ && j >= y && j < y + SQ, in_hud = hud && i >= HX && i < HX + HW && j >= HY && j < HY + HH;
        if (ui_only) { q[0] = q[1] = q[2] = q[3] = in_hud ? 1 : 0; continue; }
        q[0] = in_hud ? 1 : in_sq ? 1 : 0.1f; q[1] = q[2] = in_hud ? 1 : in_sq ? 0 : 0.1f; q[3] = 1;
    }
}
typedef struct { double cx, cy, n, hud_err; } measure;
static measure measure_out(id<MTLTexture> out, int hud) {
    __fp16 *p = readback(out); measure m = {0}; double sx = 0, sy = 0, e = 0;
    for (int j = 0; j < OH; j++) for (int i = 0; i < OW; i++) {
        const __fp16 *q = p + 4 * (j * OW + i); int in_hud = hud && i >= HX && i < HX + HW && j >= HY && j < HY + HH;
        if (in_hud) { e += fabs(1 - (double)q[0]) + fabs(1 - (double)q[1]) + fabs(1 - (double)q[2]); continue; }
        if (q[0] > 0.5f && q[1] < 0.3f) { sx += i; sy += j; m.n++; }
    }
    free(p);
    if (m.n) { m.cx = sx / m.n + 0.5; m.cy = sy / m.n + 0.5; }
    m.hud_err = hud ? e / (3.0 * HW * HH) : 0; return m;
}
static id<MTL4FXFrameInterpolator> make(MTLPixelFormat col, MTLPixelFormat dep, MTLPixelFormat mot, MTLPixelFormat ui, NSUInteger iw, NSUInteger ih, BOOL prev) {
    MTLFXFrameInterpolatorDescriptor *d = [MTLFXFrameInterpolatorDescriptor new];
    d.colorTextureFormat = col; d.outputTextureFormat = col; d.depthTextureFormat = dep; d.motionTextureFormat = mot; d.uiTextureFormat = ui;
    d.inputWidth = iw; d.inputHeight = ih; d.outputWidth = OW; d.outputHeight = OH; d.requiresPrevColorTexture = prev;
    return [d newFrameInterpolatorWithDevice:t4_dev() compiler:t4_comp()];
}
// A sequence of NF frames: the square moves by (dx, dy) output pixels a frame from (x0, y0); each frame's motion, in input pixels times scale, sits at the square's current place.
// Every frame is encoded (the first with the history reset); the output read is the midpoint between the last two frames
enum { NF = 4 };
typedef struct { float mx, my, scale; int ui_mode; int hud; int content_off; BOOL prev; int reset_last; int nf; } run_opt;   // ui_mode 0 none, 1 F composited, 2 UI layer alone
static measure run_seq(id<MTL4FXFrameInterpolator> fi, run_opt o, double *ex, double *ey) {
    int x0 = 520, y0 = 360, dx = 80, dy = 40, ox = o.content_off ? 32 : 0, oy = o.content_off ? 30 : 0, nf = o.nf ? o.nf : NF;
    NSUInteger dw = fi.inputWidth + 2 * ox, dh = fi.inputHeight + 2 * oy;
    static __fp16 *img; if (!img) img = malloc((size_t)OW * OH * 8);
    id<MTLTexture> out = tex(MTLPixelFormatRGBA16Float, OW, OH, fi.outputTextureUsage), dep = tex(MTLPixelFormatDepth32Float, dw, dh, fi.depthTextureUsage),
                   mot = tex(MTLPixelFormatRG16Float, dw, dh, fi.motionTextureUsage), ui = o.ui_mode ? tex(MTLPixelFormatRGBA16Float, OW, OH, fi.uiTextureUsage) : nil, prevc = nil;
    int hud_in_colour = o.hud && o.ui_mode == 0;   // H0 interpolates the HUD with the scene; H1 / the UI layer take the scene alone as colour
    float *dp = malloc(dw * dh * 4); __fp16 *mp = malloc(dw * dh * 4); long st = 0;
    for (int k = 0; k < nf; k++) {
        int x = x0 + k * dx, y = y0 + k * dy;
        id<MTLTexture> cur = tex(MTLPixelFormatRGBA16Float, OW, OH, fi.colorTextureUsage);
        scene(img, x, y, hud_in_colour, 0); upload(cur, img, 8);
        if (o.ui_mode == 1) { scene(img, x, y, 1, 0); upload(ui, img, 8); }
        if (o.ui_mode == 2 && k == 0) { scene(img, 0, 0, 1, 1); upload(ui, img, 8); }
        int sx = x * (int)fi.inputWidth / OW, sy = y * (int)fi.inputHeight / OH, sw = SQ * (int)fi.inputWidth / OW, sh = SQ * (int)fi.inputHeight / OH;
        for (NSUInteger j = 0; j < dh; j++) for (NSUInteger i = 0; i < dw; i++) {
            int ci = (int)i - ox, cj = (int)j - oy, in_sq = k && ci >= sx && ci < sx + sw && cj >= sy && cj < sy + sh;
            dp[j * dw + i] = in_sq || (!k && ci >= sx && ci < sx + sw && cj >= sy && cj < sy + sh) ? 0.5f : 1.0f; mp[2 * (j * dw + i)] = in_sq ? o.mx : 0; mp[2 * (j * dw + i) + 1] = in_sq ? o.my : 0;
        }
        upload(dep, dp, 4); upload(mot, mp, 4);
        fi.colorTexture = cur; fi.prevColorTexture = o.prev ? (prevc ? prevc : cur) : nil; fi.depthTexture = dep; fi.motionTexture = mot; fi.outputTexture = out; fi.uiTexture = ui;
        fi.uiTextureComposited = o.ui_mode == 1;
        fi.motionVectorScaleX = o.scale; fi.motionVectorScaleY = o.scale; fi.jitterOffsetX = fi.jitterOffsetY = 0; fi.deltaTime = 1.0f / 30; fi.depthReversed = NO;
        fi.nearPlane = 0.1f; fi.farPlane = 1000; fi.fieldOfView = 60; fi.aspectRatio = (float)OW / OH;
        fi.contentWidth = fi.inputWidth; fi.contentHeight = fi.inputHeight;
        fi.depthContentOffsetX = fi.motionContentOffsetX = (NSUInteger)ox; fi.depthContentOffsetY = fi.motionContentOffsetY = (NSUInteger)oy;
        fi.outputOffsetX = fi.outputOffsetY = 0;
        fi.shouldResetHistory = k == 0 || (k == nf - 1 && o.reset_last);
        T4 *cb = t4_begin(); for (id r in @[cur, dep, mot, out]) t4_use(cb, r); if (prevc) t4_use(cb, prevc); if (ui) t4_use(cb, ui);
        [fi encodeToCommandBuffer:cb->cb]; st = t4_wait(cb);
        prevc = cur;
        *ex = x - dx / 2.0 + SQ / 2.0; *ey = y - dy / 2.0 + SQ / 2.0;
    }
    free(dp); free(mp);
    return st == MTLCommandBufferStatusCompleted ? measure_out(out, o.hud) : (measure){-1, -1, -1, -1};
}
static double gpu_ms(id<MTL4FXFrameInterpolator> fi, int n, double *p95) {
    id<MTLTexture> c0 = tex(MTLPixelFormatRGBA16Float, OW, OH, fi.colorTextureUsage), c1 = tex(MTLPixelFormatRGBA16Float, OW, OH, fi.colorTextureUsage), out = tex(MTLPixelFormatRGBA16Float, OW, OH, fi.outputTextureUsage),
                   dep = tex(MTLPixelFormatDepth32Float, fi.inputWidth, fi.inputHeight, fi.depthTextureUsage), mot = tex(MTLPixelFormatRG16Float, fi.inputWidth, fi.inputHeight, fi.motionTextureUsage);
    double *v = calloc(n, sizeof *v); __block int got = 0; dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    for (int i = 0; i < n; i++) {
        fi.colorTexture = i & 1 ? c1 : c0; fi.prevColorTexture = i & 1 ? c0 : c1; fi.depthTexture = dep; fi.motionTexture = mot; fi.outputTexture = out; fi.uiTexture = nil;
        fi.motionVectorScaleX = fi.motionVectorScaleY = 1; fi.deltaTime = 1.0f / 30; fi.shouldResetHistory = i == 0;
        fi.contentWidth = fi.inputWidth; fi.contentHeight = fi.inputHeight;
        T4 *cb = t4_begin(); for (id r in @[c0, c1, dep, mot, out]) t4_use(cb, r);
        [fi encodeToCommandBuffer:cb->cb]; [cb->cb endCommandBuffer];
        MTL4CommitOptions *op = [MTL4CommitOptions new]; double *slot = &v[i];
        [op addFeedbackHandler:^(id<MTL4CommitFeedback> f) { *slot = (f.GPUEndTime - f.GPUStartTime) * 1e3; t4_release(cb); if (++got == n) dispatch_semaphore_signal(sem); }];
        [g_t4_res commit]; id<MTL4CommandBuffer> cbs[] = {cb->cb}; [g_t4_q commit:cbs count:1 options:op];
        if (i % 8 == 7) t4_drain();   // a few in flight, as presents are
    }
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC));
    for (int i = 1; i < n; i++) { double x = v[i]; int j = i - 1; while (j >= 0 && v[j] > x) { v[j + 1] = v[j]; j--; } v[j + 1] = x; }
    double p50 = v[n / 2]; *p95 = v[n * 95 / 100]; free(v); return p50;
}
static const char *pfname(MTLPixelFormat f) {
    switch (f) {
        case MTLPixelFormatRGBA16Float: return "RGBA16F"; case MTLPixelFormatRGBA8Unorm: return "RGBA8"; case MTLPixelFormatRGBA8Unorm_sRGB: return "RGBA8_sRGB";
        case MTLPixelFormatBGRA8Unorm: return "BGRA8"; case MTLPixelFormatBGRA8Unorm_sRGB: return "BGRA8_sRGB"; case MTLPixelFormatRGB10A2Unorm: return "RGB10A2"; case MTLPixelFormatRG11B10Float: return "RG11B10F";
        case MTLPixelFormatDepth32Float: return "D32F"; case MTLPixelFormatDepth32Float_Stencil8: return "D32F_S8"; case MTLPixelFormatDepth16Unorm: return "D16"; case MTLPixelFormatR32Float: return "R32F";
        case MTLPixelFormatRG16Float: return "RG16F"; case MTLPixelFormatRG32Float: return "RG32F"; case MTLPixelFormatInvalid: return "none"; default: return "?";
    }
}
int main(int argc, char **argv) { @autoreleasepool {
    int quick = argc > 1 && !strcmp(argv[1], "quick");
    t4_dev();
    if (![MTLFXFrameInterpolatorDescriptor supportsMetal4FX:t4_dev()]) { printf("t_framegen_probe: %s has no Metal 4 MetalFX frame interpolator; skipped\n", t4_dev().name.UTF8String); return 0; }
    printf("device %s\n", t4_dev().name.UTF8String);
    // Formats: colour (and output, and UI when given) x depth x motion
    MTLPixelFormat cols[] = {MTLPixelFormatRGBA16Float, MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB, MTLPixelFormatBGRA8Unorm, MTLPixelFormatRGB10A2Unorm, MTLPixelFormatRG11B10Float};
    MTLPixelFormat deps[] = {MTLPixelFormatDepth32Float, MTLPixelFormatDepth32Float_Stencil8, MTLPixelFormatDepth16Unorm, MTLPixelFormatR32Float};
    MTLPixelFormat mots[] = {MTLPixelFormatRG16Float, MTLPixelFormatRG32Float};
    for (unsigned i = 0; i < sizeof cols / sizeof *cols; i++) for (int ui = 0; ui < 2; ui++) {
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        id<MTL4FXFrameInterpolator> fi = make(cols[i], MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float, ui ? cols[i] : MTLPixelFormatInvalid, IW, IH, YES);
        printf("format colour %-10s depth D32F motion RG16F ui %-10s: %s", pfname(cols[i]), ui ? pfname(cols[i]) : "none", fi ? "made" : "REFUSED");
        if (fi) printf(" in %.0f ms; usage colour %#lx output %#lx depth %#lx motion %#lx ui %#lx", (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6, (unsigned long)fi.colorTextureUsage,
                       (unsigned long)fi.outputTextureUsage, (unsigned long)fi.depthTextureUsage, (unsigned long)fi.motionTextureUsage, (unsigned long)fi.uiTextureUsage);
        printf("\n");
        if (i == 0 && !ui) CHECK(fi != nil, "an interpolator for RGBA16F colour, D32F depth and RG16F motion");
    }
    for (unsigned i = 1; i < sizeof deps / sizeof *deps; i++) printf("format depth %-8s: %s\n", pfname(deps[i]), make(MTLPixelFormatRGBA16Float, deps[i], MTLPixelFormatRG16Float, MTLPixelFormatInvalid, IW, IH, YES) ? "made" : "REFUSED");
    for (unsigned i = 1; i < sizeof mots / sizeof *mots; i++) printf("format motion %-8s: %s\n", pfname(mots[i]), make(MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, mots[i], MTLPixelFormatInvalid, IW, IH, YES) ? "made" : "REFUSED");
    // The motion convention on the moving square: it moved +80, +40 output pixels (+40, +20 input pixels); the midpoint's centre is (704, 484)
    id<MTL4FXFrameInterpolator> fi = make(MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float, IW, IH, YES);
    if (!fi) { printf("t_framegen_probe: %d checks, %d failed\n", checks, failed); return 1; }
    double ex = 0, ey = 0;
    struct { const char *name; run_opt o; } mv[] = {
        {"motion (-40,-20) input px, scale 1 (to the previous frame)", {-40, -20, 1, 0, 0, 0, YES}},
        {"motion (+40,+20) input px, scale 1 (to the next frame)", {40, 20, 1, 0, 0, 0, YES, 0}},
        {"motion (-80,-40) output px, scale 1", {-80, -40, 1, 0, 0, 0, YES, 0}},
        {"motion (-20,-10), scale 2", {-20, -10, 2, 0, 0, 0, YES, 0}},
        {"zero motion", {0, 0, 1, 0, 0, 0, YES, 0}},
        {"motion (-40,-20), content at (32,30) in 1024x600 depth and motion", {-40, -20, 1, 0, 0, 1, YES, 0}},
        {"motion (-40,-20), no previous colour texture (requiresPrevColorTexture NO)", {-40, -20, 1, 0, 0, 0, NO}},
        {"motion (-40,-20), history reset on the last encode", {-40, -20, 1, 0, 0, 0, YES, 1}},
        {"motion (-40,-20), two frames only (the first a reset)", {-40, -20, 1, 0, 0, 0, YES, 0, 2}},
        {"motion (-40,-20), three frames (the first a reset)", {-40, -20, 1, 0, 0, 0, YES, 0, 3}},
    };
    measure got[16]; double gx[16], gy[16];
    for (unsigned i = 0; i < sizeof mv / sizeof *mv; i++) {
        id<MTL4FXFrameInterpolator> f = mv[i].o.prev ? fi : make(MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float, MTLPixelFormatRGBA16Float, IW, IH, NO);
        if (!f) { printf("%s: no interpolator\n", mv[i].name); got[i] = (measure){-1, -1, -1, -1}; continue; }
        got[i] = run_seq(f, mv[i].o, &ex, &ey); gx[i] = ex; gy[i] = ey;
        printf("%-90s: square centre %.1f, %.1f (midpoint %.1f, %.1f; %.1f, %.1f off), %.0f red pixels (%d)\n", mv[i].name, got[i].cx, got[i].cy, ex, ey, got[i].cx - ex, got[i].cy - ey, got[i].n, SQ * SQ);
    }
    CHECK(fabs(got[0].cx - gx[0]) <= 2 && fabs(got[0].cy - gy[0]) <= 2 && fabs(got[0].n - SQ * SQ) < SQ, "motion in input pixels pointing to the previous frame, at scale 1, puts the square at the midpoint within 2 px");
    CHECK(fabs(got[5].cx - gx[5]) <= 2 && fabs(got[5].cy - gy[5]) <= 2, "the content rectangle and its offsets select the content inside larger depth and motion textures");
    CHECK(fabs(got[3].cx - got[0].cx) <= 1 && fabs(got[3].cy - got[0].cy) <= 1, "motionVectorScale multiplies the motion texture's values");
    CHECK(fabs(got[6].cx - gx[6]) <= 2 && fabs(got[6].cy - gy[6]) <= 2, "with requiresPrevColorTexture NO the interpolator keeps the previous colour itself");
    CHECK(fabs(got[7].cx - (gx[7] + 40)) <= 1 && fabs(got[7].cy - (gy[7] + 20)) <= 1, "an encode with the history reset gives the current picture");
    CHECK(fabs(got[8].cx - (gx[8] + 40)) <= 1 && fabs(got[8].cy - (gy[8] + 20)) <= 1, "the encode after a reset still gives the current picture (no midpoint yet)");
    // The HUD box over the square's path: H0 (colour with the HUD), H1 (colour without it, the UI texture the full picture, composited), the UI layer alone (alpha)
    const char *hn[] = {"H0: colour with the HUD, no UI texture", "H1: colour without the HUD, UI texture = colour + HUD (uiTextureComposited YES)", "UI layer alone with alpha (uiTextureComposited NO)"};
    for (int h = 0; h < 3; h++) {
        measure m = run_seq(fi, (run_opt){-40, -20, 1, h, 1, 0, YES}, &ex, &ey);
        printf("%-80s: HUD mean error %.4f, square centre %.1f, %.1f, %.0f red pixels outside the HUD\n", hn[h], m.hud_err, m.cx, m.cy, m.n);
        if (h) CHECK(m.hud_err < 0.01, "a UI texture keeps the static HUD exact on the generated frame");
    }
    if (!quick) {
        double p95, p50 = gpu_ms(fi, 300, &p95);
        printf("GPU time %dx%d -> %dx%d (RGBA16F, UI format set): p50 %.3f ms, p95 %.3f ms over 300 encodes\n", IW, IH, OW, OH, p50, p95);
        id<MTL4FXFrameInterpolator> f2 = make(MTLPixelFormatRGBA16Float, MTLPixelFormatDepth32Float, MTLPixelFormatRG16Float, MTLPixelFormatInvalid, 1536, 864, YES);
        if (f2) { p50 = gpu_ms(f2, 300, &p95); printf("GPU time 1536x864 -> %dx%d (RGBA16F, no UI): p50 %.3f ms, p95 %.3f ms over 300 encodes\n", OW, OH, p50, p95); }
    }
    printf("t_framegen_probe: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
