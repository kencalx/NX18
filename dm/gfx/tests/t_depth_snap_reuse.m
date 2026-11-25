// Draws that only read the depth attachment take one snapshot a barrier interval (nvn_mtl.m fb_depth_rule, DM_NVN_FB_DSNAP). Through the production replay, in one pass on an R32Float
// colour target and a real Depth32Float attachment: draws that write depth (0.25, 0.5, 0.6) with draws between them that read the attachment at their own pixel and write what they
// read into one column each. With the switch on: the first read after a write takes a snapshot (its pass ends, as the rule did), the next read in the barrier interval reuses it
// though depth was written in between (NVN shows rendering to texture reads only after a barrier), a barrier makes the next read take a fresh one, a depth clear (waiting to be
// the next pass's load action) makes one too, and a read with no write before it in its pass reads the live snapshot, so the depth write after it keeps the pass. Off (=0): every
// read of a plane written earlier in its pass ends the pass and reads what is stored, as before. The columns read back hold the values each rule defines, and the pass ends and
// snapshot counts match.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { W = 8, TID = 661 };
static tex_t C, Z;
static prog_t wr[4] = {{.serial = 99681}, {.serial = 99682}, {.serial = 99683}, {.serial = 99684}}, rd = {.serial = 99685};   // writers at 0.25, 0.5, 0.6, 0.75; the reader
static uint8_t ops[8192]; static size_t nops;
static void *op(uint32_t code, size_t size) { op_hdr h = {code, (uint32_t)(sizeof h + size)}; memcpy(ops + nops, &h, sizeof h); void *a = ops + nops + sizeof h; memset(a, 0, size); nops += h.size; return a; }
static void ds_state(int write) {
    p_bind_state *b = op(OP_BIND_STATE, sizeof(p_bind_state)); b->kind = 5;
    ds_st d = {.dt = (uint8_t)write, .dw = (uint8_t)write, .df = NVN_DEPTH_FUNC_ALWAYS}; memcpy(b->bytes, &d, sizeof d);
}
static void draw_op(const prog_t *p, int column) {   // column < 0: the whole target
    *(p_scissor *)op(OP_SCISSOR, sizeof(p_scissor)) = column < 0 ? (p_scissor){0, 0, W, 1} : (p_scissor){column, 0, 1, 1};
    ds_state(column < 0);
    *(p_bind_program *)op(OP_BIND_PROGRAM, sizeof(p_bind_program)) = (p_bind_program){p, 3};
    *(p_draw *)op(OP_DRAW, sizeof(p_draw)) = (p_draw){NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3};
}
typedef struct { float col[W]; uint64_t splits, copies, saved, kept, passes; } result;
static result run(int on) {
    g_fb_dsnap_m = on;
    uint64_t s0[5], s1[5]; mtl_fb_dsnap_stats(s0); uint64_t sp0 = g_fb_dsplit, p0 = g_stat_pass;
    state_reset(); memset(&R, 0, sizeof R); S.tex[1][0] = TID; S.chmask.mask = 0xffffffffu;
    nops = 0;
    p_set_rt rt = {.n = 1, .depth = &Z}; rt.color[0] = &C;
    *(p_set_rt *)op(OP_SET_RT, sizeof rt) = rt;
    *(p_clear_color *)op(OP_CLEAR_COLOR, sizeof(p_clear_color)) = (p_clear_color){0, 0xf, {-1, 0, 0, 0}};
    *(p_clear_ds *)op(OP_CLEAR_DS, sizeof(p_clear_ds)) = (p_clear_ds){.depth = 1, .depth_mask = 1};
    draw_op(&wr[0], -1);   // depth 0.25
    draw_op(&rd, 0);       // column 0: written earlier in its pass: on, the first snapshot (its pass ends); off, the pass ends
    draw_op(&wr[1], -1);   // depth 0.5
    draw_op(&rd, 1);       // column 1: on, the same snapshot (0.25), the pass goes on; off, the pass ends (0.5)
    *(int32_t *)op(OP_BARRIER, 4) = NVN_BARRIER_ORDER_FRAGMENTS_BIT | NVN_BARRIER_INVALIDATE_TEXTURE_BIT;
    draw_op(&rd, 2);       // column 2: after a barrier, a fresh snapshot (0.5)
    *(p_scissor *)op(OP_SCISSOR, sizeof(p_scissor)) = (p_scissor){0, 0, W, 1};   // a whole clear
    *(p_clear_ds *)op(OP_CLEAR_DS, sizeof(p_clear_ds)) = (p_clear_ds){.depth = .875f, .depth_mask = 1};   // ends the pass; the clear waits for the next one
    draw_op(&rd, 3);       // column 3: the clear lands first: a fresh snapshot (0.875), not the one before the clear
    draw_op(&rd, 4);       // column 4: no write before it in this pass: on, the live snapshot; off, the attachment itself (0.875 both)
    draw_op(&wr[2], -1);   // depth 0.6: on, the pass goes on (column 4 read the snapshot); off, the read of column 4 ends the pass
    draw_op(&rd, 5);       // column 5: on, the snapshot (0.875); off, what is stored (0.6)
    *(p_set_rt *)op(OP_SET_RT, sizeof(p_set_rt)) = (p_set_rt){0};
    op(OP_END, 0);
    static uint64_t f; mtl_set_frame(++f);
    mtl_sub_begin(); mtl_exec(ops); rp_end();
    id<MTLBuffer> b = [g_dev newBufferWithLength:W * 4 options:MTLResourceStorageModeShared]; res_add(b);
    [blit() copyFromTexture:tex_mtl(&C) sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, 1, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:W * 4 destinationBytesPerImage:W * 4];
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes"); mtl_drain();
    CHECK(!mtl_last_commit_error(), "no GPU error");
    result r; memcpy(r.col, b.contents, sizeof r.col); mtl_fb_dsnap_stats(s1);
    r.splits = g_fb_dsplit - sp0; r.copies = s1[3] - s0[3]; r.saved = s1[0] - s0[0]; r.kept = s1[2] - s0[2]; r.passes = g_stat_pass - p0;
    printf("%s: columns %g %g %g %g %g %g; read-after-write pass ends %llu, snapshots for reads %llu, pass ends saved %llu, reads kept off the attachment %llu, passes %llu\n", on ? "on" : "off",
           r.col[0], r.col[1], r.col[2], r.col[3], r.col[4], r.col[5], (unsigned long long)r.splits, (unsigned long long)r.copies, (unsigned long long)r.saved, (unsigned long long)r.kept, (unsigned long long)r.passes);
    return r;
}
int main(void) { @autoreleasepool {
    mtl_init();
    C = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 99686}; C.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_R32F, .width = W, .height = 1, .depth = 1, .levels = 1, .samples = 1};
    Z = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 99687}; Z.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_DEPTH32F, .width = W, .height = 1, .depth = 1, .levels = 1, .samples = 1};
    for (int i = 0; i < 2; i++) { tex_t *t = i ? &Z : &C; MTLTextureDescriptor *d = tex_desc(t, 0); d.usage |= MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; CHECK(mt != nil, "target allocates"); if (!mt) return 1;
        res_add(mt); mtl_tex_init(t); serial_put(t->serial, mt); }   // NOLINT(clang-analyzer-osx.cocoa.RetainCount): g_by_serial owns them
    mtl_reg_tex(TID, &Z, NULL);
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "static float4 at(uint i, float z) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, z, 1); }\n"
        "vertex float4 v25(uint i [[vertex_id]]) { return at(i, .25); } vertex float4 v50(uint i [[vertex_id]]) { return at(i, .5); }\n"
        "vertex float4 v60(uint i [[vertex_id]]) { return at(i, .6); } vertex float4 v75(uint i [[vertex_id]]) { return at(i, .75); }\n"
        "fragment void none() {}\n"
        "struct A { depth2d<float, access::read> d [[id(0)]]; };\n"
        "fragment float4 rd(float4 p [[position]], constant A& a [[buffer(0)]]) { return float4(a.d.read(uint2(p.xy)), 0, 0, 1); }\n", nil, &error);
    CHECK(lib != nil, "the test shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
    NSString *vn[4] = {@"v25", @"v50", @"v60", @"v75"};
    NvShader *none = [NvShader new]; none->fn = t4_fn(lib, @"none"); none->stage = 1; none->rf.color_known = 1; strcpy(none->key, "dsnapnone0000000");
    for (int i = 0; i < 4; i++) { NvProg *p = [NvProg new]; p->sh[0] = [NvShader new]; p->sh[0]->fn = t4_fn(lib, vn[i]); snprintf(p->sh[0]->key, sizeof p->sh[0]->key, "dsnapv%d000000000", i); p->sh[1] = none; serial_put(wr[i].serial, p); }
    NvProg *rp = [NvProg new]; rp->sh[0] = [NvShader new]; rp->sh[0]->fn = t4_fn(lib, @"v75"); strcpy(rp->sh[0]->key, "dsnapvr000000000");
    NvShader *fs = [NvShader new]; rp->sh[1] = fs; fs->fn = t4_fn(lib, @"rd"); fs->stage = 1; strcpy(fs->key, "dsnapread0000000");
    fs->arg_len = [fs->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    fs->rf.color_known = 1; fs->rf.color_mask = 1; fs->rf.nb = 1; fs->rf.b[0] = (nvn_rbind){.kind = NVN_RB_TEX, .aid = 0, .reg = 0, .dtt = MTLTextureType2D};
    serial_put(rd.serial, rp);
    result off = run(0), on = run(1);
    const float want_on[6] = {.25f, .25f, .5f, .875f, .875f, .875f}, want_off[6] = {.25f, .5f, .5f, .875f, .875f, .6f};
    int good_on = 1, good_off = 1; for (int i = 0; i < 6; i++) { good_on &= on.col[i] == want_on[i]; good_off &= off.col[i] == want_off[i]; }
    CHECK(good_off, "off: each read sees what is stored when it runs");
    CHECK(good_on, "on: each read sees its barrier interval's snapshot, a fresh one after the barrier and after the clear");
    CHECK(on.col[6] == -1 && off.col[6] == -1 && on.col[7] == -1, "columns no draw wrote keep the colour clear");
    CHECK(off.splits == 4 && off.copies == 0 && off.saved == 0 && off.kept == 0, "off: the four reads after a write or a waiting clear end their pass (columns 0, 1, 3, 5)");
    CHECK(on.splits == 0 && on.copies == 3 && on.saved == 2 && on.kept == 1, "on: three snapshots (columns 0, 2, 3), two pass ends saved (columns 1, 5), one read kept off the attachment (column 4)");
    CHECK(on.passes < off.passes, "on opens fewer passes");
    printf("depth snapshot reuse: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
