// nn::vi::ListFrameHistory answers as the SDK fills FrameInfo (sdk 20.5.15 sdk+0x4510a0): a null buffer gets the history's size, 8; entries come newest first, status 2 for a
// frame the present queue handed on with a present tick, 1 for one still queued or dropped by the system, the frame numbers of GetLatestFrameNumber. Unreal's RHI takes the
// first status-2 entry as its latest flip (Minecraft Dungeons II main+0x142b0b0), so the newest shown frame has to come first
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
static void restart(const char *ticket_env) {   // a new start: an empty history and present queue, and DM_VI_FRAME_TICKET read again
    memset(g_vfh, 0, sizeof g_vfh); g_count = g_in = g_done = 0; memset(g_pt, 0, sizeof g_pt);
    if (ticket_env) setenv("DM_VI_FRAME_TICKET", ticket_env, 1); else unsetenv("DM_VI_FRAME_TICKET");
    atomic_store(&g_vfh_worker, -1);
}
static uint64_t ticks(uint64_t ns) { return ns * 12 / 625; }

int main(void) {
    uint64_t fi[10][5];
    unsetenv("DM_VI_FRAME_TICKET");
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
    // The present's ticket comes from the queue worker: until it has put the present in the present queue the entry is queued (status 1), even when every earlier present has
    // been handed on, and it is shown only once its own present has. Read at the game's call (as before this fix, since the queue worker) the ticket was the previous frame's,
    // so the newest frame was reported shown with the previous one's present time, and the very first one before anything was presented
    {
        restart(NULL);
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
        // the worker first (it may put the present in the queue before the game's call records the frame): the entry it makes has a queue time, the call keeps the ticket and sets its own
        g_gns += 16666667; g_hns += 16666667; uint64_t worker_at = g_gns; present_worker(3);
        assert(g_vfh[3].frame == 3 && g_vfh[3].ticket == 3 && g_vfh[3].queued_ns == worker_at);
        g_gns += 1000000; present_call();
        assert(g_vfh[3].ticket == 3 && g_vfh[3].queued_ns == g_gns && h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 3 && fi[0][0] == 1 && fi[0][2] == ticks(g_gns));
        g_done = 3; assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][0] == 2);
        // a ticket left in the ring by the frame 8 earlier is not this frame's
        for (int i = 0; i < 4; i++) present();                                                        // frames 4-7, tickets 4-7
        g_done = g_in; present_call();                                                                // frame 8: queued, though every present so far is handed on
        assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 8 && fi[0][0] == 1);
        present_worker(8); for (int i = 0; i < 8; i++) present();                                      // frames 9-16 reuse every slot
        g_done = g_in - 1; present_call();                                                            // frame 17 in frame 9's slot: queued, though ticket 9 is long handed on
        assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 17 && fi[0][0] == 1);
        // a worker 8 or more frames behind the game: an old frame's ticket leaves the newer frame in its slot alone, which stays listed and queued
        restart(NULL);
        for (int i = 0; i < 9; i++) present_call();                                                   // frames 1-9 called, none in the present queue yet; 9 in 1's slot
        uint64_t q9 = g_vfh[1].queued_ns;
        g_gns += 1000000; present_worker(1);                                                          // the worker reaches frame 1 now
        assert(g_vfh[1].frame == 9 && g_vfh[1].ticket == VFH_UNSENT && g_vfh[1].queued_ns == q9);
        g_done = g_in;                                                                                // ticket 1 handed on
        assert(h_vi_FrameHist(fi, 8, NULL) == 8 && fi[0][1] == 9 && fi[0][0] == 1);                     // 9 still listed first, queued
        for (int i = 0; i < 8; i++) assert(fi[i][0] == 1);                                             // and frames 2-9 have no present yet
        for (uint64_t f = 2; f <= 9; f++) present_worker(f);
        g_done = g_in; assert(h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 9 && fi[0][0] == 2);     // once its own present is handed on, 9 is shown
        // the game two frames ahead of a worker that lags: each frame queued until its own present is handed on, never shown with an earlier frame's time
        restart(NULL);
        int early = 0;
        for (int k = 1; k <= 30; k++) {
            present_call(); if (k > 2) present_worker((uint64_t)k - 2);                                    // the worker puts frame k - 2's present in the queue
            g_done = g_in; if (g_in < 64) g_pt[g_in] = (g_hns - 1000ull) / 1e9;                         // and it is handed on and presented at once
            int n2 = h_vi_FrameHist(fi, 8, NULL);
            for (int i = 0; i < n2; i++) early += fi[i][0] == 2 && fi[i][1] + 2 > (uint64_t)k;           // frames k and k - 1 have no present yet
            assert(n2 > 0 && fi[0][1] == (uint64_t)k && fi[0][0] == 1);
            g_gns += 16666667; g_hns += 16666667;
        }
        assert(early == 0);
    }
    // DM_VI_FRAME_TICKET=0: the ticket is read at the game's call, as before the fix (the device A/B's other leg): the worker's ticket is ignored, and with the present of the frame
    // before handed on the newest frame reads as shown already, the first frame too
    {
        restart("0");
        present_call();
        assert(g_vfh[1].ticket == 0 && h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 1 && fi[0][0] == 2);   // shown before anything was presented, as before
        present_worker(1); assert(g_vfh[1].ticket == 0);                                                       // the worker's ticket is not taken
        g_done = 1; present_call();
        assert(g_vfh[2].ticket == 1 && h_vi_FrameHist(fi, 1, NULL) == 1 && fi[0][1] == 2 && fi[0][0] == 2);   // frame 2 shown on frame 1's present
        restart("1"); present_call(); assert(g_vfh[1].ticket == VFH_UNSENT);                                   // any other value: the worker's ticket
        restart(NULL);
    }
    puts("vi frame history: count query 8, newest first, shown once handed on, presented or first-seen tick, dropped and queued frames not shown; a frame is queued until the "
         "queue worker gives it its own ticket, in either order, with a worker that lags, slot reuse, an old ticket leaving a newer frame alone; DM_VI_FRAME_TICKET=0 takes the ticket at the game's call as before");
    return 0;
}
