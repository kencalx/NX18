// The host's own Metal shaders (dm/gfx/msl/<name>.metal), compiled into the host when it is built (dm/gfx/tools/host_msl.py, which stops the build without the Metal toolchain).
// host_msl_lib loads one by name from the metallib the build made: no compile at run time, so the Metal performance HUD counts none and no thread waits for the compiler. There
// is no source fallback: a library that does not load is a [RED] line and nil. Libraries are made once per device and name.
// host_msl_cps / host_msl_rps build a host pipeline whole through an MTL4Compiler (no archive, no base to specialize): the host's own pipelines are Metal 4 ones
#pragma once
#import <Metal/Metal.h>

id<MTLLibrary> host_msl_lib(id<MTLDevice> dev, const char *name, NSError **e);
// lib's kernel name as a compute pipeline; cv (may be nil) specializes its function constants through an MTL4SpecializedFunctionDescriptor. The threadgroup size is left to
// the dispatch, as newComputePipelineStateWithFunction: left it
id<MTLComputePipelineState> host_msl_cps(id<MTL4Compiler> comp, id<MTLLibrary> lib, NSString *name, MTLFunctionConstantValues *cv, NSError **e);
// A render pipeline of lib's vs and fs. fs nil: the host's empty fragment function (dm/gfx/msl/nop_frag.metal), which Metal 4 needs whenever rasterization is on, as for a
// depth / stencil only draw. ncol colour attachments with formats cf (0: none) and write masks wm (nil: all channels), no blending; samples 0 counts as 1. A Metal 4
// pipeline names no depth / stencil format: it serves any
id<MTLRenderPipelineState> host_msl_rps(id<MTL4Compiler> comp, id<MTLLibrary> lib, NSString *vs, NSString *fs, int ncol, const MTLPixelFormat *cf, const MTLColorWriteMask *wm,
                                        NSUInteger samples, NSError **e);
