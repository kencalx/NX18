// The check of the HMMA.16816 body the shader build writes for Ampere's matrix instructions (dm/gfx/tools/dmsh_build.py hmma_msl: the simdgroup_matrix code agl's upscaler
// networks run) on a GPU, in one copy for both of its runs: dm/gfx/tests/test_dmsh_hmma.py on the Mac (the kernel compiled with the macOS chain's flags and with the iOS chain's)
// and the start-up self-test DM_SELFTEST=hmma (selftest.m, with the kernel the host was built with). The kernel (dm/gfx/tools/hmma_selftest.py KERNEL) makes HMMA_CHECK_STEPS
// calls of the helper a lane in a row on the same 256 words of the scratch, each call's D the next one's C, as games call it (144 a thread in the upscaler, some D fed back as C):
// that reuses the scratch across calls, which the body's last barrier is there for. Step k's A and B come from `in`, step 0's C too; each step's D goes to `out`; one
// m16n8k16 tile a SIMD-group of 32 lanes. The dispatch runs HMMA_CHECK_RUNS times on the same input, each into its own part of `out`.
// The reference is PTX mma.m16n8k16.row.col with f16 sources and accumulator, D = A·B + C, the fragments held by a warp's lanes (lane = 4 g + t, two halves a word, the lower
// column or k first) as A0 = A[g][2t, 2t+1], A1 = A[g+8][2t, 2t+1], A2 = A[g][2t+8, 2t+9], A3 = A[g+8][2t+8, 2t+9]; B0 = B[2t, 2t+1][g], B1 = B[2t+8, 2t+9][g];
// C0 / D0 = C[g][2t, 2t+1], C1 / D1 = C[g+8][2t, 2t+1]. Step k is checked with the C the GPU itself gave it (step k - 1's D read back), so the bound holds for each call.
// The reference is the exact sum, in float (which holds each product of two halves exactly): an ideal result, rounded once to f16, is off by up to half an f16 step (about
// 0.002 at 4 to 8), and the matrix hardware rounds the f16 accumulator as it goes, as Ampere's does, so an output passes within 0.01 + 0.4 % of its value. A NaN output never
// passes, and neither does a run whose outputs differ from the first run's (the same input: a race in the scratch). The summary gives how close the worst output came to its
// own bound, then the largest absolute error with the value it was taken at, and the largest relative error over the outputs of at least 2.5 (0.01 / 0.4 %), where the
// relative term is the larger part of the bound. The fragments are halves in [-1, 1] in steps of 0.001 from a fixed seed (xorshift32), the same on every device.
// The C part is plain C (no Metal), so it builds anywhere; the run itself is Objective-C
#pragma once
#include <math.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

enum { HMMA_CHECK_GROUPS = 64, HMMA_CHECK_LANES = 128, HMMA_CHECK_THREADS = HMMA_CHECK_GROUPS * HMMA_CHECK_LANES, HMMA_CHECK_TILES = HMMA_CHECK_THREADS / 32,
       HMMA_CHECK_STEPS = 4, HMMA_CHECK_RUNS = 8,   // threadgroups, lanes a threadgroup (four SIMD-groups), tiles (one a SIMD-group), calls a lane in a row, runs of the dispatch
       HMMA_CHECK_AB = 6, HMMA_CHECK_C = 2,         // words a lane takes a step (A0..A3, B0, B1), and for step 0's C (C0, C1)
       HMMA_CHECK_IN = HMMA_CHECK_THREADS * (HMMA_CHECK_STEPS * HMMA_CHECK_AB + HMMA_CHECK_C),   // words in: each step's A and B lane by lane, then step 0's C lane by lane
       HMMA_CHECK_OUT = HMMA_CHECK_STEPS * HMMA_CHECK_THREADS * 2 };                         // words out a run: each step's D0, D1 lane by lane
#define HMMA_CHECK_SEED 11u
#define HMMA_CHECK_ABS 0.01
#define HMMA_CHECK_REL 0.004

// worst: the largest error over its output's bound (above 1: over it); abs and abs_at: the largest absolute error and the reference's value there; rel: the largest relative
// error over the outputs of at least 2.5; over, nan, outputs: outputs over their bound (NaN ones too), NaN outputs, outputs checked; runs_differ: runs whose outputs are not
// the first run's
struct hmma_check_result { double worst, abs, abs_at, rel; long over, nan, outputs; int runs_differ; };

static inline float hmma_check_h2f(uint16_t h) { _Float16 v; memcpy(&v, &h, 2); return (float)v; }
static inline uint16_t hmma_check_f2h(float f) { _Float16 v = (_Float16)f; uint16_t h; memcpy(&h, &v, 2); return h; }
static inline float hmma_check_draw(uint32_t *s) {   // the next half: xorshift32, then one of -1.000 .. 1.000
    uint32_t x = *s; x ^= x << 13; x ^= x >> 17; x ^= x << 5; *s = x;
    return (float)((int)(x % 2001u) - 1000) / 1000.0f;
}
static inline void hmma_check_fill(uint32_t *in, uint32_t seed) {   // HMMA_CHECK_IN words
    uint32_t s = seed;
    for (int i = 0; i < HMMA_CHECK_IN; i++) {
        uint32_t lo = hmma_check_f2h(hmma_check_draw(&s)), hi = hmma_check_f2h(hmma_check_draw(&s));
        in[i] = lo | hi << 16;
    }
}
static inline const uint32_t *hmma_check_ab(const uint32_t *in, int step) { return in + step * HMMA_CHECK_THREADS * HMMA_CHECK_AB; }   // step's A and B, HMMA_CHECK_AB words a lane
static inline const uint32_t *hmma_check_c0(const uint32_t *in) { return in + HMMA_CHECK_STEPS * HMMA_CHECK_THREADS * HMMA_CHECK_AB; }   // step 0's C, 2 words a lane
static inline const uint32_t *hmma_check_d(const uint32_t *out, int step) { return out + step * HMMA_CHECK_THREADS * 2; }   // a run's D of step, 2 words a lane
// A warp's tile D = A·B + C before rounding: A and B from ab (HMMA_CHECK_AB words a lane), C from c (2 words a lane: the input's, or the GPU's D of the step before)
static inline void hmma_check_tile(const uint32_t *ab, const uint32_t *c, int warp, float D[16][8]) {
    float A[16][16], B[16][8];
    for (int L = 0; L < 32; L++) {
        const uint32_t *f = ab + (warp * 32 + L) * HMMA_CHECK_AB, *cw = c + (warp * 32 + L) * 2; int g = L / 4, t = L % 4;
        for (int q = 0; q < 4; q++) { int row = g + 8 * (q & 1), k = 2 * t + 8 * (q >> 1); A[row][k] = hmma_check_h2f(f[q] & 0xffff); A[row][k + 1] = hmma_check_h2f(f[q] >> 16); }
        for (int q = 0; q < 2; q++) { int k = 2 * t + 8 * q; B[k][g] = hmma_check_h2f(f[4 + q] & 0xffff); B[k + 1][g] = hmma_check_h2f(f[4 + q] >> 16); }
        for (int q = 0; q < 2; q++) { int row = g + 8 * q; D[row][2 * t] = hmma_check_h2f(cw[q] & 0xffff); D[row][2 * t + 1] = hmma_check_h2f(cw[q] >> 16); }
    }
    for (int row = 0; row < 16; row++) for (int col = 0; col < 8; col++) {
        float ref = D[row][col];
        for (int k = 0; k < 16; k++) ref += A[row][k] * B[k][col];
        D[row][col] = ref;
    }
}
// One run's outputs (HMMA_CHECK_OUT words) against the reference, added to *r: step k of each tile with C = the input's (step 0) or this run's own D of step k - 1
static inline void hmma_check_compare(const uint32_t *in, const uint32_t *out, struct hmma_check_result *r) {
    for (int step = 0; step < HMMA_CHECK_STEPS; step++) {
        const uint32_t *c = step ? hmma_check_d(out, step - 1) : hmma_check_c0(in), *d = hmma_check_d(out, step);
        for (int warp = 0; warp < HMMA_CHECK_TILES; warp++) {
            float D[16][8]; hmma_check_tile(hmma_check_ab(in, step), c, warp, D);
            for (int L = 0; L < 32; L++) {
                int g = L / 4, t = L % 4; const uint32_t *dw = d + (warp * 32 + L) * 2;
                for (int q = 0; q < 2; q++) for (int j = 0; j < 2; j++) {
                    float ref = D[g + 8 * q][2 * t + j], got = hmma_check_h2f((dw[q] >> (16 * j)) & 0xffff);
                    double e = fabs((double)got - ref), bound = HMMA_CHECK_ABS + fabs(ref) * HMMA_CHECK_REL;
                    r->outputs++;
                    if (isnan(got) || isnan(ref)) { r->nan++; r->over++; continue; }
                    if (e > r->abs) { r->abs = e; r->abs_at = ref; }
                    if (e / bound > r->worst) r->worst = e / bound;
                    if (fabs(ref) >= HMMA_CHECK_ABS / HMMA_CHECK_REL && e / fabs(ref) > r->rel) r->rel = e / fabs(ref);
                    r->over += e > bound;
                }
            }
        }
    }
}
// Every run (runs * HMMA_CHECK_OUT words): each against the reference, and each against the first run's outputs
static inline void hmma_check_runs(const uint32_t *in, const uint32_t *out, int runs, struct hmma_check_result *r) {
    memset(r, 0, sizeof *r);
    for (int i = 0; i < runs; i++) {
        hmma_check_compare(in, out + (size_t)i * HMMA_CHECK_OUT, r);
        r->runs_differ += i && memcmp(out, out + (size_t)i * HMMA_CHECK_OUT, sizeof *out * HMMA_CHECK_OUT) != 0;
    }
}
static inline int hmma_check_failed(const struct hmma_check_result *r) { return r->over || r->runs_differ; }
// The verdict after "<GPU>: ": "256 tiles x 4 chained calls, 8 runs: worst output at W% of its bound 0.01 + 0.4% of its value; max error A abs (at an output of V), R% rel: ok",
// or ": OVER BOUND (n of N outputs[, NaN among them][, k of 8 runs differ from the first])" or ": RUNS DIFFER (k of 8 runs differ from the first)" in place of ": ok"
static inline int hmma_check_summary(const struct hmma_check_result *r, int runs, char *line, size_t cap) {
    int n = snprintf(line, cap, "%d tiles x %d chained calls, %d runs: worst output at %.0f%% of its bound 0.01 + 0.4%% of its value; max error %.4g abs (at an output of %.3g), "
                     "%.3g%% rel: %s", HMMA_CHECK_TILES, HMMA_CHECK_STEPS, runs, r->worst * 100, r->abs, fabs(r->abs_at), r->rel * 100,
                     r->over ? "OVER BOUND" : r->runs_differ ? "RUNS DIFFER" : "ok");
    if (hmma_check_failed(r) && n > 0 && (size_t)n < cap) {
        char differ[64] = ""; if (r->runs_differ) snprintf(differ, sizeof differ, "%s%d of %d runs differ from the first", r->over ? ", " : "", r->runs_differ, runs);
        char over[96] = ""; if (r->over) snprintf(over, sizeof over, "%ld of %ld outputs%s", r->over, r->outputs, r->nan ? ", NaN among them" : "");
        n += snprintf(line + n, cap - (size_t)n, " (%s%s)", over, differ);
    }
    return n;
}

#ifdef __OBJC__
#import <Metal/Metal.h>
// "<name> (<architecture>, highest Apple family N)", the family asked by raw value (MTLGPUFamilyApple7 1007 to Apple11 1011), as nvn_mtl.m gpu_caps_log asks it
static inline void hmma_check_gpu(id<MTLDevice> dev, char *buf, size_t cap) {
    int fam = 0;
    for (int f = 1011; f >= 1007 && !fam; f--) if ([dev supportsFamily:(MTLGPUFamily)f]) fam = f - 1000;
    char n[16] = "below 7"; if (fam) snprintf(n, sizeof n, "%d", fam);
    const char *name = dev.name.UTF8String, *arch = dev.architecture.name.UTF8String;
    snprintf(buf, cap, "%s (%s, highest Apple family %s)", name ? name : "unknown GPU", arch ? arch : "unknown architecture", n);
}
// Runs lib's kernel `check` on dev, HMMA_CHECK_RUNS dispatches of HMMA_CHECK_TILES tiles in one command buffer, and compares them with the reference. Returns 1 with *r and
// "<GPU>: " and the summary (hmma_check_summary) in line, whether within the bound or not (hmma_check_failed says); 0 with "<GPU>: not run: <why>" in line
static inline int hmma_check_run(id<MTLDevice> dev, id<MTLLibrary> lib, struct hmma_check_result *r, char *line, size_t cap) {
    char gpu[256]; hmma_check_gpu(dev, gpu, sizeof gpu);
    NSError *e = nil;
    id<MTLFunction> fn = [lib newFunctionWithName:@"check"];
    id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&e] : nil;
    if (!ps) {
        const char *why = !fn ? "the library has no kernel named check" : e.localizedDescription.UTF8String ? e.localizedDescription.UTF8String : "no pipeline";
        snprintf(line, cap, "%s: not run: %s", gpu, why); return 0;
    }
    if (ps.threadExecutionWidth != 32 || ps.maxTotalThreadsPerThreadgroup < HMMA_CHECK_LANES) {   // the body works on 32-lane SIMD-groups, the check on four a threadgroup
        snprintf(line, cap, "%s: not run: SIMD-groups of %lu lanes, at most %lu lanes a threadgroup (it needs 32 and %d)", gpu,
                 (unsigned long)ps.threadExecutionWidth, (unsigned long)ps.maxTotalThreadsPerThreadgroup, HMMA_CHECK_LANES);
        return 0;
    }
    id<MTLBuffer> in = [dev newBufferWithLength:sizeof(uint32_t) * HMMA_CHECK_IN options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:sizeof(uint32_t) * HMMA_CHECK_OUT * HMMA_CHECK_RUNS options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    if (!in || !out || !cb || !ce) { snprintf(line, cap, "%s: not run: no buffers or no command encoder", gpu); return 0; }
    hmma_check_fill((uint32_t *)in.contents, HMMA_CHECK_SEED);
    memset(out.contents, 0xff, out.length);   // NaN halves: an output a lane never writes fails
    [ce setComputePipelineState:ps]; [ce setBuffer:in offset:0 atIndex:0];
    for (int i = 0; i < HMMA_CHECK_RUNS; i++) {
        [ce setBuffer:out offset:sizeof(uint32_t) * HMMA_CHECK_OUT * (NSUInteger)i atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(HMMA_CHECK_GROUPS, 1, 1) threadsPerThreadgroup:MTLSizeMake(HMMA_CHECK_LANES, 1, 1)];
    }
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        const char *why = cb.error.localizedDescription.UTF8String;
        snprintf(line, cap, "%s: not run: its command buffer ended with status %ld (%s)", gpu, (long)cb.status, why ? why : "no error"); return 0;
    }
    hmma_check_runs((const uint32_t *)in.contents, (const uint32_t *)out.contents, HMMA_CHECK_RUNS, r);
    int n = snprintf(line, cap, "%s: ", gpu);
    if (n > 0 && (size_t)n < cap) hmma_check_summary(r, HMMA_CHECK_RUNS, line + n, cap - (size_t)n);
    return 1;
}
#endif
