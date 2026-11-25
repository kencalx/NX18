// Live textures idle at low headroom (nvn_mtl.m tex_idle_commit, DM_NVN_IDLE_TEX_MB; ported from S2Arm 8adc5673, 987b31ef). Six CPU-written textures in a CPU-cached pool, each
// registered under a texture ID and bound once (tex_by_id): with no headroom known (the Mac), and with headroom above the threshold, nothing goes. Under it, the one whose IDs are
// unused for the wait goes; one bound lately, one whose storage the GPU wrote (gws_owned), one a pool table names (tt1), one with a display flag and one pinned by a queued
// descriptor stay. Its entry goes at once and its ID's view with it, but its object waits in the deferred-release queue for the open submission's fence; the next use makes it
// again from guest memory, and a copy of it reads the bytes the CPU wrote. Then the commit itself releases the one bound lately once it too has been unused for the wait.
// Run with DM_NVN_IDLE_TEX_MB unset and =0 (check_t_idle_tex): at 0 nothing goes at all. With T_IDLE_FOOT=1 the headroom stays high and the footprint goes over the cap instead
// (DM_NVN_IDLE_TEX_FOOT_MB, given 1000 MB here): under the cap nothing goes, over it the same one goes, with the footprint cap's line; =0 off: nothing goes
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
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)

static uint64_t g_fake;   // the headroom the host reads (g_rh_avail), 0: none known
static uint64_t fake_avail(void) { return g_fake; }
static uint64_t g_foot;   // the footprint the cap is held against (g_tidle_foot)
static uint64_t fake_foot(void) { return g_foot; }
enum { NT = 6, W = 8, COPY_OFF = 1 << 20 };
enum { T_IDLE, T_RECENT, T_GPU, T_POOL, T_DISPLAY, T_PIN };
static NVNtexture tex[NT]; static uint8_t pixels[NT][W * W * 4];
static int live(int i) { return serial_get(((tex_t *)&tex[i])->serial) != nil; }
static void bind(int i) { rmu_lock(); tex_by_id(i + 1); rmu_unlock(); }   // a binding of its ID: stamped with g_tu_now
static int queued_at(id o, uint64_t fence) {   // o waits in the deferred-release queue for fence
    int hit = 0; pthread_mutex_lock(&g_deferred_mu); for (NvDeferredRelease *d in g_deferred) hit |= d->object == o && d->fence == fence; pthread_mutex_unlock(&g_deferred_mu); return hit;
}
static void settle(void) { for (int i = 0; i < 100; i++) { @autoreleasepool { defer_drain(); } usleep(2000); } }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    mtl_init();
    g_rh_avail = fake_avail; g_tu_manual = 1; g_tu_now = 10;
    int by_foot = getenv("T_IDLE_FOOT") != NULL;
    if (by_foot) { g_tidle_foot = fake_foot; if (!getenv("DM_NVN_IDLE_TEX_FOOT_MB")) g_tidle_foot_mb = 1000; }
    int on = by_foot ? tidle_foot_cap() != 0 : tidle_low() != 0; (void)tidle_low();
    printf("T_IDLE_FOOT %d, DM_NVN_IDLE_TEX_FOOT_MB=%lld\n", by_foot, (long long)g_tidle_foot_mb);
    CHECK(by_foot || getenv("DM_NVN_IDLE_TEX_FOOT_MB") || g_tidle_foot_mb <= 0, "no footprint cap on the Mac by default");
    printf("DM_NVN_IDLE_TEX_MB=%lld\n", (long long)g_tidle_mb);
    CHECK(getenv("DM_NVN_IDLE_TEX_MB") || g_tidle_mb == 1536, "1536 MB by default");
    const size_t len = 2 << 20;
    uint8_t *mem = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (mem == MAP_FAILED) abort();
    pool_t pool = {0}; pool_builder_t pb = {.mem = mem, .size = len, .flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&pool, (const NVNmemoryPoolBuilder *)&pb), "CPU-cached pool initialized");
    NVNcopyRegion region = {0, 0, 0, W, W, 1};
    for (int i = 0; i < NT; i++) {
        NVNtextureBuilder tb; h_nvnTextureBuilderSetDefaults(&tb);
        h_nvnTextureBuilderSetWidth(&tb, W); h_nvnTextureBuilderSetHeight(&tb, W); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
        if (i == T_DISPLAY) h_nvnTextureBuilderSetFlags(&tb, NVN_TEXTURE_FLAGS_DISPLAY);
        h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&pool, (ptrdiff_t)(i + 1) * 65536);
        CHECK(h_nvnTextureInitialize(&tex[i], &tb), "texture initialized");
        for (int k = 0; k < W * W * 4; k++) pixels[i][k] = (uint8_t)(i * 37 + k * 3 + 1);
        h_nvnTextureWriteTexels(&tex[i], NULL, &region, pixels[i]);
        mtl_reg_tex(i + 1, (const tex_t *)&tex[i], NULL);
    }
    mtl_sub_begin();
    for (int i = 0; i < NT; i++) bind(i);
    int made = 0; for (int i = 0; i < NT; i++) made += live(i);
    CHECK(made == NT, "every texture made at its binding");
    __weak id old = serial_get(((tex_t *)&tex[T_IDLE])->serial);
    CHECK([old isKindOfClass:[NvPkg class]], "the idle one is taken from its storage (packaged)");
    mtl_tex_gpu_written((const tex_t *)&tex[T_GPU]);   // the GPU drew or copied over its storage
    g_treg[T_POOL + 1].tt1 = (uint8_t)MTLTextureType2D + 1;   // as pool_entry marks an ID a pool walk resolved
    mtl_tex_pin(((tex_t *)&tex[T_PIN])->serial);   // a queued descriptor's pin
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the first submission completes");
    mtl_sub_begin();
    g_tu_now = 100; bind(T_RECENT);   // 9 s later: one bound again
    uint64_t n0 = g_tidle_n, l0 = g_tidle_lines;
    // No headroom known (the Mac), and headroom above the threshold: nothing
    g_fake = 0; g_tidle_at = 0; g_tidle_foot_last = 0; tex_idle_commit();
    made = 0; for (int i = 0; i < NT; i++) made += live(i);
    CHECK(made == NT && g_tidle_n == n0, "no headroom known: nothing goes");
    g_fake = 4ull << 30; g_tidle_at = 0; g_tidle_foot_last = 0; tex_idle_commit();
    made = 0; for (int i = 0; i < NT; i++) made += live(i);
    CHECK(made == NT && g_tidle_n == n0, "headroom above the threshold: nothing goes");
    if (by_foot) { g_foot = 900ull << 20; g_tidle_at = 0; g_tidle_foot_last = 0; tex_idle_commit(); made = 0; for (int i = 0; i < NT; i++) made += live(i);
        CHECK(made == NT && g_tidle_n == n0, "footprint under the cap: nothing goes"); }
    // Under it (or the footprint over the cap)
    uint64_t f0 = g_tidle_foot_n;
    if (by_foot) g_foot = 1200ull << 20; else g_fake = 100ull << 20;
    g_tidle_at = 0; g_tidle_foot_last = 0; tex_idle_commit();
    uint64_t fence = g_fence + 1;
    printf("released %llu (%llu bytes)\n", (unsigned long long)(g_tidle_n - n0), (unsigned long long)g_tidle_bytes);
    if (!on) CHECK(live(T_IDLE) && g_tidle_n == n0, "DM_NVN_IDLE_TEX_MB=0 (DM_NVN_IDLE_TEX_FOOT_MB=0): nothing goes");
    else {
        CHECK(!live(T_IDLE) && g_tidle_n - n0 == 1 && g_tidle_lines - l0 == 1, "the idle CPU-sourced texture goes, one line logged");
        CHECK(!g_treg[T_IDLE + 1].view, "its ID's view goes with it");
        CHECK(by_foot ? g_tidle_foot_n - f0 == 1 : g_tidle_foot_n == f0, "counted for the footprint cap when the footprint made it go, not otherwise");
        if (by_foot) {   // the sweep freed under 64 MB: the next waits twice as long (a sweep a moment later does not run), and goes again once that time has passed
            uint64_t r0 = g_tidle_runs, every = g_tidle_foot_every; g_tidle_at = 0; g_tu_now = 101; bind(T_RECENT); tex_idle_commit();
            CHECK(every == 2000000000ull && g_tidle_runs == r0 && live(T_RECENT), "footprint cap: a sweep that freed little backs off to 2 s");
            g_foot = 900ull << 20; g_tidle_at = 0; tex_idle_commit(); g_foot = 1200ull << 20;
            CHECK(g_tidle_foot_every == 1000000000ull, "and the footprint under the cap ends the back-off");
            g_tu_now = 100;
        }
        CHECK(live(T_RECENT), "one bound lately stays");
        CHECK(live(T_GPU), "one whose storage the GPU wrote stays");
        CHECK(live(T_POOL), "one a pool table names stays");
        CHECK(live(T_DISPLAY), "a display texture stays");
        CHECK(live(T_PIN), "a pinned one stays");
        id o = old; CHECK(o && queued_at(o, fence), "its object waits in the deferred-release queue for the open submission's fence");
        o = nil;
    }
    // The fence passes, and a copy of it reads what the CPU wrote: made again from guest memory
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completes");
    settle();
    if (on) CHECK(!old, "freed once the fence passed");
    NVNcommandBuffer cmd; CHECK(h_nvnCommandBufferInitialize(&cmd, NULL), "command buffer initialized");
    h_nvnCommandBufferAddCommandMemory(&cmd, (const NVNmemoryPool *)&pool, 0, 65536); h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyTextureToBuffer(&cmd, &tex[T_IDLE], NULL, &region, (uint64_t)mem + COPY_OFF, 0);
    NVNcommandHandle handle = h_nvnCommandBufferEndRecording(&cmd);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); mtl_exec(nvn_rec_linear(handle, NULL));
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the copy completes without a GPU error");
    CHECK(!memcmp(mem + COPY_OFF, pixels[T_IDLE], sizeof pixels[T_IDLE]) && live(T_IDLE), "made again from guest memory: the copy reads what the CPU wrote");
    // The commit's own sweep: the one bound lately, unused for the wait too
    if (on) {
        uint64_t n1 = g_tidle_n;
        g_tu_now = 200; g_tidle_at = 0; g_tidle_foot_last = 0; mtl_sub_begin(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "a submission completes");
        CHECK(!live(T_RECENT) && g_tidle_n - n1 >= 1 && live(T_GPU) && live(T_POOL) && live(T_DISPLAY) && live(T_PIN), "the commit releases it once it too is idle, the others still stay");
    }
    mtl_tex_unpin(((tex_t *)&tex[T_PIN])->serial);
    h_nvnCommandBufferFinalize(&cmd);
    for (int i = 0; i < NT; i++) { mtl_reg_tex(i + 1, NULL, NULL); h_nvnTextureFinalize(&tex[i]); }
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&pool);
    settle(); munmap(mem, len);
    printf("t_idle_tex (DM_NVN_IDLE_TEX_MB=%lld): %d checks, %d failed\n", (long long)g_tidle_mb, checks, failed);
    return failed != 0;
} }
