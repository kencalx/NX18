#import "host_msl.h"
#include "host_msl_gen.h"
#include <os/lock.h>
#include <string.h>

#define HLOG(...) do { fprintf(stderr, "[dm] [msl] " __VA_ARGS__); fputc('\n', stderr); } while (0)

id<MTLLibrary> host_msl_lib(id<MTLDevice> dev, const char *name, NSError **e) {
    static os_unfair_lock lk = OS_UNFAIR_LOCK_INIT; static NSMutableDictionary<NSString *, id<MTLLibrary>> *libs; static int said;
    if (!dev || !name) return nil;
    NSString *key = [NSString stringWithFormat:@"%p/%s", (__bridge void *)dev, name];
    os_unfair_lock_lock(&lk);
    if (!libs) libs = [NSMutableDictionary dictionary];
    id<MTLLibrary> lib = libs[key];
    if (!said++) HLOG("host shader libraries: %lu, compiled for %s by %s", sizeof k_host_msl / sizeof *k_host_msl, HOST_MSL_SDK, HOST_MSL_COMPILER);
    os_unfair_lock_unlock(&lk);
    if (lib) return lib;
    int i = 0, n = (int)(sizeof k_host_msl / sizeof *k_host_msl);
    while (i < n && strcmp(k_host_msl[i].name, name)) i++;
    if (i == n) { HLOG("[RED] no host shader library %s (dm/gfx/msl/%s.metal)", name, name); return nil; }
    dispatch_data_t d = dispatch_data_create(k_host_msl[i].lib, k_host_msl[i].lib_len, NULL, ^{});   // static bytes: nothing to free
    lib = [dev newLibraryWithData:d error:e];
    if (!lib) { HLOG("[RED] host shader library %s did not load (%s): built for %s by %s", name, e && *e ? (*e).localizedDescription.UTF8String : "no error given", HOST_MSL_SDK, HOST_MSL_COMPILER); return nil; }
    lib.label = @(name);
    os_unfair_lock_lock(&lk);
    id<MTLLibrary> had = libs[key]; if (had) lib = had; else libs[key] = lib;   // another thread made it meanwhile: one library per name
    os_unfair_lock_unlock(&lk);
    return lib;
}

// lib's function name as a Metal 4 descriptor; nil with an error when lib has none of that name (the compiler's validation layer asserts on such a descriptor)
static MTL4FunctionDescriptor *host_fd(id<MTLLibrary> lib, NSString *name, MTLFunctionConstantValues *cv, NSError **e) {
    if (![lib.functionNames containsObject:name]) {
        if (e) *e = [NSError errorWithDomain:@"dm" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"no function %@ in the host library %@", name, lib.label]}];
        return nil;
    }
    MTL4LibraryFunctionDescriptor *ld = [MTL4LibraryFunctionDescriptor new]; ld.library = lib; ld.name = name;
    if (!cv) return ld;
    MTL4SpecializedFunctionDescriptor *sd = [MTL4SpecializedFunctionDescriptor new]; sd.functionDescriptor = ld; sd.constantValues = cv;
    return sd;
}

id<MTLComputePipelineState> host_msl_cps(id<MTL4Compiler> comp, id<MTLLibrary> lib, NSString *name, MTLFunctionConstantValues *cv, NSError **e) {
    if (!comp || !lib || !name) return nil;
    MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new];
    if (!(d.computeFunctionDescriptor = host_fd(lib, name, cv, e))) return nil;
    d.label = name;
    return [comp newComputePipelineStateWithDescriptor:d compilerTaskOptions:nil error:e];
}

id<MTLRenderPipelineState> host_msl_rps(id<MTL4Compiler> comp, id<MTLLibrary> lib, NSString *vs, NSString *fs, int ncol, const MTLPixelFormat *cf, const MTLColorWriteMask *wm,
                                        NSUInteger samples, NSError **e) {
    if (!comp || !lib || !vs || ncol < 0 || ncol > 8 || (ncol && !cf)) return nil;
    id<MTLLibrary> flib = lib;
    if (!fs) { flib = host_msl_lib(comp.device, "nop_frag", e); fs = @"dm_nop"; if (!flib) return nil; }
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    if (!(d.vertexFunctionDescriptor = host_fd(lib, vs, nil, e)) || !(d.fragmentFunctionDescriptor = host_fd(flib, fs, nil, e))) return nil;
    d.rasterSampleCount = samples ? samples : 1; d.label = [NSString stringWithFormat:@"%@/%@", vs, fs];
    for (int i = 0; i < ncol; i++) if (cf[i]) { d.colorAttachments[i].pixelFormat = cf[i]; d.colorAttachments[i].writeMask = wm ? wm[i] : MTLColorWriteMaskAll; }
    return [comp newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:e];
}
