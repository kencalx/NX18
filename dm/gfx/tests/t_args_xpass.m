// Argument blocks across render passes and program changes (DM_NVN_ARGS_XPASS, encode_args_ args_xpass_ok): within one submission a fragment shader's block is reused in a later
// pass, and after another program's draw, when nothing it holds has changed; a new texture handle, sampler, uniform address, registration, memory pool, guest write or storage binding of
// the stage, an inline update over the handles a shader reads from uniform memory, or a buffer write after a block made of copies makes it encode again (a uniform address only patches
// it); a new submission never reuses one. Every draw writes one pixel of a 16x1 target and the pixels are read back. DM_NVN_ARGS_XPASS=0 (and the switch set to 0 here) keeps the pass
// rule: every pass and program change encodes again. The bench at the end times a full encode against a cross-pass reuse of a shader with 28 bindings.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <unistd.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static uint8_t *mem;   // one pool: uniform blocks, the handle word of the TEXU shader, the textures' guest bytes
static uint64_t next_serial = 97000;
enum { W = 16, TA = 1, TB = 2, TC = 9, S_CLAMP = 1, S_REPEAT = 2 };
static float *u1, *u2; static uint32_t *hword;

static id<MTLTexture> texture(tex_t *t, int width, int format) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=format, .width=width, .height=1, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
    CHECK(out != nil, "texture allocated");
    if (out) { res_add(out); mtl_tex_init(t); serial_put(t->serial, out); }
    return out;
}
static NvShader *shader(id<MTLFunction> fn, int texu, int fixw) {
    static uint64_t identity = 0x7300000000000000ull;
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = fn; snprintf(s->key, sizeof s->key, "%016llx", (unsigned long long)identity++);
    s->arg_len = [fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    s->rf.nb = 3;
    s->rf.b[0] = texu ? (nvn_rbind){.kind=NVN_RB_TEXU, .reg=1, .off=0, .aid=0, .dtt=MTLTextureType2D} : (nvn_rbind){.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D};
    s->rf.b[1] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=0, .aid=1};
    s->rf.b[2] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=0, .aid=2, .fixw=(uint16_t)fixw};
    return s;
}
static uint64_t n_enc(void) { return g_stat_args_enc; }
static uint64_t n_reuse(void) { return g_stat_args_reuse; }
static uint64_t n_patch(void) { return g_stat_args_patch; }
static uint64_t n_x(void) { return g_stat_args_xpass; }
static void bind_tex(int tid) { p_bind_handles b = {.stage=1, .first=0, .n=1}; b.h[0] = (uint64_t)tid; state_op(OP_BIND_TEX, &b); }
static void bind_samp(int sid) { p_bind_handles b = {.stage=1, .first=0, .n=1}; b.h[0] = (uint64_t)sid << 20; state_op(OP_BIND_SAMP, &b); }
static void bind_ubo(int reg, const void *p) { p_bind_buf b = {.stage=1, .index=reg, .addr=(uint64_t)(uintptr_t)p, .size=16}; state_op(OP_BIND_UBO, &b); }
static void bind_prog(const prog_t *p) { p_bind_program b = {.prog=p, .stages=0x1f}; state_op(OP_BIND_PROGRAM, &b); }

static id<MTLRenderPipelineState> g_xpso; static tex_t g_out; static id<MTLTexture> g_out_tex;
static int g_px;   // the next pixel to write
static void xpass_next(void) { rp_end(); R.clear_c[0] = 0; CHECK(rp_begin() != nil, "render pass opens"); enc_r_pso(g_enc, g_xpso); }
// One draw of sh into the next pixel; *want its expected colour, kept for the readback
static uint8_t g_want[2][W][4]; static int g_sub_i;
static void xdraw(NvShader *sh, const uint8_t want[4]) {
    CHECK(g_px < W, "room for the draw"); if (g_px >= W) return;
    enc_r_viewport(g_enc, (MTLViewport){g_px, 0, 1, 1, 0, 1});
    CHECK(encode_args((id<MTL4CommandEncoder>)g_enc, sh, 1, 0), "fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    for (int i = 0; i < g_nsd; i++) if (g_sd[i].idx == 0) { g_sd[i].wrote = g_sd[i].rast = 1; }   // as the draw path notes a raster write: a loaded attachment is stored
    memcpy(g_want[g_sub_i][g_px++], want, 4);
}
// A step: the counters' moves over one draw (encoded, reused, patched, of those across passes)
typedef struct { uint64_t e, r, p, x; } cnt;
static cnt take(void) { return (cnt){n_enc(), n_reuse(), n_patch(), n_x()}; }
static int moved(cnt a, int e, int r, int p, int x) { cnt b = take(); return b.e - a.e == (uint64_t)e && b.r - a.r == (uint64_t)r && b.p - a.p == (uint64_t)p && b.x - a.x == (uint64_t)x; }
#define STEP(sh, want, e, r, p, x, label) do { cnt c0_ = take(); xdraw(sh, want); CHECK(moved(c0_, e, r, p, x), label); } while (0)

static void begin(void) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &g_out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(rp_begin() != nil, "first render pass opens"); enc_r_pso(g_enc, g_xpso); R.clear_c[0] = 0; g_px = 0;
    bind_tex(TA); bind_samp(S_CLAMP); bind_ubo(0, u1); bind_ubo(1, hword);
}
static void finish(id<MTLBuffer> rb, const char *label) {
    rp_end(); enc_b_copy_texture_buffer(blit(), g_out_tex, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(W, 1, 1), rb, 0, 4 * W, 4 * W);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "GPU submission completed");
    int bad = -1;
    for (int x = 0; x < g_px && bad < 0; x++) { const uint8_t *p = (const uint8_t *)rb.contents + 4 * x, *w = g_want[g_sub_i][x];
        for (int k = 0; k < 4; k++) if (abs((int)p[k] - (int)w[k]) > 1) { bad = x; break; } }
    if (bad >= 0) { const uint8_t *p = (const uint8_t *)rb.contents + 4 * bad, *w = g_want[g_sub_i][bad]; fprintf(stderr, "pixel %d: %u,%u,%u,%u, want %u,%u,%u,%u\n", bad, p[0], p[1], p[2], p[3], w[0], w[1], w[2], w[3]); }
    CHECK(bad < 0, label);
}
static const uint8_t RED[4] = {255, 0, 0, 255}, GREEN[4] = {0, 255, 0, 255}, BLUE[4] = {0, 0, 255, 255}, WHITE[4] = {255, 255, 255, 255}, MAGENTA[4] = {255, 0, 255, 255}, YELLOW[4] = {255, 255, 0, 255};

// The cross-pass rule on (a, b, c), with every draw's pixel checked
static void cross_case(NvShader *fa, NvShader *fb, NvShader *fc, const prog_t *pa, const prog_t *pb, id<MTLBuffer> rb) {
    const int P = g_args_partial > 0;   // DM_NVN_ARGS_PARTIAL (on by default): a texture, sampler or storage change patches the block in a later pass too (t_args_partial)
    g_sub_i = 0; begin(); bind_prog(pa);
    STEP(fa, GREEN, 1, 0, 0, 0, "the first draw encodes");                                     // 0: texture A, clamp: texel 1 (green)
    xpass_next();
    STEP(fa, GREEN, 0, 1, 0, 1, "a later pass with nothing changed reuses the block");          // 1
    bind_prog(pb);
    STEP(fb, WHITE, 1, 0, 0, 0, "another program's shader encodes");                           // 2: the handle in uniform slot 1 names texture B: texel 1 (white)
    bind_prog(pa);
    STEP(fa, GREEN, 0, 1, 0, 1, "back to the first program, the block is reused");             // 3
    xpass_next(); bind_prog(pb);
    STEP(fb, WHITE, 0, 1, 0, 1, "a shader that reads handles from uniform memory: reused while the memory holds");   // 4
    bind_prog(pa); xpass_next();
    bind_tex(TB);
    STEP(fa, WHITE, !P, 0, P, P, P ? "a new texture handle patches the block's texture (DM_NVN_ARGS_PARTIAL)" : "a new texture handle encodes");                               // 5: texture B, clamp: white
    xpass_next(); bind_samp(S_REPEAT);
    STEP(fa, BLUE, !P, 0, P, P, P ? "a new sampler patches the block's sampler" : "a new sampler encodes");                                       // 6: repeat: texel 0 (blue)
    xpass_next(); bind_ubo(0, u2);
    STEP(fa, MAGENTA, 0, 0, 1, 1, "a new uniform address patches the block");                  // 7: c = (1, 1): blue + red
    xpass_next();
    { tex_t *tc = calloc(1, sizeof *tc); texture(tc, 2, NVN_FORMAT_RGBA8); tc->mem = mem + 0x6000; tc->L.size = 8; mtl_reg_tex(TC, tc, NULL); }
    STEP(fa, MAGENTA, 1, 0, 0, 0, "a registration encodes");                                   // 8
    xpass_next();
    { void *pool; if (posix_memalign(&pool, getpagesize(), 0x4000)) abort(); memset(pool, 0, 0x4000); mtl_pool_add(pool, 0x4000); }
    STEP(fa, MAGENTA, 1, 0, 0, 0, "a new memory pool encodes");                                // 9
    xpass_next();
    { void *page; if (posix_memalign(&page, getpagesize(), getpagesize())) abort(); nvn_dirty_add_range(page, getpagesize()); }
    STEP(fa, MAGENTA, 1, 0, 0, 0, "a guest write stamp encodes");                              // 10
    xpass_next();
    { p_bind_buf b = {.stage=1, .index=3, .addr=(uint64_t)(uintptr_t)(mem + 0x7000), .size=64}; state_op(OP_BIND_SSBO, &b); }
    STEP(fa, MAGENTA, !P, 0, P, P, P ? "a storage binding of the stage patches the block (it has none: nothing written again)" : "a storage binding of the stage encodes");                   // 11
    rp_end();
    uint32_t ha = TA; mtl_sub_update(&ha, (uint64_t)(uintptr_t)hword, 4);   // the handle in uniform slot 1 now names texture A, written outside a pass
    xpass_next(); bind_prog(pb);
    STEP(fb, RED, 1, 0, 0, 0, "handles read from uniform memory: an inline update over them encodes");   // 12: texture A, repeat: texel 0 (red); with c = (1, 1) red stays red
    bind_prog(pa);
    xpass_next(); bind_prog(pb); bind_prog(pa);
    STEP(fc, MAGENTA, 1, 0, 0, 0, "a block with a padded uniform copy encodes");               // 13: texture B, repeat, the copy of u2
    xpass_next();
    STEP(fc, MAGENTA, 0, 1, 0, 1, "and is reused in a later pass while nothing was written");  // 14
    rp_end(); mtl_sub_fill((uint64_t)(uintptr_t)(mem + 0x7800), 64, 0);   // a buffer write elsewhere, outside a pass
    xpass_next();
    STEP(fc, MAGENTA, 1, 0, 0, 0, "a block of copies encodes again after a buffer write");      // 15
    finish(rb, "every draw of the cross-pass submission wrote what its bindings named");
    // c: a new submission never reuses a block of the last one
    g_sub_i = 1; begin(); bind_prog(pa); bind_tex(TB); bind_samp(S_REPEAT); bind_ubo(0, u2);
    STEP(fa, MAGENTA, 1, 0, 0, 0, "a new submission encodes");
    xpass_next();
    STEP(fa, MAGENTA, 0, 1, 0, 1, "and reuses within itself");
    finish(rb, "the second submission's draws wrote what their bindings named");
}
// d: the switch at 0 keeps the pass rule: a later pass or a program change encodes again, consecutive draws in a pass reuse
static void pass_rule_case(NvShader *fa, NvShader *fb, const prog_t *pa, const prog_t *pb, id<MTLBuffer> rb) {
    hword[0] = TB;   // the cross-pass case's update named texture A
    g_sub_i = 0; begin(); bind_prog(pa);
    uint64_t x0 = n_x();
    STEP(fa, GREEN, 1, 0, 0, 0, "pass rule: the first draw encodes");
    STEP(fa, GREEN, 0, 1, 0, 0, "pass rule: the next draw of the pass reuses");
    xpass_next();
    STEP(fa, GREEN, 1, 0, 0, 0, "pass rule: a later pass encodes");
    bind_prog(pb); STEP(fb, WHITE, 1, 0, 0, 0, "pass rule: another program encodes");
    bind_prog(pa); STEP(fa, GREEN, 1, 0, 0, 0, "pass rule: back to the first program encodes");
    xpass_next(); bind_ubo(0, u2);
    STEP(fa, YELLOW, 1, 0, 0, 0, "pass rule: a new uniform address in a later pass encodes");   // texture A, clamp: green, plus red
    bind_ubo(0, u1);
    STEP(fa, GREEN, 0, 0, 1, 0, "pass rule: within the pass it patches");
    CHECK(n_x() == x0, "pass rule: nothing reused across passes");
    finish(rb, "pass rule: every draw wrote what its bindings named");
}
// Encode cost: a shader with 16 textures, 8 samplers and 4 uniform slots, encoded in full (a hard change before each) against reused across passes (a soft one) and within a pass
static void bench(id<MTLLibrary> lib) {
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = t4_fn(lib, @"big"); strcpy(s->key, "7400000000000000");
    s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    int n = 0;
    for (int i = 0; i < 16; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=i, .aid=n, .dtt=MTLTextureType2D};
    for (int i = 0; i < 8; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=i, .aid=n};
    for (int i = 0; i < 4; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=i, .aid=n};
    s->rf.nb = n;
    begin();
    for (int i = 0; i < 16; i++) S.tex[1][i] = i & 1 ? TB : TA;
    for (int i = 0; i < 8; i++) S.samp[1][i] = (uint64_t)(i & 1 ? S_REPEAT : S_CLAMP) << 20;
    for (int i = 0; i < 4; i++) S.ubo[1][i] = (p_bind_buf){.addr=(uint64_t)(uintptr_t)u1, .size=16};
    args_dirty_all();
    enum { N = 20000 }; double ns[3];
    for (int mode = 0; mode < 3; mode++) {
        encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
        uint64_t e0 = n_enc(), t0 = bp_now();
        for (int i = 0; i < N; i++) { if (mode == 0) args_dirty_all(); else if (mode == 1) args_dirty_soft(); encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0); }
        ns[mode] = (double)(bp_now() - t0) / N;
        CHECK(n_enc() - e0 == (mode == 0 || (mode == 1 && !g_args_xpass) ? (uint64_t)N : 0), mode == 0 ? "bench: every hard change encodes" : mode == 1 ? "bench: a soft change encodes only with the switch off" : "bench: no encode within the pass");
    }
    printf("t_args_xpass bench (%d bindings, %d calls each): full encode %.0f ns, %s %.0f ns, in-pass reuse %.0f ns\n", n, N, ns[0], g_args_xpass ? "cross-pass reuse" : "after a soft change (switch off)", ns[1], ns[2]);
    rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "bench submission completed");
}

int main(void) { @autoreleasepool {
    alarm(120);
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1); setenv("DM_PSO_RECORD", "/dev/null", 1);
    const char *env = getenv("DM_NVN_ARGS_XPASS"); int env_off = env && !strcmp(env, "0");
    mtl_init(); NSError *error = nil;
    NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; constant float4 *c [[id(2)]]; };\n"
        "fragment float4 f(constant A &a [[buffer(0)]]) { float4 x = a.t.sample(a.s, float2(1.25, 0.5), level(0)); return float4(saturate(x.rgb * a.c[0].x + float3(a.c[0].y, 0, 0)), 1); }\n"
        "struct B {"];
    for (int i = 0; i < 16; i++) [src appendFormat:@" texture2d<float> t%d [[id(%d)]];", i, i];
    for (int i = 0; i < 8; i++) [src appendFormat:@" sampler s%d [[id(%d)]];", i, 16 + i];
    for (int i = 0; i < 4; i++) [src appendFormat:@" constant float4 *c%d [[id(%d)]];", i, 24 + i];
    [src appendString:@" };\nfragment float4 big(constant B &a [[buffer(0)]]) { return a.t0.sample(a.s0, float2(0.5)) + a.t15.sample(a.s7, float2(0.5)) + a.c0[0] + a.c3[0]; }\n"];
    id<MTLLibrary> lib = t4_lib(src, nil, &error);
    CHECK(lib != nil, "synthetic shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = t4_fn(lib, @"v"); d.fragmentFunction = t4_fn(lib, @"f"); d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    g_xpso = t4_rps(d, &error); CHECK(g_xpso != nil, "render pipeline compiles"); if (!g_xpso) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    mem = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); CHECK(mem != MAP_FAILED, "pool allocated"); if (mem == MAP_FAILED) return 2;
    mtl_pool_add(mem, 0x10000);
    u1 = (float *)(mem + 0x100); u1[0] = 1; u1[1] = 0;
    u2 = (float *)(mem + 0x200); u2[0] = 1; u2[1] = 1;
    hword = (uint32_t *)(mem + 0x300); hword[0] = TB;
    tex_t ta, tb; const uint8_t pa_px[8] = {255, 0, 0, 255, 0, 255, 0, 255}, pb_px[8] = {0, 0, 255, 255, 255, 255, 255, 255};   // A: red, green; B: blue, white
    id<MTLTexture> xa = texture(&ta, 2, NVN_FORMAT_RGBA8), xb = texture(&tb, 2, NVN_FORMAT_RGBA8); if (!xa || !xb) return 2;
    [xa replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:pa_px bytesPerRow:8]; [xb replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:pb_px bytesPerRow:8];
    ta.mem = mem + 0x1000; ta.L.size = 8; memcpy((void *)ta.mem, pa_px, 8); tb.mem = mem + 0x2000; tb.L.size = 8; memcpy((void *)tb.mem, pb_px, 8);
    mtl_reg_tex(TA, &ta, NULL); mtl_reg_tex(TB, &tb, NULL);
    samp_par sp = {.minf=NVN_MIN_FILTER_NEAREST, .magf=NVN_MAG_FILTER_NEAREST, .ws=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wt=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wr=NVN_WRAP_MODE_CLAMP_TO_EDGE, .lod_max=1000};
    mtl_reg_samp(S_CLAMP, &sp); sp.ws = NVN_WRAP_MODE_REPEAT; mtl_reg_samp(S_REPEAT, &sp);
    g_out_tex = texture(&g_out, W, NVN_FORMAT_RGBA8); if (!g_out_tex) return 2;
    id<MTLBuffer> rb = [g_dev newBufferWithLength:4 * W options:MTLResourceStorageModeShared]; res_add(rb);
    id<MTLFunction> ff = t4_fn(lib, @"f");
    NvShader *fa = shader(ff, 0, 0), *fb = shader(ff, 1, 0), *fc = shader(ff, 0, 128);   // fc reads its uniform slot up to byte 512, past the 256 readable: a padded copy (ub_padded)
    static prog_t pa = {.serial = 970001}, pb = {.serial = 970002};
    if (!env_off) {
        CHECK(args_xpass_on(), "the cross-pass rule is on by default");
        cross_case(fa, fb, fc, &pa, &pb, rb);
        g_args_xpass = 0; args_dirty_all();   // the switch off from here (a block kept from the rule's time is never current after a hard change)
    } else CHECK(!args_xpass_on(), "DM_NVN_ARGS_XPASS=0 turns the cross-pass rule off");
    pass_rule_case(fa, fb, &pa, &pb, rb);
    if (!env_off) { g_args_xpass = 1; args_dirty_all(); }
    bench(lib);
    if (g_bl_on) CHECK(g_bls.mism == 0 && g_bls.enc > 0, "DM_NVN_BINDLESS=1: slot tables checked against every texture and sampler the slot path resolved, no mismatch");
    printf("t_args_xpass%s: %d checks, %d failed\n", env_off ? " (DM_NVN_ARGS_XPASS=0)" : "", checks, failed);
    return failed != 0;
} }
