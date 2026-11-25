// The touch controls drawn into the game's frame (dm/host/touch_draw.h; DmGamepad.m touchDraw:, front_ios.m viewDidLayoutSubviews): the canvas and the picture's place on it in
// each picture mode and pose, the production root turning it on after the first picture and off for the Tap layout and a controller, and the frames and the atlas the gamepad hands
// the present composited here as the present does (premultiplied alpha over), against the same controls drawn on their layers (the render server's snapshot of the view, or the
// layers rendered). The present itself is nvn_mtl.m's (dm/gfx/tests/t_present_touch.m); the harness has none, so the stubs keep what the gamepad handed over (DuoRuntimeStubs.m)
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#import "DmLayout.h"
#import "DmGameMenu.h"
#import "DuoHarnessRuntime.h"
#include "dm_input.h"
void front_picture_shape(int w, int h);   // front_ios.m (dm/host/front.h)

@interface DuoTouchDrawTests : XCTestCase
@end
@interface UIView (DuoTouchDrawPad)
- (void)setPadLayout:(int)l;   // DmGamepad.m: the in-game menu's layout pick, on this pad (dm_pad_layout_set takes the last pad made, which another test may have made)
@end

typedef struct { int w, h; uint8_t *px; } DuoImage;   // BGRA, premultiplied
static DuoImage duo_image(int w, int h) { return (DuoImage){w, h, calloc((size_t)w * h, 4)}; }
static void duo_fill(DuoImage im, uint8_t grey) { for (int i = 0; i < im.w * im.h; i++) { uint8_t *p = im.px + i * 4; p[0] = p[1] = p[2] = grey; p[3] = 255; } }   // a light grey shows the shadows, which black hides
#define DUO_GREY 170
// The present's draw (present.metal vs_touch / fs_touch, host_msl_rps_over): each quad over the canvas, the atlas sampled bilinearly at pixel centres, premultiplied over
static void duo_composite(DuoImage canvas, const touch_frame *f, const uint8_t *atlas, int aw, int ah) {
    for (uint32_t k = 0; k < f->n; k++) {
        const touch_quad *q = &f->q[k];
        double dx = q->dst[0] * canvas.w, dy = q->dst[1] * canvas.h, dw = q->dst[2] * canvas.w, dh = q->dst[3] * canvas.h;
        for (int y = MAX(0, (int)floor(dy)); y < MIN(canvas.h, (int)ceil(dy + dh)); y++)
            for (int x = MAX(0, (int)floor(dx)); x < MIN(canvas.w, (int)ceil(dx + dw)); x++) {
                double cx = x + 0.5, cy = y + 0.5;
                if (cx < dx || cx >= dx + dw || cy < dy || cy >= dy + dh) continue;
                double u = (q->src[0] + (cx - dx) / dw * q->src[2]) * aw - 0.5, v = (q->src[1] + (cy - dy) / dh * q->src[3]) * ah - 0.5;
                int u0 = (int)floor(u), v0 = (int)floor(v); double fu = u - u0, fv = v - v0, s[4] = {0};
                for (int j = 0; j < 2; j++) for (int i = 0; i < 2; i++) {
                    int tu = MIN(MAX(u0 + i, 0), aw - 1), tv = MIN(MAX(v0 + j, 0), ah - 1); double wgt = (i ? fu : 1 - fu) * (j ? fv : 1 - fv);
                    const uint8_t *t = atlas + ((size_t)tv * aw + tu) * 4; for (int c = 0; c < 4; c++) s[c] += wgt * t[c];
                }
                uint8_t *p = canvas.px + ((size_t)y * canvas.w + x) * 4; double a = s[3] / 255;
                for (int c = 0; c < 4; c++) p[c] = (uint8_t)lround(MIN(255, s[c] + p[c] * (1 - a)));
            }
    }
}
// How two images differ over the rectangle (x, y, w, h) of a (b's from its origin): the mean of every channel's difference, and the share of pixels off by more than 16 in any
static void duo_diff(DuoImage a, int ax, int ay, DuoImage b, double *mean, double *off, int *worst) {
    double sum = 0; long n = 0, bad = 0; *worst = 0;
    for (int y = 0; y < b.h; y++) for (int x = 0; x < b.w; x++) {
        int X = x + ax, Y = y + ay; if (X < 0 || Y < 0 || X >= a.w || Y >= a.h) continue;
        const uint8_t *p = a.px + ((size_t)Y * a.w + X) * 4, *q = b.px + ((size_t)y * b.w + x) * 4; int m = 0;
        for (int c = 0; c < 3; c++) { int d = abs(p[c] - q[c]); sum += d; m = MAX(m, d); }
        n++; bad += m > 16; *worst = MAX(*worst, m);
    }
    *mean = n ? sum / (3.0 * n) : 0; *off = n ? (double)bad / n : 0;
}
static void duo_save(DuoImage im, NSString *name) {   // for a look: the simulator's temporary folder, path in the log
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(im.px, (size_t)im.w, (size_t)im.h, 8, (size_t)im.w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGImageRef img = CGBitmapContextCreateImage(g);
    NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:name];
    [UIImagePNGRepresentation([UIImage imageWithCGImage:img]) writeToFile:path atomically:YES];
    NSLog(@"duo-touch-draw: %@", path);
    CGImageRelease(img); CGContextRelease(g); CGColorSpaceRelease(cs);
}
// The view's controls as the render server drew them on their layers (drawViewHierarchyInRect; the menu button hidden, as it stays a view of its own), or as the layers render
// (renderInContext), over light grey, at scale
static DuoImage duo_snapshot(UIView *view, CGFloat scale, BOOL server) {
    int w = (int)lround(view.bounds.size.width * scale), h = (int)lround(view.bounds.size.height * scale);
    DuoImage im = duo_image(w, h); duo_fill(im, DUO_GREY);
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CGContextRef g = CGBitmapContextCreate(im.px, (size_t)w, (size_t)h, 8, (size_t)w * 4, cs, (CGBitmapInfo)kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
    CGContextTranslateCTM(g, 0, h); CGContextScaleCTM(g, scale, -scale);
    UIGraphicsPushContext(g);
    if (server) [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:YES]; else [view.layer renderInContext:g];
    UIGraphicsPopContext();
    CGContextRelease(g); CGColorSpaceRelease(cs);
    return im;
}

@implementation DuoTouchDrawTests
- (void)setUp {
    [super setUp];
    [NSUserDefaults.standardUserDefaults setObject:@1 forKey:@"DmPadLayout"];   // 3D: every control drawn
    // The Simulator may report a controller of its own (the Mac's): the root's touch controls show, as with none connected
    UIViewController *root = [self root]; UIView *pad = [root valueForKey:@"pad"];
    if (root.presentedViewController) {   // a suite before left the settings screen over the game (DuoShortcutTests): the game's views are out of the window under it
        XCTestExpectation *gone = [self expectationWithDescription:@"settings screen dismissed"];
        [root dismissViewControllerAnimated:NO completion:^{ [gone fulfill]; }];
        [self waitForExpectations:@[gone] timeout:5];
        XCTNSPredicateExpectation *back = [[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithFormat:@"view.window != nil"] object:root];
        (void)[XCTWaiter waitForExpectations:@[back] timeout:5];
    }
    XCTAssertNotNil(root.view.window, @"the game's views are in the window");
    [pad setValue:@NO forKey:@"padOff"]; [pad setPadLayout:1]; [root.view setNeedsLayout]; [root.view layoutIfNeeded];
}
- (UIViewController *)root {   // the production root's window (a suite before may have left a window of its own key, hidden: DuoGuideTests)
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows)
            if (!window.hidden && [NSStringFromClass(window.rootViewController.class) isEqualToString:@"DmRootVC"]) return window.rootViewController;
    }
    XCTFail(@"no window shows the production root");
    return nil;
}
- (void)settle:(UIViewController *)root {   // the main-queue hops (front_picture_shape, a controller's change) then a layout
    XCTestExpectation *e = [self expectationWithDescription:@"main queue"];
    dispatch_async(dispatch_get_main_queue(), ^{ [e fulfill]; });
    [self waitForExpectations:@[e] timeout:2];
    [root.view setNeedsLayout]; [root.view layoutIfNeeded];
}
// A pad of its own in the root's view, as with no controller: the Simulator may report one (the Mac's), which a new pad hears of on the main queue
- (UIView *)padIn:(UIViewController *)root bounds:(CGRect)b {
    UIView *pad = dm_gamepad_view(b); [root.view addSubview:pad];
    XCTestExpectation *e = [self expectationWithDescription:@"main queue"];
    dispatch_async(dispatch_get_main_queue(), ^{ [e fulfill]; });
    [self waitForExpectations:@[e] timeout:2];
    [pad setValue:@NO forKey:@"padOff"];
    return pad;
}
// A live present draws the last frame and completes (the stubs' stand-in for nvn_mtl.m's), and the gamepad hears of it on the main queue
- (void)presentDraws:(UIViewController *)root {
    (void)duo_harness_present_draws();
    XCTestExpectation *e = [self expectationWithDescription:@"main queue"];
    dispatch_async(dispatch_get_main_queue(), ^{ [e fulfill]; });
    [self waitForExpectations:@[e] timeout:2];
}
// The pad's atlas and frame handed over again: another pad (a root another test made, a pad of its own) may have handed over its own since, and the stubs keep the last of any
- (void)republish:(UIView *)pad { [pad setValue:nil forKey:@"atlasKey"]; [pad setNeedsLayout]; [pad layoutIfNeeded]; }
- (UIView *)menuButtonIn:(UIView *)pad { for (UIView *v in pad.subviews) if ([v isKindOfClass:UIButton.class]) return v; return nil; }
- (CAShapeLayer *)shapeAt:(CGPoint)p in:(CALayer *)layer {   // the smallest shape layer whose path holds p (a key, not the ring)
    CAShapeLayer *best = nil;
    for (CALayer *c in layer.sublayers) {
        if (![c isKindOfClass:CAShapeLayer.class] || !((CAShapeLayer *)c).path || !CGPathContainsPoint(((CAShapeLayer *)c).path, NULL, p, NO)) continue;
        CGRect r = CGPathGetPathBoundingBox(((CAShapeLayer *)c).path);
        if (!best || r.size.width < CGPathGetPathBoundingBox(best.path).size.width) best = (CAShapeLayer *)c;
    }
    return best;
}
- (CGRect)labelFrame:(NSString *)name in:(CALayer *)layer {
    if ([layer isKindOfClass:CATextLayer.class] && [(id)((CATextLayer *)layer).string isEqual:name]) return layer.frame;
    for (CALayer *c in layer.sublayers) { CGRect r = [self labelFrame:name in:c]; if (!CGRectIsNull(r)) return r; }
    return CGRectNull;
}

// The canvas in every picture mode and pose: the whole view (Fill: the picture, which covers it), on whole pixels; the picture's place on it where the layout had it
- (void)testCanvasHoldsEveryControlAndKeepsThePictureWhereItWas {
    struct { CGRect b; UIEdgeInsets in; BOOL open; CGRect division; DmPictureMode mode; CGFloat scale; const char *what; } cases[] = {
        {{0, 0, 956, 440}, {0, 62, 0, 62}, NO, CGRectNull, DmPictureFit, 3, "iPhone landscape Fit"},
        {{0, 0, 956, 440}, {0, 62, 0, 62}, NO, CGRectNull, DmPictureFill, 3, "iPhone landscape Fill"},
        {{0, 0, 956, 440}, {0, 62, 0, 62}, NO, CGRectNull, DmPictureStretch, 3, "iPhone landscape Stretch"},
        {{0, 0, 440, 956}, {62, 0, 34, 0}, NO, CGRectNull, DmPictureFit, 3, "iPhone portrait split"},
        {{0, 0, 440, 956}, {62, 0, 34, 0}, NO, CGRectNull, DmPictureFill, 3, "iPhone portrait split, Fill (fitted there)"},
        {{0, 0, 1000, 700}, {24, 0, 20, 0}, YES, {0, 340, 1000, 20}, DmPictureFit, 2.5, "Duo half open (tabletop split)"},
        {{0, 0, 1024, 768}, {24, 0, 20, 0}, NO, CGRectNull, DmPictureFit, 2, "iPad 4:3 Fit (bars above and below)"},
        {{0, 0, 1024, 768}, {24, 0, 20, 0}, NO, CGRectNull, DmPictureFill, 2, "iPad 4:3 Fill"},
        {{0, 0, 932, 430}, {0, 59, 21, 59}, NO, CGRectNull, DmPictureFill, 2.88, "a screen whose scale is not whole"},
    };
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        CGRect b = cases[i].b; CGFloat s = cases[i].scale; NSString *what = @(cases[i].what);
        DmLayout l = dm_layout_picture(dm_layout(b, cases[i].in, cases[i].open, cases[i].division, DM_PICTURE_16_9), b, cases[i].mode, DM_PICTURE_16_9);
        CGRect c = dm_touch_canvas(l, b, s), p = dm_touch_picture(l.game, c);
        XCTAssertTrue(CGRectContainsRect(CGRectInset(c, -1e-6, -1e-6), b), @"%@: the canvas holds the whole view, every control: %@", what, NSStringFromCGRect(c));
        XCTAssertTrue(CGRectContainsRect(CGRectInset(c, -1e-6, -1e-6), l.game), @"%@: and the whole picture", what);
        for (int k = 0; k < 4; k++) { CGFloat v = (k == 0 ? CGRectGetMinX(c) : k == 1 ? CGRectGetMinY(c) : k == 2 ? CGRectGetMaxX(c) : CGRectGetMaxY(c)) * s;
            XCTAssertEqualWithAccuracy(v, round(v), 1e-6, @"%@: each edge on a whole pixel", what); }
        XCTAssertLessThan(c.size.width - MAX(b.size.width, l.game.size.width), 1.0 / s * 2 + 1e-6, @"%@: no wider than it must be", what);
        if (cases[i].mode != DmPictureFill || l.separated) XCTAssertTrue(CGRectEqualToRect(c, b), @"%@: the view itself", what);
        CGRect back = CGRectMake(CGRectGetMinX(c) + p.origin.x * c.size.width, CGRectGetMinY(c) + p.origin.y * c.size.height, p.size.width * c.size.width, p.size.height * c.size.height);
        XCTAssertEqualWithAccuracy(CGRectGetMinX(back), CGRectGetMinX(l.game), 1e-3, @"%@: the picture where the layout put it", what);
        XCTAssertEqualWithAccuracy(CGRectGetMinY(back), CGRectGetMinY(l.game), 1e-3, @"%@", what);
        XCTAssertEqualWithAccuracy(back.size.width, l.game.size.width, 1e-3, @"%@", what);
        XCTAssertEqualWithAccuracy(back.size.height, l.game.size.height, 1e-3, @"%@", what);
    }
    XCTAssertTrue(CGRectEqualToRect(dm_touch_canvas(dm_layout_pad_only(CGRectMake(0, 0, 956, 440)), CGRectMake(0, 0, 956, 440), 3), CGRectMake(0, 0, 956, 440)), @"no picture: the view");
    XCTAssertTrue(CGRectIsEmpty(dm_touch_picture(CGRectZero, CGRectMake(0, 0, 956, 440))), @"no picture, no place for it");
}

// The production root: after the game's first picture the game view is the canvas, the control layers are hidden, and the gamepad hands the present a frame for its drawable;
// a press changes the frame, the Tap layout and a controller take the game view back to the picture (the layers as before) and the frame is turned off
- (void)testProductionRootDrawsTheControlsIntoTheFrameInEveryPictureMode {
    UIViewController *root = [self root];
    UIView *game = [root valueForKey:@"game"], *pad = [root valueForKey:@"pad"];
    CALayer *controls = [pad valueForKey:@"controls"];
    XCTAssertNotNil(game); XCTAssertNotNil(pad); XCTAssertNotNil(controls);
    front_picture_shape(1920, 1080); [self settle:root];
    XCTAssertTrue(dm_touch_in_frame(), @"after the first picture the present draws the controls");
    [self republish:pad]; [self presentDraws:root];
    XCTAssertTrue(controls.hidden, @"once a present drew them, their layers hidden: nothing over the game's layer but the menu button while it shows");
    CGFloat scale = root.view.window.windowScene.screen.nativeScale; CGRect b = root.view.bounds;
    CAMetalLayer *metal = (CAMetalLayer *)game.layer;
    const char *modes[] = {"fit", "fill", "stretch", "fit"};
    for (int m = 0; m < 4; m++) {
        dm_setting_live("DM_PICTURE_FIT", modes[m]); [root.view layoutIfNeeded]; [self republish:pad];
        DmLayout l = dm_layout_picture(dm_layout(b, root.view.safeAreaInsets, NO, CGRectNull, DM_PICTURE_16_9), b, dm_picture_mode(modes[m]), DM_PICTURE_16_9);
        CGRect canvas = dm_touch_canvas(l, b, scale);
        // within a thousandth of a point: an iPhone Duo's fractional geometry puts the two computations 1e-14 apart
        XCTAssertTrue(fabs(CGRectGetMinX(game.frame) - CGRectGetMinX(canvas)) < 1e-3 && fabs(CGRectGetMinY(game.frame) - CGRectGetMinY(canvas)) < 1e-3 &&
                      fabs(game.frame.size.width - canvas.size.width) < 1e-3 && fabs(game.frame.size.height - canvas.size.height) < 1e-3,
                      @"%s: the game view is the canvas %@, is %@", modes[m], NSStringFromCGRect(canvas), NSStringFromCGRect(game.frame));
        XCTAssertEqualWithAccuracy(metal.drawableSize.width, canvas.size.width * scale, 1, @"%s: the screen's pixels", modes[m]);
        XCTAssertEqualWithAccuracy(metal.drawableSize.height, canvas.size.height * scale, 1);
        touch_frame f; duo_harness_touch_frame(&f);
        XCTAssertEqual(f.on, 1u, @"%s: the controls drawn", modes[m]);
        XCTAssertEqualWithAccuracy(f.canvas_w, metal.drawableSize.width, 1, @"%s: the frame is for this drawable", modes[m]);
        XCTAssertEqualWithAccuracy(f.canvas_h, metal.drawableSize.height, 1);
        CGRect p = dm_touch_picture(l.game, canvas);
        XCTAssertEqualWithAccuracy(f.pic[0], p.origin.x, 1e-5); XCTAssertEqualWithAccuracy(f.pic[1], p.origin.y, 1e-5);
        XCTAssertEqualWithAccuracy(f.pic[2], p.size.width, 1e-5); XCTAssertEqualWithAccuracy(f.pic[3], p.size.height, 1e-5);
        XCTAssertEqual(f.n, 18u, @"%s: the ring, the knob and the 16 keys of the 3D layout", modes[m]);
        uint32_t gen; XCTAssertTrue(duo_harness_touch_atlas(NULL, NULL, &gen) != NULL); XCTAssertEqual(f.atlas, gen, @"the frame is for the atlas handed over last");
        XCTAssertEqual(duo_harness_touch_atlas_channels(), 2, @"the controls are greys: the atlas is handed over as grey and alpha");
    }
    // A press: the key's quad takes its pressed picture, and the release its normal one
    [self republish:pad];
    touch_frame idle; duo_harness_touch_frame(&idle);
    CGRect a = [self labelFrame:@"A" in:pad.layer];
    UITouch *t = (UITouch *)[NSClassFromString(@"DuoFakeTouch") new]; [(id)t setValue:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(a), CGRectGetMidY(a))] forKey:@"point"];
    [(id)t setValue:@1 forKey:@"tapCount"];
    [pad touchesBegan:[NSSet setWithObject:t] withEvent:nil];
    touch_frame pressed; duo_harness_touch_frame(&pressed);
    XCTAssertNotEqual(duo_harness_input().buttons & DM_BTN_A, 0ull);
    int changed = 0; for (uint32_t k = 0; k < pressed.n; k++) changed += memcmp(pressed.q[k].src, idle.q[k].src, sizeof idle.q[k].src) != 0;
    XCTAssertEqual(changed, 1, @"one quad changes its look: A's");
    [pad touchesEnded:[NSSet setWithObject:t] withEvent:nil];
    touch_frame after; duo_harness_touch_frame(&after);
    XCTAssertEqual(memcmp(after.q, idle.q, sizeof idle.q), 0, @"released: as before");

    // Tap: no control drawn, so the game view goes back to the picture and the frame is off, and the atlas is let go
    int released = duo_harness_touch_releases();
    [pad setPadLayout:2]; [root.view layoutIfNeeded];
    XCTAssertEqual(duo_harness_touch_releases(), released + 1, @"Tap: the present lets the atlas go");
    DmLayout fit = dm_layout(b, root.view.safeAreaInsets, NO, CGRectNull, DM_PICTURE_16_9);
    XCTAssertFalse(dm_touch_in_frame());
    XCTAssertTrue(CGRectEqualToRect(game.frame, fit.game), @"Tap: the picture's rectangle, as before");
    touch_frame off; duo_harness_touch_frame(&off); XCTAssertEqual(off.on, 0u, @"the present stops drawing them");
    [pad setPadLayout:1]; [root.view layoutIfNeeded];
    XCTAssertTrue(dm_touch_in_frame()); XCTAssertFalse(controls.hidden, @"back from Tap: the layers show until a present has drawn the controls");
    [self presentDraws:root]; XCTAssertTrue(controls.hidden);
    // A controller in use: the controls hide, the layers stay hidden, the game view is the picture's rectangle
    [pad setValue:@YES forKey:@"padOff"]; [root.view setNeedsLayout]; [root.view layoutIfNeeded];
    XCTAssertFalse(dm_touch_in_frame()); XCTAssertTrue(controls.hidden, @"hidden while a controller is in use, as before");
    XCTAssertTrue(CGRectEqualToRect(game.frame, fit.game));
    duo_harness_touch_frame(&off); XCTAssertEqual(off.on, 0u);
    [pad setValue:@NO forKey:@"padOff"]; [root.view setNeedsLayout]; [root.view layoutIfNeeded];
    XCTAssertTrue(dm_touch_in_frame());
}

// What the present draws (the atlas's pictures at the frame's quads, premultiplied over) against the controls on their layers as the render server draws them (the old path),
// in Fit, Fill and Stretch, at rest, with a key pressed and with the stick held off centre
- (void)testControlsInTheFrameLookAsTheyDidOnTheirLayers {
    UIViewController *root = [self root];
    UIView *pad = [root valueForKey:@"pad"]; UIView *game = [root valueForKey:@"game"];
    front_picture_shape(1920, 1080); [self settle:root];
    UIView *menu = [self menuButtonIn:pad]; BOOL menuHidden = menu.hidden; menu.hidden = YES;
    CGFloat scale = root.view.window.windowScene.screen.nativeScale;
    const char *modes[] = {"fit", "fill", "stretch"};
    for (int m = 0; m < 3; m++) for (int state = 0; state < 3; state++) {
        dm_setting_live("DM_PICTURE_FIT", modes[m]); [root.view layoutIfNeeded]; [self republish:pad];
        UITouch *t = nil; CGRect stick = CGRectNull;
        if (state) {   // 1: B pressed; 2: the left stick held a third of the way to the upper right
            CGPoint at;
            if (state == 1) { CGRect r = [self labelFrame:@"B" in:pad.layer]; at = CGPointMake(CGRectGetMidX(r), CGRectGetMidY(r)); }
            else { CAShapeLayer *ring = [pad valueForKey:@"ring"]; stick = CGPathGetPathBoundingBox(ring.path); at = CGPointMake(CGRectGetMidX(stick), CGRectGetMidY(stick)); }
            t = (UITouch *)[NSClassFromString(@"DuoFakeTouch") new]; [(id)t setValue:[NSValue valueWithCGPoint:at] forKey:@"point"]; [(id)t setValue:@1 forKey:@"tapCount"];
            [pad touchesBegan:[NSSet setWithObject:t] withEvent:nil];
            if (state == 2) { [(id)t setValue:[NSValue valueWithCGPoint:CGPointMake(at.x + stick.size.width * 0.17, at.y - stick.size.width * 0.123)] forKey:@"point"]; [pad touchesMoved:[NSSet setWithObject:t] withEvent:nil]; }
        }
        XCTAssertTrue(dm_touch_in_frame());
        touch_frame f; duo_harness_touch_frame(&f); int aw, ah; const uint8_t *atlas = duo_harness_touch_atlas(&aw, &ah, NULL);
        DuoImage drawn = duo_image((int)f.canvas_w, (int)f.canvas_h); duo_fill(drawn, DUO_GREY);
        duo_composite(drawn, &f, atlas, aw, ah);
        // the old path: the same controls on their layers, drawn by the render server
        dm_gamepad_touch_draw(pad, NO, CGRectZero, 0, CGRectZero);
        DuoImage layers = duo_snapshot(pad, scale, YES);
        [root.view setNeedsLayout]; [root.view layoutIfNeeded];   // the front end turns the frame on again
        int ox = (int)lround(-game.frame.origin.x * scale), oy = (int)lround(-game.frame.origin.y * scale);   // the screen's origin on the canvas (Fill's is inside it)
        double mean, off; int worst; duo_diff(drawn, ox, oy, layers, &mean, &off, &worst);
        NSLog(@"duo-touch-draw: %s, %s: mean difference %.3f, %.4f %% of pixels off by more than 16, worst %d", modes[m], state == 0 ? "at rest" : state == 1 ? "B pressed" : "stick held", mean, off * 100, worst);
        XCTAssertLessThan(mean, 0.25, @"%s state %d: the same picture on average", modes[m], state);
        XCTAssertLessThan(off, 0.0005, @"%s state %d: and almost every pixel within 16 levels", modes[m], state);
        if (m == 0) {
            NSString *tag = [NSString stringWithFormat:@"%s-%d", modes[m], state];
            duo_save(drawn, [NSString stringWithFormat:@"touch-frame-%@.png", tag]); duo_save(layers, [NSString stringWithFormat:@"touch-layers-%@.png", tag]);
        }
        free(drawn.px); free(layers.px);
        if (t) [pad touchesEnded:[NSSet setWithObject:t] withEvent:nil];
    }
    dm_setting_live("DM_PICTURE_FIT", "fit"); [root.view layoutIfNeeded];
    menu.hidden = menuHidden;
}

// A pad of its own laid out as a portrait split, a Duo's tabletop split and a 4:3 iPad's overlay (the harness's root is a landscape iPhone), in the window at the screen's scale
// (the sizes fit in it): the frame on the whole view, against its layers as the render server draws them
- (void)testControlsInTheFrameMatchTheirLayersInSplitAndIPadLayouts {
    struct { CGRect b; UIEdgeInsets in; BOOL open; CGRect division; const char *what; } cases[] = {
        {{0, 0, 300, 440}, {40, 0, 20, 0}, NO, CGRectNull, "portrait split"},
        {{0, 0, 900, 430}, {0, 0, 0, 0}, YES, {0, 200, 900, 14}, "Duo tabletop split"},
        {{0, 0, 586, 440}, {0, 0, 0, 0}, NO, CGRectNull, "4:3 iPad overlay (bars above and below)"},
    };
    UIViewController *root = [self root]; CGFloat s = root.view.window.windowScene.screen.nativeScale;
    for (size_t i = 0; i < sizeof cases / sizeof cases[0]; i++) {
        CGRect b = cases[i].b;
        DmLayout l = dm_layout(b, cases[i].in, cases[i].open, cases[i].division, DM_PICTURE_16_9);
        XCTAssertEqual(l.separated, i < 2, @"%s", cases[i].what);
        UIView *pad = [self padIn:root bounds:b];
        dm_gamepad_arrange(pad, l); [pad setNeedsLayout]; [pad layoutIfNeeded];
        [self menuButtonIn:pad].hidden = YES;
        CGRect canvas = dm_touch_canvas(l, b, s);
        dm_gamepad_touch_draw(pad, YES, canvas, s, dm_touch_picture(l.game, canvas)); [pad layoutIfNeeded];
        CALayer *controls = [pad valueForKey:@"controls"];
        XCTAssertFalse(controls.hidden, @"%s: the layers show until a present drew the controls", cases[i].what);
        [self presentDraws:root];
        XCTAssertTrue(controls.hidden, @"%s: then hidden", cases[i].what);
        touch_frame f; duo_harness_touch_frame(&f); int aw, ah; const uint8_t *atlas = duo_harness_touch_atlas(&aw, &ah, NULL);
        XCTAssertEqual(f.on, 1u); XCTAssertEqual(f.n, 18u, @"%s", cases[i].what);
        XCTAssertEqualWithAccuracy(f.canvas_w, b.size.width * s, 1); XCTAssertEqualWithAccuracy(f.canvas_h, b.size.height * s, 1);
        DuoImage drawn = duo_image((int)f.canvas_w, (int)f.canvas_h); duo_fill(drawn, DUO_GREY); duo_composite(drawn, &f, atlas, aw, ah);
        dm_gamepad_touch_draw(pad, NO, CGRectZero, 0, CGRectZero);
        XCTAssertFalse(controls.hidden, @"%s: off, the layers show again", cases[i].what);
        duo_harness_touch_frame(&f); XCTAssertEqual(f.on, 0u, @"and the present is told");
        DuoImage layers = duo_snapshot(pad, s, YES);
        [pad removeFromSuperview];
        double mean, off; int worst; duo_diff(drawn, 0, 0, layers, &mean, &off, &worst);
        NSLog(@"duo-touch-draw: %s: mean difference %.3f, %.4f %% of pixels off by more than 16, worst %d", cases[i].what, mean, off * 100, worst);
        XCTAssertLessThan(mean, 0.25, @"%s: the same picture on average", cases[i].what);
        XCTAssertLessThan(off, 0.0005, @"%s: and almost every pixel within 16 levels", cases[i].what);
        if (i == 0) { duo_save(drawn, @"touch-frame-portrait.png"); duo_save(layers, @"touch-layers-portrait.png"); }
        free(drawn.px); free(layers.px);
    }
}

// The layers hand over to the frame only once a present has drawn the controls for the current canvas: a new canvas (a rotation) first places the picture with no control
// (the pictures and their places are the old canvas's) and shows the layers; the frame with the controls comes after the pad's layout, and the present's answer to an older frame
// does not hide the layers
- (void)testLayersShowUntilAPresentDrewTheControlsForTheCanvas {
    UIViewController *root = [self root]; CGFloat s = root.view.window.windowScene.screen.nativeScale;
    CGRect b = CGRectMake(0, 0, 900, 430);
    DmLayout l = dm_layout(b, UIEdgeInsetsZero, NO, CGRectNull, DM_PICTURE_16_9);
    UIView *pad = [self padIn:root bounds:b];
    dm_gamepad_arrange(pad, l); [pad setNeedsLayout]; [pad layoutIfNeeded];
    CALayer *controls = [pad valueForKey:@"controls"];
    CGRect canvas = dm_touch_canvas(l, b, s);
    dm_gamepad_touch_draw(pad, YES, canvas, s, dm_touch_picture(l.game, canvas));
    touch_frame f; duo_harness_touch_frame(&f);
    XCTAssertEqual(f.on, (uint32_t)TOUCH_PLACE, @"before the pad's layout: the picture placed, no control");
    XCTAssertEqual(f.n, 0u);
    XCTAssertEqualWithAccuracy(f.canvas_w, canvas.size.width * s, 1);
    XCTAssertEqual(duo_harness_present_draws(), 0, @"nothing drawn: no answer");
    XCTAssertFalse(controls.hidden, @"the layers show meanwhile");
    [pad layoutIfNeeded];
    duo_harness_touch_frame(&f); XCTAssertEqual(f.on, (uint32_t)TOUCH_ON); XCTAssertEqual(f.n, 18u, @"after the layout: the controls");
    [self presentDraws:root]; XCTAssertTrue(controls.hidden, @"drawn: the layers hide");

    // A rotation: a portrait canvas. The frame drawn for the landscape one must not hide the layers again
    CGRect pb = CGRectMake(0, 0, 430, 900);
    DmLayout pl = dm_layout(pb, UIEdgeInsetsZero, NO, CGRectNull, DM_PICTURE_16_9);
    pad.frame = pb; dm_gamepad_arrange(pad, pl);
    CGRect pc = dm_touch_canvas(pl, pb, s);
    dm_gamepad_touch_draw(pad, YES, pc, s, dm_touch_picture(pl.game, pc));
    XCTAssertFalse(controls.hidden, @"a new canvas: the layers show");
    duo_harness_touch_frame(&f);
    XCTAssertEqual(f.on, (uint32_t)TOUCH_PLACE, @"the landscape pictures are not placed on the portrait canvas");
    XCTAssertEqualWithAccuracy(f.canvas_w, pc.size.width * s, 1); XCTAssertEqualWithAccuracy(f.canvas_h, pc.size.height * s, 1);
    [pad layoutIfNeeded];
    duo_harness_touch_frame(&f); XCTAssertEqual(f.on, (uint32_t)TOUCH_ON);
    CGRect ring = CGPathGetPathBoundingBox(((CAShapeLayer *)[pad valueForKey:@"ring"]).path);
    XCTAssertEqualWithAccuracy(f.q[0].dst[0] + f.q[0].dst[2] / 2, CGRectGetMidX(ring) / pc.size.width, 0.01, @"the ring where the portrait layout has it");
    XCTAssertEqualWithAccuracy(f.q[0].dst[1] + f.q[0].dst[3] / 2, CGRectGetMidY(ring) / pc.size.height, 0.01);
    [self presentDraws:root]; XCTAssertTrue(controls.hidden);

    // Off: the frame is turned off (it keeps the canvas for the drawables made before), the atlas let go, the layers show; half a second on, no frame at all
    int released = duo_harness_touch_releases();
    dm_gamepad_touch_draw(pad, NO, CGRectZero, 0, CGRectZero);
    duo_harness_touch_frame(&f);
    XCTAssertEqual(f.on, (uint32_t)TOUCH_OFF); XCTAssertEqualWithAccuracy(f.canvas_w, pc.size.width * s, 1, @"the off frame keeps the canvas for a moment");
    XCTAssertEqual(duo_harness_touch_releases(), released + 1, @"the atlas is let go");
    XCTAssertFalse(controls.hidden);
    XCTNSPredicateExpectation *cleared = [[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id o, NSDictionary *b2) {
        touch_frame g; duo_harness_touch_frame(&g); return g.canvas_w == 0 && g.canvas_h == 0; }] object:nil];
    (void)[XCTWaiter waitForExpectations:@[cleared] timeout:3];
    duo_harness_touch_frame(&f); XCTAssertEqual(f.canvas_w, 0u, @"then cleared: a later drawable of the old canvas's size takes nothing from it");
    [pad removeFromSuperview];
}

// While the game presents nothing (a load, a hitch) a press shows on the layers, as before; the next present that draws the controls hides them again. And when the drawable
// stops fitting the frame (the present's front_touch_unfit), the layers show and the root lays out again
- (void)testLayersShowWhileTheGamePresentsNothingOrTheFrameFitsNoDrawable {
    UIViewController *root = [self root]; CGFloat s = root.view.window.windowScene.screen.nativeScale;
    CGRect b = CGRectMake(0, 0, 900, 430);
    DmLayout l = dm_layout(b, UIEdgeInsetsZero, NO, CGRectNull, DM_PICTURE_16_9);
    UIView *pad = [self padIn:root bounds:b];
    dm_gamepad_arrange(pad, l); [pad setNeedsLayout]; [pad layoutIfNeeded];
    [self menuButtonIn:pad].hidden = YES;
    CALayer *controls = [pad valueForKey:@"controls"];
    CGRect canvas = dm_touch_canvas(l, b, s);
    dm_gamepad_touch_draw(pad, YES, canvas, s, dm_touch_picture(l.game, canvas)); [pad layoutIfNeeded];
    [self presentDraws:root]; XCTAssertTrue(controls.hidden);
    CGRect a = [self labelFrame:@"A" in:pad.layer];
    UITouch *t = (UITouch *)[NSClassFromString(@"DuoFakeTouch") new]; [(id)t setValue:[NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(a), CGRectGetMidY(a))] forKey:@"point"];
    [(id)t setValue:@1 forKey:@"tapCount"];
    CAShapeLayer *key = [self shapeAt:CGPointMake(CGRectGetMidX(a), CGRectGetMidY(a)) in:controls];
    XCTAssertNotNil(key); CGColorRef idle = CGColorCreateCopy(key.fillColor);
    duo_harness_set_present_idle(20000000);   // 20 ms: a present came lately
    [pad touchesBegan:[NSSet setWithObject:t] withEvent:nil];
    XCTAssertTrue(controls.hidden, @"presents coming: the press is drawn in the frame");
    [pad touchesEnded:[NSSet setWithObject:t] withEvent:nil];
    duo_harness_set_present_idle(400000000);   // 400 ms without a present
    [pad touchesBegan:[NSSet setWithObject:t] withEvent:nil];
    XCTAssertFalse(controls.hidden, @"no present for 400 ms: the press shows on the layers");
    XCTAssertFalse(CGColorEqualToColor(key.fillColor, idle), @"A's layer takes the pressed look");
    touch_frame f; duo_harness_touch_frame(&f); XCTAssertEqual(f.on, (uint32_t)TOUCH_ON, @"and the frame carries it for the next present");
    [self presentDraws:root];
    XCTAssertTrue(controls.hidden, @"a present drew it: the layers hide again");
    [pad touchesEnded:[NSSet setWithObject:t] withEvent:nil];
    CGColorRelease(idle);

    front_touch_unfit();
    XCTestExpectation *e = [self expectationWithDescription:@"main queue"]; dispatch_async(dispatch_get_main_queue(), ^{ [e fulfill]; }); [self waitForExpectations:@[e] timeout:2];
    XCTAssertFalse(controls.hidden, @"the frame fits no drawable: the layers show");
    [self presentDraws:root]; XCTAssertTrue(controls.hidden, @"until a present draws the controls again");
    duo_harness_set_present_idle(UINT64_MAX);
    dm_gamepad_touch_draw(pad, NO, CGRectZero, 0, CGRectZero);
    [pad removeFromSuperview];
}

// An offline HTML page is a view over the game view: while it shows, the controls go on their layers over it (into the frame they would be under it), and back into the frame after
- (void)testControlsStayOnTheirLayersOverAnOfflinePage {
    UIViewController *root = [self root];
    UIView *pad = [root valueForKey:@"pad"]; CALayer *controls = [pad valueForKey:@"controls"];
    front_picture_shape(1920, 1080); [self settle:root];
    XCTAssertTrue(dm_touch_in_frame());
    duo_harness_set_web_touch(1); [root.view layoutIfNeeded];
    XCTAssertFalse(dm_touch_in_frame(), @"a page shows: the controls are not drawn into the frame");
    XCTAssertFalse(controls.hidden, @"they are on their layers, over the page");
    touch_frame f; duo_harness_touch_frame(&f); XCTAssertEqual(f.on, (uint32_t)TOUCH_OFF);
    duo_harness_set_web_touch(0); [root.view layoutIfNeeded];
    XCTAssertTrue(dm_touch_in_frame(), @"the page gone: into the frame again");
}
@end
