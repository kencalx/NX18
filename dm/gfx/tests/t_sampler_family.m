// Sampler settings Metal's feature set tables give to Apple10 GPUs and later only (LOD bias, min / max reduction), probed on this Mac's GPU, and what a sampler of the opaque black border colour
// returns from A1BGR5Unorm and ABGR4Unorm textures, which the tables call incompatible with it on every family. The probes go through the production samplers (mtl_reg_samp, samp_by_id), so
// samp_diag's lines print here as on a device. The iPad Pro M4 is Apple9, and an active probe there could stop every game if Apple9 aborts on these settings: it runs here instead. Each probe
// runs in a process of its own (this binary with --probe), killed after PROBE_S seconds, so a validation layer abort (MTL_DEBUG_LAYER=1) or a hang is reported and the other probes still run.
// On an Apple10 GPU or later a bias or reduction that is not applied fails the test; below Apple10 the findings are reported and it passes. The controls (no bias, an average, an RGBA8Unorm
// border) and samp_diag's border flag must hold on every GPU
#include "../nvn/nvn_mtl.m"
#include <errno.h>
#include <limits.h>
#include <poll.h>
#include <signal.h>
#include <spawn.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>
extern char **environ;
uint64_t g_t0_ns;
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: "); fprintf(stderr, __VA_ARGS__); fprintf(stderr, "\n"); } } while (0)
enum { PROBE_S = 30 };

// ---------- The probes (child process): one line "RESULT ..." on stdout, MLOG and the validation layer on stderr ----------
static const char *const SRC =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 p [[position]]; };\n"
    "vertex V vs(uint i [[vertex_id]]) { V v; v.p = float4(float2((i << 1) & 2, i & 2) * 2 - 1, 0, 1); return v; }\n"
    // 8x8 target, 16x16 texture: two texels a pixel, so the implicit LOD is 1; .g: the same sample at an explicit LOD of 1
    "fragment float4 fs(V in [[stage_in]], texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]]) { float2 uv = in.p.xy / 8; return float4(t.sample(s, uv).r, t.sample(s, uv, level(1)).r, 0, 1); }\n"
    "kernel void kr(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float *o [[buffer(0)]]) { o[0] = t.sample(s, float2(0.5), level(0)).r; }\n"
    "kernel void kb(texture2d<float> t [[texture(0)]], sampler s [[sampler(0)]], device float4 *o [[buffer(0)]]) {\n"
    "    o[0] = t.sample(s, float2(-0.75, 0.5), level(0)); o[1] = t.sample(s, float2(0.5, 1.75), level(0)); o[2] = t.sample(s, float2(0.5, 0.5), level(0)); }\n";
static id<MTLLibrary> probe_lib(void) {
    NSError *e = nil; id<MTLLibrary> l = [g_dev newLibraryWithSource:@(SRC) options:nil error:&e];
    if (!l) { printf("RESULT error the probe shaders do not compile: %s\n", e.localizedDescription.UTF8String); exit(0); }
    return l;
}
static id<MTLSamplerState> prod_sampler(int sid, const samp_par *sp, int *diag) {   // the production sampler of these parameters, and samp_diag's flags for it
    mtl_reg_samp(sid, sp);
    os_unfair_lock_lock(&g_rmu); id<MTLSamplerState> s = samp_by_id(sid); *diag = sid < g_nsdiag ? g_sdiag[sid] : -1; os_unfair_lock_unlock(&g_rmu);
    return s;
}
static id<MTLTexture> tex_new(MTLPixelFormat pf, NSUInteger w, BOOL mips) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:w mipmapped:mips];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    return [g_dev newTextureWithDescriptor:d];
}
static int cb_ok(id<MTLCommandBuffer> cb) {
    if (cb.status == MTLCommandBufferStatusCompleted) return 1;
    printf("RESULT error the GPU work ended with status %lu: %s\n", (unsigned long)cb.status, cb.error ? cb.error.localizedDescription.UTF8String : "no error"); return 0;
}
static const uint8_t LV[5] = { 0, 64, 128, 191, 255 };   // level L reads red L / 4
// LOD bias: a 16x16 texture of five levels, each one colour, sampled at an implicit LOD of 1 with a nearest mip filter: level 1 + bias if the bias is applied, level 1 if it is ignored
static void probe_bias(float bias) {
    samp_par sp = {0}; sp.magf = 1; sp.minf = 3; sp.lod_max = 16; sp.lod_bias = bias; sp.aniso = 1;   // linear, nearest mip; clamp to edge
    int diag; id<MTLSamplerState> s = prod_sampler(21, &sp, &diag);
    if (!s) { printf("RESULT nil -1 -1 %d\n", diag); return; }
    id<MTLTexture> t = tex_new(MTLPixelFormatRGBA8Unorm, 16, YES);
    for (NSUInteger l = 0; l < t.mipmapLevelCount && l < 5; l++) {
        NSUInteger w = MAX(16u >> l, 1u); uint32_t px[256]; for (NSUInteger i = 0; i < w * w; i++) px[i] = LV[l] | 0xff000000u;
        [t replaceRegion:MTLRegionMake2D(0, 0, w, w) mipmapLevel:l withBytes:px bytesPerRow:4 * w];
    }
    id<MTLLibrary> lib = probe_lib(); NSError *e = nil;
    MTLRenderPipelineDescriptor *pd = [MTLRenderPipelineDescriptor new]; pd.vertexFunction = [lib newFunctionWithName:@"vs"]; pd.fragmentFunction = [lib newFunctionWithName:@"fs"];
    pd.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA32Float;
    id<MTLRenderPipelineState> ps = [g_dev newRenderPipelineStateWithDescriptor:pd error:&e];
    if (!ps) { printf("RESULT error no render pipeline: %s\n", e.localizedDescription.UTF8String); return; }
    MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA32Float width:8 height:8 mipmapped:NO];
    rd.usage = MTLTextureUsageRenderTarget; rd.storageMode = MTLStorageModePrivate; id<MTLTexture> rt = [g_dev newTextureWithDescriptor:rd];
    MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = rt; rp.colorAttachments[0].loadAction = MTLLoadActionClear; rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(-1, -1, -1, -1);
    id<MTLBuffer> out = [g_dev newBufferWithLength:8 * 8 * 16 options:MTLResourceStorageModeShared];
    if (!rt || !out) { printf("RESULT error no render target or read-back buffer\n"); return; }
    id<MTLCommandBuffer> cb = q_cb(); id<MTLRenderCommandEncoder> re = [cb renderCommandEncoderWithDescriptor:rp];
    [re setRenderPipelineState:ps]; [re setFragmentTexture:t atIndex:0]; [re setFragmentSamplerState:s atIndex:0];
    [re drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3]; [re endEncoding];
    id<MTLBlitCommandEncoder> b = [cb blitCommandEncoder];
    [b copyFromTexture:rt sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1) toBuffer:out destinationOffset:0 destinationBytesPerRow:8 * 16
        destinationBytesPerImage:8 * 8 * 16 options:MTLBlitOptionNone];
    [b endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (!cb_ok(cb)) return;
    const float *f = out.contents; int same = 1; for (int i = 1; i < 64; i++) same &= fabsf(f[4 * i] - f[0]) < 1e-3f && fabsf(f[4 * i + 1] - f[1]) < 1e-3f;
    if (!same) { printf("RESULT error the pixels differ (first %g,%g)\n", f[0], f[1]); return; }
    printf("RESULT ok %ld %ld %d\n", lroundf(f[0] * 4), lroundf(f[1] * 4), diag);
}
// Reduction: a 2x2 R8Unorm texture of 0.2, 0.4, 0.6, 0.8 sampled bilinearly at its centre, where each texel weighs a quarter: 0.5 averaged, 0.2 with min, 0.8 with max
static void probe_reduction(int reduction) {
    samp_par sp = {0}; sp.magf = 1; sp.minf = 1; sp.reduction = (uint8_t)reduction; sp.aniso = 1;   // linear, no mips (samp_by_id turns a reduction's mip filter linear)
    int diag; id<MTLSamplerState> s = prod_sampler(22, &sp, &diag);
    if (!s) { printf("RESULT nil -1 %d\n", diag); return; }
    id<MTLTexture> t = tex_new(MTLPixelFormatR8Unorm, 2, NO); const uint8_t px[4] = { 51, 102, 153, 204 };
    [t replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:px bytesPerRow:2];
    id<MTLFunction> fn = [probe_lib() newFunctionWithName:@"kr"]; if (!fn) { printf("RESULT error no function kr\n"); return; }
    NSError *e = nil; id<MTLComputePipelineState> p = [g_dev newComputePipelineStateWithFunction:fn error:&e];
    if (!p) { printf("RESULT error no compute pipeline: %s\n", e.localizedDescription.UTF8String); return; }
    id<MTLBuffer> out = [g_dev newBufferWithLength:16 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:p]; [ce setTexture:t atIndex:0]; [ce setSamplerState:s atIndex:0]; [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (!cb_ok(cb)) return;
    printf("RESULT ok %.4f %d\n", ((const float *)out.contents)[0], diag);
}
// Opaque black border, nearest, clamp to border, sampled left of and below the texture and at its centre; every texel is all ones (1, 1, 1, 1)
static void probe_border(MTLPixelFormat pf) {
    samp_par sp = {0}; sp.ws = sp.wt = sp.wr = 5; sp.border[3] = 1; sp.aniso = 1;   // NVN clamp to border, (0, 0, 0, 1): Metal's opaque black (nvn_border), no twin
    int diag; id<MTLSamplerState> s = prod_sampler(23, &sp, &diag);
    if (!s) { printf("RESULT nil %d\n", diag); return; }
    id<MTLTexture> t = tex_new(pf, 2, NO);
    if (!t) { printf("RESULT error no texture of Metal format %lu\n", (unsigned long)pf); return; }
    const uint32_t ones[4] = { ~0u, ~0u, ~0u, ~0u }; [t replaceRegion:MTLRegionMake2D(0, 0, 2, 2) mipmapLevel:0 withBytes:ones bytesPerRow:2 * (pf == MTLPixelFormatRGBA8Unorm ? 4 : 2)];
    id<MTLFunction> fn = [probe_lib() newFunctionWithName:@"kb"]; if (!fn) { printf("RESULT error no function kb\n"); return; }
    NSError *e = nil; id<MTLComputePipelineState> p = [g_dev newComputePipelineStateWithFunction:fn error:&e];
    if (!p) { printf("RESULT error no compute pipeline: %s\n", e.localizedDescription.UTF8String); return; }
    id<MTLBuffer> out = [g_dev newBufferWithLength:48 options:MTLResourceStorageModeShared];
    id<MTLCommandBuffer> cb = q_cb(); id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    [ce setComputePipelineState:p]; [ce setTexture:t atIndex:0]; [ce setSamplerState:s atIndex:0]; [ce setBuffer:out offset:0 atIndex:0];
    [ce dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)]; [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (!cb_ok(cb)) return;
    const float *f = out.contents; printf("RESULT ok"); for (int i = 0; i < 12; i++) printf(" %.3f", f[i]); printf(" %d\n", diag);
}
static int probe(const char *name) {
    alarm(PROBE_S + 10);   // should the parent be gone: it kills a probe at PROBE_S itself
    mtl_init();
    if (!strcmp(name, "bias0")) probe_bias(0); else if (!strcmp(name, "bias+1")) probe_bias(1); else if (!strcmp(name, "bias-1")) probe_bias(-1);
    else if (!strcmp(name, "avg")) probe_reduction(0); else if (!strcmp(name, "min")) probe_reduction(1); else if (!strcmp(name, "max")) probe_reduction(2);
    else if (!strcmp(name, "border-abgr4")) probe_border(MTLPixelFormatABGR4Unorm); else if (!strcmp(name, "border-a1bgr5")) probe_border(MTLPixelFormatA1BGR5Unorm);
    else if (!strcmp(name, "border-rgba8")) probe_border(MTLPixelFormatRGBA8Unorm);
    else printf("RESULT error no probe %s\n", name);
    fflush(stdout); return 0;
}

// ---------- The parent: runs each probe, judges it ----------
static double mono_s(void) { struct timespec ts; clock_gettime(CLOCK_MONOTONIC, &ts); return ts.tv_sec + ts.tv_nsec * 1e-9; }
// 0: the probe ran (res: what follows RESULT); 1: it stopped without a result (res: why); 2: it hung and was killed
static int run_probe(const char *name, char *res, size_t n) {
    char self[PATH_MAX]; uint32_t sn = sizeof self; if (_NSGetExecutablePath(self, &sn)) { snprintf(res, n, "no executable path"); return 1; }
    int fd[2]; if (pipe(fd)) { snprintf(res, n, "pipe: %s", strerror(errno)); return 1; }
    posix_spawn_file_actions_t fa; posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_adddup2(&fa, fd[1], 1); posix_spawn_file_actions_addclose(&fa, fd[0]); posix_spawn_file_actions_addclose(&fa, fd[1]);
    char *av[] = { self, "--probe", (char *)name, NULL }; pid_t pid; int e = posix_spawn(&pid, self, &fa, NULL, av, environ);
    posix_spawn_file_actions_destroy(&fa); close(fd[1]);
    if (e) { close(fd[0]); snprintf(res, n, "cannot start: %s", strerror(e)); return 1; }
    char buf[4096]; size_t len = 0; double t0 = mono_s(); int st = 0, done = 0;
    for (;;) {   // its output until it closes it, within the deadline
        double left = PROBE_S - (mono_s() - t0); if (left <= 0) break;
        struct pollfd p = { fd[0], POLLIN, 0 }; int r = poll(&p, 1, (int)(left * 1000) + 1);
        if (r < 0 && errno == EINTR) continue;
        if (r <= 0) break;
        if (len == sizeof buf - 1) { memmove(buf, buf + sizeof buf / 2, len - sizeof buf / 2); len -= sizeof buf / 2; }   // keeps reading (a closed pipe would stop the probe): the result is its last line
        ssize_t k = read(fd[0], buf + len, sizeof buf - 1 - len);
        if (k < 0 && errno == EINTR) continue;
        if (k <= 0) break;
        len += (size_t)k;
    }
    close(fd[0]); buf[len] = 0;
    for (;;) { pid_t w = waitpid(pid, &st, WNOHANG); if (w == pid) { done = 1; break; } if (w < 0 && errno != EINTR) break; if (mono_s() - t0 > PROBE_S) break; usleep(10000); }
    if (!done) { kill(pid, SIGKILL); waitpid(pid, &st, 0); snprintf(res, n, "hung: killed after %d s", (int)PROBE_S); return 2; }
    if (WIFSIGNALED(st)) { snprintf(res, n, "stopped by signal %d (%s): an abort is the validation layer or Metal refusing it, see the lines above", WTERMSIG(st), strsignal(WTERMSIG(st))); return 1; }
    char *r = NULL; for (char *q = strstr(buf, "RESULT "); q; q = strstr(q + 1, "RESULT ")) r = q;
    if (!WIFEXITED(st) || WEXITSTATUS(st) || !r) { snprintf(res, n, "exit status %d with no result", WIFEXITED(st) ? WEXITSTATUS(st) : -1); return 1; }
    r += 7; char *nl = strchr(r, '\n'); if (nl) *nl = 0;
    snprintf(res, n, "%s", r); return 0;
}
static int g_a10;   // the GPU is Apple10 or later: bias and reduction must be applied
// LOD bias of `bias`: "applied", "ignored" or what happened; the explicit-LOD read and samp_diag's census flag are checked or reported
static int judge_bias(const char *name, float bias) {
    char res[512]; int rc = run_probe(name, res, sizeof res); long li = -1, le = -1; int diag = -1; char word[16] = "";
    if (!rc && sscanf(res, "%15s %ld %ld %d", word, &li, &le, &diag) == 4 && !strcmp(word, "nil")) { printf("t_sampler_family: LOD bias %+g: Metal made no sampler state\n", bias); return 0; }
    if (rc || strcmp(word, "ok")) { printf("t_sampler_family: LOD bias %+g: %s\n", bias, res); return 0; }
    long want = 1 + lroundf(bias); const char *v = li == want ? "applied" : li == 1 ? "ignored" : "neither";
    printf("t_sampler_family: LOD bias %+g: %s (implicit LOD 1 read level %ld, %ld expected; an explicit LOD of 1 read level %ld)\n", bias, v, li, want, le);
    if (bias != 0) CHECK(!!(diag & SD_A10) == !g_a10, "samp_diag's census flag for an LOD bias is %d on a GPU %s Apple10", !!(diag & SD_A10), g_a10 ? "of" : "below");
    return li == want;
}
static int judge_reduction(const char *name, int reduction) {
    static const float want[3] = { 0.5f, 0.2f, 0.8f }; static const char *const what[3] = { "average (control)", "min reduction", "max reduction" };
    char res[512]; int rc = run_probe(name, res, sizeof res); float v = -1; int diag = -1; char word[16] = "";
    if (!rc && sscanf(res, "%15s %f %d", word, &v, &diag) == 3 && !strcmp(word, "nil")) { printf("t_sampler_family: %s: Metal made no sampler state\n", what[reduction]); return 0; }
    if (rc || strcmp(word, "ok")) { printf("t_sampler_family: %s: %s\n", what[reduction], res); return 0; }
    int ok = fabsf(v - want[reduction]) < 0.02f;
    printf("t_sampler_family: %s: %s (%.3f of texels 0.2 0.4 0.6 0.8, %.1f expected)\n", what[reduction], ok ? "applied" : fabsf(v - 0.5f) < 0.02f ? "ignored" : "neither", v, want[reduction]);
    if (reduction) CHECK(!!(diag & SD_A10) == !g_a10, "samp_diag's census flag for a reduction is %d on a GPU %s Apple10", !!(diag & SD_A10), g_a10 ? "of" : "below");
    return ok;
}
static int judge_border(const char *name, const char *fmt) {   // → 1 when the sample outside reads (0, 0, 0, 1) and the one inside (1, 1, 1, 1)
    char res[512]; int rc = run_probe(name, res, sizeof res); float f[12]; int diag = -1; char word[16] = "";
    if (rc || sscanf(res, "%15s %f %f %f %f %f %f %f %f %f %f %f %f %d", word, &f[0], &f[1], &f[2], &f[3], &f[4], &f[5], &f[6], &f[7], &f[8], &f[9], &f[10], &f[11], &diag) != 14 || strcmp(word, "ok")) {
        printf("t_sampler_family: opaque black border on %s: %s\n", fmt, res); return 0; }
    int ok = 1; for (int c = 0; c < 4; c++) ok &= fabsf(f[c] - (c == 3)) < 0.01f && fabsf(f[4 + c] - (c == 3)) < 0.01f && fabsf(f[8 + c] - 1) < 0.01f;
    printf("t_sampler_family: opaque black border on %s: outside %g,%g,%g,%g and %g,%g,%g,%g, inside %g,%g,%g,%g (%s)\n", fmt, f[0], f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11],
           ok ? "as documented for other formats" : "not (0, 0, 0, 1) outside and (1, 1, 1, 1) inside");
    CHECK(diag >= 0 && (diag & SD_OB), "samp_diag flags the opaque black border sampler (flags %d)", diag);
    return ok;
}
static void flag_case(int sid, float r, float g, float b, float a, uint8_t wrap, int want) {   // samp_diag's opaque black flags for samp_ob_pair: SD_OB on the sampler, SD_OBW on its twin, or none
    samp_par sp = {0}; sp.magf = sp.minf = 1; sp.ws = sp.wt = sp.wr = wrap; sp.border[0] = r; sp.border[1] = g; sp.border[2] = b; sp.border[3] = a; sp.aniso = 1;
    int diag; id<MTLSamplerState> s = prod_sampler(sid, &sp, &diag);
    CHECK(s != nil && diag >= 0 && (diag & (SD_OB | SD_OBW)) == want && !(diag & (SD_NIL | SD_TNIL)), "border %g,%g,%g,%g wrap %d: flags %d, opaque black flags %d expected", r, g, b, a, wrap, diag, want);
}

int main(int argc, char **argv) { @autoreleasepool {
    if (argc > 2 && !strcmp(argv[1], "--probe")) return probe(argv[2]);
    alarm(16 * PROBE_S);   // every wait below has a deadline; this is the last guard
    mtl_init();   // gpu_caps_log's line: the GPU, its family, Metal 4, the CPU's features
    g_a10 = g_gpu_fam >= 1010; char fam[16] = "below Apple7"; if (g_gpu_fam) snprintf(fam, sizeof fam, "Apple%d", g_gpu_fam - 1000);
    printf("t_sampler_family: %s, highest Apple GPU family %s\n", g_dev.name.UTF8String, fam); fflush(stdout);
    flag_case(31, 0, 0, 0, 1, 5, SD_OB); flag_case(32, 0, 0, 0, 1, 0, 0); flag_case(33, 1, 1, 1, 1, 5, 0); flag_case(34, 0.25f, 0.5f, 0.75f, 1, 5, SD_OB);   // nearest colour opaque black
    flag_case(35, 0, 0, 0, 0.4f, 4, SD_OBW); flag_case(36, 0.8f, 0.9f, 0.7f, 0.6f, 5, 0);   // a twin of opaque black; one of transparent black
    int c_bias = judge_bias("bias0", 0), c_avg = judge_reduction("avg", 0), c_border = judge_border("border-rgba8", "RGBA8Unorm (control)");
    CHECK(c_bias, "control: no bias reads level 1"); CHECK(c_avg, "control: the average is 0.5"); CHECK(c_border, "control: RGBA8Unorm reads the opaque black border");
    int bp = judge_bias("bias+1", 1), bm = judge_bias("bias-1", -1), rmin = judge_reduction("min", 1), rmax = judge_reduction("max", 2);
    judge_border("border-abgr4", "ABGR4Unorm"); judge_border("border-a1bgr5", "A1BGR5Unorm");   // reported only: Metal documents the pairing as incompatible
    if (g_a10) { CHECK(bp && bm, "an Apple10 GPU applies the sampler LOD bias"); CHECK(rmin && rmax, "an Apple10 GPU applies the min / max reduction"); }
    else printf("t_sampler_family: %s: Metal documents neither setting for this family; the lines above are the findings (send them with the device logs)\n", fam);
    printf("t_sampler_family: %d checks, %d failed\n", checks, fails);
    return fails != 0;
} }
