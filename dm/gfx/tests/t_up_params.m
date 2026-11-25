// Deswizzle parameter cells live as their upload batch's staging does (nvn_mtl.m up_param_alloc, g_up_slot_pblk; ported from the S2Arm project's ad3ddea6): a batch starts on its
// slot's 64 KB block; a block filled within the batch goes with the batch's staging (g_up_keep), not to the deferred-release queue behind the next replay submission's fence, and leaves
// the residency set when the batch has run; the slot's own block stays resident for the slot's next batch, which starts it again from the first cell.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static int resident(id o) { res_mu_lock(); int r = [g_res_objects containsObject:o]; res_mu_unlock(); return r; }
static int uploads_done(void) { for (int t = 0; t < 5000; t++) { if (!atomic_load(&g_up_pending)) return 1; usleep(1000); } return 0; }
static unsigned long deferred_n(void) { pthread_mutex_lock(&g_deferred_mu); unsigned long n = (unsigned long)g_deferred.count; pthread_mutex_unlock(&g_deferred_mu); return n; }
int main(void) { @autoreleasepool {
    mtl_init();
    __weak id<MTLBuffer> filled = nil; id<MTLBuffer> slot0 = nil;
    @autoreleasepool {
    up_begin(); unsigned s0 = g_up_cur_slot; CHECK("the first batch takes slot 0", s0 == 0);
    size_t off = 1; id<MTLBuffer> first = up_param_alloc(&off);
    CHECK("a batch's first cell is the first of its slot's block", first == g_up_slot_pblk[s0] && off == 0);
    slot0 = first;
    unsigned long def0 = deferred_n(); uint64_t made0 = g_up_pblocks_new; id<MTLBuffer> b = first;
    for (int i = 1; i < 1100; i++) b = up_param_alloc(&off);   // 1,024 cells a block: one switch
    CHECK("1,100 cells take one more block", g_up_pblocks_new == made0 + 1 && b != first && off == (1100 - 1024 - 1) * 64);
    CHECK("the filled block is the slot's own: it stays, not kept with the batch", ![g_up_keep containsObject:first]);
    for (int i = 0; i < 1024; i++) b = up_param_alloc(&off);   // fill the second one too: it is the batch's alone
    filled = g_up_keep.lastObject;
    CHECK("a filled block of this batch alone goes with its staging", filled && filled != first && resident(filled));
    CHECK("nothing goes to the deferred-release queue (the next replay submission's fence)", deferred_n() == def0);
    up_flush();
    CHECK("the upload batch completes", uploads_done());
    }
    CHECK("the batch has run: its filled block left the residency set and is freed", filled == nil);
    CHECK("the slot's own block stays resident", resident(slot0) && g_up_slot_pblk[0] == slot0);
    // The next batches go round the slots; each starts its slot's block from the first cell
    for (int k = 0; k < 3; k++) {
        up_begin(); unsigned s = g_up_cur_slot; size_t o = 1; id<MTLBuffer> p = up_param_alloc(&o);
        CHECK("each batch starts its slot's block from the first cell", p == g_up_slot_pblk[s] && o == 0);
        if (k == 2) CHECK("the first slot's block is used again once its batch has run", p == slot0);
        else CHECK("another slot: another block", p != slot0);
        up_flush();
    }
    CHECK("the batches complete", uploads_done());
    CHECK("no GPU error", !mtl_last_commit_error());
    printf("t_up_params: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
