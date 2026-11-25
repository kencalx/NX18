// Vitals (NX18-X2.0 vitals.md): the figures the present thread publishes once a second (hle_nvn.c vitals_tick), and the strings both front ends show.
// Pure C, no host state: the graphics unit test t_vitals checks the formatting, the "cap" rule, the drop order, the hysteresis and the seqlock reader.
//   Standard, left:   60 fps · CPU 2.1 W        (30 fps cap · CPU 1.2 W while NX 18 holds the game below its own target; 60 fps, 30 rendered · CPU 2.4 W while frame generation shows frames)
//   Standard, right:  🌡 Warm · ▮82% ⚡ · 9:41
//   Detailed (DM_SHOW_FPS=2) adds a second line: GPU busy 64% · max 33 ms        P-cores 82%
//   The in-game menu's header: 60 fps · 🌡 Warm · ▮82% · 9:41
// 🌡 and ▮ are placeholders a front end may draw as symbols (the iPhone's thermometer and battery glyphs); the text stays the same either way.
// When a half does not fit, its fields drop in a fixed order: left, the word "CPU" then the W field; right, the time then the heat word (its glyph stays).
// The frame rate and the battery never drop.
#pragma once
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
    uint64_t stamp_ns;     // when the window ended (now_ns); 0: nothing published yet
    int32_t cpu_mw;        // CPU power, iOS's estimate of what NX 18's CPU work drew (task_energy); -1: unknown
    int16_t pshare_pm;     // share of NX 18's CPU time on the performance cores, per mille; -1: unknown
    int16_t gpu_busy_pm;   // time the GPU had NX 18's work in flight, per mille of the window; -1: unknown
    int32_t fps10;         // frames that reached the screen, × 10
    int32_t max_gap_100us; // the longest gap between two frames on screen, in 0.1 ms
    int8_t capped;         // 1: NX 18 holds the game below its own target (never for a 30 fps target, a movie or the in-game menu's hold)
    int8_t cause;          // why, when capped: bit 0 heat, bit 1 Low Power Mode; 0: 60 did not hold
    int32_t gen10;         // generated pictures on screen (frame generation, DM_FRAMEGEN), × 10, from their own presented handlers; fps10 stays the frames the game rendered
    int32_t shown10;       // every picture on screen while frame generation shows frames, × 10 (nvn_vitals_shown10); 0 while it shows none
} nvn_vitals;

// The device's side, which the front end reads (main thread): Apple's thermal state, the battery and the time
typedef struct {
    int thermal;           // 0 nominal (Cool), 1 fair (Warm), 2 serious (Hot), 3 critical (Too hot); -1 unknown
    int bat_pct;           // -1: no battery reading
    int bat_state;         // 0 unknown, 1 unplugged, 2 charging, 3 full
    int lpm;               // Low Power Mode on
    const char *time;      // "9:41" in the player's 12- or 24-hour setting, no AM/PM; NULL or "" leaves it out
} nvn_vitals_dev;

// Seqlock: the present thread writes, the main thread reads. The reader retries while the counter is odd or moved, so it always gets one window whole
typedef struct { _Atomic uint32_t seq; nvn_vitals v; } nvn_vitals_pub;
static inline void nvn_vitals_publish(nvn_vitals_pub *p, const nvn_vitals *v) {
    uint32_t s = atomic_load_explicit(&p->seq, memory_order_relaxed);
    atomic_store_explicit(&p->seq, s + 1, memory_order_relaxed);
    atomic_thread_fence(memory_order_release);
    memcpy((void *)&p->v, v, sizeof *v);
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&p->seq, s + 2, memory_order_release);
}
static inline int nvn_vitals_read(nvn_vitals_pub *p, nvn_vitals *out) {   // 1: a whole window copied; 0: the writer kept moving (try again next tick)
    for (int i = 0; i < 16; i++) {
        uint32_t a = atomic_load_explicit(&p->seq, memory_order_acquire);
        if (a & 1) continue;
        memcpy(out, (const void *)&p->v, sizeof *out);
        atomic_thread_fence(memory_order_acquire);
        if (atomic_load_explicit(&p->seq, memory_order_relaxed) == a) return 1;
    }
    return 0;
}

#define NVN_VITALS_STALE_NS 2000000000ull   // older than this (a loading screen, the background): "--"
static inline int nvn_vitals_fresh(const nvn_vitals *v, uint64_t now_ns) { return v && v->stamp_ns && now_ns >= v->stamp_ns && now_ns - v->stamp_ns <= NVN_VITALS_STALE_NS; }

static inline const char *nvn_vitals_heat_word(int thermal) {
    switch (thermal) { case 0: return "Cool"; case 1: return "Warm"; case 2: return "Hot"; case 3: return "Too hot"; default: return NULL; }
}

// Hysteresis, so a steady scene commits text only on real moves: the frame rate within ±1 stays, CPU power moves in 0.1 W steps only after it changed by 0.2 W or more two ticks in a row
typedef struct { int fps; int w10; int pend_w10; int pend_n; int primed; int shown; int shown_fps; } nvn_vitals_smooth;   // shown, shown_fps: nvn_vitals_shown_step
static inline void nvn_vitals_smooth_step(nvn_vitals_smooth *s, int fps, int w10, int *out_fps, int *out_w10) {
    if (!s->primed) { s->fps = fps; s->w10 = w10; s->pend_n = 0; s->primed = 1; }
    else {
        if (fps < 0 || s->fps < 0 || fps > s->fps + 1 || fps < s->fps - 1) s->fps = fps;
        if (w10 < 0 || s->w10 < 0) { s->w10 = w10; s->pend_n = 0; }
        else if (w10 >= s->w10 + 2 || w10 <= s->w10 - 2) {
            if (s->pend_n && (w10 >= s->pend_w10 - 1 && w10 <= s->pend_w10 + 1)) { s->w10 = w10; s->pend_n = 0; }
            else { s->pend_w10 = w10; s->pend_n = 1; }
        } else s->pend_n = 0;
    }
    *out_fps = s->fps; *out_w10 = s->w10;
}

static inline size_t nvn_vitals_cat(char *out, size_t n, size_t at, const char *s) {
    if (!n) return at;
    size_t l = strlen(s);
    if (at < n - 1) { size_t c = l < n - 1 - at ? l : n - 1 - at; memcpy(out + at, s, c); out[at + c] = 0; }
    return at + l;
}

// The pictures a second on screen while frame generation shows frames, × 10 (the publisher, vitals_tick): the frames rendered plus the generated pictures, at most one generated
// picture per frame rendered and never more than the display link's ticks (link_hz); 0 under half a generated picture a second. The window closes at a game frame, so it holds
// whole frames rendered, but the generated pictures are counted from their own presented handlers, whose edge falls apart from them: a steady 30 rendered and 30 generated holds
// 29 or 31 of them by turns. So the generated count is taken as one per frame rendered within a picture a second of it, and the total is capped: such a window reads 60, never
// 59 or 61 on a 60 Hz screen
static inline int32_t nvn_vitals_shown10(int32_t fps10, int32_t gen10, int link_hz) {
    if (gen10 < 5 || fps10 < 0) return 0;
    int32_t g = gen10 >= fps10 - 10 ? fps10 : gen10, s = fps10 + g, cap = link_hz > 0 ? link_hz * 10 : s;
    return s < cap ? s : cap;
}
// The reader's side (the main thread, after nvn_vitals_smooth_step, whose held frame rate s->fps it shows beside it): the pictures a second on screen, held with the frame rate.
// It moves when the held frame rate moves, and while that holds it holds within ±2, the frame rate's ±1 for a frame rendered and its generated picture: a window that loses
// one frame to a hitch (58 of 60, 29 of 30) reads as the second before, "60 fps, 30 rendered", not "58 fps, 30 rendered". The figure shown is then kept to the held frame
// rate's [fps + 1, 2 × fps]: never more than one generated picture per frame rendered beside it, as the publisher counts them (nvn_vitals_shown10), and one at least while frame
// generation shows any. 0 when it shows none or the figures are stale (fresh 0)
static inline int nvn_vitals_shown_step(nvn_vitals_smooth *s, const nvn_vitals *v, int fresh) {
    int raw = fresh && v->shown10 > 0 ? (v->shown10 + 5) / 10 : 0;
    if (raw <= 0 || s->shown <= 0 || s->fps != s->shown_fps || raw > s->shown + 2 || raw < s->shown - 2) { s->shown = raw; s->shown_fps = s->fps; }
    int out = s->shown;
    if (out > 0 && s->primed && s->fps > 0) { if (out > 2 * s->fps) out = 2 * s->fps; if (out < s->fps + 1) out = s->fps + 1; }
    return out;
}
// The frame-rate field: "60 fps", "30 fps cap" (Detailed adds "· hot" or "· Low Power"), "60 fps, 30 rendered" while frame generation shows frames (shown, from
// nvn_vitals_shown_step: the pictures on screen, above the frames rendered; made-up frames are never counted as the game's, vitals.md), "-- fps" when stale
static inline size_t nvn_vitals_fps_text(char *out, size_t n, const nvn_vitals *v, int fps, int shown, int fresh, int detailed) {
    char b[48];
    if (!fresh || fps < 0) snprintf(b, sizeof b, "-- fps");
    else if (shown > fps) snprintf(b, sizeof b, "%d fps, %d rendered", shown, fps);
    else if (v->capped) snprintf(b, sizeof b, "%d fps cap%s", fps, !detailed ? "" : v->cause & 1 ? " · hot" : v->cause & 2 ? " · Low Power" : "");
    else snprintf(b, sizeof b, "%d fps", fps);
    if (n) out[0] = 0;
    return nvn_vitals_cat(out, n, 0, b);
}

// The left half. drop 0: "60 fps · CPU 2.1 W"; 1: "60 fps · 2.1 W"; 2 (or more): "60 fps". w10 is CPU power in 0.1 W (smoothed); < 0 leaves the field out. shown: as
// nvn_vitals_fps_text's (0 without frame generation)
static inline size_t nvn_vitals_left(char *out, size_t n, const nvn_vitals *v, int fps, int shown, int w10, int fresh, int detailed, int drop) {
    size_t at = nvn_vitals_fps_text(out, n, v, fps, shown, fresh, detailed);
    if (drop >= 2 || !fresh || w10 < 0) return at;
    char b[32]; snprintf(b, sizeof b, drop >= 1 ? " · %d.%d W" : " · CPU %d.%d W", w10 / 10, w10 % 10);
    return nvn_vitals_cat(out, n, at, b);
}

static inline size_t nvn_vitals_battery(char *out, size_t n, size_t at, const nvn_vitals_dev *d, int bolt) {
    char b[24];
    if (d->bat_pct < 0) return at;
    snprintf(b, sizeof b, "▮%d%%%s", d->bat_pct, bolt && (d->bat_state == 2 || d->bat_state == 3) ? " ⚡" : "");
    return nvn_vitals_cat(out, n, at, b);
}

// The right half. drop 0: "🌡 Warm · ▮82% ⚡ · 9:41"; 1: no time; 2 (or more): no heat word, the glyph stays
static inline size_t nvn_vitals_right(char *out, size_t n, const nvn_vitals_dev *d, int drop) {
    size_t at = 0; if (n) out[0] = 0;
    const char *w = nvn_vitals_heat_word(d->thermal);
    if (w) { at = nvn_vitals_cat(out, n, at, "🌡"); if (drop < 2) { at = nvn_vitals_cat(out, n, at, " "); at = nvn_vitals_cat(out, n, at, w); } }
    if (d->bat_pct >= 0) { if (at) at = nvn_vitals_cat(out, n, at, " · "); at = nvn_vitals_battery(out, n, at, d, 1); }
    if (drop < 1 && d->time && *d->time) { if (at) at = nvn_vitals_cat(out, n, at, " · "); at = nvn_vitals_cat(out, n, at, d->time); }
    return at;
}

// Detailed's second lines: left "GPU busy 64% · max 33 ms", right "P-cores 82%"; empty when stale
static inline size_t nvn_vitals_left2(char *out, size_t n, const nvn_vitals *v, int fresh) {
    if (n) out[0] = 0;
    if (!fresh) return 0;
    char b[64]; size_t at = 0;
    if (v->gpu_busy_pm >= 0) { snprintf(b, sizeof b, "GPU busy %d%%", (v->gpu_busy_pm + 5) / 10); at = nvn_vitals_cat(out, n, at, b); }
    if (v->max_gap_100us > 0) { snprintf(b, sizeof b, "%smax %d ms", at ? " · " : "", (v->max_gap_100us + 5) / 10); at = nvn_vitals_cat(out, n, at, b); }
    return at;
}
static inline size_t nvn_vitals_right2(char *out, size_t n, const nvn_vitals *v, int fresh) {
    if (n) out[0] = 0;
    if (!fresh || v->pshare_pm < 0) return 0;
    char b[32]; snprintf(b, sizeof b, "P-cores %d%%", (v->pshare_pm + 5) / 10);
    return nvn_vitals_cat(out, n, 0, b);
}

// The in-game menu header's compact line: "60 fps · 🌡 Warm · ▮82% · 9:41" (no charging bolt). drop 1: no time; 2: no heat word. Shown even with Vitals off
static inline size_t nvn_vitals_compact(char *out, size_t n, const nvn_vitals *v, int fps, int shown, int fresh, const nvn_vitals_dev *d, int drop) {
    size_t at = 0; if (n) out[0] = 0;
    (void)v;
    if (fresh && fps >= 0) { char b[40]; if (shown > fps) snprintf(b, sizeof b, "%d fps, %d rendered", shown, fps); else snprintf(b, sizeof b, "%d fps", fps); at = nvn_vitals_cat(out, n, at, b); }
    const char *w = nvn_vitals_heat_word(d->thermal);
    if (w) { if (at) at = nvn_vitals_cat(out, n, at, " · "); at = nvn_vitals_cat(out, n, at, "🌡"); if (drop < 2) { at = nvn_vitals_cat(out, n, at, " "); at = nvn_vitals_cat(out, n, at, w); } }
    if (d->bat_pct >= 0) { if (at) at = nvn_vitals_cat(out, n, at, " · "); at = nvn_vitals_battery(out, n, at, d, 0); }
    if (drop < 1 && d->time && *d->time) { if (at) at = nvn_vitals_cat(out, n, at, " · "); at = nvn_vitals_cat(out, n, at, d->time); }
    return at;
}

// Is the game held below its own target? Only for a game NX 18 paces with a target above 30 and no movie: the cause (heat, Low Power Mode) holds it, or the frame step's
// hold of k vsyncs at hz gives less than the target. The in-game menu's hold never counts (menu: 1 while it holds)
static inline int nvn_vitals_capped(float target, int movie, int cause, int hold_k, int hz, int menu) {
    if (menu || movie || target <= 30.5f || hold_k <= 0 || hz <= 0) return 0;
    if (cause) return 1;
    return (float)hz / (float)hold_k < target - 0.5f;
}
