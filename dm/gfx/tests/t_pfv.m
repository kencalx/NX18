#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

int main(void) {
    int failed = 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm) != 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatRGBA8Unorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatBGRA8Unorm, MTLPixelFormatBGRA8Unorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatBC7_RGBAUnorm, MTLPixelFormatBC7_RGBAUnorm_sRGB) != 0;
    failed += tex_need_pfv(MTLPixelFormatRGBA8Unorm, MTLPixelFormatR32Uint) != 1;
    tex_t t = {.magic=MAGIC('T', 'E', 'X', 0), .serial = 70001};
    t.d.width = 4; t.d.height = 1; t.d.depth = 1; t.d.levels = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    mtl_init();
    MTLTextureDescriptor *d = tex_desc(&t, 0);
    failed += (d.usage & MTLTextureUsagePixelFormatView) != 0;
    id<MTLTexture> base = [g_dev newTextureWithDescriptor:d];
    uint8_t bytes[16] = {1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16};
    id<MTLBuffer> src = [g_dev newBufferWithBytes:bytes length:sizeof bytes options:MTLResourceStorageModeShared];
    mtl_sub_begin();
    res_add(src); res_add(base);   // Metal 4: both ends of a copy must be in the residency set
    id fill = blit();   // copies on the main command buffer go through the host wrapper (which carries its own barrier)
    [fill copyFromBuffer:src sourceOffset:0 sourceBytesPerRow:16 sourceBytesPerImage:16 sourceSize:MTLSizeMake(4, 1, 1)
               toTexture:base destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0)];
    enc_b_end(g_blit); g_blit = nil;
    serial_put(t.serial, base);
    id<MTLTexture> upgraded = tex_upgrade_pfv(&t, base, MTLPixelFormatR32Uint);
    failed += upgraded.pixelFormat != MTLPixelFormatRGBA8Unorm;   // the upgrade keeps the original format
    failed += !(upgraded.usage & MTLTextureUsagePixelFormatView);
    failed += serial_get(t.serial) != upgraded;   // the registration has been replaced
    if (g_blit) { enc_b_end(g_blit); g_blit = nil; }
    id<MTLTexture> view = [upgraded newTextureViewWithPixelFormat:MTLPixelFormatR32Uint];
    id<MTLBuffer> dst = [g_dev newBufferWithLength:sizeof bytes options:MTLResourceStorageModeShared];
    res_add(dst);
    id read = blit();
    [read copyFromTexture:view sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 1, 1)
                 toBuffer:dst destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:16];
    enc_b_end(g_blit); g_blit = nil;
    mtl_sub_commit(); mtl_drain();
    failed += memcmp(dst.contents, bytes, sizeof bytes) != 0;
    // An RGB9E5 render target has the format-view usage at creation (a packaged one does not), so an R32UI view of it is attached as such and the packed word it writes is the
    // base texture's bits (without the usage: attached in RGB9E5 and the word written as a float, the whole picture red)
    {
        tex_t e = {.magic=MAGIC('T', 'E', 'X', 0), .serial = 70002};
        e.d.width = 4; e.d.height = 4; e.d.depth = 1; e.d.levels = 1; e.d.target = NVN_TEXTURE_TARGET_2D; e.d.format = NVN_FORMAT_RGB9E5F;
        MTLTextureDescriptor *ed = tex_desc(&e, 0);
        int f0 = failed;
        failed += ed.pixelFormat != MTLPixelFormatRGB9E5Float;
        failed += !(ed.usage & MTLTextureUsagePixelFormatView);
        failed += (tex_desc(&e, 1).usage & MTLTextureUsagePixelFormatView) != 0;   // packaged: not drawn into, keeps lossless compression
        id<MTLTexture> eb = [g_dev newTextureWithDescriptor:ed]; res_add(eb); serial_put(e.serial, eb);
        view_t v; memset(&v, 0, sizeof v); v.set_format = 1; v.format = NVN_FORMAT_R32UI;
        MTLRenderPassColorAttachmentDescriptor *a = [MTLRenderPassColorAttachmentDescriptor new];
        mtl_sub_begin(); attach(a, &e, &v, 1);
        failed += !a.texture || a.texture.pixelFormat != MTLPixelFormatR32Uint;
        uint32_t word = 0;
        if (a.texture && a.texture.pixelFormat == MTLPixelFormatR32Uint) {
            NSError *err = nil;   // a Metal 4 command buffer of the fixtures' own (t_mtl4.h): the host has no classic queue
            id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
                "vertex float4 tri(uint i [[vertex_id]]) { const float2 p[3] = {float2(-1, -1), float2(3, -1), float2(-1, 3)}; return float4(p[i], 0, 1); }\n"
                "fragment uint4 word() { return uint4(0x7e020080u, 0, 0, 0); }\n", nil, &err);
            MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = t4_fn(lib, @"tri"); pd.fragmentFunction = t4_fn(lib, @"word");
            pd.colorAttachments[0].pixelFormat = MTLPixelFormatR32Uint; id<MTLRenderPipelineState> ps = t4_rps(pd, &err);
            MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
            rp.colorAttachments[0].texture = a.texture; rp.colorAttachments[0].loadAction = MTLLoadActionDontCare; rp.colorAttachments[0].storeAction = MTLStoreActionStore;
            id<MTLBuffer> out = [g_dev newBufferWithLength:64 options:MTLResourceStorageModeShared];
            T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> en = t4_pass(cb, rp);
            [en setRenderPipelineState:ps]; [en drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; t4_end(cb, en);
            id<MTL4ComputeCommandEncoder> bl = t4_copy(cb); t4_use(cb, eb); t4_use(cb, out);
            [bl copyFromTexture:eb sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:16 destinationBytesPerImage:64];
            t4_end(cb, bl); t4_wait(cb);
            word = ((const uint32_t *)out.contents)[5];
        }
        mtl_sub_commit(); mtl_drain();
        failed += word != 0x7e020080u;
        printf("RGB9E5 render target through an R32UI view: attached %lu, word %#x (%s)\n", (unsigned long)(a.texture ? a.texture.pixelFormat : 0), word, failed == f0 ? "PASS" : "FAIL");
    }
    printf("pfv predicate failed=%d\n", failed);
    return failed != 0;
}
