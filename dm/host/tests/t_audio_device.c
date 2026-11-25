// Mac device buffer contract: drive the real setup/listener/close paths with Core Audio property notifications,
// including synchronous format notifications from a buffer write and device removal during disposal. No hardware needed.
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <stddef.h>
#include <sched.h>
#include <time.h>

static AudioComponent mock_find(AudioComponent, const AudioComponentDescription *);
static OSStatus mock_new(AudioComponent, AudioComponentInstance *);
static OSStatus mock_get(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, void *, UInt32 *);
static OSStatus mock_set(AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement, const void *, UInt32);
static OSStatus mock_add(AudioUnit, AudioUnitPropertyID, AudioUnitPropertyListenerProc, void *);
static OSStatus mock_remove(AudioUnit, AudioUnitPropertyID, AudioUnitPropertyListenerProc, void *);
static OSStatus mock_init(AudioUnit);
static OSStatus mock_start(AudioUnit);
static OSStatus mock_stop(AudioUnit);
static OSStatus mock_uninit(AudioUnit);
static OSStatus mock_dispose(AudioComponentInstance);
#define AudioComponentFindNext mock_find
#define AudioComponentInstanceNew mock_new
#define AudioUnitGetProperty mock_get
#define AudioUnitSetProperty mock_set
#define AudioUnitAddPropertyListener mock_add
#define AudioUnitRemovePropertyListenerWithUserData mock_remove
#define AudioUnitInitialize mock_init
#define AudioOutputUnitStart mock_start
#define AudioOutputUnitStop mock_stop
#define AudioUnitUninitialize mock_uninit
#define AudioComponentInstanceDispose mock_dispose
static OSStatus mock_aogpd(AudioObjectID id, const AudioObjectPropertyAddress *pa, UInt32 q, const void *qd, UInt32 *sz, void *data);
#define AudioObjectGetPropertyData mock_aogpd
static OSStatus mock_aogpds(AudioObjectID, const AudioObjectPropertyAddress *, UInt32, const void *, UInt32 *);
#define AudioObjectGetPropertyDataSize mock_aogpds
static AudioObjectPropertyListenerProc system_route_listener, device_route_listener;
static OSStatus mock_route_add(AudioObjectID id, const AudioObjectPropertyAddress *pa, AudioObjectPropertyListenerProc cb, void *ctx) {
    assert(!ctx);
    if (id == kAudioObjectSystemObject) { assert(pa->mSelector == kAudioHardwarePropertyDefaultOutputDevice); system_route_listener = cb; }
    else { assert(pa->mSelector == kAudioDevicePropertyStreamFormat); device_route_listener = cb; }
    return noErr;
}
static OSStatus mock_route_remove(AudioObjectID id, const AudioObjectPropertyAddress *pa, AudioObjectPropertyListenerProc cb, void *ctx) {
    (void)id; (void)pa; (void)cb; (void)ctx; device_route_listener = NULL; return noErr;
}
#define AudioObjectAddPropertyListener mock_route_add
#define AudioObjectRemovePropertyListener mock_route_remove
#include "../hle_audio.c"
__thread _Atomic int dm_host_work;   // defined by the graphics host in a full build

static struct {
    AudioDeviceID device;
    Float64 rate;
    AudioValueRange range;
    UInt32 frames;
    AudioUnitPropertyListenerProc device_listener, format_listener;
    unsigned writes, disposals, input_formats;
    OSStatus init_error;
    int route_ch;                        // the device's output stream format channels (the route)
    int format_ch;                       // channels of the unit's input format, as last set
    AudioChannelLayoutTag layout_tag;    // the unit's input channel layout, as last set (0: none)
} unit;
static AudioUnit fake_au(void) { return (AudioUnit)&unit; }
static int check_open_publication;
static void changed(AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el) {
    AudioUnitPropertyListenerProc cb = id == kAudioOutputUnitProperty_CurrentDevice ? unit.device_listener : unit.format_listener;
    if (cb) cb(&unit, fake_au(), id, scope, el);
}
static AudioComponent mock_find(AudioComponent c, const AudioComponentDescription *d) {
    (void)c; assert(d->componentSubType == kAudioUnitSubType_DefaultOutput); return (AudioComponent)&unit;
}
static OSStatus mock_new(AudioComponent c, AudioComponentInstance *au) {
    if (check_open_publication) {
        // Lifecycle/watchdog readers must never find the output while its unit is being constructed.
        aout *pending = (aout *)((char *)au - offsetof(aout, au));
        pthread_mutex_lock(&g_aos_lock);
        for (int i = 0; i < AOMAX; i++) assert(g_aos[i] != pending);
        pthread_mutex_unlock(&g_aos_lock);
    }
    (void)c; assert(!unit.device_listener && !unit.format_listener); *au = fake_au(); return noErr;
}
static OSStatus mock_get(AudioUnit au, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, void *data, UInt32 *size) {
    assert(au == fake_au() && el == 0);
    if (id == kAudioOutputUnitProperty_CurrentDevice) {
        assert(scope == kAudioUnitScope_Global && *size == sizeof unit.device); memcpy(data, &unit.device, *size);
    } else if (id == kAudioUnitProperty_StreamFormat) {
        assert(scope == kAudioUnitScope_Output && *size == sizeof(AudioStreamBasicDescription));
        AudioStreamBasicDescription f = {.mSampleRate = unit.rate}; memcpy(data, &f, *size);
    } else if (id == kAudioDevicePropertyBufferFrameSizeRange) {
        assert(scope == kAudioUnitScope_Global && *size == sizeof unit.range); memcpy(data, &unit.range, *size);
    } else {
        assert(id == kAudioDevicePropertyBufferFrameSize && scope == kAudioUnitScope_Global && *size == sizeof unit.frames);
        memcpy(data, &unit.frames, *size);
    }
    return noErr;
}
static OSStatus mock_set(AudioUnit au, AudioUnitPropertyID id, AudioUnitScope scope, AudioUnitElement el, const void *data, UInt32 size) {
    assert(au == fake_au() && el == 0);
    if (id == kAudioDevicePropertyBufferFrameSize) {
        assert(unit.device && scope == kAudioUnitScope_Global && size == sizeof unit.frames);
        UInt32 frames; memcpy(&frames, data, size);
        assert(frames >= unit.range.mMinimum && frames <= unit.range.mMaximum);
        unit.frames = frames; assert(++unit.writes < 100);
        changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0); // must not recursively set the same buffer
    } else if (id == kAudioUnitProperty_StreamFormat) {
        const AudioStreamBasicDescription *f = data;
        assert(scope == kAudioUnitScope_Input && size == sizeof *f && f->mSampleRate == RATE && (f->mChannelsPerFrame == 1 || f->mChannelsPerFrame == 2 || f->mChannelsPerFrame == 6));
        assert(f->mBytesPerFrame == 2 * f->mChannelsPerFrame);
        unit.format_ch = (int)f->mChannelsPerFrame;
        unit.input_formats++; changed(id, scope, el); // the 48 kHz guest format is not the hardware rate
    } else if (id == kAudioUnitProperty_AudioChannelLayout) {
        assert(scope == kAudioUnitScope_Input && el == 0 && size == sizeof(AudioChannelLayout));
        unit.layout_tag = ((const AudioChannelLayout *)data)->mChannelLayoutTag;
    } else {
        assert(id == kAudioUnitProperty_SetRenderCallback && scope == kAudioUnitScope_Input && size == sizeof(AURenderCallbackStruct));
    }
    return noErr;
}
static OSStatus mock_add(AudioUnit au, AudioUnitPropertyID id, AudioUnitPropertyListenerProc cb, void *ctx) {
    assert(au == fake_au() && !ctx);
    if (id == kAudioOutputUnitProperty_CurrentDevice) unit.device_listener = cb;
    else { assert(id == kAudioUnitProperty_StreamFormat); unit.format_listener = cb; }
    return noErr;
}
static OSStatus mock_remove(AudioUnit au, AudioUnitPropertyID id, AudioUnitPropertyListenerProc cb, void *ctx) {
    assert(au == fake_au() && !ctx);
    if (id == kAudioOutputUnitProperty_CurrentDevice) { assert(unit.device_listener == cb); unit.device_listener = NULL; }
    else { assert(id == kAudioUnitProperty_StreamFormat && unit.format_listener == cb); unit.format_listener = NULL; }
    return noErr;
}
// The system's default output and its stream format (its output channels): the route the host reads. A system object, unlike the unit's CurrentDevice, which disposal clears
enum { SYS_OUT = 100 };
static OSStatus mock_aogpd(AudioObjectID id, const AudioObjectPropertyAddress *pa, UInt32 q, const void *qd, UInt32 *sz, void *data) {
    (void)q; (void)qd; (void)sz;
    if (pa->mSelector == kAudioHardwarePropertyDefaultOutputDevice) { assert(id == kAudioObjectSystemObject); *(AudioDeviceID *)data = SYS_OUT; return noErr; }
    if (pa->mSelector == kAudioDevicePropertyStreamFormat) {
        assert(id == SYS_OUT && pa->mScope == kAudioObjectPropertyScopeOutput);
        AudioStreamBasicDescription f = {.mChannelsPerFrame = (UInt32)unit.route_ch}; memcpy(data, &f, sizeof f); return noErr;
    }
    return kAudioHardwareUnknownPropertyError;   // no device name (DM_AUDIO_DEVICE is unset in this test)
}
static OSStatus mock_aogpds(AudioObjectID id, const AudioObjectPropertyAddress *pa, UInt32 q, const void *qd, UInt32 *sz) {
    (void)id; (void)pa; (void)q; (void)qd; (void)sz; return kAudioHardwareUnknownPropertyError;   // device lists: none (DM_AUDIO_DEVICE is unset here)
}
static OSStatus mock_init(AudioUnit au) { assert(au == fake_au()); return unit.init_error; }
static dispatch_semaphore_t start_entered, start_allowed, guest_returned, device_stopped, guest_closed, device_disposed;
static OSStatus start_result;
// free_run (route_change): the mock device calls back from a thread of its own every 5 ms while started, from 20 ms after its start (the system bringing the route up); a route switch
// (dev_gap) stops its callbacks until the unit is started again. A stop waits out a callback in flight, as AudioOutputUnitStop does
static _Atomic int free_run, dev_running, dev_gap, dev_in_cb, dev_stuck; static _Atomic uint64_t dev_resume_at; static _Atomic unsigned dev_starts;
uint64_t now_ns(void);
static OSStatus mock_start(AudioUnit au) {
    assert(au == fake_au());
    if (atomic_load(&free_run)) {
        atomic_store(&dev_resume_at, now_ns() + 20000000ull); if (!atomic_load(&dev_stuck)) atomic_store(&dev_gap, 0);   // dev_stuck: the new route does not come up yet
        atomic_store(&dev_running, 1); atomic_fetch_add(&dev_starts, 1);
        return noErr;
    }
    dispatch_semaphore_signal(start_entered);
    dispatch_semaphore_wait(start_allowed, DISPATCH_TIME_FOREVER);
    return start_result;
}
static OSStatus mock_stop(AudioUnit au) {
    assert(au == fake_au());
    if (atomic_load(&free_run)) { atomic_store(&dev_running, 0); while (atomic_load(&dev_in_cb)) sched_yield(); }
    if (device_stopped) dispatch_semaphore_signal(device_stopped);
    return noErr;
}
static OSStatus mock_uninit(AudioUnit au) {
    assert(au == fake_au() && !unit.device_listener && !unit.format_listener); return noErr;
}
static OSStatus mock_dispose(AudioComponentInstance au) {
    assert(au == fake_au() && !unit.device_listener && !unit.format_listener);
    unit.device = kAudioObjectUnknown;
    changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0);
    unit.disposals++; if (device_disposed) dispatch_semaphore_signal(device_disposed); return noErr;
}

uint64_t now_ns(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return (uint64_t)t.tv_sec * 1000000000ull + t.tv_nsec; }
static struct { const void *key; void *value; } object;
void *objmap_get(const void *key) { assert(key == object.key); return object.value; }
void objmap_put(const void *key, void *value) { assert(!object.key); object.key = key; object.value = value; }
void *objmap_del(const void *key) { assert(key == object.key); void *value = object.value; object.key = NULL; object.value = NULL; return value; }
void hle_signal_system_event(void *g) { (void)g; }
void hle_bind_system_event(void *g, int autoclear) { (void)g; (void)autoclear; }
module_t *module_of(const void *p) { (void)p; return NULL; }
int dm_guest_as_contains(uintptr_t a) { (void)a; return 0; }   // hle_svc.c: no guest address space in the unit test, so the big-stack take-overs (Start / Stop / CloseAudioOut, hle_bigstack.c) run on the calling host stack
void dm_host_helper_qos(qos_class_t q) { (void)q; }

static void *guest_start(void *out) {
    assert(h_au_Start(out) == RES_OK);
    dispatch_semaphore_signal(guest_returned);
    return NULL;
}
static void *guest_close(void *out) { h_au_Close(out); dispatch_semaphore_signal(guest_closed); return NULL; }
static int signaled(dispatch_semaphore_t s, int seconds) {
    return dispatch_semaphore_wait(s, dispatch_time(DISPATCH_TIME_NOW, seconds * (int64_t)NSEC_PER_SEC)) == 0;
}
static void blocked_start(void *out) {
    start_entered = dispatch_semaphore_create(0);
    start_allowed = dispatch_semaphore_create(0);
    guest_returned = dispatch_semaphore_create(0);
    device_stopped = dispatch_semaphore_create(0);
    guest_closed = dispatch_semaphore_create(0);
    static int16_t pcm[480 * 2];
    aout_buf b = {.ptr = pcm, .cap = sizeof pcm, .size = sizeof pcm};
    assert(h_au_Append(out, &b));
    pthread_t guest;
    assert(!pthread_create(&guest, NULL, guest_start, out));
    assert(signaled(start_entered, 2));
    int returned = signaled(guest_returned, 1);
    uint64_t until = now_ns() + NSEC_PER_SEC;
    aout_buf *released;
    while (!(released = h_au_Released(out)) && now_ns() < until) usleep(1000);
    until = now_ns() + NSEC_PER_SEC;
    int lock_free;
    while (!(lock_free = !pthread_mutex_trylock(&g_aos_lock)) && now_ns() < until) usleep(1000);
    assert(returned && released == &b && lock_free);
    pthread_mutex_unlock(&g_aos_lock);

    // A callback may arrive before Start returns. Only the silent sink may touch the PCM then.
    static int16_t music[RATE * 2];
    for (unsigned i = 0; i < sizeof music / sizeof *music; i++) music[i] = 1234;
    aout_buf next = {.ptr = music, .cap = sizeof music, .size = sizeof music};
    assert(h_au_Append(out, &next));
    int16_t samples[2] = {-1, -1};
    AudioBufferList bl = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof samples, samples}}};
    aout *a = ao(out);
    au_render(a, NULL, NULL, 0, 1, &bl);
    assert(!samples[0] && !samples[1]);
    dispatch_semaphore_signal(start_allowed);
    pthread_join(guest, NULL);
    until = now_ns() + NSEC_PER_SEC;
    do { au_render(a, NULL, NULL, 0, 1, &bl); if (samples[0]) break; usleep(1000); } while (now_ns() < until);
    assert(samples[0] == 1234 && samples[1] == 1234);
    // While the device calls back (here every 2 ms) the watchdog waits 250 ms instead of 50 (DM_AUDIO_WD_MS; with DM_AUDIO_WD_MS=50, the old fixed tick, this fails)
    uint64_t slow0 = atomic_load(&g_wd_slow);
    until = now_ns() + 2 * NSEC_PER_SEC;
    while (atomic_load(&g_wd_slow) == slow0 && now_ns() < until) { au_render(a, NULL, NULL, 0, 1, &bl); usleep(2000); }
    assert(atomic_load(&g_wd_slow) > slow0);

    dm_audio_suspend(1);
    assert(signaled(device_stopped, 1));
    dm_audio_suspend(0);
    assert(signaled(start_entered, 2));
    // A successful start with no callbacks keeps releasing buffers and is retried.
    dispatch_semaphore_signal(start_allowed);
    assert(signaled(device_stopped, 3));
    until = now_ns() + NSEC_PER_SEC;
    while (!(released = h_au_Released(out)) && now_ns() < until) usleep(1000);
    assert(released == &next);
    assert(signaled(start_entered, 3));
    start_result = kAudioUnitErr_FailedInitialization;
    dispatch_semaphore_signal(start_allowed);
    assert(signaled(start_entered, 4));
    // Reset while the retry blocks. The old unit stays alive until Start returns, then its replacement starts.
    start_result = noErr;
    dm_audio_reset(); assert(unit.disposals == 0);
    dispatch_semaphore_signal(start_allowed);
    assert(signaled(device_stopped, 1) && signaled(start_entered, 2));
    assert(unit.disposals == 1);
    // Close returns while the driver still blocks Start: it unregisters the output and leaves the unit to the start's worker,
    // which stops and disposes it when Start returns.
    device_disposed = dispatch_semaphore_create(0);
    assert(!pthread_create(&guest, NULL, guest_close, out));
    assert(signaled(guest_closed, 2));
    pthread_join(guest, NULL);
    pthread_mutex_lock(&g_aos_lock);
    for (int i = 0; i < AOMAX; i++) assert(g_aos[i] != a);
    pthread_mutex_unlock(&g_aos_lock);
    assert(unit.disposals == 1);
    dispatch_semaphore_signal(start_allowed);
    assert(signaled(device_stopped, 1) && signaled(device_disposed, 2) && unit.disposals == 2);
    dispatch_release(device_disposed); device_disposed = NULL;
    dispatch_release(guest_closed);
    dispatch_release(device_stopped);
    dispatch_release(guest_returned);
    dispatch_release(start_allowed);
    dispatch_release(start_entered);
}

// A Stop and Start while the watchdog waits out a 250 ms tick: the start signals it, so the device takes over from the silent sink (its first callback seen) within about 50 ms, not up to 250
static void start_during_slow_tick(void) {
    unit.init_error = noErr; unit.device = 1; unit.rate = 48000; unit.range = (AudioValueRange){15, 4096}; unit.frames = 512;
    start_entered = dispatch_semaphore_create(0); start_allowed = dispatch_semaphore_create(0); guest_returned = dispatch_semaphore_create(0); device_stopped = dispatch_semaphore_create(0);
    uint32_t out[16] = {0}; uint8_t prm[16]; h_au_InitParam(prm);
    assert(h_au_OpenDef0(out, prm) == RES_OK);
    aout *a = ao(out);
    int16_t samples[2]; AudioBufferList bl = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof samples, samples}}};
    pthread_t guest;
    for (int round = 0; round < 2; round++) {
        if (round) { h_au_Stop(out); assert(signaled(device_stopped, 1)); }
        assert(!pthread_create(&guest, NULL, guest_start, out) && signaled(start_entered, 2) && signaled(guest_returned, 2));
        dispatch_semaphore_signal(start_allowed);   // round 1: the watchdog began a 250 ms wait a few ms ago (below), and the start now waits for its first callback
        pthread_join(guest, NULL);
        uint64_t t0 = now_ns(), until = t0 + 2 * NSEC_PER_SEC; int handed = 0;
        while (!handed && now_ns() < until) {
            au_render(a, NULL, NULL, 0, 1, &bl); usleep(1000);
            pthread_mutex_lock(&g_aos_lock); handed = a->backend == BK_AU && a->start_phase == AU_IDLE; pthread_mutex_unlock(&g_aos_lock);
        }
        uint64_t dt = now_ns() - t0;
        if (round) { printf("start during a 250 ms watchdog wait: the device took over after %.0f ms\n", dt / 1e6); assert(handed && dt < 150 * 1000000ull); }
        assert(handed);
        // keep the device calling back until the watchdog has passed after a 250 ms wait twice: the second wait has then just begun
        uint64_t slow0 = atomic_load(&g_wd_slow); until = now_ns() + 3 * NSEC_PER_SEC;
        while (atomic_load(&g_wd_slow) < slow0 + 2 && now_ns() < until) { au_render(a, NULL, NULL, 0, 1, &bl); usleep(1000); }
        assert(atomic_load(&g_wd_slow) >= slow0 + 2);
    }
    h_au_Close(out); assert(signaled(device_stopped, 1));
    dispatch_release(start_entered); dispatch_release(start_allowed); dispatch_release(guest_returned); dispatch_release(device_stopped);
    start_entered = start_allowed = guest_returned = device_stopped = NULL;
    puts("audio watchdog: a start during a 250 ms wait is handed to the device at once");
}

// The watchdog's pass, before any output opens (so before its thread starts): a 250 ms tick with no new callback only suspects a stall; the 50 ms tick after it decides, as before, on 200 ms without one
static void watchdog_ticks(void) {
    const char *wd_env = getenv("DM_AUDIO_WD_MS"); char wd_keep[16] = ""; if (wd_env) snprintf(wd_keep, sizeof wd_keep, "%s", wd_env);
    unsetenv("DM_AUDIO_WD_MS"); assert(wd_healthy_ms() == 250);
    setenv("DM_AUDIO_WD_MS", "50", 1); assert(wd_healthy_ms() == 50);   // the old fixed tick
    setenv("DM_AUDIO_WD_MS", "10", 1); assert(wd_healthy_ms() == 50);
    setenv("DM_AUDIO_WD_MS", "5000", 1); assert(wd_healthy_ms() == 1000);
    if (wd_keep[0]) setenv("DM_AUDIO_WD_MS", wd_keep, 1); else unsetenv("DM_AUDIO_WD_MS");   // the run's own value for the watchdog thread
    device_stopped = dispatch_semaphore_create(0);
    static aout a; pthread_mutex_init(&a.m, NULL); a.ch = 2; a.au = fake_au(); a.backend = BK_AU; a.start_phase = AU_IDLE; a.id = 99;
    static aout idle; pthread_mutex_init(&idle.m, NULL); idle.ch = 2; idle.au = fake_au(); idle.backend = BK_NONE; idle.start_phase = AU_IDLE; idle.id = 98;
    const uint64_t ms = 1000000; uint64_t t = 1000 * ms;
    pthread_mutex_lock(&g_aos_lock); g_aos[0] = &a; g_aos[1] = &idle;
    atomic_fetch_add(&a.cb_n, 10); assert(wd_pass(t, 50 * ms, 50));   // calling back, and a stopped output beside it: the healthy tick
    t += 250 * ms; atomic_fetch_add(&a.cb_n, 50); assert(wd_pass(t, 250 * ms, 250));
    t += 250 * ms; assert(!wd_pass(t, 250 * ms, 250)); assert(a.backend == BK_AU && !a.stalled);   // no callback in 250 ms: a suspicion only, back to 50 ms ticks
    t += 50 * ms; atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 50 * ms, 50) && a.backend == BK_AU);   // calling again (a whole-process stop): no stall
    t += 1100 * ms; assert(!wd_pass(t, 1100 * ms, 250) && a.backend == BK_AU);   // a late wake-up of the watchdog itself only restarts the count
    t += 50 * ms; atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 50 * ms, 50));
    t += 250 * ms; assert(!wd_pass(t, 250 * ms, 250) && a.backend == BK_AU);   // the device stops calling back: suspected
    t += 50 * ms; assert(!wd_pass(t, 50 * ms, 50));   // 300 ms without a callback on a 50 ms tick: the stall, as before
    assert(a.backend == BK_NULL && a.stalled && signaled(device_stopped, 1));
    null_stop(&a); a.stalled = 0; a.backend = BK_AU; a.wd_n = atomic_load(&a.cb_n); a.wd_t = t;
    t += 50 * ms; atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 50 * ms, 50));
    t += 50 * ms; a.start_phase = AU_WAIT_CALLBACK; assert(!wd_pass(t, 50 * ms, 50) && a.start_phase == AU_WAIT_CALLBACK);   // a start waiting for its first callback is never the healthy tick
    a.start_phase = AU_IDLE; a.wd_n = atomic_load(&a.cb_n); a.wd_t = t;
    // A pass after a healthy tick measures from the last callback, which au_render stamps, not from its own time. The last callback 1 ms after a healthy pass: the next healthy pass, 250 ms later, finds it
    // 249 ms old and only suspects a stall, and the 50 ms pass after it decides, 300 ms after that callback (with the pass's own time it was the 550 ms pass, and the log said 300)
    int16_t pcm[2]; AudioBufferList bl = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof pcm, pcm}}};
    t = now_ns(); atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 250 * ms, 250));
    atomic_store(&a.hold_device, 1); usleep(1000); au_render(&a, NULL, NULL, 0, 1, &bl); atomic_store(&a.hold_device, 0);
    uint64_t last_cb = atomic_load(&a.cb_t); assert(last_cb > t && last_cb < t + 100 * ms);
    uint64_t stale0 = atomic_load(&g_wd_stale);
    t += 250 * ms; assert(!wd_pass(t, 250 * ms, 250) && a.backend == BK_AU && a.wd_t == last_cb && atomic_load(&g_wd_stale) == stale0 + 1);
    t += 50 * ms; assert(!wd_pass(t, 50 * ms, 50) && a.backend == BK_NULL && signaled(device_stopped, 1));
    printf("stall decided %.0f ms after the last callback (the log's figure: %.0f ms)\n", (t - last_cb) / 1e6, (t - a.wd_t) / 1e6);
    assert(t - last_cb <= 350 * ms && t - a.wd_t == t - last_cb);
    null_stop(&a); a.stalled = 0; a.backend = BK_AU; a.wd_n = atomic_load(&a.cb_n); a.wd_t = t;
    // The last callback 40 ms before a healthy pass: the device still calls back; the next pass suspects and the 50 ms one after it decides, and the log gives the full 340 ms
    t += 50 * ms; atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 50 * ms, 50));
    t += 250 * ms; atomic_store(&a.cb_t, t - 40 * ms); atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 250 * ms, 250) && a.wd_t == t - 40 * ms);
    t += 250 * ms; assert(!wd_pass(t, 250 * ms, 250) && a.backend == BK_AU);
    t += 50 * ms; assert(!wd_pass(t, 50 * ms, 50) && a.backend == BK_NULL && signaled(device_stopped, 1) && t - a.wd_t == 340 * ms);
    null_stop(&a); a.stalled = 0; a.backend = BK_AU; a.wd_n = atomic_load(&a.cb_n); a.wd_t = t;
    // A stop of the whole process for 600 ms during a 250 ms tick: the pass 850 ms after the last is a late wake-up (more than 150 ms past its tick) and only restarts the count, so the device, whose I/O
    // thread resumes with it, has 200 ms again to call back. Under the old rule (four ticks, 1000 ms) it was a suspicion, and the next 50 ms pass stood the silent sink in at "900 ms"
    t += 50 * ms; atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 50 * ms, 50));
    t += 850 * ms; assert(!wd_pass(t, 850 * ms, 250) && a.backend == BK_AU && a.wd_t == t);
    t += 50 * ms; assert(!wd_pass(t, 50 * ms, 50) && a.backend == BK_AU && !a.stalled);
    t += 50 * ms; atomic_fetch_add(&a.cb_n, 1); assert(wd_pass(t, 50 * ms, 50));
    t += 300 * ms; assert(!wd_pass(t, 300 * ms, 250) && a.backend == BK_AU);   // 50 ms late on a 250 ms tick: still a suspicion, not a late wake-up
    t += 50 * ms; assert(!wd_pass(t, 50 * ms, 50) && a.backend == BK_NULL && signaled(device_stopped, 1));
    null_stop(&a); a.stalled = 0; a.backend = BK_AU;
    g_aos[0] = g_aos[1] = NULL; pthread_mutex_unlock(&g_aos_lock);
    dispatch_release(device_stopped); device_stopped = NULL;
    puts("audio watchdog: 250 ms ticks while called back, a suspicion decided at 50 ms from the last callback's own time, stalls as before, a late wake-up 150 ms past its tick");
}

// A route change while the output plays (AirPods connecting): the device stops calling back as the route switches. The host restarts the unit at once and its first callback plays the queue:
// no silent sink, no silent callbacks waiting for the watchdog's handoff, no underrun burst. Before (and with DM_AUDIO_ROUTE=0), the watchdog stood the silent sink in after 200-350 ms, retried
// the unit 1 s later and handed over on its next tick: sound again after about 1.3 s, with silent callbacks first. A game keeps 4 blocks of 5 ms queued, refilled as they come back
enum { RC_BLOCKS = 4, RC_FRAMES = 240 };
static aout *rc_out; static void *rc_key; static _Atomic int rc_quit; static _Atomic uint64_t rc_route_at, rc_audible_at, rc_silent;
static void *rc_device(void *p) {
    (void)p; int16_t pcm[RC_FRAMES * 2]; AudioBufferList bl = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof pcm, pcm}}};
    uint64_t t = now_ns();
    while (!atomic_load(&rc_quit)) {
        t += 5000000; uint64_t now = now_ns(); if (t > now) usleep((useconds_t)((t - now) / 1000)); else t = now;
        atomic_store(&dev_in_cb, 1);
        if (atomic_load(&dev_running) && !atomic_load(&dev_gap) && now_ns() >= atomic_load(&dev_resume_at)) {
            au_render(rc_out, NULL, NULL, 0, RC_FRAMES, &bl);
            if (atomic_load(&rc_route_at) && !atomic_load(&rc_audible_at)) {
                if (pcm[0]) atomic_store(&rc_audible_at, now_ns()); else atomic_fetch_add(&rc_silent, 1);   // a callback after the route change that played no sound
            }
        }
        atomic_store(&dev_in_cb, 0);
    }
    return NULL;
}
static _Atomic int rc_game_quit;
static void *rc_game(void *p) {
    (void)p;
    while (!atomic_load(&rc_game_quit)) {
        aout_buf *r; while ((r = h_au_Released(rc_key))) assert(h_au_Append(rc_key, r));   // a block played: queue it again
        usleep(500);
    }
    return NULL;
}
static int rc_state(int *backend, int *stalled) {
    pthread_mutex_lock(&g_aos_lock); *backend = rc_out->backend; *stalled = rc_out->stalled; int r = rc_out->route_t != 0; pthread_mutex_unlock(&g_aos_lock); return r;
}
// One route switch: gap, then trigger. Returns ms from the trigger to the first callback that played sound
static double rc_switch(const char *what, void (*trigger)(void)) {
    uint64_t u0 = atomic_load(&rc_out->under_n); unsigned s0 = atomic_load(&dev_starts);
    atomic_store(&rc_silent, 0); atomic_store(&rc_audible_at, 0);
    atomic_store(&dev_gap, 1); usleep(10000);   // the route switches: no callbacks from here until the unit is started on the new one
    uint64_t t0 = now_ns(); atomic_store(&rc_route_at, t0); trigger();
    int standins = 0, backend, stalled;
    while (!atomic_load(&rc_audible_at) && now_ns() - t0 < 3 * NSEC_PER_SEC) { rc_state(&backend, &stalled); standins |= backend == BK_NULL; usleep(1000); }
    uint64_t audible = atomic_load(&rc_audible_at);
    double ms = audible ? (audible - t0) / 1e6 : -1;
    uint64_t until = now_ns() + 300000000ull; int routed = 1;
    while (now_ns() < until) { routed = rc_state(&backend, &stalled); standins |= backend == BK_NULL; usleep(1000); }   // 300 ms of play after it
    uint64_t under = atomic_load(&rc_out->under_n) - u0;
    printf("route change (%s): sound again %.0f ms after it, %llu silent callbacks before, silent sink stood in=%d, %llu underruns in the switch and the 300 ms after, %u restart(s), handed over=%d\n",
           what, ms, (unsigned long long)atomic_load(&rc_silent), standins, (unsigned long long)under, atomic_load(&dev_starts) - s0, !routed && backend == BK_AU);
    assert(audible && ms < 150);                   // without waiting for the watchdog (its stall is 200-350 ms, its retry 1 s after)
    assert(atomic_load(&rc_silent) == 0);          // the restarted unit's first callback plays the queue
    assert(!standins && !stalled);                 // no silent sink: nothing consumed unheard
    assert(under <= 2);                            // the queue was kept full while the route switched
    assert(atomic_load(&dev_starts) == s0 + 1 && !routed && backend == BK_AU);
    atomic_store(&rc_route_at, 0);
    return ms;
}
// The fallback: the restarted unit does not call back (the new route never comes up). After 200 ms the silent sink stands in and the game's buffers come back again; when the device calls back,
// the watchdog hands over from the sink as after any start
static void rc_fallback(void) {
    atomic_store(&dev_stuck, 1); atomic_store(&dev_gap, 1); usleep(10000);
    uint64_t t0 = now_ns(); dm_audio_route_change("old device unavailable: Headphones -> Speaker (test, the new route does not call back)", 1);
    int backend = BK_AU, stalled;
    while (backend != BK_NULL && now_ns() - t0 < NSEC_PER_SEC) { rc_state(&backend, &stalled); usleep(1000); }
    double ms = (now_ns() - t0) / 1e6;
    uint32_t q0 = atomic_load(&rc_out->q_head); usleep(100000); uint32_t played = atomic_load(&rc_out->q_head) - q0;
    atomic_store(&dev_stuck, 0); atomic_store(&dev_gap, 0);   // the route comes up
    uint64_t t1 = now_ns(); int routed = 1;
    while (now_ns() - t1 < NSEC_PER_SEC) { routed = rc_state(&backend, &stalled); if (backend == BK_AU) break; usleep(1000); }
    printf("route change, the new route silent: the silent sink stood in %.0f ms after it and played %u blocks of 5 ms in 100 ms; the device took over %.0f ms after it called back\n", ms, played, (now_ns() - t1) / 1e6);
    assert(ms >= 200 && ms < 600 && played >= 10 && backend == BK_AU && !routed && !stalled);
}
static void rc_ios(void) { dm_audio_route_change("new device available: Speaker -> BluetoothA2DPOutput (test)", 1); }
static void rc_mac(void) { unit.device = 5; changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0); }
static void route_drained(void *p);
static void route_change(void) {
    unit.init_error = noErr; unit.device = 1; unit.rate = 48000; unit.range = (AudioValueRange){15, 4096}; unit.frames = 512;
    atomic_store(&free_run, 1);
    static uint32_t out[16]; uint8_t prm[16]; h_au_InitParam(prm);
    assert(h_au_OpenDef0(out, prm) == RES_OK);
    rc_key = out; rc_out = ao(out);
    static int16_t pcm[RC_BLOCKS][RC_FRAMES * 2]; static aout_buf b[RC_BLOCKS];
    for (int i = 0; i < RC_BLOCKS; i++) { for (int k = 0; k < RC_FRAMES * 2; k++) pcm[i][k] = 1234; b[i] = (aout_buf){.ptr = pcm[i], .cap = sizeof pcm[i], .size = sizeof pcm[i]}; assert(h_au_Append(out, &b[i])); }
    pthread_t dev, game;
    assert(!pthread_create(&dev, NULL, rc_device, NULL) && !pthread_create(&game, NULL, rc_game, NULL));
    assert(h_au_Start(out) == RES_OK);
    int backend = BK_NONE, stalled; uint64_t until = now_ns() + 2 * NSEC_PER_SEC;
    while (now_ns() < until) { rc_state(&backend, &stalled); if (backend == BK_AU) break; usleep(1000); }
    assert(backend == BK_AU); usleep(300000);
    rc_switch("iOS route change notification", rc_ios);
    rc_switch("Mac default output device", rc_mac);
    rc_fallback(); usleep(100000);
    // Mac: the DefaultOutput unit follows a new default device by itself and goes on calling back there (no gap): it is watched, not stopped and started again
    {
        unsigned s1 = atomic_load(&dev_starts); uint64_t u1 = atomic_load(&rc_out->under_n), c1 = atomic_load(&rc_out->cb_n);
        unit.device = 6; changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0);
        dispatch_sync_f(route_queue(), NULL, route_drained);
        rc_state(&backend, &stalled);
        pthread_mutex_lock(&g_aos_lock); uint32_t dev_now = rc_out->dev; pthread_mutex_unlock(&g_aos_lock);
        printf("route change (Mac default output device, the unit plays on): %u restart(s), %llu callbacks meanwhile, %llu underruns\n", atomic_load(&dev_starts) - s1,
               (unsigned long long)(atomic_load(&rc_out->cb_n) - c1), (unsigned long long)(atomic_load(&rc_out->under_n) - u1));
        assert(atomic_load(&dev_starts) == s1 && backend == BK_AU && !stalled && dev_now == 6 && atomic_load(&rc_out->under_n) - u1 <= 2);
    }
    // No route change, no behaviour change: the same device notified again, and a notification whose outputs are the same ones, restart nothing
    unsigned s0 = atomic_load(&dev_starts); uint64_t c0 = atomic_load(&rc_out->cb_n);
    changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0);
    dm_audio_route_change("category change: Speaker -> Speaker (test)", 0);
    usleep(200000);
    rc_state(&backend, &stalled);
    assert(atomic_load(&dev_starts) == s0 && backend == BK_AU && atomic_load(&rc_out->cb_n) > c0 + 20);
    atomic_store(&rc_game_quit, 1); pthread_join(game, NULL);
    h_au_Close(out);
    atomic_store(&rc_quit, 1); pthread_join(dev, NULL);
    atomic_store(&free_run, 0);
    puts("audio route change: the unit restarted at once on the new route, its first callback audible, no silent sink and no underrun burst; no restart without a change");
}

static void route_drained(void *p) { (void)p; }
// The route check runs on a queue and replaces the unit under g_aos_lock: read the output's unit count there
static int wait_dev_ch(aout *a, int want) {
    uint64_t until = now_ns() + 2 * NSEC_PER_SEC;
    for (;;) {
        pthread_mutex_lock(&g_aos_lock); int got = a->dev_ch; pthread_mutex_unlock(&g_aos_lock);
        if (got == want) return 1;
        if (now_ns() > until) return 0;
        usleep(1000);
    }
}
static _Atomic int route_notifications;
static void test_route_without_output(void) {
    unit.route_ch = 2;
    assert(dm_audio_route() == 2 && system_route_listener && device_route_listener);
    unit.route_ch = 6;
    AudioObjectPropertyAddress pa = {kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
    system_route_listener(kAudioObjectSystemObject, 1, &pa, NULL);
    uint64_t until = now_ns() + NSEC_PER_SEC;
    while ((dm_audio_route() != 6 || !atomic_load(&route_notifications)) && now_ns() < until) usleep(1000);
    assert(dm_audio_route() == 6 && atomic_load(&route_notifications));
    unit.route_ch = 2;
    pa.mSelector = kAudioDevicePropertyStreamFormat; pa.mScope = kAudioObjectPropertyScopeOutput;
    device_route_listener(SYS_OUT, 1, &pa, NULL);
    until = now_ns() + NSEC_PER_SEC;
    while (dm_audio_route() != 2 && now_ns() < until) usleep(1000);
    assert(dm_audio_route() == 2);
}
static void test_sink_route(void) {
    unit.route_ch = 2; unit.device = 1; unit.rate = 48000; unit.range = (AudioValueRange){15, 4096};
    void *key = dm_pcmout_open_sink(); aout *a = ao(key);
    assert(a->sink_pcm && a->ch == DM_AUDIO_SINK_CHANNELS && a->dev_ch == 2);
    int16_t pcm[257 * DM_AUDIO_SINK_CHANNELS];
    for (int i = 0; i < 257; i++) for (int j = 0; j < DM_AUDIO_SINK_CHANNELS; j++) pcm[i * DM_AUDIO_SINK_CHANNELS + j] = (int16_t)(1000 * j + i);
    aout_buf b = {.ptr = pcm, .cap = sizeof pcm, .size = sizeof pcm}; assert(dm_pcmout_append(key, &b));
    int16_t stereo[129 * 2], six[127 * 6];
    atomic_store(&a->state, STATE_STARTED);
    pull_device(a, (uint8_t *)stereo, sizeof stereo);
    atomic_store(&a->state, STATE_STOPPED);
    for (int i = 0; i < 129; i++) for (int j = 0; j < 2; j++) assert(stereo[2 * i + j] == 1000 * (j + 6) + i);
    unit.route_ch = 6; dm_audio_route_changed(); assert(a->dev_ch == 6 && unit.format_ch == 6);
    atomic_store(&a->state, STATE_STARTED);
    pull_device(a, (uint8_t *)six, sizeof six);
    atomic_store(&a->state, STATE_STOPPED);
    for (int i = 0; i < 127; i++) for (int j = 0; j < 6; j++) assert(six[6 * i + j] == 1000 * j + i + 129);
    dm_audio_suspend(1);
    unit.route_ch = 2; dm_audio_route_changed(); assert(a->dev_ch == 6);   // the cache changes in the background; the unit waits for resume
    dm_audio_suspend(0); assert(a->dev_ch == 2 && unit.format_ch == 2);
    atomic_store(&a->state, STATE_STARTED);
    pull_device(a, (uint8_t *)stereo, sizeof(int16_t) * 2);
    atomic_store(&a->state, STATE_STOPPED);
    assert(stereo[0] == 6256 && stereo[1] == 7256 && dm_pcmout_released(key) == &b);
    dm_pcmout_close(key);
    assert(!object.key);
}
int main(void) {
    watchdog_ticks();
    setenv("DM_AUDIO", "1", 1); unsetenv("DM_DBG_AU_FRAMES");
    test_route_without_output();
    unit.device = 1; unit.rate = 48000; unit.range = (AudioValueRange){15, 4096}; unit.frames = 512;
    uint32_t out[16] = {0}; uint8_t prm[16]; h_au_InitParam(prm);
    check_open_publication = 1;
    assert(h_au_OpenDef0(out, prm) == RES_OK);
    check_open_publication = 0;
    assert(unit.frames == 240 && unit.writes == 1 && unit.input_formats == 1 && unit.device_listener && unit.format_listener);

    unit.device = 2; unit.rate = 44100; unit.frames = 512;
    changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0);
    assert(unit.frames == 221 && unit.writes == 2);
    // A device's rate can change without a CurrentDevice notification.
    unit.rate = 96000; changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    assert(unit.frames == 480 && unit.writes == 3);
    unit.rate = 48000; changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    assert(unit.frames == 240 && unit.writes == 4);
    unit.rate = 44100;
    changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0);
    changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1);
    assert(unit.frames == 240 && unit.writes == 4);
    changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    assert(unit.frames == 221 && unit.writes == 5);

    // Device limits are part of the HAL contract. Request the nearest supported frame count.
    unit.device = 3; unit.rate = 48000; unit.range.mMinimum = 256;
    changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0);
    assert(unit.frames == 256);
    unit.range = (AudioValueRange){15, 128}; changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    assert(unit.frames == 128);
    unit.range.mMaximum = 4096;
    setenv("DM_DBG_AU_FRAMES", "1024", 1);
    changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0); assert(unit.frames == 1024);
    unit.device = 4; unit.rate = 44100; changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0); assert(unit.frames == 1024);
    unsetenv("DM_DBG_AU_FRAMES");
    unsigned before = unit.writes; unit.device = kAudioObjectUnknown;
    changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0); assert(unit.writes == before);
    unit.device = 1;
    // The CurrentDevice notifications above queued route changes for the stopped output: handle them before it starts, or one handled late restarts the output blocked_start drives
    dispatch_sync_f(route_queue(), NULL, route_drained);
    blocked_start(out);
    assert(!object.key);

    // Six-channel route: the unit takes six channels with the 5.1 layout, and a six-channel output reaches the device as it is.
    unit.route_ch = 6; unit.device = 5; unit.rate = 48000; unit.frames = 512; unit.format_ch = 0; unit.layout_tag = 0;
    assert(dm_audio_output_channels() == 6);
    assert(dm_audio_route() == 6);   // the game threads' read: the last route a host thread read
    uint32_t out6[16] = {0}; uint8_t prm6[16]; h_au_InitParam(prm6); *(uint16_t *)(prm6 + 4) = 6;
    assert(h_au_OpenDef0(out6, prm6) == RES_OK);
    aout *six = ao(out6);
    assert(six->ch == 6 && six->dev_ch == 6 && unit.format_ch == 6 && unit.layout_tag == kAudioChannelLayoutTag_MPEG_5_1_A);
    static int16_t six_pcm[240 * 6];
    for (int i = 0; i < 240; i++) for (int j = 0; j < 6; j++) six_pcm[6 * i + j] = (int16_t)(1000 * (j + 1) + i);
    aout_buf blk = {.ptr = six_pcm, .cap = sizeof six_pcm, .size = sizeof six_pcm};
    assert(h_au_Append(out6, &blk));
    atomic_store(&six->state, STATE_STARTED);
    int16_t got6[240 * 6];
    AudioBufferList bl6 = {.mNumberBuffers = 1, .mBuffers = {{6, sizeof got6, got6}}};
    au_render(six, NULL, NULL, 0, 240, &bl6);
    assert(memcmp(got6, six_pcm, sizeof got6) == 0);
    assert(h_au_Released(out6) == &blk);
    h_au_Close(out6);
    assert(!object.key && unit.disposals == 3);

    // Six-channel output on a stereo route: the unit takes stereo and the host downmixes (front 1.0, center and back 0.707, LFE 0.251, Q15).
    unit.route_ch = 2; unit.device = 6; unit.format_ch = 0; unit.layout_tag = 0;
    assert(dm_audio_output_channels() == 2);
    uint32_t out2[16] = {0};
    assert(h_au_OpenDef0(out2, prm6) == RES_OK);
    aout *dn = ao(out2);
    assert(dn->ch == 6 && dn->dev_ch == 2 && unit.format_ch == 2 && unit.layout_tag == 0);
    static int16_t fr_pcm[240 * 6];
    for (int i = 0; i < 240; i++) {   // every channel in its own value; the last two frames at full scale either way, to check the clamp
        int16_t f[6] = {1000, 2000, 3000, 4000, 5000, 6000}, hi[6] = {30000, 30000, 30000, 30000, 30000, 30000}, lo[6] = {-30000, -30000, -30000, -30000, -30000, -30000};
        memcpy(fr_pcm + 6 * i, i == 238 ? hi : i == 239 ? lo : f, sizeof f);
    }
    aout_buf fb = {.ptr = fr_pcm, .cap = sizeof fr_pcm, .size = sizeof fr_pcm};
    assert(h_au_Append(out2, &fb));
    atomic_store(&dn->state, STATE_STARTED);
    static int16_t st2[2 * 240];
    AudioBufferList bl2 = {.mNumberBuffers = 1, .mBuffers = {{2, sizeof st2, st2}}};
    au_render(dn, NULL, NULL, 0, 240, &bl2);
    assert(st2[0] == 7659 && st2[1] == 9366);   // L = 1000 + 0.707 × 3000 + 0.251 × 4000 + 0.707 × 5000, R = 2000 + 0.707 × 3000 + 0.251 × 4000 + 0.707 × 6000
    assert(st2[2 * 238] == 32767 && st2[2 * 238 + 1] == 32767 && st2[2 * 239] == -32768 && st2[2 * 239 + 1] == -32768);
    h_au_Close(out2);
    assert(!object.key && unit.disposals == 4);
    unit.route_ch = 2; unit.device = 1;

    // Route change mid-session (HDMI 5.1 to the speakers and back): the unit's own notification leads to a new unit at the route's count, off the notifying thread.
    unit.route_ch = 6; unit.device = 7; unit.format_ch = 0; unit.layout_tag = 0;
    uint32_t outr[16] = {0};
    assert(h_au_OpenDef0(outr, prm6) == RES_OK);
    aout *rt = ao(outr);
    assert(rt->dev_ch == 6 && unit.format_ch == 6 && unit.layout_tag == kAudioChannelLayoutTag_MPEG_5_1_A && unit.disposals == 4);
    unit.route_ch = 2; unit.layout_tag = 0;
    changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    assert(wait_dev_ch(rt, 2) && unit.format_ch == 2 && unit.layout_tag == 0 && unit.disposals == 5);
    unit.route_ch = 6; unit.device = 7;   // disposal cleared the unit's device; the new unit is on the default output again
    changed(kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0);
    assert(wait_dev_ch(rt, 6) && unit.format_ch == 6 && unit.layout_tag == kAudioChannelLayoutTag_MPEG_5_1_A && unit.disposals == 6);
    // A notification that leaves the route's count alone keeps the unit (the queued check, then the same check run here)
    changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    usleep(100000); dm_audio_route_changed(); assert(unit.disposals == 6);
    // A new unit that cannot be made leaves the output silent until the next route change, which tries again
    unit.route_ch = 2; unit.init_error = kAudioUnitErr_FailedInitialization;
    dm_audio_route_changed();
    pthread_mutex_lock(&g_aos_lock); int lost = !rt->au && rt->unit_lost; pthread_mutex_unlock(&g_aos_lock);
    assert(lost && unit.disposals == 8);   // the old unit and the failed new one
    unit.init_error = 0; unit.device = 7;
    dm_audio_route_changed();
    assert(wait_dev_ch(rt, 2) && rt->au && !rt->unit_lost && unit.format_ch == 2);
    unit.route_ch = 6; dm_audio_route_changed();
    assert(wait_dev_ch(rt, 6) && unit.disposals == 9);
    h_au_Close(outr);
    assert(!object.key && unit.disposals == 10);
    // A stereo output stays stereo on a six-channel route (the guest writes two channels): a route change leaves its unit alone
    uint32_t outs[16] = {0};
    assert(h_au_OpenDef0(outs, prm) == RES_OK && ao(outs)->dev_ch == 2 && unit.format_ch == 2);
    unit.route_ch = 2; changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    usleep(100000); dm_audio_route_changed(); unit.route_ch = 6; changed(kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
    usleep(100000); dm_audio_route_changed(); assert(ao(outs)->dev_ch == 2 && unit.disposals == 10);
    h_au_Close(outs);
    assert(!object.key && unit.disposals == 11);
    // A mono output goes to a mono unit as the guest writes it, on either route (it is not downmixed as six channels)
    unit.layout_tag = 0; uint32_t outm[16] = {0}; uint8_t prm1[16]; h_au_InitParam(prm1); *(uint16_t *)(prm1 + 4) = 1;
    assert(h_au_OpenDef0(outm, prm1) == RES_OK && ao(outm)->dev_ch == 1 && unit.format_ch == 1 && unit.layout_tag == 0);
    static int16_t mono_pcm[240];
    for (int i = 0; i < 240; i++) mono_pcm[i] = (int16_t)(100 + i);
    aout_buf mb = {.ptr = mono_pcm, .cap = sizeof mono_pcm, .size = sizeof mono_pcm};
    assert(h_au_Append(outm, &mb));
    atomic_store(&ao(outm)->state, STATE_STARTED);
    int16_t m3[3]; AudioBufferList blm = {.mNumberBuffers = 1, .mBuffers = {{1, sizeof m3, m3}}};
    au_render(ao(outm), NULL, NULL, 0, 3, &blm);
    assert(m3[0] == 100 && m3[1] == 101 && m3[2] == 102);
    unit.route_ch = 2; dm_audio_route_changed(); assert(ao(outm)->dev_ch == 1 && unit.disposals == 11);
    h_au_Close(outm);
    assert(!object.key && unit.disposals == 12);
    unit.route_ch = 2; unit.device = 1;

    // Failure after listener registration follows the same cleanup path as Close.
    unit.device = 1; unit.rate = 48000; unit.init_error = kAudioUnitErr_FailedInitialization;
    aout failed = {.ch = 2};
    assert(au_create(&failed, 2) == kAudioUnitErr_FailedInitialization && !failed.au && unit.disposals == 13);
    unit.init_error = 0; test_sink_route();
    start_during_slow_tick();
    route_change();
    puts("audio device: buffer configuration, blocked start, callback handoff, retry and lifecycle passed");
    return 0;
}

void dm_audio_device_changed(void) { atomic_fetch_add(&route_notifications, 1); }   // renderer notification delivery is checked by t_audren_work
