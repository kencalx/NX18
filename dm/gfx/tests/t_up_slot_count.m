// The upload slot count (nvn_mtl.m up_slots_pick, g_up_nslots; adapted from MacNativeGames 6ecb27c1 (MIT)): the profile's upload_slots, DM_NVN_UP_SLOTS over it, held to 3 to 8.
// With DM_NVN_UP_SLOTS=8 (set here before mtl_init), 8 batches behind a GPU event are all in flight with no wait for a slot, the ninth waits for the first slot's batch, each batch's
// bytes land, up_seq_back reports every batch once it has come back, and each slot has its own parameter block. Run as is it checks the profile's count (3 for the test games)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { EDGE = 256, NB = 12 };
static void batch(unsigned i, id<MTLBuffer> input, id<MTLBuffer> output) {   // a staged copy of EDGE bytes through the batch's staging, and one parameter cell
    up_begin();
    size_t off; id<MTLBuffer> b = up_alloc(4096, &off);
    enc_b_copy_buffer(g_up_ce, input, i * EDGE, b, off, EDGE);
    [g_up_ce barrierAfterEncoderStages:MTLStageBlit beforeEncoderStages:MTLStageBlit visibilityOptions:MTL4VisibilityOptionDevice];
    enc_b_copy_buffer(g_up_ce, b, off, output, i * EDGE, EDGE);
    size_t po = 1; id<MTLBuffer> p = up_param_alloc(&po);
    CHECK("each batch starts its own slot's parameter block", p == g_up_slot_pblk[g_up_cur_slot] && po == 0);
    up_flush();
}
int main(void) { @autoreleasepool {
    const char *why;
    CHECK("no override: the profile's count", up_slots_pick(NULL, 3, &why) == 3 && !strcmp(why, "the default"));
    CHECK("a profile of 8", up_slots_pick(NULL, 8, &why) == 8 && !strcmp(why, "game profile upload_slots"));
    CHECK("the override wins", up_slots_pick("3", 8, &why) == 3 && !strcmp(why, "DM_NVN_UP_SLOTS"));
    CHECK("held to 8", up_slots_pick("20", 3, &why) == 8 && strstr(why, "held"));
    CHECK("held to 3", up_slots_pick("1", 8, &why) == 3 && strstr(why, "held"));
    CHECK("not a number: the profile's", up_slots_pick("8x", 5, &why) == 5 && strstr(why, "not a number"));
    CHECK("empty: the profile's", up_slots_pick("", 8, &why) == 8);
    const char *env = getenv("DM_NVN_UP_SLOTS");
    mtl_init();
    unsigned want = up_slots_pick(env, DM_GAME_UPLOAD_SLOTS, &why);
    CHECK("mtl_init took the count", g_up_nslots == want);
    for (unsigned i = 0; i < UP_SLOTS_MAX; i++) CHECK("an allocator for each slot in use, none past them", (g_up_alloc4[i] != nil) == (i < g_up_nslots));
    unsigned n = g_up_nslots;
    id<MTLBuffer> input = [g_dev newBufferWithLength:NB * EDGE options:MTLResourceStorageModeShared];
    id<MTLBuffer> output = [g_dev newBufferWithLength:NB * EDGE options:MTLResourceStorageModeShared];
    res_add(input); res_add(output);
    for (unsigned i = 0; i < NB * EDGE; i++) ((uint8_t *)input.contents)[i] = (uint8_t)(i * 7 + i / EDGE + 1);
    memset(output.contents, 0, NB * EDGE);
    @autoreleasepool {
    mtl_sub_begin();
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
    [g_q4 waitForEvent:gate value:1];   // every batch below stays on the GPU until the gate opens
    unsigned seq0 = g_up_seq;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3000000000ull), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ gate.signaledValue = 1; });   // a safety net: a batch that waits fails the check below instead of hanging
    for (unsigned i = 0; i < n; i++) batch(i, input, output);
    int busy = 0; for (unsigned i = 0; i < n; i++) busy += atomic_load(&g_up_alloc_busy[i]) != 0;
    CHECK("every slot holds a batch in flight", busy == (int)n);
    CHECK("no batch waited for a slot", gate.signaledValue == 0);
    for (unsigned i = 0; i < n; i++) CHECK("a batch in flight has not come back", !up_seq_back(seq0 + i + 1));
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100000000), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ gate.signaledValue = 1; });
    batch(n, input, output);
    CHECK("one batch past the slots waited for the first slot's batch", gate.signaledValue == 1 && g_up_cur_slot == seq0 % n);
    for (unsigned i = n + 1; i < NB; i++) batch(i, input, output);
    CHECK("submission completes", mtl_wait(mtl_sub_commit(), 5000000000ull));
    CHECK("GPU has no submission error", !mtl_last_commit_error());
    mtl_drain();
    for (unsigned i = 0; i < NB; i++) CHECK("every batch has come back", up_seq_back(seq0 + i + 1));
    }
    CHECK("every batch's bytes landed", !memcmp(input.contents, output.contents, NB * EDGE));
    for (unsigned i = 0; i < n; i++) CHECK("no slot is in flight after the drain", !atomic_load(&g_up_alloc_busy[i]));
    for (unsigned i = 0; i < n; i++) for (unsigned j = 0; j < i; j++) CHECK("each slot has a parameter block of its own", g_up_slot_pblk[i] && g_up_slot_pblk[i] != g_up_slot_pblk[j]);
    printf("t_up_slot_count: %u slots (%s); %d checks, %d failed\n", n, why, checks, failed);
    return failed != 0;
} }
