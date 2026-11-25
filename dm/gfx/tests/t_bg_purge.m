// The background purge (nvn_mtl.m mtl_bg_purge; ported from the S2Arm project's 23b99c4a): going to the background, the host's packaged textures (pkg_upload's, noted by
// bg_pkg_note) in the residency set are marked purgeable; render targets, packaged textures the GPU wrote since (a copy into one, through the replay's write hook tu_wrote) or made
// with render-target use, textures only a shader writes, textures in a heap, views and buffers are not: their content is only on the GPU (ported from S2Arm 41eec704, whose
// t_nvn_bg_purge checks the same three kinds: a packaged texture marked, a GPU-only one and a GPU-written packaged one kept). Coming back they are non-volatile again: a packaged
// texture the system emptied (emptied here by the test) goes into the dropped-upload record, uploaded again at its next use. With DM_NVN_BG_PURGE=0 (--off) nothing is marked.
// Through dm_gfx_suspend as the iOS front end calls it, too.
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
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static id<MTLTexture> tex(MTLTextureUsage usage, id<MTLHeap> heap) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:256 height:256 mipmapped:NO];
    d.storageMode = MTLStorageModePrivate; d.usage = usage;
    id<MTLTexture> t = heap ? [heap newTextureWithDescriptor:d] : [g_dev newTextureWithDescriptor:d]; res_add(t); return t;
}
static MTLPurgeableState state(id<MTLTexture> t) { return [t setPurgeableState:MTLPurgeableStateKeepCurrent]; }
int main(int argc, char **argv) { @autoreleasepool {
    int off = argc > 1 && !strcmp(argv[1], "--off");
    mtl_init();
    id<MTLTexture> pkg = tex(MTLTextureUsageShaderRead, nil), pkg2 = tex(MTLTextureUsageShaderRead, nil), rt = tex(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget, nil);
    id<MTLTexture> img = tex(MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite, nil), plain = tex(MTLTextureUsageShaderRead, nil);
    MTLHeapDescriptor *hd = [MTLHeapDescriptor new]; hd.size = 4 << 20; hd.storageMode = MTLStorageModePrivate; id<MTLHeap> heap = [g_dev newHeapWithDescriptor:hd];
    id<MTLTexture> in_heap = tex(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget, heap);
    id<MTLTexture> view = [rt newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB]; res_add(view);
    id<MTLTexture> pkg_copied = tex(MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView, nil), pkg_rt = tex(MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget, nil);
    id<MTLTexture> copied_view = [pkg_copied newTextureViewWithPixelFormat:MTLPixelFormatRGBA8Unorm_sRGB];
    bg_pkg_note(pkg); bg_pkg_note(pkg2); bg_pkg_note(pkg_copied); bg_pkg_note(pkg_rt);
    tu_wrote(copied_view);   // a copy into the packaged texture, through a view of it: its content is the GPU's now
    tu_wrote(pkg_rt);        // drawn into: the usage alone keeps it
    res_commit();
    mtl_bg_purge(1);
    if (off) {
        CHECK("DM_NVN_BG_PURGE=0: nothing marked", state(pkg) == MTLPurgeableStateNonVolatile && state(rt) == MTLPurgeableStateNonVolatile);
    } else {
        CHECK("a packaged texture is marked purgeable", state(pkg) == MTLPurgeableStateVolatile && state(pkg2) == MTLPurgeableStateVolatile);
        CHECK("a render target is not (its content is only on the GPU)", state(rt) == MTLPurgeableStateNonVolatile);
        CHECK("a packaged texture a GPU copy wrote is not", state(pkg_copied) == MTLPurgeableStateNonVolatile);
        CHECK("a packaged texture with render-target use is not", state(pkg_rt) == MTLPurgeableStateNonVolatile);
        CHECK("a texture a shader writes is not (nothing would make it again)", state(img) == MTLPurgeableStateNonVolatile);
        CHECK("a texture neither packaged nor a render target is not", state(plain) == MTLPurgeableStateNonVolatile);
        CHECK("a texture in a heap is not (its heap stays non-volatile)", in_heap.heap == heap && [heap setPurgeableState:MTLPurgeableStateKeepCurrent] == MTLPurgeableStateNonVolatile);
        // The system takes two of them while the app is away
        [pkg setPurgeableState:MTLPurgeableStateEmpty];
    }
    mtl_bg_purge(0);
    CHECK("coming back every texture is non-volatile", state(pkg) == MTLPurgeableStateNonVolatile && state(pkg2) == MTLPurgeableStateNonVolatile && state(rt) == MTLPurgeableStateNonVolatile
          && state(pkg_copied) == MTLPurgeableStateNonVolatile);
    if (!off) {
        CHECK("an emptied packaged texture is uploaded again at its next use (dropped-upload record)", up_lost_has(pkg));
        CHECK("one the system left is not", !up_lost_has(pkg2));
        CHECK("the kept textures are not in the record", !up_lost_has(rt) && !up_lost_has(pkg_copied));
        up_lost_drop(pkg);
        // Through the suspend the iOS front end calls: going marks, coming back unmarks before the gate opens
        dm_gfx_suspend(1);
        CHECK("dm_gfx_suspend(1) marks after its drain", state(pkg2) == MTLPurgeableStateVolatile);
        dm_gfx_suspend(0);
        CHECK("dm_gfx_suspend(0) unmarks", state(pkg2) == MTLPurgeableStateNonVolatile);
    }
    printf("t_bg_purge%s: %d checks, %d failed\n", off ? " --off" : "", checks, failed);
    return failed != 0;
} }
