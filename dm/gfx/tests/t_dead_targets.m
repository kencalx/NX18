// Render targets another one drew over (nvn_mtl.m tu_pass and alias_dead_locked, DM_NVN_RT_DEAD; after NXNative 8653238e): a shared render target goes once another target of its
// pool wrote its bytes after its last use and it has stayed unused for the wait. One read every frame stays, as does one nothing overlaps, one whose overlapping neighbour wrote before
// its last use, and one a pin holds. A released target's serial no longer resolves, its texture ID drops its view (a pool walk reads it as the dummy until a pass writes it), and its
// next use makes it again. The wait and the pass interval follow DM_NVN_RT_DEAD_MS. Last, a pass over 4,000 covered targets (it prints the time). With --off (DM_NVN_RT_DEAD=0;
// on is the default) nothing is covered and nothing goes. A pass is skipped while no covered target has gone unused for the wait (tu_check). A resolution family (two sizes at
// one offset, sharing a heap) goes only whole (alias_dead_locked): a family whose sizes a target of another format drew over goes with both, even past the pass's limit, and its
// heap is counted; a size the size in use drew over stays while that size is in use, and goes alone with DM_NVN_RT_DEAD_FAMILY=0, as before. The pass's limit counts no family
// member: a call that asks for one releases a dead target of no family that kept members come before in the table. The members kept are a count, not a sum over passes, and a pass
// that only keeps them prints no line. A member kept at its last use is not counted for the skip until an entry leaves the table or a pass finds it not dead; then its family goes.
// Many families (Luigi's Mansion 3's 1-pixel dynamic-resolution steps: 14 families of 300 sizes): a pass asks each family's member in use, not all its members, prints its time, and
// releases what the old rule (every member asked) releases, with families going whole, a pinned size keeping its family and then asked first, and the family going once unpinned.
// Memory pressure (DM_NVN_RT_DEAD_PRESSURE, with a stand-in for os_proc_available_memory): the hysteresis over every headroom reading of Ocarina of Time's iPhone run to Hyrule Field
// (low at its memory warning, and once more) and over its GPU allocated around the load (low 2.4 s before the warning); under 2 GB a target drawn over goes after 300 ms with its
// heap freed, not waiting (with =0 at the usual 3 s, its heap waiting), one read 200 ms before stays, and the last 4 frames keep a target used in them however long they took;
// 8 of 12 made again within 10 s double the wait, and the recovery takes it back; a memory warning's pass releases at 300 ms in the trim; each group of releases has one line. The
// back-off over more than one window and spell (a step weighs the remakes of its own window's releases alone), each step and spell's end saying no more made again than released;
// the window's line giving the pressure waits; a family's and a recycled target's heaps, freed by a pressure pass, alive and resident while the GPU holds a submission before the
// release, freed after it; DM_NVN_RT_DEAD_PRESSURE=ab releasing sooner only in the phases it is on.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static tex_t target(pool_t *pool, uint64_t serial, int64_t off, NVNformat format, unsigned w) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = w, .height = w, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t); return t;
}
static int shared(id o) { pthread_mutex_lock(&g_smu); int r = o && g_alias_set && CFSetContainsValue(g_alias_set, (__bridge const void *)o); pthread_mutex_unlock(&g_smu); return r; }
static int covered(id o) { tu_rec u; return tu_use_of(o, &u); }
static long alias_slot(id o) {   // o's place in the sharing table: the order alias_dead_locked asks in
    long s = -1; pthread_mutex_lock(&g_smu); for (uint32_t i = 0; i < g_alias.cap && s < 0; i++) if (g_alias.vals[i] == (__bridge void *)o) s = (long)i; pthread_mutex_unlock(&g_smu); return s;
}
static void alias_drop(id o) {   // o's entry leaves the sharing table, as a takeover or a pool's end takes it
    pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_alias.cap; i++) if (g_alias.vals[i] == (__bridge void *)o) { alias_key k; memcpy(&k, g_alias.keys + (size_t)i * g_alias.klen, sizeof k); alias_del(&k); break; }
    pthread_mutex_unlock(&g_smu);
}
static tu_rec rec_of(id o) { tu_rec u = {0}; tu_use_of(o, &u); return u; }
static void at(uint32_t now) { g_tu_now = now; }
static void submissions(void) { for (int k = 0; k <= ALIAS_IDLE; k++) { CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "submission completes"); mtl_sub_begin(); } }   // past ALIAS_IDLE: no lookup found them lately
static void pass(uint32_t now) { submissions(); at(now); g_tu_last = now - 10; tu_pass(); }
static void drawn(id<MTLTexture> t) { tu_wrote(t); }
// The rule before the families were asked by their member in use: every covered entry asked (alias_dead_one), a target of no family going when dead, a family only when every
// member of it is dead (a member not covered is never known dead). The pass at `now` (no pass limit reached here) must release exactly those
static int pass_as_old_rule(uint32_t now) {
    submissions(); at(now); g_tu_last = now - 10;
    NSMutableArray *all = [NSMutableArray array]; NSMutableSet *want = [NSMutableSet set];
    pthread_mutex_lock(&g_smu);
    CFMutableSetRef pinned = CFSetCreateMutable(NULL, 0, NULL);
    for (uint32_t i = 0; i < g_tex_pins.cap; i++) { tex_pin *pin = g_tex_pins.vals[i]; if (!pin || !pin->object) continue;
        for (id o = (__bridge id)pin->object; o; o = view_parent(o)) CFSetAddValue(pinned, (__bridge const void *)o); }
    NSMapTable *fam = [NSMapTable strongToStrongObjectsMapTable];   // owner -> @(all dead so far)
    NSMutableArray *dead = [NSMutableArray array];
    for (uint32_t i = 0; i < g_alias.cap; i++) {
        void *val = g_alias.vals[i]; if (!val) continue;
        id o = (__bridge id)val; [all addObject:o];
        const alias_key *k = (const alias_key *)(const void *)(g_alias.keys + (size_t)i * g_alias.klen);
        tu_rec u; int d = tu_use_of(o, &u) ? alias_dead_one(k, val, &u, now, g_tu_idle, pinned) : 0;
        id own = objc_getAssociatedObject(o, &g_image_heap_owner_key);
        if (own) { NSNumber *a = [fam objectForKey:own]; [fam setObject:@((a ? a.boolValue : 1) && d == 1) forKey:own]; }
        if (d == 1) [dead addObject:o];
    }
    for (id o in dead) { id own = objc_getAssociatedObject(o, &g_image_heap_owner_key); if (!own || [[fam objectForKey:own] boolValue]) [want addObject:o]; }
    CFRelease(pinned);
    pthread_mutex_unlock(&g_smu);
    tu_pass();
    int ok = 1;
    for (id o in all) { int went = !shared(o); if (went != [want containsObject:o]) { ok = 0; fprintf(stderr, "release differs from the old rule: %p %s\n", (__bridge void *)o, went ? "went" : "stayed"); } }
    return ok;
}
static uint64_t covered_alone(void) {   // covered entries of no family: each one is asked
    uint64_t n = 0; pthread_mutex_lock(&g_smu);
    for (uint32_t i = 0; i < g_alias.cap; i++) { void *val = g_alias.vals[i]; tu_rec u; if (val && tu_use_of((__bridge id)val, &u) && !objc_getAssociatedObject((__bridge id)val, &g_image_heap_owner_key)) n++; }
    pthread_mutex_unlock(&g_smu); return n;
}
// Memory pressure (the part after the families)
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = o && [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
static int rh_waits(id h) { int w = 0; os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; h && i < g_rh_n && !w; i++) w = g_rh[i].heap == (__bridge void *)h; os_unfair_lock_unlock(&g_rh_lk); return w; }
static uint64_t g_fake_avail; static uint64_t fake_avail(void) { return g_fake_avail; }
static void headroom(uint64_t mb) { g_fake_avail = mb << 20; g_tu_hr_at = 0; }   // the stand-in for os_proc_available_memory, read at the next tu_due
static uint64_t g_fr;   // the frame the pressure part is at
static void due(uint32_t now, int frames) { for (int k = 0; k < frames; k++) { atomic_store(&g_cur_frame, ++g_fr); tu_frame_note(g_fr, now); } at(now); tu_due(); }   // a submission's start at `now`, `frames` frames beginning then
static void settle(void) {   // the released textures' fences pass, the deferred releases run and the residency set lets go of what left it (as in t_rt_recycle)
    mtl_sub_commit(); mtl_drain(); mtl_sub_begin(); mtl_sub_commit(); mtl_drain();
    dispatch_sync(g_feedback_q, ^{}); defer_drain(); res_commit(); mtl_sub_begin();
}
// What MLOG writes to stderr between capture and captured, read back into g_log (and printed as well)
static char g_log[1 << 16]; static FILE *g_logcap; static int g_logcap_fd = -1;
static void capture(void) {
    fflush(stderr); g_log[0] = 0; g_logcap = tmpfile(); if (!g_logcap) return;
    g_logcap_fd = dup(2); if (g_logcap_fd < 0) { fclose(g_logcap); g_logcap = NULL; return; }
    dup2(fileno(g_logcap), 2);
}
static void captured(void) {
    if (!g_logcap) return;
    fflush(stderr); dup2(g_logcap_fd, 2); close(g_logcap_fd); g_logcap_fd = -1;
    rewind(g_logcap); size_t n = fread(g_log, 1, sizeof g_log - 1, g_logcap); g_log[n] = 0; fclose(g_logcap); g_logcap = NULL;
    fputs(g_log, stderr);
}
// Whether every back-off step (`K of N textures … were made again`) and every low spell's end (`… s low: N textures, M MB released sooner in it, K …`) in log says no more made
// again than released; *steps and *ends count them
static int remakes_within_releases(const char *log, int *steps, int *ends) {
    int ok = 1; *steps = *ends = 0;
    for (const char *p = log; *p; ) {
        const char *e = strchr(p, '\n'); size_t len = e ? (size_t)(e - p) : strlen(p); char line[4096];
        memcpy(line, p, len < sizeof line ? len : sizeof line - 1); line[len < sizeof line ? len : sizeof line - 1] = 0; p += len + (e != NULL);
        const char *s; unsigned long long k, n;
        if ((s = strstr(line, "(DM_NVN_RT_DEAD_PRESSURE): ")) && strstr(line, " were made again within ") && sscanf(s, "(DM_NVN_RT_DEAD_PRESSURE): %llu of %llu textures", &k, &n) == 2) { (*steps)++; ok &= k <= n; }
        if ((s = strstr(line, " s low: ")) && sscanf(s, " s low: %llu textures, %*u MB released sooner in it, %llu", &n, &k) == 2) { (*ends)++; ok &= k <= n; }
    }
    return ok;
}
static const char *line_with(const char *log, const char *key, char *out, size_t cap) {   // the first line of log holding key, or NULL
    const char *s = strstr(log, key); if (!s) return NULL;
    const char *b = s; while (b > log && b[-1] != '\n') b--;
    const char *e = strchr(s, '\n'); size_t len = e ? (size_t)(e - b) : strlen(b); if (len >= cap) len = cap - 1;
    memcpy(out, b, len); out[len] = 0; return out;
}
// Every headroom reading (MB) the log of Ocarina of Time's 55-minute iPhone run to Hyrule Field has (round-logs/oot-field1/log.txt, 2026-11-15), in its order: the memory lines, the
// finalized-texture table's low-headroom lines and the iOS memory warning (index 281: 1,580 MiB at 3091 s, the Field load)
static const uint16_t oot_hr[] = {
    7425,7355,5100,3855,4143,3882,3956,4214,4469,4325,4259,4392,4261,4349,4488,3523,3622,3964,4289,4208,3958,3150,3370,3545,4063,3505,3899,3792,
    3910,3982,3888,3557,3847,3531,3713,3970,3506,4030,3861,3958,3845,3570,3780,3119,3487,3878,3724,3805,3730,3251,3455,3150,3609,2977,3224,3810,
    3445,3548,3640,2993,3534,3023,3255,3373,3292,4074,4358,3710,3298,3412,3643,3556,3931,4064,3021,3421,3558,3686,3967,4094,3904,3498,3980,3205,
    3565,3147,3218,3341,2848,3136,3613,3748,3407,3845,3806,4097,4010,3672,3519,3833,4098,3643,3295,3591,4033,3432,3971,3307,3489,3263,3169,3565,
    3403,2955,2578,3637,4031,3830,3601,3175,3562,3806,2856,3284,3380,3828,3660,3792,3694,3599,3232,3674,3370,3455,3251,3441,3359,3435,3271,3431,
    3539,3314,3182,3342,3118,3071,3362,3553,3308,3625,3556,3672,3242,3625,3776,3892,3663,3313,3727,3831,3717,3813,3728,3384,2956,2944,3183,3074,
    2967,2994,3078,3162,3230,3302,3622,3710,3797,3700,3530,3611,3455,3574,3387,3227,3316,3398,3317,3253,3567,3727,3655,3437,3562,3681,3758,3681,
    3770,3608,3689,3605,3384,3280,3445,3100,3029,3161,3071,3380,3493,3562,3671,3770,3705,3838,3627,3524,3582,3572,3489,3599,3678,3764,3572,3873,
    3788,3676,3792,3029,3150,3587,3674,3707,3736,3510,3618,3550,3485,3766,3703,3255,3391,3542,3611,3521,3439,3508,3405,3477,3452,3090,3174,2963,
    3242,3346,3265,3336,3453,3583,3474,3605,3251,2968,2979,3210,3126,3029,3029,3057,3063,3055,2763,2761,2826,2841,2845,2845,2777,2679,2679,2745,
    2443,1580,1953,2643,2629,2751,2545,2814,2784,2923,2913,2986,2988,2771,2755,2441,2505,2544,2690,2650,2556,2640,2631,2660,2671,2567,2554,2711,
    2742,2780,3338,2937,2227,2243,2590,2644,2644,2596,2982,3097,2987,2852,2023,2526,2531,2719,2769,2401,2403,2588,2634,2882,};

int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "--off");
    if (!off) unsetenv("DM_NVN_RT_DEAD"); else setenv("DM_NVN_RT_DEAD", "0", 1);   // on is the default
    mtl_init(); mtl_sub_begin(); g_tu_manual = 1; g_tu_idle = 30; g_tu_every = 10;
    void *mem = NULL; posix_memalign(&mem, 16384, 64 << 20); memset(mem, 0, 64 << 20);
    pool_t pool = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem = mem, .size = 64 << 20};
    at(100);
    tex_t a = target(&pool, 97001, 0, NVN_FORMAT_RGBA8, 64), b = target(&pool, 97002, 0, NVN_FORMAT_R32F, 64);           // b over a's bytes
    tex_t c = target(&pool, 97003, 1 << 20, NVN_FORMAT_RGBA8, 64);                                                         // nothing over it
    tex_t d = target(&pool, 97004, 2 << 20, NVN_FORMAT_RGBA8, 64), e = target(&pool, 97005, 2 << 20, NVN_FORMAT_R32F, 64); // e over d, d read every frame
    tex_t f = target(&pool, 97006, 3 << 20, NVN_FORMAT_RGBA8, 64), g = target(&pool, 97007, 3 << 20, NVN_FORMAT_R32F, 64); // g over f, f pinned
    tex_t h = target(&pool, 97008, 4 << 20, NVN_FORMAT_RGBA8, 64), i = target(&pool, 97009, 4 << 20, NVN_FORMAT_R32F, 64); // i wrote before h was made, h drew over i
    id<MTLTexture> ta = tex_mtl(&a), tc = tex_mtl(&c), td = tex_mtl(&d), tf = tex_mtl(&f), ti = tex_mtl(&i);
    if (off) {   // =0: no records, so nothing is stamped or released
        id<MTLTexture> tb = tex_mtl(&b); drawn(ta); drawn(tb);
        CHECK(ta && !covered(ta) && !g_tu.n, "with DM_NVN_RT_DEAD=0 no render target is covered");
        pass(200);
        CHECK(shared(ta) && shared(tb) && g_tu_n == 0, "and none is released");
    } else {
    CHECK(ta && (ta.usage & MTLTextureUsageRenderTarget) && covered(ta), "a compressible render target of a GPU-only pool is covered");
    drawn(ta); drawn(tc); drawn(td); drawn(tf); drawn(ti);
    at(110);
    id<MTLTexture> tb = tex_mtl(&b), te = tex_mtl(&e), tg = tex_mtl(&g), th = tex_mtl(&h);
    CHECK(tb && tb != ta && shared(ta) && shared(tb), "another description over the bytes leaves the target a live object resolves to (the takeover)");
    drawn(tb); drawn(te); drawn(tg); drawn(th);
    mtl_tex_pin(f.serial);
    {   // A pass is skipped while no covered target has gone unused for the wait (tu_check): the oldest use is the drawing at 100, the newest at 110, the wait 30
        CHECK(!tu_any_idle(125, 30) && tu_any_idle(130, 30), "the first target unused for the wait is found at 130, none before");
        uint64_t p0 = g_tu_passes, s0 = g_tu_skipped; at(125); tu_check();
        CHECK(g_tu_passes == p0 && g_tu_skipped == s0 + 1 && shared(ta) && g_tu_checked == 125, "at 125 the pass is skipped, nothing released");
    }
    for (uint32_t now = 120; now <= 160; now += 10) { at(now); CHECK(tex_mtl(&d) == td, "the target read every frame resolves to its texture"); }
    {   // a's and c's texture IDs, bound (a use) at 100 and 160
        mtl_reg_tex(5, &a, NULL); mtl_reg_tex(6, &c, NULL);
        os_unfair_lock_lock(&g_rmu); void *va = NULL, *vc = NULL; at(100); tex_fast_rid(5, &va); at(160); tex_fast_rid(6, &vc); os_unfair_lock_unlock(&g_rmu);
        CHECK(va && vc, "the IDs have views");
    }
    pass(160);
    CHECK(!shared(ta) && !tex_get(a.serial), "a target drawn over and unused for the wait goes, with its serial entry");
    CHECK(pool_unwritten_target(&a), "a pool walk reads it as the dummy until a pass writes it");
    os_unfair_lock_lock(&g_rmu); CHECK(!g_treg[5].view, "its texture ID dropped its view"); CHECK(g_treg[6].view != NULL, "an ID of a target that stays keeps its view"); os_unfair_lock_unlock(&g_rmu);
    CHECK(shared(tb) && tex_get(b.serial) == tb, "the target that drew over it stays (written after nothing over it)");
    CHECK(shared(tc), "a target nothing overlaps stays");
    CHECK(shared(td), "a target read every frame stays");
    CHECK(shared(tf) && tex_get(f.serial) == tf, "a pinned target stays");
    CHECK(shared(th), "a target whose neighbour wrote before its last use stays");
    CHECK(!shared(ti), "and the neighbour it drew over goes");
    CHECK(g_tu_n == 2 && g_tu_pinned == 1, "two released, one kept by a pin");
    CHECK(g_tu_bytes >= 2 * 64 * 64 * 4, "their bytes are counted");
    mtl_tex_unpin(f.serial);
    at(170);
    id<MTLTexture> ta2 = tex_mtl(&a); drawn(ta2);
    CHECK(ta2 && ta2 != ta && shared(ta2) && tex_get(a.serial) == ta2 && covered(ta2), "drawn into again, it is made again and covered");
    CHECK(g_tu_remade == 1, "and counted as made again");
    pass(175);
    CHECK(!shared(tb) && shared(ta2), "b goes in turn: a2 drew over its bytes after its last use");
    CHECK(!shared(tf) && shared(tg), "unpinned, the target drawn over goes");
    {   // The cost: 4,000 covered targets in 2,000 overlapping pairs, half of them released
        enum { N = 2000 }; static tex_t ts[2 * N];
        at(300);
        for (int k = 0; k < N; k++) { ts[2 * k] = target(&pool, 98000 + 2 * k, (8 << 20) + ((int64_t)k << 14), NVN_FORMAT_RGBA8, 32); drawn(tex_mtl(&ts[2 * k])); }
        at(310);
        for (int k = 0; k < N; k++) { ts[2 * k + 1] = target(&pool, 98001 + 2 * k, (8 << 20) + ((int64_t)k << 14), NVN_FORMAT_R32F, 32); drawn(tex_mtl(&ts[2 * k + 1])); }
        uint64_t n0 = g_tu_n, ns0 = g_tu_ns;
        int64_t rounds = 0; for (uint32_t now = 350; g_tu_n - n0 < N && rounds < 20; now += 10, rounds++) pass(now);
        double ms = (g_tu_ns - ns0) / 1e6 / (double)rounds;
        printf("a pass over %u covered targets: %.3f ms (%lld passes released %llu)\n", g_tu.n + (unsigned)(g_tu_n - n0), ms, (long long)rounds, (unsigned long long)(g_tu_n - n0));
        CHECK(g_tu_n - n0 == N, "every target drawn over goes, TU_MAX a pass");
        { uint64_t p0 = g_tu_passes; at(g_tu_now + 10); tu_check(); CHECK(g_tu_passes == p0 + 1, "with targets unused for the wait, the check runs the pass"); }
        CHECK(ms < 20, "a pass stays short");
        for (int k = 0; k < 2 * N; k++) mtl_tex_release(&ts[k]);
    }
    {   // Resolution families. F: its sizes 64 and 48, then a target of another format over both, all unused for the wait: both go in one call that asks for one, with their heap
        at(400);
        tex_t f64 = target(&pool, 99001, 48 << 20, NVN_FORMAT_RGBA8, 64), f48 = target(&pool, 99002, 48 << 20, NVN_FORMAT_RGBA8, 48), fo = target(&pool, 99003, 48 << 20, NVN_FORMAT_R32F, 64);
        id<MTLTexture> t64 = tex_mtl(&f64); drawn(t64);
        at(405); id<MTLTexture> t48 = tex_mtl(&f48); drawn(t48);
        at(410); id<MTLTexture> to = tex_mtl(&fo); drawn(to);
        CHECK(t64.heap && t64.heap == t48.heap && objc_getAssociatedObject(t64, &g_image_heap_owner_key), "two sizes at one offset are a resolution family with one heap");
        CHECK(!to.heap || to.heap != t64.heap, "the target of another format is not of the family");
        uint64_t heap = t64.heap.size;
        submissions(); at(460);
        uint64_t *sers = NULL; uint32_t nser = 0;
        pthread_mutex_lock(&g_smu); tu_dead_stats st = alias_dead_locked(g_tu_now, g_tu_idle, 1, &sers, &nser); pthread_mutex_unlock(&g_smu); free(sers);
        CHECK(!shared(t64) && !shared(t48) && shared(to), "a family drawn over whole goes whole, past the limit of one a call; the target over it stays");
        CHECK(st.n == 2 && st.fam == 2 && st.fam_n == 1 && st.fam_bytes == heap && st.fam_kept == 0, "its two sizes and its heap are counted");
        t48 = t64 = nil;
        // G: its size 48 drawn over by its size 64, which is read every frame: 48 stays while 64 is in use
        at(500);
        tex_t g64 = target(&pool, 99011, 56 << 20, NVN_FORMAT_RGBA8, 64), g48 = target(&pool, 99012, 56 << 20, NVN_FORMAT_RGBA8, 48);
        id<MTLTexture> u48 = tex_mtl(&g48); drawn(u48);
        at(505); id<MTLTexture> u64 = tex_mtl(&g64); drawn(u64);
        CHECK(u64.heap && u64.heap == u48.heap, "G is a family too");
        uint64_t n0 = g_tu_n, fam0 = g_tu_fam, fn0 = g_tu_fam_n, l0 = g_tu_lines;
        for (uint32_t now = 510; now <= 560; now += 10) { at(now); CHECK(tex_mtl(&g64) == u64, "the size in use resolves to its texture"); }
        uint64_t f0 = atomic_load(&g_cur_frame); atomic_store(&g_cur_frame, f0 + 100000);   // the window's line, with the families' part (for the releases before)
        pass(560);
        CHECK(shared(u48) && shared(u64) && g_tu_n == n0, "a size drawn over by its family's size in use stays");
        CHECK(g_tu_fam_kept_now == 1 && g_tu_fam == fam0 && g_tu_fam_n == fn0, "and is counted as kept for its family");
        { tu_rec r = rec_of(u48); CHECK(r.kept == r.use && tu_kept_holds() && !tu_rec_idle(&r, 560, g_tu_idle, 1) && tu_rec_idle(&r, 560, g_tu_idle, 0), "kept at its last use: not counted for the skip, though unused for the wait"); }
        at(565); tex_mtl(&g64); atomic_store(&g_cur_frame, f0 + 100400); pass(565);
        atomic_store(&g_cur_frame, f0);
        CHECK(shared(u48) && g_tu_fam_kept_now == 1, "a second pass keeps it again: one member kept, not one a pass");
        CHECK(g_tu_lines == l0 + 1, "and, nothing having gone or come back, prints no window line");
        g_tu_fam_mode = 0;   // DM_NVN_RT_DEAD_FAMILY=0: one by one, as before
        at(570); tex_mtl(&g64); pass(570);
        CHECK(!shared(u48) && shared(u64) && g_tu_n == n0 + 1 && g_tu_fam == fam0 + 1 && g_tu_fam_n == fn0, "with the rule off it goes alone, a family member with no heap of its own");
        g_tu_fam_mode = 1;
        mtl_tex_release(&f64); mtl_tex_release(&f48); mtl_tex_release(&fo); mtl_tex_release(&g64); mtl_tex_release(&g48);
    }
    {   // The pass's limit counts no family member: kept members ahead of a dead target of no family in the table leave it its slot. H: 8 families like G (a size 48 that its size 64
        // in use drew over); V: 16 targets of no family that one R32F target drew over, all pinned but the one furthest along the table, so a call that asks for one has one to release
        enum { NF = 8, NV = 16 }; static tex_t hs[NF][2], vs[NV]; id<MTLTexture> h48[NF], h64[NF], vt[NV];
        at(600);
        for (int k = 0; k < NF; k++) { hs[k][0] = target(&pool, 99101 + 2 * k, (60 << 20) + ((int64_t)k << 16), NVN_FORMAT_RGBA8, 64); hs[k][1] = target(&pool, 99102 + 2 * k, (60 << 20) + ((int64_t)k << 16), NVN_FORMAT_RGBA8, 48); }
        for (int k = 0; k < NF; k++) { h48[k] = tex_mtl(&hs[k][1]); drawn(h48[k]); }
        for (int k = 0; k < NV; k++) { vs[k] = target(&pool, 99201 + k, (62 << 20) + ((int64_t)k << 16), NVN_FORMAT_RGBA8, 64); vt[k] = tex_mtl(&vs[k]); drawn(vt[k]); }
        at(605);
        for (int k = 0; k < NF; k++) { h64[k] = tex_mtl(&hs[k][0]); drawn(h64[k]); }
        tex_t vo = target(&pool, 99300, 62 << 20, NVN_FORMAT_R32F, 512); id<MTLTexture> tvo = tex_mtl(&vo); drawn(tvo);   // over all of V
        CHECK(h64[0].heap && h64[0].heap == h48[0].heap && !objc_getAssociatedObject(vt[0], &g_image_heap_owner_key), "H are families, V are not");
        submissions(); at(660);
        for (int k = 0; k < NF; k++) CHECK(tex_mtl(&hs[k][0]) == h64[k], "H's size in use resolves to its texture");
        long first48 = LONG_MAX; for (int k = 0; k < NF; k++) { long s = alias_slot(h48[k]); if (s >= 0 && s < first48) first48 = s; }
        int v = 0; for (int k = 1; k < NV; k++) if (alias_slot(vt[k]) > alias_slot(vt[v])) v = k;
        for (int k = 0; k < NV; k++) if (k != v) mtl_tex_pin(vs[k].serial);
        CHECK(first48 < alias_slot(vt[v]), "a kept member comes before the target in the table");
        uint64_t *sers = NULL; uint32_t nser = 0;
        pthread_mutex_lock(&g_smu); tu_dead_stats st = alias_dead_locked(g_tu_now, g_tu_idle, 1, &sers, &nser); pthread_mutex_unlock(&g_smu); free(sers);
        CHECK(!shared(vt[v]) && st.n == 1 && st.fam == 0, "the target goes in a call that asks for one");
        int kept = 1; for (int k = 0; k < NF; k++) kept &= shared(h48[k]) && shared(h64[k]);
        CHECK(kept && st.fam_kept >= 1, "and the members ahead of it stay, kept for their families");
        for (int k = 0; k < NV; k++) if (k != v) mtl_tex_unpin(vs[k].serial);
        for (int k = 0; k < NF; k++) { mtl_tex_release(&hs[k][0]); mtl_tex_release(&hs[k][1]); }
        for (int k = 0; k < NV; k++) mtl_tex_release(&vs[k]);
        mtl_tex_release(&vo);
    }
    {   // The marks of kept members (tu_kept, tu_rec_idle). L: its size 48, then its size 64, then a target of another format over both; 64 is read every frame, so 48 is kept and not
        // counted for the skip. Then 64 leaves the table: 48 counts again, and the next pass releases L whole (48 alone now, its heap with it)
        at(700);
        tex_t l64 = target(&pool, 99401, 50 << 20, NVN_FORMAT_RGBA8, 64), l48 = target(&pool, 99402, 50 << 20, NVN_FORMAT_RGBA8, 48), lo = target(&pool, 99403, 50 << 20, NVN_FORMAT_R32F, 64);
        id<MTLTexture> m48 = tex_mtl(&l48); drawn(m48);
        at(703); id<MTLTexture> m64 = tex_mtl(&l64); drawn(m64);
        at(706); id<MTLTexture> mo = tex_mtl(&lo); drawn(mo);
        CHECK(m64.heap && m64.heap == m48.heap, "L is a family");
        for (uint32_t now = 710; now <= 760; now += 10) { at(now); tex_mtl(&l64); }
        pass(760);
        tu_rec r = rec_of(m48);
        CHECK(shared(m48) && shared(m64) && r.kept == r.use && tu_kept_holds() && !tu_rec_idle(&r, 770, g_tu_idle, tu_kept_holds()), "48 is kept, and not counted for the skip");
        alias_drop(m64);
        CHECK(!tu_kept_holds() && tu_rec_idle(&r, 770, g_tu_idle, tu_kept_holds()), "once an entry leaves the table, it counts again");
        uint64_t fn0 = g_tu_fam_n;
        pass(770);
        CHECK(!shared(m48) && shared(mo) && g_tu_fam_n == fn0 + 1, "and the next pass releases L whole");
        CHECK(tu_kept_holds(), "a pass that asked every entry makes the marks hold again");
        // P: 48 kept while 64 is in use; then 48 is pinned, 64 goes unused and a target of another format draws over both. The pass keeps P for its pinned 48 and finds 48 not dead,
        // so 48 is marked no more (64 is, at its last use); unpinned, 48 counts for the skip again, and the next pass releases P whole
        at(800);
        tex_t p64 = target(&pool, 99501, 52 << 20, NVN_FORMAT_RGBA8, 64), p48 = target(&pool, 99502, 52 << 20, NVN_FORMAT_RGBA8, 48), po = target(&pool, 99503, 52 << 20, NVN_FORMAT_R32F, 64);
        id<MTLTexture> q48 = tex_mtl(&p48); drawn(q48);
        at(805); id<MTLTexture> q64 = tex_mtl(&p64); drawn(q64);
        for (uint32_t now = 810; now <= 860; now += 10) { at(now); tex_mtl(&p64); }
        pass(860);
        r = rec_of(q48); CHECK(shared(q48) && r.kept == r.use, "P's 48 is kept at its last use");
        mtl_tex_pin(p48.serial);
        at(865); id<MTLTexture> qo = tex_mtl(&po); drawn(qo);
        pass(900);
        r = rec_of(q48); tu_rec r64 = rec_of(q64);
        CHECK(shared(q48) && shared(q64) && !r.kept && r64.kept == r64.use, "pinned, 48 is not dead and marked no more; 64, dead now, is kept for it");
        mtl_tex_unpin(p48.serial);
        CHECK(tu_rec_idle(&r, 910, g_tu_idle, tu_kept_holds()) && !tu_rec_idle(&r64, 910, g_tu_idle, tu_kept_holds()), "unpinned, 48 counts for the skip");
        fn0 = g_tu_fam_n;
        pass(910);
        CHECK(!shared(q48) && !shared(q64) && shared(qo) && g_tu_fam_n == fn0 + 1, "and the next pass releases P whole");
        mtl_tex_release(&l64); mtl_tex_release(&l48); mtl_tex_release(&lo); mtl_tex_release(&p64); mtl_tex_release(&p48); mtl_tex_release(&po);
    }
    {   // Memory pressure (DM_NVN_RT_DEAD_PRESSURE: tu_low_next, tu_due, tu_press_wait, tu_backoff, tu_press_warning; with =0 nothing goes sooner than the usual 3 s)
        int press = tu_press_mode() != 0;
        // The hysteresis over the logged run: low under 2,048 MB, until over 2,560 MB
        int low = 0, nt = 0, tr[4] = {-1, -1, -1, -1};
        for (int k = 0; k < (int)(sizeof oot_hr / sizeof *oot_hr); k++) { int nl = tu_low_next(low, (uint64_t)oot_hr[k] << 20); if (nl != low) { if (nt < 4) tr[nt] = k; nt++; } low = nl; }
        CHECK(nt == 4 && tr[0] == 281 && tr[1] == 283, "the run's readings: low at its memory warning (1,580 MB), back at 2,643 MB, the first after the 457 MB release");
        CHECK(tr[2] == 322 && tr[3] == 325, "and once more at 2,023 MB (frame 153438, no warning) until 2,719 MB; nowhere else in its 332 readings");
        // Between memory lines the log reads no headroom; around the Field load, its GPU allocated (a line a second) less 10,290 MB (10,350 after the trim), as its memory lines pair them
        static const struct { double t; unsigned mb; } load[] = {{3087.7, 2468}, {3089.0, 2005}, {3089.6, 1801}, {3091.1, 1674}, {3091.4, 1580}, {3092.1, 1974}, {3093.1, 1978}, {3094.1, 2532}, {3095.1, 2705}};
        double from = 0, to = 0; low = 0;
        for (unsigned k = 0; k < sizeof load / sizeof *load; k++) { int nl = tu_low_next(low, (uint64_t)load[k].mb << 20); if (nl && !low) from = load[k].t; if (!nl && low) to = load[k].t; low = nl; }
        CHECK(from == 3089.0 && to == 3095.1, "estimated: low from 3089.0 s, 2.4 s before the warning (3091.4 s), until 3095.1 s");
        CHECK(!tu_low_next(0, 0) && !tu_low_next(1, 0) && tu_low_next(1, 2560ull << 20) && !tu_low_next(1, 2561ull << 20) && !tu_low_next(0, 2048ull << 20) && tu_low_next(0, 2047ull << 20), "no headroom known is never low; the edges");
        // The rule in the replay. O: old-area targets that new ones (N) drew over; R: one drawn over that is read 200 ms before the first low check
        pass(990);   // what the parts above left dead goes now, so the counts below are this part's
        uint64_t f0 = atomic_load(&g_cur_frame); g_fr = f0 + 1000;
        g_rh_avail = fake_avail; headroom(4096);
        enum { NOLD = 4, NB = 12 };
        static tex_t o[NOLD], n[NOLD], r, rn, sx, sn, b[NB], bn[NB], c, cn, w, wn;
        __weak id<MTLTexture> wo[NOLD]; __weak id<MTLHeap> wh;
        uint64_t pn0 = g_tu_press_n, l0 = g_tu_press_lines;
        @autoreleasepool {
            at(1000);
            for (int k = 0; k < NOLD; k++) { o[k] = target(&pool, 103001 + k, (40 << 20) + ((int64_t)k << 16), NVN_FORMAT_RGBA8, 64); id<MTLTexture> x = tex_mtl(&o[k]); drawn(x); wo[k] = x; }
            wh = wo[0].heap;
            r = target(&pool, 103011, (40 << 20) + (8 << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&r));
            at(1001);
            for (int k = 0; k < NOLD; k++) { n[k] = target(&pool, 103021 + k, (40 << 20) + ((int64_t)k << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&n[k])); }
            rn = target(&pool, 103031, (40 << 20) + (8 << 16), NVN_FORMAT_R32F, 64);
        }
        CHECK(wh && resident(wh) && !rh_waits(wh), "an old target is in a heap of its own (rh_place), resident");
        submissions();   // past ALIAS_IDLE
        due(1002, 6);
        CHECK(shared(wo[0]) && !g_tu_low, "with 4 GB of headroom an old target stays: unused 200 ms, the wait is 3 s");
        headroom(1900); due(1003, 6);
        CHECK(g_tu_low == press, "under 2 GB the headroom is low");
        @autoreleasepool { at(1004); tex_mtl(&r); at(1005); drawn(tex_mtl(&rn)); }   // R read at 1004, then drawn over
        submissions(); due(1006, 6);
        int ogone = 1; for (int k = 0; k < NOLD; k++) ogone &= !shared(wo[k]);
        CHECK(press ? ogone && g_tu_press_n == pn0 + NOLD : !ogone && g_tu_press_n == pn0, press ? "low: the old targets go after 600 ms unused, counted as pressure releases" : "=0: the old targets stay");
        CHECK(shared(tex_get(r.serial)), "a target read 200 ms ago stays, though drawn over since");
        CHECK(!press || (tu_press_wait(1006, 0) == TU_PRESS_IDLE && g_tu_pend.n == NOLD && (g_tu_pend.why & 1)), "the pressure wait is 300 ms at 60 fps, and the release waits for its line");
        if (press) {   // their heaps are freed with them, not kept waiting for reuse (g_tu_drop)
            settle();
            int freed = 1; for (int k = 0; k < NOLD; k++) freed &= !wo[k];
            CHECK(freed && !rh_waits(wh) && !resident(wh), "a pressure release frees its target and the target's heap, which does not wait for reuse");
        }
        due(1008, 6);
        CHECK(shared(tex_get(r.serial)) != press, press ? "unused 400 ms, the target read before goes" : "=0: it stays");
        // F: the last 4 frames hold a target used in them, however long they took (a load's long frames): S, drawn over after a read in a 500 ms frame
        @autoreleasepool { at(1010); sx = target(&pool, 103041, (40 << 20) + (9 << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&sx)); sn = target(&pool, 103042, (40 << 20) + (9 << 16), NVN_FORMAT_R32F, 64); }
        due(1010, 6); due(1015, 1);
        @autoreleasepool { at(1016); tex_mtl(&sx); at(1017); drawn(tex_mtl(&sn)); }
        submissions(); due(1020, 1); due(1025, 1); due(1030, 1);
        CHECK(!press || tu_press_wait(1030, 0) == 16, "four 500 ms frames: the pressure wait is the 1.6 s since the first of them began");
        CHECK(shared(tex_get(sx.serial)), "a target used in the last 4 frames stays, unused 1.4 s");
        due(1032, 6);
        CHECK(shared(tex_get(sx.serial)) != press, press ? "at 60 fps again (300 ms) it goes" : "=0: it stays");
        // The hysteresis live: low until over 2,560 MB
        headroom(2300); due(1033, 6); CHECK(g_tu_low == press, "2,300 MB: still low");
        headroom(2600); due(1034, 6); CHECK(!g_tu_low, "2,600 MB: low no more");
        headroom(2300); due(1035, 6); CHECK(!g_tu_low, "2,300 MB again: not low, coming from above");
        headroom(1900); due(1036, 6); CHECK(g_tu_low == press, "1,900 MB: low again");
        if (!press) {   // =0: the usual pass (at 1035) released the old targets after 3 s, and their heaps wait for reuse
            settle();
            CHECK(!shared(wo[0]) && rh_waits(wh) && resident(wh), "=0: the usual pass released the old targets at 3 s, and their heaps wait for reuse");
        }
        // The back-off: 12 targets released at low headroom, 8 of them made again within 10 s: the wait doubles; one made again after 11 s does not count
        uint64_t q0 = g_tu_press_quick, m0 = g_tu_remade, p1 = g_tu_press_n;
        @autoreleasepool {
            at(1037); for (int k = 0; k < NB; k++) { b[k] = target(&pool, 103101 + k, (40 << 20) + ((int64_t)(16 + k) << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&b[k])); }
            at(1038); for (int k = 0; k < NB; k++) { bn[k] = target(&pool, 103121 + k, (40 << 20) + ((int64_t)(16 + k) << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&bn[k])); }
        }
        submissions(); due(1041, 6);
        CHECK(g_tu_press_n == p1 + (press ? NB : 0), "the 12 go at low headroom");
        @autoreleasepool { at(1046); for (int k = 0; k < 8; k++) drawn(tex_mtl(&b[k])); }
        CHECK(g_tu_remade == m0 + (press ? 8 : 0) && g_tu_press_quick == q0 + (press ? 8 : 0), "8 made again within 10 s of their release, counted");
        due(1047, 6);
        CHECK(g_tu_shift == press && tu_press_wait(1047, 0) == (press ? 2 * TU_PRESS_IDLE : TU_PRESS_IDLE) && tu_press_wait(1047, 1) == TU_PRESS_IDLE,
              "8 of 12 made again (a quarter would do): the low-headroom wait doubles to 600 ms; a memory warning's stays 300 ms");
        @autoreleasepool { at(1048); c = target(&pool, 103201, (40 << 20) + (30 << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&c)); at(1049); cn = target(&pool, 103202, (40 << 20) + (30 << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&cn)); }
        submissions(); due(1053, 6);
        CHECK(shared(tex_get(c.serial)), "backed off, a target unused 500 ms stays");
        due(1056, 6);
        CHECK(shared(tex_get(c.serial)) != press, press ? "unused 800 ms (over 600) it goes" : "=0: it stays");
        uint64_t q1 = g_tu_press_quick;
        @autoreleasepool { at(1167); drawn(tex_mtl(&c)); }
        CHECK(g_tu_press_quick == q1, "made again 11 s after its release: not counted for the back-off");
        headroom(2600); due(1168, 6);
        CHECK(!g_tu_low && g_tu_shift == 0, "the headroom recovers: the back-off comes down a step");
        // A memory warning: a pass at 300 ms at once in the trim, whatever the headroom and the back-off. W: drawn over, unused 500 ms
        @autoreleasepool { at(1171); w = target(&pool, 103301, (40 << 20) + (31 << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&w)); at(1172); wn = target(&pool, 103302, (40 << 20) + (31 << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&wn)); }
        headroom(4096); submissions(); due(1176, 6); g_tu_shift = 2;
        CHECK(shared(tex_get(w.serial)) && !g_tu_low, "4 GB of headroom: W stays");
        uint64_t pw = g_tu_press_n, l1 = g_tu_press_lines, tb = atomic_load(&g_trim_bytes);
        CHECK(mtl_pressure(2), "a critical warning asks for a trim");
        mtl_sub_commit(); mtl_drain(); mtl_sub_begin();   // the trim at the next submission's start (mtl_trim_at)
        g_tu_shift = 0;
        CHECK(shared(tex_get(w.serial)) != press && (press ? g_tu_press_n > pw : g_tu_press_n == pw), press ? "the warning's pass releases it, before the other classes" : "=0: the warning releases no target");
        CHECK(!press || ((g_tu_pend.why & 2) && atomic_load(&g_trim_bytes) >= tb + 64 * 64 * 4), "counted in the trim's bytes, its line pending");
        due(1177, 6); CHECK(g_tu_press_lines == l1, "no line before the GPU is done with it and a second has passed");
        settle(); settle(); due(1187, 6);
        CHECK(g_tu_press_lines == l1 + press && !g_tu_pend.n, "then one line, with the headroom and footprint before and after");
        CHECK(g_tu_press_lines >= l0 + (press ? 4 : 0), "each group of releases had its line");
        // The back-off over more than one window: a step weighs the pressure releases since the last step (or the low spell's start) and the remakes of those alone. X: 40 released,
        // 10 made again: a step. Y: 10 released after it; then 20 more of X made again, which count in no window (they once made a second step, `20 of 10 textures … made again`);
        // then 8 of Y: the second step. A low spell's start begins a window too: Z, released in the next spell, while 12 of the last spell's come back in it, takes no step. Each
        // step and each spell's end says no more made again than released. Made again by a lookup, not drawn into, so nothing they cover goes in turn
        enum { NX = 40, NY = 10, NZ = 4 };
        static tex_t x[NX], xn[NX], y[NY], yn[NY], z[NZ], zn[NZ];
        uint64_t p2 = g_tu_press_n, q2 = g_tu_press_quick;
        capture();
        headroom(1900); due(1200, 6);
        @autoreleasepool {
            at(1201); for (int k = 0; k < NX; k++) { x[k] = target(&pool, 104001 + k, (42 << 20) + ((int64_t)k << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&x[k])); }
            at(1202); for (int k = 0; k < NX; k++) { xn[k] = target(&pool, 104101 + k, (42 << 20) + ((int64_t)k << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&xn[k])); }
        }
        submissions(); g_fr = f0 + 200000; due(1206, 6);   // (far past the last window line: this pass prints one)
        CHECK(g_tu_press_n == p2 + (press ? NX : 0) && g_tu_shift == 0, "X: 40 go at low headroom");
        @autoreleasepool { at(1210); for (int k = 0; k < 10; k++) tex_mtl(&x[k]); }
        due(1211, 6);
        CHECK(g_tu_shift == press, "10 of the 40 made again: a step (600 ms)");
        @autoreleasepool {
            at(1212); for (int k = 0; k < NY; k++) { y[k] = target(&pool, 104201 + k, (45 << 20) + ((int64_t)k << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&y[k])); }
            at(1213); for (int k = 0; k < NY; k++) { yn[k] = target(&pool, 104301 + k, (45 << 20) + ((int64_t)k << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&yn[k])); }
        }
        submissions(); due(1220, 6);
        CHECK(g_tu_press_n == p2 + (press ? NX + NY : 0), "Y: 10 go after the step, unused 700 ms");
        @autoreleasepool { at(1221); for (int k = 10; k < 30; k++) tex_mtl(&x[k]); }
        CHECK(g_tu_press_quick == q2 + (press ? 30 : 0), "20 more of X made again within 10 s of their release");
        due(1222, 6);
        CHECK(g_tu_shift == press, "released before the step, they count toward no window: no second step");
        @autoreleasepool { at(1223); for (int k = 0; k < 8; k++) tex_mtl(&y[k]); }
        due(1224, 6);
        CHECK(g_tu_shift == 2 * press, "8 of the 10 released since the step made again: the second step (1.2 s)");
        headroom(2600); due(1225, 6);
        CHECK(!g_tu_low && g_tu_shift == press, "the spell ends a step down");
        headroom(1900); due(1226, 6);
        CHECK(g_tu_low == press, "and another begins");
        @autoreleasepool { at(1227); for (int k = 30; k < NX; k++) tex_mtl(&x[k]); tex_mtl(&y[8]); tex_mtl(&y[9]); }   // the last spell's, within 10 s of their release
        @autoreleasepool {
            at(1228); for (int k = 0; k < NZ; k++) { z[k] = target(&pool, 104401 + k, (46 << 20) + ((int64_t)k << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&z[k])); }
            at(1229); for (int k = 0; k < NZ; k++) { zn[k] = target(&pool, 104501 + k, (46 << 20) + ((int64_t)k << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&zn[k])); }
        }
        submissions(); due(1235, 6);
        CHECK(g_tu_press_n == p2 + (press ? NX + NY + NZ : 0), "Z: 4 go in the new spell, unused 700 ms");
        due(1236, 6);
        CHECK(g_tu_shift == press, "12 of the last spell's made again in this one: no step on 4 released in it");
        headroom(2600); due(1237, 6);
        CHECK(!g_tu_low && g_tu_shift == 0, "the spell ends a step down");
        captured();
        int steps = 0, ends = 0;
        CHECK(remakes_within_releases(g_log, &steps, &ends), "no back-off step or spell's end says more made again than released");
        CHECK(steps == 2 * press && ends == 2 * press, "two steps and two spell ends were logged");
        {   // The window's line: its pressure releases went after a shorter wait than the usual one its head gives
            char wl[2048]; const char *l = line_with(g_log, "released early up to frame", wl, sizeof wl);
            CHECK(!press || (l && strstr(l, "unused for 3.0 s (0.3 to 0.6 s at memory pressure), released early") && strstr(l, "released sooner at memory pressure")),
                  "a window with pressure releases gives their waits beside the usual one");
            CHECK(press || !l || !strstr(l, "memory pressure"), "=0: the window's line names no memory pressure");
        }
        // A resolution family a pressure pass releases (F: its sizes 64 and 48, a target of another format over both) and a target in a recycled heap of its own (S): their heaps,
        // freed with them (NvImageHeap and NvRecycledHeap drop), stay alive and resident while the GPU still runs a submission committed before the release (held by a shared event),
        // and are freed, not left waiting for reuse, once it completes
        static tex_t fa64, fa48, fao, sg, sgn;
        __weak id<MTLHeap> fh, sh; __weak id<MTLTexture> w64, w48, ws;
        @autoreleasepool {
            at(1240);
            fa64 = target(&pool, 105001, 47 << 20, NVN_FORMAT_RGBA8, 64); fa48 = target(&pool, 105002, 47 << 20, NVN_FORMAT_RGBA8, 48); fao = target(&pool, 105003, 47 << 20, NVN_FORMAT_R32F, 64);
            sg = target(&pool, 105011, (47 << 20) + (4 << 16), NVN_FORMAT_RGBA8, 64); sgn = target(&pool, 105012, (47 << 20) + (4 << 16), NVN_FORMAT_R32F, 64);
            id<MTLTexture> t64 = tex_mtl(&fa64); drawn(t64);
            at(1241); id<MTLTexture> t48 = tex_mtl(&fa48); drawn(t48); id<MTLTexture> ts = tex_mtl(&sg); drawn(ts);
            at(1242); drawn(tex_mtl(&fao)); drawn(tex_mtl(&sgn));
            CHECK(t64.heap && t64.heap == t48.heap && objc_getAssociatedObject(t64, &g_image_heap_owner_key), "F is a resolution family with one heap");
            CHECK(ts.heap && ts.heap != t64.heap && objc_getAssociatedObject(ts, &g_rh_owner_key), "S is in a recycled heap of its own");
            fh = t64.heap; sh = ts.heap; w64 = t64; w48 = t48; ws = ts;
        }
        submissions();   // past ALIAS_IDLE
        id<MTLSharedEvent> gate = [g_dev newSharedEvent];
        rec_drain(); [g_q4 waitForEvent:gate value:1];   // nothing committed from here runs until the gate opens
        uint64_t held = mtl_sub_commit(); mtl_sub_begin();
        uint64_t fn1 = g_tu_fam_n;
        headroom(1900); due(1246, 6);
        @autoreleasepool {
            CHECK(shared(w64) == !press && shared(w48) == !press && shared(ws) == !press, press ? "low: F goes whole and S goes, unused 500 ms" : "=0: they stay");
            CHECK(g_tu_fam_n == fn1 + press, "F counted as a whole family");
            for (int k = 0; k < 3; k++) { defer_drain(); res_commit(); }
            CHECK(held > atomic_load(&g_done), "the submission before the release is still held");
            CHECK(fh && resident(fh) && !rh_waits(fh), "F's heap stays alive and resident while the GPU may still use it");
            CHECK(sh && resident(sh) && !rh_waits(sh), "and so does S's");
        }
        gate.signaledValue = 1;   // release the GPU before any check can stop the test
        CHECK(mtl_wait(held, 5000000000ull), "the held submission completes once the gate opens");
        settle();
        @autoreleasepool {
            CHECK(press ? !w64 && !w48 && !ws : shared(w64) && shared(ws), press ? "past the fence F's textures and S are freed" : "=0: they are still shared");
            CHECK(press ? !fh && !sh : fh && sh && resident(fh), press ? "and their heaps freed, not waiting for reuse" : "=0: their heaps too");
        }
        headroom(2600); due(1250, 6);
        CHECK(!g_tu_low, "the headroom recovers");
        {   // DM_NVN_RT_DEAD_PRESSURE=ab (with DM_AB): the low spell is followed in every phase, and a target drawn over goes at the pressure wait, or at a warning, only in the phases
            // it is on. A: drawn over and unused 500 ms, then 700 ms
            int m0 = g_tu_press_mode; long len0 = g_ab_len, ph0 = atomic_load(&g_ab_phase);
            g_ab_len = 4; g_tu_press_mode = sw_mode_of("DM_NVN_RT_DEAD_PRESSURE", "ab", 1);
            CHECK(g_tu_press_mode >= 2 && !sw_on_at(g_tu_press_mode, 0) && sw_on_at(g_tu_press_mode, 1), "ab: off in phase 0, on in phase 1");
            static tex_t ab, abn;
            @autoreleasepool { at(1260); ab = target(&pool, 106001, (47 << 20) + (8 << 16), NVN_FORMAT_RGBA8, 64); drawn(tex_mtl(&ab)); at(1261); abn = target(&pool, 106002, (47 << 20) + (8 << 16), NVN_FORMAT_R32F, 64); drawn(tex_mtl(&abn)); }
            submissions();
            uint64_t pa = g_tu_press_n;
            atomic_store(&g_ab_phase, 0); headroom(1900); due(1265, 6);
            CHECK(g_tu_low && shared(tex_get(ab.serial)) && g_tu_press_n == pa, "phase 0: the spell begins, and A, unused 500 ms, stays at the usual wait");
            CHECK(!tu_press_warning().n && shared(tex_get(ab.serial)), "phase 0: a warning's pass releases nothing");
            atomic_store(&g_ab_phase, 1); due(1267, 6);
            CHECK(!shared(tex_get(ab.serial)) && g_tu_press_n == pa + (press ? 1 : 4), "phase 1: it goes at the pressure wait (with =0, F and S too, which the usual wait kept)");
            headroom(2600); due(1268, 6);
            CHECK(!g_tu_low, "and the spell ends");
            mtl_tex_release(&ab); mtl_tex_release(&abn);
            g_tu_press_mode = m0; g_ab_len = len0; atomic_store(&g_ab_phase, ph0);
        }
        for (int k = 0; k < NX; k++) { mtl_tex_release(&x[k]); mtl_tex_release(&xn[k]); }
        for (int k = 0; k < NY; k++) { mtl_tex_release(&y[k]); mtl_tex_release(&yn[k]); }
        for (int k = 0; k < NZ; k++) { mtl_tex_release(&z[k]); mtl_tex_release(&zn[k]); }
        mtl_tex_release(&fa64); mtl_tex_release(&fa48); mtl_tex_release(&fao); mtl_tex_release(&sg); mtl_tex_release(&sgn);
        for (int k = 0; k < NOLD; k++) { mtl_tex_release(&o[k]); mtl_tex_release(&n[k]); }
        for (int k = 0; k < NB; k++) { mtl_tex_release(&b[k]); mtl_tex_release(&bn[k]); }
        mtl_tex_release(&r); mtl_tex_release(&rn); mtl_tex_release(&sx); mtl_tex_release(&sn); mtl_tex_release(&c); mtl_tex_release(&cn); mtl_tex_release(&w); mtl_tex_release(&wn);
        g_rh_avail = NULL; g_tu_low = 0; g_tu_hr_at = 0; atomic_store(&g_cur_frame, f0);
    }
    {   // Many resolution families (Luigi's Mansion 3's dynamic resolution in 1-pixel steps: about 14 scaling targets, every size visited kept as a member). NF families of NM sizes at
        // one offset each, the largest read every frame: every other size is drawn over by it and kept. The pass asks each family's member in use, not all its members (the asks are
        // counted, g_tu_asked), and what it releases is what the old rule releases (old_rule: every member asked). Then families 0-3 go unused and a target of another format draws
        // over them (they go whole), family 4 has a size pinned (it stays: its pinned size is asked first from then on), family 5 its size in use pinned; the rest stay in use
        enum { NF = 14, NM = 300 }; static tex_t fm[NF][NM], fo[6];
        void *mem2 = NULL; posix_memalign(&mem2, 16384, 64 << 20); memset(mem2, 0, 64 << 20);
        static pool_t pool2; pool2 = (pool_t){.magic = MAGIC('P','O','O','L'), .flags = pool.flags, .mem = mem2, .size = 64 << 20};
        at(2000);
        for (int f = 0; f < NF; f++) for (int m = 0; m < NM; m++) fm[f][m] = target(&pool2, 200000 + f * 1000 + m, (int64_t)f << 22, NVN_FORMAT_RGBA8, 64 + m);   // every size declared first: the heap fits the largest
        for (int f = 0; f < NF; f++) for (int m = 0; m < NM - 1; m++) @autoreleasepool { drawn(tex_mtl(&fm[f][m])); }
        at(2001); for (int f = 0; f < NF; f++) @autoreleasepool { drawn(tex_mtl(&fm[f][NM - 1])); }   // the size in use, drawing over the rest
        int one = 1; @autoreleasepool { for (int f = 0; f < NF; f++) { id own = objc_getAssociatedObject(tex_get(fm[f][0].serial), &g_image_heap_owner_key);
            for (int m = 1; m < NM; m++) one &= objc_getAssociatedObject(tex_get(fm[f][m].serial), &g_image_heap_owner_key) == own; one &= own != nil; } }
        CHECK(one, "each family's sizes share one heap");
        submissions();
        uint64_t ns0 = g_tu_ns, p0 = g_tu_passes, n0 = g_tu_n; int same = 1; uint64_t asked = 0;
        for (uint32_t now = 2040; now <= 2080; now += 10) {
            @autoreleasepool { at(now); for (int f = 0; f < NF; f++) tex_mtl(&fm[f][NM - 1]); }
            same &= pass_as_old_rule(now);
            uint64_t a = g_tu_asked - covered_alone(); asked = asked > a ? asked : a;
        }
        double ms = (g_tu_ns - ns0) / 1e6 / (double)(g_tu_passes - p0);
        printf("a pass over %u covered targets, %d families of %d sizes in use: %.3f ms, %llu family members asked at most\n", g_tu.n, NF, NM, ms, (unsigned long long)asked);
        CHECK(same && g_tu_n == n0, "families in use: nothing goes, as by the old rule");
        CHECK(g_tu_fam_kept_now >= NF * (NM - 1), "every size but the one in use is kept");
        CHECK(asked <= 2 * NF, "a pass asks each family's size in use, not all its sizes");
        // families 0-5 go unused; another format draws over them; 4's size 7 and 5's size in use are pinned
        at(2090); @autoreleasepool { for (int f = 6; f < NF; f++) tex_mtl(&fm[f][NM - 1]);
            for (int f = 0; f < 6; f++) { fo[f] = target(&pool2, 300000 + f, (int64_t)f << 22, NVN_FORMAT_R32F, 512); drawn(tex_mtl(&fo[f])); } }
        mtl_tex_pin(fm[4][7].serial); mtl_tex_pin(fm[5][NM - 1].serial);
        submissions();
        uint64_t fn0 = g_tu_fam_n;
        for (uint32_t now = 2130; now <= 2150; now += 10) {
            @autoreleasepool { at(now); for (int f = 6; f < NF; f++) tex_mtl(&fm[f][NM - 1]); }
            same &= pass_as_old_rule(now);
        }
        int gone = 1, stay = 1;
        @autoreleasepool { for (int f = 0; f < NF; f++) for (int m = 0; m < NM; m++) { int s = tex_get(fm[f][m].serial) != nil; if (f < 4) gone &= !s; else stay &= s; } }
        CHECK(same && gone && stay && g_tu_fam_n == fn0 + 4, "families unused and drawn over go whole, a pinned size keeps its family, as by the old rule");
        CHECK(g_tu_asked - covered_alone() <= 2 * NF, "a family kept by a pinned size is asked that size first");
        mtl_tex_unpin(fm[4][7].serial); mtl_tex_unpin(fm[5][NM - 1].serial);
        submissions();
        for (uint32_t now = 2160; now <= 2170; now += 10) { @autoreleasepool { at(now); for (int f = 6; f < NF; f++) tex_mtl(&fm[f][NM - 1]); } same &= pass_as_old_rule(now); }
        @autoreleasepool { gone = !tex_get(fm[4][7].serial) && !tex_get(fm[5][NM - 1].serial) && !tex_get(fm[4][0].serial); }
        CHECK(same && gone && g_tu_fam_n == fn0 + 6, "unpinned, they go whole too");
        // family 6's size in use (the member asked first) leaves the table, as a pool's Finalize or a takeover takes it: the pass asks another member, nothing dangles, as by the old rule
        @autoreleasepool { alias_drop(tex_get(fm[6][NM - 1].serial)); }
        settle(); submissions();
        for (uint32_t now = 2180; now <= 2190; now += 10) { @autoreleasepool { at(now); for (int f = 7; f < NF; f++) tex_mtl(&fm[f][NM - 1]); } same &= pass_as_old_rule(now); }
        CHECK(same && g_tu_asked - covered_alone() <= 2 * NF, "a family whose member asked first left the table is asked another, as by the old rule");
        for (int f = 0; f < NF; f++) for (int m = 0; m < NM; m++) mtl_tex_release(&fm[f][m]);
        for (int f = 0; f < 6; f++) mtl_tex_release(&fo[f]);
    }
    {   // DM_NVN_RT_DEAD_MS: the wait, and a pass every quarter of it (100 ms to 1 s)
        static const struct { const char *ms; uint32_t idle, every; } cs[] = {{"1000", 10, 2}, {"3000", 30, 7}, {"20", 1, 1}, {"60000", 600, 10}};
        g_tu_manual = 0;
        for (unsigned k = 0; k < sizeof cs / sizeof cs[0]; k++) { setenv("DM_NVN_RT_DEAD_MS", cs[k].ms, 1); g_tu_idle = 0; tu_tick(); CHECK(g_tu_idle == cs[k].idle && g_tu_every == cs[k].every, cs[k].ms); }
        unsetenv("DM_NVN_RT_DEAD_MS"); g_tu_idle = 0; tu_tick(); CHECK(g_tu_idle == 30, "the default wait is 3 s");
        g_tu_manual = 1;
    }
    }
    mtl_tex_release(&a); mtl_tex_release(&b); mtl_tex_release(&c); mtl_tex_release(&d); mtl_tex_release(&e); mtl_tex_release(&f); mtl_tex_release(&g); mtl_tex_release(&h); mtl_tex_release(&i);
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "no GPU error");
    printf("t_dead_targets%s: %d checks, %d failed\n", off ? " --off" : "", checks, failed); return failed != 0;
} }
