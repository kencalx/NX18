// Depth-only draws (a program with no pixel shader: shadow maps, depth pre-passes) through the Metal 4 compiler. Metal 4 needs a fragment function whenever rasterization
// is on, so pso_build gives such a pipeline the host's empty one (nop_fragment, dm/gfx/msl/nop_frag.metal) and leaves every colour attachment's write mask none.
// Checks, through pso_build as the draws build them: the pipeline is a base built (or taken from the archive) and specialized, with no MTLDevice path; a triangle at z = 0.25
// writes 0.25 into the depth target where it covers it and leaves the clear value elsewhere; with a colour target in the pass (and in the pipeline's formats), its pixels
// keep their clear colour. Make runs it once as any run and once with the capture profile (argument capture, MTL_CAPTURE_ENABLED=1 without MTL_DEBUG_LAYER: the capture layer,
// no archive), which builds it the same way.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

enum { W = 8, H = 8 };
static const float CLEAR_C[4] = {0.2f, 0.4f, 0.6f, 1.0f};

// One depth-only draw of the triangle (-1,-1) (1,-1) (-1,1) at z = 0.25 with depth test less and depth writes, into a Depth32Float target cleared to 1 and, with colour,
// an RGBA8 target cleared to CLEAR_C
static void depth_draw(const char *name, id<MTLFunction> vs, int colour) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    d.vertexFunction = vs; d.fragmentFunction = nil; d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    if (colour) d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;   // as a shadow pass that keeps a colour target bound
    uint64_t spec = g_pb_spec, bases = g_pb_built + g_pb_archived + g_pb_reused; NSError *err = nil;
    id<MTLRenderPipelineState> ps = pso_build(d, &err);
    CHECK(ps != nil, "%s: a pipeline (%s)", name, err ? err.localizedDescription.UTF8String : "no error");
    if (!ps) return;
    CHECK(g_pb_built + g_pb_archived + g_pb_reused == bases + 1 && g_pb_spec == spec + 1, "%s: a base (built, from the archive or reused), then specialized", name);

    id<MTLDevice> dev = g_dev;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:W height:H mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> depth = [dev newTextureWithDescriptor:td], col = nil;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.depthAttachment.texture = depth; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = MTLStoreActionStore;
    if (colour) {
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
        cd.usage = MTLTextureUsageRenderTarget; cd.storageMode = MTLStorageModeShared;
        col = [dev newTextureWithDescriptor:cd];
        rp.colorAttachments[0].texture = col; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        rp.colorAttachments[0].clearColor = MTLClearColorMake(CLEAR_C[0], CLEAR_C[1], CLEAR_C[2], CLEAR_C[3]);
    }
    if (!depth || (colour && !col)) { CHECK(0, "%s: targets", name); return; }
    MTLDepthStencilDescriptor *dsd = [MTLDepthStencilDescriptor new]; dsd.depthWriteEnabled = YES; dsd.depthCompareFunction = MTLCompareFunctionLess;
    id<MTLBuffer> out = [dev newBufferWithLength:256 * H options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> enc = t4_pass(cb, rp);
    [enc setRenderPipelineState:t4_keep(cb, ps)]; [enc setDepthStencilState:t4_keep(cb, [dev newDepthStencilStateWithDescriptor:dsd])];
    [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; t4_end(cb, enc);
    id<MTL4ComputeCommandEncoder> copy = t4_copy(cb); t4_use(cb, depth); t4_use(cb, out);
    [copy copyFromTexture:depth sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1)
                 toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:256 * H];
    t4_end(cb, copy);
    CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted, "%s: command buffer completed", name);
    int covered = 0, open = 0, bad = 0;
    for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) {
        if (x == y) continue;   // the edge's own pixels: left to the rasterizer's rule
        float z = ((const float *)((const uint8_t *)out.contents + 256 * y))[x], want = x < y ? 0.25f : 1.0f;   // pixel centre in NDC: x + y < 0 below the diagonal
        if (z == want) { covered += x < y; open += x >= y; } else if (bad++ < 4) fprintf(stderr, "%s: depth (%d, %d) = %g, expected %g\n", name, x, y, z, want);
    }
    CHECK(!bad && covered == W * (H - 1) / 2 && open == W * (H - 1) / 2, "%s: depth written where the triangle covers the target, the clear value elsewhere (%d wrong)", name, bad);
    if (colour) {
        uint8_t px[W * H * 4]; [col getBytes:px bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0];
        int kept = 0; for (int i = 0; i < W * H; i++) { int ok = 1; for (int c = 0; c < 4; c++) ok &= abs((int)px[4 * i + c] - (int)lrintf(CLEAR_C[c] * 255)) <= 1; kept += ok; }
        CHECK(kept == W * H, "%s: the colour target keeps its clear colour (%d of %d pixels)", name, kept, W * H);
    }
}

int main(int argc, char **argv) { @autoreleasepool {
    setenv("DM_PSO_ARCHIVE", "off", 1); unsetenv("DM_PSO_BUNDLE"); setenv("DM_PSO_HYBRID", "0", 1);
    mtl_init(); NSError *err = nil;
    int capture = argc > 1 && !strcmp(argv[1], "capture");
    CHECK(!!pso4_capture() == capture, "the capture profile %s (%s)", capture ? "on" : "off", pso4_capture() ?: "no capture layer");
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint n [[vertex_id]]) { float2 p[3] = {float2(-1, -1), float2(1, -1), float2(-1, 1)}; return float4(p[n], 0.25, 1); }\n", nil, &err);
    if (!lib) { fprintf(stderr, "the fixture's shader did not compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    id<MTLFunction> vs = t4_fn(lib, @"v");
    id<MTLFunction> nop = nop_fragment();
    CHECK(nop && fn4_of(nop) && [nop.name isEqualToString:@"dm_nop"], "the host's empty fragment function is loaded and noted");
    depth_draw("depth only", vs, 0);
    depth_draw("depth only, colour target bound", vs, 1);
    CHECK(g_comp4 != nil, "the Metal 4 compiler");
    printf("t_pso_depth_only (%s): %d checks, %d failed\n", pso4_capture() ? "capture profile" : "archive off", checks, failed);
    return failed != 0;
} }
