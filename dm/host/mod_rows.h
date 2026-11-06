// The rows of a module's switchable mods, <module>.variants beside the rewritten modules (dm/tools/game_mods.py write_variants), as the Mac host reads them (loader.c
// mod_variants_one): one row per byte run, tab-separated: the role (fps, ultrawide), the kind (c: code, w: data), the file offset, the image offset (-0x… before the base) and the
// bytes in hex; a line that starts with # is a comment. Every row of the file is read before any is put in place, so a role goes in whole or not at all, as on the iPhone, whose
// pages of it are signed into the app (gen_embed.py): a row that cannot be read takes its role out (both roles when its role cannot be told). A row of any length is parsed in
// place, in its own getline buffer, its hex decoded over itself. Plain C over libc, so dm/host/tests/t_mod_rows.c runs it on any machine.
#pragma once
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>

enum { DM_MOD_ROLE_FPS = 1, DM_MOD_ROLE_ULTRAWIDE = 2, DM_MOD_ROLES = 3 };   // the host's role bits (DM_MOD_FPS, DM_MOD_ULTRAWIDE)
typedef struct { char *buf; const uint8_t *bytes; size_t len; long long io; unsigned role; int code; } dm_mod_row;   // bytes: len of them, decoded inside buf
typedef struct {
    dm_mod_row *row; size_t n, cap;
    unsigned bad;        // the roles with a row that cannot be read (both for a row whose role cannot be told, a read error, or no memory)
    long bad_line[2];    // the first such line of each role (1-based; 0: none)
} dm_mod_rows;

static inline int dm_mod_hex(char c) { return c >= '0' && c <= '9' ? c - '0' : c >= 'a' && c <= 'f' ? c - 'a' + 10 : c >= 'A' && c <= 'F' ? c - 'A' + 10 : -1; }

// A number as write_variants prints it, [-]0x<hex digits> (with need_0x 0 the 0x may be left out: the file offset, which %llx read before); 0 when s is not one, or has more
// than 15 digits
static inline int dm_mod_num(const char *s, int need_0x, long long *out) {
    int neg = *s == '-';
    if (neg) s++;
    if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X')) s += 2;
    else if (need_0x) return 0;
    unsigned long long v = 0; int n = 0;
    for (; *s; s++, n++) {
        int d = dm_mod_hex(*s);
        if (d < 0 || n == 15) return 0;
        v = v << 4 | (unsigned)d;
    }
    if (!n) return 0;
    *out = neg ? -(long long)v : (long long)v;
    return 1;
}

// One line (its newline cut here): 1 a row, filled into r, its bytes decoded over the hex in line; 0 a comment or an empty line; -1 a row it cannot read, with r->role set
// when its role can be told
static inline int dm_mod_row_parse(char *line, dm_mod_row *r) {
    memset(r, 0, sizeof *r);
    line[strcspn(line, "\r\n")] = 0;
    if (!line[0] || line[0] == '#') return 0;
    size_t k = strcspn(line, "\t");
    r->role = k == 3 && !memcmp(line, "fps", 3) ? DM_MOD_ROLE_FPS : k == 9 && !memcmp(line, "ultrawide", 9) ? DM_MOD_ROLE_ULTRAWIDE : 0;
    if (!r->role) return -1;
    char *f[5] = {line}; int n = 1;
    for (char *p = line; *p; p++) {
        if (*p != '\t') continue;
        if (n == 5) return -1;
        *p = 0; f[n++] = p + 1;
    }
    long long fo;
    if (n != 5 || (strcmp(f[1], "c") && strcmp(f[1], "w")) || !dm_mod_num(f[2], 0, &fo) || fo < 0 || !dm_mod_num(f[3], 1, &r->io)) return -1;
    size_t hl = strlen(f[4]);
    if (!hl || hl % 2) return -1;
    uint8_t *out = (uint8_t *)f[4];
    for (size_t i = 0; i < hl; i += 2) {   // byte i / 2 is written after both its digits are read, never over a digit still to read
        int hi = dm_mod_hex(f[4][i]), lo = dm_mod_hex(f[4][i + 1]);
        if (hi < 0 || lo < 0) return -1;
        out[i / 2] = (uint8_t)(hi << 4 | lo);
    }
    r->bytes = out; r->len = hl / 2; r->code = f[1][0] == 'c';
    return 1;
}

static inline void dm_mod_rows_bad(dm_mod_rows *rows, unsigned roles, long line) {
    rows->bad |= roles;
    for (int i = 0; i < 2; i++)
        if (roles >> i & 1 && !rows->bad_line[i]) rows->bad_line[i] = line;
}

// Every row of f into rows (zeroed first); only those of the roles in want are kept, but every row is checked. Free with dm_mod_rows_free
static inline void dm_mod_rows_read(FILE *f, unsigned want, dm_mod_rows *rows) {
    memset(rows, 0, sizeof *rows);
    long ln = 0;
    for (;;) {
        char *line = NULL; size_t cap = 0;
        ssize_t k = getline(&line, &cap, f);
        ln++;
        if (k < 0 || !line) { free(line); break; }   // !line: getline sets it on success; said again for an analyzer that does not model it
        dm_mod_row r;
        int got = dm_mod_row_parse(line, &r);
        if (got < 0) dm_mod_rows_bad(rows, r.role ? r.role : (unsigned)DM_MOD_ROLES, ln);
        if (got <= 0 || !(want & r.role)) { free(line); continue; }
        if (rows->n == rows->cap) {
            size_t nc = rows->cap ? 2 * rows->cap : 16;
            dm_mod_row *g = realloc(rows->row, nc * sizeof *g);
            if (!g) { free(line); dm_mod_rows_bad(rows, DM_MOD_ROLES, ln); return; }
            rows->row = g; rows->cap = nc;
        }
        r.buf = line; rows->row[rows->n++] = r;
    }
    if (ferror(f)) dm_mod_rows_bad(rows, DM_MOD_ROLES, ln);   // a read that failed part way: what is missing cannot be told
}

static inline void dm_mod_rows_free(dm_mod_rows *rows) {
    for (size_t i = 0; i < rows->n; i++) free(rows->row[i].buf);
    free(rows->row);
    memset(rows, 0, sizeof *rows);
}
