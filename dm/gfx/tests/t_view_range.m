// Texture views with a level / layer range go through mtl_view / mtl_view_sw (nvn_mtl.m; after S2Arm a6ba2b665, Apache-2.0, github.com/jhaizhou-ops/S2Arm): a range past the source
// makes no view (nil) and one red line, where newTextureView would abort the process in Metal's validation. Expectations are written from the shapes built here:
//   A: a 2D array, 64x64, 3 levels, 2 layers; C: a cube, 32x32, 1 level (6 faces)
//   A layers 1+1, levels 0+3: made (1 + 1 <= 2)       A layers 1+2: nil (3 > 2, the "(3) must be <= (2)" of S2Arm's reports)
//   A layer 2 as 2D: nil (2 + 1 > 2)                   A levels 1+3: nil (4 > 3)           A levels 0+0 or layers 0+0: nil (an empty range)
//   C face 5 as 2D: made (5 + 1 <= 6)                  C face 6: nil (7 > 6)               with a swizzle: A layers 0+2 made, 1+2 nil
// Reaching the end is the check that nothing aborted. T_VIEW_RANGE_RAW=1 makes the same out-of-range view straight through Metal, which aborts the process (the witness).
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)
int main(void) { @autoreleasepool {
    alarm(60);
    mtl_init();
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:YES];
    d.textureType = MTLTextureType2DArray; d.arrayLength = 2; d.mipmapLevelCount = 3; d.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; d.storageMode = MTLStorageModePrivate;
    id<MTLTexture> a = [g_dev newTextureWithDescriptor:d];
    MTLTextureDescriptor *dc = [MTLTextureDescriptor textureCubeDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm size:32 mipmapped:NO];
    dc.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView; dc.storageMode = MTLStorageModePrivate;
    id<MTLTexture> c = [g_dev newTextureWithDescriptor:dc];
    if (!a || !c) { fprintf(stderr, "FAIL: the source textures were not made\n"); return 1; }
    if (getenv("T_VIEW_RANGE_RAW")) {   // the witness: straight through Metal, the same range aborts the process
        id<MTLTexture> v = [a newTextureViewWithPixelFormat:a.pixelFormat textureType:MTLTextureType2DArray levels:NSMakeRange(0, 1) slices:NSMakeRange(1, 2)];
        printf("raw out-of-range view made: %s\n", v ? "yes" : "no"); return 0;
    }
    CHECK(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 3), NSMakeRange(1, 1)) != nil, "array layers 1+1, levels 0+3: made");
    CHECK(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 1), NSMakeRange(1, 2)) == nil, "array layers 1+2 (3 > 2): nil");
    CHECK(atomic_load(&g_view_refused) == 1, "one refusal counted");
    CHECK(mtl_view(a, a.pixelFormat, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(2, 1)) == nil, "array layer 2 as 2D (3 > 2): nil");
    CHECK(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(1, 3), NSMakeRange(0, 1)) == nil, "array levels 1+3 (4 > 3): nil");
    CHECK(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 0), NSMakeRange(0, 1)) == nil, "no levels: nil");
    CHECK(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 1), NSMakeRange(0, 0)) == nil, "no layers: nil");
    CHECK(mtl_view(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(NSUIntegerMax, 2), NSMakeRange(0, 1)) == nil, "a level range that wraps around: nil");
    CHECK(mtl_view(c, c.pixelFormat, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(5, 1)) != nil, "cube face 5 as 2D (6 <= 6): made");
    CHECK(mtl_view(c, c.pixelFormat, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(6, 1)) == nil, "cube face 6 (7 > 6): nil");
    MTLTextureSwizzleChannels sw = MTLTextureSwizzleChannelsMake(MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleRed, MTLTextureSwizzleOne);
    CHECK(mtl_view_sw(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 1), NSMakeRange(0, 2), sw) != nil, "swizzled, layers 0+2: made");
    CHECK(mtl_view_sw(a, a.pixelFormat, MTLTextureType2DArray, NSMakeRange(0, 1), NSMakeRange(1, 2), sw) == nil, "swizzled, layers 1+2: nil");
    CHECK(mtl_view(nil, MTLPixelFormatRGBA8Unorm, MTLTextureType2D, NSMakeRange(0, 1), NSMakeRange(0, 1)) == nil, "no source: nil");
    CHECK(atomic_load(&g_view_refused) == 8, "every out-of-range view counted (not the missing source)");
    printf("t_view_range: %d checks, %d failed (nothing aborted)\n", checks, fails);
    return fails != 0;
} }
