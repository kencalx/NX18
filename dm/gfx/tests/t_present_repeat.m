// The present repeat (DM_PRESENT_REPEAT=1, nvn_present_repeat.inc) with the display link's callback called by hand (no window, no game files), as t_framegen_dlss does: a "game"
// presents a texture of one colour per frame and the link ticks. Checked, repeat on: present snapshots are on; a tick before any frame presents nothing; the tick that takes a
// frame shows it, and a tick without a new frame shows the same picture again on its own drawable, even after the game drew into its texture again (the snapshot, not the
// game's texture), without counting as a present (g_present_n, g_pq_done, g_pres and the empty-tick count are the real frames'); a tick held for a long present interval with
// the next frame waiting is passed over with the default ring of 2 and repeated with DM_PRESENT_SNAP=3 ("ring3"); an empty tick inside a hold is repeated; nothing while
// presents are discarded (a suspend), in the rescue, or once a newer ticket was dropped; frame generation stays off. "off" (unset, or any value but 1): no repeat, no
// snapshots, the counts as before (without DM_FRAMEGEN, which would turn snapshots on)
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
@interface FakeLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@property CFTimeInterval targetTimestamp;   // the callback's deadline (the display link line reads it)
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
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } else printf("ok: %s\n", label); } while (0)
enum { W = 64, H = 64 };
static id<MTLTexture> g_game;   // the game's window texture (shared storage: the "game" draws into it from the CPU)
static void game_draw(int v) {   // the whole texture one colour: red v, green 255 - v
    static uint8_t px[W * H * 4]; for (int i = 0; i < W * H; i++) { px[4 * i] = (uint8_t)v; px[4 * i + 1] = (uint8_t)(255 - v); px[4 * i + 2] = 0; px[4 * i + 3] = 255; }
    [g_game replaceRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 withBytes:px bytesPerRow:W * 4];
}
static CAMetalLayer *offscreen_layer(void) {
    CAMetalLayer *l = [CAMetalLayer layer]; l.device = g_dev; l.pixelFormat = MTLPixelFormatBGRA8Unorm; l.framebufferOnly = NO; l.drawableSize = CGSizeMake(W, H); return l;
}
static id<CAMetalDrawable> drawable(void) {   // from four layers in turn, as t_framegen_dlss's
    static CAMetalLayer *ls[4]; static int k;
    CAMetalLayer *l = ls[k % 4]; if (!l) { l = ls[k % 4] = offscreen_layer(); [g_q4 addResidencySet:l.residencySet]; }
    k++; return [l nextDrawable];
}
static NvMetalDisplayLinkDelegate *g_delegate; static double g_ts; static int g_tick;
static void settle(void) {
    pthread_mutex_lock(&g_pq_mu); struct timespec ts; clock_gettime(CLOCK_REALTIME, &ts); ts.tv_sec += 5;
    while (g_pq_inflight && pthread_cond_timedwait(&g_pq_cv, &g_pq_mu, &ts) != ETIMEDOUT) {}
    pthread_mutex_unlock(&g_pq_mu);
}
static id<CAMetalDrawable> tick(void) {
    id<CAMetalDrawable> dr = drawable();
    FakeLinkUpdate *u = [FakeLinkUpdate new]; u.drawable = dr; u.targetPresentationTimestamp = g_ts + g_tick++ / 60.0;
    @autoreleasepool { [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u]; }
    settle(); return dr;
}
static int red_of(id<MTLTexture> t) {   // the drawable's centre pixel's red (BGRA8)
    id<MTLBuffer> b = [g_dev newBufferWithLength:4 options:MTLResourceStorageModeShared];
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, t); t4_use(cb, b);
    [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(W / 2, H / 2, 0) sourceSize:MTLSizeMake(1, 1, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:4 destinationBytesPerImage:4];
    t4_end(cb, e); t4_wait(cb);
    const uint8_t *p = b.contents; return p[1] == 255 - p[2] ? p[2] : -1;   // -1: not a picture the game drew
}
static tex_t g_win;
static uint64_t present(int v, double period) { game_draw(v); atomic_fetch_add(&g_cur_frame, 1); return present_enqueue(&g_win, period, NULL, NULL); }
static uint64_t done_n(void) { pthread_mutex_lock(&g_pq_mu); uint64_t d = g_pq_done; pthread_mutex_unlock(&g_pq_mu); return d; }
int main(int argc, char **argv) { @autoreleasepool {
    alarm(120); setbuf(stdout, NULL);
    const char *mode = argc > 1 ? argv[1] : "on";
    int off = !strcmp(mode, "off"), ring3 = !strcmp(mode, "ring3");
    if (off) { const char *v = argc > 2 ? argv[2] : NULL; if (v) setenv("DM_PRESENT_REPEAT", v, 1); else if (DM_GAME_PRESENT_REPEAT) setenv("DM_PRESENT_REPEAT", "0", 1); else unsetenv("DM_PRESENT_REPEAT"); }   // a profile with present_repeat on (Bananza): off is =0
    else setenv("DM_PRESENT_REPEAT", "1", 1);
    setenv("DM_PRESENT_SNAP", ring3 ? "3" : "0", 1);
    if (off) unsetenv("DM_FRAMEGEN"); else setenv("DM_FRAMEGEN", "1", 1);   // on: frame generation asked for too, which the repeat turns off (t_framegen_dlss "repeat off": on with another value)
    setenv("DM_PRESENT_TRIM", "0", 1); setenv("DM_PRESENT_SHARPEN", "0", 1); setenv("DM_PRESENT_UPSCALE", "off", 1); setenv("DM_POST_AA", "off", 1); setenv("DM_PSO_PREPARE", "0", 1);
    mtl_init();
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:W height:H mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead; g_game = [g_dev newTextureWithDescriptor:d];
    g_win = (tex_t){.magic = MAGIC('T','E','X',0), .serial = 96001};
    g_win.d.width = W; g_win.d.height = H; g_win.d.depth = g_win.d.levels = g_win.d.samples = 1; g_win.d.target = NVN_TEXTURE_TARGET_2D; g_win.d.format = NVN_FORMAT_RGBA8;
    serial_put(g_win.serial, g_game); res_add(g_game); res_commit();
    g_test_layer = offscreen_layer(); mtl_present_layer(W, H);
    g_dm_present_link = 1; g_link_started = 1; g_link_owns_layer = 1; g_delegate = [NvMetalDisplayLinkDelegate new];
    g_ts = CACurrentMediaTime() + 1;
    const double one = 1.0 / 60, two = 2.0 / 60;
    if (off) {
        CHECK(!rep_on() && !mtl_snap_on(), "off (unset or not 1): no present repeat, and present snapshots stay off (DM_PRESENT_SNAP=0)");
        tick(); present(10, one); tick();
        game_draw(20); id<CAMetalDrawable> e = tick(); (void)e;
        CHECK(g_rep_shown == 0 && g_rep_n == 0 && !g_rep_alloc[0] && !g_rep_ticket, "off: an empty tick presents nothing, makes nothing and records nothing");
        CHECK(g_present_n == 1 && done_n() == 1 && g_link_empty == 2, "off: one present, its ticket done, two empty ticks counted");
        printf("t_present_repeat off%s%s: %d checks, %d failed\n", argc > 2 ? " " : "", argc > 2 ? argv[2] : "", checks, failed); return failed != 0;
    }
    CHECK(rep_on() && mtl_snap_on() && g_snap_n == (ring3 ? 3 : 2), "on: present repeat, with present snapshots (a ring of 2 when DM_PRESENT_SNAP=0)");
    CHECK(!fg_on(), "on: frame generation is off though DM_FRAMEGEN=1");
    id<CAMetalDrawable> e = tick();
    CHECK(g_rep_shown == 0 && g_present_n == 0, "a tick before any frame presents nothing");
    uint64_t t1 = present(40, one); id<CAMetalDrawable> a = tick();
    CHECK(g_present_n == 1 && done_n() == t1 && red_of(a.texture) == 40, "the tick that takes frame 1 shows it");
    uint64_t empty0 = g_link_empty; pres_ent p1 = g_pres[t1 % PRING];
    game_draw(200);   // the game draws its next frame into the same texture, not yet presented
    e = tick();
    CHECK(g_rep_shown == 1 && red_of(e.texture) == 40, "an empty tick shows frame 1 again, from its snapshot, not the texture the game is drawing into");
    CHECK(g_present_n == 1 && done_n() == t1 && g_link_empty == empty0 + 1 && !memcmp(&g_pres[t1 % PRING], &p1, sizeof p1), "a repeat is not a present: present count, done ticket and presented-time record unchanged; the tick counts as empty");
    e = tick(); CHECK(g_rep_shown == 2 && red_of(e.texture) == 40, "and on the next empty tick again");
    uint64_t t2 = present(80, one); a = tick();
    CHECK(g_present_n == 2 && done_n() == t2 && red_of(a.texture) == 80 && g_rep_shown == 2, "a new frame is shown on its tick, not a repeat");
    e = tick(); CHECK(g_rep_shown == 3 && red_of(e.texture) == 80, "the empty tick after it repeats the new frame");
    // A long present interval: frame 3 held two ticks; frame 4 waits through the held tick
    uint64_t t3 = present(120, two); a = tick(); CHECK(red_of(a.texture) == 120 && done_n() == t3, "frame 3 (two ticks) is shown");
    uint64_t held0 = g_link_held, ring0 = g_rep_ring, shown0 = g_rep_shown;
    uint64_t t4 = present(160, one); e = tick();
    CHECK(g_link_held == held0 + 1 && done_n() == t3, "the next tick is held for frame 3's interval, frame 4 waiting");
    if (ring3) CHECK(g_rep_shown == shown0 + 1 && red_of(e.texture) == 120, "ring of 3: the held tick shows frame 3 again (its slot is two frames from its next copy)");
    else CHECK(g_rep_shown == shown0 && g_rep_ring == ring0 + 1, "ring of 2: the held tick with frame 4 waiting is passed over (frame 5 copies into frame 3's slot)");
    a = tick(); CHECK(red_of(a.texture) == 160 && done_n() == t4, "frame 4 on the tick after the hold");
    uint64_t t5 = present(60, two); a = tick(); CHECK(red_of(a.texture) == 60 && done_n() == t5, "frame 5 (two ticks) is shown");
    shown0 = g_rep_shown; e = tick();
    CHECK(g_rep_shown == shown0 + 1 && red_of(e.texture) == 60, "a held tick with nothing waiting is an empty tick: frame 5 again");
    // A suspend: presents discarded, nothing goes to the GPU; after it the last frame again
    mtl_present_discard(1); shown0 = g_rep_shown; e = tick();
    CHECK(g_rep_shown == shown0, "presents discarded (going to the background): no repeat");
    mtl_present_discard(0); e = tick();
    CHECK(g_rep_shown == shown0 + 1 && red_of(e.texture) == 60, "back: the last frame again");
    // The rescue (the present thread takes drawables): the link does not repeat
    atomic_store(&g_rescue_mode, 1); shown0 = g_rep_shown; tick(); atomic_store(&g_rescue_mode, 0);
    CHECK(g_rep_shown == shown0, "in the rescue: no repeat");
    // A frame dropped by the suspend after the link showed frame 5: a newer ticket was taken, so the old frame is not shown again
    present(90, one); mtl_present_discard(1); mtl_present_discard(0); shown0 = g_rep_shown; uint64_t other0 = g_rep_other; tick();
    CHECK(g_rep_shown == shown0 && g_rep_other == other0 + 1, "after a dropped frame (a newer ticket taken): no repeat of the older one");
    uint64_t t7 = present(30, one); a = tick(); e = tick();
    CHECK(done_n() == t7 && red_of(a.texture) == 30 && red_of(e.texture) == 30 && g_rep_shown == shown0 + 1, "the next frame and its repeat");
    pthread_mutex_lock(&g_pq_mu); int busy = g_rep_busy, inflight = g_pq_inflight; pthread_mutex_unlock(&g_pq_mu);
    CHECK(!busy && !inflight, "nothing left busy or in flight");
    printf("t_present_repeat %s: %d checks, %d failed\n", mode, checks, failed); return failed != 0;
} }
