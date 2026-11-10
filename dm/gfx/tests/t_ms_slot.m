// Multisample texture slots: the reflection records texture2d_ms / depth2d_ms (and their arrays) as multisample types, not 2D (URP's CopyDepth reads its MSAA depth
// through texture2d_ms: Super Monkey Ball Banana Rumble reported the multisample depth bound there as a type mismatch), and the dummy of an unbound multisample slot
// is a multisample texture that reads 0, which Metal accepts in that argument (a 2D dummy is not).
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static int refl_type(NSString *msl_type, uint8_t *dpf) {
    NSDictionary *j = @{@"route": @"B", @"stage": @"pixel", @"bindings": @[@{@"msl_name": @"t", @"msl_type": msl_type, @"arg_id": @0, @"kind": @"tex", @"reg": @128}]};
    nvn_refl r = {0}; char err[256] = "";
    if (nvn_refl_from_json(j, &r, err, sizeof err) || r.nb != 1) { fprintf(stderr, "reflection of %s: %s\n", msl_type.UTF8String, err); nvn_refl_free(&r); return -1; }
    *dpf = r.b[0].dpf; int dtt = r.b[0].dtt; nvn_refl_free(&r); return dtt;
}
int main(void) { @autoreleasepool {
    mtl_init(); NSError *error = nil; uint8_t dpf = 0;
    CHECK(refl_type(@"texture2d_ms<float>", &dpf) == MTLTextureType2DMultisample && dpf == NVN_DPF_FLOAT, "texture2d_ms is a multisample slot");
    CHECK(refl_type(@"depth2d_ms<float>", &dpf) == MTLTextureType2DMultisample && dpf == NVN_DPF_DEPTH, "depth2d_ms is a multisample depth slot");
    CHECK(refl_type(@"texture2d_ms_array<uint>", &dpf) == MTLTextureType2DMultisampleArray && dpf == NVN_DPF_UINT, "texture2d_ms_array is a multisample array slot");
    CHECK(refl_type(@"texture2d_array<float>", &dpf) == MTLTextureType2DArray, "texture2d_array stays a 2D array");
    CHECK(refl_type(@"texture2d<float>", &dpf) == MTLTextureType2D, "texture2d stays 2D");
    const int dpfs[] = {NVN_DPF_FLOAT, NVN_DPF_UINT, NVN_DPF_SINT, NVN_DPF_DEPTH};
    for (int i = 0; i < 4; i++) {
        id<MTLTexture> ms = dummy_tex(MTLTextureType2DMultisample, dpfs[i]), msa = dummy_tex(MTLTextureType2DMultisampleArray, dpfs[i]);
        CHECK(ms && ms.textureType == MTLTextureType2DMultisample && ms.sampleCount > 1, "a multisample slot's dummy is a multisample texture");
        CHECK(msa && msa.textureType == MTLTextureType2DMultisampleArray && msa.sampleCount > 1, "a multisample array slot's dummy is a multisample array");
        CHECK(ms && g_dummy_tex_rid[MTLTextureType2DMultisample][dpfs[i]] == ms.gpuResourceID._impl, "the multisample dummy's resource ID is recorded");
    }
    id<MTLTexture> one = dummy_tex(MTLTextureType1D, NVN_DPF_FLOAT);
    CHECK(one && one.textureType == MTLTextureType1D, "the 1D dummy keeps its own entry beside the multisample array's (type 8)");
    id<MTLTexture> tb = dummy_tex(MTLTextureTypeTextureBuffer, NVN_DPF_FLOAT), a1 = dummy_tex(MTLTextureType1DArray, NVN_DPF_FLOAT);
    CHECK(tb && tb.textureType == MTLTextureTypeTextureBuffer && a1 && a1.textureType == MTLTextureType1DArray, "the buffer texture's dummy (type 9) and the 1D array's (type 1) are their own");
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "kernel void rd(texture2d_ms<float> a [[texture(0)]], texture2d_ms<uint> b [[texture(1)]], depth2d_ms<float> c [[texture(2)]], device float4* out [[buffer(0)]]) {"
        " float4 v = a.read(uint2(0), 0) + float4(b.read(uint2(0), 3)) + float4(c.read(uint2(0), 1)); out[0] = v; }\n";
    id<MTLLibrary> library = t4_lib(source, nil, &error);
    if (!library) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    id<MTLComputePipelineState> pipeline = t4_cps(t4_fn(library, @"rd"), &error);
    if (!pipeline) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 2; }
    id<MTLBuffer> output = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(output.contents, 0xcd, 16);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_compute(cb);
    [e setComputePipelineState:pipeline];
    t4_tex(cb, e, T4_CS, dummy_tex(MTLTextureType2DMultisample, NVN_DPF_FLOAT), 0); t4_tex(cb, e, T4_CS, dummy_tex(MTLTextureType2DMultisample, NVN_DPF_UINT), 1);
    t4_tex(cb, e, T4_CS, dummy_tex(MTLTextureType2DMultisample, NVN_DPF_DEPTH), 2); t4_buf(cb, e, T4_CS, output, 0, 0);
    [e dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; t4_end(cb, e); t4_wait(cb);
    CHECK(cb->status == MTLCommandBufferStatusCompleted, "the GPU accepts the multisample dummies in multisample arguments");
    const float *v = output.contents;
    CHECK(v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 0, "every sample of the multisample dummies reads 0");
    printf("multisample slots: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
