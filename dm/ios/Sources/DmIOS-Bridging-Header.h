// The C and Objective-C declarations Launcher.swift, GameMenu.swift and Metrics.swift use (CloudSaves.h, DmGameMenu.h, DmMetrics.h), and those they implement with
// @c @implementation (DmLauncher.h's dm_show_launcher, DmGameMenu.h's dm_game_menu, DmMetrics.h's dm_metrics_modern_start), which the compiler checks the Swift
// signatures against. project.yml points SWIFT_OBJC_BRIDGING_HEADER here, and so does the Duo harness (dm/ios/tests/duo/project.yml).
#import "CloudSaves.h"
#import "DmGameMenu.h"
#import "DmLauncher.h"
#import "DmMetrics.h"
