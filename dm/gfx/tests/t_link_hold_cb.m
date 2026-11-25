// The display-link callback's hold (NvMetalDisplayLinkDelegate, g_link_hold_until) with two frames queued: the frame taken first stays on screen for the whole link ticks of its
// period before the callback takes the next, and a frame of one tick or less holds nothing. The test calls the callback by hand (real Metal 4 queue, offscreen drawables, a
// display-link object that never fires), as t_present_repeat.m does. Ported with upstream NXNative's hold cases (64a1b8f6d, PR #1045, in its t_link_latch_cb.m; NX 18 has
// no late latch): 60 fps on the 120 Hz link (it took the queued frame on the next 8.33 ms tick under the old 25 ms cutoff), the same on a 144 Hz screen counting virtual
// 120 Hz ticks, 120 and 75 fps on the 120 Hz link, 30 fps on the 60 Hz link and on the 30 Hz link
#include "../nvn/nvn_mtl.m"
@interface FakeLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@property CFTimeInterval targetTimestamp;
@end
@implementation FakeLinkUpdate
@end
static CAMetalLayer *g_test_layer;
void *front_metal_layer(void) { return (__bridge void *)g_test_layer; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static tex_t g_tex;
static CAMetalLayer *offscreen_layer(void) {
    CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.framebufferOnly = NO; l.drawableSize = CGSizeMake(8, 8); return l;
}
static NSMutableArray *g_layers;
static NvMetalDisplayLinkDelegate *g_delegate;
static void settle(void) {   // the present the callback handed to the encoder has run
    pthread_mutex_lock(&g_pq_mu); struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 5;
    while (g_pq_inflight && pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT) {}
    pthread_mutex_unlock(&g_pq_mu);
}
static void tick_at(double target) {   // one display-link callback for the refresh at `target`
    static unsigned n; if (g_layers.count < 8) { CAMetalLayer *nl = offscreen_layer(); [g_q4 addResidencySet:nl.residencySet]; [g_layers addObject:nl]; }   // the queue takes at most 32 residency sets
    CAMetalLayer *l = g_layers[n++ % g_layers.count];
    FakeLinkUpdate *u = [FakeLinkUpdate new]; double t0 = CACurrentMediaTime();
    u.drawable = [l nextDrawable]; u.targetTimestamp = t0 + 0.0165; u.targetPresentationTimestamp = target;
    @autoreleasepool { [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u]; }
    settle();
}
static uint64_t queued(void) { pthread_mutex_lock(&g_pq_mu); uint64_t n = g_pq_in - g_pq_read; pthread_mutex_unlock(&g_pq_mu); return n; }
// Two frames of the given rate queued; the first callback takes the first, the next `callbacks` - 1 keep it (the second still queued), and the one after takes the second
static void hold_case(int mode, int screen_hz, int fps, int callbacks, const char *name) {
    g_link_mode = mode;
    g_link_hold_until = 0;
    double step = 1. / screen_hz, target = CACurrentMediaTime() + 0.050;
    const int rate = mtl_link_rate();
    g_link_vperiod = screen_hz == rate ? 0 : 1. / rate;
    g_link_vhalf = g_link_vperiod > 0 ? step / 2 : 0;
    if (g_link_vperiod > 0) {
        // On a 144 Hz screen, the virtual 120 Hz slot at 16.67 ms comes at 13.89 ms and the next at 27.78 ms.
        tick_at(target);
        tick_at(target + step);
        target += 2 * step;
    }
    double period = (1000000000ull / (uint64_t)fps) / 1e9;   // the same whole-nanosecond period as the guest presents
    uint64_t dropped0 = g_link_dropped;
    uint64_t first = present_enqueue(&g_tex, period, NULL, NULL);
    uint64_t second = present_enqueue(&g_tex, period, NULL, NULL);
    tick_at(target);
    int waited = first && second == first + 1 && g_pq_read == first && queued() == 1;
    for (int i = 1; i < callbacks; i++) {
        tick_at(target + i * step);
        waited &= g_pq_read == first && queued() == 1;
    }
    tick_at(target + callbacks * step);
    CHECK(name, waited && g_pq_read == second && queued() == 0 && g_link_dropped == dropped0);
}
int main(void) { @autoreleasepool {
    alarm(120); if (setvbuf(stdout, NULL, _IONBF, 0)) return 2;
    setenv("DM_PRESENT_HZ", "0", 1); setenv("DM_RT", "0", 1);
    // Plain frames in order: no snapshots, repeat or frame generation (a profile may turn them on: Breath of the Wild's present_snap, Bananza's present_repeat), no trim
    setenv("DM_PRESENT_SNAP", "0", 1); setenv("DM_PRESENT_REPEAT", "0", 1); unsetenv("DM_FRAMEGEN"); setenv("DM_PRESENT_TRIM", "0", 1); setenv("DM_PRESENT_FIFO", "1", 1);
    setenv("DM_PRESENT_SHARPEN", "0", 1); setenv("DM_PRESENT_UPSCALE", "off", 1); setenv("DM_POST_AA", "off", 1); setenv("DM_PSO_PREPARE", "0", 1);
    mtl_init();
    g_test_layer = offscreen_layer(); g_layers = [NSMutableArray new];
    mtl_present_layer(8, 8);
    {   // the source texture every present shows
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d];
        g_tex = (tex_t){.magic=MAGIC('T','E','X',0), .serial=92001}; g_tex.d.width = g_tex.d.height = 8; g_tex.d.depth = g_tex.d.levels = g_tex.d.samples = 1;
        g_tex.d.target = NVN_TEXTURE_TARGET_2D; g_tex.d.format = NVN_FORMAT_RGBA8; serial_put(g_tex.serial, mt); res_add(mt); res_commit();
    }
    // A display link that never fires (the test calls the callback): present_enqueue leaves the queue to the callback
    g_link = [[CAMetalDisplayLink alloc] initWithMetalLayer:g_test_layer];
    g_dm_present_link = 1; g_link_started = 1; g_link_owns_layer = 1; g_link_mode = 1; g_delegate = [NvMetalDisplayLinkDelegate new];
    CHECK("present repeat and snapshots off", !rep_on() && !mtl_snap_on());
    // One frame through first: in this fixture the process's first present comes back not submitted, which sets no hold (upstream ran its latch cases before these)
    present_enqueue(&g_tex, 1. / 60, NULL, NULL); tick_at(CACurrentMediaTime() + 0.050);
    CHECK("the first frame is taken", queued() == 0);

    hold_case(2, 120, 60, 2, "60 fps on a 120 Hz link takes the queued frame on the second tick");
    hold_case(2, 144, 60, 3, "60 fps on a virtual 120 Hz link holds through an uneven first tick");
    hold_case(2, 120, 120, 1, "120 fps on a 120 Hz link can take a frame on the next tick");
    hold_case(2, 120, 75, 1, "75 fps on a 120 Hz link can take a frame on the next tick");
    hold_case(1, 60, 30, 2, "30 fps on a 60 Hz link takes the queued frame on the second tick");
    hold_case(3, 30, 30, 1, "30 fps on a 30 Hz link can take a frame on the next tick");
    printf("t_link_hold_cb: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
