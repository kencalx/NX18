// Six cases a review of the partial argument patches (DM_NVN_ARGS_PARTIAL, encode_args_ args_partial / pk_take) found handled in code but untested, each drawn into one pixel of a
// 64x1 target and read back:
// 1. an inline update deferred in the pass over a uniform slot, after (and before) a texture change: the patch writes the texture and the uniform slot, which reads the update's copy;
// 2. a pool shader (TEXP / SAMPP, its texture and sampler IDs in a uniform slot) on the widened uniform patch, on a partial patch of its slot texture, both, across a pass, and after
//    another table's build (with DM_NVN_ARGS_REGCHK its tables taken again in a partial patch);
// 3. a shader with a border colour twin (the sampler, its twin and the border block, nvn_border.h) and c2 on a texture-only partial patch: every sampler and the block are written
//    again, so the border colour Metal lacks still comes out, and c2's word for the slot names the new texture;
// 4. a same-pass feedback snapshot (fb_prepare) with a texture rebind in the same pass: the next draw is encoded in full and reads the attachment itself, not the snapshot the
//    earlier block held;
// 5. a cross-pass partial patch of a block made of copies (ab_xok 2: a uniform slot padded with zeros): taken while nothing was written, refused after a buffer write, and refused
//    after a sample count change for a shader reading c0 (whose bank then holds the new count);
// 6. the vertex stage: texture and sampler partial patches in a pass and across passes (with DM_NVN_ARGS_XPASS=0 only within the pass).
// Run with the switches at their defaults and with DM_NVN_ARGS_PARTIAL=0, DM_NVN_ARGS_XPASS=0, DM_NVN_ARGS_REGCHK=0 and DM_NVN_ARGS_DRV=0: the same pixels, each draw counted as
// the switches say.
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

static uint8_t *mem;
static uint64_t next_serial = 95000;
enum { W = 64, TA = 40, TB = 80, TS = 100, S_CLAMP = 1, S_REPEAT = 2, S_BORDER = 3 };
static const uint8_t TXA[2][4] = {{40, 10, 0, 255}, {80, 10, 0, 255}}, TXB[2][4] = {{120, 200, 0, 255}, {160, 200, 0, 255}};
static int P, X, RC;   // partial patches, the cross-pass rule, the registration check (pool tables taken again in a patch)

static id<MTLTexture> texture(tex_t *t, int width) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=width, .height=1, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
    CHECK(out != nil, "texture allocated");
    if (out) { res_add(out); mtl_tex_init(t); serial_put(t->serial, out); }
    return out;
}
static NvShader *shader(id<MTLLibrary> lib, NSString *fn, int stage, int nb, const nvn_rbind *b) {
    static uint64_t identity = 0x7c00000000000000ull;
    NvShader *s = [NvShader new]; s->stage = stage; s->fn = t4_fn(lib, fn); snprintf(s->key, sizeof s->key, "%016llx", (unsigned long long)identity++);
    s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    s->rf.nb = nb; memcpy(s->rf.b, b, sizeof *b * nb);
    return s;
}
static id<MTLRenderPipelineState> pso(id<MTLLibrary> lib, NSString *vert, NSString *frag) {
    NSError *error = nil; MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = t4_fn(lib, vert); d.fragmentFunction = t4_fn(lib, frag); d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> p = t4_rps(d, &error); CHECK(p != nil, "render pipeline compiles"); if (!p) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    return p;
}
static void bind_tex(int st, int slot, uint64_t h) { p_bind_handles b = {.stage=st, .first=slot, .n=1}; b.h[0] = h; state_op(OP_BIND_TEX, &b); }
static void bind_samp(int st, int slot, int sid) { p_bind_handles b = {.stage=st, .first=slot, .n=1}; b.h[0] = (uint64_t)sid << 20; state_op(OP_BIND_SAMP, &b); }
static void bind_ubo(int st, int reg, const void *p) { p_bind_buf b = {.stage=st, .index=reg, .addr=(uint64_t)(uintptr_t)p, .size=16}; state_op(OP_BIND_UBO, &b); }

static tex_t g_out; static id<MTLTexture> g_out_tex; static int g_px; static uint8_t g_want[W][4];
static void begin(void) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &g_out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(rp_begin() != nil, "first render pass opens"); R.clear_c[0] = 0; g_px = 0;
}
static void next_pass(void) { rp_end(); R.clear_c[0] = 0; CHECK(rp_begin() != nil, "render pass opens"); }
typedef struct { uint64_t e, r, p, q, x; } cnt;
static cnt take(void) { return (cnt){g_stat_args_enc, g_stat_args_reuse, g_stat_args_patch, g_stat_args_partial, g_stat_args_xpass}; }
enum { FULL, REUSE, UPATCH, PPATCH };
static void rdraw(NvShader *sh, id<MTLRenderPipelineState> p, int st, const uint8_t want[4], int how, const char *label) {
    CHECK(g_px < W, "room for the draw"); if (g_px >= W) return;
    enc_r_pso(g_enc, p); enc_r_viewport(g_enc, (MTLViewport){g_px, 0, 1, 1, 0, 1});
    cnt a = take();
    CHECK(encode_args((id<MTL4CommandEncoder>)g_enc, sh, st, st == 0), "arguments encoded");
    cnt b = take();
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    for (int i = 0; i < g_nsd; i++) if (g_sd[i].idx == 0) { g_sd[i].wrote = g_sd[i].rast = 1; }
    memcpy(g_want[g_px++], want, 4);
    static const char *const hn[4] = {"a full encode", "reused", "a uniform patch", "a partial patch"};
    int got = b.e != a.e ? FULL : b.q != a.q ? PPATCH : b.p != a.p ? UPATCH : b.r != a.r ? REUSE : -1;
    char l[300]; snprintf(l, sizeof l, "%s: %s", label, hn[how]);
    CHECK(got == how && (b.e - a.e) + (b.r - a.r) + (b.p - a.p) == 1, l);
    if (got != how) fprintf(stderr, "  (%s)\n", got >= 0 ? hn[got] : "nothing counted");
}
static void finish(id<MTLBuffer> rb, const char *label) {
    rp_end(); enc_b_copy_texture_buffer(blit(), g_out_tex, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(W, 1, 1), rb, 0, 4 * W, 4 * W);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "GPU submission completed");
    int bad = 0;
    for (int x = 0; x < g_px; x++) { const uint8_t *q = (const uint8_t *)rb.contents + 4 * x, *w = g_want[x]; int d = 0;
        for (int k = 0; k < 4; k++) d |= abs((int)q[k] - (int)w[k]) > 1;
        if (d) { bad++; fprintf(stderr, "%s: pixel %d: %u,%u,%u,%u, want %u,%u,%u,%u\n", label, x, q[0], q[1], q[2], q[3], w[0], w[1], w[2], w[3]); } }
    CHECK(!bad, label);
}
static const uint8_t *px(uint8_t r, uint8_t g, uint8_t b, uint8_t a) { static uint8_t v[4]; v[0] = r; v[1] = g; v[2] = b; v[3] = a; return v; }
static uint8_t u8(float f) { return (uint8_t)lrintf(f * 255.0f); }
static const uint8_t *arena_cpu(uint64_t gpu) {   // the CPU address of an arena block's GPU address (a c0 bank)
    for (NvArena *a in g_sub_arenas) if (gpu >= a->gpu && gpu < a->gpu + a->len) return a->cpu + (gpu - a->gpu);
    return NULL;
}

// 1. An inline update in the pass over the uniform slot, with a texture change: R the texture's texel 1, G the uniform's first float
static void case_update(NvShader *f1, id<MTLRenderPipelineState> p1, id<MTLBuffer> rb) {
    float *u = (float *)(mem + 0x100); u[0] = 0.25f;
    begin(); bind_tex(1, 0, TA); bind_samp(1, 0, S_CLAMP); bind_ubo(1, 0, u);
    rdraw(f1, p1, 1, px(80, u8(0.25f), 0, 255), FULL, "1: the first draw");
    bind_tex(1, 0, TB); float v = 0.75f; mtl_sub_update(&v, (uint64_t)(uintptr_t)u, 4);
    CHECK(g_nubd > 0, "1: the update is deferred (the pass is open)");
    rdraw(f1, p1, 1, px(160, u8(0.75f), 0, 255), P ? PPATCH : FULL, "1: a texture change, then an inline update over the uniform slot");
    if (P) CHECK((g_pk_last & (PK_TEX | PK_UBO)) == (PK_TEX | PK_UBO), "1: the patch wrote the texture and the uniform slot");
    v = 0.5f; mtl_sub_update(&v, (uint64_t)(uintptr_t)u, 4); bind_tex(1, 0, TA);
    rdraw(f1, p1, 1, px(80, u8(0.5f), 0, 255), P ? PPATCH : FULL, "1: an inline update, then a texture change");
    v = 1.0f; mtl_sub_update(&v, (uint64_t)(uintptr_t)u, 4);
    rdraw(f1, p1, 1, px(80, 255, 0, 255), UPATCH, "1: an inline update alone");
    rdraw(f1, p1, 1, px(80, 255, 0, 255), REUSE, "1: nothing since");
    finish(rb, "1: every draw read its texture and the uniform value its update left");
}

// 2. A pool shader: R the pool texture at the ID in its uniform slot (texel 1, the pool sampler at the ID beside it), G its slot texture (texel 0)
static void case_pool(NvShader *fq, id<MTLRenderPipelineState> pq, id<MTLBuffer> rb) {
    uint32_t *q1 = (uint32_t *)(mem + 0x400), *q2 = (uint32_t *)(mem + 0x500);
    q1[0] = TA; q1[1] = S_CLAMP; q2[0] = TB; q2[1] = S_CLAMP;
    begin(); bind_tex(1, 1, TA); bind_samp(1, 0, S_CLAMP); bind_ubo(1, 0, q1);
    rdraw(fq, pq, 1, px(80, 10, 0, 255), FULL, "2: the pool shader's first draw");
    bind_ubo(1, 0, q2);
    rdraw(fq, pq, 1, px(160, 10, 0, 255), P ? UPATCH : FULL, "2: its uniform slot moved (the widened uniform patch)");
    bind_tex(1, 1, TB);
    rdraw(fq, pq, 1, px(160, 200, 0, 255), P ? PPATCH : FULL, "2: its slot texture moved (a partial patch, the tables kept)");
    bind_ubo(1, 0, q1); bind_tex(1, 1, TA);
    rdraw(fq, pq, 1, px(80, 10, 0, 255), P ? PPATCH : FULL, "2: both");
    next_pass(); bind_tex(1, 1, TB);
    rdraw(fq, pq, 1, px(80, 200, 0, 255), P && X ? PPATCH : FULL, "2: its slot texture in a later pass");
    g_psnap_gen++;   // another table built or patched
    rdraw(fq, pq, 1, px(80, 200, 0, 255), P && RC ? PPATCH : FULL, "2: another pool table built: its tables taken again");
    if (P && RC) CHECK((g_pk_last & ~PK_X) == PK_POOL && fq->ab_pgen == g_psnap_gen, "2: a patch of the pool tables alone, stamped with the tables' generation");
    rdraw(fq, pq, 1, px(80, 200, 0, 255), REUSE, "2: nothing since");
    finish(rb, "2: every pool shader draw read the textures its uniform slot and its texture slot named");
}

// 3. A border colour twin and c2: R, G the corrected border colour (0.25, 0.5) of a sample left of the texture, B c2's word of texture slot 0 (the texture ID), A the texture's texel 1
static void case_border(NvShader *fb, id<MTLRenderPipelineState> pb, id<MTLBuffer> rb) {
    begin(); bind_tex(1, 0, TA); bind_samp(1, 0, S_BORDER);
    CHECK(border_need(fb, 1), "3: the sampler has a twin the shader corrects with");
    rdraw(fb, pb, 1, px(64, 128, TA, 80), FULL, "3: the first draw");
    bind_tex(1, 0, TB);
    rdraw(fb, pb, 1, px(64, 128, TB, 160), P ? PPATCH : FULL, "3: a texture-only change");
    if (P) CHECK((g_pk_last & ~PK_X) == PK_TEX, "3: a texture-only patch (its samplers, border block and c2 written again with it)");
    { const uint64_t *slot = (const uint64_t *)((const uint8_t *)fb->ab_buf.contents + fb->ab_off);
      CHECK(slot[3] != zero_bank_gpu(), "3: the border block holds the twin's mask, not the zero bank"); }
    next_pass(); bind_tex(1, 0, TA);
    rdraw(fb, pb, 1, px(64, 128, TA, 80), P && X ? PPATCH : FULL, "3: a texture-only change in a later pass");
    finish(rb, "3: the border colour Metal lacks came out of every draw, and c2 named the bound texture");
}

// 4. A same-pass feedback snapshot, then a texture rebind in the same pass: R the source attachment's texel 0 red, G slot 1's texel 1 red
static void case_feedback(NvProg *pr, id<MTLRenderPipelineState> pf, id<MTLBuffer> rb, tex_t *src) {
    NvShader *ff = pr->sh[1];
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); g_px = 0;
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = src; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(1, 0, 0, 1);
    bind_tex(1, 0, TS); bind_tex(1, 1, TA); bind_samp(1, 0, S_CLAMP);
    CHECK(rp_begin() != nil, "4: the source attachment's pass opens (cleared red)");
    fb_prepare(pr);
    CHECK(g_fb_n == 1, "4: the draw sampling its attachment takes a snapshot");
    rp_end(); R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 1, 0, 1); CHECK(rp_begin() != nil, "4: the source overwritten green"); rp_end();
    R.rt.color[0] = &g_out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0); lc_take(pr);   // as the draw opening the pass does: the waiting green clear of the texture it samples lands first
    CHECK(rp_begin() != nil, "4: the output pass opens"); R.clear_c[0] = 0;
    rdraw(ff, pf, 1, px(255, 80, 0, 255), FULL, "4: the draw with the snapshot");
    uint64_t bound = *(const uint64_t *)((const uint8_t *)ff->ab_buf.contents + ff->ab_off);
    CHECK(bound == g_fb_rid[0], "4: its block holds the snapshot");
    bind_tex(1, 1, TB);   // in the same pass
    fb_prepare(pr);
    CHECK(g_fb_n == 0, "4: the next draw needs no snapshot");
    rdraw(ff, pf, 1, px(0, 160, 0, 255), FULL, "4: a texture rebind after the snapshot's draw (never a patch of the block holding the snapshot)");
    bound = *(const uint64_t *)((const uint8_t *)ff->ab_buf.contents + ff->ab_off);
    CHECK(bound != g_fb_rid[0], "4: its block holds the attachment itself");
    fb_prepare(pr);
    rdraw(ff, pf, 1, px(0, 160, 0, 255), REUSE, "4: and the draw after it");
    bind_tex(1, 1, TA); fb_prepare(pr);
    rdraw(ff, pf, 1, px(0, 80, 0, 255), P ? PPATCH : FULL, "4: another rebind, no snapshot now");
    finish(rb, "4: the snapshot's draw read the red snapshot, the later ones the green attachment and their slot texture");
}

// 5. A block of copies (a uniform slot read past its bound size: a padded copy) on cross-pass partial patches: R the texture's texel 1, G the uniform, B c0's sample count row (count - 1)
static void case_copies(NvShader *fx, id<MTLRenderPipelineState> px_, id<MTLBuffer> rb) {
    float *u = (float *)(mem + 0x600); u[0] = 0.25f;
    begin(); bind_tex(1, 0, TA); bind_samp(1, 0, S_CLAMP); bind_ubo(1, 0, u);
    rdraw(fx, px_, 1, px(80, u8(0.25f), 0, 255), FULL, "5: the first draw");
    CHECK(!X || fx->ab_xok == 2, "5: its block is one of copies (ab_xok 2)");
    next_pass(); bind_tex(1, 0, TB);
    cnt a = take();
    rdraw(fx, px_, 1, px(160, u8(0.25f), 0, 255), P && X ? PPATCH : FULL, "5: a texture change in a later pass, nothing written");
    if (P && X) CHECK(take().x - a.x == 1, "5: counted as across passes");
    rp_end(); mtl_sub_fill((uint64_t)(uintptr_t)(mem + 0x7800), 64, 0); R.clear_c[0] = 0; CHECK(rp_begin() != nil, "5: a pass after a buffer write");
    bind_tex(1, 0, TA);
    rdraw(fx, px_, 1, px(80, u8(0.25f), 0, 255), FULL, "5: a texture change after a buffer write: a block of copies is not patched across passes");
    next_pass(); bind_tex(1, 0, TB);
    rdraw(fx, px_, 1, px(160, u8(0.25f), 0, 255), P && X ? PPATCH : FULL, "5: and patched again in the pass after (its new copies' marks)");
    // a pass with another sample count (no draw in it): c0's sample rows differ, so in full, and its bank holds the count
    next_pass(); g_pass.samples = 4; bind_tex(1, 0, TA);
    a = take(); CHECK(encode_args((id<MTL4CommandEncoder>)g_enc, fx, 1, 0), "5: encoded in the 4-sample pass");
    CHECK(take().e - a.e == 1, "5: a texture change in a pass of another sample count: in full");
    { const uint64_t *slot = (const uint64_t *)((const uint8_t *)fx->ab_buf.contents + fx->ab_off); const uint8_t *c0 = arena_cpu(slot[3]);
      CHECK(c0 && *(const uint32_t *)(c0 + DMSH_C0_SAMPLE_INFO) == 3, "5: its c0 bank holds the sample count's rows"); }
    next_pass(); bind_tex(1, 0, TB);
    rdraw(fx, px_, 1, px(160, u8(0.25f), 0, 255), FULL, "5: back to one sample: in full again");
    finish(rb, "5: every draw of a block of copies read its texture, uniform and sample rows");
}

// 6. The vertex stage: the vertex shader samples past the right edge (texel 1 with clamp, texel 0 with repeat) and passes the red channel on
static void case_vertex(NvShader *vs, id<MTLRenderPipelineState> pv, id<MTLBuffer> rb) {
    begin(); bind_tex(0, 0, TA); bind_samp(0, 0, S_CLAMP);
    rdraw(vs, pv, 0, px(80, 0, 0, 255), FULL, "6: the vertex shader's first draw");
    rdraw(vs, pv, 0, px(80, 0, 0, 255), REUSE, "6: nothing since");
    bind_tex(0, 0, TB);
    rdraw(vs, pv, 0, px(160, 0, 0, 255), P ? PPATCH : FULL, "6: a vertex texture change");
    bind_samp(0, 0, S_REPEAT);
    rdraw(vs, pv, 0, px(120, 0, 0, 255), P ? PPATCH : FULL, "6: a vertex sampler change");
    next_pass(); bind_tex(0, 0, TA);
    rdraw(vs, pv, 0, px(40, 0, 0, 255), P && X ? PPATCH : FULL, "6: a vertex texture change in a later pass");
    next_pass();
    rdraw(vs, pv, 0, px(40, 0, 0, 255), X ? REUSE : FULL, "6: a later pass, nothing changed");
    bind_tex(0, 0, TB);
    rdraw(vs, pv, 0, px(120, 0, 0, 255), P ? PPATCH : FULL, "6: a vertex texture change within the pass");
    finish(rb, "6: every vertex-stage draw read its texture and sampler");
}

int main(void) { @autoreleasepool {
    alarm(120);
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1); setenv("DM_PSO_RECORD", "/dev/null", 1);
    mtl_init(); NSError *error = nil;
    P = g_args_partial > 0; X = args_xpass_on(); RC = g_args_regchk > 0;
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A1 { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; constant float4 *c [[id(2)]]; };\n"
        "fragment float4 f1(constant A1 &a [[buffer(0)]]) { return float4(a.t.sample(a.s, float2(0.75, 0.5), level(0)).r, a.c[0].x, 0, 1); }\n"
        "struct PT { uint n; ulong seen; array<texture2d<float>, 1> e; }; struct PS { uint n; ulong seen; array<sampler, 1> e; };\n"
        "struct Q { constant PT *tp [[id(0)]]; constant PS *sp [[id(1)]]; constant uint4 *c [[id(2)]]; texture2d<float> t1 [[id(3)]]; sampler s [[id(4)]]; };\n"
        "fragment float4 fq(constant Q &a [[buffer(0)]]) { uint t = a.c[0].x, s = a.c[0].y; return float4((&a.tp->e[0])[min(t, a.tp->n)].sample((&a.sp->e[0])[min(s, a.sp->n)], float2(0.75, 0.5), level(0)).r, a.t1.sample(a.s, float2(0.25, 0.5), level(0)).g, 0, 1); }\n"
        "struct BB { uint mask; uint pad[3]; float4 k[1]; };\n"
        "struct A3 { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; sampler sw [[id(2)]]; constant BB *blk [[id(3)]]; constant uint *c2 [[id(4)]]; };\n"
        "fragment float4 f3(constant A3 &a [[buffer(0)]]) { float4 x = a.t.sample(a.s, float2(-4.0, 0.5), level(0)), y = a.t.sample(a.sw, float2(-4.0, 0.5), level(0)); float4 k = (a.blk->mask & 1u) ? a.blk->k[0] : float4(0);"
        " float4 o = x + (y - x) * k; return float4(o.r, o.g, float(a.c2[%d] & 0xffu) / 255.0, a.t.sample(a.s, float2(0.75, 0.5), level(0)).r); }\n"
        "struct A4 { texture2d<float> src [[id(0)]]; texture2d<float> t1 [[id(1)]]; sampler s [[id(2)]]; };\n"
        "fragment float4 f4(constant A4 &a [[buffer(0)]]) { return float4(a.src.sample(a.s, float2(0.25, 0.5), level(0)).r, a.t1.sample(a.s, float2(0.75, 0.5), level(0)).r, 0, 1); }\n"
        "struct A5 { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; constant float4 *c [[id(2)]]; constant uint *c0 [[id(3)]]; };\n"
        "fragment float4 f5(constant A5 &a [[buffer(0)]]) { return float4(a.t.sample(a.s, float2(0.75, 0.5), level(0)).r, a.c[0].x, float(a.c0[%d]) * 50.0 / 255.0, 1); }\n"
        "struct VA { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; }; struct VO { float4 p [[position]]; float4 c; };\n"
        "vertex VO vt(uint i [[vertex_id]], constant VA &a [[buffer(0)]]) { VO o; o.p = float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); o.c = float4(a.t.sample(a.s, float2(1.25, 0.5), level(0)).r, 0, 0, 1); return o; }\n"
        "fragment float4 fv(VO in [[stage_in]]) { return in.c; }\n", DMSH_C2_TEX / 4, DMSH_C0_SAMPLE_INFO / 4];
    id<MTLLibrary> lib = t4_lib(src, nil, &error);
    CHECK(lib != nil, "synthetic shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    mem = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 2;
    mtl_pool_add(mem, 0x10000);
    tex_t ta, tb; id<MTLTexture> xa = texture(&ta, 2), xb = texture(&tb, 2); if (!xa || !xb) return 2;
    [xa replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:TXA bytesPerRow:8]; [xb replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:TXB bytesPerRow:8];
    ta.mem = mem + 0x1000; ta.L.size = 8; memcpy((void *)ta.mem, TXA, 8); tb.mem = mem + 0x2000; tb.L.size = 8; memcpy((void *)tb.mem, TXB, 8);
    mtl_reg_tex(TA, &ta, NULL); mtl_reg_tex(TB, &tb, NULL);
    samp_par sp = {.minf=NVN_MIN_FILTER_NEAREST, .magf=NVN_MAG_FILTER_NEAREST, .ws=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wt=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wr=NVN_WRAP_MODE_CLAMP_TO_EDGE, .lod_max=1000};
    mtl_reg_samp(S_CLAMP, &sp); sp.ws = NVN_WRAP_MODE_REPEAT; mtl_reg_samp(S_REPEAT, &sp);
    sp.ws = sp.wt = sp.wr = NVN_WRAP_MODE_CLAMP_TO_BORDER; sp.border[0] = 0.25f; sp.border[1] = 0.5f; sp.border[2] = 0.75f; sp.border[3] = 1.0f; mtl_reg_samp(S_BORDER, &sp);
    g_out_tex = texture(&g_out, W); if (!g_out_tex) return 2;
    tex_t fsrc; id<MTLTexture> xs = texture(&fsrc, 2); if (!xs) return 2; fsrc.mem = mem + 0x3000; fsrc.L.size = 8; mtl_reg_tex(TS, &fsrc, NULL);
    id<MTLBuffer> rb = [g_dev newBufferWithLength:4 * W options:MTLResourceStorageModeShared]; res_add(rb);

    nvn_rbind b1[3] = {{.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=1}, {.kind=NVN_RB_CBUF, .reg=0, .aid=2}};
    NvShader *f1 = shader(lib, @"f1", 1, 3, b1);
    nvn_rbind bq[5] = {{.kind=NVN_RB_TEXP, .aid=0, .dtt=MTLTextureType2D, .dpf=NVN_DPF_FLOAT}, {.kind=NVN_RB_SAMPP, .aid=1}, {.kind=NVN_RB_CBUF, .reg=0, .aid=2},
                       {.kind=NVN_RB_TEX, .reg=1, .aid=3, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=4}};
    NvShader *fq = shader(lib, @"fq", 1, 5, bq); fq->rf.pool = fq->rf.bindless = 1;
    nvn_rbind b3[5] = {{.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=1}, {.kind=NVN_RB_SAMP, .reg=0, .aid=2, .bw=1}, {.kind=NVN_RB_BORDER, .aid=3}, {.kind=NVN_RB_DRV2, .aid=4}};
    NvShader *f3 = shader(lib, @"f3", 1, 5, b3); f3->rf.border = 4; f3->rf.drv_read[2] = 1;
    nvn_rbind b4[3] = {{.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}, {.kind=NVN_RB_TEX, .reg=1, .aid=1, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=2}};
    NvProg *pr = [NvProg new]; pr->sh[1] = shader(lib, @"f4", 1, 3, b4);
    nvn_rbind b5[4] = {{.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=1}, {.kind=NVN_RB_CBUF, .reg=0, .aid=2, .fixw=128}, {.kind=NVN_RB_DRV0, .aid=3}};
    NvShader *f5 = shader(lib, @"f5", 1, 4, b5); f5->rf.drv_read[0] = 1;
    nvn_rbind bv[2] = {{.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=1}};
    NvShader *vs = shader(lib, @"vt", 0, 2, bv);
    id<MTLRenderPipelineState> p1 = pso(lib, @"v", @"f1"), pq = pso(lib, @"v", @"fq"), p3 = pso(lib, @"v", @"f3"), p4 = pso(lib, @"v", @"f4"), p5 = pso(lib, @"v", @"f5"), pv = pso(lib, @"vt", @"fv");
    if (!p1 || !pq || !p3 || !p4 || !p5 || !pv) return 2;

    case_update(f1, p1, rb);
    case_pool(fq, pq, rb);
    case_border(f3, p3, rb);
    case_feedback(pr, p4, rb, &fsrc);
    case_copies(f5, p5, rb);
    case_vertex(vs, pv, rb);
    if (g_bl_on) CHECK(g_bls.mism == 0 && g_bls.enc > 0, "DM_NVN_BINDLESS=1: slot tables checked against every texture and sampler the slot path resolved, no mismatch");
    printf("t_args_review%s%s%s: %d checks, %d failed\n", P ? "" : " (DM_NVN_ARGS_PARTIAL=0)", X ? "" : " (DM_NVN_ARGS_XPASS=0)", RC ? "" : " (DM_NVN_ARGS_REGCHK=0)", checks, failed);
    return failed != 0;
} }
