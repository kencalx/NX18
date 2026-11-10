// Exercise staging reuse with several batches in flight. Distinct edge bytes
// in every allocation detect aliasing within a batch and reuse before a read.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label,c) do { checks++; if (!(c)) { failed++; fprintf(stderr,"FAIL: %s\n",label); } } while (0)
enum { BATCHES = 24, RANGES = 4, EDGE = 256, BYTES = BATCHES * RANGES * 2 * EDGE };
static void batch(unsigned batch, const size_t *sizes, unsigned count, id<MTLBuffer> input, id<MTLBuffer> output) {
    up_begin();
    id<MTLBuffer> blocks[RANGES]; size_t offsets[RANGES];
    for (unsigned i = 0; i < count; i++) {
        size_t off; id<MTLBuffer> b = up_alloc(sizes[i], &off);
        blocks[i] = b; offsets[i] = off;
        CHECK("allocation fits its block", off + sizes[i] <= b.length);
        CHECK("staging offset is aligned", !(off & 255));
        for (unsigned j = 0; j < i; j++) CHECK("same-batch ranges do not overlap", b != blocks[j] || off >= offsets[j] + sizes[j] || offsets[j] >= off + sizes[i]);
        size_t at = (batch * RANGES + i) * 2 * EDGE;
        enc_b_copy_buffer(g_up_ce, input, at, b, off, EDGE);
        enc_b_copy_buffer(g_up_ce, input, at + EDGE, b, off + sizes[i] - EDGE, EDGE);
        [g_up_ce barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
        enc_b_copy_buffer(g_up_ce, b, off, output, at, EDGE);
        enc_b_copy_buffer(g_up_ce, b, off + sizes[i] - EDGE, output, at + EDGE, EDGE);
    }
    up_flush();
}
int main(void) { @autoreleasepool {
    mtl_init();
    id<MTLBuffer> input = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [g_dev newBufferWithLength:BYTES options:MTLResourceStorageModeShared];
    res_add(input); res_add(output);
    for (unsigned i = 0; i < BYTES; i++) ((uint8_t *)input.contents)[i] = (uint8_t)((i / EDGE) * 37 + i * 13 + 1);
    memset(output.contents, 0, BYTES);
    const size_t normal[] = {512, 24u << 20, 24u << 20};
    const size_t burst[] = {512, 24u << 20, 24u << 20, 24u << 20};
    const size_t oversized[] = {UP_BLOCK_SIZE + 256};
    uint64_t warmed = 0;
    @autoreleasepool {   // drained after the batches, as the submit thread's pools are after each submission: what they autorelease does not outlive them (the idle trim below checks the blocks it lets go are freed)
    mtl_sub_begin();
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
    [g_q4 waitForEvent:gate value:1];
    for (unsigned i = 0; i < BATCHES; i++) {
        if (i == 3) {
            CHECK("first slot still has pending GPU work", atomic_load(&g_up_alloc_busy[0]));
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100000000), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ gate.signaledValue = 1; });
        }
        batch(i, i == BATCHES - 2 ? burst : i == BATCHES - 1 ? oversized : normal,
              i == BATCHES - 2 ? 4 : i == BATCHES - 1 ? 1 : 3, input, output);
        if (i == 3) CHECK("slot reuse waited for its pending upload", gate.signaledValue == 1);
        if (i == 5) warmed = g_up_blocks_new;
        if (i == BATCHES - 3) CHECK("warm batches avoid new staging allocations", up_reuse() ? g_up_blocks_new == warmed : g_up_blocks_new > warmed);
        // Drain periodically even in the baseline: its temporary allocations
        // are retired by submission fences, not just upload slot completion.
        if (i % 9 == 8 || i + 1 == BATCHES) {
            CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
            CHECK("GPU has no submission error", !mtl_last_commit_error());
            if (i + 1 < BATCHES) mtl_sub_begin();
        }
    }
    mtl_drain();
    }
    for (unsigned b = 0; b < BATCHES; b++) {
        unsigned count = b == BATCHES - 2 ? 4 : b == BATCHES - 1 ? 1 : 3;
        for (unsigned i = 0; i < count; i++) {
            size_t at = (b * RANGES + i) * 2 * EDGE;
            CHECK("literal edge bytes survive later batches", !memcmp((char *)input.contents + at, (char *)output.contents + at, 2 * EDGE));
        }
    }
    size_t retained = 0;
    for (unsigned i = 0; i < 3; i++) {
        CHECK("primary block stays bounded", g_up_slot_blk[i].length <= UP_BLOCK_SIZE);
        CHECK("overflow block stays bounded", g_up_slot_over[i].length <= UP_BLOCK_SIZE);
        CHECK("slot is no longer in flight", !atomic_load(&g_up_alloc_busy[i]));
        retained += g_up_slot_blk[i].length + g_up_slot_over[i].length;
    }
    CHECK("retained memory stays within 192 MiB", retained <= 6u * UP_BLOCK_SIZE);
    CHECK("oversized upload did not become persistent", g_up_block == nil);
    // Idle trim (up_trim): once UP_TRIM_IDLE submissions pass without a batch that needs more than UP_SLOT_BLOCK, each slot keeps at most its 4 MB block, no overflow, no demand, and
    // the blocks it let go leave the residency set; DM_NVN_UPLOAD_TRIM=0 keeps them. A batch of the same shape afterwards makes its blocks again and copies as before
    __weak id<MTLBuffer> held[6]; size_t held_bytes = 0; int nheld = 0;
    for (unsigned i = 0; i < 3; i++) { if (g_up_slot_blk[i].length > UP_SLOT_BLOCK) { held[nheld++] = g_up_slot_blk[i]; held_bytes += g_up_slot_blk[i].length; } if (g_up_slot_over[i]) { held[nheld++] = g_up_slot_over[i]; held_bytes += g_up_slot_over[i].length; } }
    if (up_reuse()) CHECK("the warm slots hold blocks above 4 MB before the idle submissions", nheld >= 3);   // DM_NVN_UPLOAD_REUSE=0 sizes a slot's block to its batch's first texture, so its last (small) batches left 4 MB ones
    uint64_t trimmed0 = g_up_trimmed, gpu0 = g_dev.currentAllocatedSize;
    NSUInteger res0; @autoreleasepool { pthread_mutex_lock(&g_res_mu); res0 = g_res_objects.allObjects.count; pthread_mutex_unlock(&g_res_mu); }   // allObjects is an autoreleased array of them all: drained here, or it keeps them alive
    for (unsigned i = 0; i < UP_TRIM_IDLE + 2; i++) { @autoreleasepool { mtl_sub_begin(); CHECK("idle submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull)); } }
    @autoreleasepool { mtl_sub_begin(); mtl_wait(mtl_sub_commit(), 5000000000ull); mtl_drain(); defer_drain(); res_commit(); }   // the residency set lets go of what left it at its next commit (the next submission's, in a game)
    uint64_t gpu1 = g_dev.currentAllocatedSize;   // before anything below loads a weak reference (each load is retained by this pool until it drains)
    NSUInteger res1; int still = 0, alive = 0;
    @autoreleasepool { pthread_mutex_lock(&g_res_mu); res1 = g_res_objects.allObjects.count; for (int k = 0; k < nheld; k++) { id<MTLBuffer> h = held[k]; alive += h != nil; still += h && [g_res_objects containsObject:h]; } pthread_mutex_unlock(&g_res_mu); }
    size_t idle_held = 0; int over_left = 0; size_t want_left = 0;
    for (unsigned i = 0; i < 3; i++) { idle_held += g_up_slot_blk[i].length + g_up_slot_over[i].length; over_left += g_up_slot_over[i] != nil; want_left += g_up_slot_want[i]; }
    printf("idle trim %s: %d blocks above 4 MB (%zu MiB) before, slots hold %zu MiB after %u idle submissions; residency set %lu -> %lu objects; GPU allocated %llu -> %llu MiB; released %llu\n",
           up_trim_on() ? "on" : "off (DM_NVN_UPLOAD_TRIM=0)", nheld, held_bytes >> 20, idle_held >> 20, UP_TRIM_IDLE + 2, (unsigned long)res0, (unsigned long)res1, (unsigned long long)(gpu0 >> 20), (unsigned long long)(gpu1 >> 20), (unsigned long long)(g_up_trimmed - trimmed0));
    if (up_trim_on()) {
        CHECK("idle trim: the slots hold at most 3 x 4 MB", idle_held <= 3 * UP_SLOT_BLOCK);
        CHECK("idle trim: no overflow block is kept", !over_left);
        CHECK("idle trim: the slots' demand is let go", !want_left);
        CHECK("idle trim: every block it let go left the residency set", still == 0 && res1 + nheld <= res0);
        CHECK("idle trim: and was freed", alive == 0);
        CHECK("idle trim: GPU allocated fell by the blocks let go", (int64_t)gpu0 - (int64_t)gpu1 >= (int64_t)held_bytes - (4 << 20));
        CHECK("idle trim: counted for the memory line", g_up_trimmed - trimmed0 == (uint64_t)nheld);
    } else {
        CHECK("DM_NVN_UPLOAD_TRIM=0: the blocks are kept", idle_held == retained && still == nheld && g_up_trimmed == trimmed0);
    }
    // The same batch shape again: blocks made again where they were let go, the bytes copied as before
    uint64_t made0 = g_up_blocks_new;
    memset(output.contents, 0, BYTES);
    mtl_sub_begin(); batch(0, normal, 3, input, output); batch(1, burst, 4, input, output);
    CHECK("submission after the idle trim completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    mtl_drain();
    for (unsigned b = 0; b < 2; b++) for (unsigned i = 0; i < (b ? 4u : 3u); i++) { size_t at = (b * RANGES + i) * 2 * EDGE; CHECK("after the idle trim the edge bytes survive", !memcmp((char *)input.contents + at, (char *)output.contents + at, 2 * EDGE)); }
    if (up_trim_on() && up_reuse()) CHECK("after the idle trim the blocks are made again", g_up_blocks_new > made0);
    printf("t_upload_slots: %d checks, %d failed; staging allocations %llu, retained %zu MiB\n", checks, failed, (unsigned long long)g_up_blocks_new, retained >> 20);
    return failed != 0;
} }
