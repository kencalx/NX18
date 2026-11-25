// A 32-bit integer buffer image bound to a slot the shader declares float gets the float view of the same size over the same buffer (nvn_mtl.m img_fit, img_needs_class_view,
// tbuf_view_format), so integer atomics in one shader and float loads and stores in another see the same bits. Ported from upstream NXNative d43a37905's t_buffer_image_bias case
// (LEGO Star Wars' exposure histogram: clear and reduction through texture_buffer<float>, accumulation through texture_buffer<uint> atomics). NX 18 has no buffer-image coordinate
// bias, so the image sits at an aligned pool offset here. make GAME=<id> check_t_buffer_image_float
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
enum { POOL = 65536, W = 16, OFF = 0x400, FILL = 0xEE };
static tex_t buffer_texture(uint8_t *mem, uint64_t off, uint64_t serial, uint32_t flags) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .mem = mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = NVN_FORMAT_R32UI, .flags = flags, .width = W, .height = 1, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t);
    return t;
}
int main(void) { @autoreleasepool {
    mtl_init();
    uint8_t *mem; if (posix_memalign((void **)&mem, (size_t)getpagesize(), POOL)) abort();
    memset(mem, FILL, POOL); mtl_pool_add(mem, POOL);
    uint32_t *words = (uint32_t *)(mem + OFF); words[0] = 500u;
    tex_t img = buffer_texture(mem, OFF, 99721, NVN_TEXTURE_FLAGS_IMAGE);
    mtl_reg_image(721, &img, NULL);
    nvn_rbind ub = {.kind = NVN_RB_IMG, .dtt = MTLTextureTypeTextureBuffer, .dpf = NVN_DPF_UINT, .rw = 1}, fb = ub; fb.dpf = NVN_DPF_FLOAT;
    os_unfair_lock_lock(&g_rmu);
    uint64_t urid = 0, frid = 0; int ureal = 0, freal = 0;
    id<MTLTexture> ut = img_binding(721, &ub, &urid, &ureal);
    id<MTLTexture> ft = img_binding(721, &fb, &frid, &freal);
    os_unfair_lock_unlock(&g_rmu);
    CHECK(ureal && ut.pixelFormat == MTLPixelFormatR32Uint && ut.textureType == MTLTextureTypeTextureBuffer, "a uint slot binds the R32Uint image buffer as it is");
    CHECK(img_needs_class_view(ut, NVN_DPF_FLOAT) && !img_needs_class_view(ut, NVN_DPF_UINT), "a float slot over R32Uint storage needs a view, a uint slot does not");
    int float_view = freal && ft && ft.pixelFormat == MTLPixelFormatR32Float && ft.textureType == MTLTextureTypeTextureBuffer;
    CHECK(float_view, "an R32Uint buffer image bound as float gets an R32Float view on the first bind");
    CHECK(float_view && ft.buffer == ut.buffer && ft.bufferOffset == ut.bufferOffset && ft.width == ut.width, "the float view covers the same buffer bytes");
    CHECK(float_view && frid == ft.gpuResourceID._impl, "the float slot's argument names that view");
    // a 2D integer texture in a float image slot keeps its binding (only buffer images get a float view; tex_float_fit covers sampling)
    MTLTextureDescriptor *d2 = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint width:4 height:4 mipmapped:NO];
    d2.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite; id<MTLTexture> t2 = [g_dev newTextureWithDescriptor:d2];
    CHECK(t2 && !img_needs_class_view(t2, NVN_DPF_FLOAT), "a 2D integer image in a float slot needs no class view");
    if (float_view) {
        NSError *error = nil;
        id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
            "kernel void f(texture_buffer<float, access::read_write> img [[texture(0)]], device uint *out [[buffer(0)]]) {\n"
            "    out[0] = as_type<uint>(img.read(0u).x);\n"
            "    img.write(float4(1.0), 1u);\n"
            "}\n"
            "kernel void a(texture_buffer<uint, access::read_write> img [[texture(0)]]) { img.atomic_fetch_add(2u, 7u); }\n", nil, &error);
        id<MTLFunction> ff = lib ? t4_fn(lib, @"f") : nil, fa = lib ? t4_fn(lib, @"a") : nil;
        id<MTLComputePipelineState> kf = ff ? t4_cps(ff, &error) : nil, ka = fa ? t4_cps(fa, &error) : nil;
        CHECK(kf && ka, "the kernels compile");
        if (!kf || !ka) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        words[2] = 0x3f800000u;   // 1.0f, then 7 added as an integer: the integer view sees the float view's bits
        id<MTLBuffer> out = [g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
        T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> c = t4_compute(cb);
        [c setComputePipelineState:t4_keep(cb, kf)]; t4_tex(cb, c, T4_CS, ft, 0); t4_buf(cb, c, T4_CS, out, 0, 0);
        [c dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        t4_barrier(c);
        [c setComputePipelineState:t4_keep(cb, ka)]; t4_tex(cb, c, T4_CS, ut, 0);
        [c dispatchThreads:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
        t4_end(cb, c); t4_wait(cb);
        CHECK(cb->status == MTLCommandBufferStatusCompleted, "the kernels completed");
        CHECK(*(const uint32_t *)out.contents == 500u, "a float image read hands the integer's bits over");
        CHECK(words[1] == 0x3f800000u, "a float image write lands in the integer image's bytes");
        CHECK(words[2] == 0x3f800007u, "integer atomics on the same bytes see them");
        CHECK(words[-1] == 0xEEEEEEEEu && words[W] == 0xEEEEEEEEu, "the bytes around the image are untouched");
    }
    mtl_pool_del(mem);
    printf("t_buffer_image_float: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
