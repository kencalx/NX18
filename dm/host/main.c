// Bootstrap: after loading the modules, initialize the SDK runtime in the real order of nn::init::Start (sdk+0x2b0470) in the SDK, then enter nnMain.
#include "dm.h"
#include "front.h"
#include "../gfx/nvn/dmsh_chain.h"
#include <CoreFoundation/CoreFoundation.h>
#include <stdatomic.h>
#include <sys/resource.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>
void probe_install(void); void hid_keys_init(void); void stubs_report(void); void crash_install(void); void guest_thread_init(void); void guest_gate_stack(int own_stack); uint32_t svc_thread_main_init(void);
typedef void (*fn0)(void); typedef void (*fn2)(uint64_t, uint64_t); typedef void (*fnp)(void *);
static void *req(const char *n){ void *p=guest_sym(n); if(!p) die("missing symbol %s", n); return p; }

// Game arguments: argv[0] is fixed to "game", and whatever follows "--" is appended as is (on a real device nn::init takes them from the process argument area and hands them to the SDK through SetHostArgc/Argv)
static char *g_argv[64] = {"game"}; static int g_argc = 1;

static void guest_main(void) {
    guest_thread_init();
    guest_gate_stack(0);   // the guest code runs on this thread's own stack: its SVCs get a stack of their own
    { void dm_oodle_serve_maybe(int); dm_oodle_serve_maybe(0); }   // DM_OODLE_SERVE tool mode: the game's own Oodle decoder over stdin / stdout (hle_oodle.c, exits when the input ends)
    uint32_t hmain = svc_thread_main_init();   // Main thread handle: x0 of nnosInitialize (stored in an sdk global, used by ThreadManagerImplByHorizon); x1 = pointer to the argument area
    // Copy Start step by step: _init_libc1 = __nnmusl_init_locks (initializes the stdio etc. locks as recursive locks; skipping it self-deadlocks on nested locking in putc) + __init_ssp.
    // The three callbacks passed in by rtld: A only sets an rtld flag (skipped), B = each module's DT_INIT (before nnMain), C = destructors (not done)
    ((fn0)req("_init_libc0"))();
    LOG(">>> nnosInitialize"); ((fn2)req("nnosInitialize"))(hmain, 0);
    ((fn0)req("_init_libc1"))();
    LOG(">>> nninitInitializeSdkModule"); ((fn0)req("nninitInitializeSdkModule"))();
    // The game arguments are in place before nninitStartup, as on hardware (nn::os takes them from the process argument area in nnosInitialize): Unreal Engine's nninitStartup
    // (Octopath Traveler 0, main+0x12afc) reads -SwitchVirtualAddressSpaceSize= and its other memory options there
    ((fnp)req("_ZN2nn2os11SetHostArgcEi"))((void *)(uint64_t)g_argc);
    ((fnp)req("_ZN2nn2os11SetHostArgvEPPc"))(g_argv);
    LOG(">>> nninitStartup"); ((fn0)req("nninitStartup"))();
    ((fn0)req("_init_libc2"))();
    run_module_inits();   // rtld callback B: each module's DT_INIT (global constructors)
    { void dm_guest_spawn_selftest(void); dm_guest_spawn_selftest(); }   // DM_GUEST_SPAWN_TEST self-test of host-created guest threads (hle_guestthread.c)
    { void dm_oodle_serve_maybe(int); dm_oodle_serve_maybe(1); }   // DM_OODLE_SERVE with a decoder that needs the game's malloc (LZ5, hle_oodle.c)
    { void dm_oodle_job_maybe(void); dm_oodle_job_maybe(); }   // DM_OODLE_JOB: decode a job file with the game's own Oodle and exit (hle_oodle.c, for the offline shader tools)
    LOG(">>> nnMain"); ((fn0)req("nnMain"))();
    LOG("nnMain returned");
}

struct dm_flags g_flag;
uint64_t g_t0_ns;
static void flags_init(void) {
    g_flag.thr = !!getenv("DM_THR"); g_flag.svc = !!getenv("DM_SVC"); g_flag.fs = !!getenv("DM_FS");
    g_flag.dbg = !!getenv("DM_DBG"); g_flag.imports = !!getenv("DM_IMPORTS");
    g_flag.bootprof = !!getenv("DM_BOOTPROF");
}

// Zero point of the boot timeline = process creation time (p_starttime from sysctl KERN_PROC_PID, wall clock) converted to the now_ns monotonic time base; same definition on Mac / iOS
static uint64_t proc_start_mono_ns(void) {
    struct kinfo_proc kp; size_t n = sizeof kp; int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    uint64_t mono = now_ns(); struct timeval tv; gettimeofday(&tv, NULL);
    if (sysctl(mib, 4, &kp, &n, NULL, 0) || !n) return mono;
    int64_t age = (int64_t)(tv.tv_sec - kp.kp_proc.p_starttime.tv_sec) * 1000000000ll + (tv.tv_usec - kp.kp_proc.p_starttime.tv_usec) * 1000ll;
    return age > 0 ? mono - (uint64_t)age : mono;
}

#ifdef DM_GAME_MULTI
// A host over the programs of a multi-program application (game.py header_multi): the profile of the program DM_PROGRAM names, program 0 without it. One run is one program (hle_oe.c)
const dm_game_t *dm_game_cur(void) {
    static const dm_game_t *g;
    if (!g) {
        const char *e = getenv("DM_PROGRAM"); int p = e ? atoi(e) : 0; g = &dm_games[0];
        for (size_t i = 0; i < sizeof dm_games / sizeof *dm_games; i++) if (dm_games[i].program == p) g = &dm_games[i];
    }
    return g;
}
#endif
// The modules to load when the command line names none: those of the profile's build row for main's build (its build ID from the rewriter's main.fixups.tsv), else all the profile's
// modules. A game's versions may differ in modules: Mario Kart World's base game has main subsdk0 (a Mono runtime) sdk, its update 1.8.0 main subsdk0 (the movie player) subsdk1 sdk
static int profile_modules(const char *dir, const char **names) {
    const char *all[] = DM_GAME_MODULES;
    const struct { const char *build, *mods; } rows[] = {DM_GAME_BUILD_MODULES};
    char path[1024], line[256], bid[33] = "";
    snprintf(path, sizeof path, "%s/main.fixups.tsv", dir);
    FILE *f = fopen(path, "r");
    while (f && fgets(line, sizeof line, f)) if (sscanf(line, "# BUILD_ID %32s", bid) == 1) break;
    if (f) fclose(f);
    for (size_t r = 0; *bid && r < sizeof rows / sizeof *rows; r++) {
        if (!rows[r].build || strcmp(rows[r].build, bid)) continue;
        int n = 0;
        for (int k = 0; k < DM_GAME_NMOD; k++) {   // in the profile's load order; build_modules (game.py) made the row from it
            const char *s = strstr(rows[r].mods, all[k]); size_t l = strlen(all[k]);
            while (s && !((s == rows[r].mods || s[-1] == ' ') && (!s[l] || s[l] == ' '))) s = strstr(s + 1, all[k]);
            if (s) names[n++] = all[k];
        }
        if (n < DM_GAME_NMOD) LOG("modules of main's build %.16s: %s (the profile lists %d)", bid, rows[r].mods, DM_GAME_NMOD);
        return n;
    }
    for (int k = 0; k < DM_GAME_NMOD; k++) names[k] = all[k];
    return DM_GAME_NMOD;
}

// Host loading (independent of UIKit / Metal): read the NSO, relocate, forced take-over, probes / tick gate / keys, start prefetch. By default it runs synchronously in main;
// the iOS front end can call dm_host_preload_start(same arguments) at the very start of the App's main() so that it runs first on a background thread, in parallel with the UIKit startup chain (⓪ + ① ≈ max(UIKit chain, host loading)).
static pthread_key_t g_race_keys[512];
static unsigned g_race_n, g_race_want;
static void *keyrace_thread(void *unused);
extern uint64_t g_host_start_ns;   // hle_lifecycle.c: the start's timeline counts from here when no Play time is given (DM_PLAY_AT)
static void host_preload(int argc, char **argv) {
    g_host_start_ns = now_ns();
    g_t0_ns = proc_start_mono_ns();
    flags_init();
    { void dm_diag_samplers_start(void); dm_diag_samplers_start(); }   // DM_MEMSTAT / DM_THRCPU (memstat.m): after the iOS front end has set the env files' switches
    if (argc < 2) die("usage: dmhost <dir> [mod...] [-- game arguments...]");
    // Time zone: a game gets local time from nn::time (ToCalendarTime / ToPosixTime, hle_time.c), which converts with the host's zone, so its screens show this machine's time.
    // The guest C library's localtime / mktime stay UTC, as on a Switch. Only deterministic comparison (DM_FIXED_TIME) pins the host to UTC: the same replay must convert to the same
    // calendar time on this machine (UTC+8) and on the second Mac (UTC+9)
    if (getenv("DM_FIXED_TIME")) setenv("TZ", "UTC", 1);
    // Open file limit: the soft limit starts at 256 on iOS (and in a default macOS shell), while the game's file handles, the RomFS archives, save transactions and Metal caches share it. Raise it to 4096 (as far as the hard limit allows)
    struct rlimit rl; if (!getrlimit(RLIMIT_NOFILE, &rl) && rl.rlim_cur < 4096) {
        rlim_t was = rl.rlim_cur; rl.rlim_cur = rl.rlim_max < 4096 ? rl.rlim_max : 4096;
        if (setrlimit(RLIMIT_NOFILE, &rl)) LOG("open file limit %llu could not be raised", (unsigned long long)was);
    }
    crash_install();
    {   // Which build this is: the commit the packer stamped into the app (DMCommit; a run outside an app has none), the shader chain the host loads, the profile
        CFBundleRef b = CFBundleGetMainBundle(); CFTypeRef c = b ? CFBundleGetValueForInfoDictionaryKey(b, CFSTR("DMCommit")) : NULL; char cs[64] = "not recorded";
        if (c && CFGetTypeID(c) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)c, cs, sizeof cs, kCFStringEncodingUTF8);
        LOG("build: commit %s, shader chain %s, profile %s", cs, DMSH_CHAIN, DM_GAME_ID);
        // G17: who built it (the builder's Profile name at build time, the one name the log carries, by the owner's decision) and the build ID, then the acknowledgement's day
        // (nx18.ack: "<version> <day>"). The live Profile is never logged
        char by[96] = "", bid[32] = "", ack[48] = "";
        CFTypeRef v = b ? CFBundleGetValueForInfoDictionaryKey(b, CFSTR("DMBuiltBy")) : NULL;
        if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)v, by, sizeof by, kCFStringEncodingUTF8);
        v = b ? CFBundleGetValueForInfoDictionaryKey(b, CFSTR("DMBuildID")) : NULL;
        if (v && CFGetTypeID(v) == CFStringGetTypeID()) CFStringGetCString((CFStringRef)v, bid, sizeof bid, kCFStringEncodingUTF8);
        CFPropertyListRef a = CFPreferencesCopyAppValue(CFSTR("nx18.ack"), kCFPreferencesCurrentApplication);
        if (a && CFGetTypeID(a) == CFStringGetTypeID()) { char s[48]; if (CFStringGetCString((CFStringRef)a, s, sizeof s, kCFStringEncodingUTF8)) { const char *sp = strchr(s, ' '); snprintf(ack, sizeof ack, "%s", sp ? sp + 1 : s); } }
        if (a) CFRelease(a);
        if (bid[0]) {
            if (by[0]) LOG("build: built by %s, build ID %s, %s%s", by, bid, ack[0] ? "acknowledged " : "not acknowledged yet", ack);
            else LOG("build: build ID %s (no profile name at build), %s%s", bid, ack[0] ? "acknowledged " : "not acknowledged yet", ack);
        }
    }
    const char *race = getenv("DM_TEST_KEYRACE");
    if (race && *race) {
        g_race_want = (unsigned)strtoul(race, NULL, 10);
        if (g_race_want > 512) g_race_want = 512;
        pthread_t th;
        if (pthread_create(&th, NULL, keyrace_thread, NULL)) die("DM_TEST_KEYRACE cannot start its thread");
        pthread_detach(th);
    }
    { void dm_term_install(void); dm_term_install(); }   // SIGTERM graceful exit (hle_lifecycle.c)
    { void crash_set_dump_hook(void (*)(void)); void svc_thread_dump(void); crash_set_dump_hook(svc_thread_dump); }   // Dump guest thread state on a crash
    dm_stall_start();   // the freeze detector (stall.c, DM_STALL_LOG): a red line and a state dump when presents stop while the game is in focus
    const char *names[argc + DM_GAME_NMOD]; int n = 0;
    int i = 2;
    for (; i < argc && strcmp(argv[i], "--"); i++) names[n++] = argv[i];
    if (i < argc && !strcmp(argv[i], "--")) for (i++; i < argc && g_argc < 63; i++) g_argv[g_argc++] = argv[i];
    else if (*DM_GAME_ARGS) {   // no "--" on the command line (the iOS app, the NSP script's Mac runs): the game profile's game_args, split at spaces
        char *s = strdup(DM_GAME_ARGS);
        for (char *t = strtok(s, " "); t && g_argc < 63; t = strtok(NULL, " ")) g_argv[g_argc++] = t;
        LOG("game arguments from the game profile: %s", DM_GAME_ARGS);
    }
    if (!n) n = profile_modules(argv[1], names);
    load_modules(argv[1], names, n);
    dm_cheats_init();   // the Atmosphère cheat files for this build (hle_cheats.c): picked by first 16 hex digits of main's build ID, which the loader knows now
    dm_sdk_major();   // logs the SDK version, which SDK-dependent behaviour follows (loader.c)
    uint64_t ta = now_ns();
    probe_install();   // DM_PROBE probes (for diagnostics)
    hid_keys_init();   // DM_KEYS scripted input
    uint64_t tb = now_ns();
    stubs_report();
    if (g_flag.bootprof) LOG("① breakdown (after loading): probes / keys %.1f ms, stub report %.1f ms", (tb - ta) / 1e6, (now_ns() - tb) / 1e6);
    { void loader_hash_log(void); loader_hash_log(); }   // DM_LOADHASH=1: address-independent hash of the load result (loader.c)
    { void dm_ue_malloc_install(void); dm_ue_malloc_install(); }   // Unreal's allocator on a host malloc zone, for the builds whose constructor call is cut (hle_uemalloc.c)
}
static struct { int argc; char **argv; pthread_t th; _Atomic int started; } g_pre;
static void *preload_thread(void *a) { (void)a; host_preload(g_pre.argc, g_pre.argv); return NULL; }
static void *keyrace_thread(void *unused) {
    (void)unused;
    for (unsigned i = 0; i < g_race_want; i++) if (pthread_key_create(&g_race_keys[g_race_n++], NULL)) break;
    return NULL;
}
// Start host loading early. When to call: as one of the first things in the process (iOS: in the App's main() before entering UIApplicationMain); the environment variables loading needs must already be set
// (DM_ROMFS / DM_SAVE / DM_TEMP etc. and the cwd -- loading and the prefetch start read them); the arguments must be identical, item by item, to those of the later dm_main (a difference reports a failure and exits).
// May be called only once; if not called, loading is synchronous inside main and behavior is exactly as before this call existed. Does not depend on UIKit / Metal.
void dm_host_preload_start(int argc, char **argv) {
    if (atomic_exchange(&g_pre.started, 1)) return;
    g_pre.argc = argc; g_pre.argv = calloc((size_t)argc + 1, sizeof(char *));
    for (int i = 0; i < argc; i++) g_pre.argv[i] = strdup(argv[i]);
    pthread_attr_t a; pthread_attr_init(&a); pthread_attr_setstacksize(&a, 8 << 20);
    if (pthread_create(&g_pre.th, &a, preload_thread, NULL)) die("dm_host_preload_start: cannot start the thread");
}
int main(int argc, char **argv) {
    { int mtl_pso_prebuild_tool(void); if (mtl_pso_prebuild_tool()) return 0; }   // DM_PSO_PREBUILD=tool: the pipeline archive's prebuild alone, no game (nvn_mtl.m)
    if (getenv("DM_PRELOAD")) dm_host_preload_start(argc, argv);   // Exercise the early-start path on Mac (on iOS it is called from the App's main())
    if (atomic_load(&g_pre.started)) {
        pthread_join(g_pre.th, NULL);
        int same = argc == g_pre.argc; for (int i = 0; same && i < argc; i++) same = !strcmp(argv[i], g_pre.argv[i]);
        if (!same) die("[RED] dm_host_preload_start arguments differ from main's");
        void crash_thread_init(void); crash_thread_init();   // The signal alternate stack is per thread: loading installed it on another thread, so add it for this thread
        LOG("host loading already finished early in the background (dm_host_preload_start)");
    } else host_preload(argc, argv);
    { void dm_fps_state_apply(void); dm_fps_state_apply(); }   // frame rate and render scale into the frame step state page (loader.c): the iOS launcher sets them after the loading began
    { void dm_mod_variants_apply(void); dm_mod_variants_apply(); }   // the switchable mods the launcher turned on (loader.c), before any guest code runs
    // The pipeline archive bundled with the app starts opening beside the game's own start, instead of at its first submission (nvn_mtl.m mtl_pso_bundle_preopen), once the guest's
    // address space is reserved (hle_svc.c mem_init_once, at the game's first memory call): the order of the two largest mappings stays as it was, the guest's block first. The
    // launcher's settings are in the environment by now
    { void mtl_pso_bundle_preopen(void); dm_mem_ready_hook = mtl_pso_bundle_preopen; }
    dm_start_game();   // the "start: Play at" line; the host load part of the start's timeline ends here (hle_lifecycle.c)
    front_run(guest_main);
    return 0;
}
