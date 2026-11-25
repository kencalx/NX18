// Metal 4 pipelines (pso_build): one base per pipeline with its colour state unspecialized, made into pipelines by specialization, kept in the pipeline archive.
// Checks: pipelines that differ only in colour state share one base; a specialized pipeline draws the same pixels as one built whole; a flushed archive
// file serves the base again without compiling; a flush of bases without a vertex layout is a p<seq> file, where a base with a layout is not looked up; a function with no
// Metal 4 descriptor gets no pipeline (there is no MTLDevice path); pso_key_norm drops what no pipeline depends on; compaction merges the files the prewarm took bases from into one per full period despite a
// mid-prewarm timer flush, removing them only after its last period, counting them for the prepare line, and a compaction that did not finish is not tried again on the same system build; a timer flush waits for any prewarm, so a cold start writes a file per full period; depth-only draws write depth; concurrent colour variants compile
// one base; archive flushes preserve unrelated compiler state; a function with function constants is specialized by its pipeline's descriptor, not through its library
// (fn_spec asks the library for no specialization); the descriptor for a specialization is the caller's whether the driver returns it retained or autoreleased; a compute pipeline is captured into a plain file and taken from it later, one without a Metal 4 descriptor never looked up; a native mesh pipeline is captured into a p file and taken from it later, with or without a task shader or a pixel shader, captured again by a compaction, and one without a Metal 4 descriptor refused; a capture that fails builds the pipeline all the same and hands a full period over, or stops capturing after a failure in a period that captured nothing; run files are compacted by size tier from the pipeline count in their names (a tier of more than PSO_ARCH_COMPACT files and every smaller one, never a full period's, old and malformed names as the largest tier, the same across fresh processes), and a compute or task / mesh pipeline in a file left out is not captured again. A compaction's recapture whose vertex function other captures hold (fn_claim) waits for them in a prewarm task and is captured; elsewhere it keeps the old file's base after its limit, built again by no compiler, and the compaction keeps the old files and says why
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <dispatch/dispatch.h>
// Keep the host's cache observations/deletions in a directory owned by this test.
// Metal itself still uses its real compiler cache; only this translation unit's
// confstr calls see the fixture parent, including when testing the former cleanup.
static char archive_cache_root[] = "/tmp/t_pso_archive_cache.XXXXXX";
static size_t archive_confstr(int name, char *buffer, size_t length) {
    if (name != _CS_DARWIN_USER_CACHE_DIR) return confstr(name, buffer, length);
    size_t size = strlen(archive_cache_root) + 1;
    if (length && buffer) { size_t n = size < length ? size : length; memcpy(buffer, archive_cache_root, n); buffer[n - 1] = 0; }
    return size;
}
#define confstr archive_confstr
static void archive_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block);   // --active-flush drives the archive's timer itself
#define dispatch_after archive_dispatch_after
#include "../nvn/nvn_mtl.m"
#undef dispatch_after
#include "t_mtl4.h"
static void archive_cache_cleanup(void) {
    [NSFileManager.defaultManager removeItemAtPath:@(archive_cache_root) error:nil];
}
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
static CAMetalLayer *test_layer;   // --active-flush: a window (mtl_has_window), with no present made through it
void *front_metal_layer(void) { return (__bridge void *)test_layer; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
void hlecount_flush(void) {} void dm_rec_finish(void) {} void dm_cheats_exit(void) {} void dm_audio_suspend(int on) { (void)on; }   // what the graceful exit (hle_lifecycle.c) calls besides graphics
void save_sync_soon(const char *why) { (void)why; } int save_sync_flush(int timeout_ms) { (void)timeout_ms; return 1; }   // and the cloud save's send (save_sync.c): sync off
static int checks, failed;
// The next program of a test hand-over (--exec-seed): it starts only after the archive's write, so the folder holds the file; it says so in exec.txt (the test reads it)
static void exec_then(void *dir) {
    int files = 0; for (NSString *f in [NSFileManager.defaultManager contentsOfDirectoryAtPath:@((const char *)dir) error:nil]) files += [f hasSuffix:@".mtl4a"];
    [[NSString stringWithFormat:@"%d\n", files] writeToFile:[@((const char *)dir) stringByAppendingPathComponent:@"exec.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}
#define EXPECT(name, want, got) do { uint64_t w = (want), g = (got); checks++; if (w != g) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w, (unsigned long long)g); failed++; } } while (0)
// The archive's timer (arch_note_new) on its queue, run by the test (--active-flush) instead of 10 s later; every other dispatch_after as before
static int test_archive_timer;
static dispatch_block_t test_timer_block;
static void archive_dispatch_after(dispatch_time_t when, dispatch_queue_t queue, dispatch_block_t block) {
    if (test_archive_timer && queue == g_arch_q) { EXPECT("at most one archive timer queued", 1, test_timer_block == nil); test_timer_block = block; }
    else dispatch_after(when, queue, block);
}
static void fire_archive_timer(void) {
    dispatch_sync(g_arch_q, ^{ dispatch_block_t tick = test_timer_block; EXPECT("archive timer armed", 1, tick != nil); test_timer_block = nil; if (tick) tick(); });
}

static id<MTLLibrary> g_lib, g_lib2, g_lib3;   // g_lib2: the same source again, for functions with no Metal 4 descriptor (a library hands out one function object per name);
                                              // g_lib3: once more, through the fixture's compiler, for whole reference pipelines (t4_rps)
static NSArray<NSString *> *archive_files(NSString *dir) {   // the archive's files, without their indexes (<file>.keys)
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.mtl4a'"]];
}
// The compaction's state as a start has it before its prewarm (compact_note, compact_step): no notes, no pass, nothing captured; a step scheduled before does nothing
static void compact_reset(void) {
    atomic_fetch_add(&g_cpass_gen, 1);
    os_unfair_lock_lock(&g_cnote_lock); g_cnotes = nil; g_cnote_keys = nil; g_cnote_next = 0; os_unfair_lock_unlock(&g_cnote_lock);
    g_cpass = 0; g_cpass_held = 0; g_cpass_subs = 0; g_cpass_holds = 0; g_cpass_files = 0; g_cpass_cap_ns = 0; g_cpass_held_ns = 0; g_cpass_hold_test = -1;
    g_cpass_start_ms = COMPACT_START_MS; g_cpass_batch = COMPACT_BATCH; g_cpass_rest_ms = COMPACT_REST_MS; g_cpass_hold_ms = COMPACT_HOLD_MS;
    g_compacted = 0; g_compact_bases = 0; g_compact_ns = 0; g_compact_bad = 0; g_compact_busy = 0; g_compact_closed = 0; g_compact_periods = 0; g_compact_once = 0;
}
static void compact_step_now(void) { dispatch_sync(compact_q(), ^{ @autoreleasepool { compact_step(); } }); }   // one step of the pass, here and now
// The pass as the game runs it after the prewarm (compact_schedule), with no wait before it or rest between its batches, the first frame presented: returns once it closed
// (or stopped) and every period it handed over is written, and the old files are gone when it finished
static void compact_pass_run(void) {
    uint64_t pn = g_present_n; g_present_n = 1; g_cpass_start_ms = 0; g_cpass_rest_ms = 0; g_cpass_hold_ms = 5; g_cpass_hold_test = 0;   // not the Mac's heat or Low Power Mode
    compact_schedule();
    for (int i = 0; i < 120000 && (atomic_load(&g_cpass) == 1 || atomic_load(&g_cpass) == 2); i++) usleep(1000);
    g_present_n = pn;
    arch_flush_wait(); dispatch_sync(g_arch_q, ^{});
}
static id<MTLFunction> test_fn(id<MTLLibrary> lib, NSString *name, int registered) {
    id<MTLFunction> f = [lib newFunctionWithName:name];
    MTLFunctionConstantValues *cv = f.functionConstantsDictionary.count ? [MTLFunctionConstantValues new] : nil;
    if (cv) f = [lib newFunctionWithName:name constantValues:cv error:nil];
    return registered ? fn4_note(f, lib, name, cv) : f;
}
// Counts the library specializations asked of it (newFunctionWithName:constantValues:, which compiles through the MTLDevice): fn_spec asks for none
@interface SpecCountLibrary : NSObject {
@public id<MTLLibrary> library; _Atomic int calls;
}
@end
@implementation SpecCountLibrary
- (id)forwardingTargetForSelector:(SEL)selector { return library; }
- (id<MTLFunction>)newFunctionWithName:(NSString *)entry constantValues:(MTLFunctionConstantValues *)values error:(NSError **)error {
    atomic_fetch_add(&calls, 1);
    return [library newFunctionWithName:entry constantValues:values error:error];
}
@end
static void functions_unspecialized(id<MTLLibrary> library) {
    SpecCountLibrary *count = [SpecCountLibrary new]; count->library = library;
    id<MTLLibrary> lib = (id<MTLLibrary>)count;
    MTLFunctionConstantValues *set = [MTLFunctionConstantValues new]; BOOL on = YES; [set setConstantValue:&on type:MTLDataTypeBool atIndex:0];
    id<MTLFunction> a = fn_spec(lib, @"cvs", [MTLFunctionConstantValues new], NULL), b = fn_spec(lib, @"cfs", set, NULL), c = fn_spec(lib, @"cfs", set, NULL);
    EXPECT("functions: each made", 1, a && b && c);
    EXPECT("functions: none specialized through the library", 0, count->calls);
    EXPECT("functions: a set of constants of its own is its own object and note", 1, b != c && fn4_of(b) && fn4_of(c) && fn4_of(b) != fn4_of(c));
    EXPECT("functions: its note specializes it", 1, [fn4_of(b) isKindOfClass:MTL4SpecializedFunctionDescriptor.class] && [((MTL4SpecializedFunctionDescriptor *)fn4_of(b)).constantValues isEqual:set]);
}
// fail 2: the compiler service died (err_compiler_died's text); any other: an ordinary compile error
static NSError *compile_error(int kind) {
    return kind == 2 ? [NSError errorWithDomain:@"AGXMetalG14G" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Compilation failed due to an interrupted connection: XPC_ERROR_CONNECTION_INTERRUPTED."}]
                     : [NSError errorWithDomain:@"test" code:1 userInfo:nil];
}
// Hold the first base build while other callers request colour variants and an unrelated base.
@interface ArchiveGateCompiler : NSObject {
@public id<MTL4Compiler> compiler; dispatch_semaphore_t entered, release; _Atomic int calls, lookup_calls; int fail;
}
@end
@implementation ArchiveGateCompiler
- (id)forwardingTargetForSelector:(SEL)selector { return compiler; }
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4RenderPipelineDescriptor *)d compilerTaskOptions:(MTL4CompilerTaskOptions *)opts error:(NSError **)error {
    if (opts.lookupArchives.count) atomic_fetch_add(&lookup_calls, 1);
    int call = atomic_fetch_add(&calls, 1);
    if (!call) { dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER); }
    if (fail) { if (error) *error = compile_error(fail); return nil; }
    return [compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:opts error:error];
}
@end
// Counts the compute pipeline lookups in an archive file
@interface LookupCountArchive : NSObject { @public id<MTL4Archive> archive; _Atomic int lookups; } @end
@implementation LookupCountArchive
- (id)forwardingTargetForSelector:(SEL)selector { return archive; }
- (id<MTLComputePipelineState>)newComputePipelineStateWithDescriptor:(MTL4ComputePipelineDescriptor *)d error:(NSError **)error {
    atomic_fetch_add(&lookups, 1); return [archive newComputePipelineStateWithDescriptor:d error:error];
}
@end
// Runs kernel k of compute_pipelines over 64 threads: 1 when every o[i] is i * 3 + 1
static int run_kernel(id<MTLComputePipelineState> ps) {
    if (!ps) return 0;
    id<MTLBuffer> b = [g_dev newBufferWithLength:64 * 4 options:MTLResourceStorageModeShared]; memset(b.contents, 0, 64 * 4);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> ce = t4_compute(cb);
    [ce setComputePipelineState:t4_keep(cb, ps)]; t4_buf(cb, ce, T4_CS, b, 0, 0); [ce dispatchThreads:MTLSizeMake(64, 1, 1) threadsPerThreadgroup:MTLSizeMake(32, 1, 1)]; t4_end(cb, ce);
    if (t4_wait(cb) != MTLCommandBufferStatusCompleted) return 0;
    const uint32_t *o = b.contents; for (uint32_t i = 0; i < 64; i++) if (o[i] != i * 3 + 1) return 0;
    return 1;
}
// Compute pipelines (cps_new) beside the bases: one the bundle does not hold is built through the Metal 4 compiler and compiled into the flush period in the background, written to a
// plain file (never a p<seq> one), and a later start takes it from that file without building it; compaction captures it again; a function without a Metal 4 descriptor
// gets no pipeline, is not captured and never looked up
static void compute_pipelines(void) {
    char kdir[] = "/tmp/t_pso_compute.XXXXXX"; if (!mkdtemp(kdir)) abort();
    NSString *saved = g_arch_dir; g_arch_dir = @(kdir); g_arch4 = @[]; g_arch4p = @[]; NSError *err = nil;
    arch_flush_wait();   // from an empty period
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void k(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i * 3 + 1; }\n";
    id<MTLLibrary> kl = [g_dev newLibraryWithSource:src options:nil error:&err], ul = [g_dev newLibraryWithSource:[src stringByAppendingString:@"// unregistered\n"] options:nil error:&err];
    id<MTLFunction> kf = fn4_note([kl newFunctionWithName:@"k"], kl, @"k", nil), uf = [ul newFunctionWithName:@"k"];
    uint64_t built = g_cps_built, run = g_cps_run, arch = g_cps_arch; int pending = g_arch_new;
    id<MTLComputePipelineState> kp = cps_new(kf, &err);
    EXPECT("compute: a pipeline", 1, kp != nil);
    EXPECT("compute: built", built + 1, g_cps_built);
    dispatch_sync(arch_harvest_q(), ^{});   // its capture, in the background
    EXPECT("compute: captured for the archive", pending + 1, g_arch_new);
    EXPECT("compute: its dispatch writes", 1, run_kernel(kp));
    arch_flush_wait();
    NSArray<NSString *> *names = archive_files(@(kdir));
    EXPECT("compute: one file written", 1, names.count);
    EXPECT("compute: a plain file, not a p file", 1, names.count == 1 && ![names[0] hasPrefix:@"p"]);
    EXPECT("compute: nothing left to write", 0, g_arch_new);
    LookupCountArchive *la = [LookupCountArchive new];
    NSString *path = names.count ? [@(kdir) stringByAppendingPathComponent:names[0]] : nil;
    if (!path) abort();
    la->archive = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:path] error:&err];
    g_arch4 = @[(id<MTL4Archive>)la];   // as a new start with that file
    built = g_cps_built; pending = g_arch_new;
    id<MTLComputePipelineState> kp2 = cps_new(kf, &err);
    EXPECT("compute again: from this device's archive", run + 1, g_cps_run);
    EXPECT("compute again: not built", built, g_cps_built);
    EXPECT("compute again: not from a bundle", arch, g_cps_arch);
    EXPECT("compute again: nothing captured", pending, g_arch_new);
    EXPECT("compute again: its dispatch writes", 1, run_kernel(kp2));
    // compaction during the prewarm: noted and captured nothing; captured again from its function after the first frame (compact_step), for the file that replaces the old ones
    compact_reset(); g_compact_enabled = 1; atomic_store(&g_warm_running, 1);
    EXPECT("compute, compaction: a pipeline", 1, cps_new(kf, &err) != nil);
    EXPECT("compute, compaction: from the archive", run + 2, g_cps_run);
    dispatch_sync(arch_harvest_q(), ^{});
    EXPECT("compute, compaction: noted", 1, g_compact_bases);
    EXPECT("compute, compaction: nothing captured in the prewarm", 1, !g_compacted && g_arch_new == pending);
    g_compact_state = calloc(g_arch4.count + 1, 1);   // a pick that leaves the file it is in: not noted
    g_cnotes = nil; g_cnote_keys = nil; g_compact_bases = 0;
    EXPECT("compute, compaction of other files: a pipeline", 1, cps_new(kf, &err) != nil);
    EXPECT("compute, compaction of other files: not noted", 0, g_compact_bases);
    free(g_compact_state); g_compact_state = NULL;
    EXPECT("compute, compaction: noted again", 1, cps_new(kf, &err) != nil && g_compact_bases == 1);
    atomic_store(&g_warm_running, 0);
    compact_pass_run();
    EXPECT("compute, compaction: captured again after the first frame", 1, g_compacted);
    EXPECT("compute, compaction: closed", 1, g_cpass == 3 && g_compact_closed && !g_compact_bad);
    compact_reset(); g_compact_enabled = 0;
    arch_flush_wait();
    // no Metal 4 descriptor: no pipeline (every function a pipeline is built from is noted), no lookup, nothing captured
    int looked = la->lookups; built = g_cps_built; pending = g_arch_new;
    id<MTLComputePipelineState> up = cps_new(uf, &err);
    EXPECT("compute without a descriptor: no pipeline", 1, up == nil);
    EXPECT("compute without a descriptor: never looked up", looked, la->lookups);
    EXPECT("compute without a descriptor: not built", built, g_cps_built);
    dispatch_sync(arch_harvest_q(), ^{});
    EXPECT("compute without a descriptor: not captured", pending, g_arch_new);
    [NSFileManager.defaultManager removeItemAtPath:@(kdir) error:nil]; g_arch_dir = saved; g_arch4 = @[];
}
// Draws mesh pipeline ps (one triangle over the target) into a 4x4 RGBA8 target cleared to red: 1 when the centre pixel is the fragment's colour, or red with no fragment
static int mesh_draw_ok(id<MTLRenderPipelineState> ps, int fragment) {
    if (!ps) return 0;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = t; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1); rp.colorAttachments[0].storeAction = MTLStoreActionStore;
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> en = t4_pass(cb, rp);
    MTLSize one = MTLSizeMake(1, 1, 1);
    [en setRenderPipelineState:t4_keep(cb, ps)]; [en drawMeshThreadgroups:one threadsPerObjectThreadgroup:one threadsPerMeshThreadgroup:one]; t4_end(cb, en);
    if (t4_wait(cb) != MTLCommandBufferStatusCompleted) return 0;
    uint8_t px[4]; [t getBytes:px bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
    return fragment ? px[0] == 0 && px[1] == 255 && px[2] == 0 && px[3] == 255 : px[0] == 255 && px[1] == 0 && px[2] == 0 && px[3] == 255;
}
// Native mesh pipelines (mtk_build) beside the bases: one built through the Metal 4 compiler is compiled into the flush period in the background, written to a p file (no vertex layout), and a later start takes it from
// that file without compiling, with or without a task shader; a compacting prewarm captures one taken from a plain file again; a depth-only one (no pixel shader) takes the noted
// empty fragment and goes the same way; one whose function has no Metal 4 descriptor gets no pipeline and is not captured
static void mesh_pipelines(void) {
    char mdir[] = "/tmp/t_pso_mesh.XXXXXX"; if (!mkdtemp(mdir)) abort();
    NSString *saved = g_arch_dir; g_arch_dir = @(mdir); g_arch4 = @[]; g_arch4p = @[]; NSError *err = nil;
    arch_flush_wait();   // from an empty period
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct MV { float4 p [[position]]; };\nusing Tri = mesh<MV, void, 3, 1, topology::triangle>;\n"
        "struct PL { uint n; }; struct BL { uint first; };\n"
        "[[object]] void os(object_data PL &pl [[payload]], mesh_grid_properties g) { pl.n = 1; g.set_threadgroups_per_grid(uint3(1, 1, 1)); }\n"
        // a mesh shader with no task has an object function of its own that launches its blocks (dmsh_meshstage.py main0_o)
        "[[object]] void ob(object_data BL &b [[payload]], mesh_grid_properties g) { b.first = 0; g.set_threadgroups_per_grid(uint3(1, 1, 1)); }\n"
        "[[mesh]] void ms(Tri out, const object_data BL &b [[payload]]) { out.set_primitive_count(1 + b.first); out.set_vertex(0, MV{float4(-1, -1, 0.5, 1)}); out.set_vertex(1, MV{float4(3, -1, 0.5, 1)}); out.set_vertex(2, MV{float4(-1, 3, 0.5, 1)});\n"
        "  out.set_index(0, 0); out.set_index(1, 1); out.set_index(2, 2); }\n"
        "[[mesh]] void mt(Tri out, const object_data PL &pl [[payload]]) { out.set_primitive_count(pl.n); out.set_vertex(0, MV{float4(-1, -1, 0.5, 1)}); out.set_vertex(1, MV{float4(3, -1, 0.5, 1)}); out.set_vertex(2, MV{float4(-1, 3, 0.5, 1)});\n"
        "  out.set_index(0, 0); out.set_index(1, 1); out.set_index(2, 2); }\n"
        "fragment float4 mf() { return float4(0, 1, 0, 1); }\n";
    id<MTLLibrary> ml = lib_tag([g_dev newLibraryWithSource:src options:nil error:&err], @"test/mesh"), ul = [g_dev newLibraryWithSource:[src stringByAppendingString:@"// unregistered\n"] options:nil error:&err];
    EXPECT("mesh: fixture library", 1, ml != nil && ul != nil);
    if (!ml || !ul) { g_arch_dir = saved; return; }
    NvShader *ms = [NvShader new], *mt = [NvShader new], *os = [NvShader new], *fs = [NvShader new], *um = [NvShader new];
    ms->fn = test_fn(ml, @"ms", 1); ms->stage = 4; ms->mesh_kind = 2; ms->mesh_threads = 1; ms->mesh_notask = 1; ms->mesh_obj = test_fn(ml, @"ob", 1); strlcpy(ms->key, "mesh", sizeof ms->key);
    mt->fn = test_fn(ml, @"mt", 1); mt->stage = 4; mt->mesh_kind = 2; mt->mesh_threads = 1; strlcpy(mt->key, "mesh-task", sizeof mt->key);
    os->fn = test_fn(ml, @"os", 1); os->stage = 3; os->mesh_kind = 1; os->mesh_threads = 1; os->mesh_payload = 4; strlcpy(os->key, "task", sizeof os->key);
    fs->fn = test_fn(ml, @"mf", 1); fs->stage = 1; strlcpy(fs->key, "pixel", sizeof fs->key);
    um->fn = test_fn(ul, @"ms", 0); um->stage = 4; um->mesh_kind = 2; um->mesh_threads = 1; um->mesh_notask = 1; um->mesh_obj = test_fn(ul, @"ob", 0); strlcpy(um->key, "mesh-u", sizeof um->key);
    pso_key k; memset(&k, 0, sizeof k); k.cfmt[0] = MTLPixelFormatRGBA8Unorm; k.chmask = 0xf; k.samples = 1;
    pso_key kz; memset(&kz, 0, sizeof kz); kz.cfmt[0] = MTLPixelFormatRGBA8Unorm; kz.samples = 1;   // depth only: no pixel shader, no colour written
    uint64_t built = g_mtk_built, arch = g_mtk_arch; int pending = g_arch_new, got = 0;
    id<MTLRenderPipelineState> p1 = mtk_build(&k, nil, ms, fs, &err, &got), p2 = mtk_build(&k, os, mt, fs, &err, NULL), p3 = mtk_build(&kz, nil, ms, nil, &err, NULL);
    EXPECT("mesh: pipelines", 1, p1 && p2 && p3);
    EXPECT("mesh: built", built + 3, g_mtk_built);
    EXPECT("mesh: not from the archive", 0, got);
    dispatch_sync(arch_harvest_q(), ^{});   // their captures, in the background
    EXPECT("mesh: captured for the archive", pending + 3, g_arch_new);
    EXPECT("mesh: its draw writes", 1, mesh_draw_ok(p1, 1));
    EXPECT("mesh with a task shader: its draw writes", 1, mesh_draw_ok(p2, 1));
    EXPECT("mesh, depth only: draws nothing into colour", 1, mesh_draw_ok(p3, 0));
    arch_flush_wait();
    NSArray<NSString *> *names = archive_files(@(mdir));
    EXPECT("mesh: one file written", 1, names.count);
    EXPECT("mesh: a p file (no vertex layout)", 1, names.count == 1 && [names[0] hasPrefix:@"p"]);
    NSString *first = names.firstObject;
    {   // its index names all three, the depth-only one too: the empty fragment's library is named (mtk_nop_fragment), so the file is looked up through the index alone
        int mcomplete = -1; NSData *mkeys = first ? arch_keys_read(arch_keys_path([NSString stringWithFormat:@"%s/%@", mdir, first]), &mcomplete) : nil;
        EXPECT("mesh: its index names the three pipelines", 3, mkeys.length / sizeof(uint64_t));
        EXPECT("mesh: its index is complete", 1, mcomplete);
    }
    id<MTL4Archive> file = first ? [g_dev newArchiveWithURL:[NSURL fileURLWithPath:[NSString stringWithFormat:@"%s/%@", mdir, first]] error:&err] : nil;
    g_arch4p = file ? @[file] : @[];   // as a new start with that file
    built = g_mtk_built; pending = g_arch_new;
    id<MTLRenderPipelineState> q1 = mtk_build(&k, nil, ms, fs, &err, &got), q2 = mtk_build(&k, os, mt, fs, &err, NULL), q3 = mtk_build(&kz, nil, ms, nil, &err, NULL);
    EXPECT("mesh again: from the archive", arch + 3, g_mtk_arch);
    EXPECT("mesh again: reported as archived", 1, got);
    EXPECT("mesh again: not built", built, g_mtk_built);
    dispatch_sync(arch_harvest_q(), ^{});
    EXPECT("mesh again: nothing captured", pending, g_arch_new);
    EXPECT("mesh again: its draw writes", 1, mesh_draw_ok(q1, 1));
    EXPECT("mesh again with a task shader: its draw writes", 1, mesh_draw_ok(q2, 1));
    EXPECT("mesh again, depth only: draws nothing into colour", 1, mesh_draw_ok(q3, 0));
    pso_key kb = k; kb.cfmt[0] = MTLPixelFormatBGRA8Unorm;   // other colour state: another pipeline, not in the file
    EXPECT("mesh, other colour format: built", 1, mtk_build(&kb, nil, ms, fs, &err, NULL) != nil && g_mtk_built == built + 1);
    dispatch_sync(arch_harvest_q(), ^{});
    arch_flush_wait();
    // the same file as a plain one during a compacting prewarm: captured again from its functions, for the file that replaces the old ones
    g_arch4p = @[]; g_arch4 = file ? @[file] : @[];
    compact_reset(); g_compact_enabled = 1; atomic_store(&g_warm_running, 1); pending = g_arch_new;
    EXPECT("mesh, compaction: a pipeline", 1, mtk_build(&k, nil, ms, fs, &err, NULL) != nil);
    EXPECT("mesh, compaction: from the archive", arch + 4, g_mtk_arch);
    dispatch_sync(arch_harvest_q(), ^{});
    EXPECT("mesh, compaction: noted", 1, g_compact_bases);
    EXPECT("mesh, compaction: nothing captured in the prewarm", 1, !g_compacted && g_arch_new == pending);
    g_compact_state = calloc(g_arch4.count + 1, 1);   // a pick that leaves the file it is in: not noted
    g_cnotes = nil; g_cnote_keys = nil; g_compact_bases = 0;
    EXPECT("mesh, compaction of other files: a pipeline", 1, mtk_build(&k, nil, ms, fs, &err, NULL) != nil);
    EXPECT("mesh, compaction of other files: not noted", 0, g_compact_bases);
    free(g_compact_state); g_compact_state = NULL;
    EXPECT("mesh, compaction: noted again", 1, mtk_build(&k, nil, ms, fs, &err, NULL) != nil && g_compact_bases == 1);
    atomic_store(&g_warm_running, 0);
    compact_pass_run();
    EXPECT("mesh, compaction: captured again after the first frame", 1, g_compacted);
    EXPECT("mesh, compaction: closed", 1, g_cpass == 3 && g_compact_closed && !g_compact_bad);
    compact_reset(); g_compact_enabled = 0;
    arch_flush_wait();
    // no Metal 4 descriptor: no pipeline (every function a pipeline is built from is noted), nothing captured
    pending = g_arch_new; built = g_mtk_built;
    id<MTLRenderPipelineState> up = mtk_build(&k, nil, um, fs, &err, NULL);
    EXPECT("mesh without a descriptor: no pipeline", 1, up == nil);
    EXPECT("mesh without a descriptor: not built", built, g_mtk_built);
    dispatch_sync(arch_harvest_q(), ^{});
    EXPECT("mesh without a descriptor: not captured", pending, g_arch_new);
    [NSFileManager.defaultManager removeItemAtPath:@(mdir) error:nil]; g_arch_dir = saved; g_arch4 = @[]; g_arch4p = @[];
}
// Notes whether the compaction marker exists while the serializer writes (issue #342: a flush that does not return leaves it)
@interface MarkerSerializer : NSObject { @public id<MTL4PipelineDataSetSerializer> ser; int calls, marked; } @end
@implementation MarkerSerializer
- (id)forwardingTargetForSelector:(SEL)selector { return ser; }
- (BOOL)serializeAsArchiveAndFlushToURL:(NSURL *)url error:(NSError **)error {
    calls++; marked += [[NSString stringWithContentsOfFile:arch_compact_marker() encoding:NSUTF8StringEncoding error:nil] isEqualToString:arch_compact_stamp()];
    return [ser serializeAsArchiveAndFlushToURL:url error:error];
}
@end
// Model another compiler creating state before the real compiler call returns.
// The UUID fixture belongs exclusively to this test; no discovered folder is removed.
@interface ArchiveForeignCompiler : NSObject {
@public id<MTL4Compiler> compiler; NSString *fixture; NSError *fixture_error;
    unsigned calls; BOOL created, marker_created;
}
@end
@implementation ArchiveForeignCompiler
- (id)forwardingTargetForSelector:(SEL)selector { return compiler; }
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4RenderPipelineDescriptor *)d compilerTaskOptions:(MTL4CompilerTaskOptions *)opts error:(NSError **)error {
    calls++;
    id<MTLRenderPipelineState> ps = [compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:opts error:error];
    if (ps && !created) {
        if (mkdir(fixture.fileSystemRepresentation, 0700)) fixture_error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        else {
            created = YES;
            NSString *marker = [fixture stringByAppendingPathComponent:@"PersistentState"];
            int fd = open(marker.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL, 0600);
            if (fd < 0) fixture_error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
            else { close(fd); marker_created = YES; }
        }
    }
    return ps;
}
@end
// a full-screen triangle; colour 0 = (0.5, 0.25, 1, 0.5), colour 1 = (0.2, 0.4, 0.6, 0.8); attribute 0 (a float4) scales nothing, so a vertex descriptor is part of the pipeline
static MTLRenderPipelineDescriptor *desc(MTLPixelFormat f0, int blend, MTLPixelFormat f1, MTLColorWriteMask m1, int registered) {
    MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
    id<MTLFunction> v = test_fn(g_lib2, @"vs", 0), f = test_fn(g_lib2, @"fs", 0);
    static id<MTLFunction> rv, rf;   // the registered ones are made once, as shader_load makes a shader's functions once
    if (registered) { if (!rv) { rv = test_fn(g_lib, @"vs", 1); rf = test_fn(g_lib, @"fs", 1); } v = rv; f = rf; }
    d.vertexFunction = v; d.fragmentFunction = f;
    MTLVertexDescriptor *vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format = MTLVertexFormatFloat4; vd.attributes[0].bufferIndex = 16; vd.layouts[16].stride = 16; vd.layouts[16].stepFunction = MTLVertexStepFunctionConstant; vd.layouts[16].stepRate = 0;
    d.vertexDescriptor = vd;
    d.colorAttachments[0].pixelFormat = f0;
    if (blend) { d.colorAttachments[0].blendingEnabled = YES; d.colorAttachments[0].sourceRGBBlendFactor = d.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorSourceAlpha;
                 d.colorAttachments[0].destinationRGBBlendFactor = d.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorOneMinusSourceAlpha; }
    d.colorAttachments[1].pixelFormat = f1; d.colorAttachments[1].writeMask = m1;
    d.depthAttachmentPixelFormat = MTLPixelFormatDepth32Float;   // a Metal 4 pipeline names no depth format; drawn into a pass with this depth attachment
    return d;
}
// draws with ps into fresh targets cleared to (1, 0, 0, 1) and returns texel (1, 1) of both as floats
static void draw_with(id<MTLRenderPipelineState> ps, MTLPixelFormat f0, MTLPixelFormat f1, float out[2][4]) {
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; id<MTLTexture> t[2];
    MTLPixelFormat fm[2] = { f0, f1 };
    for (int i = 0; i < 2; i++) {
        MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:fm[i] width:4 height:4 mipmapped:NO]; td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
        t[i] = [g_dev newTextureWithDescriptor:td];
        rp.colorAttachments[i].texture = t[i]; rp.colorAttachments[i].loadAction = MTLLoadActionClear; rp.colorAttachments[i].clearColor = MTLClearColorMake(1, 0, 0, 1); rp.colorAttachments[i].storeAction = MTLStoreActionStore;
    }
    MTLTextureDescriptor *dd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO]; dd.usage = MTLTextureUsageRenderTarget; dd.storageMode = MTLStorageModePrivate;
    rp.depthAttachment.texture = [g_dev newTextureWithDescriptor:dd]; rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.storeAction = MTLStoreActionDontCare;
    static id<MTLBuffer> one; if (!one) { float v[4] = { 1, 1, 1, 1 }; one = [g_dev newBufferWithBytes:v length:16 options:MTLResourceStorageModeShared]; }
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> e = t4_pass(cb, rp);
    [e setRenderPipelineState:t4_keep(cb, ps)]; t4_buf(cb, e, T4_VS, one, 0, 16); [e drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; t4_end(cb, e);
    EXPECT("draw: command completed", MTLCommandBufferStatusCompleted, t4_wait(cb));
    for (int i = 0; i < 2; i++) {
        if (fm[i] == MTLPixelFormatRGBA8Unorm) { uint8_t p[4]; [t[i] getBytes:p bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0]; for (int c = 0; c < 4; c++) out[i][c] = p[c] / 255.0f; }
        else { __fp16 p[4]; [t[i] getBytes:p bytesPerRow:32 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0]; for (int c = 0; c < 4; c++) out[i][c] = p[c]; }
    }
}
static void same_pixels(const char *name, MTLPixelFormat f0, int blend, MTLPixelFormat f1, MTLColorWriteMask m1) {
    NSError *e = nil;
    MTLRenderPipelineDescriptor *whole = desc(f0, blend, f1, m1, 0); whole.vertexFunction = t4_fn(g_lib3, @"vs"); whole.fragmentFunction = t4_fn(g_lib3, @"fs");
    id<MTLRenderPipelineState> a = pso_build(desc(f0, blend, f1, m1, 1), 0, &e), b = t4_rps(whole, &e);
    checks++; if (!a || !b) { fprintf(stderr, "%s: no pipeline (%s)\n", name, e.localizedDescription.UTF8String); failed++; return; }
    float pa[2][4], pb[2][4]; draw_with(a, f0, f1, pa); draw_with(b, f0, f1, pb);
    checks++; if (memcmp(pa, pb, sizeof pa)) { fprintf(stderr, "%s: the specialized pipeline drew (%g %g %g %g | %g %g %g %g), the whole one (%g %g %g %g | %g %g %g %g)\n", name,
        pa[0][0], pa[0][1], pa[0][2], pa[0][3], pa[1][0], pa[1][1], pa[1][2], pa[1][3], pb[0][0], pb[0][1], pb[0][2], pb[0][3], pb[1][0], pb[1][1], pb[1][2], pb[1][3]); failed++; }
}
static void depth_only(void) {
    MTLRenderPipelineDescriptor *d = desc(MTLPixelFormatInvalid, 0, MTLPixelFormatInvalid, MTLColorWriteMaskNone, 1);
    d.fragmentFunction = nil; NSError *err = nil;
    id<MTLRenderPipelineState> ps = pso_build(d, 0, &err);
    EXPECT("depth only: pipeline (through the Metal 4 compiler, with the empty fragment)", 1, ps != nil);
    if (!ps) return;
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModePrivate;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:td];
    if (!t) abort();
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor new]; rp.depthAttachment.texture = t;
    rp.depthAttachment.loadAction = MTLLoadActionClear; rp.depthAttachment.clearDepth = 1; rp.depthAttachment.storeAction = MTLStoreActionStore;
    MTLDepthStencilDescriptor *ds = [MTLDepthStencilDescriptor new]; ds.depthWriteEnabled = YES; ds.depthCompareFunction = MTLCompareFunctionAlways;
    float v[4] = {1, 1, 1, 1}; id<MTLBuffer> vb = [g_dev newBufferWithBytes:v length:sizeof v options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [g_dev newBufferWithLength:1024 options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4RenderCommandEncoder> enc = t4_pass(cb, rp);
    [enc setRenderPipelineState:t4_keep(cb, ps)]; [enc setDepthStencilState:t4_keep(cb, [g_dev newDepthStencilStateWithDescriptor:ds])];
    t4_buf(cb, enc, T4_VS, vb, 0, 16); [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; t4_end(cb, enc);
    id<MTL4ComputeCommandEncoder> blit = t4_copy(cb); t4_use(cb, t); t4_use(cb, out);
    [blit copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(4, 4, 1)
                toBuffer:out destinationOffset:0 destinationBytesPerRow:256 destinationBytesPerImage:1024]; t4_end(cb, blit);
    EXPECT("depth only: command completed", MTLCommandBufferStatusCompleted, t4_wait(cb));
    EXPECT("depth only: rasterization wrote zero depth", 1, ((float *)out.contents)[65] == 0.0f);
}
// A capture the compiler service died under (arch_capture_try, err_compiler_died; upstream NXNative 9bd8bb386): its period is handed over and not written, the counts of
// unwritten pipelines drop by what it held, and the run goes on capturing into a new period that is written. A written crashed period made Ocarina of Time's every later start
// abort in Metal's archive lookup. Then the service dying under a compile that is not a capture (arch_died through compile_done): the current period is not written either
static void crashed_period(void) {
    char cdir[] = "/tmp/t_pso_crashed.XXXXXX"; if (!mkdtemp(cdir)) abort();
    arch_flush_wait(); NSString *saved = g_arch_dir; g_arch_dir = @(cdir); nvn_hm_clear(&g_pbase, hm_rel);
    NSError *err = nil;
    MTLRenderPipelineDescriptor *a = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1); a.vertexDescriptor.layouts[16].stride = 4096;
    EXPECT("crashed: a capture before", 1, pso_build(a, 0, &err) != nil && atomic_load(&g_ep->n) == 1);
    ArchEpoch *ep = g_ep; ArchiveGateCompiler *gate = [ArchiveGateCompiler new]; gate->compiler = ep->comp; gate->fail = 2; gate->calls = 1; ep->comp = (id<MTL4Compiler>)gate;
    MTLRenderPipelineDescriptor *b = desc(MTLPixelFormatRGBA8Unorm, 1, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1); b.vertexDescriptor.layouts[16].stride = 3072;
    err = nil; EXPECT("crashed: the pipeline built by the plain compiler", 1, pso_build(b, 0, &err) != nil && !err);
    EXPECT("crashed: the period marked", 1, atomic_load(&ep->crashed));
    EXPECT("crashed: handed over", 1, g_ep != ep);
    EXPECT("crashed: still capturing", 1, arch_capturing());
    ep->comp = gate->compiler;
    arch_flush_wait();
    EXPECT("crashed: the period not written", 0, (int)archive_files(@(cdir)).count);
    EXPECT("crashed: nothing left counted as unwritten", 0, atomic_load(&g_arch_new));
    MTLRenderPipelineDescriptor *c = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1); c.vertexDescriptor.layouts[16].stride = 2560;
    EXPECT("crashed: the next period captures", 1, pso_build(c, 0, &err) != nil && atomic_load(&g_ep->n) == 1);
    arch_flush(); arch_flush_wait();
    EXPECT("crashed: the next period written", 1, (int)archive_files(@(cdir)).count);
    MTLRenderPipelineDescriptor *d = desc(MTLPixelFormatRGBA8Unorm, 1, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1); d.vertexDescriptor.layouts[16].stride = 2048;
    EXPECT("died elsewhere: a capture before", 1, pso_build(d, 0, &err) != nil && atomic_load(&g_ep->n) == 1);
    ArchEpoch *ep2 = g_ep;
    NSError *out = nil;
    EXPECT("died elsewhere: compile_done hands the error on", 1, compile_done(nil, compile_error(2), &out) == nil && out != nil);
    arch_died(compile_error(1));   // any other error: nothing
    EXPECT("died elsewhere: the period marked", 1, atomic_load(&ep2->crashed));
    EXPECT("died elsewhere: handed over", 1, g_ep != ep2);
    arch_flush_wait();
    EXPECT("died elsewhere: the period not written", 1, (int)archive_files(@(cdir)).count);
    EXPECT("died elsewhere: nothing left counted as unwritten", 0, atomic_load(&g_arch_new));
    nvn_hm_clear(&g_pbase, hm_rel);
    [NSFileManager.defaultManager removeItemAtPath:@(cdir) error:nil]; g_arch_dir = saved;
}
static void concurrent_bases(int fail) {
    nvn_hm_clear(&g_pbase, hm_rel);
    if (fail) {   // the period has captured a pipeline: a capture that fails then means its store is full
        MTLRenderPipelineDescriptor *pd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1); pd.vertexDescriptor.layouts[16].stride = 2048;
        NSError *err = nil; EXPECT("failed capture: a capture before", 1, pso_build(pd, 0, &err) != nil && atomic_load(&g_ep->n) > 0);
    }
    ArchEpoch *ep = g_ep; ArchiveGateCompiler *gate = [ArchiveGateCompiler new]; gate->compiler = ep->comp; gate->fail = fail;
    gate->entered = dispatch_semaphore_create(0); gate->release = dispatch_semaphore_create(0); ep->comp = (id<MTL4Compiler>)gate;
    NSMutableArray<MTLRenderPipelineDescriptor *> *ds = [NSMutableArray array];
    for (int i = 0; i < 8; i++) {
        MTLRenderPipelineDescriptor *d = desc(MTLPixelFormatRGBA8Unorm, i & 1, MTLPixelFormatRGBA8Unorm, i, 1);
        d.vertexDescriptor.layouts[16].stride = 512; [ds addObject:d];
    }
    dispatch_group_t group = dispatch_group_create(); __block int good = 0; NSObject *lock = [NSObject new];
    for (MTLRenderPipelineDescriptor *d in ds) dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        @autoreleasepool { NSError *err = nil; id ps = pso_build(d, 0, &err);
            @synchronized(lock) { good += ps != nil && !err; }   // a capture that fails builds the pipeline by the plain compiler all the same
        }
    });
    EXPECT("concurrent: first compiler entered", 0, dispatch_semaphore_wait(gate->entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    // An unrelated key must complete while the first remains blocked. It has the held compile's stage functions, so it is not captured beside it (fn_claim, Metal crashes on
    // that): after the wait the plain compiler builds it
    int plain0 = g_fn_plain; g_fn_wait_ms = 200;
    MTLRenderPipelineDescriptor *other = [ds[0] copy]; other.vertexDescriptor = [other.vertexDescriptor copy]; other.vertexDescriptor.layouts[16].stride = 1024;
    dispatch_group_t separate = dispatch_group_create();
    dispatch_group_async(separate, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool { pso_build(other, 0, NULL); } });
    EXPECT("concurrent: unrelated base progresses", 0, dispatch_group_wait(separate, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    EXPECT("concurrent: the unrelated base built without the archive", 1, g_fn_plain - plain0); g_fn_wait_ms = FN_WAIT_MS;
    dispatch_semaphore_signal(gate->release);
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER); dispatch_group_wait(separate, DISPATCH_TIME_FOREVER);
    EXPECT("concurrent: all callers receive result", 8, good);
    if (!fail) EXPECT("concurrent: one compile per base, the unrelated one by the plain compiler", 1, gate->calls);
    EXPECT("concurrent: no unfinished builds", 0, g_pbase_pending.n);
    ep->comp = gate->compiler;
    if (!fail) return;
    // the full period was handed over once, and the run still captures, into a fresh period
    EXPECT("failed capture: a new period", 1, g_ep != ep);
    EXPECT("failed capture: handed over once", 1, ep->failed);
    EXPECT("failed capture: still capturing", 1, arch_capturing());
    NSError *err = nil; int n0 = atomic_load(&g_ep->n); nvn_hm_clear(&g_pbase, hm_rel);
    EXPECT("failed capture: the base captured in the new period", 1, pso_build(ds[0], 0, &err) != nil && atomic_load(&g_ep->n) == n0 + 1);
    // a capture that fails in a period that has captured nothing: not the store's size, so the run captures no more, and builds the pipeline all the same
    arch_flush_wait();
    ArchEpoch *fresh = g_ep; ArchiveGateCompiler *fg = [ArchiveGateCompiler new]; fg->compiler = fresh->comp; fg->fail = 1; fg->calls = 1; fresh->comp = (id<MTL4Compiler>)fg;
    nvn_hm_clear(&g_pbase, hm_rel); err = nil;
    EXPECT("failed capture in a new period: built", 1, pso_build(ds[1], 0, &err) != nil && !err);
    EXPECT("failed capture in a new period: no more captures", 0, arch_capturing());
    int calls = fg->calls; nvn_hm_clear(&g_pbase, hm_rel);
    EXPECT("no more captures: built by the plain compiler", 1, pso_build(ds[2], 0, &err) != nil && fg->calls == calls && g_ep == fresh);
    // a pipeline both compilers refuse fails, with the plain compiler's error
    atomic_store(&g_arch_cap_off, 0); id<MTL4Compiler> plain = g_comp4;
    ArchiveGateCompiler *pg = [ArchiveGateCompiler new]; pg->compiler = plain; pg->fail = 1; pg->calls = 1; g_comp4 = (id<MTL4Compiler>)pg;
    atomic_store(&fresh->n, 1);   // as a period that holds a capture, so the failure is not taken for a broken capture
    nvn_hm_clear(&g_pbase, hm_rel); err = nil;
    EXPECT("both refuse: no pipeline, the error", 1, pso_build(ds[3], 0, &err) == nil && [err.domain isEqualToString:@"test"]);
    EXPECT("both refuse: not a failed capture", 0, fresh->failed);
    atomic_store(&fresh->n, 0); g_comp4 = plain; fresh->comp = fg->compiler;
    nvn_hm_clear(&g_pbase, hm_rel); err = nil;
    EXPECT("concurrent: failed base can retry", 1, pso_build(ds[0], 0, &err) != nil);
}
static void fn_hand_over(const uint64_t *k, int n) {   // the capture holding k's functions returns and another of them takes them at once, before any waiter can
    pthread_mutex_lock(&g_fn_mu); uint64_t ser = ++g_fn_ser;
    for (int j = 0; j < g_fn_nbusy; j++) if (fn_mine(k, n, j)) g_fn_busy[j].ser = ser;
    pthread_cond_broadcast(&g_fn_cv); pthread_mutex_unlock(&g_fn_mu);
}
// A compaction's recapture whose vertex function other captures hold (fn_claim). The pass after the first frame (compact_one) waits as long as they keep returning and is
// captured: when the prewarm's pair tasks recaptured, those that shared a vertex shader took turns, and the fourth gave up after 2 s and failed the whole compaction. One whose
// function stays held past g_fn_patient_ms keeps the base from the old file, built again by no compiler; the old files then stay, and the red line says why. A draw of the prewarm
// takes the old file's base and only notes it: it waits for no capture
static void compaction_claim(void) {
    char cdir[] = "/tmp/t_pso_compact_claim.XXXXXX"; if (!mkdtemp(cdir)) abort();
    NSString *saved = g_arch_dir; NSArray<id<MTL4Archive>> *saved4 = g_arch4, *saved4p = g_arch4p;
    g_arch_dir = @(cdir); nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = @[]; g_arch4p = @[];
    NSError *err = nil; NSMutableArray<MTLRenderPipelineDescriptor *> *descs = [NSMutableArray array];
    for (int i = 0; i < 2; i++) {   // two bases of one vertex function in an old file: the strides of their layouts tell them apart
        MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
        cd.vertexDescriptor.layouts[16].stride = 16 * (i + 40); [descs addObject:cd];
        EXPECT("compaction claim: a base", 1, pso_build(cd, 0, &err) != nil);
    }
    arch_flush_wait();
    NSArray<NSString *> *names = archive_files(@(cdir)); NSMutableArray<NSString *> *paths = [NSMutableArray array]; NSMutableArray<id<MTL4Archive>> *open = [NSMutableArray array];
    for (NSString *n in names) { NSString *f = [@(cdir) stringByAppendingPathComponent:n]; [paths addObject:f]; [open addObject:[g_dev newArchiveWithURL:[NSURL fileURLWithPath:f] error:&err]]; }
    EXPECT("compaction claim: the old file", 1, names.count);
    nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = open;   // as a start that compacts it
    compact_reset(); g_compact_enabled = 1; g_compact_files = paths;
    uint64_t k[3]; int n = fn_ids(pso_desc4(descs[0], 1, 0), k), *np = &n; uint64_t *kp = k;   // the bases' vertex function (kp, np: a block cannot take the array)
    EXPECT("compaction claim: one function, under way in another capture", 1, n == 1 && fn_claim(k, n, 0));
    g_fn_wait_ms = 200; g_fn_patient_ms = 200;
    // the prewarm (a draw of it alike): the old file's bases at once, though another capture holds their function; noted, none captured
    atomic_store(&g_warm_running, 1);
    uint64_t arch0 = g_pb_archived, t0 = bp_now();
    for (MTLRenderPipelineDescriptor *cd in descs) EXPECT("compaction claim, prewarm: a pipeline", 1, pso_build(cd, 0, &err) != nil);
    EXPECT("compaction claim, prewarm: no wait for the capture under way", 1, bp_now() - t0 < 150 * NSEC_PER_MSEC);
    EXPECT("compaction claim, prewarm: both from the old file", arch0 + 2, g_pb_archived);
    EXPECT("compaction claim, prewarm: both noted, none captured", 1, g_compact_bases == 2 && !g_compacted);
    atomic_store(&g_warm_running, 0);
    ArchiveGateCompiler *plain = [ArchiveGateCompiler new]; plain->compiler = g_comp4; plain->calls = 1; g_comp4 = (id<MTL4Compiler>)plain;   // counts what the plain compiler builds
    atomic_store(&g_cpass, 2);   // the pass captures (its periods may hold its bases)
    // the pass: three captures of the function return one after another, each within the limit, then the last one
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ for (int i = 0; i < 3; i++) { usleep(150000); fn_hand_over(kp, *np); } usleep(150000); fn_release(kp, *np); });
    t0 = bp_now();
    dispatch_sync(compact_q(), ^{ @autoreleasepool { compact_one(g_cnotes[0]); } });
    uint64_t waited = bp_now() - t0;
    EXPECT("compaction claim, pass: waited for every capture ahead, past the limit", 1, waited >= 550 * NSEC_PER_MSEC);
    EXPECT("compaction claim, pass: captured again", 1, g_compacted);
    EXPECT("compaction claim, pass: the compaction goes on", 0, g_compact_bad);
    // a capture under way that does not return within g_fn_patient_ms
    EXPECT("compaction claim, held: under way again", 1, fn_claim(k, n, 0));
    t0 = bp_now();
    dispatch_sync(compact_q(), ^{ @autoreleasepool { compact_one(g_cnotes[1]); } });
    waited = bp_now() - t0;
    EXPECT("compaction claim, held: after its limit", 1, waited >= 150 * NSEC_PER_MSEC && waited < 1500 * NSEC_PER_MSEC);
    EXPECT("compaction claim, held: the plain compiler built nothing", 1, plain->calls);
    EXPECT("compaction claim, held: not captured again", 1, g_compacted);
    EXPECT("compaction claim, held: the compaction fails", 1, g_compact_bad);
    EXPECT("compaction claim, held: for fn_claim", 1, g_compact_busy);
    fn_release(k, n); g_comp4 = plain->compiler; g_fn_wait_ms = FN_WAIT_MS; g_fn_patient_ms = FN_PATIENT_MS;
    // every note taken: the pass closes, its period is written, and the compaction ends with the old file kept and the note that holds it back
    g_cnote_next = 2; dispatch_sync(compact_q(), ^{ compact_close(); });
    arch_flush_wait(); dispatch_sync(g_arch_q, ^{});
    EXPECT("compaction claim: the period written", 1, g_compact_closed && !g_compact_periods);
    EXPECT("compaction claim: the old file stays", 1, [NSFileManager.defaultManager fileExistsAtPath:paths[0]]);
    EXPECT("compaction claim: compact_failed.tsv names it", 1, [[NSString stringWithContentsOfFile:arch_compact_fail_path() encoding:NSUTF8StringEncoding error:nil] containsString:names[0]]);
    compact_reset(); g_compact_enabled = 0; g_compact_files = nil;
    nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = saved4; g_arch4p = saved4p; g_arch_dir = saved;
    [NSFileManager.defaultManager removeItemAtPath:@(cdir) error:nil];
}
static void capture_preserves_foreign_folder(void) {
    arch_flush_wait();   // Finish earlier captures: the captures below go into a new flush period
    NSError *error = nil;
    MTLRenderPipelineDescriptor *prime = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
    prime.vertexDescriptor.layouts[16].stride = 1536;
    // Establish the period's working folder with a capture of its own compiler
    EXPECT("foreign capture: prime real compiler", 1,
           [g_ep->comp newRenderPipelineStateWithDescriptor:pso_desc4(prime, 1, 0) compilerTaskOptions:nil error:&error] != nil);
    char root[PATH_MAX];
    if (!confstr(_CS_DARWIN_USER_CACHE_DIR, root, sizeof root)) { EXPECT("foreign capture: cache path available", 1, 0); return; }
    ArchEpoch *ep = g_ep; ArchiveForeignCompiler *proxy = [ArchiveForeignCompiler new]; proxy->compiler = ep->comp;
    NSString *cache = [@(root) stringByAppendingPathComponent:@"com.apple.gpuarchiver"];
    proxy->fixture = [cache stringByAppendingPathComponent:[@"gpuarchiver-" stringByAppendingString:NSUUID.UUID.UUIDString]];
    MTLRenderPipelineDescriptor *fresh = [prime copy]; fresh.vertexDescriptor = [prime.vertexDescriptor copy];
    fresh.vertexDescriptor.layouts[16].stride = 2048;
    ep->comp = (id<MTL4Compiler>)proxy;   // the current flush period's compiler, which the captures go through
    EXPECT("foreign capture: real pipeline", 1, pso_build(fresh, 0, &error) != nil);
    ep->comp = proxy->compiler;
    EXPECT("foreign capture: one real compiler call", 1, proxy->calls);
    EXPECT("foreign capture: fixture created", 1, proxy->marker_created);
    if (proxy->fixture_error) fprintf(stderr, "foreign capture: fixture creation failed: %s\n", proxy->fixture_error.localizedDescription.UTF8String);
    arch_flush_wait();
    EXPECT("foreign capture: PersistentState survives flush", 1,
           [NSFileManager.defaultManager fileExistsAtPath:[proxy->fixture stringByAppendingPathComponent:@"PersistentState"]]);
    if (proxy->created && [NSFileManager.defaultManager fileExistsAtPath:proxy->fixture])
        EXPECT("foreign capture: test-owned fixture removed", 1, [NSFileManager.defaultManager removeItemAtPath:proxy->fixture error:nil]);
}
// Stand-ins for a base pipeline's newRenderPipelineDescriptorForSpecialization: one returns the descriptor retained, as its name promises (macOS 27.0), the other autoreleased,
// as iOS 26.0's driver does. Plain functions, so ARC's naming convention does not decide what they return
static __weak MTL4RenderPipelineDescriptor *g_spec_made;
static void *spec_retained(id self, SEL cmd) { (void)self; (void)cmd; MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new]; g_spec_made = d; return (void *)CFBridgingRetain(d); }
static void *spec_autoreleased(id self, SEL cmd) { (void)self; (void)cmd; MTL4RenderPipelineDescriptor *d = [MTL4RenderPipelineDescriptor new]; g_spec_made = d; return (void *)CFAutorelease(CFBridgingRetain(d)); }
// spec_desc owns the descriptor either way: it outlives every pool once returned (no over-release; the warm task's pool crashed on iOS 26.0) and goes away once dropped (no leak),
// on the first call, which finds out how the driver returns it, and on later ones
static void spec_desc_ownership(void) {
    SEL sel = @selector(newRenderPipelineDescriptorForSpecialization);
    const char *names[2] = {"retained", "autoreleased"}; IMP imps[2] = {(IMP)spec_retained, (IMP)spec_autoreleased};
    for (int k = 0; k < 2; k++) {
        Class c = objc_allocateClassPair(NSObject.class, k ? "TSpecBaseAutoreleased" : "TSpecBaseRetained", 0);
        if (!c) { fprintf(stderr, "spec descriptor %s: no stand-in class\n", names[k]); failed++; continue; }
        class_addMethod(c, sel, imps[k], "@@:"); objc_registerClassPair(c);
        id base = [c new]; _Atomic int own = 0;
        for (int call = 0; call < 2; call++) {
            char name[96];
            __weak MTL4RenderPipelineDescriptor *kept;   // not w: EXPECT declares its own
            @autoreleasepool {
                MTL4RenderPipelineDescriptor *s;
                @autoreleasepool { s = spec_desc(base, &own); }
                kept = s;
                snprintf(name, sizeof name, "spec descriptor %s, call %d: the caller's after its pools", names[k], call + 1);
                EXPECT(name, 1, s != nil && s == g_spec_made);
            }
            snprintf(name, sizeof name, "spec descriptor %s, call %d: freed once dropped", names[k], call + 1);
            EXPECT(name, 1, kept == nil);
            snprintf(name, sizeof name, "spec descriptor %s, call %d: ownership found", names[k], call + 1);
            EXPECT(name, k + 1, atomic_load(&own));
        }
    }
}
static long compacting_n(void) { long n = 0; for (NSUInteger i = 0; g_compact_state && i < g_compact_files.count; i++) n += g_compact_state[i] == 1; return n; }   // files compaction replaces
// How many run files a start with these would compact (0: no compaction): groups of {count, pipelines in each} (0: named before the count was, -1: a count that does not parse)
static long pick_n(NSArray<NSArray<NSNumber *> *> *groups) {
    NSMutableArray<NSString *> *names = [NSMutableArray array]; int seq = 0;
    for (NSArray<NSNumber *> *g in groups) for (int i = 0; i < g[0].intValue; i++, seq++)
        [names addObject:g[1].intValue > 0 ? [NSString stringWithFormat:@"/x/%05d-%d.mtl4a", seq, g[1].intValue] : g[1].intValue ? [NSString stringWithFormat:@"/x/%05d-x.mtl4a", seq]
                                            : [NSString stringWithFormat:@"/x/%05d.mtl4a", seq]];
    arch_flush_wait(); dispatch_sync(g_arch_q, ^{});   // an earlier test's queued write or finish must not land between the pick and the count
    g_compacted = 0; g_compact_enabled = 0; g_compact_files = nil; g_compact_state = NULL; arch_compact_pick(names);
    long n = g_compact_enabled ? compacting_n() : 0;
    g_compact_enabled = 0; g_compact_files = nil; g_compact_state = NULL;
    return n;
}
// g_pbase_miss: an archive that never has the base, with the real compiler. A miss is searched for once, for its own base only; it keeps neither the compile nor the base
// it builds from a draw, and the compile skips the search
@interface MissingBaseArchive : NSObject { @public unsigned calls; } @end
@implementation MissingBaseArchive
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4RenderPipelineDescriptor *)d error:(NSError **)e {
    (void)d; (void)e; calls++; return nil;
}
@end
static void repeated_archive_miss(void) {
    NSArray *saved = g_arch4, *savedp = g_arch4p;
    MissingBaseArchive *archive = [MissingBaseArchive new];
    g_arch4 = @[(id<MTL4Archive>)archive]; g_arch4p = @[];
    MTLRenderPipelineDescriptor *d = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
    d.vertexDescriptor.layouts[16].stride = 1536;
    NSError *e = nil;
    for (int i = 0; i < 100; i++) EXPECT("negative probe: no archived pipeline", 1, pso_build_ex(d, 0, &e, 0) == nil);
    EXPECT("negative probe: one lookup for 100 misses", 1, archive->calls);
    EXPECT("negative probe: no unfinished owner", 0, g_pbase_pending.n);
    d.vertexDescriptor.layouts[16].stride = 1552;
    EXPECT("negative probe: another layout is independent", 1, pso_build_ex(d, 0, &e, 0) == nil);
    EXPECT("negative probe: another key looked up", 2, archive->calls);
    d.vertexDescriptor.layouts[16].stride = 1536;
    EXPECT("negative probe: demand can still compile", 1, pso_build_ex(d, 0, &e, 1) != nil);
    EXPECT("negative probe: the compile does not search again", 2, archive->calls);
    unsigned after = archive->calls;
    EXPECT("negative probe: compiled base overrides miss", 1, pso_build_ex(d, 0, &e, 0) != nil);
    EXPECT("negative probe: completed base needs no archive scan", after, archive->calls);
    g_arch4 = saved; g_arch4p = savedp;
    nvn_hm_clear(&g_pbase_miss, hm_rel);
}

// An app's folder of Metal's build folders (ga_claim / ga_remove): a start with no other copy running snapshots only earlier runs' directories with their (dev, ino)
// identity; a copy started beside it lists none; once the first exits, a third start still lists none while the second runs; and background removal preserves files,
// symlinks, unrelated directories, post-snapshot directories, and any entry replaced by a new directory, file, or symlink with the same name.
static NSSet<NSString *> *ga_names(NSArray<GaDir *> *dirs) {
    NSMutableSet<NSString *> *s = [NSMutableSet setWithCapacity:dirs.count];
    for (GaDir *g in dirs) [s addObject:g->name];
    return s;
}
static void app_folder_claim(void) {
    EXPECT("app folder: a host without a bundle shares Metal's folder", 0, ga_own());
    EXPECT("app folder: Metal's folder", 1, [ga_dir() hasSuffix:@"/com.apple.gpuarchiver"]);
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *app_dir = [@(archive_cache_root) stringByAppendingPathComponent:@"org.nxnative.test"];
    NSString *dir = [app_dir stringByAppendingPathComponent:@"com.apple.gpuarchiver"];
    NSString *d_a = [dir stringByAppendingPathComponent:@"gpuarchiver-aaaaaa"];
    NSString *d_a_nested = [d_a stringByAppendingPathComponent:@"nested"];
    NSString *d_b = [dir stringByAppendingPathComponent:@"gpuarchiver-bbbbbb"];
    NSString *d_rep = [dir stringByAppendingPathComponent:@"gpuarchiver-replaced"];
    NSString *d_sfile = [dir stringByAppendingPathComponent:@"gpuarchiver-swapfile"];
    NSString *d_slink = [dir stringByAppendingPathComponent:@"gpuarchiver-swaplink"];
    for (NSString *p in @[d_a_nested, d_b, d_rep, d_sfile, d_slink])
        [fm createDirectoryAtPath:p withIntermediateDirectories:YES attributes:nil error:nil];
    [@"old" writeToFile:[d_a_nested stringByAppendingPathComponent:@"state"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [@"old" writeToFile:[d_b stringByAppendingPathComponent:@"state"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [@"old" writeToFile:[d_rep stringByAppendingPathComponent:@"old"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [@"old" writeToFile:[d_sfile stringByAppendingPathComponent:@"old"] atomically:NO encoding:NSUTF8StringEncoding error:nil];
    [@"old" writeToFile:[d_slink stringByAppendingPathComponent:@"old"] atomically:NO encoding:NSUTF8StringEncoding error:nil];

    NSString *other = [dir stringByAppendingPathComponent:@"unrelated"];
    NSString *other_file = [other stringByAppendingPathComponent:@"state"];
    [fm createDirectoryAtPath:other withIntermediateDirectories:NO attributes:nil error:nil];
    [@"keep" writeToFile:other_file atomically:NO encoding:NSUTF8StringEncoding error:nil];
    EXPECT("app folder: nested symlink fixture created", 0, symlink(other.fileSystemRepresentation, [d_a_nested stringByAppendingPathComponent:@"out"].fileSystemRepresentation));

    NSString *file = [dir stringByAppendingPathComponent:@"gpuarchiver-file"];
    [@"keep" writeToFile:file atomically:NO encoding:NSUTF8StringEncoding error:nil];
    NSString *link = [dir stringByAppendingPathComponent:@"gpuarchiver-link"];
    EXPECT("app folder: matching symlink fixture created", 0, symlink(other.fileSystemRepresentation, link.fileSystemRepresentation));

    int a, b, c, d;
    NSArray<GaDir *> *got = ga_claim(dir, &a);
    NSSet<NSString *> *want = [NSSet setWithObjects:@"gpuarchiver-aaaaaa", @"gpuarchiver-bbbbbb", @"gpuarchiver-replaced", @"gpuarchiver-swapfile", @"gpuarchiver-swaplink", nil];
    EXPECT("app folder: the first copy lists only earlier run directories", 1, a >= 0 && [ga_names(got) isEqualToSet:want]);
    NSString *late = [dir stringByAppendingPathComponent:@"gpuarchiver-late"], *late_file = [late stringByAppendingPathComponent:@"live"];
    EXPECT("app folder: post-snapshot directory created", 1, [fm createDirectoryAtPath:late withIntermediateDirectories:NO attributes:nil error:nil]);
    EXPECT("app folder: post-snapshot file written", 1, [@"live" writeToFile:late_file atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    EXPECT("app folder: a second copy lists none", 1, ga_claim(dir, &b) == nil && b >= 0);
    close(a);   // the first copy quits
    EXPECT("app folder: a third copy lists none while the second runs", 1, ga_claim(dir, &c) == nil && c >= 0);
    close(b); close(c);
    NSArray<GaDir *> *again = ga_claim(dir, &d);
    EXPECT("app folder: with no copy running, a start lists old and late directories", 6, again.count);
    close(d);

    // Concurrent-writer mutations after snapshot: keep the old directory's inode allocated across replacement creation so the new directory gets a distinct st_ino.
    NSString *moved_rep = [app_dir stringByAppendingPathComponent:@"moved-replaced"];
    NSString *rep_live = [d_rep stringByAppendingPathComponent:@"live"];
    EXPECT("app folder: move replaced fixture aside", 1, [fm moveItemAtPath:d_rep toPath:moved_rep error:nil]);
    EXPECT("app folder: create replacement directory", 1, [fm createDirectoryAtPath:d_rep withIntermediateDirectories:NO attributes:nil error:nil]);
    EXPECT("app folder: write file in replacement directory", 1, [@"live" writeToFile:rep_live atomically:NO encoding:NSUTF8StringEncoding error:nil]);
    EXPECT("app folder: remove moved old fixture", 1, [fm removeItemAtPath:moved_rep error:nil]);

    EXPECT("app folder: remove swapfile fixture dir", 1, [fm removeItemAtPath:d_sfile error:nil]);
    EXPECT("app folder: replace with regular file", 1, [@"file" writeToFile:d_sfile atomically:NO encoding:NSUTF8StringEncoding error:nil]);

    EXPECT("app folder: remove swaplink fixture dir", 1, [fm removeItemAtPath:d_slink error:nil]);
    EXPECT("app folder: replace with symlink", 0, symlink(other.fileSystemRepresentation, d_slink.fileSystemRepresentation));

    EXPECT("app folder: removes only unchanged snapshotted directories", 2, ga_remove(dir, got));
    struct stat st;
    EXPECT("app folder: old matching directory a gone", 0, lstat(d_a.fileSystemRepresentation, &st) == 0);
    EXPECT("app folder: old matching directory b gone", 0, lstat(d_b.fileSystemRepresentation, &st) == 0);
    EXPECT("app folder: unrelated directory retained", 1, [fm fileExistsAtPath:other_file]);
    EXPECT("app folder: matching regular file retained", 1, lstat(file.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode));
    EXPECT("app folder: matching symlink retained without following it", 1, lstat(link.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode));
    EXPECT("app folder: directory created after snapshot retained", 1, [fm fileExistsAtPath:late_file]);
    EXPECT("app folder: replacement directory with same name retained", 1, [fm fileExistsAtPath:rep_live]);
    EXPECT("app folder: directory swapped for regular file retained", 1, lstat(d_sfile.fileSystemRepresentation, &st) == 0 && S_ISREG(st.st_mode));
    EXPECT("app folder: directory swapped for symlink retained", 1, lstat(d_slink.fileSystemRepresentation, &st) == 0 && S_ISLNK(st.st_mode));
    EXPECT("app folder: no folder, no lock", 1, ga_claim(nil, &d) == nil && d < 0);
    EXPECT("app folder: no folder, nothing removed", 0, ga_remove(nil, got));
}

int main(int argc, char **argv) { @autoreleasepool {
    if (!mkdtemp(archive_cache_root)) abort();
    atexit(archive_cache_cleanup);
    NSString *cache_path = [@(archive_cache_root) stringByAppendingPathComponent:@"com.apple.gpuarchiver"];
    if (!cache_path) abort();
    if (![NSFileManager.defaultManager createDirectoryAtPath:cache_path
                               withIntermediateDirectories:NO attributes:nil error:nil]) abort();
    if (argc == 2 && !strcmp(argv[1], "--cache-only")) {
        app_folder_claim();
        printf("t_pso_archive cache cleanup: %d checks, %d failed\n", checks, failed);
        return failed != 0;
    }
    char dir[] = "/tmp/t_pso_archive.XXXXXX"; if (!mkdtemp(dir)) abort();
    setenv("DM_PSO_ARCHIVE", argc == 3 ? argv[2] : dir, 1);
    mtl_init(); NSError *err = nil;
    NSString *src = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\nstruct I { float4 a [[attribute(0)]]; };\n"
        "vertex V vs(I in [[stage_in]], uint id [[vertex_id]]) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.p = float4(uv * 2 - 1, 0, in.a.w); return o; }\n"
        "struct O { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; };\nfragment O fs() { return { float4(0.5, 0.25, 1.0, 0.5), float4(0.2, 0.4, 0.6, 0.8) }; }\n"
        "fragment O fs2() { return { float4(1), float4(0) }; }\n"
        "vertex V vs0(uint id [[vertex_id]]) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.p = float4(uv * 2 - 1, 0, 1); return o; }\n";
    if (getenv("DM_TEST_ARCHIVE_CONSTANTS")) src = [src stringByReplacingOccurrencesOfString:@"fragment O fs() { return" withString:@"constant bool enabled [[function_constant(0)]]; fragment O fs() { if (is_function_constant_defined(enabled) && enabled) discard_fragment(); return"];
    if (argc == 3) {
        NSString *metal = [@(argv[2]) stringByAppendingPathComponent:@"fixture.metal"], *library = [metal stringByAppendingString:@"lib"];
        if (strstr(argv[1], "-seed")) {   // a mode that writes the archive builds the shader library
            [src writeToFile:metal atomically:YES encoding:NSUTF8StringEncoding error:nil];
            NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
            task.arguments = @[@"-sdk", @"macosx", @"metal", metal, @"-o", library];
            if (![task launchAndReturnError:&err]) return 1;
            [task waitUntilExit]; if (task.terminationStatus) return 1;
        }
        g_lib = [g_dev newLibraryWithURL:[NSURL fileURLWithPath:library] error:&err];
    } else g_lib = [g_dev newLibraryWithSource:src options:nil error:&err];
    if (!g_lib) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
    g_lib2 = [g_dev newLibraryWithSource:[src stringByAppendingString:@"// another library: the same source would come back as the same library\n"] options:nil error:&err];
    g_lib3 = t4_lib([src stringByAppendingString:@"// the whole reference pipelines' library\n"], nil, &err);
    if (!g_lib2 || !g_lib3) { fprintf(stderr, "%s\n", err.localizedDescription.UTF8String); return 1; }
    lib_tag(g_lib, @"fixture.metallib"); lib_tag(g_lib2, @"fixture2.metallib");   // as lib_from_file names the game's: their pipelines have index keys
    // A period's write and the pipeline compiles do not overlap (ser_begin / ser_compile_begin; port of NXNative cc8f44906): the write waits for a compile under way, a compile
    // waits for a write under way (counted as held back), and a compile that does not return holds a write back SER_WAIT_MS at most
    if (argc == 2 && !strcmp(argv[1], "--ser-gate")) {
        pso4_init();
        MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
        EXPECT("gate: a capture", 1, pso_build(cd, 0, &err) != nil && atomic_load(&g_arch_new) == 1);
        ser_compile_begin();   // a compile under way
        arch_flush(); usleep(400000);
        EXPECT("gate: the period's write waits for the compile under way", 0, archive_files(@(dir)).count);
        ser_compile_end();
        EXPECT("gate: written once the compile returned", 0, dispatch_group_wait(g_arch_pending, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        EXPECT("gate: one file", 1, archive_files(@(dir)).count);
        ser_begin();   // a period serializing
        uint64_t holds = atomic_load(&g_ser_holds);
        cd.vertexDescriptor.layouts[16].stride += 16;
        __block int built = 0; dispatch_semaphore_t done = dispatch_semaphore_create(0); MTLRenderPipelineDescriptor *cd2 = [cd copy];
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool { built = pso_build(cd2, 0, NULL) != nil; } dispatch_semaphore_signal(done); });
        EXPECT("gate: a compile waits while a period serializes", 1, dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC)) != 0);
        pthread_mutex_lock(&g_ser_mu); int beside = g_ser_compiles; pthread_mutex_unlock(&g_ser_mu);
        EXPECT("gate: no compile under way beside the write", 0, beside);
        ser_end();
        EXPECT("gate: the compile goes on once the period is written", 0, dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
        EXPECT("gate: built, and counted as held back", 1, built && atomic_load(&g_ser_holds) == holds + 1);
        ser_compile_begin();   // a compile that does not return
        uint64_t t0 = now_ns(); arch_flush();
        EXPECT("gate: the write goes ahead beside it", 0, dispatch_group_wait(g_arch_pending, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
        double held = (now_ns() - t0) / 1e9;
        EXPECT("gate: after SER_WAIT_MS", 1, held > SER_WAIT_MS / 1e3 * 0.8 && held < SER_WAIT_MS / 1e3 + 2);
        EXPECT("gate: two files", 2, archive_files(@(dir)).count);
        ser_compile_end();
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive serialization gate: %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    // The windowed timer's write in play (port of NXNative f539b2dcd): with a window, the timer writes only once no frame was presented for ARCH_FLUSH_INTERVAL_S and no compile
    // is under way, and looks again meanwhile with the captures kept in the current period; a save, a full period and a run without a window write as before
    if (argc == 2 && !strcmp(argv[1], "--active-flush")) {
        pso4_init();
        test_archive_timer = 1; test_layer = [CAMetalLayer layer];
        const uint64_t idle_ns = (ARCH_FLUSH_INTERVAL_S + 1) * (uint64_t)NSEC_PER_SEC;
        MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
        EXPECT("timer: a capture", 1, pso_build(cd, 0, &err) != nil && atomic_load(&g_arch_new) == 1);
        atomic_store(&dm_present_ns, now_ns() - idle_ns);
        ser_compile_begin(); ArchEpoch *busy = ep_enter(0);   // a compile under way in the period
        fire_archive_timer();
        EXPECT("timer: idle, but a compile under way: the period stays", 1, busy == g_ep);
        atomic_store(&dm_present_ns, now_ns());   // the game presents again before the compile returns
        ep_leave(busy); ser_compile_end();
        fire_archive_timer();
        EXPECT("timer: presenting: deferred, nothing written", 0, archive_files(@(dir)).count);
        EXPECT("timer: the period still holds its capture", 1, atomic_load(&g_arch_new));
        atomic_store(&dm_present_ns, now_ns() - idle_ns);
        fire_archive_timer();
        EXPECT("timer: idle with no compile under way: written at once", 1, archive_files(@(dir)).count);
        EXPECT("timer: nothing left", 0, atomic_load(&g_arch_new));
        EXPECT("timer: no retry after the write", 1, test_timer_block == nil);
        atomic_store(&dm_present_ns, now_ns());
        cd.vertexDescriptor.layouts[16].stride += 16;
        EXPECT("timer: a capture in play", 1, pso_build(cd, 0, &err) != nil && atomic_load(&g_arch_new) == 1);
        fire_archive_timer();
        EXPECT("timer: deferred in play, its retry armed", 1, archive_files(@(dir)).count == 1 && test_timer_block != nil);
        cd.vertexDescriptor.layouts[16].stride += 16;
        uint64_t holds = atomic_load(&g_ser_holds);
        EXPECT("timer: a deferred write holds no compile back", 1, pso_build(cd, 0, &err) != nil && atomic_load(&g_ser_holds) == holds && atomic_load(&g_arch_new) == 2);
        mtl_arch_save(5000, 0);
        EXPECT("timer: a save writes in play", 2, archive_files(@(dir)).count);
        fire_archive_timer();
        EXPECT("timer: nothing left, no retry", 1, test_timer_block == nil && atomic_load(&g_arch_new) == 0);
        g_arch_period_max = 1; cd.vertexDescriptor.layouts[16].stride += 16;
        EXPECT("timer: a capture fills a period", 1, pso_build(cd, 0, &err) != nil);
        dispatch_group_wait(g_arch_pending, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        EXPECT("timer: a full period writes in play", 3, archive_files(@(dir)).count);
        g_arch_period_max = ARCH_PERIOD_MAX;
        if (test_timer_block) fire_archive_timer();
        test_layer = nil; cd.vertexDescriptor.layouts[16].stride += 16;
        EXPECT("timer: a capture without a window", 1, pso_build(cd, 0, &err) != nil && atomic_load(&g_arch_new) == 1);
        atomic_store(&dm_present_ns, now_ns());
        fire_archive_timer();
        dispatch_group_wait(g_arch_pending, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
        EXPECT("timer: without a window it writes as before", 4, archive_files(@(dir)).count);
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive windowed timer: %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    // The prebuild's new files opened before the first frame (arch_adopt_prebuilt, upstream NXNative 4add5fbb4): a base without a vertex layout captured into a p file after
    // pso4_init is found by a compile 0 lookup in the same run, from its index, with the miss recorded before it forgotten and nothing compiled; the file is not probed or noted
    // for the prebuild's trim; a second call opens nothing again; with too little address space left beside it the file is not opened, and a later call with room takes it
    if (argc == 2 && !strcmp(argv[1], "--adopt-prebuilt")) {
        pso4_init();
        MTLRenderPipelineDescriptor *nd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
        nd.vertexFunction = fn4_note([g_lib newFunctionWithName:@"vs0"], g_lib, @"vs0", nil);
        nd.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
        EXPECT("adopt: none in the archive yet", 1, pso_build_ex(nd, 0, &err, 0) == nil);
        EXPECT("adopt: the miss recorded", 1, g_pbase_miss.n);
        MTL4RenderPipelineDescriptor *m4 = pso_desc4(nd, 1, 0);
        EXPECT("adopt: its Metal 4 base descriptor", 1, m4 != nil);
        EXPECT("adopt: captured as the prebuild would", 1, arch_capture(m4, &err, 0, NULL) != nil);
        arch_flush_wait();
        NSArray<NSString *> *af = archive_files(@(dir));
        EXPECT("adopt: a p file written after pso4_init", 1, af.count == 1 && arch_name_kind(af[0]) == 1);
        g_arch_adopt_reserve = UINT64_MAX / 2;   // more than any task's address space
        arch_adopt_prebuilt();
        EXPECT("adopt, no room: not opened", 1, g_arch_ix.n == 0 && g_arch_ixf.count == 0);
        EXPECT("adopt, no room: the miss kept", 1, g_pbase_miss.n);
        g_arch_adopt_reserve = 2ull << 30;
        uint64_t arch0 = g_pb_archived, built0 = g_pb_built, asks0 = g_arch_asks;
        arch_adopt_prebuilt();
        EXPECT("adopt: indexed", 1, g_arch_ix.n == 1 && g_arch_ixf.count == 1);
        EXPECT("adopt: the miss forgotten", 0, g_pbase_miss.n);
        EXPECT("adopt: not probed, not the prebuild's to trim", 0, g_arch_probe_n + g_arch_pre_files.count);
        EXPECT("adopt: a compile 0 lookup finds it in the same run", 1, pso_build_ex(nd, 0, &err, 0) != nil);
        EXPECT("adopt: from the file its index names, nothing compiled", 1, g_pb_archived == arch0 + 1 && g_pb_built == built0 && g_arch_asks == asks0 + 1);
        arch_adopt_prebuilt();
        EXPECT("adopt: a second call opens nothing again", 1, g_arch_ixf.count == 1 && g_arch4p.count == 0);
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive adopt prebuilt: %d checks, %d failed\n", checks, failed); return failed != 0;
    }
    if (argc == 3 && !strncmp(argv[1], "--cold-", 7)) {   // across fresh processes: a cold start's prewarm with a timer flush after each new base, then the next start
        g_arch_period_max = 4; int seed = !strcmp(argv[1], "--cold-seed"), cut = !strcmp(argv[1], "--cold-cut-seed"), after_cut = !strcmp(argv[1], "--cold-after-cut");
        int quit = !strcmp(argv[1], "--cold-quit-seed"), after_quit = !strcmp(argv[1], "--cold-after-quit");
        // a crashed compaction's marker, left by an earlier run: the quit's write must not take it away
        if (quit) [arch_compact_stamp() writeToFile:[NSString stringWithFormat:@"%s/compacting", argv[2]] atomically:YES encoding:NSUTF8StringEncoding error:nil];
        pso4_init();
        EXPECT("cold restart: no compaction", 0, g_compact_enabled);
        uint64_t arch0 = g_pb_archived, built0 = g_pb_built, asks0 = g_arch_asks;
        atomic_store(&g_warm_running, 1);
        for (int i = 0; i <= PSO_ARCH_COMPACT; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 70);
            EXPECT("cold restart: pipeline", 1, pso_build(cd, 0, &err) != nil);
            if (seed || cut || quit) dispatch_sync(g_arch_q, ^{ arch_flush(); });   // the timer's
            if (cut && i == 5) {   // the cold start is killed here, in its prewarm: the full period is written, the 2 captures after it are not
                dispatch_group_wait(g_arch_pending, DISPATCH_TIME_FOREVER);
                printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
                _exit(failed != 0);
            }
            if (quit && i == 5) {   // the player quits here, in the prewarm: exit() writes the 2 captures after the full period too (mtl_arch_save)
                printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
                exit(failed != 0);
            }
        }
        atomic_store(&g_warm_running, 0); arch_flush_wait();
        int expect_archived = seed ? 0 : after_cut ? 4 : after_quit ? 6 : PSO_ARCH_COMPACT + 1;
        EXPECT("cold restart: compiled in the cold start, from the archive in the next", expect_archived, (int)(g_pb_archived - arch0));
        EXPECT("cold restart: compiled where not in the archive", PSO_ARCH_COMPACT + 1 - expect_archived, (int)(g_pb_built - built0));
        EXPECT("cold restart: the index asks one file for each base found and none for a miss", expect_archived, (int)(g_arch_asks - asks0));
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
        return failed != 0;
    }
    // Across fresh processes: a run ends in its prewarm, before any full period (Ocarina of Time's warm-up runs of 2026-11-10 without a window: 400-500 bases held, none written).
    // --warmflush-: the timer's flush in a prewarm the game plays through hands the period over once it is DM_PSO_ARCH_WARM_FLUSH_MS old, so a run killed after it (no exit write)
    // keeps them. --warmprep-: the same in the prepare step, which ends before the first frame, hands nothing over: the next start compiles them. --term-: SIGTERM while a draw is
    // still in the graphics layer (DM_TEST_STUCK_DRAW: it never leaves, as one compiling its pipeline did), so the drain never returns; the archive is written all the same.
    // --exec-: oe::ExecuteProgram's hand-over (dm_host_shutdown_then) with that draw: the next program (exec_then) starts after the write, and finds the file there. Then the
    // next start takes every base from the archive and compiles none
    if (argc == 3 && (!strncmp(argv[1], "--warmflush-", 12) || !strncmp(argv[1], "--warmprep-", 11) || !strncmp(argv[1], "--term-", 7) || !strncmp(argv[1], "--exec-", 7))) {
        int term = !strncmp(argv[1], "--term-", 7), exec = !strncmp(argv[1], "--exec-", 7), prep = !strncmp(argv[1], "--warmprep-", 11), seed = strstr(argv[1], "-seed") != NULL;
        enum { K = 5 };
        if (seed && term) { void dm_term_install(void); dm_term_install(); }
        pso4_init();
        uint64_t arch0 = g_pb_archived, built0 = g_pb_built;
        atomic_store(&g_warm_running, 1); atomic_store(&g_warm_bg, !prep);
        for (int i = 0; i < K; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 120);
            EXPECT("end in the prewarm: pipeline", 1, pso_build(cd, 0, &err) != nil);
        }
        if (seed) {
            EXPECT("end in the prewarm: compiled", K, (int)(g_pb_built - built0));
            if (!term && !exec) {   // the timer's flush, once the period is old enough; then the run is killed (no exit write)
                usleep(400 * 1000); dispatch_sync(g_arch_q, ^{ arch_flush(); }); dispatch_group_wait(g_arch_pending, DISPATCH_TIME_FOREVER);
                printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed); fflush(stdout);
                _exit(failed != 0);
            }
            if (getenv("DM_TEST_STUCK_DRAW")) { void dm_gfx_enter(void); dm_gfx_enter(); }   // a draw under way that does not return
            printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed); fflush(stdout);
            if (failed) _exit(1);
            if (exec) { void dm_host_shutdown_then(const char *, void (*)(void *), void *); dm_host_shutdown_then("test hand-over", exec_then, argv[2]); }
            kill(getpid(), SIGTERM);   // to the process, as a harness sends it: raise() aims it at this thread, where the ignored signal never reaches the GCD signal source
            for (;;) pause();
        }
        atomic_store(&g_warm_running, 0); arch_flush_wait();
        EXPECT("after an end in the prewarm: bases from the archive", prep ? 0 : K, (int)(g_pb_archived - arch0));
        EXPECT("after an end in the prewarm: bases compiled", prep ? K : 0, (int)(g_pb_built - built0));
        printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
        return failed != 0;
    }
    // A fresh process is essential: a compiler that built the source archives still has their online binaries.
    if (argc == 3 && !strncmp(argv[1], "--oldname-", 10)) {   // across fresh processes: nine run files named before the count (the test renames them) are compacted once, then not again
        int seed = !strcmp(argv[1], "--oldname-seed"), replay = !strcmp(argv[1], "--oldname-replay");
        pso4_init();
        NSMutableArray<MTLRenderPipelineDescriptor *> *descs = [NSMutableArray array];
        for (int i = 0; i <= PSO_ARCH_COMPACT; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 2); [descs addObject:cd];
        }
        if (seed) for (MTLRenderPipelineDescriptor *cd in descs) { EXPECT("old names restart: pipeline", 1, pso_build(cd, 0, &err) != nil); arch_flush_wait(); }
        else {
            EXPECT("old names restart: the nine old names compacted once", replay ? PSO_ARCH_COMPACT + 1 : 0, g_compact_enabled ? compacting_n() : 0);
            uint64_t arch0 = g_pb_archived, built0 = g_pb_built;
            atomic_store(&g_warm_running, 1);
            for (MTLRenderPipelineDescriptor *cd in descs) pso_build(cd, 0, &err);
            atomic_store(&g_warm_running, 0);
            EXPECT("old names restart: every base from disk", arch0 + descs.count, g_pb_archived);
            EXPECT("old names restart: none compiled", built0, g_pb_built);
            EXPECT("old names restart: none captured before the first frame", 0, g_compacted);
            compact_pass_run();
            EXPECT("old names restart: the nine captured again after it", replay ? PSO_ARCH_COMPACT + 1 : 0, g_compacted);
            arch_flush_wait();
        }
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
        return failed != 0;
    }
    if (argc == 3 && !strncmp(argv[1], "--tier-", 7)) {   // by tier across fresh processes: one full period's file and nine of one base; the nine compacted; then nothing to compact
        g_arch_period_max = 4; int seed = !strcmp(argv[1], "--tier-seed"), replay = !strcmp(argv[1], "--tier-replay");
        pso4_init();
        NSMutableArray<MTLRenderPipelineDescriptor *> *descs = [NSMutableArray array];
        for (int i = 0; i < 4 + PSO_ARCH_COMPACT + 1; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i < 4 ? i + 20 : i - 2); [descs addObject:cd];
        }
        if (seed) {
            for (int i = 0; i < 4; i++) EXPECT("tier restart: pipeline", 1, pso_build(descs[i], 0, &err) != nil);   // the 4th capture hands the period over
            arch_flush_wait();
            for (NSUInteger i = 4; i < descs.count; i++) { EXPECT("tier restart: pipeline", 1, pso_build(descs[i], 0, &err) != nil); arch_flush_wait(); }
        } else {
            EXPECT("tier restart: the nine small files compacted, not the full one", replay ? PSO_ARCH_COMPACT + 1 : 0, g_compact_enabled ? compacting_n() : 0);
            uint64_t arch0 = g_pb_archived, built0 = g_pb_built;
            atomic_store(&g_warm_running, 1);
            for (MTLRenderPipelineDescriptor *cd in descs) pso_build(cd, 0, &err);
            atomic_store(&g_warm_running, 0);
            EXPECT("tier restart: every base from disk", arch0 + descs.count, g_pb_archived);
            EXPECT("tier restart: none compiled", built0, g_pb_built);
            EXPECT("tier restart: the small files' bases alone noted", replay ? PSO_ARCH_COMPACT + 1 : 0, g_compact_bases);
            compact_pass_run();
            EXPECT("tier restart: the small files' bases alone captured again", replay ? PSO_ARCH_COMPACT + 1 : 0, g_compacted);
            arch_flush_wait();
        }
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
        return failed != 0;
    }
    // Across fresh processes, the compaction's pass after the first frame cut short by a quit: --defer-seed writes nine files of one base; --defer-quit compacts them with a
    // period of 4 (its prepare step captures nothing), captures 5 of them again and quits mid-pass (exit(): the period under way is written, the pass stops): the nine old files
    // stay beside the two new ones; --defer-replay finds every base (the 5 in the newer files), compacts what is left and removes the old files; --defer-verify compacts nothing
    if (argc == 3 && !strncmp(argv[1], "--defer-", 8)) {
        g_arch_period_max = 4; int seed = !strcmp(argv[1], "--defer-seed"), quit = !strcmp(argv[1], "--defer-quit"), replay = !strcmp(argv[1], "--defer-replay");
        pso4_init();
        NSMutableArray<MTLRenderPipelineDescriptor *> *descs = [NSMutableArray array];
        for (int i = 0; i <= PSO_ARCH_COMPACT; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 160); [descs addObject:cd];
        }
        if (seed) for (MTLRenderPipelineDescriptor *cd in descs) { EXPECT("deferred compaction: pipeline", 1, pso_build(cd, 0, &err) != nil); arch_flush_wait(); }
        else {
            EXPECT("deferred compaction: compacting", quit || replay, g_compact_enabled);
            uint64_t arch0 = g_pb_archived, built0 = g_pb_built; int new0 = g_arch_new;
            atomic_store(&g_warm_running, 1);
            dispatch_apply(descs.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) { @autoreleasepool { pso_build(descs[i], 0, NULL); } });
            atomic_store(&g_warm_running, 0);
            EXPECT("deferred compaction: every base from disk", arch0 + descs.count, g_pb_archived);
            EXPECT("deferred compaction: none compiled", built0, g_pb_built);
            EXPECT("deferred compaction: none captured before the first frame", 1, g_arch_new == new0 && !g_compacted);
            EXPECT("deferred compaction: noted", quit ? PSO_ARCH_COMPACT + 1 : replay ? 5 : 0, g_compact_bases);   // replay: the 4 of the full period's file are in no tier
            if (quit) {
                g_present_n = 1; g_cpass_start_ms = g_cpass_rest_ms = g_cpass_hold_ms = 3600000; g_cpass_batch = 5;
                g_cpass_hold_test = 0; compact_schedule(); compact_step_now();   // ready at once: the first batch
                EXPECT("deferred compaction: 5 captured again before the quit", 5, g_compacted);
                arch_flush_wait();
                mtl_warm_stop(); compact_step_now();   // the quit: the pass stops at its next step
                EXPECT("deferred compaction: stopped", 4, g_cpass);
                printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed); fflush(stdout);
                exit(failed != 0);   // arch_at_exit writes the period under way (1 base)
            }
            compact_pass_run();
            EXPECT("deferred compaction: captured again after the first frame", replay ? 5 : 0, g_compacted);
            if (replay) EXPECT("deferred compaction: done", 1, g_cpass == 3 && g_compact_closed && !g_compact_periods && !g_compact_bad);
        }
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
        return failed != 0;
    }
    if (argc == 3 && !strncmp(argv[1], "--stale-", 8)) {   // across fresh processes: files of another shader chain and files written before the chain stamp (fix 10)
        const char *keep_env = getenv("DM_PSO_KEEP_OLD"); int seed = !strcmp(argv[1], "--stale-seed"), keep = keep_env && !strcmp(keep_env, "1");
        NSMutableArray<MTLRenderPipelineDescriptor *> *descs = [NSMutableArray array];
        for (int i = 0; i < 6; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 100); [descs addObject:cd];
        }
        NSString *(^fpath)(int) = ^NSString *(int i) { return [NSString stringWithFormat:@"%s/%05d-1.mtl4a", argv[2], i]; };
        // an index as a host before the stamp wrote it (DMPSOIX1), or one stamped with another chain
        void (^write_ix)(int, NSData *, int, const char *) = ^(int i, NSData *keys, int complete, const char *chain) {
            uint32_t head[2] = {(uint32_t)complete, (uint32_t)(keys.length / 8)}; char st[ARCH_STAMP_LEN] = {0};
            NSMutableData *d = [NSMutableData dataWithBytes:chain ? "DMPSOIX2" : "DMPSOIX1" length:8]; [d appendBytes:head length:sizeof head];
            if (chain) { strncpy(st, chain, sizeof st); [d appendBytes:st length:sizeof st]; }
            [d appendData:keys]; [d writeToFile:arch_keys_path(fpath(i)) atomically:YES];
        };
        if (seed) {
            pso4_init();
            for (int i = 0; i < 6; i++) { EXPECT("stale chain: pipeline", 1, pso_build(descs[i], 0, &err) != nil); arch_flush_wait(); }
            NSData *key[6]; int complete = 0, stamp = 0;
            for (int i = 0; i < 6; i++) {
                key[i] = arch_keys_read_st(arch_keys_path(fpath(i)), &complete, &stamp);
                EXPECT("stale chain: a new file's index carries this chain", 1, stamp == 1 && complete == 1 && key[i].length == 8);
            }
            write_ix(0, key[0], 1, "000000000000");   // 0: another chain's (removed at the open, never opened)
            write_ix(1, key[1], 1, NULL);             // 1: no stamp, its own key (serves base 1: stamped)
            write_ix(3, key[0], 1, NULL);             // 3: no stamp, names base 0, which it does not hold (a named miss: removed)
            unlink(arch_keys_path(fpath(4)).fileSystemRepresentation);   // 4, 5: no index (scanned: 4 serves base 4, 5 serves nothing and is asked twice)
            unlink(arch_keys_path(fpath(5)).fileSystemRepresentation);
            int st = 0; EXPECT("stale chain: the old stamp reads as another chain", 1, arch_keys_read_st(arch_keys_path(fpath(0)), &complete, &st) && st == -1);
            EXPECT("stale chain: a DMPSOIX1 index reads as no stamp", 1, arch_keys_read_st(arch_keys_path(fpath(1)), &complete, &st) && st == 0 && complete == 1);
            EXPECT("stale chain: a DMPSOIX1 index keeps its keys", 1, [arch_keys_read(arch_keys_path(fpath(1)), &complete) isEqualToData:key[1]]);
        } else {
            g_arch_probe_miss = 1; g_arch_probe_asks = 2;
            pso4_init();
            NSFileManager *fm = NSFileManager.defaultManager;
            EXPECT("stale chain: files opened", keep ? 6 : 5, g_arch4.count + g_arch_ixf.count);
            EXPECT("stale chain: another chain's file removed at the open", keep ? 1 : 0, [fm fileExistsAtPath:fpath(0)]);
            EXPECT("stale chain: and its index", keep ? 1 : 0, [fm fileExistsAtPath:arch_keys_path(fpath(0))]);
            EXPECT("stale chain: counted", keep ? 0 : 1, g_arch_old_n);
            EXPECT("stale chain: files without a stamp probed", keep ? 0 : 4, g_arch_probe_n);
            uint64_t arch0 = g_pb_archived, built0 = g_pb_built;
            for (int i = 0; i < 5; i++) EXPECT("stale chain: pipeline", 1, pso_build(descs[i], 0, &err) != nil);
            // with the old file kept, base 0 is still compiled: file 3 is newer and its index names base 0, so a lookup asks it alone (a named lookup asks one file) and misses
            EXPECT("stale chain: bases 1, 2 and 4 from the archive", 3, (int)(g_pb_archived - arch0));
            EXPECT("stale chain: bases 0 and 3 compiled", 2, (int)(g_pb_built - built0));
            int gone = arch_probe_settle(), complete = -1, st = 0;
            EXPECT("stale chain: probe removed the files that served nothing", keep ? 0 : 2, gone);
            EXPECT("stale chain: a named miss and no hit: removed", keep ? 1 : 0, [fm fileExistsAtPath:fpath(3)]);
            EXPECT("stale chain: asked twice, no hit, no index: removed", keep ? 1 : 0, [fm fileExistsAtPath:fpath(5)]);
            EXPECT("stale chain: the current file stays", 1, [fm fileExistsAtPath:fpath(2)]);
            EXPECT("stale chain: an unstamped file that served a base stays", 1, [fm fileExistsAtPath:fpath(1)] && [fm fileExistsAtPath:fpath(4)]);
            NSData *k1 = arch_keys_read_st(arch_keys_path(fpath(1)), &complete, &st);
            EXPECT("stale chain: and gets this chain's stamp, its keys and completeness kept", keep ? 0 : 1, k1.length == 8 && st == 1 && complete == 1);
            NSData *k4 = arch_keys_read_st(arch_keys_path(fpath(4)), &complete, &st);
            EXPECT("stale chain: a file with no index gets an empty stamped one, not complete", keep ? 0 : 1, k4 && k4.length == 0 && st == 1 && complete == 0);
            EXPECT("stale chain: settles once", 0, arch_probe_settle());
            g_arch_cap = 0;   // the new bases are not written at exit: the folder is checked as the probe left it
        }
        printf("t_pso_archive %s%s: %d checks, %d failed\n", argv[1], keep ? " (DM_PSO_KEEP_OLD=1)" : "", checks, failed);
        return failed != 0;
    }
    if (argc == 3) {
        int seed = !strcmp(argv[1], "--compact-seed");
        pso4_init();
        EXPECT("restart: opened run archives", seed ? 0 : !strcmp(argv[1], "--compact-replay") ? PSO_ARCH_COMPACT + 1 : 1, g_arch4.count + g_arch_ixf.count);
        atomic_store(&g_warm_running, !seed);
        NSMutableArray<MTLRenderPipelineDescriptor *> *descs = [NSMutableArray array];
        for (int i = 0; i <= PSO_ARCH_COMPACT; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 2);
            [descs addObject:cd];
            if (seed) { EXPECT("restart: pipeline", 1, pso_build(cd, 0, &err) != nil); arch_flush_wait(); }
        }
        if (!seed) {
            int fresh = getenv("DM_TEST_ARCHIVE_MIXED") != NULL, compacting = g_compact_files != nil;
            int outcomes[PSO_ARCH_COMPACT + 1] = {0}; int *results = outcomes;
            dispatch_apply(descs.count, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(size_t i) {
                @autoreleasepool { results[i] = pso_build(descs[i], 0, NULL) != nil; }
            });
            for (int i = 0; i <= PSO_ARCH_COMPACT; i++) EXPECT("restart: pipeline", 1, outcomes[i]);
            if (fresh) {
                MTLRenderPipelineDescriptor *extra = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
                extra.fragmentFunction = test_fn(g_lib, @"fs2", 1);
                extra.vertexDescriptor.layouts[16].stride = 4096;
                EXPECT("restart: fresh pipeline mixed with recaptures", 1, pso_build(extra, 0, &err) != nil);
            }
            EXPECT("restart: every base from disk", PSO_ARCH_COMPACT + 1 + (fresh && !compacting), g_pb_archived);
            EXPECT("restart: compiled bases", fresh && compacting, g_pb_built);
            dispatch_sync(g_arch_q, ^{ arch_flush(); });
            if (g_compact_files) EXPECT("restart: the prepare step captures none again, the timed flush keeps the fresh base pending", fresh, g_arch_new);
            atomic_store(&g_warm_running, 0);
            if (g_compact_files) {   // the pass after the first frame: its recaptures join the fresh base's period (issue #342: mixed in one serializer)
                compact_pass_run();
                EXPECT("restart: every base captured again after the first frame", PSO_ARCH_COMPACT + 1, g_compacted);
            }
            arch_flush_wait();
        }
        if (seed && getenv("DM_TEST_ARCHIVE_MIXED")) [arch_os_build() writeToFile:arch_compact_marker() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
        printf("t_pso_archive %s: %d checks, %d failed\n", argv[1], checks, failed);
        return failed != 0;
    }
    // pipelines differing only in colour state share one base
    same_pixels("RGBA8 blended, RGBA16F all channels", MTLPixelFormatRGBA8Unorm, 1, MTLPixelFormatRGBA16Float, MTLColorWriteMaskAll);
    EXPECT("first pipeline: its base compiled", 1, g_pb_built);
    same_pixels("RGBA16F, RGBA8 red and green", MTLPixelFormatRGBA16Float, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskRed | MTLColorWriteMaskGreen);
    same_pixels("RGBA8, RGBA8 no channel", MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskNone);
    EXPECT("other colour states: the same base", 1, g_pb_built);
    EXPECT("other colour states: base reused", 2, g_pb_reused);
    EXPECT("one specialization per pipeline", 3, g_pb_spec);
    // the archive: flushed to a file, a later start takes the base from it without compiling
    EXPECT("one base waits for the archive", 1, g_arch_new);
    ArchEpoch *ep0 = g_ep;
    arch_flush_wait();
    NSString *file = [@(dir) stringByAppendingPathComponent:@"00000-1.mtl4a"];   // <seq>-<pipelines it holds>
    EXPECT("archive file written", 1, [NSFileManager.defaultManager fileExistsAtPath:file]);
    EXPECT("the flush began a new period", 1, g_ep != ep0);
    EXPECT("nothing left to write", 0, g_arch_new);
    {   // its index: the one base's key, complete; a key is the descriptor's, the same for the same pipeline and another for another, none without names
        int complete = -1; NSData *keys = arch_keys_read(arch_keys_path(file), &complete);
        MTLRenderPipelineDescriptor *k1 = desc(MTLPixelFormatRGBA8Unorm, 1, MTLPixelFormatRGBA16Float, MTLColorWriteMaskAll, 1), *k2 = desc(MTLPixelFormatRGBA8Unorm, 1, MTLPixelFormatRGBA16Float, MTLColorWriteMaskAll, 1);
        uint64_t a = arch_key(pso_desc4(k1, 1, 0)), b = arch_key(pso_desc4(k2, 1, 0));
        EXPECT("index: written beside the file, one key", 1, keys.length == sizeof(uint64_t));
        EXPECT("index: complete", 1, complete);
        EXPECT("index: the base's key", 1, keys.length == sizeof(uint64_t) && !memcmp(keys.bytes, &a, sizeof a));
        EXPECT("key: the same pipeline, the same key", 1, a && a == b);
        k2.vertexDescriptor.layouts[16].stride = 32;
        EXPECT("key: another layout, another key", 1, arch_key(pso_desc4(k2, 1, 0)) != a);
        MTL4RenderPipelineDescriptor *u = pso_desc4(k1, 1, 0); MTL4LibraryFunctionDescriptor *uf = [MTL4LibraryFunctionDescriptor new];
        uf.library = [g_dev newLibraryWithSource:[src stringByAppendingString:@"// a library with no name\n"] options:nil error:&err]; uf.name = @"vs"; u.vertexFunctionDescriptor = uf;
        EXPECT("key: none for a library with no name", 0, arch_key(u));
        uf.library = g_lib;
        uint64_t (^spec_key)(MTLFunctionConstantValues *) = ^uint64_t(MTLFunctionConstantValues *cv) {   // the descriptors copy what they are given: set, then assign
            MTL4SpecializedFunctionDescriptor *sf = [MTL4SpecializedFunctionDescriptor new]; sf.functionDescriptor = uf; sf.constantValues = cv; u.vertexFunctionDescriptor = sf;
            return arch_key(u);
        };
        MTLFunctionConstantValues *c1 = [MTLFunctionConstantValues new], *c2 = [MTLFunctionConstantValues new]; bool on = 1, off = 0; int seven = 7;
        [c1 setConstantValue:&on type:MTLDataTypeBool atIndex:3]; [c1 setConstantValue:&seven type:MTLDataTypeInt atIndex:0];
        [c2 setConstantValue:&seven type:MTLDataTypeInt atIndex:0]; [c2 setConstantValue:&on type:MTLDataTypeBool atIndex:3];   // the same values, set in another order
        uint64_t c0 = spec_key([MTLFunctionConstantValues new]), ka = spec_key(c1), kb = spec_key(c2);
        [c2 setConstantValue:&off type:MTLDataTypeBool atIndex:3]; uint64_t kc = spec_key(c2);
        EXPECT("key: constant values by their values", 1, c0 && ka && ka != c0 && ka == kb && kc != ka);
        int partial = -1; NSString *kp = [@(dir) stringByAppendingPathComponent:@"t.keys"];
        EXPECT("index: one with a pipeline with no key is not complete", 1, arch_keys_write(kp, keys, 0) && arch_keys_read(kp, &partial) && partial == 0);
        unlink(kp.fileSystemRepresentation);
    }
    nvn_hm_clear(&g_pbase, hm_rel);   // as a new start: no base in memory, the archive opened
    g_arch4 = @[[g_dev newArchiveWithURL:[NSURL fileURLWithPath:file] error:&err]];
    uint64_t built = g_pb_built;
    same_pixels("from the archive: RGBA8 blended, RGBA16F", MTLPixelFormatRGBA8Unorm, 1, MTLPixelFormatRGBA16Float, MTLColorWriteMaskAll);
    EXPECT("base from the archive", 1, g_pb_archived);
    EXPECT("no base compiled", built, g_pb_built);
    // a flush whose bases all read their vertices themselves (no vertex layout) is a p<seq> file; a base with a layout is never looked up in one
    MTLRenderPipelineDescriptor *nd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
    nd.vertexFunction = fn4_note([g_lib newFunctionWithName:@"vs0"], g_lib, @"vs0", nil); nd.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor];
    EXPECT("no layout: a pipeline", 1, pso_build(nd, 0, &err) != nil);
    EXPECT("no layout: its base compiled", built + 1, g_pb_built);
    arch_flush_wait();
    NSString *pfile = [@(dir) stringByAppendingPathComponent:@"p00001.mtl4a"];
    EXPECT("no layout: written to a p file", 1, [NSFileManager.defaultManager fileExistsAtPath:pfile]);
    nvn_hm_clear(&g_pbase, hm_rel);
    id<MTL4Archive> pa = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:pfile] error:&err], va = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:file] error:&err];
    g_arch4 = @[]; g_arch4p = @[pa, va];   // the layout base's file among the p files: not looked in
    uint64_t arch0 = g_pb_archived; built = g_pb_built;
    EXPECT("no layout again: a pipeline", 1, pso_build(nd, 0, &err) != nil);
    EXPECT("no layout again: base from the p file", arch0 + 1, g_pb_archived);
    {   // the index names a file for the base that misses there (a device file of another translation chain: the key names none) and the bundle holds it: taken from the bundle,
        // not compiled and captured again into a p file that shadows the bundle from then on (arch_lookup_in)
        int pc = 0; NSData *pk = arch_keys_read(arch_keys_path(pfile), &pc); uint64_t k0 = 0; if (pk.length >= sizeof k0) memcpy(&k0, pk.bytes, sizeof k0);
        EXPECT("named miss: the p file's index names the base", 1, k0 != 0 && pc == 1);
        nvn_hm_clear(&g_pbase, hm_rel); nvn_hm_put(&g_arch_ix, &k0, (__bridge void *)va); g_arch4p = @[]; g_arch_bundle = pa;
        uint64_t a1 = g_pb_archived, b1 = g_pb_built; int n1 = g_arch_new;
        EXPECT("named miss: a pipeline", 1, pso_build(nd, 0, &err) != nil);
        EXPECT("named miss: base from the bundle", a1 + 1, g_pb_archived);
        EXPECT("named miss: nothing compiled", b1, g_pb_built);
        EXPECT("named miss: nothing captured", n1, g_arch_new);
        g_arch_bundle = nil; nvn_hm_clear(&g_arch_ix, NULL); g_arch4p = @[pa, va]; nvn_hm_clear(&g_pbase, hm_rel);
    }
    same_pixels("layout base with only p files open", MTLPixelFormatRGBA8Unorm, 1, MTLPixelFormatRGBA16Float, MTLColorWriteMaskAll);
    EXPECT("layout base: not taken from a p file, compiled", built + 1, g_pb_built);
    EXPECT("layout base: one waits for a plain file", 1, g_arch_new_vd);
    // compaction: with more than PSO_ARCH_COMPACT files, the bases the prewarm takes from them are captured again; after the flush that follows, one file holds them and the old ones are gone
    {
        char cdir[] = "/tmp/t_pso_compact.XXXXXX"; if (!mkdtemp(cdir)) abort();
        NSString *saved = g_arch_dir; g_arch_dir = @(cdir); nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = @[]; g_arch4p = @[];
        NSMutableArray<MTLRenderPipelineDescriptor *> *descs = [NSMutableArray array];
        for (int i = 0; i <= PSO_ARCH_COMPACT; i++) {   // one base per file: the stride of the layout tells them apart
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 2); [descs addObject:cd];
            if (!pso_build(cd, 0, &err)) { fprintf(stderr, "compaction: no pipeline %d\n", i); failed++; }
            arch_flush_wait();
        }
        NSArray<NSString *> *names = [archive_files(@(cdir)) sortedArrayUsingSelector:@selector(compare:)];
        EXPECT("compaction: one file per flush", PSO_ARCH_COMPACT + 1, names.count);
        NSMutableArray<id<MTL4Archive>> *open = [NSMutableArray array]; NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *n in names.reverseObjectEnumerator) { NSString *f = [@(cdir) stringByAppendingPathComponent:n]; [paths addObject:f]; [open addObject:[g_dev newArchiveWithURL:[NSURL fileURLWithPath:f] error:&err]]; }
        nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = open;   // as a new start with that many files
        compact_reset(); g_compact_enabled = 1; g_compact_files = paths;
        g_arch_period_max = 4;   // the recaptured bases fill two periods and part of a third: each full one is handed over, the timer's flushes wait while the pass captures
        uint64_t arch0 = g_pb_archived, built0 = g_pb_built; int new0 = g_arch_new;
        atomic_store(&g_warm_running, 1);
        for (MTLRenderPipelineDescriptor *cd in descs) pso_build(cd, 0, &err);
        // the prepare step: lookups alone, every base noted, none captured before the first frame
        EXPECT("compaction: the prepare step captures nothing (captures before the first frame)", new0, g_arch_new);
        EXPECT("compaction: none captured again before the first frame", 0, g_compacted);
        EXPECT("compaction: the prepare line counts the bases noted", descs.count, g_compact_bases);
        dispatch_sync(g_arch_q, ^{ arch_flush(); });   // the timer fires while prewarm still has other work
        arch_flush_wait();
        EXPECT("compaction: no file written in the prepare step", PSO_ARCH_COMPACT + 1, archive_files(@(cdir)).count);
        atomic_store(&g_warm_running, 0);
        EXPECT("compaction: every base from the archive", arch0 + descs.count, g_pb_archived);
        EXPECT("compaction: none compiled", built0, g_pb_built);
        // the pass, a step at a time (its own waits are an hour long): not before the first frame, held while hot, then batches of 5
        uint64_t pn = g_present_n; g_present_n = 0; g_cpass_start_ms = g_cpass_rest_ms = g_cpass_hold_ms = 3600000; g_cpass_batch = 5;
        compact_schedule();
        EXPECT("compaction: the pass scheduled after the prewarm", 1, g_cpass);
        compact_step_now();
        EXPECT("compaction: the pass waits for the first frame", 1, g_cpass == 1 && !g_compacted);
        g_present_n = 1; g_cpass_hold_test = 1; compact_step_now();
        EXPECT("compaction: held while the device is hot", 1, g_cpass == 1 && g_cpass_held && !g_compacted);
        g_cpass_hold_test = 0;
        ArchEpoch *ep = g_ep; ArchiveGateCompiler *gate = [ArchiveGateCompiler new]; gate->compiler = ep->comp; gate->calls = 1; ep->comp = (id<MTL4Compiler>)gate;
        compact_step_now();   // 5: the 4th hands its period over (ARCH_PERIOD_MAX), the 5th starts the next
        ep->comp = gate->compiler;
        EXPECT("compaction: captures original shader functions, not archive imports", 0, gate->lookup_calls);
        EXPECT("compaction: the first batch captured", 1, g_cpass == 2 && !g_cpass_held && g_compacted == 5);
        dispatch_sync(g_arch_q, ^{ arch_flush(); });   // the timer fires while the pass captures
        arch_flush_wait();
        EXPECT("compaction: the timer's flush waits for the pass", 1, g_arch_new);
        EXPECT("compaction: a file per full period", PSO_ARCH_COMPACT + 2, archive_files(@(cdir)).count);
        g_cpass_hold_test = 2; compact_step_now();   // Low Power Mode: held, and the timer's flushes go on meanwhile
        EXPECT("compaction: held in Low Power Mode", 1, g_cpass_held && g_compacted == 5);
        dispatch_sync(g_arch_q, ^{ arch_flush(); }); arch_flush_wait();
        EXPECT("compaction: while held the timer's flush writes", 0, g_arch_new);
        EXPECT("compaction: its period a file", PSO_ARCH_COMPACT + 3, archive_files(@(cdir)).count);
        g_cpass_hold_test = 0;
        MarkerSerializer *ms = [MarkerSerializer new]; ms->ser = g_ep->ser; g_ep->ser = (id<MTL4PipelineDataSetSerializer>)ms;   // the period the last batch fills
        g_cpass_batch = 4; compact_step_now();   // the last 4: a full period, handed over at its 4th capture
        arch_flush_wait();
        EXPECT("compaction: the marker exists while the flush writes", 1, ms->calls == 1 && ms->marked == 1);
        EXPECT("compaction: the flush that returned removed the marker", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        EXPECT("compaction: every base captured again", descs.count, g_compacted);
        EXPECT("compaction: and their time", 1, g_compact_ns > 0);
        int kept = 0; for (NSString *f in paths) kept += [NSFileManager.defaultManager fileExistsAtPath:f];
        EXPECT("compaction: the old files stay until it closes", paths.count, kept);
        compact_step_now();   // no note left: it closes, and the old files go once its periods are written
        arch_flush_wait(); dispatch_sync(g_arch_q, ^{});
        EXPECT("compaction: closed", 3, g_cpass);
        kept = 0; for (NSString *f in paths) kept += [NSFileManager.defaultManager fileExistsAtPath:f];
        EXPECT("compaction: the old files removed", 0, kept);
        g_present_n = pn;
        // in the background (iOS, mtl_arch_save to mtl_arch_resume) no write arms the marker, and one armed when the app went there goes: iOS may SIGKILL a suspended app
        arch_mark_bg(1); arch_mark(1);
        EXPECT("compaction: no marker while in the background", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        arch_mark(0); arch_mark_bg(0); arch_mark(1);
        EXPECT("compaction: a marker again in the foreground", 1, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        arch_mark_bg(1);
        EXPECT("compaction: going to the background removes a write's marker", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        arch_mark_bg(0);
        EXPECT("compaction: a write still under way when the app comes back arms it again", 1, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        arch_mark(0);
        EXPECT("compaction: and the write that returned removes it", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        names = archive_files(@(cdir));
        EXPECT("compaction: a file per period left", (descs.count + 3) / 4, names.count);
        EXPECT("compaction: done", 0, g_compact_periods + !g_compact_closed + g_compact_bad);
        EXPECT("compaction: no failure file after one that finished", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_fail_path()]);
        compact_reset();
        g_arch_period_max = ARCH_PERIOD_MAX;
        // a compaction that did not finish: the same files, or up to PSO_ARCH_COMPACT more, are not compacted again on this system build; more, a missing one or another build try again
        {
            NSMutableArray<NSString *> *runf = [NSMutableArray array]; for (NSString *n in names) [runf addObject:[@(cdir) stringByAppendingPathComponent:n]];
            NSMutableArray<NSString *> *more = [runf mutableCopy]; for (int i = 0; i < PSO_ARCH_COMPACT; i++) [more addObject:[NSString stringWithFormat:@"%s/9%04d.mtl4a", cdir, i]];
            EXPECT("failed compaction: tried without the file", 1, arch_compact_retry(runf));
            arch_compact_fail_note();
            NSString *note = [NSString stringWithContentsOfFile:arch_compact_fail_path() encoding:NSUTF8StringEncoding error:nil];
            EXPECT("failed compaction: the file names the system build and the files", 1, [note containsString:arch_os_build()] && names.count && [note containsString:[names[0] stringByAppendingString:@"\n"]]);
            EXPECT("failed compaction: not again on the same files", 0, arch_compact_retry(runf));
            EXPECT("failed compaction: not again with up to PSO_ARCH_COMPACT more", 0, arch_compact_retry(more));
            EXPECT("failed compaction: the file stays", 1, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_fail_path()]);
            [more addObject:[NSString stringWithFormat:@"%s/99999.mtl4a", cdir]];
            EXPECT("failed compaction: again with more", 1, arch_compact_retry(more));
            EXPECT("failed compaction: the file removed", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_fail_path()]);
            arch_compact_fail_note();
            EXPECT("failed compaction: again when one is gone", 1, arch_compact_retry([runf subarrayWithRange:NSMakeRange(1, runf.count - 1)]));
            arch_compact_fail_note();
            NSString *other = [[NSString stringWithContentsOfFile:arch_compact_fail_path() encoding:NSUTF8StringEncoding error:nil] stringByReplacingOccurrencesOfString:arch_os_build() withString:@"os\t1A1\n"];
            [other writeToFile:arch_compact_fail_path() atomically:YES encoding:NSUTF8StringEncoding error:nil];
            EXPECT("failed compaction: again on another system build", 1, arch_compact_retry(runf));
            // a plain file the start kept but could not open or read (g_arch_unusable) is none of the run's files: the note leaves it out, or every start tried again
            {
                NSString *kept = [NSString stringWithFormat:@"%s/77777.mtl4a", cdir];
                [@"x" writeToFile:kept atomically:YES encoding:NSUTF8StringEncoding error:nil]; g_arch_unusable = [NSMutableSet setWithObject:kept.lastPathComponent];
                arch_compact_fail_note();
                NSString *kn = [NSString stringWithContentsOfFile:arch_compact_fail_path() encoding:NSUTF8StringEncoding error:nil];
                EXPECT("failed compaction: a file kept unread is not in the note", 0, [kn containsString:@"77777.mtl4a"]);
                EXPECT("failed compaction: and does not make the next start try again", 0, arch_compact_retry(runf));
                g_arch_unusable = nil; unlink(kept.fileSystemRepresentation); unlink(arch_compact_fail_path().fileSystemRepresentation);
            }
            // the start's pick asks it (arch_compact_pick): a tier over PSO_ARCH_COMPACT on the files a failed compaction named, and up to PSO_ARCH_COMPACT more, is not picked
            NSMutableArray<NSString *> *pick = [runf mutableCopy]; for (int i = 0; i < PSO_ARCH_COMPACT; i++) [pick addObject:[NSString stringWithFormat:@"%s/8%04d-1.mtl4a", cdir, i]];
            arch_compact_fail_note(); g_compact_enabled = 0; g_compact_files = nil; g_compact_state = NULL;
            arch_compact_pick(pick);
            EXPECT("failed compaction: the pick holds back on the same files", 0, g_compact_enabled);
            [pick addObject:[NSString stringWithFormat:@"%s/89999-1.mtl4a", cdir]];
            arch_compact_pick(pick);
            EXPECT("failed compaction: the pick takes the tier with more", 1, g_compact_enabled && g_compact_files == pick);
            EXPECT("failed compaction: and the file goes", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_fail_path()]);
            free(g_compact_state); g_compact_state = NULL; g_compact_enabled = 0; g_compact_files = nil;
        }
        // a marker left by a compaction that did not finish: the next start on this system build does not compact, one from another build is removed and compaction tried
        EXPECT("compaction: allowed without a marker", 1, arch_compact_allowed());
        [arch_compact_stamp() writeToFile:arch_compact_marker() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        EXPECT("compaction: not after one that did not finish on this system build", 0, arch_compact_allowed());
        EXPECT("compaction: that marker stays", 1, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        [[@"os\t1A1\n" stringByAppendingString:@"capture\toriginal-functions-v1\n"] writeToFile:arch_compact_marker() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        EXPECT("compaction: tried again on another system build", 1, arch_compact_allowed());
        EXPECT("compaction: the other build's marker removed", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        [arch_os_build() writeToFile:arch_compact_marker() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        EXPECT("compaction: old archive-import marker permits the new capture method", 1, arch_compact_allowed());
        EXPECT("compaction: old capture marker removed", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_compact_marker()]);
        nvn_hm_clear(&g_pbase, hm_rel); g_compact_enabled = 0; g_compacted = 0;
        NSMutableArray<id<MTL4Archive>> *left = [NSMutableArray array];
        for (NSString *n in names) [left addObject:[g_dev newArchiveWithURL:[NSURL fileURLWithPath:[@(cdir) stringByAppendingPathComponent:n]] error:&err]];
        g_arch4 = left;
        arch0 = g_pb_archived; built0 = g_pb_built;
        for (MTLRenderPipelineDescriptor *cd in descs) pso_build(cd, 0, &err);
        EXPECT("compaction: the new files hold every base", arch0 + descs.count, g_pb_archived);
        EXPECT("compaction: none compiled from the new files", built0, g_pb_built);
        [NSFileManager.defaultManager removeItemAtPath:@(cdir) error:nil]; g_arch_dir = saved; g_arch4 = @[];
    }
    // compaction by size tier: which run files a start compacts, from their names
    {
        g_arch_period_max = ARCH_PERIOD_MAX;
        EXPECT("tier: nine files of one pipeline", 9, pick_n(@[@[@9, @1]]));
        EXPECT("tier: nine full periods, none", 0, pick_n(@[@[@9, @(ARCH_PERIOD_MAX)]]));
        EXPECT("tier: nine small files, not the three larger ones", 9, pick_n(@[@[@9, @1], @[@3, @16]]));
        EXPECT("tier: nine in a larger tier take the smaller files with them", 11, pick_n(@[@[@2, @1], @[@9, @16]]));
        EXPECT("tier: eight in each tier, none", 0, pick_n(@[@[@8, @1], @[@8, @16], @[@8, @100], @[@8, @1000]]));
        EXPECT("tier: nine files named before the count, as the largest tier", 9, pick_n(@[@[@9, @0]]));
        EXPECT("tier: five named before the count stay beside nine small files", 9, pick_n(@[@[@5, @0], @[@9, @1]]));
        int F = ARCH_PERIOD_MAX;   // a compaction's full periods beside the files of play
        EXPECT("tier: five full, a session of 5 files under 8 and 4 under 64", 0, pick_n(@[@[@5, @(F)], @[@5, @6], @[@4, @20]]));
        EXPECT("tier: five full, a session of 30 small files", 30, pick_n(@[@[@5, @(F)], @[@30, @6]]));
        EXPECT("tier: five full, a session of 273 small files", 273, pick_n(@[@[@5, @(F)], @[@273, @6]]));
        EXPECT("tier: nine full periods (more than 16,000 bases), none", 0, pick_n(@[@[@9, @(F)], @[@1, @300]]));
        EXPECT("tier: nine named before the count beside five full, those nine", 9, pick_n(@[@[@5, @(F)], @[@9, @0]]));
        EXPECT("tier: a count that does not parse counts as named before, not as small", 9, pick_n(@[@[@5, @(-1)], @[@9, @1]]));
        EXPECT("tier: nine small files beside eight of a tier above, the small ones", 9, pick_n(@[@[@8, @16], @[@9, @1]]));
        EXPECT("tier: their merge makes the ninth file above, which the next start takes", 9, pick_n(@[@[@8, @16], @[@1, @9]]));
        int bounds[][2] = {{1, 0}, {7, 0}, {8, 1}, {63, 1}, {64, 2}, {511, 2}, {512, 3}, {1999, 3}, {2000, 8}, {2010, 8}};
        for (int i = 0; i < 10; i++) EXPECT("tier: its boundaries", bounds[i][1], arch_tier([NSString stringWithFormat:@"/x/00001-%d.mtl4a", bounds[i][0]]));
        EXPECT("tier: a count past an int counts as named before", 3, arch_tier(@"/x/00001-99999999999.mtl4a"));
        // many sessions by the rule alone: 5 full files, then 200 sessions of 30 files of 6 pipelines, each start compacting what it picks into a file per full period and the rest.
        // Without tiers every start took every file; here the files left below a full period stay at most 4 tiers of 8, and each pipeline is captured again about once per tier
        {
            NSMutableArray<NSNumber *> *files = [NSMutableArray arrayWithArray:@[@(F), @(F), @(F), @(F), @(F)]]; long added = 0, again = 0, biggest = 0; int most = 0, seq = 0, starts = 0, fulls = 0;
            for (int session = 0; session < 200; session++) {
                for (int i = 0; i < 30; i++) [files addObject:@6];
                added += 30 * 6;
                NSMutableArray<NSString *> *names = [NSMutableArray array];
                for (NSNumber *c in files) [names addObject:[NSString stringWithFormat:@"/x/%05d-%d.mtl4a", seq++, c.intValue]];
                g_compact_enabled = 0; g_compact_files = nil; g_compact_state = NULL; arch_compact_pick(names);
                if (!g_compact_enabled) continue;
                NSMutableArray<NSNumber *> *left = [NSMutableArray array]; long taken = 0; starts++;
                for (NSUInteger i = 0; i < files.count; i++) { if (g_compact_state[i]) { taken += files[i].intValue; fulls += files[i].intValue >= F; } else [left addObject:files[i]]; }
                again += taken; biggest = MAX(biggest, taken);
                for (; taken >= F; taken -= F) [left addObject:@(F)];
                if (taken) [left addObject:@(taken)];
                files = left; int small = 0; for (NSNumber *c in files) small += c.intValue < F; most = MAX(most, small);
            }
            g_compact_enabled = 0; g_compact_files = nil; g_compact_state = NULL;
            EXPECT("tier, 200 sessions: every start after a session of 30 small files compacts", 200, starts);
            EXPECT("tier, 200 sessions: no full period's file taken", 0, fulls);
            EXPECT("tier, 200 sessions: files below a full period stay at most 4 tiers of 8", 1, most <= 4 * PSO_ARCH_COMPACT);
            EXPECT("tier, 200 sessions: what play added captured again at least once, and 3 times or fewer on average", 1, again >= added && again <= 3 * added);
            EXPECT("tier, 200 sessions: the largest start below the whole archive", 1, biggest < added / 2);
        }
    }
    // a compaction: the full periods' files stay, used or not, and their bases are not captured again; the nine files of one base are compacted; the next start takes
    // every base from the files left
    {
        char cdir[] = "/tmp/t_pso_tier.XXXXXX"; if (!mkdtemp(cdir)) abort();
        NSString *saved = g_arch_dir; g_arch_dir = @(cdir); nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = @[]; g_arch4p = @[];
        g_arch_period_max = 4;
        g_compact_enabled = 0; g_compact_files = nil; g_compact_state = NULL; compact_reset();
        NSMutableArray<MTLRenderPipelineDescriptor *> *full = [NSMutableArray array], *unused = [NSMutableArray array], *small = [NSMutableArray array];
        for (int k = 0; k < 2; k++) {   // two full periods: each 4th capture hands its period over
            for (int i = 0; i < 4; i++) {
                MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
                cd.vertexDescriptor.layouts[16].stride = 16 * (20 + 10 * k + i); [k ? full : unused addObject:cd];
                if (!pso_build(cd, 0, &err)) { fprintf(stderr, "tier: no pipeline %d\n", i); failed++; }
            }
            arch_flush_wait();
        }
        for (int i = 0; i <= PSO_ARCH_COMPACT; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 2); [small addObject:cd];
            if (!pso_build(cd, 0, &err)) { fprintf(stderr, "tier: no pipeline %d\n", i); failed++; }
            arch_flush_wait();
        }
        NSArray<NSString *> *names = [archive_files(@(cdir)) sortedArrayUsingSelector:@selector(compare:)];
        EXPECT("tier: two full periods' files and one file per flush", PSO_ARCH_COMPACT + 3, names.count);
        EXPECT("tier: a full period's file, in no tier", 8, names.count ? arch_tier(names[0]) : -1);
        EXPECT("tier: a flush of one pipeline, the smallest tier", 0, names.count ? arch_tier(names.lastObject) : -1);
        NSString *gone = names.count > 1 ? [@(cdir) stringByAppendingPathComponent:names[0]] : @"", *kept = names.count > 1 ? [@(cdir) stringByAppendingPathComponent:names[1]] : @"";
        NSMutableArray<id<MTL4Archive>> *open = [NSMutableArray array]; NSMutableArray<NSString *> *paths = [NSMutableArray array];
        for (NSString *n in names.reverseObjectEnumerator) { NSString *f = [@(cdir) stringByAppendingPathComponent:n]; [paths addObject:f]; [open addObject:[g_dev newArchiveWithURL:[NSURL fileURLWithPath:f] error:&err]]; }
        nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = open;   // as a new start with these files
        arch_compact_pick(paths);
        EXPECT("tier: more than PSO_ARCH_COMPACT small files: compaction", 1, g_compact_enabled);
        EXPECT("tier: the small files alone", (long)small.count, compacting_n());
        NSMutableArray<NSString *> *compacted = [NSMutableArray array]; for (NSUInteger i = 0; i < paths.count; i++) if (g_compact_state[i] == 1) [compacted addObject:paths[i]];
        uint64_t arch0 = g_pb_archived, built0 = g_pb_built;
        atomic_store(&g_warm_running, 1);
        for (MTLRenderPipelineDescriptor *cd in full) pso_build(cd, 0, &err);
        for (MTLRenderPipelineDescriptor *cd in small) pso_build(cd, 0, &err);
        atomic_store(&g_warm_running, 0);
        EXPECT("tier: every base from the archive", arch0 + full.count + small.count, g_pb_archived);
        EXPECT("tier: none compiled", built0, g_pb_built);
        EXPECT("tier: only the small files' bases noted", small.count, g_compact_bases);
        EXPECT("tier: none captured before the first frame", 0, g_compacted);
        compact_pass_run();   // after the first frame
        EXPECT("tier: only the small files' bases captured again", small.count, g_compacted);
        EXPECT("tier: done", 0, g_compact_periods + !g_compact_closed + g_compact_bad);
        EXPECT("tier: the full period's file the prewarm took from stays", 1, [NSFileManager.defaultManager fileExistsAtPath:kept]);
        EXPECT("tier: the full period's file the run took nothing from stays too", 1, [NSFileManager.defaultManager fileExistsAtPath:gone]);
        int left = 0; for (NSString *f in compacted) left += [NSFileManager.defaultManager fileExistsAtPath:f];
        EXPECT("tier: the small files removed", 0, left);
        names = [archive_files(@(cdir)) sortedArrayUsingSelector:@selector(compare:)];
        EXPECT("tier: the two full files and a file per period", 2 + (small.count + 3) / 4, names.count);
        nvn_hm_clear(&g_pbase, hm_rel); g_compact_enabled = 0; g_compact_files = nil; g_compact_state = NULL; compact_reset();
        NSMutableArray<id<MTL4Archive>> *again = [NSMutableArray array];
        for (NSString *n in names.reverseObjectEnumerator) [again addObject:[g_dev newArchiveWithURL:[NSURL fileURLWithPath:[@(cdir) stringByAppendingPathComponent:n]] error:&err]];
        g_arch4 = again; arch0 = g_pb_archived; built0 = g_pb_built;
        for (MTLRenderPipelineDescriptor *cd in full) pso_build(cd, 0, &err);
        for (MTLRenderPipelineDescriptor *cd in small) pso_build(cd, 0, &err);
        EXPECT("tier: the files left hold every base the prewarm took", arch0 + full.count + small.count, g_pb_archived);
        EXPECT("tier: none compiled from them", built0, g_pb_built);
        nvn_hm_clear(&g_pbase, hm_rel); g_arch_period_max = ARCH_PERIOD_MAX;
        [NSFileManager.defaultManager removeItemAtPath:@(cdir) error:nil]; g_arch_dir = saved; g_arch4 = @[];
    }
    compute_pipelines();
    // a timer's flush waits for the prewarm's end, compacting or not, and so a cold start writes a file per full period, not one per 10 s: here 3 files for 9 new bases,
    // where a file per timer flush made 9, more than PSO_ARCH_COMPACT, and the next start compacted them all
    {
        char cdir[] = "/tmp/t_pso_cold.XXXXXX"; if (!mkdtemp(cdir)) abort();
        NSString *saved = g_arch_dir; g_arch_dir = @(cdir); nvn_hm_clear(&g_pbase, hm_rel); g_arch4 = @[]; g_arch4p = @[];
        g_arch_period_max = 4; atomic_store(&g_warm_running, 1);
        for (int i = 0; i <= PSO_ARCH_COMPACT; i++) {
            MTLRenderPipelineDescriptor *cd = desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 1);
            cd.vertexDescriptor.layouts[16].stride = 16 * (i + 70);
            if (!pso_build(cd, 0, &err)) { fprintf(stderr, "cold: no pipeline %d\n", i); failed++; }
            ArchEpoch *ep = g_ep;
            dispatch_sync(g_arch_q, ^{ arch_flush(); });   // the timer's
            if (i % 4 != 3) EXPECT("cold: the timer's flush waits for the prewarm's end", 1, g_ep == ep);
        }
        atomic_store(&g_warm_running, 0); arch_flush_wait();
        NSUInteger files = archive_files(@(cdir)).count;
        EXPECT("cold: a file per full period and one for the rest", (PSO_ARCH_COMPACT + 4) / 4, files);
        nvn_hm_clear(&g_pbase, hm_rel); g_arch_period_max = ARCH_PERIOD_MAX;
        [NSFileManager.defaultManager removeItemAtPath:@(cdir) error:nil]; g_arch_dir = saved; g_arch4 = @[];
    }
    mesh_pipelines();
    // a function with no Metal 4 descriptor: no pipeline, an error that names the note (there is no MTLDevice path)
    uint64_t built0 = g_pb_built; err = nil;
    id<MTLRenderPipelineState> l = pso_build(desc(MTLPixelFormatRGBA8Unorm, 0, MTLPixelFormatRGBA8Unorm, MTLColorWriteMaskAll, 0), 0, &err);
    EXPECT("unregistered function: no pipeline", 1, l == nil);
    EXPECT("unregistered function: an error naming the missing note", 1, err && [err.localizedDescription containsString:@"fn4_note"]);
    EXPECT("unregistered function: nothing compiled", built0, g_pb_built);
    depth_only();
    concurrent_bases(0);
    concurrent_bases(1);
    crashed_period();
    compaction_claim();
    // key normalization
    pso_key k; memset(&k, 0, sizeof k); k.blend_en = 0x5; k.dfmt = MTLPixelFormatDepth32Float; k.sfmt = MTLPixelFormatStencil8;
    for (int i = 0; i < 8; i++) { k.cfmt[i] = MTLPixelFormatRGBA8Unorm; k.blend[i].src_rgb = 5; k.blend[i].dst_rgb = 6; }   // every target present: only the blend rule acts
    pso_key_norm(&k, 0);
    EXPECT("blend of an enabled target kept", 5, k.blend[0].src_rgb);
    EXPECT("blend of an enabled target kept (2)", 6, k.blend[2].dst_rgb);
    EXPECT("blend of a disabled target dropped", 0, k.blend[1].src_rgb);
    EXPECT("blend of a disabled target dropped (7)", 0, k.blend[7].dst_rgb);
    EXPECT("depth format kept (an MTLDevice pipeline names it)", MTLPixelFormatDepth32Float, k.dfmt);
    EXPECT("stencil format kept", MTLPixelFormatStencil8, k.sfmt);
    // a function that declares function constants (fn_spec, as shader_load loads one): on the Metal 4 path it stays unspecialized, with a specialized descriptor, and a
    // pipeline is made from it; nothing is specialized through MTLLibrary, which compiles through the MTLDevice (the HUD's "Consider adopting MTL4Compiler")
    {
        id<MTLLibrary> cl = [g_dev newLibraryWithSource:@"#include <metal_stdlib>\nusing namespace metal;\nconstant bool k [[function_constant(0)]];\n"
            "struct V { float4 p [[position]]; };\nvertex V cvs(uint i [[vertex_id]]) { V o; o.p = float4(is_function_constant_defined(k) && k ? 1 : 0, 0, 0, 1); return o; }\n"
            "fragment float4 cfs() { return is_function_constant_defined(k) && k ? float4(1) : float4(0); }\nfragment float4 plain() { return float4(1); }\n" options:nil error:&err];
        functions_unspecialized(cl);
        NSError *se = nil; id<MTLFunction> cf = fn_spec(cl, @"cfs", [MTLFunctionConstantValues new], &se), cv = fn_spec(cl, @"cvs", [MTLFunctionConstantValues new], &se);
        EXPECT("constants: the function stays unspecialized on the Metal 4 path", 1, cf.functionConstantsDictionary.count);
        EXPECT("constants: its descriptor specializes it", 1, [fn4_of(cf) isKindOfClass:MTL4SpecializedFunctionDescriptor.class]);
        MTLRenderPipelineDescriptor *cd = [MTLRenderPipelineDescriptor new]; cd.vertexFunction = cv; cd.fragmentFunction = cf; cd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        EXPECT("constants: a pipeline made from it (through the Metal 4 compiler)", 1, pso_build(cd, 0, &se) != nil);
        // a fragment function with no Metal 4 descriptor: no pipeline (every function a pipeline is built from is noted, the DM_NVN_HILITE overrides too)
        cd.fragmentFunction = [cl newFunctionWithName:@"plain"]; se = nil;
        EXPECT("constants: an unnoted fragment function gets no pipeline", 1, pso_build(cd, 0, &se) == nil && se != nil);
    }
    repeated_archive_miss();
    spec_desc_ownership();
    capture_preserves_foreign_folder();
    app_folder_claim();
    [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
    printf("t_pso_archive: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
