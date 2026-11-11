// Newly allocated Switch texture storage is zero, including every MSAA color sample.
// Poison the Metal storage first so this cannot pass because the driver happened to zero it.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #c); } } while (0)

int main(void) { @autoreleasepool {
    mtl_init(); NSError *error = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void read_ms(texture2d_ms<float,access::read> t [[texture(0)]], device float4 *o [[buffer(0)]], uint2 p [[thread_position_in_grid]]) { for(uint s=0;s<t.get_num_samples();s++) o[(p.y*8+p.x)*t.get_num_samples()+s]=t.read(p,s); }\n";
    id<MTLLibrary> lib = t4_lib(src, nil, &error); CHECK(lib != nil); if (!lib) return 1;
    id<MTLComputePipelineState> reader = t4_cps(t4_fn(lib, @"read_ms"), &error); CHECK(reader != nil); if (!reader) return 1;
    MTLPixelFormat formats[] = {MTLPixelFormatRGBA8Unorm, MTLPixelFormatRG11B10Float, MTLPixelFormatRGBA16Float};
    for (int fi = 0; fi < 3; fi++) for (int samples = 2; samples <= 4; samples *= 2) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:formats[fi] width:8 height:8 mipmapped:NO];
        td.textureType = MTLTextureType2DMultisample; td.sampleCount = samples; td.storageMode = MTLStorageModePrivate;
        td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        id<MTLTexture> t = [g_dev newTextureWithDescriptor:td]; CHECK(t != nil); if (!t) continue;
        MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
        rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
        rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(.75,.5,.25,.875);
        T4 *cb = t4_begin(); t4_end(cb, t4_pass(cb, rp));
        CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted);
        res_add(t); state_reset(); memset(&R,0,sizeof R); mtl_sub_begin(); tex_zero_fill(t); mtl_sub_commit(); mtl_drain();
        CHECK(!mtl_last_commit_error());
        id<MTLBuffer> out = [g_dev newBufferWithLength:64*samples*16 options:MTLResourceStorageModeShared];
        cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_compute(cb);
        [e setComputePipelineState:t4_keep(cb, reader)]; t4_tex(cb, e, T4_CS, t, 0); t4_buf(cb, e, T4_CS, out, 0, 0);
        [e dispatchThreads:MTLSizeMake(8,8,1) threadsPerThreadgroup:MTLSizeMake(8,8,1)]; t4_end(cb, e);
        CHECK(t4_wait(cb) == MTLCommandBufferStatusCompleted);
        float *p = out.contents; int zero = 1;
        for (int i = 0; i < 64*samples; i++) for (int c = 0; c < 4; c++) zero &= p[4*i+c] == (c == 3 && fi == 1 ? 1.0f : 0.0f);
        CHECK(zero); printf("MSAA color initialization format %lu samples %d: %s\n", (unsigned long)formats[fi], samples, zero ? "PASS" : "FAIL");
    }
    printf("MSAA color initialization: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
