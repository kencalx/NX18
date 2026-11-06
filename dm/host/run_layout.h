// The module layout of each run, for crash reports that name game code only by its address. iOS's crash reports (MetricKit, dm/ios/Sources/DmMetrics.m) give a frame of the game's
// code as a bare address: the game's modules are not images the system knows (their binary UUID is all zeros), and their bases change from one run to the next. So each run on the
// iPhone leaves a block in Documents/run_layouts.txt (loader.c dm_mod_variants_apply, after the launcher and before any guest code runs), keyed by its pid and start time: the build,
// each module's base, size, text end, patch area and key page, the JIT layout's code memory, and the switchable mods' pieces put in place. The newest DM_RUNLOG_KEEP runs are
// kept. The crash summary in log.txt (crash_summary.h) and scripts/crashlog.py read it. Plain C over libc alone, so dm/host/tests/t_crash_summary.c and
// dm/tools/tests/test_crashlog.py run it on any machine.
//
// A block, one line each, fields as key=value separated by single spaces (no value holds a space), the newest block last in the file:
//   run pid=<pid> start=<unix seconds> utc=<the same, ISO 8601> commit=<the app's DMCommit> title=<title ID>[/p<program>] mods=<roles turned on: none, fps, ultrawide, fps+ultrawide>
//   module name=<name> base=<hex> size=<hex> text_end=<hex> patch=<hex, - before the base> patch_len=<hex> key=<hex> [fps=<hex>] [back=<hex> back_len=<hex>] [nro=1] [build=<hex>]
//   [jit base=<hex> size=<hex> image=<hex>]   (the JIT layout, loader.c jit_layout_init: the code memory, whose first image bytes are the served image's code)
//   piece module=<name> off=<hex, - before the base> len=<hex> kind=<code|data> roles=<fps|ultrawide|fps+ultrawide>
//   end
// A module's parts, as gen_embed.py maps them (game_mods.py file_pieces): its text is [0, text_end rounded up to 16 KB), executable; its patch area [patch, patch + patch_len),
// executable, after the image or (patch < 0) before the base; a back patch area [back, back + back_len) inside the image, executable; the rest of [0, size) is the writable part
// (ro, data, bss: read and write, never executable), but for the key page [key, key + 16 KB), read-only, and the frame step state page [fps, fps + 16 KB). A code piece is a whole
// signed page a switchable mod changes (16 KB), a data piece the bytes it writes into the writable part. A reader skips lines it does not know, and a module, jit or piece line
// whose numbers are past any address (DM_RUNLOG_MAXV: the file is in Documents, where the Files app can change it), so every offset it works out fits in 64 bits
#pragma once
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { DM_RUNLOG_KEEP = 8, DM_RUNLOG_PAGE = 0x4000 };
#define DM_RUNLOG_MAXV ((uint64_t)1 << 48)   // past every user address of arm64
#define DM_RUNLOG_HEADER "# Module layouts of this app's newest runs, newest last (dm/host/run_layout.h); the crash summary in log.txt and scripts/crashlog.py read them\n"

typedef struct {
    char name[32], build[40];
    uint64_t base, size, text_end, key, fps, back, back_len, patch_len;
    int64_t patch;
    int nro;
} dm_runlog_mod;
typedef struct { char module[32]; int64_t off; uint64_t len; int code; unsigned roles; } dm_runlog_piece;
typedef struct {
    long long pid, start;   // start: the process's start, wall clock (unix seconds)
    char utc[32], commit[64], title[40];
    unsigned mods;          // the roles turned on (fps 1, ultrawide 2), whether or not a piece of theirs went in
    uint64_t jit_base, jit_size, jit_image;   // the JIT layout's code memory (jit_size 0: none) and how much of it the served image fills
    int nmod, npiece;
    dm_runlog_mod *mod; dm_runlog_piece *piece;   // the writer's own arrays; the reader's are malloc'd (dm_runlog_free)
} dm_runlog_run;

// Role bits as the host has them (game_mods.py ROLE_BIT): their names in the record, and the launcher's names for them
static inline const char *dm_runlog_roles(unsigned r) { r &= 3; return r == 0 ? "none" : r == 1 ? "fps" : r == 2 ? "ultrawide" : "fps+ultrawide"; }
static inline unsigned dm_runlog_roles_of(const char *s) { return (strstr(s, "fps") ? 1u : 0u) | (strstr(s, "ultrawide") ? 2u : 0u); }
static inline const char *dm_runlog_role_label(unsigned r) { r &= 3; return r == 0 ? "none" : r == 1 ? "High frame rate" : r == 2 ? "Ultrawide" : "High frame rate and Ultrawide"; }

// Text appended to a buffer of cap bytes, cut off at its end but always measured, as snprintf: len is what the whole text takes
typedef struct { char *p; size_t cap, len; } dm_rl_buf;
static inline void dm_rl_put(dm_rl_buf *b, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static inline void dm_rl_put(dm_rl_buf *b, const char *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    int k = b->len < b->cap ? vsnprintf(b->p + b->len, b->cap - b->len, fmt, ap) : vsnprintf(NULL, 0, fmt, ap);
    va_end(ap);
    if (k > 0) b->len += (size_t)k;
}
// A signed offset as the record and the summary write it: 0x1a2b, or -0x2000000 before the base
static inline const char *dm_rl_shex(char out[24], int64_t v) {
    uint64_t m = v < 0 ? (uint64_t)0 - (uint64_t)v : (uint64_t)v;
    snprintf(out, 24, "%s0x%llx", v < 0 ? "-" : "", (unsigned long long)m);
    return out;
}
// A value as one field: every space, control character and = becomes _, so the line stays key=value tokens
static inline const char *dm_rl_token(char *out, size_t n, const char *s) {
    size_t k = 0;
    for (; s && *s && k + 1 < n; s++) out[k++] = ((unsigned char)*s <= ' ' || *s == '=') ? '_' : *s;
    if (n) out[k] = 0;
    if (!k && n > 1) { out[0] = '-'; out[1] = 0; }
    return out;
}
static inline void dm_rl_utc(char out[32], long long t) {
    time_t tt = (time_t)t; struct tm tm;
    if (!gmtime_r(&tt, &tm) || !strftime(out, 32, "%Y-%m-%dT%H:%M:%SZ", &tm)) snprintf(out, 32, "-");
}

// One run's block. Returns its length; out gets as much of it as fits in n bytes, NUL-terminated (n = 0 only measures)
static inline size_t dm_runlog_block(char *out, size_t n, const dm_runlog_run *r) {
    dm_rl_buf b = {out, n, 0}; char t1[96], t2[96], t3[48], h1[24], h2[24];
    if (n) out[0] = 0;
    dm_rl_utc(t3, r->start);
    dm_rl_put(&b, "run pid=%lld start=%lld utc=%s commit=%s title=%s mods=%s\n", r->pid, r->start, t3, dm_rl_token(t1, sizeof t1, r->commit), dm_rl_token(t2, sizeof t2, r->title),
              dm_runlog_roles(r->mods));
    for (int i = 0; i < r->nmod; i++) {
        const dm_runlog_mod *m = &r->mod[i];
        dm_rl_put(&b, "module name=%s base=0x%llx size=0x%llx text_end=0x%llx patch=%s patch_len=0x%llx key=0x%llx", dm_rl_token(t1, sizeof t1, m->name), (unsigned long long)m->base,
                  (unsigned long long)m->size, (unsigned long long)m->text_end, dm_rl_shex(h1, m->patch), (unsigned long long)m->patch_len, (unsigned long long)m->key);
        if (m->fps) dm_rl_put(&b, " fps=0x%llx", (unsigned long long)m->fps);
        if (m->back_len) dm_rl_put(&b, " back=0x%llx back_len=0x%llx", (unsigned long long)m->back, (unsigned long long)m->back_len);
        if (m->nro) dm_rl_put(&b, " nro=1");
        if (m->build[0]) dm_rl_put(&b, " build=%s", dm_rl_token(t2, sizeof t2, m->build));
        dm_rl_put(&b, "\n");
    }
    if (r->jit_size) dm_rl_put(&b, "jit base=0x%llx size=0x%llx image=0x%llx\n", (unsigned long long)r->jit_base, (unsigned long long)r->jit_size, (unsigned long long)r->jit_image);
    for (int i = 0; i < r->npiece; i++) {
        const dm_runlog_piece *p = &r->piece[i];
        dm_rl_put(&b, "piece module=%s off=%s len=0x%llx kind=%s roles=%s\n", dm_rl_token(t1, sizeof t1, p->module), dm_rl_shex(h2, p->off), (unsigned long long)p->len,
                  p->code ? "code" : "data", dm_runlog_roles(p->roles));
    }
    dm_rl_put(&b, "end\n");
    return b.len;
}

// The next line of [s, s + n) from *at: its start and length without the newline; 0 at the end
static inline int dm_rl_line(const char *s, size_t n, size_t *at, const char **line, size_t *len) {
    if (*at >= n) return 0;
    const char *p = s + *at, *e = memchr(p, '\n', n - *at);
    *line = p; *len = e ? (size_t)(e - p) : n - *at;
    *at += *len + (e ? 1 : 0);
    return 1;
}
static inline int dm_rl_is(const char *line, size_t len, const char *word) { size_t k = strlen(word); return len >= k && !memcmp(line, word, k) && (len == k || line[k] == ' '); }

// The text of an old record with block added as the newest: the newest keep - 1 complete blocks of old (a block cut off partway, by an older writer that was stopped, is dropped),
// then block. malloc'd and NUL-terminated, its length in *outn; NULL when memory runs out
static inline char *dm_runlog_merge(const char *old, size_t oldn, const char *block, int keep, size_t *outn) {
    size_t *at = NULL, *to = NULL, nb = 0, cap = 0, pos = 0, start = 0; int in = 0;
    const char *line; size_t len;
    while (old && dm_rl_line(old, oldn, &pos, &line, &len)) {
        if (dm_rl_is(line, len, "run")) { in = 1; start = (size_t)(line - old); continue; }
        if (!in || !dm_rl_is(line, len, "end")) continue;
        if (nb == cap) {
            size_t c2 = cap ? cap * 2 : 16; size_t *a2 = realloc(at, c2 * sizeof *at), *t2 = a2 ? realloc(to, c2 * sizeof *to) : NULL;
            if (a2) at = a2;
            if (!a2 || !t2) { free(at); free(to); return NULL; }
            to = t2; cap = c2;
        }
        at[nb] = start; to[nb] = pos; nb++; in = 0;
    }
    size_t first = keep > 1 && nb > (size_t)(keep - 1) ? nb - (size_t)(keep - 1) : keep > 1 ? 0 : nb, total = strlen(DM_RUNLOG_HEADER) + strlen(block);
    for (size_t i = first; i < nb; i++) total += to[i] - at[i] + (old[to[i] - 1] == '\n' ? 0 : 1);
    char *out = malloc(total + 1);
    if (out) {
        size_t k = strlen(DM_RUNLOG_HEADER);
        memcpy(out, DM_RUNLOG_HEADER, k);
        for (size_t i = first; i < nb; i++) { memcpy(out + k, old + at[i], to[i] - at[i]); k += to[i] - at[i]; if (out[k - 1] != '\n') out[k++] = '\n'; }
        memcpy(out + k, block, strlen(block)); k += strlen(block); out[k] = 0;
        if (outn) *outn = k;
    }
    free(at); free(to);
    return out;
}

// The value of key in a record line, copied into out (n bytes); 0 when the line has no such field
static inline int dm_rl_field(const char *line, size_t len, const char *key, char *out, size_t n) {
    size_t kl = strlen(key);
    for (size_t i = 0; i < len;) {
        size_t j = i;
        while (j < len && line[j] != ' ') j++;
        if (j - i > kl && line[i + kl] == '=' && !memcmp(line + i, key, kl)) {
            size_t v = j - i - kl - 1; if (v >= n) v = n ? n - 1 : 0;
            if (n) { memcpy(out, line + i + kl + 1, v); out[v] = 0; }
            return 1;
        }
        i = j + 1;
    }
    if (n) out[0] = 0;
    return 0;
}
static inline long long dm_rl_num(const char *line, size_t len, const char *key) { char v[40]; return dm_rl_field(line, len, key, v, sizeof v) ? strtoll(v, NULL, 0) : 0; }
static inline uint64_t dm_rl_unum(const char *line, size_t len, const char *key) { char v[40]; return dm_rl_field(line, len, key, v, sizeof v) ? strtoull(v, NULL, 0) : 0; }

static inline void dm_runlog_free(dm_runlog_run *r) { free(r->mod); free(r->piece); r->mod = NULL; r->piece = NULL; r->nmod = r->npiece = 0; }
static inline int dm_rl_small(int64_t v) { return v > -(int64_t)DM_RUNLOG_MAXV && v < (int64_t)DM_RUNLOG_MAXV; }
static inline int dm_rl_sane_mod(const dm_runlog_mod *m) {
    return m->base < DM_RUNLOG_MAXV && m->size < DM_RUNLOG_MAXV && m->text_end < DM_RUNLOG_MAXV && m->key < DM_RUNLOG_MAXV && m->fps < DM_RUNLOG_MAXV && m->back < DM_RUNLOG_MAXV
           && m->back_len < DM_RUNLOG_MAXV && m->patch_len < DM_RUNLOG_MAXV && dm_rl_small(m->patch);
}

// The record of the run with this pid in the text of run_layouts.txt, for a crash at a time in [lo, hi] (unix seconds, -1 when not known): of its complete blocks with that pid, the
// newest that started before hi (with a minute's slack for the clocks; hi < 0: the newest of that pid). A pid comes back after a restart of the device, so a block that started after
// the crash is another run. And one instance of the app runs at a time, so a block of another pid that started after that one and a minute or more before lo shows it is of an
// earlier run of the pid: the crashed run left none (it ended before writing one, or the write failed).
// 1 and *out filled (dm_runlog_free it) when one is found; 2 when the newest is of such an earlier run: *out filled with it all the same (for its start; dm_runlog_free it), and
// *later the pid of a run that started between; 0 when none is; -1 when memory runs out. pids, when given, gets the pids of the complete blocks, oldest first (the newest maxp;
// *np their count)
static inline int dm_runlog_find(const char *text, size_t n, long long pid, long long lo, long long hi, dm_runlog_run *out, long long *later, long long *pids, int maxp, int *np) {
    dm_runlog_run cur, best; memset(&cur, 0, sizeof cur); memset(&best, 0, sizeof best);
    int found = 0, in = 0, capm = 0, capp = 0, bad = 0, other = 0; size_t pos = 0; const char *line; size_t len; long long other_start = 0, other_pid = 0;
    if (np) *np = 0;
    while (text && !bad && dm_rl_line(text, n, &pos, &line, &len)) {
        if (dm_rl_is(line, len, "run")) {
            dm_runlog_free(&cur); memset(&cur, 0, sizeof cur); capm = capp = 0; in = 1;
            cur.pid = dm_rl_num(line, len, "pid"); cur.start = dm_rl_num(line, len, "start");
            char v[64];
            dm_rl_field(line, len, "utc", cur.utc, sizeof cur.utc); dm_rl_field(line, len, "commit", cur.commit, sizeof cur.commit); dm_rl_field(line, len, "title", cur.title, sizeof cur.title);
            cur.mods = dm_rl_field(line, len, "mods", v, sizeof v) ? dm_runlog_roles_of(v) : 0;
        } else if (in && dm_rl_is(line, len, "module")) {
            if (cur.nmod == capm) { int c2 = capm ? capm * 2 : 8; dm_runlog_mod *g = realloc(cur.mod, (size_t)c2 * sizeof *g); if (!g) { bad = 1; break; } cur.mod = g; capm = c2; }
            dm_runlog_mod *m = &cur.mod[cur.nmod++]; memset(m, 0, sizeof *m);
            dm_rl_field(line, len, "name", m->name, sizeof m->name); dm_rl_field(line, len, "build", m->build, sizeof m->build);
            m->base = dm_rl_unum(line, len, "base"); m->size = dm_rl_unum(line, len, "size"); m->text_end = dm_rl_unum(line, len, "text_end"); m->key = dm_rl_unum(line, len, "key");
            m->fps = dm_rl_unum(line, len, "fps"); m->back = dm_rl_unum(line, len, "back"); m->back_len = dm_rl_unum(line, len, "back_len"); m->patch_len = dm_rl_unum(line, len, "patch_len");
            m->patch = dm_rl_num(line, len, "patch"); m->nro = (int)dm_rl_num(line, len, "nro");
            if (!dm_rl_sane_mod(m)) cur.nmod--;
        } else if (in && dm_rl_is(line, len, "jit")) {
            uint64_t jb = dm_rl_unum(line, len, "base"), js = dm_rl_unum(line, len, "size"), ji = dm_rl_unum(line, len, "image");
            if (jb < DM_RUNLOG_MAXV && js < DM_RUNLOG_MAXV && ji < DM_RUNLOG_MAXV) { cur.jit_base = jb; cur.jit_size = js; cur.jit_image = ji; }
        } else if (in && dm_rl_is(line, len, "piece")) {
            if (cur.npiece == capp) { int c2 = capp ? capp * 2 : 8; dm_runlog_piece *g = realloc(cur.piece, (size_t)c2 * sizeof *g); if (!g) { bad = 1; break; } cur.piece = g; capp = c2; }
            dm_runlog_piece *p = &cur.piece[cur.npiece++]; memset(p, 0, sizeof *p); char v[32];
            dm_rl_field(line, len, "module", p->module, sizeof p->module);
            p->off = dm_rl_num(line, len, "off"); p->len = dm_rl_unum(line, len, "len");
            p->code = dm_rl_field(line, len, "kind", v, sizeof v) && !strcmp(v, "code");
            p->roles = dm_rl_field(line, len, "roles", v, sizeof v) ? dm_runlog_roles_of(v) : 0;
            if (!dm_rl_small(p->off) || p->len >= DM_RUNLOG_MAXV) cur.npiece--;
        } else if (in && dm_rl_is(line, len, "end")) {
            in = 0;
            if (np && pids && maxp > 0) {   // the newest maxp
                if (*np == maxp) { memmove(pids, pids + 1, (size_t)(maxp - 1) * sizeof *pids); (*np)--; }
                pids[(*np)++] = cur.pid;
            }
            if (cur.pid != pid) {   // the latest start of another pid's run that began a minute or more before the crash
                if (lo >= 0 && cur.start <= lo - 60 && (!other || cur.start > other_start)) { other = 1; other_start = cur.start; other_pid = cur.pid; }
                continue;
            }
            if ((hi >= 0 && cur.start > hi + 60) || (found && cur.start < best.start)) continue;
            dm_runlog_free(&best); best = cur; memset(&cur, 0, sizeof cur); capm = capp = 0; found = 1;
        }
    }
    dm_runlog_free(&cur);
    if (bad) { dm_runlog_free(&best); return -1; }
    if (found) { *out = best; if (other && other_start > best.start) { if (later) *later = other_pid; return 2; } }
    return found;
}
