// DM_SIGNPOST (../dm_signpost.h): the switch, the off path and the macros' calls. Built three ways (Makefile):
//   T_SP_STUB   against signpost_stub/os/signpost.h, which counts every call: only the exact value 1 turns the lanes on; off, no os_signpost call is made and no macro
//               argument is evaluated; on, each macro reaches os_signpost with its category's log, its name, its format and its id
//   T_SP_NONE   with -DDM_SP_NONE: the no-op form the Linux parse check and a plain C11 build get, which evaluates nothing and calls nothing even after init
//   (neither)   against the system's <os/signpost.h>: on a Mac the real os_signpost, turned on with DM_SIGNPOST=1, every macro form emitted once (not recorded: nothing
//               reads the log here); on Linux the no-op form
#include "../dm_signpost.h"
#include <stdio.h>
#include <string.h>

static int fails, evals;
#define CHECK(c, ...) do { if (!(c)) { fails++; printf("FAIL %s:%d: ", __FILE__, __LINE__); printf(__VA_ARGS__); printf("\n"); } } while (0)
static int side(void) { return ++evals; }   // an argument with a side effect: the off path must not evaluate it

#ifdef T_SP_STUB
#include <stdarg.h>
static int n_create, n_gen, n_emit; static const char *created[8];
static struct { int kind; os_log_t log; os_signpost_id_t id; const char *name, *fmt; int a0; } last;
os_log_t os_log_create(const char *subsystem, const char *category) {
    if (strcmp(subsystem, "org.nintanium.host")) { printf("FAIL subsystem %s\n", subsystem); fails++; }
    if (n_create >= 0 && n_create < 8) created[n_create] = category;
    return (os_log_t)(uintptr_t)(0x1000 + 0x10 * n_create++);
}
os_signpost_id_t os_signpost_id_generate(os_log_t log) { (void)log; return 100 + (os_signpost_id_t)n_gen++; }
void stub_sp(int kind, os_log_t log, os_signpost_id_t id, const char *name, const char *fmt, ...) {
    const char *p = strchr(fmt, '%'); va_list ap; va_start(ap, fmt); last.a0 = p && p[1] == 'd' ? va_arg(ap, int) : 0; va_end(ap);   // the first argument, when it is an int
    n_emit++; last.kind = kind; last.log = log; last.id = id; last.name = name; last.fmt = fmt;
}
#endif

static void emit_all(int expect_on) {   // every macro form once, with arguments that count their evaluation
    int e0 = evals;
    dm_sp_id id = DM_SP_ID(DM_SP_GPU + 0 * side());
    DM_SP_BEGIN(DM_SP_FRAME, "submit", DM_SP_EXCL, "cmdbufs=%d", side());
    DM_SP_END(DM_SP_FRAME, "submit", DM_SP_EXCL, "fence=%llu", (unsigned long long)side());
    DM_SP_BEGIN(DM_SP_GPU, "gpu", id, "frame=%llu seg=%u", (unsigned long long)side(), 0u);
    DM_SP_END(DM_SP_GPU, "gpu", id, "exec_ms=%.3f err=%d", 1.5, side());
    DM_SP_EVENT(DM_SP_POI, "longframe", "%{public}s", side() ? "frame 1" : "");
    if (!expect_on) CHECK(evals == e0, "the off path evaluated %d macro arguments", evals - e0);
    else CHECK(evals == e0 + 6, "on, %d of 6 arguments evaluated", evals - e0);
}

int main(void) {
    CHECK(!DM_SP_ON(), "on before dm_sp_init");
    CHECK(dm_sp_env_on("1") && !dm_sp_env_on(NULL) && !dm_sp_env_on("") && !dm_sp_env_on("0") && !dm_sp_env_on("2") && !dm_sp_env_on("10") && !dm_sp_env_on("1 ") && !dm_sp_env_on("yes"),
          "only the exact value 1 turns the lanes on");
    emit_all(0);
    const char *offs[] = {NULL, "", "0", "2", "10", "on", "true"};
    for (unsigned i = 0; i < sizeof offs / sizeof *offs; i++) {
        if (offs[i]) setenv("DM_SIGNPOST", offs[i], 1); else unsetenv("DM_SIGNPOST");
        CHECK(!dm_sp_init() && !DM_SP_ON(), "DM_SIGNPOST=%s turned the lanes on", offs[i] ? offs[i] : "(unset)");
    }
    emit_all(0);
#ifdef T_SP_STUB
    CHECK(!n_create && !n_gen && !n_emit, "off: %d os_log_create, %d id, %d emit calls", n_create, n_gen, n_emit);
#endif
    setenv("DM_SIGNPOST", "1", 1);
    int on = dm_sp_init();
#if defined(DM_SP_HAVE)
    CHECK(on == 1 && DM_SP_ON(), "DM_SIGNPOST=1 left the lanes off");
    CHECK(dm_sp_init() == 1, "a second init");
    for (int c = 0; c < DM_SP_NLOG; c++) CHECK(dm_sp.log[c] != NULL, "category %d has no log", c);
#else
    CHECK(on == 0 && !DM_SP_ON(), "the no-op form turned on");
#endif
#ifdef T_SP_STUB
    static const char *const cats[] = {"PointsOfInterest", "Frame", "GPU", "Display", "Shaders"};
    CHECK(n_create == 5, "%d logs made, want 5 (one per category, once)", n_create);
    for (int c = 0; c < 5 && c < n_create; c++) CHECK(!strcmp(created[c], cats[c]), "category %d is %s, want %s", c, created[c], cats[c]);
    dm_sp_id a = DM_SP_ID(DM_SP_GPU), b = DM_SP_ID(DM_SP_GPU);
    CHECK(a && b && a != b && n_gen == 2, "ids %llu %llu from %d calls", (unsigned long long)a, (unsigned long long)b, n_gen);
    DM_SP_BEGIN(DM_SP_GPU, "gpu", a, "seg=%d", 7);
    CHECK(n_emit == 1 && last.kind == 'b' && last.log == DM_SP_LOG(DM_SP_GPU) && last.id == a && !strcmp(last.name, "gpu") && !strcmp(last.fmt, "seg=%d") && last.a0 == 7, "begin");
    DM_SP_END(DM_SP_GPU, "gpu", a, "err=%d", 3);
    CHECK(n_emit == 2 && last.kind == 'e' && last.id == a && last.a0 == 3, "end");
    DM_SP_EVENT(DM_SP_DISPLAY, "tick", "why=%d", 1);
    CHECK(n_emit == 3 && last.kind == 'v' && last.log == DM_SP_LOG(DM_SP_DISPLAY) && last.id == OS_SIGNPOST_ID_EXCLUSIVE && !strcmp(last.name, "tick"), "event");
    DM_SP_BEGIN(DM_SP_POI, "frame", DM_SP_EXCL, "frame=%d", 2);
    CHECK(last.log == DM_SP_LOG(DM_SP_POI) && last.id == OS_SIGNPOST_ID_EXCLUSIVE, "an exclusive interval");
    n_emit = 0;
#endif
    emit_all(on);
#ifdef T_SP_STUB
    CHECK(n_emit == 5, "%d of 5 emits", n_emit);
#endif
    printf("t_signpost (%s): %s\n",
#if defined(T_SP_STUB)
           "counting stand-in",
#elif defined(DM_SP_HAVE)
           "the system's os_signpost",
#else
           "no-op form",
#endif
           fails ? "FAILED" : "ok");
    return fails != 0;
}
