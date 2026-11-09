// Where the iOS front end puts the game's picture and the touch controls (front_ios.m lays the views out, DmGamepad.m its controls): pure functions of the view's bounds,
// its safe area and an iPhone Duo's fold (UIKit's division region, which includes its interactive margins), so the Duo harness tests them without a device (dm/ios/tests/duo).
#pragma once
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef struct { CGRect game, controls; BOOL separated, topSafeOnly; } DmLayout;

static inline UIEdgeInsets dm_game_safe_insets(CGRect bounds, UIEdgeInsets insets, BOOL duo) {
    return duo && bounds.size.height > bounds.size.width ? UIEdgeInsetsMake(insets.top, 0, 0, 0) : insets;
}

// The picture's width / height before the game's first present (front.h front_picture_shape gives the real one: a taller shape under DM_SCREEN_ASPECT, 1920x1344)
#define DM_PICTURE_16_9 (16.0 / 9.0)

// The largest centered rectangle of the picture's shape (aspect = width / height) in b
static inline CGRect dm_aspect_fit(CGRect b, CGFloat aspect) {
    CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0 || aspect <= 0) return CGRectZero;
    if (w / h > aspect) w = h * aspect; else h = w / aspect;
    return CGRectMake(floor(CGRectGetMidX(b) - w / 2), floor(CGRectGetMidY(b) - h / 2), w, h);
}

// Picture "Fill" (DM_PICTURE_FIT=fill, a launcher and in-game menu setting): the smallest centered rectangle of the picture's shape that covers b. The game's picture keeps
// its shape, so what lies outside b is cropped, never stretched. Not rounded, so it covers b exactly.
static inline CGRect dm_aspect_fill(CGRect b, CGFloat aspect) {
    CGFloat w = b.size.width, h = b.size.height;
    if (w <= 0 || h <= 0 || aspect <= 0) return CGRectZero;
    if (w / h > aspect) h = w / aspect; else w = h * aspect;
    return CGRectMake(CGRectGetMidX(b) - w / 2, CGRectGetMidY(b) - h / 2, w, h);
}

// DM_PICTURE_FIT: fit (the default), fill (cropped) or stretch. The values are a BOOL's for Fit and Fill, so dm_layout_picture still takes YES / NO for them
typedef NS_ENUM(NSInteger, DmPictureMode) { DmPictureFit = 0, DmPictureFill = 1, DmPictureStretch = 2 };
static inline DmPictureMode dm_picture_mode(const char *_Nullable value) {
    if (value && !strcmp(value, "fill")) return DmPictureFill;
    if (value && !strcmp(value, "stretch")) return DmPictureStretch;
    return DmPictureFit;
}
static inline BOOL dm_picture_fill(const char *_Nullable value) { return dm_picture_mode(value) == DmPictureFill; }
static inline BOOL dm_picture_stretch(const char *_Nullable value) { return dm_picture_mode(value) == DmPictureStretch; }

static inline CGRect dm_horizontal_division(CGRect b, CGRect division) {
    if (CGRectIsNull(division) || division.size.width <= division.size.height) return CGRectNull;
    // Preserve zero-height inactive folds and clip regions during display handoff.
    CGFloat x = MAX(CGRectGetMinX(b), CGRectGetMinX(division));
    CGFloat y = MAX(CGRectGetMinY(b), CGRectGetMinY(division));
    CGFloat right = MIN(CGRectGetMaxX(b), CGRectGetMaxX(division));
    CGFloat bottom = MIN(CGRectGetMaxY(b), CGRectGetMaxY(division));
    if (right - x < b.size.width * 0.9 || bottom < y ||
        y <= CGRectGetMinY(b) || bottom >= CGRectGetMaxY(b)) return CGRectNull;
    return CGRectMake(x, y, right - x, bottom - y);
}

static inline DmLayout dm_layout(CGRect b, UIEdgeInsets insets, BOOL partiallyOpen, CGRect division, CGFloat aspect) {
    DmLayout l = { dm_aspect_fit(b, aspect), b, NO, NO };
    if (CGRectIsEmpty(b)) return l;
    division = dm_horizontal_division(b, division);
    BOOL portrait = b.size.height > b.size.width;
    if (!portrait && (!partiallyOpen || CGRectIsNull(division))) return l;
    if (CGRectIsNull(division)) division = CGRectMake(b.origin.x, CGRectGetMidY(b), b.size.width, 0);
    CGRect safe = UIEdgeInsetsInsetRect(b, insets);
    CGRect upper = CGRectMake(CGRectGetMinX(safe), CGRectGetMinY(safe), safe.size.width,
                             CGRectGetMinY(division) - CGRectGetMinY(safe));
    CGRect lower = CGRectMake(CGRectGetMinX(b), CGRectGetMaxY(division), b.size.width,
                             CGRectGetMaxY(b) - CGRectGetMaxY(division));
    if (upper.size.height <= 0 || CGRectGetMaxY(safe) <= CGRectGetMinY(lower)) return l;
    l.game = dm_aspect_fit(upper, aspect); l.controls = lower; l.separated = YES;
    return l;
}

// The picture is on a TV (front_ios.m DmTVSceneDelegate): the controls take the whole view and no touch goes to the game's touch screen (the game is docked there).
static inline DmLayout dm_layout_pad_only(CGRect b) { return (DmLayout){ CGRectZero, b, NO, NO }; }

// Fill and Stretch cover the full view only in the overlay layout (landscape). A portrait or tabletop split keeps the picture fitted in its
// area above the controls, where cropping or stretching a small picture would cost more than the bars.
// Stretch (DM_PICTURE_FIT=stretch): the game rectangle is the whole view, whatever the picture's shape; the present pass then draws the picture over the whole drawable
// instead of keeping its shape (nvn_mtl.m mtl_present_stretch, which front_ios.m sets from dm_layout_stretched), so nothing is cropped and there are no bars.
static inline DmLayout dm_layout_picture(DmLayout l, CGRect b, DmPictureMode mode, CGFloat aspect) {
    if (l.separated || CGRectIsEmpty(b)) return l;
    if (mode == DmPictureFill) l.game = dm_aspect_fill(b, aspect);
    else if (mode == DmPictureStretch) l.game = b;
    return l;
}
// Whether the game rectangle differs in shape from the picture, so the present must stretch the picture to it rather than letterbox it (Stretch in the overlay layout)
static inline BOOL dm_layout_stretched(DmLayout l, DmPictureMode mode, CGFloat aspect) {
    CGFloat w = l.game.size.width, h = l.game.size.height;
    return mode == DmPictureStretch && !l.separated && w > 0 && h > 0 && aspect > 0 && fabs((w / h) / aspect - 1) >= 0.001;
}
// How far off the picture's shape a stretched picture may be and still go through MetalFX: nvn_mtl.m fx_wanted's 1 % (present_viewport's). Below it the present still scales the
// picture by MetalFX when Upscaling is MetalFX, though the layout counts it as stretched (dm_layout_stretched's 0.1 %)
#define DM_FX_SHAPE_TOLERANCE 0.01
// Whether MetalFX's spatial scaler can draw the picture into the game rectangle: not stretched, or stretched to a shape within DM_FX_SHAPE_TOLERANCE of its own (fx_wanted). Where
// it can, the drawable keeps the view's pixels for the scaler to fill (front_ios.m viewDidLayoutSubviews)
static inline BOOL dm_layout_fx_shape(DmLayout l, BOOL stretched, CGFloat aspect) {
    CGFloat w = l.game.size.width, h = l.game.size.height;
    return !stretched || (w > 0 && h > 0 && aspect > 0 && fabs((w / h) / aspect - 1) < DM_FX_SHAPE_TOLERANCE);
}

// The drawable's pixel size for a game view of bounds (points) at scale pixels per point: the view's pixels, or, given the picture's render size px (front.h front_picture_size;
// zero: none, the view's pixels), no more pixels than the picture has, which Core Animation then scales to the view as the present's bilinear pass would have. Stretched (the
// present draws the picture over the whole drawable, dm_layout_stretched): each direction on its own, the picture's pixels at most. Otherwise the view's shape, at the scale
// that gives the picture all its pixels in both directions (the view has the picture's shape in Fit and Fill), never above the view's own
static inline CGSize dm_drawable_size(CGSize bounds, CGFloat scale, CGSize px, BOOL stretched) {
    CGSize d = CGSizeMake(bounds.width * scale, bounds.height * scale);
    if (px.width <= 0 || px.height <= 0 || bounds.width <= 0 || bounds.height <= 0) return d;
    if (stretched) return CGSizeMake(MIN(d.width, px.width), MIN(d.height, px.height));
    CGFloat s = MAX(px.width / bounds.width, px.height / bounds.height);
    return s < scale ? CGSizeMake(round(bounds.width * s), round(bounds.height * s)) : d;
}

// A point in the view as the game's touch screen sees it: normalized on the game rectangle, which with Fill is larger than the view,
// so a touch on the visible part lands where that part of the picture is; with Stretch it is the view, stretched as the picture is. Clamped to [0, 0.999].
static inline CGPoint dm_game_touch_point(CGRect game, CGPoint p) {
    CGFloat w = game.size.width, h = game.size.height;
    if (w <= 0 || h <= 0) return CGPointZero;
    return CGPointMake(fmin(fmax((p.x - CGRectGetMinX(game)) / w, 0), 0.999), fmin(fmax((p.y - CGRectGetMinY(game)) / h, 0), 0.999));
}

UIView *dm_gamepad_view(CGRect frame);
void dm_gamepad_arrange(UIView *view, DmLayout layout);
void dm_gamepad_reset(void);
void dm_gamepad_opmode_changed(void);   // the console mode changed (the in-game menu, a TV): the Tap layout exists only in handheld mode

NS_ASSUME_NONNULL_END
