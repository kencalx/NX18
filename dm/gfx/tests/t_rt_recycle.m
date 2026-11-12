// Recycled texture memory (nvn_mtl.m rh_texture, rh_place, GitHub issues #1831, #1823): a shared texture in a GPU-only pool is made in a placement heap of its own, an eighth larger
// than the texture; once its texture is freed the heap stays resident, and the smallest waiting heap that fits, up to half as large again, takes the next texture, cleared as a new
// allocation is: one a step of Metal's sizes larger included, COMPRESSIBLE or not. Same-pass feedback snapshots draw from the same heaps. Heaps that wait too long leave the
// residency set when a submission begins. CPU-visible pools, block-compressed textures and DM_NVN_RT_RECYCLE=0 keep allocations of their own. The waiting heaps stay under the cap after a
// submission begins: 256 MB on the Mac, on iOS 256 MB down to 32 MB as the headroom to the memory limit falls from 3 GB to 1 GB (a stand-in headroom here), DM_NVN_RT_RECYCLE_CAP=<MB> fixed.
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static tex_t target(pool_t *pool, uint64_t serial, uint64_t off, unsigned w, unsigned h) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA16F, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); return t;
}
static int resident(id o) { pthread_mutex_lock(&g_res_mu); int r = [g_res_objects containsObject:o]; pthread_mutex_unlock(&g_res_mu); return r; }
static unsigned waiting(void) { os_unfair_lock_lock(&g_rh_lk); unsigned n = g_rh_n; os_unfair_lock_unlock(&g_rh_lk); return n; }
static void settle(void) {   // the released textures' fences pass and the deferred releases run (as in t_image_alias)
    mtl_sub_commit(); mtl_drain(); mtl_sub_begin(); mtl_sub_commit(); mtl_drain();
    dispatch_sync(g_feedback_q, ^{}); defer_drain(); mtl_sub_begin();
}
static void fill(id<MTLTexture> t, uint8_t v) {
    NSUInteger row = t.width * 8, bytes = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; memset(b.contents, v, bytes); res_add(b);
    enc_b_copy_buffer_texture(blit(), b, 0, row, bytes, MTLSizeMake(t.width, t.height, 1), t, 0, 0, MTLOriginMake(0, 0, 0));
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the fill completes without GPU error"); res_remove(b); mtl_sub_begin();
}
static int all_zero(id<MTLTexture> t) {
    NSUInteger row = t.width * 8, bytes = row * t.height;
    id<MTLBuffer> b = [g_dev newBufferWithLength:bytes options:MTLResourceStorageModeShared]; res_add(b);
    enc_b_copy_texture_buffer(blit(), t, 0, 0, MTLOriginMake(0, 0, 0), MTLSizeMake(t.width, t.height, 1), b, 0, row, bytes);
    mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the read completes without GPU error"); res_remove(b); mtl_sub_begin();
    const uint8_t *p = b.contents; for (NSUInteger i = 0; i < bytes; i++) if (p[i]) return 0;
    return 1;
}

static uint64_t g_fake_avail;
static uint64_t fake_avail(void) { return g_fake_avail; }
// The cap the waiting heaps keep to after a submission begins. Eight 1080p RGBA16F targets (about 16 MB each) are freed together: with a stand-in headroom of 512 MB (iOS near its limit)
// at most 32 MB of them wait; with 8 GB (an iPhone in the usual case) and on the Mac, all of them, under 256 MB; DM_NVN_RT_RECYCLE_CAP fixes the cap whatever the headroom
static void cap_cases(pool_t *pool) {
    const char *e = getenv("DM_NVN_RT_RECYCLE_CAP"); int64_t fixed = e && *e ? (int64_t)atoll(e) << 20 : -1;
    CHECK(rh_cap_for(8ull << 30) == 256u << 20 && rh_cap_for(3ull << 30) == 256u << 20, "3 GB of headroom or more: 256 MB");
    CHECK(rh_cap_for(1ull << 30) == 32u << 20 && rh_cap_for(200ull << 20) == 32u << 20, "1 GB or less: 32 MB");
    CHECK(rh_cap_for(2ull << 30) == 144u << 20, "2 GB: half way, 144 MB");
    for (int round = 0; round < 3; round++) {
        uint64_t avail = round == 0 ? 0 : round == 1 ? 512ull << 20 : 8ull << 30;   // 0: no headroom source (the Mac)
        g_rh_avail = round ? fake_avail : NULL; g_fake_avail = avail; g_rh_cap_at = 0;
        uint64_t want = fixed >= 0 ? (uint64_t)fixed : round == 1 ? 32u << 20 : 256u << 20;
        tex_t t[8]; uint64_t total = 0; __strong id<MTLTexture> keep[8];
        for (int i = 0; i < 8; i++) { t[i] = target(pool, 96000 + 16 * (uint64_t)round + (uint64_t)i, (uint64_t)i << 21, 1920, 1080); mtl_tex_init(&t[i]); keep[i] = tex_mtl(&t[i]); total += keep[i].heap.size; }
        CHECK(keep[7] && keep[7].heap, "eight targets in heaps of their own");
        for (int i = 0; i < 8; i++) { keep[i] = nil; mtl_tex_release(&t[i]); }
        mtl_alias_drop_pool(pool); settle();   // settle ends with a submission beginning: rh_trim
        os_unfair_lock_lock(&g_rh_lk); uint64_t wb = g_rh_bytes; unsigned wn = g_rh_n; os_unfair_lock_unlock(&g_rh_lk);
        char m[160]; snprintf(m, sizeof m, "headroom %llu MB: waiting %llu MB within the cap of %llu MB after a submission begins", (unsigned long long)(avail >> 20), (unsigned long long)(wb >> 20), (unsigned long long)(want >> 20));
        CHECK(wb <= want && atomic_load(&g_rh_cap_now) == want, m);
        if (want >= total) CHECK(wn == 8 && wb == total, "all eight wait when they fit under the cap");
        else CHECK(wb + total / 8 > want, "the cap is filled, not emptied: only the oldest past it go");
        printf("cap round %d (headroom %llu MB): %u heaps wait, %llu MB of %llu MB freed together, cap %llu MB\n", round, (unsigned long long)(avail >> 20), wn, (unsigned long long)(wb >> 20), (unsigned long long)(total >> 20), (unsigned long long)(atomic_load(&g_rh_cap_now) >> 20));
        os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; i < g_rh_n; i++) g_rh[i].t -= RH_IDLE_NS; os_unfair_lock_unlock(&g_rh_lk);
        mtl_sub_commit(); mtl_drain(); mtl_sub_begin();   // the next round starts with none waiting
        CHECK(waiting() == 0, "the idle heaps go before the next round");
    }
    // With no heap waiting the cap still follows the headroom: the memory line's cap reads the headroom of now, not of the last time a heap waited. Round 2 left 256 MB (8 GB of headroom)
    g_rh_avail = fake_avail; g_fake_avail = 512ull << 20; g_rh_cap_at = 0;
    mtl_sub_commit(); mtl_drain(); mtl_sub_begin();   // rh_trim with none waiting
    CHECK(waiting() == 0 && atomic_load(&g_rh_cap_now) == (fixed >= 0 ? (uint64_t)fixed : 32u << 20), "none waiting: the headroom falling to 512 MB lowers the memory line's cap to 32 MB at the next submission's start");
    printf("cap with none waiting (headroom 512 MB): %llu MB\n", (unsigned long long)(atomic_load(&g_rh_cap_now) >> 20));
    g_rh_avail = NULL;
}

int main(void) { @autoreleasepool {
    mtl_init(); void *mem = NULL; posix_memalign(&mem, 16384, 64 << 20); memset(mem, 0, 64 << 20);
    pool_t pool = {.magic = MAGIC('P','O','O','L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE, .mem = mem, .size = 64 << 20};
    mtl_sub_begin();
    if (!sw_on(rh_mode())) {   // DM_NVN_RT_RECYCLE=0
        tex_t a = target(&pool, 95001, 0, 640, 360); mtl_tex_init(&a);
        CHECK(tex_mtl(&a) && !tex_mtl(&a).heap && g_rh_made == 0, "with the switch off a target is its own allocation");
        mtl_tex_release(&a); mtl_alias_drop_pool(&pool); settle();
        printf("t_rt_recycle (off): %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    __weak id<MTLHeap> first_heap;
    {
        tex_t a = target(&pool, 95001, 0, 640, 360); mtl_tex_init(&a);
        id<MTLTexture> ta = tex_mtl(&a);
        CHECK(ta && ta.heap && ta.width == 640 && ta.height == 360, "a GPU-only pool's target is placed in a heap of its own, at its own size");
        CHECK(resident(ta.heap) && !resident(ta), "its heap is what the residency set holds");
        CHECK(g_rh_made == 1 && g_rh_reused == 0, "a new heap is counted as made");
        MTLSizeAndAlign need = [g_dev heapTextureSizeAndAlignWithDescriptor:tex_desc(&a, 0)];
        CHECK(ta.heap.size >= need.size + need.size / 8, "the heap is made an eighth larger than its first target");
        fill(ta, 0x5a);
        first_heap = ta.heap;
        ta = nil; mtl_tex_release(&a); mtl_alias_drop_pool(&pool);   // the pool goes: the sharing table lets its texture go (deferred)
        settle();
    }
    CHECK(first_heap && waiting() == 1, "once its texture is freed the heap waits");
    CHECK(first_heap && resident(first_heap), "and stays resident while it waits");
    {
        tex_t b = target(&pool, 95002, 8 << 20, 632, 356); mtl_tex_init(&b);   // another place, a slightly smaller size
        id<MTLTexture> tb = tex_mtl(&b);
        CHECK(tb && tb.heap == first_heap && g_rh_reused == 1 && waiting() == 0, "the next target that fits is placed in the waiting heap");
        CHECK(tb.width == 632 && tb.height == 356, "at its own size");
        CHECK(all_zero(tb), "and is cleared as a new allocation is: nothing of the old target's pixels is read");
        tex_t c = target(&pool, 95003, 16 << 20, 1280, 720); mtl_tex_init(&c);
        id<MTLTexture> tc = tex_mtl(&c);
        CHECK(tc && tc.heap && tc.heap != tb.heap && g_rh_made == 2, "a target the waiting heaps cannot hold gets a new heap");
        tb = nil; tc = nil; mtl_tex_release(&b); mtl_tex_release(&c); mtl_alias_drop_pool(&pool);
        settle();
    }
    CHECK(waiting() == 2, "both heaps wait");
    {   // a heap more than an eighth larger than the target is not taken
        tex_t d = target(&pool, 95004, 0, 160, 90); mtl_tex_init(&d);
        id<MTLTexture> td = tex_mtl(&d);
        CHECK(td && td.heap && g_rh_made == 3 && waiting() == 2, "a much smaller target leaves the waiting heaps alone");
        td = nil; mtl_tex_release(&d); mtl_alias_drop_pool(&pool); settle();
    }
    {   // outside: a CPU-visible pool; inside: a texture without COMPRESSIBLE
        pool_t cpu = pool; cpu.flags = NVN_MEMORY_POOL_FLAGS_CPU_CACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE;
        tex_t e = target(&cpu, 95005, 0, 640, 360); mtl_tex_init(&e);
        CHECK(tex_mtl(&e) && !tex_mtl(&e).heap, "a CPU-visible pool's texture keeps its own allocation");
        tex_t f = target(&pool, 95006, 24 << 20, 644, 360); f.d.flags = 0; mtl_tex_init(&f);   // one step of Metal's sizes above the first target (1,982,464 -> 2,179,072 bytes on an M6)
        CHECK(tex_mtl(&f) && tex_mtl(&f).heap == first_heap, "a texture without COMPRESSIBLE, a size step larger than the heap's first target, takes the waiting heap");
        tex_t g = target(&pool, 95008, 32 << 20, 512, 512); g.d.flags = 0; g.d.format = NVN_FORMAT_RGBA_DXT1; nvn_tex_layout(&g.d, &g.L); mtl_tex_init(&g);
        CHECK(tex_mtl(&g) && !tex_mtl(&g).heap, "a block-compressed texture (an asset, never rendered to) keeps its own allocation");
        mtl_tex_release(&e); mtl_tex_release(&f); mtl_tex_release(&g); mtl_alias_drop_pool(&cpu); mtl_alias_drop_pool(&pool); settle();
    }
    unsigned before = waiting();
    CHECK(before == 3, "three heaps wait");
    os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; i < g_rh_n; i++) g_rh[i].t -= RH_IDLE_NS; os_unfair_lock_unlock(&g_rh_lk);
    mtl_sub_commit(); mtl_drain(); mtl_sub_begin();   // rh_trim
    CHECK(waiting() == 0 && g_rh_trimmed == before && g_rh_bytes == 0, "heaps that waited too long are freed when a submission begins");
    CHECK(!first_heap || !resident(first_heap), "and leave the residency set");
    cap_cases(&pool);
    {   // a same-pass feedback snapshot is placed in recycled memory, and its heap waits once the snapshot goes
        int fresh = 0; uint64_t made = g_rh_made; fb_cache_t *e = fb_snap(95007, 0, 0, MTLPixelFormatRGBA16Float, 640, 360, 1, &fresh);
        CHECK(e && fresh && e->snap.heap && g_rh_made == made + 1 && resident(e->snap.heap), "a snapshot is placed in a recycled heap, resident");
        if (e) { defer_obj_release(e->snap); e->snap = nil; e->ser = 0; }
        settle();
        CHECK(waiting() == 1, "its heap waits once the snapshot is freed");
    }
    mtl_sub_commit(); mtl_drain(); free(mem);
    printf("t_rt_recycle: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
