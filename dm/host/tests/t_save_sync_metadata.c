// Exercise the real metadata writer with stdio failures, and the real pull (the cloud's save swapped in) with rename failures, without cloud or game files.
// pull: every step that can fail, failing: this device's save stays whole and nowhere but in place or in its backups, and the staging folder (cleared at every
// start) never holds this device's save, also while a pull that succeeds is between two steps (the app killed there).
// The journal (<save>.pull): the app killed after each rename or swap of a pull (a longjmp out of it, nothing undone), with this device's folders holding a save, empty or
// absent, then the next start's mount (sync off): this device's save is back as it was, the cloud's gone, the journal removed; killed again in the middle of that recovery,
// the next one finishes it. A recovery that fails refuses the mount and keeps the journal, and the start after it recovers; an unreadable journal refuses the mount; a
// second mount gets the first's answer. Older backups are pruned only when a pull completes, and nothing is sent after the host while a journal is pending.
// The metadata file's format both ways: what an older build reads of a file this one writes (its reader, copied below), and what this one reads of an older build's
// file (no cloud line). The save size records (upstream 60f0fe506) through the pull, its journal and the recovery (size_record_cases).
#include <errno.h>
#include <setjmp.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/xattr.h>
#include <unistd.h>

static int fail_open, fail_write, fail_close, fail_rename, cleanup_errno;
static int closes, renames, unlinks, metadata_fd;
static FILE *metadata;
static char diagnostic[2048];

static FILE *test_fopen(const char *path, const char *mode) {
    if (!strcmp(mode, "w")) {
        if (fail_open) { errno = EACCES; return NULL; }
        metadata = fopen(path, mode);
        if (metadata) metadata_fd = fileno(metadata);
        return metadata;
    }
    return fopen(path, mode);
}
static int test_fprintf(FILE *f, const char *fmt, ...) {
    if (f == metadata && fail_write) { errno = ENOSPC; return -1; }
    va_list ap; va_start(ap, fmt);
    int r = f == stderr ? vsnprintf(diagnostic, sizeof diagnostic, fmt, ap) : vfprintf(f, fmt, ap);
    va_end(ap); return r;
}
static int test_fclose(FILE *f) {
    int tracked = f == metadata;
    if (tracked) { closes++; metadata = NULL; }
    int r = fclose(f);
    if (tracked && fail_close) { errno = EIO; return EOF; }
    return r;
}
// A pull's fault: the call (1 rename, 2 renamex_np) whose from and to end so fails with EIO, after `skip` such calls succeeded; up to two at once
static struct fault { int op; const char *from, *to; int skip; } faults[2];
static char staging[PATH_MAX];   // <save>.sync-tmp: after every rename and swap of a pull, it must hold nothing of this device's save
static int staging_held;
static int ends(const char *s, const char *suffix) { size_t a = strlen(s), b = strlen(suffix); return a >= b && !strcmp(s + a - b, suffix); }
static int faulted(int op, const char *from, const char *to) {
    for (int i = 0; i < 2; i++) {
        struct fault *f = &faults[i];
        if (f->op != op || !ends(from, f->from) || !ends(to, f->to)) continue;
        if (f->skip-- > 0) continue;
        f->op = 0; errno = EIO; return 1;
    }
    return 0;
}
static int holds(const char *dir, const char *text);
// The app killed: after `crash_after` more renames and swaps succeed, the next one's caller never comes back (crash_jmp)
static int crash_after = -1; static jmp_buf crash_jmp;
static void crash_point(void) { if (crash_after > 0 && !--crash_after) { crash_after = -1; longjmp(crash_jmp, 1); } }
static int test_rename(const char *from, const char *to) {
    renames++;
    if (fail_rename) { errno = EROFS; return -1; }
    if (faulted(1, from, to)) return -1;
    int r = rename(from, to);
    if (*staging && holds(staging, "original")) staging_held = 1;
    if (!r) crash_point();
    return r;
}
static int fail_stage_publish;   // the next publish of a cloud backup's staging fails (backup_cloud_restore)
static int test_renamex_np(const char *from, const char *to, unsigned flags) {
    if (fail_stage_publish && strstr(from, "/.cloud-stage.")) { fail_stage_publish = 0; errno = EIO; return -1; }
    if (faulted(2, from, to)) return -1;
    int r = renamex_np(from, to, flags);
    if (*staging && holds(staging, "original")) staging_held = 1;
    if (!r) crash_point();
    return r;
}
static const char *fail_xattr_suffix; static int fail_xattr_errno;
static ssize_t test_getxattr(const char *path, const char *name, void *value, size_t size, u_int32_t position, int options) {
    if (fail_xattr_suffix && ends(path, fail_xattr_suffix)) { errno = fail_xattr_errno; return -1; }
    return getxattr(path, name, value, size, position, options);
}
static int test_unlink(const char *path) {
    unlinks++;
    int r = unlink(path);
    if (cleanup_errno) errno = cleanup_errno;
    return r;
}
#define fopen test_fopen
#define fprintf test_fprintf
#define fclose test_fclose
#define rename test_rename
#define unlink test_unlink
#define renamex_np test_renamex_np
#define getxattr test_getxattr
#include "../save_sync.c"
#undef fopen
#undef fprintf
#undef fclose
#undef rename
#undef unlink
#undef renamex_np
#undef getxattr

static int checks, failures;
#define CHECK(c, label) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL: %s (%s)\n", name, label); } } while (0)
static const char old_hash[] = "00000000000000000000000000000000";
static const char new_hash[] = "123456789abcdef0123456789abcdef0";
static const char cloud[] = "/Users/p/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves/0100ABC/save.dmsync";

// The reader of the build before the cloud line (fa92bb0e save_sync.c), as it is: an older build on another device, or this one's app before an update
// (NX 18 before the port of the cloud line, b545929f's save_sync.c, has this very reader too, as did the earlier port's base, a1057c2d)
static void older_build_read_base(const char *save, char *out) {   // <save>.sync: the hash of the save last known to be the same here and in the cloud ("" for none)
    char p[PATH_MAX], ln[128]; out[0] = 0;
    snprintf(p, sizeof p, "%s.sync", save);
    FILE *f = fopen(p, "r"); if (!f) return;
    while (fgets(ln, sizeof ln, f)) if (!strncmp(ln, "base\t", 5) && strspn(ln + 5, "0123456789abcdef") == SS_HASH) { memcpy(out, ln + 5, SS_HASH); out[SS_HASH] = 0; }
    fclose(f);
}
static void put_sync(const char *save, const char *text) {   // a <save>.sync as another build left it
    char path[PATH_MAX]; snprintf(path, sizeof path, "%s.sync", save);
    FILE *f = fopen(path, "w"); if (!f || fputs(text, f) < 0 || fclose(f)) abort();
}

static void run_case(const char *save, const char *name, int open_error, int write_error,
                     int close_error, int rename_error, int expected_errno) {
    char path[PATH_MAX], temp[PATH_MAX + 8]; sync_state st;
    snprintf(path, sizeof path, "%s.sync", save);
    snprintf(temp, sizeof temp, "%s.tmp", path);
    FILE *f = fopen(path, "w");
    if (!f || fprintf(f, "base\t%s\n", old_hash) < 0 || fclose(f)) abort();
    fail_open = open_error; fail_write = write_error; fail_close = close_error; fail_rename = rename_error;
    cleanup_errno = EBUSY; // Cleanup must not replace the original diagnostic.
    closes = renames = unlinks = 0; metadata_fd = -1; metadata = NULL; diagnostic[0] = 0;
    write_base(save, new_hash, cloud);
    CHECK(closes == !open_error, "every opened stream is closed exactly once");
    if (!open_error) CHECK(fcntl(metadata_fd, F_GETFD) == -1 && errno == EBADF, "file descriptor is closed");
    CHECK(renames == !(open_error || write_error || close_error), "rename only follows successful write and close");
    CHECK(unlinks == (!!expected_errno && !open_error), "failed temporary file is removed");
    if (expected_errno) {
        char error[40]; snprintf(error, sizeof error, "(errno=%d)", expected_errno);
        CHECK(strstr(diagnostic, error) != NULL, "first error is reported after cleanup");
    } else CHECK(!diagnostic[0], "success has no error diagnostic");
    CHECK(access(temp, F_OK) == -1 && errno == ENOENT, "no temporary file remains");
    // Keep the failing implementation's leaked stream from affecting later cases.
    if (metadata) { fclose(metadata); metadata = NULL; }
    read_base(save, &st);
    CHECK(!strcmp(st.base, expected_errno ? old_hash : new_hash), "failed updates preserve previous metadata; success replaces it");
    CHECK(expected_errno ? !st.named && !st.cloud[0] : st.named && !strcmp(st.cloud, cloud), "the cloud file comes with the base, and only with a write that went through");
}

static void formats(const char *save) {
    const char *name = "formats"; char old[SS_HASH + 1], text[3 * PATH_MAX]; sync_state st;
    write_base(save, new_hash, cloud);
    older_build_read_base(save, old); read_base(save, &st);
    CHECK(!strcmp(old, new_hash), "an older build reads this one's base");
    CHECK(!strcmp(st.base, new_hash) && st.named && !strcmp(st.cloud, cloud), "this one reads its base and cloud file back");
    put_sync(save, "# save sync (dm/host/save_sync.h): the save last known to be the same here and in the cloud\nbase\t123456789abcdef0123456789abcdef0\n");
    read_base(save, &st);
    CHECK(!strcmp(st.base, new_hash) && !st.named && !st.cloud[0], "an older build's file: its base, and no cloud file named");
    put_sync(save, "base\t123456789abcdef0123456789abcdef0\nlater\tsomething a newer build knows\ncloud\t/c/save.dmsync\n");
    read_base(save, &st);
    CHECK(!strcmp(st.base, new_hash) && st.named && !strcmp(st.cloud, "/c/save.dmsync"), "a line it does not know is skipped");
    // A cloud path with a base line's text where the older reader's 127-byte pieces begin: the real base line comes after it, and the last one read is the base
    char path[PATH_MAX]; size_t k = 0;
    k += (size_t)snprintf(path + k, sizeof path - k, "/x");
    while (k < 2 * 127 - 6) path[k++] = 'a';
    path[k] = 0; snprintf(path + k, sizeof path - k, "base\t%s/save.dmsync", old_hash);
    write_base(save, new_hash, path);
    older_build_read_base(save, old); read_base(save, &st);
    CHECK(!strcmp(old, new_hash), "an older build is not misled by a long cloud path");
    CHECK(!strcmp(st.base, new_hash) && !strcmp(st.cloud, path), "this one reads the long path whole");
    memset(text, 'p', sizeof text); memcpy(text, "cloud\t/", 7); memcpy(text + sizeof text - 50, "\nbase\t123456789abcdef0123456789abcdef0\n", 40); text[sizeof text - 10] = 0;
    put_sync(save, text);
    read_base(save, &st);
    CHECK(!strcmp(st.base, new_hash) && st.named && !st.cloud[0], "a cloud line longer than any path names no cloud file this build can have");
    // The rule the mount and the launchers' report decide with (base_for): the base counts for the file it names, for a cloud file holding that very save, and when no
    // file is named (an older build's); for another folder's file, not at all
    write_base(save, new_hash, cloud); read_base(save, &st);
    CHECK(!strcmp(base_for(&st, cloud, ""), new_hash), "the base counts for the file it names");
    CHECK(!*base_for(&st, "/other/0100ABC/save.dmsync", old_hash) && !*base_for(&st, "/other/0100ABC/save.dmsync", ""), "not for another folder's file");
    CHECK(!strcmp(base_for(&st, "/other/0100ABC/save.dmsync", new_hash), new_hash), "but for another file that holds that very save");
    put_sync(save, "base\t123456789abcdef0123456789abcdef0\n"); read_base(save, &st);
    CHECK(!strcmp(base_for(&st, "/other/0100ABC/save.dmsync", old_hash), new_hash), "an older build's base counts as it did there");
}
// Any file under dir whose contents start with text
static int holds(const char *dir, const char *text) {
    char **v; size_t n; int k = 0; struct stat st;
    if (lstat(dir, &st)) return 0;
    if (!S_ISDIR(st.st_mode)) { char b[64] = {0}; FILE *f = fopen(dir, "r"); if (!f) return 0; fread(b, 1, sizeof b - 1, f); fclose(f); return !strncmp(b, text, strlen(text)); }
    if (names_of(dir, &v, &n)) return 0;
    for (size_t i = 0; i < n; i++) { char c[PATH_MAX]; snprintf(c, sizeof c, "%s/%s", dir, v[i]); k += holds(c, text); }
    free_names(v, n); return k;
}
static int is(const char *path, const char *text) {
    char b[64] = {0}; FILE *f = fopen(path, "r"); if (!f) return 0; size_t k = fread(b, 1, sizeof b - 1, f); fclose(f);
    return k == strlen(text) && !memcmp(b, text, k);
}
static void put(const char *path, const char *text) { FILE *f = fopen(path, "w"); if (!f || fputs(text, f) < 0 || fclose(f)) abort(); }
// The cloud's save, packed: save/a "cloud 0" and, with device, save_device/b "cloud 1"
static void cloud_bundle(const char *root, int device, char *out, size_t n) {
    char src[PATH_MAX], p[PATH_MAX]; ss_meta m;
    snprintf(src, sizeof src, "%s/cloud%d", root, device); mkdirs(src);
    snprintf(p, sizeof p, "%s/a", src); put(p, "cloud 0");
    if (device) { snprintf(p, sizeof p, "%s_device", src); mkdirs(p); snprintf(p, sizeof p, "%s_device/b", src); put(p, "cloud 1"); }
    snprintf(out, n, "%s/cloud%d.dmsync", root, device);
    if (ss_pack(src, "0100000000010000", out, &m)) abort();
}
// One pull onto this device's save/a "original 0" and save_device/b "original 1", with up to two faults; want: pull's answer.
// device_cloud: the cloud's save has save_device. After it: what is in place, where this device's save is, what is left behind
static void pull_case(const char *root, const char *name, const char *bundle, int device_cloud, struct fault f0, struct fault f1, int want) {
    char save[PATH_MAX], dev[PATH_MAX], p[PATH_MAX], kept[PATH_MAX], backups[PATH_MAX]; ss_meta m;
    snprintf(save, sizeof save, "%s/save", root); snprintf(dev, sizeof dev, "%s/save_device", root); snprintf(backups, sizeof backups, "%s-backups", save);
    rm_tree(save); rm_tree(dev); rm_tree(backups); mkdirs(save); mkdirs(dev);
    snprintf(p, sizeof p, "%s/a", save); put(p, "original 0"); snprintf(p, sizeof p, "%s/b", dev); put(p, "original 1");
    for (int k = 0; k < KEEP_BACKUPS; k++) { snprintf(p, sizeof p, "%s/2000-01-01 00.00.%02d local", backups, k); mkdirs(p); snprintf(p, sizeof p, "%s/2000-01-01 00.00.%02d local/a", backups, k); put(p, "older"); }   // the most a side keeps
    snprintf(staging, sizeof staging, "%s.sync-tmp", save); staging_held = 0;
    faults[0] = f0; faults[1] = f1;
    int r = pull(save, bundle, &m, kept, sizeof kept), e = errno;
    *staging = 0;
    CHECK(r == want, "pull's answer");
    CHECK(!faults[0].op && !faults[1].op, "every fault was reached");
    CHECK(!staging_held, "the staging folder never held this device's save");
    snprintf(p, sizeof p, "%s.sync-tmp/in", save);
    CHECK(access(p, F_OK) == -1 && errno == ENOENT, "the staging folder is cleared");
    CHECK(holds(root, "original 0") == 1 && holds(root, "original 1") == 1, "this device's save is there once, nothing lost or copied");
    CHECK(holds(save, "original 0") + holds(backups, "original 0") == 1 && holds(dev, "original 1") + holds(backups, "original 1") == 1,
          "this device's save is in place or in its backups");
    if (want) CHECK(r == -2 || e == EIO, "the first failure's errno");
    if (want == -1) {
        snprintf(p, sizeof p, "%s/a", save); CHECK(is(p, "original 0"), "a failed pull leaves this device's save in place");
        snprintf(p, sizeof p, "%s/b", dev); CHECK(is(p, "original 1"), "a failed pull leaves this device's device save in place");
        CHECK(!holds(backups, "cloud"), "no cloud file is left in the backups");
        CHECK(access(kept, F_OK) == -1, "the empty backup folder is removed");
        CHECK(holds(backups, "older") == KEEP_BACKUPS, "a failed pull removes no older backup");
    } else if (!want) {
        snprintf(p, sizeof p, "%s/a", save); CHECK(is(p, "cloud 0"), "the cloud's save is in place");
        snprintf(p, sizeof p, "%s/b", dev); CHECK(device_cloud ? is(p, "cloud 1") : access(p, F_OK) == -1, "the cloud's device save is in place, or none when it has none");
        snprintf(p, sizeof p, "%s/save/a", kept); CHECK(is(p, "original 0"), "this device's save is kept in the backup pull names");
        snprintf(p, sizeof p, "%s/save_device/b", kept); CHECK(is(p, "original 1"), "this device's device save is kept in the backup pull names");
        snprintf(p, sizeof p, "%s/2000-01-01 00.00.00 local", backups);
        CHECK(holds(backups, "older") == KEEP_BACKUPS - 1 && access(p, F_OK) == -1, "a pull that succeeds keeps the newest KEEP_BACKUPS, its own among them");
    } else {
        CHECK(*kept && holds(kept, "original"), "the backup pull names holds what is not in place");
        CHECK(holds(backups, "older") == KEEP_BACKUPS, "a pull that cannot put the save back removes no older backup");
    }
}
// This device's save folder cannot be listed (EACCES here; EMFILE or ENOMEM on a device): never taken for "no save". ss_scan fails (the mount turns sync off), and a
// pull fails before anything moves: before 2026-11-11, has_entries said empty, ss_decide pulled, and pull swapped the real folder into the staging folder and cleared it
static void unreadable_case(const char *root) {
    const char *name = "this device's save folder cannot be listed";
    char save[PATH_MAX], dev[PATH_MAX], p[PATH_MAX], kept[PATH_MAX], backups[PATH_MAX], bundle[PATH_MAX]; ss_meta m;
    snprintf(save, sizeof save, "%s/save", root); snprintf(dev, sizeof dev, "%s/save_device", root); snprintf(backups, sizeof backups, "%s-backups", save);
    rm_tree(save); rm_tree(dev); rm_tree(backups); mkdirs(save);
    snprintf(p, sizeof p, "%s/a", save); put(p, "original 0");
    cloud_bundle(root, 0, bundle, sizeof bundle);
    if (chmod(save, 0)) abort();
    DIR *probe = opendir(save);
    if (probe) { closedir(probe); chmod(save, 0755); fprintf(stderr, "skipped: %s (this user can list a folder with no permissions)\n", name); return; }
    CHECK(ss_scan(save, &m) != 0, "ss_scan fails: the mount turns sync off, it does not decide on an empty save");
    int r = pull(save, bundle, &m, kept, sizeof kept);
    chmod(save, 0755);
    CHECK(r == -1, "pull fails before anything moves");
    snprintf(p, sizeof p, "%s/a", save); CHECK(is(p, "original 0"), "this device's save stays in place");
    CHECK(access(backups, F_OK) == -1, "no backup folder is made");
    snprintf(p, sizeof p, "%s.sync-tmp/in", save); CHECK(access(p, F_OK) == -1, "the staging folder is cleared");
    snprintf(p, sizeof p, "%s.pull", save); CHECK(access(p, F_OK) == -1, "no journal is written");
    rm_tree(save); rm_tree(backups);
}
// This device's save before a pull: save/a "original 0", and the device folder as `dev_had` says (HAD_SAVE: save_device/b "original 1", HAD_EMPTY: an empty folder, HAD_NONE: none)
static void device_save(const char *root, int dev_had) {
    char save[PATH_MAX], dev[PATH_MAX], p[PATH_MAX];
    snprintf(save, sizeof save, "%s/save", root); snprintf(dev, sizeof dev, "%s/save_device", root);
    rm_tree(save); rm_tree(dev); snprintf(p, sizeof p, "%s-backups", save); rm_tree(p); snprintf(p, sizeof p, "%s.pull", save); unlink(p);
    mkdirs(save); snprintf(p, sizeof p, "%s/a", save); put(p, "original 0");
    if (dev_had != HAD_NONE) mkdirs(dev);
    if (dev_had == HAD_SAVE) { snprintf(p, sizeof p, "%s/b", dev); put(p, "original 1"); }
}
// This device's save as device_save made it, and nothing of the cloud's anywhere under root but the bundles
static int as_before(const char *root, int dev_had) {
    char p[PATH_MAX], dev[PATH_MAX], **v; size_t n; int ok = 1;
    snprintf(p, sizeof p, "%s/save/a", root); ok &= is(p, "original 0");
    snprintf(p, sizeof p, "%s/save", root); if (!names_of(p, &v, &n)) { ok &= n == 1; free_names(v, n); } else ok = 0;
    snprintf(dev, sizeof dev, "%s/save_device", root);
    if (dev_had == HAD_SAVE) { snprintf(p, sizeof p, "%s/b", dev); ok &= is(p, "original 1"); }
    else if (dev_had == HAD_EMPTY) ok &= !access(dev, F_OK) && !has_entries(dev);
    else ok &= access(dev, F_OK) == -1;
    snprintf(p, sizeof p, "%s/save", root); ok &= !holds(p, "cloud") && !holds(dev, "cloud");
    snprintf(p, sizeof p, "%s/save-backups", root); ok &= !holds(p, "cloud") && !holds(p, "original");
    snprintf(p, sizeof p, "%s/save.pull", root); ok &= access(p, F_OK) == -1;
    return ok;
}
static int count_backups(const char *save) {
    char dir[PATH_MAX], **v; size_t n; int k = 0; snprintf(dir, sizeof dir, "%s-backups", save);
    if (names_of(dir, &v, &n)) return 0;
    for (size_t i = 0; i < n; i++) k += is_backup(v[i], "local");
    free_names(v, n); return k;
}
static void journal_cases(const char *root, const char *both, const char *one) {
    char save[PATH_MAX], kept[PATH_MAX], p[PATH_MAX]; ss_meta m; const char *name; struct fault none = {0};
    snprintf(save, sizeof save, "%s/save", root);
    unsetenv("DM_SAVE_SYNC");   // the next start's mount with sync off: the journal is put right whatever the setting
    static const char *had_names[] = {"no device folder", "an empty device folder", "a device save"};
    for (int dev_had = HAD_NONE; dev_had <= HAD_SAVE; dev_had++)
        for (int b = 0; b < 2; b++) {   // the cloud's save with and without a device save
            int steps = 0;
            for (int k = 1; k < 16; k++) {   // killed after k renames and swaps; the first k that is not reached is the pull completing
                device_save(root, dev_had);
                char label[200]; snprintf(label, sizeof label, "killed after %d steps, %s, the cloud's %s a device save", k, had_names[dev_had], b ? "with" : "without"); name = label;
                faults[0] = faults[1] = none; crash_after = k;
                if (!setjmp(crash_jmp)) { int r = pull(save, b ? both : one, &m, kept, sizeof kept); crash_after = -1; CHECK(!r, "an uninterrupted pull completes"); steps = k - 1; break; }
                snprintf(p, sizeof p, "%s.pull", save); CHECK(!access(p, F_OK), "the journal is there after the kill");
                if (k == 3) {   // and killed again in the middle of the recovery: the next start finishes it
                    crash_after = 1; pull_journal j;
                    if (!setjmp(crash_jmp)) { CHECK(journal_read(save, &j) == 1, "the journal reads back"); recover(save, &j); }
                    crash_after = -1;
                }
                CHECK(mount_once(save, "0100000000010000") == 0, "the next start's mount goes on");
                CHECK(as_before(root, dev_had), "this device's save is back as it was, the cloud's gone, the journal removed");
            }
            name = had_names[dev_had]; CHECK(steps >= 2, "a pull has steps to be killed after");
        }
    // A recovery that fails refuses the mount and keeps the journal; the start after it recovers
    name = "a recovery that fails";
    device_save(root, HAD_SAVE); faults[0] = faults[1] = none; crash_after = 3;   // the journal, the cloud's save into the backups, then its swap: the cloud's in place
    if (!setjmp(crash_jmp)) { pull(save, both, &m, kept, sizeof kept); crash_after = -1; CHECK(0, "the pull was killed"); }
    faults[0] = (struct fault){2, "local/save", "/save", 0};   // the swap back fails
    CHECK(mount_once(save, "0100000000010000") == -1, "the mount is refused");
    snprintf(p, sizeof p, "%s.pull", save); CHECK(!access(p, F_OK), "the journal is kept");
    CHECK(holds(root, "original 0") == 1 && holds(root, "original 1") == 1, "this device's save is whole, in place or in its backups");
    CHECK(!faults[0].op, "the fault was reached");
    CHECK(mount_once(save, "0100000000010000") == 0 && as_before(root, HAD_SAVE), "the next start puts it back");
    // An unreadable journal refuses the mount and is left for the player
    name = "an unreadable journal";
    device_save(root, HAD_SAVE); put(p, "not a journal\n");
    CHECK(mount_once(save, "0100000000010000") == -1 && !access(p, F_OK), "the mount is refused, the file left");
    unlink(p);
    // Pruning: a pull that fails keeps the older backups it found; one that completes leaves KEEP_BACKUPS
    name = "pruning";
    device_save(root, HAD_SAVE);
    for (int i = 0; i < KEEP_BACKUPS + 2; i++) { snprintf(p, sizeof p, "%s-backups/2020-01-%02d 00.00.00 local", save, i + 1); mkdirs(p); }
    faults[0] = (struct fault){1, "in/save", "local/save", 0}; faults[1] = none;
    CHECK(pull(save, both, &m, kept, sizeof kept) == -1 && count_backups(save) == KEEP_BACKUPS + 2, "a pull that fails prunes nothing");
    faults[0] = none;
    CHECK(pull(save, both, &m, kept, sizeof kept) == 0 && count_backups(save) == KEEP_BACKUPS, "one that completes leaves the newest KEEP_BACKUPS, its own among them");
    snprintf(p, sizeof p, "%s/save/a", kept); CHECK(is(p, "original 0"), "its own backup is kept");
    // Nothing is sent after the host while a journal is pending: what is in place may be half the cloud's
    name = "send after exit with a journal pending";
    device_save(root, HAD_SAVE); faults[0] = none; crash_after = 3;
    if (!setjmp(crash_jmp)) { pull(save, both, &m, kept, sizeof kept); crash_after = -1; }
    char cloud[PATH_MAX], cf[PATH_MAX]; snprintf(cloud, sizeof cloud, "%s/cloud-folder", root); setenv("DM_SAVE_SYNC", cloud, 1);
    CHECK(save_sync_after_exit(save, "0100000000010000") == 0, "not in step: nothing sent");
    snprintf(cf, sizeof cf, "%s/0100000000010000/save.dmsync", cloud); CHECK(access(cf, F_OK) == -1, "the cloud has no file");
    unsetenv("DM_SAVE_SYNC");
    // The first mount's answer is the second's (the device save mounted after the account save)
    name = "a second mount";
    CHECK(save_sync_mount(save, "0100000000010000") == 0 && as_before(root, HAD_SAVE), "the first mount recovers and goes on");
    device_save(root, HAD_SAVE); snprintf(p, sizeof p, "%s.pull", save); put(p, "not a journal\n");
    CHECK(save_sync_mount(save, "0100000000010000") == 0, "a second mount gets the first's answer, not a new one");
    unlink(p);
}
// dir holds `keep` and nothing else (keep NULL: nothing)
static int holds_only(const char *dir, const char *keep) {
    DIR *d = opendir(dir); struct dirent *e; int ok = d != NULL;
    while (d && (e = readdir(d))) if (e->d_name[0] != '.' && (!keep || strcmp(e->d_name, keep))) ok = 0;
    if (d) closedir(d);
    return ok;
}
static int file_is(const char *path, const char *text) {
    char b[64]; int fd = open(path, O_RDONLY); if (fd < 0) return 0;
    ssize_t n = read(fd, b, sizeof b - 1); close(fd);
    return n >= 0 && (b[n] = 0, !strcmp(b, text));
}
// fetch_timed: a fetch that comes too late (blocked on a FIFO, the default fetch's open) neither writes over nor removes what a later attempt fetched to the same file
static void fetch_cases(const char *folder) {
    const char *name = "late fetch"; char dir[PATH_MAX], fifo[PATH_MAX], src[PATH_MAX], none[PATH_MAX], dst[PATH_MAX];
    snprintf(dir, sizeof dir, "%s/fetch", folder); mkdir(dir, 0755);
    snprintf(fifo, sizeof fifo, "%s/cloud.fifo", folder); snprintf(src, sizeof src, "%s/cloud.dmsync", folder); snprintf(none, sizeof none, "%s/none.dmsync", folder);
    snprintf(dst, sizeof dst, "%s/cloud.dmsync", dir);
    put(src, "newer");
    CHECK(fetch_timed(none, dst, 2000) == 0 && holds_only(dir, NULL), "no cloud file: 0, nothing left");
    CHECK(fetch_timed(src, dst, 2000) == 1 && file_is(dst, "newer") && holds_only(dir, "cloud.dmsync"), "a fetch in time: the file at its place, nothing else");
    test_unlink(dst);
    if (mkfifo(fifo, 0644)) abort();
    CHECK(fetch_timed(fifo, dst, 100) == -1 && holds_only(dir, NULL), "a fetch that does not come in time: -1");
    CHECK(fetch_timed(src, dst, 2000) == 1 && file_is(dst, "newer"), "the next attempt's fetch");
    int w = open(fifo, O_WRONLY); if (w < 0 || write(w, "older", 5) != 5) abort();
    close(w);   // the first fetch goes on now: it copies "older", finds itself dropped and removes its file
    usleep(300 * 1000);
    CHECK(file_is(dst, "newer") && holds_only(dir, "cloud.dmsync"), "the late fetch leaves the later attempt's file as it was and removes only its own");
    test_unlink(dst); test_unlink(src); test_unlink(fifo); rmdir(dir);
}
// The cloud's save kept before this device's replaces it (upstream 7886d3038): unpacked into staging, published whole under a dated name, and only then are older cloud
// backups pruned. A failed publish or unpack costs no backup and leaves no staging; a killed start's staging goes at the next start; the player's own folders stay
static int has_cloud_stage(const char *save) {
    char dir[PATH_MAX], **v; size_t n; int found = 0;
    snprintf(dir, sizeof dir, "%s-backups", save);
    if (names_of(dir, &v, &n)) return 0;
    for (size_t i = 0; i < n; i++) if (!strncmp(v[i], CLOUD_STAGE_PREFIX, sizeof CLOUD_STAGE_PREFIX - 1)) found = 1;
    free_names(v, n); return found;
}
static int cloud_backups(const char *save, int *seeded_ok, int first) {   // the "<date> cloud" backups; *seeded_ok: the seeded ones from `first` on are there with their marks
    char dir[PATH_MAX], **v; size_t n; int c = 0;
    snprintf(dir, sizeof dir, "%s-backups", save); *seeded_ok = 1;
    if (names_of(dir, &v, &n)) return 0;
    for (size_t i = 0; i < n; i++) c += is_backup(v[i], "cloud");
    free_names(v, n);
    for (int i = first; i <= KEEP_BACKUPS; i++) {
        char p[PATH_MAX], want[32]; snprintf(p, sizeof p, "%s/2020-01-%02d 00.00.00 cloud/save/mark.txt", dir, i); snprintf(want, sizeof want, "seeded-%02d", i);
        if (!is(p, want)) *seeded_ok = 0;
    }
    return c;
}
static void cloud_backup_cases(const char *folder) {
    const char *name = "cloud backup staging";
    char root[PATH_MAX], remote[PATH_MAX], local[PATH_MAX], backups[PATH_MAX], bundle[PATH_MAX], p[PATH_MAX], kept[PATH_MAX];
    ss_meta mr, got; int ok;
    snprintf(root, sizeof root, "%s/cloud-backup", folder); snprintf(remote, sizeof remote, "%s/remote/save", root); snprintf(local, sizeof local, "%s/local/save", root);
    snprintf(backups, sizeof backups, "%s-backups", local); snprintf(bundle, sizeof bundle, "%s/cloud.dmsync", root);
    rm_tree(root); mkdirs(remote); mkdirs(local);
    snprintf(p, sizeof p, "%s/a", remote); put(p, "cloud-a"); snprintf(p, sizeof p, "%s/b", remote); put(p, "cloud-b");
    CHECK(!ss_pack(remote, "0100000000010000", bundle, &mr), "pack the cloud's save");
    for (int i = 1; i <= KEEP_BACKUPS; i++) {
        char want[32]; snprintf(p, sizeof p, "%s/2020-01-%02d 00.00.00 cloud/save", backups, i); mkdirs(p);
        snprintf(p, sizeof p, "%s/2020-01-%02d 00.00.00 cloud/save/mark.txt", backups, i); snprintf(want, sizeof want, "seeded-%02d", i); put(p, want);
    }
    snprintf(p, sizeof p, "%s/my-manual-backup", backups); mkdirs(p); snprintf(p, sizeof p, "%s/my-manual-backup/note.txt", backups); put(p, "keep-me");
    fail_stage_publish = 1;
    CHECK(backup_cloud_restore(local, bundle, &got, kept, sizeof kept) == -1 && errno == EIO && !*kept, "a failed publish fails the backup with its errno");
    CHECK(cloud_backups(local, &ok, 1) == KEEP_BACKUPS && ok && !has_cloud_stage(local), "a failed publish keeps all ten backups and leaves no staging");
    snprintf(p, sizeof p, "%s/missing.dmsync", root);
    CHECK(backup_cloud_restore(local, p, &got, kept, sizeof kept) == -1 && !*kept, "an unreadable cloud file fails the backup");
    CHECK(cloud_backups(local, &ok, 1) == KEEP_BACKUPS && ok && !has_cloud_stage(local), "a failed unpack keeps all ten backups and leaves no staging");
    snprintf(p, sizeof p, "%s/%s99999-0/save", backups, CLOUD_STAGE_PREFIX); mkdirs(p);
    snprintf(p, sizeof p, "%s/%s99999-0/save/partial", backups, CLOUD_STAGE_PREFIX); put(p, "interrupted");
    clean_backup_staging(local);
    snprintf(p, sizeof p, "%s/my-manual-backup/note.txt", backups);
    CHECK(!has_cloud_stage(local) && is(p, "keep-me") && cloud_backups(local, &ok, 1) == KEEP_BACKUPS && ok, "a killed start's staging goes; backups and the player's folder stay");
    CHECK(!backup_cloud_restore(local, bundle, &got, kept, sizeof kept) && *kept && !strcmp(got.hash, mr.hash), "the backup is published");
    char pa[PATH_MAX], pb[PATH_MAX]; snprintf(pa, sizeof pa, "%s/save/a", kept); snprintf(pb, sizeof pb, "%s/save/b", kept);
    snprintf(p, sizeof p, "%s/2020-01-01 00.00.00 cloud", backups);
    CHECK(is(pa, "cloud-a") && is(pb, "cloud-b") && access(p, F_OK) && cloud_backups(local, &ok, 2) == KEEP_BACKUPS && ok, "whole, and only then the oldest goes: ten stay");
    snprintf(p, sizeof p, "%s/my-manual-backup/note.txt", backups);
    CHECK(is(p, "keep-me") && !has_cloud_stage(local), "the player's folder stays and no staging is left");
    rm_tree(root);
}
// A guest-name read that fails with anything but ENOATTR fails the scan and the pack with its errno (upstream 0c932bc95): packed without the name, a case alias
// (.dm-case-N) would come back under its host name. A file with no name (ENOATTR) is an ordinary file
static void xattr_failure_cases(const char *folder) {
    const char *name = "guest-name getxattr failures";
    char root[PATH_MAX], local[PATH_MAX], out[PATH_MAX], unpacked[PATH_MAX], p[PATH_MAX];
    ss_meta ml, mr;
    snprintf(root, sizeof root, "%s/xattr-fail", folder); snprintf(local, sizeof local, "%s/local/save", root);
    snprintf(out, sizeof out, "%s/packed.dmsync", root); snprintf(unpacked, sizeof unpacked, "%s/unpacked", root);
    rm_tree(root); mkdirs(local);
    snprintf(p, sizeof p, "%s/plain", local); put(p, "ordinary-file");
    snprintf(p, sizeof p, "%s/.dm-case-1", local); put(p, "alias-content");
    CHECK(!setxattr(p, GUEST_NAME, "Plain", 5, 0, XATTR_NOFOLLOW), "attach guest-name xattr to .dm-case-1 alias");
    CHECK(!ss_scan(local, &ml) && ml.files == 2, "scan succeeds with ENOATTR on an ordinary file and a readable alias name");
    fail_xattr_suffix = "/.dm-case-1"; fail_xattr_errno = EIO; cleanup_errno = EBUSY;
    CHECK(ss_scan(local, &mr) == -1 && errno == EIO, "ss_scan propagates EIO from getxattr");
    CHECK(ss_pack(local, "0100000000010000", out, &mr) == -1 && errno == EIO, "ss_pack propagates EIO from getxattr through its cleanup");
    CHECK(access(out, F_OK) == -1 && errno == ENOENT, "a failed ss_pack leaves no partial archive");
    fail_xattr_suffix = NULL; fail_xattr_errno = 0; cleanup_errno = 0;
    CHECK(!ss_pack(local, "0100000000010000", out, &mr) && !strcmp(mr.hash, ml.hash), "with the name readable the pack succeeds, with the scan's hash");
    mkdirs(unpacked);
    CHECK(!ss_read(out, unpacked, &mr) && !strcmp(mr.hash, ml.hash), "the archive unpacks with the same hash");
    snprintf(p, sizeof p, "%s/save/.dm-case-1", unpacked);
    char g[16] = {0}; ssize_t gl = getxattr(p, GUEST_NAME, g, sizeof g - 1, 0, XATTR_NOFOLLOW);
    CHECK(is(p, "alias-content") && gl == 5 && !strcmp(g, "Plain"), "the .dm-case-1 alias comes back with its guest name and contents");
    rm_tree(root);
}
// The save size records (<save>.size, <save>_device.size: hle_fs.c's ExtendSaveData, upstream 60f0fe506) through a pull: killed after every step, with and without records here
// and in the cloud's save, and killed again in the recovery; an older cloud save without records takes this device's out into the backup; a swap that fails is undone, and
// one whose undo fails too keeps the journal for the next start; a journal from before the size lines leaves the records as they are, and a damaged size line refuses the mount
static void size_record_cases(const char *folder) {
    static const char *TID = "0100000000010000";
    const char *name = "size records through a pull";
    char root[PATH_MAX], save[PATH_MAX], dev[PATH_MAX], s0[PATH_MAX], s1[PATH_MAX], backups[PATH_MAX], kept[PATH_MAX], p[PATH_MAX];
    char b_with[PATH_MAX], b_old[PATH_MAX], src_with[PATH_MAX], src_old[PATH_MAX];
    ss_meta m; struct fault none = {0};
    snprintf(root, sizeof root, "%s/size-rec", folder);
    snprintf(save, sizeof save, "%s/save", root); snprintf(dev, sizeof dev, "%s/save_device", root);
    snprintf(s0, sizeof s0, "%s.size", save); snprintf(s1, sizeof s1, "%s_device.size", save);
    snprintf(backups, sizeof backups, "%s-backups", save);
    rm_tree(root); mkdirs(root);
    unsetenv("DM_SAVE_SYNC");
    snprintf(src_with, sizeof src_with, "%s/c-with/save", root); mkdirs(src_with);   // the cloud's save with both records
    snprintf(p, sizeof p, "%s/a", src_with); put(p, "cloud 0");
    snprintf(p, sizeof p, "%s_device", src_with); mkdirs(p); snprintf(p, sizeof p, "%s_device/b", src_with); put(p, "cloud 1");
    snprintf(p, sizeof p, "%s.size", src_with); put(p, "117440512 8388608\n");
    snprintf(p, sizeof p, "%s_device.size", src_with); put(p, "67108864 4194304\n");
    snprintf(b_with, sizeof b_with, "%s/with.dmsync", root);
    CHECK(!ss_pack(src_with, TID, b_with, &m), "a cloud save with size records packs");
    snprintf(src_old, sizeof src_old, "%s/c-old/save", root); mkdirs(src_old);   // and an older one with none
    snprintf(p, sizeof p, "%s/a", src_old); put(p, "cloud 0");
    snprintf(b_old, sizeof b_old, "%s/old.dmsync", root);
    CHECK(!ss_pack(src_old, TID, b_old, &m), "an older cloud save without them packs");
    for (int local_sz = 0; local_sz < 2; local_sz++)
        for (int cloud_sz = 0; cloud_sz < 2; cloud_sz++) {
            int steps = 0;
            for (int k = 1; k < 20; k++) {
                rm_tree(save); rm_tree(dev); rm_tree(backups); unlink(s0); unlink(s1);
                snprintf(p, sizeof p, "%s.pull", save); unlink(p);
                mkdirs(save); snprintf(p, sizeof p, "%s/a", save); put(p, "original 0");
                mkdirs(dev); snprintf(p, sizeof p, "%s/b", dev); put(p, "original 1");
                if (local_sz) { put(s0, "100663296 4194304\n"); put(s1, "50331648 4194304\n"); }
                faults[0] = faults[1] = none; crash_after = k;
                if (!setjmp(crash_jmp)) {
                    int r = pull(save, cloud_sz ? b_with : b_old, &m, kept, sizeof kept); crash_after = -1;
                    CHECK(!r, "an uninterrupted pull completes"); steps = k - 1;
                    CHECK(cloud_sz ? is(s0, "117440512 8388608\n") && is(s1, "67108864 4194304\n") : access(s0, F_OK) == -1 && access(s1, F_OK) == -1, "the cloud's records, or none, in place");
                    if (local_sz) { snprintf(p, sizeof p, "%s/save.size", kept); CHECK(is(p, "100663296 4194304\n"), "this device's records are kept in the backup");
                                    snprintf(p, sizeof p, "%s/save_device.size", kept); CHECK(is(p, "50331648 4194304\n"), "both of them"); }
                    break;
                }
                snprintf(p, sizeof p, "%s.pull", save); CHECK(!access(p, F_OK), "the journal is there after the kill");
                if (k == 6) {   // killed again in the recovery, while it puts the records back
                    crash_after = 1; pull_journal j;
                    if (!setjmp(crash_jmp)) { CHECK(journal_read(save, &j) == 1, "the journal reads back"); recover(save, &j); }
                    crash_after = -1;
                }
                CHECK(mount_once(save, TID) == 0, "the next start's mount puts the save and its records back");
                snprintf(p, sizeof p, "%s/a", save); CHECK(is(p, "original 0"), "the account save is back");
                snprintf(p, sizeof p, "%s/b", dev); CHECK(is(p, "original 1"), "the device save is back");
                if (local_sz) CHECK(is(s0, "100663296 4194304\n") && is(s1, "50331648 4194304\n"), "this device's records are back, whole");
                else CHECK(access(s0, F_OK) == -1 && access(s1, F_OK) == -1, "the cloud's records are gone where this device had none");
                snprintf(p, sizeof p, "%s.pull", save); CHECK(access(p, F_OK) == -1, "the journal is removed");
            }
            CHECK(steps >= 3, "a pull with records has steps to be killed after");
        }
    name = "an older cloud save over records";
    rm_tree(save); rm_tree(dev); rm_tree(backups); unlink(s0); unlink(s1);
    mkdirs(save); snprintf(p, sizeof p, "%s/a", save); put(p, "original 0");
    put(s0, "100663296 4194304\n"); put(s1, "50331648 4194304\n");
    faults[0] = faults[1] = none;
    CHECK(pull(save, b_old, &m, kept, sizeof kept) == 0 && access(s0, F_OK) == -1 && access(s1, F_OK) == -1, "the pull takes this device's records out");
    snprintf(p, sizeof p, "%s/save.size", kept); CHECK(is(p, "100663296 4194304\n"), "save.size is kept in the backup");
    snprintf(p, sizeof p, "%s/save_device.size", kept); CHECK(is(p, "50331648 4194304\n"), "save_device.size too");
    name = "a size record's swap fails";
    rm_tree(save); rm_tree(dev); rm_tree(backups); unlink(s0); unlink(s1);
    mkdirs(save); snprintf(p, sizeof p, "%s/a", save); put(p, "original 0");
    put(s0, "100663296 4194304\n"); put(s1, "50331648 4194304\n");
    snprintf(staging, sizeof staging, "%s.sync-tmp", save); staging_held = 0;
    faults[0] = (struct fault){2, "local/save_device.size", "/save_device.size", 0}; faults[1] = none;
    CHECK(pull(save, b_with, &m, kept, sizeof kept) == -1 && !faults[0].op && !staging_held, "the pull is undone");
    *staging = 0;
    snprintf(p, sizeof p, "%s/a", save); CHECK(is(p, "original 0") && is(s0, "100663296 4194304\n") && is(s1, "50331648 4194304\n"), "the save and both records are as they were");
    faults[0] = (struct fault){2, "local/save_device.size", "/save_device.size", 0}; faults[1] = (struct fault){2, "local/save.size", "/save.size", 1};
    CHECK(pull(save, b_with, &m, kept, sizeof kept) == -2 && !faults[0].op && !faults[1].op, "and when save.size's swap back fails too: -2");
    snprintf(p, sizeof p, "%s.pull", save); CHECK(!access(p, F_OK), "the journal is kept");
    CHECK(mount_once(save, TID) == 0 && is(s0, "100663296 4194304\n") && is(s1, "50331648 4194304\n"), "the next start puts both records back");
    name = "journals and size lines";
    rm_tree(save); rm_tree(dev); rm_tree(backups); unlink(s0); unlink(s1);
    mkdirs(save); snprintf(p, sizeof p, "%s/a", save); put(p, "original 0");
    put(s0, "100663296 4194304\n");
    struct stat st; stat(save, &st);
    snprintf(p, sizeof p, "%s.pull", save);
    { FILE *jf = fopen(p, "w"); fprintf(jf, "kept\t\nfolder\t0\t2\t%llu\t%llu\nfolder\t1\t0\t0\t0\n", (unsigned long long)st.st_dev, (unsigned long long)st.st_ino); fclose(jf); }
    CHECK(mount_once(save, TID) == 0 && is(s0, "100663296 4194304\n"), "a journal from before the size lines leaves save.size as it is");
    put(p, "kept\t\nfolder\t0\t1\t0\t0\nfolder\t1\t0\t0\t0\nsize\t0\t99\t0\t0\n");
    CHECK(mount_once(save, TID) == -1 && !access(p, F_OK), "a damaged size line refuses the mount, the journal left");
    put(p, "kept\t\nfolder\t0\t1\t0\t0\nfolder\t1\t0\t0\t0\nsize\t0\t0\t0\t0\n");
    CHECK(mount_once(save, TID) == -1, "one size line of two refuses it too");
    unlink(p);
    rm_tree(root);
}
int main(void) {
    char folder[] = "/tmp/dm-save-sync-metadata-XXXXXX", save[PATH_MAX], path[PATH_MAX];
    if (!mkdtemp(folder)) return 1;
    snprintf(save, sizeof save, "%s/save", folder);
    run_case(save, "open failure", 1, 0, 0, 0, EACCES);
    run_case(save, "write failure", 0, 1, 0, 0, ENOSPC);
    run_case(save, "write and close failures", 0, 1, 1, 0, ENOSPC);
    run_case(save, "close failure", 0, 0, 1, 0, EIO);
    run_case(save, "rename failure", 0, 0, 0, 1, EROFS);
    run_case(save, "success", 0, 0, 0, 0, 0);
    formats(save);
    snprintf(path, sizeof path, "%s.sync", save); unlink(path);
    {
        char root[PATH_MAX], both[PATH_MAX], one[PATH_MAX]; const char *name;
        struct fault none = {0};
        snprintf(root, sizeof root, "%s/pull", folder); mkdirs(root);
        cloud_bundle(root, 1, both, sizeof both); cloud_bundle(root, 0, one, sizeof one);
        name = "pull, nothing fails"; pull_case(root, name, both, 1, none, none, 0);
        name = "pull, the cloud's has no device save"; pull_case(root, name, one, 0, none, none, 0);
        // The move into the backups that the old pull did after its swap; here the first step, before anything is in place
        name = "pull, the cloud's save into the backups fails"; pull_case(root, name, both, 1, (struct fault){1, "in/save", "local/save", 0}, none, -1);
        name = "pull, the device save's swap fails: the save is swapped back"; pull_case(root, name, both, 1, (struct fault){2, "local/save_device", "/save_device", 0}, none, -1);
        name = "pull, the device save's move to the backups fails"; pull_case(root, name, one, 0, (struct fault){1, "/save_device", "local/save_device", 0}, none, -1);
        name = "pull, the device save's swap and the save's swap back fail";
        pull_case(root, name, both, 1, (struct fault){2, "local/save_device", "/save_device", 0}, (struct fault){2, "local/save", "/save", 1}, -2);
        {   char rs[PATH_MAX]; snprintf(rs, sizeof rs, "%s/save", root); snprintf(path, sizeof path, "%s.pull", rs);
            CHECK(!access(path, F_OK), "a pull that could not be put back keeps its journal");
            unsetenv("DM_SAVE_SYNC");
            CHECK(mount_once(rs, "0100000000010000") == 0 && as_before(root, HAD_SAVE), "the next start puts this device's save back"); }
        journal_cases(root, both, one);
        unreadable_case(root);
        rm_tree(root);
    }
    fetch_cases(folder);
    cloud_backup_cases(folder);
    xattr_failure_cases(folder);
    size_record_cases(folder);
    rmdir(folder);
    printf("save-sync metadata: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
