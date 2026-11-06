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
// The flagged run (hmma_selftest.py FLAGS_KERNEL, kernel check_flags, a library of its own) checks the paths TensorPass's flags take: HMMA_FLAGS_CALLS calls a SIMD-group in
// the order hmma_flags_calls lists them, two accumulator chains of three calls open at once in slots 0 and 7, a call in no chain while both are open (it works in a pair of
// matrices of its own, not in slot 0's: dmsh_build.py HMMA_BODY), A kept from the call before, C = 0, and A loaded from shared memory where an LDSM read it, plain and
// transposed; each call is given stale registers where its flags say they are not read. A chain's middle results stay in the
// SIMD-group's matrices, so only its end is seen: its bound is the single call's, 0.01 + 0.4 % of the value each call makes, added up along the chain, since each call
// adds its own rounding to the error the C it was given already holds (hmma_flags_tile). The input is each tile's matrices, halves from the same draw.
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
enum { HMMA_FLAGS_CALLS = 8, HMMA_FLAGS_ENDS = 4,   // the flagged run's calls a SIMD-group, and its results: two chains' ends and two calls' D
       HMMA_FLAGS_TILE = 1664,                      // halves a tile: A0, A1 (16 x 16, row-major), B0..B7 (16 x 8, row k), C (16 x 8, row-major) (hmma_selftest.py TILE)
       HMMA_FLAGS_B = 512, HMMA_FLAGS_C = 1536,     // where B0 and C start in a tile
       HMMA_FLAGS_IN = HMMA_CHECK_TILES * HMMA_FLAGS_TILE / 2,   // words in: each tile's halves
       HMMA_FLAGS_OUT = HMMA_CHECK_THREADS * HMMA_FLAGS_ENDS * 2 };   // words out a run: each lane's D0, D1 of each result
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
static inline void hmma_check_fill_n(uint32_t *in, int words, uint32_t seed) {
    uint32_t s = seed;
    for (int i = 0; i < words; i++) {
        uint32_t lo = hmma_check_f2h(hmma_check_draw(&s)), hi = hmma_check_f2h(hmma_check_draw(&s));
        in[i] = lo | hi << 16;
    }
}
static inline void hmma_check_fill(uint32_t *in, uint32_t seed) { hmma_check_fill_n(in, HMMA_CHECK_IN, seed); }   // HMMA_CHECK_IN words
static inline void hmma_flags_fill(uint32_t *in, uint32_t seed) { hmma_check_fill_n(in, HMMA_FLAGS_IN, seed); }   // HMMA_FLAGS_IN words
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
// One output against its reference and bound, added to *r
static inline void hmma_check_note(struct hmma_check_result *r, float got, double ref, double bound) {
    double e = fabs((double)got - ref);
    r->outputs++;
    if (isnan(got) || isnan(ref)) { r->nan++; r->over++; return; }
    if (e > r->abs) { r->abs = e; r->abs_at = ref; }
    if (e / bound > r->worst) r->worst = e / bound;
    if (fabs(ref) >= HMMA_CHECK_ABS / HMMA_CHECK_REL && e / fabs(ref) > r->rel) r->rel = e / fabs(ref);
    r->over += e > bound;
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
                    hmma_check_note(r, got, ref, HMMA_CHECK_ABS + fabs(ref) * HMMA_CHECK_REL);
                }
            }
        }
    }
}
// The flagged run's calls in the kernel's order: the A (0, 1) and B (0..7) each multiplies, and the result it adds to (0, 1: the chains in slots 0 and 7; 2: one call after
// them; 3: one call in no chain while both are open). Results 0 and 3 start from the tile's C, the others from 0 (hmma_selftest.py CALLS, which also has each call's flags, and
// FROM_C)
static const struct { int a, b, end; } hmma_flags_calls[HMMA_FLAGS_CALLS] = {{0, 0, 0}, {0, 1, 1}, {0, 2, 0}, {0, 7, 3}, {1, 3, 1}, {1, 4, 0}, {1, 5, 1}, {1, 6, 2}};
static const int hmma_flags_from_c[HMMA_FLAGS_ENDS] = {1, 0, 0, 1};
static inline float hmma_flags_half(const uint32_t *in, int tile, int i) {   // half i of a tile (low half of a word first)
    uint32_t w = in[(tile * HMMA_FLAGS_TILE + i) / 2];
    return hmma_check_h2f((uint16_t)((i & 1 ? w >> 16 : w) & 0xffff));
}
// A tile's results as exact sums (P, in double, which holds each product of two halves and their sums of these sizes exactly) and each one's bound (E). Call i of a result
// makes D_i = round(P_i + err_(i-1)), within the single call's bound of that value, so with E_i the bound on err_i: E_i = E_(i-1) + 0.01 + 0.4 % (|P_i| + E_(i-1)), E_0 = 0
static inline void hmma_flags_tile(const uint32_t *in, int tile, double P[HMMA_FLAGS_ENDS][16][8], double E[HMMA_FLAGS_ENDS][16][8]) {
    for (int e = 0; e < HMMA_FLAGS_ENDS; e++) for (int row = 0; row < 16; row++) for (int col = 0; col < 8; col++) {
        P[e][row][col] = hmma_flags_from_c[e] ? hmma_flags_half(in, tile, HMMA_FLAGS_C + row * 8 + col) : 0; E[e][row][col] = 0;
    }
    for (int i = 0; i < HMMA_FLAGS_CALLS; i++) {
        int a = hmma_flags_calls[i].a * 256, b = HMMA_FLAGS_B + hmma_flags_calls[i].b * 128, e = hmma_flags_calls[i].end;
        for (int row = 0; row < 16; row++) for (int col = 0; col < 8; col++) {
            double p = P[e][row][col];
            for (int k = 0; k < 16; k++) p += (double)hmma_flags_half(in, tile, a + row * 16 + k) * hmma_flags_half(in, tile, b + k * 8 + col);
            P[e][row][col] = p;
            E[e][row][col] += HMMA_CHECK_ABS + HMMA_CHECK_REL * (fabs(p) + E[e][row][col]);
        }
    }
}
// One flagged run's outputs (HMMA_FLAGS_OUT words: lane by lane, each result's D0, D1) against the reference, added to *r
static inline void hmma_flags_compare(const uint32_t *in, const uint32_t *out, struct hmma_check_result *r) {
    for (int tile = 0; tile < HMMA_CHECK_TILES; tile++) {
        double P[HMMA_FLAGS_ENDS][16][8], E[HMMA_FLAGS_ENDS][16][8]; hmma_flags_tile(in, tile, P, E);
        for (int L = 0; L < 32; L++) {
            int g = L / 4, t = L % 4; const uint32_t *dw = out + (tile * 32 + L) * HMMA_FLAGS_ENDS * 2;
            for (int e = 0; e < HMMA_FLAGS_ENDS; e++) for (int q = 0; q < 2; q++) for (int j = 0; j < 2; j++) {
                int row = g + 8 * q, col = 2 * t + j;
                hmma_check_note(r, hmma_check_h2f((dw[e * 2 + q] >> (16 * j)) & 0xffff), P[e][row][col], E[e][row][col]);
            }
        }
    }
}
// Every run (runs * words words, compare's run size): each against the reference, and each against the first run's outputs
static inline void hmma_check_runs_of(const uint32_t *in, const uint32_t *out, int runs, int words, void (*compare)(const uint32_t *, const uint32_t *, struct hmma_check_result *),
                                      struct hmma_check_result *r) {
    memset(r, 0, sizeof *r);
    for (int i = 0; i < runs; i++) {
        compare(in, out + (size_t)i * (size_t)words, r);
        r->runs_differ += i && memcmp(out, out + (size_t)i * (size_t)words, sizeof *out * (size_t)words) != 0;
    }
}
static inline void hmma_check_runs(const uint32_t *in, const uint32_t *out, int runs, struct hmma_check_result *r) { hmma_check_runs_of(in, out, runs, HMMA_CHECK_OUT, hmma_check_compare, r); }
static inline void hmma_flags_runs(const uint32_t *in, const uint32_t *out, int runs, struct hmma_check_result *r) { hmma_check_runs_of(in, out, runs, HMMA_FLAGS_OUT, hmma_flags_compare, r); }
static inline int hmma_check_failed(const struct hmma_check_result *r) { return r->over || r->runs_differ; }
// The verdict after "<GPU>: ": "256 tiles x 4 chained calls, 8 runs: worst output at W% of its bound 0.01 + 0.4% of its value; max error A abs (at an output of V), R% rel: ok",
// or ": OVER BOUND (n of N outputs[, NaN among them][, k of 8 runs differ from the first])" or ": RUNS DIFFER (k of 8 runs differ from the first)" in place of ": ok"
static inline int hmma_check_counts(const struct hmma_check_result *r, int runs, char *line, int n, size_t cap) {   // a failed summary's counts after its n characters
    if (hmma_check_failed(r) && n > 0 && (size_t)n < cap) {
        char differ[64] = ""; if (r->runs_differ) snprintf(differ, sizeof differ, "%s%d of %d runs differ from the first", r->over ? ", " : "", r->runs_differ, runs);
        char over[96] = ""; if (r->over) snprintf(over, sizeof over, "%ld of %ld outputs%s", r->over, r->outputs, r->nan ? ", NaN among them" : "");
        n += snprintf(line + n, cap - (size_t)n, " (%s%s)", over, differ);
    }
    return n;
}
static inline int hmma_check_summary(const struct hmma_check_result *r, int runs, char *line, size_t cap) {
    int n = snprintf(line, cap, "%d tiles x %d chained calls, %d runs: worst output at %.0f%% of its bound 0.01 + 0.4%% of its value; max error %.4g abs (at an output of %.3g), "
                     "%.3g%% rel: %s", HMMA_CHECK_TILES, HMMA_CHECK_STEPS, runs, r->worst * 100, r->abs, fabs(r->abs_at), r->rel * 100,
                     r->over ? "OVER BOUND" : r->runs_differ ? "RUNS DIFFER" : "ok");
    return hmma_check_counts(r, runs, line, n, cap);
}
// The flagged run's verdict after "<GPU>: ": "256 tiles x 8 flagged calls (accumulators in two slots, a call in no chain in between, A kept, C = 0, A from shared memory plain and
// transposed), 8 runs: worst result at W% of its bound (0.01 + 0.4% of each call's value, added up its chain); max error A abs (at an output of V), R% rel: ok", with OVER BOUND
// or RUNS DIFFER and their counts in place of ok as hmma_check_summary has them
static inline int hmma_flags_summary(const struct hmma_check_result *r, int runs, char *line, size_t cap) {
    int n = snprintf(line, cap, "%d tiles x %d flagged calls (accumulators in two slots, a call in no chain in between, A kept, C = 0, A from shared memory plain and transposed), %d "
                     "runs: worst result at %.0f%% of its bound (0.01 + 0.4%% of each call's value, added up its chain); max error %.4g abs (at an output of %.3g), %.3g%% rel: "
                     "%s", HMMA_CHECK_TILES, HMMA_FLAGS_CALLS, runs, r->worst * 100, r->abs, fabs(r->abs_at), r->rel * 100,
                     r->over ? "OVER BOUND" : r->runs_differ ? "RUNS DIFFER" : "ok");
    return hmma_check_counts(r, runs, line, n, cap);
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
// Runs lib's kernel on dev, HMMA_CHECK_RUNS dispatches of HMMA_CHECK_TILES tiles in one command buffer on in_words words from fill, each run into its own out_words, and
// compares them with the reference (runs_of). Returns 1 with *r and "<GPU>: " and the summary in line, whether within the bound or not (hmma_check_failed says); 0 with
// "<GPU>: <what>not run: <why>" in line
static inline int hmma_check_dispatch(id<MTLDevice> dev, id<MTLLibrary> lib, NSString *kernel, const char *what, int in_words, int out_words, void (*fill)(uint32_t *, uint32_t),
                                      void (*runs_of)(const uint32_t *, const uint32_t *, int, struct hmma_check_result *),
                                      int (*summary)(const struct hmma_check_result *, int, char *, size_t), struct hmma_check_result *r, char *line, size_t cap) {
    char gpu[256]; hmma_check_gpu(dev, gpu, sizeof gpu);
    NSError *e = nil;
    id<MTLFunction> fn = [lib newFunctionWithName:kernel];
    id<MTLComputePipelineState> ps = fn ? [dev newComputePipelineStateWithFunction:fn error:&e] : nil;
    if (!ps) {
        const char *name = kernel.UTF8String, *why = e.localizedDescription.UTF8String;
        if (!fn) snprintf(line, cap, "%s: %snot run: the library has no kernel named %s", gpu, what, name ? name : "?");
        else snprintf(line, cap, "%s: %snot run: %s", gpu, what, why ? why : "no pipeline");
        return 0;
    }
    if (ps.threadExecutionWidth != 32 || ps.maxTotalThreadsPerThreadgroup < HMMA_CHECK_LANES) {   // the body works on 32-lane SIMD-groups, the check on four a threadgroup
        snprintf(line, cap, "%s: %snot run: SIMD-groups of %lu lanes, at most %lu lanes a threadgroup (it needs 32 and %d)", gpu, what,
                 (unsigned long)ps.threadExecutionWidth, (unsigned long)ps.maxTotalThreadsPerThreadgroup, HMMA_CHECK_LANES);
        return 0;
    }
    id<MTLBuffer> in = [dev newBufferWithLength:sizeof(uint32_t) * (NSUInteger)in_words options:MTLResourceStorageModeShared];
    id<MTLBuffer> out = [dev newBufferWithLength:sizeof(uint32_t) * (NSUInteger)out_words * HMMA_CHECK_RUNS options:MTLResourceStorageModeShared];
    id<MTLCommandQueue> q = [dev newCommandQueue];
    id<MTLCommandBuffer> cb = [q commandBuffer];
    id<MTLComputeCommandEncoder> ce = [cb computeCommandEncoder];
    if (!in || !out || !cb || !ce) { snprintf(line, cap, "%s: %snot run: no buffers or no command encoder", gpu, what); return 0; }
    fill((uint32_t *)in.contents, HMMA_CHECK_SEED);
    memset(out.contents, 0xff, out.length);   // NaN halves: an output a lane never writes fails
    [ce setComputePipelineState:ps]; [ce setBuffer:in offset:0 atIndex:0];
    for (int i = 0; i < HMMA_CHECK_RUNS; i++) {
        [ce setBuffer:out offset:sizeof(uint32_t) * (NSUInteger)out_words * (NSUInteger)i atIndex:1];
        [ce dispatchThreadgroups:MTLSizeMake(HMMA_CHECK_GROUPS, 1, 1) threadsPerThreadgroup:MTLSizeMake(HMMA_CHECK_LANES, 1, 1)];
    }
    [ce endEncoding]; [cb commit]; [cb waitUntilCompleted];
    if (cb.status != MTLCommandBufferStatusCompleted) {
        const char *why = cb.error.localizedDescription.UTF8String;
        snprintf(line, cap, "%s: %snot run: its command buffer ended with status %ld (%s)", gpu, what, (long)cb.status, why ? why : "no error"); return 0;
    }
    runs_of((const uint32_t *)in.contents, (const uint32_t *)out.contents, HMMA_CHECK_RUNS, r);
    int n = snprintf(line, cap, "%s: ", gpu);
    if (n > 0 && (size_t)n < cap) summary(r, HMMA_CHECK_RUNS, line + n, cap - (size_t)n);
    return 1;
}
// lib's kernel `check` (hmma_selftest.py KERNEL: four chained calls a lane, flags 0) against the reference
static inline int hmma_check_run(id<MTLDevice> dev, id<MTLLibrary> lib, struct hmma_check_result *r, char *line, size_t cap) {
    return hmma_check_dispatch(dev, lib, @"check", "", HMMA_CHECK_IN, HMMA_CHECK_OUT, hmma_check_fill, hmma_check_runs, hmma_check_summary, r, line, cap);
}
// lib's kernel `check_flags` (hmma_selftest.py FLAGS_KERNEL: the flagged calls) against the reference; a line that says it did not run names the flagged calls
static inline int hmma_flags_run(id<MTLDevice> dev, id<MTLLibrary> lib, struct hmma_check_result *r, char *line, size_t cap) {
    return hmma_check_dispatch(dev, lib, @"check_flags", "flagged calls: ", HMMA_FLAGS_IN, HMMA_FLAGS_OUT, hmma_flags_fill, hmma_flags_runs, hmma_flags_summary, r, line, cap);
}
#endif
