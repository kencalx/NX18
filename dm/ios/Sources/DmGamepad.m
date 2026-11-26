// Virtual gamepad (Nintendo button positions) + physical controllers (GameController), handed to the host through dm_input_set and dm_pad_set_player (hle_hid.c, bit layout in dm_input.h).
//   Two layouts, three in handheld mode, picked in the in-game menu (GameMenu.swift) that the menu button at the top centre (a ring with eight rays in a cyan-to-coral gradient, menuIcon) opens; the choice is kept in NSUserDefaults (each game is its own app, so per game); the first launch uses the game profile's pad_layout (DM_GAME_PAD_LAYOUT).
//   The menu is NX 18's panel (GameMenuPanel.swift; a tap on the button, or a controller's Home, opens and closes it), or with DM_GAME_MENU=system the UIMenu it always was, which UIKit opens from the button.
//   While the panel is open the controllers drive it and the game gets none of their input; once it closes, a button still held (the B that closed it) reaches the game only after it is let go.
//   The menu button is not hidden with the touch controls when a physical controller is connected, so the menu is there in every layout and with every controller (it still fades
//   after 5 s and comes back on a double tap, as below).
//   The menu button is hidden while playing: a double tap anywhere but on a drawn control (keys, diamond, D-pad, left stick) shows it, and it fades out again after 5 s
//   without a touch on it (the menu open keeps it; closing the menu starts the 5 s again). It shows from the start until 5 s after the game's first picture and after the
//   progress screen of a first start, "Preparing shaders" (dm_gamepad_hint), so a new player sees where it is; it stays while VoiceOver or Switch Control is on (turning either on shows it), and while an
//   offline HTML page is shown (touches off the controls go to the page, so a double tap cannot reach the pad). A double tap on a control is a double press, not a request
//   for the menu, so it never shows the button
//   Tap (touch): no control but the menu button, every other touch goes to the game's local touch viewport; offered only while the game is in handheld mode, the only one in which it reads the touch screen (Balatro, played by touch).
//   2D (simple): top corners ZL above L (one column), ZR above R likewise, teardrops with the tip toward the screen corner; − and + side by side at the top centre; the left stick in the bottom-left corner (its ring centres where the thumb lands while it is held, tilt measured from there, and goes home when let go, small dead zone);
//     the A (right) B (bottom) X (top) Y (left) diamond in the bottom-right corner, sliding a finger between keys switches keys. Each bottom corner holds a single control, so it sits close in (reaching halfway into the side safe-area inset).
//   3D (full, Pro Controller style): everything in 2D (left stick and diamond keep their place and size), plus a D-pad (inward of and below the left stick, 8-way), a right stick that is not drawn
//     (a touch landing in the right third of the screen on no control holds it: centred where it lands, the centre dragged along once the finger passes the stick radius) and L3 / R3 (small round keys in the top row, inward of ZL / ZR).
//     Breath of the Wild crouches with L3 and uses the scope with R3; 3D World and Breath of the Wild turn the camera with the right stick.
//   Touch-down ownership: the menu button where it is nearer than a locked key (a view of its own, DmMenuButton), locked keys next (shoulders, − / +, L3 / R3), then whichever of the diamond, the D-pad and the left stick has the smallest distance / grab radius (the left stick's grab circle borders the D-pad),
//     then in 3D the right stick for a touch in the right third.
//   Everything hugs the edges and corners to leave the picture room; controls sit over the picture, one CAShapeLayer each: a press only swaps the fill, a stick only moves its knob, nothing redraws the whole screen.
//   While they show with the game's picture on the phone, the present draws them into the game's frame instead and their layers stay hidden (touchDraw:, below; dm/host/touch_draw.h):
//   a layer over the game's made iOS composite the two, a refresh more of latency. This view takes every touch as before either way.
//   Touches no control takes (in 3D, those outside the right third) go to the game's touch screen when DmLayout assigns a local game viewport (pushGame; Super Mario Galaxy's pointer in handheld mode).
//   The virtual gamepad (all but the menu button) hides while a physical controller is connected and comes back when it is removed; unclaimed touches go to the game only when a local game viewport exists. Physical controllers keep every button (D-pad and right stick included) and map by position: bottom = B, right = A, left = Y, top = X (same positions as on a Switch controller); a Nintendo pad maps by its labels (pad_apple.h).
//   Each physical controller is a player of its own (local co-op), as on the Mac: the first one connected is player 1, together with the touch gamepad, the next player 2, and so on up to 8; see "Physical controllers" below.
//   Shaking the phone shakes the controller (DM_BTN_SHAKE: its six-axis sensor, hle_hid.c), whichever controls are in use; see "Shaking the phone" below.
#import <UIKit/UIKit.h>
#import <GameController/GameController.h>
#import <CoreMotion/CoreMotion.h>
#import <CoreText/CoreText.h>
#include <pthread.h>
#include "dm.h"
#include "dm_input.h"
#include "state_report.h"   // Menu while NX 18's panel shows
#import "DmVitals.h"   // Vitals over the picture hides while the panel shows; its header line keeps the figures coming
#include "front.h"
#include "ui_font.h"   // NX 18's UI font: the key letters and the controller prompt
#include "game_profile.h"
#include "haptics_apple.h"
#include "motion_apple.h"
#include "motion_fusion.h"
#include "pad_apple.h"
#include "pad_slots.h"
#include "ctrl_prompt.h"
#include "touch_draw.h"   // the controls drawn into the game's frame by the present (nvn_mtl.m touch_draw)
#import "DmCapture.h"   // the Capture button takes a screenshot
#include "pad_switch2_apple.h"   // Switch 2 controllers over Bluetooth LE, shared with the Mac front end (upstream PR #1900)
#include <stdatomic.h>
#import "DmLayout.h"
#import "DmGameMenu.h"

enum { B_A = 0, B_B, B_X, B_Y, B_LS, B_RS, B_L, B_R, B_ZL, B_ZR, B_PLUS, B_MINUS, B_LEFT, B_UP, B_RIGHT, B_DOWN, B_N };
enum { C_NONE = 0, C_STICK, C_DPAD, C_FACE, C_BTN, C_GAME };   // which control a touch holds; C_GAME: none, the touch goes to the game's touch screen (finger slot << 8)
enum { S_RING = B_N, S_KNOB, S_N };   // the pictures of the controls drawn into the game's frame: one per key, then the left stick's ring and knob (touchAtlas)

static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER;
static uint64_t g_touch_btn, g_shake_btn;
static int32_t g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry;
static void publish(void) {   // the touch gamepad and the shake; the host ORs them with player 1's controller and takes whichever stick is deflected more (hle_hid.c)
    pthread_mutex_lock(&g_mu);
    dm_input_set(g_touch_btn | g_shake_btn, g_touch_lx, g_touch_ly, g_touch_rx, g_touch_ry);
    pthread_mutex_unlock(&g_mu);
}

// ---- Shaking the phone ----
// The accelerometer at 60 Hz (no gyroscope, no permission prompt): gravity is followed by a slow low-pass (about 0.8 s), and a sample whose acceleration beyond it exceeds DM_SHAKE_G
// (1.5 G by default; Documents/env.txt overrides) is a hit. The controller is shaken until 120 ms after the last hit: a flick is one shake (the host finishes it as a whole cycle)
// and shaking on keeps it going. Holding the phone and pressing the screen stays far below the threshold. Each detected shake is logged with its peak
static CMMotionManager *g_motion;
static void motion_start(void) {
    if (g_motion) return;
    g_motion = [CMMotionManager new];
    if (!g_motion.accelerometerAvailable) { LOG("front end: no accelerometer, shaking the phone does nothing"); return; }
    const char *e = getenv("DM_SHAKE_G"); double thr = e && atof(e) > 0 ? atof(e) : 1.5;
    LOG("front end: shaking the phone shakes the controller (threshold %.2f G)", thr);
    g_motion.accelerometerUpdateInterval = 1.0 / 60;
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    __block double gx = 0, gy = 0, gz = 0, last = -1, peak = 0; __block BOOL init = NO;
    [g_motion startAccelerometerUpdatesToQueue:q withHandler:^(CMAccelerometerData *d, NSError *err) {
        (void)err; if (!d) return;
        CMAcceleration a = d.acceleration;
        if (!init) { gx = a.x; gy = a.y; gz = a.z; init = YES; }
        double dx = a.x - gx, dy = a.y - gy, dz = a.z - gz, g = sqrt(dx * dx + dy * dy + dz * dz);
        gx += (a.x - gx) * 0.02; gy += (a.y - gy) * 0.02; gz += (a.z - gz) * 0.02;
        if (g > thr) { if (last < 0) peak = 0; last = d.timestamp; peak = fmax(peak, g); }
        BOOL on = last >= 0 && d.timestamp - last < 0.12;
        if (!on && last >= 0) { LOG("front end: phone shaken (peak %.1f G)", peak); last = -1; }
        uint64_t want = on ? DM_BTN_SHAKE : 0;
        pthread_mutex_lock(&g_mu); BOOL changed = g_shake_btn != want; g_shake_btn = want; pthread_mutex_unlock(&g_mu);
        if (changed) publish();
    }];
}

// ---- The phone's gyro ----
// A controller mounted on the phone (Backbone One, Razer Kishi, GameSir G8) has no motion sensors of its own: the phone in the middle is the console, as a Switch in handheld.
// So the phone's device motion (gyro + accelerometer, CoreMotion's fused gravity and user acceleration, 100 Hz, no permission prompt) drives player 1's six-axis sensor, turned
// into the Switch frame for the screen's orientation (motion_phone_to_switch, motion_fusion.h): x to the right of the picture, y to its top, z toward the player.
// The host keeps phone and controller orientations separately, choosing fresh controller data in auto mode and the phone alone in forced mode.
// DM_PHONE_MOTION: auto (default) while no controller supplies fresh gyro data (a DualSense held apart from the phone uses its own, motion_apple.h), 1 always, 0 never.
// DM_MOTION=0 (all live motion off; the NSP script's --no-motion builds it in) never starts device motion.
// Which frame the samples come in: the pad view (full screen, over the picture) is the motion body (CMMotionManager.deviceMotionBody, iOS 27), so Core Motion delivers them in
// that view's frame for whichever display shows it and however it is turned: x to the right of the picture, y to its top, z toward the player, the Switch frame as it is.
// Without a body they come in the hardware frame, turned here by the interface orientation (g_iface_orient), which holds only where the hardware frame is the screen's portrait
// frame: not on iPhone Duo's inner display, whose picture is a quarter turn from it (up / down and left / right swapped, GitHub issue #569). Open: while the scene is not full screen
// (Split View on the inner display) Core Motion falls back to the hardware frame without saying so, and the samples are then taken as the view's frame (g_iface_orient, kept up
// to date on layout, would turn them, but nothing tells when the fallback is in force)
static _Atomic int g_iface_orient = 3;      // UIInterfaceOrientation, updated on layout
static BOOL g_motion_body;                  // samples in the body's frame (deviceMotionBody set)
static void phone_motion_start(UIView *body) {
    const char *e = getenv("DM_MOTION");
    if (e && !atoi(e)) { LOG("front end: motion is off (DM_MOTION=0), the phone's gyro is not used"); return; }
    e = getenv("DM_PHONE_MOTION"); int mode = !e || !strcmp(e, "auto") ? -1 : atoi(e);
    if (!mode) { LOG("front end: the phone's gyro is off (DM_PHONE_MOTION=0)"); return; }
    if (!g_motion.deviceMotionAvailable) { LOG("front end: no device motion, the phone's gyro is not used"); return; }
    LOG("front end: the phone's gyro drives the controller's six-axis sensor %s", mode < 0 ? "while no controller supplies fresh motion" : "always (DM_PHONE_MOTION=1)");
    g_motion.deviceMotionUpdateInterval = 1.0 / 100;
    g_motion.deviceMotionBody = body; g_motion_body = YES; LOG("front end: the phone's motion comes in the pad view's frame (deviceMotionBody)");
    NSOperationQueue *q = [NSOperationQueue new]; q.maxConcurrentOperationCount = 1;
    [g_motion startDeviceMotionUpdatesToQueue:q withHandler:^(CMDeviceMotion *d, NSError *err) {
        (void)err; if (!d) return;
        float a[3] = {(float)(d.gravity.x + d.userAcceleration.x), (float)(d.gravity.y + d.userAcceleration.y), (float)(d.gravity.z + d.userAcceleration.z)};
        float w[3] = {(float)d.rotationRate.x, (float)d.rotationRate.y, (float)d.rotationRate.z}, as[3], ws[3];
        int o = g_motion_body ? 1 : atomic_load(&g_iface_orient);   // the body's frame is already the picture's: the portrait map, which leaves it as it is
        motion_phone_to_switch(o, a, as); motion_phone_to_switch(o, w, ws);
        dm_motion_set_switch(0, as, ws);
    }];
}

// ---- Layout constants (in u; x measured from the outer edge, the right half mirrors) ----
static const CGFloat
    K_ZL_X = 44, K_ZL_Y = 40, K_ZL_R = 26,          // ZL / ZR: centre from the outer edge and the top, radius
    K_L_X = 44, K_L_Y = 108, K_L_R = 24,            // L / R: same column as ZL / ZR
    K_DROP_TIP = 1.45,                              // teardrop tip distance from the centre (times the radius)
    K_CORNER_IN = 0.5,                              // how far the bottom-corner controls reach into the side safe-area inset (in landscape there is only the rounded screen corner there; the Dynamic Island is mid-edge)
    K_FACE_X = 81, K_PAD_Y = 82,                    // diamond centre from the outer edge; diamond and stick centre from the bottom (B's lower edge about 5 above it)
    K_FACE_GAP = 50, K_FACE_R = 27,                 // diamond: key distance from the centre, key radius
    K_PILL_DX = 52, K_PILL_Y = 22, K_PILL_W = 50, K_PILL_H = 28,   // − / +: centre from the screen's midline (the middle goes to the layout button) and from the top, size
    K_MENU_R = 15,                                  // menu button: top centre, level with − / +; it takes a touch within 1.6 times this (at least 22 points, half of a 44-point target)
    K_STICK_X = 81, K_STICK_R = 77, K_KNOB_R = 30,  // left stick: mirrors the diamond, the ring as large as the whole diamond (key distance + key radius), the knob a little larger than a diamond key
    K_STICK_GRAB = 1.4,                             // how near the ring centre a touch-down grabs a stick (times the ring radius)
    K_FULL = 0.8,                                   // full tilt at this fraction of the ring radius (the knob still travels to the ring edge)
    K_DEAD = 0.1,                                   // stick dead zone (times the ring radius)
    // controls only the 3D layout has
    K_LOW_X = 231, K_LOW_Y = 64,                    // D-pad centre from the outer edge and the bottom (inward of and below the left stick, as on a Pro Controller)
    K_DPAD_R = 48, K_ARM_W = 17, K_ARM_IN = 11,     // D-pad: arm outer edge from the centre, half-width, tip from the centre
    K_DPAD_GRAB = 1.3,                              // D-pad grab radius (times the outer edge)
    K_RSTICK_R = 60,                                // right stick (not drawn): radius around its centre, the touch-down point
    K_RSWIPE = 1.0 / 3,                             // right stick area: this fraction of the screen width from the right edge (not in u)
    K_CLICK_X = 102, K_CLICK_R = 17;                // L3 / R3: centre from the outer edge (level with ZL / ZR), radius
static const int k_btns[] = {B_ZL, B_L, B_ZR, B_R, B_MINUS, B_PLUS, B_LS, B_RS};   // keys locked at touch-down (L3 / R3 only in the 3D layout)
static NSString *const k_layout_key = @"DmPadLayout";   // NSUserDefaults: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
int dm_opmode(void);   // hle_oe.c: 0 = handheld
int front_web_touch(void);   // web_apple.m: an offline HTML page is shown over the picture (hitTest, below)

@interface DmGamepad : UIView
- (void)arrange:(DmLayout)layout;
- (BOOL)menuTakes:(CGPoint)p;
- (void)menuTouched;
- (void)menuClosed;
- (void)menuOpenNow;
- (void)panelToggle;
@end
// The menu button: a UIButton that opens the in-game menu: with DM_GAME_MENU=system its menu is the UIMenu (UIKit draws it and takes the touches while it is open), else a tap
// opens or closes NX 18's panel (panelToggle). Its hit circle is larger than the drawn one, and a key nearer
// to the touch wins (− / + sit beside it), so it asks the pad
@interface DmMenuButton : UIButton
@end
@implementation DmMenuButton
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent *)e { DmGamepad *pad = (DmGamepad *)self.superview; return [pad menuTakes:[self convertPoint:p toView:pad]]; }
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [(DmGamepad *)self.superview menuTouched]; [super touchesBegan:ts withEvent:e]; }
- (void)contextMenuInteraction:(UIContextMenuInteraction *)i willEndForConfiguration:(UIContextMenuConfiguration *)c animator:(id<UIContextMenuInteractionAnimating>)a {
    if ([UIButton instancesRespondToSelector:_cmd]) [super contextMenuInteraction:i willEndForConfiguration:c animator:a];
    [(DmGamepad *)self.superview menuClosed];
}
@end
static __weak DmGamepad *g_view;
static __weak DmGamepad *g_touch_pad;   // the pad that last handed the present a frame (touchPublish): the present's answers go to it (front_touch_drawn, front_touch_unfit)
static void pads_start(void);   // Physical controllers, below
static void pads_release_game(void);

@implementation DmGamepad {
    NSMapTable<UITouch *, NSNumber *> *_owner;     // touch → control (with the key for C_BTN or the stick for C_STICK, << 8)
    UITouch *_stick[2]; CGPoint _stickNow[2];      // the touch holding each stick and where it is now (0 left, 1 right)
    CGPoint _rCentre;                              // the right stick's centre: where its touch landed, dragged along past K_RSTICK_R
    CGPoint _lCentre;                              // the left stick's centre while it is held: where its touch landed (Apple HIG, Game controls: a movement stick where the thumb lands); home when let go
    uint64_t _faceBits, _dpadBits, _btnBits;
    NSMapTable<UITouch *, NSNumber *> *_faceOf;    // which keys each touch on the diamond currently holds
    CAShapeLayer *_key[B_N]; CATextLayer *_label[B_N];   // one layer per key
    CAShapeLayer *_ring, *_knob;                   // the left stick (the right one is not drawn)
    DmMenuButton *_menu;                           // opens the in-game menu (GameMenu.swift)
    NSUInteger _menuGen; BOOL _menuOpen;           // the menu button's hide timer (each show or touch starts a new one) and whether its menu is open
    BOOL _systemMenu;                              // DM_GAME_MENU=system: the button opens the UIMenu (dm_game_menu), else NX 18's panel (dm_game_panel_open)
    UIImpactFeedbackGenerator *_touchFeedback;       // one short feedback per touch-control press edge
    unsigned _hapticSticks;
    BOOL _stickShown;                              // the left stick was held at the last refresh
    BOOL _full, _tap;                              // the 3D layout / the Tap layout is current
    CALayer *_controls;                            // holds every control layer: hidden while a physical controller is connected (the view itself stays, for game touches), and while the present draws them
    // The controls drawn into the game's frame (dm/host/touch_draw.h): front_ios.m turns it on (touchDraw:) with the canvas, the game view's frame (pad points), its pixels a
    // point and the picture's place on it. A picture of each control at those pixels, normal and pressed (touchAtlas: the control layers themselves rendered, so they look as
    // they did), goes to the present once per look; each change of a press or the knob hands it a frame of quads (touchPublish). The layers hide only once a present that drew
    // the controls completed (_inFrame, front_touch_drawn), and show again while the canvas changes (until the pictures are made for it), while the game presents nothing
    // (a press would not show until the next present) and when the drawable stops fitting the frame (front_touch_unfit)
    BOOL _touchDraw, _inFrame, _sprites; CGRect _canvas, _canvasPic; CGFloat _canvasScale;
    uint32_t _ackFrom;                             // the first frame after the last change, whose drawing (or a later one's) hides the layers; 0: none published yet
    uint32_t _offs;                                // times the present stopped drawing them (touchDraw: off): the frame is cleared after the last one only
    NSData *_atlasKey; uint32_t _atlasGen; BOOL _atlasOK;
    CGRect _spritePt[S_N];                         // each picture's rectangle in its layer's points (the knob's in its own bounds), whole pixels
    CGRect _spriteUV[S_N][2];                      // where it is in the atlas, normalized: normal [0] and pressed [1] (the ring has one look)
    BOOL _padOff;                                  // a physical controller is connected: every touch goes to the game
    DmLayout _layout;
    UITouch *_game[16];                            // touches on the game's touch screen by finger slot
}

// Touch control size and opacity (the settings screen's and the in-game menu's rows, DM_TOUCH_SIZE and DM_TOUCH_OPACITY; main thread). The size multiplies u, so every control, its distance from
// the edges and corners and its hit area follow it: Large (1) is the size the controls always had, Medium 0.85 and Small 0.7. An iPad already draws them larger (u is capped at 1.3, and its
// points are larger: about 1.5 times an iPhone's physical size), so Small there is about an iPhone's Large. The opacity multiplies each colour's own alpha (Normal, 1, is the look they
// always had; capped at 1) and the shadows' (at most theirs). The menu button keeps the normal look, so the menu that changes them stays easy to find
static CGFloat g_touch_size = 1, g_touch_opacity = 1;
static CGFloat touch_value(const char *name, const char *v, CGFloat lo, CGFloat hi) {   // a size or opacity: 1 when unset or out of range
    if (!v || !*v) return 1;
    char *end; double x = strtod(v, &end);
    if (end == v || *end || !(x >= lo && x <= hi)) { LOG("[RED] front end: %s=%s: a number from %.1f to %.1f; keeping 1", name, v, lo, hi); return 1; }
    return x;
}
static UIColor *k_idle, *k_on, *k_line, *k_ringFill, *k_text, *k_textOn;
static void make_colors(CGFloat o) {   // each colour carries its own low opacity instead of lowering the whole view's alpha (that would add an off-screen pass for the full-screen layer)
    k_idle = [UIColor colorWithWhite:1 alpha:MIN(0.14 * o, 1)]; k_on = [UIColor colorWithWhite:1 alpha:MIN(0.45 * o, 1)]; k_line = [UIColor colorWithWhite:1 alpha:MIN(0.38 * o, 1)];
    k_ringFill = [UIColor colorWithWhite:1 alpha:MIN(0.06 * o, 1)]; k_text = [UIColor colorWithWhite:1 alpha:MIN(0.6 * o, 1)]; k_textOn = [UIColor colorWithWhite:0 alpha:MIN(0.7 * o, 1)];
}
static float shadow_opacity(void) { return 0.2f * (float)MIN(g_touch_opacity, 1); }
// A pressed key or a held knob glows past its edge (Apple HIG, Game controls: a press state players see even when the finger covers the control): its drop shadow becomes a
// soft white halo while it is down, in the layers and in the atlas's pressed pictures alike, so the present draws the same. K_GLOW_R: the halo's blur radius (points)
enum { K_GLOW_R = 8 };
static void press_glow(CAShapeLayer *l, BOOL on) {
    if (on) { l.shadowColor = UIColor.whiteColor.CGColor; l.shadowOpacity = (float)MIN(0.6 * g_touch_opacity, 0.9); l.shadowRadius = K_GLOW_R; l.shadowOffset = CGSizeZero; }
    else { l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = shadow_opacity(); l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1); }
}
static CAShapeLayer *shape(CALayer *parent) {
    CAShapeLayer *l = [CAShapeLayer layer];
    l.fillColor = k_idle.CGColor; l.strokeColor = k_line.CGColor; l.lineWidth = 1.5;
    l.shadowColor = UIColor.blackColor.CGColor; l.shadowOpacity = shadow_opacity(); l.shadowRadius = 3; l.shadowOffset = CGSizeMake(0, 1);
    [parent addSublayer:l]; return l;
}
static CATextLayer *label(CALayer *parent, NSString *s) {
    CATextLayer *t = [CATextLayer layer];
    t.string = s; t.alignmentMode = kCAAlignmentCenter; t.foregroundColor = k_text.CGColor;
    [parent addSublayer:t]; return t;
}
static BOOL fullOnly(int b) { return b == B_LS || b == B_RS || b >= B_LEFT; }   // keys shown only in the 3D layout

- (instancetype)initWithFrame:(CGRect)f {
    if ((self = [super initWithFrame:f])) {
        _layout = dm_layout(self.bounds, UIEdgeInsetsZero, NO, CGRectNull, DM_PICTURE_16_9);   // until the front end arranges it
        [self registerForTraitChanges:@[UITraitDisplayScale.class] withHandler:^(id<UITraitEnvironment> environment, UITraitCollection *previous) {
            [(UIView *)environment setNeedsLayout];
        }];
        self.multipleTouchEnabled = YES; self.opaque = NO; self.backgroundColor = UIColor.clearColor;
        const char *feedback = getenv("DM_TOUCH_HAPTICS");
        if (!feedback || atoi(feedback)) {
            _touchFeedback = [UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleLight forView:self];   // an interaction of this view (setTouchFeedback: removes it)
            [_touchFeedback prepare];
        }
        _owner = [NSMapTable strongToStrongObjectsMapTable]; _faceOf = [NSMapTable strongToStrongObjectsMapTable];
        g_touch_size = touch_value("DM_TOUCH_SIZE", getenv("DM_TOUCH_SIZE"), 0.5, 1); g_touch_opacity = touch_value("DM_TOUCH_OPACITY", getenv("DM_TOUCH_OPACITY"), 0.1, 2);
        if (g_touch_size != 1 || g_touch_opacity != 1) LOG("front end: touch controls at size %.2f, opacity %.2f (DM_TOUCH_SIZE, DM_TOUCH_OPACITY)", g_touch_size, g_touch_opacity);
        make_colors(1); UIColor *menuFill = k_idle, *menuLine = k_line;   // the menu button's: the normal look
        make_colors(g_touch_opacity);
        _controls = [CALayer layer]; [self.layer addSublayer:_controls];
        _ring = shape(_controls); _ring.fillColor = k_ringFill.CGColor;
        _knob = shape(_controls);
        CAShapeLayer *in = [CAShapeLayer layer]; in.fillColor = nil; in.strokeColor = k_line.CGColor; in.lineWidth = 1.5;   // inner ring of the knob
        [_knob addSublayer:in];
        static NSString *const names[B_N] = {@"A", @"B", @"X", @"Y", @"L3", @"R3", @"L", @"R", @"ZL", @"ZR", @"+", @"−"};
        for (int b = 0; b < B_N; b++) {
            _key[b] = shape(_controls);
            if (names[b]) _label[b] = label(_key[b], names[b]);   // the D-pad arms carry no label
        }
        _menu = [DmMenuButton buttonWithType:UIButtonTypeCustom];
        _menu.backgroundColor = menuFill; _menu.layer.borderColor = menuLine.CGColor; _menu.layer.borderWidth = 1.5;
        _menu.layer.shadowColor = UIColor.blackColor.CGColor; _menu.layer.shadowOpacity = 0.2; _menu.layer.shadowRadius = 3; _menu.layer.shadowOffset = CGSizeMake(0, 1);
        _menu.tintColor = [UIColor colorWithRed:0 green:0xC8 / 255.0 blue:0xF5 / 255.0 alpha:1]; _menu.accessibilityLabel = @"Menu";   // NX 18's cyan (LauncherRow.swift NX18Palette): the UIMenu's ticks, as on the settings screen
        const char *gm = getenv("DM_GAME_MENU"); _systemMenu = gm && !strcmp(gm, "system");
        __weak DmGamepad *weakSelf = self;
        if (_systemMenu) {   // the UIMenu, which UIKit opens from the button and closes itself
            LOG("front end: in-game menu: the system's menu (DM_GAME_MENU=system)");
            _menu.menu = CFBridgingRelease(dm_game_menu()); _menu.showsMenuAsPrimaryAction = YES;
            [_menu addAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; [weakSelf menuOpened]; [weakSelf reset]; }] forControlEvents:UIControlEventMenuActionTriggered];   // the menu opens: release every key and touch first
        } else {
            if (gm && *gm) LOG("[RED] front end: DM_GAME_MENU=%s: only system is known; NX 18's menu", gm);
            [_menu addAction:[UIAction actionWithHandler:^(UIAction *a) { (void)a; [weakSelf panelToggle]; }] forControlEvents:UIControlEventPrimaryActionTriggered];   // a tap (VoiceOver's too) opens it, or closes it
        }
        [self addSubview:_menu];   // shown from here until 5 s after the game's first picture (dm_gamepad_hint), then on a double tap
        NSNumber *saved = [NSUserDefaults.standardUserDefaults objectForKey:k_layout_key];
        int l = saved ? (int)saved.integerValue : DM_GAME_PAD_LAYOUT;
        if (l == 2 && dm_opmode() != 0) l = 0;   // Tap only in handheld mode (env.txt's DM_OPMODE may have changed it)
        _full = l == 1; _tap = l == 2;
        [self applyLayout];
        NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidConnectNotification object:nil];
        [nc addObserver:self selector:@selector(padsChanged:) name:GCControllerDidDisconnectNotification object:nil];
        [nc addObserver:self selector:@selector(assistiveChanged:) name:UIAccessibilityVoiceOverStatusDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(assistiveChanged:) name:UIAccessibilitySwitchControlStatusDidChangeNotification object:nil];
        pads_start();
        [self padsChanged:nil];
        motion_start();
        phone_motion_start(self);
    }
    return self;
}
- (void)applyLayout {   // show / hide the controls for the current layout
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) _key[b].hidden = _tap || (fullOnly(b) && !_full);
    _ring.hidden = _knob.hidden = _tap;
    [CATransaction commit];
}
// The menu button's visibility (see the top of this file): shown, then faded out 5 s after the last show or touch unless its menu is open
static const NSTimeInterval k_menu_hide_s = 5;
static BOOL assistive_running(void) { return UIAccessibilityIsVoiceOverRunning() || UIAccessibilityIsSwitchControlRunning(); }   // the menu button stays while either runs
- (void)menuShow {
    if (_menu.hidden || _menu.alpha < 1) { _menu.hidden = NO; [UIView animateWithDuration:0.2 animations:^{ self->_menu.alpha = 1; }]; }
    [self menuScheduleHide];
}
- (void)menuScheduleHide {
    NSUInteger g = ++_menuGen;
    __weak DmGamepad *w = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(k_menu_hide_s * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DmGamepad *me = w;
        if (!me || g != me->_menuGen || me->_menuOpen || assistive_running()) return;
        if (front_web_touch()) { [me menuScheduleHide]; return; }   // an offline HTML page is shown: a double tap off the controls reaches the page, not the pad (hitTest), so the button stays; it fades at most 5 s after the page goes
        [UIView animateWithDuration:0.35 animations:^{ me->_menu.alpha = 0; } completion:^(BOOL done) { (void)done; if (g == me->_menuGen && !me->_menuOpen) me->_menu.hidden = YES; }];
    });
}
// VoiceOver or Switch Control turned on or off: the button shows, so either can reach it (a hidden button is no accessibility element, and VoiceOver's double tap activates the
// focused element instead of reaching touchesBegan); the hide timer keeps it while either runs, and once both are off it fades 5 s later
- (void)assistiveChanged:(NSNotification *)n { (void)n; dispatch_async(dispatch_get_main_queue(), ^{ [self menuShow]; }); }
- (void)menuTouched { [self menuShow]; }
// The freeze detector (dm/host/stall.c) holds off while the menu is open: the game may stand still behind it. The system UIMenu's close comes from willEnd or, when that never
// came, from the next touch on the game (menuClosed), which only holds the detector off longer
// The log hears each open and close through the same two methods (hle_oe.c dm_front_menu_set: "front end: in-game menu open" / "... closed after N s"). UIKit draws the menu over
// the game on the same GPU, and 13 Sentinels on an iPhone showed GPU spikes and dropped frames while it was open that the log could not tell from the game's own; the long-frame
// lines and the 300-frame windows now say which frames were made under the menu (hle_nvn.c front_ui). Each close is reported once: willEnd clears _menuOpen, so the touch on the
// game that also closes the menu (touchesBegan) reports one only when willEnd never came. The host ignores a repeated report all the same. Both of NX 18's menus (the panel and
// DM_GAME_MENU=system's UIMenu) reach these two, so the detector and the log always see the same menu
- (void)menuOpened { _menuOpen = YES; _menuGen++; _menu.hidden = NO; _menu.alpha = 1; dm_stall_menu(1); dm_front_menu_set(1, NULL); }
- (void)menuClosed { _menuOpen = NO; dm_stall_menu(0); dm_front_menu_set(0, NULL); [self menuScheduleHide]; }
// A home screen shortcut (dm_gamepad_menu_open): the button shows at once (a faded or hidden one does not open its menu) and its menu opens on the next main-queue turn, as a tap does
// (UIControl performPrimaryAction presents a menu-as-primary-action button's menu)
- (void)menuOpenNow {
    [_menu.layer removeAllAnimations]; _menu.hidden = NO; _menu.alpha = 1; [self menuScheduleHide];
    __weak DmGamepad *w = self;
    dispatch_async(dispatch_get_main_queue(), ^{ DmGamepad *me = w; if (me && me.window) { if (me->_systemMenu) [me->_menu performPrimaryAction]; else [me panelOpen]; } });
}
// NX 18's panel (GameMenuPanel.swift): every key and touch released and the controllers taken from the game first, as the UIMenu's opening releases them; it calls
// dm_gamepad_panel_closed as it starts to close
- (void)panelOpen {
    if (_systemMenu || dm_game_panel_shown()) return;
    [_menu.layer removeAllAnimations];
    [self menuOpened]; [self reset]; pads_release_game();
    if (dm_game_panel_open((__bridge void *)_menu)) { dm_state_menu(1); dm_vitals_menu_open(1); }
    else dm_gamepad_panel_closed();
}
- (void)panelToggle { if (dm_game_panel_shown()) dm_game_panel_close(); else [self panelOpen]; }
- (int)padLayout { return _tap ? 2 : _full ? 1 : 0; }
- (int)touchHidden { return _padOff ? 1 : _tap ? 2 : 0; }   // dm_gamepad_touch_hidden
- (void)setPadLayout:(int)l {   // the in-game menu's pick: release every touch first (no key stays held), save, lay out again
    if (l == 2 && dm_opmode() != 0) l = 0;
    [self reset];
    _full = l == 1; _tap = l == 2;
    [NSUserDefaults.standardUserDefaults setObject:@(l) forKey:k_layout_key];
    [self applyLayout]; [self setNeedsLayout]; [self.superview setNeedsLayout];   // Tap draws no control: the front end takes the game view back to the picture
}
- (void)opmodeChanged {   // docked: the Tap layout goes (the game reads no touch screen then), unsaved, so handheld mode at the next start brings it back
    if (!_tap || dm_opmode() == 0) return;
    [self reset]; _tap = NO; _full = NO; [self applyLayout]; [self setNeedsLayout]; [self.superview setNeedsLayout];
}
- (void)setTouchFeedback:(BOOL)on {
    if (!on) { if (_touchFeedback) [self removeInteraction:_touchFeedback]; _touchFeedback = nil; return; }   // the generator is one of this view's interactions: it goes with it
    if (!_touchFeedback) { _touchFeedback = [UIImpactFeedbackGenerator feedbackGeneratorWithStyle:UIImpactFeedbackStyleLight forView:self]; [_touchFeedback prepare]; }
}
- (void)setTouchSize:(CGFloat)s {   // the in-game menu's Touch control size: every touch released first (a held stick's centre moves), then laid out again, hit areas included
    if (s == g_touch_size) return;
    [self reset]; g_touch_size = s; [self setNeedsLayout];
}
- (void)setTouchOpacity:(CGFloat)o {   // the in-game menu's Touch control opacity: new colours, and every layer and label takes them (shape() and label() set them only when a layer is made)
    if (o == g_touch_opacity) return;
    g_touch_opacity = o; make_colors(o);
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    float sh = shadow_opacity();
    _ring.strokeColor = _knob.strokeColor = k_line.CGColor; _ring.fillColor = k_ringFill.CGColor; _ring.shadowOpacity = _knob.shadowOpacity = sh;
    for (CALayer *l in _knob.sublayers) if ([l isKindOfClass:CAShapeLayer.class]) ((CAShapeLayer *)l).strokeColor = k_line.CGColor;   // the knob's inner ring
    for (int b = 0; b < B_N; b++) { _key[b].strokeColor = k_line.CGColor; _key[b].shadowOpacity = sh; }
    [CATransaction commit];
    [self refresh];   // the keys' and the knob's fills and the labels' colour, pressed or not
}

// ---- Layout (points; computed inside the safe area) ----
- (void)arrange:(DmLayout)layout {
    if (CGRectEqualToRect(_layout.controls, layout.controls) && CGRectEqualToRect(_layout.game, layout.game) && _layout.separated == layout.separated && _layout.topSafeOnly == layout.topSafeOnly) return;
    [self reset];   // A finger held across a pose change must not leave a key or game touch stuck.
    _layout = layout;
    [self setNeedsLayout];
}
- (CGRect)safe { return CGRectIntersection(_layout.controls, UIEdgeInsetsInsetRect(self.bounds, dm_game_safe_insets(self.bounds, self.safeAreaInsets, _layout.topSafeOnly))); }
- (CGRect)corner { if (_layout.separated) return self.safe; UIEdgeInsets i = self.safeAreaInsets; i.left *= K_CORNER_IN; i.right *= K_CORNER_IN; return UIEdgeInsetsInsetRect(self.bounds, i); }   // the rectangle the bottom-corner controls use
- (CGFloat)u { if (_layout.separated) { CGRect s = self.safe; return MIN(MIN(s.size.height / 430.0, s.size.width / 700.0), 1.3) * g_touch_size; } return MIN(self.bounds.size.height / 430.0, 1.3) * g_touch_size; }   // 1 = 430 points tall (iPhone Pro Max landscape), times Touch control size
static CGPoint side(CGRect s, int right, CGFloat dx, CGFloat y) { return CGPointMake(right ? CGRectGetMaxX(s) - dx : CGRectGetMinX(s) + dx, y); }
- (BOOL)portraitControls { return _layout.separated && self.bounds.size.height > self.bounds.size.width; }
- (CGPoint)portraitThumbCenter:(BOOL)right {
    CGRect s = self.safe;
    return CGPointMake(CGRectGetMinX(s) + s.size.width * (right ? 0.72 : 0.28),
                       CGRectGetMinY(s) + s.size.height * 0.58);
}
- (CGPoint)faceCenter { CGRect s = self.corner; CGFloat u = self.u;
    if (self.portraitControls) return [self portraitThumbCenter:YES];
    CGFloat edge = _layout.separated ? self.faceGap + self.faceHitR : 0;
    return side(s, 1, MAX(K_FACE_X * u, edge), CGRectGetMaxY(s) - MAX(K_PAD_Y * u, edge)); }
- (CGFloat)faceGap { return K_FACE_GAP * self.u; }
- (CGFloat)faceR { return K_FACE_R * self.u; }
// Touch targets keep Apple's minimums at every Touch control size (HIG, Game controls: 44 pt for the frequent controls, 28 pt for the rest): the drawing shrinks, the target
// stops at 22 pt of radius (the diamond's at 85% of its key spacing, so a touch between two keys still presses one or both as at the larger sizes, never three)
- (CGFloat)faceHitR { return MAX(self.faceR * 1.25, _layout.separated ? 22 : MIN(22, self.faceGap * 0.85)); }
- (CGPoint)facePos:(int)b { CGPoint c = self.faceCenter; CGFloat g = self.faceGap;
    switch (b) { case B_A: return CGPointMake(c.x + g, c.y); case B_B: return CGPointMake(c.x, c.y + g); case B_X: return CGPointMake(c.x, c.y - g); default: return CGPointMake(c.x - g, c.y); } }
- (CGPoint)stickHome {
    if (self.portraitControls) {
        CGPoint p = [self portraitThumbCenter:NO];
        if (_full) p.x -= self.dpadR + 6 * self.u;
        return p;
    }
    CGRect s = self.corner;
    return side(s, 0, K_STICK_X * self.u, CGRectGetMaxY(s) - K_PAD_Y * self.u);
}
- (CGPoint)stickCentre:(int)i { return i ? _rCentre : _stick[0] ? _lCentre : self.stickHome; }
- (CGPoint)ringShift { if (!_stick[0]) return CGPointZero; CGPoint h = self.stickHome; return CGPointMake(_lCentre.x - h.x, _lCentre.y - h.y); }   // the drawn ring follows the held stick's centre
- (CGFloat)stickR:(int)i { return i ? K_RSTICK_R * self.u / g_touch_size : K_STICK_R * self.u; }   // the right stick is not drawn: its swipe keeps the Large length whatever Touch control size
- (BOOL)inRightArea:(CGPoint)p { CGRect b = _layout.controls; return p.x >= CGRectGetMaxX(b) - b.size.width * K_RSWIPE; }
- (CGPoint)dpadCenter {
    if (self.portraitControls) {
        CGPoint p = [self portraitThumbCenter:NO];
        p.x += [self stickR:0] + 6 * self.u;
        return p;
    }
    CGRect s = self.corner; CGFloat u = self.u;
    return side(s, 0, K_LOW_X * u, CGRectGetMaxY(s) - K_LOW_Y * u);
}
- (CGFloat)dpadR { return K_DPAD_R * self.u; }
static BOOL isDrop(int b) { return b == B_ZL || b == B_L || b == B_ZR || b == B_R; }
static BOOL isClick(int b) { return b == B_LS || b == B_RS; }
- (CGPoint)dropCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; BOOL z = b == B_ZL || b == B_ZR;
    CGFloat edge = _layout.separated ? 22 : 0;
    return side(s, b == B_ZR || b == B_R, MAX((z ? K_ZL_X : K_L_X) * u, edge), CGRectGetMinY(s) + MAX((z ? K_ZL_Y : K_L_Y) * u, edge)); }
- (CGFloat)dropR:(int)b { return (b == B_ZL || b == B_ZR ? K_ZL_R : K_L_R) * self.u; }
- (CGPoint)clickCenter:(int)b { CGRect s = self.safe; CGFloat u = self.u; CGFloat edge = _layout.separated ? 22 : 0;
    return side(s, b == B_RS, MAX(K_CLICK_X * u, edge), CGRectGetMinY(s) + MAX(K_ZL_Y * u, edge)); }
- (CGRect)pillRect:(int)b { CGRect s = self.safe; CGFloat u = self.u, w = K_PILL_W * u, h = K_PILL_H * u;
    CGPoint c = CGPointMake(CGRectGetMidX(s) + (b == B_PLUS ? K_PILL_DX : -K_PILL_DX) * u, CGRectGetMinY(s) + MAX(K_PILL_Y * u, _layout.separated ? 14 : 0));   // − on the left, + on the right
    return CGRectMake(c.x - w / 2, c.y - h / 2, w, h); }
- (CGPoint)menuCenter { CGRect s = self.safe; return CGPointMake(CGRectGetMidX(s), CGRectGetMinY(s) + MAX(K_PILL_Y * self.u, _layout.separated ? 14 : 0)); }

static CGFloat dist(CGPoint a, CGPoint b) { return hypot(a.x - b.x, a.y - b.y); }
- (CGFloat)buttonDistance:(int)b point:(CGPoint)p {
    CGFloat u = self.u;
    if (isDrop(b)) return dist(p, [self dropCenter:b]) / MAX([self dropR:b] * 1.35, 22);   // 44 pt at least (faceHitR)
    if (isClick(b)) return dist(p, [self clickCenter:b]) / MAX(K_CLICK_R * u * 1.35, _layout.separated ? 22 : 14);   // L3 / R3: 28 pt at least
    CGRect r = CGRectInset([self pillRect:b], -8 * u, -8 * u);
    CGFloat w = MAX(r.size.width, 28), h = MAX(r.size.height, 28);   // − / +: 28 pt at least
    if (!_layout.separated && !CGRectContainsPoint(CGRectInset(r, -(w - r.size.width) / 2, -(h - r.size.height) / 2), p)) return CGFLOAT_MAX;
    return MAX(fabs(p.x - CGRectGetMidX(r)) / (w / 2), fabs(p.y - CGRectGetMidY(r)) / (h / 2));
}
- (int)btnAt:(CGPoint)p {   // Locked at touch-down; nearest normalized target wins overlapping separated-layout hits.
    int best = -1; CGFloat distance = 1;
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (fullOnly(b) && !_full) continue;
        CGFloat d = [self buttonDistance:b point:p];
        if (d <= 1 && (best < 0 || d < distance)) {
            best = b; distance = d;
            if (!_layout.separated) return b;
        }
    }
    return best;
}
- (CGFloat)menuDistance:(CGPoint)p { return dist(p, self.menuCenter) / MAX(K_MENU_R * self.u * 1.6, 22); }
- (BOOL)menuTakes:(CGPoint)p {   // the menu button takes a touch in its hit circle unless a locked key's target is nearer (the drawn keys are hidden in Tap and with a controller)
    CGFloat d = [self menuDistance:p]; if (d > 1) return NO;
    if (_tap || _padOff || (_layout.separated && !CGRectContainsPoint(_layout.controls, p))) return YES;
    int hit = [self btnAt:p];
    return hit < 0 || d < [self buttonDistance:hit point:p];
}
- (uint64_t)faceAt:(CGPoint)p {   // keys under the finger in the diamond (between two keys both count)
    uint64_t m = 0; CGFloat r = self.faceHitR;
    for (int b = B_A; b <= B_Y; b++) if (dist(p, [self facePos:b]) <= r) m |= 1ull << b;
    return m;
}
- (uint64_t)dpadAt:(CGPoint)p {   // 8 directions: 45° each, diagonals press two keys; a small centre circle counts as none
    CGPoint c = self.dpadCenter; CGFloat dx = p.x - c.x, dy = p.y - c.y;
    if (hypot(dx, dy) < self.dpadR * 0.25) return 0;
    double a = atan2(-dy, dx) * 180 / M_PI; uint64_t m = 0;
    if (a > -67.5 && a < 67.5) m |= 1ull << B_RIGHT;
    if (a > 22.5 && a < 157.5) m |= 1ull << B_UP;
    if (a > 112.5 || a < -112.5) m |= 1ull << B_LEFT;
    if (a < -22.5 && a > -157.5) m |= 1ull << B_DOWN;
    return m;
}
- (CGPoint)knobOffset:(int)i {   // knob offset from the stick centre (clamped to the stick radius)
    if (!_stick[i]) return CGPointZero;
    CGPoint h = [self stickCentre:i]; CGFloat dx = _stickNow[i].x - h.x, dy = _stickNow[i].y - h.y, d = hypot(dx, dy), R = [self stickR:i];
    if (d > R) { dx *= R / d; dy *= R / d; }
    return CGPointMake(dx, dy);
}

// ---- Touch ----
- (void)recompute {
    uint64_t face = 0; for (UITouch *t in _faceOf) face |= [_faceOf objectForKey:t].unsignedLongLongValue;
    uint64_t btn = 0, dpad = 0;
    for (UITouch *t in _owner) { uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff);
        if (c == C_BTN) btn |= 1ull << (v >> 8);
        else if (c == C_DPAD) dpad |= [self dpadAt:[t locationInView:self]]; }
    int32_t ax[4] = {0};
    for (int i = 0; i < 2; i++) {
        CGPoint o = [self knobOffset:i]; CGFloat R = [self stickR:i], d = hypot(o.x, o.y), dz = R * K_DEAD;
        if (d <= dz) continue;
        CGFloat m = fmin((d - dz) / (R * K_FULL - dz), 1) / d;   // outside the dead zone: 0 rising to full at the full-tilt radius
        ax[i * 2] = (int32_t)lrint(o.x * m * 32767); ax[i * 2 + 1] = (int32_t)lrint(-o.y * m * 32767);   // host: up is positive; rounded so full tilt is exactly 32767
    }
    BOOL changed = face != _faceBits || dpad != _dpadBits || btn != _btnBits;
    uint64_t pressed = (face | dpad | btn) & ~(_faceBits | _dpadBits | _btnBits);
    unsigned gripping = (_stick[0] ? 1u : 0) | (_stick[1] ? 2u : 0);
    if (pressed || (gripping & ~_hapticSticks)) {
        [_touchFeedback impactOccurredWithIntensity:0.6]; [_touchFeedback prepare];
    }
    _hapticSticks = gripping;
    _faceBits = face; _dpadBits = dpad; _btnBits = btn;
    pthread_mutex_lock(&g_mu);
    g_touch_btn = face | dpad | btn; g_touch_lx = ax[0]; g_touch_ly = ax[1]; g_touch_rx = ax[2]; g_touch_ry = ax[3];
    pthread_mutex_unlock(&g_mu);
    publish();
    BOOL stick = _stick[0] != nil;   // only the left stick is drawn: the right one needs no refresh
    if (changed || stick || _stickShown) [self refresh];   // also refresh on the stick release so the knob returns to the centre
    _stickShown = stick;
}
// Touches no control takes go to the game's touch screen, normalized on front_ios.m's actual 16:9 viewport (including portrait and tabletop splits, and the cropped Fill picture): Super Mario Galaxy's pointer in handheld mode (profile op_mode). The host reports them only in handheld mode, as on the Switch (hle_hid.c touch_read)
- (void)pushGame {
    CGRect b = _layout.game;
    if (b.size.width <= 0 || b.size.height <= 0) { dm_touch_set(NULL, 0); return; }
    dm_touch t[16]; int n = 0;
    for (int i = 0; i < 16; i++) if (_game[i]) {
        CGPoint p = dm_game_touch_point(b, [_game[i] locationInView:self]);   // with Fill the game rectangle is larger than the view (DmLayout.h)
        t[n++] = (dm_touch){(uint32_t)i, (float)p.x, (float)p.y};
    }
    dm_touch_set(t, n);
}
- (BOOL)gameBegin:(UITouch *)t {
    if (CGRectIsEmpty(_layout.game) || (_layout.separated && !CGRectContainsPoint(_layout.game, [t locationInView:self]))) return NO;
    for (int i = 0; i < 16; i++) if (!_game[i]) { _game[i] = t; [_owner setObject:@(C_GAME | (uint64_t)i << 8) forKey:t]; return YES; }
    return NO;
}
// While an offline HTML page is shown over the picture (web_apple.m front_web_touch), a touch no control would take goes to the page instead of the game's touch screen:
// the gamepad lets it through. The same tests as touchesBegan
- (BOOL)drawnControlAt:(CGPoint)p {   // a drawn control would take a touch here: a key, the diamond, the D-pad, the left stick (not the right stick's open area)
    if (_padOff || (_layout.separated && !CGRectContainsPoint(_layout.controls, p))) return NO;
    if (_tap) return NO;
    if ([self btnAt:p] >= 0) return YES;
    if (dist(p, self.faceCenter) / (self.faceGap + MAX(self.faceR * 1.6, self.faceHitR)) <= 1) return YES;
    if (_full && dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    return dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0) < 1;
}
- (BOOL)controlAt:(CGPoint)p {
    if (_padOff || (_layout.separated && !CGRectContainsPoint(_layout.controls, p))) return NO;
    if (_tap) return NO;
    if ([self btnAt:p] >= 0) return YES;
    if (dist(p, self.faceCenter) / (self.faceGap + MAX(self.faceR * 1.6, self.faceHitR)) <= 1) return YES;
    if (_full && dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    if (!_stick[0] && dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0) < 1) return YES;
    return _full && !_stick[1] && [self inRightArea:p];
}
- (UIView *)hitTest:(CGPoint)p withEvent:(UIEvent *)e {
    BOOL web = front_web_touch() != 0;
    if (web && (_menu.hidden || _menu.alpha < 1)) [self menuShow];   // a page shown while the menu button was hidden (front_web_show has no front-end call): the first touch brings it back
    UIView *v = [super hitTest:p withEvent:e];
    return v == self && web && ![self controlAt:p] ? nil : v;
}
- (void)touchesBegan:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    if (_menuOpen) [self menuClosed];   // a touch on the game: the menu is gone, whether or not its end was reported
    for (UITouch *t in ts) if (t.tapCount >= 2 && ![self drawnControlAt:[t locationInView:self]]) { [self menuShow]; break; }   // a double tap off the controls shows the menu button
    for (UITouch *t in ts) {
        if (_padOff) { game |= [self gameBegin:t]; continue; }
        CGPoint p = [t locationInView:self];
        if (_layout.separated && !CGRectContainsPoint(_layout.controls, p)) { game |= [self gameBegin:t]; continue; }
        int hit = _tap ? -1 : [self btnAt:p];   // the menu button took its own touches (menuTakes)
        if (hit >= 0) { [_owner setObject:@(C_BTN | (uint64_t)hit << 8) forKey:t]; continue; }
        if (_tap) { game |= [self gameBegin:t]; continue; }
        // diamond, D-pad, left stick: take the one with the smallest distance / grab radius, if it is <= 1
        CGFloat best = 1; int kind = C_NONE, idx = 0;
        CGFloat f = dist(p, self.faceCenter) / (self.faceGap + MAX(self.faceR * 1.6, self.faceHitR)); if (f <= best) { best = f; kind = C_FACE; }
        if (_full) { CGFloat d = dist(p, self.dpadCenter) / MAX(self.dpadR * K_DPAD_GRAB, _layout.separated ? 22 : 0); if (d < best) { best = d; kind = C_DPAD; } }
        if (!_stick[0]) { CGFloat s = dist(p, self.stickHome) / MAX([self stickR:0] * K_STICK_GRAB, _layout.separated ? 22 : 0); if (s < best) { best = s; kind = C_STICK; } }
        if (kind == C_NONE && _full && !_stick[1] && [self inRightArea:p]) { kind = C_STICK; idx = 1; _rCentre = p; }   // the right stick: centred where the touch lands
        if (kind == C_FACE) { [_owner setObject:@(C_FACE) forKey:t]; [_faceOf setObject:@([self faceAt:p]) forKey:t]; }
        else if (kind == C_DPAD) [_owner setObject:@(C_DPAD) forKey:t];
        else if (kind == C_STICK) { [_owner setObject:@(C_STICK | (uint64_t)idx << 8) forKey:t]; _stick[idx] = t; _stickNow[idx] = p;
            if (idx == 0) { CGRect b = self.bounds; CGFloat m = [self stickR:0] * 0.5;   // centred where the thumb lands, at least half the ring on the screen
                _lCentre = CGPointMake(MIN(MAX(p.x, CGRectGetMinX(b) + m), CGRectGetMaxX(b) - m), MIN(MAX(p.y, CGRectGetMinY(b) + m), CGRectGetMaxY(b) - m)); } }
        else game |= [self gameBegin:t];
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesMoved:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue; int c = (int)(v & 0xff); CGPoint p = [t locationInView:self];
        if (c == C_FACE) [_faceOf setObject:@([self faceAt:p]) forKey:t];
        else if (c == C_STICK) { _stickNow[v >> 8] = p;
            if ((v >> 8) == 1) { CGFloat d = dist(p, _rCentre), R = [self stickR:1];   // the right stick's centre follows a finger past its radius, so turning back responds at once
                if (d > R) _rCentre = CGPointMake(p.x - (p.x - _rCentre.x) * R / d, p.y - (p.y - _rCentre.y) * R / d); } }
        else if (c == C_GAME) game = YES;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)endTouches:(NSSet<UITouch *> *)ts tapped:(BOOL)ended {
    BOOL game = NO;
    for (UITouch *t in ts) {
        uint64_t v = [_owner objectForKey:t].unsignedLongLongValue;
        if ((v & 0xff) == C_GAME && (v >> 8) < 16) { _game[v >> 8] = nil; game = YES; }
        [_owner removeObjectForKey:t]; [_faceOf removeObjectForKey:t]; for (int i = 0; i < 2; i++) if (t == _stick[i]) _stick[i] = nil;
    }
    if (game) [self pushGame];
    [self recompute];
}
- (void)touchesEnded:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:YES]; }
- (void)touchesCancelled:(NSSet<UITouch *> *)ts withEvent:(UIEvent *)e { [self endTouches:ts tapped:NO]; }
- (void)reset { [_owner removeAllObjects]; [_faceOf removeAllObjects]; _stick[0] = _stick[1] = nil; for (int i = 0; i < 16; i++) _game[i] = nil; [self pushGame]; [self recompute]; }

// ---- Shapes ----
static CGPathRef circlePath(CGPoint c, CGFloat r) { return CGPathCreateWithEllipseInRect(CGRectMake(c.x - r, c.y - r, 2 * r, 2 * r), NULL); }
// The menu button's icon: a ring with eight straight rays (the owner's drawing) in NX 18's two colours, a sweep from cyan (top left) to coral (bottom right) and back around the
// ring, so the rays take the colour of where they stand (LauncherRow.swift NX18Palette: cyan #00C8F5, coral #FF6B5A). The two blends sit between rays (the sweep turned an
// eighth of a ray's spacing off the diagonal): one blend centred on a ray would mix it to grey. side: the icon's width and height in points, drawn at the
// screen's scale for each touch-control size, so it stays sharp. Ring centred at half the radius, rays from 0.72 to the edge, all strokes 0.19 of the radius, flat ends
static UIImage *menuIcon(CGFloat side, CGFloat scale) {
    UIGraphicsImageRendererFormat *f = [UIGraphicsImageRendererFormat preferredFormat]; f.opaque = NO; f.scale = scale;
    UIImage *img = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(side, side) format:f] imageWithActions:^(UIGraphicsImageRendererContext *rc) {
        CGContextRef g = rc.CGContext; CGFloat R = side / 2, w = 0.19 * R;
        CGContextSetLineWidth(g, w); CGContextSetLineCap(g, kCGLineCapButt);
        CGContextAddEllipseInRect(g, CGRectMake(R - 0.505 * R, R - 0.505 * R, 1.01 * R, 1.01 * R));
        for (int i = 0; i < 8; i++) {
            CGFloat a = i * M_PI_4, c = cos(a), s = sin(a), in = 0.72 * R, out = R - w * 0.5 * (fabs(c) > 0.1 && fabs(s) > 0.1 ? 1 : 0);   // a diagonal's flat end keeps its corners inside
            CGContextMoveToPoint(g, R + in * c, R + in * s); CGContextAddLineToPoint(g, R + out * c, R + out * s);
        }
        CGContextReplacePathWithStrokedPath(g); CGContextClip(g);   // the strokes as a shape the gradient fills
        CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
        const CGFloat cyan[4] = {0, 0xC8 / 255.0, 0xF5 / 255.0, 1}, coral[4] = {1, 0x6B / 255.0, 0x5A / 255.0, 1};
        CGColorRef c0 = CGColorCreate(cs, cyan), c1 = CGColorCreate(cs, coral);
        const CGFloat at[6] = {0, 0.17, 0.33, 0.67, 0.83, 1};   // each colour holds most of its half, the blends short and centred a quarter turn from it, between two rays
        CGGradientRef grad = CGGradientCreateWithColors(cs, (__bridge CFArrayRef)@[(__bridge id)c0, (__bridge id)c0, (__bridge id)c1, (__bridge id)c1, (__bridge id)c0, (__bridge id)c0], at);
        CGContextDrawConicGradient(g, grad, CGPointMake(R, R), -5 * M_PI / 8);   // cyan centred between the top-left and top rays (UIKit's y runs down), coral opposite
        CGGradientRelease(grad); CGColorRelease(c0); CGColorRelease(c1); CGColorSpaceRelease(cs);
    }];
    return [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}
static CGPathRef dropPath(CGPoint c, CGFloat r, CGFloat tipAngle, CGFloat round) {   // teardrop: circle + two tangents meeting at the tip, tip slightly rounded
    CGFloat d = r * K_DROP_TIP, th = acos(r / d);
    CGPoint tip = CGPointMake(c.x + d * cos(tipAngle), c.y + d * sin(tipAngle));
    CGPoint p1 = CGPointMake(c.x + r * cos(tipAngle + th), c.y + r * sin(tipAngle + th)), p2 = CGPointMake(c.x + r * cos(tipAngle - th), c.y + r * sin(tipAngle - th));
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, p2.x, p2.y);
    CGPathAddArcToPoint(p, NULL, tip.x, tip.y, p1.x, p1.y, round);
    CGPathAddArc(p, NULL, c.x, c.y, r, tipAngle + th, tipAngle - th + 2 * M_PI, false);
    CGPathCloseSubpath(p); return p;
}
static CGPathRef armPath(CGPoint c, CGFloat R, CGFloat w, CGFloat in, CGFloat angle, CGFloat round) {   // one D-pad arm: an upward pentagon (tip toward the centre) rotated by angle around the centre
    CGPoint v[5] = {{-w, -R}, {w, -R}, {w, -(in + w)}, {0, -in}, {-w, -(in + w)}};
    CGFloat cs = cos(angle), sn = sin(angle);
    for (int i = 0; i < 5; i++) v[i] = CGPointMake(c.x + v[i].x * cs - v[i].y * sn, c.y + v[i].x * sn + v[i].y * cs);
    CGMutablePathRef p = CGPathCreateMutable();
    CGPathMoveToPoint(p, NULL, (v[4].x + v[0].x) / 2, (v[4].y + v[0].y) / 2);
    for (int i = 0; i < 5; i++) CGPathAddArcToPoint(p, NULL, v[i].x, v[i].y, v[(i + 1) % 5].x, v[(i + 1) % 5].y, round);
    CGPathCloseSubpath(p); return p;
}
static void setPath(CAShapeLayer *l, CGPathRef p) { l.path = p; l.shadowPath = p; CGPathRelease(p); }
static void placeLabel(CATextLayer *t, CGPoint c, CGFloat fs) {
    CTFontRef f = dm_ui_ctfont_emphasized(fs);
    t.font = f; t.fontSize = CTFontGetSize(f);   // the UI font's size is scaled (DM_UI_FONT_SCALE)
    CGFloat h = CTFontGetAscent(f) + CTFontGetDescent(f) + (dm_ui_font_on() ? 0 : CTFontGetLeading(f)), w = fs * 3;   // the UI font's line gap is below its letters: left out, so they stay centred
    t.frame = CGRectMake(c.x - w / 2, c.y - h / 2, w, h);
    CFRelease(f);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    UIWindowScene *ws = self.window.windowScene; if (ws) atomic_store(&g_iface_orient, (int)ws.effectiveGeometry.interfaceOrientation);
    CGFloat u = self.u;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGFloat scale = MAX(self.traitCollection.displayScale, 1);
    for (int b = 0; b < B_N; b++) if (_label[b] && _label[b].contentsScale != scale) {
        _label[b].contentsScale = scale; [_label[b] setNeedsDisplay];
    }
    _controls.frame = self.layer.bounds;
    for (int b = B_A; b <= B_Y; b++) { CGPoint c = [self facePos:b]; setPath(_key[b], circlePath(c, self.faceR)); placeLabel(_label[b], c, 20 * u); }
    for (int i = 0; i < (int)(sizeof k_btns / sizeof *k_btns); i++) { int b = k_btns[i];
        if (isDrop(b)) {
            BOOL right = b == B_ZR || b == B_R; CGPoint c = [self dropCenter:b];
            setPath(_key[b], dropPath(c, [self dropR:b], right ? -M_PI_4 : -3 * M_PI_4, 4 * u)); placeLabel(_label[b], c, 16 * u);   // tip toward the near top corner
        } else if (isClick(b)) {
            CGPoint c = [self clickCenter:b]; setPath(_key[b], circlePath(c, K_CLICK_R * u)); placeLabel(_label[b], c, 13 * u);
        } else {
            CGRect rc = [self pillRect:b];
            setPath(_key[b], CGPathCreateWithRoundedRect(rc, rc.size.height / 2, rc.size.height / 2, NULL)); placeLabel(_label[b], CGPointMake(CGRectGetMidX(rc), CGRectGetMidY(rc)), 18 * u);
        }
    }
    static const struct { int b; CGFloat angle; } arms[] = {{B_UP, 0}, {B_RIGHT, M_PI_2}, {B_DOWN, M_PI}, {B_LEFT, -M_PI_2}};   // the same arm in 90° steps
    for (int i = 0; i < 4; i++) setPath(_key[arms[i].b], armPath(self.dpadCenter, self.dpadR, K_ARM_W * u, K_ARM_IN * u, arms[i].angle, 6 * u));
    CGFloat mr = K_MENU_R * u; CGPoint mc = self.menuCenter;
    _menu.frame = CGRectMake(mc.x - mr, mc.y - mr, 2 * mr, 2 * mr); _menu.layer.cornerRadius = mr;
    _menu.layer.shadowPath = [UIBezierPath bezierPathWithOvalInRect:_menu.bounds].CGPath;
    [_menu setImage:menuIcon(16 * u, scale) forState:UIControlStateNormal];   // drawn for this size and screen, so it stays sharp at every touch-control scale
    setPath(_ring, circlePath(self.stickHome, [self stickR:0]));
    CGFloat k = K_KNOB_R * u; _knob.bounds = CGRectMake(0, 0, 2 * k, 2 * k);
    setPath(_knob, circlePath(CGPointMake(k, k), k));
    CAShapeLayer *in = (CAShapeLayer *)_knob.sublayers.firstObject; CGPathRef ip = circlePath(CGPointMake(k, k), k * 0.62);
    in.frame = _knob.bounds; in.path = ip; CGPathRelease(ip);
    [CATransaction commit];
    _sprites = YES;   // the paths are laid out for the canvas: refresh makes the pictures for them (touchAtlas) before a frame draws them
    [self refresh];
}
- (void)safeAreaInsetsDidChange { [super safeAreaInsetsDidChange]; [self setNeedsLayout]; }
#define TOUCH_STALL_NS 100000000ull   // no present for this long: a press shows on the layers (refresh)
- (void)refresh {   // pressed state → fill, sticks → knob position: in the frame the present draws them into (touchPublish), and on the layers while they show
    if (_touchDraw) {
        [self touchAtlas];
        // The game presents nothing (a load, a hitch, a program hand-off): the controls in the frame would not follow this press until the next present, so the layers show it,
        // as before; the next present that draws the controls hides them again
        if (_inFrame && mtl_present_touch_idle_ns() > TOUCH_STALL_NS) [self touchLayers:"the game presents nothing"];
        [self touchPublish];
        if (_inFrame) return;   // the layers are hidden: they keep the look they had, and get the current one when they show again
    }
    [self layerLook];
}
- (void)layerLook {
    uint64_t all = _faceBits | _dpadBits | _btnBits;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    for (int b = 0; b < B_N; b++) { BOOL on = (all >> b) & 1;
        _key[b].fillColor = (on ? k_on : k_idle).CGColor; _label[b].foregroundColor = (on ? k_textOn : k_text).CGColor; press_glow(_key[b], on); }
    CGPoint h = [self stickCentre:0], o = [self knobOffset:0], rs = self.ringShift;
    _knob.position = CGPointMake(h.x + o.x, h.y + o.y); _knob.fillColor = (_stick[0] ? k_on : k_idle).CGColor; press_glow(_knob, _stick[0] != 0);
    _ring.affineTransform = CGAffineTransformMakeTranslation(rs.x, rs.y);
    [CATransaction commit];
}

// ---- The controls drawn into the game's frame (dm/host/touch_draw.h) ----
// A visible layer over the game's CAMetalLayer makes iOS composite the two, which costs one refresh between the present and the screen (docs/reference/frame-rate.md, "Touch
// controls over the game's layer cost a refresh of latency"). So while the controls show, front_ios.m makes the game view the whole screen (dm_touch_canvas) and turns this on:
// the control layers stay hidden, as with a controller, and the live present draws the controls into its drawable instead, over the picture. The view itself stays and takes
// every touch as before (hit tests, the game's touch screen, the sticks, the double tap); the menu button is a view of its own and stays one (it shows 5 s at a time)
- (void)touchDraw:(BOOL)on canvas:(CGRect)canvas scale:(CGFloat)scale picture:(CGRect)pic {
    if (on == _touchDraw && (!on || (CGRectEqualToRect(canvas, _canvas) && scale == _canvasScale && CGRectEqualToRect(pic, _canvasPic)))) return;
    BOOL was = _touchDraw;
    _touchDraw = on;
    if (on) {   // the canvas and the picture's place on it at once (TOUCH_PLACE: no control yet, the pictures and their places are for the last canvas); the layers show the
                // controls until a present has drawn them for this canvas. layoutSubviews lays the paths out, makes the atlas for these pixels if they changed and hands over
                // the frame with the controls (refresh)
        _canvas = canvas; _canvasScale = scale; _canvasPic = pic; _sprites = NO;
        [self touchLayers:NULL]; [self touchPublish]; [self setNeedsLayout]; return;
    }
    if (was) {   // the present stops drawing them: a last frame that is off (it keeps the canvas, so a drawable made before the game view left it still places the picture
                 // there: touch_frame_places), the atlas let go (made again when they come back), and the layers take the current look
        touch_frame f = {0}; [self touchFrameHead:&f]; f.on = TOUCH_OFF; mtl_present_touch(&f);
        mtl_present_touch_release(); _atlasKey = nil; _atlasOK = NO;
        [self touchLayers:NULL]; [self refresh];
        // Then, once those drawables are long gone, no frame at all: nothing the front end no longer lays out stays published
        __weak DmGamepad *me = self; uint32_t off = ++_offs;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            DmGamepad *p = me; if (!p || p->_touchDraw || p->_offs != off || g_touch_pad != p) return;
            touch_frame z = {0}; mtl_present_touch(&z);
        });
    }
}
// The control layers show again (why: logged; NULL for a change the front end logs itself) until a present has drawn the controls from a frame published after this
- (void)touchLayers:(const char *)why {
    BOOL showed = !_controls.hidden;
    _inFrame = NO; _ackFrom = 0;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; _controls.hidden = _padOff; [CATransaction commit];
    if (!showed && !_padOff) [self layerLook];
    if (why) { static int said; if (said++ < 8 || said % 100 == 0) LOG("front end: touch controls on their layers until the next present draws them (%s)", why); }
}
// A live present that drew the controls from frame seq or later completed (nvn_mtl.m, through front_touch_drawn): the controls are on screen in the frame, so the layers hide
- (void)touchDrawn:(uint32_t)seq {
    if (!_touchDraw || _inFrame || !_ackFrom || !touch_seq_since(seq, _ackFrom)) return;
    _inFrame = YES;
    [CATransaction begin]; [CATransaction setDisableActions:YES]; _controls.hidden = YES; [CATransaction commit];
}
// The present had drawables the frame is not laid out for, many in a row (nvn_mtl.m, through front_touch_unfit): the layers show and the root lays the view out again
- (void)touchUnfit {
    if (!_touchDraw) return;
    [self touchLayers:"the drawable does not fit the frame"]; [self touchPublish]; [self.superview setNeedsLayout];
}
// What the pictures of the controls depend on: the pixels a point, the opacity, and each layer's path and whether it shows (positions too: a control's place within its picture's
// pixels follows its position, so each keeps the fraction of a pixel its layer had)
- (NSData *)touchLook {
    NSMutableData *d = [NSMutableData data];
    CGFloat head[2] = {_canvasScale, g_touch_opacity}; [d appendBytes:head length:sizeof head];
    CAShapeLayer *ls[S_N]; for (int b = 0; b < B_N; b++) ls[b] = _key[b]; ls[S_RING] = _ring; ls[S_KNOB] = _knob;
    for (int i = 0; i < S_N; i++) {
        CGRect r = ls[i].path ? CGPathGetPathBoundingBox(ls[i].path) : CGRectNull; CGFloat v[5] = {ls[i].hidden, r.origin.x, r.origin.y, r.size.width, r.size.height};
        [d appendBytes:v length:sizeof v];
    }
    return d;
}
// A layer's shadow as Core Animation draws it: its shadowPath as an opaque shape, blurred by shadowRadius, offset, in shadowColor at shadowOpacity, under the whole shape, so it
// shows through a translucent fill (renderInContext takes a shadow from what it draws instead, the fill's 14 % alpha: hardly any). The shape is drawn outside the picture's
// rectangle (pt, the clip) and its shadow brought back by the offset. A shadow's offset and blur are in the context's base space (pixels, y up), whatever the transform. Core
// Graphics' blur of 2.2 times the radius matches the render server's shadow best (the Duo harness's DuoTouchDrawTests against drawViewHierarchyInRect: a mean difference of
// 0.065 of 255 per channel over the screen, 0.10 at 2 and 0.32 at 1)
#define TOUCH_SHADOW_BLUR 2.2
static void touch_shadow(CGContextRef g, CAShapeLayer *l, CGFloat sc, CGRect pt) {
    if (!l.shadowPath || l.shadowOpacity <= 0 || !l.shadowColor) return;
    CGFloat away = pt.size.width + 64;
    CGColorRef c = CGColorCreateCopyWithAlpha(l.shadowColor, CGColorGetAlpha(l.shadowColor) * l.shadowOpacity);
    CGContextSaveGState(g);
    CGContextSetShadowWithColor(g, CGSizeMake((l.shadowOffset.width - away) * sc, -l.shadowOffset.height * sc), l.shadowRadius * sc * TOUCH_SHADOW_BLUR, c);
    CGContextTranslateCTM(g, away, 0); CGContextAddPath(g, l.shadowPath); CGContextSetGrayFillColor(g, 0, 1); CGContextFillPath(g);
    CGContextRestoreGState(g);
    CGColorRelease(c);
}
// The pictures of the controls at the canvas's pixels a point: each layer as it is, rendered by Core Animation's own renderer (renderInContext: the path's fill and outline,
// the label; the shadow by touch_shadow), normal and pressed, into one atlas the present samples, grey and alpha when every pixel is a grey (touch_grey). Made again only when
// the look changes (touchLook). Main thread, 10-30 ms
- (void)touchAtlas {
    NSData *key = [self touchLook];
    if ([key isEqualToData:_atlasKey]) return;
    _atlasKey = key; _atlasOK = NO;
    CGFloat sc = _canvasScale; if (sc <= 0) return;
    double t0 = CACurrentMediaTime();
    CAShapeLayer *ls[S_N]; for (int b = 0; b < B_N; b++) ls[b] = _key[b]; ls[S_RING] = _ring; ls[S_KNOB] = _knob;
    int idx[2 * S_N], st[2 * S_N], w[2 * S_N], h[2 * S_N], x[2 * S_N], y[2 * S_N], n = 0;
    for (int i = 0; i < S_N; i++) {
        _spritePt[i] = CGRectNull;
        if (ls[i].hidden || !ls[i].path) continue;
        // the path, its outline and its shadow (a blur of shadowRadius, offset), whole pixels outward
        CGFloat m = ls[i].lineWidth / 2 + 2 * MAX(ls[i].shadowRadius, i == S_RING ? 0 : K_GLOW_R) + MAX(fabs(ls[i].shadowOffset.width), fabs(ls[i].shadowOffset.height)) + 1;   // the pressed look's glow too
        CGRect r = CGRectInset(i == S_KNOB ? ls[i].bounds : CGPathGetPathBoundingBox(ls[i].path), -m, -m);
        CGFloat x0 = floor(CGRectGetMinX(r) * sc) / sc, y0 = floor(CGRectGetMinY(r) * sc) / sc, x1 = ceil(CGRectGetMaxX(r) * sc) / sc, y1 = ceil(CGRectGetMaxY(r) * sc) / sc;
        _spritePt[i] = CGRectMake(x0, y0, x1 - x0, y1 - y0);
        for (int s = 0; s < (i == S_RING ? 1 : 2); s++) { idx[n] = i; st[n] = s; w[n] = (int)lround((x1 - x0) * sc); h[n] = (int)lround((y1 - y0) * sc); n++; }
    }
    int width = 2048, height = 0;
    for (int k = 0; k < n; k++) width = MAX(width, w[k] + 4);
    if (!n || !(height = touch_pack(n, w, h, width, 2, x, y))) return;   // nothing to draw (_atlasOK stays NO: touchPublish places the picture only)
    size_t row = (size_t)width * 4; void *px = calloc((size_t)height, row);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = px ? CGBitmapContextCreate(px, (size_t)width, (size_t)height, 8, row, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little) : NULL;   // BGRA, premultiplied: the atlas's texture
    CGColorSpaceRelease(cs);
    if (!g) { free(px); LOG("[RED] front end: no bitmap for the touch controls' %dx%d atlas; they go back to their layers", width, height); front_touch_draw_failed(); return; }
    CGContextTranslateCTM(g, 0, height); CGContextScaleCTM(g, 1, -1);   // UIKit's way up, as a layer renders
    [CATransaction begin]; [CATransaction setDisableActions:YES];   // looks set and put back in one transaction: the render server sees none of them
    BOOL hidden = _controls.hidden; _controls.hidden = NO;
    CGAffineTransform ringT = _ring.affineTransform; _ring.affineTransform = CGAffineTransformIdentity;   // pictured at home: the held stick's shift is applied where it is placed (ringShift)
    for (int k = 0; k < n; k++) {
        int i = idx[k]; BOOL on = st[k];
        if (i < B_N) { ls[i].fillColor = (on ? k_on : k_idle).CGColor; _label[i].foregroundColor = (on ? k_textOn : k_text).CGColor; press_glow(ls[i], on); }
        else if (i == S_KNOB) { ls[i].fillColor = (on ? k_on : k_idle).CGColor; press_glow(ls[i], on); }
        CGContextSaveGState(g);
        CGContextTranslateCTM(g, x[k], y[k]); CGContextClipToRect(g, CGRectMake(0, 0, w[k], h[k]));
        CGContextScaleCTM(g, sc, sc); CGContextTranslateCTM(g, -_spritePt[i].origin.x, -_spritePt[i].origin.y);
        touch_shadow(g, ls[i], sc, _spritePt[i]);
        float so = ls[i].shadowOpacity; ls[i].shadowOpacity = 0;   // drawn above; renderInContext would take it from the fill's alpha
        [ls[i] renderInContext:g];
        ls[i].shadowOpacity = so;
        CGContextRestoreGState(g);
        _spriteUV[i][on] = CGRectMake((CGFloat)x[k] / width, (CGFloat)y[k] / height, (CGFloat)w[k] / width, (CGFloat)h[k] / height);
    }
    for (int b = 0; b < B_N; b++) { _key[b].fillColor = k_idle.CGColor; _label[b].foregroundColor = k_text.CGColor; press_glow(_key[b], NO); }   // refresh gives the layers their look when they show again
    _knob.fillColor = k_idle.CGColor; press_glow(_knob, NO);
    _controls.hidden = hidden; _ring.affineTransform = ringT;
    [CATransaction commit];
    CGContextRelease(g);
    uint8_t *grey = malloc((size_t)width * height * 2);   // every colour of the controls is a grey (white, black): two bytes a pixel, half the memory, when that holds
    int ch = grey && touch_grey(px, width, height, row, grey) ? 2 : 4;
    _atlasOK = mtl_present_touch_atlas(ch == 2 ? grey : px, width, height, ch == 2 ? (size_t)width * 2 : row, ch, ++_atlasGen) != 0;
    free(grey); free(px);
    if (!_atlasOK) { front_touch_draw_failed(); return; }
    static int said; if (said++ < 4 || said % 50 == 0)   // the first few, then one in 50: a rotation or a size pick each make one
        LOG("front end: touch controls pictured for the present: %d pictures, atlas %dx%d %s (%.1f MB) at %.2f pixels a point, %.1f ms", n, width, height, ch == 2 ? "grey and alpha" : "BGRA",
            (double)width * height * ch / 1048576.0, sc, (CACurrentMediaTime() - t0) * 1e3);
}
- (void)touchFrameHead:(touch_frame *)f {   // the canvas and the picture's place on it
    f->canvas_w = (uint32_t)lround(_canvas.size.width * _canvasScale); f->canvas_h = (uint32_t)lround(_canvas.size.height * _canvasScale);
    f->pic[0] = (float)_canvasPic.origin.x; f->pic[1] = (float)_canvasPic.origin.y; f->pic[2] = (float)_canvasPic.size.width; f->pic[3] = (float)_canvasPic.size.height;
}
static void touch_quad_at(touch_frame *f, CGRect pt, CGRect canvas, CGRect uv) {   // a picture at pt (pad points) on the canvas
    if (f->n >= TOUCH_QUADS || CGRectIsNull(pt) || canvas.size.width <= 0 || canvas.size.height <= 0) return;
    touch_quad *q = &f->q[f->n++];
    q->dst[0] = (float)((pt.origin.x - canvas.origin.x) / canvas.size.width); q->dst[1] = (float)((pt.origin.y - canvas.origin.y) / canvas.size.height);
    q->dst[2] = (float)(pt.size.width / canvas.size.width); q->dst[3] = (float)(pt.size.height / canvas.size.height);
    q->src[0] = (float)uv.origin.x; q->src[1] = (float)uv.origin.y; q->src[2] = (float)uv.size.width; q->src[3] = (float)uv.size.height;
}
// The frame the present draws next: every control that shows, in the order its layer had (the ring, the knob, then the keys), each in its look now (pressed, the knob held)
- (void)touchPublish {
    touch_frame f = {0}; [self touchFrameHead:&f];
    BOOL ready = _atlasOK && _sprites;   // the pictures and their places are for this canvas (not before layoutSubviews has laid it out and touchAtlas made them)
    f.on = ready ? TOUCH_ON : TOUCH_PLACE; f.atlas = _atlasGen;
    if (ready) {
        uint64_t all = _faceBits | _dpadBits | _btnBits;
        if (!_ring.hidden) { CGPoint rs = self.ringShift; touch_quad_at(&f, CGRectOffset(_spritePt[S_RING], rs.x, rs.y), _canvas, _spriteUV[S_RING][0]); }
        if (!_knob.hidden) {   // the knob's picture is in its own bounds: placed where the layer's position puts them (its anchor is the centre)
            CGPoint h = [self stickCentre:0], o = [self knobOffset:0]; CGSize k = _knob.bounds.size; CGRect p = _spritePt[S_KNOB];
            touch_quad_at(&f, CGRectOffset(p, h.x + o.x - k.width / 2, h.y + o.y - k.height / 2), _canvas, _spriteUV[S_KNOB][_stick[0] != nil]);
        }
        for (int b = 0; b < B_N; b++) if (!_key[b].hidden) touch_quad_at(&f, _spritePt[b], _canvas, _spriteUV[b][(all >> b) & 1]);
    }
    g_touch_pad = self;
    uint32_t seq = mtl_present_touch(&f);
    if (ready && !_inFrame) {   // the layers show: the present says when it has drawn this frame or a later one (touchDrawn)
        if (!_ackFrom) _ackFrom = seq;
        mtl_present_touch_ack(_ackFrom);
    }
}
- (BOOL)controlsShown { return !_padOff && !_tap; }

// ---- Physical controllers ----
// Each supported controller (an extended gamepad profile, or a lone Joy-Con held sideways: pad_live_input) is a player of its own, as on the Mac (front_mac.m): it holds a slot (pad_slots.h: player 1 first, a reconnected controller
// gets its player back) and goes to dm_pad_set_player, and hle_hid.c reports player n on its own npad while the slot is held (dm_pad_players). Player 1's controller is ORed
// with the touch gamepad; a one-player game that supports only No1 / Handheld still sees every controller as player 1 (hle_hid.c). Each player has its controller's rumble and
// gyro; the phone's gyro is player 1's. With DM_PAD_MERGE=1 every controller is player 1, as before (the last one moved wins). With DM_PAD_PRESS_TO_JOIN=1 a controller is
// no player until one of its buttons is pressed, then it is the lowest player free (pad_slot_take_lowest), as on the Mac: the players choose their order
static pad_slots g_slots;
static GCController *g_held[DM_PLAYERS];   // the controller of each slot, kept alive while it holds it (the slot table keys on its pointer)
static int g_merge, g_press_to_join;
static int32_t axis(float v) { return (int32_t)(fmaxf(-1.f, fminf(1.f, v)) * 32767); }
static const char *pad_name(GCController *c);
static void npad_name(int p, char *out, size_t cap);
static int cp_poll(void);
static uint64_t pad_mask(GCExtendedGamepad *g) {   // the Switch buttons a controller holds now
    _Static_assert(DM_BTN_A == 1u << B_A && DM_BTN_B == 1u << B_B && DM_BTN_X == 1u << B_X && DM_BTN_Y == 1u << B_Y, "face button bits");
    uint64_t m = dm_pad_face(g);   // by position, a Nintendo pad by its labels
    #define K(btn, bit) if (btn.isPressed) m |= 1ull << bit
    K(g.leftShoulder, B_L); K(g.rightShoulder, B_R); K(g.leftTrigger, B_ZL); K(g.rightTrigger, B_ZR);
    K(g.buttonMenu, B_PLUS); if (g.buttonOptions) K(g.buttonOptions, B_MINUS);
    if (g.leftThumbstickButton) K(g.leftThumbstickButton, B_LS); if (g.rightThumbstickButton) K(g.rightThumbstickButton, B_RS);
    K(g.dpad.left, B_LEFT); K(g.dpad.up, B_UP); K(g.dpad.right, B_RIGHT); K(g.dpad.down, B_DOWN);
    #undef K
    return m;
}
// A lone Joy-Con: iOS presents it held sideways through live input, with no extended gamepad profile (upstream issue #2971, ported from upstream 985ea6cf6). Its direction pad
// is the stick, and its face buttons go by position as in SDL's Apple mapping. nil for any other controller without an extended profile
static GCControllerLiveInput *pad_live_input(GCController *c) {
    NSString *category = c.productCategory;
    if ([category isEqualToString:@"Nintendo Switch Joy-Con (L)"] || [category isEqualToString:@"Nintendo Switch Joy-Con (R)"]) return c.input;
    return nil;
}
static id<GCDirectionPadElement> pad_live_stick(GCControllerLiveInput *input) { return input.dpads[GCInputLeftThumbstick] ?: input.dpads[GCInputDirectionPad]; }
static BOOL pad_usable(GCController *c) {   // a controller the game can play with
    if (c.extendedGamepad) return YES;
    GCControllerLiveInput *input = pad_live_input(c);
    return pad_live_stick(input) || input.buttons[GCInputButtonA] || input.buttons[GCInputButtonX];
}
static uint64_t pad_live_buttons(GCControllerLiveInput *input) {
    uint64_t m = 0;
    #define K(name, bit) if (input.buttons[name].pressedInput.pressed) m |= 1ull << bit
    K(GCInputButtonX, B_A); K(GCInputButtonA, B_B); K(GCInputButtonY, B_X); K(GCInputButtonB, B_Y);
    K(GCInputLeftShoulder, B_L); K(GCInputRightShoulder, B_R); K(GCInputLeftTrigger, B_ZL); K(GCInputRightTrigger, B_ZR);
    K(GCInputButtonMenu, B_PLUS); K(GCInputButtonOptions, B_MINUS); K(GCInputLeftThumbstickButton, B_LS);
    #undef K
    return m;
}
static uint64_t pad_buttons(GCController *c) { return c.extendedGamepad ? pad_mask(c.extendedGamepad) : pad_live_buttons(pad_live_input(c)); }   // either kind
// The in-game panel and the controllers (main thread, as the handlers): 1 the panel is open (it reads the controllers itself, GameMenuPanel.swift), 2 it closed while a button
// was held (the B that closed it), which the game must not see; 0 the game has them. Home opens and closes the panel: its press, on any controller
static int g_menu_block;
static NSHashTable<GCController *> *g_home_down;
static int cp_up(void);
static BOOL pad_home(GCExtendedGamepad *g) {   // YES on Home's press, which then opens or closes the panel
    GCControllerButtonInput *h = g.buttonHome; GCController *c = g.controller;
    if (!g_home_down) g_home_down = [NSHashTable weakObjectsHashTable];
    if (!h.isPressed) { [g_home_down removeObject:c]; return NO; }
    if ([g_home_down containsObject:c]) return NO;
    [g_home_down addObject:c];
    if (!g_view || cp_up()) return NO;
    [g_view panelToggle];
    return YES;
}
// Capture takes a screenshot (DmCapture.m), at its press, on any controller that has the button: an extended pad's Share (Capture on Nintendo pads), a phone-clip pad's own
// screenshot button (pad_capture_button: GameSir and the like name it otherwise) and a Switch 2 pad's Capture. The game never sees it, as on the console; a held Capture is
// the recording's (captures-album.md, later). Its own press handler, so a button outside the extended profile is heard too
static void pad_capture_press(GCController *c, bool down) {   // press and release: a short press is a screenshot, a held one records (DmCapture.h dm_capture_button)
    (void)c;
    if (!g_view) return;
    if (down && (cp_up() || g_menu_block)) return;
    dm_capture_button(g_view, down);
}
static BOOL pads_any_pressed(void) { for (GCController *c in GCController.controllers) if (pad_usable(c) && pad_buttons(c)) return YES; return NO; }
static int g_merge_s2_rumble;   // DM_PAD_MERGE: player 1's rumble goes to the Switch 2 pads (merge_rumble_to_s2, upstream PR #1900)
static void merge_rumble_to_s2(int on);
static void read_pad(GCController *c) {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (!g && !pad_live_input(c)) return;
    int p = g_merge ? 0 : pad_slot_of(&g_slots, (__bridge const void *)c); if (p < 0 && !g_press_to_join) return;
    if (g && pad_home(g)) return;   // a lone Joy-Con's Home stays with the system (pad_listen)
    if (g_menu_block == 1 || (g_menu_block == 2 && pads_any_pressed())) return;   // the panel has the controllers, or a button that closed it is still down
    if (g_menu_block == 2) {   // all let go: each controller read as it is now (a stick held over the close)
        g_menu_block = 0;
        for (GCController *o in GCController.controllers) if (o != c && pad_usable(o)) read_pad(o);
    }
    uint64_t m = pad_buttons(c);
    float lx, ly, rx = 0, ry = 0;
    if (g) { lx = g.leftThumbstick.xAxis.value; ly = g.leftThumbstick.yAxis.value; rx = g.rightThumbstick.xAxis.value; ry = g.rightThumbstick.yAxis.value; }
    else { id<GCDirectionPadElement> stick = pad_live_stick(pad_live_input(c)); lx = stick.xAxis.value; ly = stick.yAxis.value; }
    if (p < 0) {   // DM_PAD_PRESS_TO_JOIN=1: it joins at its first button, a press the game also gets
        char nb[16];
        if (!m) return;
        if ((p = pad_slot_take_lowest(&g_slots, (__bridge const void *)c, pad_name(c))) < 0) { LOG("controller '%s': a button pressed, but all %d players are taken", pad_name(c), DM_PLAYERS); return; }
        g_held[p] = c; dm_motion_attach(c, p); dm_pad_players(pad_slot_mask(&g_slots));
        npad_name(p, nb, sizeof nb); LOG("controller '%s': a button pressed: player %d (npad %s)", pad_name(c), p + 1, nb);
    }
    if (cp_poll()) return;   // the controller applet's prompt has the controllers (front_ctrl_support)
    if (g_merge_s2_rumble && m) merge_rumble_to_s2(0);   // DM_PAD_MERGE: a button on this controller takes player 1's rumble back from a Switch 2 pad
    dm_haptics_apple_controller(p, c);
    dm_pad_set_player(p, m, axis(lx), axis(ly), axis(rx), axis(ry));
}
// The controller's input handler (one per controller: the extended profile's, or a lone Joy-Con's live input's); YES when it is set now, so a controller waiting to join is
// logged once. Home and Capture of an extended pad: without this iOS takes them as system gestures (Home opens the Games overlay, Capture a screenshot); Home opens and closes
// the in-game panel (pad_home), Capture takes a screenshot (pad_claim_buttons). A lone Joy-Con's stay with the system, as upstream keeps them
// The game buttons pad_mask reads, and Home: every other button iOS ties to a system gesture is the controller's capture button
static BOOL pad_game_button(GCControllerElement *e) {
    static NSSet<NSString *> *game;
    if (!game) game = [NSSet setWithObjects:GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder, GCInputLeftTrigger,
                       GCInputRightTrigger, GCInputButtonMenu, GCInputButtonOptions, GCInputLeftThumbstickButton, GCInputRightThumbstickButton, GCInputButtonHome, nil];
    return [game intersectsSet:e.aliases];
}
static GCControllerButtonInput *pad_capture_button(GCController *c) {
    GCPhysicalInputProfile *pr = c.physicalInputProfile;
    if (pr.buttons[GCInputButtonShare]) return pr.buttons[GCInputButtonShare];
    for (NSString *n in pr.buttons) { GCControllerButtonInput *b = pr.buttons[n]; if (b.boundToSystemGesture && !pad_game_button(b)) return b; }
    return nil;
}
// iOS's system gestures: off for Home, Share and every button iOS ties to one (a phone-clip pad's screenshot button, Options' long press), so each press is the game's or
// NX 18's at once. Logged once per controller, with the buttons' names, so a log shows which button a new controller's capture is
static void pad_claim_buttons(GCController *c) {
    NSMutableArray<NSString *> *bound = [NSMutableArray array];
    GCPhysicalInputProfile *pr = c.physicalInputProfile;
    for (NSString *n in pr.buttons) {
        GCControllerButtonInput *b = pr.buttons[n];
        if (!b.boundToSystemGesture && ![n isEqualToString:GCInputButtonHome] && ![n isEqualToString:GCInputButtonShare]) continue;
        if (b.boundToSystemGesture) [bound addObject:n];
        b.preferredSystemGestureState = GCSystemGestureStateDisabled;
    }
    GCControllerButtonInput *cap = pad_capture_button(c);
    if (cap && !cap.pressedChangedHandler) {
        __weak GCController *weak = c;
        cap.pressedChangedHandler = ^(GCControllerButtonInput *b, float v, BOOL down) { (void)b; (void)v; GCController *k = weak; if (k) pad_capture_press(k, down); };
    }
    static NSHashTable<GCController *> *said; if (!said) said = [NSHashTable weakObjectsHashTable];
    if ([said containsObject:c]) return;
    [said addObject:c];
    LOG("controller '%s': system gestures off for %s; capture button: %s", pad_name(c), bound.count ? [bound componentsJoinedByString:@", "].UTF8String : "Home and Share (none bound)",
        cap ? (cap.localizedName ?: [cap.aliases.allObjects componentsJoinedByString:@"/"]).UTF8String : "none");
}
static BOOL pad_listen(GCController *c) {
    GCExtendedGamepad *g = c.extendedGamepad;
    if (g) {
        pad_claim_buttons(c);
        if (g.valueChangedHandler) return NO;
        g.valueChangedHandler = ^(GCExtendedGamepad *profile, GCControllerElement *el) { (void)el; if (profile.valueChangedHandler) read_pad(profile.controller); };
        return YES;
    }
    GCControllerLiveInput *input = pad_live_input(c);
    if (!input || input.elementValueDidChangeHandler) return NO;
    __weak GCController *weak = c;
    input.elementValueDidChangeHandler = ^(id<GCDevicePhysicalInput> state, id<GCPhysicalInputElement> el) {
        (void)el; GCController *controller = weak;
        if (controller && state.elementValueDidChangeHandler) read_pad(controller);
    };
    return YES;
}
static void pad_unlisten(GCController *c) {
    if (c.extendedGamepad) c.extendedGamepad.valueChangedHandler = nil;
    else pad_live_input(c).elementValueDidChangeHandler = nil;
}
static const char *pad_name(GCController *c) { return c.vendorName.UTF8String ?: "?"; }
static void npad_name(int p, char *out, size_t cap) { uint32_t id = dm_player_npad(p); if (id == 0x20) snprintf(out, cap, "handheld"); else snprintf(out, cap, "%u", id); }
// Switch 2 controllers over Bluetooth LE (pad_switch2_apple.h, shared with the Mac front end): a pad is a player's controller as a GameController one is, in the same slots.
// iOS cannot give the transport this device's Bluetooth address, so a controller is used without bonding: hold Sync on it after each start of the game
static const dm_switch2_front g_s2front;
static int g_s2_off;   // the app is in the background or resigning: no Switch 2 input reaches the game
static void pads_start(void) {
    const char *e = getenv("DM_PAD_MERGE"); g_merge = e && atoi(e);
    e = getenv("DM_PAD_PRESS_TO_JOIN"); g_press_to_join = !g_merge && e && atoi(e);
    LOG("front end: %s", g_merge ? "every controller is player 1 (DM_PAD_MERGE)" : "each controller is a player of its own, the touch gamepad plays with player 1");
    if (g_press_to_join) LOG("front end: a controller becomes a player at its first button press, the lowest player free (DM_PAD_PRESS_TO_JOIN)");
    if (dm_switch2_start(&g_s2front)) LOG("front end: Switch 2 controllers: hold Sync on one to use it (no bonding on iOS: again after each start)");
}
// The panel opens: nothing a controller held stays pressed in the game, and the controllers' input waits until it closes (g_menu_block)
static void pads_release_game(void) {
    g_menu_block = 1;
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0); else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
void dm_gamepad_panel_closed(void) {   // GameMenuPanel.swift, main thread
    [g_view menuClosed];
    dm_state_menu(0); dm_vitals_menu_open(0);
    if (!g_menu_block) return;
    g_menu_block = pads_any_pressed() ? 2 : 0;   // a button that closed it still down (B): read_pad gives the controllers back once nothing is held; else at once
    if (!g_menu_block) for (GCController *c in GCController.controllers) if (pad_usable(c)) read_pad(c);   // a stick held over the close
}
// Called at start and on every connect / disconnect (gone: the controller that was just removed, nil otherwise); returns whether a controller is in use
static BOOL pads_merged(GCController *gone) {
    if (gone) dm_motion_detach(gone, 0);   // its handler: padsChanged
    BOOL any = NO; int motion = 0;
    for (GCController *c in GCController.controllers) if (c != gone && pad_usable(c)) {
        if (c.motion.hasRotationRate) motion = 1;
        any = YES; pad_listen(c);
        dm_motion_attach(c, 0);   // every controller is player 1: the last one moved drives its six-axis sensor
        read_pad(c);
    }
    if (!any || !motion) dm_motion_clear(0);   // the phone's gyro (if on) takes over from its next sample
    if (!any) { dm_haptics_apple_controller(0, nil); dm_pad_set(0, 0, 0, 0, 0); }
    return any;
}
static BOOL pads_slotted(GCController *gone) {
    NSArray<GCController *> *now = GCController.controllers; char nb[16]; BOOL waiting = NO;
    for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p] && (g_held[p] == gone || ![now containsObject:g_held[p]])) {
        npad_name(p, nb, sizeof nb); LOG("controller '%s' disconnected: player %d (npad %s) is free", pad_name(g_held[p]), p + 1, nb);
        pad_unlisten(g_held[p]);
        dm_motion_detach(g_held[p], p);   // player 1's: the phone's gyro (if on) takes over from its next sample
        dm_haptics_apple_controller(p, nil);
        pad_slot_free(&g_slots, (__bridge const void *)g_held[p]); g_held[p] = nil;
        dm_pad_set_player(p, 0, 0, 0, 0, 0);   // nothing stays pressed
    }
    for (GCController *c in now) if (c != gone && pad_usable(c) && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) {
        if (g_press_to_join) {   // a player at its first button (read_pad)
            waiting = YES;
            if (pad_listen(c)) LOG("controller '%s' connected: press a button to play (DM_PAD_PRESS_TO_JOIN)", pad_name(c));
            continue;
        }
        int p = pad_slot_take(&g_slots, (__bridge const void *)c, pad_name(c));
        if (p < 0) { LOG("controller '%s' connected: all %d players are taken, not used", pad_name(c), DM_PLAYERS); continue; }
        g_held[p] = c; pad_listen(c);
        dm_motion_attach(c, p);
        npad_name(p, nb, sizeof nb); LOG("controller '%s' connected: player %d (npad %s)%s", pad_name(c), p + 1, nb, c.motion.hasRotationRate ? ", with motion (gyro)" : "");
        read_pad(c);
    }
    dm_pad_players(pad_slot_mask(&g_slots));
    dispatch_async(dispatch_get_main_queue(), ^{ cp_poll(); });   // a controller came or went while the controller applet's prompt is up
    return waiting || pad_slot_mask(&g_slots) != 0;   // a controller waiting for its first press hides the touch gamepad too
}
- (void)padsChanged:(NSNotification *)note {
    GCController *c = note.object, *gone = [note.name isEqual:GCControllerDidDisconnectNotification] ? c : nil;
    if (gone) pad_unlisten(gone);   // even a controller still waiting for its first press can have a handler
    if (c) { BOOL usable = pad_usable(c); if (!usable || g_merge) LOG("controller %s: %s%s", gone ? "disconnected" : "connected", pad_name(c), usable ? "" : " (no supported gamepad profile: not used)"); }
    BOOL any = g_merge ? pads_merged(gone) : pads_slotted(gone);
    dispatch_async(dispatch_get_main_queue(), ^{   // the touch gamepad hides while any controller is in use; the front end lays the game view out again (with them hidden, as it was before the controls were drawn into its frame)
        self->_padOff = any; self->_controls.hidden = any || (self->_touchDraw && self->_inFrame); [self reset]; [self.superview setNeedsLayout];
    });
}
@end

// The controller applet's prompt (front.h front_ctrl_support, ctrl_prompt.h; GitHub issue #1640), as the Mac's (front_mac.m): the game asked for more players than it sees, and
// the game's thread waits while a card is up over the game. A controller that joins meanwhile is a player at once (its first button with DM_PAD_PRESS_TO_JOIN, its connection
// without) and the count follows. A and B are GameController's buttonA and buttonB on an extended pad, or a lone Joy-Con's mapped A and B (the joining press does not count); the card's
// Done and Cancel buttons take touches, and its scrim keeps every other touch from the game and the touch gamepad. The game gets no controller input while it is up, nor
// until the A or B that closed it is let go. A front end passes the texts in the player's language as DM_CTRL_PROMPT_TEXT (cp_text). Main thread
static ctrl_prompt g_cp; static int g_cp_confirm, g_cp_cancel, g_cp_ok;
static int cp_up(void) { return g_cp.phase != CP_IDLE; }   // the prompt has the controllers: Home opens no menu
static UIView *g_cp_view; static UILabel *g_cp_count; static UIButton *g_cp_done_btn; static dispatch_semaphore_t g_cp_done;
@interface DmCtrlPrompt : NSObject @end
@implementation DmCtrlPrompt
- (void)done { g_cp_confirm = 1; cp_poll(); }
- (void)cancel { g_cp_cancel = 1; cp_poll(); }
@end
static DmCtrlPrompt *g_cp_target;
static void cp_buttons(int *a, int *b) {
    *a = *b = 0;
    for (GCController *c in GCController.controllers) {
        GCExtendedGamepad *g = c.extendedGamepad;
        if (g) { *a |= g.buttonA.isPressed; *b |= g.buttonB.isPressed; }
        else if (pad_usable(c)) { uint64_t m = pad_live_buttons(pad_live_input(c)); *a |= (m & DM_BTN_A) != 0; *b |= (m & DM_BTN_B) != 0; }
    }
    for (s2_pad *d = dm_switch2_pads(); d; d = d->next) s2_pad_ab(&d->st, a, b);   // Switch 2 controllers (pad_switch2_apple.h)
}
static int cp_waiting(void) {   // connected controllers that are no player yet
    int n = 0;
    if (!g_merge) for (GCController *c in GCController.controllers) if (pad_usable(c) && pad_slot_of(&g_slots, (__bridge const void *)c) < 0) n++;
    if (!g_merge) for (s2_pad *d = dm_switch2_pads(); d; d = d->next) if (pad_slot_of(&g_slots, d) < 0) n++;
    return n;
}
static UILabel *cp_label(const char *text, CGFloat size, UIFontWeight w, CGFloat alpha) {
    UILabel *l = [UILabel new]; l.font = dm_ui_font(size, w); l.textColor = [UIColor colorWithWhite:1 alpha:alpha];
    l.numberOfLines = 0; l.textAlignment = NSTextAlignmentCenter; dm_ui_label_text(l, @(text)); return l;
}
static UIButton *cp_button(const char *title, SEL action, int primary) {
    UIButtonConfiguration *cfg = primary ? UIButtonConfiguration.filledButtonConfiguration : UIButtonConfiguration.grayButtonConfiguration;
    cfg.title = @(title); cfg.cornerStyle = UIButtonConfigurationCornerStyleCapsule; cfg.buttonSize = UIButtonConfigurationSizeLarge;
    if (dm_ui_font_on()) {   // the title in the UI font (a large button's is 17 pt at the default text size), scaled with Dynamic Type as the configuration's own font is; without it that font, as before
        UIFont *f = dm_ui_font(17, UIFontWeightSemibold);
        cfg.titleTextAttributesTransformer = ^NSDictionary<NSAttributedStringKey, id> *(NSDictionary<NSAttributedStringKey, id> *a) {
            NSMutableDictionary<NSAttributedStringKey, id> *m = [a mutableCopy];
            m[NSFontAttributeName] = [[UIFontMetrics metricsForTextStyle:UIFontTextStyleHeadline] scaledFontForFont:f];   // the button's text size (the transformer runs with its traits)
            return m;
        };
    }
    UIButton *b = [UIButton buttonWithConfiguration:cfg primaryAction:nil];
    [b addTarget:g_cp_target action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
static void cp_show(void) {   // the card once per prompt; its count and its Done button follow each step
    const char *env = getenv("DM_CTRL_PROMPT_TEXT"); char t[CP_TEXTS][256];
    for (int i = 0; i < CP_TEXTS; i++) cp_text(env, i, &g_cp, t[i], sizeof t[i]);
    if (!g_cp_view) {
        UIWindow *w = g_view.window;
        if (!w) for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) if ([sc isKindOfClass:UIWindowScene.class]) for (UIWindow *x in ((UIWindowScene *)sc).windows) if (x.isKeyWindow) w = x;
        if (!w) return;
        if (!g_cp_target) g_cp_target = [DmCtrlPrompt new];
        UIView *scrim = [[UIView alloc] initWithFrame:w.bounds]; scrim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        scrim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.6];
        g_cp_count = cp_label(t[CP_TEXT_COUNT], 20, UIFontWeightSemibold, 0.9);
        g_cp_done_btn = cp_button(t[CP_TEXT_DONE], @selector(done), 1);
        UIStackView *actions = [[UIStackView alloc] initWithArrangedSubviews:@[g_cp_done_btn, cp_button(t[CP_TEXT_CANCEL], @selector(cancel), 0)]];
        actions.spacing = 16; actions.distribution = UIStackViewDistributionFillEqually;
        UIStackView *card = [[UIStackView alloc] initWithArrangedSubviews:@[cp_label(t[CP_TEXT_TITLE], 26, UIFontWeightBold, 1), cp_label(t[CP_TEXT_HINT], 17, UIFontWeightRegular, 0.6), g_cp_count, actions]];
        card.axis = UILayoutConstraintAxisVertical; card.spacing = 14; [card setCustomSpacing:28 afterView:g_cp_count];
        card.layoutMargins = UIEdgeInsetsMake(32, 36, 28, 36); card.layoutMarginsRelativeArrangement = YES;
        card.backgroundColor = [UIColor colorWithRed:0.10 green:0.10 blue:0.11 alpha:1]; card.layer.cornerRadius = 28;
        card.translatesAutoresizingMaskIntoConstraints = NO;
        [scrim addSubview:card];
        NSLayoutConstraint *wide = [card.widthAnchor constraintEqualToConstant:520]; wide.priority = UILayoutPriorityDefaultHigh;   // narrower on a narrow screen
        [NSLayoutConstraint activateConstraints:@[[card.centerXAnchor constraintEqualToAnchor:scrim.centerXAnchor], [card.centerYAnchor constraintEqualToAnchor:scrim.centerYAnchor],
            [card.widthAnchor constraintLessThanOrEqualToAnchor:scrim.widthAnchor constant:-32], wide]];
        [w addSubview:scrim]; g_cp_view = scrim;
    }
    dm_ui_label_text(g_cp_count, @(t[CP_TEXT_COUNT]));
    g_cp_done_btn.enabled = cp_can_confirm(&g_cp);
}
// One step of the prompt (a button, a touch on the card, a controller joining, coming or going); returns whether it keeps the game's input
static int cp_poll(void) {
    if (g_cp.phase == CP_IDLE) return 0;
    int a, b, joined = dm_players_reported(); cp_buttons(&a, &b);
    int confirm = g_cp_confirm, cancel = g_cp_cancel; g_cp_confirm = g_cp_cancel = 0;
    cp_phase was = g_cp.phase, ph = cp_step(&g_cp, joined, cp_waiting(), a, b, confirm, cancel);
    if (was == CP_OPEN && ph == CP_OPEN) cp_show();
    if (was == CP_OPEN && ph != CP_OPEN) {
        [g_cp_view removeFromSuperview]; g_cp_view = nil; g_cp_count = nil; g_cp_done_btn = nil;
        LOG("front end: controller prompt closed: %d players (%s)", joined, g_cp.ok ? "done" : "canceled");
        g_cp_ok = g_cp.ok; dispatch_semaphore_signal(g_cp_done);
        ph = cp_step(&g_cp, joined, 0, a, b, 0, 0);   // nothing held: the game has its input at once
    }
    if (ph == CP_IDLE) { for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) read_pad(g_held[p]); return 0; }   // each controller read as it is now
    return 1;
}
int front_ctrl_support(int min, int max) {
    if (!front_metal_layer()) return -1;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (dm_game_panel_shown()) dm_game_panel_close();   // the in-game panel gives way: it holds the controllers (g_menu_block), which the prompt needs
        [g_view reset]; dm_touch_set(NULL, 0);   // nothing the game held stays pressed while the prompt has the input
        if (g_merge) dm_pad_set(0, 0, 0, 0, 0); else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
        int a, b; cp_buttons(&a, &b);
        g_cp_done = done; cp_open(&g_cp, min, max, dm_players_reported(), a, b);
        LOG("front end: controller prompt open: %d to %d players wanted, %d in, %d controllers waiting to join", min, max, g_cp.joined, cp_waiting());
        cp_show(); cp_poll();
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    return g_cp_ok;
}
static int s2pad_player(s2_pad *d) { return g_merge ? 0 : pad_slot_of(&g_slots, d); }
// DM_PAD_MERGE: player 1's rumble follows the controller last used, as pad_report hands it to a GameController one (as front_mac.m)
static void merge_rumble_to_s2(int on) {
    if (!g_merge || g_merge_s2_rumble == on) return;
    g_merge_s2_rumble = on; dm_haptics_apple_set_sink(0, on ? dm_switch2_rumble : NULL);
}
static int s2pad_blocked(void) { return g_s2_off || cp_blocks_input(g_cp.phase); }   // no input to the game (in the background, or the controller prompt up)
static const s2_pad *g_s2_capture_down[8];   // the Switch 2 pads whose Capture is held (a pad that goes is dropped in s2pad_detach)
static int s2_capture_edge(const s2_pad *d, int held) {   // 1 at the press, -1 at the release, 0 otherwise
    int at = -1, free_at = -1;
    for (int i = 0; i < 8; i++) { if (g_s2_capture_down[i] == d) at = i; else if (!g_s2_capture_down[i] && free_at < 0) free_at = i; }
    if (!held) { if (at >= 0) { g_s2_capture_down[at] = NULL; return -1; } return 0; }
    if (at >= 0) return 0;
    if (free_at >= 0) g_s2_capture_down[free_at] = d;
    return 1;
}
static void s2pad_read(s2_pad *d) {
    if (g_s2_off) return;
    int p = s2pad_player(d);
    uint64_t m; int32_t st[4]; if (!s2_pad_input(&d->st, &m, st)) return;
    { int e = s2_capture_edge(d, s2_pad_capture(&d->st)); if (e) pad_capture_press(nil, e > 0); }   // Capture: a screenshot, or held, a recording (pad_capture_press)
    if (p < 0) {   // DM_PAD_PRESS_TO_JOIN=1: it joins at its first button, as a GameController one does (pad_report)
        char nb[16];
        if (!g_press_to_join || !m) return;
        if ((p = pad_slot_take_lowest(&g_slots, d, d->name)) < 0) { LOG("controller '%s' (Bluetooth): a button pressed, but all %d players are taken", d->name, DM_PLAYERS); return; }
        dm_pad_players(pad_slot_mask(&g_slots)); dm_haptics_apple_set_sink(p, dm_switch2_rumble);   // its rumble goes over Bluetooth, not to a Core Haptics engine
        npad_name(p, nb, sizeof nb); LOG("controller '%s' (Bluetooth): a button pressed: player %d (npad %s)", d->name, p + 1, nb);
        [g_view padsChanged:nil];   // the touch gamepad hides
    }
    if (cp_poll()) return;   // the controller applet's prompt has the controllers (front_ctrl_support)
    if (m) merge_rumble_to_s2(1);
    if (g_merge) dm_pad_set(m, st[0], st[1], st[2], st[3]); else dm_pad_set_player(p, m, st[0], st[1], st[2], st[3]);
}
static int s2pad_attach(s2_pad *d) {   // 1: kept (a player, or waiting for its first button press); 0: no free player (pad_switch2_apple.h)
    if (g_press_to_join && !g_merge) { LOG("controller '%s' (Bluetooth) connected: press a button to play (DM_PAD_PRESS_TO_JOIN)", d->name); cp_poll(); return 1; }
    int p = g_merge ? 0 : pad_slot_take(&g_slots, d, d->name); char nb[16];
    if (p < 0) { LOG("controller '%s' (Bluetooth) connected: all %d players are taken, not used", d->name, DM_PLAYERS); return 0; }
    npad_name(p, nb, sizeof nb); LOG("controller '%s' (Bluetooth) connected: player %d (npad %s)", d->name, p + 1, nb);
    if (!g_merge) { dm_pad_players(pad_slot_mask(&g_slots)); dm_haptics_apple_set_sink(p, dm_switch2_rumble); }   // its rumble goes over Bluetooth, not to a Core Haptics engine
    [g_view padsChanged:nil];   // the touch gamepad hides
    cp_poll();   // one controller fewer to wait for
    return 1;
}
static void s2pad_detach(s2_pad *d) {   // d is already off the transport's list
    s2_capture_edge(d, 0);
    if (g_merge) { LOG("controller '%s' (Bluetooth) disconnected", d->name); if (!dm_switch2_pads()) merge_rumble_to_s2(0); dm_pad_set(0, 0, 0, 0, 0); [g_view padsChanged:nil]; return; }
    int p = pad_slot_free(&g_slots, d); char nb[16]; if (p < 0) { cp_poll(); return; }   // one that had not joined: one fewer waiting
    dm_haptics_apple_set_sink(p, NULL);
    npad_name(p, nb, sizeof nb); LOG("controller '%s' (Bluetooth) disconnected: player %d (npad %s) is free", d->name, p + 1, nb);
    dm_pad_set_player(p, 0, 0, 0, 0, 0);
    dm_pad_players(pad_slot_mask(&g_slots));
    [g_view padsChanged:nil];
    cp_poll();   // one player fewer
}
static const dm_switch2_front g_s2front = {s2pad_attach, s2pad_detach, s2pad_read, s2pad_player, s2pad_blocked};

UIView *dm_gamepad_view(CGRect frame) { DmGamepad *v = [[DmGamepad alloc] initWithFrame:frame]; g_view = v; return v; }
void dm_gamepad_arrange(UIView *view, DmLayout layout) { [(DmGamepad *)view arrange:layout]; }
void dm_gamepad_opmode_changed(void) { [g_view opmodeChanged]; }
BOOL dm_gamepad_controls_shown(UIView *view) { return [(DmGamepad *)view controlsShown]; }
CGRect dm_gamepad_top_center(UIView *view) { DmGamepad *g = (DmGamepad *)view; return CGRectUnion([g pillRect:B_MINUS], [g pillRect:B_PLUS]); }
void dm_gamepad_touch_draw(UIView *view, BOOL on, CGRect canvas, CGFloat scale, CGRect picture) { [(DmGamepad *)view touchDraw:on canvas:canvas scale:scale picture:picture]; }
void front_touch_drawn(uint32_t seq) { dispatch_async(dispatch_get_main_queue(), ^{ [g_touch_pad touchDrawn:seq]; }); }   // touch_draw.h: the present's completion handler
void front_touch_unfit(void) { dispatch_async(dispatch_get_main_queue(), ^{ [g_touch_pad touchUnfit]; }); }   // touch_draw.h: the present thread
void dm_gamepad_touch_feedback(bool on) { [g_view setTouchFeedback:on]; }
void dm_gamepad_touch_look(const char *env, const char *value) {   // front_ios.m dm_setting_live: DM_TOUCH_SIZE or DM_TOUCH_OPACITY from the in-game menu, at once
    BOOL size = !strcmp(env, "DM_TOUCH_SIZE");
    CGFloat v = touch_value(env, value, size ? 0.5 : 0.1, size ? 1 : 2);
    if (size) [g_view setTouchSize:v]; else [g_view setTouchOpacity:v];
    LOG("front end: touch control %s %.2f (in-game menu)", size ? "size" : "opacity", v);
}
double dm_gamepad_size(void) { return g_touch_size; }   // front_ios.m: the frame-rate counter sits in the top row by the same units
void dm_gamepad_menu_open(void) { if (g_view) [g_view menuOpenNow]; else LOG("front end: no touch controls yet: the in-game menu cannot open"); }   // main thread (LauncherShortcuts.swift)
void dm_gamepad_hint(void) { [g_view menuShow]; }   // main thread: the menu button shows for 5 s (front_ios.m: the game's first picture, the end of the progress screen)
int dm_pad_layout(void) { return g_view ? [g_view padLayout] : 0; }
int dm_gamepad_touch_hidden(void) { return g_view ? [g_view touchHidden] : 0; }   // front_ios.m dm_setting_why: the touch rows' note in the in-game menu
bool dm_pad_layout_offered(int layout) { return layout == 0 || layout == 1 || (layout == 2 && dm_opmode() == 0); }
void dm_pad_layout_set(int layout) { [g_view setPadLayout:layout]; }
void dm_gamepad_active(void) { dispatch_async(dispatch_get_main_queue(), ^{ for (GCController *c in GCController.controllers) dm_motion_rearm(c); g_s2_off = 0; dm_switch2_active(1); for (s2_pad *d = dm_switch2_pads(); d; d = d->next) s2pad_read(d); }); }   // On become active: motion_apple.h
void dm_gamepad_reset(void) {   // On resign active: release everything (a key held while switching away and released in background gets no "release")
    dispatch_async(dispatch_get_main_queue(), ^{ [g_view reset]; g_s2_off = 1; dm_switch2_active(0); });
    for (int p = 0; p < DM_PLAYERS; p++) { int s2 = 0; for (s2_pad *d = dm_switch2_pads(); d; d = d->next) if (s2pad_player(d) == p) s2 = 1; if (s2) dm_pad_set_player(p, 0, 0, 0, 0, 0); }
    pthread_mutex_lock(&g_mu); g_shake_btn = 0; pthread_mutex_unlock(&g_mu); publish();
    if (g_merge) dm_pad_set(0, 0, 0, 0, 0);
    else for (int p = 0; p < DM_PLAYERS; p++) if (g_held[p]) dm_pad_set_player(p, 0, 0, 0, 0, 0);
}
