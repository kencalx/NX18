// The window textures' render area (DM_NVN_WIN_AREA, on by default; nvn_mtl.m present_enqueue and rp_begin_ex_). Fortune's Weave, Bananza, Star Fox, Mario Kart World and Ocarina of
// Time make their window textures larger than the picture they present (2880x1620 on the iPhone, a 1920x1080 crop: 44% of it), and every frame clear and store the whole texture and
// its depth-stencil: Bananza's clear pass with no draws took 0.97 ms at the phone's lower GPU clock and stored 40 MB a frame, its composite another 17.8 MB (NX18-X2.0
// gpu-clock-collapse.md). A pass whose colour attachments are all window textures (level 0, slice 0) is limited to the largest crop presented from them (renderTargetWidth /
// Height): tiles outside it are not cleared, drawn or stored. Pixels outside the crop never reach the screen. The area counts only once that largest crop has held for
// WA_HOLD presents of the texture and covers at most 90% of it; a crop that grows past it turns the area off at once until the new largest crop has held again, so a
// growing crop clips at most the frames already in flight. Header only: the present side (wa_present, one presenting thread) and the pass side (wa_area, any thread) share
// atomics, so t_win_area tests it without the host
#pragma once
#include <stdatomic.h>
#include <stdint.h>
enum { WA_N = 8, WA_HOLD = 60, WA_SHRINK = 600 };
// WA_SHRINK: a smaller crop that has held this many presents of the texture becomes its largest (the largest only grew before: Bananza's composite window texture got a
// full-size present at boot and was never limited after it; NX18-X2.0 bananza-alldata-analysis.md). A dynamic resolution's moving crop does not hold that long
typedef struct { _Atomic uint64_t ser[WA_N]; _Atomic uint32_t area[WA_N];   // area: w << 16 | h once held, 0: the whole texture
                 uint32_t mw[WA_N], mh[WA_N], held[WA_N]; unsigned next;
                 uint32_t lw[WA_N], lh[WA_N], run[WA_N]; } wa_table;   // the last crop's extent and how many presents in a row it has been the same   // the presenting thread's: the largest crop's extent and how long it held
// A present of texture ser (tw x th) showing crop (x, y, w, h; NULL or w <= 0: the whole texture). Returns 1 when the texture's area just became active (for a log line)
static inline int wa_present(wa_table *t, uint64_t ser, uint32_t tw, uint32_t th, const int *crop) {
    if (!ser || !tw || !th || tw > 0xffff || th > 0xffff) return 0;
    uint32_t ex = tw, ey = th;
    if (crop && crop[2] > 0 && crop[3] > 0 && crop[0] >= 0 && crop[1] >= 0) {
        uint64_t x1 = (uint64_t)crop[0] + (uint64_t)crop[2], y1 = (uint64_t)crop[1] + (uint64_t)crop[3];
        ex = x1 < tw ? (uint32_t)x1 : tw; ey = y1 < th ? (uint32_t)y1 : th; }
    int k = -1;
    for (int i = 0; i < WA_N; i++) if (atomic_load_explicit(&t->ser[i], memory_order_relaxed) == ser) { k = i; break; }
    if (k < 0) { k = (int)(t->next++ % WA_N);   // a new texture takes the oldest slot
        atomic_store_explicit(&t->area[k], 0, memory_order_release); atomic_store_explicit(&t->ser[k], ser, memory_order_release);
        t->mw[k] = ex; t->mh[k] = ey; t->held[k] = 0; t->lw[k] = ex; t->lh[k] = ey; t->run[k] = 0; return 0; }
    if (ex == t->lw[k] && ey == t->lh[k]) t->run[k]++; else { t->lw[k] = ex; t->lh[k] = ey; t->run[k] = 0; }
    if ((ex < t->mw[k] || ey < t->mh[k]) && t->run[k] >= WA_SHRINK) {   // a smaller crop has held: it is the largest from now on (held as the hold already passed)
        t->mw[k] = ex; t->mh[k] = ey; t->held[k] = WA_HOLD;
        if ((uint64_t)ex * ey * 10 > (uint64_t)tw * th * 9) { atomic_store_explicit(&t->area[k], 0, memory_order_release); return 0; }
        atomic_store_explicit(&t->area[k], ex << 16 | ey, memory_order_release); return 1; }
    if (ex > t->mw[k] || ey > t->mh[k]) {   // the crop grew: the whole texture until the new largest has held
        if (ex > t->mw[k]) t->mw[k] = ex; if (ey > t->mh[k]) t->mh[k] = ey;
        t->held[k] = 0; atomic_store_explicit(&t->area[k], 0, memory_order_release); return 0; }
    if (t->held[k] >= WA_HOLD) return 0;
    if (++t->held[k] < WA_HOLD) return 0;
    if ((uint64_t)t->mw[k] * t->mh[k] * 10 > (uint64_t)tw * th * 9) return 0;   // the crop covers (nearly) the whole texture: nothing to save
    atomic_store_explicit(&t->area[k], t->mw[k] << 16 | t->mh[k], memory_order_release); return 1;
}
// The held area of texture ser, 0 for none
static inline uint32_t wa_area(wa_table *t, uint64_t ser) {
    for (int i = 0; i < WA_N; i++) if (atomic_load_explicit(&t->ser[i], memory_order_acquire) == ser) return atomic_load_explicit(&t->area[i], memory_order_acquire);
    return 0;
}
// A pass's area from its attachments: n colour attachments (their texture's serial, level and slice; ser 0: not attached), every attached one a window texture with the same area at
// level 0, slice 0, and at least one; the depth / stencil attachment, if any (dw, dh nonzero), no smaller than the area. Returns w << 16 | h, 0 for the whole pass
static inline uint32_t wa_pass(wa_table *t, int n, const uint64_t *ser, const uint32_t *level, const uint32_t *slice, uint32_t dw, uint32_t dh) {
    uint32_t a = 0; int any = 0;
    for (int i = 0; i < n; i++) { if (!ser[i]) continue;
        uint32_t ai = level[i] || slice[i] ? 0 : wa_area(t, ser[i]); if (!ai || (any && ai != a)) return 0; a = ai; any = 1; }
    if (!any) return 0;
    if ((dw || dh) && (dw < (a >> 16) || dh < (a & 0xffff))) return 0;
    return a;
}
