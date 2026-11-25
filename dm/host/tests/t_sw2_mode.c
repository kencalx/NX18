// DM_SW2_MODE (hle_sdk16.c sw2_mode): nn::pl::IsRunningOnOunce answers false, as a Switch 1, unless the switch is on. Off: no log line, the answer of X1.0.
// On: true, logged once. The real forced registration, no guest SDK; g_sw2_mode is reset between cases, as a new process would start
#define DM_LOG_IMPL   // the log lines are counted here (dm_log below), not written
#include "../hle_sdk16.c"
#include <stdarg.h>
static int logs; static char last_log[256];
void dm_log(const char *fmt, ...) { va_list ap; va_start(ap, fmt); vsnprintf(last_log, sizeof last_log, fmt, ap); va_end(ap); logs++; }

static int checks, fails;
#define CHECK(c, msg) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, msg); } } while (0)
void *guest_sym(const char *name) { (void)name; return NULL; }
module_t *g_mod;
int g_nmod;
uint64_t g_t0_ns;
uint64_t now_ns(void) { return 0; }
int dm_sdk_major(void) { return 3; }
int dm_game_imports(const char *prefix) { (void)prefix; return 0; }
module_t *module_of(const void *p) { (void)p; return NULL; }
void dm_backtrace(uint64_t fp) { (void)fp; }
void hle_bind_system_event(void *ev, int autoclear) { (void)ev; (void)autoclear; }
void hle_signal_system_event(void *ev) { (void)ev; }
uint64_t hle_system_event_binding(void *ev) { (void)ev; abort(); }
int hle_signal_system_event_binding(uint64_t binding) { (void)binding; abort(); }
uint32_t hle_hid_connected_npad(void) { return 0; }
void dm_host_helper_qos(qos_class_t q) { (void)q; }
void dm_applet_enter(const char *name) { (void)name; }   // hle_oe.c: the shop stand-ins beside the hook
void dm_applet_leave(void) {}

// One run of the game: DM_SW2_MODE as given (NULL: unset), then the game asks three times. Returns the answer; *nlog gets the lines logged
static unsigned run(unsigned (*ounce)(void), const char *value, int *nlog) {
    if (value) setenv("DM_SW2_MODE", value, 1); else unsetenv("DM_SW2_MODE");
    atomic_store(&g_sw2_mode, -1); logs = 0; last_log[0] = 0;
    unsigned a = ounce(), b = ounce(), c = ounce();
    CHECK(a == b && b == c, "the answer stays the same through the run");
    *nlog = logs;
    return a;
}

int main(void) {
    const hle_force_ent *e = &hle_force_h_pl_IsOunce;
    CHECK(!strcmp(e->name, "_ZN2nn2pl16IsRunningOnOunceEv") && e->fn, "forced registration has the exact public symbol and a function");
    CHECK(e->why && e->why[0], "forced hook has a reason");
    if (fails) return 1;
    unsigned (*ounce)(void) = e->fn;
    int n;
    // Off: the answer of X1.0 (false), and nothing logged
    const char *off[] = {NULL, "", "0", "00", "off", "OFF", "no", "false", "False"};
    for (unsigned i = 0; i < sizeof off / sizeof *off; i++) {
        CHECK(run(ounce, off[i], &n) == 0, "off: running on a Switch 1");
        CHECK(n == 0, "off: no log line, as before the switch");
    }
    // On: true, one log line naming the switch
    const char *on[] = {"1", "on", "yes", "2"};
    for (unsigned i = 0; i < sizeof on / sizeof *on; i++) {
        CHECK(run(ounce, on[i], &n) == 1, "on: running on a Switch 2");
        CHECK(n == 1 && strstr(last_log, "DM_SW2_MODE") && strstr(last_log, "IsRunningOnOunce: yes"), "on: logged once, naming the switch");
    }
    // Read once: a change of the variable after the first call does not flip the answer mid-run
    CHECK(run(ounce, "1", &n) == 1, "on at the first call");
    setenv("DM_SW2_MODE", "0", 1);
    CHECK(ounce() == 1, "kept on after the variable changes");
    unsetenv("DM_SW2_MODE");
    printf("t_sw2_mode: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
