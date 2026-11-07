// The Mac app's settings window (dm/mac/Launcher.swift, SwiftUI and AppKit), which launcher.c runs in its own process before it starts the host. Launcher.swift implements the
// declaration below (@c @implementation: the compiler checks the Swift signature against it; pack_app.py hands swiftc this header with -import-objc-header), and launcher.c
// calls it with this header, so a change to one side that the other does not follow fails to compile
#pragma once

#ifdef __cplusplus
extern "C" {
#endif
// 1: Play (the window's settings are in the environment), 0: the player quit, 2: no window (no launcher.json, or "Show this window at launch" off: launcher.c applies the
// saved choices). On the main thread only, as the Swift body asserts: it runs the app's event loop (launcher.c's main calls it)
int dm_mac_launcher(void);
#ifdef __cplusplus
}
#endif
