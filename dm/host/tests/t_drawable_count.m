// DM_DRAWABLE_COUNT (../front_drawable.h, used by front_ios.m and front_mac.m): unset leaves a CAMetalLayer at Metal's 3 drawables; 2 and 3 set maximumDrawableCount; any other
// value is refused and leaves the layer as it was
#import <QuartzCore/CAMetalLayer.h>
#include <stdio.h>
#include "front_drawable.h"
static int checks, failed;
#define EXPECT(name, want, got) do { long w_ = (want), g_ = (got); checks++; if (w_ != g_) { failed++; fprintf(stderr, "FAIL: %s: expected %ld, got %ld\n", name, w_, g_); } } while (0)
int main(void) { @autoreleasepool {
    CAMetalLayer *l = [CAMetalLayer layer];
    EXPECT("a new layer has Metal's 3 drawables", 3, (long)l.maximumDrawableCount);
    EXPECT("unset: left as it is", 0, front_drawable_count(l, NULL)); EXPECT("unset: 3 drawables", 3, (long)l.maximumDrawableCount);
    EXPECT("empty: left as it is", 0, front_drawable_count(l, "")); EXPECT("empty: 3 drawables", 3, (long)l.maximumDrawableCount);
    EXPECT("2: set", 2, front_drawable_count(l, "2")); EXPECT("2: the layer has 2 drawables", 2, (long)l.maximumDrawableCount);
    EXPECT("3: set", 3, front_drawable_count(l, "3")); EXPECT("3: the layer has 3 drawables", 3, (long)l.maximumDrawableCount);
    front_drawable_count(l, "2");
    EXPECT("4: refused", -1, front_drawable_count(l, "4")); EXPECT("4: the layer keeps its 2", 2, (long)l.maximumDrawableCount);
    EXPECT("x: refused", -1, front_drawable_count(l, "x")); EXPECT("23: refused", -1, front_drawable_count(l, "23")); EXPECT("refused values: still 2", 2, (long)l.maximumDrawableCount);
    printf("t_drawable_count: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
