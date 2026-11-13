// Residency changes and their commit: res_add / res_remove only queue a change, and res_commit applies and commits what is queued under a lock of its own. A commit that adds
// hundreds of MB takes tens of milliseconds; while it held the lock res_add takes, every res_add on any thread waited for it (Switch Sports Resort's court load: the submit
// thread's res_add waited 20-43 ms in one frame for the upload batches' completion handlers). Checks, with real Metal allocations:
//  - a res_add or res_remove while another thread's commit is under way returns at once (it waited for the whole commit before);
//  - after res_commit returns, what was added before it is in the set, also when another thread's commit took the change;
//  - a removed allocation stays alive until the commit that takes it out of the set, then goes.
// And, after Ocarina of Time's test 3 (baf45a97) froze once with nothing in the log (one path the audits could not rule out: a long residency or queue commit, which every
// completion waited behind while the upload batch's feedback handler committed the residency set on g_feedback_q):
//  - a residency commit, a queue commit or a wait for the commit lock past the threshold (g_slow_commit_ns, 100 ms; lowered here to drive the lines) says so, with what it
//    applied, its site, its thread, whether it ran on the feedback queue and the lock's holder; the first 20 of a kind, then every 100th;
//  - no feedback handler waits for the commit lock: with it held by another thread, the upload batch's and a one-off command buffer's handlers return and the feedback queue
//    runs on; their removals are committed by the residency commit worker once the lock is free (the batch counts as pending until then), and once_wait commits its own before
//    it returns;
//  - a pool lookup that makes a pool resident commits after letting go of g_mu, and neither it nor another thread's lookup of that pool returns before the pool is committed.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; printf("FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
// stderr (MLOG) goes to an unlinked file for the whole run; log_new() returns what was written since its last call (and echoes it)
static char g_log[1 << 20]; static int g_logfd = -1; static off_t g_logoff;
static const char *log_new(void) {
    fflush(stderr); ssize_t n = g_logfd < 0 ? 0 : pread(g_logfd, g_log, sizeof g_log - 1, g_logoff); if (n < 0) n = 0;
    g_log[n] = 0; g_logoff += n; fputs(g_log, stdout); return g_log;
}
static int count(const char *s, const char *w) { int n = 0; for (const char *p = s; (p = strstr(p, w)); p += strlen(w)) n++; return n; }
static dispatch_semaphore_t run(void (^b)(void)) {   // b on a thread of its own; returned() gives it ms to return
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ b(); dispatch_semaphore_signal(s); });
    return s;
}
static int returned(dispatch_semaphore_t s, int64_t ms) { return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, ms * (int64_t)NSEC_PER_MSEC)) == 0; }
// The commit lock held on a thread of its own, as a long commit holds it, until release is signalled; returns once it is held
static dispatch_semaphore_t hold_lock(dispatch_semaphore_t release) {
    dispatch_semaphore_t held = dispatch_semaphore_create(0);
    dispatch_semaphore_t done = run(^{ res_commit_lock(); dispatch_semaphore_signal(held); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); res_commit_unlock(); });
    dispatch_semaphore_wait(held, DISPATCH_TIME_FOREVER);
    return done;
}
// The feedback queue held by a block of its own until the returned semaphore is signalled
static dispatch_semaphore_t gate_feedback(void) {
    dispatch_semaphore_t gate = dispatch_semaphore_create(0), in = dispatch_semaphore_create(0);
    dispatch_async(g_feedback_q, ^{ dispatch_semaphore_signal(in); dispatch_semaphore_wait(gate, DISPATCH_TIME_FOREVER); });
    dispatch_semaphore_wait(in, DISPATCH_TIME_FOREVER);
    return gate;
}
static int feedback_runs(void) { dispatch_semaphore_t s = dispatch_semaphore_create(0); dispatch_async(g_feedback_q, ^{ dispatch_semaphore_signal(s); }); return returned(s, 2000); }
static int pool_resident_now(uint64_t a) {   // g_mu only tried: with it held for the length of a commit this answers -1, not wait
    if (pthread_mutex_trylock(&g_mu)) return -1;
    int i = pool_find(a, 1), r = i >= 0 && g_pools[i].res; pthread_mutex_unlock(&g_mu); return r;
}

enum { BIG_BYTES = 48u << 20 };

static id<MTLBuffer> buf(size_t n) { return [g_dev newBufferWithLength:n options:MTLResourceStorageModePrivate]; }

int main(void) { @autoreleasepool {
    alarm(120); setvbuf(stdout, NULL, _IONBF, 0);
    { char path[] = "/tmp/t_res_commit.XXXXXX"; g_logfd = mkstemp(path); if (g_logfd >= 0) { unlink(path); fflush(stderr); dup2(g_logfd, 2); } }
    setenv("DM_NVN_ENC_THREAD", "0", 1);   // the one-off command buffer's queue commit is its own (once_commit), not the encode thread's
    mtl_init();
    CHECK("the slow commit threshold is 100 ms", g_slow_commit_ns == 100000000ull);
    CHECK("a residency set", g_res != nil);

    // Added, committed, in the set
    id<MTLBuffer> a = buf(1u << 20);
    res_add(a); res_commit();
    CHECK("an allocation added and committed is in the set", [g_res containsAllocation:a]);

    // Removed: alive until its commit, gone after it
    __weak id<MTLBuffer> weak_r = nil;
    @autoreleasepool { id<MTLBuffer> r = buf(1u << 20); weak_r = r; res_add(r); res_commit(); res_remove(r); }
    CHECK("a removed allocation stays alive until its removal is committed", weak_r != nil);
    @autoreleasepool { res_commit(); }
    CHECK("and goes once it is", weak_r == nil);

    // A res_add while another thread's commit is under way: a commit alone takes well under a millisecond here, but tens of milliseconds in a game whose GPU is busy (10-25 ms
    // each in Switch Sports Resort's court load), so one is stood in for by holding the commit's lock for 100 ms, as a commit holds it
    NSMutableArray *small = [NSMutableArray array];
    dispatch_semaphore_t held = dispatch_semaphore_create(0), released = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        pthread_mutex_lock(&g_res_commit_mu); dispatch_semaphore_signal(held); usleep(100000); pthread_mutex_unlock(&g_res_commit_mu); dispatch_semaphore_signal(released);
    });
    dispatch_semaphore_wait(held, DISPATCH_TIME_FOREVER);
    uint64_t worst = 0, t_all = bp_now();
    for (int i = 0; i < 200; i++) { id<MTLBuffer> s = buf(4096); [small addObject:s]; uint64_t t0 = bp_now(); res_add(s); res_remove(s); res_add(s); uint64_t d = bp_now() - t0; if (d > worst) worst = d; }
    uint64_t adds = bp_now() - t_all;
    printf("200 res_add / res_remove while a commit holds its lock: %.2f ms in all, the slowest %.3f ms\n", adds / 1e6, worst / 1e6);
    CHECK("res_add and res_remove do not wait for a commit under way", adds < 50000000ull);
    uint64_t t_c = bp_now(); res_commit(); uint64_t waited = bp_now() - t_c;
    CHECK("res_commit waits for the commit under way, then commits its own changes", waited > 20000000ull && dispatch_semaphore_wait(released, DISPATCH_TIME_NOW) == 0);
    int all = 1; for (id<MTLBuffer> s in small) all &= [g_res containsAllocation:s];
    CHECK("everything added is in the set after the commit", all);

    // A change another thread's commit took is in the set when this thread's res_commit returns
    for (int round = 0; round < 50; round++) {
        id<MTLBuffer> x = buf(BIG_BYTES / 4), y = buf(4096);
        res_add(x);
        dispatch_semaphore_t go = dispatch_semaphore_create(0), fin = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ dispatch_semaphore_signal(go); res_commit(); dispatch_semaphore_signal(fin); });
        dispatch_semaphore_wait(go, DISPATCH_TIME_FOREVER);
        res_add(y); res_commit();
        int ok = [g_res containsAllocation:x] && [g_res containsAllocation:y];
        dispatch_semaphore_wait(fin, DISPATCH_TIME_FOREVER);
        if (!ok) { CHECK("a change committed by another thread is in the set when res_commit returns", 0); break; }
        res_remove(x); res_remove(y); res_commit();
    }
    CHECK("racing commits leave nothing queued", !res_pending());
    const char *log = log_new();   // the bare mutex's 100 ms hold above may or may not have passed the threshold by the time res_commit took it: not counted

    // A wait for the commit lock past the threshold: the waiter's site and thread, and the holder's site
    { dispatch_semaphore_t rel = dispatch_semaphore_create(0), done = hold_lock(rel);
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ dispatch_semaphore_signal(rel); });
      res_commit(); returned(done, 2000); }
    log = log_new();
    CHECK("a 150 ms wait for the commit lock says so once, with the waiter's site and the holder's", count(log, "[RED] slow wait for the residency commit lock") == 1 && strstr(log, "at nvn_mtl.m:") && strstr(log, "held by host thread") && strstr(log, "from t_res_commit.m:"));

    // Slow residency commits (the threshold lowered to 0: every commit with changes says it): what it applied, its thread, the feedback queue
    g_slow_commit_ns = 0;
    { id<MTLBuffer> c = buf(1u << 20); res_add(c); res_commit(); log = log_new();
      CHECK("a slow residency commit's line: one add of 1 MB, no removal, not on the feedback queue", count(log, "[RED] slow residency commit:") == 1 && strstr(log, "(adds 1, 1.0 MB; removes 0, 0.0 MB) on thread ") && !strstr(log, "on the feedback queue") && strstr(log, "(#1)"));
      res_remove(c); dispatch_sync(g_feedback_q, ^{ res_commit(); }); log = log_new();
      CHECK("one on the feedback queue says so", count(log, "[RED] slow residency commit:") == 1 && strstr(log, "(adds 0, 0.0 MB; removes 1, 1.0 MB)") && strstr(log, ", on the feedback queue (#2)")); }
    { id<MTLBuffer> c = buf(4096); for (int i = 0; i < 98; i++) { if (i & 1) res_remove(c); else res_add(c); res_commit(); }
      if (res_pending() || [g_res containsAllocation:c]) { res_remove(c); res_commit(); }
      log = log_new();
      CHECK("the first 20, then every 100th: 18 more lines in the next 98, the 100th among them", count(log, "[RED] slow residency commit:") == 19 && strstr(log, "(#20)") && !strstr(log, "(#21)") && strstr(log, "(#100)")); }
    // A slow queue commit: a one-off command buffer's
    { NvOnce *o = once_new(1); once_end(o, once_copy(o)); CHECK("a one-off command buffer completes", once_wait(o) == 1); log = log_new();
      CHECK("a slow queue commit's line, with its site", count(log, "[RED] slow queue commit:") == 1 && strstr(log, "at once_commit (a one-off command buffer) on thread")); }
    g_slow_commit_ns = 100000000ull;
    log_new();

    // The upload batch's feedback handler queues its staging's removal and does not wait for the commit lock: with the lock held by another thread (a long commit), the
    // batch comes back and the feedback queue runs on; the batch stays pending until the residency commit worker has committed the removal, which frees the staging
    { dispatch_semaphore_t gate = gate_feedback();   // so that the handler runs only once the lock is held
      __weak id<MTLBuffer> w_stg = nil; unsigned seq;
      @autoreleasepool { up_begin(); seq = g_up_seq; id<MTLBuffer> stg = buf(4u << 20); w_stg = stg; res_add(stg); [g_up_keep addObject:stg]; up_flush(); }
      CHECK("setup: the batch is pending", atomic_load(&g_up_pending) == 1);
      dispatch_semaphore_t rel = dispatch_semaphore_create(0), done = hold_lock(rel);
      dispatch_semaphore_signal(gate);
      int back = 0; for (int i = 0; i < 200 && !(back = atomic_load(&g_up_slot_back[(seq - 1) % 3]) >= seq); i++) usleep(10000);
      CHECK("the upload batch's handler returns while the commit lock is held", back);
      CHECK("the feedback queue runs on behind it", feedback_runs());
      int alive; @autoreleasepool { alive = w_stg != nil; }
      CHECK("its staging's removal is queued, not committed: the staging alive, the batch still pending", res_pending() && alive && atomic_load(&g_up_pending) == 1);
      dispatch_semaphore_signal(rel); returned(done, 2000);
      up_wait_zero(&g_up_pending, WS_DIAG);
      @autoreleasepool { alive = w_stg != nil; }
      CHECK("once the lock is free the worker commits it: the batch is done and its staging freed", atomic_load(&g_up_pending) == 0 && !alive); }

    // A one-off command buffer without a waiter: its handler (and its done block) run while the lock is held; the worker commits the removal once the lock is free
    { dispatch_semaphore_t gate = gate_feedback();
      __weak id<MTLBuffer> w_tmp = nil; __block _Atomic int fin = 0;
      @autoreleasepool { NvOnce *o = once_new(1); id<MTLBuffer> t = buf(1u << 20); w_tmp = t; once_use(o, t); once_end(o, once_copy(o)); once_commit(o, ^(int ok) { atomic_store(&fin, ok ? 1 : 2); }); }
      dispatch_semaphore_t rel = dispatch_semaphore_create(0), done = hold_lock(rel);
      dispatch_semaphore_signal(gate);
      for (int i = 0; i < 200 && !atomic_load(&fin); i++) usleep(10000);
      int alive; @autoreleasepool { alive = w_tmp != nil; }
      CHECK("a one-off command buffer's completion runs while the commit lock is held", atomic_load(&fin) == 1 && feedback_runs());
      CHECK("its temporary's removal is queued, not committed", res_pending() && alive);
      dispatch_semaphore_signal(rel); returned(done, 2000);
      for (int i = 0; i < 200; i++) { @autoreleasepool { alive = w_tmp != nil; } if (!alive) break; usleep(10000); }
      CHECK("the worker commits it once the lock is free, which frees it", !alive); }
    // With a waiter: once_wait commits the removal itself, so the temporary is gone when it returns
    { __weak id<MTLBuffer> w_tmp = nil; int ok;
      @autoreleasepool { NvOnce *o = once_new(1); id<MTLBuffer> t = buf(1u << 20); w_tmp = t; once_use(o, t); once_end(o, once_copy(o)); ok = once_wait(o); }
      int alive; @autoreleasepool { alive = w_tmp != nil; }
      CHECK("once_wait returns with what once_use made resident out of the set and freed", ok == 1 && !alive && !res_pending()); }

    // A pool lookup that makes its pool resident commits after letting go of g_mu: with the commit lock held, g_mu is free while it waits, and neither it nor another
    // thread's lookup of the same pool returns before the pool is in the committed set
    { const size_t pn = 4u << 20;
      uint8_t *mem = mmap(NULL, pn, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
      uint64_t base = (uint64_t)(uintptr_t)mem;
      mtl_pool_add(mem, pn);
      dispatch_semaphore_t rel = dispatch_semaphore_create(0), held = hold_lock(rel);
      __block void *pb_a = NULL, *pb_b = NULL;
      dispatch_semaphore_t a = run(^{ uint64_t off; mtl_addr(base + 4096, 64, &pb_a, &off); });
      int seen = 0; for (int i = 0; i < 400 && seen != 1; i++) { seen = pool_resident_now(base); if (seen != 1) usleep(5000); }
      CHECK("the lookup marks the pool resident and lets go of g_mu while its commit waits", seen == 1);
      CHECK("the lookup has not returned before its commit", !returned(a, 100));
      dispatch_semaphore_t b = run(^{ uint64_t off; mtl_addr(base + 8192, 64, &pb_b, &off); });
      CHECK("another thread's lookup of that pool waits for the commit too", !returned(b, 150));
      dispatch_semaphore_signal(rel); returned(held, 2000);
      int ra = returned(a, 2000), rb = returned(b, 2000);
      CHECK("both return once the lock is free, with the pool in the committed set and no add left open", ra && rb && pb_a && pb_a == pb_b && [g_res containsAllocation:(__bridge id<MTLBuffer>)pb_a] && atomic_load(&g_pool_res_open) == 0);
      mtl_pool_del(mem); }
    log = log_new();
    for (id<MTLBuffer> s in small) res_remove(s);
    res_remove(a); res_commit();
    printf("t_res_commit: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
