// The present's upscaling mode (DM_PRESENT_UPSCALE: nvn_mtl.m fx_mode) and the in-game menu's pick of it while the game runs (mtl_present_upscale_set). The main thread posts a
// pick; only the live present takes it, at its next present, and learns whether the mode in force changed. A capture (an offscreen present, on another thread) reads the mode in
// force and takes no pick. The present's Sharpening (DM_PRESENT_SHARPEN: nvn_mtl.m present_sharpen, mtl_present_sharpen_set) is picked the same way, through the same helpers
// on a mode and a pick of its own, and so is its edge smoothing (DM_POST_AA: nvn_mtl.m aa_mode, mtl_present_aa_set). Plain C, so dm/gfx/tests/t_upscale_pick.c runs it on any
// machine, also under ThreadSanitizer
#pragma once
#include <stdatomic.h>
#include <string.h>

enum { UP_OFF = 0, UP_METALFX = 1 };

// DM_PRESENT_UPSCALE's values: metalfx (or 1), off (or 0, empty, unset); -1 for anything else
static inline int up_parse(const char *e) {
    if (!e || !*e || !strcmp(e, "off") || !strcmp(e, "0")) return UP_OFF;
    return !strcmp(e, "metalfx") || !strcmp(e, "1") ? UP_METALFX : -1;
}
// DM_PRESENT_SHARPEN's values, the levels of the settings row: 0 off, 1 low, 2 medium, 3 high; -1 for anything else. Unset or empty is the caller's to decide (the
// profile's present_sharpen)
enum { SHARP_OFF = 0, SHARP_HIGH = 3 };
static inline int sharp_parse(const char *e) { return e && e[0] >= '0' && e[0] <= '3' && !e[1] ? e[0] - '0' : -1; }
// A level's RCAS strength in stops (FSR1's FsrRcasCon: the shader takes exp2(-stops), 0 the strongest): low 2, medium 1, high 0.5. FSR's own default of 0.2 stops is not
// offered: it overshot HUD text by 7-9/255 in the synthetic test (docs/reference/rendering.md, Sharpening in the present); 0 for off, which draws no RCAS at all
static inline float sharp_stops(int level) { return level == 1 ? 2.0f : level == 2 ? 1.0f : level == 3 ? 0.5f : 0.0f; }
// DM_POST_AA's values, the settings row's: off (or 0), edge, edge-sharp (CMAA2's Extra Sharp); ab, or ab:<k>[,<k>...]/<n>, alternates off and edge with the DM_AB phases (the
// caller reads it through nvn_mtl.m sw_mode_of; never a menu pick). -1 for anything else, edge1 or abc included. Unset or empty is the caller's to decide (the profile's post_aa)
enum { AA_OFF = 0, AA_EDGE = 1, AA_EDGE_SHARP = 2, AA_AB = 3 };
static inline int aa_parse(const char *e) {
    if (!e || !*e || !strcmp(e, "off") || !strcmp(e, "0")) return AA_OFF;
    if (!strcmp(e, "edge")) return AA_EDGE;
    if (!strcmp(e, "edge-sharp")) return AA_EDGE_SHARP;
    return !strncmp(e, "ab", 2) && (!e[2] || e[2] == ':') ? AA_AB : -1;
}
// The main thread's pick (a mode up_parse returned); a later pick before the next present replaces it
static inline void up_post(_Atomic int *req, int mode) { atomic_store_explicit(req, mode, memory_order_relaxed); }
// The mode for one present: the mode in force (*mode, -1 before the first present), or -1 when it is to be decided: at the first present, and at the live present's first present
// after a pick. Then *want is the pick (taken: the next present sees none), or -1 to read the environment; the caller decides (a GPU without the scaler gets UP_OFF) and stores it
// with up_set. Two relaxed loads on every other present
static inline int up_now(_Atomic int *mode, _Atomic int *req, int live, int *want) {
    int v = atomic_load_explicit(mode, memory_order_relaxed), r = live ? atomic_load_explicit(req, memory_order_relaxed) : -1;
    if (v >= 0 && r < 0) return v;
    *want = r >= 0 ? atomic_exchange_explicit(req, -1, memory_order_relaxed) : -1;
    return -1;
}
// Stores the decided mode; returns whether it changed a mode in force (not the first decision, not a pick of the same mode)
static inline int up_set(_Atomic int *mode, int v) { int was = atomic_exchange_explicit(mode, v, memory_order_relaxed); return was >= 0 && was != v; }
