#include "nvn_capture.h"
#include "nvn_hmap.h"
#include <os/lock.h>

void *objc_autoreleasePoolPush(void);
void objc_autoreleasePoolPop(void *);

// Ready continuations of NVN queues share the renderer's one ordered Metal queue.
// An unresolved wait parks its queue, never the submitting CPU or another queue.
typedef struct nq_receipt { unsigned refs, published; uint64_t fence, present; struct nq_receipt *spare_next; } nq_receipt;   // spare_next: the free list (nq_pooled)
typedef struct nq_node {
    struct nq_node *next;
    uint8_t *bytes; size_t length, capacity;
    unsigned kind, mode, closed, waiting; volatile uint32_t *event; uint32_t value;   // event, mode, value: an NQ_EVENT node's wait
    struct nq_signal { volatile uint32_t *word; unsigned mode; uint32_t value; } *signals; unsigned nsignals, signals_cap;   // an NQ_COMMANDS node's GPU event signals in recorded order, issued at its completion (nq_event_issued)
    struct nq_signal signal0; uint64_t signal_set;   // signal0: the first signal, so a node of one signal (split mode) allocates no array (nq_pooled); signal_set: this node's mark in nq_signal_words (nq_signal_on)
    uint64_t wait_fence, event_predecessor; unsigned wait_kind; const sync_t *sync_source; nq_receipt *receipt;
    tex_t texture; double period; int crop[4];
} nq_node;
typedef struct nq_owned { struct nq_owned *next; unsigned kind; uint64_t data[]; } nq_owned;
typedef struct nq_job { struct nq_job *next; nq_node *first, *last; nq_receipt *receipt; nq_owned *owned; nvn_hmap objects; uint64_t frame; } nq_job;
static void nq_job_free(nq_job *j) {
    for(nq_owned *o=j->owned,*next;o;o=next) { next=o->next; if(o->kind==CAP_K_PROG) mtl_prog_unpin((prog_t *)o->data); else if(o->kind==CAP_K_TEX) mtl_tex_unpin(((tex_t *)o->data)->serial); free(o); }
    free(j->objects.keys); free(j->objects.vals); free(j);
}
static int nq_snapshot_address(void *ctx,uint64_t *field,uint64_t len,int writable) { (void)ctx;(void)field;(void)len;(void)writable;return 1; }
static int nq_snapshot_object(void *ctx,int kind,uint64_t *field,uint8_t *payload,uint32_t size) {
    (void)payload;(void)size; nq_job *j=ctx; if(!*field || (kind!=CAP_K_PROG && kind!=CAP_K_TEX)) return 1;
    uint64_t key[2]={*field,(unsigned)kind}; nq_owned *o=nvn_hm_get(&j->objects,key);
    if(!o) {
        size_t bytes=kind==CAP_K_PROG?sizeof(prog_t):sizeof(tex_t); o=calloc(1,sizeof *o+bytes); if(!o) die("queue descriptor allocation failed");
        o->kind=kind; o->next=j->owned; j->owned=o;
        if(kind==CAP_K_PROG) mtl_prog_snapshot((prog_t *)o->data,(const prog_t *)(uintptr_t)*field);
        else { memcpy(o->data,(const void *)(uintptr_t)*field,bytes); mtl_tex_pin(((tex_t *)o->data)->serial); }
        nvn_hm_put(&j->objects,key,o);
    }
    *field=(uintptr_t)o->data;return 1;
}
static const cap_ops nq_snapshot_ops={nq_snapshot_address,nq_snapshot_object};
typedef struct nq_queue {
    struct nq_queue *next; uint64_t serial, physical, present; int origin;
    nq_job *first, *last; nq_receipt *tail;
} nq_queue;
static pthread_mutex_t nq_mu = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t nq_cv = PTHREAD_COND_INITIALIZER;
static pthread_once_t nq_once = PTHREAD_ONCE_INIT;
static nq_queue *nq_queues;
static int nq_test_held;   // nvn_queue_test_hold: replay takes no queued work while set (unit tests only)
static _Atomic uint64_t nq_event_polls;   // the replay's 1 ms polls for a mapped event word that ended by their timeout (the threads line, power_line): one host wakeup each
// The last GPU write of each event word not yet landed: its submission's fence, and for a WRITE signal the value it leaves (exact). A wait the queued value satisfies needs no
// completion: its continuation is encoded after the writer's on the one ordered Metal queue, as the next submission of one NVN queue is, and memory the writer's completion lands
// on the CPU (reports, render-target readbacks) is that same in-flight case. An ADD's result depends on the writes landing before it, so such a wait still waits for them
// The entries are found by word in a hash map (nq_event_words) and kept in a list in fence order, oldest first, so nvn_queue_gpu_progress takes the landed ones off its head. Each signal used to
// walk a list of every word written and not yet landed, under nq_mu on the replay thread: on an M4 Max 0.26 ms a frame for NieR:Automata's 850 signals on the same words each frame (0.003 ms
// now), 1.8 ms with 850 fresh words and three frames in flight, and 21 ms with 2,000 (0.03 ms now). Entries taken off go to a free list (NQ_EVENT_SPARES) instead of free. DM_NVN_EVENT_MAP=0
// keeps the walked list, newest first, one calloc and one free per entry.
// Both give the same answers: one entry per word, holding its last write, removed once that write's fence has completed (all of them with a fence at or below the completed one)
typedef struct nq_event_write { struct nq_event_write *next, *prev; volatile uint32_t *word; uint64_t fence; uint32_t value; int exact; } nq_event_write;
static nq_event_write *nq_event_writes, *nq_event_newest;   // map: in fence order from the oldest, nq_event_newest the last; list (DM_NVN_EVENT_MAP=0): newest first, singly linked
static nvn_hmap nq_event_words;   // word pointer (8-byte key) -> its nq_event_write (map only)
static nq_event_write *nq_event_spare; static unsigned nq_event_nspare;
enum { NQ_EVENT_SPARES=4096 };
static int nq_event_map=-1;   // 1 map, 0 list (a unit test may set it directly while nothing is recorded)
static _Atomic uint64_t nq_stat_event_writes, nq_stat_event_ns; static unsigned nq_stat_event_peak;   // the queue line: writes recorded, time in this bookkeeping on the replay thread and in GPU progress, most words in flight
static unsigned nq_event_nlist;   // entries in the list when the map is off (DM_NVN_EVENT_MAP=0), so the queue line counts the words in flight with either; the map keeps its own count (nq_event_words.n)
static int nq_event_map_on(void) {
    if(nq_event_map<0) { const char *e=getenv("DM_NVN_EVENT_MAP"); int on=!(e && !strcmp(e,"0")); if(!on) LOG("[nvn] GPU event writes kept in a list and a node's signals scanned (DM_NVN_EVENT_MAP=0)"); nq_event_map=on; }
    return nq_event_map;
}
static int nq_event_mapped(void) {   // under nq_mu
    int on=nq_event_map_on(); if(on && !nq_event_words.klen) nvn_hm_init(&nq_event_words,8);
    return on;
}
static unsigned nq_event_inflight(void) { return nq_event_mapped()?nq_event_words.n:nq_event_nlist; }   // under nq_mu: the event words with a write not yet landed
static nq_event_write *nq_event_write_of(volatile uint32_t *word) {
    if(nq_event_mapped()) return nvn_hm_get(&nq_event_words,&word);
    nq_event_write *w=nq_event_writes; while(w && w->word!=word) w=w->next; return w;
}
static uint64_t nq_event_pending(volatile uint32_t *word) { nq_event_write *w=nq_event_write_of(word); return w?w->fence:0; }
static void nq_event_unlink(nq_event_write *w) {   // map only
    if(w->prev) w->prev->next=w->next; else nq_event_writes=w->next;
    if(w->next) w->next->prev=w->prev; else nq_event_newest=w->prev;
    w->next=w->prev=NULL;
}
// Fences come from one ordered Metal queue in issue order, so an entry nearly always goes last; an older fence (a unit test) goes to its place, so the list stays in fence order
static void nq_event_place(nq_event_write *w) {   // map only
    nq_event_write *after=nq_event_newest;
    if(after && after->fence>w->fence) { if(nq_event_writes->fence>=w->fence) after=NULL; else while(after->fence>w->fence) after=after->prev; }
    w->prev=after; w->next=after?after->next:nq_event_writes;
    if(w->next) w->next->prev=w; else nq_event_newest=w;
    if(after) after->next=w; else nq_event_writes=w;
}
static void nq_event_issued(volatile uint32_t *word,uint64_t fence,unsigned mode,uint32_t value) {
    atomic_fetch_add_explicit(&nq_stat_event_writes,1,memory_order_relaxed);
    if(!nq_event_mapped()) {
        nq_event_write *w=nq_event_write_of(word);
        if(!w) { w=calloc(1,sizeof *w); if(!w) die("event ordering allocation failed"); w->word=word; w->next=nq_event_writes; nq_event_writes=w; if(++nq_event_nlist>nq_stat_event_peak) nq_stat_event_peak=nq_event_nlist; }
        w->fence=fence; w->value=value; w->exact=mode==0; return;
    }
    nq_event_write *w=nvn_hm_get(&nq_event_words,&word);
    if(w) nq_event_unlink(w);
    else {
        if(nq_event_spare) { w=nq_event_spare; nq_event_spare=w->next; nq_event_nspare--; memset(w,0,sizeof *w); }
        else if(!(w=calloc(1,sizeof *w))) die("event ordering allocation failed");
        w->word=word; nvn_hm_put(&nq_event_words,&word,w);
        if(nq_event_words.n>nq_stat_event_peak) nq_stat_event_peak=nq_event_words.n;
    }
    w->fence=fence; w->value=value; w->exact=mode==0; nq_event_place(w);
}
static void nq_event_landed(uint64_t done) {   // under nq_mu: forget the writes whose fence has completed
    if(!nq_event_mapped()) {
        nq_event_write **p=&nq_event_writes;
        while(*p) { nq_event_write *w=*p; if(w->fence<=done) { *p=w->next; free(w); nq_event_nlist--; } else p=&w->next; }
        return;
    }
    while(nq_event_writes && nq_event_writes->fence<=done) {
        nq_event_write *w=nq_event_writes; nq_event_unlink(w); nvn_hm_del(&nq_event_words,&w->word);
        if(nq_event_nspare<NQ_EVENT_SPARES) { w->next=nq_event_spare; nq_event_spare=w; nq_event_nspare++; } else free(w);
    }
}

enum { NQ_COMMANDS, NQ_EVENT, NQ_SYNC, NQ_FENCE, NQ_PRESENT };
// Free lists of nodes and receipts. In split mode (signal_events split / DM_NVN_SIGNAL_EVENTS=split; the default for every game but NieR:Automata until the issue #2112 merge, a fallback
// since), each GPU event signal made a command node, an NQ_FENCE node, that node's receipt and a signals
// array: four allocations on the submitting thread and four frees on the replay thread per signal. A node now keeps its first signal inline (signal0), and nodes and receipts come from these
// lists, at most NQ_POOL_MAX of each kept (a node is 296 bytes, a receipt 32: at most about 330 KB in all). The lists have a lock of their own, taken with no other held after it: nodes and receipts are made under
// g_sub_mu, nq_mu or neither, and given back under nq_mu. A recycled receipt is no more of a hazard to a stale pointer than freed memory malloc hands out again. DM_NVN_NODE_POOL=0 allocates and
// frees each one, with no inline signal, as before. The queue line counts them, with the command nodes that started without a spare command copy (nq_spare_take)
static os_unfair_lock nq_pool_mu=OS_UNFAIR_LOCK_INIT;
enum { NQ_POOL_MAX=1024 };
static nq_node *nq_node_pool; static nq_receipt *nq_receipt_pool; static unsigned nq_node_npool, nq_receipt_npool;
static int nq_pool=-1;   // 1 free lists and inline signal, 0 off (a unit test may set it directly)
static _Atomic uint64_t nq_stat_nodes, nq_stat_nodes_pooled, nq_stat_receipts, nq_stat_receipts_pooled, nq_stat_no_spare;
static int nq_pooled(void) {
    if(nq_pool<0) { const char *e=getenv("DM_NVN_NODE_POOL"); int on=!(e && !strcmp(e,"0")); if(!on) LOG("[nvn] queue nodes and receipts allocated one by one (DM_NVN_NODE_POOL=0)"); nq_pool=on; }
    return nq_pool;
}
static nq_node *nq_node_new(void) {
    nq_node *n=NULL; atomic_fetch_add_explicit(&nq_stat_nodes,1,memory_order_relaxed);
    if(nq_pooled()) { os_unfair_lock_lock(&nq_pool_mu); if((n=nq_node_pool)) { nq_node_pool=n->next; nq_node_npool--; } os_unfair_lock_unlock(&nq_pool_mu); }
    if(n) { memset(n,0,sizeof *n); atomic_fetch_add_explicit(&nq_stat_nodes_pooled,1,memory_order_relaxed); }
    else if(!(n=calloc(1,sizeof *n))) die("queue continuation allocation failed");
    return n;
}
static void nq_node_free(nq_node *n) {
    if(n->signals!=&n->signal0) free(n->signals);
    free(n->bytes);
    if(nq_pooled()) { os_unfair_lock_lock(&nq_pool_mu); if(nq_node_npool<NQ_POOL_MAX) { n->next=nq_node_pool; nq_node_pool=n; nq_node_npool++; n=NULL; } os_unfair_lock_unlock(&nq_pool_mu); }
    free(n);
}
static nq_receipt *nq_new(void) {
    nq_receipt *r=NULL; atomic_fetch_add_explicit(&nq_stat_receipts,1,memory_order_relaxed);
    if(nq_pooled()) { os_unfair_lock_lock(&nq_pool_mu); if((r=nq_receipt_pool)) { nq_receipt_pool=r->spare_next; nq_receipt_npool--; } os_unfair_lock_unlock(&nq_pool_mu); }
    if(r) { memset(r,0,sizeof *r); atomic_fetch_add_explicit(&nq_stat_receipts_pooled,1,memory_order_relaxed); }
    else if(!(r=calloc(1,sizeof *r))) die("queue receipt allocation failed");
    r->refs=1; return r;
}
static void nq_put(nq_receipt *r) {
    if(!r || --r->refs) return;
    if(nq_pooled()) { os_unfair_lock_lock(&nq_pool_mu); if(nq_receipt_npool<NQ_POOL_MAX) { r->spare_next=nq_receipt_pool; nq_receipt_pool=r; nq_receipt_npool++; r=NULL; } os_unfair_lock_unlock(&nq_pool_mu); }
    free(r);
}
static void nq_set_sync(sync_t *s,nq_receipt *r) { if(s->fenced==3) nq_put((nq_receipt *)(uintptr_t)s->fence); r->refs++; s->fence=(uintptr_t)r; s->fenced=3; }
void nvn_sync_release(sync_t *s) { pthread_mutex_lock(&nq_mu); if(s->fenced==3) nq_put((nq_receipt *)(uintptr_t)s->fence); s->fenced=0; s->fence=0; pthread_mutex_unlock(&nq_mu); }
static nq_queue *nq_get(queue_t *q) {
    nq_queue *p=nq_queues; while(p && p->serial!=q->serial) p=p->next;
    if(!p) { p=calloc(1,sizeof *p); if(!p) die("queue state allocation failed"); p->serial=q->serial; p->origin=q->origin_ll; p->next=nq_queues; nq_queues=p; }
    return p;
}
static void nq_publish(nq_receipt *r,uint64_t fence) { r->fence=fence; r->published=1; pthread_cond_broadcast(&nq_cv); }
static int nq_predicate(uint32_t current,unsigned mode,uint32_t target) { return mode==0 ? current==target : (uint32_t)(current-target)<0x80000000u; }
static int nq_sync_encoded(const sync_t *s,uint64_t *fence) {
    if(s->fenced==3) { nq_receipt *r=(nq_receipt *)(uintptr_t)s->fence; if(!r->published) return 0; *fence=r->fence; return 1; }
    if(!s->fenced) return 0; *fence=s->fence; return 1;
}
void nvn_queue_gpu_progress(void) {
    pthread_mutex_lock(&nq_mu); uint64_t t0=nq_event_writes?now_ns():0;
    if(t0) { nq_event_landed(mtl_completed_fence()); atomic_fetch_add_explicit(&nq_stat_event_ns,now_ns()-t0,memory_order_relaxed); }
    pthread_cond_broadcast(&nq_cv); pthread_mutex_unlock(&nq_mu);
}
static void nq_event_publish(volatile uint32_t *word,unsigned mode,uint32_t value,uint64_t gpu_fence) {
    pthread_mutex_lock(&nq_mu);
    if(mode==1) atomic_fetch_add_explicit((_Atomic uint32_t *)word,value,memory_order_release);
    else atomic_store_explicit((_Atomic uint32_t *)word,value,memory_order_release);
    atomic_thread_fence(memory_order_seq_cst);
    // Latch waits already reached: a subsequent signal must not erase a release.
    for(nq_queue *q=nq_queues;q;q=q->next) if(q->first && q->first->first) {
        nq_node *n=q->first->first;
        if(n->kind==NQ_EVENT && n->waiting && n->event==word && (gpu_fence ? gpu_fence>=n->event_predecessor : nq_event_pending(word)<=mtl_completed_fence()) && nq_predicate(atomic_load_explicit((_Atomic uint32_t *)word,memory_order_acquire),n->mode,n->value)) { n->event=NULL; n->wait_fence=gpu_fence; }
    }
    pthread_cond_broadcast(&nq_cv); pthread_mutex_unlock(&nq_mu);
}
void nvn_event_publish(volatile uint32_t *word,unsigned mode,uint32_t value) { nq_event_publish(word,mode,value,0); }
void nvn_event_publish_gpu(volatile uint32_t *word,unsigned mode,uint32_t value,uint64_t fence) { nq_event_publish(word,mode,value,fence); }
static void nq_snapshot_sync(nq_node *n,const sync_t *s) {
    n->wait_kind=s->fenced; n->wait_fence=s->fence;
    if(s->fenced==3) { n->receipt=(nq_receipt *)(uintptr_t)s->fence; n->receipt->refs++; }
}
// The submit-cost probes run once per nvn_queue_submit and once per replayed COMMANDS or PRESENT node, so in split mode once per GPU event signal. By default a reading is one THREAD_BASIC_INFO
// call on a port kept per thread (hle_nvn.c thr_times) plus thread_selfcounts: about 0.9 us a scope on an M4 Max. DM_NVN_SUBMIT_PROBES=full keeps the earlier reading, clock_gettime for the CPU
// time and mach_thread_self, thread_info and mach_port_deallocate for the kernel time (thr_sys_ns), about 1.6 us a scope; both feed the same translation lines. The kernel figure there is lower
// by default, since the earlier reading's own port calls ran inside the scope (in t_wait_event 1.8 against 3.3 ms for 4,000 scopes of about 10 us)
static int nq_probes_full=-1;
static int nq_probe_full(void) {
    if(nq_probes_full<0) { const char *e=getenv("DM_NVN_SUBMIT_PROBES"); nq_probes_full=e && !strcmp(e,"full"); if(nq_probes_full) LOG("[nvn] submit-cost probes: full (DM_NVN_SUBMIT_PROBES=full): clock_gettime plus a thread port made and released per reading"); }
    return nq_probes_full;
}
typedef struct { uint64_t wall, cpu, instr, cycles, sys; } nq_cost;
static nq_cost nq_cost_begin(void) {
    nq_cost c={.wall=now_ns()};
    if(nq_probe_full()) { c.cpu=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); c.sys=thr_sys_ns(); } else thr_times(&c.cpu,&c.sys);
    thr_counts(&c.instr,&c.cycles); return c;
}
static void nq_cost_end(nq_cost c) {
    int full=nq_probe_full(); uint64_t dw=now_ns()-c.wall, cpu=0, sys=0, ins, cyc;
    if(full) cpu=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID); else thr_times(&cpu,&sys);
    thr_counts(&ins,&cyc); if(full) sys=thr_sys_ns();
    uint64_t dc=cpu-c.cpu;
    atomic_fetch_add(&g_nvn_ns,dw); atomic_fetch_add(&g_sub_wall_ns,dw); atomic_fetch_add(&g_cum_sub_wall_ns,dw);
    atomic_fetch_add(&g_sub_cpu_ns,dc); atomic_fetch_add(&g_cum_sub_cpu_ns,dc);
    atomic_fetch_add(&g_sub_instr,ins-c.instr); atomic_fetch_add(&g_cum_sub_instr,ins-c.instr);
    atomic_fetch_add(&g_cum_sub_cyc,cyc-c.cycles); atomic_fetch_add(&g_cum_sub_sys_ns,sys-c.sys);
}
// The command copies (nq_bytes) of replayed nodes go to the next submissions' nodes instead of free (nq_spare_take / nq_spare_give), so a steady frame allocates none. Both run under g_sub_mu: the
// submitting thread copies the commands (nq_flatten) and the worker replays them (nq_worker) holding it. At most NQ_SPARES are kept, none over NQ_SPARE_MAX (a load's long stream is freed)
enum { NQ_SPARES=4 };
#define NQ_SPARE_MAX ((size_t)4<<20)
static struct { uint8_t *bytes; size_t capacity; } nq_spare[NQ_SPARES]; static int nq_nspare;
static void nq_spare_take(nq_node *n) { if(nq_nspare) { nq_nspare--; n->bytes=nq_spare[nq_nspare].bytes; n->capacity=nq_spare[nq_nspare].capacity; } else atomic_fetch_add_explicit(&nq_stat_no_spare,1,memory_order_relaxed); }
static void nq_spare_give(nq_node *n) { if(n->bytes && n->capacity<=NQ_SPARE_MAX && nq_nspare<NQ_SPARES) { nq_spare[nq_nspare].bytes=n->bytes; nq_spare[nq_nspare].capacity=n->capacity; nq_nspare++; n->bytes=NULL; n->capacity=0; } }
// When the queue line is due: the first time the replay's frame passes a multiple of 300 after the last line, given the frames since it (0 when not due); the first frame seen only sets the
// baseline. frame is the frame of the last replayed job, and it goes back whenever jobs of two queues interleave (a job of frame 599 on one queue waiting on a frame-600 job of another), so a
// frame at or below the last line's is ignored: compared by its multiple of 300 alone, such a frame wrote a line of zeros over a wrapped frame count and moved the baseline back, and the next
// job's line then counted the jobs between as one frame
static uint64_t nq_report_due(uint64_t frame,uint64_t *reported) {
    if(frame==UINT64_MAX) return 0;
    if(*reported==UINT64_MAX) { *reported=frame; return 0; }
    if(frame<=*reported || frame/300==*reported/300) return 0;
    uint64_t frames=frame-*reported; *reported=frame; return frames;
}
// The queue line, from the replay thread every 300 frames with no lock held: per frame, the nodes and receipts made and how many came from the free lists (nq_pooled), the command nodes that
// started without a spare copy (they allocate it as they grow), the GPU event writes recorded (nq_event_issued) and the time this bookkeeping took on the replay thread and in GPU progress,
// with the event words in flight now and the most at once since the start, counted with the map and with the list (DM_NVN_EVENT_MAP=0) alike
static void nq_report(uint64_t frame,uint64_t frames) {
    static uint64_t p[8]; uint64_t v[8]={atomic_load(&nq_stat_nodes),atomic_load(&nq_stat_nodes_pooled),atomic_load(&nq_stat_receipts),atomic_load(&nq_stat_receipts_pooled),atomic_load(&nq_stat_no_spare),atomic_load(&nq_stat_event_writes),atomic_load(&nq_stat_event_ns),0};
    pthread_mutex_lock(&nq_mu); unsigned peak=nq_stat_event_peak, inflight=nq_event_inflight(); pthread_mutex_unlock(&nq_mu);
    double nf=frames?(double)frames:1;
    LOG("[nvn] queue up to frame %llu, per frame: nodes %.1f (%.1f from the free list), receipts %.1f (%.1f from the free list), command nodes without a spare copy %.1f; GPU event writes %.1f, their bookkeeping %.3f ms; event words in flight %u, at most %u",
        frame,(v[0]-p[0])/nf,(v[1]-p[1])/nf,(v[2]-p[2])/nf,(v[3]-p[3])/nf,(v[4]-p[4])/nf,(v[5]-p[5])/nf,(v[6]-p[6])/1e6/nf,inflight,peak);
    memcpy(p,v,sizeof p);
}
static void *nq_worker(void *unused) {
    (void)unused; pthread_setname_np("NVN queue replay");
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE,0);
    uint64_t frame=UINT64_MAX, reported=UINT64_MAX;
    for(;;) {
        pthread_mutex_lock(&nq_mu); nq_queue *q=NULL; nq_node *n=NULL; nq_job *j=NULL;
        for(;;) {
        scan_again:;
            if(nq_test_held) { pthread_cond_wait(&nq_cv,&nq_mu); continue; }
            int mapped_event_wait=0;
            for(q=nq_queues;q;q=q->next) {
                j=q->first; if(!j) continue; n=j->first;
                if(!n) { nq_publish(j->receipt,q->physical); q->first=j->next; if(!q->first) q->last=NULL; nq_put(j->receipt);
                    pthread_mutex_unlock(&nq_mu); pthread_mutex_lock(&g_sub_mu); void *pool=objc_autoreleasePoolPush(); nq_job_free(j); objc_autoreleasePoolPop(pool); pthread_mutex_unlock(&g_sub_mu); pthread_mutex_lock(&nq_mu); goto scan_again; }
                if(n->kind==NQ_EVENT && n->event) {
                    uint64_t predecessor=nq_event_pending(n->event);
                    if(!n->waiting) n->event_predecessor=predecessor;
                    // The queued GPU write satisfies the wait: the GPU runs this continuation after it (nq_event_write). Ocarina of Time waits on about 25 events a frame; each wait
                    // for the writer's completion left the GPU idle while the host encoded the next submission, 2 ms of its 14.5 ms frame, which its dynamic resolution read as work
                    nq_event_write *queued=predecessor>mtl_completed_fence() ? nq_event_write_of(n->event) : NULL;
                    if(queued && queued->exact && nq_predicate(queued->value,n->mode,n->value)) break;
                    if(predecessor>mtl_completed_fence() || !nq_predicate(atomic_load_explicit((_Atomic uint32_t *)n->event,memory_order_acquire),n->mode,n->value)) { n->waiting=1; mapped_event_wait=1; continue; }
                }
                if(n->kind==NQ_SYNC) {
                    if(n->receipt && !n->receipt->published) continue;
                    // Targets are immutable snapshots. One Metal queue orders an encoded producer before this continuation. A sync not yet fenced when the wait was submitted
                    // (wait_kind 0) is a snapshot of nothing to wait for, and the wait passes. Sparking! ZERO, on one NVN queue, waits on a sync before that queue's own first
                    // fence of it at its first load, which runs on the console; parked here, the fence behind the wait never published and its SyncWait stalled the game (#1808)
                }
                break;
            }
            if(q) break;
            // NVN events can also be changed by plain stores through mapped pool memory.
            // A bounded notification poll only while such a word is awaited complements API/callback wakes.
            if(mapped_event_wait) { struct timespec tick={0,1000000}; if(pthread_cond_timedwait_relative_np(&nq_cv,&nq_mu,&tick)==ETIMEDOUT) atomic_fetch_add_explicit(&nq_event_polls,1,memory_order_relaxed); }
            else pthread_cond_wait(&nq_cv,&nq_mu);
        }
        j->first=n->next; if(!j->first) j->last=NULL;
        // Round-robin ready queues: a continually fed independent producer cannot starve another queue.
        if(q->next) { nq_queue **link=&nq_queues; while(*link!=q) link=&(*link)->next; *link=q->next; nq_queue *tail=nq_queues; while(tail->next) tail=tail->next; tail->next=q; q->next=NULL; }
        if(n->kind==NQ_SYNC || n->kind==NQ_EVENT) { uint64_t f=n->receipt?n->receipt->fence:n->wait_fence; if(f>q->physical) q->physical=f; }
        if(n->kind==NQ_FENCE) nq_publish(n->receipt,q->physical);
        pthread_mutex_unlock(&nq_mu);
        uint64_t fence=0, present=0;
        if(n->kind==NQ_COMMANDS || n->kind==NQ_PRESENT) {
            dm_host_mutex_lock(&g_sub_mu); void *pool=objc_autoreleasePoolPush();
            dm_host_work++; mtl_prepare(); dm_host_work--;
            gfx_enter(); nq_cost cost=nq_cost_begin();
            if(frame!=j->frame) { frame=j->frame; mtl_set_frame(frame); }
            mtl_queue_activate(q->serial); mtl_set_queue_origin_lower_left(q->origin);
            if(n->kind==NQ_COMMANDS) {
                uint64_t handle=(uintptr_t)n->bytes;
                nvn_cap_submit(1,&handle);
                mtl_sub_begin(); nvn_ft_poll(); mtl_sub_index(&handle,1);
                mtl_exec_rest(NULL,0); mtl_exec(n->bytes); fence=mtl_sub_commit();
            } else {
                nvn_cap_present(&n->texture,n->crop);
                present=mtl_present(&n->texture,n->period,n->crop); mtl_tex_unpin(n->texture.serial);
            }
            nq_cost_end(cost); gfx_leave(); objc_autoreleasePoolPop(pool); if(n->kind==NQ_COMMANDS) nq_spare_give(n); pthread_mutex_unlock(&g_sub_mu);
        }
        pthread_mutex_lock(&nq_mu); if(n->kind==NQ_PRESENT) { q->present=present; j->receipt->present=present; }
        if(fence) { q->physical=fence; if(n->nsignals) { uint64_t t0=now_ns(); for(unsigned i=0;i<n->nsignals;i++) nq_event_issued(n->signals[i].word,fence,n->signals[i].mode,n->signals[i].value); atomic_fetch_add_explicit(&nq_stat_event_ns,now_ns()-t0,memory_order_relaxed); } }
        if(n->receipt) nq_put(n->receipt); nq_node_free(n); pthread_cond_broadcast(&nq_cv); pthread_mutex_unlock(&nq_mu);
        uint64_t frames=nq_report_due(frame,&reported); if(frames) nq_report(frame,frames);
    }
    return NULL;
}
static void nq_start(void) { pthread_t t; if(pthread_create(&t,NULL,nq_worker,NULL)) die("NVN queue worker failed"); pthread_detach(t); }
static nq_node *nq_append(nq_job *j,unsigned kind) { nq_node *n=nq_node_new(); n->kind=kind; if(j->last) j->last->next=n; else j->first=n; j->last=n; return n; }
// A node's command copy grows by doubling (from 4 KB): growing 4 KB at a time took a reallocation for every 4 KB, each possibly a copy of all before it, under g_sub_mu
static void nq_bytes(nq_node *n,const void *bytes,size_t length) { if(n->length+length>n->capacity) { size_t want=(n->length+length+4095)&~(size_t)4095, grown=n->capacity*2; n->capacity=grown>want?grown:want; n->bytes=realloc(n->bytes,n->capacity); if(!n->bytes) die("queue commands allocation failed"); } memcpy(n->bytes+n->length,bytes,length); n->length+=length; } // NOLINT(bugprone-suspicious-realloc-usage): allocation failure aborts, so the old buffer cannot leak into a continuing process
// Where a GPU event signal leaves the commands around it (profile key signal_events; DM_NVN_SIGNAL_EVENTS=node / split overrides it). node (the default, upstream's behaviour since
// issue #2112): the signal stays inside its node, which goes on to the next wait (WAIT_EVENT, WAIT_SYNC), FENCE_SYNC or the end of the submitted commands, and the node's signals publish in
// recorded order when the whole node completes: each still after every GPU write before it (post_run in nvn_mtl.m publishes the events last), only later. split (a fallback): the signal
// ends its command node, so the node's Metal submission ends there and the event publishes once the work before it completes. NieR:Automata follows each of its occlusion queries with a
// SignalEvent; split made its one command buffer about 850 Metal submissions a frame in its heavy scenes, each ending the open render pass, so the next query's draw reopened the 1080p depth
// target with a full load, store and entry barrier (dm/games/010056B015FE8000/README.md); BioShock Infinite's title screen went from 88 to 189 passes a frame (issue #2112). Waits still
// end a node, so a wait in the same job always finds the producer's node committed before it; a wait on another queue is released when this node is encoded (a WRITE signal) or lands (an
// ADD), not at the signal.
// A node holds at most one signal of each event word: a second signal of a word ends the node before it, as split does (with the same turn for the other queues, the NQ_FENCE node), so the earlier
// value is released when its own node is encoded. Kept in one node, only the word's last value was recorded at encode (nq_event_issued), and a wait on another queue for an earlier one (EQUAL 1
// before a WRITE of 2, or a reset to 0 before a count) was left to the release at publish (nq_event_publish), which only latches a wait already looked at: one looked at after the node landed
// found the last value and parked for good. NieR:Automata signals each word once per command buffer (622 signals on 622 words a frame), so its nodes are not split by this
static int nq_signal_node=-1;   // 1 node, 0 split (a unit test may set it directly)
// DM_NVN_SIGNAL_EVENTS's value: 1 node, 0 split; unset or empty, dflt (the profile's). Any other value is logged and dflt taken: before, any value but split meant node (and before the issue
// #2112 merge, any value but node meant split), so Split, 0 or off silently chose the mode an A/B meant to leave
static int nq_signal_events_mode(const char *e,int dflt) {
    if(!e || !*e) return dflt;
    if(!strcmp(e,"node")) return 1;
    if(!strcmp(e,"split")) return 0;
    LOG("[nvn] DM_NVN_SIGNAL_EVENTS=%s is neither node nor split: the profile's signal_events (%s) is used",e,dflt?"node":"split");
    return dflt;
}
static int nq_signals_in_node(void) {
    if(nq_signal_node<0) { nq_signal_node=nq_signal_events_mode(getenv("DM_NVN_SIGNAL_EVENTS"),DM_GAME_SIGNAL_EVENTS_NODE);
        LOG("[nvn] GPU event signals %s (profile key signal_events; DM_NVN_SIGNAL_EVENTS=node / split)",nq_signal_node?"publish when their command node completes: a signal does not end the node":"end their command node"); }
    return nq_signal_node;
}
// Whether a node already holds a signal of a word. A node of up to NQ_SIGNAL_SCAN signals is scanned; past that its words are marked in nq_signal_words (word -> the node's mark, signal_set),
// under g_sub_mu as nq_flatten is: a scan for every signal was n squared, 0.05 ms a frame on an M4 Max for 622 signals in one node and 0.5 ms for 2,000 (0.006 and 0.02 ms now). A mark is a number never given
// to another node, so the map is not cleared between nodes; it is emptied when it passes NQ_SIGNAL_WORDS words, and the current node's words are marked again. DM_NVN_EVENT_MAP=0 scans every node
enum { NQ_SIGNAL_SCAN=16, NQ_SIGNAL_WORDS=16384 };
static nvn_hmap nq_signal_words; static uint64_t nq_signal_mark;
static void nq_signal_mark_word(nq_node *n,volatile uint32_t *word) {
    if(!nq_signal_words.klen) nvn_hm_init(&nq_signal_words,8);
    nvn_hm_put(&nq_signal_words,&word,(void *)(uintptr_t)n->signal_set);
}
static int nq_signal_on(const nq_node *n,const uint8_t *a) {
    volatile uint32_t *word; memcpy(&word,a,8);
    if(n->signal_set) return (uintptr_t)nvn_hm_get(&nq_signal_words,&word)==n->signal_set;
    for(unsigned i=0;i<n->nsignals;i++) if(n->signals[i].word==word) return 1;
    return 0;
}
static void nq_signal_add(nq_node *n,const uint8_t *a) {
    if(!n->signals_cap && nq_pooled()) { n->signals=&n->signal0; n->signals_cap=1; }
    if(n->nsignals==n->signals_cap) {
        unsigned cap=n->signals_cap>1?n->signals_cap*2:4; struct nq_signal *grown=n->signals==&n->signal0?malloc(cap*sizeof *grown):realloc(n->signals,cap*sizeof *grown);   // NOLINT(bugprone-suspicious-realloc-usage): allocation failure aborts
        if(!grown) die("queue signal allocation failed");
        if(n->signals==&n->signal0) grown[0]=n->signal0;
        n->signals=grown; n->signals_cap=cap;
    }
    struct nq_signal *g=&n->signals[n->nsignals++]; memcpy(&g->word,a,8); memcpy(&g->mode,a+8,4); memcpy(&g->value,a+12,4);
    if(n->signal_set) nq_signal_mark_word(n,g->word);
    else if(n->nsignals>NQ_SIGNAL_SCAN && nq_event_map_on()) {
        if(nq_signal_words.n>NQ_SIGNAL_WORDS) nvn_hm_clear(&nq_signal_words,NULL);
        n->signal_set=++nq_signal_mark;
        for(unsigned i=0;i<n->nsignals;i++) nq_signal_mark_word(n,n->signals[i].word);
    }
}
static void nq_end(nq_job *j) { if(j->last && j->last->kind==NQ_COMMANDS && !j->last->closed) { op_hdr end={OP_END,8}; nq_bytes(j->last,&end,8); j->last->closed=1; } }
// One record of a recording, copied into the job (its object pointers snapshotted); waits and fences cut the job. A signal does not by default (nq_signals_in_node): its value is published
// when the commands it is among complete (mtl_sub_event), and a wait on it is ordered by that value or, while it is in flight, by the fence of those commands (nq_event_write), so the node
// keeps every signal it records. Each node is a Metal command buffer of its own, so a cut ends the open render pass: BioShock Infinite signals an event per occlusion query, and a cut
// at each took its title screen from 88 to 189 passes a frame and from 734 MB to 2.58 GB of attachment loads (issue #2112); NieR:Automata's heavy scenes made about 850 Metal submissions
// a frame. A second signal of a word already in the node still cuts it (nq_signal_on)
static void nq_record_one(nq_job *j,const uint8_t *p,op_hdr h) {
    const uint8_t *a=p+8;
    if(h.op==OP_END || h.op==OP_JUMP || h.op==OP_CALL) die("NVN command list: a %s record inside a recording's piece at %p",h.op==OP_END?"END":h.op==OP_JUMP?"JUMP":"CALL",(const void *)p);
    if(h.op==OP_WAIT_EVENT || h.op==OP_WAIT_SYNC || h.op==OP_FENCE_SYNC) {
        nq_end(j); nq_node *n=nq_append(j,h.op==OP_WAIT_EVENT?NQ_EVENT:h.op==OP_WAIT_SYNC?NQ_SYNC:NQ_FENCE);
        if(h.op==OP_WAIT_EVENT) { memcpy(&n->event,a,8); memcpy(&n->mode,a+8,4); memcpy(&n->value,a+12,4); }
        else { memcpy(&n->sync_source,a,8); if(h.op==OP_FENCE_SYNC) n->receipt=nq_new(); }
    } else {
        nq_node *n=j->last;
        if(h.op==OP_SIGNAL_EVENT && n && n->kind==NQ_COMMANDS && !n->closed && nq_signal_on(n,a)) { nq_end(j); nq_append(j,NQ_FENCE)->receipt=nq_new(); n=j->last; }   // one signal of a word per node (nq_signals_in_node)
        if(!n || n->kind!=NQ_COMMANDS || n->closed) { n=nq_append(j,NQ_COMMANDS); nq_spare_take(n); }
        size_t offset=n->length; nq_bytes(n,p,h.size); if(!n->bytes) die("queue commands: a record of %u bytes",h.size);
        if(!cap_rec_fields(h.op,n->bytes+offset+8,h.size,&nq_snapshot_ops,j)) die("queue snapshot: unknown command %u",h.op);
        if(h.op==OP_SIGNAL_EVENT) { nq_signal_add(n,a); if(!nq_signals_in_node()) { nq_end(j); nq_append(j,NQ_FENCE)->receipt=nq_new(); } }   // see nq_signals_in_node
    }
}
// A compact record (nvn_obj.h OPC_*) goes into the job as the canonical records it stands for
static void nq_record(nq_job *j,const uint8_t *p,op_hdr h) {
    if(!rec_compact(h.op)) { nq_record_one(j,p,h); return; }
    uint8_t x[REC_EXPAND_MAX] __attribute__((aligned(8))); size_t n=rec_expand(p,x);
    for(size_t o=0;o<n;) { op_hdr c; memcpy(&c,x+o,8); nq_record_one(j,x+o,c); o+=c.size; }
}
// A handle is the recording's control list (nvn_obj.h ctl_e): its pieces of records, its links to more control memory. Calls were copied in when they were recorded
static void nq_flatten(nq_job *j,const uint8_t *list) {
    for(const uint8_t *e=list;;e+=8) {
        uint64_t v; memcpy(&v,e,8); unsigned k=ctl_kind(v);
        if(k==CTL_LINK) { e=ctl_addr(v)-8; continue; }
        if(k!=CTL_CHUNK) die("NVN command list %p: corrupt control entry %#llx at %p",(const void *)list,(unsigned long long)v,(const void *)e);
        const uint8_t *p=ctl_addr(v),*pe=p+ctl_chunk_bytes(v);
        while(p<pe) { op_hdr h; memcpy(&h,p,8);
            if(h.size<8 || h.size&7 || h.size>(size_t)(pe-p)) die("NVN command list %p: record {op %u, size %u} at %p, %zu bytes into its piece of %zu at %p",(const void *)list,h.op,h.size,(const void *)p,(size_t)(p-ctl_addr(v)),ctl_chunk_bytes(v),(const void *)ctl_addr(v));
            nq_record(j,p,h); p+=h.size; }
        if(v&CTL_LAST) return;
    }
}
static void nq_enqueue(nq_queue *q,nq_job *j) { if(q->last) q->last->next=j; else q->first=j; q->last=j; nq_put(q->tail); q->tail=j->receipt; q->tail->refs++; pthread_cond_broadcast(&nq_cv); }
void nvn_queue_submit(queue_t *q,int count,const uint64_t *handles) {
    pthread_once(&nq_once,nq_start); nq_job *j=calloc(1,sizeof *j); if(!j) die("queue job allocation failed"); j->receipt=nq_new();
    j->objects.klen=16; j->frame=dm_nvn_frame_count();
    // No scheduler lock while copying descriptors or resolving shader libraries.
    dm_host_mutex_lock(&g_sub_mu); void *pool=objc_autoreleasePoolPush(); dm_host_work++; mtl_prepare(); dm_host_work--; nq_cost cost=nq_cost_begin();
    for(int i=0;i<count;i++) nq_flatten(j,(const uint8_t *)(uintptr_t)handles[i]); nq_end(j);
    nq_cost_end(cost); objc_autoreleasePoolPop(pool); pthread_mutex_unlock(&g_sub_mu);
    int waits=0; for(nq_node *node=j->first;node;node=node->next) waits|=node->kind==NQ_EVENT || node->kind==NQ_SYNC;
    nvn_cap_queue(q->serial,waits);
    pthread_mutex_lock(&nq_mu);
    for(nq_node *node=j->first;node;node=node->next) if(node->sync_source) {
        if(node->kind==NQ_FENCE) nq_set_sync((sync_t *)node->sync_source,node->receipt); else nq_snapshot_sync(node,node->sync_source);
        node->sync_source=NULL;
    }
    nq_enqueue(nq_get(q),j); pthread_mutex_unlock(&nq_mu);
}
// The window retains this logical receipt until it reacquires or finalizes that image.
// Only replay turns it into a physical display ticket; present never waits on the guest thread.
uint64_t nvn_queue_present(queue_t *q,const tex_t *t,double period,const int crop[4]) {
    nvn_cap_queue(q->serial,0);
    pthread_once(&nq_once,nq_start); nq_job *j=calloc(1,sizeof *j); if(!j) die("queue present allocation failed");
    j->receipt=nq_new(); j->frame=dm_nvn_frame_count(); nq_node *n=nq_append(j,NQ_PRESENT);
    n->texture=*t; mtl_tex_pin(t->serial); n->period=period; if(crop) memcpy(n->crop,crop,sizeof n->crop);
    pthread_mutex_lock(&nq_mu); j->receipt->refs++; uint64_t ticket=(uintptr_t)j->receipt;
    nq_enqueue(nq_get(q),j); pthread_mutex_unlock(&nq_mu); return ticket;
}
void nvn_queue_test_hold(int on) { pthread_mutex_lock(&nq_mu); nq_test_held=on; pthread_cond_broadcast(&nq_cv); pthread_mutex_unlock(&nq_mu); }
void nvn_queue_present_release(uint64_t ticket) {
    if(!ticket) return; pthread_mutex_lock(&nq_mu); nq_put((nq_receipt *)(uintptr_t)ticket); pthread_mutex_unlock(&nq_mu);
}
void nvn_queue_present_wait(uint64_t ticket) {
    if(!ticket) return; nq_receipt *r=(nq_receipt *)(uintptr_t)ticket;
    pthread_mutex_lock(&nq_mu); while(!r->published) pthread_cond_wait(&nq_cv,&nq_mu); uint64_t physical=r->present; pthread_mutex_unlock(&nq_mu);
    if(physical) mtl_present_wait(physical);
}
void nvn_queue_fence(queue_t *q,sync_t *s) {
    pthread_mutex_lock(&nq_mu); nq_queue *p=nq_get(q);
    if(p->tail) nq_set_sync(s,p->tail); else { if(s->fenced==3) nq_put((nq_receipt *)(uintptr_t)s->fence); s->fenced=1; s->fence=p->physical; }
    pthread_mutex_unlock(&nq_mu);
}
int nvn_sync_wait(const sync_t *s,uint64_t timeout) {
    uint64_t start=now_ns(),fence=0; pthread_mutex_lock(&nq_mu);
    while(!nq_sync_encoded(s,&fence)) {
        uint64_t elapsed=now_ns()-start; if(timeout!=UINT64_MAX && elapsed>=timeout) { pthread_mutex_unlock(&nq_mu); return 0; }
        if(timeout==UINT64_MAX) pthread_cond_wait(&nq_cv,&nq_mu);
        else { uint64_t left=timeout-elapsed; struct timespec ts={(time_t)(left/1000000000ull),(long)(left%1000000000ull)}; pthread_cond_timedwait_relative_np(&nq_cv,&nq_mu,&ts); }
    }
    pthread_mutex_unlock(&nq_mu); uint64_t elapsed=now_ns()-start;
    return mtl_wait(fence,timeout==UINT64_MAX?timeout:elapsed>=timeout?0:timeout-elapsed);
}
void nvn_queue_wait_sync(queue_t *q,const sync_t *s) {
    nvn_cap_queue(q->serial,1);
    pthread_once(&nq_once,nq_start); nq_job *j=calloc(1,sizeof *j); if(!j) die("queue wait allocation failed"); j->receipt=nq_new();
    pthread_mutex_lock(&nq_mu); nq_snapshot_sync(nq_append(j,NQ_SYNC),s); nq_enqueue(nq_get(q),j); pthread_mutex_unlock(&nq_mu);
}
void nvn_queue_finish(queue_t *q) { sync_t s={0}; nvn_queue_fence(q,&s); nvn_sync_wait(&s,UINT64_MAX); nvn_sync_release(&s);
    pthread_mutex_lock(&nq_mu); uint64_t present=nq_get(q)->present; pthread_mutex_unlock(&nq_mu);
    if(present) mtl_present_wait(present);
}
void nvn_queue_forget(queue_t *q) { nvn_queue_finish(q); pthread_mutex_lock(&nq_mu); nq_queue **p=&nq_queues; while(*p && (*p)->serial!=q->serial) p=&(*p)->next; if(*p) { nq_queue *old=*p; *p=old->next; nq_put(old->tail); free(old); } pthread_mutex_unlock(&nq_mu); }
