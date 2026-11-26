// See DmCapture.h.
#import "DmCapture.h"
#if __has_include(<ScreenCaptureKit/ScreenCaptureKit.h>)   // the device SDK; the Simulator's has none (the Duo harness: recording reports it is not available)
@import ScreenCaptureKit;
@import AVFoundation;
#define DM_HAVE_SCK 1
#endif
#include "front_capture.h"
#include "ui_font.h"
#include "save_sync.h"   // dm_save_title: the title ID the NX 18 folder files this game's saves, and captures, under
#import "CloudSaves.h"   // the NX 18 folder and this game's captures choice

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

// With This game's captures on NX 18 folder (the NX 18 card): the file moves from Documents/Captures to <NX 18 folder>/<title ID>/Captures, through a file coordinator as iCloud
// Drive asks, and NX 18 Beam finds it there on the Mac. Copied first, removed here only once the copy is whole: a folder that cannot be reached keeps it in Documents/Captures.
// Background queue; dir: the NX 18 folder (resolved on the main thread, which holds its scope). YES when it moved
static BOOL capture_to_folder(NSString *path, NSString *dir) {
    const char *t = dm_save_title(); NSString *tid = (t && *t ? @(t) : @"game").uppercaseString;   // as the saves are laid out (save_sync.c cloud_path)
    NSURL *dst = [[[NSURL fileURLWithPath:dir isDirectory:YES] URLByAppendingPathComponent:tid isDirectory:YES] URLByAppendingPathComponent:@"Captures" isDirectory:YES];
    dst = [dst URLByAppendingPathComponent:path.lastPathComponent];
    __block BOOL ok = NO; NSError *err = nil;
    [[[NSFileCoordinator alloc] initWithFilePresenter:nil] coordinateWritingItemAtURL:dst options:NSFileCoordinatorWritingForReplacing error:&err byAccessor:^(NSURL *to) {
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm createDirectoryAtURL:to.URLByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
        ok = [fm copyItemAtURL:[NSURL fileURLWithPath:path] toURL:to error:nil];
    }];
    if (ok) [NSFileManager.defaultManager removeItemAtPath:path error:nil];
    LOG("capture: %s", ok ? "moved to the NX 18 folder" : "the NX 18 folder could not be written: kept in Documents/Captures");
    return ok;
}

void dm_capture_screenshot(UIView *over) {
    __weak UIView *weak = over;
    BOOL asked = front_capture_screenshot(^(NSString *path, BOOL ok) {
        UIWindow *w = weak.window;
        if (!ok) { notice_show(w, nil, @"Couldn't save the screenshot"); return; }
        NSString *folder = dm_nx18_captures_shared() ? dm_nx18_folder_path(NULL) : nil;   // main thread: resolving it holds the folder's scope
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{   // a small picture for the notice, off the main thread
            UIImage *thumb = [[UIImage imageWithContentsOfFile:path] imageByPreparingThumbnailOfSize:CGSizeMake(104, 60)];
            NSString *text = @"Screenshot saved";
            if (folder) text = capture_to_folder(path, folder) ? @"Screenshot saved to the NX 18 folder" : @"Screenshot saved here: the NX 18 folder can't be reached";
            dispatch_async(dispatch_get_main_queue(), ^{ notice_show(w, thumb, text); });
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
        static CFTimeInterval last;   // iOS posts the notice twice for one screenshot (the owner's log, Bananza): the second, within a second, is the same one
        CFTimeInterval now = CACurrentMediaTime(); if (now - last < 1.0) return; last = now;
        LOG("capture: iOS took a screenshot: saving the game's picture to Captures too");
        dm_capture_screenshot(v);
    }];
    if (!g_follow) LOG("capture: iOS screenshots go to Photos only (DM_CAPTURE_SYSTEM=0)");
}

// ---- Recording (DmCapture.h) ----
// ScreenCaptureKit, iOS 27's screen recording (ReplayKit is deprecated there): the system's picker asks the player to confirm, its filter is this app's window, and an
// SCRecordingOutput writes the stream (HEVC in a .mov, the app's sound, no microphone) to Captures/<date>.part.mov, renamed when it finishes. Main thread, apart from the
// framework's callbacks, which hop to it
#if DM_HAVE_SCK
@interface DmRecorder : NSObject <SCContentSharingPickerObserver, SCStreamDelegate, SCRecordingOutputDelegate>
@property (nonatomic, strong) SCStream *stream;
@property (nonatomic, strong) SCRecordingOutput *output;
@property (nonatomic, copy) NSString *part;
@property (nonatomic, weak) UIView *over;
@property (nonatomic) int tries;   // picker styles tried after the first (contentSharingPickerStartDidFailWithError)
@end
static DmRecorder *g_rec;
static BOOL g_rec_on, g_rec_busy; static CFTimeInterval g_rec_t0;

bool dm_capture_recording(void) { return g_rec_on; }
int dm_capture_recording_seconds(void) { return g_rec_on ? (int)(CACurrentMediaTime() - g_rec_t0) : 0; }

static void rec_finish(BOOL ok) {   // the file is complete (ok) or the recording failed: rename, file it where This game's captures says, and tell the player
    DmRecorder *r = g_rec; NSString *part = r.part; UIView *over = r.over;
    g_rec_on = NO; g_rec_busy = NO; g_rec = nil;
    [SCContentSharingPicker.sharedPicker removeObserver:r]; SCContentSharingPicker.sharedPicker.active = NO;
    if (!part) return;
    NSString *path = [part substringToIndex:part.length - @".part.mov".length];
    if (ok) ok = rename(part.fileSystemRepresentation, path.fileSystemRepresentation) == 0;
    if (!ok) unlink(part.fileSystemRepresentation);
    LOG("capture: recording %s", ok ? "saved" : "failed");
    if (!ok) { notice_show(over.window, nil, @"Couldn't save the recording"); return; }
    NSString *folder = dm_nx18_captures_shared() ? dm_nx18_folder_path(NULL) : nil;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSString *text = folder ? (capture_to_folder(path, folder) ? @"Recording saved to the NX 18 folder" : @"Recording saved here: the NX 18 folder can't be reached") : @"Recording saved";
        dispatch_async(dispatch_get_main_queue(), ^{ notice_show(over.window, nil, text); });
    });
}

@implementation DmRecorder
- (void)contentSharingPicker:(SCContentSharingPicker *)picker didCancelForStream:(SCStream *)stream {
    (void)picker; (void)stream;
    dispatch_async(dispatch_get_main_queue(), ^{ LOG("capture: recording cancelled in the picker"); self.part = nil; rec_finish(NO); });
}
- (void)contentSharingPickerStartDidFailWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        LOG("capture: the recording picker did not open (%s, %s %ld)", error.localizedDescription.UTF8String, error.domain.UTF8String, (long)error.code);
        if (self.tries < 2) {   // iOS 27.3 refuses some picker styles as "not supported on this platform" (the owner's iPhone, NieR: the window style): try the next one
            self.tries++;
            SCContentSharingPicker *p = SCContentSharingPicker.sharedPicker;
            if (self.tries == 1) { LOG("capture: trying the picker with the display style"); [p presentPickerUsingContentStyle:SCShareableContentStyleDisplay]; }
            else { LOG("capture: trying the picker with no style"); [p present]; }
            return;
        }
        UIView *v = self.over; self.part = nil; rec_finish(NO); notice_show(v.window, nil, @"Recording isn't available now");
    });
}
- (void)contentSharingPicker:(SCContentSharingPicker *)picker didUpdateWithFilter:(SCContentFilter *)filter forStream:(SCStream *)stream {
    (void)picker;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (stream || self.stream) return;   // a change to a running stream: nothing to do
        // The picture at its own shape, fitted in 1920 x 1080 (about 75 MB a minute at the encoder's rate): the captured size is the content's, in pixels
        CGSize px = CGSizeMake(filter.contentRect.size.width * filter.pointPixelScale, filter.contentRect.size.height * filter.pointPixelScale);
        double k = px.width > 0 && px.height > 0 ? MIN(1.0, MIN(1920.0 / MAX(px.width, px.height), 1080.0 / MIN(px.width, px.height))) : 1.0;
        SCStreamConfiguration *c = [SCStreamConfiguration new];
        if (px.width > 0 && px.height > 0) { c.width = (size_t)(px.width * k) & ~(size_t)1; c.height = (size_t)(px.height * k) & ~(size_t)1; }
        c.capturesAudio = YES; c.excludesCurrentProcessAudio = NO;   // the game's own sound
        SCRecordingOutputConfiguration *oc = [SCRecordingOutputConfiguration new];
        oc.outputURL = [NSURL fileURLWithPath:self.part];
        oc.outputFileType = [oc.availableOutputFileTypes containsObject:AVFileTypeQuickTimeMovie] ? AVFileTypeQuickTimeMovie : oc.availableOutputFileTypes.firstObject;
        if ([oc.availableVideoCodecTypes containsObject:AVVideoCodecTypeHEVC]) oc.videoCodecType = AVVideoCodecTypeHEVC;
        self.stream = [[SCStream alloc] initWithFilter:filter configuration:c delegate:self];
        self.output = [[SCRecordingOutput alloc] initWithConfiguration:oc delegate:self];
        NSError *err = nil;
        if (![self.stream addRecordingOutput:self.output error:&err]) { LOG("[RED] capture: the recording output was refused (%s)", err.localizedDescription.UTF8String); self.part = nil; rec_finish(NO); return; }
        LOG("capture: recording %.0fx%.0f as %zux%zu %s", px.width, px.height, c.width, c.height, oc.videoCodecType.UTF8String);
        [self.stream startCaptureWithCompletionHandler:^(NSError *e) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (e) { LOG("capture: recording not started (%s)", e.localizedDescription.UTF8String); UIView *v = self.over; self.part = nil; rec_finish(NO); notice_show(v.window, nil, @"Couldn't start the recording"); return; }
                g_rec_on = YES; g_rec_busy = NO; g_rec_t0 = CACurrentMediaTime();   // nothing drawn over the game, which the recording would hold: iOS shows its own indicator
                LOG("capture: recording started");
            });
        }];
    });
}
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {   // the system stopped it (the app left the screen, the player stopped it in Control Center)
    (void)stream;
    dispatch_async(dispatch_get_main_queue(), ^{ LOG("capture: the recording was stopped by the system (%s)", error.localizedDescription.UTF8String); g_rec_busy = YES; });   // the output's finish files it
}
- (void)recordingOutputDidStartRecording:(SCRecordingOutput *)o { (void)o; }
- (void)recordingOutput:(SCRecordingOutput *)o didFailWithError:(NSError *)error {
    (void)o; dispatch_async(dispatch_get_main_queue(), ^{ LOG("[RED] capture: the recording failed (%s)", error.localizedDescription.UTF8String); rec_finish(NO); });
}
- (void)recordingOutputDidFinishRecording:(SCRecordingOutput *)o { (void)o; dispatch_async(dispatch_get_main_queue(), ^{ rec_finish(YES); }); }
@end

static void rec_start(UIView *over) {
    SCContentSharingPicker *p = SCContentSharingPicker.sharedPicker;
    if (!p.isAvailable) { notice_show(over.window, nil, @"Recording isn't available now"); return; }
    NSString *path = front_capture_name(front_capture_dir(), @"mov", NSDate.date);
    if (!path) { notice_show(over.window, nil, @"Couldn't start the recording"); return; }
    g_rec = [DmRecorder new]; g_rec.over = over; g_rec.part = [path stringByAppendingString:@".part.mov"]; g_rec_busy = YES;
    SCContentSharingPickerConfiguration *pc = [SCContentSharingPickerConfiguration new];
    pc.showsMicrophoneControl = NO; pc.showsCameraControl = NO;
    p.defaultConfiguration = pc;
    [p addObserver:g_rec]; p.active = YES;
    [p presentPickerUsingContentStyle:SCShareableContentStyleWindow];   // the system asks the player to confirm recording this app
    LOG("capture: asking to record");
}

static void rec_stop(void) {
    if (!g_rec_on || !g_rec.stream) return;
    g_rec_busy = YES;
    [g_rec.stream stopCaptureWithCompletionHandler:^(NSError *e) { if (e) LOG("capture: stopping the recording: %s", e.localizedDescription.UTF8String); }];   // the output's finish files it
}

#else
static BOOL g_rec_on, g_rec_busy;
bool dm_capture_recording(void) { return g_rec_on; }
int dm_capture_recording_seconds(void) { return 0; }
static void rec_start(UIView *over) { LOG("capture: recording is not available in this build (no ScreenCaptureKit)"); notice_show(over.window, nil, @"Recording isn't available now"); }
static void rec_stop(void) {}
#endif

void dm_capture_record_toggle(UIView *over) {
    if (g_rec_busy) return;
    if (g_rec_on) rec_stop(); else rec_start(over);
}

// The Capture button: held half a second toggles the recording at that moment; let go sooner, a screenshot
void dm_capture_button(UIView *over, bool down) {
    static CFTimeInterval at; static BOOL held_fired; static NSUInteger press;
    if (down) {
        at = CACurrentMediaTime(); held_fired = NO; NSUInteger mine = ++press;
        __weak UIView *weak = over;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (press != mine || at == 0) return;
            held_fired = YES; UIView *v = weak; if (v) dm_capture_record_toggle(v);
        });
        return;
    }
    if (at == 0) return;
    BOOL was_held = held_fired; at = 0;
    if (!was_held) dm_capture_screenshot(over);
}
