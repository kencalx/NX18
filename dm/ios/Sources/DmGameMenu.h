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
bool dm_setting_live(const char *env, const char *value);   // front_ios.m: value NULL asks whether the running game takes env at once; otherwise applies it
// The cheats (dm/host/hle_cheats.c, as dm.h declares them) that GameMenu.swift's Cheats submenu lists and toggles: the file of this build in the cheats folder, Documents/cheats on the iPhone (main.m)
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
