// Vitals on the iPhone and iPad (DmVitals.m; NX18-X2.0 vitals.md): two solid pills in the touch controls' top row, either side of − (≡) +, showing the frame rate and
// CPU power on the left, heat, battery and the time on the right. Display only: it takes no touch. Its one 1 s timer runs only while Vitals is on or the in-game menu is open,
// and only in the foreground. The in-game menu's header reads the compact line (dm_vitals_compact_text) on each tick it posts.
#pragma once
#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif
UIView *dm_vitals_view(void);                       // the view, made once; front_ios.m adds it over the pad
void dm_vitals_set_level(int level);                // 0 off, 1 Standard, 2 Detailed (DM_SHOW_FPS); the host's publisher follows
int dm_vitals_get_level(void);
void dm_vitals_layout(CGRect row, CGFloat u, CGRect center);   // the controls' top row (safe), the pad's unit and the − (≡) + span to keep clear of
void dm_vitals_menu_open(int open);                 // the in-game menu: Vitals over the picture hides; the header's line keeps the figures coming, Vitals on or off
void dm_vitals_foreground(int fg);                  // the app's scene: the timer runs only in the foreground
// The menu header's compact line, plain text with the 🌡 and ▮ placeholders: "60 fps · 🌡 Warm · ▮82% · 9:41"; drop 1 leaves out the time, 2 the heat word too
const char *dm_vitals_compact_text(int drop);
int dm_vitals_thermal(void);                        // 0-3 (Cool, Warm, Hot, Too hot), -1 unknown: the header's thermometer glyph
int dm_vitals_battery(void);                        // percent, -1 unknown: the header's battery glyph
int dm_vitals_timer_running(void);                  // tests: the one 1 s timer exists
extern NSString *const DmVitalsTickNotification;    // posted on the main queue after each tick while the menu is open
#ifdef __cplusplus
}
#endif
