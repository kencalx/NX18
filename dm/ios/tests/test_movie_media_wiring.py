"""Movie media on Apple's frameworks, checked in the sources off the device: a movie's AAC channel order (hle_movie.c md_aac_layout, dm/host/hle_movie_aac_order.h) and the AAC
converter disposed at a Flush. A VideoToolbox session iOS lost is restarted at the next key frame (hle_movie.c movie_vt_restart, X1.0's movie_restart); the other line's
rebuild (hle_movie_vt_rebuild.h, DM_VT_REBUILD) was not taken.

The decisions run as plain C in dm/host/tests/t_aac_layout.c (make -C dm/host/tests movie-logic), and through AudioToolbox and VideoToolbox in t_movie_vpx.c,
t_movie_avc.c and t_codec_video.c on a Mac. What none of them runs: where the calls sit (the layout once per converter, before its first packet; the disposal on the decoder's
thread), the switches' names against docs/env_switches.tsv and the log lines against docs/reference/movies.md."""
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
        self.assertIn('getenv("DM_AAC_LAYOUT"); g_aac_layout = e && !strcmp(e, "1")', self.movie)   # opt-in in release 1

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


class SessionLoss(unittest.TestCase):   # a session iOS lost: upstream's replay (PR #2877) first, X1.0's restart at the next key frame as the fallback
    def test_replay_then_restart(self):
        vt = read('dm/host/hle_movie_vt.h')
        for fn in ('movie_vt_remember', 'movie_vt_replay', 'movie_vt_create', 'kVTDecodeFrame_DoNotOutputFrame'): self.assertIn(fn, vt)
        self.assertIn('int movie_vt_restart(void) { const char *e = getenv("DM_MOVIE_RESTART");', read('dm/host/hle_movie.c'))
        self.assertFalse((REPO / 'dm/host/hle_movie_vt_rebuild.h').exists())   # NX 18's earlier rebuild line, which copied every unit, stays out
        for rel in ('dm/host/hle_movie_avc.c', 'dm/host/hle_movie_av1.c'):
            src = read(rel)
            self.assertNotIn('vtr_', src, rel)
            self.assertLess(src.index('movie_vt_replay('), src.index('&& movie_vt_restart()'), rel)   # the replay is tried before the restart
        table = {ln.split('\t')[0] for ln in read('docs/env_switches.tsv').split('\n')}
        self.assertIn('DM_MOVIE_RESTART', table); self.assertNotIn('DM_VT_REBUILD', table)
        movies = read('docs/reference/movies.md')
        self.assertIn('### A movie decoder iOS ended in the background', movies)
        self.assertNotIn('### A VideoToolbox session lost while the app was suspended', movies)
        self.assertIn('- **Cost:**', movies)
        front = read('dm/ios/Sources/front_ios.m')
        self.assertIn('case 0: dm_movie_active(0);', front); self.assertIn('dm_movie_active(1); break;', front)   # the replay waits for the app to be active


class Documented(unittest.TestCase):
    def test_switches_and_lines(self):
        table = {ln.split('\t')[0] for ln in read('docs/env_switches.tsv').split('\n')}
        for sw in ('DM_AAC_LAYOUT', 'DM_AAC_FLUSH'): self.assertIn(sw, table)
        movies = read('docs/reference/movies.md')
        for heading in ('### AAC 5.1 in the console\'s channel order', '### AAC after a Flush starts afresh'):
            self.assertIn(heading, movies)
        for text in ("[movie] AAC: 6 channels in AudioToolbox's order", "handed out in the console's (MediaCodec's) order", "already the console's (MediaCodec's)",
                     'kept (DM_AAC_LAYOUT=0)', 'AudioToolbox gives no output channel layout', "a channel has no place in MediaCodec's order",
                     "AudioToolbox did not take the console's channel order"):
            self.assertIn(text, movies, text)
        movie = read('dm/host/hle_movie.c')
        for fmt in ("AudioToolbox gives no output channel layout", "a channel has no place in MediaCodec's order", "AudioToolbox did not take the console's channel order",
                    "handed out in the console's (MediaCodec's) order", "already the console's (MediaCodec's)", 'kept (DM_AAC_LAYOUT=0)'):
            self.assertIn(fmt, movie, fmt)
        mk = read('dm/host/tests/Makefile')
        self.assertIn('\t$(B)/t_mod_rows\n\t$(B)/t_aac_layout\n', mk)   # in make run, which CI's host tests run on macOS


if __name__ == '__main__':
    unittest.main()
