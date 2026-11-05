// NVN's depth bounds test through the replay (DM_DEPTH_BOUNDS, nvn_mtl.m draw_): a draw is discarded where the depth already stored at the pixel is outside the bounds and kept
// inside them, bounds are clamped to [0, 1], min above max and a disabled test draw as today, and a clear later in the same pass is not cut by them. Runs only where the GPU has
// the test (Apple10 or later: an M5 Mac); elsewhere, and without the switch, it checks that nothing would be recorded (hle_nvn.c h_depth_bounds asks mtl_depth_bounds_rec)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, label) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static uint8_t *cmd; static size_t used;
static void emit(unsigned op, const void *p, size_t n) {
    size_t z = (8 + n + 7) & ~7ull; op_hdr h = {op, (uint32_t)z};
    memcpy(cmd + used, &h, 8); if (n) memcpy(cmd + used + 8, p, n); used += z;
}
static void execute(void) {
    emit(OP_END, NULL, 0); mtl_sub_begin(); uint64_t handle = (uint64_t)cmd; mtl_sub_index(&handle, 1); mtl_exec(cmd);
    uint64_t fence = mtl_sub_commit(); CHECK(mtl_wait(fence, 5000000000ull), "GPU submission completes");
    CHECK(!mtl_last_commit_error(), "GPU reports no error"); used = 0;
}
// Pixels of the 8 x 8 RGBA8 target that are red (drawn), blue (the first clear) or green (the later clear)
static void count(const tex_t *t, int *red, int *blue, int *green) {
    mtl_sub_begin(); id<MTLBuffer> b = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared]; res_add(b);
    enc_b_copy_texture_buffer(blit(), tex_mtl(t), 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(8, 8, 1), b, 0, 32, 256);
    uint64_t fence = mtl_sub_commit(); CHECK(mtl_wait(fence, 5000000000ull), "readback completes");
    const uint8_t *p = b.contents; *red = *blue = *green = 0;
    for (int i = 0; i < 64; i++) { const uint8_t *q = p + 4 * i; *red += q[0] == 255 && q[1] == 0 && q[2] == 0; *blue += q[0] == 0 && q[1] == 0 && q[2] == 255; *green += q[0] == 0 && q[1] == 255 && q[2] == 0; }
}
static void clear(float r, float g, float b, int depth) {
    p_clear_color c = {.index = 0, .mask = 15, .rgba = {r, g, b, 1}}; emit(OP_CLEAR_COLOR, &c, sizeof c);
    if (depth) { p_clear_ds d = {.depth = .5f, .depth_mask = 1}; emit(OP_CLEAR_DS, &d, sizeof d); }
}
static void bounds(int en, float mn, float mx) { p_depth_bounds b = {en, mn, mx}; emit(OP_DEPTH_BOUNDS, &b, sizeof b); }
int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1); mtl_init();
    const char *e = getenv("DM_DEPTH_BOUNDS"); int want = e && atoi(e) > 0, a10 = [g_dev supportsFamily:MTLGPUFamilyApple10], rec = mtl_depth_bounds_rec();
    CHECK(rec == (want && a10), "bounds are recorded only with DM_DEPTH_BOUNDS=1 on an Apple10-or-later GPU");
    if (!rec) { printf("t_depth_bounds: %s; %d checks, %d failed\n", !want ? "DM_DEPTH_BOUNDS is not 1: nothing is recorded" : "this GPU is below the Apple10 family: nothing is recorded", checks, fails); return fails != 0; }
    void *memory = NULL; if (posix_memalign(&memory, getpagesize(), 65536)) abort(); memset(memory, 0, 65536); mtl_pool_add(memory, 65536); cmd = memory;
    NSError *error = nil; id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[n % 3], 0.25, 1); }\n"
        "fragment float4 f() { return float4(1, 0, 0, 1); }\n" options:nil error:&error];
    if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    static prog_t pg = {.serial = 910601}; NvProg *program = [NvProg new];
    program->sh[0] = [NvShader new]; program->sh[0]->fn = [lib newFunctionWithName:@"v"];
    program->sh[1] = [NvShader new]; program->sh[1]->fn = [lib newFunctionWithName:@"f"]; program->sh[1]->stage = 1; serial_put(pg.serial, program);
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 910602}, z = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 910603};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    z.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_DEPTH32F, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    state_reset(); memset(&R, 0, sizeof R);
    p_set_rt rt = {.n = 1, .depth = &z}; rt.color[0] = &t; emit(OP_SET_RT, &rt, sizeof rt);
    p_bind_program bp = {.prog = &pg, .stages = 3}; emit(OP_BIND_PROGRAM, &bp, sizeof bp);
    ds_st ds = {.df = NVN_DEPTH_FUNC_ALWAYS}; p_bind_state bs = {.kind = 5}; memcpy(bs.bytes, &ds, sizeof ds); emit(OP_BIND_STATE, &bs, sizeof bs);   // no depth test or write: only the bounds cull
    p_draw tri = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1};
    struct { int en; float mn, mx; int red; const char *label; } cases[] = {
        {1, .6f, 1.f, 0, "stored depth 0.5 below the bounds 0.6..1: every fragment discarded"},
        {1, .4f, .6f, 64, "stored depth 0.5 inside the bounds 0.4..0.6: every fragment drawn"},
        {1, 0.f, .5f, 64, "the bounds are inclusive: 0..0.5 keeps a stored 0.5"},
        {0, .6f, 1.f, 64, "a disabled test draws everything"},
        {1, -1.f, .45f, 0, "bounds clamp to 0..0.45 and still discard 0.5"},
        {1, -2.f, 2.f, 64, "bounds past both ends clamp to 0..1: the test passes everything"},
        {1, .7f, .3f, 64, "min above max leaves the test off (a red line), as without the switch"},
    };
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        clear(0, 0, 1, 1); bounds(cases[i].en, cases[i].mn, cases[i].mx); emit(OP_DRAW, &tri, sizeof tri); execute();
        int red, blue, green; count(&t, &red, &blue, &green);
        CHECK(red == cases[i].red && red + blue == 64, cases[i].label);
        printf("case %u: %s: %d red, %d blue\n", i, cases[i].label, red, blue);
    }
    // A clear later in the same pass is drawn with the bounds off (clr_tri), and the next draw sets them again
    clear(0, 0, 1, 1); bounds(1, .6f, 1.f); emit(OP_DRAW, &tri, sizeof tri);
    p_scissor sc = {0, 0, 4, 8}; emit(OP_SCISSOR, &sc, sizeof sc); clear(0, 1, 0, 0);   // a partial clear stays in the pass
    sc = (p_scissor){0, 0, 8, 8}; emit(OP_SCISSOR, &sc, sizeof sc); emit(OP_DRAW, &tri, sizeof tri); execute();
    { int red, blue, green; count(&t, &red, &blue, &green);
      CHECK(green == 32 && blue == 32 && red == 0, "a clear between bounded draws is not cut by the bounds, and the next draw is bounded again"); }
    printf("t_depth_bounds: %d checks, %d failed\n", checks, fails);
    return fails != 0;
} }
