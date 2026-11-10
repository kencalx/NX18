// Metal 4 command buffers and pipelines for the test fixtures: one API, two back ends.
//
// A fixture that #includes nvn_mtl.m (before this header) gets the production back end: its command buffers are the host's one-off command buffers (NvOnce: once_new(1),
// once_copy, once_end, once_wait) on the Metal 4 queue g_q4, ordered behind the uploads and the encode thread's records as the host's own readbacks are, its resources made
// resident through once_use, and its functions noted for the host's pipelines through fn4_note. Any other fixture (and the runners the Python tests write) gets the standalone
// back end: an MTL4CommandQueue of its own with a residency set, allocators and argument tables, and a map of its own for the function descriptors. T4_STANDALONE forces it.
//
// Metal 4 makes nothing resident and tracks no hazard by itself:
//   - every texture, buffer or heap an encoder reads or writes goes through t4_use (t4_buf / t4_tex / t4_pass / t4_bytes do it for what they bind);
//   - each encoder starts with a queue barrier (after all earlier work) and ends with one (t4_end: before all later work);
//   - dispatches and copies in one compute encoder may overlap: t4_barrier between two that depend on each other.
// Bindings go through argument tables (one per stage and command buffer); set*Bytes, which Metal 4 does not have, through a scratch buffer (t4_bytes). Samplers bound
// through t4_samp need supportArgumentBuffers. Pipelines are built by an MTL4Compiler from the Metal 4 function descriptors t4_fn / t4_fn_cv noted (t4_cps, t4_rps, t4_mps),
// libraries from source through it too (t4_lib).
#pragma once
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <dispatch/dispatch.h>
#include <os/lock.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#if !defined(T4_STANDALONE) && defined(MDIE) && defined(res_add)
#define T4_NVN 1
#else
#define T4_NVN 0
#endif

enum { T4_CS, T4_VS, T4_FS, T4_OS, T4_MS, T4_NSTAGE };   // the argument table's stage: compute, vertex, fragment, object, mesh
enum { T4_SCRATCH = 64 << 10, T4_BUFS = 31, T4_TEXS = 31, T4_SAMPS = 16 };

#define T4_DIE(...) do { fprintf(stderr, "[t_mtl4] FATAL "); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); abort(); } while (0)

@interface T4 : NSObject {
@public
#if T4_NVN
    NvOnce *o;
#else
    id<MTL4CommandBuffer> cb; id<MTL4CommandAllocator> al; NSMutableArray *used;
#endif
    id<MTL4ArgumentTable> tab[T4_NSTAGE];
    NSMutableArray<id<MTLBuffer>> *scratch; NSUInteger scratch_at;
    long status;   // MTLCommandBufferStatusCompleted / MTLCommandBufferStatusError once t4_wait returned, else MTLCommandBufferStatusNotEnqueued
}
@end
@implementation T4 @end

// ---- device, compiler, libraries, functions, pipelines -----------------------------------------------------------------------------------------------------------------

static inline id<MTLDevice> t4_dev(void) {
#if T4_NVN
    if (!g_dev) T4_DIE("t4_dev before mtl_init");
    return g_dev;
#else
    static id<MTLDevice> dev; static dispatch_once_t once;
    dispatch_once(&once, ^{ dev = MTLCreateSystemDefaultDevice(); });
    if (!dev) T4_DIE("no Metal device");
    if (![dev supportsFamily:MTLGPUFamilyMetal4]) T4_DIE("the Metal device %s has no Metal 4", dev.name.UTF8String);
    return dev;
#endif
}
static inline id<MTL4Compiler> t4_comp(void) {   // the fixtures' own compiler (the host's g_comp4 is made only with its pipeline archive)
    static id<MTL4Compiler> comp; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *e = nil; comp = [t4_dev() newCompilerWithDescriptor:[MTL4CompilerDescriptor new] error:&e];
        if (!comp) T4_DIE("no MTL4Compiler: %s", e.localizedDescription.UTF8String);
    });
    return comp;
}
// A library from MSL source, compiled through the MTL4Compiler (opt may be nil)
static inline id<MTLLibrary> t4_lib(NSString *src, MTLCompileOptions *opt, NSError **e) {
    MTL4LibraryDescriptor *d = [MTL4LibraryDescriptor new]; d.source = src; if (opt) d.options = opt;
    return [t4_comp() newLibraryWithDescriptor:d error:e];
}
#if !T4_NVN
static os_unfair_lock g_t4_fn_lk = OS_UNFAIR_LOCK_INIT;
static NSMapTable *g_t4_fn;   // id<MTLFunction> → MTL4FunctionDescriptor, by identity
#endif
static inline id<MTLFunction> t4_note(id<MTLFunction> f, id<MTLLibrary> lib, NSString *name, MTLFunctionConstantValues *cv) {
#if T4_NVN
    return fn4_note(f, lib, name, cv);
#else
    if (!f || !lib || !name) return f;
    MTL4LibraryFunctionDescriptor *ld = [MTL4LibraryFunctionDescriptor new]; ld.library = lib; ld.name = name;
    MTL4FunctionDescriptor *d = ld;
    if (cv) { MTL4SpecializedFunctionDescriptor *sd = [MTL4SpecializedFunctionDescriptor new]; sd.functionDescriptor = ld; sd.constantValues = cv; d = sd; }
    os_unfair_lock_lock(&g_t4_fn_lk);
    if (!g_t4_fn) g_t4_fn = [[NSMapTable alloc] initWithKeyOptions:NSPointerFunctionsStrongMemory | NSPointerFunctionsObjectPointerPersonality valueOptions:NSPointerFunctionsStrongMemory capacity:0];
    [g_t4_fn setObject:d forKey:f];
    os_unfair_lock_unlock(&g_t4_fn_lk);
    return f;
#endif
}
// The Metal 4 descriptor t4_fn / t4_fn_cv noted for f (nil for a function made some other way)
static inline MTL4FunctionDescriptor *t4_fd(id<MTLFunction> f) {
    if (!f) return nil;
#if T4_NVN
    return fn4_of(f);
#else
    os_unfair_lock_lock(&g_t4_fn_lk); MTL4FunctionDescriptor *d = [g_t4_fn objectForKey:f]; os_unfair_lock_unlock(&g_t4_fn_lk);
    return d;
#endif
}
// A function of lib, noted for Metal 4 pipelines (also the host's: pso_build takes the note). nil when lib has no such function
static inline id<MTLFunction> t4_fn(id<MTLLibrary> lib, NSString *name) { return lib && name ? t4_note([lib newFunctionWithName:name], lib, name, nil) : nil; }
// A function that declares function constants, specialized with cv by the pipeline that uses it (MTL4SpecializedFunctionDescriptor): the MTLFunction itself stays unspecialized,
// so its reflection is the library's; nothing is compiled through the MTLDevice
static inline id<MTLFunction> t4_fn_cv(id<MTLLibrary> lib, NSString *name, MTLFunctionConstantValues *cv, NSError **e) {
    id<MTLFunction> f = lib && name ? [lib newFunctionWithName:name] : nil;
    if (!f) { if (e) *e = [NSError errorWithDomain:@"t_mtl4" code:1 userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:@"no function %@ in the library", name]}]; return nil; }
    return t4_note(f, lib, name, cv ? cv : [MTLFunctionConstantValues new]);
}
static inline NSError *t4_err(NSString *what) { return [NSError errorWithDomain:@"t_mtl4" code:2 userInfo:@{NSLocalizedDescriptionKey: what}]; }
static inline MTL4FunctionDescriptor *t4_fd_or(id<MTLFunction> f, const char *stage, NSError **e) {
    MTL4FunctionDescriptor *d = t4_fd(f);
    if (f && !d && e) *e = t4_err([NSString stringWithFormat:@"%s function %@ was not made through t4_fn / t4_fn_cv: no Metal 4 descriptor", stage, f.name]);
    return d;
}
static inline id<MTLComputePipelineState> t4_cps_desc(MTLComputePipelineDescriptor *s, NSError **e) {
    MTL4ComputePipelineDescriptor *d = [MTL4ComputePipelineDescriptor new];
    if (!(d.computeFunctionDescriptor = t4_fd_or(s.computeFunction, "compute", e))) return nil;
    d.threadGroupSizeIsMultipleOfThreadExecutionWidth = s.threadGroupSizeIsMultipleOfThreadExecutionWidth;
    d.maxTotalThreadsPerThreadgroup = s.maxTotalThreadsPerThreadgroup;
    d.requiredThreadsPerThreadgroup = s.requiredThreadsPerThreadgroup;
    if (s.label) d.label = s.label;
    return [t4_comp() newComputePipelineStateWithDescriptor:d compilerTaskOptions:nil error:e];
}
static inline id<MTLComputePipelineState> t4_cps(id<MTLFunction> f, NSError **e) {
    if (!f) { if (e) *e = t4_err(@"no compute function"); return nil; }
    MTLComputePipelineDescriptor *d = [MTLComputePipelineDescriptor new]; d.computeFunction = f;
    return t4_cps_desc(d, e);
}
// The fragment a rasterizing pipeline without one gets (a Metal 4 render pipeline that rasterizes names a fragment function)
static inline MTL4FunctionDescriptor *t4_nop_frag(void) {
    static MTL4FunctionDescriptor *d; static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSError *e = nil; id<MTLLibrary> lib = t4_lib(@"fragment void t4_nop_frag() {}\n", nil, &e);
        if (!lib) T4_DIE("no-op fragment: %s", e.localizedDescription.UTF8String);
        MTL4LibraryFunctionDescriptor *ld = [MTL4LibraryFunctionDescriptor new]; ld.library = lib; ld.name = @"t4_nop_frag"; d = ld;
    });
    return d;
}
static inline void t4_colors(MTL4RenderPipelineColorAttachmentDescriptorArray *to, MTLRenderPipelineColorAttachmentDescriptorArray *from) {
    for (NSUInteger i = 0; i < 8; i++) {
        MTLRenderPipelineColorAttachmentDescriptor *s = from[i]; MTL4RenderPipelineColorAttachmentDescriptor *c = to[i];
        c.pixelFormat = s.pixelFormat; c.writeMask = s.writeMask;
        c.blendingState = s.blendingEnabled ? MTL4BlendStateEnabled : MTL4BlendStateDisabled;
        c.sourceRGBBlendFactor = s.sourceRGBBlendFactor; c.destinationRGBBlendFactor = s.destinationRGBBlendFactor; c.rgbBlendOperation = s.rgbBlendOperation;
        c.sourceAlphaBlendFactor = s.sourceAlphaBlendFactor; c.destinationAlphaBlendFactor = s.destinationAlphaBlendFactor; c.alphaBlendOperation = s.alphaBlendOperation;
    }
}
// A render pipeline as the Metal 3 descriptor describes it (its functions made through t4_fn / t4_fn_cv). Metal 4 pipelines name no depth / stencil format: those are left out
static inline id<MTLRenderPipelineState> t4_rps(MTLRenderPipelineDescriptor *s, NSError **e) {
    MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new];
    if (!(d.vertexFunctionDescriptor = t4_fd_or(s.vertexFunction, "vertex", e))) { if (e && !*e) *e = t4_err(@"no vertex function"); return nil; }
    if (s.fragmentFunction && !(d.fragmentFunctionDescriptor = t4_fd_or(s.fragmentFunction, "fragment", e))) return nil;
    if (!s.fragmentFunction && s.rasterizationEnabled) d.fragmentFunctionDescriptor = t4_nop_frag();
    d.vertexDescriptor = s.vertexDescriptor;
    d.rasterSampleCount = s.rasterSampleCount;
    d.alphaToCoverageState = s.alphaToCoverageEnabled ? MTL4AlphaToCoverageStateEnabled : MTL4AlphaToCoverageStateDisabled;
    d.alphaToOneState = s.alphaToOneEnabled ? MTL4AlphaToOneStateEnabled : MTL4AlphaToOneStateDisabled;
    d.rasterizationEnabled = s.rasterizationEnabled;
    d.inputPrimitiveTopology = s.inputPrimitiveTopology;
    d.maxVertexAmplificationCount = s.maxVertexAmplificationCount;
    t4_colors(d.colorAttachments, s.colorAttachments);
    if (s.label) d.label = s.label;
    return [t4_comp() newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:e];
}
static inline id<MTLRenderPipelineState> t4_mps(MTLMeshRenderPipelineDescriptor *s, NSError **e) {
    MTL4MeshRenderPipelineDescriptor *d = [MTL4MeshRenderPipelineDescriptor new];
    if (s.objectFunction && !(d.objectFunctionDescriptor = t4_fd_or(s.objectFunction, "object", e))) return nil;
    if (!(d.meshFunctionDescriptor = t4_fd_or(s.meshFunction, "mesh", e))) { if (e && !*e) *e = t4_err(@"no mesh function"); return nil; }
    if (s.fragmentFunction && !(d.fragmentFunctionDescriptor = t4_fd_or(s.fragmentFunction, "fragment", e))) return nil;
    if (!s.fragmentFunction && s.rasterizationEnabled) d.fragmentFunctionDescriptor = t4_nop_frag();
    d.maxTotalThreadsPerObjectThreadgroup = s.maxTotalThreadsPerObjectThreadgroup; d.maxTotalThreadsPerMeshThreadgroup = s.maxTotalThreadsPerMeshThreadgroup;
    d.requiredThreadsPerObjectThreadgroup = s.requiredThreadsPerObjectThreadgroup; d.requiredThreadsPerMeshThreadgroup = s.requiredThreadsPerMeshThreadgroup;
    d.objectThreadgroupSizeIsMultipleOfThreadExecutionWidth = s.objectThreadgroupSizeIsMultipleOfThreadExecutionWidth;
    d.meshThreadgroupSizeIsMultipleOfThreadExecutionWidth = s.meshThreadgroupSizeIsMultipleOfThreadExecutionWidth;
    d.payloadMemoryLength = s.payloadMemoryLength; d.maxTotalThreadgroupsPerMeshGrid = s.maxTotalThreadgroupsPerMeshGrid;
    d.rasterSampleCount = s.rasterSampleCount;
    d.alphaToCoverageState = s.alphaToCoverageEnabled ? MTL4AlphaToCoverageStateEnabled : MTL4AlphaToCoverageStateDisabled;
    d.alphaToOneState = s.alphaToOneEnabled ? MTL4AlphaToOneStateEnabled : MTL4AlphaToOneStateDisabled;
    d.rasterizationEnabled = s.rasterizationEnabled;
    d.maxVertexAmplificationCount = s.maxVertexAmplificationCount;
    t4_colors(d.colorAttachments, s.colorAttachments);
    if (s.label) d.label = s.label;
    return [t4_comp() newRenderPipelineStateWithDescriptor:d compilerTaskOptions:nil error:e];
}

// ---- command buffers -------------------------------------------------------------------------------------------------------------------------------------------------

#if !T4_NVN
static id<MTL4CommandQueue> g_t4_q; static id<MTLResidencySet> g_t4_res; static NSCountedSet *g_t4_rc;
static os_unfair_lock g_t4_lk = OS_UNFAIR_LOCK_INIT;   // the residency counts and the allocator pool
enum { T4_KEEP = 4 }; static __strong id<MTL4CommandAllocator> g_t4_al[T4_KEEP]; static int g_t4_nal;
static inline void t4_init(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        id<MTLDevice> dev = t4_dev(); NSError *e = nil;
        MTL4CommandQueueDescriptor *qd = [MTL4CommandQueueDescriptor new]; qd.label = @"t_mtl4";
        if (!(g_t4_q = [dev newMTL4CommandQueueWithDescriptor:qd error:&e])) T4_DIE("no MTL4CommandQueue: %s", e.localizedDescription.UTF8String);
        MTLResidencySetDescriptor *rd = [MTLResidencySetDescriptor new]; rd.label = @"t_mtl4";
        if (!(g_t4_res = [dev newResidencySetWithDescriptor:rd error:&e])) T4_DIE("no residency set: %s", e.localizedDescription.UTF8String);
        [g_t4_q addResidencySet:g_t4_res];
        g_t4_rc = [NSCountedSet set];
    });
}
#endif
static inline MTL4VisibilityOptions t4_vis(void) {
#if T4_NVN
    return resource_vis();
#else
    return MTL4VisibilityOptionDevice;
#endif
}
// A command buffer of its own (in place of a classic queue's): ordered after everything committed before it
static inline T4 *t4_begin(void) {
    T4 *t = [T4 new]; t->status = MTLCommandBufferStatusNotEnqueued;
#if T4_NVN
    if (!g_q4) T4_DIE("t4_begin without the Metal 4 queue (mtl_init first)");
    t->o = once_new(1);
#else
    t4_init();
    os_unfair_lock_lock(&g_t4_lk);
    if (g_t4_nal) { t->al = g_t4_al[--g_t4_nal]; g_t4_al[g_t4_nal] = nil; }
    os_unfair_lock_unlock(&g_t4_lk);
    if (t->al) [t->al reset]; else t->al = [t4_dev() newCommandAllocator];
    t->cb = [t4_dev() newCommandBuffer];
    if (!t->al || !t->cb) T4_DIE("no Metal 4 command allocator / buffer");
    [t->cb beginCommandBufferWithAllocator:t->al];
    t->used = [NSMutableArray array];
#endif
    return t;
}
// Make res (a texture, buffer or heap) resident until the command buffer completes; a view or a texture over a buffer by what it is made from, a heap's resource by its heap
static inline void t4_use(T4 *t, id res) {
    if (!res) return;
#if T4_NVN
    once_use(t->o, res);
#else
    @autoreleasepool {
        id r = res;
        if ([r conformsToProtocol:@protocol(MTLTexture)]) { id<MTLTexture> x = r; while (x.parentTexture) x = x.parentTexture; r = x.buffer ? (id)x.buffer : (id)x; }
        id<MTLHeap> heap = [r conformsToProtocol:@protocol(MTLResource)] ? ((id<MTLResource>)r).heap : nil;
        if (heap) r = heap;
        if (!r || [t->used containsObject:r]) return;
        [t->used addObject:r];
        os_unfair_lock_lock(&g_t4_lk);
        if (![g_t4_rc countForObject:r]) [g_t4_res addAllocation:r];
        [g_t4_rc addObject:r];
        os_unfair_lock_unlock(&g_t4_lk);
    }
#endif
}
// A compute encoder, for dispatches and for the copies a blit encoder made (copyFromTexture, copyFromBuffer, fillBuffer, generateMipmapsForTexture...)
static inline id<MTL4ComputeCommandEncoder> t4_compute(T4 *t) {
#if T4_NVN
    return once_copy(t->o);
#else
    id<MTL4ComputeCommandEncoder> e = [t->cb computeCommandEncoder];
    if (!e) T4_DIE("no Metal 4 compute encoder");
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:t4_vis()];
    return e;
#endif
}
static inline id<MTL4ComputeCommandEncoder> t4_copy(T4 *t) { return t4_compute(t); }
// A render encoder for the pass a classic descriptor describes (its attachments made resident)
static inline id<MTL4RenderCommandEncoder> t4_pass(T4 *t, MTLRenderPassDescriptor *rp) {
    MTL4RenderPassDescriptor *d = [MTL4RenderPassDescriptor new];
    for (NSUInteger i = 0; i < 8; i++) if (rp.colorAttachments[i].texture) { d.colorAttachments[i] = rp.colorAttachments[i]; t4_use(t, rp.colorAttachments[i].texture); t4_use(t, rp.colorAttachments[i].resolveTexture); }
    if (rp.depthAttachment.texture) { d.depthAttachment = rp.depthAttachment; t4_use(t, rp.depthAttachment.texture); t4_use(t, rp.depthAttachment.resolveTexture); }
    if (rp.stencilAttachment.texture) { d.stencilAttachment = rp.stencilAttachment; t4_use(t, rp.stencilAttachment.texture); t4_use(t, rp.stencilAttachment.resolveTexture); }
    d.renderTargetArrayLength = rp.renderTargetArrayLength; d.renderTargetWidth = rp.renderTargetWidth; d.renderTargetHeight = rp.renderTargetHeight;
    d.defaultRasterSampleCount = rp.defaultRasterSampleCount;
    d.tileWidth = rp.tileWidth; d.tileHeight = rp.tileHeight; d.threadgroupMemoryLength = rp.threadgroupMemoryLength; d.imageblockSampleLength = rp.imageblockSampleLength;
    if (rp.visibilityResultBuffer) { d.visibilityResultBuffer = rp.visibilityResultBuffer; t4_use(t, rp.visibilityResultBuffer); }
#if T4_NVN
    id<MTL4CommandBuffer> cb = t->o->cb;
#else
    id<MTL4CommandBuffer> cb = t->cb;
#endif
    id<MTL4RenderCommandEncoder> e = [cb renderCommandEncoderWithDescriptor:d];
    if (!e) T4_DIE("no Metal 4 render encoder");
    [e barrierAfterQueueStages:MTLStageAll beforeStages:MTLStageAll visibilityOptions:t4_vis()];
    return e;
}
// Between two dispatches or copies of one compute encoder where the second reads what the first wrote
static inline void t4_barrier(id<MTL4ComputeCommandEncoder> e) {
    [e barrierAfterEncoderStages:MTLStageDispatch | MTLStageBlit beforeEncoderStages:MTLStageDispatch | MTLStageBlit visibilityOptions:t4_vis()];
}
static inline void t4_end(T4 *t, id e) {
#if T4_NVN
    once_end(t->o, e);
#else
    (void)t;
    [(id<MTL4CommandEncoder>)e barrierAfterStages:MTLStageAll beforeQueueStages:MTLStageAll visibilityOptions:t4_vis()];
    [e endEncoding];
#endif
}
static inline id<MTL4ArgumentTable> t4_table(T4 *t, id e, int stage) {
    if (stage < 0 || stage >= T4_NSTAGE) T4_DIE("argument table stage %d", stage);
    if (!t->tab[stage]) {
        MTL4ArgumentTableDescriptor *d = [MTL4ArgumentTableDescriptor new];
        d.maxBufferBindCount = T4_BUFS; d.maxTextureBindCount = T4_TEXS; d.maxSamplerStateBindCount = T4_SAMPS; d.initializeBindings = YES;
        NSError *err = nil; if (!(t->tab[stage] = [t4_dev() newArgumentTableWithDescriptor:d error:&err])) T4_DIE("no argument table: %s", err.localizedDescription.UTF8String);
    }
    // Bound again with every binding: an encoder takes a snapshot of the table at each draw or dispatch, and a table belongs to every encoder of this command buffer
    if (stage == T4_CS) [(id<MTL4ComputeCommandEncoder>)e setArgumentTable:t->tab[stage]];
    else {
        static const MTLRenderStages st[T4_NSTAGE] = {0, MTLRenderStageVertex, MTLRenderStageFragment, MTLRenderStageObject, MTLRenderStageMesh};
        [(id<MTL4RenderCommandEncoder>)e setArgumentTable:t->tab[stage] atStages:st[stage]];
    }
    return t->tab[stage];
}
// setBuffer / setVertexBuffer / setFragmentBuffer (b may be nil: address 0)
static inline void t4_buf(T4 *t, id e, int stage, id<MTLBuffer> b, NSUInteger off, NSUInteger i) {
    t4_use(t, b);
    [t4_table(t, e, stage) setAddress:b ? b.gpuAddress + off : 0 atIndex:i];
}
// setTexture / setVertexTexture / setFragmentTexture
static inline void t4_tex(T4 *t, id e, int stage, id<MTLTexture> x, NSUInteger i) {
    t4_use(t, x);
    [t4_table(t, e, stage) setTexture:x ? x.gpuResourceID : (MTLResourceID){0} atIndex:i];
}
// setSamplerState / setFragmentSamplerState (made with supportArgumentBuffers)
static inline void t4_samp(T4 *t, id e, int stage, id<MTLSamplerState> s, NSUInteger i) {
    [t4_table(t, e, stage) setSamplerState:s ? s.gpuResourceID : (MTLResourceID){0} atIndex:i];
}
// setBytes / setVertexBytes / setFragmentBytes: a copy in the command buffer's scratch buffer
static inline void t4_bytes(T4 *t, id e, int stage, const void *p, size_t n, NSUInteger i) {
    NSUInteger at = (t->scratch_at + 255) & ~(NSUInteger)255;
    id<MTLBuffer> b = t->scratch.lastObject;
    if (!b || at + n > b.length) {
        b = [t4_dev() newBufferWithLength:n > T4_SCRATCH ? n : T4_SCRATCH options:MTLResourceStorageModeShared];
        if (!b) T4_DIE("no scratch buffer");
        if (!t->scratch) t->scratch = [NSMutableArray array];
        [t->scratch addObject:b]; at = 0;
    }
    memcpy((uint8_t *)b.contents + at, p, n); t->scratch_at = at + n;
    t4_buf(t, e, stage, b, at, i);
}
#if !T4_NVN
static inline void t4_release(T4 *t) {   // the command buffer completed: what t4_use made resident leaves the residency set (unless another one still uses it), its allocator is kept
    os_unfair_lock_lock(&g_t4_lk);
    int gone = 0;
    for (id r in t->used) { [g_t4_rc removeObject:r]; if (![g_t4_rc countForObject:r]) { [g_t4_res removeAllocation:r]; gone = 1; } }
    if (gone) [g_t4_res commit];
    [t->used removeAllObjects];
    if (g_t4_nal < T4_KEEP && t->al) g_t4_al[g_t4_nal++] = t->al;
    t->al = nil;
    os_unfair_lock_unlock(&g_t4_lk);
}
#endif
// addCompletedHandler + commit: done (may be nil) runs once the GPU is done, on another thread, ok 0 on a GPU error
static inline void t4_commit(T4 *t, void (^done)(int ok)) {
#if T4_NVN
    NvOnce *o = t->o; t->o = nil;
    NSArray *keep = @[t];   // the argument tables and scratch buffers, until the GPU is done with them
    once_commit(o, ^(int ok) { (void)keep; if (done) done(ok); });
#else
    [t->cb endCommandBuffer];
    MTL4CommitOptions *opt = [MTL4CommitOptions new];
    [opt addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
        if (f.error) fprintf(stderr, "[t_mtl4] command buffer error: %s\n", f.error.description.UTF8String);
        t4_release(t);
        if (done) done(!f.error);
    }];
    os_unfair_lock_lock(&g_t4_lk); [g_t4_res commit]; os_unfair_lock_unlock(&g_t4_lk);
    id<MTL4CommandBuffer> cbs[] = {t->cb};
    [g_t4_q commit:cbs count:1 options:opt];
#endif
}
// commit + waitUntilCompleted: MTLCommandBufferStatusCompleted, or MTLCommandBufferStatusError on a GPU error (also kept in t->status)
static inline long t4_wait(T4 *t) {
#if T4_NVN
    int ok = once_wait(t->o); t->o = nil;
#else
    dispatch_semaphore_t sem = dispatch_semaphore_create(0); __block int ok = 0;
    t4_commit(t, ^(int k) { ok = k; dispatch_semaphore_signal(sem); });
    dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
#endif
    return t->status = ok ? MTLCommandBufferStatusCompleted : MTLCommandBufferStatusError;
}
// Everything committed to the fixture's queue so far has completed (an empty command buffer behind it)
static inline void t4_drain(void) {
    T4 *t = t4_begin(); t4_end(t, t4_compute(t)); t4_wait(t);
}
