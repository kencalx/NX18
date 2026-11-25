// The present crop's size, logging only (nvn_mtl.m present_crop_note): a game whose dynamic resolution moves its crop inside the window texture (Mario Kart World) shows how far it
// went, so a heat A/B can tell whether the picture fell to about 85% or 70% of the texture a side (the X2.0 heat ladder's first phone runs, M1). The crop moves alone do not say it.
// Each live present adds the share of the window texture its crop covers; every NVN_CROP_AREA_PRESENTS presents a line gives the mean, the smallest and the largest share, with the
// side length the mean comes to for a crop of the texture's shape, the smallest and the largest crop in pixels (a game that crops a larger texture at full resolution, 1280x720 of
// a 1920x1080 texture, reads 44.4%: the pixels show it is its full size), the thermal state and the time since launch (the line counts presents, not the power rows' frames, so
// these anchor it). A game whose presents have all shown the whole window texture, with a crop that never moved, gets no line. Plain C, so the Mac's unit tests run it
// (tests/t_crop_area.c)
#pragma once
#include <math.h>
#include <stdint.h>
#include <stdio.h>

enum { NVN_CROP_AREA_PRESENTS = 300 };   // the power and memory lines' 300 frames (hle_nvn.c), counted in presents
// One interval's presents. min_w x min_h, max_w x max_h: the crops of the smallest and the largest share. cropped: this session, a present showed less than its whole texture
typedef struct { uint64_t n; double sum, min, max; uint64_t tw, th, min_w, min_h, max_w, max_h; int cropped; } nvn_crop_area;
// One present: its window texture (tw x th) and its crop (cw x ch; the whole texture when the game set none)
static inline void nvn_crop_area_add(nvn_crop_area *a, uint64_t tw, uint64_t th, uint64_t cw, uint64_t ch) {
    if (!tw || !th) return;
    double s = (double)cw * (double)ch / ((double)tw * (double)th);
    if (!a->n || s < a->min) { a->min = s; a->min_w = cw; a->min_h = ch; }
    if (!a->n || s > a->max) { a->max = s; a->max_w = cw; a->max_h = ch; }
    a->sum += s; a->n++; a->tw = tw; a->th = th; a->cropped |= s < 1;
}
// The line for an interval's presents into b (moved: the crop moves among them; total: this session's so far; thermal: the thermal state, -1 where there is none; t_s: seconds
// since launch). Returns 0 and writes nothing when none were added, or when no present this session showed less than its whole texture and the crop never moved (a game that sets
// no crop)
static inline int nvn_crop_area_text(char *b, size_t cap, const nvn_crop_area *a, uint64_t moved, uint64_t total, int thermal, double t_s) {
    if (!a->n || !(a->cropped || total)) return 0;
    double mean = a->sum / (double)a->n;
    snprintf(b, cap, "present crop over %llu presents: %.1f%% of the %llux%llu window texture on average (%.0f%% a side), smallest %.1f%% (%.0f%% a side, %llux%llu), largest %.1f%% "
             "(%llux%llu); crop moved %llu times in them, %llu so far; thermal %d, %.0f s after launch", (unsigned long long)a->n, mean * 100, (unsigned long long)a->tw,
             (unsigned long long)a->th, sqrt(mean) * 100, a->min * 100, sqrt(a->min) * 100, (unsigned long long)a->min_w, (unsigned long long)a->min_h, a->max * 100,
             (unsigned long long)a->max_w, (unsigned long long)a->max_h, (unsigned long long)moved, (unsigned long long)total, thermal, t_s);
    return 1;
}
// The next interval starts empty; the session's cropped stays
static inline void nvn_crop_area_next(nvn_crop_area *a) { *a = (nvn_crop_area){.cropped = a->cropped}; }
