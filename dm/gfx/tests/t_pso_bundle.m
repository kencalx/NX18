// The pipeline archive made offline and bundled with the app (DM_PSO_BUNDLE, pso_bundle_open / pso_bundle_covers in nvn_mtl.m), made here as build_ipa.sh makes it: tiny shader
// libraries and their reflection, a pair list, then dm/gfx/tools/pso_offline.py (metal-tt) for this Mac's GPU. Checks: the archive for this GPU opens and comes first among the files of
// bases without a vertex layout; with a matching stamp the prebuild builds only the pairs left to the device (a function with constants) and takes nothing from the compiler otherwise,
// and a draw of a covered pair takes its base from the bundle and captures nothing for the device's own archive;
// a stamp of another depth mode or other pairs runs the device's prebuild, which still takes the bundled bases it finds; an archive whose bases the probe does not find is not trusted;
// a folder without this GPU's file and a file that is no archive leave no archive; the compute shaders of the shader map have their pipelines in the archive (cps_new: nothing
// built), and a shader with function constants or not in the map is built as before; the task / mesh pipelines of the prewarm list's M rows (the host's own keys) are in the archive,
// with a task shader and with the mesh shader's own object function, blended and with a write mask cut to the pixel shader's output map, and with no colour target (mtk_build: from the bundle, nothing built
// or captured), and one with a pixel shader that declares function constants or with no pixel shader is built as before; the layout bases of the prewarm list's R rows (keys the
// engine writes, pso_key_fill / pso_skey_from: float, half, instanced, constant and CPU-converted (I2F) streams, 4 samples with alpha to coverage, an integer input fed its own class
// and through its shadow inputs, integer / mixed / dual-source fragments, depth only) come from the bundle through plain lookups (pso_build(pso_desc(...)): nothing compiled), and
// a row with a pixel shader with function constants or an attribute beyond its constant stream's stride (metal-tt refuses it) is built as before.
// Without metal-tt (no Metal toolchain) it says so and passes
#include "../nvn/nvn_mtl.m"
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
static void reset_counts(void) { g_pre_done = g_pre_built = g_pre_archived = g_pre_skipped = g_pre_failed = 0; }
// The R rows of the prewarm list as a draw records them (pso_key_fill from the state, pso_skey_from, pso_skey_hex), kept for the lookups: what the vertex layout and the colour
// targets are, attribute 0 a Float4 from stream 0 and attribute 1 as the row says
enum { NR = 16 };
static pso_key g_rk[NR]; static NvShader *g_rv[NR], *g_rf[NR]; static const char *g_rn[NR]; static int g_nr;
static NSMutableString *g_rrows;
static void rrow(const char *name, NvShader *vs, NvShader *fs, int a1fmt, int a1off, int a1st, uint32_t s0, uint32_t s1, uint32_t d1, uint32_t c0, uint32_t c1, uint32_t samples, int a2c, int src1) {
    state_reset(); S.nattr = 2;
    S.attr[0] = (va_st){.fmt = 0x2E, .offset = 0, .stream = 0}; S.attr[1] = (va_st){.fmt = (uint32_t)a1fmt, .offset = (uint32_t)a1off, .stream = (uint32_t)a1st};
    S.stream[0].stride = s0; if (a1st) { S.stream[a1st].stride = s1; S.stream[a1st].divisor = d1; }
    S.ms.a2c = a2c;
    if (src1) { S.color.blend_en = 1; S.blend[0].src_rgb = S.blend[0].src_a = NVN_BLEND_FUNC_ONE; S.blend[0].dst_rgb = S.blend[0].dst_a = NVN_BLEND_FUNC_ONE_MINUS_SRC1_COLOR; }
    uint32_t cf[8] = {c0, c1};
    pso_key_fill(&g_rk[g_nr], vs, fs, cf, c0 || c1 ? 0 : MTLPixelFormatDepth32Float, 0, samples, 0);
    pso_skey sk; char hex[sizeof sk * 2 + 1]; pso_skey_from(&g_rk[g_nr], vs, fs, 0, NULL, &sk); pso_skey_hex(&sk, hex);
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
    // declaration at 16, its signed one at 17, dmsh_vin.py); pixel shaders with an integer (entry_u), a mixed (entry_m, output 1 an integer) and a dual-source (entry_d) entry point
    NSString *hd = @"#include <metal_stdlib>\nusing namespace metal;\nstruct VO { float4 p [[position]]; };\n";
    NSString *va = [hd stringByAppendingString:@"struct VI { float4 p [[attribute(0)]]; float2 uv [[attribute(1)]]; };\n"
        "vertex VO main0(VI i [[stage_in]]) { VO o; o.p = i.p + float4(i.uv, 0, 0); return o; }\nvertex VO main0_z(VI i [[stage_in]]) { VO o; o.p = i.p * 0.5 + float4(i.uv, 0, 0); return o; }\n"];
    NSString *vi = [hd stringByAppendingString:@"struct VI { float4 p [[attribute(0)]]; uint4 m [[attribute(1)]]; };\nvertex VO main0(VI i [[stage_in]]) { VO o; o.p = i.p + float4(i.m); return o; }\n"];
    NSString *vib = [hd stringByAppendingString:@"struct VI { float4 p [[attribute(0)]]; uint4 m [[attribute(1)]]; float4 m_vf [[attribute(16)]]; int4 m_vo [[attribute(17)]]; };\n"
        "vertex VO main0(VI i [[stage_in]]) { uint4 m = i.m | as_type<uint4>(i.m_vf) | as_type<uint4>(i.m_vo); VO o; o.p = i.p + float4(m); return o; }\n"];
    NSString *fu = @"#include <metal_stdlib>\nusing namespace metal;\nfragment float4 main0() { return float4(1); }\nfragment uint4 main0_u() { return uint4(1); }\n";
    NSString *two = @"#include <metal_stdlib>\nusing namespace metal;\nstruct O { float4 c0 [[color(0)]]; float4 c1 [[color(1)]]; };\nfragment O main0() { return O{float4(1), float4(0.5)}; }\n";
    NSString *fm = [two stringByAppendingString:@"struct OM { float4 c0 [[color(0)]]; uint4 c1 [[color(1)]]; };\nfragment OM main0_m() { return OM{float4(1), uint4(2)}; }\n"];
    NSString *fd = [two stringByAppendingString:@"struct OD { float4 c0 [[color(0), index(0)]]; float4 c1 [[color(0), index(1)]]; };\nfragment OD main0_d() { return OD{float4(1), float4(0.5)}; }\n"];
    if (lib(msl, @"va_b", va) || lib(msl, @"vi_b", vi) || lib(msl, @"vi_bv", vib) || lib(msl, @"fa_b", [NSString stringWithFormat:f, 1, 1]) || lib(msl, @"fu_b", fu) ||
        lib(msl, @"fm_b", fm) || lib(msl, @"fd_b", fd)) { fprintf(stderr, "t_pso_bundle: the layout fixture libraries did not compile\n"); return 1; }
    put([msl stringByAppendingPathComponent:@"va_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"vs", @", \"entry_z\": \"main0_z\", \"vertex_inputs\": [{\"location\": 0, \"msl_type\": \"float4\"}, {\"location\": 1, \"msl_type\": \"float2\"}]"]);
    put([msl stringByAppendingPathComponent:@"vi_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"vs", @", \"vertex_inputs\": [{\"location\": 0, \"msl_type\": \"float4\"}, {\"location\": 1, \"msl_type\": \"uint4\"}], "
                                                            "\"vin\": {\"shadow\": [{\"location\": 1, \"float\": 16, \"sint\": 17}]}"]);
    put([msl stringByAppendingPathComponent:@"fa_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"raster\": {\"colors\": [0]}"]);
    put([msl stringByAppendingPathComponent:@"fu_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"entry_u\": \"main0_u\", \"raster\": {\"colors\": [0]}"]);
    put([msl stringByAppendingPathComponent:@"fm_b.json"], [NSString stringWithFormat:refl, DMSH_CHAIN, @"ps", @", \"entry_m\": \"main0_m\", \"uint_mask_m\": 2, \"raster\": {\"colors\": [0, 1]}"]);
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
    rrow("I2F format (CPU conversion slot)", sva, sfa, 0x57, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("4 samples, alpha to coverage", sva, sfa, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 4, 1, 0);
    rrow("integer input, own class", svi, sfa, 0x27, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("integer input, shadow input", svi, sfa, 0x11, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("integer input, other sign: shadow", svi, sfa, 0x15, 16, 0, 20, 0, 0, RGBA8, 0, 1, 0, 0);
    rrow("integer fragment", sva, sfu, 0x16, 16, 0, 24, 0, 0, RGBA8U, 0, 1, 0, 0);
    rrow("mixed fragment", sva, sfm, 0x16, 16, 0, 24, 0, 0, RGBA8, RGBA8U, 1, 0, 0);
    rrow("dual-source fragment", sva, sfd, 0x16, 16, 0, 24, 0, 0, RGBA8, 0, 1, 0, 1);
    rrow("depth only", sva, nil, 0x16, 16, 0, 24, 0, 0, 0, 0, 1, 0, 0);
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
            id<MTLRenderPipelineState> ps = pso_build(pso_desc(&g_rk[i], g_rv[i], g_rf[i], nil, 0), !g_rk[i].border, &err);   // off as the draw takes it
            snprintf(what, sizeof what, "layout, %s: a pipeline", g_rn[i]); EXPECT(what, 1, ps != nil);
            if (!ps) fprintf(stderr, "  %s: %s\n", g_rn[i], err.localizedDescription.UTF8String);
            snprintf(what, sizeof what, "layout, %s: its base %s", g_rn[i], i < nfound ? "from the bundle" : "built"); EXPECT(what, i < nfound, g_pb_archived - a0);
            snprintf(what, sizeof what, "layout, %s: %s", g_rn[i], i < nfound ? "nothing compiled" : "compiled"); EXPECT(what, i >= nfound, g_pb_built - b0);
            snprintf(what, sizeof what, "layout, %s: %scounted as a layout base from the bundle", g_rn[i], i < nfound ? "" : "not "); EXPECT(what, i < nfound, g_pb_bundle_vd - v0);
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
        EXPECT("probe: another archive opened", 1, g_arch_bundle != nil);
        EXPECT("probe: its bases are not this run's", 0, pso_bundle_covers(pre_parse(txt), pre_stamp(txt, 0), 0, rest));
        g_arch_bundle = real;
        EXPECT("probe: the bundled archive holds them", 1, pso_bundle_covers(pre_parse(txt), pre_stamp(txt, 0), 0, rest));
        EXPECT("probe: not for the other depth mode", 0, pso_bundle_covers(pre_parse(txt), pre_stamp(txt, 1), 1, rest));
        // Raw-pair sampling can hit only ineligible pairs: 0 of 0 lookups must not suppress the device prebuild.
        NSMutableString *sparse = [NSMutableString string];
        for (int i = 0; i < PRE_PROBE; i++) [sparse appendFormat:@"missing%d\tf1\n", i];
        [sparse appendString:@"v1\tf1\n"];
        put([bundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(sparse, 0));
        EXPECT("probe: no eligible sample cannot establish coverage", 0, pso_bundle_covers(pre_parse(sparse), pre_stamp(sparse, 0), 0, nil));
        put([bundle stringByAppendingPathComponent:@"prebuilt.tsv"], pre_stamp(txt, 0));
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
    [NSFileManager.defaultManager removeItemAtPath:root error:nil];
    printf("t_pso_bundle: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
