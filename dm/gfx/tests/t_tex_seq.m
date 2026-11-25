// Texture lookups past the cached view (tex_by_id_ptr, DM_NVN_ARGS_STATS' AG_TEXSLOW) under guest writes elsewhere, and tex_fit's type-compatible views.
// A packaged (here CPU-written) texture ID's view was current only until the next guest write anywhere (the dirty clock): Ocarina of Time takes about 2,000 write faults a second
// across 4,700 memory pools, so nearly every binding of a packaged texture went down the slow path for a check of its pages (2026-11-21: 19-21% of full encodes on the phone).
// DM_NVN_TEX_SEQ keeps the tracked range's write sequence with the view (nvn_dirty_since_seq), so a write to another range leaves it current; DM_NVN_TEX_ALT2 keeps a second
// type-compatible view per ID. Checked here: the same resource IDs with the switches on and off, a write to a texture's own pages still re-uploads it (and only it), a write
// beside textures in their own pool sends only that pool's IDs to the page check, a pool's removal is seen, and an ID read as two types makes its views once.
// Bench: lookups through tex_fast_rid with a write between rounds, off and on (best of 5)
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#include <sys/mman.h>
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { P = 96, PER = 2, N = P * PER, TW = 256, POOL = 1 << 20, TOFF = 256 << 10, DATA = 1 << 20, ROUNDS = 48 };   // P pools of PER 256x256 RGBA8 textures (256 KB) at 0 and 256 KB; a data pool
static uint8_t *g_pmem[P], *g_dmem; static pool_t g_pool[P], g_dpool; static NVNtexture g_tex[N];
static size_t g_pg;

static void pool_make(pool_t *pool, uint8_t **mem, size_t len) {
    *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (*mem == MAP_FAILED) abort();
    pool_builder_t pb = {.mem=*mem, .size=len, .flags=NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)pool, (const NVNmemoryPoolBuilder *)&pb), "CPU-cached pool initialized");
}
static void tex_make(NVNtexture *tex, pool_t *pool, ptrdiff_t off, int target, int depth, uint8_t fill) {
    NVNtextureBuilder tb; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetTarget(&tb, target); h_nvnTextureBuilderSetWidth(&tb, TW); h_nvnTextureBuilderSetHeight(&tb, TW); h_nvnTextureBuilderSetDepth(&tb, depth);
    h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8); h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)pool, off);
    CHECK(h_nvnTextureInitialize(tex, &tb), "texture initialized");
    static uint8_t px[TW * TW * 4]; memset(px, fill, sizeof px);
    for (int z = 0; z < depth; z++) { NVNcopyRegion r = {0, 0, z, TW, TW, 1}; h_nvnTextureWriteTexels(tex, NULL, &r, px); }   // CPU-written: a packaged texture's path
}
// A guest write the dirty tracking sees (a fault's effect): the page protected, then written through the host's pre-write hook
static void gwrite(void *p) { void *pg = (void *)((uintptr_t)p & ~(g_pg - 1)); nvn_dirty_protect(pg, g_pg); dm_guest_write_prepare(p, 16); memset(p, 0x5a, 16); }
// One round of lookups of every ID, as the bindings of a stretch of draws between two guest writes: the resource IDs folded into *sum, and each kept in rid (when not NULL)
static void round_(uint64_t *sum, uint64_t *rid) {
    rmu_lock();
    for (int i = 1; i <= N; i++) { void *tv = NULL; uint64_t r = tex_fast_rid(i, &tv); *sum = *sum * 31 + r; if (rid) rid[i] = r; }
    os_unfair_lock_unlock(&g_rmu);
}
// The switch as mtl_init reads it: off, no ID keeps a range's write sequence (one kept from a run with it on would still be taken by the fast tests)
static void seq_mode(int on) { g_tex_seq = on; if (!on) { rmu_lock(); for (int i = 0; i < g_ntreg; i++) g_treg[i].view_wp = NULL; os_unfair_lock_unlock(&g_rmu); } }
static uint64_t slow_n(void) { uint64_t n = 0; for (int i = 0; i < TS_N; i++) n += g_tsl.n[i]; return n; }
// rounds of lookups with a write before each: where = 0 a data pool, 1 a page of texture pool (round % P) beside its textures. Returns the ns per lookup
static double run(int where, int rounds, uint64_t *sum) {
    uint64_t t = 0;
    for (int k = 0; k < rounds; k++) {
        gwrite(where ? g_pmem[k % P] + 3 * TOFF + 64 : g_dmem + (size_t)(k % 32) * g_pg + 64);
        uint64_t t0 = bp_now(); round_(sum, NULL); t += bp_now() - t0;
    }
    return (double)t / ((double)rounds * N);
}

int main(void) { @autoreleasepool {
    alarm(300);
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1); setenv("DM_PSO_RECORD", "/dev/null", 1);
    g_pg = (size_t)getpagesize();
    mtl_init(); ast_init(); g_ast_on = 0;
    pool_make(&g_dpool, &g_dmem, DATA);
    for (int p = 0; p < P; p++) { pool_make(&g_pool[p], &g_pmem[p], POOL); for (int j = 0; j < PER; j++) tex_make(&g_tex[p * PER + j], &g_pool[p], (ptrdiff_t)j * TOFF, NVN_TEXTURE_TARGET_2D, 1, (uint8_t)(p * PER + j)); }
    for (int i = 1; i <= N; i++) mtl_reg_tex(i, (const tex_t *)&g_tex[i - 1], NULL);
    mtl_sub_begin(); uint64_t s0 = 0; round_(&s0, NULL); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "first uploads completed");
    for (int i = 1; i <= N; i++) CHECK(g_treg[i].view && g_treg[i].view_pkg && g_treg[i].view_span, "each ID holds a packaged view with its tracked range");

    // 1. the same resource IDs, on and off, through writes in another pool and beside the textures in theirs
    uint64_t sum[2][2] = {{0}};
    for (int on = 0; on < 2; on++) { seq_mode(on); mtl_sub_begin(); for (int w = 0; w < 2; w++) run(w, ROUNDS, &sum[on][w]); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "rounds submitted"); }
    CHECK(sum[0][0] == sum[1][0] && sum[0][1] == sum[1][1], "the same resource IDs with DM_NVN_TEX_SEQ on and off");

    // 2. counted: a write in another pool sends no ID down the slow path once each has been checked; one beside textures sends only that pool's IDs (to the page check, clean)
    g_ast_on = 1;
    for (int on = 0; on < 2; on++) {
        seq_mode(on); mtl_sub_begin(); uint64_t s = 0; run(0, 2, &s); run(1, 2, &s);   // settle: every ID checked once in this mode
        memset(&g_tsl, 0, sizeof g_tsl); run(0, ROUNDS, &s);
        uint64_t a = slow_n(), asp = g_tsl.n[TS_SPAN];
        memset(&g_tsl, 0, sizeof g_tsl); run(1, ROUNDS, &s);
        uint64_t b = slow_n(), bsp = g_tsl.n[TS_SPAN];
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "counted rounds submitted");
        printf("DM_NVN_TEX_SEQ=%d: %d rounds of %d lookups, a write before each: in another pool %llu past the cached view (%llu page checks), beside textures in their pool %llu (%llu page checks)\n",
               on, ROUNDS, N, (unsigned long long)a, (unsigned long long)asp, (unsigned long long)b, (unsigned long long)bsp);
        if (!on) CHECK(a == (uint64_t)ROUNDS * N && asp == a && b == (uint64_t)ROUNDS * N, "off: every packaged ID checked after every write");
        else CHECK(a == 0 && b == (uint64_t)ROUNDS * PER && bsp == b, "on: a write in another pool sends none, one beside textures only that pool's IDs, each to a clean page check");
    }
    g_ast_on = 0;

    // 3. a write to a texture's own pages: re-uploaded (a new resource ID) after any number of writes elsewhere, and only that texture; with the switch on and off
    for (int on = 0; on < 2; on++) {
        seq_mode(on); static uint64_t r0[N + 1], r1[N + 1];
        mtl_sub_begin(); uint64_t s = 0; run(0, 4, &s); round_(&s, r0);
        const int victim = 2 * PER + 1;   // the second texture of pool 2: its pool-mate keeps its view
        gwrite(((tex_t *)&g_tex[victim - 1])->mem + 4096);
        run(0, 3, &s); round_(&s, r1);
        int changed = 0; for (int i = 1; i <= N; i++) changed += r0[i] != r1[i];
        char l[160]; snprintf(l, sizeof l, "DM_NVN_TEX_SEQ=%d: a write into a texture re-uploads it, and only it", on);
        CHECK(r0[victim] != r1[victim] && changed == 1, l);
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "re-upload submitted");
    }

    // 4. the range's removal and registration over other memory: the kept sequence no longer holds
    {
        seq_mode(1); mtl_sub_begin(); uint64_t s = 0; run(0, 2, &s);
        treg_t *r = &g_treg[1]; const void *wp = r->view_wp; uint64_t w = r->view_w;
        CHECK(wp && nvn_dirty_seq_same(wp, w), "an ID checked clean keeps its range's write sequence");
        uint8_t *m = g_pmem[0]; nvn_dirty_remove_range(m);
        CHECK(!nvn_dirty_seq_same(wp, w), "the range's removal moves it");
        nvn_dirty_add_range(m, POOL);
        CHECK(!nvn_dirty_seq_same(wp, w), "and so does a registration over the memory");
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submitted");
    }

    // 5. tex_fit: an ID read as a 2D array and as a cube in turn (a 6-layer array) makes its two views once with DM_NVN_TEX_ALT2, and again at each change without
    {
        pool_t apool; uint8_t *amem; pool_make(&apool, &amem, 4 << 20);
        NVNtexture at; tex_make(&at, &apool, 0, NVN_TEXTURE_TARGET_2D_ARRAY, 6, 0x33);
        const int aid = N + 1; mtl_reg_tex(aid, (const tex_t *)&at, NULL);
        g_ast_on = 1;
        for (int on = 0; on < 2; on++) {
            g_tex_alt2 = on; mtl_sub_begin(); rmu_lock();
            treg_drop_views(&g_treg[aid]);
            memset(&g_tsl, 0, sizeof g_tsl); uint64_t g0 = g_alt_gen;
            uint64_t rid2[2] = {0}, ridc[2] = {0}; int same = 1, types = 1;
            for (int k = 0; k < 20; k++) {
                id<MTLTexture> t = tex_by_id(aid); uint64_t a = 0, c = 0;
                id<MTLTexture> v2 = tex_fit(aid, t, MTLTextureType2D, &a), vc = tex_fit(aid, t, MTLTextureTypeCube, &c);
                types &= v2.textureType == MTLTextureType2D && vc.textureType == MTLTextureTypeCube && vc.arrayLength == 1 && v2.parentTexture == vc.parentTexture;
                if (k == 0) { rid2[on] = a; ridc[on] = c; } else same &= a == rid2[on] && c == ridc[on];
            }
            os_unfair_lock_unlock(&g_rmu);
            uint64_t made = g_tsl.fn[TF_NEW] + g_tsl.fn[TF_VIEW] + g_tsl.fn[TF_TYPE];
            printf("DM_NVN_TEX_ALT2=%d: 20 rounds of a 2D and a cube read of one ID: %llu views made (%llu for another type), %llu kept hits, %llu second-view hits; type-view generation moved %llu\n",
                   on, (unsigned long long)made, (unsigned long long)g_tsl.fn[TF_TYPE], (unsigned long long)g_tsl.fn[TF_HIT], (unsigned long long)g_tsl.fn[TF_KEPT2], (unsigned long long)(g_alt_gen - g0));
            CHECK(types, "each read gets a view of its declared type over the same texture");
            if (on) CHECK(made == 2 && same && g_tsl.fn[TF_KEPT2] == 19, "on: the two views made once and kept");
            else CHECK(made == 40 && g_tsl.fn[TF_TYPE] == 39, "off: a view made at each change of type");
            CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "submitted");
        }
        g_ast_on = 0;
    }

    // bench: lookups with a write in another pool before each round of N, best of 5
    {
        double best[2][2] = {{1e9, 1e9}, {1e9, 1e9}};
        for (int rep = 0; rep < 5; rep++) for (int on = 0; on < 2; on++) {
            seq_mode(on); mtl_sub_begin(); uint64_t s = 0; run(0, 2, &s); run(1, 2, &s);
            for (int w = 0; w < 2; w++) { double ns = run(w, 200, &s); if (ns < best[on][w]) best[on][w] = ns; }
            CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "bench submitted");
        }
        // the same with DM_NVN_ARGS_STATS' timing, as the phone's log measures it: the time inside tex_by_id_ptr (AG_TEXSLOW) a lookup, clock reads included
        double sl[2] = {0}; g_ast_on = 1;
        for (int on = 0; on < 2; on++) { seq_mode(on); mtl_sub_begin(); uint64_t s = 0; run(0, 2, &s); uint64_t x0 = tl_tex_slow; run(0, 200, &s); sl[on] = (double)(tl_tex_slow - x0) * g_ast.ns_per_tick / (200.0 * N);
                                         CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "bench submitted"); }
        g_ast_on = 0;
        printf("t_tex_seq bench (%d packaged texture IDs, %d KB each, in %d pools, a guest write before each round, best of 5): write in another pool %.1f ns a lookup off / %.1f ns on; "
               "write beside textures in one of their pools %.1f ns off / %.1f ns on; with DM_NVN_ARGS_STATS, time past the cached view %.1f ns a lookup off / %.1f ns on\n",
               N, TW * TW * 4 / 1024, P, best[0][0], best[1][0], best[0][1], best[1][1], sl[0], sl[1]);
        CHECK(best[1][0] < best[0][0], "on: lookups after a write elsewhere are cheaper");
    }
    printf("t_tex_seq: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
