// See CloudSaves.h.

#import "CloudSaves.h"

static NSString *const kCloudSaves = @"cloudSavesBookmark";

// The folder's security scope, held from the first resolve on: the host writes there after every
// save. Not stopped while that folder stays picked (the process exits when the game does). Picking
// another folder, turning cloud saves off, or a bookmark that no longer resolves stops it, all in
// the launcher, before Play sets DM_SAVE_SYNC (dm_cloud_saves_env) and the host reads it. Every
// start that succeeded is matched by one stop. It used to be dropped without a stop when another
// folder was picked, and replaced by a URL never started when the same folder resolved again, so a
// started scope stayed taken for the rest of the run (a sandbox extension per folder change; no
// save was affected: the folder in use was always started).
// The NX 18 folder (F10, gate-ui §21.4) is a second bookmark, so up to two scopes are held: this game's own folder and the NX 18 folder. Both are held for a move
// (save_sync_move reads one and writes the other) and for a Profile read while this game's saves stay in its own folder. During play only the folder DM_SAVE_SYNC points at
// stays held: dm_cloud_saves_env stops the other before the game starts. Each start that succeeded is matched by one stop.
// held[slot] is the URL whose startAccessingSecurityScopedResource returned YES for that slot (0: own folder, 1: NX 18 folder), nil when none did.
static NSURL *held[2];

static void scope_slot(int slot, NSURL *url) {   // url: the folder this slot resolves to now, nil for none
    if (held[slot] && url && [held[slot].path isEqualToString:url.path]) return;   // already held: keep the URL that started it
    if (held[slot]) { [held[slot] stopAccessingSecurityScopedResource]; held[slot] = nil; }
    if (url && [url startAccessingSecurityScopedResource]) held[slot] = url;   // one that does not start is not held, and the next resolve tries again
}
static void scope_hold(NSURL *url) { scope_slot(0, url); }

static NSData *fresh_bookmark(NSURL *url) {
    // The picker grants a security scope that lasts while it is held: the bookmark is written with
    // the scope on. One written without it reads back on this run and resolves to nothing from the
    // next launch on.
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *bookmark = [url bookmarkDataWithOptions:0 includingResourceValuesForKeys:nil relativeToURL:nil error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    return bookmark;
}

NSString *dm_cloud_saves_path(BOOL *stale) {
    if (stale) *stale = NO;
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kCloudSaves];
    if (bookmark.length == 0) return nil;
    BOOL isStale = NO;
    NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&error];
    if (!url) {
        // A re-signed build gets a bookmark the system will not resolve for it. Keep the data, the
        // player may install the same signature again, and let the launcher ask for a new pick.
        fprintf(stderr, "boot: the picked cloud-save folder bookmark does not resolve (%s)\n", error.localizedDescription.UTF8String ?: "no reason given");
        scope_hold(nil);   // cloud saves are off now (no DM_SAVE_SYNC): a scope an earlier resolve started is stopped; a later resolve that works starts it again
        if (stale) *stale = YES;
        return nil;
    }
    scope_hold(url);   // held for the session (see held)
    if (isStale) {
        // The system still resolves it but asks for a rewrite. Same signature, so a fresh bookmark sticks.
        NSData *again = fresh_bookmark(url);
        if (again) [NSUserDefaults.standardUserDefaults setObject:again forKey:kCloudSaves];
        if (stale) *stale = YES;
    }
    return url.path;
}

BOOL dm_store_cloud_saves(NSURL *url) {
    NSData *bookmark = fresh_bookmark(url);
    NSError *error = nil;
    NSURL *back = nil;
    if (bookmark) back = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:nil error:&error];
    if (!bookmark || !back) {
        // A bookmark that cannot come back is not saved as if it were good.
        fprintf(stderr, "[RED] could not bookmark %s: %s\n", url.path.UTF8String ?: "?",
                error.localizedDescription.UTF8String ?: (bookmark ? "the bookmark does not resolve again" : "no bookmark data"));
        return NO;
    }
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kCloudSaves];
    fprintf(stderr, "launcher: cloud-save folder set to %s\n", url.path.UTF8String ?: "?");
    return YES;
}

void dm_clear_cloud_saves(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kCloudSaves];
    scope_hold(nil);
}

void dm_cloud_saves_env(void) {
    static BOOL fromPick;   // DM_SAVE_SYNC is the one this set, not an env file's
    if (getenv("DM_SAVE_SYNC") && !fromPick) return;
    BOOL stale = NO;
    NSString *folder = nil;
    if (dm_nx18_cloud_shared()) {   // this game's saves in the NX 18 folder: that folder's scope stays held, the own folder's goes
        folder = dm_nx18_folder_path(&stale);
        if (stale && !folder) fprintf(stderr, "boot: the NX 18 folder needs to be chosen again (the app is signed differently now); cloud saves use this game's own folder\n");
        if (folder) scope_slot(0, nil);
    }
    if (!folder) {
        folder = dm_cloud_saves_path(&stale);
        scope_slot(1, nil);   // the NX 18 folder is not where the game saves: its scope goes before the game starts
        if (stale && !folder) fprintf(stderr, "boot: the cloud-save folder needs to be chosen again (the app is signed differently now); cloud saves are off\n");
    }
    if (folder.length) {
        setenv("DM_SAVE_SYNC", folder.fileSystemRepresentation, 1); fromPick = YES;
        fprintf(stderr, "boot: cloud saves through %s\n", folder.fileSystemRepresentation);
    } else if (fromPick) { unsetenv("DM_SAVE_SYNC"); fromPick = NO; }
}

// ---- the NX 18 folder (F10, gate-ui §20-§21): a second bookmark, and this game's cloud mode ----
static NSString *const kNX18Folder = @"nx18.folder";   // the bookmark
static NSString *const kNX18Cloud = @"nx18.cloud";     // "shared": this game's cloud saves in the NX 18 folder; "own" (or none): its own folder
static NSString *const kNX18Captures = @"nx18.captures";   // "shared": this game's captures in the NX 18 folder; "own" (or none): Documents/Captures

NSString *dm_nx18_folder_path(BOOL *stale) {
    if (stale) *stale = NO;
    NSData *bookmark = [NSUserDefaults.standardUserDefaults dataForKey:kNX18Folder];
    if (bookmark.length == 0) return nil;
    BOOL isStale = NO; NSError *error = nil;
    NSURL *url = [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:&isStale error:&error];
    if (!url) {   // a re-signed build: the data stays (the same signature may come back), and the card says "Choose your NX 18 folder again"
        fprintf(stderr, "boot: the NX 18 folder bookmark does not resolve (%s)\n", error.localizedDescription.UTF8String ?: "no reason given");
        scope_slot(1, nil);
        if (stale) *stale = YES;
        return nil;
    }
    scope_slot(1, url);
    if (isStale) {
        NSData *again = fresh_bookmark(url);
        if (again) [NSUserDefaults.standardUserDefaults setObject:again forKey:kNX18Folder];
        if (stale) *stale = YES;
    }
    return url.path;
}

BOOL dm_store_nx18_folder(NSURL *url) {
    NSData *bookmark = fresh_bookmark(url);
    NSURL *back = bookmark ? [NSURL URLByResolvingBookmarkData:bookmark options:0 relativeToURL:nil bookmarkDataIsStale:nil error:nil] : nil;
    if (!bookmark || !back) { fprintf(stderr, "[RED] could not bookmark the NX 18 folder\n"); return NO; }
    [NSUserDefaults.standardUserDefaults setObject:bookmark forKey:kNX18Folder];
    fprintf(stderr, "launcher: NX 18 folder chosen\n");   // never its path: the folder's name may carry the player's name
    return YES;
}

void dm_clear_nx18_folder(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNX18Folder];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNX18Cloud];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:kNX18Captures];
    scope_slot(1, nil);
}

BOOL dm_nx18_cloud_shared(void) { return [[NSUserDefaults.standardUserDefaults stringForKey:kNX18Cloud] isEqualToString:@"shared"]; }
void dm_set_nx18_cloud_shared(BOOL shared) {
    [NSUserDefaults.standardUserDefaults setObject:shared ? @"shared" : @"own" forKey:kNX18Cloud];
    fprintf(stderr, "launcher: this game's cloud saves in %s\n", shared ? "the NX 18 folder" : "its own folder");
}
BOOL dm_nx18_captures_shared(void) { return [[NSUserDefaults.standardUserDefaults stringForKey:kNX18Captures] isEqualToString:@"shared"]; }
void dm_set_nx18_captures_shared(BOOL shared) {
    [NSUserDefaults.standardUserDefaults setObject:shared ? @"shared" : @"own" forKey:kNX18Captures];
    fprintf(stderr, "launcher: this game's captures in %s\n", shared ? "the NX 18 folder" : "its own folder");
}
