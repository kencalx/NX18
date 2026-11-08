// The present's upscaling mode (DM_PRESENT_UPSCALE: nvn_mtl.m fx_mode) and the in-game menu's pick of it while the game runs (mtl_present_upscale_set). The main thread posts a
// pick; only the live present takes it, at its next present, and learns whether the mode in force changed. A capture (an offscreen present, on another thread) reads the mode in
// force and takes no pick. Plain C, so dm/gfx/tests/t_upscale_pick.c runs it on any machine, also under ThreadSanitizer
#pragma once
#include <stdatomic.h>
#include <string.h>

enum { UP_OFF = 0, UP_METALFX = 1 };

// DM_PRESENT_UPSCALE's values: metalfx (or 1), off (or 0, empty, unset); -1 for anything else
static inline int up_parse(const char *e) {
    if (!e || !*e || !strcmp(e, "off") || !strcmp(e, "0")) return UP_OFF;
    return !strcmp(e, "metalfx") || !strcmp(e, "1") ? UP_METALFX : -1;
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
