// The GPU clock rescue (hle_nvn.c clock_rescue_tick): iOS sets the GPU's clock to the frame rate it sees delivered. A heavy moment that makes frames late can leave
// the clock at about a third of its speed, where the same frames stay late, so the game stays below 60 with the phone cool (gpu-clock-collapse, BotW at about 40 fps
// for 90 s, Bananza at 30). The player's way out was the pause menu: a few light frames at 60, then iOS raises the clock. This does the same through the game's own
// resolution: for about 3 s its 3D views are drawn smaller, its frames fit 16.7 ms at the low clock, the 60 cadence comes back, and the size goes back to what it was.
// The rescue's factor (RESCUE_SCALE) is one of three the render scale's setter composes (nvn_heat.h nvn_scale: the player's Render scale, the heat ladder's, the rescue's),
// so its end takes its own factor back and leaves a heat rung that came or went meanwhile as it is. Its lever is the game's: a render-scale stub (Breath of the Wild, Tears of
// the Kingdom: state +0x14, or +0x10 for a stub without it) or, in the Mario Kart World family, the GPU time its own dynamic resolution reads, stretched (heat-ladder.md §6)
//
// Pure decision logic, one call a second (the caller's tick), tested in dm/host/tests/t_clock_rescue.c:
//   stuck: the target is 60 or more, the frame rate below 90% of it for RESCUE_STUCK_S ticks in a row, and the latest GPU probe at RESCUE_RATIO or more of the session's
//          fastest (the GPU's clock low, not a heavy scene at full clock), with nothing that holds it off (nvn_rescue_held: a heat or Low Power Mode hold, a movie, a step
//          the game fixes itself, thermal state 2 or worse);
//   rescue: the rescue's factor RESCUE_SCALE (the composed scale at least 0.5) for its hold (RESCUE_HOLD_S ticks; DM_CLOCK_RESCUE_S=3-20 sets another), then 1;
//   back-off: a rescue that comes within RESCUE_SOON_S past the wait after the last one's end doubles the wait (RESCUE_WAIT_S, up to RESCUE_WAIT_MAX_S), and RESCUE_CLEAN_S
//          at the target sets it back. A scene that cannot hold 60 at any clock is left alone after a few tries.
//
// The cool-down (nvn_rescue.cool; hle_nvn.c: the default in the stretch family, DM_CLOCK_RESCUE=classic for the rescue above): the rescue that holds 60 with 0.75-sized views
// did not bring the clock back on the iPhone (Bananza: 5 rescues, the probe at 3.2x through every one). The owner's pause did: about 5 s of the menu at 20-30% GPU busy and
// the probe went from 3.2x to 1.3x (NX18-X2.0 gpu-clock-collapse.md, run 6). So the cool-down draws the views at the floor (RESCUE_COOL_SCALE: the stretch family's ×4) for
// RESCUE_COOL_HOLD_S with the game's controller held at interval 3 (20 fps; 2 where it has no 3; hle_fctl.c dm_fctl_cool), as light a load as the game allows, and no probe back to 60 until it ends: then the game's own controller probes as usual
#pragma once
#include <stdint.h>

enum { RESCUE_COOL_HOLD_S = 8 };
#define RESCUE_COOL_SCALE 0.5f
enum { RESCUE_STUCK_S = 2, RESCUE_HOLD_S = 3, RESCUE_SOON_S = 10, RESCUE_WAIT_S = 10, RESCUE_WAIT_MAX_S = 160, RESCUE_CLEAN_S = 60 };
#define RESCUE_RATIO 2.3
#define RESCUE_SCALE 0.75f

typedef struct {
    int below;            // ticks in a row below 90% of the target
    int left;             // ticks left of a rescue under way (0: none)
    int wait;             // the current back-off, s
    double next_ok;       // no rescue before this time, s
    double last_end;      // the last rescue's end, s (0: none yet)
    double last_below;    // the last tick below 90% of the target, s
    unsigned count;       // rescues so far
    int hold;             // a rescue's ticks (RESCUE_HOLD_S; DM_CLOCK_RESCUE_S, nvn_rescue_hold_parse)
    int cool;             // the cool-down (above): RESCUE_COOL_SCALE for RESCUE_COOL_HOLD_S (nvn_rescue_cool)
} nvn_rescue;

typedef struct {
    double now;           // s
    double fps;           // frames shown in the last tick
    double target;        // the frame-rate target (60; 30 or 0: not rescued; nvn_rescue_target)
    double ratio;         // the latest GPU probe against the session's fastest (0: none yet)
    int held;             // nvn_rescue_held: a heat or Low Power Mode hold, a movie playing, a step the game fixes itself, thermal state 2 or worse
} nvn_rescue_in;

enum { RESCUE_NONE = 0, RESCUE_START = 1, RESCUE_END = 2 };

static inline void nvn_rescue_init(nvn_rescue *r) { *r = (nvn_rescue){0}; r->wait = RESCUE_WAIT_S; r->hold = RESCUE_HOLD_S; }
// The cool-down: its factor and its hold (a DM_CLOCK_RESCUE_S set before or after still sets the hold)
static inline void nvn_rescue_cool(nvn_rescue *r) { r->cool = 1; if (r->hold == RESCUE_HOLD_S) r->hold = RESCUE_COOL_HOLD_S; }
// DM_CLOCK_RESCUE_S: a rescue's hold in seconds, 3 to 20 (3 is RESCUE_HOLD_S, as without it). 0: unset or empty; -1: refused (not a whole number in range). The phone's clock
// came back only after about 5 s of unbroken 60 a step (NX18-X2.0 gpu-clock-collapse.md), longer than the 3 s hold
static inline int nvn_rescue_hold_parse(const char *e) {
    if (!e || !*e) return 0;
    int v = 0; for (const char *c = e; *c; c++) { if (*c < '0' || *c > '9' || v > 100) return -1; v = v * 10 + (*c - '0'); }
    return v >= RESCUE_HOLD_S && v <= 20 ? v : -1;
}

// One tick: RESCUE_START when the scale is to go down now, RESCUE_END when it is to go back, else RESCUE_NONE
static inline int nvn_rescue_step(nvn_rescue *r, const nvn_rescue_in *in) {
    if (r->left > 0) {   // a rescue under way: it ends after its ticks, or at once when a hold or a movie starts (they set their own rate)
        if (--r->left == 0 || in->held) { r->left = 0; r->last_end = in->now; r->below = 0; return RESCUE_END; }
        return RESCUE_NONE;
    }
    if (in->held || in->target < 60 || in->fps >= 0.9 * in->target) {
        if (r->last_end > 0 && in->now - r->last_below >= RESCUE_CLEAN_S) { r->wait = RESCUE_WAIT_S; r->next_ok = 0; }   // a minute at the target: the back-off starts again
        r->below = 0; return RESCUE_NONE;
    }
    r->last_below = in->now;
    if (++r->below < RESCUE_STUCK_S || in->ratio < RESCUE_RATIO || in->now < r->next_ok) return RESCUE_NONE;
    if (r->last_end > 0 && in->now - r->last_end < r->wait + RESCUE_SOON_S) { r->wait *= 2; if (r->wait > RESCUE_WAIT_MAX_S) r->wait = RESCUE_WAIT_MAX_S; }
    const int hold = r->hold > 0 ? r->hold : RESCUE_HOLD_S;
    r->next_ok = in->now + hold + r->wait;
    r->left = hold; r->below = 0; r->count++;
    return RESCUE_START;
}

// The target the rescue judges against: the frame step's (state +0, DM_FPS_TARGET) where the game has a state page, and no more than a step the game fixes itself allows
// (fixed: state +0x24, in vsyncs; Mario Kart World's own 30 fps mode, Breath of the Wild's VFR override at 2: 60 / fixed, 30, below 60 and not rescued, so a minute of it also
// starts the back-off again); else, in the stretch family, its own frame-rate controller's top rate (hle_fctl.c dm_fctl_top_fps: 60 over its lowest interval, so a
// cutscene's fixed 20 is below 60 and not rescued; 0 = no controller seen: 60)
static inline double nvn_rescue_target(const float *page, int fixed, int top) {
    if (!page) return top > 0 ? top : 60;
    double t = *page;
    if (fixed >= 2 && 60.0 / fixed < t) t = 60.0 / fixed;
    return t;
}
// What holds the rescue off (nvn_rescue_in.held; a rescue under way ends at once): a movie, a heat or Low Power Mode hold (movie, capped), a step the game fixes itself
// (fixed >= 2, as above: its own 30 fps is no stuck clock), and the phone at thermal state 2 or worse as the heat ladder last read it (th: DM_HEAT_FORCE's when forced; -1 with
// DM_THERMAL_CAP=0, or none): there iOS lowers the GPU's clock for the heat, which a rescue cannot raise, and the 30 fps hold may wait 15 s behind 70% (heat-ladder.md D15),
// in which the rescue would stack its 0.75 under 70% (0.525; x3.63 in the stretch family). Below state 2 it runs as before the heat ladder's step 4
static inline int nvn_rescue_held(int movie, int capped, int fixed, int th) { return movie || capped || fixed >= 2 || th >= 2; }
// The rescue's factor while a rescue is under way (the setter composes it under the player's and the heat ladder's), 1 otherwise
static inline double nvn_rescue_factor(const nvn_rescue *r) { return r->left > 0 ? (r->cool ? RESCUE_COOL_SCALE : RESCUE_SCALE) : 1.0; }
