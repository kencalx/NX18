// GPU memory full stops the game as a hang does and empties the residency set at once (nvn_mtl.m gpu_lost_check, gpu_err_oom, res_drop_all; ported from S2Arm 966e78cae, Apache-2.0).
// Checks the error's shape: Metal 4's reason name and code, Metal 3's code 8, an innocent victim's code alone not taken; a revoked access and a hang not taken for it. Then the
// flow: a hang taken as lost leaves the residency set as it is (what it holds stays for the dump); an out-of-memory error stops the game once, the front end is told, the set is
// emptied (and its books, and the changes queued for it), a residency change after it joins nothing, the waits give way and nothing more is committed. Real Metal 4 queue, no window
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
extern _Atomic int test_gpu_lost_calls;   // t_gpu_lost_front.c
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static NSError *nested(NSString *domain, NSInteger code, NSString *text, NSError *under) {   // as Metal 4 reports a command buffer's error: the cause under NSUnderlyingErrorKey
    NSMutableDictionary *u = [NSMutableDictionary dictionary];
    if (text) u[NSLocalizedDescriptionKey] = text;
    if (under) { u[NSUnderlyingErrorKey] = under; u[NSMultipleUnderlyingErrorsKey] = @[under]; }
    return [NSError errorWithDomain:domain code:code userInfo:u];
}
static void res_settle(void) { dispatch_sync(res_commit_q(), ^{}); }   // what the residency commit worker was handed is done
int main(void) { @autoreleasepool {
    alarm(60); setvbuf(stdout, NULL, _IONBF, 0);
    setenv("DM_GPU_LOST_S", "0", 1);   // no watchdog: this test takes the GPU as lost itself
    NSString *mtl4 = MTL4CommandQueueErrorDomain, *iogpu = @"IOGPUCommandQueueErrorDomain";
    NSError *oom = nested(mtl4, MTL4CommandQueueErrorTimeout, nil, nested(mtl4, MTL4CommandQueueErrorOutOfMemory, @"Insufficient Memory (00000008:kIOGPUCommandBufferCallbackErrorOutOfMemory)", nested(iogpu, 8, nil, nil)));
    CHECK("out of GPU memory by its reason name, under Metal 4's top-level timeout", gpu_err_oom(oom));
    CHECK("by Metal 4's code alone", gpu_err_oom(nested(mtl4, MTL4CommandQueueErrorTimeout, nil, nested(mtl4, MTL4CommandQueueErrorOutOfMemory, nil, nil))));
    CHECK("by Metal 3's code 8 alone", gpu_err_oom([NSError errorWithDomain:MTLCommandBufferErrorDomain code:MTLCommandBufferErrorOutOfMemory userInfo:nil]));
    CHECK("an innocent victim's code alone is not taken for it", !gpu_err_oom(nested(MTLCommandBufferErrorDomain, MTLCommandBufferErrorOutOfMemory, nil,
        nested(iogpu, 5, @"Discarded (victim of GPU error/recovery) (00000005:kIOGPUCommandBufferCallbackErrorInnocentVictim)", nil))));
    CHECK("a revoked access, a hang, a page fault and no error are not", !gpu_err_oom(gpu_lost_test_error()) && !gpu_err_oom(nested(mtl4, MTL4CommandQueueErrorTimeout, nil, nested(iogpu, 3, nil, nil)))
          && !gpu_err_oom(nested(mtl4, MTL4CommandQueueErrorTimeout, nil, nested(mtl4, MTL4CommandQueueErrorNotPermitted, nil, nested(iogpu, 11, nil, nil)))) && !gpu_err_oom(nil));

    mtl_init();
    id<MTLBuffer> b1 = [g_dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared], b2 = [g_dev newBufferWithLength:1 << 20 options:MTLResourceStorageModeShared];
    res_add(b1); res_commit();
    NSUInteger before = g_res.allocationCount;
    gpu_lost_take(GL_HANG, "a hang (the test's)"); res_settle();
    CHECK("a hang taken as lost leaves the residency set as it is", before >= 1 && g_res.allocationCount == before && atomic_load(&test_gpu_lost_calls) == 1);
    atomic_store(&g_gpu_lost, GL_NONE); atomic_store(&test_gpu_lost_calls, 0);   // the test's own reset: a run is lost once

    res_add(b2);   // queued, not committed yet: dropped with the set
    gpu_lost_check(oom, "submission"); res_settle();
    CHECK("out of GPU memory stops the game, and the front end is told", atomic_load(&g_gpu_lost) == GL_OOM && atomic_load(&test_gpu_lost_calls) == 1 && mtl_gpu_lost_why() == 3);
    CHECK("the residency set is emptied at once, its books and queued changes with it", g_res.allocationCount == 0 && g_res_qn == 0 && g_res_objects.count == 0);
    res_add(b1); res_commit();
    CHECK("a residency change after it joins nothing", g_res.allocationCount == 0);
    gpu_lost_check(oom, "submission"); gpu_lost_check(gpu_lost_test_error(), "submission");
    CHECK("the front end is told only once", atomic_load(&test_gpu_lost_calls) == 1 && atomic_load(&g_gpu_lost) == GL_OOM);
    uint64_t skips = atomic_load(&g_gone_skips);
    mtl_sub_begin(); uint64_t f = mtl_sub_commit();
    uint64_t t0 = now_ns(); int ok = mtl_wait(f, UINT64_MAX); double ms = (now_ns() - t0) / 1e6;
    CHECK("nothing more is committed, and a SyncWait gives way", atomic_load(&g_gone_skips) > skips && ok && ms < 50);
    printf("t_gpu_oom: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
