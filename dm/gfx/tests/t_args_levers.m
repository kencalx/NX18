// The argument-encoding levers (NX18-X2.0 bindless-study.md step 1, bindless-plan.md stage 1), each behind its own switch, with a Mac micro-benchmark each:
// - DM_NVN_POOL_MEMO (pool_gpu): a pool table lookup kept while the registration and storage generations, the submission, g_psnap_gen and (for a table whose walk left textures
//   out) the frame hold. Checked: a repeated lookup is a memo hit and returns what the first check returns; a registration, a storage change (texture tables only), a table built or
//   patched, a new submission and, with textures left out, a new frame each send the next lookup through pool_walk again; with the switch off no lookup is a memo hit.
// - DM_NVN_ARGS_DRV (drv_bank): a c0 / c2 driver bank per graphics stage, shared by the blocks of a submission while the stage's binding history holds every change since it was made.
//   Checked: after each kind of change the bank is reused, copied and patched, or made whole as expected, and holds the bytes of a bank made whole from the same state.
// - DM_NVN_ARGS_REGCHK (args_sync_dirty, args_rck, PK_POOL): a sync of texture / sampler registrations alone stamps each ID instead of moving every hard generation. Checked by pixel
//   readback: a block whose slots name no registered ID is reused, one naming the registered texture or sampler ID is encoded in full and draws the new data, a texture change with a
//   registration elsewhere is still a partial patch, a pool shader's tables are taken again (partial patch) and draw the re-registered texture, a registration with a replaced object, a
//   change without a note or a memory pool encodes in full, and a shader with a kind the check does not take (TEXD) encodes in full.
// - DM_NVN_POOL_ENTRY (pool_entry): an ID of a known texture type other than the table's answered before its storage, budget and stand-in checks, and the type taken from the
//   view record. Checked by a patch bench (two tables over 4,000 IDs, 300 registered again a round): every entry of both tables is the ID's texture or the dummy, on and off; it prints
//   a patch's time and its split (the DM_NVN_ARGS_STATS levers line's pool patch fields).
// Run with each switch at its default and at 0.
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
static uint64_t next_serial = 97000;
enum { W = 64, TA = 1, TB = 2, TC = 3, TD = 4, S_CLAMP = 1, S_REPEAT = 2 };
static id<MTLTexture> texture(tex_t *t, int width) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=width, .height=1, .depth=1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
    CHECK(out != nil, "texture allocated");
    if (out) { res_add(out); mtl_tex_init(t); serial_put(t->serial, out); }
    return out;
}
static tex_t g_tx[8];
static id<MTLTexture> g_txm[8];
static const uint8_t TEXEL[8][2][4] = {{{40, 10, 0, 255}, {80, 10, 0, 255}}, {{120, 200, 0, 255}, {160, 200, 0, 255}}, {{20, 60, 0, 255}, {30, 60, 0, 255}}, {{200, 90, 0, 255}, {220, 90, 0, 255}},
                                        {{100, 140, 0, 255}, {110, 140, 0, 255}}};
static void make_tex(int k, uint32_t off) {   // texture k (2 texels, TEXEL[k]) over pool memory at off
    if (g_txm[k]) return;
    g_txm[k] = texture(&g_tx[k], 2); g_tx[k].mem = mem + off; g_tx[k].L.size = 8;
    [g_txm[k] replaceRegion:MTLRegionMake2D(0, 0, 2, 1) mipmapLevel:0 withBytes:TEXEL[k] bytesPerRow:8]; memcpy((void *)g_tx[k].mem, TEXEL[k], 8);
}
static void reg_tex_at(int tid, int k, uint32_t off) { make_tex(k, off); mtl_reg_tex(tid, &g_tx[k], NULL); }   // registered at tid

// ---------- DM_NVN_POOL_MEMO ----------
static uint64_t lookup(int samp, __unsafe_unretained id<MTLBuffer> *b, int *how) {
    rmu_lock(); uint64_t g = samp ? pool_gpu(1, 0, 0, 0, b) : pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, 0, b); *how = g_pw_how; os_unfair_lock_unlock(&g_rmu);
    return g;
}
static pool_snap *snap2d(void) { for (int k = 0; k < POOL_SNAPS; k++) if (g_psnap[k].buf && !g_psnap[k].samp && g_psnap[k].dtt == MTLTextureType2D && g_psnap[k].dpf == NVN_DPF_FLOAT && !g_psnap[k].base) return &g_psnap[k]; return NULL; }
static void memo_cases(void) {
    const int M = g_pool_memo > 0; const int HIT = M ? PW_MEMO : PW_FAST;
    mtl_sub_begin();
    __unsafe_unretained id<MTLBuffer> b0 = nil, b1 = nil; int how = -1;
    uint64_t g0 = lookup(0, &b0, &how);
    CHECK(g0 && b0 && how != PW_MEMO, "the first lookup of a submission goes through pool_walk");
    uint64_t g1 = lookup(0, &b1, &how);
    CHECK(how == HIT && g1 == g0 && b1 == b0, M ? "a repeated lookup is a memo hit, with what the first check returned" : "switch off: a repeated lookup takes the first check");
    // a registration: the next lookup takes the table's patch path (the new ID's entry written), then it is kept again
    reg_tex_at(TD, 3, 0x3000);
    uint64_t g2 = lookup(0, &b1, &how);
    CHECK(how == PW_PATCHED || how == PW_KEPT, "after a registration the lookup patches or keeps the table (no memo)");
    CHECK(b1 && ((const uint64_t *)((const uint8_t *)b1.contents + DMSH_POOL_HEAD))[TD] == g_txm[3].gpuResourceID._impl, "and the table holds the newly registered texture");
    uint64_t g3 = lookup(0, &b0, &how);
    CHECK(how == HIT && g3 == g2 && b0 == b1, "then it is kept again");
    // the sampler table: kept over a storage change, which the texture table is not
    __unsafe_unretained id<MTLBuffer> s0 = nil, s1 = nil; uint64_t sg0 = lookup(1, &s0, &how); lookup(1, &s1, &how);
    CHECK(sg0 && how == HIT && s1 == s0, "the sampler table is kept too");
    atomic_fetch_add(&g_ser_gen, 1);   // a change without a note: the texture table is built whole
    lookup(0, &b0, &how); CHECK(how == PW_WALK, "a storage change without a note: the texture table is built again");
    lookup(1, &s1, &how); CHECK(how == PW_FAST && s1 == s0, "a storage change leaves the sampler table as it was (it follows registrations alone): the texture table's build moved g_psnap_gen, so the first check");
    // another table built or patched (g_psnap_gen): the memo goes, the first check holds
    lookup(0, &b0, &how); CHECK(how == HIT, "kept after its build");
    g_psnap_gen++;
    lookup(0, &b1, &how); CHECK(how == PW_FAST && b1 == b0, "g_psnap_gen moved: the first check again, the same table");
    lookup(0, &b1, &how); CHECK(how == HIT, "and then the memo");
    // textures left out (the walk goes on next frame): kept for this frame only
    pool_snap *p = snap2d(); CHECK(p != NULL, "the texture table found");
    if (p) { p->left = 1; p->left_req = 1; p->frame = atomic_load(&g_cur_frame); g_psnap_gen++;
        lookup(0, &b1, &how); CHECK(how == PW_FAST, "textures left out, this frame: the first check");
        lookup(0, &b1, &how); CHECK(how == HIT, "and the memo within the frame");
        atomic_fetch_add(&g_cur_frame, 1);
        lookup(0, &b1, &how); CHECK(how != PW_MEMO, "a new frame with textures left out: no memo (the walk goes on)");
        p = snap2d(); if (p) { p->left = p->left_req = 0; } }
    rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "memo submission completed");
    // a new submission: through pool_walk again (its read-mark scan and transient IDs)
    mtl_sub_begin();
    lookup(0, &b0, &how); CHECK(how != PW_MEMO, "a new submission: no memo");
    lookup(0, &b1, &how); CHECK(how == HIT && b1 == b0, "and then the memo");
    // the bench: a lookup of a current table, memo on and off
    enum { N = 200000, ROUNDS = 5 }; double best[2] = {1e9, 1e9}; const int was = g_pool_memo;
    for (int r = 0; r < ROUNDS; r++) for (int m = 0; m < 2; m++) {
        g_pool_memo = m; lookup(0, &b0, &how); lookup(0, &b0, &how);
        uint64_t t0 = bp_now(); rmu_lock();
        for (int i = 0; i < N; i++) { __unsafe_unretained id<MTLBuffer> x = nil; pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, 0, &x); }
        os_unfair_lock_unlock(&g_rmu);
        double ns = (double)(bp_now() - t0) / N; if (ns < best[m]) best[m] = ns;
    }
    g_pool_memo = was;
    printf("t_args_levers bench, pool table lookup (%d calls, best of %d): first check %.1f ns, memo %.1f ns\n", N, ROUNDS, best[0], best[1]);
    rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "bench submission completed");
}

// ---------- the pool tables' patch path ----------
// What a patch costs per ID it takes again (Ocarina of Time on the iPhone: about 5 patches a frame at 40-180 us each, the 'pool and handle tables' share of its full encodes): NT IDs,
// three in four 2D textures and one in four 2D arrays, a 2D table and a 2D-array table built; each round registers K IDs again with other textures of their type, and both tables are
// looked up (each patches the K IDs). Prints the time a table patch takes and its split (g_ppw), with DM_NVN_POOL_ENTRY at its setting and 0
static id<MTLTexture> bench_tex(tex_t *t, int array, uint32_t off) {
    *t = (tex_t){.magic=MAGIC('T','E','X',0), .serial=next_serial++};
    t->d = (nvn_texdesc){.target=array ? NVN_TEXTURE_TARGET_2D_ARRAY : NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RGBA8, .width=2, .height=1, .depth=array ? 2 : 1, .levels=1, .samples=1};
    MTLTextureDescriptor *d = tex_desc(t, 0); d.storageMode = MTLStorageModeShared;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d];
    if (out) { res_add(out); mtl_tex_init(t); serial_put(t->serial, out); t->mem = mem + off; t->L.size = 8; }
    return out;
}
static void pool_patch_bench(void) {
    enum { NT = 4000, K = 300, ROUNDS = 40, NB = 8 };
    static tex_t bt[2][NB]; static __strong id<MTLTexture> bm[2][NB];
    for (int a = 0; a < 2; a++) for (int i = 0; i < NB; i++) { bm[a][i] = bench_tex(&bt[a][i], a, 0x8000 + 0x100 * (uint32_t)(a * NB + i)); CHECK(bm[a][i] != nil, "bench texture made"); }
    const int base = 0x10000;   // past the IDs the cases use
    static int cur[NT + 1];   // the texture registered at each ID (of its type's NB)
    for (int i = 1; i <= NT; i++) { cur[i] = i % NB; mtl_reg_tex(base + i, &bt[(i & 3) == 0][cur[i]], NULL); }
    mtl_sub_begin();
    __unsafe_unretained id<MTLBuffer> x = nil;
    rmu_lock(); pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, base, &x); pool_gpu(0, MTLTextureType2DArray, NVN_DPF_FLOAT, base, &x); os_unfair_lock_unlock(&g_rmu);
    const int was = g_pool_entry, ast_was = g_ast_on; double best[2] = {1e18, 1e18}; uint64_t split[2][PP_N] = {{0}};
    uint32_t rnd = 12345;
    for (int pass = 0; pass < 3; pass++) for (int m = 0; m < 2; m++) {   // the last pass with the split's clock reads (g_ast_on), its time not taken
        g_pool_entry = m ? was : 0; g_ast_on = pass == 2; double tot = 0; uint64_t pp0[PP_N]; memcpy(pp0, g_ppw, sizeof pp0);
        for (int r = 0; r < ROUNDS; r++) {
            for (int j = 0; j < K; j++) { rnd = rnd * 1103515245u + 12345u; int i = 1 + (int)(rnd >> 8) % NT; cur[i] = (i + r + 1) % NB; mtl_reg_tex(base + i, &bt[(i & 3) == 0][cur[i]], NULL); }
            uint64_t t0 = bp_now(); rmu_lock();
            pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, base, &x); pool_gpu(0, MTLTextureType2DArray, NVN_DPF_FLOAT, base, &x);
            os_unfair_lock_unlock(&g_rmu); tot += (double)(bp_now() - t0);
        }
        double ns = tot / (2.0 * ROUNDS); if (pass < 2 && ns < best[m]) best[m] = ns;
        if (pass == 2) for (int i = 0; i < PP_N; i++) split[m][i] = g_ppw[i] - pp0[i];
        for (int a = 0; a < 2; a++) {   // every entry of both tables: the texture registered at its ID when of the table's type, else the dummy
            rmu_lock(); pool_gpu(0, a ? MTLTextureType2DArray : MTLTextureType2D, NVN_DPF_FLOAT, base, &x); os_unfair_lock_unlock(&g_rmu);
            const uint64_t *e = (const uint64_t *)((const uint8_t *)x.contents + DMSH_POOL_HEAD); uint32_t n = *(const uint32_t *)x.contents; int bad = 0;
            for (int i = 1; i <= NT && i < (int)n; i++) { uint64_t want = ((i & 3) == 0) == a ? bm[a][cur[i]].gpuResourceID._impl : e[n]; if (e[i] != want) bad++; }
            char l[160]; snprintf(l, sizeof l, "pool table patch bench (DM_NVN_POOL_ENTRY=%d): every entry of the %s table is the ID's texture or the dummy", g_pool_entry, a ? "2D-array" : "2D"); CHECK(!bad, l);
        }
    }
    g_pool_entry = was; g_ast_on = ast_was;
    static mach_timebase_info_data_t tb; if (!tb.denom) mach_timebase_info(&tb);
    printf("t_args_levers bench, pool table patch (%d IDs, %d registered again a round, two tables; best of 2): DM_NVN_POOL_ENTRY=0 %.1f us a patch (%.0f ns an ID), on %.1f us (%.0f ns an ID)\n",
           NT, K, best[0] / 1e3, best[0] / K, best[1] / 1e3, best[1] / K);
    for (int m = 0; m < 2; m++) { const uint64_t *d = split[m]; double n = d[PP_PATHS] ? (double)d[PP_PATHS] : 1, kk = (double)tb.numer / tb.denom / 1e3;
        printf("  %s: %.0f patch paths, %.0f IDs each; per patch: collecting %.1f us, resolving %.1f us, texture lookups past the view %.1f us, table copies %.1f us\n", m ? "on" : "off",
               (double)d[PP_PATHS], d[PP_IDS] / n, d[PP_COLLECT] * kk / n, d[PP_RESOLVE] * kk / n, d[PP_TEXSLOW] * kk / n, d[PP_TAKE] * kk / n); }
    rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "patch bench submission completed");
}

// ---------- DM_NVN_ARGS_DRV ----------
static tex_t g_out; static id<MTLTexture> g_out_tex;
static void pass_begin(void) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &g_out; R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0, 0, 0, 0);
    CHECK(rp_begin() != nil, "render pass opens"); R.clear_c[0] = 0;
}
static void pass_end(const char *label) { rp_end(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), label); }
static void bind_tex(int st, int slot, uint64_t h) { p_bind_handles b = {.stage=st, .first=slot, .n=1}; b.h[0] = h; state_op(OP_BIND_TEX, &b); }
static void bind_samp(int st, int slot, int sid) { p_bind_handles b = {.stage=st, .first=slot, .n=1}; b.h[0] = (uint64_t)sid << 20; state_op(OP_BIND_SAMP, &b); }
static void bind_img(int st, int slot, uint64_t h) { p_bind_handles b = {.stage=st, .first=slot, .n=1}; b.h[0] = h; state_op(OP_BIND_IMG, &b); }
static void bind_ssbo(int st, int slot, const void *p, uint32_t size) { p_bind_buf b = {.stage=st, .index=slot, .addr=(uint64_t)(uintptr_t)p, .size=size}; state_op(OP_BIND_SSBO, &b); }
static void push(uint32_t v) { _Alignas(8) uint8_t buf[sizeof(p_push_const) + 4]; p_push_const *b = (p_push_const *)buf; b->compute = 0; b->offset = 0; b->size = 4; memcpy(b->data, &v, 4); state_op(OP_PUSH_CONST, b); }
// The bank drv_bank gives against one made whole from the same state, and how it was had (DB_*)
static int bank_check(NvShader *sh, int st, int bank, int want, const char *label) {
    uint64_t n0[DB_N]; memcpy(n0, g_stat_drv[bank != 0], sizeof n0);
    __unsafe_unretained id<MTLBuffer> b = nil; uint64_t gpu = drv_bank(sh, st, bank, &b);
    g_args_wrote[st] = g_args_seq;   // as the encode that asked would (a later change is an entry of its own in the history)
    int how = -1; for (int i = 0; i < DB_N; i++) if (g_stat_drv[bank != 0][i] != n0[i]) how = i;
    const uint8_t *got = (const uint8_t *)b.contents + (gpu - b.gpuAddress);
    static uint8_t whole[DMSH_DRV_SIZE]; memset(whole, 0, sizeof whole);
    if (bank) drv_fill_c2(whole, st, sh->rf.dyn, sh->rf.pool ? S.tex_base : 0, sh->rf.pool ? S.samp_base : 0); else drv_fill_c0(whole, st);
    int same = !memcmp(got, whole, sizeof whole);
    if (!same) for (int i = 0; i < DMSH_DRV_SIZE; i += 4) if (memcmp(got + i, whole + i, 4)) { fprintf(stderr, "%s: c%d byte %#x: %08x, made whole %08x\n", label, bank, i, *(const uint32_t *)(got + i), *(const uint32_t *)(whole + i)); break; }
    char l[200]; static const char *const hn[DB_N] = {"reused", "copied and patched", "made whole"};
    snprintf(l, sizeof l, "%s: c%d %s, the bytes of one made whole", label, bank, hn[want]);
    CHECK(same && how == want, l);
    if (how != want) fprintf(stderr, "  (%s)\n", how >= 0 ? hn[how] : "none");
    return how;
}
static void drv_cases(void) {
    if (g_args_drv <= 0) return;
    NvShader *sh = [NvShader new]; sh->stage = 1; sh->rf.drv_read[0] = sh->rf.drv_read[2] = 1;
    NvShader *dy = [NvShader new]; dy->stage = 1; dy->rf.drv_read[2] = 1; dy->rf.dyn = 1;
    float *s1 = (float *)(mem + 0x7000), *s2 = (float *)(mem + 0x7100);
    pass_begin();
    bind_tex(1, 0, TA | (uint64_t)S_CLAMP << 20); bind_tex(1, 33, TB); bind_tex(1, NVN_SEPTEX_SLOT0 + 5, TA); bind_samp(1, 3, S_REPEAT); bind_ssbo(1, 2, s1, 64); g_draw_binst = 4;
    bank_check(sh, 1, 2, DB_FULL, "the first c2 of a submission");
    bank_check(sh, 1, 0, DB_FULL, "the first c0");
    bank_check(sh, 1, 2, DB_HIT, "nothing changed");
    bank_check(sh, 1, 0, DB_HIT, "nothing changed");
    bind_ssbo(1, 2, s2, 32);
    bank_check(sh, 1, 2, DB_HIT, "a storage buffer moved: c2");
    bank_check(sh, 1, 0, DB_DERIVED, "a storage buffer moved: c0");
    g_draw_binst = 9;
    bank_check(sh, 1, 2, DB_HIT, "a base instance: c2");
    bank_check(sh, 1, 0, DB_DERIVED, "a base instance: c0");
    g_pass.samples = 4;
    bank_check(sh, 1, 0, DB_DERIVED, "a sample count: c0");
    g_pass.samples = 1;
    bank_check(sh, 1, 0, DB_DERIVED, "the sample count back: c0");
    bind_tex(1, 0, TB);   // slot 0: its bit also names slots 64, 128 (separate 0) and 192 (separate 64)
    bank_check(sh, 1, 0, DB_HIT, "a texture moved: c0");
    bank_check(sh, 1, 2, DB_DERIVED, "a texture moved: c2");
    bind_tex(1, NVN_SEPTEX_SLOT0 + 69, TB); bind_tex(1, 33, 0); bind_tex(1, 40, TA); bind_samp(1, 67, S_CLAMP); bind_samp(1, 3, 0);
    bank_check(sh, 1, 2, DB_DERIVED, "a separate texture, a combined slot past 31 cleared and slot 40, two samplers");
    bind_img(1, 1, TA);   // an image: a hard change the history does not hold
    bank_check(sh, 1, 2, DB_FULL, "an image binding");
    bank_check(sh, 1, 0, DB_FULL, "an image binding: c0");
    bind_tex(1, 33, TA);   // slot 33 shares its word with image slot 1, which is bound
    bank_check(sh, 1, 2, DB_DERIVED, "a combined slot past 31 under a bound image");
    bank_check(dy, 1, 2, DB_FULL, "a shader with dynamic handle arrays: a bank of its own kind");
    bind_tex(1, 2, TB);
    bank_check(dy, 1, 2, DB_DERIVED, "and patched for it");
    bank_check(sh, 1, 2, DB_FULL, "the other kind again: made whole");
    for (int i = 0; i < PK_RING + 4; i++) bind_tex(1, i, i & 1 ? TA : TB);   // a full history: its oldest entries joined
    bank_check(sh, 1, 2, DB_DERIVED, "more texture changes than the history holds");
    push(3);
    bank_check(sh, 1, 0, DB_FULL, "push constants (a hard change): c0");
    bank_check(sh, 1, 2, DB_FULL, "push constants: c2");
    bank_check(sh, 0, 2, DB_FULL, "another stage: a bank of its own");
    pass_end("driver bank submission completed");
    pass_begin();
    bind_tex(1, 0, TA); bind_ssbo(1, 2, s1, 64); g_draw_binst = 4;
    bank_check(sh, 1, 2, DB_FULL, "a new submission: c2");
    bank_check(sh, 1, 0, DB_FULL, "a new submission: c0");
    pass_end("driver bank submission completed");
}
// Encode cost of a shader with 16 textures, 8 samplers, 4 uniform slots, 2 storage buffers, c0 and c2: a texture, storage or base instance change, as partial patches and (with
// the patches off) as full encodes, banks shared (DM_NVN_ARGS_DRV) and not
static void drv_bench(id<MTLLibrary> lib) {
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = t4_fn(lib, @"big"); strcpy(s->key, "7900000000000000");
    s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    int n = 0;
    for (int i = 0; i < 16; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=i, .aid=n, .dtt=MTLTextureType2D};
    for (int i = 0; i < 8; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=i, .aid=n};
    for (int i = 0; i < 4; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=i, .aid=n};
    for (int i = 0; i < 2; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SBUFP, .reg=i, .aid=n};
    s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_DRV0, .aid=n}; n++; s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_DRV2, .aid=n}; n++; s->rf.drv_read[0] = s->rf.drv_read[2] = 1;
    s->rf.nb = n;
    float *u = (float *)(mem + 0x100), *sa = (float *)(mem + 0x7000), *sb = (float *)(mem + 0x7100);
    pass_begin();
    for (int i = 0; i < 16; i++) S.tex[1][i] = i & 1 ? TB : TA;
    for (int i = 0; i < 8; i++) S.samp[1][i] = (uint64_t)(i & 1 ? S_REPEAT : S_CLAMP) << 20;
    for (int i = 0; i < 4; i++) S.ubo[1][i] = (p_bind_buf){.addr=(uint64_t)(uintptr_t)u, .size=16};
    for (int i = 0; i < 2; i++) S.ssbo[1][i] = (p_bind_buf){.addr=(uint64_t)(uintptr_t)sa, .size=16};
    args_dirty_all();
    enum { N = 20000, ROUNDS = 5, MODES = 6 }; double best[2][MODES]; for (int d = 0; d < 2; d++) for (int m = 0; m < MODES; m++) best[d][m] = 1e9;
    static const char *const name[MODES] = {"patch texture", "patch storage", "patch base instance", "full encode, texture", "full encode, storage", "full encode after a hard change"};
    const int drv0 = g_args_drv, part0 = g_args_partial;
    for (int r = 0; r < ROUNDS; r++) for (int d = 0; d < 2; d++) for (int mode = 0; mode < MODES; mode++) {
        g_args_drv = d; g_args_partial = mode < 3; s->ab_pkind = 0;
        encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
        uint64_t t0 = bp_now();
        for (int i = 0; i < N; i++) {
            switch (mode) {
                case 0: case 3: { p_bind_handles b = {.stage=1, .first=3, .n=1}; b.h[0] = (uint64_t)(i & 1 ? TB : TA); state_op(OP_BIND_TEX, &b); break; }
                case 1: case 4: { p_bind_buf b = {.stage=1, .index=1, .addr=(uint64_t)(uintptr_t)(i & 1 ? sa : sb), .size=16}; state_op(OP_BIND_SSBO, &b); break; }
                case 2: g_draw_binst = (uint32_t)i; break;
                case 5: args_dirty_all(); break;
            }
            encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
        }
        double ns = (double)(bp_now() - t0) / N; if (ns < best[d][mode]) best[d][mode] = ns;
    }
    g_args_drv = drv0; g_args_partial = part0; s->ab_pkind = 0;
    printf("t_args_levers bench, driver banks (%d bindings with c0 and c2, %d calls, best of %d): ", n, N, ROUNDS);
    for (int m = 0; m < MODES; m++) printf("%s %.0f -> %.0f ns%s", name[m], best[0][m], best[1][m], m < MODES - 1 ? ", " : "\n");
    pass_end("bench submission completed");
}

// ---------- DM_NVN_ARGS_REGCHK ----------
// Every draw writes one pixel of a 64x1 target, read back at the end: fp samples texture slot 0 (texel 1 with clamp, texel 0 with repeat: R) and slot 1 (texel 0: G) through sampler
// slot 0; fq samples the pool tables at the texture and sampler IDs its uniform slot holds (texel 1); fd has a dynamic handle array (TEXD), whose kind the check does not take
enum { TX = 20, TY = 21, SX = 5 };
static int g_px; static uint8_t g_want[W][4]; static id<MTLRenderPipelineState> g_ps_p, g_ps_q, g_ps_d;
static struct { int t0, t1, rep; const uint8_t (*t0x)[4], (*t1x)[4]; } st;   // what fp reads: the textures' texels as registered now
static void want_p(uint8_t w[4]) { w[0] = st.t0x[st.rep ? 0 : 1][0]; w[1] = st.t1x[0][1]; w[2] = 0; w[3] = 255; }
static void xdraw(NvShader *sh, id<MTLRenderPipelineState> p, const uint8_t want[4]) {
    CHECK(g_px < W, "room for the draw"); if (g_px >= W) return;
    if (g_ast_on) ast_draw();
    enc_r_pso(g_enc, p); enc_r_viewport(g_enc, (MTLViewport){g_px, 0, 1, 1, 0, 1});
    CHECK(encode_args((id<MTL4CommandEncoder>)g_enc, sh, 1, 0), "fragment arguments encoded");
    enc_r_draw(g_enc, MTLPrimitiveTypeTriangle, 0, 3);
    for (int i = 0; i < g_nsd; i++) if (g_sd[i].idx == 0) { g_sd[i].wrote = g_sd[i].rast = 1; }
    memcpy(g_want[g_px++], want, 4);
}
typedef struct { uint64_t e, r, p, q; } cnt;
static cnt take(void) { return (cnt){g_stat_args_enc, g_stat_args_reuse, g_stat_args_patch, g_stat_args_partial}; }
enum { FULL, REUSE, PATCH, REUSE_ALWAYS };
static void step(NvShader *sh, id<MTLRenderPipelineState> p, const uint8_t want[4], int with, const char *label) {   // with: the outcome with the switch on; off, a full encode after a registration
    const int on = g_args_regchk > 0, w = on || with == REUSE_ALWAYS ? (with == REUSE_ALWAYS ? REUSE : with) : FULL; cnt a = take(); xdraw(sh, p, want); cnt b = take();
    char l[240]; snprintf(l, sizeof l, "%s: %s", label, w == FULL ? "a full encode" : w == REUSE ? "reused" : "a partial patch");
    CHECK(w == FULL ? b.e - a.e == 1 && b.r == a.r && b.q == a.q : w == REUSE ? b.r - a.r == 1 && b.e == a.e : b.q - a.q == 1 && b.e == a.e, l);
}
static void finish(id<MTLBuffer> rb, const char *label) {
    rp_end(); enc_b_copy_texture_buffer(blit(), g_out_tex, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(W, 1, 1), rb, 0, 4 * W, 4 * W);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "GPU submission completed");
    int bad = -1;
    for (int x = 0; x < g_px && bad < 0; x++) { const uint8_t *q = (const uint8_t *)rb.contents + 4 * x, *w = g_want[x];
        for (int k = 0; k < 4; k++) if (abs((int)q[k] - (int)w[k]) > 1) { bad = x; break; } }
    if (bad >= 0) for (int x = bad; x < g_px; x++) { const uint8_t *q = (const uint8_t *)rb.contents + 4 * x, *w = g_want[x]; int d = 0; for (int k = 0; k < 4; k++) d |= abs((int)q[k] - (int)w[k]) > 1;
        if (d) fprintf(stderr, "pixel %d: %u,%u,%u,%u, want %u,%u,%u,%u\n", x, q[0], q[1], q[2], q[3], w[0], w[1], w[2], w[3]); }
    CHECK(bad < 0, label);
}
static samp_par g_sp_clamp, g_sp_repeat;
static void rck_cases(NvShader *fp, NvShader *fq, NvShader *fd, id<MTLBuffer> rb) {
    const int P = g_args_partial > 0;
    uint32_t *qu = (uint32_t *)(mem + 0x400);   // fq's uniform slot: texture ID, sampler ID
    make_tex(2, 0x3000); make_tex(4, 0x5000);
    reg_tex_at(TA, 0, 0x1000); reg_tex_at(TB, 1, 0x2000); mtl_reg_samp(S_CLAMP, &g_sp_clamp); mtl_reg_samp(S_REPEAT, &g_sp_repeat);
    pass_begin(); g_px = 0;
    bind_tex(1, 0, TA); bind_tex(1, 1, TB); bind_samp(1, 0, S_CLAMP); st.t0x = TEXEL[0]; st.t1x = TEXEL[1]; st.rep = 0;
    qu[0] = TA; qu[1] = S_CLAMP; { p_bind_buf b = {.stage=1, .index=0, .addr=(uint64_t)(uintptr_t)qu, .size=16}; state_op(OP_BIND_UBO, &b); }
    uint8_t w[4]; want_p(w); step(fp, g_ps_p, w, FULL, "the first draw");
    want_p(w); step(fp, g_ps_p, w, REUSE_ALWAYS, "the same draw");
    // a texture registered at an ID no slot names: the sync stamps it, the block holds
    uint64_t r0 = g_stat_rck[0]; reg_tex_at(TX, 2, 0x3000);
    want_p(w); step(fp, g_ps_p, w, REUSE, "a texture registered at an ID no slot names");
    CHECK(g_args_regchk <= 0 || g_stat_rck[0] == r0 + 1, "a sync taken by ID");
    // the ID slot 0 names registered with other data: in full, and the new texels drawn
    reg_tex_at(TA, 3, 0x4000); st.t0x = TEXEL[3];
    want_p(w); step(fp, g_ps_p, w, FULL, "the ID texture slot 0 names registered again");
    // samplers: one no slot names, then the one slot 0 names, registered as repeat
    mtl_reg_samp(SX, &g_sp_repeat);
    want_p(w); step(fp, g_ps_p, w, REUSE, "a sampler registered at an ID no slot names");
    mtl_reg_samp(S_CLAMP, &g_sp_repeat); st.rep = 1;
    want_p(w); step(fp, g_ps_p, w, FULL, "the sampler ID slot 0 names registered again");
    // a texture change with a registration elsewhere: still a partial patch
    bind_tex(1, 1, TX); st.t1x = TEXEL[2]; reg_tex_at(TY, 4, 0x5000);
    want_p(w); step(fp, g_ps_p, w, P ? PATCH : FULL, "a texture change and a registration elsewhere");
    // a newly bound ID registered since the block: in full (the check takes the slots as they are now)
    reg_tex_at(TY, 2, 0x3000); bind_tex(1, 1, TY);
    want_p(w); step(fp, g_ps_p, w, FULL, "a texture change to an ID registered since");
    // the pool shader: its tables taken again after a registration (a partial patch), the new texture drawn when its ID was the one registered
    const uint8_t *qw = TEXEL[3][st.rep ? 0 : 1];
    step(fq, g_ps_q, qw, FULL, "the pool shader's first draw");
    reg_tex_at(TX, 4, 0x5000);
    step(fq, g_ps_q, qw, P ? PATCH : FULL, "a registration elsewhere: the pool shader's tables taken again");
    reg_tex_at(TA, 2, 0x3000); qw = TEXEL[2][st.rep ? 0 : 1];
    step(fq, g_ps_q, qw, P ? PATCH : FULL, "the ID the pool shader reads registered again: its tables taken again, the new texture drawn");
    g_psnap_gen++;   // another table built or patched
    step(fq, g_ps_q, qw, P ? PATCH : FULL, "another table built: the pool shader's tables taken again (no registration)");
    st.t0x = TEXEL[2]; want_p(w); step(fp, g_ps_p, w, FULL, "and fp, whose slot 0 names that ID: in full");
    // what the sync cannot take by ID: every block in full
    reg_tex_at(TX, 0, 0x1000); atomic_fetch_add(&g_ser_gen, 1);
    want_p(w); step(fp, g_ps_p, w, g_args_regchk > 0 ? FULL : FULL, "a registration with a replaced object (serial)");
    reg_tex_at(TX, 2, 0x3000); atomic_fetch_add(&g_reg_gen, 1);
    want_p(w); step(fp, g_ps_p, w, FULL, "a registration with a change without a note");
    { uint8_t *mp = mmap(NULL, 0x4000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); reg_tex_at(TX, 4, 0x5000); mtl_pool_add(mp, 0x4000);
      want_p(w); step(fp, g_ps_p, w, FULL, "a registration with a memory pool"); }
    // a shader whose kinds the check does not take
    uint8_t wd[4] = {st.t0x[st.rep ? 0 : 1][0], st.t1x[0][1], 0, 255};
    step(fd, g_ps_d, wd, FULL, "the dynamic-array shader's first draw");
    reg_tex_at(TX, 2, 0x3000);
    step(fd, g_ps_d, wd, FULL, "a registration elsewhere: a shader whose kinds the check does not take, in full");
    if (g_ast_on && g_args_regchk > 0) CHECK(g_ast.fresh[AW_REG_UNCHK] >= 1 && g_ast.fresh[AW_REG_ID] >= 3, "DM_NVN_ARGS_STATS: full encodes counted as reg_id and reg_unchecked");
    finish(rb, "every draw wrote what its bindings named as registered");
    // another submission
    pass_begin(); g_px = 0; bind_tex(1, 0, TA); bind_tex(1, 1, TB); bind_samp(1, 0, S_CLAMP); st.t0x = TEXEL[2]; st.t1x = TEXEL[1];
    want_p(w); step(fp, g_ps_p, w, FULL, "a new submission");
    reg_tex_at(TY, 4, 0x5000);
    want_p(w); step(fp, g_ps_p, w, REUSE, "and a registration elsewhere in it");
    finish(rb, "every draw of the second submission");
}
// Encode cost after a registration of an ID the shader's slots do not name: the block checked and reused, or encoded in full (16 textures, 8 samplers, 4 uniform slots)
static void rck_bench(id<MTLLibrary> lib) {
    NvShader *s = [NvShader new]; s->stage = 1; s->fn = t4_fn(lib, @"big2"); strcpy(s->key, "7a00000000000000");
    s->arg_len = [s->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    int n = 0;
    for (int i = 0; i < 16; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=i, .aid=n, .dtt=MTLTextureType2D};
    for (int i = 0; i < 8; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=i, .aid=n};
    for (int i = 0; i < 4; i++, n++) s->rf.b[n] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=i, .aid=n};
    s->rf.nb = n;
    pass_begin();
    for (int i = 0; i < 16; i++) S.tex[1][i] = i & 1 ? TB : TA;
    for (int i = 0; i < 8; i++) S.samp[1][i] = (uint64_t)(i & 1 ? S_REPEAT : S_CLAMP) << 20;
    for (int i = 0; i < 4; i++) S.ubo[1][i] = (p_bind_buf){.addr=(uint64_t)(uintptr_t)(mem + 0x100), .size=16};
    args_dirty_all();
    enum { N = 20000, ROUNDS = 5 }; double best[2] = {1e9, 1e9}, reg_only = 1e9; const int was = g_args_regchk;
    for (int r = 0; r < ROUNDS; r++) {
        for (int m = 0; m < 2; m++) {
            g_args_regchk = m; mtl_reg_tex(TX, &g_tx[4], NULL); encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0);
            uint64_t e0 = g_stat_args_enc, t0 = bp_now();
            for (int i = 0; i < N; i++) { mtl_reg_tex(TX, &g_tx[2 + (i & 1) * 2], NULL); encode_args((id<MTL4CommandEncoder>)g_enc, s, 1, 0); }
            double ns = (double)(bp_now() - t0) / N; if (ns < best[m]) best[m] = ns;
            if (!r) CHECK(m ? g_stat_args_enc == e0 : g_stat_args_enc - e0 == N, m ? "bench: every block checked and reused" : "bench, switch off: every block in full");
        }
        uint64_t t0 = bp_now(); for (int i = 0; i < N; i++) mtl_reg_tex(TX, &g_tx[2 + (i & 1) * 2], NULL);
        double ns = (double)(bp_now() - t0) / N; if (ns < reg_only) reg_only = ns;
    }
    g_args_regchk = was;
    printf("t_args_levers bench, a registration elsewhere then an encode (%d bindings, %d calls, best of %d): in full %.0f ns, checked and reused %.0f ns (the registration alone %.0f ns)\n", n, N, ROUNDS, best[0], best[1], reg_only);
    pass_end("bench submission completed");
}

int main(void) { @autoreleasepool {
    alarm(120);
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1); setenv("DM_PSO_RECORD", "/dev/null", 1);
    const char *e = getenv("DM_NVN_POOL_MEMO"); int memo_off = e && !strcmp(e, "0");
    e = getenv("DM_NVN_ARGS_DRV"); int drv_off = e && !strcmp(e, "0");
    e = getenv("DM_NVN_ARGS_REGCHK"); int rck_off = e && !strcmp(e, "0");
    e = getenv("DM_NVN_POOL_ENTRY"); int pe_off = e && !strcmp(e, "0");
    mtl_init();
    CHECK(g_pool_entry == !pe_off, pe_off ? "DM_NVN_POOL_ENTRY=0 turns the pool entry order off" : "the pool entry order is on by default");
    CHECK(g_pool_memo == !memo_off, memo_off ? "DM_NVN_POOL_MEMO=0 turns the memo off" : "the pool table memo is on by default");
    CHECK(g_args_regchk == !rck_off, rck_off ? "DM_NVN_ARGS_REGCHK=0 turns the registration check off" : "the registration check is on by default");
    CHECK(g_args_drv == !drv_off, drv_off ? "DM_NVN_ARGS_DRV=0 turns the shared driver banks off" : "the shared driver banks are on by default");
    mem = mmap(NULL, 0x10000, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) return 2;
    mtl_pool_add(mem, 0x10000);
    reg_tex_at(TA, 0, 0x1000); reg_tex_at(TB, 1, 0x2000);
    samp_par sp = {.minf=NVN_MIN_FILTER_NEAREST, .magf=NVN_MAG_FILTER_NEAREST, .ws=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wt=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wr=NVN_WRAP_MODE_CLAMP_TO_EDGE, .lod_max=1000};
    mtl_reg_samp(S_CLAMP, &sp); sp.ws = NVN_WRAP_MODE_REPEAT; mtl_reg_samp(S_REPEAT, &sp);
    memo_cases();
    pool_patch_bench();
    g_out_tex = texture(&g_out, W); if (!g_out_tex) return 2;
    NSError *error = nil; NSMutableString *src = [NSMutableString stringWithString:@"#include <metal_stdlib>\nusing namespace metal;\nstruct B {"];
    for (int i = 0; i < 16; i++) [src appendFormat:@" texture2d<float> t%d [[id(%d)]];", i, i];
    for (int i = 0; i < 8; i++) [src appendFormat:@" sampler s%d [[id(%d)]];", i, 16 + i];
    for (int i = 0; i < 4; i++) [src appendFormat:@" constant float4 *c%d [[id(%d)]];", i, 24 + i];
    for (int i = 0; i < 2; i++) [src appendFormat:@" device float4 *b%d [[id(%d)]];", i, 28 + i];
    [src appendString:@" constant uint *d0 [[id(30)]]; constant uint *d2 [[id(31)]]; };\nfragment float4 big(constant B &a [[buffer(0)]]) { return a.t0.sample(a.s0, float2(0.5)) + a.t15.sample(a.s7, float2(0.5)) + a.c0[0] + a.c3[0] + a.b0[0] + a.b1[0] + float(a.d0[0] + a.d2[0]); }\n"];
    id<MTLLibrary> lib = t4_lib(src, nil, &error);
    CHECK(lib != nil, "synthetic shaders compile"); if (!lib) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    drv_cases();
    drv_bench(lib);
    g_sp_clamp = (samp_par){.minf=NVN_MIN_FILTER_NEAREST, .magf=NVN_MAG_FILTER_NEAREST, .ws=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wt=NVN_WRAP_MODE_CLAMP_TO_EDGE, .wr=NVN_WRAP_MODE_CLAMP_TO_EDGE, .lod_max=1000};
    g_sp_repeat = g_sp_clamp; g_sp_repeat.ws = NVN_WRAP_MODE_REPEAT;
    id<MTLLibrary> lr = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i[[vertex_id]]) { return float4(i == 1 ? 3.0 : -1.0, i == 2 ? 3.0 : -1.0, 0, 1); }\n"
        "struct A { texture2d<float> t0 [[id(0)]]; texture2d<float> t1 [[id(1)]]; sampler s [[id(2)]]; };\n"
        "fragment float4 fp(constant A &a [[buffer(0)]]) { return float4(a.t0.sample(a.s, float2(1.25, 0.5), level(0)).r, a.t1.sample(a.s, float2(0.25, 0.5), level(0)).g, 0, 1); }\n"
        "struct PT { uint n; ulong seen; array<texture2d<float>, 1> e; }; struct PS { uint n; ulong seen; array<sampler, 1> e; };\n"
        "struct Q { constant PT *tp [[id(0)]]; constant PS *sp [[id(1)]]; constant uint4 *c [[id(2)]]; };\n"
        "fragment float4 fq(constant Q &a [[buffer(0)]]) { uint t = a.c[0].x, s = a.c[0].y; return (&a.tp->e[0])[min(t, a.tp->n)].sample((&a.sp->e[0])[min(s, a.sp->n)], float2(1.25, 0.5), level(0)); }\n"
        "struct D { array<texture2d<float>, 2> td [[id(0)]]; sampler s [[id(2)]]; };\n"
        "fragment float4 fd(constant D &a [[buffer(0)]]) { return float4(a.td[0].sample(a.s, float2(1.25, 0.5), level(0)).r, a.td[1].sample(a.s, float2(0.25, 0.5), level(0)).g, 0, 1); }\n"
        "struct B2 { array<texture2d<float>, 16> t [[id(0)]]; array<sampler, 8> s [[id(16)]]; array<constant float4 *, 4> c [[id(24)]]; };\n"
        "fragment float4 big2(constant B2 &a [[buffer(0)]]) { return a.t[0].sample(a.s[0], float2(0.5)) + a.t[15].sample(a.s[7], float2(0.5)) + a.c[0][0] + a.c[3][0]; }\n", nil, &error);
    CHECK(lr != nil, "synthetic shaders compile"); if (!lr) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    MTLRenderPipelineDescriptor *pdsc = [MTLRenderPipelineDescriptor new]; pdsc.vertexFunction = t4_fn(lr, @"v"); pdsc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    pdsc.fragmentFunction = t4_fn(lr, @"fp"); g_ps_p = t4_rps(pdsc, &error); pdsc.fragmentFunction = t4_fn(lr, @"fq"); g_ps_q = t4_rps(pdsc, &error); pdsc.fragmentFunction = t4_fn(lr, @"fd"); g_ps_d = t4_rps(pdsc, &error);
    CHECK(g_ps_p && g_ps_q && g_ps_d, "render pipelines compile"); if (!g_ps_p || !g_ps_q || !g_ps_d) return 2;
    NvShader *fp = [NvShader new]; fp->stage = 1; fp->fn = t4_fn(lr, @"fp"); strcpy(fp->key, "7b00000000000001"); fp->arg_len = [fp->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    fp->rf.nb = 3; fp->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=0, .aid=0, .dtt=MTLTextureType2D}; fp->rf.b[1] = (nvn_rbind){.kind=NVN_RB_TEX, .reg=1, .aid=1, .dtt=MTLTextureType2D}; fp->rf.b[2] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=0, .aid=2};
    NvShader *fq = [NvShader new]; fq->stage = 1; fq->fn = t4_fn(lr, @"fq"); strcpy(fq->key, "7b00000000000002"); fq->arg_len = [fq->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    fq->rf.nb = 3; fq->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEXP, .aid=0, .dtt=MTLTextureType2D, .dpf=NVN_DPF_FLOAT}; fq->rf.b[1] = (nvn_rbind){.kind=NVN_RB_SAMPP, .aid=1}; fq->rf.b[2] = (nvn_rbind){.kind=NVN_RB_CBUF, .reg=0, .aid=2}; fq->rf.pool = fq->rf.bindless = 1;
    NvShader *fd = [NvShader new]; fd->stage = 1; fd->fn = t4_fn(lr, @"fd"); strcpy(fd->key, "7b00000000000003"); fd->arg_len = [fd->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    fd->rf.nb = 2; fd->rf.b[0] = (nvn_rbind){.kind=NVN_RB_TEXD, .aid=0, .n=2, .dtt=MTLTextureType2D}; fd->rf.b[1] = (nvn_rbind){.kind=NVN_RB_SAMP, .reg=0, .aid=2}; fd->rf.dyn = 1;
    id<MTLBuffer> rb = [g_dev newBufferWithLength:4 * W options:MTLResourceStorageModeShared]; res_add(rb);
    rck_cases(fp, fq, fd, rb);
    rck_bench(lr);
    printf("t_args_levers%s%s%s%s: %d checks, %d failed\n", memo_off ? " (DM_NVN_POOL_MEMO=0)" : "", pe_off ? " (DM_NVN_POOL_ENTRY=0)" : "", drv_off ? " (DM_NVN_ARGS_DRV=0)" : "", rck_off ? " (DM_NVN_ARGS_REGCHK=0)" : "", checks, failed);
    return failed != 0;
} }
