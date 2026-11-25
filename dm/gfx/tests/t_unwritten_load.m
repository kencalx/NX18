// Colour attachments no draw of their pass writes are loaded as DontCare (nvn_mtl.m ldc_plan, DM_NVN_UNWRITTEN_LOAD), and stored as DontCare, so their memory stays as it was. Through the
// production replay, on two RGBA8 targets (blue, yellow) and a Depth32Float one: draws that write target 0 only, draws with target 1's channels masked off, depth-only draws, a draw
// that writes target 1 later in the pass (a same-target SetRenderTargets between), a draw the scan did not see (the next replay in the same submission: the pass ends before it), and a
// clear drawn as a triangle into a target loaded as DontCare (likewise). Each case runs with the switch on and off; the read-backs match byte for byte and hold the literal colours,
// and the loads skipped and the pass ends a draw forced are counted as expected.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { W = 8 };
static tex_t C0, C1, Z;
static prog_t p0 = {.serial = 99721}, p01 = {.serial = 99722}, pz = {.serial = 99723};   // writes target 0; writes 0 and 1; writes no colour
static uint8_t ops[4096]; static size_t nops;
static void *op(uint32_t code, size_t size) { op_hdr h = {code, (uint32_t)(sizeof h + size)}; memcpy(ops + nops, &h, sizeof h); void *a = ops + nops + sizeof h; memset(a, 0, size); nops += h.size; return a; }
static void set_rt(int depth) { p_set_rt r = {.n = 2, .depth = depth ? &Z : NULL}; r.color[0] = &C0; r.color[1] = &C1; *(p_set_rt *)op(OP_SET_RT, sizeof r) = r; }
static void scissor(int x, int w) { *(p_scissor *)op(OP_SCISSOR, sizeof(p_scissor)) = (p_scissor){x, 0, w, W}; }
static void chmask(uint32_t m) { p_bind_state *b = op(OP_BIND_STATE, sizeof(p_bind_state)); b->kind = 2; memcpy(b->bytes, &m, 4); }
static void draw_op(const prog_t *p) {
    *(p_bind_program *)op(OP_BIND_PROGRAM, sizeof(p_bind_program)) = (p_bind_program){p, 3};
    *(p_draw *)op(OP_DRAW, sizeof(p_draw)) = (p_draw){NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3};
}
static void exec_ops(void) { op(OP_END, 0); mtl_exec(ops); nops = 0; }
static void fill(void) {   // blue, yellow, depth 0.75, outside the replay
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = tex_mtl(&C0); p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
    p.colorAttachments[1].texture = tex_mtl(&C1); p.colorAttachments[1].clearColor = MTLClearColorMake(1, 1, 0, 1);
    for (int i = 0; i < 2; i++) { p.colorAttachments[i].loadAction = MTLLoadActionClear; p.colorAttachments[i].storeAction = MTLStoreActionStore; }
    p.depthAttachment.texture = tex_mtl(&Z); p.depthAttachment.loadAction = MTLLoadActionClear; p.depthAttachment.storeAction = MTLStoreActionStore; p.depthAttachment.clearDepth = .75;
    mtl_sub_begin(); enc_r_end(enc_r_begin(p)); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the fill completes"); mtl_drain();
}
typedef struct { uint8_t c0[W * W * 4], c1[W * W * 4]; float z[W * W]; uint64_t n, split; } shot_t;
static shot_t finish(void) {
    rp_end();
    id<MTLBuffer> b[3]; for (int i = 0; i < 3; i++) { b[i] = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; res_add(b[i]); }
    [blit() copyFromTexture:tex_mtl(&C0) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[0] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [blit() copyFromTexture:tex_mtl(&C1) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[1] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [blit() copyFromTexture:tex_mtl(&Z) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[2] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes"); mtl_drain();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    shot_t s; memcpy(s.c0, b[0].contents, sizeof s.c0); memcpy(s.c1, b[1].contents, sizeof s.c1); memcpy(s.z, b[2].contents, sizeof s.z);
    uint64_t bytes; mtl_ldc_stats(&s.n, &bytes, &s.split); return s;
}
// x in [x0, x1) of every row holds rgba
static int area(const uint8_t *p, int x0, int x1, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    for (int y = 0; y < W; y++) for (int x = x0; x < x1; x++) { const uint8_t *q = p + (y * W + x) * 4; if (q[0] != r || q[1] != g || q[2] != b || q[3] != a) return 0; }
    return 1;
}
enum { CASES = 7 };
static const char *names[CASES] = {"target 1 not drawn", "target 1's channels masked off", "depth-only draws", "target 1 drawn later in the pass", "a same-target SetRenderTargets, then target 1 drawn",
                                   "a draw the scan did not see", "a clear triangle into a target loaded as DontCare"};
static shot_t run_case(int k) {
    fill(); static uint64_t f; mtl_set_frame(++f);
    state_reset(); memset(&R, 0, sizeof R); S.ds = (ds_st){.dt = 1, .dw = 1, .df = NVN_DEPTH_FUNC_ALWAYS};
    mtl_sub_begin();
    switch (k) {
        case 0: set_rt(1); scissor(0, W); draw_op(&p0); draw_op(&p0); exec_ops(); break;
        case 1: set_rt(1); scissor(0, W); chmask(0xf); draw_op(&p01); chmask(0xffffffffu); exec_ops(); break;
        case 2: set_rt(1); scissor(0, W); draw_op(&pz); draw_op(&pz); exec_ops(); break;
        case 3: set_rt(0); scissor(0, W); draw_op(&p0); scissor(0, W / 2); draw_op(&p01); exec_ops(); break;
        case 4: set_rt(0); scissor(0, W); draw_op(&p0); set_rt(0); scissor(0, W / 2); draw_op(&p01); exec_ops(); break;
        case 5: set_rt(0); scissor(0, W); draw_op(&p0); exec_ops(); scissor(0, W / 2); draw_op(&p01); exec_ops(); break;
        case 6: set_rt(0); scissor(0, W); draw_op(&p0); exec_ops(); scissor(0, W / 2);
                *(p_clear_color *)op(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){1, 0xf, {1, 0, 1, 1}}; exec_ops(); break;
    }
    return finish();
}
int main(void) { @autoreleasepool {
    mtl_init();
    C0 = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 99724}; C0.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = W, .height = W, .depth = 1, .levels = 1, .samples = 1};
    C1 = C0; C1.serial = 99725; Z = C0; Z.serial = 99726; Z.d.format = NVN_FORMAT_DEPTH32F;
    tex_t *all[3] = {&C0, &C1, &Z};
    for (int i = 0; i < 3; i++) { MTLTextureDescriptor *d = tex_desc(all[i], 0); d.usage |= MTLTextureUsageRenderTarget;
        id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; CHECK(mt != nil, "target allocates"); if (!mt) return 1;
        res_add(mt); mtl_tex_init(all[i]); serial_put(all[i]->serial, mt); }   // NOLINT(clang-analyzer-osx.cocoa.RetainCount): g_by_serial owns them
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, .5, 1); }\n"
        "fragment float4 one() { return float4(0, 1, 0, 1); }\n"
        "struct O { float4 a [[color(0)]]; float4 b [[color(1)]]; }; fragment O two() { O o; o.a = float4(0, 1, 0, 1); o.b = float4(1, 0, 0, 1); return o; }\n"
        "fragment void none() {}\n", nil, &error);
    CHECK(lib != nil, "the test shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvShader *vs = [NvShader new]; vs->fn = t4_fn(lib, @"v");
    struct { prog_t *p; NSString *fn; uint32_t mask; } pp[3] = {{&p0, @"one", 1}, {&p01, @"two", 3}, {&pz, @"none", 0}};
    for (int i = 0; i < 3; i++) { NvProg *p = [NvProg new]; p->sh[0] = vs; p->sh[1] = [NvShader new]; p->sh[1]->fn = t4_fn(lib, pp[i].fn); p->sh[1]->stage = 1;
        p->sh[1]->rf.color_known = 1; p->sh[1]->rf.color_mask = pp[i].mask; serial_put(pp[i].p->serial, p); }
    // what each case loads as DontCare and how many pass ends a draw forces (on)
    const uint64_t want_n[CASES] = {1, 1, 2, 0, 0, 1, 1}, want_split[CASES] = {0, 0, 0, 0, 0, 1, 1};
    for (int k = 0; k < CASES; k++) {
        uint64_t n0, b0, s0; mtl_ldc_stats(&n0, &b0, &s0);
        g_ldc_on = 0; shot_t off = run_case(k);
        CHECK(off.n == n0 && off.split == s0, "off: nothing loaded as DontCare");
        g_ldc_on = 1; shot_t on = run_case(k); shot_t base = {.n = n0, .split = s0};
        int same = !memcmp(on.c0, off.c0, sizeof on.c0) && !memcmp(on.c1, off.c1, sizeof on.c1) && !memcmp(on.z, off.z, sizeof on.z);
        CHECK(same, names[k]);
        CHECK(on.n - base.n == want_n[k] && on.split - base.split == want_split[k], "loads skipped and pass ends as expected");
        int lit = 1;
        switch (k) {
            case 0: lit = area(on.c0, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W, 255, 255, 0, 255); break;
            case 1: lit = area(on.c0, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W, 255, 255, 0, 255); break;
            case 2: lit = area(on.c0, 0, W, 0, 0, 255, 255) && area(on.c1, 0, W, 255, 255, 0, 255); for (int i = 0; i < W * W; i++) lit &= on.z[i] == .5f; break;
            case 3: case 4: case 5: lit = area(on.c0, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W / 2, 255, 0, 0, 255) && area(on.c1, W / 2, W, 255, 255, 0, 255); break;
            case 6: lit = area(on.c0, 0, W, 0, 255, 0, 255) && area(on.c1, 0, W / 2, 255, 0, 255, 255) && area(on.c1, W / 2, W, 255, 255, 0, 255); break;
        }
        CHECK(lit, "the targets hold the literal colours");
        printf("case %d (%s): %s, loads skipped %llu, pass ends forced %llu\n", k, names[k], same && lit ? "PASS" : "FAIL", (unsigned long long)(on.n - base.n), (unsigned long long)(on.split - base.split));
    }
    printf("unwritten loads: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
