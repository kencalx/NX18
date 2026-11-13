// A new single-sample Depth16 / Depth32F texture is zeroed in the upload batch by copies from the zero buffer, in pieces of rows (tex_zero_fill), not by a clear render pass (which fails
// with a GPU out-of-memory error on large attachments on an M3 Pro). Every texel of every level and layer reads 0 afterwards, from a texture first filled with a non-zero depth.
// Port of NXNative 4cdd5577: here the copies are the profile key depth_zero_copy's (Ocarina of Time; DM_DEPTH_ZERO_COPY overrides), so the cases run with it on whatever the game,
// then again with it off, where the clear pass zeroes them as before (no copies). A texture of 64 MB or more leaves a note for the 'depth zero:' line, which gives the GPU time of
// its frame and the next two (dz_line).
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

int main(void) { @autoreleasepool {
    mtl_init();
    NSError *error = nil;
    id<MTLLibrary> library = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void count_nz(depth2d<float,access::read> d [[texture(0)]], device atomic_uint *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { if (p.x < d.get_width() && p.y < d.get_height() && d.read(p) != 0.0f) atomic_fetch_add_explicit(o, 1u, memory_order_relaxed); }\n" options:nil error:&error];
    id<MTLComputePipelineState> counter = [g_dev newComputePipelineStateWithFunction:[library newFunctionWithName:@"count_nz"] error:&error];
    CHECK(counter != nil, "synthetic non-zero counter compiles");
    if (!counter) return 1;
    id<MTLCommandQueue> queue = [g_dev newCommandQueue];
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
        id<MTLCommandBuffer> cb = [queue commandBuffer]; id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        for (NSUInteger l = 0; l < base.mipmapLevelCount; l++) for (NSUInteger s = 0; s < base.arrayLength; s++) {
            NSUInteger w = MAX(base.width >> l, 1u), h = MAX(base.height >> l, 1u);
            [blit copyFromBuffer:poison sourceOffset:0 sourceBytesPerRow:w * bpp sourceBytesPerImage:w * h * bpp sourceSize:MTLSizeMake(w, h, 1) toTexture:base destinationSlice:s destinationLevel:l destinationOrigin:MTLOriginMake(0, 0, 0)];
        }
        [blit endEncoding]; [cb commit]; [cb waitUntilCompleted];
        CHECK(cb.status == MTLCommandBufferStatusCompleted, "the texture takes its non-zero depth");
        res_add(base);
        state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin();
        g_dz.frame = 0; g_depth_zero_env = 1;   // the note as with DM_DEPTH_ZERO_COPY set, either way
        tex_zero_fill(base);
        int pieces0 = 0; for (int k = 0; k < g_nup_blits; k++) pieces0 += g_up_blits[k].dst == base && g_up_blits[k].slice == 0 && g_up_blits[k].level == 0 && !g_up_blits[k].tsrc;
        if (mode) CHECK(pieces0 == (int)cases[i].pieces, "level 0 of a layer is zeroed by the expected number of copies, with no render pass");
        else CHECK(pieces0 == 0, "depth_zero_copy off: no copies (the clear pass, as before)");
        int big = base.allocatedSize >= (64u << 20);
        CHECK(big ? g_dz.frame == atomic_load(&g_cur_frame) + 1 && g_dz.by_copy == mode && g_dz.w == cases[i].w && g_dz.mb == (unsigned)(base.allocatedSize >> 20) : !g_dz.frame,
              "a depth texture of 64 MB or more leaves a note for the 'depth zero:' line, a smaller one none");
        g_dz.frame = 0;
        mtl_sub_commit(); mtl_drain();
        CHECK(!mtl_last_commit_error(), "zero fill completes without GPU error");
        id<MTLBuffer> count = [g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        int clean = 1;
        for (NSUInteger l = 0; l < base.mipmapLevelCount; l++) for (NSUInteger s = 0; s < base.arrayLength; s++) {
            id<MTLTexture> v = [base newTextureViewWithPixelFormat:base.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(l, 1) slices:NSMakeRange(s, 1)];
            *(uint32_t *)count.contents = 0;
            cb = [queue commandBuffer]; id<MTLComputeCommandEncoder> e = [cb computeCommandEncoder];
            [e setComputePipelineState:counter]; [e setTexture:v atIndex:0]; [e setBuffer:count offset:0 atIndex:0];
            [e dispatchThreads:MTLSizeMake(v.width, v.height, 1) threadsPerThreadgroup:MTLSizeMake(16, 16, 1)]; [e endEncoding]; [cb commit]; [cb waitUntilCompleted];
            CHECK(cb.status == MTLCommandBufferStatusCompleted, "the texels are read on the GPU");
            if (*(uint32_t *)count.contents) { clean = 0; fprintf(stderr, "  level %lu layer %lu: %u texels not zero\n", (unsigned long)l, (unsigned long)s, *(uint32_t *)count.contents); }
        }
        CHECK(clean, cases[i].label);
        printf("case %u: %s: %d copies into level 0, %s\n", i, cases[i].label, pieces0, clean ? "PASS" : "FAIL");
        defer_obj_release(base);
    } }
    // The line: 12288x12288 Depth16Unorm (296 MB), as Ocarina of Time's save load makes, zeroed by copies, with the GPU times of its frame and the next two
    g_depth_zero_env = 0; g_depth_zero_copy = 1;
    g_dz.w = g_dz.h = 12288; g_dz.mb = 296; g_dz.pieces = 72; g_dz.by_copy = 1; g_dz.pf = MTLPixelFormatDepth16Unorm; g_dz.frame = 1954;
    char line[320]; double g3[3] = {149.04, 3.2, -1}; dz_line(line, sizeof line, g3); printf("line: %s\n", line);
    CHECK(!strcmp(line, "depth zero: the 12288x12288 Depth16Unorm (296 MB) made in frame 1953, zeroed by 72 copies (game profile depth_zero_copy): GPU 149.0 ms that frame, 3.2 ms and not known the next two"),
          "the 'depth zero:' line names the texture, how it was zeroed and the three frames' GPU times");
    g_dz.by_copy = 0; g_dz.pieces = 1; g_depth_zero_env = 1; dz_line(line, sizeof line, g3);
    CHECK(strstr(line, "zeroed by 1 clear pass (DM_DEPTH_ZERO_COPY)") != NULL, "and the clear pass, with the switch");
    dz_tick(1954 + DZ_LAG - 2); CHECK(g_dz.frame == 1954, "the line waits until the three frames' GPU times are known");
    dz_tick(1954 + DZ_LAG); CHECK(g_dz.frame == 0, "then it is written once");
    printf("depth zero fill: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
