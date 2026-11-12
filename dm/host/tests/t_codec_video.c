// The Switch 2's video decoder API as the host serves it (hle_codec_video.c), without a guest: the buffer protocol, results, sync handles, sync point events and the
// readback, on synthetic red key frames: 16x16 VP9 and VP8 (the ones t_movie_vpx.c decodes), a 64x64 H.264 baseline frame (ffmpeg's libx264, SEI removed) and a 64x64 AV1 frame
// (SVT-AV1 through PyAV, preset 12, CRF 30); no game data. The SystemEvent functions are stubs that record each event's state.
#include "../hle.h"
#undef HLE_FORCE
#define HLE_FORCE(mangled, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#include "../hle_movie.c"
#include "../hle_codec_video.c"
// VideoToolbox's decode is wrapped so a test can play iOS invalidating a session in the background (kVTInvalidSessionErr): returned by the decode, or given to the callback.
// Its session creation is wrapped too, so a test can play iOS refusing a new hardware session while the app is still inactive (kVTVideoDecoderNotAvailableNowErr)
#include <VideoToolbox/VideoToolbox.h>
static OSStatus vt_decode(VTDecompressionSessionRef, CMSampleBufferRef, VTDecodeFrameFlags, void *, VTDecodeInfoFlags *);
static OSStatus vt_create(CFAllocatorRef, CMVideoFormatDescriptionRef, CFDictionaryRef, CFDictionaryRef, const VTDecompressionOutputCallbackRecord *, VTDecompressionSessionRef *);
#define VTDecompressionSessionDecodeFrame vt_decode
#define VTDecompressionSessionCreate vt_create
#include "../hle_movie_avc.c"
#include "../hle_movie_av1.c"
#undef VTDecompressionSessionDecodeFrame
#undef VTDecompressionSessionCreate
#include <assert.h>
static int vt_fail, vt_calls;   // vt_fail: 1 = the next decode returns kVTInvalidSessionErr, 2 = it gives that error to the callback and returns noErr (then 0 again)
static mavc *vt_avc; static mav1 *vt_av1;   // whose callback mode 2 calls
static OSStatus vt_decode(VTDecompressionSessionRef vs, CMSampleBufferRef sb, VTDecodeFrameFlags fl, void *src, VTDecodeInfoFlags *info) {
    vt_calls++;
    int f = vt_fail; vt_fail = 0;
    if (f == 1) return kVTInvalidSessionErr;
    if (f == 2) { if (vt_avc) on_frame(vt_avc, src, kVTInvalidSessionErr, 0, NULL, kCMTimeInvalid, kCMTimeInvalid); else av1_on_frame(vt_av1, src, kVTInvalidSessionErr, 0, NULL, kCMTimeInvalid, kCMTimeInvalid); return noErr; }
    return VTDecompressionSessionDecodeFrame(vs, sb, fl, src, info);
}
static OSStatus vt_create_fail; static int vt_creates;   // vt_create_fail: the next session creation returns it (then 0 again)
static OSStatus vt_create(CFAllocatorRef al, CMVideoFormatDescriptionRef fd, CFDictionaryRef spec, CFDictionaryRef attrs, const VTDecompressionOutputCallbackRecord *cb, VTDecompressionSessionRef *vs) {
    vt_creates++;
    OSStatus f = vt_create_fail; vt_create_fail = 0;
    if (f) { *vs = NULL; return f; }
    return VTDecompressionSessionCreate(al, fd, spec, attrs, cb, vs);
}
static char g_err[8192];   // what one call logged
#define LOGGED(stmt) do { fflush(stderr); int s_ = dup(2); FILE *t_ = tmpfile(); assert(s_ >= 0 && t_); dup2(fileno(t_), 2); stmt; fflush(stderr); dup2(s_, 2); close(s_); \
                          rewind(t_); size_t k_ = fread(g_err, 1, sizeof g_err - 1, t_); g_err[k_] = 0; fclose(t_); } while (0)

uint64_t now_ns(void) { return 1; }
static uint64_t test_guest;   // the guest clock (hle_os.c guest_ns: frozen while the app is in the background), which the pacing's movie clock runs on
uint64_t guest_ns(void) { return test_guest; }
__thread _Atomic int dm_host_work;   // hle_thread.c
static struct { void *ev; int bound, set; } g_ev[16];
static int ev_slot(void *e) { for (int i = 0; i < 16; i++) if (g_ev[i].ev == e) return i; for (int i = 0; i < 16; i++) if (!g_ev[i].ev) { g_ev[i].ev = e; return i; } abort(); }
void hle_bind_system_event(void *e, int autoclear) { (void)autoclear; g_ev[ev_slot(e)].bound = 1; }
void hle_signal_system_event(void *e) { g_ev[ev_slot(e)].set = 1; }
void hle_clear_system_event(void *e) { g_ev[ev_slot(e)].set = 0; }
static int ev_set(void *e) { return g_ev[ev_slot(e)].set; }
static void destroy_ev(void *e) { g_ev[ev_slot(e)].bound = g_ev[ev_slot(e)].set = 0; }   // nn::os::DestroySystemEvent: closing the handle unbinds the event
void *guest_sym(const char *n) { return !strcmp(n, "_ZN2nn2os18DestroySystemEventEPNS0_15SystemEventTypeE") ? (void *)destroy_ev : NULL; }
static vpx_image_t *black_i420(unsigned w, unsigned h) {
    vpx_image_t *c = vpx_img_alloc(NULL, VPX_IMG_FMT_I420, w, h, 1); if (!c) return NULL;
    memset(c->planes[0], 16, (size_t)c->stride[0] * h);
    memset(c->planes[1], 128, (size_t)c->stride[1] * ((h + 1) / 2)); memset(c->planes[2], 128, (size_t)c->stride[2] * ((h + 1) / 2));
    return c;
}

static const uint8_t vp8[] = {
    0xf0,0x02,0x00,0x9d,0x01,0x2a,0x10,0x00,0x10,0x00,0x00,0x47,0x08,0x85,0x85,0x88,
    0x85,0x84,0x88,0x02,0x02,0x02,0x75,0xaa,0x03,0xf8,0x03,0xfa,0x02,0x0d,0x4d,0x18,
    0x00,0xfe,0xfd,0x6e,0xf3,0xff,0xe3,0x99,0x37,0x30,0xc4,0xff,0x8e,0x6d,0xff,0xf1,
    0x61,0x3c,0x0e,0x28,0xc8,0xff,0xf1,0x51,0x00,
};
static const uint8_t av1[] = {   // one temporal unit: temporal delimiter, sequence header (profile 0, 64x64), frame
    0x12,0x00,0x0a,0x0b,0x02,0x00,0x00,0x04,0x95,0x7f,0xfc,0x0a,0xf9,0x00,0x40,0x32,0x15,0x10,0x00,0xbc,0x00,0x49,0x22,0x08,0x08,0x21,0x10,0x00,0xad,0x3b,0x67,0x00,
    0x1e,0xb5,0xdb,0x79,0x52,0x90,
};
static const uint8_t h264[] = {   // Annex B: SPS, PPS, one IDR slice
    0x00,0x00,0x00,0x01,0x67,0x42,0xc0,0x0a,0xdc,0x42,0x6c,0x04,0x40,0x00,0x00,0x03,0x00,0x40,0x00,0x00,0x0c,0xa3,0xc4,0x89,
    0xe0,0x00,0x00,0x00,0x01,0x68,0xce,0x0f,0xc8,0x00,0x00,0x01,0x65,0x88,0x84,0x3a,0x11,0x8a,0x00,0x02,0x18,0xf1,0xc0,0x00,
    0x40,0xf6,0x38,0x00,0x08,0x79,0x49,0xc9,0xc9,0xd7,0x5d,0x75,0xd7,0x5d,0x75,0xd7,0x5d,0x75,0xe0,
};
static const uint8_t vp9[] = {
    0x82,0x49,0x83,0x42,0x00,0x00,0xf0,0x00,0xf6,0x00,0x38,0x24,0x1c,0x18,0x4a,0x00,
    0x00,0x30,0x60,0x00,0x00,0x10,0xbf,0xff,0xf7,0x1d,0xaf,0xff,0xff,0xff,0x5f,0xdf,
    0xff,0xff,0xff,0xf2,0x2a,0xc0,0x00,
};

// Pacing by the pictures' times (hle_codec_video.c CV_PACE): a player that takes one picture per game frame, as Ocarina of Time's movie library does, at frame_ns of guest time a
// frame, against n pictures of a 60 fps stream (the 16x16 VP9 key frame again and again). It holds bufs buffers, each acquired, waited for, read and released in turn. The feeder sends
// packets while the submission event is up, either until the decoder refuses one (busy: Ocarina of Time's, which kept CV_HOLD pictures waiting) or one packet per signal it
// clears (Mario Tennis Fever's). Frames from bg_from for bg_n run with the guest clock frozen (the app in the background); at frame gap_at the guest clock jumps by gap_ns.
// A picture asked for at a frame's release is shown bufs frames later (the buffers are taken in turn), so that is where the background and the jump show
#define PACE_ITV(k) ((int64_t)(((k) * 1000000000ll + 30) / 60))   // picture k's time (ns)
typedef struct { int frames, shown, starved, mono, eos_last, fps60, bg_skips, gap_jump, max_jump; } pace_res;
static pace_res pace_play(uint64_t frame_ns, int n, int until_busy, int bufs, int bg_from, int bg_n, int gap_at, uint64_t gap_ns) {
    _Alignas(16) static uint8_t pd[0x400], pp[4][0x40], pm[4][16 * 16 * 4];
    memset(pd, 0, sizeof pd);
    cv_pref pf = h_cv_pref(16, 16, 3, 0); uint64_t sz, al; assert(!h_cv_poolsize(&sz, &al, &pf, 1));
    for (int i = 0; i < bufs; i++) assert(!h_cv_pool(pp[i], pm[i], sz, &pf, 1, 0));
    assert(!h_cv_vp9init2(pd, 0x10000, 16, 16, 1, 1, 3, NULL, 0)); void *ev = pd + CV_EVENT_OFF;
    uint32_t idx = 0; cv_sync sy; uint16_t w, h, cw, ch; int64_t ts, last = -1; bool eos;
    for (uint32_t i = 0; i < (uint32_t)bufs; i++) assert(!h_cv_vp9reg(pd, i, pp[i], 0));
    for (int i = 0; i < bufs; i++) { assert(!h_cv_vp9acq(&idx, &sy, pd)); h_cv_vp9rel(pd, idx, sy); }   // every buffer asks for a picture
    pace_res r = {.mono = 1}; int sent = 0, have = 0;
    while (r.frames < 4 * n) {
        r.frames++;
        if (!(r.frames >= bg_from && r.frames < bg_from + bg_n)) test_guest += r.frames == gap_at ? gap_ns : frame_ns;
        while (sent < n && ev_set(ev)) {
            if (!until_busy) hle_clear_system_event(ev);
            uint64_t id; Result x = h_cv_vp9submit(&id, pd, vp9, sizeof vp9, PACE_ITV(sent), sent == n - 1);
            if (x == CV_BUSY) break;
            assert(!x); sent++;
        }
        if (!have) { assert(!h_cv_vp9acq(&idx, &sy, pd)); have = 1; }
        if (!h_gs_trywait(&sy)) { r.starved++; assert(h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, pd, idx) == CV_NONE); continue; }   // its sync handle: not signalled until filled
        assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, pd, idx) && w == 16);
        int jump = last < 0 ? 1 : (int)((ts - last + PACE_ITV(1) / 2) / PACE_ITV(1));   // pictures this frame moved on
        if (last >= 0 && ts <= last) r.mono = 0;
        if (jump > r.max_jump) r.max_jump = jump;
        if (r.frames - bufs >= bg_from && r.frames - bufs < bg_from + bg_n && jump != 1) r.bg_skips++;
        if (r.frames - bufs == gap_at) r.gap_jump = jump;
        last = ts; r.shown++; r.fps60 += dm_movie_fps() == 60;
        if (eos) { r.eos_last = ts == PACE_ITV(n - 1) && sent == n; break; }
        h_cv_vp9rel(pd, idx, sy); have = 0;
    }
    assert(!dm_movie_playing() && !dm_movie_fps());   // the end of stream ended the movie signal
    assert(!h_cv_vp9fin(pd));
    for (int i = 0; i < bufs; i++) h_cv_poolfin(pp[i]);
    return r;
}
// A player that paces itself by the pictures' times (Donkey Kong Bananza's, Mario Tennis Fever's kind): it holds bufs buffers and shows the newest filled picture whose time is at or
// before its own playback clock, giving the older ones back. Its clock starts start_ns after the first picture is filled (it fills its buffers first), and stops for pause_n frames
// from pause_at (a pause menu: the guest clock runs, the player gives nothing back). Returns the distinct pictures it showed; with the host's pacing it must show every one
static int pace_self(uint64_t frame_ns, int64_t itv, int n, int bufs, uint64_t start_ns, int pause_at, int pause_n, uint64_t *skipped) {
    _Alignas(16) static uint8_t pd[0x400], pp[4][0x40], pm[4][16 * 16 * 4];
    memset(pd, 0, sizeof pd);
    cv_pref pf = h_cv_pref(16, 16, 3, 0); uint64_t sz, al; assert(!h_cv_poolsize(&sz, &al, &pf, 1));
    for (int i = 0; i < bufs; i++) assert(!h_cv_pool(pp[i], pm[i], sz, &pf, 1, 0));
    assert(!h_cv_vp9init2(pd, 0x10000, 16, 16, 1, 1, 3, NULL, 0)); void *ev = pd + CV_EVENT_OFF; cv_dec *dd = cv_of(pd);
    uint32_t idx[4]; cv_sync sy[4]; int64_t bts[4]; int full[4] = {0};
    for (uint32_t i = 0; i < (uint32_t)bufs; i++) assert(!h_cv_vp9reg(pd, i, pp[i], 0));
    for (int i = 0; i < bufs; i++) { assert(!h_cv_vp9acq(&idx[i], &sy[i], pd)); h_cv_vp9rel(pd, idx[i], sy[i]); }
    for (int i = 0; i < bufs; i++) assert(!h_cv_vp9acq(&idx[i], &sy[i], pd));
    int sent = 0, shown = 0, started = 0; int64_t cur = -1, play = 0; uint64_t first = 0; uint16_t w, h, cw, ch; int64_t ts; bool eos;
    for (int f = 1; f < 40 * n && cur < (int64_t)(n - 1) * itv; f++) {
        int paused = f >= pause_at && f < pause_at + pause_n;
        test_guest += frame_ns; if (started && !paused) play += (int64_t)frame_ns;
        while (sent < n && ev_set(ev)) { uint64_t id; Result x = h_cv_vp9submit(&id, pd, vp9, sizeof vp9, (int64_t)sent * itv, sent == n - 1); if (x == CV_BUSY) break; assert(!x); sent++; }
        for (int i = 0; i < bufs; i++) if (!full[i] && h_gs_trywait(&sy[i])) { assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, pd, idx[i])); full[i] = 1; bts[i] = ts; if (!first) first = test_guest; }
        if (!started && first && test_guest - first >= start_ns) started = 1;
        if (!started || paused) continue;
        int best = -1; for (int i = 0; i < bufs; i++) if (full[i] && bts[i] <= play && (best < 0 || bts[i] > bts[best])) best = i;
        if (best < 0) continue;
        if (bts[best] != cur) { cur = bts[best]; shown++; }
        for (int i = 0; i < bufs; i++) if (full[i] && bts[i] < bts[best]) { h_cv_vp9rel(pd, idx[i], sy[i]); assert(!h_cv_vp9acq(&idx[i], &sy[i], pd)); full[i] = 0; }
    }
    *skipped = dd->mv_skip;   // before the end of stream's pace line (the last picture is shown while its buffer is held)
    assert(!h_cv_vp9fin(pd));
    for (int i = 0; i < bufs; i++) h_cv_poolfin(pp[i]);
    return shown;
}
static void pace_print(const char *what, const pace_res *r) {
    printf("  %s: %d frames, %d pictures shown, at most %d skipped in a frame, starved %d, monotonic %d, end of stream on the last %d, 60 fps signal %d, %d skips in the background, %d pictures on at the jump\n",
           what, r->frames, r->shown, r->max_jump - 1, r->starved, r->mono, r->eos_last, r->fps60, r->bg_skips, r->gap_jump);
}

// A VideoToolbox session iOS invalidated in the background (hle_movie_avc.c, hle_movie_av1.c; Ocarina of Time's opening movie after the notification panel): with movie_vt_restart the
// session is dropped and a new one starts at the next key frame. The units before it reach no decoder and show the last picture again at their own times; one plain line says
// so, no red one. Off, as before
static const uint8_t h264_p[] = {0x00, 0x00, 0x00, 0x01, 0x41, 0x9a, 0x00, 0x10};   // a non-IDR slice header alone: it must never reach a decoder (vt_fail fails it before)
static const uint8_t av1_inter[] = {0x12, 0x00, 0x32, 0x02, 0x30, 0x00};   // temporal delimiter, then a frame OBU whose header starts show_existing_frame 0, frame_type 1 (inter)
static int red_y(const uint8_t *y, size_t stride, int w, int h) { for (int r = 0; r < h; r++) for (int x = 0; x < w; x++) if (abs(y[(size_t)r * stride + x] - 81) > 4) return 0; return 1; }
static void vt_restart_avc(void) {
    static uint8_t nv12[64 * 64 * 3 / 2]; int64_t pts; int r, calls;
    setenv("DM_MOVIE_RESTART", "1", 1);
    mavc *a = mavc_new(); vt_avc = a;
    assert(!mavc_decode(a, h264, sizeof h264, 0) && a->vs && mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && red_y(nv12, 64, 64, 64));
    // Pictures before the IDR show the last picture taken again, at their own times (STILL(t): the red frame at t, and nothing else queued)
    #define STILL(t) (mavc_queued(a) == 1 && mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && pts == (t) && red_y(nv12, 64, 64, 64))
    vt_fail = 1; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 1000));   // the session died while the app was away: a non-IDR packet finds it
    assert(!r && !a->vs && a->restart && a->restarts == 1 && STILL(1000));
    assert(strstr(g_err, "[movie] AVC: VideoToolbox's session was invalidated") && strstr(g_err, "at the next IDR picture") && !strstr(g_err, "[RED]"));
    calls = vt_calls; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 2000));   // skipped until the IDR: no decoder, the still picture, nothing logged
    assert(!r && vt_calls == calls && !a->vs && STILL(2000) && !g_err[0]);
    assert(!mavc_decode(a, h264_p, sizeof h264_p, 1500) && !mavc_queued(a));   // a picture whose time is before one shown (a B picture): none, the times stay in order
    assert(!mavc_decode(a, h264, sizeof h264, 3000) && a->vs && !a->restart && vt_calls == calls + 1);   // the IDR: a new session from the parameter sets
    assert(mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && pts == 3000 && red_y(nv12, 64, 64, 64));
    vt_fail = 1; LOGGED(r = mavc_decode(a, h264, sizeof h264, 4000));   // found at an IDR: a new session decodes that same picture
    assert(!r && a->vs && !a->restart && a->restarts == 2 && strstr(g_err, "at this IDR picture") && !strstr(g_err, "[RED]"));
    assert(mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && pts == 4000 && red_y(nv12, 64, 64, 64));
    vt_fail = 2; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 5000));   // the error in the callback, the decode returning noErr
    assert(!r && !a->vs && a->restart && !a->lost && a->restarts == 3 && !strstr(g_err, "[RED]") && STILL(5000));
    assert(!mavc_decode(a, h264, sizeof h264, 6000) && a->vs && mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && pts == 6000);
    // iOS refuses the new session (the app still inactive, kVTVideoDecoderNotAvailableNowErr): still waiting for an IDR, so the P pictures after it reach no session that lacks their reference
    vt_fail = 1; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 7000)); assert(!r && !a->vs && a->restart && a->restarts == 4 && STILL(7000));
    vt_create_fail = kVTVideoDecoderNotAvailableNowErr; calls = vt_creates; LOGGED(r = mavc_decode(a, h264, sizeof h264, 8000));
    assert(!r && vt_creates == calls + 1 && !a->vs && a->restart && STILL(8000) && strstr(g_err, "not available yet") && !strstr(g_err, "[RED]"));
    calls = vt_calls; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 9000)); assert(!r && vt_calls == calls && !a->vs && a->restart && STILL(9000) && !g_err[0]);
    assert(!mavc_decode(a, h264, sizeof h264, 10000) && a->vs && !a->restart && mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && pts == 10000 && red_y(nv12, 64, 64, 64));
    vt_fail = 1; vt_create_fail = kVTVideoDecoderNotAvailableNowErr; LOGGED(r = mavc_decode(a, h264, sizeof h264, 11000));   // found at an IDR, and the new session refused: the next IDR
    assert(!r && !a->vs && a->restart && a->restarts == 5 && !strstr(g_err, "[RED]") && STILL(11000));
    LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 12000)); assert(!r && !a->vs && a->restart && STILL(12000));
    assert(!mavc_decode(a, h264, sizeof h264, 13000) && a->vs && !a->restart && mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && pts == 13000);
    vt_fail = 1; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 14000)); assert(a->restart && STILL(14000));   // any other refusal: the old red line, and still the next IDR
    vt_create_fail = kVTVideoDecoderMalfunctionErr; LOGGED(r = mavc_decode(a, h264, sizeof h264, 15000));
    assert(r == -1 && !a->vs && a->restart && strstr(g_err, "[RED] movie: VideoToolbox cannot create an AVC decode session") && STILL(15000));
    LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 16000)); assert(!r && !a->vs && a->restart && STILL(16000));
    assert(!mavc_decode(a, h264, sizeof h264, 17000) && a->vs && !a->restart && mavc_take(a, 0, nv12, 64, 64, &pts) == 1 && pts == 17000);
    mavc_drop(a); assert(!a->last);   // a Flush or Stop: nothing of the old stream is shown again
    #undef STILL
    mavc_free(a);
    // Off (DM_MOVIE_RESTART=0, or a profile without movie_restart): as before, the packet fails with a red line and the session is kept
    setenv("DM_MOVIE_RESTART", "0", 1);
    a = mavc_new(); vt_avc = a;
    assert(!mavc_decode(a, h264, sizeof h264, 0) && mavc_take(a, 0, nv12, 64, 64, &pts) == 1);
    vt_fail = 1; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 1000));
    assert(r == -1 && a->vs && !a->restart && !a->restarts && !a->last && !mavc_queued(a) && strstr(g_err, "[RED] movie: AVC decode submission failed (-12903"));
    vt_fail = 2; LOGGED(r = mavc_decode(a, h264_p, sizeof h264_p, 2000));
    assert(!r && a->vs && !a->lost && !a->restart);   // the callback's error is the old red one (already logged once for this decoder)
    mavc_free(a); vt_avc = NULL;
    unsetenv("DM_MOVIE_RESTART"); assert(movie_vt_restart() == DM_GAME_MOVIE_RESTART);   // without the variable: the profile's movie_restart
    setenv("DM_MOVIE_RESTART", "1", 1); assert(movie_vt_restart()); setenv("DM_MOVIE_RESTART", "0", 1); assert(!movie_vt_restart()); unsetenv("DM_MOVIE_RESTART");
}
// Ocarina of Time's opening after a restart, as its player sees it (CV_PACE: one picture a game frame, 60 fps, packets sent until the decoder refuses one): a key frame, then
// `gap` temporal units the invalidated session cannot decode (the first fails with kVTInvalidSessionErr), then key frames. Returns the frame at which the key frame after the gap
// (picture `gap`) is first shown; *stills the pictures shown before it with a time inside the gap
static int av1_gap_play(int gap, int *stills) {
    _Alignas(16) static uint8_t da[0x400], pp[3][0x40], pm[3][64 * 64 * 4]; memset(da, 0, sizeof da);
    cv_pref pf = h_cv_pref(64, 64, 3, 0); uint64_t sz, al; assert(!h_cv_poolsize(&sz, &al, &pf, 1));
    for (int i = 0; i < 3; i++) assert(!h_cv_pool(pp[i], pm[i], sz, &pf, 1, 0));
    assert(!h_cv_av1tm(da, NULL, 0, 0x10000, 64, 64, 1, 3, 2, 2)); vt_av1 = cv_of(da)->av1;
    uint32_t idx = 0; cv_sync sy; uint16_t w, h, cw, ch; int64_t ts; bool eos;
    for (uint32_t i = 0; i < 3; i++) assert(!h_cv_av1reg(da, i, pp[i], 0));
    for (int i = 0; i < 3; i++) { assert(!h_cv_av1acq(&idx, &sy, da)); h_cv_av1rel(da, idx, sy); }
    int n = gap + 120, sent = 0, have = 0, at = -1; *stills = 0;
    for (int f = 1; f < 4 * n && at < 0; f++) {
        test_guest += 16666667;
        for (int k = 0; k < 8 && sent < n; k++) {
            int key = sent == 0 || sent >= gap; uint64_t id;
            if (sent == 1) vt_fail = 1;
            Result x = h_cv_av1submit(&id, da, key ? av1 : av1_inter, key ? sizeof av1 : sizeof av1_inter, PACE_ITV(sent), sent == n - 1);
            if (x == CV_BUSY) break;
            assert(!x); sent++;
        }
        if (!have) { assert(!h_cv_av1acq(&idx, &sy, da)); have = 1; }
        if (!h_gs_trywait(&sy)) continue;
        assert(!h_cv_av1props(&w, &h, &cw, &ch, &ts, &eos, da, idx) && w == 64);
        if (ts >= PACE_ITV(gap)) at = f; else *stills += ts > 0;
        h_cv_av1rel(da, idx, sy); have = 0;
    }
    assert(!h_cv_av1fin(da)); vt_av1 = NULL;
    for (int i = 0; i < 3; i++) h_cv_poolfin(pp[i]);
    return at;
}
static void vt_restart_av1(void) {
    // Key frames: a sequence header and a key frame; a sequence header beside an inter frame is none
    uint8_t seq_inter[32]; memcpy(seq_inter, av1, 15); memcpy(seq_inter + 15, av1_inter + 2, 4);
    assert(av1_key(av1, sizeof av1) && !av1_key(av1_inter, sizeof av1_inter) && !av1_key(seq_inter, 19) && !av1_key(av1, 2));
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1)) { puts("AV1 session restart: skipped, this Mac has no hardware AV1 decoder"); return; }
    setenv("DM_MOVIE_RESTART", "1", 1); setenv("DM_AV1_DAV1D", "0", 1);
    mav1 *a = mav1_new(); vt_av1 = a; mav1_picture pic; int r, calls;
    assert(mav1_decode(a, av1, sizeof av1, &pic) == 1 && red_y(pic.y, pic.ystride, 64, 64));
    // Units before the key frame show the last picture again (STILL: the red frame), for their own times
    #define STILL (r == 1 && red_y(pic.y, pic.ystride, 64, 64))
    vt_fail = 1; LOGGED(r = mav1_decode(a, av1_inter, sizeof av1_inter, &pic));
    assert(STILL && !a->vs && a->restart && a->restarts == 1 && !a->soft);
    assert(strstr(g_err, "[movie] AV1: VideoToolbox's session was invalidated") && strstr(g_err, "at the next key frame") && !strstr(g_err, "[RED]"));
    calls = vt_calls; LOGGED(r = mav1_decode(a, av1_inter, sizeof av1_inter, &pic)); assert(STILL && vt_calls == calls && !g_err[0]);
    LOGGED(r = mav1_decode(a, seq_inter, 19, &pic)); assert(STILL && vt_calls == calls && !a->vs && a->restart && !g_err[0]);   // a sequence header alone does not start it
    assert(mav1_decode(a, av1, sizeof av1, &pic) == 1 && a->vs && !a->restart && red_y(pic.y, pic.ystride, 64, 64));
    vt_fail = 1; LOGGED(r = mav1_decode(a, av1, sizeof av1, &pic));   // found at a key frame: a new session decodes it
    assert(r == 1 && a->vs && !a->restart && a->restarts == 2 && strstr(g_err, "at this key frame") && !strstr(g_err, "[RED]") && red_y(pic.y, pic.ystride, 64, 64));
    vt_fail = 2; LOGGED(r = mav1_decode(a, av1_inter, sizeof av1_inter, &pic));   // the error in the callback
    assert(STILL && !a->vs && a->restart && !a->lost && a->restarts == 3 && !strstr(g_err, "[RED]"));
    // iOS refuses the new session (the app still inactive, kVTVideoDecoderNotAvailableNowErr): still waiting for a key frame on VideoToolbox, not dav1d for the rest of the movie
    vt_create_fail = kVTVideoDecoderNotAvailableNowErr; calls = vt_creates; LOGGED(r = mav1_decode(a, av1, sizeof av1, &pic));
    assert(STILL && vt_creates == calls + 1 && !a->vs && a->restart && !a->soft && strstr(g_err, "not available yet") && !strstr(g_err, "[RED]"));
    calls = vt_calls; LOGGED(r = mav1_decode(a, av1_inter, sizeof av1_inter, &pic)); assert(STILL && vt_calls == calls && !a->vs && a->restart && !g_err[0]);
    assert(mav1_decode(a, av1, sizeof av1, &pic) == 1 && a->vs && !a->restart && !a->soft && red_y(pic.y, pic.ystride, 64, 64));
    vt_fail = 1; vt_create_fail = kVTVideoDecoderNotAvailableNowErr; LOGGED(r = mav1_decode(a, av1, sizeof av1, &pic));   // found at a key frame, and the new session refused
    assert(STILL && !a->vs && a->restart && !a->soft && a->restarts == 4 && !strstr(g_err, "[RED]"));
    assert(mav1_decode(a, av1, sizeof av1, &pic) == 1 && a->vs && !a->restart && !a->soft);
    #undef STILL
    mav1_reset(a); assert(!a->restart && !a->last);   // a new stream (Stop / Flush) starts as before, with no picture to show again
    mav1_free(a);
    // Through nn::codec (hle_codec_video.c), as Ocarina of Time's opening: the last picture again for each unit until the key frame, each held for a buffer, and no red line
    _Alignas(16) static uint8_t da[0x400]; memset(da, 0, sizeof da); uint64_t id;
    assert(!h_cv_av1tm(da, NULL, 0, 0x10000, 64, 64, 1, 3, 2, 2) && cv_of(da)); vt_av1 = cv_of(da)->av1;
    assert(!h_cv_av1submit(&id, da, av1, sizeof av1, 0, false) && cv_of(da)->nheld == 1);
    vt_fail = 1; LOGGED(assert(!h_cv_av1submit(&id, da, av1_inter, sizeof av1_inter, 16666667, false))); assert(cv_of(da)->nheld == 2 && cv_of(da)->held_ts[1] == 16666667 && !strstr(g_err, "[RED]"));
    assert(!h_cv_av1submit(&id, da, av1_inter, sizeof av1_inter, 33333333, false) && cv_of(da)->nheld == 3 && cv_of(da)->held_ts[2] == 33333333);
    assert(!h_cv_av1submit(&id, da, av1, sizeof av1, 50000000, false) && cv_of(da)->nheld == 4 && cv_of(da)->held_ts[3] == 50000000);
    assert(!h_cv_av1fin(da)); vt_av1 = NULL;
    // The gap at real speed: the units before the key frame repeat the last picture at their own times, so the player's clock runs through them and the key frame comes on time
    // (before, they gave no picture: sent at once, the clock stopped while the buffers waited, and the key frame 1 s on was shown at frame 8, the movie 1 s ahead of the game's sound)
    int stills, at; LOGGED(at = av1_gap_play(60, &stills));
    printf("  restart gap of 1 s through nn::codec: the key frame after it shown at frame %d, %d still pictures before it\n", at, stills);
    assert(at >= 60 && at <= 66 && stills >= 50 && !strstr(g_err, "[RED]"));
    // Off: as before
    setenv("DM_MOVIE_RESTART", "0", 1);
    a = mav1_new(); vt_av1 = a;
    assert(mav1_decode(a, av1, sizeof av1, &pic) == 1);
    vt_fail = 1; LOGGED(r = mav1_decode(a, av1_inter, sizeof av1_inter, &pic));
    assert(r == -1 && a->vs && !a->restart && !a->restarts && !a->last && strstr(g_err, "[RED] movie: AV1 decode submission failed (-12903"));
    mav1_free(a); vt_av1 = NULL;
    unsetenv("DM_MOVIE_RESTART"); unsetenv("DM_AV1_DAV1D");
}

int main(void) {
    _Alignas(16) static uint8_t dec[0x400], pool[3][0x40], spt[0x80], mem[16 * 16 * 4];
    uint64_t size, align, id; uint32_t idx; cv_sync sync; uint16_t w, h, cw, ch; int64_t ts; bool eos;

    // Pools: one picture each, NV12 (format 3, as Bananza asks)
    cv_pref pref = h_cv_pref(16, 16, 3, 0);
    assert(!h_cv_poolsize(&size, &align, &pref, 1) && size >= 16 * 16 * 4 && align == CV_NATIVE_ALIGN);
    for (int i = 0; i < 3; i++) assert(!h_cv_pool(pool[i], mem, size, &pref, 1, 0) && pool_of(pool[i]));

    // Decoder: the submission-ready event is bound in its type and signalled
    assert(!h_cv_vp9init2(dec, 0x10000, 16, 16, 1, 1, 3, NULL, 0));
    cv_dec *d = cv_of(dec); assert(d && d->vpx_ok);
    void *ev = NULL; assert(!h_cv_vp9event(&ev, dec) && ev == dec + CV_EVENT_OFF && g_ev[ev_slot(ev)].bound && ev_set(ev));

    // Registering makes a buffer acquirable at once, its sync handle signalled; an empty queue answers 3604
    for (uint32_t i = 0; i < 2; i++) assert(!h_cv_vp9reg(dec, i, pool[i], 0));
    for (uint32_t i = 0; i < 2; i++) { assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == i && sync.magic == CV_SYNC && sync.gen == 0 && h_gs_trywait(&sync)); }
    assert(h_cv_vp9acq(&idx, &sync, dec) == CV_NONE);
    assert(h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) == CV_NONE);

    // Released: acquirable again with a new handle that signals once a picture is in the buffer; the picture's properties and its NV12 / RGBA readback
    h_cv_vp9rel(dec, 0, sync);
    assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 0 && sync.gen == 1 && !h_gs_trywait(&sync));
    assert(h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) == CV_NONE);
    assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 1000, false) && id == 1);
    assert(h_gs_trywait(&sync));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 0) && w == 16 && h == 16 && cw == 16 && ch == 16 && ts == 1000 && !eos);
    uint32_t cs = 7; w = h = 0;   // SDK 19's form: the same properties, and colour space 0
    assert(!h_cv_vp9props19(&w, &h, &cw, &ch, &cs, &ts, &eos, dec, 0) && w == 16 && h == 16 && ts == 1000 && !eos && cs == 0);
    uint8_t nv12[16 * 16 * 3 / 2], rgba[16 * 16 * 4];
    assert(!h_cv_nv12(pool[0], 0, 0, 0, 16, 16, nv12, 16, 256, nv12 + 256, 16, 128));
    for (int i = 0; i < 256; i++) assert(abs(nv12[i] - 81) <= 3);
    for (int i = 256; i < 384; i += 2) { assert(abs(nv12[i] - 90) <= 3); assert(abs(nv12[i + 1] - 240) <= 3); }
    uint8_t y[256], uv[128];   // separate planes
    assert(!h_cv_nv12(pool[0], 0, 0, 0, 16, 16, y, 16, 256, uv, 16, 128) && !memcmp(y, nv12, 256) && !memcmp(uv, nv12 + 256, 128));
    assert(!h_cv_rgba(pool[0], 0, 0, 0, 16, 16, rgba, 64, sizeof rgba));
    for (int i = 0; i < 1024; i += 4) assert(rgba[i] >= 250 && rgba[i + 1] <= 5 && rgba[i + 2] <= 5 && rgba[i + 3] == 255);

    // No released buffer: pictures wait; the event goes down at CV_READY, with room left for a client's signal in flight, and packets are refused (3603) at CV_HOLD
    for (int i = 0; i < CV_READY; i++) assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 2000 + i, false));
    assert(d->nheld == CV_READY && !ev_set(ev));
    for (int i = CV_READY; i < CV_HOLD; i++) assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 2000 + i, false));
    assert(d->nheld == CV_HOLD && !ev_set(ev));
    assert(h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 9999, false) == CV_BUSY);
    // A release takes the oldest; the event comes back below CV_READY
    for (int i = CV_HOLD; i > CV_READY; i--) { h_cv_vp9rel(dec, 1, sync); assert(d->nheld == i - 1 && !ev_set(ev)); assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 1); }
    h_cv_vp9rel(dec, 1, sync);
    assert(d->nheld == CV_READY - 1 && ev_set(ev));
    assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 1 && h_gs_trywait(&sync));
    // Start signals it again: a client may drop the signal Initialize gave
    hle_clear_system_event(ev); assert(!ev_set(ev));
    assert(!h_cv_vp9start(dec) && ev_set(ev));
    // A release below CV_READY with no packet taken signals nothing: a client counts each signal as one packet it may send. A packet taken does
    hle_clear_system_event(ev);
    h_cv_vp9rel(dec, 1, sync); assert(d->nheld == CV_READY - 2 && !ev_set(ev));
    assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 1);
    assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 2000 + CV_HOLD, false) && d->nheld == CV_READY - 1 && ev_set(ev));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 1) && ts == 2000 + CV_HOLD - CV_READY + 1);

    // Sync point event: armed on an unfilled buffer, signalled when the picture lands; one armed on a filled buffer is signalled at once
    assert(!h_spt_create(spt) && g_ev[ev_slot(spt)].bound);
    h_cv_vp9rel(dec, 0, sync);   // buffer 0 takes the next waiting picture at once
    assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 0);
    assert(!h_spt_request(spt, &sync) && ev_set(spt) && !SPT(spt)->armed);
    assert(!h_cv_vp9reg(dec, 2, pool[2], 0) && !h_cv_vp9acq(&idx, &sync, dec) && idx == 2);
    for (int i = 0; i < 2; i++) { h_cv_vp9rel(dec, (uint32_t)i, sync); assert(!h_cv_vp9acq(&idx, &sync, dec)); }   // the last two waiting pictures go out
    h_cv_vp9rel(dec, 2, sync); assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 2 && !h_gs_trywait(&sync));
    assert(!h_spt_request(spt, &sync) && !ev_set(spt) && SPT(spt)->armed);
    assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 3000, false) && ev_set(spt) && !SPT(spt)->armed && h_gs_trywait(&sync));

    // End of stream with no data: the next released buffer carries it, with no picture
    assert(!h_cv_vp9submit(&id, dec, NULL, 0, 0, true) && d->eos_pending);
    h_cv_vp9rel(dec, 2, sync); assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 2 && h_gs_trywait(&sync));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 2) && eos && w == 0 && h == 0);

    // A pool finalized while its buffer is still registered: the buffer keeps working, its picture has nowhere to go (ASan checks no freed pool is written)
    h_cv_poolfin(pool[1]); assert(!pool_of(pool[1]) && d->buf[1].pool == NULL);
    h_cv_vp9rel(dec, 1, sync); assert(!h_cv_vp9acq(&idx, &sync, dec) && idx == 1 && !h_gs_trywait(&sync));
    assert(!h_cv_vp9submit(&id, dec, vp9, sizeof vp9, 4000, false) && h_gs_trywait(&sync));
    assert(!h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, dec, 1) && ts == 4000 && w == 16);
    // A flush drops the waiting pictures and restarts the decoder; finalize frees it and destroys its event
    assert(!h_cv_vp9flush(dec) && d->nheld == 0 && d->vpx_ok && ev_set(ev));
    assert(!h_cv_vp9fin(dec) && !cv_of(dec) && !g_ev[ev_slot(ev)].bound);
    // A decoder initialised again in the same memory, cleared in between (Donkey Kong Bananza's second movie): its event is bound anew
    memset(dec, 0, sizeof dec);
    assert(!h_cv_vp9init2(dec, 0x10000, 16, 16, 1, 1, 3, NULL, 0) && cv_of(dec) && g_ev[ev_slot(ev)].bound && ev_set(ev));
    assert(!h_cv_vp9fin(dec) && !cv_of(dec) && !g_ev[ev_slot(ev)].bound);
    for (int i = 0; i < 3; i += 2) { h_cv_poolfin(pool[i]); assert(!pool_of(pool[i])); }
    // VP8 (libvpx) and H.264 (VideoToolbox) take the same protocol: one released buffer, one key frame, its picture read back red
    {   _Alignas(16) static uint8_t d8[0x400], p8[0x40], m8[16 * 16 * 4];
        assert(!h_cv_poolsize(&size, &align, &pref, 1) && !h_cv_pool(p8, m8, size, &pref, 1, 0));
        assert(!h_cv_vp8init2(d8, 0x10000, 16, 16, 1, 1, 3, NULL, 0) && cv_of(d8) && cv_of(d8)->codec == CV_VP8 && cv_of(d8)->vpx_ok);
        assert(!h_cv_vp8reg(d8, 0, p8, 0) && !h_cv_vp8acq(&idx, &sync, d8) && idx == 0);
        h_cv_vp8rel(d8, 0, sync); assert(!h_cv_vp8acq(&idx, &sync, d8) && !h_gs_trywait(&sync));
        assert(!h_cv_vp8submit(&id, d8, vp8, sizeof vp8, 7000, false) && h_gs_trywait(&sync));
        assert(!h_cv_vp8props(&w, &h, &cw, &ch, &ts, &eos, d8, 0) && w == 16 && h == 16 && ts == 7000);
        assert(!h_cv_nv12(p8, 0, 0, 0, 16, 16, nv12, 16, 256, nv12 + 256, 16, 128));
        for (int i = 0; i < 256; i++) assert(abs(nv12[i] - 81) <= 3);
        for (int i = 256; i < 384; i += 2) { assert(abs(nv12[i] - 90) <= 4); assert(abs(nv12[i + 1] - 240) <= 4); }
        // Unregistered: no longer acquirable or filled
        h_cv_vp8rel(d8, 0, sync); assert(!h_cv_vp8unreg(d8, 0) && h_cv_vp8acq(&idx, &sync, d8) == CV_NONE && !cv_of(d8)->buf[0].reg);
        assert(!h_cv_vp8fin(d8) && !cv_of(d8)); h_cv_poolfin(p8);
    }
    {   _Alignas(16) static uint8_t dh[0x400], ph[0x40], mh[64 * 64 * 4]; static uint8_t yuv[64 * 64 * 3 / 2];
        cv_pref p64 = h_cv_pref(64, 64, 3, 0);
        assert(!h_cv_poolsize(&size, &align, &p64, 1) && !h_cv_pool(ph, mh, size, &p64, 1, 0));
        assert(!h_cv_h264init2(dh, 0x10000, 64, 64, 1, 1, 3, NULL, 0) && cv_of(dh) && cv_of(dh)->codec == CV_H264 && cv_of(dh)->avc);
        assert(!h_cv_h264reg(dh, 0, ph, 0) && !h_cv_h264acq(&idx, &sync, dh));
        h_cv_h264rel(dh, 0, sync); assert(!h_cv_h264acq(&idx, &sync, dh) && !h_gs_trywait(&sync));
        assert(!h_cv_h264submit(&id, dh, h264, sizeof h264, 5000000, true) && h_gs_trywait(&sync));   // end of stream: VideoToolbox gives its picture out
        assert(!h_cv_h264props(&w, &h, &cw, &ch, &ts, &eos, dh, 0) && w == 64 && h == 64 && ts == 5000000 && eos);
        assert(!h_cv_nv12(ph, 0, 0, 0, 64, 64, yuv, 64, 4096, yuv + 4096, 64, 2048));
        for (int i = 0; i < 4096; i++) assert(abs(yuv[i] - 81) <= 4);
        for (int i = 4096; i < 6144; i += 2) { assert(abs(yuv[i] - 90) <= 6); assert(abs(yuv[i + 1] - 240) <= 6); }
        assert(!h_cv_h264fin(dh) && !cv_of(dh)); h_cv_poolfin(ph);
    }
    {   // AV1: a decoder of its own codec through SDK 22's entry point, whose last two arguments lie on the stack (the guest's 8-byte slots), and a packet with no sequence header yet gives no picture
        uint8_t da[0x400]; memset(da, 0, sizeof da);
        assert(!h_cv_av1tm(da, NULL, 0, 0x10000, 0xabcd0080, 0xabcd0040, 1, 3, 2, 2) && cv_of(da) && cv_of(da)->codec == CV_AV1 && cv_of(da)->w == 0x80 && cv_of(da)->h == 0x40);
        assert(h_cv_av1ev22(da) == da + CV_EVENT_OFF && ev_set(da + CV_EVENT_OFF));
        static const uint8_t delimiter[] = {0x12, 0x00};   // a temporal delimiter OBU alone
        uint64_t n; assert(!h_cv_av1submit(&n, da, delimiter, sizeof delimiter, 0, false) && !cv_of(da)->nheld);
        assert(!h_cv_av1fin(da) && !cv_of(da));
        // The av1C record from a sequence header: profile 0, one operating point at level 12 (tier 0), 2560x1440, 8-bit 4:2:0 with chroma position 0, written field by field
        uint8_t obu[32] = {0x0a, 0}; size_t bit = 16;
        #define PUT(v, nb) do { for (int k_ = (nb) - 1; k_ >= 0; k_--, bit++) if (((uint32_t)(v) >> k_) & 1) obu[bit / 8] |= (uint8_t)(0x80 >> (bit % 8)); } while (0)
        PUT(0, 3); PUT(0, 1); PUT(0, 1);            // profile, still picture, reduced header
        PUT(0, 1); PUT(0, 1); PUT(0, 5);            // no timing info, no display delay, one operating point
        PUT(0, 12); PUT(12, 5); PUT(0, 1);          // idc, level 12, tier
        PUT(11, 4); PUT(10, 4); PUT(2559, 12); PUT(1439, 11);   // frame size bits and frame size
        PUT(0, 1); PUT(0, 3); PUT(0, 4);            // no frame ids, block tools, inter tools
        PUT(1, 1); PUT(0, 2);                       // order hint, jnt_comp and ref_frame_mvs
        PUT(1, 1); PUT(1, 1);                       // screen content tools: choose; integer mv: choose
        PUT(6, 3); PUT(0, 3);                       // order hint bits, superres / cdef / restoration
        PUT(0, 1); PUT(0, 1); PUT(0, 1);            // not high bit depth, not monochrome, no colour description
        PUT(0, 1); PUT(0, 2); PUT(0, 1);            // colour range, chroma position, separate delta q
        #undef PUT
        obu[1] = (uint8_t)((bit + 7) / 8 - 2);
        uint8_t c[4]; int aw = 0, ah = 0;
        assert(mav1_av1c(obu, (bit + 7) / 8, c, &aw, &ah) && aw == 2560 && ah == 1440);
        assert(c[0] == 0x81 && c[1] == 12 && c[2] == 0x0c && c[3] == 0);
        size_t seqn = 0; assert(find_seq(obu, (bit + 7) / 8, &seqn) == obu && seqn == (bit + 7) / 8);
        assert(!mav1_av1c(delimiter, sizeof delimiter, c, &aw, &ah) && !find_seq(delimiter, sizeof delimiter, &seqn));
        // The red frame on each backend this Mac has (VideoToolbox where the chip decodes AV1, and dav1d, which DM_AV1_DAV1D=1 picks), as NV12: Y 81, Cb 90, Cr 240 (BT.601, video range)
        for (int soft = VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1) ? 0 : 1; soft < 2; soft++) {
            setenv("DM_AV1_DAV1D", soft ? "1" : "0", 1);
            mav1 *a = mav1_new(); assert(!strcmp(mav1_backend(a), soft ? "dav1d" : "VideoToolbox"));
            mav1_picture pic; assert(mav1_decode(a, av1, sizeof av1, &pic) == 1 && pic.w == 64 && pic.h == 64 && pic.matrix == 1 && !pic.full_range);   // no matrix in the stream: BT.601 at 64 lines
            for (int y = 0; y < 64; y++) for (int x = 0; x < 64; x++) assert(abs(pic.y[(size_t)y * pic.ystride + x] - 81) <= 4);
            for (int y = 0; y < 32; y++) for (int x = 0; x < 64; x += 2) { assert(abs(pic.uv[(size_t)y * pic.uvstride + x] - 90) <= 6); assert(abs(pic.uv[(size_t)y * pic.uvstride + x + 1] - 240) <= 6); }
            mav1_reset(a); assert(mav1_decode(a, delimiter, sizeof delimiter, &pic) == 0);   // a new stream: nothing until its sequence header
            mav1_free(a);
        }
        unsetenv("DM_AV1_DAV1D");
    }
    {   // A native image: SDK 22's preference and pool, the handle names the pool's memory, and a picture lands there as RGBA in NVN's linear layout
        cv_pref p = h_cv_pref22(0xffff0020, 0xffff0010, 2, 2); assert(p.w == 32 && p.h == 16);
        uint64_t sz, al; assert(!h_cv_poolsize(&sz, &al, &p, 2) && al == CV_NATIVE_ALIGN && sz == 2 * CV_NATIVE_ALIGN);
        uint8_t pt[0x40] = {0}; void *m; assert(!posix_memalign(&m, al, sz)); memset(m, 0, sz);
        assert(!h_cv_pool22(pt, m, sz, &p, 2));
        uint32_t ha = h_cv_native(pt, 1), nw, nh, ns; uint8_t *nm = NULL; uint64_t nz;
        assert(ha && dm_native_image(ha, &nm, &nz, &nw, &nh, &ns) && nm == (uint8_t *)m + CV_NATIVE_ALIGN && nz == CV_NATIVE_ALIGN && nw == 32 && nh == 16 && ns == 128);
        vpx_image_t *im = black_i420(32, 16); im->range = VPX_CR_STUDIO_RANGE;
        pool_native_write(pool_of(pt), 1, im); vpx_img_free(im);
        assert(nm[0] == 0 && nm[3] == 255 && nm[ns * 15 + 31 * 4 + 3] == 255);
        h_cv_poolfin(pt); assert(!dm_native_image(ha, &nm, &nz, &nw, &nh, &ns)); free(m);
    }
    {   // SDK 19's Initialize by remote memory (two sizes before the picture size) and its preference: a VP9 decoder as the other forms make
        _Alignas(16) static uint8_t d19[0x400];
        cv_pref p19 = h_cv_pref19(0xffff0000u | 64, 32, 3, 1);   // the 16-bit sizes come unextended
        assert(p19.w == 64 && p19.h == 32 && p19.fmt == 3 && p19.magic == CV_MAGIC);
        assert(!h_cv_vp9rm19(d19, 0x10000, 0x200000, 0xabcd0000u | 16, 16, 1, 1, 3) && cv_of(d19) && cv_of(d19)->w == 16);
        assert(!h_cv_vp9fin(d19));
    }
    {   // Blank native images (GameChat's camera pictures with no camera): zeroed storage with room for 16 bytes a pixel, apart from the decoder pools' handles, gone once freed
        uint32_t a = dm_native_image_blank(384, 216), b = dm_native_image_blank(384, 216), nw, nh, ns; uint8_t *nm = NULL; uint64_t nz;
        assert(a && b && a != b && a >> 31 && b >> 31);
        assert(dm_native_image(a, &nm, &nz, &nw, &nh, &ns) && nw == 384 && nh == 216 && ns >= 384 * 16 && ns % 64 == 0 && nz >= (uint64_t)ns * 216);
        for (uint64_t k = 0; k < nz; k++) assert(!nm[k]);
        dm_native_image_blank_free(a); assert(!dm_native_image(a, &nm, &nz, &nw, &nh, &ns)); assert(dm_native_image(b, &nm, &nz, &nw, &nh, &ns));
        dm_native_image_blank_free(b); dm_native_image_blank_free(b); dm_native_image_blank_free(0x100);   // twice, and a decoder pool's handle: nothing happens
        uint32_t k[BLANK_MAX + 1]; for (int i = 0; i < BLANK_MAX; i++) assert((k[i] = dm_native_image_blank(32, 32)));
        assert(!(k[BLANK_MAX] = dm_native_image_blank(32, 32)));   // full
        for (int i = 0; i < BLANK_MAX; i++) dm_native_image_blank_free(k[i]);
    }
    {   // Pacing: a 60 fps movie of 600 pictures (10 s) against a player that takes a picture a game frame
        const int n = 600;
        pace_res r = pace_play(33333333, n, 1, 2, 0, 0, 0, 0); pace_print("30 Hz", &r);
        assert(r.mono && r.eos_last && !r.starved && r.max_jump <= 3);
        assert(r.shown >= n / 2 - 6 && r.shown <= n / 2 + 6);                   // about half skipped
        assert(r.frames >= n / 2 - 6 && r.frames <= n / 2 + 6);                  // the movie takes its own 10 s, not 20
        assert(r.fps60 >= r.shown - 6);   // the frame step's movie signal says 60 pictures a second (from the 8th picture decoded)
        r = pace_play(27777778, n, 1, 2, 0, 0, 0, 0); pace_print("36 Hz", &r);   // the iPhone's 36 fps
        assert(r.mono && r.eos_last && !r.starved && r.max_jump <= 3);
        assert(r.shown >= n * 6 / 10 - 6 && r.shown <= n * 6 / 10 + 6);          // 40% skipped
        assert(r.frames >= n * 6 / 10 - 6 && r.frames <= n * 6 / 10 + 6);
        r = pace_play(16666667, n, 1, 2, 0, 0, 0, 0); pace_print("60 Hz", &r);   // a game at the movie's rate: every picture, in order
        assert(r.mono && r.eos_last && !r.starved && r.shown >= n - 3 && r.max_jump <= 2);
        // The feeder that sends one packet per signal keeps 4 pictures waiting, not 12: at 30 Hz and at 15 Hz (4 pictures a frame) no frame waits for its picture
        r = pace_play(33333333, n, 0, 2, 0, 0, 0, 0); pace_print("30 Hz, one packet per signal", &r);
        assert(r.mono && r.eos_last && !r.starved && r.shown >= n / 2 - 6 && r.shown <= n / 2 + 6);
        r = pace_play(66666667, n, 0, 2, 0, 0, 0, 0); pace_print("15 Hz, one packet per signal", &r);
        assert(r.mono && r.eos_last && !r.starved && r.frames >= n / 4 - 6 && r.frames <= n / 4 + 6);
        // Four buffers in flight, as a player that asks ahead
        r = pace_play(33333333, n, 1, 4, 0, 0, 0, 0); pace_print("30 Hz, four buffers", &r);
        assert(r.mono && r.eos_last && !r.starved && r.frames >= n / 2 - 6 && r.frames <= n / 2 + 6);
        // The app in the background for 60 frames (the guest clock frozen): the clock waits, each of those frames takes the next picture
        r = pace_play(33333333, n, 1, 2, 100, 60, 0, 0); pace_print("30 Hz, 60 frames in the background", &r);
        assert(r.mono && r.eos_last && !r.starved && !r.bg_skips && r.frames >= n / 2 + 30 - 6 && r.frames <= n / 2 + 30 + 6);
        // A player that stops asking for 2 s (a pause, a load): the clock does not run across a gap of CV_PACE_GAP or more (the movie takes its 10 s plus the stall frame).
        // A 0.2 s hitch is run through: the movie still takes 10 s, the 12 pictures caught up over the next frames (about 4 wait at a time)
        r = pace_play(33333333, n, 1, 2, 0, 0, 200, 2000000000ull); pace_print("30 Hz, a 2 s stall", &r);
        assert(r.mono && r.eos_last && !r.starved && r.gap_jump == 1 && r.frames >= n / 2 - 5 && r.frames <= n / 2 + 7);
        r = pace_play(33333333, n, 1, 2, 0, 0, 200, 200000000ull); pace_print("30 Hz, a 0.2 s hitch", &r);
        assert(r.mono && r.eos_last && !r.starved && r.gap_jump >= 2 && r.frames >= n / 2 - 6 - 6 && r.frames <= n / 2);
        // A player that paces itself by the pictures' times loses no picture to the host's pacing: starting 0.2 s after its buffers are filled (the clock started at the first
        // hand-out ran that far ahead of it, and a 30 fps movie showed 102 of 300 pictures), after a 1 s pause (0.25 s ahead: 135 of 300), at 24 and 60 fps
        uint64_t sk; int shown;
        shown = pace_self(16666667, 33333333, 300, 4, 200000000, 0, 0, &sk); printf("  self-paced, 30 fps, started 0.2 s late: %d of 300 shown, %llu skipped\n", shown, (unsigned long long)sk); assert(shown == 300 && !sk);
        shown = pace_self(16666667, 33333333, 300, 4, 0, 100, 60, &sk); printf("  self-paced, 30 fps, a 1 s pause: %d of 300 shown, %llu skipped\n", shown, (unsigned long long)sk); assert(shown == 300 && !sk);
        shown = pace_self(16666667, 41666667, 240, 4, 200000000, 0, 0, &sk); printf("  self-paced, 24 fps, started 0.2 s late: %d of 240 shown, %llu skipped\n", shown, (unsigned long long)sk); assert(shown == 240 && !sk);
        shown = pace_self(16666667, PACE_ITV(1), 600, 3, 100000000, 0, 0, &sk); printf("  self-paced, 60 fps, started 0.1 s late: %d of 600 shown, %llu skipped\n", shown, (unsigned long long)sk); assert(shown == 600 && !sk);
        shown = pace_self(33333333, PACE_ITV(1), 600, 4, 0, 0, 0, &sk); printf("  self-paced at 30 Hz, 60 fps: %d of 600 shown, %llu skipped\n", shown, (unsigned long long)sk); assert(shown >= 295 && shown <= 305);
        // DM_CODEC_PACE=0: every picture in order, as before
        setenv("DM_CODEC_PACE", "0", 1);
        r = pace_play(33333333, n, 1, 2, 0, 0, 0, 0); pace_print("30 Hz, DM_CODEC_PACE=0", &r);
        assert(r.mono && r.eos_last && !r.starved && r.shown == n && r.frames == n && r.max_jump == 1 && r.fps60 >= n - 6);
        unsetenv("DM_CODEC_PACE");
    }
    {   // A flush starts the clock again: a new stream from time 0 hands out its first picture, not the picture the old clock is at
        _Alignas(16) static uint8_t fd[0x400], fp[0x40], fm[16 * 16 * 4];
        cv_pref pf = h_cv_pref(16, 16, 3, 0); uint64_t sz, al; assert(!h_cv_poolsize(&sz, &al, &pf, 1) && !h_cv_pool(fp, fm, sz, &pf, 1, 0));
        assert(!h_cv_vp9init2(fd, 0x10000, 16, 16, 1, 1, 3, NULL, 0)); cv_dec *fdd = cv_of(fd);
        assert(!h_cv_vp9reg(fd, 0, fp, 0) && !h_cv_vp9acq(&idx, &sync, fd)); h_cv_vp9rel(fd, 0, sync);
        for (int k = 0; k < 8; k++) assert(!h_cv_vp9submit(&id, fd, vp9, sizeof vp9, PACE_ITV(k), false));
        assert(!h_cv_vp9acq(&idx, &sync, fd) && h_gs_trywait(&sync) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == 0);
        test_guest += 16666667; h_cv_vp9rel(fd, 0, sync);   // picture 0 given back: the clock starts at its time, and picture 1 is next
        assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(1) && fdd->pace_run && !fdd->mv_skip);
        test_guest += 100000000; h_cv_vp9rel(fd, 0, sync);   // 100 ms on: pictures 2-5 skipped, picture 6 handed out
        assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(6) && fdd->mv_skip == 4 && dm_movie_fps() == 60);
        assert(!h_cv_vp9flush(fd) && !dm_movie_playing() && !fdd->pace_on);   // the flush ends the movie signal and the clock
        h_cv_vp9rel(fd, 0, sync); test_guest += 100000000;   // the old stream's picture given back starts no clock
        for (int k = 0; k < 8; k++) assert(!h_cv_vp9submit(&id, fd, vp9, sizeof vp9, PACE_ITV(k), false));
        assert(!h_cv_vp9acq(&idx, &sync, fd) && h_gs_trywait(&sync) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == 0 && !fdd->pace_run);
        test_guest += 33333333; h_cv_vp9rel(fd, 0, sync);
        assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(1));
        test_guest += 66666667; h_cv_vp9rel(fd, 0, sync);
        assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(4));
        // Times that start again without a flush (a looped stream) start a new clock too
        assert(!h_cv_vp9flush(fd));
        for (int k = 0; k < 3; k++) assert(!h_cv_vp9submit(&id, fd, vp9, sizeof vp9, PACE_ITV(100 + k), false));
        h_cv_vp9rel(fd, 0, sync); assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(100));
        test_guest += 33333333;
        for (int k = 0; k < 3; k++) assert(!h_cv_vp9submit(&id, fd, vp9, sizeof vp9, PACE_ITV(k), false));   // back to time 0 behind 101 and 102
        h_cv_vp9rel(fd, 0, sync); assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(101));
        test_guest += 100000000;
        h_cv_vp9rel(fd, 0, sync); assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(102));   // never across the drop in times
        test_guest += 33333333;
        h_cv_vp9rel(fd, 0, sync); assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == 0);   // the new times' first picture
        test_guest += 100000000;
        h_cv_vp9rel(fd, 0, sync); assert(!h_cv_vp9acq(&idx, &sync, fd) && !h_cv_vp9props(&w, &h, &cw, &ch, &ts, &eos, fd, 0) && ts == PACE_ITV(1));   // a new clock, from picture 0's time
        assert(!h_cv_vp9fin(fd) && !dm_movie_playing()); h_cv_poolfin(fp);
    }
    {   // Two decoders at once (a title movie's decoder finalized while the next movie plays): the movie signal stays until the last one stops
        _Alignas(16) static uint8_t td[2][0x400], tp[2][0x40], tm[2][16 * 16 * 4];
        cv_pref pf = h_cv_pref(16, 16, 3, 0); uint64_t sz, al; assert(!h_cv_poolsize(&sz, &al, &pf, 1));
        for (int j = 0; j < 2; j++) {
            assert(!h_cv_pool(tp[j], tm[j], sz, &pf, 1, 0) && !h_cv_vp9init2(td[j], 0x10000, 16, 16, 1, 1, 3, NULL, 0));
            assert(!h_cv_vp9reg(td[j], 0, tp[j], 0) && !h_cv_vp9acq(&idx, &sync, td[j])); h_cv_vp9rel(td[j], 0, sync);
            for (int k = 0; k < 9; k++) assert(!h_cv_vp9submit(&id, td[j], vp9, sizeof vp9, PACE_ITV(k), false));
            assert(!h_cv_vp9acq(&idx, &sync, td[j])); h_cv_vp9rel(td[j], 0, sync);   // the second picture, handed out with 9 decoded: the signal is up
        }
        assert(dm_movie_fps() == 60 && g_cv_sig == 2);
        assert(!h_cv_vp9fin(td[0]) && dm_movie_playing() && dm_movie_fps() == 60);   // the first one's end does not end the second one's movie
        assert(!h_cv_vp9fin(td[1]) && !dm_movie_playing() && !g_cv_sig);
        for (int j = 0; j < 2; j++) h_cv_poolfin(tp[j]);
    }
    vt_restart_avc(); vt_restart_av1();
    puts("VideoToolbox session restart: an invalidated session is dropped, the units before the next key frame skipped, one plain line; off, the red line as before");
    printf("t_codec_video: all passed\n");
    return 0;
}
