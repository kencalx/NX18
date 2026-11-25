#import <GameController/GameController.h>
#import "DuoHarnessRuntime.h"
#include "dm.h"
#include "dm_input.h"
#include "haptics_apple.h"
#include "pad_switch2_apple.h"
#include "hle.h"
#include "touch_draw.h"
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

NSString * const DuoHarnessInputDidChangeNotification = @"DuoHarnessInputDidChange";

static pthread_mutex_t g_input_lock = PTHREAD_MUTEX_INITIALIZER;
static DuoHarnessState g_state;

DuoHarnessInput duo_harness_input(void) {
    pthread_mutex_lock(&g_input_lock);
    DuoHarnessInput value = g_state.input;
    pthread_mutex_unlock(&g_input_lock);
    return value;
}

DuoHarnessState duo_harness_state(void) {
    pthread_mutex_lock(&g_input_lock);
    DuoHarnessState value = g_state;
    pthread_mutex_unlock(&g_input_lock);
    return value;
}

void duo_harness_clear(void) {
    pthread_mutex_lock(&g_input_lock);
    memset(&g_state, 0, sizeof(g_state));
    pthread_mutex_unlock(&g_input_lock);
}

void dm_input_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    pthread_mutex_lock(&g_input_lock);
    g_state.input.buttons = buttons;
    g_state.input.lx = lx; g_state.input.ly = ly; g_state.input.rx = rx; g_state.input.ry = ry;
    pthread_mutex_unlock(&g_input_lock);
    [[NSNotificationCenter defaultCenter] postNotificationName:DuoHarnessInputDidChangeNotification object:nil];
}

void dm_touch_set(const dm_touch *touches, int count) {
    pthread_mutex_lock(&g_input_lock);
    g_state.input.touch_count = count > 16 ? 16 : count;
    g_state.input.touch_update_count++;
    memset(g_state.input.touches, 0, sizeof(g_state.input.touches));
    if (touches && g_state.input.touch_count > 0) memcpy(g_state.input.touches, touches, (size_t)g_state.input.touch_count * sizeof(*touches));
    if (touches && g_state.input.touch_count > 0) {
        g_state.input.last_touch_count = g_state.input.touch_count;
        memset(g_state.input.last_touches, 0, sizeof(g_state.input.last_touches));
        memcpy(g_state.input.last_touches, touches, (size_t)g_state.input.touch_count * sizeof(*touches));
    }
    pthread_mutex_unlock(&g_input_lock);
    [[NSNotificationCenter defaultCenter] postNotificationName:DuoHarnessInputDidChangeNotification object:nil];
}

void dm_pad_set(uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    dm_pad_set_player(0, buttons, lx, ly, rx, ry);
}

void dm_pad_set_player(int player, uint64_t buttons, int32_t lx, int32_t ly, int32_t rx, int32_t ry) {
    if (player < 0 || player >= DM_PLAYERS) return;
    pthread_mutex_lock(&g_input_lock);
    g_state.players[player] = (DuoHarnessPlayerInput){buttons, lx, ly, rx, ry};
    pthread_mutex_unlock(&g_input_lock);
}

void dm_pad_players(uint32_t mask) {
    pthread_mutex_lock(&g_input_lock);
    g_state.connected_players = mask;
    pthread_mutex_unlock(&g_input_lock);
}

void dm_motion_set(int player, const float acceleration[3], const float rotation[3]) {
    if (player < 0 || player >= DM_PLAYERS || !acceleration || !rotation) return;
    pthread_mutex_lock(&g_input_lock);
    memcpy(g_state.controller_motion[player].acceleration, acceleration, sizeof(g_state.controller_motion[player].acceleration));
    memcpy(g_state.controller_motion[player].rotation, rotation, sizeof(g_state.controller_motion[player].rotation));
    g_state.controller_motion_mask |= 1u << player;
    pthread_mutex_unlock(&g_input_lock);
}

void dm_motion_set_switch(int player, const float acceleration[3], const float rotation[3]) {
    (void)player; (void)acceleration; (void)rotation;
}

void dm_motion_clear(int player) {
    if (player < 0 || player >= DM_PLAYERS) return;
    pthread_mutex_lock(&g_input_lock);
    memset(&g_state.controller_motion[player], 0, sizeof(g_state.controller_motion[player]));
    g_state.controller_motion_mask &= ~(1u << player);
    pthread_mutex_unlock(&g_input_lock);
}

uint32_t dm_player_npad(int player) { return player == 0 ? 0x20 : (uint32_t)player; }

static int g_opmode;   // handheld, until a test or the in-game menu docks it
int dm_opmode(void) { return g_opmode; }
void dm_set_opmode(int mode) { g_opmode = mode; }
static int g_rumble = 1;
void dm_haptics_set_enabled(int on) { g_rumble = on; }
int duo_harness_rumble(void) { return g_rumble; }
void dm_haptics_apple_init(void) {}
void dm_haptics_apple_controller(int player, GCController *controller) { (void)player; (void)controller; }
void dm_haptics_apple_set_sink(int player, void (*sink)(const dm_haptic_state *state)) { (void)player; (void)sink; }
// Switch 2 controllers over Bluetooth (pad_switch2_apple.m, which the app builds from the host's sources): off in the harness, which has no Bluetooth
int dm_switch2_start(const dm_switch2_front *front) { (void)front; return 0; }
void dm_switch2_active(int on) { (void)on; }
s2_pad *dm_switch2_pads(void) { return NULL; }
void dm_switch2_rumble(const dm_haptic_state *state) { (void)state; }

int front_ios_boot_ok(void) { return 1; }
void front_ios_boot(void) {}
// dm_show_launcher is the real one (Launcher.swift): without a launcher list (DM_APP_DM unset, no dm/launcher.json in the harness) it returns false and the game starts

uint64_t g_t0_ns;
uint64_t now_ns(void) { return 1; }
uint64_t mtl_present_count(void) { return 0; }
static int g_present_stretch;   // what the front end last told the present (Picture Stretch)
void mtl_present_stretch(int on) { g_present_stretch = on; }
int duo_harness_present_stretch(void) { return g_present_stretch; }
void mtl_present_upscale_set(const char *mode) { (void)mode; }   // the in-game menu's Upscaling (nvn_mtl.m): no present in the harness
void mtl_present_sharpen_set(const char *level) { (void)level; }   // the in-game menu's Sharpening (nvn_mtl.m): no present in the harness
void mtl_present_aa_set(const char *mode) { (void)mode; }   // the in-game menu's Anti-aliasing (nvn_mtl.m): no present in the harness
static int g_present_why[3];   // what the live present last did with Upscaling, Sharpening and Anti-aliasing (nvn_mtl.m, front.h): a test sets it (duo_harness_set_present_why)
int mtl_present_fx_why(void) { return g_present_why[0]; }
int mtl_present_sharp_why(void) { return g_present_why[1]; }
int mtl_present_aa_why(void) { return g_present_why[2]; }
void duo_harness_set_present_why(int fx, int sharp, int aa) { g_present_why[0] = fx; g_present_why[1] = sharp; g_present_why[2] = aa; }
static int g_web_touch;   // whether an offline HTML page is shown over the picture (web_apple.m is not in the harness)
int front_web_touch(void) { return g_web_touch; }
void front_web_shown(void);   // front_ios.m: the root lays out again (web_apple.m calls it at each change)
void duo_harness_set_web_touch(int on) { if (g_web_touch == on) return; g_web_touch = on; front_web_shown(); }
void dm_camera_aspect_screen(float ratio) { (void)ratio; }   // Ultrawide's camera (loader.c): no game in the harness
void dm_low_power_cap_set(int on) { (void)on; }   // the in-game menu's Low Power Mode at 30 fps (hle_nvn.c): no frame cap in the harness
int dm_power_detail_on(void) { return 0; }
// Vitals' figures (hle_nvn.c publishes them from the present thread): a test sets one window (duo_harness_set_vitals); now_ns is 1 here, so a window stamped 1 is fresh
#include "nvn_vitals.h"
static nvn_vitals g_duo_vitals; static int g_duo_vitals_level, g_duo_vitals_menu;
void duo_harness_set_vitals(int fps, int cpu_mw, int capped);
int dm_vitals_read(nvn_vitals *out) {   // DUO_VITALS=1 (screenshots): a steady 60 fps at 2.1 W until a test sets its own
    if (!g_duo_vitals.stamp_ns && getenv("DUO_VITALS") && atoi(getenv("DUO_VITALS"))) duo_harness_set_vitals(60, 2140, 0);
    *out = g_duo_vitals; return 1;
}
void dm_vitals_level_set(int level) { g_duo_vitals_level = level; }
void dm_vitals_menu_set(int open) { g_duo_vitals_menu = open; }
int duo_harness_vitals_level(void) { return g_duo_vitals_level; }
int duo_harness_vitals_menu(void) { return g_duo_vitals_menu; }
void duo_harness_set_vitals(int fps, int cpu_mw, int capped) { g_duo_vitals = (nvn_vitals){.stamp_ns = 1, .cpu_mw = cpu_mw, .pshare_pm = 820, .gpu_busy_pm = 640, .fps10 = fps * 10, .max_gap_100us = 330, .capped = (int8_t)capped}; }
static uint64_t g_duo_saved;
uint64_t dm_fs_last_commit_ns(void) { return g_duo_saved; }
void duo_harness_set_saved_ns(uint64_t ns) { g_duo_saved = ns; }   // the power detail line (hle_nvn.c): no power line in the harness, so no battery monitoring either
// The cheats GameMenu.swift lists (hle_cheats.c): no cheats folder in the harness, so the in-game menu has no Cheats submenu; DUO_CHEATS=1 gives it a placeholder cheat file
// (made-up names, for screenshots of the Cheats page): two sections, a cheat that runs once, one that cannot run here and an always-on master, toggled in memory
typedef struct { const char *name, *section, *why; int kind, flags, on; } DuoCheat;
static DuoCheat g_duo_cheats[] = {
    {"Master code", "", "", 1, 0, 1},
    {"Placeholder: infinite health", "Player", "", 0, 0, 1},
    {"Placeholder: moon jump", "Player", "", 0, 0, 0},
    {"Placeholder: refill items", "Player", "", 0, 32, 0},
    {"Placeholder: timer frozen", "World", "", 0, 0, 0},
    {"Placeholder: code patch", "World", "(rewrites code: Mac only)", 2, 0, 0},
};
static int g_duo_cheats_master = 1;
static int duo_cheats(void) { const char *c = getenv("DUO_CHEATS"); return c && atoi(c) != 0; }
static int duo_cheat_ok(int i) { return duo_cheats() && i >= 0 && i < (int)(sizeof g_duo_cheats / sizeof g_duo_cheats[0]); }
int dm_cheats_found(void) { return duo_cheats(); }
int dm_cheats_ncheats(void) { return duo_cheats() ? (int)(sizeof g_duo_cheats / sizeof g_duo_cheats[0]) : 0; }
const char *dm_cheats_build(void) { return duo_cheats() ? "0123456789ABCDEF" : ""; }
const char *dm_cheats_version(void) { return duo_cheats() ? "1.0.0" : ""; }
const char *dm_cheats_dir_path(void) { return duo_cheats() ? "/duo/cheats" : ""; }
int dm_cheats_nothers(void) { return 0; }
const char *dm_cheat_name_at(int i) { return duo_cheat_ok(i) ? g_duo_cheats[i].name : ""; }
const char *dm_cheat_why_at(int i) { return duo_cheat_ok(i) ? g_duo_cheats[i].why : ""; }
const char *dm_cheat_section_at(int i) { return duo_cheat_ok(i) ? g_duo_cheats[i].section : ""; }
int dm_cheat_kind_at(int i) { return duo_cheat_ok(i) ? g_duo_cheats[i].kind : 2; }
int dm_cheat_flags_at(int i) { return duo_cheat_ok(i) ? g_duo_cheats[i].flags : 0; }
int dm_cheat_on_at(int i) { return duo_cheat_ok(i) ? g_duo_cheats[i].on : 0; }
void dm_cheat_toggle(int i) { if (duo_cheat_ok(i) && !(g_duo_cheats[i].flags & 32)) g_duo_cheats[i].on = !g_duo_cheats[i].on; }
void dm_cheats_reload(void) {}
int dm_gfx_capture(const char *path, void (*done)(void *ctx, const char *path, int ok), void *ctx) { (void)path; (void)done; (void)ctx; return 0; }   // no game picture in the harness
int dm_cheats_master(void) { return g_duo_cheats_master; }
void dm_cheats_master_set(int on) { g_duo_cheats_master = on; }
__thread _Atomic int dm_host_work;
void dm_gfx_suspend(int on) { (void)on; }
void dm_gfx_inactive(int on) { (void)on; }   // the bundled pipeline archive's crash guard (hle_nvn.c): no archive in the harness
void dm_gfx_pressure(int level) { (void)level; }   // front_ios.m's memory pressure source
void dm_heat_poke(void) {}   // hle_nvn.c: the heat ladder's thermal-state poke (front_ios.m's notification); no heat ladder in the harness
void dm_heat_timer_tick(void) {}   // hle_nvn.c: the heat ladder's 1 s timer (front_ios.m); nothing to sample in the harness
int dm_gfx_save_wait(int wait_ms) { (void)wait_ms; return 1; }
void dm_audio_suspend(int on) { (void)on; }
void dm_audio_reset(void) {}
void dm_movie_active(int active) { (void)active; }   // front_ios.m: a movie decoder iOS ended waits for the app to be active again (hle_movie_vt.h); no movies here
void dm_audio_route_change(const char *why, int changed) { (void)why; (void)changed; }
int dm_audio_io_ms(void) { return 0; }   // DM_AUDIO_IO_MS unset (audio_io.h)
void dm_audio_io_granted(double seconds) { (void)seconds; }
uint32_t dm_audio_io_frames(void) { return 0; }
void dm_focus_set(int state) { (void)state; }
static int g_front_menu;   // hle_oe.c's front-end menu state, as DmGamepad.m last reported it (dm_front_menu_set: its log line and the long-frame tag)
void dm_front_menu_set(int open, const char *where) { (void)where; g_front_menu = open != 0; }
int duo_harness_front_menu(void) { return g_front_menu; }
void guest_clock_freeze_for(int reason, int on) { (void)reason; (void)on; }
void dm_stall_menu(int open) { (void)open; }   // the freeze detector (stall.c), which DmGamepad.m holds off while the in-game menu is open: no presents and no detector in the harness
const char *front_ios_boot_message(void) { return NULL; }
const char *front_ios_device_check(void) { return NULL; }   // a supported GPU
bool front_ios_hud_enabled_from_saved_choice(void) { return false; }   // main.m: no saved Performance HUD choice turned the HUD on at launch
const char *dm_save_title(void) { return "0100D0D0D0D0E000"; }   // hle_fs.c's, from the game's profile: the title ID the cloud file is named after (save_sync.c, compiled here, has save_sync_flush)
int dm_players_reported(void) { return __builtin_popcount(duo_harness_state().connected_players | 1u); }   // hle_hid.c: DmGamepad.m asks for the player count (the controller prompt's joined count); player 1 always, as the touch gamepad
// The touch controls drawn into the frame (nvn_mtl.m, touch_draw.h): no present in the harness, so the last frame and atlas the gamepad handed over are kept for the tests
static touch_frame g_touch_frame; static int g_touch_frames;
static NSData *g_touch_atlas; static int g_touch_atlas_w, g_touch_atlas_h, g_touch_atlas_channels; static uint32_t g_touch_atlas_gen;
static touch_box g_touch_box_h; static uint32_t g_touch_seq_h, g_touch_ack_h; static int g_touch_releases; static uint64_t g_touch_idle = UINT64_MAX;
uint32_t mtl_present_touch(const touch_frame *f) { g_touch_frame = *f; g_touch_frames++; return g_touch_seq_h = touch_publish(&g_touch_box_h, f); }   // the sequence as the present's box gives it
void mtl_present_touch_ack(uint32_t seq) { g_touch_ack_h = seq; }
void mtl_present_touch_release(void) { g_touch_releases++; g_touch_atlas = nil; g_touch_atlas_gen = 0; }
uint64_t mtl_present_touch_idle_ns(void) { return g_touch_idle; }
void duo_harness_set_present_idle(uint64_t ns) { g_touch_idle = ns; }
int duo_harness_touch_releases(void) { return g_touch_releases; }
int duo_harness_present_draws(void) {   // as nvn_mtl.m's present_now completing a live present that drew the last frame: the front end hears of it once per request (front_touch_drawn)
    g_touch_idle = 0;
    if (g_touch_frame.on != TOUCH_ON || !g_touch_frame.n || !g_touch_atlas || g_touch_frame.atlas != g_touch_atlas_gen) return 0;
    if (!g_touch_ack_h || !touch_seq_since(g_touch_seq_h, g_touch_ack_h)) return 0;
    g_touch_ack_h = 0; front_touch_drawn(g_touch_seq_h); return 1;
}
int mtl_present_touch_atlas(const void *px, int w, int h, size_t row, int channels, uint32_t gen) {   // kept as BGRA (a grey and alpha atlas expanded, as fs_touch_grey does)
    NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)w * h * 4]; uint8_t *o = d.mutableBytes;
    for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        const uint8_t *p = (const uint8_t *)px + (size_t)y * row + (size_t)x * channels; uint8_t *q = o + ((size_t)y * w + x) * 4;
        if (channels == 2) { q[0] = q[1] = q[2] = p[0]; q[3] = p[1]; } else memcpy(q, p, 4);
    }
    g_touch_atlas_channels = channels;
    g_touch_atlas = d; g_touch_atlas_w = w; g_touch_atlas_h = h; g_touch_atlas_gen = gen; return 1;
}
int duo_harness_touch_frame(touch_frame *f) { if (f) *f = g_touch_frame; return g_touch_frames; }
int duo_harness_touch_atlas_channels(void) { return g_touch_atlas_channels; }
const uint8_t *duo_harness_touch_atlas(int *w, int *h, uint32_t *gen) { if (w) *w = g_touch_atlas_w; if (h) *h = g_touch_atlas_h; if (gen) *gen = g_touch_atlas_gen; return g_touch_atlas.bytes; }
// The GPU-lost path front_ios.m now links (front_gpu_lost): the harness never loses its GPU
int mtl_gpu_lost_why(void) { return 0; }
void dm_host_shutdown(const char *why) { (void)why; }
