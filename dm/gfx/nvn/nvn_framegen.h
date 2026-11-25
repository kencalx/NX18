// Frame generation (DM_FRAMEGEN, X2.0 item C6; off by default): the decision whether a game frame gets a generated frame before it, and the display-link tick
// sequencer that shows it (pure functions, shared by Mac / iOS; unit test tests/t_framegen.c). nvn_mtl.m ("Frame generation") does the Metal side.
// A game at a 30 fps cap on the 60 Hz link takes a frame on tick T and holds it through T+1 (g_link_hold_until). With frame generation the frame taken at T is preceded by
// G(n-1, n), MetalFX's midpoint between the previous real frame and this one, shown at T; the real frame F(n) is shown at T+1, the tick that held before. The game's own
// cadence is unchanged (it still waits two ticks per acquire) and F reaches the screen one tick (16.7 ms) later. Every per-ticket record (g_pres, g_pq_done, the present
// allocators, the link's tick record) follows F only. Where generation starts or stops that tick shifts the real frames' on-screen intervals (three ticks, then one), so the
// shift is recorded per ticket (mtl_presented_shift) and taken out where hle_nvn.c judges them: the frame step and the dropped frames still see two-tick intervals.
// fg_decide is asked once per frame the link takes. It turns generation off, with a reason the status line counts, whenever a midpoint would be wrong or unwanted: the switch off,
// no MetalFX interpolator, a movie (Ocarina of Time's opening is native 60 fps; its frames have no upscale), the host's in-game menu, a period other than two ticks (a game
// already at 60 has nothing to add; at three or more a midpoint paces unevenly), a link other than the 60 Hz one or its rescue, heat, Low Power Mode or a rung of the heat
// ladder (generation doubles the present work exactly when a phone is hot), the Battery Saver preset (the player chose battery over smoothness), a screenshot, no upscale event in this frame or no history of the last one, a change of sizes or formats, missing depth or motion.
// The first frame generated after any of those resets the interpolator's history (reset_history), as do a reset the game's upscaler asked for and the end of a movie.
#pragma once
#include <stdint.h>

enum {   // why a frame is shown without a generated frame before it (FG_GEN: it gets one)
    FG_GEN, FG_OFF, FG_UNSUPPORTED, FG_MAKING, FG_MOVIE, FG_MENU, FG_PERIOD, FG_LINK, FG_THERMAL, FG_BATTERY, FG_SHOT, FG_FPS, FG_NO_SNAP, FG_NO_UPSCALE,
    FG_NO_HISTORY, FG_KEY, FG_NO_DEPTH, FG_NO_MOTION, FG_CROP, FG_STALE, FG_ENCODE, FG_WHY_N
};
static const char *const fg_why_name[FG_WHY_N] = {"generated", "off", "unsupported", "interpolator not made yet", "movie", "in-game menu", "period not 2 ticks", "link not 60 Hz",
    "heat or Low Power Mode", "Battery Saver", "screenshot", "no 30 fps cap", "no present snapshot", "no upscale", "no history", "sizes or formats changed", "no depth", "no motion", "crop out of bounds",
    "capture overwritten", "encode failed"};

typedef struct {
    int enabled;        // DM_FRAMEGEN on
    int supported;      // +[MTLFXFrameInterpolatorDescriptor supportsMetal4FX:]
    int ready;          // an interpolator exists for this frame's key (0: being made, or MetalFX made none: failed)
    int failed;         // MetalFX made no interpolator for this key
    int movie;          // a video's pictures are handed out (hle_movie.c dm_movie_playing: the movie library or an nn::codec decoder)
    int menu;           // the front end's menu is open (dm_front_menu_now; mtl_framegen_hold in the tests)
    int period;         // ticks this frame stays on screen
    int link_mode;      // 1 = the 60 Hz link; 0 = no link, 2 = 120 Hz, 3 = 30 Hz
    int rescue;         // the link is rescued (the present thread takes drawables itself)
    int thermal;        // thermal state serious or critical, or Low Power Mode (until both have been gone 30 s), or a rung of the heat ladder
    int battery;        // the Battery Saver preset (DM_PRESET=battery)
    int shot;           // a screenshot or capture takes this frame
    int fps30;          // the 30 fps cap is in force (the scope so far: a midpoint between two-tick frames)
    int snap;           // the frame lives in a present snapshot slot until its own tick
    int upscale;        // this frame carries an upscale event (a capture of depth and motion)
    int history;        // the previous real frame's colour is in the history, from the frame right before, with the same key
    int key_changed;    // the capture's sizes or formats differ from the previous capture's
    int depth, motion;  // the capture holds depth / motion (motion may be zero motion when allowed)
    int crop_full;      // the window crop is valid (a crop that is part of the window texture is copied out for the interpolator)
    int stale;          // the capture's ring slot was taken by a later frame before this one's tick
    int reset;          // the game's upscaler asked for a history reset (DLSS reset, a new scaler)
} fg_in;
typedef struct { int gen, why, reset_history; } fg_out;
typedef struct {
    int off;            // the last decision was not FG_GEN (the next generated frame resets the history)
    int movie_was;      // a movie was playing at the last decision
    uint64_t gen, real, why[FG_WHY_N];
} fg_gate;

static inline int fg_why(const fg_in *in) {
    if (!in->enabled) return FG_OFF;
    if (!in->supported) return FG_UNSUPPORTED;
    if (in->movie) return FG_MOVIE;
    if (in->menu) return FG_MENU;
    if (in->shot) return FG_SHOT;
    if (in->thermal) return FG_THERMAL;
    if (in->battery) return FG_BATTERY;
    if (!in->fps30) return FG_FPS;
    if (in->link_mode != 1 || in->rescue) return FG_LINK;
    if (in->period != 2) return FG_PERIOD;
    if (!in->snap) return FG_NO_SNAP;
    if (!in->upscale) return FG_NO_UPSCALE;
    if (in->stale) return FG_STALE;
    if (in->key_changed) return FG_KEY;
    if (!in->depth) return FG_NO_DEPTH;
    if (!in->motion) return FG_NO_MOTION;
    if (!in->crop_full) return FG_CROP;
    if (in->failed) return FG_UNSUPPORTED;
    if (!in->ready) return FG_MAKING;
    if (!in->history) return FG_NO_HISTORY;
    return FG_GEN;
}
static inline fg_out fg_decide(fg_gate *g, const fg_in *in) {
    fg_out o = {0, fg_why(in), 0};
    int movie_ended = g->movie_was && !in->movie; g->movie_was = in->movie;
    o.gen = o.why == FG_GEN;
    if (o.gen) { o.reset_history = g->off || in->reset || movie_ended; g->off = 0; g->gen++; }
    else { g->off = 1; g->real++; }
    g->why[o.why]++;
    return o;
}
// A generated frame that could not be encoded after fg_decide said FG_GEN (no drawable work, a failed encode): counted as real, and the next one resets the history
static inline void fg_undo(fg_gate *g) { g->gen--; g->real++; g->why[FG_GEN]--; g->why[FG_ENCODE]++; g->off = 1; }

// The tick sequencer. One call per display-link tick that counts (a tick of the link's own rate). pending: a real frame whose generated frame was shown on the tick before.
// A pending real frame beats both the hold and a newly queued frame, so it is never dropped for a generated one, and a missed tick (a link stall) just shows it on the next.
enum { FG_A_EMPTY, FG_A_HELD, FG_A_PENDING, FG_A_REAL, FG_A_GEN };
typedef struct { uint64_t ticket; int has; } fg_seq;
// queued: a frame waits in the present queue; held: the previous real frame's hold has not run out; gen: fg_decide's answer for the frame this tick would take
static inline int fg_tick(fg_seq *s, int queued, int held, int gen) {
    if (s->has) { s->has = 0; return FG_A_PENDING; }
    if (!queued) return FG_A_EMPTY;
    if (held) return FG_A_HELD;
    return gen ? FG_A_GEN : FG_A_REAL;
}
static inline void fg_pend(fg_seq *s, uint64_t ticket) { s->ticket = ticket; s->has = 1; }   // after FG_A_GEN presented the generated frame of ticket
// Suspend, a discard or a rescue: the pending real frame is not shown; returns its ticket (0 = none) for the caller's accounting
static inline uint64_t fg_flush(fg_seq *s) { uint64_t t = s->has ? s->ticket : 0; s->has = 0; return t; }
