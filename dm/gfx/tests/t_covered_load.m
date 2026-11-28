// Colour attachments the pass's opening draw covers whole load as DontCare (nvn_mtl.m lcv_plan / lcv_check / lcv_confirm, DM_NVN_COVERED_LOAD, rule (d)). Through the production
// replay, on two RGBA8 targets filled outside the replay (blue, yellow) and a Depth32Float one (0.75), with a vertex shader whose position is its attribute (pos_attr) and the
// positions in guest memory: converted are a full-screen triangle, a quad of two listed triangles, a strip, an indexed quad, a draw writing both targets, pass-through blending,
// a depth test that always passes, and a cover draw followed by a partial one in the same pass. Kept loaded (negative controls) are a partial scissor, blending that reads the
// target, a fragment shader that may discard, a depth test that can fail, a channel write mask, half the screen, a partial viewport, back-face culling, positions a GPU copy in
// the same submission writes (the CPU's bytes are stale: they say full screen, the copy makes it half), and a vertex shader whose position is not provable. Each case runs with
// the switch on and off: the read-backs match byte for byte and hold the literal colours, and the loads converted (attachments and passes) are counted as expected, with no
// planned load left unconfirmed and no pass ended for a write. check_t_covered_load runs it under the validation layer's load-action check, which fills DontCare loads with
// its pattern: a converted attachment the draw did not cover whole would show it. Last, the plan's cost (lcv_check on a full-screen quad).
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
static tex_t C0, C1, Z;
static prog_t p_one = {.serial = 99821}, p_two = {.serial = 99822}, p_half = {.serial = 99823}, p_disc = {.serial = 99824}, p_red = {.serial = 99825}, p_unp = {.serial = 99826};
static uint8_t ops[16384] __attribute__((aligned(8))); static size_t nops;
static uint8_t *mem;   // guest memory: vertices and indices
enum { V_TRI = 0, V_QUAD = 256, V_STRIP = 512, V_IQUAD = 768, V_HALF = 1024, V_FAR = 1280, V_GPU = 1536, V_SRC = 1792, I_QUAD = 2048 };
static void *op(uint32_t code, size_t size) { size_t sz = (sizeof(op_hdr) + size + 7) & ~(size_t)7; op_hdr h = {code, (uint32_t)sz}; memcpy(ops + nops, &h, sizeof h); void *a = ops + nops + sizeof h; memset(a, 0, sz - sizeof h); nops += sz; return a; }
static void t_set_rt(int n, int depth) { p_set_rt r = {.n = n, .depth = depth ? &Z : NULL}; r.color[0] = &C0; if (n > 1) r.color[1] = &C1; *(p_set_rt *)op(OP_SET_RT, sizeof r) = r; }
static void t_scissor(int x, int w) { *(p_scissor *)op(OP_SCISSOR, sizeof(p_scissor)) = (p_scissor){x, 0, w, W}; }
static void t_state(int kind, const void *v, size_t n) { p_bind_state *b = op(OP_BIND_STATE, sizeof(p_bind_state)); b->kind = kind; memcpy(b->bytes, v, n); }
static void t_chmask(uint32_t m) { t_state(2, &m, 4); }
static void t_ds(ds_st d) { t_state(5, &d, sizeof d); }
static void t_blend(int on, int src, int dst) { blend_st b = {.target = 0, .src_rgb = (uint64_t)src, .dst_rgb = (uint64_t)dst, .src_a = NVN_BLEND_FUNC_ONE, .dst_a = NVN_BLEND_FUNC_ZERO, .eq_rgb = NVN_BLEND_EQUATION_ADD, .eq_a = NVN_BLEND_EQUATION_ADD};
    t_state(0, &b, sizeof b); color_st c = {.blend_en = on ? 1 : 0}; t_state(1, &c, sizeof c); }
static void t_cull(int face) { poly_st p = {.cull = (uint32_t)face, .front = 0, .mode = NVN_POLYGON_MODE_FILL}; t_state(4, &p, sizeof p); }
static void t_verts(int off) {   // the position stream: RGBA32F at mem + off, stride 16
    struct { int32_t first, n; va_st attr; } a = {0, 1, {.fmt = NVN_FORMAT_RGBA32F}}; memcpy(op(OP_BIND_VATTR, sizeof a), &a, sizeof a);
    struct { int32_t first, n; vs_st stream; } s = {0, 1, {.stride = 16}}; memcpy(op(OP_BIND_VSTREAM, sizeof s), &s, sizeof s);
    *(p_bind_vbuf1 *)op(OP_BIND_VBUF1, sizeof(p_bind_vbuf1)) = (p_bind_vbuf1){.index = 0, .size = 256, .addr = (uint64_t)(uintptr_t)(mem + off)}; }
static void t_program(const prog_t *p) { *(p_bind_program *)op(OP_BIND_PROGRAM, sizeof(p_bind_program)) = (p_bind_program){p, 3}; }
static void t_draw(int prim, int count) { *(p_draw *)op(OP_DRAW, sizeof(p_draw)) = (p_draw){.prim = prim, .count = count, .instances = 1}; }
static void t_draw_idx(int count) { *(p_draw_idx *)op(OP_DRAW_IDX, sizeof(p_draw_idx)) = (p_draw_idx){.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .itype = 1, .count = count, .instances = 1, .ibuf = (uint64_t)(uintptr_t)(mem + I_QUAD)}; }
static void t_viewport(float x, float w) { p_viewports *v = op(OP_VIEWPORTS, sizeof(p_viewports)); v->n = 1; v->v[0][0] = x; v->v[0][2] = w; v->v[0][3] = W; }
static void exec_ops(void) { op(OP_END, 0); mtl_exec(ops); nops = 0; }
static void t_fill(void) {   // blue, yellow, depth 0.75, outside the replay
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = tex_mtl(&C0); p.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 1, 1);
    p.colorAttachments[1].texture = tex_mtl(&C1); p.colorAttachments[1].clearColor = MTLClearColorMake(1, 1, 0, 1);
    for (int i = 0; i < 2; i++) { p.colorAttachments[i].loadAction = MTLLoadActionClear; p.colorAttachments[i].storeAction = MTLStoreActionStore; }
    p.depthAttachment.texture = tex_mtl(&Z); p.depthAttachment.loadAction = MTLLoadActionClear; p.depthAttachment.storeAction = MTLStoreActionStore; p.depthAttachment.clearDepth = .75;
    mtl_sub_begin(); enc_r_end(enc_r_begin(p)); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the fill completes"); mtl_drain();
}
typedef struct { uint8_t c0[W * W * 4], c1[W * W * 4]; uint64_t lcv[4], split; } shot_t;
static void counters(shot_t *s) { mtl_lcv_stats(s->lcv); uint64_t n, b; mtl_ldc_stats(&n, &b, &s->split); }
static shot_t finish(void) {
    rp_end();
    id<MTLBuffer> b[2]; for (int i = 0; i < 2; i++) { b[i] = [g_dev newBufferWithLength:W * W * 4 options:MTLResourceStorageModeShared]; res_add(b[i]); }
    [blit() copyFromTexture:tex_mtl(&C0) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[0] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    [blit() copyFromTexture:tex_mtl(&C1) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, W, 1) toBuffer:b[1] destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * W * 4];
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes"); mtl_drain();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    shot_t s; memcpy(s.c0, b[0].contents, sizeof s.c0); memcpy(s.c1, b[1].contents, sizeof s.c1); counters(&s); return s;
}
// x in [x0, x1) of every row holds rgba
static int t_area(const uint8_t *p, int x0, int x1, uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    for (int y = 0; y < W; y++) for (int x = x0; x < x1; x++) { const uint8_t *q = p + (y * W + x) * 4; if (q[0] != r || q[1] != g || q[2] != b || q[3] != a) return 0; }
    return 1;
}
static int t_count(const uint8_t *p, uint8_t r, uint8_t g, uint8_t b) { int n = 0; for (int i = 0; i < W * W; i++) n += p[4 * i] == r && p[4 * i + 1] == g && p[4 * i + 2] == b; return n; }
enum { CASES = 18, CONVERTED = 8 };
static const char *names[CASES] = {"full-screen triangle", "quad of two listed triangles", "quad as a strip", "indexed quad", "a draw writing both targets", "pass-through blending",
    "depth test always", "cover draw, then a partial draw in the pass",
    "partial scissor", "blending that reads the target", "a fragment shader that may discard", "a depth test that can fail", "channel write mask", "half the screen",
    "partial viewport", "back faces culled", "positions a GPU copy in the submission writes", "position not provable"};
static const ds_st ds_off = {.df = NVN_DEPTH_FUNC_ALWAYS};
static shot_t run_case(int k) {
    t_fill(); static uint64_t f; mtl_set_frame(++f);
    state_reset(); memset(&R, 0, sizeof R);
    mtl_sub_begin();
    switch (k) {
        case 0: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 1: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_one); t_verts(V_QUAD); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 6); break;
        case 2: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_one); t_verts(V_STRIP); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLE_STRIP, 4); break;
        case 3: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_one); t_verts(V_IQUAD); t_draw_idx(6); break;
        case 4: t_set_rt(2, 0); t_ds(ds_off); t_program(&p_two); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 5: t_set_rt(1, 0); t_ds(ds_off); t_blend(1, NVN_BLEND_FUNC_ONE, NVN_BLEND_FUNC_ZERO); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 6: t_set_rt(1, 1); t_ds((ds_st){.dt = 1, .dw = 1, .df = NVN_DEPTH_FUNC_ALWAYS}); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 7: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); t_scissor(0, W / 2); t_program(&p_red); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 8: t_set_rt(1, 0); t_ds(ds_off); t_scissor(0, W / 2); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 9: t_set_rt(1, 0); t_ds(ds_off); t_blend(1, NVN_BLEND_FUNC_SRC_ALPHA, NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA); t_program(&p_half); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 10: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_disc); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 11: t_set_rt(1, 1); t_ds((ds_st){.dt = 1, .df = NVN_DEPTH_FUNC_LESS}); t_program(&p_one); t_verts(V_FAR); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 12: t_set_rt(1, 0); t_ds(ds_off); t_chmask(0x3); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 13: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_one); t_verts(V_HALF); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 14: t_set_rt(1, 0); t_ds(ds_off); t_viewport(0, W / 2); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 15: t_set_rt(1, 0); t_ds(ds_off); t_cull(NVN_FACE_BACK); t_program(&p_one); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
        case 16: { memcpy(mem + V_GPU, mem + V_TRI, 48);   // the CPU's bytes: full screen again (the last run's copy left half there)
                   t_set_rt(1, 0); t_ds(ds_off); struct { uint64_t src, dst, n; } c = {(uint64_t)(uintptr_t)(mem + V_SRC), (uint64_t)(uintptr_t)(mem + V_GPU), 48};
                   memcpy(op(OP_COPY_B2B, sizeof c), &c, sizeof c); t_program(&p_one); t_verts(V_GPU); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break; }
        case 17: t_set_rt(1, 0); t_ds(ds_off); t_program(&p_unp); t_verts(V_TRI); t_draw(NVN_DRAW_PRIMITIVE_TRIANGLES, 3); break;
    }
    exec_ops();
    return finish();
}
static void t_put(int off, const float (*v)[4], int n) { memcpy(mem + off, v, (size_t)n * 16); }
int main(void) { @autoreleasepool {
    mtl_init();
    C0 = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 99827}; C0.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = W, .height = W, .depth = 1, .levels = 1, .samples = 1};
    C1 = C0; C1.serial = 99828; Z = C0; Z.serial = 99829; Z.d.format = NVN_FORMAT_DEPTH32F;
    tex_t *all[3] = {&C0, &C1, &Z};
    for (int i = 0; i < 3; i++) { MTLTextureDescriptor *d = tex_desc(all[i], 0); d.usage |= MTLTextureUsageRenderTarget;
        id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; CHECK(mt != nil, "target allocates"); if (!mt) return 1;
        res_add(mt); mtl_tex_init(all[i]); serial_put(all[i]->serial, mt); }   // NOLINT(clang-analyzer-osx.cocoa.RetainCount): g_by_serial owns them
    void *m = NULL; CHECK(!posix_memalign(&m, (size_t)getpagesize(), 65536), "guest memory allocated"); if (!m) return 1;
    mem = m; memset(mem, 0, 65536); mtl_pool_add(mem, 65536);
    const float tri[3][4] = {{-1, -1, .5f, 1}, {3, -1, .5f, 1}, {-1, 3, .5f, 1}};
    const float quad[6][4] = {{-1, -1, .5f, 1}, {1, -1, .5f, 1}, {1, 1, .5f, 1}, {-1, -1, .5f, 1}, {1, 1, .5f, 1}, {-1, 1, .5f, 1}};
    const float strip[4][4] = {{-1, -1, .5f, 1}, {1, -1, .5f, 1}, {-1, 1, .5f, 1}, {1, 1, .5f, 1}};
    const float half[3][4] = {{-1, -1, .5f, 1}, {1, -1, .5f, 1}, {-1, 1, .5f, 1}};
    const float far_[3][4] = {{-1, -1, .9f, 1}, {3, -1, .9f, 1}, {-1, 3, .9f, 1}};
    const uint16_t idx[6] = {0, 1, 2, 0, 2, 3};
    t_put(V_TRI, tri, 3); t_put(V_QUAD, quad, 6); t_put(V_STRIP, strip, 4); t_put(V_IQUAD, (const float (*)[4])quad, 3); memcpy(mem + V_IQUAD + 48, quad[5], 16);
    t_put(V_HALF, half, 3); t_put(V_FAR, far_, 3); t_put(V_GPU, tri, 3); t_put(V_SRC, half, 3); memcpy(mem + I_QUAD, idx, sizeof idx);
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct I { float4 p [[attribute(0)]]; };\n"
        "vertex float4 v(I i [[stage_in]]) { return i.p; }\n"
        "fragment float4 one() { return float4(0, 1, 0, 1); }\n"
        "fragment float4 red() { return float4(1, 0, 0, 1); }\n"
        "fragment float4 half_() { return float4(0, 1, 0, .5); }\n"
        "fragment float4 disc(float4 p [[position]]) { if (p.x < 8) discard_fragment(); return float4(0, 1, 0, 1); }\n"
        "struct O { float4 a [[color(0)]]; float4 b [[color(1)]]; }; fragment O two() { O o; o.a = float4(0, 1, 0, 1); o.b = float4(1, 0, 0, 1); return o; }\n", nil, &error);
    CHECK(lib != nil, "the test shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NvShader *vs = [NvShader new], *vu = [NvShader new];
    for (int i = 0; i < 2; i++) { NvShader *s = i ? vu : vs; s->fn = t4_fn(lib, @"v"); s->rf.nv = 1; s->rf.v[0].loc = 0; s->rf.v[0].nvn = 0; s->rf.v[0].ct = NVN_CT_FLOAT; memset(s->rf.v[0].sh, 0xff, sizeof s->rf.v[0].sh); }
    vs->rf.pos_attr = 0; vu->rf.pos_attr = -1;   // position x / y / z / w as the attribute's (pos_w from the attribute), and one the reflection could not prove
    struct { prog_t *p; NSString *fn; uint32_t mask; int disc; NvShader *v; } pp[6] = {{&p_one, @"one", 1, 0, vs}, {&p_two, @"two", 3, 0, vs}, {&p_half, @"half_", 1, 0, vs}, {&p_disc, @"disc", 1, 1, vs}, {&p_red, @"red", 1, 0, vs}, {&p_unp, @"one", 1, 0, vu}};
    for (int i = 0; i < 6; i++) { NvProg *p = [NvProg new]; p->sh[0] = pp[i].v; p->sh[1] = [NvShader new]; p->sh[1]->fn = t4_fn(lib, pp[i].fn); p->sh[1]->stage = 1;
        p->sh[1]->rf.color_known = 1; p->sh[1]->rf.color_mask = pp[i].mask; p->sh[1]->rf.may_discard = (uint8_t)pp[i].disc; serial_put(pp[i].p->serial, p); }
    const uint64_t want_n[CASES] = {1, 1, 1, 1, 2, 1, 1, 1};   // attachments converted with the switch on (the rest: none)
    for (int k = 0; k < CASES; k++) {
        shot_t b0; counters(&b0);
        g_lcv_on = 0; shot_t off = run_case(k);
        CHECK(off.lcv[0] == b0.lcv[0] && off.lcv[2] == b0.lcv[2], "off: nothing converted");
        shot_t b1; counters(&b1);
        g_lcv_on = 1; shot_t on = run_case(k);
        uint64_t n = on.lcv[0] - b1.lcv[0], np = on.lcv[2] - b1.lcv[2], miss = on.lcv[3] - b1.lcv[3], split = on.split - b1.split;
        int same = !memcmp(on.c0, off.c0, sizeof on.c0) && !memcmp(on.c1, off.c1, sizeof on.c1);
        CHECK(same, names[k]);
        CHECK(n == want_n[k] && np == (k < CONVERTED) && miss == 0 && split == 0, "loads converted as expected, none unconfirmed, no pass ended");
        int lit = 1;
        switch (k) {
            case 0: case 1: case 2: case 3: case 5: case 6: case 17: lit = t_area(on.c0, 0, W, 0, 255, 0, 255) && t_area(on.c1, 0, W, 255, 255, 0, 255); break;
            case 4: lit = t_area(on.c0, 0, W, 0, 255, 0, 255) && t_area(on.c1, 0, W, 255, 0, 0, 255); break;
            case 7: lit = t_area(on.c0, 0, W / 2, 255, 0, 0, 255) && t_area(on.c0, W / 2, W, 0, 255, 0, 255); break;
            case 8: case 14: lit = t_area(on.c0, 0, W / 2, 0, 255, 0, 255) && t_area(on.c0, W / 2, W, 0, 0, 255, 255); break;
            case 9: { const uint8_t *q = on.c0; lit = q[0] == 0 && q[1] >= 126 && q[1] <= 129 && q[2] >= 126 && q[2] <= 129; for (int i = 1; i < W * W; i++) lit &= !memcmp(on.c0 + 4 * i, q, 4); break; }
            case 10: lit = t_area(on.c0, 0, W / 2, 0, 0, 255, 255) && t_area(on.c0, W / 2, W, 0, 255, 0, 255); break;
            case 11: lit = t_area(on.c0, 0, W, 0, 0, 255, 255); break;
            case 12: lit = t_area(on.c0, 0, W, 0, 255, 255, 255); break;
            case 13: case 16: { int g = t_count(on.c0, 0, 255, 0), bl = t_count(on.c0, 0, 0, 255); lit = g > 0 && bl > 0 && g + bl == W * W; break; }   // half green, the rest blue as loaded
            case 15: { int g = t_count(on.c0, 0, 255, 0), bl = t_count(on.c0, 0, 0, 255); lit = (g == W * W) || (bl == W * W); break; }   // drawn or culled whole
        }
        CHECK(lit, "the targets hold the literal colours");
        printf("case %2d (%s): %s, converted %llu in %llu passes\n", k, names[k], same && lit ? "PASS" : "FAIL", (unsigned long long)n, (unsigned long long)np);
    }
    // The plan's cost: lcv_check on the full-screen quad, with the state the last ops left (one colour target, the quad's stream bound)
    {   state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); t_set_rt(1, 0); t_ds(ds_off); t_program(&p_one); t_verts(V_QUAD); exec_ops(); rp_end(); mtl_sub_commit(); mtl_drain();
        const uint32_t cf[8] = {MTLPixelFormatRGBA8Unorm}; p_draw dw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 6, .instances = 1}; NvProg *pr = prog_get(&p_one);
        CHECK(lcv_check(pr, &dw, NULL, 1, cf, W, W, 0, 0) == 1, "the bench's quad is proven");
        dw.count = 5; CHECK(lcv_check(pr, &dw, NULL, 1, cf, W, W, 0, 0) == 0, "five vertices are not"); dw.count = 6;
        // lcv_confirm when the draw also writes an attachment still loaded as DontCare (draw_ then ends the pass and draws again): the covered one is not confirmed either,
        // so the ended pass stores neither (stored, the covered one would hold the DontCare fill undrawn). Positive control: the covered one alone is confirmed
        {   const double box[4] = {0, 0, W, W}; const MTLScissorRect sc = {0, 0, W, W};
            g_pass.tw = W; g_pass.th = W; memset(g_pass.cfmt, 0, sizeof g_pass.cfmt); g_pass.cfmt[0] = g_pass.cfmt[1] = MTLPixelFormatRGBA8Unorm; g_pass.hd = g_pass.hs = 0;
            for (int pos = 0; pos < 2; pos++) {
                g_nsd = 2; g_sd[0] = (sd_att){.idx = 0, .ldc = 1, .bytes = W * W * 4}; g_sd[1] = (sd_att){.idx = 1, .ldc = 1, .bytes = W * W * 4};
                g_ldc_mask = pos ? 1 : 3; g_lcv_mask = 1; g_lcv_seq = g_draw_seq;
                lcv_confirm(pr, &dw, NULL, pos ? 1 : 3, box, sc, 1);
                if (pos) CHECK(g_sd[0].ldc == 0 && g_ldc_mask == 0 && g_lcv_mask == 0, "confirm: the covered attachment alone is confirmed and stored");
                else CHECK(g_sd[0].ldc == 1 && g_sd[1].ldc == 1 && g_ldc_mask == 3 && g_lcv_mask == 0, "confirm: a write into another DontCare slot (a split follows) confirms nothing");
            }
            g_nsd = 0; g_ldc_mask = 0; }
        const int N = 200000; uint64_t t0 = bp_now(); unsigned sink = 0; for (int i = 0; i < N; i++) sink += lcv_check(pr, &dw, NULL, 1, cf, W, W, 0, 0); uint64_t t1 = bp_now();
        printf("plan cost: %.0f ns a proof (lcv_check: state, pipeline key, positions, cover) (%u)\n", (double)(t1 - t0) / N, sink); }
    mtl_pool_del(mem); free(mem);
    printf("covered loads: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
