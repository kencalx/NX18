// Occlusion queries and conditional rendering with pooled query records (DM_NVN_QUERY_POOL, nvn_mtl.m vis_add / vis_op / rc_values), checked with the
// switch on and off (check_t_query_pool runs both, with and without the encode thread): the same answers either way.
// - one submission of 8,300 samples-passed queries, each a draw under its own scissor and a report, with a reset in the middle after a draw it drops: past
//   VIS_SLOTS slots the pass goes on in an overflow buffer, so the slots of one submission name two buffers; every report holds the running total at its place;
// - draws after a submission's last report are added at its completion and counted by the next submission's report;
// - 1,000 conditional draws on landed queries (equal / not equal, zero / nonzero) under counting: the report counts exactly the 500 drawn;
// - a micro-benchmark of the replay's per-query work (a slot, a report with its condition records, a condition) and of its completion, pooled and as before.
// It checks the profile key render_cond's replay, so the key is on whatever profile GAME names.
#include "game_profile.h"
#undef DM_GAME_RENDER_COND
#define DM_GAME_RENDER_COND 1
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#define P(name) ((NVNT_##name)nvn_lookup(#name))
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failures;
#define CHECK(c, name) do { int check_ok = !!(c); checks++; failures += !check_ok; printf("%s: %s\n", check_ok ? "PASS" : "FAIL", name); } while (0)
static void require(int ok, const char *name) { CHECK(ok, name); if (!ok) exit(2); }
enum { W = 8, H = 8, POOL_BYTES = 8 << 20, TEX_A = 0x80000, REPORTS = 0x100000, CMD = 0x200000, CMD_BYTES = 6 << 20, Q = 8300, Q_RESET = 4000, CONDS = 1000 };
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer command; static NVNtexture target; static uint8_t *memory;
static const float viewport[] = {0, 0, W, H};

static void begin(void) {   // a fresh stretch of command memory for each recording
    P(nvnCommandBufferAddCommandMemory)(&command, &pool, CMD, CMD_BYTES); P(nvnCommandBufferBeginRecording)(&command);
    const NVNtexture *colors[] = {&target};
    P(nvnCommandBufferSetRenderTargets)(&command, 1, colors, NULL, NULL, NULL);
    P(nvnCommandBufferSetViewports)(&command, 0, 1, viewport); P(nvnCommandBufferSetScissor)(&command, 0, 0, W, H);
}
static void run(void) {
    NVNcommandHandle h = P(nvnCommandBufferEndRecording)(&command); NVNsync sync;
    P(nvnSyncInitialize)(&sync, &device); P(nvnQueueSubmitCommands)(&queue, 1, &h);
    P(nvnQueueFenceSync)(&queue, &sync, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0);
    NVNsyncWaitResult r = P(nvnSyncWait)(&sync, 10000000000ull);
    require(r == NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED || r == NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED, "submission and its GPU work complete");
    P(nvnSyncFinalize)(&sync); P(nvnQueueFinish)(&queue);
}
static uint64_t *report(unsigned k) { return (uint64_t *)(memory + REPORTS + 32 * (size_t)k); }   // 16-byte records 32 bytes apart: each one's +16 neighbour stays 0
static void tri(void) { P(nvnCommandBufferDrawArrays)(&command, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3); }

// The replay's per-query work as Ocarina of Time does it, ~1,500 a frame: a draw's new slot, the report (its condition records, its 16 bytes noted, the post op)
// and a condition on it; then its completion reading the slots. Under g_sub_mu inside a submission of its own, between the real ones
typedef struct { double enc, done; } bench_t;
static bench_t bench(int pooled, int frames, int n) {
    pthread_mutex_lock(&g_sub_mu); g_qpool = pooled; mtl_sub_begin();
    id<MTLBuffer> vb = [g_dev newBufferWithLength:VIS_SLOTS * 8 options:MTLResourceStorageModeShared];
    static uint64_t *rr; if (!rr) { rr = calloc((size_t)n * 4 + 4, 8); }
    double best_enc = 1e30, best_done = 1e30;
    for (int f = 0; f < frames; f++) {
        uint64_t t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        for (int k = 0; k < n; k++) { uint64_t ad = (uint64_t)(uintptr_t)(rr + 4 * k + 2);
            vis_add(vb, (uint32_t)k); rc_note(ad, 2); hw_note(ad); post(vis_op(VIS_REPORT, ad, NVN_COUNTER_TYPE_SAMPLES_PASSED)); }
        for (int k = 0; k < n; k++) { uint64_t x, y; (void)rc_values((uint64_t)(uintptr_t)(rr + 4 * k + 2), &x, &y); }
        uint64_t t1 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        @autoreleasepool { uint64_t sum = 0; for (int i = 0; i < g_npost; i++) sum += vis_sum(&g_post[i], &g_va); vis_arena_done(&g_va); g_va_mark = 0; if (sum) abort(); }
        uint64_t t2 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
        g_npost = 0; g_nhw_sub = 0;
        if (f >= 3) { if (t1 - t0 < best_enc) best_enc = t1 - t0; if (t2 - t1 < best_done) best_done = t2 - t1; }   // the first frames make the records
    }
    mtl_sub_commit(); g_qpool = -1; pthread_mutex_unlock(&g_sub_mu);
    return (bench_t){best_enc / n, best_done / n};
}

int main(void) { @autoreleasepool {
    if (setvbuf(stdout, NULL, _IONBF, 0)) abort();
    // The long-pass split (DM_NVN_PASS_SPLIT, on by default on the Mac, off on iOS) loses the first slot's samples of a counting pass it splits: the first of the 8,300
    // reports read 0, with the query pool on or off (found by this test; not this change's). Off here, so the reports check the pooled records alone
    setenv("DM_NVN_PASS_SPLIT", "0", 0);
    mtl_init(); NSError *error = nil;
    int pooled = qpool_on(); printf("DM_NVN_QUERY_POOL: %s\n", pooled ? "on" : "off (=0)");
    id<MTLLibrary> library = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { const float2 p[] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0.5,1); }\n"
        "fragment float4 red() { return float4(1,0,0,1); }\n", nil, &error);
    if (!library) fprintf(stderr, "%s\n", error.localizedDescription.UTF8String);
    require(library != nil, "synthetic shaders compile");
    NvShader *vs = [NvShader new]; vs->fn = t4_fn(library, @"v");
    NvShader *fs = [NvShader new]; fs->stage = 1; fs->rf.color_mask = 1; fs->fn = t4_fn(library, @"red");
    NvProg *red = [NvProg new]; red->sh[0] = vs; red->sh[1] = fs;
    NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); require(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); require(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    require(!posix_memalign((void **)&memory, getpagesize(), POOL_BYTES), "pool storage allocated"); memset(memory, 0, POOL_BYTES);
    NVNmemoryPoolBuilder pb = {0}; P(nvnMemoryPoolBuilderSetDefaults)(&pb); P(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    P(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_BYTES); P(nvnMemoryPoolBuilderSetFlags)(&pb, 0x24); require(P(nvnMemoryPoolInitialize)(&pool, &pb), "pool initialized");
    require(P(nvnCommandBufferInitialize)(&command, &device), "command buffer initialized");
    NVNtextureBuilder tb = {0}; P(nvnTextureBuilderSetDefaults)(&tb); P(nvnTextureBuilderSetDevice)(&tb, &device);
    P(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D); P(nvnTextureBuilderSetSize2D)(&tb, W, H);
    P(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetStorage)(&tb, &pool, TEX_A);
    require(P(nvnTextureInitialize)(&target, &tb), "render target initialized");
    NVNprogram program; require(P(nvnProgramInitialize)(&program, &device), "program initialized");
    { prog_t *p = (prog_t *)&program; p->serial = nvn_new_serial(); serial_put(p->serial, red); }
    for (unsigned k = 0; k < Q + 8; k++) report(k)[0] = report(k)[1] = 0xdeadbeef;

    // The pipeline is built in the background: draws before it is ready are not drawn. Warm it up until a full draw counts its samples
    int warm = 0; uint64_t *w0 = report(Q + 5);
    for (int i = 0; i < 100 && !warm; i++) {
        begin(); P(nvnCommandBufferBindProgram)(&command, &program, 3); P(nvnCommandBufferResetCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED);
        tri(); P(nvnCommandBufferReportCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)w0); run();
        warm = w0[0] == W * H; if (!warm) usleep(20000);
    }
    require(warm, "the test pipeline is ready (a full draw counts its samples)");

    // 1. Many queries in one submission, a reset in the middle, past the visibility buffer's slots
    begin(); P(nvnCommandBufferBindProgram)(&command, &program, 3);
    P(nvnCommandBufferResetCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED);
    for (unsigned k = 0; k < Q; k++) {
        if (k == Q_RESET) { tri(); P(nvnCommandBufferResetCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED); }   // a draw the reset drops
        P(nvnCommandBufferSetScissor)(&command, 0, 0, 1 + k % 8, 1 + k / 8 % 8);
        tri(); P(nvnCommandBufferReportCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)report(k));
    }
    run();
    uint64_t acc = 0; unsigned bad = 0, first_bad = 0;
    for (unsigned k = 0; k < Q; k++) {
        if (k == Q_RESET) acc = 0;
        acc += (1 + k % 8) * (1 + k / 8 % 8);
        if (report(k)[0] != acc) { if (!bad++) first_bad = k; }
    }
    if (bad) printf("first wrong report %u: %llu, expected running total there\n", first_bad, (unsigned long long)report(first_bad)[0]);
    CHECK(!bad, "8,300 reports in one submission (an overflow visibility buffer past 8,192 slots, a reset after a dropped draw): each holds the running total at its place");
    CHECK(report(Q)[0] == 0xdeadbeef && report(0)[2] == 0, "no report written past the last one, and the +16 neighbours stay as they were");

    // 2. Draws after a submission's last report are counted by the next submission's report (no reset between)
    begin(); P(nvnCommandBufferBindProgram)(&command, &program, 3); tri(); tri(); run();
    begin(); P(nvnCommandBufferReportCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)report(Q + 1)); run();
    CHECK(report(Q + 1)[0] == acc + 2 * W * H, "slots after a submission's last report are added at its completion and counted by the next report");

    // 3. Conditional draws on landed queries, counted by a query of their own
    uint64_t *empty = report(Q + 2), *seen = report(Q + 3), *final = report(Q + 4);
    begin(); P(nvnCommandBufferResetCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED);
    P(nvnCommandBufferReportCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)empty);
    P(nvnCommandBufferBindProgram)(&command, &program, 3); tri();
    P(nvnCommandBufferReportCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)seen); run();
    CHECK(empty[0] == 0 && seen[0] == W * H, "the condition queries land with 0 and the drawn samples");
    begin(); P(nvnCommandBufferBindProgram)(&command, &program, 3); P(nvnCommandBufferResetCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED);
    for (unsigned i = 0; i < CONDS; i++) {   // not equal on seen and equal on empty draw; the other two do not
        P(nvnCommandBufferSetRenderEnableConditional)(&command, (NVNconditionalRenderMode)(i & 1), (NVNbufferAddress)(uintptr_t)(i & 2 ? seen : empty));
        tri(); P(nvnCommandBufferSetRenderEnable)(&command, 1);
    }
    P(nvnCommandBufferReportCounter)(&command, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)final); run();
    CHECK(final[0] == (uint64_t)CONDS / 2 * W * H, "1,000 conditions on landed queries: exactly the 500 that hold drawn");

    // 4. The micro-benchmark, pooled and as before (alternating, best frame of each)
    bench_t b[2][2];
    for (int round = 0; round < 2; round++) for (int m = 1; m >= 0; m--) b[round][m] = bench(m, 40, 1500);
    double pe = MIN(b[0][1].enc, b[1][1].enc), pd = MIN(b[0][1].done, b[1][1].done), oe = MIN(b[0][0].enc, b[1][0].enc), od = MIN(b[0][0].done, b[1][0].done);
    printf("bench (1,500 queries and conditions a frame, best frame of 2 x 37): replay %.1f ns a query pooled, %.1f as before (DM_NVN_QUERY_POOL=0); completion %.1f ns pooled, %.1f as before\n", pe, oe, pd, od);
    CHECK(g_va.n == 0 && g_nvs == 0, "no slot left pending after the benchmark's submissions");

    P(nvnQueueFinish)(&queue); P(nvnProgramFinalize)(&program); P(nvnTextureFinalize)(&target); P(nvnCommandBufferFinalize)(&command);
    P(nvnMemoryPoolFinalize)(&pool); P(nvnQueueFinalize)(&queue); P(nvnDeviceFinalize)(&device); free(memory);
    printf("query pool: %d checks, %d failed\n", checks, failures); return failures != 0;
} }
