// The plain-C parts of the NVN layer's GPU diagnostics (../nvn/nvn_gpu_diag.h), on any machine: the 1st, 2nd, 4th ... error of a kind is logged, also with errors from
// several threads at once; the passes of a command buffer as its feedback handler formats them when it fails (kinds, sizes, formats, draws, the first and last program's
// shader keys, the frame's numbering, a command buffer's range of records, the first and last ones shown of a long one, records overwritten once the ring wraps), a
// reader formatting records while the submit thread writes newer ones over them (make t_gpu_diag_tsan: what it reads is whole or reads as gone), and the GPU busy time
// as the union of command buffers' intervals. nvn_mtl.m's use of it needs a GPU: its feedback handlers on the Metal 4 queue
#include "../nvn/nvn_gpu_diag.h"
#include <pthread.h>
#include <stdlib.h>

static int checks, failed;
#define EXPECT(name, want, got) do { long long w_ = (long long)(want), g_ = (long long)(got); checks++; if (w_ != g_) { fprintf(stderr, "%s: expected %lld, got %lld\n", name, w_, g_); failed++; } } while (0)
#define HAS(name, text, part) do { checks++; if (!strstr((text), (part))) { fprintf(stderr, "%s: \"%s\" not in \"%s\"\n", name, (part), (text)); failed++; } } while (0)
#define LACKS(name, text, part) do { checks++; if (strstr((text), (part))) { fprintf(stderr, "%s: \"%s\" unexpected in \"%s\"\n", name, (part), (text)); failed++; } } while (0)

static gd_ring g_ring;   // as nvn_mtl.m keeps it: static, 128 KB
static int progs[8];     // stand-ins for programs: only their addresses are compared

static void errors(void) {
    _Atomic uint32_t c = 0; int logged = 0; uint32_t last = 0;
    for (int i = 1; i <= 1000; i++) { uint32_t n = gd_err_due(&c); if (n) { logged++; EXPECT("errors: a power of two", 0, n & (n - 1)); EXPECT("errors: the count", i, n); last = n; } }
    EXPECT("errors: 1, 2, 4 ... 512 of 1000 logged", 10, logged);
    EXPECT("errors: the last logged", 512, last);
}
static _Atomic uint32_t g_err; static _Atomic int g_logged;
static void *err_thread(void *arg) { (void)arg; for (int i = 0; i < 4096; i++) if (gd_err_due(&g_err)) atomic_fetch_add(&g_logged, 1); return NULL; }
static void errors_threads(void) {
    pthread_t t[4]; for (int i = 0; i < 4; i++) pthread_create(&t[i], NULL, err_thread, NULL);
    for (int i = 0; i < 4; i++) pthread_join(t[i], NULL);
    EXPECT("errors from 4 threads: all counted", 4 * 4096, atomic_load(&g_err));
    EXPECT("errors from 4 threads: 1, 2, 4 ... 16384 logged once each", 15, atomic_load(&g_logged));
}

static void passes(void) {
    gd_ring *g = &g_ring; char t[512]; uint64_t first, end;
    gd_pass_begin(g, GD_RENDER, 100, 7, 1280, 720, 2, 115, 260, 1);   // a game pass: RGBA16Float, Depth32Float_Stencil8
    for (int i = 0; i < 5; i++) if (gd_count(g, &progs[0])) gd_prog(g, &progs[0], 0x0123456789abcdefull, 0xfedcba9876543210ull);
    gd_pass_begin(g, GD_COPY, 100, 0, 0, 0, 0, 0, 0, 0);
    if (gd_count(g, &progs[1])) gd_prog(g, &progs[1], 0xaaaa000000000001ull, 0);
    if (gd_count(g, &progs[1])) gd_prog(g, &progs[1], 0xaaaa000000000001ull, 0);   // the same kernel again: no change
    gd_pass_begin(g, GD_RENDER, 100, 8, 640, 360, 1, 80, 0, 4);
    int keys = 0; for (int i = 0; i < 6; i++) if (gd_count(g, &progs[2 + i % 3])) { keys++; gd_prog(g, &progs[2 + i % 3], 0x1000 + (uint64_t)(i % 3), 0x2000 + (uint64_t)(i % 3)); }
    EXPECT("passes: each program change asks for its keys", 6, keys);
    gd_cb_close(g, &first, &end);
    EXPECT("command buffer: first record", 0, first);
    EXPECT("command buffer: end", 3, end);
    EXPECT("command buffer: closing ends the open pass", 0, gd_count(g, &progs[0]));   // a draw now counts nowhere

    EXPECT("text: record 0 is there", 1, gd_pass_text(g, 0, t, sizeof t));
    HAS("text: render pass", t, "frame 100 #0 R pass 7 1280x720");
    HAS("text: formats", t, "colours 2 (format 115) depth/stencil format 260 samples 1");
    HAS("text: draws", t, ", 5 draws");
    HAS("text: the program's keys", t, "vertex 0123456789abcdef fragment fedcba9876543210");
    LACKS("text: one program only", t, "last");
    gd_pass_text(g, 1, t, sizeof t);
    HAS("text: copy encoder", t, "frame 100 #1 B, 2 dispatches, kernel aaaa000000000001");
    LACKS("text: no attachments for a copy encoder", t, "colours");
    gd_pass_text(g, 2, t, sizeof t);
    HAS("text: first and last program", t, "#2 R pass 8 640x360 colours 1 (format 80) depth/stencil format 0 samples 4, 6 draws, vertex 0000000000001000 fragment 0000000000002000 ... last vertex 0000000000001002 fragment 0000000000002002 (6 programs bound)");
    EXPECT("text: a record not written yet", 0, gd_pass_text(g, 3, t, sizeof t));

    gd_pass_begin(g, GD_DLSS, 101, 0, 0, 0, 0, 0, 0, 0);   // the next frame numbers its records from 0
    gd_pass_begin(g, GD_HOST_RENDER, 101, 0, 32, 32, 1, 70, 0, 1);
    gd_cb_close(g, &first, &end);
    EXPECT("next command buffer: first", 3, first);
    EXPECT("next command buffer: end", 5, end);
    gd_pass_text(g, 3, t, sizeof t); HAS("text: a new frame starts at #0", t, "frame 101 #0 D, 0 draws");
    gd_pass_text(g, 4, t, sizeof t); HAS("text: host render pass", t, "frame 101 #1 r 32x32");
    LACKS("text: no program, no keys", t, "vertex");
    LACKS("text: no pass number for the host's own", t, "pass ");
    gd_cb_close(g, &first, &end);
    EXPECT("an empty command buffer", 0, end - first);
    gd_pass_begin(g, GD_COMPUTE, 101, 0, 0, 0, 0, 0, 0, 0);   // a built-in kernel has no key
    if (gd_count(g, &progs[3])) gd_prog(g, &progs[3], 0, 0);
    gd_cb_close(g, &first, &end);
    gd_pass_text(g, first, t, sizeof t); HAS("text: a built-in kernel's key reads -", t, "C, 1 dispatches, kernel -");

    // Saturation: a pass's draws stop at 65535, its programs at 255
    gd_pass_begin(g, GD_RENDER, 102, 9, 16, 16, 1, 70, 0, 1);
    for (int i = 0; i < 70000; i++) if (gd_count(g, &progs[i & 1])) gd_prog(g, &progs[i & 1], (uint64_t)i, (uint64_t)i);
    gd_cb_close(g, &first, &end);
    gd_pass_text(g, first, t, sizeof t);
    HAS("saturated draws", t, "65535 draws or more");
    HAS("saturated programs", t, "(255 or more programs bound)");
    // A short buffer is cut, never overrun
    char small[24]; memset(small, 'x', sizeof small);
    EXPECT("short buffer: still there", 1, gd_pass_text(g, first, small, 16));
    EXPECT("short buffer: cut at its size", 15, strlen(small));
    EXPECT("short buffer: the bytes after it untouched", 'x', small[16]);

    // The ring wraps: a record GD_RING passes old is gone, the newest ones are there
    uint64_t old = first;
    for (int i = 0; i < GD_RING; i++) gd_pass_begin(g, GD_COMPUTE, 200, 0, 0, 0, 0, 0, 0, 0);
    EXPECT("wrapped: the old record is gone", 0, gd_pass_text(g, old, t, sizeof t));
    EXPECT("wrapped: the newest is there", 1, gd_pass_text(g, g->seq - 1, t, sizeof t));
    EXPECT("wrapped: the oldest still kept is there", 1, gd_pass_text(g, g->seq - GD_RING, t, sizeof t));
    HAS("wrapped: numbered within its frame", t, "frame 200 #0 C");
    gd_cb_close(g, &first, &end);
    EXPECT("wrapped: a command buffer of as many passes as the ring", GD_RING, end - first);
}
static void pick(void) {
    uint64_t gap, skip;
    EXPECT("pick: all of a short one", 5, gd_pick(10, 15, 32, &gap, &skip)); EXPECT("pick: no gap", 5, gap); EXPECT("pick: none left out", 0, skip);
    EXPECT("pick: at most max", 32, gd_pick(0, 100, 32, &gap, &skip)); EXPECT("pick: the first half", 16, gap); EXPECT("pick: the ones left out", 68, skip);
    EXPECT("pick: none", 0, gd_pick(7, 7, 32, &gap, &skip));
}

// A reader formats records while the writer writes newer ones over them: each record's kernel key is its number times 3, plus 1, and it has one dispatch, so a text that mixed
// two records, or read one half written, would show a key or a count that does not belong to its number
static gd_ring g_race;
static _Atomic int g_stop; static _Atomic uint64_t g_head;
static void *writer(void *arg) {
    (void)arg;
    for (uint64_t s = 0; s < 200000; s++) {
        gd_pass_begin(&g_race, GD_COMPUTE, (uint32_t)(s / 100), 0, 0, 0, 0, 0, 0, 0);
        if (gd_count(&g_race, &progs[s & 1])) gd_prog(&g_race, &progs[s & 1], s * 3 + 1, 0);
        atomic_store_explicit(&g_head, g_race.seq, memory_order_release);
    }
    atomic_store(&g_stop, 1);
    return NULL;
}
static void race(void) {
    pthread_t w; pthread_create(&w, NULL, writer, NULL);
    long whole = 0, gone = 0, bad = 0; char t[256], want[64];
    while (!atomic_load(&g_stop)) {
        uint64_t h = atomic_load_explicit(&g_head, memory_order_acquire); if (h < 2) continue;
        for (uint64_t s = h > GD_RING ? h - GD_RING : 0; s < h; s += 97) {
            if (!gd_pass_text(&g_race, s, t, sizeof t)) { gone++; continue; }
            whole++; unsigned long long key = s * 3 + 1; snprintf(want, sizeof want, "kernel %016llx", key);
            if (!strstr(t, want) || !strstr(t, "1 dispatches")) { if (!bad++) fprintf(stderr, "race: record %llu reads \"%s\"\n", (unsigned long long)s, t); }
        }
    }
    pthread_join(w, NULL);
    EXPECT("race: no record read mixed with another", 0, bad);
    checks++; if (!whole) { fprintf(stderr, "race: no record was read whole\n"); failed++; }
    fprintf(stderr, "race: %ld records read whole, %ld gone under the reader\n", whole, gone);
}

// DM_NVN_PASS_RING=0 (nvn_mtl.m sets off before any pass): nothing is recorded, a draw finds no open record, and a command buffer has no records to log
static gd_ring g_off;
static void ring_off(void) {
    gd_ring *g = &g_off; uint64_t first, end; char t[400];
    g->off = 1;
    gd_pass_begin(g, GD_RENDER, 1, 1, 1280, 720, 1, 80, 252, 1);
    EXPECT("off: a draw finds no open record", 0, gd_count(g, &progs[0]));
    gd_prog(g, &progs[0], 1, 2);
    gd_cb_close(g, &first, &end);
    EXPECT("off: a command buffer of no records", 0, end - first);
    EXPECT("off: nothing written", 0, g->seq);
    EXPECT("off: record 0 is not there", 0, gd_pass_text(g, 0, t, sizeof t));
}

static void busy(void) {
    gd_busy b = {0};
    gd_busy_add(&b, 1000, 2000); EXPECT("busy: one interval", 1000, gd_busy_ns(&b));
    gd_busy_add(&b, 1500, 3000); EXPECT("busy: an overlap counts once", 2000, gd_busy_ns(&b));
    gd_busy_add(&b, 2200, 2800); EXPECT("busy: one inside another adds nothing", 2000, gd_busy_ns(&b));
    gd_busy_add(&b, 4000, 4500); EXPECT("busy: a gap is not counted", 2500, gd_busy_ns(&b));
    gd_busy_add(&b, 0, 9000); EXPECT("busy: no start time is skipped", 2500, gd_busy_ns(&b));
    gd_busy_add(&b, 5000, 5000); gd_busy_add(&b, 6000, 5500); EXPECT("busy: empty and reversed are skipped", 2500, gd_busy_ns(&b));
    gd_busy_add(&b, 3500, 3900); EXPECT("busy: one reported late in a gap before the last end: the documented undercount", 2500, gd_busy_ns(&b));
    gd_busy_add(&b, 4400, 5000); EXPECT("busy: one reaching past the last end counts from it", 3000, gd_busy_ns(&b));
}

int main(void) {
    errors(); errors_threads(); passes(); pick(); race(); ring_off(); busy();
    printf("t_gpu_diag: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
