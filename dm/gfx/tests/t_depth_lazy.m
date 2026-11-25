// DM_NVN_DEPTH_LAZY (profile key depth_lazy): a single-sample 2D Depth16 / Depth32F texture of 64 MB or more is made a placement sparse texture with no tile mapped (lz_make), and
// tiles are mapped and zeroed where the GPU is about to write something other than zero (lz_map). Each case runs the same operations on a lazy texture and on the texture the host
// makes without the switch (zeroed whole), and every texel of the two must match: read() at integer coordinates, plain samples and comparison samples. Cases: a new texture reads 0
// with no tile mapped (a 4096x4096 Depth32F and Ocarina of Time's 12288x12288 Depth16); draws through lz_draw (a scissored one, one bounded only by its viewport, one with no
// depth write) map only the tiles under them; tiles that come back from a freed lazy texture holding other depth are zeroed when mapped again; production clears (a whole one
// to 0 maps nothing, a scissored one maps its tiles, a whole one to another value makes it a normal texture, lz_whole, which takes every name of the lazy one: the serial, a texture
// sharing its storage, a texture ID; the lazy one and its tiles go once the GPU is done); a whole clear to another value keeps it lazy where its mapped tiles or the heaps' free
// ones hold most of it (lz_whole_pays: every tile mapped by a draw first; a freed texture's tiles free in the heaps); a texture clear of the whole level to 0 maps nothing, to
// another value makes it a normal texture, and one of a part or a channel mask (which clear_tex does not draw for depth) maps nothing; Ocarina of Time's save load (a 12288x12288
// Depth16 whose first use is a whole clear to a non-zero depth: no tile mapped, no heap made); a texture copy into it maps every tile; a copy out of an unmapped region reads 0; the
// switch off, the profile's default and a GPU without such textures (the fallback, a normal texture); a pool finalized before its texture objects takes a lazy one and a normal one
// made of one with it, and a pinned one cleared whole to another depth after that is neither made a normal texture nor mapped
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } else printf("ok: %s\n", label); } while (0)

static id<MTLComputePipelineState> g_diff, g_lzprobe;
static id<MTLRenderPipelineState> g_draw_ps; static id<MTLDepthStencilState> g_draw_ds;
enum { W = 4096, H = 4096 };

static void lz_reset(const char *v) { if (v) setenv("DM_NVN_DEPTH_LAZY", v, 1); else unsetenv("DM_NVN_DEPTH_LAZY"); g_lz_on = -1; }
static id<MTLTexture> make(tex_t *t, uint64_t serial, int format, unsigned w, unsigned h) {   // through the host's own path (tex_mtl), as a game's texture
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = serial; t->off = serial << 24;   // its own storage: the sharing table keys textures by pool, offset and description
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE};
    mtl_tex_init(t);
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    id<MTLTexture> mt = tex_mtl(t);
    mtl_sub_commit(); mtl_drain();
    return mt;
}
static NvLazy *lz(id<MTLTexture> t) { return lz_of(t, NULL); }
static void make_in(tex_t *t, pool_t *pool, uint64_t serial, int format, unsigned w, unsigned h) {   // a texture object of a memory pool, made by nothing yet
    memset(t, 0, sizeof *t); t->magic = MAGIC('T', 'E', 'X', 0); t->serial = serial; t->pool = pool; t->off = (int64_t)(serial & 0xff) << 24;
    t->d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = format, .width = w, .height = h, .depth = 1, .levels = 1, .samples = 1, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE};
    mtl_tex_init(t);
}
static int live_entry(uint64_t k) { pthread_mutex_lock(&g_smu); int r = nvn_hm_get(&g_by_serial, &k) != NULL; pthread_mutex_unlock(&g_smu); return r; }
static int ghost_entry(uint64_t k) { pthread_mutex_lock(&g_smu); int r = nvn_hm_get(&g_ghost, &k) != NULL; pthread_mutex_unlock(&g_smu); return r; }
static int rh_waits(id h) { int w = 0; os_unfair_lock_lock(&g_rh_lk); for (unsigned i = 0; h && i < g_rh_n && !w; i++) w = g_rh[i].heap == (__bridge void *)h; os_unfair_lock_unlock(&g_rh_lk); return w; }   // a recycled heap handed back for reuse
// A game thread's Finalize of g_race_pool landing once a whole clear has read the pool as live (nvn_mtl.m g_pool_read_after), once; and the texture object's own Finalize after it
// when g_race_tex is set
static pool_t *g_race_pool; static tex_t *g_race_tex;
static void race_finalize(const void *pool) {
    if (!g_race_pool || pool != g_race_pool) return;
    g_race_pool->magic = 0; mtl_alias_drop_pool(g_race_pool); g_race_pool = NULL;   // nvnMemoryPoolFinalize: the magic goes, then the replay forgets the pool
    if (g_race_tex) { mtl_tex_release(g_race_tex); g_race_tex = NULL; }
}
// Texels where a and b differ (read() of every texel), and where their plain and comparison samples at the texel centres differ
static void diff(id<MTLTexture> a, id<MTLTexture> b, uint32_t out[3]) {
    id<MTLBuffer> r = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(r.contents, 0, 16);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_compute(cb);
    [e setComputePipelineState:t4_keep(cb, g_diff)]; t4_tex(cb, e, T4_CS, a, 0); t4_tex(cb, e, T4_CS, b, 1); t4_buf(cb, e, T4_CS, r, 0, 0);
    [e dispatchThreads:MTLSizeMake(a.width, a.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; t4_end(cb, e);
    CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted, "the comparison runs on the GPU");
    memcpy(out, r.contents, 12);
}
// Read() at integer points far into the texture, a plain sample and a comparison sample at their centres: the values a texture holding v everywhere gives
static int reads_value(id<MTLTexture> t, float v) {
    const uint32_t pts[][2] = {{0, 0}, {(uint32_t)t.width - 1, (uint32_t)t.height - 1}, {(uint32_t)t.width / 2, (uint32_t)t.height / 3}, {9000 % (uint32_t)t.width, 7000 % (uint32_t)t.height}, {5, (uint32_t)t.height - 7}};
    enum { N = sizeof pts / sizeof *pts };
    id<MTLBuffer> in = [g_dev newBufferWithBytes:pts length:sizeof pts options:MTLResourceStorageModeShared], out = [g_dev newBufferWithLength:N * 16 options:MTLResourceStorageModeShared];
    for (int i = 0; i < N * 4; i++) ((float *)out.contents)[i] = -7;
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_compute(cb);
    [e setComputePipelineState:t4_keep(cb, g_lzprobe)]; t4_tex(cb, e, T4_CS, t, 0); t4_buf(cb, e, T4_CS, in, 0, 0); t4_buf(cb, e, T4_CS, out, 0, 1);
    [e dispatchThreads:MTLSizeMake(N, 1, 1) threadsPerThreadgroup:MTLSizeMake(N, 1, 1)]; t4_end(cb, e);
    if (t4_wait(cb) != MTLCommandBufferStatusCompleted) return 0;
    const float *o = out.contents; int ok = 1;
    for (int i = 0; i < N; i++) ok &= o[4 * i] == v && o[4 * i + 1] == v && o[4 * i + 2] == (.5f > v) && o[4 * i + 3] == (0.f > v);   // read, sample, compare (0.5 > v), compare (0 > v)
    return ok;
}
static int reads_zero(id<MTLTexture> t) { return reads_value(t, 0); }
// Whether the serial table's note log holds a note for serial after generation g0 (ser_note: its texture IDs and pool entries alone are taken again)
static int noted_since(uint64_t serial, uint64_t g0) {
    int hit = 0; os_unfair_lock_lock(&g_snote_lk);
    for (uint64_t g = g0 + 1; g <= g_ser_gen && !hit; g++) hit = g_ser_log[g % SER_LOG].gen == g && g_ser_log[g % SER_LOG].serial == serial;
    os_unfair_lock_unlock(&g_snote_lk); return hit;
}
static id<MTLTexture> by_id(int tid) { os_unfair_lock_lock(&g_rmu); id<MTLTexture> t = tex_by_id(tid); os_unfair_lock_unlock(&g_rmu); return t; }
// What the GPU is done with is released before a count is read: mtl_drain waits for the GPU, and the releases its fences let go follow off this thread. The encode thread has made
// its calls (its blocks' autorelease pools drained), the feedback handlers have run (each drains what its fence let go), so have the residency commits they handed on (res_commit_q)
// and the drains they kicked off the submit thread (defer_kick_group), whose residency commit drops the last reference to what it retires, on a utility thread; what is left is
// drained and committed here. Read right after mtl_drain, the counts met a lazy texture such a commit freed later (its NvLazy still counted live, its tiles mapped): the pool
// case's failed up to 1 run in 10 under load, the save-load and freed-tile cases' about 1 in 150
static void settle(void) {
    rec_drain(); dispatch_sync(g_feedback_q, ^{}); dispatch_sync(res_commit_q(), ^{});
    if (dispatch_group_wait(defer_kick_group(), dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC))) { checks++; failed++; fprintf(stderr, "FAIL: the drains kicked off the submit thread end within 10 s\n"); }
    while (defer_drain()) {}   // entries handed back while another thread held g_smu are taken again
    res_commit();
}
static void drains(void) { for (int i = 0; i < 4; i++) { mtl_sub_begin(); mtl_sub_commit(); mtl_drain(); } settle(); }
// Tiles of the heaps' free list the test takes, as another sparse texture would, so that a whole clear finds none free (lz_whole_pays); unhold gives them back
static uint32_t *g_held; static size_t g_nheld, g_heldcap;
static uint64_t free_now(void) { pthread_mutex_lock(&g_sp_mu); uint64_t n = sp_free_now(); pthread_mutex_unlock(&g_sp_mu); return n; }
static void hold_free(void) {
    pthread_mutex_lock(&g_sp_mu);
    for (uint32_t s; sp_free_now() && sp_slot(&s);) { if (g_nheld == g_heldcap) { g_heldcap = g_heldcap ? 2 * g_heldcap : 1024; g_held = realloc(g_held, g_heldcap * sizeof *g_held); } g_held[g_nheld++] = s; }
    pthread_mutex_unlock(&g_sp_mu);
}
static void unhold(void) { pthread_mutex_lock(&g_sp_mu); for (size_t i = 0; i < g_nheld; i++) sp_release(g_held[i]); g_nheld = 0; pthread_mutex_unlock(&g_sp_mu); drains(); }
// A draw that writes depth z through a pass on t, scissored to sc and with the viewport vp: the GPU half of a draw whose host half is lz_draw
static void t_draw(id<MTLTexture> t, MTLScissorRect sc, MTLViewport vp, float z) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.depthAttachment.texture = t; rp.depthAttachment.loadAction = MTLLoadActionLoad; rp.depthAttachment.storeAction = MTLStoreActionStore;
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> e = t4_pass(cb, rp);
    [e setRenderPipelineState:t4_keep(cb, g_draw_ps)]; [e setDepthStencilState:t4_keep(cb, g_draw_ds)]; [e setViewport:vp]; [e setScissorRect:sc];
    t4_bytes(cb, e, T4_FS, &z, 4, 0); [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; t4_end(cb, e);
    CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted, "a depth draw completes");
}
// The host half of a draw: the pass's depth attachment is t, the draw writes depth or not, under the scissor sc and the viewport vp (lz_draw), then the queue's mapping and the zeroing run
static void host_draw(id<MTLTexture> t, int writes, MTLScissorRect sc, MTLViewport vp) {
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
    memset(&g_pass, 0, sizeof g_pass); { id<MTLTexture> root = nil; g_pass.lz = lz_of(t, &root); g_pass.lz_tex = root; }
    S.ds.dt = 1; S.ds.dw = writes;
    double v[4] = {MIN(vp.originX, vp.originX + vp.width), MIN(vp.originY, vp.originY + vp.height), MAX(vp.originX, vp.originX + vp.width), MAX(vp.originY, vp.originY + vp.height)};
    lz_draw(sc, v);
    memset(&g_pass, 0, sizeof g_pass);
    mtl_sub_commit(); mtl_drain();
}
static uint32_t tiles_in(NvLazy *z, long x0, long y0, long x1, long y1) {   // tiles a pixel rectangle touches, within the texture
    x0 = MAX(x0, 0); y0 = MAX(y0, 0); x1 = MIN(x1, (long)z->w); y1 = MIN(y1, (long)z->h);
    return x1 <= x0 || y1 <= y0 ? 0 : (uint32_t)(((x1 - 1) / z->tw - x0 / z->tw + 1) * ((y1 - 1) / z->th - y0 / z->th + 1));
}
static void exec_ops(const void *ops) { mtl_exec(ops); mtl_sub_commit(); mtl_drain(); CHECK(!mtl_last_commit_error(), "the production operations complete without a GPU error"); }
static void t_clear_ds(tex_t *t, float depth, int has_sc, p_scissor sc) {   // nvnCommandBufferClearDepthStencil through the replay
    struct { op_hdr rh; p_set_rt rt; op_hdr ch; p_clear_ds c; op_hdr end; } ops = {0};
    ops.rh = (op_hdr){OP_SET_RT, sizeof(op_hdr) + sizeof(p_set_rt)}; ops.rt = (p_set_rt){.depth = t};
    ops.ch = (op_hdr){OP_CLEAR_DS, sizeof(op_hdr) + sizeof(p_clear_ds)}; ops.c = (p_clear_ds){.depth = depth, .depth_mask = 1};
    ops.end = (op_hdr){OP_END, sizeof(op_hdr)};
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); R.has_sc = has_sc; R.sc = sc;
    if (has_sc) { R.has_rt = 1; R.rt.depth = t; CHECK(rp_begin() != nil, "a pass on the target is open before the scissored clear"); }
    exec_ops(&ops);
}
static void t_clear_tex_r(tex_t *t, float depth, NVNcopyRegion r, int mask, int view_fmt) {   // nvnCommandBufferClearTexture of a region, a channel mask, through a view of a format (0: none)
    struct { op_hdr h; p_clear_tex c; op_hdr end; } ops = {0};
    ops.h = (op_hdr){OP_CLEAR_TEX, sizeof(op_hdr) + sizeof(p_clear_tex)}; ops.c = (p_clear_tex){.tex = t, .mask = mask, .r = r}; ops.c.c.f[0] = depth;
    if (view_fmt) { ops.c.has_view = 1; ops.c.view.set_format = 1; ops.c.view.format = view_fmt; }
    ops.end = (op_hdr){OP_END, sizeof(op_hdr)};
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); exec_ops(&ops);
}
static void t_clear_tex(tex_t *t, float depth) { t_clear_tex_r(t, depth, (NVNcopyRegion){0, 0, 0, (int)t->d.width, (int)t->d.height, 1}, 15, 0); }   // of the whole level
static void t_copy_t2t(tex_t *src, tex_t *dst, NVNcopyRegion r) {   // nvnCommandBufferCopyTextureToTexture, the same region in both
    struct { op_hdr h; p_copy_t2t c; op_hdr end; } ops = {0};
    ops.h = (op_hdr){OP_COPY_T2T, sizeof(op_hdr) + sizeof(p_copy_t2t)}; ops.c = (p_copy_t2t){.src = src, .dst = dst, .sr = r, .dr = r};
    ops.end = (op_hdr){OP_END, sizeof(op_hdr)};
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); exec_ops(&ops);
}
static void matches(id<MTLTexture> a, id<MTLTexture> b, const char *label) {
    uint32_t d[3]; diff(a, b, d); char l[300];
    snprintf(l, sizeof l, "%s: every texel matches the texture backed whole (read %u, sample %u, compare %u differ)", label, d[0], d[1], d[2]);
    CHECK(!d[0] && !d[1] && !d[2], l);
}

int main(void) { @autoreleasepool {
    mtl_init();
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "constexpr sampler plain(filter::nearest, coord::normalized); constexpr sampler cmp_gt(filter::linear, compare_func::greater, coord::normalized);\n"
        "kernel void diff(depth2d<float> a [[texture(0)]], depth2d<float> b [[texture(1)]], device atomic_uint *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {\n"
        "  if (p.x >= a.get_width() || p.y >= a.get_height()) return; float2 uv = (float2(p) + 0.5) / float2(a.get_width(), a.get_height());\n"
        "  if (a.read(p) != b.read(p)) atomic_fetch_add_explicit(&o[0], 1u, memory_order_relaxed);\n"
        "  if (a.sample(plain, uv) != b.sample(plain, uv)) atomic_fetch_add_explicit(&o[1], 1u, memory_order_relaxed);\n"
        "  if (a.sample_compare(cmp_gt, uv, 0.3) != b.sample_compare(cmp_gt, uv, 0.3)) atomic_fetch_add_explicit(&o[2], 1u, memory_order_relaxed); }\n"
        "kernel void probe(depth2d<float> t [[texture(0)]], constant uint2 *pt [[buffer(0)]], device float4 *o [[buffer(1)]], uint i [[thread_position_in_grid]]) {\n"
        "  float2 uv = (float2(pt[i]) + 0.5) / float2(t.get_width(), t.get_height());\n"
        "  o[i] = float4(t.read(pt[i]), t.sample(plain, uv), t.sample_compare(cmp_gt, uv, 0.5), t.sample_compare(cmp_gt, uv, 0.0)); }\n"
        "struct V { float4 p [[position]]; };\n"
        "vertex V vs(uint i [[vertex_id]]) { float2 q = float2((i << 1) & 2, i & 2); return { float4(q * 2 - 1, 0, 1) }; }\n"
        "struct F { float d [[depth(any)]]; };\n"
        "fragment F fs(constant float &d [[buffer(0)]]) { return { d }; }\n", nil, &error);
    if (!lib) { printf("t_depth_lazy: shader compile failed: %s\n", error.localizedDescription.UTF8String); return 1; }
    g_diff = t4_cps(t4_fn(lib, @"diff"), &error); g_lzprobe = t4_cps(t4_fn(lib, @"probe"), &error);
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new];
    pd.vertexFunction = t4_fn(lib, @"vs"); pd.fragmentFunction = t4_fn(lib, @"fs"); pd.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    g_draw_ps = t4_rps(pd, &error);
    MTLDepthStencilDescriptor *dd = [MTLDepthStencilDescriptor new]; dd.depthCompareFunction = MTLCompareFunctionAlways; dd.depthWriteEnabled = YES; g_draw_ds = [g_dev newDepthStencilStateWithDescriptor:dd];
    if (!g_diff || !g_lzprobe || !g_draw_ps || !g_draw_ds) { printf("t_depth_lazy: pipelines failed: %s\n", error.localizedDescription.UTF8String); return 1; }

    // The default and the switch
    lz_reset(NULL); CHECK(depth_lazy_on() == DM_GAME_DEPTH_LAZY && !g_lz_env, "unset, the switch leaves the profile's depth_lazy");
    lz_reset("0"); CHECK(depth_lazy_on() == 0 && g_lz_env, "DM_NVN_DEPTH_LAZY=0: off");
    tex_t off; id<MTLTexture> plain = make(&off, 99701, NVN_FORMAT_DEPTH32F, W, H);
    CHECK(plain && !plain.isSparse && !lz(plain), "switch off: a 64 MB depth texture is made as before, backed whole");
    lz_reset("1"); CHECK(depth_lazy_on() == 1, "DM_NVN_DEPTH_LAZY=1: on");

    // Size, format and shape rules
    tex_t small, d32s8;
    id<MTLTexture> s = make(&small, 99702, NVN_FORMAT_DEPTH32F, 4096, 4095);
    CHECK(s && !lz(s), "under 64 MB (4096x4095 Depth32F): backed whole");
    id<MTLTexture> c = make(&d32s8, 99703, NVN_FORMAT_DEPTH32F_STENCIL8, 4096, 4096);
    CHECK(c && !lz(c), "a depth-stencil format: backed whole");
    mtl_tex_release(&small); mtl_tex_release(&d32s8);

    // A new lazy texture: no tile, reads 0 everywhere, as the zeroed one
    tex_t lt; id<MTLTexture> lazy = make(&lt, 99704, NVN_FORMAT_DEPTH32F, W, H);
    NvLazy *z = lz(lazy);
    CHECK(lazy && lazy.isSparse && z && z->nmap == 0 && atomic_load(&g_lz_tiles) == 0, "4096x4096 Depth32F (64 MB): placement sparse, no tile mapped");
    printf("lazy texture: %lu bytes allocated (64 MB declared), tile %ux%u\n", (unsigned long)lazy.allocatedSize, z ? z->tw : 0, z ? z->th : 0);
    CHECK(lazy.allocatedSize < (8u << 20), "it holds no memory for its texels");
    CHECK(reads_zero(lazy), "unmapped: read() at integer points, samples and comparison samples give 0");
    matches(lazy, plain, "as made");
    {   // a copy out of an unmapped region reads 0 (readbacks, the host's own snapshot copies)
        id<MTLBuffer> out = [g_dev newBufferWithLength:256 * 4 options:MTLResourceStorageModeShared]; memset(out.contents, 0x5a, 256 * 4);
        T4 *cb = t4_begin(); t4_use(cb, lazy); t4_use(cb, out); id<MTL4ComputeCommandEncoder> b = t4_copy(cb);
        [b copyFromTexture:lazy sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(3000, 3000, 0) sourceSize:MTLSizeMake(256, 1, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:1024 destinationBytesPerImage:1024];
        t4_end(cb, b); t4_wait(cb);
        int zero = 1; for (int i = 0; i < 256; i++) zero &= ((float *)out.contents)[i] == 0;
        CHECK(zero, "a copy out of an unmapped region reads 0");
    }

    // Tiles that held other depth come back zeroed: a lazy texture fully drawn to 0.75, then freed; its tiles go back to the free list once the GPU is past the fence
    // (made by lz_make alone: a game's texture lives in the sharing table until its storage is taken over or its pool goes, which this test does not model)
    {   tex_t pt = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99705}; pt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_DEPTH32F, .width = W, .height = H, .depth = 1, .levels = 1, .samples = 1};
        uint64_t before = 0;
        @autoreleasepool { id<MTLTexture> poison = lz_make(&pt, tex_desc(&pt, 0));
        state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); lz_map_all(lz(poison), poison, "the test"); mtl_sub_commit(); mtl_drain();
        t_draw(poison, (MTLScissorRect){0, 0, W, H}, (MTLViewport){0, 0, W, H, 0, 1}, .75f);
        before = atomic_load(&g_lz_tiles);
        res_remove(poison); res_commit(); poison = nil; }
        drains();
        printf("after the release: %llu lazy tiles mapped (%llu before), %llu free tiles waiting\n", (unsigned long long)atomic_load(&g_lz_tiles), (unsigned long long)before, (unsigned long long)g_sp_nlate);
        CHECK(atomic_load(&g_lz_tiles) == before - 1024, "a freed lazy texture gives its 1,024 tiles back");
    }

    // Draws through the draw path's host half (lz_draw): a scissored one, one bounded by its viewport alone (with the margin), one without depth writes
    MTLScissorRect sc1 = {1000, 700, 300, 200}; MTLViewport vp1 = {1000, 700, 300, 200, 0, 1};
    host_draw(lazy, 1, sc1, vp1);
    CHECK(z->nmap == tiles_in(z, 1000, 700, 1300, 900), "a scissored draw maps the tiles under its scissor alone");
    printf("scissored draw: %u tiles mapped\n", z->nmap);
    CHECK(g_sp_heaps.count == 1, "they are the freed texture's tiles (no second placement heap was made)");
    CHECK(reads_zero(lazy), "the newly mapped tiles, which held 0.75 in the freed texture, read 0");
    matches(lazy, plain, "after the mapping, before the draw");
    t_draw(lazy, sc1, vp1, .25f); t_draw(plain, sc1, vp1, .25f);
    matches(lazy, plain, "a draw of 0.25 into the scissor");
    uint32_t n1 = z->nmap;
    MTLScissorRect full = {0, 0, W, H}; MTLViewport vp2 = {2048, 2048, 100, -100, 0, 1};   // flipped
    host_draw(lazy, 1, full, vp2);
    CHECK(z->nmap - n1 == tiles_in(z, 2048 - LZ_MARGIN, 1948 - LZ_MARGIN, 2148 + LZ_MARGIN, 2048 + LZ_MARGIN) - 0, "a draw with no scissor maps its (flipped) viewport's box and the margin");
    printf("viewport draw: %u tiles more\n", z->nmap - n1);
    t_draw(lazy, full, vp2, .5f); t_draw(plain, full, vp2, .5f);
    matches(lazy, plain, "a draw of 0.5 into the viewport");
    uint32_t n2 = z->nmap;
    host_draw(lazy, 0, full, (MTLViewport){0, 0, W, H, 0, 1});
    CHECK(z->nmap == n2, "a draw that writes no depth maps nothing");

    // Production clears through the replay (clear_ds): a whole one to 0, a scissored one to 0.6 (clear_ds_tri), a whole one to 1
    t_clear_ds(&lt, 0, 0, (p_scissor){0}); t_clear_ds(&off, 0, 0, (p_scissor){0});
    CHECK(z->nmap == n2, "a whole clear to 0 maps nothing");
    matches(lazy, plain, "a whole clear to 0");
    p_scissor cs = {300, 3000, 200, 600};
    t_clear_ds(&lt, .6f, 1, cs); t_clear_ds(&off, .6f, 1, cs);
    CHECK(z->nmap == n2 + tiles_in(z, 300, 3000, 500, 3600), "a scissored clear to 0.6 maps the tiles under its scissor");
    matches(lazy, plain, "a scissored clear to 0.6");
    // A whole clear to 1 makes it a normal texture: every name of the lazy one moves to it (the serial, a texture sharing its storage, a texture ID, through a note), no tile is mapped.
    // The heaps' free tiles (the freed texture's) are taken first: with them free, mapping the rest would cost no memory and the texture would stay lazy (the cases below)
    hold_free(); CHECK(free_now() == 0 && g_nheld > 0, "the heaps' free tiles are taken, as another sparse texture would take them");
    tex_t lt2 = lt; lt2.serial = 99711; mtl_tex_init(&lt2);
    CHECK(tex_mtl(&lt2) == lazy, "a second texture over the same storage shares the lazy one");
    mtl_reg_tex(7, &lt, NULL); CHECK(by_id(7) == lazy, "a texture ID resolves to the lazy one");
    uint32_t n3 = z->nmap; uint64_t whole0 = atomic_load(&g_lz_whole), tiles0 = atomic_load(&g_lz_tiles), gen0 = g_ser_gen;
    t_clear_ds(&lt, 1, 0, (p_scissor){0}); t_clear_ds(&off, 1, 0, (p_scissor){0});
    id<MTLTexture> now = tex_mtl(&lt);
    CHECK(now && now != lazy && !now.isSparse && !lz(now) && atomic_load(&g_lz_whole) == whole0 + 1, "a whole clear to 1 makes it a normal texture");
    CHECK(z->nmap == n3 && atomic_load(&g_lz_tiles) == tiles0, "it maps no tile of the lazy one");
    CHECK(now.width == W && now.height == H && now.pixelFormat == MTLPixelFormatDepth32Float && (now.usage & MTLTextureUsageRenderTarget), "the normal texture has the lazy one's size, format and render-target use");
    CHECK(tex_mtl(&lt2) == now && alias_has(now) && !alias_has(lazy), "the texture sharing its storage takes it too, and so does the sharing table");
    CHECK(noted_since(lt.serial, gen0) && noted_since(lt2.serial, gen0), "both serials are noted (their texture IDs alone resolve again)");
    CHECK(by_id(7) == now, "the texture ID resolves to the normal texture");
    matches(now, plain, "a whole clear to 1");
    printf("lazy tiles: %u of %u when it was made normal\n", z->nmap, z->nx * z->ny);
    host_draw(now, 1, sc1, vp1);
    CHECK(atomic_load(&g_lz_tiles) == tiles0, "a draw into the normal texture maps nothing");
    // The lazy one is retired once the GPU is done with it: out of the residency set (its tiles go back to the free list when it goes, as for the freed one above; the save-load case
    // below sees both its lazy textures go). This test still holds it (lazy, and the earlier fixtures' command buffers in the outer autorelease pool)
    drains();
    CHECK(![g_res_objects containsObject:lazy] && [g_res_objects containsObject:now], "the lazy one leaves the residency set once the GPU is done with it; the normal one stays");
    mtl_reg_tex_gone(7); mtl_tex_release(&lt2);
    unhold();

    // A whole clear to 1 of a lazy texture every tile of which a draw mapped first: a normal texture would add its 64 MB and leave the 64 MB of tiles free in heaps that are never
    // freed, so it stays lazy, nothing more mapped (lz_whole_pays)
    {   tex_t fm; id<MTLTexture> l = make(&fm, 99714, NVN_FORMAT_DEPTH32F, W, H);
        host_draw(l, 1, (MTLScissorRect){0, 0, W, H}, (MTLViewport){0, 0, W, H, 0, 1});
        CHECK(lz(l) && lz(l)->nmap == lz(l)->nx * lz(l)->ny, "a draw over the whole target maps every tile");
        uint64_t whole0 = atomic_load(&g_lz_whole), kept0 = atomic_load(&g_lz_kept), tiles0 = atomic_load(&g_lz_tiles); NSUInteger heaps0 = g_sp_heaps.count;
        t_clear_ds(&fm, 1, 0, (p_scissor){0});
        CHECK(tex_mtl(&fm) == l && l.isSparse && lz(l) && atomic_load(&g_lz_whole) == whole0 && atomic_load(&g_lz_kept) == kept0 + 1,
              "then a whole clear to 1 keeps it lazy (a normal texture would take 64 MB more)");
        CHECK(atomic_load(&g_lz_tiles) == tiles0 && g_sp_heaps.count == heaps0, "no tile more mapped, no heap made");
        CHECK(reads_value(l, 1), "it reads 1 everywhere");
        l = nil; mtl_tex_release(&fm);
    }
    // A whole clear to 1 of a lazy texture with no tile mapped while the heaps hold free tiles for all of it (a freed lazy texture's): mapped from them, no heap made, kept lazy
    {   tex_t pt = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99716}; pt.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_DEPTH32F, .width = W, .height = H, .depth = 1, .levels = 1, .samples = 1};
        @autoreleasepool { id<MTLTexture> p = lz_make(&pt, tex_desc(&pt, 0));
            state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); lz_map_all(lz(p), p, "the test"); mtl_sub_commit(); mtl_drain();
            res_remove(p); res_commit(); p = nil; }
        drains();
        tex_t fr; id<MTLTexture> l = make(&fr, 99715, NVN_FORMAT_DEPTH32F, W, H);
        uint64_t whole0 = atomic_load(&g_lz_whole), kept0 = atomic_load(&g_lz_kept); NSUInteger heaps0 = g_sp_heaps.count;
        printf("free tiles in the heaps: %llu\n", (unsigned long long)free_now());
        CHECK(lz(l) && lz(l)->nmap == 0 && free_now() >= lz(l)->nx * lz(l)->ny, "a freed lazy texture's tiles are free in the heaps, enough for a new one");
        t_clear_ds(&fr, 1, 0, (p_scissor){0});
        CHECK(tex_mtl(&fr) == l && lz(l) && lz(l)->nmap == lz(l)->nx * lz(l)->ny && atomic_load(&g_lz_whole) == whole0 && atomic_load(&g_lz_kept) == kept0 + 1,
              "then a whole clear to 1 maps every tile from them and keeps it lazy");
        CHECK(g_sp_heaps.count == heaps0, "no heap made");
        CHECK(reads_value(l, 1), "it reads 1 everywhere");
        l = nil; mtl_tex_release(&fr);
    }

    // A texture clear of the whole level (to 0: nothing mapped; to 0.4: a normal texture) and a copy into a lazy texture (every tile mapped); the 12288x12288 Depth16 as Ocarina of Time's save load makes it
    // (the heaps' free tiles taken again: Ocarina of Time's save load finds none, its first one making six heaps for its 5,632 tiles with the switch's first build)
    {   hold_free();
        tex_t ct, rt_, ot; id<MTLTexture> cl = make(&ct, 99706, NVN_FORMAT_DEPTH32F, W, H), ref = make(&rt_, 99707, NVN_FORMAT_DEPTH32F, W, H);
        t_clear_tex(&ct, 0);
        CHECK(tex_mtl(&ct) == cl && lz(cl) && lz(cl)->nmap == 0 && reads_zero(cl), "a texture clear of the whole level to 0 maps nothing");
        // Texture clears clear_tex writes nothing for (a part of the level, a channel mask, in a depth format: red line 44) map nothing either; every tile was mapped and zeroed
        {   uint64_t tiles0 = atomic_load(&g_lz_tiles), whole0 = atomic_load(&g_lz_whole);
            t_clear_tex_r(&ct, .5f, (NVNcopyRegion){100, 200, 0, 1000, 900, 1}, 15, 0);
            t_clear_tex_r(&ct, .5f, (NVNcopyRegion){0, 0, 0, W, H, 1}, 1, 0);
            t_clear_tex_r(&ct, .5f, (NVNcopyRegion){0, 0, 0, W, H - 1, 1}, 15, NVN_FORMAT_DEPTH32F);
            CHECK(tex_mtl(&ct) == cl && lz(cl)->nmap == 0 && atomic_load(&g_lz_tiles) == tiles0 && atomic_load(&g_lz_whole) == whole0,
                  "texture clears of a part, a channel mask and a part through a Depth32F view (none drawn for depth) map nothing");
            CHECK(reads_zero(cl), "and it still reads 0, as the texture backed whole does after them");
        }
        uint64_t whole0 = atomic_load(&g_lz_whole), tiles0 = atomic_load(&g_lz_tiles);
        t_clear_tex(&ct, .4f);
        id<MTLTexture> cln = tex_mtl(&ct);
        CHECK(cln && cln != cl && !cln.isSparse && !lz(cln) && lz(cl)->nmap == 0 && atomic_load(&g_lz_tiles) == tiles0 && atomic_load(&g_lz_whole) == whole0 + 1,
              "a texture clear of the whole level to 0.4 makes it a normal texture, no tile mapped");
        lz_reset("0"); id<MTLTexture> plain2 = make(&ot, 99708, NVN_FORMAT_DEPTH32F, W, H); lz_reset("1");
        t_clear_tex(&ot, .4f); matches(cln, plain2, "a texture clear to 0.4");
        t_copy_t2t(&off, &rt_, (NVNcopyRegion){100, 200, 0, 1000, 900, 1});
        CHECK(lz(ref) && lz(ref)->nmap == lz(ref)->nx * lz(ref)->ny, "a texture copy into it maps every tile");
        uint32_t dd2[3]; diff(ref, plain, dd2);
        uint32_t want = 0;   // the copied region holds plain's texels, the rest 0: count plain's non-zero texels outside it
        {   id<MTLBuffer> r = [g_dev newBufferWithLength:4 * W * H options:MTLResourceStorageModeShared];
            T4 *cb = t4_begin(); t4_use(cb, plain); t4_use(cb, r); id<MTL4ComputeCommandEncoder> b = t4_copy(cb);
            [b copyFromTexture:plain sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:r destinationOffset:0 destinationBytesPerRow:4 * W destinationBytesPerImage:4 * W * H];
            t4_end(cb, b); t4_wait(cb);
            const float *f = r.contents; for (uint32_t y = 0; y < H; y++) for (uint32_t x = 0; x < W; x++) if (f[(size_t)y * W + x] != 0 && !(x >= 100 && x < 1100 && y >= 200 && y < 1100)) want++; }
        char l[200]; snprintf(l, sizeof l, "the copy: the region holds the source's texels and the rest 0 (%u texels differ from the source, %u expected)", dd2[0], want);
        CHECK(dd2[0] == want, l);
        mtl_tex_release(&ct); mtl_tex_release(&rt_); mtl_tex_release(&ot);
        tex_t big; id<MTLTexture> b12 = make(&big, 99709, NVN_FORMAT_DEPTH16, 12288, 12288);
        CHECK(b12 && lz(b12) && lz(b12)->nmap == 0, "12288x12288 Depth16 (288 MB): placement sparse, no tile mapped");
        printf("12288x12288 Depth16: %lu bytes allocated, %u tiles of %ux%u\n", (unsigned long)b12.allocatedSize, lz(b12) ? lz(b12)->nx * lz(b12)->ny : 0, lz(b12) ? lz(b12)->tw : 0, lz(b12) ? lz(b12)->th : 0);
        CHECK(reads_zero(b12), "it reads 0 everywhere");
        b12 = nil; mtl_tex_release(&big);
        // Ocarina of Time's save load: a 12288x12288 Depth16 whose first use is a whole clear to a non-zero depth (its texture is made by the clear's attachment), and a 4096x4096 Depth32F the same
        // (counted once what the 12288x12288 took over has gone: the lazy texture whose sharing-table entry its storage took, 99714's, freed and its tiles in the heaps' free list.
        // settle adds no submission: one more would leave 99715's entry idle long enough, ALIAS_IDLE, for the 4096x4096's storage below to take it over too)
        settle(); hold_free();
        uint64_t oo_made0 = atomic_load(&g_lz_n), oo_whole0 = atomic_load(&g_lz_whole), oo_tiles0 = atomic_load(&g_lz_tiles), oo_live0 = atomic_load(&g_lz_live); NSUInteger oo_heaps0 = g_sp_heaps.count;
        tex_t oo = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99712, .off = 99712ull << 24}, o32 = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99713, .off = 99713ull << 24};
        oo.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_DEPTH16, .width = 12288, .height = 12288, .depth = 1, .levels = 1, .samples = 1, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE};
        o32.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_DEPTH32F, .width = W, .height = H, .depth = 1, .levels = 1, .samples = 1, .flags = NVN_TEXTURE_FLAGS_COMPRESSIBLE};
        mtl_tex_init(&oo); mtl_tex_init(&o32);
        t_clear_ds(&o32, 1, 0, (p_scissor){0}); t_clear_ds(&oo, 1, 0, (p_scissor){0});
        id<MTLTexture> on = tex_mtl(&oo), on32 = tex_mtl(&o32);
        CHECK(atomic_load(&g_lz_n) == oo_made0 + 2 && atomic_load(&g_lz_whole) == oo_whole0 + 2, "Ocarina of Time's two save-load depth textures: made lazy by the clear's attachment, then normal textures");
        CHECK(on && !on.isSparse && !lz(on) && on.width == 12288 && on.pixelFormat == MTLPixelFormatDepth16Unorm && on32 && !on32.isSparse && !lz(on32), "both are normal textures");
        CHECK(atomic_load(&g_lz_tiles) == oo_tiles0 && g_sp_heaps.count == oo_heaps0, "no tile mapped, no placement heap made");
        CHECK(reads_value(on, 1) && reads_value(on32, 1), "both read 1 everywhere");
        drains();
        CHECK(atomic_load(&g_lz_live) == oo_live0, "the two lazy textures are gone once the GPU is done with them");
        on = on32 = nil; mtl_tex_release(&oo); mtl_tex_release(&o32);
        unhold();
    }

    // A memory pool finalized before its texture object (Ocarina of Time's 12288x12288 shadow target: the pool at the load into Hyrule Field, the object only at the next load;
    // nvn_mtl.m pool_finalize_locked, upstream NXNative 13c35e90a): a lazy texture of the pool with tiles mapped goes with the pool's Finalize, and its tiles once the GPU is done
    // with it; one a whole clear made a normal texture goes the same way; a pinned one (a queued descriptor) cleared whole to another depth after its pool is gone is neither made
    // a normal texture again, which would hold its whole size under its serial until the object's own Finalize, nor mapped (lz_whole)
    if (depth_lazy_on()) {
        pool_t lp = {.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE};
        uint64_t live0 = atomic_load(&g_lz_live), tiles0 = atomic_load(&g_lz_tiles);
        tex_t pa, pb, pc; __weak id<MTLTexture> wa, wb;
        make_in(&pa, &lp, 99721, NVN_FORMAT_DEPTH32F, W, H); make_in(&pb, &lp, 99722, NVN_FORMAT_DEPTH32F, W, H); make_in(&pc, &lp, 99723, NVN_FORMAT_DEPTH32F, W, H);
        t_clear_ds(&pa, .5f, 1, (p_scissor){0, 0, 512, 512});   // a scissored clear: pa lazy, its tiles under the scissor mapped
        hold_free(); uint64_t whole0 = atomic_load(&g_lz_whole);
        t_clear_ds(&pb, 1, 0, (p_scissor){0});   // a whole clear to 1: pb a normal texture
        @autoreleasepool {
            id<MTLTexture> ta = tex_mtl(&pa), tb = tex_mtl(&pb);
            CHECK(ta && lz(ta) && lz(ta)->nmap > 0 && tb && !tb.isSparse && atomic_load(&g_lz_whole) == whole0 + 1, "a pool's lazy texture with tiles mapped, and one a whole clear made a normal texture");
            wa = ta; wb = tb;
        }
        unhold();
        CHECK(atomic_load(&g_lz_tiles) > tiles0 && atomic_load(&g_lz_live) == live0 + 1, "one lazy texture of the pool live, its tiles mapped");
        __weak id<MTLTexture> wc;
        @autoreleasepool {   // pc's texture as the lookups below hand it out (at +0: autoreleased here when ARC's return handshake is off, as under ThreadSanitizer) goes with this pool
            state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); id<MTLTexture> tcp = tex_mtl(&pc); mtl_sub_commit(); mtl_drain();
            mtl_tex_pin(pc.serial);   // a queued descriptor of pc, holding what it resolves to now
            CHECK(tcp && lz(tcp) && lz(tcp)->nmap == 0 && atomic_load(&g_lz_live) == live0 + 2, "a third one, lazy, no tile mapped, pinned");
            lp.magic = 0; mtl_alias_drop_pool(&lp);   // nvnMemoryPoolFinalize: the magic goes, then the replay forgets the pool
            CHECK(!live_entry(pa.serial) && !live_entry(pb.serial) && !live_entry(pc.serial), "the pool's Finalize ends the three texture objects' entries");
            drains();
            CHECK(!wa && !wb, "once the GPU is done with them, the lazy texture and the normal one are freed though their objects live on");
            CHECK(atomic_load(&g_lz_tiles) == tiles0 && atomic_load(&g_lz_live) == live0 + 1, "the lazy one's tiles back to the heaps; the pinned one stays");
            uint64_t whole1 = atomic_load(&g_lz_whole), kept1 = atomic_load(&g_lz_kept); hold_free();
            t_clear_ds(&pc, 1, 0, (p_scissor){0});   // a whole clear to 1 of the pinned one, after its pool's Finalize
            unhold();
            CHECK(atomic_load(&g_lz_whole) == whole1 && atomic_load(&g_lz_kept) == kept1 && lz(tcp)->nmap == 0 && atomic_load(&g_lz_tiles) == tiles0,
                  "a whole clear to another depth after its pool is gone neither makes it a normal texture nor maps a tile");
            CHECK(!live_entry(pc.serial) && tex_get(pc.serial) == tcp, "and gives its serial no entry: only the pin holds it");
            mtl_tex_unpin(pc.serial); wc = tcp;
        }
        drains();
        CHECK(!wc && atomic_load(&g_lz_live) == live0, "unpinned, it goes too");
        mtl_tex_release(&pa); mtl_tex_release(&pb); mtl_tex_release(&pc);
        CHECK(atomic_load(&g_lz_live) == live0 && atomic_load(&g_lz_tiles) == tiles0, "the objects' own Finalize, later, frees nothing more");
    }
    // A whole clear that read the pool as live just before a game thread's Finalize cleared its magic, its rest landing after the Finalize: the normal texture lz_whole makes serves
    // that clear and keeps no entry, whether the object lives on or its own Finalize came between, and it is retired, kept until the submission in flight completes (its recycled heap
    // not handed out for reuse before that), then freed (nvn_mtl.m pool_fin_since, tex_put_made)
    if (depth_lazy_on()) {
        for (int between = 0; between < 2; between++) {
            const char *who = between ? "its object finalized between" : "its object live";
            char l[300];
            pool_t lq = {.magic = MAGIC('P', 'O', 'O', 'L'), .flags = NVN_MEMORY_POOL_FLAGS_CPU_NO_ACCESS | NVN_MEMORY_POOL_FLAGS_GPU_CACHED | NVN_MEMORY_POOL_FLAGS_COMPRESSIBLE};
            tex_t pz; make_in(&pz, &lq, 99731 + (uint64_t)between, NVN_FORMAT_DEPTH32F, W, H);
            __weak id<MTLTexture> wl, wn; __weak id<MTLHeap> wh;
            state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();   // outside the lookups' pool: the submission's own pool is popped at its commit, after that one
            @autoreleasepool {
                id<MTLTexture> lazy = tex_mtl(&pz); wl = lazy;
                snprintf(l, sizeof l, "the racing clear (%s): a lazy texture of the pool, with its entry", who); CHECK(lazy && lz(lazy) && live_entry(pz.serial), l);
                hold_free(); uint64_t whole0 = atomic_load(&g_lz_whole);
                g_race_pool = &lq; g_race_tex = between ? &pz : NULL; g_pool_read_after = race_finalize;
                id<MTLTexture> n = lz_whole(&pz, lazy, "a test's whole clear");
                g_pool_read_after = NULL; wn = n; wh = n.heap;
                snprintf(l, sizeof l, "the racing clear (%s): the Finalize lands as it looks, and it makes the normal texture for its use", who);
                CHECK(!g_race_pool && lq.magic == 0 && n && !n.isSparse && !lz(n) && atomic_load(&g_lz_whole) == whole0 + 1, l);
                snprintf(l, sizeof l, "the racing clear (%s): no entry under the serial, live or finalized", who);
                CHECK(!live_entry(pz.serial) && !ghost_entry(pz.serial) && !tex_get(pz.serial), l);
            }
            res_commit();   // the residency set's queued change lets go of it: from here only the retirement holds it
            snprintf(l, sizeof l, "the racing clear (%s): the normal texture is retired, kept until the submission in flight completes, its heap not handed out before", who);
            CHECK(wn && !rh_waits(wh), l);
            mtl_sub_commit(); mtl_drain(); unhold();
            snprintf(l, sizeof l, "the racing clear (%s): then freed, and the lazy one", who); CHECK(!wn && !wl, l);
            if (!between) mtl_tex_release(&pz);
        }
    }

    // A GPU without placement sparse depth textures: the texture is made as before
    g_lz_test_nosparse = 1; tex_t fb; id<MTLTexture> f = make(&fb, 99710, NVN_FORMAT_DEPTH32F, W, H); g_lz_test_nosparse = 0;
    CHECK(f && !f.isSparse && !lz(f) && reads_zero(f), "no placement sparse depth on the GPU: backed whole and zeroed, as without the switch");
    mtl_tex_release(&fb);
    lz_line("the test");
    mtl_tex_release(&lt); mtl_tex_release(&off);
    printf("lazy depth textures: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
