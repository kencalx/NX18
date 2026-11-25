// Ultrawide's camera in the loader (../loader.c dm_camera_aspect_screen, dm_fps_state_apply, dm_game_aspect): the fixups table's CAMERA_ASPECT, the build gate, the ratio the host
// asks for at state +0x64 only under Ultrawide on a wider screen, and the ratio read back only from the camera stub's acknowledgement at +0x68. Synthetic pages, no game files.
// Adapted from ComicBit/nxnative eb9a42ba4 (MIT)
#include "../loader.c"
#include <assert.h>
#include <signal.h>
#include <sys/resource.h>
#include <sys/wait.h>
void mtl_present_screen(uint32_t w, uint32_t h) { (void)w; (void)h; }   // loader.c: a screen taller than 16:9; no renderer here

struct dm_flags g_flag;
uint64_t now_ns(void) { return 0; }
void gate_register(uint64_t a, const char *k, int n, uint64_t o) { (void)a; (void)k; (void)n; (void)o; }
void hlecount_seal(void) {}
void *hlecount_wrap(const char *kind, const char *name, void *fn) { (void)kind; (void)name; return fn; }
uint64_t resolve_import(module_t *m, const char *name) { (void)m; (void)name; return 0; }
int hle_implements(const char *name) { (void)name; return 0; }
int svc_nro_deactivate(module_t *m) { m->loaded = 0; return 1; }

static _Alignas(0x4000) uint8_t image[0xc000];
static module_t module;
static const char *build = "cd57b23fa4bbad65803d9788c01821ee";
static const float SCREEN = 2868.0f / 1320;   // an iPhone 18 Pro Max in landscape

static void reset(void) {
    atomic_store(&g_cam_state, NULL); g_cam_screen = 0; dm_fps_state = NULL;
    memset(image, 0, sizeof image);
    module = (module_t){.base = image, .size = sizeof image, .fps_state_off = 0x8000, .key_page_off = 0x4000, .key_page_size = 0x4000, .camera_aspect = 1};
    strcpy(module.name, "main"); strcpy(module.build_id, build);
    setenv("DM_FPS_TARGET", "0", 1); unsetenv("DM_RENDER_SCALE"); unsetenv("DM_DYNAMIC_RESOLUTION"); unsetenv("DM_SCREEN_ASPECT"); unsetenv("DM_MOD_ULTRAWIDE");
}
static float at(unsigned off) { float f; memcpy(&f, image + 0x8000 + off, sizeof f); return f; }
static void acknowledge(void) {   // what the camera stub does after the projection's store
    uint32_t bits = atomic_load((_Atomic uint32_t *)(void *)(image + 0x8064));
    atomic_store_explicit((_Atomic uint32_t *)(void *)(image + 0x8068), bits, memory_order_release);
}
static void start(int ultrawide, float screen) {
    reset(); install_fps_state(&module);
    if (screen) dm_camera_aspect_screen(screen);   // the front end, after the loading began
    if (ultrawide) setenv("DM_MOD_ULTRAWIDE", "1", 1);
    dm_fps_state_apply();
}

static void asks_only_under_ultrawide(void) {
    start(1, SCREEN);
    assert(at(0x64) == SCREEN && dm_game_aspect() == 0);   // asked for, not drawn yet: no squeeze
    acknowledge(); assert(dm_game_aspect() == SCREEN);
    start(0, SCREEN); assert(at(0x64) == 0);                // Ultrawide off: the game's own
    start(1, 0); assert(at(0x64) == 0);                     // no screen ratio (the Mac, or the front end left Ultrawide off)
    start(1, 16.0f / 9); assert(at(0x64) == 0);             // a 16:9 screen
    start(1, NAN); assert(at(0x64) == 0);
    reset(); install_fps_state(&module); dm_camera_aspect_screen(SCREEN); setenv("DM_MOD_ULTRAWIDE", "1", 1); setenv("DM_SCREEN_ASPECT", "1.43", 1);
    dm_fps_state_apply(); assert(at(0x64) == 0);            // a taller Picture shape wins (the front end sets 0 under Ultrawide)
    setenv("DM_SCREEN_ASPECT", "0", 1); dm_fps_state_apply(); assert(at(0x64) == SCREEN);
    // an acknowledgement of 0 (the game's own again) or of 16:9 reads as none
    start(1, SCREEN); acknowledge(); assert(dm_game_aspect() == SCREEN);
    unsetenv("DM_MOD_ULTRAWIDE"); dm_fps_state_apply(); assert(at(0x64) == 0); acknowledge(); assert(dm_game_aspect() == 0);
}
static void other_builds(void) {
    for (int mode = 0; mode < 3; mode++) {
        reset();
        if (mode == 0) module.camera_aspect = 0;
        if (mode == 1) strcpy(module.build_id, "00000000000000000000000000000000");
        if (mode == 2) strcpy(module.name, "sdk");
        install_fps_state(&module); dm_camera_aspect_screen(SCREEN); setenv("DM_MOD_ULTRAWIDE", "1", 1); dm_fps_state_apply();
        assert(at(0x64) == 0 && dm_game_aspect() == 0);
        float f = SCREEN; memcpy(image + 0x8068, &f, 4); assert(dm_game_aspect() == 0);   // not read either
    }
}
static void fixups_and_bounds(void) {
    reset();
    char dir[] = "/tmp/dm-aspect-XXXXXX"; assert(mkdtemp(dir));
    char path[128]; snprintf(path, sizeof path, "%s/main.fixups.tsv", dir);
    FILE *f = fopen(path, "w"); assert(f);
    fprintf(f, "# PATCH_OFF\t0xc000\n# KEY_PAGE_OFF\t0x4000\n# KEY_PAGE_SIZE\t0x4000\n# KEY_K18_IDX\t0\n# KEY_KTLS_IDX\t1\n# KEY_KTLR_IDX\t2\n# KEY_KGATE_IDX\t3\n"
               "# FPS_STATE_OFF\t0x8000\n# CAMERA_ASPECT\t1\n# BUILD_ID\t%s\n", build);
    fclose(f); module.camera_aspect = 0; module.fps_state_off = 0; module.build_id[0] = 0;
    read_layout(&module, dir);
    assert(module.camera_aspect == 1 && module.fps_state_off == 0x8000 && !strcmp(module.build_id, build));
    unlink(path); rmdir(dir);
    module.size = 0x806c; install_fps_state(&module);   // the exact extent the camera needs
    pid_t child = fork(); assert(child >= 0);
    if (!child) { struct rlimit lim = {0, 0}; setrlimit(RLIMIT_CORE, &lim); int fd = open("/dev/null", O_WRONLY); dup2(fd, 2); module.size--; install_fps_state(&module); _exit(0); }
    int status; assert(waitpid(child, &status, 0) == child);
    assert(!(WIFEXITED(status) && WEXITSTATUS(status) == 0));   // a state page too small for it stops the load
}
static void *acks(void *unused) { (void)unused; for (int i = 0; i < 20000; i++) acknowledge(); return NULL; }
static void concurrency(void) {
    start(1, SCREEN);
    pthread_t t; assert(!pthread_create(&t, NULL, acks, NULL));
    for (int i = 0; i < 20000; i++) { float r = dm_game_aspect(); assert(r == 0 || r == SCREEN); }
    assert(!pthread_join(t, NULL)); assert(dm_game_aspect() == SCREEN);
}
int main(void) {
    for (int k = 0; k < 2; k++) {
        asks_only_under_ultrawide(); other_builds(); fixups_and_bounds(); concurrency();
        build = "277178b7dba1b6d4949a84778d4abc58";
    }
    puts("Ultrawide's camera (Breath of the Wild 1.9.0, Tears of the Kingdom 1.4.3): fixups key, build gate, Ultrawide and screen conditions, acknowledgement, bounds: OK");
    return 0;
}
