// Repeated passes (nvn_rec.h pr_note, DM_NVN_PASS_REPEAT=1): a render pass recorded byte for byte as one of the previous frame counts as repeated, with its draws; one argument
// changed, or a pass of the same frame, does not; the pass's begin (its descriptor) and labels are not part of the stream. Then the hashing's cost per record, for the default:
// the switch stays off unless it costs under ~0.05 ms a frame. Runs the real encode thread on no encoder (messages to nil). No GPU work.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

static void pass(uint64_t pso, uint64_t addr, int draws) {   // a render pass: a pipeline, a table address, a viewport and its draws
    rec_put(RO_RE_BEGIN, 0)->a[0] = 0;
    rec_put(RO_LABEL, 0)->a[0] = 0;
    { rec_t *r = rec_put(RO_R_PSO, 0); r->a[0] = 0; r->a[1] = pso; }   // nobj 0 (no object): the hash reads a[0] only, so pso goes in a word it ignores ...
    { rec_t *r = rec_put(RO_T_ADDR, 0); r->a[0] = 0; r->a[1] = addr; r->a[2] = 3; }   // ... and the table address in one it reads
    { MTLViewport v = {0, 0, 1280, 720, 0, 1}; rec_t *r = rec_put(RO_R_VIEWPORT, 0); memcpy(r->a, &v, sizeof v); }
    for (int i = 0; i < draws; i++) { rec_t *r = rec_put(RO_R_DRAW, 0); r->a[0] = 3; r->a[1] = (uint64_t)i * 3; r->a[2] = 3; }
    rec_put(RO_END, 0);
}
static void frame(uint64_t f) { rec_drain(); atomic_store(&g_cur_frame, f); }

int main(void) { @autoreleasepool {
    setenv("DM_NVN_PASS_REPEAT", "1", 1);
    frame(1);
    pass(1, 0x1000, 4); pass(2, 0x2000, 6); pass(3, 0x3000, 2); pass(3, 0x3000, 2);   // the fourth repeats the third within the frame: not counted
    frame(2);
    pass(1, 0x1000, 4);   // as frame 1's first: repeated (4 draws)
    pass(2, 0x2008, 6);   // a table address moved: not repeated
    pass(9, 0x3000, 2);   // only the ignored word differs: repeated (2 draws)
    { rec_put(RO_RE_BEGIN, 0)->a[0] = 0; rec_t *r = rec_put(RO_R_DRAW, 0); r->a[0] = 3; r->a[1] = 0; r->a[2] = 4; rec_put(RO_END, 0); }   // a draw count frame 1 never had
    rec_drain();
    CHECK(g_pr == 1, "DM_NVN_PASS_REPEAT=1 did not turn the count on");
    CHECK(g_pr_passes == 8, "render passes %llu, want 8", (unsigned long long)g_pr_passes);
    CHECK(g_pr_rep == 2, "repeated passes %llu, want 2 (frame 2's first and third)", (unsigned long long)g_pr_rep);
    CHECK(g_pr_draws_all == 14 + 13, "draws %llu, want 27", (unsigned long long)g_pr_draws_all);
    CHECK(g_pr_draws_rep == 6, "draws in repeated passes %llu, want 6", (unsigned long long)g_pr_draws_rep);
    CHECK(g_pr_ns_rep <= g_pr_ns, "time in repeated passes above the total");

    // The hashing's cost: pr_note over a frame's worth of records (20,000, Ocarina of Time's order), against the same loop without it
    enum { N = 20000, ROUNDS = 50 };
    static rec_t recs[N];
    for (int i = 0; i < N; i++) {
        rec_t *r = &recs[i]; memset(r, 0, sizeof *r);
        r->op = i % 200 == 0 ? RO_RE_BEGIN : i % 200 == 199 ? RO_END : (uint32_t[]){RO_R_PSO, RO_T_ADDR, RO_R_VIEWPORT, RO_R_DRAW_IDX, RO_R_CULL, RO_T_TEX, RO_R_SCISSOR, RO_R_DRAW}[i & 7];
        for (int k = 0; k < 15; k++) r->a[k] = (uint64_t)i * 31 + (uint64_t)k;
    }
    double best = 1e30;
    for (int round = 0; round < ROUNDS; round++) {
        atomic_store(&g_cur_frame, 1000 + (uint64_t)round);
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int i = 0; i < N; i++) pr_note(&recs[i]);
        double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6; if (ms < best) best = ms;
    }
    printf("t_pass_repeat: hashing %.4f ms for %d records (%.2f ns a record, best of %d)\n", best, N, best * 1e6 / N, ROUNDS);
    CHECK(best < 1.0, "hashing a frame's records took %.3f ms", best);
    printf("t_pass_repeat: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
