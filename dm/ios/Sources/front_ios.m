// iOS front end (the iOS implementation of front.h): a Metal view of the picture's shape (16:9, or what the game presents: front_picture_shape) + a full-screen virtual gamepad layer (DmGamepad.m). Where they go is DmLayout.h's: in landscape the picture
// is centered (black bars; Picture Fill: cropped to cover the screen; Picture Stretch: the whole screen, stretched) and the controls are drawn over it; in portrait, or on an iPhone Duo half folded, the picture sits above the controls. With a TV connected the Metal view
// is on the TV and the phone shows the pad (DmTVSceneDelegate). While the touch controls show on the phone, the present draws them into the game's frame (touch_draw.h): the Metal
// view takes the whole screen and the picture keeps its place on it, so nothing sits over the game's layer (DM_TOUCH_DRAW=layer: their layers, as before).
// The host runs on the big-stack thread started by main.m; front_run runs the guest directly on the calling thread.
#import <UIKit/UIKit.h>
#import <UserNotifications/UserNotifications.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <AVFAudio/AVFAudio.h>
#include <errno.h>
#include <stdatomic.h>
#include "front.h"
#include "hle.h"
#include "dm.h"
#include "front_drawable.h"   // DM_DRAWABLE_COUNT
#include "state_report.h"   // the screen state for the system's performance traces
#include "front_bright.h"   // the brightness lines and DM_BRIGHT_PROBE
#include "haptics_apple.h"
#include "save_sync.h"
#include "ui_font.h"   // NX 18's UI font for the hint, the counter, the progress screen and the program handoff
#include "touch_draw.h"   // front_touch_draw_failed
#include "audio_io.h"   // DM_AUDIO_IO_MS
#import "CloudSaves.h"

void dm_gamepad_active(void);
void dm_gamepad_hint(void);   // DmGamepad.m: the menu button shows for 5 s (main thread)
#import "DmLayout.h"
#import "DmGameMenu.h"
#import "DmCapture.h"
#import "DmVitals.h"   // Vitals, the frame-rate counter grown into frame rate, CPU power, heat, battery and time
static int front_ios_vitals_parse(const char *v);
static int front_ios_vitals_level(void);

void front_ios_boot(void);
int front_ios_boot_ok(void);
const char *front_ios_boot_message(void);   // main.m: why a build that keeps the game files off the IPA found none usable (NULL = the generic hint)
const char *front_ios_device_check(void);   // main.m: why this device cannot run the games (its GPU has no BC textures; NULL = supported); makes the first Metal device
bool front_ios_hud_enabled_from_saved_choice(void);   // main.m: the saved Performance HUD choice turned Metal's HUD on at launch
void dm_profile_env(void);   // NX18Profile.swift: DM_NICK and DM_PROFILE_IMAGE from the NX 18 Profile
void dm_play_record_event(int ev);   // PlayRecord.swift: 1 a session starts (the game's start, back in front), 0 it ends (to the background)
bool dm_show_launcher(void *view_controller, void (*done)(void));   // Launcher.swift: false = no launcher (no dm/launcher.json, or DM_LAUNCHER=0); true = it calls done later (Play, or the skip's short wait)

static CAMetalLayer *g_layer;
// The app window scene's screen (the phone's or iPad's own; a TV's scene never takes its place), cached on the main thread when the scene connects (main.m front_ios_scene) and at
// each layout of the root view, for the readers on other threads and those that come before the view is in a window: front_display_pixels (vi::QueryDisplayBufferMaxResolution),
// front_screen_max_fps (nvn_mtl.m mtl_display_hz and the display link) and the brightness (dm_brightness_now). UIScreen.mainScreen, which these read before, is deprecated (iOS 26).
// Only the device's own screen has a backlight, so the brightness is read from g_own_screen alone: the screen the app's scene first connects on (the built-in one; an iPad under
// Stage Manager can later move the window to an external display, which g_screen then follows for the size and rate, but whose brightness means nothing)
static UIScreen *g_screen;       // main thread
static UIScreen *g_own_screen;   // main thread
static __weak UIWindowScene *g_own_scene;   // main thread: the app's scene, whose activation state the brightness lines give
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
    if (!g_own_scene) g_own_scene = scene;
    screen_cache(scene.screen);
}
int front_screen_max_fps(void) { return g_screen_fps; }   // front.h; hle_nvn.c keeps 120 fps off on iOS whatever it says (high_cap_tick)
static void front_ios_notify_setup(void);
static void front_ios_notify_ask(void);
static void gpu_lost_note(void);   // the last session ended with the GPU taken as lost (front_gpu_lost)
static void front_ios_power_watch(void);
static void probe_start(void);
static void probe_arm(void);
static void probe_restore(const char *why);
static void front_ios_audio_watch(void);

@interface DmGameView : UIView
@property (nonatomic) CGFloat maxPixelWidth;   // 0: the screen's own pixels; a TV caps the drawable at 1920 across (tv_attach)
@property (nonatomic) CGSize picturePixels;   // zero: the drawable has the view's pixels; else at most the picture's render size (DmRootVC viewDidLayoutSubviews, DmLayout.h dm_drawable_size)
@property (nonatomic) BOOL stretched;   // the present draws the picture over the whole drawable (Picture Stretch, mtl_present_stretch): picturePixels applies to each direction on its own
@property (nonatomic) CGFloat drawableScale;   // 0: as above; else the drawable's pixels a point, below the screen's (DM_PRESENT_DRAWABLE=game with the touch controls in the frame, touch_draw.h touch_drawable_scale)
@property (nonatomic, readonly) CGFloat pixelScale;
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
        { const char *dc = getenv("DM_DRAWABLE_COUNT"); int n = front_drawable_count(l, dc);   // front_drawable.h: unset keeps Metal's 3
          if (n > 0) LOG("front end: %d drawables (DM_DRAWABLE_COUNT)", n); else if (n < 0) LOG("[RED] front end: DM_DRAWABLE_COUNT=%s is not 2 or 3: Metal's 3 drawables", dc); }
        self.backgroundColor = UIColor.blackColor;
    }
    return self;
}
- (void)didMoveToWindow { [super didMoveToWindow]; [self setNeedsLayout]; }   // the phone's screen or a TV's (DmTVSceneDelegate)
- (void)setPicturePixels:(CGSize)px { if (!CGSizeEqualToSize(px, _picturePixels)) { _picturePixels = px; [self setNeedsLayout]; } }
- (void)setStretched:(BOOL)on { if (on != _stretched) { _stretched = on; [self setNeedsLayout]; } }
- (void)setDrawableScale:(CGFloat)s { if (s != _drawableScale) { _drawableScale = s; [self setNeedsLayout]; } }
// Render at the pixels of the screen the view is on (an iPad window can move to another), at most maxPixelWidth across; with picturePixels set, at most the picture's render
// size, and Core Animation scales the layer to the view (its contentsGravity, resize): 1920x1080 instead of 2868x1320 in landscape Stretch on an iPhone 18 Pro Max, three
// drawables of 8 MB instead of 15 MB, and a present pass that draws the picture 1:1. The layer keeps the screen's contentsScale: the view's size in points, and with it the
// layout and the touches (layout.game), stay as they are
- (CGFloat)pixelScale {   // the drawable's pixels a point before picturePixels: the screen's, at most maxPixelWidth across (the touch controls' pictures take it too, DmGamepad.m touchAtlas)
    UIScreen *screen = self.window.windowScene.screen;
    CGFloat scale = screen ? screen.nativeScale : MAX(self.traitCollection.displayScale, 1);
    if (self.maxPixelWidth > 0) scale = MIN(scale, self.maxPixelWidth / MAX(self.bounds.size.width, 1));
    return scale;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CAMetalLayer *l = (CAMetalLayer *)self.layer;
    CGFloat scale = self.pixelScale;
    l.contentsScale = scale;
    CGSize d = dm_drawable_size(self.bounds.size, scale, self.picturePixels, self.stretched);
    // DM_PRESENT_DRAWABLE=game with the touch controls in the frame: the canvas's points at the scale the root chose, rounded as the gamepad rounds its frame's canvas (touchFrameHead)
    BOOL game = self.drawableScale > 0 && self.drawableScale < scale;
    if (game) d = CGSizeMake(round(self.bounds.size.width * self.drawableScale), round(self.bounds.size.height * self.drawableScale));
    if (!CGSizeEqualToSize(d, l.drawableSize) && d.width > 0 && d.height > 0) {
        CGSize view = CGSizeMake(self.bounds.size.width * scale, self.bounds.size.height * scale);
        if (game) LOG("front end: drawable %.0fx%.0f at %.3f pixels a point, the picture's render size with the touch controls in the frame (DM_PRESENT_DRAWABLE=game), scaled by Core Animation to the view's %.0fx%.0f pixels",
                      d.width, d.height, self.drawableScale, view.width, view.height);
        else if (CGSizeEqualToSize(d, view)) LOG("front end: drawable %.0fx%.0f, the view's pixels", d.width, d.height);
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
@property (nonatomic, strong) UIView *vitals;
@property (nonatomic) BOOL launched;
@property (nonatomic, strong) id tv;   // the TV scene accessory's registration (iOS 27)
@property (nonatomic) BOOL ultrawideStretch;   // Ultrawide holds the picture at Stretch (startGame): the in-game menu shows its Picture row disabled then (dm_setting_held)
@property (nonatomic) BOOL split;   // the last layout put the picture above the controls (portrait, or an iPhone Duo half open), where Fill and Stretch do not apply (dm_setting_why)
@property (nonatomic) DmPictureMode picture;   // DM_PICTURE_FIT: fit, fill (in landscape the picture covers the screen, its edges cropped) or stretch (it covers the screen, stretched to its shape) (DmLayout.h dm_layout_picture)
@property (nonatomic) BOOL partiallyOpen;   // an iPhone Duo's hinge half open (UIHingeInteraction, iOS 27.1)
@property (nonatomic) NSInteger hingeStatus;
@property (nonatomic, copy) NSString *layoutLog;   // the last layout line logged
@property (nonatomic, copy) NSString *touchLog;   // the last line logged on what draws the touch controls (viewDidLayoutSubviews)
@property (nonatomic) BOOL touchDrawn;   // the present draws the touch controls into the game's frame (the last layout)
- (void)hingeChanged:(UIHinge *)hinge;
- (void)startGame;
- (void)applyVitals:(int)level;
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
// DM_PRESENT_DRAWABLE=game (touch_draw.h touch_drawable_game): the drawable at the picture's render size while the touch controls are drawn into the frame too, where it keeps the
// screen's pixels by default (the controls' pictures 1:1). The canvas (the whole screen with Fit's bars or a split's controls) takes one scale, just enough for the picture's
// rectangle to get all of the picture's pixels (touch_drawable_scale), the controls are pictured and laid out at it (dm_gamepad_touch_draw), and Core Animation scales the layer
// to the screen. Where MetalFX upscales to the screen's pixels it stands down (its scaler would have no larger rectangle to fill), as under DM_DRAWABLE_NATIVE=1 and on a TV;
// each reason is logged once it changes. Whether iOS still sends a scaled layer's drawables straight to the display is the device A/B's question (the Metal HUD's layersize and
// presentdelay). Main thread
static BOOL g_drawable_game;
// The touch controls drawn into the game's frame (touch_draw.h, DmGamepad.m touchDraw:) while they show on the phone with the game's picture; their layers over the game's layer
// with DM_TOUCH_DRAW=layer (an A/B of the two), on a TV (the phone is all pad), before the game's first picture (the controls show over the black screen before the game draws),
// or once the present has said it cannot draw them (front_touch_draw_failed). Main thread
static BOOL g_touch_layer, g_touch_failed;
static BOOL upscale_is_metalfx(const char *v) { return v && (!strcmp(v, "metalfx") || !strcmp(v, "1")); }   // nvn_upscale_pick.h up_parse's values
static void launcher_done(void) { [g_root startGame]; }
int front_web_touch(void);   // web_apple.m: an offline HTML page is shown over the picture
void mtl_present_stretch(int on);   // nvn_mtl.m: the present draws the picture over the whole drawable instead of keeping its shape (Picture Stretch)
void mtl_present_upscale_set(const char *mode);   // nvn_mtl.m: the in-game menu's Upscaling, which the present thread takes at its next present
void mtl_present_sharpen_set(const char *level);   // nvn_mtl.m: the in-game menu's Sharpening, which the present thread takes at its next present
void mtl_present_aa_set(const char *mode);   // nvn_mtl.m: the in-game menu's Anti-aliasing (edge smoothing), which the present thread takes at its next present
void dm_low_power_cap_set(int on);   // hle_nvn.c: the in-game menu's Low Power Mode at 30 fps, which the next thermal and Low Power Mode sample takes (once a second)
static const char *picture_name(DmPictureMode m) { return m == DmPictureFill ? "Fill" : m == DmPictureStretch ? "Stretch" : "Fit"; }
@implementation DmRootVC
- (void)loadView { self.view = [DmRootView new]; }
- (void)showHint:(NSString *)text {   // why the game cannot start, centered over the black screen
    UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(self.view.bounds, 40, 40)];
    lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
    lb.font = dm_ui_font(17, UIFontWeightRegular); dm_ui_label_text(lb, text); [self.view addSubview:lb];
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.blackColor;
    __weak DmRootVC *weakSelf = self;
    [self.view addInteraction:[[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
        [weakSelf hingeChanged:update.hinge];
    }]];
    // Another display scale (an iPad window moved to a screen of another scale, keeping its size in points): the game view's drawable changes its pixels, so the touch controls'
    // canvas must too (viewDidLayoutSubviews hands the gamepad the new pixels a point), or the frames would fit no drawable
    [self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) { [weakSelf.view setNeedsLayout]; }];
    front_ios_power_watch();
    front_ios_notify_setup();
    if (!front_ios_boot_ok()) {   // No game files: show a hint and do not start the host
        const char *why = front_ios_boot_message();
        [self showHint:why ? [NSString stringWithFormat:@"Game files unusable.\n%s", why] : @"Game files not found.\nPut the RomFS folder from your own dump of this game into this App's Documents as \"romfs\" (Files app), then restart."]; return;
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
    if (!getenv("DM_PLAY_AT")) {   // a start without the settings screen (or its Play): the start's timeline counts from here (dm/host/hle_lifecycle.c; the screen's Play sets it, Launcher.swift)
        struct timespec w; clock_gettime(CLOCK_REALTIME, &w); char v[32]; snprintf(v, sizeof v, "%lld.%06ld", (long long)w.tv_sec, w.tv_nsec / 1000); setenv("DM_PLAY_AT", v, 1);
    }
    dm_cloud_saves_env();   // DM_SAVE_SYNC from the launcher's Cloud saves pick, before the game's first save mount reads it (CloudSaves.m, save_sync.h)
    dm_profile_env();       // the Profile's name and picture for the games, also at a start that skipped the Gate (NX18Profile.swift; a cheap look at the NX 18 folder within 1 s)
    dm_play_record_event(1);   // the play record's session (PlayRecord.swift, on the device only)
    front_hud_env();   // before the process's first Metal device, which reads MTL_HUD_ENABLED (an env file's DM_METAL_HUD sets it in main.m already; GitHub issue #840)
    const char *dev = front_ios_device_check();   // that first device: a GPU without BC textures is refused here, not at launch, so the launcher's HUD switch counts
    if (dev) { [self showHint:[NSString stringWithFormat:@"This device is not supported.\n%s", dev]]; return; }   // the host does not start
    gpu_lost_note();
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
            dm_camera_aspect_screen((float)r);   // a game whose own camera widens (CAMERA_ASPECT: Breath of the Wild, Tears of the Kingdom) draws this ratio (loader.c)
            // The mod widens the view itself, inside the game's 16:9 picture: a taller Picture shape (DM_SCREEN_ASPECT, e.g. the iPhone Duo pick) would change that picture under it
            const char *as = getenv("DM_SCREEN_ASPECT");
            if (as && *as && strcmp(as, "0")) { setenv("DM_SCREEN_ASPECT", "0", 1); LOG("front end: Ultrawide keeps the game's 16:9 picture: DM_SCREEN_ASPECT=%s → 0", as); }
        }
    }
    g_upscale_metalfx = upscale_is_metalfx(getenv("DM_PRESENT_UPSCALE"));   // the main thread, as the menu's setenv (dm_setting_env): no copy under the lock is needed here
    const char *dn = getenv("DM_DRAWABLE_NATIVE"); g_drawable_native = dn && atoi(dn) != 0;
    { const char *pd = getenv("DM_PRESENT_DRAWABLE"); int bad; g_drawable_game = touch_drawable_game(pd, &bad);
      if (bad) LOG("[RED] front end: DM_PRESENT_DRAWABLE=%s: game or screen; the drawable keeps the screen's pixels with the touch controls in the frame", pd);
      else if (g_drawable_game) LOG("front end: DM_PRESENT_DRAWABLE=game: the drawable at the picture's render size with the touch controls in the frame too, scaled by Core Animation to the screen"); }
    const char *td = getenv("DM_TOUCH_DRAW");
    if (td && !strcmp(td, "layer")) g_touch_layer = YES;
    else if (td && *td && strcmp(td, "frame")) LOG("[RED] front end: DM_TOUCH_DRAW=%s: layer or frame; the touch controls are drawn into the game's frame", td);
    if (g_drawable_native) LOG("front end: the drawable keeps the view's pixels (DM_DRAWABLE_NATIVE=1), also where the present scales the picture bilinearly");
    self.view.clipsToBounds = YES;   // with Fill the game view is larger than the screen
    self.view.window.traitOverrides.preferredContentSizeCategory = UIContentSizeCategorySmall;   // UIKit draws the in-game menu's UIMenu (GameMenu.swift, DM_GAME_MENU=system) in this window: it keeps one compact text size over the game, whatever the system's text size (NX 18's panel sets the system's back on itself, GameMenuPanel.swift)
    self.game = [[DmGameView alloc] initWithFrame:self.view.bounds];
    [self.view addSubview:self.game];
    g_layer = (CAMetalLayer *)self.game.layer;
    dm_capture_follow_system(self.game);   // iOS's own screenshots also save the game's clean picture to Captures (DmCapture.h)
    if (getenv("DM_METAL_HUD") && atoi(getenv("DM_METAL_HUD"))) { g_layer.developerHUDProperties = @{@"mode": @"default"}; LOG("front end: Metal performance HUD on (DM_METAL_HUD)"); }   // Apple's HUD over the game: frame rate, frame and GPU time, memory
    else if (front_ios_hud_enabled_from_saved_choice()) { g_layer.developerHUDProperties = @{@"mode": @"disabled"}; LOG("front end: Metal performance HUD off on the game (switched off since the launch turned it on)"); }   // main.m boot_env
    dm_haptics_apple_init();
    self.pad = dm_gamepad_view(self.view.bounds);
    self.pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.view addSubview:self.pad];
    [self applyVitals:front_ios_vitals_level()];
    [self.view setNeedsLayout]; [self.view layoutIfNeeded];
    UIApplication.sharedApplication.idleTimerDisabled = YES;
    tv_attach();   // a TV connected while the launcher showed
    front_ios_boot();
    probe_start();   // DM_BRIGHT_PROBE (logging only, off by default)
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
    // The touch controls drawn into the game's frame: the game view is the whole screen (Fill: its picture, which covers it) and the picture keeps its rectangle on it
    // (dm_touch_canvas, dm_touch_picture), at the screen's pixels, so the controls' pictures land 1:1 (picturePixels off: a drawable at the picture's render size would scale them)
    BOOL shown = dm_gamepad_controls_shown(self.pad);
    // An offline HTML page (web_apple.m) is a view over the game view and under the pad: the controls drawn into the game's frame would be under it, and it is over the
    // game's layer anyway, so they stay on their layers over it while it shows (front_web_shown lays the view out again at each change)
    const char *layerWhy = onTV ? "the picture is on the TV, the phone is all pad" : g_touch_failed ? "the present cannot draw them" : g_touch_layer ? "DM_TOUCH_DRAW=layer" :
                           !g_pictured ? "until the game's first picture" : front_web_touch() ? "an offline page is shown over the picture" : NULL;
    BOOL touchDraw = shown && !layerWhy;
    CGFloat pxScale = self.game.pixelScale;
    CGRect canvas = touchDraw ? dm_touch_canvas(layout, b, pxScale) : layout.game;
    if (!onTV) self.game.frame = canvas;
    self.split = !onTV && layout.separated;
    BOOL stretched = !onTV && dm_layout_stretched(layout, self.picture, g_picture_aspect);
    mtl_present_stretch(stretched);   // a TV and a split keep the picture's shape
    self.game.stretched = stretched;   // the drawable: the picture's render size where MetalFX does not run (g_picture_px), on a TV as well
    BOOL fxScreen = g_upscale_metalfx && dm_layout_fx_shape(layout, stretched, g_picture_aspect);   // MetalFX fills the screen's pixels
    self.game.picturePixels = touchDraw || g_drawable_native || fxScreen ? CGSizeZero : g_picture_px;
    // DM_PRESENT_DRAWABLE=game: with the touch controls in the frame, the canvas at the picture's render size (g_drawable_game, above); drawScale is the drawable's pixels a point
    CGFloat drawScale = pxScale;
    if (g_drawable_game) {
        const char *why = onTV ? "stands down: the picture is on the TV (its own drawable)" : g_drawable_native ? "stands down: DM_DRAWABLE_NATIVE=1 keeps the view's pixels" :
                          fxScreen ? "stands down: MetalFX upscaling fills the screen's pixels (DM_PRESENT_UPSCALE, the in-game menu's Upscaling)" :
                          !touchDraw ? "not needed: no touch controls in the frame, the drawable takes the picture's render size as by default" :
                          g_picture_px.width <= 0 ? "waits for the picture's render size" : NULL;
        if (!why) drawScale = touch_drawable_scale(layout.game.size.width, layout.game.size.height, g_picture_px.width, g_picture_px.height, pxScale);
        NSString *line = why ? [NSString stringWithFormat:@"DM_PRESENT_DRAWABLE=game %s", why]
                             : [NSString stringWithFormat:@"DM_PRESENT_DRAWABLE=game: the canvas %.0fx%.0f points at %.3f pixels a point (the screen's %.2f), %.0fx%.0f, for the picture's %.0fx%.0f",
                                canvas.size.width, canvas.size.height, drawScale, pxScale, round(canvas.size.width * drawScale), round(canvas.size.height * drawScale), g_picture_px.width, g_picture_px.height];
        static NSString *said; if (![line isEqualToString:said]) { said = line; LOG("front end: %s", line.UTF8String); }
    }
    self.game.drawableScale = touchDraw && drawScale < pxScale ? drawScale : 0;
    layout.topSafeOnly = duoPortrait;
    NSString *line = [NSString stringWithFormat:@"%@, hinge %ld%s, divisions %@, picture %@, controls %@", onTV ? @"pad only (picture on the TV)" : layout.separated ? @"split" : self.picture == DmPictureFill ? @"overlay, Fill" : self.picture == DmPictureStretch ? @"overlay, Stretch" : @"overlay",
                      (long)self.hingeStatus, self.partiallyOpen ? " (half open)" : "", regionLog, NSStringFromCGRect(layout.game), NSStringFromCGRect(layout.controls)];
    if (![line isEqualToString:self.layoutLog]) { self.layoutLog = line; LOG("front end: layout %s", line.UTF8String); }
    self.pad.frame = b;
    dm_gamepad_arrange(self.pad, layout);
    self.touchDrawn = touchDraw; dm_gamepad_touch_draw(self.pad, touchDraw, canvas, drawScale, dm_touch_picture(layout.game, canvas));   // pictured and laid out at the drawable's pixels a point
    NSString *tl = touchDraw ? [NSString stringWithFormat:@"drawn into the game's frame by the present (canvas %.0fx%.0f points, drawable %.0fx%.0f; DM_TOUCH_DRAW=layer draws them on their layers)",
                                canvas.size.width, canvas.size.height, round(canvas.size.width * drawScale), round(canvas.size.height * drawScale)]
                 : !shown ? (dm_gamepad_touch_hidden() == 2 ? @"hidden (the Tap layout): nothing over the game's layer but the menu button while it shows" : @"hidden (a controller is in use)")
                 : [NSString stringWithFormat:@"drawn on their layers over the game's layer (%s)", layerWhy];
    if (![tl isEqualToString:self.touchLog]) { self.touchLog = tl; LOG("front end: touch controls %s", tl.UTF8String); }
    if (self.vitals) {   // Vitals: the top row's free stretches either side of − (≡) +, level with them (22 of the pad's units down); u is the pad's unit
        CGRect s = CGRectIntersection(layout.controls, UIEdgeInsetsInsetRect(b, gameInsets));
        CGFloat u = (layout.separated ? MIN(MIN(s.size.height / 430.0, s.size.width / 700.0), 1.3) : MIN(b.size.height / 430.0, 1.3)) * dm_gamepad_size();   // times Touch control size, as the pad's
        [self.view bringSubviewToFront:self.vitals];
        self.vitals.frame = self.view.bounds;
        dm_vitals_layout(s, u, dm_gamepad_top_center(self.pad));
    }
}
- (void)applyVitals:(int)level {   // Vitals: DM_SHOW_FPS at Play (0 off, 1 Standard, 2 Detailed), then the in-game menu's tile (on writes 1)
    if (level && !self.vitals) { self.vitals = dm_vitals_view(); [self.view addSubview:self.vitals]; }   // above the pad, which hides while a controller is connected
    dm_vitals_set_level(level);
    [self.view setNeedsLayout];
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
    if (dm_show_launcher((__bridge void *)self, launcher_done)) dm_state_report(DM_STATE_SCREEN, "Gate");   // state_report.h; the game's start says Loading (hle_lifecycle.c)
    else [self startGame];   // the settings screen first (Launcher.swift), when the app has one
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
void front_picture_size(int w, int h) {   // front.h: the drawable's size where MetalFX does not run (g_picture_px); the largest crop's, so a game's dynamic resolution resizes nothing
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
        if (!g_pictured) { g_pictured = YES; dm_gamepad_hint(); [g_root.view setNeedsLayout]; }   // the first present reports the first shape: the menu button's 5 s at the start count from the game's first picture, and the touch controls go into the frame
        if (a == g_picture_aspect) return;
        g_picture_aspect = a; LOG("front end: picture shape %dx%d, the game's view follows it", w, h);
        [g_root.view setNeedsLayout]; if (g_tv) [g_tv.rootViewController.view setNeedsLayout];
    });
}

void front_touch_draw_failed(void) {   // touch_draw.h: the present cannot draw the touch controls (its pipeline, or the atlas's texture), so they go back to their layers for this run
    dispatch_async(dispatch_get_main_queue(), ^{ if (g_touch_failed) return; g_touch_failed = YES; [g_root.view setNeedsLayout]; });
}
bool dm_touch_in_frame(void) { return g_root.touchDrawn; }   // the present draws the touch controls now (the Duo harness); main thread

// The in-game menu's picks go into the environment under one lock (dm_setting_env, from GameMenu.swift), and a host thread that reads one of those variables while the game runs
// copies it under the same lock (front_env_copy, front.h): Darwin's setenv rewrites a value string it allocated in place, or reallocates it, under a pointer getenv handed another
// thread before. Of the variables the menu sets, only DM_PRESENT_UPSCALE, DM_PRESENT_SHARPEN, DM_POST_AA, DM_LOW_POWER_CAP and DM_PRESET are read so (nvn_mtl.m fx_mode, sharp_mode and aa_mode, on the
// present thread, at its first present; startGame also reads DM_PRESENT_UPSCALE on the main thread, for the drawable; hle_nvn.c thermal_capped, at its first sample; nvn_framegen.inc
// fg_power_why, once a second on the display link's and the present thread while frame generation is on: the preset, which GameMenu.swift gameMenuPresetEnv sets, not a row). The others are read on the main thread, which picks run on: DM_PICTURE_FIT,
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
    if (!strcmp(env, "DM_SHOW_FPS")) { if (value) [g_root applyVitals:front_ios_vitals_parse(value)]; return true; }
    if (!strcmp(env, "DM_TOUCH_HAPTICS")) { if (value) dm_gamepad_touch_feedback(atoi(value) != 0); return true; }
    if (!strcmp(env, "DM_CAPTURE_SYSTEM")) { if (value) dm_capture_follow_set(atoi(value) != 0); return true; }
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
    if (!strcmp(env, "DM_LOW_POWER_CAP")) { if (value) dm_low_power_cap_set(atoi(value) != 0); return true; }   // the 30 fps hold in Low Power Mode (hle_nvn.c thermal_capped), at its next sample
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
// first present): MetalFX upscaled. GameMenu.swift then leaves out the launcher's hint for the row, which can only say MetalFX may not run under Ultrawide. Main thread
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
// Brightness lines, logging only, for the X2.0 heat ladder's first phone runs (front_bright.h). Every UIScreenBrightnessDidChangeNotification gets a line with the device's own screen's new
// value and the one before, the thermal state, the time since launch and whether the app's scene is active (a change while it is inactive is most likely the player's, from Control
// Center), at most FRONT_BRIGHT_BURST lines a second; the next line, or a trailing "brightness settled at" line a second later with the value the storm ended on, says how many
// were not logged. The power and on-screen rows' brightness (every 300 frames) reads the same cached value as before. DM_BRIGHT_PROBE=<0.05-1.0> (off by default; env.txt, player
// builds too): once, 3 s after the game's scene is active, the brightness is saved and set to that value. The change lines then say which notifications match the set and how long
// after it they came, and lines 1 s and 10 s after the set (60 s, 180 s and 600 s too, while it is still set) read UIScreen.brightness back; the cached value follows the set and the
// put-back. They answer whether an app's own set posts the notification, whether iOS keeps the app's value with Auto-Brightness on, whether a low value holds. The saved value is put
// back once, on resign active (a swipe in the app switcher kills the app with no trip to the background), on entering the background or at a program handoff (handoff_notice: the
// graceful exit that ends the app then never resigns active), whichever comes first; a crash leaves the probe's value on the screen. All of it on the main thread
static front_bright_rate g_bright_rate;
static double g_probe_value;   // DM_BRIGHT_PROBE's value; 0: no probe
static int g_probe_state;   // 0 off, 1 waiting for the game's scene to be active, 2 set, 3 put back
static unsigned g_probe_gen;   // probe_arm's pending set: only the latest one sets, and resigning active cancels it
static double g_probe_from, g_probe_t, g_probe_back_t;   // the brightness before the set; when the set and the put-back were made (seconds after launch)
static int g_probe_in_set;   // inside the set's or the put-back's call: a notification posted from within it
static unsigned g_probe_notes, g_probe_ours, g_probe_sync;   // notifications since the set; those that match its value within FRONT_BRIGHT_OWN_S; of those, the ones posted inside the set call
static double launch_s(void) { return (now_ns() - g_t0_ns) / 1e9; }
static const char *scene_state(void) {
    UIWindowScene *s = g_own_scene;
    if (!s) return "no scene";
    switch (s.activationState) {
        case UISceneActivationStateForegroundActive: return "scene active";
        case UISceneActivationStateForegroundInactive: return "scene inactive";
        case UISceneActivationStateBackground: return "scene in the background";
        default: return "scene not attached";
    }
}
// The trailing line of a storm (front_bright_rate_flush): the value the screen settled on, once the changes past the guard's burst were not logged and no line since counted them
static void bright_settled(void) {
    unsigned k = front_bright_rate_flush(&g_bright_rate);
    if (!k || !g_own_screen) return;
    g_brightness = g_own_screen.brightness;
    LOG("front end: brightness settled at %.3f (thermal %d, %.1f s after launch, %s; %u changes before it not logged)", (double)g_brightness, dm_thermal_now(), launch_s(), scene_state(), k);
}
static void bright_changed(NSNotification *n) {
    double was = g_brightness, t = launch_s();
    if (g_own_screen) g_brightness = g_own_screen.brightness;
    double v = g_brightness;
    char probe[96] = "";
    if (g_probe_state == 2) {
        double dt = g_probe_in_set ? 0 : t - g_probe_t; int ours = front_bright_ours(v, g_probe_value, dt);
        g_probe_notes++; g_probe_ours += ours; g_probe_sync += ours && g_probe_in_set;
        snprintf(probe, sizeof probe, "; %.2f s after the probe's set%s", dt, !ours ? "" : g_probe_in_set ? ", the set's own, posted inside the set call" : ", the set's own");
    } else if (g_probe_state == 3) {   // only the put-back's own notification is tagged (its value, within FRONT_BRIGHT_OWN_S); later changes are Auto-Brightness's or the player's
        double dt = g_probe_in_set ? 0 : t - g_probe_back_t;
        if (front_bright_ours(v, g_probe_from, dt)) snprintf(probe, sizeof probe, "; %.2f s after the probe's put-back, its own%s", dt, g_probe_in_set ? ", posted inside the put-back call" : "");
    }
    unsigned skipped = 0; int trail = 0;
    if (!front_bright_rate_take(&g_bright_rate, t, &skipped, &trail)) {
        if (trail) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(FRONT_BRIGHT_WINDOW_S * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ bright_settled(); });
        return;
    }
    char sk[48] = "";
    if (skipped) snprintf(sk, sizeof sk, "; %u changes before it not logged", skipped);
    LOG("front end: brightness %.3f → %.3f (thermal %d, %.1f s after launch, %s%s%s%s)", was, v, dm_thermal_now(), t, scene_state(),
        n.object && n.object != g_own_screen ? ", posted for another screen" : "", probe, sk);
}
// A read-back of UIScreen.brightness after_s after the set (past 10 s only while the probe's value is still set: Auto-Brightness moves every 1-3 min, so those show whether the value
// held). The block runs late when the app was suspended or the main thread busy, so the line gives the measured delay too. A screen that reads other than the cached value changed
// with no notification so far: the line says so and the cache takes the value, so the on-screen and power rows' brightness is right again
static void probe_read(int after_s) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)after_s * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (after_s > 10 && g_probe_state != 2) return;
        double r = g_own_screen.brightness, c = g_brightness; char silent[64] = "";
        if (fabs(r - c) > 0.005) { snprintf(silent, sizeof silent, ", with no notification so far (cached %.3f)", c); g_brightness = r; }
        LOG("front end: brightness probe: %d s (%.1f s measured) after the set to %.3f the screen reads %.3f%s%s; %u notifications since the set, %u of them the set's own (%u posted inside the set call); thermal %d, %s",
            after_s, launch_s() - g_probe_t, g_probe_value, r, silent, g_probe_state == 3 ? " (put back since)" : "", g_probe_notes, g_probe_ours, g_probe_sync, dm_thermal_now(), scene_state());
    });
}
static void probe_set(void) {
    UIWindowScene *s = g_own_scene;
    if (g_probe_state != 1 || !g_own_screen || !s || s.activationState != UISceneActivationStateForegroundActive) return;
    g_probe_from = g_own_screen.brightness; g_probe_t = launch_s(); g_probe_state = 2;
    LOG("front end: brightness probe (DM_BRIGHT_PROBE): %.3f → %.3f (thermal %d, %.1f s after launch)", g_probe_from, g_probe_value, dm_thermal_now(), g_probe_t);
    g_probe_in_set = 1; g_own_screen.brightness = g_probe_value; g_probe_in_set = 0;
    g_brightness = g_own_screen.brightness;   // the cache the rows and the next change line's "was" read, whether or not the set posted a notification
    LOG("front end: brightness probe: set; the screen reads %.3f right after, %u notifications inside the set call", g_brightness, g_probe_notes);
    probe_read(1); probe_read(10); probe_read(60); probe_read(180); probe_read(600);
}
// The game's scene is active (startGame, front_ios_focus_event 3): the set 3 s later, if it is still active then and the scene did not resign active and come back meanwhile (the
// generation: a block from an earlier become-active would otherwise set it less than 3 s after the latest, as the player closes Control Center)
static void probe_arm(void) {
    if (g_probe_state != 1) return;
    unsigned gen = ++g_probe_gen;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 3 * (int64_t)NSEC_PER_SEC), dispatch_get_main_queue(), ^{ if (gen == g_probe_gen) probe_set(); });
}
static void probe_start(void) {
    const char *e = getenv("DM_BRIGHT_PROBE"); double v = front_bright_probe_value(e);
    if (v < 0) { LOG("[RED] front end: DM_BRIGHT_PROBE=%.32s ignored: the probe takes a brightness from 0.05 to 1.0", e); return; }
    if (!v || g_probe_state) return;
    g_probe_value = v; g_probe_state = 1;
    LOG("front end: brightness probe (DM_BRIGHT_PROBE=%.3f): set once, 3 s after the game's scene is active; put back on resign active, in the background or at a program handoff", v);
    probe_arm();
}
static void probe_restore(const char *why) {   // before the set (state 1), it cancels a pending one instead
    if (g_probe_state == 1) g_probe_gen++;
    if (g_probe_state != 2 || !g_own_screen) return;
    double now = g_own_screen.brightness; g_probe_state = 3; g_probe_back_t = launch_s();
    g_probe_in_set = 1; g_own_screen.brightness = g_probe_from; g_probe_in_set = 0;
    g_brightness = g_own_screen.brightness;
    LOG("front end: brightness probe: put back %.3f (the screen read %.3f; %s, %.1f s after the set; %u notifications since it, %u of them the set's own)",
        g_probe_from, now, why, launch_s() - g_probe_t, g_probe_notes, g_probe_ours);
}
// Battery level and charging state for the power detail line (hle_nvn.c power_detail, DM_POWER_DETAIL): UIDevice is read on the main thread only, at start and on each change, and
// kept here for the thread that writes the power line. Battery monitoring is turned on only for that line
static _Atomic int g_bat_on, g_bat_pct = -1, g_bat_state;
static void battery_cache(void) {
    UIDevice *d = UIDevice.currentDevice; float l = d.batteryLevel; UIDeviceBatteryState s = d.batteryState;
    atomic_store(&g_bat_pct, l < 0 ? -1 : (int)lroundf(l * 100));
    atomic_store(&g_bat_state, s == UIDeviceBatteryStateUnplugged ? 1 : s == UIDeviceBatteryStateCharging ? 2 : s == UIDeviceBatteryStateFull ? 3 : 0);
}
int dm_power_source(int *pct, int *state, int *lpm) {
    *pct = atomic_load(&g_bat_pct); *state = atomic_load(&g_bat_state); *lpm = dm_low_power_now();
    return (atomic_load(&g_bat_on) ? 1 : 0) | 2;
}
static void front_ios_power_watch(void) {
    if (dm_power_detail_on()) {
        UIDevice.currentDevice.batteryMonitoringEnabled = YES; battery_cache(); atomic_store(&g_bat_on, 1);
        for (NSNotificationName nm in @[UIDeviceBatteryLevelDidChangeNotification, UIDeviceBatteryStateDidChangeNotification])
            [NSNotificationCenter.defaultCenter addObserverForName:nm object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { (void)n; battery_cache(); }];
    }
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenBrightnessDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *n) { bright_changed(n); }];
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: thermal state → %d (%.0f s after launch)", dm_thermal_now(), (now_ns() - g_t0_ns) / 1e9); dm_heat_poke(); }];   // the heat ladder samples at once
    // The heat ladder's 1 s timer (hle_nvn.c dm_heat_timer_tick; heat-ladder.md §7.1): it samples while no frames come (loads, the progress screen), and nothing while the app is away
    static dispatch_source_t heat_timer;
    heat_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(heat_timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 4);
    dispatch_source_set_event_handler(heat_timer, ^{ dm_heat_timer_tick(); });
    dispatch_resume(heat_timer);
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoPowerStateDidChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        (void)n; LOG("front end: Low Power Mode → %s (%.0f s after launch)", dm_low_power_now() ? "on" : "off", (now_ns() - g_t0_ns) / 1e9);
        dispatch_async(dispatch_get_main_queue(), ^{ screen_cache(g_screen); }); }];
    LOG("front end: thermal state %d, brightness %.2f, Low Power Mode %s", dm_thermal_now(), g_brightness, dm_low_power_now() ? "on" : "off");
    // The system's memory pressure: dm_gfx_pressure (hle_nvn.c) logs the footprint and the room to the memory limit, so a jetsam can be traced to memory, and gives back idle memory (DM_MEMORY_TRIM=0: logged only)
    static dispatch_source_t mp;
    mp = dispatch_source_create(DISPATCH_SOURCE_TYPE_MEMORYPRESSURE, 0, DISPATCH_MEMORYPRESSURE_NORMAL | DISPATCH_MEMORYPRESSURE_WARN | DISPATCH_MEMORYPRESSURE_CRITICAL, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
    dispatch_source_set_event_handler(mp, ^{ unsigned long d = dispatch_source_get_data(mp); dm_gfx_pressure(d & DISPATCH_MEMORYPRESSURE_CRITICAL ? 2 : d & DISPATCH_MEMORYPRESSURE_WARN ? 1 : 0); });
    dispatch_resume(mp);
}

// Vitals' level (DmVitals.m, NX18-X2.0 vitals.md §4): DM_SHOW_FPS (the launcher, Documents/env.txt) as 0 off, 1 Standard, 2 Detailed, or YES / NO; without it the IPA's DMShowFPS
// (the NSP script's SHOW_FPS / --show-fps; build_ipa.sh writes YES or NO, a number works too). YES is Standard: intValue alone would read "YES" as 0
static int front_ios_vitals_parse(const char *v) {
    if (!v) return 0;
    while (*v == ' ') v++;
    if (*v >= '0' && *v <= '9') { int n = atoi(v); return n < 0 ? 0 : n > 2 ? 2 : n; }
    return !strcasecmp(v, "YES") || !strcasecmp(v, "true") || !strcasecmp(v, "on");
}
static int front_ios_vitals_level(void) {
    const char *e = getenv("DM_SHOW_FPS");
    if (e) return front_ios_vitals_parse(e);
    id p = [NSBundle.mainBundle objectForInfoDictionaryKey:@"DMShowFPS"];
    if ([p isKindOfClass:NSNumber.class]) { int n = [p intValue]; return n < 0 ? 0 : n > 2 ? 2 : n; }
    return [p isKindOfClass:NSString.class] ? front_ios_vitals_parse([p UTF8String]) : 0;
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
            g_prog_title.font = dm_ui_font(20, UIFontWeightSemibold);
            g_prog_bar = [[UIProgressView alloc] initWithProgressViewStyle:UIProgressViewStyleDefault]; g_prog_bar.frame = CGRectMake(20, 48, 280, 4);
            g_prog_count = [[UILabel alloc] initWithFrame:CGRectMake(0, 64, 320, 22)]; g_prog_count.textAlignment = NSTextAlignmentCenter;
            g_prog_count.textColor = [UIColor colorWithWhite:0.72 alpha:1]; g_prog_count.font = dm_ui_mono_digits(13, UIFontWeightRegular);
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
void front_web_shown(void) { [g_root.view setNeedsLayout]; }   // web_apple.m: a page was shown or went: the touch controls go on their layers over it, or back into the frame
// An app of several programs (main.m: dm/programs.txt; DM_EXEC_OUT is set only there). iOS cannot start the app's process again, so oe::ExecuteProgram records the next program and the
// app ends (hle_oe.c); the next start runs it. To spare the player a silent quit, the app names the program on screen for 1.5 s, then schedules a local notification 1 s ahead that
// opens the app again ("Tap to start …"), then ends. Notifications are asked for at the first start of such an app; a player who refuses is asked on screen to open the app again.
// An app of one program that asks to start again (oe::RequestToRelaunchApplication: Super Smash Bros. Ultimate after a language change) cannot either: it asks the player on screen to
// open it again, for 3 s, then ends. No notification there: such an app never asked for them, and a prompt now would come as the app ends
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
static void handoff_notice(NSString *text) {   // the game is ending: no sound, and a line on a dark screen in its place
    dm_audio_suspend(1);
    dispatch_async(dispatch_get_main_queue(), ^{
        probe_restore("program handoff");   // the graceful exit that follows never resigns active: DM_BRIGHT_PROBE's value is put back here (nothing without the probe)
        UIWindow *w = g_root.view.window; if (!w) return;
        UIView *o = [[UIView alloc] initWithFrame:w.bounds]; o.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        o.backgroundColor = [UIColor colorWithWhite:0 alpha:0.85];
        UILabel *lb = [[UILabel alloc] initWithFrame:CGRectInset(o.bounds, 40, 0)]; lb.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        lb.numberOfLines = 0; lb.textAlignment = NSTextAlignmentCenter; lb.textColor = UIColor.whiteColor;
        lb.font = dm_ui_font(22, UIFontWeightSemibold); dm_ui_label_text(lb, text);
        [o addSubview:lb]; [w addSubview:o];
    });
}
// The GPU taken as lost (front.h; nvn_mtl.m gpu_watch: no GPU work finished for DM_GPU_LOST_S seconds with work waiting): save and quit instead of a frozen picture the player has
// to close from the app switcher, which also lost the cloud save's send. By now nothing more goes to the GPU and every wait on it has returned. A line on a dark screen takes the
// picture's place, and the graceful exit (hle_lifecycle.c dm_host_shutdown, on a thread of its own: it waits) sends the cloud save of what the game last saved, writes the pipeline
// archive and ends the process; past its own limit it ends it all the same. The next launch says so once (gpu_lost_note). Called on the watchdog's or Metal's feedback queue
static NSString *const kGpuLostNote = @"NX18GPULostNote";
void front_gpu_lost(void) {
    int why = mtl_gpu_lost_why();
    LOG("front end: the GPU %s; saving and quitting", why == 1 ? "access was revoked" : why == 3 ? "ran out of memory" : "finished no work for several seconds");
    [NSUserDefaults.standardUserDefaults setInteger:why forKey:kGpuLostNote]; [NSUserDefaults.standardUserDefaults synchronize];   // before the exit: the next launch's note
    handoff_notice(@"The game stopped responding.\nIt was closed to keep your save safe; open the app again to play on.");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ dm_host_shutdown("the GPU stopped responding"); });
}
// The next launch after front_gpu_lost: a log line and one alert as the game starts (the same notice the save failure shows), then the note is gone
static void gpu_lost_note(void) {
    NSInteger why = [NSUserDefaults.standardUserDefaults integerForKey:kGpuLostNote]; if (!why) return;
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kGpuLostNote];
    LOG("front end: the last session ended because the GPU stopped responding (reason %ld); telling the player", (long)why);
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *vc = g_root; while (vc.presentedViewController) vc = vc.presentedViewController;
        if (!vc) return;
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"The last session was closed"
                                                                   message:why == 3 ? @"The GPU ran out of memory, so NX 18 closed the game instead of leaving the phone frozen. Progress up to the game's last save is kept."
                                                                                    : @"The GPU stopped responding, so NX 18 closed the game instead of leaving it frozen. Progress up to the game's last save is kept."
                                                            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [vc presentViewController:a animated:YES completion:nil];
    });
}
void front_program_handoff(int index, const char *name) {   // front.h; on the guest thread that called oe::ExecuteProgram or oe::RequestToRelaunchApplication, before the graceful exit
    if (!multi_program()) {
        handoff_notice(@"The game restarts.\nOpen the app again to continue.");
        LOG("front end: the app ends to start again; the player is asked to open it again");
        usleep(3000 * 1000); return;
    }
    NSString *nm = name && *name ? @(name) : [NSString stringWithFormat:@"program %d", index];
    if (!notify_allowed()) {
        handoff_notice([NSString stringWithFormat:@"Open the app again to start %@.", nm]);
        LOG("front end: program %d starts at the next start of the app (notifications not allowed)", index);
        usleep(3000 * 1000); return;
    }
    handoff_notice([NSString stringWithFormat:@"Starting %@\u2026", nm]);
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
// so every callback came up 1.3 ms short and was zero-filled, about 47 gaps per second (crackling; reproducible on the Mac by forcing 1024-frame callbacks: 1999 underruns in 2000 callbacks). Ask for 5 ms and the system picks the nearest it supports
// (DM_AUDIO_IO_MS asks for 5-20 ms instead, a power A/B; the host's audio renderer then keeps more blocks in flight, audio_io.h);
// the category is Playback, as a game's or media app's: the ring / silent switch does not mute it (the default SoloAmbient follows the switch, which silenced the game whenever the phone was on silent) and it still interrupts other apps' audio.
// Set once at boot and again on return to the foreground (the system may reset it after an interruption)
static int g_session_off;   // the last activation failed (another app or a call still held the session): tried again when the app becomes active
// Six channels when the route takes them (HDMI, a multichannel interface or dock): the session's maximum is the route's, and it stays 2 on headphones, AirPods included.
// Asked at activation and again on each route change (front_ios_audio_watch), since a preference does not carry from one route to the next
static void front_ios_audio_channels(AVAudioSession *s) {
    NSError *e = nil; NSInteger most = s.maximumOutputNumberOfChannels, want = most >= 6 ? 6 : 2;
    if (want > 2 && ![s setPreferredOutputNumberOfChannels:want error:&e]) LOG("[RED] audio session: %ld output channels could not be set: %s", (long)want, e.localizedDescription.UTF8String);
    LOG("audio session: route %s, output channels %ld (route maximum %ld)", s.currentRoute.outputs.firstObject.portType.UTF8String ?: "(none)", (long)s.outputNumberOfChannels, (long)most);
}
void front_ios_audio_session(void) {
    AVAudioSession *s = AVAudioSession.sharedInstance; NSError *e = nil;
    if (![s setCategory:AVAudioSessionCategoryPlayback error:&e]) LOG("[RED] audio session category could not be set: %s", e.localizedDescription.UTF8String);
    [s setPreferredSampleRate:48000 error:nil];
    int ms = dm_audio_io_ms(); BOOL set = ms != 0; if (!set) ms = AUDIO_IO_MS_DEFAULT;   // DM_AUDIO_IO_MS (audio_io.h): another duration for a power A/B
    if (![s setPreferredIOBufferDuration:ms / 1000.0 error:&e]) LOG("[RED] audio session I/O buffer duration could not be set: %s", e.localizedDescription.UTF8String);
    g_session_off = ![s setActive:YES error:&e];
    if (g_session_off) LOG("[RED] audio session activation failed: %s", e.localizedDescription.UTF8String);
    LOG("audio session: sample rate %.0f Hz, I/O buffer %.2f ms (asked for %d ms%s)", s.sampleRate, s.IOBufferDuration * 1000, ms, set ? ", DM_AUDIO_IO_MS" : "");
    dm_audio_io_granted(s.IOBufferDuration);   // the host's audio renderer keeps a callback's worth and more in flight (nothing while the switch is unset)
    front_ios_audio_channels(s);   // six output channels where the route takes them (upstream 1af88aad6)
}
// The channels the route takes now (hle_audio.c decides the output from it: six only when the session has six)
int dm_ios_output_channels(void) { return (int)AVAudioSession.sharedInstance.outputNumberOfChannels; }

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
    // Route changes (AirPods or headphones connecting or going, an override, a category change): the host restarts its playing outputs on the new route at once instead of waiting for its
    // watchdog (dm_audio_route_change, hle_audio.c, which logs the one line). Handled on the posting thread, not the main queue: the host only queues the work. The outputs are compared by port
    // type and UID; the line names port types, the session's sample rate and I/O buffer, never a port's name (the owner chooses it: "…'s AirPods").
    // A new output (an HDMI adapter, a dock) is first asked for the channels it takes (upstream 1af88aad6): the host's route work gives a six-channel output a unit at the new count
    // before it restarts the others (route_sync in hle_audio.c). Not for a category change: that is the app's own setCategory at activation, on the same route
    [nc addObserverForName:AVAudioSessionRouteChangeNotification object:nil queue:nil usingBlock:^(NSNotification *n) {
        AVAudioSessionRouteChangeReason why = (AVAudioSessionRouteChangeReason)[n.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
        AVAudioSessionRouteDescription *was = n.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
        AVAudioSession *s = AVAudioSession.sharedInstance; AVAudioSessionRouteDescription *now = s.currentRoute;
        if (why != AVAudioSessionRouteChangeReasonCategoryChange) front_ios_audio_channels(s);
        NSString *(^ports)(AVAudioSessionRouteDescription *, BOOL) = ^NSString *(AVAudioSessionRouteDescription *r, BOOL uid) {
            NSMutableArray *a = [NSMutableArray array];
            for (AVAudioSessionPortDescription *p in r.outputs) [a addObject:uid ? [NSString stringWithFormat:@"%@/%@", p.portType, p.UID] : p.portType];
            return a.count ? [a componentsJoinedByString:@"+"] : @"none";
        };
        const char *r = why == AVAudioSessionRouteChangeReasonNewDeviceAvailable ? "new device available" : why == AVAudioSessionRouteChangeReasonOldDeviceUnavailable ? "old device unavailable" :
                        why == AVAudioSessionRouteChangeReasonCategoryChange ? "category change" : why == AVAudioSessionRouteChangeReasonOverride ? "override" :
                        why == AVAudioSessionRouteChangeReasonWakeFromSleep ? "wake from sleep" : why == AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory ? "no suitable route for the category" :
                        why == AVAudioSessionRouteChangeReasonRouteConfigurationChange ? "route configuration change" : "unknown reason";
        char d[256];
        snprintf(d, sizeof d, "%s: %s -> %s, %.0f Hz, I/O buffer %.2f ms", r, ports(was, NO).UTF8String, ports(now, NO).UTF8String, s.sampleRate, s.IOBufferDuration * 1000);
        dm_audio_io_granted(s.IOBufferDuration);   // a route can grant another buffer (DM_AUDIO_IO_MS only)
        dm_audio_route_change(d, !was || ![ports(was, YES) isEqualToString:ports(now, YES)]);
    }];
}

// Scene lifecycle (called by SceneDelegate in main.m): 0 resign active, 1 enter background, 2 return to foreground, 3 become active. On entering background, freeze the guest clock and suspend after in-flight GPU work completes (submitting GPU work in background gets the process killed).
// dm_gfx_suspend returns within about 3 s even when the GPU does not drain (hle_nvn.c: a red line and a dump, graphics left suspended, the archive's hand-over skipped), so the two
// background tasks after it always start: Ocarina of Time's test 3 froze once, and closing it from the app switcher then never got past dm_gfx_suspend, the cloud save with it
// The screen stays on while the game is active: only touches reset the idle timer, so with a controller (or during a cutscene) the screen dimmed and locked mid-game
// Cloud saves (save_sync.h): what the game committed goes out before iOS suspends the app, without the sender's quiet wait or gap. iOS gives a background task about half a minute.
// The send itself starts at the resign active (dm_focus_set 2, hle_oe.c), which is all a swipe in the app switcher leaves before it kills the app; the background's flush waits for it
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
        case 0: dm_movie_active(0); probe_restore("resign active"); dm_gamepad_reset(); dm_focus_set(2); dm_gfx_inactive(1); break;   // a swipe in the app switcher kills the app with no trip to the background: dm_gfx_inactive, and dm_focus_set starts the cloud save's send
        case 1: dm_state_background(1); dm_vitals_foreground(0); probe_restore("background"); UIApplication.sharedApplication.idleTimerDisabled = NO; dm_focus_set(3); dm_play_record_event(0); g_audio_bg = 1; front_ios_audio_apply(); guest_clock_freeze_for(1, 1); dm_gfx_suspend(1); archive_background(); save_sync_background(); break;
        case 2: dm_state_background(0); dm_vitals_foreground(1); dm_gfx_suspend(0); guest_clock_freeze_for(1, 0); front_ios_audio_session(); g_audio_bg = 0; front_ios_audio_apply(); dm_focus_set(2); break;
        case 3:   // Becoming active again also ends an interruption whose resumption recommendation never came (not every one sends it), and retries a session that would not activate on the way back
            UIApplication.sharedApplication.idleTimerDisabled = YES;
            if (g_audio_intr) { LOG("audio session: active again with no interruption-ended notice; resuming"); g_audio_intr = 0; g_session_off = 1; }
            if (g_session_off) front_ios_audio_session();
            front_ios_audio_apply(); dm_gamepad_active(); dm_focus_set(1); dm_gfx_inactive(0); probe_arm(); dm_play_record_event(1); dm_movie_active(1); break;   // dm_movie_active: a movie decoder iOS ended waits for this to start again (hle_movie_vt.h)
    }
}
