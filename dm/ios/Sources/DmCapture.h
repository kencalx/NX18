// The player's screenshots on the iPhone and iPad (NX18-X2.0 captures-album.md): the Capture button of a controller (DmGamepad.m) and the in-game menu's Take Screenshot
// (GameMenu.swift) ask for one; front_capture.h names the file in Documents/Captures and the graphics side draws the game picture into it, without the touch controls or
// Vitals. A small notice with the picture shows at the top left for two seconds (as a console's "Captured" notice), and VoiceOver hears it. Main thread
#pragma once
#import <UIKit/UIKit.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif
void dm_capture_screenshot(UIView *over);   // over: a view in the game's window; the notice goes on that window
// iOS's own screenshots (side and volume buttons, or a controller's Share button, which iOS keeps for itself on some pads whatever the app asks: the GameSir G8+): with
// DM_CAPTURE_SYSTEM on (the settings' Save screenshots to Captures, on by default) each also saves NX 18's clean picture to Captures. front_ios.m starts it with the game view
void dm_capture_follow_system(UIView *over);
void dm_capture_follow_set(bool on);   // the in-game menu (dm_setting_live)
#ifdef __cplusplus
}
#endif
