// The crash guard of the pipeline archive made offline and bundled with the app (nvn_mtl.m pso_bundle_open, DM_PSO_BUNDLE). A bundled archive of the device's own GPU family
// crashed Metal at boot on an iPhone Air with iOS 27.0, cause unknown (LNPANDY/NX2Apple#640), and such a game crashed at every start until it was rebuilt or the player set
// DM_PSO_BUNDLE=off. So before Metal first reads the archive, a start writes a record (pso_bundle_guard.tsv beside the device's own archive folder) that a start with this archive
// (its identity: file name, size, a digest of its first and last 64 KiB and the app's own build, nvn_mtl.m pso_bundle_identity) on this system build (kern.osversion) is under
// way, and it takes the record back once the start is past the danger window: PG_FRAMES frames presented after the prepare step ended and every compile of the prebuild returned
// (or the background prebuild ended), or PG_FRAMES_MAX frames when that does not come (no prewarm list, DM_PSO_MANIFEST=off, a compile that never returns). An iOS app usually
// ends killed, swiped away or by jetsam while suspended (hle_cheats.c keeps no unclean-exit marker on iOS for that reason), so while the app is away (in the background,
// dm_gfx_suspend; inactive, dm_gfx_inactive: the app switcher, from which a swipe kills it without a trip to the background; or in the host's graceful exit, dm_gfx_exiting, its
// first step) and at a clean exit, the record is as the start's end would leave it, and it is written again when the app is back: a record a start finds is a start that ended
// in the foreground before its window was over, a crash or a kill there.
// How many such starts in a row leave the archive out (need):
//   - 1 for most games, which had no archive before it became the default: #640's crash came at every start, so waiting for a second would only cost the player a second
//     crash, and a wrong verdict (an unrelated crash in the first seconds, iOS ending the app for memory in the foreground) leaves the game as it was before (no archive: one
//     on-device build of the bases, "Preparing pipelines", after which the device's own archive serves every start).
//   - 2 for a profile that sets pso_mtl4 on (DM_GAME_PSO_MTL4): such a game had its archive at every start, unguarded, and may need it (13 Sentinels: Aegis Rim on an A20 Pro
//     crashed without it, where is not known; Breath of the Wild's own build of the bases ran). One unrelated early end with the archive is then followed by another start with it, never by one without it.
// The start that leaves the archive out is watched too, and its outcome decides:
//   - past its window: the archive stays out for this archive, app build and system build (skip), start after start, so launches never alternate between crashing and not;
//   - not past its window either: the archive is not shown to be the cause, so the next start uses it again, watched as a first start.
// What it cannot tell: a start without the archive that crashes only after its window counts as past it. So a game that needs its archive and crashes late without it loses it
// (skip) after `need` unrelated early ends in a row with it; with need 2 that takes two in a row. Deleting the record, DM_PSO_BUNDLE_GUARD=0, another archive or host build, or
// an iOS update brings it back. An app rebuilt from the same inputs keeps its identity (the archive is reused, the linker's LC_UUID is a digest of its output), and so the record.
// The record's states, as the next start reads them (a record of another archive or system build, or one it cannot read, counts as none):
//   none     use the archive; written while watched: with
//   with     a start with it did not get past its window: need 1, leave it out ([RED]), written while watched: without; need 2, use it ([RED]), written while watched: with2
//   with2    two starts in a row with it did not (need 2): leave it out ([RED]); written while watched: without
//   without  the start without it did not get past its window either: use it ([RED]); written while watched: with
//   skip     a start without it got past its window after a start with it (two in a row with need 2) did not: leave it out ([RED]), not watched
// A watched start past its window writes: with, with2 -> none (the file goes), without -> skip. Away or at a clean exit it writes what was known before it (pg_left): with -> none,
// with2 -> with, without -> what it found (with or with2). The window is counted in presented frames, so a start that shows nothing (a hang the player ends from the app switcher)
// is no evidence either way. With DM_PSO_PREPARE=0 (the prewarm and prebuild in the background, a diagnostic) PG_FRAMES_MAX can end the window before a long prebuild does.
// The record serves one process at a time, as on iOS: two processes of the app sharing it (the Mac, where the guard is off unless DM_PSO_BUNDLE_GUARD=1) can read each other's
// start under way as one that ended. Plain C (stdio, POSIX files, pthread, C11 atomics), so dm/gfx/tests/t_pso_guard.c runs it on any machine; nvn_mtl.m does the logging, the
// paths and the archive's identity
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

enum { PG_NONE, PG_WITH, PG_WITH2, PG_WITHOUT, PG_SKIP, PG_STATES };
static const char *const pg_name[PG_STATES] = {"none", "with", "with2", "without", "skip"};
enum { PG_AWAY_BACKGROUND = 1, PG_AWAY_INACTIVE = 2, PG_AWAY_EXIT = 4 };   // why the app is away (pg_away): dm_gfx_suspend, dm_gfx_inactive, dm_gfx_exiting
#ifndef PG_FRAMES
#define PG_FRAMES 300        // frames presented after the prepare step and the prebuild ended: 5 s at 60 fps (the game's first frames draw with the archive's bases)
#endif
#ifndef PG_FRAMES_MAX
#define PG_FRAMES_MAX 1800   // frames presented without that end (no prewarm list, DM_PSO_MANIFEST=off, a compile that never returns): 30 s at 60 fps
#endif
#define PG_UNMARKED UINT32_MAX
// need: how many starts in a row with the archive that end early leave it out (1 or 2, pg_begin); found: the record this start read; armed: the state it keeps written while
// watched (PG_WITH, PG_WITH2 or PG_WITHOUT; PG_NONE: not watched); away: PG_AWAY_* bits (kept across pg_begin: an app away when the archive opens writes the record as the
// start's end would); err: errno of a record that could not be written (the guard then does not watch). watching: armed, read by the present path without the lock; mark_at: the
// frame count when the prepare step and the prebuild ended (PG_UNMARKED before); due: pg_frame reported the end of the window; frames: presents while watched
typedef struct {
    pthread_mutex_t mu;
    char path[1024], os[64], arch[512];
    int need, found, armed, away, err;
    _Atomic int watching, due;
    _Atomic uint32_t frames, mark_at;
} pg_guard;
#define PG_GUARD_INIT {.mu = PTHREAD_MUTEX_INITIALIZER, .need = 1, .mark_at = PG_UNMARKED}

// The state a record's text holds for this archive and system build (lines "state\t<name>", "os\t<build>", "archive\t<identity>"; # comments), PG_NONE for another one or none
static inline int pg_parse(const char *txt, const char *os, const char *arch) {
    int st = PG_NONE, os_ok = 0, arch_ok = 0;
    for (const char *l = txt; l && *l;) {
        const char *e = strchr(l, '\n'); size_t n = e ? (size_t)(e - l) : strlen(l);
        const char *tab = memchr(l, '\t', n);
        if (*l != '#' && tab) {
            size_t k = (size_t)(tab - l), vn = n - k - 1; const char *v = tab + 1;
            if (k == 5 && !memcmp(l, "state", 5)) { st = PG_NONE; for (int i = PG_WITH; i < PG_STATES; i++) if (strlen(pg_name[i]) == vn && !memcmp(v, pg_name[i], vn)) st = i; }
            else if (k == 2 && !memcmp(l, "os", 2)) os_ok = strlen(os) == vn && !memcmp(v, os, vn);
            else if (k == 7 && !memcmp(l, "archive", 7)) arch_ok = strlen(arch) == vn && !memcmp(v, arch, vn);
        }
        l = e ? e + 1 : NULL;
    }
    return os_ok && arch_ok && *os && *arch ? st : PG_NONE;
}
static inline int pg_format(char *buf, size_t n, int st, const char *os, const char *arch) {
    return snprintf(buf, n, "# the crash guard of the pipeline archive bundled with the app (nvn_mtl.m, nvn_pso_guard.h): delete this file to try the archive again\n"
                    "state\t%s\nos\t%s\narchive\t%s\n", pg_name[st], os, arch);
}
// The record as state st leaves it (PG_NONE: no file), written whole or not at all (a temporary file renamed over it). 0, or an errno
static inline int pg_store(const pg_guard *g, int st) {
    if (st == PG_NONE) return unlink(g->path) && errno != ENOENT ? errno : 0;
    char buf[2048], tmp[1100]; int n = pg_format(buf, sizeof buf, st, g->os, g->arch);
    if (n < 0 || (size_t)n >= sizeof buf || snprintf(tmp, sizeof tmp, "%s.tmp", g->path) >= (int)sizeof tmp) return ENAMETOOLONG;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) return errno;
    ssize_t w = write(fd, buf, (size_t)n);
    int err = w == n ? 0 : w < 0 ? errno : EIO;
    if (close(fd) && !err) err = errno;
    if (!err && rename(tmp, g->path)) err = errno;
    if (err) unlink(tmp);
    return err;
}
static inline int pg_load(const pg_guard *g) {
    char buf[4096]; FILE *f = fopen(g->path, "r"); if (!f) return PG_NONE;
    size_t n = fread(buf, 1, sizeof buf - 1, f); fclose(f); buf[n] = 0;
    return pg_parse(buf, g->os, g->arch);
}
// What a start does for the record it found: use the archive or not, and the state it keeps written while watched (PG_NONE: not watched)
static inline int pg_use(int found, int need) { return found == PG_NONE || found == PG_WITHOUT || (found == PG_WITH && need > 1); }
static inline int pg_arm(int found, int need) {
    switch (found) {
    case PG_NONE: case PG_WITHOUT: return PG_WITH;
    case PG_WITH: return need > 1 ? PG_WITH2 : PG_WITHOUT;
    case PG_WITH2: return PG_WITHOUT;
    default: return PG_NONE;   // PG_SKIP
    }
}
static inline int pg_after(int armed) { return armed == PG_WITHOUT ? PG_SKIP : PG_NONE; }   // what a watched start past its window leaves
// What one away or at a clean exit leaves: what was known before it, since its end is no evidence either way (after a start without the archive that ended early as well: none,
// the archive not shown to be the cause)
static inline int pg_left(int armed, int found) { return armed == PG_WITH2 ? PG_WITH : armed == PG_WITHOUT ? found : PG_NONE; }
// The start's verdict, copied under the lock (the background hook may write the guard meanwhile): use the archive or not; the record it found; the state it keeps written while
// watched (PG_NONE: not watched); the errno of a record it could not write (then not watched: the record stays as found, and so does every later start's verdict until it can be)
typedef struct { int use, found, armed, err; } pg_start;
// Before the archive is first used. need: how many starts in a row with it that end early leave it out (1, or 2 for a game that may need it)
static inline pg_start pg_begin(pg_guard *g, const char *path, const char *os, const char *arch, int need) {
    pthread_mutex_lock(&g->mu);
    snprintf(g->path, sizeof g->path, "%s", path); snprintf(g->os, sizeof g->os, "%s", os); snprintf(g->arch, sizeof g->arch, "%s", arch);
    g->need = need > 1 ? 2 : 1; g->found = pg_load(g); g->armed = PG_NONE; g->err = 0;
    atomic_store(&g->mark_at, PG_UNMARKED); atomic_store(&g->due, 0); atomic_store(&g->frames, 0);
    int arm = pg_arm(g->found, g->need);
    if (arm != PG_NONE) { g->err = pg_store(g, g->away ? pg_left(arm, g->found) : arm); if (!g->err) g->armed = arm; }
    atomic_store(&g->watching, g->armed != PG_NONE);
    pg_start r = {pg_use(g->found, g->need), g->found, g->armed, g->err};
    pthread_mutex_unlock(&g->mu);
    return r;
}
// The archive was not opened after all (Metal refused it): nothing of it ran, so the start is no evidence either way and the record goes back to what the start found
static inline void pg_unused(pg_guard *g) {
    pthread_mutex_lock(&g->mu);
    if (g->armed == PG_WITH || g->armed == PG_WITH2) { g->err = pg_store(g, g->found); g->armed = PG_NONE; atomic_store(&g->watching, 0); }
    pthread_mutex_unlock(&g->mu);
}
// The prepare step and its prebuild, or the background prebuild, ended: the window ends PG_FRAMES frames from here (the first call counts)
static inline void pg_mark(pg_guard *g) { uint32_t un = PG_UNMARKED; atomic_compare_exchange_strong(&g->mark_at, &un, atomic_load(&g->frames)); }
// A frame presented while watched: 1 once, when it ends the window (the caller then calls pg_pass, off the present path)
static inline int pg_frame(pg_guard *g) {
    uint32_t n = atomic_fetch_add(&g->frames, 1) + 1, m = atomic_load(&g->mark_at);
    return ((m != PG_UNMARKED && n - m >= PG_FRAMES) || n >= PG_FRAMES_MAX) && !atomic_exchange(&g->due, 1);
}
// The start is past its window: the record as that leaves it. Returns the state it was watched in (PG_NONE: it was not), *err the errno of a record not written
static inline int pg_pass(pg_guard *g, int *err) {
    pthread_mutex_lock(&g->mu);
    int was = g->armed; *err = 0;
    if (was != PG_NONE) { *err = g->err = pg_store(g, pg_after(was)); g->armed = PG_NONE; atomic_store(&g->watching, 0); }
    pthread_mutex_unlock(&g->mu);
    return was;
}
// The app goes away (on 1) or comes back (0) for a reason (PG_AWAY_*): while any reason holds, the record is as the start's end would leave it, then as it was. Returns the state
// watched when the record was written, PG_NONE when nothing was (not watched, or away already / still away for another reason); *err the errno of a record not written
static inline int pg_away(pg_guard *g, int why, int on, int *err) {
    pthread_mutex_lock(&g->mu);
    int old = g->away != 0, was = PG_NONE; *err = 0;
    g->away = on ? g->away | why : g->away & ~why;
    if (g->armed != PG_NONE && old != (g->away != 0)) { was = g->armed; *err = g->err = pg_store(g, g->away ? pg_left(was, g->found) : was); }
    pthread_mutex_unlock(&g->mu);
    return was;
}
// A clean exit (atexit): the record as the start's end would leave it. trylock: another thread may hold the lock while the process exits
static inline void pg_exit(pg_guard *g) {
    if (pthread_mutex_trylock(&g->mu)) return;
    if (g->armed != PG_NONE) { pg_store(g, pg_left(g->armed, g->found)); g->armed = PG_NONE; atomic_store(&g->watching, 0); }
    pthread_mutex_unlock(&g->mu);
}
