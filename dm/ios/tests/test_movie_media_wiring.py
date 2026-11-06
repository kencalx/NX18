"""Movie media on Apple's frameworks, checked in the sources off the device: a movie's AAC channel order (hle_movie.c md_aac_layout, dm/host/hle_movie_aac_order.h), the AAC
converter disposed at a Flush, VideoToolbox's VP9 check (hle_movie_avc.c mvt_vp9_check) and the VideoToolbox session made again after iOS lost it
(dm/host/hle_movie_vt_rebuild.h, used by hle_movie_avc.c and hle_movie_av1.c).

The decisions run as plain C in dm/host/tests/t_aac_layout.c and t_vt_rebuild.c (make -C dm/host/tests movie-logic), and through AudioToolbox and VideoToolbox in t_movie_vpx.c,
t_movie_avc.c and t_codec_video.c on a Mac. What none of them runs: where the calls sit (the layout once per converter, before its first packet; the disposal on the decoder's
thread; the VP9 check on a background queue, never on the caller; the rebuild on both decoders' only decode path), the switches' names against docs/env_switches.tsv, the log
lines against docs/reference/movies.md, and the deployment targets that let VTRegisterSupplementalVideoDecoderIfAvailable be called with no availability check."""
from pathlib import Path
import re
import unittest

REPO = Path(__file__).resolve().parents[3]


def read(rel):
    return (REPO / rel).read_text(encoding='utf-8')


def body(src, header):
    """The text of the C function whose definition starts with header, through its closing brace"""
    i = src.index(header); j = src.index('{', i); depth = 0
    for k in range(j, len(src)):
        depth += {'{': 1, '}': -1}.get(src[k], 0)
        if not depth: return src[j:k + 1]
    raise AssertionError(header)


def version(text):
    return tuple(int(x) for x in text.split('.'))


class AacOrder(unittest.TestCase):
    def setUp(self):
        self.movie = read('dm/host/hle_movie.c'); self.order = read('dm/host/hle_movie_aac_order.h')

    def test_set_once_per_converter_before_its_first_packet(self):
        opened = body(self.movie, 'static int md_aac_open(mdec_t *d) {')
        cookie, layout = opened.index('kAudioConverterDecompressionMagicCookie'), opened.index('md_aac_layout(d);')
        self.assertLess(cookie, layout)   # after the configuration, which tells the converter the stream's channels
        self.assertTrue(opened.rstrip('}').rstrip().endswith('md_aac_layout(d);\n    return 1;'))
        self.assertEqual(self.movie.count('md_aac_layout(d);'), 1)   # only there: md_aac opens a converter at a stream's first packet (and after a Stop or a Flush)
        self.assertIn('if (!d->aac && !md_aac_open(d)) return 0;', body(self.movie, 'static int md_aac(mdec_t *d, const uint8_t *p, int n, int slot) {'))
        lay = body(self.movie, 'static void md_aac_layout(mdec_t *d) {')
        self.assertTrue(lay.split('\n')[1].strip().startswith('if (d->ch < 3) return;'))   # mono and stereo: not touched
        self.assertIn('r == 1 && on', lay)   # set only when the order differs and DM_AAC_LAYOUT is on
        self.assertIn('kAudioChannelLayoutTag_UseChannelDescriptions', lay)   # the stream's own labels, reordered: nothing to mix
        self.assertIn('getenv("DM_AAC_LAYOUT"); g_aac_layout = !(e && !strcmp(e, "0"))', self.movie)

    def test_a_layout_with_a_tag_only_is_read(self):   # 12 bytes (CAAudioChannelLayout::CalculateByteSize(0)), less than sizeof(AudioChannelLayout)
        self.assertIn('#define MD_LAYOUT_HEAD offsetof(AudioChannelLayout, mChannelDescriptions)', self.movie)
        for fn in ('static int md_layout_labels(', 'static int md_aac_labels('):
            f = body(self.movie, fn)
            self.assertNotIn('sizeof *l', f); self.assertNotIn('sizeof *x', f); self.assertIn('MD_LAYOUT_HEAD', f)

    def test_the_header_labels_are_checked_against_the_sdk(self):
        names = re.findall(r'(AACL_[A-Z]+) = \d+', self.order)
        self.assertGreaterEqual(len(names), 20)
        assert_ = self.movie[self.movie.index('_Static_assert(AACL_LEFT'):]; assert_ = assert_[:assert_.index(';')]
        for n in names: self.assertIn(n + ' == kAudioChannelLabel_', assert_, n)
        for wide in ('kAudioChannelLabel_LeftWide == 35', 'kAudioChannelLabel_RightWide == 36', 'kAudioChannelLabel_LFE2 == 37'): self.assertIn(wide, assert_)   # the log's names

    def test_disposed_at_a_flush_as_at_a_stop(self):
        flush = body(self.movie, 'HLE_FORCE("_ZN5movie7Decoder5FlushEv"')
        self.assertIn('md_reset(d, 0);', flush)
        self.assertNotIn('md_reset(d, 1)', flush)   # that would also drop the slots' last pictures
        self.assertNotIn('dm_host_lock(&d->dmu)', flush)   # no second hold of the lock: a packet sent in between would decode in the old decoder
        self.assertEqual(self.movie.count('md_reset(d, 0)'), 1)   # only the Flush resets without closing everything
        reset = body(self.movie, 'static void md_reset(mdec_t *d, int close) {')
        lock, unlock = reset.index('dm_host_lock(&d->dmu);'), reset.rindex('pthread_mutex_unlock(&d->dmu);')
        line = next(ln for ln in reset.split('\n') if 'MD_TYPE_AAC' in ln)
        self.assertIn('md_aac_flush_on()', line)
        self.assertIn('md_job(d, MDJ_CLOSE); d->aac_reopen = 1;', line)   # on the decoder's thread, as md_reset(d, 1) closes at a Stop
        for at in (reset.index(line), reset.index('stb_vorbis_close(d->vb)')): self.assertTrue(lock < at < unlock)   # in the same hold of dmu as the queues' reset
        self.assertIn('if (close) { md_job(d, MDJ_CLOSE); d->aac_reopen = 0; }', reset)   # a Stop after a Flush: the next stream's converter prints its line
        self.assertIn('if (d->aac) { AudioConverterDispose(d->aac); d->aac = NULL; }', body(self.movie, 'static void md_close(mdec_t *d) {'))
        self.assertIn('getenv("DM_AAC_FLUSH"); on = !(e && !strcmp(e, "0"))', self.movie)


class Vp9Check(unittest.TestCase):
    def setUp(self):
        self.avc = read('dm/host/hle_movie_avc.c')

    def test_asked_for_by_the_first_vp9_stream_of_each_api(self):
        vpx = body(read('dm/host/hle_movie.c'), 'static int md_vpx(mdec_t *d, const uint8_t *p, int n, int slot) {')
        opened = vpx[vpx.index('if (!d->vpx_on) {'):vpx.index('if (vpx_codec_decode(')]
        self.assertIn('if (d->type == MD_TYPE_VP9) mvt_vp9_check();', opened)   # on the decoder's host thread, when libvpx opens
        cv = body(read('dm/host/hle_codec_video.c'), 'static void cv_open(cv_dec *d) {')
        self.assertIn('if (d->codec == CV_VP9) mvt_vp9_check();', cv)
        self.assertIn('void mvt_vp9_check(void);', read('dm/host/hle_movie_avc.h'))
        self.assertIn('void mvt_vp9_check(void) { g_vp9_checks++; }', read('dm/host/tests/t_movie_vpx.c'))   # that test links hle_movie.c without hle_movie_avc.c

    def test_once_on_a_background_queue(self):
        check = body(self.avc, 'void mvt_vp9_check(void) {')
        self.assertIn('atomic_flag_test_and_set(&once)', check)
        self.assertIn('dispatch_async_f(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), NULL, vp9_probe);', check)   # the caller (a game thread, for nn::codec) only queues it
        self.assertNotIn('VTRegister', check)
        self.assertIn('getenv("DM_VP9_PROBE")', check)
        probe = body(self.avc, 'static void vp9_probe(void *ctx) {')
        reg, hw = probe.index('VTRegisterSupplementalVideoDecoderIfAvailable(kCMVideoCodecType_VP9);'), probe.rindex('VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)')
        self.assertLess(reg, hw)   # asked after registering, and once before
        self.assertLess(probe.index('VTIsHardwareDecodeSupported(kCMVideoCodecType_VP9)'), reg)
        self.assertNotIn('VTDecompressionSessionCreate', probe)   # a check only: nothing decodes through it

    def test_no_availability_check_is_needed(self):   # VTUtilities.h (iPhoneOS 27.2 SDK): API_AVAILABLE(macos(11.0), ios(26.2), tvos(26.2), visionos(26.2))
        ios = re.search(r'deploymentTarget:\s*\n\s*iOS: "([\d.]+)"', read('dm/ios/project.yml')).group(1)
        mac = re.search(r'MACOS_MIN := ([\d.]+)', read('dm/mac/min_os.mk')).group(1)
        self.assertGreaterEqual(version(ios), (26, 2), 'below iOS 26.2 VTRegisterSupplementalVideoDecoderIfAvailable needs an availability check')
        self.assertGreaterEqual(version(mac), (11, 0), 'below macOS 11 VTRegisterSupplementalVideoDecoderIfAvailable needs an availability check')


class SessionRebuild(unittest.TestCase):
    def setUp(self):
        self.avc, self.av1 = read('dm/host/hle_movie_avc.c'), read('dm/host/hle_movie_av1.c'); self.vtr = read('dm/host/hle_movie_vt_rebuild.h')

    def test_the_errors_are_videotoolboxs(self):
        self.assertIn('VTR_INVALID_SESSION = -12903, VTR_DECODER_MALFUNCTION = -12911', self.vtr)
        self.assertIn('_Static_assert(VTR_INVALID_SESSION == kVTInvalidSessionErr && VTR_DECODER_MALFUNCTION == kVTVideoDecoderMalfunctionErr', self.avc)
        self.assertIn('getenv("DM_VT_REBUILD"); on = !(e && !strcmp(e, "0"))', self.vtr)

    def test_at_most_one_rebuild_a_packet(self):   # an error back straight after the rebuild is the data's: stuck to the next key frame, never a rebuild per packet
        dec = body(self.vtr, 'static inline int32_t vtr_decode(')
        self.assertEqual(dec.count('o->remake(o->ctx)'), 1); self.assertNotIn('for (int pass', dec)
        self.assertIn('if (key) s->stuck = 0;', dec)
        self.assertIn('if (s->stuck) return o->decode(o->ctx, p, n, 0);', dec)
        self.assertIn('if (r->again) s->stuck = 1;', dec)
        self.assertIn('s->stuck = 0; }', body(self.vtr, 'static inline void vtr_reset(vtr_state *s) {'))

    def test_h264_decodes_only_through_it(self):
        dec = body(self.avc, 'int mavc_decode(mavc *a, const uint8_t *p, int n, int64_t pts_us) {')
        self.assertIn('vtr_decode(&a->vt, &ops, a->au, c.len, c.idr, &r)', dec)   # the IDR starts the kept units over
        self.assertNotIn('VTDecompressionSessionDecodeFrame', dec)
        self.assertEqual(self.avc.count('VTDecompressionSessionDecodeFrame('), 1)   # only in avc_vt_decode
        self.assertIn('VTDecompressionSessionDecodeFrame(', body(self.avc, 'static int32_t avc_vt_decode(void *ctx, const uint8_t *p, size_t n, int discard) {'))
        self.assertIn('if (!a->vt.lost && (a->dirty || !a->vs) && !open_session(a, 0)) return -1;', dec)   # a lost session is made again by vtr_decode only, which brings it back first
        self.assertIn('return open_session(ctx, 1);', body(self.avc, 'static int avc_vt_remake(void *ctx) {'))
        self.assertIn('if (!again || said != a->said) LOG("[movie] AVC: VideoToolbox decoding', body(self.avc, 'static int open_session(mavc *a, int again) {'))   # not once per rebuild
        self.assertIn('return !st && a->vt.on && vtr_lost_err(a->cb_st) ? a->cb_st : st;', body(self.avc, 'static int32_t avc_vt_decode('))   # off: the call's answer, as before
        frame = body(self.avc, 'static void on_frame(')
        self.assertLess(frame.index('a->cb_st = st;'), frame.index('if (a->discard) return;'))   # an error is seen in the re-feed too
        self.assertLess(frame.index('if (a->discard) return;'), frame.index('CVPixelBufferRetain(img)'))   # a picture decoded again never enters the reorder queue
        self.assertIn('vtr_reset(&a->vt);', body(self.avc, 'void mavc_drop(mavc *a) {'))   # a flush: the next unit is a key frame
        self.assertIn('vtr_init(&a->vt, vtr_switch());', self.avc)

    def test_av1_decodes_only_through_it(self):
        dec = body(self.av1, 'int mav1_decode(mav1 *a, const uint8_t *data, size_t n, mav1_picture *out) {')
        self.assertIn('vtr_decode(&a->vt, &ops, data, n, vtr_av1_key(data, n), &r)', dec)
        self.assertNotIn('VTDecompressionSessionDecodeFrame', dec)
        self.assertEqual(self.av1.count('VTDecompressionSessionDecodeFrame('), 1)
        self.assertLess(dec.index('if (a->soft) return decode_dav1d('), dec.index('vtr_decode('))   # dav1d is not VideoToolbox: not kept, not made again
        self.assertIn('return av1_open(a, seq, n);', body(self.av1, 'static int av1_vt_remake(void *ctx) {'))
        self.assertIn('return !st && a->vt.on && vtr_lost_err(a->cb_st) ? a->cb_st : st;', body(self.av1, 'static int32_t av1_vt_decode('))
        opened = dec[dec.index('if (!av1_open(a, seq, seqn)) {'):dec.index('vtr_decode(')]
        self.assertIn('a->vt.lost = 0;', opened)   # a session made from a new sequence header replaces the lost one: not made a second time
        frame = body(self.av1, 'static void av1_on_frame(')
        self.assertLess(frame.index('a->cb_st = st;'), frame.index('if (a->discard) return;'))
        self.assertLess(frame.index('if (a->discard) return;'), frame.index('a->got = CVPixelBufferRetain(img);'))
        self.assertIn('vtr_reset(&a->vt); a->vt.lost = 0;', body(self.av1, 'void mav1_reset(mav1 *a) {'))

    def test_one_line_each_rate_limited(self):
        for src, codec, key in ((self.avc, '"H.264"', '"IDR"'), (self.av1, '"AV1"', '"key frame"')):
            self.assertIn(f'r.err && vtr_log_due(&a->vt) ? vtr_report_text(&a->vt, &r, {codec}, {key}, line, sizeof line) : 0', src)
            self.assertIn('if (say) LOG("%s%s", say > 1 ? "[RED] movie: " : "[movie] ", line);', src)


class Documented(unittest.TestCase):
    def test_switches_and_lines(self):
        table = {ln.split('\t')[0] for ln in read('docs/env_switches.tsv').split('\n')}
        for sw in ('DM_AAC_LAYOUT', 'DM_AAC_FLUSH', 'DM_VP9_PROBE', 'DM_VT_REBUILD'): self.assertIn(sw, table)
        movies = read('docs/reference/movies.md')
        for heading in ('### AAC 5.1 in the console\'s channel order', '### AAC after a Flush starts afresh', '### VP9 in VideoToolbox: a check only',
                        '### A VideoToolbox session lost while the app was suspended'):
            self.assertIn(heading, movies)
        for text in ("[movie] AAC: 6 channels in AudioToolbox's order", "handed out in the console's (MediaCodec's) order", "already the console's (MediaCodec's)",
                     'kept (DM_AAC_LAYOUT=0)', 'AudioToolbox gives no output channel layout', "a channel has no place in MediaCodec's order",
                     "AudioToolbox did not take the console's channel order", '[movie] VP9 in VideoToolbox: hardware decoder',
                     'VideoToolbox session made again after', 'and made again past the 300 packets or 32 MB', 'and not made again: the next packet tries again',
                     'again in the session made again after', "the data's error, not the session's", '[RED] movie: AVC decode error (VideoToolbox -12903, first case)'):
            self.assertIn(text, movies, text)
        movie, vtr = read('dm/host/hle_movie.c'), read('dm/host/hle_movie_vt_rebuild.h')
        for fmt in ("AudioToolbox gives no output channel layout", "a channel has no place in MediaCodec's order", "AudioToolbox did not take the console's channel order",
                    "handed out in the console's (MediaCodec's) order", "already the console's (MediaCodec's)", 'kept (DM_AAC_LAYOUT=0)'):
            self.assertIn(fmt, movie, fmt)
        for fmt in ('VideoToolbox session made again after', 'and made again past the %d packets or %zu MB', 'and not made again: the next packet tries again',
                    'VideoToolbox answered %d (%s) again in the session made again after %d', "the data's error, not the session's"):
            self.assertIn(fmt, vtr, fmt)
        mk = read('dm/host/tests/Makefile')
        self.assertIn('\t$(B)/t_aac_layout\n\t$(B)/t_vt_rebuild\n', mk)   # in make run, which CI's host tests run on macOS


if __name__ == '__main__':
    unittest.main()
