// iOS front end (the iOS implementation of front.h): a Metal view of the picture's shape (16:9, or what the game presents: front_picture_shape) + a full-screen virtual gamepad layer (DmGamepad.m). Where they go is DmLayout.h's: in landscape the picture
// is centered (black bars; Picture Fill: cropped to cover the screen; Picture Stretch: the whole screen, stretched) and the controls are drawn over it; in portrait, or on an iPhone Duo half folded, the picture sits above the controls. With a TV connected the Metal view
// is on the TV and the phone shows the pad (DmTVSceneDelegate).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#include <errno.h>
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
bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0); true = it calls done later (Play, or the skip's short wait)

static CAMetalLayer *g_layer;
// The app window scene's screen (the phone's or iPad's own; a TV's scene never takes its place), cached on the main thread when the scene connects (main.m front_ios_scene) and at
// each layout of the root view, for the readers on other threads and those that come before the view is in a window: front_display_pixels (vi::QueryDisplayBufferMaxResolution),
// front_screen_max_fps (nvn_mtl.m mtl_display_hz and the display link) and the brightness (dm_brightness_now). UIScreen.mainScreen, which these read before, is deprecated (iOS 26).
// Only the device's own screen has a backlight, so the brightness is read from g_own_screen alone: the screen the app's scene first connects on (the built-in one; an iPad under
// Stage Manager can later move the window to an external display, which g_screen then follows for the size and rate, but whose brightness means nothing)
static UIScreen *g_screen;       // main thread
static UIScreen *g_own_screen;   // main thread
static _Atomic int g_screen_px_w, g_screen_px_h, g_screen_fps;
static _Atomic double g_brightness = -1;
static void screen_cache(UIScreen *s) {
    if (!s) return;
    g_screen = s;
    CGRect b = s.nativeBounds; g_screen_px_w = (int)b.size.width; g_screen_px_h = (int)b.size.height;
    g_screen_fps = (int)(g_own_screen ?: s).maximumFramesPerSecond;   // the device's own screen, as UIScreen.mainScreen gave: a rate that is a multiple of 60 (front.h), not an external display's under Stage Manager
    if (s == g_own_screen) g_brightness = s.brightness;
}
void front_ios_scene(UIWindowScene *scene) {   // main.m SceneDelegate: the app's scene connects, before its window and views exist
    if (!g_own_screen) g_own_screen = scene.screen;
    screen_cache(scene.screen);
}
int front_screen_max_fps(void) { return g_screen_fps; }   // front.h; hle_nvn.c keeps 120 fps off on iOS whatever it says (high_cap_tick)
static void front_ios_notify_setup(void);
static void front_ios_notify_ask(void);
static void front_ios_power_watch(void);
static void front_ios_audio_watch(void);
static UILabel *front_ios_fps_label(void);

@interface DmGameView : UIView
@property (nonatomic) CGFloat maxPixelWidth;   // 0: the screen's own pixels; a TV caps the drawable at 1920 across (tv_attach)
@property (nonatomic) CGSize picturePixels;   // zero: the drawable has the view's pixels; else at most the picture's render size (DmRootVC viewDidLayoutSubviews, DmLayout.h dm_drawable_size)
@property (nonatomic) BOOL stretched;   // the present draws the picture over the whole drawable (Picture Stretch, mtl_present_stretch): picturePixels applies to each direction on its own
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
        // A drawable is only ever the present pass's colour attachment (nvn_mtl.m present_encode_m4; MetalFX writes a texture of its own): screenshots, the window grab and
        // DM_NVN_REGLUM read the game's picture or an offscreen texture. So the drawables are render targets only (framebufferOnly, the default, as on the Mac), which lets Core
        // Animation and Metal keep them in the form best for display (lossless compression). DM_DRAWABLE_SHADER_ACCESS=1 makes them readable and writable by shaders again, as
        // before (framebufferOnly NO)
        const char *sa = getenv("DM_DRAWABLE_SHADER_ACCESS"); BOOL shaderAccess = sa && atoi(sa);
        l.framebufferOnly = !shaderAccess;
        if (shaderAccess) LOG("front end: the drawables allow shader access (DM_DRAWABLE_SHADER_ACCESS=1)");
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)didMoveToWindow { [super didMoveToWindow]; [self setNeedsLayout]; }   // the phone's screen or a TV's (DmTVSceneDelegate)
- (void)setPicturePixels:(CGSize)px { if (!CGSizeEqualToSize(px, _picturePixels)) { _picturePixels = px; [self setNeedsLayout]; } }
- (void)setStretched:(BOOL)on { if (on != _stretched) { _stretched = on; [self setNeedsLayout]; } }
// Render at the pixels of the screen the view is on (an iPad window can move to another), at most maxPixelWidth across; with picturePixels set, at most the picture's render
// size, and Core Animation scales the layer to the view (its contentsGravity, resize): 1920x1080 instead of 2868x1320 in landscape Stretch on an iPhone 18 Pro Max, three
// drawables of 8 MB instead of 15 MB, and a present pass that draws the picture 1:1. The layer keeps the screen's contentsScale: the view's size in points, and with it the
// layout and the touches (layout.game), stay as they are
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    UIScreen *screen = self.window.windowScene.screen;
    CGFloat scale = screen ? screen.nativeScale : MAX(self.traitCollection.displayScale, 1);
    if (self.maxPixelWidth > 0) scale = MIN(scale, self.maxPixelWidth / MAX(self.bounds.size.width, 1));
    l.contentsScale = scale;
    CGSize d = dm_drawable_size(self.bounds.size, scale, self.picturePixels, self.stretched);
    if (!CGSizeEqualToSize(d, l.drawableSize) && d.width > 0 && d.height > 0) {
        CGSize view = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
        if (CGSizeEqualToSize(d, view)) LOG("front end: drawable %.0fx%.0f, the view's pixels", d.width, d.height);
        else LOG("front end: drawable %.0fx%.0f, the picture's %.0fx%.0f, scaled by Core Animation to the view's %.0fx%.0f pixels", d.width, d.height, self.picturePixels.width, self.picturePixels.height, view.width, view.height);
    }
    l.drawableSize = d;
}
@end
static void tv_attach(void);

@interface DmRootView : UIView
@end
@implementation DmRootView
+ (BOOL)requiresConstraintBasedLayout { return YES; }
- (void)updateConstraints {
    // Reading here registers UIKit's automatic reserved-region invalidation.
    [self reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive];
    [self setNeedsLayout];
    [super updateConstraints];
}
@end

@interface DmRootVC : UIViewController
@property (nonatomic, strong) DmGameView *game;
@property (nonatomic, strong) UIView *pad;
@property (nonatomic, strong) UILabel *fps;
@property (nonatomic) BOOL launched;
@property (nonatomic, strong) id tv;   // the TV scene accessory's registration (iOS 27)
@property (nonatomic) BOOL ultrawideStretch;   // Ultrawide holds the picture at Stretch (startGame): the in-game menu shows its Picture row disabled then (dm_setting_held)
@property (nonatomic) BOOL split;   // the last layout put the picture above the controls (portrait, or an iPhone Duo half open), where Fill and Stretch do not apply (dm_setting_why)
@property (nonatomic) DmPictureMode picture;   // DM_PICTURE_FIT: fit, fill (in landscape the picture covers the screen, its edges cropped) or stretch (it covers the screen, stretched to its shape) (DmLayout.h dm_layout_picture)
@property (nonatomic) BOOL partiallyOpen;   // an iPhone Duo's hinge half open (UIHingeInteraction, iOS 27.1)
@property (nonatomic) NSInteger hingeStatus;
@property (nonatomic, copy) NSString *layoutLog;   // the last layout line logged
- (void)hingeChanged:(UIHinge *)hinge;
- (void)startGame;
- (void)showFPS:(BOOL)on;
@end
static DmRootVC *g_root;
static CGFloat g_picture_aspect = DM_PICTURE_16_9;   // the presented picture's width / height (front_picture_shape); main thread
static BOOL g_pictured;   // the game's first picture was reported (front_picture_shape); main thread
// The drawable at the picture's render size (front_picture_size, DmGameView picturePixels) wherever the present scales the picture bilinearly: Upscaling Standard, or Picture
// Stretch (and so Ultrawide) to a shape 1 % or more off the picture's, where MetalFX does not run (nvn_mtl.m fx_wanted: its spatial scaler is made for a uniform scale; DmLayout.h
// dm_layout_fx_shape). The present would draw the picture into the view's pixels bilinearly; Core Animation does the same scale on the layer, and the drawables are smaller. Where
// MetalFX can run the drawable keeps the view's pixels, which its scaler fills. DM_DRAWABLE_NATIVE=1 keeps the view's pixels always, as before. Main thread
static CGSize g_picture_px;   // the picture's render size (front_picture_size), zero before the first present
static BOOL g_upscale_metalfx;   // Upscaling is MetalFX: DM_PRESENT_UPSCALE at the start (startGame), then the in-game menu's pick (dm_setting_live)
static BOOL g_drawable_native;   // DM_DRAWABLE_NATIVE=1
static BOOL upscale_is_metalfx(const char *v) { return v && (!strcmp(v, "metalfx") || !strcmp(v, "1")); }   // nvn_upscale_pick.h up_parse's values
static void launcher_done(void) { [g_root startGame]; }
void mtl_present_stretch(int on);   // nvn_mtl.m: the present draws the picture over the whole drawable instead of keeping its shape (Picture Stretch)
void mtl_present_upscale_set(const char *mode);   // nvn_mtl.m: the in-game menu's Upscaling, which the present thread takes at its next present
void mtl_present_sharpen_set(const char *level);   // nvn_mtl.m: the in-game menu's Sharpening, which the present thread takes at its next present
void mtl_present_aa_set(const char *mode);   // nvn_mtl.m: the in-game menu's Anti-aliasing (edge smoothing), which the present thread takes at its next present
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
    __weak DmRootVC *weakSelf = self;
    [self.view addInteraction:[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
        [weakSelf hingeChanged:update.hinge];
    }]];
    front_ios_power_watch();
    front_ios_notify_setup();
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        const char *why = front_ios_boot_message();
        [self showHint:why ? [NSString stringWithFormat:@"Game files unusable.\n%s", why] : @"Game files not found.\nPut the RomFS folder into this App's Documents as \"romfs\" (Files app), then restart."]; return;
    }
    front_ios_audio_watch();
    {   // iOS 27 offers a TV scene only to a registered scene accessory, no longer from the Info.plist entry alone (the entry stays: main.m's App names its "TV" configuration)
        UISceneConfiguration *c = [[UISceneConfiguration alloc] initWithName:@"TV" sessionRole:UIWindowSceneSessionRoleExternalDisplayNonInteractive];
        c.delegateClass = NSClassFromString(@"DmTVSceneDelegate");
        self.tv = [self registerSceneAccessory:[UISceneAccessory externalNonInteractiveSceneAccessoryWithConfiguration:c]];
    }
}
- (void)hingeChanged:(UIHinge *)hinge {
    NSInteger status = hinge ? hinge.status : UIHingeStatusUnknown;
    if (self.hingeStatus != status) {
        self.hingeStatus = status;
        LOG("front end: Duo hinge status %ld, angle %.3f", (long)status, hinge.angle);
    }
    self.partiallyOpen = status == UIHingeStatusPartiallyOpen;
    [self.view setNeedsUpdateConstraints];
    [self.view setNeedsLayout];
}
// The game view, the pad and the frame-rate counter are made once the launcher has set the switches they read (DM_SHOW_FPS, DM_METAL_HUD); the host's loading began at app launch (main.m)
- (void)startGame {
    if (self.game) return;
    dm_cloud_saves_env();   // DM_SAVE_SYNC from the launcher's Cloud saves pick, before the game's first save mount reads it (CloudSaves.m, save_sync.h)
    front_hud_env();   // before the process's first Metal device, which reads MTL_HUD_ENABLED (an env file's DM_METAL_HUD sets it in main.m already; GitHub issue #840)
    const char *dev = front_ios_device_check();   // that first device: a GPU without BC textures is refused here, not at launch, so the launcher's HUD switch counts
    if (dev) { [self showHint:[NSString stringWithFormat:@"This device is not supported.\n%s", dev]]; return; }   // the host does not start
    {   // Picture shape "auto" (the launcher's Match screen): the app window's own shape when it is taller than 16:9 (an iPad's 4:3, an unfolded iPhone Duo's 1.43:1; loader.c
        // takes 1.3 to 1.77), else 16:9. The window's, not the screen's: on an iPad under Stage Manager or Split View the app does not fill the screen. Resolved here, before the
        // host writes the state page (main.c dm_fps_state_apply)
        const char *a = getenv("DM_SCREEN_ASPECT");
        if (a && !strcmp(a, "auto")) {
            CGSize sz = self.view.window ? self.view.window.bounds.size : g_screen.bounds.size; double r = MAX(sz.width, sz.height) / MAX(MIN(sz.width, sz.height), 1);
            char v[16]; if (r >= 1.3 && r < 1.77) snprintf(v, sizeof v, "%.3f", r); else strcpy(v, "0");
            setenv("DM_SCREEN_ASPECT", v, 1); LOG("front end: picture shape auto: window %.0fx%.0f points (%.3f:1) → DM_SCREEN_ASPECT=%s", sz.width, sz.height, r, v);
        }
    }
    self.picture = dm_picture_mode(getenv("DM_PICTURE_FIT"));
    if (self.picture == DmPictureFill) LOG("front end: picture Fill (DM_PICTURE_FIT=fill), the 16:9 picture covers the screen in landscape and its edges are cropped");
    if (self.picture == DmPictureStretch) LOG("front end: picture Stretch (DM_PICTURE_FIT=stretch), the picture is stretched to cover the screen in landscape, nothing cropped");
    // Ultrawide (DM_MOD_ULTRAWIDE=1, a switchable mod from the NSP script's mods folder, put in place by loader.c dm_mod_variants_apply): such mods render a wider view into the game's
    // 16:9 picture and expect it stretched over a wider screen, so the picture is stretched (Picture Stretch). A screen no wider than 16:9 (an iPad's 4:3) would show it squeezed:
    // there the mod stays out, before the host reads the switch when the game starts
    const char *uw = getenv("DM_MOD_ULTRAWIDE");
    if (uw && !strcmp(uw, "1")) {
        UIScreen *scr = self.view.window.windowScene.screen; CGSize sz = (scr ?: g_screen).bounds.size;   // the window's screen; the app scene's (screen_cache) before the view is in a window
        CGFloat r = MAX(sz.width, sz.height) / MAX(MIN(sz.width, sz.height), 1);
        if (r < 1.85) { unsetenv("DM_MOD_ULTRAWIDE"); LOG("front end: Ultrawide left off: this screen (%.2f:1) is not wider than 16:9", r); }
        else {
            self.picture = DmPictureStretch; self.ultrawideStretch = YES; LOG("front end: Ultrawide: the picture is stretched over the %.2f:1 screen in landscape", r);
            // The mod widens the view itself, inside the game's 16:9 picture: a taller Picture shape (DM_SCREEN_ASPECT, e.g. the iPhone Duo pick) would change that picture under it
            const char *as = getenv("DM_SCREEN_ASPECT");
            if (as && *as && strcmp(as, "0")) { setenv("DM_SCREEN_ASPECT", "0", 1); LOG("front end: Ultrawide keeps the game's 16:9 picture: DM_SCREEN_ASPECT=%s → 0", as); }
        }
    }
    g_upscale_metalfx = upscale_is_metalfx(getenv("DM_PRESENT_UPSCALE"));   // the main thread, as the menu's setenv (dm_setting_env): no copy under the lock is needed here
    const char *dn = getenv("DM_DRAWABLE_NATIVE"); g_drawable_native = dn && atoi(dn) != 0;
    if (g_drawable_native) LOG("front end: the drawable keeps the view's pixels (DM_DRAWABLE_NATIVE=1), also where the present scales the picture bilinearly");
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
    screen_cache(self.view.window.windowScene.screen);   // an iPad's window can move to another screen; nil before the view is in a window, which keeps the scene's
    CGRect b = self.view.bounds; if (!self.game) return;
    CGRect division = CGRectNull;   // an iPhone Duo's fold, as UIKit reports it (iOS 27.1)
    NSMutableArray<NSString *> *regionLog = [NSMutableArray array];
    for (UIViewReservedRegion *region in [self.view reservedRegionsOfKind:UIViewReservedRegionKind.divisionRegionKind options:UIViewReservedRegionQueryOptionsIncludeInactive]) {
        [regionLog addObject:[NSString stringWithFormat:@"%@ active=%d", NSStringFromCGRect(region.frame), region.isActive]];
        CGRect candidate = dm_horizontal_division(b, region.frame);
        if (CGRectIsNull(division) && !CGRectIsNull(candidate)) division = candidate;
    }
    BOOL duoPortrait = b.size.height > b.size.width && (self.hingeStatus != 0 || !CGRectIsNull(division));
    UIEdgeInsets gameInsets = dm_game_safe_insets(b, self.view.safeAreaInsets, duoPortrait);
    BOOL onTV = self.game.superview != self.view;   // the TV's view lays the picture out; the phone is all pad
    DmLayout layout = onTV ? dm_layout_pad_only(b) : dm_layout_picture(dm_layout(b, gameInsets, self.partiallyOpen, division, g_picture_aspect), b, self.picture, g_picture_aspect);
    if (!onTV) self.game.frame = layout.game;
    self.split = !onTV && layout.separated;
    BOOL stretched = !onTV && dm_layout_stretched(layout, self.picture, g_picture_aspect);
    mtl_present_stretch(stretched);   // a TV and a split keep the picture's shape
    self.game.stretched = stretched;   // the drawable: the picture's render size where MetalFX does not run (g_picture_px), on a TV as well
    self.game.picturePixels = g_drawable_native || (g_upscale_metalfx && dm_layout_fx_shape(layout, stretched, g_picture_aspect)) ? CGSizeZero : g_picture_px;
    layout.topSafeOnly = duoPortrait;
    NSString *line = [NSString stringWithFormat:@"%@, hinge %ld%s, divisions %@, picture %@, controls %@", onTV ? @"pad only (picture on the TV)" : layout.separated ? @"split" : self.picture == DmPictureFill ? @"overlay, Fill" : self.picture == DmPictureStretch ? @"overlay, Stretch" : @"overlay",
                      (long)self.hingeStatus, self.partiallyOpen ? " (half open)" : "", regionLog, NSStringFromCGRect(layout.game), NSStringFromCGRect(layout.controls)];
    if (![line isEqualToString:self.layoutLog]) { self.layoutLog = line; LOG("front end: layout %s", line.UTF8String); }
    self.pad.frame = b;
    dm_gamepad_arrange(self.pad, layout);
    if (self.fps) {   // the top row's free stretch: right of DmGamepad.m's L3 key (102 + 17 of its units from the safe edge), level with − / + (22 units down); u is its unit
        CGRect s = CGRectIntersection(layout.controls, UIEdgeInsetsInsetRect(b, gameInsets));
        CGFloat u = (layout.separated ? MIN(MIN(s.size.height / 430.0, s.size.width / 700.0), 1.3) : MIN(b.size.height / 430.0, 1.3)) * dm_gamepad_size();   // times Touch control size, as the pad's
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
void front_picture_size(int w, int h) {   // front.h: the drawable's size where MetalFX does not run (g_picture_px); not the crop's, so a game's dynamic resolution resizes nothing
    if (w <= 0 || h <= 0) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_picture_px.width == w && g_picture_px.height == h) return;
        g_picture_px = CGSizeMake(w, h); [g_root.view setNeedsLayout];   // viewDidLayoutSubviews hands it to the game view, also while it is on a TV
    });
}
void front_picture_shape(int w, int h) {   // front.h: the views take the presented picture's shape (a taller one under DM_SCREEN_ASPECT) instead of 16:9
    if (w <= 0 || h <= 0) return;
    CGFloat a = (CGFloat)w / h;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_pictured) { g_pictured = YES; dm_gamepad_hint(); }   // the first present reports the first shape: the menu button's 5 s at the start count from the game's first picture
        if (a == g_picture_aspect) return;
        g_picture_aspect = a; LOG("front end: picture shape %dx%d, the game's view follows it", w, h);
        [g_root.view setNeedsLayout]; if (g_tv) [g_tv.rootViewController.view setNeedsLayout];
    });
}

// The in-game menu's picks go into the environment under one lock (dm_setting_env, from GameMenu.swift), and a host thread that reads one of those variables while the game runs
// copies it under the same lock (front_env_copy, front.h): Darwin's setenv rewrites a value string it allocated in place, or reallocates it, under a pointer getenv handed another
// thread before. Of the variables the menu sets, only DM_PRESENT_UPSCALE, DM_PRESENT_SHARPEN and DM_POST_AA are read so (nvn_mtl.m fx_mode, sharp_mode and aa_mode, on the
// present thread, at its first present; startGame also reads DM_PRESENT_UPSCALE on the main thread, for the drawable). The others are read on the main thread, which picks run on: DM_PICTURE_FIT,
// DM_SHOW_FPS and DM_RUMBLE in startGame, DM_TOUCH_* in the gamepad's init, both before the menu exists; DM_OPMODE once, by hle_oe.c dm_opmode, which caches it, and the menu's own opening calls it (dm_pad_layout_offered) before a pick can be made. A host thread that comes to read one of them while
// the game runs takes it through front_env_copy, or is handed the pick by dm_setting_live below, as the present thread is (mtl_present_upscale_set, mtl_present_sharpen_set,
// mtl_present_aa_set)
static pthread_mutex_t g_env_lock = PTHREAD_MUTEX_INITIALIZER;
void dm_setting_env(const char *env, const char *value) { pthread_mutex_lock(&g_env_lock); setenv(env, value, 1); pthread_mutex_unlock(&g_env_lock); }
int front_env_copy(const char *name, char *out, size_t cap) {
    pthread_mutex_lock(&g_env_lock);
    const char *e = getenv(name);
    if (cap) strlcpy(out, e ? e : "", cap);
    pthread_mutex_unlock(&g_env_lock);
    return e != NULL;
}

// The settings the in-game menu offers (GameMenu.swift, from the gamepad's menu button), each taking effect while the game runs; the launcher's other settings need the next start.
// value NULL: only whether env is one of them; otherwise apply it (GameMenu.swift has saved it and put it in the environment, dm_setting_env). Console mode changes as on a Switch put in or taken out of its
// dock (the operation mode change notification); while a TV shows the picture the game stays docked, and the choice applies when the TV is unplugged
bool dm_setting_live(const char *env, const char *value) {
    if (!env || !g_root.game) return false;
    if (!strcmp(env, "DM_PICTURE_FIT")) {
        if (g_root.ultrawideStretch) return !value;   // Ultrawide holds Stretch (dm_setting_held): the row is shown, and a pick would squeeze or crop the mod's wider view until the next start
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
    if (!strcmp(env, "DM_TOUCH_SIZE") || !strcmp(env, "DM_TOUCH_OPACITY")) { if (value) { dm_gamepad_touch_look(env, value); [g_root.view setNeedsLayout]; } return true; }   // the counter follows the size
    if (!strcmp(env, "DM_PRESENT_UPSCALE")) {   // taken by the present thread (nvn_mtl.m); the drawable follows (g_upscale_metalfx)
        if (value) { mtl_present_upscale_set(value); g_upscale_metalfx = upscale_is_metalfx(value); [g_root.view setNeedsLayout]; LOG("front end: upscaling %s (in-game menu)", value); }
        return true;
    }
    if (!strcmp(env, "DM_PRESENT_SHARPEN")) {   // taken by the present thread (nvn_mtl.m); the drawable stays as it is: the sharpening is inside the present's own draw
        if (value) { mtl_present_sharpen_set(value); LOG("front end: sharpening %s (in-game menu)", value); }
        return true;
    }
    if (!strcmp(env, "DM_POST_AA")) {   // taken by the present thread (nvn_mtl.m); the drawable stays as it is: edge smoothing works on the game's picture before the present's draw
        if (value) { mtl_present_aa_set(value); LOG("front end: anti-aliasing %s (in-game menu)", value); }
        return true;
    }
    if (!strcmp(env, "DM_RUMBLE")) { if (value) { dm_haptics_set_enabled(atoi(value) != 0); LOG("front end: game rumble %s (in-game menu)", atoi(value) ? "on" : "off"); } return true; }
    return false;
}
// A live setting whose value the front end holds while the game runs, so the in-game menu shows its row disabled, with dm_setting_why's reason as its subtitle (GameMenu.swift),
// and dm_setting_live refuses a pick: Picture while Ultrawide holds Stretch (startGame). The saved choice stays as it is, and applies again at a start without Ultrawide
bool dm_setting_held(const char *env) { return env && g_root.game && !strcmp(env, "DM_PICTURE_FIT") && g_root.ultrawideStretch; }
// The value it holds, for the menu to tick in place of the saved choice (the launcher's shows rule says the same, settings.tsv), or NULL
const char *dm_setting_held_value(const char *env) { return dm_setting_held(env) ? "stretch" : NULL; }
// Why a live setting the in-game menu shows does nothing at the moment, as only the running game knows it (docs/settings.md, In-game menu): a short line for the row's
// subtitle, or NULL. The present's last outcome for Upscaling, Sharpening and Anti-aliasing (nvn_mtl.m, front.h DM_FX_* and the others), and the front end's own state for
// Picture (Ultrawide, a TV, a split layout), Console mode (a TV) and the touch controls (a controller, the Tap layout). GameMenu.swift reads it each time the menu opens, as it
// builds the menu then; the launcher's rules (LauncherSettings.swift) give the reasons that follow from the other settings and the device. Main thread
const char *dm_setting_why(const char *env) {
    if (!env || !g_root.game) return NULL;
    BOOL onTV = g_root.game.superview != g_root.view;
    if (!strcmp(env, "DM_PICTURE_FIT")) {
        if (g_root.ultrawideStretch) return "Ultrawide always stretches the picture";   // the launcher's rule says the same (settings.tsv)
        if (g_root.picture == DmPictureFit) return NULL;   // Fill and Stretch cover the screen in the landscape overlay only (DmLayout.h dm_layout_picture)
        return onTV ? "The TV shows the whole picture" : g_root.split ? "Applies in landscape only" : NULL;
    }
    if (!strcmp(env, "DM_OPMODE")) return g_tv_mode_was >= 0 ? "Held at Docked while a TV is connected" : NULL;   // the pick applies once it is unplugged (dm_setting_live)
    if (!strcmp(env, "DM_TOUCH_SIZE") || !strcmp(env, "DM_TOUCH_OPACITY") || !strcmp(env, "DM_TOUCH_HAPTICS")) {
        if (!dm_gamepad_touch_hidden()) return NULL;
        return !strcmp(env, "DM_TOUCH_SIZE") ? "Only sizes the menu button now" : "Touch controls are hidden";   // the menu button and the counter still follow the size
    }
    if (!strcmp(env, "DM_PRESENT_UPSCALE")) switch (mtl_present_fx_why()) {
        case DM_FX_STRETCHED: return "Not upscaling: picture is stretched";
        case DM_FX_NOT_LARGER: return "Not upscaling: picture isn't shown larger";
        case DM_FX_REFUSED: return "Not upscaling: MetalFX can't take this size";
        default: return NULL;   // upscaling, or Standard
    }
    if (!strcmp(env, "DM_PRESENT_SHARPEN")) switch (mtl_present_sharp_why()) {
        case DM_SHARP_METALFX: return "Off while MetalFX upscales";
        case DM_SHARP_GAME_UPSCALER: return "Off while MetalFX runs the game's upscaler";
        case DM_SHARP_FORMAT: return "Not supported for this game's picture";
        case DM_SHARP_PIPELINE: return "Couldn't start: see Share log";   // its pipeline failed to build (a [RED] line in the log), as edge smoothing's below
        default: return NULL;
    }
    if (!strcmp(env, "DM_POST_AA")) switch (mtl_present_aa_why()) {
        case DM_AA_FORMAT: return "Not supported for this game's picture";
        case DM_AA_FAILED: return "Couldn't start: see Share log";
        default: return NULL;
    }
    return NULL;
}
// Whether the running game says a live setting's choice took effect at the last present, which dm_setting_why's NULL does not tell apart from "nothing known yet" (0 before the
// first present): MetalFX upscaled. GameMenu.swift then leaves out the launcher's hint for the row, which can only say MetalFX may not run under Stretch or Ultrawide. Main thread
bool dm_setting_working(const char *env) { return env && g_root.game && !strcmp(env, "DM_PRESENT_UPSCALE") && mtl_present_fx_why() == DM_FX_UPSCALED; }
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
// Brightness (the device's own screen, g_own_screen) is read on the main thread at start (screen_cache) and on each change; every change of the thermal state and of Low Power Mode (which lowers the CPU clock) is logged with the time since launch.
// Low Power Mode can also lower the screen's maximumFramesPerSecond (ProMotion held at 60 Hz), so the screen's values are cached again on each change
int dm_thermal_now(void) { return (int)NSProcessInfo.processInfo.thermalState; }
int dm_low_power_now(void) { return NSProcessInfo.processInfo.lowPowerModeEnabled; }   // the frame step does not probe in it (hle_nvn.c fstep_cpu_slowed)
double dm_brightness_now(void) { return g_brightness; }
static void front_ios_power_watch(void) {
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; if (g_own_screen) g_brightness = g_own_screen.brightness; }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9);
        dispatch_async(dispatch_get_main_queue(), ^{ screen_cache(g_screen); }); }];
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

// Progress screen of the prepare step (front.h front_progress): a dark view over the game's view and the pad, the title, a bar and a count, centered; UIKit views, so it draws while the game's thread waits
static UIView *g_prog; static UILabel *g_prog_count; static UIProgressView *g_prog_bar; static UILabel *g_prog_title;
void (*front_progress_hook)(const char *title, long done, long total);
void front_progress(const char *title, long done, long total) {
    if (!g_layer) return;
    NSString *tt = title ? @(title) : nil;
    void (*hook)(const char *, long, long) = front_progress_hook;
    if (hook) { dispatch_async(dispatch_get_main_queue(), ^{ hook(tt.UTF8String, done, total); if (!tt) dm_gamepad_hint(); }); return; }   // the host app draws it (front.h)
    dispatch_async(dispatch_get_main_queue(), ^{
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
int front_display_pixels(int *w, int *h) {   // the app scene's screen in pixels (screen_cache), landscape (nativeBounds is portrait); any thread
    int a = g_screen_px_w, c = g_screen_px_h;
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
// iOS 27's model (AVAudioSessionInterruptionNotification and its keys are deprecated there): the system deactivating the session (DidBecomeInactive, source System; its
// interruption context, when another app's session took it, gives the reason) begins an interruption, and the system's resumption recommendation ends it, as the old "ended" did,
// whatever the recommendation (the game's sound is the app's own, not a playback the player started). A deactivation the app asked for (source App) is no interruption: the host never
// deactivates the session. The session becoming active again (DidBecomeActive) ends an interruption whose recommendation never came; and
// becoming active as an app ends one too (front_ios_focus_event 3), as before. All of this runs on the main queue, like the scene callbacks
static int g_audio_bg, g_audio_intr;
static void front_ios_audio_apply(void) { dm_audio_suspend(g_audio_bg || g_audio_intr); }
static void front_ios_audio_watch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:AVAudioSessionDidBecomeInactiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        AVAudioSessionDeactivationContext *c = n.userInfo[AVAudioSessionDeactivationContextKey];
        if (c && c.source != AVAudioSessionDeactivationSourceSystem) return;
        AVAudioSessionInterruptionContext *ic = c.interruptionContext;
        if (ic) LOG("audio session: interrupted (reason %lu)", (unsigned long)ic.reason);
        else LOG("audio session: interrupted (deactivated by the system, no other app's session named)");
        g_audio_intr = 1; front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionResumptionRecommendationNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        AVAudioSessionResumptionContext *c = n.userInfo[AVAudioSessionResumptionContextKey];
        LOG("audio session: interruption ended (%s)", !c ? "no recommendation" : c.recommendation == AVAudioSessionResumptionRecommendationShouldResume ? "the system recommends resuming" : "the system recommends not resuming; resuming anyway");
        g_audio_intr = 0;
        if (!g_audio_bg) front_ios_audio_session();
        front_ios_audio_apply();
    }];
    [nc addObserverForName:AVAudioSessionDidBecomeActiveNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) {
        (void)n; if (!g_audio_intr) return;
        LOG("audio session: active again with no resumption recommendation; resuming"); g_audio_intr = 0;
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

// The pipeline archive's writes dm_gfx_suspend started (a prewarm's period: up to some 2,000 bases, seconds to write) finish before iOS suspends the app, which may then end it
// without a word: a write cut short is lost, its bases built again at the next start
static void archive_background(void) {
    UIApplication *app = UIApplication.sharedApplication;
    __block UIBackgroundTaskIdentifier task = UIBackgroundTaskInvalid;
    void (^end)(void) = ^{ if (task != UIBackgroundTaskInvalid) { [app endBackgroundTask:task]; task = UIBackgroundTaskInvalid; } };
    task = [app beginBackgroundTaskWithName:@"pipeline archive" expirationHandler:end];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        if (!dm_gfx_save_wait(25000)) LOG("front end: the pipeline archive was not all written before the app was suspended");
        dispatch_async(dispatch_get_main_queue(), end);
    });
}

void front_ios_focus_event(int ev) {
    if (!g_layer) return;
    switch (ev) {
        case 0: dm_gamepad_reset(); dm_focus_set(2); break;
        case 1: UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); archive_background(); save_sync_background(); break;
        case 2: dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); break;
        case 3:   // Becoming active again also ends an interruption whose resumption recommendation never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); dm_gamepad_active(); dm_focus_set(1); break;
    }
}
