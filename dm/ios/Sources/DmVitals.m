// Vitals on the iPhone and iPad (DmVitals.h; NX18-X2.0 vitals.md §2, §7, §10).
// The present thread publishes the frame rate, CPU power, GPU busy time and the cap once a second (hle_nvn.c vitals_tick, nvn_vitals.h); this file adds Apple's thermal state,
// the battery and the time, formats both halves with nvn_vitals.h, and fits them beside − (≡) + by dropping fields in the fixed order. Solid pill fill (#141415 at 65%, 85% with
// Reduce Transparency or Increase Contrast), no blur, no masksToBounds; display only, so every touch reaches the pad and the game. One 1 s timer, tolerance 0.2 s, while Vitals is on
// or the in-game menu is open, in the foreground only; text is set only when it changed (the hysteresis in nvn_vitals.h keeps a steady scene's text still).
#import "DmVitals.h"
#include <stdatomic.h>
#include "dm.h"
#include "ui_font.h"
#include "nvn_vitals.h"

int dm_vitals_read(nvn_vitals *out);     // hle_nvn.c: the last whole window
void dm_vitals_level_set(int level);     // hle_nvn.c: the publisher's gate
void dm_vitals_menu_set(int open);
int dm_power_detail_on(void);
uint64_t now_ns(void);

NSString *const DmVitalsTickNotification = @"DmVitalsTick";

static UIColor *vit_cyan(void) { return [UIColor colorWithRed:0x00 / 255.0 green:0xC8 / 255.0 blue:0xF5 / 255.0 alpha:1]; }
static UIColor *vit_coral(void) { return [UIColor colorWithRed:0xFF / 255.0 green:0x6B / 255.0 blue:0x5A / 255.0 alpha:1]; }
static UIColor *vit_fill(void) {
    BOOL solid = UIAccessibilityIsReduceTransparencyEnabled() || UIAccessibilityDarkerSystemColorsEnabled();
    return [UIColor colorWithRed:0x14 / 255.0 green:0x14 / 255.0 blue:0x15 / 255.0 alpha:solid ? 0.85 : 0.65];
}

@interface DmVitalsPill : UIView
@property (nonatomic, strong) UILabel *line1, *line2;
@end
@implementation DmVitalsPill
- (instancetype)init {
    if (!(self = [super initWithFrame:CGRectZero])) return nil;
    self.layer.backgroundColor = vit_fill().CGColor; self.layer.cornerRadius = 6;   // rounded ends without masksToBounds: no offscreen pass
    self.userInteractionEnabled = NO; self.isAccessibilityElement = NO;
    for (int i = 0; i < 2; i++) {
        UILabel *l = [UILabel new];
        l.textColor = UIColor.whiteColor; l.userInteractionEnabled = NO; l.isAccessibilityElement = NO; l.backgroundColor = UIColor.clearColor;
        [self addSubview:l];
        if (i) self.line2 = l; else self.line1 = l;
    }
    return self;
}
@end

@interface DmVitalsView : UIView
@property (nonatomic, strong) DmVitalsPill *left, *right;
@end
@implementation DmVitalsView
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e { (void)p; (void)e; return nil; }   // display only: a tap goes to what is under it (the pad, the game's touch screen)
@end

static DmVitalsView *g_view;
static int g_level, g_menu, g_fg = 1, g_bat_watch;
static NSTimer *g_timer;
static nvn_vitals_smooth g_smooth;
static nvn_vitals g_last; static int g_fresh, g_fps = -1, g_w10 = -1, g_shown;   // g_shown: the pictures on screen while frame generation shows frames (nvn_vitals_shown_step), 0 otherwise
static nvn_vitals_dev g_dev;
static char g_time[16];
static NSDateFormatter *g_fmt;
static CGRect g_row, g_center; static CGFloat g_u = 1;
static NSString *g_t1l, *g_t1r, *g_t2l, *g_t2r;   // the last texts set: set again only on a change

static void vit_time(void) {
    if (!g_fmt) {
        g_fmt = [NSDateFormatter new];
        NSString *f = [NSDateFormatter dateFormatFromTemplate:@"jmm" options:0 locale:NSLocale.currentLocale] ?: @"H:mm";
        f = [[f stringByReplacingOccurrencesOfString:@"a" withString:@""] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];   // the 12- or 24-hour setting, no AM/PM, as the status bar
        g_fmt.dateFormat = f;
    }
    strlcpy(g_time, [g_fmt stringFromDate:NSDate.date].UTF8String ?: "", sizeof g_time);
}
static void vit_battery_watch(int on) {
    if (on == g_bat_watch) return;
    g_bat_watch = on;
    if (on) UIDevice.currentDevice.batteryMonitoringEnabled = YES;
    else if (!dm_power_detail_on()) UIDevice.currentDevice.batteryMonitoringEnabled = NO;   // the power detail line keeps its own (front_ios.m)
}
static void vit_device(void) {   // main thread
    NSProcessInfoThermalState t = NSProcessInfo.processInfo.thermalState;
    g_dev.thermal = (int)t <= 3 ? (int)t : -1;
    UIDevice *d = UIDevice.currentDevice; float l = d.batteryMonitoringEnabled ? d.batteryLevel : -1; UIDeviceBatteryState s = d.batteryState;
    g_dev.bat_pct = l < 0 ? -1 : (int)lroundf(l * 100);
    g_dev.bat_state = s == UIDeviceBatteryStateUnplugged ? 1 : s == UIDeviceBatteryStateCharging ? 2 : s == UIDeviceBatteryStateFull ? 3 : 0;
    g_dev.lpm = NSProcessInfo.processInfo.lowPowerModeEnabled;
    vit_time(); g_dev.time = g_time;
}
static void vit_read(void) {
    nvn_vitals v;
    if (dm_vitals_read(&v)) g_last = v;
    g_fresh = nvn_vitals_fresh(&g_last, now_ns());
    int fps = g_fresh ? (g_last.fps10 + 5) / 10 : -1, w10 = g_fresh && g_last.cpu_mw >= 0 ? (g_last.cpu_mw + 50) / 100 : -1;
    nvn_vitals_smooth_step(&g_smooth, fps, w10, &g_fps, &g_w10);
    g_shown = nvn_vitals_shown_step(&g_smooth, &g_last, g_fresh);
}

// The attributed text: 🌡 becomes the thermometer symbol (its fill steps with the state; cyan at Cool and Warm, coral at Hot and Too hot), ▮ the battery symbol
// (yellow in Low Power Mode, as iOS draws it); everything else white, digits that do not jitter
static NSAttributedString *vit_text(NSString *s, CGFloat size, BOOL second) {
    UIFont *f = dm_ui_mono_digits(size, second ? UIFontWeightMedium : UIFontWeightSemibold);
    NSMutableAttributedString *a = [NSMutableAttributedString new];
    NSDictionary *base = @{NSFontAttributeName: f, NSForegroundColorAttributeName: second ? [UIColor colorWithWhite:1 alpha:0.8] : UIColor.whiteColor};
    NSScanner *sc = [NSScanner scannerWithString:s]; sc.charactersToBeSkipped = nil;
    NSCharacterSet *marks = [NSCharacterSet characterSetWithCharactersInString:@"🌡▮"];
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithFont:f scale:UIImageSymbolScaleSmall];
    while (!sc.atEnd) {
        NSString *run = nil;
        if ([sc scanUpToCharactersFromSet:marks intoString:&run] && run.length) [a appendAttributedString:[[NSAttributedString alloc] initWithString:run attributes:base]];
        if (sc.atEnd) break;
        NSRange r = [s rangeOfComposedCharacterSequenceAtIndex:sc.scanLocation];
        NSString *m = [s substringWithRange:r]; sc.scanLocation = NSMaxRange(r);
        NSString *name; UIColor *tint;
        if ([m isEqualToString:@"🌡"]) {
            int t = g_dev.thermal; name = t <= 0 ? @"thermometer.low" : t == 1 ? @"thermometer.medium" : @"thermometer.high"; tint = t >= 2 ? vit_coral() : vit_cyan();
        } else {
            int p = g_dev.bat_pct; name = p >= 88 ? @"battery.100percent" : p >= 63 ? @"battery.75percent" : p >= 38 ? @"battery.50percent" : p >= 13 ? @"battery.25percent" : @"battery.0percent";
            tint = g_dev.lpm ? UIColor.systemYellowColor : UIColor.whiteColor;
        }
        UIImage *img = [[UIImage systemImageNamed:name withConfiguration:cfg] imageWithTintColor:tint renderingMode:UIImageRenderingModeAlwaysOriginal];
        if (!img) { [a appendAttributedString:[[NSAttributedString alloc] initWithString:m attributes:base]]; continue; }
        NSTextAttachment *at = [NSTextAttachment textAttachmentWithImage:img];
        at.bounds = CGRectMake(0, f.descender * 0.6, img.size.width, img.size.height);
        NSMutableAttributedString *as = [[NSAttributedString attributedStringWithAttachment:at] mutableCopy];
        [as addAttributes:base range:NSMakeRange(0, as.length)];
        [a appendAttributedString:as];
    }
    return a;
}
static CGFloat vit_width(NSAttributedString *a) { return ceil([a boundingRectWithSize:CGSizeMake(1e4, 100) options:NSStringDrawingUsesLineFragmentOrigin context:nil].size.width); }

static CGFloat vit_size(void) {   // 13 pt; 15 pt at the player's accessibility text sizes (the app's setting, not the window's forced Small)
    return UIContentSizeCategoryIsAccessibilityCategory(UIApplication.sharedApplication.preferredContentSizeCategory) ? 15 : 13;
}

// One half: its strings from drop 0 to 2, the first that fits `room` (text plus 8 pt a side); the last when none does
static NSString *vit_fit(int left, CGFloat room, CGFloat size, NSAttributedString **out, CGFloat *w) {
    char b[160]; NSString *s = nil;
    for (int drop = 0; drop <= 2; drop++) {
        if (left) nvn_vitals_left(b, sizeof b, &g_last, g_fps, g_shown, g_w10, g_fresh, g_level == 2, drop);
        else nvn_vitals_right(b, sizeof b, &g_dev, drop);
        s = @(b);
        NSAttributedString *a = vit_text(s, size, NO); CGFloat aw = vit_width(a);
        *out = a; *w = aw;
        if (aw + 16 <= room) break;
    }
    return s;
}

static void vit_accessibility(void) {   // one element, read in words on focus; it never speaks by itself
    NSMutableArray *p = [NSMutableArray array];
    if (g_fresh && g_fps >= 0) [p addObject:[NSString stringWithFormat:@"%d frames per second%@", g_fps, g_last.capped ? @", capped" : @""]];
    if (g_fresh && g_w10 >= 0) [p addObject:[NSString stringWithFormat:@"CPU power %d.%d watts", g_w10 / 10, g_w10 % 10]];
    const char *h = nvn_vitals_heat_word(g_dev.thermal); if (h) [p addObject:@(h)];
    if (g_dev.bat_pct >= 0) [p addObject:[NSString stringWithFormat:@"Battery %d percent%@", g_dev.bat_pct, g_dev.bat_state == 2 ? @", charging" : @""]];
    if (g_time[0]) [p addObject:@(g_time)];
    g_view.accessibilityLabel = [p componentsJoinedByString:@". "];
}

static void vit_place(void) {   // main thread: fit both halves into the row, either side of − (≡) +
    if (!g_view || g_view.hidden) return;
    CGFloat size = vit_size(), h1 = round(size * 1.7), u = g_u;
    CGFloat y = floor(CGRectGetMinY(g_row) + 22 * u - h1 / 2);
    CGFloat lx = floor(CGRectGetMinX(g_row) + 130 * u), rx = ceil(CGRectGetMaxX(g_row) - 130 * u);
    BOOL center = !CGRectIsEmpty(g_center);
    CGFloat lroom = (center ? CGRectGetMinX(g_center) - 8 : CGRectGetMidX(g_row) - 4) - lx, rroom = rx - (center ? CGRectGetMaxX(g_center) + 8 : CGRectGetMidX(g_row) + 4);
    NSAttributedString *la, *ra; CGFloat lw, rw;
    NSString *ls = vit_fit(1, lroom, size, &la, &lw), *rs = vit_fit(0, rroom, size, &ra, &rw);
    char b2[96]; NSString *l2 = @"", *r2 = @"";
    if (g_level == 2) { nvn_vitals_left2(b2, sizeof b2, &g_last, g_fresh); l2 = @(b2); nvn_vitals_right2(b2, sizeof b2, &g_last, g_fresh); r2 = @(b2); }
    CGFloat size2 = size - 2, h2 = l2.length || r2.length ? round(size2 * 1.5) : 0;
    NSAttributedString *la2 = l2.length ? vit_text(l2, size2, YES) : nil, *ra2 = r2.length ? vit_text(r2, size2, YES) : nil;
    CGFloat lw2 = la2 ? vit_width(la2) : 0, rw2 = ra2 ? vit_width(ra2) : 0;
    DmVitalsPill *L = g_view.left, *R = g_view.right;
    if (![ls isEqualToString:g_t1l]) { L.line1.attributedText = la; g_t1l = ls; }
    if (![rs isEqualToString:g_t1r]) { R.line1.attributedText = ra; g_t1r = rs; }
    if (![l2 isEqualToString:g_t2l]) { L.line2.attributedText = la2; g_t2l = l2; }
    if (![r2 isEqualToString:g_t2r]) { R.line2.attributedText = ra2; g_t2r = r2; }
    CGFloat lW = MIN(MAX(lw, lw2) + 16, MAX(lroom, 0)), rW = MIN(MAX(rw, rw2) + 16, MAX(rroom, 0)), H = h1 + h2;
    L.frame = CGRectMake(lx, y, lW, H); R.frame = CGRectMake(rx - rW, y, rW, H);
    L.line1.frame = CGRectMake(8, 0, lW - 16, h1); R.line1.frame = CGRectMake(8, 0, rW - 16, h1); R.line1.textAlignment = NSTextAlignmentRight;
    L.line2.frame = CGRectMake(8, h1 - 3, lW - 16, h2); R.line2.frame = CGRectMake(8, h1 - 3, rW - 16, h2); R.line2.textAlignment = NSTextAlignmentRight;
    L.line2.hidden = !la2; R.line2.hidden = !ra2;
    R.hidden = !ra.length;
    vit_accessibility();
}

static void vit_tick(void) {
    vit_device();
    vit_read();
    if (g_level && !g_menu) vit_place();
    if (g_menu) [NSNotificationCenter.defaultCenter postNotificationName:DmVitalsTickNotification object:nil];
}
static void vit_timer_update(void) {   // the one 1 s timer: while Vitals is on or the menu is open, in the foreground
    int want = (g_level || g_menu) && g_fg;
    vit_battery_watch((g_level || g_menu) ? 1 : 0);
    if (want && !g_timer) {
        g_timer = [NSTimer timerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) { (void)t; vit_tick(); }];
        g_timer.tolerance = 0.2;   // iOS may bundle the wakeup with others
        [NSRunLoop.mainRunLoop addTimer:g_timer forMode:NSRunLoopCommonModes];
        vit_tick();
    } else if (!want && g_timer) { [g_timer invalidate]; g_timer = nil; }
}

UIView *dm_vitals_view(void) {
    if (g_view) return g_view;
    g_view = [DmVitalsView new];
    g_view.userInteractionEnabled = NO; g_view.backgroundColor = UIColor.clearColor;
    g_view.left = [DmVitalsPill new]; g_view.right = [DmVitalsPill new];
    [g_view addSubview:g_view.left]; [g_view addSubview:g_view.right];
    g_view.isAccessibilityElement = YES; g_view.accessibilityTraits = UIAccessibilityTraitUpdatesFrequently | UIAccessibilityTraitStaticText;
    g_view.hidden = YES;
    for (NSNotificationName nm in @[UIAccessibilityReduceTransparencyStatusDidChangeNotification, UIAccessibilityDarkerSystemColorsStatusDidChangeNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
            (void)n; g_view.left.layer.backgroundColor = g_view.right.layer.backgroundColor = vit_fill().CGColor; }];
    for (NSNotificationName nm in @[NSSystemClockDidChangeNotification, NSCurrentLocaleDidChangeNotification])
        [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; g_fmt = nil; }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIContentSizeCategoryDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; g_t1l = g_t1r = g_t2l = g_t2r = nil; vit_place(); }];
    return g_view;
}
void dm_vitals_set_level(int level) {
    level = level < 0 ? 0 : level > 2 ? 2 : level;
    if (level != g_level) LOG("front end: Vitals %s", level == 2 ? "on (Detailed)" : level ? "on" : "off");
    g_level = level; dm_vitals_level_set(level);
    g_t1l = g_t1r = g_t2l = g_t2r = nil;
    if (g_view) g_view.hidden = !level || g_menu;
    vit_timer_update();
    if (level && !g_menu) { vit_device(); vit_read(); vit_place(); }
}
int dm_vitals_get_level(void) { return g_level; }
void dm_vitals_layout(CGRect row, CGFloat u, CGRect center) { g_row = row; g_u = u; g_center = center; g_t1l = g_t1r = nil; vit_place(); }
void dm_vitals_menu_open(int open) {
    open = !!open; if (open == g_menu) return;
    g_menu = open; dm_vitals_menu_set(open);
    if (g_view) g_view.hidden = !g_level || open;
    if (!open) { g_t1l = g_t1r = g_t2l = g_t2r = nil; }
    vit_timer_update();
    if (!open && g_level) vit_place();
}
void dm_vitals_foreground(int fg) { g_fg = !!fg; vit_timer_update(); }
const char *dm_vitals_compact_text(int drop) {
    static char b[160];
    if (!g_timer) { vit_device(); vit_read(); }   // a read before the first tick
    nvn_vitals_compact(b, sizeof b, &g_last, g_fps, g_shown, g_fresh, &g_dev, drop);
    return b;
}
int dm_vitals_thermal(void) { return g_dev.thermal; }
int dm_vitals_battery(void) { return g_dev.bat_pct; }
int dm_vitals_timer_running(void) { return g_timer != nil; }
