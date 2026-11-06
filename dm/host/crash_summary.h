// The crash summary in log.txt: what a MetricKit crash report (Documents/metrics/<…>-diagnostic-crash.json, DmMetrics.m) says, in lines a player can send and a reader can act on.
// The exception and signal by name, the termination reason, the first lines of the memory region info, the crashed run's pid, build and time; then the crashed thread's newest frames,
// each as image+offset for the system's images and, for the game's own code (binary UUID all zeros: the modules are not images iOS knows), as module+offset and the part it is in
// (text, patch area, writable part, key page, a switchable mod's page), from the layout record of the run with the same pid (run_layout.h); then the switchable mods that run had in
// place and which toggle to try off first. Both shapes of the report: MetricManager's (iOS 27, Metrics.swift: crashDiagnostic, environment, timeRange; callStackThreads, rootFrames,
// binaryInfo) and MXMetricManager's (DM_METRICS=mx: crashDiagnostics[], diagnosticMetaData, timeStampEnd; callStacks, callStackRootFrames, binaryName in each frame).
// Plain C over libc, with a small JSON reader of its own, so the whole summary runs on any machine: dm/host/tests/t_crash_summary.c, and dm/tools/tests/test_crashlog.py, which
// checks that scripts/crashlog.py prints the same lines. DmMetrics.m runs it on its metrics queue, never on a game thread
#pragma once
#include "run_layout.h"

// ---------- JSON, as far as the reports need: a tree of nodes over the text, strings left escaped until read ----------
enum { CJ_NONE, CJ_NULL, CJ_FALSE, CJ_TRUE, CJ_INT, CJ_REAL, CJ_STR, CJ_ARR, CJ_OBJ };
// first, next: the first child and the next sibling (node indices, 0 = none); key, klen: an object member's key in the text; str, slen: a string's text between its quotes;
// u: a number's magnitude (a real's integral part), neg its sign, bad when it is not exact (an exponent, or more than 64 bits)
typedef struct { uint8_t type, neg, bad; uint32_t first, next, key, klen, str, slen; uint64_t u; } cj_node;
typedef struct { const char *s; size_t n; cj_node *v; uint32_t nv, cap, root; int lim; } cj_doc;   // lim: the text failed on a limit of the reader (size, nodes, nesting, memory)
enum { CJ_MAX_NODES = 1 << 24, CJ_MAX_DEPTH = 1 << 16 };
#define CJ_MAX_TEXT ((size_t)1 << 30)

static inline void cj_free(cj_doc *d) { free(d->v); d->v = NULL; d->nv = d->cap = d->root = 0; }
static inline uint32_t cj_new(cj_doc *d, uint8_t type) {
    if (d->nv == d->cap) {
        if (d->cap >= CJ_MAX_NODES) { d->lim = 1; return 0; }
        uint32_t c2 = d->cap * 2; cj_node *g = realloc(d->v, (size_t)c2 * sizeof *g);
        if (!g) { d->lim = 1; return 0; }
        d->v = g; d->cap = c2;
    }
    memset(&d->v[d->nv], 0, sizeof d->v[0]); d->v[d->nv].type = type;
    return d->nv++;
}
static inline size_t cj_ws(const char *s, size_t n, size_t i) { while (i < n && (s[i] == ' ' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r')) i++; return i; }
// A string from its opening quote at *i; *i ends past the closing one
static inline int cj_scan_str(const char *s, size_t n, size_t *i) {
    for (size_t j = *i + 1; j < n;) {
        unsigned char c = (unsigned char)s[j];
        if (c == '"') { *i = j + 1; return 1; }
        if (c == '\\') { j += 2; continue; }
        if (c < 0x20) return 0;
        j++;
    }
    return 0;
}
static inline int cj_scan_num(const char *s, size_t n, size_t *i, cj_node *x) {
    size_t j = *i; int dig = 0, real = 0; uint64_t u = 0;
    if (j < n && s[j] == '-') { x->neg = 1; j++; }
    for (; j < n && s[j] >= '0' && s[j] <= '9'; j++, dig++) {
        unsigned g = (unsigned)(s[j] - '0');
        if (u > (UINT64_MAX - g) / 10) x->bad = 1; else u = u * 10 + g;
    }
    if (!dig) return 0;
    if (j < n && s[j] == '.') { int f = 0; for (j++; j < n && s[j] >= '0' && s[j] <= '9'; j++) f++; if (!f) return 0; real = 1; }
    if (j < n && (s[j] == 'e' || s[j] == 'E')) {
        int e = 0; j++;
        if (j < n && (s[j] == '+' || s[j] == '-')) j++;
        for (; j < n && s[j] >= '0' && s[j] <= '9'; j++) e++;
        if (!e) return 0;
        real = 1; x->bad = 1;
    }
    x->type = real ? CJ_REAL : CJ_INT; x->u = u; *i = j;
    return 1;
}
static inline int cj_key(const char *s, size_t n, size_t *i, uint32_t *key, uint32_t *klen) {
    size_t a = cj_ws(s, n, *i), b = a;
    if (a >= n || s[a] != '"' || !cj_scan_str(s, n, &b)) return 0;
    *key = (uint32_t)(a + 1); *klen = (uint32_t)(b - a - 2);
    b = cj_ws(s, n, b);
    if (b >= n || s[b] != ':') return 0;
    *i = b + 1;
    return 1;
}
// Parses the whole text (one value, then only white space); 1 when it is JSON, else 0 and nothing kept (d->lim set when it failed on one of the reader's limits, not on the text)
static inline int cj_parse(cj_doc *d, const char *s, size_t n) {
    memset(d, 0, sizeof *d); d->s = s; d->n = n;
    if (!s) return 0;
    if (n >= CJ_MAX_TEXT || !(d->v = malloc(1024 * sizeof *d->v))) { d->lim = 1; return 0; }
    d->cap = 1024; d->nv = 1; memset(&d->v[0], 0, sizeof d->v[0]);   // node 0: none
    typedef struct { uint32_t node, last; } cj_open;
    cj_open *st = NULL; size_t sp = 0, scap = 0, i = 0; uint32_t key = 0, klen = 0; int ok = 0;
    for (;;) {
        i = cj_ws(s, n, i);
        if (i >= n) goto done;
        char c = s[i]; uint8_t t;
        if (c == '{') t = CJ_OBJ; else if (c == '[') t = CJ_ARR; else if (c == '"') t = CJ_STR;
        else if (c == 't') t = CJ_TRUE; else if (c == 'f') t = CJ_FALSE; else if (c == 'n') t = CJ_NULL;
        else if (c == '-' || (c >= '0' && c <= '9')) t = CJ_INT;
        else goto done;
        uint32_t x = cj_new(d, t);
        if (!x) goto done;
        if (t == CJ_STR) { size_t a = i; if (!cj_scan_str(s, n, &i)) goto done; d->v[x].str = (uint32_t)(a + 1); d->v[x].slen = (uint32_t)(i - a - 2); }
        else if (t == CJ_TRUE || t == CJ_FALSE || t == CJ_NULL) {
            const char *w = t == CJ_TRUE ? "true" : t == CJ_FALSE ? "false" : "null"; size_t wl = strlen(w);
            if (n - i < wl || memcmp(s + i, w, wl) != 0) goto done;
            i += wl;
        } else if (t == CJ_INT) { if (!cj_scan_num(s, n, &i, &d->v[x])) goto done; }
        else i++;
        if (sp) {
            cj_open *p = &st[sp - 1];
            if (p->last) d->v[p->last].next = x; else d->v[p->node].first = x;
            p->last = x;
            if (d->v[p->node].type == CJ_OBJ) { d->v[x].key = key; d->v[x].klen = klen; }
        } else if (d->root) goto done;
        else d->root = x;
        if (t == CJ_OBJ || t == CJ_ARR) {
            if (sp == scap) {
                size_t c2 = scap ? scap * 2 : 64; cj_open *g = c2 <= CJ_MAX_DEPTH ? realloc(st, c2 * sizeof *g) : NULL;
                if (!g) { d->lim = 1; goto done; }
                st = g; scap = c2;
            }
            st[sp].node = x; st[sp].last = 0; sp++;
            i = cj_ws(s, n, i);
            if (i < n && s[i] == (t == CJ_OBJ ? '}' : ']')) { i++; sp--; goto after; }
            if (t == CJ_OBJ && !cj_key(s, n, &i, &key, &klen)) goto done;
            continue;   // its first value
        }
    after:
        for (;;) {   // after a value: the next one of its container, the container's end, or the text's
            i = cj_ws(s, n, i);
            if (!sp) { ok = i == n; goto done; }
            if (i >= n) goto done;
            uint8_t pt = d->v[st[sp - 1].node].type;
            if (s[i] == ',') { i++; if (pt == CJ_OBJ && !cj_key(s, n, &i, &key, &klen)) goto done; break; }
            if (s[i] != (pt == CJ_OBJ ? '}' : ']')) goto done;
            i++; sp--;
        }
    }
done:
    free(st);
    if (!ok) cj_free(d);
    return ok;
}
static inline uint32_t cj_get(const cj_doc *d, uint32_t obj, const char *key) {
    if (!obj || d->v[obj].type != CJ_OBJ) return 0;
    size_t kl = strlen(key);
    for (uint32_t c = d->v[obj].first; c; c = d->v[c].next)
        if (d->v[c].klen == kl && !memcmp(d->s + d->v[c].key, key, kl)) return c;
    return 0;
}
static inline uint32_t cj_kids(const cj_doc *d, uint32_t x, uint8_t type) { return x && d->v[x].type == type ? d->v[x].first : 0; }
static inline int cj_is(const cj_doc *d, uint32_t x, uint8_t type) { return x && d->v[x].type == type; }
static inline int cj_u64(const cj_doc *d, uint32_t x, uint64_t *out) {
    if (!x || (d->v[x].type != CJ_INT && d->v[x].type != CJ_REAL) || d->v[x].bad || (d->v[x].neg && d->v[x].u)) return 0;
    *out = d->v[x].u; return 1;
}
static inline int cj_i64(const cj_doc *d, uint32_t x, long long *out) {
    if (!x || (d->v[x].type != CJ_INT && d->v[x].type != CJ_REAL) || d->v[x].bad || d->v[x].u > (uint64_t)INT64_MAX) return 0;
    *out = d->v[x].neg ? -(long long)d->v[x].u : (long long)d->v[x].u; return 1;
}
static inline int cj_hex4(const char *s, unsigned *v) {
    *v = 0;
    for (int k = 0; k < 4; k++) {
        char c = s[k]; unsigned g = c >= '0' && c <= '9' ? (unsigned)(c - '0') : c >= 'a' && c <= 'f' ? (unsigned)(c - 'a' + 10) : c >= 'A' && c <= 'F' ? (unsigned)(c - 'A' + 10) : 16u;
        if (g > 15) return 0;
        *v = *v << 4 | g;
    }
    return 1;
}
// A string's text, unescaped, into out (n bytes, NUL-terminated, cut at a character's start when it does not fit); its length, 0 for a node that is no string
static inline size_t cj_text(const cj_doc *d, uint32_t x, char *out, size_t n) {
    if (!n) return 0;
    out[0] = 0;
    if (!cj_is(d, x, CJ_STR)) return 0;
    const char *s = d->s + d->v[x].str; size_t L = d->v[x].slen, k = 0; int cut = 0;
    for (size_t i = 0; i < L && !cut;) {
        char enc[4]; size_t el = 1; char c = s[i++];
        enc[0] = c;
        if (c == '\\' && i < L) {
            char e = s[i++]; unsigned cp = 0;
            enc[0] = e == 'n' ? '\n' : e == 't' ? '\t' : e == 'r' ? '\r' : e == 'b' ? '\b' : e == 'f' ? '\f' : e;
            if (e == 'u') {
                if (L - i < 4 || !cj_hex4(s + i, &cp)) cp = 0xFFFD; else i += 4;
                if (cp >= 0xD800 && cp < 0xDC00) {   // a surrogate pair
                    unsigned lo = 0;
                    if (L - i >= 6 && s[i] == '\\' && s[i + 1] == 'u' && cj_hex4(s + i + 2, &lo) && lo >= 0xDC00 && lo < 0xE000) { cp = 0x10000 + ((cp - 0xD800) << 10) + (lo - 0xDC00); i += 6; }
                    else cp = 0xFFFD;
                } else if (cp >= 0xDC00 && cp < 0xE000) cp = 0xFFFD;
                if (cp < 0x80) enc[0] = (char)cp;
                else if (cp < 0x800) { enc[0] = (char)(0xC0 | cp >> 6); enc[1] = (char)(0x80 | (cp & 0x3F)); el = 2; }
                else if (cp < 0x10000) { enc[0] = (char)(0xE0 | cp >> 12); enc[1] = (char)(0x80 | (cp >> 6 & 0x3F)); enc[2] = (char)(0x80 | (cp & 0x3F)); el = 3; }
                else { enc[0] = (char)(0xF0 | cp >> 18); enc[1] = (char)(0x80 | (cp >> 12 & 0x3F)); enc[2] = (char)(0x80 | (cp >> 6 & 0x3F)); enc[3] = (char)(0x80 | (cp & 0x3F)); el = 4; }
            }
        }
        if (k + el >= n) { cut = 1; break; }
        memcpy(out + k, enc, el); k += el;
    }
    if (cut && k) {   // a character the end cut partway (a raw one is copied byte by byte) goes whole
        size_t j = k;
        while (j && ((unsigned char)out[j - 1] & 0xC0) == 0x80) j--;
        unsigned char c0 = j ? (unsigned char)out[j - 1] : 0; size_t need = c0 >= 0xF0 ? 4 : c0 >= 0xE0 ? 3 : c0 >= 0xC0 ? 2 : 1;
        if (j && k - (j - 1) < need) k = j - 1;
    }
    out[k] = 0;
    return k;
}

// ---------- names ----------
static inline const char *dm_cs_exc_name(long long t) {   // <mach/exception_types.h>
    static const char *const n[] = {NULL, "EXC_BAD_ACCESS", "EXC_BAD_INSTRUCTION", "EXC_ARITHMETIC", "EXC_EMULATION", "EXC_SOFTWARE", "EXC_BREAKPOINT", "EXC_SYSCALL",
                                    "EXC_MACH_SYSCALL", "EXC_RPC_ALERT", "EXC_CRASH", "EXC_RESOURCE", "EXC_GUARD", "EXC_CORPSE_NOTIFY"};
    return t > 0 && t < (long long)(sizeof n / sizeof *n) ? n[t] : NULL;
}
static inline const char *dm_cs_code_name(long long type, long long code) {   // the first exception code: a kern_return_t for EXC_BAD_ACCESS, the arm64 codes of the others
    if (type == 1) switch (code) {
        case 1: return "KERN_INVALID_ADDRESS"; case 2: return "KERN_PROTECTION_FAILURE"; case 3: return "KERN_NO_SPACE"; case 4: return "KERN_INVALID_ARGUMENT";
        case 5: return "KERN_FAILURE"; case 8: return "KERN_NO_ACCESS"; case 9: return "KERN_MEMORY_FAILURE"; case 10: return "KERN_MEMORY_ERROR";
        case 50: return "KERN_CODESIGN_ERROR"; case 0x101: return "EXC_ARM_DA_ALIGN"; case 0x102: return "EXC_ARM_DA_DEBUG"; case 0x103: return "EXC_ARM_SP_ALIGN";
        case 0x104: return "EXC_ARM_SWP"; case 0x105: return "EXC_ARM_PAC_FAIL"; default: return NULL;   // <mach/arm/exception.h>
    }
    if (type == 2 && code == 1) return "EXC_ARM_UNDEFINED";
    if (type == 3 && code >= 0 && code <= 6) { static const char *const f[] = {"EXC_ARM_FP_UNDEFINED", "EXC_ARM_FP_IO", "EXC_ARM_FP_DZ", "EXC_ARM_FP_OF", "EXC_ARM_FP_UF", "EXC_ARM_FP_IX", "EXC_ARM_FP_ID"}; return f[code]; }
    if (type == 6 && code == 1) return "EXC_ARM_BREAKPOINT";
    return NULL;
}
static inline const char *dm_cs_signal_name(long long s) {   // Darwin's numbers, which differ from Linux's
    static const char *const n[] = {NULL, "SIGHUP", "SIGINT", "SIGQUIT", "SIGILL", "SIGTRAP", "SIGABRT", "SIGEMT", "SIGFPE", "SIGKILL", "SIGBUS", "SIGSEGV", "SIGSYS", "SIGPIPE", "SIGALRM",
                                    "SIGTERM", "SIGURG", "SIGSTOP", "SIGTSTP", "SIGCONT", "SIGCHLD", "SIGTTIN", "SIGTTOU", "SIGIO", "SIGXCPU", "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGWINCH",
                                    "SIGINFO", "SIGUSR1", "SIGUSR2"};
    return s > 0 && s < (long long)(sizeof n / sizeof *n) ? n[s] : NULL;
}
// What a termination reason ("Namespace CODESIGNING, Code 0x2") means, for the ones a game here can meet; NULL for the rest
static inline const char *dm_cs_term_hint(const char *t) {
    const char *c = strstr(t, "Code "); unsigned long long code = c ? strtoull(c + 5, NULL, 0) : 0;
    if (strstr(t, "CODESIGNING")) return code == 2 ? "code signing: an invalid page, the run executed a page that is not signed code, such as a writable one" : "code signing";
    if (strstr(t, "JETSAM")) return "the system ended the app for memory";
    if (code == 0x8badf00dull) return "the system's watchdog: the app did not answer in time";
    if (code == 0xdead10ccull) return "the app held a file lock or a database while in the background";
    return NULL;
}

// ---------- time: ISO 8601 (MetricManager's dates, 2026-11-06T02:15:36Z) or MXMetricManager's (2020-07-07 10:25:00 +0000) to unix seconds, -1 for neither ----------
static inline long long dm_cs_days(long long y, unsigned m, unsigned d) {   // days since 1970-01-01 of a date of the proleptic Gregorian calendar
    y -= m <= 2;
    long long era = (y >= 0 ? y : y - 399) / 400; unsigned yoe = (unsigned)(y - era * 400), doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1, doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    return era * 146097 + (long long)doe - 719468;
}
static inline int dm_cs_digits(const char *s, int k, int *v) { *v = 0; for (int i = 0; i < k; i++) { if (s[i] < '0' || s[i] > '9') return 0; *v = *v * 10 + (s[i] - '0'); } return 1; }
static inline long long dm_cs_time(const char *s) {
    int Y, M, D, h, mi, se;
    if (strlen(s) < 19 || !dm_cs_digits(s, 4, &Y) || s[4] != '-' || !dm_cs_digits(s + 5, 2, &M) || s[7] != '-' || !dm_cs_digits(s + 8, 2, &D) || (s[10] != 'T' && s[10] != ' ')
        || !dm_cs_digits(s + 11, 2, &h) || s[13] != ':' || !dm_cs_digits(s + 14, 2, &mi) || s[16] != ':' || !dm_cs_digits(s + 17, 2, &se) || M < 1 || M > 12 || D < 1 || D > 31)
        return -1;
    const char *p = s + 19; long off = 0; int hh, mm;
    if (*p == '.') for (p++; *p >= '0' && *p <= '9'; p++) {}
    while (*p == ' ') p++;
    if ((*p == '+' || *p == '-') && dm_cs_digits(p + 1, 2, &hh)) {
        const char *q = p + 3 + (p[3] == ':');
        off = (hh * 3600L + (dm_cs_digits(q, 2, &mm) ? mm * 60L : 0)) * (*p == '-' ? -1 : 1);
    }
    return dm_cs_days(Y, (unsigned)M, (unsigned)D) * 86400 + h * 3600L + mi * 60L + se - off;
}

// ---------- the memory region info's table rows ("--->  mapped file  111234000-111cbc000 [ 10.5M] rw-/rw- SM=COW ...") ----------
typedef struct { uint64_t lo, hi; char prot[4], type[40]; int fault; } dm_cs_region;
static inline int dm_cs_hexrange(const char *t, size_t L, uint64_t *lo, uint64_t *hi) {
    const char *dash = memchr(t, '-', L);
    if (!dash || dash == t || dash == t + L - 1) return 0;
    for (const char *c = t; c < t + L; c++)
        if (c != dash && !((*c >= '0' && *c <= '9') || (*c >= 'a' && *c <= 'f') || (*c >= 'A' && *c <= 'F'))) return 0;
    *lo = strtoull(t, NULL, 16); *hi = strtoull(dash + 1, NULL, 16);
    return 1;
}
static inline int dm_cs_prot(const char *t, size_t L) {
    return L == 7 && (t[0] == 'r' || t[0] == '-') && (t[1] == 'w' || t[1] == '-') && (t[2] == 'x' || t[2] == '-') && t[3] == '/' && (t[4] == 'r' || t[4] == '-') && (t[5] == 'w' || t[5] == '-')
           && (t[6] == 'x' || t[6] == '-');
}
static inline int dm_cs_regions(const char *info, dm_cs_region *r, int max) {
    int n = 0;
    for (const char *l = info; l && *l && n < max;) {
        const char *e = strchr(l, '\n'); size_t L = e ? (size_t)(e - l) : strlen(l);
        const char *tok[24]; size_t tl[24]; int nt = 0;
        for (size_t i = 0; i < L && nt < 24;) {
            while (i < L && (l[i] == ' ' || l[i] == '\t')) i++;
            if (i >= L) break;
            size_t j = i; while (j < L && l[j] != ' ' && l[j] != '\t') j++;
            tok[nt] = l + i; tl[nt] = j - i; nt++; i = j;
        }
        int f = nt && tl[0] == 4 && !memcmp(tok[0], "--->", 4), ri = -1; dm_cs_region g; memset(&g, 0, sizeof g);
        for (int k = f; k < nt && ri < 0; k++) if (dm_cs_hexrange(tok[k], tl[k], &g.lo, &g.hi)) ri = k;
        for (int k = ri + 1; ri >= 0 && k < nt; k++) if (dm_cs_prot(tok[k], tl[k])) { memcpy(g.prot, tok[k], 3); break; }
        if (ri > f && g.prot[0]) {
            dm_rl_buf b = {g.type, sizeof g.type, 0};
            for (int k = f; k < ri; k++) dm_rl_put(&b, "%s%.*s", k > f ? " " : "", (int)tl[k], tok[k]);
            g.fault = f; r[n++] = g;
        }
        l = e ? e + 1 : NULL;
    }
    return n;
}

// ---------- where an address of the game's code is, by the run's layout ----------
static inline uint64_t dm_cs_page_up(uint64_t v) { return (v + DM_RUNLOG_PAGE - 1) & ~(uint64_t)(DM_RUNLOG_PAGE - 1); }
// "main+0x14b8fa0, main's writable part (not executable), 0x7060 below its patch area" into out; 0 when a is in no module of the run nor in its JIT code memory. *known: whether the
// part is known (the record gives the text end); *hit: the roles of the switchable-mod piece holding it, 0 for none. The offsets are worked out in 64 bits without overflow for any
// record (dm_runlog_find also leaves out a line whose numbers are past any address)
static inline int dm_cs_where(const dm_runlog_run *r, uint64_t a, char *out, size_t n, int *known, unsigned *hit) {
    *known = 0; *hit = 0;
    if (n) out[0] = 0;
    for (int i = 0; r && i < r->nmod; i++) {
        const dm_runlog_mod *m = &r->mod[i]; int64_t off;
        if (a >= m->base && a - m->base < m->size && a - m->base <= (uint64_t)INT64_MAX) off = (int64_t)(a - m->base);
        else if (a < m->base && m->patch < 0 && m->base - a <= (uint64_t)0 - (uint64_t)m->patch) off = (int64_t)((uint64_t)0 - (m->base - a));   // -(base - a), at most -patch
        else continue;
        const char *part; int writable = 0; *known = 1;
        // Before the base: off >= patch here. The gap between the patch area and the base stays the reservation's anonymous memory on the iPhone (read and write); the Mac makes it
        // inaccessible
        if (m->patch < 0 && off < 0) part = (uint64_t)off - (uint64_t)m->patch < m->patch_len ? "patch area" : "gap before its base (not code: read-write on the iPhone, inaccessible on the Mac)";
        else if (m->patch >= 0 && off >= m->patch) part = "patch area";
        else if (m->back_len && (uint64_t)off >= m->back && (uint64_t)off < m->back + m->back_len) part = "back patch area";
        else if (!m->text_end) { part = "text or writable part (the layout gives no text end)"; *known = 0; }
        else if ((uint64_t)off < dm_cs_page_up(m->text_end)) part = "text";
        else if (m->key && (uint64_t)off >= m->key && (uint64_t)off < m->key + DM_RUNLOG_PAGE) part = "key page (read-only)";
        else if (m->fps && (uint64_t)off >= m->fps && (uint64_t)off < m->fps + DM_RUNLOG_PAGE) part = "frame step state page (writable, not executable)";
        else { part = "writable part (not executable)"; writable = 1; }
        dm_rl_buf b = {out, n, 0}; char h[24];
        dm_rl_put(&b, "%s%s%s, %s's %s", m->name, off < 0 ? "" : "+", dm_rl_shex(h, off), m->name, part);
        for (int k = 0; k < r->npiece; k++) {
            const dm_runlog_piece *p = &r->piece[k];
            if (strcmp(p->module, m->name) != 0 || off < p->off || (uint64_t)off - (uint64_t)p->off >= p->len) continue;
            dm_rl_put(&b, ", in a switchable mod's %s (%s)", p->code ? "code page" : "data", dm_runlog_role_label(p->roles));
            *hit = p->roles ? p->roles : 3;
            break;
        }
        if (writable && m->patch > 0 && off >= 0 && off < m->patch) dm_rl_put(&b, ", 0x%llx below its patch area", (unsigned long long)((uint64_t)m->patch - (uint64_t)off));
        return 1;
    }
    if (r && r->jit_size && a >= r->jit_base && a - r->jit_base < r->jit_size) {   // the JIT layout's code memory (loader.c jit_layout_init; hle_jit.c maps the served image there)
        dm_rl_buf b = {out, n, 0}; uint64_t off = a - r->jit_base;
        dm_rl_put(&b, "jit+0x%llx, %s", (unsigned long long)off, off < r->jit_image ? "the JIT code memory, in its served image (code made by the game's JIT plugin, built on the Mac)"
                                                                                  : "the JIT code memory, past its served image (not code)");
        *known = 1;
        return 1;
    }
    return 0;
}

// ---------- the summary ----------
typedef void (*dm_crash_line_fn)(void *ctx, const char *line);
typedef struct { dm_crash_line_fn fn; void *ctx; } dm_cs_out;
static inline void dm_cs_say(const dm_cs_out *o, const char *fmt, ...) __attribute__((format(printf, 2, 3)));
static inline void dm_cs_say(const dm_cs_out *o, const char *fmt, ...) {
    char l[1200]; va_list ap; va_start(ap, fmt); vsnprintf(l, sizeof l, fmt, ap); va_end(ap);
    o->fn(o->ctx, l);
}
enum { DM_CS_FRAMES = 16 };   // the newest frames shown of the crashed thread
static inline int dm_cs_zero_uuid(const char *u) {   // the game's code: no image iOS knows (or no UUID at all)
    for (; *u; u++) if (*u != '0' && *u != '-') return 0;
    return 1;
}
static inline void dm_cs_frame(const cj_doc *d, uint32_t f, uint32_t info, const dm_runlog_run *rec, const dm_cs_region *rg, int nrg, char *out, size_t n, unsigned *hit) {
    uint64_t a = 0, off = 0; char uuid[48], name[96];
    cj_u64(d, cj_get(d, f, "address"), &a); cj_u64(d, cj_get(d, f, "offsetIntoBinaryTextSegment"), &off);
    cj_text(d, cj_get(d, f, "binaryUUID"), uuid, sizeof uuid);
    cj_text(d, cj_get(d, f, "binaryName"), name, sizeof name);   // MXMetricManager's frames name their image
    for (uint32_t b = cj_kids(d, info, CJ_ARR); !name[0] && uuid[0] && b; b = d->v[b].next) {   // MetricManager's list them once, in binaryInfo
        char u2[48]; cj_text(d, cj_get(d, b, "uuid"), u2, sizeof u2);
        if (!strcmp(u2, uuid)) cj_text(d, cj_get(d, b, "name"), name, sizeof name);
    }
    dm_rl_buf o = {out, n, 0}; int known = 0;
    if (n) out[0] = 0;
    *hit = 0;
    dm_rl_put(&o, "0x%llx ", (unsigned long long)a);
    if (!dm_cs_zero_uuid(uuid)) {
        if (name[0] && strcmp(name, "???") != 0) dm_rl_put(&o, "%s+0x%llx", name, (unsigned long long)off);
        else dm_rl_put(&o, "image %.8s+0x%llx", uuid, (unsigned long long)off);
        return;
    }
    char w[512];
    if (rec && dm_cs_where(rec, a, w, sizeof w, &known, hit)) dm_rl_put(&o, "%s", w);
    else dm_rl_put(&o, "%s", rec ? "game code in no module of the run" : "game code");
    for (int k = 0; !known && k < nrg; k++)
        if (a >= rg[k].lo && a < rg[k].hi) {
            dm_rl_put(&o, ", in the report's region 0x%llx-0x%llx %s %s%s", (unsigned long long)rg[k].lo, (unsigned long long)rg[k].hi, rg[k].prot, rg[k].type, rg[k].prot[2] == 'x' ? "" : " (not executable)");
            break;
        }
}
// One crash diagnostic: diag holds the call stack tree, meta the exception fields (MetricManager: diag itself; MXMetricManager: its diagnosticMetaData), env MetricManager's environment
// (pid, build, device; MXMetricManager keeps them in meta), t0 and t1 the report's time range
static inline void dm_cs_one(const cj_doc *d, uint32_t diag, uint32_t meta, uint32_t env, uint32_t t0, uint32_t t1, const char *lay, size_t ln, int have_lay, const dm_cs_out *o) {
    char l[1200], term[512], when0[64], when1[64], v[128]; dm_rl_buf b = {l, sizeof l, 0}; long long et = 0, ec = 0, sg = 0;
    int het = cj_i64(d, cj_get(d, meta, "exceptionType"), &et), hec = cj_i64(d, cj_get(d, meta, "exceptionCode"), &ec), hsg = cj_i64(d, cj_get(d, meta, "signal"), &sg);
    if (het) { const char *nm = dm_cs_exc_name(et); if (nm) dm_rl_put(&b, "%s (%lld)", nm, et); else dm_rl_put(&b, "exception type %lld", et); }
    if (hec) { const char *nm = het ? dm_cs_code_name(et, ec) : NULL; if (nm) dm_rl_put(&b, "%s%s (%lld)", b.len ? ", " : "", nm, ec); else dm_rl_put(&b, "%scode 0x%llx", b.len ? ", " : "", (unsigned long long)ec); }
    if (hsg) { const char *nm = dm_cs_signal_name(sg); if (nm) dm_rl_put(&b, "%ssignal %s (%lld)", b.len ? "; " : "", nm, sg); else dm_rl_put(&b, "%ssignal %lld", b.len ? "; " : "", sg); }
    if (cj_text(d, cj_get(d, meta, "terminationReason"), term, sizeof term)) {
        const char *hint = dm_cs_term_hint(term);
        dm_rl_put(&b, "%stermination reason %s", b.len ? "; " : "", term);
        if (hint) dm_rl_put(&b, " (%s)", hint);
    }
    dm_cs_say(o, "%s", b.len ? l : "the report names no exception, signal or termination reason");
    uint32_t why = cj_get(d, meta, "exceptionReason");   // an Objective-C exception (MXCrashDiagnosticObjectiveCExceptionReason)
    if (cj_is(d, why, CJ_OBJ) && (cj_text(d, cj_get(d, why, "composedMessage"), v, sizeof v) || cj_text(d, cj_get(d, why, "exceptionName"), v, sizeof v))) dm_cs_say(o, "exception reason: %s", v);
    // The memory region info: the faulting address's region and its neighbours, white space runs as one space
    size_t rmax = 8192; char *region = malloc(rmax); dm_cs_region rg[16]; int nrg = 0;
    if (region && cj_text(d, cj_get(d, meta, "virtualMemoryRegionInfo"), region, rmax)) {
        nrg = dm_cs_regions(region, rg, 16);
        int shown = 0;
        for (const char *p = region; p && *p && shown < 5;) {
            const char *e = strchr(p, '\n'); size_t L = e ? (size_t)(e - p) : strlen(p), k = 0; char line[420]; int sp = 0;
            for (size_t i = 0; i < L && k + 1 < sizeof line; i++) {
                char c = p[i] == '\t' ? ' ' : p[i];
                if (c == ' ') { sp = k > 0; continue; }
                if (sp) { line[k++] = ' '; sp = 0; if (k + 1 >= sizeof line) break; }
                line[k++] = c;
            }
            line[k] = 0;
            if (k) { dm_cs_say(o, "memory: %s", line); shown++; }
            p = e ? e + 1 : NULL;
        }
    }
    // The run: pid, build, device, system, time
    uint32_t src = env ? env : meta; long long pid = -1; int hpid = cj_i64(d, cj_get(d, src, "pid"), &pid);
    b.len = 0; l[0] = 0;
    if (hpid) dm_rl_put(&b, "pid %lld", pid);
    if (cj_text(d, cj_get(d, src, env ? "applicationBuildVersion" : "appBuildVersion"), v, sizeof v)) dm_rl_put(&b, "%sapp build %s", b.len ? ", " : "", v);
    if (cj_text(d, cj_get(d, src, "deviceType"), v, sizeof v)) dm_rl_put(&b, "%s%s", b.len ? ", " : "", v);
    uint32_t os = cj_get(d, src, "osVersion");
    if (cj_is(d, os, CJ_STR)) { if (cj_text(d, os, v, sizeof v)) dm_rl_put(&b, "%s%s", b.len ? ", " : "", v); }
    else if (cj_is(d, os, CJ_OBJ) && cj_text(d, cj_get(d, os, "number"), v, sizeof v)) {
        char pl[64], bn[64];
        if (!cj_text(d, cj_get(d, os, "platform"), pl, sizeof pl)) snprintf(pl, sizeof pl, "iOS");
        dm_rl_put(&b, "%s%s %s", b.len ? ", " : "", pl, v);
        if (cj_text(d, cj_get(d, os, "buildNumber"), bn, sizeof bn)) dm_rl_put(&b, " (%s)", bn);
    }
    cj_text(d, t0, when0, sizeof when0); cj_text(d, t1, when1, sizeof when1);
    if (when0[0] && when1[0] && strcmp(when0, when1) != 0) dm_rl_put(&b, "%sbetween %s and %s", b.len ? ", " : "", when0, when1);
    else if (when1[0] || when0[0]) dm_rl_put(&b, "%sat %s", b.len ? ", " : "", when1[0] ? when1 : when0);
    dm_cs_say(o, "run: %s", b.len ? l : "the report names no pid, build or time");
    // That run's layout record, by the report's time range (MetricManager: begin and end, the crash's time; MXMetricManager: the payload's)
    long long hi = when1[0] ? dm_cs_time(when1) : when0[0] ? dm_cs_time(when0) : -1, lo = when0[0] ? dm_cs_time(when0) : hi;
    dm_runlog_run rec; memset(&rec, 0, sizeof rec); long long pids[DM_RUNLOG_KEEP * 4], later = 0; int np = 0, got = 0;
    if (!hpid) dm_cs_say(o, "layout: the report names no pid, so no run's record can be matched: game frames are raw addresses");
    else if (!have_lay) dm_cs_say(o, "layout: no run_layouts.txt (a build from before it, or it could not be read): game frames are raw addresses");
    else if ((got = dm_runlog_find(lay, ln, pid, lo, hi, &rec, &later, pids, (int)(sizeof pids / sizeof *pids), &np)) == 1)
        dm_cs_say(o, "layout: the run's record in run_layouts.txt: started %s, commit %s, title %s, switchable mods on: %s", rec.utc[0] ? rec.utc : "-", rec.commit[0] ? rec.commit : "-",
                  rec.title[0] ? rec.title : "-", dm_runlog_role_label(rec.mods));
    else if (got == 2)
        dm_cs_say(o, "layout: run_layouts.txt's record of pid %lld is of an earlier run (started %s): pid %lld started after it, before the crash, so the crashed run left no record "
                  "(it ended before writing one, or the write failed): game frames are raw addresses", pid, rec.utc[0] ? rec.utc : "-", later);
    else {
        b.len = 0; l[0] = 0;
        for (int k = 0; k < np; k++) dm_rl_put(&b, "%s%lld", k ? ", " : "", pids[k]);
        dm_cs_say(o, "layout: run_layouts.txt has no record of pid %lld (it holds the runs of pids %s): game frames are raw addresses", pid, np ? l : "none");
    }
    const dm_runlog_run *R = got == 1 ? &rec : NULL;
    // The crashed thread, newest frame first: each frame's subFrames holds its caller
    uint32_t tree = cj_get(d, diag, "callStackTree"), threads = cj_get(d, tree, "callStackThreads");
    if (!threads) threads = cj_get(d, tree, "callStacks");
    int nth = 0, pick = -1, k = 0; uint32_t th = 0, first = 0;
    for (uint32_t t = cj_kids(d, threads, CJ_ARR); t; t = d->v[t].next, nth++) {
        if (!first) first = t;
        if (pick < 0 && cj_is(d, cj_get(d, t, "threadAttributed"), CJ_TRUE)) { pick = nth; th = t; }
    }
    if (!th && first) th = first;
    uint32_t roots = cj_get(d, th, "rootFrames");
    if (!roots) roots = cj_get(d, th, "callStackRootFrames");
    uint32_t f = cj_kids(d, roots, CJ_ARR), info = cj_get(d, tree, "binaryInfo"), last = 0;
    unsigned hit_roles = 0; int hits[4], nhit = 0, nhits = 0;
    if (!f) dm_cs_say(o, "the report has no call stack");
    else if (pick >= 0) dm_cs_say(o, "crashed thread (the report's thread %d of %d), newest frame first:", pick, nth);
    else dm_cs_say(o, "no thread is marked as the crashed one; the report's first thread of %d, newest frame first:", nth);
    for (; f && k < 1 << 20; k++) {
        char fl[900]; unsigned hit = 0;
        dm_cs_frame(d, f, info, R, rg, nrg, fl, sizeof fl, &hit);
        if (hit) { hit_roles |= hit; if (nhit < 4) hits[nhit++] = k; nhits++; }
        if (k < DM_CS_FRAMES) dm_cs_say(o, "#%d %s", k, fl);
        last = f;
        uint32_t sub = cj_get(d, f, "subFrames");
        f = cj_kids(d, sub, CJ_ARR);
    }
    if (k > DM_CS_FRAMES) {
        char fl[900]; unsigned hit = 0;
        dm_cs_frame(d, last, info, R, rg, nrg, fl, sizeof fl, &hit);
        dm_cs_say(o, "... %d more frames; the oldest, #%d: %s", k - DM_CS_FRAMES, k - 1, fl);
    }
    // The switchable mods that run had in place, and the toggle to try off first
    if (R && R->npiece) {
        unsigned all = 0; b.len = 0; l[0] = 0;
        for (unsigned roles = 1; roles <= 3; roles++) {
            int cnt = 0, listed = 0; size_t mark = b.len;
            for (int i = 0; i < R->npiece; i++) if ((R->piece[i].roles ? R->piece[i].roles : 3) == roles) cnt++;
            if (!cnt) continue;
            all |= roles;
            dm_rl_put(&b, "%s%s: %d piece%s (", mark ? "; " : "", dm_runlog_role_label(roles), cnt, cnt == 1 ? "" : "s");
            for (int i = 0; i < R->npiece; i++) {
                const dm_runlog_piece *p = &R->piece[i]; char h[24];
                if ((p->roles ? p->roles : 3) != roles) continue;
                if (listed == 4) { dm_rl_put(&b, ", ..."); break; }
                dm_rl_put(&b, "%s%s %s %s%s", listed ? ", " : "", p->module, p->code ? "code page" : "data", p->off < 0 ? "" : "+", dm_rl_shex(h, p->off));
                if (!p->code) dm_rl_put(&b, " (%llu bytes)", (unsigned long long)p->len);
                listed++;
            }
            dm_rl_put(&b, ")");
        }
        char fr[96]; dm_rl_buf fb = {fr, sizeof fr, 0};   // which frames of the crashed thread run in them
        fr[0] = 0;
        if (!nhits) dm_rl_put(&fb, "no frame of the crashed thread is in them");
        else {
            dm_rl_put(&fb, "frame%s ", nhits > 1 ? "s" : "");
            for (int i = 0; i < nhit; i++) dm_rl_put(&fb, "%s#%d", i ? ", " : "", hits[i]);
            if (nhits > nhit) dm_rl_put(&fb, " and %d more", nhits - nhit);
            dm_rl_put(&fb, " %s in them", nhits > 1 ? "are" : "is");
        }
        unsigned off = hit_roles ? hit_roles : all;
        dm_cs_say(o, "switchable mods in place in that run: %s; %s. Turning %s off in the launcher is the first thing to try%s", l, fr, dm_runlog_role_label(off),
                  off == 3 ? " (one at a time, to tell which)" : "");
    } else if (R && R->mods) dm_cs_say(o, "switchable mods turned on in that run (%s), but none of their pieces was put in place", dm_runlog_role_label(R->mods));
    dm_runlog_free(&rec);
    free(region);
}
// Summarizes every crash diagnostic of a report (json: its text, n bytes, not NUL-terminated) by the layout record (lay, ln: the text of run_layouts.txt; NULL when there is none), one
// line at a time to fn. Returns how many it summarized (0: JSON with no crash diagnostic of a shape it knows), -1 when the text is not JSON, -2 when it is past the reader's limits
// (larger than 1 GB, more than 16M values, nested deeper than 65,536, or out of memory)
static inline int dm_crash_summary(const char *json, size_t n, const char *lay, size_t ln, dm_crash_line_fn fn, void *ctx) {
    cj_doc d; dm_cs_out o = {fn, ctx}; int count = 0;
    if (!cj_parse(&d, json, n)) return d.lim ? -2 : -1;
    uint32_t root = d.root, c;
    if ((c = cj_get(&d, root, "crashDiagnostic"))) {   // MetricManager: one diagnostic per report
        uint32_t tr = cj_get(&d, root, "timeRange");
        dm_cs_one(&d, c, c, cj_get(&d, root, "environment"), cj_get(&d, tr, "begin"), cj_get(&d, tr, "end"), lay, ln, lay != NULL, &o); count = 1;
    } else if ((c = cj_get(&d, root, "crashDiagnostics")) && cj_is(&d, c, CJ_ARR)) {   // an MXDiagnosticPayload: every crash of it, each with its own run
        int total = 0;
        for (uint32_t e = d.v[c].first; e; e = d.v[e].next) total++;
        for (uint32_t e = d.v[c].first; e; e = d.v[e].next) {
            if (total > 1) dm_cs_say(&o, "crash %d of %d in this report:", count + 1, total);
            uint32_t meta = cj_get(&d, e, "diagnosticMetaData");
            dm_cs_one(&d, e, meta ? meta : e, 0, cj_get(&d, root, "timeStampBegin"), cj_get(&d, root, "timeStampEnd"), lay, ln, lay != NULL, &o); count++;
        }
    } else if (cj_get(&d, root, "callStackTree")) {   // one MXCrashDiagnostic on its own
        uint32_t meta = cj_get(&d, root, "diagnosticMetaData");
        dm_cs_one(&d, root, meta ? meta : root, 0, 0, 0, lay, ln, lay != NULL, &o); count = 1;
    }
    cj_free(&d);
    return count;
}
