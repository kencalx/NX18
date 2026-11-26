// Cloud save sync unit test (takes seconds): dm/host/save_sync.c through hle_fs.c's own save mount and Commit, with a plain folder standing in for iCloud Drive.
// Each device's game session runs in a child process (the host's sync state is once per process, as it is once per start of the app); the parent checks what each left
// in its save, its backups and the cloud. All expected values are written by hand from the semantics in save_sync.h:
//   (1) packing: a save with folders, a guest name and a device save comes back the same (contents, guest name, dates); the hash ignores dates and .DS_Store and sees contents;
//       a file cut short, a flipped byte, a byte too many and a path out of the save are refused
//   (2) ss_decide's table: both changed, the newer one wins; with a front end that asks, it asks, whatever the times say
//   (3) Mac A has a save and the cloud none: A's session sends it; iPhone B has none: B's session brings it in; B saves: the cloud has B's
//   (4) A starts again: only the cloud's changed: it comes in, and A's old save is kept in A's backups ("local")
//   (5) both changed, the cloud's newer, with a front end that asks (DM_SAVE_SYNC_CHOICE): B played without sync, A sent a newer save; B starts with sync and no
//       choice yet ("ask"): neither replaces the other; with the player's choice of the cloud's: A's comes in, B's is kept
//   (6) both changed, this one newer, with a front end that asks: A played without sync later than B sent; A starts with no choice yet, then with a choice made on
//       another cloud save: nothing is replaced; with the player's choice of this one: A's goes out, B's is kept in A's backups ("cloud")
//   (7) the Mac launcher's send after the host exited: a save the host committed and did not send goes out
//   (8) the game's own folder (<folder>/<title ID>) chosen as the folder
//   (9) a new backup removes the oldest of its side beyond 10, and leaves the other side's and the player's own folders
//   (10) the launcher's DM_SAVE with a trailing slash: the same <save>.sync as the host's
//   (11) the cloud cannot be read at the start (a download that does not come in time), and can when the game saves: the cloud's changed save is not replaced,
//        neither by the sender nor by the Mac launcher after the host; the player's "offline" choice with the cloud unreadable all along sends nothing
//   (12) the first play on a new Mac, the cloud's save not read at the start: the new save does not replace the cloud's progress; the next start, with a front end
//        that asks, asks; the player's choice of the cloud's brings it in and keeps the new one
//   (13) a damaged file in the cloud: no save to lose, this device's replaces it and the file is kept in the backups ("cloud")
//   (14) no front end asks: both changed, the newer one wins at the start (the cloud's: it comes in, this one is kept); the cloud not read at the start and this
//        device's save newer: not sent that session, the next start sends it and keeps the cloud's in the backups ("cloud")
//   (15) the report a front end reads before it plays; a pull's journal the start cannot put back stops the save mount
//   (16) a backup that cannot be made (the backups folder on another volume or full: rename fails with EXDEV, mkdir with ENOSPC, made so here) costs no older backup and
//        leaves no folder: a pull (this device's save stays as it was), the start's copy of the cloud's save it chose against, the damaged cloud file the sender keeps;
//        the next start that can keep it does, and only then removes the oldest of that side beyond 10
//   (17) another folder picked, with no save in it: the save in step with the first one goes there at the start (it did only once the game saved), with one log line
//   (18) another folder with an older save of another device's in it: the newer one wins (this one goes out, that one is kept), not "only the cloud's changed"
//   (19) the same folder again: its base still counts (only the cloud's changed: it comes in, though this device's date is newer)
//   (20) a <save>.sync an older build wrote (no cloud line): its base counts as it did, and the next sync writes the cloud line; with a folder new to it, the save goes out
//   (21) the cloud's file removed, the folder the same: the save goes back at the start
//   (22) the Mac launcher after a host that ended right after its save mount: what the mount found to send goes out
//   (23) another path whose file is the very save last in step (another spelling of the same folder): the base counts, and a save changed since goes out though it is older
//   (24) a cloud file it cannot read (a newer build's format) and the save last in step: neither the start nor the Mac launcher replaces it
//   (25) the save last in step with another folder, its push not gone out at the start: a flush later sends it to the cloud as the mount found it, and only so; another
//        device's save sent there meanwhile stays (that flush; the Mac launcher, or the flush, after a start that cannot read the cloud), and the next start compares the two
//   (26) a front end that asks after another folder was picked, this device's save still the one last in step with the other folder: the report (save_sync_report)
//        says conflict, as the mount sees it, so the launcher asks the player; an "ask" (it saw nothing to choose) replaces neither; the player's choice of this one sends
//        it and keeps the other device's in the backups ("cloud"), the player's choice of the cloud's brings it in and keeps this one ("local")
//   (27) the same, with this device's save changed since its last sync too: the report says conflict, an "ask" replaces neither, the player's later choice of this one,
//        the older, sends it and keeps the other device's in the backups ("cloud")
//   (28) the same folder through a link (another spelling of it): its base still counts, at the mount and in the report (only the cloud's changed: it comes in)
//   (29) the Mac launcher after a start that found the cloud in step, the cloud's file then not seen: it sends nothing, as the mount marked no push
//   (30) the sender's pacing in play (a short quiet wait and gap here, ss_pacing_set): the first send of a session goes after the quiet wait, the next only a gap after it;
//        the in-game menu (save_sync_soon) and a flush send at once; a send after the first finds the cloud's file still its own last send and does not read it again; a kill
//        right after a Commit leaves the local save whole and the cloud's at most one gap behind, and the next start finds only this one changed and sends it (no conflict)
//   (31) the cloud's file replaced by another device's after this device's send (a new file in its place): it is read again, and not replaced
//   (32) a quit through exit() (the Mac's ⌘Q) inside the gap: the save not sent yet goes before the process ends
//   (33) a flush while the send save_sync_soon started just before is under way (the background, the graceful exit, the quit): one pass, the flush waits for it; when that
//        send fails, the flush sends once more of its own
//   (34) another device's file put at the cloud path right after this device's store renamed its own there (iCloud between the rename and the identity's note): not
//        taken for this device's own, so the next send reads it and does not replace it
#include "../hle_fs.c"
#include <ctype.h>
#include <sys/wait.h>
#include <sys/time.h>
#include <sys/sysctl.h>

struct dm_flags g_flag; uint64_t g_t0_ns;
// (16): a rename into a path that holds g_rename_fail fails as across volumes (EXDEV), a mkdir of one that holds g_mkdir_fail as on a full disk (ENOSPC); every other
// call is the system's. save_sync.c is linked into this program, so its calls come here
static const char *g_rename_fail, *g_mkdir_fail;
// (33): a rename onto exactly g_store_to (the store's rename of its part file over the cloud's) takes g_store_us first (a slow store: a flush comes while the send is
// under way), and fails once as across volumes while g_store_fail_once is set. (34): once it went through, g_store_swap (another device's file) is renamed over it
static const char *g_store_to, *g_store_swap; static _Atomic int g_store_us, g_store_fail_once;
int rename(const char *from, const char *to) {
    if (g_rename_fail && strstr(to, g_rename_fail)) { errno = EXDEV; return -1; }
    if (g_store_to && !strcmp(to, g_store_to)) {
        if (g_store_us) usleep((useconds_t)g_store_us);
        if (atomic_exchange(&g_store_fail_once, 0)) { errno = EXDEV; return -1; }
        int r = renameat(AT_FDCWD, from, AT_FDCWD, to);
        if (!r && g_store_swap) { renameat(AT_FDCWD, g_store_swap, AT_FDCWD, to); g_store_swap = NULL; }
        return r;
    }
    return renameat(AT_FDCWD, from, AT_FDCWD, to);
}
int mkdir(const char *path, mode_t mode) {
    if (g_mkdir_fail && strstr(path, g_mkdir_fail)) { errno = ENOSPC; return -1; }
    return mkdirat(AT_FDCWD, path, mode);
}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
void dm_guest_write_prepare(void *a, size_t n) { (void)a; (void)n; }

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  ✗ "); } else printf("  ✓ "); printf(__VA_ARGS__); printf("\n"); fflush(stdout); } while (0)
static void put(const char *p, const char *s) { FILE *f = fopen(p, "w"); fputs(s, f); fclose(f); }
static int same(const char *p, const char *s) {
    char b[64] = {0}; FILE *f = fopen(p, "r"); if (!f) return 0; size_t k = fread(b, 1, sizeof b - 1, f); fclose(f);
    return k == strlen(s) && !memcmp(b, s, k);
}
static void mkd(const char *p) { char c[1200]; snprintf(c, sizeof c, "%s", p); for (char *s = c + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(c, 0755); *s = '/'; } mkdir(c, 0755); }
static void set_mtime(const char *p, time_t t) { struct timeval tv[2] = {{t, 0}, {t, 0}}; utimes(p, tv); }
static time_t mtime_of(const char *p) { struct stat st; return stat(p, &st) ? 0 : st.st_mtimespec.tv_sec; }
static int exists(const char *p) { return !access(p, F_OK); }
static int count_in(const char *p, const char *s) {   // how many times s is in the file (-1: no file)
    static char b[1 << 16]; FILE *f = fopen(p, "r"); if (!f) return -1; size_t k = fread(b, 1, sizeof b - 1, f); fclose(f); b[k] = 0;
    int n = 0; for (const char *q = b; (q = strstr(q, s)); q += strlen(s)) n++;
    return n;
}

// The newest backup of a save whose name ends in " <side>", "" when there is none
static void backup_of(const char *save, const char *side, char *out, size_t n) {
    char dir[1200]; snprintf(dir, sizeof dir, "%s-backups", save); out[0] = 0;
    DIR *d = opendir(dir); struct dirent *e; char best[256] = "";
    size_t sl = strlen(side);
    while (d && (e = readdir(d))) { size_t l = strlen(e->d_name); if (l > sl && e->d_name[l - sl - 1] == ' ' && !strcmp(e->d_name + l - sl, side) && strcmp(e->d_name, best) > 0) strlcpy(best, e->d_name, sizeof best); }
    if (d) closedir(d);
    if (*best) snprintf(out, n, "%s/%s", dir, best);
}
// Whether any backup of a save's `side` ("<date> <side>", or with " <k>" after it: more than one in a second) holds rel (under the backup folder) with that value
static int kept_at(const char *save, const char *side, const char *rel, const char *value) {
    char dir[1200], p[1600]; snprintf(dir, sizeof dir, "%s-backups", save);
    DIR *d = opendir(dir); struct dirent *e; int found = 0; size_t sl = strlen(side);
    while (d && !found && (e = readdir(d))) {   // the date is 19 characters
        const char *n = e->d_name;
        if (strlen(n) < 20 + sl || n[19] != ' ' || strncmp(n + 20, side, sl) || (n[20 + sl] && n[20 + sl] != ' ')) continue;
        snprintf(p, sizeof p, "%s/%s/%s", dir, n, rel); found = same(p, value);
    }
    if (d) closedir(d);
    return found;
}
static int kept(const char *save, const char *side, const char *file, const char *value) { char rel[300]; snprintf(rel, sizeof rel, "save/%s", file); return kept_at(save, side, rel, value); }
// What the cloud holds of the game file, unpacked into a folder of its own
static int cloud_has(const char *cloud_file, const char *root, const char *file, const char *value) {
    static int k; char into[1200], p[1400]; ss_meta m;
    snprintf(into, sizeof into, "%s/peek%d-%d", root, (int)getpid(), k++); mkd(into);   // the pid: a session's child peeks too ((30)), with the counter it was forked with
    if (ss_read(cloud_file, into, &m)) return 0;
    snprintf(p, sizeof p, "%s/save/%s", into, file); return same(p, value);
}

static Result write_save(const char *path, const char *s) {           // create -> open -> set size -> write -> close, as a game does
    uint64_t h; h_fs_CreateFile(path, 0); Result r = h_fs_OpenFile(&h, path, MODE_WRITE); if (r) return r;
    h_fs_SetFileSize(h, (int64_t)strlen(s));
    r = h_fs_WriteFile(h, 0, s, strlen(s), NULL); h_fs_CloseFile(h); return r;
}

static const char *g_log;   // set: a session's stderr (the save sync's lines) goes to this file
static void pass_on(const char *p) {   // and then on to this one's stderr, where a sanitizer build's reports are read
    static char b[1 << 16]; FILE *f = fopen(p, "r"); if (!f) return; size_t k = fread(b, 1, sizeof b, f); fclose(f); fwrite(b, 1, k, stderr);
}
enum { NOT_SENT = 64 };   // run(): the flush did not leave the save in step with the cloud
enum { READABLE, LATE, UNREADABLE };   // run(): the cloud's file all along, only after the save mount (a download that did not come in time), never
// One start of the game on a device: the save mount (the cloud's save comes in), then, with a file, the game writing it and committing, then a flush (the iPhone app
// going to the background). cloud NULL: sync off; choice: DM_SAVE_SYNC_CHOICE; cf: the cloud's file, made unreadable as `reach` says.
// Returns the child's failed steps, plus NOT_SENT when the flush did not leave the save in step with the cloud
static int run(const char *save, const char *cloud, const char *file, const char *value, const char *choice, const char *cf, int reach) {
    fflush(stdout); fflush(stderr);
    if (reach != READABLE) chmod(cf, 0);
    pid_t p = fork();
    if (!p) {
        if (g_log) { int fd = open(g_log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0 && fd != STDERR_FILENO) { dup2(fd, STDERR_FILENO); close(fd); } }
        setenv("DM_SAVE", save, 1);
        if (cloud) setenv("DM_SAVE_SYNC", cloud, 1); else unsetenv("DM_SAVE_SYNC");
        if (choice) setenv("DM_SAVE_SYNC_CHOICE", choice, 1); else unsetenv("DM_SAVE_SYNC_CHOICE");
        int bad = h_fs_MountSave("save", NULL) != RES_OK;
        if (reach == LATE) chmod(cf, 0644);
        if (file) { char gp[256]; snprintf(gp, sizeof gp, "save:/%s", file); bad += write_save(gp, value) != RES_OK; bad += h_fs_Commit("save") != RES_OK; }
        if (cloud && save_sync_flush(10000) != 1) bad += NOT_SENT;
        fflush(stdout); fflush(stderr); _exit(bad);
    }
    int st; waitpid(p, &st, 0);
    if (reach != READABLE) chmod(cf, 0644);
    return WIFEXITED(st) ? WEXITSTATUS(st) : 99;
}
static int session(const char *save, const char *cloud, const char *file, const char *value) { return run(save, cloud, file, value, NULL, NULL, READABLE); }
// DM_SAVE_SYNC_CHOICE for the cloud's save as it is now: "<side>:<its hash>"
static const char *choice_of(const char *side, const char *cf) {
    static char c[64]; ss_meta m;
    if (ss_read(cf, NULL, &m)) snprintf(c, sizeof c, "%s:none", side); else snprintf(c, sizeof c, "%s:%s", side, m.hash);
    return c;
}
static int backups(const char *save, const char *side) {   // how many backups of that side ("<date> <side>", or with " <k>" after it: more than one in a second)
    char dir[1200]; snprintf(dir, sizeof dir, "%s-backups", save);
    int k = 0; DIR *d = opendir(dir); struct dirent *e; size_t sl = strlen(side);
    while (d && (e = readdir(d))) { const char *n = e->d_name; k += strlen(n) >= 20 + sl && n[19] == ' ' && !strncmp(n + 20, side, sl) && (!n[20 + sl] || n[20 + sl] == ' '); }
    if (d) closedir(d);
    return k;
}

// A start that ends right after the save mount (a crash, a quit before the game saves): the sender may not have sent yet
static int mount_only(const char *save, const char *cloud) {
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (!p) { setenv("DM_SAVE", save, 1); setenv("DM_SAVE_SYNC", cloud, 1); _exit(h_fs_MountSave("save", NULL) != RES_OK); }
    int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 99;
}

// A start that stops after its save mount and a first flush (*first: its result) until resume(): the iPhone app in the background, then back and going to the
// background again. -1: no child
static pid_t start_paused(const char *save, const char *cloud, int *go, int *first) {
    int up[2], down[2]; *first = -1;
    if (pipe(up)) return -1;
    if (pipe(down)) { close(up[0]); close(up[1]); return -1; }
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (!p) {
        if (g_log) { int fd = open(g_log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0 && fd != STDERR_FILENO) { dup2(fd, STDERR_FILENO); close(fd); } }
        setenv("DM_SAVE", save, 1); setenv("DM_SAVE_SYNC", cloud, 1);
        char r = h_fs_MountSave("save", NULL) != RES_OK ? 'x' : (char)('0' + save_sync_flush(10000)), c;
        fflush(stderr);
        if (write(up[1], &r, 1) != 1 || read(down[0], &c, 1) != 1) _exit(98);
        int bad = save_sync_flush(10000) != 1;
        fflush(stdout); fflush(stderr); _exit(bad);
    }
    close(up[1]); close(down[0]);
    char r = 'x';
    if (p < 0 || read(up[0], &r, 1) != 1) r = 'x';
    close(up[0]);
    if (p < 0) { close(down[1]); return -1; }
    *first = r == 'x' ? -1 : r - '0'; *go = down[1]; return p;
}
static int resume(pid_t p, int go) {   // the child's second flush: 0 = it said in step
    int w = (int)write(go, "g", 1); close(go);
    int st; waitpid(p, &st, 0); return w != 1 ? 98 : WIFEXITED(st) ? WEXITSTATUS(st) : 99;
}

// (30): poll the cloud's file until it holds the game file's value, for up to ms; the time it was seen (monotonic ns), 0 when it never was
static uint64_t seen_at(const char *cf, const char *root, const char *value, int ms) {
    for (uint64_t end = now_ns() + (uint64_t)ms * 1000000ull; ; usleep(20000)) {
        if (cloud_has(cf, root, "game.dat", value)) return now_ns();
        if (now_ns() >= end) return 0;
    }
}
enum { PACE_GAP_MS = 3000 };
// (30): one start of the game played for a while with the sender's pacing at a short quiet wait and PACE_GAP_MS: each step that fails sets a bit of the exit code
static int paced(const char *save, const char *cloud, const char *cf, const char *root) {
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (!p) {
        if (g_log) { int fd = open(g_log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0 && fd != STDERR_FILENO) { dup2(fd, STDERR_FILENO); close(fd); } }
        setenv("DM_SAVE", save, 1); setenv("DM_SAVE_SYNC", cloud, 1); unsetenv("DM_SAVE_SYNC_CHOICE");
        ss_pacing_set(100, PACE_GAP_MS);
        int bad = h_fs_MountSave("save", NULL) != RES_OK;
        bad |= (write_save("save:/game.dat", "p1") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        uint64_t t1 = seen_at(cf, root, "p1", 5000);
        bad |= !t1 << 2;   // the session's first send: after the quiet wait, no gap
        bad |= (write_save("save:/game.dat", "p2") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        usleep(1000000);
        bad |= !cloud_has(cf, root, "game.dat", "p1") << 3;   // quiet long since, the gap not over: still the first send's
        uint64_t t2 = seen_at(cf, root, "p2", PACE_GAP_MS + 5000);
        bad |= (!t2 || t2 - t1 + 300000000ull < (uint64_t)PACE_GAP_MS * 1000000ull) << 4;   // the gap after the first send, not sooner
        uint64_t sk = ss_own_skips();
        bad |= (write_save("save:/game.dat", "p3") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        uint64_t t3a = now_ns(); save_sync_soon("the in-game menu opened");
        uint64_t t3 = seen_at(cf, root, "p3", 2000);
        bad |= (!t3 || t3 - t3a > 1500000000ull) << 5;   // the in-game menu: at once, well inside the gap
        bad |= (write_save("save:/game.dat", "p4") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        bad |= (save_sync_flush(5000) != 1 || !cloud_has(cf, root, "game.dat", "p4")) << 6;   // the background's flush: at once
        bad |= (ss_own_skips() - sk != 2) << 7;   // both found the cloud's file this device's own and did not read it again
        bad |= (write_save("save:/game.dat", "p5") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        fflush(stdout); fflush(stderr); _exit(bad);   // killed right after the Commit, inside the gap
    }
    int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}
// (31): this device sends q1, another device's save replaces the cloud's file (a new file, as iCloud puts one there), this device commits q2 and flushes. Exit code bits
static int replaced(const char *save, const char *cloud, const char *cf, const char *root, const char *theirs) {
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (!p) {
        if (g_log) { int fd = open(g_log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0 && fd != STDERR_FILENO) { dup2(fd, STDERR_FILENO); close(fd); } }
        setenv("DM_SAVE", save, 1); setenv("DM_SAVE_SYNC", cloud, 1); unsetenv("DM_SAVE_SYNC_CHOICE");
        ss_pacing_set(100, 0);
        int bad = h_fs_MountSave("save", NULL) != RES_OK;
        bad |= (write_save("save:/game.dat", "q1") != RES_OK || h_fs_Commit("save") != RES_OK || save_sync_flush(5000) != 1 || !cloud_has(cf, root, "game.dat", "q1")) << 1;
        char part[1500]; ss_meta m; snprintf(part, sizeof part, "%s.other", cf);
        bad |= (ss_pack(theirs, DM_GAME_ID, part, &m) || rename(part, cf)) << 2;
        uint64_t sk = ss_own_skips();
        bad |= (write_save("save:/game.dat", "q2") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        bad |= (save_sync_flush(5000) != 0) << 3;   // not in step: the next start decides
        bad |= (ss_own_skips() != sk) << 4;   // the new file was read
        fflush(stdout); fflush(stderr); _exit(bad);
    }
    int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}

// (32): a start that sends r1, commits r2 inside a long gap and quits through exit(), which runs the atexit handlers as ⌘Q does. Exit code bits
static int quit_in_gap(const char *save, const char *cloud, const char *cf, const char *root) {
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (!p) {
        if (g_log) { int fd = open(g_log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0 && fd != STDERR_FILENO) { dup2(fd, STDERR_FILENO); close(fd); } }
        setenv("DM_SAVE", save, 1); setenv("DM_SAVE_SYNC", cloud, 1); unsetenv("DM_SAVE_SYNC_CHOICE");
        ss_pacing_set(100, 600000);
        int bad = h_fs_MountSave("save", NULL) != RES_OK;
        bad |= (write_save("save:/game.dat", "r1") != RES_OK || h_fs_Commit("save") != RES_OK || !seen_at(cf, root, "r1", 5000)) << 1;
        bad |= (write_save("save:/game.dat", "r2") != RES_OK || h_fs_Commit("save") != RES_OK) << 2;
        usleep(300000);
        bad |= !cloud_has(cf, root, "game.dat", "r1") << 3;   // held by the gap
        fflush(stdout); fflush(stderr); exit(bad);
    }
    int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}

// (33): a start that sends s1, then commits s2 and s3 inside a long gap, each followed by save_sync_soon and, 100 ms later, while the slow store of the send it started
// is under way, a flush; the send for s3 fails once. Exit code bits
static int soon_then_flush(const char *save, const char *cloud, const char *cf, const char *root) {
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (!p) {
        if (g_log) { int fd = open(g_log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0 && fd != STDERR_FILENO) { dup2(fd, STDERR_FILENO); close(fd); } }
        setenv("DM_SAVE", save, 1); setenv("DM_SAVE_SYNC", cloud, 1); unsetenv("DM_SAVE_SYNC_CHOICE");
        ss_pacing_set(100, 600000);
        int bad = h_fs_MountSave("save", NULL) != RES_OK;
        bad |= (write_save("save:/game.dat", "s1") != RES_OK || h_fs_Commit("save") != RES_OK || !seen_at(cf, root, "s1", 5000)) << 1;
        g_store_to = cf; g_store_us = 400000;
        bad |= (write_save("save:/game.dat", "s2") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        uint64_t n0 = ss_passes();
        save_sync_soon("the game lost focus"); usleep(100000);
        bad |= (save_sync_flush(5000) != 1 || !cloud_has(cf, root, "game.dat", "s2")) << 2;
        bad |= (ss_passes() - n0 != 1) << 3;   // the flush waited for the send under way, and asked for no second pass
        bad |= (write_save("save:/game.dat", "s3") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        n0 = ss_passes(); g_store_fail_once = 1;
        save_sync_soon("the game lost focus"); usleep(100000);
        bad |= (save_sync_flush(5000) != 1 || !cloud_has(cf, root, "game.dat", "s3")) << 4;   // that send failed: the flush's own got there
        bad |= (ss_passes() - n0 != 2) << 5;
        g_store_to = NULL;
        fflush(stdout); fflush(stderr); _exit(bad);
    }
    int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}

// (34): a start that sends t1 (its identity noted), then t2, whose store is followed at once by another device's file renamed over it, then t3. Exit code bits
static int swapped_after_store(const char *save, const char *cloud, const char *cf, const char *root, const char *theirs) {
    fflush(stdout); fflush(stderr);
    pid_t p = fork();
    if (!p) {
        if (g_log) { int fd = open(g_log, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd >= 0 && fd != STDERR_FILENO) { dup2(fd, STDERR_FILENO); close(fd); } }
        setenv("DM_SAVE", save, 1); setenv("DM_SAVE_SYNC", cloud, 1); unsetenv("DM_SAVE_SYNC_CHOICE");
        ss_pacing_set(100, 0);
        int bad = h_fs_MountSave("save", NULL) != RES_OK;
        bad |= (write_save("save:/game.dat", "t1") != RES_OK || h_fs_Commit("save") != RES_OK || save_sync_flush(5000) != 1 || !cloud_has(cf, root, "game.dat", "t1")) << 1;
        static char part[1500]; ss_meta m; snprintf(part, sizeof part, "%s.other", cf);
        bad |= ss_pack(theirs, DM_GAME_ID, part, &m) << 2;
        g_store_to = cf; g_store_swap = part;
        bad |= (write_save("save:/game.dat", "t2") != RES_OK || h_fs_Commit("save") != RES_OK || save_sync_flush(5000) != 1) << 3;   // stored, as far as this device knows
        bad |= (g_store_swap != NULL || !cloud_has(cf, root, "game.dat", "other")) << 4;   // and the other device's file took its place right after
        g_store_to = NULL;
        uint64_t sk = ss_own_skips();
        bad |= (write_save("save:/game.dat", "t3") != RES_OK || h_fs_Commit("save") != RES_OK) << 1;
        bad |= (save_sync_flush(5000) != 0) << 5;   // not in step: the next start decides
        bad |= (ss_own_skips() != sk) << 6;   // the file was read, not taken for this device's own
        fflush(stdout); fflush(stderr); _exit(bad);
    }
    int st; waitpid(p, &st, 0); return WIFEXITED(st) ? WEXITSTATUS(st) : 255;
}

int main(void) {
    char root[1024]; const char *sp = getenv("TMPDIR"); snprintf(root, sizeof root, "%s/t_save_sync.XXXXXX", sp ? sp : "/private/tmp");
    if (!mkdtemp(root)) { perror("mkdtemp"); return 1; }
    char p[1400], q[1400], u[1400], bundle[1400];
    ss_meta m, m2;

    printf("(1) packing\n");
    char P[1200]; snprintf(P, sizeof P, "%s/pack/save", root);
    snprintf(p, sizeof p, "%s/sub", P); mkd(p); snprintf(p, sizeof p, "%s/empty", P); mkd(p); snprintf(p, sizeof p, "%s_device", P); mkd(p);
    snprintf(p, sizeof p, "%s/a", P); put(p, "hello"); set_mtime(p, 1000000000);
    snprintf(p, sizeof p, "%s/sub/b", P); put(p, "xy"); setxattr(p, FS_GUEST_NAME, "B", 1, 0, XATTR_NOFOLLOW); set_mtime(p, 1000000100);
    snprintf(p, sizeof p, "%s/sub/.dm-case-1", P); put(p, "alias"); setxattr(p, FS_GUEST_NAME, "CaseFile", 8, 0, XATTR_NOFOLLOW); set_mtime(p, 1000000075);
    snprintf(p, sizeof p, "%s_device/d", P); put(p, "dev"); set_mtime(p, 1000000050);
    CHECK(!ss_scan(P, &m) && m.files == 4 && strlen(m.hash) == SS_HASH && m.saved == 1000000100, "scan: 4 files, a 32-digit hash, saved = the newest file's date (%d files, saved %lld)", m.files, (long long)m.saved);
    snprintf(bundle, sizeof bundle, "%s/pack/save.dmsync", root);
    CHECK(!ss_pack(P, "0100abc", bundle, &m2) && !strcmp(m2.hash, m.hash) && !strcmp(m2.title, "0100ABC"), "pack: the same hash as the scan, the title ID in capitals (%s)", m2.title);
    CHECK(!ss_read(bundle, NULL, &m2) && !strcmp(m2.hash, m.hash) && m2.files == 4 && m2.saved == 1000000100 && !strcmp(m2.title, "0100ABC") && m2.device[0], "read: hash, files, date, title and device come back (from %s)", m2.device);
    snprintf(u, sizeof u, "%s/pack/out", root); mkd(u);
    CHECK(!ss_read(bundle, u, &m2), "unpack");
    snprintf(p, sizeof p, "%s/save/a", u); snprintf(q, sizeof q, "%s/save/sub/b", u);
    char g[16] = {0}; ssize_t gl = getxattr(q, FS_GUEST_NAME, g, sizeof g - 1, 0, XATTR_NOFOLLOW);
    CHECK(same(p, "hello") && same(q, "xy") && gl == 1 && g[0] == 'B', "files and the guest name (hle_fs.c's FS_GUEST_NAME) come back");
    snprintf(q, sizeof q, "%s/save/sub/.dm-case-1", u);
    memset(g, 0, sizeof g); gl = getxattr(q, FS_GUEST_NAME, g, sizeof g - 1, 0, XATTR_NOFOLLOW);
    CHECK(same(q, "alias") && gl == 8 && !strcmp(g, "CaseFile"), "a .dm-case-1 alias round-trips its original guest name and contents");
    CHECK(mtime_of(p) == 1000000000, "a file's date comes back (%lld)", (long long)mtime_of(p));
    snprintf(p, sizeof p, "%s/save/empty", u); snprintf(q, sizeof q, "%s/save_device/d", u);
    struct stat st; CHECK(!stat(p, &st) && S_ISDIR(st.st_mode) && same(q, "dev"), "an empty folder and the device save come back");
    snprintf(p, sizeof p, "%s/save", u); CHECK(!ss_scan(p, &m2) && !strcmp(m2.hash, m.hash), "the unpacked save has the original's hash");
    snprintf(p, sizeof p, "%s/a", P); set_mtime(p, 1200000000);
    CHECK(!ss_scan(P, &m2) && !strcmp(m2.hash, m.hash) && m2.saved == 1200000000, "another date, the same hash (the date still says which is newer)");
    snprintf(p, sizeof p, "%s/.DS_Store", P); put(p, "finder");
    CHECK(!ss_scan(P, &m2) && !strcmp(m2.hash, m.hash), "Finder's .DS_Store is not part of the save");
    snprintf(p, sizeof p, "%s/a", P); put(p, "hellO");
    CHECK(!ss_scan(P, &m2) && strcmp(m2.hash, m.hash), "one changed byte, another hash");
    snprintf(p, sizeof p, "%s/pack/none", root); mkd(p);
    CHECK(!ss_scan(p, &m2) && !m2.files && !m2.hash[0], "an empty folder is no save: no files, no hash");
    {   FILE *f = fopen(bundle, "rb"); fseek(f, 0, SEEK_END); long n = ftell(f); rewind(f); char *b = malloc((size_t)n + 1); fread(b, 1, (size_t)n, f); fclose(f);
        snprintf(p, sizeof p, "%s/pack/bad.dmsync", root);
        f = fopen(p, "wb"); fwrite(b, 1, (size_t)n - 1, f); fclose(f); CHECK(ss_read(p, NULL, &m2) && !m2.files, "a file cut short by one byte is refused");
        f = fopen(p, "wb"); fwrite(b, 1, (size_t)n, f); fputc(0, f); fclose(f); CHECK(ss_read(p, NULL, &m2), "a byte too many is refused");
        b[n - 12] ^= 1; f = fopen(p, "wb"); fwrite(b, 1, (size_t)n, f); fclose(f); CHECK(ss_read(p, NULL, &m2), "a flipped byte in the contents is refused (the hash)");
        free(b);
    }
    {   // one entry, save/../escaped, in an otherwise well-formed file
        uint8_t hdr[144] = {0}, h[24] = {2}; uint32_t one = 1, n = 1; uint16_t pl = 15; uint64_t sz = 1;
        memcpy(hdr, "DMSYNC1\n", 8); memcpy(hdr + 8, &one, 4); memcpy(hdr + 12, &n, 4); memcpy(h + 2, &pl, 2); memcpy(h + 8, &sz, 8);
        snprintf(p, sizeof p, "%s/pack/escape.dmsync", root); FILE *f = fopen(p, "wb");
        fwrite(hdr, 1, sizeof hdr, f); fwrite(h, 1, sizeof h, f); fwrite("save/../escaped", 1, 15, f); fputc('z', f); fwrite("DMSYNCE\n", 1, 8, f); fclose(f);
        snprintf(u, sizeof u, "%s/pack/esc/in", root); mkd(u); snprintf(q, sizeof q, "%s/pack/esc/in/escaped", root);
        char q2[1400]; snprintf(q2, sizeof q2, "%s/pack/esc/escaped", root);
        CHECK(ss_read(p, u, &m2) && !exists(q) && !exists(q2), "a path that leaves the save is refused, and nothing is written");
    }

    printf("(2) which way\n");
    int both;
    CHECK(ss_decide("", "", "", 0, 0, 0, &both) == SS_KEEP && !both, "no save anywhere: keep");
    CHECK(ss_decide("L", "", "", 0, 0, 0, &both) == SS_PUSH && !both, "nothing in the cloud: send");
    CHECK(ss_decide("", "", "R", 0, 0, 0, &both) == SS_PULL && !both, "nothing here: bring in");
    CHECK(ss_decide("X", "B", "X", 0, 0, 0, &both) == SS_KEEP && !both, "the same here and in the cloud: keep");
    CHECK(ss_decide("B", "B", "R", 9, 1, 0, &both) == SS_PULL && !both, "only the cloud's changed: bring in, even with an older date");
    CHECK(ss_decide("L", "B", "B", 1, 9, 0, &both) == SS_PUSH && !both, "only this one changed: send, even with an older date");
    CHECK(ss_decide("L", "B", "R", 10, 20, 0, &both) == SS_PULL && both, "both changed, the cloud's newer: bring in");
    CHECK(ss_decide("L", "B", "R", 20, 10, 0, &both) == SS_PUSH && both, "both changed, this one newer: send");
    CHECK(ss_decide("L", "", "R", 20, 10, 0, &both) == SS_PUSH && both, "a first sync with a save of its own counts as both changed");
    CHECK(ss_decide("L", "B", "R", 10, 10, 0, &both) == SS_PUSH && both, "the same date: this device's is kept");
    CHECK(ss_decide("L", "B", "R", 10, 20, 1, &both) == SS_ASK && both, "a front end asks: both changed, the cloud's newer: ask");
    CHECK(ss_decide("L", "B", "R", 20, 10, 1, &both) == SS_ASK && both, "a front end asks: both changed, this one newer: ask");
    CHECK(ss_decide("L", "", "R", 20, 10, 1, &both) == SS_ASK && both, "a front end asks: a first sync with a save of its own: ask");
    CHECK(ss_decide("B", "B", "R", 9, 1, 1, &both) == SS_PULL && !both, "a front end asks: only the cloud's changed still comes in");

    char A[1200], B[1200], cloud[1200], cf[1400], id[24], back[1400];
    snprintf(A, sizeof A, "%s/mac/save", root); snprintf(B, sizeof B, "%s/iphone/save", root); snprintf(cloud, sizeof cloud, "%s/iCloud Drive/nxnative Saves", root);
    mkd(A); mkd(B); mkd(cloud);
    for (size_t i = 0; i <= strlen(DM_GAME_ID); i++) id[i] = (char)toupper((unsigned char)DM_GAME_ID[i]);
    snprintf(cf, sizeof cf, "%s/%s/save.dmsync", cloud, id);

    printf("(3) Mac -> cloud -> iPhone\n");
    snprintf(p, sizeof p, "%s/game.dat", A); put(p, "v1");
    CHECK(session(A, cloud, NULL, NULL) == 0 && cloud_has(cf, root, "game.dat", "v1"), "the Mac's first session with sync sends its save");
    snprintf(p, sizeof p, "%s.sync", A); CHECK(exists(p), "and remembers it as in step (%s)", p);
    snprintf(p, sizeof p, "%s.sync-tmp", A); CHECK(!exists(p), "nothing is left beside the save");
    snprintf(p, sizeof p, "%s/game.dat", B);
    CHECK(session(B, cloud, NULL, NULL) == 0 && same(p, "v1"), "the iPhone's first session brings it in");
    snprintf(q, sizeof q, "%s-backups", B); CHECK(!exists(q), "with no save of its own, the iPhone keeps no backup");
    CHECK(session(B, cloud, "game.dat", "v2") == 0 && cloud_has(cf, root, "game.dat", "v2"), "the iPhone saves: the cloud has its save");

    printf("(4) the cloud's changed\n");
    snprintf(p, sizeof p, "%s/game.dat", A);
    CHECK(session(A, cloud, NULL, NULL) == 0 && same(p, "v2"), "the Mac starts again: the iPhone's save comes in");
    backup_of(A, "local", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "v1"), "the Mac's old save is kept (%s)", back);

    printf("(5) both changed, the cloud's newer\n");
    snprintf(p, sizeof p, "%s/game.dat", B);
    CHECK(session(B, NULL, "game.dat", "v4") == 0 && same(p, "v4"), "the iPhone plays with sync off");
    set_mtime(p, time(NULL) - 100);
    CHECK(session(A, cloud, "game.dat", "v5") == 0 && cloud_has(cf, root, "game.dat", "v5"), "then the Mac saves and sends");
    CHECK(run(B, cloud, NULL, NULL, "ask", NULL, READABLE) == NOT_SENT && same(p, "v4") && cloud_has(cf, root, "game.dat", "v5") && !backups(B, "local") && !backups(B, "cloud"),
          "the iPhone starts with sync and no choice yet: it plays with its own, nothing is sent, the newer Mac save stays in the cloud");
    CHECK(run(B, cloud, NULL, NULL, choice_of("cloud", cf), NULL, READABLE) == 0 && same(p, "v5"), "the player chooses the cloud's: the Mac save comes in");
    backup_of(B, "local", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "v4"), "the iPhone's own is kept (%s)", back);

    printf("(6) both changed, this one newer\n");
    snprintf(p, sizeof p, "%s/game.dat", A);
    CHECK(session(A, NULL, "game.dat", "v6") == 0, "the Mac plays with sync off");
    set_mtime(p, time(NULL) + 100);
    CHECK(session(B, cloud, "game.dat", "v7") == 0 && cloud_has(cf, root, "game.dat", "v7"), "the iPhone saves and sends");
    char old_choice[64]; snprintf(old_choice, sizeof old_choice, "%s", choice_of("local", cf));
    CHECK(run(A, cloud, NULL, NULL, "ask", NULL, READABLE) == NOT_SENT && same(p, "v6") && cloud_has(cf, root, "game.dat", "v7") && !backups(A, "cloud"),
          "the Mac starts with sync and no choice yet: its newer save stays here and is not sent, the iPhone's stays in the cloud");
    CHECK(session(B, cloud, "game.dat", "v7b") == 0 && cloud_has(cf, root, "game.dat", "v7b"), "the iPhone saves again");
    CHECK(run(A, cloud, NULL, NULL, old_choice, NULL, READABLE) == NOT_SENT && same(p, "v6") && cloud_has(cf, root, "game.dat", "v7b"),
          "a choice made on the cloud's save before that one replaces nothing");
    {   ss_meta here; char own[64] = "";   // the token names the cloud's save, not this device's (the launchers sent local:<this device's hash> until this was checked)
        if (!ss_scan(A, &here)) snprintf(own, sizeof own, "local:%s", here.hash);
        CHECK(*own && run(A, cloud, NULL, NULL, own, NULL, READABLE) == NOT_SENT && same(p, "v6") && cloud_has(cf, root, "game.dat", "v7b"),
              "local:<this device's hash> is not a choice for the cloud's save: nothing is replaced"); }
    CHECK(run(A, cloud, NULL, NULL, choice_of("local", cf), NULL, READABLE) == 0 && same(p, "v6") && cloud_has(cf, root, "game.dat", "v6"),
          "the player chooses this one: it goes out");
    backup_of(A, "cloud", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "v7b"), "the iPhone's save it replaced in the cloud is kept on the Mac (%s)", back);

    printf("(7) the Mac launcher after the host\n");
    snprintf(p, sizeof p, "%s/game.dat", A); put(p, "v8");
    setenv("DM_SAVE_SYNC", cloud, 1);
    CHECK(save_sync_after_exit(A, DM_GAME_ID) == 1 && cloud_has(cf, root, "game.dat", "v8"), "a save the host left unsent goes out");
    time_t sent = mtime_of(cf);
    sleep(1);
    CHECK(save_sync_after_exit(A, DM_GAME_ID) == 1 && mtime_of(cf) == sent, "a second time there is nothing to send (the cloud's file is not rewritten)");
    unsetenv("DM_SAVE_SYNC");
    CHECK(save_sync_after_exit(A, DM_GAME_ID) == 1, "sync off: nothing to do");

    printf("(8) the game's own folder chosen\n");
    char C[1200], own[1300]; snprintf(C, sizeof C, "%s/mac2/save", root); mkd(C); snprintf(own, sizeof own, "%s/%s", cloud, id);
    snprintf(p, sizeof p, "%s/game.dat", C);
    CHECK(session(C, own, NULL, NULL) == 0 && same(p, "v8"), "<folder>/<title ID> itself as the folder: the save in it comes in");
    snprintf(q, sizeof q, "%s/%s", own, id); CHECK(!exists(q), "and no second <title ID> folder is made inside it");

    printf("(9) old backups go\n");
    snprintf(q, sizeof q, "%s-backups", C);
    for (int i = 0; i < 12; i++) { snprintf(p, sizeof p, "%s/2001-01-01 00.00.%02d local/save", q, i); mkd(p); }
    snprintf(p, sizeof p, "%s/2001-01-01 00.00.00 cloud", q); mkd(p); snprintf(p, sizeof p, "%s/my copy", q); mkd(p);
    snprintf(p, sizeof p, "%s/2001-01-01 00.00.00 local 2", q); mkd(p);
    CHECK(session(B, cloud, "game.dat", "v9") == 0 && cloud_has(cf, root, "game.dat", "v9"), "the iPhone saves again");
    snprintf(p, sizeof p, "%s/game.dat", C);
    CHECK(session(C, own, NULL, NULL) == 0 && same(p, "v9"), "the second Mac brings it in, keeping its own");
    int locals = 0; DIR *d = opendir(q); struct dirent *e;
    while (d && (e = readdir(d))) { size_t l = strlen(e->d_name); locals += l > 6 && (!strcmp(e->d_name + l - 6, " local") || strstr(e->d_name, " local ")); }
    if (d) closedir(d);
    backup_of(C, "local", back, sizeof back); snprintf(u, sizeof u, "%s/save/game.dat", back);
    CHECK(locals == 10 && same(u, "v8"), "10 local backups stay, the new one among them (%d)", locals);
    snprintf(p, sizeof p, "%s/2001-01-01 00.00.00 local 2", q); snprintf(u, sizeof u, "%s/2001-01-01 00.00.02 local", q);
    char u2[1400]; snprintf(u2, sizeof u2, "%s/2001-01-01 00.00.03 local", q);
    CHECK(!exists(p) && !exists(u) && exists(u2), "the four oldest went (00, 00 2, 01, 02)");
    snprintf(p, sizeof p, "%s/2001-01-01 00.00.00 cloud", q); snprintf(u, sizeof u, "%s/my copy", q);
    CHECK(exists(p) && exists(u), "the other side's backups and a folder of the player's stay");

    printf("(10) the Mac launcher's DM_SAVE with a slash after it\n");
    snprintf(p, sizeof p, "%s/game.dat", C); put(p, "v10");
    snprintf(u, sizeof u, "%s/", C); setenv("DM_SAVE_SYNC", own, 1);
    CHECK(save_sync_after_exit(u, DM_GAME_ID) == 1 && cloud_has(cf, root, "game.dat", "v10"), "it goes out");
    snprintf(p, sizeof p, "%s/.sync", C); CHECK(!exists(p), "and the sync state is beside the save, not inside it");
    unsetenv("DM_SAVE_SYNC");

    printf("(11) the cloud cannot be read at the start\n");
    char M[1200], N[1200], P2[1200], cloud2[1200], cf2[1400];
    snprintf(M, sizeof M, "%s/mac3/save", root); snprintf(N, sizeof N, "%s/mac4/save", root); snprintf(P2, sizeof P2, "%s/iphone2/save", root);
    snprintf(cloud2, sizeof cloud2, "%s/iCloud Drive/Other Saves", root); mkd(M); mkd(N); mkd(P2); mkd(cloud2);
    snprintf(cf2, sizeof cf2, "%s/%s/save.dmsync", cloud2, id);
    snprintf(p, sizeof p, "%s/game.dat", M); put(p, "m1");
    CHECK(session(M, cloud2, NULL, NULL) == 0 && session(P2, cloud2, "game.dat", "p1") == 0 && cloud_has(cf2, root, "game.dat", "p1"), "the Mac sends m1, the iPhone brings it in and sends p1");
    CHECK(run(M, cloud2, "game.dat", "m2", NULL, cf2, LATE) == NOT_SENT && same(p, "m2") && cloud_has(cf2, root, "game.dat", "p1") && !backups(M, "cloud"),
          "the Mac starts before the cloud's save can be read and saves m2: the iPhone's p1 stays in the cloud, nothing is moved into the Mac's backups");
    setenv("DM_SAVE_SYNC", cloud2, 1);
    CHECK(save_sync_after_exit(M, DM_GAME_ID) == 0 && cloud_has(cf2, root, "game.dat", "p1"), "nor does the Mac launcher's send after the host replace it");
    unsetenv("DM_SAVE_SYNC");
    CHECK(run(M, cloud2, "game.dat", "m3", "offline", cf2, UNREADABLE) == NOT_SENT && same(p, "m3") && cloud_has(cf2, root, "game.dat", "p1"),
          "the player plays offline with the cloud unreadable all along: m3 is played, nothing is sent");
    CHECK(run(M, cloud2, NULL, NULL, choice_of("cloud", cf2), NULL, READABLE) == 0 && same(p, "p1"), "with the cloud back, the player chooses the iPhone's: it comes in");
    backup_of(M, "local", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "m3"), "and the Mac's m3 is kept (%s)", back);

    printf("(12) the first play on a new Mac\n");
    snprintf(p, sizeof p, "%s/game.dat", N);
    CHECK(run(N, cloud2, "game.dat", "n1", NULL, cf2, LATE) == NOT_SENT && same(p, "n1") && cloud_has(cf2, root, "game.dat", "p1"),
          "the new Mac starts before the cloud's save can be read and the game makes a new save: the cloud's progress stays");
    CHECK(run(N, cloud2, NULL, NULL, "ask", NULL, READABLE) == NOT_SENT && same(p, "n1") && cloud_has(cf2, root, "game.dat", "p1"), "its next start, with no choice yet, replaces nothing");
    CHECK(run(N, cloud2, NULL, NULL, choice_of("cloud", cf2), NULL, READABLE) == 0 && same(p, "p1"), "the player chooses the cloud's: it comes in");
    backup_of(N, "local", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "n1"), "and the new save is kept (%s)", back);
    CHECK(session(N, cloud2, "game.dat", "n2") == 0 && cloud_has(cf2, root, "game.dat", "n2"), "from then on its saves go out");

    printf("(13) a damaged file in the cloud\n");
    put(cf2, "DMSYNC1\nnot a save");
    CHECK(session(N, cloud2, "game.dat", "n3") == 0 && cloud_has(cf2, root, "game.dat", "n3"), "this device's save replaces it");
    backup_of(N, "cloud", back, sizeof back); snprintf(q, sizeof q, "%s/save.dmsync", back);
    CHECK(*back && same(q, "DMSYNC1\nnot a save"), "the damaged file is kept (%s)", back);

    printf("(14) no front end asks: the newer one wins\n");
    char X[1200], Y[1200], cloud3[1200], cf3[1400];
    snprintf(X, sizeof X, "%s/mac5/save", root); snprintf(Y, sizeof Y, "%s/iphone3/save", root); snprintf(cloud3, sizeof cloud3, "%s/iCloud Drive/Third Saves", root);
    mkd(X); mkd(Y); mkd(cloud3); snprintf(cf3, sizeof cf3, "%s/%s/save.dmsync", cloud3, id);
    snprintf(p, sizeof p, "%s/game.dat", X);
    CHECK(session(Y, cloud3, "game.dat", "y1") == 0 && session(X, cloud3, NULL, NULL) == 0 && same(p, "y1"), "the iPhone sends y1, the Mac brings it in");
    CHECK(session(X, NULL, "game.dat", "x1") == 0, "the Mac plays with sync off");
    set_mtime(p, time(NULL) - 100);
    CHECK(session(Y, cloud3, "game.dat", "y2") == 0 && cloud_has(cf3, root, "game.dat", "y2"), "the iPhone saves and sends a newer save");
    CHECK(session(X, cloud3, NULL, NULL) == 0 && same(p, "y2"), "the Mac starts with sync: the iPhone's newer save comes in");
    backup_of(X, "local", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "x1"), "and the Mac's own is kept (%s)", back);
    CHECK(session(Y, cloud3, "game.dat", "y3") == 0 && cloud_has(cf3, root, "game.dat", "y3"), "the iPhone saves again");
    CHECK(run(X, cloud3, "game.dat", "x2", NULL, cf3, LATE) == NOT_SENT && same(p, "x2") && cloud_has(cf3, root, "game.dat", "y3") && !backups(X, "cloud"),
          "the Mac starts before the cloud's save can be read and saves x2: not sent that session");
    CHECK(session(X, cloud3, NULL, NULL) == 0 && same(p, "x2") && cloud_has(cf3, root, "game.dat", "x2"), "its next start finds its save the newer one: it goes out");
    backup_of(X, "cloud", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "y3"), "and the iPhone's save it replaced is kept on the Mac (%s)", back);

    printf("(15) the report a front end reads before it plays\n");
    char R1[1200], R2[1200], cloud4[1200], cf4[1400], own4[1400], line[2048];
    snprintf(R1, sizeof R1, "%s/mac6/save", root); snprintf(R2, sizeof R2, "%s/iphone4/save", root);
    snprintf(cloud4, sizeof cloud4, "%s/iCloud Drive/Fourth Saves", root); snprintf(own4, sizeof own4, "%s/%s", cloud4, id);
    mkd(R1); mkd(R2); mkd(cloud4); snprintf(cf4, sizeof cf4, "%s/%s/save.dmsync", cloud4, id);
#define REPORT(save, folder) (!save_sync_report(save, DM_GAME_ID, folder, 0, line, sizeof line) && !strchr(line, '\n'))
    CHECK(!strcmp(dm_save_title(), DM_GAME_ID), "the title the iPhone launcher names the cloud file with is the profile's");
    CHECK(REPORT(R1, cloud4) && strstr(line, "sync=1 cloud=0 ") && strstr(line, "local=- ") && strstr(line, "conflict=0"),
          "no save here, none in the cloud: no conflict, nothing to replace (%s)", line);
    snprintf(p, sizeof p, "%s/game.dat", R1); put(p, "r1-with-progress");
    CHECK(REPORT(R1, cloud4) && strstr(line, "files=1 size=16 ") && strstr(line, "chash=- ") && strstr(line, "conflict=0"),
          "a save here, the cloud's empty: no conflict, the mount sends it (%s)", line);
    CHECK(session(R1, cloud4, NULL, NULL) == 0 && cloud_has(cf4, root, "game.dat", "r1-with-progress"), "the session sends it");
    CHECK(REPORT(R1, cloud4) && strstr(line, "cloud=1 ") && strstr(line, "csize=16 ") && strstr(line, "sametitle=1 ") && strstr(line, "conflict=0") && !strstr(line, "cdevice=- "),
          "the same save here and in the cloud: no conflict, the cloud's device named (%s)", line);
    CHECK(REPORT(R1, own4) && strstr(line, "cloud=1 ") && strstr(line, "csize=16 "),
          "the game's own folder chosen as the folder: the same file as the mount's (%s)", line);
    snprintf(p, sizeof p, "%s/game.dat", R2);
    CHECK(REPORT(R2, cloud4) && strstr(line, "local=- ") && strstr(line, "cfiles=1 ") && strstr(line, "conflict=0"),
          "the cloud has one and this device none: it comes in, no conflict (%s)", line);
    CHECK(session(R2, cloud4, NULL, NULL) == 0 && same(p, "r1-with-progress"), "and the session brings it in");
    CHECK(session(R2, NULL, "game.dat", "r2") == 0 && same(p, "r2"), "the iPhone plays with sync off and saves r2");
    set_mtime(p, time(NULL) - 100);
    CHECK(session(R1, cloud4, "game.dat", "r3-more-progress") == 0 && cloud_has(cf4, root, "game.dat", "r3-more-progress"), "then the Mac saves more and sends it");
    snprintf(p, sizeof p, "%s/game.dat", R2); put(p, "new"); set_mtime(p, time(NULL) + 45);
    // the cloud's save was sent from this machine, so its device is this machine's model, as save_sync.c names it: a GitHub runner, a virtual machine, is "VirtualMac2,1"
    char model[64] = "", cdev[96]; size_t mlen = sizeof model;
    if (sysctlbyname("hw.model", model, &mlen, NULL, 0) || !model[0]) snprintf(model, sizeof model, "unknown");
    snprintf(cdev, sizeof cdev, "cdevice=%s ", model);
    CHECK(REPORT(R2, cloud4) && strstr(line, "conflict=1") && strstr(line, "cfiles=1 ") && strstr(line, cdev),
          "both changed: the report says conflict, with the cloud's device (%s)", line);
    CHECK(strstr(line, " pull=0") != NULL, "no pull pending (%s)", line);
    {   // a pull that did not finish: what is in place may be half the cloud's, so no comparison is offered; the start's mount puts this device's save back first
        char J[1300]; snprintf(J, sizeof J, "%s.pull", R2); put(J, "kept\t\nfolder\t0\t1\t0\t0\nfolder\t1\t0\t0\t0\n");
        CHECK(REPORT(R2, cloud4) && strstr(line, " pull=1") && strstr(line, "conflict=0"), "a pending pull: said so, and no conflict offered (%s)", line);
        unlink(J);
    }
    {   // the incident of the PR: the new game's save is the newer by date, so the player needs the sizes to tell them apart
        char *cs = strstr(line, "csaved="), *sv = strstr(line, " saved=");
        CHECK(cs && sv && atoll(sv + 7) > atoll(cs + 7) && strstr(line, " size=3 ") && strstr(line, "csize=16 "),
              "this device's date is the newer, its save the smaller (%s)", line);
    }
    chmod(cf4, 0);
    CHECK(REPORT(R2, cloud4) && strstr(line, "cloud=-1 ") && strstr(line, "chash=- ") && strstr(line, "conflict=0"),
          "the cloud cannot be read: said so, and no conflict to offer (%s)", line);
    chmod(cf4, 0644);
    CHECK(REPORT(R2, "0") && strstr(line, "sync=0 cloud=0 ") && !strstr(line, "local=- ") && strstr(line, "conflict=0"),
          "sync off: the local save alone is reported (%s)", line);
    setenv("DM_SAVE_SYNC", cloud4, 1);
    CHECK(REPORT(R2, NULL) && strstr(line, "conflict=1"), "no folder given: DM_SAVE_SYNC's, as the mount reads it (%s)", line);
    unsetenv("DM_SAVE_SYNC");
    CHECK(REPORT(R2, NULL) && strstr(line, "sync=0 "), "and with no DM_SAVE_SYNC, sync is off (%s)", line);
    snprintf(q, sizeof q, "%s.sync-tmp", R2);
    CHECK(access(q, F_OK), "the reports leave no files behind");
#undef REPORT

    {   // (15) a pull's journal the start cannot put back (this device's folder is neither in place nor in the backups it names): the game's save mount stops rather than
        // play on, commit and send a half-replaced save; the save and the journal are left as they were. With the journal gone, the mount goes on
        char S15[1200], J[1300], A[1300]; snprintf(S15, sizeof S15, "%s/s15/save", root); mkd(S15);
        snprintf(A, sizeof A, "%s/a", S15); put(A, "mine");
        snprintf(J, sizeof J, "%s.pull", S15); put(J, "kept\t/nonexistent/backup\nfolder\t0\t2\t1\t1\nfolder\t1\t0\t0\t0\n");
        CHECK(session(S15, NULL, NULL, NULL) != 0, "(15) the save mount stops");
        CHECK(same(A, "mine") && exists(J), "(15) the save and the journal are left as they were");
        unlink(J);
        CHECK(session(S15, NULL, NULL, NULL) == 0 && same(A, "mine"), "(15) with no journal the mount goes on");
    }
    printf("(16) a backup that cannot be made\n");
    {   char A3[1200], B3[1200], H5[1200], ch5[1400], bk[1400], oldest[1600];
        snprintf(A3, sizeof A3, "%s/pmac/save", root); snprintf(B3, sizeof B3, "%s/ppad/save", root); mkd(A3); mkd(B3);
        snprintf(H5, sizeof H5, "%s/iCloud Drive/Eighth Saves", root); mkd(H5); snprintf(ch5, sizeof ch5, "%s/%s/save.dmsync", H5, id);
        snprintf(p, sizeof p, "%s/game.dat", A3); put(p, "a1");
        CHECK(session(A3, H5, NULL, NULL) == 0 && session(B3, H5, "game.dat", "b2") == 0 && cloud_has(ch5, root, "game.dat", "b2"), "(16) the Mac sends a1, the iPad brings it in and sends b2");
        for (int i = 0; i < 10; i++) {   // ten older backups of each side: the most that stay
            snprintf(bk, sizeof bk, "%s-backups/2001-01-%02d 00.00.00 local/save", A3, i + 1); mkd(bk);
            snprintf(bk, sizeof bk, "%s-backups/2001-01-%02d 00.00.00 local/save/game.dat", A3, i + 1); put(bk, "old");
            snprintf(bk, sizeof bk, "%s-backups/2001-01-%02d 00.00.00 cloud/save", A3, i + 1); mkd(bk);
            snprintf(bk, sizeof bk, "%s-backups/2001-01-%02d 00.00.00 cloud/save/game.dat", A3, i + 1); put(bk, "old");
        }
        // A pull: both changed, the cloud's newer, so it comes in and this one is kept first; the move into the backups fails
        snprintf(oldest, sizeof oldest, "%s-backups/2001-01-01 00.00.00 local", A3);
        put(p, "a-unsynced"); set_mtime(p, time(NULL) - 5000);
        g_rename_fail = "-backups/";
        run(A3, H5, NULL, NULL, NULL, NULL, READABLE);
        g_rename_fail = NULL;
        snprintf(q, sizeof q, "%s.sync-tmp", A3);
        CHECK(same(p, "a-unsynced") && cloud_has(ch5, root, "game.dat", "b2") && !exists(q), "(16) a pull fails: this device's save stays as it was, nothing is left beside it");
        CHECK(backups(A3, "local") == 10 && exists(oldest), "(16) the backup folder made for it goes, and no older backup is removed");
        CHECK(session(A3, H5, NULL, NULL) == 0 && same(p, "b2"), "(16) the next start pulls");
        CHECK(kept(A3, "local", "game.dat", "a-unsynced") && backups(A3, "local") == 10 && !exists(oldest), "(16) it keeps this device's, and only then the oldest beyond 10 goes");
        // The start's copy of the cloud's save it chose against: both changed, this one newer, so it goes out and the cloud's is kept first; unpacking that copy fails
        snprintf(oldest, sizeof oldest, "%s-backups/2001-01-01 00.00.00 cloud", A3);
        CHECK(session(A3, NULL, "game.dat", "a-newer") == 0, "(16) the Mac plays with sync off");
        set_mtime(p, time(NULL) + 100);
        snprintf(q, sizeof q, "%s/game.dat", B3);
        CHECK(session(B3, H5, "game.dat", "b3") == 0 && cloud_has(ch5, root, "game.dat", "b3"), "(16) the iPad saves and sends b3");
        g_mkdir_fail = "/.cloud-stage.";   // the cloud's copy is unpacked into staging first (backup_cloud_restore, upstream 7886d3038)
        CHECK(run(A3, H5, NULL, NULL, NULL, NULL, READABLE) == NOT_SENT && same(p, "a-newer") && cloud_has(ch5, root, "game.dat", "b3"),
              "(16) the Mac's newer save cannot keep the cloud's first: nothing is sent");
        g_mkdir_fail = NULL;
        CHECK(backups(A3, "cloud") == 10 && exists(oldest), "(16) the folder made for it goes, and no older cloud backup is removed");
        CHECK(session(A3, H5, NULL, NULL) == 0 && same(p, "a-newer") && cloud_has(ch5, root, "game.dat", "a-newer"), "(16) the next start sends it");
        CHECK(kept(A3, "cloud", "game.dat", "b3") && backups(A3, "cloud") == 10 && !exists(oldest), "(16) it keeps the iPad's, and only then the oldest beyond 10 goes");
        // The damaged cloud file the sender keeps before it replaces it: the move into the backups fails
        snprintf(oldest, sizeof oldest, "%s-backups/2001-01-02 00.00.00 cloud", A3);
        put(ch5, "DMSYNC1\nnot a save");
        g_rename_fail = "-backups/";
        CHECK(session(A3, H5, "game.dat", "a-more") == NOT_SENT && same(ch5, "DMSYNC1\nnot a save"), "(16) the damaged file cannot be kept: it is not replaced");
        g_rename_fail = NULL;
        CHECK(backups(A3, "cloud") == 10 && exists(oldest), "(16) the folder made for it goes, and no older cloud backup is removed");
        CHECK(session(A3, H5, "game.dat", "a-most") == 0 && cloud_has(ch5, root, "game.dat", "a-most"), "(16) the next save replaces it");
        CHECK(kept_at(A3, "cloud", "save.dmsync", "DMSYNC1\nnot a save") && backups(A3, "cloud") == 10 && !exists(oldest), "(16) it keeps the damaged file, and only then the oldest beyond 10 goes");
    }

    // C is still in step with the first folder's file (cf): v10 (cases 11-16 use saves of their own)
    char F2[1200], F3[1200], F4[1200], cg2[1400], cg3[1400], cg4[1400], E[1200], state[1400], logf[1400], want[1600];
    snprintf(F2, sizeof F2, "%s/iCloud Drive/Saves 2", root); snprintf(F3, sizeof F3, "%s/iCloud Drive/Saves 3", root); snprintf(F4, sizeof F4, "%s/iCloud Drive/Saves 4", root);
    mkd(F2); mkd(F3); mkd(F4);
    snprintf(cg2, sizeof cg2, "%s/%s/save.dmsync", F2, id); snprintf(cg3, sizeof cg3, "%s/%s/save.dmsync", F3, id); snprintf(cg4, sizeof cg4, "%s/%s/save.dmsync", F4, id);
    snprintf(E, sizeof E, "%s/ipad/save", root); mkd(E);
    snprintf(state, sizeof state, "%s.sync", C); snprintf(logf, sizeof logf, "%s/session.log", root);

    printf("(17) another folder, with no save in it\n");
    g_log = logf;
    CHECK(session(C, F2, NULL, NULL) == 0 && cloud_has(cg2, root, "game.dat", "v10"), "the save, unchanged since its sync with the first folder, goes to the new one at the start");
    g_log = NULL;
    CHECK(count_in(logf, "this device last synced with ") == 1 && count_in(logf, "is not in the cloud yet: it goes to the cloud") == 1 && count_in(logf, "sent: ") == 1,
          "the log says once that the last sync was with another folder, then that the save goes, and that it went");
    pass_on(logf);
    snprintf(want, sizeof want, "\ncloud\t%s\n", cg2); CHECK(count_in(state, want) == 1, "the sync state names the new folder's file");

    printf("(18) another folder, with another device's older save in it\n");
    snprintf(p, sizeof p, "%s/game.dat", E); put(p, "v11"); set_mtime(p, time(NULL) - 1000);
    CHECK(session(E, F3, NULL, NULL) == 0 && cloud_has(cg3, root, "game.dat", "v11"), "an iPad sends an older save to a third folder");
    snprintf(p, sizeof p, "%s/game.dat", C);
    CHECK(session(C, F3, NULL, NULL) == 0 && same(p, "v10") && cloud_has(cg3, root, "game.dat", "v10"),
          "the Mac picks that folder: its own newer save stays and goes out (a first sync with the folder: the newer wins), not the iPad's in over it");
    backup_of(C, "cloud", back, sizeof back); snprintf(q, sizeof q, "%s/save/game.dat", back);
    CHECK(*back && same(q, "v11"), "the iPad's save it replaced is kept on the Mac (%s)", back);

    printf("(19) the same folder again\n");
    CHECK(session(E, F3, "game.dat", "v13") == 0 && cloud_has(cg3, root, "game.dat", "v13"), "the iPad takes the Mac's save in, saves and sends");
    snprintf(p, sizeof p, "%s/game.dat", C); set_mtime(p, time(NULL) + 1000);   // a newer date, the same save: the base still says only the cloud's changed
    CHECK(session(C, F3, NULL, NULL) == 0 && same(p, "v13"), "the Mac starts with the same folder: only the cloud's changed, so it comes in, though the Mac's date is newer");

    printf("(20) a sync state an older build wrote\n");
    CHECK(session(E, F3, "game.dat", "v14") == 0 && cloud_has(cg3, root, "game.dat", "v14"), "the iPad saves and sends again");
    CHECK(!ss_scan(C, &m) && m.files == 1, "the Mac's save, v13");
    snprintf(want, sizeof want, "# save sync (dm/host/save_sync.h): the save last known to be the same here and in the cloud\nbase\t%s\n", m.hash); put(state, want);   // no cloud line
    snprintf(p, sizeof p, "%s/game.dat", C); set_mtime(p, time(NULL) + 1000);
    CHECK(session(C, F3, NULL, NULL) == 0 && same(p, "v14"), "its base counts as it did: only the cloud's changed, the iPad's save comes in");
    snprintf(want, sizeof want, "\ncloud\t%s\n", cg3); CHECK(count_in(state, want) == 1, "and the sync state now names the folder's file");
    CHECK(!ss_scan(C, &m) && m.files == 1, "the Mac's save, v14");
    snprintf(want, sizeof want, "# save sync (dm/host/save_sync.h): the save last known to be the same here and in the cloud\nbase\t%s\n", m.hash); put(state, want);
    CHECK(session(C, F4, NULL, NULL) == 0 && cloud_has(cg4, root, "game.dat", "v14"), "with no cloud line and a folder that has no save, the save goes out at the start");

    printf("(21) the cloud's file removed\n");
    unlink(cg4); g_log = logf;
    CHECK(session(C, F4, NULL, NULL) == 0 && cloud_has(cg4, root, "game.dat", "v14"), "the same folder, its file gone: the save goes back at the start");
    g_log = NULL;
    CHECK(count_in(logf, "is no longer in the cloud: it goes to the cloud") == 1 && count_in(logf, "last synced with") == 0, "the log says it is no longer there, and nothing about another folder");
    pass_on(logf);

    printf("(22) the Mac launcher after a host that ended at its save mount\n");
    unlink(cg4);
    CHECK(mount_only(C, F4) == 0, "the host mounts the save and ends");
    setenv("DM_SAVE_SYNC", F4, 1);
    CHECK(save_sync_after_exit(C, DM_GAME_ID) == 1 && cloud_has(cg4, root, "game.dat", "v14"), "the launcher's send after it: the save the mount found to send is in the cloud");
    snprintf(want, sizeof want, "%s.sync-tmp", C); CHECK(!exists(want), "and the mount's mark of that push is gone with it");
    unsetenv("DM_SAVE_SYNC");

    printf("(23) another path to the very save last in step\n");
    char F6[1200], cg6[1400], F7[1200], cg7[1400], F8[1200], cg8[1400], aside[1500], logp[1400];
    snprintf(F6, sizeof F6, "%s/iCloud Drive/Saves 6", root); snprintf(cg6, sizeof cg6, "%s/%s/save.dmsync", F6, id);
    snprintf(F7, sizeof F7, "%s/iCloud Drive/Saves 7", root); snprintf(cg7, sizeof cg7, "%s/%s/save.dmsync", F7, id);
    snprintf(F8, sizeof F8, "%s/iCloud Drive/Saves 8", root); snprintf(cg8, sizeof cg8, "%s/%s/save.dmsync", F8, id);
    {   FILE *f = fopen(cg4, "rb"), *o = NULL; char b[4096]; size_t k = 0, w = 0;
        if (f) { k = fread(b, 1, sizeof b, f); fclose(f); }
        snprintf(p, sizeof p, "%s/%s", F6, id); mkd(p);
        if (k > 0 && k < sizeof b && (o = fopen(cg6, "wb"))) { w = fwrite(b, 1, k, o); if (fclose(o)) w = 0; }
        CHECK(k > 0 && k < sizeof b && w == k, "the fourth folder's file, byte for byte, under another path");
    }
    snprintf(p, sizeof p, "%s/game.dat", C); put(p, "v17"); set_mtime(p, time(NULL) - 100000);
    g_log = logf;
    CHECK(session(C, F6, NULL, NULL) == 0 && same(p, "v17") && cloud_has(cg6, root, "game.dat", "v17"),
          "the Mac's save, changed since its last sync and older than the cloud's: only this one changed, so it goes out (the cloud's file is the save last in step)");
    g_log = NULL;
    CHECK(count_in(logf, "last synced with") == 0, "and no line about another folder");
    pass_on(logf);

    printf("(24) a cloud file it cannot read, this device's save the one last in step\n");
    put(cg6, "not a packed save (a newer build's format)");
    g_log = logf;
    CHECK(session(C, F6, NULL, NULL) == 0 && same(p, "v17"), "a start: the Mac plays on with its save");
    g_log = NULL;
    CHECK(same(cg6, "not a packed save (a newer build's format)"), "the file it cannot read is left as it was");
    CHECK(count_in(logf, "it replaces the cloud's damaged file once the game saves") == 1 && count_in(logf, "sent: ") == 0, "the log says it is replaced only once the game saves");
    pass_on(logf);
    setenv("DM_SAVE_SYNC", F6, 1);
    CHECK(save_sync_after_exit(C, DM_GAME_ID) == 1 && same(cg6, "not a packed save (a newer build's format)"), "nor does the Mac launcher's send after it replace it");
    unsetenv("DM_SAVE_SYNC");

    printf("(25) the push of the save last in step with another folder, not gone out at the start\n");
    int go = -1, first; pid_t kid = -1;
    snprintf(p, sizeof p, "%s/not yet", root);
    CHECK(!symlink(p, F7) && (kid = start_paused(C, F7, &go, &first)) > 0 && first == 0,
          "the Mac picks a folder it cannot write into yet: the save the mount found to send does not go out (the first flush says so)");
    snprintf(want, sizeof want, "\ncloud\t%s\n", cg6); CHECK(count_in(state, want) == 1, "the sync state still names the file it was in step with");
    unlink(F7); mkd(F7);
    CHECK(kid > 0 && resume(kid, go) == 0 && cloud_has(cg7, root, "game.dat", "v17"), "the folder can be written, still with no file: a flush later in that start sends the save");
    snprintf(want, sizeof want, "\ncloud\t%s\n", cg7); CHECK(count_in(state, want) == 1, "and only then names the new folder's file");
    snprintf(p, sizeof p, "%s/not yet", root); snprintf(logp, sizeof logp, "%s/paused.log", root);
    g_log = logp; kid = -1;
    CHECK(!symlink(p, F8) && (kid = start_paused(C, F8, &go, &first)) > 0 && first == 0, "the Mac picks another such folder: its push does not go out either");
    g_log = NULL;
    unlink(F8); mkd(F8);
    snprintf(p, sizeof p, "%s/game.dat", E);
    CHECK(session(E, F8, "game.dat", "v20") == 0 && cloud_has(cg8, root, "game.dat", "v20"), "meanwhile the iPad picks that folder, saves and sends");
    CHECK(kid > 0 && resume(kid, go) == 0 && cloud_has(cg8, root, "game.dat", "v20"), "the Mac's flush later in that start: its unchanged save does not replace the iPad's");
    CHECK(count_in(logp, "changed meanwhile: this device's, the one it last synced, is not sent") == 1 && count_in(logp, "sent: ") == 0, "the log says why");
    pass_on(logp);
    snprintf(aside, sizeof aside, "%s.aside", cg8);
    CHECK(!rename(cg8, aside) && (mkd(cg8), mount_only(C, F8) == 0), "the Mac's next start cannot read the cloud at its save mount (a folder where the file is), and ends");
    rmdir(cg8); rename(aside, cg8);
    setenv("DM_SAVE_SYNC", F8, 1);
    CHECK(save_sync_after_exit(C, DM_GAME_ID) == 1 && cloud_has(cg8, root, "game.dat", "v20"), "the launcher's send after it leaves the iPad's save too");
    unsetenv("DM_SAVE_SYNC");
    kid = -1;
    CHECK(!rename(cg8, aside) && (mkd(cg8), (kid = start_paused(C, F8, &go, &first)) > 0), "the iPhone's next start cannot read the cloud at its save mount either");
    rmdir(cg8); rename(aside, cg8);
    CHECK(kid > 0 && resume(kid, go) == 0 && cloud_has(cg8, root, "game.dat", "v20"), "and its flush once the cloud can be read leaves the iPad's save too");
    snprintf(p, sizeof p, "%s/game.dat", C); set_mtime(p, time(NULL) - 100000);
    CHECK(session(C, F8, NULL, NULL) == 0 && same(p, "v20"), "a start that reads the cloud compares the two: the iPad's newer save comes in");
    CHECK(kept(C, "local", "game.dat", "v17"), "and the Mac's is kept in its backups");

    printf("(26) a front end that asks, after another folder was picked\n");
    char K[1200], L[1200], H1[1200], H2[1200], ch1[1400], ch2[1400], logk[1400];
    snprintf(K, sizeof K, "%s/mac8/save", root); snprintf(L, sizeof L, "%s/iphone6/save", root); mkd(K); mkd(L);
    snprintf(H1, sizeof H1, "%s/iCloud Drive/Ninth Saves", root); snprintf(H2, sizeof H2, "%s/iCloud Drive/Tenth Saves", root); mkd(H1); mkd(H2);
    snprintf(ch1, sizeof ch1, "%s/%s/save.dmsync", H1, id); snprintf(ch2, sizeof ch2, "%s/%s/save.dmsync", H2, id); snprintf(logk, sizeof logk, "%s/ask.log", root);
    snprintf(p, sizeof p, "%s/game.dat", L); put(p, "l1"); set_mtime(p, time(NULL) - 1000);
    CHECK(session(L, H2, NULL, NULL) == 0 && cloud_has(ch2, root, "game.dat", "l1"), "an iPhone sends an older save to a folder");
    snprintf(p, sizeof p, "%s/game.dat", K); put(p, "k1");
    CHECK(session(K, H1, NULL, NULL) == 0 && cloud_has(ch1, root, "game.dat", "k1"), "the Mac is in step with another folder");
    CHECK(!save_sync_report(K, DM_GAME_ID, H2, 0, line, sizeof line) && strstr(line, "conflict=1") && strstr(line, "cfiles=1 "),
          "the Mac's launcher reports the iPhone's folder: a conflict, as the mount sees it (the other folder's base counts for nothing) (%s)", line);
    CHECK(!save_sync_report(K, DM_GAME_ID, H1, 0, line, sizeof line) && strstr(line, "conflict=0"), "and none for the folder it is in step with (%s)", line);
    g_log = logk;
    // Its flush says in step (0, not NOT_SENT): the save it plays is the one it last synced, which has nothing new to send (send_save); nothing goes until the player chooses
    CHECK(run(K, H2, NULL, NULL, "ask", NULL, READABLE) == 0 && same(p, "k1") && cloud_has(ch2, root, "game.dat", "l1") && !backups(K, "local") && !backups(K, "cloud"),
          "a start with \"ask\" there (nothing chosen yet): neither replaces the other, the Mac plays on with its own");
    g_log = NULL;
    CHECK(count_in(logk, "this device last synced with ") == 1 && count_in(logk, "neither replaces the other") == 1, "the log says the last sync was with another folder, and that both changed");
    pass_on(logk);
    CHECK(run(K, H2, NULL, NULL, choice_of("local", ch2), NULL, READABLE) == 0 && same(p, "k1") && cloud_has(ch2, root, "game.dat", "k1"),
          "the player chooses the Mac's: it goes out");
    CHECK(kept(K, "cloud", "game.dat", "l1"), "and the iPhone's save it replaced is kept on the Mac");
    snprintf(q, sizeof q, "%s/game.dat", L);
    CHECK(session(L, H2, NULL, NULL) == 0 && same(q, "k1"), "the iPhone takes the Mac's in");
    CHECK(session(L, H2, "game.dat", "l2") == 0 && cloud_has(ch2, root, "game.dat", "l2"), "the iPhone saves l2 and sends it");
    CHECK(session(K, H1, "game.dat", "k2") == 0 && cloud_has(ch1, root, "game.dat", "k2"), "the Mac goes back to the first folder and sends k2 there");
    CHECK(!save_sync_report(K, DM_GAME_ID, H2, 0, line, sizeof line) && strstr(line, "conflict=1"), "picking the iPhone's folder again is a conflict (%s)", line);
    CHECK(run(K, H2, NULL, NULL, choice_of("cloud", ch2), NULL, READABLE) == 0 && same(p, "l2"), "the player chooses the cloud's: the iPhone's comes in");
    CHECK(kept(K, "local", "game.dat", "k2"), "and the Mac's is kept");

    printf("(27) a front end that asks, after another folder was picked, this device's save changed too\n");
    char K3[1200], L3[1200], H3[1200], H4[1200], ch3[1400], ch4[1400], logk3[1400];
    snprintf(K3, sizeof K3, "%s/mac9/save", root); snprintf(L3, sizeof L3, "%s/iphone7/save", root); mkd(K3); mkd(L3);
    snprintf(H3, sizeof H3, "%s/iCloud Drive/Eleventh Saves", root); snprintf(H4, sizeof H4, "%s/iCloud Drive/Twelfth Saves", root); mkd(H3); mkd(H4);
    snprintf(ch3, sizeof ch3, "%s/%s/save.dmsync", H3, id); snprintf(ch4, sizeof ch4, "%s/%s/save.dmsync", H4, id); snprintf(logk3, sizeof logk3, "%s/ask2.log", root);
    snprintf(p, sizeof p, "%s/game.dat", K3); put(p, "k6");
    CHECK(session(K3, H3, NULL, NULL) == 0 && cloud_has(ch3, root, "game.dat", "k6"), "the Mac is in step with a folder");
    put(p, "k7"); set_mtime(p, time(NULL) - 5000);
    snprintf(q, sizeof q, "%s/game.dat", L3); put(q, "q6");
    CHECK(session(L3, H4, NULL, NULL) == 0 && cloud_has(ch4, root, "game.dat", "q6"), "an iPhone sends a newer save to another folder");
    CHECK(!save_sync_report(K3, DM_GAME_ID, H4, 0, line, sizeof line) && strstr(line, "conflict=1"), "the Mac's launcher reports a conflict for that folder (%s)", line);
    g_log = logk3;
    CHECK(run(K3, H4, NULL, NULL, "ask", NULL, READABLE) == NOT_SENT && same(p, "k7") && cloud_has(ch4, root, "game.dat", "q6") && !backups(K3, "local") && !backups(K3, "cloud"),
          "the Mac, its save changed since, picks the iPhone's folder with \"ask\": neither replaces the other");
    g_log = NULL;
    CHECK(count_in(logk3, "neither replaces the other") == 1, "the log says both changed");
    pass_on(logk3);
    CHECK(run(K3, H4, NULL, NULL, choice_of("local", ch4), NULL, READABLE) == 0 && same(p, "k7") && cloud_has(ch4, root, "game.dat", "k7"),
          "the player chooses this one, the older: it goes out");
    CHECK(kept(K3, "cloud", "game.dat", "q6"), "and the iPhone's save it replaced is kept on the Mac");

    printf("(28) the same folder through a link\n");
    char M10[1200], N10[1200], Hs[1200], Hl[1200], chs[1400], chl[1400], logl[1400], hide[1500];
    snprintf(M10, sizeof M10, "%s/mac10/save", root); snprintf(N10, sizeof N10, "%s/ipad10/save", root); mkd(M10); mkd(N10);
    snprintf(Hs, sizeof Hs, "%s/iCloud Drive/Thirteenth Saves", root); snprintf(Hl, sizeof Hl, "%s/Linked Saves", root); mkd(Hs);
    snprintf(chs, sizeof chs, "%s/%s/save.dmsync", Hs, id); snprintf(chl, sizeof chl, "%s/%s/save.dmsync", Hl, id); snprintf(logl, sizeof logl, "%s/link.log", root);
    snprintf(p, sizeof p, "%s/game.dat", M10); put(p, "m1");
    CHECK(session(M10, Hs, NULL, NULL) == 0 && cloud_has(chs, root, "game.dat", "m1"), "the Mac is in step with a folder");
    snprintf(q, sizeof q, "%s/game.dat", N10);
    CHECK(session(N10, Hs, NULL, NULL) == 0 && same(q, "m1") && session(N10, Hs, "game.dat", "n2") == 0 && cloud_has(chs, root, "game.dat", "n2"), "an iPad takes it in, saves n2 and sends it");
    set_mtime(p, time(NULL) + 1000);   // a newer date, the same save: only the cloud's changed
    CHECK(!symlink(Hs, Hl), "a link to that folder, another spelling of it (as /var is of /private/var, or a bookmark's resolved path)");
    CHECK(!save_sync_report(M10, DM_GAME_ID, Hl, 0, line, sizeof line) && strstr(line, "conflict=0"), "the Mac's launcher reports the folder through the link: no conflict (%s)", line);
    g_log = logl;
    CHECK(session(M10, Hl, NULL, NULL) == 0 && same(p, "n2"), "the Mac starts with the folder through the link: its base still counts, only the cloud's changed, so the iPad's comes in");
    g_log = NULL;
    CHECK(count_in(logl, "last synced with") == 0, "and no line about another folder");
    pass_on(logl);

    printf("(29) the Mac launcher after a start that found the cloud in step, its file then not seen\n");
    CHECK(mount_only(M10, Hl) == 0, "the host mounts the save, in step with the cloud, and ends");
    snprintf(hide, sizeof hide, "%s.hidden", chs);
    CHECK(!rename(chs, hide), "the cloud's file is not seen (an iCloud Drive that has not listed another device's new upload yet)");
    setenv("DM_SAVE_SYNC", Hl, 1);
    CHECK(save_sync_after_exit(M10, DM_GAME_ID) == 1 && !exists(chs), "the launcher's send after it sends nothing: its mount found no push to make (no mark)");
    unsetenv("DM_SAVE_SYNC");
    rename(hide, chs);
    snprintf(want, sizeof want, "%s.sync-tmp", M10); CHECK(!exists(want), "and nothing is left beside the save");

    printf("(30) the sender's pacing in play\n");
    char S30[1200], C30[1200], cf30[1400], log30[1400], T31[1200], O31[1200];
    snprintf(S30, sizeof S30, "%s/pace/save", root); snprintf(C30, sizeof C30, "%s/iCloud Drive/Paced Saves", root); mkd(S30); mkd(C30);
    snprintf(cf30, sizeof cf30, "%s/%s/save.dmsync", C30, id); snprintf(log30, sizeof log30, "%s/pace.log", root);
    snprintf(p, sizeof p, "%s/game.dat", S30); put(p, "p0");
    CHECK(session(S30, C30, NULL, NULL) == 0 && cloud_has(cf30, root, "game.dat", "p0"), "a device in step with the cloud");
    g_log = log30;
    int pr = paced(S30, C30, cf30, root);
    g_log = NULL;
    CHECK(!(pr & 7), "the session's first send goes after the quiet wait (code %#x)", pr);
    CHECK(!(pr & 8), "a second Commit is held inside the gap, though the game has been quiet for long");
    CHECK(!(pr & 16), "and goes once the gap since the first send is over");
    CHECK(!(pr & 32), "the in-game menu opening sends at once, inside the gap");
    CHECK(!(pr & 64), "and so does a flush (the app going to the background)");
    CHECK(!(pr & 128), "the sends after the first do not read the cloud's file again: it is still this device's own last send");
    CHECK(count_in(log30, "not read again") == 3 && count_in(log30, "at once: the in-game menu opened") == 1 && count_in(log30, "at once: a flush") == 1,
          "the log says so, and what sent them at once");
    CHECK(same(p, "p5") && cloud_has(cf30, root, "game.dat", "p4"), "killed right after its last Commit: the local save is whole (p5), the cloud's one send behind (p4)");
    pass_on(log30); g_log = log30;
    CHECK(session(S30, C30, NULL, NULL) == 0 && cloud_has(cf30, root, "game.dat", "p5") && same(p, "p5"), "the next start sends it");
    g_log = NULL;
    CHECK(count_in(log30, "changed since the last sync: it goes to the cloud") == 1 && !backups(S30, "cloud") && !backups(S30, "local"),
          "as the only one that changed: no conflict, nothing kept aside");
    pass_on(log30);

    printf("(31) the cloud's file replaced by another device's after this device's send\n");
    snprintf(T31, sizeof T31, "%s/pace2/save", root); snprintf(O31, sizeof O31, "%s/other31/save", root); mkd(T31); mkd(O31);
    snprintf(p, sizeof p, "%s/game.dat", O31); put(p, "other");
    snprintf(p, sizeof p, "%s/game.dat", T31); put(p, "q0");
    CHECK(session(T31, C30, NULL, NULL) == 0 && cloud_has(cf30, root, "game.dat", "q0"), "another device in step with the same cloud file");
    g_log = log30;
    int rr = replaced(T31, C30, cf30, root, O31);
    g_log = NULL;
    CHECK(!(rr & 7), "it sends q1, then another device's save takes the file's place (code %#x)", rr);
    CHECK(!(rr & 8) && cloud_has(cf30, root, "game.dat", "other"), "its next send does not replace that save: not in step, the next start decides");
    CHECK(!(rr & 16) && count_in(log30, "not read again") == 0, "the new file was read, not taken for this device's own");
    pass_on(log30);

    printf("(32) a quit through exit() inside the gap\n");
    char U32[1200]; snprintf(U32, sizeof U32, "%s/quit/save", root); mkd(U32);
    snprintf(p, sizeof p, "%s/game.dat", U32); put(p, "r0"); set_mtime(p, time(NULL) + 100);
    CHECK(session(U32, C30, NULL, NULL) == 0 && cloud_has(cf30, root, "game.dat", "r0"), "a device in step with the cloud (its newer save went out)");
    g_log = log30;
    int qr = quit_in_gap(U32, C30, cf30, root);
    g_log = NULL;
    CHECK(!qr && same(p, "r2"), "a start sends r1, commits r2 inside a long gap and quits (code %#x)", qr);
    CHECK(cloud_has(cf30, root, "game.dat", "r2") && count_in(log30, "at once: the game is ending") == 1, "the quit sent r2 before the process ended");
    pass_on(log30);

    printf("(33) a flush while the send it would ask for is under way\n");
    char V33[1200]; snprintf(V33, sizeof V33, "%s/soon/save", root); mkd(V33);
    snprintf(p, sizeof p, "%s/game.dat", V33); put(p, "s0"); set_mtime(p, time(NULL) + 200);
    CHECK(session(V33, C30, NULL, NULL) == 0 && cloud_has(cf30, root, "game.dat", "s0"), "a device in step with the cloud (its newer save went out)");
    g_log = log30;
    int sr = soon_then_flush(V33, C30, cf30, root);
    g_log = NULL;
    CHECK(!(sr & 3), "a start sends s1, then commits inside a long gap (code %#x)", sr);
    CHECK(!(sr & 4) && !(sr & 8), "a flush during the send save_sync_soon started waits for it: s2 in the cloud after one pass, not a second clone and pack");
    CHECK(!(sr & 16) && !(sr & 32), "when that send fails, the flush sends once more of its own: s3 in the cloud after two passes");
    CHECK(count_in(log30, "at once: the game lost focus") == 1 && count_in(log30, "at once: a flush") == 1, "the sends say what sent them at once");
    pass_on(log30);

    printf("(34) another device's file put in place right after this device's store\n");
    char W34[1200], O34[1200]; snprintf(W34, sizeof W34, "%s/swap/save", root); snprintf(O34, sizeof O34, "%s/other34/save", root); mkd(W34); mkd(O34);
    snprintf(p, sizeof p, "%s/game.dat", O34); put(p, "other");
    snprintf(p, sizeof p, "%s/game.dat", W34); put(p, "t0"); set_mtime(p, time(NULL) + 300);
    CHECK(session(W34, C30, NULL, NULL) == 0 && cloud_has(cf30, root, "game.dat", "t0"), "a device in step with the cloud (its newer save went out)");
    g_log = log30;
    int wr = swapped_after_store(W34, C30, cf30, root, O34);
    g_log = NULL;
    CHECK(!(wr & 7), "it sends t1 (code %#x)", wr);
    CHECK(!(wr & 8) && !(wr & 16), "t2's store goes through, and another device's save takes the file's place right after");
    CHECK(!(wr & 32) && cloud_has(cf30, root, "game.dat", "other"), "t3's send does not replace that save: not in step, the next start decides");
    CHECK(!(wr & 64), "that file was read, not taken for this device's own by the identity noted after t2's store");
    pass_on(log30);

    printf("(35) moving this game's cloud save between two folders (save_sync_move, gate-ui §21.4)\n");
    char M35[1200], O35[1200], OWN[1200], NXF[1200], X35[1200], cown[1400], cnx[1400], cx[1400], mout[160];
    snprintf(M35, sizeof M35, "%s/mover/save", root); snprintf(O35, sizeof O35, "%s/other35/save", root); mkd(M35); mkd(O35);
    snprintf(OWN, sizeof OWN, "%s/iCloud Drive/Own Saves", root); snprintf(NXF, sizeof NXF, "%s/iCloud Drive/NX 18", root); snprintf(X35, sizeof X35, "%s/iCloud Drive/NX 18 B", root);
    mkd(OWN); mkd(NXF); mkd(X35);
    snprintf(cown, sizeof cown, "%s/%s/save.dmsync", OWN, id); snprintf(cnx, sizeof cnx, "%s/%s/save.dmsync", NXF, id); snprintf(cx, sizeof cx, "%s/%s/save.dmsync", X35, id);
    snprintf(p, sizeof p, "%s/game.dat", M35); put(p, "m1");
    CHECK(session(M35, OWN, NULL, NULL) == 0 && cloud_has(cown, root, "game.dat", "m1"), "a game in step with its own folder");
    CHECK(save_sync_move(M35, OWN, NXF, DM_GAME_ID, SS_MOVE_ASK_FIRST, 0, mout, sizeof mout) == SS_MOVE_DONE, "a move into an empty NX 18 folder goes through");
    CHECK(cloud_has(cnx, root, "game.dat", "m1") && cloud_has(cown, root, "game.dat", "m1"), "the save is in the NX 18 folder, and the old copy stays");
    CHECK(save_sync_move(M35, OWN, NXF, DM_GAME_ID, SS_MOVE_ASK_FIRST, 0, mout, sizeof mout) == SS_MOVE_DONE, "again, with the same save there: done, nothing asked");
    CHECK(save_sync_move(M35, OWN, OWN, DM_GAME_ID, SS_MOVE_ASK_FIRST, 0, mout, sizeof mout) == SS_MOVE_SAME, "the same folder: only the mode changes");
    snprintf(p, sizeof p, "%s/game.dat", O35); put(p, "o1"); set_mtime(p, time(NULL) - 5000);
    CHECK(session(O35, X35, NULL, NULL) == 0 && cloud_has(cx, root, "game.dat", "o1"), "another device's save is in a second NX 18 folder");
    CHECK(save_sync_move(M35, OWN, X35, DM_GAME_ID, SS_MOVE_ASK_FIRST, 0, mout, sizeof mout) == SS_MOVE_ASK && strstr(mout, "from_saved=") && strstr(mout, "to_saved="),
          "a move onto another save of this game asks first (%s)", mout);
    CHECK(cloud_has(cx, root, "game.dat", "o1"), "and changes nothing while it asks");
    CHECK(save_sync_move(M35, OWN, X35, DM_GAME_ID, SS_MOVE_USE_THERE, 0, mout, sizeof mout) == SS_MOVE_DONE && cloud_has(cx, root, "game.dat", "o1"), "use the one there: nothing copied");
    int before = backups(M35, "cloud");
    CHECK(save_sync_move(M35, OWN, X35, DM_GAME_ID, SS_MOVE_REPLACE, 0, mout, sizeof mout) == SS_MOVE_DONE && cloud_has(cx, root, "game.dat", "m1"), "replace: this save goes there");
    CHECK(backups(M35, "cloud") == before + 1 && kept(M35, "cloud", "game.dat", "o1"), "and the one there is kept first, in the cloud side's backups");
    char aside35[1500]; snprintf(aside35, sizeof aside35, "%s.aside", cown);
    CHECK(!rename(cown, aside35) && (mkd(cown), 1), "the folder it leaves cannot be read (a folder where the file is)");
    CHECK(save_sync_move(M35, OWN, NXF, DM_GAME_ID, SS_MOVE_REPLACE, 0, mout, sizeof mout) == SS_MOVE_FAIL && cloud_has(cnx, root, "game.dat", "m1"), "then nothing moves, and nothing changes");
    rmdir(cown); rename(aside35, cown);
    snprintf(p, sizeof p, "%s/Empty", root); mkd(p);
    CHECK(save_sync_move(M35, p, NXF, DM_GAME_ID, SS_MOVE_ASK_FIRST, 0, mout, sizeof mout) == SS_MOVE_DONE && cloud_has(cnx, root, "game.dat", "m1"),
          "a folder it leaves with no save: only the folder changes");

    printf("== save sync: %d checks, %d failed ==\n", checks, fails);
    if (!fails) { char c[1200]; snprintf(c, sizeof c, "rm -rf '%s'", root); system(c); }
    return fails != 0;
}
