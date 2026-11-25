// Saves through a cloud folder (iCloud Drive), so the Mac app and the iPhone app of one game play on from the same save. Off unless DM_SAVE_SYNC names the folder
// (each app's launcher sets the folder the player chose in its Cloud saves: dm/mac/launcher.c from the Mac settings window, CloudSaves.m on the iPhone; "icloud" is iCloud Drive/nxnative Saves).
// The folder holds one file per game, <folder>/<title ID>/save.dmsync (a folder named after the title ID is taken as the game's own): the committed save (DM_SAVE and DM_SAVE_device) packed into one file. iCloud replaces a file as a
// whole but syncs a folder file by file, and a save that is half one device's and half the other's is worse than either.
// When: the cloud's copy comes in at the game's first save mount (hle_fs.c, before the work directory is cloned from the committed save); the committed save goes out a few
// seconds after a Commit, on a thread of its own (the game never waits), and in play at least 3 minutes after the last send; at once when the in-game menu opens, when the game
// leaves focus (the iPhone's resign active, before a swipe in the app switcher; the Mac's window losing focus), when the app goes to the background (the iPhone; the Mac's
// minimized window), when the game ends (the graceful exit), and from the Mac launcher once the host has exited. The Commit
// itself is on disk when it returns: what waits is only the cloud's copy, which the next start's mount sends when it is behind.
// Which way: <DM_SAVE>.sync keeps the hash of the save last known to be the same here and in the cloud (base), and which cloud file that was (cloud). Only the cloud's changed: it
// comes in; only this one changed: it goes out; both changed (played on both without syncing in between, or the first sync of a device that has a save of its own): the start
// decides. A front end that asks the player (the Mac and iPhone launchers, from save_sync_report below) sets DM_SAVE_SYNC_CHOICE (save_sync.c, read_choice): with no choice, neither
// replaces the other, the game plays on with this device's and nothing is sent; with one, the chosen save wins. Without DM_SAVE_SYNC_CHOICE the newer one wins and the other is kept.
// Another folder picked is a first sync with it: a base kept for another cloud file counts only when this one holds that very save (a .sync an older build wrote names no cloud
// file, and its base counts as it did there, also for a folder picked before the game's first sync with this build). save_sync_report applies the same rule, so its conflict is
// the mount's. Only the start decides: a send replaces a cloud save only when it is no save, the one last synced, damaged (the file kept first), or the one the start chose
// against; a cloud that changed since (or that the start could not read) waits for the next start. A save the first mount finds to send goes then, also when it is the base,
// which the sender otherwise skips: the cloud has no file (a folder new to this device, or the file removed) or the folder changed. That push is kept in memory, not in
// <DM_SAVE>.sync: it goes from that start to the cloud as the mount found it (a cloud changed meanwhile is the next start's to compare), or from the Mac launcher after it when
// the cloud has no file, and a push that does not go out leaves the next start to decide again. A cloud file it cannot read (damaged, or a newer build's format) is replaced only
// by a save that differs from the base.
// Every save this replaces, here or in the cloud, is kept first in <DM_SAVE>-backups/<date> <side>; the newest 10 of each side stay.
#pragma once
#include <stddef.h>
#include <stdint.h>

#define SS_HASH 32   // hex digits of a save's hash: the first 16 bytes of a SHA-256

typedef struct {
    char hash[SS_HASH + 1];   // over the paths, the guest names and the contents, not the dates: the same save has the same hash on every device
    int64_t saved;            // the newest file's modification time (seconds since 1970): which of two changed saves is newer
    char title[24], device[64];
    int files;                // regular files; 0 = no save
    int64_t bytes;            // their contents' size: tells the player a new game's save from one with progress (save_sync_report)
} ss_meta;

// ---- the parts (dm/host/tests/t_save_sync.c calls them) ----
// The committed save as it is on disk (save, and save + "_device"). 0 on success; m->files == 0: no save yet
int ss_scan(const char *save, ss_meta *m);
// Packs the save into one file. 0 on success; m receives what was packed
int ss_pack(const char *save, const char *title, const char *out, ss_meta *m);
// Reads a packed save and checks all of it (the header, every entry, the hash, the end marker); with `into`, unpacks it there as into/save and into/save_device.
// 0 on success; a damaged or cut-off file, or a path that leaves the save, fails
int ss_read(const char *bundle, const char *into, ss_meta *m);
typedef enum { SS_KEEP, SS_PULL, SS_PUSH, SS_ASK } ss_way;
// Which way, from the three hashes ("" for none: no save here, no sync yet, nothing in the cloud). *both = both changed: then SS_ASK when a front end asks the
// player (`ask`), else the newer one by the times (the same time: this device's)
ss_way ss_decide(const char *local, const char *base, const char *remote, int64_t local_saved, int64_t remote_saved, int ask, int *both);
void ss_pacing_set(int quiet_ms, int gap_ms);   // the sender's quiet wait and gap (QUIET_MS, GAP_MS), for a test that cannot wait minutes
uint64_t ss_own_skips(void);                    // sends that found the cloud's file still this device's own last send, and did not read it again
uint64_t ss_passes(void);                       // the sender's passes (each clones and packs the save), for the tests

// ---- what a front end asks the player with (docs/frontends.md, The cloud saves folder) ----
// Before the start, the two saves as the game's first mount will compare them, in one line of key=value pairs (no newline):
//   sync=<0 off | 1 on> cloud=<1 read | 0 no save there (or a damaged file, which the mount replaces) | -1 not read within wait_ms>
//   local=<hash|-> saved=<secs> files=<n> size=<bytes> chash=<hash|-> csaved=<secs> cfiles=<n> csize=<bytes> cdevice=<model, e.g. iPhone17,1|-> sametitle=<0|1> conflict=<0|1> pull=<0|1>
// pull = a pull of the cloud's save did not finish (<save>.pull): what is in place may be half the cloud's, so conflict is 0; the start's mount puts this device's save back first
// conflict = both changed since the last sync (or this device has never synced with this cloud file and both have a save; a base kept for another folder's file counts for
// nothing, as at the mount): the case the front end shows both saves for and answers with
// DM_SAVE_SYNC_CHOICE=local:<chash> (local:none with no cloud save) or cloud:<chash>, both naming the cloud's save the player chose against; with no conflict it passes `ask`, and with cloud=-1 `offline` (the mount does not wait again).
// `save` is the committed save folder (DM_SAVE), `title` the title ID, `folder` the cloud folder as DM_SAVE_SYNC would name it (NULL: DM_SAVE_SYNC itself), and
// `wait_ms` how long the cloud's file may take to come (<= 0: as long as the mount waits). Blocks that long at most: call it off the main thread.
// 0 on success, -1 when the arguments do not fit or this device's save cannot be read
int save_sync_report(const char *save, const char *title, const char *folder, int wait_ms, char *out, size_t n);
// Moves this game's cloud save from one folder to another (gate-ui §21.4: the NX 18 folder and the game's own; folders as DM_SAVE_SYNC names them): fetches the save in `from`
// and checks it whole, stores it in `to` (when `to` has no save of this game, or by `how`), reads it back and compares the hash. Only then may the front end switch the folder.
// SS_MOVE_DONE: switch (also with no save to move, the same save there already, or SS_MOVE_USE_THERE); SS_MOVE_SAME: the same file, only the mode changes; SS_MOVE_ASK: `to`
// holds another save of this game (out: "from_saved=<secs> to_saved=<secs>"), ask the player and call again with SS_MOVE_REPLACE (the one there goes into <save>-backups first)
// or SS_MOVE_USE_THERE; SS_MOVE_FAIL: nothing switches (offline, not downloaded within wait_ms, or not read back). The old copy is never removed. Blocks: off the main thread
typedef enum { SS_MOVE_ASK_FIRST, SS_MOVE_REPLACE, SS_MOVE_USE_THERE } ss_move;
enum { SS_MOVE_FAIL = -1, SS_MOVE_DONE = 0, SS_MOVE_SAME = 1, SS_MOVE_ASK = 2 };
int save_sync_move(const char *save, const char *from, const char *to, const char *title, ss_move how, int wait_ms, char *out, size_t n);

// ---- the host ----
const char *dm_save_title(void);          // the title ID the cloud file is named after (hle_fs.c, from the game's profile): for a front end in the host's process (the iPhone launcher)
// The game's first save mount (hle_fs.c): puts back this device's save from a pull of the cloud's that did not finish (<save>.pull, whatever DM_SAVE_SYNC says), then
// brings the cloud's save in when it is the one to keep, and starts the sender. 0: the save may be mounted (whether or not the cloud's came in); -1: it may not, as this
// device's save could not be put back whole (the log says where it is; the next start tries again). A second mount gets the first's answer
int save_sync_mount(const char *save, const char *title);
void save_sync_committed(void);           // a Commit went through (hle_fs.c, under its locks: it only wakes the sender)
// In play the sender waits QUIET_MS after the last Commit and GAP_MS (3 minutes) after its last send (save_sync.c); these send at once, past both:
void save_sync_soon(const char *why);     // without waiting (the in-game menu opening, the game leaving focus or going to the background, the graceful exit): why is a static string for the log
int save_sync_flush(int timeout_ms);      // and waits (the iPhone app going to the background, the graceful exit): 1 = in step with the cloud, 0 = not (yet)
int save_sync_after_exit(const char *save, const char *title);   // the Mac launcher once the host has exited (a crash included): 1 = in step, 0 = not

// ---- what the platform provides (weak defaults in save_sync.c: plain file copies, which the Mac's iCloud Drive takes) ----
// Copies the cloud's file to a local one; the iPhone app goes through NSFileCoordinator, which downloads a file iCloud has only listed (SaveSync.m).
// 1 = copied, 0 = there is none, -1 = failed
int front_save_sync_fetch(const char *cloud, const char *local);
// Puts a local file at the cloud path, replacing the file there as a whole. 1 = done
int front_save_sync_store(const char *local, const char *cloud);
// Clones the committed save folder `dir` to `to` while no Commit can swap it (hle_fs.c takes its lock; the default, with no host running, does not need one). 0 on success
int dm_fs_clone_committed(const char *dir, const char *to);
