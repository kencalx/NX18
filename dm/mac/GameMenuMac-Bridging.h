// The C the Mac host's Swift (dm/mac/GameMenuMac.swift and the iOS menu's GameMenu.swift, GameMenuPanel.swift, built into dmhost by dm/host/Makefile) calls: the menu's settings
// and cheats as the iOS app declares them (DmGameMenu.h; the Mac's are in front_mac.m, hle_cheats.c and hle_fs.c), the panel's input bits, and the Mac front end's own
#include <stdbool.h>
#include "../ios/Sources/DmGameMenu.h"
#include "../host/game_menu_input.h"
bool dm_mac_pads_any(void);   // front_mac.m: a raw HID, Switch 2 or Joy-Con pad is there (GameController does not list those)
void dm_mac_capture(void);    // front_mac.m: Take Screenshot, as Capture and ⇧⌘S
