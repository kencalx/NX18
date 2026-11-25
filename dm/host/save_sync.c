// Saves through a cloud folder (iCloud Drive): see save_sync.h. Plain C on system calls and CommonCrypto only, so the Mac launcher links it as the host does (dm/mac/pack_app.py).
// A packed save (<folder>/<title ID>/save.dmsync), little-endian:
//   header  "DMSYNC1\n", u32 version (1), u32 entries, 32 hex digits of the hash, i64 saved, char title[24], char device[64]
//   entry   u8 type (1 folder, 2 file), u8 0, u16 path length, u16 guest-name length, u16 0, u64 size, i64 mtime; the path (save/... or save_device/...), the guest name, the contents
//   end     "DMSYNCE\n", then the end of the file (a file cut off anywhere is refused)
// The hash runs over each entry's first 16 header bytes (not the date), its path, its guest name and its contents, in the order walk() visits them.
#include "save_sync.h"
#include <CommonCrypto/CommonDigest.h>
#include <TargetConditionals.h>
#include <ctype.h>
#include <dirent.h>
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/clonefile.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/xattr.h>
#include <time.h>
#include <unistd.h>

#define SLOG(...) do { fprintf(stderr, "[dm] save sync: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define SRED(...) do { fprintf(stderr, "[dm] [RED] save sync: " __VA_ARGS__); fputc('\n', stderr); } while (0)
#define GUEST_NAME "org.d2rmobile.guest-name"   // hle_fs.c FS_GUEST_NAME: a file's guest name when its host name had to differ (a case collision); part of the save
#define QUIET_MS 3000    // a game often commits several times in a row: the sender waits until it has been quiet this long
#define GAP_MS 180000    // in play, at least this long from one send to the next (the sender): Super Smash Bros. Ultimate sent 9 times (13.4 MB) in 8.6 minutes, Donkey Kong Bananza 12 in 6.5
#define QUIT_MS 5000     // what a quit (exit(): the Mac's ⌘Q, its window closed) gives the send of what is not sent yet; the Mac launcher sends after the host too
#define FETCH_MS 10000   // the longest the game waits for the cloud's copy (a download); then it plays on with this device's save, which is not sent until the two have been compared
#define KEEP_BACKUPS 10  // backups kept of each side (local, cloud); older ones are removed when a new one is made
enum { HDR = 8 + 4 + 4 + SS_HASH + 8 + 24 + 64, ENT = 24, CHUNK = 1 << 16 };   // header bytes, entry header bytes, the copy buffer
static const char MAGIC[8] __attribute__((nonstring)) = "DMSYNC1\n", END[8] __attribute__((nonstring)) = "DMSYNCE\n";
static const char *const FOLDERS[2] = {"save", "save_device"};   // their names in a packed save; on disk DM_SAVE and DM_SAVE_device (hle_fs.c h_fs_MountDeviceSave)

// ---------- files ----------
static void folder_path(const char *save, int i, char *out, size_t n) { snprintf(out, n, i ? "%s_device" : "%s", save); }

static void free_names(char **v, size_t n) { for (size_t i = 0; i < n; i++) free(v[i]); free(v); }
static int by_name(const void *a, const void *b) { return strcmp(*(char *const *)a, *(char *const *)b); }
// A folder's names in byte order, without . and ..; -1 when it cannot be read
static int names_of(const char *dir, char ***out, size_t *count) {
    DIR *d = opendir(dir); if (!d) return -1;
    char **v = NULL; size_t n = 0, cap = 0; struct dirent *e; int r = 0;
    while ((e = readdir(d))) {
        if (!strcmp(e->d_name, ".") || !strcmp(e->d_name, "..")) continue;
        if (n == cap) { char **w = realloc(v, (cap = cap ? cap * 2 : 16) * sizeof *v); if (!w) { r = -1; break; } v = w; }
        if (!(v[n] = strdup(e->d_name))) { r = -1; break; }
        n++;
    }
    closedir(d);
    if (r) { free_names(v, n); return -1; }
    if (n) qsort(v, n, sizeof *v, by_name);
    *out = v; *count = n; return 0;
}

static int mkdirs(const char *path) {   // mkdir -p
    char p[PATH_MAX]; if (snprintf(p, sizeof p, "%s", path) >= (int)sizeof p) return -1;
    for (char *s = p + 1; *s; s++) if (*s == '/') { *s = 0; mkdir(p, 0755); *s = '/'; }
    return mkdir(p, 0755) && errno != EEXIST ? -1 : 0;
}

static int rm_tree(const char *p) {   // rm -rf: 0 when nothing is left
    struct stat st; if (lstat(p, &st)) return errno == ENOENT ? 0 : -1;
    if (!S_ISDIR(st.st_mode)) return unlink(p);
    char **v; size_t n; if (names_of(p, &v, &n)) return -1;
    int r = 0;
    for (size_t i = 0; i < n; i++) { char c[PATH_MAX]; snprintf(c, sizeof c, "%s/%s", p, v[i]); if (rm_tree(c)) r = -1; }
    free_names(v, n);
    return rmdir(p) ? -1 : r;
}

// Anything in it but Finder's .DS_Store: an empty folder is no save (the host makes DM_SAVE at every mount, DM_SAVE_device at the device save's). 1 yes, 0 no (or no
// such folder), -1 it cannot be listed (opendir: EMFILE, ENOMEM, EACCES): never "no save", or a pull would swap the folder into the staging folder, which is cleared,
// with no backup made, and ss_scan would call it empty and decide on that; callers take -1 as an error (pack_save fails, so the mount turns sync off; pull fails first)
static int has_entries(const char *dir) {
    char **v; size_t n, k = 0;
    if (names_of(dir, &v, &n)) { struct stat st; return lstat(dir, &st) && errno == ENOENT ? 0 : -1; }
    for (size_t i = 0; i < n; i++) k += strcmp(v[i], ".DS_Store") != 0;
    free_names(v, n); return k > 0;
}

typedef int (*visit_fn)(void *ctx, const char *abs, const char *rel, const struct stat *st);
// Every entry under abs, depth first, a folder before what it holds, names in byte order: the order that gives the same save the same hash on every device.
// Finder's .DS_Store is left out (a save folder someone opened in Finder is still the same save), and so are links, which the host never makes in a save
static int walk(const char *abs, const char *rel, visit_fn fn, void *ctx) {
    char **v; size_t n; if (names_of(abs, &v, &n)) return -1;
    int r = 0;
    for (size_t i = 0; i < n && !r; i++) {
        if (!strcmp(v[i], ".DS_Store")) continue;
        char a[PATH_MAX], p[PATH_MAX]; struct stat st;
        if (snprintf(a, sizeof a, "%s/%s", abs, v[i]) >= (int)sizeof a || snprintf(p, sizeof p, "%s/%s", rel, v[i]) >= (int)sizeof p || lstat(a, &st)) r = -1;
        else if (S_ISDIR(st.st_mode)) { if (!(r = fn(ctx, a, p, &st))) r = walk(a, p, fn, ctx); }
        else if (S_ISREG(st.st_mode)) r = fn(ctx, a, p, &st);
    }
    free_names(v, n); return r;
}

static int write_all(int fd, const void *b, size_t n) {
    for (const char *p = b; n; ) { ssize_t k = write(fd, p, n); if (k < 0 && errno == EINTR) continue; if (k <= 0) return -1; p += k; n -= (size_t)k; }
    return 0;
}

static int copy_fd(int in, int out) {
    char *b = malloc(CHUNK); if (!b) return -1;
    ssize_t k; int r = 0;
    while ((k = read(in, b, CHUNK)) != 0) { if (k < 0) { if (errno == EINTR) continue; r = -1; break; } if (write_all(out, b, (size_t)k)) { r = -1; break; } }
    free(b); return r;
}

static void hex(const uint8_t *d, char *out) { for (int i = 0; i < SS_HASH / 2; i++) snprintf(out + 2 * i, 3, "%02x", d[i]); }

static void when(int64_t t, char *out, size_t n) {   // a save's time in the log
    time_t tt = (time_t)t; struct tm tm;
    if (!t || !localtime_r(&tt, &tm) || !strftime(out, n, "%Y-%m-%d %H:%M:%S", &tm)) snprintf(out, n, "unknown");
}

static void device_name(char *out, size_t n) {   // the model ("Mac16,1", "iPhone17,1"): which device a save came from, for the log
    char model[64] = ""; size_t len = sizeof model;
    if (sysctlbyname(TARGET_OS_OSX ? "hw.model" : "hw.machine", model, &len, NULL, 0)) model[0] = 0;
    snprintf(out, n, "%s", model[0] ? model : "unknown");
}

static void upper_title(const char *title, char *out, size_t n) {   // one spelling of the title ID in the cloud, whoever packed the app
    size_t i = 0; for (; title[i] && i + 1 < n; i++) out[i] = (char)toupper((unsigned char)title[i]);
    out[i] = 0;
}

// ---------- packing ----------
typedef struct { CC_SHA256_CTX sha; FILE *out; ss_meta *m; uint32_t entries; uint8_t buf[CHUNK]; } packer;

static int pack_entry(void *c, const char *abs, const char *rel, const struct stat *st) {
    packer *k = c;
    char guest[1024]; ssize_t gl = getxattr(abs, GUEST_NAME, guest, sizeof guest, 0, XATTR_NOFOLLOW);
    if (gl < 0) gl = 0;   // ENOATTR: the host name is the guest's
    size_t pl = strlen(rel); int file = S_ISREG(st->st_mode);
    if (pl > UINT16_MAX) return -1;
    uint8_t h[ENT] = {(uint8_t)(file ? 2 : 1)}; uint16_t pl16 = (uint16_t)pl, gl16 = (uint16_t)gl;
    uint64_t size = file ? (uint64_t)st->st_size : 0; int64_t mt = st->st_mtimespec.tv_sec;
    memcpy(h + 2, &pl16, 2); memcpy(h + 4, &gl16, 2); memcpy(h + 8, &size, 8); memcpy(h + 16, &mt, 8);
    CC_SHA256_Update(&k->sha, h, 16); CC_SHA256_Update(&k->sha, rel, (CC_LONG)pl); CC_SHA256_Update(&k->sha, guest, (CC_LONG)gl);
    if (k->out && (fwrite(h, 1, ENT, k->out) != ENT || fwrite(rel, 1, pl, k->out) != pl || fwrite(guest, 1, (size_t)gl, k->out) != (size_t)gl)) return -1;
    k->entries++;
    if (!file) return 0;
    int fd = open(abs, O_RDONLY); if (fd < 0) return -1;
    uint64_t left = size; ssize_t got = 0;
    while (left && (got = read(fd, k->buf, left < CHUNK ? (size_t)left : CHUNK)) != 0) {
        if (got < 0) { if (errno == EINTR) continue; break; }
        CC_SHA256_Update(&k->sha, k->buf, (CC_LONG)got);
        if (k->out && fwrite(k->buf, 1, (size_t)got, k->out) != (size_t)got) break;
        left -= (uint64_t)got;
    }
    close(fd);
    if (left) return -1;   // a failed read, or a file shorter than its size (the save is a clone no Commit touches, so not one being written)
    k->m->files++; k->m->bytes += (int64_t)size;
    if (mt > k->m->saved) k->m->saved = mt;
    return 0;
}

static int pack_save(const char *save, packer *k) {
    CC_SHA256_Init(&k->sha);
    for (int i = 0; i < 2; i++) {
        char dir[PATH_MAX]; folder_path(save, i, dir, sizeof dir);
        if (has_entries(dir) && walk(dir, FOLDERS[i], pack_entry, k)) return -1;
    }
    uint8_t d[CC_SHA256_DIGEST_LENGTH]; CC_SHA256_Final(d, &k->sha); hex(d, k->m->hash);
    if (!k->m->files) k->m->hash[0] = 0;   // no save: no hash, so that "nothing here" compares as nothing
    return 0;
}

int ss_scan(const char *save, ss_meta *m) {
    memset(m, 0, sizeof *m);
    packer *k = calloc(1, sizeof *k); if (!k) return -1;
    k->m = m; int r = pack_save(save, k);
    free(k); return r;
}

int ss_pack(const char *save, const char *title, const char *out, ss_meta *m) {
    memset(m, 0, sizeof *m);
    upper_title(title, m->title, sizeof m->title); device_name(m->device, sizeof m->device);
    packer *k = calloc(1, sizeof *k); if (!k) return -1;
    k->m = m; int r = -1;
    uint8_t hdr[HDR] = {0}; uint32_t version = 1;
    if (!(k->out = fopen(out, "wb")) || fwrite(hdr, 1, HDR, k->out) != HDR || pack_save(save, k) || fwrite(END, 1, sizeof END, k->out) != sizeof END) goto done;
    memcpy(hdr, MAGIC, 8); memcpy(hdr + 8, &version, 4); memcpy(hdr + 12, &k->entries, 4); memcpy(hdr + 16, m->hash, strlen(m->hash));
    memcpy(hdr + 48, &m->saved, 8); memcpy(hdr + 56, m->title, strlen(m->title)); memcpy(hdr + 80, m->device, strlen(m->device));
    if (fseeko(k->out, 0, SEEK_SET) || fwrite(hdr, 1, HDR, k->out) != HDR || fflush(k->out) || fsync(fileno(k->out))) goto done;
    r = 0;
done:
    if (k->out && fclose(k->out)) r = -1;
    if (r) unlink(out);
    free(k); return r;
}

// A path in a packed save: under save/ or save_device/, with no empty, . or .. part (a damaged file must not write outside `into`)
static int path_ok(const char *p) {
    if (strncmp(p, "save/", 5) && strncmp(p, "save_device/", 12)) return 0;
    for (const char *s = p;; ) {
        const char *e = strchr(s, '/'); size_t n = e ? (size_t)(e - s) : strlen(s);
        if (!n || (n == 1 && s[0] == '.') || (n == 2 && s[0] == '.' && s[1] == '.')) return 0;
        if (!e) return 1;
        s = e + 1;
    }
}

int ss_read(const char *bundle, const char *into, ss_meta *m) {
    memset(m, 0, sizeof *m);
    FILE *f = fopen(bundle, "rb"); if (!f) return -1;
    uint8_t *buf = malloc(CHUNK), hdr[HDR], h[ENT], end[sizeof END], d[CC_SHA256_DIGEST_LENGTH];
    char want[SS_HASH + 1] = "", path[PATH_MAX], guest[1024], out[PATH_MAX];
    uint32_t version, n; int r = -1, fd = -1;
    CC_SHA256_CTX sha; CC_SHA256_Init(&sha);
    if (!buf || fread(hdr, 1, HDR, f) != HDR || memcmp(hdr, MAGIC, 8)) goto done;
    memcpy(&version, hdr + 8, 4); memcpy(&n, hdr + 12, 4);
    if (version != 1) goto done;
    memcpy(want, hdr + 16, SS_HASH); memcpy(&m->saved, hdr + 48, 8); memcpy(m->title, hdr + 56, 23); memcpy(m->device, hdr + 80, 63);
    for (uint32_t i = 0; i < n; i++) {
        uint16_t pl, gl; uint64_t size; int64_t mt;
        if (fread(h, 1, ENT, f) != ENT) goto done;
        memcpy(&pl, h + 2, 2); memcpy(&gl, h + 4, 2); memcpy(&size, h + 8, 8); memcpy(&mt, h + 16, 8);
        if ((h[0] != 1 && h[0] != 2) || !pl || pl >= sizeof path || gl > sizeof guest || (h[0] == 1 && size)) goto done;
        if (fread(path, 1, pl, f) != pl || fread(guest, 1, gl, f) != gl) goto done;
        path[pl] = 0;
        if (strlen(path) != pl || !path_ok(path)) goto done;
        CC_SHA256_Update(&sha, h, 16); CC_SHA256_Update(&sha, path, pl); CC_SHA256_Update(&sha, guest, gl);
        if (into) {
            if (snprintf(out, sizeof out, "%s/%s", into, path) >= (int)sizeof out) goto done;
            if (h[0] == 1) { if (mkdirs(out)) goto done; }
            else {
                *strrchr(out, '/') = 0; int made = mkdirs(out); out[strlen(out)] = '/';
                if (made || (fd = open(out, O_WRONLY | O_CREAT | O_EXCL, 0644)) < 0) goto done;
            }
            if (gl && setxattr(out, GUEST_NAME, guest, gl, 0, XATTR_NOFOLLOW)) goto done;
        }
        for (uint64_t left = size; left; ) {
            size_t k = left < CHUNK ? (size_t)left : CHUNK;
            if (fread(buf, 1, k, f) != k) goto done;
            CC_SHA256_Update(&sha, buf, (CC_LONG)k);
            if (fd >= 0 && write_all(fd, buf, k)) goto done;
            left -= k;
        }
        if (fd >= 0) {   // the file's own date back: the newest one is the save's age when two changed saves are compared (ss_decide), not the time of the copy
            struct timespec t[2] = {{(time_t)mt, 0}, {(time_t)mt, 0}}; futimens(fd, t);
            int bad = close(fd); fd = -1; if (bad) goto done;
        }
        if (h[0] == 2) { m->files++; m->bytes += (int64_t)size; }
    }
    if (fread(end, 1, sizeof end, f) != sizeof end || memcmp(end, END, sizeof end) || fgetc(f) != EOF) goto done;
    CC_SHA256_Final(d, &sha); hex(d, m->hash);
    if (!m->files) m->hash[0] = 0;
    if (strcmp(m->hash, want)) goto done;
    r = 0;
done:
    if (fd >= 0) close(fd);
    free(buf); fclose(f);
    if (r) { m->files = 0; m->bytes = 0; m->hash[0] = 0; }
    return r;
}

ss_way ss_decide(const char *local, const char *base, const char *remote, int64_t local_saved, int64_t remote_saved, int ask, int *both) {
    *both = 0;
    if (!*remote) return *local ? SS_PUSH : SS_KEEP;           // nothing in the cloud
    if (!strcmp(local, remote)) return SS_KEEP;                 // already the same
    if (!*local) return SS_PULL;                                // nothing here
    if (*base && !strcmp(local, base)) return SS_PULL;          // only the cloud's changed
    if (*base && !strcmp(remote, base)) return SS_PUSH;         // only this one changed
    *both = 1;                                                  // both changed, or this device's first sync with a save of its own
    if (ask) return SS_ASK;                                     // a front end asks the player (DM_SAVE_SYNC_CHOICE)
    return remote_saved > local_saved ? SS_PULL : SS_PUSH;      // no front end asks: the newer one; the other is kept in the backups
}

// DM_SAVE_SYNC_CHOICE: what the player chose before the start, after a front end compared the two saves (docs/frontends.md, The cloud saves folder).
// Any value says the front end asks the player when both changed (then neither replaces the other without a choice); unset, the newer one wins (ss_decide).
// "ask": no choice yet (the two were the same, or only one side changed, when the front end checked). "cloud:<hash>" brings in the cloud's save with that hash,
// "local:<hash>" lets this device's replace the cloud's save with that hash ("local:none": the cloud had none), "offline": the cloud could not be read before the start.
// A choice holds only for the save it was made on: when the cloud's has changed since, it is not used (and a save that changed on both sides is replaced on neither)
typedef enum { CH_NONE, CH_ASK, CH_CLOUD, CH_LOCAL, CH_OFFLINE } choice_kind;
static choice_kind read_choice(char *hash) {
    const char *v = getenv("DM_SAVE_SYNC_CHOICE"); hash[0] = 0;
    if (!v || !*v) return CH_NONE;
    if (!strcmp(v, "ask")) return CH_ASK;
    if (!strcmp(v, "offline")) return CH_OFFLINE;
    choice_kind k = !strncmp(v, "cloud:", 6) ? CH_CLOUD : !strncmp(v, "local:", 6) ? CH_LOCAL : CH_NONE;
    const char *h = v + 6;
    if (k == CH_LOCAL && !strcmp(h, "none")) return k;
    if (k != CH_NONE && strlen(h) == SS_HASH && strspn(h, "0123456789abcdef") == SS_HASH) { memcpy(hash, h, SS_HASH + 1); return k; }
    SRED("DM_SAVE_SYNC_CHOICE=%s is not a choice (ask, cloud:<hash>, local:<hash>, local:none, offline): ignored, the newer save wins", v);
    return CH_NONE;
}

// ---------- the sync state, backups, the cloud's file ----------
// <save>.sync: base, the hash of the save last known to be the same here and in the cloud ("" for none), and cloud, the cloud file it was the same as. named: the file has a
// cloud line (one an older build wrote has none, and named no cloud). Lines it does not know are skipped, as an older build skips the cloud line
typedef struct { char base[SS_HASH + 1], cloud[PATH_MAX]; int named; } sync_state;
static void read_base(const char *save, sync_state *s) {
    char p[PATH_MAX], ln[PATH_MAX + 16];   // the longest line write_base writes: "cloud\t", a cloud file's path (cloud_file: under PATH_MAX), "\n"
    memset(s, 0, sizeof *s);
    snprintf(p, sizeof p, "%s.sync", save);
    FILE *f = fopen(p, "r"); if (!f) return;
    for (int at = 1; fgets(ln, sizeof ln, f); ) {   // at: this piece begins a line (a longer line comes in pieces)
        size_t n = strlen(ln); int whole = n && ln[n - 1] == '\n';
        if (whole) ln[--n] = 0;
        if (at && !strncmp(ln, "base\t", 5) && strspn(ln + 5, "0123456789abcdef") == SS_HASH) { memcpy(s->base, ln + 5, SS_HASH); s->base[SS_HASH] = 0; }
        else if (at && !strncmp(ln, "cloud\t", 6)) {   // one longer than any path names no cloud file this build can have
            s->named = 1;
            if (!(whole || feof(f)) || snprintf(s->cloud, sizeof s->cloud, "%s", ln + 6) >= (int)sizeof s->cloud) s->cloud[0] = 0;
        }
        at = whole;
    }
    fclose(f);
}
// The cloud file's path with its folders resolved (realpath: a link, /var for /private/var, the form a security-scoped bookmark resolves to, a folder picked by hand
// that is the "icloud" one), so one folder reached two ways is one folder here. A folder not made yet resolves through the nearest one that exists, which gives the
// same path once it is made; when nothing resolves, the path as given
static void canon_cloud(const char *cloud, char *out, size_t n) {
    char dir[PATH_MAX], real[PATH_MAX];
    snprintf(out, n, "%s", cloud);
    if (snprintf(dir, sizeof dir, "%s", cloud) >= (int)sizeof dir) return;
    for (char *cut = strrchr(dir, '/'); cut && cut > dir; cut = strrchr(dir, '/')) {
        *cut = 0;
        if (realpath(dir, real)) { if (snprintf(out, n, "%s/%s", real, cloud + (cut - dir) + 1) >= (int)n) snprintf(out, n, "%s", cloud); return; }
    }
}
static int same_cloud(const char *a, const char *b) {   // the same cloud file, however each path spells its folders
    if (!strcmp(a, b)) return 1;
    char ca[PATH_MAX], cb[PATH_MAX]; canon_cloud(a, ca, sizeof ca); canon_cloud(b, cb, sizeof cb);
    return !strcmp(ca, cb);
}
// The base counts for the cloud file it was recorded with (a file an older build wrote names none: it counts as it did there), and for one that holds that very save
// (remote: its hash, "" when it was not read). Another folder's says nothing about this one: the first sync with it compares the two saves, never "only the cloud's
// changed". The mount and the launchers' report (save_sync_report) both decide with it, so the report's conflict is the mount's
static const char *base_for(const sync_state *s, const char *cloud, const char *remote) {
    return !s->named || same_cloud(s->cloud, cloud) || (*remote && !strcmp(remote, s->base)) ? s->base : "";
}

// Written beside it and renamed over it: a cut-off write must not read as another base. The cloud line comes first: an older build reads the last base line it finds, in
// pieces of 127 bytes, so a long path is never read as the base. The cloud file is written with its folders resolved (canon_cloud)
static void write_base(const char *save, const char *hash, const char *cloud_given) {
    char p[PATH_MAX], t[PATH_MAX + 8], cloud[PATH_MAX];
    canon_cloud(cloud_given, cloud, sizeof cloud);
    snprintf(p, sizeof p, "%s.sync", save); snprintf(t, sizeof t, "%s.tmp", p);
    FILE *f = fopen(t, "w");
    int err = f ? 0 : errno;
    if (f) {
        if (fprintf(f, "# save sync (dm/host/save_sync.h): the save last known to be the same here and in the cloud, and that cloud's file\ncloud\t%s\nbase\t%s\n", cloud, hash) < 0) err = errno;
        // Close even after a write error, and keep that error if close or cleanup fails too.
        if (fclose(f) && !err) err = errno;
        if (!err && rename(t, p)) err = errno;
        if (err) unlink(t);
    }
    if (err) SRED("cannot write %s (errno=%d): the next start compares with the sync before", p, err);
}

// A backup this file made for `side`: "YYYY-MM-DD HH.MM.SS <side>", or with " <k>" after it (backup_dir); anything else in <save>-backups is the player's
static int is_backup(const char *name, const char *side) {
    static const char form[] = "0000-00-00 00.00.00 ";
    for (int i = 0; form[i]; i++) if (form[i] == '0' ? !isdigit((unsigned char)name[i]) : name[i] != form[i]) return 0;
    const char *s = name + sizeof form - 1; size_t sl = strlen(side);
    if (strncmp(s, side, sl)) return 0;
    if (!s[sl]) return 1;
    if (s[sl] != ' ' || !s[sl + 1]) return 0;
    for (s += sl + 1; *s; s++) if (!isdigit((unsigned char)*s)) return 0;
    return 1;
}

// Only the newest KEEP_BACKUPS of a side stay: each switch between devices keeps a whole save, and on a phone they add up. `made` (just made) is one of them whatever its date says
static void prune_backups(const char *save, const char *side, const char *made) {
    char dir[PATH_MAX], **v; size_t n, k = 0, gone = 0; snprintf(dir, sizeof dir, "%s-backups", save);
    if (names_of(dir, &v, &n)) return;
    const char *mine = strrchr(made, '/'); mine = mine ? mine + 1 : made;
    for (size_t i = 0; i < n; i++) if (is_backup(v[i], side) && strcmp(v[i], mine)) v[k++] = v[i]; else free(v[i]);   // in date order (names_of sorts them)
    for (size_t i = 0; i + (KEEP_BACKUPS - 1) < k; i++) {
        char p[PATH_MAX]; snprintf(p, sizeof p, "%s/%s", dir, v[i]);
        if (rm_tree(p)) SRED("cannot remove the old backup %s (errno=%d)", p, errno); else gone++;
    }
    if (gone) SLOG("removed %zu old %s backup%s (the newest %d stay)", gone, side, gone == 1 ? "" : "s", KEEP_BACKUPS);
    free_names(v, k);
}

// A folder for a save about to be replaced: <save>-backups/<date> <side> (local: this device's, cloud: the cloud's). The oldest of that side beyond KEEP_BACKUPS go only once
// it holds the save (the caller's prune_backups): a backup that fails must not cost a real one, and a start that fails every time (a full disk, the backups on another volume)
// would otherwise leave an empty folder each time and remove one real backup each time. A caller whose backup fails removes the folder it made (a pull that cannot put this
// device's save back keeps it, with what is not in place)
static int backup_dir(const char *save, const char *side, char *out, size_t n) {
    char stamp[32]; time_t t = time(NULL); struct tm tm; localtime_r(&t, &tm); strftime(stamp, sizeof stamp, "%Y-%m-%d %H.%M.%S", &tm);
    snprintf(out, n, "%s-backups/%s %s", save, stamp, side);
    for (int k = 2; !access(out, F_OK); k++) snprintf(out, n, "%s-backups/%s %s %d", save, stamp, side, k);
    return mkdirs(out) ? -1 : 0;
}

// A DM_SAVE_SYNC value → <folder>/<title ID>/save.dmsync; 0 when sync is off
static int cloud_path(const char *v, const char *title, char *out, size_t n) {
    char dir[PATH_MAX], id[24];
    if (!v || !*v || !strcmp(v, "0")) return 0;
    if (!strcmp(v, "icloud")) {
#if TARGET_OS_OSX
        const char *home = getenv("HOME"); char drive[PATH_MAX]; struct stat st;
        snprintf(drive, sizeof drive, "%s/Library/Mobile Documents/com~apple~CloudDocs", home ? home : "");
        if (!home || stat(drive, &st)) {
            if (errno == EPERM || errno == EACCES) SLOG("off: this app may not open iCloud Drive (System Settings > Privacy & Security > Files and Folders)");
            else SLOG("off: iCloud Drive is not on for this Mac (no %s)", drive);
            return 0;
        }
        snprintf(dir, sizeof dir, "%s/nxnative Saves", drive);
#else
        SLOG("off: DM_SAVE_SYNC=icloud is the Mac's iCloud Drive folder; on this device, choose the folder in the launcher (Cloud saves)");
        return 0;
#endif
    } else snprintf(dir, sizeof dir, "%s", v);
    size_t L = strlen(dir); while (L > 1 && dir[L - 1] == '/') dir[--L] = 0;
    upper_title(title, id, sizeof id);
    if (!*id || strchr(id, '/')) return 0;
    // The game's own folder chosen instead of the one above it (a picker shows <folder>/<title ID> once another device has synced): taken as it is, not given a second <title ID>
    const char *last = strrchr(dir, '/');
    if (!strcasecmp(last ? last + 1 : dir, id)) return snprintf(out, n, "%s/save.dmsync", dir) < (int)n;
    return snprintf(out, n, "%s/%s/save.dmsync", dir, id) < (int)n;
}
static int cloud_file(const char *title, char *out, size_t n) { return cloud_path(getenv("DM_SAVE_SYNC"), title, out, n); }

// The platform's fetch, given at most `ms`: a download iCloud never finishes must not hold the game at its first save mount. One that comes too late is dropped.
// Each fetch writes a file of its own (part: <local>.<pid>-<n>.part), renamed to `local` only by the caller that still waits for it: a fetch that came too late
// removes its own file and nothing else, so it never writes over or removes what a later attempt fetched to the same `local` (the sender's out/cloud.dmsync)
typedef struct { pthread_mutex_t mu; pthread_cond_t cv; int done, abandoned, result; char cloud[PATH_MAX], part[PATH_MAX + 32]; } fetch_job;
static void *fetch_thread(void *p) {
    fetch_job *j = p; int r = front_save_sync_fetch(j->cloud, j->part);
    pthread_mutex_lock(&j->mu); j->done = 1; j->result = r; int late = j->abandoned; pthread_cond_signal(&j->cv); pthread_mutex_unlock(&j->mu);
    if (late) { unlink(j->part); pthread_mutex_destroy(&j->mu); pthread_cond_destroy(&j->cv); free(j); }
    return NULL;
}
static void deadline(int ms, struct timespec *ts) {
    clock_gettime(CLOCK_REALTIME, ts);
    ts->tv_sec += ms / 1000; ts->tv_nsec += (long)(ms % 1000) * 1000000;
    if (ts->tv_nsec >= 1000000000) { ts->tv_sec++; ts->tv_nsec -= 1000000000; }
}
static int fetch_timed(const char *cloud, const char *local, int ms) {   // front_save_sync_fetch's answer, or -1 at the time limit (or with no thread to wait on)
    static _Atomic unsigned seq;
    fetch_job *j = calloc(1, sizeof *j); pthread_t t;
    if (!j) return -1;
    pthread_mutex_init(&j->mu, NULL); pthread_cond_init(&j->cv, NULL);
    snprintf(j->cloud, sizeof j->cloud, "%s", cloud); snprintf(j->part, sizeof j->part, "%s.%d-%u.part", local, (int)getpid(), atomic_fetch_add(&seq, 1));
    int e = pthread_create(&t, NULL, fetch_thread, j);
    if (e) { pthread_mutex_destroy(&j->mu); pthread_cond_destroy(&j->cv); free(j); SRED("no thread to fetch the cloud's save (error %d)", e); return -1; }   // not fetched on this thread: a download that never finishes would hold the game
    pthread_detach(t);
    struct timespec ts; deadline(ms, &ts);
    pthread_mutex_lock(&j->mu);
    while (!j->done && pthread_cond_timedwait(&j->cv, &j->mu, &ts) != ETIMEDOUT) {}
    int r = j->done ? j->result : -1, mine = j->done;
    if (!mine) j->abandoned = 1;   // the thread frees it when it ends
    pthread_mutex_unlock(&j->mu);
    if (mine) {
        if (r == 1 && rename(j->part, local)) { SRED("cannot put the cloud's save at %s (errno=%d)", local, errno); r = -1; }
        if (r != 1) unlink(j->part);   // what a fetch that failed left, if anything
        pthread_mutex_destroy(&j->mu); pthread_cond_destroy(&j->cv); free(j);
    } else SLOG("the cloud's save did not come within %d s", ms / 1000);
    return r;
}

// ---------- the two directions ----------
// The pull's journal, <save>.pull: written and synced before the first of this device's folders moves, removed once the cloud's save is wholly in place (the commit
// point). It names the backup folder and, for each folder, what this device had there: nothing, an empty folder (the host makes DM_SAVE at every mount), or a save,
// with that folder's device and inode. A rename or a swap moves a folder whole and keeps its inode, so wherever a pull that failed, or an app killed in the middle of
// one, left this device's folder (in place, or in the backups), recover() finds it and puts it back. The journal lies beside the save: <save>.sync-tmp is cleared at
// every start and <save>-backups is pruned, and the mount reads it before either (mount_once). An app kill is covered; a power loss is not claimed (the folder renames
// are not synced to the disk)
enum { HAD_NONE, HAD_EMPTY, HAD_SAVE };   // what this device had in a folder before the pull
typedef struct { char kept[PATH_MAX]; int had[2]; uint64_t dev[2], ino[2]; } pull_journal;
static void journal_path(const char *save, char *out, size_t n) { snprintf(out, n, "%s.pull", save); }
static int journal_write(const char *save, const pull_journal *j) {
    char p[PATH_MAX], t[PATH_MAX + 8], b[PATH_MAX + 512], dir[PATH_MAX]; int e = 0;
    journal_path(save, p, sizeof p); snprintf(t, sizeof t, "%s.tmp", p);
    int L = snprintf(b, sizeof b, "# save sync (dm/host/save_sync.c): a pull of the cloud's save in progress; the next start puts this device's save back\nkept\t%s\n", j->kept);
    for (int i = 0; i < 2 && L > 0 && L < (int)sizeof b; i++)
        L += snprintf(b + L, sizeof b - (size_t)L, "folder\t%d\t%d\t%llu\t%llu\n", i, j->had[i], (unsigned long long)j->dev[i], (unsigned long long)j->ino[i]);
    if (L <= 0 || L >= (int)sizeof b) { errno = ENAMETOOLONG; return -1; }
    int fd = open(t, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return -1;
    if (write_all(fd, b, (size_t)L) || fsync(fd)) e = errno;
    if (close(fd) && !e) e = errno;
    if (!e && rename(t, p)) e = errno;
    if (e) { unlink(t); errno = e; return -1; }
    snprintf(dir, sizeof dir, "%s", p); char *s = strrchr(dir, '/'); if (s) *s = 0;   // the rename on the disk too, as far as the folder's sync goes
    if (s && (fd = open(dir, O_RDONLY)) >= 0) { fsync(fd); close(fd); }
    return 0;
}
static int journal_read(const char *save, pull_journal *j) {   // 1: a pull did not finish; 0: none; -1: a journal that cannot be read
    char p[PATH_MAX], line[PATH_MAX + 64]; int got = 0;
    journal_path(save, p, sizeof p); memset(j, 0, sizeof *j);
    FILE *f = fopen(p, "r");
    if (!f) return errno == ENOENT ? 0 : -1;
    while (fgets(line, sizeof line, f)) {
        line[strcspn(line, "\n")] = 0;
        int i, had; unsigned long long dev, ino;
        if (!strncmp(line, "kept\t", 5)) { snprintf(j->kept, sizeof j->kept, "%s", line + 5); got |= 4; }
        else if (sscanf(line, "folder\t%d\t%d\t%llu\t%llu", &i, &had, &dev, &ino) == 4 && i >= 0 && i < 2 && had >= HAD_NONE && had <= HAD_SAVE) {
            j->had[i] = had; j->dev[i] = dev; j->ino[i] = ino; got |= 1 << i;
        }
    }
    fclose(f);
    return got == 7 ? 1 : -1;
}
static int is_folder(const char *p, uint64_t dev, uint64_t ino) { struct stat st; return !lstat(p, &st) && S_ISDIR(st.st_mode) && (uint64_t)st.st_dev == dev && (uint64_t)st.st_ino == ino; }
// This device's save back as it was before the pull the journal describes, from wherever that pull stopped; then the journal goes. Run again after it stopped itself,
// it goes on from there. What it removes is only ever the cloud's (still in the cloud): a folder that is not the one the journal names, or one where this device had none.
// 0: back (the journal removed); -1: not (the journal kept, and with it what this device's save is made of)
static int recover(const char *save, const pull_journal *j) {
    int ok = 1;
    for (int i = 0; i < 2; i++) {
        char here[PATH_MAX], old[PATH_MAX];
        folder_path(save, i, here, sizeof here); snprintf(old, sizeof old, "%s/%s", j->kept, FOLDERS[i]);
        if (j->had[i] == HAD_SAVE) {
            if (is_folder(here, j->dev[i], j->ino[i])) {   // in place: a folder of this name in the backups is the cloud's, on its way in
                if (*j->kept && !access(old, F_OK) && rm_tree(old)) ok = 0;
            } else if (*j->kept && is_folder(old, j->dev[i], j->ino[i])) {   // in the backups: swapped back over the cloud's, which then goes
                if (access(here, F_OK) ? rename(old, here) : renamex_np(old, here, RENAME_SWAP) || rm_tree(old)) ok = 0;
            } else { SRED("%s: this device's folder is neither in place nor in %s", here, *j->kept ? j->kept : "the backups"); ok = 0; }
        } else {   // no save of this device's here: none again (an empty folder where there was one), the cloud's removed
            if (!access(here, F_OK) && rm_tree(here)) ok = 0;
            if (ok && j->had[i] == HAD_EMPTY && mkdirs(here)) ok = 0;
        }
    }
    if (!ok) return -1;
    if (*j->kept) rmdir(j->kept);   // empty now, unless the player put something there
    char p[PATH_MAX]; journal_path(save, p, sizeof p);
    return unlink(p) && errno != ENOENT ? -1 : 0;
}
// The cloud's save replaces this one. It is unpacked beside it first (<save>.sync-tmp/in), the journal written, then each of its folders moved into this device's
// backup folder and swapped from there with the live one (renamex_np, as a Commit swaps): one step puts the cloud's folder in place and leaves this device's in the
// backups, so the staging folder, which every start clears, never holds the only copy of this device's save. A folder the cloud's save does not have goes to the
// backups too, so both hold the same. A step that fails puts everything back (recover, as the next start would after a kill). The older backups of this device's
// saves are pruned only once this one is complete. kept: the backup of this device's save, "" when it had none.
// 0: the cloud's save is in place. -1: this device's save is as it was (also when a folder of it cannot be listed: has_entries -1, nothing has moved, no journal
// written). -2: it could not be put back: the journal stays, and the next start tries again (until then the save is not mounted). errno: the first failure's
static int pull(const char *save, const char *bundle, ss_meta *r, char *kept, size_t kn) {
    char tmp[PATH_MAX], here[2][PATH_MAX], incoming[2][PATH_MAX], old[2][PATH_MAX], jp[PATH_MAX];
    pull_journal j; memset(&j, 0, sizeof j);
    int fresh[2], e = 0;
    snprintf(tmp, sizeof tmp, "%s.sync-tmp/in", save);
    kept[0] = 0;
    if (rm_tree(tmp) || mkdirs(tmp) || ss_read(bundle, tmp, r)) { e = errno; rm_tree(tmp); errno = e; return -1; }
    for (int i = 0; i < 2; i++) {
        struct stat st;
        folder_path(save, i, here[i], sizeof here[i]); snprintf(incoming[i], sizeof incoming[i], "%s/%s", tmp, FOLDERS[i]);
        fresh[i] = !access(incoming[i], F_OK);
        if (lstat(here[i], &st)) {
            if (errno != ENOENT) { e = errno; rm_tree(tmp); errno = e; return -1; }   // nothing has moved
            j.had[i] = HAD_NONE;
        } else {
            int he = has_entries(here[i]);
            if (he < 0) { e = errno; rm_tree(tmp); errno = e; return -1; }   // a folder it cannot list is never taken for an empty one (a save that would be removed): nothing has moved
            j.had[i] = he ? HAD_SAVE : HAD_EMPTY;
        }
        if (j.had[i] == HAD_SAVE) { j.dev[i] = (uint64_t)st.st_dev; j.ino[i] = (uint64_t)st.st_ino; }
    }
    if ((j.had[0] == HAD_SAVE || j.had[1] == HAD_SAVE) && backup_dir(save, "local", kept, kn)) { e = errno; kept[0] = 0; rm_tree(tmp); errno = e; return -1; }   // pruned only once the pull is complete
    snprintf(j.kept, sizeof j.kept, "%s", kept);
    if (journal_write(save, &j)) { e = errno; if (*kept) rmdir(kept); kept[0] = 0; rm_tree(tmp); errno = e; return -1; }   // nothing of this device's has moved
    for (int i = 0; i < 2; i++) {
        snprintf(old[i], sizeof old[i], "%s/%s", kept, FOLDERS[i]);
        if (j.had[i] == HAD_SAVE && fresh[i]) { if (rename(incoming[i], old[i]) || renamex_np(old[i], here[i], RENAME_SWAP)) { e = errno; goto undo; } }
        else if (j.had[i] == HAD_SAVE) { if (rename(here[i], old[i])) { e = errno; goto undo; } }
        else if (fresh[i]) {   // no save in this folder: an empty one is swapped into the staging folder, which is cleared
            if (access(here[i], F_OK) ? rename(incoming[i], here[i]) : renamex_np(incoming[i], here[i], RENAME_SWAP)) { e = errno; goto undo; }
        }
    }
    journal_path(save, jp, sizeof jp);
    if (unlink(jp)) { e = errno; goto undo; }   // the commit point
    rm_tree(tmp);
    if (*kept) prune_backups(save, "local", kept);
    return 0;
undo:
    {   int back = !recover(save, &j);
        if (back) kept[0] = 0;   // nothing of this device's save is in the backups now
        rm_tree(tmp);   // the cloud's save only (and an empty folder this device had): nothing of this device's save is ever here
        errno = e;
        return back ? -1 : -2; }
}

// The cloud's file as this device's last send left it (send_save, just after the store): which file it is on disk, and the save it holds. The next send compares the file
// there with it by stat alone: the same file, untouched since (device, inode, size, modification and birth times), is this device's own copy, and it is not fetched and read
// through again (on the iPhone a coordinated copy of the whole file and a hash of every byte, at every send). A file another device sent, or one iCloud downloaded or put
// back, is another file and is fetched as before; so is the cloud file of a <save>.sync that names another save. Per process: a start's mount always reads the cloud's file
typedef struct { int set, files; char cloud[PATH_MAX], hash[SS_HASH + 1]; dev_t dev; ino_t ino; off_t size; struct timespec mtime, birth; } own_copy;
static own_copy g_own; static pthread_mutex_t g_own_mu = PTHREAD_MUTEX_INITIALIZER;
static _Atomic uint64_t g_own_skips;   // sends that found the cloud's file still this device's own (the tests read it)
// The identity is taken from the file itself, once the store has returned: opened, fstat, and noted only when its header names the save this send stored. iCloud can put
// another device's file at the path between the store's rename and here (two devices playing at once); noted by a stat of the path, that file would pass for this device's
// own at the next send, which would then replace it with no "changed since this device's last sync" check. Its header names its own save: nothing is noted, and the next
// send reads it. A dataless file (iCloud has only listed it) is not read here: nothing noted either
static void own_note(const char *cloud, const ss_meta *m) {
    struct stat st; uint8_t hdr[HDR]; int ok = 0, fd = open(cloud, O_RDONLY | O_CLOEXEC);
    if (fd >= 0) {
        ok = !fstat(fd, &st) && !(st.st_flags & SF_DATALESS) && pread(fd, hdr, HDR, 0) == HDR && !memcmp(hdr, MAGIC, 8)
             && strlen(m->hash) == SS_HASH && !memcmp(hdr + 16, m->hash, SS_HASH);
        close(fd);
    }
    pthread_mutex_lock(&g_own_mu);
    g_own.set = ok;
    if (ok) { snprintf(g_own.cloud, sizeof g_own.cloud, "%s", cloud); snprintf(g_own.hash, sizeof g_own.hash, "%s", m->hash); g_own.files = m->files;
              g_own.dev = st.st_dev; g_own.ino = st.st_ino; g_own.size = st.st_size; g_own.mtime = st.st_mtimespec; g_own.birth = st.st_birthtimespec; }
    pthread_mutex_unlock(&g_own_mu);
}
static void own_forget(void) { pthread_mutex_lock(&g_own_mu); g_own.set = 0; pthread_mutex_unlock(&g_own_mu); }
static int same_ts(struct timespec a, struct timespec b) { return a.tv_sec == b.tv_sec && a.tv_nsec == b.tv_nsec; }
// 1: the cloud's file is this device's last send, untouched, and that save is the one last synced (base): *other says what it holds, as a read of it would
static int own_still(const char *cloud, const char *base, ss_meta *other) {
    struct stat st; int same = 0;
    if (stat(cloud, &st)) return 0;
    pthread_mutex_lock(&g_own_mu);
    if (g_own.set && !strcmp(g_own.cloud, cloud) && !strcmp(g_own.hash, base) && g_own.dev == st.st_dev && g_own.ino == st.st_ino && g_own.size == st.st_size
        && same_ts(g_own.mtime, st.st_mtimespec) && same_ts(g_own.birth, st.st_birthtimespec)) {
        same = 1; memset(other, 0, sizeof *other); snprintf(other->hash, sizeof other->hash, "%s", g_own.hash); other->files = g_own.files;
    }
    pthread_mutex_unlock(&g_own_mu);
    if (same) atomic_fetch_add(&g_own_skips, 1);
    return same;
}
uint64_t ss_own_skips(void) { return atomic_load(&g_own_skips); }

// What this device committed goes to the cloud, unless the cloud already has it. It replaces only what it was compared against: no save, the save last synced
// (<save>.sync), or a damaged file (kept first). A cloud save that changed since this device's last sync (another device sent it, or this device never synced) is
// not replaced: the next start decides between the two (ss_decide: the newer one, or the player's choice when a front end asks).
// The base it compares with is this device's last sync, whichever cloud file that was with: the same save again has nothing new to send, unless `seen` says it is to go
// (another folder picked, or the cloud's file gone: mount_once, save_sync_after_exit). Then it goes only to the cloud as it was found: seen "" no file, or the hash of the
// save there. A cloud that changed since (another device sent its save, or a file it cannot read) is the next start's to compare: nothing is sent, and that is 1 too.
// 1 = in step with the cloud, 0 = not: the cloud cannot be read or written now (the next Commit, a flush or the Mac launcher tries again), or it waits for the next start.
// *stored: 1 when it wrote the cloud's file. why: what sent it before the sender's gap (a flush), for the log; NULL none
static int send_save(const char *save, const char *title, const char *cloud, const char *seen, int *stored, const char *why) {
    char tmp[PATH_MAX], snap[PATH_MAX], packed[PATH_MAX], theirs[PATH_MAX], dir[PATH_MAX], kept[PATH_MAX], t[32];
    ss_meta mine, other; sync_state st; int ok = 0, got, bad, again, own = 0; struct stat ps;
    *stored = 0;
    snprintf(tmp, sizeof tmp, "%s.sync-tmp/out", save); snprintf(snap, sizeof snap, "%s/s", tmp);
    snprintf(packed, sizeof packed, "%s/save.dmsync", tmp); snprintf(theirs, sizeof theirs, "%s/cloud.dmsync", tmp);
    if (rm_tree(tmp) || mkdirs(tmp)) { SRED("cannot make %s (errno=%d)", tmp, errno); goto done; }
    // A clone of the committed folders, taken while no Commit can swap them: the game may commit again while this packs
    for (int i = 0; i < 2; i++) {
        char from[PATH_MAX], to[PATH_MAX]; folder_path(save, i, from, sizeof from); folder_path(snap, i, to, sizeof to);
        if (has_entries(from) && dm_fs_clone_committed(from, to)) { SRED("cloning %s failed (errno=%d)", from, errno); goto done; }
    }
    if (ss_pack(snap, title, packed, &mine)) { SRED("packing %s failed (errno=%d)", save, errno); goto done; }
    read_base(save, &st);
    again = !strcmp(mine.hash, st.base);   // the save this device last synced
    if (!mine.files || (again && !seen)) { ok = 1; goto done; }   // no save yet, or the one already in step
    if ((own = own_still(cloud, st.base, &other))) got = 1;   // this device's last send, still there: not fetched and read again
    else if ((got = fetch_timed(cloud, theirs, FETCH_MS)) < 0) { SLOG("the cloud's save %s cannot be read now; sending later", cloud); goto done; }
    bad = !own && got && ss_read(theirs, NULL, &other);
    if (got && !bad && !strcmp(other.hash, mine.hash)) { write_base(save, mine.hash, cloud); ok = 1; goto done; }
    if (again && (bad || strcmp(got ? other.hash : "", seen))) {
        SLOG("the cloud's save %s changed meanwhile: this device's, the one it last synced, is not sent; the next start compares the two", cloud); ok = 1; goto done;
    }
    if (bad) {   // no save can be read from it, so no progress is lost: the file itself is kept, then replaced
        char raw[PATH_MAX + 16];
        if (backup_dir(save, "cloud", kept, sizeof kept)) { SRED("cannot keep the cloud's damaged save before replacing it (errno=%d); not sent", errno); goto done; }
        if (snprintf(raw, sizeof raw, "%s/save.dmsync", kept) >= (int)sizeof raw || rename(theirs, raw)) {   // the folder goes again: an empty one would take a backup's slot
            int e = errno; rmdir(kept); SRED("cannot keep the cloud's damaged save before replacing it (errno=%d); not sent", e); goto done;
        }
        prune_backups(save, "cloud", kept);
        SRED("the cloud's save %s is damaged; this device's replaces it, and the damaged file is kept in %s", cloud, kept);
    }
    else if (got && other.files && strcmp(other.hash, st.base)) {
        static _Atomic int told;   // once a session: the sender comes here after every Commit
        when(other.saved, t, sizeof t);
        if (!atomic_exchange(&told, 1)) SLOG("not sent: the cloud's save (from %s, saved %s) changed since this device's last sync, and so did this one; the next start decides between the two", other.device, t);
        goto done;
    }
    snprintf(dir, sizeof dir, "%s", cloud); *strrchr(dir, '/') = 0;
    own_forget();   // what is there from now on is not known until the store has gone through
    if (mkdirs(dir) || front_save_sync_store(packed, cloud) != 1) { SRED("sending to %s failed (errno=%d)", cloud, errno); goto done; }
    own_note(cloud, &mine);
    write_base(save, mine.hash, cloud); ok = 1; *stored = 1;
    when(mine.saved, t, sizeof t);
    SLOG("sent: %d files, %.2f MB, saved %s, to %s%s%s%s", mine.files, stat(packed, &ps) ? 0.0 : ps.st_size / 1048576.0, t, cloud,
         own ? "; the cloud's copy was this device's last send, not read again" : "", why ? "; at once: " : "", why ? why : "");
done:
    rm_tree(tmp); *strrchr(tmp, '/') = 0; rmdir(tmp);   // <save>.sync-tmp too, once nothing else is in it (a fetch that came too late may still be)
    return ok;
}

// ---------- the host: the first mount, the sender, flushes ----------
static pthread_mutex_t g_mu = PTHREAD_MUTEX_INITIALIZER, g_mount_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cv = PTHREAD_COND_INITIALIZER;
static _Atomic int g_on;
static int g_mounted, g_want, g_busy, g_failed;   // the mount ran; a send asked for without a Commit (the mount found this save newer, a flush); a send running; the last one failed
static int g_force;                               // the mount found the save its base names is to go (send_save's seen: g_seen) and it has not gone yet
static uint64_t g_commits, g_sent, g_upto;        // Commits seen; the Commits the last send covered; those the send under way covers (g_busy)
static _Atomic uint64_t g_passes;                 // the sender's passes (send_save calls), for the tests (ss_passes)
// The sender's pacing: a send goes once the game has been quiet g_quiet_ms since its last Commit and, in play, g_gap_ms since the last send went (g_sent_ns; none yet this
// session: the first goes after the quiet wait). A flush goes at once, past both (g_want; g_why says what asked, for the log): the in-game menu opening (dm_front_menu_set),
// the game leaving focus (dm_focus_set 2 from 1: the iPhone's resign active, before a swipe in the app switcher that kills the app; the Mac's window losing its focus), the
// app going to the background (dm_focus_set 3: the iPhone's flush, the Mac's minimized window), the game ending (the graceful exit), the mount's push. The local save is
// not touched by any of it: a Commit is on disk, whole, when it returns (hle_fs.c), and a kill before the send leaves the cloud's copy at most about g_gap_ms behind, which
// the next start's mount finds as "only this one changed" (the base is still the last send's) and sends
static int g_quiet_ms = QUIET_MS, g_gap_ms = GAP_MS;
static uint64_t g_commit_ns, g_sent_ns;           // the last Commit; the last send that wrote the cloud's file (0: none this session)
static const char *g_why;                         // what asked for the flush under way (a static string), NULL: none
static uint64_t mono_ns(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC); }
void ss_pacing_set(int quiet_ms, int gap_ms) { pthread_mutex_lock(&g_mu); g_quiet_ms = quiet_ms; g_gap_ms = gap_ms; pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu); }
static char g_save[PATH_MAX], g_title[24], g_cloud[PATH_MAX], g_seen[SS_HASH + 1];

// The mount's push of the save its base names (g_force), not gone out yet: <save>.sync-tmp/push holds the cloud as the mount found it (seen: "" for no file). The Mac
// launcher's send after the host (save_sync_after_exit) sends that save only on this mark, so it never sends it to a cloud it merely cannot see a file in (an iCloud
// Drive that has not yet listed another device's new upload) unless this start's mount found it so. The next start's mount clears the folder, and decides again
static void push_mark(const char *save, const char *seen) {
    char d[PATH_MAX], p[PATH_MAX + 8]; snprintf(d, sizeof d, "%s.sync-tmp", save); snprintf(p, sizeof p, "%s/push", d);
    FILE *f = mkdirs(d) ? NULL : fopen(p, "w"); int bad = !f, e = errno;
    if (f) { if (fprintf(f, "%s\n", seen) < 0) { bad = 1; e = errno; } if (fclose(f) && !bad) { bad = 1; e = errno; } if (bad) unlink(p); }
    if (bad) SLOG("cannot mark the push in %s (errno=%d): the Mac launcher does not send it if the game ends first", p, e);
}
static void push_unmark(const char *save) {
    char d[PATH_MAX], p[PATH_MAX + 8]; snprintf(d, sizeof d, "%s.sync-tmp", save); snprintf(p, sizeof p, "%s/push", d);
    unlink(p); rmdir(d);   // the folder too, once nothing else is in it
}
static int push_marked(const char *save, char *seen, size_t n) {   // 1: the mark is there, seen what it holds
    char p[PATH_MAX + 16], ln[SS_HASH + 4] = ""; snprintf(p, sizeof p, "%s.sync-tmp/push", save);
    FILE *f = fopen(p, "r"); if (!f) return 0;
    if (!fgets(ln, sizeof ln, f)) ln[0] = 0;
    fclose(f);
    ln[strcspn(ln, "\n")] = 0; snprintf(seen, n, "%s", ln);
    return 1;
}

static void *sender(void *arg) {
    (void)arg;
    pthread_mutex_lock(&g_mu);
    for (;;) {
        while (g_commits == g_sent && !g_want) pthread_cond_wait(&g_cv, &g_mu);
        while (!g_want) {   // quiet since the last Commit, and in play the gap since the last send (a flush waits for neither)
            uint64_t now = mono_ns(), due = g_commit_ns + (uint64_t)g_quiet_ms * 1000000ull;
            if (g_sent_ns && g_sent_ns + (uint64_t)g_gap_ms * 1000000ull > due) due = g_sent_ns + (uint64_t)g_gap_ms * 1000000ull;
            if (now >= due) break;
            struct timespec rel = {(time_t)((due - now) / 1000000000ull), (long)((due - now) % 1000000000ull)};
            pthread_cond_timedwait_relative_np(&g_cv, &g_mu, &rel);
        }
        uint64_t upto = g_upto = g_commits; const char *why = g_want ? g_why : NULL; g_want = 0; g_why = NULL; g_busy = 1;
        const char *seen = g_force ? g_seen : NULL;
        pthread_mutex_unlock(&g_mu);
        atomic_fetch_add(&g_passes, 1);
        int stored = 0, ok = send_save(g_save, g_title, g_cloud, seen, &stored, why);
        pthread_mutex_lock(&g_mu);
        if (stored) g_sent_ns = mono_ns();
        g_busy = 0; g_sent = upto; g_failed = !ok; if (ok && g_force) { g_force = 0; push_unmark(g_save); }
        pthread_cond_broadcast(&g_cv);
    }
    return NULL;
}

// A quit through exit() (the Mac's ⌘Q, its window closed): what was committed and not sent goes now, within QUIT_MS. The graceful exit (hle_lifecycle.c) asks the same
// before its _exit. The iPhone app ends without either: after its trip to the background, which flushes, or killed by a swipe in the app switcher, which comes with no
// trip to the background and no atexit; the resign active before it has started the send (dm_focus_set 2, hle_oe.c), and a send the kill cuts short leaves the cloud's
// file as it was (the store renames a whole file over it)
static void at_quit(void) {
    save_sync_soon("the game is ending");
    if (!save_sync_flush(QUIT_MS)) SLOG("the save did not reach the cloud at the quit; it goes at the next start");
}

// The first save mount: an interrupted pull put right first, whatever the sync setting (a player may have turned sync off since), before the staging folder is cleared
// and before a sender can pack what is in place; then, with sync on, the cloud's save and this one compared. 0: this device's save may be mounted; -1: it may not
// (an interrupted or failed pull could not be put back: what this device's save is made of stays where the journal says, and the next start tries again)
static int mount_once(const char *save, const char *title) {
    char cloud[PATH_MAX], tmp[PATH_MAX], theirs[PATH_MAX], kept[PATH_MAX], t[32], t2[32], chosen[SS_HASH + 1];
    ss_meta mine, other; sync_state st; memset(&other, 0, sizeof other); kept[0] = 0;
    pull_journal j; int jr = journal_read(save, &j);
    if (jr < 0) { SRED("%s.pull, the journal of a pull of the cloud's save, cannot be read (errno=%d): the save is not mounted; this device's save is in place or in %s-backups", save, errno, save); return -1; }
    if (jr) {
        SLOG("a pull of the cloud's save did not finish: putting this device's save back");
        if (recover(save, &j)) { SRED("this device's save could not be put back (errno=%d): it is not mounted; what is not in %s is kept in %s, and the next start tries again", errno, save, *j.kept ? j.kept : "its backups"); return -1; }
        SLOG("this device's save is back as it was before that pull");
    }
    if (!cloud_file(title, cloud, sizeof cloud)) return 0;
    SLOG("on: %s (in play, sends at least %d s apart; at once when the in-game menu opens, the app goes to the background or the game ends)", cloud, g_gap_ms / 1000);
    snprintf(tmp, sizeof tmp, "%s.sync-tmp", save); snprintf(theirs, sizeof theirs, "%s/in.dmsync", tmp);
    if (rm_tree(tmp) || mkdirs(tmp)) { SRED("cannot make %s (errno=%d): off", tmp, errno); return 0; }   // rm_tree: what an earlier session left
    if (ss_scan(save, &mine)) { SRED("this device's save %s cannot be read (errno=%d): off", save, errno); return 0; }
    read_base(save, &st);
    choice_kind choice = read_choice(chosen);
    int got = choice == CH_OFFLINE ? -1 : fetch_timed(cloud, theirs, FETCH_MS), both = 0, failed = 0, pr, damaged = 0;
    if (got > 0 && ss_read(theirs, NULL, &other)) { SRED("the cloud's save %s is damaged: playing on with this device's, which replaces it (the damaged file is kept)", cloud); got = 0; damaged = 1; }
    else if (got > 0 && strcasecmp(other.title, title)) { SRED("the cloud's save %s is %s's, not %s's: not used", cloud, other.title, title); got = -1; }
    // Another folder's base says nothing about this one (base_for): two saves that differ are compared, the newer winning or, with a front end that asks, the player's
    // choice. The launchers' report decides with the same rule, so a front end that asks sees that conflict too and asks the player, and its "ask" means as ever that
    // it saw nothing to choose (it could not see the cloud's file yet, say): neither is replaced until the player has chosen
    const char *base = base_for(&st, cloud, got > 0 ? other.hash : "");
    if (*st.base && !*base) SLOG("this device last synced with %s, not this folder's file: a first sync with it", *st.cloud ? st.cloud : "another cloud file");
    if (got < 0) { SLOG("playing on with this device's save; it is not sent until it has been compared with the cloud's"); failed = 1; }
    ss_way way = got < 0 ? SS_KEEP : ss_decide(mine.hash, base, got ? other.hash : "", mine.saved, other.saved, choice != CH_NONE, &both);
    // The player's choice, for the save it was made on (the cloud's may have changed between the check and this mount)
    const char *now = got > 0 && other.files ? other.hash : "none";
    if ((choice == CH_CLOUD || choice == CH_LOCAL) && got >= 0 && way != SS_KEEP) {
        if (strcmp(choice == CH_CLOUD ? chosen : (*chosen ? chosen : "none"), now))   // the way stays ss_decide's: a save that changed on both sides is replaced on neither
            SRED("the cloud's save changed after the player chose (now %s): the choice is not used", now);
        else way = choice == CH_CLOUD ? SS_PULL : SS_PUSH;
    } else if (choice == CH_OFFLINE) SLOG("the player chose to play with this device's save without the cloud's");
    switch (way) {
    case SS_PULL:
        when(other.saved, t, sizeof t);
        if ((pr = pull(save, theirs, &other, kept, sizeof kept))) {
            if (pr == -2) {
                if (*kept) SRED("bringing the cloud's save in failed (errno=%d), and this device's could not all be put back: it is not mounted; what is not in %s is kept in %s, and the next start tries again", errno, save, kept);
                else SRED("bringing the cloud's save in failed (errno=%d), and part of the cloud's could not be taken out again: it is not mounted; %s holds some of it (this device had no save), and the next start tries again", errno, save);
                rm_tree(tmp); return -1;
            }
            SRED("bringing the cloud's save in failed (errno=%d): playing on with this device's", errno);
            failed = 1; break;
        }
        write_base(save, other.hash, cloud);
        SLOG("brought in the cloud's save (from %s, saved %s%s)%s%s", other.device, t, choice == CH_CLOUD ? ", the player's choice" : !both ? "" : *base ? ", the newer of two that both changed" : ", the newer of the two",
             *kept ? "; this device's is kept in " : "", kept);
        break;
    case SS_PUSH:
        // Over a cloud save that changed since the last sync (the newer of two that both changed, the first sync with another folder's file, or the player's choice): the
        // start chose against it, so it is kept first and counts as the one last synced; the sender replaces only that one (send_save), not a save another device sends
        // meanwhile. This comes before the push below: a cloud save not kept stops here, before anything is forced
        if (got > 0 && other.files && strcmp(other.hash, base)) {
            if (backup_dir(save, "cloud", kept, sizeof kept)) { SRED("cannot keep the cloud's save before replacing it (errno=%d): not sent", errno); kept[0] = 0; failed = 1; break; }
            if (ss_read(theirs, kept, &other)) {   // only a copy (the cloud's file is still there): what was unpacked goes, so no part-filled folder takes a backup's slot
                int e = errno; rm_tree(kept); kept[0] = 0; SRED("cannot keep the cloud's save before replacing it (errno=%d): not sent", e); failed = 1; break;
            }
            prune_backups(save, "cloud", kept);
            write_base(save, other.hash, cloud);
        }
        when(mine.saved, t, sizeof t); when(other.saved, t2, sizeof t2);
        // The sender skips the save its base names (send_save). This is that save: this start's sender sends it anyway, to the cloud as found here (no file, or the save it
        // was compared with), so it goes now, not only once the game saves again. Only in memory: <save>.sync changes once it has gone, and a push that does not go out
        // (the app killed, the cloud not written) leaves the next start to decide again. Not over a file it cannot read (damaged, or a newer build's format): that one is
        // replaced only by a save that differs, as before (send_save keeps the damaged file first)
        if (!strcmp(mine.hash, st.base)) {
            if (damaged) { SLOG("this device's save (saved %s) is the one it last synced: it replaces the cloud's damaged file once the game saves", t); break; }
            g_force = 1; snprintf(g_seen, sizeof g_seen, "%s", got ? other.hash : "");
        }
        // No file: a base this cloud file had says it was there once; one an older build wrote says nothing about which file had it
        SLOG("this device's save (saved %s) %s: it goes to the cloud", t, damaged ? "replaces the cloud's damaged file"
             : !got || !other.files ? !*base ? "is not in the cloud yet" : st.named ? "is no longer in the cloud" : "is not in the cloud"
             : choice == CH_LOCAL ? "is the player's choice" : !both ? "changed since the last sync" : *base ? "is the newer of two that both changed" : "is the newer of the two");
        if (*kept) SLOG("the cloud's save it replaces (from %s, saved %s) is kept in %s", other.device, t2, kept);
        g_want = 1; g_why = "the start found this device's save to send";
        break;
    case SS_ASK:
        when(other.saved, t, sizeof t); when(mine.saved, t2, sizeof t2);
        SLOG("both changed: the cloud's save (from %s, saved %s) and this device's (saved %s); playing on with this device's, and neither replaces the other until the player chooses at the next start", other.device, t, t2);
        failed = 1;
        break;
    case SS_KEEP:
        if (got > 0 && mine.files) { write_base(save, mine.hash, cloud); SLOG("in step with the cloud"); }
        else if (!got) SLOG("no save here or in the cloud yet");
        break;
    }
    rm_tree(tmp);
    if (g_force) push_mark(save, g_seen);   // before the sender starts: it removes the mark once the push has gone
    snprintf(g_save, sizeof g_save, "%s", save); upper_title(title, g_title, sizeof g_title); snprintf(g_cloud, sizeof g_cloud, "%s", cloud);
    g_failed = failed;
    pthread_t th;
    if (pthread_create(&th, NULL, sender, NULL)) { SRED("cannot start the sender: saves are not sent this session"); return 0; }
    pthread_detach(th);
    atomic_store(&g_on, 1);
    atexit(at_quit);
    return 0;
}

// ---------- what a front end asks the player with ----------
// The two saves and the one last synced, as the mount will see them (dm/host/save_sync.h). The cloud's file is found as the mount finds it (cloud_path) and fetched
// through the same front-end call, so on the iPhone the report is what downloads a file iCloud has only listed. It goes to a file of its own under <save>.sync-tmp:
// a report the front end stopped waiting for may still be fetching when the next one starts, or when the game's mount clears the folder.
int save_sync_report(const char *save, const char *title, const char *folder, int wait_ms, char *out, size_t n) {
    char dd[PATH_MAX], cloud[PATH_MAX], tmp[PATH_MAX], theirs[PATH_MAX], dev[64];
    static _Atomic int seq;
    ss_meta mine, other; sync_state st; int got = -1, both = 0, same = 1, on;
    memset(&other, 0, sizeof other);
    if (!save || !*save || !title || !*title || !out || !n) return -1;
    snprintf(dd, sizeof dd, "%s", save); size_t L = strlen(dd); while (L > 1 && dd[L - 1] == '/') dd[--L] = 0;
    if (ss_scan(dd, &mine)) return -1;
    read_base(dd, &st);
    if ((on = cloud_path(folder ? folder : getenv("DM_SAVE_SYNC"), title, cloud, sizeof cloud))) {
        snprintf(tmp, sizeof tmp, "%s.sync-tmp", dd);
        snprintf(theirs, sizeof theirs, "%s/report-%d-%d.dmsync", tmp, (int)getpid(), atomic_fetch_add(&seq, 1));
        if (!mkdirs(tmp)) {
            got = fetch_timed(cloud, theirs, wait_ms > 0 ? wait_ms : FETCH_MS);
            if (got > 0 && ss_read(theirs, NULL, &other)) { SRED("the cloud's save %s is damaged", cloud); got = 0; memset(&other, 0, sizeof other); }   // the mount replaces it
            unlink(theirs); rmdir(tmp);
        }
        if (got > 0 && strcasecmp(other.title, title)) same = 0;
    }
    pull_journal j; int pending = journal_read(dd, &j) != 0;   // a pull that did not finish: what is in place may be half the cloud's, so no comparison is offered;
    if (got >= 0 && same && !pending)   // the mount puts this device's save back, then compares; another folder's base counts for nothing, as at the mount (base_for)
        ss_decide(mine.hash, base_for(&st, cloud, got > 0 ? other.hash : ""), got > 0 ? other.hash : "", mine.saved, other.saved, 1, &both);
    snprintf(dev, sizeof dev, "%s", other.device); for (char *s = dev; *s; s++) if (*s == ' ' || *s == '=') *s = '_';
    int w = snprintf(out, n, "sync=%d cloud=%d local=%s saved=%lld files=%d size=%lld chash=%s csaved=%lld cfiles=%d csize=%lld cdevice=%s sametitle=%d conflict=%d pull=%d",
                     on, on ? got : 0, *mine.hash ? mine.hash : "-", (long long)mine.saved, mine.files, (long long)mine.bytes,
                     got > 0 && *other.hash ? other.hash : "-", (long long)other.saved, other.files, (long long)other.bytes, *dev ? dev : "-", same, both, pending);
    return w < 0 || w >= (int)n ? -1 : 0;
}

// ---------- moving this game's cloud saves between two folders (gate-ui §21.4) ----------
// The NX 18 folder and a game's own folder: the front end switches DM_SAVE_SYNC's folder only after this has put the save where it is going and read it back. The old copy stays.
int save_sync_move(const char *save, const char *from, const char *to, const char *title, ss_move how, int wait_ms, char *out, size_t n) {
    char cf[PATH_MAX], ct[PATH_MAX], dd[PATH_MAX], tmp[PATH_MAX], a[PATH_MAX], b[PATH_MAX], kept[PATH_MAX], dir[PATH_MAX];
    static _Atomic int seq;
    ss_meta mf, mt, back; int r = SS_MOVE_FAIL;
    memset(&mf, 0, sizeof mf); memset(&mt, 0, sizeof mt);
    if (out && n) out[0] = 0;
    if (!save || !*save || !title || !*title || !cloud_path(from, title, cf, sizeof cf) || !cloud_path(to, title, ct, sizeof ct)) return SS_MOVE_FAIL;
    if (same_cloud(cf, ct)) { SLOG("move: the two folders hold the same file; only the mode changes"); return SS_MOVE_SAME; }
    snprintf(dd, sizeof dd, "%s", save); size_t L = strlen(dd); while (L > 1 && dd[L - 1] == '/') dd[--L] = 0;
    snprintf(tmp, sizeof tmp, "%s.sync-tmp", dd);
    int k = atomic_fetch_add(&seq, 1);
    snprintf(a, sizeof a, "%s/move-%d-%d-from.dmsync", tmp, (int)getpid(), k); snprintf(b, sizeof b, "%s/move-%d-%d-to.dmsync", tmp, (int)getpid(), k);
    if (mkdirs(tmp)) return SS_MOVE_FAIL;
    int ms = wait_ms > 0 ? wait_ms : FETCH_MS;
    int gf = fetch_timed(cf, a, ms);   // 1. the save where it is now, checked whole
    if (gf < 0 || (gf > 0 && ss_read(a, NULL, &mf))) { SRED("move: the save in the folder it leaves could not be read whole; nothing changes"); goto done; }
    if (gf == 0) { SLOG("move: no save in the folder it leaves; only the folder changes"); r = SS_MOVE_DONE; goto done; }
    int gt = fetch_timed(ct, b, ms);   // 2. what the folder it goes to holds already
    if (gt < 0) { SRED("move: the folder it goes to could not be read; nothing changes"); goto done; }
    if (gt > 0 && !ss_read(b, NULL, &mt) && mt.files) {
        if (!strcmp(mt.hash, mf.hash)) { SLOG("move: the folder it goes to holds the same save already"); r = SS_MOVE_DONE; goto done; }
        if (how == SS_MOVE_ASK_FIRST) {
            if (out && n) snprintf(out, n, "from_saved=%lld to_saved=%lld", (long long)mf.saved, (long long)mt.saved);
            r = SS_MOVE_ASK; goto done;
        }
        if (how == SS_MOVE_USE_THERE) { SLOG("move: the save there is kept; the next start compares it"); r = SS_MOVE_DONE; goto done; }
        // Replace: the one there is kept first, in the cloud side's backups
        if (backup_dir(dd, "cloud", kept, sizeof kept) || ss_read(b, kept, &mt)) { SRED("move: cannot keep the save there before replacing it (errno=%d); nothing changes", errno); goto done; }
        prune_backups(dd, "cloud", kept);
    }
    // 3. stored, read back, compared
    snprintf(dir, sizeof dir, "%s", ct); char *sl = strrchr(dir, '/'); if (sl) *sl = 0;
    if (mkdirs(dir) || front_save_sync_store(a, ct) != 1) { SRED("move: storing the save in the folder it goes to failed (errno=%d); nothing changes", errno); goto done; }
    unlink(b); memset(&back, 0, sizeof back);
    if (fetch_timed(ct, b, ms) != 1 || ss_read(b, NULL, &back) || strcmp(back.hash, mf.hash)) { SRED("move: the stored save did not read back the same; nothing changes"); goto done; }
    SLOG("move: the save is in the new folder and checked");
    r = SS_MOVE_DONE;
done:
    unlink(a); unlink(b); rmdir(tmp);
    return r;
}

int save_sync_mount(const char *save, const char *title) {   // the first mount does it; a second one (the device save) waits for it and gets its answer
    static int unsafe;
    pthread_mutex_lock(&g_mount_mu);
    if (!g_mounted) { g_mounted = 1; unsafe = mount_once(save, title) != 0; }
    int r = unsafe ? -1 : 0;
    pthread_mutex_unlock(&g_mount_mu);
    return r;
}

void save_sync_committed(void) {
    if (!atomic_load(&g_on)) return;
    pthread_mutex_lock(&g_mu); g_commits++; g_commit_ns = mono_ns(); pthread_cond_broadcast(&g_cv); pthread_mutex_unlock(&g_mu);
}

// Under g_mu. What a send now would add: with one under way, the Commits past those it covers (it clones the save after they are on disk); with none, the Commits past the
// last send's, or a last send that failed. A send asked for while one runs that covers them all would only clone and pack the same save again to find it in step
static int send_owed(void) { return g_busy ? g_commits != g_upto : g_commits != g_sent || g_failed; }
static void send_ask(const char *why) { g_want = 1; if (!g_why) g_why = why; pthread_cond_broadcast(&g_cv); }
uint64_t ss_passes(void) { return atomic_load(&g_passes); }

void save_sync_soon(const char *why) {
    if (!atomic_load(&g_on)) return;
    pthread_mutex_lock(&g_mu);
    if (send_owed()) send_ask(why);   // nothing new, or all of it in the send under way: nothing to ask
    pthread_mutex_unlock(&g_mu);
}

// The Commits made before the flush, in the cloud. A send under way that covers them is waited for, not asked again (save_sync_soon just before, as the background, the
// graceful exit and the quit do, has started it); only when it fails does the flush ask for one of its own, as it does with none under way. Commits made while it waits are
// the sender's, at its own pace
int save_sync_flush(int timeout_ms) {
    if (!atomic_load(&g_on)) return 1;
    struct timespec ts; deadline(timeout_ms, &ts);
    pthread_mutex_lock(&g_mu);
    uint64_t upto = g_commits;
    if (send_owed()) send_ask("a flush");
    int own = g_want;   // a send not started yet covers them: the flush's own
    for (;;) {
        if (!g_want && !g_busy) {
            if (g_sent >= upto && !g_failed) break;
            if (own) break;   // its own send ran and did not reach the cloud
            own = 1; send_ask("a flush");   // the send it waited for failed
        }
        if (pthread_cond_timedwait(&g_cv, &g_mu, &ts) == ETIMEDOUT) break;
    }
    int ok = !g_want && !g_busy && g_sent >= upto && !g_failed;
    pthread_mutex_unlock(&g_mu);
    return ok;
}

// No file at the cloud path, nor the placeholder iCloud lists for one it has not downloaded (.<name>.icloud), as SaveSync.m looks: a save sent there replaces nothing
static int no_cloud_file(const char *cloud) {
    char ph[PATH_MAX]; struct stat st; const char *name = strrchr(cloud, '/');
    if (!name || snprintf(ph, sizeof ph, "%.*s/.%s.icloud", (int)(name - cloud), cloud, name + 1) >= (int)sizeof ph) return 0;
    return stat(cloud, &st) && errno == ENOENT && stat(ph, &st) && errno == ENOENT;
}

int save_sync_after_exit(const char *save, const char *title) {   // save: DM_SAVE, its trailing slashes stripped as h_fs_MountSave strips them (the same <save>.sync and <save>-backups)
    char cloud[PATH_MAX], dd[PATH_MAX];
    if (!save || !*save) return 1;
    snprintf(dd, sizeof dd, "%s", save); size_t L = strlen(dd); while (L > 1 && dd[L - 1] == '/') dd[--L] = 0;
    pull_journal j;
    if (journal_read(dd, &j)) { SRED("a pull of the cloud's save did not finish: nothing is sent until the next start puts this device's save back"); return 0; }   // what is in place may be half the cloud's
    if (!cloud_file(title, cloud, sizeof cloud)) return 1;
    // The host may have ended before its sender sent what its mount found to send. When that is the save its base names (another folder picked, the cloud's file
    // removed), it goes only on the mount's own mark (push_mark: this start's mount found no file there) and only where it replaces nothing: a cloud with no file now
    // either. Any other is the next start's to compare
    char seen[SS_HASH + 2]; int marked = push_marked(dd, seen, sizeof seen);
    int stored, ok = send_save(dd, title, cloud, marked && !*seen && no_cloud_file(cloud) ? "" : NULL, &stored, NULL);
    if (ok && marked) push_unmark(dd);
    return ok;
}

// ---------- the platform's parts: these defaults are plain file copies, which the Mac's iCloud Drive takes (it downloads a file a read asks for) ----------
__attribute__((weak)) int front_save_sync_fetch(const char *cloud, const char *local) {
    int in = open(cloud, O_RDONLY); if (in < 0) return errno == ENOENT ? 0 : -1;
    int out = open(local, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (out < 0) { close(in); return -1; }
    int r = copy_fd(in, out); close(in);
    if (close(out)) r = -1;
    if (r) unlink(local);
    return r ? -1 : 1;
}

// Written beside the cloud file under a .nosync name (iCloud Drive does not upload those) and renamed over it: iCloud sees one whole new file
__attribute__((weak)) int front_save_sync_store(const char *local, const char *cloud) {
    char part[PATH_MAX]; snprintf(part, sizeof part, "%s.%d.nosync", cloud, (int)getpid());
    int in = open(local, O_RDONLY); if (in < 0) return 0;
    int out = open(part, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (out < 0) { close(in); return 0; }
    int r = copy_fd(in, out);
    if (!r && fsync(out)) r = -1;
    close(in);
    if (close(out)) r = -1;
    if (!r && rename(part, cloud)) r = -1;
    if (r) unlink(part);
    return !r;
}

__attribute__((weak)) int dm_fs_clone_committed(const char *dir, const char *to) { return clonefile(dir, to, 0) ? -1 : 0; }
