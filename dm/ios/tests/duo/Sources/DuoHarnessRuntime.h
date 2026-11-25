#pragma once
#import <Foundation/Foundation.h>
#include "front.h"
#include "dm_input.h"
#include "touch_draw.h"

typedef struct {
    uint64_t buttons;
    int32_t lx, ly, rx, ry;
    int touch_count;
    dm_touch touches[16];
    uint64_t touch_update_count;
    int last_touch_count;
    dm_touch last_touches[16];
} DuoHarnessInput;

typedef struct {
    uint64_t buttons;
    int32_t lx, ly, rx, ry;
} DuoHarnessPlayerInput;

typedef struct {
    float acceleration[3];
    float rotation[3];
} DuoHarnessMotion;

typedef struct {
    DuoHarnessInput input;
    DuoHarnessPlayerInput players[DM_PLAYERS];
    uint32_t connected_players;
    DuoHarnessMotion controller_motion[DM_PLAYERS];
    uint32_t controller_motion_mask;
} DuoHarnessState;

DuoHarnessInput duo_harness_input(void);
int duo_harness_rumble(void);   // the in-game menu's rumble switch (dm_haptics_set_enabled)
int duo_harness_present_stretch(void);   // whether the present was last told to stretch the picture (mtl_present_stretch, Picture Stretch)
int duo_harness_front_menu(void);   // what DmGamepad.m last told the host of its in-game menu (dm_front_menu_set): 1 open, 0 closed
void duo_harness_set_web_touch(int on);   // front_web_touch: 1 as if an offline HTML page were shown over the picture
int duo_harness_vitals_level(void);   // what DmVitals.m last told the host's publisher (dm_vitals_level_set)
int duo_harness_vitals_menu(void);   // the publisher's menu flag (dm_vitals_menu_set): 1 while the in-game menu's header reads the figures
void duo_harness_set_vitals(int fps, int cpu_mw, int capped);   // one published window, fresh
void duo_harness_set_saved_ns(uint64_t ns);   // dm_fs_last_commit_ns: the last save commit (CLOCK_MONOTONIC), 0 none yet
void duo_harness_set_present_why(int fx, int sharp, int aa);   // as if the live present had last done this with Upscaling, Sharpening and Anti-aliasing (front.h DM_FX_* and the others)
void dm_set_opmode(int mode);
int dm_opmode(void);
DuoHarnessState duo_harness_state(void);
void duo_harness_clear(void);

int duo_harness_touch_frame(touch_frame *f);   // the last frame the gamepad handed the present (mtl_present_touch) in f; how many it handed over
const uint8_t *duo_harness_touch_atlas(int *w, int *h, uint32_t *gen);   // the last atlas (BGRA, premultiplied, w * 4 bytes a row) and its generation, NULL before one
int duo_harness_touch_atlas_channels(void);   // 2: the last atlas was handed over as grey and alpha, 4: BGRA
bool dm_touch_in_frame(void);   // front_ios.m: the present draws the touch controls now
int duo_harness_present_draws(void);   // as if a live present drew the last frame and completed: 1 when the gamepad was told (front_touch_drawn, on the main queue); also ends a stall
void duo_harness_set_present_idle(uint64_t ns);   // mtl_present_touch_idle_ns from now on: the time since the last live present (UINT64_MAX: none yet)
int duo_harness_touch_releases(void);   // how many times the gamepad let the atlas go (mtl_present_touch_release)

FOUNDATION_EXPORT NSString * const DuoHarnessInputDidChangeNotification;
