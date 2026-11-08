// The render-pass savings on the GPU, through production replay with the TBDR mode off (DM_NVN_OMIT_UNWRITTEN, DM_NVN_CLEAR_FMTMASK; nvn_mtl.m): each case runs with its switch off
// and on, in one process (the switches are read as ab and the DM_AB phase picks them), and the targets read back must match each other and the values computed by hand.
//   omit: a pass of two RGBA8 targets whose one draw writes colour 0 leaves colour 1 out, and colour 1 keeps its green; a later draw in the same pass that writes colour 1 ends the
//         pass first (one split) and its yellow lands
//   clear: a clear of an R16 target with mask 0x1 is a whole clear (counted), a clear of an RG16 target with mask 0x1 stays a triangle and keeps green
// DM_NVN_LOAD_COVER's proof is first_draw_covers, the TBDR mode's, whose geometry t_cover checks; its new rejects are in t_rpsave. Run under MTL_DEBUG_LAYER=1 (check_t_rpsave_gpu):
// a pipeline with no attachment at a slot its fragment writes must pass Metal's validation
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static tex_t c0 = {.magic=MAGIC('T','E','X',0), .serial=99601}, c1 = {.magic=MAGIC('T','E','X',0), .serial=99602};
static tex_t r16 = {.magic=MAGIC('T','E','X',0), .serial=99603}, rg16 = {.magic=MAGIC('T','E','X',0), .serial=99604};
static prog_t p1 = {.serial=99611}, p2 = {.serial=99612};
static void seed(tex_t *t, MTLClearColor c) {
    MTL4RenderPassDescriptor *p = [MTL4RenderPassDescriptor new];
    p.colorAttachments[0].texture = tex_mtl(t); p.colorAttachments[0].loadAction = MTLLoadActionClear; p.colorAttachments[0].storeAction = MTLStoreActionStore;
    p.colorAttachments[0].clearColor = c;
    enc_r_end(enc_r_begin(p));
}
static void begin(int on) {   // a new frame and submission with the switches off (phase 0) or on (phase 1)
    static uint64_t frame; mtl_set_frame(++frame); atomic_store(&g_ab_phase, on ? 1 : 0);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
}
static void readback(tex_t *t, id<MTLBuffer> b, unsigned bpp) {
    [blit() copyFromTexture:tex_mtl(t) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1) toBuffer:b destinationOffset:0
            destinationBytesPerRow:8 * bpp destinationBytesPerImage:64 * bpp];
}
typedef struct { uint8_t a[256], b[256]; uint64_t omit, split, cfm; } result;
static result run_omit(int on, int second) {
    begin(on); seed(&c0, MTLClearColorMake(0, 0, 1, 1)); seed(&c1, MTLClearColorMake(0, 1, 0, 1));
    uint64_t s0[9], s1[9]; mtl_rpsave_stats(s0);
    struct { op_hdr rt_h; p_set_rt rt; op_hdr pr_h; p_bind_program pr; op_hdr draw_h; p_draw draw; op_hdr end; } a = {0};
    a.rt_h = (op_hdr){OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt)}; a.rt = (p_set_rt){.n = 2}; a.rt.color[0] = &c0; a.rt.color[1] = &c1;
    a.pr_h = (op_hdr){OP_BIND_PROGRAM, sizeof(op_hdr) + sizeof(p_bind_program)}; a.pr = (p_bind_program){&p1, 3};
    a.draw_h = (op_hdr){OP_DRAW, sizeof(op_hdr) + sizeof(p_draw)}; a.draw = (p_draw){NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; a.end = (op_hdr){OP_END, sizeof(op_hdr)};
    mtl_exec((const uint8_t *)&a);
    CHECK(g_enc != nil, "the draw's pass stays open");
    CHECK(g_pass.omit == (on ? 2u : 0u), on ? "the pass leaves colour 1 out" : "with the switch off every slot is attached");
    if (second) {   // the same pass goes on with a draw that writes both slots
        struct { op_hdr pr_h; p_bind_program pr; op_hdr draw_h; p_draw draw; op_hdr end; } b = {0};
        b.pr_h = (op_hdr){OP_BIND_PROGRAM, sizeof(op_hdr) + sizeof(p_bind_program)}; b.pr = (p_bind_program){&p2, 3};
        b.draw_h = (op_hdr){OP_DRAW, sizeof(op_hdr) + sizeof(p_draw)}; b.draw = (p_draw){NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3}; b.end = (op_hdr){OP_END, sizeof(op_hdr)};
        mtl_exec((const uint8_t *)&b);
        CHECK(g_pass.omit == 0, "the pass that draws into colour 1 attaches it");
    }
    rp_end();
    id<MTLBuffer> ba = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared], bb = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    readback(&c0, ba, 4); readback(&c1, bb, 4);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completes"); CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    result r = {0}; memcpy(r.a, ba.contents, 256); memcpy(r.b, bb.contents, 256); mtl_rpsave_stats(s1);
    r.omit = s1[5] - s0[5]; r.split = s1[8] - s0[8]; return r;
}
static result run_clear(int on) {
    begin(on); seed(&r16, MTLClearColorMake(0, 0, 0, 1)); seed(&rg16, MTLClearColorMake(0, 1, 0, 1));
    uint64_t s0[9], s1[9]; mtl_rpsave_stats(s0);
    struct { op_hdr rt_h; p_set_rt rt; op_hdr c0_h; p_clear_color c0; op_hdr c1_h; p_clear_color c1; op_hdr end; } a = {0};
    a.rt_h = (op_hdr){OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt)}; a.rt = (p_set_rt){.n = 2}; a.rt.color[0] = &r16; a.rt.color[1] = &rg16;
    a.c0_h = (op_hdr){OP_CLEAR_COLOR, sizeof(op_hdr) + sizeof(p_clear_color)}; a.c0 = (p_clear_color){0, 0x1, {1, 1, 1, 1}};
    a.c1_h = (op_hdr){OP_CLEAR_COLOR, sizeof(op_hdr) + sizeof(p_clear_color)}; a.c1 = (p_clear_color){1, 0x1, {1, 1, 1, 1}};
    a.end = (op_hdr){OP_END, sizeof(op_hdr)};
    mtl_exec((const uint8_t *)&a); rp_flush();
    id<MTLBuffer> ba = [g_dev newBufferWithLength:128 options:MTLResourceStorageModeShared], bb = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    readback(&r16, ba, 2); readback(&rg16, bb, 4);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "GPU submission completes"); CHECK(!mtl_last_commit_error(), "GPU submission has no error");
    result r = {0}; memcpy(r.a, ba.contents, 128); memcpy(r.b, bb.contents, 256); mtl_rpsave_stats(s1); r.cfm = s1[0] - s0[0]; return r;
}
int main(void) { @autoreleasepool {
    setenv("DM_NVN_TBDR", "0", 1); setenv("DM_AB", "1000000", 1);   // phases are set by hand (begin): ab is on in phase 1
    setenv("DM_NVN_OMIT_UNWRITTEN", "ab", 1); setenv("DM_NVN_CLEAR_FMTMASK", "ab", 1);
    mtl_init(); CHECK(!tbdr_on(), "the TBDR mode stays off");
    nvn_texdesc d = {.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 8, .height = 8, .depth = 1, .levels = 1, .samples = 1};
    c0.d = c1.d = d; d.format = NVN_FORMAT_R16; r16.d = d; d.format = NVN_FORMAT_RG16; rg16.d = d;
    NSError *error = nil;
    id<MTLLibrary> lib = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[n], .5, 1); }\n"
        "fragment float4 f1() { return float4(1, 0, 0, 1); }\n"
        "struct O { float4 a [[color(0)]]; float4 b [[color(1)]]; };\nfragment O f2() { return {float4(1, 0, 0, 1), float4(1, 1, 0, 1)}; }\n" options:nil error:&error];
    CHECK(lib != nil, "literal test shaders compile"); if (!lib) return 1;
    for (int k = 0; k < 2; k++) {
        NvProg *pr = [NvProg new]; pr->sh[0] = [NvShader new]; pr->sh[1] = [NvShader new];
        pr->sh[0]->fn = [lib newFunctionWithName:@"v"]; pr->sh[1]->fn = [lib newFunctionWithName:k ? @"f2" : @"f1"];
        pr->sh[1]->stage = 1; pr->sh[1]->rf.color_known = 1; pr->sh[1]->rf.color_mask = k ? 3 : 1;
        serial_put(k ? p2.serial : p1.serial, pr);
    }
    static const uint8_t red[4] = {255, 0, 0, 255}, green[4] = {0, 255, 0, 255}, yellow[4] = {255, 255, 0, 255};
    for (int second = 0; second < 2; second++) {
        result off = run_omit(0, second), on = run_omit(1, second);
        CHECK(!memcmp(off.a, on.a, 256) && !memcmp(off.b, on.b, 256), "the targets match byte for byte with the switch off and on");
        int good = 1; for (int i = 0; i < 64; i++) good &= !memcmp(on.a + 4 * i, red, 4) && !memcmp(on.b + 4 * i, second ? yellow : green, 4);
        CHECK(good, second ? "colour 0 red, colour 1 yellow: the draw that writes colour 1 lands" : "colour 0 red, colour 1 keeps its green");
        CHECK(off.omit == 0 && on.omit == 1, "one slot left out with the switch on, none off");
        CHECK(off.split == 0 && on.split == (uint64_t)second, "a pass split only for the draw that writes the slot left out");
        printf("omit, %s: left out %llu, split %llu\n", second ? "a second draw writes colour 1" : "one draw", (unsigned long long)on.omit, (unsigned long long)on.split);
    }
    {
        result off = run_clear(0), on = run_clear(1);
        CHECK(!memcmp(off.a, on.a, 128) && !memcmp(off.b, on.b, 256), "the clears match byte for byte with the switch off and on");
        int good = 1; for (int i = 0; i < 64; i++) {
            uint16_t r, rg[2]; memcpy(&r, on.a + 2 * i, 2); memcpy(rg, on.b + 4 * i, 4);
            good &= r == 0xffff && rg[0] == 0xffff && rg[1] == 0xffff; }
        CHECK(good, "R16 cleared to 1; RG16's red cleared to 1, its green kept at 1");
        CHECK(off.cfm == 0 && on.cfm == 1, "the R16 clear is taken whole with the switch on only; the RG16 clear with mask 0x1 is not");
        printf("clear: format-complete clears taken whole %llu\n", (unsigned long long)on.cfm);
    }
    printf("RPSAVE_GPU %d checks, %d failed\n", checks, failed); return failed != 0;
} }
