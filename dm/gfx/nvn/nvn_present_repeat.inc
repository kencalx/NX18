// ---------- Present repeat (DM_PRESENT_REPEAT=1, an X2.0 rider; off by default) ----------
// Included by nvn_mtl.m after the present snapshots (snap_take), before present_enqueue. With DM_PRESENT_REPEAT=1 the display link presents on every tick it counts: a tick
// without a new frame (an empty tick, and one held for a long present interval with nothing waiting) shows the last frame again, so iOS sees a present at the link's rate (60 or
// 30 Hz; the virtual ticks of link_range, which the callback filters first, alike). The A/B question (gpu-clock-collapse.md, candidate 3): whether the performance controller
// that drops the GPU clock in Breath of the Wild's heavy scenes reads the present cadence or the frames' completion. The idea is upstream's: keep iOS's frame pacing and the GPU
// clock steady.
// What is shown again is the last real frame's present snapshot, a host texture of the snapshot ring (DM_PRESENT_REPEAT=1 turns snapshots on, as frame generation does), never
// the game's own texture, which the game may be drawing into again: the repeat goes through the same present pass as the real frame (edge smoothing, MetalFX or bilinear
// scaling, Sharpening, picture fit, the touch controls), from the snapshot, onto the tick's drawable, so the drawable's content is the real frame's again. The slot is safe to
// read: its next copy (snap_take) is the one for the frame g_snap_n presents later, which can begin only once g_pq_in has reached ticket + g_snap_n - 1, so a repeat is made only
// while g_pq_in + 2 <= ticket + g_snap_n, and present_enqueue waits (g_rep_busy) while one is being encoded, so the queue cannot move past that until it is committed; the copy's
// queue barrier then orders it after the repeat on the GPU. With the default ring of 2 that is every empty tick; a tick held with the next frame already waiting is repeated
// only with a ring of 3 or more (DM_PRESENT_SNAP=3).
// A repeat is not a present: g_present_n, the presented-time ring (g_pres), g_pq_done and the hold (g_link_hold_until) are the real frames'; the display link's line still counts
// the tick as empty or held. It has three command allocators of its own (taken in turn; one still on the GPU passes the tick over rather than waiting) and counts in
// g_pq_inflight, so a suspend's drain waits for it; it is not made while presents are discarded (going to the background), after a GPU loss, in the rescue (the present thread
// takes drawables then) or before the link has shown a frame with a snapshot, and not after the present thread or a drop took a newer ticket (g_rep_ticket != g_pq_read).
// Off (unset or anything but "1") nothing here runs: the display link asks rep_on(), one cached load, only on an empty or held tick, after a real present, and present_fx_idle
// only while an effect's textures exist; present_enqueue's wait reads g_rep_busy, always 0. A status line every 600 repeats counts them and the ticks passed over.
static int rep_on(void) {
    static int v = -1; if (v >= 0) return v;
    const char *e = getenv("DM_PRESENT_REPEAT"); v = e && *e ? !strcmp(e, "1") : DM_GAME_PRESENT_REPEAT;   // the profile's present_repeat is the default (Bananza: the clock kick needs it)
    if (v) MLOG("present repeat (%s): the display link presents on every tick; a tick without a new frame shows the last frame's present snapshot again (not counted as a present); frame generation is off", e && *e ? "DM_PRESENT_REPEAT=1" : "profile present_repeat; DM_PRESENT_REPEAT=0 turns it off");
    return v;
}
static int g_rep_busy;   // under g_pq_mu: a repeat is being encoded from a snapshot slot (present_enqueue waits; rep_tick_locked)
static pq_item g_rep_it; static uint64_t g_rep_ticket;   // the last real frame the display link showed with a snapshot (link thread only; 0: none)
static id<MTL4CommandAllocator> g_rep_alloc[3]; static id<MTL4CommandBuffer> g_rep_cb[3]; static id<MTLBuffer> g_rep_uv[3];
static uint64_t g_rep_fence[3], g_rep_done[3], g_rep_n;   // g_rep_done: under g_pq_mu (the commit feedback)
static int g_rep_aa_ai, g_rep_fx_ai; static uint64_t g_rep_aa_seq, g_rep_fx_seq;   // under g_pq_mu: the last repeat whose present pass ran edge smoothing / MetalFX
static uint64_t g_rep_shown, g_rep_ring, g_rep_alloc_busy, g_rep_other;   // link thread: repeats committed; ticks passed over by the ring rule, a busy allocator, anything else
// The display link, after a real frame's present (it: the frame, ticket: its ticket, shown: present_now submitted it): the frame a later tick shows again
static void rep_note(const pq_item *it, uint64_t ticket, int shown) {
    if (shown && it->snap_v) { g_rep_it = *it; g_rep_ticket = ticket; } else g_rep_ticket = 0;
}
// present_fx_idle: a repeat whose present pass ran edge smoothing (aa) or the MetalFX scaler is still on the GPU
static int rep_effect_busy(int aa) {
    if (!rep_on()) return 0;
    pthread_mutex_lock(&g_pq_mu);
    int b = aa ? g_rep_aa_seq && g_rep_done[g_rep_aa_ai] < g_rep_aa_seq : g_rep_fx_seq && g_rep_done[g_rep_fx_ai] < g_rep_fx_seq;
    pthread_mutex_unlock(&g_pq_mu);
    return b;
}
static void rep_status(void) {
    if (!g_rep_shown || g_rep_shown % 600) return;
    MLOG("present repeat: %llu ticks showed the last frame again; passed over %llu (the next frame waiting with a ring of %d), %llu (its allocator still on the GPU), %llu (no frame, a newer ticket taken, presents discarded)",
         (unsigned long long)g_rep_shown, (unsigned long long)g_rep_ring, g_snap_n, (unsigned long long)g_rep_alloc_busy, (unsigned long long)g_rep_other);
}
// The display link's tick that takes no frame (empty, or held for the present interval), called under g_pq_mu, which it unlocks: shows the last frame again on dr. Returns 1 when
// it presented
static int rep_tick_locked(id<CAMetalDrawable> dr, double target_ts) {
    (void)target_ts;
    pq_item it = g_rep_it; uint64_t tk = g_rep_ticket; int k = -1;
    if (tk && tk == g_pq_read && it.snap_v && !g_fg_seq.has && !atomic_load(&g_present_discard) && !atomic_load(&g_gpu_lost))
        for (int i = 0; i < g_snap_n; i++) if (g_snap[i].serial == it.t.serial && atomic_load(&g_snap[i].ev) == it.snap_v && atomic_load(&g_snap[i].ticket) == tk) k = i;
    if (k < 0) { g_rep_other++; pthread_mutex_unlock(&g_pq_mu); return 0; }
    if (g_pq_in + 2 > tk + (uint64_t)g_snap_n) { g_rep_ring++; pthread_mutex_unlock(&g_pq_mu); return 0; }   // the frame that copies into this slot next may be on its way
    int ai = (int)(g_rep_n % 3);
    if (g_rep_done[ai] < g_rep_fence[ai]) { g_rep_alloc_busy++; pthread_mutex_unlock(&g_pq_mu); return 0; }
    g_rep_busy = 1;   // present_enqueue waits from here until the commit: the queue stays below the slot's next copy
    pthread_mutex_unlock(&g_pq_mu);
    int ok = 0;
    @autoreleasepool {
        id<MTLTexture> src = tex_mtl(&it.t);
        CAMetalLayer *layer = (__bridge CAMetalLayer *)front_metal_layer();
        if (!g_rep_alloc[ai]) {
            g_rep_alloc[ai] = [g_dev newCommandAllocator]; g_rep_cb[ai] = [g_dev newCommandBuffer];
            g_rep_uv[ai] = [g_dev newBufferWithLength:sizeof(float) * PRESENT_UV_FLOATS options:MTLResourceStorageModeShared]; if (g_rep_uv[ai]) res_add(g_rep_uv[ai]);
        }
        if (src && layer && dr && g_rep_alloc[ai] && g_rep_cb[ai] && g_rep_uv[ai]) {
            if (g_present_layer_resident != layer) { [g_q4 addResidencySet:layer.residencySet]; g_present_layer_resident = layer; }
            res_commit();
            [g_rep_alloc[ai] reset];
            [g_q4 waitForDrawable:dr];
            id<MTL4CommandBuffer> cb = g_rep_cb[ai];
            [cb beginCommandBufferWithAllocator:g_rep_alloc[ai]];
            int kind = present_encode_m4(cb, src, dr.texture, it.crop, g_rep_uv[ai], &g_fx_present, &g_aa_present);
            [cb endCommandBuffer];
            uint64_t seq = ++g_rep_n;
            pthread_mutex_lock(&g_pq_mu);
            int go = kind && !atomic_load(&g_present_discard);   // a suspend that began meanwhile: nothing more goes to the GPU (its drain counts g_pq_inflight from here)
            if (go) {
                g_pq_inflight++;
                if (kind & PRESENT_AA) { g_rep_aa_ai = ai; g_rep_aa_seq = seq; }   // present_fx_idle keeps them until this command buffer has completed (rep_effect_busy)
                if ((kind & ~PRESENT_AA) == PRESENT_METALFX) { g_rep_fx_ai = ai; g_rep_fx_seq = seq; }
            }
            pthread_mutex_unlock(&g_pq_mu);
            if (go) {
                MTL4CommitOptions *o = [MTL4CommitOptions new];
                uint64_t touch_seq = g_touch_seq; uint32_t touch_drew = g_touch_drew;   // as present_now's: the touch controls drawn from the front end's latest frame
                id<MTLTexture> keep_src = src;   // a Metal 4 command buffer retains nothing
                [o addFeedbackHandler:^(id<MTL4CommitFeedback> f) {
                    fb_in("present repeat"); (void)keep_src;
                    if (touch_seq > atomic_load_explicit(&g_touch_done, memory_order_relaxed)) atomic_store_explicit(&g_touch_done, touch_seq, memory_order_release);
                    uint32_t want = touch_drew && !f.error ? atomic_load_explicit(&g_touch_ack, memory_order_acquire) : 0;
                    if (want && touch_seq_since(touch_drew, want) && atomic_compare_exchange_strong(&g_touch_ack, &want, 0)) front_touch_drawn(touch_drew);
                    gpu_busy_note(f.GPUStartTime, f.GPUEndTime);
                    if (f.error) { MLOG("[RED] present repeat: command buffer error: %s", f.error.description.UTF8String); gpu_lost_check(f.error, "present repeat"); }
                    pthread_mutex_lock(&g_pq_mu); if (seq > g_rep_done[ai]) g_rep_done[ai] = seq; g_pq_inflight--; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
                    fb_out();
                }];
                id<MTL4CommandBuffer> buffers[] = {cb};
                if (gpu_gone()) gpu_gone_skip(); else [g_q4 commit:buffers count:1 options:o];   // nothing more is sent to a GPU taken as lost
                g_rep_fence[ai] = seq;
            }
            [g_q4 signalDrawable:dr];
            if (go) { [dr present]; ok = 1; }   // on the tick's own target time (the display link's drawable)
        }
    }
    pthread_mutex_lock(&g_pq_mu); g_rep_busy = 0; pthread_cond_broadcast(&g_pq_cv); pthread_mutex_unlock(&g_pq_mu);
    if (ok) { g_rep_shown++; rep_status(); }
    else g_rep_other++;
    return ok;
}
