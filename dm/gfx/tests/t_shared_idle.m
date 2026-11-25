// DM_NVN_SHARED_IDLE (nvn_mtl.m shared_idle_locked): shared textures kept by the sharing table alone (no live or finalized serial, view or pin holds them) that no lookup found
// for the wait go, when their storage holds what they hold (mode 1, the default): a texture the GPU cannot draw into in a pool the CPU can read, and one it can whose writes are
// stored into its storage (a format the host does not widen); never a render target in a CPU_NO_ACCESS pool, a read-only texture there (a GPU copy's content), a COMPRESSIBLE one,
// one looked up lately, one a serial holds, a view's parent held through the view's serial, or a resolution family member. Mode 2 takes the GPU's own content too. Each texture's bytes
// count once however many keys name it; the left-behind count says what mode 2 would add. Last, the walk runs at a commit every SI_EVERY submissions, and with the switch at 0
// nothing goes (the default since 2026-11-22). Run with DM_NVN_SHARED_IDLE unset, =1 and =2 (check_t_shared_idle): the test reads the mode the host read
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)

static alias_key akey(const pool_t *pool, int64_t off, NVNformat format, int w, uint32_t flags) {
    alias_key k; memset(&k, 0, sizeof k); k.pool = (uint64_t)(uintptr_t)pool; k.off = off;
    k.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = w, .depth = 1, .levels = 1, .samples = 1, .flags = flags};
    return k;
}
static id<MTLTexture> mk(MTLPixelFormat pf, int w, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:w mipmapped:NO];
    d.usage = usage; d.storageMode = MTLStorageModePrivate; return [g_dev newTextureWithDescriptor:d];
}
static int has(const alias_key *k) { pthread_mutex_lock(&g_smu); int r = nvn_hm_get(&g_alias, k) != NULL; pthread_mutex_unlock(&g_smu); return r; }
static void next_submission(void) { if (!mtl_wait(mtl_sub_commit(), 5000000000ull)) { failed++; fprintf(stderr, "FAIL: a submission did not complete\n"); } mtl_sub_begin(); }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    mtl_init(); mtl_sub_begin();
    int mode = si_mode();
    printf("DM_NVN_SHARED_IDLE=%d, idle %llu submissions by default\n", mode, (unsigned long long)g_si_idle);
    CHECK(g_si_idle == SI_IDLE_DEF || getenv("DM_NVN_SHARED_IDLE_SUBS"), "the wait is 65,536 submissions unless set");
    static uint8_t cmem[1 << 20], gmem[1 << 20];
    static pool_t cpu = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = cmem, .size = sizeof cmem},
                  gpu = {.flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED, .mem = gmem, .size = sizeof gmem};
    const MTLTextureUsage RO = MTLTextureUsageShaderRead, RT = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    // Kept alone and idle, content the storage's: a BC1 asset (under two keys), an RGBA8 target whose writes are stored into its storage
    alias_key kbc = akey(&cpu, 0, NVN_FORMAT_RGBA_DXT1, 64, 0), kbc2 = akey(&cpu, 0, NVN_FORMAT_RGBA_DXT1_SRGB, 64, 0), krt = akey(&cpu, 1 << 16, NVN_FORMAT_RGBA8, 64, 0);
    // Kept alone and idle, content the GPU's own: a target in a CPU_NO_ACCESS pool, a read-only texture there, a COMPRESSIBLE target in a CPU pool
    alias_key kgrt = akey(&gpu, 0, NVN_FORMAT_RGBA8, 64, 0), kgro = akey(&gpu, 1 << 16, NVN_FORMAT_RGBA_DXT1, 64, 0), kcmp = akey(&cpu, 2 << 16, NVN_FORMAT_RGBA8, 64, NVN_TEXTURE_FLAGS_COMPRESSIBLE);
    // Kept: looked up lately, held by a serial, a view's parent held through the view's serial, a resolution family member
    alias_key kseen = akey(&cpu, 3 << 16, NVN_FORMAT_RGBA8, 64, 0), kheld = akey(&cpu, 4 << 16, NVN_FORMAT_RGBA8, 64, 0), kpar = akey(&cpu, 5 << 16, NVN_FORMAT_RGBA8, 64, 0),
              kfam = akey(&cpu, 6 << 16, NVN_FORMAT_RGBA8, 64, 0);
    id<MTLTexture> bc = mk(MTLPixelFormatBC1_RGBA, 64, RO), rt = mk(MTLPixelFormatRGBA8Unorm, 64, RT), grt = mk(MTLPixelFormatRGBA8Unorm, 64, RT), gro = mk(MTLPixelFormatBC1_RGBA, 64, RO),
                   cmp = mk(MTLPixelFormatRGBA8Unorm, 64, RT), seen = mk(MTLPixelFormatRGBA8Unorm, 64, RT), held = mk(MTLPixelFormatRGBA8Unorm, 64, RT), par = mk(MTLPixelFormatRGBA8Unorm, 64, RT),
                   fam = mk(MTLPixelFormatRGBA8Unorm, 64, RT);
    id<MTLTexture> view = [par newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    NvImageHeap *own = [NvImageHeap new]; objc_setAssociatedObject(fam, &g_image_heap_owner_key, own, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    for (int i = 0; i < 8; i++) next_submission();   // the stamps below are older than the wait of 4
    pthread_mutex_lock(&g_smu);
    alias_key ks[] = {kbc, kbc2, krt, kgrt, kgro, kcmp, kseen, kheld, kpar, kfam}; id os[] = {bc, bc, rt, grt, gro, cmp, seen, held, par, fam};
    for (unsigned i = 0; i < sizeof ks / sizeof ks[0]; i++) { alias_put(&ks[i], os[i]); nvn_hm_put(&g_alias_seen, &ks[i], (void *)(uintptr_t)1); }
    nvn_hm_put(&g_alias_seen, &kseen, (void *)(uintptr_t)(g_fence + 1));
    uint32_t n0 = g_alias.n;
    pthread_mutex_unlock(&g_smu);
    serial_put(980001, held); serial_put(980002, view);
    uint64_t n_before = g_si_n, b_before = g_si_bytes;
    pthread_mutex_lock(&g_smu); uint32_t went = shared_idle_locked(mode, 4, 256, NULL); uint32_t n1 = g_alias.n; pthread_mutex_unlock(&g_smu);
    printf("released %u entries, %llu bytes; left for the GPU's content %llu (%llu bytes)\n", went, (unsigned long long)(g_si_bytes - b_before), (unsigned long long)g_si_gpu_n, (unsigned long long)g_si_gpu_bytes);
    if (!mode) CHECK(!went && n1 == n0 && !g_si_n, "with the switch at 0 the walk releases nothing");
    else {
        CHECK(!has(&kbc) && !has(&kbc2) && !has(&krt), "the asset (both keys) and the target whose writes reach its storage go");
        CHECK(has(&kgrt) == (mode < 2) && has(&kgro) == (mode < 2) && has(&kcmp) == (mode < 2), mode < 2 ? "content the GPU's alone stays" : "mode 2 takes content the GPU's alone too");
        CHECK(has(&kseen) && has(&kheld) && has(&kpar) && has(&kfam), "one looked up lately, one a serial holds, a held view's parent and a family member stay");
        uint64_t want = bc.allocatedSize + rt.allocatedSize + (mode < 2 ? 0 : grt.allocatedSize + gro.allocatedSize + cmp.allocatedSize);
        CHECK(went == (mode < 2 ? 3u : 6u) && n0 - n1 == went && g_si_n - n_before == went && g_si_bytes - b_before == want, "counted, each texture's bytes once");
        CHECK(mode < 2 ? g_si_gpu_n == 3 && g_si_gpu_bytes == grt.allocatedSize + gro.allocatedSize + cmp.allocatedSize : !g_si_gpu_n, "the left-behind count is what mode 2 would add");
        pthread_mutex_lock(&g_smu); int still = alias_has(bc) || alias_has(rt); pthread_mutex_unlock(&g_smu);
        CHECK(!still, "a released texture is no longer shared (retired behind the submission in flight)");
    }
    if (mode) {   // a texture a live texture ID registration names (its cached view, through a view of it) stays, idle or not; a release starts a new ID epoch and an unknown pool-table log entry
        alias_key kr = akey(&cpu, 9 << 16, NVN_FORMAT_RGBA8, 64, 0), kf = akey(&cpu, 10 << 16, NVN_FORMAT_RGBA_DXT1, 64, 0);
        id<MTLTexture> rtex = mk(MTLPixelFormatRGBA8Unorm, 64, RO), ftex = mk(MTLPixelFormatBC1_RGBA, 64, RO), rview = [rtex newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
        treg_t *keep_treg = g_treg; int keep_n = g_ntreg; treg_t regs[2]; memset(regs, 0, sizeof regs);
        regs[1].ok = 1; regs[1].view = (__bridge void *)rview; g_treg = regs; g_ntreg = 2;
        pthread_mutex_lock(&g_smu); alias_put(&kr, rtex); alias_put(&kf, ftex); nvn_hm_put(&g_alias_seen, &kr, (void *)(uintptr_t)1); nvn_hm_put(&g_alias_seen, &kf, (void *)(uintptr_t)1); pthread_mutex_unlock(&g_smu);
        uint64_t ep0 = treg_ep(), gen0 = g_ser_gen;
        rmu_lock(); CFMutableSetRef held = treg_held_set(); rmu_unlock();
        CHECK(CFSetContainsValue(held, (__bridge const void *)rview) && CFSetContainsValue(held, (__bridge const void *)rtex), "the held set has a registration's view and its parent");
        pthread_mutex_lock(&g_smu); uint32_t w2 = shared_idle_locked(mode, 4, 256, held); pthread_mutex_unlock(&g_smu); CFRelease(held);
        CHECK(has(&kr) && !has(&kf) && w2 == 1 && g_si_reg_kept == 1, "an idle texture a texture ID names stays; one no ID names goes");
        CHECK(g_ser_gen == gen0 + 1 && g_ser_log[g_ser_gen % SER_LOG].gen != g_ser_gen, "the release leaves an unknown log entry: pool tables are built whole");
        CHECK(treg_ep() == ep0 + 1, "the release starts a new texture ID epoch: cached views are looked up again");
        regs[1].gone = 1; rmu_lock(); held = treg_held_set(); rmu_unlock();
        CHECK(!CFSetContainsValue(held, (__bridge const void *)rtex), "a registration whose pool went holds nothing"); CFRelease(held);
        g_treg = keep_treg; g_ntreg = keep_n;
        pthread_mutex_lock(&g_smu); alias_del(&kr); pthread_mutex_unlock(&g_smu);
    }
    serial_del(980001); serial_del(980002);
    {   // the commit's walk, every SI_EVERY submissions at the configured wait
        alias_key kc = akey(&cpu, 8 << 16, NVN_FORMAT_RGBA_DXT1, 64, 0); id<MTLTexture> c = mk(MTLPixelFormatBC1_RGBA, 64, RO);
        uint64_t idle0 = g_si_idle; g_si_idle = 4;
        pthread_mutex_lock(&g_smu); alias_put(&kc, c); pthread_mutex_unlock(&g_smu);
        int subs = 0; for (; subs < 2 * SI_EVERY + 8 && has(&kc); subs++) next_submission();
        printf("the commit's walk took it after %d submissions\n", subs);
        CHECK(mode ? !has(&kc) && subs <= SI_EVERY + 8 && subs >= 4 : has(&kc), mode ? "a commit's walk releases it within SI_EVERY submissions once idle" : "with the switch at 0 the commit releases nothing");
        g_si_idle = idle0;
        pthread_mutex_lock(&g_smu); alias_del(&kc); pthread_mutex_unlock(&g_smu);
    }
    pthread_mutex_lock(&g_smu); for (unsigned i = 0; i < sizeof ks / sizeof ks[0]; i++) alias_del(&ks[i]); pthread_mutex_unlock(&g_smu);
    next_submission(); defer_drain();
    printf("t_shared_idle (DM_NVN_SHARED_IDLE=%d): %d checks, %d failed\n", mode, checks, failed); return failed != 0;
} }
