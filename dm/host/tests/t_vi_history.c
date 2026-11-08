// nn::vi::ListFrameHistory answers as the SDK fills FrameInfo (sdk 20.5.15 sdk+0x4510a0): a null buffer gets the history's size, 8; entries come newest first, status 2 for a
// frame the present queue handed on with a present tick, 1 for one still queued or dropped by the system, the frame numbers of GetLatestFrameNumber. Unreal's RHI takes the
// first status-2 entry as its latest flip (Minecraft Dungeons II main+0x142b0b0), so the newest shown frame has to come first.
// Off (profile frame_history off, DM_VI_FRAME_HISTORY=0) every call returns 0, the count query too, and writes nothing, as before the host kept the history (Luigi's Mansion 3).
// The test sets DM_VI_FRAME_HISTORY itself, so it checks the same under any GAME's profile
#include "../../gfx/hle_vi.c"
#include <assert.h>

static uint64_t g_count, g_in, g_done, g_gns = 5000000000ull, g_hns = 9000000000ull;
static double g_pt[64];   // presented time per ticket (seconds on the now_ns clock), 0 not yet, -1 dropped
uint64_t dm_nvn_frame_count(void) { return g_count; }
void mtl_present_progress(uint64_t *q, uint64_t *d) { *q = g_in; *d = g_done; }
double mtl_presented_time(uint64_t n) { return n < 64 ? g_pt[n] : 0; }
void mtl_present_layer(uint32_t w, uint32_t h) { (void)w; (void)h; }
uint64_t guest_ns(void) { return g_gns; }
uint64_t now_ns(void) { return g_hns; }
int dm_sdk_ounce(void) { return 0; }
int dm_opmode(void) { return 0; }

// A present, as the host makes it since NXNative's queue worker (ea0c98df): the game's call records the frame (hle_nvn.c), then the worker puts its present in the present queue
// and tells the history its ticket (nvn_queue.inc); present_call and present_worker are the two halves, present both at once
static void present_call(void) { g_count++; dm_vi_frame_queued(g_count); }
static void present_worker(uint64_t frame) { g_in++; dm_vi_frame_ticket(frame, g_in); }
static void present(void) { present_call(); present_worker(g_count); }
static uint64_t ticks(uint64_t ns) { return ns * 12 / 625; }

static int decide(const char *env) {   // a fresh decision of the switch, as at a new start
    if (env) setenv("DM_VI_FRAME_HISTORY", env, 1); else unsetenv("DM_VI_FRAME_HISTORY");
    g_vfh_on = -1; return vfh_on();
}

int main(void) {
    uint64_t fi[10][5];
    // the switch: 0 / off and 1 / on override the profile either way; unset, or a value it does not take, keeps the profile's
    assert(decide(NULL) == DM_GAME_FRAME_HISTORY && decide("yes") == DM_GAME_FRAME_HISTORY && decide("") == DM_GAME_FRAME_HISTORY);
    assert(decide("0") == 0 && decide("off") == 0 && decide("on") == 1 && decide("1") == 1);   // on from here
    assert(h_vi_FrameHist(NULL, 0, NULL) == 8 && h_vi_FrameHist(fi, 0, NULL) == 8);   // the SDK's count query
    assert(h_vi_FrameHist(fi, 10, NULL) == 0);                                        // nothing presented yet
    for (int i = 0; i < 10; i++) { present(); g_gns += 16666667; g_hns += 16666667; }  // frames 1-10, tickets 1-10
    g_done = 7;                                   // 1-7 handed on, 8-10 still queued
    g_pt[7] = (g_hns - 100000000ull) / 1e9;       // 7 shown 0.1 s before host now
    g_pt[6] = -1;                                 // 6 dropped by the system
    memset(fi, 0xa5, sizeof fi);
    int n = h_vi_FrameHist(fi, 10, NULL);
    assert(n == 8);                               // the last 8: frames 10 down to 3
    for (int k = 0; k < n; k++) assert(fi[k][1] == (uint64_t)(10 - k));
    for (int k = 0; k < 3; k++) assert(fi[k][0] == 1 && fi[k][3] == 0 && fi[k][4] == 0);   // 10, 9, 8: queued
    assert(fi[3][0] == 2 && fi[3][3] == fi[3][4] && fi[3][3] == ticks(g_gns - 100000000ull));   // 7: its presented time on the guest clock
    assert(fi[4][0] == 1 && fi[4][3] == 0);       // 6: dropped
    assert(fi[5][0] == 2 && fi[5][3] == ticks(g_gns));   // 5: handed on, no presented time (headless): the time it was first seen
    assert(fi[0][2] == ticks(5000000000ull + 9 * 16666667ull));   // queue tick of frame 10
    assert(fi[8][0] == 0xa5a5a5a5a5a5a5a5ull);    // nothing written past the entries returned
    g_gns += 1000000000ull;
    n = h_vi_FrameHist(fi, 10, NULL);
    assert(fi[5][3] == ticks(g_gns - 1000000000ull));   // the first-seen time stays
    assert(h_vi_FrameHist(fi, 2, NULL) == 2 && fi[0][1] == 10 && fi[1][1] == 9);   // a smaller buffer gets the newest
    // queued (profile frame_history queued, DM_VI_FRAME_HISTORY=queued): the same 8 frames, every one shown, the queued (8-10) and the dropped (6) too, queue tick and both present
    // ticks its queue time less VFH_LEAD_NS (present - queue 0); the present queue's progress is not read. Only the word "queued" takes it
    assert(decide("queued") == 2 && decide("2") == DM_GAME_FRAME_HISTORY && decide("Queued") == DM_GAME_FRAME_HISTORY && decide("queued") == 2);
    assert(h_vi_FrameHist(NULL, 0, NULL) == 8);
    uint64_t seen5 = g_vfh[5].seen_ns;
    memset(fi, 0xa5, sizeof fi);
    assert(h_vi_FrameHist(fi, 10, NULL) == 8);
    for (int k = 0; k < 8; k++) { uint64_t q = ticks(5000000000ull + (uint64_t)(9 - k) * 16666667ull - VFH_LEAD_NS);
        assert(fi[k][0] == 2 && fi[k][1] == (uint64_t)(10 - k) && fi[k][2] == q && fi[k][3] == q && fi[k][4] == q); }
    assert(fi[8][0] == 0xa5a5a5a5a5a5a5a5ull && g_vfh[5].seen_ns == seen5);   // nothing past the entries; "on"'s first-seen time untouched
    assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 10 && fi[0][0] == 2);   // the render thread's 1-entry call: the newest frame, shown
    assert(decide("1") == 1);
    // off: the frames above are still recorded, but every call answers 0, the count query too, and writes nothing
    assert(decide("0") == 0);
    memset(fi, 0xa5, sizeof fi);
    assert(h_vi_FrameHist(NULL, 0, NULL) == 0 && h_vi_FrameHist(fi, 0, NULL) == 0 && h_vi_FrameHist(fi, 10, NULL) == 0 && h_vi_FrameHist(fi, 1, NULL) == 0);
    for (int k = 0; k < 10; k++) for (int j = 0; j < 5; j++) assert(fi[k][j] == 0xa5a5a5a5a5a5a5a5ull);
    for (int i = 0; i < 2; i++) present();        // presents go on being recorded while it is off
    assert(decide("1") == 1 && h_vi_FrameHist(fi, 10, NULL) == 8 && fi[0][1] == 12);   // and on again (a new start), the history has them
    // the window line's counts: calls by what they ask, entries and shown entries, reset once 300 presents have passed since the window began
    g_vfs = (vfh_stats){.from = g_count};
    h_vi_FrameHist(NULL, 0, NULL); h_vi_FrameHist(fi, 1, NULL); h_vi_FrameHist(fi, 8, NULL);
    assert(g_vfs.calls == 3 && g_vfs.count == 1 && g_vfs.one == 1 && g_vfs.more == 1 && g_vfs.ents == 9 && g_vfs.shown == 2);   // shown: frames 7 and 5 of the 8-entry call, none of the 1-entry call (12, queued)
    for (int i = 0; i < 300; i++) present();
    h_vi_FrameHist(fi, 1, NULL);
    assert(g_vfs.calls == 0 && g_vfs.from == g_count);   // logged and begun again
    assert(decide("0") == 0); h_vi_FrameHist(fi, 8, NULL);
    assert(g_vfs.calls == 1 && g_vfs.more == 1 && g_vfs.ents == 0);   // counted with it off too
    // Luigi's Mansion 3's present command (main+0xb7a4b8) given the queued answer at the interval 2 it set: wait A (newest entry queued: sleep a 60 Hz frame and ask again) never
    // sleeps, and wait B (sleep until 16.67 ms after the newest entry's present tick) holds no present past where the frame was ready. Each frame starts at a 16.67 ms vsync (the
    // host's acquire), its present is ready 6 ms later, the game's sleep overshoots by 0.1 ms and the host's present takes 0.05 ms before it records the frame. Without the lead wait B
    // would bind from the second frame and push each present 0.15 ms later, and the 72nd would miss its vsync
    {
        assert(decide("queued") == 2);
        const uint64_t D = 16666667, T = 16666667, w = 6000000, over = 100000, h = 50000;
        uint64_t v0 = g_gns + D, worst = 0; int wa = 0, wb = 0, got = 0;
        for (uint64_t k = 0; k < 600; k++) {
            uint64_t v = v0 + k * D, now = v + w;
            if (h_vi_FrameHist(fi, 1, NULL) == 1) { got++;
                if (fi[0][0] == 1) wa++;
                uint64_t until = fi[0][3] * 625 / 12 + T;
                if (now < until) { now = until + over; wb++; }
            }
            if (now - v > worst) worst = now - v;
            g_gns = now + h; present();
        }
        assert(got == 600 && wa == 0 && wb == 0 && worst == w);
    }
    // The same present command with the history on (DM_VI_FRAME_HISTORY=1) and the host's present queue two frames behind, so the newest entry is always still queued (the case
    // asks for it after each present and checks that). Given interval 1, wait A runs interval - 1 = 0 times and wait B (interval 2 or more) not at all: no present is held, though the
    // history is on and its newest entry queued. At 2 (DM_FPS_TARGET=30, or the game's own interval) wait A sleeps a 60 Hz frame at every present, on top of the frame's work: the
    // game's own 30 fps pacing, which is why Luigi's Mansion 3's profile keeps frame_history off at Frame rate 30 (its note, Frame rate). This models the game's loop given an
    // interval; which interval the host answers (hle_nvn.c window_interval: in display mode the one the window presents at, NXNative's 028a2631) is checked by t_nvn's three
    // window_interval checks, on the Mac
    {
        assert(decide("1") == 1);
        for (int interval = 1; interval <= 2; interval++) {
            int slept = 0, queued = 0;
            for (int k = 0; k < 120; k++) {
                for (int i = 0; i < interval - 1; i++) {   // wait A
                    if (h_vi_FrameHist(fi, 1, NULL) != 1 || fi[0][0] != 1) break;
                    slept++; g_gns += 16666667; g_hns += 16666667;
                }
                present(); g_done = g_in - 2;   // handed on two frames behind
                queued += h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][0] == 1 && fi[0][1] == g_count;
                g_gns += 16666667; g_hns += 16666667;
            }
            assert(queued == 120 && (interval == 1 ? slept == 0 : slept == 120));
        }
    }
    // The present's ticket comes from the queue worker: until it has put the present in the present queue the entry is queued (status 1), even when every earlier present has
    // been handed on, and it is shown only once its own present has. Read at the game's call (as before the fix after the merge of 028a2631) the ticket was the previous
    // frame's, so the newest frame was reported shown with the previous one's present time, and the very first one before anything was presented
    {
        assert(decide("1") == 1);
        memset(g_vfh, 0, sizeof g_vfh); g_count = g_in = g_done = 0; memset(g_pt, 0, sizeof g_pt);   // a new start
        present_call();
        assert(h_vi_FrameHist(fi, 8, NULL) == 1 && fi[0][1] == 1 && fi[0][0] == 1 && fi[0][3] == 0);   // the first frame: queued, nothing presented yet
        present_worker(1); assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][0] == 1);                    // in the present queue, not handed on
        g_done = 1; g_pt[1] = (g_hns - 5000000ull) / 1e9;
        assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][0] == 2 && fi[0][3] == ticks(g_gns - 5000000ull));   // handed on: shown at its presented time
        g_gns += 16666667; g_hns += 16666667; present_call();                                            // frame 2: the game's call; every earlier present handed on
        assert(h_vi_FrameHist(fi, 2, NULL) == 2 && fi[0][1] == 2 && fi[0][0] == 1 && fi[1][0] == 2);     // 2 queued, 1 shown
        present_worker(2); assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][0] == 1);
        g_done = 2; g_pt[2] = (g_hns - 1000000ull) / 1e9;
        assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][0] == 2 && fi[0][3] == ticks(g_gns - 1000000ull));   // its own present time, not frame 1's
        // the worker first (it may put the present in the queue before the game's call records the frame): the ticket is kept, the call sets the queue time
        g_gns += 16666667; g_hns += 16666667; present_worker(3); present_call();
        assert(g_vfh[3].ticket == 3 && g_vfh[3].queued_ns == g_gns && h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 3 && fi[0][0] == 1 && fi[0][2] == ticks(g_gns));
        g_done = 3; assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][0] == 2);
        // a ticket left in the ring by the frame 8 earlier is not this frame's
        for (int i = 0; i < 4; i++) present();                                                        // frames 4-7, tickets 4-7
        g_done = g_in; present_call();                                                                // frame 8: queued, though every present so far is handed on
        assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 8 && fi[0][0] == 1);
        present_worker(8); for (int i = 0; i < 8; i++) present();                                      // frames 9-16 reuse every slot
        g_done = g_in - 1; present_call();                                                            // frame 17 in frame 9's slot: queued, though ticket 9 is long handed on
        assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 17 && fi[0][0] == 1);
    }
    puts("vi frame history: count query 8, newest first, shown once handed on, presented or first-seen tick, dropped and queued frames not shown; off: 0 for every call, nothing written; "
         "DM_VI_FRAME_HISTORY overrides the profile both ways; window counts; queued: every frame shown at its queue tick, LM3's waits A and B do not hold a present; on: at interval 1 "
         "wait A never sleeps on a queued newest entry, at 2 it sleeps a frame at every present; a frame is queued until the queue worker gives it its own ticket");
    return 0;
}
