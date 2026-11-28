// The Vitals text cache (DmVitals.m, DM_VITALS_CACHE), run off the device: built for Mac Catalyst by test_vitals_cache.py, with DmVitals.m included so its statics are reachable.
// Checks that the cache shows tick by tick what building every tick shows (frame rate, power, heat, battery, time, Detailed, a narrow row's drops), that a steady scene builds
// nothing, that a change rebuilds only its half, and that Low Power Mode alone recolours the battery symbol (left stale with the cache off, as before). Then the cost of a
// steady tick's vit_place with the cache off and on, best of 5 x 1000 (the Mac's CPU: a phone's figure is a few times higher)
#include <stdarg.h>
#include <stdio.h>
#include <mach/mach_time.h>
#import "DmVitals.m"
static nvn_vitals g_feed;
int dm_vitals_read(nvn_vitals *out) { *out = g_feed; return 1; }
void dm_vitals_level_set(int level) { (void)level; }
void dm_vitals_menu_set(int open) { (void)open; }
int dm_power_detail_on(void) { return 0; }
uint64_t now_ns(void) { return 5000000000ull; }

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: %s (line %d)\n", msg, __LINE__); } } while (0)
static void feed(int fps, int mw) { g_feed = (nvn_vitals){.stamp_ns = 4900000000ull, .cpu_mw = mw, .pshare_pm = 800, .gpu_busy_pm = 640, .fps10 = fps * 10, .max_gap_100us = 330}; }
static void dev(int thermal, int pct, int lpm, const char *t) { strlcpy(g_time, t, sizeof g_time); g_dev = (nvn_vitals_dev){.thermal = thermal, .bat_pct = pct, .bat_state = 1, .lpm = lpm, .time = g_time}; }
static void step(void) { vit_read(); vit_place(); }   // a tick without vit_device (the test sets the device side)
static NSString *texts(void) {
    DmVitalsPill *L = g_view.left, *R = g_view.right;
    return [NSString stringWithFormat:@"%@|%@|%@|%@|%@", L.line1.attributedText.string, R.line1.attributedText.string, L.line2.attributedText.string ?: @"", R.line2.attributedText.string ?: @"", g_view.accessibilityLabel];
}
static NSArray<NSString *> *run_sequence(int cache) {
    g_vit_cache = cache; vit_texts_reset(); g_smooth = (nvn_vitals_smooth){0}; g_fps = g_w10 = -1;
    NSMutableArray *out = [NSMutableArray array];
    int fpss[] = {60, 60, 60, 59, 45, 45, 30, 30, 60, 60}; int mws[] = {3100, 3100, 3200, 3600, 3600, 3700, 2000, 2000, 2000, 2100};
    for (int i = 0; i < 10; i++) {
        if (i == 3) dm_vitals_set_level(2);
        feed(fpss[i], mws[i]); dev(i < 5 ? 0 : 1, 82 - i / 4, 0, i < 7 ? "9:41" : "9:42");
        if (i == 6) dm_vitals_layout(CGRectMake(0, 0, 600, 60), 1, CGRectMake(250, 0, 100, 44));   // a narrow row: drops
        if (i == 8) dm_vitals_layout(CGRectMake(0, 0, 900, 60), 1, CGRectMake(400, 0, 100, 44));
        step(); [out addObject:texts()];
    }
    dm_vitals_set_level(1);
    return out;
}
int main(void) { @autoreleasepool {
    dm_vitals_view(); g_view.hidden = NO; g_level = 1; dm_vitals_layout(CGRectMake(0, 0, 900, 60), 1, CGRectMake(400, 0, 100, 44));
    // 1. The same labels and accessibility text with the cache on and off, tick by tick, through changes of every input
    NSArray *off = run_sequence(0), *on = run_sequence(1);
    CHECK([off isEqualToArray:on], "the cache shows exactly what building each tick shows");
    if (![off isEqualToArray:on]) for (NSUInteger i = 0; i < off.count; i++) if (![off[i] isEqualToString:on[i]]) fprintf(stderr, "  tick %lu off: %s\n  tick %lu on:  %s\n", i, [off[i] UTF8String], i, [on[i] UTF8String]);
    // 2. A steady scene builds nothing after the first tick
    g_vit_cache = 1; vit_texts_reset(); g_level = 1; feed(60, 3100); dev(0, 80, 0, "9:41");
    for (int i = 0; i < 5; i++) step();   // the smoothing settles
    g_cache_hits = g_cache_builds = 0;
    for (int i = 0; i < 50; i++) step();
    CHECK(g_cache_builds == 0 && g_cache_hits == 100, "a steady scene: nothing built, both halves reused");
    NSAttributedString *right0 = g_ha[0], *left0 = g_ha[1];
    feed(45, 3100); for (int i = 0; i < 3; i++) step();
    CHECK(g_ha[1] != left0 && g_ha[0] == right0, "a new frame rate rebuilds the left half only");
    // 3. Low Power Mode alone recolours the battery symbol (the plain text does not change)
    NSAttributedString *before = g_view.right.line1.attributedText;
    dev(0, 80, 1, "9:41"); step();
    NSAttributedString *after = g_view.right.line1.attributedText;
    CHECK([before.string isEqualToString:after.string] && ![before isEqualToAttributedString:after], "cache on: Low Power Mode alone sets the right half again (its symbol turns yellow)");
    g_vit_cache = 0; vit_texts_reset(); dev(0, 80, 0, "9:41"); step(); before = g_view.right.line1.attributedText; dev(0, 80, 1, "9:41"); step(); after = g_view.right.line1.attributedText;
    CHECK([before isEqualToAttributedString:after], "cache off (as before): Low Power Mode alone leaves the old symbol (the plain text is the same)");
    // 4. Cost of a steady tick's vit_place, best of 5 x 1000
    mach_timebase_info_data_t tb; mach_timebase_info(&tb);
    for (int mode = 0; mode < 2; mode++) {
        g_vit_cache = mode; vit_texts_reset(); dev(1, 80, 0, "9:41"); feed(60, 3100);
        for (int lv = 1; lv <= 2; lv++) {
            g_level = lv; double best = 1e9;
            for (int r = 0; r < 5; r++) {
                uint64_t t0 = mach_absolute_time();
                for (int i = 0; i < 1000; i++) @autoreleasepool { step(); }
                double us = (double)(mach_absolute_time() - t0) * tb.numer / tb.denom / 1000.0 / 1000;
                if (us < best) best = us;
            }
            printf("vit_place, steady tick, %s, cache %s: %.1f us\n", lv == 2 ? "Detailed" : "Standard", mode ? "on" : "off", best);
        }
    }
    printf("vitals cache: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}}
