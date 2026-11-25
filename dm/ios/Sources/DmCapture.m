// See DmCapture.h.
#import "DmCapture.h"
#include "front_capture.h"
#include "ui_font.h"

static UIView *g_notice;   // the one notice showing, replaced by the next

static void notice_show(UIWindow *w, UIImage *thumb, NSString *text) {
    if (!w) return;
    [g_notice removeFromSuperview];
    UIView *pill = [UIView new];
    pill.backgroundColor = [UIColor colorWithWhite:0.08 alpha:0.86]; pill.layer.cornerRadius = 14; pill.layer.cornerCurve = kCACornerCurveContinuous;
    pill.userInteractionEnabled = NO; pill.isAccessibilityElement = NO;
    UIImageView *iv = [[UIImageView alloc] initWithImage:thumb ?: [UIImage systemImageNamed:@"camera.fill"]];
    iv.contentMode = thumb ? UIViewContentModeScaleAspectFill : UIViewContentModeCenter; iv.clipsToBounds = YES; iv.layer.cornerRadius = 6;
    iv.tintColor = [UIColor colorWithRed:0x00 / 255.0 green:0xC8 / 255.0 blue:0xF5 / 255.0 alpha:1];
    UILabel *l = [UILabel new]; l.text = text; l.textColor = UIColor.whiteColor; l.font = dm_ui_font(15, UIFontWeightSemibold);
    for (UIView *v in @[iv, l]) { v.translatesAutoresizingMaskIntoConstraints = NO; [pill addSubview:v]; }
    pill.translatesAutoresizingMaskIntoConstraints = NO;
    [w addSubview:pill];
    [NSLayoutConstraint activateConstraints:@[
        [pill.leadingAnchor constraintEqualToAnchor:w.safeAreaLayoutGuide.leadingAnchor constant:12],
        [pill.topAnchor constraintEqualToAnchor:w.safeAreaLayoutGuide.topAnchor constant:10],
        [iv.leadingAnchor constraintEqualToAnchor:pill.leadingAnchor constant:8], [iv.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
        [iv.widthAnchor constraintEqualToConstant:thumb ? 52 : 28], [iv.heightAnchor constraintEqualToConstant:thumb ? 30 : 28],
        [l.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:10], [l.trailingAnchor constraintEqualToAnchor:pill.trailingAnchor constant:-14],
        [l.topAnchor constraintEqualToAnchor:pill.topAnchor constant:10], [l.bottomAnchor constraintEqualToAnchor:pill.bottomAnchor constant:-10],
    ]];
    g_notice = pill;
    pill.alpha = 0;
    BOOL still = UIAccessibilityIsReduceMotionEnabled();
    if (!still) pill.transform = CGAffineTransformMakeTranslation(0, -8);
    [UIView animateWithDuration:0.2 animations:^{ pill.alpha = 1; pill.transform = CGAffineTransformIdentity; }];
    UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, text);
    __weak UIView *weak = pill;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIView *p = weak; if (!p) return;
        [UIView animateWithDuration:0.3 animations:^{ p.alpha = 0; } completion:^(BOOL f) { (void)f; [p removeFromSuperview]; if (g_notice == p) g_notice = nil; }];
    });
}

void dm_capture_screenshot(UIView *over) {
    __weak UIView *weak = over;
    BOOL asked = front_capture_screenshot(^(NSString *path, BOOL ok) {
        UIWindow *w = weak.window;
        if (!ok) { notice_show(w, nil, @"Couldn't save the screenshot"); return; }
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // a small picture for the notice, off the main thread
            UIImage *thumb = [[UIImage imageWithContentsOfFile:path] imageByPreparingThumbnailOfSize:CGSizeMake(104, 60)];
            dispatch_async(dispatch_get_main_queue(), ^{ notice_show(w, thumb, @"Screenshot saved"); });
        });
    });
    if (!asked) LOG("capture: a screenshot is still being saved, or the Captures folder cannot be made");
}

static int g_follow = -1;   // DM_CAPTURE_SYSTEM: -1 not read yet
void dm_capture_follow_set(bool on) { g_follow = on; LOG("capture: iOS screenshots %s", on ? "also saved to Captures" : "go to Photos only"); }
void dm_capture_follow_system(UIView *over) {
    static id token;
    if (token) return;
    if (g_follow < 0) { const char *e = getenv("DM_CAPTURE_SYSTEM"); g_follow = !e || atoi(e) != 0; }
    __weak UIView *weak = over;
    token = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; UIView *v = weak;
        if (g_follow <= 0 || !v) return;
        LOG("capture: iOS took a screenshot: saving the game's picture to Captures too");
        dm_capture_screenshot(v);
    }];
    if (!g_follow) LOG("capture: iOS screenshots go to Photos only (DM_CAPTURE_SYSTEM=0)");
}
