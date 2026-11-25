// Idle reuse-cache entries marked volatile (nvn_mtl.m cv_mark / cv_back, DM_NVN_CACHE_VOLATILE): render-target heaps waiting for reuse (rh_trim marks, rh_heap takes back),
// the upload staging pool's blocks (up_pool_trim marks, up_pool_get takes back) and same-pass feedback snapshots (fb_vol_sweep marks, fb_snap_shape takes back). For each: an entry
// idle long enough goes volatile and stays resident; one taken again is non-volatile before it is used; one the system emptied (forced here with setPurgeableState:Empty, and
// through the test hook g_cv_test_empty, as the kernel cannot be made to purge on demand) is dropped, out of the residency set, and a new one made, which reads back what was
// written into it. In-flight safety: a snapshot whose submission the GPU has not completed, or one taken in a submission still open, is never marked; a render-target heap whose
// texture a held submission still uses never reaches the list; a staging block of a held batch never reaches the pool. The memory line's counts return to 0 after a trim.
// DM_NVN_CACHE_VOLATILE=0 (--off): nothing is marked.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
#define MB (1u << 20)
static MTLPurgeableState st(id o) { return [(id<MTLHeap>)o setPurgeableState:MTLPurgeableStateKeepCurrent]; }
static int resident(id o) { res_mu_lock(); int r = [g_res_objects containsObject:o]; res_mu_unlock(); return r; }
static unsigned long queued(void) { pthread_mutex_lock(&g_deferred_mu); unsigned long n = g_deferred.count; pthread_mutex_unlock(&g_deferred_mu); return n; }
static void settle(void) {
    for (int i = 0; i < 400 && queued(); i++) { @autoreleasepool { defer_drain(); res_commit(); } usleep(5000); }
    for (int i = 0; i < 10; i++) { usleep(10000); @autoreleasepool { defer_drain(); res_commit(); } }
}
// Write a pattern into t's level 0 / slice 0 through a buffer, read it back, and compare: the memory a new entry was made with holds what is written into it
static int round_trip(id<MTLTexture> t, uint8_t seed) { @autoreleasepool {
    NSUInteger bpp = 4, row = t.width * bpp, n = row * t.height;
    id<MTLBuffer> in = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared], out = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    for (NSUInteger i = 0; i < n; i++) ((uint8_t *)in.contents)[i] = (uint8_t)(i * 31 + seed);
    memset(out.contents, 0, n);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> be = t4_copy(cb); t4_use(cb, in); t4_use(cb, out); t4_use(cb, t);   // a Metal 4 command buffer of the host's (t_mtl4.h)
    [be copyFromBuffer:in sourceOffset:0 sourceBytesPerRow:row sourceBytesPerImage:n sourceSize:MTLSizeMake(t.width, t.height, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    t4_barrier(be);   // the read-back reads what the upload wrote
    [be copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(t.width, t.height, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:row destinationBytesPerImage:n];
    t4_end(cb, be);
    return t4_wait(cb) == MTLCommandBufferStatusCompleted && !memcmp(in.contents, out.contents, n);
} }
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
static int waits(id<MTLHeap> h) { int r = 0; os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; i < g_rh_n; i++) r |= g_rh[i].heap == (__bridge void *)h; os_unfair_lock_unlock(&g_rh_lk); return r; }
static void rh_age(uint64_t ns) { os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; i < g_rh_n; i++) g_rh[i].t -= ns; os_unfair_lock_unlock(&g_rh_lk); }
static MTLTextureDescriptor *rt_desc(NSUInteger side) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:side height:side mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; return d;
}
static id<MTLHeap> heap_of(id<MTLTexture> t) { NvRecycledHeap *o = objc_getAssociatedObject(t, &g_rh_owner_key); return o ? o->heap : nil; }
// A heap waiting for reuse, as rh_texture's owner gives it when its texture is freed
static id<MTLHeap> wait_heap(uint64_t size) {
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.type = MTLHeapTypePlacement; hd.size = size; hd.storageMode = MTLStorageModePrivate;
    id<MTLHeap> h = [g_dev newHeapWithDescriptor:hd]; res_add(h);
    @autoreleasepool { NvRecycledHeap *o = [NvRecycledHeap new]; o->heap = h; o = nil; }
    return h;
}
// ---- the staging pool (as t_stage_pool) ----
enum { EDGE = 256, ROUNDS = 16, PER = 4, BYTES = ROUNDS * PER * 2 * EDGE };
static id<MTLBuffer> g_in, g_out; static unsigned g_round;
static int uploads_done(void) { for (int t = 0; t < 5000; t++) { if (!atomic_load(&g_up_pending)) return 1; usleep(1000); } return 0; }
static void pool_age(uint64_t ns) { os_unfair_lock_lock(&g_up_pool_lk); g_up_pool_used_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - ns; os_unfair_lock_unlock(&g_up_pool_lk); }
static uint64_t pool_bytes(void) { os_unfair_lock_lock(&g_up_pool_lk); uint64_t b = g_up_pool_bytes; os_unfair_lock_unlock(&g_up_pool_lk); return b; }
static unsigned burst(__strong id<MTLBuffer> temps[2]) {   // one batch of four 24 MB allocations, the last two in temporary blocks; each one's edge bytes go through it and back
    unsigned r = g_round++ % ROUNDS; int nt = 0; id<MTLBuffer> prev = nil;
    up_begin(); unsigned s = g_up_cur_slot;
    for (unsigned i = 0; i < PER; i++) {
        size_t off, n = 24 * MB; id<MTLBuffer> b = up_alloc(n, &off);
        if (b != g_up_slot_blk[s] && b != g_up_slot_over[s] && b != prev && nt < 2) temps[nt++] = b;
        prev = b;
        size_t at = (r * PER + i) * 2 * EDGE;
        enc_b_copy_buffer(g_up_ce, g_in, at, b, off, EDGE);
        enc_b_copy_buffer(g_up_ce, g_in, at + EDGE, b, off + n - EDGE, EDGE);
        [g_up_ce barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
        enc_b_copy_buffer(g_up_ce, b, off, g_out, at, EDGE);
        enc_b_copy_buffer(g_up_ce, b, off + n - EDGE, g_out, at + EDGE, EDGE);
    }
    up_flush();
    return r;
}
static int round_ok(unsigned r) { size_t at = r * PER * 2 * EDGE; return !memcmp((char *)g_in.contents + at, (char *)g_out.contents + at, PER * 2 * EDGE); }
static void up_settle(void) { @autoreleasepool { CHECK("uploads complete", uploads_done()); res_commit(); } }
static void sub(void) { @autoreleasepool { mtl_sub_begin(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); res_commit(); } }
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "--off");
    mtl_init();
    CHECK("the switch reads as the run asks", cv_on() == !off);
    // ---------- 1. Render-target heaps waiting for reuse ----------
    @autoreleasepool {
        id<MTLHeap> h = wait_heap([g_dev heapTextureSizeAndAlignWithDescriptor:rt_desc(1024)].size * 9 / 8);   // as rh_heap makes one for a 1024x1024 target
        CHECK("the heap waits", waits(h) && waiting() == 1);
        rh_trim();
        CHECK("a heap just put in the list is not marked", st(h) == MTLPurgeableStateNonVolatile && atomic_load(&g_cv_n) == 0);
        rh_age(CV_IDLE_NS + 1000000);
        rh_trim();
        if (off) CHECK("off: a heap idle past CV_IDLE_NS stays non-volatile", st(h) == MTLPurgeableStateNonVolatile && atomic_load(&g_cv_n) == 0);
        else {
            CHECK("a heap idle past CV_IDLE_NS is volatile, still waiting and resident", st(h) == MTLPurgeableStateVolatile && waits(h) && resident(h));
            CHECK("counted volatile", atomic_load(&g_cv_n) == 1 && atomic_load(&g_cv_bytes) == h.size);
        }
        // taken back for a texture that fits: the same heap, non-volatile, and its texture holds what is written into it
        uint64_t reused0 = g_rh_reused;
        id<MTLTexture> t = rh_place(rt_desc(1024));
        CHECK("a texture is placed", t != nil);
        CHECK("in the waiting heap, reused", heap_of(t) == h && g_rh_reused == reused0 + 1 && !waits(h));
        CHECK("non-volatile again before use", st(h) == MTLPurgeableStateNonVolatile && atomic_load(&g_cv_n) == 0 && atomic_load(&g_cv_bytes) == 0);
        CHECK("its texture reads back what was written", round_trip(t, 1));
        t = nil;   // the heap waits again (NvRecycledHeap dealloc)
    }
    CHECK("the heap waits again after its texture went", waiting() == 1);
    if (!off) {
        // emptied by the system while it waited (forced): the next take drops it and makes a new heap
        __weak id<MTLHeap> wold; uint64_t e0 = atomic_load(&g_cv_emptied), trimmed0 = g_rh_trimmed, made0 = g_rh_made;
        @autoreleasepool {
            os_unfair_lock_lock(&g_rh_lk); id<MTLHeap> old = (__bridge id<MTLHeap>)g_rh[0].heap; os_unfair_lock_unlock(&g_rh_lk); wold = old;
            rh_age(CV_IDLE_NS + 1000000); rh_trim();
            CHECK("volatile again", st(old) == MTLPurgeableStateVolatile);
            [old setPurgeableState:MTLPurgeableStateEmpty];
            id<MTLTexture> t = rh_place(rt_desc(1024));
            CHECK("emptied: a new heap is made for the texture", t && heap_of(t) && heap_of(t) != old && g_rh_made == made0 + 1);
            CHECK("the emptied heap was dropped from the list and the residency set", !waits(old) && !resident(old) && g_rh_trimmed == trimmed0 + 1);
            CHECK("counted emptied and made again", atomic_load(&g_cv_emptied) == e0 + 1 && atomic_load(&g_cv_n) == 0);
            CHECK("the new heap is non-volatile and its texture reads back what was written", st(heap_of(t)) == MTLPurgeableStateNonVolatile && round_trip(t, 2));
            old = nil; res_commit();
            t = nil;
        }
        settle();
        @autoreleasepool { id<MTLHeap> o = wold; CHECK("the emptied heap was freed", o == nil); }
        // the test hook: the next take reports its heap emptied whatever the kernel did
        @autoreleasepool {
            CHECK("one heap waits", waiting() == 1);
            os_unfair_lock_lock(&g_rh_lk); id<MTLHeap> old = (__bridge id<MTLHeap>)g_rh[0].heap; os_unfair_lock_unlock(&g_rh_lk);
            rh_age(CV_IDLE_NS + 1000000); rh_trim();
            atomic_store(&g_cv_test_empty, 1); uint64_t e1 = atomic_load(&g_cv_emptied);
            id<MTLTexture> t = rh_place(rt_desc(1024));
            CHECK("hook: a new heap is made", t && heap_of(t) != old && !resident(old) && atomic_load(&g_cv_emptied) == e1 + 1 && atomic_load(&g_cv_test_empty) == 0);
            CHECK("hook: its texture reads back what was written", round_trip(t, 3));
            t = nil; old = nil;
        }
        settle();
    }
    // in flight: a texture a held submission uses: its heap reaches the list only after that submission's fence, so it cannot be marked before
    @autoreleasepool {
        int n0 = 0; rh_trim_all(&n0); settle();
        id<MTLSharedEvent> gate = [g_dev newSharedEvent]; [g_q4 waitForEvent:gate value:1];
        __weak id<MTLHeap> wh;
        mtl_sub_begin();
        @autoreleasepool { id<MTLTexture> t = rh_place(rt_desc(512)); res_add(t); wh = heap_of(t); defer_obj_release(t); }   // freed after this submission, as the replay retires one
        uint64_t f = mtl_sub_commit(); rec_publish();
        for (int i = 0; i < 5; i++) { @autoreleasepool { defer_drain(); } usleep(2000); }
        @autoreleasepool { id<MTLHeap> h = wh;
            CHECK("in flight: the heap of a texture a held submission uses does not wait", h && !waits(h));
            rh_age(CV_IDLE_NS + 1000000); rh_trim();
            CHECK("in flight: and is never volatile", h && st(h) == MTLPurgeableStateNonVolatile); }
        gate.signaledValue = 1;
        CHECK("the held submission completes", mtl_wait(f, 5000000000ull));
        settle();
        @autoreleasepool { id<MTLHeap> h = wh;
            CHECK("after its fence the heap waits", h && waits(h));
            rh_age(CV_IDLE_NS + 1000000); rh_trim();
            CHECK(off ? "off: not marked" : "and goes volatile once idle", h && st(h) == (off ? MTLPurgeableStateNonVolatile : MTLPurgeableStateVolatile)); }
        rh_trim_all(&n0); settle();
        CHECK("a trim of volatile heaps leaves nothing counted", atomic_load(&g_cv_n) == 0 && atomic_load(&g_cv_bytes) == 0);
    }
    // ---------- 2. The upload staging pool ----------
    g_in = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared]; g_out = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    res_add(g_in); res_add(g_out); res_commit();
    for (unsigned i = 0; i < BYTES; i++) ((uint8_t *)g_in.contents)[i] = (uint8_t)((i / EDGE) * 37 + i * 13 + 1);
    g_up_pool_cap = 128 * MB;
    @autoreleasepool {
        __strong id<MTLBuffer> t[2] = {nil};
        unsigned r = burst(t); up_settle(); CHECK("a burst's bytes went through its blocks", round_ok(r));
        CHECK("two blocks pooled", pool_bytes() == 2 * UP_BLOCK_SIZE);
        sub();
        CHECK("a pool used just now is not marked", st(t[0]) == MTLPurgeableStateNonVolatile && st(t[1]) == MTLPurgeableStateNonVolatile);
        pool_age(CV_IDLE_NS + 1000000); sub();
        if (off) CHECK("off: an idle pool stays non-volatile", st(t[0]) == MTLPurgeableStateNonVolatile && st(t[1]) == MTLPurgeableStateNonVolatile);
        else CHECK("a pool idle past CV_IDLE_NS: its blocks are volatile, still pooled and resident", st(t[0]) == MTLPurgeableStateVolatile && st(t[1]) == MTLPurgeableStateVolatile
                   && pool_bytes() == 2 * UP_BLOCK_SIZE && resident(t[0]) && resident(t[1]) && atomic_load(&g_cv_n) == 2);
        // taken back: the same blocks, non-volatile, and the bytes go through them intact
        __strong id<MTLBuffer> u[2] = {nil}; uint64_t made0 = g_up_blocks_new;
        r = burst(u);
        CHECK("the pooled blocks are taken back", ((u[0] == t[0] || u[0] == t[1]) && (u[1] == t[0] || u[1] == t[1])) && g_up_blocks_new == made0 + 2);   // the next slot's own two
        CHECK("non-volatile before the batch writes them", st(u[0]) == MTLPurgeableStateNonVolatile && st(u[1]) == MTLPurgeableStateNonVolatile && atomic_load(&g_cv_n) == 0);
        up_settle(); CHECK("their bytes went through intact", round_ok(r));
        if (!off) {
            // emptied (one by the kernel's call, one by the hook): both dropped, new blocks made, and the bytes go through those
            pool_age(CV_IDLE_NS + 1000000); sub();
            CHECK("volatile again", st(u[0]) == MTLPurgeableStateVolatile && st(u[1]) == MTLPurgeableStateVolatile);
            os_unfair_lock_lock(&g_up_pool_lk); id<MTLBuffer> first = g_up_pool.firstObject; os_unfair_lock_unlock(&g_up_pool_lk);
            [first setPurgeableState:MTLPurgeableStateEmpty];   // the kernel's call empties one; the pool hands out its last block first, which the hook reports emptied
            atomic_store(&g_cv_test_empty, 1);
            uint64_t e0 = atomic_load(&g_cv_emptied); made0 = g_up_blocks_new;
            __strong id<MTLBuffer> v[2] = {nil};
            r = burst(v);
            CHECK("emptied blocks are dropped: none of them is handed out", v[0] != u[0] && v[0] != u[1] && v[1] != u[0] && v[1] != u[1]);
            CHECK("they left the residency set", !resident(u[0]) && !resident(u[1]));
            CHECK("new blocks were made for the batch", g_up_blocks_new == made0 + 4 && atomic_load(&g_cv_emptied) == e0 + 2 && atomic_load(&g_cv_n) == 0);
            up_settle(); CHECK("the bytes went through the new blocks intact", round_ok(r));
            v[0] = v[1] = nil;
        }
        // in flight: with the queue held, a burst's blocks are not pooled, so an idle pool's marking cannot reach them
        @autoreleasepool {
            int n; up_pool_release(&n); res_commit();
            id<MTLSharedEvent> gate = [g_dev newSharedEvent]; [g_q4 waitForEvent:gate value:1];
            __strong id<MTLBuffer> w[2] = {nil}; r = burst(w); rec_publish();
            pool_age(CV_IDLE_NS + 1000000); up_pool_trim();
            CHECK("in flight: a held batch's blocks are not pooled and not volatile", pool_bytes() == 0 && st(w[0]) == MTLPurgeableStateNonVolatile && st(w[1]) == MTLPurgeableStateNonVolatile);
            gate.signaledValue = 1; up_settle(); CHECK("the held batch's bytes went through", round_ok(r));
            up_pool_release(&n); res_commit(); w[0] = w[1] = nil;
        }
        CHECK("a released pool leaves nothing counted", atomic_load(&g_cv_n) == 0 && atomic_load(&g_cv_bytes) == 0);
        t[0] = t[1] = u[0] = u[1] = nil;
    }
    // ---------- 3. Same-pass feedback snapshots ----------
    @autoreleasepool {
        int fresh = 0;
        mtl_sub_begin();
        fb_cache_t *e = fb_snap(93001, 0, 0, MTLPixelFormatRGBA8Unorm, 256, 256, 1, &fresh);
        CHECK("a snapshot is taken", e && e->snap && fresh);
        id<MTLTexture> s0 = e->snap; id m0 = fb_vol_obj(s0);
        // a submission still open: the sweep marks nothing, however old the entry looks
        uint64_t sub0 = e->sub; e->sub -= CV_FB_IDLE_SUBS + 1; fb_vol_sweep();
        CHECK("open submission: never marked", !e->vol && st(m0) == MTLPurgeableStateNonVolatile);
        e->sub = sub0;
        id<MTLSharedEvent> gate = [g_dev newSharedEvent]; [g_q4 waitForEvent:gate value:1];
        uint64_t f = mtl_sub_commit(); rec_publish();
        // the GPU has not completed its submission: an entry old in submissions is still not marked
        e->sub -= CV_FB_IDLE_SUBS + 1; fb_vol_sweep();
        CHECK("in flight: never marked before its fence", !e->vol && st(m0) == MTLPurgeableStateNonVolatile);
        gate.signaledValue = 1; CHECK("the held submission completes", mtl_wait(f, 5000000000ull));
        e->sub = sub0;
        for (int i = 0; i < CV_FB_IDLE_SUBS - 2; i++) sub();
        CHECK("an entry taken a few submissions ago is not marked", !e->vol && st(m0) == MTLPurgeableStateNonVolatile);
        for (int i = 0; i < 4; i++) sub();
        if (off) CHECK("off: an idle snapshot stays non-volatile", !e->vol && st(m0) == MTLPurgeableStateNonVolatile);
        else CHECK("an idle snapshot whose fence passed is volatile, and resident", e->vol && st(m0) == MTLPurgeableStateVolatile && e->snap == s0 && (resident(m0) || resident(s0)));
        // taken again for another key of the same shape: the same texture, non-volatile, copied into again
        mtl_sub_begin();
        fb_cache_t *e2 = fb_snap(93002, 0, 0, MTLPixelFormatRGBA8Unorm, 256, 256, 0, &fresh);
        CHECK("taken back: the same snapshot texture, fresh", e2 == e && e->snap == s0 && fresh && !e->vol && st(m0) == MTLPurgeableStateNonVolatile && atomic_load(&g_cv_n) == 0);
        CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
        CHECK("it reads back what was written", round_trip(e->snap, 4));
        if (!off) {
            for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
            CHECK("volatile again", e->vol && st(m0) == MTLPurgeableStateVolatile);
            [(id<MTLHeap>)m0 setPurgeableState:MTLPurgeableStateEmpty];
            uint64_t e0 = atomic_load(&g_cv_emptied);
            mtl_sub_begin();
            fb_cache_t *e3 = fb_snap(93002, 0, 0, MTLPixelFormatRGBA8Unorm, 256, 256, 0, &fresh);
            CHECK("emptied: a new snapshot texture is made, fresh (copied into again)", e3 && e3->snap && e3->snap != s0 && fresh && !e3->vol && atomic_load(&g_cv_emptied) == e0 + 1);
            CHECK("the new one is non-volatile and resident", st(fb_vol_obj(e3->snap)) == MTLPurgeableStateNonVolatile && (resident(e3->snap) || resident(fb_vol_obj(e3->snap))));
            CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
            CHECK("it reads back what was written", round_trip(e3->snap, 5));
            // the hook, on an entry of the same shape
            for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
            id<MTLTexture> s1 = e3->snap; atomic_store(&g_cv_test_empty, 1);
            mtl_sub_begin();
            fb_cache_t *e4 = fb_snap(93003, 0, 0, MTLPixelFormatRGBA8Unorm, 256, 256, 0, &fresh);
            CHECK("hook: a new snapshot texture is made", e4 && e4->snap && e4->snap != s1 && fresh && atomic_load(&g_cv_emptied) == e0 + 2);
            CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
            CHECK("hook: it reads back what was written", round_trip(e4->snap, 6));
            // marked, then the full trim releases it: nothing left counted
            for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
            CHECK("volatile before the trim", atomic_load(&g_cv_n) >= 1);
        }
        mtl_drain(); mtl_trim(4); settle();
        CHECK("after the trim nothing is counted volatile", atomic_load(&g_cv_n) == 0 && atomic_load(&g_cv_bytes) == 0);
    }
    // ---------- 4. Kept snapshots emptied, the idle release of volatile ones, and the footprint cap's trim ----------
    if (!off) @autoreleasepool {
        int fresh = 0;
        // a kept snapshot (as fb_keep_try leaves a shape that came back) goes volatile, is emptied, and its own key comes back: a new texture, still kept
        mtl_sub_begin(); g_draw_seq++;
        fb_cache_t *a = fb_snap(94001, 0, 0, MTLPixelFormatRGBA8Unorm, 256, 256, 1, &fresh);
        a->keep = 1;
        CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
        for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
        CHECK("kept: volatile once idle", a->vol && a->keep);
        id<MTLTexture> sa = a->snap; uint64_t kept0 = atomic_load(&g_fbc_kept);
        [(id<MTLHeap>)fb_vol_obj(sa) setPurgeableState:MTLPurgeableStateEmpty];
        mtl_sub_begin(); g_draw_seq++;
        fb_cache_t *a2 = fb_snap(94001, 0, 0, MTLPixelFormatRGBA8Unorm, 256, 256, 0, &fresh);
        CHECK("kept and emptied, its own key back: a new texture, fresh, still kept", a2 == a && a->snap && a->snap != sa && fresh && a->keep && !a->vol && atomic_load(&g_fbc_kept) == kept0);
        CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
        CHECK("it reads back what was written", round_trip(a->snap, 7));
        // the review's case: the kept entry of shape A, volatile and emptied, taken by a new key of shape B through the rank search (every other entry live in this draw's
        // submission): B's texture must not inherit A's keep
        for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
        CHECK("kept A volatile again", a->vol && a->keep);
        [(id<MTLHeap>)fb_vol_obj(a->snap) setPurgeableState:MTLPurgeableStateEmpty];
        mtl_sub_begin();
        for (int i = 0; i < 7; i++) { g_draw_seq++; fb_snap(94100 + (uint64_t)i, 0, 0, MTLPixelFormatRGBA8Unorm, 64, 64, 1, &fresh); }
        g_draw_seq++;
        fb_cache_t *b = fb_snap(94200, 0, 0, MTLPixelFormatBGRA8Unorm, 512, 128, 1, &fresh);
        CHECK("shape B took kept A's entry", b == a && b->snap && b->snap.width == 512 && b->snap.height == 128 && fresh);
        CHECK("B is not kept (A's keep went with A's shape)", !b->keep && !b->vol);
        CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
        // the idle release of a volatile, non-kept snapshot: its heap goes back to the list non-volatile
        for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
        id<MTLHeap> hb = fb_vol_obj(b->snap);
        CHECK("B volatile once idle", b->vol && hb && st(hb) == MTLPurgeableStateVolatile);
        uint64_t n0 = atomic_load(&g_cv_n);
        for (int i = 0; i < FB_SNAP_IDLE; i++) sub();
        settle();
        CHECK("the idle release lets B go", b->snap == nil);
        CHECK("its heap waits in the list again, non-volatile, and is no longer counted", waits(hb) && st(hb) == MTLPurgeableStateNonVolatile && atomic_load(&g_cv_n) < n0);
        hb = nil;
        { int n; rh_trim_all(&n); } settle();
        // the idle release of a volatile snapshot the system emptied: its heap is freed, not handed back
        mtl_sub_begin(); g_draw_seq++;
        fb_cache_t *c = fb_snap(94300, 0, 0, MTLPixelFormatRGBA8Unorm, 128, 128, 1, &fresh);
        CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
        for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
        CHECK("C volatile once idle", c->vol);
        __weak id<MTLHeap> whc;
        @autoreleasepool { id<MTLHeap> hc = fb_vol_obj(c->snap); whc = hc; [hc setPurgeableState:MTLPurgeableStateEmpty]; }
        uint64_t e0 = atomic_load(&g_cv_emptied);
        for (int i = 0; i < FB_SNAP_IDLE; i++) sub();
        settle();
        @autoreleasepool { id<MTLHeap> hc = whc;
            CHECK("emptied C released: its heap is not handed back to the list", c->snap == nil && (!hc || !waits(hc)) && atomic_load(&g_cv_emptied) == e0 + 1); }
        mtl_drain(); mtl_trim(4); settle();
        CHECK("nothing counted volatile after the trim", atomic_load(&g_cv_n) == 0 && atomic_load(&g_cv_bytes) == 0);
    }
    // the footprint cap's trim (TRIM_FOOT) with volatile entries: waiting heaps and snapshots go and leave the count; the staging pool is not the cap trim's, so its volatile
    // blocks stay pooled and counted
    @autoreleasepool {
        int fresh = 0;
        __weak id<MTLHeap> wh;
        @autoreleasepool { id<MTLHeap> h = wait_heap(4 * MB); wh = h; }
        rh_age(CV_IDLE_NS + 1000000); rh_trim();
        mtl_sub_begin(); g_draw_seq++;
        fb_cache_t *d = fb_snap(95001, 0, 0, MTLPixelFormatRGBA8Unorm, 256, 256, 1, &fresh);
        CHECK("mtl_sub_commit", mtl_wait(mtl_sub_commit(), 5000000000ull));
        __strong id<MTLBuffer> t[2] = {nil};
        unsigned r = burst(t); up_settle(); CHECK("a burst's bytes went through its blocks", round_ok(r));
        for (int i = 0; i < CV_FB_IDLE_SUBS + 2; i++) sub();
        pool_age(CV_IDLE_NS + 1000000); sub();
        if (off) CHECK("off: nothing volatile before the cap trim", atomic_load(&g_cv_n) == 0 && !d->vol);
        else CHECK("heap, snapshot and pool blocks volatile before the cap trim", atomic_load(&g_cv_n) == 4 && d->vol && st(t[0]) == MTLPurgeableStateVolatile);
        mtl_drain(); mtl_trim_at(TRIM_FOOT, g_fence); settle();
        @autoreleasepool { id<MTLHeap> h = wh; CHECK("cap trim: the waiting heap went", !h || !waits(h)); }
        CHECK("cap trim: the snapshot went", d->snap == nil && !d->vol);
        CHECK("cap trim: the staging pool stays", pool_bytes() == 2 * UP_BLOCK_SIZE);
        if (off) CHECK("off: nothing counted", atomic_load(&g_cv_n) == 0);
        else CHECK("cap trim: only the pool's two blocks still counted volatile", atomic_load(&g_cv_n) == 2 && atomic_load(&g_cv_bytes) == 2 * UP_BLOCK_SIZE && st(t[0]) == MTLPurgeableStateVolatile);
        int n; up_pool_release(&n); res_commit(); t[0] = t[1] = nil;
        CHECK("released: nothing counted", atomic_load(&g_cv_n) == 0 && atomic_load(&g_cv_bytes) == 0);
    }
    CHECK("no GPU error", !mtl_last_commit_error());
    printf("t_cache_volatile%s: %d checks, %d failed; %llu marked, %llu emptied and made again\n", off ? " (off)" : "", checks, failed,
           (unsigned long long)atomic_load(&g_cv_marked), (unsigned long long)atomic_load(&g_cv_emptied));
    return failed != 0;
} }
