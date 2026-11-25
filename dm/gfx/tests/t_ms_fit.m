// A multisample texture of a sample count the GPU lacks is made with the largest count it has below it (nvn_mtl.m tex_desc; ported from the S2Arm project's a6f28581), not
// refused: 16 samples (no Apple GPU has them) and 8 (an A15 iPhone has only 2 and 4) step down to what the device answers, counted here from the device itself; 2 and 4 stay;
// one sample has no Metal form and is still refused. The descriptor made is one Metal makes a texture from, and a render pass clears it.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
static NSUInteger fit(NSUInteger want) { NSUInteger best = 0; for (NSUInteger n = 2; n <= want; n *= 2) if ([g_dev supportsTextureSampleCount:n]) best = n; return best; }
static MTLTextureDescriptor *desc(int target, int samples) {
    tex_t t; memset(&t, 0, sizeof t);
    t.serial = nvn_new_serial(); t.d.target = target; t.d.format = NVN_FORMAT_RGBA8; t.d.width = 64; t.d.height = 32; t.d.depth = target == 6 ? 2 : 1; t.d.levels = 1; t.d.samples = samples;
    return tex_desc(&t, 0);
}
int main(void) { @autoreleasepool {
    mtl_init();
    printf("device sample counts: 2 %d, 4 %d, 8 %d, 16 %d\n", [g_dev supportsTextureSampleCount:2], [g_dev supportsTextureSampleCount:4], [g_dev supportsTextureSampleCount:8], [g_dev supportsTextureSampleCount:16]);
    int targets[] = {5, 6};
    for (int ti = 0; ti < 2; ti++) for (int want = 2; want <= 16; want *= 2) {
        MTLTextureDescriptor *d = desc(targets[ti], want);
        NSUInteger n = fit(want);
        CHECK("a count the GPU lacks steps down to the largest it has below it; one it has stays", d && d.sampleCount == n);
        if (!d) continue;
        id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
        CHECK("Metal makes the texture", t && t.sampleCount == n);
        if (!t || ti) continue;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
        T4 *cb = t4_begin(); t4_end(cb, t4_pass(cb, rp));
        CHECK("a render pass into it completes", t4_wait(cb) == MTLCommandBufferStatusCompleted);
    }
    CHECK("16 samples are not made as 16 on this GPU (none has them)", ![g_dev supportsTextureSampleCount:16] && desc(5, 16).sampleCount < 16);
    CHECK("one sample has no Metal form: still refused", desc(5, 1) == nil && desc(5, 0) == nil);
    printf("t_ms_fit: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
