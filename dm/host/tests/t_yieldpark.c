// Parked yields (hle_thread.c park_yield, DM_YIELD_PARK) on real threads and the real clock: a guest thread waits for another thread's progress in a spin counter loop of yields
// (x19 moves at each pass, so each yield returns at once with no host call, as Ocarina of Time's main thread's do), while a second guest thread works for a set time and then
// makes progress in one of three ways: a thread SVC (a signal), a yield after its work (a worker that polls again), or a plain store with no SVC, which only the park's cap
// ends. For each wait the waiter's CPU time (its thread CPU clock) and its wake latency (from the store to the loop's exit) are measured, with parks off (the yield path as
// before: a busy spin) and on. Short waits, under the park start, never park. A last part oversubscribes the cores with waiters and times the work they wait for: with parks
// the worker gets a core sooner. Prints the numbers; the assertions are loose enough for a loaded machine
#include "../dm.h"
#include <assert.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/sysctl.h>
#include "../hle_thread.c"

static thr_t *self(void) { thr_t *me = pthread_getspecific(g_keythr); assert(me); return me; }
static void other_svc(void) { uint64_t r[32] = {0, H_CUR_THREAD}; svc_thread(0x0C, r); }   // GetThreadPriority: other work between yields, and progress for a parked thread
static void yield_pass(uint64_t *ctr) { uint64_t r[32] = {0}; for (int i = 19; i <= 28; i++) r[i] = 0x1000 + (uint64_t)i; r[19] = ++*ctr; svc_thread(0x0B, r); }   // a spin counter's yield
static uint64_t cpu_ns(void) { return clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); }
static void busy_until(uint64_t t) { while (now_ns() < t) { } }
static void park_set(const char *v) { if (v) setenv("DM_YIELD_PARK", v, 1); else unsetenv("DM_YIELD_PARK"); g_pk_mode = -1; park_mode(); }
// A guest thread with no guest code, linked into the all-threads chain (dm_yield_top); its host thread sets it as its own
static thr_t *guest_thr(uint32_t h) {
    thr_t *t = calloc(1, sizeof *t); assert(t); t->handle = h; t->spin_mod = "main"; pthread_cond_init(&t->cv, 0); pthread_cond_init(&t->pcv, 0);
    g_lock(); t->all = g_all; g_all = t; g_unlock(); return t;
}

// BY_ARB: the progress is the SVC's own write, SignalToAddress type 2 on the word the waiter polls, made under G while another thread keeps G busy (the write comes well after
// the SVC's entry). BY_WAKE_WORK: the worker comes back from a blocking wait (WaitForAddress with a 100 µs timeout), works with no SVC, stores the flag and yields
enum { BY_SVC, BY_YIELD, BY_STORE, BY_ARB, BY_WAKE_WORK };
static const char *by_name[] = {"a signal SVC", "a yield after work", "a store alone", "SignalToAddress type 2 with G contended", "a yield after a blocking wait and work"};
static uint32_t gword, gdummy;   // the guest word SignalToAddress writes; the word the worker's blocking wait waits on (0, never signalled)
static _Atomic int go_n, flag, quit; static _Atomic uint64_t set_ns; static uint64_t work_ns; static int by; static thr_t *worker_t;
// The worker: for each round (go_n moves), work_ns of work, then the store and its kind of progress
static void *worker(void *arg) {
    (void)arg; pthread_setspecific(g_keythr, worker_t);
    uint64_t ctr = 0; int seen = 0;
    for (;;) {
        while (atomic_load(&go_n) == seen && !atomic_load(&quit)) { }
        if (atomic_load(&quit)) break;
        seen = atomic_load(&go_n);
        yield_pass(&ctr);   // the poll that found the job (its next yield after work is progress)
        if (by == BY_ARB) {
            busy_until(now_ns() + work_ns);
            uint64_t r[32] = {(uint64_t)&gword, 2, __atomic_load_n(&gword, __ATOMIC_SEQ_CST), 1}; svc_thread(0x35, r); assert(r[0] == 0);
            atomic_store(&set_ns, now_ns()); atomic_store(&flag, 1);   // after the SVC's return: the word was written before it
            continue;
        }
        if (by == BY_WAKE_WORK) {
            uint64_t r[32] = {(uint64_t)&gdummy, 0, 1, 100000}; svc_thread(0x34, r);   // blocks until its timeout
            busy_until(now_ns() + work_ns - 100000);
        } else busy_until(now_ns() + work_ns);
        atomic_store(&set_ns, now_ns()); atomic_store(&flag, 1);
        if (by == BY_SVC) other_svc();
        else if (by == BY_YIELD || by == BY_WAKE_WORK) yield_pass(&ctr);
    }
    return NULL;
}
// Keeps G busy: 30 µs held, 5 µs free, while hog_on
static _Atomic int hog_on;
static void *g_hog(void *a) { (void)a; while (atomic_load(&hog_on)) { g_lock(); busy_until(now_ns() + 30000); g_unlock(); busy_until(now_ns() + 5000); } return NULL; }
typedef struct { double cpu_us, lat_p50_us, lat_max_us; uint64_t parks, woke; } result;
static int cmp_u64(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }
// rounds waits of the main guest thread for the worker's work of w ns
static result run(int rounds, uint64_t w, int kind) {
    work_ns = w; by = kind;
    uint64_t lat[512]; assert(rounds <= 512);
    thr_t *me = self(); uint64_t p0 = me->npark, k0 = me->npark_woke, c = 0, ctr = 0;
    for (int i = 0; i < rounds; i++) {
        atomic_store(&flag, 0); other_svc();   // a new run
        uint32_t g0 = __atomic_load_n(&gword, __ATOMIC_SEQ_CST);
        uint64_t c0 = cpu_ns();
        atomic_fetch_add(&go_n, 1);
        if (kind == BY_ARB) while (__atomic_load_n(&gword, __ATOMIC_SEQ_CST) == g0) yield_pass(&ctr);
        else while (!atomic_load(&flag)) yield_pass(&ctr);
        uint64_t seen = now_ns();
        if (kind == BY_ARB) while (!atomic_load(&flag)) { }   // the worker's SVC return
        uint64_t set = atomic_load(&set_ns);
        c += cpu_ns() - c0; lat[i] = seen > set ? seen - set : 0;
        usleep(200);   // the worker back to its wait for the next round
    }
    qsort(lat, rounds, sizeof lat[0], cmp_u64);
    return (result){c / 1e3 / rounds, lat[rounds / 2] / 1e3, lat[rounds - 1] / 1e3, me->npark - p0, me->npark_woke - k0};
}

// Oversubscribed: n waiters (guest threads) spin for the worker's flag while the worker does a fixed amount of work; → the work's wall time in ms
static _Atomic int ov_flag, ov_ready;
static void *ov_waiter(void *arg) {
    pthread_setspecific(g_keythr, arg); uint64_t ctr = 0;
    other_svc(); atomic_fetch_add(&ov_ready, 1);
    while (!atomic_load(&ov_flag)) yield_pass(&ctr);
    return NULL;
}
static volatile uint64_t sink;
static double oversubscribed(int n, uint64_t iters) {
    pthread_t pt[64]; thr_t *ts[64]; assert(n <= 64);
    atomic_store(&ov_flag, 0); atomic_store(&ov_ready, 0);
    for (int i = 0; i < n; i++) { ts[i] = guest_thr(0x2000 + (uint32_t)i); assert(!pthread_create(&pt[i], 0, ov_waiter, ts[i])); }
    while (atomic_load(&ov_ready) < n) { }
    usleep(2000);   // every waiter past the park start
    uint64_t t0 = now_ns(), x = 1;
    for (uint64_t i = 0; i < iters; i++) x = x * 6364136223846793005ull + 1442695040888963407ull;
    sink = x;
    double ms = (now_ns() - t0) / 1e6;
    atomic_store(&ov_flag, 1); other_svc();
    for (int i = 0; i < n; i++) pthread_join(pt[i], 0);
    g_lock(); for (int i = 0; i < n; i++) thr_free(ts[i]); g_unlock();
    return ms;
}

int main(void) {
    alarm(60);
    svc_thread_main_init();
    // count, whatever the game's profile says (sleep would make the workers' spins storm sleeps), and this thread acquires the window texture, as Ocarina of Time's main thread
    // does: with parks off its spin is a busy spin
    setenv("DM_YIELD_STORM", "count", 1); g_ys_mode = -1; assert(ystorm_mode() == 1);
    dm_thread_acquire_mark();
    worker_t = guest_thr(0x1050);
    pthread_t wp; assert(!pthread_create(&wp, 0, worker, 0));
    char line[1536];

    // the default (unset or empty) is on; =0 / off: the yield path as before (no park, no registration)
    park_set(NULL); assert(park_mode() == 1 && g_pk_start == 50000 && g_pk_cap == 50000);
    park_set(""); assert(park_mode() == 1);
    park_set("off"); assert(park_mode() == 0);
    park_set("0"); assert(park_mode() == 0);
    result off_svc = run(100, 1000000, BY_SVC);
    assert(off_svc.parks == 0 && g_pk_reg == 0 && g_pk_wakes == 0);
    printf("  off, 1 ms waits ended by %s: waiter CPU %.0f µs a wait, wake latency p50 %.1f / max %.1f µs\n", by_name[BY_SVC], off_svc.cpu_us, off_svc.lat_p50_us, off_svc.lat_max_us);
    assert(off_svc.cpu_us > 500 && off_svc.lat_p50_us < 5);   // a busy spin: most of the 1 ms on the CPU, and the store seen at once
    puts("PASS: DM_YIELD_PARK unset parks (the default), =0 spins as before");

    park_set("1"); assert(park_mode() == 1 && g_pk_start == 50000 && g_pk_cap == 50000);
    for (int k = BY_SVC; k <= BY_STORE; k++) {
        result r = run(100, 1000000, k), o = k == BY_SVC ? off_svc : (park_set("0"), run(100, 1000000, k));
        park_set("1");
        printf("  1 ms waits ended by %s: waiter CPU %.0f → %.0f µs a wait; wake latency p50 %.1f → %.1f µs, max %.1f → %.1f µs; parks %llu a wait, %llu woken by progress\n",
               by_name[k], o.cpu_us, r.cpu_us, o.lat_p50_us, r.lat_p50_us, o.lat_max_us, r.lat_max_us, (unsigned long long)(r.parks / 100), (unsigned long long)r.woke);
        assert(r.parks > 0 && r.cpu_us < o.cpu_us / 3);   // the spin's CPU time mostly given back (50 µs of spinning before the first park, then a pass per wake)
        if (k != BY_STORE) assert(r.woke > 0 && r.lat_p50_us < 50);   // woken by the progress itself, sooner than the cap (Mac: a few µs)
        else assert(r.lat_p50_us < 50 + 2000);   // only the cap ends the park: at most about 50 µs late, and a busy machine's timer slack
    }
    puts("PASS: parks give back the spin's CPU time, wake at the progress (a signal SVC, a yield after work), and at the cap otherwise");

    // waits shorter than the park start (20 µs) never park: the latency of a spin
    { result r = run(100, 20000, BY_SVC);
      printf("  20 µs waits: parks %llu, waiter CPU %.0f µs a wait, wake latency p50 %.2f µs\n", (unsigned long long)r.parks, r.cpu_us, r.lat_p50_us);
      assert(r.parks <= 5 && r.lat_p50_us < 20); }   // a preemption past 30 µs in a round can make one park
    puts("PASS: a wait under the park start spins as before");

    // the power line's top yielders carry the parks; the registration ends with the run
    dm_yield_top(line, sizeof line); puts(line);
    other_svc(); assert(!self()->pk_reg && g_pk_reg == 0);
    { result r = run(10, 1000000, BY_SVC); (void)r; }
    dm_yield_top(line, sizeof line);
    assert(strstr(line, "0x1001 'main thread'") && strstr(line, "; parks ") && strstr(line, ", woken "));
    puts("PASS: the power line counts parks and their wakes; any other SVC ends the registration");

    // =<cap>:<start>: from 200 µs, up to 20 µs a park; a store alone then ends 20 µs late at most (and the timer's slack)
    park_set("20:200"); assert(park_mode() == 1 && g_pk_cap == 20000 && g_pk_start == 200000);
    { result r = run(50, 1000000, BY_STORE);
      printf("  =20:200, stores alone: parks %llu a wait, wake latency p50 %.1f µs\n", (unsigned long long)(r.parks / 50), r.lat_p50_us);
      assert(r.parks / 50 >= 10 && r.lat_p50_us < 20 + 2000); }
    puts("PASS: =<cap µs>:<start µs> sets both");

    // DM_YIELD_STORM=0 turns parks off too (no tight runs are tracked)
    setenv("DM_YIELD_STORM", "0", 1); g_ys_mode = -1; park_set("1");
    { result r = run(20, 1000000, BY_SVC); assert(r.parks == 0); }
    setenv("DM_YIELD_STORM", "count", 1); g_ys_mode = -1;
    puts("PASS: DM_YIELD_STORM=0 turns parks off");

    // a loop that reads the clock at each pass and moves a pass counter waits for a time: it never parks (a park would end it up to the cap late)
    park_set("1");
    { other_svc(); uint64_t p0 = self()->npark, ctr = 0, t0 = now_ns();
      while (now_ns() - t0 < 1000000) { dm_clock_reads++; yield_pass(&ctr); }
      assert(self()->npark == p0); }
    puts("PASS: a moving loop that reads the clock does not park");

    // the SVC's own write under a busy G, and a worker's yield after a blocking wait and its job: both wake the park well under its 50 µs cap
    park_set("1");
    { pthread_t hp; atomic_store(&hog_on, 1); assert(!pthread_create(&hp, 0, g_hog, 0));
      result r = run(100, 1000000, BY_ARB);
      atomic_store(&hog_on, 0); pthread_join(hp, 0);
      printf("  1 ms waits ended by %s: waiter CPU %.0f µs a wait, wake latency p50 %.1f / max %.1f µs after the SVC's return; parks %llu a wait, %llu woken\n",
             by_name[BY_ARB], r.cpu_us, r.lat_p50_us, r.lat_max_us, (unsigned long long)(r.parks / 100), (unsigned long long)r.woke);
      assert(r.parks > 0 && r.lat_p50_us < 20); }
    { result r = run(100, 1000000, BY_WAKE_WORK);
      printf("  1 ms waits ended by %s: waiter CPU %.0f µs a wait, wake latency p50 %.1f / max %.1f µs; parks %llu a wait, %llu woken\n",
             by_name[BY_WAKE_WORK], r.cpu_us, r.lat_p50_us, r.lat_max_us, (unsigned long long)(r.parks / 100), (unsigned long long)r.woke);
      assert(r.parks > 0 && r.lat_p50_us < 20); }
    puts("PASS: a park wakes after the SVC's own write (G contended) and at a yield after a blocking wait and work");

    atomic_store(&quit, 1); pthread_join(wp, 0);

    // oversubscribed: twice as many spinning waiters as cores, and the work they wait for
    int ncpu = 8; size_t sz = sizeof ncpu; sysctlbyname("hw.ncpu", &ncpu, &sz, 0, 0); ncpu *= 2; if (ncpu > 64) ncpu = 64;
    park_set("0"); double a = oversubscribed(ncpu, 50000000);
    park_set("1"); double b = oversubscribed(ncpu, 50000000);
    printf("  %d spinning waiters, the work they wait for: %.1f ms with parks off, %.1f ms on\n", ncpu, a, b);
    assert(b < a * 1.5 + 5);
    puts("PASS: oversubscribed, the work the waiters wait for is no slower with parks");
    return 0;
}
