// The in-game menu: GameMenu.swift builds it, the gamepad's menu button at the top centre opens it (DmGamepad.m). It holds the controller layout, the launcher
// settings the running game takes at once (front_ios.m dm_setting_live) and the cheats; the other settings stay on the settings screen before the game starts.
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif
void *dm_game_menu(void);   // GameMenu.swift: a retained UIMenu, rebuilt each time it opens
int dm_pad_layout(void);   // DmGamepad.m: 0 = 2D, 1 = 3D, 2 = Tap (DM_GAME_PAD_LAYOUT's numbers)
bool dm_pad_layout_offered(int layout);   // Tap only in handheld mode
void dm_pad_layout_set(int layout);   // releases every touch first, and is saved for the next start
void dm_gamepad_touch_feedback(bool on);   // DM_TOUCH_HAPTICS
void dm_gamepad_touch_look(const char *env, const char *value);   // DM_TOUCH_SIZE or DM_TOUCH_OPACITY, at once (DmGamepad.m)
double dm_gamepad_size(void);   // the touch controls' size factor (DM_TOUCH_SIZE; 1 = Large)
bool dm_setting_live(const char *env, const char *value);   // front_ios.m: value NULL asks whether the running game takes env at once; otherwise applies it
void dm_setting_env(const char *env, const char *value);   // front_ios.m: a pick into the environment, under the lock a host thread copies such a variable under (front.h front_env_copy)
bool dm_setting_held(const char *env);   // front_ios.m: the front end holds this live setting's value while the game runs (Picture under Ultrawide): its row is shown disabled
const char *dm_setting_why(const char *env);   // front_ios.m: why this live setting does nothing at the moment, as the running game knows it (a static string), or NULL
bool dm_setting_working(const char *env);   // front_ios.m: the running game says this live setting's choice took effect at the last present (MetalFX upscaled)
int dm_gamepad_touch_hidden(void);   // DmGamepad.m: 0 the touch controls are drawn, 1 hidden while a controller is connected, 2 the Tap layout draws none (main thread)
// The cheats (dm/host/hle_cheats.c, as dm.h declares them) that GameMenu.swift's Cheats submenu lists and toggles: the file of this build in the cheats folder, Documents/cheats on the iPhone (main.m).
// They show nothing until the host has loaded them (dm_cheats_init, on the preload thread); a string returned points into hle_cheats.c's static arrays, and the menu copies it at once
int dm_cheats_found(void);
int dm_cheats_ncheats(void);
const char *dm_cheats_build(void);
const char *dm_cheats_version(void);
const char *dm_cheats_dir_path(void);
int dm_cheats_nothers(void);
const char *dm_cheat_name_at(int i);
const char *dm_cheat_why_at(int i);
const char *dm_cheat_section_at(int i);
int dm_cheat_kind_at(int i);
int dm_cheat_flags_at(int i);
int dm_cheat_on_at(int i);
void dm_cheat_toggle(int i);
void dm_cheats_reload(void);
int dm_cheats_master(void);
void dm_cheats_master_set(int on);
#ifdef __cplusplus
}
#endif
