// The device's pipeline list (nvn_mtl.m pso_user_record, DM_PSO_USER_QUEUE): a row is filtered against the seed and the list and written on the list's own serial queue, so the
// recording thread (mostly the replay, at a draw's first pipeline) neither reads the whole list into the filter set nor writes the file. Ocarina of Time's seed is 20,054 rows
// (MacNativeGames 7cdf1b27). `t_pso_user_queue --off` runs under DM_PSO_USER_QUEUE=0: the recording thread does both, as before. Its rows are C rows: an S row is not written
// by default (DM_PSO_DROP_S; t_pso_warm checks that).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static NSArray<NSString *> *lines(const char *path) {
    NSString *t = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *r = [NSMutableArray array]; for (NSString *l in [t componentsSeparatedByString:@"\n"]) if (l.length) [r addObject:l];
    return r;
}
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc == 2 && !strcmp(argv[1], "--off");
    if (off) setenv("DM_PSO_USER_QUEUE", "0", 1); else unsetenv("DM_PSO_USER_QUEUE");
    char path[] = "/tmp/t_pso_user_queue.XXXXXX"; int fd = mkstemp(path); if (fd < 0) return 2;
    const char *old = "C\t1111111111111111_b\n"; if (write(fd, old, strlen(old)) != (ssize_t)strlen(old)) return 2; close(fd);
    setenv("DM_PSO_USER", path, 1); unsetenv("DM_SAVE"); g_shmap_path = nil;   // no seed beside a shader map: the list alone fills the filter
    if (!off) dispatch_suspend(pso_user_queue());   // the queue holds the rows: what the recording thread did itself shows
    pso_user_record("C\t%s\n", "2222222222222222_b");
    pso_user_record("C\t%s\n", "1111111111111111_b");   // already in the list
    pso_user_record("C\t%s\n", "2222222222222222_b");   // recorded twice
    if (off) {
        CHECK("off: the recording thread built the filter set", g_pso_user_seen != nil || g_pso_user_hs_ready);   // the string set with DM_PSO_USER_HASH=0, else the row hashes
        CHECK("off: and wrote the row before returning", lines(path).count == 2);
        CHECK("off: no queue was made", g_pso_user_q == NULL);
    } else {
        CHECK("the recording thread did not build the filter set", g_pso_user_seen == nil && !g_pso_user_hs_ready && !g_pso_user_checked);
        CHECK("nor write the file", lines(path).count == 1);
        dispatch_resume(pso_user_queue());
    }
    pso_user_sync();
    NSArray *got = lines(path);
    CHECK("the new row is written once, the old one not again", got.count == 2 && [got[0] isEqualToString:@"C\t1111111111111111_b"] && [got[1] isEqualToString:@"C\t2222222222222222_b"]);
    // rows from several threads at once all reach the file, each once (the recording threads are the replay, the prefetch queues and the prewarm's workers)
    if (off) for (size_t i = 0; i < 64; i++) pso_user_record("R\t%04zx\n", i % 32);   // the old path has no lock: one thread
    else dispatch_apply(64, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) { pso_user_record("R\t%04zx\n", i % 32); });
    pso_user_sync();
    got = lines(path);
    NSMutableSet *rs = [NSMutableSet set]; for (NSString *l in got) if ([l hasPrefix:@"R\t"]) [rs addObject:l];
    if (!off) CHECK("32 distinct rows from 64 calls on many threads, each once", got.count == 34 && rs.count == 32);
    else CHECK("off: the rows all reach the file, each once", got.count == 34 && rs.count == 32);
    pso_user_sync(); if (g_pso_user) { fclose(g_pso_user); g_pso_user = NULL; } unlink(path);
    printf("t_pso_user_queue%s: %d checks, %d failed\n", off ? " --off" : "", checks, failed); return failed != 0;
} }
