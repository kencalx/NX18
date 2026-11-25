// Private Metal buffers reject even querying contents under API validation.
// Both cases use real aligned private buffer textures (upstream NXNative f67a9e88d). NX 18's tbuf_shadow takes the
// view alone: DM_TBUF_ALIGN at twice the device's alignment puts the aligned view below it, so it reaches the guard.
// No unsupported view is created or submitted to the GPU.
#include "../nvn/nvn_mtl.m"
#include <unistd.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (%d)\n", label, __LINE__); } } while (0)
int main(int argc, char **argv) { @autoreleasepool {
    alarm(30);
    if (argc != 2 || (strcmp(argv[1], "shadow") && strcmp(argv[1], "rows"))) return 2;
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_PSO_PREBUILD", "0", 1); setenv("DM_PSO_MANIFEST", "off", 1); setenv("DM_PSO_USER", "/dev/null", 1);
    NSUInteger al0 = 0;
    { id<MTLDevice> d0 = MTLCreateSystemDefaultDevice(); al0 = [d0 minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR32Uint]; if (al0 < 16) al0 = 16; }
    char alv[32]; snprintf(alv, sizeof alv, "%lu", (unsigned long)(2 * al0)); setenv("DM_TBUF_ALIGN", alv, 1);
    mtl_init();
    id<MTLBuffer> src = [g_dev newBufferWithLength:4096 options:MTLResourceStorageModePrivate];
    CHECK(src != nil, "private source allocation"); if (!src) return 2;
    CHECK(src.storageMode == MTLStorageModePrivate, "actual Metal buffer is private");
    NSUInteger al = [g_dev minimumLinearTextureAlignmentForPixelFormat:MTLPixelFormatR32Uint];
    MTLTextureDescriptor *d = [MTLTextureDescriptor textureBufferDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:17 resourceOptions:src.resourceOptions usage:MTLTextureUsageShaderRead];
    id<MTLTexture> source = [src newTextureWithDescriptor:d offset:al bytesPerRow:256];
    CHECK(source != nil, "real aligned private source view"); if (!source) return 2;
    uint64_t rid = 0x1234, copies = g_tbs_copies, rows = g_tb2_copy;
    id<MTLTexture> result;
    if (!strcmp(argv[1], "shadow")) {
        CHECK(source.bufferOffset % tbuf_al(MTLPixelFormatR32Uint) != 0, "the view is below the raised alignment, so it reaches the guard");
        os_unfair_lock_lock(&g_rmu);
        result = tbuf_shadow(0, source, &rid);   // no registered ID: no element lead (tbuf_lead), so nothing is copied
        os_unfair_lock_unlock(&g_rmu);
        CHECK(result == source, "unsupported shadow keeps its existing fallback");
    } else {
        // A larger row-view alignment can require a copy even when the source
        // buffer texture itself is valid (also reproducible with DM_TBUF_ALIGN).
        os_unfair_lock_lock(&g_rmu);
        result = tbuf_rows_copy(source, source.buffer, source.bufferOffset, MTLPixelFormatR32Uint, 4, 1, 256, 2 * al, &rid);
        os_unfair_lock_unlock(&g_rmu);
        CHECK(result == nil, "unsupported row copy keeps its existing failure result");
    }
    CHECK(rid == 0x1234, "no fabricated resource identity");
    CHECK(g_tbs_copies == copies && g_tb2_copy == rows, "no CPU snapshot or staging copy");
    printf("t_tbuf_access %s: %d checks, %d failed\n", argv[1], checks, failed);
    return failed != 0;
} }
