// Feed a delayed CPU/GPU sample to the production counter replay without a Metal device.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"   // the present (h_nvnQueuePresentTexture) advances the deterministic clock
#undef g_ft

module_t *g_mod;
int g_nmod;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void *module_sym(module_t *m, const char *name) { (void)m; (void)name; return NULL; }
void *guest_sym(const char *name) { (void)name; return NULL; }
void svc_thread_dump(void) {}

static unsigned checks, failures;
#define CHECK(label, condition) do { checks++; if (!(condition)) { failures++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

@interface ClockDevice : NSObject
@property MTLTimestamp cpu;
@property MTLTimestamp gpu;
@end
@implementation ClockDevice
- (void)sampleTimestamps:(MTLTimestamp *)cpu gpuTimestamp:(MTLTimestamp *)gpu { *cpu = self.cpu; *gpu = self.gpu; }
- (uint64_t)queryTimestampFrequency { return 1000000000; }
@end

@interface ClockHeap : NSObject
@property uint64_t boundary;
@property uint64_t *slots;   // when set: the stamp of each slot, 0 for slot 0 too
@property NSUInteger nslots;
@end
@implementation ClockHeap
- (NSData *)resolveCounterRange:(NSRange)range {
    if (range.length != 1) return nil;
    MTL4TimestampHeapEntry entry = {.timestamp = self.slots ? (range.location < self.nslots ? self.slots[range.location] : 0) : self.boundary};
    return self.slots || range.location == 0 ? [NSData dataWithBytes:&entry length:sizeof entry] : nil;
}
@end

// The GPU timeline (sub_place, place_back). Three submissions of one frame, each a single command buffer (guest ns), and what the Switch would have done with them: A ready at 1,000
// runs 1,000 to 2,000. B was submitted at 1,500, while A ran, but the host translated it first: the GPU ran it 4,000 to 6,000, idle 2,000 to 4,000 for the host alone. C was submitted
// at 7,000, after B's end on the Switch (4,000) and here (6,000): the GPU's wait for it is the game's own, and it ran 7,500 to 8,000. The timeline places B at 2,000 to 4,000 and C at
// 7,000 to 7,500
static uint64_t off_of(uint64_t fence, uint64_t ready, uint64_t c0, uint64_t c1) {
    static post_rec r; memset(&r, 0, sizeof r); atomic_store(&r.fence, fence); r.t_ready = ready;
    return sub_place(&r, c0, c1);
}
static void check_timeline(void) {
    g_line_fence = 0; g_line_end = 0;
    post_op top = {.type = 0x10}, end = {.type = 0};
    CHECK("a submission ready when the GPU starts it keeps its times", off_of(1, 1000, 1000, 2000) == 0);
    uint64_t off = off_of(2, 1500, 4000, 6000);
    CHECK("the GPU's wait for the host's translation is left out", off == 2000);
    CHECK("its start report is where the previous submission ended", rep_ticks(&top, NULL, 0, 4000, 6000, off) == nvn_timestamp_from_ns(2000));
    CHECK("its end report keeps its own GPU time", rep_ticks(&end, NULL, 0, 4000, 6000, off) == nvn_timestamp_from_ns(4000));
    off = off_of(3, 7000, 7500, 8000);
    CHECK("the GPU's wait for the game's own submit is kept", off == 500 && rep_ticks(&top, NULL, 0, 7500, 8000, off) == nvn_timestamp_from_ns(7000));
    CHECK("the frame's span is its GPU work and the game's own wait: 6,500 ns (7,000 with the host's)", rep_ticks(&end, NULL, 0, 7500, 8000, off) - nvn_timestamp_from_ns(1000) == nvn_timestamp_from_ns(7500) - nvn_timestamp_from_ns(1000));
    CHECK("a submission with no ready time is not moved", off_of(4, 0, 9000, 9500) == 0);
    CHECK("a submission after it is not placed before its end", off_of(5, 8000, 10000, 10500) == 500);
    CHECK("a submission placed out of order is not moved", off_of(2, 1500, 10000, 11000) == 0);
    CHECK("nor one that the timeline would move later than the GPU ran it", off_of(6, 12000, 11000, 11500) == 0 && g_line_end == 11500);
    // A submission of two command buffers, with a timestamp boundary inside the first (segments 0 and 1, committed after segment 1: 4,000 to 5,000) and the last 6,000 to 7,000,
    // ready at 1,500 while the one before ran 1,000 to 2,000: it is placed from its first command buffer's start, 2,000 earlier, and its own 1,000 between command buffers is out too
    g_line_fence = 0; g_line_end = 0;
    CHECK("the first of the pair keeps its times", off_of(1, 1000, 1000, 2000) == 0);
    static seg_clk two; memset(&two, 0, sizeof two); two.ncm = 1; two.cm[0] = 1;
    atomic_store(&two.t[1][0], 4000); atomic_store(&two.t[1][1], 5000);
    static post_rec r2; memset(&r2, 0, sizeof r2); atomic_store(&r2.fence, 2); r2.t_ready = 1500; r2.sc = &two; r2.seg_last = 2;
    off = sub_place(&r2, 6000, 7000);
    post_op top1 = {.type = 0x10, .seg = 1}, end2 = {.type = 0, .seg = 2};
    CHECK("a submission of several command buffers is placed from its first one's start", off == 2000);
    CHECK("its first segment's report reads where the one before ended", rep_ticks(&top1, &two, 2, 6000, 7000, off) == nvn_timestamp_from_ns(2000));
    CHECK("its end leaves out both waits: its own GPU work after the one before", rep_ticks(&end2, &two, 2, 6000, 7000, off) == nvn_timestamp_from_ns(4000));
    // Then one of two command buffers whose first one's feedback has not arrived (a SyncWait woke on the GPU's signal first), ready at 7,000, its last 10,000 to 11,000: it is not
    // moved, and its end report reads 11,000. The next, submitted at 7,500 and run 11,500 to 12,500, starts there, not at its ready time: no report reads earlier than one before it
    static seg_clk miss; memset(&miss, 0, sizeof miss); miss.ncm = 1; miss.cm[0] = 1;
    static post_rec r3; memset(&r3, 0, sizeof r3); atomic_store(&r3.fence, 3); r3.t_ready = 7000; r3.sc = &miss; r3.seg_last = 2;
    off = sub_place(&r3, 10000, 11000);
    CHECK("with its first command buffer's feedback missing nothing is moved", off == 0 && rep_ticks(&end2, &miss, 2, 10000, 11000, off) == nvn_timestamp_from_ns(11000));
    off = off_of(4, 7500, 11500, 12500);
    CHECK("the timeline goes on from the end of a submission it did not move", off == 500 && rep_ticks(&top, NULL, 0, 11500, 12500, off) == nvn_timestamp_from_ns(11000));
    g_line_fence = 0; g_line_end = 0;
}
// A submission of three command buffers, its GPU idle between them while the host translated (sub_cut commits only once the GPU has run out of work):
//   command buffer 0: segments 0 and 1, GPU 0 to 3,000 ns, committed at the boundary after segment 1; the boundary's stamp lands at the start of command buffer 1 (4,010)
//   command buffer 1: segment 2, 4,000 to 6,000, committed after segment 2; that boundary's stamp landed in its last encoder, before the commit (5,990)
//   the last one: segments 3 and 4, 9,000 to 12,000 (c0 / c1), the stamp at the boundary between them 10,000
// A span of reports reads the GPU's work alone: the 1,000 ns and 3,000 ns gaps are left out once a time is past their middle
static void check_idle_gaps(ClockDevice *device, ClockHeap *heap) {
    uint64_t g0 = device.cpu - 50000, off = device.gpu - device.cpu;   // guest time of the submission's start; a heap stamp is on the GPU clock, guest + off
    static seg_clk clock; memset(&clock, 0, sizeof clock);
    clock.nb = 5; for (int k = 0; k < 5; k++) clock.b[k] = (uint16_t)k;
    clock.ncm = 2; clock.cm[0] = 1; clock.cm[1] = 2;
    atomic_store(&clock.t[1][0], g0); atomic_store(&clock.t[1][1], g0 + 3000);
    atomic_store(&clock.t[2][0], g0 + 4000); atomic_store(&clock.t[2][1], g0 + 6000);
    uint64_t c0 = g0 + 9000, c1 = g0 + 12000;
    uint64_t slots[5] = {g0 + 5 + off, g0 + 1500 + off, g0 + 4010 + off, g0 + 5990 + off, g0 + 10000 + off};
    heap.slots = slots; heap.nslots = 5;
    CHECK("no idle before the first commit", seg_idle_before(&clock, g0 + 3400, c0) == 0);
    CHECK("a gap counts once a time is past its middle", seg_idle_before(&clock, g0 + 3600, c0) == 1000);
    CHECK("both gaps before the last command buffer", seg_idle_before(&clock, g0 + 9000, c0) == 4000);
    post_op top0 = {.type = 0x10, .seg = 0}, end1 = {.type = 0, .seg = 1}, end2 = {.type = 0, .seg = 2}, top4 = {.type = 0x10, .seg = 4}, end4 = {.type = 0, .seg = 4};
    CHECK("the first report keeps its time", rep_ticks(&top0, &clock, 4, c0, c1, 0) == nvn_timestamp_from_ns(g0 + 5));
    CHECK("a stamp written after a commit leaves out the gap before it", rep_ticks(&end1, &clock, 4, c0, c1, 0) == nvn_timestamp_from_ns(g0 + 3010));
    CHECK("a stamp written before a commit keeps the time of its command buffer", rep_ticks(&end2, &clock, 4, c0, c1, 0) == nvn_timestamp_from_ns(g0 + 4990));
    CHECK("a stamp in the last command buffer leaves out both gaps", rep_ticks(&top4, &clock, 4, c0, c1, 0) == nvn_timestamp_from_ns(g0 + 6000));
    CHECK("the submission's end leaves out both gaps", rep_ticks(&end4, &clock, 4, c0, c1, 0) == nvn_timestamp_from_ns(g0 + 8000));
    CHECK("the span of the submission is its GPU work", rep_ticks(&end4, &clock, 4, c0, c1, 0) - rep_ticks(&top0, &clock, 4, c0, c1, 0) == nvn_timestamp_from_ns(g0 + 8000) - nvn_timestamp_from_ns(g0 + 5));
    atomic_store(&clock.t[2][0], 0); atomic_store(&clock.t[2][1], 0);   // command buffer 1's feedback has not arrived
    CHECK("a command buffer with no feedback gives no gap", seg_idle_before(&clock, g0 + 9000, c0) == 0);
    heap.slots = NULL; heap.nslots = 0;
}

// The GPU time stretch end to end (the Mario Kart World family's heat and rescue lever: hle_nvn.c scale_set hands k to mtl_gpu_stretch_set, post_run applies it to the reports
// it writes). One submission of report ops through post_run as its completion runs it (no segment clocks: a TIMESTAMP_TOP reads c0, the others c1), each report's record
// read back
static void stretch_sub(uint64_t fence, const uint32_t *types, int n, uint64_t c0, uint64_t c1, uint64_t (*out)[2]) {
    post_rec *r = calloc(1, sizeof *r); post_op *ops = calloc((size_t)n, sizeof *ops);
    for (int i = 0; i < n; i++) { ops[i].kind = 0; ops[i].type = types[i]; ops[i].addr = (uint64_t)(uintptr_t)out[i]; out[i][0] = out[i][1] = 0; }
    atomic_store(&r->fence, fence); r->n = n; r->ops = ops;
    pthread_mutex_lock(&g_post_mu); post_run(r, c0, c1);   // post_run frees the ops and unlocks
    free(r);
}
static void check_stretch(void) {
    g_line_fence = 0; g_line_end = 0; g_stretch_floor = 0;
    uint64_t o[4][2]; const uint32_t pair[2] = {0x10, 0}, seg[4] = {0x10, 0, 0x10, 0};
    const uint64_t T4 = nvn_timestamp_from_ns(4000), T6 = nvn_timestamp_from_ns(6000);
    mtl_gpu_stretch_set(0); stretch_sub(100, pair, 2, 4000, 6000, o);
    CHECK("no stretch (a game without heat_gpu_stretch): the reports read what rep_ticks gives", o[0][1] == T4 && o[1][1] == T6 && mtl_gpu_stretch_now() == 0 && g_stretch_floor == 0);
    mtl_gpu_stretch_set(1.5); stretch_sub(101, pair, 2, 8000, 10000, o);
    const uint64_t T8 = nvn_timestamp_from_ns(8000), T10 = nvn_timestamp_from_ns(10000), want = T10 - (uint64_t)((double)(T10 - T8) * 1.5);
    CHECK("x1.5: the start reads 1.5 times its distance back from the end, the end where it was, nothing later than it was",
          mtl_gpu_stretch_now() == 1.5 && o[0][1] == want && o[0][1] < T8 && o[1][1] == T10 && g_stretch_floor == T10);
    // TOP, BOTTOM, TOP, BOTTOM in one submission read S, E, S, E: both pairs stretched (the floor is read once per submission, not report by report in op order)
    stretch_sub(102, seg, 4, 12000, 14000, o);
    const uint64_t T12 = nvn_timestamp_from_ns(12000), T14 = nvn_timestamp_from_ns(14000), w2 = T14 - (uint64_t)((double)(T14 - T12) * 1.5);
    CHECK("TOP, BOTTOM, TOP, BOTTOM: both pairs read 1.5 times their span (the second TOP not lifted to the first BOTTOM)",
          o[0][1] == w2 && o[2][1] == w2 && o[1][1] == T14 && o[3][1] == T14);
    // a submission whose own start is before the latest time written (a record completed early with c1 = now): its start reads its own time, never the later floor
    stretch_sub(103, pair, 2, 13000, 16000, o);
    CHECK("after a submission written later than this one's start: the start reads its own time, the end its own", o[0][1] == nvn_timestamp_from_ns(13000) && o[1][1] == nvn_timestamp_from_ns(16000));
    stretch_sub(104, pair, 2, 1000, 2000, o);
    CHECK("the floor is never lowered", g_stretch_floor == nvn_timestamp_from_ns(16000) && o[0][1] == nvn_timestamp_from_ns(1000));
    mtl_gpu_stretch_set(1); stretch_sub(105, pair, 2, 20000, 22000, o);
    CHECK("x1 (the family, no rung now): untouched, the floor following", o[0][1] == nvn_timestamp_from_ns(20000) && o[1][1] == nvn_timestamp_from_ns(22000) && g_stretch_floor == nvn_timestamp_from_ns(22000));
    // The stretch is unit-independent: in either raw unit (614.4 MHz ticks on NVN, nanoseconds on NVN2: nvn_timestamp.h) a 2,000 ns submission at x1.5 reads 3,000 ns
    // through the API's conversion, the end where it was. The Mario Kart World family is NVN2, so its reports are nanoseconds
    for (int ns_mode = 0; ns_mode < 2; ns_mode++) {
        nvn_timestamp_ns = ns_mode; g_stretch_floor = 0; g_line_fence = 0; g_line_end = 0;
        mtl_gpu_stretch_set(1.5); stretch_sub(200 + (uint64_t)ns_mode, pair, 2, 30000, 32000, o);
        const uint64_t s = nvn_timestamp_to_ns(o[0][1]), e = nvn_timestamp_to_ns(o[1][1]);
        CHECK(ns_mode ? "NVN2 (ns reports): x1.5 reads a 2,000 ns span as 3,000 ns, the end where it was" : "NVN (614.4 MHz reports): x1.5 reads a 2,000 ns span as 3,000 ns, the end where it was",
              o[1][1] == nvn_timestamp_from_ns(32000) && e - s >= 2998 && e - s <= 3002);
        if (ns_mode) CHECK("NVN2: the reports are the guest clock's nanoseconds", o[1][1] == 32000 && o[0][1] == 29000);
    }
    // The GPU time scale (profile gpu_time_scale: Donkey Kong Bananza's 0.6144, NVN2): k below 1 through the same wire, the spans shortened toward the end, which stays; with
    // 85%'s stretch on top (k = 0.6144 x 1 / 0.85²) the span reads 0.85 of its length; the next submission's reports never read before the last end, nor past their own end
    nvn_timestamp_ns = 1; g_stretch_floor = 0; g_line_fence = 0; g_line_end = 0;
    mtl_gpu_stretch_set(0.6144); stretch_sub(300, seg, 4, 40000, 50000, o);
    CHECK("NVN2 time scale x0.6144: TOP, BOTTOM, TOP, BOTTOM read a 10,000 ns span as 6,143-6,144 ns, the end where it was, the floor at the end",
          mtl_gpu_stretch_now() == 0.6144 && o[1][1] == 50000 && o[3][1] == 50000 && o[0][1] == o[2][1] && o[0][1] >= 43856 && o[0][1] <= 43857 && g_stretch_floor == 50000);
    const double k85 = 0.6144 / (0.85 * 0.85);
    mtl_gpu_stretch_set(k85); stretch_sub(301, pair, 2, 52000, 62000, o);
    CHECK("  with 85%'s stretch on top: a 10,000 ns span reads 8,503-8,504 ns, after the submission before it",
          o[1][1] == 62000 && 62000 - o[0][1] >= 8503 && 62000 - o[0][1] <= 8504 && o[0][1] >= 50000);
    mtl_gpu_stretch_set(1); stretch_sub(302, pair, 2, 64000, 66000, o);
    CHECK("  DM_GPU_TIME_SCALE=1 (k 1): the reports' true times", o[0][1] == 64000 && o[1][1] == 66000);
    nvn_timestamp_ns = 0;
    mtl_gpu_stretch_set(0); g_stretch_floor = 0; g_line_fence = 0; g_line_end = 0;
}

int main(void) {
    @autoreleasepool {
        ClockDevice *device = [ClockDevice new];
        ClockHeap *heap = [ClockHeap new];
        g_dev = (id<MTLDevice>)device;
        g_ts_heap = (id<MTL4CounterHeap>)heap;
        const uint64_t age = 8000000, delay = 20000000, offset = 100000000;
        // The sampled CPU time predates the report by at least 20 ms. A late guest-clock
        // read would add that scheduling delay to the value sent to the game.
        device.cpu = now_ns() - delay;
        device.gpu = device.cpu + offset;
        heap.boundary = device.gpu - age;
        seg_clk clock = {.nb = 1, .b = {0}};
        post_op report = {.type = 0x10, .seg = 0};
        uint64_t expected = nvn_timestamp_from_ns(device.cpu - age);
        CHECK("a late read preserves the GPU boundary's sampled guest time", rep_ticks(&report, &clock, 0, 0, 0, 0) == expected);
        device.cpu += 1000;
        device.gpu += 1000;
        CHECK("a later clock pair maps the same boundary to the same report", rep_ticks(&report, &clock, 0, 0, 0, 0) == expected);
        device.cpu = 0;
        CHECK("a missing CPU sample takes the existing feedback fallback", rep_ticks(&report, &clock, 0, 10000, 0, 0) == nvn_timestamp_from_ns(10000));
        device.cpu = now_ns() - delay; device.gpu = device.cpu + offset;
        check_idle_gaps(device, heap);
        check_timeline();
        check_stretch();

        guest_clock_freeze(1);
        uint64_t frozen = guest_ns();
        CHECK("projection keeps the frozen guest time", guest_ns_at_host_time(1) == frozen);
        usleep(1000);
        guest_clock_freeze(0);
        uint64_t host = now_ns(), guest = guest_ns_at_host_time(host);
        CHECK("projection subtracts the time spent frozen", guest < host && guest >= frozen);
        CHECK("a host sample older than the pause offset cannot underflow", guest_ns_at_host_time(1) == 0);
        CHECK("feedback conversion uses the resumed guest epoch", llabs((int64_t)gpu_s_guest_ns(host / 1e9) - (int64_t)guest) <= 2);
        { int bad = 0; for (int i = 0; i < 20000; i++) { uint64_t h = now_ns(); if (!gpu_s_guest_ns(h / 1e9)) bad++; } CHECK("a feedback time in the clock tick of the read is not in the future", bad == 0); }
        CHECK("a feedback time one double step ahead of the read is the read's time", llabs((int64_t)gpu_s_guest_ns(nextafter(host / 1e9, INFINITY)) - (int64_t)guest) <= 2);
        CHECK("future feedback is rejected", gpu_s_guest_ns(host / 1e9 + 1) == 0);
        CHECK("invalid feedback is rejected", gpu_s_guest_ns(NAN) == 0 && gpu_s_guest_ns(INFINITY) == 0);

        setenv("DM_DETCLOCK", "1000000", 1);
        // A synthetic window with no textures exercises the present's clock accounting without submitting a GPU job: one step per present at present interval 1 and 2
        NVNwindow window = {0};
        h_nvnWindowSetPresentInterval(&window, 1);
        h_nvnQueuePresentTexture(NULL, &window, 0);
        uint64_t deterministic = guest_ns();
        uint64_t frame = dm_guest_frame();
        CHECK("deterministic projection uses the current guest frame", guest_ns_at_host_time(host) == deterministic);
        h_nvnQueuePresentTexture(NULL, &window, 0);
        CHECK("an interval-1 present advances one frame and one step", dm_guest_frame() == frame + 1 && guest_ns_at_host_time(host) == deterministic + 1000000);
        h_nvnWindowSetPresentInterval(&window, 2);
        h_nvnQueuePresentTexture(NULL, &window, 0);
        CHECK("an interval-2 present advances one frame and one step", dm_guest_frame() == frame + 2 && guest_ns_at_host_time(host) == deterministic + 2000000);
    }
    printf("counter clock: %u checks, %u failed\n", checks, failures);
    return failures != 0;
}
