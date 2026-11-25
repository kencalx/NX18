// Partial argument patches (DM_NVN_ARGS_PARTIAL, encode_args_ args_partial / pk_take): a block whose only changes since it are texture, sampler, storage-buffer or base-instance
// changes of its stage (with or without a uniform change) is copied and only those kinds' entries are written again. Every draw writes one pixel of a 64x1 target whose four channels
// each show one binding kind (texture slot 0 through sampler 0, texture slot 1, a storage buffer times a uniform, c0's base instance), and the pixels are read back. Checked: a texture,
// sampler, storage or base instance change alone patches; a texture and a uniform change together patch; only the texture slots that moved are written again; a storage patch notes
// its storage write; a change of each kind made while another shader of the stage wrote its block in between is still seen; the same in a later pass (the cross-pass rule); any hard
// change with them (a registration, push constants, an image binding), another submission, encodes in full; more changes than the history has entries still patch (its oldest entries joined); a shader that reads no uniform
// keeps its block after a uniform change; a shader with a dynamic handle array (TEXD, once off the uniform patch's list) is patched after a uniform change and a texture change.
// With DM_NVN_ARGS_PARTIAL=0 (and the switch set to 0 here) the same draws encode in full and give the same pixels. With DM_NVN_ARGS_STATS=1 the partial counts are checked too.
// The bench at the end times a full encode against a partial patch of each kind on a shader with 16 textures, 8 samplers, 4 uniform slots, 2 storage buffers and c0.
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
static uint64_t next_serial = 96000;
enum { W = 64, TA = 1, TB = 2, TC = 9, S_CLAMP = 1, S_REPEAT = 2 };
static float *u1, *u2, *sa, *sbb;
static int P;   // partial patches on

static id<MTLTexture> texture(tex_t *t, int width) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=width, .height=1, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
    CHECK(out != nil, "texture allocated");
    if (out) { res_add(out); mtl_tex_init(t); serial_put(t->serial, out); }
    return out;
}
static id<MTLRenderPipelineState> pso(id<MTLLibrary> lib, NSString *frag) {
    NSError *error = nil; MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = t4_fn(lib, @"v"); d.fragmentFunction = t4_fn(lib, frag); d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    id<MTLRenderPipelineState> p = t4_rps(d, &error); CHECK(p != nil, "render pipeline compiles"); if (!p) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    return p;
}
static NvShader *shader(id<MTLFunction> fn, int nb, const nvn_rbind *b) {
    static uint64_t identity = 0x7700000000000000ull;
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = fn; snprintf(s->key, sizeof s->key, "%016llx", (unsigned long long)identity++);
    s->arg_len = [fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    s->rf.nb = nb; memcpy(s->rf.b, b, sizeof *b * nb);
    return s;
}
// The fragment shader of most draws: R texture slot 0 (texel 1 with clamp, texel 0 with repeat), G texture slot 1 (texel 0), B storage x times uniform x, A c0's base instance / 255
static NvShader *shader_p(id<MTLFunction> fn) {
    nvn_rbind b[6] = {{.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}, {.kind=NVN_RB_TEX, .reg=1, .aid=1, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=2},
                      {.kind=NVN_RB_CBUF, .reg=0, .aid=3}, {.kind=NVN_RB_SBUFP, .reg=3, .aid=4, .rw=1}, {.kind=NVN_RB_DRV0, .aid=5}};
    NvShader *s = shader(fn, 6, b); s->rf.drv_read[0] = 1; return s;
}
static void bind_tex(int slot, int tid) { p_bind_handles b = {.stage=1, .first=slot, .n=1}; b.h[0] = (uint64_t)tid; state_op(OP_BIND_TEX, &b); }
static void bind_samp(int sid) { p_bind_handles b = {.stage=1, .first=0, .n=1}; b.h[0] = (uint64_t)sid << 20; state_op(OP_BIND_SAMP, &b); }
static void bind_ubo(const void *p) { p_bind_buf b = {.stage=1, .index=0, .addr=(uint64_t)(uintptr_t)p, .size=16}; state_op(OP_BIND_UBO, &b); }
static void bind_ssbo(const void *p) { p_bind_buf b = {.stage=1, .index=3, .addr=(uint64_t)(uintptr_t)p, .size=16}; state_op(OP_BIND_SSBO, &b); }
static void push(uint32_t v) { _Alignas(8) uint8_t buf[sizeof(p_push_const) + 4]; p_push_const *b = (p_push_const *)buf; b->compute = 0; b->offset = 0; b->size = 4; memcpy(b->data, &v, 4); state_op(OP_PUSH_CONST, b); }

// What the draws should show: the state as the P shader reads it
static const uint8_t TXA[2][4] = {{40, 10, 0, 255}, {80, 10, 0, 255}}, TXB[2][4] = {{120, 200, 0, 255}, {160, 200, 0, 255}};
static struct { int t0, t1, rep; const float *ub, *sb; uint32_t binst; } st;
static const uint8_t (*tx(int tid))[4] { return tid == TB ? TXB : TXA; }
static void want_p(uint8_t w[4]) {
    w[0] = tx(st.t0)[st.rep ? 0 : 1][0]; w[1] = tx(st.t1)[0][1]; w[2] = (uint8_t)lrintf(st.sb[0] * st.ub[0] * 255.0f); w[3] = (uint8_t)st.binst;
}

static tex_t g_out; static id<MTLTexture> g_out_tex; static int g_px; static uint8_t g_want[W][4];
static void next_pass(void) { rp_end(); R.clear_c[0] = 0; CHECK(rp_begin() != nil, "render pass opens"); }
static void xdraw(NvShader *sh, id<MTLRenderPipelineState> p, const uint8_t want[4]) {
    CHECK(g_px < W, "room for the draw"); if (g_px >= W) return;
    if (g_ast_on) ast_draw();
    enc_r_pso(g_enc, p); enc_r_viewport(g_enc, (MTLViewport){g_px, 0, 1, 1, 0, 1});
    CHECK(encode_args((id<MTL4CommandEncoder>)g_enc, sh, 1, 0), "fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    for (int i = 0; i < g_nsd; i++) if (g_sd[i].idx == 0) { g_sd[i].wrote = g_sd[i].rast = 1; }
    memcpy(g_want[g_px++], want, 4);
}
typedef struct { uint64_t e, r, p, q, x; } cnt;
static cnt take(void) { return (cnt){g_stat_args_enc, g_stat_args_reuse, g_stat_args_patch, g_stat_args_partial, g_stat_args_xpass}; }
// One draw of sh: a partial patch when the switch is on and part says so, else a full encode (full: always a full encode)
static id<MTLRenderPipelineState> g_ppso;
static void step_p(NvShader *sh, int part, const char *label) {
    uint8_t w[4]; want_p(w); cnt a = take(); xdraw(sh, g_ppso, w); cnt b = take();
    char l[240]; int pp = part && P;
    snprintf(l, sizeof l, "%s: %s", label, pp ? "a partial patch" : "a full encode");
    CHECK(b.e - a.e == (uint64_t)!pp && b.q - a.q == (uint64_t)pp && b.p - a.p == (uint64_t)pp && b.r == a.r, l);
}
static void begin(void) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &g_out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(rp_begin() != nil, "first render pass opens"); R.clear_c[0] = 0; g_px = 0;
    st.t0 = st.t1 = TA; st.rep = 0; st.ub = u1; st.sb = sa; st.binst = 7; g_draw_binst = 7;
    bind_tex(0, TA); bind_tex(1, TA); bind_samp(S_CLAMP); bind_ubo(u1); bind_ssbo(sa);
}
static void finish(id<MTLBuffer> rb, const char *label) {
    rp_end(); enc_b_copy_texture_buffer(blit(), g_out_tex, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(W, 1, 1), rb, 0, 4 * W, 4 * W);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "GPU submission completed");
    int bad = -1;
    for (int x = 0; x < g_px && bad < 0; x++) { const uint8_t *p = (const uint8_t *)rb.contents + 4 * x, *w = g_want[x];
        for (int k = 0; k < 4; k++) if (abs((int)p[k] - (int)w[k]) > 1) { bad = x; break; } }
    if (bad >= 0) { const uint8_t *p = (const uint8_t *)rb.contents + 4 * bad, *w = g_want[bad]; fprintf(stderr, "pixel %d: %u,%u,%u,%u, want %u,%u,%u,%u\n", bad, p[0], p[1], p[2], p[3], w[0], w[1], w[2], w[3]); }
    CHECK(bad < 0, label);
}

static void cases(NvShader *fp, NvShader *fq, NvShader *fn_, NvShader *fd, id<MTLRenderPipelineState> pn, id<MTLRenderPipelineState> pd, id<MTLBuffer> rb) {
    begin();
    step_p(fp, 0, "the first draw");
    bind_tex(0, TB); st.t0 = TB;
    uint64_t tm = 0, sm = 0; int pk = P ? args_partial(fp, 1, 1, 0, &tm, &sm) : 0;
    if (P) CHECK(pk == PK_TEX && tm == 1 && sm == 0, "a texture slot 0 change: the history holds a texture change of slot 0 only");
    step_p(fp, 1, "a texture alone");
    bind_samp(S_REPEAT); st.rep = 1;
    step_p(fp, 1, "a sampler alone");
    uint32_t g0 = g_sbw_gen;
    bind_ssbo(sbb); st.sb = sbb;
    step_p(fp, 1, "a storage buffer alone");
    CHECK(g_sbw_gen != g0, "the storage patch notes its storage write (sbw_note)");
    g0 = g_sbw_gen; bind_tex(1, TB); st.t1 = TB;
    if (P) { pk = args_partial(fp, 1, 1, 0, &tm, &sm); CHECK(pk == PK_TEX && tm == 2, "a texture slot 1 change: slot 1 only (slot 0 kept)"); }
    uint64_t w0 = g_ast.pslot[0], k0 = g_ast.pslot[1];
    step_p(fp, 1, "the other texture slot alone");
    if (P && g_ast_on) CHECK(g_ast.pslot[0] - w0 == 1 && g_ast.pslot[1] - k0 == 2, "only that texture binding written again (the other and the sampler kept)");
    if (P) CHECK(g_sbw_gen == g0, "a texture patch notes no storage write (it keeps the storage entries)");
    g_draw_binst = st.binst = 33;
    step_p(fp, 1, "a base instance alone");
    bind_tex(0, TA); st.t0 = TA; bind_ubo(u2); st.ub = u2;
    step_p(fp, 1, "a texture and a uniform buffer together");
    // changes made while another shader of the stage wrote its block in between: both are seen
    bind_tex(1, TA); st.t1 = TA;
    { uint8_t w[4]; want_p(w); xdraw(fq, g_ppso, w); }
    bind_ssbo(sa); st.sb = sa;
    { uint8_t w[4]; want_p(w); xdraw(fq, g_ppso, w); }
    bind_samp(S_CLAMP); st.rep = 0;
    if (P) { pk = args_partial(fp, 1, 1, 0, &tm, &sm); CHECK((pk & ~PK_X) == (PK_TEX | PK_SSBO | PK_SAMP) && tm == 2 && sm == 1, "three changes with blocks of another shader between them: all three in the history"); }
    step_p(fp, 1, "texture, storage and sampler changes over another shader's blocks");
    // any hard change with them: in full
    bind_tex(0, TB); st.t0 = TB;
    { tex_t *tc = calloc(1, sizeof *tc); texture(tc, 2); tc->mem = mem + 0x6000; tc->L.size = 8; mtl_reg_tex(TC, tc, NULL); }
    step_p(fp, 0, "a texture change and a registration");
    bind_tex(0, TA); st.t0 = TA; push(5);
    step_p(fp, 0, "a texture change and push constants");
    bind_ssbo(sbb); st.sb = sbb;
    { p_bind_handles b = {.stage=1, .first=0, .n=1}; b.h[0] = TA; state_op(OP_BIND_IMG, &b); }
    step_p(fp, 0, "a storage change and an image binding");
    // a later pass: the cross-pass rule's block is patched too
    next_pass(); bind_tex(0, TB); st.t0 = TB;
    cnt a = take();
    step_p(fp, 1, "a texture change in a later pass");
    if (P) CHECK(take().x - a.x == 1, "counted as across passes (@args_xpass)");
    next_pass(); g_draw_binst = st.binst = 9;
    step_p(fp, 1, "a base instance change in a later pass");
    // more changes than the history has entries (another shader's block between each, so none is folded into the last): the oldest are joined, every change still seen
    for (int i = 0; i < PK_RING + 3; i++) {
        if (i == 1) { st.sb = st.sb == sa ? sbb : sa; bind_ssbo(st.sb); }   // each one a change: the other value
        else if (i == 2) { st.rep = !st.rep; bind_samp(st.rep ? S_REPEAT : S_CLAMP); }
        else if (i == 0) { st.t0 = st.t0 == TA ? TB : TA; bind_tex(0, st.t0); }
        else { st.t1 = st.t1 == TA ? TB : TA; bind_tex(1, st.t1); }
        uint8_t w[4]; want_p(w); xdraw(fq, g_ppso, w); }
    CHECK(!P || g_args_pk[1].n == PK_RING, "the history full");
    if (P) { pk = args_partial(fp, 1, 1, 0, &tm, &sm); CHECK((pk & ~PK_X) == (PK_TEX | PK_SSBO | PK_SAMP) && tm == 3 && sm == 1, "an older block sees the joined entries: both texture slots, the storage buffer, the sampler"); }
    step_p(fp, 1, "more changes than the history has entries");
    st.t1 = st.t1 == TA ? TB : TA; bind_tex(1, st.t1); for (int i = 0; i < 3; i++) { uint8_t w[4]; want_p(w); xdraw(fq, g_ppso, w); }   // one change, then fq's reuses: no new entry
    if (P) { pk = args_partial(fp, 1, 1, 0, &tm, &sm); CHECK((pk & ~PK_X) == PK_TEX && tm == 2, "and then one more: only it"); }
    step_p(fp, 1, "and then one more");
    // a shader that reads no uniform keeps its block after a uniform change
    { const uint8_t *tw = tx(st.t0)[st.rep ? 0 : 1]; xdraw(fn_, pn, tw); }
    bind_ubo(u1); st.ub = u1;
    { const uint8_t *tw = tx(st.t0)[st.rep ? 0 : 1]; cnt c0 = take(); xdraw(fn_, pn, tw); cnt c1 = take();
      CHECK(P ? c1.r - c0.r == 1 && c1.e == c0.e : c1.e - c0.e == 1, P ? "a shader that reads no uniform: its block is reused after a uniform change" : "a shader that reads no uniform: encoded after a uniform change (switch off)"); }
    // a dynamic handle array (TEXD): patched after a uniform change, and after a texture change
    { uint8_t w[4] = {tx(st.t0)[st.rep ? 0 : 1][0], tx(st.t1)[0][1], 0, 255}; xdraw(fd, pd, w); }
    bind_ubo(u2); st.ub = u2;
    { uint8_t w[4] = {(uint8_t)(tx(st.t0)[st.rep ? 0 : 1][0] / 2), tx(st.t1)[0][1], 0, 255}; cnt c0 = take(); xdraw(fd, pd, w); cnt c1 = take();
      CHECK(P ? c1.p - c0.p == 1 && c1.e == c0.e : c1.e - c0.e == 1, P ? "a TEXD shader: patched after a uniform change" : "a TEXD shader: encoded after a uniform change (switch off)"); }
    st.t1 = st.t1 == TA ? TB : TA; bind_tex(1, st.t1);
    { uint8_t w[4] = {(uint8_t)(tx(st.t0)[st.rep ? 0 : 1][0] / 2), tx(st.t1)[0][1], 0, 255}; cnt c0 = take(); xdraw(fd, pd, w); cnt c1 = take();
      CHECK(P ? c1.q - c0.q == 1 && c1.e == c0.e : c1.e - c0.e == 1, P ? "a TEXD shader: a partial patch after a texture change" : "a TEXD shader: encoded after a texture change (switch off)"); }
    finish(rb, "every draw of the first submission wrote what its bindings named");
    // another submission: its blocks are never patched from the last one's
    begin(); bind_tex(0, TB); st.t0 = TB;
    step_p(fp, 0, "a texture change into a new submission");
    bind_tex(0, TA); st.t0 = TA;
    step_p(fp, 1, "and a texture change within it");
    finish(rb, "every draw of the second submission wrote what its bindings named");
}

// Encode cost: full encode against a partial patch of each kind, a shader with 16 textures, 8 samplers, 4 uniform slots, 2 storage buffers, c0
static void bench(id<MTLLibrary> lib) {
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = t4_fn(lib, @"big"); strcpy(s->key, "7800000000000000");
    s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    int n = 0;
    for (int i = 0; i < 16; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=i, .aid=n, .dtt=MTLTextureType2D};
    for (int i = 0; i < 8; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=i, .aid=n};
    for (int i = 0; i < 4; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=i, .aid=n};
    for (int i = 0; i < 2; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SBUFP, .reg=i, .aid=n};
    s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_DRV0, .aid=n}; n++; s->rf.drv_read[0] = 1;
    s->rf.nb = n;
    begin();
    for (int i = 0; i < 16; i++) S.tex[1][i] = i & 1 ? TB : TA;
    for (int i = 0; i < 8; i++) S.samp[1][i] = (uint64_t)(i & 1 ? S_REPEAT : S_CLAMP) << 20;
    for (int i = 0; i < 4; i++) S.ubo[1][i] = (p_bind_buf){.addr=(uint64_t)(uintptr_t)u1, .size=16};
    for (int i = 0; i < 2; i++) S.ssbo[1][i] = (p_bind_buf){.addr=(uint64_t)(uintptr_t)sa, .size=16};
    args_dirty_all();
    enum { N = 20000, ROUNDS = 5, MODES = 6 }; double best[MODES]; for (int m = 0; m < MODES; m++) best[m] = 1e9;
    static const char *const name[MODES] = {"full encode", "texture (1 of 16 slots)", "sampler (1 of 8)", "storage buffer", "base instance", "texture + uniform"};
    for (int r = 0; r < ROUNDS; r++) for (int mode = 0; mode < MODES; mode++) {
        encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
        uint64_t e0 = g_stat_args_enc, q0 = g_stat_args_partial, t0 = bp_now();
        for (int i = 0; i < N; i++) {
            switch (mode) {
                case 0: args_dirty_all(); break;
                case 1: { p_bind_handles b = {.stage=1, .first=3, .n=1}; b.h[0] = (uint64_t)(i & 1 ? TB : TA); state_op(OP_BIND_TEX, &b); break; }
                case 2: { p_bind_handles b = {.stage=1, .first=2, .n=1}; b.h[0] = (uint64_t)(i & 1 ? S_CLAMP : S_REPEAT) << 20; state_op(OP_BIND_SAMP, &b); break; }
                case 3: { p_bind_buf b = {.stage=1, .index=1, .addr=(uint64_t)(uintptr_t)(i & 1 ? sa : sbb), .size=16}; state_op(OP_BIND_SSBO, &b); break; }
                case 4: g_draw_binst = (uint32_t)i; break;
                case 5: { p_bind_handles b = {.stage=1, .first=3, .n=1}; b.h[0] = (uint64_t)(i & 1 ? TB : TA); state_op(OP_BIND_TEX, &b);
                          p_bind_buf u = {.stage=1, .index=2, .addr=(uint64_t)(uintptr_t)(i & 1 ? u1 : u2), .size=16}; state_op(OP_BIND_UBO, &u); break; }
            }
            encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
        }
        double ns = (double)(bp_now() - t0) / N; if (ns < best[mode]) best[mode] = ns;
        if (!r) { char l[160]; int full = mode == 0 || !P;
            snprintf(l, sizeof l, "bench %s: %s", name[mode], full ? "every call a full encode" : "every call a partial patch");
            CHECK(full ? g_stat_args_enc - e0 == N : g_stat_args_partial - q0 == N && g_stat_args_enc == e0, l); }
    }
    printf("t_args_partial bench (%d bindings, %d calls, best of %d%s):", n, N, ROUNDS, P ? "" : ", switch off");
    for (int m = 0; m < MODES; m++) printf(" %s %.0f ns%s", name[m], best[m], m < MODES - 1 ? "," : "\n");
    rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "bench submission completed");
}

int main(void) { @autoreleasepool {
    alarm(120);
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1); setenv("DM_PSO_RECORD", "/dev/null", 1);
    const char *e = getenv("DM_NVN_ARGS_PARTIAL"); int env_off = e && !strcmp(e, "0");
    mtl_init(); NSError *error = nil;
    CHECK(g_args_partial == !env_off, env_off ? "DM_NVN_ARGS_PARTIAL=0 turns partial patches off" : "partial patches are on by default");
    NSMutableString *src = [NSMutableString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A { texture2d<float> t0 [[id(0)]]; texture2d<float> t1 [[id(1)]]; sampler s [[id(2)]]; constant float4 *c [[id(3)]]; device float4 *sb [[id(4)]]; constant uint *c0 [[id(5)]]; };\n"
        "fragment float4 fp(constant A &a [[buffer(0)]]) { return float4(a.t0.sample(a.s, float2(1.25, 0.5), level(0)).r, a.t1.sample(a.s, float2(0.25, 0.5), level(0)).g, a.sb[0].x * a.c[0].x, float(a.c0[%d]) / 255.0); }\n"
        "struct N { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; };\n"
        "fragment float4 fn(constant N &a [[buffer(0)]]) { return a.t.sample(a.s, float2(1.25, 0.5), level(0)); }\n"
        "struct D { array<texture2d<float>, 2> td [[id(0)]]; sampler s [[id(2)]]; constant float4 *c [[id(3)]]; };\n"
        "fragment float4 fd(constant D &a [[buffer(0)]]) { return float4(a.td[0].sample(a.s, float2(1.25, 0.5), level(0)).r * a.c[0].x, a.td[1].sample(a.s, float2(0.25, 0.5), level(0)).g, 0, 1); }\n"
        "struct B {", DMSH_C0_BASE_INSTANCE / 4];
    for (int i = 0; i < 16; i++) [src appendFormat:@" texture2d<float> t%d [[id(%d)]];", i, i];
    for (int i = 0; i < 8; i++) [src appendFormat:@" sampler s%d [[id(%d)]];", i, 16 + i];
    for (int i = 0; i < 4; i++) [src appendFormat:@" constant float4 *c%d [[id(%d)]];", i, 24 + i];
    for (int i = 0; i < 2; i++) [src appendFormat:@" device float4 *b%d [[id(%d)]];", i, 28 + i];
    [src appendString:@" constant uint *d0 [[id(30)]]; };\nfragment float4 big(constant B &a [[buffer(0)]]) { return a.t0.sample(a.s0, float2(0.5)) + a.t15.sample(a.s7, float2(0.5)) + a.c0[0] + a.c3[0] + a.b0[0] + a.b1[0] + float(a.d0[0]); }\n"];
    id<MTLLibrary> lib = t4_lib(src, nil, &error);
    CHECK(lib != nil, "synthetic shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    g_ppso = pso(lib, @"fp"); id<MTLRenderPipelineState> pn = pso(lib, @"fn"), pd = pso(lib, @"fd"); if (!g_ppso || !pn || !pd) return 2;
    mem = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 2;
    mtl_pool_add(mem, 0x10000);
    u1 = (float *)(mem + 0x100); u1[0] = 1; u2 = (float *)(mem + 0x200); u2[0] = 0.5f;
    sa = (float *)(mem + 0x7000); sa[0] = 0.4f; sbb = (float *)(mem + 0x7100); sbb[0] = 0.8f;
    tex_t ta, tb; id<MTLTexture> xa = texture(&ta, 2), xb = texture(&tb, 2); if (!xa || !xb) return 2;
    [xa replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:TXA bytesPerRow:8]; [xb replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:TXB bytesPerRow:8];
    ta.mem = mem + 0x1000; ta.L.size = 8; memcpy((void *)ta.mem, TXA, 8); tb.mem = mem + 0x2000; tb.L.size = 8; memcpy((void *)tb.mem, TXB, 8);
    mtl_reg_tex(TA, &ta, NULL); mtl_reg_tex(TB, &tb, NULL);
    samp_par sp = {.minf=NVN_MIN_FILTER_NEAREST, .magf=NVN_MAG_FILTER_NEAREST, .ws=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wt=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wr=NVN_WRAP_MODE_CLAMP_TO_EDGE, .lod_max=1000};
    mtl_reg_samp(S_CLAMP, &sp); sp.ws = NVN_WRAP_MODE_REPEAT; mtl_reg_samp(S_REPEAT, &sp);
    g_out_tex = texture(&g_out, W); if (!g_out_tex) return 2;
    id<MTLBuffer> rb = [g_dev newBufferWithLength:4 * W options:MTLResourceStorageModeShared]; res_add(rb);
    id<MTLFunction> ffp = t4_fn(lib, @"fp");
    NvShader *fp = shader_p(ffp), *fq = shader_p(ffp);
    nvn_rbind bn[2] = {{.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=1}};
    NvShader *fn_ = shader(t4_fn(lib, @"fn"), 2, bn);
    nvn_rbind bd[3] = {{.kind=NVN_RB_TEXD, .aid=0, .n=2, .dtt=MTLTextureType2D}, {.kind=NVN_RB_SAMP, .reg=0, .aid=2}, {.kind=NVN_RB_CBUF, .reg=0, .aid=3}};
    NvShader *fd = shader(t4_fn(lib, @"fd"), 3, bd); fd->rf.dyn = 1;
    CHECK(args_xpass_on(), "the cross-pass rule is on");
    P = g_args_partial > 0;
    cases(fp, fq, fn_, fd, pn, pd, rb);
    if (P && g_ast_on) {
        CHECK(g_ast.n[4] == g_stat_args_partial && g_ast.n[1] + g_ast.n[4] == g_stat_args_patch, "DM_NVN_ARGS_STATS: partial patches timed apart from the uniform patches");
        CHECK(g_ast.part[0] >= 6 && g_ast.part[1] >= 2 && g_ast.part[2] >= 2 && g_ast.part[3] >= 2 && g_ast.part[4] >= 1, "partial patches counted by kind");
        uint64_t pc = 0; for (int i = 0; i < PKC_N; i++) pc += g_ast.pn[i];
        CHECK(pc == g_stat_args_partial && g_ast.pn[PKC_TEX] >= 3 && g_ast.pn[PKC_SSBO] >= 1 && g_ast.pn[PKC_BINST] >= 2 && g_ast.pn[PKC_MIX] >= 2, "and their time by class");
        CHECK(mtl_args_stats_log(1000, 10) == 7 + g_bl_on, "seven [args-stats] lines: causes, patches, time, texture lookups, partial patches, levers, shaders (and slot tables with DM_NVN_BINDLESS=1)");
    }
    if (!env_off) {   // the switch off in the same run: the same draws, all encoded in full, the same pixels
        g_args_partial = 0; P = 0; args_dirty_all();
        fp->ab_pkind = fq->ab_pkind = fn_->ab_pkind = fd->ab_pkind = 0;
        uint64_t uk = g_ast.ubok[NVN_RB_TEXD], u0 = g_ast.ubok[0];
        cases(fp, fq, fn_, fd, pn, pd, rb);
        if (g_ast_on) CHECK(g_ast.ubok[NVN_RB_TEXD] - uk == 1 && g_ast.ubok[0] - u0 == 1, "DM_NVN_ARGS_STATS, switch off: ubo_unpatchable counted by the kind that kept each shader off the patch (TEXD; none for no uniform slot)");
        g_args_partial = 1; P = 1; args_dirty_all();
    }
    bench(lib);
    if (g_bl_on) CHECK(g_bls.mism == 0 && g_bls.enc > 0, "DM_NVN_BINDLESS=1: slot tables checked against every texture and sampler the slot path resolved, no mismatch");
    printf("t_args_partial%s: %d checks, %d failed\n", env_off ? " (DM_NVN_ARGS_PARTIAL=0)" : "", checks, failed);
    return failed != 0;
} }
