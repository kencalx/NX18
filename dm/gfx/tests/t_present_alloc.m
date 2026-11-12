// Display-link presents with the GPU held back: a present must not reset a command allocator whose own present has not run yet. Real Metal 4 queue and offscreen
// drawables; the link's callback is called by hand (no window, no game files). Two cases: a dropped frame (two presents in flight) and one frame per tick (three in flight).
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
@interface FakeLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
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
static tex_t source(unsigned serial, uint8_t left, uint8_t right) {   // 8x8 grey, the left four columns one value and the right four another
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:8 height:8 mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; uint8_t bytes[256];
    for (int i = 0; i < 64; i++) { uint8_t v = i % 8 < 4 ? left : right; bytes[4 * i] = bytes[4 * i + 1] = bytes[4 * i + 2] = v; bytes[4 * i + 3] = 255; }
    [mt replaceRegion:MTLRegionMake2D(0, 0, 8, 8) mipmapLevel:0 withBytes:bytes bytesPerRow:32];
    tex_t t = {.magic=MAGIC('T','E','X',0), .serial=serial};
    t.d.width = t.d.height = 8; t.d.depth = t.d.levels = t.d.samples = 1;
    t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    serial_put(t.serial, mt); res_add(mt); res_commit(); return t;
}
static CAMetalLayer *offscreen_layer(void) {
    CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.framebufferOnly = NO; l.drawableSize = CGSizeMake(8, 8); return l;
}
// Every present gets a drawable of its own layer. With all drawables from one offscreen layer, 1 of 100 runs under CPU load got ticket 1's IOSurface back from
// nextDrawable while the gate still held ticket 1's present, and ticket 4 then drew over the picture this test reads back
static NSMutableArray *g_layers;
static id<CAMetalDrawable> drawable(void) {
    CAMetalLayer *l = offscreen_layer(); [g_q4 addResidencySet:l.residencySet]; [g_layers addObject:l]; return [l nextDrawable];
}
static NvMetalDisplayLinkDelegate *g_delegate;
static id<CAMetalDrawable> tick_with(id<CAMetalDrawable> dr) {   // one display-link callback (it does not look at the link)
    FakeLinkUpdate *u = [FakeLinkUpdate new]; u.drawable = dr; u.targetPresentationTimestamp = CACurrentMediaTime() + 0.016;
    [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u];
    return dr;
}
static id<CAMetalDrawable> tick(void) { return tick_with(drawable()); }
// The tick that lands on a used allocator runs on its own thread, so the test sees whether it waits; its drawable is taken before the thread starts
static id<CAMetalDrawable> g_held; static dispatch_semaphore_t g_held_done;
static void *held_tick(void *arg) { (void)arg; @autoreleasepool { tick_with(g_held); } dispatch_semaphore_signal(g_held_done); return NULL; }
static void reuse_case(id<CAMetalDrawable> dr, id<MTLSharedEvent> gate, uint64_t open, uint64_t ticket, int inflight, uint64_t old) {
    char name[160];
    g_held = dr; g_held_done = dispatch_semaphore_create(0); pthread_t th; pthread_create(&th, NULL, held_tick, NULL);
    int returned = dispatch_semaphore_wait(g_held_done, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC)) == 0;
    pthread_mutex_lock(&g_pq_mu); int inside = g_pq_read == ticket && g_pq_inflight == inflight; pthread_mutex_unlock(&g_pq_mu);
    snprintf(name, sizeof name, "ticket %llu reached present_now", (unsigned long long)ticket); CHECK(name, returned || inside);
    snprintf(name, sizeof name, "allocator %llu is not reused while ticket %llu is on the GPU", (unsigned long long)(ticket % 3), (unsigned long long)old); CHECK(name, !returned);
    gate.signaledValue = open;
    if (!returned) returned = dispatch_semaphore_wait(g_held_done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0;
    snprintf(name, sizeof name, "ticket %llu is presented once the GPU gets to ticket %llu", (unsigned long long)ticket, (unsigned long long)old); CHECK(name, returned);
    pthread_join(th, NULL);
    pthread_mutex_lock(&g_pq_mu); struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 5;
    while (g_pq_inflight && pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT) {}
    int left = g_pq_inflight; uint64_t done = g_pq_done; pthread_mutex_unlock(&g_pq_mu);
    CHECK("every present completed", left == 0 && done == ticket);
}
static int bad_pixels(id<MTLTexture> t, uint8_t left, uint8_t right) {
    id<MTLBuffer> out = [g_dev newBufferWithLength:256 options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> b = t4_copy(cb);
    t4_use(cb, t), t4_use(cb, out), [b copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(8, 8, 1)
        toBuffer:out destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:256];
    t4_end(cb, b); t4_wait(cb);
    const uint8_t *p = out.contents; int bad = 0;
    for (int i = 0; i < 64; i++) { uint8_t v = i % 8 < 4 ? left : right; bad += p[4 * i] != v || p[4 * i + 1] != v || p[4 * i + 2] != v; }
    if (bad) { printf("first row:"); for (int i = 0; i < 8; i++) printf(" %u", p[4 * i]); printf(" (want %u x4, %u x4)\n", left, right); }
    return bad;
}
// A 128x128 drawable for the effects case, from three layers in turn (a queue takes at most 32 residency sets, so not a layer per present; each present here completes before the next)
static id<CAMetalDrawable> big_drawable(void) {
    static CAMetalLayer *ls[3]; static int k;
    CAMetalLayer *l = ls[k % 3]; if (!l) { l = ls[k % 3] = offscreen_layer(); l.drawableSize = CGSizeMake(128, 128); [g_q4 addResidencySet:l.residencySet]; }
    k++; return [l nextDrawable];
}
// One present of t through the display link's callback, completed before it returns
static void present_done(const tex_t *t) { @autoreleasepool {
    present_enqueue(t, 1. / 60, NULL, NULL); tick_with(big_drawable());
    pthread_mutex_lock(&g_pq_mu); struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 5;
    while (g_pq_inflight && pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT) {}
    pthread_mutex_unlock(&g_pq_mu);
} }
static NSUInteger res_count(void) { NSUInteger n; @autoreleasepool { pthread_mutex_lock(&g_res_mu); n = g_res_objects.allObjects.count; pthread_mutex_unlock(&g_res_mu); } return n; }
static void fx_case(void) {
    char name[200]; int keep = present_fx_keep();
    tex_t big = {.magic = MAGIC('T','E','X',0), .serial = 91010};
    @autoreleasepool {
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:64 height:64 mipmapped:NO];
        d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> mt = [g_dev newTextureWithDescriptor:d]; static uint8_t bytes[64 * 64 * 4];
        for (int i = 0; i < 64 * 64; i++) { uint8_t v = (i % 64) < 32 ? 40 : 220; bytes[4 * i] = bytes[4 * i + 1] = bytes[4 * i + 2] = v; bytes[4 * i + 3] = 255; }   // a hard edge for CMAA2
        [mt replaceRegion:MTLRegionMake2D(0, 0, 64, 64) mipmapLevel:0 withBytes:bytes bytesPerRow:256];
        big.d.width = big.d.height = 64; big.d.depth = big.d.levels = big.d.samples = 1; big.d.target = NVN_TEXTURE_TARGET_2D; big.d.format = NVN_FORMAT_RGBA8;
        serial_put(big.serial, mt); res_add(mt); res_commit();
    }
    CHECK("effects: CMAA2's kernels are made", aa_pipelines(1));
    int mfx = [MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev];
    g_fx_idle_presents = 4;
    mtl_present_aa_set("edge"); mtl_present_upscale_set("metalfx");
    for (int i = 0; i < 3; i++) present_done(&big);
    CHECK("effects on: edge smoothing ran and holds its texture and lists", g_aa_ran && g_aa_present.tex && g_aa_present.work && g_aa_present.ctl);
    if (mfx) CHECK("effects on: MetalFX ran and holds its scaler and output", g_fx_ran && g_fx_present.sc && g_fx_present.out);
    else printf("effects: this GPU has no Metal 4 MetalFX scaler; edge smoothing alone\n");
    uint64_t z = g_aa_present.tex.allocatedSize + g_aa_present.work.allocatedSize + g_aa_present.ctl.allocatedSize + g_fx_present.in.allocatedSize + g_fx_present.out.allocatedSize;
    int nobj = !!g_aa_present.tex + !!g_aa_present.work + !!g_aa_present.ctl + !!g_fx_present.in + !!g_fx_present.out;
    __weak id w[5] = {g_aa_present.tex, g_aa_present.work, g_aa_present.ctl, g_fx_present.in, g_fx_present.out};   // GPU allocated cannot show them go: drawables come and go between these presents
    uint64_t freed0 = atomic_load(&g_present_fx_freed), gpu0 = g_dev.currentAllocatedSize; NSUInteger res0 = res_count();
    mtl_present_aa_set("off"); mtl_present_upscale_set("off");
    for (int i = 0; i < g_fx_idle_presents + 2; i++) present_done(&big);
    uint64_t gpu1 = g_dev.currentAllocatedSize; NSUInteger res1 = res_count();
    printf("effects off for %d presents (DM_PRESENT_FX_KEEP %s): %d objects, %llu KB before; residency set %lu -> %lu, GPU allocated %llu -> %llu KB, released %llu\n", g_fx_idle_presents + 2, keep ? "1" : "unset",
           nobj, (unsigned long long)(z >> 10), (unsigned long)res0, (unsigned long)res1, (unsigned long long)(gpu0 >> 10), (unsigned long long)(gpu1 >> 10), (unsigned long long)(atomic_load(&g_present_fx_freed) - freed0));
    if (!keep) {
        CHECK("effects off: CMAA2's texture and lists released", !g_aa_present.tex && !g_aa_present.raw && !g_aa_present.work && !g_aa_present.ctl);
        if (mfx) CHECK("effects off: the scaler and its textures released", !g_fx_present.sc && !g_fx_present.in && !g_fx_present.out);
        snprintf(name, sizeof name, "effects off: the residency set lost their %d objects", nobj); CHECK(name, res1 + nobj <= res0);
        int alive = 0; @autoreleasepool { for (int k = 0; k < 5; k++) { id o = w[k]; alive += o != nil; } }
        CHECK("effects off: their textures and buffers are freed", alive == 0);
        CHECK("effects off: counted for the memory line", atomic_load(&g_present_fx_freed) == freed0 + 1 + mfx);
    } else {
        CHECK("DM_PRESENT_FX_KEEP=1: the effects' state is kept", g_aa_present.tex && (!mfx || g_fx_present.out) && res1 == res0 && atomic_load(&g_present_fx_freed) == freed0);
    }
    // On again: made again (the scaler after FX_REMAKE_PRESENTS presents since the last one made)
    mtl_present_aa_set("edge"); mtl_present_upscale_set("metalfx");
    for (int i = 0; i < FX_REMAKE_PRESENTS + 4; i++) present_done(&big);
    CHECK("effects on again: edge smoothing runs with its state made again", g_aa_ran && g_aa_present.tex && g_aa_present.work);
    if (mfx) CHECK("effects on again: MetalFX runs with a scaler made again", g_fx_ran && g_fx_present.sc && g_fx_present.out && g_fx_idle == 0);
    mtl_present_aa_set("off"); mtl_present_upscale_set("off"); g_fx_idle_presents = FX_IDLE_PRESENTS;
}
int main(void) { @autoreleasepool {
    alarm(30); setbuf(stdout, NULL);
    setenv("DM_PRESENT_HZ", "0", 1);
    mtl_init();
    g_test_layer = offscreen_layer(); g_layers = [NSMutableArray new];
    mtl_present_layer(8, 8);   // a layer of the drawables' shape, so the picture fills them: left to the default, the display's 16:9, it has bars in a square drawable (present_shape)
    // Display-link mode without a link thread: link_sync sees a started link that is not there yet, the present thread leaves the queue to the callback
    g_dm_present_link = 1; g_link_started = 1; g_link_owns_layer = 1; g_delegate = [NvMetalDisplayLinkDelegate new];
    tex_t a = source(91001, 50, 150), b = source(91002, 100, 100), c = source(91003, 200, 200);
    static const int left_half[4] = {0, 0, 4, 8};
    id<MTLSharedEvent> gate = [g_dev newSharedEvent];
    // Every callback moves g_pq_done to ticket - 1, so it is no guard for the allocator: the presents below wait only if the allocator's own completion is checked.
    // On main both cases fail the reuse check, and the earlier ticket's drawable reads back black (0 in every pixel): its command buffer was encoded again before the GPU ran it

    // A dropped frame: ticket 1 on allocator 1, then 3 (2 dropped) on allocator 0, then 4 on allocator 1 again with two presents in flight
    [g_q4 waitForEvent:gate value:1];   // nothing committed to the Metal 4 queue from here runs until the gate opens
    present_enqueue(&a, 1. / 60, NULL, NULL);
    id<CAMetalDrawable> first = tick();
    present_enqueue(&b, 1. / 60, NULL, NULL); present_enqueue(&b, 1. / 60, NULL, NULL); present_enqueue(&c, 1. / 60, left_half, NULL);
    tick();
    printf("after the drop: read %llu, done %llu, in flight %d\n", (unsigned long long)g_pq_read, (unsigned long long)g_pq_done, g_pq_inflight);
    CHECK("ticket 1 has not completed", g_pq_inflight == 2);
    reuse_case(drawable(), gate, 1, 4, 2, 1);
    int bad = bad_pixels(first.texture, 50, 150); printf("ticket 1 drawable: %d of 64 pixels wrong\n", bad);
    CHECK("ticket 1 shows its own picture", bad == 0);

    // One frame per tick, nothing dropped: tickets 5, 6 and 7 on allocators 2, 0 and 1, then 8 on allocator 2 again with three presents in flight
    [g_q4 waitForEvent:gate value:2];
    present_enqueue(&a, 1. / 60, NULL, NULL); id<CAMetalDrawable> fifth = tick();
    present_enqueue(&b, 1. / 60, NULL, NULL); tick();
    present_enqueue(&b, 1. / 60, NULL, NULL); tick();
    present_enqueue(&c, 1. / 60, left_half, NULL);
    printf("one per tick: read %llu, done %llu, in flight %d, dropped %llu\n", (unsigned long long)g_pq_read, (unsigned long long)g_pq_done, g_pq_inflight, (unsigned long long)g_link_dropped);
    CHECK("tickets 5-7 have not completed", g_pq_inflight == 3 && g_link_dropped == 1);
    reuse_case(drawable(), gate, 2, 8, 3, 5);
    CHECK("no frame dropped after ticket 2", g_link_dropped == 1);
    bad = bad_pixels(fifth.texture, 50, 150); printf("ticket 5 drawable: %d of 64 pixels wrong\n", bad);
    CHECK("ticket 5 shows its own picture", bad == 0);

    // A standing frame trimmed (DM_PRESENT_TRIM=3): two frames waiting at every tick, as when two landed in one refresh and none came without one. FIFO takes the older at the
    // first two ticks, and the third takes the newest, dropping one; then a single frame resets the run. The GPU gate is open from here on
    // K comes from DM_PRESENT_TRIM when it is set, whatever the profile says (env.txt's 0 turns a profile's trim off), else from the profile's present_trim, an explicit 0 included (60 for
    // Ocarina of Time), else from the platform: 60 on iOS (a second of ticks on a faster link), off on the Mac. Run with GAME=0400486024DEC000 as well as the generic suites' game to see both profiles
    { int src = -1, ios, k;
      CHECK("trim: K read at the first tick is this host's (the Mac's)", g_link_trim == present_trim_k(getenv("DM_PRESENT_TRIM"), DM_GAME_PRESENT_TRIM, PRESENT_TRIM_PLATFORM, NULL) && !PRESENT_TRIM_PLATFORM);
      CHECK("trim: the profile's present_trim without DM_PRESENT_TRIM", present_trim_k(NULL, DM_GAME_PRESENT_TRIM, 0, NULL) == (DM_GAME_PRESENT_TRIM > 0 ? DM_GAME_PRESENT_TRIM : 0));
      for (ios = 0; ios < 2; ios++) {
          CHECK("trim: DM_PRESENT_TRIM wins over the profile and the platform", present_trim_k("0", 60, ios, &src) == 0 && src == TRIM_OFF && present_trim_k("0", -1, ios, NULL) == 0 && present_trim_k("45", 60, ios, &src) == 45 && src == TRIM_ENV
                && present_trim_k("45", -1, ios, NULL) == 45 && present_trim_k("-3", -1, ios, NULL) == 0 && present_trim_k("off", -1, ios, NULL) == 0);
          CHECK("trim: a profile's present_trim wins over the platform, its 0 off", present_trim_k(NULL, 0, ios, &src) == 0 && src == TRIM_OFF && present_trim_k(NULL, 120, ios, &src) == 120 && src == TRIM_PROFILE
                && present_trim_ticks(120, src, 120) == 120 && present_trim_ticks(120, src, 30) == 120);
      }
      k = present_trim_k(NULL, -1, 1, &src);
      CHECK("trim: iOS without the key or the variable: 60 ticks (iOS default)", k == 60 && src == TRIM_PLATFORM && present_trim_ticks(k, src, 60) == 60 && present_trim_ticks(k, src, 30) == 60);
      CHECK("trim: iOS default on a 120 Hz link: a second of ticks", present_trim_ticks(k, src, 120) == 120);
      k = present_trim_k(NULL, -1, 0, &src);
      CHECK("trim: the Mac without the key or the variable: off", k == 0 && src == TRIM_OFF && present_trim_ticks(k, src, 120) == 0);
    }
    printf("trim: K %d (game profile present_trim %d, -1 no key)\n", g_link_trim, DM_GAME_PRESENT_TRIM);
    g_link_trim = 3; g_link_trim_src = TRIM_PROFILE; uint64_t drop0 = g_link_dropped, in0 = g_pq_in;
    present_enqueue(&a, 1. / 60, NULL, NULL); present_enqueue(&b, 1. / 60, NULL, NULL); tick();
    CHECK("two waiting, first tick: the older (FIFO)", g_pq_read == in0 + 1 && g_link_it_depth == 2 && g_link_trims == 0);
    present_enqueue(&b, 1. / 60, NULL, NULL); tick();
    CHECK("two waiting, second tick: the older (FIFO)", g_pq_read == in0 + 2 && g_link_trims == 0);
    present_enqueue(&c, 1. / 60, left_half, NULL); tick();
    CHECK("two waiting, third tick: the newest, one dropped", g_pq_read == in0 + 4 && g_pq_read == g_pq_in && g_link_trims == 1 && g_link_dropped == drop0 + 1);
    present_enqueue(&a, 1. / 60, NULL, NULL); tick();
    CHECK("one waiting: taken, the run starts again", g_pq_read == g_pq_in && g_link_standing == 0 && g_link_trims == 1 && g_link_dropped == drop0 + 1);
    pthread_mutex_lock(&g_pq_mu); struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 5;
    while (g_pq_inflight && pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT) {}
    int left = g_pq_inflight; pthread_mutex_unlock(&g_pq_mu);
    CHECK("the trim's presents completed", left == 0);
    g_link_trim = 0;

    // Present effects released when off (present_fx_idle): edge smoothing (CMAA2) and MetalFX run on a 64x64 picture shown at 128x128, then both are turned off. Once the effects have
    // not run for g_fx_idle_presents presents and the last present that ran them has completed, their textures and buffers leave the residency set and GPU allocated falls by them;
    // turned on again they are made again. DM_PRESENT_FX_KEEP=1 keeps them, as before
    fx_case();
    printf("present allocators: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
