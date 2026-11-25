// Two measurement-only log parts of the frame chain: the display link line's deadline part (nvn_mtl.m lk_line: commits past the callback's targetTimestamp and the callback's
// blocking, p50 / p95 / max of those that were late or blocked) and the threads line's core placement (hle_nvn.c dm_tcore_sample / dm_tcore_text: each role's thread samples
// itself once a frame; time and energy by core type since the last line; a role that moved thread starts again there). No GPU work.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static void busy_ms(double ms) { uint64_t t = bp_now(); while (bp_now() - t < (uint64_t)(ms * 1e6)) {} }
static _Atomic int g_role_go;
static void *role_thread(void *arg) {   // the encode role on a thread of its own: 40 ms of work over 4 frames
    (void)arg; pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    dm_tcore_sample(DM_TCORE_ENCODE, 1);
    for (uint64_t f = 2; f <= 5; f++) { busy_ms(10); dm_tcore_sample(DM_TCORE_ENCODE, f); dm_tcore_sample(DM_TCORE_ENCODE, f); }   // the second call in a frame is a no-op
    atomic_store(&g_role_go, 1);
    return NULL;
}

int main(void) { @autoreleasepool {
    // 1. lk_line: 300 presents, 30 of them committed after the deadline by 0.1-3.0 ms, the rest 1 ms early; 10 unknown (no deadline); 20 blocked for the encode thread, 5 for the allocator
    double late[300], cw[300], aw[300];
    for (int i = 0; i < 300; i++) { late[i] = i < 30 ? 0.1 * (i + 1) : i < 290 ? -1.0 : NAN; cw[i] = i % 15 == 0 ? 0.5 + i / 300.0 : 0; aw[i] = i < 5 ? 2.0 : 0; }
    const char *t = lk_line(late, cw, aw);
    printf("lk_line:%s\n", t);
    CHECK(strstr(t, "commits after the callback's deadline (targetTimestamp) 30 of 290, late by p50 1.600 / p95 2.900 / max 3.000 ms"), "late part: %s", t);
    CHECK(strstr(t, "notes (snapshot, upload, submission) on 20, "), "commit-wait count: %s", t);
    CHECK(strstr(t, "for the present allocator on 5, p50 2.000 / p95 2.000 / max 2.000 ms"), "allocator part: %s", t);
    for (int i = 0; i < 300; i++) { late[i] = -0.5; cw[i] = aw[i] = 0; }
    t = lk_line(late, cw, aw);
    CHECK(strstr(t, "deadline (targetTimestamp) 0 of 300, late by p50 0.000") && strstr(t, "notes (snapshot, upload, submission) on 0,"), "all on time: %s", t);

    // 2. Core placement: the encode role samples on its own thread, the replay role on this one; 40 ms of work shows in its CPU time, and the text names every role
    char out[512]; setenv("DM_POWER_DETAIL", "1", 1);
    dm_tcore_text(out, sizeof out, 1);   // baselines
    pthread_t th; pthread_create(&th, NULL, role_thread, NULL); pthread_join(th, NULL);
    dm_tcore_sample(DM_TCORE_REPLAY, 1); busy_ms(5); dm_tcore_sample(DM_TCORE_REPLAY, 2);
    dm_tcore_text(out, sizeof out, 1.0);   // over "1 s": the figures are ms
    printf("dm_tcore_text:%s\n", out);
    CHECK(strstr(out, "acquiring (frame) thread") && strstr(out, " replay ") && strstr(out, " encode ") && strstr(out, " present "), "a role is missing: %s", out);
    double ep = -1, ee = -1, rp = -1, re = -1; const char *q = strstr(out, " encode "), *r = strstr(out, " replay ");
    if (q) sscanf(q, " encode %lf / %lf", &ep, &ee);
    if (r) sscanf(r, " replay %lf / %lf", &rp, &re);
    CHECK(ep + ee > 30 && ep + ee < 80, "the encode role's 40 ms of work read as %.0f + %.0f ms", ep, ee);
    CHECK(rp + re >= 3 && rp + re < 30, "the replay role's 5 ms read as %.0f + %.0f ms", rp, re);
    // the role sampled on another thread (this one) starts there: its first sample adds nothing
    busy_ms(5); dm_tcore_sample(DM_TCORE_ENCODE, 100); busy_ms(5);
    dm_tcore_text(out, sizeof out, 1.0); q = strstr(out, " encode "); ep = ee = -1; if (q) sscanf(q, " encode %lf / %lf", &ep, &ee);
    CHECK(ep == 0 && ee == 0, "the role's first sample on a new thread added %.0f + %.0f ms", ep, ee);
    printf("t_chain_lines: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
