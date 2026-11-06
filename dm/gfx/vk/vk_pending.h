// Vulkan pipelines whose Metal compile finishes while the game goes on (hle_vk.m, DM_VK_PSO_ASYNC): what the thread that creates a pipeline, the completion handler
// that ends its compile, the draws that use it and vkDestroyPipeline agree on. Plain C (pthread, C11 atomics), so dm/gfx/tests/t_vk_pending.c runs it under
// ThreadSanitizer on any machine. One word per pipeline, zero for one with no compile running (zalloc's zero is right for a pipeline that never compiled):
//   · VKP_BUSY from vkp_begin until vkp_finish, which the handler calls once the pipeline's Metal objects are stored: clearing it publishes them (release), and a
//     reader that sees it clear (vkp_wait: one acquire load, else a sleep on the pool's condition variable) reads them whole;
//   · VKP_GONE when the game destroys the pipeline (vkp_drop). Whichever of the two comes second frees it: vkp_drop returns 1 when no compile is running, vkp_finish
//     when the game destroyed the pipeline meanwhile. A handler never touches freed memory, and vkDestroyPipeline never waits for Metal;
//   · vkp_end, the handler's last call, after that free; vkp_wait_all (vkDestroyDevice) waits until every handler has made it.
// At most limit compiles are handed to Metal at once (vkp_start; hle_vk.m: twice what its compiler runs at once, so it always has the next one): the others wait in
// the pool's queue in the order they were created, and the vkp_end that frees a slot returns the next for its caller to hand over. One a submission is about to draw
// with goes to the queue's front (vkp_hurry, vkp_wait), so a frame waits for its own pipelines and not for every one created before them.
// The pool also counts what the [vk] pipelines line reports (vkp_take): compiles finished and failed, the first begin and the last finish, each one's time from begin
// to finish, the most in flight and handed to Metal, the creating threads' time in vkCreateGraphicsPipelines (vkp_create) and the waits for a compile
#pragma once
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>
#include <time.h>

enum { VKP_BUSY = 1, VKP_GONE = 2 };
#ifndef VKP_SLOW_NS
#define VKP_SLOW_NS 5000000000ull   // a wait during which no compile at all has finished for this long is reported (vkp_wait's slow); the test takes less
#endif
// st: the word; t0: vkp_begin's time, which vkp_finish reads (the handler runs after the compile was handed to Metal); queued, qprev, qnext: its place in the pool's
// queue, under the pool's lock
typedef struct vkp_t { _Atomic uint32_t st; uint32_t queued; uint64_t t0; struct vkp_t *qprev, *qnext; } vkp_t;
// One burst of compiles, as vkp_take hands it out: compiles finished (n, failed ones too: nfail), first begin and last finish, the sum of begin-to-finish times, the
// time in vkCreateGraphicsPipelines summed over the creating threads, waits that slept (all their time, the longest), the most in flight (queued ones too) and the
// most handed to Metal at once; total: compiles finished since the start
typedef struct { uint64_t n, nfail, first, last, sum, create_ns, nwait, wait_ns, wait_max, total; uint32_t peak, peak_run; } vkp_rec;
typedef struct {
    pthread_mutex_t mu; pthread_cond_t cv;
    uint32_t inflight, waiting;   // compiles begun and not ended (vkp_end), queued ones too; threads asleep in vkp_wait / vkp_wait_all (a finish or an end wakes them only when there are some)
    uint32_t running, limit;      // compiles handed to Metal (vkp_start to vkp_end), at most limit of them (0: no limit)
    vkp_t *qhead, *qtail;         // the others, oldest first
    vkp_rec b;                    // the burst so far, since the last vkp_take
} vkp_pool;
#define VKP_POOL_INIT {.mu = PTHREAD_MUTEX_INITIALIZER, .cv = PTHREAD_COND_INITIALIZER}

static inline uint64_t vkp_clock(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + (uint64_t)t.tv_nsec; }
static inline void vkp_set_limit(vkp_pool *g, uint32_t n) { pthread_mutex_lock(&g->mu); g->limit = n; pthread_mutex_unlock(&g->mu); }
// Before the pipeline is handed out: vkCreateGraphicsPipelines' return publishes the word to the game's threads
static inline void vkp_begin(vkp_pool *g, vkp_t *p, uint64_t now) {
    p->t0 = now; atomic_store_explicit(&p->st, VKP_BUSY, memory_order_relaxed);
    pthread_mutex_lock(&g->mu);
    if (!g->inflight && !g->b.n) g->b.first = now;   // the first compile since the last vkp_take
    if (++g->inflight > g->b.peak) g->b.peak = g->inflight;
    pthread_mutex_unlock(&g->mu);
}
static inline void vkp_run(vkp_pool *g) { if (++g->running > g->b.peak_run) g->b.peak_run = g->running; }   // under the lock: a compile takes a slot
static inline void vkp_unqueue(vkp_pool *g, vkp_t *p) {   // under the lock
    if (p->qprev) p->qprev->qnext = p->qnext; else g->qhead = p->qnext;
    if (p->qnext) p->qnext->qprev = p->qprev; else g->qtail = p->qprev;
    p->qprev = p->qnext = NULL; p->queued = 0;
}
static inline void vkp_front(vkp_pool *g, vkp_t *p) {   // under the lock: a queued compile someone waits for is the next handed to Metal
    if (!p->queued || g->qhead == p) return;
    vkp_unqueue(g, p);   // not the head, so the queue still has one (the else is for the static analyzer, which cannot see that)
    p->queued = 1; p->qnext = g->qhead; if (g->qhead) g->qhead->qprev = p; else g->qtail = p; g->qhead = p;
}
// After vkp_begin, once the compile is ready to go: 1 = the caller hands it to Metal now; 0 (queue only, limit compiles at Metal already) = it waits in the queue, and
// the vkp_end that frees a slot returns it. queue 0 (DM_VK_PSO_ASYNC=0: the creating thread compiles it) always takes a slot, for the count
static inline int vkp_start(vkp_pool *g, vkp_t *p, int queue) {
    pthread_mutex_lock(&g->mu);
    int now = !queue || !g->limit || g->running < g->limit;
    if (now) vkp_run(g);
    else { p->queued = 1; p->qnext = NULL; p->qprev = g->qtail; if (g->qtail) g->qtail->qnext = p; else g->qhead = p; g->qtail = p; }
    pthread_mutex_unlock(&g->mu);
    return now;
}
// The handler, once the pipeline's Metal objects are stored (failed: it has none); the draws waiting for it wake. 1: the game destroyed the pipeline meanwhile, and the
// caller frees it. After the exchange a pipeline the game still has may be destroyed and freed at any time, so p is not touched again. Then vkp_end, after that free
static inline int vkp_finish(vkp_pool *g, vkp_t *p, int failed, uint64_t now) {
    uint64_t t0 = p->t0;
    pthread_mutex_lock(&g->mu);
    uint32_t old = atomic_fetch_and_explicit(&p->st, ~(uint32_t)VKP_BUSY, memory_order_acq_rel);
    g->b.n++; g->b.total++; g->b.nfail += failed != 0; g->b.sum += now > t0 ? now - t0 : 0; if (now > g->b.last) g->b.last = now;
    if (g->waiting) pthread_cond_broadcast(&g->cv);
    pthread_mutex_unlock(&g->mu);
    return (old & VKP_GONE) != 0;
}
// The handler's last call: its compile is no longer in flight, so vkp_wait_all returns only once no handler touches a pipeline. slot: the compile had one (vkp_start).
// The oldest queued compile then takes it and is returned, for the caller to hand to Metal (NULL: none); it is still in flight, so vkp_wait_all waits for it too
static inline vkp_t *vkp_end(vkp_pool *g, int slot) {
    vkp_t *n = NULL;
    pthread_mutex_lock(&g->mu);
    g->inflight--;
    if (slot) { g->running--; if (g->qhead && (!g->limit || g->running < g->limit)) { n = g->qhead; vkp_unqueue(g, n); vkp_run(g); } }
    if (g->waiting) pthread_cond_broadcast(&g->cv);
    pthread_mutex_unlock(&g->mu);
    return n;
}
// vkDestroyPipeline: 1 = free it now; 0 = its compile is running or queued, and that compile's vkp_finish returns 1
static inline int vkp_drop(vkp_t *p) { return !(atomic_fetch_or_explicit(&p->st, VKP_GONE, memory_order_acq_rel) & VKP_BUSY); }
// A submission that will draw with p, before it waits for any of its pipelines: a queued compile goes to the queue's front. One load once the compile has finished
static inline void vkp_hurry(vkp_pool *g, vkp_t *p) {
    if (!(atomic_load_explicit(&p->st, memory_order_acquire) & VKP_BUSY)) return;
    pthread_mutex_lock(&g->mu); vkp_front(g, p); pthread_mutex_unlock(&g->mu);
}
// Before reading the pipeline's Metal objects: one load once the compile has finished; else a queued compile goes to the front and the caller sleeps until it ends. A
// wait during which no compile at all has finished for VKP_SLOW_NS calls slow once, without the pool's lock held: a compile that does not return, not a long queue
static inline void vkp_wait(vkp_pool *g, vkp_t *p, void (*slow)(uint64_t waited_ns, uint32_t inflight)) {
    if (!(atomic_load_explicit(&p->st, memory_order_acquire) & VKP_BUSY)) return;
    uint64_t t0 = vkp_clock(), tp = t0, now, w; int warned = 0;
    pthread_mutex_lock(&g->mu); g->waiting++;
    vkp_front(g, p);
    uint64_t seen = g->b.total;
    while (atomic_load_explicit(&p->st, memory_order_acquire) & VKP_BUSY) {
        struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 1;   // a second at a time, for the report
        pthread_cond_timedwait(&g->cv, &g->mu, &ts);
        now = vkp_clock();   // first the stretch up to this wake with none finished, then a compile that finished at it (a finish wakes the sleepers at once)
        if (!warned && now - tp > VKP_SLOW_NS && slow) { warned = 1; uint32_t n = g->inflight; pthread_mutex_unlock(&g->mu); slow(now - t0, n); pthread_mutex_lock(&g->mu); }
        if (g->b.total != seen) { seen = g->b.total; tp = now; }   // a compile finished: Metal's compiler is working through the queue
    }
    g->waiting--;
    w = vkp_clock() - t0; g->b.nwait++; g->b.wait_ns += w; if (w > g->b.wait_max) g->b.wait_max = w;
    pthread_mutex_unlock(&g->mu);
}
static inline void vkp_wait_all(vkp_pool *g) {
    pthread_mutex_lock(&g->mu); g->waiting++;
    while (g->inflight) pthread_cond_wait(&g->cv, &g->mu);
    g->waiting--; pthread_mutex_unlock(&g->mu);
}
// No compile begun and not ended: then every pipeline a submission can bind has its state (each was created, so begun, before it was recorded)
static inline int vkp_idle(vkp_pool *g) { pthread_mutex_lock(&g->mu); int r = !g->inflight; pthread_mutex_unlock(&g->mu); return r; }
static inline void vkp_create(vkp_pool *g, uint64_t ns) { pthread_mutex_lock(&g->mu); g->b.create_ns += ns; pthread_mutex_unlock(&g->mu); }
// The burst so far, once it has ended: some compile finished, none is in flight and the last finished quiet ns or more before now. 1: *r is the burst, and a new one
// starts; 0: r is not written
static inline int vkp_take(vkp_pool *g, uint64_t now, uint64_t quiet, vkp_rec *r) {
    pthread_mutex_lock(&g->mu);
    int ok = g->b.n && !g->inflight && now >= g->b.last && now - g->b.last >= quiet;
    if (ok) { *r = g->b; uint64_t total = g->b.total; memset(&g->b, 0, sizeof g->b); g->b.total = total; }
    pthread_mutex_unlock(&g->mu);
    return ok;
}
