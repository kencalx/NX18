// The GPU hang watchdog (nvn_mtl.m gpu_watch, DM_GPU_LOST_S; the idea is d2r-metal's, MIT). A GPU that never completes is faked by holding the Metal 4 queue on a shared event
// that is not signalled until the end ([g_q4 waitForEvent:]): every command buffer committed after it waits. Checks that an idle GPU is no stall; that with work waiting the
// stall report comes once at half the limit and the GPU is taken as lost once at the limit, with the front end told once; that the game's SyncWait, a queue finish and a one-off
// command buffer's wait, each blocked on the held work, return then; that nothing more is committed after (a later submission is skipped, its fence never completes, and its
// SyncWait returns at once); and, run with `off` and DM_GPU_LOST_S=0, that the watchdog does nothing however long the GPU holds. Real Metal 4 queue, no window, no game files
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
extern _Atomic int test_gpu_lost_calls;   // t_gpu_lost_front.c
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static double secs(void) { return now_ns() / 1e9; }
static int count(const char *hay, const char *needle) { int n = 0; for (const char *p = hay; (p = strstr(p, needle)); p++) n++; return n; }
int main(int argc, char **argv) { @autoreleasepool {
    alarm(60); setvbuf(stdout, NULL, _IONBF, 0);
    int off = argc > 1 && !strcmp(argv[1], "off");
    setenv("DM_PRESENT_LINK", "0", 1);
    static char out[1 << 16]; fflush(stderr); int keep = dup(2); FILE *tf = tmpfile(); dup2(fileno(tf), 2);   // the log, read back at the end
    mtl_init();
    double limit = gpw_seconds();
    usleep(off ? 300000 : (useconds_t)(limit * 1.3e6));   // no work waiting: an idle GPU is no stall
    int idle_ok = !atomic_load(&g_gpu_lost);

    id<MTLSharedEvent> hold = [g_dev newSharedEvent];
    [g_q4 waitForEvent:hold value:1];   // the queue runs nothing committed after this until the end
    mtl_sub_begin(); uint64_t f = mtl_sub_commit();
    __block int sync_ok = -1, once_ok = -2; __block double sync_at = 0, finish_at = 0, once_at = 0;
    double t0 = secs();
    dispatch_group_t g = dispatch_group_create(); dispatch_queue_t gq = dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0);
    if (!off) {
        dispatch_group_async(g, gq, ^{ sync_ok = mtl_wait(f, UINT64_MAX); sync_at = secs(); });   // the game's SyncWait on the held fence
        dispatch_group_async(g, gq, ^{ mtl_finish(); finish_at = secs(); });                     // nvnQueueFinish: the fence's feedback, then the upload batches
        dispatch_group_async(g, gq, ^{ once_ok = once_drain(); once_at = secs(); });            // a one-off command buffer behind the held work
    }
    if (off) {
        int r = mtl_wait(f, 2500000000ull);   // longer than the test's other runs' limit: nothing is taken as lost
        fflush(stderr); dup2(keep, 2); close(keep); rewind(tf); out[fread(out, 1, sizeof out - 1, tf)] = 0; fclose(tf); fputs(out, stdout);
        CHECK("DM_GPU_LOST_S=0: the watchdog says it is off", strstr(out, "GPU hang watchdog off (DM_GPU_LOST_S=0)") != NULL);
        CHECK("DM_GPU_LOST_S=0: an idle GPU is no stall", idle_ok);
        CHECK("DM_GPU_LOST_S=0: the held fence's SyncWait times out, nothing is taken as lost", !r && !atomic_load(&g_gpu_lost) && !atomic_load(&test_gpu_lost_calls) && !strstr(out, "GPU stall"));
        hold.signaledValue = 1;
        CHECK("DM_GPU_LOST_S=0: once the GPU runs again the fence completes", mtl_wait(f, 5000000000ull) && !atomic_load(&g_gone_skips));
        printf("t_gpu_watch (off): %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    usleep((useconds_t)(limit * 0.75e6));
    int before = !atomic_load(&g_gpu_lost) && !atomic_load(&test_gpu_lost_calls) && sync_ok == -1 && !finish_at && once_ok == -2;
    long waited = dispatch_group_wait(g, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((limit + 1.5) * NSEC_PER_SEC)));
    double lost_at = secs();
    uint64_t skips0 = atomic_load(&g_gone_skips);
    mtl_sub_begin(); uint64_t f2 = mtl_sub_commit();   // after: nothing is committed
    double w0 = secs(); int sync2 = mtl_wait(f2, UINT64_MAX); double w2 = secs() - w0;
    uint64_t skips1 = atomic_load(&g_gone_skips);
    hold.signaledValue = 1;   // let the held work run: what was committed before completes, what was skipped never does
    usleep(400000);
    uint64_t done = atomic_load(&g_done);
    usleep((useconds_t)(limit * 1.2e6));
    fflush(stderr); dup2(keep, 2); close(keep); rewind(tf); out[fread(out, 1, sizeof out - 1, tf)] = 0; fclose(tf); fputs(out, stdout);
    printf("limit %.2f s; SyncWait returned %d at %.2f s, queue finish at %.2f s, one-off wait %d at %.2f s; later submission's SyncWait %.1f ms; skips %llu -> %llu; done %llu, fences %llu / %llu\n",
           limit, sync_ok, sync_at - t0, finish_at - t0, once_ok, once_at - t0, w2 * 1e3, (unsigned long long)skips0, (unsigned long long)skips1, (unsigned long long)done, (unsigned long long)f, (unsigned long long)f2);
    CHECK("an idle GPU is no stall", idle_ok);
    CHECK("before the limit nothing is taken as lost and the waits still wait", before);
    CHECK("the stall report comes once, at half the limit, with the stuck fence", count(out, "GPU stall (the stall report)") == 1 && strstr(out, "stall dump: fences submitted"));
    CHECK("at the limit the GPU is taken as lost once, with its report", count(out, "GPU stall (the GPU taken as lost)") == 1 && count(out, "[RED] GPU lost: no GPU work finished") == 1);
    CHECK("the front end is told once", atomic_load(&g_gpu_lost) == GL_HANG && atomic_load(&test_gpu_lost_calls) == 1);
    CHECK("every wait on the held work returns at the limit", !waited && sync_ok == 1 && once_ok >= 0 && sync_at - t0 < limit + 1.2 && finish_at - t0 < limit + 1.2 && once_at - t0 < limit + 1.2 && lost_at - t0 >= limit * 0.9);
    CHECK("nothing more is sent: the later submission is skipped and its SyncWait returns at once", skips1 > skips0 && sync2 == 1 && w2 < 0.05);
    CHECK("  its fence never completes, while the held work does once let go", done >= f && done < f2);
    CHECK("fired once: no second report or call", count(out, "[RED] GPU lost:") == 1 && atomic_load(&test_gpu_lost_calls) == 1);
    printf("t_gpu_watch: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
