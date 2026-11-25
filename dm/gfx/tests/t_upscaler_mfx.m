// A game's upscaler drawn by MetalFX (DM_UPSCALER=metalfx; nvn_mtl.m up_mfx_encode), or by a bilinear stretch (DM_NVN_UP_BILINEAR=1, profile key upscaler_bilinear; at the end): one of the game's upscaler shaders reading a 960x540 texture and writing a
// 1920x1080 image is replaced by the spatial scaler, which fills the whole image with the texture's colour; equal sizes, another shader, and DM_UPSCALER unset
// (the last run) leave the dispatch to the shader. Runs under any profile: the named shader is the profile's first upscaler (DM_GAME_UPSCALER_KEYS), and a profile with
// none swaps no shader; the MetalFX draw itself (up_mfx_encode) does not look at the key. The colour (up_mfx_color) comes from synthetic code holding the curves' constants: a variant with sRGB input
// comes out decoded to linear, one whose code squares its result keeping the sign (square-rooted input) comes out squared, through the scaler's own input even where the game's texture could
// go straight, and one whose output stays encoded, or whose code says nothing of its colour, is left to its shader. The scaler comes after the work before it and the next draw pass after the scaler
// (mfx_order, upstream NXNative b25b651b): a slow pass that ends with no barrier writes the input just before each dispatch, and a draw pass copies the image just after it
// (the Makefile's DM_NVN_BARRIER=game run makes that pass skip its consumer barrier unless the scaler cleared the relaxed end)
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
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static void fill(id<MTLTexture> t, MTLClearColor c) {
    T4 *cb = t4_begin(); MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = c;
    t4_end(cb, t4_pass(cb, rp)); t4_wait(cb);
}
static int matches(id<MTLTexture> t, const float inside[4], MTLRegion region, const float outside[4]) {   // allow HDR scaler rounding on each channel
    NSUInteger n = t.width * t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:n * 8 options:MTLResourceStorageModeShared];
    if (!b) { fprintf(stderr, "readback buffer did not allocate\n"); return 0; }
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb);
    t4_use(cb, t), t4_use(cb, b), [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 8 destinationBytesPerImage:n * 8];
    t4_end(cb, e); t4_wait(cb);
    const __fp16 *p = b.contents;
    for (NSUInteger i = 0; i < n; i++) {
        NSUInteger x = i % t.width, y = i / t.width;
        const float *want = x >= region.origin.x && x < region.origin.x + region.size.width &&
                            y >= region.origin.y && y < region.origin.y + region.size.height ? inside : outside;
        for (int c = 0; c < 4; c++) if (!(fabsf((float)p[4*i+c] - want[c]) <= fmaxf(0.01f, 0.03f * fabsf(want[c])))) {
            fprintf(stderr, "texel %lu,%lu channel %d: %g, expected %g\n", (unsigned long)x, (unsigned long)y, c, (float)p[4*i+c], want[c]);
            return 0;
        }
    }
    return 1;
}
// Every texel of an R11G11B10F texture holds rgb (HDR scaler rounding on each channel), and their mean is within 1.5 % (or 0.005): MetalFX's own R11G11B10F writes come out about 3 % low
static float r11_unpack(uint32_t v, int mb) { uint32_t e = v >> mb, m = v & ((1u << mb) - 1); return e ? ldexpf(1 + m / (float)(1u << mb), (int)e - 15) : ldexpf(m / (float)(1u << mb), -14); }
static int matches_r11(id<MTLTexture> t, const float rgb[3]) {
    NSUInteger n = t.width * t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:n * 4 options:MTLResourceStorageModeShared];
    if (!b) { fprintf(stderr, "readback buffer did not allocate\n"); return 0; }
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb);
    t4_use(cb, t), t4_use(cb, b), [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 4 destinationBytesPerImage:n * 4];
    t4_end(cb, e); t4_wait(cb);
    const uint32_t *p = b.contents; double sum[3] = {0};
    for (NSUInteger i = 0; i < n; i++) {
        float c[3] = {r11_unpack(p[i] & 0x7ff, 6), r11_unpack(p[i] >> 11 & 0x7ff, 6), r11_unpack(p[i] >> 22, 5)};
        for (int k = 0; k < 3; k++) sum[k] += c[k];
        for (int k = 0; k < 3; k++) if (!(fabsf(c[k] - rgb[k]) <= fmaxf(0.01f, 0.03f * fabsf(rgb[k])))) {
            fprintf(stderr, "texel %lu,%lu channel %d: %g, expected %g\n", (unsigned long)(i % t.width), (unsigned long)(i / t.width), k, c[k], rgb[k]);
            return 0;
        }
    }
    for (int k = 0; k < 3; k++) if (!(fabs(sum[k] / n - rgb[k]) <= fmax(0.005, 0.015 * fabs(rgb[k])))) { fprintf(stderr, "channel %d: mean %g, expected %g\n", k, sum[k] / n, rgb[k]); return 0; }
    return 1;
}
// Code holding each constant 12 times, among others: the shape of a real variant's curves
static int color_of(const float *f32, int n32, const float *f16, int n16) {
    uint8_t code[4096]; size_t o = 0;
    for (int i = 0; i < (int)sizeof code; i++) code[i] = (uint8_t)(i * 37 + 11);
    for (int r = 0; r < 12; r++) {
        for (int i = 0; i < n32; i++) { memcpy(code + o, &f32[i], 4); o += 16; }
        for (int i = 0; i < n16; i++) { __fp16 h = f16[i]; memcpy(code + o, &h, 2); o += 16; }
    }
    return up_mfx_color(code, sizeof code);
}
// Code whose 16-byte instructions are zero but for n FMUL (0x220) or HMUL2 (0x232) of a register by itself, |x| on the sides asked (abs_a: Ra, bit 73; abs_b: Rb, bit 62), at index 8 + 3 * i;
// reg 0xff is RZ; hswz: HMUL2's B lanes (bits 60..61), A's left at 0. Then the extra instructions, from index 1, and each f32 constant of f32[] 12 times from the end
static int color_of_squares(unsigned op, int abs_a, int abs_b, int n, unsigned reg, unsigned hswz, const uint64_t (*extra)[2], int nextra, const float *f32, int n32) {
    uint8_t code[8192] = {0};
    for (int i = 0; i < n; i++) {
        unsigned r = reg == 0xff ? 0xff : (unsigned)(reg + i);
        uint64_t lo = op | (uint64_t)r << 24 | (uint64_t)r << 32 | (uint64_t)abs_b << 62 | (uint64_t)hswz << 60, hi = (uint64_t)abs_a << 9;
        memcpy(code + 16 * (8 + 3 * i), &lo, 8); memcpy(code + 16 * (8 + 3 * i) + 8, &hi, 8);
    }
    for (int i = 0; i < nextra; i++) { memcpy(code + 16 * (1 + i), &extra[i][0], 8); memcpy(code + 16 * (1 + i) + 8, &extra[i][1], 8); }
    for (int r = 0, o = (int)sizeof code - 16; r < 12; r++) for (int i = 0; i < n32; i++, o -= 16) memcpy(code + o, &f32[i], 4);
    return up_mfx_color(code, sizeof code);
}
// A pattern in the w x h rectangle at the origin of t (RGBA16F), magenta past it, through a shared buffer: what each texel holds depends on its place, so a scaled picture shows where it read
static void pattern(id<MTLTexture> t, NSUInteger w, NSUInteger h) {
    NSUInteger tw = t.width, th = t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:tw * th * 8 options:MTLResourceStorageModeShared];
    __fp16 *p = b.contents;
    for (NSUInteger y = 0; y < th; y++) for (NSUInteger x = 0; x < tw; x++) { __fp16 *q = p + 4 * (y * tw + x);
        if (x < w && y < h) { q[0] = (__fp16)(0.5f + 0.5f * sinf(x * 0.05f) * cosf(y * 0.07f)); q[1] = (__fp16)(((x ^ y) & 16) ? 0.9f : 0.1f); q[2] = (__fp16)((float)x / w); q[3] = 1; }
        else { q[0] = 1; q[1] = 0; q[2] = 1; q[3] = 1; } }
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, b); t4_use(cb, t);
    [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:tw * 8 sourceBytesPerImage:tw * th * 8 sourceSize:MTLSizeMake(tw, th, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    t4_end(cb, e); t4_wait(cb);
}
static id<MTLBuffer> read16(id<MTLTexture> t) {   // an RGBA16F texture's texels
    NSUInteger n = t.width * t.height; id<MTLBuffer> b = [g_dev newBufferWithLength:n * 8 options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, t); t4_use(cb, b);
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:t.width * 8 destinationBytesPerImage:n * 8];
    t4_end(cb, e); t4_wait(cb); return b;
}
// MetalFX's own scale (HDR, RGBA16F) of the w x h pattern into ow x oh, by a scaler made for exactly that input: what the game's upscaler drawn by MetalFX must match
static id<MTLBuffer> reference(NSUInteger w, NSUInteger h, NSUInteger ow, NSUInteger oh) {
    MTLFXSpatialScalerDescriptor *d = [MTLFXSpatialScalerDescriptor new];
    d.colorTextureFormat = d.outputTextureFormat = MTLPixelFormatRGBA16Float; d.inputWidth = w; d.inputHeight = h; d.outputWidth = ow; d.outputHeight = oh;
    d.colorProcessingMode = MTLFXSpatialScalerColorProcessingModeHDR;
    id<MTL4FXSpatialScaler> sc = [d newSpatialScalerWithDevice:g_dev compiler:mtl_comp4()];
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:w height:h mipmapped:NO]; td.storageMode = MTLStorageModePrivate; td.usage = sc.colorTextureUsage | MTLTextureUsageShaderRead;
    id<MTLTexture> in = [g_dev newTextureWithDescriptor:td]; pattern(in, w, h);
    td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float width:ow height:oh mipmapped:NO]; td.storageMode = MTLStorageModePrivate; td.usage = sc.outputTextureUsage | MTLTextureUsageShaderRead;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:td];
    T4 *cb = t4_begin(); t4_use(cb, in); t4_use(cb, out);
    sc.colorTexture = in; sc.outputTexture = out; sc.inputContentWidth = w; sc.inputContentHeight = h; [sc encodeToCommandBuffer:cb->o->cb];
    t4_wait(cb); return read16(out);
}
static NvShader *upscaler(const char *key) {
    NvShader *s = [NvShader new]; snprintf(s->key, sizeof s->key, "%s", key); s->up_color = UP_COLOR_LINEAR;
    s->rf.nb = 2; s->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 0};
    s->rf.b[1] = (nvn_rbind){.kind = NVN_RB_IMG, .dtt = MTLTextureType2D, .dpf = NVN_DPF_FLOAT, .reg = 1, .rw = 1};
    return s;
}
int main(void) { @autoreleasepool {
    mtl_init();
    const float enc[2] = {0.0031308f, 1 / 2.4f}, dec[2] = {0.04045f, 2.4f}, both[4] = {0.0031308f, 1 / 2.4f, 0.04045f, 2.4f}, dec16[3] = {0.040435791015625f, 2.3984375f, 0.07745361328125f}, enc16[1] = {0.41650390625f};
    float once[1] = {2.4f}; uint8_t rare[256] = {0}; memcpy(rare, once, 4);
    CHECK(color_of(both, 4, NULL, 0) == UP_COLOR_LINEAR, "an encode and a decode in floats: linear input and output (Bananza)");
    CHECK(color_of(NULL, 0, dec16, 3) == UP_COLOR_SRGB, "only a decode, in half floats: sRGB input, linear output (Splatoon Raiders)");
    CHECK(color_of(enc, 2, NULL, 0) == UP_COLOR_KEEP, "an encode with no decode: the output stays encoded, the shader runs");
    CHECK(color_of(NULL, 0, NULL, 0) == UP_COLOR_KEEP, "no curve: the output stays encoded, the shader runs");
    CHECK(color_of(dec, 2, NULL, 0) == UP_COLOR_KEEP, "a shape no pack has shown (a decode in floats, no encode): the shader runs");
    CHECK(color_of(NULL, 0, (const float[4]){0.040435791015625f, 2.3984375f, 0.07745361328125f, enc16[0]}, 4) == UP_COLOR_KEEP, "a half float encode must not read as encoded input: the shader runs");
    CHECK(up_mfx_color(rare, sizeof rare) == UP_COLOR_KEEP, "a constant used once is chance, not a curve");
    // Square-rooted input, linear output (Ocarina of Time's agl_ndsr_vr.pck FMUL, agl_ndsr_vr_light.pck HMUL2): x * |x| from 8 times, no power, no constant of a curve
    const uint64_t ex2[1][2] = {{0x308, 2ull << 10}}, lg2[1][2] = {{0x308, 3ull << 10}}, sqrt_[1][2] = {{0x308, 8ull << 10}}, rcp[1][2] = {{0x308, 4ull << 10}};
    const float k1292[1] = {12.92f};
    CHECK(color_of_squares(0x220, 0, 1, 8, 10, 0, NULL, 0, NULL, 0) == UP_COLOR_ROOT, "FMUL x, |x| 8 times: square-rooted input, linear output");
    CHECK(color_of_squares(0x232, 1, 0, 32, 10, 0, NULL, 0, NULL, 0) == UP_COLOR_ROOT, "HMUL2 |x|, x on the same lanes: square-rooted input, linear output");
    CHECK(color_of_squares(0x220, 0, 1, 8, 10, 0, rcp, 1, NULL, 0) == UP_COLOR_ROOT, "a MUFU that is no power (RCP) beside the squares does not count");
    CHECK(color_of_squares(0x220, 0, 0, 8, 10, 0, NULL, 0, NULL, 0) == UP_COLOR_KEEP, "x * x keeps no sign: not the square-rooted shape, the shader runs");
    CHECK(color_of_squares(0x220, 1, 1, 8, 10, 0, NULL, 0, NULL, 0) == UP_COLOR_KEEP, "|x| * |x| keeps no sign: the shader runs");
    CHECK(color_of_squares(0x220, 0, 1, 7, 10, 0, NULL, 0, NULL, 0) == UP_COLOR_KEEP, "7 squares are chance: the shader runs");
    CHECK(color_of_squares(0x220, 0, 1, 8, 0xff, 0, NULL, 0, NULL, 0) == UP_COLOR_KEEP, "RZ * |RZ| is no square: the shader runs");
    CHECK(color_of_squares(0x232, 0, 1, 8, 10, 1, NULL, 0, NULL, 0) == UP_COLOR_KEEP, "HMUL2 of a register's two different lanes is no square: the shader runs");
    CHECK(color_of_squares(0x220, 0, 1, 8, 10, 0, ex2, 1, NULL, 0) == UP_COLOR_KEEP && color_of_squares(0x220, 0, 1, 8, 10, 0, lg2, 1, NULL, 0) == UP_COLOR_KEEP,
          "squares beside a power (MUFU.EX2 / LG2): a curve may follow them, the shader runs");
    CHECK(color_of_squares(0x220, 0, 1, 8, 10, 0, NULL, 0, k1292, 1) == UP_COLOR_KEEP, "squares beside a curve's constant alone (12.92 in floats): the shader runs");
    CHECK(color_of_squares(0x220, 0, 1, 8, 10, 0, ex2, 1, enc, 2) == UP_COLOR_KEEP, "squares, then an encode (Ocarina of Time's 12 encoding variants): the output stays encoded, the shader runs");
    CHECK(color_of_squares(0x220, 0, 0, 0, 10, 0, sqrt_, 1, NULL, 0) == UP_COLOR_KEEP, "no curve and no square (a pre-pass that square-roots): nothing says its colour, the shader runs");
    const char *up = getenv("DM_UPSCALER"); int on = up && !strcmp(up, "metalfx");
    setenv("DM_NVN_UP_BILINEAR", "0", 1); atomic_fetch_add(&g_cur_frame, 1);   // MetalFX itself first, whatever the profile's upscaler_bilinear (the stretch is checked at the end)
    tex_t in = texture(77, 960, 540, NVN_FORMAT_RGBA16F), out = texture(78, 1920, 1080, NVN_FORMAT_RGBA16F), same = texture(79, 960, 540, NVN_FORMAT_RGBA16F);
    out.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; same.d.flags |= NVN_TEXTURE_FLAGS_IMAGE;
    mtl_tex_init(&in); mtl_tex_init(&out); mtl_tex_init(&same);
    mtl_reg_tex(701, &in, NULL); mtl_reg_image(702, &out, NULL); mtl_reg_image(703, &same, NULL);
    const float colour[4] = {0.5f, 0.25f, 0.75f, 1.0f}, black[4] = {0, 0, 0, 1};
    fill(tex_mtl(&in), MTLClearColorMake(colour[0], colour[1], colour[2], colour[3])); fill(tex_mtl(&out), MTLClearColorMake(0, 0, 0, 1));
    char key[24] = "7629d857a0a93833_b"; if (DM_GAME_UPSCALER_N) snprintf(key, sizeof key, "%.16s_b", DM_GAME_UPSCALER_KEYS);   // the profile's first upscaler, else Bananza's (not named here)
    NvShader *named = upscaler(key), *other = upscaler("0123456789abcdef_b");
    CHECK(up_mfx_wanted(named) == (on && DM_GAME_UPSCALER_N), "a shader the profile names is swapped exactly when DM_UPSCALER=metalfx (none in a profile without upscalers)");
    CHECK(!up_mfx_wanted(other), "a shader the profile does not name is never swapped");
    memset(&S, 0, sizeof S); S.tex[5][0] = 701; S.img[5][1] = 702;
    { const uint32_t rects[8] = {0, 0, 959, 539, 0, 0, 1919, 1079}; memcpy(S.push[1], rects, sizeof rects); }   // c[24]: input and output rectangles (origin, inclusive last texel)
    mtl_sub_begin(); int drawn = on && up_mfx_encode(named);
    CHECK(drawn == on, "the named shader's dispatch is drawn by MetalFX");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission completes");
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> written = tex_by_id(702); os_unfair_lock_unlock(&g_rmu);
    CHECK(matches(written, on ? colour : black, MTLRegionMake2D(0, 0, 1920, 1080), black), on ? "MetalFX filled the whole 1920x1080 image with the texture's colour" : "without the switch the image is untouched");
    if (on) {
        // Passes around the scaler (see the top): each round a new colour, the last one the texture's colour again for the checks below
        tex_t cp = texture(82, 1920, 1080, NVN_FORMAT_RGBA16F); mtl_tex_init(&cp);
        const float rc[2][4] = {{0.125f, 0.625f, 0.25f, 1.0f}, {colour[0], colour[1], colour[2], colour[3]}}; int pdrawn = 0, stale_in = 0, stale_out = 0;
        for (int round = 0; round < 8; round++) {
            mtl_sub_begin(); pdrawn += slow_draw(tex_mtl(&in), rc[round & 1], 200000, 1); pdrawn += up_mfx_encode(named); pdrawn += copy_draw(written, tex_mtl(&cp));
            CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the submission with passes around the scaler completes");
            stale_in += !matches(written, rc[round & 1], MTLRegionMake2D(0, 0, 1920, 1080), black); stale_out += !matches(tex_mtl(&cp), rc[round & 1], MTLRegionMake2D(0, 0, 1920, 1080), black);
        }
        CHECK(pdrawn == 24, "the passes around the scaler are drawn and MetalFX draws each dispatch");
        CHECK(!stale_in, "the scaler reads the input the pass just before it wrote, in every round");
        CHECK(!stale_out, "the pass after the scaler reads its output, in every round");
        tex_t packed = texture(80, 976, 548, NVN_FORMAT_R11G11B10F);
        mtl_tex_init(&packed); mtl_reg_tex(704, &packed, NULL);
        const float hdr[4] = {2.0f, 0.5f, 0.25f, 1.0f};
        fill(tex_mtl(&packed), MTLClearColorMake(hdr[0], hdr[1], hdr[2], hdr[3]));
        fill(written, MTLClearColorMake(0, 0, 0, 1));
        const uint32_t crop[8] = {7, 3, 959, 539, 13, 9, 1899, 1059};
        memcpy(S.push[1], crop, sizeof crop);
        S.tex[5][0] = 704;
        mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes the packed HDR subrectangle");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the converted submission completes");
        CHECK(matches(written, hdr, MTLRegionMake2D(13, 9, 1900, 1060), black), "the HDR output fills only its destination rectangle");
        tex_t packed_out = texture(81, 1920, 1080, NVN_FORMAT_R11G11B10F);
        packed_out.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; mtl_tex_init(&packed_out);
        view_t view = {.set_swizzle = 1, .swz = {MTLTextureSwizzleRed, MTLTextureSwizzleGreen, MTLTextureSwizzleBlue, MTLTextureSwizzleOne}};
        mtl_reg_image(705, &packed_out, &view);
        S.img[5][1] = 705;
        id<MTLTexture> backing = tex_mtl(&packed_out);
        uint64_t upgrades = g_pfv_upgrades;
        for (int frame = 0; frame < 32; frame++) {
            mtl_sub_begin();
            CHECK(up_mfx_encode(named), "MetalFX writes the image behind a swizzled sampled view");
            CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "packed output submission completes");
        }
        CHECK(tex_mtl(&packed_out) == backing && g_pfv_upgrades == upgrades, "repeated scales reuse the original image backing");
        // sRGB input and linear output (Splatoon Raiders): the same sizes as above, so a scaler of their own, and the image holds the colour decoded
        S.img[5][1] = 702; S.tex[5][0] = 701; { const uint32_t rects[8] = {0, 0, 959, 539, 0, 0, 1919, 1079}; memcpy(S.push[1], rects, sizeof rects); }
        named->up_color = UP_COLOR_SRGB;
        const float decoded[4] = {0.2140f, 0.0509f, 0.5225f, 1.0f};   // sRGB 0.5, 0.25, 0.75
        fill(written, MTLClearColorMake(0, 0, 0, 1)); mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes sRGB-encoded input");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the sRGB submission completes");
        CHECK(matches(written, decoded, MTLRegionMake2D(0, 0, 1920, 1080), black), "the sRGB input comes out decoded to linear");
        fill(tex_mtl(&packed), MTLClearColorMake(colour[0], colour[1], colour[2], colour[3])); fill(written, MTLClearColorMake(0, 0, 0, 1));
        { const uint32_t r[8] = {7, 3, 959, 539, 13, 9, 1899, 1059}; memcpy(S.push[1], r, sizeof r); } S.tex[5][0] = 704; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes a packed sRGB-encoded subrectangle");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the packed sRGB submission completes");
        CHECK(matches(written, decoded, MTLRegionMake2D(13, 9, 1900, 1060), black), "the packed sRGB input comes out decoded, in its destination rectangle only");
        named->up_color = UP_COLOR_LINEAR;
        fill(tex_mtl(&in), MTLClearColorMake(colour[0], colour[1], colour[2], colour[3])); fill(written, MTLClearColorMake(0, 0, 0, 1));
        { const uint32_t rects[8] = {0, 0, 959, 539, 0, 0, 1919, 1079}; memcpy(S.push[1], rects, sizeof rects); } S.tex[5][0] = 701; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "linear input after sRGB at the same sizes");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the second linear submission completes");
        CHECK(matches(written, colour, MTLRegionMake2D(0, 0, 1920, 1080), black), "the same sizes in linear colour are not decoded: each colour has its own scaler");
        // The input the game's own texture in its own format when the rectangle is the whole texture (DM_NVN_MFX_DIRECT, on by default; =0: only RGBA16F), the output only in RGBA16F:
        // R11G11B10F into R11G11B10F, as Ocarina of Time's (the output drawn back, at full precision); into a whole RGBA16F image (both straight); into an offset rectangle (drawn back)
        int any = !(getenv("DM_NVN_MFX_DIRECT") && !strcmp(getenv("DM_NVN_MFX_DIRECT"), "0"));
        tex_t r11 = texture(83, 960, 540, NVN_FORMAT_R11G11B10F), r11_out = texture(84, 1920, 1080, NVN_FORMAT_R11G11B10F);
        r11_out.d.flags |= NVN_TEXTURE_FLAGS_IMAGE; mtl_tex_init(&r11); mtl_tex_init(&r11_out);
        mtl_reg_tex(706, &r11, NULL); mtl_reg_image(707, &r11_out, NULL);
        fill(tex_mtl(&r11), MTLClearColorMake(hdr[0], hdr[1], hdr[2], 1)); fill(tex_mtl(&r11_out), MTLClearColorMake(0, 0, 0, 1));
        { const uint32_t r[8] = {0, 0, 959, 539, 0, 0, 1919, 1079}; memcpy(S.push[1], r, sizeof r); } S.tex[5][0] = 706; S.img[5][1] = 707;
        uint64_t s_in = g_up_mfx_straight[0], s_out = g_up_mfx_straight[1]; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes R11G11B10F into R11G11B10F");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the R11G11B10F submission completes");
        CHECK(g_up_mfx_straight[0] == s_in + any && g_up_mfx_straight[1] == s_out, any ? "R11G11B10F whole textures: the input the game's own, the output drawn back" : "DM_NVN_MFX_DIRECT=0: R11G11B10F goes through RGBA16F");
        CHECK(matches_r11(tex_mtl(&r11_out), hdr), "the R11G11B10F image holds the HDR colour everywhere, not darkened");
        fill(written, MTLClearColorMake(0, 0, 0, 1)); S.img[5][1] = 702; s_in = g_up_mfx_straight[0]; s_out = g_up_mfx_straight[1]; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes R11G11B10F into RGBA16F");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the mixed-format submission completes");
        CHECK(g_up_mfx_straight[0] == s_in + any && g_up_mfx_straight[1] == s_out + 1, "R11G11B10F into RGBA16F: the output the game's own, the input too with the switch");
        CHECK(matches(written, hdr, MTLRegionMake2D(0, 0, 1920, 1080), black), "the RGBA16F image holds the HDR colour everywhere");
        fill(written, MTLClearColorMake(0, 0, 0, 1)); { const uint32_t r[8] = {0, 0, 959, 539, 13, 9, 1899, 1059}; memcpy(S.push[1], r, sizeof r); }
        s_in = g_up_mfx_straight[0]; s_out = g_up_mfx_straight[1]; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes R11G11B10F into an offset rectangle");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the offset submission completes");
        CHECK(g_up_mfx_straight[0] == s_in + any && g_up_mfx_straight[1] == s_out, "an offset output rectangle is drawn back, the whole input still the game's own");
        CHECK(matches(written, hdr, MTLRegionMake2D(13, 9, 1900, 1060), black), "the offset output fills only its destination rectangle");
        { const uint32_t r[8] = {0, 0, 959, 539, 0, 0, 1919, 1079}; memcpy(S.push[1], r, sizeof r); } S.tex[5][0] = 701;
        // Square-rooted input (Ocarina of Time's networks): the input squared on its copy into the scaler's RGBA16F texture, never straight, even a whole R11G11B10F or RGBA16F texture
        // that linear input sends straight; MetalFX in HDR mode, so the image holds the square as the game's shader writes it: 1, 0.5, 0.25 → 1, 0.25, 0.0625 in R11G11B10F (squares
        // a 5-bit mantissa holds exactly: MetalFX's result a hair low drawn into blue's 5 bits drops a whole step, 0.5625 to 0.546875; and at 4.0 its HDR mode's own curve gives 3.875),
        // 0.5, 0.25, 0.75 → 0.25, 0.0625, 0.5625 in RGBA16F
        named->up_color = UP_COLOR_ROOT;
        const float squared[4] = {0.25f, 0.0625f, 0.5625f, 1.0f}, hdr_squared[3] = {1.0f, 0.25f, 0.0625f};
        fill(tex_mtl(&r11), MTLClearColorMake(1.0, 0.5, 0.25, 1)); fill(tex_mtl(&r11_out), MTLClearColorMake(0, 0, 0, 1));
        S.tex[5][0] = 706; S.img[5][1] = 707; s_in = g_up_mfx_straight[0]; s_out = g_up_mfx_straight[1]; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes square-rooted R11G11B10F input");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the square-rooted R11G11B10F submission completes");
        CHECK(g_up_mfx_straight[0] == s_in && g_up_mfx_straight[1] == s_out, "a square-rooted whole R11G11B10F input goes through the squaring copy, its output drawn back");
        CHECK(matches_r11(tex_mtl(&r11_out), hdr_squared), "the square-rooted R11G11B10F input comes out squared into linear colour");
        fill(written, MTLClearColorMake(0, 0, 0, 1)); S.tex[5][0] = 701; S.img[5][1] = 702; s_in = g_up_mfx_straight[0]; s_out = g_up_mfx_straight[1]; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "MetalFX takes square-rooted RGBA16F input");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the square-rooted RGBA16F submission completes");
        CHECK(g_up_mfx_straight[0] == s_in && g_up_mfx_straight[1] == s_out + 1, "a square-rooted whole RGBA16F input still goes through the squaring copy; the output straight");
        CHECK(matches(written, squared, MTLRegionMake2D(0, 0, 1920, 1080), black), "the square-rooted RGBA16F input comes out squared into linear colour");
        // Dynamic resolution (Ocarina of Time: 854x480 to 1440x810 into 1920x1080, each size a texture of its own): with DM_NVN_MFX_CONTENT (on by default) one scaler for the
        // output takes every input size as its content, where a scaler per input size filled the 4 slots over and over. Each rectangle a pattern, the game's texture 16 texels
        // larger with magenta past it (what MetalFX reads past the content must be the content's edge, up_mfx_pad), and the image byte for byte MetalFX's own scale of the
        // pattern by a scaler made for its size. Then the same sizes again, as the game cycles through them: no scaler more
        { int content = !(getenv("DM_NVN_MFX_CONTENT") && !strcmp(getenv("DM_NVN_MFX_CONTENT"), "0"));
          named->up_color = UP_COLOR_LINEAR; S.img[5][1] = 702;
          const unsigned sz[5][2] = {{1440, 810}, {854, 480}, {1280, 720}, {1366, 768}, {1920, 1000}}; uint64_t made0 = g_up_mfx_made; int same = 0, ran = 0;
          for (int pass = 0; pass < 2; pass++) for (int k = 0; k < 5; k++) {
              unsigned w = sz[k][0], h = sz[k][1];
              tex_t dr = texture(90 + k, w + 16, h + 16, NVN_FORMAT_RGBA16F); if (!pass) { mtl_tex_init(&dr); mtl_reg_tex(710 + k, &dr, NULL); }
              os_unfair_lock_lock(&g_rmu); id<MTLTexture> drt = tex_by_id(710 + k); os_unfair_lock_unlock(&g_rmu);
              if (!pass) pattern(drt, w, h);
              fill(written, MTLClearColorMake(0, 0, 0, 1));
              { const uint32_t r[8] = {0, 0, w - 1, h - 1, 0, 0, 1919, 1079}; memcpy(S.push[1], r, sizeof r); } S.tex[5][0] = 710 + k; mtl_sub_begin();
              int d = up_mfx_encode(named); ran += d;
              CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the dynamic-resolution submission completes");
              if (!d || pass) continue;
              id<MTLBuffer> got = read16(written), want = reference(w, h, 1920, 1080);
              int eq = !memcmp(got.contents, want.contents, 1920 * 1080 * 8); same += eq;
              if (!eq) { const uint16_t *a = got.contents, *b = want.contents; size_t diff = 0; for (size_t i = 0; i < 1920 * 1080 * 4; i++) diff += a[i] != b[i]; fprintf(stderr, "%ux%u: %zu of %d values differ from MetalFX's own scale\n", w, h, diff, 1920 * 1080 * 4); }
          }
          CHECK(ran == 10, "MetalFX draws every dynamic-resolution size");
          CHECK(same == 5, "each size's image is byte for byte MetalFX's own scale of its rectangle (nothing from past the content)");
          uint64_t made = g_up_mfx_made - made0;
          printf("dynamic resolution: %llu scalers made for 5 input sizes over 10 dispatches (DM_NVN_MFX_CONTENT %s)\n", (unsigned long long)made, content ? "on" : "off");
          CHECK(content ? made <= 1 : made >= 5, content ? "one scaler for the output serves every input size" : "DM_NVN_MFX_CONTENT=0: a scaler per input size, as before"); }
        named->up_color = UP_COLOR_LINEAR;
        NvShader *encoded_out = upscaler(key); encoded_out->up_color = UP_COLOR_KEEP;
        CHECK(!up_mfx_wanted(encoded_out), "a named shader whose output stays encoded is left to its shader");
        S.tex[5][0] = 701;
        S.img[5][1] = 703; { const uint32_t same_r[8] = {0, 0, 959, 539, 0, 0, 959, 539}; memcpy(S.push[1], same_r, sizeof same_r); } mtl_sub_begin(); uint64_t kept = g_up_mfx_kept;
        CHECK(!up_mfx_encode(named) && g_up_mfx_kept == kept + 1, "an image no larger than the texture leaves the dispatch to the shader");
        mtl_wait(mtl_sub_commit(), 5000000000ull);
        // The bilinear stretch (DM_NVN_UP_BILINEAR=1; profile key upscaler_bilinear): the same dispatches drawn by one bilinear draw, no MetalFX scaler, read again at the next frame
        setenv("DM_NVN_UP_BILINEAR", "1", 1); atomic_fetch_add(&g_cur_frame, 1);
        uint64_t mfx0 = g_up_mfx_n, bil0 = g_up_bil_n;
        S.img[5][1] = 702; S.tex[5][0] = 701; { const uint32_t r[8] = {0, 0, 959, 539, 0, 0, 1919, 1079}; memcpy(S.push[1], r, sizeof r); }
        fill(tex_mtl(&in), MTLClearColorMake(colour[0], colour[1], colour[2], colour[3])); fill(written, MTLClearColorMake(0, 0, 0, 1)); mtl_sub_begin();
        CHECK(up_mfx_encode(named), "the stretch draws the named shader's dispatch");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the stretch's submission completes");
        CHECK(g_up_bil_n == bil0 + 1 && g_up_mfx_n == mfx0, "drawn by the stretch, not by MetalFX");
        CHECK(matches(written, colour, MTLRegionMake2D(0, 0, 1920, 1080), black), "the stretch fills the whole 1920x1080 image with the texture's colour");
        CHECK(!atomic_load(&g_up_mfx_drawn), "after the stretch the present may sharpen again");
        fill(tex_mtl(&packed), MTLClearColorMake(hdr[0], hdr[1], hdr[2], hdr[3])); fill(written, MTLClearColorMake(0, 0, 0, 1));
        { const uint32_t r[8] = {7, 3, 959, 539, 13, 9, 1899, 1059}; memcpy(S.push[1], r, sizeof r); } S.tex[5][0] = 704; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "the stretch takes the packed HDR subrectangle");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the stretched HDR submission completes");
        CHECK(matches(written, hdr, MTLRegionMake2D(13, 9, 1900, 1060), black), "the stretched HDR output fills only its destination rectangle, unclamped");
        named->up_color = UP_COLOR_ROOT;
        fill(tex_mtl(&r11), MTLClearColorMake(1.0, 0.5, 0.25, 1)); fill(tex_mtl(&r11_out), MTLClearColorMake(0, 0, 0, 1));
        { const uint32_t r[8] = {0, 0, 959, 539, 0, 0, 1919, 1079}; memcpy(S.push[1], r, sizeof r); } S.tex[5][0] = 706; S.img[5][1] = 707; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "the stretch takes square-rooted R11G11B10F input");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the square-rooted stretch's submission completes");
        CHECK(matches_r11(tex_mtl(&r11_out), hdr_squared), "the square-rooted input comes out squared into linear colour through the stretch");
        named->up_color = UP_COLOR_SRGB; mfx0 = g_up_mfx_n; bil0 = g_up_bil_n;
        fill(written, MTLClearColorMake(0, 0, 0, 1)); S.tex[5][0] = 701; S.img[5][1] = 702; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "sRGB-encoded input with the stretch on");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the sRGB submission with the stretch on completes");
        CHECK(g_up_mfx_n == mfx0 + 1 && g_up_bil_n == bil0, "sRGB-encoded input keeps MetalFX, which decodes it");
        CHECK(matches(written, decoded, MTLRegionMake2D(0, 0, 1920, 1080), black), "and comes out decoded to linear");
        named->up_color = UP_COLOR_LINEAR;
        setenv("DM_NVN_UP_BILINEAR", "0", 1); atomic_fetch_add(&g_cur_frame, 1); mfx0 = g_up_mfx_n; bil0 = g_up_bil_n; mtl_sub_begin();
        CHECK(up_mfx_encode(named), "=0 at the next frame: MetalFX again");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the MetalFX submission after the stretch completes");
        CHECK(g_up_mfx_n == mfx0 + 1 && g_up_bil_n == bil0, "with =0 MetalFX draws the dispatch, the preset picked in game taken at the next frame");
        unsetenv("DM_NVN_UP_BILINEAR"); atomic_fetch_add(&g_cur_frame, 1);
        CHECK(up_bil_on() == DM_GAME_UP_BILINEAR, "unset: the profile's upscaler_bilinear decides");
        setenv("DM_NVN_UP_BILINEAR", "", 1); atomic_fetch_add(&g_cur_frame, 1);
        CHECK(up_bil_on() == DM_GAME_UP_BILINEAR, "empty (a front end clearing a preset's switch): the profile's upscaler_bilinear decides");
    }
    printf("t_upscaler_mfx (%s): %d checks, %d failed\n", on ? "metalfx" : "game", checks, failed);
    return failed != 0;
}}
