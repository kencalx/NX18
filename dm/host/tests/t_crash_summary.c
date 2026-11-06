// The crash summary's core (dm/host/crash_summary.h, run_layout.h), on any machine: the JSON reader (escapes, \u and surrogate pairs, numbers at their limits, nesting, and texts
// cut short or wrong, which must fail cleanly); the layout record (a block as loader.c writes it, the newest 8 kept across merges with a block cut off partway dropped, the record
// of a pid found by its start time when the pid came back after a restart, an older run of the pid told apart from the crashed run, lines with numbers past any address left
// out); where an address lies in a module (text, patch area after the image and before the base, back patch area, key page, frame step page, writable part, a switchable mod's
// page) or in the JIT code memory; and the summary of a small synthetic report of each shape, MetricManager's and MXMetricManager's.
// Every prefix of the reports is read as well, under ASan and UBSan in make asan (dm/tools/tests/test_crashlog.py compiles and runs it too, and holds the summary to
// scripts/crashlog.py line by line). Plain C: cc -std=gnu11 t_crash_summary.c
#include "../crash_summary.h"

static int fails, checks;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL %s:%d: ", __FILE__, __LINE__); fprintf(stderr, __VA_ARGS__); fputc('\n', stderr); } } while (0)

typedef struct { char *buf; size_t len, cap; int n; } lines_t;
static void collect(void *ctx, const char *l) {
    lines_t *L = ctx; size_t k = strlen(l);
    if (L->len + k + 2 > L->cap) { L->cap = (L->len + k + 2) * 2; char *g = realloc(L->buf, L->cap); if (!g) abort(); L->buf = g; }
    memcpy(L->buf + L->len, l, k); L->len += k; L->buf[L->len++] = '\n'; L->buf[L->len] = 0; L->n++;
}
static int has_line(const lines_t *L, const char *want) {   // a whole line of the summary
    size_t k = strlen(want);
    for (const char *p = L->buf; p && *p;) {
        const char *e = strchr(p, '\n'); size_t len = e ? (size_t)(e - p) : strlen(p);
        if (len == k && !memcmp(p, want, k)) return 1;
        p = e ? e + 1 : NULL;
    }
    return 0;
}

static void json_reader(void) {
    const char *t = "{\"a\": [1, -2, 3.75, 1e3, \"x\\n\\u00e9\\ud83d\\ude00\\/\", true, false, null, {}, []], \"b\": {\"max\": 18446744073709551615, \"over\": 18446744073709551616}}";
    cj_doc d; uint64_t u = 0; long long v = 0; char s[64];
    CHECK(cj_parse(&d, t, strlen(t)), "a valid text");
    uint32_t a = cj_get(&d, d.root, "a"), e = cj_kids(&d, a, CJ_ARR);
    CHECK(cj_i64(&d, e, &v) && v == 1, "1"); e = d.v[e].next;
    CHECK(cj_i64(&d, e, &v) && v == -2 && !cj_u64(&d, e, &u), "-2, not unsigned"); e = d.v[e].next;
    CHECK(cj_u64(&d, e, &u) && u == 3, "a real's integral part"); e = d.v[e].next;
    CHECK(!cj_u64(&d, e, &u), "an exponent is not exact"); e = d.v[e].next;
    CHECK(cj_text(&d, e, s, sizeof s) == 9 && !strcmp(s, "x\n\xc3\xa9\xf0\x9f\x98\x80/"), "escapes, \\u, a surrogate pair: %s", s);
    CHECK(cj_text(&d, e, s, 4) == 2 && !strcmp(s, "x\n"), "cut before a character that does not fit");
    CHECK(cj_text(&d, e, s, 5) == 4 && !strcmp(s, "x\n\xc3\xa9"), "a character that fits");
    e = d.v[e].next; CHECK(cj_is(&d, e, CJ_TRUE), "true"); e = d.v[e].next; CHECK(cj_is(&d, e, CJ_FALSE), "false"); e = d.v[e].next; CHECK(cj_is(&d, e, CJ_NULL), "null");
    e = d.v[e].next; CHECK(cj_is(&d, e, CJ_OBJ) && !d.v[e].first, "{}"); e = d.v[e].next; CHECK(cj_is(&d, e, CJ_ARR) && !d.v[e].first && !d.v[e].next, "[] last");
    uint32_t b = cj_get(&d, d.root, "b");
    CHECK(cj_u64(&d, cj_get(&d, b, "max"), &u) && u == UINT64_MAX, "the largest unsigned");
    CHECK(!cj_u64(&d, cj_get(&d, b, "over"), &u) && !cj_i64(&d, cj_get(&d, b, "max"), &v), "past 64 bits, and past the signed range");
    CHECK(!cj_get(&d, d.root, "c") && !cj_get(&d, a, "a") && !cj_text(&d, a, s, sizeof s) && !s[0], "missing keys and wrong types");
    cj_free(&d);
    static const char *const bad[] = {"", " ", "{", "[1,]", "{\"a\"}", "{\"a\":1,}", "[1] x", "\"abc", "tru", "-", "[1.]", "[1e]", "{\"a\" 1}", "[\"\x01\"]", "{1:2}", "]", "[}", "{]", "nul"};
    for (size_t i = 0; i < sizeof bad / sizeof *bad; i++) CHECK(!cj_parse(&d, bad[i], strlen(bad[i])) && !d.v, "not JSON: %s", bad[i]);
    size_t deep = 70000; char *n = malloc(2 * deep + 1);
    if (!n) abort();
    for (size_t i = 0; i < deep; i++) { n[i] = '['; n[2 * deep - 1 - i] = ']'; }
    CHECK(cj_parse(&d, n, 2000) == 0, "1000 open arrays and no close"); CHECK(cj_parse(&d, n + deep - 1000, 2000) == 1, "1000 nested arrays"); cj_free(&d);
    CHECK(!cj_parse(&d, n, 2 * deep) && d.lim, "nesting past the limit fails cleanly, on the limit");
    CHECK(!cj_parse(&d, n, 2000) && !d.lim, "a text cut short is no limit");
    CHECK(dm_crash_summary(n, 2 * deep, NULL, 0, collect, NULL) == -2, "the summary says it is past its limits");
    free(n);
}

static dm_runlog_mod g_mods[3] = {
    {.name = "main", .build = "00112233", .base = 0x200000000ull, .size = 0x1000000, .text_end = 0x7f1234, .key = 0xfdc000, .patch = 0xfe0000, .patch_len = 0x20000},
    {.name = "sdk", .base = 0x201400000ull, .size = 0x800000, .text_end = 0x300000, .key = 0x5f8000, .fps = 0x5fc000, .back = 0x700000, .back_len = 0x100000, .patch = -0x200000, .patch_len = 0x100000},
    {.name = "nro0", .base = 0x202000000ull, .size = 0x100000, .text_end = 0x40000, .key = 0xdc000, .patch = 0xe0000, .patch_len = 0x20000, .nro = 1}};
static dm_runlog_piece g_pieces[3] = {{.module = "main", .off = 0x64000, .len = 0x4000, .code = 1, .roles = 2}, {.module = "main", .off = 0xfe4000, .len = 0x4000, .code = 1, .roles = 3},
                                      {.module = "main", .off = 0x900010, .len = 8, .code = 0, .roles = 1}};
static dm_runlog_run run_of(long long pid, long long start) {
    dm_runlog_run r = {.pid = pid, .start = start, .commit = "557cb3b0", .title = "0100000000010000", .mods = 3, .nmod = 3, .npiece = 3, .mod = g_mods, .piece = g_pieces};
    return r;
}
static char *block_of(dm_runlog_run r) {
    size_t n = dm_runlog_block(NULL, 0, &r); char *b = malloc(n + 1);
    if (!b) abort();
    CHECK(dm_runlog_block(b, n + 1, &r) == n && strlen(b) == n, "measured, then written whole");
    return b;
}

static void record(void) {
    char *b = block_of(run_of(4242, 1793931330));
    CHECK(!strncmp(b, "run pid=4242 start=1793931330 utc=2026-11-06T02:15:30Z commit=557cb3b0 title=0100000000010000 mods=fps+ultrawide\n", 112), "the run line: %.120s", b);
    CHECK(strstr(b, "\nmodule name=sdk base=0x201400000 size=0x800000 text_end=0x300000 patch=-0x200000 patch_len=0x100000 key=0x5f8000 fps=0x5fc000 back=0x700000 back_len=0x100000\n") != NULL, "a module before its base");
    CHECK(strstr(b, "\npiece module=main off=0xfe4000 len=0x4000 kind=code roles=fps+ultrawide\npiece module=main off=0x900010 len=0x8 kind=data roles=fps\nend\n") != NULL, "pieces, then end");
    char small[40]; CHECK(dm_runlog_block(small, sizeof small, &(dm_runlog_run){.pid = 1}) > sizeof small && strlen(small) == sizeof small - 1, "cut to the buffer");
    // Twelve runs merged one after another: the newest 8, oldest first, under one header
    char *text = NULL; size_t n = 0;
    for (int i = 0; i < 12; i++) {
        char *bi = block_of(run_of(100 + i, 1793930000 + i)), *m = dm_runlog_merge(text, n, bi, DM_RUNLOG_KEEP, &n);
        free(text); free(bi); text = m;
        CHECK(text != NULL, "merged");
        if (!text) return;
    }
    long long pids[16]; int np = 0; dm_runlog_run got;
    long long later = 0;
    CHECK(dm_runlog_find(text, n, 104, -1, -1, &got, &later, pids, 16, &np) == 1 && np == 8 && pids[0] == 104 && pids[7] == 111, "the newest 8 kept: %d, %lld..%lld", np, pids[0], pids[np ? np - 1 : 0]);
    dm_runlog_free(&got);
    CHECK(dm_runlog_find(text, n, 103, -1, -1, &got, &later, pids, 16, &np) == 0, "the oldest dropped");
    // A crash of pid 104 after the run of pid 105 started (1793930005, more than a minute before the crash): the record of 104 is of an earlier run
    CHECK(dm_runlog_find(text, n, 104, 1793930200, 1793930200, &got, &later, NULL, 0, NULL) == 2 && got.start == 1793930004 && later == 111, "an earlier run of the pid: %lld", later);
    dm_runlog_free(&got);
    CHECK(dm_runlog_find(text, n, 111, 1793930200, 1793930200, &got, &later, NULL, 0, NULL) == 1 && got.start == 1793930011, "the newest run is the crashed one"); dm_runlog_free(&got);
    CHECK(dm_runlog_find(text, n, 110, 1793930040, 1793930040, &got, &later, NULL, 0, NULL) == 1, "a run of another pid within the minute before the crash proves nothing"); dm_runlog_free(&got);
    CHECK(!strncmp(text, DM_RUNLOG_HEADER, strlen(DM_RUNLOG_HEADER)) && !strstr(text + 1, "# Module layouts"), "one header");
    // A block cut off partway (its writer was stopped) is dropped at the next merge; the same pid after a restart is another run
    char *cut = malloc(n + 64); if (!cut) abort();
    static const char tail[] = "run pid=4242 start=1793991200 utc=x\nmodule name=main";
    memcpy(cut, text, n); memcpy(cut + n, tail, sizeof tail - 1); size_t cn = n + sizeof tail - 1;
    char *again = block_of(run_of(4242, 1793991200)), *b2 = dm_runlog_merge(cut, cn, b, DM_RUNLOG_KEEP, &cn), *b3 = b2 ? dm_runlog_merge(b2, cn, again, DM_RUNLOG_KEEP, &cn) : NULL;
    CHECK(b3 && !strstr(b3, "utc=x"), "the cut block dropped");
    CHECK(b3 && dm_runlog_find(b3, cn, 4242, 1793931336, 1793931336, &got, &later, pids, 16, &np) == 1 && got.start == 1793931330 && got.nmod == 3 && got.npiece == 3, "the run of that pid before the crash");
    if (got.nmod == 3) {
        CHECK(got.mod[1].patch == -0x200000 && got.mod[1].back == 0x700000 && got.mod[2].nro == 1 && !strcmp(got.mod[0].build, "00112233") && got.mods == 3, "modules read back");
        CHECK(got.piece[2].off == 0x900010 && got.piece[2].len == 8 && !got.piece[2].code && got.piece[2].roles == 1 && !strcmp(got.utc, "2026-11-06T02:15:30Z"), "pieces read back");
    }
    dm_runlog_free(&got);
    CHECK(b3 && dm_runlog_find(b3, cn, 4242, -1, -1, &got, &later, NULL, 0, NULL) == 1 && got.start == 1793991200, "no crash time: the newest of that pid"); dm_runlog_free(&got);
    CHECK(b3 && dm_runlog_find(b3, cn, 4242, 1793000000, 1793000000, &got, &later, NULL, 0, NULL) == 0, "every run of the pid started after the crash");
    CHECK(dm_runlog_find(NULL, 0, 1, -1, -1, &got, &later, pids, 16, &np) == 0 && np == 0, "no record");
    free(cut); free(again); free(b2); free(b3); free(text); free(b);
    // Numbers past any address (a record changed in the Files app): those lines are left out, the rest is read, and nothing overflows (UBSan in make asan)
    static const char odd[] = "run pid=7 start=100 utc=x commit=c title=t mods=ultrawide\n"
        "module name=bad base=0x1 size=0xffffffffffffffff text_end=0x10 patch=-0x8000000000000000 patch_len=0xffffffffffffffff key=0x0\n"
        "module name=far base=0x200000000 size=0x1000000 text_end=0x10 patch=-0x7fffffffffffffff patch_len=0x10 key=0x0\n"
        "module name=main base=0x210000000 size=0x1000000 text_end=0x7f1234 patch=0xfe0000 patch_len=0x20000 key=0xfdc000\n"
        "jit base=0xffffffffffffffff size=0x10 image=0x10\n"
        "piece module=main off=-0x8000000000000000 len=0x4000 kind=code roles=ultrawide\n"
        "piece module=main off=0x64000 len=0xffffffffffffffff kind=code roles=ultrawide\n"
        "piece module=main off=0x64000 len=0x4000 kind=code roles=ultrawide\nend\n";
    CHECK(dm_runlog_find(odd, sizeof odd - 1, 7, -1, -1, &got, &later, NULL, 0, NULL) == 1 && got.nmod == 1 && !strcmp(got.mod[0].name, "main") && got.npiece == 1 && !got.jit_size,
          "lines past any address left out: %d modules, %d pieces", got.nmod, got.npiece);
    char out[300]; int known; unsigned hit;
    for (uint64_t a = 0; a < 0x300000000ull; a += 0x7ff1234) dm_cs_where(&got, a, out, sizeof out, &known, &hit);
    dm_runlog_free(&got);
    dm_runlog_mod wild[2] = {{.name = "w", .base = 0x100000000ull, .size = UINT64_MAX, .patch = INT64_MIN, .patch_len = UINT64_MAX, .text_end = UINT64_MAX},
                             {.name = "v", .base = UINT64_MAX - 1, .size = 0x10, .patch = INT64_MAX, .key = UINT64_MAX}};
    dm_runlog_piece wp = {.module = "w", .off = INT64_MIN, .len = UINT64_MAX, .code = 1};
    dm_runlog_run wr = {.nmod = 2, .npiece = 1, .mod = wild, .piece = &wp, .jit_base = UINT64_MAX - 4, .jit_size = UINT64_MAX};
    static const uint64_t probes[] = {0, 1, 0xffffffff, 0x100000000ull, 0x8000000000000000ull, UINT64_MAX - 2, UINT64_MAX};
    for (size_t i = 0; i < sizeof probes / sizeof *probes; i++) dm_cs_where(&wr, probes[i], out, sizeof out, &known, &hit);   // whatever it says, without overflow
    // The JIT layout's code memory
    char *jb = block_of((dm_runlog_run){.pid = 9, .start = 50, .jit_base = 0x300000000ull, .jit_size = 0x2000000, .jit_image = 0x1a4000});
    CHECK(strstr(jb, "\njit base=0x300000000 size=0x2000000 image=0x1a4000\nend\n") != NULL, "the jit line: %s", jb);
    CHECK(dm_runlog_find(jb, strlen(jb), 9, -1, -1, &got, &later, NULL, 0, NULL) == 1 && got.jit_base == 0x300000000ull && got.jit_size == 0x2000000 && got.jit_image == 0x1a4000, "the jit line read back");
    CHECK(dm_cs_where(&got, 0x300010040, out, sizeof out, &known, &hit) && known && !strcmp(out, "jit+0x10040, the JIT code memory, in its served image (code made by the game's JIT plugin, built on the Mac)"), "%s", out);
    CHECK(dm_cs_where(&got, 0x300400000, out, sizeof out, &known, &hit) && !strcmp(out, "jit+0x400000, the JIT code memory, past its served image (not code)"), "%s", out);
    CHECK(!dm_cs_where(&got, 0x302000000, out, sizeof out, &known, &hit), "past the code memory");
    dm_runlog_free(&got); free(jb);
}

static void where(void) {
    dm_runlog_run r = run_of(1, 1);
    static const struct { uint64_t a; const char *want; int known; unsigned hit; } t[] = {
        {0x200fd8fa0, "main+0xfd8fa0, main's writable part (not executable), 0x7060 below its patch area", 1, 0},
        {0x2007f0648, "main+0x7f0648, main's text", 1, 0},
        {0x2007f3ffc, "main+0x7f3ffc, main's text", 1, 0},   // past the text end, on its last page: code still
        {0x200064010, "main+0x64010, main's text, in a switchable mod's code page (Ultrawide)", 1, 2},
        {0x200fe4100, "main+0xfe4100, main's patch area, in a switchable mod's code page (High frame rate and Ultrawide)", 1, 3},
        {0x200fdc008, "main+0xfdc008, main's key page (read-only)", 1, 0},
        {0x200900014, "main+0x900014, main's writable part (not executable), in a switchable mod's data (High frame rate), 0x6dffec below its patch area", 1, 1},
        {0x201200000, "sdk-0x200000, sdk's patch area", 1, 0},
        {0x2012fffff, "sdk-0x100001, sdk's patch area", 1, 0},
        {0x201300000, "sdk-0x100000, sdk's gap before its base (not code: read-write on the iPhone, inaccessible on the Mac)", 1, 0},
        {0x201b50000, "sdk+0x750000, sdk's back patch area", 1, 0},
        {0x2019fc020, "sdk+0x5fc020, sdk's frame step state page (writable, not executable)", 1, 0},
        {0x201800000, "sdk+0x400000, sdk's writable part (not executable)", 1, 0},
        {0x2020fffff, "nro0+0xfffff, nro0's patch area", 1, 0},
    };
    for (size_t i = 0; i < sizeof t / sizeof *t; i++) {
        char out[300]; int known = -1; unsigned hit = 99;
        CHECK(dm_cs_where(&r, t[i].a, out, sizeof out, &known, &hit) && !strcmp(out, t[i].want) && known == t[i].known && hit == t[i].hit, "0x%llx: %s", (unsigned long long)t[i].a, out);
    }
    char out[300]; int known; unsigned hit;
    CHECK(!dm_cs_where(&r, 0x201000000, out, sizeof out, &known, &hit) && !dm_cs_where(&r, 0x2011fffff, out, sizeof out, &known, &hit) && !dm_cs_where(&r, 0x202100000, out, sizeof out, &known, &hit), "in no module");
    dm_runlog_mod m = g_mods[0]; m.text_end = 0; dm_runlog_run r2 = {.nmod = 1, .mod = &m};
    CHECK(dm_cs_where(&r2, 0x200001000, out, sizeof out, &known, &hit) && !known && !strcmp(out, "main+0x1000, main's text or writable part (the layout gives no text end)"), "no text end: %s", out);
    CHECK(dm_cs_time("2026-11-06T02:15:36Z") == 1793931336 && dm_cs_time("2026-11-06 03:15:36 +0100") == 1793931336 && dm_cs_time("2026-11-06T02:15:36.5-00:30") == 1793933136
          && dm_cs_time("2026-13-01T00:00:00Z") == -1 && dm_cs_time("soon") == -1 && dm_cs_time("1970-01-01T00:00:00Z") == 0 && dm_cs_time("2000-03-01T00:00:00Z") == 951868800, "times");
    CHECK(!strcmp(dm_cs_code_name(1, 0x105), "EXC_ARM_PAC_FAIL") && !strcmp(dm_cs_code_name(1, 0x103), "EXC_ARM_SP_ALIGN") && !dm_cs_code_name(1, 0x106), "arm64 data abort codes");
}

// A small report of MetricManager's shape: a crash in the writable part, called from the text and a mod's page, then the app's own frames
static const char *k_modern =
    "{\"crashDiagnostic\": {\"callStackTree\": {\"binaryInfo\": [{\"name\": \"DmIOS\", \"uuid\": \"AAAA0000-0000-0000-0000-000000000001\"}], \"callStackPerThread\": true,"
    " \"callStackThreads\": [{\"threadAttributed\": false, \"rootFrames\": [{\"address\": 16, \"binaryUUID\": \"AAAA0000-0000-0000-0000-000000000001\", \"offsetIntoBinaryTextSegment\": 16}]},"
    " {\"threadAttributed\": true, \"rootFrames\": [{\"address\": 8606551968, \"binaryUUID\": \"00000000-0000-0000-0000-000000000000\", \"offsetIntoBinaryTextSegment\": 8606551968, \"subFrames\": ["
    "{\"address\": 8590344208, \"binaryUUID\": \"00000000-0000-0000-0000-000000000000\", \"offsetIntoBinaryTextSegment\": 8590344208, \"subFrames\": ["
    "{\"address\": 4375710396, \"binaryUUID\": \"AAAA0000-0000-0000-0000-000000000001\", \"offsetIntoBinaryTextSegment\": 1379004, \"subFrames\": []}]}]}]}]},"
    " \"exceptionCode\": 2, \"exceptionType\": 1, \"signal\": 9, \"terminationReason\": \"Namespace CODESIGNING, Code 0x2\","
    " \"virtualMemoryRegionInfo\": \"0x200fd8fa0 is in 0x2007f4000-0x200fdc000;  bytes after start: 1\\n      REGION TYPE   START - END   [ VSIZE] PRT\\/MAX SHRMOD\\n"
    "--->  mapped file   2007f4000-200fdc000   [  7.9M] rw-\\/rw- SM=COW  Object_id=22222222\"},"
    " \"environment\": {\"applicationBuildVersion\": \"1.4.1\", \"deviceType\": \"iPhone19,3\", \"osVersion\": {\"buildNumber\": \"24C5037i\", \"number\": \"27.3\", \"platform\": \"iPhone OS\"}, \"pid\": 4242},"
    " \"timeRange\": {\"begin\": \"2026-11-06T02:15:36Z\", \"end\": \"2026-11-06T02:15:36Z\"}, \"version\": \"2.0.0\"}";
// And MXMetricManager's: a payload of two crashes, binaryName in the frames, the older keys
static const char *k_payload =
    "{\"timeStampBegin\": \"2026-11-06 02:15:36 +0000\", \"timeStampEnd\": \"2026-11-06 02:15:36 +0000\", \"crashDiagnostics\": ["
    "{\"version\": \"1.0.0\", \"callStackTree\": {\"callStackPerThread\": true, \"callStacks\": [{\"threadAttributed\": true, \"callStackRootFrames\": ["
    "{\"address\": 8590344208, \"binaryUUID\": \"00000000-0000-0000-0000-000000000000\", \"binaryName\": \"???\", \"offsetIntoBinaryTextSegment\": 8590344208, \"subFrames\": ["
    "{\"address\": 4375710396, \"binaryUUID\": \"AAAA0000-0000-0000-0000-000000000001\", \"binaryName\": \"DmIOS\", \"offsetIntoBinaryTextSegment\": 1379004}]}]}]},"
    " \"diagnosticMetaData\": {\"appBuildVersion\": \"1.4.1\", \"osVersion\": \"iPhone OS 27.3 (24C5037i)\", \"exceptionType\": 1, \"exceptionCode\": 1, \"signal\": 11, \"pid\": 4242,"
    " \"terminationReason\": \"Namespace SIGNAL, Code 0xb\"}},"
    "{\"callStackTree\": {\"callStacks\": []}, \"diagnosticMetaData\": {\"exceptionType\": 10, \"signal\": 6, \"exceptionReason\": {\"composedMessage\": \"*** -[NSArray objectAtIndex:]: index 3 beyond bounds\"}}}]}";

static void summaries(void) {
    dm_runlog_run r = run_of(4242, 1793931330); char *lay = block_of(r);
    lines_t L = {0};
    CHECK(dm_crash_summary(k_modern, strlen(k_modern), lay, strlen(lay), collect, &L) == 1, "one crash");
    static const char *const want[] = {
        "EXC_BAD_ACCESS (1), KERN_PROTECTION_FAILURE (2); signal SIGKILL (9); termination reason Namespace CODESIGNING, Code 0x2 (code signing: an invalid page, the run executed a page that is not signed code, such as a writable one)",
        "memory: 0x200fd8fa0 is in 0x2007f4000-0x200fdc000; bytes after start: 1",
        "memory: REGION TYPE START - END [ VSIZE] PRT/MAX SHRMOD",
        "memory: ---> mapped file 2007f4000-200fdc000 [ 7.9M] rw-/rw- SM=COW Object_id=22222222",
        "run: pid 4242, app build 1.4.1, iPhone19,3, iPhone OS 27.3 (24C5037i), at 2026-11-06T02:15:36Z",
        "layout: the run's record in run_layouts.txt: started 2026-11-06T02:15:30Z, commit 557cb3b0, title 0100000000010000, switchable mods on: High frame rate and Ultrawide",
        "crashed thread (the report's thread 1 of 2), newest frame first:",
        "#0 0x200fd8fa0 main+0xfd8fa0, main's writable part (not executable), 0x7060 below its patch area",
        "#1 0x200064010 main+0x64010, main's text, in a switchable mod's code page (Ultrawide)",
        "#2 0x104d00abc DmIOS+0x150abc",
        "switchable mods in place in that run: High frame rate: 1 piece (main data +0x900010 (8 bytes)); Ultrawide: 1 piece (main code page +0x64000); High frame rate and Ultrawide: 1 piece (main code page +0xfe4000); frame #1 is in them. Turning Ultrawide off in the launcher is the first thing to try",
    };
    CHECK(L.n == (int)(sizeof want / sizeof *want), "%d lines:\n%s", L.n, L.buf);
    for (size_t i = 0; i < sizeof want / sizeof *want; i++) CHECK(has_line(&L, want[i]), "missing: %s\nin:\n%s", want[i], L.buf);
    free(L.buf); memset(&L, 0, sizeof L);
    CHECK(dm_crash_summary(k_modern, strlen(k_modern), NULL, 0, collect, &L) == 1 && has_line(&L, "#0 0x200fd8fa0 game code, in the report's region 0x2007f4000-0x200fdc000 rw- mapped file (not executable)")
          && has_line(&L, "layout: no run_layouts.txt (a build from before it, or it could not be read): game frames are raw addresses") && !strstr(L.buf, "switchable"), "no record:\n%s", L.buf);
    free(L.buf); memset(&L, 0, sizeof L);
    CHECK(dm_crash_summary(k_payload, strlen(k_payload), lay, strlen(lay), collect, &L) == 2, "two crashes");
    CHECK(has_line(&L, "crash 1 of 2 in this report:") && has_line(&L, "EXC_BAD_ACCESS (1), KERN_INVALID_ADDRESS (1); signal SIGSEGV (11); termination reason Namespace SIGNAL, Code 0xb")
          && has_line(&L, "run: pid 4242, app build 1.4.1, iPhone OS 27.3 (24C5037i), at 2026-11-06 02:15:36 +0000") && has_line(&L, "#0 0x200064010 main+0x64010, main's text, in a switchable mod's code page (Ultrawide)")
          && has_line(&L, "#1 0x104d00abc DmIOS+0x150abc") && has_line(&L, "crash 2 of 2 in this report:") && has_line(&L, "EXC_CRASH (10); signal SIGABRT (6)")
          && has_line(&L, "exception reason: *** -[NSArray objectAtIndex:]: index 3 beyond bounds") && has_line(&L, "the report has no call stack")
          && has_line(&L, "layout: the report names no pid, so no run's record can be matched: game frames are raw addresses"), "payload:\n%s", L.buf);
    free(L.buf); memset(&L, 0, sizeof L);
    // The crashed run left no record (it ended before writing one) and an older run had its pid: that record is not taken, since a run of another pid started in between
    char *older = block_of(run_of(4242, 1793000000)), *between = block_of(run_of(30001, 1793900000)); size_t on = 0;
    char *t1 = dm_runlog_merge(NULL, 0, older, DM_RUNLOG_KEEP, &on), *t2 = t1 ? dm_runlog_merge(t1, on, between, DM_RUNLOG_KEEP, &on) : NULL;
    CHECK(t2 && dm_crash_summary(k_modern, strlen(k_modern), t2, on, collect, &L) == 1
          && has_line(&L, "layout: run_layouts.txt's record of pid 4242 is of an earlier run (started 2026-10-26T07:33:20Z): pid 30001 started after it, before the crash, so the crashed run left no record (it ended before writing one, or the write failed): game frames are raw addresses")
          && has_line(&L, "#0 0x200fd8fa0 game code, in the report's region 0x2007f4000-0x200fdc000 rw- mapped file (not executable)") && !strstr(L.buf, "switchable"), "an earlier run of the pid:\n%s", L.buf);
    free(L.buf); memset(&L, 0, sizeof L); free(older); free(between); free(t1); free(t2);
    // JSON in no shape the summary knows: nothing summarized (DmMetrics.m says so)
    static const char *const unknown[] = {"{\"diagnostic\": {\"crash\": {}}, \"environment\": {\"pid\": 1}}", "{\"crashDiagnostics\": []}", "[]", "7"};
    for (size_t i = 0; i < sizeof unknown / sizeof *unknown; i++) CHECK(dm_crash_summary(unknown[i], strlen(unknown[i]), NULL, 0, collect, &L) == 0 && L.n == 0, "no crash in: %s", unknown[i]);
    free(L.buf); memset(&L, 0, sizeof L);
    // Every prefix of each report, and each with one byte changed, is read without a fault: a prefix is not JSON, a changed byte may still be
    const char *reps[] = {k_modern, k_payload};
    for (int k = 0; k < 2; k++) {
        size_t n = strlen(reps[k]); char *cp = malloc(n); int bad = 0;
        if (!cp) abort();
        for (size_t i = 0; i < n; i++) { memcpy(cp, reps[k], i); if (dm_crash_summary(cp, i, lay, strlen(lay), collect, &L) != -1) bad++; L.len = 0; L.n = 0; }
        CHECK(!bad, "%d prefixes read as JSON", bad);
        for (size_t i = 0; i < n; i += 3) {
            static const char sub[] = "\"{}[],:\\0 x";
            memcpy(cp, reps[k], n); cp[i] = sub[i % (sizeof sub - 1)];
            dm_crash_summary(cp, n, lay, i % 7 ? strlen(lay) : i % strlen(lay), collect, &L); L.len = 0; L.n = 0;
        }
        free(cp);
    }
    free(L.buf); free(lay);
}

int main(void) {
    json_reader(); record(); where(); summaries();
    if (fails) { fprintf(stderr, "crash summary: %d of %d checks failed\n", fails, checks); return 1; }
    printf("crash summary: OK (%d checks)\n", checks);
    return 0;
}
