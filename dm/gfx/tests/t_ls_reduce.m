// Attachment traffic the replay proves avoidable (nvn_mtl.m: rule (a) ldc_scan / clear_color_tri, DM_NVN_CLEARED_LOAD; rule (b) ls_dead_scan / sd_finish, DM_NVN_DS_DEAD_STORE; rule (c)
// the resolve in copy_t2t_enc, DM_NVN_MSAA_RESOLVE_ONLY) and the DM_NVN_LS_STATS measurement. Through the production replay on GPU-only targets: a colour target loaded as DontCare
// because the pass clears it whole before drawing it (and the cases that must still load it: a scissored clear, a draw into it first; and, when that clear
// cannot be drawn (its pipeline fails, g_clr_fail_test), the target never stored, so its memory keeps what it held); a depth / stencil store dropped because a
// whole clear of the same texture comes before any read (both planes, the depth alone, after a clear of another depth target), and the cases that keep it (a draw between, a
// scissored clear, the clear in the next command list, another texture object over the same memory, a masked stencil clear); a multisample resolve that stores only the resolve
// because the samples are cleared whole next (and kept when they are drawn over or nothing follows). Every case runs with its switch on and off: the read-backs (colour, depth,
// stencil, the resolve destination and the samples resolved again) match byte for byte and hold the literal values, and the rules fire exactly where expected. Run with Metal
// validation and its load / store action checks, which fill what a DontCare load or store leaves with a pattern: a read of dropped bytes would show in the read-backs.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { W = 16 };
static pool_t gpool;
static tex_t C, C1, O, Z, Z2, ZA, MS, MD;   // colours, the other target, depth (D32S8), another depth, a texture object over Z's memory (another serial), 4x colour, its resolve destination
static prog_t p0 = {.serial = 99801}, p01 = {.serial = 99802};   // writes target 0 green; writes 0 green and 1 red
static tex_t target(uint64_t serial, int64_t off, NVNformat format, int samples) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = &gpool, .mem = gpool.mem + off, .off = off};
    t.d = (nvn_texdesc){.target = samples > 1 ? NVN_TEXTURE_TARGET_2D_MULTISAMPLE : NVN_TEXTURE_TARGET_2D, .format = format, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = W, .height = W, .depth = 1, .levels = 1, .samples = samples};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t); return t;
}
static uint8_t ops[8192]; static size_t nops;
static void *op(uint32_t code, size_t size) { op_hdr h = {code, (uint32_t)(sizeof h + size)}; memcpy(ops + nops, &h, sizeof h); void *a = ops + nops + sizeof h; memset(a, 0, size); nops += h.size; return a; }
static void set_rt(const tex_t *c0, const tex_t *c1, const tex_t *z) { p_set_rt r = {0}; r.n = c1 ? 2 : c0 ? 1 : 0; r.color[0] = c0; r.color[1] = c1; r.depth = z; *(p_set_rt *)op(OP_SET_RT, sizeof r) = r; }
static void scissor(int x, int w) { *(p_scissor *)op(OP_SCISSOR, sizeof(p_scissor)) = (p_scissor){x, 0, w, W}; }
static void draw_op(const prog_t *p) {
    *(p_bind_program *)op(OP_BIND_PROGRAM, sizeof(p_bind_program)) = (p_bind_program){p, 3};
    *(p_draw *)op(OP_DRAW, sizeof(p_draw)) = (p_draw){NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3};
}
static void clear_c(int slot, float r, float g, float b, float a) { *(p_clear_color *)op(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){slot, 0xf, {r, g, b, a}}; }
static void clear_ds(float depth, int stencil, int smask) { *(p_clear_ds *)op(OP_CLEAR_DS, sizeof(p_clear_ds)) = (p_clear_ds){.depth = depth, .depth_mask = 1, .stencil = stencil, .stencil_mask = smask}; }
static void resolve_op(void) { p_copy_t2t *c = op(OP_COPY_T2T, sizeof(p_copy_t2t)); c->src = &MS; c->dst = &MD; c->sr = (NVNcopyRegion){0, 0, 0, W, W, 1}; c->dr = c->sr; c->flags = DM_COPY_RESOLVE; }
static void exec_ops(void) { op(OP_END, 0); mtl_exec(ops); nops = 0; }
static void fill(void) {   // C blue, C1 yellow, O black, Z / Z2 depth 0.75 stencil 0x33, MS red, MD black: outside the replay
    mtl_sub_begin();
    const tex_t *cs[4] = {&C, &C1, &O, &MD}; MTLClearColor cc[4] = {MTLClearColorMake(0, 0, 1, 1), MTLClearColorMake(1, 1, 0, 1), MTLClearColorMake(0, 0, 0, 1), MTLClearColorMake(0, 0, 0, 1)};
    for (int i = 0; i < 4; i++) { MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new]; p.colorAttachments[0].texture = tex_mtl(cs[i]); p.colorAttachments[0].clearColor = cc[i];
        p.colorAttachments[0].loadAction = MTLLoadActionClear; p.colorAttachments[0].storeAction = MTLStoreActionStore; enc_r_end(enc_r_begin(p)); }
    MTL4RenderPassDescriptor *m = [MTL4RenderPassDescriptor new]; m.colorAttachments[0].texture = tex_mtl(&MS); m.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    m.colorAttachments[0].loadAction = MTLLoadActionClear; m.colorAttachments[0].storeAction = MTLStoreActionStore; enc_r_end(enc_r_begin(m));
    const tex_t *zs[2] = {&Z, &Z2};
    for (int i = 0; i < 2; i++) { MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new]; id<MTLTexture> t = tex_mtl(zs[i]);
        p.depthAttachment.texture = t; p.depthAttachment.loadAction = MTLLoadActionClear; p.depthAttachment.storeAction = MTLStoreActionStore; p.depthAttachment.clearDepth = .75;
        p.stencilAttachment.texture = t; p.stencilAttachment.loadAction = MTLLoadActionClear; p.stencilAttachment.storeAction = MTLStoreActionStore; p.stencilAttachment.clearStencil = 0x33;
        enc_r_end(enc_r_begin(p)); }
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the fill completes"); mtl_drain();
}
typedef struct { uint8_t c[W * W * 4], c1[W * W * 4], o[W * W * 4], md[W * W * 4], ms[W * W * 4], s[W * W]; float z[W * W]; uint64_t lfc, dsd, msr, split; } shot_t;
static id<MTLBuffer> rb_buf(size_t n) { id<MTLBuffer> b = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared]; res_add(b); return b; }
static void rb_tex(id<MTLTexture> t, id<MTLBuffer> b, size_t bpp, MTLBlitOption o) {
    [blit() copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:W * bpp destinationBytesPerImage:W * W * bpp options:o];
}
static id<MTLTexture> g_rb;   // the samples resolved again for the read-back
static shot_t finish(void) {
    rp_end(); if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    MTL4RenderPassDescriptor *m = [MTL4RenderPassDescriptor new]; m.colorAttachments[0].texture = tex_mtl(&MS); m.colorAttachments[0].resolveTexture = g_rb;
    m.colorAttachments[0].loadAction = MTLLoadActionLoad; m.colorAttachments[0].storeAction = MTLStoreActionStoreAndMultisampleResolve; enc_r_end(enc_r_begin(m));
    id<MTLBuffer> b[7]; for (int i = 0; i < 5; i++) b[i] = rb_buf(W * W * 4); b[5] = rb_buf(W * W * 4); b[6] = rb_buf(W * W);
    rb_tex(tex_mtl(&C), b[0], 4, 0); rb_tex(tex_mtl(&C1), b[1], 4, 0); rb_tex(tex_mtl(&O), b[2], 4, 0); rb_tex(tex_mtl(&MD), b[3], 4, 0); rb_tex(g_rb, b[4], 4, 0);
    rb_tex(tex_mtl(&Z), b[5], 4, MTLBlitOptionDepthFromDepthStencil); rb_tex(tex_mtl(&Z), b[6], 1, MTLBlitOptionStencilFromDepthStencil);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes"); mtl_drain();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    shot_t s; memcpy(s.c, b[0].contents, sizeof s.c); memcpy(s.c1, b[1].contents, sizeof s.c1); memcpy(s.o, b[2].contents, sizeof s.o); memcpy(s.md, b[3].contents, sizeof s.md);
    memcpy(s.ms, b[4].contents, sizeof s.ms); memcpy(s.z, b[5].contents, sizeof s.z); memcpy(s.s, b[6].contents, sizeof s.s);
    s.lfc = g_lfc_n; s.dsd = g_dsd_n; s.msr = g_msr_n; s.split = g_ldc_split; return s;
}
static int area(const uint8_t *p, int x0, int x1, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    for (int y = 0; y < W; y++) for (int x = x0; x < x1; x++) { const uint8_t *q = p + (y * W + x) * 4; if (q[0] != r || q[1] != g || q[2] != b || q[3] != a) return 0; }
    return 1;
}
static int depth_is(const shot_t *s, float z, uint8_t st) { for (int i = 0; i < W * W; i++) if (s->z[i] != z || s->s[i] != st) return 0; return 1; }
enum { CASES = 15 };
static const char *names[CASES] = {
    "(a) a target cleared whole before any draw writes it", "(a) a scissored clear: loaded", "(a) a draw into it before the clear: loaded",
    "(b) depth and stencil cleared whole before any read", "(b) the depth alone cleared whole: the stencil stored", "(b) a clear of another depth target first, then this one's",
    "(b) a draw between: stored", "(b) a scissored clear: stored", "(b) the clear past the command list's end: stored", "(b) another texture object over the same memory: stored",
    "(b) a masked stencil clear: stored",
    "(c) the samples cleared whole after the resolve", "(c) the samples drawn over after the resolve: stored", "(c) nothing after the resolve: stored", "(a) the clear cannot be drawn: the target keeps its memory"};
static shot_t run_case(int k) {
    fill(); static uint64_t f; mtl_set_frame(++f);
    state_reset(); memset(&R, 0, sizeof R); S.ds = (ds_st){.dt = 1, .dw = 1, .df = NVN_DEPTH_FUNC_ALWAYS};
    mtl_sub_begin();
    switch (k) {
        case 0: set_rt(&C, &C1, NULL); scissor(0, W); draw_op(&p0); clear_c(1, 1, 0, 1, 1); draw_op(&p0); exec_ops(); break;
        case 1: set_rt(&C, &C1, NULL); draw_op(&p0); scissor(0, W / 2); clear_c(1, 1, 0, 1, 1); scissor(0, W); draw_op(&p0); exec_ops(); break;
        case 2: set_rt(&C, &C1, NULL); scissor(0, W); draw_op(&p0); scissor(0, W / 2); draw_op(&p01); scissor(0, W); clear_c(1, 1, 0, 1, 1); exec_ops(); break;
        case 3: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, &Z); clear_ds(.25, 7, 0xff); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 4: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, &Z); clear_ds(.25, 7, 0); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 5: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, &Z2); clear_ds(.5, 9, 0xff); set_rt(&O, NULL, &Z); clear_ds(.25, 7, 0xff); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 6: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, NULL); draw_op(&p0); set_rt(&O, NULL, &Z); clear_ds(.25, 7, 0xff); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 7: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, &Z); scissor(0, W / 2); clear_ds(.25, 7, 0xff); scissor(0, W); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 8: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, NULL); exec_ops(); set_rt(&O, NULL, &Z); clear_ds(.25, 7, 0xff); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 9: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, &ZA); clear_ds(.25, 7, 0xff); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 10: set_rt(&C, NULL, &Z); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&O, NULL, &Z); clear_ds(.25, 7, 0x0f); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 11: set_rt(&MS, NULL, NULL); draw_op(&p0); resolve_op(); set_rt(&MS, NULL, NULL); clear_c(0, 0, 0, 1, 1); set_rt(&O, NULL, NULL); exec_ops(); break;
        case 12: set_rt(&MS, NULL, NULL); scissor(0, W / 2); draw_op(&p0); resolve_op(); set_rt(&MS, NULL, NULL); scissor(W / 2, W / 2); draw_op(&p0); scissor(0, W); exec_ops(); break;
        case 13: set_rt(&MS, NULL, NULL); draw_op(&p0); resolve_op(); exec_ops(); break;
        case 14: g_clr_fail_test = 1; set_rt(&C, &C1, NULL); scissor(0, W); draw_op(&p0); clear_c(1, 1, 0, 1, 1); draw_op(&p0); exec_ops(); rp_end(); g_clr_fail_test = 0; break;   // the clear triangle's pipeline fails
    }
    return finish();
}
static int flt_cmp_d(const double *a, const double *b) { return *a < *b ? -1 : *a > *b; }
static void set_rules(int on) { g_lfc_on = g_dsd_on = g_msr_on = on; }
// --bench: rule (b)'s shape at 2048x2048 (a colour + D32S8 pass, then the depth cleared whole for a pass into another target), 200 frames a run, rules off and on in turn; the
// wall time from the first submission to the last one's completion, which the GPU's passes dominate
static tex_t BC, BO, BZ;
static double bench_run(int on) {
    set_rules(on); uint64_t t0 = bp_now();
    for (int fr = 0; fr < 200; fr++) { static uint64_t f = 5000; mtl_set_frame(++f); state_reset(); memset(&R, 0, sizeof R); S.ds = (ds_st){.dt = 1, .dw = 1, .df = NVN_DEPTH_FUNC_ALWAYS};
        mtl_sub_begin(); set_rt(&BC, NULL, &BZ); clear_ds(1, 0x5a, 0xff); draw_op(&p0); set_rt(&BO, NULL, &BZ); clear_ds(.25, 7, 0xff); draw_op(&p0); set_rt(&BC, NULL, NULL); exec_ops(); rp_end();
        uint64_t fe = mtl_sub_commit(); if (fr == 199) CHECK(mtl_wait(fe, 5000000000ull), "the bench completes"); }
    mtl_drain(); return (double)(bp_now() - t0) / 1e6;
}
int main(int argc, char **argv) { @autoreleasepool {
    mtl_init();
    void *gm = NULL; posix_memalign(&gm, 16384, 16 << 20); memset(gm, 0, 16 << 20);
    gpool = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem = gm, .size = 16 << 20};
    C = target(99811, 0, NVN_FORMAT_RGBA8, 1); C1 = target(99812, 1 << 20, NVN_FORMAT_RGBA8, 1); O = target(99813, 2 << 20, NVN_FORMAT_RGBA8, 1);
    Z = target(99814, 3 << 20, NVN_FORMAT_DEPTH32F_STENCIL8, 1); Z2 = target(99815, 4 << 20, NVN_FORMAT_DEPTH32F_STENCIL8, 1);
    MS = target(99817, 6 << 20, NVN_FORMAT_RGBA8, 4); MD = target(99818, 8 << 20, NVN_FORMAT_RGBA8, 1);
    ZA = Z; ZA.serial = 99816;   // the same memory under another texture object
    if (argc > 1 && !strcmp(argv[1], "--bench")) {
        void *bm = NULL; posix_memalign(&bm, 16384, 64 << 20); memset(bm, 0, 64 << 20);
        static pool_t bpool; bpool = gpool; bpool.mem = bm; bpool.size = 64 << 20;
        tex_t *bt[3] = {&BC, &BO, &BZ}; NVNformat bf[3] = {NVN_FORMAT_RGBA8, NVN_FORMAT_RGBA8, NVN_FORMAT_DEPTH32F_STENCIL8};
        for (int i = 0; i < 3; i++) { *bt[i] = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 99830 + (uint64_t)i, .pool = &bpool, .mem = bpool.mem + ((int64_t)i << 24), .off = (int64_t)i << 24};
            bt[i]->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = bf[i], .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = 2048, .height = 2048, .depth = 1, .levels = 1, .samples = 1};
            nvn_tex_layout(&bt[i]->d, &bt[i]->L); mtl_tex_init(bt[i]);
            MTLTextureDescriptor *d = tex_desc(bt[i], 0); d.usage |= MTLTextureUsageRenderTarget; id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; res_add(mt); serial_put(bt[i]->serial, mt); }
        argc = 0; }
    tex_t *all[7] = {&C, &C1, &O, &Z, &Z2, &MS, &MD};
    for (int i = 0; i < 7; i++) { MTLTextureDescriptor *d = tex_desc(all[i], 0); d.usage |= MTLTextureUsageRenderTarget;
        id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; CHECK(mt != nil, "target allocates"); if (!mt) return 1;
        res_add(mt); serial_put(all[i]->serial, mt); }   // NOLINT(clang-analyzer-osx.cocoa.RetainCount): g_by_serial owns them
    { MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:W mipmapped:NO]; d.usage = MTLTextureUsageRenderTarget; d.storageMode = MTLStorageModePrivate;
      g_rb = [g_dev newTextureWithDescriptor:d]; res_add(g_rb); }
    CHECK(dsd_tex_ok(&Z, tex_mtl(&Z)) && dsd_tex_ok(&MS, tex_mtl(&MS)), "the GPU-only targets are eligible");
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, .5, 1); }\n"
        "fragment float4 one() { return float4(0, 1, 0, 1); }\n"
        "struct O { float4 a [[color(0)]]; float4 b [[color(1)]]; }; fragment O two() { O o; o.a = float4(0, 1, 0, 1); o.b = float4(1, 0, 0, 1); return o; }\n", nil, &error);
    CHECK(lib != nil, "the test shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvShader *vs = [NvShader new]; vs->fn = t4_fn(lib, @"v");
    struct { prog_t *p; NSString *fn; uint32_t mask; } pp[2] = {{&p0, @"one", 1}, {&p01, @"two", 3}};
    for (int i = 0; i < 2; i++) { NvProg *p = [NvProg new]; p->sh[0] = vs; p->sh[1] = [NvShader new]; p->sh[1]->fn = t4_fn(lib, pp[i].fn); p->sh[1]->stage = 1;
        p->sh[1]->rf.color_known = 1; p->sh[1]->rf.color_mask = pp[i].mask; serial_put(pp[i].p->serial, p); }
    if (BZ.serial) {
        bench_run(0); bench_run(1);   // warm the pipelines
        double t[2][5]; uint64_t d0 = g_dsd_bytes;
        for (int r = 0; r < 5; r++) { t[0][r] = bench_run(0); t[1][r] = bench_run(1); }
        for (int k = 0; k < 2; k++) qsort(t[k], 5, sizeof(double), (int (*)(const void *, const void *))flt_cmp_d);
        printf("bench 2048x2048, 200 frames: rules off median %.1f ms, on %.1f ms (%.3f / %.3f ms a frame); depth / stencil bytes not stored per frame %.1f MB\n", t[0][2], t[1][2], t[0][2] / 200, t[1][2] / 200,
               (double)(g_dsd_bytes - d0) / 5 / 200 / 1048576.0);
        printf("load / store reductions: %d checks, %d failed\n", checks, failed); return failed != 0; }
    // per case: rule (a) loads skipped, rule (b) planes not stored, rule (c) resolves storing only the resolve
    const uint64_t want_lfc[CASES] = {1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1}, want_dsd[CASES] = {0, 0, 0, 2, 1, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0},
                   want_msr[CASES] = {0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0};
    for (int k = 0; k < CASES; k++) {
        set_rules(0); shot_t b0 = {.lfc = g_lfc_n, .dsd = g_dsd_n, .msr = g_msr_n}; shot_t off = run_case(k);
        CHECK(off.lfc == b0.lfc && off.dsd == b0.dsd && off.msr == b0.msr, "off: no rule fires");
        set_rules(1); shot_t b1 = {.lfc = g_lfc_n, .dsd = g_dsd_n, .msr = g_msr_n, .split = g_ldc_split}; shot_t on = run_case(k);
        int same = !memcmp(on.c, off.c, sizeof on.c) && !memcmp(on.c1, off.c1, sizeof on.c1) && !memcmp(on.o, off.o, sizeof on.o) && !memcmp(on.md, off.md, sizeof on.md)
                   && !memcmp(on.ms, off.ms, sizeof on.ms) && !memcmp(on.z, off.z, sizeof on.z) && !memcmp(on.s, off.s, sizeof on.s);
        CHECK(same, names[k]);
        uint64_t lfc = on.lfc - b1.lfc, dsd = on.dsd - b1.dsd, msr = on.msr - b1.msr;
        CHECK(lfc == want_lfc[k] && dsd == want_dsd[k] && msr == want_msr[k], "the rules fire where expected");
        CHECK(on.split == b1.split, "no pass end forced");
        int lit = 1;
        switch (k) {
            case 0: lit = area(on.c, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W, 255, 0, 255, 255); break;
            case 1: lit = area(on.c, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W / 2, 255, 0, 255, 255) && area(on.c1, W / 2, W, 255, 255, 0, 255); break;
            case 2: lit = area(on.c, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W, 255, 0, 255, 255); break;
            case 3: case 5: lit = area(on.c, 0, W, 0, 255, 0, 255) && depth_is(&on, .25f, 7); break;
            case 4: lit = area(on.c, 0, W, 0, 255, 0, 255) && depth_is(&on, .25f, 0x5a); break;
            case 6: lit = area(on.o, 0, W, 0, 255, 0, 255) && depth_is(&on, .25f, 7); break;
            case 7: for (int y = 0; y < W; y++) for (int x = 0; x < W; x++) lit &= on.z[y * W + x] == (x < W / 2 ? .25f : .5f) && on.s[y * W + x] == (x < W / 2 ? 7 : 0x5a); break;
            case 8: lit = depth_is(&on, .25f, 7); break;
            case 9: break;   // the other object's texture is the replay's to choose: the read-backs match
            case 10: lit = depth_is(&on, .25f, 0x57); break;   // 0x5a with the low four bits replaced by 7's
            case 11: lit = area(on.md, 0, W, 0, 255, 0, 255) && area(on.ms, 0, W, 0, 0, 255, 255); break;
            case 12: lit = area(on.md, 0, W / 2, 0, 255, 0, 255) && area(on.md, W / 2, W, 255, 0, 0, 255) && area(on.ms, 0, W, 0, 255, 0, 255); break;
            case 13: lit = area(on.md, 0, W, 0, 255, 0, 255) && area(on.ms, 0, W, 0, 255, 0, 255); break;
            case 14: lit = area(on.c, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W, 255, 255, 0, 255); break;   // no clear drawn: target 1 keeps the fill's yellow, not an unloaded tile
        }
        CHECK(lit, "the targets hold the literal values");
        printf("case %2d %s: %s (loads skipped %llu, depth / stencil stores dropped %llu, sample stores dropped %llu)\n", k, names[k], same && lit ? "PASS" : "FAIL",
               (unsigned long long)lfc, (unsigned long long)dsd, (unsigned long long)msr);
    }
    // DM_NVN_LS_STATS: a frame stores C and Z and the next clears them whole: their stores count as cleared with no use between (not in the texture pool), O's as loaded again
    {   set_rules(0); g_ls_on = 1; ls_frame(1000);
        fill(); state_reset(); memset(&R, 0, sizeof R); S.ds = (ds_st){.dt = 1, .dw = 1, .df = NVN_DEPTH_FUNC_ALWAYS};
        mtl_sub_begin();   // both frames in one submission: the read-back is a use (tex_mtl, tu_stamp)
        for (int fr = 0; fr < 2; fr++) { mtl_set_frame(1001 + (uint64_t)fr); set_rt(&C, NULL, &Z); clear_c(0, 0, 0, 0, 1); clear_ds(1, 0, 0xff); draw_op(&p0); set_rt(&O, NULL, NULL); draw_op(&p0); exec_ops(); }
        finish();
        double dead = 0, again = 0, load = 0, store = 0, passes = 0; for (int i = 0; i <= LS_KINDS; i++) { dead += g_lsk[i].dead; again += g_lsk[i].again; load += g_lsk[i].load; store += g_lsk[i].store; passes += g_lsk[i].passes; }
        printf("ls-stats: passes %.0f, load %.0f, store %.0f, cleared unread %.0f, loaded again %.0f bytes\n", passes, load, store, dead, again);
        CHECK(passes == 4 && dead >= W * W * 4 + W * W * 5 && again >= W * W * 4, "the measurement sees the stores cleared unread and those loaded again");
        ls_frame(1000 + LS_WIN); g_ls_on = 0; }
    printf("load / store reductions: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
