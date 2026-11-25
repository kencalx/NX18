// Packaged textures released for the footprint cap (nvn_mtl.m tex_idle_commit, DM_NVN_IDLE_TEX_PKG, DM_NVN_IDLE_TEX_FOOT_MB, DM_NVN_IDLE_TEX_FOOT_TRIM). Textures in a CPU-cached
// pool, each under a texture ID bound once, whose storage holds random bytes (the game's files, read in):
//  - P_IDLE: a 2048x2048 RGBA8 packaged texture (16 MB); P_ARR: a 128x128 RGBA8 packaged 2D array of 2 layers and 4 levels;
//  - P_POOL: one a pool table names (tt1); P_BUSY: one bound lately;
//  - P_GPU: one a GPU copy wrote into (a store in its package), whose storage the CPU then rewrote a page of, so gws_owned no longer holds and the store alone keeps it;
//  - P_CMP: a COMPRESSIBLE packaged 256x256 2D array of 2 layers: a buffer-to-texture copy writes layer 0 (no store: COMPRESSIBLE storage is not a store target), the CPU then
//    rewrites a page of layer 1 (gws_owned no longer holds); its storage lacks the copy, so it stays, and a later copy still reads the GPU's bytes;
//  - P_LOST: a packaged texture whose package took a GPU write its storage never got (gsb_lost, as gsb_missed marks one);
//  - P_CPU: a texture with no packaged layout whose storage the CPU wrote before its first use (CPU-written).
// The footprint the cap reads is 4 MB plus P_IDLE while it lives, the cap 16 MB.
//  - A copy of P_IDLE and of P_ARR's layer 1 level 1 into buffers gives the bytes they hold (A, AR).
//  - The next submission copies P_IDLE again and its commit's own sweep releases P_CPU, P_ARR and P_IDLE (the oldest first): P_IDLE's package waits for that submission's fence,
//    the copy completes with no GPU error and the same bytes, and the footprint is under the cap after it; the others stay, and the sweep's tally names each one's rule.
//  - Once the fence has passed the old package is freed; copies made after it upload P_IDLE and P_ARR again from their storage: byte for byte A and AR.
//  - A sweep under the cap releases nothing; over it with nothing to take, a cache trim is asked once (TRIM_FOOT), the next submission runs it, and as it frees under 64 MB the
//    next waits twice as long. A pressure warning takes the place of a cache trim asked.
// Run with DM_NVN_IDLE_TEX_PKG unset and =0, DM_NVN_IDLE_TEX_FOOT_TRIM=0, DM_MEMORY_TRIM=0 and DM_NVN_ENC_THREAD=1 (check_t_idle_pkg). At =0 only P_CPU goes, under the rules before
// packaged textures: its sharing entry stays, and the packaged ones are tallied as packaged.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
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
void crash_install(void);   // the write-fault handler: the CPU-written texture's pages are tracked from its initialization
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)

enum { BIG = 2048, SMALL = 64, ARR = 128, CMP = 256 };
enum { P_IDLE, P_POOL, P_GPU, P_BUSY, P_ARR, P_CMP, P_LOST, P_CPU, NT };
enum { OFF_TEX = 1 << 20, OFF_SMALL = 20 << 20, OFF_ARR = 22 << 20, OFF_CMP = 24 << 20, OFF_A = 32 << 20, OFF_A2 = 52 << 20, OFF_B = 72 << 20,
       OFF_SRC = 88 << 20, OFF_C = 89 << 20, OFF_AR = 90 << 20, OFF_AR2 = 91 << 20, POOL_LEN = 96 << 20 };
static NVNtexture tex[NT];
static int live(int i) { return serial_get(((tex_t *)&tex[i])->serial) != nil; }
static void bind(int i) { rmu_lock(); tex_by_id(i + 1); rmu_unlock(); }
static uint64_t fake_foot(void) { return (4ull << 20) + (live(P_IDLE) ? (uint64_t)BIG * BIG * 4 : 0); }
static int queued_at(id o, uint64_t fence) {
    int hit = 0; pthread_mutex_lock(&g_deferred_mu); for (NvDeferredRelease *d in g_deferred) hit |= d->object == o && d->fence == fence; pthread_mutex_unlock(&g_deferred_mu); return hit;
}
static void settle(void) { for (int i = 0; i < 100; i++) { @autoreleasepool { defer_drain(); } usleep(2000); } }
static pool_t pool; static uint8_t *mem;
static const NVNcopyRegion big = {0, 0, 0, BIG, BIG, 1}, small = {0, 0, 0, SMALL, SMALL, 1}, arr_l1 = {0, 0, 1, ARR / 2, ARR / 2, 1}, cmp_l0 = {0, 0, 0, CMP, CMP, 1};
static NVNtextureView lv1;   // level 1 of P_ARR
static void rec_begin(NVNcommandBuffer *cmd) { h_nvnCommandBufferAddCommandMemory(cmd, (const NVNmemoryPool *)&pool, 0, 65536); h_nvnCommandBufferBeginRecording(cmd); }
static void copy_out(NVNcommandBuffer *cmd, int i, const NVNtextureView *v, const NVNcopyRegion *r, uint64_t off) { h_nvnCommandBufferCopyTextureToBuffer(cmd, &tex[i], v, r, (uint64_t)mem + off, 0); }
static void run(NVNcommandHandle h) { state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_exec(nvn_rec_linear(h, NULL)); }
static void cpu_page(int i, uint64_t at) {   // the CPU rewrites one whole page of texture i's storage from byte `at` on
    size_t pg = (size_t)getpagesize(); uintptr_t a = ((uintptr_t)((tex_t *)&tex[i])->mem + at + pg - 1) & ~(uintptr_t)(pg - 1);
    memset((void *)a, 0x22, pg);
}

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    crash_install(); mtl_init();
    g_tu_manual = 1; g_tu_now = 10;
    g_tidle_foot = fake_foot; if (!getenv("DM_NVN_IDLE_TEX_FOOT_MB")) g_tidle_foot_mb = 16;
    int on = tidle_pkg_on();
    printf("DM_NVN_IDLE_TEX_PKG %d, cap %lld MB\n", on, (long long)g_tidle_foot_mb);
    mem = mmap(NULL, POOL_LEN, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort();
    pool_builder_t pb = {.mem = mem, .size = POOL_LEN, .flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool, (const NVNmemoryPoolBuilder *)&pb), "CPU-cached pool initialized");
    NVNpackagedTextureLayout lay = {{1, 0, 0, 0, 7, 0, 1, 0}};
    for (int i = 0; i < NT; i++) {
        NVNtextureBuilder tb; h_nvnTextureBuilderSetDefaults(&tb);
        int w = i == P_IDLE ? BIG : i == P_ARR ? ARR : i == P_CMP ? CMP : SMALL;
        h_nvnTextureBuilderSetWidth(&tb, w); h_nvnTextureBuilderSetHeight(&tb, w); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
        if (i == P_ARR || i == P_CMP) { h_nvnTextureBuilderSetTarget(&tb, NVN_TEXTURE_TARGET_2D_ARRAY); h_nvnTextureBuilderSetDepth(&tb, 2); }
        if (i == P_ARR) h_nvnTextureBuilderSetLevels(&tb, 4);
        if (i == P_CMP) h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
        if (i != P_CPU) h_nvnTextureBuilderSetPackagedTextureLayout(&tb, &lay);
        size_t off = i == P_IDLE ? OFF_TEX : i == P_ARR ? OFF_ARR : i == P_CMP ? OFF_CMP : OFF_SMALL + (size_t)(i - 1) * 65536;
        h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&pool, (ptrdiff_t)off);
        CHECK(h_nvnTextureInitialize(&tex[i], &tb), "texture initialized");
        size_t sz = h_nvnTextureGetStorageSize(&tex[i]);
        if (i == P_CMP) memset(mem + off, 0x11, sz);
        else { uint32_t x = 0x9e3779b9u * (uint32_t)(i + 1); for (size_t k = 0; k < sz; k++) { x ^= x << 13; x ^= x >> 17; x ^= x << 5; mem[off + k] = (uint8_t)x; } }
        CHECK(((tex_t *)&tex[i])->has_layout == (i != P_CPU), "a packaged layout, but for the CPU-written one");
    }
    for (int i = 0; i < NT; i++) mtl_reg_tex(i + 1, (const tex_t *)&tex[i], NULL);
    memset(mem + OFF_SRC, 0xAB, (size_t)CMP * CMP * 4);
    h_nvnTextureViewSetDefaults(&lv1); h_nvnTextureViewSetLevels(&lv1, 1, 1);
    const size_t bytes = (size_t)BIG * BIG * 4, arr_bytes = (size_t)(ARR / 2) * (ARR / 2) * 4;
    // Submission 1: every ID bound (P_CPU, P_ARR, P_CMP and P_LOST earliest, so a sweep takes them first), P_IDLE and P_ARR's layer 1 level 1 copied out, GPU copies into P_GPU and P_CMP's layer 0
    NVNcommandBuffer cmd; CHECK(h_nvnCommandBufferInitialize(&cmd, NULL), "command buffer initialized");
    rec_begin(&cmd);
    copy_out(&cmd, P_IDLE, NULL, &big, OFF_A); copy_out(&cmd, P_ARR, &lv1, &arr_l1, OFF_AR);
    h_nvnCommandBufferCopyTextureToTexture(&cmd, &tex[P_BUSY], NULL, &small, &tex[P_GPU], NULL, &small, 0);
    h_nvnCommandBufferCopyBufferToTexture(&cmd, (uint64_t)mem + OFF_SRC, &tex[P_CMP], NULL, &cmp_l0, 0);
    NVNcommandHandle h1 = h_nvnCommandBufferEndRecording(&cmd);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    g_tu_now = 5; bind(P_CPU); bind(P_ARR); bind(P_CMP); bind(P_LOST); g_tu_now = 10;   // P_CMP and P_LOST would go before P_IDLE, were they let go
    for (int i = 0; i < NT; i++) if (i != P_CPU && i != P_ARR && i != P_CMP && i != P_LOST) bind(i);
    mtl_exec(nvn_rec_linear(h1, NULL));
    int made = 0; for (int i = 0; i < NT; i++) made += live(i);
    CHECK(made == NT, "every texture made at its binding");
    __weak id old = serial_get(((tex_t *)&tex[P_IDLE])->serial);
    id cpu_pk = serial_get(((tex_t *)&tex[P_CPU])->serial);
    CHECK([old isKindOfClass:[NvPkg class]] && [cpu_pk isKindOfClass:[NvPkg class]], "P_IDLE is a package, and P_CPU too (CPU-written)");
    alias_key cpu_key = tex_alias_key((tex_t *)&tex[P_CPU]); cpu_pk = nil;
    g_treg[P_POOL + 1].tt1 = (uint8_t)MTLTextureType2D + 1;   // as pool_entry marks an ID a pool walk resolved
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "submission 1 completes without a GPU error");
    uint8_t *A = malloc(bytes), *AR = malloc(arr_bytes); memcpy(A, mem + OFF_A, bytes); memcpy(AR, mem + OFF_AR, arr_bytes);
    int nz = 0; for (size_t k = 0; k < bytes && !nz; k++) nz = A[k] != 0;
    CHECK(nz, "the copy holds the texture's bytes (not zeros)");
    {   NvPkg *g = serial_get(((tex_t *)&tex[P_GPU])->serial), *c = serial_get(((tex_t *)&tex[P_CMP])->serial);
        CHECK(g->stored && !c->stored, "the copy into P_GPU was stored into its storage, the one into COMPRESSIBLE P_CMP not"); }
    cpu_page(P_GPU, 0); cpu_page(P_CMP, ((tex_t *)&tex[P_CMP])->L.layer_size);   // the CPU rewrites a page: gws_owned no longer holds for either
    { const tex_t *g = (tex_t *)&tex[P_GPU], *c = (tex_t *)&tex[P_CMP];
      CHECK(!gws_owned((uintptr_t)g->mem, (uintptr_t)g->mem + g->L.size) && !gws_owned((uintptr_t)c->mem, (uintptr_t)c->mem + c->L.size), "after the CPU's page, neither storage reads as GPU-written"); }
    gsb_lost((tex_t *)&tex[P_LOST]);
    CHECK(((NvPkg *)serial_get(((tex_t *)&tex[P_LOST])->serial))->gw_lost, "P_LOST's package keeps that a GPU write missed its storage");
    // Submission 2 (9 s later): P_BUSY bound again, P_IDLE copied out again, and its commit's own sweep, the footprint 20 MB over the cap of 16
    h_nvnCommandBufferFinalize(&cmd); CHECK(h_nvnCommandBufferInitialize(&cmd, NULL), "command buffer initialized again");
    rec_begin(&cmd); copy_out(&cmd, P_IDLE, NULL, &big, OFF_A2); NVNcommandHandle h2 = h_nvnCommandBufferEndRecording(&cmd);
    g_tu_now = 100;
    uint64_t pn0 = g_tidle_pkg_n, n0 = g_tidle_n, w0 = g_tidle_wlines, tr0 = g_tidle_trims;
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); bind(P_BUSY);
    mtl_exec(nvn_rec_linear(h2, NULL));
    g_tidle_at = 0; g_tidle_foot_last = 0;
    uint64_t fence = g_fence + 1;
    uint64_t done2 = mtl_sub_commit();   // the sweep runs here, before the fence is taken
    CHECK(!live(P_CPU), "the CPU-written one goes");
    if (on) {
        CHECK(!live(P_IDLE) && !live(P_ARR) && g_tidle_pkg_n - pn0 == 2 && g_tidle_n - n0 == 3 && g_tidle_pkg_bytes >= bytes, "the idle packaged textures go too, counted as packaged");
        id o = old; CHECK(o && queued_at(o, fence), "P_IDLE's package waits for the fence of the submission that copies from it"); o = nil;
        CHECK(!g_treg[P_IDLE + 1].view, "its ID's view goes with it");
        CHECK(!hm_get_id(&g_pkg_share, &cpu_key), "a released package's sharing entry goes with it");
    } else {
        CHECK(live(P_IDLE) && live(P_ARR) && g_tidle_n - n0 == 1, "DM_NVN_IDLE_TEX_PKG=0: the packaged ones stay");
        CHECK(hm_get_id(&g_pkg_share, &cpu_key) != nil, "=0: the released CPU-written package's sharing entry stays, as before");
    }
    CHECK(live(P_POOL) && live(P_GPU) && live(P_BUSY) && live(P_CMP) && live(P_LOST), "the table-named, GPU-written, recently bound, COMPRESSIBLE and lost-write ones stay");
    CHECK(g_tidle_wlines - w0 == 1, "one sweep line logged");
    const tidle_tally *ta = &g_tidle_last;
    printf("tally: all %llu; pool %llu, gpu %llu, busy %llu, storage %llu, pkg off %llu, ok %llu\n", (unsigned long long)ta->all_n, (unsigned long long)ta->n[TW_POOL], (unsigned long long)ta->n[TW_GPU],
           (unsigned long long)ta->n[TW_BUSY], (unsigned long long)ta->n[TW_STORAGE], (unsigned long long)ta->n[TW_PKG_OFF], (unsigned long long)ta->n[TW_OK]);
    CHECK(ta->all_n == NT && ta->n[TW_POOL] == 1 && ta->n[TW_BUSY] == 1 && ta->kn[TK_STORE] == NT, "the tally: eight packages, one kept for a pool table, one for a recent binding");
    if (on) CHECK(ta->n[TW_GPU] == 2 && ta->n[TW_STORAGE] == 1 && ta->n[TW_OK] == 3 && ta->b[TW_OK] >= bytes,
                  "kept for a GPU write: P_GPU (its store alone) and P_LOST; for its storage: COMPRESSIBLE P_CMP; three could go, 16 MB with them");
    else CHECK(ta->n[TW_PKG_OFF] == 5 && ta->n[TW_OK] == 1 && ta->b[TW_PKG_OFF] >= bytes, "=0: five kept as packaged, the CPU-written one could go");
    CHECK(mtl_wait(done2, 5000000000ull) && !mtl_last_commit_error(), "submission 2 completes without a GPU error");
    CHECK(!memcmp(mem + OFF_A2, A, bytes), "the copy recorded before the release read the same bytes");
    if (on) CHECK(fake_foot() < (uint64_t)g_tidle_foot_mb << 20, "the footprint is under the cap");
    CHECK(on ? g_tidle_trims == tr0 : g_tidle_trims == tr0 + (getenv("DM_NVN_IDLE_TEX_FOOT_TRIM") || getenv("DM_MEMORY_TRIM") ? 0 : 1),
          on ? "it freed what it wanted: no cache trim asked" : "freed little: a cache trim asked (unless off)");
    settle();
    if (on) CHECK(!old, "the old package is freed once the fence has passed");
    // Submission 3: copies after the release: made again from the storage, byte for byte; P_CMP's layer 0 still the GPU's copy
    h_nvnCommandBufferFinalize(&cmd); CHECK(h_nvnCommandBufferInitialize(&cmd, NULL), "command buffer initialized again");
    rec_begin(&cmd); copy_out(&cmd, P_IDLE, NULL, &big, OFF_B); copy_out(&cmd, P_ARR, &lv1, &arr_l1, OFF_AR2); copy_out(&cmd, P_CMP, NULL, &cmp_l0, OFF_C);
    NVNcommandHandle h3 = h_nvnCommandBufferEndRecording(&cmd);
    uint64_t up0 = g_pkg_uploads;
    run(h3);
    if (on) CHECK(g_pkg_uploads - up0 >= 2, "P_IDLE and P_ARR uploaded again from their storage");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "submission 3 completes without a GPU error");
    CHECK(live(P_IDLE) && !memcmp(mem + OFF_B, A, bytes), "P_IDLE made again: byte for byte what it held");
    CHECK(live(P_ARR) && !memcmp(mem + OFF_AR2, AR, arr_bytes), "P_ARR's layer 1 level 1 made again: byte for byte what it held");
    CHECK(mem[OFF_C] == 0xAB && mem[OFF_C + (size_t)CMP * CMP * 4 - 1] == 0xAB, "P_CMP's layer 0 still holds the GPU's copy");
    // Under the cap: nothing more goes; over it with nothing to take: one cache trim asked, run at the next submission's start, and the next waits twice as long
    uint64_t n1 = g_tidle_n, tr1 = g_tidle_trims; g_tu_now = 300;
    for (int i = 0; i < NT; i++) bind(i);
    g_tidle_at = 0; g_tidle_foot_last = 0; g_tidle_foot_mb = 64; tex_idle_commit();
    CHECK(g_tidle_n == n1 && live(P_IDLE), "under the cap: nothing goes");
    g_tidle_foot_mb = 1; g_tidle_trim_at = 0; g_tidle_trim_every = TIDLE_TRIM_NS; atomic_store(&g_trim_req, 0);
    g_tidle_at = 0; g_tidle_foot_last = 0; tex_idle_commit();
    g_tidle_at = 0; g_tidle_foot_last = 0; tex_idle_commit();
    const char *te = getenv("DM_NVN_IDLE_TEX_FOOT_TRIM"), *me = getenv("DM_MEMORY_TRIM");
    int want_trim = (!te || atoi(te) != 0) && (!me || atoi(me) != 0);
    CHECK(g_tidle_n == n1 && g_tidle_trims - tr1 == (uint64_t)want_trim, want_trim ? "over the cap with nothing idle: one cache trim asked for two sweeps" : "the trim off (or DM_MEMORY_TRIM=0): none asked");
    CHECK(atomic_load(&g_trim_req) == (want_trim ? TRIM_FOOT : 0), "the request waits for the next submission");
    uint64_t t0 = atomic_load(&g_trim_n);
    mtl_sub_begin();
    CHECK(atomic_load(&g_trim_req) == 0 && atomic_load(&g_trim_n) - t0 == (uint64_t)want_trim, "the next submission's start runs it");
    if (want_trim) CHECK(g_tidle_trim_every == 2 * TIDLE_TRIM_NS, "it freed under 64 MB: the next waits twice as long");
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "a submission completes");
    if (!me || atoi(me) != 0) {
        atomic_store(&g_trim_req, TRIM_FOOT); mtl_pressure(1);
        CHECK(atomic_load(&g_trim_req) == 1, "a pressure warning takes the place of a cache trim asked");
    }
    atomic_store(&g_trim_req, 0);
    h_nvnCommandBufferFinalize(&cmd);
    for (int i = 0; i < NT; i++) { mtl_reg_tex(i + 1, NULL, NULL); h_nvnTextureFinalize(&tex[i]); }
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&pool);
    settle(); munmap(mem, POOL_LEN); free(A); free(AR);
    printf("t_idle_pkg (DM_NVN_IDLE_TEX_PKG=%d): %d checks, %d failed\n", on, checks, failed);
    return failed != 0;
} }
