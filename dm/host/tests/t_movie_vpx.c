// Synthetic 16x16 red key frames encoded with ffmpeg's libvpx encoders; no game data.
// Include the real decoder, without registering unrelated SDK hooks in this test.
#include "../hle.h"
#undef HLE_FORCE
#define HLE_FORCE(mangled, why, ret, cname, ...) static ret cname(__VA_ARGS__)
#include "../hle_movie.c"
#include <assert.h>
#include <math.h>

static const uint8_t vp8[] = {
    0xf0,0x02,0x00,0x9d,0x01,0x2a,0x10,0x00,0x10,0x00,0x00,0x47,0x08,0x85,0x85,0x88,
    0x85,0x84,0x88,0x02,0x02,0x02,0x75,0xaa,0x03,0xf8,0x03,0xfa,0x02,0x0d,0x4d,0x18,
    0x00,0xfe,0xfd,0x6e,0xf3,0xff,0xe3,0x99,0x37,0x30,0xc4,0xff,0x8e,0x6d,0xff,0xf1,
    0x61,0x3c,0x0e,0x28,0xc8,0xff,0xf1,0x51,0x00,
};
static const uint8_t vp9[] = {
    0x82,0x49,0x83,0x42,0x00,0x00,0xf0,0x00,0xf6,0x00,0x38,0x24,0x1c,0x18,0x4a,0x00,
    0x00,0x30,0x60,0x00,0x00,0x10,0xbf,0xff,0xf7,0x1d,0xaf,0xff,0xff,0xff,0x5f,0xdf,
    0xff,0xff,0xff,0xf2,0x2a,0xc0,0x00,
};
static void decode(int type, int format, const uint8_t *packet, int size) {
    mdec_t d = { .type = type, .fmt = format, .w = 16, .h = 16 };
    assert(md_vpx(&d, packet, size, 0) == 1);
    const uint8_t *p = d.out[0].frm;
    if (format == MD_FMT_NV12) {
        assert(d.out[0].cap == 16 * 16 * 3 / 2);
        for (int i = 0; i < 256; i++) assert(abs(p[i] - 81) <= 3);
        for (int i = 256; i < 384; i += 2) { assert(abs(p[i] - 90) <= 3); assert(abs(p[i+1] - 240) <= 3); }
    } else {
        assert(d.out[0].cap == 16 * 16 * 4);
        for (int i = 0; i < 1024; i += 4) assert(p[i] >= 250 && p[i+1] <= 5 && p[i+2] <= 5 && p[i+3] == 255);
    }
    vpx_codec_destroy(&d.vpx);
    free(d.out[0].frm);
}
// The frame step's movie signal (dm_movie_playing): a video picture handed out raises it for MD_PLAYING_NS; an audio output does not
static uint64_t test_now = 1000000000ull;
uint64_t now_ns(void) { return test_now; }
__thread _Atomic int dm_host_work;   // hle_thread.c
void dm_host_lock(pthread_mutex_t *m) { pthread_mutex_lock(m); }
void mavc_drop(mavc *a) { (void)a; }   // hle_movie_avc.c: no H.264 here
// The decoder thread (md_worker, which the AAC test's Flush uses) reaches hle_movie_avc.c's H.264 calls, which no VP8, VP9 or audio decoder makes: not linked here
mavc *mavc_new(void) { abort(); }
void mavc_free(mavc *a) { (void)a; abort(); }
void mavc_set_rgba(mavc *a) { (void)a; abort(); }
int mavc_decode(mavc *a, const uint8_t *p, int n, int64_t pts_us) { (void)a; (void)p; (void)n; (void)pts_us; abort(); }
int mavc_take(mavc *a, int flush, uint8_t *nv12, int w, int h, int64_t *pts_us) { (void)a; (void)flush; (void)nv12; (void)w; (void)h; (void)pts_us; abort(); }
void dm_host_helper_qos(qos_class_t q) { (void)q; }   // hle_thread.c (the decoder thread, md_worker, which the AAC test's Flush uses)
static void playing(void) {
    static mdec_t video = { .type = MD_TYPE_VP9, .nout = MD_NOUT_VIDEO, .started = 1 }, audio = { .type = MD_TYPE_VORBIS, .nout = MD_NOUT, .started = 1 };
    pthread_mutex_init(&video.mu, NULL); pthread_mutex_init(&audio.mu, NULL);
    void *vs[2] = { NULL, &video }, *as[2] = { NULL, &audio };
    int idx, left; int64_t pts; uint32_t flags;
    assert(!dm_movie_playing());
    audio.outq[0] = 0; audio.noutq = 1;
    assert(!h_movie_AcqOut(as, &idx, &pts, &flags, &left) && idx == 0 && !dm_movie_playing());
    video.outq[0] = 3; video.noutq = 1;
    assert(!h_movie_AcqOut(vs, &idx, &pts, &flags, &left) && idx == 3 && dm_movie_playing());
    test_now += MD_PLAYING_NS - 1; assert(dm_movie_playing());
    assert(h_movie_AcqOut(vs, &idx, &pts, &flags, &left) == MD_NO_OUTPUT && dm_movie_playing());   // no picture ready: nothing handed out, the signal is not renewed
    test_now += 1; assert(!dm_movie_playing());
    puts("movie signal: a video picture raises it for half a second, audio outputs do not");
}
// A Flush (a seek, or a movie that loops) must not end the movie's Vorbis sound. A synthetic one-channel stream (both block sizes 64, all-zero residue; no game data), made as the demuxer hands it over:
// the identification and setup headers, then raw audio packets. Before the fix, stb_vorbis_flush_pushdata left the decoder searching for an Ogg page and it gave no sample again
typedef struct { unsigned char data[1024]; int bits; } vpkt;
static void vbits(vpkt *p, unsigned value, int n) { for (int i = 0; i < n; i++, p->bits++) p->data[p->bits / 8] |= ((value >> i) & 1) << (p->bits % 8); }
static void vhead(vpkt *p, int type) { vbits(p, type, 8); for (int i = 0; i < 6; i++) vbits(p, "vorbis"[i], 8); }
static void vcodebook(vpkt *p, int lookup) {
    vbits(p, 0x564342, 24); vbits(p, 1, 16); vbits(p, 1, 24);     // one dimension, one entry
    vbits(p, 0, 1); vbits(p, 0, 1); vbits(p, 0, 5);                // unordered, dense, one-bit code
    vbits(p, lookup, 4);
    if (lookup) { vbits(p, (788u << 21) | 1, 32); vbits(p, 0, 32); vbits(p, 0, 4); vbits(p, 0, 1); vbits(p, 0, 1); }   // minimum 1.0, delta 0.0, one-bit multiplicand, no sequence
}
static int vorbis_samples(mdec_t *d, vpkt *packets, int n) {
    int got = 0; for (int i = 0; i < n; i++) got += md_vorbis(d, packets[i].data, (packets[i].bits + 7) / 8, 0); return got;
}
// One channel, blocksizes as in the identification header (0x66: both 64; 0x86: 64 and 256), one mode per window size in use; packets as vaudio makes them
static void vstream(mdec_t *d, vpkt *id, vpkt *setup, int blocksizes, int modes) {
    vhead(id, 1); vbits(id, 0, 32); vbits(id, 1, 8); vbits(id, 48000, 32); for (int i = 0; i < 3; i++) vbits(id, 0, 32); vbits(id, blocksizes, 8); vbits(id, 1, 8);
    vhead(setup, 5); vbits(setup, 1, 8); vcodebook(setup, 0); vcodebook(setup, 1);
    vbits(setup, 0, 6); vbits(setup, 0, 16);                                          // one time configuration
    vbits(setup, 0, 6); vbits(setup, 1, 16); vbits(setup, 0, 5); vbits(setup, 0, 2); vbits(setup, 5, 4); vbits(setup, 0, 6);   // one floor 1, no partitions
    vbits(setup, 0, 16); vbits(setup, 0, 24); vbits(setup, 32, 24); vbits(setup, 31, 24); vbits(setup, 0, 6); vbits(setup, 0, 8);   // residue 0: partition size 32, classbook 0
    vbits(setup, 1, 3); vbits(setup, 0, 1); vbits(setup, 1, 8);                       // pass 0 uses vector codebook 1
    vbits(setup, 0, 6); vbits(setup, 0, 16); vbits(setup, 0, 1); vbits(setup, 0, 1); vbits(setup, 0, 2);   // one mapping, no coupling, reserved bits
    vbits(setup, 0, 8); vbits(setup, 0, 8); vbits(setup, 0, 8);
    vbits(setup, modes - 1, 6); for (int m = 0; m < modes; m++) { vbits(setup, m, 1); vbits(setup, 0, 16); vbits(setup, 0, 16); vbits(setup, 0, 8); }   // mode m: short (0) or long (1) window
    vbits(setup, 1, 1);
    d->vhdr[0] = id->data; d->vhdr_n[0] = (id->bits + 7) / 8; d->vhdr[1] = setup->data; d->vhdr_n[1] = (setup->bits + 7) / 8;
    pthread_mutex_init(&d->mu, NULL); pthread_mutex_init(&d->dmu, NULL);
}
static void vaudio(vpkt *p, int modes, int blockflag, int prev_long, int next_long) {   // the window flags are only in a long window's packet
    vbits(p, 0, 1);
    if (modes > 1) { vbits(p, blockflag, 1); if (blockflag) { vbits(p, prev_long, 1); vbits(p, next_long, 1); } }
    vbits(p, 1, 1); vbits(p, 255, 8); vbits(p, 255, 8); vbits(p, 0, 1); vbits(p, 0, 32);
}
static void vorbis_flush(void) {
    static vpkt id, setup, audio[8]; static mdec_t d = { .type = MD_TYPE_VORBIS, .nout = MD_NOUT, .started = 1 };
    vstream(&d, &id, &setup, 0x66, 1);
    for (int i = 0; i < 8; i++) vaudio(&audio[i], 1, 0, 0, 0);
    int before = vorbis_samples(&d, audio, 8);
    assert(before > 0);
    void *self[2] = { NULL, &d };
    assert(h_movie_Flush(self) == 0);
    assert(vorbis_samples(&d, audio, 8) == before);   // the stream starts afresh: the same samples again
    assert(h_movie_Flush(self) == 0 && h_movie_Flush(self) == 0);   // Dread and others flush twice in a row
    assert(vorbis_samples(&d, audio, 8) == before);
    puts("Vorbis movie sound: the samples come again after a Flush");
}
// At a window change each packet leaves with (previous blocksize + its blocksize) / 4 samples. With blocksizes 64 / 256, stb_vorbis gives 176 and 32 for a long window before a short one and the short one,
// where the specification has 128 and 80. Samples kept across a change do not survive a Flush
static void vorbis_window_change(void) {
    static vpkt id, setup, audio[11]; static mdec_t d = { .type = MD_TYPE_VORBIS, .nout = MD_NOUT, .started = 1 };
    static const int window[11] = { 256, 256, 256, 64, 64, 256, 256, 64, 256, 64, 256 };
    vstream(&d, &id, &setup, 0x86, 2);
    for (int i = 0; i < 11; i++) vaudio(&audio[i], 2, window[i] == 256, i && window[i - 1] == 256, i == 10 || window[i + 1] == 256);
    void *self[2] = { NULL, &d };
    for (int run = 0; run < 2; run++) {
        assert(!md_vorbis(&d, audio[0].data, (audio[0].bits + 7) / 8, 0));   // the first packet only primes the overlap
        for (int i = 1; i < 11; i++) {
            assert(md_vorbis(&d, audio[i].data, (audio[i].bits + 7) / 8, 0));
            assert(d.out[0].bytes == (size_t)(window[i - 1] + window[i]) / 4 * sizeof(int16_t));
        }
        assert(!d.hold_n);   // the last window has a long one after it: nothing lies past its centre
        assert(h_movie_Flush(self) == 0);
        for (int i = 0; i < 3; i++) md_vorbis(&d, audio[i].data, (audio[i].bits + 7) / 8, 0);
        assert(d.hold_n);    // the long window before a short one left samples behind
        assert(h_movie_Flush(self) == 0 && !d.hold_n && !d.vb_prev);
    }
    puts("Vorbis movie sound: outputs as long as the specification says at a window change");
}
// An output takes the values asked for and leaves the rest for the next one; at most what is kept
static void vorbis_split(void) {
    static mdec_t d = { .type = MD_TYPE_VORBIS, .nout = MD_NOUT, .started = 1 };
    d.hold_cap = 1472 + 128; d.hold = malloc(d.hold_cap * sizeof *d.hold); d.hold_n = d.hold_cap;
    for (size_t i = 0; i < d.hold_n; i++) d.hold[i] = (int16_t)i;
    assert(md_vorbis_emit(&d, 0, 1024) && d.out[0].bytes == 1024 * sizeof *d.hold && d.hold_n == 576);
    assert(((int16_t *)d.out[0].frm)[1023] == 1023 && d.hold[0] == 1024);
    assert(md_vorbis_emit(&d, 0, 1024) && d.out[0].bytes == 576 * sizeof *d.hold && !d.hold_n);
    assert(!md_vorbis_emit(&d, 0, 1024));
    puts("Vorbis movie sound: an output takes the length asked for and leaves the rest");
}
// SDK 1 exports these three getters without const. Later SDKs export the const overloads.
typedef struct { char bytes[16]; size_t used; } test_buffer;
static void *buffer_data(const void *buf) { return (void *)((const test_buffer *)buf)->bytes; }
static size_t buffer_size(const void *buf) { return ((const test_buffer *)buf)->used; }
static size_t buffer_capacity(const void *buf) { return sizeof ((const test_buffer *)buf)->bytes; }
static void unused_export(void) { abort(); }
static int exports_const, exports_mutable, mutable_lookups;
void *guest_sym(const char *name) {
    static const struct { const char *modern, *early; void *fn; } getters[] = {
        {"_ZNK5movie6Buffer4DataEv", "_ZN5movie6Buffer4DataEv", buffer_data},
        {"_ZNK5movie6Buffer8CapacityEv", "_ZN5movie6Buffer8CapacityEv", buffer_capacity},
        {"_ZNK5movie6Buffer4SizeEv", "_ZN5movie6Buffer4SizeEv", buffer_size},
    };
    for (size_t i = 0; i < sizeof getters / sizeof *getters; i++) {
        if (!strcmp(name, getters[i].modern)) return exports_const ? getters[i].fn : NULL;
        if (!strcmp(name, getters[i].early)) { mutable_lookups++; return exports_mutable ? getters[i].fn : NULL; }
    }
    return unused_export;  // the other required SDK methods exist but this test never calls them
}
static void movie_buffer_exports(void) {
    test_buffer buf = {.bytes = "frame", .used = 5};
    for (int sdk = 1; sdk <= 3; sdk++) {  // mutable only, const only, both
        exports_const = sdk & 2; exports_mutable = sdk & 1; mutable_lookups = 0;
        memset(&G, 0, sizeof G);
        md_syms();
        assert(G.data(&buf) == buf.bytes && G.size(&buf) == 5 && G.cap(&buf) == 16);
        assert(mutable_lookups == (exports_const ? 0 : 3));
    }
    memset(&G, 0, sizeof G);
}
// AAC 5.1 through AudioToolbox both ways, no game data: a tone in each channel (L R C LFE Ls Rs), encoded by AudioToolbox's AAC encoder told that order
// (kAudioConverterInputChannelLayout MPEG_5_1_A), then decoded by md_aac as a movie's AAC decoder decodes it: with DM_AAC_LAYOUT off (AudioToolbox's own order, printed),
// then after a Flush with it on, then after another Flush. On, each slot holds the console's channel (L R C LFE Ls Rs); each slot's samples are one of the off run's slots,
// value for value (the order moves channels and changes no sample); and a Flush starts the stream afresh (the same samples again: DM_AAC_FLUSH)
static const double k_tone[6] = {440, 660, 990, 60, 1320, 1760};   // L R C LFE Ls Rs (AAC codes only an LFE channel's lowest lines)
enum { AAC_IN = 48000, AAC_PKTS = 80, AAC_OUT = 64 * 1024 };
typedef struct { const int16_t *pcm; UInt32 at; } aac_src;
static OSStatus aac_src_feed(AudioConverterRef c, UInt32 *np, AudioBufferList *bl, AudioStreamPacketDescription **pd, void *ud) {
    (void)c; (void)pd; aac_src *s = ud; UInt32 n = AAC_IN - s->at; if (n > *np) n = *np;
    bl->mNumberBuffers = 1; bl->mBuffers[0].mNumberChannels = 6; bl->mBuffers[0].mData = (void *)(s->pcm + (size_t)s->at * 6); bl->mBuffers[0].mDataByteSize = n * 12;
    s->at += n; *np = n; return 0;   // 0 frames: the end, the encoder flushes
}
static double goertzel(const int16_t *x, size_t n, double hz) {   // the power of one frequency in channel x (every 6th sample)
    double c = 2 * cos(2 * M_PI * hz / 48000), s1 = 0, s2 = 0;
    for (size_t i = 0; i < n; i++) { double s0 = x[i * 6] + c * s1 - s2; s2 = s1; s1 = s0; }
    return s1 * s1 + s2 * s2 - c * s1 * s2;
}
static int aac_tone(const int16_t *pcm, int slot) {   // the tone a slot carries, -1 for none (silent)
    double best = 1e9; int k = -1;   // well above rounding noise over 16384 samples
    for (int t = 0; t < 6; t++) { double p = goertzel(pcm + 4096 * 6 + slot, 16384, k_tone[t]); if (p > best) { best = p; k = t; } }
    return k;
}
static size_t aac_run(mdec_t *d, uint8_t *const *pk, const UInt32 *pn, int np, int16_t *pcm) {
    size_t got = 0;
    for (int i = 0; i < np; i++) if (md_aac(d, pk[i], (int)pn[i], 0)) {
        size_t f = d->out[0].bytes / 12; if (got + f > AAC_OUT) f = AAC_OUT - got;
        memcpy(pcm + got * 6, d->out[0].frm, f * 12); got += f;
    }
    return got;
}
static void aac_order(void) {
    static int16_t in[AAC_IN * 6], off[AAC_OUT * 6], on[AAC_OUT * 6], again[AAC_OUT * 6];
    for (int i = 0; i < AAC_IN; i++) for (int c = 0; c < 6; c++) in[i * 6 + c] = (int16_t)lrint(8000 * sin(2 * M_PI * k_tone[c] * i / 48000));
    AudioStreamBasicDescription pcm = {.mSampleRate = 48000, .mFormatID = kAudioFormatLinearPCM, .mFormatFlags = kLinearPCMFormatFlagIsSignedInteger | kLinearPCMFormatFlagIsPacked,
                                       .mBytesPerPacket = 12, .mFramesPerPacket = 1, .mBytesPerFrame = 12, .mChannelsPerFrame = 6, .mBitsPerChannel = 16};
    AudioStreamBasicDescription aac = {.mSampleRate = 48000, .mFormatID = kAudioFormatMPEG4AAC, .mFormatFlags = kMPEG4Object_AAC_LC, .mFramesPerPacket = 1024, .mChannelsPerFrame = 6};
    AudioConverterRef enc = NULL; OSStatus st = AudioConverterNew(&pcm, &aac, &enc);
    if (st) { printf("AAC 5.1: no AudioToolbox AAC encoder for 6 channels here (%d), skipped\n", (int)st); return; }
    AudioChannelLayout lay = {.mChannelLayoutTag = kAudioChannelLayoutTag_MPEG_5_1_A};
    int told = !AudioConverterSetProperty(enc, kAudioConverterInputChannelLayout, sizeof lay, &lay);
    UInt32 maxp = 0, sz = sizeof maxp; AudioConverterGetProperty(enc, kAudioConverterPropertyMaximumOutputPacketSize, &sz, &maxp);
    if (!maxp) maxp = 6 * 768;
    uint8_t *pk[AAC_PKTS], *buf = malloc(maxp); UInt32 pn[AAC_PKTS]; int np = 0; aac_src src = {in, 0}; OSStatus est = 0;
    while (np < AAC_PKTS) {
        UInt32 n = 1; AudioStreamPacketDescription pd = {0}; AudioBufferList ob = {1, {{6, maxp, buf}}};
        if ((est = AudioConverterFillComplexBuffer(enc, aac_src_feed, &src, &n, &ob, &pd)) || !n) break;
        UInt32 len = pd.mDataByteSize ? pd.mDataByteSize : ob.mBuffers[0].mDataByteSize;
        pk[np] = malloc(len); memcpy(pk[np], buf + pd.mStartOffset, len); pn[np++] = len;
    }
    AudioConverterDispose(enc); free(buf);
    if (np <= 40) {   // 47 frames of 1024 and the encoder's priming expected: an encoder that made a converter and gave less is this test's setup, not the host's decoder
        printf("AAC 5.1: AudioToolbox's AAC encoder gave %d packets for 6 channels here (%d, input order %s), skipped\n", np, (int)est, told ? "told" : "NOT told");
        for (int i = 0; i < np; i++) free(pk[i]);
        return;
    }
    static mdec_t d = { .type = MD_TYPE_AAC, .nout = MD_NOUT_AAC, .started = 1, .ch = 6, .rate = 48000 };   // no csd-0: md_aac_open makes the AAC-LC configuration (48 kHz, 6 channels)
    pthread_mutex_init(&d.mu, NULL); pthread_mutex_init(&d.dmu, NULL); pthread_mutex_init(&d.wmu, NULL); pthread_cond_init(&d.wcv, NULL);
    assert(!pthread_create(&d.wk, NULL, md_worker, &d));   // a Flush disposes the converter on the decoder's thread
    void *self[2] = { NULL, &d };
    g_aac_layout = 0; size_t n0 = aac_run(&d, pk, pn, np, off);
    assert(h_movie_Flush(self) == 0 && !d.aac && d.aac_reopen);   // the converter goes, as at a Stop; the next packet opens it
    g_aac_layout = 1; size_t n1 = aac_run(&d, pk, pn, np, on);
    assert(!d.aac_reopen && h_movie_Flush(self) == 0 && !d.aac);
    size_t n2 = aac_run(&d, pk, pn, np, again);
    assert(n0 > 4096 + 16384 && n0 == n1 && n1 == n2);
    assert(!memcmp(on, again, n1 * 12));   // a Flush starts the stream afresh: no overlap of the old position, the same samples as after the first one
    char a[64] = "", b[64] = ""; uint32_t lab[6]; int t_off[6], t_on[6];
    for (int c = 0; c < 6; c++) { t_off[c] = aac_tone(off, c); t_on[c] = aac_tone(on, c); }
    for (int c = 0; c < 6; c++) { lab[c] = t_off[c] < 0 ? 0 : (uint32_t[]){AACL_LEFT, AACL_RIGHT, AACL_CENTER, AACL_LFE, AACL_LS, AACL_RS}[t_off[c]]; }
    aac_labels_text(lab, 6, a, sizeof a);
    for (int c = 0; c < 6; c++) { lab[c] = t_on[c] < 0 ? 0 : (uint32_t[]){AACL_LEFT, AACL_RIGHT, AACL_CENTER, AACL_LFE, AACL_LS, AACL_RS}[t_on[c]]; }
    aac_labels_text(lab, 6, b, sizeof b);
    printf("AAC 5.1 (AudioToolbox encoder %s the input order): AudioToolbox's own order %s; with DM_AAC_LAYOUT %s\n", told ? "told" : "NOT told", a, b);
    for (int j = 0; j < 6; j++) {   // each slot on is one slot off, every sample the same
        int match = -1;
        for (int i = 0; i < 6 && match < 0; i++) { size_t f = 0; while (f < n1 && on[f * 6 + j] == off[f * 6 + i]) f++; if (f == n1) match = i; }
        assert(match >= 0);
    }
    if (told) for (int c = 0; c < 6; c++) if (c != 3) assert(t_on[c] == c);   // L R C _ Ls Rs in their slots; the LFE slot is the one left (its tone may be filtered)
    dm_host_lock(&d.dmu); md_job(&d, MDJ_QUIT); pthread_mutex_unlock(&d.dmu); pthread_join(d.wk, NULL);
    for (int i = 0; i < np; i++) free(pk[i]);
    free(d.out[0].frm);
    puts("AAC 5.1: handed out in the console's order (L R C LFE Ls Rs), the samples unchanged, and a Flush starts the sound afresh");
}
int main(void) {
    movie_buffer_exports();
    playing();
    vorbis_flush();
    vorbis_window_change();
    vorbis_split();
    int w = 0, h = 0;
    assert(!vp8_size(vp8, 9, &w, &h));
    assert(vp8_size(vp8, sizeof vp8, &w, &h) && w == 16 && h == 16);
    for (int format = MD_FMT_ABGR; format <= MD_FMT_NV12; format++) {
        decode(3, format, vp9, sizeof vp9);
        decode(2, format, vp8, sizeof vp8);
    }
    puts("VP8 and VP9 key frames: NV12 and RGBA pixels match");
    aac_order();
}
