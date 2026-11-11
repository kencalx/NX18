// GLSLC at run time. Fire Emblem: Three Houses (KTGL, SDK 6.5.0) compiles 9 built-in GLSL shaders at boot with the game's own runtime compiler (subsdk0, glslcCompile called through a function
// table from main+0x9c89f8; the sources are plain strings in main, e.g. "in vec3 ktglPosition0; …"). Their outputs are in no game file, and shaders are translated offline only, so the
// outputs are captured once on the Mac: DM_GLSLC_CAPTURE=<dir> writes every successful compile's GLSLC output (magic 0x19866891, the whole output's length at +0x44) to
// <dir>/<FNV-1a of the output>.glslc. shader_split.py reads that folder like any other source of GLSLC outputs (the NSP script makes it for a game whose main holds GLSL sources and imports glslcCompile).
// The compile object's first word points at its last results {GLSLCcompilationStatus *, GLSLCoutput *}; the status has "success" at +0xc and "allocation error" at +0xd, which is what the
// game itself reads after the call (main+0x9c8a04)
// Play: a game may also compile when a scene needs a shader its files do not hold. Catherine: Full Body loads each material's shaders from data/shaders_binary/<flags>.vs / .ps, a pre-compiled
// cache that lacks many combinations, and compiles the missing ones (21 when a save at Night 2 loads), past the boot the NSP script's capture runs. Without DM_GLSLC_CAPTURE, every output
// whose file name the shader map does not name (its source column: /glslc_capture/<name> or /glslc_play/<name>) is saved to glslc_play/ beside the save (DM_SAVE's parent: the app's
// Documents/glslc_play, on the Mac beside save/, as pso_user.tsv; DM_GLSLC_PLAY=<dir> another folder, off none). Its draws are missing in this build (shaders are translated offline only);
// the NSP script takes the folder into the next build (gather_glslc_play)
#include "hle.h"
#include <sys/stat.h>
#include <unistd.h>
#include <mach-o/dyld.h>

// The capture files the shader map was built from: the FNV-1a names in its source column, sorted (glslc_known). NULL: no map could be read, so every output counts as new
static uint64_t *g_known; static size_t g_nknown; static int g_known_read;
static int u64_cmp(const void *a, const void *b) { uint64_t x = *(const uint64_t *)a, y = *(const uint64_t *)b; return x < y ? -1 : x > y; }
static void known_read(void) {
    const char *path = getenv("DM_NVN_SHMAP");   // set by the iOS app, the Mac app and the NSP script's run command; a host run by hand reads dm/games/<id>/ beside dm/host (nvn_mtl.m shmap_read)
    char def[1200];
    if (!path) { char exe[1024]; uint32_t n = sizeof exe; if (_NSGetExecutablePath(exe, &n)) return; char *sl = strrchr(exe, '/'); if (sl) *sl = 0;
        snprintf(def, sizeof def, "%s/../games/%s/shader_map.tsv", exe, DM_GAME_ID); path = def; }
    FILE *f = fopen(path, "r"); if (!f) return;
    size_t cap = 0; char line[4096];
    g_known = malloc(1);
    while (fgets(line, sizeof line, f)) {
        const char *m = strstr(line, "/glslc_capture/"); if (!m) m = strstr(line, "/glslc_play/");
        if (!m) continue;
        const char *h = strchr(m + 1, '/') + 1; char *end; uint64_t v = strtoull(h, &end, 16);
        if (end != h + 16 || strncmp(end, ".glslc#", 7)) continue;
        if (g_nknown == cap) { uint64_t *k = realloc(g_known, (cap = cap ? cap * 2 : 64) * sizeof *k); if (!k) break; g_known = k; }
        g_known[g_nknown++] = v;
    }
    fclose(f);
    qsort(g_known, g_nknown, sizeof *g_known, u64_cmp);
}
static int glslc_known(uint64_t h) {   // 1: the map names this output, 0: it does not, -1: no map
    if (!g_known_read) { g_known_read = 1; known_read(); }
    return g_known ? bsearch(&h, g_known, g_nknown, sizeof h, u64_cmp) != NULL : -1;
}

static int save(const char *dir, uint64_t h, const uint8_t *out, uint32_t n, char *path, size_t np) {   // 1: written now, 0: there already, -1: failed
    snprintf(path, np, "%s/%016llx.glslc", dir, (unsigned long long)h);
    struct stat st; if (!stat(path, &st)) return 0;
    char tmp[1100]; snprintf(tmp, sizeof tmp, "%s.partial", path);   // a whole file or none: the NSP script takes only whole outputs
    FILE *f = fopen(tmp, "wb"); if (!f) { LOG("[RED] glslc: cannot write %s", tmp); return -1; }
    int ok = fwrite(out, 1, n, f) == n; ok &= !fclose(f);
    if (!ok || rename(tmp, path)) { LOG("[RED] glslc: cannot write %s", path); unlink(tmp); return -1; }
    return 1;
}

static const char *play_dir(void) {   // glslc_play/ beside the save, made at the first output it gets; NULL: off
    static char dir[1024]; static int init;
    if (!init) {
        init = 1; const char *e = getenv("DM_GLSLC_PLAY"), *s = getenv("DM_SAVE");
        if (e && (!strcmp(e, "off") || !strcmp(e, "0") || !*e)) dir[0] = 0;
        else if (e) snprintf(dir, sizeof dir, "%s", e);
        else if (s && *s) { snprintf(dir, sizeof dir, "%s", s); size_t n = strlen(dir); while (n > 1 && dir[n - 1] == '/') dir[--n] = 0;
            char *sl = strrchr(dir, '/'); if (sl) snprintf(sl + 1, sizeof dir - (size_t)(sl + 1 - dir), "glslc_play"); else snprintf(dir, sizeof dir, "glslc_play"); }
    }
    return dir[0] ? dir : NULL;
}

static void capture(const void *obj) {
    static const char *dir; static int init;
    if (!init) { init = 1; dir = getenv("DM_GLSLC_CAPTURE"); if (dir) { mkdir(dir, 0755); LOG("glslc: run-time compile outputs are saved to %s", dir); } }
    const uint8_t *const *res = *(const uint8_t *const *const *)obj;
    if (!res || !res[0] || !res[1] || !res[0][0xc] || res[0][0xd]) return;
    const uint8_t *out = res[1]; uint32_t n = *(const uint32_t *)(out + 0x44);
    if (*(const uint32_t *)out != 0x19866891 || n < 0x48 || n > (64u << 20)) { LOG("[RED] glslc: unknown output header (magic %#x length %#x), not saved", *(const uint32_t *)out, n); return; }
    uint64_t h = 0xcbf29ce484222325ull; for (uint32_t i = 0; i < n; i++) h = (h ^ out[i]) * 0x100000001b3ull;
    char path[1024];
    if (dir) {   // the NSP script's capture run: every output
        if (save(dir, h, out, n, path, sizeof path) > 0) LOG("glslc: saved a run-time compile output %s (%u bytes)", path, n);
        return;
    }
    static pthread_mutex_t mu = PTHREAD_MUTEX_INITIALIZER; static unsigned seen;   // the game may compile on several threads
    pthread_mutex_lock(&mu);
    if (glslc_known(h) == 1) { pthread_mutex_unlock(&mu); return; }   // in this build's shader tables
    const char *pd = play_dir(); int w = 0;
    if (pd) { mkdir(pd, 0755); w = save(pd, h, out, n, path, sizeof path); }
    unsigned k = ++seen;
    pthread_mutex_unlock(&mu);
    if (k == 1) LOG("[RED] glslc: the game compiled a shader that this build's shader map does not have (output %016llx, %u bytes): its draws are missing (shaders are translated offline only). %s",
                    (unsigned long long)h, n, pd ? "Such outputs are saved to glslc_play/ beside the save: put that folder into the NSP folder and build the app again" : "DM_GLSLC_PLAY=off: not saved");
    else if (k <= 64) LOG("glslc: shader output %016llx is not in the shader map either (%u so far this run)%s", (unsigned long long)h, k, w > 0 ? ", saved" : "");
    else if (k == 65) LOG("glslc: more outputs not in the shader map are saved without a line");
}

// The GPU code version the game's own GLSLC writes (glslcGetVersion returns GLSLCversion {apiMajor, apiMinor, gpuCodeVersionMajor, gpuCodeVersionMinor, package, …}, 0x34 bytes, through x8),
// 0 when the game carries no GLSLC. nvnDeviceGetInteger reports at least this as the driver's newest supported GPU code version (hle_nvn.c): a game's driver, in the same SDK, runs that code
int dm_glslc_gpu_code(int *major, int *minor) {
    static int v[2] = {-1, -1};
    if (v[0] < 0) {
        typedef struct { uint32_t w[16]; } glslc_version_t;
        glslc_version_t (*get)(void) = (glslc_version_t (*)(void))guest_sym("glslcGetVersion");
        v[0] = v[1] = 0;
        if (get) { glslc_version_t r = get(); v[0] = (int)r.w[2]; v[1] = (int)r.w[3]; LOG("glslc: GLSLC API %u.%u, GPU code version %d.%d", r.w[0], r.w[1], v[0], v[1]); }
    }
    *major = v[0]; *minor = v[1];
    return v[0] > 0;
}

HLE_FORCE("glslcCompile", "run-time GLSL compile (the game's own GLSLC compiles as usual; with DM_GLSLC_CAPTURE the outputs are saved to disk for offline translation, without it those the shader map lacks go to glslc_play/)", uint8_t, h_glslc_Compile, void *obj) {
    static uint8_t (*orig)(void *);
    if (!orig && !(orig = guest_sym("glslcCompile"))) die("glslcCompile missing");
    uint8_t ok = orig(obj);
    if (ok) capture(obj);   // DM_GLSLC_CAPTURE: every output; else those the shader map does not name, to glslc_play/
    return ok;
}
