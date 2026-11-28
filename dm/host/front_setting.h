// The in-game menu's notes that only the running game knows, shared by the iPhone's front end (front_ios.m dm_setting_why) and the Mac's (front_mac.m): why Upscaling,
// Sharpening or Anti-aliasing does nothing at the moment, from the present's last outcome (nvn_mtl.m, front.h DM_FX_* and the others). A short line for the row's note, or NULL.
// The menu reads it each time it builds its rows (GameMenu.swift gameMenuRow). Pure: the outcomes are passed in
#pragma once
#include <string.h>
#include "front.h"

// env: the setting's variable; fx, sharp, aa: mtl_present_fx_why(), mtl_present_sharp_why(), mtl_present_aa_why(); log: where the player finds the log ("Share log", "Show log")
static inline const char *front_setting_present_why(const char *env, int fx, int sharp, int aa, int share_log) {
    if (!env) return NULL;
    const char *failed = share_log ? "Couldn't start: see Share log" : "Couldn't start: see Show log";   // a pipeline that failed to build (a [RED] line in the log)
    if (!strcmp(env, "DM_PRESENT_UPSCALE")) switch (fx) {
        case DM_FX_STRETCHED: return "Not upscaling: picture is stretched";
        case DM_FX_NOT_LARGER: return "Not upscaling: picture isn't shown larger";
        case DM_FX_REFUSED: return "Not upscaling: MetalFX can't take this size";
        default: return NULL;   // upscaling, or Standard
    }
    if (!strcmp(env, "DM_PRESENT_SHARPEN")) switch (sharp) {
        case DM_SHARP_METALFX: return "Off while MetalFX upscales";
        case DM_SHARP_GAME_UPSCALER: return "Off while MetalFX runs the game's upscaler";
        case DM_SHARP_FORMAT: return "Not supported for this game's picture";
        case DM_SHARP_PIPELINE: return failed;
        default: return NULL;
    }
    if (!strcmp(env, "DM_POST_AA")) switch (aa) {
        case DM_AA_FORMAT: return "Not supported for this game's picture";
        case DM_AA_FAILED: return failed;
        default: return NULL;
    }
    return NULL;
}
