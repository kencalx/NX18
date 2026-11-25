// A compute pipeline error injected at the Metal 4 compiler, then the replay's own dispatch path (ported from NXNative 9df3c09fc, MIT, whose test injects at the MTLDevice):
// a compile the compiler service's death interrupted leaves the shader retryable and the next dispatch writes its result; a refusal is kept and not asked again; and a dispatch of
// nn::ndve's movie network reaches the engine (DM_NDVE_ENGINE=1) without the replay asking Metal for its pipeline, so the following layer continues the sequence in order.
#import <objc/runtime.h>
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed, compile_attempts;
static NSString *compile_error;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)

static id fail_compute_pipeline(id self, SEL sel, MTL4ComputePipelineDescriptor *d, MTL4CompilerTaskOptions *o, NSError **error) __attribute__((ns_returns_retained));
static id fail_compute_pipeline(id self, SEL sel, MTL4ComputePipelineDescriptor *d, MTL4CompilerTaskOptions *o, NSError **error) {
    (void)self; (void)sel; (void)d; (void)o;
    compile_attempts++;
    if (error) *error = [NSError errorWithDomain:@"TestMetalCompiler" code:2 userInfo:@{NSLocalizedDescriptionKey: compile_error}];
    return nil;
}
static id<MTLLibrary> g_tlib;
static NvShader *shader(const char *key) {
    NvShader *cs = [NvShader new];
    snprintf(cs->key, sizeof cs->key, "%s", key);
    cs->stage = 5; cs->fn = t4_fn(g_tlib, @"write_value");
    cs->arg_len = [cs->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    cs->rf.tg[0] = cs->rf.tg[1] = cs->rf.tg[2] = 1;
    cs->rf.nb = 1;
    cs->rf.b[0] = (nvn_rbind){.kind=NVN_RB_SBUFP, .rw=1, .reg=0, .aid=0};
    return cs;
}
static void begin(prog_t *pg, void *mem, size_t page) {
    mtl_sub_begin(); state_reset(); memset(&R, 0, sizeof R);
    S.cprog = pg;
    S.ssbo[5][0] = (p_bind_buf){.addr=(uint64_t)mem, .size=page};
}

int main(void) { @autoreleasepool {
    mtl_init();
    NSError *error = nil;
    g_tlib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct Args { device uint *out [[id(0)]]; };\n"
        "kernel void write_value(constant Args &a [[buffer(0)]]) { a.out[0] = 42; }\n", nil, &error);
    Method method = class_getInstanceMethod([(id)mtl_comp4() class], @selector(newComputePipelineStateWithDescriptor:compilerTaskOptions:error:));
    if (!g_tlib || !method) { fprintf(stderr, "cannot set up the compute test: %s\n", error.localizedDescription.UTF8String); return 1; }

    NvProg *program = [NvProg new];
    prog_t pg = {.serial=960011};
    serial_put(pg.serial, program);
    size_t page = (size_t)getpagesize();
    void *mem = NULL;
    if (posix_memalign(&mem, page, page)) return 1;
    memset(mem, 0, page);
    mtl_pool_add(mem, page);
    p_dispatch one = {.x=1, .y=1, .z=1};

    begin(&pg, mem, page);
    NvShader *retry = shader("1111111111111111");
    program->sh[5] = retry;
    compile_error = @"Compilation failed: XPC_ERROR_CONNECTION_INTERRUPTED";
    IMP original = method_setImplementation(method, (IMP)fail_compute_pipeline);
    dispatch(&one);
    method_setImplementation(method, original);
    CHECK(compile_attempts == 1 && !retry->cps_failed, "a compiler-service interruption leaves the shader retryable");
    dispatch(&one);
    uint64_t fence = mtl_sub_commit();
    CHECK(mtl_wait(fence, 5000000000ull), "the retry's submission completes");
    mtl_drain();
    CHECK(!mtl_last_commit_error() && *(uint32_t *)mem == 42, "the next dispatch builds the pipeline and writes the result");

    begin(&pg, mem, page);
    NvShader *refused = shader("2222222222222222");
    program->sh[5] = refused;
    compile_attempts = 0;
    compile_error = @"Compute pipeline refused";
    original = method_setImplementation(method, (IMP)fail_compute_pipeline);
    dispatch(&one);
    dispatch(&one);
    method_setImplementation(method, original);
    CHECK(compile_attempts == 1 && refused->cps_failed, "a permanent refusal is kept");

    // The reported failure came after the network's first three dispatches had been taken by the engine
    CHECK(ndve_sel() == NDVE_NET, "DM_NDVE_ENGINE=1: the host's network");
    CHECK(ndve_offsets(), "the model's weight offsets add up");
    g_nd.state = 2; g_nd.pos = 4; g_nd.w0 = 0x100000;
    program->sh[5] = shader(k_ndve_keys[4]);
    S.ssbo[5][2] = (p_bind_buf){.addr=g_nd.w0 + g_ndve_w[4], .size=1};
    S.ssbo[5][3] = (p_bind_buf){.addr=g_nd.w0 + g_ndve_b[4], .size=1};
    compile_attempts = 0;
    compile_error = @"Compilation failed: XPC_ERROR_CONNECTION_INTERRUPTED";
    original = method_setImplementation(method, (IMP)fail_compute_pipeline);
    dispatch(&one);
    method_setImplementation(method, original);
    CHECK(compile_attempts == 0 && g_nd.pos == 5, "the engine takes the layer without the replay asking Metal for its pipeline");

    program->sh[5] = shader(k_ndve_keys[5]);
    S.ssbo[5][2].addr = g_nd.w0 + g_ndve_w[5];
    S.ssbo[5][3].addr = g_nd.w0 + g_ndve_b[5];
    dispatch(&one);
    CHECK(g_nd.pos == 6 && !g_nd.off, "the following layer continues the network in order");
    fence = mtl_sub_commit();
    CHECK(mtl_wait(fence, 5000000000ull), "the NDVE submission completes");
    mtl_drain();
    mtl_pool_del(mem);
    mtl_drain();
    free(mem);
    printf("t_dispatch_pipeline: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
