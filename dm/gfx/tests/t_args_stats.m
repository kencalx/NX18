// DM_NVN_ARGS_STATS: the reasons full argument encodes are counted under (encode_args_ ast_fresh_why), the patch and registration counts, the time split, the shader table and the
// "[args-stats]" lines. Each step draws one pixel with one change before it and checks that exactly one full encode was counted, under that change's reason: a new texture handle,
// sampler, storage binding, push constants, texture and memory-pool registrations, a guest write, a host compute encoder, the shader's first encode, another submission, and with
// the cross-pass rule off a new pass and a program change. Without the switch nothing is counted and no line is written. Run with and without DM_NVN_ARGS_STATS=1.
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
enum { W = 32, TA = 1, TB = 2, TC = 9, S_CLAMP = 1, S_REPEAT = 2 };
static float *u1, *u2;
static int on;   // DM_NVN_ARGS_STATS=1

static id<MTLTexture> texture(tex_t *t, int width) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=width, .height=1, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
    CHECK(out != nil, "texture allocated");
    if (out) { res_add(out); mtl_tex_init(t); serial_put(t->serial, out); }
    return out;
}
static NvShader *shader(id<MTLFunction> fn, uint64_t id_) {
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = fn; snprintf(s->key, sizeof s->key, "%016llx", (unsigned long long)id_);
    s->arg_len = [fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    s->rf.nb = 3;
    s->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D};
    s->rf.b[1] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=0, .aid=1};
    s->rf.b[2] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=0, .aid=2};
    return s;
}
static void bind_tex(int tid) { p_bind_handles b = {.stage=1, .first=0, .n=1}; b.h[0] = (uint64_t)tid; state_op(OP_BIND_TEX, &b); }
static void bind_samp(int sid) { p_bind_handles b = {.stage=1, .first=0, .n=1}; b.h[0] = (uint64_t)sid << 20; state_op(OP_BIND_SAMP, &b); }
static void bind_ubo(int reg, const void *p) { p_bind_buf b = {.stage=1, .index=reg, .addr=(uint64_t)(uintptr_t)p, .size=16}; state_op(OP_BIND_UBO, &b); }
static void bind_prog(const prog_t *p) { p_bind_program b = {.prog=p, .stages=0x1f}; state_op(OP_BIND_PROGRAM, &b); }
static void push(uint32_t v) { _Alignas(8) uint8_t buf[sizeof(p_push_const) + 4]; p_push_const *b = (p_push_const *)buf; b->compute = 0; b->offset = 0; b->size = 4; memcpy(b->data, &v, 4); state_op(OP_PUSH_CONST, b); }

static id<MTLRenderPipelineState> g_spso; static tex_t g_out; static int g_px;
static void next_pass(void) { rp_end(); R.clear_c[0] = 0; CHECK(rp_begin() != nil, "render pass opens"); enc_r_pso(g_enc, g_spso); }
static void xdraw(NvShader *sh) {
    CHECK(g_px < W, "room for the draw"); if (g_px >= W) return;
    if (g_ast_on) ast_draw();   // what draw() does first
    enc_r_viewport(g_enc, (MTLViewport){g_px++, 0, 1, 1, 0, 1});
    CHECK(encode_args((id<MTL4CommandEncoder>)g_enc, sh, 1, 0), "fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
}
static uint64_t enc_n(void) { return g_stat_args_enc; }
static uint64_t sum_fresh(void) { uint64_t n = 0; for (int i = 0; i < AW_N; i++) n += g_ast.fresh[i]; return n; }
// One draw: with the switch, exactly one full encode counted, under why; without it, one encode and nothing counted
static void step(NvShader *sh, int why, const char *label) {
    uint64_t e0 = enc_n(), f0 = sum_fresh(), w0 = g_ast.fresh[why];
    xdraw(sh);
    char l[200];
    snprintf(l, sizeof l, "%s: one full encode", label); CHECK(enc_n() - e0 == 1, l);
    if (on) { snprintf(l, sizeof l, "%s: counted under %s", label, g_aw_name[why]); CHECK(sum_fresh() - f0 == 1 && g_ast.fresh[why] - w0 == 1, l);
              if (sum_fresh() - f0 == 1 && g_ast.fresh[why] - w0 != 1) for (int i = 0; i < AW_N; i++) if (g_ast.fresh[i]) fprintf(stderr, "  %s %llu\n", g_aw_name[i], (unsigned long long)g_ast.fresh[i]); }
    else CHECK(sum_fresh() == 0, "switch off: nothing counted");
}
static void begin(void) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &g_out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(rp_begin() != nil, "first render pass opens"); enc_r_pso(g_enc, g_spso); R.clear_c[0] = 0; g_px = 0;
    bind_tex(TA); bind_samp(S_CLAMP); bind_ubo(0, u1);
}
static void finish(void) { rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "GPU submission completed"); }

int main(void) { @autoreleasepool {
    alarm(120);
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1); setenv("DM_PSO_RECORD", "/dev/null", 1);
    const char *e = getenv("DM_NVN_ARGS_STATS"); on = e && atoi(e) > 0;
    mtl_init(); NSError *error = nil;
    g_args_partial = 0;   // the full encodes' reasons, texture, sampler and storage changes among them: with partial patches those are patched (t_args_partial counts them)
    CHECK(g_ast_on == on, on ? "DM_NVN_ARGS_STATS=1 turns the counts on" : "the counts are off by default");
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A { texture2d<float> t [[id(0)]]; sampler s [[id(1)]]; constant float4 *c [[id(2)]]; };\n"
        "fragment float4 f(constant A &a [[buffer(0)]]) { return a.t.sample(a.s, float2(0.5), level(0)) * a.c[0].x; }\n";
    id<MTLLibrary> lib = t4_lib(src, nil, &error);
    CHECK(lib != nil, "synthetic shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = t4_fn(lib, @"v"); d.fragmentFunction = t4_fn(lib, @"f"); d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    g_spso = t4_rps(d, &error); CHECK(g_spso != nil, "render pipeline compiles"); if (!g_spso) return 2;
    mem = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 2;
    mtl_pool_add(mem, 0x10000);
    u1 = (float *)(mem + 0x100); u1[0] = 1; u2 = (float *)(mem + 0x200); u2[0] = 0.5f;
    tex_t ta, tb; if (!texture(&ta, 2) || !texture(&tb, 2)) return 2;
    ta.mem = mem + 0x1000; ta.L.size = 8; tb.mem = mem + 0x2000; tb.L.size = 8;
    mtl_reg_tex(TA, &ta, NULL); mtl_reg_tex(TB, &tb, NULL);
    samp_par sp = {.minf=NVN_MIN_FILTER_NEAREST, .magf=NVN_MAG_FILTER_NEAREST, .ws=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wt=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wr=NVN_WRAP_MODE_CLAMP_TO_EDGE, .lod_max=1000};
    mtl_reg_samp(S_CLAMP, &sp); sp.ws = NVN_WRAP_MODE_REPEAT; mtl_reg_samp(S_REPEAT, &sp);
    if (!texture(&g_out, W)) return 2;
    id<MTLFunction> ff = t4_fn(lib, @"f");
    NvShader *fa = shader(ff, 0x7500000000000001ull), *fb = shader(ff, 0x7500000000000002ull);
    static prog_t pa = {.serial = 980001}, pb = {.serial = 980002};
    CHECK(args_xpass_on(), "the cross-pass rule is on by default");

    begin(); bind_prog(&pa);
    step(fa, AW_FIRST, "the shader's first encode");
    bind_tex(TB); step(fa, AW_TEX, "a new texture handle");
    bind_samp(S_REPEAT); step(fa, AW_SAMP, "a new sampler");
    { p_bind_buf b = {.stage=1, .index=3, .addr=(uint64_t)(uintptr_t)(mem + 0x7000), .size=64}; state_op(OP_BIND_SSBO, &b); }
    step(fa, AW_SSBO, "a storage binding");
    push(7); step(fa, AW_PUSH, "push constants");
    uint64_t d0 = g_ast.draws_reg, r0 = g_ast.regs_between;
    { tex_t *tc = calloc(1, sizeof *tc); texture(tc, 2); tc->mem = mem + 0x6000; tc->L.size = 8; mtl_reg_tex(TC, tc, NULL); mtl_reg_tex(TC + 1, tc, NULL); }
    step(fa, AW_REG_TEX, "texture registrations");
    if (on) CHECK(g_ast.draws_reg - d0 == 1 && g_ast.regs_between - r0 == 2, "a draw after two registrations: one draw with registrations, two between");
    { void *pool; if (posix_memalign(&pool, getpagesize(), 0x4000)) abort(); memset(pool, 0, 0x4000); mtl_pool_add(pool, 0x4000); }
    step(fa, AW_REG_POOL, "a new memory pool");
    { void *page; if (posix_memalign(&page, getpagesize(), getpagesize())) abort(); nvn_dirty_add_range(page, getpagesize()); }
    step(fa, AW_GWRITE, "a guest write stamp");
    uint64_t p0 = g_ast.patch[0], pt0 = g_stat_args_patch;
    bind_ubo(0, u2); xdraw(fa);
    CHECK(g_stat_args_patch - pt0 == 1, "a new uniform address patches");
    if (on) CHECK(g_ast.patch[0] - p0 == 1, "the patch is counted under the uniform binding");
    rp_end(); enc_c_end(enc_c_own()); next_pass();
    step(fa, AW_HOST_CS, "a host compute encoder in between");
    step(fb, AW_FIRST, "another shader's first encode");
    bind_prog(&pb); bind_prog(&pa); next_pass();
    uint64_t e0 = enc_n(); xdraw(fa); CHECK(enc_n() == e0, "across a pass and program change with the rule on: reused");
    g_args_xpass = 0;   // the pass rule alone: a new pass or program encodes again
    next_pass(); step(fa, AW_PASS, "the rule off: a new pass");
    bind_prog(&pb); bind_prog(&pa); step(fa, AW_PROG, "the rule off: a program change");
    g_args_xpass = 1;
    finish();
    begin(); bind_prog(&pa); bind_tex(TB); bind_samp(S_REPEAT); bind_ubo(0, u2); push(7);
    { p_bind_buf b = {.stage=1, .index=3, .addr=(uint64_t)(uintptr_t)(mem + 0x7000), .size=64}; state_op(OP_BIND_SSBO, &b); }
    args_dirty_soft();   // as if the bindings had held: only the pass changed since its block (state_reset's own bindings were hard changes)
    g_args_hgen[1] = fa->ast_hgen;
    step(fa, AW_NEWSUB, "a block of the last submission");
    finish();

    if (on) {
        CHECK(g_ast.n[0] == g_stat_args_enc && g_ast.n[1] == g_stat_args_patch && g_ast.n[2] == g_stat_args_reuse, "encode_args timed once a call, by outcome");
        uint64_t sg = 0; for (int i = 0; i < AG_N; i++) sg += g_ast.tg[i];
        CHECK(g_ast.t[0] > 0 && sg > 0 && sg <= g_ast.t[0], "the full encodes' time by kind is within their whole time");
        CHECK(g_ast.tg[AG_TEX] > 0 || g_ast.tg[AG_CBUF] > 0 || g_ast.tg[AG_TAIL] > 0, "some kind group timed");
        CHECK(g_ast.sync[0] >= 3 && g_ast.sync[1] >= 1 && g_ast.sync[2] >= 1 && g_ast.sync[3] >= 1, "the binding syncs count registrations, memory pools and guest writes");
        // the shader table: fa's entry holds its full encodes, slot counts and the reasons
        int w = atomic_load(&g_ast.kw) & 1; const ast_key_t *ka = NULL;
        for (int i = 0; i < AK_N; i++) if (g_ast.keys[w][i].sh == (__bridge void *)fa) ka = &g_ast.keys[w][i];
        CHECK(ka && !strcmp(ka->key, "7500000000000001") && ka->ntex == 1 && ka->nsamp == 1 && !ka->pool && ka->why[AW_TEX] == 1 && ka->why[AW_PUSH] == 1, "the shader table has the shader's counts");
        uint64_t fa_fresh = 0; for (int i = 0; i < AW_N; i++) fa_fresh += ka ? ka->why[i] : 0;
        CHECK(ka && ka->fresh == fa_fresh && ka->fresh >= 12, "its full encodes are the sum of its reasons");
        uint64_t tsn = 0; for (int i = 0; i < TS_N; i++) tsn += g_tsl.n[i];
        CHECK(tsn == tl_tex_slow_n && tsn > 0, "every texture lookup past the cached view is counted under one outcome");
        int lines = mtl_args_stats_log(1000, 10);
        CHECK(lines == 6, "six [args-stats] lines: causes, patches and syncs, time, texture lookups, levers, shaders");
        ka = NULL; for (int i = 0; i < AK_N; i++) if (g_ast.keys[w][i].sh) ka = &g_ast.keys[w][i];
        CHECK(!ka, "the line clears the table's half it read");
        CHECK((atomic_load(&g_ast.kw) & 1) != w, "and the other half is written from then on");
    } else {
        uint64_t any = 0; for (int i = 0; i < AW_N; i++) any |= g_ast.fresh[i];
        for (int i = 0; i < 4; i++) any |= g_ast.t[i] | g_ast.n[i];
        any |= g_ast.patch[0] | g_ast.patch[1] | g_ast.sync[0] | g_ast.draws | atomic_load(&g_ast_reg_ts) | atomic_load(&g_ast_reg_pool);
        CHECK(!any, "switch off: no counter moved");
        CHECK(mtl_args_stats_log(1000, 10) == 0, "switch off: no line");
    }
    // Cost of the counting: a shader with 16 textures, 8 samplers and 4 uniform slots encoded in full and reused, with the switch as it is and then the other way
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = ff; strcpy(s->key, "7600000000000000");
    id<MTLLibrary> lib2 = nil; {
        NSMutableString *bs = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct B {"];
        for (int i = 0; i < 16; i++) [bs appendFormat:@" texture2d<float> t%d [[id(%d)]];", i, i];
        for (int i = 0; i < 8; i++) [bs appendFormat:@" sampler s%d [[id(%d)]];", i, 16 + i];
        for (int i = 0; i < 4; i++) [bs appendFormat:@" constant float4 *c%d [[id(%d)]];", i, 24 + i];
        [bs appendString:@" };\nfragment float4 big(constant B &a [[buffer(0)]]) { return a.t0.sample(a.s0, float2(0.5)) + a.t15.sample(a.s7, float2(0.5)) + a.c0[0] + a.c3[0]; }\n"];
        lib2 = t4_lib(bs, nil, &error); }
    CHECK(lib2 != nil, "the bench shader compiles"); if (!lib2) return 2;
    s->fn = t4_fn(lib2, @"big"); s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    int n = 0;
    for (int i = 0; i < 16; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=i, .aid=n, .dtt=MTLTextureType2D};
    for (int i = 0; i < 8; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=i, .aid=n};
    for (int i = 0; i < 4; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=i, .aid=n};
    s->rf.nb = n;
    begin();
    for (int i = 0; i < 16; i++) S.tex[1][i] = i & 1 ? TB : TA;
    for (int i = 0; i < 8; i++) S.samp[1][i] = (uint64_t)(i & 1 ? S_REPEAT : S_CLAMP) << 20;
    for (int i = 0; i < 4; i++) S.ubo[1][i] = (p_bind_buf){.addr=(uint64_t)(uintptr_t)u1, .size=16};
    enum { N = 20000, ROUNDS = 5 }; double best[2][2] = {{1e9, 1e9}, {1e9, 1e9}};   // [switch][full, reuse]: the best of the rounds
    for (int r = 0; r < ROUNDS; r++) for (int sw = 0; sw < 2; sw++) {
        g_ast_on = sw ? (g_ast.keys[0] != NULL) : 0;   // the switch flipped in place (the counts need ast_init's table)
        if (sw && !g_ast_on) { static int once; if (!once++) printf("t_args_stats bench: the switch-on side needs DM_NVN_ARGS_STATS=1\n"); continue; }
        for (int mode = 0; mode < 2; mode++) {
            args_dirty_all(); encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
            uint64_t t0 = bp_now();
            for (int i = 0; i < N; i++) { if (mode == 0) args_dirty_all(); encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0); }
            double ns = (double)(bp_now() - t0) / N; if (ns < best[sw][mode]) best[sw][mode] = ns;
        }
    }
    g_ast_on = on;
    if (best[1][0] < 1e9) printf("t_args_stats bench (%d bindings, %d calls, best of %d): full encode %.0f ns off / %.0f ns on, reuse %.1f ns off / %.1f ns on\n", n, N, ROUNDS, best[0][0], best[1][0], best[0][1], best[1][1]);
    else printf("t_args_stats bench (%d bindings, %d calls, best of %d): full encode %.0f ns, reuse %.1f ns (switch off)\n", n, N, ROUNDS, best[0][0], best[0][1]);
    finish();
    printf("t_args_stats%s: %d checks, %d failed\n", on ? " (DM_NVN_ARGS_STATS=1)" : "", checks, failed);
    return failed != 0;
} }
