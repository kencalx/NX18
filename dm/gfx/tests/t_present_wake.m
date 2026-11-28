// The nvn-present thread while the display link owns the layer (DM_PRESENT_WAKE, nvn_mtl.m present_main): it has no work there, and with the switch on it sleeps on a condition
// variable of its own, so the present queue's broadcasts (each enqueue, each tick, each present's commit feedback) no longer wake it. Real Metal 4 queue and offscreen drawables; the
// link's callback is called by hand (no window, no game files).
//   1. 300 display-link presents: the thread's wakes counted (on: at most its 1 s timer's; DM_PRESENT_WAKE=0: three or so a present, the negative control).
//   2. Hand-back stress: 2,000 times the layer is taken (as link_main does), a frame queued behind it, and the layer given back (link_layer_back_locked) while a second thread
//      broadcasts the queue's condition variable non-stop; each frame must be taken by the present thread within 300 ms, well under the 1 s timer, so a lost wakeup fails.
//   3. A hand-back that does not signal (the old code's broadcast alone): on, the frame waits for the 1 s timer and the late count says so; off, it is taken at once.
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
@interface FakeLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@property CFTimeInterval targetTimestamp;
@end
@implementation FakeLinkUpdate
@end
static CAMetalLayer *_Atomic g_test_layer;
void *front_metal_layer(void) { return (__bridge void *)atomic_load(&g_test_layer); }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
static tex_t source(unsigned serial) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; uint8_t bytes[256]; memset(bytes, 120, sizeof bytes);
    [mt replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:bytes bytesPerRow:32];
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=serial};
    t.d.width = t.d.height = 8; t.d.depth = t.d.levels = t.d.samples = 1;
    t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    serial_put(t.serial, mt); res_add(mt); res_commit(); return t;
}
static CAMetalLayer *offscreen_layer(void) {
    CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.framebufferOnly = NO; l.drawableSize = CGSizeMake(8, 8); return l;
}
static id<CAMetalDrawable> next_drawable(void) {   // three layers in turn (a queue takes at most 32 residency sets); each present completes before the next
    static CAMetalLayer *ls[3]; static int k;
    CAMetalLayer *l = ls[k % 3]; if (!l) { l = ls[k % 3] = offscreen_layer(); [g_q4 addResidencySet:l.residencySet]; }
    k++; return [l nextDrawable];
}
static NvMetalDisplayLinkDelegate *g_delegate;
static void tick(void) {
    FakeLinkUpdate *u = [FakeLinkUpdate new]; u.drawable = next_drawable(); u.targetPresentationTimestamp = CACurrentMediaTime() + 0.016;
    [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u];
}
static int wait_locked(int (^done)(void), double s) {   // under g_pq_mu: until done() or s seconds
    struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); long ns = ts.tv_nsec + (long)((s - floor(s)) * 1e9); ts.tv_sec += (time_t)s + ns / 1000000000L; ts.tv_nsec = ns % 1000000000L;
    while (!done()) if (pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) == ETIMEDOUT) return done();
    return 1;
}
static void take_layer(void) {   // as link_main: the layer is the link's once the present thread holds no frame
    pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 1; while (g_pq_holding) pthread_cond_wait(&g_pq_cv, &g_pq_mu); pthread_mutex_unlock(&g_pq_mu);
}
static _Atomic int g_noise_stop; static _Atomic uint64_t g_noise_n;
static void *noise(void *arg) {   // the link's ticks and the commit feedback: broadcasts of the queue's condition variable with nothing for the present thread
    (void)arg; while (!atomic_load(&g_noise_stop)) { pthread_mutex_lock(&g_pq_mu); pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu); atomic_fetch_add(&g_noise_n, 1); sched_yield(); }
    return NULL;
}
int main(void) { @autoreleasepool {
    alarm(120); setbuf(stdout, NULL);
    setenv("DM_PRESENT_HZ", "0", 1); setenv("DM_PRESENT_SNAP", "0", 1); setenv("DM_PRESENT_REPEAT", "0", 1);
    mtl_init();
    atomic_store(&g_test_layer, offscreen_layer());
    mtl_present_layer(8, 8);
    g_dm_present_link = 1; g_link_started = 1; g_link_owns_layer = 1; g_delegate = [NvMetalDisplayLinkDelegate new];
    int on = present_wake_on(); printf("DM_PRESENT_WAKE %s\n", on ? "on (default)" : "=0");
    tex_t a = source(92001);

    // 1. 300 presents through the display link's callback, each completed before the next
    present_enqueue(&a, 1. / 60, NULL, NULL); tick();   // starts the present thread, which goes to sleep: the link owns the layer
    pthread_mutex_lock(&g_pq_mu); wait_locked(^{ return (int)(g_pq_inflight == 0); }, 5); pthread_mutex_unlock(&g_pq_mu);
    usleep(20000);
    uint64_t w0 = atomic_load(&g_pmain_wakes), t0 = now_ns(), r0 = g_pq_read;
    for (int i = 0; i < 300; i++) @autoreleasepool {
        present_enqueue(&a, 1. / 60, NULL, NULL); tick();
        pthread_mutex_lock(&g_pq_mu); wait_locked(^{ return (int)(g_pq_inflight == 0); }, 5); pthread_mutex_unlock(&g_pq_mu);
    }
    uint64_t wakes = atomic_load(&g_pmain_wakes) - w0; double secs = (now_ns() - t0) / 1e9;
    printf("300 display-link presents in %.2f s: the present thread woke %llu times (%.2f a present)\n", secs, (unsigned long long)wakes, wakes / 300.0);
    CHECK("all 300 presents taken by the link's callback", g_pq_read == r0 + 300 && g_present_n >= 300);
    if (on) CHECK("on: the present thread sleeps through the link's presents (its 1 s timer at most)", wakes <= (uint64_t)secs + 2);
    else CHECK("DM_PRESENT_WAKE=0: the present thread wakes on the queue's broadcasts (2 or more a present)", wakes >= 600);

    // 2. Hand-back stress, with a thread broadcasting all the while
    atomic_store(&g_test_layer, nil);   // the present thread's own presents return at once (no layer): the ticket is processed, nothing reaches the GPU
    pthread_t nt; pthread_create(&nt, NULL, noise, NULL);
    int slow = 0, early = 0; double worst = 0; uint64_t late0 = atomic_load(&g_pmain_late);
    for (int i = 0; i < 2000; i++) @autoreleasepool {
        take_layer();
        uint64_t tk = present_enqueue(&a, 1. / 60, NULL, NULL);
        // Every other hand-back after a pause, so the present thread is surely asleep on its own condition variable (the enqueue's broadcast may find it still on the queue's)
        if (i % 100 == 0) { usleep(2000); pthread_mutex_lock(&g_pq_mu); early += g_pq_read >= tk; pthread_mutex_unlock(&g_pq_mu); }   // still the link's: not taken
        else if (i % 2) usleep(200);
        uint64_t h0 = now_ns();
        pthread_mutex_lock(&g_pq_mu); link_layer_back_locked();
        int ok = wait_locked(^{ return (int)(g_pq_done >= tk); }, 0.3);
        pthread_mutex_unlock(&g_pq_mu);
        double ms = (now_ns() - h0) / 1e6; if (ms > worst) worst = ms;
        slow += !ok;
    }
    atomic_store(&g_noise_stop, 1); pthread_join(nt, NULL);
    printf("hand-back stress: 2000 hand-backs, %llu broadcasts from the noise thread, slowest take %.3f ms, %d over 300 ms, %d taken while the link owned the layer\n",
           (unsigned long long)atomic_load(&g_noise_n), worst, slow, early);
    CHECK("stress: every frame queued behind the link is taken within 300 ms of the hand-back", slow == 0);
    CHECK("stress: none is taken while the link owns the layer", early == 0);
    CHECK("stress: no hand-back needed the 1 s timer", atomic_load(&g_pmain_late) == late0);

    // 3. A hand-back without the signal, as before the change (a broadcast of g_pq_cv only)
    take_layer();
    uint64_t tk = present_enqueue(&a, 1. / 60, NULL, NULL); usleep(20000);   // the present thread asleep again, on its own condition variable when on
    uint64_t h0 = now_ns();
    pthread_mutex_lock(&g_pq_mu); g_link_owns_layer = 0; pthread_cond_broadcast(&g_pq_cv);
    int ok = wait_locked(^{ return (int)(g_pq_done >= tk); }, 3);
    pthread_mutex_unlock(&g_pq_mu);
    double ms = (now_ns() - h0) / 1e6; printf("a hand-back without the signal: taken after %.1f ms\n", ms);
    if (on) CHECK("on: an unsignalled hand-back is taken by the 1 s timer and counted late", ok && ms >= 500 && ms < 2500 && atomic_load(&g_pmain_late) == late0 + 1);
    else CHECK("DM_PRESENT_WAKE=0: an unsignalled hand-back is taken at once", ok && ms < 300);
    printf("present wake: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
