// Native integer-to-float vertex fetch (nvn_mtl.m vin_i2f; adapted from ComicBit/nxnative 39cc2e79c, MIT). For each of the 24 *_UI2F / *_I2F formats (0x51-0x68) into a float,
// uint and int input (with and without a float shadow), the production pso_desc routes the attribute to Metal's fetch (8 / 16-bit) or to a CPU conversion slot (32-bit, no shadow,
// captures, the switches), vin_on / vconv_wanted give the draw the same answer from the current state, and the words the vertex shader receives through the native route are bit for
// bit the CPU conversion's (vconv_fill, the old route): every 8-bit value and every 16-bit value in each component. Then vconv_fill's decode-once loop against vconv_elem per element
// for all 24 formats (unaligned source, odd stride, stride 0), and ordinary integer formats into a float input staying on the CPU (their register bits, never a numeric conversion).
// Run with DM_NVN_I2F_NATIVE=0 and DM_NVN_VCONV_CPU=1 too (the Makefile): then every route is the CPU conversion
#include "../nvn/nvn_mtl.m"
#define T4_STANDALONE   // no mtl_init: the fixture's own device, queue and residency set
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; printf("FAIL: "); printf(__VA_ARGS__); printf("\n"); } } while (0)
enum { STRIDE = 20, OFF = 4, OUT_SLOT = 13 };
static id<MTLDevice> dev; static id<MTLLibrary> lib; static id<MTLBuffer> zero;
static int env_is(const char *k, const char *v) { const char *e = getenv(k); return e && !strcmp(e, v); }

// The words input 0 receives for nv vertices of vb (stride STRIDE), drawn with pso_desc's descriptor d: conv (16 bytes a vertex) is bound at VCONV_SLOT0 as vconv_bind binds it
static int draw_words(MTLRenderPipelineDescriptor *d, id<MTLBuffer> vb, id<MTLBuffer> conv, int nv, uint32_t *got) {
    NSError *err = nil; id<MTLRenderPipelineState> ps = t4_rps(d, &err);
    if (!ps) { printf("pipeline: %s\n", err.localizedDescription.UTF8String); return 0; }
    id<MTLBuffer> out = [dev newBufferWithLength:(NSUInteger)nv * 16 options:MTLResourceStorageModeShared]; memset(out.contents, 0xEE, (size_t)nv * 16);
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor]; rp.renderTargetWidth = rp.renderTargetHeight = 1; rp.defaultRasterSampleCount = 1;
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> en = t4_pass(cb, rp); [en setRenderPipelineState:t4_keep(cb, ps)];
    t4_buf(cb, en, T4_VS, out, 0, OUT_SLOT); t4_buf(cb, en, T4_VS, vb, 0, VB_SLOT(0)); t4_buf(cb, en, T4_VS, zero, 0, 30);
    if (conv) t4_buf(cb, en, T4_VS, conv, 0, VCONV_SLOT0);
    [en drawPrimitives:MTLPrimitiveTypePoint vertexStart:0 vertexCount:(NSUInteger)nv]; t4_end(cb, en); t4_wait(cb);
    if (cb->status != MTLCommandBufferStatusCompleted) { printf("GPU command failed\n"); return 0; }
    memcpy(got, out.contents, (size_t)nv * 16); return 1;
}

// shadow: 0 none (an integer input without a float shadow), 1 the float shadow at 16 and the other sign at 17; capture: the pipeline is a capture's (TF / geometry / discard)
static void route(int f, int ct, int shadow, int capture) {
    int ib, is, n = vconv_i2f(f, &ib, &is), es = n * ib / 8;
    int native_on = !env_is("DM_NVN_I2F_NATIVE", "0") && !env_is("DM_NVN_VCONV_CPU", "1");
    int native = native_on && !capture && ib < 32 && (ct == NVN_CT_FLOAT || shadow);
    char what[96]; snprintf(what, sizeof what, "format %#x into %s%s%s", f, ct == NVN_CT_FLOAT ? "float" : ct == NVN_CT_UINT ? "uint" : "int", ct != NVN_CT_FLOAT && !shadow ? " (no float shadow)" : "", capture ? " (capture)" : "");
    NvShader *vs = [NvShader new]; snprintf(vs->key, sizeof vs->key, "i2f_test_b");
    static NSString *const base[3] = { @"vf", @"vu_b", @"vi_b" }, *const shad[3] = { nil, @"vu_s", @"vi_s" };
    vs->fn = t4_fn(lib, base[ct]); vs->stage = 0;
    vs->rf.nv = 1; vs->rf.v[0].nvn = 0; vs->rf.v[0].loc = 0; vs->rf.v[0].ct = (uint8_t)ct; memset(vs->rf.v[0].sh, 0xff, sizeof vs->rf.v[0].sh);
    if (ct != NVN_CT_FLOAT) {   // the shadow-input library (dmsh_vin.py) declares the input again at 16 (float) and 17 (the other sign)
        vs->rf.has_vin = 1; vs->vfn = t4_fn(lib, shad[ct]); vs->vfn_state = 1;
        if (shadow) vs->rf.v[0].sh[NVN_CT_FLOAT] = 16;
        vs->rf.v[0].sh[ct == NVN_CT_UINT ? NVN_CT_INT : NVN_CT_UINT] = 17;
    }
    pso_key k; memset(&k, 0, sizeof k); k.attr[0].fmt = (uint32_t)f; k.attr[0].offset = OFF; k.attr[0].stream = 0; k.stream[0].stride = STRIDE;
    state_reset(); S.nattr = 1; S.attr[0].fmt = (uint32_t)f; S.attr[0].offset = OFF; S.attr[0].stream = 0; S.stream[0].stride = STRIDE;
    int on = vin_on(vs, &k, capture);
    CHECK(on == vin_on(vs, NULL, capture), "%s: the pipeline's routes and the draw's differ", what);
    CHECK(!!(on & VIN_I2F) == (native_on && !capture), "%s: native fetch route %d", what, on);
    CHECK(vconv_wanted(&vs->rf, 0, &k, on) == !native && vconv_wanted(&vs->rf, 0, NULL, on) == !native, "%s: converted on the CPU %d, expected %d", what, vconv_wanted(&vs->rf, 0, &k, on), !native);
    if (capture) { CHECK(vconv_wanted(&vs->rf, 0, NULL, 0), "%s: a capture's hazard check misses the conversion", what); return; }   // nvn_geometry.inc asks with on = 0
    MTLRenderPipelineDescriptor *d = pso_desc(&k, vs, nil, nil, 0); d.rasterizationEnabled = NO;
    int at = native && ct != NVN_CT_FLOAT ? 16 : 0;
    MTLVertexAttributeDescriptor *ad = d.vertexDescriptor.attributes[at];
    if (native) CHECK(ad.bufferIndex == VB_SLOT(0) && ad.format == vfmt(f) && ad.offset == OFF, "%s: not read by Metal's fetch (slot %lu, format %lu)", what, (unsigned long)ad.bufferIndex, (unsigned long)ad.format);
    else CHECK(ad.bufferIndex == VCONV_SLOT0 && ad.format == (ct == NVN_CT_UINT ? MTLVertexFormatUInt4 : ct == NVN_CT_INT ? MTLVertexFormatInt4 : MTLVertexFormatFloat4), "%s: not read from the conversion slot", what);
    CHECK((d.vertexFunction == vs->vfn) == (native && ct != NVN_CT_FLOAT), "%s: shadow entry point chosen wrongly", what);
    // Every 8-bit value, every 16-bit value in each component; 32-bit ones a set of edges (they stay on the CPU)
    static const uint32_t E[] = { 0, 1, 127, 128, 255, 32767, 32768, 65535, 0xffffff, 0x1000000, 0x1000001, 0x1000003, 0x7fffffff, 0x80000000, 0xffffffff, 0x12345678 };
    int nv = ib == 8 ? 256 : ib == 16 ? 65536 : 64;
    id<MTLBuffer> vb = [dev newBufferWithLength:(NSUInteger)nv * STRIDE + 64 options:MTLResourceStorageModeShared]; uint8_t *p = vb.contents;
    for (int i = 0; i < nv * STRIDE + 64; i++) p[i] = (uint8_t)(i * 131 + 7);
    for (int v = 0; v < nv; v++) for (int c = 0; c < n; c++) {
        uint8_t *e = p + v * STRIDE + OFF;
        if (ib == 8) e[c] = (uint8_t)(v + 37 * c);
        else if (ib == 16) { uint16_t h = (uint16_t)(v + 9973 * c); memcpy(e + 2 * c, &h, 2); }
        else { uint32_t w = E[(v + 5 * c) % 16]; memcpy(e + 4 * c, &w, 4); }
    }
    (void)es;
    float *want = malloc((size_t)nv * 16); uint32_t *got = malloc((size_t)nv * 16);
    vconv_fill(f, (uint64_t)(uintptr_t)(p + OFF), STRIDE, (uint64_t)nv, want);   // the old route's words
    id<MTLBuffer> conv = native ? nil : [dev newBufferWithBytes:want length:(NSUInteger)nv * 16 options:MTLResourceStorageModeShared];
    if (draw_words(d, vb, conv, nv, got)) {
        int bad = 0; for (int v = 0; v < nv; v++) for (int c = 0; c < 4; c++) { uint32_t w; memcpy(&w, want + 4 * v + c, 4);
            if (got[4 * v + c] != w && bad++ < 3) printf("  %s vertex %d component %d: got %08x, the CPU conversion %08x\n", what, v, c, got[4 * v + c], w); }
        CHECK(!bad, "%s (%s): %d words differ from the CPU conversion", what, native ? "native fetch" : "CPU conversion", bad);
    } else CHECK(0, "%s: no pipeline or GPU failure", what);
    free(want); free(got);
}

int main(void) { @autoreleasepool {
    dev = MTLCreateSystemDefaultDevice(); if (!dev) return 2;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct F { float4 a [[attribute(0)]]; };\n"
        "vertex void vf(F in [[stage_in]], device uint4 *o [[buffer(13)]], uint v [[vertex_id]]) { o[v] = as_type<uint4>(in.a); }\n"
        "struct UB { uint4 a [[attribute(0)]]; }; struct IB { int4 a [[attribute(0)]]; };\n"
        "vertex void vu_b(UB in [[stage_in]], device uint4 *o [[buffer(13)]], uint v [[vertex_id]]) { o[v] = in.a; }\n"
        "vertex void vi_b(IB in [[stage_in]], device uint4 *o [[buffer(13)]], uint v [[vertex_id]]) { o[v] = as_type<uint4>(in.a); }\n"
        "struct US { uint4 a [[attribute(0)]]; float4 f [[attribute(16)]]; int4 s [[attribute(17)]]; };\n"
        "struct IS { int4 a [[attribute(0)]]; float4 f [[attribute(16)]]; uint4 s [[attribute(17)]]; };\n"
        "vertex void vu_s(US in [[stage_in]], device uint4 *o [[buffer(13)]], uint v [[vertex_id]]) { o[v] = in.a | as_type<uint4>(in.f) | as_type<uint4>(in.s); }\n"
        "vertex void vi_s(IS in [[stage_in]], device uint4 *o [[buffer(13)]], uint v [[vertex_id]]) { o[v] = as_type<uint4>(in.a) | as_type<uint4>(in.f) | in.s; }\n";
    NSError *err = nil; lib = t4_lib(src, nil, &err); if (!lib) { puts(err.localizedDescription.UTF8String); return 2; }
    zero = [dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(zero.contents, 0, 16);
    for (int f = 0x51; f <= 0x68; f++) {
        route(f, NVN_CT_FLOAT, 0, 0);
        for (int ct = NVN_CT_UINT; ct <= NVN_CT_INT; ct++) { route(f, ct, 1, 0); route(f, ct, 0, 0); }
        route(f, NVN_CT_FLOAT, 0, 1); route(f, NVN_CT_UINT, 1, 1);
    }
    // vconv_fill's decode-once loop against vconv_elem's per-element decode: unaligned source, an odd stride, stride 0, zero elements
    static uint8_t raw[64 * 23 + 8];
    for (size_t i = 0; i < sizeof raw; i++) raw[i] = (uint8_t)(i * 197 + 13);
    for (int f = 0x51; f <= 0x68; f++) for (int pass = 0; pass < 3; pass++) {
        int es = vconv_size(f); uint32_t stride = pass == 2 ? 0 : (uint32_t)es + 3 + (pass ? 4 : 0); const uint8_t *s = raw + 1 + 2 * pass;
        float got[64][4], want[64][4]; memset(got, 0xAB, sizeof got);
        vconv_fill(f, (uint64_t)(uintptr_t)s, stride, 64, &got[0][0]);
        for (int v = 0; v < 64; v++) vconv_elem(f, s + (size_t)v * stride, want[v]);
        CHECK(!memcmp(got, want, sizeof got), "format %#x stride %u: vconv_fill differs from vconv_elem", f, stride);
        float canary[4] = {7, 7, 7, 7}; vconv_fill(f, (uint64_t)(uintptr_t)s, stride, 0, canary);
        CHECK(canary[0] == 7 && canary[3] == 7, "format %#x: zero elements wrote", f);
    }
    // Ordinary 8 / 16-bit integers into a float input keep their register bits through the CPU (Monster Hunter Rise's flags), never a numeric conversion
    static const int ordinary[] = { 0x03, 0x04, 0x14, 0x15, 0x27, 0x2D };
    for (unsigned i = 0; i < sizeof ordinary / sizeof *ordinary; i++) {
        nvn_refl rf = {0}; rf.nv = 1; rf.v[0].ct = NVN_CT_FLOAT; memset(rf.v[0].sh, 0xff, sizeof rf.v[0].sh);
        pso_key k; memset(&k, 0, sizeof k); k.attr[0].fmt = (uint32_t)ordinary[i];
        CHECK(vconv_wanted(&rf, 0, &k, VIN_I2F) && vconv_wanted(&rf, 0, &k, VIN_I2F | VIN_SHADOW), "ordinary integer format %#x into a float input left the CPU conversion", ordinary[i]);
    }
    printf("t_i2f_fetch: %d checks, %d failed\n", checks, failed);
    return failed ? 1 : 0;
} }
