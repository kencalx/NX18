// The page-in of a residency commit outside the residency commit lock (DM_NVN_RES_PREWIRE, nvn_mtl.m res_commit_to / res_prewire / res_commit_take). Ocarina of Time on the
// iPhone 18 Pro Max had "slow residency commit: 174.3 ms (adds 374, 201.7 MB)" on the commit worker, mostly the mlock page-in of guest-file pages, and the encode thread and the
// replay waited 178 and 177 ms for the lock behind it. Here a commit on a thread of its own wires a 16 MB "file-backed" buffer (the layout hook says so) in 1 MB calls the test makes
// slow (8 ms each, about 130 ms in all), as a page-in from the disk is, while this thread:
//  - commits only the changes made before that buffer's add (as the encode thread's guard does for a command buffer recorded before it): with the switch on it returns at once,
//    with its change in the set and the big buffer not yet in it; off (=0) it waits for the whole page-in, as before;
//  - takes the lock as a queue commit does: at once with the switch on, after the page-in off;
//  - commits everything: it waits for the prewire and returns with the big buffer in the set (the rule that a commit returns with what it was asked for holds either way);
// and, switch on, a page-in of four 4 MB buffers goes in 4 MB chunks, each committed after its own page-in, so a commit that needs only the first one returns after about a
// quarter of the page-in with the first buffer in the set and the last not yet. The residency line counts the prewires. Prints the waits, for before / after
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; printf("FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static double ms_since(uint64_t t0) { return (bp_now() - t0) / 1e6; }
static uintptr_t r_lo, r_hi;
static int backed(const void *p, size_t n) { uintptr_t a = (uintptr_t)p; return a >= r_lo && a + n <= r_hi ? 1 : -1; }
static _Atomic int calls; static dispatch_semaphore_t in_call;
static void slow_call(void) { if (!atomic_fetch_add(&calls, 1)) dispatch_semaphore_signal(in_call); usleep(8000); }
static int committed(id<MTLAllocation> b) { res_commit_lock(); int r = [g_res containsAllocation:b]; res_commit_unlock(); return r; }   // the lock: a prewire does not hold it, a commit holds it briefly
static void *commit_thread(void *arg) { (void)arg; @autoreleasepool { res_commit(); } return NULL; }
// The overlap case: a commit under the lock that stays in [g_res commit] 50 ms (g_res_commit_before), the end of the prewire's last mlock call, and a sampler of the in-kernel report
static void slow_commit(void) { usleep(50000); }
static _Atomic uint64_t last_call_end; static _Atomic int sampling;
static void slow_call_t(void) { slow_call(); atomic_store(&last_call_end, bp_now()); }
enum { NSAMP = 4096 }; static uint64_t sp_t[NSAMP]; static int sp_on[NSAMP], nsamp;
static void *sampler(void *arg) { (void)arg; while (atomic_load(&sampling) && nsamp < NSAMP) { sp_t[nsamp] = bp_now(); sp_on[nsamp] = mtl_res_commit_stuck(0, NULL, 0) != 0; nsamp++; usleep(500); } return NULL; }
static _Atomic int drain_done;
static void *drain_thread(void *arg) { (void)arg; @autoreleasepool { res_commit(); } atomic_store(&drain_done, 1); return NULL; }

int main(void) { @autoreleasepool {
    alarm(120); setvbuf(stdout, NULL, _IONBF, 0);
    mtl_init();
    g_pw_jobs = 1;   // DM_NVN_PREWIRE_JOBS=1: the timings below assume one call after another (t_file_wire checks the parallel page-in)
    int on = pw_on();
    printf("t_res_prewire: DM_NVN_RES_PREWIRE %s\n", on ? "on" : "off");
    const size_t R = 64u << 20, A = 16u << 20;
    uint8_t *r = mmap(NULL, R, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (r == MAP_FAILED) abort();
    memset(r, 0x33, R);
    r_lo = (uintptr_t)r; r_hi = r_lo + R;
    g_fwire_backed_hook = backed; g_fwire_call = 1u << 20; g_fwire_call_before = slow_call; in_call = dispatch_semaphore_create(0);
    g_slow_commit_ns = 50000000ull;   // the slow-prewire line at 50 ms
    char line[2048]; mtl_res_stats(line, sizeof line);

    // A small change, then the big file-backed add; a commit of both on another thread
    id<MTLBuffer> small = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    id<MTLBuffer> big = [g_dev newBufferWithBytesNoCopy:r length:A options:MTLResourceStorageModeShared deallocator:nil];
    res_add(small); uint64_t s0 = res_seq_now(); res_add(big);
    atomic_store(&calls, 0);
    uint64_t tw = bp_now(); pthread_t th; pthread_create(&th, NULL, commit_thread, NULL);
    CHECK("the other thread's commit is in its page-in", !dispatch_semaphore_wait(in_call, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    uint64_t t0 = bp_now(); res_commit_to(s0, LOCK_SITE); double w_older = ms_since(t0);
    int small_in = committed(small), big_in = committed(big);
    t0 = bp_now(); res_commit_lock(); res_commit_unlock(); double w_lock = ms_since(t0);
    t0 = bp_now(); res_commit(); double w_all = ms_since(t0);
    pthread_join(th, NULL); double page_in = ms_since(tw);
    printf("  page-in and commit of 16 MB on the other thread %.1f ms; this thread waited: changes before it %.1f ms, the lock (as a queue commit) %.1f ms, every change %.1f ms\n", page_in, w_older, w_lock, w_all);
    CHECK("the small change is in the set once the commit of the changes before the big add returns", small_in);
    CHECK("every change is in the set once the commit of everything returns", committed(small) && committed(big));
    if (on) {
        CHECK("on: the commit of the changes before the big add does not wait for its page-in (under 30 ms)", w_older < 30);
        CHECK("on: and the big buffer is not in the set yet then", !big_in);
        CHECK("on: a queue commit's take of the lock does not wait for the page-in (under 30 ms)", w_lock < 30);
    } else CHECK("off: the commit waits for the whole page-in under the lock, as before", w_older > 60 || w_lock > 60);

    if (on) {   // chunks: four 4 MB buffers, 4 MB a prewire
        g_pw_chunk = 4u << 20;
        id<MTLBuffer> c[4]; for (int i = 0; i < 4; i++) c[i] = [g_dev newBufferWithBytesNoCopy:r + A + (size_t)i * (4u << 20) length:4u << 20 options:MTLResourceStorageModeShared deallocator:nil];
        res_add(c[0]); uint64_t s1 = res_seq_now(); for (int i = 1; i < 4; i++) res_add(c[i]);
        atomic_store(&calls, 0);
        tw = bp_now(); pthread_create(&th, NULL, commit_thread, NULL);
        CHECK("chunks: the other thread's commit is in its page-in", !dispatch_semaphore_wait(in_call, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        t0 = bp_now(); res_commit_to(s1, LOCK_SITE); double w1 = ms_since(t0);
        int c0 = committed(c[0]), c3 = committed(c[3]);
        pthread_join(th, NULL); page_in = ms_since(tw);
        printf("  chunks: page-in and commits of 4 x 4 MB %.1f ms; the commit that needs the first buffer waited %.1f ms\n", page_in, w1);
        CHECK("chunks: the commit that needs the first buffer returns with it in the set, the last one not yet", c0 && !c3);
        CHECK("chunks: and waits for about its own chunk (under half of the whole page-in)", w1 < page_in / 2);
        for (int i = 0; i < 4; i++) CHECK("chunks: all of them are in the set at the end", committed(c[i]));
        mtl_res_stats(line, sizeof line);
        CHECK("the residency line counts the prewires and the waits for them", strstr(line, "(prewired outside the lock 5, 32 MB") && strstr(line, "waits for a prewire "));
        if (!strstr(line, "(prewired outside the lock 5, 32 MB")) printf("  %s\n", line);
        for (int i = 0; i < 4; i++) res_remove(c[i]);
    }

    // A prewire and a commit under the lock in the kernel together (the commit needs none of the prewire's changes): the in-kernel report (mtl_res_commit_stuck, which the freeze
    // detector and the suspend read) stays set for as long as either is in, the commit's end does not clear the prewire's mark, and a suspend-style wait (as hle_nvn.c drain_wait:
    // a look every 2 ms) for a commit that waits on that prewire ends on the report, before the commit is back
    if (on) {
        res_commit();
        g_pw_chunk = 64u << 20; g_fwire_call_before = slow_call_t;
        id<MTLBuffer> small2 = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
        id<MTLBuffer> big2 = [g_dev newBufferWithBytesNoCopy:r + 2 * A length:A options:MTLResourceStorageModeShared deallocator:nil];
        res_add(small2); uint64_t s2 = res_seq_now(); res_add(big2);
        atomic_store(&calls, 0); atomic_store(&last_call_end, 0); nsamp = 0; atomic_store(&sampling, 1);
        pthread_t sp; pthread_create(&sp, NULL, sampler, NULL);
        pthread_create(&th, NULL, commit_thread, NULL);
        CHECK("overlap: the prewire is in its page-in", !dispatch_semaphore_wait(in_call, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        uint64_t t_in = bp_now();
        g_res_commit_before = slow_commit; res_commit_to(s2, LOCK_SITE); g_res_commit_before = NULL;   // 50 ms in [g_res commit] while the prewire goes on
        char rep[320] = ""; int after_take = mtl_res_commit_stuck(0, rep, sizeof rep) != 0;
        CHECK("overlap: once the commit under the lock is back, the prewire's mark is still there", after_take && strstr(rep, "before its commit takes the residency commit lock"));
        atomic_store(&drain_done, 0); pthread_t dt; pthread_create(&dt, NULL, drain_thread, NULL);
        uint64_t t0 = bp_now(); int bailed = 0;
        while (!atomic_load(&drain_done) && ms_since(t0) < 2000) { if (mtl_res_commit_stuck(20000000ull, NULL, 0)) { bailed = 1; break; } usleep(2000); }
        double w = ms_since(t0); int drain_back = atomic_load(&drain_done);
        printf("  overlap: a suspend-style wait for a commit behind the prewire ended after %.1f ms (%s)\n", w, bailed ? "on the in-kernel report" : "the commit came back");
        CHECK("overlap: a suspend-style wait ends on the report while the commit still waits for the prewire", bailed && !drain_back && w < 20);
        pthread_join(dt, NULL); pthread_join(th, NULL);
        atomic_store(&sampling, 0); pthread_join(sp, NULL);
        uint64_t t_out = atomic_load(&last_call_end); int gaps = 0, in_win = 0;
        for (int i = 0; i < nsamp; i++) if (sp_t[i] > t_in && sp_t[i] < t_out) { in_win++; gaps += !sp_on[i]; }
        printf("  overlap: %d looks while the prewire was in the kernel, %d of them found nothing\n", in_win, gaps);
        CHECK("overlap: the report is set at every look while either is in the kernel", in_win > 20 && gaps == 0);
        CHECK("overlap: both are in the set at the end", committed(small2) && committed(big2));
        CHECK("overlap: nothing is reported once both are back", !mtl_res_commit_stuck(0, NULL, 0));
        res_remove(small2); res_remove(big2);
    }
    g_fwire_call_before = NULL; g_fwire_backed_hook = NULL;
    res_remove(small); res_remove(big); res_commit();
    CHECK("removals commit too", !committed(small) && !committed(big));
    printf("t_res_prewire: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
