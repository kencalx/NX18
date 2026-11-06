// A VideoToolbox decode session made again after it was lost (hle_movie_avc.c for H.264, hle_movie_av1.c for AV1; both decoder APIs use them, hle_movie.c and hle_codec_video.c).
// iOS suspends the whole app when it leaves the foreground (front_ios.m), and a session that was decoding can then answer kVTInvalidSessionErr (-12903) from then on, or
// kVTVideoDecoderMalfunctionErr (-12911): WebRTC's iOS decoder makes its session again on exactly these two ("This can happen after backgrounding", RTCVideoDecoderH264.mm).
// The host kept the broken session, and a movie playing at that moment would stay frozen to its end (a looping one for good); not yet seen on a device
// Decoding is deterministic, so the pictures can be exactly those of an uninterrupted decode: the access units since the stream's last random access point (an H.264 IDR,
// an AV1 temporal unit with a sequence header and a shown key frame) are kept, and on one of those errors the session is invalidated and made again, the kept units go into
// it once more with their pictures thrown away (they were handed out, or wait in the H.264 reorder queue, already), and the packet is decoded again. Past VTR_MAX_UNITS units or
// VTR_MAX_BYTES bytes since the key frame nothing is kept until the next one, and a session lost then is made again without them: no unit is decoded until the next key frame
// (the picture the game has stays on screen), and the caller prints one [RED] line. DM_VT_REBUILD=0 keeps nothing and makes nothing again, as before.
// One of those errors that comes back straight after the session was made again (on a unit decoded again, or on the packet decoded again) is the data's, not the session's:
// -12911 also comes from the callback for a single frame the decoder fails on, in any session. Until the next key frame the units then go into the session as it is and its
// answer is theirs, as before, and it is not made again: a unit that always fails costs one rebuild a key frame interval, not one (and every unit since the key frame decoded
// again) a packet. A session lost again in that time (the app suspended twice within the catch-up) stays lost until the next key frame.
// The cap: docs/reference/movies.md records no bitrates, only how fast these decoders go (VideoToolbox AV1 about 450 pictures a second at 2560x1440 on an M3 Pro; a packet
// 3-8 ms on the caller), and the re-feed runs on the thread that decodes (movie::Decoder's own; nn::codec's submitting game thread), once, after the app comes back. So the
// cap is a time: 300 units is 10 s at 30 fps and 5 s at 60, longer than x264's default key frame interval (250 frames), and about 0.7 s of re-feeding at 450 pictures a
// second. 32 MB bounds the memory a decoder keeps: 300 units at 107 KB each, 25 Mbit/s at 30 fps (a single packet's bound is MD_INCAP, 4 MB). Plain C over libc, so
// dm/host/tests/t_vt_rebuild.c drives it with a fake decoder on any machine
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum { VTR_INVALID_SESSION = -12903, VTR_DECODER_MALFUNCTION = -12911 };   // VTErrors.h: kVTInvalidSessionErr, kVTVideoDecoderMalfunctionErr (hle_movie_avc.c checks the values)
enum { VTR_DROPPED = 1 };            // vtr_decode: the unit was not decoded (made again without the units it needs; nothing until the next key frame)
enum { VTR_MAX_UNITS = 300 };
#define VTR_MAX_BYTES ((size_t)32 << 20)

typedef struct {
    uint8_t *buf; size_t len, cap;   // the units since the last key frame, back to back
    size_t *end; int n, ncap;        // where each one ends in buf
    int over;        // they went past the cap: none are kept until the next key frame
    int lost;        // the session is gone and not made again yet (its error in err)
    int dropping;    // made again without the units: no unit is decoded until the next key frame
    int stuck;       // the error came back straight after the session was made again: until the next key frame the units go into this session as they are, as before
    int on;          // DM_VT_REBUILD (vtr_init); 0: nothing kept, an error is the decoder's answer, as before
    int32_t err;     // the error that lost the session
    int max_units; size_t max_bytes;
    unsigned logs;   // the caller's lines about it (vtr_log_due)
} vtr_state;

typedef struct {   // the decoder, for vtr_decode
    void *ctx;
    int32_t (*decode)(void *ctx, const uint8_t *p, size_t n, int discard);   // one unit into the session; discard: its pictures are thrown away. → its status
    int (*remake)(void *ctx);   // the session invalidated and made again from the stream's configuration: 1 when made
} vtr_ops;

typedef struct {   // what one vtr_decode did, for the caller's log line
    int32_t err;     // the error the session was lost to (0: nothing happened)
    int rebuilt;     // the session was made again (0 or 1)
    int refed;       // kept units decoded again, their pictures thrown away
    int dropping;    // made again without the units (past the cap): units are dropped from this one to the next key frame
    int failed;      // the session could not be made again: the next unit tries again, with the units kept
    int kept;        // units since the key frame, this one included (0 past the cap)
    int32_t again;   // the error came back straight after it was made again (a unit decoded again, or this one): the data's; the decoder is stuck until the next key frame
} vtr_report;

// DM_VT_REBUILD: on unless 0, read once
static inline int vtr_switch(void) { static int on = -1; if (on < 0) { const char *e = getenv("DM_VT_REBUILD"); on = !(e && !strcmp(e, "0")); } return on; }
static inline int vtr_lost_err(int32_t st) { return st == VTR_INVALID_SESSION || st == VTR_DECODER_MALFUNCTION; }
static inline const char *vtr_err_name(int32_t st) { return st == VTR_INVALID_SESSION ? "kVTInvalidSessionErr" : st == VTR_DECODER_MALFUNCTION ? "kVTVideoDecoderMalfunctionErr" : "?"; }
static inline void vtr_init(vtr_state *s, int on) { memset(s, 0, sizeof *s); s->on = on; s->max_units = VTR_MAX_UNITS; s->max_bytes = VTR_MAX_BYTES; }
static inline void vtr_free(vtr_state *s) { free(s->buf); free(s->end); s->buf = NULL; s->end = NULL; s->cap = s->len = 0; s->n = s->ncap = 0; }
// A flush or seek: the next unit is a key frame, nothing before it is needed (the session itself, lost or not, stays as it is)
static inline void vtr_reset(vtr_state *s) { s->n = 0; s->len = 0; s->over = 0; s->dropping = 0; s->stuck = 0; }
// The kept unit i
static inline const uint8_t *vtr_unit(const vtr_state *s, int i, size_t *n) { size_t b = i ? s->end[i - 1] : 0; *n = s->end[i] - b; return s->buf + b; }
// A unit about to be decoded joins the kept ones (a key frame starts them over). → 1 kept, 0 not (past the cap, or no memory: none are kept until the next key frame)
static inline int vtr_keep(vtr_state *s, const uint8_t *p, size_t n, int key) {
    if (key) { s->n = 0; s->len = 0; s->over = 0; }
    if (s->over) return 0;
    if (s->n + 1 > s->max_units || n > s->max_bytes - s->len) goto past;
    if (s->n == s->ncap) {
        int c = s->ncap ? s->ncap * 2 : 32; size_t *e = realloc(s->end, (size_t)c * sizeof *e);
        if (!e) goto past;
        s->end = e; s->ncap = c;
    }
    if (s->len + n > s->cap) {
        size_t c = s->cap ? s->cap : (size_t)1 << 16; while (c < s->len + n) c *= 2;
        if (c > s->max_bytes) c = s->max_bytes;
        uint8_t *b = realloc(s->buf, c);
        if (!b) goto past;
        s->buf = b; s->cap = c;
    }
    if (n) memcpy(s->buf + s->len, p, n);
    s->len += n; s->end[s->n++] = s->len;
    return 1;
past:   // the memory goes back at once: a long stretch without a key frame keeps nothing
    s->over = 1; s->n = 0; s->len = 0; free(s->buf); s->buf = NULL; s->cap = 0;
    return 0;
}
// Decode one unit (key: it is a random access point) through o, making the session again after a lost-session error: the kept units before this one go in again with
// their pictures thrown away, then this one is decoded once more; the error back straight after that makes the decoder stuck until the next key frame (see the top).
// → its status (0 decoded), VTR_DROPPED when it was not decoded (the session was made again past the cap, or is dropping until the next key frame), or the error when the
// session is lost and could not be made again. Each call makes the session at most once. *r says what happened
static inline int32_t vtr_decode(vtr_state *s, const vtr_ops *o, const uint8_t *p, size_t n, int key, vtr_report *r) {
    memset(r, 0, sizeof *r);
    if (!s->on) return o->decode(o->ctx, p, n, 0);
    vtr_keep(s, p, n, key);
    r->kept = s->n;
    if (key) s->stuck = 0;
    if (s->dropping) {
        if (!key) return VTR_DROPPED;
        s->dropping = 0;
    }
    if (s->stuck) return o->decode(o->ctx, p, n, 0);   // the error came back after the session was made again: the unit's answer, as before, until the next key frame
    int32_t st;
    if (!s->lost) {
        st = o->decode(o->ctx, p, n, 0);
        if (!vtr_lost_err(st)) return st;
        s->lost = 1; s->err = st;
    }
    r->err = s->err;
    if (!o->remake(o->ctx)) { r->failed = 1; return s->err; }   // the next unit tries again
    s->lost = 0; r->rebuilt = 1;
    if (!key && s->over) { s->dropping = 1; r->dropping = 1; return VTR_DROPPED; }
    for (int i = 0; !key && i + 1 < s->n; i++) {   // every kept unit but the last, which is this one
        size_t un; const uint8_t *u = vtr_unit(s, i, &un);
        int32_t e = o->decode(o->ctx, u, un, 1); r->refed++;
        if (vtr_lost_err(e)) { r->again = e; break; }   // back while catching up: the rest would only fail too
    }
    st = o->decode(o->ctx, p, n, 0);   // into the session as it is, after a catch-up cut short too
    if (!r->again && vtr_lost_err(st)) r->again = st;
    if (r->again) s->stuck = 1;
    return st;
}
// The caller's log lines about one decoder: the first 4, then every 2^k-th
static inline int vtr_log_due(vtr_state *s) { unsigned k = ++s->logs; return k <= 4 || !(k & (k - 1)); }
// The caller's line about one vtr_decode that met a lost session (r->err), for codec ("H.264") and its random access point (key, "IDR"), into buf without its prefix:
// → 2 for a [RED] line (pictures are lost or may be wrong), 1 for a plain one (made again, every picture kept), 0 for none
static inline int vtr_report_text(const vtr_state *s, const vtr_report *r, const char *codec, const char *key, char *buf, size_t cap) {
    if (!r->err) return 0;
    int32_t e = r->err; const char *en = vtr_err_name(e);
    if (r->dropping) {
        snprintf(buf, cap, "%s: VideoToolbox session lost (%d, %s) and made again past the %d packets or %zu MB kept since the last %s: none decoded until the next %s, "
                 "the last picture stays (DM_VT_REBUILD)", codec, (int)e, en, s->max_units, s->max_bytes >> 20, key, key);
        return 2;
    }
    if (r->failed) { snprintf(buf, cap, "%s: VideoToolbox session lost (%d, %s) and not made again: the next packet tries again, %d since the last %s kept", codec, (int)e, en, r->kept, key); return 2; }
    if (r->again) {
        snprintf(buf, cap, "%s: VideoToolbox answered %d (%s) again in the session made again after %d, %d packets decoded again: the data's error, not the session's; "
                 "until the next %s the packets go into this session as they are, and it is not made again (DM_VT_REBUILD)", codec, (int)r->again, vtr_err_name(r->again), (int)e, r->refed, key);
        return 2;
    }
    snprintf(buf, cap, "%s: VideoToolbox session made again after %d (%s): %d packets since the last %s decoded again, their pictures thrown away (DM_VT_REBUILD)", codec, (int)e, en, r->refed, key);
    return 1;
}

// AV1: a temporal unit (OBUs in the low-overhead format, each with its size, as WebM and the SDK's demuxer keep them) that is a random access point: it has a sequence
// header, and its first frame header is a key frame that is shown (AV1 5.9.2: show_existing_frame 0, frame_type KEY_FRAME, show_frame 1; with reduced_still_picture_header
// every frame is one). Anything else, a hidden key frame or a key frame without its sequence header included, counts as not one, which keeps more units than needed, never fewer
static inline int vtr_av1_key(const uint8_t *p, size_t n) {
    int reduced = -1;
    for (size_t i = 0; i < n;) {
        if (p[i] & 0x80 || !(p[i] & 2)) return 0;   // forbidden bit, or no size field
        unsigned type = p[i] >> 3 & 15; size_t at = i + (p[i] & 4 ? 2 : 1); uint64_t size = 0; size_t l = 0;
        for (; l < 8 && at + l < n; l++) { size |= (uint64_t)(p[at + l] & 0x7f) << (7 * l); if (!(p[at + l] & 0x80)) break; }
        if (l == 8 || at + l >= n) return 0;
        at += l + 1;
        if (size > n - at) return 0;
        if (type == 1 && size) reduced = p[at] >> 3 & 1;   // sequence header: seq_profile (3 bits), still_picture, reduced_still_picture_header
        if ((type == 3 || type == 6) && size) {           // frame header, or a frame
            if (reduced < 0) return 0;
            if (reduced) return 1;
            return !(p[at] & 0x80) && (p[at] >> 5 & 3) == 0 && (p[at] >> 4 & 1);
        }
        i = at + (size_t)size;
    }
    return 0;
}
