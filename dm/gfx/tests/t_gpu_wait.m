// The game's own waits for the GPU give the waiting guest thread's core away while they block, as kernel waits do on Horizon (hle_nvn.c gpu_wait_begin, nvn_acquire_block
// → hle_thread.c dm_thread_gpu_wait, t_gpu_wait_hold.c's stand-in here). Luigi's Mansion 3's render thread ('CommandQueue', priority 30, core 1) calls nvnQueueFinish before
// each present; after the acquire's waits were marked (ac1260cc) the finish still waited in host code the scheduler counted as running guest code, and the same-core handoff
// that woke the thread held 'worker core 1' (44, core 1) through it: 871 ms of every second, 16,581 polls of 50 µs a second on the iPhone 18 Pro Max, its acquires blocking
// for nothing (the finish had waited out the GPU and the last present). Real NVN queue, replay, Metal submissions and present queue:
//   - a finish whose queue the replay holds (a wait for an NVN event) gives the core away once, before the replay encodes, and is back on return;
//   - a sync wait on a fence behind a GPU gate does the same in the GPU wait (DM_NVN_FAST_WAKE=0: the feedback wait instead of the event's), and its timeout still ends on
//     time when entering the GPU wait waits for the thread lock;
//   - a finish after a present, with snapshots off (LM3's setting) and the present thread stalled, gives it away while it waits for the present's ticket, as a GPU wait;
//   - a poll (timeout 0), a wait already satisfied, a finish with nothing left, a host thread's own wait for the GPU and any wait under the deterministic clock keep the core.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
extern _Atomic int gw_enter, gw_leave, dw_enter, dw_leave, gw_det; extern _Atomic unsigned gw_hold_us; extern _Atomic uint64_t gw_enter_ns;
static int checks, failed;
#define CHECK(c, ...) do { checks++; int ok_ = !!(c); failed += !ok_; printf("%s ", ok_ ? "PASS" : "FAIL"); printf(__VA_ARGS__); printf("\n"); } while (0)
static NVNdevice dev; static NVNqueue queue;

// A guest thread's call on a thread of its own, so the test can look while it blocks
typedef struct { int kind; NVNsync *sync; uint64_t timeout; NVNsyncWaitResult res; uint64_t t0, t1; int after_e, after_l; dispatch_semaphore_t done; } call_t;
static void *call_thread(void *arg) { @autoreleasepool {
    call_t *c = arg; c->t0 = now_ns();
    if (c->kind == 0) h_nvnQueueFinish(&queue); else c->res = h_nvnSyncWait(c->sync, c->timeout);
    c->t1 = now_ns(); c->after_e = t_acq_in; c->after_l = t_acq_blocked;   // the scope is this thread's: both 0 once the call is back
    dispatch_semaphore_signal(c->done);
} return NULL; }
static pthread_t call_start(call_t *c) { c->done = dispatch_semaphore_create(0); pthread_t th; if (pthread_create(&th, NULL, call_thread, c)) exit(2); return th; }
static int call_back_within(call_t *c, int64_t ms) { return dispatch_semaphore_wait(c->done, dispatch_time(DISPATCH_TIME_NOW, ms * 1000000ll)) == 0; }

static NVNmemoryPool pool; static NVNevent event; static uint8_t *memory;
static void event_setup(void) {
    if (posix_memalign((void **)&memory, getpagesize(), 65536)) exit(2); memset(memory, 0, 65536);
    NVNmemoryPoolBuilder pb = {0}; h_nvnMemoryPoolBuilderSetDefaults(&pb); h_nvnMemoryPoolBuilderSetDevice(&pb, &dev);
    h_nvnMemoryPoolBuilderSetStorage(&pb, memory, 65536); h_nvnMemoryPoolBuilderSetFlags(&pb, 0x24);
    CHECK(h_nvnMemoryPoolInitialize(&pool, &pb), "event pool initialized");
    NVNeventBuilder eb = {0}; h_nvnEventBuilderSetDefaults(&eb); h_nvnEventBuilderSetStorage(&eb, &pool, 32768);
    CHECK(h_nvnEventInitialize(&event, &eb), "event initialized");
}
// A recording that waits for the event to reach value: the replay parks the queue there, so what is submitted after it is not encoded until the event is signalled
static NVNcommandHandle wait_recording(NVNcommandBuffer *cmd, uint32_t value, int64_t at) {
    h_nvnCommandBufferInitialize(cmd, &dev); h_nvnCommandBufferAddCommandMemory(cmd, &pool, at, 8192);
    h_nvnCommandBufferBeginRecording(cmd); h_nvnCommandBufferWaitEvent(cmd, &event, NVN_EVENT_WAIT_MODE_EQUAL, value);
    return h_nvnCommandBufferEndRecording(cmd);
}
// A fence behind a gate on the Metal queue: completes only once the gate opens
static uint64_t gated_fence(id<MTLSharedEvent> gate) {
    [g_q4 waitForEvent:gate value:1];
    mtl_sub_begin(); return mtl_sub_commit();
}
static void settle(void) { NVNsync s; h_nvnSyncInitialize(&s, &dev); h_nvnQueueFenceSync(&queue, &s, NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE, 0); h_nvnSyncWait(&s, 2000000000ull); h_nvnSyncFinalize(&s); }

static void finish_replay_case(void) {
    NVNcommandBuffer cmd; NVNcommandHandle h = wait_recording(&cmd, 1, 0);
    h_nvnQueueSubmitCommands(&queue, 1, &h);
    int e0 = gw_enter, l0 = gw_leave, d0 = dw_enter; call_t c = {.kind = 0};
    pthread_t th = call_start(&c);
    int back = call_back_within(&c, 150);
    CHECK(!back, "finish waits while the replay holds its queue for an event");
    CHECK(gw_enter == e0 + 1 && gw_leave == l0 && dw_enter == d0, "and has given its core away once, as a GPU wait (entries %d, leaves %d, display waits %d)", gw_enter - e0, gw_leave - l0, dw_enter - d0);
    CHECK(gw_enter_ns >= c.t0 && gw_enter_ns - c.t0 < 100000000ull, "entered %.3f ms into the finish, before the replay encoded its work", gw_enter_ns >= c.t0 ? (gw_enter_ns - c.t0) / 1e6 : -1.0);
    h_nvnEventSignal(&event, NVN_EVENT_SIGNAL_MODE_WRITE, 1);
    if (!back) back = call_back_within(&c, 2000);
    CHECK(back, "finish returns once the event lets the replay go on");
    if (!back) exit(2); pthread_join(th, NULL);
    CHECK(gw_enter == e0 + 1 && gw_leave == l0 + 1 && !c.after_e && !c.after_l, "entered once in all and left on return (entries %d, leaves %d)", gw_enter - e0, gw_leave - l0);
    h_nvnCommandBufferFinalize(&cmd);
    settle();
    int e1 = gw_enter; uint64_t t0 = now_ns(); h_nvnQueueFinish(&queue);
    CHECK(gw_enter == e1, "a finish with nothing left to wait for keeps its core (%.3f ms)", (now_ns() - t0) / 1e6);
}
static void sync_gpu_case(const char *how) {
    settle();
    id<MTLSharedEvent> gate = [g_dev newSharedEvent]; if (!gate) exit(2);
    uint64_t f = gated_fence(gate);
    sync_t s = {MAGIC('S', 'Y', 'N', 'C'), 1, f};
    int e0 = gw_enter, l0 = gw_leave, d0 = dw_enter;
    CHECK(h_nvnSyncWait((NVNsync *)&s, 0) == NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED && gw_enter == e0, "%s: a poll of a fence behind the gate keeps its core", how);
    CHECK(!mtl_wait(f, 20000000ull) && gw_enter == e0, "%s: a host thread's own wait for it (no game wait around it) takes no GPU wait", how);
    // Entering the GPU wait can wait for the thread lock G (gw_hold_us stands for it): the game's timeout still ends on time, the time left read after the entry, as the acquire's
    // pacing sleep does. Read before, a 60 ms wait whose entry waited 60 ms for G expired after 120 ms
    {
        gw_hold_us = 60000; uint64_t t0 = now_ns();
        NVNsyncWaitResult r = h_nvnSyncWait((NVNsync *)&s, 60000000ull); uint64_t took = now_ns() - t0;
        gw_hold_us = 0;
        CHECK(r == NVN_SYNC_WAIT_RESULT_TIMEOUT_EXPIRED && took < 95000000ull && gw_enter == e0 + 1 && gw_leave == l0 + 1 && !t_acq_in && !t_acq_blocked,
              "%s: a 60 ms sync wait whose GPU wait entry waits 60 ms for the thread lock expires at its timeout (%.1f ms), entered and left once", how, took / 1e6);
        e0 = gw_enter; l0 = gw_leave;
    }
    call_t c = {.kind = 1, .sync = (NVNsync *)&s, .timeout = 2000000000ull};
    pthread_t th = call_start(&c);
    int back = call_back_within(&c, 150);
    CHECK(!back && gw_enter == e0 + 1 && gw_leave == l0 && dw_enter == d0, "%s: a sync wait on it blocks with its core given away once, as a GPU wait (entries %d, leaves %d)", how, gw_enter - e0, gw_leave - l0);
    gate.signaledValue = 1;
    if (!back) back = call_back_within(&c, 2000);
    if (!back) exit(2); pthread_join(th, NULL);
    CHECK(c.res == NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED && gw_leave == l0 + 1 && !c.after_e && !c.after_l, "%s: it is satisfied once the gate opens and left the GPU wait on return", how);
    e0 = gw_enter;
    CHECK(h_nvnSyncWait((NVNsync *)&s, 2000000000ull) == NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED && gw_enter == e0, "%s: a wait already satisfied keeps its core", how);
}
static tex_t source(unsigned i) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; uint8_t bytes[256]; memset(bytes, 73 + i, sizeof bytes);
    [mt replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:bytes bytesPerRow:32];
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = 91001 + i};
    t.d.width = t.d.height = 8; t.d.depth = t.d.levels = t.d.samples = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    serial_put(t.serial, mt); res_add(mt); res_commit(); return t;
}
// LM3 on the iPhone has snapshots off: a finish after a present waits for that present's ticket, which the present thread (stalled here, as a display that takes its time)
// processes late. On Horizon the finish is a kernel wait for the GPU; here that wait is the finish's too, and gives the core away as a GPU wait, not a display wait
static void finish_present_case(void) {
    settle();
    tex_t textures[2]; win_t win = {.ntex = 2};
    for (int i = 0; i < 2; i++) { textures[i] = source(i); win.tex[i] = (NVNtexture *)&textures[i]; }
    int idx; h_nvnWindowAcquireTexture((NVNwindow *)&win, NULL, &idx);
    mtl_present_test_stall(300000000);
    h_nvnQueuePresentTexture(&queue, (NVNwindow *)&win, idx);
    int e0 = gw_enter, l0 = gw_leave, d0 = dw_enter, dl0 = dw_leave; call_t c = {.kind = 0};
    pthread_t th = call_start(&c);
    int back = call_back_within(&c, 150);
    CHECK(!back, "finish after a present (snapshots off) waits for the stalled present's ticket");
    CHECK(gw_enter == e0 + 1 && gw_leave == l0 && dw_enter == d0, "and has given its core away once, as a GPU wait, not as the acquire's display wait (entries %d, display waits %d)", gw_enter - e0, dw_enter - d0);
    if (!back) back = call_back_within(&c, 3000);
    if (!back) exit(2); pthread_join(th, NULL);
    CHECK(gw_leave == l0 + 1 && dw_leave == dl0 && !c.after_e && !c.after_l, "and left it on return, after %.0f ms", (c.t1 - c.t0) / 1e6);
    mtl_present_test_stall(0);
    h_nvnWindowFinalize((NVNwindow *)&win); h_nvnQueueFinish(&queue);
}
static void det_case(void) {
    settle(); gw_det = 1;
    NVNcommandBuffer cmd; NVNcommandHandle h = wait_recording(&cmd, 2, 8192);
    h_nvnQueueSubmitCommands(&queue, 1, &h);
    int e0 = gw_enter; call_t c = {.kind = 0};
    pthread_t th = call_start(&c);
    int back = call_back_within(&c, 100);
    CHECK(!back && gw_enter == e0, "under the deterministic clock a finish that blocks keeps its core (whether it blocks depends on the host's load)");
    h_nvnEventSignal(&event, NVN_EVENT_SIGNAL_MODE_WRITE, 2);
    if (!back) back = call_back_within(&c, 2000);
    if (!back) exit(2); pthread_join(th, NULL);
    CHECK(gw_enter == e0 && !c.after_e && !c.after_l, "and takes no GPU wait in all");
    gw_det = 0; h_nvnCommandBufferFinalize(&cmd);
}
int main(int argc, char **argv) { @autoreleasepool {
    alarm(30); setbuf(stdout, NULL);
    int fast = !(argc > 1 && !strcmp(argv[1], "feedback"));
    if (!fast) setenv("DM_NVN_FAST_WAKE", "0", 1);
    setenv("DM_PRESENT_SNAP", "0", 1); setenv("DM_PRESENT_HZ", "0", 1); setenv("DM_RT", "0", 1); setenv("DM_FRAME_WG", "0", 1);
    mtl_init();
    NVNdeviceBuilder db = {0}; h_nvnDeviceBuilderSetDefaults(&db); CHECK(h_nvnDeviceInitialize(&dev, &db), "device initialized");
    NVNqueueBuilder qb = {0}; h_nvnQueueBuilderSetDefaults(&qb); h_nvnQueueBuilderSetDevice(&qb, &dev);
    CHECK(h_nvnQueueInitialize(&queue, &qb), "queue initialized");
    state_reset(); memset(&R, 0, sizeof R); mtl_sub_begin(); CHECK(mtl_wait(mtl_sub_commit(), 2000000000ull), "a first submission completed");
    event_setup();
    finish_replay_case();
    sync_gpu_case(fast ? "the GPU's signal (fast wake)" : "the feedback wait (DM_NVN_FAST_WAKE=0)");
    finish_present_case();
    det_case();
    printf("t_gpu_wait: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
