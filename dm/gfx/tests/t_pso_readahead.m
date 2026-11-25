// The bundled archive's read-ahead (nvn_mtl.m ra_step, DM_PSO_READAHEAD=1): its scheduling and stop rules, on a temporary file standing in for the archive's GPU code ranges.
// It waits for the start's pipeline work (no frame yet, a compaction pass scheduled or capturing, the prewarm running), waits while hot, in Low Power Mode or in the background,
// stops for good under RA_HEADROOM_MB of headroom or at the process's end, and otherwise reads every range in RA_CHUNK steps with a rest after each. No Metal objects, no game files.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } else printf("ok: %s\n", label); } while (0)

static uint64_t g_test_avail;
static uint64_t test_avail(void) { return g_test_avail; }
static char g_file[1024];
static void reset(void) {   // a fresh read-ahead over the file's two ranges
    if (g_ras.fd >= 0) close(g_ras.fd);
    free(g_ras.buf); memset(&g_ras, 0, sizeof g_ras); g_ras.fd = -1;
    memset(&g_ra, 0, sizeof g_ra);
    arch_reads rd = {0}; arch_reads_code(&rd, 4096, 20u << 20); arch_reads_code(&rd, (24u << 20), 3u << 20);   // 20 MB and 3 MB of "GPU code"
    ra_note([NSString stringWithUTF8String:g_file], &rd);
    g_cpass_hold_test = 0; atomic_store(&g_cpass, 0); g_present_n = 1; atomic_store(&g_warm_running, 0); atomic_store(&g_warm_stop, 0); g_test_avail = 0;
}

int main(void) { @autoreleasepool {
    snprintf(g_file, sizeof g_file, "%s/t_pso_readahead.%d.bin", getenv("TMPDIR") ?: "/tmp", getpid());
    int fd = open(g_file, O_RDWR | O_CREAT | O_TRUNC, 0600); if (fd < 0 || ftruncate(fd, 28u << 20)) { perror(g_file); return 1; } close(fd);
    g_rh_avail = test_avail;

    CHECK(ra_decide(0, NULL, 0, 0) == RA_GO, "nothing in the way: it reads (headroom not known, as on the Mac)");
    CHECK(ra_decide(0, "hot", 0, 4ull << 30) == RA_WAIT && ra_decide(0, NULL, 1, 4ull << 30) == RA_WAIT, "a hold or the start's work: it waits");
    CHECK(ra_decide(0, NULL, 0, 512ull << 20) == RA_STOP && ra_decide(1, NULL, 0, 0) == RA_STOP, "low headroom or the process's end: it stops");

    reset(); g_present_n = 0; atomic_store(&g_cpass_subs, 0);
    CHECK(ra_step() == g_ra_hold_ms && g_ras.read == 0 && !g_ras.t0, "before the first frame it waits and reads nothing");
    g_present_n = 1; atomic_store(&g_cpass, 2);
    CHECK(ra_step() == g_ra_hold_ms && g_ras.read == 0, "while the compaction captures it waits");
    atomic_store(&g_cpass, 1); CHECK(ra_step() == g_ra_hold_ms && g_ras.read == 0, "while a compaction pass is scheduled it waits");
    atomic_store(&g_cpass, 0); atomic_store(&g_warm_running, 1); CHECK(ra_step() == g_ra_hold_ms && g_ras.read == 0, "while the prewarm runs it waits");
    atomic_store(&g_warm_running, 0); atomic_store(&g_cpass, 3);   // a closed compaction pass is over

    int ms = ra_step();
    CHECK(ms >= g_ra_rest_ms && g_ras.read == RA_CHUNK, "then it reads one chunk and rests");
    for (int h = 1; h <= 3; h++) { g_cpass_hold_test = h; uint64_t r = g_ras.read; CHECK(ra_step() == g_ra_hold_ms && g_ras.read == r, h == 1 ? "hot: it waits" : h == 2 ? "Low Power Mode: it waits" : "in the background: it waits"); }
    CHECK(g_ras.holds == 1, "one hold counted while it lasts");
    g_cpass_hold_test = 0;
    int steps = 0; while ((ms = ra_step()) >= 0 && steps < 100) steps++;
    CHECK(g_ras.done && g_ras.read == g_ra.total && g_ra.total == (23u << 20), "every range is read, once");
    CHECK(steps == 1, "in chunks: 23 MB in three steps (8 + 8 + 7 MB, the last one across both ranges)");
    CHECK(ra_step() == -1, "over: no more steps");

    reset(); g_test_avail = 900ull << 20;
    CHECK(ra_step() == -1 && g_ras.done && g_ras.read == 0, "under the headroom it stops for good without reading");
    reset(); g_test_avail = 4ull << 30; (void)ra_step(); g_test_avail = 100ull << 20;
    CHECK(ra_step() == -1 && g_ras.read == RA_CHUNK && g_ras.fd < 0 && !g_ras.buf, "headroom falling while it reads: it stops and lets go of its file and buffer");
    reset(); atomic_store(&g_cpass, 3); atomic_store(&g_warm_stop, 1);
    CHECK(ra_step() == -1 && g_ras.read == 0, "the process ending: it stops");
    atomic_store(&g_warm_stop, 0);

    unlink(g_file);
    printf("read-ahead: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
