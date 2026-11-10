// The GPU capture profile (nvn_mtl.m pso4_capture). A run that loads Metal's capture layer (MTL_CAPTURE_ENABLED, DM_GPU_CAPTURE, or an iOS app whose Info.plist has
// MetalCaptureEnabled) opens no pipeline archive, neither the one bundled with the app (DM_PSO_BUNDLE) nor the device's folder (DM_PSO_ARCHIVE), makes no pipeline
// serializer, writes no archive file and never compiles with lookupArchives; it still builds every pipeline through the Metal 4 compiler: a base specialized for its colour
// state, a PSO_WHOLE pipeline whole, a depth-only one with the empty fragment, compute pipelines with and without function constants, and they draw and dispatch.
// Modes (one folder, in this order, as make runs them):
//   seed <dir>     no capture variable: builds the pipelines into <dir>/archive, writes the file, and copies it as <dir>/bundle/<GPU architecture>.mtl4a
//   capture <dir>  a capture variable set: neither folder is opened (Metal's newArchiveWithURL is never called), nothing is written into them
//   normal <dir>   no capture variable (DM_PSO_MTL4=0 set, which is ignored): both are opened and a serializer made, so the capture run's checks are not vacuous
// Also: capture_profile_why's table (the Info.plist key without a variable).
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#include <objc/runtime.h>
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, ...) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

// What the device and the compilers are asked, counted by replacing the methods of their classes (whatever layer wraps them) before pso4_init runs
static _Atomic int n_archive, n_serializer, n_render, n_compute, n_spec, n_lookup;
typedef id (*fn_arch)(id, SEL, NSURL *, NSError **) __attribute__((ns_returns_retained));
typedef id (*fn_ser)(id, SEL, id) __attribute__((ns_returns_retained));
typedef id (*fn_comp)(id, SEL, id, MTL4CompilerTaskOptions *, NSError **) __attribute__((ns_returns_retained));
typedef id (*fn_spec_t)(id, SEL, id, id, NSError **) __attribute__((ns_returns_retained));
static fn_arch o_archive; static fn_ser o_serializer; static fn_comp o_render, o_compute; static fn_spec_t o_spec;
static id c_archive(id s, SEL c, NSURL *u, NSError **e) __attribute__((ns_returns_retained)) { atomic_fetch_add(&n_archive, 1); return o_archive(s, c, u, e); }
static id c_serializer(id s, SEL c, id d) __attribute__((ns_returns_retained)) { atomic_fetch_add(&n_serializer, 1); return o_serializer(s, c, d); }
static void lookups(MTL4CompilerTaskOptions *o) { if (o.lookupArchives.count) atomic_fetch_add(&n_lookup, 1); }
static id c_render(id s, SEL c, id d, MTL4CompilerTaskOptions *o, NSError **e) __attribute__((ns_returns_retained)) { atomic_fetch_add(&n_render, 1); lookups(o); return o_render(s, c, d, o, e); }
static id c_compute(id s, SEL c, id d, MTL4CompilerTaskOptions *o, NSError **e) __attribute__((ns_returns_retained)) { atomic_fetch_add(&n_compute, 1); lookups(o); return o_compute(s, c, d, o, e); }
static id c_spec(id s, SEL c, id d, id b, NSError **e) __attribute__((ns_returns_retained)) { atomic_fetch_add(&n_spec, 1); return o_spec(s, c, d, b, e); }
static IMP swap(id obj, SEL sel, IMP to) {
    Method m = class_getInstanceMethod(object_getClass(obj), sel);
    if (!m) { fprintf(stderr, "%s has no %s\n", object_getClassName(obj), sel_getName(sel)); abort(); }
    return method_setImplementation(m, to);
}
static void count_calls(void) {
    o_archive = (fn_arch)swap(g_dev, @selector(newArchiveWithURL:error:), (IMP)c_archive);
    o_serializer = (fn_ser)swap(g_dev, @selector(newPipelineDataSetSerializerWithDescriptor:), (IMP)c_serializer);
    o_render = (fn_comp)swap(g_comp4, @selector(newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:), (IMP)c_render);
    o_compute = (fn_comp)swap(g_comp4, @selector(newComputePipelineStateWithDescriptor:compilerTaskOptions:error:), (IMP)c_compute);
    o_spec = (fn_spec_t)swap(g_comp4, @selector(newRenderPipelineStateBySpecializationWithDescriptor:pipeline:error:), (IMP)c_spec);
}

static NSArray<NSString *> *files(NSString *dir) { return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)] ?: @[]; }

static void table(void) {
    CHECK(!capture_profile_why(NULL, NULL, nil), "no variable, no key: the archive");
    CHECK(capture_profile_why("1", NULL, nil), "MTL_CAPTURE_ENABLED");
    CHECK(capture_profile_why(NULL, "5", nil), "DM_GPU_CAPTURE");
    CHECK(capture_profile_why(NULL, NULL, @YES) && !strcmp(capture_profile_why(NULL, NULL, @YES), "Info.plist MetalCaptureEnabled"), "Info.plist MetalCaptureEnabled with no variable (Xcode's capture button)");
    CHECK(capture_profile_why(NULL, NULL, @"YES"), "Info.plist MetalCaptureEnabled as a string");
    CHECK(!capture_profile_why(NULL, NULL, @NO), "Info.plist MetalCaptureEnabled false");
}

static id<MTLLibrary> g_lib;
static MTLRenderPipelineDescriptor *render_desc(MTLPixelFormat f, id<MTLFunction> fs) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    static id<MTLFunction> vs; if (!vs) vs = t4_fn(g_lib, @"vs");
    d.vertexFunction = vs; d.fragmentFunction = fs; d.colorAttachments[0].pixelFormat = f; d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;
    return d;
}
// Draws a full-target triangle with ps into an RGBA8 target cleared to black: its pixel (1, 1)
static uint32_t draw_px(id<MTLRenderPipelineState> ps) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO];
    dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 0);
    rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    rp.depthAttachment.texture = [g_dev newTextureWithDescriptor:dd]; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> enc = t4_pass(cb, rp);
    [enc setRenderPipelineState:t4_keep(cb, ps)]; [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; t4_end(cb, enc);
    if (t4_wait(cb) != MTLCommandBufferStatusCompleted) return 0xdeadbeef;
    uint32_t px[16]; [t getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(0, 0, 4, 4) mipmapLevel:0];
    return px[5];
}
static uint32_t run_cs(id<MTLComputePipelineState> ps) {
    id<MTLBuffer> b = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared]; memset(b.contents, 0, 16);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> enc = t4_compute(cb);
    [enc setComputePipelineState:t4_keep(cb, ps)]; t4_buf(cb, enc, T4_CS, b, 0, 0);
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; t4_end(cb, enc);
    if (t4_wait(cb) != MTLCommandBufferStatusCompleted) return 0xdeadbeef;
    return *(uint32_t *)b.contents;
}
// Every kind of pipeline the game's draws and dispatches build, through pso_build and cps_new
static void pipelines(const char *mode) {
    NSError *e = nil; int spec0 = n_spec, render0;
    id<MTLRenderPipelineState> a = pso_build(render_desc(MTLPixelFormatRGBA8Unorm, t4_fn(g_lib, @"fs")), &e);
    CHECK(a && draw_px(a) == 0xff4080ffu, "%s: a pipeline specialized from its base draws (%s)", mode, e ? e.localizedDescription.UTF8String : "-");
    CHECK(n_spec == spec0 + 1, "%s: by specialization (%d)", mode, n_spec - spec0);
    MTLRenderPipelineDescriptor *wd = render_desc(MTLPixelFormatRGBA8Unorm, t4_fn(g_lib, @"fs2")); wd.label = PSO_WHOLE; spec0 = n_spec; render0 = n_render;
    id<MTLRenderPipelineState> w = pso_build(wd, &e);
    CHECK(w && draw_px(w) == 0xff00ff00u, "%s: a pipeline built whole draws", mode);
    CHECK(n_spec == spec0 && n_render == render0 + 1, "%s: whole, by one compile (%d, %d)", mode, n_spec - spec0, n_render - render0);
    id<MTLRenderPipelineState> z = pso_build(render_desc(MTLPixelFormatInvalid, nil), &e);
    CHECK(z != nil, "%s: a depth-only pipeline (the empty fragment)", mode);
    int compute0 = n_compute;
    id<MTLComputePipelineState> c = cps_new(t4_fn(g_lib, @"cs"), &e);
    CHECK(c && run_cs(c) == 7, "%s: a compute pipeline dispatches", mode);
    MTLFunctionConstantValues *cv = [MTLFunctionConstantValues new]; uint32_t k = 42; [cv setConstantValue:&k type:MTLDataTypeUInt atIndex:0];
    id<MTLComputePipelineState> ck = cps_new(fn_spec(g_lib, @"ck", cv, &e), &e);
    CHECK(ck && run_cs(ck) == 42, "%s: a compute pipeline with its constants from the function's note dispatches", mode);
    if (!strcmp(mode, "capture")) CHECK(n_compute >= compute0 + 2, "%s: both compiled (%d)", mode, n_compute - compute0);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc != 3) { fprintf(stderr, "usage: t_pso_capture seed|capture|normal <dir>\n"); return 2; }
    const char *mode = argv[1]; NSString *dir = @(argv[2]), *arch = [dir stringByAppendingPathComponent:@"archive"], *bundle = [dir stringByAppendingPathComponent:@"bundle"];
    int capture = !strcmp(mode, "capture"), seed = !strcmp(mode, "seed");
    if (!capture && !seed && strcmp(mode, "normal")) { fprintf(stderr, "unknown mode %s\n", mode); return 2; }
    table();
    setenv("DM_PSO_ARCHIVE", arch.UTF8String, 1); setenv("DM_PSO_HYBRID", "0", 1); unsetenv("DM_PSO_MANIFEST");
    if (seed) unsetenv("DM_PSO_BUNDLE"); else setenv("DM_PSO_BUNDLE", bundle.UTF8String, 1);
    CHECK(!!pso4_capture() == capture, "%s: the capture profile %s (%s)", mode, capture ? "on" : "off", pso4_capture() ?: "no capture variable");
    mtl_init(); NSError *err = nil;
    g_lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); return float4(uv * 2 - 1, 0.5, 1); }\n"
        "fragment float4 fs() { return float4(1, 0.5, 0.25, 1); }\n"
        "fragment float4 fs2() { return float4(0, 1, 0, 1); }\n"
        "kernel void cs(device uint *o [[buffer(0)]]) { o[0] = 7; }\n"
        "constant uint k [[function_constant(0)]];\n"
        "kernel void ck(device uint *o [[buffer(0)]]) { o[0] = is_function_constant_defined(k) ? k : 1; }\n", nil, &err);
    if (!g_lib) { fprintf(stderr, "the fixture's shaders did not compile: %s\n", err.localizedDescription.UTF8String); return 1; }
    NSArray<NSString *> *before = files(arch), *bundled = files(bundle);
    count_calls();
    pso4_init();
    if (capture) {
        CHECK(before.count > 0 && bundled.count > 0, "capture: the seeded folder and bundle hold files to leave alone (%lu, %lu)", (unsigned long)before.count, (unsigned long)bundled.count);
        CHECK(!g_arch_dir && !g_arch_bundle && !g_arch4.count && !g_arch4p.count && !g_arch_cap && !g_ep, "capture: no archive opened, none captured into");
    } else {
        CHECK(g_arch_dir && g_arch_cap && g_ep, "%s: the archive folder is opened and captured into", mode);
        if (!seed) CHECK(g_arch_bundle != nil && n_archive >= 2, "normal: the bundled archive and the folder's file are opened (%d opens)", n_archive);
    }
    pipelines(mode);
    if (!capture) arch_flush_wait();
    mtl_arch_save(ARCH_QUIT_WAIT_MS, 0);
    NSArray<NSString *> *after = files(arch);
    if (capture) {
        CHECK(n_archive == 0, "capture: newArchiveWithURL never called (%d)", n_archive);
        CHECK(n_serializer == 0, "capture: no pipeline serializer made (%d)", n_serializer);
        CHECK([after isEqual:before] && [files(bundle) isEqual:bundled], "capture: nothing written into the archive folder or the bundle");
    } else {
        CHECK(n_serializer > 0, "%s: a pipeline serializer made", mode);
        if (seed) CHECK(after.count > before.count, "seed: the archive folder gets a file (%lu)", (unsigned long)after.count);
    }
    CHECK(n_lookup == 0, "%s: no compile with lookupArchives (%d)", mode, n_lookup);
    if (seed) {   // the folder's file as the archive bundled with the app, under this GPU's name (pso_bundle_open)
        NSString *f = nil; for (NSString *n in after) if ([n hasSuffix:@".mtl4a"]) f = n;
        [NSFileManager.defaultManager createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil];
        NSString *to = [bundle stringByAppendingPathComponent:[g_dev.architecture.name stringByAppendingPathExtension:@"mtl4a"]];
        CHECK(f && [NSFileManager.defaultManager copyItemAtPath:[arch stringByAppendingPathComponent:f] toPath:to error:&err], "seed: the bundle written (%s)", err ? err.localizedDescription.UTF8String : "no file");
    }
    printf("t_pso_capture %s: %d checks, %d failed\n", mode, checks, failed);
    if (!strcmp(mode, "normal") && [dir hasPrefix:@"/tmp/t_pso_capture."]) [NSFileManager.defaultManager removeItemAtPath:dir error:nil];   // the last mode: make's folder goes
    return failed != 0;
} }
