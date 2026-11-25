// A sampler pool's entries 0 and 1 are registered at its initialization as the game's own NVN driver writes them (hle_nvn.c samp_pool_reserved; ported from the S2Arm project's
// 3b477729): linear filters, LOD 0..1000, wrap CLAMP_TO_EDGE, anisotropy 1 and 2. The expected values are written from S2Arm's reading of the driver, not taken from the code.
// Two pools in use at once each get them at their own base; the game's own later registration of ID 0 overrides the reserved one; a pool of one entry gets one; a pool past the
// 16 the host numbers apart, which shares the first one's numbering, does not overwrite the first one's entries; and the replay builds a Metal sampler for ID 0 (samp_by_id) and binds it where it used to read
// ID 0 as no sampler (samp_fast, pool_entry).
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
static int reserved(int sid, float aniso) {   // the driver's entry: NVN enums LINEAR 1, CLAMP_TO_EDGE 7, compare mode 0 (off) / LESS 2
    if (sid < 0 || sid >= g_nsreg || !g_sreg_ok[sid]) return 0;
    const samp_par *p = &g_sreg[sid];
    return p->minf == 1 && p->magf == 1 && p->ws == 7 && p->wt == 7 && p->wr == 7 && p->lod_min == 0.f && p->lod_max == 1000.f && p->lod_bias == 0.f
        && p->aniso == aniso && p->cmp_mode == 0 && p->cmp_func == 2 && p->reduction == 0;
}
int main(void) { @autoreleasepool {
    mtl_init();
    NVNsamplerPool sa, sb, sc; memset(&sa, 0, sizeof sa); memset(&sb, 0, sizeof sb); memset(&sc, 0, sizeof sc);
    CHECK(h_nvnSamplerPoolInitialize(&sa, NULL, 0, 272) && h_nvnSamplerPoolInitialize(&sb, NULL, 0x10000, 300), "two sampler pools initialized");
    int ba = nvn_dpool_base(&sa, 0), bb = nvn_dpool_base(&sb, 0);
    CHECK(ba != bb, "two pools in use are numbered apart");
    CHECK(reserved(ba, 1.f) && reserved(ba + 1, 2.f), "pool A: entries 0 and 1 are the driver's");
    CHECK(reserved(bb, 1.f) && reserved(bb + 1, 2.f), "pool B: entries 0 and 1 are the driver's, at its own base");
    CHECK(!g_sreg_ok[ba + 2], "entry 2 is not registered");
    rmu_lock(); id<MTLSamplerState> s0 = samp_by_id(ba); os_unfair_lock_unlock(&g_rmu);
    CHECK(s0 != nil, "the replay has a Metal sampler for ID 0");
    // ID 0 used to stand for no sampler wherever a handle was read (the dummy, nearest filtering): now the registered one, in the direct binding (samp_fast) and the pool tables
    rmu_lock(); void *f0 = samp_fast(ba); int gone = 0, left = 0, left_req = 0, trans = 0, dead = 0;
    uint64_t pe0 = pool_entry(1, 0, ba, ~0ull, &gone, &left, &left_req, &trans, &dead); uint64_t rid0 = g_srid[ba]; os_unfair_lock_unlock(&g_rmu);
    CHECK(f0 == (__bridge void *)s0 && f0 != (__bridge void *)dummy_samp(), "a binding of ID 0 takes the registered sampler, not the dummy");
    CHECK(pe0 && pe0 == rid0 && pe0 != dummy_samp_rid(), "a pool table's entry 0 is the registered sampler");
    rmu_lock(); int unreg = samp_reg(ba + 5); os_unfair_lock_unlock(&g_rmu);
    CHECK(!unreg, "an ID nothing registered is still none");
    NVNsamplerBuilder bld; memset(&bld, 0, sizeof bld); h_nvnSamplerBuilderSetDefaults(&bld);
    h_nvnSamplerBuilderSetMinMagFilter(&bld, NVN_MIN_FILTER_NEAREST, NVN_MAG_FILTER_NEAREST);
    h_nvnSamplerPoolRegisterSamplerBuilder(&sa, 0, &bld);
    CHECK(g_sreg[ba].minf == NVN_MIN_FILTER_NEAREST && g_sreg[ba].ws == NVN_WRAP_MODE_REPEAT, "the game's own registration of ID 0 overrides the reserved one");
    CHECK(reserved(ba + 1, 2.f) && reserved(bb, 1.f), "and leaves the others");
    CHECK(h_nvnSamplerPoolInitialize(&sc, NULL, 0x20000, 1), "a one-entry pool initialized");
    int bc = nvn_dpool_base(&sc, 0);
    CHECK(reserved(bc, 1.f) && (bc + 1 >= g_nsreg || !g_sreg_ok[bc + 1]), "a one-entry pool gets entry 0 only");
    // Pools past the 16 numbered apart share the first one's numbering (dpool_add): they must not overwrite what the game registered there
    NVNsamplerPool more[16]; memset(more, 0, sizeof more);
    for (int i = 0; i < 16; i++) h_nvnSamplerPoolInitialize(&more[i], NULL, 0, 8);
    CHECK(g_nspb == NDPOOL, "the host numbers 16 pools apart");
    CHECK(g_sreg[ba].minf == NVN_MIN_FILTER_NEAREST, "a pool past them does not overwrite the first pool's ID 0");
    printf("t_samp_reserved: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
