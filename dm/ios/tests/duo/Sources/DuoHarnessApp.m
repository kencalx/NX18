#import <UIKit/UIKit.h>
#include "ui_font.h"   // NX 18's UI font, registered as main.m does
#import <GameController/GameController.h>
#import "DmLayout.h"
#import "DuoHarnessRuntime.h"
#include <stdlib.h>
#include <string.h>
#include <objc/runtime.h>
#if __has_include(<UIKit/UIHingeInteraction.h>)
#import <UIKit/UIHingeInteraction.h>
#endif

UIViewController *front_ios_root(void);
void front_ios_scene(UIWindowScene *scene);   // front_ios.m: caches the scene's screen (size, rate, brightness), as main.m does
void dm_shortcut_cold(const char *type);   // LauncherShortcuts.swift: home screen shortcuts, handed over as main.m's SceneDelegate does
bool dm_shortcut_perform(const char *type);
void dm_gamepad_menu_open(void);   // DmGamepad.m: opens the in-game menu (DUO_MENU_OPEN)

static NSArray<NSNumber *> *DuoHarnessRectArray(CGRect rect) {
    return @[@(CGRectGetMinX(rect)), @(CGRectGetMinY(rect)), @(CGRectGetWidth(rect)), @(CGRectGetHeight(rect))];
}

static NSArray<NSArray<NSNumber *> *> *DuoHarnessTouchArray(DuoHarnessInput input) {
    NSMutableArray *touches = [NSMutableArray arrayWithCapacity:(NSUInteger)input.last_touch_count];
    for (int i = 0; i < input.last_touch_count; i++) {
        [touches addObject:@[@(input.last_touches[i].x), @(input.last_touches[i].y)]];
    }
    return touches;
}

@interface DuoHarnessDiagnosticsOverlay : UIView
@property (nonatomic, copy) void (^didLayout)(void);
@end

@implementation DuoHarnessDiagnosticsOverlay
- (void)layoutSubviews {
    [super layoutSubviews];
    if (self.didLayout) self.didLayout();
}
@end

// A scripted controller for the settings screen (docs/settings.md, Presets, the guide and a controller): DUO_PAD_SCRIPT is a comma-separated list of steps run one every 0.35 s on a hidden virtual
// controller, after DUO_PAD_DELAY seconds (default 2): up, down, left, right (the D-pad), a, b, y, plus, l, r (Switch buttons: the virtual pad is not a Nintendo one, so A is its
// right button, as pad_apple.h maps it), wait (one step of nothing). The controller stays connected afterwards, so the focus ring stays on screen for a screenshot
API_AVAILABLE(ios(17.0)) static GCVirtualController *g_script_pad;
static BOOL duo_pad_nintendo(void);   // DUO_PAD_KIND, below
API_AVAILABLE(ios(17.0)) static void duo_pad_step(NSArray<NSString *> *steps, NSUInteger i) {
    if (i >= steps.count) { NSLog(@"duo: pad script done"); return; }
    NSString *s = [steps[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    NSDictionary<NSString *, NSValue *> *dirs = @{@"up": [NSValue valueWithCGPoint:CGPointMake(0, 1)], @"down": [NSValue valueWithCGPoint:CGPointMake(0, -1)],
                                                   @"left": [NSValue valueWithCGPoint:CGPointMake(-1, 0)], @"right": [NSValue valueWithCGPoint:CGPointMake(1, 0)]};
    NSDictionary<NSString *, NSString *> *buttons = duo_pad_nintendo()
        ? @{@"a": GCInputButtonA, @"b": GCInputButtonB, @"y": GCInputButtonY, @"x": GCInputButtonX, @"plus": GCInputButtonMenu, @"l": GCInputLeftShoulder, @"r": GCInputRightShoulder}
        : @{@"a": GCInputButtonB, @"b": GCInputButtonA, @"y": GCInputButtonX, @"x": GCInputButtonY, @"plus": GCInputButtonMenu, @"l": GCInputLeftShoulder, @"r": GCInputRightShoulder};
    void (^release)(void) = ^{};
    if (dirs[s]) {
        [g_script_pad setPosition:dirs[s].CGPointValue forDirectionPadElement:GCInputDirectionPad];
        release = ^{ [g_script_pad setPosition:CGPointZero forDirectionPadElement:GCInputDirectionPad]; };
    } else if (buttons[s]) {
        NSString *b = buttons[s];
        [g_script_pad setValue:1 forButtonElement:b];
        release = ^{ [g_script_pad setValue:0 forButtonElement:b]; };
    } else if (![s isEqualToString:@"wait"]) NSLog(@"duo: pad script step %@ unknown", s);
    NSLog(@"duo: pad script %@", s);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 8)), dispatch_get_main_queue(), release);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * 0.35)), dispatch_get_main_queue(), ^{ duo_pad_step(steps, i + 1); });
}
// DUO_PAD_KIND=nintendo: every controller presents itself as a Switch Pro Controller (productCategory), so the hints show a Nintendo pad's labels and the script's a / b / x / y
// are the pad's buttons of those names (pad_apple.h: a Nintendo pad by its labels). For screenshots of the controller hints; any other value keeps the pads as they are
static BOOL duo_pad_nintendo(void) { return [NSProcessInfo.processInfo.environment[@"DUO_PAD_KIND"] isEqualToString:@"nintendo"]; }
static NSString *duo_nintendo_category(id self, SEL _cmd) { (void)self; (void)_cmd; return @"Switch Pro Controller"; }
static void duo_pad_kind(void) {
    if (!duo_pad_nintendo()) return;
    Method m = class_getInstanceMethod(GCController.class, @selector(productCategory));
    if (m) method_setImplementation(m, (IMP)duo_nintendo_category);
    NSLog(@"duo: controllers present themselves as Switch Pro Controllers (DUO_PAD_KIND=nintendo)");
}
// DUO_BACKDROP: a picture over the (empty) game view, below the touch controls and the menu: a file path (placeholder art) or #RRGGBB, for screenshots of the menu button and
// the in-game menu over a bright or a dark scene
static void duo_backdrop(UIViewController *root, int tries) {
    NSString *b = NSProcessInfo.processInfo.environment[@"DUO_BACKDROP"];
    if (!b.length) return;
    UIView *game = [root valueForKey:@"game"];
    if (!game.superview) {   // the game view comes when the game starts (front_ios.m startGame): look again a little later
        if (tries < 50) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 10)), dispatch_get_main_queue(), ^{ duo_backdrop(root, tries + 1); });
        return;
    }
    UIImageView *v = [[UIImageView alloc] initWithFrame:root.view.bounds];
    v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    v.contentMode = UIViewContentModeScaleAspectFill; v.clipsToBounds = YES; v.userInteractionEnabled = NO;
    if ([b hasPrefix:@"#"] && b.length == 7) {
        unsigned rgb = 0; [[NSScanner scannerWithString:[b substringFromIndex:1]] scanHexInt:&rgb];
        v.backgroundColor = [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
    } else v.image = [UIImage imageWithContentsOfFile:b];
    [game.superview insertSubview:v aboveSubview:game];
}
static void duo_pad_script(void) {
    NSString *script = NSProcessInfo.processInfo.environment[@"DUO_PAD_SCRIPT"];
    if (!script.length) return;
    if (@available(iOS 17.0, *)) {
        GCVirtualControllerConfiguration *config = [GCVirtualControllerConfiguration new];
        config.hidden = YES;
        config.elements = [NSSet setWithArray:@[GCInputButtonA, GCInputButtonB, GCInputButtonX, GCInputButtonY, GCInputLeftShoulder, GCInputRightShoulder,
                                                 GCInputButtonMenu, GCInputLeftThumbstick, GCInputDirectionPad]];
        g_script_pad = [[GCVirtualController alloc] initWithConfiguration:config];
        double delay = NSProcessInfo.processInfo.environment[@"DUO_PAD_DELAY"].doubleValue ?: 2;
        NSArray<NSString *> *steps = [script componentsSeparatedByString:@","];
        [g_script_pad connectWithReplyHandler:^(NSError *error) {
            if (error) { NSLog(@"duo: pad script: no virtual controller (%@)", error); return; }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * delay)), dispatch_get_main_queue(), ^{ duo_pad_step(steps, 0); });
        }];
    }
}

@interface DuoHarnessAppDelegate : UIResponder <UIApplicationDelegate>
@end

@interface DuoHarnessSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@property (nonatomic, strong) UILabel *diagnosticsLabel;
@property (nonatomic, strong) id inputObserver;
@property (nonatomic) NSInteger diagnosticHingeStatus;
@property (nonatomic) CGFloat diagnosticHingeAngle;
#if __has_include(<UIKit/UIHingeInteraction.h>)
@property (nonatomic, strong) UIHingeInteraction *diagnosticHingeInteraction API_AVAILABLE(ios(27.1));
#endif
- (void)refreshDiagnostics;
@end

@implementation DuoHarnessAppDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    (void)application; (void)options;
    // Synthetic touches should not start device motion or trigger hardware feedback.
    setenv("DM_MOTION", "0", 1);
    setenv("DM_TOUCH_HAPTICS", "0", 1);
    return YES;
}
- (UISceneConfiguration *)application:(UIApplication *)application
    configurationForConnectingSceneSession:(UISceneSession *)session
    options:(UISceneConnectionOptions *)options {
    (void)application; (void)options;
    return [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
}
@end

@implementation DuoHarnessSceneDelegate
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    (void)session;
    if (![scene isKindOfClass:UIWindowScene.class]) return;
    if (options.shortcutItem) dm_shortcut_cold(options.shortcutItem.type.UTF8String);   // opened from a home screen shortcut, as main.m's SceneDelegate
    front_ios_scene((UIWindowScene *)scene);   // before the window and views that read the screen, as main.m's SceneDelegate
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    UIViewController *root = front_ios_root();
    self.window.rootViewController = root;
    [self.window makeKeyAndVisible];
    duo_backdrop(root, 0);
    duo_pad_kind();
    duo_pad_script();
    double menuAt = NSProcessInfo.processInfo.environment[@"DUO_MENU_OPEN"].doubleValue;   // docs/settings.md, In-game menu: open it after that many seconds, for a screenshot
    if (menuAt > 0) dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC * menuAt)), dispatch_get_main_queue(), ^{ NSLog(@"duo: in-game menu open"); dm_gamepad_menu_open(); });

    self.diagnosticHingeStatus = -1;
    self.diagnosticHingeAngle = -1;
    self.diagnosticsLabel = [UILabel new];
    self.diagnosticsLabel.frame = CGRectMake(0, 0, 1, 1);
    self.diagnosticsLabel.isAccessibilityElement = YES;
    self.diagnosticsLabel.accessibilityIdentifier = @"duo.diagnostics";
    self.diagnosticsLabel.accessibilityLabel = @"Duo native rotation diagnostics";
    self.diagnosticsLabel.accessibilityTraits = UIAccessibilityTraitStaticText;
    self.diagnosticsLabel.userInteractionEnabled = NO;

    DuoHarnessDiagnosticsOverlay *overlay = [[DuoHarnessDiagnosticsOverlay alloc] initWithFrame:root.view.bounds];
    overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    overlay.backgroundColor = UIColor.clearColor;
    overlay.userInteractionEnabled = NO;
    [overlay addSubview:self.diagnosticsLabel];
    __weak DuoHarnessSceneDelegate *weakSelf = self;
    overlay.didLayout = ^{ [weakSelf refreshDiagnostics]; };
    [root.view addSubview:overlay];

    self.inputObserver = [NSNotificationCenter.defaultCenter addObserverForName:DuoHarnessInputDidChangeNotification
                                                                          object:nil
                                                                           queue:NSOperationQueue.mainQueue
                                                                      usingBlock:^(NSNotification *note) {
        (void)note;
        [weakSelf refreshDiagnostics];
    }];
#if __has_include(<UIKit/UIHingeInteraction.h>)
    if (@available(iOS 27.1, *)) {
        self.diagnosticHingeInteraction = [[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction *interaction, UIHingeInteractionUpdate *update) {
            (void)interaction;
            UIHinge *hinge = update.hinge;
            weakSelf.diagnosticHingeStatus = hinge ? hinge.status : -1;
            weakSelf.diagnosticHingeAngle = hinge ? hinge.angle : -1;
            [weakSelf refreshDiagnostics];
        }];
        [root.view addInteraction:self.diagnosticHingeInteraction];
    }
#endif
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshDiagnostics]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(NSEC_PER_SEC / 2)), dispatch_get_main_queue(), ^{
        [weakSelf.window.rootViewController.view layoutIfNeeded];
        [weakSelf refreshDiagnostics];
    });
}

- (void)windowScene:(UIWindowScene *)windowScene performActionForShortcutItem:(UIApplicationShortcutItem *)item completionHandler:(void (^)(BOOL))done {
    (void)windowScene; done(dm_shortcut_perform(item.type.UTF8String));   // a home screen shortcut while the harness runs, as main.m's SceneDelegate
}

- (void)windowScene:(UIWindowScene *)windowScene
    didUpdateEffectiveGeometry:(UIWindowSceneGeometry *)previousEffectiveGeometry API_AVAILABLE(ios(26.0)) {
    (void)windowScene; (void)previousEffectiveGeometry;
    __weak DuoHarnessSceneDelegate *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf refreshDiagnostics]; });
}

- (void)refreshDiagnostics {
    UIWindow *window = self.window;
    UIViewController *root = window.rootViewController;
    if (!window || !root || !self.diagnosticsLabel) return;
    UIWindowScene *scene = window.windowScene;
    UIView *game = [root valueForKey:@"game"];
    UIView *pad = [root valueForKey:@"pad"];
    if (!game || !pad) {
        self.diagnosticsLabel.accessibilityValue = @"Duo diagnostics unavailable: production gamepad has not started";
        return;
    }
    NSValue *storedLayout = [pad valueForKey:@"layout"];
    if (![storedLayout isKindOfClass:NSValue.class] || strcmp(storedLayout.objCType, @encode(DmLayout)) != 0) {
        self.diagnosticsLabel.accessibilityValue = @"Duo diagnostics unavailable: production gamepad layout is not readable";
        return;
    }
    self.diagnosticsLabel.frame = game.frame;
    DmLayout layout;
    [storedLayout getValue:&layout size:sizeof(layout)];

    DuoHarnessInput input = duo_harness_input();
    NSDictionary *snapshot = @{
        @"orientation": @(scene.effectiveGeometry.interfaceOrientation),
        @"bounds": DuoHarnessRectArray(root.view.bounds),
        @"game": DuoHarnessRectArray(game.frame),
        @"controls": DuoHarnessRectArray(layout.controls),
        @"separated": @(layout.separated),
        @"touchCount": @(input.touch_count),
        @"touchUpdates": @(input.touch_update_count),
        @"lastTouches": DuoHarnessTouchArray(input),
        @"hingeStatus": @(self.diagnosticHingeStatus),
        @"hingeAngle": @(self.diagnosticHingeAngle)
    };
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:snapshot options:0 error:&error];
    if (!data) {
        self.diagnosticsLabel.accessibilityValue = [NSString stringWithFormat:@"diagnostics error: %@", error];
        return;
    }
    NSString *value = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (![self.diagnosticsLabel.accessibilityValue isEqualToString:value]) self.diagnosticsLabel.accessibilityValue = value;
}

- (void)dealloc {
    if (self.inputObserver) [NSNotificationCenter.defaultCenter removeObserver:self.inputObserver];
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool { dm_ui_font_register(NSBundle.mainBundle.resourcePath.fileSystemRepresentation); }   // as main.m: SIMCTL_CHILD_DM_UI_FONT=<file> shows the screens in that font
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(DuoHarnessAppDelegate.class)); }
}
