// A new single-sample Depth16 / Depth32F texture is zeroed in the upload batch by copies from the zero buffer, in pieces of rows (tex_zero_fill), not by a clear render pass (which fails
// with a GPU out-of-memory error on large attachments on an M3 Pro). Every texel of every level and layer reads 0 afterwards, from a texture first filled with a non-zero depth.
// Port of NXNative 4cdd5577: here the copies are the profile key depth_zero_copy's (Ocarina of Time; DM_DEPTH_ZERO_COPY overrides), so the cases run with it on whatever the game,
// then again with it off, where the clear pass zeroes them as before (no copies). Unset, the switch leaves the profile's value. A texture of 64 MB or more leaves a note for the
// 'depth zero:' line, which gives the GPU time of the upload batch that zeroed it (its feedback handler, up_flush) and of its frame and the next two (dz_line); up to DZ_N notes wait.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static int dz_find(id<MTLTexture> t) { for (int k = 0; k < DZ_N; k++) if (g_dz[k].frame && g_dz[k].w == t.width && g_dz[k].h == t.height && g_dz[k].pf == t.pixelFormat) return k; return -1; }
static int dz_waiting(void) { int n = 0; for (int k = 0; k < DZ_N; k++) n += g_dz[k].frame != 0; return n; }
static void dz_clear(void) { memset(g_dz, 0, sizeof g_dz); for (int k = 0; k < DZ_N; k++) atomic_store(&g_dz_up[k], 0); }

int main(void) { @autoreleasepool {
    mtl_init();
    // The default: unset, the profile's value (Ocarina of Time on, every other game the clear pass); 1 / 0 override it
    unsetenv("DM_DEPTH_ZERO_COPY"); g_depth_zero_copy = -1;
    CHECK(depth_zero_copy() == DM_GAME_DEPTH_ZERO_COPY && !g_depth_zero_env, "unset, the switch leaves the profile's depth_zero_copy");
    printf("depth_zero_copy by default: %d (the profile's %d)\n", g_depth_zero_copy, DM_GAME_DEPTH_ZERO_COPY);
    setenv("DM_DEPTH_ZERO_COPY", "0", 1); g_depth_zero_copy = -1; CHECK(depth_zero_copy() == 0 && g_depth_zero_env, "DM_DEPTH_ZERO_COPY=0: the clear pass");
    setenv("DM_DEPTH_ZERO_COPY", "1", 1); g_depth_zero_copy = -1; CHECK(depth_zero_copy() == 1 && g_depth_zero_env, "DM_DEPTH_ZERO_COPY=1: copies");
    unsetenv("DM_DEPTH_ZERO_COPY");
    NSError *error = nil;
    id<MTLLibrary> library = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void count_nz(depth2d<float,access::read> d [[texture(0)]], device atomic_uint *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { if (p.x < d.get_width() && p.y < d.get_height() && d.read(p) != 0.0f) atomic_fetch_add_explicit(o, 1u, memory_order_relaxed); }\n", nil, &error);
    id<MTLComputePipelineState> counter = t4_cps(t4_fn(library, @"count_nz"), &error);
    CHECK(counter != nil, "synthetic non-zero counter compiles");
    if (!counter) return 1;
    struct { int target, format; unsigned w, h, depth, levels, pieces; const char *label; } cases[] = {   // pieces: copies into level 0 of one layer, with the 4 MB zero buffer
        {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH16, 4096, 4096, 1, 1, 8, "Depth16 4096x4096"},
        {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH32F, 2048, 2048, 1, 1, 4, "Depth32F 2048x2048"},
        {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH32F, 4096, 4096, 1, 1, 16, "Depth32F 4096x4096 (64 MB, as Ocarina of Time's save load makes): a note for the line"},
        {NVN_TEXTURE_TARGET_2D_ARRAY, NVN_FORMAT_DEPTH16, 3072, 3072, 2, 3, 5, "Depth16 3072x3072, two layers, three levels"},
        {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH32F, 16384, 129, 1, 1, 3, "Depth32F 16384x129: the last piece is one row"},
        {NVN_TEXTURE_TARGET_CUBEMAP, NVN_FORMAT_DEPTH32F, 256, 256, 1, 1, 1, "Depth32F cube 256x256, six faces"},
        {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH16, 1024, 1024, 1, 1, 1, "Depth16 1024x1024"},
        {NVN_TEXTURE_TARGET_2D, NVN_FORMAT_DEPTH32F, 17, 5, 1, 3, 1, "Depth32F 17x5, three levels"},
    };
    for (int mode = 1; mode >= 0; mode--) { g_depth_zero_copy = mode; printf("depth_zero_copy %s\n", mode ? "on" : "off");
    for (unsigned i = 0; i < sizeof cases / sizeof *cases; i++) {
        tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 99601 + i};
        t.d = (nvn_texdesc){.target = cases[i].target, .format = cases[i].format, .width = cases[i].w, .height = cases[i].h, .depth = cases[i].depth, .levels = cases[i].levels, .samples = 1};
        MTLTextureDescriptor *descriptor = tex_desc(&t, 0);
        id<MTLTexture> base = descriptor ? [g_dev newTextureWithDescriptor:descriptor] : nil;
        CHECK(base != nil, "synthetic depth texture allocates");
        if (!base) continue;
        size_t bpp = base.pixelFormat == MTLPixelFormatDepth16Unorm ? 2 : 4, poison_bytes = (size_t)cases[i].w * cases[i].h * bpp;
        id<MTLBuffer> poison = [g_dev newBufferWithLength:poison_bytes options:MTLResourceStorageModeShared];
        if (bpp == 2) for (size_t k = 0; k < poison_bytes / 2; k++) ((uint16_t *)poison.contents)[k] = 0xbfff;   // 0.75
        else for (size_t k = 0; k < poison_bytes / 4; k++) ((float *)poison.contents)[k] = .75f;
        T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> blit = t4_copy(cb); t4_use(cb, poison); t4_use(cb, base);
        for (NSUInteger l = 0; l < base.mipmapLevelCount; l++) for (NSUInteger s = 0; s < base.arrayLength; s++) {
            NSUInteger w = MAX(base.width >> l, 1u), h = MAX(base.height >> l, 1u);
            [blit copyFromBuffer:poison sourceOffset:0 sourceBytesPerRow:w * bpp sourceBytesPerImage:w * h * bpp sourceSize:MTLSizeMake(w, h, 1) toTexture:base destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
        t4_end(cb, blit);
        CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted, "the texture takes its non-zero depth");
        res_add(base);
        state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
        dz_clear(); g_depth_zero_env = 1;   // the note as with DM_DEPTH_ZERO_COPY set, either way
        tex_zero_fill(base);
        int pieces0 = 0; for (int k = 0; k < g_nup_blits; k++) pieces0 += g_up_blits[k].dst == base && g_up_blits[k].slice == 0 && g_up_blits[k].level == 0 && !g_up_blits[k].tsrc;
        if (mode) CHECK(pieces0 == (int)cases[i].pieces, "level 0 of a layer is zeroed by the expected number of copies, with no render pass");
        else CHECK(pieces0 == 0, "depth_zero_copy off: no copies (the clear pass, as before)");
        int big = base.allocatedSize >= (64u << 20), k = dz_find(base);
        if (i == 2) CHECK(big, "the 4096x4096 Depth32F is 64 MB or more, as on the phone");
        CHECK(big ? k >= 0 && dz_waiting() == 1 && g_dz[k].frame == atomic_load(&g_cur_frame) + 1 && g_dz[k].by_copy == mode && g_dz[k].mb == (unsigned)(base.allocatedSize >> 20) &&
                    g_dz[k].seq == g_up_seq && atomic_load(&g_dz_up[k]) == (uint64_t)g_up_seq << 32 : !dz_waiting(),
              "a depth texture of 64 MB or more leaves a note for the 'depth zero:' line, with its upload batch, a smaller one none");
        mtl_sub_commit(); mtl_drain();
        CHECK(!mtl_last_commit_error(), "zero fill completes without GPU error");
        for (int w = 0; w < 5000 && atomic_load(&g_up_pending); w++) usleep(1000);   // the batch's feedback handler
        if (big) { uint64_t u = atomic_load(&g_dz_up[k]);
            CHECK((u >> 32) == g_dz[k].seq && (uint32_t)u > 0, "the upload batch's feedback gives the note its GPU time");
            printf("  upload batch with the zeroing: %.2f ms on the GPU\n", ((uint32_t)u - 1) / 1000.0); }
        dz_clear();
        id<MTLBuffer> count = [g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        int clean = 1;
        for (NSUInteger l = 0; l < base.mipmapLevelCount; l++) for (NSUInteger s = 0; s < base.arrayLength; s++) {
            id<MTLTexture> v = [base newTextureViewWithPixelFormat:base.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(l, 1) slices:NSMakeRange(s, 1)];
            *(uint32_t *)count.contents = 0;
            cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_compute(cb);
            [e setComputePipelineState:t4_keep(cb, counter)]; t4_tex(cb, e, T4_CS, v, 0); t4_buf(cb, e, T4_CS, count, 0, 0);
            [e dispatchThreads:MTLSizeMake(v.width, v.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; t4_end(cb, e);
            CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted, "the texels are read on the GPU");
            if (*(uint32_t *)count.contents) { clean = 0; fprintf(stderr, "  level %lu layer %lu: %u texels not zero\n", (unsigned long)l, (unsigned long)s, *(uint32_t *)count.contents); }
        }
        CHECK(clean, cases[i].label);
        printf("case %u: %s: %d copies into level 0, %s\n", i, cases[i].label, pieces0, clean ? "PASS" : "FAIL");
        defer_obj_release(base);
    } }
    // The line: 12288x12288 Depth16Unorm (296 MB), as Ocarina of Time's save load makes, zeroed by copies, with the GPU times of its upload batch, its frame and the next two
    g_depth_zero_env = 0; g_depth_zero_copy = 1;
    dz_note_t z = {1954, 12288, 12288, 296, 72, 7, 1, MTLPixelFormatDepth16Unorm};
    char line[400]; double g3[3] = {149.04, 3.2, -1}; dz_line(&z, line, sizeof line, 2.46, g3); printf("line: %s\n", line);
    CHECK(!strcmp(line, "depth zero: the 12288x12288 Depth16Unorm (296 MB) made in frame 1953, zeroed by 72 copies (game profile depth_zero_copy): the upload batch with them 2.5 ms on the GPU; "
                        "that frame's submissions 149.0 ms on the GPU, 3.2 ms and not known the next two"),
          "the 'depth zero:' line names the texture, how it was zeroed, its upload batch's and the three frames' GPU times");
    z.by_copy = 0; z.pieces = 1; g_depth_zero_env = 1; dz_line(&z, line, sizeof line, -1, g3);
    CHECK(strstr(line, "zeroed by 1 clear pass (DM_DEPTH_ZERO_COPY): the upload batch with it not known on the GPU") != NULL, "and the clear pass, with the switch, its batch not back");
    // A save load's two: the 296 MB Depth16 and the 64 MB Depth32F in the same frame give a line each, the batch's time where its feedback came back
    MTLTextureDescriptor *d16 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth16Unorm width:12288 height:12288 mipmapped:NO];
    MTLTextureDescriptor *d32 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4096 height:4096 mipmapped:NO];
    MTLTextureDescriptor *d32s = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4608 height:4096 mipmapped:NO];
    for (MTLTextureDescriptor *d in @[d16, d32, d32s]) { d.storageMode = MTLStorageModePrivate; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead; }
    id<MTLTexture> t16 = [g_dev newTextureWithDescriptor:d16], t32 = [g_dev newTextureWithDescriptor:d32], t32s = [g_dev newTextureWithDescriptor:d32s];
    CHECK(t16 && t32 && t32s, "the save load's depth textures allocate");
    dz_clear(); unsigned sq = g_up_seq;
    uint64_t f0 = atomic_load(&g_cur_frame);
    dz_note(t16, 73, 1); dz_note(t32, 16, 1);
    int k16 = dz_find(t16), k32 = dz_find(t32);
    CHECK(k16 >= 0 && k32 >= 0 && k16 != k32 && dz_waiting() == 2, "two notes in one frame: both wait (the second no longer replaces the first)");
    uint64_t w = (uint64_t)sq << 32; atomic_compare_exchange_strong(&g_dz_up[k16], &w, w | 3101u);   // as the batch's feedback handler stores 3.1 ms
    dz_note(t32, 16, 1); dz_note(t32, 16, 1);
    CHECK(dz_waiting() == DZ_N && dz_find(t16) == k16, "four notes fill the slots");
    dz_note(t32s, 18, 1);
    CHECK(dz_waiting() == DZ_N && dz_find(t32s) >= 0 && dz_find(t16) == k16, "with every slot taken, a larger texture takes a smaller one's place, the largest kept");
    uint64_t made = g_dz[k16].frame;
    dz_note(t32, 16, 1);
    CHECK(dz_find(t16) == k16 && g_dz[k16].frame == made && dz_find(t32s) >= 0, "and a texture no larger than any waiting one is dropped");
    dz_tick(f0 + DZ_LAG - 1); CHECK(dz_waiting() == DZ_N, "the lines wait until the three frames' GPU times are known");
    dz_tick(f0 + DZ_LAG); CHECK(dz_waiting() == 0 && !atomic_load(&g_dz_up[k16]), "then each is written once, its slot free again");
    // The batch's feedback with times that are not a GPU time (Ocarina of Time's iPhone test 3: lines of 4000000.0 ms and 171810.0 ms). Before, a start of 0 with an end at 42556.079 s
    // of uptime stored the end's whole uptime cut at 4e9 us (4000000.0 ms), and a start 171.81 s before the end stored 171810.0 ms; both are "not known" now and add nothing to
    // the timing line's @upload_gpu_ms. A real time still goes in (up_gpu_note, which up_flush's feedback handler calls)
    dz_clear(); sq = ++g_up_seq; dz_note(t16, 72, 1); k16 = dz_find(t16); (void)mtl_upload_gpu_ns_take();
    CHECK(k16 >= 0, "a note waits for the batch's feedback");
    struct { double g0, g1; const char *label; } bad[] = {
        {0, 42556.079, "a GPU start of 0 (was the end's uptime, 4000000.0 ms): not known"},
        {100.0, 271.81, "a span of 171.81 s, a start left over (was 171810.0 ms): not known"},
        {271.81, 100.0, "an end before the start: not known"},
        {-1.0, 0.5, "a negative start: not known"}};
    for (unsigned i = 0; k16 >= 0 && i < sizeof bad / sizeof bad[0]; i++) {
        up_gpu_note(sq, bad[i].g0, bad[i].g1);
        CHECK(atomic_load(&g_dz_up[k16]) == (uint64_t)sq << 32 && mtl_upload_gpu_ns_take() == 0, bad[i].label);
    }
    if (k16 >= 0) { double up = (uint32_t)atomic_load(&g_dz_up[k16]) ? 0 : -1; double gn[3] = {149.04, 3.2, 3.1}; dz_line(&g_dz[k16], line, sizeof line, up, gn); printf("line: %s\n", line);
        CHECK(strstr(line, "the upload batch with them not known on the GPU") != NULL, "the line says the batch's time is not known, as dz_tick reads the empty low half"); }
    up_gpu_note(sq + 1, 100.0, 100.00246);
    CHECK(k16 >= 0 && atomic_load(&g_dz_up[k16]) == (uint64_t)sq << 32, "another batch's time does not land in the note");
    uint64_t un = mtl_upload_gpu_ns_take(); CHECK(un > 2459000 && un < 2461000, "but goes into @upload_gpu_ms");
    up_gpu_note(sq, 100.0, 100.00246); uint64_t uw = k16 >= 0 ? atomic_load(&g_dz_up[k16]) : 0;
    CHECK((uw >> 32) == sq && (uint32_t)uw >= 2460 && (uint32_t)uw <= 2461, "a GPU time of 2.46 ms goes into the note (microseconds + 1)");
    un = mtl_upload_gpu_ns_take(); CHECK(un > 2459000 && un < 2461000, "and into @upload_gpu_ms");
    up_gpu_note(sq, 100.0, 109.5); CHECK(atomic_load(&g_dz_up[k16 >= 0 ? k16 : 0]) == uw && mtl_upload_gpu_ns_take() == 9500000000ull, "a span under 10 s counts; the note keeps its first time");
    dz_clear();
    // The power tick's span of one frame (mtl_gpu_span, which hle_nvn.c tick_gpu adds to the union through nvn_power.h nvn_pd_span_add), fed through the same ring the submissions
    // fill (gpu_tag_begin / gpu_tag_done). Frames far above this test's own, so dz_tick's reads above are not touched. Ocarina of Time's first power tick in iPhone test 3 read about
    // 42,556,079 ms/s as the union: a start just above 0 passes gpu_tag_done's own check and gave a span of the whole uptime, which mtl_gpu_span now does not return
    {
        uint64_t fs = 900000, s0 = 0, s1 = 0;
        gpu_tag_begin(fs); gpu_tag_done(fs, 0, 0);
        CHECK(!mtl_gpu_span(fs, &s0, &s1), "span: a frame whose command buffer came back with no GPU times has no span");
        gpu_tag_begin(fs + 1); gpu_tag_done(fs + 1, 100.0, 100.012);
        CHECK(mtl_gpu_span(fs + 1, &s0, &s1) && s0 == 100000000000ull && s1 - s0 > 11999000 && s1 - s0 < 12001000, "span: a 12 ms frame has its span");
        gpu_tag_begin(fs + 2); gpu_tag_done(fs + 2, 1e-6, 42556.079);
        CHECK(mtl_gpu_span(fs + 2, &s0, &s1) == 0 && mtl_gpu_ms(fs + 2) > 4e7, "span: a start just above 0 with an end at 42556 s of uptime has no span (was about 42,556,079 ms); the summed time is not changed");
        gpu_tag_begin(fs + 3); gpu_tag_begin(fs + 3); gpu_tag_done(fs + 3, 100.0, 100.01); gpu_tag_done(fs + 3, 102.0, 102.01);
        CHECK(mtl_gpu_span(fs + 3, &s0, &s1) == 0 && mtl_gpu_ms(fs + 3) > 19.99 && mtl_gpu_ms(fs + 3) < 20.01, "span: a frame whose command buffers spread over 2 s has no span, its summed time still counts");
        gpu_tag_begin(fs + 4); gpu_tag_begin(fs + 4); gpu_tag_done(fs + 4, 100.0, 100.01);
        CHECK(!mtl_gpu_span(fs + 4, &s0, &s1), "span: a frame with a command buffer still out has no span yet");
    }
    printf("depth zero fill: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
