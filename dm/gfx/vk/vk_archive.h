// The Vulkan layer's pipeline archive (hle_vk.m, DM_VK_ARCHIVE, off by default): the parts that are plain C (stdio, POSIX files, pthread), so dm/gfx/tests/t_vk_archive.c runs
// them on any machine; hle_vk.m does the Metal calls, the paths and the logging. The archive is a folder (vk_archive/ beside the save, Documents/ on iOS) of Metal binary archives
// (MTLBinaryArchive: the layer builds classic Metal pipelines on a classic device, mtl_device_classic), each written once and never changed:
//   · p<seq>.bin, a binary archive made from nothing (a new one per write: no archive is ever added to after it was read from a file, nor serialized again), and p<seq>.keys,
//     the keys of the pipelines added to it and its size in bytes (vka_keys_format). A .bin whose .keys does not name its size (a write cut short between the two renames) is
//     not used and is removed with it;
//   · stamp.tsv, what every file was made for (vka_stamp): the system build, the app's own build (its LC_UUID), the GPU, the game's build and the Vulkan shader library (its
//     function list, which holds each function's SHA-256: vka_lib_id). A start whose stamp differs in any of them removes every p<seq> file first, and writes the new stamp only
//     once none is left, so a system or host update, another GPU, another game build or rebuilt shaders never read an old archive (Metal would also miss in it, by its own key;
//     the files would only take room);
//   · guard.tsv, the crash guard's record (../nvn/nvn_pso_guard.h, with its own record file).
// A pipeline's key (vka_fnv over what pipe_make reads from its create info into the Metal descriptor) only says whether this layer has added it: Metal looks the pipeline up in
// the archives by its own key, and a pipeline it does not find there compiles as it does without the archive. 64 bits: two pipelines with the same key (about 1 in 10^12 for
// Super Mario Galaxy's 4,535) would only leave the second out of the archive and count it as found.
// The gate (vka_gate) keeps the archive's writes apart in time from the layer's compiles: while the archive is used, every pipeline holds it as a reader from its creation to
// the end of its compile (whether or not its descriptor names an archive: the start that writes the first file has none to name), and the writer (adds into a new archive, its
// serialization) begins only while no reader does. A pipeline created during a write compiles without the archives and overlaps the write; the gate counts those, for the
// write's log line (Metal's archive internals are shared with the Metal 4 serializer, which crashed when a compile and a write overlapped: docs/reference/shaders.md, A flush per
// compiler period)
#pragma once
#include <errno.h>
#include <fcntl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <unistd.h>

enum { VKA_FILES = 32 };   // archive files at most: a start keeps the first VKA_FILES and writes no more after them

// ---------- Keys ----------
#define VKA_FNV0 0xcbf29ce484222325ull   // FNV-1a, 64 bits
static inline uint64_t vka_fnv(uint64_t h, const void *p, size_t n) { const uint8_t *b = p; for (size_t i = 0; i < n; i++) { h ^= b[i]; h *= 0x100000001b3ull; } return h; }
static inline uint64_t vka_u32(uint64_t h, uint32_t v) { return vka_fnv(h, &v, sizeof v); }   // in the device's byte order: a key is only read on the device that wrote it
static inline uint64_t vka_end(uint64_t h) { return h ? h : 1; }   // 0 is no key (a pipeline the archive does not see)

// A set of keys, sorted, without duplicates
typedef struct { uint64_t *k; size_t n, cap; } vka_set;
static inline size_t vka_lower(const vka_set *s, uint64_t k) {
    size_t lo = 0, hi = s->n;
    while (lo < hi) { size_t m = lo + (hi - lo) / 2; if (s->k[m] < k) lo = m + 1; else hi = m; }
    return lo;
}
static inline int vka_has(const vka_set *s, uint64_t k) { size_t i = vka_lower(s, k); return i < s->n && s->k[i] == k; }
static inline int vka_add(vka_set *s, uint64_t k) {   // 1: added; 0: there already; -1: no memory (the set is unchanged)
    size_t i = vka_lower(s, k);
    if (i < s->n && s->k[i] == k) return 0;
    if (s->n == s->cap) {
        size_t c = s->cap ? 2 * s->cap : 256; uint64_t *nk = realloc(s->k, c * sizeof *nk);
        if (!nk) return -1;
        s->k = nk; s->cap = c;
    }
    memmove(s->k + i + 1, s->k + i, (s->n - i) * sizeof *s->k); s->k[i] = k; s->n++;
    return 1;
}
static inline void vka_set_free(vka_set *s) { free(s->k); s->k = NULL; s->n = s->cap = 0; }

// ---------- What the archive was made for ----------
enum { VKA_OS, VKA_HOST, VKA_GPU, VKA_GAME, VKA_SHADERS, VKA_FIELDS };
static const char *const vka_field[VKA_FIELDS] = {"os", "host", "gpu", "game", "shaders"};
typedef struct { char v[VKA_FIELDS][256]; } vka_stamp;
static inline int vka_stamp_format(char *buf, size_t n, const vka_stamp *s) {
    int k = snprintf(buf, n, "# what the Vulkan layer's pipeline archive in this folder was made for (hle_vk.m, vk_archive.h): a start for anything else removes its files\n");
    for (int i = 0; i < VKA_FIELDS && k >= 0 && (size_t)k < n; i++) k += snprintf(buf + k, n - (size_t)k, "%s\t%s\n", vka_field[i], s->v[i]);
    return k;
}
// The first field in which the stamp in txt differs from want (a field missing counts as different); VKA_FIELDS when it is the same stamp; -1 when txt is NULL (no stamp)
static inline int vka_stamp_diff(const char *txt, const vka_stamp *want) {
    if (!txt) return -1;
    int seen[VKA_FIELDS] = {0};
    for (const char *l = txt; l && *l;) {
        const char *e = strchr(l, '\n'); size_t n = e ? (size_t)(e - l) : strlen(l);
        const char *tab = *l != '#' ? memchr(l, '\t', n) : NULL;
        for (int i = 0; tab && i < VKA_FIELDS; i++) {
            size_t k = (size_t)(tab - l), vn = n - k - 1;
            if (strlen(vka_field[i]) != k || memcmp(l, vka_field[i], k)) continue;
            seen[i] = 1 + (strlen(want->v[i]) == vn && !memcmp(tab + 1, want->v[i], vn));   // 2: the same value
        }
        l = e ? e + 1 : NULL;
    }
    for (int i = 0; i < VKA_FIELDS; i++) if (seen[i] != 2) return i;
    return VKA_FIELDS;
}

// ---------- One archive file's keys (p<seq>.keys) ----------
// "size\t<bytes of p<seq>.bin>", then one key per line in 16 hex digits; # comments. Returns the text (malloc'd, *len its length) or NULL
static inline char *vka_keys_format(uint64_t size, const uint64_t *k, size_t n, size_t *len) {
    size_t cap = 160 + 17 * n; char *b = malloc(cap); if (!b) return NULL;
    int o = snprintf(b, cap, "# the keys of the pipelines in the binary archive of the same name (hle_vk.m, vk_archive.h), and its size\nsize\t%llu\n", (unsigned long long)size);
    if (o < 0) { free(b); return NULL; }
    size_t at = (size_t)o;
    for (size_t i = 0; i < n; i++) at += (size_t)snprintf(b + at, cap - at, "%016llx\n", (unsigned long long)k[i]);
    *len = at; return b;
}
// 1: txt is the keys of a file of this size, added to out (all of them, or none: 0 when one cannot be added); 0: another size, a malformed line or no size line (out unchanged)
static inline int vka_keys_parse(const char *txt, uint64_t size, vka_set *out) {
    if (!txt) return 0;
    int have_size = 0; size_t nk = 0, cap = 0; uint64_t *ks = NULL; int ok = 1;
    for (const char *l = txt; ok && l && *l;) {
        const char *e = strchr(l, '\n'); size_t n = e ? (size_t)(e - l) : strlen(l);
        if (n && *l != '#') {
            char line[64];
            if (n >= sizeof line) ok = 0;
            else {
                memcpy(line, l, n); line[n] = 0; char *end = NULL;
                if (!strncmp(line, "size\t", 5)) {
                    errno = 0; unsigned long long v = strtoull(line + 5, &end, 10);
                    ok = !have_size && !errno && end != line + 5 && !*end && v == size; have_size = 1;
                } else if (n == 16 && have_size) {
                    errno = 0; unsigned long long v = strtoull(line, &end, 16);
                    ok = !errno && end == line + 16 && v != 0;
                    if (ok && nk == cap) { size_t c = cap ? 2 * cap : 256; uint64_t *nks = realloc(ks, c * sizeof *nks); if (!nks) ok = 0; else { ks = nks; cap = c; } }
                    if (ok) ks[nk++] = v;
                } else ok = 0;
            }
        }
        l = e ? e + 1 : NULL;
    }
    ok = ok && have_size;
    for (size_t i = 0; ok && i < nk; i++) if (vka_add(out, ks[i]) < 0) ok = 0;
    free(ks);
    return ok;
}

// ---------- Files ----------
// path written whole or not at all (a temporary file renamed over it). 0, or an errno
static inline int vka_write(const char *path, const void *buf, size_t n) {
    char tmp[1100];
    if (snprintf(tmp, sizeof tmp, "%s.tmp", path) >= (int)sizeof tmp) return ENAMETOOLONG;
    int fd = open(tmp, O_WRONLY | O_CREAT | O_TRUNC, 0644); if (fd < 0) return errno;
    int err = 0; const char *p = buf;
    for (size_t left = n; left && !err;) { ssize_t w = write(fd, p, left); if (w < 0) err = errno == EINTR ? 0 : errno; else if (!w) err = EIO; else { p += w; left -= (size_t)w; } }
    if (close(fd) && !err) err = errno;
    if (!err && rename(tmp, path)) err = errno;
    if (err) unlink(tmp);
    return err;
}
// The whole file (at most max bytes), NUL-terminated (malloc'd), or NULL
static inline char *vka_read(const char *path, size_t max) {
    FILE *f = fopen(path, "r"); if (!f) return NULL;
    char *b = malloc(max + 1); size_t n = b ? fread(b, 1, max, f) : 0;
    int bad = !b || ferror(f), more = !bad && n == max && fgetc(f) != EOF;   // a byte past max only after a full read (a short one has met the end, or an error)
    fclose(f);
    if (bad || more) { free(b); return NULL; }
    b[n] = 0; return b;
}
// A file's identity: its name, size and a digest of its first and last 64 KiB (reading a large archive whole would cost a start its reads). 0, or an errno
static inline int vka_file_id(const char *path, char *out, size_t n) {
    int fd = open(path, O_RDONLY); if (fd < 0) return errno;
    struct stat st = {0}; enum { PART = 65536 }; uint8_t *b = malloc(PART); uint64_t h = VKA_FNV0; int err = 0;
    if (!b) err = ENOMEM; else if (fstat(fd, &st)) err = errno;
    for (int i = 0; !err && i < 2; i++) {
        off_t at = i && st.st_size > PART ? st.st_size - PART : 0;
        ssize_t r = pread(fd, b, PART, at);
        if (r < 0) err = errno; else h = vka_fnv(h, b, (size_t)r);
    }
    free(b); close(fd);
    if (err) return err;
    const char *name = strrchr(path, '/'); name = name ? name + 1 : path;
    return snprintf(out, n, "%s %lld %016llx", name, (long long)st.st_size, (unsigned long long)h) >= (int)n ? ENAMETOOLONG : 0;
}
// A Metal library's identity (vk_shaders.metallib): vka_file_id, then a digest of the library's whole function list, which the MTLB header names (its offset at byte 24, its
// size at byte 32) and which holds each function's name and the SHA-256 of its code, so a rebuild that changes any function changes it, wherever its code lies in the file.
// A file that is not such a library, or whose header names a list beyond the file or over 64 MiB, gets "-" there (its identity is then vka_file_id's). 0, or an errno
static inline int vka_lib_id(const char *path, char *out, size_t n) {
    char head[512]; int err = vka_file_id(path, head, sizeof head);
    if (err) return err;
    int fd = open(path, O_RDONLY); if (fd < 0) return errno;
    enum { PART = 65536 }; uint8_t hdr[40]; uint64_t at = 0, len = 0, h = VKA_FNV0; struct stat st = {0}; int list = 0;
    if (fstat(fd, &st)) err = errno;
    else if (pread(fd, hdr, sizeof hdr, 0) == (ssize_t)sizeof hdr && !memcmp(hdr, "MTLB", 4)) {
        for (int i = 7; i >= 0; i--) { at = at << 8 | hdr[24 + i]; len = len << 8 | hdr[32 + i]; }   // little-endian, as every Apple GPU's library
        list = at >= sizeof hdr && len && len <= 64ull << 20 && at <= (uint64_t)st.st_size && len <= (uint64_t)st.st_size - at;
    }
    uint8_t *b = list ? malloc(PART) : NULL; if (list && !b) err = ENOMEM;
    for (uint64_t done = 0; list && !err && done < len;) {
        size_t want = len - done < PART ? (size_t)(len - done) : PART; ssize_t r = pread(fd, b, want, (off_t)(at + done));
        if (r < 0) err = errno; else if (!r) err = EIO; else { h = vka_fnv(h, b, (size_t)r); done += (uint64_t)r; }
    }
    free(b); close(fd);
    if (err) return err;
    int k = list ? snprintf(out, n, "%s fl %llu %016llx", head, (unsigned long long)len, (unsigned long long)h) : snprintf(out, n, "%s fl -", head);
    return k < 0 || (size_t)k >= n ? ENAMETOOLONG : 0;
}
// The sequence number of one of the archive's files, p<5 digits>.<ext> (ext "bin" or "keys"); -1 for any other name
static inline int vka_seq(const char *name, const char *ext) {
    size_t el = strlen(ext);
    if (strlen(name) != 7 + el || name[0] != 'p' || name[6] != '.' || strcmp(name + 7, ext)) return -1;
    int s = 0; for (int i = 1; i < 6; i++) { if (name[i] < '0' || name[i] > '9') return -1; s = s * 10 + (name[i] - '0'); }
    return s;
}

// ---------- The folder as a start finds it ----------
// The names in dir that are the archive's (p<seq>.bin, p<seq>.keys) or a write cut short (*.tmp), read whole before any is removed: POSIX leaves unspecified which entries
// readdir returns once the folder changes, and a volume that is not APFS (DM_VK_ARCHIVE=<folder> on the Mac: exFAT, a network share) can skip some. 0, or ENOMEM; a folder
// that cannot be opened has none
typedef struct { char **name; int n, cap; } vka_names;
static inline void vka_names_free(vka_names *l) { for (int i = 0; i < l->n; i++) free(l->name[i]); free(l->name); l->name = NULL; l->n = l->cap = 0; }
static inline int vka_is_tmp(const char *nm) { size_t l = strlen(nm); return l > 4 && !strcmp(nm + l - 4, ".tmp"); }
static inline int vka_list(const char *dir, vka_names *l) {
    memset(l, 0, sizeof *l);
    DIR *d = opendir(dir); int err = 0;
    for (struct dirent *e; d && !err && (e = readdir(d));) {
        const char *nm = e->d_name;
        if (vka_seq(nm, "bin") < 0 && vka_seq(nm, "keys") < 0 && !vka_is_tmp(nm)) continue;
        if (l->n == l->cap) { int nc = l->cap ? 2 * l->cap : 64; char **na = realloc(l->name, (size_t)nc * sizeof *na); if (!na) { err = ENOMEM; break; } l->name = na; l->cap = nc; }
        if (!(l->name[l->n] = strdup(nm))) err = ENOMEM; else l->n++;
    }
    if (d) closedir(d);
    if (err) vka_names_free(l);
    return err;
}
// With another stamp in stamp.tsv, or none, every p<seq> file goes and the stamp is written, once a second listing finds none left (diff: vka_stamp_diff's verdict); *.tmp
// files (a write cut short) always go. Then each p<seq>.bin whose p<seq>.keys names its size is kept, oldest first, VKA_FILES at most; the others go with their keys, and so
// does a .keys without its .bin. n, seq: the files kept; next: the number for the next file (past every p<seq> file found); removed: the files removed. 0, or an errno: of a
// stamp that cannot be written, or ENOTEMPTY when an old archive's files cannot all be removed (then the archive is not used: what the folder holds would not be known)
typedef struct { int n, next, removed, diff, seq[VKA_FILES]; } vka_folder;
static inline int vka_cmp_int(const void *a, const void *b) { int x = *(const int *)a, y = *(const int *)b; return (x > y) - (x < y); }
static inline int vka_scan(const char *dir, const vka_stamp *st, vka_folder *o) {
    memset(o, 0, sizeof *o);
    char p[1100], *txt;
    if (snprintf(p, sizeof p, "%s/stamp.tsv", dir) >= (int)sizeof p) return ENAMETOOLONG;
    txt = vka_read(p, 65536); o->diff = vka_stamp_diff(txt, st); free(txt);
    int fresh = o->diff != VKA_FIELDS, *bins = NULL, *keys = NULL, nb = 0, nk = 0, cb = 0, ck = 0;
    vka_names l; int err = vka_list(dir, &l);
    for (int i = 0; !err && i < l.n; i++) {
        const char *nm = l.name[i]; int sb = vka_seq(nm, "bin"), sk = vka_seq(nm, "keys");
        if (sb >= 0 || sk >= 0) { if ((sb > sk ? sb : sk) + 1 > o->next) o->next = (sb > sk ? sb : sk) + 1; }
        if (vka_is_tmp(nm) || (fresh && (sb >= 0 || sk >= 0))) {
            if (snprintf(p, sizeof p, "%s/%s", dir, nm) < (int)sizeof p && !unlink(p)) o->removed++;
            continue;
        }
        int **a = sb >= 0 ? &bins : &keys, *n = sb >= 0 ? &nb : &nk, *c = sb >= 0 ? &cb : &ck;
        if (*n == *c) { int nc = *c ? 2 * *c : 64, *na = realloc(*a, (size_t)nc * sizeof *na); if (!na) { err = ENOMEM; break; } *a = na; *c = nc; }
        (*a)[(*n)++] = sb >= 0 ? sb : sk;
    }
    vka_names_free(&l);
    if (err) { free(bins); free(keys); return err; }
    if (fresh) {
        free(bins); free(keys);
        vka_names left; if ((err = vka_list(dir, &left))) return err;   // the folder again: an entry the first listing did not return, or one that could not be removed
        int old = 0; for (int i = 0; i < left.n; i++) old += vka_seq(left.name[i], "bin") >= 0 || vka_seq(left.name[i], "keys") >= 0;
        vka_names_free(&left);
        if (old) return ENOTEMPTY;   // the stamp is not written: the next start finds the old one, or none, and tries again
        char buf[2048]; int k = vka_stamp_format(buf, sizeof buf, st);
        if (k < 0 || (size_t)k >= sizeof buf) return ENAMETOOLONG;
        if (snprintf(p, sizeof p, "%s/stamp.tsv", dir) >= (int)sizeof p) return ENAMETOOLONG;
        return vka_write(p, buf, (size_t)k);
    }
    if (nb > 1) qsort(bins, (size_t)nb, sizeof *bins, vka_cmp_int);
    for (int i = 0; i < nk; i++) {   // a .keys without its .bin
        int have = 0; for (int j = 0; j < nb && !have; j++) have = bins[j] == keys[i];
        if (!have && snprintf(p, sizeof p, "%s/p%05d.keys", dir, keys[i]) < (int)sizeof p && !unlink(p)) o->removed++;
    }
    for (int i = 0; i < nb; i++) {
        char bp[1100], kp[1100]; struct stat fs; vka_set probe = {0};
        if (snprintf(bp, sizeof bp, "%s/p%05d.bin", dir, bins[i]) >= (int)sizeof bp || snprintf(kp, sizeof kp, "%s/p%05d.keys", dir, bins[i]) >= (int)sizeof kp) continue;
        char *kt = vka_read(kp, 1 << 20);
        int ok = o->n < VKA_FILES && !stat(bp, &fs) && vka_keys_parse(kt, (uint64_t)fs.st_size, &probe);
        free(kt); vka_set_free(&probe);
        if (ok) o->seq[o->n++] = bins[i];
        else { o->removed += !unlink(bp); o->removed += !unlink(kp); }
    }
    free(bins); free(keys);
    return 0;
}

// ---------- Reads and writes apart ----------
// users: the layer's compiles while the archive is used, from vka_read_begin (pipe_make) to vka_read_end (the end of their compile); writing: the writer runs; during: compiles
// begun while it ran (vka_read_begin refused), since vka_write_begin
typedef struct { pthread_mutex_t mu; uint32_t users, during; int writing; } vka_gate;
#define VKA_GATE_INIT {.mu = PTHREAD_MUTEX_INITIALIZER}
static inline int vka_read_begin(vka_gate *g) {   // 0: a write runs, so no archive (counted in during)
    pthread_mutex_lock(&g->mu); int ok = !g->writing; if (ok) g->users++; else g->during++; pthread_mutex_unlock(&g->mu); return ok;
}
static inline void vka_read_end(vka_gate *g) { pthread_mutex_lock(&g->mu); g->users--; pthread_mutex_unlock(&g->mu); }
static inline int vka_write_begin(vka_gate *g) {   // 0: a compile is under way, try later
    pthread_mutex_lock(&g->mu); int ok = !g->users && !g->writing; if (ok) { g->writing = 1; g->during = 0; } pthread_mutex_unlock(&g->mu); return ok;
}
static inline uint32_t vka_write_end(vka_gate *g) {   // the compiles begun during the write, which overlapped it
    pthread_mutex_lock(&g->mu); g->writing = 0; uint32_t n = g->during; pthread_mutex_unlock(&g->mu); return n;
}
