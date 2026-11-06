// The heat / Low Power mark of the iOS frame-rate counter (front_ios.m fps_show): what the host packs while heat or Low Power Mode holds something back (hle_nvn.c
// dm_power_cap_now: the frame rate cap; nvn_mtl.m mtl_fx_power_hold: MetalFX's upscaling), and the note the counter shows under the count. Plain C, so
// dm/gfx/tests/t_power_mark.c runs it on any machine
#pragma once
#include <stddef.h>
#include <stdio.h>

enum { PM_HEAT = 1, PM_LOW_POWER = 2 };   // the causes: iOS's thermal state serious or worse, Low Power Mode (hle_nvn.c thermal_capped's CAP_HEAT and CAP_LOW_POWER)

// The frame rate cap's mark: the causes << 8 | the frame rate they hold (30 for a frame-step game, 60 for a 120 fps limiter), 0 when no cause holds it
static inline int pm_frame_cap(int why, int fps) { return why ? why << 8 | fps : 0; }
// A frame-step game's: the causes hold 30 only above a 30 target and while no movie plays (a 30 target and a movie are their own 30, whatever the heat)
static inline int pm_step_cap(int why, int movie, double target) { return pm_frame_cap(!movie && target > 30 ? why : 0, 30); }

// The note under the count for a frame rate cap's mark (cap) and MetalFX's held-back causes (fx): the cause in why ("Hot" when heat is one of them, else "Low Power") and what is held
// back in what ("30 fps cap", "no MetalFX" or both). Returns PM_HEAT or PM_LOW_POWER (the counter's icon: a thermometer or a battery), 0 when nothing is held back (no note)
static inline int pm_note(int cap, int fx, char *why, size_t why_n, char *what, size_t what_n) {
    if (!cap && !fx) return 0;
    int hot = ((cap >> 8) | fx) & PM_HEAT;
    snprintf(why, why_n, "%s", hot ? "Hot" : "Low Power");
    if (cap && fx) snprintf(what, what_n, "%d fps cap, no MetalFX", cap & 0xff);
    else if (cap) snprintf(what, what_n, "%d fps cap", cap & 0xff);
    else snprintf(what, what_n, "no MetalFX");
    return hot ? PM_HEAT : PM_LOW_POWER;
}
