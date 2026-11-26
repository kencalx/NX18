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
// Recording (ScreenCaptureKit, iOS 27's screen recording: the system asks the player to confirm, then the app as shown, with the game's sound, no microphone) to an HEVC .mov in Captures, filed as screenshots are (the NX 18 folder when
// This game's captures says so). Nothing is drawn over the game while it runs (the recording holds what is on screen): iOS shows its own recording indicator, and the in-game
// menu's Stop Recording row the time. iOS asks once whether the app may record. It stops, and is saved, when the app leaves the screen
void dm_capture_record_toggle(UIView *over);
bool dm_capture_recording(void);
int dm_capture_recording_seconds(void);   // how long the recording has run, 0 when none
// A controller's Capture button: a press under half a second takes a screenshot (at its release), held that long it starts or stops a recording (as it reaches half a second)
void dm_capture_button(UIView *over, bool down);
#ifdef __cplusplus
}
#endif
