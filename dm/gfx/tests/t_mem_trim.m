// The memory trim (nvn_mtl.m mtl_trim_at, hle_nvn.c dm_gfx_trim, dm_gfx_pressure, dm_gfx_suspend): with what sits idle and large made first (two render-target heaps waiting for reuse,
// upload slot blocks above 4 MB with their overflow, three same-pass feedback snapshots of three sizes), dm_gfx_trim between submissions with the GPU drained releases every one of
// them: they leave the residency set, GPU allocated falls by at least their bytes, the line counts them, and the present thread is asked to release effects that are off. Memory
// pressure (mtl_pressure) only asks: the trim runs at the next submission's start; DM_MEMORY_TRIM=0 logs it and asks nothing. Going to the background (dm_gfx_suspend(1)) trims
// after its drain; DM_BG_TRIM=0 does not. Idle snapshots (fix 13): FB_SNAP_IDLE submissions after their last use the snapshots go; DM_NVN_FB_SNAP_IDLE=0 keeps them
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)
enum { MB = 1 << 20 };
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
static unsigned long queued(void) { pthread_mutex_lock(&g_deferred_mu); unsigned long n = g_deferred.count; pthread_mutex_unlock(&g_deferred_mu); return n; }
static void settle(void) {   // the deferred releases whose fence has passed run (here, or in the drain defer_kick started on a utility queue), and the residency set lets go of them at its commit
    for (int i = 0; i < 400 && queued(); i++) { @autoreleasepool { defer_drain(); res_commit(); } usleep(5000); }
    for (int i = 0; i < 10; i++) { usleep(10000); @autoreleasepool { defer_drain(); res_commit(); } }   // a kick's drain takes its entries off the queue before it removes them from the set
}
static int snaps(void) { int n = 0; for (int i = 0; i < 8; i++) n += g_fbc[i].snap != nil; return n; }
static size_t big_slots(void) { size_t b = 0; for (unsigned i = 0; i < 3; i++) { if (g_up_slot_blk[i].length > UP_SLOT_BLOCK) b += g_up_slot_blk[i].length; b += g_up_slot_over[i].length; } return b; }
// What a game leaves idle: n_heaps 32 MB heaps waiting for reuse (an NvRecycledHeap gives its heap to the list when it goes, as rh_texture's owner does when the target's texture is
// freed), a submission of upload batches that grows the slots' blocks to 24 MB and more with an overflow block, and snapshots of three attachment sizes. held: the objects, weak
static uint64_t make_idle(__weak id held[], int *nheld) {
    uint64_t bytes = 0; *nheld = 0;
    @autoreleasepool {
        for (int i = 0; i < 2; i++) {
            MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypePlacement; hd.size = 32 * MB; hd.storageMode = MTLStorageModePrivate;
            id<MTLHeap> h = [g_dev newHeapWithDescriptor:hd]; res_add(h); bytes += h.size; held[(*nheld)++] = h;
            NvRecycledHeap *o = [NvRecycledHeap new]; o->heap = h; o = nil;   // waits now (dealloc)
        }
        id<MTLBuffer> src = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModeShared];
        if (!src) { fprintf(stderr, "FAIL: no 4 KB shared buffer for the upload batches\n"); exit(1); }
        res_add(src);
        mtl_sub_begin();
        for (int b = 0; b < 3; b++) {   // one batch per slot: 2 x 24 MB, past the 32 MB block, so each slot has a block above 4 MB and an overflow block
            up_begin();
            for (int k = 0; k < 2; k++) { size_t off; id<MTLBuffer> blk = up_alloc(24 * MB, &off); enc_b_copy_buffer(g_up_ce, src, 0, blk, off, 256); }
            up_flush();
        }
        int fresh = 0; const NSUInteger side[3] = {1024, 512, 256};
        for (int i = 0; i < 3; i++) { fb_cache_t *e = fb_snap(91000 + (uint64_t)i, 0, 0, MTLPixelFormatRGBA16Float, side[i], side[i], 1, &fresh); if (e) { bytes += e->snap.allocatedSize; held[(*nheld)++] = e->snap; } }
        CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission with the upload batches completes");
        mtl_drain();
        for (unsigned i = 0; i < 3; i++) { if (g_up_slot_blk[i].length > UP_SLOT_BLOCK) held[(*nheld)++] = g_up_slot_blk[i]; if (g_up_slot_over[i]) held[(*nheld)++] = g_up_slot_over[i]; }
        bytes += big_slots();
        res_remove(src);
    }
    settle();
    return bytes;
}
static int held_resident(__weak id held[], int n) { int r = 0; @autoreleasepool { for (int i = 0; i < n; i++) { id o = held[i]; r += o && resident(o); } } return r; }
static int held_alive(__weak id held[], int n) { int r = 0; @autoreleasepool { for (int i = 0; i < n; i++) { id o = held[i]; r += o != nil; } } return r; }
int main(void) { @autoreleasepool {
    mtl_init();
    int trim_on = !getenv("DM_MEMORY_TRIM") || atoi(getenv("DM_MEMORY_TRIM")), bg_on = !getenv("DM_BG_TRIM") || atoi(getenv("DM_BG_TRIM")), fb_idle = fb_snap_idle_on();
    __weak id held[16]; int nheld = 0;
    // 1. dm_gfx_trim at once
    uint64_t want = make_idle(held, &nheld);
    CHECK(waiting() == 2 && snaps() == 3 && big_slots() >= 3 * 24 * MB, "idle state made: 2 heaps waiting, 3 snapshots, 3 slots above 4 MB");
    CHECK(held_resident(held, nheld) == nheld, "all of it resident");
    uint64_t gpu0 = g_dev.currentAllocatedSize, n0 = atomic_load(&g_trim_n);
    atomic_store(&g_fx_trim_req, 0);
    uint64_t got = dm_gfx_trim(4);
    settle();
    uint64_t gpu1 = g_dev.currentAllocatedSize;
    printf("dm_gfx_trim: %llu MB released of %llu MB made idle; GPU allocated %llu -> %llu MB; %d of %d objects still resident, %d alive\n", (unsigned long long)(got / MB), (unsigned long long)(want / MB),
           (unsigned long long)(gpu0 / MB), (unsigned long long)(gpu1 / MB), held_resident(held, nheld), nheld, held_alive(held, nheld));
    CHECK(got >= want, "dm_gfx_trim: returns at least the bytes made idle");
    CHECK(waiting() == 0, "dm_gfx_trim: no render-target heap waits");
    CHECK(big_slots() == 0, "dm_gfx_trim: no slot block above 4 MB, no overflow block");
    CHECK(snaps() == 0, "dm_gfx_trim: no feedback snapshot kept");
    CHECK(held_resident(held, nheld) == 0, "dm_gfx_trim: every one left the residency set");
    CHECK(held_alive(held, nheld) == 0, "dm_gfx_trim: and was freed");
    CHECK((int64_t)gpu0 - (int64_t)gpu1 >= (int64_t)want - 4 * MB, "dm_gfx_trim: GPU allocated fell by the bytes made idle");
    CHECK(atomic_load(&g_trim_n) == n0 + 1, "dm_gfx_trim: counted for the memory line");
    CHECK(atomic_load(&g_fx_trim_req) == 1, "dm_gfx_trim: the present thread is asked to release effects that are off");
    // 2. Memory pressure asks; the next submission's start trims
    nheld = 0; want = make_idle(held, &nheld);
    n0 = atomic_load(&g_trim_n);
    int asked = mtl_pressure(1);
    CHECK(asked == trim_on && atomic_load(&g_trim_req) == trim_on, trim_on ? "pressure: a trim is asked" : "pressure with DM_MEMORY_TRIM=0: only logged");
    CHECK(waiting() == 2 && atomic_load(&g_trim_n) == n0, "pressure: nothing released before a submission starts");
    mtl_sub_begin(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the next submission completes"); mtl_drain(); settle();
    CHECK(atomic_load(&g_trim_req) == 0, "pressure: the request is taken");
    CHECK(atomic_load(&g_trim_n) == n0 + (uint64_t)trim_on, trim_on ? "pressure: the submission's start trimmed" : "DM_MEMORY_TRIM=0: no trim");
    CHECK(waiting() == (trim_on ? 0u : 2u) && held_resident(held, nheld) == (trim_on ? 0 : nheld), trim_on ? "pressure: heaps, blocks and snapshots left the residency set" : "DM_MEMORY_TRIM=0: all kept");
    if (!trim_on) { dm_gfx_trim(4); settle(); }
    // 3. Going to the background
    nheld = 0; want = make_idle(held, &nheld); n0 = atomic_load(&g_trim_n);
    dm_gfx_suspend(1); settle();
    CHECK(atomic_load(&g_trim_n) == n0 + (uint64_t)bg_on, bg_on ? "background: dm_gfx_suspend trims after its drain" : "DM_BG_TRIM=0: going to the background trims nothing");
    CHECK(held_resident(held, nheld) == (bg_on ? 0 : nheld), bg_on ? "background: all of it left the residency set" : "DM_BG_TRIM=0: all kept");
    dm_gfx_suspend(0);
    dm_gfx_trim(4); settle();
    // 4. Idle snapshots (fix 13) at a submission's start, FB_SNAP_IDLE submissions after their last use
    @autoreleasepool {
        mtl_sub_begin(); int fresh = 0; __weak id s0 = nil;
        fb_cache_t *e = fb_snap(92000, 0, 0, MTLPixelFormatRGBA16Float, 640, 360, 1, &fresh); s0 = e ? e->snap : nil;
        fb_snap(92001, 0, 0, MTLPixelFormatRGBA16Float, 320, 180, 1, &fresh); fb_snap(92002, 0, 0, MTLPixelFormatRGBA16Float, 160, 90, 1, &fresh);
        mtl_wait(mtl_sub_commit(), 5000000000ull);
        uint64_t f0 = atomic_load(&g_fbc_freed);
        for (int i = 0; i < FB_SNAP_IDLE - 1; i++) { @autoreleasepool { mtl_sub_begin(); mtl_wait(mtl_sub_commit(), 5000000000ull); } }
        CHECK(snaps() == 3, "idle snapshots: kept before FB_SNAP_IDLE submissions");
        for (int i = 0; i < 2; i++) { @autoreleasepool { mtl_sub_begin(); mtl_wait(mtl_sub_commit(), 5000000000ull); } }
        mtl_drain(); settle();
        printf("idle snapshots %s: %d kept after %d idle submissions, %llu released\n", fb_idle ? "on" : "off (DM_NVN_FB_SNAP_IDLE=0)", snaps(), FB_SNAP_IDLE + 1, (unsigned long long)(atomic_load(&g_fbc_freed) - f0));
        CHECK(snaps() == (fb_idle ? 0 : 3), fb_idle ? "idle snapshots: all three go" : "DM_NVN_FB_SNAP_IDLE=0: all three kept");
        CHECK(atomic_load(&g_fbc_freed) - f0 == (fb_idle ? 3u : 0u), "idle snapshots: counted");
        id s = s0; CHECK(fb_idle ? !s : s && resident(s), fb_idle ? "idle snapshots: freed" : "DM_NVN_FB_SNAP_IDLE=0: still resident");
        s = nil;
    }
    printf("t_mem_trim: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
