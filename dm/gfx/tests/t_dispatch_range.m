// Compute dispatches in the copy encoder get a barrier only when their memory overlaps what the encoder holds since its last barrier (nvn_mtl.m dispatch_ranges / dispatch_enc_r,
// DM_NVN_DISPATCH_RANGE). One submission of game dispatches through the production dispatch(), on the GPU, with hand-written expectations: the barriers before each operation
// (mtl_blit_barriers) and the words each one leaves. Default (on): a dispatch whose storage buffers miss every earlier one's gets no barrier; one that reads a storage buffer, or a
// uniform buffer, an earlier dispatch wrote gets one; one that writes what an earlier dispatch read gets one; a copy that reads a dispatch's output gets one; an indirect dispatch keeps
// the barrier and counts as writing everything, and so does a texture copy (blit) for the dispatch after it. DM_NVN_DISPATCH_RANGE=1 (the rule of S2Arm 116fe90e): as above, by ranges between
// dispatches too; =0: a barrier before every dispatch (the old rule). The words are the same either way. Unset or =2 (the default, the game's barriers, S2Arm a51b43f7): game_mode below
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define EXPECT(n,w,v) do { long long w_=(long long)(w), v_=(long long)(v); checks++; \
    printf("%-72s expected %lld → got %lld %s\n",n,w_,v_,w_==v_?"✓":"✗"); failed+=w_!=v_; } while(0)
enum { N = 256, REG = N * 4 };   // words per region, bytes per region
enum { X, Y, Z, W, V, U, Q, C, Z2, W2, Z3, W3, Z4, W4, Z5, W5, IND, Y2, NREG };
enum { NFILL = 128, FILL = 512 };   // game_mode's full-table case: dispatches of one 64-thread group (256 bytes) each, at their own FILL bytes after the regions
static uint8_t *g_mem;
static uint64_t at(int r) { return (uint64_t)(uintptr_t)(g_mem + (size_t)r * REG); }
static uint32_t *words(int r) { return (uint32_t *)(void *)(g_mem + (size_t)r * REG); }
static prog_t g_pg_ss = {.serial = 970001}, g_pg_ub = {.serial = 970002};
// src (a storage buffer, or uniform slot 0 for the uniform program) + 1 into dst (storage slot 1); indirect: the group counts at IND
static uint64_t run(prog_t *pg, int src, int dst, int indirect) {
    S.cprog = pg;
    if (pg == &g_pg_ub) S.ubo[5][0] = (p_bind_buf){.addr = at(src), .size = REG}; else S.ssbo[5][0] = (p_bind_buf){.addr = at(src), .size = REG};
    S.ssbo[5][1] = (p_bind_buf){.addr = at(dst), .size = REG};
    p_dispatch dp = {.x = N / 64, .y = 1, .z = 1}; if (indirect) { dp.ind = at(IND); dp.x = dp.y = dp.z = 99; }
    uint64_t b0 = mtl_blit_barriers(); dispatch(&dp); return mtl_blit_barriers() - b0;
}
static uint64_t run_at(uint64_t src, uint64_t dst) {   // one group (64 words) from src (storage slot 0) + 1 into dst (storage slot 1), each bound as 256 bytes
    S.cprog = &g_pg_ss; S.ssbo[5][0] = (p_bind_buf){.addr = src, .size = 256}; S.ssbo[5][1] = (p_bind_buf){.addr = dst, .size = 256};
    p_dispatch dp = {.x = 1, .y = 1, .z = 1}; uint64_t b0 = mtl_blit_barriers(); dispatch(&dp); return mtl_blit_barriers() - b0;
}
static void game_barrier(void) {   // the game's nvnCommandBufferBarrier, through the replay (OP_BARRIER in mtl_exec)
    uint8_t ops[32] = {0}; op_hdr h = {OP_BARRIER, 8 + 4}; int32_t bits = NVN_BARRIER_ORDER_PRIMITIVES_BIT | NVN_BARRIER_INVALIDATE_SHADER_BIT;
    memcpy(ops, &h, sizeof h); memcpy(ops + 8, &bits, 4); h = (op_hdr){OP_END, 8}; memcpy(ops + 12, &h, sizeof h); mtl_exec(ops);
}
// DM_NVN_DISPATCH_RANGE unset or =2: between dispatches with ranges only the game's barriers count; copies are still checked against what dispatches wrote and read, and dispatches against what copies did
static void game_mode(void) {
    uint64_t r0 = mtl_dispatch_range_stats(0), n0 = mtl_dispatch_range_stats(2), g0 = mtl_dispatch_range_stats(3);
    uint64_t g1 = run(&g_pg_ss, X, Y, 0);    // the encoder's first operation
    uint64_t g2 = run(&g_pg_ss, X, Y2, 0);   // its storage buffer X overlaps G1's (counted as written), with no game barrier between them
    game_barrier(); EXPECT("OP_BARRIER notes the game's barrier for the next dispatch", 1, g_dsp_game_bar);
    uint64_t g3 = run(&g_pg_ss, Y, V, 0);    // reads Y, which G1 wrote, after the game's barrier
    EXPECT("the dispatch takes the game's barrier", 0, g_dsp_game_bar);
    uint64_t g4 = run(&g_pg_ss, Z, W, 0);    // misses everything
    int dn = g_dspw_n; uint64_t g4b = run(&g_pg_ss, Z, W, 0);   // the same ranges again, no game barrier: the same words, and the ranges are not recorded twice
    EXPECT("G4 again: the dispatch tables keep one entry a range", dn, g_dspw_n);
    uint64_t b0 = mtl_blit_barriers(); mtl_sub_copy(at(V), at(C), REG); uint64_t cp = mtl_blit_barriers() - b0;   // a copy reading G3's output
    uint64_t g5 = run(&g_pg_ss, C, W2, 0);   // reads C, which the copy wrote
    int before = g_dspw_n; uint64_t fill = 0, last = 0; int k = 0;
    for (; k < NFILL && g_dspw_n + 2 <= DW_MAX; k++) fill += run_at(at(NREG) + (uint64_t)k * FILL, at(NREG) + (uint64_t)k * FILL + 256);   // two new ranges each, no game barrier
    int full = g_dspw_n; last = run_at(at(NREG) + (uint64_t)k * FILL, at(NREG) + (uint64_t)k * FILL + 256);   // no room for its two ranges
    uint64_t fence = mtl_sub_commit(); EXPECT("the submission completes", 1, mtl_wait(fence, 5000000000ull)); mtl_drain();
    EXPECT("no GPU error", 0, mtl_last_commit_error());
    EXPECT("G1 X->Y, the encoder's first operation: barriers before it", 0, g1);
    EXPECT("G2 X->Y2 overlaps G1, no game barrier: no barrier", 0, g2);
    EXPECT("G3 Y->V after the game's barrier: a barrier", 1, g3);
    EXPECT("G4 Z->W misses everything: no barrier", 0, g4);
    EXPECT("G4 again over its own ranges, no game barrier: no barrier", 0, g4b);
    EXPECT("a copy V->C reads G3's output (the dispatch table): a barrier", 1, cp);
    EXPECT("G5 C->W2 reads the copy's output: a barrier", 1, g5);
    EXPECT("the fill starts after G5's two ranges", 2, before);
    EXPECT("dispatches until the dispatch table is full: no barrier", 0, fill);
    EXPECT("the dispatch table is full", DW_MAX, full);
    EXPECT("the next dispatch, with no room: a barrier", 1, last);
    EXPECT("after it the table holds its two ranges", 2, g_dspw_n);
    EXPECT("dispatches with ranges", 6 + k + 1, mtl_dispatch_range_stats(0) - r0);
    EXPECT("dispatches with ranges and no barrier", 3 + k, mtl_dispatch_range_stats(2) - n0);
    EXPECT("barriers taken from the game's", 1, mtl_dispatch_range_stats(3) - g0);
    int y = 1, y2 = 1, v = 1, w = 1, c = 1, w2 = 1, f = 1;
    for (int i = 0; i < N; i++) { y &= words(Y)[i] == 3u * i + 2; y2 &= words(Y2)[i] == 3u * i + 2; v &= words(V)[i] == 3u * i + 3; w &= words(W)[i] == 1001u + i; c &= words(C)[i] == 3u * i + 3; w2 &= words(W2)[i] == 3u * i + 4; }
    for (int j = 0; j <= k; j++) for (int i = 0; i < 64; i++) { const uint32_t *fs = (const uint32_t *)(const void *)(g_mem + (size_t)NREG * REG + (size_t)j * FILL); f &= fs[64 + i] == 1u; }
    EXPECT("Y = X + 1, Y2 = X + 1", 1, y && y2); EXPECT("V = X + 2 (G3 after the game's barrier)", 1, v); EXPECT("W = Z + 1", 1, w);
    EXPECT("C = X + 2 (the copy after G3)", 1, c); EXPECT("W2 = X + 3 (G5 after the copy)", 1, w2); EXPECT("the fill's words = 0 + 1", 1, f);
}
static NvShader *shader(id<MTLLibrary> lib, NSString *name, int uniform) {
    NvShader *cs = [NvShader new]; cs->stage = 5; cs->fn = t4_fn(lib, name);
    cs->arg_len = [cs->fn newArgumentEncoderWithBufferIndex:0].encodedLength;
    cs->rf.tg[0] = 64; cs->rf.tg[1] = cs->rf.tg[2] = 1; cs->rf.nb = 2;
    cs->rf.b[0] = uniform ? (nvn_rbind){.kind = NVN_RB_CBUF, .reg = 0, .aid = 0} : (nvn_rbind){.kind = NVN_RB_SBUFP, .rw = 1, .reg = 0, .aid = 0};
    cs->rf.b[1] = (nvn_rbind){.kind = NVN_RB_SBUFP, .rw = 1, .reg = 1, .aid = 1};
    return cs;
}
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *e = getenv("DM_NVN_DISPATCH_RANGE"); int on = !(e && !strcmp(e, "0")), game = !e || !strcmp(e, "2");
    mtl_init(); NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "struct S2 { device uint *src [[id(0)]]; device uint *dst [[id(1)]]; };\n"
        "kernel void inc(constant S2 &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.dst[i] = a.src[i] + 1; }\n"
        "struct U2 { constant uint *src [[id(0)]]; device uint *dst [[id(1)]]; };\n"
        "kernel void inc_u(constant U2 &a [[buffer(0)]], uint i [[thread_position_in_grid]]) { a.dst[i] = a.src[i] + 1; }\n", nil, &error);
    if (!lib) { printf("FAIL: kernels do not compile: %s\n", error.localizedDescription.UTF8String); return 1; }
    NvProg *ps = [NvProg new]; ps->sh[5] = shader(lib, @"inc", 0); serial_put(g_pg_ss.serial, ps);
    NvProg *pu = [NvProg new]; pu->sh[5] = shader(lib, @"inc_u", 1); serial_put(g_pg_ub.serial, pu);
    size_t len = (size_t)NREG * REG + (size_t)(NFILL + 1) * FILL; if (posix_memalign((void **)&g_mem, (size_t)getpagesize(), len)) return 2;
    memset(g_mem, 0, len); mtl_pool_add(g_mem, len);
    for (int i = 0; i < N; i++) { words(X)[i] = 3u * i + 1; words(Z)[i] = 1000u + i; words(Q)[i] = 5000u + i; words(Z2)[i] = 7000u + i; words(Z3)[i] = 9000u + i; words(Z4)[i] = 11000u + i; words(Z5)[i] = 13000u + i; }
    uint32_t counts[3] = {N / 64, 1, 1}; memcpy(words(IND), counts, sizeof counts);
    mtl_sub_begin(); state_reset(); memset(&R, 0, sizeof R);
    if (game) { game_mode(); mtl_pool_del(g_mem); free(g_mem); printf("t_dispatch_range (the game's barriers): %d checks, %d failed\n", checks, failed); return failed != 0; }
    uint64_t r0 = mtl_dispatch_range_stats(0), f0 = mtl_dispatch_range_stats(1), n0 = mtl_dispatch_range_stats(2);
    uint64_t d1 = run(&g_pg_ss, X, Y, 0);   // the encoder's first operation
    uint64_t d2 = run(&g_pg_ss, Z, W, 0);   // storage buffers miss D1's (the regions only touch)
    uint64_t d3 = run(&g_pg_ss, Y, V, 0);   // reads Y, which D1 wrote
    uint64_t d4 = run(&g_pg_ub, V, U, 0);   // reads V as a uniform buffer: D3 wrote it
    uint64_t d5 = run(&g_pg_ss, Q, V, 0);   // writes V, which D4 read
    uint64_t b0 = mtl_blit_barriers(); mtl_sub_copy(at(V), at(C), REG); uint64_t cp = mtl_blit_barriers() - b0;   // a copy reading D5's output
    uint64_t d6 = run(&g_pg_ss, Z2, W2, 0);   // misses the copy's ranges
    uint64_t d7 = run(&g_pg_ss, Z3, W3, 1);   // indirect, misses everything: still a barrier
    uint64_t d8 = run(&g_pg_ss, Z4, W4, 0);   // misses everything, but D7 counts as writing all memory
    b0 = mtl_blit_barriers(); (void)blit(); uint64_t tc = mtl_blit_barriers() - b0;   // a texture copy's record (blit: everything written), as a binding's tex_upgrade leaves it
    uint64_t d9 = run(&g_pg_ss, Z5, W5, 0);   // misses everything, but follows that record
    uint64_t fence = mtl_sub_commit(); EXPECT("the submission completes", 1, mtl_wait(fence, 5000000000ull)); mtl_drain();
    EXPECT("no GPU error", 0, mtl_last_commit_error());
    EXPECT("D1 X->Y, the encoder's first operation: barriers before it", 0, d1);
    EXPECT(on ? "D2 Z->W misses D1's storage buffers: no barrier" : "D2 Z->W (DM_NVN_DISPATCH_RANGE=0): a barrier", on ? 0 : 1, d2);
    EXPECT("D3 Y->V reads D1's output: a barrier", 1, d3);
    EXPECT("D4 reads V (D3's output) as a uniform buffer: a barrier", 1, d4);
    EXPECT("D5 Q->V writes what D4 read: a barrier", 1, d5);
    EXPECT("a copy V->C reads D5's output: a barrier", 1, cp);
    EXPECT(on ? "D6 Z2->W2 misses the copy's ranges: no barrier" : "D6 Z2->W2 (DM_NVN_DISPATCH_RANGE=0): a barrier", on ? 0 : 1, d6);
    EXPECT("D7 indirect, missing everything: still a barrier", 1, d7);
    EXPECT("D8 after the indirect one (counted as writing everything): a barrier", 1, d8);
    EXPECT("a texture copy after D8: a barrier", 1, tc);
    EXPECT("D9 Z5->W5 after the texture copy (everything written): a barrier", 1, d9);
    EXPECT("dispatches with ranges", on ? 8 : 0, mtl_dispatch_range_stats(0) - r0);
    EXPECT("dispatches with the old rule", on ? 1 : 9, mtl_dispatch_range_stats(1) - f0);
    EXPECT("dispatches with ranges and no barrier", on ? 2 : 0, mtl_dispatch_range_stats(2) - n0);
    int y = 1, w = 1, u = 1, v = 1, c = 1, w2 = 1, w3 = 1, w4 = 1, w5 = 1;
    for (int i = 0; i < N; i++) {
        y &= words(Y)[i] == 3u * i + 2; w &= words(W)[i] == 1001u + i; u &= words(U)[i] == 3u * i + 4;   // U = V + 1 as D3 left V (X + 2), before D5 wrote it
        v &= words(V)[i] == 5001u + i; c &= words(C)[i] == 5001u + i; w2 &= words(W2)[i] == 7001u + i; w3 &= words(W3)[i] == 9001u + i; w4 &= words(W4)[i] == 11001u + i; w5 &= words(W5)[i] == 13001u + i;
    }
    EXPECT("Y = X + 1", 1, y); EXPECT("W = Z + 1", 1, w);
    EXPECT("U = X + 3 (D4 read V after D3, before D5)", 1, u); EXPECT("V = Q + 1 (D5 last)", 1, v);
    EXPECT("C = Q + 1 (the copy after D5)", 1, c); EXPECT("W2 = Z2 + 1, W3 = Z3 + 1, W4 = Z4 + 1, W5 = Z5 + 1", 1, w2 && w3 && w4 && w5);
    mtl_pool_del(g_mem); free(g_mem);
    printf("t_dispatch_range (%s): %d checks, %d failed\n", on ? "ranges, DM_NVN_DISPATCH_RANGE=1" : "DM_NVN_DISPATCH_RANGE=0", checks, failed); return failed != 0;
} }
