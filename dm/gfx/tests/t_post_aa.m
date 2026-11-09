// Edge smoothing in the present (DM_POST_AA: nvn_mtl.m aa_encode, dm/gfx/msl/cmaa2.metal) on a synthetic aliased picture: large flat triangles drawn with binary coverage (stair
// steps), a shallow half-plane, and a HUD block of 1-2 pixel white strokes on dark. Real Metal 4 presents through present_offscreen_m4 (as screenshots) and present_encode_m4 (as
// the live present), checked against the source bytes: off is byte-identical; edge changes only pixels beside an edge and smooths the steps; the strokes change within a bound;
// a crop smaller than its texture gives the same picture as the crop alone; an sRGB swapchain is smoothed in linear light; the lists' clamps hold; MetalFX takes the smoothed
// texture as its input. `t_post_aa bench` times the run at the study's sizes instead (the docs' M4 Max figures)
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle   // both files have a static g_ft (see t_present_crop.m)
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
void dm_vi_layer_crop(int c[4]) { memset(c, 0, 4 * sizeof *c); }
static int failed, cases;
#define EXPECT(n, w, v) do { long a_=(w),b_=(v); cases++; printf("%s expected %ld → got %ld %s\n",n,a_,b_,a_==b_?"✓":"✗");failed+=a_!=b_; } while(0)
#define CHECK(n, c) EXPECT(n, 1, !!(c))

enum { W = 256, H = 192 };
// The scene, W x H RGBA8 bytes; hud: 1 where a HUD stroke is (NULL = not wanted). foliage: 40,000 small triangles in place of the large ones (the bench's dense case)
static void tri(uint8_t *p, int w, int h, const float v[6], const uint8_t c[4]) {
    float x0 = fminf(v[0], fminf(v[2], v[4])), x1 = fmaxf(v[0], fmaxf(v[2], v[4])), y0 = fminf(v[1], fminf(v[3], v[5])), y1 = fmaxf(v[1], fmaxf(v[3], v[5]));
    float area = (v[2] - v[0]) * (v[5] - v[1]) - (v[3] - v[1]) * (v[4] - v[0]); if (area == 0) return;
    for (int y = (int)fmaxf(0, floorf(y0)); y < h && y <= y1; y++) for (int x = (int)fmaxf(0, floorf(x0)); x < w && x <= x1; x++) {
        float px = x + 0.5f, py = y + 0.5f;
        float a = ((v[2] - v[0]) * (py - v[1]) - (v[3] - v[1]) * (px - v[0])) / area, b = ((v[4] - v[2]) * (py - v[3]) - (v[5] - v[3]) * (px - v[2])) / area, d = ((v[0] - v[4]) * (py - v[5]) - (v[1] - v[5]) * (px - v[4])) / area;
        if (a >= 0 && b >= 0 && d >= 0) memcpy(p + 4 * (y * w + x), c, 4);
    }
}
static void scene(uint8_t *p, int w, int h, uint8_t *hud, int foliage, long seed) {
    srand48(seed);
    for (int i = 0; i < w * h; i++) { p[4 * i] = 90; p[4 * i + 1] = 110; p[4 * i + 2] = 100; p[4 * i + 3] = 255; }
    int n = foliage ? 40000 : 14;
    for (int i = 0; i < n; i++) {
        float cx = drand48() * w, cy = drand48() * h, r = foliage ? 1.5f + drand48() * 6 : 30 + drand48() * w / 3.0f, v[6];
        for (int k = 0; k < 3; k++) { double a = drand48() * 6.283; v[2 * k] = cx + r * cos(a); v[2 * k + 1] = cy + r * sin(a); }
        uint8_t c[4] = {(uint8_t)(drand48() * 256), (uint8_t)(drand48() * 256), (uint8_t)(drand48() * 256), 255};
        tri(p, w, h, v, c);
    }
    // A shallow half-plane in the top-right corner: black below a 1:5 slope, white above (CMAA2's long Z shapes)
    for (int y = 0; y < h / 3; y++) for (int x = 2 * w / 3; x < w; x++) { uint8_t v = y < (x - 2 * w / 3) / 5.0f + 4 ? 255 : 0; p[4 * (y * w + x)] = p[4 * (y * w + x) + 1] = p[4 * (y * w + x) + 2] = v; }
    // The HUD: the bottom-left corner dark, with white strokes 1-2 pixels wide and 4-12 long, across, down and diagonal
    if (hud) memset(hud, 0, (size_t)w * h);
    int hx = w / 3, hy = 2 * h / 3;
    for (int y = hy; y < h; y++) for (int x = 0; x < hx; x++) { uint8_t *q = p + 4 * (y * w + x); q[0] = 20; q[1] = 20; q[2] = 30; }
    for (int i = 0; i < (w >= 1000 ? 3000 : 60); i++) {   // the study's 3,000 at the bench's sizes
        int x = 2 + (int)(drand48() * (hx - 16)), y = hy + 2 + (int)(drand48() * (h - hy - 16)), len = 4 + (int)(drand48() * 9), wid = 1 + (i & 1), o = i % 3;
        for (int s = 0; s < len; s++) for (int t = 0; t < wid; t++) {
            int px = o == 0 ? x + s : o == 1 ? x + t : x + s + t, py = o == 0 ? y + t : y + s;
            if (px >= w || py >= h) continue;
            uint8_t *q = p + 4 * (py * w + px); q[0] = q[1] = q[2] = 255; if (hud) hud[py * w + px] = 1;
        }
    }
}
// A tw x th texture of format pf holding px (cw x ch bytes) at (cx, cy) and noise elsewhere (seed: its pattern)
static id<MTLTexture> src_tex(MTLPixelFormat pf, int tw, int th, int cx, int cy, int cw, int ch, const uint8_t *px, long seed) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:tw height:th mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
    uint8_t *b = malloc((size_t)tw * th * 4); srand48(seed);
    for (int i = 0; i < tw * th * 4; i++) b[i] = (uint8_t)(drand48() * 256);
    for (int y = 0; y < ch; y++) memcpy(b + 4 * ((y + cy) * tw + cx), px + 4 * y * cw, 4 * cw);
    [t replaceRegion:MTLRegionMake2D(0, 0, tw, th) mipmapLevel:0 withBytes:b bytesPerRow:tw * 4];
    free(b); res_add(t); res_commit(); return t;
}
static id<MTLTexture> out_tex(int w, int h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget; return [g_dev newTextureWithDescriptor:d];
}
// The present of src's crop (NULL: whole) into a w x h RGBA8 texture as a screenshot takes it (present_offscreen_wait); its kind, the bytes in o
static int capture(id<MTLTexture> src, const int crop[4], int w, int h, uint8_t *o) {
    id<MTLTexture> out = out_tex(w, h);
    int kind = present_offscreen_wait(src, crop, out);
    [out getBytes:o bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0]; return kind;
}
// The live present's encode (present_encode_m4 with the present thread's state, as present_now), into a w x h RGBA8 texture
static int live(id<MTLTexture> src, const int crop[4], int w, int h, uint8_t *o) {
    id<MTLTexture> out = out_tex(w, h); res_add(out); res_commit();
    id<MTL4CommandAllocator> al = [g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; id<MTLSharedEvent> ev = [g_dev newSharedEvent];
    if (!al || !cb || !ev) { CHECK("live present: a command allocator and buffer", 0); res_remove(out); return PRESENT_FAILED; }
    [cb beginCommandBufferWithAllocator:al]; int kind = present_encode_m4(cb, src, out, crop, g_present_uv[0], &g_fx_present, &g_aa_present); [cb endCommandBuffer];
    [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
    CHECK("live present completes", [ev waitUntilSignaledValue:1 timeoutMS:10000]);
    if (kind & PRESENT_AA) aa_note(g_aa_present.ctl);
    [out getBytes:o bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0]; res_remove(out); return kind;
}
// 1 where the pixel and its 8 neighbours are the same colour in px (w x h): no edge for CMAA2 to find
static int flat(const uint8_t *px, int w, int h, int x, int y) {
    for (int dy = -1; dy <= 1; dy++) for (int dx = -1; dx <= 1; dx++) {
        int u = x + dx, v = y + dy; if (u < 0 || v < 0 || u >= w || v >= h) continue;
        if (memcmp(px + 4 * (v * w + u), px + 4 * (y * w + x), 3)) return 0;
    }
    return 1;
}
static double srgb_enc(double v) { return v < 0.0031308 ? v * 12.92 : 1.055 * pow(v, 1 / 2.4) - 0.055; }
static double srgb_dec(double v) { return v < 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4); }
// The RMS distance of the half-plane's edge (scene) in o from the line fitted to the source's (src), in pixels: per column, the white coverage of its rows in linear light
static double stair_rms(const uint8_t *src, const uint8_t *o) {
    int x0 = 2 * W / 3 + 3, x1 = W - 3, n = x1 - x0; double cs[W], co[W], sx = 0, sy = 0, sxx = 0, sxy = 0;
    for (int x = x0; x < x1; x++) {
        double a = 0, b = 0; for (int y = 0; y < H / 3 - 1; y++) { a += srgb_dec(src[4 * (y * W + x)] / 255.0); b += srgb_dec(o[4 * (y * W + x)] / 255.0); }
        cs[x] = a; co[x] = b; sx += x; sy += a; sxx += (double)x * x; sxy += x * a;
    }
    double k = (n * sxy - sx * sy) / (n * sxx - sx * sx), c = (sy - k * sx) / n, e = 0;
    for (int x = x0; x < x1; x++) { double d = co[x] - (k * x + c); e += d * d; }
    return sqrt(e / n);
}

// The GPU time of edge smoothing alone (its copy and five dispatches), median of 40 after 10, at the study's sizes
static void bench(void) {
    const int sizes[][2] = {{1600, 900}, {1920, 1080}, {2868, 1320}};
    atomic_store(&g_aa_mode, AA_EDGE);
    for (int fol = 0; fol < 2; fol++) for (int s = 0; s < 3; s++) {
        int w = sizes[s][0], h = sizes[s][1]; uint8_t *px = malloc((size_t)w * h * 4); scene(px, w, h, NULL, fol, 7);
        id<MTLTexture> src = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, w, h, 0, 0, w, h, px, 1), raw = present_raw_src(src);
        id<MTLBuffer> uvb = [g_dev newBufferWithLength:sizeof(float) * PRESENT_UV_FLOATS options:MTLResourceStorageModeShared]; res_add(uvb); res_commit();
        aa_state aa = {0}; NSUInteger r[4] = {0, 0, (NSUInteger)w, (NSUInteger)h}; double *t = calloc(80, sizeof *t); int n = 0;
        dispatch_semaphore_t sem = dispatch_semaphore_create(0);
        for (int it = 0; it < 80; it++) {   // back to back, as presents follow one another, so the GPU's clock does not drop between them; the last 40 count
            id<MTL4CommandAllocator> al = [g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer];
            if (!al || !cb) { printf("bench: no command allocator or buffer\n"); exit(1); }
            [cb beginCommandBufferWithAllocator:al]; aa_encode(&aa, cb, src, raw, r, uvb, 0); [cb endCommandBuffer];
            MTL4CommitOptions *o = [MTL4CommitOptions new];
            [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) { (void)al; t[it] = (f.GPUEndTime - f.GPUStartTime) * 1e3; dispatch_semaphore_signal(sem); }];
            [g_q4 commit:&cb count:1 options:o];
        }
        for (int it = 0; it < 80; it++) dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
        for (int it = 40; it < 80; it++) t[n++] = t[it];
        for (int i = 1; i < n; i++) { double x = t[i]; int j = i - 1; while (j >= 0 && t[j] > x) { t[j + 1] = t[j]; j--; } t[j + 1] = x; }
        aa_note(aa.ctl);
        printf("bench %s %dx%d: edge smoothing p50 %.3f ms (min %.3f, max %.3f); %u candidates, %u blend items, %u 2x2 locations\n", fol ? "foliage" : "typical", w, h, t[n / 2], t[0], t[n - 1],
               atomic_load(&g_aa_seen[0]), atomic_load(&g_aa_seen[1]), atomic_load(&g_aa_seen[2]));
        aa_free(&aa); res_remove(uvb); res_remove(src); free(px); free(t);
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    mtl_init();
    if (argc > 1 && !strcmp(argv[1], "bench")) { bench(); return 0; }
    mtl_present_layer(W, H);   // the picture's shape is the crop's: a W x H capture is the crop 1:1
    g_fx_mode = UP_OFF; atomic_store(&g_sharp_mode, 0);
    uint8_t *px = malloc(W * H * 4), *hud = malloc(W * H), *off = malloc(W * H * 4), *a = malloc(W * H * 4), *b = malloc(W * H * 4);
    scene(px, W, H, hud, 0, 3);
    int whole[4] = {0, 0, 0, 0};
    id<MTLTexture> s8 = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, W, H, 0, 0, W, H, px, 1), u8 = src_tex(MTLPixelFormatRGBA8Unorm, W, H, 0, 0, W, H, px, 1);

    // Off: the present as before, byte-identical to the source
    atomic_store(&g_aa_mode, AA_OFF);
    EXPECT("off: the bilinear pass", PRESENT_STANDARD, capture(s8, whole, W, H, off));
    EXPECT("off: byte-identical to the source", 0, memcmp(off, px, W * H * 4));

    // The live present never waits for the kernels to be compiled: the first present that smooths starts making them in the background and shows the picture as it is; once
    // they are made, the next present smooths
    {
        atomic_store(&g_aa_mode, AA_EDGE);
        EXPECT("first live present: the kernels are not made yet, the picture as it is", PRESENT_STANDARD, live(s8, whole, W, H, a));
        EXPECT("  byte-identical to the source", 0, memcmp(a, px, W * H * 4));
        EXPECT("  the in-game menu has nothing to say yet (front.h mtl_present_aa_why)", DM_AA_OFF, mtl_present_aa_why());
        CHECK("  the kernels being made in the background", atomic_load(&g_aa_ps_state) != 0);
        CHECK("a capture waits for them", aa_pipelines(1));
        EXPECT("the next live present smooths", PRESENT_STANDARD | PRESENT_AA, live(s8, whole, W, H, a));
        EXPECT("  and says it ran", DM_AA_RAN, mtl_present_aa_why());
    }

    // Edge, an sRGB swapchain: only pixels beside an edge change, the stair steps are smoothed, alpha and flat areas stay
    double hud_edge = 0, hud_sharp = 0; int changed_edge = 0, changed_sharp = 0;
    for (int m = AA_EDGE; m <= AA_EDGE_SHARP; m++) {
        const char *nm = m == AA_EDGE ? "edge" : "edge-sharp";
        atomic_store(&g_aa_mode, m);
        EXPECT("edge: the bilinear pass after edge smoothing", PRESENT_STANDARD | PRESENT_AA, capture(s8, whole, W, H, a));
        int moved = 0, flat_moved = 0, alpha = 0, hud_n = 0, hud_touched = 0; double hud_sum = 0;
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
            const uint8_t *p = a + 4 * (y * W + x), *q = px + 4 * (y * W + x); int d = memcmp(p, q, 4) != 0;
            moved += d; alpha += p[3] != q[3];
            if (d && flat(px, W, H, x, y)) flat_moved++;
            if (hud[y * W + x]) { hud_n++; int dd = abs(p[0] - q[0]) + abs(p[1] - q[1]) + abs(p[2] - q[2]); hud_sum += dd / 3.0; hud_touched += dd != 0; }
        }
        // The 1:5 half-plane's stair steps: each column's edge position (its rows' linear coverage summed) against the straight line fitted to the source's; aliased, a
        // sawtooth of about 0.29 pixels RMS
        double rs = stair_rms(px, px), ra = stair_rms(px, a);
        printf("  %s: %d pixels changed; the 1:5 half-plane's edge %.3f px RMS off its line (source %.3f); HUD strokes: %d of %d pixels touched, mean |change| %.2f/255\n",
               nm, moved, ra, rs, hud_touched, hud_n, hud_sum / hud_n);
        CHECK("edge: pixels changed", moved > 500);
        EXPECT("edge: no pixel without an edge beside it changed", 0, flat_moved);
        EXPECT("edge: alpha unchanged", 0, alpha);
        CHECK("edge: the shallow stair steps smoothed (the edge's distance from its line under 70 % of the source's)", ra < 0.7 * rs);
        // The HUD's bound: white strokes on dark, crossing one another, are CMAA2's hardest case short of text (measured 10.3/255 on average and 45 % touched, Extra Sharp
        // 5.1/255; docs/reference/rendering.md). A port that blurred more, or Extra Sharp that did not hold back, fails here
        CHECK(m == AA_EDGE ? "edge: the HUD strokes' pixels changed under 12/255 on average" : "edge-sharp: the HUD strokes' pixels changed under 7/255 on average", hud_sum / hud_n < (m == AA_EDGE ? 12 : 7));
        CHECK("edge: under half the HUD strokes' pixels touched", hud_touched * 2 < hud_n);
        if (m == AA_EDGE) { hud_edge = hud_sum / hud_n; changed_edge = moved; memcpy(b, a, W * H * 4); } else { hud_sharp = hud_sum / hud_n; changed_sharp = moved; }
    }
    CHECK("edge-sharp: changes the HUD strokes less than edge", hud_sharp < hud_edge);
    CHECK("edge-sharp: changes fewer pixels than edge", changed_sharp < changed_edge);
    atomic_store(&g_aa_mode, AA_EDGE);

    // A crop smaller than its texture: the same picture as the crop alone, whatever lies around it (an older crop's texels), at an odd size and offset
    {
        const int cw = 201, ch = 147, cx = 13, cy = 7; uint8_t *cpx = malloc(cw * ch * 4), *c1 = malloc(cw * ch * 4), *c2 = malloc(cw * ch * 4), *c3 = malloc(cw * ch * 4);
        for (int y = 0; y < ch; y++) memcpy(cpx + 4 * y * cw, px + 4 * ((y + 30) * W + 40), 4 * cw);
        id<MTLTexture> alone = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, cw, ch, 0, 0, cw, ch, cpx, 1);
        id<MTLTexture> in1 = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, W, H, cx, cy, cw, ch, cpx, 11), in2 = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, W, H, cx, cy, cw, ch, cpx, 12);
        int crop[4] = {cx, cy, cw, ch};
        mtl_present_layer(cw, ch);
        capture(alone, whole, cw, ch, c1);
        EXPECT("crop: through edge smoothing", PRESENT_STANDARD | PRESENT_AA, capture(in1, crop, cw, ch, c2));
        capture(in2, crop, cw, ch, c3);
        int moved = 0; for (int i = 0; i < cw * ch; i++) moved += memcmp(c1 + 4 * i, cpx + 4 * i, 4) != 0;
        CHECK("crop: the crop alone is smoothed", moved > 200);
        EXPECT("crop: byte-identical to the crop alone (nothing read from around it)", 0, memcmp(c1, c2, cw * ch * 4));
        EXPECT("crop: byte-identical with other texels around it", 0, memcmp(c2, c3, cw * ch * 4));
        // The live present too, its crop moving inside one texture: one allocation, the window texture's size
        uint8_t *l = malloc(cw * ch * 4);
        EXPECT("live crop: through edge smoothing", PRESENT_STANDARD | PRESENT_AA, live(in1, crop, cw, ch, l));
        EXPECT("live crop: byte-identical to the capture (screenshots show what the screen does)", 0, memcmp(l, c2, cw * ch * 4));
        id<MTLTexture> made = g_aa_present.tex; int crop2[4] = {cx + 2, cy + 1, cw - 9, ch - 5};
        mtl_present_layer(cw - 9, ch - 5); live(in1, crop2, cw - 9, ch - 5, l);
        CHECK("live crop: a moved crop keeps the texture", g_aa_present.tex == made);
        EXPECT("live crop: the window texture's size", W, (int)g_aa_present.tex.width);
        free(cpx); free(c1); free(c2); free(c3); free(l); res_remove(alone); res_remove(in1); res_remove(in2);
        mtl_present_layer(W, H);
    }

    // An RGBA8 swapchain is smoothed as stored, an sRGB one in linear light: on black and white, the sRGB result is the RGBA8 one encoded
    {
        uint8_t *bw = malloc(W * H * 4), *ru = malloc(W * H * 4), *rs = malloc(W * H * 4);
        for (int i = 0; i < W * H; i++) { uint8_t v = px[4 * i] > 128 ? 255 : 0; bw[4 * i] = bw[4 * i + 1] = bw[4 * i + 2] = v; bw[4 * i + 3] = 255; }
        id<MTLTexture> bu = src_tex(MTLPixelFormatRGBA8Unorm, W, H, 0, 0, W, H, bw, 1), bs = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, W, H, 0, 0, W, H, bw, 1);
        EXPECT("RGBA8: through edge smoothing", PRESENT_STANDARD | PRESENT_AA, capture(bu, whole, W, H, ru));
        capture(bs, whole, W, H, rs);
        int both = 0, brighter = 0, darker = 0, far = 0;
        for (int i = 0; i < W * H; i++) {
            if (ru[4 * i] == bw[4 * i] && rs[4 * i] == bw[4 * i]) continue;
            both++; brighter += rs[4 * i] > ru[4 * i]; darker += rs[4 * i] < ru[4 * i];
            if (ru[4 * i] >= 64 && fabs(rs[4 * i] - 255 * srgb_enc(ru[4 * i] / 255.0)) > 3) far++;
        }
        printf("  black and white: %d pixels smoothed, the sRGB swapchain's brighter at %d, darker at %d\n", both, brighter, darker);
        CHECK("sRGB and RGBA8: pixels smoothed", both > 100);
        EXPECT("sRGB: never darker than RGBA8's blend (linear light)", 0, darker);
        CHECK("sRGB: brighter where blended", brighter * 2 > both);
        EXPECT("sRGB: the RGBA8 blend encoded, within 3/255", 0, far);
        free(bw); free(ru); free(rs); res_remove(bu); res_remove(bs);
    }

    // A flat picture finds nothing: no candidates, no blend items, the bytes as they were
    {
        uint8_t *fl = malloc(W * H * 4); for (int i = 0; i < W * H; i++) { fl[4 * i] = 40; fl[4 * i + 1] = 200; fl[4 * i + 2] = 90; fl[4 * i + 3] = 255; }
        id<MTLTexture> ft = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, W, H, 0, 0, W, H, fl, 1);
        EXPECT("flat: through edge smoothing", PRESENT_STANDARD | PRESENT_AA, capture(ft, whole, W, H, a));
        EXPECT("flat: no shape candidates", 0, atomic_load(&g_aa_seen[0])); EXPECT("flat: no blend items", 0, atomic_load(&g_aa_seen[1]));
        EXPECT("flat: byte-identical", 0, memcmp(a, fl, W * H * 4));
        free(fl); res_remove(ft);
    }

    // The lists' clamps: capacities of 64 overflow on the scene; the run completes (MTL_DEBUG_LAYER and shader validation in the check target), says so, and touches only edges
    {
        const uint32_t caps[2][3] = {{64, 1 << 20, 16}, {1 << 20, 48, 1 << 20}};   // candidates and locations short, then blend items (locations follow the items stored)
        for (int c = 0; c < 2; c++) {
            memcpy(g_aa_test_cap, caps[c], sizeof g_aa_test_cap);
            EXPECT("clamp: through edge smoothing", PRESENT_STANDARD | PRESENT_AA, capture(s8, whole, W, H, a));
            printf("  clamped at %u / %u / %u: %u candidates, %u blend items, %u locations wanted, overflow bits %#x\n", caps[c][0], caps[c][1], caps[c][2],
                   atomic_load(&g_aa_seen[0]), atomic_load(&g_aa_seen[1]), atomic_load(&g_aa_seen[2]), atomic_load(&g_aa_seen[3]));
            EXPECT(c ? "clamp: the blend items ran past their capacity" : "clamp: the candidates and locations ran past theirs", c ? 2 : 5, atomic_load(&g_aa_seen[3]));
            int flat_moved = 0, moved = 0;
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { int d = memcmp(a + 4 * (y * W + x), px + 4 * (y * W + x), 4) != 0; moved += d; flat_moved += d && flat(px, W, H, x, y); }
            EXPECT("clamp: no pixel without an edge changed", 0, flat_moved);
            CHECK("clamp: fewer pixels smoothed than unclamped", moved < changed_edge);
        }
        memset(g_aa_test_cap, 0, sizeof g_aa_test_cap);
        capture(s8, whole, W, H, a); EXPECT("unclamped: no overflow", 0, atomic_load(&g_aa_seen[3]));
        EXPECT("unclamped: the same picture as before", 0, memcmp(a, b, W * H * 4));
        // The threadgroup store of Z shapes' blend items made small, so shapes that do not fit are blended in place (BlendZs) and the slots they reserved before its end are
        // marked empty: the same blend items reach the lists as with the whole store, and the picture differs only by the order of a pixel's items in its list. The store is
        // filled with a stray item first (this GPU's threadgroup memory may happen to read 0, which decodes to a pixel outside the crop): a slot read before anything wrote
        // it adds that item
        uint32_t items = atomic_load(&g_aa_seen[1]);
        EXPECT("whole store: every Z shape's blend items fit it", 0, atomic_load(&g_aa_seen[4]));
        g_aa_test_stray = 1;
        capture(s8, whole, W, H, a); EXPECT("whole store, stray items around: the same blend items", items, atomic_load(&g_aa_seen[1]));
        EXPECT("  the same picture", 0, memcmp(a, b, W * H * 4));
        for (uint32_t slm = 0; slm <= 40; slm += 20) {
            g_aa_test_slm = slm ? slm : 1;
            EXPECT("small store: through edge smoothing", PRESENT_STANDARD | PRESENT_AA, capture(s8, whole, W, H, a));
            int flat_moved = 0, far = 0, moved = 0;
            for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
                const uint8_t *p = a + 4 * (y * W + x), *q = b + 4 * (y * W + x); int d = memcmp(p, px + 4 * (y * W + x), 4) != 0; moved += d; flat_moved += d && flat(px, W, H, x, y);
                for (int c = 0; c < 4; c++) far += abs(p[c] - q[c]) > 1;
            }
            printf("  a store of %u blend items: %u Z shapes blended in place, %u blend items (whole store %u), %d pixels changed, %d channels more than 1/255 from the whole store's\n",
                   g_aa_test_slm, atomic_load(&g_aa_seen[4]), atomic_load(&g_aa_seen[1]), items, moved, far);
            CHECK("small store: Z shapes blended in place", atomic_load(&g_aa_seen[4]) > 0);
            EXPECT("small store: the same blend items as the whole store", items, atomic_load(&g_aa_seen[1]));
            EXPECT("small store: no pixel without an edge changed", 0, flat_moved);
            EXPECT("small store: the whole store's picture within 1/255", 0, far);
        }
        g_aa_test_slm = g_aa_test_stray = 0;
    }

    // Not an 8-bit format: shown without edge smoothing, said once
    {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:W height:H mipmapped:NO]; d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> ft = [g_dev newTextureWithDescriptor:d]; __fp16 *h = malloc(W * H * 8); for (int i = 0; i < W * H * 4; i++) h[i] = px[i] / 255.0f;
        [ft replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:h bytesPerRow:W * 8]; res_add(ft); res_commit();
        int was = mtl_present_aa_why();
        EXPECT("RGBA16Float: no edge smoothing", PRESENT_STANDARD, capture(ft, whole, W, H, a));
        EXPECT("  the warning said", 1, g_red_once[165] > 0);
        EXPECT("  a capture leaves the in-game menu's note", was, mtl_present_aa_why());
        live(ft, whole, W, H, a);
        EXPECT("  the live present's note: a format it does not handle", DM_AA_FORMAT, mtl_present_aa_why());
        free(h); res_remove(ft);
    }

    // MetalFX takes the smoothed texture as its input: the same picture as MetalFX of the smoothed crop handed to it as a plain source (whole texture, and a crop inside one)
    if ([MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) {
        atomic_store(&g_fx_mode, UP_METALFX);
        const int crops[2][4] = {{0, 0, W, H}, {9, 5, 181, 133}};
        for (int c = 0; c < 2; c++) {
            const int *cr = crops[c]; int cw = cr[2], ch = cr[3], ow = cw * 2, oh = ch * 2;
            uint8_t *sm = malloc(cw * ch * 4), *x = malloc(ow * oh * 4), *y = malloc(ow * oh * 4), *cpx = malloc(cw * ch * 4);
            for (int r = 0; r < ch; r++) memcpy(cpx + 4 * r * cw, px + 4 * ((r + cr[1]) * W + cr[0]), 4 * cw);
            mtl_present_layer(cw, ch);
            atomic_store(&g_fx_mode, UP_OFF); capture(s8, cr, cw, ch, sm); atomic_store(&g_fx_mode, UP_METALFX);   // the smoothed crop, 1:1
            EXPECT("MetalFX: after edge smoothing", PRESENT_METALFX | PRESENT_AA, capture(s8, cr, ow, oh, x));
            atomic_store(&g_aa_mode, AA_OFF);
            id<MTLTexture> ref = src_tex(MTLPixelFormatRGBA8Unorm_sRGB, W, H, cr[0], cr[1], cw, ch, sm, 5);
            EXPECT("MetalFX: the reference without", PRESENT_METALFX, capture(ref, cr, ow, oh, y));
            atomic_store(&g_aa_mode, AA_EDGE);
            EXPECT(c ? "MetalFX of a crop: byte-identical to MetalFX of the smoothed crop (the padding past it smoothed too)" : "MetalFX: byte-identical to MetalFX of the smoothed picture", 0, memcmp(x, y, ow * oh * 4));
            free(sm); free(x); free(y); free(cpx); res_remove(ref);
        }
        // The live present: its scaler reads the smoothed texture, and makes no input texture of its own
        int cw = 181, ch = 133; const int cr[4] = {9, 5, cw, ch}; uint8_t *x = malloc(cw * ch * 16);
        mtl_present_layer(cw, ch); g_present_n += FX_REMAKE_PRESENTS;
        EXPECT("live MetalFX: after edge smoothing", PRESENT_METALFX | PRESENT_AA, live(s8, cr, cw * 2, ch * 2, x));
        CHECK("live MetalFX: no input texture of the scaler's own", g_fx_present.in == nil);
        atomic_store(&g_aa_mode, AA_OFF); g_present_n++;
        EXPECT("live MetalFX: off", PRESENT_METALFX, live(s8, cr, cw * 2, ch * 2, x));
        CHECK("live MetalFX: then its own input texture", g_fx_present.in != nil);
        atomic_store(&g_aa_mode, AA_EDGE); atomic_store(&g_fx_mode, UP_OFF); free(x); mtl_present_layer(W, H);
    } else printf("  (no Metal 4 MetalFX spatial scaler on this GPU: the MetalFX checks are skipped)\n");

    // The in-game menu's pick: a capture leaves it, the live present takes it at its next present; a value that is no choice is ignored
    {
        atomic_store(&g_aa_mode, AA_OFF);
        mtl_present_aa_set("edge-sharp");
        EXPECT("menu: a capture leaves the pick", PRESENT_STANDARD, capture(s8, whole, W, H, a)); EXPECT("  still waiting", AA_EDGE_SHARP, atomic_load(&g_aa_req));
        EXPECT("menu: the live present takes it", PRESENT_STANDARD | PRESENT_AA, live(s8, whole, W, H, a));
        EXPECT("  taken", -1, atomic_load(&g_aa_req)); EXPECT("  edge-sharp in force", AA_EDGE_SHARP, atomic_load(&g_aa_mode));
        mtl_present_aa_set("Edge smoothing"); EXPECT("menu: a label is no choice", -1, atomic_load(&g_aa_req));
        mtl_present_aa_set("ab"); EXPECT("menu: ab is the environment's only", -1, atomic_load(&g_aa_req));
        mtl_present_aa_set("off"); EXPECT("menu: off again", PRESENT_STANDARD, live(s8, whole, W, H, a));
        EXPECT("  the note follows", DM_AA_OFF, mtl_present_aa_why());
        EXPECT("  byte-identical to the source", 0, memcmp(a, px, W * H * 4));
    }

    // DM_POST_AA from the environment, the profile's post_aa without it, and ab with the DM_AB phases
    {
        unsetenv("DM_POST_AA"); atomic_store(&g_aa_mode, -1); EXPECT("unset: the profile's post_aa (off for every profile)", aa_parse(DM_GAME_POST_AA), aa_mode(1));
        setenv("DM_POST_AA", "edge", 1); atomic_store(&g_aa_mode, -1); EXPECT("DM_POST_AA=edge", AA_EDGE, aa_mode(1));
        setenv("DM_POST_AA", "bogus", 1); atomic_store(&g_aa_mode, -1); EXPECT("DM_POST_AA=bogus: the profile's", aa_parse(DM_GAME_POST_AA), aa_mode(1));
        long len = g_ab_len; g_ab_len = 0;
        setenv("DM_POST_AA", "ab", 1); atomic_store(&g_aa_mode, -1); EXPECT("DM_POST_AA=ab without DM_AB: off", AA_OFF, aa_mode(1)); EXPECT("  kept off", AA_OFF, atomic_load(&g_aa_mode));
        g_ab_len = 4; atomic_store(&g_aa_mode, -1); atomic_store(&g_ab_phase, 0);
        EXPECT("DM_POST_AA=ab, phase 0: off", AA_OFF, aa_mode(1)); EXPECT("  the mode in force is ab", AA_AB, atomic_load(&g_aa_mode));
        atomic_store(&g_ab_phase, 1); EXPECT("DM_POST_AA=ab, phase 1: edge", AA_EDGE, aa_mode(1));
        EXPECT("  a capture follows the phase too", PRESENT_STANDARD | PRESENT_AA, capture(s8, whole, W, H, a));
        atomic_store(&g_ab_phase, 2); EXPECT("DM_POST_AA=ab, phase 2: off", AA_OFF, aa_mode(1));
        g_ab_len = len; atomic_store(&g_ab_phase, 0); unsetenv("DM_POST_AA"); atomic_store(&g_aa_mode, AA_OFF);
    }
    res_remove(s8); res_remove(u8); free(px); free(hud); free(off); free(a); free(b);
    printf("== %d checks, %d failed ==\n", cases, failed); return failed != 0;
} }
