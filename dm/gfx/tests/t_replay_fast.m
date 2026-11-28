// The replay's per-draw fast paths (reference/frame-rate.md "Per-draw lookups the replay repeated"), each against the path it replaces, with negative controls and a micro-benchmark
// shaped like Ocarina of Time's replay thread:
// - DM_NVN_FB_STOR: a texture ID's (serial, pool, offset) record (tstor_get) answers what fb_att_is read under g_rmu, after registrations, re-registrations, an ID emptied and a pool
//   gone, and while another thread registers that ID over and over (a torn record is never taken); fb_att_is with the switch on and off fills the same storage for every query
// - DM_NVN_PSO_MEMO: a render pipeline lookup through the program's remembered slot (pso_tab_get) answers what the table does across a put, a grow and a clear (no pipeline a cleared
//   table let go is handed out); off, the slot is not used
// The task / mesh draws' fragment generation (DM_NVN_MTK_KEEP) is checked on the GPU by t_mesh_first_use.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <pthread.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static pool_t g_tpools[8];   // stand-ins: fb_att_is compares pool pointers only
static tex_t mk_tex(int pool, int64_t off) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = nvn_new_serial(), .pool = &g_tpools[pool], .off = off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 4, .height = 4, .depth = 1, .levels = 1, .samples = 1};
    return t;
}
// What fb_att_is's first step reads for (tid, ser), switch on or off: the attachment shares the pool pointer (not the offset), so the storage is read and the answer is 0
static fb_where where_of(int tid, uint64_t ser, int fast) {
    int keep = g_fb_stor; g_fb_stor = fast;
    tex_t a = mk_tex(0, -1); a.serial = 1;   // pool 0 at an offset no test texture has: never the same storage
    fb_where w = {0}; int r = fb_att_is(&a, ser, tid, &w);
    g_fb_stor = keep; (void)r;
    return w;
}
static int same_where(fb_where a, fb_where b) { return a.got == b.got && a.pool == b.pool && a.off == b.off; }

static void storage_record(void) {
    enum { T = 101 };
    tex_t a = mk_tex(1, 0x1000), b = mk_tex(2, 0x2000);
    const pool_t *p; int64_t o;
    mtl_reg_tex(T, &a, NULL);
    CHECK(tstor_get(T, a.serial, &p, &o) && p == a.pool && o == a.off, "a registration's record holds its pool and offset");
    CHECK(!tstor_get(T, b.serial, &p, &o), "another serial is not answered");
    CHECK(!tstor_get(0, a.serial, &p, &o) && !tstor_get(1 << 20, a.serial, &p, &o) && !tstor_get(T, 0, &p, &o), "ID 0, an ID past the table, serial 0: not answered");
    mtl_reg_tex(T, &b, NULL);
    CHECK(!tstor_get(T, a.serial, &p, &o), "re-registered: the old serial is no longer answered");
    CHECK(tstor_get(T, b.serial, &p, &o) && p == b.pool && o == b.off, "re-registered: the new texture's storage");
    mtl_reg_tex(T, &b, NULL);   // the same again (mtl_reg_tex's 'same': nothing written)
    CHECK(tstor_get(T, b.serial, &p, &o) && p == b.pool && o == b.off, "registered again the same: unchanged");
    mtl_reg_tex_gone(T);   // its pool finalized: the registration stays, marked gone (fb_att_is's lock path reads it all the same)
    CHECK(same_where(where_of(T, b.serial, 1), where_of(T, b.serial, 0)), "a gone registration: the same storage either way");
    mtl_reg_tex(T, NULL, NULL);
    CHECK(!tstor_get(T, b.serial, &p, &o), "emptied: not answered");
    CHECK(same_where(where_of(T, b.serial, 1), where_of(T, b.serial, 0)) && !where_of(T, b.serial, 1).pool, "emptied: no storage either way");
    // Random registrations over 64 IDs and 8 pools, every query (current and stale serials) answered the same with the switch on and off
    uint64_t rng = 0x9e3779b97f4a7c15ull, sers[64][4] = {{0}}; int bad = 0, n = 0;
    uint64_t f0 = g_fb_stor_fast;
    for (int step = 0; step < 4000; step++) {
        rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17;
        int id_ = 200 + (int)(rng % 64), op = (int)(rng >> 8) % 8;
        if (op == 0) mtl_reg_tex(id_, NULL, NULL);
        else if (op == 1) mtl_reg_tex_gone(id_);
        else { tex_t t = mk_tex((int)(rng >> 16) % 8, (int64_t)((rng >> 24) % 16) * 0x100); mtl_reg_tex(id_, &t, NULL); uint64_t *s = sers[id_ - 200]; memmove(s + 1, s, 3 * sizeof *s); s[0] = t.serial; }
        for (int q = 0; q < 4; q++) { uint64_t s = sers[id_ - 200][q]; if (!s) continue; n++; bad += !same_where(where_of(id_, s, 1), where_of(id_, s, 0)); }
    }
    CHECK(!bad && n > 10000, "4,000 random registrations: fb_att_is reads the same storage with DM_NVN_FB_STOR on and off for every current and stale serial");
    CHECK(g_fb_stor_fast > f0, "the lock-free record answered");
    printf("storage record: %d queries after random registrations, %d different\n", n, bad);
}

// One thread registers an ID with two textures in turn (another pool and offset each), as fast as it can; the reader asks for each serial: a record it takes must be that texture's
static _Atomic int g_stop; static tex_t g_ta, g_tb; enum { TC = 300 };
static void *toggler(void *arg) { (void)arg; uint64_t n = 0; while (!atomic_load(&g_stop)) { mtl_reg_tex(TC, (n++ & 1) ? &g_tb : &g_ta, NULL); } return (void *)(uintptr_t)n; }
static void storage_race(void) {
    g_ta = mk_tex(3, 0x300); g_tb = mk_tex(4, 0x400); mtl_reg_tex(TC, &g_ta, NULL);
    atomic_store(&g_stop, 0); pthread_t th; pthread_create(&th, NULL, toggler, NULL);
    uint64_t taken = 0, torn = 0, naive_torn = 0, t0 = bp_now();
    while (bp_now() - t0 < 300000000ull) {
        for (int k = 0; k < 2; k++) { const tex_t *want = k ? &g_tb : &g_ta; const pool_t *p; int64_t o;
            if (tstor_get(TC, want->serial, &p, &o)) { taken++; torn += p != want->pool || o != want->off; } }
        // negative control: the same fields read without the sequence: a serial beside the other texture's pool or offset
        const tstor_t *e = &g_tstor[TC]; uint64_t s = atomic_load_explicit(&e->ser, memory_order_relaxed); uintptr_t p = atomic_load_explicit(&e->pool, memory_order_relaxed); int64_t o = atomic_load_explicit(&e->off, memory_order_relaxed);
        if (s == g_ta.serial) naive_torn += p != (uintptr_t)g_ta.pool || o != g_ta.off; else if (s == g_tb.serial) naive_torn += p != (uintptr_t)g_tb.pool || o != g_tb.off;
    }
    atomic_store(&g_stop, 1); void *wr; pthread_join(th, &wr);
    printf("storage record under a registering thread: %llu registrations, %llu records taken, %llu torn; read without the sequence: %llu torn (negative control, timing-dependent)\n",
           (unsigned long long)(uintptr_t)wr, (unsigned long long)taken, (unsigned long long)torn, (unsigned long long)naive_torn);
    CHECK(taken > 0 && !torn, "a record taken while another thread registers the ID is always one texture's own");
    mtl_reg_tex(TC, NULL, NULL);
}

// Bench: the storage read fb_att_is makes once per sampled texture of a draw, locked (as before) and from the record; 33,024 IDs registered (the pool walk's count in Ocarina of Time),
// reads spread over 4,000 of them. With a second thread registering textures meanwhile (the game streaming), the locked read waits for it
static double bench_where(int fast, int n, const uint64_t *ser, const int *tid) {
    uint64_t t0 = bp_now(); uintptr_t sink = 0;
    for (int i = 0; i < n; i++) { fb_where w = {0}; int id_ = tid[i];
        if (fast && tstor_get(id_, ser[i], &w.pool, &w.off)) {}
        else { rmu_lock(); if (id_ > 0 && id_ < g_ntreg && g_treg[id_].ok && g_treg[id_].t.serial == ser[i]) { w.pool = g_treg[id_].t.pool; w.off = g_treg[id_].t.off; } os_unfair_lock_unlock(&g_rmu); }
        sink += (uintptr_t)w.pool + (uintptr_t)w.off; }
    __asm__ volatile("" :: "r"(sink));
    return (double)(bp_now() - t0) / n;
}
static void *streamer(void *arg) { (void)arg; uint64_t n = 0; while (!atomic_load(&g_stop)) { tex_t t = mk_tex(5, (int64_t)(n % 64) * 0x100); mtl_reg_tex(40000 + (int)(n % 512), &t, NULL); n++; usleep(20); } return NULL; }
static void storage_bench(void) {
    enum { IDS = 33024, HOT = 4000, N = 2000000 };
    static uint64_t sers[IDS]; for (int i = 1; i < IDS; i++) { tex_t t = mk_tex(i % 8, (int64_t)i * 0x1000); mtl_reg_tex(1000 + i, &t, NULL); sers[i] = t.serial; }
    static uint64_t qs[N]; static int qt[N]; uint64_t rng = 12345;
    for (int i = 0; i < N; i++) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; int k = 1 + (int)(rng % HOT); qt[i] = 1000 + k; qs[i] = sers[k]; }
    double slow = 1e9, fast = 1e9;
    for (int r = 0; r < 5; r++) { double a = bench_where(0, N, qs, qt), b = bench_where(1, N, qs, qt); if (a < slow) slow = a; if (b < fast) fast = b; }
    atomic_store(&g_stop, 0); pthread_t th; pthread_create(&th, NULL, streamer, NULL);
    double slow_c = 1e9, fast_c = 1e9;
    for (int r = 0; r < 5; r++) { double a = bench_where(0, N, qs, qt), b = bench_where(1, N, qs, qt); if (a < slow_c) slow_c = a; if (b < fast_c) fast_c = b; }
    atomic_store(&g_stop, 1); pthread_join(th, NULL);
    // 12,000 a frame: about 2,000 draws with an attachment, 6 sampled textures each
    printf("bench, feedback storage read (best of 5, %d reads over %d of %d IDs): under g_rmu %.1f ns, lock-free %.1f ns a read (%.1fx); with a thread registering every 20 us: %.1f ns vs %.1f ns; "
           "at 12,000 reads a frame: %.0f us vs %.0f us\n", N, HOT, IDS, slow, fast, slow / fast, slow_c, fast_c, slow * 12000 / 1e3, fast * 12000 / 1e3);
    CHECK(fast <= slow, "the record is no slower than the lock");
}

static void rel(void *v) { CFRelease(v); }
static void pipeline_memo(void) {
    enum { K = 3000 };
    static pso_key keys[K]; NSMutableArray *objs = [NSMutableArray array];
    nvn_hm_clear(&g_pso, rel);
    for (int i = 0; i < K; i++) { memset(&keys[i], 0, sizeof keys[i]); keys[i].vs = (const void *)(uintptr_t)(0x1000 + i); keys[i].cfmt[0] = 80; keys[i].chmask = 0xf; [objs addObject:[NSObject new]]; }
    for (int i = 0; i < K / 2; i++) hm_put_id(&g_pso, &keys[i], objs[i]);
    uint32_t hint = 0; uint64_t h0 = g_pso_memo_hit;
    CHECK(pso_tab_get(&g_pso, &keys[7], &hint) == objs[7] && hint, "a lookup notes its slot");
    CHECK(pso_tab_get(&g_pso, &keys[7], &hint) == objs[7] && g_pso_memo_hit == h0 + 1, "the same key again: from the slot");
    CHECK(pso_tab_get(&g_pso, &keys[8], &hint) == objs[8], "another key through the same slot: its own pipeline");
    CHECK(pso_tab_get(&g_pso, &keys[K - 1], &hint) == nil, "a key not in the table: none");
    hint = 0; pso_tab_get(&g_pso, &keys[9], &hint);
    for (int i = K / 2; i < K; i++) hm_put_id(&g_pso, &keys[i], objs[i]);   // the table grows (slots move)
    int bad = 0; for (int i = 0; i < K; i++) { uint32_t h = i == 9 ? hint : 0; bad += pso_tab_get(&g_pso, &keys[i], &h) != objs[i]; if (i == 9) hint = h; }
    CHECK(!bad, "after the table grew, every key (one with a slot from before) finds its own pipeline");
    nvn_hm_clear(&g_pso, rel);   // as t_pso_warm and t_pso_pending clear it between cases
    CHECK(pso_tab_get(&g_pso, &keys[9], &hint) == nil, "a cleared table: nothing from the slot (no pipeline it let go)");
    hm_put_id(&g_pso, &keys[10], objs[10]);
    uint32_t h10 = hint; CHECK(pso_tab_get(&g_pso, &keys[10], &h10) == objs[10], "put after the clear: found");
    g_pso_memo = 0; uint32_t z = 0; uint64_t hit = g_pso_memo_hit, miss = g_pso_memo_miss;
    CHECK(pso_tab_get(&g_pso, &keys[10], &z) == objs[10] && !z && g_pso_memo_hit == hit && g_pso_memo_miss == miss, "DM_NVN_PSO_MEMO=0: a plain lookup, no slot noted, nothing counted");
    g_pso_memo = 1;
    nvn_hm_clear(&g_pso, rel);
    printf("pipeline memo: sizeof(pso_key) %zu bytes\n", sizeof(pso_key));
}
// Bench: 3,000 pipelines in the table, 1,500 lookups a frame from 300 programs, each asking for its own key (most of a frame's pso_get calls come back to a program's pipeline)
static void pipeline_bench(void) {
    enum { K = 3000, PR = 300, N = 1500 * 400 };
    static pso_key keys[K]; NSMutableArray *objs = [NSMutableArray array];
    nvn_hm_clear(&g_pso, rel);
    for (int i = 0; i < K; i++) { memset(&keys[i], 0, sizeof keys[i]); keys[i].vs = (const void *)(uintptr_t)(0x1000 + i); keys[i].fs = (const void *)(uintptr_t)(0x9000 + i % 97); keys[i].cfmt[0] = 80; keys[i].chmask = 0xf; [objs addObject:[NSObject new]]; hm_put_id(&g_pso, &keys[i], objs[i]); }
    static uint32_t hints[PR]; static int seq[N]; uint64_t rng = 777; for (int i = 0; i < N; i++) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; seq[i] = (int)(rng % PR); }
    double plain = 1e9, memo = 1e9; uintptr_t sink = 0;
    for (int r = 0; r < 5; r++) {
        pso_key k; uint64_t t0 = bp_now();
        for (int i = 0; i < N; i++) { memcpy(&k, &keys[seq[i] * 7], sizeof k); sink += (uintptr_t)(__bridge void *)hm_get_id(&g_pso, &k); }   // the key as pso_key_fill leaves it: a copy on the stack
        double a = (double)(bp_now() - t0) / N; t0 = bp_now();
        for (int i = 0; i < N; i++) { memcpy(&k, &keys[seq[i] * 7], sizeof k); sink += (uintptr_t)(__bridge void *)pso_tab_get(&g_pso, &k, &hints[seq[i]]); }
        double b = (double)(bp_now() - t0) / N; if (a < plain) plain = a; if (b < memo) memo = b;
    }
    __asm__ volatile("" :: "r"(sink));
    printf("bench, render pipeline lookup (best of 5, %d lookups from %d programs, %d pipelines, %zu-byte keys): hashed %.1f ns, from the program's slot %.1f ns (%.1fx); at 1,500 a frame: %.0f us vs %.0f us\n",
           N, PR, K, sizeof(pso_key), plain, memo, plain / memo, plain * 1500 / 1e3, memo * 1500 / 1e3);
    CHECK(memo <= plain, "the slot is no slower than the hash");
    nvn_hm_clear(&g_pso, rel);
}

int main(void) { @autoreleasepool {
    mtl_init();
    storage_record();
    storage_race();
    storage_bench();
    pipeline_memo();
    pipeline_bench();
    printf("replay fast paths: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
