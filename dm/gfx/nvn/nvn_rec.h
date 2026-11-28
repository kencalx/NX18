// Deferred encoding (DM_NVN_ENC_THREAD=1; included by nvn_mtl.m only): the replay's Metal encoding runs on a worker thread while the submit thread goes on translating.
// About 40% of the submit thread's time was spent inside Metal itself: encoder creation, draw calls, state setters and argument table writes (Breath of the Wild: about 2.7 of 6.5 ms a frame).
// With this switch the replay talks to stand-ins for the main command buffer, its encoders and the argument tables it rewrites per draw. Each call becomes a fixed-size record (objects retained);
// records go to the encode thread in blocks, and the encode thread makes the same calls in the same order on the real objects. Commits of the main command buffer and of upload batches, and
// event signals, are records too, so the queue sees work in exactly the order it did before. The submit thread waits for the encode thread to finish (rec_drain) before anything that waits for
// the GPU or uses another queue, so nothing outside the submission can tell the difference; at the end of a submission it only hands its records over with a note of its fence (nvn_mtl.m
// mtl_sub_commit, g_sub_cmt), which a present of the game's own texture waits for (DM_NVN_SUB_DRAIN=1 drains there as before). A submission that ends while the GPU still has work
// may be held and committed with later ones (DM_NVN_SUB_MERGE, below).
// Everything else the replay creates (textures, views, pipelines, buffers, residency) stays on the submit thread: device calls, safe from any thread. Queue commits take the residency lock,
// since the submit thread may be adding to the set at the same time.
// A selector the stand-ins do not implement stops the host with its name (forwardingTargetForSelector), so a missing one cannot silently drop work.

// ---------- Copy queue: large uniform shadows (ubp_get) are filled by a worker thread ----------
// A shadow is the bytes of a uniform range as the GPU will read them at that point of the submission (nvn_mtl.m ubp_get): memory, or the previous shadow of the range, with the inline
// updates queued since laid over it. Breath of the Wild makes about 440 a frame, 14 MB of copies, a tenth of the submit thread's time. The submit thread queues the copies in order and
// goes on; one worker makes them in the same order (a shadow may start from the previous one). The GPU reads shadows only after its command buffer is committed, and every commit first
// waits for the copies queued before it (ubc_wait, from the encode thread when Metal encoding is deferred); a CPU read of a shadow waits for its own copies. DM_NVN_UB_COPY_THREAD=0
// copies on the submit thread as before
// Hand-off: the copy thread sleeps on g_ubc_head and a waiter on g_ubc_done (os_sync_wait_on_address: the kernel compares the word, so a change before the sleep is not lost),
// each woken only by the thread that advanced that word, after it did. A waker never clears the sleeper's flag; the sleeper does, once awake. A push whose wake call comes late
// can meet the flag the thread set for its next sleep, on a word that already includes that push: had the call taken the flag, the thread would sleep with it clear, the next
// push would not wake it and every later wait would hang (the waiting thread's commit never made, its fence never signalled). Waiters are counted for the same reason.
// No mutex: before, ubc_wait locked a mutex and signalled a condition on every spin while the thread slept, and the woken thread could not get that mutex back. Ocarina of
// Time on one build: the replay thread spent half its busy time there, the copy thread waited for the mutex 9 times as long as it copied, and translation took 170-330k
// instructions a draw against 32-48k
#include "../../host/dm_spin.h"   // the short waits' WFET (DM_HOST_SPIN)
typedef struct { void *d; const void *s; size_t n; } ubc_op;
// The short waits on either side spin on WFET (DM_HOST_SPIN, dm_spin.h): the core stops until the watched word's line is written, at the yield spin's wake latency and about a
// half of its energy (M4 Max, t_host_spin: wake p50 42-83 ns; 32 against 57 µJ per 5 µs wait). They are bounded in time now, not in passes: UBC_SPIN yields took 1.7 µs on an
// M4 Max P core and 4-8 µs on its E cores, the copy thread's 2000 loads 0.8 / 2.2 µs. DM_HOST_SPIN=0 keeps the passes. A blocked thread's wake took 5.5 µs (p50) there, so a wait
// past the spin blocks as before. t_ubc_wait's replay-shaped run (30 submissions a frame, 15 copies of 1-64 KB each): 85-90% of the commits' waits end within 5 µs, 1.2-1.6 a frame
// sleep; the process's energy 0.76 mJ a frame against 1.34 with the yield spin, the copy thread's polls finding the next push 201 times a frame against 133 (it slept 92 against 147)
// DM_NVN_WAITS=1 counts the waits by length and the copy thread's polls in the [waits] line (ubc_stats)
enum { UBC_N = 8192, UBC_SPIN = 4096, UBC_SPIN_NS = 4000,   // UBC_SPIN_NS: "4 µs" in ubc_stats' text
       UBC_POLL = 2000, UBC_POLL_NS = 2000 };   // a waiter's spin before it sleeps (the copies it waits for are usually a few KB); the copy thread's poll after a burst
static ubc_op g_ubc[UBC_N];
static _Alignas(128) _Atomic uint64_t g_ubc_head;   // ops queued (monotonic; the copy thread sleeps on it)
static _Alignas(128) _Atomic uint64_t g_ubc_done;   // ops made (a waiter sleeps on it)
static _Alignas(128) _Atomic uint32_t g_ubc_sleeping, g_ubc_waiting;   // the copy thread is asleep or about to be (it clears this itself) / waiters asleep or about to be
static _Alignas(128) _Atomic uint64_t g_ubc_wakes;   // wake calls made, both ways (t_ubc_wait)
// DM_NVN_WAITS=1: ubc_wait's waits that did not return at once, by length (<1, <2, <5, <10, <50, <500, more µs) and those that slept; the copy thread's polls after a burst that found
// the next push (and of them within 1 µs) or went to sleep (counted always: the copy thread's own words)
static _Atomic uint64_t g_ubc_hist[7], g_ubc_slept, g_ubc_poll_hit, g_ubc_poll_fast, g_ubc_poll_miss;
static inline void ubc_hist(uint64_t ns, int slept) {
    uint64_t us = ns / 1000; int b = us < 1 ? 0 : us < 2 ? 1 : us < 5 ? 2 : us < 10 ? 3 : us < 50 ? 4 : us < 500 ? 5 : 6;
    atomic_fetch_add_explicit(&g_ubc_hist[b], 1, memory_order_relaxed); if (slept) atomic_fetch_add_explicit(&g_ubc_slept, 1, memory_order_relaxed);
}
#ifndef UBC_T_SLEEPING   // t_ubc_wait: holds the copy thread on its way to sleep, so that a late wake call lands there
#define UBC_T_SLEEPING() ((void)0)
#endif
static int ubc_on(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_NVN_UB_COPY_THREAD"); v = !(e && !strcmp(e, "0")); } return v; }
// Wake the copy thread if it sleeps; only ubc_push, after its store to g_ubc_head (pushes between the wake and the thread clearing its flag make a call each, harmless)
static inline void ubc_kick(void) {
    if (atomic_load(&g_ubc_sleeping)) { atomic_fetch_add_explicit(&g_ubc_wakes, 1, memory_order_relaxed); os_sync_wake_by_address_any(&g_ubc_head, sizeof g_ubc_head, OS_SYNC_WAKE_BY_ADDRESS_NONE); }
}
static void *ubc_thread(void *arg) {
    (void)arg; pthread_setname_np("dm-ub-copy"); pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    for (uint64_t t = 0;;) {
        uint64_t h = atomic_load_explicit(&g_ubc_head, memory_order_acquire);
        if (t == h) {   // a submission queues copies in bursts: stay awake a moment (WFET on g_ubc_head, or UBC_POLL loads with DM_HOST_SPIN=0)
            uint64_t p0 = ws_t0(); h = dm_spin_ne64(&g_ubc_head, t, UBC_POLL_NS, UBC_POLL);
            if (h != t) { atomic_fetch_add_explicit(&g_ubc_poll_hit, 1, memory_order_relaxed); if (ws_t0() - p0 < 1000) atomic_fetch_add_explicit(&g_ubc_poll_fast, 1, memory_order_relaxed); }
            else atomic_fetch_add_explicit(&g_ubc_poll_miss, 1, memory_order_relaxed);
        }
        while (t == h) {   // the flag first, then the word (both sequentially consistent, as the pusher's store and flag load): a push sees the flag or this sees the push
            atomic_store(&g_ubc_sleeping, 1);
            if ((h = atomic_load(&g_ubc_head)) != t) break;
            UBC_T_SLEEPING();
            os_sync_wait_on_address(&g_ubc_head, t, sizeof g_ubc_head, OS_SYNC_WAIT_ON_ADDRESS_NONE);   // returns at once if the word is no longer t; EINTR and spurious returns loop
            atomic_store(&g_ubc_sleeping, 0);   // awake: set again before the next sleep's look at the word
            h = atomic_load(&g_ubc_head);
        }
        if (atomic_load_explicit(&g_ubc_sleeping, memory_order_relaxed)) atomic_store_explicit(&g_ubc_sleeping, 0, memory_order_relaxed);   // also when the look found a push; a store only when set (the line is the submit thread's to read on every push)
        for (; t < h; t++) { const ubc_op *o = &g_ubc[t % UBC_N]; memcpy(o->d, o->s, o->n); }
        atomic_store(&g_ubc_done, t);
        if (atomic_load(&g_ubc_waiting)) { atomic_fetch_add_explicit(&g_ubc_wakes, 1, memory_order_relaxed); os_sync_wake_by_address_all(&g_ubc_done, sizeof g_ubc_done, OS_SYNC_WAKE_BY_ADDRESS_NONE); }
    }
    return NULL;
}
// Wait until the first seq ops are made (the replay thread, or the encode thread at a commit): spin a moment, then sleep on g_ubc_done. The sleep ends at the 10 s mark once
// (os_sync_wait_on_address_with_timeout, up to the mark only) to say it with the site (nvn_mtl.m wait_say); a waker's call finds it asleep as before, and after the mark it is the
// plain sleep again. A timed-out sleep is a spurious return to this loop
static void ubc_wait_at(uint64_t seq, const char *site) {
    if (atomic_load_explicit(&g_ubc_done, memory_order_acquire) >= seq) return;
    uint64_t w0 = ws_t0(); wait_mark m = {0, 1}; int slept = 0;
    // the copies are queued, so the copy thread is awake or woken by their push: a short spin first (dm_spin.h), then sleep
    if (!dm_spin_ge64(&g_ubc_done, seq, UBC_SPIN_NS, UBC_SPIN)) for (;;) {
        if (!slept) { slept = 1; wait_mark_set(&m); }
        atomic_fetch_add(&g_ubc_waiting, 1);   // counted first, then the word (as the copy thread's store and count load): it sees this waiter or this sees its store
        uint64_t d = atomic_load(&g_ubc_done), left = m.told ? 0 : wait_mark_left(&m);
        if (d < seq) {
            if (m.told) os_sync_wait_on_address(&g_ubc_done, d, sizeof g_ubc_done, OS_SYNC_WAIT_ON_ADDRESS_NONE);
            else if (left) os_sync_wait_on_address_with_timeout(&g_ubc_done, d, sizeof g_ubc_done, OS_SYNC_WAIT_ON_ADDRESS_NONE, OS_CLOCK_MACH_ABSOLUTE_TIME, left);
        }
        atomic_fetch_sub(&g_ubc_waiting, 1);
        if (atomic_load_explicit(&g_ubc_done, memory_order_acquire) >= seq) break;
        if (wait_mark_due(&m)) {
            static _Atomic int n;
            wait_say(&n, "the uniform copies", site, "up to op %llu: made %llu of %llu queued; the copy thread %s", (unsigned long long)seq, (unsigned long long)atomic_load(&g_ubc_done),
                     (unsigned long long)atomic_load(&g_ubc_head), atomic_load(&g_ubc_sleeping) ? "sleeps" : "is awake");
        }
    }
    if (ws_on()) { ws_put(WS_UBC, w0, 1); ubc_hist(ws_t0() - w0, slept); }
}
#define ubc_wait(seq) ubc_wait_at(seq, LOCK_SITE)
// The [waits] line's part for the uniform copies (ws_report, DM_NVN_WAITS=1): the waits by length and the copy thread's polls since the last line, per frame
static size_t ubc_stats(char *out, size_t n, uint64_t frames) {
    uint64_t h[7], sl = atomic_exchange(&g_ubc_slept, 0), ph = atomic_exchange(&g_ubc_poll_hit, 0), pf = atomic_exchange(&g_ubc_poll_fast, 0), pm = atomic_exchange(&g_ubc_poll_miss, 0), all = 0;
    for (int i = 0; i < 7; i++) { h[i] = atomic_exchange(&g_ubc_hist[i], 0); all += h[i]; }
    if (!all && !ph && !pm) return 0;
    double f = frames ? (double)frames : 1;
    int w = snprintf(out, n, " uniform copy waits by length <1 µs %.2f / <2 %.2f / <5 %.2f / <10 %.2f / <50 %.2f / <500 %.2f / more %.2f (slept %.2f; spin: %s), copy thread polls after a burst found the next push %.2f (within 1 µs %.2f), went to sleep %.2f;",
                     h[0] / f, h[1] / f, h[2] / f, h[3] / f, h[4] / f, h[5] / f, h[6] / f, sl / f, dm_spin_wfet() ? "WFET up to 4 µs" : "4096 yields", ph / f, pf / f, pm / f);
    return w <= 0 ? 0 : (size_t)w < n ? (size_t)w : n - 1;
}
static inline uint64_t ubc_head(void) { return atomic_load_explicit(&g_ubc_head, memory_order_relaxed); }
// Queue a copy (submit thread only); returns the count of ops that must be made for it to be done
static uint64_t ubc_push(void *d, const void *s, size_t n) {
    static int started;
    if (!started) { pthread_t th; if (pthread_create(&th, NULL, ubc_thread, NULL)) MDIE("cannot start the uniform copy thread"); pthread_detach(th); started = 1; }
    uint64_t h = atomic_load_explicit(&g_ubc_head, memory_order_relaxed);
    if (h - atomic_load_explicit(&g_ubc_done, memory_order_acquire) >= UBC_N) ubc_wait(h - UBC_N + 1);
    g_ubc[h % UBC_N] = (ubc_op){d, s, n};
    atomic_store(&g_ubc_head, h + 1);
    ubc_kick();
    return h + 1;
}

enum {
    RO_CB_NEW, RO_CB_BEGIN, RO_CB_END, RO_COMMIT, RO_COMMIT_REAL, RO_SIGNAL, RO_CB_BLOCK, RO_Q_BLOCK,
    RO_RE_BEGIN, RO_CE_BEGIN, RO_END,
    RO_BAR_QUEUE, RO_BAR_AFTER_STAGES, RO_BAR_ENCODER,
    RO_R_TABLE, RO_R_PSO, RO_R_DSS, RO_R_VIEWPORT, RO_R_SCISSOR, RO_R_CULL, RO_R_WINDING, RO_R_FILL, RO_R_BIAS, RO_R_CLIP, RO_R_DBND, RO_R_SREF, RO_R_BLEND, RO_R_VIS, RO_R_AMP, RO_R_CMAP,
    RO_R_DRAW, RO_R_DRAW_INST, RO_R_DRAW_IND, RO_R_DRAW_IDX, RO_R_DRAW_IDX_IND, RO_R_MESH, RO_R_MESH_IND, RO_R_STORE_C, RO_R_STORE_D, RO_R_STORE_S,
    RO_C_TABLE, RO_C_PSO, RO_C_DISPATCH, RO_C_DISPATCH_IND, RO_C_COPY_BB, RO_C_COPY_BT, RO_C_COPY_BT_OPT, RO_C_COPY_TB, RO_C_COPY_TB_OPT, RO_C_COPY_TT, RO_C_FILL,
    RO_T_ADDR, RO_T_TEX, RO_T_SAMP,
    RO_LABEL, RO_R_TS, RO_C_TS,   // diagnostics: DM_NVN_ENC_LABEL, DM_NVN_GPUPROF
    RO_NOTE,   // a[0] an _Atomic uint64_t, a[1] a value: the encode thread has made every call before this one (rec_note_wait)
    RO_FLUSH,   // the held submissions go to the queue here (rec_flush_held: a present of the game's own texture)
};
typedef struct { uint32_t op, nobj; uint64_t a[15]; } rec_t;   // the first nobj slots hold retained objects (0 for nil), released once the call is made
enum { REC_BLK_OLD = 256, REC_BLK_DEFAULT = 1024, REC_BLK_MAX = 2048, REC_ALIGN = 128 };
// A record is one 128-byte cache line of Apple's cores, written by the submit thread and read by the encode thread: r[] starts on a line (it was at offset 16, so every record
// spanned two lines and each line moved between the cores twice), and blocks are allocated on a line (rec_blk_new: posix_memalign; malloc promises 16 bytes)
typedef struct rec_blk { struct rec_blk *next; int n; _Alignas(REC_ALIGN) rec_t r[]; } rec_blk;
_Static_assert(sizeof(rec_t) == REC_ALIGN && offsetof(rec_blk, r) % REC_ALIGN == 0, "a record is one cache line, and r[] starts on one");
// Records a block holds: DM_NVN_REC_BLK=<n> (16 to 2048; 0: 256, the old size), read once before the first block. A block goes to the encode thread when it is full, at a commit, a cut
// segment or a drain, and each hand-over to a sleeping encode thread is a wake (g_rb_wakes, the threads line). Upstream NXNative 6ccaca8e2 went from 256 to 2048; NX 18 takes 1024 by
// default, as a larger block also starts the encode thread later in a submission, so more of a submission's encoding is left after its commit
static int g_rec_blk;
static int rec_blk_n(void) {
    if (__builtin_expect(g_rec_blk > 0, 1)) return g_rec_blk;
    const char *e = getenv("DM_NVN_REC_BLK"); int v = e && *e ? atoi(e) : REC_BLK_DEFAULT; if (e && *e && !v) v = REC_BLK_OLD;
    g_rec_blk = v < 16 ? 16 : v > REC_BLK_MAX ? REC_BLK_MAX : v;
    if (e && *e) MLOG("DM_NVN_REC_BLK=%s: the encode thread's blocks hold %d records (%d by default)", e, g_rec_blk, REC_BLK_DEFAULT);
    return g_rec_blk;
}
static rec_blk *rec_blk_new(void) { void *p = NULL; if (posix_memalign(&p, REC_ALIGN, offsetof(rec_blk, r) + (size_t)rec_blk_n() * sizeof(rec_t))) MDIE("deferred encoding: out of memory"); return p; }

// On by default on iOS: Breath of the Wild on an iPhone 17 Pro Max (handheld, the Great Plateau) took about 8 ms of submit thread per frame without it and 3.3–4.5 ms with it
static int g_rec = -1;
static inline int rec_on(void) {
    if (__builtin_expect(g_rec >= 0, 1)) return g_rec;
    const char *e = getenv("DM_NVN_ENC_THREAD");
#if TARGET_OS_IPHONE
    g_rec = !e || atoi(e) > 0;
#else
    g_rec = e ? atoi(e) > 0 : DM_GAME_ENC_THREAD;   // the profile's enc_thread: Need for Speed: Hot Pursuit Remastered waits on its fence each frame, so encoding on its thread took its 60 fps frame from 18.1 to 16.7 ms
#endif
    if (g_rec) MLOG("Metal encoding runs on its own thread (DM_NVN_ENC_THREAD=0 turns it off)");
    return g_rec;
}
static pthread_mutex_t g_rb_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_rb_work = PTHREAD_COND_INITIALIZER, g_rb_idle = PTHREAD_COND_INITIALIZER;
static rec_blk *g_rb_cur, *g_rb_head, *g_rb_tail, *g_rb_free;   // the submit thread's open block; blocks waiting for the encode thread; empty blocks
static int g_rb_busy, g_rb_started, g_rb_sleeping;              // the encode thread is working through a block; the thread exists; it waits for work
static _Atomic uint64_t g_rb_wakes;                              // the encode thread's returns from its wait for work (rec_publish / rec_own_push signals, and spurious ones): the threads line (mtl_rec_wakes)
uint64_t mtl_rec_wakes(void) { return atomic_load_explicit(&g_rb_wakes, memory_order_relaxed); }

static inline uint64_t rec_obj(id o) { return o ? (uint64_t)(uintptr_t)CFBridgingRetain(o) : 0; }
static inline id rec_id(uint64_t v) { return (__bridge id)(void *)(uintptr_t)v; }
static inline uint64_t rec_f(float f) { uint32_t u; memcpy(&u, &f, 4); return u; }
static inline float rec_fv(uint64_t v) { uint32_t u = (uint32_t)v; float f; memcpy(&f, &u, 4); return f; }

static pthread_mutex_t g_note_mu = PTHREAD_MUTEX_INITIALIZER; static pthread_cond_t g_note_cv = PTHREAD_COND_INITIALIZER;

// What the encode thread is doing, for the freeze detector's dump (nvn_mtl.m mtl_stall_dump): set where it may wait (for work, for the uniform copies, for the residency commit lock)
// and around its queue calls, with the time it entered the state (mach ticks); not per record, so a block's calls cost nothing more
enum { RX_IDLE, RX_BLOCK, RX_UBC, RX_RESLOCK, RX_COMMIT, RX_SIGNAL, RX_CB_BLOCK, RX_Q_BLOCK, RX_NOTE, RX_N };
static const char *const rx_name[RX_N] = {"waiting for work", "making a block's calls", "waiting for the uniform copies (ubc_wait)", "waiting for the residency commit lock",
    "in the queue's commit", "in the queue's event signal", "in a framework's encoding (RO_CB_BLOCK)", "in a queue operation (RO_Q_BLOCK)", "publishing a note"};
static _Atomic uint32_t g_rx_state; static _Atomic uint64_t g_rx_since;
static inline void rx_set(uint32_t s) { atomic_store_explicit(&g_rx_since, mach_absolute_time(), memory_order_relaxed); atomic_store_explicit(&g_rx_state, s, memory_order_relaxed); }
// The encode thread's state for a wait's 10 s line: what it does and for how long
static void rx_now(char *out, size_t size) {
    uint32_t st = atomic_load_explicit(&g_rx_state, memory_order_relaxed); uint64_t since = atomic_load_explicit(&g_rx_since, memory_order_relaxed), now = mach_absolute_time();
    snprintf(out, size, "the encode thread %s for %.1f s", rx_name[st < RX_N ? st : 0], since && now > since ? mach_s(now - since) : 0.0);
}
// Wait until the encode thread has passed a RO_NOTE of at least v on p (only the encode thread's progress through what is queued, never the GPU). At the 10 s mark it says so once,
// with the caller's site and what the encode thread is doing (nvn_mtl.m wait_say), and waits on. Under the suspend's limit (nvn_mtl.m t_drain_by: snap_drain in mtl_drain_by) it
// ends there; the caller reads the note again
static void rec_note_wait_at(_Atomic uint64_t *p, uint64_t v, const char *site) {
    if (atomic_load(p) >= v) return;
    wn_in(WN_NOTE, v);
    wait_mark m; wait_mark_set(&m);   // the 10 s line, once; the wait is as long as before
    pthread_mutex_lock(&g_note_mu);
    while (atomic_load(p) < v && !drain_over()) {
        wait_mark_sleep(&g_note_cv, &g_note_mu, &m);
        if (atomic_load(p) < v && wait_mark_due(&m)) { static _Atomic int n; char rx[160]; rx_now(rx, sizeof rx); wait_say(&n, "the encode thread's note", site, "value %llu, the note at %llu; %s", (unsigned long long)v, (unsigned long long)atomic_load(p), rx); }
    }
    pthread_mutex_unlock(&g_note_mu);
    wn_out(WN_NOTE);
}
#define rec_note_wait(p, v) rec_note_wait_at(p, v, LOCK_SITE)

// ---------- The encode thread ----------
static id g_rx_cb, g_rx_enc;   // the encode thread's real command buffer and open encoder
// ---------- Submissions committed together ----------
// A submission's commit is held while the GPU still runs a main command buffer committed earlier: its command buffer is ended and kept, the next submissions' go into command buffers
// of their own, and the held ones reach the queue in one commit call, in order. A game that splits its frame at every event signal makes many small submissions (Ocarina of Time 22
// to 30 a frame, each cut again at its waits, signals and fences by the queue scheduler), and they all reach the queue within a few milliseconds, behind the frame's first one.
// Command buffers queued behind running work are the condition for the kernel's stall (docs/reference/frame-rate.md, "The GPU idles with the next command buffer already
// committed"): on upstream's iPhone 17, with the GPU at a low clock, the second command buffer of a frame started 22 to 37 ms after the first had ended in three frames of four, the GPU
// then read 55 to 75 % busy and its governor never raised the clock again (5 to 12 fps where the same scene holds 30). The held ones are committed when the GPU runs out of work (read at the
// end of an encoder, and every 50 us while nothing is recorded, for half a millisecond at most), when the submit thread drains the encode thread, at a present without a snapshot (RO_FLUSH), and before anything else goes to the queue
// (an upload batch, a snapshot copy, a one-off command buffer in order, a queue operation, a signal of its own): each command buffer keeps its place among those exactly as when it was
// committed on its own. Upstream's first version put the next submissions into the held command buffer itself; an upload batch recorded inside a submission then went to the queue after
// the draws of that submission recorded before it, which sampled the textures before their upload (pink and dark flashes on the iPhone, and a GPU error and recovery). Each held
// submission's feedback gets its own part of the commit's GPU time, from the stamp its successor's first encoder writes (ts_sub_begin) where there is one, so a counter report that falls
// back to its command buffer's times (rep_ticks) reads what it read on its own. DM_NVN_SUB_MERGE=0 commits every submission on its own again (ab: alternates with the DM_AB phases)
// Whether the GPU still has work is read from an event the encode thread signals after each of its commits (g_rx_ev: the GPU has run out of its work once that reads g_rx_seq):
// the GPU writes it as it gets there, about 0.04 ms after the work's end on upstream's M6, where the commit feedback runs 0.08-1.2 ms after it, and nothing woke the encode thread for it
// (it looked at the end of its next encoder or after a 150 us wait), so each held batch sat that long in front of an idle GPU. An upload batch or a snapshot copy counts as
// work too. DM_NVN_SUB_IDLE_FB=1 reads the commit feedback's count instead, as upstream's first version did (ab: alternates with the DM_AB phases, for measurement)
enum { RX_PEND_MAX = 48 };
static id g_rx_held_cb[RX_PEND_MAX]; static DmCommitFB *g_rx_fb[RX_PEND_MAX]; static id g_rx_stamp_heap[RX_PEND_MAX]; static int g_rx_stamp[RX_PEND_MAX], g_rx_npend;   // the held submissions, oldest first; stamp: the heap slot of the boundary after it (-1: none)
static int g_rx_after, g_rx_want_stamp;   // the last record was a held commit (or its signal or note); the next boundary stamp is the last held submission's end
static uint64_t g_rx_ubc;   // the newest uniform shadow the held submissions read (ubc_wait at the commit)
static struct { uint64_t v; _Atomic uint64_t *p; } g_rx_post[2 * RX_PEND_MAX + 4]; static id g_rx_post_ev[2 * RX_PEND_MAX + 4]; static int g_rx_npost;   // the signals (an event) and notes that followed held commits: made after the real one, in order
static _Atomic int g_rx_fly, g_rx_held, g_rx_drain, g_rx_busy_hold;   // main command buffers committed and not reported back (DM_NVN_SUB_IDLE_FB); commits are held (rec_drain waits for them); rec_drain callers waiting; tests: the GPU counts as busy
static id<MTLSharedEvent> g_rx_ev; static uint64_t g_rx_seq;   // signalled with ++g_rx_seq after every commit of the encode thread (rx_mark)
static uint64_t g_rx_merged, g_rx_cbs; static int g_rx_last_nb;   // submissions held and committed with a later one; commit calls of main command buffers; command buffers in the last one
static int sw_mode(const char *name, int dflt); static inline int sw_on(int m);
static void rca_queue_guard(uint64_t seq);   // nvn_mtl.m: commits what the replay handed off (DM_NVN_RES_ASYNC), before the encode thread's queue commits
static uint64_t res_seq_now(void);   // nvn_mtl.m: the next residency change's number; a record that commits keeps it, so its guard needs only the changes before it (DM_NVN_RES_PREWIRE)
static uint64_t g_rx_res_seq;   // the largest of those numbers among the main command buffers rx_commit commits next (held ones included); 0 none yet
static int rx_merge_on(void) {
    static int v = -1;
    if (v < 0) { const char *e = getenv("DM_NVN_SUB_MERGE"); v = e && !strncmp(e, "ab", 2) ? sw_mode("DM_NVN_SUB_MERGE", 0) : !(e && !strcmp(e, "0"));
        if (!v) MLOG("DM_NVN_SUB_MERGE=0: every submission is committed on its own"); }
    return sw_on(v);
}
// The replay's cut decision (nvn_mtl.m sub_cut, pass_split_try; DM_NVN_CUT_EVENT) reads the same event from its own thread: g_rx_seq_pub is g_rx_seq once its signal is queued,
// g_rx_made the main command buffers the encode thread has put on the queue (held ones count when they go), g_rec_cmts the ones the replay recorded (the replay thread only)
static _Atomic uint64_t g_rx_seq_pub, g_rx_made; static uint64_t g_rec_cmts;
static void rx_mark(void) { if (!g_rx_ev) g_rx_ev = [g_dev newSharedEvent]; [g_q4 signalEvent:g_rx_ev value:++g_rx_seq]; atomic_store_explicit(&g_rx_seq_pub, g_rx_seq, memory_order_release); }   // after a commit, under the residency commit lock
static int rx_busy(void) {   // the GPU still runs work the encode thread committed
    static int fbm = -1; if (fbm < 0) fbm = sw_mode("DM_NVN_SUB_IDLE_FB", 0);
    if (atomic_load_explicit(&g_rx_busy_hold, memory_order_relaxed)) return 1;
    if (fbm && sw_on(fbm)) return atomic_load(&g_rx_fly) > 0;
    return g_rx_ev && g_rx_ev.signaledValue < g_rx_seq;
}
static double rx_stamp_s(id heap, int slot) {   // a boundary stamp in seconds on the Mach clock, as a commit feedback's GPU times are; 0 when it was not written
    if (!heap || slot < 0) return 0;
    NSData *d = [(id<MTL4CounterHeap>)heap resolveCounterRange:NSMakeRange((NSUInteger)slot, 1)]; const MTL4TimestampHeapEntry *en = d.bytes;
    if (!en || d.length < sizeof *en || !en->timestamp) return 0;
    MTLTimestamp cpu = 0, gpu = 0; [g_dev sampleTimestamps:&cpu gpuTimestamp:&gpu];
    static double scale; if (!scale) { uint64_t hz = [g_dev queryTimestampFrequency]; scale = hz ? 1e9 / (double)hz : 1; }
    double ago = (double)gpu - (double)en->timestamp * scale;
    return cpu && ago >= 0 && ago < 2e9 ? ((double)cpu - ago) / 1e9 : 0;
}
// One commit call: the held command buffers, then (cur) the encode thread's own, ended by the caller, with its feedback own (nil: none). The held ones' feedback comes first
static void rx_commit(int cur, DmCommitFB *own, uint64_t ubc) {
    int n = g_rx_npend, nb = n + (cur != 0), cnt = nb; if (!nb) return;
    id<MTL4CommandBuffer> buffers[RX_PEND_MAX + 1];
    NSMutableArray *fbs = [NSMutableArray arrayWithCapacity:(NSUInteger)cnt], *heaps = [NSMutableArray arrayWithCapacity:(NSUInteger)(n ? n : 1)]; NSMutableData *st = [NSMutableData dataWithLength:(NSUInteger)(n ? n : 1) * sizeof(int)]; int *sl = st.mutableBytes;
    for (int i = 0; i < n; i++) { buffers[i] = g_rx_held_cb[i]; [fbs addObject:g_rx_fb[i]]; [heaps addObject:g_rx_stamp_heap[i] ?: (id)NSNull.null]; sl[i] = g_rx_stamp[i]; g_rx_held_cb[i] = nil; g_rx_fb[i] = nil; g_rx_stamp_heap[i] = nil; }
    if (cur) { buffers[n] = g_rx_cb; [fbs addObject:own ?: (id)NSNull.null]; }
    if (g_rx_ubc > ubc) ubc = g_rx_ubc;
    g_rx_ubc = 0; g_rx_npend = 0; g_rx_want_stamp = 0; atomic_store(&g_rx_held, 0);
    rx_set(RX_UBC); ubc_wait(ubc);   // the uniform shadows these command buffers read
    MTL4CommitOptions *o = [MTL4CommitOptions new];
    atomic_fetch_add(&g_rx_fly, 1);
    [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        atomic_fetch_sub(&g_rx_fly, 1);
        if (cnt == 1) { if (fbs[0] != NSNull.null) for (void (^b)(id<MTL4CommitFeedback>) in ((DmCommitFB *)fbs[0])->blocks) b(f); return; }
        double t[RX_PEND_MAX + 2]; const int *ss = st.bytes; t[0] = f.GPUStartTime; t[cnt] = f.GPUEndTime;
        for (int i = 1; i < cnt; i++) { double at = i - 1 < n && heaps[(NSUInteger)(i - 1)] != NSNull.null ? rx_stamp_s(heaps[(NSUInteger)(i - 1)], ss[i - 1]) : 0; t[i] = at > 0 && at >= t[0] && at <= t[cnt] ? at : -1; }
        for (int i = cnt - 1; i >= 1; i--) if (t[i] < 0 || t[i] > t[i + 1]) t[i] = t[i + 1];   // no stamp (an encoder with no work writes none): the submission ends where the next known boundary is
        for (int i = 0; i < cnt; i++) { if (fbs[(NSUInteger)i] == NSNull.null) continue; DmPartFB *part = [DmPartFB new]; part->t0 = t[i]; part->t1 = t[i + 1]; part->err = f.error;
            for (void (^b)(id<MTL4CommitFeedback>) in ((DmCommitFB *)fbs[(NSUInteger)i])->blocks) b((id<MTL4CommitFeedback>)part); }
    }];
    rx_set(RX_RESLOCK);
    rca_queue_guard(g_rx_res_seq); g_rx_res_seq = 0;   // what the replay handed to the residency commit worker is in the set first (DM_NVN_RES_ASYNC, nvn_mtl.m res_commit_soon)
    res_commit_lock();   // apart from the residency set's commit, as the present snapshot's queue commit (nvn_mtl.m res_commit)
    rx_set(RX_COMMIT);
    Q4_COMMIT_TIMED(nb > 1 ? "the encode thread (RO_COMMIT, held main command buffers)" : "the encode thread (RO_COMMIT, a main command buffer)", [g_q4 commit:buffers count:(NSUInteger)nb options:o]);   // a commit of 100 ms or more says so (nvn_mtl.m q4_commit_slow)
    rx_mark(); res_commit_unlock();
    atomic_fetch_add_explicit(&g_rx_made, (uint64_t)nb, memory_order_release);
    rx_set(RX_BLOCK);
    if (cur) g_rx_cb = nil;
    g_rx_cbs++; g_rx_merged += (uint64_t)n; g_rx_last_nb = nb;
    for (int i = 0; i < g_rx_npost; i++) {   // what followed the held commits
        if (g_rx_post_ev[i]) { rx_set(RX_SIGNAL); [g_q4 signalEvent:g_rx_post_ev[i] value:g_rx_post[i].v]; g_rx_post_ev[i] = nil; rx_set(RX_BLOCK); }
        else { _Atomic uint64_t *np = g_rx_post[i].p; rx_set(RX_NOTE); pthread_mutex_lock(&g_note_mu); if (g_rx_post[i].v > atomic_load(np)) atomic_store(np, g_rx_post[i].v); pthread_cond_broadcast(&g_note_cv); pthread_mutex_unlock(&g_note_mu); rx_set(RX_BLOCK); }
    }
    g_rx_npost = 0;
    if (g_rx_cbs % 20000 == 0) MLOG("held submissions: %llu commits of main command buffers so far, %llu submissions committed with a later one (DM_NVN_SUB_MERGE)", (unsigned long long)g_rx_cbs, (unsigned long long)g_rx_merged);
}
static void rx_flush(void) { if (g_rx_npend) rx_commit(0, nil, 0); }   // the held command buffers go to the queue now
static int rx_cut_hold_flush(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_NVN_CUT_HOLD"); v = !(e && !strcmp(e, "0")); } return v; }   // the block-start look (rec_thread) goes with DM_NVN_CUT_HOLD
// ---------- Repeated passes (DM_NVN_PASS_REPEAT=1; measurement only) ----------
static _Alignas(128) _Atomic uint64_t g_cur_frame;   // the replay's frame (mtl_set_frame): the encode thread's policy tick and the repeated passes' frames
// Whether indirect command buffers could save encode time: per frame, the share of render passes whose recorded stream (every record between the pass's begin and its end: the
// op and the arguments it uses, object pointers included; the begin with its descriptor, a new object each frame, labels and timestamps left out) is byte-identical to a pass of the previous frame, with their draws and the encode
// thread's time in them. Hashed on the encode thread as it makes the records (each record's words folded with a rotation apiece, then one multiply into the pass's hash). Logged every 300 frames: "[pass repeat] up to frame N, per frame: ...".
// Off by default: t_pass_repeat measures the hashing at 3.3 ns a record on an M4 Max P core, 0.07 ms for a 20,000-record frame (about three times that on the iPhone's capped cores),
// over the 0.05 ms a frame an always-on count may cost.
// Counts the encode thread's records only: DM_NVN_ENC_THREAD=0 gives no line
static int g_pr = -1;   // -1 not read, 0 off, 1 on
static uint8_t g_pr_nargs[RO_FLUSH + 1];   // the argument words an op uses (pr_init); 0 for ops that are not part of a pass's stream
enum { PR_MAX = 2048 };
static uint64_t g_pr_h, g_pr_t0, g_pr_frame, g_pr_prev[PR_MAX], g_pr_this[PR_MAX];
static int g_pr_open, g_pr_draws, g_pr_nprev, g_pr_nthis, g_pr_frames;
static uint64_t g_pr_passes, g_pr_rep, g_pr_draws_all, g_pr_draws_rep, g_pr_ns, g_pr_ns_rep;
static void pr_init(void) {
    const char *e = getenv("DM_NVN_PASS_REPEAT"); g_pr = e && atoi(e) > 0;
    static const struct { uint8_t op, n; } na[] = {
        {RO_BAR_QUEUE, 3}, {RO_BAR_AFTER_STAGES, 3}, {RO_BAR_ENCODER, 3},
        {RO_R_TABLE, 2}, {RO_R_PSO, 1}, {RO_R_DSS, 1}, {RO_R_VIEWPORT, 6}, {RO_R_SCISSOR, 4}, {RO_R_CULL, 1}, {RO_R_WINDING, 1}, {RO_R_FILL, 1}, {RO_R_BIAS, 3}, {RO_R_CLIP, 1},
        {RO_R_DBND, 2}, {RO_R_SREF, 2}, {RO_R_BLEND, 4}, {RO_R_VIS, 2}, {RO_R_AMP, 3}, {RO_R_CMAP, 1},
        {RO_R_DRAW, 3}, {RO_R_DRAW_INST, 5}, {RO_R_DRAW_IND, 2}, {RO_R_DRAW_IDX, 8}, {RO_R_DRAW_IDX_IND, 5}, {RO_R_MESH, 3}, {RO_R_MESH_IND, 3},
        {RO_R_STORE_C, 2}, {RO_R_STORE_D, 1}, {RO_R_STORE_S, 1}, {RO_T_ADDR, 3}, {RO_T_TEX, 3}, {RO_T_SAMP, 3}};
    for (size_t i = 0; i < sizeof na / sizeof *na; i++) g_pr_nargs[na[i].op] = na[i].n;
    if (g_pr) MLOG("DM_NVN_PASS_REPEAT=1: render passes recorded byte for byte as one of the previous frame are counted (the [pass repeat] line every 300 frames)");
}
static int pr_cmp(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }
static int pr_seen(uint64_t h) {   // in the previous frame's (sorted) set
    int lo = 0, hi = g_pr_nprev - 1;
    while (lo <= hi) { int m = (lo + hi) / 2; if (g_pr_prev[m] == h) return 1; if (g_pr_prev[m] < h) lo = m + 1; else hi = m - 1; }
    return 0;
}
static void pr_frame(uint64_t f) {   // a new frame's first pass: this frame's set becomes the previous one; the line every 300 frames
    memcpy(g_pr_prev, g_pr_this, (size_t)g_pr_nthis * sizeof *g_pr_this); g_pr_nprev = g_pr_nthis; g_pr_nthis = 0;
    qsort(g_pr_prev, (size_t)g_pr_nprev, sizeof *g_pr_prev, pr_cmp);
    g_pr_frame = f;
    if (++g_pr_frames < 300) return;
    double nf = g_pr_frames;
    MLOG("[pass repeat] up to frame %llu, per frame: render passes %.1f, %.1f%% of them byte-identical to a pass of the previous frame; draws %.1f, %.1f%% in those passes; "
         "encode thread time in render passes %.3f ms, %.3f ms of it in the identical ones", (unsigned long long)f, g_pr_passes / nf, g_pr_passes ? 100.0 * g_pr_rep / g_pr_passes : 0.0,
         g_pr_draws_all / nf, g_pr_draws_all ? 100.0 * g_pr_draws_rep / g_pr_draws_all : 0.0, mach_s(g_pr_ns) * 1e3 / nf, mach_s(g_pr_ns_rep) * 1e3 / nf);
    g_pr_frames = 0; g_pr_passes = g_pr_rep = g_pr_draws_all = g_pr_draws_rep = g_pr_ns = g_pr_ns_rep = 0;
}
static void pr_note(const rec_t *r) {
    uint32_t op = r->op;
    if (op == RO_RE_BEGIN) {
        uint64_t f = atomic_load_explicit(&g_cur_frame, memory_order_relaxed);
        if (f != g_pr_frame) pr_frame(f);
        g_pr_open = 1; g_pr_h = 0xcbf29ce484222325ull; g_pr_draws = 0; g_pr_t0 = mach_absolute_time();
        return;
    }
    if (!g_pr_open) return;
    if (op == RO_END) {
        uint64_t dt = mach_absolute_time() - g_pr_t0; int rep = pr_seen(g_pr_h);
        if (g_pr_nthis < PR_MAX) g_pr_this[g_pr_nthis++] = g_pr_h;
        g_pr_passes++; g_pr_draws_all += (uint64_t)g_pr_draws; g_pr_ns += dt;
        if (rep) { g_pr_rep++; g_pr_draws_rep += (uint64_t)g_pr_draws; g_pr_ns_rep += dt; }
        g_pr_open = 0;
        return;
    }
    if (op > RO_FLUSH) return;
    uint64_t x = op; int n = g_pr_nargs[op];   // the record's words folded with a rotation each (no carried chain), then one multiply into the pass's hash
    for (int i = 0; i < n; i++) x += __builtin_rotateleft64(r->a[i], 9 * i + 1) ^ (0x9e3779b97f4a7c15ull * (uint64_t)(i + 1));
    uint64_t h = (g_pr_h ^ x) * 0xff51afd7ed558ccdull; g_pr_h = h ^ (h >> 29);
    if (op >= RO_R_DRAW && op <= RO_R_MESH_IND) g_pr_draws++;
}
static void rec_exec(const rec_t *r) {
    if (__builtin_expect(g_pr != 0, 0)) { if (g_pr < 0) pr_init(); if (g_pr) pr_note(r); }
    const uint64_t *a = r->a; id e = g_rx_enc;
    int after = g_rx_after; if (r->op != RO_SIGNAL && r->op != RO_NOTE) g_rx_after = 0;
    switch (r->op) {
    case RO_CB_NEW: g_rx_cb = [g_dev newCommandBuffer]; break;
    case RO_CB_BEGIN: [(id<MTL4CommandBuffer>)g_rx_cb beginCommandBufferWithAllocator:rec_id(a[0])]; break;
    case RO_CB_END: [(id<MTL4CommandBuffer>)g_rx_cb endCommandBuffer]; break;
    case RO_CB_BLOCK: rx_set(RX_CB_BLOCK); ((void (^)(id<MTL4CommandBuffer>))rec_id(a[0]))(g_rx_cb); rx_set(RX_BLOCK); break;
    case RO_COMMIT: {   // a main command buffer (ended): a[0] its feedback, a[2] its uniform shadows, a[5] the submission ends with it, a[6] res_seq_now as it was put
        DmCommitFB *fb = rec_id(a[0]);
        if (a[6] > g_rx_res_seq) g_rx_res_seq = a[6];
        if (a[5] && fb && g_rx_npend < RX_PEND_MAX && rx_busy() && !atomic_load(&g_rx_drain) && rx_merge_on()) {   // held: the GPU has work (a[5] 1 a submission's end, 2 a segment cut, DM_NVN_CUT_HOLD)
            g_rx_held_cb[g_rx_npend] = g_rx_cb; g_rx_fb[g_rx_npend] = fb; g_rx_stamp[g_rx_npend] = -1; g_rx_stamp_heap[g_rx_npend] = nil; g_rx_npend++; if (a[2] > g_rx_ubc) g_rx_ubc = a[2];
            g_rx_cb = nil; g_rx_after = 1; g_rx_want_stamp = 1; atomic_store(&g_rx_held, 1);
            break; }
        rx_commit(1, fb, a[2]);
        break; }
    case RO_COMMIT_REAL: {   // an upload batch, a snapshot copy, a one-off command buffer in order: a whole command buffer, after everything recorded before it; a[2] res_seq_now as it was put
        rx_flush();
        id<MTL4CommandBuffer> buffers[] = {rec_id(a[1])}; MTL4CommitOptions *o = rec_id(a[0]);
        rx_set(RX_RESLOCK);
        rca_queue_guard(a[2]);   // as rx_commit's
        res_commit_lock();   // apart from the residency set's commit, as the present snapshot's queue commit (nvn_mtl.m res_commit)
        rx_set(RX_COMMIT);
        Q4_COMMIT_TIMED("the encode thread (RO_COMMIT_REAL)", if (o) [g_q4 commit:buffers count:1 options:o]; else [g_q4 commit:buffers count:1]);   // a commit of 100 ms or more says so (nvn_mtl.m q4_commit_slow)
        rx_mark(); res_commit_unlock();
        rx_set(RX_BLOCK);
        break; }
    case RO_SIGNAL:
        if (after && g_rx_npend && g_rx_npost < (int)(sizeof g_rx_post / sizeof *g_rx_post)) { g_rx_post_ev[g_rx_npost] = rec_id(a[0]); g_rx_post[g_rx_npost].v = a[1]; g_rx_post[g_rx_npost++].p = NULL; g_rx_after = 1; break; }   // its command buffer is not committed yet
        rx_flush(); rx_set(RX_SIGNAL); [g_q4 signalEvent:rec_id(a[0]) value:a[1]]; rx_set(RX_BLOCK); break;
    case RO_FLUSH: rx_flush(); break;
    case RO_Q_BLOCK: rx_flush(); rx_set(RX_RESLOCK); rca_queue_guard(a[1]); rx_set(RX_Q_BLOCK); ((void (^)(void))rec_id(a[0]))(); rx_set(RX_BLOCK); break;   // rca_queue_guard: a sparse mapping update's heap in the set first, as before a queue commit
    case RO_RE_BEGIN: g_rx_enc = [(id<MTL4CommandBuffer>)g_rx_cb renderCommandEncoderWithDescriptor:rec_id(a[0])]; break;
    case RO_CE_BEGIN: g_rx_enc = [(id<MTL4CommandBuffer>)g_rx_cb computeCommandEncoder]; break;
    case RO_END: [(id<MTL4CommandEncoder>)e endEncoding]; g_rx_enc = nil; g_rx_want_stamp = 0;
        if (g_rx_npend && (atomic_load(&g_rx_drain) || !rx_busy())) rx_flush();   // the GPU has run out of work (or the submit thread waits): the held ones go to it
        break;
    case RO_BAR_QUEUE: [(id<MTL4CommandEncoder>)e barrierAfterQueueStages:a[0] beforeStages:a[1] visibilityOptions:a[2]]; break;
    case RO_BAR_AFTER_STAGES: [(id<MTL4CommandEncoder>)e barrierAfterStages:a[0] beforeQueueStages:a[1] visibilityOptions:a[2]]; break;
    case RO_BAR_ENCODER: [(id<MTL4CommandEncoder>)e barrierAfterEncoderStages:a[0] beforeEncoderStages:a[1] visibilityOptions:a[2]]; break;
    case RO_R_TABLE: [(id<MTL4RenderCommandEncoder>)e setArgumentTable:rec_id(a[0]) atStages:a[1]]; break;
    case RO_R_PSO: [(id<MTL4RenderCommandEncoder>)e setRenderPipelineState:rec_id(a[0])]; break;
    case RO_R_DSS: [(id<MTL4RenderCommandEncoder>)e setDepthStencilState:rec_id(a[0])]; break;
    case RO_R_VIEWPORT: { MTLViewport v; memcpy(&v, a, sizeof v); [(id<MTL4RenderCommandEncoder>)e setViewport:v]; break; }
    case RO_R_SCISSOR: { MTLScissorRect s; memcpy(&s, a, sizeof s); [(id<MTL4RenderCommandEncoder>)e setScissorRect:s]; break; }
    case RO_R_CULL: [(id<MTL4RenderCommandEncoder>)e setCullMode:a[0]]; break;
    case RO_R_WINDING: [(id<MTL4RenderCommandEncoder>)e setFrontFacingWinding:a[0]]; break;
    case RO_R_FILL: [(id<MTL4RenderCommandEncoder>)e setTriangleFillMode:a[0]]; break;
    case RO_R_BIAS: [(id<MTL4RenderCommandEncoder>)e setDepthBias:rec_fv(a[0]) slopeScale:rec_fv(a[1]) clamp:rec_fv(a[2])]; break;
    case RO_R_CLIP: [(id<MTL4RenderCommandEncoder>)e setDepthClipMode:a[0]]; break;
    case RO_R_DBND: [(id<MTL4RenderCommandEncoder>)e setDepthTestMinBound:rec_fv(a[0]) maxBound:rec_fv(a[1])]; break;
    case RO_R_SREF: [(id<MTL4RenderCommandEncoder>)e setStencilFrontReferenceValue:(uint32_t)a[0] backReferenceValue:(uint32_t)a[1]]; break;   // front, back
    case RO_R_BLEND: [(id<MTL4RenderCommandEncoder>)e setBlendColorRed:rec_fv(a[0]) green:rec_fv(a[1]) blue:rec_fv(a[2]) alpha:rec_fv(a[3])]; break;
    case RO_R_VIS: [(id<MTL4RenderCommandEncoder>)e setVisibilityResultMode:a[0] offset:a[1]]; break;
    case RO_R_AMP: { MTLVertexAmplificationViewMapping m = {(uint32_t)a[1], (uint32_t)a[2]}; [(id<MTL4RenderCommandEncoder>)e setVertexAmplificationCount:a[0] viewMappings:a[0] ? &m : NULL]; break; }   // count 0 or 1 (slice-merged passes)
    case RO_R_CMAP: [(id<MTL4RenderCommandEncoder>)e setColorAttachmentMap:(__bridge MTLLogicalToPhysicalColorAttachmentMap *)(void *)(uintptr_t)a[0]]; break;   // one of nvn_mtl.m's g_fsp_map, kept for the process (face-split draws)
    case RO_R_DRAW: [(id<MTL4RenderCommandEncoder>)e drawPrimitives:a[0] vertexStart:a[1] vertexCount:a[2]]; break;
    case RO_R_DRAW_INST: [(id<MTL4RenderCommandEncoder>)e drawPrimitives:a[0] vertexStart:a[1] vertexCount:a[2] instanceCount:a[3] baseInstance:a[4]]; break;
    case RO_R_DRAW_IND: [(id<MTL4RenderCommandEncoder>)e drawPrimitives:a[0] indirectBuffer:a[1]]; break;
    case RO_R_DRAW_IDX: [(id<MTL4RenderCommandEncoder>)e drawIndexedPrimitives:a[0] indexCount:a[1] indexType:a[2] indexBuffer:a[3] indexBufferLength:a[4] instanceCount:a[5] baseVertex:(NSInteger)a[6] baseInstance:a[7]]; break;
    case RO_R_DRAW_IDX_IND: [(id<MTL4RenderCommandEncoder>)e drawIndexedPrimitives:a[0] indexType:a[1] indexBuffer:a[2] indexBufferLength:a[3] indirectBuffer:a[4]]; break;
    case RO_R_MESH: [(id<MTL4RenderCommandEncoder>)e drawMeshThreadgroups:MTLSizeMake(a[0], 1, 1) threadsPerObjectThreadgroup:MTLSizeMake(a[2] ? a[2] : 1, 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(a[1], 1, 1)]; break;
    case RO_R_MESH_IND: [(id<MTL4RenderCommandEncoder>)e drawMeshThreadgroupsWithIndirectBuffer:a[0] threadsPerObjectThreadgroup:MTLSizeMake(a[2] ? a[2] : 1, 1, 1) threadsPerMeshThreadgroup:MTLSizeMake(a[1], 1, 1)]; break;   // PR #1312's indirect task / mesh draws: the encode thread (iOS) aborted on the selector
    case RO_R_STORE_C: [(id<MTL4RenderCommandEncoder>)e setColorStoreAction:a[0] atIndex:a[1]]; break;
    case RO_R_STORE_D: [(id<MTL4RenderCommandEncoder>)e setDepthStoreAction:a[0]]; break;
    case RO_R_STORE_S: [(id<MTL4RenderCommandEncoder>)e setStencilStoreAction:a[0]]; break;
    case RO_C_TABLE: [(id<MTL4ComputeCommandEncoder>)e setArgumentTable:rec_id(a[0])]; break;
    case RO_C_PSO: [(id<MTL4ComputeCommandEncoder>)e setComputePipelineState:rec_id(a[0])]; break;
    case RO_C_DISPATCH: [(id<MTL4ComputeCommandEncoder>)e dispatchThreadgroups:MTLSizeMake(a[0], a[1], a[2]) threadsPerThreadgroup:MTLSizeMake(a[3], a[4], a[5])]; break;
    case RO_C_DISPATCH_IND: [(id<MTL4ComputeCommandEncoder>)e dispatchThreadgroupsWithIndirectBuffer:a[0] threadsPerThreadgroup:MTLSizeMake(a[1], a[2], a[3])]; break;
    case RO_C_COPY_BB: [(id<MTL4ComputeCommandEncoder>)e copyFromBuffer:rec_id(a[0]) sourceOffset:a[2] toBuffer:rec_id(a[1]) destinationOffset:a[3] size:a[4]]; break;
    case RO_C_COPY_BT: [(id<MTL4ComputeCommandEncoder>)e copyFromBuffer:rec_id(a[0]) sourceOffset:a[2] sourceBytesPerRow:a[3] sourceBytesPerImage:a[4] sourceSize:MTLSizeMake(a[5], a[6], a[7])
                           toTexture:rec_id(a[1]) destinationSlice:a[8] destinationLevel:a[9] destinationOrigin:MTLOriginMake(a[10], a[11], a[12])]; break;
    case RO_C_COPY_BT_OPT: [(id<MTL4ComputeCommandEncoder>)e copyFromBuffer:rec_id(a[0]) sourceOffset:a[2] sourceBytesPerRow:a[3] sourceBytesPerImage:a[4] sourceSize:MTLSizeMake(a[5], a[6], a[7])
                           toTexture:rec_id(a[1]) destinationSlice:a[8] destinationLevel:a[9] destinationOrigin:MTLOriginMake(a[10], a[11], a[12]) options:(MTLBlitOption)a[13]]; break;
    case RO_C_COPY_TB: [(id<MTL4ComputeCommandEncoder>)e copyFromTexture:rec_id(a[0]) sourceSlice:a[2] sourceLevel:a[3] sourceOrigin:MTLOriginMake(a[4], a[5], a[6]) sourceSize:MTLSizeMake(a[7], a[8], a[9])
                           toBuffer:rec_id(a[1]) destinationOffset:a[10] destinationBytesPerRow:a[11] destinationBytesPerImage:a[12]]; break;
    case RO_C_COPY_TB_OPT: [(id<MTL4ComputeCommandEncoder>)e copyFromTexture:rec_id(a[0]) sourceSlice:a[2] sourceLevel:a[3] sourceOrigin:MTLOriginMake(a[4], a[5], a[6]) sourceSize:MTLSizeMake(a[7], a[8], a[9])
                           toBuffer:rec_id(a[1]) destinationOffset:a[10] destinationBytesPerRow:a[11] destinationBytesPerImage:a[12] options:(MTLBlitOption)a[13]]; break;
    case RO_C_COPY_TT: [(id<MTL4ComputeCommandEncoder>)e copyFromTexture:rec_id(a[0]) sourceSlice:a[2] sourceLevel:a[3] sourceOrigin:MTLOriginMake(a[4], a[5], a[6]) sourceSize:MTLSizeMake(a[7], a[8], a[9])
                           toTexture:rec_id(a[1]) destinationSlice:a[10] destinationLevel:a[11] destinationOrigin:MTLOriginMake(a[12], a[13], a[14])]; break;
    case RO_C_FILL: [(id<MTL4ComputeCommandEncoder>)e fillBuffer:rec_id(a[0]) range:NSMakeRange(a[1], a[2]) value:(uint8_t)a[3]]; break;
    case RO_T_ADDR: [(id<MTL4ArgumentTable>)rec_id(a[0]) setAddress:a[1] atIndex:a[2]]; break;
    case RO_T_TEX: [(id<MTL4ArgumentTable>)rec_id(a[0]) setTexture:(MTLResourceID){a[1]} atIndex:a[2]]; break;
    case RO_T_SAMP: [(id<MTL4ArgumentTable>)rec_id(a[0]) setSamplerState:(MTLResourceID){a[1]} atIndex:a[2]]; break;
    case RO_LABEL: [(id<MTL4CommandEncoder>)e setLabel:rec_id(a[0])]; break;
    case RO_R_TS: [(id<MTL4RenderCommandEncoder>)e writeTimestampWithGranularity:a[1] afterStage:a[2] intoHeap:rec_id(a[0]) atIndex:a[3]];
        if (g_rx_want_stamp && g_rx_npend && rec_id(a[0]) == (id)g_ts_heap) { g_rx_stamp_heap[g_rx_npend - 1] = rec_id(a[0]); g_rx_stamp[g_rx_npend - 1] = (int)a[3]; g_rx_want_stamp = 0; }   // the submission's begin stamp: where the held one before it ends
        break;
    case RO_C_TS: [(id<MTL4ComputeCommandEncoder>)e writeTimestampWithGranularity:a[1] intoHeap:rec_id(a[0]) atIndex:a[2]];
        if (g_rx_want_stamp && g_rx_npend && rec_id(a[0]) == (id)g_ts_heap) { g_rx_stamp_heap[g_rx_npend - 1] = rec_id(a[0]); g_rx_stamp[g_rx_npend - 1] = (int)a[2]; g_rx_want_stamp = 0; }
        break;
    case RO_NOTE: { _Atomic uint64_t *p = (_Atomic uint64_t *)(uintptr_t)a[0];
        if (after && g_rx_npend && g_rx_npost < (int)(sizeof g_rx_post / sizeof *g_rx_post)) { g_rx_post_ev[g_rx_npost] = nil; g_rx_post[g_rx_npost].v = a[1]; g_rx_post[g_rx_npost++].p = p; g_rx_after = 1; break; }   // noted once its command buffer is committed
        rx_set(RX_NOTE); pthread_mutex_lock(&g_note_mu); if (a[1] > atomic_load(p)) atomic_store(p, a[1]); pthread_cond_broadcast(&g_note_cv); pthread_mutex_unlock(&g_note_mu); rx_set(RX_BLOCK); break; }
    default: MDIE("deferred encoding: unknown record %u", r->op);
    }
    for (uint32_t i = 0; i < r->nobj; i++) if (a[i]) CFRelease((CFTypeRef)(uintptr_t)a[i]);
}
// The encode thread's time-constraint policy (nvn_rt.h; profile key replay_rt, DM_REPLAY_RT): ticked after each block at the replay's frame (mtl_set_frame), when that moved on
static nvn_rtw g_rec_rtw = {.name = "dm-encode"};
static void *rec_thread(void *arg) {
    (void)arg; pthread_setname_np("dm-encode");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    const int rt = nvn_replay_rt();
    for (;;) {
        rx_set(RX_IDLE);
        pthread_mutex_lock(&g_rb_mu);
        while (!g_rb_head) {
            if (g_rx_npend) {   // held commits and nothing more to encode: a short wait for the next submission while the GPU still has work (looked at every 50 us), then they go
                for (int k = 0; k < 9 && !g_rb_head && !atomic_load(&g_rx_drain) && rx_busy(); k++) { struct timespec ts = {0, 50000}; g_rb_sleeping = 1; pthread_cond_timedwait_relative_np(&g_rb_work, &g_rb_mu, &ts); g_rb_sleeping = 0; }
                if (g_rb_head) break;
                g_rb_busy = 1; pthread_mutex_unlock(&g_rb_mu);
                rx_set(RX_BLOCK);
                @autoreleasepool { rx_flush(); }
                rx_set(RX_IDLE);
                pthread_mutex_lock(&g_rb_mu); g_rb_busy = 0; if (!g_rb_head) pthread_cond_broadcast(&g_rb_idle);
                continue;
            }
            g_rb_sleeping = 1; pthread_cond_wait(&g_rb_work, &g_rb_mu); g_rb_sleeping = 0; atomic_fetch_add_explicit(&g_rb_wakes, 1, memory_order_relaxed);
        }
        rec_blk *b = g_rb_head; g_rb_head = b->next; if (!g_rb_head) g_rb_tail = NULL; g_rb_busy = 1;
        pthread_mutex_unlock(&g_rb_mu);
        rx_set(RX_BLOCK);
        @autoreleasepool {
            if (g_rx_npend && !rx_busy() && rx_cut_hold_flush()) rx_flush();   // a long pass's records: the held ones go once the GPU has run out, without waiting for the encoder's end (DM_NVN_CUT_HOLD)
            for (int i = 0; i < b->n; i++) rec_exec(&b->r[i]); }
        pthread_mutex_lock(&g_rb_mu);
        b->n = 0; b->next = g_rb_free; g_rb_free = b; g_rb_busy = 0;
        if (!g_rb_head) pthread_cond_broadcast(&g_rb_idle);
        pthread_mutex_unlock(&g_rb_mu);
        { uint64_t f = atomic_load_explicit(&g_cur_frame, memory_order_relaxed);
          if (rt && (!g_rec_rtw.started || f > g_rec_rtw.frame)) nvn_rtw_tick(&g_rec_rtw, f);
          dm_tcore_sample(DM_TCORE_ENCODE, f); }   // the threads line's core placement (at most once a frame)
    }
    return NULL;
}

// ---------- The submit thread's side ----------
static void rec_publish(void) {
    if (!g_rb_cur || !g_rb_cur->n) return;
    pthread_mutex_lock(&g_rb_mu);
    g_rb_cur->next = NULL; if (g_rb_tail) g_rb_tail->next = g_rb_cur; else g_rb_head = g_rb_cur; g_rb_tail = g_rb_cur; g_rb_cur = NULL;
    if (g_rb_sleeping) pthread_cond_signal(&g_rb_work);
    pthread_mutex_unlock(&g_rb_mu);
}
static __attribute__((noinline)) rec_t *rec_put_slow(uint32_t op, uint32_t nobj);
static inline rec_t *rec_put(uint32_t op, uint32_t nobj) {
    rec_blk *b = g_rb_cur;
    if (__builtin_expect(b && b->n < g_rec_blk, 1)) { rec_t *r = &b->r[b->n++]; r->op = op; r->nobj = nobj; return r; }
    return rec_put_slow(op, nobj);
}
static __attribute__((noinline)) rec_t *rec_put_slow(uint32_t op, uint32_t nobj) {
    if (g_rb_cur && g_rb_cur->n >= rec_blk_n()) rec_publish();
    if (!g_rb_cur) {
        pthread_mutex_lock(&g_rb_mu);
        if (!g_rb_started) { pthread_t th; pthread_attr_t at; if (!g_rx_ev) g_rx_ev = [g_dev newSharedEvent]; /* made before the thread: the replay reads it too (rec_gpu_busy) */ pthread_attr_init(&at); pthread_attr_setstacksize(&at, 1 << 20);
            if (pthread_create(&th, &at, rec_thread, NULL)) MDIE("deferred encoding: cannot start the encode thread"); pthread_attr_destroy(&at); g_rb_started = 1; }
        g_rb_cur = g_rb_free; if (g_rb_cur) g_rb_free = g_rb_cur->next;
        pthread_mutex_unlock(&g_rb_mu);
        if (!g_rb_cur) g_rb_cur = rec_blk_new();
        g_rb_cur->n = 0;
    }
    rec_t *r = &g_rb_cur->r[g_rb_cur->n++]; r->op = op; r->nobj = nobj; return r;
}
// Hand over what is recorded and wait until the encode thread has made every call. The drains, the blocked ones and their wall time are counted for the translation detail line
// (mtl_wait_stats; a clock is read only when the drain blocks); DM_NVN_WAITS=1's ledger counts them too, with the time of every drain
static _Atomic uint64_t g_drains, g_drains_blocked, g_drain_ns;
static void rec_drain_at(const char *site) {
    if (!g_rb_started) return;
    rec_publish();
    uint64_t w0 = ws_t0(), b0 = 0; int blocked = 0; wait_mark m = {0, 1};
    pthread_mutex_lock(&g_rb_mu);
    atomic_fetch_add(&g_rx_drain, 1); if (g_rb_sleeping) pthread_cond_signal(&g_rb_work);   // held commits go now (DM_NVN_SUB_MERGE)
    while (g_rb_head || g_rb_busy || atomic_load(&g_rx_held)) {
        if (!blocked) { b0 = now_ns(); wn_in(WN_DRAIN, 0); wait_mark_set(&m); }   // the 10 s line, once; the wait is as long as before
        blocked = 1;
        if (atomic_load(&g_rx_held)) { struct timespec ts = {0, 2000000}; pthread_cond_timedwait_relative_np(&g_rb_idle, &g_rb_mu, &ts); if (g_rb_sleeping) pthread_cond_signal(&g_rb_work); }   // a wake the encode thread missed is made again
        else wait_mark_sleep(&g_rb_idle, &g_rb_mu, &m);
        if ((g_rb_head || g_rb_busy || atomic_load(&g_rx_held)) && wait_mark_due(&m)) {
            static _Atomic int n; char rx[160]; rx_now(rx, sizeof rx); int blocks = 0; for (rec_blk *b = g_rb_head; b; b = b->next) blocks++;
            wait_say(&n, "the encode thread to drain", site, "%d blocks queued, %d submissions held, %s; fences completed %llu, submitted %llu", blocks, g_rx_npend, rx, (unsigned long long)atomic_load(&g_done), (unsigned long long)atomic_load(&g_fence));
        }
    }
    atomic_fetch_sub(&g_rx_drain, 1);
    if (blocked) wn_out(WN_DRAIN);
    pthread_mutex_unlock(&g_rb_mu);
    atomic_fetch_add_explicit(&g_drains, 1, memory_order_relaxed);
    if (blocked) { atomic_fetch_add_explicit(&g_drains_blocked, 1, memory_order_relaxed); atomic_fetch_add_explicit(&g_drain_ns, now_ns() - b0, memory_order_relaxed); }
    if (ws_on()) ws_put(WS_DRAIN, w0, blocked);
}
#define rec_drain() rec_drain_at(LOCK_SITE)
// Whether the GPU still has main work, as the replay sees it with the encode thread on (nvn_mtl.m cut_busy, DM_NVN_CUT_EVENT): a commit recorded and not yet on the queue (still in
// the records, or held by the encode thread), or one on the queue whose event the GPU has not written yet. The commit feedback the replay read before (g_seg_inflight) comes
// 0.08-1.2 ms after the GPU's end, where the event is written about 0.04 ms after it (see rx_busy); an upload batch on the queue counts as work too, as it does for rx_busy
static int rec_gpu_busy(void) {
    if (atomic_load_explicit(&g_rx_busy_hold, memory_order_relaxed)) return 1;
    if (atomic_load_explicit(&g_rx_made, memory_order_acquire) < g_rec_cmts) return 1;
    uint64_t s = atomic_load_explicit(&g_rx_seq_pub, memory_order_acquire);
    return s && g_rx_ev.signaledValue < s;
}
// The held submissions go to the queue at this point of what is recorded, and with them their notes (g_sub_cmt). A present of the game's own texture without a snapshot records it:
// its display command buffer goes to the queue straight from the present thread once the encode thread has noted the frame's last submission (sub_commit_wait). Held until the GPU ran
// out of work, that submission went with the next frame's first ones, the present thread waited for the GPU to go idle, and the display command buffer, which waits for all earlier work
// on the queue, followed part of the next frame. Upstream's present goes through the encode thread's queue, which sends the held ones there too
static void rec_flush_held(void) { if (rec_on() && g_rb_started) { rec_put(RO_FLUSH, 0); rec_publish(); } }
// A block of records from another thread than the submit thread (the present snapshot's copy): it goes in one piece behind every block published so far. Everything the game
// submitted before it presents is published by then (a submission publishes its records before it returns), so the block runs after the frame's work, and the presenting thread
// does not wait for the encode thread
static rec_blk *rec_own_begin(void) {
    pthread_mutex_lock(&g_rb_mu); rec_blk *b = g_rb_free; if (b) g_rb_free = b->next; pthread_mutex_unlock(&g_rb_mu);
    if (!b) b = rec_blk_new();
    b->n = 0; return b;
}
static rec_t *rec_own_put(rec_blk *b, uint32_t op, uint32_t nobj) { if (b->n >= rec_blk_n()) MDIE("deferred encoding: an own block is full"); rec_t *r = &b->r[b->n++]; r->op = op; r->nobj = nobj; return r; }
static void rec_own_push(rec_blk *b) {
    pthread_mutex_lock(&g_rb_mu);
    b->next = NULL; if (g_rb_tail) g_rb_tail->next = b; else g_rb_head = b; g_rb_tail = b;
    if (g_rb_sleeping) pthread_cond_signal(&g_rb_work);
    pthread_mutex_unlock(&g_rb_mu);
}
static __attribute__((noreturn)) void rec_missing(id o, SEL s) { MDIE("deferred encoding: %s has no stand-in for -%s (DM_NVN_ENC_THREAD=0 runs without it)", object_getClassName(o), sel_getName(s)); }

// Argument tables: every stand-in is made once and kept for good (rec_table), so the real table is passed without a retain
@interface DmRecTable : NSObject { @public id real; } @end
static inline void rec_table_op(uint32_t op, id t, uint64_t v, NSUInteger i) { rec_t *r = rec_put(op, 0); r->a[0] = (uint64_t)(uintptr_t)(__bridge void *)((DmRecTable *)t)->real; r->a[1] = v; r->a[2] = i; }
@implementation DmRecTable
- (void)setAddress:(uint64_t)gpu atIndex:(NSUInteger)i { rec_table_op(RO_T_ADDR, self, gpu, i); }
- (void)setTexture:(MTLResourceID)t atIndex:(NSUInteger)i { rec_table_op(RO_T_TEX, self, t._impl, i); }
- (void)setSamplerState:(MTLResourceID)t atIndex:(NSUInteger)i { rec_table_op(RO_T_SAMP, self, t._impl, i); }
- (id)forwardingTargetForSelector:(SEL)s { rec_missing(self, s); }
@end
static inline id rec_table_real(id t) { return [t isKindOfClass:[DmRecTable class]] ? ((DmRecTable *)t)->real : t; }

@interface DmRecEnc : NSObject @end
@implementation DmRecEnc
- (BOOL)conformsToProtocol:(Protocol *)p { return p == @protocol(MTL4CommandEncoder) || p == @protocol(MTL4RenderCommandEncoder) || p == @protocol(MTL4ComputeCommandEncoder) || [super conformsToProtocol:p]; }
- (id)forwardingTargetForSelector:(SEL)s { rec_missing(self, s); }
- (void)endEncoding { rec_put(RO_END, 0); }
- (void)barrierAfterQueueStages:(MTLStages)a beforeStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)v { rec_t *r = rec_put(RO_BAR_QUEUE, 0); r->a[0] = a; r->a[1] = b; r->a[2] = v; }
- (void)barrierAfterStages:(MTLStages)a beforeQueueStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)v { rec_t *r = rec_put(RO_BAR_AFTER_STAGES, 0); r->a[0] = a; r->a[1] = b; r->a[2] = v; }
- (void)barrierAfterEncoderStages:(MTLStages)a beforeEncoderStages:(MTLStages)b visibilityOptions:(MTL4VisibilityOptions)v { rec_t *r = rec_put(RO_BAR_ENCODER, 0); r->a[0] = a; r->a[1] = b; r->a[2] = v; }
// Render
- (void)setArgumentTable:(id)t atStages:(MTLRenderStages)s { id x = rec_table_real(t); int keep = x != t; rec_t *r = rec_put(RO_R_TABLE, !keep); r->a[0] = keep ? (uint64_t)(uintptr_t)(__bridge void *)x : rec_obj(x); r->a[1] = s; }
- (void)setRenderPipelineState:(id)p { rec_t *r = rec_put(RO_R_PSO, 1); r->a[0] = rec_obj(p); }
- (void)setDepthStencilState:(id)s { rec_t *r = rec_put(RO_R_DSS, 1); r->a[0] = rec_obj(s); }
- (void)setViewport:(MTLViewport)v { rec_t *r = rec_put(RO_R_VIEWPORT, 0); memcpy(r->a, &v, sizeof v); }
- (void)setScissorRect:(MTLScissorRect)s { rec_t *r = rec_put(RO_R_SCISSOR, 0); memcpy(r->a, &s, sizeof s); }
- (void)setCullMode:(MTLCullMode)m { rec_put(RO_R_CULL, 0)->a[0] = m; }
- (void)setFrontFacingWinding:(MTLWinding)w { rec_put(RO_R_WINDING, 0)->a[0] = w; }
- (void)setTriangleFillMode:(MTLTriangleFillMode)m { rec_put(RO_R_FILL, 0)->a[0] = m; }
- (void)setDepthBias:(float)u slopeScale:(float)s clamp:(float)c { rec_t *r = rec_put(RO_R_BIAS, 0); r->a[0] = rec_f(u); r->a[1] = rec_f(s); r->a[2] = rec_f(c); }
- (void)setDepthClipMode:(MTLDepthClipMode)m { rec_put(RO_R_CLIP, 0)->a[0] = m; }
- (void)setDepthTestMinBound:(float)lo maxBound:(float)hi { rec_t *r = rec_put(RO_R_DBND, 0); r->a[0] = rec_f(lo); r->a[1] = rec_f(hi); }
- (void)setStencilReferenceValue:(uint32_t)v { rec_t *r = rec_put(RO_R_SREF, 0); r->a[0] = r->a[1] = v; }
- (void)setStencilFrontReferenceValue:(uint32_t)f backReferenceValue:(uint32_t)b { rec_t *r = rec_put(RO_R_SREF, 0); r->a[0] = f; r->a[1] = b; }
- (void)setBlendColorRed:(float)r_ green:(float)g blue:(float)b alpha:(float)a { rec_t *r = rec_put(RO_R_BLEND, 0); r->a[0] = rec_f(r_); r->a[1] = rec_f(g); r->a[2] = rec_f(b); r->a[3] = rec_f(a); }
- (void)setVisibilityResultMode:(MTLVisibilityResultMode)m offset:(NSUInteger)o { rec_t *r = rec_put(RO_R_VIS, 0); r->a[0] = m; r->a[1] = o; }
- (void)setVertexAmplificationCount:(NSUInteger)n viewMappings:(const MTLVertexAmplificationViewMapping *)m { rec_t *r = rec_put(RO_R_AMP, 0); r->a[0] = n; r->a[1] = n && m ? m[0].viewportArrayIndexOffset : 0; r->a[2] = n && m ? m[0].renderTargetArrayIndexOffset : 0; }
- (void)setColorAttachmentMap:(MTLLogicalToPhysicalColorAttachmentMap *)m { rec_put(RO_R_CMAP, 0)->a[0] = (uint64_t)(uintptr_t)(__bridge void *)m; }
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n { rec_t *r = rec_put(RO_R_DRAW, 0); r->a[0] = p; r->a[1] = v; r->a[2] = n; }
- (void)drawPrimitives:(MTLPrimitiveType)p vertexStart:(NSUInteger)v vertexCount:(NSUInteger)n instanceCount:(NSUInteger)i baseInstance:(NSUInteger)b {
    rec_t *r = rec_put(RO_R_DRAW_INST, 0); r->a[0] = p; r->a[1] = v; r->a[2] = n; r->a[3] = i; r->a[4] = b; }
- (void)drawPrimitives:(MTLPrimitiveType)p indirectBuffer:(uint64_t)g { rec_t *r = rec_put(RO_R_DRAW_IND, 0); r->a[0] = p; r->a[1] = g; }
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexCount:(NSUInteger)n indexType:(MTLIndexType)t indexBuffer:(uint64_t)g indexBufferLength:(NSUInteger)len instanceCount:(NSUInteger)i baseVertex:(NSInteger)bv baseInstance:(NSUInteger)bi {
    rec_t *r = rec_put(RO_R_DRAW_IDX, 0); r->a[0] = p; r->a[1] = n; r->a[2] = t; r->a[3] = g; r->a[4] = len; r->a[5] = i; r->a[6] = (uint64_t)bv; r->a[7] = bi; }
- (void)drawIndexedPrimitives:(MTLPrimitiveType)p indexType:(MTLIndexType)t indexBuffer:(uint64_t)g indexBufferLength:(NSUInteger)len indirectBuffer:(uint64_t)ind {
    rec_t *r = rec_put(RO_R_DRAW_IDX_IND, 0); r->a[0] = p; r->a[1] = t; r->a[2] = g; r->a[3] = len; r->a[4] = ind; }
- (void)drawMeshThreadgroups:(MTLSize)g threadsPerObjectThreadgroup:(MTLSize)o threadsPerMeshThreadgroup:(MTLSize)m { rec_t *r = rec_put(RO_R_MESH, 0); r->a[0] = g.width; r->a[1] = m.width; r->a[2] = o.width; }
- (void)drawMeshThreadgroupsWithIndirectBuffer:(MTLGPUAddress)ib threadsPerObjectThreadgroup:(MTLSize)o threadsPerMeshThreadgroup:(MTLSize)m { rec_t *r = rec_put(RO_R_MESH_IND, 0); r->a[0] = ib; r->a[1] = m.width; r->a[2] = o.width; }
- (void)setColorStoreAction:(MTLStoreAction)a atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_R_STORE_C, 0); r->a[0] = a; r->a[1] = i; }
- (void)setDepthStoreAction:(MTLStoreAction)a { rec_put(RO_R_STORE_D, 0)->a[0] = a; }
- (void)setStencilStoreAction:(MTLStoreAction)a { rec_put(RO_R_STORE_S, 0)->a[0] = a; }
// Compute and copies (Metal 4 copies are on the compute encoder)
- (void)setArgumentTable:(id)t { id x = rec_table_real(t); int keep = x != t; rec_t *r = rec_put(RO_C_TABLE, !keep); r->a[0] = keep ? (uint64_t)(uintptr_t)(__bridge void *)x : rec_obj(x); }
- (void)setComputePipelineState:(id)p { rec_t *r = rec_put(RO_C_PSO, 1); r->a[0] = rec_obj(p); }
- (void)dispatchThreadgroups:(MTLSize)n threadsPerThreadgroup:(MTLSize)t { rec_t *r = rec_put(RO_C_DISPATCH, 0); r->a[0] = n.width; r->a[1] = n.height; r->a[2] = n.depth; r->a[3] = t.width; r->a[4] = t.height; r->a[5] = t.depth; }
- (void)dispatchThreadgroupsWithIndirectBuffer:(uint64_t)g threadsPerThreadgroup:(MTLSize)t { rec_t *r = rec_put(RO_C_DISPATCH_IND, 0); r->a[0] = g; r->a[1] = t.width; r->a[2] = t.height; r->a[3] = t.depth; }
- (void)copyFromBuffer:(id)s sourceOffset:(NSUInteger)so toBuffer:(id)d destinationOffset:(NSUInteger)doff size:(NSUInteger)n {
    rec_t *r = rec_put(RO_C_COPY_BB, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = so; r->a[3] = doff; r->a[4] = n; }
- (void)copyFromBuffer:(id)s sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)img sourceSize:(MTLSize)z toTexture:(id)d destinationSlice:(NSUInteger)sl destinationLevel:(NSUInteger)lv destinationOrigin:(MTLOrigin)o {
    rec_t *r = rec_put(RO_C_COPY_BT, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = so; r->a[3] = row; r->a[4] = img; r->a[5] = z.width; r->a[6] = z.height; r->a[7] = z.depth;
    r->a[8] = sl; r->a[9] = lv; r->a[10] = o.x; r->a[11] = o.y; r->a[12] = o.z; }
// The two copies with blit options move one plane of a combined depth / stencil texture through a buffer (the depth plane copy, nvn_mtl.m enc_b_copy_*_opt); without their stand-ins
// the encode thread stopped there (t_unwritten_store with DM_NVN_ENC_THREAD=1, the iOS default)
- (void)copyFromBuffer:(id)s sourceOffset:(NSUInteger)so sourceBytesPerRow:(NSUInteger)row sourceBytesPerImage:(NSUInteger)img sourceSize:(MTLSize)z toTexture:(id)d destinationSlice:(NSUInteger)sl destinationLevel:(NSUInteger)lv destinationOrigin:(MTLOrigin)o options:(MTLBlitOption)opt {
    rec_t *r = rec_put(RO_C_COPY_BT_OPT, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = so; r->a[3] = row; r->a[4] = img; r->a[5] = z.width; r->a[6] = z.height; r->a[7] = z.depth;
    r->a[8] = sl; r->a[9] = lv; r->a[10] = o.x; r->a[11] = o.y; r->a[12] = o.z; r->a[13] = opt; }
- (void)copyFromTexture:(id)s sourceSlice:(NSUInteger)sl sourceLevel:(NSUInteger)lv sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)z toBuffer:(id)d destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)img {
    rec_t *r = rec_put(RO_C_COPY_TB, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = sl; r->a[3] = lv; r->a[4] = o.x; r->a[5] = o.y; r->a[6] = o.z; r->a[7] = z.width; r->a[8] = z.height; r->a[9] = z.depth;
    r->a[10] = doff; r->a[11] = row; r->a[12] = img; }
- (void)copyFromTexture:(id)s sourceSlice:(NSUInteger)sl sourceLevel:(NSUInteger)lv sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)z toBuffer:(id)d destinationOffset:(NSUInteger)doff destinationBytesPerRow:(NSUInteger)row destinationBytesPerImage:(NSUInteger)img options:(MTLBlitOption)opt {
    rec_t *r = rec_put(RO_C_COPY_TB_OPT, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = sl; r->a[3] = lv; r->a[4] = o.x; r->a[5] = o.y; r->a[6] = o.z; r->a[7] = z.width; r->a[8] = z.height; r->a[9] = z.depth;
    r->a[10] = doff; r->a[11] = row; r->a[12] = img; r->a[13] = opt; }
- (void)copyFromTexture:(id)s sourceSlice:(NSUInteger)sl sourceLevel:(NSUInteger)lv sourceOrigin:(MTLOrigin)o sourceSize:(MTLSize)z toTexture:(id)d destinationSlice:(NSUInteger)dsl destinationLevel:(NSUInteger)dlv destinationOrigin:(MTLOrigin)dorg {
    rec_t *r = rec_put(RO_C_COPY_TT, 2); r->a[0] = rec_obj(s); r->a[1] = rec_obj(d); r->a[2] = sl; r->a[3] = lv; r->a[4] = o.x; r->a[5] = o.y; r->a[6] = o.z; r->a[7] = z.width; r->a[8] = z.height; r->a[9] = z.depth;
    r->a[10] = dsl; r->a[11] = dlv; r->a[12] = dorg.x; r->a[13] = dorg.y; r->a[14] = dorg.z; }
- (void)fillBuffer:(id)b range:(NSRange)rg value:(uint8_t)v { rec_t *r = rec_put(RO_C_FILL, 1); r->a[0] = rec_obj(b); r->a[1] = rg.location; r->a[2] = rg.length; r->a[3] = v; }
// Diagnostics: encoder labels (DM_NVN_ENC_LABEL) and timestamps into a counter heap (DM_NVN_GPUPROF); the render form names a stage, the compute form none
- (void)setLabel:(NSString *)l { rec_put(RO_LABEL, 1)->a[0] = rec_obj(l); }
- (void)writeTimestampWithGranularity:(MTL4TimestampGranularity)g afterStage:(MTLRenderStages)st intoHeap:(id)h atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_R_TS, 1); r->a[0] = rec_obj(h); r->a[1] = g; r->a[2] = st; r->a[3] = i; }
- (void)writeTimestampWithGranularity:(MTL4TimestampGranularity)g intoHeap:(id)h atIndex:(NSUInteger)i { rec_t *r = rec_put(RO_C_TS, 1); r->a[0] = rec_obj(h); r->a[1] = g; r->a[2] = i; }
@end

@interface DmRecCB : NSObject @end
@implementation DmRecCB
- (id)forwardingTargetForSelector:(SEL)s { rec_missing(self, s); }
- (void)beginCommandBufferWithAllocator:(id)a { rec_put(RO_CB_BEGIN, 1)->a[0] = rec_obj(a); }
- (void)endCommandBuffer { rec_put(RO_CB_END, 0); }
- (id)renderCommandEncoderWithDescriptor:(MTL4RenderPassDescriptor *)d { rec_put(RO_RE_BEGIN, 1)->a[0] = rec_obj([d copy]); return [DmRecEnc new]; }   // copied: the replay may reuse or change the descriptor afterwards
- (id)computeCommandEncoder { rec_put(RO_CE_BEGIN, 0); return [DmRecEnc new]; }
@end

// The replay's entry points
static id rec_cb_new(void) { if (!rec_on()) return [g_dev newCommandBuffer]; rec_put(RO_CB_NEW, 0); return [DmRecCB new]; }
// Work a framework encodes itself (MetalFX's scalers) needs the real command buffer: on the encoding thread, in order with the recorded encoders
static void rec_cb_block(id cb, void (^block)(id<MTL4CommandBuffer>)) {
    if ([cb isKindOfClass:[DmRecCB class]]) rec_put(RO_CB_BLOCK, 1)->a[0] = rec_obj([block copy]);
    else block(cb);
}
static id rec_table(id t) { if (!rec_on() || !t) return t; DmRecTable *s = [DmRecTable new]; s->real = t; return s; }
// The replay's main command buffer: committed once the uniform shadows queued so far are made (ubc_wait). end: the submission ends with this command buffer (the encode thread may hold
// it and commit it with the next ones: held submissions)
static void rec_commit(id cb, DmCommitFB *fb, int end) {
    if ([cb isKindOfClass:[DmRecCB class]]) { g_rec_cmts++; rec_t *r = rec_put(RO_COMMIT, 1); r->a[0] = rec_obj(fb); r->a[2] = ubc_head(); r->a[5] = (uint64_t)end; r->a[6] = res_seq_now(); return; }
    ubc_wait(ubc_head());
    id<MTL4CommandBuffer> buffers[] = {cb}; MTL4CommitOptions *o = commit_opts(fb);
    Q4_COMMIT_TIMED("rec_commit (a main command buffer, no encode thread)", if (o) [g_q4 commit:buffers count:1 options:o]; else [g_q4 commit:buffers count:1]);
}
// An upload batch: its place in the queue is after what is recorded so far (it reads no uniform shadow)
static void rec_commit_upload(id cb, MTL4CommitOptions *o) {
    if (rec_on() && g_rb_started) { rec_t *r = rec_put(RO_COMMIT_REAL, 2); r->a[0] = rec_obj(o); r->a[1] = rec_obj(cb); r->a[2] = res_seq_now(); return; }
    id<MTL4CommandBuffer> buffers[] = {cb};
    Q4_COMMIT_TIMED("rec_commit_upload (an upload batch, no encode thread)", if (o) [g_q4 commit:buffers count:1 options:o]; else [g_q4 commit:buffers count:1]);
}
// A queue operation (a sparse texture's mapping update, nvn_mtl.m sparse_*): on the encoding thread in its place among the recorded commits, so it reaches the queue before the upload batch
// committed after it and after the command buffers committed before it
static void rec_queue_block(void (^block)(void)) { if (rec_on() && g_rb_started) { rec_t *r = rec_put(RO_Q_BLOCK, 1); r->a[0] = rec_obj([block copy]); r->a[1] = res_seq_now(); } else block(); }
static void rec_signal(id ev, uint64_t v) { if (rec_on() && g_rb_started) { rec_t *r = rec_put(RO_SIGNAL, 1); r->a[0] = rec_obj(ev); r->a[1] = v; } else [g_q4 signalEvent:ev value:v]; }
