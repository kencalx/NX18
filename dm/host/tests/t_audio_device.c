// Mac device buffer contract: drive the real setup/listener/close paths with Core Audio property notifications,
// including synchronous format notifications from a buffer write and device removal during disposal. No hardware needed.
#include <AudioToolbox/AudioToolbox.h>
#include <assert.h>
#include <stddef.h>
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
        assert(scope == kAudioUnitScope_Input && size == sizeof *f && f->mSampleRate == RATE && f->mChannelsPerFrame == 2);
        unit.input_formats++; changed(id, scope, el); // the 48 kHz guest format is not the hardware rate
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
static OSStatus mock_init(AudioUnit au) { assert(au == fake_au()); return unit.init_error; }
static dispatch_semaphore_t start_entered, start_allowed, guest_returned, device_stopped, guest_closed, device_disposed;
static OSStatus start_result;
static OSStatus mock_start(AudioUnit au) {
    assert(au == fake_au());
    dispatch_semaphore_signal(start_entered);
    dispatch_semaphore_wait(start_allowed, DISPATCH_TIME_FOREVER);
    return start_result;
}
static OSStatus mock_stop(AudioUnit au) {
    assert(au == fake_au()); dispatch_semaphore_signal(device_stopped); return noErr;
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
    gbuf b = {pcm, sizeof pcm, sizeof pcm};
    assert(h_au_Append(out, &b));
    pthread_t guest;
    assert(!pthread_create(&guest, NULL, guest_start, out));
    assert(signaled(start_entered, 2));
    int returned = signaled(guest_returned, 1);
    uint64_t until = now_ns() + NSEC_PER_SEC;
    gbuf *released;
    while (!(released = h_au_Released(out)) && now_ns() < until) usleep(1000);
    until = now_ns() + NSEC_PER_SEC;
    int lock_free;
    while (!(lock_free = !pthread_mutex_trylock(&g_aos_lock)) && now_ns() < until) usleep(1000);
    assert(returned && released == &b && lock_free);
    pthread_mutex_unlock(&g_aos_lock);

    // A callback may arrive before Start returns. Only the silent sink may touch the PCM then.
    static int16_t music[RATE * 2];
    for (unsigned i = 0; i < sizeof music / sizeof *music; i++) music[i] = 1234;
    gbuf next = {music, sizeof music, sizeof music};
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

int main(void) {
    watchdog_ticks();
    setenv("DM_AUDIO", "1", 1); unsetenv("DM_DBG_AU_FRAMES");
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
    blocked_start(out);
    assert(!object.key);

    // Failure after listener registration follows the same cleanup path as Close.
    unit.device = 1; unit.rate = 48000; unit.init_error = kAudioUnitErr_FailedInitialization;
    aout failed = {.ch = 2};
    assert(au_create(&failed) == kAudioUnitErr_FailedInitialization && !failed.au && unit.disposals == 3);
    start_during_slow_tick();
    puts("audio device: buffer configuration, blocked start, callback handoff, retry and lifecycle passed");
    return 0;
}
