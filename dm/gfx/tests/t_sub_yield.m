// The replay's safe point for the game's submits (DM_NVN_SUB_YIELD, nvn_queue.inc nq_sub_yield): a submit that finds g_sub_mu held by a long command node
// takes it between two of the node's commands and returns while the node is still being replayed; with the switch at 0 it waits for the node's end, as before.
// Program and queue finalization (sub_lock_whole) never get in mid-node: a finalize called while the node runs, with a submit waiting beside it, returns only
// after the node is done. Both jobs draw what they should: the long node's 40,000 draws all counted by its samples-passed report, the submitted job's colour
// read back. check_t_sub_yield runs it with the encode thread off and on, and with the switch off.
#include "game_profile.h"
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
enum { W = 8, H = 8, BYTES = W * H * 4, POOL_BYTES = 16 << 20, TEX_A = 0x80000, TEX_B = 0x90000, OUTPUT = 0xa0000, REPORTS = 0xb0000, CMD_A = 0x200000, CMD_B = 0xa00000, CMD_BYTES = 6 << 20, LONG = 40000 };
static NVNdevice device; static NVNqueue queue; static NVNmemoryPool pool; static NVNcommandBuffer cmd_a, cmd_b; static NVNtexture target_a, target_b; static uint8_t *memory;
static NVNbufferAddress output; static NVNprogram red, green, spare;
static const NVNcopyRegion region = {0, 0, 0, W, H, 1};
static const float viewport[] = {0, 0, W, H};

static void targets(NVNcommandBuffer *c, NVNtexture *t) {
    const NVNtexture *colors[] = {t};
    P(nvnCommandBufferSetRenderTargets)(c, 1, colors, NULL, NULL, NULL);
    P(nvnCommandBufferSetViewports)(c, 0, 1, viewport); P(nvnCommandBufferSetScissor)(c, 0, 0, W, H);
}
static void fence(NVNsync *s) { P(nvnSyncInitialize)(s, &device); P(nvnQueueFenceSync)(&queue, s, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0); }
static int published(NVNsync *s) {   // the replay has encoded everything before the fence (nq_sync_encoded)
    pthread_mutex_lock(&nq_mu); sync_t *st = (sync_t *)s; int p = st->fenced == 3 && ((nq_receipt *)(uintptr_t)st->fence)->published; pthread_mutex_unlock(&nq_mu); return p;
}
static void finish(NVNsync *s) {
    NVNsyncWaitResult r = P(nvnSyncWait)(s, 20000000000ull);
    require(r == NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED || r == NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED, "the job and its GPU work complete");
    P(nvnSyncFinalize)(s);
}
static int pixels(unsigned offset, unsigned r, unsigned g, unsigned b) {
    const uint8_t want[] = {r, g, b, 255};
    for (int i = 0; i < W * H; i++) if (memcmp(memory + OUTPUT + offset + i * 4, want, 4)) return 0;
    return 1;
}
static void init_texture(NVNtexture *texture, unsigned offset) {
    NVNtextureBuilder tb = {0}; P(nvnTextureBuilderSetDefaults)(&tb); P(nvnTextureBuilderSetDevice)(&tb, &device);
    P(nvnTextureBuilderSetTarget)(&tb, NVN_TEXTURE_TARGET_2D); P(nvnTextureBuilderSetSize2D)(&tb, W, H);
    P(nvnTextureBuilderSetFormat)(&tb, NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetStorage)(&tb, &pool, offset);
    require(P(nvnTextureInitialize)(texture, &tb), "texture initialized");
}
static void init_program(NVNprogram *program, NvProg *compiled) {
    require(P(nvnProgramInitialize)(program, &device), "program initialized");
    prog_t *p = (prog_t *)program; p->serial = nvn_new_serial(); serial_put(p->serial, compiled);
}
// The long node: LONG draws on target A under samples-passed counting, one command node (no wait, fence or signal in it)
static NVNcommandHandle record_long(uint64_t *rep) {
    P(nvnCommandBufferAddCommandMemory)(&cmd_a, &pool, CMD_A, CMD_BYTES); P(nvnCommandBufferBeginRecording)(&cmd_a);
    targets(&cmd_a, &target_a); P(nvnCommandBufferBindProgram)(&cmd_a, &red, 3);
    P(nvnCommandBufferResetCounter)(&cmd_a, NVN_COUNTER_TYPE_SAMPLES_PASSED);
    for (int i = 0; i < LONG; i++) P(nvnCommandBufferDrawArrays)(&cmd_a, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3);
    P(nvnCommandBufferReportCounter)(&cmd_a, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)rep);
    P(nvnCommandBufferCopyTextureToBuffer)(&cmd_a, &target_a, NULL, &region, output, 0);
    return P(nvnCommandBufferEndRecording)(&cmd_a);
}
// The short job a game thread submits meanwhile: green on target B, read back
static NVNcommandHandle record_short(void) {
    P(nvnCommandBufferAddCommandMemory)(&cmd_b, &pool, CMD_B, 1 << 16); P(nvnCommandBufferBeginRecording)(&cmd_b);
    targets(&cmd_b, &target_b); P(nvnCommandBufferBindProgram)(&cmd_b, &green, 3);
    P(nvnCommandBufferDrawArrays)(&cmd_b, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3);
    P(nvnCommandBufferCopyTextureToBuffer)(&cmd_b, &target_b, NULL, &region, output + BYTES, 0);
    return P(nvnCommandBufferEndRecording)(&cmd_b);
}
static NVNsync long_sync; static _Atomic int fin_done; static _Atomic uint64_t fin_draws; static uint64_t draws0;
static void *finalize_thread(void *arg) { (void)arg; P(nvnProgramFinalize)(&spare); atomic_store(&fin_draws, g_stat_draw - draws0); atomic_store(&fin_done, 1); return NULL; }   // the replay's draws when it returned

int main(void) { @autoreleasepool {
    if (setvbuf(stdout, NULL, _IONBF, 0)) abort(); mtl_init(); NSError *error = nil;
    id<MTLLibrary> library = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\n"
        "vertex float4 v(uint i [[vertex_id]]) { const float2 p[] = {float2(-1,-1),float2(3,-1),float2(-1,3)}; return float4(p[i],0.5,1); }\n"
        "fragment float4 red() { return float4(1,0,0,1); } fragment float4 green() { return float4(0,1,0,1); }\n", nil, &error);
    require(library != nil, "synthetic shaders compile");
    NvShader *vs = [NvShader new]; vs->fn = t4_fn(library, @"v");
    NvProg *pr[2]; for (int i = 0; i < 2; i++) { NvShader *fs = [NvShader new]; fs->stage = 1; fs->rf.color_mask = 1; fs->fn = t4_fn(library, i ? @"green" : @"red"); pr[i] = [NvProg new]; pr[i]->sh[0] = vs; pr[i]->sh[1] = fs; }
    NVNdeviceBuilder db = {0}; P(nvnDeviceBuilderSetDefaults)(&db); require(P(nvnDeviceInitialize)(&device, &db), "device initialized");
    NVNqueueBuilder qb = {0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb, &device); require(P(nvnQueueInitialize)(&queue, &qb), "queue initialized");
    require(!posix_memalign((void **)&memory, getpagesize(), POOL_BYTES), "pool storage allocated"); memset(memory, 0, POOL_BYTES);
    NVNmemoryPoolBuilder pb = {0}; P(nvnMemoryPoolBuilderSetDefaults)(&pb); P(nvnMemoryPoolBuilderSetDevice)(&pb, &device);
    P(nvnMemoryPoolBuilderSetStorage)(&pb, memory, POOL_BYTES); P(nvnMemoryPoolBuilderSetFlags)(&pb, 0x24); require(P(nvnMemoryPoolInitialize)(&pool, &pb), "pool initialized");
    NVNbufferBuilder bb = {0}; NVNbuffer buffer; P(nvnBufferBuilderSetDefaults)(&bb); P(nvnBufferBuilderSetDevice)(&bb, &device);
    P(nvnBufferBuilderSetStorage)(&bb, &pool, OUTPUT, BYTES * 2); require(P(nvnBufferInitialize)(&buffer, &bb), "readback buffer initialized"); output = P(nvnBufferGetAddress)(&buffer);
    require(P(nvnCommandBufferInitialize)(&cmd_a, &device) && P(nvnCommandBufferInitialize)(&cmd_b, &device), "command buffers initialized");
    init_texture(&target_a, TEX_A); init_texture(&target_b, TEX_B);
    init_program(&red, pr[0]); init_program(&green, pr[1]); init_program(&spare, pr[1]);
    uint64_t *rep = (uint64_t *)(memory + REPORTS), *warm = rep + 4;

    // The pipelines are built in the background: warm both up until a draw of each counts its samples
    int ready = 0;
    for (int i = 0; i < 100 && !ready; i++) {
        P(nvnCommandBufferAddCommandMemory)(&cmd_b, &pool, CMD_B, 1 << 16); P(nvnCommandBufferBeginRecording)(&cmd_b);
        P(nvnCommandBufferResetCounter)(&cmd_b, NVN_COUNTER_TYPE_SAMPLES_PASSED);
        targets(&cmd_b, &target_a); P(nvnCommandBufferBindProgram)(&cmd_b, &red, 3); P(nvnCommandBufferDrawArrays)(&cmd_b, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3);
        targets(&cmd_b, &target_b); P(nvnCommandBufferBindProgram)(&cmd_b, &green, 3); P(nvnCommandBufferDrawArrays)(&cmd_b, NVN_DRAW_PRIMITIVE_TRIANGLES, 0, 3);
        P(nvnCommandBufferReportCounter)(&cmd_b, NVN_COUNTER_TYPE_SAMPLES_PASSED, (NVNbufferAddress)(uintptr_t)warm);
        NVNcommandHandle h = P(nvnCommandBufferEndRecording)(&cmd_b); NVNsync s;
        P(nvnQueueSubmitCommands)(&queue, 1, &h); fence(&s); finish(&s);
        ready = warm[0] == 2 * W * H; if (!ready) usleep(20000);
    }
    require(ready, "the test pipelines are ready");
    int on = nq_yield_on(); printf("DM_NVN_SUB_YIELD: %s\n", on ? "on" : "off (=0)");   // read at the worker's start

    // 1. A submit while the long node is replayed
    NVNcommandHandle hl = record_long(rep), hs = record_short();
    uint64_t w0[7], w1[7]; nq_wait_stats(w0); uint64_t y0 = atomic_load(&nq_stat_yields), yn0 = atomic_load(&nq_stat_yield_ns), d0 = g_stat_draw; draws0 = d0;
    P(nvnQueueSubmitCommands)(&queue, 1, &hl); fence(&long_sync);
    uint64_t deadline = now_ns() + 5000000000ull;
    while (g_stat_draw - d0 < 2000 && now_ns() < deadline) usleep(50);   // the replay is in the long node
    CHECK(!published(&long_sync), "the long node is still being replayed when the game thread submits");
    pthread_t fin; pthread_create(&fin, NULL, finalize_thread, NULL);   // a finalize beside the submit: it may find the lock lent, and must wait for the node's end
    uint64_t t0 = now_ns(); P(nvnQueueSubmitCommands)(&queue, 1, &hs); uint64_t t1 = now_ns();
    uint64_t draws_at = g_stat_draw - d0; int mid = !published(&long_sync) && draws_at < LONG;
    NVNsync short_sync; fence(&short_sync);
    finish(&long_sync); finish(&short_sync); pthread_join(fin, NULL);
    nq_wait_stats(w1); uint64_t yields = atomic_load(&nq_stat_yields) - y0, yield_ns = atomic_load(&nq_stat_yield_ns) - yn0;
    printf("submit returned after %.3f ms with %llu of the long node's %d draws replayed; %llu lock yields (the replay without the lock %.3f ms), submit waits %llu (%.3f ms)\n", (t1 - t0) / 1e6,
           (unsigned long long)draws_at, LONG, (unsigned long long)yields, yield_ns / 1e6, (unsigned long long)(w1[4] - w0[4]), (w1[3] - w0[3]) / 1e6);
    if (on) {
        CHECK(mid && yields >= 1, "with the safe point, the submit gets the lock between two commands of the long node and returns before the node ends");
    } else {
        CHECK(!mid && yields == 0, "with DM_NVN_SUB_YIELD=0 the submit waits for the long node's end, as before");
    }
    CHECK(w1[6] - w0[6] >= yields && w1[5] - w0[5] >= yield_ns, "each lend counts as a replay g_sub_mu wait, with its time");
    CHECK(atomic_load(&fin_done) && atomic_load(&fin_draws) >= LONG, "a program finalize called while the node runs returns only after the node is done");
    CHECK(rep[0] == (uint64_t)LONG * W * H, "every one of the long node's draws drawn and counted");
    CHECK(pixels(0, 255, 0, 0) && pixels(BYTES, 0, 255, 0), "both jobs' pictures as drawn");

    // 2. A starved submitter: it counts itself waiting but never runs to take the lent lock (woken, not scheduled). The replay lends once, waits at most
    // NQ_YIELD_WAIT_NS, and lends no more in that node
    hl = record_long(rep); rep[0] = 0;
    uint64_t y1 = atomic_load(&nq_stat_yields), yn1 = atomic_load(&nq_stat_yield_ns), to1 = atomic_load(&nq_stat_yield_timeouts); d0 = g_stat_draw;
    atomic_fetch_add(&g_exec_yield_want, 1);
    P(nvnQueueSubmitCommands)(&queue, 1, &hl); fence(&long_sync); finish(&long_sync);
    atomic_fetch_sub(&g_exec_yield_want, 1);
    uint64_t sy = atomic_load(&nq_stat_yields) - y1, sns = atomic_load(&nq_stat_yield_ns) - yn1, sto = atomic_load(&nq_stat_yield_timeouts) - to1;
    printf("starved submitter: %llu lends (%llu not taken), the replay without the lock %.3f ms in a node of %d draws\n", (unsigned long long)sy, (unsigned long long)sto, sns / 1e6, LONG);
    if (on) CHECK(sy == 1 && sto == 1 && sns < 2000000, "a lend no submit takes ends the lending for the node: one wait of at most about 0.2 ms (under 2 ms with scheduling slack)");
    else CHECK(sy == 0, "with DM_NVN_SUB_YIELD=0 nothing is lent");
    CHECK(rep[0] == (uint64_t)LONG * W * H, "the long node drawn whole beside the starved submitter");

    P(nvnQueueFinish)(&queue); P(nvnProgramFinalize)(&red); P(nvnProgramFinalize)(&green);
    P(nvnTextureFinalize)(&target_a); P(nvnTextureFinalize)(&target_b); P(nvnCommandBufferFinalize)(&cmd_a); P(nvnCommandBufferFinalize)(&cmd_b);
    P(nvnBufferFinalize)(&buffer); P(nvnMemoryPoolFinalize)(&pool); P(nvnQueueFinalize)(&queue); P(nvnDeviceFinalize)(&device); free(memory);
    printf("submit yield: %d checks, %d failed\n", checks, failures); return failures != 0;
} }
