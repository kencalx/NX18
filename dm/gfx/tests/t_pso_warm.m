// Exercise real manifest loading, shader loading, pipeline builds, cache claims and GPU draws.
// Synthetic shaders need no game files; old rows differ in unused state, while live changes and logical target 7 in a merged pass must remain distinct.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

static int checks, failed;
#define EXPECT(name, want, got) do { uint64_t w_ = (want), g_ = (got); checks++; \
    if (w_ != g_) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w_, (unsigned long long)g_); failed++; } } while (0)

static int fixtures(NSString *dir) {
    NSString *source = @"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 vs(uint id [[vertex_id]]) { float2 uv = float2((id << 1) & 2, id & 2); return float4(uv * 2 - 1, 0, 1); }\n"
        "fragment float4 fs() { return float4(0.5, 0.25, 1, 0.5); }\n"
        "struct MeshVertex { float4 position [[position]]; };\n"
        "using Triangle = mesh<MeshVertex, void, 3, 1, topology::triangle>;\n"
        // a mesh shader with no task has an object function of its own that launches its blocks (dmsh_meshstage.py main0_o)
        "struct Block { uint first; };\n"
        "[[object]] void ms_o(object_data Block &b [[payload]], mesh_grid_properties g) { b.first = 0; g.set_threadgroups_per_grid(uint3(1, 1, 1)); }\n"
        "[[mesh]] void ms(Triangle out, const object_data Block &b [[payload]]) {\n"
        "  out.set_primitive_count(1);\n"
        "  out.set_vertex(0, MeshVertex{float4(-1, -1, 0.5, 1)}); out.set_index(0, 0);\n"
        "  out.set_vertex(1, MeshVertex{float4( 3, -1, 0.5, 1)}); out.set_index(1, 1);\n"
        "  out.set_vertex(2, MeshVertex{float4(-1,  3, 0.5, 1)}); out.set_index(2, 2);\n"
        "}\n"
        "[[mesh]] void ms_z(Triangle out, const object_data Block &b [[payload]]) { out.set_primitive_count(0); }\n";
    NSString *metal = [dir stringByAppendingPathComponent:@"fixture.metal"];
    NSString *library = [dir stringByAppendingPathComponent:@"warm-vs.metallib"];
    if (![source writeToFile:metal atomically:YES encoding:NSUTF8StringEncoding error:nil]) return 0;
    NSTask *compiler = [NSTask new]; compiler.executableURL = [NSURL fileURLWithPath:@"/usr/bin/xcrun"];
    compiler.arguments = @[@"-sdk", @"macosx", @"metal", metal, @"-o", library];
    NSError *error = nil;
    if (![compiler launchAndReturnError:&error]) { fprintf(stderr, "fixture compiler: %s\n", error.localizedDescription.UTF8String); return 0; }
    [compiler waitUntilExit]; if (compiler.terminationStatus) return 0;
    if (![NSFileManager.defaultManager copyItemAtPath:library toPath:[dir stringByAppendingPathComponent:@"warm-fs.metallib"] error:nil]) return 0;
    if (![NSFileManager.defaultManager copyItemAtPath:library toPath:[dir stringByAppendingPathComponent:@"warm-ms.metallib"] error:nil]) return 0;
    for (NSString *stage in @[@"vs", @"fs", @"ms"]) {
        NSMutableDictionary *reflection = [@{@"chain": @DMSH_CHAIN, @"route": @"B", @"entry": stage, @"entry_z": stage, @"bindings": @[], @"vertex_inputs": @[]} mutableCopy];
        if ([stage isEqualToString:@"ms"]) { reflection[@"mesh_stage"] = @{@"kind": @"ms", @"threads": @1}; reflection[@"entry_z"] = @"ms_z"; reflection[@"entry_object"] = @"ms_o"; }
        NSData *json = [NSJSONSerialization dataWithJSONObject:reflection options:0 error:nil];
        if (![json writeToFile:[dir stringByAppendingPathComponent:[NSString stringWithFormat:@"warm-%@.json", stage]] atomically:YES]) return 0;
    }
    g_msl_dir = dir; g_shmap = @{@"warm-vs": @"vertex", @"warm-fs": @"pixel", @"warm-ms": @"mesh"}.mutableCopy;
    return 1;
}

// Hold the real first library load, not a replacement shader loader. The S and R tasks below
// then reach warm_shader concurrently, while a different shader must still load successfully.
@interface WarmGateDevice : NSObject {
@public id<MTLDevice> device; dispatch_semaphore_t entered, release; _Atomic unsigned library_calls;
}
@end
@implementation WarmGateDevice
- (id)forwardingTargetForSelector:(SEL)selector { return device; }
- (id<MTLLibrary>)newLibraryWithData:(dispatch_data_t)data error:(NSError **)error {
    if (!atomic_fetch_add(&library_calls, 1)) {
        dispatch_semaphore_signal(entered);
        dispatch_semaphore_wait(release, DISPATCH_TIME_FOREVER);
    }
    return [device newLibraryWithData:data error:error];
}
@end

// Observe the second caller's lookup under the production dictionary lock. Even if the test
// releases the device gate immediately, the owner cannot publish until this caller unlocks.
@interface WarmLookupDictionary : NSObject {
@public NSMutableDictionary *dictionary; dispatch_semaphore_t second_lookup; unsigned lookups;
}
@end
@implementation WarmLookupDictionary
- (id)forwardingTargetForSelector:(SEL)selector { return dictionary; }
- (id)objectForKeyedSubscript:(id)key {
    if ([key isEqual:@"warm-vs"] && ++lookups == 2) dispatch_semaphore_signal(second_lookup);
    return dictionary[key];
}
@end

static NSString *row(const pso_key *key, int merged) {
    NvShader *vs = [NvShader new], *fs = [NvShader new];
    strcpy(vs->key, "warm-vs"); strcpy(fs->key, "warm-fs"); fs->stage = 1;
    pso_skey sk; char hex[sizeof sk * 2 + 1];
    pso_skey_from(key, vs, fs, merged, NULL, &sk); pso_skey_hex(&sk, hex);
    return [NSString stringWithFormat:@"R\t%s\n", hex];
}

static void pixels(id<MTLRenderPipelineState> pipeline, int mesh, uint8_t out[4]) {
    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:4 height:4 mipmapped:NO];
    td.usage = MTLTextureUsageRenderTarget; td.storageMode = MTLStorageModeShared;
    id<MTLTexture> target = [g_dev newTextureWithDescriptor:td];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor new]; pass.colorAttachments[0].texture = target;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear; pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    T4 *cb = t4_begin();
    id<MTL4RenderCommandEncoder> enc = t4_pass(cb, pass);
    [enc setRenderPipelineState:t4_keep(cb, pipeline)];
    if (mesh) {
        MTLSize one = MTLSizeMake(1, 1, 1);
        [enc drawMeshThreadgroups:one threadsPerObjectThreadgroup:one threadsPerMeshThreadgroup:one];
    } else [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
    t4_end(cb, enc);
    t4_wait(cb);
    EXPECT("GPU draw completed", MTLCommandBufferStatusCompleted, cb->status);
    [target getBytes:out bytesPerRow:16 fromRegion:MTLRegionMake2D(1, 1, 1, 1) mipmapLevel:0];
}

static void check_draw(const pso_key *raw, int merged, const uint8_t expected[4]) {
    NvShader *vs = g_shcache[@"warm-vs"], *fs = g_shcache[@"warm-fs"];
    if (!vs || !fs) { EXPECT("warmed shaders claimed", 1, 0); return; }
    state_reset(); S.color.blend_en = raw->blend_en; S.chmask.mask = raw->chmask; S.ms.a2c = raw->a2c;
    memcpy(S.blend, raw->blend, sizeof S.blend);
    memcpy(g_pass.cfmt, raw->cfmt, sizeof g_pass.cfmt); g_pass.dfmt = raw->dfmt; g_pass.sfmt = raw->sfmt; g_pass.samples = raw->samples;
    g_pso_lmap = merged ? raw->lmap : NULL;
    pso_key live; pso_key_fill(&live, vs, fs, raw->cfmt, raw->dfmt, raw->sfmt, raw->samples, merged);
    if (merged) memcpy(live.lmap, raw->lmap, sizeof live.lmap);
    EXPECT("live key finds warmed pipeline", 1, hm_get_id(&g_pso, &live) != nil);
    uint64_t before = g_pb_spec + g_pb_built;
    NvProg *program = [NvProg new]; program->sh[0] = vs; program->sh[1] = fs;
    id<MTLRenderPipelineState> warmed = pso_get_(program);
    EXPECT("draw lookup adds no pipeline build", before, g_pb_spec + g_pb_built);
    EXPECT("draw lookup returns a pipeline", 1, warmed != nil);
    if (!warmed) { g_pso_lmap = NULL; return; }
    // Build the descriptor from the unnormalized historical state as a rendering oracle.
    pso_key original = *raw; original.vs = (__bridge void *)vs; original.fs = (__bridge void *)fs;
    NSError *error = nil; id<MTLRenderPipelineState> reference = pso_build(pso_desc(&original, vs, fs, nil, merged), 0, &error);
    EXPECT("original descriptor builds", 1, reference != nil);
    if (reference) {
        uint8_t a[4], b[4]; pixels(warmed, 0, a); pixels(reference, 0, b);
        EXPECT("normalization preserves rendered pixels", 1, memcmp(a, b, sizeof a) == 0);
        int correct = 1; for (int i = 0; i < 4; i++) correct &= abs((int)a[i] - expected[i]) <= 1;
        EXPECT("pixels have the intended blend and channel mask", 1, correct);
    }
    g_pso_lmap = NULL;
}

static void singleflight(NSString *dir) {
    warm_load_begin(); g_warm_items = [NSMutableArray array]; atomic_store(&g_warm_ready, 0);
    WarmLookupDictionary *lookup = [WarmLookupDictionary new]; lookup->dictionary = g_warm_dict;
    lookup->second_lookup = dispatch_semaphore_create(0); g_warm_dict = (NSMutableDictionary *)lookup;
    for (NSString *extension in @[@"json", @"metallib"]) {
        NSString *source = [dir stringByAppendingPathComponent:[@"warm-fs." stringByAppendingString:extension]];
        NSString *target = [dir stringByAppendingPathComponent:[@"warm-other." stringByAppendingString:extension]];
        if (![NSFileManager.defaultManager fileExistsAtPath:target])
            EXPECT("unrelated fixture copied", 1, [NSFileManager.defaultManager copyItemAtPath:source toPath:target error:nil]);
    }
    pso_key key = {0}; key.cfmt[0] = MTLPixelFormatRGBA8Unorm; key.samples = 1; key.chmask = 15;
    NSString *manifest = [dir stringByAppendingPathComponent:@"concurrent.tsv"];
    NSString *text = [@"S\twarm-vs\t0\n" stringByAppendingString:row(&key, 0)];
    EXPECT("concurrent manifest written", 1, [text writeToFile:manifest atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    long lines = 0; NSArray<WarmTask *> *tasks = warm_parse(@[manifest], &lines);
    EXPECT("S and R are distinct real warm tasks", 2, tasks.count);
    if (tasks.count != 2) return;
    pso4_init();   // Match warm_start: initialize the real compiler before substituting the test device.
    WarmGateDevice *gate = [WarmGateDevice new]; gate->device = g_dev;
    gate->entered = dispatch_semaphore_create(0); gate->release = dispatch_semaphore_create(0);
    g_dev = (id<MTLDevice>)gate;
    dispatch_group_t callers = dispatch_group_create();
    dispatch_group_async(callers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ warm_task(tasks[0]); });
    EXPECT("first real shader load reaches device gate", 0, dispatch_semaphore_wait(gate->entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    dispatch_group_async(callers, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ warm_task(tasks[1]); });
    EXPECT("R task reaches S task's key while its load is held", 0, dispatch_semaphore_wait(lookup->second_lookup, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    // A dedicated worker avoids a failed assertion hanging the test behind the very global load lock it is meant to catch.
    dispatch_group_t unrelated = dispatch_group_create();
    __block NvShader *other = nil;
    dispatch_group_async(unrelated, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ @autoreleasepool { other = warm_shader(@"warm-other", 1); } });
    EXPECT("unrelated shader finishes before owner is released", 0, dispatch_group_wait(unrelated, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    dispatch_semaphore_signal(gate->release);
    dispatch_group_wait(callers, DISPATCH_TIME_FOREVER); dispatch_group_wait(unrelated, DISPATCH_TIME_FOREVER);
    EXPECT("unrelated shader loaded", 1, other != nil);
    EXPECT("actual library loads", 3, atomic_load(&gate->library_calls));
    NvShader *published = warm_shader(@"warm-vs", 0);
    unsigned references = 0;
    for (WarmItem *item in g_warm_items) {
        if (item->kind == 0) { EXPECT("S task retains the published shader", 1, item->shader == published); references++; }
        if (item->kind == 1) { EXPECT("R task retains the published shader", 1, item->vs == published); references++; }
    }
    EXPECT("both real callers returned the same shader", 2, references);
    EXPECT("cached lookup returns the published shader", 1, warm_shader(@"warm-vs", 0) == published);
    EXPECT("cached lookups perform no library loads", 3, atomic_load(&gate->library_calls));
    g_dev = gate->device;
    warm_claim();
    NvShader *vs = g_shcache[@"warm-vs"];
    EXPECT("S and R publish one shader identity", 1, vs == published);
    // Missing geometry reflection returns nil quietly. Warm callers share its negative result;
    // a later demand caller still retries, and succeeds once real reflection appears.
    EXPECT("failed warm load", 1, warm_shader(@"retry-gs", 2) == nil);
    NSDictionary *reflection = @{@"chain": @DMSH_CHAIN, @"gs_slice": @{@"loc": @0, @"comp": @"x"}};
    NSString *path = [dir stringByAppendingPathComponent:@"retry-gs.json"];
    EXPECT("retry reflection written", 1, [[NSJSONSerialization dataWithJSONObject:reflection options:0 error:nil] writeToFile:path atomically:YES]);
    EXPECT("failure stays cached for this warm phase", 1, warm_shader(@"retry-gs", 2) == nil);
    EXPECT("demand loading still retries failed warm key", 1, shader_get(@"retry-gs", 2) != nil);
    EXPECT("retry fixture removed", 1, [NSFileManager.defaultManager removeItemAtPath:path error:nil]);
    g_warm_t0 = bp_now(); warm_finish();
    g_shcache = nil; nvn_hm_clear(&g_pso, hm_rel);
}

static void scenario(NSString *dir, int merged) {
    nvn_hm_clear(&g_pso, hm_rel); g_shcache = nil; g_warm_items = [NSMutableArray array];
    warm_load_begin();
    g_warm_rps = g_warm_claim_rps = 0; atomic_store(&g_warm_ready, 0);
    pso_key keys[4] = {0}; keys[0].cfmt[0] = MTLPixelFormatRGBA8Unorm; keys[0].samples = 1;
    int logical = merged ? 7 : 0;
    keys[0].chmask = 0xfu << (4 * logical);
    blend_st enabled = {.src_rgb = NVN_BLEND_FUNC_SRC_ALPHA, .dst_rgb = NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA,
        .src_a = NVN_BLEND_FUNC_SRC_ALPHA, .dst_a = NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA, .eq_rgb = NVN_BLEND_EQUATION_ADD, .eq_a = NVN_BLEND_EQUATION_ADD};
    if (merged) { memset(keys[0].lmap, 0xff, sizeof keys[0].lmap); keys[0].lmap[0] = 7; keys[0].blend_en = 1u << 7; keys[0].blend[7] = enabled; }
    keys[1] = keys[0];
    // Neither row matches byte-for-byte, but both describe the same pipeline.
    if (merged) keys[1].blend[1].src_rgb = NVN_BLEND_FUNC_DST_ALPHA;
    else { keys[1].blend_en = 1u << 7; keys[1].chmask |= 0xfu << 28; }   // old pso_key_fill copied no blend factors for absent targets
    keys[2] = keys[0]; keys[2].chmask = 2u << (4 * logical);   // a real write-mask difference
    keys[3] = keys[0]; keys[3].blend_en ^= 1u << logical;   // a real blend-enable difference
    if (!merged) keys[3].blend[0] = enabled;
    NSString *a = [dir stringByAppendingPathComponent:@"seed.tsv"], *b = [dir stringByAppendingPathComponent:@"user.tsv"];
    NSString *r0 = row(&keys[0], merged), *r1 = row(&keys[1], merged);
    EXPECT("historical rows differ before loading", 0, [r0 isEqual:r1]);
    NSString *seed = [r0 stringByAppendingString:r1];
    // The second list repeats both old rows, then changes two pieces of effective state.
    NSString *user = [NSString stringWithFormat:@"%@%@%@%@", r1, r0, row(&keys[2], merged), row(&keys[3], merged)];
    EXPECT("seed manifest written", 1, [seed writeToFile:a atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    EXPECT("user manifest written", 1, [user writeToFile:b atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    uint64_t before = g_pb_spec; g_warm_t0 = bp_now(); atomic_store(&g_warm_running, 1);
    long lines = 0; for (WarmTask *t in warm_parse(@[a, b], &lines)) warm_task(t);
    warm_finish();
    EXPECT("only three effective pipelines compiled across both manifests", 3, g_pb_spec - before);
    EXPECT("only three render pipelines enqueued", 3, g_warm_rps);
    warm_claim();
    EXPECT("three warmed pipelines claimed into cache", 3, g_warm_claim_rps);
    EXPECT("cache has exactly three effective keys", 3, g_pso.n);
    const uint8_t plain[4] = {128, 64, 255, 128}, green[4] = {255, 64, 0, 255};
    const uint8_t blended[4] = {191, 32, 128, 191}, blended_green[4] = {255, 32, 0, 255};
    check_draw(&keys[0], merged, merged ? blended : plain);
    check_draw(&keys[1], merged, merged ? blended : plain);
    check_draw(&keys[2], merged, merged ? blended_green : green);
    check_draw(&keys[3], merged, merged ? plain : blended);
    printf("%s manifests: six rows -> %llu builds, %u cache keys\n", merged ? "merged" : "normal", (unsigned long long)g_warm_rps, g_pso.n);
}

static void native_mesh(NSString *dir) {
    state_reset();
    int old_depth = atomic_exchange(&g_depth_zero, 0);
    S.chmask.mask = 15;
    memset(g_pass.cfmt, 0, sizeof g_pass.cfmt);
    g_pass.cfmt[0] = MTLPixelFormatRGBA8Unorm; g_pass.dfmt = g_pass.sfmt = 0; g_pass.samples = 1;
    NvShader *live = shader_load(@"warm-ms", 4, 0), *fragment = shader_load(@"warm-fs", 1, 0);
    EXPECT("native mesh fixture loaded", 1, live != nil && fragment != nil);
    if (!live || !fragment) return;

    pso_key state;
    pso_key_fill(&state, live, fragment, g_pass.cfmt, 0, 0, 1, 0);
    pso_skey key; char hex[sizeof key * 2 + 1];
    pso_skey_from(&state, live, fragment, 0, NULL, &key); pso_skey_hex(&key, hex);
    NSString *valid = [NSString stringWithFormat:@"M\t-\t%s\n", hex];
    NSString *wrong_stage = [NSString stringWithFormat:@"M\twarm-fs\t%s\n", hex];
    key.vs_stage = 7; pso_skey_hex(&key, hex);
    NSString *raw = [NSString stringWithFormat:@"M\t-\t%s\n", hex];
    NSString *manifest = [dir stringByAppendingPathComponent:@"mesh.tsv"];
    NSString *text = [NSString stringWithFormat:@"S\twarm-ms\t7\nS\twarm-ms\t4\n%@%@%@%@", wrong_stage, raw, valid, valid];
    EXPECT("mesh manifest written", 1, [text writeToFile:manifest atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    long lines = 0; NSArray<WarmTask *> *tasks = warm_parse(@[manifest], &lines);
    EXPECT("one mesh library and one mesh pipeline after normalizing stage aliases", 2, lines);
    if (tasks.count != 2) return;
    warm_load_begin(); warm_task(tasks[0]); warm_task(tasks[1]);
    EXPECT("mesh warm tasks publish the library and the pipeline", 2, g_warm_items.count);
    if (g_warm_items.count != 2) return;
    WarmItem *item = g_warm_items[1];

    // A live shader loaded while prewarm was in flight has a different object identity.
    g_shcache = @{@"warm-ms": live, @"warm-fs": fragment}.mutableCopy;
    warm_claim();
    EXPECT("duplicate live shader objects claim the warm pipeline", 1, g_pso_mtk.n);
    g_mtk.ms = live;
    NvProg *raster = [NvProg new]; raster->sh[1] = fragment;
    uint64_t before = g_bp_pso_n;
    id<MTLRenderPipelineState> demanded = mtk_pso(raster);
    EXPECT("first demand returns the required mesh pipeline", 1, demanded != nil);
    EXPECT("duplicate live shader demand does not compile", before, g_bp_pso_n);
    EXPECT("duplicate live shader uses the warmed pipeline", 1, demanded == item->object);
    id<MTLRenderPipelineState> again = mtk_pso(raster);
    EXPECT("second demand reuses the pipeline", 1, again == demanded);
    EXPECT("second demand does not compile", before, g_bp_pso_n);

    g_shcache = nil;
    warm_enqueue(item); warm_claim();
    g_mtk.ms = g_shcache[@"warm-ms"]; raster->sh[1] = g_shcache[@"warm-fs"];
    id<MTLRenderPipelineState> warmed = mtk_pso(raster);
    EXPECT("first demand with identical shaders uses the warm pipeline", 1, warmed == item->object);
    EXPECT("warm hit does not compile", before, g_bp_pso_n);
    if (demanded && warmed) {
        uint8_t a[4], b[4];
        pixels(demanded, 1, a); pixels(warmed, 1, b);
        EXPECT("required and warmed mesh draws match", 1, memcmp(a, b, sizeof a) == 0);
        EXPECT("native mesh draw writes the triangle", 1, a[0] == 128 && a[1] == 64 && a[2] == 255 && a[3] == 128);
    }
    // A different depth entry must still miss: this fixture's ms_z emits no geometry.
    atomic_store(&g_depth_zero, 1);
    NvShader *other_depth = shader_load(@"warm-ms", 4, 0);
    EXPECT("different depth entry loaded", 1, other_depth && ![other_depth->ventry isEqualToString:live->ventry]);
    if (other_depth) {
        g_shcache[@"warm-ms"] = other_depth;
        unsigned count = g_pso_mtk.n;
        warm_enqueue(item); warm_claim();
        EXPECT("different depth entry is not claimed", count, g_pso_mtk.n);
        g_mtk.ms = other_depth;
        id<MTLRenderPipelineState> alternate = mtk_pso(raster);
        EXPECT("different depth entry builds its own pipeline", before + 1, g_bp_pso_n);
        EXPECT("different depth entry is not the warmed pipeline", 1, alternate && alternate != warmed);
        if (alternate) { uint8_t pixel[4]; pixels(alternate, 1, pixel); EXPECT("alternate entry preserves the clear color", 1, pixel[0] == 255 && pixel[1] == 0 && pixel[2] == 0 && pixel[3] == 255); }
    }
    atomic_store(&g_depth_zero, old_depth);
    pso_key depth = {.dfmt = MTLPixelFormatDepth32Float, .samples = 1};
    NSError *error = nil;
    EXPECT("depth-only native mesh pipeline uses the empty fragment", 1, mtk_build(&depth, nil, live, nil, &error, NULL) != nil);
    g_mtk.ms = nil;
    g_warm_t0 = bp_now(); warm_finish();
}

// The prepare step's shader-only lines (warm_split_late, warm_late_arm, warm_late_start): an S line whose shader an R, M or C line uses stays before the first frame, in its
// place; the rest wait for the first frame and then load on the utility workers, a library the game has loaded already is skipped, and each one loaded is claimed at the next
// submission. A run that never presents starts them after PREPARE_LATE_SUBS submissions (warm_late_tick). The prepare step timed with every S line before the first frame and
// with the split models what a list of many shader-only lines costs the first frame (printed, not checked: the split runs first, so the other run finds the pair's bases made)
static WarmTask *task(int kind, NSString *key, NSString *vkey, NSString *fkey, NSString *tkey) {
    WarmTask *t = [WarmTask new]; t->kind = kind; t->key = key; t->vkey = vkey; t->fkey = fkey; t->tkey = tkey; t->stage = 1; return t;
}
static int late_wait(int state) { for (int i = 0; i < 1000 && atomic_load(&g_warm_late_state) != state; i++) usleep(10000); return atomic_load(&g_warm_late_state) == state; }
static void late_lines(NSString *dir) {
    {   // the split alone: kept are the pipeline lines and the S lines of the shaders they use, in the lists' order; the others go, in theirs
        NSArray<WarmTask *> *tasks = @[task(0, @"a", nil, nil, nil), task(1, nil, @"v", @"f", nil), task(0, @"v", nil, nil, nil), task(0, @"f", nil, nil, nil), task(2, @"c", nil, nil, nil),
                                       task(0, @"c", nil, nil, nil), task(3, nil, @"m", @"mf", @"mt"), task(0, @"mt", nil, nil, nil), task(0, @"mf", nil, nil, nil), task(0, @"z", nil, nil, nil)];
        NSMutableArray<WarmTask *> *late = [NSMutableArray array]; long lines = 12;
        NSArray<WarmTask *> *now = warm_split_late(tasks, late, &lines);
        EXPECT("two shader-only lines no pipeline line uses wait", 2, late.count);
        EXPECT("they keep their order", 1, late.count == 2 && [late[0]->key isEqual:@"a"] && [late[1]->key isEqual:@"z"]);
        EXPECT("the lines before the first frame lose them", 10, lines);
        EXPECT("the rest stay", 8, now.count);
        int order = now.count == 8; for (NSUInteger i = 0; order && i < now.count; i++) order = now[i] == tasks[i + 1];
        EXPECT("in their order, the S lines of R, C and M shaders with them", 1, order);
    }
    enum { K = 48 };
    for (int i = 0; i <= K; i++) {
        for (NSString *ext in @[@"json", @"metallib"]) {
            NSString *to = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"late-%02d.%@", i, ext]];
            if (![NSFileManager.defaultManager fileExistsAtPath:to])
                EXPECT("shader-only fixture copied", 1, [NSFileManager.defaultManager copyItemAtPath:[dir stringByAppendingPathComponent:[@"warm-fs." stringByAppendingString:ext]] toPath:to error:nil]);
        }
        g_shmap[[NSString stringWithFormat:@"late-%02d", i]] = @"pixel";
    }
    pso_key key = {0}; key.cfmt[0] = MTLPixelFormatRGBA8Unorm; key.samples = 1; key.chmask = 15;
    NSMutableString *text = [NSMutableString stringWithFormat:@"S\twarm-vs\t0\nS\twarm-fs\t1\n%@", row(&key, 0)];
    for (int i = 0; i < K; i++) [text appendFormat:@"S\tlate-%02d\t1\n", i];
    NSString *manifest = [dir stringByAppendingPathComponent:@"late.tsv"];
    EXPECT("shader-only manifest written", 1, [text writeToFile:manifest atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    // The prepare step with the split, then with every line (the model)
    nvn_hm_clear(&g_pso, hm_rel); g_shcache = nil; g_warm_items = [NSMutableArray array]; atomic_store(&g_warm_ready, 0); g_warm_done = 0; g_warm_shaders = 0;
    long lines = 0; NSArray<WarmTask *> *all = warm_parse(@[manifest], &lines);
    EXPECT("every line parsed", K + 3, lines);
    NSMutableArray<WarmTask *> *late = [NSMutableArray array]; long before = lines;
    NSArray<WarmTask *> *now = warm_split_late(all, late, &before);
    EXPECT("the shader-only lines wait", K, late.count);
    EXPECT("the pair's S lines and its R line stay", 3, before);
    warm_load_begin(); uint64_t t0 = bp_now(); warm_prepare(now, before, (long)late.count); double split_ms = (bp_now() - t0) / 1e6;
    EXPECT("before the first frame: the pair's two shaders", 2, g_warm_shaders);
    nvn_hm_clear(&g_pso, hm_rel); g_shcache = nil; [g_warm_items removeAllObjects]; atomic_store(&g_warm_ready, 0); g_warm_done = 0; g_warm_shaders = 0;
    warm_load_begin(); t0 = bp_now(); warm_prepare(all, lines, 0); double all_ms = (bp_now() - t0) / 1e6;
    EXPECT("with every line before the first frame, every shader", K + 2, g_warm_shaders);
    printf("prepare model: %ld lines before the first frame in %.1f ms with every shader-only line there, %ld lines in %.1f ms with %d left to after it (%.2f ms a shader-only line)\n",
           lines, all_ms, before, split_ms, (int)K, (all_ms - split_ms) / K);
    g_warm_t0 = bp_now(); warm_finish();
    // After the first frame: one library the game's prefetch has already is skipped, the rest load and are claimed
    g_shcache = nil; [g_warm_items removeAllObjects]; atomic_store(&g_warm_ready, 0);
    progpf_first(@"late-05");
    uint64_t loaded0 = g_warm_late_loaded, had0 = g_warm_late_had;
    warm_late_arm(late);
    EXPECT("the lines wait for the first frame", 1, atomic_load(&g_warm_late_state));
    warm_late_start("the test's first frame");
    EXPECT("they load and end", 1, late_wait(3));
    EXPECT("every library but the prefetched one loaded", K - 1, g_warm_late_loaded - loaded0);
    EXPECT("the prefetched one skipped", 1, g_warm_late_had - had0);
    warm_claim();
    int claimed = 0; for (int i = 0; i < K; i++) claimed += g_shcache[[NSString stringWithFormat:@"late-%02d", i]] != nil;
    EXPECT("each loaded library claimed by the next submission", K - 1, claimed);
    EXPECT("not the one the game loads itself", 1, g_shcache[@"late-05"] == nil);
    warm_late_start("again"); EXPECT("a second start does nothing", 3, atomic_load(&g_warm_late_state));
    // A run that never presents: the lines start after PREPARE_LATE_SUBS submissions
    atomic_store(&g_warm_late_state, 0); warm_late_arm(@[task(0, [NSString stringWithFormat:@"late-%02d", (int)K], nil, nil, nil)]);
    for (int i = 0; i < PREPARE_LATE_SUBS - 1; i++) warm_late_tick();
    EXPECT("they wait while the submissions are few", 1, atomic_load(&g_warm_late_state));
    loaded0 = g_warm_late_loaded; warm_late_tick();
    EXPECT("and start at the last one", 1, late_wait(3));
    EXPECT("their library loaded", 1, g_warm_late_loaded - loaded0);
    g_shcache = nil; [g_warm_items removeAllObjects]; atomic_store(&g_warm_ready, 0); nvn_hm_clear(&g_pso, hm_rel);
}

// No shader-only (S) rows (nvn_mtl.m drop_s_on, DM_PSO_DROP_S; upstream NXNative 28d41fc9d): by default the prewarm ignores the lists' S lines and counts them, nothing records
// one (a draw's own load, a prefetched library's claim, a direct record), a hybrid stand-in's R row reaches the Mac recording too, and the device list's filter leaves S rows
// out of its set. Each check runs again under =0 (the negative control: the old behaviour, which fails the default's checks)
static NSArray<NSString *> *file_rows(const char *path) {
    NSString *t = [NSString stringWithContentsOfFile:@(path) encoding:NSUTF8StringEncoding error:nil];
    NSMutableArray *r = [NSMutableArray array]; for (NSString *l in [t componentsSeparatedByString:@"\n"]) if (l.length) [r addObject:l];
    return r;
}
static unsigned kind_rows(NSArray<NSString *> *rows, NSUInteger from, NSString *prefix) {
    unsigned n = 0; for (NSUInteger i = from; i < rows.count; i++) n += [rows[i] hasPrefix:prefix]; return n;
}
static void drop_s(NSString *dir) {
    pso_key key = {0}; key.cfmt[0] = MTLPixelFormatRGBA8Unorm; key.samples = 1; key.chmask = 15;
    NSString *manifest = [dir stringByAppendingPathComponent:@"drop.tsv"];
    NSString *text = [NSString stringWithFormat:@"# a comment\nS\twarm-vs\t0\nS\twarm-fs\t1\n%@S\twarm-vs\t0\nC\t\n", row(&key, 0)];
    EXPECT("S-row manifest written", 1, [text writeToFile:manifest atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    for (int on = 1; on >= 0; on--) {
        g_drop_s = on; uint64_t s0 = atomic_load(&g_warm_skip_s); long lines = 0;
        NSArray<WarmTask *> *tasks = warm_parse(@[manifest], &lines);
        unsigned shader_tasks = 0; for (WarmTask *t in tasks) shader_tasks += t->kind == 0;
        NSMutableArray<WarmTask *> *late = [NSMutableArray array]; long now = lines; warm_split_late(tasks, late, &now);
        if (on) {
            EXPECT("drop: the S lines are no lines and no tasks, the R line stays", 1, lines == 1 && tasks.count == 1 && shader_tasks == 0 && tasks[0]->kind == 1);
            EXPECT("drop: every S line counted, the repeated one too", 3, atomic_load(&g_warm_skip_s) - s0);
            EXPECT("drop: nothing for after the first frame (DM_PSO_LATE_S)", 0, late.count);
        } else {
            EXPECT("=0: the S lines are tasks, as before", 1, lines == 3 && tasks.count == 3 && shader_tasks == 2);
            EXPECT("=0: none counted", 0, atomic_load(&g_warm_skip_s) - s0);
            EXPECT("=0: the late split sees them (both used by the R line: none waits)", 0, late.count);
        }
    }
    // The 'prewarm done' and 'prepare' lines' shader count: by default the libraries the pipeline lines load (no S task counts any); =0 only the S tasks', as before
    for (int on = 1; on >= 0; on--) {
        g_drop_s = on; long lines = 0; NSArray<WarmTask *> *tasks = warm_parse(@[manifest], &lines); NSMutableArray<WarmTask *> *rt = [NSMutableArray array];
        for (WarmTask *t in tasks) if (t->kind == 1) [rt addObject:t];   // the R line's task alone
        nvn_hm_clear(&g_pso, hm_rel); g_shcache = nil; g_warm_items = [NSMutableArray array]; atomic_store(&g_warm_ready, 0); g_warm_done = 0; g_warm_shaders = 0;
        warm_load_begin(); for (WarmTask *t in rt) warm_task(t);
        if (on) EXPECT("drop: the R line's two libraries counted", 2, g_warm_shaders);
        else EXPECT("=0: an R line counts no library, as before", 0, g_warm_shaders);
    }
    nvn_hm_clear(&g_pso, hm_rel); g_shcache = nil; [g_warm_items removeAllObjects]; atomic_store(&g_warm_ready, 0); g_warm_done = 0; g_warm_shaders = 0;
    // The recorders: the Mac recording (DM_PSO_RECORD) and the device's list (DM_PSO_USER, through its queue and filter)
    char rec[] = "/tmp/t_pso_warm_rec.XXXXXX"; int fd = mkstemp(rec); if (fd >= 0) close(fd);
    NSString *user = [dir stringByAppendingPathComponent:@"drop_user.tsv"];
    EXPECT("device list written", 1, [@"S\twarm-other\t1\nC\tseed_b\n" writeToFile:user atomically:YES encoding:NSUTF8StringEncoding error:nil]);
    pso_user_sync(); if (g_pso_user) fclose(g_pso_user);
    g_pso_record = fopen(rec, "a"); g_pso_record_checked = 1;
    setenv("DM_PSO_USER", user.fileSystemRepresentation, 1); g_pso_user = NULL; g_pso_user_checked = 0;
    free(g_pso_user_hs.k); g_pso_user_hs = (pso_hset){0}; g_pso_user_hs_ready = 0; g_pso_user_seen = nil;
    NSString *saved_map = g_shmap_path; g_shmap_path = nil;   // no seed: the device's list alone fills the filter
    NvShader *vs = shader_load(@"warm-vs", 0, 0), *fs = shader_load(@"warm-fs", 1, 0);
    EXPECT("recording fixtures loaded", 1, vs && fs);
    for (int on = 1; on >= 0 && vs && fs; on--) {
        g_drop_s = on;
        NSUInteger r0 = file_rows(rec).count, u0 = file_rows(user.fileSystemRepresentation).count;
        g_shcache = nil; [g_warm_items removeAllObjects]; atomic_store(&g_warm_ready, 0);
        EXPECT("a draw's own load", 1, shader_get(@"warm-fs", 1) != nil);   // shader_get's record
        WarmItem *item = [WarmItem new]; item->kind = 0; item->record = 1; item->key = @"warm-vs"; item->shader = vs; warm_enqueue(item); warm_claim();   // a prefetched library's claim
        pso_key dk = key; dk.chmask = on ? 7 : 3; demand_record(&dk, vs, fs);   // a hybrid stand-in's demand (another key each pass: one row per key)
        pso_user_record("S\t%s\t%d\n", "warm-other", 1);   // a direct S record (in the device's list already)
        pso_user_record("S\t%s\t%d\n", "warm-new", 1);     // and one that is not
        pso_user_sync(); fflush(g_pso_record);
        NSArray<NSString *> *r = file_rows(rec), *u = file_rows(user.fileSystemRepresentation);
        if (on) {
            EXPECT("drop: the Mac recording has no S row", 0, kind_rows(r, r0, @"S\t"));
            EXPECT("drop: and the stand-in's R row", 1, kind_rows(r, r0, @"R\t"));
            EXPECT("drop: the device's list has no new S row", 0, kind_rows(u, u0, @"S\t"));
            EXPECT("drop: and the stand-in's R row", 1, kind_rows(u, u0, @"R\t"));
            EXPECT("drop: the filter's set holds the list's C row, not its S row", 1, g_pso_user_hs_ready ? g_pso_user_hs.n == 2 : g_pso_user_seen.count == 2);   // C seed_b and the R row
        } else {
            EXPECT("=0: the Mac recording has the draw's and the claim's S rows, as before", 2, kind_rows(r, r0, @"S\t"));
            EXPECT("=0: and no stand-in R row, as before", 0, kind_rows(r, r0, @"R\t"));
            // warm-other is not in the set the default filled (it left the S rows out), so =0 writes it again here: a switch changed within one run, never on a device
            EXPECT("=0: the device's list has the S rows, as before", 4, kind_rows(u, u0, @"S\t"));
            EXPECT("=0: and the stand-in's R row", 1, kind_rows(u, u0, @"R\t"));
        }
    }
    {   // the filter's fill alone, on a list: S rows left out by default, kept under =0
        pso_hset hs = {0}; g_drop_s = 1; pso_hset_add_list(&hs, manifest); size_t n_on = hs.n; free(hs.k);
        hs = (pso_hset){0}; g_drop_s = 0; pso_hset_add_list(&hs, manifest); size_t n_off = hs.n; free(hs.k);
        EXPECT("filter fill: the R and C rows only", 2, n_on);
        EXPECT("filter fill =0: the two distinct S rows too, as before", 4, n_off);
    }
    g_drop_s = 1; g_warm_t0 = bp_now(); warm_finish();   // the 'prewarm done' line with its S count
    pso_user_sync(); if (g_pso_user) fclose(g_pso_user); g_pso_user = NULL; g_pso_user_checked = 1;   // nothing more written by the tests after this one
    free(g_pso_user_hs.k); g_pso_user_hs = (pso_hset){0}; g_pso_user_hs_ready = 0; g_pso_user_seen = nil; unsetenv("DM_PSO_USER");
    fclose(g_pso_record); g_pso_record = NULL; unlink(rec);
    g_shmap_path = saved_map; g_shcache = nil; [g_warm_items removeAllObjects]; atomic_store(&g_warm_ready, 0);
}

// The paths that load a library share one preparation (shader_acquire; adapted from ComicBit/nxnative bee12ec, MIT): the prewarm, a draw's own load and a shader-only line
// after the first frame ask for the same key while the first load is held at the device, and the library loads once, all three taking the same shader. A failed preparation is
// not kept (the next caller loads it), DM_NVN_SHADER_SHARE=0 prepares each copy again, and nothing the sharing kept outlives the caches that hold its shaders.
@interface ShareLookupDictionary : NSObject { @public NSMutableDictionary *dictionary; NSString *key; dispatch_semaphore_t looked; } @end
@implementation ShareLookupDictionary
- (id)forwardingTargetForSelector:(SEL)selector { return dictionary; }
- (id)objectForKeyedSubscript:(id)k { if ([k isEqual:key]) dispatch_semaphore_signal(looked); return dictionary[k]; }
@end
static void shared_paths(NSString *dir) {
    for (NSString *name in @[@"share-fs", @"share-off"]) for (NSString *ext in @[@"json", @"metallib"]) {
        NSString *to = [dir stringByAppendingPathComponent:[NSString stringWithFormat:@"%@.%@", name, ext]];
        if (![NSFileManager.defaultManager fileExistsAtPath:to])
            EXPECT("sharing fixture copied", 1, [NSFileManager.defaultManager copyItemAtPath:[dir stringByAppendingPathComponent:[@"warm-fs." stringByAppendingString:ext]] toPath:to error:nil]);
    }
    g_shmap[@"share-fs"] = g_shmap[@"share-off"] = g_shmap[@"share-bad"] = @"pixel";
    g_shshare = 1; g_shload = nil; g_shcache = [NSMutableDictionary dictionary]; g_warm_items = [NSMutableArray array]; atomic_store(&g_warm_ready, 0);
    __weak NvShader *weak_shader = nil; __weak ShLoad *weak_record = nil;
    @autoreleasepool {
        warm_load_begin();
        ShareLookupDictionary *lookup = [ShareLookupDictionary new]; lookup->dictionary = [NSMutableDictionary dictionary]; lookup->key = @"share-fs";
        lookup->looked = dispatch_semaphore_create(0); g_shload = (NSMutableDictionary *)lookup;
        WarmGateDevice *gate = [WarmGateDevice new]; gate->device = g_dev;
        gate->entered = dispatch_semaphore_create(0); gate->release = dispatch_semaphore_create(0);
        g_dev = (id<MTLDevice>)gate;
        uint64_t made0 = g_shload_made, joined0 = g_shload_joined, late0 = g_warm_late_loaded;
        __block NvShader *warm = nil, *demand = nil;
        dispatch_group_t callers = dispatch_group_create();
        dispatch_group_async(callers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ @autoreleasepool { warm = warm_shader(@"share-fs", 1); } });
        EXPECT("the prewarm's load reaches the device gate", 0, dispatch_semaphore_wait(gate->entered, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        EXPECT("the prewarm looked the key up", 0, dispatch_semaphore_wait(lookup->looked, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        dispatch_group_async(callers, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{ @autoreleasepool { demand = shader_get(@"share-fs", 1); } });
        dispatch_group_async(callers, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ warm_late_one(task(0, @"share-fs", nil, nil, nil)); });
        EXPECT("the draw's load finds the key in flight", 0, dispatch_semaphore_wait(lookup->looked, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        EXPECT("the late line finds the key in flight", 0, dispatch_semaphore_wait(lookup->looked, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
        dispatch_semaphore_signal(gate->release);
        EXPECT("the three paths finish", 0, dispatch_group_wait(callers, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC)));
        EXPECT("the library loads once for three paths", 1, atomic_load(&gate->library_calls));
        EXPECT("one preparation made", 1, g_shload_made - made0);
        EXPECT("two preparations joined", 2, g_shload_joined - joined0);
        EXPECT("the late line handed its shader on", 1, g_warm_late_loaded - late0);
        NvShader *late = g_warm_items.count == 1 ? g_warm_items[0]->shader : nil;
        EXPECT("all three paths have the same shader", 1, warm && warm == demand && demand == late);
        EXPECT("the draw's load entered it in the cache", 1, g_shcache[@"share-fs"] == demand);
        NvShader *again = shader_acquire(@"share-fs", 1, 0);
        EXPECT("a later caller takes the finished shader", 1, again == warm);
        EXPECT("without a load", 1, atomic_load(&gate->library_calls));
        weak_shader = warm; weak_record = lookup->dictionary[@"share-fs"];
        // A failed preparation is not kept: the next caller loads it, and succeeds once the library exists
        made0 = g_shload_made;
        EXPECT("a missing library fails", 1, shader_acquire(@"share-bad", 1, 0) == nil);
        EXPECT("the failure leaves the table", 1, lookup->dictionary[@"share-bad"] == nil);
        for (NSString *ext in @[@"json", @"metallib"])
            EXPECT("retry fixture copied", 1, [NSFileManager.defaultManager copyItemAtPath:[dir stringByAppendingPathComponent:[@"warm-fs." stringByAppendingString:ext]]
                                                                                   toPath:[dir stringByAppendingPathComponent:[@"share-bad." stringByAppendingString:ext]] error:nil]);
        NvShader *retried = shader_acquire(@"share-bad", 1, 0);
        EXPECT("the next caller prepares it again and succeeds", 1, retried != nil);
        EXPECT("two preparations for the failure and the retry", 2, g_shload_made - made0);
        EXPECT("a later caller takes the retried shader", 1, shader_acquire(@"share-bad", 1, 0) == retried);
        // DM_NVN_SHADER_SHARE=0: each caller prepares its own copy, and nothing enters the table
        g_shshare = 0; unsigned calls = atomic_load(&gate->library_calls); made0 = g_shload_made; joined0 = g_shload_joined;
        NvShader *a = shader_acquire(@"share-off", 1, 0), *b = shader_acquire(@"share-off", 1, 0);
        EXPECT("switched off: two copies", 1, a && b && a != b);
        EXPECT("switched off: two loads", calls + 2, atomic_load(&gate->library_calls));
        EXPECT("switched off: nothing shared or counted", 1, lookup->dictionary[@"share-off"] == nil && g_shload_made == made0 && g_shload_joined == joined0);
        g_shshare = 1;
        g_dev = gate->device;
        warm = demand = late = again = retried = nil;
        g_shload = nil; g_shcache = nil; [g_warm_items removeAllObjects]; atomic_store(&g_warm_ready, 0); g_warm_dict = nil; g_warm_loads = nil;
    }
    EXPECT("the shared shader is released with the caches that held it", 1, weak_shader == nil);
    EXPECT("its record is released with the table", 1, weak_record == nil);
    for (NSString *ext in @[@"json", @"metallib"]) [NSFileManager.defaultManager removeItemAtPath:[dir stringByAppendingPathComponent:[@"share-bad." stringByAppendingString:ext]] error:nil];
}

// The prepare screen's show decision (prepare_rest; idea from S2Arm 98fc203eb): no compile rate before PREPARE_EST_COMPILES real compiles (the lines' rate decides, so a start of
// archive hits alone shows no screen that flashes), the compile rate after, where the lines' rate alone said the rest was quick (negative control: the old rule)
static void estimate(void) {
    // 8,000 archive hits in the first 0.5 s of a 47,000-line list, then real compiles
    {
        int lines_rate = 0; uint64_t ms = 1000000ull;
        double rest = prepare_rest(500 * ms, 8000, 47000, 10, &lines_rate);
        EXPECT("estimate: fewer than 32 compiles give no compile rate", 1, lines_rate);
        EXPECT("estimate: the lines' rate stands in", 1, rest > 2.4e9 && rest < 2.5e9);
        rest = prepare_rest(3000 * ms, 8100, 47000, 100, &lines_rate);
        EXPECT("estimate: 32 compiles or more give the compile rate", 0, lines_rate);
        EXPECT("estimate: the rest at that rate is minutes", 1, rest > 1000e9);
        double old = 3000.0 * ms * (47000 - 8100) / 8100;   // the old rule: lines done over time
        EXPECT("estimate: the old rule said seconds (negative control)", 1, old < 20e9);
        rest = prepare_rest(600 * ms, 9900, 10000, 0, &lines_rate);
        EXPECT("estimate: a start of archive hits only: no screen that flashes", 1, lines_rate && rest < 3e8);
        rest = prepare_rest(600 * ms, 9900, 10000, 40, &lines_rate);
        EXPECT("estimate: 100 lines left at 40 compiles in 0.6 s: the screen shows", 1, !lines_rate && rest >= 3e8);
    }
}

int main(void) { @autoreleasepool {
    alarm(60);   // A regression in owner/waiter progress must fail rather than hang the suite.
    setenv("DM_PSO_ARCHIVE", "off", 1); setenv("DM_NVN_PREDICT", "0", 1);
    unsetenv("DM_NVN_HILITE"); unsetenv("DM_NVN_MAGSCAN"); unsetenv("DM_PSO_RECORD"); unsetenv("DM_PSO_USER"); unsetenv("DM_SAVE");
    char dir[] = "/tmp/t_pso_warm.XXXXXX"; if (!mkdtemp(dir)) return 1;
    mtl_init();
    if (!fixtures(@(dir))) { fprintf(stderr, "failed to compile synthetic shader fixtures\n"); [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil]; return 1; }
    // The prebuild tool's default workers: as many compiles as Metal runs at once, however few cores level 0 has
    EXPECT("prebuild tool workers: Metal's concurrent compiles", g_dev.maximumConcurrentCompilationTaskCount, compile_tasks());
    g_drop_s = 0;   // DM_PSO_DROP_S=0 for the tests of S lines: the paths they check still run there (drop_s checks the default)
    singleflight(@(dir));
    scenario(@(dir), 0); scenario(@(dir), 1);
    native_mesh(@(dir));
    late_lines(@(dir));
    drop_s(@(dir));
    shared_paths(@(dir));
    estimate();
    EXPECT("pipelines are built through the Metal 4 compiler", 1, g_comp4 != nil && g_pb_spec > 0);
    [NSFileManager.defaultManager removeItemAtPath:@(dir) error:nil];
    printf("t_pso_warm: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
