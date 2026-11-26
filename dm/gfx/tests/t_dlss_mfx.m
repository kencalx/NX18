// NVN2's DLSS on MetalFX (nvn_mtl.m dlss_eval) with Metal encoding on its own thread and without: MetalFX's temporal scaler encodes into the replay's real command buffer
// (rec_cb_block), never the recording's stand-in, and fills a 1920x1080 output from a flat 960x540 colour; two evaluations through the same scaler before the submission ends
// keep each one's own output. A network that takes new sizes after an evaluation in the same submission replaces its scaler, and the submission still completes: the
// replaced scaler lives until then (a Metal 4 command buffer retains nothing; released at once, the commit messages a freed object, which the Makefile's NSZombieEnabled
// turns into a crash every time: "-[_MTL4MachineLearningPipelineState executable]: message sent to deallocated instance")
// The scaler comes after the work before it and the next draw pass after the scaler (mfx_order, upstream NXNative b25b651b): a slow pass that ends with no barrier writes the
// colour just before each evaluation, and a draw pass copies the output just after it; the Makefile's DM_NVN_BARRIER=game run makes that pass skip its consumer barrier
// unless the scaler cleared the relaxed end
// DLSS's bias mask reaches MetalFX as its reactive mask (upstream NXNative 23790f8dc, PR #1904): the scaler is made for the mask's format and handed its texture, and a
// checkerboard moved one pixel with zero motion vectors comes out as a reset's with the mask at 1, keeping history at 0
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include "t_mfx_passes.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static tex_t texture(uint64_t serial, unsigned w, unsigned h, int format) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .off = serial << 24};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1, .flags = NVN_TEXTURE_FLAGS_IMAGE};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static void fill(id<MTLTexture> t, MTLClearColor c, int depth) {
    T4 *cb = t4_begin(); MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    if (depth) { rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionStore; rp.depthAttachment.clearDepth = 0; }
    else { rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = c; }
    t4_end(cb, t4_pass(cb, rp)); t4_wait(cb);
}
static int flat(id<MTLTexture> t, const float want[4]) {   // the middle half of the picture (the scaler's edges may differ), within HDR rounding
    NSUInteger n = t.width * t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:n * 8 options:MTLResourceStorageModeShared];
    if (!b) { fprintf(stderr, "readback buffer did not allocate\n"); return 0; }
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb);
    t4_use(cb, t), t4_use(cb, b), [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 8 destinationBytesPerImage:n * 8];
    t4_end(cb, e); t4_wait(cb);
    const __fp16 *p = b.contents;
    for (NSUInteger y = t.height / 4; y < t.height * 3 / 4; y++) for (NSUInteger x = t.width / 4; x < t.width * 3 / 4; x++)
        for (int c = 0; c < 4; c++) if (!(fabsf((float)p[4 * (y * t.width + x) + c] - want[c]) <= 0.03f)) {
            fprintf(stderr, "texel %lu,%lu channel %d: %g, expected %g\n", (unsigned long)x, (unsigned long)y, c, (float)p[4 * (y * t.width + x) + c], want[c]); return 0; }
    return 1;
}
static void upload(id<MTLTexture> t, const void *px, NSUInteger bpp) {   // the textures are private: through a shared buffer and a copy
    id<MTLBuffer> b = [g_dev newBufferWithBytes:px length:t.width * t.height * bpp options:MTLResourceStorageModeShared];
    if (!b) { fprintf(stderr, "upload buffer did not allocate\n"); exit(1); }
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb);
    t4_use(cb, t), t4_use(cb, b), [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:t.width * bpp sourceBytesPerImage:t.width * t.height * bpp sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    t4_end(cb, e); t4_wait(cb);
}
static float *readback(id<MTLTexture> t) {   // RGBA16F as floats, the caller frees
    NSUInteger n = t.width * t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:n * 8 options:MTLResourceStorageModeShared];
    if (!b) { fprintf(stderr, "readback buffer did not allocate\n"); exit(1); }
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb);
    t4_use(cb, t), t4_use(cb, b), [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 8 destinationBytesPerImage:n * 8];
    t4_end(cb, e); t4_wait(cb);
    float *f = malloc(n * 4 * sizeof *f); const __fp16 *p = b.contents; for (NSUInteger i = 0; i < n * 4; i++) f[i] = (float)p[i];
    return f;
}
// A dynamic input occupies only part of its texture. Give the padding a different alpha so a bilinear tap outside the content cannot pass unnoticed.
static void fill_alpha_rect(id<MTLTexture> t, const float c[4], unsigned sx, unsigned sy, unsigned w, unsigned h) {
    __fp16 *p = malloc(t.width * t.height * 8);
    for (NSUInteger y = 0; y < t.height; y++) for (NSUInteger x = 0; x < t.width; x++) {
        for (int ch = 0; ch < 3; ch++) p[4 * (y * t.width + x) + ch] = c[ch];
        p[4 * (y * t.width + x) + 3] = x >= sx && x < sx + w && y >= sy && y < sy + h ? c[3] : 1;
    }
    upload(t, p, 8); free(p);
}
static int alpha_flat(id<MTLTexture> t, float want) {   // every pixel, including the edges and corners the temporal RGB checks leave out
    float *p = readback(t); int ok = 1;
    for (NSUInteger y = 0; y < t.height && ok; y++) for (NSUInteger x = 0; x < t.width; x++) if (!(fabsf(p[4 * (y * t.width + x) + 3] - want) <= 0.001f)) {
        fprintf(stderr, "alpha at %lu,%lu: %g, expected %g\n", (unsigned long)x, (unsigned long)y, p[4 * (y * t.width + x) + 3], want); ok = 0; break;
    }
    free(p); return ok;
}
static float mean_diff(const float *x, const float *y, NSUInteger w, NSUInteger h) {   // over the middle half, RGB
    double d = 0; NSUInteger k = 0;
    for (NSUInteger j = h / 4; j < h * 3 / 4; j++) for (NSUInteger i = w / 4; i < w * 3 / 4; i++) for (int c = 0; c < 3; c++, k++) d += fabsf(x[4 * (j * w + i) + c] - y[4 * (j * w + i) + c]);
    return (float)(d / (double)k);
}
// A 4-pixel checkerboard, then the same board moved one pixel with motion vectors of 0 (what DLSS's bias mask is for: content the vectors do not carry), not reset. With
// the reactive mask at 1 the scaler takes the current frame alone, as a reset does; at 0 it keeps some history. Returns the mean distance to the reset output (upstream
// NXNative 23790f8dc)
static float moved_board(int net, float mask_value) {
    enum { W = 480, H = 270 };
    tex_t c0 = texture(200 + 10 * net, W, H, NVN_FORMAT_RGBA16F), c1 = texture(201 + 10 * net, W, H, NVN_FORMAT_RGBA16F), d = texture(202 + 10 * net, W, H, NVN_FORMAT_DEPTH32F),
          m = texture(203 + 10 * net, W, H, NVN_FORMAT_RG16F), o = texture(204 + 10 * net, 2 * W, 2 * H, NVN_FORMAT_RGBA16F), o2 = texture(205 + 10 * net, 2 * W, 2 * H, NVN_FORMAT_RGBA16F),
          k = texture(206 + 10 * net, W, H, NVN_FORMAT_R8);
    tex_t *all[] = {&c0, &c1, &d, &m, &o, &o2, &k}; for (int i = 0; i < 7; i++) mtl_tex_init(all[i]);
    static __fp16 px[2][W * H * 4]; static uint8_t mk[W * H];
    for (int s = 0; s < 2; s++) for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        const int on = (((x + s) >> 2) ^ (y >> 2)) & 1;
        for (int ch = 0; ch < 4; ch++) px[s][4 * (y * W + x) + ch] = ch == 3 ? 1 : on ? 0.9f : 0.1f;
    }
    memset(mk, (int)(mask_value * 255.0f + 0.5f), sizeof mk);
    upload(tex_mtl(&c0), px[0], 8); upload(tex_mtl(&c1), px[1], 8); upload(tex_mtl(&k), mk, 1);
    fill(tex_mtl(&d), MTLClearColorMake(0, 0, 0, 0), 1); fill(tex_mtl(&m), MTLClearColorMake(0, 0, 0, 0), 0);
    p_dlss c = {.tex = {&c0, &d, &m, &o, &k}, .net = (uint64_t)net, .iw = W, .ih = H, .ow = 2 * W, .oh = 2 * H, .mv = {1, 1}, .pre_exposure = 1, .flags = DLSS_F_DEPTH_INVERTED, .reset = 1};
    for (int frame = 0; frame < 6; frame++) { mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull); c.reset = 0; }
    c.tex[DLSS_COLOR] = &c1; mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull);
    float *moved = readback(tex_mtl(&o));
    c.tex[DLSS_OUTPUT] = &o2; c.reset = 1; mtl_sub_begin(); dlss_eval(&c); mtl_wait(mtl_sub_commit(), 5000000000ull);
    float *fresh = readback(tex_mtl(&o2));
    const float r = mean_diff(moved, fresh, 2 * W, 2 * H); free(moved); free(fresh);
    return r;
}
int main(void) { @autoreleasepool {
    mtl_init();
    tex_t col = texture(90, 960, 540, NVN_FORMAT_RGBA16F), col2 = texture(91, 960, 540, NVN_FORMAT_RGBA16F), dep = texture(92, 960, 540, NVN_FORMAT_DEPTH32F),
          mot = texture(93, 960, 540, NVN_FORMAT_RG16F), out = texture(94, 1920, 1080, NVN_FORMAT_RGBA16F), out2 = texture(95, 1920, 1080, NVN_FORMAT_RGBA16F),
          bias = texture(89, 960, 540, NVN_FORMAT_R8);
    mtl_tex_init(&col); mtl_tex_init(&col2); mtl_tex_init(&dep); mtl_tex_init(&mot); mtl_tex_init(&out); mtl_tex_init(&out2); mtl_tex_init(&bias);
    const float a[4] = {0.5f, 0.25f, 0.75f, 0.25f}, b[4] = {0.125f, 0.625f, 0.25f, 0.75f};   // alpha too: NVN2 DLSS keeps it, MetalFX writes 1 (dlss_alpha_pso)
    fill(tex_mtl(&col), MTLClearColorMake(a[0], a[1], a[2], a[3]), 0); fill(tex_mtl(&col2), MTLClearColorMake(b[0], b[1], b[2], b[3]), 0);
    fill(tex_mtl(&dep), MTLClearColorMake(0, 0, 0, 0), 1); fill(tex_mtl(&mot), MTLClearColorMake(0, 0, 0, 0), 0);
    fill(tex_mtl(&bias), MTLClearColorMake(0, 0, 0, 0), 0);
    p_dlss c = {.tex = {&col, &dep, &mot, &out, &bias}, .net = 1, .iw = 960, .ih = 540, .ow = 1920, .oh = 1080, .mv = {1, 1}, .pre_exposure = 1, .flags = DLSS_F_MV_LOW_RES | DLSS_F_DEPTH_INVERTED, .reset = 1};   // motion at the input's size, as the game passes
    p_dlss c2 = c; c2.tex[DLSS_COLOR] = &col2; c2.tex[DLSS_OUTPUT] = &out2;
    for (int frame = 0; frame < 4; frame++) {   // the temporal scaler settles over a few frames of the same input
        mtl_sub_begin(); dlss_eval(&c); dlss_eval(&c2);
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission completes");
        c.reset = c2.reset = 0;
    }
    CHECK(g_dlss[0].sc != nil, "MetalFX made a temporal scaler for these formats");
    CHECK(g_dlss[0].mask && g_dlss[0].sc.reactiveMaskTextureFormat == MTLPixelFormatR8Unorm, "the scaler takes the DLSS bias mask as its reactive mask, in the mask's format");
    CHECK(g_dlss[0].sc.reactiveMaskTexture == tex_mtl(&bias), "the evaluation hands the bias mask's texture to the scaler");
    tex_t col3 = texture(96, 960, 486, NVN_FORMAT_RGBA16F), dep3 = texture(97, 960, 486, NVN_FORMAT_DEPTH32F), mot3 = texture(98, 960, 486, NVN_FORMAT_RG16F), out3 = texture(99, 1920, 972, NVN_FORMAT_RGBA16F);
    mtl_tex_init(&col3); mtl_tex_init(&dep3); mtl_tex_init(&mot3); mtl_tex_init(&out3);
    fill(tex_mtl(&col3), MTLClearColorMake(b[0], b[1], b[2], 1), 0); fill(tex_mtl(&dep3), MTLClearColorMake(0, 0, 0, 0), 1); fill(tex_mtl(&mot3), MTLClearColorMake(0, 0, 0, 0), 0);
    p_dlss c3 = c; c3.net = c.net = 2; c.reset = 1; c3.tex[DLSS_COLOR] = &col3; c3.tex[DLSS_DEPTH] = &dep3; c3.tex[DLSS_MOTION] = &mot3; c3.tex[DLSS_OUTPUT] = &out3; c3.iw = 960; c3.ih = 486; c3.ow = 1920; c3.oh = 972;
    // A new network evaluated at 1920x1080, then at 1920x972 (Fast Fusion's second size) in the same submission: the first scaler is kept beside the second, then finalizing the
    // network drops both from the cache before commit. The encoding thread has made the evaluations' calls by then (rec_drain, as a game's frame of records hands them over in pieces),
    // so only deferred release keeps the dropped scalers alive until the submission completes (NSZombieEnabled turns an early release into a crash every time)
    mtl_sub_begin(); dlss_eval(&c);
    const void *first = (__bridge void *)g_dlss[1].sc;   // its address only: a reference here would keep it alive
    rec_drain(); dlss_eval(&c3);
    CHECK(first && g_dlss[1].sc && (__bridge void *)g_dlss[1].sc == first && g_dlss[2].sc && (__bridge void *)g_dlss[2].sc != first, "new sizes keep the network's earlier scaler beside the new one");
    rec_drain(); mtl_dlss_forget(2); dlss_retire_drain();
    CHECK(!g_dlss[1].sc && !g_dlss[2].sc, "finalizing the network drops its scalers from the cache before commit");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission that encoded the dropped scalers completes");
    CHECK(flat(tex_mtl(&out), a), "the first evaluation's output holds its own colour");
    CHECK(flat(tex_mtl(&out2), b), "the second evaluation through the same scaler holds its own");
    // Alpha through MetalFX (upstream NXNative 1db4bcb28): an input whose content fills only part of its texture, its padding at another alpha, keeps the content's alpha at
    // every output pixel, edges and corners too (the alpha pass clamps its taps to the content's texel centres)
    tex_t col5 = texture(110, 1024, 576, NVN_FORMAT_RGBA16F), dep5 = texture(111, 1024, 576, NVN_FORMAT_DEPTH32F), mot5 = texture(112, 1024, 576, NVN_FORMAT_RG16F), out5 = texture(113, 1536, 864, NVN_FORMAT_RGBA16F);
    mtl_tex_init(&col5); mtl_tex_init(&dep5); mtl_tex_init(&mot5); mtl_tex_init(&out5);
    fill_alpha_rect(tex_mtl(&col5), b, 0, 0, 768, 432); fill(tex_mtl(&dep5), MTLClearColorMake(0, 0, 0, 0), 1); fill(tex_mtl(&mot5), MTLClearColorMake(0, 0, 0, 0), 0);
    p_dlss c5 = {.tex = {&col5, &dep5, &mot5, &out5}, .net = 5, .iw = 768, .ih = 432, .ow = 1536, .oh = 864, .mv = {1, 1}, .pre_exposure = 1, .flags = DLSS_F_DEPTH_INVERTED, .reset = 1};
    mtl_sub_begin(); dlss_eval(&c5);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the padded input's submission completes");
    CHECK(alpha_flat(tex_mtl(&out5), b[3]), "a padded input's alpha clamps to its content at every output edge and corner");
    // The record's ow/oh keep the builder's original size after NetworkResize; alpha follows the scaler's own output extent (upstream: Star Fox, 1920x1080 resized to 960x540)
    c5.ow = 3072; c5.oh = 1728; c5.reset = 1;
    mtl_sub_begin(); dlss_eval(&c5);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission with the original builder size completes");
    CHECK(alpha_flat(tex_mtl(&out5), b[3]), "alpha follows the scaler's output extent rather than the original builder size");
    // The scaler after the work before it, and the next pass after the scaler (mfx_order). Before: a slow pass writes the colour just before each evaluation and ends with no
    // barrier, as a scaler's own encoders end (the passes the host ends carry barriers of their own); behind an encoder of barriers alone the scaler read the colour before it in
    // most rounds. After: a draw pass copies the output right after the evaluation, which DM_NVN_BARRIER=game (a run of the Makefile's) orders only if the relaxed end is cleared
    tex_t cp = texture(104, 1920, 1080, NVN_FORMAT_RGBA16F); mtl_tex_init(&cp);
    float rc[2][4] = {{a[0], a[1], a[2], 1}, {b[0], b[1], b[2], 1}}; int drawn = 0, stale_in = 0, stale_out = 0;
    for (int round = 0; round < 8; round++) {
        mtl_sub_begin(); drawn += slow_draw(tex_mtl(&col), rc[round & 1], 200000, 1); c.reset = 1; dlss_eval(&c); drawn += copy_draw(tex_mtl(&out), tex_mtl(&cp));
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission with passes around the evaluation completes");
        stale_in += !flat(tex_mtl(&out), rc[round & 1]); stale_out += !flat(tex_mtl(&cp), rc[round & 1]);
    }
    CHECK(drawn == 16, "the passes around the evaluation are drawn");
    CHECK(!stale_in, "the scaler reads the colour the pass just before it wrote, in every round");
    CHECK(!stale_out, "the pass after the scaler reads its output, in every round");
    const float kept = moved_board(10, 0), dropped = moved_board(11, 1);
    printf("moved board, mean distance to a reset: mask 0 %.4f, mask 1 %.4f\n", kept, dropped);
    CHECK(kept > 0.02f, "with the reactive mask at 0 the scaler keeps history the motion vectors do not carry");
    CHECK(dropped < kept * 0.5f, "with the reactive mask at 1 the scaler takes the current frame, as DLSS's bias mask asks");   // M4 Max: 0.171 at 0, 0.054 at 1 (upstream's Mac: 0.164, 0.021); 0.17 at 1 with the mask dropped
    printf("t_dlss_mfx (encoding thread %s): %d checks, %d failed\n", rec_on() ? "on" : "off", checks, failed);
    return failed != 0;
}}
