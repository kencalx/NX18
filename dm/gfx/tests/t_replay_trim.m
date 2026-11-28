// The replay's slice-2 trims (upstream NXNative 5c841a856): DM_NVN_PC_LAST (the pool lookup table's last entry, the replay thread's own table told apart by its thread pointer,
// buffer lengths kept in the entries) and DM_NVN_REPLAY_TRIM (vconv_int's table, draw_color_writes' shifts, skip_fs_draw's early out). Each answers what the old path answers:
// the integer formats and channel masks over every input, lookups from a claimed thread and from another against the pool index, a removed pool never answered from a last entry
// (negative control: the entry kept past the generation is), each thread's upload flag its own. T_TRIM_BENCH=1: lookups per call, switch on and off
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static uint32_t chmask_loop(uint32_t m) { uint32_t r = 0; for (int i = 0; i < 8; i++) if ((m >> (4 * i)) & 0xf) r |= 1u << i; return r; }
enum { REGION = 1 << 16 };
static uint64_t A, B; static const size_t a_size = 4 * REGION;
// On the claimed thread: lookups of A then B then A again, through the replay's table
static int rep_ok, rep_flag_own; static uint64_t rep_last_hits;
static void *rep_thread(void *u) {
    (void)u; mtl_pc_claim();
    void *mb; uint64_t mo, gpu, bl;
    int ok = mtl_gpu_addr(A + 0x100, 16, &mb, &mo, &gpu) && mo == 0x100;
    ok &= g_pc_rep.gen == atomic_load(&g_pool_gen) && g_pc_rep.last.lo == A;   // the replay's table took it, not this thread's thread-local one
    uint64_t h0 = g_stat_pc_last;
    ok &= mtl_gpu_addr(A + 0x2000, 16, &mb, &mo, &gpu) && mo == 0x2000 && g_stat_pc_last == h0 + 1;   // the same pool: the last entry
    ok &= mtl_gpu_addr_len(B + 0x40, 16, &mb, &mo, &gpu, &bl) && mo == 0x40 && bl == ((__bridge id<MTLBuffer>)mb).length;
    rep_last_hits = g_stat_pc_last - h0;
    t_tex_upload_lookup = 1; rep_flag_own = g_tex_upload_rep == 1 && t_tex_upload_tl == 0; t_tex_upload_lookup = 0;
    rep_ok = ok; g_pc_rep_tp = 0; return NULL;   // let go, so the main thread's lookups below never take the replay's table
}
int main(void) { @autoreleasepool {
    mtl_init();
    // vconv_int: the table against the scan, for every format value and a few outside
    { int bad = 0; for (int f = -4; f < 300; f++) { int b0 = -1, s0 = -1, b1 = -1, s1 = -1; int n0 = vconv_int_scan(f, &b0, &s0); g_replay_trim = 1; int n1 = vconv_int(f, &b1, &s1);
          if (n0 != n1 || (n0 && (b0 != b1 || s0 != s1))) bad++; }
      CHECK("vconv_int's table answers as the scan for every format", bad == 0); }
    // draw_color_writes' collapse against the loop, for every one-target mask and random ones
    { int bad = 0; uint32_t r = 12345; for (int i = 0; i < 200000; i++) { r = r * 1103515245u + 12345u; uint32_t m = i < 256 ? (uint32_t)(i & 15) << (4 * (i >> 5 & 7)) : r ^ (r << 7); if (chmask_any(m) != chmask_loop(m)) bad++; }
      CHECK("the channel mask collapse answers as the loop", bad == 0); }
    // skip_fs_draw: nothing set, nothing skipped, and no call; a key set is still skipped
    { NvProg *pr = [NvProg new]; NvShader *fs = [NvShader new]; strcpy(fs->key, "abcdef0123456789"); pr->sh[1] = fs;
      CHECK("no fragment skip set: none skipped", !skip_fs_draw(pr) && g_skip_fs_n == 0);
      g_skip_fs_n = -1; setenv("DM_NVN_SKIP_FS", "abcdef", 1); CHECK("a fragment skip set: that shader is skipped", skip_fs_draw(pr) == 1 && g_skip_fs_n == 1);
      strcpy(fs->key, "ffff"); CHECK("another is not", skip_fs_draw(pr) == 0); unsetenv("DM_NVN_SKIP_FS"); g_skip_fs_n = 0; }
    // the submission context formatted later reads as it did at every commit
    { cctx_t c = {7, 1, 2, 3, 4, 5}; char b[320]; CHECK("the submission context's text", !strcmp(cctx_fmt(&c, b, sizeof b), "frame 7; since the last submission: passes +1, first texture uploads +2, re-uploads +3, serial table changes +4; deferred-release queue 5")); }

    const size_t n = 4u << 20;
    uint8_t *mem = mmap(NULL, n, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (mem == MAP_FAILED) abort();
    A = ((uint64_t)(uintptr_t)mem + REGION - 1) & ~(uint64_t)(REGION - 1); B = A + (2u << 20);
    mtl_pool_add((void *)(uintptr_t)A, a_size); mtl_pool_add((void *)(uintptr_t)B, REGION);
    void *mb = NULL; uint64_t mo = 0, gpu = 0, bl = 0;
    // A claimed thread's lookups go through the global table; the main thread's own table is untouched by them
    uint64_t main_gen = t_pc_tl.gen;
    pthread_t th; pthread_create(&th, NULL, rep_thread, NULL); pthread_join(th, NULL);
    CHECK("the claimed thread looks up through the replay's table and its last entry", rep_ok && rep_last_hits == 1);
    CHECK("its upload flag is its own", rep_flag_own && !t_tex_upload_lookup);
    CHECK("the main thread's table is not the replay's", t_pc_tl.gen == main_gen);
    // On this thread: the last entry answers the same pool again, and the kept length is the buffer's
    CHECK("a lookup fills the last entry", mtl_gpu_addr(A + 0x40, 16, &mb, &mo, &gpu) && t_pc_tl.last.lo == A);
    const pc_ent *c = pc_get(A + 0x3000, 16);
    CHECK("the same pool again is answered by the last entry", c == &t_pc_tl.last);
    CHECK("with the buffer's length", mtl_gpu_addr_len(A + 0x3000, 16, &mb, &mo, &gpu, &bl) && bl == ((__bridge id<MTLBuffer>)mb).length && bl >= a_size);
    CHECK("a range past the pool is not answered by it", pc_get(A + a_size - 8, 16) == NULL);
    // A removed pool: the generation moves, and the last entry does not answer
    mtl_pool_del((void *)(uintptr_t)A);
    CHECK("the removed pool is not answered from the last entry", pc_get(A + 0x3000, 16) == NULL && !mtl_gpu_addr(A + 0x3000, 16, &mb, &mo, &gpu));
    // negative control: the entry kept past the generation (the check pc_get makes first) answers for the removed pool
    { pc_tab *T = &t_pc_tl; pc_ent keep = {A, A + a_size, A, nil, 0x1000, A + a_size, REACH_END, a_size}; T->last = keep; uint64_t g = T->gen; T->gen = atomic_load(&g_pool_gen);
      CHECK("negative control: a last entry taken as current answers a removed pool", pc_get(A + 0x3000, 16) == &T->last);
      T->last = (pc_ent){0}; T->gen = g; }
    // Off: no last entry
    g_pc_last = 0; mtl_gpu_addr(B + 0x80, 16, &mb, &mo, &gpu); c = pc_get(B + 0x100, 16); CHECK("off: lookups come from the tables, not a last entry", c && c != &t_pc_tl.last); g_pc_last = 1;
    // DM_NVN_CBSIZE_REUSE: the same words in the same submission give the stage's last table; other words, a new one; a new submission, a new one (its arena); off, a new one each time
    {   mtl_pool_add((void *)(uintptr_t)A, a_size);
        mtl_sub_begin(); state_reset();
        S.ubo[1][0] = (p_bind_buf){.stage = 1, .index = 0, .addr = A, .size = 0x100};
        __unsafe_unretained id<MTLBuffer> u0 = nil, u1 = nil; uint64_t r0 = g_stat_cbs_reuse;
        uint64_t g0 = cbsize_table(1, &u0), g1 = cbsize_table(1, &u1);
        CHECK("the same words in the same submission: the same table", g0 && g0 == g1 && u0 == u1 && g_stat_cbs_reuse == r0 + 1);
        CHECK("its words are slot 0's bound size", g_cbsc[1].d[0] == 0x100 && g_cbsc[1].d[1] == 0);
        S.ubo[1][0].size = 0x200; uint64_t g2 = cbsize_table(1, &u1);
        CHECK("other words: a new table with them", g2 != g0 && g_cbsc[1].d[0] == 0x200 && g_cbsc[1].gpu == g2);
        S.ubo[1][3] = (p_bind_buf){.stage = 1, .index = 3, .addr = A + 0x1000, .size = 0x40}; uint64_t g3 = cbsize_table(1, &u1);
        CHECK("another slot bound: a new table", g3 != g2 && g_cbsc[1].d[3] == 0x100);
        mtl_wait(mtl_sub_commit(), 5000000000ull); mtl_sub_begin();
        uint64_t g4 = cbsize_table(1, &u1); int in_cur = 0; for (NvArena *a in g_sub_arenas) in_cur |= g4 >= a->gpu && g4 < a->gpu + a->len;
        CHECK("a new submission: a new table in its arena", g4 != g3 && in_cur);
        // negative control: the stage's table kept as current past the submission (no epoch check) would name a slice of the last submission's arena
        mtl_wait(mtl_sub_commit(), 5000000000ull); g_arena_next = nil; mtl_sub_begin();   // the last block is not taken back: it is the GPU's to finish and then free to reuse
        uint64_t keep = g_cbsc[1].gpu; g_cbsc[1].epoch = g_arena_epoch; uint64_t g5 = cbsize_table(1, &u1); in_cur = 0; for (NvArena *a in g_sub_arenas) in_cur |= g5 >= a->gpu && g5 < a->gpu + a->len;
        CHECK("negative control: taken as current, the table is the last submission's slice", g5 == keep && !in_cur);
        g_cbsc[1].gpu = 0;
        g_cbsize_reuse = 0; uint64_t g6 = cbsize_table(1, &u1), g7 = cbsize_table(1, &u1); g_cbsize_reuse = 1;
        CHECK("off: a new table each time", g6 != g7);
        mtl_wait(mtl_sub_commit(), 5000000000ull); state_reset(); mtl_pool_del((void *)(uintptr_t)A);
    }
    if (getenv("T_TRIM_BENCH")) {
        enum { N = 4000000 }; double best[2] = {1e9, 1e9};
        mtl_pool_add((void *)(uintptr_t)A, a_size);
        for (int round = 0; round < 5; round++) for (int k = 0; k < 2; k++) {
            g_pc_last = !k; if (!k) mtl_pc_claim();   // on: this thread takes the replay's place (its global table)
            mtl_gpu_addr(A, 16, &mb, &mo, &gpu); mtl_gpu_addr(B, 16, &mb, &mo, &gpu);
            uint64_t t0 = bp_now(), sum = 0;
            for (int i = 0; i < N; i++) { uint64_t a = (i & 3) == 3 ? B + (uint64_t)(i & 0xff0) : A + (uint64_t)((i * 64) & 0x3fff0); if (mtl_gpu_addr(a, 16, &mb, &mo, &gpu)) sum += mo; }
            double ns = (double)(bp_now() - t0) / N; if (ns < best[k]) best[k] = ns; if (!sum) printf(" "); g_pc_rep_tp = 0;
        }
        g_pc_last = 1;
        {   double cb[2] = {1e9, 1e9}; enum { M = 50000 };
            for (int round = 0; round < 5; round++) for (int k = 0; k < 2; k++) { g_cbsize_reuse = !k; mtl_sub_begin(); state_reset();
                for (int r = 0; r < 4; r++) S.ubo[1][r] = (p_bind_buf){.stage = 1, .index = (int32_t)r, .addr = A + 0x1000 * (uint64_t)r, .size = 0x100};
                __unsafe_unretained id<MTLBuffer> u = nil; uint64_t t0 = bp_now();
                for (int i = 0; i < M; i++) cbsize_table(1, &u);
                double ns = (double)(bp_now() - t0) / M; if (ns < cb[k]) cb[k] = ns; mtl_wait(mtl_sub_commit(), 5000000000ull); }
            g_cbsize_reuse = 1; state_reset();
            printf("t_replay_trim bench: a uniform size table (four slots bound) %.1f ns with DM_NVN_CBSIZE_REUSE=0, %.1f ns on\n", cb[1], cb[0]); }
        mtl_pool_del((void *)(uintptr_t)A);
        printf("t_replay_trim bench (as the replay thread, three in four lookups of one pool): a pool lookup %.2f ns with DM_NVN_PC_LAST=0, %.2f ns on\n", best[1], best[0]);
    }
    mtl_pool_del((void *)(uintptr_t)B); mtl_drain(); munmap(mem, n);
    printf("t_replay_trim: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
