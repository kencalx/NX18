// The cost of a same-core handoff's wait (dm_yield_to_core_peers), and what the in-game menu's focus pair leaves behind.
// Catherine: Full Body's main thread (priority 44, core 0) and job_update_0 (priority 43, core 0) trade a lock 5,000-6,200 times a second in some scenes: each release wakes
// the worker, the main thread waits until it blocks again, and the worker blocks after 5-20 µs. The wait was a loop of 50 µs nanosleeps, so every handoff cost at least one
// timer wakeup: on the iPhone 18 Pro Max wakeups went from about 2,300 to 6,300-6,700 a second and the CPU moved to the performance cores (0.03-0.05 → 0.47 W) at 30 fps.
// The owner saw it right after closing NX 18's menu, whose focus pair (2, then 1) under focus handling mode 0 changes nothing the wait reads; this test plays that pair first.
// Real thread SVCs: the worker is a guest thread made by CreateThread, woken by an event as the game's lock wakes it, and the main thread's SignalEvent waits for it
#include "../dm.h"
#include <assert.h>
#include <signal.h>
#include <stdatomic.h>
#include <unistd.h>
#include "../hle_thread.c"
#ifndef HLE_OE_SOURCE
#define HLE_OE_SOURCE "../hle_oe.c"
#endif
#include HLE_OE_SOURCE
void dm_host_shutdown_then(const char *why, void (*then)(void *), void *arg) { (void)why; (void)then; (void)arg; }   // oe::ExecuteProgram: not exercised here
void dm_host_shutdown(const char *why) { (void)why; }
void save_sync_soon(const char *why) { (void)why; }   // hle_oe.c's menu and background ask the cloud save to go (save_sync.c)
void dm_hid_opmode_changed(void) {}
void dm_audio_suspend(int on) { (void)on; }
void guest_clock_freeze_for(int reason, int on) { (void)reason; (void)on; }
void dm_gfx_suspend(int on) { (void)on; }
void dm_gfx_quit_begin(void) {}   // the hand-over starts the pipeline archive's write (hle_oe.c)
static void timeout(int sig) { (void)sig; const char m[] = "[RED] handoff wait test timed out\n"; write(2, m, sizeof m - 1); _exit(99); }
// The real thread_main registers the pthread and waits for StartThread; only the jump to a guest stack is replaced by this C entry point
void dm_thread_enter(uint64_t entry, uint64_t arg, uint64_t sp) {
    (void)sp;
    ((void (*)(uint64_t))entry)(arg);
    uint64_t r[32] = {0}; svc_thread(0x0A, r);
    abort();
}
static uint32_t ev_w, ev_r;
static _Atomic int done, stop, host_sleep, display, pre;
#define DISPLAY_WAIT_NS 3000000
static void worker(uint64_t unused) {   // job_update_0's shape: wait, a few µs of work, wait again; or a host sleep in its work (the backstop case)
    (void)unused;
    for (;;) {
        uint32_t h = ev_r; uint64_t r[32] = {0, (uint64_t)&h, 1, (uint64_t)-1};
        svc_thread(0x18, r); assert(r[0] == 0);
        r[0] = ev_r; svc_thread(0x17, r); assert(r[0] == 0);
        if (atomic_load(&stop)) return;
        if (atomic_load(&host_sleep)) dm_guest_sleep_ns(5000000);   // stops running without a guest wait: nothing signals the waiter
        else if (atomic_load(&display)) {   // Luigi's Mansion 3's 'CommandQueue' (priority 30, core 1): woken, a little work, then the window texture's acquire waits for the display link
            uint64_t t = now_ns(); while (now_ns() - t < 8000) {}
            atomic_fetch_add(&pre, 1);
            int ann = atomic_load(&display) == 1;   // 2: the acquire as it was, a host wait the scheduler does not see
            if (ann) dm_thread_display_wait(1);
            struct timespec ts = {0, DISPLAY_WAIT_NS}; nanosleep(&ts, 0);   // the display link's wait (hle_nvn.c nvnWindowAcquireTexture → nvn_mtl.m mtl_link_wait_ticks)
            if (ann) dm_thread_display_wait(0);
        }
        else { uint64_t t = now_ns(); while (now_ns() - t < 8000) {} }
        atomic_fetch_add(&done, 1);
    }
}
static void signal_worker(void) { uint64_t r[32] = {ev_w}; assert(svc_thread(0x11, r) && r[0] == 0); }
// Luigi's Mansion 3's frame after ac1260cc: 'worker core 1' (priority 44, core 1) hands 'CommandQueue' (30, core 1) its frame with SignalToAddress; CommandQueue submits, then
// nvnQueueFinish waits for the GPU (and, with snapshots off, the last present) before it presents. The finish's waits are host condition waits on other host threads (the replay,
// the GPU's signal: nvn_queue.inc nvn_sync_wait, nvn_mtl.m mtl_wait_at), which the scheduler counted as running guest code: the signaller was held for the whole wait, 871 ms
// of every second at 16,581 polls a second on the iPhone. A host 'GPU' thread here completes each submission GPU_WAIT_NS after it comes; marked as hle_nvn.c marks the finish
// (dm_thread_gpu_wait just before the wait blocks, not under the wait's own lock), the signaller is let go as the wait begins
#define GPU_WAIT_NS 3000000
static _Atomic uint32_t frame_word;
static _Atomic int render_stop, render_done, render_pre, gpu_marked;
static pthread_mutex_t gpu_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t gpu_cv = PTHREAD_COND_INITIALIZER; static uint64_t gpu_sub, gpu_done; static int gpu_quit;
static void *gpu_thread(void *unused) {
    (void)unused; pthread_mutex_lock(&gpu_mu);
    for (;;) {
        while (gpu_done == gpu_sub && !gpu_quit) pthread_cond_wait(&gpu_cv, &gpu_mu);
        if (gpu_quit) break;
        uint64_t f = gpu_sub; pthread_mutex_unlock(&gpu_mu);
        struct timespec ts = {0, GPU_WAIT_NS}; nanosleep(&ts, 0);
        pthread_mutex_lock(&gpu_mu); gpu_done = f; pthread_cond_broadcast(&gpu_cv);
    }
    pthread_mutex_unlock(&gpu_mu); return NULL;
}
static void queue_finish(int marked) {   // the finish's shape: a submission, then a wait for its completion that blocks on a host condition variable
    pthread_mutex_lock(&gpu_mu); uint64_t f = ++gpu_sub; pthread_cond_broadcast(&gpu_cv); int blocked = 0;
    if (gpu_done < f && marked) { blocked = 1; pthread_mutex_unlock(&gpu_mu); dm_thread_gpu_wait(1); pthread_mutex_lock(&gpu_mu); }
    while (gpu_done < f) pthread_cond_wait(&gpu_cv, &gpu_mu);
    pthread_mutex_unlock(&gpu_mu);
    if (blocked) dm_thread_gpu_wait(0);   // runnable before the game's code runs again
}
static void render(uint64_t unused) {
    (void)unused;
    for (;;) {
        uint64_t r[32] = {(uint64_t)&frame_word, 2, 0, (uint64_t)-1};   // WaitForAddress: wait while the word is 0
        svc_thread(0x34, r); assert(r[0] == 0 || r[0] == R_BAD_STATE);
        atomic_store(&frame_word, 0);
        if (atomic_load(&render_stop)) return;
        uint64_t t = now_ns(); while (now_ns() - t < 8000) {}   // the frame's submits
        atomic_fetch_add(&render_pre, 1);
        queue_finish(atomic_load(&gpu_marked));
        atomic_fetch_add(&render_done, 1);
    }
}
static void signal_render(void) { atomic_store(&frame_word, 1); uint64_t r[32] = {(uint64_t)&frame_word, 0, 0, 1}; assert(svc_thread(0x35, r) && r[0] == 0); }
static void render_waits(uint32_t rh) { for (;;) { g_lock(); thr_t *w = h_get(rh, O_THREAD); int waiting = w->wkind == 3; g_unlock(); if (waiting) return; usleep(50); } }
// The threads line's count of the handoffs a GPU wait ended (dm_wake_stats over secs = 1, so the per-second figure is the count since its last call); -1 if the line lacks it
static long long line_gpu_ended(void) {
    static char line[8192]; dm_wake_stats(line, sizeof line, 1);
    const char *p = strstr(line, " ended by a display wait, "); unsigned long long v;
    return p && sscanf(p + strlen(" ended by a display wait, "), "%llu by a GPU wait", &v) == 1 ? (long long)v : -1;
}
static int gpu_case(const char *what, int marked, int n, uint32_t rh) {
    atomic_store(&gpu_marked, marked);
    line_gpu_ended();   // the line's baseline
    uint64_t p0 = atomic_load(&g_hpoll), g0 = atomic_load(&g_gwait_held), d0 = atomic_load(&g_dwait_held), held_ns = 0; int unordered = 0, early = 0;
    for (int i = 0; i < n; i++) {
        int want = atomic_load(&render_done) + 1, pre_want = atomic_load(&render_pre) + 1;
        uint64_t t0 = now_ns(); signal_render(); held_ns += now_ns() - t0;
        if (atomic_load(&render_pre) != pre_want) unordered++;   // back before the frame's submits: the handoff's order broken
        if (atomic_load(&render_done) != want) early++;          // back before the finish's wait ended
        while (atomic_load(&render_done) != want) usleep(50);
        render_waits(rh);
    }
    uint64_t polls = atomic_load(&g_hpoll) - p0, ended = atomic_load(&g_gwait_held) - g0, dended = atomic_load(&g_dwait_held) - d0; long long shown = line_gpu_ended();
    int ok = !unordered && !dended && shown == (long long)ended && (marked ? early >= n * 9 / 10 && polls * 4 < (uint64_t)n && ended == (uint64_t)n : !early && polls >= (uint64_t)n);
    printf("%s: %s: %d frames handed over with SignalToAddress, held %.0f µs each, %llu timer polls of 50 µs, %d back before the finish's wait ended, %llu handoffs ended by a GPU wait (the threads line: %lld; %llu by a display wait), %d before the submits\n",
           ok ? "PASS" : "FAIL", what, n, held_ns / 1e3 / n, (unsigned long long)polls, early, (unsigned long long)ended, shown, (unsigned long long)dended, unordered);
    return ok;
}
static uint64_t g_last_polls;
// n wakes of a worker whose work ends in the acquire's display wait (mode 1: as nvnWindowAcquireTexture marks it now; 2: unmarked, as before). Each signal must return after the
// worker's work before the wait (the handoff's order); marked, it returns as the wait begins, without a timer poll, and the threads line's count names each such wait. Unmarked,
// the signaller was held for the whole wait with a 50 µs poll after each condition wait: 17,690 polls a second on the iPhone (the control here)
static void worker_waits(uint32_t wh) { for (;;) { g_lock(); thr_t *w = h_get(wh, O_THREAD); int waiting = w->wkind == 4; g_unlock(); if (waiting) return; usleep(50); } }
static int display_case(const char *what, int mode, int n, uint32_t wh) {
    atomic_store(&display, mode);
    uint64_t p0 = atomic_load(&g_hpoll), d0 = atomic_load(&g_dwait_held), held_ns = 0; int unordered = 0, early = 0;
    for (int i = 0; i < n; i++) {
        int want = atomic_load(&done) + 1, pre_want = atomic_load(&pre) + 1;
        uint64_t t0 = now_ns(); signal_worker(); held_ns += now_ns() - t0;
        if (atomic_load(&pre) != pre_want) unordered++;
        if (atomic_load(&done) != want) early++;   // back before the display wait ended
        while (atomic_load(&done) != want) usleep(50);
        worker_waits(wh);   // the next wake finds it waiting again, as the game's next frame does
    }
    atomic_store(&display, 0);
    uint64_t polls = atomic_load(&g_hpoll) - p0, ended = atomic_load(&g_dwait_held) - d0;
    int ok = !unordered && (mode == 1 ? early >= n * 9 / 10 && polls * 4 < (uint64_t)n && ended == (uint64_t)n : !early && polls >= (uint64_t)n);
    printf("%s: %s: %d wakes, held %.0f µs each, %llu timer polls of 50 µs, %d back before the display wait ended, %llu handoffs ended by a display wait, %d before the work ahead of it\n",
           ok ? "PASS" : "FAIL", what, n, held_ns / 1e3 / n, (unsigned long long)polls, early, (unsigned long long)ended, unordered);
    return ok;
}
// n handoffs in a row: each must return after the worker's work (the ordering the handoff exists for) and without a timer wakeup of the waiter in the common case
static int storm(const char *what, int n) {
    uint64_t p0 = atomic_load(&g_hpoll), h0 = g_preempt_n, ns0 = g_preempt_ns, t0 = now_ns(); int unordered = 0;
    for (int i = 0; i < n; i++) { int want = atomic_load(&done) + 1; signal_worker(); if (atomic_load(&done) != want) unordered++; }
    uint64_t polls = atomic_load(&g_hpoll) - p0, handoffs = g_preempt_n - h0;
    // a loaded machine can keep the worker off a CPU past the spin, and then the backstop may fire: a quarter of the handoffs is far from the one poll per handoff of the old wait
    int ok = !unordered && handoffs >= (uint64_t)n * 9 / 10 && polls * 4 < (uint64_t)n;
    printf("%s: %s: %d handoffs (%llu waited) in %.1f ms, wait %.1f µs each, %llu timer polls of 50 µs, %d returned before the worker's work\n", ok ? "PASS" : "FAIL", what, n,
           (unsigned long long)handoffs, (now_ns() - t0) / 1e6, handoffs ? (g_preempt_ns - ns0) / 1e3 / handoffs : 0, (unsigned long long)polls, unordered);
    g_last_polls = polls;
    return ok;
}
int main(int argc, char **argv) {
    (void)argv;
    signal(SIGALRM, timeout); alarm(20);
    unsetenv("DM_OE_SCRIPT");
    setenv("DM_PREEMPT", argc > 1 ? "1" : "0", 1);
    svc_thread_main_init();
    thr_t *self = cur(); self->mask = 1; self->core = 0; self->prio = 44;
    uint64_t r[32] = {0};
    assert(svc_thread(0x45, r) && r[0] == 0); ev_w = (uint32_t)r[1]; ev_r = (uint32_t)r[2];
    uint64_t c[32] = {0, (uint64_t)worker, 0, 0, 43, 0};
    assert(svc_thread(0x08, c) && c[0] == 0);
    uint32_t wh = (uint32_t)c[1];
    c[0] = wh; assert(svc_thread(0x09, c) && c[0] == 0);
    for (;;) { g_lock(); thr_t *w = h_get(wh, O_THREAD); int waiting = w->wkind == 4; g_unlock(); if (waiting) break; usleep(100); }
    int ok = 1;
    h_oe_SetFocusMode(0);   // Catherine's mode: suspended out of focus, no focus notifications
    qos_class_t q0 = QOS_CLASS_UNSPECIFIED, q1 = QOS_CLASS_UNSPECIFIED; int rp = 0; pthread_get_qos_class_np(pthread_self(), &q0, &rp);
    ok &= storm("lock storm before the menu", 3000);
    uint64_t before = g_last_polls;
    dm_focus_set(2); dm_focus_set(1);   // the menu opens and closes
    uint32_t m = 0; int quiet = !h_oe_TryPopMsg(&m);
    pthread_get_qos_class_np(pthread_self(), &q1, &rp);
    g_lock(); int clean = !self->yield_pending && !atomic_load(&self->sleeping) && !self->native_wait && !self->nhand; g_unlock();
    int focus_ok = quiet && q0 == q1 && clean;
    printf("%s: focus 2 → 1 under mode 0: no notification %d, QoS %#x → %#x, the waiter's handoff state clear %d\n", focus_ok ? "PASS" : "FAIL", quiet, q0, q1, clean);
    ok &= focus_ok;
    ok &= storm("lock storm after the menu closed", 3000);
    if (g_last_polls > before + 3000 / 20) { printf("FAIL: the focus pair raised the timer polls %llu → %llu\n", (unsigned long long)before, (unsigned long long)g_last_polls); ok = 0; }
    // The backstop: a held thread that stops running without a guest wait (a host sleep here; host GPU work alike) releases the waiter within a poll period, not at the end of its sleep
    atomic_store(&host_sleep, 1);
    uint64_t t0 = now_ns(); signal_worker(); uint64_t waited = now_ns() - t0; int early = atomic_load(&done) == 6000;
    while (atomic_load(&done) != 6001) usleep(100);
    int bs = early && waited < 4000000;
    printf("%s: held thread in a host sleep releases the waiter after %.0f µs, before its work %d\n", bs ? "PASS" : "FAIL", waited / 1e3, early);
    ok &= bs;
    atomic_store(&host_sleep, 0);
    worker_waits(wh);
    ok &= display_case("acquire's display wait, unmarked (as before)", 2, 20, wh);
    ok &= display_case("acquire's display wait, marked blocked", 1, 100, wh);
    g_lock(); int bal = !self->native_wait; thr_t *w0 = h_get(wh, O_THREAD); int wbal = w0 && !w0->native_wait; g_unlock();
    printf("%s: native waits balanced after the display waits (signaller %d, worker %d)\n", bal && wbal ? "PASS" : "FAIL", bal, wbal);
    ok &= bal && wbal;
    atomic_store(&stop, 1); signal_worker();
    uint32_t h = wh; uint64_t w[32] = {0, (uint64_t)&h, 1, (uint64_t)-1};
    assert(svc_thread(0x18, w) && w[0] == 0);
    w[0] = wh; assert(svc_thread(0x16, w) && w[0] == 0);
    for (int i = 0; i < 2; i++) { w[0] = i ? ev_r : ev_w; assert(svc_thread(0x16, w) && w[0] == 0); }
    // The render thread's queue finish (LM3's 'CommandQueue', priority 30 on the signaller's core), handed its frames with SignalToAddress
    {
        pthread_t gt; assert(!pthread_create(&gt, NULL, gpu_thread, NULL));
        uint64_t rc[32] = {0, (uint64_t)render, 0, 0, 30, 0};
        assert(svc_thread(0x08, rc) && rc[0] == 0);
        uint32_t rh = (uint32_t)rc[1];
        rc[0] = rh; assert(svc_thread(0x09, rc) && rc[0] == 0);
        render_waits(rh);
        ok &= gpu_case("queue finish's GPU wait, unmarked (as before)", 0, 20, rh);
        ok &= gpu_case("queue finish's GPU wait, marked blocked", 1, 100, rh);
        g_lock(); int sb = !self->native_wait; thr_t *r0 = h_get(rh, O_THREAD); int rb = r0 && !r0->native_wait; g_unlock();
        printf("%s: native waits balanced after the GPU waits (signaller %d, render thread %d)\n", sb && rb ? "PASS" : "FAIL", sb, rb);
        ok &= sb && rb;
        atomic_store(&render_stop, 1); signal_render();
        uint32_t hr = rh; uint64_t rw[32] = {0, (uint64_t)&hr, 1, (uint64_t)-1};
        assert(svc_thread(0x18, rw) && rw[0] == 0);
        rw[0] = rh; assert(svc_thread(0x16, rw) && rw[0] == 0);
        pthread_mutex_lock(&gpu_mu); gpu_quit = 1; pthread_cond_broadcast(&gpu_cv); pthread_mutex_unlock(&gpu_mu); pthread_join(gt, NULL);
    }
    return ok ? 0 : 1;
}
