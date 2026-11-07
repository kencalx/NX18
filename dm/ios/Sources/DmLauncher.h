// The settings screen before the game starts (Launcher.swift, SwiftUI), which front_ios.m shows when the window appears. Launcher.swift implements the declaration below
// (@c @implementation: the compiler checks the Swift signature against it, through the bridging header, DmIOS-Bridging-Header.h); front_ios.m calls it, and the Duo harness's
// stand-in defines it (dm/ios/tests/duo/Sources/DuoRuntimeStubs.m), both with this header, so a change to one side that the others do not follow fails to compile
#pragma once
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif
// Shows the launcher over view_controller (the root UIViewController, passed unretained: __bridge) and returns true; done runs once Play has put the settings into the
// environment. false: no launcher (no dm/launcher.json, or DM_LAUNCHER=0), and done is not called. Main thread only, as the Swift body asserts; done is called on the main
// thread too (UIKit's dismiss completion), which it needs: front_ios.m's launcher_done starts the game's views
bool dm_show_launcher(void *_Nonnull view_controller, void (*_Nonnull done)(void));
#ifdef __cplusplus
}
#endif
