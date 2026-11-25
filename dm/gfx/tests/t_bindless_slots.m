// Slot tables, stage 1 (DM_NVN_BINDLESS=1, NX18-X2.0 bindless-plan.md): the table path reads the same textures and samplers as the slot path. A fragment shader of five bindings
// (combined slot 0 as 2D, combined slot 1 declared a 2D array over a 2D texture: tex_fit's view, separate slot 2 as 2D, sampler slot 0, the sampler of combined slot 0's handle) is
// encoded through encode_args (the slot path: its argument block), and bl_note keeps the table beside it. Each step draws two pixels of a 32x1 target: one through the slot shader
// (fs, its argument block) and one through a hand-written table shader (ft), which reads every texture and sampler from the table version bl_build made, by slot, through typed
// views of one table of resource IDs. Both pixels must hold the texels the bindings name. Steps: the first draw; the same again (reused); a full encode after push constants (the
// version taken without a look); a texture rebind
// (a new version, while the first draw's version stays as the GPU read it); a registration of a bound ID with another texture (a new epoch); a sampler rebind; slot 0 emptied (the
// dummy); a rebind back. Every pixel is read back after the submission. Checked too: the table entries equal the block's entries, no mismatch is counted, and the versions taken
// without a look are counted. With the switch off nothing is built (the table shader is not drawn).
// Bench (Mac): a full encode of 16 textures and 8 samplers with and without the table checks, and a check that finds its version current.
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
static uint64_t next_serial = 98000;
enum { W = 32, NTX = 6, S_CLAMP = 1, S_REPEAT = 2, TA = 10, TB = 11, TC = 12, SEP = NVN_SEPTEX_SLOT0 + 2 };
static tex_t g_tx[NTX + 1]; static id<MTLTexture> g_txm[NTX + 1];
static uint8_t texel(int k, int j) { return (uint8_t)(20 + 30 * k + 10 * j); }   // texture k's texel j, its red channel (2 texels)
static void make_tex(int k) {
    tex_t *t = &g_tx[k]; *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=k == NTX ? W : 2, .height=1, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    g_txm[k] = [g_dev newTextureWithDescriptor:d]; CHECK(g_txm[k] != nil, "texture allocated");
    res_add(g_txm[k]); mtl_tex_init(t); serial_put(t->serial, g_txm[k]);
    if (k < NTX) { uint8_t px[8] = {texel(k, 0), 0, 0, 255, texel(k, 1), 0, 0, 255}; t->mem = mem + 0x1000 + 0x100 * (uint32_t)k; t->L.size = 8;
        [g_txm[k] replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:px bytesPerRow:8]; memcpy((void *)t->mem, px, 8); }
}
static void bind_tex(int slot, uint64_t h) { p_bind_handles b = {.stage=1, .first=slot, .n=1}; b.h[0] = h; state_op(OP_BIND_TEX, &b); }
static void bind_samp(int slot, int sid) { p_bind_handles b = {.stage=1, .first=slot, .n=1}; b.h[0] = (uint64_t)sid << 20; state_op(OP_BIND_SAMP, &b); }
static id<MTLRenderPipelineState> g_ps_s, g_ps_t; static NvShader *g_fs; static int g_px; static uint8_t g_want[W][4];
static struct { int t0, t1, t2, rep0, rep1; } st;   // what is bound: texture index per slot (-1: none), sampler slot 0 / slot 0's handle sampler repeating
// fs and ft return (slot 0 at u 1.25 through sampler slot 0, slot 1's layer 0 at u 0.25 through slot 0's handle sampler, separate slot 2 at u 1.25 through sampler slot 0), red each
static void want(uint8_t w[4]) {
    w[0] = st.t0 < 0 ? 0 : texel(st.t0, st.rep0 ? 0 : 1); w[1] = st.t1 < 0 ? 0 : texel(st.t1, 0); w[2] = st.t2 < 0 ? 0 : texel(st.t2, st.rep0 ? 0 : 1); w[3] = 255;
}
static void draw_pair(const char *label) {   // the slot shader, then the table shader, each one pixel
    CHECK(g_px + 2 <= W, "room for the draws"); if (g_px + 2 > W) return;
    uint8_t w[4]; want(w);
    enc_r_pso(g_enc, g_ps_s); enc_r_viewport(g_enc, (MTLViewport){g_px, 0, 1, 1, 0, 1});
    uint64_t mism0 = g_bls.mism;
    CHECK(encode_args((id<MTL4CommandEncoder>)g_enc, g_fs, 1, 0), "slot path encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3); memcpy(g_want[g_px++], w, 4);
    if (!g_bl_on) return;
    char l[200]; snprintf(l, sizeof l, "%s: no slot table mismatch", label); CHECK(g_bls.mism == mism0, l);
    // the block's entries (texture slots 0, 1, 2; samplers 3, 4) against the table version's
    const uint64_t *blk = (const uint64_t *)((const uint8_t *)g_fs->ab_buf.contents + g_fs->ab_off);
    CHECK(g_bl.mat_ver == g_bl.ver && g_bl.gpu && g_bl.cpu, "the table's version built");
    const uint64_t *tt = g_bl.cpu, *ts = g_bl.cpu + g_bl.nt;
    snprintf(l, sizeof l, "%s: the table entries are the block's", label);
    CHECK(g_bl.nt > SEP && g_bl.ns > 128 && tt[0] == blk[0] && tt[1] == blk[1] && tt[SEP] == blk[2] && ts[0] == blk[3] && ts[128] == blk[4], l);
    // the table shader: its arguments are the table's address three times (2D view, 2D-array view, samplers after the textures)
    __unsafe_unretained id<MTLBuffer> ab; arena_at a = arena_take_u(24, &ab); uint64_t *p = (uint64_t *)(void *)a.cpu;
    p[0] = g_bl.gpu; p[1] = g_bl.gpu; p[2] = g_bl.gpu + 8 * (uint64_t)g_bl.nt;
    enc_r_pso(g_enc, g_ps_t); enc_r_viewport(g_enc, (MTLViewport){g_px, 0, 1, 1, 0, 1});
    enc_r_args(g_enc, MTLRenderStageFragment, a.gpu, 0); enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3); memcpy(g_want[g_px++], w, 4);
}
static tex_t g_out; static id<MTLTexture> g_out_tex;
static void pass_begin(void) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &g_out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(rp_begin() != nil, "render pass opens"); R.clear_c[0] = 0;
}
static void finish(id<MTLBuffer> rb, const char *label) {
    rp_end(); enc_b_copy_texture_buffer(blit(), g_out_tex, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(W, 1, 1), rb, 0, 4 * W, 4 * W);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "GPU submission completed");
    int bad = 0;
    for (int x = 0; x < g_px; x++) { const uint8_t *q = (const uint8_t *)rb.contents + 4 * x, *w = g_want[x]; int d = 0; for (int k = 0; k < 4; k++) d |= abs((int)q[k] - (int)w[k]) > 1;
        if (d) { bad++; fprintf(stderr, "pixel %d (%s path): %u,%u,%u,%u, want %u,%u,%u,%u\n", x, x & 1 ? "table" : "slot", q[0], q[1], q[2], q[3], w[0], w[1], w[2], w[3]); } }
    CHECK(!bad, label);
}
static void cases(id<MTLBuffer> rb) {
    samp_par sp = {.minf=NVN_MIN_FILTER_NEAREST, .magf=NVN_MAG_FILTER_NEAREST, .ws=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wt=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wr=NVN_WRAP_MODE_CLAMP_TO_EDGE, .lod_max=1000};
    mtl_reg_samp(S_CLAMP, &sp); sp.ws = NVN_WRAP_MODE_REPEAT; mtl_reg_samp(S_REPEAT, &sp);
    mtl_reg_tex(TA, &g_tx[0], NULL); mtl_reg_tex(TB, &g_tx[1], NULL); mtl_reg_tex(TC, &g_tx[2], NULL);
    pass_begin(); g_px = 0;
    bind_tex(0, TA | (uint64_t)S_REPEAT << 20); bind_tex(1, TB); bind_tex(SEP, TC); bind_samp(0, S_CLAMP);
    st.t0 = 0; st.t1 = 1; st.t2 = 2; st.rep0 = 0; st.rep1 = 1;
    uint64_t cur0 = g_bls.cur, b0 = g_bls.builds;
    draw_pair("the first draw");
    draw_pair("the same draw again");   // reused: nothing resolved, nothing checked
    args_dirty_w(1, AW_PUSH);   // a hard change that moves no slot: a full encode, its texture work the table's current version would save
    draw_pair("a full encode after push constants");
    if (g_bl_on) CHECK(g_bls.cur > cur0, "nothing bound changed: the version taken without a look");
    uint64_t v1 = g_bl.ver, gpu1 = g_bl.gpu;
    bind_tex(0, 3 | (uint64_t)S_REPEAT << 20); mtl_reg_tex(3, &g_tx[3], NULL); st.t0 = 3;   // a rebind (and a registration of the new ID)
    draw_pair("slot 0 rebound");
    if (g_bl_on) CHECK(g_bl.ver != v1 && g_bl.gpu != gpu1, "a rebind: a new version in a new block (the first draws keep theirs)");
    mtl_reg_tex(TC, &g_tx[4], NULL); st.t2 = 4;   // the ID separate slot 2 names, registered with another texture
    draw_pair("the separate slot's ID registered again");
    bind_samp(0, S_REPEAT); st.rep0 = 1;
    draw_pair("sampler slot 0 rebound");
    bind_tex(0, 0); st.t0 = -1;   // an empty slot: the dummy
    draw_pair("slot 0 emptied");
    bind_tex(0, TA | (uint64_t)S_REPEAT << 20); st.t0 = 0;
    draw_pair("slot 0 bound again");
    draw_pair("and again");
    if (g_bl_on) CHECK(g_bls.builds > b0 && g_bls.mism == 0, "versions built, no mismatch");
    finish(rb, "every pixel holds what its bindings name, through the slots and through the table");
    // a new submission: a new epoch, the table made again in its arena
    uint64_t e0 = g_bls.ep[BLE_SUB];
    pass_begin(); g_px = 0; bind_tex(0, TA | (uint64_t)S_REPEAT << 20); bind_tex(1, TB); bind_tex(SEP, TC); bind_samp(0, S_CLAMP); st.rep0 = 0;
    draw_pair("a new submission");
    if (g_bl_on) CHECK(g_bls.ep[BLE_SUB] > e0 || g_bls.ep[BLE_REG] + g_bls.ep[BLE_SER] + g_bls.ep[BLE_DIRTY] > 0, "a new submission: a new epoch");
    finish(rb, "the new submission's pixels");
    if (!g_bl_on) CHECK(g_bls.enc == 0 && g_bls.builds == 0, "switch off: nothing checked or built");
}
// Encode cost of a shader with 16 textures and 8 samplers: a full encode (after a hard change) with the table checks off and on, and with the checks finding a texture rebind
static void bench(id<MTLLibrary> lib) {
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = t4_fn(lib, @"big"); strcpy(s->key, "7c00000000000000");
    s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    int n = 0;
    for (int i = 0; i < 16; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=i, .aid=n, .dtt=MTLTextureType2D};
    for (int i = 0; i < 8; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=i, .aid=n};
    s->rf.nb = n;
    pass_begin();
    for (int i = 0; i < 16; i++) S.tex[1][i] = i & 1 ? TB : TA;
    for (int i = 0; i < 8; i++) S.samp[1][i] = (uint64_t)(i & 1 ? S_REPEAT : S_CLAMP) << 20;
    args_dirty_all();
    enum { N = 20000, ROUNDS = 5, MODES = 3 }; double best[2][MODES]; for (int b = 0; b < 2; b++) for (int m = 0; m < MODES; m++) best[b][m] = 1e18;
    static const char *const name[MODES] = {"full encode after a hard change", "partial patch of a texture", "full encode after a texture rebind (partial patches off)"};
    const int was = g_bl_on, part = g_args_partial;
    for (int r = 0; r < ROUNDS; r++) for (int b = 0; b < 2; b++) for (int m = 0; m < MODES; m++) {
        g_bl_on = b; g_args_partial = m == 1; s->ab_pkind = 0; encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
        uint64_t t0 = bp_now();
        for (int i = 0; i < N; i++) {
            if (m == 0) args_dirty(1); else { p_bind_handles h = {.stage=1, .first=3, .n=1}; h.h[0] = (uint64_t)(i & 1 ? TA : TB); state_op(OP_BIND_TEX, &h); }
            encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
        }
        double ns = (double)(bp_now() - t0) / N; if (ns < best[b][m]) best[b][m] = ns;
    }
    g_bl_on = was; g_args_partial = part; s->ab_pkind = 0;
    printf("t_bindless_slots bench (16 textures, 8 samplers, %d calls, best of %d), table checks off -> on: ", N, ROUNDS);
    for (int m = 0; m < MODES; m++) printf("%s %.0f -> %.0f ns%s", name[m], best[0][m], best[1][m], m < MODES - 1 ? ", " : "\n");
    // what the table path itself costs: a check that finds its version current (stage 2's reuse), and one entry written again with its block made
    if (g_bl_on) {
        uint64_t slots[NVN_REFL_MAXARG]; memcpy(slots, (const uint8_t *)s->ab_buf.contents + s->ab_off, s->arg_len);
        rmu_lock(); bl_note(s, 1, slots, 0, 0, 0);
        uint64_t t0 = bp_now(); for (int i = 0; i < N; i++) bl_note(s, 1, slots, 0, 0, 0); double cur = (double)(bp_now() - t0) / N;
        t0 = bp_now(); for (int i = 0; i < N; i++) { S.tex[1][3] = i & 1 ? TA : TB; g_bl_tgen[1]++; slots[3] ^= 1; bl_note(s, 1, slots, 0, 0, 0); } double one = (double)(bp_now() - t0) / N;
        os_unfair_lock_unlock(&g_rmu);
        printf("t_bindless_slots bench, the table check alone (24 converted bindings): version current %.0f ns, one entry written and its version built %.0f ns\n", cur, one);
        CHECK(g_bls.mism == 0, "the bench's checks found no mismatch");
    }
    rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "bench submission completed");
}
int main(void) { @autoreleasepool {
    alarm(120);
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1); setenv("DM_PSO_RECORD", "/dev/null", 1);
    const char *e = getenv("DM_NVN_BINDLESS"); int on = e && atoi(e) > 0;
    mtl_init();
    CHECK(g_bl_on == on, on ? "DM_NVN_BINDLESS=1 turns the slot tables on" : "the slot tables are off by default");
    mem = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 2;
    mtl_pool_add(mem, 0x10000);
    for (int k = 0; k <= NTX; k++) make_tex(k);
    g_out = g_tx[NTX]; g_out_tex = g_txm[NTX];
    NSError *error = nil;
    NSString *src = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A { texture2d<float> t0 [[id(0)]]; texture2d_array<float> t1 [[id(1)]]; texture2d<float> t2 [[id(2)]]; sampler s0 [[id(3)]]; sampler s1 [[id(4)]]; };\n"
        "fragment float4 fs(constant A &a [[buffer(0)]]) { return float4(a.t0.sample(a.s0, float2(1.25, 0.5), level(0)).r, a.t1.sample(a.s1, float2(0.25, 0.5), 0, level(0)).r, a.t2.sample(a.s0, float2(1.25, 0.5), level(0)).r, 1); }\n"
        // the table path: one table of resource IDs by slot, read through a view of the type each slot declares; samplers after the textures (SAMPT: 128 + its texture slot)
        "struct TX { array<texture2d<float>, 1> e; }; struct TXA { array<texture2d_array<float>, 1> e; }; struct SX { array<sampler, 1> e; };\n"
        "struct T { constant TX *t [[id(0)]]; constant TXA *ta [[id(1)]]; constant SX *s [[id(2)]]; };\n"
        "fragment float4 ft(constant T &a [[buffer(0)]]) { sampler s0 = (&a.s->e[0])[0], s1 = (&a.s->e[0])[128];\n"
        "  return float4((&a.t->e[0])[0].sample(s0, float2(1.25, 0.5), level(0)).r, (&a.ta->e[0])[1].sample(s1, float2(0.25, 0.5), 0, level(0)).r, (&a.t->e[0])[%d].sample(s0, float2(1.25, 0.5), level(0)).r, 1); }\n"
        "struct B { array<texture2d<float>, 16> t [[id(0)]]; array<sampler, 8> s [[id(16)]]; };\n"
        "fragment float4 big(constant B &a [[buffer(0)]]) { return a.t[0].sample(a.s[0], float2(0.5)) + a.t[15].sample(a.s[7], float2(0.5)); }\n", SEP];
    id<MTLLibrary> lib = t4_lib(src, nil, &error);
    CHECK(lib != nil, "shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = t4_fn(lib, @"v"); pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pd.fragmentFunction = t4_fn(lib, @"fs"); g_ps_s = t4_rps(pd, &error); pd.fragmentFunction = t4_fn(lib, @"ft"); g_ps_t = t4_rps(pd, &error);
    CHECK(g_ps_s && g_ps_t, "pipelines compile"); if (!g_ps_s || !g_ps_t) return 2;
    g_fs = [NvShader new]; g_fs->stage = 1; g_fs->fn = t4_fn(lib, @"fs"); strcpy(g_fs->key, "7c00000000000001"); g_fs->arg_len = [g_fs->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    g_fs->rf.nb = 5;
    g_fs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D};
    g_fs->rf.b[1] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=1, .aid=1, .dtt=MTLTextureType2DArray};
    g_fs->rf.b[2] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=SEP, .aid=2, .dtt=MTLTextureType2D};
    g_fs->rf.b[3] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=0, .aid=3};
    g_fs->rf.b[4] = (nvn_rbind){.kind=NVN_RB_SAMPT, .reg=0, .aid=4};
    id<MTLBuffer> rb = [g_dev newBufferWithLength:4 * W options:MTLResourceStorageModeShared]; res_add(rb);
    cases(rb);
    bench(lib);
    printf("t_bindless_slots%s: %d checks, %d failed\n", on ? " (DM_NVN_BINDLESS=1)" : "", checks, failed);
    return failed != 0;
} }
