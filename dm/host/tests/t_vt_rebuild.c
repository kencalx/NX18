// A VideoToolbox session made again after it was lost (../hle_movie_vt_rebuild.h), driven with a fake decoder: plain C, no Apple framework, no game data.
// The fake decoder's picture for a unit is a hash of every unit since the last key frame, as a real decoder's picture depends on its references, and a unit it decodes
// without a key frame since it was made counts as wrong. Each case loses the session at one decode call and checks the pictures handed out against an uninterrupted
// decode: the same, all of them (the units since the key frame are decoded again and their pictures thrown away), or, past the cap, the same but for the units from the
// loss to the next key frame, which are not decoded at all. Also: other errors, the switch off (as before), a session that cannot be made again at once, two losses in one
// GOP, a unit that always fails (the pictures, and one decode call a packet, as with the switch off: no rebuild per packet), a loss back straight after the rebuild (while
// catching up or on the packet: stuck to the next key frame), a flush, and the AV1 key frame test on synthetic OBUs and on a real SVT-AV1 temporal unit
#include "../hle_movie_vt_rebuild.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

enum { UNITS = 60, GOP = 20 };
typedef struct {
    int valid, have_key; uint64_t state;
    int calls, lose_at, lose_again_at, bad_at; int32_t lose_with;
    int fail_unit; int32_t fail_with; const uint8_t *fail_p; size_t fail_n;   // fail_unit (1-based): that unit always answers fail_with, in any session, which goes on
    int remakes, remake_fail;
    uint64_t pic[UNITS * 4]; int npic, wrong, discarded;
} fake;
static int32_t fake_decode(void *ctx, const uint8_t *p, size_t n, int discard) {
    fake *f = ctx; f->calls++;
    if (f->calls == f->lose_at || f->calls == f->lose_again_at) f->valid = 0;
    if (!f->valid) return f->lose_with;
    if (f->calls == f->bad_at) return -12909;   // kVTVideoDecoderBadDataErr: the unit gives nothing, the session goes on
    if (f->fail_unit && n == f->fail_n && !memcmp(p, f->fail_p, n)) return f->fail_with;   // a frame the decoder fails on (-12911 from its callback): nothing, the session goes on
    if (p[0] == 'K') { f->state = 1469598103934665603ull; f->have_key = 1; }
    else if (!f->have_key) f->wrong++;
    for (size_t i = 0; i < n; i++) f->state = (f->state ^ p[i]) * 1099511628211ull;
    if (discard) f->discarded++;
    else f->pic[f->npic++] = f->have_key ? f->state : 0;
    return 0;
}
static int fake_remake(void *ctx) {
    fake *f = ctx; f->remakes++;
    if (f->remake_fail > 0) { f->remake_fail--; return 0; }
    f->valid = 1; f->have_key = 0; f->state = 0; return 1;
}
static uint8_t g_units[UNITS][24];
static size_t unit(int i, const uint8_t **p) {   // unit i: K or P, its number, and a length that varies
    uint8_t *u = g_units[i]; u[0] = i % GOP ? 'P' : 'K';
    size_t n = 4 + (size_t)(i * 7 % 20); for (size_t k = 1; k < n; k++) u[k] = (uint8_t)(i * 31 + k);
    *p = u; return n;
}
typedef struct { vtr_report r[UNITS]; int32_t st[UNITS]; int calls[UNITS], remakes[UNITS]; } run_log;   // calls, remakes: what each unit's vtr_decode made
static void run(fake *f, vtr_state *s, run_log *L) {
    vtr_ops o = {f, fake_decode, fake_remake};
    f->valid = 1;
    if (f->fail_unit) f->fail_n = unit(f->fail_unit - 1, &f->fail_p);
    for (int i = 0; i < UNITS; i++) {
        const uint8_t *p; size_t n = unit(i, &p); int c = f->calls, m = f->remakes;
        L->st[i] = vtr_decode(s, &o, p, n, p[0] == 'K', &L->r[i]);
        L->calls[i] = f->calls - c; L->remakes[i] = f->remakes - m;
    }
}
static fake g_ref;
static void reference(void) {
    vtr_state s; vtr_init(&s, 0); run_log L; g_ref = (fake){0}; run(&g_ref, &s, &L);
    assert(g_ref.npic == UNITS && !g_ref.wrong && !g_ref.remakes);
    vtr_free(&s);
}
// The pictures of f are the reference's, but for the units [skip_from, skip_to)
static void same_but(const fake *f, int skip_from, int skip_to) {
    int k = 0;
    for (int i = 0; i < UNITS; i++) { if (i >= skip_from && i < skip_to) continue; assert(k < f->npic && f->pic[k] == g_ref.pic[i]); k++; }
    assert(k == f->npic && !f->wrong);
}
static int call_of(int u) { return u + 1; }   // the decode call of unit u while nothing was decoded again

static void lost_mid_gop(int32_t err) {   // lost at unit 25, 5 units into the GOP from 20: made again, 20..24 again, then 25: every picture as the reference's
    fake f = {.lose_at = call_of(25), .lose_with = err}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    same_but(&f, 0, 0);
    assert(f.remakes == 1 && f.discarded == 5);
    assert(L.st[25] == 0 && L.r[25].rebuilt == 1 && L.r[25].refed == 5 && L.r[25].err == err && !L.r[25].dropping && !L.r[25].failed && L.r[25].kept == 6);
    for (int i = 0; i < UNITS; i++) if (i != 25) assert(!L.r[i].rebuilt && !L.r[i].err && L.st[i] == 0);
    vtr_free(&s);
    printf("lost 5 units into a GOP (%s): made again, 5 units decoded again and thrown away, every picture as an uninterrupted decode's\n", vtr_err_name(err));
}
static void lost_at_key(void) {   // lost at the key frame 40: made again, nothing to decode again
    fake f = {.lose_at = call_of(40), .lose_with = VTR_INVALID_SESSION}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    same_but(&f, 0, 0);
    assert(f.remakes == 1 && !f.discarded && L.r[40].rebuilt == 1 && !L.r[40].refed && L.r[40].kept == 1);
    vtr_free(&s);
    puts("lost at a key frame: made again, nothing decoded again, every picture the same");
}
static void lost_at_gop_end(void) {   // lost at unit 39, the GOP's last: 19 units again
    fake f = {.lose_at = call_of(39), .lose_with = VTR_INVALID_SESSION}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    same_but(&f, 0, 0);
    assert(f.remakes == 1 && f.discarded == 19 && L.r[39].refed == 19 && L.r[39].kept == 20);
    vtr_free(&s);
    puts("lost at a GOP's last unit: 19 units decoded again, every picture the same");
}
static void other_errors(void) {   // a bad unit is the decoder's answer, as before: nothing made again, the unit gives no picture
    fake f = {.bad_at = call_of(25)}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    assert(L.st[25] == -12909 && !L.r[25].rebuilt && !f.remakes && f.npic == UNITS - 1);
    assert(!vtr_lost_err(-12909) && !vtr_lost_err(0) && !vtr_lost_err(-12913) && vtr_lost_err(-12903) && vtr_lost_err(-12911));
    vtr_free(&s);
    puts("other errors (-12909): returned as before, no session made again");
}
static void past_the_cap(void) {   // 4 units at most: lost 6 units into a GOP, the units past the loss give nothing until the key frame at 40, then the pictures go on as the reference's
    fake f = {.lose_at = call_of(25), .lose_with = VTR_INVALID_SESSION}; vtr_state s; vtr_init(&s, 1); s.max_units = 4; run_log L; run(&f, &s, &L);
    same_but(&f, 25, 40);
    assert(L.st[25] == VTR_DROPPED && L.r[25].rebuilt == 1 && L.r[25].dropping && !L.r[25].refed && !L.r[25].kept);
    for (int i = 26; i < 40; i++) assert(L.st[i] == VTR_DROPPED && !L.r[i].rebuilt && !L.r[i].dropping);   // one line: only at the loss
    assert(L.st[40] == 0 && !s.dropping && f.remakes == 1 && f.calls == 25 + 1 + 20);
    for (int i = 0; i < UNITS; i++) assert(L.r[i].kept <= 4);
    vtr_free(&s);
    // by bytes: units are 4 to 23 bytes, and the GOP from 20 passes 100 bytes at unit 28
    fake g = {.lose_at = call_of(30), .lose_with = VTR_INVALID_SESSION}; vtr_init(&s, 1); s.max_bytes = 100; run(&g, &s, &L);
    same_but(&g, 30, 40);
    assert(L.st[30] == VTR_DROPPED && L.r[30].dropping && !s.buf);   // the memory went back when the cap was passed
    vtr_free(&s);
    puts("past the cap (units, bytes): made again without them, pictures dropped until the next key frame, then the same");
}
static void switched_off(void) {   // DM_VT_REBUILD=0: nothing kept, nothing made again: the lost session answers every unit after it, as before
    fake f = {.lose_at = call_of(25), .lose_with = VTR_INVALID_SESSION}; vtr_state s; vtr_init(&s, 0); run_log L; run(&f, &s, &L);
    assert(f.npic == 25 && !f.remakes && !s.buf && !s.n);
    for (int i = 25; i < UNITS; i++) assert(L.st[i] == VTR_INVALID_SESSION && !L.r[i].rebuilt);
    same_but(&f, 25, UNITS);
    vtr_free(&s);
    puts("DM_VT_REBUILD=0: the session stays lost, nothing kept, as before");
}
static void remake_fails_once(void) {   // the first try to make it again fails: unit 25 gives nothing, 26 makes it and decodes 20..25 again
    fake f = {.lose_at = call_of(25), .lose_with = VTR_INVALID_SESSION, .remake_fail = 1}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    same_but(&f, 25, 26);
    assert(L.st[25] == VTR_INVALID_SESSION && L.r[25].failed && !L.r[25].rebuilt);
    assert(L.st[26] == 0 && L.r[26].rebuilt == 1 && L.r[26].refed == 6 && L.r[26].err == VTR_INVALID_SESSION && f.remakes == 2);
    vtr_free(&s);
    puts("not made again at once: that packet gives nothing, the next one makes it and catches up");
}
static void lost_while_catching_up(void) {   // lost at 25, and again on the third unit decoded again: the loss back straight after the rebuild is taken for the data's,
    // so to the key frame at 40 every unit goes once into that session (lost here, so none gives a picture) and nothing is made again; 40 makes it again and goes on
    fake f = {.lose_at = call_of(25), .lose_again_at = call_of(25) + 3, .lose_with = VTR_INVALID_SESSION}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    same_but(&f, 25, 40);
    assert(L.st[25] == VTR_INVALID_SESSION && L.r[25].rebuilt == 1 && L.r[25].refed == 3 && L.r[25].again == VTR_INVALID_SESSION && L.calls[25] == 1 + 3 + 1);
    for (int i = 26; i < 40; i++) assert(L.st[i] == VTR_INVALID_SESSION && !L.r[i].err && L.calls[i] == 1 && !L.remakes[i]);
    assert(L.st[40] == 0 && L.r[40].rebuilt == 1 && !L.r[40].refed && !L.r[40].again && L.r[40].err == VTR_INVALID_SESSION && f.remakes == 2 && !s.stuck);
    vtr_free(&s);
    puts("lost again while catching up: stuck to the next key frame (one decode call a packet, nothing made again), which makes it again");
}
static void lost_again_on_the_retry(void) {   // lost at 25, made again, caught up, and lost again on 25 itself: the same, stuck to 40
    fake f = {.lose_at = call_of(25), .lose_again_at = call_of(25) + 6, .lose_with = VTR_DECODER_MALFUNCTION}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    same_but(&f, 25, 40);
    assert(L.st[25] == VTR_DECODER_MALFUNCTION && L.r[25].refed == 5 && L.r[25].again == VTR_DECODER_MALFUNCTION && L.calls[25] == 1 + 5 + 1 && L.remakes[25] == 1);
    for (int i = 26; i < 40; i++) assert(L.calls[i] == 1 && !L.remakes[i]);
    assert(L.st[40] == 0 && L.remakes[40] == 1 && f.remakes == 2);
    vtr_free(&s);
    puts("lost again on the packet decoded again: stuck to the next key frame, which makes it again");
}
static void unit_always_fails(void) {   // unit 25 always answers -12911, in any session, which goes on: one rebuild, then as with the switch off
    fake off = {.fail_unit = 26, .fail_with = VTR_DECODER_MALFUNCTION}; vtr_state s; vtr_init(&s, 0); run_log L; run(&off, &s, &L);
    assert(L.st[25] == VTR_DECODER_MALFUNCTION && off.npic == UNITS - 1 && !off.remakes);
    vtr_free(&s);
    fake f = {.fail_unit = 26, .fail_with = VTR_DECODER_MALFUNCTION}; vtr_init(&s, 1); run(&f, &s, &L);
    assert(f.npic == off.npic && !memcmp(f.pic, off.pic, sizeof f.pic) && !f.wrong);   // every picture the switch-off run's: the made-again session is caught up to the same state
    assert(L.st[25] == VTR_DECODER_MALFUNCTION && L.r[25].rebuilt == 1 && L.r[25].refed == 5 && L.r[25].again == VTR_DECODER_MALFUNCTION && L.calls[25] == 1 + 5 + 1);
    for (int i = 26; i < UNITS; i++) assert(L.calls[i] == 1 && !L.remakes[i] && !L.r[i].err && L.st[i] == 0);   // each later packet: one decode call, no session
    assert(f.remakes == 1 && f.calls == UNITS + 5 + 1 && !s.stuck);   // the key frame at 40 ended it
    vtr_free(&s);
    puts("a unit that always fails (-12911): made again once, then one decode call a packet and the switch-off run's pictures");
}
static void two_losses_one_gop(void) {   // lost at 25 and, after a rebuild that went through, again at 30: made again both times, every picture the reference's
    fake f = {.lose_at = call_of(25), .lose_again_at = call_of(30) + 5 + 1, .lose_with = VTR_INVALID_SESSION}; vtr_state s; vtr_init(&s, 1); run_log L; run(&f, &s, &L);
    same_but(&f, 0, 0);
    assert(L.r[25].rebuilt == 1 && L.r[25].refed == 5 && !L.r[25].again && L.r[30].rebuilt == 1 && L.r[30].refed == 10 && !L.r[30].again && f.remakes == 2);
    vtr_free(&s);
    puts("two losses in one GOP, the first rebuild through: made again both times, every picture the same");
}
static void flush(void) {   // a flush between GOPs: the kept units start over with the next key frame, and a dropping or stuck decoder stops
    vtr_state s; vtr_init(&s, 1); fake f = {0}; f.valid = 1; vtr_ops o = {&f, fake_decode, fake_remake}; vtr_report r; const uint8_t *p;
    for (int i = 0; i < 5; i++) { size_t n = unit(i, &p); assert(!vtr_decode(&s, &o, p, n, p[0] == 'K', &r)); }
    assert(s.n == 5);
    vtr_reset(&s); assert(!s.n && !s.len && !s.over && !s.dropping);
    s.dropping = 1; s.stuck = 1; vtr_reset(&s); assert(!s.dropping && !s.stuck);
    size_t n = unit(20, &p); assert(!vtr_decode(&s, &o, p, n, 1, &r) && s.n == 1);
    vtr_free(&s);
    puts("flush: the kept units start over");
}
static void av1_key(void) {
    static const uint8_t svt[] = {   // t_codec_video.c's SVT-AV1 temporal unit: temporal delimiter, sequence header (profile 0, 64x64), frame (a shown key frame)
        0x12,0x00,0x0a,0x0b,0x02,0x00,0x00,0x04,0x95,0x7f,0xfc,0x0a,0xf9,0x00,0x40,0x32,0x15,0x10,0x00,0xbc,0x00,0x49,0x22,0x08,0x08,0x21,0x10,0x00,0xad,0x3b,0x67,0x00,
        0x1e,0xb5,0xdb,0x79,0x52,0x90,
    };
    assert(vtr_av1_key(svt, sizeof svt));
    for (size_t n = 0; n < sizeof svt; n++) assert(!vtr_av1_key(svt, n));   // cut short: an OBU whose size runs past the end is not read
    uint8_t tu[] = {0x12, 0x00, 0x0a, 0x01, 0x00, 0x32, 0x01, 0x10};   // delimiter, a 1-byte sequence header (not reduced), a frame: show_existing 0, KEY_FRAME, show_frame 1
    assert(vtr_av1_key(tu, sizeof tu));
    tu[7] = 0x30; assert(!vtr_av1_key(tu, sizeof tu));   // frame_type 1, an inter frame
    tu[7] = 0x50; assert(!vtr_av1_key(tu, sizeof tu));   // frame_type 2, intra-only: not a random access point
    tu[7] = 0x00; assert(!vtr_av1_key(tu, sizeof tu));   // a hidden key frame
    tu[7] = 0x80; assert(!vtr_av1_key(tu, sizeof tu));   // show_existing_frame
    tu[7] = 0x10; tu[5] = 0x1a; assert(vtr_av1_key(tu, sizeof tu));   // a frame header OBU (type 3) as well as a frame (type 6)
    tu[5] = 0x32; tu[4] = 0x08; tu[7] = 0x30; assert(vtr_av1_key(tu, sizeof tu));   // reduced_still_picture_header: every frame is a key frame
    tu[4] = 0x00;
    static const uint8_t no_seq[] = {0x12, 0x00, 0x32, 0x01, 0x10};   // a key frame without its sequence header: not counted, more units kept, never fewer
    assert(!vtr_av1_key(no_seq, sizeof no_seq));
    static const uint8_t ext[] = {0x0e, 0x00, 0x01, 0x00, 0x36, 0x00, 0x01, 0x10};   // both OBUs with an extension byte
    assert(vtr_av1_key(ext, sizeof ext));
    static const uint8_t no_size[] = {0x08, 0x00, 0x30, 0x10};   // no size fields: not the low-overhead format
    assert(!vtr_av1_key(no_size, sizeof no_size));
    static const uint8_t long_size[] = {0x0a, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01};   // a size of more than 8 bytes of leb128
    assert(!vtr_av1_key(long_size, sizeof long_size));
    static const uint8_t past_end[] = {0x0a, 0x05, 0x00, 0x32, 0x01};   // a size past the end
    assert(!vtr_av1_key(past_end, sizeof past_end));
    puts("AV1 random access points: a sequence header with a shown key frame (or a reduced still picture) only");
}
static void lines(void) {   // the log line of each outcome, and its kind (2: [RED], 1: plain, 0: none)
    vtr_state s; vtr_init(&s, 1); char t[320];
    vtr_report r = {.err = VTR_INVALID_SESSION, .rebuilt = 1, .refed = 5, .kept = 6};
    assert(vtr_report_text(&s, &r, "H.264", "IDR", t, sizeof t) == 1);
    assert(!strcmp(t, "H.264: VideoToolbox session made again after -12903 (kVTInvalidSessionErr): 5 packets since the last IDR decoded again, their pictures thrown away (DM_VT_REBUILD)"));
    r = (vtr_report){.err = VTR_DECODER_MALFUNCTION, .rebuilt = 1, .dropping = 1};
    assert(vtr_report_text(&s, &r, "AV1", "key frame", t, sizeof t) == 2);
    assert(!strcmp(t, "AV1: VideoToolbox session lost (-12911, kVTVideoDecoderMalfunctionErr) and made again past the 300 packets or 32 MB kept since the last key frame: "
                      "none decoded until the next key frame, the last picture stays (DM_VT_REBUILD)"));
    r = (vtr_report){.err = VTR_INVALID_SESSION, .failed = 1, .kept = 7};
    assert(vtr_report_text(&s, &r, "H.264", "IDR", t, sizeof t) == 2);
    assert(!strcmp(t, "H.264: VideoToolbox session lost (-12903, kVTInvalidSessionErr) and not made again: the next packet tries again, 7 since the last IDR kept"));
    r = (vtr_report){.err = VTR_DECODER_MALFUNCTION, .rebuilt = 1, .refed = 5, .again = VTR_DECODER_MALFUNCTION};
    assert(vtr_report_text(&s, &r, "H.264", "IDR", t, sizeof t) == 2);
    assert(!strcmp(t, "H.264: VideoToolbox answered -12911 (kVTVideoDecoderMalfunctionErr) again in the session made again after -12911, 5 packets decoded again: the data's error, "
                      "not the session's; until the next IDR the packets go into this session as they are, and it is not made again (DM_VT_REBUILD)"));
    r.refed = 299; assert(vtr_report_text(&s, &r, "AV1", "key frame", t, sizeof t) == 2 && strlen(t) < sizeof t - 1);   // the longest fits the callers' 320 bytes
    r = (vtr_report){0}; assert(!vtr_report_text(&s, &r, "H.264", "IDR", t, sizeof t));
    unsigned due = 0; for (int i = 0; i < 64; i++) due += (unsigned)vtr_log_due(&s);
    assert(due == 4 + 4);   // the 1st to 4th, then the 8th, 16th, 32nd and 64th
    puts("log lines: made again (plain), past the cap, not made again, back after the rebuild ([RED]); the first 4 a decoder, then every 2^k-th");
}
int main(void) {
    reference();
    lost_mid_gop(VTR_INVALID_SESSION);
    lost_mid_gop(VTR_DECODER_MALFUNCTION);
    lost_at_key();
    lost_at_gop_end();
    other_errors();
    past_the_cap();
    switched_off();
    remake_fails_once();
    lost_while_catching_up();
    lost_again_on_the_retry();
    unit_always_fails();
    two_losses_one_gop();
    flush();
    av1_key();
    lines();
    assert(VTR_MAX_UNITS == 300 && VTR_MAX_BYTES == 32u << 20);
    puts("t_vt_rebuild: ok");
    return 0;
}
