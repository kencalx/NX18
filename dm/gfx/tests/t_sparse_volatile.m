// Empty sparse tile heaps marked volatile (nvn_mtl.m sp_vol_sweep_at / spv_take, DM_NVN_SPARSE_VOLATILE). The placement heaps that lazy depth textures and sparse pools take their
// 64 KB tiles from are never freed; a heap every tile of which has been in the free list for SPV_IDLE_NS goes volatile and stays resident, and the first tile taken from it again
// makes it non-volatile, or, when the system emptied it, a new heap takes its index (the old one out of the residency set). Cases: a heap a live lazy texture maps is never marked;
// tiles freed but not yet past the GPU's fence keep it in use; free for less than SPV_IDLE_NS it is not marked, then it is; taken again it is the same heap, non-volatile, and the
// lazy texture that takes it reads 0 (the old texture's 0.75 is gone) and then what is drawn into it; emptied (setPurgeableState:Empty, as the system would) the next take makes a new
// heap whose tiles read 0 and then what is drawn; a memory trim marks an empty heap at once; counts return to 0. --off (DM_NVN_SPARSE_VOLATILE=0): nothing is marked, and the reuse works as before
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("ok: %s\n", label); } while (0)
enum { W = 4096, H = 4096 };   // a 64 MB Depth32F: 1,024 tiles, one whole heap
static id<MTLComputePipelineState> g_tprobe; static id<MTLRenderPipelineState> g_draw_ps; static id<MTLDepthStencilState> g_draw_ds;

static MTLPurgeableState st(id o) { return [(id<MTLHeap>)o setPurgeableState:MTLPurgeableStateKeepCurrent]; }
// Volatile, or emptied already: under memory pressure (other GPU work on the machine) the system may take a volatile heap at any moment, as it would on the phone
static int vol(id o) { MTLPurgeableState s = st(o); return s == MTLPurgeableStateVolatile || s == MTLPurgeableStateEmpty; }
static int resident(id o) { res_mu_lock(); int r = [g_res_objects containsObject:o]; res_mu_unlock(); return r; }
static NvLazy *lz(id<MTLTexture> t) { return lz_of(t, NULL); }
static void settle(void) {   // as t_depth_lazy's: what the GPU is done with is released before a count is read
    rec_drain(); dispatch_sync(g_feedback_q, ^{}); dispatch_sync(res_commit_q(), ^{});
    if (dispatch_group_wait(defer_kick_group(), dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) { checks++; failed++; fprintf(stderr, "FAIL: the drains kicked off the submit thread end within 10 s\n"); }
    while (defer_drain()) {}
    res_commit();
}
static void drains(void) { for (int i = 0; i < 4; i++) { mtl_sub_begin(); mtl_sub_commit(); mtl_drain(); } settle(); }
static id<MTLTexture> lazy_new(uint64_t serial) {   // made by lz_make alone, as t_depth_lazy's freed-tile case
    tex_t pt = {.magic = MAGIC('T', 'E', 'X', 0), .serial = serial};
    pt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_DEPTH32F, .width = W, .height = H, .depth = 1, .levels = 1, .samples = 1};
    return lz_make(&pt, tex_desc(&pt, 0));
}
static void map_all(id<MTLTexture> t) { state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); lz_map_all(lz(t), t, "the test"); mtl_sub_commit(); mtl_drain(); }
static void tdraw(id<MTLTexture> t, float z) {   // the whole texture to depth z
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionLoad; rp.depthAttachment.storeAction = MTLStoreActionStore;
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> e = t4_pass(cb, rp);
    [e setRenderPipelineState:t4_keep(cb, g_draw_ps)]; [e setDepthStencilState:t4_keep(cb, g_draw_ds)];
    [e setViewport:(MTLViewport){0, 0, W, H, 0, 1}]; [e setScissorRect:(MTLScissorRect){0, 0, W, H}];
    t4_bytes(cb, e, T4_FS, &z, 4, 0); [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; t4_end(cb, e);
    CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted, "a depth draw completes");
}
static int reads_value(id<MTLTexture> t, float v) {   // read() at points spread over the texture
    const uint32_t pts[][2] = {{0, 0}, {W - 1, H - 1}, {W / 2, H / 3}, {3000, 700}, {5, H - 7}, {1234, 3456}};
    enum { N = sizeof pts / sizeof *pts };
    id<MTLBuffer> in = [g_dev newBufferWithBytes:pts length:sizeof pts options:MTLResourceStorageModeShared], out = [g_dev newBufferWithLength:N * 4 options:MTLResourceStorageModeShared];
    for (int i = 0; i < N; i++) ((float *)out.contents)[i] = -7;
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_compute(cb);
    [e setComputePipelineState:t4_keep(cb, g_tprobe)]; t4_tex(cb, e, T4_CS, t, 0); t4_buf(cb, e, T4_CS, in, 0, 0); t4_buf(cb, e, T4_CS, out, 0, 1);
    [e dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(N, 1, 1)]; t4_end(cb, e);
    if (t4_wait(cb) != MTLCommandBufferStatusCompleted) return 0;
    int ok = 1; for (int i = 0; i < N; i++) ok &= ((float *)out.contents)[i] == v;
    return ok;
}
static id<MTLHeap> heap0(void) { pthread_mutex_lock(&g_sp_mu); id<MTLHeap> h = g_sp_heaps.count ? g_sp_heaps[0] : nil; pthread_mutex_unlock(&g_sp_mu); return h; }
static NSUInteger nheaps(void) { pthread_mutex_lock(&g_sp_mu); NSUInteger n = g_sp_heaps.count; pthread_mutex_unlock(&g_sp_mu); return n; }
static uint64_t g_t;   // the test's clock for sp_vol_sweep_at
static void sweep(uint64_t step_ns) { g_t += step_ns; sp_vol_sweep_at(g_t); }

int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "--off");
    setenv("DM_NVN_DEPTH_LAZY", "1", 1);
    mtl_init();
    g_spv_test_manual = 1; g_t = clock_gettime_nsec_np(CLOCK_MONOTONIC);
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void probe(depth2d<float> t [[texture(0)]], constant uint2 *pt [[buffer(0)]], device float *o [[buffer(1)]], uint i [[thread_position_in_grid]]) { o[i] = t.read(pt[i]); }\n"
        "struct V { float4 p [[position]]; };\n"
        "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); return { float4(q * 2 - 1, 0, 1) }; }\n"
        "struct F { float d [[depth(any)]]; };\n"
        "fragment F fs(constant float &d [[buffer(0)]]) { return { d }; }\n", nil, &error);
    if (!lib) { printf("t_sparse_volatile: shader compile failed: %s\n", error.localizedDescription.UTF8String); return 1; }
    g_tprobe = t4_cps(t4_fn(lib, @"probe"), &error);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = t4_fn(lib, @"vs"); pd.fragmentFunction = t4_fn(lib, @"fs"); pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    g_draw_ps = t4_rps(pd, &error);
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; g_draw_ds = [g_dev newDepthStencilStateWithDescriptor:dd];
    if (!g_tprobe || !g_draw_ps || !g_draw_ds) { printf("t_sparse_volatile: pipelines failed: %s\n", error.localizedDescription.UTF8String); return 1; }
    CHECK(spv_on() == !off, off ? "DM_NVN_SPARSE_VOLATILE=0: off" : "on by default");

    // A live lazy texture maps every tile of the first heap: it is never marked
    id<MTLHeap> h0 = nil;
    @autoreleasepool {
        id<MTLTexture> a = lazy_new(99801);
        if (!a || !lz(a)) { printf("t_sparse_volatile: this GPU makes no placement sparse Depth32F texture: nothing to test\n"); return 0; }
        map_all(a); tdraw(a, .75f);
        CHECK(reads_value(a, .75f), "the first texture holds what was drawn (0.75)");
        h0 = heap0();
        CHECK(nheaps() == 1 && h0 && resident(h0), "one placement heap, resident");
        for (int i = 0; i < 4; i++) sweep(SPV_IDLE_NS);
        CHECK(st(h0) == MTLPurgeableStateNonVolatile && !atomic_load(&g_spv_vol), "a heap a live texture maps stays non-volatile");
        res_remove(a); res_commit(); a = nil;
    }
    // Freed, but the GPU not yet past the fence of the release: the tiles wait (sp_slot_free) and the heap is in use
    pthread_mutex_lock(&g_sp_mu); size_t late = g_sp_nlate; pthread_mutex_unlock(&g_sp_mu);
    printf("after the release: %zu tiles waiting for the fence\n", late);
    if (late) { for (int i = 0; i < 4; i++) sweep(SPV_IDLE_NS); CHECK(st(h0) == MTLPurgeableStateNonVolatile, "tiles freed behind a fence the GPU has not passed keep the heap non-volatile"); }
    drains();
    // All free: not marked before SPV_IDLE_NS, then marked (on)
    sweep(SPV_EVERY_NS); sweep(SPV_EVERY_NS);
    CHECK(st(h0) == MTLPurgeableStateNonVolatile, "all free for less than SPV_IDLE_NS: not marked");
    sweep(SPV_IDLE_NS);
    uint64_t cvn0 = atomic_load(&g_cv_n);
    if (off) CHECK(st(h0) == MTLPurgeableStateNonVolatile && !atomic_load(&g_spv_marked), "off: an empty heap stays non-volatile");
    else {
        CHECK(vol(h0) && resident(h0), "an empty heap past SPV_IDLE_NS is volatile and still resident");
        CHECK(atomic_load(&g_spv_vol) == 1 && atomic_load(&g_spv_marked) == 1 && cvn0 >= 1 && atomic_load(&g_cv_bytes) >= 64ull << 20, "counted volatile (64 MB)");
    }
    { uint64_t m = atomic_load(&g_spv_marked); sweep(SPV_EVERY_NS); CHECK(atomic_load(&g_spv_marked) == m, "a volatile heap is not marked twice"); }

    // Taken again (the negative control): the same heap, non-volatile before its tiles are mapped; the new texture reads 0 (the freed one's 0.75 is gone), then what is drawn
    @autoreleasepool {
        id<MTLTexture> b = lazy_new(99802);
        map_all(b);
        // the system may have taken the volatile heap meanwhile (memory pressure on a loaded machine): then a new heap is in its index, which is the path checked below on purpose
        uint64_t sys = atomic_load(&g_spv_emptied);
        if (sys) printf("note: the system emptied the volatile heap before it was taken again (memory pressure): a new heap took its index\n");
        CHECK(sys <= 1 && (sys ? heap0() != h0 : heap0() == h0) && nheaps() == 1 && st(heap0()) == MTLPurgeableStateNonVolatile, "taken again: the same heap (or, emptied by the system, a new one), non-volatile, no heap added");
        CHECK(!atomic_load(&g_spv_vol) && atomic_load(&g_cv_n) == (off ? cvn0 : cvn0 - 1), "no longer counted volatile");
        h0 = heap0();
        CHECK(reads_value(b, 0), "its tiles, which held 0.75 in the freed texture, read 0");
        tdraw(b, .25f);
        CHECK(reads_value(b, .25f), "and then what is drawn into them (0.25)");
        res_remove(b); res_commit(); b = nil;
    }
    drains();
    // A memory trim marks an empty heap at once, before SPV_IDLE_NS
    mtl_trim(4);
    if (off) CHECK(st(h0) == MTLPurgeableStateNonVolatile, "off: a memory trim leaves the empty heap non-volatile");
    if (!off) {
        uint64_t e0 = atomic_load(&g_spv_emptied);
        CHECK(vol(h0) && atomic_load(&g_spv_vol) == 1, "empty again: a memory trim marks it volatile at once");
        // The system empties it (forced: the kernel cannot be made to purge on demand): the next take makes a new heap in its place
        [h0 setPurgeableState:MTLPurgeableStateEmpty];
        @autoreleasepool {
            id<MTLTexture> c = lazy_new(99803);
            map_all(c);
            id<MTLHeap> h1 = heap0(); settle();
            CHECK(h1 && h1 != h0 && nheaps() == 1 && st(h1) == MTLPurgeableStateNonVolatile, "emptied: a new heap takes its index");
            CHECK(!resident(h0) && resident(h1), "the emptied heap left the residency set, the new one is in");
            CHECK(atomic_load(&g_spv_emptied) == e0 + 1 && !atomic_load(&g_spv_vol), "counted emptied and made again");
            CHECK(reads_value(c, 0), "the new heap's tiles read 0");
            tdraw(c, .5f);
            CHECK(reads_value(c, .5f), "and then what is drawn into them (0.5)");
            res_remove(c); res_commit(); c = nil;
        }
        drains();
        // The test hook (cv_back's g_cv_test_empty) takes the same path
        h0 = heap0(); sweep(SPV_EVERY_NS); sweep(SPV_IDLE_NS); sweep(SPV_EVERY_NS);
        CHECK(vol(h0), "the new heap, empty, goes volatile too");
        atomic_store(&g_cv_test_empty, 1);
        @autoreleasepool {
            id<MTLTexture> d = lazy_new(99804);
            map_all(d);
            CHECK(heap0() != h0 && atomic_load(&g_spv_emptied) == e0 + 2 && reads_value(d, 0), "hook: a new heap, its tiles read 0");
            tdraw(d, .125f); CHECK(reads_value(d, .125f), "hook: what is drawn reads back");
            res_remove(d); res_commit(); d = nil;
        }
        drains();
    }
    CHECK(!atomic_load(&g_spv_vol), "nothing counted volatile once every heap was taken again");
    printf("t_sparse_volatile%s: %d checks, %d failed; %llu marked, %llu emptied and made again\n", off ? " (off)" : "", checks, failed,
           (unsigned long long)atomic_load(&g_spv_marked), (unsigned long long)atomic_load(&g_spv_emptied));
    return failed ? 1 : 0;
} }
