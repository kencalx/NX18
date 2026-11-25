// The raw pool table within a submission (nvn_mtl.m gmem_map, DM_NVN_GMEM_KEEP): a draw takes the table built earlier in the submission while pools have only come since, the commit
// points the words at a table of the pools as they are then (gmem_commit_patch), and a pool taken out, or a new submission, builds it again at the next draw. Ocarina of Time makes up to
// 91 memory pools a frame on other threads while the replay encodes (MacNativeGames b964bd4e). `t_gmem_keep --off` runs under DM_NVN_GMEM_KEEP=0: every change builds it again.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static int table_has(uint64_t guest) {   // the current table has an entry that starts at the guest address
    const uint8_t *t = g_gmem_buf.contents;
    for (unsigned k = 1, n = (unsigned)(g_gmem_buf.length / DMSH_GMEM_MAP_ENTRY); k < n; k++) { uint64_t lo; memcpy(&lo, t + (size_t)k * DMSH_GMEM_MAP_ENTRY, sizeof lo); if (lo == guest) return 1; }
    return 0;
}
static uint64_t builds(void) { uint64_t b, k; mtl_gmem_builds(&b, &k); return b; }
static uint64_t kept(void) { uint64_t b, k; mtl_gmem_builds(&b, &k); return k; }
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc == 2 && !strcmp(argv[1], "--off");
    if (off) setenv("DM_NVN_GMEM_KEEP", "0", 1); else unsetenv("DM_NVN_GMEM_KEEP");
    mtl_init();
    const uint64_t MB = 1ull << 20;
    uint8_t *mem = mmap(NULL, 64 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    uint64_t a = (uint64_t)(uintptr_t)mem;
    mtl_pool_add(mem, 4 * MB); mtl_pool_addressed(mem, 4 * MB);
    mtl_sub_begin();
    uint64_t t0 = gmem_map_gpu(), b0 = builds(), k0 = kept();
    CHECK("the first draw builds the table", t0 && b0 >= 1 && table_has(a));
    // a pool made on another thread while the submission is encoded: the next draw keeps the table, its word is noted
    mtl_pool_add(mem + 8 * MB, 4 * MB); mtl_pool_addressed(mem + 8 * MB, 4 * MB);
    uint64_t t1 = gmem_map_gpu(), w = t1;
    if (off) CHECK("off: a pool made builds the table again", t1 != t0 && builds() == b0 + 1 && table_has(a + 8 * MB));
    else CHECK("a pool made keeps the submission's table at a draw", t1 == t0 && builds() == b0 && kept() == k0 + 1 && !table_has(a + 8 * MB));
    gmem_slot_note(&w, NULL);
    gmem_commit_patch();   // a commit, whole or segment: the words follow the pools
    CHECK("the commit points the word at a table that holds the new pool", w == g_gmem_buf.gpuAddress && table_has(a + 8 * MB) && table_has(a));
    uint64_t t2 = g_gmem_buf.gpuAddress, b2 = builds();
    if (off) CHECK("off: the commit had nothing left to build", t2 == t1);
    else CHECK("the commit built it once", t2 != t0 && b2 == b0 + 1);
    // more pools in the same submission, then one taken out: a table that may name a going buffer is not kept
    mtl_pool_add(mem + 16 * MB, 4 * MB); mtl_pool_addressed(mem + 16 * MB, 4 * MB);
    uint64_t t3 = gmem_map_gpu();
    if (!off) CHECK("kept again after the commit, in the same submission", t3 == t2 && builds() == b2);
    mtl_pool_del(mem + 8 * MB);
    uint64_t t4 = gmem_map_gpu();
    CHECK("a pool taken out builds the table again at the next draw", t4 != t3 && !table_has(a + 8 * MB) && table_has(a + 16 * MB));
    uint64_t b4 = builds();
    CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    // the next submission does not take a table an earlier one built behind the pools
    mtl_sub_begin();
    mtl_pool_add(mem + 24 * MB, 4 * MB); mtl_pool_addressed(mem + 24 * MB, 4 * MB);
    uint64_t t5 = gmem_map_gpu();
    CHECK("a new submission builds it at its first draw after a change", t5 != t4 && builds() == b4 + 1 && table_has(a + 24 * MB));
    uint64_t t6 = gmem_map_gpu();
    CHECK("an unchanged pool set keeps it", t6 == t5 && builds() == b4 + 1);
    CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    CHECK("GPU has no submission error", !mtl_last_commit_error());
    printf("t_gmem_keep%s: %d checks, %d failed\n", off ? " --off" : "", checks, failed); return failed != 0;
} }
