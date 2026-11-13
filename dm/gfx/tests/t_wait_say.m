// The host's waits with no limit say so once they pass the 10 s mark (nvn_mtl.m wait_say and wait_fence_say; nvn_rec.h ubc_wait, rec_drain, rec_note_wait). Ocarina of Time's test 3
// froze with nothing in the log: the game's SyncWait (mtl_wait_at's fast wake, on the GPU event for up to an hour), up_wait_zero, the present waits and the encode and copy threads'
// waits had no line. With the mark shortened to 150 ms (g_wait_say_ns), each wait is held past it on a thread of its own: it writes its red line once, with its site, however many
// marks pass after, and it still returns only once what it waits for has come (the GPU's gate opened, the upload count back to 0, the present ticket processed, the encode thread or
// the copy thread let go); a finite SyncWait still times out at its own limit, not before. A wait that ends before the mark says nothing. Real Metal 4 queue, no window. The present
// allocator's wait in present_now is t_present_alloc's
#define UBC_T_SLEEPING() ubc_t_sleeping()
static void ubc_t_sleeping(void);
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; printf("FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)
// The copy thread held on its way to sleep (nvn_rec.h's UBC_T_SLEEPING hook), so that a copy pushed meanwhile waits for it
static _Atomic int g_ubc_hold, g_ubc_in_hook;
static void ubc_t_sleeping(void) {
    if (!atomic_load(&g_ubc_hold)) return;
    atomic_store(&g_ubc_in_hook, 1); while (atomic_load(&g_ubc_hold)) usleep(1000); atomic_store(&g_ubc_in_hook, 0);
}
// stderr (MLOG) goes to an unlinked file for the whole run; log_new() returns what was written since its last call (and echoes it)
static char g_log[65536]; static int g_logfd = -1; static off_t g_logoff;
static const char *log_new(void) {
    fflush(stderr); ssize_t n = g_logfd < 0 ? 0 : pread(g_logfd, g_log, sizeof g_log - 1, g_logoff); if (n < 0) n = 0;
    g_log[n] = 0; g_logoff += n; fputs(g_log, stdout); return g_log;
}
static int count(const char *s, const char *w) { int n = 0; for (const char *p = s; (p = strstr(p, w)); p += strlen(w)) n++; return n; }
// A wait on a thread of its own; returned() gives it ms to return
static dispatch_semaphore_t run(void (^b)(void)) {
    dispatch_semaphore_t s = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ b(); dispatch_semaphore_signal(s); });
    return s;
}
static int returned(dispatch_semaphore_t s, int64_t ms) { return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, ms * (int64_t)NSEC_PER_MSEC)) == 0; }
enum { HOLD_MS = 500 };   // past three marks of 150 ms: the line still comes once
// GPU work held by a shared-event gate: a submission whose fence completes only once the gate opens
static uint64_t held_fence(id<MTLSharedEvent> gate, uint64_t v) {
    rec_drain(); [g_q4 waitForEvent:gate value:v];
    mtl_sub_begin(); return mtl_sub_commit();
}
static _Atomic int g_enc_hold;
static void hold_encoder(void) { atomic_store(&g_enc_hold, 1); rec_queue_block(^{ while (atomic_load(&g_enc_hold)) usleep(1000); }); }

int main(void) { @autoreleasepool {
    alarm(60); setvbuf(stdout, NULL, _IONBF, 0);
    { char path[] = "/tmp/t_wait_say.XXXXXX"; g_logfd = mkstemp(path); if (g_logfd >= 0) { unlink(path); fflush(stderr); dup2(g_logfd, 2); } }
    setenv("DM_NVN_ENC_THREAD", "1", 1); setenv("DM_PRESENT_LINK", "0", 1);
    mtl_init();
    CHECK(g_wait_say_ns == 10000000000ull, "the mark is 10 s");
    mtl_sub_begin(); CHECK(mtl_wait(mtl_sub_commit(), 2000000000ull) && rec_on() && g_rb_started, "an empty submission completes, encoding on its own thread");
    g_wait_say_ns = 150000000ull;
    char want[256]; const char *log;

    // 1. The game's SyncWait on the newest fence (the fast wake: the GPU event, in slices of the mark), with no limit: one line, with the stuck command buffer's report after it
    id<MTLSharedEvent> gate = [g_dev newSharedEvent]; if (!gate) abort();
    uint64_t f = held_fence(gate, 1);
    CHECK(fast_wake() && f == atomic_load(&g_fence) && atomic_load(&g_done) < f, "setup: a fence held by the gate, the fast wake on");
    __block int ok = 0;
    dispatch_semaphore_t s = run(^{ ok = mtl_wait(f, UINT64_MAX); });
    CHECK(!returned(s, HOLD_MS), "the SyncWait waits on past the mark while the GPU is held");
    gate.signaledValue = 1;
    CHECK(returned(s, 5000) && ok, "it returns once the gate opens, the fence complete");
    log = log_new();
    snprintf(want, sizeof want, "[RED] the host has waited 0.15 s for GPU work up to fence %llu (wait site %d, %s)", (unsigned long long)f, WS_SYNC_NEWEST, ws_name[WS_SYNC_NEWEST]);
    CHECK(count(log, want) == 1, "the fast wake's line, once in three marks, with the wait site");
    CHECK(count(log, "the host has waited") == 1, "no other wait said anything");

    // 2. A SyncWait with a limit past the mark says it too, and still times out at its limit; one whose limit comes before the mark says nothing
    f = held_fence(gate, 2);
    uint64_t t0 = bp_now(); int r = mtl_wait(f, 400000000ull); uint64_t took = bp_now() - t0;
    log = log_new();
    CHECK(!r && took >= 390000000ull && took < 2000000000ull, "a 400 ms SyncWait on a held fence times out at 400 ms");
    snprintf(want, sizeof want, "waited 0.15 s for GPU work up to fence %llu (wait site %d", (unsigned long long)f, WS_SYNC_NEWEST);
    CHECK(count(log, want) == 1, "and says the mark once");
    t0 = bp_now(); r = mtl_wait(f, 100000000ull); took = bp_now() - t0;
    log = log_new();
    CHECK(!r && took >= 90000000ull && count(log, "the host has waited") == 0, "a 100 ms SyncWait times out at 100 ms and says nothing");

    // 3. The feedback wait (the condition variable: a host wait such as the allocator's), no limit: once
    s = run(^{ ok = mtl_wait_at(f, UINT64_MAX, WS_DIAG); });
    CHECK(!returned(s, HOLD_MS), "the host's fence wait waits on past the mark");
    gate.signaledValue = 2;
    CHECK(returned(s, 5000) && ok, "it returns once the gate opens");
    log = log_new();
    snprintf(want, sizeof want, "waited 0.15 s for GPU work up to fence %llu (wait site %d, %s)", (unsigned long long)f, WS_DIAG, ws_name[WS_DIAG]);
    CHECK(count(log, want) == 1, "the feedback wait's line, once");

    // 4. up_wait_zero: an upload batch that does not complete
    atomic_fetch_add(&g_up_pending, 1);
    s = run(^{ up_wait_zero(&g_up_pending, WS_FINISH); });
    CHECK(!returned(s, HOLD_MS), "up_wait_zero waits on past the mark");
    atomic_fetch_sub(&g_up_pending, 1); up_wake();
    CHECK(returned(s, 5000), "it returns once the count is back to 0");
    log = log_new();
    snprintf(want, sizeof want, "waited 0.15 s for the upload batches to complete at %s (thread", ws_name[WS_FINISH]);
    CHECK(count(log, want) == 1 && count(log, "1 pending") == 1, "up_wait_zero's line, once, with its wait site and the count");

    // 5. mtl_present_wait: a ticket the present thread has not processed (no display link here: the condition variable alone)
    pthread_mutex_lock(&g_pq_mu); uint64_t tk = g_pq_done + 1; pthread_mutex_unlock(&g_pq_mu);
    CHECK(!g_link_owns_layer && !atomic_load(&g_present_discard), "setup: presents without the display link, not discarded");
    s = run(^{ mtl_present_wait(tk); });
    CHECK(!returned(s, HOLD_MS), "the present wait waits on past the mark");
    pthread_mutex_lock(&g_pq_mu); g_pq_done = tk; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
    CHECK(returned(s, 5000), "it returns once the ticket is processed");
    log = log_new();
    snprintf(want, sizeof want, "waited 0.15 s for a present to be handed to the GPU at mtl_present_wait (thread ");
    char tkw[64]; snprintf(tkw, sizeof tkw, "): ticket %llu;", (unsigned long long)tk);
    CHECK(count(log, want) == 1 && count(log, tkw) == 1, "the present wait's line, once, with its site and ticket");
    s = run(^{ mtl_present_wait(tk + 1); });
    usleep(50000);
    pthread_mutex_lock(&g_pq_mu); g_pq_done = tk + 1; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
    CHECK(returned(s, 5000) && count(log_new(), "the host has waited") == 0, "a present wait that ends before the mark says nothing");

    // 6. rec_drain: the encode thread held in a queue operation
    hold_encoder();
    s = run(^{ rec_drain(); });
    CHECK(!returned(s, HOLD_MS), "rec_drain waits on past the mark");
    atomic_store(&g_enc_hold, 0);
    CHECK(returned(s, 5000), "it returns once the encode thread is let go");
    log = log_new();
    CHECK(count(log, "waited 0.15 s for the encode thread to drain at t_wait_say.m:") == 1 && count(log, "in a queue operation (RO_Q_BLOCK)") == 1,
          "rec_drain's line, once, with the caller's file:line and what the encode thread does");

    // 7. rec_note_wait: a note behind the held encode thread
    static _Atomic uint64_t note;
    hold_encoder();
    { rec_t *n = rec_put(RO_NOTE, 0); n->a[0] = (uint64_t)(uintptr_t)&note; n->a[1] = 1; rec_publish(); }
    s = run(^{ rec_note_wait(&note, 1); });
    CHECK(!returned(s, HOLD_MS), "rec_note_wait waits on past the mark");
    atomic_store(&g_enc_hold, 0);
    CHECK(returned(s, 5000) && atomic_load(&note) == 1, "it returns once the encode thread passes the note");
    log = log_new();
    CHECK(count(log, "waited 0.15 s for the encode thread's note at t_wait_say.m:") == 1 && count(log, "value 1, the note at 0;") == 1, "rec_note_wait's line, once, with its site and values");
    rec_drain();

    // 8. ubc_wait: the copy thread held on its way to sleep after a first copy, a second one pushed behind it
    uint64_t a = 7, b = 0, c = 9, d = 0;
    atomic_store(&g_ubc_hold, 1);
    ubc_wait(ubc_push(&b, &a, sizeof a));
    for (int i = 0; i < 2000 && !atomic_load(&g_ubc_in_hook); i++) usleep(1000);
    CHECK(b == 7 && atomic_load(&g_ubc_in_hook), "setup: the first copy made, the copy thread held");
    uint64_t seq = ubc_push(&d, &c, sizeof c);
    s = run(^{ ubc_wait(seq); });
    CHECK(!returned(s, HOLD_MS), "ubc_wait waits on past the mark");
    atomic_store(&g_ubc_hold, 0);
    CHECK(returned(s, 5000) && d == 9, "it returns once the copy thread is let go, the copy made");
    log = log_new();
    snprintf(want, sizeof want, "waited 0.15 s for the uniform copies at t_wait_say.m:");
    CHECK(count(log, want) == 1 && count(log, "up to op ") == 1, "ubc_wait's line, once, with its site");

    g_wait_say_ns = 10000000000ull;
    printf("t_wait_say: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
