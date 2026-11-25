// nn::ndve's movie network through the replay's dispatch hook (nvn_ndve.inc ndve_engine_dispatch), on synthetic textures and zero weights: the 14 dispatches of a movie frame,
// the colour conversion's 1920x1080 RGBA8 picture a gradient. DM_NDVE_ENGINE=mfx (the iPhone's default): the network's 12 dispatches and the resampler taken, the network's
// RGB10A2 image left unwritten, and MetalFX's spatial scaler writes the 2560x1440 RGBA8 canvas: its size kept, not black, the mean colour of the picture within a few steps,
// the gradient the right way round, and upside down when the resampler's constants flip its rows; the same through MetalFX's own input and output (copies). Unset (the Mac's default) or =1: the host's network writes the image and its
// resampler the canvas, the same checks on the canvas. Fallbacks under mfx: a canvas missing at the resampler runs the network into the image for the game's resampler
// (returned 0, never a black or frozen movie), MetalFX failing at the resampler runs the host's network and resampler for that frame and every one after, and a chain that is
// not the model's (weights out of place) leaves every later dispatch to the game. Also under mfx: the network's tensors are not made until the network runs; a 2048x1152
// canvas (the docked iPhone's output size) is scaled too; a dispatch that does not read the network's image may come before the resampler, while one that reads it, or
// the next frame's colour conversion with no resampler in between, gets the network's image written first and MetalFX off. DM_NDVE_ENGINE=ab with DM_AB: the host's network
// in the even phases, MetalFX in the odd ones, each sequence keeping the kind it started with. The values DM_NDVE_ENGINE takes (ndve_parse) are checked under any setting
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static tex_t texture(uint64_t serial, unsigned w, unsigned h, int format, int image) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .off = serial << 24};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    if (image) t.d.flags |= NVN_TEXTURE_FLAGS_IMAGE;
    nvn_tex_layout(&t.d, &t.L); return t;
}
// Whole-texture copies through a shared buffer (4 bytes a texel: RGBA8 and RGB10A2)
static void upload(id<MTLTexture> t, const uint32_t *px) {
    NSUInteger n = t.width * t.height; id<MTLBuffer> b = [g_dev newBufferWithBytes:px length:n * 4 options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, t); t4_use(cb, b);
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:t.width * 4 sourceBytesPerImage:n * 4 sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    t4_end(cb, e); t4_wait(cb);
}
static uint32_t *readback(id<MTLTexture> t) {
    NSUInteger n = t.width * t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, t); t4_use(cb, b);
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 4 destinationBytesPerImage:n * 4];
    t4_end(cb, e); t4_wait(cb);
    uint32_t *p = malloc(n * 4); memcpy(p, b.contents, n * 4); return p;
}
static void clear(id<MTLTexture> t) { uint32_t *z = calloc(t.width * t.height, 4); upload(t, z); free(z); }
static long nonzero(id<MTLTexture> t) { uint32_t *p = readback(t); long k = 0; for (NSUInteger i = 0; i < t.width * t.height; i++) k += (p[i] & 0x3fffffff) != 0; free(p); return k; }   // colour bits only
// The mean of each RGBA8 channel over rows y0..y1-1 (0..255)
static void mean_rows(id<MTLTexture> t, NSUInteger y0, NSUInteger y1, double m[4]) {
    uint32_t *p = readback(t); double s[4] = {0};
    for (NSUInteger y = y0; y < y1; y++) for (NSUInteger x = 0; x < t.width; x++) { uint32_t v = p[y * t.width + x]; for (int c = 0; c < 4; c++) s[c] += v >> (8 * c) & 255; }
    for (int c = 0; c < 4; c++) m[c] = s[c] / (double)((y1 - y0) * t.width);
    free(p);
}
static double mean_cols(id<MTLTexture> t, NSUInteger x0, NSUInteger x1, int c) {
    uint32_t *p = readback(t); double s = 0;
    for (NSUInteger y = 0; y < t.height; y++) for (NSUInteger x = x0; x < x1; x++) s += p[y * t.width + x] >> (8 * c) & 255;
    free(p); return s / (double)((x1 - x0) * t.height);
}
static NvShader *shader(const char *key, int nb, const nvn_rbind *b) {
    NvShader *s = [NvShader new]; snprintf(s->key, sizeof s->key, "%s_b", key);
    s->rf.nb = nb; for (int i = 0; i < nb; i++) s->rf.b[i] = b[i];
    return s;
}
static NvShader *g_sh[NDVE_N]; static uint64_t g_w0, g_wrs;
static int g_cvw = 2560, g_cvh = 1440, g_no_rs;   // the canvas the resampler's constants describe; g_no_rs: the frame ends after 5a7d69b0 (returns -1)
enum { PIC = 801, NET_IMG = 802, NET_TEX = 803, DITH = 804, CANVAS = 805, CANVAS2 = 806 };
// One movie frame's 14 dispatches in one submission: *taken counts the network's dispatches the hook took, the resampler's answer returned. bad: the network dispatch whose
// weights are moved off the model's place (0: none); mid: run between 5a7d69b0 and the resampler (a failure to inject)
static int movie_frame(int *taken, int flip, int bad, void (^mid)(void)) {
    p_dispatch dp = {0}; int n = 0;
    mtl_sub_begin();
    memset(S.ssbo[5], 0, sizeof S.ssbo[5]);
    CHECK(!ndve_engine_dispatch(g_sh[0], &dp), "the colour conversion always runs");
    for (int p = 1; p <= 12; p++) {
        S.ssbo[5][2] = (p_bind_buf){.addr = g_w0 + g_ndve_w[p] + (p == bad ? 256 : 0), .size = 256};
        S.ssbo[5][3] = (p_bind_buf){.addr = g_w0 + g_ndve_b[p], .size = 32};
        n += ndve_engine_dispatch(g_sh[p], &dp);
    }
    if (mid) mid();
    int rs = -1;
    if (!g_no_rs) {
        S.ssbo[5][2] = (p_bind_buf){.addr = g_wrs, .size = 0x3000}; S.ssbo[5][3] = (p_bind_buf){0};
        int32_t c[24] = {0}; c[2] = 1919; c[3] = 1079; c[6] = g_cvw - 1; c[7] = g_cvh - 1; c[20] = 1; if (flip) { c[18] = g_cvh - 1; c[19] = 1; }
        const float px[2] = {1.0f / g_cvw, 1.0f / g_cvh}; memcpy(&c[10], px, sizeof px);   // s2.zw: the output texel's size in uv (the host's resampler samples the picture there)
        memcpy(S.push[1], c, sizeof c);
        rs = ndve_engine_dispatch(g_sh[13], &dp);
    }
    CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull) && !mtl_last_commit_error(), "the movie frame's submission completes");
    *taken = n; return rs;
}
int main(void) { @autoreleasepool {
    // DM_NDVE_ENGINE's values (ndve_parse): unset or empty the platform's default, mfx / metalfx, check, ab, 0, any other number the host's network, another word refused
    CHECK(ndve_parse(NULL, 1) == NDVE_MFX && ndve_parse("", 1) == NDVE_MFX && ndve_parse(NULL, 0) == NDVE_NET && ndve_parse("", 0) == NDVE_NET, "unset: MetalFX on iOS, the host's network on the Mac");
    CHECK(ndve_parse("1", 1) == NDVE_NET && ndve_parse("2", 0) == NDVE_NET && ndve_parse("0", 1) == NDVE_GAME && ndve_parse("0", 0) == NDVE_GAME, "1 the host's network, 0 the game's, on either platform");
    CHECK(ndve_parse("mfx", 0) == NDVE_MFX && ndve_parse("metalfx", 0) == NDVE_MFX && ndve_parse("check", 1) == NDVE_CHECK && ndve_parse("ab", 1) == NDVE_AB && ndve_parse("ab:1/2", 0) == NDVE_AB,
          "mfx forces MetalFX on the Mac too; check and ab as before");
    CHECK(ndve_parse("on", 1) < 0 && ndve_parse("1x", 0) < 0, "another word is refused (the default kept, with a red line)");
    CHECK(NDVE_MFX_DEFAULT == 0, "this test runs on the Mac, where the default is the host's network");
    mtl_init();
    const int sel = ndve_sel(), mfx = sel == NDVE_MFX, ab = sel == NDVE_AB;
    if (sel == NDVE_GAME || sel == NDVE_CHECK || (ab && !g_ndve_ab)) { printf("t_ndve_mfx: DM_NDVE_ENGINE=%s is not a mode this test drives (unset, 1, mfx, or ab with DM_AB)\n", getenv("DM_NDVE_ENGINE")); return 1; }
    // The textures: the picture (the colour conversion's image, the network's input), the network's RGB10A2 image (an image to 5a7d69b0, a texture to the resampler), the dither, the canvas
    tex_t pic = texture(81, 1920, 1080, NVN_FORMAT_RGBA8, 1), net = texture(82, 1920, 1080, NVN_FORMAT_RGB10A2, 1), dith = texture(83, 512, 512, NVN_FORMAT_RGBA8, 0),
          canvas = texture(84, 2560, 1440, NVN_FORMAT_RGBA8, 1), canvas2 = texture(85, 2048, 1152, NVN_FORMAT_RGBA8, 1);
    mtl_tex_init(&pic); mtl_tex_init(&net); mtl_tex_init(&dith); mtl_tex_init(&canvas); mtl_tex_init(&canvas2);
    mtl_reg_tex(PIC, &pic, NULL); mtl_reg_image(NET_IMG, &net, NULL); mtl_reg_tex(NET_TEX, &net, NULL); mtl_reg_tex(DITH, &dith, NULL); mtl_reg_image(CANVAS, &canvas, NULL);
    mtl_reg_image(CANVAS2, &canvas2, NULL);
    id<MTLTexture> tpic = tex_mtl(&pic), tnet = tex_mtl(&net), tcanvas = tex_mtl(&canvas), tcanvas2 = tex_mtl(&canvas2);
    { uint32_t *g = malloc(1920 * 1080 * 4);   // red across, green down, blue 128
      for (int y = 0; y < 1080; y++) for (int x = 0; x < 1920; x++) g[y * 1920 + x] = (uint32_t)(x * 255 / 1919) | (uint32_t)(y * 255 / 1079) << 8 | 128u << 16 | 255u << 24;
      upload(tpic, g); free(g); }
    double want[4]; mean_rows(tpic, 0, 1080, want);
    clear(tex_mtl(&dith));
    // Zero weights in a memory pool: the network adds nothing to the picture, the resampler's network nothing to its bilinear sample
    void *mem = NULL; const size_t wlen = 0x40000 + 0x4000;
    if (posix_memalign(&mem, 16384, wlen)) { fprintf(stderr, "no weight memory\n"); return 1; }
    memset(mem, 0, wlen); mtl_pool_add(mem, wlen);
    g_w0 = (uint64_t)(uintptr_t)mem; g_wrs = g_w0 + 0x3c400;
    CHECK(ndve_offsets(), "the layer table adds up to the model's weights");
    // The shaders: the model's keys, the bindings the hook reads
    const nvn_rbind first[1] = {{.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 1}};
    const nvn_rbind last[2] = {{.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 4}, {.kind = NVN_RB_IMG, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 0, .rw = 1}};
    const nvn_rbind rs[3] = {{.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 0}, {.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 3},
                             {.kind = NVN_RB_IMG, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 1, .rw = 1}};
    for (int i = 0; i < NDVE_N; i++) g_sh[i] = i == 1 ? shader(k_ndve_keys[i], 1, first) : i == 12 ? shader(k_ndve_keys[i], 2, last) : i == 13 ? shader(k_ndve_keys[i], 3, rs) : shader(k_ndve_keys[i], 0, NULL);
    memset(&S, 0, sizeof S);
    S.tex[5][1] = PIC; S.tex[5][4] = PIC; S.img[5][0] = NET_IMG; S.tex[5][0] = NET_TEX; S.tex[5][3] = DITH; S.img[5][1] = CANVAS;
    // The pipelines and the scaler build in the background at the first movie dispatch; until then the game's dispatches run
    { p_dispatch dp = {0}; mtl_sub_begin(); ndve_engine_dispatch(g_sh[0], &dp); mtl_wait(mtl_sub_commit(), 5000000000ull); }
    for (int k = 0; k < 3000 && g_nd.state == 1; k++) usleep(10000);
    CHECK(g_nd.state == 2, "the engine's pipelines are ready");
    CHECK(g_nd.mfx_state == (mfx || ab ? 2 : -1), mfx || ab ? "MetalFX made the movie's scaler" : "no scaler is made when the network runs");
    CHECK(mfx ? !g_nd.t[0] && !g_nd.luma : g_nd.t[0] && g_nd.luma, mfx ? "mfx: the network's tensors (92 MB) are not made while MetalFX draws" : "the network's tensors are made with the pipelines");
    if (mfx) CHECK(g_nd.mfx[0] && g_nd.mfx[1], "a scaler for each canvas, 2560x1440 and 2048x1152");
    int taken = 0, r;
    // 1. A frame in the mode asked for
    clear(tnet); clear(tcanvas);
    r = movie_frame(&taken, 0, 0, nil);
    CHECK(taken == 12 && r == 1, "the network's 12 dispatches and the resampler are taken");
    CHECK(tcanvas.width == 2560 && tcanvas.height == 1440 && tex_mtl(&canvas) == tcanvas, "the canvas keeps the game's texture and size");
    CHECK(nonzero(tcanvas) == 2560 * 1440, "every texel of the canvas is written, none black");
    double m[4]; mean_rows(tcanvas, 0, 1440, m);
    for (int c = 0; c < 3; c++) if (!(fabs(m[c] - want[c]) <= 4)) { fprintf(stderr, "channel %d: mean %.2f, the picture's %.2f\n", c, m[c], want[c]); CHECK(0, "the canvas keeps the picture's mean colour"); }
    CHECK(mean_cols(tcanvas, 0, 16, 0) < 8 && mean_cols(tcanvas, 2544, 2560, 0) > 247, "red rises left to right, as in the picture");
    { double top[4], bot[4]; mean_rows(tcanvas, 0, 4, top); mean_rows(tcanvas, 1436, 1440, bot); CHECK(top[1] < 8 && bot[1] > 247, "green rises top to bottom: the picture the right way up"); }
    if (mfx) {
        CHECK(nonzero(tnet) == 0, "MetalFX: the network's image is never written (its 12 dispatches skipped, nothing computed in their place)");
        CHECK(g_nd.mfx_frames == 1 && g_nd.frames == 0, "MetalFX drew the frame, not the host's network");
        printf("t_ndve_mfx: the picture %s, the canvas %s\n", g_nd.mfx_sides & 1 ? "straight" : "copied", g_nd.mfx_sides & 2 ? "straight" : "copied");
        // 2. The resampler flips its rows: the picture goes in upside down
        clear(tcanvas);
        r = movie_frame(&taken, 1, 0, nil);
        CHECK(taken == 12 && r == 1 && g_nd.mfx_frames == 2, "a resampler that flips its rows is drawn by MetalFX too");
        { double top[4], bot[4]; mean_rows(tcanvas, 0, 4, top); mean_rows(tcanvas, 1436, 1440, bot); CHECK(top[1] > 247 && bot[1] < 8, "flipped: green falls top to bottom, as the resampler would write it"); }
        mean_rows(tcanvas, 0, 1440, m);
        CHECK(fabs(m[0] - want[0]) <= 4 && fabs(m[1] - want[1]) <= 4 && fabs(m[2] - want[2]) <= 4, "flipped: the mean colour kept");
        // 2b. Both sides through MetalFX's own textures (a game texture it cannot take): the picture copied in, the canvas copied out
        clear(tcanvas); g_ndve_mfx_own = 1;
        r = movie_frame(&taken, 0, 0, nil);
        g_ndve_mfx_own = 0;
        CHECK(taken == 12 && r == 1 && g_nd.mfx_sides == 0 && g_nd.mfx_in && g_nd.mfx_out[0], "MetalFX through its own input and output, copied in and out");
        CHECK(nonzero(tcanvas) == 2560 * 1440, "copied out: every texel of the canvas written");
        mean_rows(tcanvas, 0, 1440, m);
        CHECK(fabs(m[0] - want[0]) <= 4 && fabs(m[1] - want[1]) <= 4 && fabs(m[2] - want[2]) <= 4, "copied in and out: the mean colour kept");
        { double top[4], bot[4]; mean_rows(tcanvas, 0, 4, top); mean_rows(tcanvas, 1436, 1440, bot); CHECK(top[1] < 8 && bot[1] > 247, "copied in and out: the right way up"); }
        // 2c. A 2048x1152 canvas (the docked iPhone's output size), the right way up and flipped
        S.img[5][1] = CANVAS2; g_cvw = 2048; g_cvh = 1152;
        for (int f = 0; f < 2; f++) {
            uint64_t mf = g_nd.mfx_frames; clear(tcanvas2);
            r = movie_frame(&taken, f, 0, nil);
            CHECK(taken == 12 && r == 1 && g_nd.mfx_frames == mf + 1 && g_nd.mfx_state == 2, "a 2048x1152 canvas is scaled by MetalFX too");
            CHECK(nonzero(tcanvas2) == 2048 * 1152, "2048x1152: every texel of the canvas written");
            mean_rows(tcanvas2, 0, 1152, m);
            CHECK(fabs(m[0] - want[0]) <= 4 && fabs(m[1] - want[1]) <= 4 && fabs(m[2] - want[2]) <= 4, "2048x1152: the mean colour kept");
            { double top[4], bot[4]; mean_rows(tcanvas2, 0, 4, top); mean_rows(tcanvas2, 1148, 1152, bot); CHECK(f ? top[1] > 247 && bot[1] < 8 : top[1] < 8 && bot[1] > 247, f ? "2048x1152 flipped: upside down" : "2048x1152: the right way up"); }
        }
        S.img[5][1] = CANVAS; g_cvw = 2560; g_cvh = 1440;
        CHECK(!g_nd.t[0] && nonzero(tnet) == 0, "no network yet: its tensors not made, its image never written");
        // 2d. A dispatch that does not read the network's image, between 5a7d69b0 and the resampler: MetalFX still draws the frame
        const nvn_rbind other_b[1] = {{.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 3}};   // the dither, not the network's image
        NvShader *other = shader("0123456789abcdef", 1, other_b);
        const nvn_rbind reader_b[1] = {{.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 0}};   // the network's image, as a texture
        NvShader *reader = shader("fedcba9876543210", 1, reader_b);
        { uint64_t mf = g_nd.mfx_frames; __block int took = -1;
          r = movie_frame(&taken, 0, 0, ^{ p_dispatch d0 = {0}; took = ndve_engine_dispatch(other, &d0); });
          CHECK(took == 0 && taken == 12 && r == 1 && g_nd.mfx_frames == mf + 1 && g_nd.mfx_state == 2 && nonzero(tnet) == 0, "a dispatch that does not read the network's image leaves the frame to MetalFX"); }
        // 2e. A dispatch that reads the network's image before the resampler (another game's resampler, say): the network the frame skipped is written first, MetalFX off
        { __block int took = -1; __block uint64_t fr = 0;
          r = movie_frame(&taken, 0, 0, ^{ p_dispatch d0 = {0}; took = ndve_engine_dispatch(reader, &d0); fr = g_nd.mfx_frames; });
          CHECK(took == 0 && g_nd.mfx_state == -1, "a dispatch reading the network's image first: it runs, MetalFX is off");
          CHECK(nonzero(tnet) > 1920 * 1080 / 2, "and the network's image is written before it: not a black or frozen movie");
          CHECK(r == 1 && g_nd.mfx_frames == fr, "the resampler after it is the host's, from the image written");
          CHECK(g_nd.t[0] && g_nd.luma && !g_nd.t_zero, "the network's tensors were made when it first ran, and zeroed"); }
        // 2f. The next frame's colour conversion with no resampler in between: the image is written before it, MetalFX off
        g_nd.mfx_state = 2; clear(tnet); g_no_rs = 1;
        r = movie_frame(&taken, 0, 0, nil);
        g_no_rs = 0;
        CHECK(taken == 12 && nonzero(tnet) == 0 && g_nd.seq_mfx && g_nd.pos == 13, "a frame with no resampler: the network's image not written yet");
        { p_dispatch d0 = {0}; mtl_sub_begin(); r = ndve_engine_dispatch(g_sh[0], &d0); CHECK(mtl_wait(mtl_sub_commit(), 10000000000ull) && !mtl_last_commit_error(), "the colour conversion's submission completes"); }
        CHECK(r == 0 && g_nd.mfx_state == -1 && nonzero(tnet) > 1920 * 1080 / 2, "the next colour conversion: the network the frame skipped is written before it, MetalFX off");
        g_nd.mfx_state = 2;
        // 3. The canvas missing at the resampler: the network runs into its image after all, for the game's resampler (the dispatch returned to the game)
        clear(tnet);
        r = movie_frame(&taken, 0, 0, ^{ S.img[5][1] = 0; });
        S.img[5][1] = CANVAS;
        CHECK(taken == 12 && r == 0, "a missing canvas leaves the resampler to the game");
        CHECK(nonzero(tnet) > 1920 * 1080 / 2, "and the network the frame skipped is in its image for it: not a black or frozen movie");
        CHECK(g_nd.mfx_state == -1, "MetalFX is off from then on");
        // 4. The next frame and the ones after: the host's network
        g_nd.mfx_state = 2;   // MetalFX back for the next case
        clear(tnet); clear(tcanvas);
        r = movie_frame(&taken, 0, 0, ^{ g_nd.mfx_state = -1; });   // MetalFX fails between 5a7d69b0 and the resampler
        CHECK(taken == 12 && r == 1, "MetalFX failing at the resampler: the host's network and resampler draw the frame");
        CHECK(nonzero(tnet) > 1920 * 1080 / 2 && nonzero(tcanvas) == 2560 * 1440, "the network's image and the canvas are written");
        uint64_t mf = g_nd.mfx_frames, nf = g_nd.frames;
        clear(tnet);
        r = movie_frame(&taken, 0, 0, nil);
        CHECK(taken == 12 && r == 1 && g_nd.mfx_frames == mf && g_nd.frames == nf + 1 && nonzero(tnet) > 1920 * 1080 / 2, "after the failure the host's network runs the movie");
    } else CHECK(nonzero(tnet) > 1920 * 1080 / 2 && g_nd.frames == 1 && g_nd.mfx_frames == 0, "the host's network wrote its image and drew the frame");
    if (ab) {   // DM_NDVE_ENGINE=ab (DM_AB=1: phase 0 off, odd phases on): MetalFX in the odd phases, the host's network in the even ones, latched when a sequence starts
        for (int ph = 0; ph < 4; ph++) {
            uint64_t mf = g_nd.mfx_frames, nf = g_nd.frames; atomic_store(&g_ab_phase, ph); clear(tnet);
            r = movie_frame(&taken, 0, 0, ^{ atomic_store(&g_ab_phase, ph + 1); });   // the phase changes in the middle of the sequence: no effect on it
            CHECK(taken == 12 && r == 1 && (ph & 1 ? g_nd.mfx_frames == mf + 1 && g_nd.frames == nf && nonzero(tnet) == 0 : g_nd.frames == nf + 1 && g_nd.mfx_frames == mf && nonzero(tnet) > 1920 * 1080 / 2),
                  ph & 1 ? "ab: an on phase's sequence is MetalFX's, a phase change in it notwithstanding" : "ab: an off phase's sequence is the host's network, a phase change in it notwithstanding");
        }
        atomic_store(&g_ab_phase, 0);
    }
    // 5. A chain that is not the model's: weights out of place after two dispatches were skipped. The engine is off for the rest of the run, every dispatch the game's
    r = movie_frame(&taken, 0, 3, nil);
    CHECK(taken == 2 && r == 0 && g_nd.off, "weights out of place: the dispatches from there on are the game's, the engine off");
    r = movie_frame(&taken, 0, 0, nil);
    CHECK(taken == 0 && r == 0, "and every later frame's are the game's");
    printf("t_ndve_mfx (%s): %d checks, %d failed\n", mfx ? "mfx" : ab ? "ab" : "network", checks, failed);
    return failed != 0;
}}
