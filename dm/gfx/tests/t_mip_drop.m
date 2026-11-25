// Mip drop (DM_NVN_MIP_DROP, nvn_mtl.m md_pick / md_levels / md_whole): a large block-compressed 2D texture uploaded from its storage, first looked up by a texture ID, is made
// without its top K levels. Each level of the test textures is one solid BC1 colour (and per layer), so a sample tells which of the game's levels it read.
//   eligible: the host texture is the game's level K down; a sample whose derivatives ask for the game's level L reads level max(L, K); a texture ID's view of levels [b, b + n)
//             reads the game's level max(b, K) first; a sampler's top-level clamp counts from the host's first level (documented); a 2D array keeps its layers; a CPU write
//             re-uploads it still dropped, with the new content
//   excluded: uncompressed, below DM_NVN_MIP_DROP_MIN, a chain that stops early, a cube, a rectangle, an IMAGE texture, a thin strip, one a host use resolved first
//   made whole: a texture-to-buffer copy of a dropped texture reads the game's level 0 byte for byte, the texture stays whole after a later CPU write, the texture ID sees it
// Run with DM_NVN_MIP_DROP=2, 1 and 0 (check_t_mip_drop): every expectation follows the K the host read
// Also the long-frame line's split of the replay's time (nvn_lft.h), which these uploads drive: a texture made whole, an upload deswizzled on the CPU, the replay's lock waits
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#include "t_mtl4.h"
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)

static NVNmemoryPool tpool, cpool; static uint8_t *tmem, *cmem; static size_t tnext; static NVNcommandBuffer cmd;
static unsigned K;
static uint16_t rgb565(unsigned level, unsigned layer, unsigned gen) { return (uint16_t)(((level + 1 + gen * 12) & 31) << 11 | ((63 - level * 5) & 63) << 5 | ((layer * 10 + 3) & 31)); }
static void want_rgb(unsigned level, unsigned layer, unsigned gen, float c[3]) { uint16_t v = rgb565(level, layer, gen); c[0] = (v >> 11) / 31.f; c[1] = (v >> 5 & 63) / 63.f; c[2] = (v & 31) / 31.f; }
// One level of one layer filled with a solid BC1 block (colour0 > colour1: four-colour mode, every index 0)
static void fill_level(NVNtexture *tex, unsigned level, unsigned layer, unsigned gen) {
    tex_t *t = (tex_t *)tex; uint32_t w = MAX(t->d.width >> level, 1u), h = MAX(t->d.height >> level, 1u), bx = (w + 3) / 4, by = (h + 3) / 4;
    static uint64_t blocks[512 * 256]; uint64_t b = rgb565(level, layer, gen);   // colour1 = 0, indices 0
    for (uint32_t i = 0; i < bx * by; i++) blocks[i] = b;
    NVNtextureView v; h_nvnTextureViewSetDefaults(&v); h_nvnTextureViewSetLevels(&v, (int)level, 1);
    NVNcopyRegion r = {0, 0, (int)layer, (int)w, (int)h, 1};
    h_nvnTextureWriteTexels(tex, &v, &r, blocks);
}
static int make_tex(NVNtexture *tex, int target, int format, unsigned w, unsigned h, unsigned depth, unsigned levels, int flags) {
    NVNtextureBuilder tb; h_nvnTextureBuilderSetDefaults(&tb);
    h_nvnTextureBuilderSetTarget(&tb, target); h_nvnTextureBuilderSetWidth(&tb, (int)w); h_nvnTextureBuilderSetHeight(&tb, (int)h); h_nvnTextureBuilderSetDepth(&tb, (int)depth);
    h_nvnTextureBuilderSetLevels(&tb, (int)levels); h_nvnTextureBuilderSetFormat(&tb, format); h_nvnTextureBuilderSetFlags(&tb, flags);
    size_t sz = h_nvnTextureBuilderGetStorageSize(&tb); tnext = (tnext + 0xffff) & ~(size_t)0xffff;
    h_nvnTextureBuilderSetStorage(&tb, &tpool, (ptrdiff_t)tnext); tnext += sz;
    if (!h_nvnTextureInitialize(tex, &tb)) return 0;
    if (format == NVN_FORMAT_RGBA_DXT1) {
        unsigned layers = target == NVN_TEXTURE_TARGET_2D_ARRAY ? depth : target == NVN_TEXTURE_TARGET_CUBEMAP ? 6 : 1;
        for (unsigned l = 0; l < levels; l++) for (unsigned y = 0; y < layers; y++) fill_level(tex, l, y, 0);
    } else mtl_tex_cpu_written((tex_t *)tex);
    return 1;
}
static void settle(void) { for (int i = 0; i < 5000 && atomic_load(&g_up_pending); i++) usleep(1000); pthread_mutex_lock(&g_mu); g_done = g_fence; pthread_mutex_unlock(&g_mu); defer_drain(); }
static NvPkg *pkg_of(NVNtexture *tex) { id o = tex_get(((tex_t *)tex)->serial); return [o isKindOfClass:[NvPkg class]] ? o : nil; }
// The texture ID's texture, as a draw would bind it (tex_by_id: the sampling path)
static id<MTLTexture> by_id(int tid, NVNtexture *tex, const view_t *v) {
    mtl_reg_tex(tid, (const tex_t *)tex, v);
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> r = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu);
    if (!g_cb) up_flush();
    return r;
}
static id<MTLComputePipelineState> g_k2d, g_karr;
typedef struct { float grad, lvl; uint32_t mode, layer; } q_t;   // mode 0: derivatives grad (UV per pixel), 1: explicit level lvl
// One sample at the centre: what colour the GPU reads
static void sample(id<MTLTexture> t, id<MTLSamplerState> s, q_t q, float out[3]) {
    static id<MTLBuffer> ob; if (!ob) ob = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    memset(ob.contents, 0, 16);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> ce = t4_compute(cb);
    [ce setComputePipelineState:t4_keep(cb, t.textureType == MTLTextureType2DArray ? g_karr : g_k2d)];
    t4_tex(cb, ce, T4_CS, t, 0); t4_samp(cb, ce, T4_CS, s, 0); t4_bytes(cb, ce, T4_CS, &q, sizeof q, 0); t4_buf(cb, ce, T4_CS, ob, 0, 1);
    [ce dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    t4_end(cb, ce); t4_wait(cb);
    const float *f = ob.contents; out[0] = f[0]; out[1] = f[1]; out[2] = f[2];
}
static int near3(const float a[3], const float b[3]) { for (int i = 0; i < 3; i++) if (fabsf(a[i] - b[i]) > 0.03f) return 0; return 1; }
// A sample whose derivatives ask for the game's level L of a w-wide texture reads the game's level want
static int reads_level(id<MTLTexture> t, id<MTLSamplerState> s, unsigned w, unsigned L, unsigned layer, unsigned want, unsigned gen) {
    float got[3], exp[3]; q_t q = {(float)(1u << L) / (float)w, 0, 0, layer};
    sample(t, s, q, got); want_rgb(want, layer, gen, exp);
    if (!near3(got, exp)) fprintf(stderr, "  level %u layer %u: read %.3f %.3f %.3f, the game's level %u is %.3f %.3f %.3f\n", L, layer, got[0], got[1], got[2], want, exp[0], exp[1], exp[2]);
    return near3(got, exp);
}
static int reads_explicit(id<MTLTexture> t, id<MTLSamplerState> s, float lvl, unsigned want) {
    float got[3], exp[3]; q_t q = {0, lvl, 1, 0}; sample(t, s, q, got); want_rgb(want, 0, 0, exp);
    if (!near3(got, exp)) fprintf(stderr, "  explicit level %.0f: read %.3f %.3f %.3f, the game's level %u is %.3f %.3f %.3f\n", lvl, got[0], got[1], got[2], want, exp[0], exp[1], exp[2]);
    return near3(got, exp);
}
static id<MTLSamplerState> samp(float max_lod) {
    MTLSamplerDescriptor *d = [MTLSamplerDescriptor new]; d.minFilter = d.magFilter = MTLSamplerMinMagFilterNearest; d.mipFilter = MTLSamplerMipFilterNearest;
    d.lodMaxClamp = max_lod; d.supportArgumentBuffers = YES; return [g_dev newSamplerStateWithDescriptor:d];
}
static int dropped(id<MTLTexture> mt, NVNtexture *tex, unsigned k) { tex_t *t = (tex_t *)tex; while (mt.parentTexture) mt = mt.parentTexture; return mt.width == t->d.width >> k && mt.height == t->d.height >> k && mt.mipmapLevelCount == t->d.levels - k; }

int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    mtl_init();
    K = (unsigned)md_k();
    printf("DM_NVN_MIP_DROP: %u levels, from %u texels\n", K, g_md_min);
    const size_t tlen = 64 << 20, clen = 8 << 20;
    tmem = mmap(NULL, tlen, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0); cmem = mmap(NULL, clen, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
    if (tmem == MAP_FAILED || cmem == MAP_FAILED) abort();
    pool_builder_t pb = {.mem = tmem, .size = tlen, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize(&tpool, (const NVNmemoryPoolBuilder *)&pb), "texture pool initialized");
    pool_builder_t cb = {.mem = cmem, .size = clen, .flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    CHECK(h_nvnMemoryPoolInitialize(&cpool, (const NVNmemoryPoolBuilder *)&cb), "command pool initialized");
    CHECK(h_nvnCommandBufferInitialize(&cmd, NULL), "command buffer initialized");
    h_nvnCommandBufferAddCommandMemory(&cmd, &cpool, 0, 262144);
    NSError *err = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Q { float grad, lvl; uint mode, layer; };\n"
        "kernel void k2d(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Q &q [[buffer(0)]], device float4 *o [[buffer(1)]]) {\n"
        "  o[0] = q.mode ? t.sample(s, float2(0.5), level(q.lvl)) : t.sample(s, float2(0.5), gradient2d(float2(q.grad, 0), float2(0, q.grad))); }\n"
        "kernel void karr(texture2d_array<float> t [[texture(0)]], sampler s [[sampler(0)]], constant Q &q [[buffer(0)]], device float4 *o [[buffer(1)]]) {\n"
        "  o[0] = q.mode ? t.sample(s, float2(0.5), q.layer, level(q.lvl)) : t.sample(s, float2(0.5), q.layer, gradient2d(float2(q.grad, 0), float2(0, q.grad))); }\n", nil, &err);
    g_k2d = lib ? t4_cps(t4_fn(lib, @"k2d"), &err) : nil; g_karr = lib ? t4_cps(t4_fn(lib, @"karr"), &err) : nil;
    if (!g_k2d || !g_karr) { fprintf(stderr, "kernels: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLSamplerState> s_all = samp(1000), s_top = samp(0), s_one = samp(1);

    // Eligible: a 1024x1024 BC1 texture with every level (11)
    static NVNtexture a, b, arr;
    CHECK(make_tex(&a, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 11, 0), "1024x1024 BC1 texture, 11 levels");
    uint64_t up0 = atomic_load(&g_md_uploads);
    id<MTLTexture> ta = by_id(400, &a, NULL);
    CHECK(ta && dropped(ta, &a, K), "a texture ID's lookup makes it without its top K levels (the game's level K is the host's level 0)");
    CHECK(pkg_of(&a) && pkg_of(&a)->md == K && atomic_load(&g_md_uploads) - up0 == (K ? 1 : 0), "its NvPkg counts the levels left out");
    settle();
    int ok = 1; for (unsigned L = 0; L < 11; L++) ok &= reads_level(ta, s_all, 1024, L, 0, MAX(L, K), 0);
    CHECK(ok, "a sample asking for the game's level L by its derivatives reads the game's level max(L, K)");
    CHECK(reads_level(ta, s_top, 1024, 5, 0, K, 0), "a sampler clamped to the top level reads the first level kept");
    CHECK(reads_level(ta, s_one, 1024, 6, 0, K + 1, 0), "a sampler's level clamp counts from the host's first level (documented: K levels past the game's clamp)");
    CHECK(reads_explicit(ta, s_all, 0, K), "an explicit level 0 reads the first level kept");

    // Views by the game's level numbers
    view_t v; memset(&v, 0, sizeof v); v.set_levels = 1; v.base_level = 3; v.nlevels = 2;
    id<MTLTexture> va = by_id(401, &a, &v);
    CHECK(va && va.mipmapLevelCount == 2 && va.width == 1024u >> 3 && reads_explicit(va, s_all, 0, 3) && reads_explicit(va, s_all, 1, 4), "a view of the game's levels 3 + 2 reads levels 3 and 4");
    v.base_level = 1; v.nlevels = 1;
    id<MTLTexture> vb = by_id(402, &a, &v);
    CHECK(vb && vb.mipmapLevelCount == 1 && reads_explicit(vb, s_all, 0, MAX(1u, K)), "a view of a level left out reads the first level kept");
    v.base_level = 0; v.nlevels = 4;
    id<MTLTexture> vc = by_id(403, &a, &v);
    CHECK(vc && vc.mipmapLevelCount == 4 - K && reads_explicit(vc, s_all, 0, K) && reads_explicit(vc, s_all, 3 - K, 3), "a view of the game's levels 0 + 4 ends at the game's level 3");

    // A 2D array keeps its layers
    CHECK(make_tex(&arr, NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 2, 11, NVN_TEXTURE_FLAGS_MINIMAL_LAYOUT), "1024x1024x2 BC1 array, MINIMAL_LAYOUT");
    id<MTLTexture> tarr = by_id(404, &arr, NULL); settle();
    ok = tarr && dropped(tarr, &arr, K); for (unsigned y = 0; y < 2; y++) for (unsigned L = 0; L < 11; L += 3) ok &= reads_level(tarr, s_all, 1024, L, y, MAX(L, K), 0);
    CHECK(ok, "a 2D array: each layer reads the game's level max(L, K)");

    // A CPU write re-uploads it, still without its top levels, with the new content
    CHECK(make_tex(&b, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 2048, 1024, 1, 12, 0), "2048x1024 BC1 texture, 12 levels");
    id<MTLTexture> tb0 = by_id(405, &b, NULL); settle();
    fill_level(&b, 5, 0, 1);
    id<MTLTexture> tb1 = by_id(405, &b, NULL); settle();
    CHECK(tb1 != tb0 && dropped(tb1, &b, K) && reads_level(tb1, s_all, 2048, 5, 0, 5, 1) && reads_level(tb1, s_all, 2048, 6, 0, 6, 0), "a CPU write re-uploads it without its top levels, the written level new");

    // Excluded kinds stay whole, each counted by its reason (md_pick's tally, after the mip drop line)
    uint64_t why0[MDR_N]; for (int r = 0; r < MDR_N; r++) why0[r] = atomic_load(&g_mdr_n[r]);
    static NVNtexture ex[8]; int n_ex = 0;
    CHECK(make_tex(&ex[n_ex++], NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 1024, 1024, 1, 11, 0), "RGBA8");
    CHECK(make_tex(&ex[n_ex++], NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 512, 512, 1, 10, 0), "BC1 512x512 (below the minimum)");
    CHECK(make_tex(&ex[n_ex++], NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 2, 0), "BC1 1024x1024 with 2 levels");
    CHECK(make_tex(&ex[n_ex++], NVN_TEXTURE_TARGET_CUBEMAP, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 11, 0), "BC1 cube 1024");
    CHECK(make_tex(&ex[n_ex++], NVN_TEXTURE_TARGET_RECTANGLE, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 1, 0), "BC1 rectangle");
    CHECK(make_tex(&ex[n_ex++], NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 11, NVN_TEXTURE_FLAGS_IMAGE), "BC1 with IMAGE");
    CHECK(make_tex(&ex[n_ex++], NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 16, 1, 11, 0), "BC1 1024x16 strip (its smaller side under 16 << K)");
    for (int i = 0; i < n_ex; i++) {
        id<MTLTexture> t = by_id(410 + i, &ex[i], NULL); while (t.parentTexture) t = t.parentTexture;
        CHECK(t && t.width == ((tex_t *)&ex[i])->d.width && (!pkg_of(&ex[i]) || !pkg_of(&ex[i])->md), "an excluded texture is made whole");
    }
    // Resolved first by a host use (not a texture ID): whole
    static NVNtexture h;
    CHECK(make_tex(&h, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 11, 0), "BC1 texture a host use resolves first");
    id<MTLTexture> th = tex_mtl((tex_t *)&h); if (!g_cb) up_flush();
    CHECK(th && th.width == 1024 && th.mipmapLevelCount == 11, "a host use's first upload makes every level");
    id<MTLTexture> thid = by_id(420, &h, NULL);
    CHECK(thid == th, "a later texture ID lookup keeps it whole");
    {   // the tally: RGBA8 not block-compressed, 512 below the floor, 2 levels not a whole chain, the cube and the rectangle not 2D, IMAGE a flag, the strip too thin, the host use first
        static const int want[MDR_N] = {[MDR_FORMAT] = 1, [MDR_FLOOR] = 1, [MDR_CHAIN] = 1, [MDR_TARGET] = 2, [MDR_FLAGS] = 1, [MDR_SHAPE] = 1, [MDR_OUTSIDE] = 1};
        int ok_r = 1; for (int r = 0; r < MDR_N; r++) ok_r &= atomic_load(&g_mdr_n[r]) - why0[r] == (uint64_t)(K ? want[r] : 0);
        CHECK(ok_r, K ? "each upload that kept every level is counted by its reason" : "with the switch off nothing is counted");
        CHECK(!K || atomic_load(&g_mdr_bytes[MDR_FLOOR]) >= md_bytes((tex_t *)&ex[1], K), "with the bytes of its top levels");
        char why[1024]; md_tally_text(why, sizeof why); printf("mip drop tally:%s\n", why);
        CHECK(K ? strstr(why, ", below the size floor 1 (") && strstr(why, "; uploads that kept every level in all, by reason (the MB of their top levels): not block-compressed ") == why : !why[0], "the line's tally names them");
    }

    // Made whole: a texture-to-buffer copy of the dropped texture reads the game's level 0 (and level 1) byte for byte
    settle();
    uint64_t whole0 = atomic_load(&g_md_whole), live0 = atomic_load(&g_md_live_n);
    NVNcopyRegion r0 = {0, 0, 0, 1024, 1024, 1}, r1 = {0, 0, 0, 512, 512, 1};
    NVNtextureView l1; h_nvnTextureViewSetDefaults(&l1); h_nvnTextureViewSetLevels(&l1, 1, 1);
    uint64_t dst0 = (uint64_t)(uintptr_t)(cmem + (1 << 20)), dst1 = dst0 + (512 << 10);
    memset((void *)(uintptr_t)dst0, 0xcd, (512 << 10) + (128 << 10));
    h_nvnCommandBufferBeginRecording(&cmd);
    h_nvnCommandBufferCopyTextureToBuffer(&cmd, &a, NULL, &r0, dst0, 0);
    h_nvnCommandBufferCopyTextureToBuffer(&cmd, &a, &l1, &r1, dst1, 0);
    NVNcommandHandle hd = h_nvnCommandBufferEndRecording(&cmd);
    uint8_t *rec = nvn_rec_linear(hd, NULL);
    nvn_lft l0; mtl_lft_take(&l0); int none = 1; for (int k = 0; k < LFT_N; k++) none &= !l0.n[k];
    CHECK(none, "the long-frame split counts nothing before a submission names the replay thread");
    mtl_sub_begin(); mtl_exec(rec);
    CHECK(mtl_wait(mtl_sub_commit(), 5000000000ull) && !mtl_last_commit_error(), "the copies ran");
    settle(); free(rec);
    nvn_lft lw; mtl_lft_take(&lw);
    CHECK(K ? lw.n[LFT_MD] == 1 && lw.ns[LFT_MD] > 0 : !lw.n[LFT_MD], "the long-frame split times the texture made whole for the copy");
    CHECK(!K || (lw.n[LFT_TEX] >= 1 && lw.up[LFT_TEX] > 0 && lw.n[LFT_RES] >= 1), "and its new texture and residency add, inside its upload");
    const uint64_t *c0 = (const uint64_t *)(uintptr_t)dst0, *c1 = (const uint64_t *)(uintptr_t)dst1; int same = 1;
    for (int i = 0; i < 256 * 256; i++) same &= c0[i] == rgb565(0, 0, 0);
    for (int i = 0; i < 128 * 128; i++) same &= c1[i] == rgb565(1, 0, 0);
    CHECK(same, "a copy from the game's levels 0 and 1 reads them as written");
    CHECK(pkg_of(&a) && !pkg_of(&a)->md && pkg_of(&a)->md_no == (K ? 1 : 0) && pkg_of(&a)->tex.width == 1024 && pkg_of(&a)->tex.mipmapLevelCount == 11, "the copy made it whole, and it stays so");
    CHECK(atomic_load(&g_md_whole) - whole0 == (K ? 1 : 0) && live0 - atomic_load(&g_md_live_n) == (K ? 1 : 0), "counted as made whole again; one texture fewer held without levels");
    CHECK(atomic_load(&g_mdr_n[MDR_WHOLE]) - why0[MDR_WHOLE] == (K ? 1 : 0), "its upload is counted as made whole for a host use");
    id<MTLTexture> ta2 = by_id(400, &a, NULL); settle();
    CHECK(ta2 && ta2.width == 1024 && reads_level(ta2, s_all, 1024, 0, 0, 0, 0), "its texture ID reads the game's level 0 now");
    os_unfair_lock_lock(&g_rmu); id<MTLTexture> va2 = tex_by_id(401); os_unfair_lock_unlock(&g_rmu);
    CHECK(va2 && va2.width == 1024u >> 3 && va2.parentTexture == pkg_of(&a)->tex, "the other texture IDs over it follow (a view of the whole texture)");
    fill_level(&a, 0, 0, 1);
    id<MTLTexture> ta3 = by_id(400, &a, NULL); settle();
    CHECK(ta3 && ta3.width == 1024 && reads_level(ta3, s_all, 1024, 0, 0, 0, 1), "a CPU write after it re-uploads it whole");

    {   // The long-frame line's split (nvn_lft.h), on the replay thread (this one since mtl_sub_begin): the CPU's deswizzle of an upload, its texture and staging buffer and
        // their residency adds; a wait for a lock another thread holds; not another thread's wait; and the line's part
        nvn_lft l; mtl_lft_take(&l);
        int gpu = g_nvn_deswz_gpu; g_nvn_deswz_gpu = 0;
        static NVNtexture cpu;
        CHECK(make_tex(&cpu, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA8, 256, 256, 1, 1, 0), "RGBA8 256x256 for the CPU's deswizzle");
        id<MTLTexture> tc = by_id(430, &cpu, NULL); settle();
        g_nvn_deswz_gpu = gpu;
        mtl_lft_take(&l);
        CHECK(tc && l.n[LFT_SWZ] == 1 && l.ns[LFT_SWZ] > 0 && l.up[LFT_SWZ] == l.ns[LFT_SWZ], "the CPU's deswizzle of an upload is timed, inside the upload");
        CHECK(l.n[LFT_TEX] == 2 && l.up[LFT_TEX] == l.ns[LFT_TEX] && l.n[LFT_RES] >= 2, "its texture and staging buffer made, and their residency adds");
        dispatch_semaphore_t in = dispatch_semaphore_create(0), out = dispatch_semaphore_create(0);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ pthread_mutex_lock(&g_smu); dispatch_semaphore_signal(in); usleep(30000); pthread_mutex_unlock(&g_smu); });
        dispatch_semaphore_wait(in, DISPATCH_TIME_FOREVER); smu_lock(); pthread_mutex_unlock(&g_smu);
        mtl_lft_take(&l);
        CHECK(l.n[LFT_LOCK] == 1 && l.ns[LFT_LOCK] >= 15000000, "the replay's wait for a lock another thread holds is timed");
        pthread_mutex_lock(&g_smu);
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ smu_lock(); pthread_mutex_unlock(&g_smu); dispatch_semaphore_signal(out); });
        usleep(20000); pthread_mutex_unlock(&g_smu); dispatch_semaphore_wait(out, DISPATCH_TIME_FOREVER);
        mtl_lft_take(&l);
        CHECK(!l.n[LFT_LOCK], "another thread's wait is not");
        nvn_lft z; memset(&z, 0, sizeof z); char line[256];
        CHECK(!nvn_lft_text(line, sizeof line, &z) && !line[0], "the line's part says nothing under 0.5 ms");
        z.n[LFT_TEX] = 3; z.ns[LFT_TEX] = 120400000; z.up[LFT_TEX] = 2100000; z.n[LFT_LOCK] = 4; z.ns[LFT_LOCK] = 210000000; z.drain_ns = 1200000;
        int w = nvn_lft_text(line, sizeof line, &z);
        printf("long-frame split: %s\n", line);
        CHECK(w == (int)strlen(line) && !strcmp(line, "; replay split: textures made 3, 120.4 ms (2.1 in uploads); lock waits 4, 210.0 ms; encode-thread waits 1.2 ms"), "the line's part names each part with a count");
        char tiny[24]; w = nvn_lft_text(tiny, sizeof tiny, &z);
        CHECK(w == (int)sizeof tiny - 1 && strlen(tiny) == sizeof tiny - 1, "a short buffer is cut, not overrun");
    }
    printf("mip drop: %llu held now (%llu KB not allocated), %llu uploads (%llu KB of levels not uploaded), %llu made whole again\n", (unsigned long long)atomic_load(&g_md_live_n),
           (unsigned long long)(atomic_load(&g_md_live_bytes) >> 10), (unsigned long long)atomic_load(&g_md_uploads), (unsigned long long)(atomic_load(&g_md_skip_bytes) >> 10), (unsigned long long)atomic_load(&g_md_whole));
    CHECK(atomic_load(&g_md_live_n) == (K ? 2 : 0) && atomic_load(&g_md_live_bytes) == (K ? md_bytes((tex_t *)&arr, K) + md_bytes((tex_t *)&b, K) : 0), "the memory line's figures: the array and the 2048x1024 texture");
    {   // DM_NVN_MIP_DROP_COMPRESSIBLE (on by default) and DM_NVN_MIP_DROP_PARTIAL (off by default): COMPRESSIBLE beside MINIMAL_LAYOUT, and a 6-level chain that stops at 32 texels.
        // Each is dropped when its switch is on (and the mip drop is), reads the game's level max(L, K) by derivatives, is counted live under its switch in the line's last part;
        // with its switch off it stays whole, counted by its own reason
        int cf_on = md_cflag_on(), p_on = md_partial_on();
        printf("DM_NVN_MIP_DROP_COMPRESSIBLE=%d DM_NVN_MIP_DROP_PARTIAL=%d\n", cf_on, p_on);
        uint64_t c0 = atomic_load(&g_mdr_n[MDR_CFLAG]), s0 = atomic_load(&g_mdr_n[MDR_SHORT]), e1 = atomic_load(&g_md_ext_n[1]), e2 = atomic_load(&g_md_ext_n[2]), live0 = atomic_load(&g_md_live_n);
        static NVNtexture cf, sh, cfi;
        CHECK(make_tex(&cf, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 11, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_MINIMAL_LAYOUT), "BC1 1024x1024 COMPRESSIBLE | MINIMAL_LAYOUT");
        CHECK(make_tex(&sh, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 6, 0), "BC1 1024x1024 with 6 levels (down to 32 texels)");
        CHECK(make_tex(&cfi, NVN_TEXTURE_TARGET_2D, NVN_FORMAT_RGBA_DXT1, 1024, 1024, 1, 11, NVN_TEXTURE_FLAGS_COMPRESSIBLE | NVN_TEXTURE_FLAGS_IMAGE), "BC1 1024x1024 COMPRESSIBLE | IMAGE");
        uint64_t f0 = atomic_load(&g_mdr_n[MDR_FLAGS]);
        id<MTLTexture> tcf = by_id(440, &cf, NULL), tsh = by_id(441, &sh, NULL), tcfi = by_id(442, &cfi, NULL); settle();
        unsigned kc = cf_on ? K : 0, ks = p_on ? K : 0;
        CHECK(tcf && dropped(tcf, &cf, kc), cf_on ? "COMPRESSIBLE: made without its top K levels" : "COMPRESSIBLE with its switch off: made whole");
        CHECK(tsh && dropped(tsh, &sh, ks), p_on ? "a chain that stops early: made without its top K levels" : "a chain that stops early with its switch off: made whole");
        CHECK(tcfi && dropped(tcfi, &cfi, 0) && atomic_load(&g_mdr_n[MDR_FLAGS]) - f0 == (K ? 1 : 0), "COMPRESSIBLE with another flag (IMAGE) stays whole, counted under flags or samples");
        int ok_c = 1; for (unsigned L = 0; L < 11; L++) ok_c &= reads_level(tcf, s_all, 1024, L, 0, MAX(L, kc), 0);
        int ok_s = 1; for (unsigned L = 0; L < 6; L++) ok_s &= reads_level(tsh, s_all, 1024, L, 0, MAX(L, ks), 0);
        CHECK(ok_c && ok_s, "each reads the game's level max(L, K) by its derivatives (L where it is whole), the short chain's last level its own");
        CHECK(atomic_load(&g_mdr_n[MDR_CFLAG]) - c0 == (K && !cf_on) && atomic_load(&g_mdr_n[MDR_SHORT]) - s0 == (K && !p_on), "with a switch off its texture is counted by its own reason");
        CHECK(atomic_load(&g_md_ext_n[1]) - e1 == (kc ? 1 : 0) && atomic_load(&g_md_ext_n[2]) - e2 == (ks ? 1 : 0) && atomic_load(&g_md_live_n) - live0 == (kc ? 1u : 0u) + (ks ? 1u : 0u),
              "each one dropped is counted live under its switch");
        CHECK(atomic_load(&g_md_ext_bytes[1]) == (kc ? md_bytes((tex_t *)&cf, K) : 0) && atomic_load(&g_md_ext_bytes[2]) == (ks ? md_bytes((tex_t *)&sh, K) : 0), "with the bytes of its top levels");
        char ext[256]; md_ext_text(ext, sizeof ext); printf("mip drop switches:%s\n", ext);
        char want[160]; snprintf(want, sizeof want, "through DM_NVN_MIP_DROP_COMPRESSIBLE %d (", kc ? 1 : 0);
        CHECK(cf_on ? strstr(ext, "; of those held now, through DM_NVN_MIP_DROP_COMPRESSIBLE") == ext && strstr(ext, want) : !strstr(ext, "COMPRESSIBLE"), "the line's last part names what the switch saves now");
        CHECK(p_on == !!strstr(ext, "through DM_NVN_MIP_DROP_PARTIAL"), "and the partial chains' only when that switch is on");
    }
    printf("mip drop (K=%u): %d checks, %d failed\n", K, checks, failed);
    return failed != 0;
} }
