// A window texture whose first use is the present (Super Smash Bros. Ultimate and DRAGON QUEST XI S present theirs before drawing into it): present_enqueue resolves it on the
// submit thread, where it is made and zero-filled into an upload batch (tex_zero_fill), flushed at once outside a submission. With Metal encoding on its own thread that flush is
// only recorded and published, and nothing drains the encode thread until the next submission: the present thread must wait for the encode thread to commit it (pup_commit_wait)
// before its display command buffer goes straight to the queue. The encode thread is held in a block that sleeps, queued before the present: the present thread's commit must come
// after the block. Also: a present with no upload of its own that the display link shows in place of the one carrying the note still waits for it, and a submission that drained its
// only upload leaves the next present nothing to note. Real Metal 4 queue, no window; the display link's callback is called by hand
#include "../nvn/nvn_mtl.m"
@interface FakeLinkUpdate : NSObject
@property id<CAMetalDrawable> drawable;
@property CFTimeInterval targetPresentationTimestamp;
@end
@implementation FakeLinkUpdate
@end
static _Atomic int g_slept;        // the encode thread has left the sleeping block
static _Atomic int g_present_seen = -1;   // g_slept when present_now last asked for the layer (on the present thread or the display link's)
void *front_metal_layer(void) {    // present_now asks for the layer just before it takes a drawable; with none it returns, as without a window
    if (!pthread_main_np()) atomic_store(&g_present_seen, atomic_load(&g_slept));
    return NULL;
}
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)
#define SETUP(name, ok) do { int pass = !!(ok); failed += !pass; printf("setup, %s: %s\n", name, pass ? "ok" : "FAIL"); } while (0)   // what a case needs, not what it checks
static void hold_encoder(void) {   // in the encode thread's queue ahead of whatever is recorded next
    atomic_store(&g_slept, 0); atomic_store(&g_present_seen, -1);
    rec_queue_block(^{ usleep(300000); atomic_store(&g_slept, 1); });
}
static tex_t new_tex(unsigned serial) {   // never used before: no storage, made by its first use (an offset of its own: textures over the same storage share one Metal texture, tex_alias_key)
    tex_t t = {.magic = MAGIC('T', 'E', 'X', 0), .serial = serial, .off = (serial - 93000) * 0x10000};
    t.d.width = t.d.height = 8; t.d.depth = t.d.levels = t.d.samples = 1; t.d.target = NVN_TEXTURE_TARGET_2D; t.d.format = NVN_FORMAT_RGBA8;
    return t;
}
static NvMetalDisplayLinkDelegate *g_delegate;
static void *link_tick(void *arg) {   // one display-link callback, on a thread of its own as the link's (it does not look at the link)
    (void)arg;
    @autoreleasepool { FakeLinkUpdate *u = [FakeLinkUpdate new]; u.targetPresentationTimestamp = CACurrentMediaTime() + 0.016;
        [g_delegate metalDisplayLink:(CAMetalDisplayLink *)(id)u needsUpdate:(CAMetalDisplayLinkUpdate *)u]; }
    return NULL;
}
int main(void) { @autoreleasepool {
    alarm(60); setvbuf(stdout, NULL, _IONBF, 0);
    setenv("DM_NVN_ENC_THREAD", "1", 1);
    setenv("DM_PRESENT_LINK", "0", 1); setenv("DM_PRESENT_SNAP", "0", 1);   // presents on the present thread, straight from the game's texture
    mtl_init();
    mtl_sub_begin();   // the submit thread, and the encode thread started
    CHECK("an empty submission completes", mtl_wait(mtl_sub_commit(), 2000000000ull));
    CHECK("encoding runs on its own thread", rec_on() && g_rb_started);

    tex_t t = new_tex(93001);
    hold_encoder();
    uint64_t v0 = g_pup_v;
    uint64_t tk = mtl_present(&t, 1. / 60, NULL, NULL);
    CHECK("the present's fill is not left in an open upload batch", g_up_cb == nil);
    CHECK("the flushed batch is noted for the present thread", g_pup_v == v0 + 1);
    mtl_present_wait(tk);
    CHECK("present_now ran", atomic_load(&g_present_seen) >= 0);
    CHECK("the display command buffer is committed after the encode thread has committed the fill", atomic_load(&g_present_seen) == 1);

    // A texture already made: no batch is opened, nothing is noted, and the present does not wait for the encode thread
    v0 = g_pup_v;
    mtl_present_wait(mtl_present(&t, 1. / 60, NULL, NULL));
    CHECK("a present with no upload notes nothing", g_pup_v == v0 && g_up_cb == nil);

    // A texture made inside a submission: its fill's batch is flushed ahead of the submission's command buffer and on the queue once the commit drains the encode thread
    // (g_up_seq_drained). The next present has nothing to wait for and notes nothing
    tex_t u = new_tex(93002);
    mtl_sub_begin();
    unsigned seq0 = g_up_seq; tex_mtl(&u);
    SETUP("the texture made inside the submission opened an upload batch", g_up_seq != seq0 && g_up_cb != nil);
    SETUP("the submission completes", mtl_wait(mtl_sub_commit(), 2000000000ull));
    v0 = g_pup_v;
    mtl_present_wait(mtl_present(&t, 1. / 60, NULL, NULL));
    CHECK("a present after a submission that drained its only upload notes nothing", g_pup_v == v0);

    // The display link drops the present carrying the note: a new texture's present (its fill noted) and then a present of a texture already made (nothing of its own to note),
    // both queued while the encode thread is held. The link takes the newest (DM_PRESENT_TRIM=1: every tick finding two or more waiting), and that present's display command
    // buffer must still come after the fill the dropped one carried. Display-link mode without a link thread, as in t_present_alloc: the present thread leaves the queue to the callback
    g_link_trim = 1;
    pthread_mutex_lock(&g_pq_mu); g_dm_present_link = 1; g_link_started = 1; g_link_owns_layer = 1; pthread_mutex_unlock(&g_pq_mu);
    g_delegate = [NvMetalDisplayLinkDelegate new];
    tex_t w = new_tex(93003);
    hold_encoder();
    v0 = g_pup_v;
    uint64_t t1 = mtl_present(&w, 1. / 60, NULL, NULL), t2 = mtl_present(&t, 1. / 60, NULL, NULL);
    SETUP("the new texture's fill is noted and the second present notes nothing", g_pup_v == v0 + 1 && t2 == t1 + 1);
    CHECK("the present with no upload of its own carries the newest note", g_pq[(t2 - 1) % PQ].up_v == g_pup_v);
    uint64_t drop0 = g_link_dropped;
    pthread_t th; pthread_create(&th, NULL, link_tick, NULL); pthread_join(th, NULL);
    SETUP("the display link took the second present and dropped the first", g_pq_read == t2 && g_pq_done == t2 && g_link_dropped == drop0 + 1);
    CHECK("the display command buffer of the present shown in place of the noted one is committed after the encode thread has committed the fill", atomic_load(&g_present_seen) == 1);
    printf("t_present_fill: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
