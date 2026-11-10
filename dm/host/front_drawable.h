// DM_DRAWABLE_COUNT=2|3: the CAMetalLayer's maximumDrawableCount, for the iOS and Mac front ends (front_ios.m DmGameView, front_mac.m front_run). Unset, the layer keeps Metal's
// default of 3 drawables, as before. Two save one drawable of the picture's size (7.9 MiB at 1920x1080 on an iPhone, 28.6 MiB at the MacBook Pro's 3456x2168 window) and can
// make nextDrawable wait, which shows as dropped frames: an experiment to A/B on a device (scripts/devlog.py's on-screen dropped frames and frame-interval p99), not a default.
// Returns the count set, 0 when the layer is left as Metal has it, -1 for a value other than 2 or 3 (also left as it is)
#import <QuartzCore/CAMetalLayer.h>
#include <string.h>
static inline int front_drawable_count(CAMetalLayer *l, const char *v) {
    if (!v || !*v) return 0;
    if (strcmp(v, "2") && strcmp(v, "3")) return -1;
    l.maximumDrawableCount = v[0] == '2' ? 2 : 3;
    return (int)l.maximumDrawableCount;
}
