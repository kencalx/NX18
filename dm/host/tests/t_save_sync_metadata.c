// Exercise the real metadata writer with stdio failures, without cloud or game files; then the file's format both ways: what an older build reads of a file this one
// writes (its reader, copied below), and what this one reads of an older build's file (no cloud line).
// Then the real pull (the cloud's save swapped in) with rename failures: every step that can fail, failing: this device's save stays whole and nowhere but in
// place or in its backups, and the staging folder (cleared at every start) never holds this device's save, also while a pull that succeeds is between two steps
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
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
static int test_rename(const char *from, const char *to) {
    renames++;
    if (fail_rename) { errno = EROFS; return -1; }
    if (faulted(1, from, to)) return -1;
    int r = rename(from, to);
    if (*staging && holds(staging, "original")) staging_held = 1;
    return r;
}
static int test_renamex_np(const char *from, const char *to, unsigned flags) {
    if (faulted(2, from, to)) return -1;
    int r = renamex_np(from, to, flags);
    if (*staging && holds(staging, "original")) staging_held = 1;
    return r;
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
#include "../save_sync.c"
#undef fopen
#undef fprintf
#undef fclose
#undef rename
#undef unlink
#undef renamex_np

static int checks, failures;
#define CHECK(c, label) do { checks++; if (!(c)) { failures++; fprintf(stderr, "FAIL: %s (%s)\n", name, label); } } while (0)
static const char old_hash[] = "00000000000000000000000000000000";
static const char new_hash[] = "123456789abcdef0123456789abcdef0";
static const char cloud[] = "/Users/p/Library/Mobile Documents/com~apple~CloudDocs/nxnative Saves/0100ABC/save.dmsync";

// The reader of the build before the cloud line (fa92bb0e save_sync.c), as it is: an older build on another device, or this one's app before an update
// (NX 18's main before the port of the cloud line, a1057c2d's save_sync.c, has this very reader too)
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
    } else if (!want) {
        snprintf(p, sizeof p, "%s/a", save); CHECK(is(p, "cloud 0"), "the cloud's save is in place");
        snprintf(p, sizeof p, "%s/b", dev); CHECK(device_cloud ? is(p, "cloud 1") : access(p, F_OK) == -1, "the cloud's device save is in place, or none when it has none");
        snprintf(p, sizeof p, "%s/save/a", kept); CHECK(is(p, "original 0"), "this device's save is kept in the backup pull names");
        snprintf(p, sizeof p, "%s/save_device/b", kept); CHECK(is(p, "original 1"), "this device's device save is kept in the backup pull names");
    } else CHECK(*kept && holds(kept, "original"), "the backup pull names holds what is not in place");
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
        rm_tree(root);
    }
    rmdir(folder);
    printf("save-sync metadata: %d checks, %d failed\n", checks, failures);
    return failures != 0;
}
