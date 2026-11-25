// The upload staging block pool (nvn_mtl.m up_pool_put / up_pool_get / up_pool_trim / up_pool_release; ported from S2Arm 01afd92a and 6e708d3e): a batch's temporary 32 MB blocks
// stay resident in the pool when the batch has run, and the next burst takes them with no allocation and no residency add; the pool is bounded by its cap, goes after 5 s unused,
// at once when the headroom is low (a fake g_rh_avail), at a memory trim and going to the background, and never hands out a block whose batch the GPU has not finished.
// Each allocation's edge bytes go through the block and back, so a block reused too early shows. DM_NVN_STAGE_POOL_MB=0: nothing is pooled, as before.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { EDGE = 256, ROUNDS = 64, PER = 4, BYTES = ROUNDS * PER * 2 * EDGE };
#define MB (1u << 20)
static id<MTLBuffer> g_in, g_out; static unsigned g_round;
static int resident(id o) { res_mu_lock(); int r = [g_res_objects containsObject:o]; res_mu_unlock(); return r; }
static int committed(id o) { res_commit_lock(); int r = [g_res containsAllocation:o]; res_commit_unlock(); return r; }   // Metal's set, read under the commit lock (no commit on another thread meanwhile)
static NSUInteger res_count(void) { @autoreleasepool { res_mu_lock(); NSUInteger n = g_res_objects.allObjects.count; res_mu_unlock(); return n; } }
static int uploads_done(void) { for (int t = 0; t < 5000; t++) { if (!atomic_load(&g_up_pending)) return 1; usleep(1000); } return 0; }
static uint64_t pool_bytes(void) { os_unfair_lock_lock(&g_up_pool_lk); uint64_t b = g_up_pool_bytes; os_unfair_lock_unlock(&g_up_pool_lk); return b; }
static void pool_age(uint64_t ns) { os_unfair_lock_lock(&g_up_pool_lk); g_up_pool_used_ns = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - ns; os_unfair_lock_unlock(&g_up_pool_lk); }
static uint64_t g_fake_avail; static uint64_t fake_avail(void) { return g_fake_avail; }
// One batch of four 24 MB allocations: the slot's block, its overflow block, then two temporary blocks (temps). Returns its round, for check_round
static unsigned burst(__strong id<MTLBuffer> temps[2]) {
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
    CHECK("a burst takes two temporary blocks", nt == 2);
    up_flush();
    return r;
}
static void check_round(unsigned r) { size_t at = r * PER * 2 * EDGE; CHECK("the edge bytes went through their blocks intact", !memcmp((char *)g_in.contents + at, (char *)g_out.contents + at, PER * 2 * EDGE)); }
static void settle(void) { @autoreleasepool { CHECK("uploads complete", uploads_done()); res_commit(); } }
static void sub(void) { @autoreleasepool { mtl_sub_begin(); CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); res_commit(); } }
int main(void) { @autoreleasepool {
    mtl_init();
    const char *env = getenv("DM_NVN_STAGE_POOL_MB");
    if (env) CHECK("DM_NVN_STAGE_POOL_MB sets the cap", up_pool_cap() == (uint64_t)atoll(env) * MB);
    else CHECK("the default cap: 128 MB on iOS, 512 MB on the Mac", up_pool_cap() == (TARGET_OS_IPHONE ? 128u : 512u) * MB);
    g_in = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared]; g_out = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    res_add(g_in); res_add(g_out);
    for (unsigned i = 0; i < BYTES; i++) ((uint8_t *)g_in.contents)[i] = (uint8_t)((i / EDGE) * 37 + i * 13 + 1);
    __strong id<MTLBuffer> t[3][2] = {{nil}};
    if (env && !atoll(env)) {   // off: temporary blocks retire after their batch, as before
        __weak id<MTLBuffer> w0, w1;
        @autoreleasepool { unsigned r = burst(t[0]); w0 = t[0][0]; w1 = t[0][1]; t[0][0] = t[0][1] = nil; settle(); check_round(r); }
        CHECK("off: nothing pooled", pool_bytes() == 0 && g_up_pool_puts == 0);
        @autoreleasepool { id<MTLBuffer> a = w0, b = w1; CHECK("off: the temporary blocks left the residency set and were freed", !a && !b); }
        @autoreleasepool { uint64_t made = g_up_blocks_new; unsigned r = burst(t[1]); settle(); check_round(r); CHECK("off: a burst allocates again (the next slot's two blocks and two temporary ones)", g_up_blocks_new == made + 4); }
        printf("t_stage_pool (off): %d checks, %d failed\n", checks, failed);
        return failed != 0;
    }
    g_up_pool_cap = 128 * MB;   // four blocks, whatever the platform's default
    // Warm: the first burst makes the slot's blocks and two temporary ones, which the pool keeps, still resident
    @autoreleasepool {
        unsigned r = burst(t[0]); settle(); check_round(r);
        CHECK("the temporary blocks are kept in the pool", pool_bytes() == 2 * UP_BLOCK_SIZE && g_up_pool_puts == 2);
        CHECK("and stay in the residency set", resident(t[0][0]) && resident(t[0][1]) && committed(t[0][0]) && committed(t[0][1]));
        // A burst on the next slot: only its own slot blocks are made; the temporary ones come from the pool, with no residency add
        uint64_t made = g_up_blocks_new, hits = g_up_pool_hits; NSUInteger n0 = res_count();
        r = burst(t[1]);
        CHECK("a burst past the slot blocks reuses the pooled blocks", (t[1][0] == t[0][0] || t[1][0] == t[0][1]) && (t[1][1] == t[0][0] || t[1][1] == t[0][1]) && g_up_pool_hits == hits + 2);
        CHECK("no new allocation for them (the slot's two blocks only)", g_up_blocks_new == made + 2);
        CHECK("no residency add for them", res_count() == n0 + 2);
        settle(); check_round(r);
        r = burst(t[2]); settle(); check_round(r);   // the third slot's blocks
        CHECK("two blocks pooled after the warm bursts", pool_bytes() == 2 * UP_BLOCK_SIZE);
    }
    // In flight: with the queue held, each slot's burst takes blocks; none the GPU still reads is handed out again, and the pool takes them back only once their batch has run,
    // up to its cap: six temporary blocks retire, four are kept and two leave the residency set and are freed
    __weak id<MTLBuffer> w[6];
    @autoreleasepool {
        for (int s = 0; s < 3; s++) t[s][0] = t[s][1] = nil;
        id<MTLSharedEvent> gate = [g_dev newSharedEvent];
        [g_q4 waitForEvent:gate value:1];
        unsigned r[3]; uint64_t puts0 = g_up_pool_puts;
        for (int s = 0; s < 3; s++) {
            r[s] = burst(t[s]);
            CHECK("the pool takes nothing back while the GPU has not run the batch", pool_bytes() == 0 && g_up_pool_puts == puts0);
        }
        rec_publish();
        CHECK("the held batches are still on the GPU", atomic_load(&g_up_alloc_busy[0]));
        NSMutableSet *seen = [NSMutableSet set]; for (int s = 0; s < 3; s++) for (int k = 0; k < 2; k++) [seen addObject:t[s][k]];
        CHECK("no block is handed out twice while its batch runs", seen.count == 6);
        gate.signaledValue = 1;
        settle(); for (int s = 0; s < 3; s++) check_round(r[s]);
        for (int s = 0; s < 3; s++) for (int k = 0; k < 2; k++) w[s * 2 + k] = t[s][k];
        for (int s = 0; s < 3; s++) t[s][0] = t[s][1] = nil;
    }
    @autoreleasepool {
        int alive = 0, res = 0; for (int k = 0; k < 6; k++) { id<MTLBuffer> b = w[k]; alive += b != nil; res += b && resident(b) && committed(b); }
        CHECK("the pool holds its cap", pool_bytes() == g_up_pool_cap);
        CHECK("the four kept stay resident; the two past the cap left the set and were freed", alive == 4 && res == 4);
    }
    // Idle: 5 s unused, the next submission's start releases the pool, out of the residency set
    @autoreleasepool { sub(); CHECK("a submission within 5 s keeps the pool", pool_bytes() == g_up_pool_cap); }
    pool_age(UP_POOL_IDLE_NS + 1000000000ull); uint64_t freed0 = g_up_pool_freed;
    sub();
    @autoreleasepool {
        int alive = 0, res = 0; for (int k = 0; k < 6; k++) { id<MTLBuffer> b = w[k]; alive += b != nil; res += b && (resident(b) || committed(b)); }
        CHECK("after 5 s unused the pool is released", pool_bytes() == 0 && g_up_pool_freed == freed0 + 4);
        CHECK("its blocks left the residency set and were freed", res == 0 && alive == 0);
    }
    // Low headroom (a fake reading): under a block + 1 GB nothing is kept; with room it is; under 1 GB the pool goes at the next submission's start, before the 5 s
    g_rh_avail = fake_avail;
    @autoreleasepool {
        g_fake_avail = 512ull * MB; uint64_t skip0 = g_up_pool_skip_bytes;
        unsigned r = burst(t[0]); settle(); check_round(r);
        CHECK("low headroom: not kept", pool_bytes() == 0 && g_up_pool_skip_bytes == skip0 + 2 * UP_BLOCK_SIZE && !resident(t[0][0]) && !resident(t[0][1]));
        g_fake_avail = 4ull << 30; r = burst(t[1]); settle(); check_round(r);
        CHECK("room again: kept", pool_bytes() == 2 * UP_BLOCK_SIZE);
        g_fake_avail = 900ull * MB; g_up_pool_hr_at = 0; pool_age(0);
        sub();
        CHECK("headroom under 1 GB: released at once", pool_bytes() == 0 && !resident(t[1][0]) && !resident(t[1][1]) && !committed(t[1][0]));
        g_fake_avail = 0; r = burst(t[2]); settle(); check_round(r);
        CHECK("a headroom of 0 (none known) limits nothing", pool_bytes() == 2 * UP_BLOCK_SIZE);
        for (int s = 0; s < 3; s++) t[s][0] = t[s][1] = nil;
    }
    g_rh_avail = NULL;
    // A memory trim (pressure, or dm_gfx_suspend's going to the background) and the background purge take it whole
    @autoreleasepool {
        CHECK("pooled before the trim", pool_bytes() == 2 * UP_BLOCK_SIZE);
        mtl_drain(); mtl_trim(3);
        CHECK("the background trim releases the pool", pool_bytes() == 0);
        unsigned r = burst(t[0]); settle(); check_round(r);
        CHECK("pooled again", pool_bytes() == 2 * UP_BLOCK_SIZE && resident(t[0][0]));
        mtl_drain(); mtl_trim(1);
        CHECK("a pressure warning's trim releases the pool", pool_bytes() == 0 && !resident(t[0][0]) && !committed(t[0][0]));
        r = burst(t[1]); settle(); check_round(r);
        mtl_drain(); mtl_bg_purge(1);
        CHECK("going to the background (mtl_bg_purge) releases the pool", pool_bytes() == 0 && !resident(t[1][0]) && !committed(t[1][0]));
        mtl_bg_purge(0);
        t[0][0] = t[0][1] = t[1][0] = t[1][1] = nil;
    }
    CHECK("no GPU error", !mtl_last_commit_error());
    printf("t_stage_pool: %d checks, %d failed; %llu taken from the pool, %llu returned, %llu released\n", checks, failed,
           (unsigned long long)g_up_pool_hits, (unsigned long long)g_up_pool_puts, (unsigned long long)g_up_pool_freed);
    return failed != 0;
} }
