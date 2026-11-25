// The writes queued in a submission over a range (pend_since) are looked up in at most PEND_SINCE_MAX steps (ported from S2Arm 8cdae876, Apache-2.0, whose t_nvn_ubd_index ⑬ checks
// the same counts): past them the answer is -1, cannot tell, and the uniform shadow (ubp_get) is refused as for an overflowing list, where before a submission with 116,000 inline
// updates on one page walked the whole chain at every lookup. The expectations are written from the rule, not taken from the code: 100 updates on one page are all found and the
// shadow holds the newest bytes; 8,192 are all found; 8,193 and 20,000 answer -1 within 5 ms and the shadow is refused (g_ubp_why[4]); a range over more than PEND_SPAN pages
// (the whole-list scan) answers -1 past the cap too, and finds its writes below it.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static id<MTLBuffer> g_ring;
// n inline updates of 16 bytes over [P, P + 256) (slot i % 16), each with its own data in the ring (byte value i & 0xff), as mtl_sub_update queues them
static void queue(uint64_t P, int n) {
    pend_reset();
    for (int i = 0; i < n; i++) {
        uint64_t dst = P + (uint64_t)(i % 16) * 16;
        memset((uint8_t *)g_ring.contents + (size_t)i * 16, i & 0xff, 16);
        int e = pend_add(dst, 16, 1);
        if (e >= 0) { g_upd[g_nupd] = (upd_ent){dst, (size_t)i * 16, g_ring}; g_pend_upd[e] = (uint32_t)++g_nupd; }
    }
}
int main(void) { @autoreleasepool {
    mtl_init();
    size_t page = (size_t)getpagesize(); void *mem = NULL;
    if (posix_memalign(&mem, page, 16 * page)) return 1;
    memset(mem, 0, 16 * page); mtl_pool_add(mem, 16 * page);
    g_ring = [g_dev newBufferWithLength:20000 * 16 options:MTLResourceStorageModeShared];
    uint64_t P = (uint64_t)(uintptr_t)mem;
    mtl_sub_begin();

    queue(P, 100);
    CHECK(pend_since(P, P + 256, 0, g_ubp_idx) == 100, "100 updates on one page: all found");
    uint64_t gpu = 0; const uint8_t *cpu = NULL; int newest = 1;
    CHECK(ubp_get(P, P + 256, &gpu, &cpu) == 1 && cpu, "under the cap the shadow is made");
    for (int k = 0; cpu && k < 16; k++) { int last = (99 - k) / 16 * 16 + k; newest &= cpu[k * 16] == last && cpu[k * 16 + 15] == last; }   // the last i < 100 with i % 16 == k
    CHECK(newest, "the shadow holds each slot's newest update");

    queue(P, PEND_SINCE_MAX);
    CHECK(pend_since(P, P + 256, 0, g_ubp_idx) == PEND_SINCE_MAX, "8,192 updates on one page: all found");
    queue(P, PEND_SINCE_MAX + 1);
    CHECK(pend_since(P, P + 256, 0, g_ubp_idx) == -1, "8,193 updates on one page: cannot tell");
    CHECK(pend_since(P, P + 256, 2, g_ubp_idx) == PEND_SINCE_MAX - 1, "those queued since a later index are found");

    queue(P, 20000);
    uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); int nbig = pend_since(P, P + 256, 0, g_ubp_idx); uint64_t dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0;
    CHECK(nbig == -1 && dt < 5000000ull, "20,000 updates on one page: cannot tell, within 5 ms");
    uint64_t why4 = g_ubp_why[4];
    CHECK(ubp_get(P, P + 256, &gpu, &cpu) == 0 && g_ubp_why[4] == why4 + 1, "over the cap the shadow is refused");

    // A range over more than PEND_SPAN pages scans the whole list
    uint64_t wide = (uint64_t)(PEND_SPAN + 1) << 12;
    queue(P, 100);
    CHECK(pend_since(P, P + wide, 0, g_ubp_idx) == 100, "a wide range under the cap finds every write");
    queue(P, PEND_SINCE_MAX + 1);
    CHECK(pend_since(P, P + wide, 0, g_ubp_idx) == -1, "a wide range over the cap: cannot tell");

    pend_reset();
    uint64_t fence = mtl_sub_commit(); CHECK(mtl_wait(fence, 5000000000ull), "the submission completes"); mtl_drain();
    mtl_pool_del(mem); mtl_drain(); free(mem);
    printf("t_pend_since_cap: %d checks, %d failed (20,000 updates looked up in %.3f ms)\n", checks, failed, dt / 1e6);
    return failed != 0;
} }
