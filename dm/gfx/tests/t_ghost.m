// The finalized-texture table (g_ghost, tex_put): its size decided once (ghost_cap: 512 by default, the profile's ghost_table, DM_NVN_GHOST held to 64..8192) and logged at the start,
// the ring holding exactly that many with the oldest going first, and the counts of the table's 300-frame line (mtl_ghost_stat): puts, evictions, and puts of a serial the table
// pushed out in the last 4 frames (thrash), the patch time less the misses inside it, and a memory trim taking a larger table back to 512 (ghost_trim). Ocarina of Time put about 800 textures a frame into 512 in one area on an iPhone, most of them pushed out a frame or two before.
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
static int resolves(uint64_t k) { return tex_get(k) != nil; }
// Empty the table as evictions would, and give it another size (a test only: the host decides it once)
static void ghost_reset(unsigned cap) {
    pthread_mutex_lock(&g_smu);
    for (unsigned i = 0; i < NGHOST_MAX; i++) if (g_ghost_ring[i]) {
        id ev = hm_get_id(&g_ghost, &g_ghost_ring[i]); if (ev) { ghost_held_add((__bridge void *)ev, -1); obj_drop(ev); }
        hm_del_id(&g_ghost, &g_ghost_ring[i]); g_ghost_ring[i] = 0;
    }
    g_ghost_next = 0; g_ghost_cap = cap; memset(g_ghost_gone_ser, 0, sizeof g_ghost_gone_ser);
    pthread_mutex_unlock(&g_smu);
}
static uint64_t g_next = 1ull << 61;   // serials no texture object owns (not in g_tex_live) and below 2^62: they go to the ghost table
static void put(uint64_t k) { @autoreleasepool { tex_put(k, [NSObject new]); } }
static void frame(uint64_t f) { atomic_store(&g_cur_frame, f); }

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
    CHECK(sizeof g_ghost_ring == 8192 * sizeof(uint64_t), "the ring has room for 8,192 (64 KB)");
}

// The ring holds exactly cap serials, the oldest going first; puts and evictions counted
static void ring(unsigned cap) {
    ghost_reset(cap); frame(1000);
    uint64_t base = g_next, puts0 = g_ghost_puts, ev0 = g_ghost_evicted;
    for (unsigned i = 0; i < cap; i++) put(base + i);
    CHECK(held() == cap && g_ghost_evicted == ev0, "a full table holds every one put");
    for (unsigned i = 0; i < 100; i++) put(base + cap + i);
    int first_gone = 1, kept = 1; for (unsigned i = 0; i < 100; i++) first_gone &= !resolves(base + i);
    for (unsigned i = 100; i < cap + 100; i++) kept &= resolves(base + i);
    char m[96]; snprintf(m, sizeof m, "%u: the table holds %u, the 100 oldest gone", cap, cap);
    CHECK(held() == cap && first_gone && kept, m);
    CHECK(g_ghost_puts - puts0 == cap + 100 && g_ghost_evicted - ev0 == 100, "puts and evictions counted");
    put(base + cap + 99);   // a serial still held, put again: replaced, not another entry
    CHECK(held() == cap && g_ghost_puts - puts0 == cap + 100 && g_ghost_evicted - ev0 == 100, "a serial put again while held is no new put");
    g_next = base + cap + 100;
}

// A put of a serial the table pushed out in the last 4 frames is thrash; older ones and new serials are not
static void thrash(void) {
    ghost_reset(64); uint64_t base = g_next; frame(2000);
    for (unsigned i = 0; i < 64 + 8; i++) put(base + i);   // 8 pushed out at frame 2000
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
    put(base); put(base + GHOST_GONE); for (unsigned i = 1; i <= 62; i++) put(base + i);   // base in ring slot 0, base + 8192 in slot 1
    put(base + 63);   // pushes base out (slot 0)
    th0 = g_ghost_thrash; frame(2101); put(base);   // wanted again: its put pushes out base + 8192, whose record takes base's slot
    CHECK(g_ghost_thrash - th0 == 1 && !resolves(base + GHOST_GONE), "thrash counted when the put's own eviction shares the serial's record slot");
    g_next = base + 2 * GHOST_GONE;
}

// A memory trim takes a table above the default's size back down to it, the oldest first; the emptied slots fill again before anything is pushed out
static void trim(void) {
    ghost_reset(4096); uint64_t base = g_next, ev0, puts0; frame(2500);
    for (unsigned i = 0; i < 3000; i++) put(base + i);   // not full: the oldest is slot 0
    ev0 = g_ghost_evicted;
    unsigned n = ghost_trim(NGHOST_DEF);
    int gone = 1, kept = 1; for (unsigned i = 0; i < 2488; i++) gone &= !resolves(base + i);
    for (unsigned i = 2488; i < 3000; i++) kept &= resolves(base + i);
    CHECK(n == 2488 && held() == 512 && gone && kept && g_ghost_evicted == ev0, "3000 held in 4096, trimmed to 512: the 2488 oldest go, not counted as evictions");
    CHECK(ghost_trim(NGHOST_DEF) == 0 && held() == 512, "a table at 512 is not trimmed");
    g_next = base + 3000;
    ghost_reset(1000); base = g_next;
    for (unsigned i = 0; i < 1500; i++) put(base + i);   // wrapped: base + 500 is the oldest, in slot 500
    n = ghost_trim(NGHOST_DEF);
    gone = 1; kept = 1; for (unsigned i = 0; i < 988; i++) gone &= !resolves(base + i);
    for (unsigned i = 988; i < 1500; i++) kept &= resolves(base + i);
    CHECK(n == 488 && held() == 512 && gone && kept, "a wrapped ring trimmed from its oldest");
    ev0 = g_ghost_evicted; puts0 = g_ghost_puts;
    for (unsigned i = 0; i < 488; i++) put(base + 1500 + i);
    CHECK(held() == 1000 && g_ghost_evicted == ev0, "the 488 emptied slots fill again without an eviction");
    put(base + 1988);
    CHECK(g_ghost_evicted - ev0 == 1 && !resolves(base + 988) && resolves(base + 989) && g_ghost_puts - puts0 == 489, "then the oldest goes first again");
    g_next = base + 2000;
    // Through the memory trim itself: a warning trims, back to normal does not
    ghost_reset(4096); base = g_next;
    for (unsigned i = 0; i < 1000; i++) put(base + i);
    char out[8192];
    logged(out, sizeof out, "memory trim", ^{ mtl_trim(0); });
    CHECK(held() == 1000 && strstr(out, "finalized-texture table entries 0 (down to 512)"), "pressure back to normal: the table stays");
    logged(out, sizeof out, "memory trim", ^{ mtl_trim(1); });
    printf("%s", out);
    CHECK(held() == 512 && strstr(out, "finalized-texture table entries 488 (down to 512)"), "a pressure warning: down to 512, in the trim's line");
    g_next = base + 1000;
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
    for (unsigned i = 0; i < 64 + 30; i++) put(base + i);   // 94 puts, 30 pushed out
    frame(3302); for (unsigned i = 0; i < 6; i++) put(base + i);   // 6 of them wanted again: 6 thrash, 6 more pushed out
    int n = logged(out, sizeof out, "finalized-texture table up to frame", ^{ mtl_ghost_stat(3600); });
    printf("%s", out);
    CHECK(n == 1, "one line for the window");
    CHECK(strstr(out, "up to frame 3600 (64 held, up to 64), per frame: 0.33 put, 0.02 of them pushed out in the last 4 frames, 0.12 pushed out;") != NULL, "per frame over 300 frames: 100 puts, 6 thrash, 36 evictions");
    CHECK(strstr(out, "ms in the texture misses that put") && strstr(out, "ms patching pool tables") && strstr(out, "texture ID epochs started"), "the costs and the epochs");
    g_next = base + 100;
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
    patch_less_misses();
    line();
    printf("t_ghost (table %u at start): %d checks, %d failed\n", (unsigned)expect, checks, failed); return failed != 0;
} }
