// Cloud saves on the iPhone (dm/host/save_sync.h): the iCloud Drive folder the player picked in the
// launcher's Cloud saves section (Launcher.swift), remembered across launches. The Mac app chooses the
// same folder in its settings window. The host brings the save in from there when the game starts and
// sends it there after each save.
//
// iOS does not let an app remember a path outside its sandbox. It lets it keep a bookmark: the document
// picker grants access to the folder, and the bookmark resolves to it again after a relaunch. The
// bookmark is bound to the app's signing identity, so a re-signed build cannot resolve it, and the
// launcher asks the player to pick the folder again.

#import <Foundation/Foundation.h>

/// The picked folder, or nil when there is none or it no longer resolves. `stale` (optional) is set
/// when a bookmark exists but cannot be used under this signature.
NSString *dm_cloud_saves_path(BOOL *stale);

/// Store a bookmark for the folder the player just picked. Returns NO when the system refuses to make one.
BOOL dm_store_cloud_saves(NSURL *url);

/// Forget it: cloud saves off.
void dm_clear_cloud_saves(void);

/// Puts the picked folder into DM_SAVE_SYNC before the game starts (front_ios.m, at Play), its
/// security scope held for the session. A DM_SAVE_SYNC from an env file or the launch environment
/// wins. Turning cloud saves off in the launcher clears the one this set.
void dm_cloud_saves_env(void);

// ---- the NX 18 folder (F10, gate-ui §20-§21) ----
// One folder for the Profile and, when this game's mode is shared, its cloud saves (<NX 18>/<title ID>/save.dmsync, as cloud_path lays them out). A second bookmark
// beside the own folder's; both scopes may be held at once (a move, a Profile read), and only DM_SAVE_SYNC's folder stays held during play.

/// The NX 18 folder, or nil when none was chosen or it no longer resolves (`stale` set: "Choose your NX 18 folder again").
NSString *dm_nx18_folder_path(BOOL *stale);
/// Store a bookmark for the NX 18 folder just picked. NO when the system refuses one.
BOOL dm_store_nx18_folder(NSURL *url);
/// Forget it (and this game's shared mode).
void dm_clear_nx18_folder(void);
/// This game's cloud saves in the NX 18 folder (YES) or in its own folder (NO). dm_cloud_saves_env follows it.
BOOL dm_nx18_cloud_shared(void);
void dm_set_nx18_cloud_shared(BOOL shared);
