// Included by nvn_mtl.m after the display link's rate helpers (link_range, link_latency, g_link_mode), before link_main, which starts it.
// DM_LINK_SIM=1 (diagnostic): a display link the host times itself, for a Mac whose screen is locked or asleep, where the system's link calls back nothing and every frame goes
// through the rescue path. A run-loop timer on the link thread ticks at the rate the link was asked for (60, 30 or 120 Hz, on a steady clock from its start), takes the layer's
// next drawable and calls the same delegate as the system's link, with a target display time one 60 Hz period ahead at every rate (so the 30 and 60 Hz links compare). The whole display-link path runs as it does on screen
// (the hold, frame generation's tick order, the present pass), but nothing says when a picture was really shown: presented times are the system's (0 for an unseen window)
@interface NvSimLinkUpdate : NSObject
@property (strong) id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@property CFTimeInterval targetTimestamp;   // the callback's deadline (the display link line): the tick after this one, as the system's link sets it for a latency of one
@end
@implementation NvSimLinkUpdate
@end
@interface NvSimLink : NSObject { @public CFRunLoopTimerRef tm; CAMetalLayer *layer; id<CAMetalDisplayLinkDelegate> delegate; double next; uint64_t late; }
@property CAFrameRateRange preferredFrameRateRange;
@property float preferredFrameLatency;
@property BOOL paused;
- (void)invalidate;
@end
@implementation NvSimLink
- (void)invalidate { if (tm) { CFRunLoopTimerInvalidate(tm); CFRelease(tm); tm = NULL; } }
@end
static int link_sim(void) { static int v = -1; if (v < 0) { const char *e = getenv("DM_LINK_SIM"); v = e && !strcmp(e, "1"); if (v) MLOG("display link: simulated by the host's own 60 Hz clock (DM_LINK_SIM=1, diagnostic): presented times are not the screen's"); } return v; }
static void link_sim_tick(CFRunLoopTimerRef tm, void *info) {
    NvSimLink *sl = (__bridge NvSimLink *)info;
    float hz = sl.preferredFrameRateRange.preferred > 0 ? sl.preferredFrameRateRange.preferred : 60; double period = 1.0 / hz, now = CACurrentMediaTime();
    if (now - sl->next > period) { sl->late += (uint64_t)((now - sl->next) / period); sl->next = now; }   // the thread was held up: ticks are skipped, not run in a burst
    double at = sl->next; sl->next += period;
    CFRunLoopTimerSetNextFireDate(tm, CFAbsoluteTimeGetCurrent() + (sl->next - CACurrentMediaTime()));
    if (sl.paused) return;
    @autoreleasepool {
        id<CAMetalDrawable> dr = [sl->layer nextDrawable]; if (!dr) return;
        NvSimLinkUpdate *u = [NvSimLinkUpdate new]; u.drawable = dr; u.targetPresentationTimestamp = at + 1.0 / 60; u.targetTimestamp = at + period;
        [sl->delegate metalDisplayLink:(CAMetalDisplayLink *)(id)sl needsUpdate:(CAMetalDisplayLinkUpdate *)(id)u];
    }
}
static void link_sim_run(CAMetalLayer *layer, NvMetalDisplayLinkDelegate *delegate) {
    NvSimLink *sl = [NvSimLink new]; sl->layer = layer; sl->delegate = delegate; sl.preferredFrameRateRange = link_range(g_link_mode); sl.preferredFrameLatency = link_latency(); sl->next = CACurrentMediaTime();
    CFRunLoopTimerContext cx = {0, (__bridge void *)sl, NULL, NULL, NULL};
    sl->tm = CFRunLoopTimerCreate(NULL, CFAbsoluteTimeGetCurrent(), 1000, 0, 0, link_sim_tick, &cx); CFRunLoopTimerSetTolerance(sl->tm, 0);
    CFRunLoopAddTimer(CFRunLoopGetCurrent(), sl->tm, kCFRunLoopDefaultMode);
    g_link_rl = CFRunLoopGetCurrent(); g_link = (CAMetalDisplayLink *)(id)sl;
    CFRunLoopRun();
    [sl invalidate];
    MLOG("display link (simulated): stopped, %llu ticks skipped for a late thread", (unsigned long long)sl->late);
}
