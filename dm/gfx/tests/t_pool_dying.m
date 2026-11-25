// A finalized memory pool is taken out in replay order (nvn_mtl.m mtl_pool_retire / mtl_pool_reap; ported from S2Arm d9af7859, Apache-2.0, whose t_nvn_pool_defer cases these are,
// on this tree's pool table, chunks and index). Commands recorded before the game's Finalize and replayed after it still name the pool's addresses: it stays findable until the
// replay's oldest submission not done is past the first one submitted after the Finalize. Expected by hand:
// - finalized after submission 5: found while the oldest submission not done is 5 or 6, gone once it is 7, and its buffer's GPU address no longer given out;
// - a new pool over the same memory takes the finalized one out at once and resolves to its own buffer, one entry;
// - a large pool in chunks (BIG_MIN) keeps answering through its chunks and makes new ones until it goes, then all its entries go, and another pool's lookups stay right (the index);
// - a sparse run replaced over a finalized pool's memory (mtl_pool_replace) takes it out too; mtl_pool_del still takes a pool out at once.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <sys/mman.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static id<MTLBuffer> find(const void *a, uint64_t n) { void *mb = NULL; uint64_t mo = 0; return mtl_addr((uint64_t)(uintptr_t)a, n, &mb, &mo) ? (__bridge id<MTLBuffer>)mb : nil; }
static int entries(const void *key) { int n = 0; pthread_mutex_lock(&g_mu); for (int i = 0; i < g_npool; i++) n += g_pools[i].key == key; pthread_mutex_unlock(&g_mu); return n; }

int main(void) { @autoreleasepool {
    mtl_init();
    const uint64_t MB = 1ull << 20;
    uint8_t *mem = mmap(NULL, 64 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    mtl_pool_add(mem, 16 * MB);
    id<MTLBuffer> b0 = find(mem + MB, 64);
    CHECK("the pool resolves", b0 != nil && entries(mem) == 1);
    mtl_pool_retire(mem, 16 * MB, 5);   // finalized when the queue had taken 5 submissions
    mtl_pool_reap(5); CHECK("the replay at a submission from before the Finalize: still found", find(mem + MB, 64) == b0);
    mtl_pool_reap(6); CHECK("at the first one after it: still found", find(mem + MB, 64) == b0 && entries(mem) == 1);
    mtl_pool_reap(7); CHECK("past it: gone", !find(mem + MB, 64) && entries(mem) == 0 && g_ndying == 0);
    mtl_sub_begin(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    // Finalized, then a new pool over the same memory: the old one goes at once
    mtl_pool_add(mem, 16 * MB); id<MTLBuffer> b1 = find(mem + MB, 64);
    mtl_pool_retire(mem, 16 * MB, 9);
    mtl_pool_add(mem, 32 * MB); id<MTLBuffer> b2 = find(mem + MB, 64);
    CHECK("a new pool over a finalized one's memory: its own buffer, one entry", b2 && b2 != b1 && b2.length >= 32 * MB && entries(mem) == 1 && g_ndying == 0);
    mtl_pool_del(mem); CHECK("mtl_pool_del: at once", !find(mem + MB, 64) && entries(mem) == 0);
    // A large pool in chunks, with another pool beside it in the index
    uint8_t *big = mmap(NULL, 640 * MB, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (big == MAP_FAILED) abort();
    mtl_pool_add(mem, 4 * MB); id<MTLBuffer> other = find(mem + 100, 64);
    mtl_pool_add(big, 640 * MB);
    id<MTLBuffer> c0 = find(big + 10 * MB, 4096);
    CHECK("a large pool: one chunk", c0 && g_nbig == 1 && entries(big) == 1);
    mtl_pool_retire(big, 640 * MB, 20);
    mtl_pool_reap(21);
    id<MTLBuffer> c1 = find(big + 300 * MB, 4096);
    CHECK("finalized, not yet past: its chunks answer and a new stride gets one", find(big + 10 * MB, 4096) == c0 && c1 && c1 != c0 && entries(big) == 2 && g_nbig == 1);
    mtl_pool_reap(22);
    CHECK("past it: every chunk and the large pool go", !find(big + 10 * MB, 4096) && !find(big + 300 * MB, 4096) && entries(big) == 0 && g_nbig == 0);
    CHECK("the other pool still resolves through the index", find(mem + 200, 64) == other && entries(mem) == 1);
    mtl_pool_del(mem);
    // A sparse run's pool replaced over a finalized pool's memory
    mtl_pool_add(mem, 8 * MB); mtl_pool_retire(mem, 8 * MB, 30);
    const void *add[1] = {mem + 4 * MB}; uint64_t asz[1] = {MB};
    mtl_pool_replace(NULL, 0, add, asz, 1);
    CHECK("a replacement over it takes the finalized pool out", entries(mem) == 0 && entries(mem + 4 * MB) == 1 && g_ndying == 0 && !find(mem + 100, 64) && find(mem + 4 * MB + 8, 64));
    mtl_pool_del(mem + 4 * MB);
    mtl_sub_begin(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); mtl_drain();
    munmap(big, 640 * MB); munmap(mem, 64 * MB);
    printf("t_pool_dying: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
