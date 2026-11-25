// Programs resolved before the game changes the depth mode (nvnDeviceSetDepthMode) are resolved again at their next use (nvn_mtl.m shader_depth_stale, prog_get_ptr, bind_rebuild;
// S2Arm 8df8cbe7, Apache-2.0, whose t_depth_reresolve cases these are, on this tree's borrowed prog_get_ptr). A game that set near=0 after about 157 vertex shaders kept their GL
// entry points, so characters and terrain fell outside the depth range. Expected values are by hand:
// - With the mode unchanged a program resolves to the same object twice. Once the mode changes, it resolves to a new one that no longer holds the old mode's vertex shader, which the
//   serial table now gives, and a second look gives that same new one.
// - A combined program (bind_stages: vertex from one program, fragment from another) is put together again from its stages' programs, keeping the fragment program's shader, not
//   resolved as an empty program of its own.
// - A shader loaded under the old mode is not handed out by the shader cache again (shader_get); it is kept for the process (pipelines may still name it).
// The fixtures' vertex shaders are made by hand, loaded under mode 0; the shader map is empty, so a program resolved again has no shaders of its own.
#define nvn_game_fps nvn_game_fps_mtl_default
#include "../nvn/nvn_mtl.m"
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
uint64_t g_t0_ns;
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)

static NvShader *vs_mode0(void) { NvShader *s = [NvShader new]; s->stage = 0; s->depth_moded = 1; s->load_z = 0; strlcpy(s->key, "00000000deadbeef_b", sizeof s->key); return s; }

int main(void) { @autoreleasepool {
    char map[] = "/tmp/t_depth_reresolve_XXXXXX"; int fd = mkstemp(map); if (fd < 0) abort(); close(fd);   // an empty shader map
    setenv("DM_NVN_SHMAP", map, 1);
    state_reset(); mtl_set_depth_zero(0);
    static prog_t p, v, f;
    p.magic = v.magic = f.magic = MAGIC('P', 'R', 'O', 'G');
    p.serial = nvn_new_serial(); v.serial = nvn_new_serial(); f.serial = nvn_new_serial();
    NvShader *vs0 = vs_mode0(), *fs = [NvShader new]; fs->stage = 1;
    { NvProg *o = [NvProg new]; o->sh[0] = vs0; serial_put(p.serial, o); }
    { NvProg *o = [NvProg new]; o->sh[0] = vs0; serial_put(v.serial, o); }
    { NvProg *o = [NvProg new]; o->sh[1] = fs; serial_put(f.serial, o); }
    NvProg *a = prog_get(&p), *a2 = prog_get(&p);
    CHECK(a && a == a2 && a->sh[0] == vs0, "mode unchanged: the same program twice");
    S.bst[0] = &v; S.bst[1] = NULL; const prog_t *c = bind_stages(&f, 2);
    NvProg *ca = c ? prog_get(c) : nil;
    CHECK(c && c != &v && c != &f && ca && ca->sh[0] == vs0 && ca->sh[1] == fs, "a combined program: vertex from v, fragment from f");
    g_shcache = [NSMutableDictionary dictionary]; g_shcache[@"00000000deadbeef_b"] = vs0;
    CHECK(shader_get(@"00000000deadbeef_b", 0) == vs0, "the shader cache gives the shader while the mode stands");
    mtl_set_depth_zero(1);
    NvProg *b = prog_get(&p);
    CHECK(b && b != a && b->sh[0] != vs0, "mode changed: resolved again, without the old mode's vertex shader");
    CHECK(serial_get(p.serial) == b, "  the serial table gives the new one");
    CHECK(prog_get(&p) == b, "  a second look: the same new one, not resolved again");
    NvProg *cb = prog_get(c);
    CHECK(cb && cb != ca && cb->sh[1] == fs && cb->sh[0] != vs0, "the combined program put together again: the fragment program's shader kept, the old vertex shader gone");
    CHECK(prog_get(c) == cb, "  a second look: the same one");
    CHECK(shader_get(@"00000000deadbeef_b", 0) != vs0, "the shader cache no longer gives the old mode's shader");
    CHECK(g_sh_stale && [g_sh_stale containsObject:vs0], "  it is kept for the process");
    mtl_set_depth_zero(0);
    NvShader *vs1 = vs_mode0();   // loaded under mode 0 again, as the game's mode is now
    { NvProg *o = [NvProg new]; o->sh[0] = vs1; serial_put(p.serial, o); }
    NvProg *d = prog_get(&p);
    CHECK(d && d->sh[0] == vs1 && prog_get(&p) == d, "back to mode 0: a program of mode 0's shader stands");
    unlink(map);
    printf("t_depth_reresolve: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
