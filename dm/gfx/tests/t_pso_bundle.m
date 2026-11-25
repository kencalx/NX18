// The pipeline archive made offline and bundled with the app (DM_PSO_BUNDLE, pso_bundle_open / pso_bundle_covers in nvn_mtl.m), made here as build_ipa.sh makes it: tiny shader
// libraries and their reflection, a pair list, then dm/gfx/tools/pso_offline.py (metal-tt) for this Mac's GPU. Checks: the archive for this GPU opens and comes first among the files of
// bases without a vertex layout; with a matching stamp the prebuild builds only the pairs left to the device (a function with constants) and takes nothing from the compiler otherwise,
// and a draw of a covered pair takes its base from the bundle and captures nothing for the device's own archive;
// a stamp of another depth mode or other pairs runs the device's prebuild, which still takes the bundled bases it finds; an archive whose bases the probe does not find is not trusted;
// a folder without this GPU's file and a file that is no archive leave no archive; the compute shaders of the shader map have their pipelines in the archive (cps_new: nothing
// built), and a shader with function constants or not in the map is built as before; the task / mesh pipelines of the prewarm list's M rows (the host's own keys) are in the archive,
// with a task shader and with the mesh shader's own object function, blended and with a write mask cut to the pixel shader's output map, and with no colour target (mtk_build: from the bundle, nothing built
// or captured), and one with a pixel shader that declares function constants or with no pixel shader is built as before; the layout bases of the prewarm list's R rows (keys the
// engine writes, pso_key_fill / pso_skey_from: float, half, instanced, constant, natively fetched (8-bit I2F) and CPU-converted (32-bit I2F) streams, 4 samples with alpha to coverage, an integer input fed its own class
// and through its shadow inputs, integer / mixed / dual-source fragments, depth only) come from the bundle through plain lookups (pso_build(pso_desc(...)): nothing compiled), and
// a row with a pixel shader with function constants or an attribute beyond its constant stream's stride (metal-tt refuses it) is built as before. The probe tells a list of cover pairs
// (every vertex shader with the same one or few pixel shaders) from real ones, and only such a list lets DM_PSO_HYBRID_KICK=0 leave a hybrid miss's pulling base unbuilt; a
// later probe that refuses the archive clears it. The stand-ins of the R rows whose vertex shader has a pulling library (pso_offline.py plan_standins): standins.tsv lists them, the
// probe finds them (standin_probe_in, not for the other depth mode; pso_bundle_covers looks them up in the background, on a line of their own, and gives their count on its line), and a draw of such a pair with another layout and colour state than its row's takes its pulling base from the
// bundle (hybrid_get: float, integer and 4-sample alpha-to-coverage targets), nothing compiled. The early open at the game's start (mtl_pso_bundle_preopen): the first submission
// takes its archive, waiting on the open's own serial queue, which its wait raises to its QoS (where this process's QoS is not clamped), and also for an open not begun yet; the
// crash guard begins with it, its record put back once Metal's open returned and written again by the first submission (also for one start ended early, and for two in a row,
// which leave the archive out), a small archive, DM_PSO_PREOPEN=0, a GPU without a file and a file that is no archive are left as before, and the
// mapping window (arch_open_begin / arch_open_end) is counted when two overlap.
// The crash guard (nvn_pso_guard.h; its rules are t_pso_guard.c's), which the Mac runs only with DM_PSO_BUNDLE_GUARD=1: unset, a planted record is not read; with it, a record
// planted for this archive and system build after one start that ended early uses the archive again, watched as the second in a row; after two in a row it leaves the archive out,
// and the start without it past its window keeps it out; DM_PSO_BUNDLE_GUARD=0 (and =Off) opens it all the same; a start with it writes the record before Metal reads it, the background
// puts it back and the window clears it; a file the container check refuses writes no record; and another system build's record is none.
// Without metal-tt (no Metal toolchain) it says so and passes
#include "../nvn/nvn_mtl.m"
#include <libproc.h>
#include "t_mtl4.h"
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(name, want, ...) do { uint64_t w = (want), g = (__VA_ARGS__); checks++; if (w != g) { fprintf(stderr, "%s: expected %llu, got %llu\n", name, (unsigned long long)w, (unsigned long long)g); failed++; } } while (0)

static int sh(NSString *cmd) { int r = system(cmd.UTF8String); return WIFEXITED(r) ? WEXITSTATUS(r) : -1; }
static void put(NSString *path, NSString *text) { [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil]; [text writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
static int lib(NSString *dir, NSString *name, NSString *src) {   // <dir>/<name>.metallib from MSL, with the SDK's compiler
    put([NSString stringWithFormat:@"%@/%@.metal", dir, name], src);
    return sh([NSString stringWithFormat:@"cd %@ && xcrun -sdk macosx metal -c %@.metal -o %@.air && xcrun -sdk macosx metallib %@.air -o %@.metallib && rm %@.metal %@.air", dir, name, name, name, name, name, name]);
}
// What run writes to stderr (the host's log lines), through a file in dir
static NSString *stderr_of(NSString *dir, void (^run)(void)) {
    NSString *p = [dir stringByAppendingPathComponent:@"stderr.txt"]; fflush(stderr); int saved = dup(2), fd = open(p.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) dup2(fd, 2);
    run(); fflush(stderr);
    if (fd >= 0) { dup2(saved, 2); close(fd); }
    close(saved);
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil] ?: @""; unlink(p.fileSystemRepresentation);
    fputs(s.UTF8String, stderr);   // as it would have been
    return s;
}
// The early open's end, without the one wait its block takes (pso_bundle_join's): a block queued behind it on its serial queue
static void preopen_wait(void) { dispatch_sync(pso_preopen_q(), ^{}); }
// A thread's priority as ps shows it (its QoS, with any override applied), read from another thread while it sleeps; its handle from thread_self_handle
static uint64_t thread_self_handle(void) {
    mach_port_t t = mach_thread_self(); thread_identifier_info_data_t ii; mach_msg_type_number_t n = THREAD_IDENTIFIER_INFO_COUNT;
    kern_return_t kr = thread_info(t, THREAD_IDENTIFIER_INFO, (thread_info_t)&ii, &n); mach_port_deallocate(mach_task_self(), t);
    return kr == KERN_SUCCESS ? ii.thread_handle : 0;
}
static int thread_pri(uint64_t h) { struct proc_threadinfo p = {0}; return h && proc_pidinfo(getpid(), PROC_PIDTHREADINFO, h, &p, sizeof p) > 0 ? p.pth_priority : -1; }
// The first submission as the guest's thread makes it: user-interactive QoS (0x21 on the iPhone), then pso_bundle_open
static _Atomic uint64_t g_ui_handle;
static void *ui_first_submission(void *list) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
    @autoreleasepool { atomic_store(&g_ui_handle, thread_self_handle()); pso_bundle_open((__bridge NSMutableArray *)list); }
    return NULL;
}
static void reset_counts(void) { g_pre_done = g_pre_built = g_pre_archived = g_pre_skipped = g_pre_failed = 0; }
// The R rows of the prewarm list as a draw records them (pso_key_fill from the state, pso_skey_from, pso_skey_hex), kept for the lookups: what the vertex layout and the colour
// targets are, attribute 0 a Float4 from stream 0 and attribute 1 as the row says
enum { NR = 24 };
static pso_key g_trk[NR]; static NvShader *g_rv[NR], *g_rf[NR]; static const char *g_rn[NR]; static int g_nr;
static NSMutableString *g_rrows;
static void rrow(const char *name, NvShader *vs, NvShader *fs, int a1fmt, int a1off, int a1st, uint32_t s0, uint32_t s1, uint32_t d1, uint32_t c0, uint32_t c1, uint32_t samples, int a2c, int src1) {
    state_reset(); S.nattr = 2;
    S.attr[0] = (va_st){.fmt = 0x2E, .offset = 0, .stream = 0}; S.attr[1] = (va_st){.fmt = (uint32_t)a1fmt, .offset = (uint32_t)a1off, .stream = (uint32_t)a1st};
    S.stream[0].stride = s0; if (a1st) { S.stream[a1st].stride = s1; S.stream[a1st].divisor = d1; }
    S.ms.a2c = a2c;
    if (src1) { S.color.blend_en = 1; S.blend[0].src_rgb = S.blend[0].src_a = NVN_BLEND_FUNC_ONE; S.blend[0].dst_rgb = S.blend[0].dst_a = NVN_BLEND_FUNC_ONE_MINUS_SRC1_COLOR; }
    uint32_t cf[8] = {c0, c1};
    pso_key_fill(&g_trk[g_nr], vs, fs, cf, c0 || c1 ? 0 : MTLPixelFormatDepth32Float, 0, samples, 0);
    pso_skey sk; char hex[sizeof sk * 2 + 1]; pso_skey_from(&g_trk[g_nr], vs, fs, 0, NULL, &sk); pso_skey_hex(&sk, hex);
    [g_rrows appendFormat:@"R\t%s\n", hex]; g_rv[g_nr] = vs; g_rf[g_nr] = fs; g_rn[g_nr] = name; g_nr++;
}

int main(void) { @autoreleasepool {
    char tmp[PATH_MAX]; snprintf(tmp, sizeof tmp, "%s/t_pso_bundle.XXXXXX", getenv("TMPDIR") ?: "/tmp"); if (!mkdtemp(tmp)) abort();
    NSString *root = @(tmp), *msl = [root stringByAppendingFormat:@"/msl/b-%s", DMSH_CHAIN], *tables = [root stringByAppendingPathComponent:@"tables"];
    NSString *bundle = [root stringByAppendingPathComponent:@"bundle"], *arch = [root stringByAppendingPathComponent:@"archive"];
    // A magic number alone cannot establish an archive: these are the known crash inputs, checked without calling Metal.
    NSString *bad = [root stringByAppendingPathComponent:@"bad.mtl4a"];
    const uint8_t magics[][4] = {{0xcf, 0xfa, 0xed, 0xfe}, {0xcb, 0xfe, 0xba, 0xbe}, {0xca, 0xfe, 0xba, 0xbe}, {0xca, 0xfe, 0xba, 0xbf}};
    for (unsigned i = 0; i < sizeof magics / sizeof magics[0]; i++) {
        [[NSData dataWithBytes:magics[i] length:4] writeToFile:bad atomically:YES];
        EXPECT("archive guard: bare magic refused", 0, arch_file_ok(bad));
        NSMutableData *header = [NSMutableData dataWithLength:32]; memcpy(header.mutableBytes, magics[i], 4); [header writeToFile:bad atomically:YES];
        EXPECT("archive guard: bare header refused", 0, arch_file_ok(bad));
    }
    // # cover padding sections are skipped by pre_parse and pre_parse_files, resetting on # kind: and isolating headerless later files (no Metal compiler needed).
    @autoreleasepool {
        NSString *cov = @"# kind: evidence\nv1\tf1\n# cover: single-stage padding pairs\nv1\tf2\n# kind: evidence\nv1\tfc\n# cover\nv1\tf3\n";
        EXPECT("cover: pre_parse skips # cover and resets on # kind:", 2, pre_parse(cov).count);
        EXPECT("cover: pre_parse_files isolates headerless second file", 2, pre_parse_files(@[@"# kind: evidence\nv1\tf1\n# cover: padding\nv1\tf2\n", @"v1\tfc\n"]).count);
        EXPECT("cover: pre_parse_files deduplicates across files", 1, pre_parse_files(@[@"v1\tf1\n", @"v1\tf1\n"]).count);
        {   // Ocarina of Time's size (34,600 rows): a set of NSArrays (hash = count) took minutes on the iPhone and the game never started; string keys keep it well under a second
            NSMutableString *big = [NSMutableString string]; for (int i = 0; i < 40000; i++) [big appendFormat:@"v%d\tf%d\n", i, i];
            uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW); NSUInteger n = pre_parse_files(@[big, @"v1\tf1\n"]).count;
            double ms = (clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0) / 1e6;
            EXPECT("cover: pre_parse_files keeps 40,000 distinct pairs once", 40000, n);
            EXPECT("cover: pre_parse_files on 40,000 pairs takes under 2 s", 1, ms < 2000);
        }
    }
    NSString *v = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\n"
        "vertex V main0(uint id [[vertex_id]]) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.p = float4(uv * 2 - 1, 0, 1); return o; }\n"
        "vertex V main0_z(uint id [[vertex_id]]) { V o; float2 uv = float2((id << 1) & 2, id & 2); o.p = float4(uv * 2 - 1, 0.5, 1); return o; }\n";
    NSString *f = @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(%d, %d, 0, 1); }\n";
    NSString *fc = @"#include <metal_stdlib>\nusing namespace metal;\nconstant bool k [[function_constant(0)]];\nfragment float4 main0() { return is_function_constant_defined(k) ? float4(1) : float4(0); }\n";
    NSString *k = @"#include <metal_stdlib>\nusing namespace metal;\nkernel void main0(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = i * %d; }\n";
    NSString *kc = @"#include <metal_stdlib>\nusing namespace metal;\nconstant uint m [[function_constant(0)]];\n"
        "kernel void main0(device uint *o [[buffer(0)]], uint i [[thread_position_in_grid]]) { o[i] = is_function_constant_defined(m) ? m : i; }\n";
    [NSFileManager.defaultManager createDirectoryAtPath:msl withIntermediateDirectories:YES attributes:nil error:nil];
    if (lib(msl, @"v1_bp", v) || lib(msl, @"f1_b", [NSString stringWithFormat:f, 1, 0]) || lib(msl, @"f2_b", [NSString stringWithFormat:f, 0, 1]) || lib(msl, @"fc_b", fc) ||
        lib(msl, @"c1_b", [NSString stringWithFormat:k, 2]) || lib(msl, @"c2_b", [NSString stringWithFormat:k, 4]) ||
        lib(msl, @"c3_b", [NSString stringWithFormat:k, 5]) || lib(msl, @"cc_b", kc)) {
        printf("t_pso_bundle: no Metal compiler (xcrun metal), GPU checks not run; %d file checks failed\n", failed); return failed != 0; }
    put([msl stringByAppendingPathComponent:@"v1_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"entry_z\": \"main0_z\", \"pull\": {}, \"vertex_inputs\": []}", DMSH_CHAIN]);
    for (NSString *k in @[@"f1", @"f2", @"fc"]) put([msl stringByAppendingFormat:@"/%@_b.json", k], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\"}", DMSH_CHAIN]);
    for (NSString *c in @[@"c1", @"c2", @"c3", @"cc"]) put([msl stringByAppendingFormat:@"/%@_b.json", c], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"route\": \"B\", \"bindings\": [], \"stage\": \"cs\", \"entry\": \"main0\"%@}",
                                                DMSH_CHAIN, @""]);
    put([tables stringByAppendingPathComponent:@"shader_map.tsv"], @"package\tindex\tstage\tdm_ctl_sha16\tsource\ncs.bin\t0\tcompute\tc1\tx\ncs.bin\t1\tcompute\tc2\tx\ncs.bin\t2\tcompute\tcc\tx\n");
    put([tables stringByAppendingPathComponent:@"shader_pairs.tsv"], @"# pairs\nv1\tf1\nv1\tf2\nv1\tfc\n");
    // Task and mesh shaders as dmsh_meshstage.py makes them: a task shader's object function, a mesh shader with a task (main0, main0_z) and one without, whose own object function
    // launches its blocks (main0_o); a pixel shader whose output map leaves alpha alone (raster.omap), so its pipelines' write mask is cut to RGB
    NSString *meshes = @"#include <metal_stdlib>\nusing namespace metal;\nstruct MV { float4 p [[position]]; };\nusing Tri = mesh<MV, void, 3, 1, topology::triangle>;\nstruct PL { uint n; };\n"
        "[[mesh]] void main0(Tri out, const object_data PL &pl [[payload]]) { out.set_primitive_count(pl.n); out.set_vertex(0, MV{float4(-1, -1, 0.5, 1)}); out.set_vertex(1, MV{float4(3, -1, 0.5, 1)});\n"
        "  out.set_vertex(2, MV{float4(-1, 3, 0.5, 1)}); out.set_index(0, 0); out.set_index(1, 1); out.set_index(2, 2); }\n"
        "[[mesh]] void main0_z(Tri out, const object_data PL &pl [[payload]]) { out.set_primitive_count(pl.n); out.set_vertex(0, MV{float4(-1, -1, 0, 1)}); out.set_vertex(1, MV{float4(3, -1, 0, 1)});\n"
        "  out.set_vertex(2, MV{float4(-1, 3, 0, 1)}); out.set_index(0, 0); out.set_index(1, 1); out.set_index(2, 2); }\n%@";
    NSString *task = @"#include <metal_stdlib>\nusing namespace metal;\nstruct PL { uint n; };\n"
        "[[object]] void main0(object_data PL &pl [[payload]], mesh_grid_properties g) { pl.n = 1; g.set_threadgroups_per_grid(uint3(1, 1, 1)); }\n";
    NSString *own = @"[[object]] void main0_o(object_data PL &pl [[payload]], mesh_grid_properties g) { pl.n = 1; g.set_threadgroups_per_grid(uint3(1, 1, 1)); }\n";
    if (lib(msl, @"t1_b", task) || lib(msl, @"m1_b", [NSString stringWithFormat:meshes, @""]) || lib(msl, @"m2_b", [NSString stringWithFormat:meshes, own]) ||
        lib(msl, @"p1_b", [NSString stringWithFormat:f, 0, 1])) { fprintf(stderr, "t_pso_bundle: the task / mesh fixture libraries did not compile\n"); return 1; }
    NSString *refl = @"{\"chain\": \"%s\", \"route\": \"B\", \"bindings\": [], \"stage\": \"%@\", \"entry\": \"main0\"%@}";
    put([msl stringByAppendingPathComponent:@"t1_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ts", @", \"mesh_stage\": {\"kind\": \"ts\", \"threads\": 1, \"payload\": 4, \"task\": true}"]);
    put([msl stringByAppendingPathComponent:@"m1_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ms", @", \"entry_z\": \"main0_z\", \"mesh_stage\": {\"kind\": \"ms\", \"threads\": 1, \"payload\": 4, \"task\": true}"]);
    put([msl stringByAppendingPathComponent:@"m2_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ms",
                                                            @", \"entry_z\": \"main0_z\", \"entry_object\": \"main0_o\", \"mesh_stage\": {\"kind\": \"ms\", \"threads\": 1, \"payload\": 4, \"task\": false}"]);
    put([msl stringByAppendingPathComponent:@"p1_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"raster\": {\"colors\": [0], \"omap\": 7}"]);
    put([msl stringByAppendingPathComponent:@"fc_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @""]);   // also the pixel shader of a task / mesh row, which shader_load loads
    setenv("DM_NVN_SHMAP", [tables stringByAppendingPathComponent:@"shader_map.tsv"].UTF8String, 1);
    setenv("DM_MSL_DIR", [root stringByAppendingPathComponent:@"msl"].UTF8String, 1);
    setenv("DM_PSO_ARCHIVE", arch.UTF8String, 1); setenv("DM_PSO_MANIFEST", "off", 1);
    mtl_init();
    NSString *gpu = g_dev.architecture.name;
    // The M rows, as mtk_pso records them (pso_skey_from, pso_skey_hex): keys that only name the shaders, as a prewarm row does
    NvShader *(^named)(const char *, int) = ^NvShader *(const char *key, int stage) { NvShader *o = [NvShader new]; strlcpy(o->key, key, sizeof o->key); o->stage = stage; return o; };
    pso_key mk; memset(&mk, 0, sizeof mk); mk.cfmt[0] = MTLPixelFormatRGBA8Unorm; mk.chmask = 0xf; mk.samples = 1;
    pso_key md; memset(&md, 0, sizeof md); md.samples = 1; md.dfmt = MTLPixelFormatDepth32Float;   // a pixel shader but no colour target (a depth pre-pass): every attachment the default
    pso_key mb = mk; mb.cfmt[1] = MTLPixelFormatBGRA8Unorm; mb.chmask = 0xff; mb.blend_en = 1;   // target 0 blended (source alpha over), target 1 written by no output
    mb.blend[0].src_rgb = mb.blend[0].src_a = NVN_BLEND_FUNC_SRC_ALPHA; mb.blend[0].dst_rgb = mb.blend[0].dst_a = NVN_BLEND_FUNC_ONE_MINUS_SRC_ALPHA; mb.blend[0].eq_rgb = mb.blend[0].eq_a = NVN_BLEND_EQUATION_ADD;
    NSString *(^mrow)(const char *, const char *, const char *, const pso_key *) = ^NSString *(const char *t, const char *m, const char *p, const pso_key *k) {
        pso_skey sk; char hex[sizeof sk * 2 + 1]; pso_skey_from(k, named(m, 4), p ? named(p, 1) : nil, 0, NULL, &sk); pso_skey_hex(&sk, hex);
        return [NSString stringWithFormat:@"M\t%s\t%s\n", t ?: "-", hex]; };
    // Shaders with stage inputs, as the translator makes them: va (float inputs: a Float4 at 0, a float2 at 1), vi (an unsigned integer input at 1 with shadow inputs, vi_bv: its float
    // declaration at 16, its signed one at 17, dmsh_vin.py); pixel shaders with a typed-output entry point (entry_u) for an integer target and for a float target beside an integer one (output 1), as main0_u is when it declares no constant (the build's are in the side library with constants, left to the device), and a dual-source (entry_d) entry point
    NSString *hd = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 p [[position]]; };\n";
    NSString *va = [hd stringByAppendingString:@"struct VI { float4 p [[attribute(0)]]; float2 uv [[attribute(1)]]; };\n"
        "vertex VO main0(VI i [[stage_in]]) { VO o; o.p = i.p + float4(i.uv, 0, 0); return o; }\nvertex VO main0_z(VI i [[stage_in]]) { VO o; o.p = i.p * 0.5 + float4(i.uv, 0, 0); return o; }\n"];
    NSString *vi = [hd stringByAppendingString:@"struct VI { float4 p [[attribute(0)]]; uint4 m [[attribute(1)]]; };\nvertex VO main0(VI i [[stage_in]]) { VO o; o.p = i.p + float4(i.m); return o; }\n"];
    NSString *vib = [hd stringByAppendingString:@"struct VI { float4 p [[attribute(0)]]; uint4 m [[attribute(1)]]; float4 m_vf [[attribute(16)]]; int4 m_vo [[attribute(17)]]; };\n"
        "vertex VO main0(VI i [[stage_in]]) { uint4 m = i.m | as_type<uint4>(i.m_vf) | as_type<uint4>(i.m_vo); VO o; o.p = i.p + float4(m); return o; }\n"];
    NSString *fu = @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1); }\nfragment uint4 main0_u() { return uint4(1); }\n";
    NSString *two = @"#include <metal_stdlib>\nusing namespace metal;\nstruct O { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; };\nfragment O main0() { return O{float4(1), float4(0.5)}; }\n";
    NSString *fm = [two stringByAppendingString:@"struct OM { float4 c0 [[color(0)]]; uint4 c1 [[color(1)]]; };\nfragment OM main0_u() { return OM{float4(1), uint4(2)}; }\n"];
    NSString *fd = [two stringByAppendingString:@"struct OD { float4 c0 [[color(0), index(0)]]; float4 c1 [[color(0), index(1)]]; };\nfragment OD main0_d() { return OD{float4(1), float4(0.5)}; }\n"];
    if (lib(msl, @"va_b", va) || lib(msl, @"vi_b", vi) || lib(msl, @"vi_bv", vib) || lib(msl, @"fa_b", [NSString stringWithFormat:f, 1, 1]) || lib(msl, @"fu_b", fu) ||
        lib(msl, @"fm_b", fm) || lib(msl, @"fd_b", fd)) { fprintf(stderr, "t_pso_bundle: the layout fixture libraries did not compile\n"); return 1; }
    put([msl stringByAppendingPathComponent:@"va_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"vs", @", \"entry_z\": \"main0_z\", \"vertex_inputs\": [{\"location\": 0, \"msl_type\": \"float4\"}, {\"location\": 1, \"msl_type\": \"float2\"}]"]);
    put([msl stringByAppendingPathComponent:@"vi_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"vs", @", \"vertex_inputs\": [{\"location\": 0, \"msl_type\": \"float4\"}, {\"location\": 1, \"msl_type\": \"uint4\"}], "
                                                            "\"vin\": {\"shadow\": [{\"location\": 1, \"float\": 16, \"sint\": 17}]}"]);
    put([msl stringByAppendingPathComponent:@"fa_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"raster\": {\"colors\": [0]}"]);
    put([msl stringByAppendingPathComponent:@"fu_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"entry_u\": \"main0_u\", \"raster\": {\"colors\": [0]}"]);
    put([msl stringByAppendingPathComponent:@"fm_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"entry_u\": \"main0_u\", \"raster\": {\"colors\": [0, 1]}"]);
    put([msl stringByAppendingPathComponent:@"fd_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"entry_d\": \"main0_d\", \"raster\": {\"colors\": [0, 1]}"]);
    shmap_read_once();   // the library folder (g_msl_dir), as shmap_load reads it before the prewarm
    NvShader *sva = shader_load(@"va_b", 0, 0), *svi = shader_load(@"vi_b", 0, 0), *sfa = shader_load(@"fa_b", 1, 0), *sfu = shader_load(@"fu_b", 1, 0), *sfm = shader_load(@"fm_b", 1, 0),
             *sfd = shader_load(@"fd_b", 1, 0), *sfc = shader_load(@"fc_b", 1, 0);
    if (!sva || !svi || !sfa || !sfu || !sfm || !sfd || !sfc) { fprintf(stderr, "t_pso_bundle: the layout fixture shaders did not load\n"); return 1; }
    const uint32_t RGBA8 = MTLPixelFormatRGBA8Unorm, RGBA8U = MTLPixelFormatRGBA8Uint;
    g_rrows = [NSMutableString string];
    rrow("float layout", sva, sfa, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("half", sva, sfa, 0x11, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("instanced stream", sva, sfa, 0x16, 0, 1, 16, 8, 1, RGBA8, 0, 1, 0, 0);
    rrow("constant stream", sva, sfa, 0x0A, 0, 2, 16, 0, 0, RGBA8, 0, 1, 0, 0);   // a Float: within the stride of 4 pso_desc gives a constant stream
    rrow("I2F format (native fetch)", sva, sfa, 0x57, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("32-bit I2F format (CPU conversion slot)", sva, sfa, 0x5B, 0, 1, 16, 8, 0, RGBA8, 0, 1, 0, 0);
    rrow("4 samples, alpha to coverage", sva, sfa, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 4, 1, 0);
    rrow("integer input, own class", svi, sfa, 0x27, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("integer input, shadow input", svi, sfa, 0x11, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("integer input, other sign: shadow", svi, sfa, 0x15, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("integer fragment", sva, sfu, 0x16, 16, 0, 24, 0, 0, RGBA8U, 0, 1, 0, 0);
    rrow("mixed fragment", sva, sfm, 0x16, 16, 0, 24, 0, 0, RGBA8, RGBA8U, 1, 0, 0);
    rrow("dual-source fragment", sva, sfd, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 1, 0, 1);
    rrow("depth only", sva, nil, 0x16, 16, 0, 24, 0, 0, 0, 0, 1, 0, 0);
    // A vertex shader with stage inputs and a pulling library (vp_bp, dmsh_pull.py), whose rows also give stand-ins (pso_offline.py plan_standins): the pulling base hybrid_get asks
    // for when a later draw of the same pair misses its pipeline, with the fragment entry of the row's targets, its samples and alpha to coverage
    NSString *vpl = [va stringByReplacingOccurrencesOfString:@"i.p + float4(i.uv, 0, 0)" withString:@"i.p - float4(i.uv, 0, 0)"];   // another function than va's: libraries are taken by content
    if ([vpl isEqualToString:va] || lib(msl, @"vp_b", vpl) || lib(msl, @"vp_bp", [v stringByReplacingOccurrencesOfString:@"uv * 2 - 1" withString:@"uv * 2 - 0.5"])) { fprintf(stderr, "t_pso_bundle: the stand-in fixture libraries did not compile\n"); return 1; }
    put([msl stringByAppendingPathComponent:@"vp_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"vs", @", \"entry_z\": \"main0_z\", \"pull\": {}, "
                                                            "\"vertex_inputs\": [{\"location\": 0, \"msl_type\": \"float4\"}, {\"location\": 1, \"msl_type\": \"float2\"}]"]);
    NvShader *svp = shader_load(@"vp_b", 0, 0);
    if (!svp || !svp->has_pull) { fprintf(stderr, "t_pso_bundle: the stand-in fixture shader did not load with its pulling library\n"); return 1; }
    rrow("stand-in pair, float layout", svp, sfa, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("stand-in pair, integer fragment", svp, sfu, 0x16, 16, 0, 24, 0, 0, RGBA8U, 0, 1, 0, 0);
    rrow("stand-in pair, 4 samples, alpha to coverage", svp, sfa, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 4, 1, 0);
    int nfound = g_nr;   // the rows above come from the bundle; those below are built: a pixel shader with function constants, and a Float2 in a constant stream, beyond the
    // stride of 4 pso_desc gives it, which the device's compiler takes and metal-tt refuses (left to the device, so that the rest of its group is not refused with it)
    rrow("pixel shader with function constants", sva, sfc, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("constant stream, attribute beyond the stride", sva, sfa, 0x16, 0, 2, 16, 0, 0, RGBA8, 0, 1, 0, 0);
    put([tables stringByAppendingPathComponent:@"pso_manifest.tsv"], [@[@"# list\n", mrow("t1_b", "m1_b", "p1_b", &mk), mrow(NULL, "m2_b", "p1_b", &mb), mrow("t1_b", "m1_b", "p1_b", &mk),
                                                                      mrow("t1_b", "m1_b", "fc_b", &mk), mrow(NULL, "m2_b", NULL, &mk), mrow("t1_b", "m1_b", "p1_b", &md), g_rrows] componentsJoinedByString:@""]);
    // the archive as build_ipa.sh makes it (the tool's own folder: this file is dm/gfx/tests/t_pso_bundle.m)
    NSString *tool = [[@(__FILE__) stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"../tools/pso_offline.py"];
    if (sh([NSString stringWithFormat:@"python3 %@ --platform macos --gpu %@ --msl %@ --pairs %@/shader_pairs.tsv --shader-map %@/shader_map.tsv --manifest %@/pso_manifest.tsv --out %@ --work %@/work > %@/pso_offline.log 2>&1",
            tool, gpu, msl, tables, tables, tables, bundle, root, root])) {
        NSString *log = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"pso_offline.log"] encoding:NSUTF8StringEncoding error:nil];
        if ([log containsString:@"metal-tt is not available"]) { printf("t_pso_bundle: no metal-tt (xcodebuild -downloadComponent MetalToolchain), GPU checks not run; %d file checks failed\n", failed); return failed != 0; }
        fprintf(stderr, "pso_offline.py failed:\n%s\n", log.UTF8String); return 1;
    }
    EXPECT("bundle: this GPU's archive", 1, [NSFileManager.defaultManager fileExistsAtPath:[bundle stringByAppendingFormat:@"/%@.mtl4a", gpu]]);
    NSData *archiveBytes = [NSData dataWithContentsOfFile:[bundle stringByAppendingFormat:@"/%@.mtl4a", gpu]];
    EXPECT("archive guard: real offline archive accepted", 1, arch_file_ok([bundle stringByAppendingFormat:@"/%@.mtl4a", gpu]));
    // what the open reads first (arch_open_read): the records outside __TEXT (__AIR_DATA) and the libraries (__TEXT,__metallib), not the GPU code
    @autoreleasepool {
        NSString *ap = [bundle stringByAppendingFormat:@"/%@.mtl4a", gpu]; arch_reads rd = {0};
        EXPECT("archive reads: offline archive checked", 1, arch_file_state_rd(ap, &rd));
        EXPECT("archive reads: offline archive, records and libraries", 2, rd.n);
        uint64_t tot = 0; for (int i = 0; i < rd.n; i++) tot += rd.len[i];
        EXPECT("archive reads: offline archive, less than the file", 1, tot > 0 && tot < archiveBytes.length);
        NSError *e = nil; EXPECT("archive reads: offline archive opens", 1, arch_open_read(ap, &rd, &e) != nil);
    }
    for (NSUInteger len = 32; len < archiveBytes.length; len = MIN(len * 2, archiveBytes.length)) {
        [[archiveBytes subdataWithRange:NSMakeRange(0, len)] writeToFile:bad atomically:YES];
        EXPECT("archive guard: truncated offline archive refused", 0, arch_file_ok(bad));
    }
    // Both standard universal wrappers must retain their slice bounds, including 64-bit offsets that cannot fit in the file.
    for (int wide = 0; wide < 2; wide++) {
        NSMutableData *wrapped = [NSMutableData dataWithLength:64];
        struct fat_header *fh = wrapped.mutableBytes; fh->magic = OSSwapHostToBigInt32(wide ? FAT_MAGIC_64 : FAT_MAGIC); fh->nfat_arch = OSSwapHostToBigInt32(1);
        if (wide) {
            struct fat_arch_64 *a = (void *)((uint8_t *)wrapped.mutableBytes + sizeof *fh);
            a->offset = OSSwapHostToBigInt64(64); a->size = OSSwapHostToBigInt64(archiveBytes.length);
        } else {
            struct fat_arch *a = (void *)((uint8_t *)wrapped.mutableBytes + sizeof *fh);
            a->offset = OSSwapHostToBigInt32(64); a->size = OSSwapHostToBigInt32((uint32_t)archiveBytes.length);
        }
        [wrapped appendData:archiveBytes]; [wrapped writeToFile:bad atomically:YES];
        EXPECT("archive guard: universal GPU image accepted", 1, arch_file_ok(bad));
        if (wide) ((struct fat_arch_64 *)((uint8_t *)wrapped.mutableBytes + sizeof *fh))->offset = UINT64_MAX;
        else ((struct fat_arch *)((uint8_t *)wrapped.mutableBytes + sizeof *fh))->size = UINT32_MAX;
        [wrapped writeToFile:bad atomically:YES];
        EXPECT("archive guard: universal slice outside file refused", 0, arch_file_ok(bad));
    }
    NSMutableData *broken = [archiveBytes mutableCopy];
    struct mach_header_64 *mh = broken.mutableBytes;
    EXPECT("archive fixture: one GPU image", MH_MAGIC_64, mh->magic);
    ((struct load_command *)((uint8_t *)broken.mutableBytes + sizeof *mh))->cmdsize = 0;
    [broken writeToFile:bad atomically:YES];
    EXPECT("archive guard: invalid load command refused", 0, arch_file_ok(bad));
    NSString *rest = [NSString stringWithContentsOfFile:[bundle stringByAppendingPathComponent:@"rest_pairs.tsv"] encoding:NSUTF8StringEncoding error:nil];
    EXPECT("bundle: one pair left to the device", 1, [rest isEqualToString:@"v1\tfc\n"]);
    setenv("DM_PSO_BUNDLE", bundle.UTF8String, 1);
    shmap_load(); pso4_init();
    EXPECT("bundle: opened", 1, g_arch_bundle != nil);
    EXPECT("bundle: first among the files without a vertex layout", 1, g_arch4p.count && g_arch4p[0] == g_arch_bundle);
    // compute pipelines: the shader map's compute shaders come from the bundle; a shader with function constants and one the map does not have are built
    @autoreleasepool {
        NvShader *c1 = shader_load(@"c1_b", 5, 0), *c2 = shader_load(@"c2_b", 5, 0), *c3 = shader_load(@"c3_b", 5, 0), *cc = shader_load(@"cc_b", 5, 0); NSError *err = nil;
        EXPECT("compute: shaders loaded", 1, c1 && c2 && c3 && cc);
        uint64_t a0 = g_cps_arch, b0 = g_cps_built; int n0 = g_arch_new;
        EXPECT("compute: a pipeline", 1, c1 && cps_new(c1->fn, &err) != nil);
        EXPECT("compute: a second pipeline", 1, c2 && cps_new(c2->fn, &err) != nil);
        EXPECT("compute: both from the bundle", a0 + 2, g_cps_arch);
        EXPECT("compute: nothing built", b0, g_cps_built);
        EXPECT("compute with constants: a pipeline", 1, cc && cps_new(cc->fn, &err) != nil);
        EXPECT("compute not in the map: a pipeline", 1, c3 && cps_new(c3->fn, &err) != nil);
        EXPECT("compute with constants, not in the map: built", b0 + 2, g_cps_built);
        EXPECT("compute with constants, not in the map: not from the bundle", a0 + 2, g_cps_arch);
        dispatch_sync(arch_harvest_q(), ^{});
        EXPECT("compute not in the map and with constants: both captured into this device's archive", n0 + 2, g_arch_new);
    }
    // task / mesh pipelines: the three the rows describe come from the bundle, nothing built or captured; a pixel shader with function constants and no pixel shader are built as before
    @autoreleasepool {
        NvShader *t1 = shader_load(@"t1_b", 3, 0), *m1 = shader_load(@"m1_b", 4, 0), *m2 = shader_load(@"m2_b", 4, 0), *p1 = shader_load(@"p1_b", 1, 0), *pc = shader_load(@"fc_b", 1, 0);
        EXPECT("mesh: shaders loaded", 1, t1 && m1 && m2 && p1 && pc && m2->mesh_obj && t1->mesh_kind == 1 && m1->mesh_kind == 2 && m2->mesh_notask);
        NSString *log = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"pso_offline.log"] encoding:NSUTF8StringEncoding error:nil];
        EXPECT("mesh: three pipelines in the archive, the constant and no-pixel-shader rows left out", 1, [log containsString:@"5 task / mesh rows: 3 task / mesh pipelines"]);
        uint64_t a0 = g_mtk_arch, b0 = g_mtk_built; int n0 = g_arch_new, got = 0; NSError *err = nil;
        if (t1 && m1 && m2 && p1 && pc) {
            EXPECT("mesh with a task: a pipeline", 1, mtk_build(&mk, t1, m1, p1, &err, &got) != nil);
            EXPECT("mesh with a task: from the bundle", 1, got);
            EXPECT("mesh, its own object function, blended: a pipeline", 1, mtk_build(&mb, nil, m2, p1, &err, &got) != nil);
            EXPECT("mesh, its own object function, blended: from the bundle", 1, got);
            EXPECT("mesh, no colour target: a pipeline", 1, mtk_build(&md, t1, m1, p1, &err, &got) != nil);
            EXPECT("mesh, no colour target: from the bundle", 1, got);
            EXPECT("mesh: all three from the archive", a0 + 3, g_mtk_arch);
            EXPECT("mesh: nothing built", b0, g_mtk_built);
            EXPECT("mesh, pixel shader with constants: a pipeline", 1, mtk_build(&mk, t1, m1, pc, &err, &got) != nil);
            EXPECT("mesh, pixel shader with constants: built", 0, got);
            EXPECT("mesh, no pixel shader: a pipeline", 1, mtk_build(&mk, nil, m2, nil, &err, &got) != nil);
            EXPECT("mesh, no pixel shader: built", 0, got);
            EXPECT("mesh: the two left out built", b0 + 2, g_mtk_built);
            pso_key other = mb; other.blend[0].dst_rgb = NVN_BLEND_FUNC_ONE;   // other blend state than the row's: another pipeline
            EXPECT("mesh, other blend state: a pipeline", 1, mtk_build(&other, nil, m2, p1, &err, &got) != nil);
            EXPECT("mesh, other blend state: not in the bundle", 0, got);
            dispatch_sync(arch_harvest_q(), ^{});
            EXPECT("mesh: only those built captured for the device's archive", n0 + 3, g_arch_new);
        }
    }
    // layout bases: every R row's base (a vertex layout) comes from the bundle (pso_desc as the draw and the prewarm make it, pso_build: nothing compiled), the one with a pixel
    // shader with function constants is built
    @autoreleasepool {
        NSString *log = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"pso_offline.log"] encoding:NSUTF8StringEncoding error:nil];
        EXPECT("layout: the rows' bases in the archive, the constant row left out", 1, [log containsString:[NSString stringWithFormat:@"%d render rows: %d layout bases", g_nr, nfound]]);
        for (int i = 0; i < g_nr; i++) {
            uint64_t a0 = g_pb_archived, b0 = g_pb_built, v0 = g_pb_bundle_vd; NSError *err = nil; char what[160];
            id<MTLRenderPipelineState> ps = pso_build(pso_desc(&g_trk[i], g_rv[i], g_rf[i], nil, 0), !g_trk[i].border, &err);   // off as the draw takes it
            snprintf(what, sizeof what, "layout, %s: a pipeline", g_rn[i]); EXPECT(what, 1, ps != nil);
            if (!ps) fprintf(stderr, "  %s: %s\n", g_rn[i], err.localizedDescription.UTF8String);
            snprintf(what, sizeof what, "layout, %s: its base %s", g_rn[i], i < nfound ? "from the bundle" : "built"); EXPECT(what, i < nfound, g_pb_archived - a0);
            snprintf(what, sizeof what, "layout, %s: %s", g_rn[i], i < nfound ? "nothing compiled" : "compiled"); EXPECT(what, i >= nfound, g_pb_built - b0);
            snprintf(what, sizeof what, "layout, %s: %scounted as a layout base from the bundle", g_rn[i], i < nfound ? "" : "not "); EXPECT(what, i < nfound, g_pb_bundle_vd - v0);
        }
    }
    // Stand-ins: the bundle holds the pulling bases of the pairs the R rows draw with (vp with fa, and with fu's integer entry), which the pair list does not name; standins.tsv
    // lists them, the probe finds them (pre_desc_ex), and a draw of such a pair with another layout and colour state than its row's takes its stand-in from the bundle (hybrid_get):
    // nothing compiled. The rows of vertex shaders without a pulling library (va, vi) give none (a pair no row names still misses: hybrid_get's kick, not run here, builds it)
    @autoreleasepool {
        NSString *log = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"pso_offline.log"] encoding:NSUTF8StringEncoding error:nil];
        EXPECT("stand-ins: three for two pairs", 1, [log containsString:[NSString stringWithFormat:@"%d render rows: 3 stand-ins for 2 shader pairs", g_nr]]);
        NSString *sts = [NSString stringWithContentsOfFile:[bundle stringByAppendingPathComponent:@"standins.tsv"] encoding:NSUTF8StringEncoding error:nil];
        EXPECT("stand-ins: standins.tsv", 1, [sts isEqualToString:@"vp\tfa\tmain0\t1\t0\nvp\tfu\tmain0_u\t1\t0\nvp\tfa\tmain0\t4\t1\n"]);
        int sp = 0, sf = 0; NSArray *srows = standin_rows(g_bundle_dir);
        EXPECT("stand-ins: the probe reads three", 3, standin_probe_in(g_arch_bundle, srows, 0, &sp, &sf));
        EXPECT("stand-ins: the probe looks up three", 3, sp);
        EXPECT("stand-ins: the probe finds three", 3, sf);
        EXPECT("stand-ins: not for the other depth mode", 0, (standin_probe_in(g_arch_bundle, srows, 1, &sp, &sf), sf));
        EXPECT("stand-ins: no file, none", 0, standin_rows([root stringByAppendingPathComponent:@"none"]).count + standin_rows(nil).count);
        struct { const char *name; NvShader *fs; uint32_t c0, samples; int a2c; } draws[] = {
            {"stand-in draw, float target", sfa, RGBA8, 1, 0}, {"stand-in draw, integer target", sfu, RGBA8U, 1, 0}, {"stand-in draw, 4 samples, alpha to coverage", sfa, RGBA8, 4, 1}};
        for (unsigned i = 0; i < sizeof draws / sizeof draws[0]; i++) {
            state_reset(); S.nattr = 2; S.ms.a2c = draws[i].a2c;   // another layout than the rows': a Float4 and a Half4 from one stream of 40 bytes
            S.attr[0] = (va_st){.fmt = 0x2E, .offset = 0, .stream = 0}; S.attr[1] = (va_st){.fmt = 0x29, .offset = 32, .stream = 0}; S.stream[0].stride = 40;
            uint32_t cf[8] = {draws[i].c0}; pso_key k; pso_key_fill(&k, svp, draws[i].fs, cf, 0, 0, draws[i].samples, 0);
            uint64_t a0 = g_pb_archived, b0 = g_pb_built, m0 = g_hy_made; char what[160];
            snprintf(what, sizeof what, "%s: a pulling pipeline", draws[i].name); EXPECT(what, 1, hybrid_get(&k, svp, draws[i].fs) != nil);
            snprintf(what, sizeof what, "%s: its base from the bundle", draws[i].name); EXPECT(what, a0 + 1, g_pb_archived);
            snprintf(what, sizeof what, "%s: nothing compiled", draws[i].name); EXPECT(what, b0, g_pb_built);
            snprintf(what, sizeof what, "%s: counted as made", draws[i].name); EXPECT(what, m0 + 1, g_hy_made);
        }
    }
    // A separate output forces one base per compiler invocation, then metal-pack merges both for this GPU.
    NSString *batched = [root stringByAppendingPathComponent:@"batched"];
    if (sh([NSString stringWithFormat:@"python3 %@ --platform macos --gpu %@ --msl %@ --pairs %@/shader_pairs.tsv --out %@ --work %@/batch-work --batch-size 1 > %@/pso_batched.log 2>&1",
            tool, gpu, msl, tables, batched, root, root])) {
        NSString *log = [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"pso_batched.log"] encoding:NSUTF8StringEncoding error:nil];
        fprintf(stderr, "batched pso_offline.py failed:\n%s\n", log.UTF8String); return 1;
    }
    NSString *batchPath = [batched stringByAppendingFormat:@"/%@.mtl4a", gpu];
    EXPECT("batched archive: container accepted", 1, arch_file_ok(batchPath));
    id<MTL4Archive> batchArchive = arch_file_ok(batchPath) ? [g_dev newArchiveWithURL:[NSURL fileURLWithPath:batchPath] error:nil] : nil;
    EXPECT("batched archive: opened", 1, batchArchive != nil);
    EXPECT("batched archive: first group's base", 1, [batchArchive newRenderPipelineStateWithDescriptor:pre_desc(@"v1", @"f1", 0) error:nil] != nil);
    EXPECT("batched archive: second group's base", 1, [batchArchive newRenderPipelineStateWithDescriptor:pre_desc(@"v1", @"f2", 0) error:nil] != nil);
    EXPECT("batched archive: absent depth entry stays absent", 0, [batchArchive newRenderPipelineStateWithDescriptor:pre_desc(@"v1", @"f1", 1) error:nil] != nil);
    // Whether a vertex shader writes the layer is its reflection's layer_out (dmsh_entry.py layer_out), as shader_load takes it, not the layer's name in its library: one with layer
    // entry points of its own (entry_layer, vs_layer_entry) names it there, and its main0 pairs get a base. One whose main0 writes it (layer_out) gets none: its pipelines take an input
    // primitive class
    NSString *vl = @"#include <metal_stdlib>\nusing namespace metal;\nstruct V { float4 p [[position]]; };\nstruct L { float4 p [[position]]; uint l [[render_target_array_index]]; };\n"
        "vertex V main0(uint id [[vertex_id]]) { V o; o.p = float4(float(id & 1), float(id >> 1), 0, 1); return o; }\n"
        "vertex L main0_l(uint id [[vertex_id]]) { L o; o.p = float4(float(id & 1), float(id >> 1), 0, 1); o.l = 1; return o; }\n";
    if (!lib(msl, @"vl_b", vl) && !lib(msl, @"vw_b", vl)) {
        put([msl stringByAppendingPathComponent:@"vl_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"entry_layer\": \"main0_l\", \"vertex_inputs\": []}", DMSH_CHAIN]);
        put([msl stringByAppendingPathComponent:@"vw_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"layer_out\": true, \"vertex_inputs\": []}", DMSH_CHAIN]);
        EXPECT("prebuild: a library with layer entry points of its own gets main0's base", 1, pre_desc(@"vl", @"f1", 0) != nil);
        EXPECT("prebuild: a vertex shader whose main0 writes the layer (layer_out) gets none", 0, pre_desc(@"vw", @"f1", 0) != nil);
    }
    // The border corrections' constant in a pulling library's main0_z, its second function, at the near = 0 depth mode: metal-tt specializes only a library's first function
    // ("cannot find private metadata at offset '8'"), so pso_offline.py specializes it from a library of its own (needs_cut), and the base serves pre_desc through the whole library
    // (Nintendo Switch Sports Resort: 2,401 bases of 124 such libraries had left the archive refused)
    NSString *vb = [NSString stringWithFormat:@"#include <metal_stdlib>\nusing namespace metal;\nconstant bool dm_border_off [[function_constant(%d)]];\n"
        "constant bool dm_border_live = !is_function_constant_defined(dm_border_off) || !dm_border_off;\nstruct V { float4 p [[position]]; };\n"
        "vertex V main0(uint id [[vertex_id]]) { V o; o.p = float4(float(id & 1), float(id >> 1), dm_border_live ? 0.25 : 0, 1); return o; }\n"
        "vertex V main0_z(uint id [[vertex_id]]) { V o; o.p = float4(float(id & 1), float(id >> 1), dm_border_live ? 0.75 : 0.5, 1); return o; }\n", DMSH_BORDER_FC];
    if (!lib(msl, @"vb_bp", vb)) {
        put([msl stringByAppendingPathComponent:@"vb_b.json"], [NSString stringWithFormat:@"{\"chain\": \"%s\", \"entry\": \"main0\", \"entry_z\": \"main0_z\", \"pull\": {}, \"vertex_inputs\": []}", DMSH_CHAIN]);
        put([tables stringByAppendingPathComponent:@"border.tsv"], @"vb\tf1\n");
        NSString *zero = [root stringByAppendingPathComponent:@"zero"];
        int rc = sh([NSString stringWithFormat:@"python3 %@ --platform macos --gpu %@ --msl %@ --pairs %@/border.tsv --out %@ --work %@/zero-work --depth zero --no-compute > %@/pso_zero.log 2>&1",
                     tool, gpu, msl, tables, zero, root, root]);
        EXPECT("border constant in main0_z: pso_offline.py made the archive", 0, rc);
        if (rc) fprintf(stderr, "%s\n", [NSString stringWithContentsOfFile:[root stringByAppendingPathComponent:@"pso_zero.log"] encoding:NSUTF8StringEncoding error:nil].UTF8String);
        NSString *zeroPath = [zero stringByAppendingFormat:@"/%@.mtl4a", gpu];
        id<MTL4Archive> zeroArchive = arch_file_ok(zeroPath) ? [g_dev newArchiveWithURL:[NSURL fileURLWithPath:zeroPath] error:nil] : nil;
        EXPECT("border constant in main0_z: archive opened", 1, zeroArchive != nil);
        EXPECT("border constant in main0_z: the host's specialized base found", 1, [zeroArchive newRenderPipelineStateWithDescriptor:pre_desc(@"vb", @"f1", 1) error:nil] != nil);
        EXPECT("border constant in main0_z: no main0 base", 0, [zeroArchive newRenderPipelineStateWithDescriptor:pre_desc(@"vb", @"f1", 0) error:nil] != nil);
    }
    EXPECT("batched archive: full coverage stamp preserved", 1, [[NSString stringWithContentsOfFile:[batched stringByAppendingPathComponent:@"prebuilt.tsv"] encoding:NSUTF8StringEncoding error:nil]
            isEqualToString:[NSString stringWithContentsOfFile:[bundle stringByAppendingPathComponent:@"prebuilt.tsv"] encoding:NSUTF8StringEncoding error:nil]]);
    // its stamp matches: only the pair with function constants is built here
    reset_counts();
    EXPECT("covered: one pair built on the device", 1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("covered: its base compiled", 1, g_pre_built);
    EXPECT("covered: nothing else", 0, g_pre_archived + g_pre_skipped + g_pre_failed);
    EXPECT("covered: again, nothing to do", -1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    // a draw of a covered pair (its pulling pipeline, as pso_desc_pull makes it) takes the base from the bundle: nothing compiled, nothing captured for the device's own archive
    @autoreleasepool {
        id<MTLLibrary> vl = lib_from_file([msl stringByAppendingPathComponent:@"v1_bp.metallib"], NULL), fl = lib_from_file([msl stringByAppendingPathComponent:@"f1_b.metallib"], NULL);
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = t4_fn(vl, @"main0"); d.fragmentFunction = t4_fn(fl, @"main0");
        d.vertexDescriptor = [MTLVertexDescriptor vertexDescriptor]; d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        uint64_t built0 = g_pb_built, arch0 = g_pb_archived; int new0 = g_arch_new; NSError *err = nil;
        EXPECT("covered draw: a pipeline", 1, pso_build(d, 0, &err) != nil);
        EXPECT("covered draw: its base from the bundle", arch0 + 1, g_pb_archived);
        EXPECT("covered draw: none compiled", built0, g_pb_built);
        EXPECT("covered draw: nothing captured for the device's archive", new0, g_arch_new);
    }
    // the near = 0 depth mode: not what the archive was made for, so the device's prebuild runs, and its main0_z bases are not in the archive
    [NSFileManager.defaultManager removeItemAtPath:[arch stringByAppendingPathComponent:@"prebuilt.tsv"] error:nil];
    reset_counts(); atomic_store(&g_depth_zero, 1);
    EXPECT("other depth mode: every pair", 3, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("other depth mode: every base compiled", 3, g_pre_built);
    atomic_store(&g_depth_zero, 0);
    // other pairs (a second list): the device's prebuild runs and takes the bundled bases it finds
    [NSFileManager.defaultManager removeItemAtPath:[arch stringByAppendingPathComponent:@"prebuilt.tsv"] error:nil];
    put([tables stringByAppendingPathComponent:@"more.tsv"], @"v1\tf2\nv1\tfc\n"); setenv("DM_PSO_PAIRS", [tables stringByAppendingPathComponent:@"more.tsv"].UTF8String, 1);
    reset_counts();
    EXPECT("other pairs: every pair", 3, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
    EXPECT("other pairs: two bases from the bundle", 2, g_pre_archived);
    EXPECT("other pairs: one compiled", 1, g_pre_built);
    unsetenv("DM_PSO_PAIRS");
    // a matching stamp but an archive without the bases (here: one of the device's own files): the probe finds none, so it is not trusted
    @autoreleasepool {
        NSString *txt = [NSString stringWithContentsOfFile:[tables stringByAppendingPathComponent:@"shader_pairs.tsv"] encoding:NSUTF8StringEncoding error:nil];
        NSString *own = [arch stringByAppendingPathComponent:[[[NSFileManager.defaultManager contentsOfDirectoryAtPath:arch error:nil] filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"self BEGINSWITH 'p' AND self ENDSWITH '.mtl4a'"]] firstObject]];
        id<MTL4Archive> real = g_arch_bundle; NSError *e = nil;
        g_arch_bundle = [g_dev newArchiveWithURL:[NSURL fileURLWithPath:own] error:&e];
        EXPECT("archive guard: real serialized archive accepted", 1, arch_file_ok(own));
        { arch_reads rd = {0}; EXPECT("archive reads: serialized archive checked", 1, arch_file_state_rd(own, &rd));
          EXPECT("archive reads: serialized archive, records and libraries", 1, rd.n >= 2);
          EXPECT("archive reads: serialized archive opens", 1, arch_open_read(own, &rd, &e) != nil); }
        EXPECT("probe: another archive opened", 1, g_arch_bundle != nil);
        EXPECT("probe: its bases are not this run's", 0, pso_bundle_covers(pre_parse(txt), pre_stamp(txt, 0), 0, rest, "shader_pairs.tsv"));
        g_arch_bundle = real;
        // the stand-ins' lookups say only what the log needs, so they run in the background (utility QoS) on a line of their own, and the probe line gives their count
        __block int covers = -1;
        NSString *said = stderr_of(root, ^{ covers = pso_bundle_covers(pre_parse(txt), pre_stamp(txt, 0), 0, rest, "shader_pairs.tsv"); dispatch_group_wait(g_standin_bg, DISPATCH_TIME_FOREVER); });
        EXPECT("probe: the bundled archive holds them", 1, covers);
        EXPECT("probe: the stand-ins' count on the probe line", 1, [said containsString:@"; stand-ins for the pairs the prewarm list's R rows draw with: 3 (looked up in the background)"]);
        EXPECT("probe: the stand-ins looked up on a line of their own", 1,
               [said containsString:@"pipeline archive bundled with the app: stand-ins for the pairs the prewarm list's R rows draw with: 3 of 3 probed found ("]);
        EXPECT("probe: three pixel shaders are no cover pairs", 0, atomic_load(&g_bundle_cover_only));
        // A game whose programs have one stage is listed through a cover of one or a few pixel shaders, every vertex shader with the same ones (13 Sentinels: 376 vertex shaders,
        // all with 0ddfcfcdcc3ddf9e; Luigi's Mansion 3: 963, each with the same 4): the probe line says so, and only then may DM_PSO_HYBRID_KICK=0 leave a miss's pulling base
        // unbuilt. A depth-only pair (no pixel key) and a single pair prove nothing either way; a small cross product of several pixel shaders is taken for real pairs (three Unity
        // games list 3 × 2 BNSH variation pairs)
        EXPECT("cover: every pair with one pixel shader", 1, pre_cover_only(pre_parse(@"va\tcov\nvb\tcov\nvc\tcov\n")));
        EXPECT("cover: a depth-only pair does not count", 1, pre_cover_only(pre_parse(@"va\tcov\nvb\tcov\nvd\t\n")));
        EXPECT("cover: one pair is no cover list", 0, pre_cover_only(pre_parse(@"va\tcov\n")));
        EXPECT("cover: a second pixel shader for one vertex shader only", 0, pre_cover_only(pre_parse(@"va\tcov\nvb\tcov\nvb\tf2\n")));
        NSMutableString *cross = [NSMutableString string];
        for (int i = 0; i < 8; i++) [cross appendFormat:@"v%d\tca\nv%d\tcb\n", i, i];
        EXPECT("cover: eight vertex shaders, each with the same two pixel shaders", 1, pre_cover_only(pre_parse(cross)));
        [cross appendString:@"v8\tca\n"];
        EXPECT("cover: one vertex shader without the second", 0, pre_cover_only(pre_parse(cross)));
        EXPECT("cover: a 3 x 2 cross product is taken for real pairs", 0, pre_cover_only(pre_parse(@"va\tca\nva\tcb\nvb\tca\nvb\tcb\nvc\tca\nvc\tcb\n")));
        EXPECT("cover: the test's own pairs", 0, pre_cover_only(pre_parse(txt)));
        EXPECT("kick: on by default, cover pairs or not", 1, hybrid_kick_decide(1, 1) && hybrid_kick_decide(1, 0));
        EXPECT("kick: DM_PSO_HYBRID_KICK=0 with cover pairs only", 0, hybrid_kick_decide(0, 1));
        EXPECT("kick: DM_PSO_HYBRID_KICK=0 does nothing for real pairs", 1, hybrid_kick_decide(0, 0));
        // End to end, from the probe to the switch: a list of cover pairs whose probed pair the archive holds (v1 with f1; the second vertex shader has no library, so the probe
        // skips it) sets the flag, and with DM_PSO_HYBRID_KICK=0 a miss then builds no pulling base; a later probe that refuses the archive (its stamp is not this run's) clears
        // the flag again, and the miss kicks as before
        NSString *cov = @"v1\tf1\nvnolib\tf1\n";
        EXPECT("cover probe: a list of cover pairs", 1, pre_cover_only(pre_parse(cov)));
        put([bundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(cov, 0));
        setenv("DM_PSO_HYBRID_KICK", "0", 1); g_hy_kick_env = -1;
        EXPECT("cover probe: the bundled archive holds its probed pair", 1, pso_bundle_covers(pre_parse(cov), pre_stamp(cov, 0), 0, nil, "shader_pairs.tsv"));
        EXPECT("cover probe: the flag is set", 1, atomic_load(&g_bundle_cover_only));
        EXPECT("cover probe: DM_PSO_HYBRID_KICK=0 skips the kick", 0, hybrid_kick_ok());
        EXPECT("cover probe, stamp refused: no archive", 0, pso_bundle_covers(pre_parse(cov), pre_stamp(cov, 1), 1, nil, "shader_pairs.tsv"));
        EXPECT("cover probe, stamp refused: the flag is cleared", 0, atomic_load(&g_bundle_cover_only));
        EXPECT("cover probe, stamp refused: the miss kicks as before", 1, hybrid_kick_ok());
        unsetenv("DM_PSO_HYBRID_KICK"); g_hy_kick_env = -1;
        put([bundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(txt, 0));
        EXPECT("probe: not for the other depth mode", 0, pso_bundle_covers(pre_parse(txt), pre_stamp(txt, 1), 1, rest, "shader_pairs.tsv"));
        // Raw-pair sampling can hit only ineligible pairs: 0 of 0 lookups must not suppress the device prebuild.
        NSMutableString *sparse = [NSMutableString string];
        for (int i = 0; i < PRE_PROBE; i++) [sparse appendFormat:@"missing%d\tf1\n", i];
        [sparse appendString:@"v1\tf1\n"];
        put([bundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(sparse, 0));
        EXPECT("probe: no eligible sample cannot establish coverage", 0, pso_bundle_covers(pre_parse(sparse), pre_stamp(sparse, 0), 0, nil, "shader_pairs.tsv"));
        put([bundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(txt, 0));
    }
    // cover-only shader_pairs.tsv builds zero bases in pso_prebuild
    @autoreleasepool {
        NSString *sp = [tables stringByAppendingPathComponent:@"shader_pairs.tsv"];
        NSString *saved = [NSString stringWithContentsOfFile:sp encoding:NSUTF8StringEncoding error:nil];
        [NSFileManager.defaultManager removeItemAtPath:[arch stringByAppendingPathComponent:@"prebuilt.tsv"] error:nil];
        put(sp, @"# kind: evidence\n# cover: single-stage padding pairs\nv1\tf1\nv1\tf2\n");
        reset_counts();
        EXPECT("cover-only: pso_prebuild builds nothing", -1, pso_prebuild(1, 1, QOS_CLASS_USER_INITIATED));
        EXPECT("cover-only: zero bases built or archived", 0, g_pre_built + g_pre_archived);
        put(sp, saved);
    }
    // a folder without this GPU's archive, and a file that is no archive (Metal crashed on one, and on a bare Mach-O header too): no archive, no crash
    @autoreleasepool {
        id<MTL4Archive> real = g_arch_bundle; NSString *other = [root stringByAppendingPathComponent:@"other"];
        put([other stringByAppendingPathComponent:@"applegpu_g99x.mtl4a"], @"x");
        NSMutableArray *list = [NSMutableArray array]; g_arch_bundle = nil;
        setenv("DM_PSO_BUNDLE", other.UTF8String, 1); pso_bundle_open(list);
        EXPECT("no file for this GPU: none opened", 0, list.count + (g_arch_bundle != nil));
        put([other stringByAppendingFormat:@"/%@.mtl4a", gpu], @"not an archive");   // Metal's own loadFromURL crashed on it: never handed to Metal
        pso_bundle_open(list);
        EXPECT("not an archive: none opened", 0, list.count + (g_arch_bundle != nil));
        EXPECT("not an archive: refused before Metal", 0, arch_file_ok([other stringByAppendingFormat:@"/%@.mtl4a", gpu]));
        setenv("DM_PSO_BUNDLE", "off", 1); pso_bundle_open(list);
        EXPECT("off: none opened", 0, list.count);
        g_arch_bundle = real;
    }
    // The crash guard: the record beside the device's own archive folder (DM_PSO_ARCHIVE's parent, root here), as pso_bundle_open reads and writes it
    @autoreleasepool {
        id<MTL4Archive> real = g_arch_bundle; NSString *p = [bundle stringByAppendingFormat:@"/%@.mtl4a", gpu], *rec = [root stringByAppendingPathComponent:@"pso_bundle_guard.tsv"];
        NSString *ident = pso_bundle_identity(p); char os[64] = "", txt[2048]; size_t n = sizeof os; sysctlbyname("kern.osversion", os, &n, NULL, 0);
        EXPECT("guard: the archive has an identity", 1, ident.length > 0);
        EXPECT("guard: the identity names this executable's build", 1, ident.length && ![ident hasSuffix:@"host unknown"]);
        EXPECT("guard: two early ends in a row for every game", 2, PSO_GUARD_NEED);
        setenv("DM_PSO_BUNDLE", bundle.UTF8String, 1);
        // planted: two starts in a row with it did not get past their first frames
        psg_format(txt, sizeof txt, PSG_WITH2, os, ident.UTF8String); put(rec, @(txt));
        // the Mac's default: the guard is off, the record is neither read nor written
        unsetenv("DM_PSO_BUNDLE_GUARD");
        NSMutableArray *list = [NSMutableArray array]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("guard: off by default on the Mac, opened", 1, list.count == 1 && g_arch_bundle != nil);
        EXPECT("guard: off by default, the record left as it was", 1, [[NSString stringWithContentsOfFile:rec encoding:NSUTF8StringEncoding error:nil] isEqualToString:@(txt)]);
        // DM_PSO_BUNDLE_GUARD=1, one start that ended early: this start uses it again, watched as the second in a row
        setenv("DM_PSO_BUNDLE_GUARD", "1", 1);
        psg_format(txt, sizeof txt, PSG_WITH, os, ident.UTF8String); put(rec, @(txt));
        [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("guard: one early end, opened again", 1, list.count == 1 && g_arch_bundle != nil);
        EXPECT("guard: one early end, watched as the second in a row", PSG_WITH2, g_psg.armed);
        EXPECT("guard: one early end, on disk", PSG_WITH2, psg_load(&g_psg));
        { int err = 0; psg_pass(&g_psg, &err); }   // that start past its window: the record goes
        EXPECT("guard: the second start past its window, no record", 0, [NSFileManager.defaultManager fileExistsAtPath:rec]);
        // two in a row: this start leaves it out and is watched without it
        psg_format(txt, sizeof txt, PSG_WITH2, os, ident.UTF8String); put(rec, @(txt));
        [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("guard: planted record, archive left out", 0, list.count + (g_arch_bundle != nil));
        EXPECT("guard: watched without it", PSG_WITHOUT, g_psg.armed);
        EXPECT("guard: the record says so before the first frame", PSG_WITHOUT, psg_load(&g_psg));
        // past its window without it (the prepare step's end with no compile of the prebuild under way, then PSG_FRAMES presents): it stays out, start after start
        pso_guard_prepared(); for (int i = 0; i < PSG_FRAMES; i++) pso_guard_frame();
        for (int i = 0; i < 500 && atomic_load(&g_psg.watching); i++) usleep(10000);   // psg_pass runs on a utility queue
        EXPECT("guard: past its window", 0, atomic_load(&g_psg.watching));
        EXPECT("guard: skip on disk", PSG_SKIP, psg_load(&g_psg));
        pso_bundle_open(list);
        EXPECT("guard: skip, archive left out again", 0, list.count + (g_arch_bundle != nil));
        // DM_PSO_BUNDLE_GUARD=0: the record is not read, the archive opens
        setenv("DM_PSO_BUNDLE_GUARD", "0", 1); pso_bundle_open(list); setenv("DM_PSO_BUNDLE_GUARD", "1", 1);
        EXPECT("guard off: opened", 1, list.count == 1 && g_arch_bundle != nil);
        EXPECT("guard off: the record left as it was", PSG_SKIP, psg_load(&g_psg));
        // DM_PSO_BUNDLE_GUARD=off (DM_PSO_BUNDLE's word; false and no too, in any case) is off as well: the old commit read only 0 as off and kept the guard on
        [list removeAllObjects]; g_arch_bundle = nil;
        setenv("DM_PSO_BUNDLE_GUARD", "Off", 1); pso_bundle_open(list); setenv("DM_PSO_BUNDLE_GUARD", "1", 1);
        EXPECT("guard off (off): opened", 1, list.count == 1 && g_arch_bundle != nil);
        EXPECT("guard off (off): the record left as it was", PSG_SKIP, psg_load(&g_psg));
        // no record: the archive opens and the record says a start with it is under way; the background puts it back, the foreground writes it again, the window clears it
        [NSFileManager.defaultManager removeItemAtPath:rec error:nil]; [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("guard: no record, opened", 1, list.count == 1 && g_arch_bundle != nil);
        EXPECT("guard: written before Metal read it", PSG_WITH, psg_load(&g_psg));
        mtl_pso_guard_away(1, 1); EXPECT("guard: in the background, no record", 0, [NSFileManager.defaultManager fileExistsAtPath:rec]);
        mtl_pso_guard_away(1, 0); EXPECT("guard: back, written again", PSG_WITH, psg_load(&g_psg));
        pso_guard_mark("the test's prepare step"); for (int i = 0; i < PSG_FRAMES; i++) pso_guard_frame();
        for (int i = 0; i < 500 && atomic_load(&g_psg.watching); i++) usleep(10000);
        EXPECT("guard: the record cleared after the window", 0, [NSFileManager.defaultManager fileExistsAtPath:rec]);
        // a file the container check refuses never reaches Metal, so it writes no record
        NSString *other = [root stringByAppendingPathComponent:@"other"];
        setenv("DM_PSO_BUNDLE", other.UTF8String, 1); [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("guard: not an archive, none opened", 0, list.count + (g_arch_bundle != nil));
        EXPECT("guard: not an archive, no record", 0, [NSFileManager.defaultManager fileExistsAtPath:rec]);
        setenv("DM_PSO_BUNDLE", bundle.UTF8String, 1);
        // a record of another system build is no record: the archive is tried again
        psg_format(txt, sizeof txt, PSG_SKIP, "0A000", ident.UTF8String); put(rec, @(txt));
        [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("guard: another system build's record, opened", 1, list.count == 1 && g_arch_bundle != nil);
        int err = 0; psg_pass(&g_psg, &err);
        unsetenv("DM_PSO_BUNDLE_GUARD");
        g_arch_bundle = real;
    }
    // The early open (mtl_pso_bundle_preopen, at the game's start once the guest's address space is reserved): an archive of PSO_PREOPEN_MIN or more opens in the background on the system default device, the first
    // submission's pso_bundle_open takes that archive (pso_bundle_join), and the crash guard's record is written by the early open, before Metal reads the file. A smaller one,
    // DM_PSO_PREOPEN=0, a GPU without a file (said once) and a file that is no archive leave the first submission as before
    @autoreleasepool {
        id<MTL4Archive> real = g_arch_bundle; NSString *rec = [root stringByAppendingPathComponent:@"pso_bundle_guard.tsv"];
        setenv("DM_PSO_BUNDLE", bundle.UTF8String, 1); unsetenv("DM_PSO_BUNDLE_GUARD"); unsetenv("DM_PSO_PREOPEN");
        EXPECT("preopen: about a quarter of a GB or more", 256u << 20, (unsigned)PSO_PREOPEN_MIN);
        atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen();
        EXPECT("preopen: a small archive is left to the first submission", 0, atomic_load(&g_bpre.state));
        NSMutableArray *list = [NSMutableArray array]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("preopen: the small archive opened at the first submission", 1, list.count == 1 && g_arch_bundle != nil);
        g_preopen_min = 0; mtl_pso_bundle_preopen();
        EXPECT("preopen: after the first submission opened it, nothing more", 3, atomic_load(&g_bpre.state));
        atomic_store(&g_bpre.state, 0);
        setenv("DM_PSO_PREOPEN", "0", 1); mtl_pso_bundle_preopen(); unsetenv("DM_PSO_PREOPEN");
        EXPECT("preopen: DM_PSO_PREOPEN=0, none", 0, atomic_load(&g_bpre.state));
        mtl_pso_bundle_preopen();
        EXPECT("preopen: under way", 1, atomic_load(&g_bpre.state));
        preopen_wait();
        EXPECT("preopen: opened on the system default device", 1, g_bpre.a != nil && g_bpre.dev == g_dev);
        EXPECT("preopen: the mapping window closed", 0, g_arch_open_n);
        mtl_pso_bundle_preopen();
        EXPECT("preopen: once", 1, atomic_load(&g_bpre.state));
        id<MTL4Archive> early = g_bpre.a;
        [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("preopen: the first submission takes its archive", 1, list.count == 1 && g_arch_bundle == early && early != nil);
        EXPECT("preopen: taken", 2, atomic_load(&g_bpre.state));
        EXPECT("preopen: the bundle's folder", 1, [g_bundle_dir isEqualToString:bundle]);
        EXPECT("preopen: its bases found", 1, [g_arch_bundle newRenderPipelineStateWithDescriptor:pre_desc(@"v1", @"f1", 0) error:nil] != nil);
        // the first submission's wait raises the open to its own QoS: a block queued ahead of the open on its serial queue (the header's 'blocks submitted earlier to that serial
        // queue') runs at user-initiated QoS until a user-interactive thread waits for the open, then at that thread's. A dispatch_group_wait, or a wait for a block of a global
        // queue, raises nothing (checked with a small program at utility QoS under a default waiter: 20 -> 31 for this queue, 20 -> 20 for the other two). Where the system holds
        // every thread of this process at or below the default priority (a QoS clamp: user-initiated and user-interactive both read 31), the raise cannot be seen and is not checked
        {
            EXPECT("preopen: the open's queue is user-initiated", QOS_CLASS_USER_INITIATED, dispatch_queue_get_qos_class(pso_preopen_q(), NULL));
            EXPECT("preopen: the open's queue is its own", 1, !strcmp(dispatch_queue_get_label(pso_preopen_q()), "dm.nvn.pso-preopen"));
            __block _Atomic uint64_t ahead_h = 0; __block _Atomic int go = 0;
            dispatch_async(pso_preopen_q(), ^{
                atomic_store(&ahead_h, thread_self_handle());
                for (int i = 0; i < 1500 && !atomic_load(&go); i++) usleep(2000);
            });
            while (!atomic_load(&ahead_h)) usleep(1000);
            usleep(20000); int before = thread_pri(atomic_load(&ahead_h));
            atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen();   // queued behind it
            EXPECT("preopen: under way behind the block ahead", 1, atomic_load(&g_bpre.state));
            [list removeAllObjects]; g_arch_bundle = nil; atomic_store(&g_ui_handle, 0);
            pthread_t th; pthread_create(&th, NULL, ui_first_submission, (__bridge void *)list);
            while (!atomic_load(&g_ui_handle)) usleep(1000);
            usleep(20000); int waiter = thread_pri(atomic_load(&g_ui_handle)), during = before;
            for (int i = 0; i < 250 && (during = thread_pri(atomic_load(&ahead_h))) <= before; i++) usleep(2000);   // the override comes as the wait begins
            atomic_store(&go, 1); pthread_join(th, NULL);
            if (before > 0 && waiter > before) EXPECT("preopen: raised to the waiting thread's priority while the first submission waits", 1, during >= waiter);
            else printf("t_pso_bundle: the raise of the early open is not checked: a user-interactive thread reads priority %d, the user-initiated open %d (a QoS clamp on this process)\n",
                        waiter, before);
            if (during < waiter) fprintf(stderr, "preopen: priority %d before the wait, %d during it, the waiting thread's %d\n", before, during, waiter);
            EXPECT("preopen: the waiting first submission took the archive", 1, list.count == 1 && g_arch_bundle != nil && atomic_load(&g_bpre.state) == 2);
        }
        // a first submission that comes before the open has begun waits for it all the same (the block counts as not done until it has run)
        {
            dispatch_suspend(pso_preopen_q());
            atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen();
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 50 * NSEC_PER_MSEC), dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ dispatch_resume(pso_preopen_q()); });
            [list removeAllObjects]; g_arch_bundle = nil; uint64_t w0 = bp_now(); pso_bundle_open(list);
            EXPECT("preopen: the first submission waited for an open not begun yet", 1, bp_now() - w0 >= 40000000ull && list.count == 1 && g_arch_bundle != nil);
        }
        // windows that overlap (the early open and pso4_init's opens) restore NSData's method once, after the last
        Method m = arch_read_method(); IMP before = method_getImplementation(m);
        arch_open_begin(); arch_open_begin(); EXPECT("window: open", 1, method_getImplementation(m) == (IMP)arch_read_mapped);
        arch_open_end(); EXPECT("window: still open after the first end", 1, method_getImplementation(m) == (IMP)arch_read_mapped);
        arch_open_end(); EXPECT("window: closed after the last", 1, method_getImplementation(m) == before);
        arch_open_end(); EXPECT("window: an end too many changes nothing", 1, method_getImplementation(m) == before && g_arch_open_n == 0);
        // a GPU without a file: said by the early open, and the first submission does not look again
        NSString *none = [root stringByAppendingPathComponent:@"none"]; [NSFileManager.defaultManager createDirectoryAtPath:none withIntermediateDirectories:YES attributes:nil error:nil];
        setenv("DM_PSO_BUNDLE", none.UTF8String, 1); atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen();
        EXPECT("preopen: no file for this GPU, nothing under way", 2, atomic_load(&g_bpre.state));
        [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("preopen: no file for this GPU, none opened", 0, list.count + (g_arch_bundle != nil));
        // a file that is no archive: refused in the background, before Metal and without a record; the first submission takes nothing
        setenv("DM_PSO_BUNDLE_GUARD", "1", 1); [NSFileManager.defaultManager removeItemAtPath:rec error:nil];
        setenv("DM_PSO_BUNDLE", [root stringByAppendingPathComponent:@"other"].UTF8String, 1); atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen();
        preopen_wait();
        [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("preopen: not an archive, none opened", 0, list.count + (g_arch_bundle != nil));
        EXPECT("preopen: not an archive, no record", 0, [NSFileManager.defaultManager fileExistsAtPath:rec]);
        // the crash guard: the early open begins it (the record is written before Metal reads the file: test_pso_guard_wiring checks the order) and the start is watched as one
        // with the archive; once Metal's open returned, the record is as the start's end would leave it until the first submission takes the archive and writes it again, so an
        // early end in the game's own start is not counted
        setenv("DM_PSO_BUNDLE", bundle.UTF8String, 1); atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen();
        preopen_wait();
        EXPECT("preopen, guard: watched", PSG_WITH, g_psg.armed);
        EXPECT("preopen, guard: set aside until the first submission", PSG_AWAY_IDLE, g_psg.away);
        EXPECT("preopen, guard: until then no record, as before this start", 0, [NSFileManager.defaultManager fileExistsAtPath:rec]);
        [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
        EXPECT("preopen, guard: taken", 1, list.count == 1 && g_arch_bundle != nil);
        EXPECT("preopen, guard: the first submission writes the record", PSG_WITH, psg_load(&g_psg));
        EXPECT("preopen, guard: no longer set aside", 0, g_psg.away);
        { int err = 0; psg_pass(&g_psg, &err); }
        EXPECT("preopen, guard: past its window, no record", 0, [NSFileManager.defaultManager fileExistsAtPath:rec]);
        {   // one start with it ended early: the record stays as found until the first submission, which writes the second in a row
            NSString *ident = pso_bundle_identity([bundle stringByAppendingFormat:@"/%@.mtl4a", g_dev.architecture.name]); char os[64] = "", txt[2048]; size_t n = sizeof os;
            sysctlbyname("kern.osversion", os, &n, NULL, 0);
            psg_format(txt, sizeof txt, PSG_WITH, os, ident.UTF8String); put(rec, @(txt));
            atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen(); preopen_wait();
            EXPECT("preopen, guard, one ended early: watched as the second in a row", PSG_WITH2, g_psg.armed);
            EXPECT("preopen, guard, one ended early: until the first submission, as found", PSG_WITH, psg_load(&g_psg));
            [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
            EXPECT("preopen, guard, one ended early: taken", 1, list.count == 1 && g_arch_bundle != nil);
            EXPECT("preopen, guard, one ended early: the second in a row from the first submission", PSG_WITH2, psg_load(&g_psg));
            { int err = 0; psg_pass(&g_psg, &err); }
            // two in a row: the early open leaves the archive out, and that start is watched from the first submission as well
            psg_format(txt, sizeof txt, PSG_WITH2, os, ident.UTF8String); put(rec, @(txt));
            atomic_store(&g_bpre.state, 0); mtl_pso_bundle_preopen(); preopen_wait();
            EXPECT("preopen, guard, two in a row: left out, watched without it", PSG_WITHOUT, g_psg.armed);
            EXPECT("preopen, guard, two in a row: until the first submission, as found", PSG_WITH2, psg_load(&g_psg));
            [list removeAllObjects]; g_arch_bundle = nil; pso_bundle_open(list);
            EXPECT("preopen, guard, two in a row: none taken", 0, list.count + (g_arch_bundle != nil));
            EXPECT("preopen, guard, two in a row: without it from the first submission", PSG_WITHOUT, psg_load(&g_psg));
            { int err = 0; psg_pass(&g_psg, &err); }
            [NSFileManager.defaultManager removeItemAtPath:rec error:nil];
        }
        unsetenv("DM_PSO_BUNDLE_GUARD"); setenv("DM_PSO_BUNDLE", bundle.UTF8String, 1);
        g_preopen_min = PSO_PREOPEN_MIN; atomic_store(&g_bpre.state, 0); g_arch_bundle = real;
    }
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    printf("t_pso_bundle: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
