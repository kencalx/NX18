// The prebuild with a base Apple's compiler cannot build (GitHub issue #294), stood in for by a compiler that holds one pixel shader's compile, and one that fails another's.
// A compile that does not return holds back only the file of its own flush period (ArchEpoch in nvn_mtl.m). Checks, while it is held: the prebuild hands out every pair (where the
// prepare step stops waiting) and builds the others; a draw's compile goes through; a flush of a later period writes its file. Once released: its period is written, the prebuild
// finishes and stamps, nothing is left to write. A base that fails (pre_fail_load): the stamp is written and prebuild_failed.tsv names it; a later start of this system build
// with that stamp does nothing, and without the stamp it leaves the pair to the draws without compiling it; a list written on another system build makes it try the pair again.
// The prebuild's own files (pb<seq>_<program>, pre_trim): one no pair's base was found in is removed by the next prebuild, one that gave a base stays, a draw's p file stays,
// DM_PSO_PREBUILD_TRIM=0 keeps them all, and an archive bundled with the app that holds every pair's base removes them and prebuilt.tsv. Two programs of one application, each with
// its own pair list, alternating in one folder (arch_pre_mine): neither removes the other's files, and one the bundle covers removes only its own, and the stamp only when it is its own
// The same trim when the prebuild's files have a complete index (<file>.keys, read as pso4_init reads it: reopen_ix), which puts them in g_arch_ixf, not g_arch4p.
// A library file the app does not carry (a pulling library; a shader): the stamp names it, a later start of that app does nothing, one with the file builds the pair; a stamp from
// before this check runs once. The same with the library as one image (shader_lib.py pack), and a file added beside it
#include "../nvn/nvn_mtl.m"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(name, want, ...) do { uint64_t w = (want), g = (__VA_ARGS__); checks++; if (w != g) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w, (unsigned long long)g); failed++; } } while (0)

// Holds the compile whose pixel function is named "hold" until released, and fails the one named "bad" (bad: how many times it was asked)
@interface HoldCompiler : NSObject { @public id<MTL4Compiler> compiler; dispatch_semaphore_t entered, release; _Atomic int bad; } @end
@implementation HoldCompiler
- (id)forwardingTargetForSelector:(SEL)selector { return compiler; }
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4RenderPipelineDescriptor *)d compilerTaskOptions:(MTL4CompilerTaskOptions *)opts error:(NSError **)error {
    MTL4FunctionDescriptor *f = d.fragmentFunctionDescriptor;
    if ([f isKindOfClass:[MTL4LibraryFunctionDescriptor class]] && [((MTL4LibraryFunctionDescriptor *)f).name isEqualToString:@"hold"]) {
        dispatch_semaphore_signal(entered); dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    }
    if ([f isKindOfClass:[MTL4LibraryFunctionDescriptor class]] && [((MTL4LibraryFunctionDescriptor *)f).name isEqualToString:@"bad"]) {
        bad++; if (error) *error = [NSError errorWithDomain:@"test" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Compilation failed\tafter\nmultiple retries"}]; return nil;
    }
    return [compiler newRenderPipelineStateWithDescriptor:d compilerTaskOptions:opts error:error];
}
@end
static int sh(NSString *cmd) { int r = system(cmd.UTF8String); return WIFEXITED(r) ? WEXITSTATUS(r) : -1; }
static void put(NSString *path, NSString *text) { [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]; [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static int lib(NSString *dir, NSString *name, NSString *src) {   // <dir>/<name>.metallib from MSL, with the SDK's compiler
    put([NSString stringWithFormat:@"%@/%@.metal", dir, name], src);
    return sh([NSString stringWithFormat:@"cd %@ && xcrun -sdk macosx metal -c %@.metal -o %@.air && xcrun -sdk macosx metallib %@.air -o %@.metallib && rm %@.metal %@.air", dir, name, name, name, name, name, name]);
}
static NSUInteger files(NSString *dir) { return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.mtl4a'"]].count; }
static void reset_counts(void) { g_pre_done = g_pre_built = g_pre_archived = g_pre_skipped = g_pre_failed = 0; }
static NSString *slurp(NSString *path) { return [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil]; }
static void arm(HoldCompiler *c) {   // the compiler of the prebuild's next period (arch_pre_begin keeps one already open)
    if (!g_ep_pre) g_ep_pre = ep_new(1);
    if (![(id)g_ep_pre->comp isKindOfClass:[HoldCompiler class]]) { c->compiler = g_ep_pre->comp; g_ep_pre->comp = (id<MTL4Compiler>)c; }
}
static void reopen(NSString *dir) {   // the folder's files, as a new start opens them (pso4_init: the prebuild's own noted)
    NSMutableArray<id<MTL4Archive>> *a = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) if ([n hasSuffix:@".mtl4a"]) {
        id<MTL4Archive> archive = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:n]] error:nil];
        if (!archive) abort();
        [a addObject:archive]; if (arch_name_kind(n) == 2) arch_pre_note(archive, [dir stringByAppendingPathComponent:n]);
    }
    g_arch4p = a;
}
static void reopen_ix(NSString *dir) {   // the same with the files' indexes, as pso4_init reads them: a file with a complete index in g_arch_ixf alone, newest first in g_arch_ix
    nvn_hm_clear(&g_arch_ix, NULL);
    NSMutableArray<id<MTL4Archive>> *a = [NSMutableArray array], *ixf = [NSMutableArray array];
    NSArray<NSString *> *names = [[[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self ENDSWITH '.mtl4a'"]]
        sortedArrayUsingComparator:^NSComparisonResult(NSString *x, NSString *y) { int p = [x substringFromIndex:arch_name_kind(x)].intValue, q = [y substringFromIndex:arch_name_kind(y)].intValue; return p > q ? NSOrderedAscending : p < q ? NSOrderedDescending : NSOrderedSame; }];
    for (NSString *n in names) {
        NSString *p = [dir stringByAppendingPathComponent:n];
        id<MTL4Archive> archive = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:p] error:nil];
        if (!archive) abort();
        if (arch_name_kind(n) == 2) arch_pre_note(archive, p);
        int complete = 0; NSData *keys = arch_keys_read(arch_keys_path(p), &complete);
        const uint64_t *kv = keys.bytes; NSUInteger nk = keys.length / sizeof(uint64_t);
        for (NSUInteger j = 0; j < nk; j++) if (!nvn_hm_get(&g_arch_ix, &kv[j])) nvn_hm_put(&g_arch_ix, &kv[j], (__bridge void *)archive);
        [keys && complete ? ixf : a addObject:archive];
    }
    g_arch4p = a; g_arch_ixf = ixf;
}
static NSArray<NSString *> *named(NSString *dir, NSString *prefix) {   // the folder's .mtl4a files whose names start with prefix
    return [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self BEGINSWITH %@ AND self ENDSWITH '.mtl4a'", prefix]];
}
static int until(int (^cond)(void), double seconds) { uint64_t t0 = bp_now(); while (!cond()) { if (bp_now() - t0 > seconds * 1e9) return 0; usleep(10000); } return 1; }

int main(void) { @autoreleasepool {
    char tmp[] = "/tmp/t_pso_stall.XXXXXX"; if (!mkdtemp(tmp)) abort();
    NSString *root = @(tmp), *msl = [root stringByAppendingFormat:@"/msl/b-%s", DMSH_CHAIN], *tables = [root stringByAppendingPathComponent:@"tables"];
    NSString *arch = [root stringByAppendingPathComponent:@"archive"];
    NSString *v = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
        "vertex V main0(uint id [[vertex_id]]) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.p = float4(uv * 2 - 1, 0, 1); return o; }\n";
    NSString *f = @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 %@() { return float4(%d, %d, %d.0 / 65536.0, 1); }\n";
    [NSFileManager.defaultManager createDirectoryAtPath:msl withIntermediateDirectories:YES attributes:nil error:nil];
    int pid = getpid() & 0xffff;
    if (lib(msl, @"v1_bp", v) || lib(msl, @"f1_b", [NSString stringWithFormat:f, @"hold", 1, 0, pid]) || lib(msl, @"f2_b", [NSString stringWithFormat:f, @"main0", 0, 1, pid]) ||
        lib(msl, @"f3_b", [NSString stringWithFormat:f, @"main0", 1, 1, pid]) || lib(msl, @"f4_b", [NSString stringWithFormat:f, @"main0", 0, 0, pid]) ||
        lib(msl, @"f5_b", [NSString stringWithFormat:f, @"bad", 2, 0, pid]) || lib(msl, @"f6_b", [NSString stringWithFormat:f, @"main0", 0, 2, pid])) {
        printf("t_pso_stall: no Metal compiler (xcrun metal), not run\n"); return 0; }
    put([msl stringByAppendingPathComponent:@"v1_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"pull\": {}, \"vertex_inputs\": []}", DMSH_CHAIN]);
    put([msl stringByAppendingPathComponent:@"f1_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"hold\"}", DMSH_CHAIN]);
    put([msl stringByAppendingPathComponent:@"f5_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"bad\"}", DMSH_CHAIN]);
    for (NSString *k in @[@"f2", @"f3", @"f4", @"f6"]) put([msl stringByAppendingFormat:@"/%@_b.json", k], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\"}", DMSH_CHAIN]);
    put([tables stringByAppendingPathComponent:@"shader_map.tsv"], @"# empty\n");
    put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], @"# pairs\nv1\tf1\nv1\tf2\nv1\tf3\n");
    setenv("DM_NVN_SHMAP", [tables stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    setenv("DM_MSL_DIR", [root stringByAppendingPathComponent:@"msl"].UTF8String, 1);
    setenv("DM_PSO_ARCHIVE", arch.UTF8String, 1); setenv("DM_PSO_MANIFEST", "off", 1);
    mtl_init(); pso4_init();
    if (!g_comp4 || !g_arch_cap) { printf("t_pso_stall: no Metal 4 compiler, not run\n"); return 0; }

    g_ep_pre = ep_new(1); ArchEpoch *ep1 = g_ep_pre; HoldCompiler *hold = [HoldCompiler new]; hold->compiler = ep1->comp;   // the prebuild's period
    hold->entered = dispatch_semaphore_create(0); hold->release = dispatch_semaphore_create(0); ep1->comp = (id<MTL4Compiler>)hold;
    EXPECT("three pairs", 3, pso_prebuild(2, 0, QOS_CLASS_USER_INITIATED));
    EXPECT("held: the compile of f1 entered", 0, dispatch_semaphore_wait(hold->entered, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
    EXPECT("held: every pair handed out (the prepare step stops waiting)", 1, until(^{ return (int)(atomic_load(&g_pre_next) >= 3); }, 10));
    EXPECT("held: the other pairs built", 1, until(^{ return (int)(g_pre_done == 2); }, 10));
    EXPECT("held: the prebuild not done", 1, g_pre_running);

    // a flush hands the held period over and returns; a draw's compile, in a period of the draws', goes through, and that period's flush writes its file
    arch_flush();
    EXPECT("held: the flush began a new period", 1, g_ep_pre != ep1);
    MTL4RenderPipelineDescriptor *m = pre_desc(@"v1", @"f4", 0);
    EXPECT("held: a descriptor for the draw", 1, m != nil);
    dispatch_group_t draw = dispatch_group_create(); __block id drawn = nil;
    dispatch_group_async(draw, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool { NSError *e = nil; drawn = arch_capture(m, &e, 0, NULL); } });
    EXPECT("held: a draw's compile returns", 0, dispatch_group_wait(draw, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
    EXPECT("held: a draw's compile built", 1, drawn != nil);
    arch_flush();
    EXPECT("held: the later period's file written", 1, until(^{ return (int)(files(arch) == 1); }, 10));

    // released: the held period is written, the prebuild finishes and stamps
    dispatch_semaphore_signal(hold->release);
    EXPECT("released: the prebuild finished", 1, until(^{ return (int)!g_pre_running; }, 30));
    EXPECT("released: every pair built", 3, g_pre_built);
    EXPECT("released: none failed", 0, g_pre_failed);
    EXPECT("released: the held period's file written", 2, files(arch));
    EXPECT("released: the prebuild's bases in a file of its own, the draw's in a p file", 1, named(arch, @"pb").count == 1 && named(arch, @"p0").count == 1);
    EXPECT("released: the prebuild's period closed", 1, g_ep_pre == nil);
    EXPECT("released: stamped", 1, [NSFileManager.defaultManager fileExistsAtPath:[arch stringByAppendingPathComponent:@"prebuilt.tsv"]]);
    EXPECT("released: nothing left to write", 0, g_arch_new);
    ep1->comp = hold->compiler;

    // every base is in the files
    NSMutableArray<id<MTL4Archive>> *open = [NSMutableArray array];
    for (NSString *n in [NSFileManager.defaultManager contentsOfDirectoryAtPath:arch error:nil]) if ([n hasSuffix:@".mtl4a"]) {
        id<MTL4Archive> archive = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:[arch stringByAppendingPathComponent:n]] error:nil];
        if (!archive) abort();
        [open addObject:archive];
    }
    int found = 0;
    for (NSString *k in @[@"f1", @"f2", @"f3", @"f4"]) @autoreleasepool {
        MTL4RenderPipelineDescriptor *d = pre_desc(@"v1", k, 0);
        for (id<MTL4Archive> a in open) if ([a newRenderPipelineStateWithDescriptor:d error:nil]) { found++; break; }
    }
    EXPECT("every base in the files", 4, found);
    // a base whose period is written and gone still specializes (the draws keep bases for the whole run)
    MTL4RenderPipelineDescriptor *s = spec_desc(drawn, &g_spec_own);
    s.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm; s.colorAttachments[0].writeMask = MTLColorWriteMaskAll; s.colorAttachments[0].blendingState = MTL4BlendStateDisabled;
    NSError *se = nil;
    EXPECT("a base of a written period specializes", 1, [g_comp4 newRenderPipelineStateBySpecializationWithDescriptor:s pipeline:drawn error:&se] != nil);

    // a base that fails: into a fresh archive folder, with new pairs (one fails, one builds)
    NSString *arch2 = [root stringByAppendingPathComponent:@"archive2"], *stamp = [arch2 stringByAppendingPathComponent:@"prebuilt.tsv"], *failp = [arch2 stringByAppendingPathComponent:@"prebuild_failed.tsv"];
    [NSFileManager.defaultManager createDirectoryAtPath:arch2 withIntermediateDirectories:YES attributes:nil error:nil];
    g_arch_dir = arch2; g_arch4 = @[]; g_arch4p = @[];
    put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], @"# pairs\nv1\tf5\nv1\tf6\n");
    HoldCompiler *failc = [HoldCompiler new];   // armed in the current period before each run (one worker: both compiles in it; the run's last flush begins another)
    // Apple's compiler fails it outside the archive too: a base the capture refuses is built by the plain compiler (arch_capture)
    HoldCompiler *plainc = [HoldCompiler new]; id<MTL4Compiler> plain = g_comp4; plainc->compiler = plain; g_comp4 = (id<MTL4Compiler>)plainc;
    arm(failc); reset_counts();
    EXPECT("failing: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("failing: asked once", 1, failc->bad);
    EXPECT("failing: the plain compiler asked too", 1, plainc->bad);
    EXPECT("failing: still capturing", 1, arch_capturing());
    EXPECT("failing: one failed", 1, g_pre_failed);
    EXPECT("failing: one built", 1, g_pre_built);
    EXPECT("failing: stamped all the same", 1, slurp(stamp) != nil);
    NSString *list = slurp(failp);
    EXPECT("failing: the failure list names the pair", 1, [list containsString:@"\nfail\tv1\tf5\tCompilation failed after multiple retries\n"]);
    EXPECT("failing: for this system build", 1, [list containsString:arch_os_build()]);
    // a later start of this system build with that stamp: nothing to do
    reset_counts();
    EXPECT("again: nothing to do", (uint64_t)-1, (uint64_t)(int64_t)pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    // without the stamp: the failed pair is left to the draws, not compiled again
    unlink(stamp.fileSystemRepresentation); reopen(arch2); arm(failc); reset_counts();
    EXPECT("unstamped: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("unstamped: not asked again", 1, failc->bad);
    EXPECT("unstamped: left to the draws", 1, g_pre_skipped);
    EXPECT("unstamped: as one that failed before", 1, g_pre_known_n);
    EXPECT("unstamped: the other from the archive", 1, g_pre_archived);
    EXPECT("unstamped: none failed this time", 0, g_pre_failed);
    EXPECT("unstamped: the list keeps it", 1, [slurp(failp) containsString:@"fail\tv1\tf5\t"]);
    // a list written on another system build: tried again
    put(failp, [slurp(failp) stringByReplacingOccurrencesOfString:arch_os_build() withString:@"os\t1A1\n"]); reopen(arch2); arm(failc); reset_counts();
    EXPECT("other build: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("other build: asked again", 2, failc->bad);
    EXPECT("other build: failed again", 1, g_pre_failed);
    EXPECT("other build: the other from the archive", 1, g_pre_archived);
    EXPECT("other build: the list is for this build now", 1, [slurp(failp) containsString:arch_os_build()]);
    // it builds after a system update (the real compiler, the list from another build): the list goes
    if (g_ep_pre && (id)g_ep_pre->comp == failc) g_ep_pre->comp = failc->compiler;
    g_comp4 = plain;
    put(failp, [slurp(failp) stringByReplacingOccurrencesOfString:arch_os_build() withString:@"os\t1A1\n"]); reopen(arch2); reset_counts();
    EXPECT("fixed: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("fixed: built", 1, g_pre_built);
    EXPECT("fixed: no failure list", 0, [NSFileManager.defaultManager fileExistsAtPath:failp]);

    // the prebuild's files a later prebuild no longer needs, in a fresh folder
    NSString *arch3 = [root stringByAppendingPathComponent:@"archive3"], *stamp3 = [arch3 stringByAppendingPathComponent:@"prebuilt.tsv"], *pairs = [tables stringByAppendingPathComponent:@"shader_pairs.tsv"];
    [NSFileManager.defaultManager createDirectoryAtPath:arch3 withIntermediateDirectories:YES attributes:nil error:nil];
    g_arch_dir = arch3; g_arch4 = @[]; g_arch4p = @[];
    put(pairs, @"v1\tf2\nv1\tf3\n"); reset_counts();
    EXPECT("trim: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    NSArray<NSString *> *first = named(arch3, @"pb");
    EXPECT("trim: the prebuild's file", 1, first.count == 1 && files(arch3) == 1);
    // other pairs, one of them in that file: it stays
    put(pairs, @"v1\tf3\nv1\tf4\n"); reopen(arch3); reset_counts();
    EXPECT("trim, a pair kept: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("trim, a pair kept: one from the file", 1, g_pre_archived);
    EXPECT("trim, a pair kept: the file stays", 1, first.count && [NSFileManager.defaultManager fileExistsAtPath:[arch3 stringByAppendingPathComponent:first[0]]]);
    EXPECT("trim, a pair kept: a second file", 2, named(arch3, @"pb").count);
    // a draw's base without a vertex layout, in a p file of its own
    MTL4RenderPipelineDescriptor *dm = pre_desc(@"v1", @"f6", 0); NSError *de = nil;
    EXPECT("trim: a draw's base", 1, dm && arch_capture(dm, &de, 0, NULL) != nil);
    arch_flush_wait();
    NSArray<NSString *> *drawn3 = named(arch3, @"p0");
    EXPECT("trim: the draw's p file", 1, drawn3.count);
    // pairs none of the first file holds: it goes, the second file and the draw's stay, then the stamp
    put(pairs, @"v1\tf4\n"); reopen(arch3); reset_counts();
    EXPECT("trim: one pair", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("trim: from the second file", 1, g_pre_archived);
    EXPECT("trim: the first file removed", 0, first.count && [NSFileManager.defaultManager fileExistsAtPath:[arch3 stringByAppendingPathComponent:first[0]]]);
    EXPECT("trim: the second file stays", 1, named(arch3, @"pb").count);
    EXPECT("trim: the draw's p file stays", 1, drawn3.count && [NSFileManager.defaultManager fileExistsAtPath:[arch3 stringByAppendingPathComponent:drawn3[0]]]);
    EXPECT("trim: stamped", 1, [slurp(stamp3) hasPrefix:pre_stamp(slurp(pairs), 0)]);
    // DM_PSO_PREBUILD_TRIM=0: a file no base was found in stays
    put(pairs, @"v1\tf2\n"); reopen(arch3); reset_counts(); setenv("DM_PSO_PREBUILD_TRIM", "0", 1);
    EXPECT("no trim: one pair", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("no trim: built", 1, g_pre_built);
    EXPECT("no trim: every file stays", 2, named(arch3, @"pb").count);
    unsetenv("DM_PSO_PREBUILD_TRIM");
    // an archive bundled with the app that holds every pair's base and leaves none to the device: the prebuild's files go, and prebuilt.tsv with them; the draw's p file stays
    NSString *bundle = [root stringByAppendingPathComponent:@"bundle"], *gpu = g_dev.architecture.name ?: @"gpu";
    [NSFileManager.defaultManager createDirectoryAtPath:bundle withIntermediateDirectories:YES attributes:nil error:nil];
    NSArray<NSString *> *pre3 = named(arch3, @"pb"); id<MTL4Archive> holds = nil;
    for (NSString *n in pre3) @autoreleasepool {
        id<MTL4Archive> a = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:[arch3 stringByAppendingPathComponent:n]] error:nil];
        if (a && [a newRenderPipelineStateWithDescriptor:pre_desc(@"v1", @"f2", 0) error:nil]) {
            NSString *copy = [bundle stringByAppendingFormat:@"/%@.mtl4a", gpu];
            [NSFileManager.defaultManager copyItemAtPath:[arch3 stringByAppendingPathComponent:n] toPath:copy error:nil];
            holds = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:copy] error:nil];
        }
    }
    EXPECT("covered: a bundle that holds the pair", 1, holds != nil);
    put([bundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(slurp(pairs), 0));
    reopen(arch3); g_arch_bundle = holds; g_bundle_dir = bundle; reset_counts();
    EXPECT("covered: nothing to build", (uint64_t)-1, (uint64_t)(int64_t)pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("covered: the prebuild's files removed", 0, named(arch3, @"pb").count);
    EXPECT("covered: prebuilt.tsv removed", 0, [NSFileManager.defaultManager fileExistsAtPath:stamp3]);
    EXPECT("covered: the draw's p file stays", 1, drawn3.count && [NSFileManager.defaultManager fileExistsAtPath:[arch3 stringByAppendingPathComponent:drawn3[0]]]);
    g_arch_bundle = nil; g_bundle_dir = nil;
    // two programs of one application (Super Mario 3D All-Stars), each with a pair list of its own, alternating in one folder: neither's prebuild removes the other's file
    NSString *arch4 = [root stringByAppendingPathComponent:@"archive4"], *stamp4 = [arch4 stringByAppendingPathComponent:@"prebuilt.tsv"];
    [NSFileManager.defaultManager createDirectoryAtPath:arch4 withIntermediateDirectories:YES attributes:nil error:nil];
    g_arch_dir = arch4; g_arch4 = @[]; g_arch4p = @[];
    BOOL (^there)(NSString *) = ^BOOL(NSString *n) { return n && [NSFileManager.defaultManager fileExistsAtPath:[arch4 stringByAppendingPathComponent:n]]; };
    g_pre_program = 0x010049900F546001ull; put(pairs, @"v1\tf2\n"); reset_counts();
    EXPECT("programs: the first program's pair", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    NSArray<NSString *> *pa = named(arch4, @"pb"); NSString *fa = pa.firstObject;
    EXPECT("programs: the first program's file, named for it", 1, pa.count == 1 && [fa hasSuffix:@"_010049900F546001.mtl4a"]);
    g_pre_program = 0x010049900F546002ull; put(pairs, @"v1\tf3\n"); reopen(arch4); reset_counts();
    EXPECT("programs: the second program's pair", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("programs: built, the first program's file holds none of its pairs", 1, g_pre_built);
    EXPECT("programs: the first program's file stays", 1, there(fa));
    NSString *fb = nil; for (NSString *n in named(arch4, @"pb")) if (![n isEqualToString:fa]) fb = n;
    EXPECT("programs: the second program's file", 1, [fb hasSuffix:@"_010049900F546002.mtl4a"]);
    g_pre_program = 0x010049900F546001ull; put(pairs, @"v1\tf2\n"); reopen(arch4); reset_counts();
    EXPECT("programs, back: one pair", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("programs, back: from its own file", 1, g_pre_archived);
    EXPECT("programs, back: nothing built", 0, g_pre_built);
    EXPECT("programs, back: both files stay", 1, there(fa) && there(fb) && named(arch4, @"pb").count == 2);
    // the second program again, so that the folder's stamp is its own; then the first, which the bundle covers: its file goes, the second's file and stamp stay
    g_pre_program = 0x010049900F546002ull; put(pairs, @"v1\tf3\n"); reopen(arch4); reset_counts();
    EXPECT("programs, second again: from its own file", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED) == 1 && g_pre_archived == 1 && there(fa) && there(fb));
    g_pre_program = 0x010049900F546001ull; put(pairs, @"v1\tf2\n"); reopen(arch4); g_arch_bundle = holds; g_bundle_dir = bundle; reset_counts();
    EXPECT("programs, covered: nothing to build", (uint64_t)-1, (uint64_t)(int64_t)pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("programs, covered: its own file removed", 0, there(fa));
    EXPECT("programs, covered: the other program's file stays", 1, there(fb));
    EXPECT("programs, covered: the other program's stamp stays", 1, [slurp(stamp4) hasPrefix:pre_stamp(@"v1\tf3\n", 0)]);
    g_arch_bundle = nil; g_bundle_dir = nil; g_pre_program = 0;
    // the same with an index: each pb file the prebuild writes has a complete <file>.keys, and a start puts such a file in g_arch_ixf alone (pso4_init). A pair's base the index
    // names a file for is credited to that file, so a file that gave one stays and one that gave none goes, with its .keys
    NSString *arch7 = [root stringByAppendingPathComponent:@"archive7"];
    [NSFileManager.defaultManager createDirectoryAtPath:arch7 withIntermediateDirectories:YES attributes:nil error:nil];
    g_arch_dir = arch7; g_arch4 = @[]; g_arch4p = @[]; g_arch_ixf = @[];
    put(pairs, @"v1\tf2\nv1\tf3\n"); reset_counts();
    EXPECT("indexed: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    NSArray<NSString *> *ifirst = named(arch7, @"pb"); NSString *ia = ifirst.firstObject;
    EXPECT("indexed: the prebuild's file", 1, ifirst.count == 1);
    int icomplete = 0; NSData *ikeys = ia ? arch_keys_read(arch_keys_path([arch7 stringByAppendingPathComponent:ia]), &icomplete) : nil;
    EXPECT("indexed: its index names both bases", 2, ikeys.length / sizeof(uint64_t));
    EXPECT("indexed: its index is complete", 1, icomplete);
    put(pairs, @"v1\tf3\nv1\tf4\n"); reopen_ix(arch7); reset_counts();
    EXPECT("indexed: the file only through the index", 1, g_arch_ixf.count == 1 && g_arch4p.count == 0 && g_arch_ix.n == 2);
    EXPECT("indexed, a pair kept: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("indexed, a pair kept: one from the file", 1, g_pre_archived);
    EXPECT("indexed, a pair kept: one built", 1, g_pre_built);
    EXPECT("indexed, a pair kept: the file stays", 1, ia && [NSFileManager.defaultManager fileExistsAtPath:[arch7 stringByAppendingPathComponent:ia]]);
    EXPECT("indexed, a pair kept: a second file", 2, named(arch7, @"pb").count);
    put(pairs, @"v1\tf4\n"); reopen_ix(arch7); reset_counts();
    EXPECT("indexed trim: one pair", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("indexed trim: from the second file", 1, g_pre_archived);
    EXPECT("indexed trim: nothing built", 0, g_pre_built);
    EXPECT("indexed trim: the first file removed", 0, ia && [NSFileManager.defaultManager fileExistsAtPath:[arch7 stringByAppendingPathComponent:ia]]);
    EXPECT("indexed trim: its index removed", 0, ia && [NSFileManager.defaultManager fileExistsAtPath:arch_keys_path([arch7 stringByAppendingPathComponent:ia])]);
    EXPECT("indexed trim: the second file stays", 1, named(arch7, @"pb").count);
    // a bundle that covers the pair: the indexed file goes too, with its .keys and the stamp (which ends with the libs line)
    NSString *ib = named(arch7, @"pb").firstObject, *ibundle = [root stringByAppendingPathComponent:@"bundle7"];
    [NSFileManager.defaultManager createDirectoryAtPath:ibundle withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *icopy = [ibundle stringByAppendingFormat:@"/%@.mtl4a", gpu];
    [NSFileManager.defaultManager copyItemAtPath:[arch7 stringByAppendingPathComponent:ib] toPath:icopy error:nil];
    put([ibundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(slurp(pairs), 0));
    EXPECT("indexed covered: the device's stamp has the libs line", 1, [slurp([arch7 stringByAppendingPathComponent:@"prebuilt.tsv"]) hasSuffix:@"libs\tall\n"]);
    reopen_ix(arch7); g_arch_bundle = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:icopy] error:nil]; g_bundle_dir = ibundle; reset_counts();
    EXPECT("indexed covered: nothing to build", (uint64_t)-1, (uint64_t)(int64_t)pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("indexed covered: the prebuild's file removed", 0, named(arch7, @"pb").count);
    EXPECT("indexed covered: its index removed", 0, [NSFileManager.defaultManager fileExistsAtPath:arch_keys_path([arch7 stringByAppendingPathComponent:ib])]);
    EXPECT("indexed covered: prebuilt.tsv removed", 0, [NSFileManager.defaultManager fileExistsAtPath:[arch7 stringByAppendingPathComponent:@"prebuilt.tsv"]]);
    g_arch_bundle = nil; g_bundle_dir = nil; nvn_hm_clear(&g_arch_ix, NULL); g_arch_ixf = nil;

    // the other blocks' state: no files open, the first pair list
    g_arch4 = @[]; g_arch4p = @[]; reset_counts(); g_pre_nolib = 0; g_pre_nolib_file = nil;
    // a pulling library the app does not carry (last: its image block packs the library folder away) (an IPA packed without _bp.metallib, then DM_PSO_MTL4=1): into a fresh archive folder
    NSString *arch5 = [root stringByAppendingPathComponent:@"archive5"], *stamp5 = [arch5 stringByAppendingPathComponent:@"prebuilt.tsv"];
    [NSFileManager.defaultManager createDirectoryAtPath:arch5 withIntermediateDirectories:YES attributes:nil error:nil];
    g_arch_dir = arch5; g_arch4 = @[]; g_arch4p = @[];
    put([msl stringByAppendingPathComponent:@"v2_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"pull\": {}, \"vertex_inputs\": []}", DMSH_CHAIN]);
    NSString *pairs3 = @"# pairs\nv2\tf6\nv1\tf4\n"; put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], pairs3);
    reset_counts();
    EXPECT("no library: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("no library: left to the draws", 1, g_pre_skipped);
    EXPECT("no library: counted", 1, g_pre_nolib);
    EXPECT("no library: the other built", 1, g_pre_built);
    EXPECT("no library: the stamp names it", 1, [slurp(stamp5) hasSuffix:@"libs\tmissing\tv2_bp.metallib\n"]);
    reset_counts();
    EXPECT("no library, same app: nothing to do", (uint64_t)-1, (uint64_t)(int64_t)pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    // the app comes back with the library: the pair is built, the other taken from the archive, and the stamp says all
    EXPECT("library installed", 0, lib(msl, @"v2_bp", v));
    reopen(arch5); reset_counts();
    EXPECT("library back: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("library back: built", 1, g_pre_built);
    EXPECT("library back: the other from the archive", 1, g_pre_archived);
    EXPECT("library back: none counted", 0, g_pre_nolib);
    EXPECT("library back: the stamp says all", 1, [slurp(stamp5) hasSuffix:@"libs\tall\n"]);
    reset_counts();
    EXPECT("library back: nothing to do", (uint64_t)-1, (uint64_t)(int64_t)pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    // a stamp from before this check (no libs line) may hide such pairs: one more run, everything from the archive
    put(stamp5, pre_stamp(pairs3, 0)); reopen(arch5); reset_counts();
    EXPECT("old stamp: two pairs", 2, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("old stamp: nothing compiled", 0, g_pre_built);
    EXPECT("old stamp: both from the archive", 2, g_pre_archived);
    EXPECT("old stamp: the stamp says all", 1, [slurp(stamp5) hasSuffix:@"libs\tall\n"]);
    // the library as one image beside its folder, as the Mac app and the IPA carry it (dm/tools/shader_lib.py pack, msl_image.h): its files are found there, and a pixel shader
    // the library lacks is named by its file
    NSString *packer = [[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../../tools/shader_lib.py"];
    EXPECT("image: packed", 0, sh([NSString stringWithFormat:@"python3 %@ pack %@ > /dev/null", packer, msl]));
    EXPECT("image: no folder", 0, [NSFileManager.defaultManager fileExistsAtPath:msl]);
    NSString *arch6d = [root stringByAppendingPathComponent:@"archive6"], *stamp6 = [arch6d stringByAppendingPathComponent:@"prebuilt.tsv"];
    [NSFileManager.defaultManager createDirectoryAtPath:arch6d withIntermediateDirectories:YES attributes:nil error:nil];
    g_arch_dir = arch6d; g_arch4 = @[]; g_arch4p = @[];
    put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], @"# pairs\nv2\tf6\nv1\tf4\nv1\tf9\n");
    reset_counts();
    EXPECT("image: three pairs", 3, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("image: both built from it", 2, g_pre_built);
    EXPECT("image: the absent shader counted", 1, g_pre_nolib);
    EXPECT("image: the stamp names its file", 1, [slurp(stamp6) hasSuffix:@"libs\tmissing\tf9_b.json\n"]);
    reset_counts();
    EXPECT("image, same app: nothing to do", (uint64_t)-1, (uint64_t)(int64_t)pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    // a partial build makes that shader in a folder beside the image: its pair is built, the others taken from the archive
    put([msl stringByAppendingPathComponent:@"f9_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\"}", DMSH_CHAIN]);
    EXPECT("image: shader added", 0, lib(msl, @"f9_b", [NSString stringWithFormat:f, @"main0", 2, 2, pid]));
    reopen(arch6d); reset_counts();
    EXPECT("image + folder: three pairs", 3, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("image + folder: built", 1, g_pre_built);
    EXPECT("image + folder: the others from the archive", 2, g_pre_archived);
    EXPECT("image + folder: none counted", 0, g_pre_nolib);
    EXPECT("image + folder: the stamp says all", 1, [slurp(stamp6) hasSuffix:@"libs\tall\n"]);
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    printf("t_pso_stall: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}}
