// Texture ID epochs (ser_sync) and their causes. A change a note names sends only that serial's IDs down the slow path; a change without a note, a list past SER_NOTES, a release of
// shared textures or a sparse mapping request since the last sync starts a new epoch, which sends every ID there. Before DM_NVN_SPARSE_EPOCH any sparse mapping that existed made
// every change start one (Mario Kart World, whose terrain arrays are sparse, started 14-19 a frame with no resolution family behind them): now only a mapping request since the
// last sync does, and the pool tables follow the same rule (pool_walk: built whole only after a mapping request since the table took its entries). Each epoch is counted by
// cause (g_epr) for the finalized-texture table's line. The sparse mapping generation is moved by hand (g_vp_gen, what every mapping request moves in hle_nvn.c vpt_set).
// A micro-benchmark times a sync of notes against one that starts an epoch, each followed by a lookup of every registered ID, as the pool walks after each change do.
// --off: the run's DM_NVN_SPARSE_EPOCH=0 (the old rule: with a sparse mapping every change starts an epoch and builds the pool tables whole)
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

enum { NT = 8, BASE = 1, NB_TEX = 64, NB_PER = 64, NB_BASE = 64, SYNCS = 15 };   // the benchmark: 64 textures x 64 IDs = 4,096 IDs, 15 syncs ("a frame" of Mario Kart World)
static NVNtexture g_t[NT];
static uint64_t ser_of(int i) { return ((const tex_t *)&g_t[i])->serial; }
static void resolve_once(int lo, int n) { os_unfair_lock_lock(&g_rmu); for (int i = lo; i < lo + n; i++) tex_fast(i); os_unfair_lock_unlock(&g_rmu); }
static int stale(int lo, int n);
// Every ID's view taken again, until a pass changes no serial (a first resolution notes the serial entries it makes)
static void resolve(int lo, int n) { for (int k = 0; k < 4; k++) { resolve_once(lo, n); if (!stale(lo, n)) return; } }
// IDs in [lo, lo + n) whose cached view the next lookup cannot take (after the sync a lookup makes)
static int stale(int lo, int n) {
    os_unfair_lock_lock(&g_rmu); uint64_t ep = treg_ep(); int s = 0;
    for (int i = lo; i < lo + n; i++) s += !g_treg[i].view || g_treg[i].view_ser != ep;
    os_unfair_lock_unlock(&g_rmu); return s;
}
static uint64_t ep_now(void) { return g_treg_ep; }
static uint64_t why(int k) { return atomic_load(&g_epr[k]); }
static void sparse_request(void) { atomic_fetch_add(&g_vp_gen, 1); }   // what a mapping request does to the generation (vpt_set)
// The 2D float texture table at base 0, as a draw that reads it would ask for it, in a submission of its own (t_pool_notes)
static id<MTLBuffer> table(void) {
    mtl_sub_begin(); __unsafe_unretained id<MTLBuffer> b = nil;
    os_unfair_lock_lock(&g_rmu); pool_gpu(0, MTLTextureType2D, NVN_DPF_FLOAT, 0, &b); os_unfair_lock_unlock(&g_rmu);
    id<MTLBuffer> held = b; CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull), "the submission completed"); return held;
}
static uint64_t entry(id<MTLBuffer> b, int i) { return ((const uint64_t *)((const uint8_t *)b.contents + DMSH_POOL_HEAD))[i]; }
// What fn writes to stderr (MLOG), the lines holding key joined into out (t_ghost)
typedef void (^logged_fn)(void);
static int logged(char *out, size_t cap, const char *key, logged_fn fn) {
    char path[] = "/tmp/t_tex_epochs.XXXXXX"; int fd = mkstemp(path); if (fd < 0) return 0;
    fflush(stderr); int saved = dup(2); if (saved < 0) { unlink(path); close(fd); return 0; }
    dup2(fd, 2); fn(); fflush(stderr); dup2(saved, 2); close(saved);
    FILE *f = fopen(path, "r"); unlink(path); close(fd); if (!f) return 0;
    char line[4096]; int got = 0; *out = 0;
    while (fgets(line, sizeof line, f)) if (strstr(line, key)) { strlcat(out, line, cap); got++; }
    fclose(f); return got;
}

int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "--off");
    setenv("DM_NVN_RT_RECYCLE", "0", 1);
    mtl_init();
    CHECK(sparse_epoch_on() == !off, off ? "DM_NVN_SPARSE_EPOCH=0: the old rule" : "the new rule by default");
    // NT textures over a pool the CPU cannot reach (each resolves to its shared texture), texture i at ID BASE + i
    size_t len = (size_t)(NT + NB_TEX) * 4096; uint8_t *m = mmap(NULL, len, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); if (m == MAP_FAILED) abort();
    pool_t rp = {0}; pool_builder_t pb = {.mem = m, .size = len, .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize((NVNmemoryPool *)&rp, (const NVNmemoryPoolBuilder *)&pb), "the pool initialized");
    NVNtextureBuilder tb = {0}; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetWidth(&tb, 4); h_nvnTextureBuilderSetHeight(&tb, 4); h_nvnTextureBuilderSetFormat(&tb, NVN_FORMAT_RGBA8);
    int ok = 1;
    for (int i = 0; i < NT; i++) { h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&rp, (ptrdiff_t)i * 4096); ok &= h_nvnTextureInitialize(&g_t[i], &tb) != 0; mtl_reg_tex(BASE + i, (const tex_t *)&g_t[i], NULL); }
    CHECK(ok, "the textures initialized");
    resolve(BASE, NT);
    CHECK(stale(BASE, NT) == 0, "every ID holds a view of this epoch");

    // No sparse mapping: a note sends its serial's ID alone down the slow path
    uint64_t ep = ep_now(); ser_note(ser_of(2));
    CHECK(stale(BASE, NT) == 1 && ep_now() == ep, "no sparse mapping: a note, its ID alone, no epoch");
    resolve(BASE, NT);

    // A mapping request since the last sync: the next change starts an epoch whatever the notes (the negative control: this one must start)
    sparse_request(); uint64_t sp = why(EPR_SPARSE); ep = ep_now(); ser_note(ser_of(2));
    CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1 && why(EPR_SPARSE) == sp + 1, "a mapping request since the last sync: a new epoch, every ID, counted as a sparse mapping change");
    resolve(BASE, NT);

    // A sparse mapping exists, no request since: with the new rule the notes cover the change; with the old one every change starts an epoch
    uint64_t any = why(EPR_SPARSE_ANY), kept = atomic_load(&g_epr_kept); ep = ep_now(); ser_note(ser_of(5));
    if (!off) CHECK(stale(BASE, NT) == 1 && ep_now() == ep && atomic_load(&g_epr_kept) == kept + 1, "a sparse mapping, no request since: the note's ID alone, no epoch, counted as kept");
    else CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1 && why(EPR_SPARSE_ANY) == any + 1, "DM_NVN_SPARSE_EPOCH=0: an epoch, counted as a sparse mapping existing");
    resolve(BASE, NT);
    // A request between syncs, then several notes: the request is not lost to the notes
    sparse_request(); ep = ep_now(); ser_note(ser_of(1)); ser_note(ser_of(3));
    CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1, "a request among notes: the next sync starts an epoch");
    resolve(BASE, NT);
    // A request with no serial change: no sync happens (as before), and the change after it starts the epoch
    sparse_request(); resolve(BASE, NT); ep = ep_now(); CHECK(ep_now() == ep && stale(BASE, NT) == 0, "a request alone syncs nothing");
    ser_note(ser_of(4)); CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1, "the next change after a request starts the epoch");
    resolve(BASE, NT);

    // Every other cause still starts one, each counted as itself
    uint64_t c0 = why(EPR_UPGRADE); ep = ep_now(); ser_bump_bare(EPR_UPGRADE);
    CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1 && why(EPR_UPGRADE) == c0 + 1, "a format view upgrade (no note): an epoch, counted as one");
    resolve(BASE, NT);
    c0 = why(EPR_MIPDROP); ep = ep_now(); ser_note(ser_of(0)); ser_bump_bare(EPR_MIPDROP);
    CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1 && why(EPR_MIPDROP) == c0 + 1, "a mip-dropped texture made whole beside a note: an epoch, counted as the bump");
    resolve(BASE, NT);
    c0 = why(EPR_OTHER); ep = ep_now(); atomic_fetch_add(&g_ser_gen, 1);
    CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1 && why(EPR_OTHER) == c0 + 1, "a bump no site names: an epoch, counted as other");
    resolve(BASE, NT);
    c0 = why(EPR_FULL); ep = ep_now(); for (int i = 0; i <= SER_NOTES; i++) ser_note(ser_of(6));
    CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1 && why(EPR_FULL) == c0 + 1, "one note past the list: an epoch, counted as notes past the list");
    resolve(BASE, NT);
    ep = ep_now(); for (int i = 0; i < SER_NOTES; i++) ser_note(ser_of(6));
    if (!off) CHECK(stale(BASE, NT) == 1 && ep_now() == ep, "a full list, not past it: the notes cover it");
    resolve(BASE, NT);
    c0 = why(EPR_SHARED); ep = ep_now(); ser_note_all();
    CHECK(stale(BASE, NT) == NT && ep_now() == ep + 1 && why(EPR_SHARED) == c0 + 1, "shared textures let go: an epoch, counted as such");
    resolve(BASE, NT);

    // The pool tables: a note with a sparse mapping and no request since patches the table (new rule) or builds it whole (old rule); a request since builds it whole either way
    table(); table();
    uint64_t builds = g_stat_pool_builds; ser_note(ser_of(3)); id<MTLBuffer> t1 = table();
    if (!off) CHECK(g_stat_pool_builds == builds, "a note, sparse mapping unchanged: the table is patched or kept, not built whole");
    else CHECK(g_stat_pool_builds == builds + 1, "DM_NVN_SPARSE_EPOCH=0: built whole");
    sparse_request(); builds = g_stat_pool_builds; ser_note(ser_of(3)); id<MTLBuffer> t2 = table();
    CHECK(g_stat_pool_builds == builds + 1, "a mapping request since the table took its entries: built whole");
    int same = 1; for (int i = BASE; i < BASE + NT; i++) same &= entry(t1, i) == entry(t2, i);
    CHECK(same, "the patched table holds what the table built whole does");
    // A request, then a registration alone (the table patched, no serial change), then a change: the table's entries were never all taken again since the request, so it is built
    // whole (a patch of the registration must not count as taking every entry at the new generation)
    table(); sparse_request(); mtl_reg_tex(BASE + NT, (const tex_t *)&g_t[0], NULL); uint64_t sg0 = atomic_load(&g_ser_gen); builds = g_stat_pool_builds; table();
    CHECK(atomic_load(&g_ser_gen) == sg0 && g_stat_pool_builds == builds, "a registration alone: the table is patched");
    builds = g_stat_pool_builds; ser_note(ser_of(3)); table();
    CHECK(g_stat_pool_builds == builds + 1, "a request before a registration-only patch: the next change still builds the table whole");
    mtl_reg_tex(BASE + NT, NULL, NULL); table();

    // The finalized-texture table's line names the causes (a put, so the window writes one)
    @autoreleasepool { tex_put(1ull << 61, [NSObject new]); }
    char out[8192];
    CHECK(logged(out, sizeof out, "finalized-texture table up to frame", ^{ mtl_ghost_stat(300); }) == 1, "the line is written");
    CHECK(strstr(out, "; epochs by cause a frame: ") && strstr(out, "sparse mappings changed") && strstr(out, "format view upgrades") && strstr(out, "notes past the list") && strstr(out, "shared textures let go")
          && strstr(out, "syncs kept by their notes with sparse mappings unchanged") && strstr(out, off ? "(DM_NVN_SPARSE_EPOCH off)" : "(DM_NVN_SPARSE_EPOCH on)"), "the causes and the kept syncs, in plain words");
    if (!off) CHECK(!strstr(out, "a sparse mapping exists"), "with the new rule no epoch is counted for a mapping that only exists");
    else CHECK(strstr(out, "a sparse mapping exists"), "with the old rule, the epochs it started");
    fputs(out, stdout);
    @autoreleasepool { tex_put((1ull << 61) + 1, [NSObject new]); }
    CHECK(logged(out, sizeof out, "finalized-texture table up to frame", ^{ mtl_ghost_stat(600); }) == 1 && strstr(out, "epochs started 0.00") && strstr(out, "epochs by cause a frame: none; 0.00 syncs kept"),
          "a window without epochs: none");

    // Micro-benchmark, a sparse mapping existing and no request since: 4,096 IDs, SYNCS syncs, each followed by a lookup of every ID (a pool walk's), a sync of one note against
    // one that starts an epoch. With the new rule the note's sync sends 64 IDs down the slow path; with the old one (--off) it starts an epoch too. Best of 5
    NVNtexture *bt = calloc(NB_TEX, sizeof *bt); ok = 1;
    for (int i = 0; i < NB_TEX; i++) { h_nvnTextureBuilderSetStorage(&tb, (NVNmemoryPool *)&rp, (ptrdiff_t)(NT + i) * 4096); ok &= h_nvnTextureInitialize(&bt[i], &tb) != 0;
        for (int j = 0; j < NB_PER; j++) mtl_reg_tex(NB_BASE + i * NB_PER + j, (const tex_t *)&bt[i], NULL); }
    CHECK(ok, "the benchmark's textures initialized");
    const int nb = NB_TEX * NB_PER; resolve(NB_BASE, nb); resolve(NB_BASE, nb);
    static mach_timebase_info_data_t tbi; mach_timebase_info(&tbi);
    double best_note = 1e30, best_ep = 1e30;
    for (int r = 0; r < 5; r++) {
        uint64_t t0 = mach_absolute_time();
        for (int s = 0; s < SYNCS; s++) { ser_note(((const tex_t *)&bt[s % NB_TEX])->serial); resolve_once(NB_BASE, nb); }
        uint64_t t1 = mach_absolute_time();
        for (int s = 0; s < SYNCS; s++) { ser_bump_bare(EPR_OTHER); resolve_once(NB_BASE, nb); }
        uint64_t t2 = mach_absolute_time();
        double a = (double)(t1 - t0) * tbi.numer / tbi.denom / 1000.0, b = (double)(t2 - t1) * tbi.numer / tbi.denom / 1000.0;
        if (a < best_note) best_note = a; if (b < best_ep) best_ep = b;
    }
    printf("benchmark (DM_NVN_SPARSE_EPOCH %s, a sparse mapping exists): %d syncs over %d IDs, each followed by a lookup of every ID: a note each %.1f us, an epoch each %.1f us (%.1fx)\n",
           off ? "off" : "on", SYNCS, nb, best_note, best_ep, best_ep / best_note);
    if (!off) CHECK(best_ep > 3 * best_note, "a sync of one note costs a fraction of an epoch: only its IDs take the slow path");
    else CHECK(best_note > best_ep / 2, "the old rule: a sync of one note costs an epoch, every ID takes the slow path");

    for (int i = 0; i < nb; i++) mtl_reg_tex(NB_BASE + i, NULL, NULL);
    for (int i = 0; i < NT; i++) mtl_reg_tex(BASE + i, NULL, NULL);
    table(); table();
    for (int i = 0; i < NB_TEX; i++) h_nvnTextureFinalize(&bt[i]);
    for (int i = 0; i < NT; i++) h_nvnTextureFinalize(&g_t[i]);
    h_nvnMemoryPoolFinalize((NVNmemoryPool *)&rp); free(bt); defer_drain(); munmap(m, len);
    printf("t_tex_epochs (DM_NVN_SPARSE_EPOCH %s): %d checks, %d failed\n", off ? "off" : "on", checks, failed); return failed != 0;
} }
