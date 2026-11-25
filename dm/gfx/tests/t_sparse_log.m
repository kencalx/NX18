// A whole (not placement) sparse texture's content check through its pool's change log (nvn_mtl.m pkg_sparse_clean, hle_nvn.c nvn_sparse_since_runs / nvn_sparse_log_hit,
// nvn_dirty.c nvn_dirty_since_last; ported from S2Arm de791716), through the real NVN entry points. Expectations are written from the mapping and dirty-page rules, not read back
// from the code: a check after unrelated writes and mappings answers from the kept runs without a walk and keeps the texture; a mapping request over the texture is seen through the log
// (a walk, a re-upload, the new pages' content), and the next unrelated change is answered from the log again (runs taken anew); a CPU write inside a mapped run is found without a walk
// (re-upload, the written content); more requests than the log holds walk once, and the texture stays; a pool finalized and made again over the same object never answers with the old
// pool's log position (its id), and a finalized pool object made unreadable is never read by a later check (NXNative 6d0ee04ac's rule). DM_NVN_SPARSE_LOG=0 walks at every check, as
// before, with the same content at every step.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static void finish(void) { CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); CHECK("GPU has no submission error", !mtl_last_commit_error()); }
static id<MTLTexture> resolve(const NVNtexture *x) { mtl_sub_begin(); id<MTLTexture> m = tex_mtl((const tex_t *)x); finish(); return m; }
static pool_t g_phys, g_sparse;
static uint8_t *g_pm;
static void map_at(pool_t *sp, uint64_t voff, uint64_t size, uint64_t poff, int mapped) {
    map_req r = {.phys = mapped ? (NVNmemoryPool *)&g_phys : NULL, .poff = (int64_t)poff, .voff = (int64_t)voff, .size = size};
    CHECK("mapping request", h_nvnMemoryPoolMapVirtual((NVNmemoryPool *)sp, 1, (const NVNmappingRequest *)&r));
}
static void cpu_write(uint64_t poff, const void *src, size_t n) { dm_guest_write_prepare(g_pm + poff, n); memcpy(g_pm + poff, src, n); }
// The whole level read back equals the deswizzled expected storage
static int holds(id<MTLTexture> m, const tex_t *T, const uint8_t *storage, unsigned w) {
    uint32_t *want = malloc((size_t)w * w * 4); if (!want || nvn_deswizzle(&T->d, 0, 0, storage, want, (size_t)w * 4)) { free(want); return 0; }
    id<MTLBuffer> rb = [g_dev newBufferWithLength:(size_t)w * w * 4 options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> ce = t4_copy(cb);
    t4_use(cb, m), t4_use(cb, rb), [ce copyFromTexture:m sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(w, w, 1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:w * 4 destinationBytesPerImage:(NSUInteger)w * w * 4];
    t4_end(cb, ce); t4_wait(cb);
    int ok = !memcmp(rb.contents, want, (size_t)w * w * 4); free(want); return ok;
}
int main(void) { @autoreleasepool {
    mtl_init();
    const int on = sparse_log_on();
    enum { W = 256, PG = 0x1000 };
    size_t plen = 4u << 20; const uint64_t A = 0, B = 1u << 20, SCR = 3u << 20;   // physical: content A, content B, scratch for unrelated writes and mappings
    g_pm = mmap(NULL, plen, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (g_pm == MAP_FAILED) abort();
    pool_builder_t pb = {.mem = g_pm, .size = plen, .flags = 0x24};
    CHECK("physical pool", h_nvnMemoryPoolInitialize((NVNmemoryPool *)&g_phys, (const NVNmemoryPoolBuilder *)&pb));
    pb = (pool_builder_t){.size = DM_GAME_APP_POOL + (1ull << 32), .flags = NVN_MEMORY_POOL_FLAGS_VIRTUAL};
    CHECK("sparse pool", h_nvnMemoryPoolInitialize((NVNmemoryPool *)&g_sparse, (const NVNmemoryPoolBuilder *)&pb));
    NVNtextureBuilder tb; NVNtexture tx; h_nvnTextureBuilderSetDefaults(&tb); h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D); h_nvnTextureBuilderSetWidth(&tb, W); h_nvnTextureBuilderSetHeight(&tb, W);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8); h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_SPARSE); h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&g_sparse, 0);
    CHECK("sparse texture", h_nvnTextureInitialize(&tx, &tb));
    const tex_t *T = (const tex_t *)&tx; const uint64_t S = (T->L.size + PG - 1) & ~(uint64_t)(PG - 1);
    CHECK("small enough to stay whole, a few pages", S >= 4 * PG && S <= (512u << 10));
    // Two contents, swizzled, in the physical pool
    uint8_t *sa = calloc(1, S), *sb = calloc(1, S), *exp = calloc(1, S); uint32_t *lin = malloc((size_t)W * W * 4);
    for (size_t i = 0; i < (size_t)W * W; i++) lin[i] = (uint32_t)(i + 1) * 2654435761u;
    CHECK("swizzle A", !nvn_swizzle(&T->d, 0, 0, lin, (size_t)W * 4, sa));
    for (size_t i = 0; i < (size_t)W * W; i++) lin[i] = (uint32_t)(i + 7) * 40503u ^ 0x5A5A5A5Au;
    CHECK("swizzle B", !nvn_swizzle(&T->d, 0, 0, lin, (size_t)W * 4, sb));
    memcpy(g_pm + A, sa, S); memcpy(g_pm + B, sb, S);
    map_at(&g_sparse, 0, S, A, 1); memcpy(exp, sa, S);
    id<MTLTexture> m = resolve(&tx);
    CHECK("uploaded whole (not placement)", m && !m.isSparse);
    CHECK("holds content A", holds(m, T, exp, W));
    NvPkg *pk = tex_get(T->serial);
    CHECK("a whole sparse package", pk && pk->sparse && !pk->ps);
    uint64_t far = 64ull << 20, junk[1024] = {0}; int nj = 0;
    #define UNRELATED() do { junk[0] = ++nj; cpu_write(SCR, junk, sizeof junk); map_at(&g_sparse, far, PG, SCR + PG * (uint64_t)(nj & 7), 1); } while (0)
    // 1. Unrelated writes and mappings: the first check walks (and keeps the runs), the second answers from the log, and nothing is uploaded again
    UNRELATED(); uint64_t w0 = g_spc_walk, l0 = g_spc_log, r0 = g_pkg_reuploads;
    CHECK("the same texture", resolve(&tx) == m);
    CHECK("first check after the upload: one walk", g_spc_walk == w0 + 1 && g_spc_log == l0);
    UNRELATED(); w0 = g_spc_walk; l0 = g_spc_log;
    (void)resolve(&tx);
    if (on) CHECK("nothing of it changed: no walk, answered from the log", g_spc_walk == w0 && g_spc_log == l0 + 1);
    else CHECK("DM_NVN_SPARSE_LOG=0: a walk, as before", g_spc_walk == w0 + 1 && g_spc_log == l0);
    CHECK("not uploaded again", g_pkg_reuploads == r0 && pk->tex == m);
    w0 = g_spc_walk; l0 = g_spc_log; (void)resolve(&tx);
    CHECK("nothing changed: no check at all", g_spc_walk == w0 && g_spc_log == l0);
    // 2. A mapping change over the texture, seen through the log: a walk and a re-upload of what the new pages hold; the next unrelated change is answered from the log again
    map_at(&g_sparse, PG, 2 * PG, B + PG, 1); memcpy(exp + PG, sb + PG, 2 * PG);
    w0 = g_spc_walk; l0 = g_spc_log; r0 = g_pkg_reuploads;
    id<MTLTexture> m2 = resolve(&tx);
    CHECK("the overlapping request sends the check to the walk", g_spc_walk == w0 + 1 && g_spc_log == l0);
    CHECK("re-uploaded", g_pkg_reuploads == r0 + 1);
    CHECK("holds the newly mapped pages", holds(m2, T, exp, W));
    UNRELATED(); (void)resolve(&tx);   // the first check after the re-upload walks: the walk after an overlapping request found it written
    UNRELATED(); w0 = g_spc_walk; l0 = g_spc_log; r0 = g_pkg_reuploads;
    (void)resolve(&tx);
    if (on) CHECK("after the walk the runs are taken anew: the log answers again", g_spc_walk == w0 && g_spc_log == l0 + 1);
    CHECK("still not uploaded again", g_pkg_reuploads == r0);
    // 3. A CPU write inside a mapped run: found from the kept runs, without a walk
    w0 = g_spc_walk; l0 = g_spc_log; r0 = g_pkg_reuploads;
    cpu_write(B + PG + 0x200, sa + PG + 0x200, 0x400); memcpy(exp + PG + 0x200, sa + PG + 0x200, 0x400);
    id<MTLTexture> m3 = resolve(&tx);
    if (on) CHECK("the write is found from the runs: no walk", g_spc_walk == w0 && g_spc_log == l0 + 1);
    CHECK("re-uploaded for the write", g_pkg_reuploads == r0 + 1);
    CHECK("holds the written bytes", holds(m3, T, exp, W));
    // 4. More mapping requests than the log holds (VLOG_N), none over the texture: one walk, the texture stays
    for (int i = 0; i <= VLOG_N; i++) map_at(&g_sparse, far + 16 * PG, PG, SCR + PG * (uint64_t)(i & 1), 1);
    UNRELATED(); (void)resolve(&tx);   // the re-upload's first check
    for (int i = 0; i <= VLOG_N; i++) map_at(&g_sparse, far + 16 * PG, PG, SCR + PG * (uint64_t)(i & 1), 1);
    junk[0] = ++nj; cpu_write(SCR, junk, sizeof junk);
    w0 = g_spc_walk; l0 = g_spc_log; r0 = g_pkg_reuploads;
    (void)resolve(&tx);
    CHECK("the log went round: the full walk", g_spc_walk == w0 + 1 && g_spc_log == l0);
    CHECK("clean: not uploaded again", g_pkg_reuploads == r0);
    UNRELATED(); w0 = g_spc_walk; l0 = g_spc_log; (void)resolve(&tx);
    if (on) CHECK("and the log answers after it", g_spc_walk == w0 && g_spc_log == l0 + 1);
    CHECK("content through it all", holds(pk->tex, T, exp, W));
    // 5. Descriptor lifetime. (a) A pool finalized and made again over the same object: the old pool's log position never answers for the new one, even with requests since that
    // position none of which overlaps. (b) A finalized pool's object made unreadable: a later check of another texture, after a mapping in another pool, never reads it
    {   const size_t page = (size_t)getpagesize();
        pool_t *dead = mmap(NULL, page, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); CHECK("pool object page", dead != MAP_FAILED);
        pool_builder_t vb = {.size = DM_GAME_APP_POOL + (1ull << 30), .flags = NVN_MEMORY_POOL_FLAGS_VIRTUAL};
        CHECK("a second sparse pool", h_nvnMemoryPoolInitialize((NVNmemoryPool *)dead, (const NVNmemoryPoolBuilder *)&vb));
        NVNtexture dx; h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)dead, 0); CHECK("a texture on it", h_nvnTextureInitialize(&dx, &tb));
        const tex_t *D = (const tex_t *)&dx; map_at(dead, 0, S, A, 1);
        (void)resolve(&dx); UNRELATED(); map_at(dead, far, PG, SCR, 1); (void)resolve(&dx);
        NvPkg *dk = tex_get(D->serial); uint64_t vid = dk ? dk->lid : 0, sq = dk ? dk->lseq : 0, sq0 = sq; uint64_t da = (uint64_t)(uintptr_t)D->mem;
        if (on) CHECK("its runs and log position are kept", dk && dk->lok && vid);
        h_nvnTextureFinalize(&dx); h_nvnMemoryPoolFinalize((NVNmemoryPool *)dead);
        CHECK("a finalized pool answers 'walk'", nvn_sparse_log_hit(dead, vid, &sq, da, S) == 1 && sq == sq0);
        CHECK("the pool again over the same object", h_nvnMemoryPoolInitialize((NVNmemoryPool *)dead, (const NVNmemoryPoolBuilder *)&vb));
        uint64_t db = (uint64_t)(uintptr_t)((const pool_t *)dead)->vp->base; uint64_t ign = 0;
        (void)nvn_sparse_log_seq(dead);   // its log starts (another texture asked)
        for (uint64_t i = 0; i < sq0 + 2; i++) map_at(dead, far + PG * (i & 3), PG, SCR, 1);   // past the old position, none over the old texture's range
        CHECK("the new pool's log has requests past the old position", (ign = nvn_sparse_log_seq(dead)) > sq0);
        sq = sq0; CHECK("the old position never answers for the new pool (its id)", nvn_sparse_log_hit(dead, vid, &sq, db, S) == 1 && sq == sq0);
        h_nvnMemoryPoolFinalize((NVNmemoryPool *)dead);
        CHECK("the finalized pool object is made unreadable", !mprotect(dead, page, PROT_NONE));
        UNRELATED(); map_at(&g_sparse, PG, PG, A + PG, 1); memcpy(exp + PG, sa + PG, PG);
        id<MTLTexture> m5 = resolve(&tx);
        CHECK("a later check never reads the finalized pool, and sees its own change", holds(m5, T, exp, W));
        CHECK("object page released", !munmap(dead, page)); }
    h_nvnTextureFinalize(&tx);
    printf("t_sparse_log (DM_NVN_SPARSE_LOG %s): %d checks, %d failed; page-table walks %llu, answered from the log %llu\n", on ? "on" : "off", checks, failed, (unsigned long long)g_spc_walk, (unsigned long long)g_spc_log);
    return failed != 0;
}}
