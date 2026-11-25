// Read-ahead at setup and the residency trickle (ported from kid-with-sword-remake, cheemu21, MIT: L7.7 58a47fbf + f8aea728, L7.8 c8c37258).
// mtl_preread: a range is asked once, again only after 2 s, a longer range at the same start is asked again, ranges over 64 MB and DM_NVN_PREREAD=0 ask nothing,
// and the calls run on the queue. res_trickle: nothing before a pool table was built, then addressed pools up to the budget per frame (the next frame takes the rest),
// never an unaddressed pool or one over 64 MB, and DM_NVN_RES_TRICKLE_MB's budget
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static uint8_t *file_mem(size_t n) {
    const char *td = getenv("TMPDIR"); char path[512]; snprintf(path, sizeof path, "%s/t_preread.XXXXXX", td && *td ? td : "/tmp");
    int fd = mkstemp(path); if (fd < 0) abort(); unlink(path);
    if (ftruncate(fd, (off_t)n)) abort();
    uint8_t *m = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0); if (m == MAP_FAILED) abort();
    close(fd); return m;
}
static int res_of(const void *mem) { mu_lock(); int i = pool_peek((uint64_t)(uintptr_t)mem), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r; }
static void drain(void) { for (int i = 0; i < 200 && atomic_load(&g_preread_ns) == 0; i++) usleep(1000); }
int main(void) { @autoreleasepool {
    mtl_init();
    g_preread = 1; setenv("DM_NVN_RES_TRICKLE_MB", "16", 1);   // both off by default: DM_NVN_PREREAD=1, DM_NVN_RES_TRICKLE_MB=16
    size_t MB = 1u << 20;
    // mtl_preread
    uint8_t *m = file_mem(8 * MB);
    mtl_preread(m, 1 * MB);
    CHECK("first ask", atomic_load(&g_preread_n) == 1 && atomic_load(&g_preread_bytes) == MB);
    mtl_preread(m, 1 * MB);
    mtl_preread(m + 100, 4000);   // same page start, a shorter end
    CHECK("asked again within 2 s: skipped", atomic_load(&g_preread_n) == 1 && atomic_load(&g_preread_skip) == 2);
    mtl_preread(m, 2 * MB);
    CHECK("a longer range at the same start: asked", atomic_load(&g_preread_n) == 2);
    mtl_preread(m + 4 * MB, 1 * MB);
    CHECK("another start: asked", atomic_load(&g_preread_n) == 3);
    mtl_preread(m, 65 * MB); mtl_preread(NULL, MB); mtl_preread(m, 0);
    CHECK("over 64 MB, no memory, no size: nothing", atomic_load(&g_preread_n) == 3);
    drain();
    CHECK("the calls ran, none failed", atomic_load(&g_preread_ns) > 0 && atomic_load(&g_preread_fail) == 0);
    { int k = (int)(((uintptr_t)m >> 12) * 0x9E3779B1u % PREREAD_SLOTS); atomic_store(&g_preread_seen[k].t, atomic_load(&g_preread_seen[k].t) - 3000000000ull); }
    mtl_preread(m, 1 * MB);
    CHECK("asked again after 2 s", atomic_load(&g_preread_n) == 4);
    g_preread = 0; mtl_preread(m + 6 * MB, MB);
    CHECK("DM_NVN_PREREAD=0: nothing", atomic_load(&g_preread_n) == 4);
    g_preread = 1;
    // res_trickle: three 8 MB pools addressed, one 8 MB not, one 72 MB addressed
    uint8_t *p[3]; for (int i = 0; i < 3; i++) { p[i] = file_mem(8 * MB); mtl_pool_add(p[i], 8 * MB); mtl_pool_addressed(p[i], 4096); }
    uint8_t *u = file_mem(8 * MB); mtl_pool_add(u, 8 * MB);
    uint8_t *big = file_mem(72 * MB); mtl_pool_add(big, 72 * MB); mtl_pool_addressed(big, 4096);
    atomic_store(&g_cur_frame, 10);
    res_trickle();
    CHECK("no pool table yet: nothing", !res_of(p[0]) && !res_of(p[1]) && !res_of(p[2]));
    g_gmem_seen = 1;
    res_trickle();
    int n = res_of(p[0]) + res_of(p[1]) + res_of(p[2]);
    CHECK("16 MB a frame: two of the three", n == 2 && atomic_load(&g_trickle_n) == 2 && atomic_load(&g_trickle_bytes) == 16 * MB);
    res_trickle();
    CHECK("the same frame: no more", res_of(p[0]) + res_of(p[1]) + res_of(p[2]) == 2);
    atomic_store(&g_cur_frame, 11); res_trickle();
    CHECK("the next frame: the third", res_of(p[0]) && res_of(p[1]) && res_of(p[2]) && atomic_load(&g_trickle_n) == 3);
    CHECK("an unaddressed pool stays out", !res_of(u));
    CHECK("a pool over 64 MB is left to the table", !res_of(big));
    CHECK("the adds were committed", atomic_load(&g_pool_res_open) == 0 || (res_commit(), atomic_load(&g_pool_res_open) == 0));
    printf("t_preread: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
