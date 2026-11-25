// The address → pool index (nvn_mtl.m g_pidx) follows each pool registered or removed in place (pidx_added / pidx_removing) instead of being re-sorted whole at the next lookup
// (ported from the S2Arm project's 8d2bafd0). 600 pools registered in a shuffled order over 1,024 64 KB slots, then 2,000 steps that remove a slot's pool or register one; a large
// pool's chunks (BIG_MIN) made and lengthened among them. What each lookup should find comes from the test's own slot table, not from the index: the index stays valid through every
// step, an occupied slot finds the pool that starts there, an empty one finds none, and the index holds each entry once in start order.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { SLOTS = 1024, SLOT = 64 << 10 };
static uint8_t *base; static uint8_t used[SLOTS];
static uint32_t rnd(void) { static uint32_t x = 12345; x = x * 1664525u + 1013904223u; return x >> 8; }
static int index_sound(void) {   // caller holds g_mu: every entry once, in start order
    static uint8_t seen[1 << 14]; if (g_npool > (int)sizeof seen) return 0;
    memset(seen, 0, (size_t)g_npool);
    for (int i = 0; i < g_npool; i++) {
        int k = g_pidx[i]; if (k < 0 || k >= g_npool || seen[k]++) return 0;
        if (i && g_pools[g_pidx[i - 1]].lo > g_pools[k].lo) return 0;
    }
    return 1;
}
static int verify(int *lookups) {   // the errors in one sweep of every slot
    int bad = 0;
    pthread_mutex_lock(&g_mu);
    if (!g_pidx_ok || !index_sound()) bad++;
    for (int s = 0; s < SLOTS; s++) {
        uint64_t a = (uint64_t)(uintptr_t)(base + (size_t)s * SLOT);
        g_plast = -1;   // through the index, not the last hit
        int k = pool_held(a + 123, 1); (*lookups)++;
        if (used[s]) { if (k < 0 || g_pools[k].lo != a) bad++; } else if (k >= 0) bad++;
    }
    pthread_mutex_unlock(&g_mu);
    return bad;
}
static int index_ok(void) { pthread_mutex_lock(&g_mu); int ok = g_pidx_ok && index_sound(); pthread_mutex_unlock(&g_mu); return ok; }
int main(void) { @autoreleasepool {
    mtl_init();
    base = mmap(NULL, (size_t)SLOTS * SLOT, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); if (base == MAP_FAILED) abort();
    int lookups = 0, bad = 0;
    for (int i = 0; i < 600; ) { int s = (int)(rnd() % SLOTS); if (used[s]) continue; mtl_pool_add(base + (size_t)s * SLOT, SLOT); used[s] = 1; i++; }
    pthread_mutex_lock(&g_mu); g_plast = -1; (void)pool_held((uint64_t)(uintptr_t)base, 1); int ok0 = g_pidx_ok; pthread_mutex_unlock(&g_mu);
    CHECK("600 pools in a shuffled order: the first lookup sorts the index, and every slot is answered right", ok0 && verify(&lookups) == 0);
    int adds = 0, dels = 0, invalid = 0;
    for (int step = 0; step < 2000; step++) {
        int s = (int)(rnd() % SLOTS);
        if (used[s]) { mtl_pool_del(base + (size_t)s * SLOT); used[s] = 0; dels++; } else { mtl_pool_add(base + (size_t)s * SLOT, SLOT); used[s] = 1; adds++; }
        pthread_mutex_lock(&g_mu); invalid += !g_pidx_ok; pthread_mutex_unlock(&g_mu);
        if (step < 20 || step % 50 == 49) bad += verify(&lookups);
    }
    CHECK("both registrations and removals were made", adds > 600 && dels > 600);
    CHECK("the index stays valid after every registration and removal (no full re-sort)", invalid == 0);
    CHECK("every sampled lookup and the index order are right", bad == 0);
    if (failed) fprintf(stderr, "  %d lookups, %d wrong, index invalid %d times\n", lookups, bad, invalid);
    for (int s = 0; s < SLOTS; s++) if (!used[s]) { mtl_pool_add(base + (size_t)s * SLOT, SLOT); used[s] = 1; }
    CHECK("all 1,024 slots taken (the index grows in place): still valid and right", verify(&lookups) == 0);
    for (int s = 0; s < SLOTS; s += 2) { mtl_pool_del(base + (size_t)s * SLOT); used[s] = 0; }
    CHECK("every other slot's pool removed: still valid and right", verify(&lookups) == 0);
    // A large pool's chunks are g_pools entries too: one made, then lengthened in place (big_lookup), then the pool removed with all its entries
    const uint64_t MB = 1ull << 20, big_len = BIG_MIN;
    uint8_t *big = mmap(NULL, big_len, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANON, -1, 0); if (big == MAP_FAILED) abort();
    uint64_t bb = (uint64_t)(uintptr_t)big; void *mb = NULL; uint64_t mo = 0, gpu = 0;
    mtl_pool_add(big, big_len);
    CHECK("a large pool registered: the index stays valid", index_ok());
    int n0 = g_npool;
    CHECK("a chunk made", mtl_gpu_addr(bb + 100, 4096, &mb, &mo, &gpu) && g_npool == n0 + 1);
    CHECK("the chunk made: the index stays valid and in order", index_ok());
    CHECK("the chunk lengthened in place", mtl_gpu_addr(bb + 100, 100 * MB, &mb, &mo, &gpu) && g_npool == n0 + 1);
    CHECK("the chunk lengthened: the index stays valid and in order", index_ok());
    CHECK("the small pools are still answered right", verify(&lookups) == 0);
    mtl_pool_del(big);
    CHECK("the large pool removed: its entries left the index, which stays valid", g_npool == n0 && index_ok() && verify(&lookups) == 0);
    // An index that does not match falls back to the full sort: a corrupted entry is found out by the removal, which invalidates it
    pthread_mutex_lock(&g_mu); g_plast = -1; (void)pool_held(bb, 1); int victim = -1; for (int s = 1; s < SLOTS; s += 2) if (used[s]) { victim = s; break; }
    int p = -1; for (int i = 0; i < g_npool; i++) if (g_pools[g_pidx[i]].lo == (uintptr_t)(base + (size_t)victim * SLOT)) p = i;
    int other = g_pidx[p ? p - 1 : p + 1]; g_pidx[p] = other; pthread_mutex_unlock(&g_mu);   // the victim's entry now names another pool
    mtl_pool_del(base + (size_t)victim * SLOT); used[victim] = 0;
    pthread_mutex_lock(&g_mu); int fell_back = !g_pidx_ok; pthread_mutex_unlock(&g_mu);
    CHECK("an index that does not match is invalidated, not trusted", fell_back);
    pthread_mutex_lock(&g_mu); g_plast = -1; (void)pool_held((uint64_t)(uintptr_t)base, 1); int resorted = g_pidx_ok; pthread_mutex_unlock(&g_mu);
    CHECK("the next lookup re-sorts it whole and answers right", resorted && verify(&lookups) == 0);
    mtl_drain();
    printf("t_pool_index: %d checks, %d failed (%d lookups)\n", checks, failed, lookups);
    return failed != 0;
} }
