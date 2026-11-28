// Deferred encoding's records (nvn_rec.h rec_t, rec_blk): each record is one 128-byte cache line, and a block's r[] starts on a line. It started at offset 16, so every record the
// submit thread wrote and the encode thread read spanned two lines. Checks the layout and the blocks' alignment, then times the real hand-off: the submit thread's rec_put and
// rec_publish, the encode thread's rec_thread and rec_exec (state records on no encoder: messages to nil, so only the records' own cost is left), up to rec_drain.
// T_REC_BASE=1 builds it against a tree from before the change (the layout checks are skipped there), for the before / after figures in the commit. No GPU work.
#include "../nvn/nvn_mtl.m"
#include <libproc.h>
static uint64_t proc_cycles(void) { struct rusage_info_v6 r; memset(&r, 0, sizeof r); proc_pid_rusage(getpid(), RUSAGE_INFO_V6, (rusage_info_t *)&r); return r.ri_cycles; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)
static int cmpd(const void *a, const void *b) { double x = *(const double *)a, y = *(const double *)b; return x < y ? -1 : x > y; }

int main(int argc, char **argv) { @autoreleasepool {
    int frames = argc > 1 ? atoi(argv[1]) : 40;
#ifndef T_REC_BASE
    CHECK(sizeof(rec_t) == 128, "rec_t is %zu bytes, want one 128-byte line", sizeof(rec_t));
    CHECK(offsetof(rec_blk, r) % 128 == 0, "rec_blk's r[] starts at %zu, not on a line", offsetof(rec_blk, r));
    for (int i = 0; i < 8; i++) { rec_blk *b = rec_blk_new(); CHECK(((uintptr_t)b & 127) == 0 && ((uintptr_t)b->r & 127) == 0, "block %p (records at %p) not on a line", (void *)b, (void *)b->r); free(b); }
#endif
    // The hand-off: 20,000 records a frame (Ocarina of Time's replay records about that many), in a submission's mix of state setters and draws, then a drain
    enum { PER = 20000 };
    double per[256], cyc[256], tail[256], wk[256]; if (frames > 256) frames = 256;
    rec_put(RO_R_CULL, 0)->a[0] = 0; rec_drain();   // starts the encode thread
    const char *pe = getenv("T_REC_PACE"); const uint64_t pace = pe ? (uint64_t)atoll(pe) : 0;   // T_REC_PACE=<ns>: the submit thread spends that long a record, as a replay does between its records, so the encode thread waits for blocks
    for (int f = 0; f < frames; f++) {
        uint64_t t0 = bp_now(), c0 = proc_cycles();
        for (int i = 0; i < PER; i++) {
            if (pace) { uint64_t until = t0 + pace * (uint64_t)(i + 1); while (bp_now() < until) {} }
            switch (i & 7) {
            case 0: { MTLViewport v = {0, 0, 1280, 720, 0, 1}; rec_t *r = rec_put(RO_R_VIEWPORT, 0); memcpy(r->a, &v, sizeof v); break; }
            case 1: { MTLScissorRect s = {0, 0, 1280, 720}; rec_t *r = rec_put(RO_R_SCISSOR, 0); memcpy(r->a, &s, sizeof s); break; }
            case 2: rec_put(RO_R_CULL, 0)->a[0] = (uint64_t)(i & 1); break;
            case 3: { rec_t *r = rec_put(RO_R_DRAW_IDX, 0); r->a[0] = 3; r->a[1] = 36; r->a[2] = 1; r->a[3] = 0x1000; r->a[4] = 72; r->a[5] = 1; r->a[6] = 0; r->a[7] = 0; break; }
            case 4: { rec_t *r = rec_put(RO_R_BIAS, 0); r->a[0] = rec_f(0); r->a[1] = rec_f(1); r->a[2] = rec_f(0); break; }
            case 5: rec_put(RO_R_WINDING, 0)->a[0] = 1; break;
            case 6: { rec_t *r = rec_put(RO_R_SREF, 0); r->a[0] = r->a[1] = 0; break; }
            default: { rec_t *r = rec_put(RO_R_DRAW, 0); r->a[0] = 3; r->a[1] = 0; r->a[2] = 3; break; }
            }
        }
        uint64_t t1 = bp_now(), w0 = atomic_load(&g_rb_wakes);   // the drain: what the encode thread still had to do once the last record was put (the tail after a commit)
        rec_drain();
        per[f] = (double)(bp_now() - t0) / PER; cyc[f] = (double)(proc_cycles() - c0) / PER; tail[f] = (double)(bp_now() - t1) / 1e3; wk[f] = (double)(atomic_load(&g_rb_wakes) - w0);
    }
    uint64_t wakes_all = atomic_load(&g_rb_wakes);
    qsort(per, (size_t)frames, sizeof *per, cmpd); qsort(cyc, (size_t)frames, sizeof *cyc, cmpd); qsort(tail, (size_t)frames, sizeof *tail, cmpd); (void)wk;
    printf("t_rec_align (%s): %d frames of %d records, put to drained, ns per record: p50 %.2f / p10 %.2f / p90 %.2f; CPU cycles per record (both threads) p50 %.1f\n",
#ifdef T_REC_BASE
           "base layout, r[] at offset 16",
#else
           "r[] on a 128-byte line",
#endif
           frames, PER, per[frames / 2], per[frames / 10], per[frames * 9 / 10], cyc[frames / 2]);
#ifndef T_REC_BASE
    printf("t_rec_align: blocks of %d records (DM_NVN_REC_BLK): encode thread wakes %.1f per frame; the drain after the last record p50 %.1f us / p90 %.1f us\n", rec_blk_n(), (double)wakes_all / (frames + 1), tail[frames / 2], tail[frames * 9 / 10]);
#endif
    printf("t_rec_align: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
