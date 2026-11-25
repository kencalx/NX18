// HLE common: register host implementations by Switch mangled name.
// Note the differences between Apple AAPCS64 and Switch: Apple requires the caller to extend <32-bit arguments (bool/char/short), Switch code does not extend ⇒
// such parameters are always declared as int/unsigned and truncated by ourselves. Variadic arguments go on the stack on Apple and in registers on Switch ⇒ variadic functions cannot use C's "..." directly.
#pragma once
#include "dm.h"
#include <stddef.h>
typedef struct { const char *name; void *fn; } hle_ent;
#define HLE(mangled, ret, cname, ...)                                                             \
    static ret cname(__VA_ARGS__);                                                                \
    __attribute__((used, section("__DATA,swhle"))) static const hle_ent hle_ent_##cname = {mangled, (void *)cname}; \
    static ret cname(__VA_ARGS__)

typedef uint32_t Result;   // nn::Result: w0, 0 = success
#define RES_OK 0u
#define RES_FAIL 0x2A2u      // Generic failure (cut features such as networking uniformly return this)

// Guest address → host object side table
void *objmap_get(const void *guest);
void objmap_put(const void *guest, void *host);
void *objmap_del(const void *guest);
uint64_t now_ns(void);
// A blocking native HLE wait releases the guest core. With the condition mutex
// held, enter with 1 before waiting and balance with 0 after reacquiring it.
void dm_thread_native_wait(int entering);
void dm_thread_display_wait(int entering);   // the window texture's acquire waits for the display: 1 before the wait, 0 after (hle_thread.c; hle_nvn.c nvnWindowAcquireTexture)
void dm_thread_gpu_wait(int entering);       // the game's nvnQueueFinish / nvnSyncWait waits for the GPU: 1 before the wait, 0 after (hle_thread.c; hle_nvn.c)
void dm_thread_service_connect(void);   // an HLE call that stands for connecting to a service on Horizon: threads started so far get to run (hle_thread.c)
void dm_thread_service_request(void);   // an HLE call that is a blocking service request on Horizon: the caller gives up its core (hle_thread.c)
uint64_t guest_ns(void);              // Guest clock (hle_os.c; does not advance while frozen, guest_clock_freeze)
int dm_detclock_enabled(void);
uint64_t dm_guest_frame(void);        // Incremented each time the host presents a frame; unaffected by machine load
void guest_clock_freeze(int on);
void dm_movie_active(int active);   // iOS movie decoder recovery waits for activation
void guest_clock_freeze_for(int reason, int on);   // Freeze by reason (0 tick hold, 1 background, 2 system keyboard, 3 NVN prepare, 4 NVN archive init); see hle_os.c
void guest_clock_read_wait(void);     // A guest read of the system counter: counts it in dm_clock_reads and waits while backgrounded or preparing (hle_os.c)
extern __thread uint64_t dm_clock_reads;   // the calling thread's guest reads of the system counter (hle_os.c; thr_yield tells clock waits by them)

// Forced takeover: even if the SDK module has a definition, all references to that symbol at load time (JUMP_SLOT/GLOB_DAT/ABS64) are resolved to the host implementation.
// Used only for the service-layer nn:: (service clients of fs/oe/aoc/pctl...); the SDK's libc++ and nn::os internals do not go into this table.
// Every entry must state the reason for the takeover; an entry in the table that no module references makes loading report a failure and abort (a wrong list must fail loudly).
typedef struct { const char *name; void *fn; const char *why; const char *to; } hle_force_ent;   // to: a guest alias (HLE_FORCE_ALIAS below), fn NULL
#define HLE_FORCE(mangled, why, ret, cname, ...)                                                   \
    static ret cname(__VA_ARGS__);                                                                \
    __attribute__((used, section("__DATA,swforce"))) static const hle_force_ent hle_force_##cname = {mangled, (void *)cname, why}; \
    static ret cname(__VA_ARGS__)
// Same as above, but the implementation runs on this thread's big host stack (hle_bigstack.c): what is registered is a stub generated at compile time (the implementation's address goes into x16, then a jump to dm_bigstack_enter).
// For take-overs with large stack use (the file system sizes its buffers by PATH_MAX): a game thread's stack can be as small as 8 KB. Only register arguments are carried over (<= 8 integer, <= 8 floating point); not for variadic functions
#define HLE_FORCE_BIG(mangled, why, ret, cname, ...)                                               \
    static ret cname(__VA_ARGS__) __attribute__((used));                                          \
    extern const char cname##_bs[];                                                               \
    __asm__(".text\n.p2align 2\n.globl _" #cname "_bs\n.private_extern _" #cname "_bs\n_" #cname "_bs:\n" \
            "    adrp x16, _" #cname "@PAGE\n    add x16, x16, _" #cname "@PAGEOFF\n    b _dm_bigstack_enter\n"); \
    __attribute__((used, section("__DATA,swforce"))) static const hle_force_ent hle_force_##cname = {mangled, (void *)(uintptr_t)cname##_bs, why}; \
    static ret cname(__VA_ARGS__)
// A guest alias: every reference to mangled binds to the loaded modules' own definition of target instead, as if the module had imported target. No host code runs and no
// signature is restated, so the alias holds for every SDK that defines both. For a hardware class whose constructor the host takes over to build the SDK's software class in the
// same memory: its members, called directly rather than through the vtable, go to the software class's members of the same signature (hle_codec.c). A target no loaded module
// defines leaves the reference bound as it would be without the entry, with a red line; a target that is itself taken over stops loading (force_init)
#define HLE_FORCE_ALIAS(mangled, target, why) HLE_FORCE_ALIAS_(mangled, target, why, __COUNTER__)
#define HLE_FORCE_ALIAS_(mangled, target, why, n) HLE_FORCE_ALIAS__(mangled, target, why, n)
#define HLE_FORCE_ALIAS__(mangled, target, why, n) \
    __attribute__((used, section("__DATA,swforce"))) static const hle_force_ent hle_force_alias_##n = {mangled, NULL, why, target}
// The game's call site inside a HLE_FORCE_BIG implementation: pass __builtin_return_address(0), which after a stack switch is the entry's own (hle_bigstack.c)
void *dm_bigstack_caller(void *ra);

// Operation mode (0 handheld / 1 docked): owned by hle_oe.c, and the hid controller style follows it; the front end can switch it at runtime
int dm_opmode(void);
void dm_set_opmode(int m);          // On change, push notification 30 / 31 according to the switches the game has turned on
void dm_hid_opmode_changed(void);   // hle_hid.c: the npads follow the console mode; signals the style event of each npad whose style changed
// Focus (1 foreground / 2 focus lost / 3 background): called by the front end on lifecycle changes; a change pushes notification 15
void dm_focus_set(int st);
// Library applet stand-ins (controller, keyboard, error, Mii, account, shop): on Horizon the applet takes the application's focus until it closes, and the Show call returns after
// that. DM_APPLET("name"); first in the stand-in's body holds the game out of focus until the body returns, notifying 15 on the way in and out (hle_oe.c). Not for stand-ins that
// report the applet could not start (RES_FAIL cuts): those never had an applet open
void dm_applet_enter(const char *name);
void dm_applet_leave(void);
static inline void dm_applet_leave_(const char *const *name) { (void)name; dm_applet_leave(); }
#define DM_APPLET(name) const char *const dm_applet_ __attribute__((cleanup(dm_applet_leave_))) = (name); dm_applet_enter(dm_applet_)
// Audio pause / resume following the lifecycle (called by the front end on going to background / returning to foreground)
extern uint8_t *dm_fps_state;   // frame step state page (loader.c install_fps_state): +0 float target fps, +4 movie flag (dm_movie_playing, written by the host at each present: Tears of the Kingdom's step stub caps its first, undecided steps by it), +0x10 float render scale, +0x18 double game seconds stepped; NULL when the build has none
extern int dm_fps_step_max;   // loader.c: the largest step the frame step stubs give the game (patch_nso.py ctx.step_max; 0 = FSTEP_MAX)
int dm_movie_playing(void);   // hle_movie.c: a video decoder of the SDK's movie library handed out a picture in the last half second (the frame step then holds 30 fps, or its fastest hold for a movie above 30: dm_movie_fps)
int dm_movie_fps(void);       // hle_movie.c: the playing movie's pictures a second (0 = none playing, or not known: the movie::Decoder path's, the Switch's 30)
void dm_movie_picture(uint64_t interval_ns);   // hle_movie.c: a video decoder handed out a picture now; interval_ns its stream's picture interval (0 = not known)
void dm_movie_stopped(void);  // hle_movie.c: the video decoder stopped or went away: the movie signal drops at once
void dm_audio_suspend(int on);
uint64_t dm_audio_render_calls(void);   // Cumulative sound card callback count (the silent sink is not counted)
void dm_audio_reset(void);   // iOS media services reset: recreate the AudioUnits (hle_audio.c)
// nn::audio::AudioOutBuffer in the SDK's own layout, the audout service's buffer format (the same from SDK 8 to Switch 2's). The game fills and reads it through the SDK's own
// descriptor functions, which the host leaves to the sdk: SetAudioOutBufferInfo stores the data at +0x08, the buffer size at +0x10 and the data size at +0x18, the getters load the
// same offsets, and AudioBufferList links buffers through next (Hades's sdk+0x142ab0..0x142ae0). hle_audio.c's AudioOut queues and plays these; hle_audren.c hands it its rendered
// blocks in the same form. Until 2026-11 the host took three of those functions over to keep a private 24-byte layout, and the ones it left read it wrong (docs/reference/audio.md)
typedef struct { void *next; void *ptr; uint64_t cap, size, offset; } aout_buf;   // next, data, buffer_size, data_size, data_offset
_Static_assert(sizeof(aout_buf) == 40 && offsetof(aout_buf, ptr) == 0x08 && offsetof(aout_buf, cap) == 0x10 && offsetof(aout_buf, size) == 0x18 && offsetof(aout_buf, offset) == 0x20,
               "nn::audio::AudioOutBuffer layout");
void dm_audio_route_change(const char *why, int changed);   // iOS audio route change: restart the playing outputs on the new route when changed (hle_audio.c; the Mac follows its unit's CurrentDevice itself)
void dm_audio_route_changed(void);   // the output route changed: recreate units whose route-dependent channel count changed (hle_audio.c)
int dm_audio_output_channels(void);   // the output route: 6 when the device takes six channels, else 2 (hle_audio.c); reads the device on a host stack
int dm_audio_route(void);             // cached route, initialized on the calling host stack (hle_audio.c)
// In-process DeviceSink PCM: L R C LFE Ls Rs, followed by the stereo fold made before clamping/resampling.
// Both representations stay queued together; a device route change selects one without losing the original mix.
enum { DM_AUDIO_SINK_CHANNELS = 8 };
void *dm_pcmout_open_sink(void);
void dm_audio_device_changed(void);   // signal the game's bound output-device notifications (hle_audren.c)
