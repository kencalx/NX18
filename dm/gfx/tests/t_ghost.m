// The finalized-texture table (g_ghost, tex_put): its ceiling decided once (ghost_cap: 512 by default, the profile's ghost_table, DM_NVN_GHOST held to 64..8192) and logged at the start,
// the table holding that many with the least recently used going first, and the counts of the table's 300-frame line (mtl_ghost_stat): puts, evictions, and puts of a serial the table
// pushed out in the last 4 frames (thrash), the patch time less the misses inside it, and a memory trim taking a larger table back to 512 (ghost_trim). Ocarina of Time put about 800 textures a frame into 512 in one area on an iPhone, most of them pushed out a frame or two before.
// Kept by use (Ocarina of Time test 3: a ring of 4096 that had filled kept about 2,200 textures resident, and the headroom to the memory limit fell to 2.3 GB): an entry looked up
// again is the youngest (lru), what a submission in flight used is never let go below twice the ceiling (in_flight), idle entries drain back to 512 at each commit, by frames or by
// submissions (idle_drain), low headroom takes the table to 512 at once (low_headroom), and the line counts the drained and the dropped
// --expect <n>: the size the run's DM_NVN_GHOST should give (without it: the profile's)
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
// What fn writes to stderr (MLOG), the lines holding key joined into out
typedef void (^logged_fn)(void);
static int logged(char *out, size_t cap, const char *key, logged_fn fn) {
    char path[] = "/tmp/t_ghost.XXXXXX"; int fd = mkstemp(path); if (fd < 0) return 0;
    fflush(stderr); int saved = dup(2); if (saved < 0) { unlink(path); close(fd); return 0; }
    dup2(fd, 2); fn(); fflush(stderr); dup2(saved, 2); close(saved);
    FILE *f = fopen(path, "r"); unlink(path); close(fd); if (!f) return 0;
    char line[4096]; int got = 0; *out = 0;
    while (fgets(line, sizeof line, f)) if (strstr(line, key)) { strlcat(out, line, cap); got++; }
    fclose(f); return got;
}
static unsigned held(void) { pthread_mutex_lock(&g_smu); unsigned n = g_ghost.n; pthread_mutex_unlock(&g_smu); return n; }
static int resolves(uint64_t k) { return tex_get(k) != nil; }   // a lookup: the entry becomes the youngest
static int has(uint64_t k) { pthread_mutex_lock(&g_smu); int r = nvn_hm_get(&g_ghost, &k) != NULL; pthread_mutex_unlock(&g_smu); return r; }   // without a use
// Empty the table as evictions would, and give it another ceiling (a test only: the host decides it once)
static void ghost_reset(unsigned cap) {
    pthread_mutex_lock(&g_smu);
    while (g_ghost_lru) ghost_evict(g_ghost_lru->serial);
    g_ghost_cap = cap; memset(g_ghost_gone_ser, 0, sizeof g_ghost_gone_ser);
    pthread_mutex_unlock(&g_smu);
}
static uint64_t g_next = 1ull << 61;   // serials no texture object owns (not in g_tex_live) and below 2^62: they go to the ghost table
static void put(uint64_t k) { @autoreleasepool { tex_put(k, [NSObject new]); } }
static void frame(uint64_t f) { atomic_store(&g_cur_frame, f); }
static void settle(void) { g_fence++; pthread_mutex_lock(&g_mu); g_done = g_fence; pthread_mutex_unlock(&g_mu); defer_drain(); }   // a submission ended and the GPU passed every fence
// The list agrees with the table: one place per ghost serial and one serial per place, links both ways, uses from oldest to newest (the walks stop at the first entry in use)
static int list_ok(const char **why) {
    pthread_mutex_lock(&g_smu); unsigned places = 0; const ghost_use *prev = NULL; *why = NULL;
    for (const ghost_use *u = g_ghost_lru; u && !*why; prev = u, u = u->next) {
        if (++places > g_ghost_use.n) *why = "a list longer than its records (a cycle)";
        else if (u->prev != prev) *why = "a back link is wrong";
        else if (nvn_hm_get(&g_ghost_use, &u->serial) != u) *why = "a record is not the one its table names";
        else if (!nvn_hm_get(&g_ghost, &u->serial)) *why = "a place with no ghost entry";
        else if (prev && (u->frame < prev->frame || u->sub < prev->sub)) *why = "used before the one ahead of it";
    }
    if (!*why && prev != g_ghost_mru) *why = "the list does not end at its youngest";
    if (!*why && (places != g_ghost.n || g_ghost_use.n != g_ghost.n)) *why = "places, records and ghost serials differ";
    pthread_mutex_unlock(&g_smu); return !*why;
}
#define LIST_OK(label) do { const char *why_; char m_[160]; int ok_ = list_ok(&why_); snprintf(m_, sizeof m_, "%s: %s", label, why_ ? why_ : "the list agrees"); CHECK(ok_, m_); } while (0)

static void pick(void) {   // the decision itself, every source
    const char *why;
    CHECK(ghost_cap_pick(NULL, NGHOST_DEF, &why) == 512 && !strcmp(why, "the default"), "no key, no switch: 512, the default");
    CHECK(ghost_cap_pick("", NGHOST_DEF, &why) == 512 && !strcmp(why, "the default"), "an empty DM_NVN_GHOST is unset");
    CHECK(ghost_cap_pick(NULL, 4096, &why) == 4096 && !strcmp(why, "game profile ghost_table"), "the profile's 4096 (Ocarina of Time)");
    CHECK(ghost_cap_pick("1000", 4096, &why) == 1000 && !strcmp(why, "DM_NVN_GHOST"), "DM_NVN_GHOST overrides the profile");
    CHECK(ghost_cap_pick("512", 4096, &why) == 512 && !strcmp(why, "DM_NVN_GHOST"), "DM_NVN_GHOST=512 takes a profile back to the default");
    CHECK(ghost_cap_pick("20", NGHOST_DEF, &why) == 64 && !strcmp(why, "DM_NVN_GHOST, held to 64 to 8192"), "below 64: 64");
    CHECK(ghost_cap_pick("-5", NGHOST_DEF, &why) == 64, "a negative number: 64");
    CHECK(ghost_cap_pick("100000", NGHOST_DEF, &why) == 8192 && !strcmp(why, "DM_NVN_GHOST, held to 64 to 8192"), "above 8192: 8192");
    CHECK(ghost_cap_pick("64", NGHOST_DEF, &why) == 64 && ghost_cap_pick("8192", NGHOST_DEF, &why) == 8192 && !strcmp(why, "DM_NVN_GHOST"), "64 and 8192 themselves");
    CHECK(ghost_cap_pick("junk", 4096, &why) == 4096 && !strcmp(why, "DM_NVN_GHOST is not a number, so game profile ghost_table"), "not a number: the profile's");
    CHECK(ghost_cap_pick("12x", NGHOST_DEF, &why) == 512 && !strcmp(why, "DM_NVN_GHOST is not a number, so the default"), "a number with more after it is not a number");
}

// The table holds cap serials, the least recently used going first; puts and evictions counted
static void ring(unsigned cap) {
    ghost_reset(cap); frame(1000);
    uint64_t base = g_next, puts0 = g_ghost_puts, ev0 = g_ghost_evicted;
    for (unsigned i = 0; i < cap; i++) put(base + i);
    CHECK(held() == cap && g_ghost_evicted == ev0, "a full table holds every one put");
    settle();   // their submission completed: none is in use
    for (unsigned i = 0; i < 100; i++) { put(base + cap + i); settle(); }   // each in a submission of its own, completed: with a ceiling under 100 the table would otherwise grow past it
    int first_gone = 1, kept = 1; for (unsigned i = 0; i < 100; i++) first_gone &= !resolves(base + i);
    for (unsigned i = 100; i < cap + 100; i++) kept &= resolves(base + i);
    char m[96]; snprintf(m, sizeof m, "%u: the table holds %u, the 100 oldest gone", cap, cap);
    CHECK(held() == cap && first_gone && kept, m);
    CHECK(g_ghost_puts - puts0 == cap + 100 && g_ghost_evicted - ev0 == 100, "puts and evictions counted");
    put(base + cap + 99);   // a serial still held, put again: replaced, not another entry
    CHECK(held() == cap && g_ghost_puts - puts0 == cap + 100 && g_ghost_evicted - ev0 == 100, "a serial put again while held is no new put");
    LIST_OK("ring");
    g_next = base + cap + 100;
}

// A put of a serial the table pushed out in the last 4 frames is thrash; older ones and new serials are not
static void thrash(void) {
    ghost_reset(64); uint64_t base = g_next; frame(2000);
    for (unsigned i = 0; i < 64; i++) put(base + i);
    settle(); for (unsigned i = 64; i < 64 + 8; i++) put(base + i);   // 8 pushed out at frame 2000
    uint64_t th0 = g_ghost_thrash;
    frame(2003); put(base + 0); put(base + 1);   // 3 frames later: wanted again
    CHECK(g_ghost_thrash - th0 == 2, "two puts of serials pushed out 3 frames before: thrash");
    frame(2004); put(base + 2);   // 4 frames later: outside the window
    CHECK(g_ghost_thrash - th0 == 2, "a serial pushed out 4 frames before: no thrash");
    put(base + 1000);   // never in the table
    CHECK(g_ghost_thrash - th0 == 2, "a new serial: no thrash");
    put(base + 0);   // still held (put again at 2003): no new put
    CHECK(g_ghost_thrash - th0 == 2, "a serial still held: no thrash");
    // The puts since pushed out base + 8 and + 9 at frame 2003 (+ 10 and + 11 at 2004): wanted again a frame later
    uint64_t ev = g_ghost_evicted; put(base + 8); put(base + 9);
    CHECK(g_ghost_thrash - th0 == 4 && g_ghost_evicted - ev == 2, "pushed out and wanted a frame later: thrash");
    put(base + 8);   // counted once: it is held again
    CHECK(g_ghost_thrash - th0 == 4, "a thrash put is counted once");
    g_next = base + 2000;
    // A put whose own eviction is of a serial in the same slot of the evicted record (8,192 apart): the put's serial is looked up before that eviction takes the slot
    ghost_reset(64); base = g_next; frame(2100);
    put(base); put(base + GHOST_GONE); for (unsigned i = 1; i <= 62; i++) put(base + i);   // base the least recently used, base + 8192 the next
    settle(); put(base + 63);   // pushes base out
    th0 = g_ghost_thrash; frame(2101); put(base);   // wanted again: its put pushes out base + 8192, whose record takes base's slot
    CHECK(g_ghost_thrash - th0 == 1 && !resolves(base + GHOST_GONE), "thrash counted when the put's own eviction shares the serial's record slot");
    LIST_OK("thrash");
    g_next = base + 2 * GHOST_GONE;
}

// A memory trim takes a table above the default's size back down to it, the least recently used first, and leaves what a submission in flight used
static void trim(void) {
    ghost_reset(4096); uint64_t base = g_next, ev0, puts0; frame(2500);
    for (unsigned i = 0; i < 3000; i++) put(base + i);
    CHECK(ghost_trim() == 0 && held() == 3000, "every entry in use by the submission in flight: the trim lets none go");
    settle(); ev0 = g_ghost_evicted;
    unsigned n = ghost_trim();
    int gone = 1, kept = 1; for (unsigned i = 0; i < 2488; i++) gone &= !has(base + i);
    for (unsigned i = 2488; i < 3000; i++) kept &= has(base + i);
    CHECK(n == 2488 && held() == 512 && gone && kept && g_ghost_evicted == ev0, "3000 held in 4096, trimmed to 512: the 2488 least recently used go, not counted as evictions");
    CHECK(ghost_trim() == 0 && held() == 512, "a table at 512 is not trimmed");
    g_next = base + 3000;
    ghost_reset(1000); base = g_next;
    for (unsigned i = 0; i < 1000; i++) put(base + i);
    settle(); for (unsigned i = 1000; i < 1500; i++) put(base + i);   // full: base + 500 is the least recently used
    settle(); n = ghost_trim();
    gone = 1; kept = 1; for (unsigned i = 0; i < 988; i++) gone &= !has(base + i);
    for (unsigned i = 988; i < 1500; i++) kept &= has(base + i);
    CHECK(n == 488 && held() == 512 && gone && kept, "a full table trimmed from its least recently used");
    ev0 = g_ghost_evicted; puts0 = g_ghost_puts;
    for (unsigned i = 0; i < 488; i++) put(base + 1500 + i);
    CHECK(held() == 1000 && g_ghost_evicted == ev0, "the table fills to its ceiling again without an eviction");
    settle(); put(base + 1988);
    CHECK(g_ghost_evicted - ev0 == 1 && !has(base + 988) && has(base + 989) && g_ghost_puts - puts0 == 489, "then the least recently used goes first again");
    g_next = base + 2000;
    // Through the memory trim itself: a warning trims, back to normal does not
    ghost_reset(4096); base = g_next;
    for (unsigned i = 0; i < 1000; i++) put(base + i);
    settle();
    char out[8192];
    logged(out, sizeof out, "memory trim", ^{ mtl_trim(0); });
    CHECK(held() == 1000 && strstr(out, "finalized-texture table entries 0 (down to 512)"), "pressure back to normal: the table stays");
    logged(out, sizeof out, "memory trim", ^{ mtl_trim(1); });
    printf("%s", out);
    CHECK(held() == 512 && strstr(out, "finalized-texture table entries 488 (down to 512)"), "a pressure warning: down to 512, in the trim's line");
    LIST_OK("trim");
    g_next = base + 1000;
}

// Least recently used: an entry looked up again (tex_get, a pin) is the youngest, and a full table lets the oldest unused one go instead
static void lru(void) {
    ghost_reset(64); uint64_t base = g_next; frame(2700);
    for (unsigned i = 0; i < 64; i++) put(base + i);
    settle();
    CHECK(resolves(base + 0), "the oldest looked up again");
    mtl_tex_pin(base + 2); mtl_tex_unpin(base + 2);   // the third pinned: a use too
    settle(); uint64_t ev0 = g_ghost_evicted;
    put(base + 64); put(base + 65);
    CHECK(has(base + 0) && has(base + 2) && !has(base + 1) && !has(base + 3) && g_ghost_evicted - ev0 == 2, "a full table: the entries not used again go, the ones looked up and pinned stay");
    for (unsigned i = 0; i < 60; i++) put(base + 66 + i);   // 60 more: the 60 entries of the first put not used again go
    CHECK(has(base + 0) && has(base + 2) && !has(base + 63) && held() == 64, "used entries outlast the 60 others of the first put");
    put(base + 126);
    CHECK(!has(base + 0) && has(base + 2), "then the one looked up first goes");
    put(base + 127);
    CHECK(!has(base + 2) && has(base + 64), "then the pinned one");
    LIST_OK("lru");
    g_next = base + 200;
}

// A submission in flight's entries stay: a full table goes past its ceiling rather than let them go, up to twice it; once the GPU passes the fence the oldest goes again
static void in_flight(void) {
    ghost_reset(64); uint64_t base = g_next, ev0 = g_ghost_evicted; frame(2800);
    for (unsigned i = 0; i < 64; i++) put(base + i);
    for (unsigned i = 64; i < 128; i++) put(base + i);   // the same submission: nothing completed
    int all = 1; for (unsigned i = 0; i < 128; i++) all &= has(base + i);
    CHECK(held() == 128 && all && g_ghost_evicted == ev0, "every entry in use: the table goes past its ceiling of 64 to 128, none let go");
    put(base + 128);
    CHECK(held() == 128 && !has(base + 0) && g_ghost_evicted - ev0 == 1, "at twice the ceiling the oldest goes all the same");
    // Used in the submission before (committed, not completed): still in use
    g_fence++;   // that submission committed
    put(base + 129);
    CHECK(held() == 128 && !has(base + 1) && g_ghost_evicted - ev0 == 2, "a committed submission not completed: still past the ceiling, still bounded");
    settle();
    put(base + 130);
    CHECK(held() == 128 && !has(base + 2) && g_ghost_evicted - ev0 == 3, "once the GPU passed it, the oldest goes and the table stays where it is");
    pthread_mutex_lock(&g_smu); unsigned n = ghost_release(0, UINT_MAX, 0); pthread_mutex_unlock(&g_smu);
    CHECK(n == 127 && held() == 1 && has(base + 130), "a release to nothing stops at the entry the submission being encoded put");
    LIST_OK("in flight");
    g_next = base + 200;
}

// The idle drain at each commit: entries unused for 600 frames, or 16,384 submissions, go 32 a commit, least recently used first, back to 512; one used again stays
static void idle_drain(void) {
    ghost_reset(4096); uint64_t base = g_next, d0 = g_ghost_drained; frame(10000);
    for (unsigned i = 0; i < 2048; i++) put(base + i);
    settle();
    frame(10300); CHECK(resolves(base + 0), "one looked up again 300 frames later");
    settle();
    frame(10599); ghost_commit();
    CHECK(held() == 2048 && g_ghost_drained == d0, "599 frames: nothing idle, nothing drained");
    frame(10600); ghost_commit();
    CHECK(held() == 2048 - GHOST_DRAIN && g_ghost_drained - d0 == GHOST_DRAIN && !has(base + 1) && has(base + 0), "600 frames: 32 drained, least recently used first");
    int calls = 1; while (held() > 512 && calls < 100) { ghost_commit(); calls++; }
    CHECK(held() == 512 && calls == 48 && g_ghost_drained - d0 == 1536 && has(base + 0), "back to 512 in 48 commits; the one used again stays");
    ghost_commit(); CHECK(held() == 512, "512: no more drained");
    g_next = base + 2048;
    // Through a real submission's commit
    ghost_reset(4096); base = g_next; frame(20000);
    for (unsigned i = 0; i < 600; i++) put(base + i);
    settle(); frame(20600); d0 = g_ghost_drained;
    mtl_sub_begin(); CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "a submission committed and completed");
    CHECK(held() == 600 - GHOST_DRAIN && g_ghost_drained - d0 == GHOST_DRAIN, "mtl_sub_commit drains 32");
    g_next = base + 600;
    // Idle by submissions with the frame standing still (a stretch with no present)
    ghost_reset(4096); base = g_next; frame(30000);
    for (unsigned i = 0; i < 600; i++) put(base + i);
    settle(); d0 = g_ghost_drained;   // the submission that put them completed
    g_fence += GHOST_IDLE_SUBS - 2;   // the one being encoded is 16,383 after it
    ghost_commit(); CHECK(held() == 600, "16,383 submissions and no frame: not idle yet");
    settle(); ghost_commit();   // 16,384 after it
    CHECK(held() == 600 - GHOST_DRAIN && g_ghost_drained - d0 == GHOST_DRAIN, "16,384 submissions and no frame: idle, drained");
    // At or below the floor (a ceiling under 512 keeps its own): nothing
    ghost_reset(100); base = g_next + 1000;
    for (unsigned i = 0; i < 100; i++) put(base + i);
    settle(); frame(40000); d0 = g_ghost_drained; ghost_commit();
    CHECK(held() == 100 && g_ghost_drained == d0, "a ceiling of 100: its floor is 100, nothing drained");
    LIST_OK("idle drain");
    g_next = base + 100;
}

// Low headroom to the memory limit (iOS; the test gives one): above 512, everything no submission in flight uses goes at once, with a line; enough headroom changes nothing
static uint64_t g_fake_avail;
static uint64_t fake_avail(void) { return g_fake_avail; }
static void low_headroom(void) {
    ghost_reset(4096); uint64_t base = g_next, l0 = g_ghost_low, d0 = g_ghost_drained; frame(50000);
    for (unsigned i = 0; i < 1500; i++) put(base + i);
    settle(); g_rh_avail = fake_avail;
    g_fake_avail = 3200ull << 20; g_ghost_hr_at = 0; ghost_commit();
    CHECK(held() == 1500 && g_ghost_low == l0 && g_ghost_drained == d0, "3.2 GB of headroom and nothing idle: the table stays");
    g_fake_avail = 2900ull << 20; ghost_commit();
    CHECK(held() == 1500, "the headroom is read at most every 250 ms: the next commit at once does not see it");
    char out[4096]; g_ghost_hr_at = 0;
    int n = logged(out, sizeof out, "finalized-texture table: headroom", ^{ ghost_commit(); });
    printf("%s", out);
    CHECK(held() == 512 && g_ghost_low - l0 == 988 && has(base + 1499) && !has(base + 987), "2.9 GB: the 988 least recently used go at once, down to 512");
    CHECK(n == 1 && strstr(out, "headroom to the system memory limit 2900 MB, under 3072 MB: 988 entries let go at once, 512 held now (down to 512"), "one line for it");
    for (unsigned i = 0; i < 600; i++) put(base + 2000 + i);   // the submission being encoded puts 600 more
    g_ghost_hr_at = 0; ghost_commit();
    int kept = 1; for (unsigned i = 0; i < 600; i++) kept &= has(base + 2000 + i);
    CHECK(held() == 600 && kept && g_ghost_low - l0 == 1500, "what the submission in flight put stays; the 512 older go");
    g_rh_avail = NULL;
    LIST_OK("low headroom");
    g_next = base + 3000;
}

// The patch time leaves out the misses that put timed inside it (they are in the miss time), so the line's two figures add up; never below zero
static void patch_less_misses(void) {
    uint64_t q0 = atomic_load(&g_pool_patch_ticks), t0 = mach_absolute_time() - 100000, m0 = tl_ghost_miss_sum;
    tl_ghost_miss_sum += 40000; pool_patch_add(t0, m0);
    uint64_t d = atomic_load(&g_pool_patch_ticks) - q0, now = mach_absolute_time();
    CHECK(d >= 60000 && d <= now - t0 - 40000, "the patch path's time less the misses inside it");
    q0 = atomic_load(&g_pool_patch_ticks); t0 = mach_absolute_time(); m0 = tl_ghost_miss_sum;
    tl_ghost_miss_sum += 1000000000ull; pool_patch_add(t0, m0);
    CHECK(atomic_load(&g_pool_patch_ticks) == q0, "misses longer than the patch add nothing");
}

// The line: per frame since the last, quiet windows write none
static void line(void) {
    char out[8192];
    mtl_ghost_stat(3000);   // a baseline: what came before
    // The patch path and the epochs move in nearly every game's windows: without a put or an eviction they write no line
    atomic_fetch_add(&g_pool_patch_ticks, 1000000); atomic_fetch_add(&g_treg_ep_bumps, 3);
    CHECK(!logged(out, sizeof out, "finalized-texture table up to frame", ^{ mtl_ghost_stat(3300); }), "a window with no put or eviction writes no line, whatever the patch path and epochs did");
    ghost_reset(64); uint64_t base = g_next; frame(3301);
    for (unsigned i = 0; i < 64; i++) put(base + i);
    settle(); for (unsigned i = 64; i < 64 + 30; i++) put(base + i);   // 94 puts, 30 pushed out
    frame(3302); for (unsigned i = 0; i < 6; i++) put(base + i);   // 6 of them wanted again: 6 thrash, 6 more pushed out
    int n = logged(out, sizeof out, "finalized-texture table up to frame", ^{ mtl_ghost_stat(3600); });
    printf("%s", out);
    CHECK(n == 1, "one line for the window");
    CHECK(strstr(out, "up to frame 3600 (64 held, up to 64), per frame: 0.33 put, 0.02 of them pushed out in the last 4 frames, 0.12 pushed out;") != NULL, "per frame over 300 frames: 100 puts, 6 thrash, 36 evictions");
    CHECK(strstr(out, "ms in the texture misses that put") && strstr(out, "ms patching pool tables") && strstr(out, "texture ID epochs started"), "the costs and the epochs");
    CHECK(strstr(out, "; in the window 0 idle entries drained, 0 let go at low memory headroom") != NULL, "no drain in that window");
    g_next = base + 100;
    // A window with only a drain and a low-headroom drop writes a line, with their counts
    ghost_reset(4096); base = g_next; frame(3700);
    for (unsigned i = 0; i < 600; i++) put(base + i);
    settle(); mtl_ghost_stat(3800);   // the puts' window
    frame(4400); ghost_commit();   // 32 drained
    g_rh_avail = fake_avail; g_fake_avail = 1ull << 30; g_ghost_hr_at = 0; ghost_commit(); g_rh_avail = NULL;   // the other 56 above 512 at once
    n = logged(out, sizeof out, "finalized-texture table up to frame", ^{ mtl_ghost_stat(4500); });
    printf("%s", out);
    CHECK(n == 1 && strstr(out, "0.00 put, 0.00 of them pushed out in the last 4 frames, 0.00 pushed out;") && strstr(out, "; in the window 32 idle entries drained, 56 let go at low memory headroom"),
          "a window with a drain and a drop and no put: a line with their counts");
    g_next = base + 600;
}

int main(int argc, const char **argv) { @autoreleasepool {
    long expect = argc > 2 && !strcmp(argv[1], "--expect") ? atol(argv[2]) : DM_GAME_GHOST_TABLE;
    char out[8192];
    int n = logged(out, sizeof out, "finalized-texture table:", ^{ mtl_init(); });
    printf("%s", out);
    char want[96]; snprintf(want, sizeof want, "finalized-texture table: up to %ld textures", expect);
    CHECK(n == 1 && strstr(out, want), "one start line with the size");
    CHECK(g_ghost_cap == (unsigned)expect, argc > 2 ? "DM_NVN_GHOST's size" : "the profile's size");
    if (!strcmp(DM_GAME_ID, "0400486024DEC000")) CHECK(DM_GAME_GHOST_TABLE == 4096, "Ocarina of Time's profile: 4096");
    pick();
    ring((unsigned)expect);   // the size this run started with (1000 under DM_NVN_GHOST=1000: a size that is no power of two)
    ring(512); ring(4096); ring(1000); ring(64); ring(8192);
    thrash();
    trim();
    lru(); in_flight(); idle_drain(); low_headroom();
    patch_less_misses();
    line();
    printf("t_ghost (table %u at start): %d checks, %d failed\n", (unsigned)expect, checks, failed); return failed != 0;
} }
