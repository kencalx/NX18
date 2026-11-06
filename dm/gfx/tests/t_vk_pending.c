// The protocol of Vulkan pipelines compiled while the game goes on (dm/gfx/vk/vk_pending.h, hle_vk.m DM_VK_PSO_ASYNC), with Metal's compiler played by worker threads
// that finish the compiles in another order than they began: game threads create pipelines on several threads at once, draw with them (the draw waits for the compile
// and must read the pipeline state the handler stored), destroy some at once, some after drawing and some after their compile ended, and some compiles fail. Every
// pipeline must be freed exactly once, by vkDestroyPipeline or by its handler, and never touched after (make vk-pending: also under ThreadSanitizer and
// AddressSanitizer); the counters of the [vk] pipelines line must add up. With a limit, at most that many compiles are at the compiler and the others wait in the
// pool's queue; the one a draw waits for goes first. Plain C: runs on Linux as on the Mac (cc -std=c11 -pthread)
#define _GNU_SOURCE
#define VKP_SLOW_NS 50000000ull   // the wait report after 50 ms instead of 5 s
#include "../vk/vk_pending.h"
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static _Atomic int checks, fails;   // the game threads check too (slow)
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)
static vkp_pool g_pp = VKP_POOL_INIT;

// A pipeline as hle_vk.m has one: its Metal state (pso, stored by the handler before vkp_finish) and the word
typedef struct { vkp_t pend; uint64_t pso, want; int fail; } pipe_t;
#define PIPE_OF(n) ((pipe_t *)(void *)((char *)(n) - offsetof(pipe_t, pend)))
static _Atomic uint64_t g_made, g_freed, g_failed, g_drawn, g_drawn_ok, g_by_handler, g_queued;   // by_handler: freed by the handler (vkp_finish returned 1); queued: vkp_start said wait
static void pipe_free(pipe_t *p) { p->pso = 0xdeadull; free(p); g_freed++; }
static pipe_t *pipe_new(uint64_t want, int fail) { pipe_t *p = calloc(1, sizeof *p); p->want = want; p->fail = fail; g_made++; g_failed += fail != 0; return p; }
static void submit(pipe_t *p);
static void compiled(pipe_t *p) {   // the handler: stores the pipeline state, then finishes; its slot goes to the next queued compile
    p->pso = p->fail ? 0 : p->want;
    if (vkp_finish(&g_pp, &p->pend, p->fail, vkp_clock())) { g_by_handler++; pipe_free(p); }
    vkp_t *n = vkp_end(&g_pp, 1);
    if (n) submit(PIPE_OF(n));
}
static void drawn(pipe_t *p, void (*slow)(uint64_t, uint32_t)) { vkp_wait(&g_pp, &p->pend, slow); g_drawn++; g_drawn_ok += p->pso == (p->fail ? 0 : p->want); }

// Metal's compiler: a queue of compiles, finished by workers after a short random time each, newest first
typedef struct job { struct job *next; pipe_t *p; } job_t;
static job_t *g_q; static pthread_mutex_t g_qmu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_qcv = PTHREAD_COND_INITIALIZER; static int g_qstop;
static _Thread_local unsigned t_seed;
static unsigned rnd(void) { t_seed = t_seed * 1103515245u + 12345u; return t_seed >> 8; }
static void submit(pipe_t *p) {
    job_t *j = malloc(sizeof *j); j->p = p;
    pthread_mutex_lock(&g_qmu); j->next = g_q; g_q = j; pthread_cond_signal(&g_qcv); pthread_mutex_unlock(&g_qmu);
}
static void *compiler(void *arg) {
    t_seed = (unsigned)(uintptr_t)arg * 2654435761u;
    for (;;) {
        pthread_mutex_lock(&g_qmu);
        while (!g_q && !g_qstop) pthread_cond_wait(&g_qcv, &g_qmu);
        if (!g_q) { pthread_mutex_unlock(&g_qmu); return NULL; }
        job_t *j = g_q; g_q = j->next;
        pthread_mutex_unlock(&g_qmu);
        pipe_t *p = j->p; free(j);
        if (rnd() % 4 == 0) usleep(rnd() % 300);
        compiled(p);
    }
}
static void compilers_start(pthread_t *c, int n) { g_qstop = 0; for (int i = 0; i < n; i++) pthread_create(&c[i], NULL, compiler, (void *)(uintptr_t)(i + 1)); }
static void compilers_stop(pthread_t *c, int n) {
    pthread_mutex_lock(&g_qmu); g_qstop = 1; pthread_cond_broadcast(&g_qcv); pthread_mutex_unlock(&g_qmu);
    for (int i = 0; i < n; i++) pthread_join(c[i], NULL);
}

static _Atomic int g_slow_calls;
static void slow(uint64_t w, uint32_t n) { (void)n; CHECK(w > VKP_SLOW_NS, "slow called after %llu ns", (unsigned long long)w); g_slow_calls++; }

// A game thread: creates pipelines (each compile goes to the queue), and destroys each at once, draws with it first, or keeps it a while and destroys it later
#define PER_THREAD 20000
static void *game(void *arg) {
    t_seed = (unsigned)(uintptr_t)arg * 40503u + 7;
    pipe_t *kept[64]; int nk = 0;
    for (int i = 0; i < PER_THREAD; i++) {
        uint64_t t = vkp_clock();
        pipe_t *p = pipe_new(((uint64_t)(uintptr_t)arg << 32) | (uint64_t)i << 1 | 1, rnd() % 16 == 0);
        vkp_begin(&g_pp, &p->pend, t);
        if (vkp_start(&g_pp, &p->pend, 1)) submit(p); else g_queued++;
        vkp_create(&g_pp, vkp_clock() - t);
        switch (rnd() % 4) {
            case 0: if (vkp_drop(&p->pend)) pipe_free(p); break;   // destroyed right after it was created
            case 1: if (rnd() & 1) vkp_hurry(&g_pp, &p->pend);   // a submission's first pass (pipe_wait_sub)
                drawn(p, slow); if (vkp_drop(&p->pend)) pipe_free(p); break;   // a draw at first use
            default:   // kept, destroyed later (its compile has often ended by then)
                if (nk == 64) { int k = rnd() % 64; if (vkp_drop(&kept[k]->pend)) pipe_free(kept[k]); kept[k] = p; } else kept[nk++] = p;
        }
    }
    for (int k = 0; k < nk; k++) { drawn(kept[k], slow); if (vkp_drop(&kept[k]->pend)) pipe_free(kept[k]); }
    return NULL;
}
// The [vk] pipelines line, taken while the game threads run, as frame_end does (quiet 0 here: whenever nothing is in flight)
static _Atomic int g_run; static vkp_rec g_sum; static uint32_t g_lim;
static void sum_add(const vkp_rec *r) { g_sum.n += r->n; g_sum.nfail += r->nfail; g_sum.nwait += r->nwait; if (r->peak_run > g_sum.peak_run) g_sum.peak_run = r->peak_run; }
static void *reporter(void *arg) {
    (void)arg;
    while (g_run) {
        vkp_rec r;
        if (vkp_take(&g_pp, vkp_clock(), 0, &r)) {
            sum_add(&r);
            CHECK(r.peak >= 1 && r.last >= r.first && r.nfail <= r.n && r.wait_max <= r.wait_ns && r.peak_run <= r.peak && (!g_lim || r.peak_run <= g_lim), "a burst's counters");
        }
        usleep(50);
    }
    return NULL;
}
static void stress(int ngame, int ncomp, uint32_t lim) {   // lim: compiles at the compiler at once, 0 none
    pthread_t c[16], gt[16], rt; g_run = 1;
    memset(&g_sum, 0, sizeof g_sum); g_lim = lim; vkp_set_limit(&g_pp, lim);
    uint64_t made = g_made, failed = g_failed, total = g_pp.b.total, byh = g_by_handler, queued = g_queued;
    compilers_start(c, ncomp);
    pthread_create(&rt, NULL, reporter, NULL);
    for (int i = 0; i < ngame; i++) pthread_create(&gt[i], NULL, game, (void *)(uintptr_t)(i + 1));
    for (int i = 0; i < ngame; i++) pthread_join(gt[i], NULL);
    vkp_wait_all(&g_pp);   // vkDestroyDevice
    g_run = 0; pthread_join(rt, NULL);
    compilers_stop(c, ncomp);
    vkp_rec r; if (vkp_take(&g_pp, vkp_clock(), 0, &r)) sum_add(&r);
    CHECK(g_pp.inflight == 0 && g_pp.waiting == 0 && g_pp.running == 0 && !g_pp.qhead && !g_pp.qtail, "nothing in flight, at the compiler, queued or asleep after vkp_wait_all");
    CHECK(g_sum.n == g_made - made && g_pp.b.total - total == g_made - made, "%d game threads, %d compilers, limit %u: every compile counted once in the records (%llu of %llu)", ngame,
          ncomp, lim, (unsigned long long)g_sum.n, (unsigned long long)(g_made - made));
    CHECK(!lim || (g_queued > queued && g_sum.peak_run <= lim), "with a limit, compiles were queued (%llu) and at most %u at the compiler (%u)", (unsigned long long)(g_queued - queued),
          lim, g_sum.peak_run);
    CHECK(g_sum.nfail == g_failed - failed, "and every failure (%llu of %llu)", (unsigned long long)g_sum.nfail, (unsigned long long)(g_failed - failed));
    CHECK(g_freed == g_made, "every pipeline freed exactly once (%llu made, %llu freed)", (unsigned long long)g_made, (unsigned long long)g_freed);
    CHECK(g_drawn == g_drawn_ok, "every draw read the state its handler stored (%llu of %llu)", (unsigned long long)g_drawn_ok, (unsigned long long)g_drawn);
    CHECK(g_sum.nwait && g_by_handler > byh, "both paths taken: draws asleep on a compile (%llu), pipelines freed by their handler (%llu)", (unsigned long long)g_sum.nwait,
          (unsigned long long)(g_by_handler - byh));
    printf("%d game threads, %d compilers, limit %u: %llu pipelines, %llu queued, %llu draws asleep on a compile, %llu pipelines freed by their handler\n", ngame, ncomp, lim,
           (unsigned long long)(g_made - made), (unsigned long long)(g_queued - queued), (unsigned long long)g_sum.nwait, (unsigned long long)(g_by_handler - byh));
}

static pipe_t *g_late;
static void *late(void *arg) {   // a handler 30-120 ms late, which takes 20 ms more to free a destroyed pipeline: vkp_wait_all must wait for that too
    usleep((useconds_t)(uintptr_t)arg);
    pipe_t *p = g_late; p->pso = p->fail ? 0 : p->want;
    if (vkp_finish(&g_pp, &p->pend, p->fail, vkp_clock())) { usleep(20000); g_by_handler++; pipe_free(p); }
    vkp_end(&g_pp, 0);
    return NULL;
}

static void *drawer(void *arg) { drawn(arg, slow); return NULL; }   // a submission that waits for a queued pipeline
static _Atomic int g_prog_run; static _Atomic uint64_t g_prog_gap;
static void *progress(void *arg) {   // other pipelines' compiles ending every 5 ms (Metal working through a long queue); the longest gap between two
    (void)arg; uint64_t last = vkp_clock();
    while (g_prog_run) {
        usleep(5000);
        pipe_t q = {0}; vkp_begin(&g_pp, &q.pend, vkp_clock()); vkp_finish(&g_pp, &q.pend, 0, vkp_clock()); vkp_end(&g_pp, 0);
        uint64_t now = vkp_clock(); if (now - last > g_prog_gap) g_prog_gap = now - last; last = now;
    }
    return NULL;
}
static uint32_t asleep(void) { pthread_mutex_lock(&g_pp.mu); uint32_t n = g_pp.waiting; pthread_mutex_unlock(&g_pp.mu); return n; }

int main(void) {
    alarm(600);   // a lost wake-up hangs: fail instead
    // One pipeline, step by step
    {
        pipe_t p = {0};
        CHECK(vkp_drop(&p.pend), "a pipeline that never compiled is freed by vkDestroyPipeline (zalloc's zero)");
        vkp_wait(&g_pp, &p.pend, slow);   // and a draw does not wait for it
        pipe_t q = {0}; vkp_begin(&g_pp, &q.pend, 100);
        CHECK(!vkp_drop(&q.pend), "destroyed while compiling: vkDestroyPipeline leaves it to the handler");
        CHECK(vkp_finish(&g_pp, &q.pend, 0, 300), "and the handler frees it"); vkp_end(&g_pp, 0);
        pipe_t s = {0}; vkp_begin(&g_pp, &s.pend, 400);
        CHECK(!vkp_finish(&g_pp, &s.pend, 1, 1000), "compiled first (DM_VK_PSO_ASYNC=0: on the creating thread): the handler leaves it to the game"); vkp_end(&g_pp, 0);
        vkp_wait(&g_pp, &s.pend, slow);
        CHECK(vkp_drop(&s.pend), "then vkDestroyPipeline frees it");
        vkp_rec r;
        CHECK(!vkp_take(&g_pp, 1100, 500, &r), "no record before the burst has been quiet for 500");
        CHECK(!vkp_take(&g_pp, 900, 0, &r), "a time before the last finish (a clock read before another thread's finish) does not count as quiet");
        CHECK(vkp_take(&g_pp, 1500, 500, &r) && r.n == 2 && r.nfail == 1 && r.first == 100 && r.last == 1000 && r.sum == 200 + 600 && r.peak == 1 && r.nwait == 0 && r.total == 2,
              "the burst: 2 compiles, 1 failed, from 100 to 1000, 800 in all, 1 in flight at most");
        CHECK(!vkp_take(&g_pp, 5000, 0, &r), "taken once");
        pipe_t a = {0}, b = {0}; vkp_begin(&g_pp, &a.pend, 2000); vkp_begin(&g_pp, &b.pend, 2100); vkp_create(&g_pp, 150);
        vkp_finish(&g_pp, &a.pend, 0, 2200); vkp_end(&g_pp, 0);
        CHECK(!vkp_take(&g_pp, 9000, 0, &r), "no record while a compile is in flight");
        vkp_finish(&g_pp, &b.pend, 0, 2300);
        CHECK(!vkp_take(&g_pp, 9000, 0, &r), "nor before its handler's vkp_end"); vkp_end(&g_pp, 0);
        CHECK(vkp_take(&g_pp, 9000, 0, &r) && r.n == 2 && r.peak == 2 && r.first == 2000 && r.last == 2300 && r.create_ns == 150 && r.total == 4,
              "the next burst: 2 at once, from its own first begin; total goes on");
    }
    // A draw that waits for a compile another thread ends 120 ms later, no other compile ending meanwhile: it sleeps, reads the state, its wait is counted, and reported
    // once (no compile ended for VKP_SLOW_NS)
    {
        g_late = pipe_new(77, 0); vkp_begin(&g_pp, &g_late->pend, vkp_clock());
        pipe_t *p = g_late; int before = g_slow_calls; uint64_t t = vkp_clock();
        pthread_t th; pthread_create(&th, NULL, late, (void *)(uintptr_t)120000);
        drawn(p, slow);
        uint64_t w = vkp_clock() - t;
        pthread_join(th, NULL);
        CHECK(w >= 100000000ull && w < 600000000ull, "the draw waited for the compile, and woke at its end, not at the next 1 s step (%llu ns)", (unsigned long long)w);
        CHECK(g_slow_calls - before == 1, "the wait with no compile ending for 50 ms was reported once (%d)", g_slow_calls - before);
        vkp_rec r; CHECK(vkp_take(&g_pp, vkp_clock(), 0, &r) && r.n == 1 && r.nwait == 1 && r.wait_ns >= 100000000ull && r.wait_max == r.wait_ns, "and counted");
        CHECK(vkp_drop(&p->pend), "freed by vkDestroyPipeline"); pipe_free(p);
        // the same compile, destroyed while it runs: the handler frees it, vkDestroyDevice waits for it
        g_late = pipe_new(78, 1); vkp_begin(&g_pp, &g_late->pend, vkp_clock());
        CHECK(!vkp_drop(&g_late->pend), "destroyed while compiling");
        pthread_create(&th, NULL, late, (void *)(uintptr_t)30000);
        vkp_wait_all(&g_pp);
        CHECK(g_pp.inflight == 0 && g_freed == g_made, "vkp_wait_all returns once the handler has freed it (vkp_end comes after the free)");
        pthread_join(th, NULL);
        CHECK(vkp_take(&g_pp, vkp_clock(), 0, &r) && r.n == 1 && r.nfail == 1, "a failed compile is counted");
    }
    // The queue, step by step: limit 1, so one compile at the compiler and the others queued in creation order, one a submission hurries first
    {
        vkp_set_limit(&g_pp, 1);
        pipe_t a = {0}, b = {0}, c = {0}, d = {0}; vkp_rec r;
        vkp_begin(&g_pp, &a.pend, 10000); vkp_begin(&g_pp, &b.pend, 10001); vkp_begin(&g_pp, &c.pend, 10002); vkp_begin(&g_pp, &d.pend, 10003);
        CHECK(vkp_start(&g_pp, &a.pend, 1) && !vkp_start(&g_pp, &b.pend, 1) && !vkp_start(&g_pp, &c.pend, 1) && !vkp_start(&g_pp, &d.pend, 1), "limit 1: the first at the compiler, the others queued");
        CHECK(!vkp_idle(&g_pp), "not idle while compiles are queued");
        vkp_hurry(&g_pp, &c.pend);   // from the middle: c b d
        vkp_hurry(&g_pp, &d.pend);   // from the tail: d c b
        vkp_hurry(&g_pp, &d.pend);   // already first
        vkp_finish(&g_pp, &a.pend, 0, 10010);
        CHECK(vkp_end(&g_pp, 1) == &d.pend, "a's slot goes to d, the last a submission hurried");
        vkp_finish(&g_pp, &d.pend, 0, 10020);
        CHECK(vkp_end(&g_pp, 1) == &c.pend, "then c, hurried before it");
        vkp_finish(&g_pp, &c.pend, 0, 10030);
        CHECK(vkp_end(&g_pp, 1) == &b.pend, "then b");
        vkp_finish(&g_pp, &b.pend, 0, 10040);
        CHECK(vkp_end(&g_pp, 1) == NULL && vkp_idle(&g_pp) && !g_pp.qhead && !g_pp.qtail && g_pp.running == 0, "then none, and idle");
        CHECK(vkp_take(&g_pp, 20000, 0, &r) && r.n == 4 && r.peak == 4 && r.peak_run == 1, "4 in flight at most, 1 at the compiler");
        // the creating thread's own compile (queue 0) takes a slot past the limit; the queue then waits until the slots are back under it
        pipe_t e = {0}, f = {0}, h = {0};
        vkp_begin(&g_pp, &e.pend, 30000); vkp_begin(&g_pp, &f.pend, 30001); vkp_begin(&g_pp, &h.pend, 30002);
        CHECK(vkp_start(&g_pp, &e.pend, 1) && vkp_start(&g_pp, &f.pend, 0) && !vkp_start(&g_pp, &h.pend, 1), "queue 0 always starts, past the limit");
        vkp_finish(&g_pp, &e.pend, 0, 30010);
        CHECK(vkp_end(&g_pp, 1) == NULL, "one slot back, still at the limit: h waits");
        vkp_finish(&g_pp, &f.pend, 0, 30020);
        CHECK(vkp_end(&g_pp, 1) == &h.pend, "the next slot goes to h");
        pipe_t k = {0}; vkp_begin(&g_pp, &k.pend, 30030); CHECK(!vkp_start(&g_pp, &k.pend, 1), "queued behind h");
        pipe_t m = {0}; vkp_begin(&g_pp, &m.pend, 30031); vkp_finish(&g_pp, &m.pend, 1, 30032);
        CHECK(vkp_end(&g_pp, 0) == NULL, "a compile that never had a slot (DM_VK_PSO_ASYNC: no vertex shader) gives none");
        vkp_finish(&g_pp, &h.pend, 0, 30040);
        CHECK(vkp_end(&g_pp, 1) == &k.pend, "h's goes to k");
        vkp_finish(&g_pp, &k.pend, 0, 30050); CHECK(vkp_end(&g_pp, 1) == NULL && vkp_idle(&g_pp), "and idle again");
        CHECK(vkp_take(&g_pp, 40000, 0, &r) && r.n == 5 && r.nfail == 1 && r.peak_run == 2, "5 compiles, 2 at the compiler at most (one past the limit)");
        // a draw that waits for a queued pipeline moves it to the front: the next slot is its own
        pipe_t *x = pipe_new(80, 0), *y = pipe_new(81, 0), *z = pipe_new(82, 0);
        vkp_begin(&g_pp, &x->pend, vkp_clock()); vkp_begin(&g_pp, &y->pend, vkp_clock()); vkp_begin(&g_pp, &z->pend, vkp_clock());
        CHECK(vkp_start(&g_pp, &x->pend, 1) && !vkp_start(&g_pp, &y->pend, 1) && !vkp_start(&g_pp, &z->pend, 1), "x at the compiler, y z queued");
        pthread_t th; pthread_create(&th, NULL, drawer, z);
        for (int i = 0; i < 5000 && !asleep(); i++) usleep(1000);
        CHECK(asleep() == 1, "the draw sleeps on z");
        x->pso = x->want; vkp_finish(&g_pp, &x->pend, 0, vkp_clock());
        CHECK(vkp_end(&g_pp, 1) == &z->pend, "x's slot goes to z, which a draw waits for, not y");
        z->pso = z->want; vkp_finish(&g_pp, &z->pend, 0, vkp_clock());
        CHECK(vkp_end(&g_pp, 1) == &y->pend, "then y");
        pthread_join(th, NULL);
        y->pso = y->want; vkp_finish(&g_pp, &y->pend, 0, vkp_clock()); CHECK(vkp_end(&g_pp, 1) == NULL, "none left");
        CHECK(vkp_drop(&x->pend) && vkp_drop(&y->pend) && vkp_drop(&z->pend), "all three freed by vkDestroyPipeline"); pipe_free(x); pipe_free(y); pipe_free(z);
        CHECK(vkp_take(&g_pp, vkp_clock(), 0, &r) && r.n == 3 && r.nwait == 1, "the draw's wait counted");
        vkp_set_limit(&g_pp, 0);
    }
    // A wait behind a queue that keeps moving (another compile ends every 5 ms) for 200 ms, four times VKP_SLOW_NS: not reported. The one above, with no compile ending, is
    {
        pipe_t *p = pipe_new(83, 0); vkp_begin(&g_pp, &p->pend, vkp_clock());
        int before = g_slow_calls; g_prog_run = 1; g_prog_gap = 0; g_late = p;
        pthread_t pt, th; pthread_create(&pt, NULL, progress, NULL); pthread_create(&th, NULL, late, (void *)(uintptr_t)200000);
        drawn(p, slow);
        pthread_join(th, NULL); g_prog_run = 0; pthread_join(pt, NULL);
        if (g_prog_gap < VKP_SLOW_NS / 2) CHECK(g_slow_calls == before, "a long wait while compiles keep ending is not reported (%d)", g_slow_calls - before);
        else printf("the wait with progress not checked: this machine left %.0f ms between two compiles\n", g_prog_gap / 1e6);
        vkp_rec r = {0}; CHECK(vkp_take(&g_pp, vkp_clock(), 0, &r) && r.nwait == 1 && r.wait_ns >= 150000000ull, "the wait counted (%.0f ms)", r.wait_ns / 1e6);   // {0}: the message reads it when vkp_take fails
        CHECK(vkp_drop(&p->pend), "freed by vkDestroyPipeline"); pipe_free(p);
    }
    stress(4, 3, 6);   // twice the compiler's workers, as hle_vk.m sets it
    stress(3, 1, 2);   // one worker: Metal running one compile at a time
    stress(1, 8, 0);   // no limit
    stress(4, 4, 1);   // one at a time: the longest queue
    printf("vk_pending: %d checks, %d failed (%llu pipelines, %llu drawn)\n", checks, fails, (unsigned long long)g_made, (unsigned long long)g_drawn);
    return fails != 0;
}
