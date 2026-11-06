// iOS front end (the iOS implementation of front.h): a Metal view of the picture's shape (16:9, or what the game presents: front_picture_shape) + a full-screen virtual gamepad layer (DmGamepad.m). Where they go is DmLayout.h's: in landscape the picture
// is centered (black bars; Picture Fill: cropped to cover the screen; Picture Stretch: the whole screen, stretched) and the controls are drawn over it; in portrait, or on an iPhone Duo half folded, the picture sits above the controls. With a TV connected the Metal view
// is on the TV and the phone shows the pad (DmTVSceneDelegate).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#import <BackgroundTasks/BackgroundTasks.h>
#include <errno.h>
#include <stdatomic.h>
#include <malloc/malloc.h>
#include <os/proc.h>
#include <mach/mach.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "haptics_apple.h"
#include "save_sync.h"
#import "CloudSaves.h"

void dm_gamepad_active(void);
void dm_gamepad_hint(void);   // DmGamepad.m: the menu button shows for 5 s (main thread)
#import "DmLayout.h"
#import "DmGameMenu.h"

void front_ios_boot(void);
int front_ios_boot_ok(void);
const char *front_ios_boot_message(void);   // main.m: why a build that keeps the game files off the IPA found none usable (NULL = the generic hint)
const char *front_ios_device_check(void);   // main.m: why this device cannot run the games (its GPU has no BC textures; NULL = supported); makes the first Metal device
bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0)

static CAMetalLayer *g_layer;
static void front_ios_notify_setup(void);
static void front_ios_notify_ask(void);
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);
static void prep_progress(NSString *phase, long done, long total);   // the prepare step in the background (DM_BG_PREPARE), main queue
static void prep_end(const char *why);

@interface DmGameView : UIView
@property (nonatomic) CGFloat maxPixelWidth;   // 0: the screen's own pixels; a TV caps the drawable at 1920 across (tv_attach)
@end
@implementation DmGameView
+ (Class)layerClass { return CAMetalLayer.class; }
- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        [self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
            [(UIView *)environment setNeedsLayout];
        }];
        CAMetalLayer *l = (CAMetalLayer *)self.layer;
        l.device = MTLCreateSystemDefaultDevice(); l.pixelFormat = MTLPixelFormatBGRA8Unorm;
        l.contentsScale = MAX(self.traitCollection.displayScale, 1); l.opaque = YES;
        // A drawable is only ever the present pass's colour attachment (nvn_mtl.m present_encode_m4): screenshots, the window grab and DM_NVN_REGLUM read the game's picture or
        // an offscreen texture. So the drawables are render targets only (framebufferOnly, the default, as on the Mac), which lets Core Animation and Metal keep them in the form
        // best for display (lossless compression). DM_DRAWABLE_SHADER_ACCESS=1 makes them readable and writable by shaders again, as before (framebufferOnly NO)
        const char *sa = getenv("DM_DRAWABLE_SHADER_ACCESS"); BOOL shaderAccess = sa && atoi(sa);
        l.framebufferOnly = !shaderAccess;
        if (shaderAccess) LOG("front end: the drawables allow shader access (DM_DRAWABLE_SHADER_ACCESS=1)");
        l.name = @"game";   // MetricKit's frame-rate metric (MetalFrameRateMetric, iOS 27) names each CAMetalLayer by this: Documents/metrics reports the game's frame rate as layer "game" (DmMetrics.m); one layer, on the phone or the TV
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)didMoveToWindow { [super didMoveToWindow]; [self setNeedsLayout]; }   // the phone's screen or a TV's (DmTVSceneDelegate)
- (void)layoutSubviews {   // render at the pixels of the screen the view is on (an iPad window can move to another), at most maxPixelWidth across
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    UIScreen *screen = self.window.windowScene.screen;
    CGFloat scale = screen ? screen.nativeScale : MAX(self.traitCollection.displayScale, 1);
    if (self.maxPixelWidth > 0) scale = MIN(scale, self.maxPixelWidth / MAX(self.bounds.size.width, 1));
    l.contentsScale = scale;
    l.drawableSize = CGSizeMake(self.bounds.size.width * l.contentsScale, self.bounds.size.height * l.contentsScale);
}
@end
static void tv_attach(void);

@interface DmRootView : UIView
@end
@implementation DmRootView
+ (BOOL)requiresConstraintBasedLayout { return YES; }
- (void)updateConstraints {
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if (@available(iOS 27.1, *)) {
        // Reading here registers UIKit's automatic reserved-region invalidation.
        [self reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive];
        [self setNeedsLayout];
    }
#endif
    [super updateConstraints];
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UILabel *fps;
@property (nonatomic) BOOL launched;
@property (nonatomic, strong) id tv;   // the TV scene accessory's registration (iOS 27)
@property (nonatomic) DmPictureMode picture;   // DM_PICTURE_FIT: fit, fill (in landscape the picture covers the screen, its edges cropped) or stretch (it covers the screen, stretched to its shape) (DmLayout.h dm_layout_picture)
@property (nonatomic) BOOL ultrawideStretch;   // Ultrawide holds the picture at Stretch (startGame): the in-game menu has no Picture row then (dm_setting_live)
@property (nonatomic) BOOL partiallyOpen;   // an iPhone Duo's hinge half open (UIHingeInteraction, iOS 27.1)
@property (nonatomic) NSInteger hingeStatus;
@property (nonatomic, copy) NSString *layoutLog;   // the last layout line logged
#if __has_include(<UIKit/UIHingeInteraction.h>)
- (void)hingeChanged:(UIHinge *)hinge API_AVAILABLE(ios(27.1));
#endif
- (void)startGame;
- (void)showFPS:(BOOL)on;
@end
static DmRootVC *g_root;
static CGFloat g_picture_aspect = DM_PICTURE_16_9;   // the presented picture's width / height (front_picture_shape); main thread
static BOOL g_pictured;   // the game's first picture was reported (front_picture_shape); main thread
static void launcher_done(void) { [g_root startGame]; }
void mtl_present_stretch(int on);   // nvn_mtl.m: the present draws the picture over the whole drawable instead of keeping its shape (Picture Stretch)
static const char *picture_name(DmPictureMode m) { return m == DmPictureFill ? "Fill" : m == DmPictureStretch ? "Stretch" : "Fit"; }
@implementation DmRootVC
- (void)loadView { self.view = [DmRootView new]; }
- (void)showHint:(NSString *)text {   // why the game cannot start, centered over the black screen
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
    lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
    lb.text = text; [self.view addSubview:lb];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if (@available(iOS 27.1, *)) {
        __weak DmRootVC *weakSelf = self;
        [self.view addInteraction:[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
            [weakSelf hingeChanged:update.hinge];
        }]];
    }
#endif
    front_ios_power_watch();
    front_ios_notify_setup();
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        const char *why = front_ios_boot_message();
        [self showHint:why ? [NSString stringWithFormat:@"Game files unusable.\n%s", why] : @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart."]; return;
    }
    front_ios_audio_watch();
#if defined(__IPHONE_27_0)   // compiled only with an SDK that has the scene accessory API
    if (@available(iOS 27.0, *)) {   // iOS 27 offers a TV scene only to a registered scene accessory, no longer from the Info.plist entry alone (that path stays for iOS 26)
        UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"TV" sessionRole:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
        c.delegateClass = NSClassFromString(@"DmTVSceneDelegate");
        self.tv = [self registerSceneAccessory:[UISceneAccessory externalNonInteractiveSceneAccessoryWithConfiguration:c]];
    }
#endif
}
#if __has_include(<UIKit/UIHingeInteraction.h>)
- (void)hingeChanged:(UIHinge *)hinge API_AVAILABLE(ios(27.1)) {
    NSInteger status = hinge ? hinge.status : UIHingeStatusUnknown;
    if (self.hingeStatus != status) {
        self.hingeStatus = status;
        LOG("front end: Duo hinge status %ld, angle %.3f", (long)status, hinge.angle);
    }
    self.partiallyOpen = status == UIHingeStatusPartiallyOpen;
    [self.view setNeedsUpdateConstraints];
    [self.view setNeedsLayout];
}
#endif
// The game view, the pad and the frame-rate counter are made once the launcher has set the switches they read (DM_SHOW_FPS, DM_METAL_HUD); the host's loading began at app launch (main.m)
- (void)startGame {
    if (self.game) return;
    dm_cloud_saves_env();   // DM_SAVE_SYNC from the launcher's Cloud saves pick, before the game's first save mount reads it (CloudSaves.m, save_sync.h)
    front_hud_env();   // before the process's first Metal device, which reads MTL_HUD_ENABLED (an env file's DM_METAL_HUD sets it in main.m already; GitHub issue #840)
    const char *dev = front_ios_device_check();   // that first device: a GPU without BC textures is refused here, not at launch, so the launcher's HUD switch counts
    if (dev) { [self showHint:[NSString stringWithFormat:@"This device is not supported.\n%s", dev]]; return; }   // the host does not start
    self.picture = dm_picture_mode(getenv("DM_PICTURE_FIT"));
    if (self.picture == DmPictureFill) LOG("front end: picture Fill (DM_PICTURE_FIT=fill), the 16:9 picture covers the screen in landscape and its edges are cropped");
    if (self.picture == DmPictureStretch) LOG("front end: picture Stretch (DM_PICTURE_FIT=stretch), the picture is stretched to cover the screen in landscape, nothing cropped");
    // Ultrawide (DM_MOD_ULTRAWIDE=1, a switchable mod from the NSP script's mods folder, put in place by loader.c dm_mod_variants_apply): such mods render a wider view into the game's
    // 16:9 picture and expect it stretched over a wider screen, so the picture is stretched (Picture Stretch). A screen no wider than 16:9 (an iPad's 4:3) would show it squeezed:
    // there the mod stays out, before the host reads the switch when the game starts
    const char *uw = getenv("DM_MOD_ULTRAWIDE");
    if (uw && !strcmp(uw, "1")) {
        UIScreen *scr = self.view.window.windowScene.screen; CGSize sz = (scr ?: UIScreen.mainScreen).bounds.size;   // the window's screen; the main one before the view is in a window
        CGFloat r = MAX(sz.width, sz.height) / MAX(MIN(sz.width, sz.height), 1);
        if (r < 1.85) { unsetenv("DM_MOD_ULTRAWIDE"); LOG("front end: Ultrawide left off: this screen (%.2f:1) is not wider than 16:9", r); }
        else { self.picture = DmPictureStretch; self.ultrawideStretch = YES; LOG("front end: Ultrawide: the picture is stretched over the %.2f:1 screen in landscape", r); }
    }
    self.view.clipsToBounds = YES;   // with Fill the game view is larger than the screen
    self.view.window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategorySmall;   // UIKit draws the in-game menu (GameMenu.swift) in this window: it keeps one compact text size over the game, whatever the system's text size
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
    dm_haptics_apple_init();
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    const char *fps = getenv("DM_SHOW_FPS");
    [self showFPS:fps ? atoi(fps) != 0 : [[NSBundle.mainBundle objectForInfoDictionaryKey:@"DMShowFPS"] boolValue]];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    tv_attach();   // a TV connected while the launcher showed
    front_ios_boot();
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGRect b = self.view.bounds; if (!self.game) return;
    CGRect division = CGRectNull;   // an iPhone Duo's fold, as UIKit reports it (iOS 27.1)
    NSMutableArray<NSString *> *regionLog = [NSMutableArray array];
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if (@available(iOS 27.1, *)) {
        for (UIViewReservedRegion *region in [self.view reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]) {
            [regionLog addObject:[NSString stringWithFormat:@"%@ active=%d", NSStringFromCGRect(region.frame), region.isActive]];
            CGRect candidate = dm_horizontal_division(b, region.frame);
            if (CGRectIsNull(division) && !CGRectIsNull(candidate)) division = candidate;
        }
    }
#endif
    BOOL duoPortrait = b.size.height > b.size.width && (self.hingeStatus != 0 || !CGRectIsNull(division));
    UIEdgeInsets gameInsets = dm_game_safe_insets(b, self.view.safeAreaInsets, duoPortrait);
    BOOL onTV = self.game.superview != self.view;   // the TV's view lays the picture out; the phone is all pad
    DmLayout layout = onTV ? dm_layout_pad_only(b) : dm_layout_picture(dm_layout(b, gameInsets, self.partiallyOpen, division, g_picture_aspect), b, self.picture, g_picture_aspect);
    if (!onTV) self.game.frame = layout.game;
    mtl_present_stretch(!onTV && dm_layout_stretched(layout, self.picture, g_picture_aspect));   // a TV and a split keep the picture's shape
    layout.topSafeOnly = duoPortrait;
    NSString *line = [NSString stringWithFormat:@"%@, hinge %ld%s, divisions %@, picture %@, controls %@", onTV ? @"pad only (picture on the TV)" : layout.separated ? @"split" : self.picture == DmPictureFill ? @"overlay, Fill" : self.picture == DmPictureStretch ? @"overlay, Stretch" : @"overlay",
                      (long)self.hingeStatus, self.partiallyOpen ? " (half open)" : "", regionLog, NSStringFromCGRect(layout.game), NSStringFromCGRect(layout.controls)];
    if (![line isEqualToString:self.layoutLog]) { self.layoutLog = line; LOG("front end: layout %s", line.UTF8String); }
    self.pad.frame = b;
    dm_gamepad_arrange(self.pad, layout);
    if (self.fps) {   // the top row's free stretch: right of DmGamepad.m's L3 key (102 + 17 of its units from the safe edge), level with − / + (22 units down); u is its unit
        CGRect s = CGRectIntersection(layout.controls, UIEdgeInsetsInsetRect(b, gameInsets));
        CGFloat u = layout.separated ? MIN(MIN(s.size.height / 430.0, s.size.width / 700.0), 1.3) : MIN(b.size.height / 430.0, 1.3);
        self.fps.frame = CGRectMake(floor(CGRectGetMinX(s) + 130 * u), floor(CGRectGetMinY(s) + 22 * u - 11), 64, 22);
    }
}
- (void)showFPS:(BOOL)on {   // the frame-rate counter: DM_SHOW_FPS at Play, then the in-game menu
    if (on && !self.fps) { self.fps = front_ios_fps_label(); [self.view addSubview:self.fps]; [self.view setNeedsLayout]; }   // above the pad, which hides while a controller is connected
    self.fps.hidden = !on;
}
- (void)viewDidAppear:(BOOL)a {
    [super viewDidAppear:a];
    if (!front_ios_boot_ok() && front_ios_boot_message() && !self.presentedViewController) {   // a slim build whose game file image is missing or another version (main.m)
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Game files" message:@(front_ios_boot_message()) preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
    }
    if (self.launched || !front_ios_boot_ok()) return;
    self.launched = YES; g_root = self;
    if (!dm_show_launcher((__bridge void *)self, launcher_done)) [self startGame];   // the settings screen first (Launcher.swift), when the app has one
    front_ios_notify_ask();
}
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeAll; }   // Edge gestures need two swipes, to avoid accidental exits
- (BOOL)prefersStatusBarHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
@end
UIViewController *front_ios_root(void) { return [DmRootVC new]; }

// A TV (cable or AirPlay): iOS gives the app the TV as a scene of its own instead of mirroring the phone. The game's view moves there, 16:9 fills the TV, and the game is
// docked as a Switch on its dock (1080p, the operation mode change notification); the phone keeps the pad. Unplugging puts the view back and the mode the game had before
@interface DmTVVC : UIViewController
@end
@implementation DmTVVC
- (void)viewDidLoad { [super viewDidLoad]; self.view.backgroundColor = UIColor.blackColor; }
- (void)viewDidLayoutSubviews { [super viewDidLayoutSubviews]; for (UIView *v in self.view.subviews) v.frame = dm_aspect_fit(self.view.bounds, g_picture_aspect); }
@end
static UIWindow *g_tv; static int g_tv_mode_was = -1;
static void tv_attach(void) {
    DmGameView *v = g_root.game; if (!g_tv || !v || v.superview == g_tv.rootViewController.view) return;
    // at most 1080p: the game renders 1080p docked, and a 4K drawable only adds an upscale and a 4K stream (an AirPlay TV showed black, the GPU went from 15 to 60 ms a frame).
    // Taken from the picture, not the screen, so a display of another shape still gets the full 1920 pixels across the picture (DmGameView layoutSubviews applies it)
    v.maxPixelWidth = 1920;
    [g_tv.rootViewController.view addSubview:v]; [g_tv.rootViewController.view setNeedsLayout]; [g_root.view setNeedsLayout];   // the phone's pad takes the whole screen
    CGRect f = dm_aspect_fit(g_tv.bounds, g_picture_aspect); CGFloat scale = MIN(g_tv.windowScene.screen.nativeScale, 1920.0 / MAX(f.size.width, 1));
    if (g_tv_mode_was < 0) g_tv_mode_was = dm_opmode();
    dm_set_opmode(1); dm_gamepad_opmode_changed();
    LOG("front end: TV connected (%.0fx%.0f points), the picture moves there at %.0fx%.0f, console mode", g_tv.bounds.size.width, g_tv.bounds.size.height, f.size.width * scale, f.size.height * scale);
}
static void tv_detach(void) {
    DmGameView *v = g_root.game; g_tv = nil; v.maxPixelWidth = 0;
    if (v && v.superview != g_root.view) { [g_root.view insertSubview:v atIndex:0]; [g_root.view setNeedsLayout]; }
    if (g_tv_mode_was >= 0) { dm_set_opmode(g_tv_mode_was); g_tv_mode_was = -1; dm_gamepad_opmode_changed(); }
    LOG("front end: TV disconnected, the picture is back on the phone");
}
void front_picture_shape(int w, int h) {   // front.h: the views take the presented picture's shape (a taller one under DM_SCREEN_ASPECT) instead of 16:9
    if (w <= 0 || h <= 0) return;
    CGFloat a = (CGFloat)w / h;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_pictured) { g_pictured = YES; dm_gamepad_hint(); prep_end("the game showed its first picture"); }   // the first present reports the first shape: the menu button's 5 s at the start count from the game's first picture
        if (a == g_picture_aspect) return;
        g_picture_aspect = a; LOG("front end: picture shape %dx%d, the game's view follows it", w, h);
        [g_root.view setNeedsLayout]; if (g_tv) [g_tv.rootViewController.view setNeedsLayout];
    });
}

// The settings the in-game menu offers (GameMenu.swift, from the gamepad's menu button), each taking effect while the game runs; the launcher's other settings need the next start.
// value NULL: only whether env is one of them; otherwise apply it (GameMenu.swift has saved it and put it in the environment). Console mode changes as on a Switch put in or taken out of its
// dock (the operation mode change notification); while a TV shows the picture the game stays docked, and the choice applies when the TV is unplugged
bool dm_setting_live(const char *env, const char *value) {
    if (!env || !g_root.game) return false;
    if (!strcmp(env, "DM_PICTURE_FIT")) {
        if (g_root.ultrawideStretch) return false;   // Ultrawide holds Stretch: the row would tick the saved choice, and a pick would squeeze or crop the mod's wider view until the next start
        if (value) { g_root.picture = dm_picture_mode(value); [g_root.view setNeedsLayout]; LOG("front end: picture %s (in-game menu)", picture_name(g_root.picture)); }
        return true;
    }
    if (!strcmp(env, "DM_OPMODE")) {
        if (!value) return true;
        int m = atoi(value) ? 1 : 0;
        if (g_tv_mode_was >= 0) { g_tv_mode_was = m; LOG("front end: console mode %s once the TV is unplugged (in-game menu)", m ? "docked" : "handheld"); return true; }
        dm_set_opmode(m); dm_gamepad_opmode_changed(); LOG("front end: console mode %s (in-game menu)", m ? "docked" : "handheld");
        return true;
    }
    if (!strcmp(env, "DM_SHOW_FPS")) { if (value) [g_root showFPS:atoi(value) != 0]; return true; }
    if (!strcmp(env, "DM_TOUCH_HAPTICS")) { if (value) dm_gamepad_touch_feedback(atoi(value) != 0); return true; }
    if (!strcmp(env, "DM_RUMBLE")) { if (value) { dm_haptics_set_enabled(atoi(value) != 0); LOG("front end: game rumble %s (in-game menu)", atoi(value) ? "on" : "off"); } return true; }
    return false;
}
@interface DmTVSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (strong, nonatomic) UIWindow *window;
@end
@implementation DmTVSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)o {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [DmTVVC new];
    self.window.hidden = NO;   // without a window iOS goes on mirroring the phone; not key, so the phone's window keeps the keyboard
    g_tv = self.window; tv_attach();
}
- (void)sceneDidDisconnect:(UIScene *)s { if (g_tv == self.window) tv_detach(); self.window = nil; }
@end

// Thermal state and screen brightness for the power and present rows every 300 frames (hle_nvn.c; its weak defaults return -1 on the Mac). thermalState: 0 nominal, 1 fair, 2 serious, 3 critical.
// Brightness is read on the main thread at start and on each change; every change of the thermal state and of Low Power Mode (which lowers the CPU clock) is logged with the time since launch
static _Atomic double g_brightness = -1;
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }   // the frame step does not probe in it (hle_nvn.c fstep_cpu_slowed)
double dm_brightness_now(void) { return g_brightness; }
// iOS's memory warning, the last notice before the system ends the app for memory (which leaves no line in the log): the footprint and what is left are logged, so log.txt shows
// how close a run came, and the allocators hand their free pages back to the system (malloc_zone_pressure_relief). Nothing the game holds is freed, so no game state changes
static void front_ios_memory_warning(void) {
    task_vm_info_data_t vi; mach_msg_type_number_t vc = TASK_VM_INFO_COUNT;
    double fp = task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&vi, &vc) == KERN_SUCCESS ? vi.phys_footprint / 1048576.0 : -1;
    size_t freed = malloc_zone_pressure_relief(NULL, 0);
    LOG("[RED] front end: iOS memory warning (%.0f s after launch): footprint %.0f MiB, %llu MiB left before the limit; %.1f MiB of free allocator pages handed back", (now_ns() - g_t0_ns) / 1e9, fp,
        (unsigned long long)(os_proc_available_memory() >> 20), freed / 1048576.0);
}
static void front_ios_power_watch(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil usingBlock:^(NSNotification *n) { (void)n; front_ios_memory_warning(); }];
    g_brightness = UIScreen.mainScreen.brightness;
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; g_brightness = UIScreen.mainScreen.brightness; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9); }];
    LOG("front end: thermal state %d, brightness %.2f, Low Power Mode %s", dm_thermal_now(), g_brightness, dm_low_power_now() ? "on" : "off");
}

// Frame-rate counter: the frames put on screen in the last second (nvn_mtl.m counts them for NVN and for the Vulkan layer alike; frames the display link merged away are not counted).
// On when the IPA was built with it (the NSP script's SHOW_FPS / --show-fps → DMShowFPS in Info.plist); DM_SHOW_FPS=0 / 1 (the launcher, Documents/env.txt) overrides that without a rebuild,
// and the in-game menu turns it on and off ([DmRootVC showFPS:])
uint64_t mtl_present_count(void);
static UILabel *front_ios_fps_label(void) {
    UILabel *l = [UILabel new];
    l.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold]; l.textColor = UIColor.whiteColor; l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45]; l.layer.cornerRadius = 6; l.layer.masksToBounds = YES; l.userInteractionEnabled = NO;
    l.text = @"-- fps";
    __block uint64_t n0 = mtl_present_count(); __block double t0 = CACurrentMediaTime();
    [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *t) {
        (void)t; uint64_t n = mtl_present_count(); double now = CACurrentMediaTime();
        if (now - t0 < 1.5) l.text = [NSString stringWithFormat:@"%.0f fps", (n - n0) / (now - t0)];   // a longer span is the time in the background: no reading
        n0 = n; t0 = now;
    }];
    LOG("front end: frame-rate counter on");
    return l;
}

// The prepare step in the background (DM_BG_PREPARE=1; off by default until it is measured on the devices). Today leaving the app during "Preparing shaders" or "Preparing pipelines" stops
// the step: iOS suspends the whole process within seconds. With the switch on, the step asks iOS for a continued processing task (BackgroundTasks, iOS 26 and later) once its screen shows
// while the player is in the app; iOS then keeps the process running when the player leaves, shows the step's count (front_progress) in a Live Activity and lets the player cancel it there.
// Nothing else changes: leaving the app still freezes the guest clock, hands the sound to the silent sink and closes the graphics gate (front_ios_focus_event), and the step itself submits no
// GPU work (hle_nvn.c runs it outside the gate: it loads shaders and makes pipelines), so the game's first submission waits at the closed gate and no command buffer is committed in the
// background. The task asks for no GPU, so it needs no entitlement (a free development team signs the app) and no background mode, only Info.plist's BGTaskSchedulerPermittedIdentifiers
// (project.yml: <bundle ID>.prepare.*, the wildcard form iOS asks this task for; the app registers and submits <bundle ID>.prepare.pipelines). It ends when the step ends (front_prepare_end,
// nvn_mtl.m) or the game shows its first picture; when it expires (the player's cancel, or iOS) it is completed at once, and the step pauses when iOS suspends the app, as without it.
// One task per process, submitted with the fail strategy (a queued task would start when the step is over or the app suspended). Off by default because the process then runs in the
// background for as long as the step lasts, where iOS used to suspend it within seconds: guest threads that neither read the clock nor submit (an audio thread the silent sink paces) keep
// running all that time, and whether Metal's compiler serves a background app at a useful rate is not measured yet
static NSString *g_prep_id, *g_prep_title, *g_prep_phase;   // the registered task identifier (nil: off), the Live Activity's title (the game's name), the step's screen title last reported; main queue
static BGContinuedProcessingTask *g_prep_task;   // the running task; main queue
static int g_prep_state;   // 0 not asked for yet, 1 submitted, 2 running, 3 over (asked for at most once per process); main queue
static BOOL g_prep_over;   // the step has ended (front_prepare_end) or the game has presented; main queue
static _Atomic int g_prep_completed;   // setTaskCompletedWithSuccess: was called: the expiration handler may run on another queue
static double g_prep_t0, g_prep_note_t, g_prep_away_t;   // when the task was asked for; when its subtitle last changed; when the step was first seen going on with the app in the background (0: it is not)
static long g_prep_done, g_prep_total, g_prep_away_from, g_prep_away_now, g_prep_away_units;   // the count last reported; the count this absence is measured from; what this absence did on an earlier screen; done in the background, all absences
static void prep_complete(BGTask *t, BOOL ok) { if (t && !atomic_exchange(&g_prep_completed, 1)) [t setTaskCompletedWithSuccess:ok]; }
static void prep_away_end(double now, const char *why) {   // the player came back, or the step ended in the background: the log says what the time away did
    long units = g_prep_away_now + g_prep_done - g_prep_away_from; g_prep_away_units += units;
    LOG("front end: preparing in the background: %s after %.0f s away; %ld shaders or pipelines done meanwhile (%.1f a second), now at %s %ld of %ld", why, now - g_prep_away_t, units,
        units / MAX(now - g_prep_away_t, 0.001), g_prep_phase.UTF8String, g_prep_done, g_prep_total);
    g_prep_away_t = 0; g_prep_away_now = 0;
}
static void prep_launch(BGTask *task) {   // main queue (registered so): iOS starts the task it took
    if (![task isKindOfClass:BGContinuedProcessingTask.class] || g_prep_state != 1 || g_prep_over) {   // the step ended before iOS started it: done at once
        LOG("front end: preparing in the background: iOS started the task after the step %s; it ends at once", g_prep_over ? "ended" : "gave it up");
        if (g_prep_state == 1) g_prep_state = 3;
        prep_complete(task, g_prep_over); return;
    }
    BGContinuedProcessingTask *t = (BGContinuedProcessingTask *)task; __weak BGContinuedProcessingTask *wt = t;
    t.expirationHandler = ^{   // the player cancelled it in the Live Activity, or iOS ended it: completed at once, wherever iOS calls this; the step then pauses when iOS suspends the app, as without the task
        prep_complete(wt, NO);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (g_prep_state != 2) return;
            g_prep_state = 3; g_prep_task = nil;
            if (g_prep_away_t) prep_away_end(CACurrentMediaTime(), "the task expired");
            LOG("front end: preparing in the background: the task expired (cancelled in the Live Activity or ended by iOS) at %s %ld of %ld; the step pauses while iOS suspends the app and goes on when the player comes back",
                g_prep_phase.UTF8String, g_prep_done, g_prep_total);
        });
    };
    g_prep_task = t; g_prep_state = 2;
    t.progress.totalUnitCount = MAX(g_prep_total, 1); t.progress.completedUnitCount = MIN(g_prep_done, MAX(g_prep_total, 1));
    LOG("front end: preparing in the background: iOS started the task %.1f s after it was asked for (%s %ld of %ld): the step goes on if the player leaves the app",
        CACurrentMediaTime() - g_prep_t0, g_prep_phase.UTF8String, g_prep_done, g_prep_total);
}
// main.m, from application:didFinishLaunchingWithOptions: (BackgroundTasks wants launch handlers registered before launch ends, each identifier once: a second registration ends the app)
void front_ios_bg_prepare_register(void) {
    const char *e = getenv("DM_BG_PREPARE");
    if (!e || strcmp(e, "1")) return;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *bid = NSBundle.mainBundle.bundleIdentifier, *wild = bid ? [bid stringByAppendingString:@".prepare.*"] : nil;
        NSArray *permitted = [NSBundle.mainBundle objectForInfoDictionaryKey:@"BGTaskSchedulerPermittedIdentifiers"];
        if (!NSClassFromString(@"BGContinuedProcessingTaskRequest")) { LOG("front end: DM_BG_PREPARE=1, but this system has no continued processing task (iOS 26 and later): the prepare step pauses in the background"); return; }
        if (!wild || ![permitted isKindOfClass:NSArray.class] || ![permitted containsObject:wild]) {   // an install tool that changes the bundle ID leaves the Info.plist entry with the old one
            LOG("[RED] front end: DM_BG_PREPARE=1, but Info.plist's BGTaskSchedulerPermittedIdentifiers does not hold %s: the prepare step pauses in the background", wild ? wild.UTF8String : "<bundle ID>.prepare.*");
            return;
        }
        NSString *ident = [bid stringByAppendingString:@".prepare.pipelines"]; BOOL ok = NO;
        @try { ok = [BGTaskScheduler.sharedScheduler registerForTaskWithIdentifier:ident usingQueue:dispatch_get_main_queue() launchHandler:^(BGTask *t) { prep_launch(t); }]; }
        @catch (NSException *x) { LOG("[RED] front end: the prepare step's background task could not be registered: %s", x.reason.UTF8String); }
        if (!ok) { LOG("[RED] front end: the prepare step's background task %s was not registered: the prepare step pauses in the background", ident.UTF8String); return; }
        id name = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleDisplayName"] ?: [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleName"];
        g_prep_title = [name isKindOfClass:NSString.class] && [name length] ? name : @"Game";
        g_prep_id = ident;
        LOG("front end: DM_BG_PREPARE=1: the prepare step may go on while the player is in another app (task %s, asked for when its screen shows)", ident.UTF8String);
    });
}
static void prep_submit(NSString *phase) {   // main queue, with the app in the foreground: iOS takes the request from the foreground app only
    g_prep_state = 1; g_prep_t0 = CACurrentMediaTime();
    BGTaskScheduler *s = BGTaskScheduler.sharedScheduler;
    if (![s respondsToSelector:@selector(submitTaskRequest:completionHandler:)]) { g_prep_state = 3; LOG("front end: preparing in the background: this system cannot submit the task (no submitTaskRequest:completionHandler:)"); return; }
    BGContinuedProcessingTaskRequest *r = [[BGContinuedProcessingTaskRequest alloc] initWithIdentifier:g_prep_id title:g_prep_title subtitle:phase];
    r.strategy = BGContinuedProcessingTaskRequestSubmissionStrategyFail;   // now or not at all; requiredResources stays the default: compiles need no GPU, and background GPU use would need an entitlement
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{   // BackgroundTasks: not from the main thread (the iOS 27 submission; it replaces the deprecated submitTaskRequest:error:)
        [s submitTaskRequest:r completionHandler:^(NSError *err) {
            if (!err) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                if (g_prep_state == 1) g_prep_state = 3;
                BOOL bg = [err.domain isEqualToString:BGTaskSchedulerErrorDomain];
                LOG("front end: preparing in the background: iOS did not take the task (%s, code %ld%s): the step pauses in the background, as without it", err.localizedDescription.UTF8String, (long)err.code,
                    bg && err.code == BGTaskSchedulerErrorCodeImmediateRunIneligible ? ": it could not start now" : bg && err.code == BGTaskSchedulerErrorCodeNotPermitted ? ": the identifier is not in Info.plist's BGTaskSchedulerPermittedIdentifiers" : "");
            });
        }];
    });
    LOG("front end: preparing in the background: task asked for at %s (fail strategy, no GPU)", phase.UTF8String);
}
// Every count front_progress reports, on the main queue: the request at the first one with the app in the foreground, then the task's progress (the system expires a task that reports none)
// and its Live Activity subtitle at most once a second, and how long the step went on with the app in the background
static void prep_progress(NSString *phase, long done, long total) {
    if (!g_prep_id || g_prep_over || g_prep_state == 3) return;
    UIApplicationState st = UIApplication.sharedApplication.applicationState;
    if (!g_prep_state) { if (st != UIApplicationStateActive) return; prep_submit(phase); }
    double now = CACurrentMediaTime(); BOOL other = ![phase isEqualToString:g_prep_phase];
    if (g_prep_away_t && other) { g_prep_away_now += g_prep_done - g_prep_away_from; g_prep_away_from = 0; }   // the second screen counts from 0
    g_prep_phase = phase; g_prep_done = done; g_prep_total = total;
    if (st == UIApplicationStateBackground && g_prep_task && !g_prep_away_t) {
        g_prep_away_t = now; g_prep_away_from = done;
        LOG("front end: preparing in the background: the player left the app at %s %ld of %ld; the step goes on", phase.UTF8String, done, total);
    } else if (st != UIApplicationStateBackground && g_prep_away_t) prep_away_end(now, "the player came back");
    BGContinuedProcessingTask *t = g_prep_task; if (!t) return;
    t.progress.totalUnitCount = MAX(total, 1); t.progress.completedUnitCount = MIN(done, MAX(total, 1));
    if ((other || now - g_prep_note_t >= 1.0) && [t respondsToSelector:@selector(updateTitle:subtitle:)]) {
        g_prep_note_t = now;
        [t updateTitle:g_prep_title subtitle:[NSString stringWithFormat:@"%@: %@ of %@", phase, [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                                              [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]]];
    }
}
static void prep_end(const char *why) {   // main queue: the step ended (front_prepare_end) or the game presented its first picture
    if (g_prep_over) return;
    g_prep_over = YES;
    if (!g_prep_id) return;
    if (g_prep_away_t) prep_away_end(CACurrentMediaTime(), why);
    BGContinuedProcessingTask *t = g_prep_task; g_prep_task = nil;
    if (g_prep_state == 2 && t) {
        t.progress.completedUnitCount = t.progress.totalUnitCount;
        prep_complete(t, YES);
        LOG("front end: preparing in the background: task completed (%s) %.1f s after it was asked for; %ld done with the app in the background", why, CACurrentMediaTime() - g_prep_t0, g_prep_away_units);
    }
    if (g_prep_state != 1) g_prep_state = 3;   // a task submitted and not started yet: its launch handler completes it
}
void front_prepare_end(void) { dispatch_async(dispatch_get_main_queue(), ^{ prep_end("the prepare step ended"); }); }   // nvn_mtl.m warm_start, on the game's submit thread, once the step is over

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's view and the pad, the title, a bar and a count, centered; UIKit views, so it draws while the game's thread waits
static UIView *g_prog; static UILabel *g_prog_count; static UIProgressView *g_prog_bar; static UILabel *g_prog_title;
void (*front_progress_hook)(const char *title, long done, long total);
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    void (*hook)(const char *, long, long) = front_progress_hook;
    if (hook) { dispatch_async(dispatch_get_main_queue(), ^{ if (tt) prep_progress(tt, done, total); hook(tt.UTF8String, done, total); if (!tt) dm_gamepad_hint(); }); return; }   // the host app draws it (front.h)
    dispatch_async(dispatch_get_main_queue(), ^{
        if (tt) prep_progress(tt, done, total);   // DM_BG_PREPARE: the background task's progress
        if (!tt) { [g_prog removeFromSuperview]; g_prog = nil; dm_gamepad_hint(); return; }   // the screen goes: the menu button it covered shows for 5 s (DmGamepad.m)
        if (!g_prog) {
            UIView *root = g_root.view; if (!root) return;
            g_prog = [[UIView alloc] initWithFrame:root.bounds]; g_prog.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            g_prog.backgroundColor = [UIColor colorWithWhite:0.06 alpha:0.94];
            UIView *box = [[UIView alloc] initWithFrame:CGRectMake(floor((root.bounds.size.width - 320) / 2), floor((root.bounds.size.height - 96) / 2), 320, 96)];
            box.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin | UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
            g_prog_title = [[UILabel alloc] initWithFrame:CGRectMake(0, 4, 320, 30)]; g_prog_title.textAlignment = NSTextAlignmentCenter; g_prog_title.textColor = UIColor.whiteColor;
            g_prog_title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
            g_prog_bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; g_prog_bar.frame = CGRectMake(20, 48, 280, 4);
            g_prog_count = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 320, 22)]; g_prog_count.textAlignment = NSTextAlignmentCenter;
            g_prog_count.textColor = [UIColor colorWithWhite:0.72 alpha:1]; g_prog_count.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightRegular];
            [box addSubview:g_prog_title]; [box addSubview:g_prog_bar]; [box addSubview:g_prog_count]; [g_prog addSubview:box];
            [root addSubview:g_prog];
        }
        g_prog_title.text = tt; g_prog_bar.progress = total > 0 ? (float)done / (float)total : 0;
        g_prog_count.text = [NSString stringWithFormat:@"%@ of %@", [NSNumberFormatter localizedStringFromNumber:@(done) numberStyle:NSNumberFormatterDecimalStyle],
                             [NSNumberFormatter localizedStringFromNumber:@(total) numberStyle:NSNumberFormatterDecimalStyle]];
    });
}
void *front_metal_layer(void) { return (__bridge void *)g_layer; }
int front_display_pixels(int *w, int *h) {   // the screen in pixels, landscape (nativeBounds is portrait); UIScreen's sizes may be read from any thread
    CGRect b = UIScreen.mainScreen.nativeBounds; int a = (int)b.size.width, c = (int)b.size.height;
    if (a <= 0 || c <= 0) return 0;
    *w = a > c ? a : c; *h = a > c ? c : a; return 1;
}
// Offline HTML pages (web_apple.m): the page's view goes over the game view and under the gamepad, which lets touches on no control through to it while the page is
// shown (DmGamepad.m hitTest); the page takes them as a click on what they land on, and the gamepad and controllers drive it as on the Switch
void front_web_attach(UIView *box) {
    UIView *v = g_root.view; box.frame = v.bounds;
    if (g_root.game) [v insertSubview:box aboveSubview:g_root.game]; else [v addSubview:box];
}
void front_web_detach(UIView *box) { (void)box; }
// An app of several programs (main.m: dm/programs.txt; DM_EXEC_OUT is set only there). iOS cannot start the app's process again, so oe::ExecuteProgram records the next program and the
// app ends (hle_oe.c); the next start runs it. To spare the player a silent quit, the app names the program on screen for 1.5 s, then schedules a local notification 1 s ahead that
// opens the app again ("Tap to start …"), then ends. Notifications are asked for at the first start of such an app; a player who refuses gets the plain quit
static int multi_program(void) { const char *e = getenv("DM_EXEC_OUT"); return e && *e; }
@interface DmNotifyDelegate : NSObject <UNUserNotificationCenterDelegate>
@end
@implementation DmNotifyDelegate
// The notification can come due before the graceful exit has ended the process: show it anyway, so it waits in the notification centre once the app is gone
- (void)userNotificationCenter:(UNUserNotificationCenter *)c willPresentNotification:(UNNotification *)n withCompletionHandler:(void (^)(UNNotificationPresentationOptions))done {
    (void)c; (void)n; done(UNNotificationPresentationOptionBanner | UNNotificationPresentationOptionList);
}
@end
static DmNotifyDelegate *g_notify_delegate;
static void front_ios_notify_setup(void) {   // at each start: the delegate, and no notification left from an earlier hand-off (the app is open now)
    if (!multi_program()) return;
    UNUserNotificationCenter *c = UNUserNotificationCenter.currentNotificationCenter;
    g_notify_delegate = [DmNotifyDelegate new]; c.delegate = g_notify_delegate;
    [c removeAllPendingNotificationRequests]; [c removeAllDeliveredNotifications];
}
static void front_ios_notify_ask(void) {   // iOS asks the player only while the choice is not made, so this shows a prompt at the first start alone
    if (!multi_program()) return;
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionSound completionHandler:^(BOOL granted, NSError *e) {
        LOG("front end: notifications %s%s%s", granted ? "allowed" : "not allowed", e ? ": " : "", e ? e.localizedDescription.UTF8String : ""); }];
}
static int notify_allowed(void) {
    __block UNAuthorizationStatus st = UNAuthorizationStatusNotDetermined; dispatch_semaphore_t got = dispatch_semaphore_create(0);
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *t) { st = t.authorizationStatus; dispatch_semaphore_signal(got); }];
    if (dispatch_semaphore_wait(got, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC))) return 0;
    return st == UNAuthorizationStatusAuthorized || st == UNAuthorizationStatusProvisional || st == UNAuthorizationStatusEphemeral;
}
void front_program_handoff(int index, const char *name) {   // front.h; on the guest thread that called oe::ExecuteProgram, before the graceful exit
    if (!multi_program() || !notify_allowed()) { LOG("front end: program %d starts at the next start of the app (notifications not allowed)", index); return; }
    NSString *nm = name && *name ? @(name) : [NSString stringWithFormat:@"program %d", index];
    dm_audio_suspend(1);   // the game is ending: no sound under the notice
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = g_root.view.window; if (!w) return;
        UIView *o = [[UIView alloc] initWithFrame:w.bounds]; o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        o.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(o.bounds, 40, 0)]; lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold]; lb.text = [NSString stringWithFormat:@"Starting %@\u2026", nm];
        [o addSubview:lb]; [w addSubview:o];
    });
    usleep(1500 * 1000);
    UNMutableNotificationContent *c = [UNMutableNotificationContent new]; c.body = [NSString stringWithFormat:@"Tap to start %@", nm];
    UNNotificationRequest *r = [UNNotificationRequest requestWithIdentifier:@"dm.program" content:c trigger:[UNTimeIntervalNotificationTrigger triggerWithTimeInterval:1.0 repeats:NO]];
    __block NSError *err = nil; dispatch_semaphore_t added = dispatch_semaphore_create(0);
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:r withCompletionHandler:^(NSError *e) { err = e; dispatch_semaphore_signal(added); }];
    if (dispatch_semaphore_wait(added, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) LOG("[RED] front end: the notification for program %d was not scheduled within 2 s", index);
    else if (err) LOG("[RED] front end: the notification for program %d could not be scheduled: %s", index, err.localizedDescription.UTF8String);
    else LOG("front end: \"Starting %s\" shown, notification for program %d scheduled", nm.UTF8String, index);
}
void front_run(void (*guest)(void)) { guest(); }   // Already on main.m's big-stack thread

// Software keyboard: show a UIAlertController on the main thread, the calling thread waits for the result
int front_text_input(const char *title, const char *sub, const char *guide, const char *initial, int max_chars, char *out, int out_cap) {
    (void)max_chars;
    if (!g_layer) return -1;
    __block int r = 0; __block NSString *text = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    NSString *t = title && *title ? @(title) : @"", *m = [NSString stringWithFormat:@"%s%s%s", sub ? sub : "", sub && *sub && guide && *guide ? "\n" : "", guide ? guide : ""];
    NSString *init = initial ? @(initial) : @"", *ph = guide ? @(guide) : @"";
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *ac = [UIAlertController alertControllerWithTitle:t message:m preferredStyle:UIAlertControllerStyleAlert];
        [ac addTextFieldWithConfigurationHandler:^(UITextField *f) { f.text = init; f.placeholder = ph; }];
        [ac addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) { (void)x; r = 1; text = ac.textFields.firstObject.text; dispatch_semaphore_signal(done); }]];
        [ac addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *x) { (void)x; dispatch_semaphore_signal(done); }]];
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        if (!vc) { dispatch_semaphore_signal(done); return; }
        [vc presentViewController:ac animated:YES completion:nil];
    });
    // The guest clock keeps running meanwhile, as on the Switch (hle_swkbd.c): a freeze here as well stopped Octopath Traveler 0's frame loop for as long as the box was up and made its sound stutter
    // (4,977 ms and 2,577 ms frames, 5,181 wakeups a second). The inline keyboard freezes around its own call (hle_swkbd.c)
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    if (!r) return 0;
    snprintf(out, out_cap, "%s", text.UTF8String ? text.UTF8String : "");
    return 1;
}

// Save write failed (most likely the phone's storage is full): show a notice on the main thread without blocking the game. hle_fs.c calls this when a save transaction is refused or a mount has to fall back to read-only;
// the iOS front end used not to implement it, so there was only a log line and the player never learned that progress was not being saved
void front_save_failed(int err) {
    LOG("front end: save data write failed errno=%d, telling the player", err);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = nil;
        for (UIScene *s in UIApplication.sharedApplication.connectedScenes) if ([s isKindOfClass:UIWindowScene.class]) for (UIWindow *w in ((UIWindowScene *)s).windows) if (w.isKeyWindow) vc = w.rootViewController;
        while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) { LOG("[RED] front end: no window for the save-failure alert errno=%d", err); return; }
        NSString *m = err == ENOSPC ? @"Storage is full, so progress was not saved. Free up space and save again."
                                    : [NSString stringWithFormat:@"Saving failed (errno %d); progress was not saved.", err];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Save failed" message:m preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}

// Audio session: the frames RemoteIO asks for in each callback follow the I/O buffer duration, about 21 ms by default on iOS (1024 frames at 48 kHz). The game keeps only 4 blocks × 5 ms = 20 ms in flight,
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports;
// the category is Playback, as a game's or media app's: the ring / silent switch does not mute it (the default SoloAmbient follows the switch, which silenced the game whenever the phone was on silent) and it still interrupts other apps' audio.
// Set once at boot and again on return to the foreground (the system may reset it after an interruption)
static int g_session_off;   // the last activation failed (another app or a call still held the session): tried again when the app becomes active
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategoryPlayback error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    if (![s setPreferredIOBufferDuration:0.005 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    LOG("audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for 5 ms)", s.sampleRate, s.IOBufferDuration * 1000);
}

// Real audio output is suspended (the silent sink paces the game) while the app is in the background or another audio session has interrupted ours (Siri, an alarm, a call).
// Without the interruption observer the AudioUnits stayed "started" while iOS no longer called them, and a game waiting for its buffers back lost its sound until restart.
// All of this runs on the main queue, like the scene callbacks
static int g_audio_bg, g_audio_intr;
static void front_ios_audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
static void front_ios_audio_watch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionInterruptionNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        NSUInteger type = [n.userInfo[AVAudioSessionInterruptionTypeKey] unsignedIntegerValue], reason = [n.userInfo[AVAudioSessionInterruptionReasonKey] unsignedIntegerValue];
        if (type == AVAudioSessionInterruptionTypeBegan) { LOG("audio session: interrupted (reason %lu)", (unsigned long)reason); g_audio_intr = 1; }
        else {
            LOG("audio session: interruption ended"); g_audio_intr = 0;
            if (!g_audio_bg) front_ios_audio_session();
        }
        front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionMediaServicesWereResetNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; LOG("audio session: the media services were reset; setting the session and the outputs up again");
        front_ios_audio_session(); dm_audio_reset();
    }];
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed).
// The screen stays on while the game is active: only touches reset the idle timer, so with a controller (or during a cutscene) the screen dimmed and locked mid-game
// Cloud saves (save_sync.h): what the game committed goes out before iOS suspends the app, without the sender's quiet wait. iOS gives a background task about half a minute
static void save_sync_background(void) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^end)(void) = ^{ if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; } };   // on the main queue, as the expiry handler runs
    task = [app beginBackgroundTaskWithName:@"cloud save" expirationHandler:end];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!save_sync_flush(20000)) LOG("front end: the save did not reach the cloud before the app was suspended; it goes after the next save or at the next start");
        dispatch_async(dispatch_get_main_queue(), end);
    });
}

void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); dm_gfx_inactive(1); break;   // dm_gfx_inactive: a swipe in the app switcher kills the app with no trip to the background
        case 1: UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); save_sync_background(); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); break;
        case 3:   // Becoming active again also ends an interruption whose "ended" never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); dm_gamepad_active(); dm_focus_set(1); dm_gfx_inactive(0); break;
    }
}
