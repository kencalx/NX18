// The freeze detector's graphics dump (mtl_stall_dump; dm/host/stall.c, DM_STALL_LOG) with real Metal 4: it must return at once while the locks and the waits it describes are held,
// and name them. Checks, with the residency commit lock and the residency lock held by another thread, a feedback handler that does not return, and a fence wait blocked on another
// thread: the dump returns within 100 ms, names each lock's holder with the site that took it (this file) and its age, the running handler, and the blocked wait with its fence; a
// one-off command buffer's handler beats the feedback queue's heartbeat, and once everything is let go the dump says free, idle and none
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; printf("FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
// What the dump writes to stderr (MLOG), and how long it took
static char g_out[16384]; static uint64_t g_took;
static void dump_logged(void) {
    char path[] = "/tmp/t_stall_dump.XXXXXX"; int fd = mkstemp(path); if (fd < 0) { g_out[0] = 0; return; }
    fflush(stderr); int saved = dup(2); if (saved < 0) { unlink(path); close(fd); g_out[0] = 0; return; }
    dup2(fd, 2);
    uint64_t t0 = bp_now(); mtl_stall_dump(); g_took = bp_now() - t0;
    fflush(stderr); dup2(saved, 2); close(saved);
    FILE *f = fopen(path, "r"); unlink(path); close(fd); g_out[0] = 0; if (!f) return;
    // NOLINTNEXTLINE(clang-analyzer-unix.BlockInCriticalSection): no lock is held here; the checker takes res_commit_lock's trylock (once_drain) as held on both of its paths
    char line[4096]; while (fgets(line, sizeof line, f)) strlcat(g_out, line, sizeof g_out);
    fclose(f);
}
static int has(const char *s) { return strstr(g_out, s) != NULL; }

int main(void) { @autoreleasepool {
    mtl_init();
    // The heartbeat: a one-off command buffer's feedback handler stamps it, and is not running once it has returned
    uint64_t n0 = atomic_load(&g_fbq_n);
    once_drain();
    CHECK(atomic_load(&g_fbq_n) > n0 && !atomic_load(&g_fbq_what) && atomic_load(&g_fbq_out), "a feedback handler beats the heartbeat");

    // Hold everything: the residency commit lock and the residency lock on two threads, a feedback handler that does not return, a fence wait on a fence nothing completes
    dispatch_semaphore_t held = dispatch_semaphore_create(0), go = dispatch_semaphore_create(0), fb_go = dispatch_semaphore_create(0), waited = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ res_commit_lock(); dispatch_semaphore_signal(held); dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER); res_commit_unlock(); dispatch_semaphore_signal(held); });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ res_mu_lock(); dispatch_semaphore_signal(held); dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER); res_mu_unlock(); dispatch_semaphore_signal(held); });
    dispatch_async(g_feedback_q, ^{ fb_in("stuck test"); dispatch_semaphore_signal(held); dispatch_semaphore_wait(fb_go, DISPATCH_TIME_FOREVER); fb_out(); });
    uint64_t fence = atomic_load(&g_fence) + 1000;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ mtl_wait_at(fence, 1500000000ull, WS_DIAG); dispatch_semaphore_signal(waited); });
    for (int i = 0; i < 3; i++) dispatch_semaphore_wait(held, DISPATCH_TIME_FOREVER);
    usleep(200000);   // the wait has blocked, and the holds have an age
    dump_logged();
    printf("%s", g_out);
    CHECK(g_took < 100000000ull, "the dump returns at once with every lock it describes held");
    CHECK(has("residency commit lock (g_res_commit_mu) held by host thread") && has("residency lock (g_res_mu) held by host thread"), "both residency locks' holders");
    CHECK(has("from t_stall_dump.m:"), "the site that took each lock");
    CHECK(has("running the stuck test handler for "), "the feedback handler that has not returned, and for how long");
    char want[160]; snprintf(want, sizeof want, "wait for a fence's feedback (fence): 1 thread, the latest for %llu", (unsigned long long)fence);
    CHECK(has(want), "the blocked fence wait and its fence");
    CHECK(has("stall dump: present queue") && has("stall dump: upload batches") && has("wait points: main fence"), "the present queue, the upload slots and mtl_wait_state_dump's line");

    // Let go: free, idle, none
    dispatch_semaphore_signal(go); dispatch_semaphore_signal(go); dispatch_semaphore_signal(fb_go);
    dispatch_semaphore_wait(held, DISPATCH_TIME_FOREVER); dispatch_semaphore_wait(held, DISPATCH_TIME_FOREVER);
    dispatch_semaphore_wait(waited, DISPATCH_TIME_FOREVER);
    once_drain();   // after the stuck handler: the queue has moved on
    dump_logged();
    CHECK(has("residency commit lock (g_res_commit_mu) free; residency lock (g_res_mu) free"), "both locks free once let go");
    CHECK(has("feedback queue idle, its last handler ended"), "the feedback queue idle");
    CHECK(has("blocked waits in progress: none"), "no wait in progress");
    printf("t_stall_dump: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
