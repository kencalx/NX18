// Server environment queries offline (hle_offline.c, from PR #1199): the takeovers are looked up by their mangled names in the real swforce registrations, so a missing or misspelled
// one fails, as it would fall through to the SDK's nsd client and abort on a host that serves no nsd service
#include "../hle_offline.c"
#include <mach-o/getsect.h>

static int unexpected, checks, failed;
void hle_bind_system_event(void *ev, int autoclear) { (void)ev; (void)autoclear; unexpected++; }
void dm_applet_enter(const char *name) { (void)name; unexpected++; }
void dm_applet_leave(void) { unexpected++; }
// hle_offline.c's Poll and Select go to the host's sockets (hle_net.c): neither may run here
int dm_sk_poll(void *fds, uint64_t n, int ms) { (void)fds; (void)n; (void)ms; unexpected++; return -1; }
int dm_sk_select(int n, uint64_t *r, uint64_t *w, uint64_t *e, const int64_t *tv) { (void)n; (void)r; (void)w; (void)e; (void)tv; unexpected++; return -1; }
extern const struct mach_header_64 _mh_execute_header;
#define CHECK(c, msg) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", msg); } } while (0)
static void *hook(const char *name) {
    unsigned long bytes = 0;
    const hle_force_ent *entries = (const hle_force_ent *)getsectiondata(&_mh_execute_header, "__DATA", "swforce", &bytes);
    void *fn = NULL;
    unsigned count = 0;
    for (size_t i = 0; entries && i < bytes / sizeof *entries; i++) {
        if (strcmp(entries[i].name, name)) continue;
        count++; fn = entries[i].fn;
        CHECK(entries[i].why && entries[i].why[0], "takeover has a reason");
    }
    CHECK(count == 1 && fn, name);
    return count == 1 ? fn : NULL;
}
int main(void) {
    int (*type)(void) = hook("_ZN2nn3nsd35GetApplicationServerEnvironmentTypeEv");
    void (*identifier)(char *) = hook("_ZN2nn3nsd24GetEnvironmentIdentifierEPNS0_21EnvironmentIdentifierE");
    if (type && identifier) {
        struct { char value[8]; uint8_t guard[8]; } env;
        memset(&env, 0xa5, sizeof env);
        identifier(env.value);
        CHECK(!memcmp(env.value, "lp1\0\0\0\0\0", 8), "the environment identifier is retail lp1");
        for (size_t i = 0; i < sizeof env.guard; i++) CHECK(env.guard[i] == 0xa5, "identifier writes only its eight-byte output");
        // oe::ServerEnvironmentType 1 is lp1 (the game's enum-to-name table): the type agrees with the identifier. oe::GetServerEnvironmentType reaches it through the sdk's PLT
        CHECK(type() == 1, "the server environment type is retail lp1 (1)");
    }
    CHECK(unexpected == 0, "environment queries need no event, applet or network operation");
    printf("server environment: %d checks, %d failed\n", checks, failed);
    return failed != 0;
}
