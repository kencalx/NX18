// The C the harness's Swift tests call (DuoGameMenuTests.swift, DuoShortcutTests.swift): the in-game menu's front-end functions and the harness's stubs of the host (DuoRuntimeStubs.m)
#import "DmIOS-Bridging-Header.h"   // the app's own, imported here: the implicit import through @testable import DuoHarness is deprecated
#import "DmGameMenu.h"
#import "DmVitals.h"   // DuoVitalsTests.swift: the view, its level and the menu header's line
#import "DuoHarnessRuntime.h"
#include "save_sync.h"   // DuoShortcutTests: a cloud save made with the host's own packing (save_sync_after_exit)
#import "DmLayout.h"   // dm_gamepad_view (DuoGameMenuPanelTests.swift: a pad made with DM_GAME_MENU=system)
#import "DuoLiveObjects.h"   // DuoGateMemoryTests.swift: the footprint and the live instances of the settings screen's classes
