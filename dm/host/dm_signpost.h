// os_signpost lanes for Instruments (DM_SIGNPOST=1): where each frame's time goes, in the os_signpost and Points of Interest instruments, beside Metal System Trace.
// Off by default. Off, each site is one load of dm_sp.on and a branch that is never taken: nothing is formatted, allocated or locked, no id is made, and the macros'
// arguments are not evaluated, so they must be plain reads (never a *_take(), an atomic_exchange or any call with a side effect), or the game would run differently
// with the switch on. Where <os/signpost.h> does not exist (the Linux parse check, a plain C11 build) every macro is a no-op.
// dm_sp_init() reads the switch once, from main.c host_preload (after iOS main.m has applied Documents/env.txt, before any graphics, encode, display-link or vsync
// thread starts, so a plain int needs no atomics). Unit tests never call it and run with signposts off.
// Names and formats must be string literals (os_signpost puts them in __TEXT,__oslogstring), hence macros. The subsystem, the categories and the names are an interface
// for saved Instruments templates: docs/development.md lists them and dm/tools/tests/test_signpost_wiring.py keeps the two in step.
#pragma once
#include <stdint.h>
#include <stdlib.h>

enum { DM_SP_POI, DM_SP_FRAME, DM_SP_GPU, DM_SP_DISPLAY, DM_SP_SHADERS, DM_SP_NLOG };
#define DM_SP_SUBSYSTEM "org.nintanium.host"
static inline int dm_sp_env_on(const char *v) { return v && v[0] == '1' && !v[1]; }   // only the exact value 1 turns it on: unset, 0 or anything else leaves it off

#if defined(__has_include) && !defined(DM_SP_NONE)   // DM_SP_NONE: build the no-op form even where os_signpost exists (t_signpost)
#if __has_include(<os/signpost.h>)
#define DM_SP_HAVE 1
#endif
#endif

#ifdef DM_SP_HAVE
#include <os/signpost.h>
typedef os_signpost_id_t dm_sp_id;
// One copy per image: hidden weak definitions coalesce at link time and are reached PC-relative. The handles are kept as void *: os_log_t is an ARC object type in
// Objective-C files and a plain pointer in C files, so a field of that type would differ between them
struct dm_sp_state { int on; void *log[DM_SP_NLOG]; };
__attribute__((weak, visibility("hidden"))) struct dm_sp_state dm_sp;
#if defined(__OBJC__) && defined(__has_feature)
#if __has_feature(objc_arc)
#define DM_SP_LOG(c) ((__bridge os_log_t)dm_sp.log[c])
#define DM_SP_KEEP(l) ((__bridge_retained void *)(l))
#endif
#endif
#ifndef DM_SP_LOG
#define DM_SP_LOG(c) ((os_log_t)dm_sp.log[c])
#define DM_SP_KEEP(l) ((void *)(l))
#endif
#define DM_SP_ON() __builtin_expect(dm_sp.on, 0)
#define DM_SP_EXCL OS_SIGNPOST_ID_EXCLUSIVE   // intervals of that name never overlap (one thread, or serialized by a lock)
#define DM_SP_ID(c) (DM_SP_ON() ? os_signpost_id_generate(DM_SP_LOG(c)) : OS_SIGNPOST_ID_NULL)   // a new id, for intervals that overlap or end on another thread
// os_signpost checks os_signpost_enabled() itself on every call (it changes when Instruments starts or stops recording), so it is not cached here
#define DM_SP_BEGIN(c, name, id, ...) do { if (DM_SP_ON()) os_signpost_interval_begin(DM_SP_LOG(c), (id), name, __VA_ARGS__); } while (0)
#define DM_SP_END(c, name, id, ...) do { if (DM_SP_ON()) os_signpost_interval_end(DM_SP_LOG(c), (id), name, __VA_ARGS__); } while (0)
#define DM_SP_EVENT(c, name, ...) do { if (DM_SP_ON()) os_signpost_event_emit(DM_SP_LOG(c), OS_SIGNPOST_ID_EXCLUSIVE, name, __VA_ARGS__); } while (0)
// 1 when DM_SIGNPOST=1 turned the lanes on (the caller logs it); handles are made once and never released
static inline int dm_sp_init(void) {
    if (dm_sp.on || !dm_sp_env_on(getenv("DM_SIGNPOST"))) return dm_sp.on;
    static const char *const cat[DM_SP_NLOG] = {OS_LOG_CATEGORY_POINTS_OF_INTEREST, "Frame", "GPU", "Display", "Shaders"};
    for (int i = 0; i < DM_SP_NLOG; i++) dm_sp.log[i] = DM_SP_KEEP(os_log_create(DM_SP_SUBSYSTEM, cat[i]));
    dm_sp.on = 1;
    return 1;
}
#else
// No os_signpost: nothing is emitted and no argument is evaluated (the call below sits in dead code, so the arguments are only type-checked and count as used)
typedef uint64_t dm_sp_id;
static inline void dm_sp_nop(int c, ...) { (void)c; }
#define DM_SP_ON() 0
#define DM_SP_EXCL ((dm_sp_id)0)
#define DM_SP_ID(c) ((void)sizeof(c), (dm_sp_id)0)
#define DM_SP_BEGIN(c, ...) do { if (0) dm_sp_nop((c), __VA_ARGS__); } while (0)
#define DM_SP_END(c, ...) do { if (0) dm_sp_nop((c), __VA_ARGS__); } while (0)
#define DM_SP_EVENT(c, ...) do { if (0) dm_sp_nop((c), __VA_ARGS__); } while (0)
static inline int dm_sp_init(void) { return 0; }
#endif
