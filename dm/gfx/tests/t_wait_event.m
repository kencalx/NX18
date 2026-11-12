// Contract fixture: real public NVN lookup -> recording -> QueueSubmit -> Metal replay.
// An event wait gates GPU work, but never blocks CPU submission or another NVN queue.
// The queue's own costs are counted on the calling thread: allocations (malloc, calloc, realloc) while t_count_allocs is set, and the thread port and thread_info calls the submit-cost probes
// make. The system headers come first, so only the calls in the NVN layer below go through these counters
#include <Foundation/Foundation.h>
#include <Metal/Metal.h>
#include <stdlib.h>
#include <malloc/malloc.h>
#include <mach/mach.h>
static __thread int t_count_allocs; static __thread unsigned t_allocs, t_thread_self, t_thread_info;
static void *t_malloc(size_t n) { t_allocs+=t_count_allocs; return malloc(n); }
static void *t_calloc(size_t c,size_t n) { t_allocs+=t_count_allocs; return calloc(c,n); }
static void *t_realloc(void *p,size_t n) { t_allocs+=t_count_allocs; return realloc(p,n); }
static mach_port_t t_mach_thread_self(void) { t_thread_self++; return mach_thread_self(); }
static kern_return_t t_thread_info_fn(thread_inspect_t t,thread_flavor_t f,thread_info_t i,mach_msg_type_number_t *n) { t_thread_info++; return thread_info(t,f,i,n); }
#define malloc(n) t_malloc(n)
#define calloc(c,n) t_calloc(c,n)
#define realloc(p,n) t_realloc(p,n)
#define mach_thread_self() t_mach_thread_self()
#define thread_info(t,f,i,n) t_thread_info_fn(t,f,i,n)
#define nvn_game_fps nvn_game_fps_mtl_default
#define nvn_event_publish_gpu event_test_publish
#include "../nvn/nvn_mtl.m"
#undef nvn_event_publish_gpu
#undef nvn_game_fps
#define g_ft g_ft_hle
#include "../nvn/hle_nvn.c"
#undef g_ft
#define P(name) ((NVNT_##name)nvn_lookup(#name))
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, fails;
#define CHECK(c,label) do { int ok=!!(c); checks++; fails+=!ok; printf("%s: %s\n",ok?"PASS":"FAIL",label); fflush(stdout); } while(0)
// Observe the exact release boundary, then call the real event publisher. This
// avoids a timing race between a CPU polling thread and a very small store into storage.
static _Atomic uintptr_t event_test_storage;
static _Atomic uint32_t event_test_pixel;
// Every GPU publication in order (signals_in_node): word, mode, value
enum { PUB_MAX=4096 };
static struct { volatile uint32_t *word; unsigned mode; uint32_t value; } pub_log[PUB_MAX]; static _Atomic int pub_n;
void event_test_publish(volatile uint32_t *word,unsigned mode,uint32_t value,uint64_t fence) {
    { int i=atomic_fetch_add(&pub_n,1); if(i<PUB_MAX) { pub_log[i].word=word; pub_log[i].mode=mode; pub_log[i].value=value; } }
    uintptr_t storage=atomic_load(&event_test_storage);
    if(storage && value==11) {
        atomic_store(&event_test_pixel,*(volatile uint32_t *)storage);
    }
    nvn_event_publish_gpu(word,mode,value,fence);
}

typedef struct job { NVNqueue *queue; NVNcommandHandle handle; dispatch_semaphore_t done; struct job *next; } job;
static pthread_mutex_t jobs_mu=PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t jobs_cv=PTHREAD_COND_INITIALIZER;
static job *jobs_first,*jobs_last; static int jobs_stop;
static void *submit_worker(void *unused) { (void)unused; @autoreleasepool {
    for (;;) {
        pthread_mutex_lock(&jobs_mu);
        while (!jobs_first && !jobs_stop) pthread_cond_wait(&jobs_cv,&jobs_mu);
        if (!jobs_first) { pthread_mutex_unlock(&jobs_mu); break; }
        job *j=jobs_first; jobs_first=j->next; if (!jobs_first) jobs_last=NULL;
        pthread_mutex_unlock(&jobs_mu);
        P(nvnQueueSubmitCommands)(j->queue,1,&j->handle);
        dispatch_semaphore_signal(j->done);
    }
} return NULL; }
static void enqueue(job *j,NVNqueue *queue,NVNcommandHandle handle) {
    *j=(job){.queue=queue,.handle=handle,.done=dispatch_semaphore_create(0)};
    pthread_mutex_lock(&jobs_mu); if(jobs_last) jobs_last->next=j; else jobs_first=j;
    jobs_last=j; pthread_cond_signal(&jobs_cv); pthread_mutex_unlock(&jobs_mu);
}
static int returned(job *j,uint64_t ns) { return dispatch_semaphore_wait(j->done,dispatch_time(DISPATCH_TIME_NOW,(int64_t)ns))==0; }
static int landed(NVNsync *s,uint64_t ns) {
    NVNsyncWaitResult r=P(nvnSyncWait)(s,ns);
    return r==NVN_SYNC_WAIT_RESULT_ALREADY_SIGNALED || r==NVN_SYNC_WAIT_RESULT_CONDITION_SATISFIED;
}
static void require_returned(job *j,int seen) {
    if (!seen && !returned(j,5000000000ull)) { fprintf(stderr,"submission did not return after rescue release\n"); _Exit(2); }
}
static NVNdevice device; static NVNqueue queues[2]; static NVNmemoryPool pool;
static NVNevent event, event2; static uint8_t *memory; static volatile uint32_t *source,*result;
static NVNbufferAddress source_addr,result_addr; static NVNcommandBuffer commands[2];
static NVNcommandHandle begin_cmd(int k) {
    P(nvnCommandBufferInitialize)(&commands[k],&device);
    P(nvnCommandBufferAddCommandMemory)(&commands[k],&pool,k*32768,32768);
    P(nvnCommandBufferBeginRecording)(&commands[k]); return 0;
}
static NVNcommandHandle consumer(int mode,uint32_t target,NVNsync *fence,int wait) {
    begin_cmd(0);
    if(wait) P(nvnCommandBufferWaitEvent)(&commands[0],&event,(NVNeventWaitMode)mode,target);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[0],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[0],fence,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    return P(nvnCommandBufferEndRecording)(&commands[0]);
}
static const uint32_t sentinel=0x13579bdf, before=0x01020304, after=0xa1b2c3d4;
static void case_wait(const char *label,int mode,uint32_t initial,uint32_t target,int ready) {
    printf("CASE %s mode=%d initial=%#x target=%#x ready=%d\n",label,mode,initial,target,ready);
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,initial);
    NVNsync fence; P(nvnSyncInitialize)(&fence,&device); job j;
    enqueue(&j,&queues[0],consumer(mode,target,&fence,1));
    int cpu_returned=returned(&j,250000000ull);
    CHECK(cpu_returned,"QueueSubmitCommands returns while the event is unresolved");
    int completed=landed(&fence,ready?1000000000ull:100000000ull);
    CHECK(completed==ready,"GPU completion follows the event predicate before CPU release");
    CHECK(*result==(ready?before:sentinel),"GPU output before CPU release");
    // Release on every path, including failed assertions and a CPU-blocking implementation.
    if(!ready) *source=after;
    P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,target);
    require_returned(&j,cpu_returned);
    int finished=landed(&fence,5000000000ull); CHECK(finished,"GPU work finishes after CPU rescue/release");
    if(!finished) { fprintf(stderr,"GPU did not finish after unconditional event release\n"); _Exit(2); }
    CHECK(*result==(ready?before:after),"GPU reads payload from the correct side of the event release");
    P(nvnSyncFinalize)(&fence);
}
static void case_cross_queue(void) {
    printf("CASE forward cross-queue producer\n");
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNsync consumed,produced; P(nvnSyncInitialize)(&consumed,&device); P(nvnSyncInitialize)(&produced,&device);
    NVNcommandHandle ch=consumer(0,1,&consumed,1);
    begin_cmd(1);
    uint32_t payload=after;
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[1],source_addr,4,0,4,&payload);
    P(nvnCommandBufferSignalEvent)(&commands[1],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,1);
    P(nvnCommandBufferFenceSync)(&commands[1],&produced,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    NVNcommandHandle ph=P(nvnCommandBufferEndRecording)(&commands[1]);
    job cj,pj; enqueue(&cj,&queues[0],ch); int cr=returned(&cj,250000000ull);
    CHECK(cr,"consumer submit returns before a later producer is submitted");
    CHECK(!landed(&consumed,100000000ull) && *result==sentinel,"consumer is gated before producer submission");
    enqueue(&pj,&queues[1],ph); int pr=returned(&pj,250000000ull);
    CHECK(pr,"producer on a different NVN queue can be submitted");
    int done=landed(&consumed,1000000000ull);
    CHECK(done,"later producer releases the consumer without CPU intervention");
    CHECK(done && *result==after,"consumer sees the later producer's GPU payload");
    // Even a single-Metal-queue deadlock is released before joining/draining.
    P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1);
    require_returned(&cj,cr); require_returned(&pj,pr);
    int drained=landed(&consumed,5000000000ull) && landed(&produced,5000000000ull);
    CHECK(drained,"both queues drain after unconditional cleanup release");
    if(!drained) _Exit(2);
    P(nvnSyncFinalize)(&consumed); P(nvnSyncFinalize)(&produced);
}
// Receipt tests observe public sync completion. This helper only waits until the scheduler has encoded the logical fence, so a negative GPU assertion cannot pass merely because its CPU worker has not run yet.
static int receipt_encoded(NVNsync *sync,uint64_t timeout) {
    uint64_t start=now_ns(),fence=0; int ready=0;
    pthread_mutex_lock(&nq_mu);
    while(!(ready=nq_sync_encoded((const sync_t *)sync,&fence))) {
        uint64_t elapsed=now_ns()-start; if(elapsed>=timeout) break;
        uint64_t left=timeout-elapsed; struct timespec ts={(time_t)(left/1000000000ull),(long)(left%1000000000ull)};
        pthread_cond_timedwait_relative_np(&nq_cv,&nq_mu,&ts);
    }
    pthread_mutex_unlock(&nq_mu); return ready;
}
static void receipt_unrelated_completion(void) {
    printf("CASE unrelated physical completion cannot release a parked logical fence\n");
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNsync command_fence,logical,unrelated; P(nvnSyncInitialize)(&command_fence,&device); P(nvnSyncInitialize)(&logical,&device); P(nvnSyncInitialize)(&unrelated,&device);
    job blocked,other; enqueue(&blocked,&queues[0],consumer(0,1,&command_fence,1)); int br=returned(&blocked,250000000ull);
    CHECK(br,"parked consumer submission returns before unrelated work");
    P(nvnQueueFenceSync)(&queues[0],&logical,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    begin_cmd(1); uint32_t payload=after; P(nvnCommandBufferUpdateUniformBuffer)(&commands[1],source_addr,4,0,4,&payload);
    P(nvnCommandBufferFenceSync)(&commands[1],&unrelated,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    enqueue(&other,&queues[1],P(nvnCommandBufferEndRecording)(&commands[1])); int or_=returned(&other,250000000ull);
    CHECK(or_,"unrelated queue submission returns"); int progressed=landed(&unrelated,1000000000ull);
    CHECK(progressed,"unrelated queue physically completes while consumer is parked");
    CHECK(!landed(&logical,0) && !landed(&command_fence,0),"neither consumer fence inherits an unrelated physical completion");
    CHECK(*result==sentinel,"parked consumer has not copied its payload");
    P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1);   // unconditional rescue before joining or reporting a fatal fixture failure
    require_returned(&blocked,br); require_returned(&other,or_);
    int drained=landed(&logical,5000000000ull) && landed(&command_fence,5000000000ull) && landed(&unrelated,5000000000ull);
    CHECK(drained && *result==after,"logical and physical work drain after the actual dependency is released"); if(!drained) _Exit(2);
    P(nvnSyncFinalize)(&command_fence); P(nvnSyncFinalize)(&logical); P(nvnSyncFinalize)(&unrelated);
}
static void receipt_snapshot(int command_wait) {
    printf("CASE %s wait retains its original receipt through retarget and finalize\n",command_wait?"command-buffer":"queue");
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNqueue completed_queue; NVNqueueBuilder qb={0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb,&device);
    CHECK(P(nvnQueueInitialize)(&completed_queue,&qb),"completed retarget queue initializes");
    NVNsync target_sync,consumed,producer_tail; P(nvnSyncInitialize)(&target_sync,&device); P(nvnSyncInitialize)(&consumed,&device); P(nvnSyncInitialize)(&producer_tail,&device);
    begin_cmd(0); P(nvnCommandBufferWaitEvent)(&commands[0],&event,NVN_EVENT_WAIT_MODE_EQUAL,1); uint32_t payload=after;
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[0],source_addr,4,0,4,&payload);
    job producer,consumer_job,tail_job; enqueue(&producer,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); int pr=returned(&producer,250000000ull);
    CHECK(pr,"original producer is enqueued before its receipt is captured");
    P(nvnQueueFenceSync)(&queues[0],&target_sync,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    if(!command_wait) CHECK(P(nvnQueueWaitSync)(&queues[1],&target_sync),"queue wait captures the original producer receipt");
    begin_cmd(1); if(command_wait) P(nvnCommandBufferWaitSync)(&commands[1],&target_sync);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[1],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[1],&consumed,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    enqueue(&consumer_job,&queues[1],P(nvnCommandBufferEndRecording)(&commands[1])); int cr=returned(&consumer_job,250000000ull);
    CHECK(cr,"consumer recording has captured its sync dependency");
    // Replace the producer queue's tail too: after the original job retires, the queued wait must own the old receipt itself.
    begin_cmd(0); enqueue(&tail_job,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); int tr=returned(&tail_job,250000000ull);
    P(nvnQueueFenceSync)(&queues[0],&producer_tail,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    P(nvnQueueFenceSync)(&completed_queue,&target_sync,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    CHECK(!landed(&consumed,100000000ull) && *result==sentinel,"retargeting the source sync to a completed queue does not release the queued wait");
    P(nvnSyncFinalize)(&target_sync);
    P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1);   // release even if a stale raw pointer has already let the consumer run
    require_returned(&producer,pr); require_returned(&consumer_job,cr); require_returned(&tail_job,tr);
    int drained=landed(&consumed,5000000000ull) && landed(&producer_tail,5000000000ull);
    CHECK(drained && *result==after,"queued wait survives sync finalization and observes the original producer payload"); if(!drained) _Exit(2);
    P(nvnSyncFinalize)(&consumed); P(nvnSyncFinalize)(&producer_tail); P(nvnQueueFinalize)(&completed_queue);
}
static void receipt_wait_only(int command_wait) {
    printf("CASE %s wait-only queue inherits the producer GPU fence\n",command_wait?"command-buffer":"queue");
    *source=before;
    NVNsync produced,consumed; P(nvnSyncInitialize)(&produced,&device); P(nvnSyncInitialize)(&consumed,&device);
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); rec_drain(); [g_q4 waitForEvent:gate value:1]; pthread_mutex_unlock(&g_sub_mu);
    begin_cmd(1); uint32_t payload=after; P(nvnCommandBufferUpdateUniformBuffer)(&commands[1],source_addr,4,0,4,&payload);
    job producer,waiter; enqueue(&producer,&queues[1],P(nvnCommandBufferEndRecording)(&commands[1])); int pr=returned(&producer,250000000ull);
    P(nvnQueueFenceSync)(&queues[1],&produced,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    int encoded=receipt_encoded(&produced,1000000000ull); CHECK(pr && encoded,"producer receipt publishes while its GPU work is held by a shared-event gate");
    int wr=1;
    if(command_wait) {
        begin_cmd(0); P(nvnCommandBufferWaitSync)(&commands[0],&produced);
        P(nvnCommandBufferFenceSync)(&commands[0],&consumed,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
        enqueue(&waiter,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); wr=returned(&waiter,250000000ull);
    } else {
        CHECK(P(nvnQueueWaitSync)(&queues[0],&produced),"wait-only queue accepts the producer dependency");
        P(nvnQueueFenceSync)(&queues[0],&consumed,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    }
    int wait_encoded=receipt_encoded(&consumed,1000000000ull); CHECK(wr && wait_encoded,"wait-only logical receipt publishes without adding GPU commands");
    CHECK(!landed(&produced,0) && !landed(&consumed,0),"published wait-only receipt remains pending until the producer GPU fence completes");
    gate.signaledValue=1;   // always release the GPU before cleanup, including assertion failures
    require_returned(&producer,pr); if(command_wait) require_returned(&waiter,wr);
    int drained=landed(&produced,5000000000ull) && landed(&consumed,5000000000ull);
    CHECK(drained && *source==after,"wait-only fence completes after the actual producer GPU work"); if(!drained) _Exit(2);
    P(nvnSyncFinalize)(&produced); P(nvnSyncFinalize)(&consumed);
}
// The stale initial value must not satisfy a wait behind an earlier GPU reset.
static void event_stale_gpu_reset(void) {
    printf("CASE queued GPU reset precedes equality evaluation\n");
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1);
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1]; pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    NVNsync reset,consumed; P(nvnSyncInitialize)(&reset,&device); P(nvnSyncInitialize)(&consumed,&device);
    begin_cmd(0);
    P(nvnCommandBufferSignalEvent)(&commands[0],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,0);
    P(nvnCommandBufferFenceSync)(&commands[0],&reset,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    P(nvnCommandBufferWaitEvent)(&commands[0],&event,NVN_EVENT_WAIT_MODE_EQUAL,1);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[0],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[0],&consumed,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    job j; enqueue(&j,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); int returned_=returned(&j,250000000ull);
    CHECK(returned_ && receipt_encoded(&reset,1000000000ull),"GPU reset prefix encodes without blocking submit");
    CHECK(!receipt_encoded(&consumed,100000000ull),"stale initial event value cannot release a wait behind an in-flight reset");
    gate.signaledValue=1;
    int reset_done=landed(&reset,5000000000ull);
    CHECK(reset_done && P(nvnEventGetValue)(&event)==0,"GPU reset reaches storage before the later CPU release");
    CHECK(!landed(&consumed,0) && *result==sentinel,"consumer remains parked after the reset");
    *source=after; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1);
    require_returned(&j,returned_); int done=landed(&consumed,5000000000ull);
    CHECK(done && *result==after,"later CPU release resumes the consumer with its new payload");
    if(!done) _Exit(2);
    P(nvnSyncFinalize)(&reset); P(nvnSyncFinalize)(&consumed);
}
// A wait whose event a still-running WRITE signal satisfies is encoded without that writer's completion (the one Metal queue runs it after the writer, nq_event_write), and its GPU work
// still sees the writer's payload; an ADD signal's result is not known before it lands, so a wait on it parks until then
static void event_queued_write(int mode) {
    printf("CASE wait on an in-flight %s signal\n",mode==NVN_EVENT_SIGNAL_MODE_WRITE?"WRITE":"ADD");
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1]; pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    NVNsync produced,consumed; P(nvnSyncInitialize)(&produced,&device); P(nvnSyncInitialize)(&consumed,&device);
    begin_cmd(1); uint32_t payload=after;
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[1],source_addr,4,0,4,&payload);
    P(nvnCommandBufferSignalEvent)(&commands[1],&event,(NVNeventSignalMode)mode,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,1);
    P(nvnCommandBufferFenceSync)(&commands[1],&produced,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    job pj,cj; enqueue(&pj,&queues[1],P(nvnCommandBufferEndRecording)(&commands[1])); int pr=returned(&pj,250000000ull);
    CHECK(pr && receipt_encoded(&produced,1000000000ull),"producer encodes while its GPU work is held by a shared-event gate");
    enqueue(&cj,&queues[0],consumer(NVN_EVENT_WAIT_MODE_EQUAL,1,&consumed,1)); int cr=returned(&cj,250000000ull);
    int early=receipt_encoded(&consumed,mode==NVN_EVENT_SIGNAL_MODE_WRITE?1000000000ull:100000000ull);
    CHECK(early==(mode==NVN_EVENT_SIGNAL_MODE_WRITE),mode==NVN_EVENT_SIGNAL_MODE_WRITE?"the consumer is encoded behind the in-flight WRITE before it completes"
                                                                                 :"the consumer waits for an in-flight ADD to land");
    CHECK(!landed(&produced,0) && !landed(&consumed,0) && *result==sentinel,"nothing has run while the gate holds the GPU");
    gate.signaledValue=1;   // always release the GPU before cleanup, including assertion failures
    require_returned(&pj,pr); require_returned(&cj,cr);
    int done=landed(&produced,5000000000ull) && landed(&consumed,5000000000ull);
    CHECK(done && *result==after,"the consumer's copy reads the producer's payload"); if(!done) { P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1); _Exit(2); }
    P(nvnSyncFinalize)(&produced); P(nvnSyncFinalize)(&consumed);
}
// A signal does not cut its recording (issue #2112): two signals with commands between them are one Metal submission, and a wait on the first of them, which is not the
// recording's last, is still encoded behind the in-flight write. This is signal_events node, the default; split (signals_in_node(0)) cuts at each signal
static void event_signal_no_cut(void) {
    printf("CASE signals stay in their recording's submission\n");
    int saved=nq_signals_in_node(); nq_signal_node=1;
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNevent second; NVNeventBuilder eb={0}; P(nvnEventBuilderSetDefaults)(&eb); P(nvnEventBuilderSetStorage)(&eb,&pool,65548); CHECK(P(nvnEventInitialize)(&second,&eb),"second event initialized");
    P(nvnEventSignal)(&second,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1]; uint64_t first_fence=mtl_last_fence(); pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    NVNsync produced,consumed; P(nvnSyncInitialize)(&produced,&device); P(nvnSyncInitialize)(&consumed,&device);
    begin_cmd(1); uint32_t payload=after, other=before;
    P(nvnCommandBufferSignalEvent)(&commands[1],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,1);
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[1],source_addr,4,0,4,&other);
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[1],source_addr,4,0,4,&payload);
    P(nvnCommandBufferSignalEvent)(&commands[1],&second,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,7);
    P(nvnCommandBufferFenceSync)(&commands[1],&produced,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    job pj,cj; enqueue(&pj,&queues[1],P(nvnCommandBufferEndRecording)(&commands[1])); int pr=returned(&pj,250000000ull);
    CHECK(pr && receipt_encoded(&produced,1000000000ull),"producer encodes while its GPU work is held by a shared-event gate");
    pthread_mutex_lock(&g_sub_mu); uint64_t submissions=mtl_last_fence()-first_fence; pthread_mutex_unlock(&g_sub_mu);
    CHECK(submissions==1,"both signals and the commands between them are one Metal submission");
    enqueue(&cj,&queues[0],consumer(NVN_EVENT_WAIT_MODE_EQUAL,1,&consumed,1)); int cr=returned(&cj,250000000ull);
    CHECK(receipt_encoded(&consumed,1000000000ull),"a wait on the first signal is encoded behind the in-flight submission");
    CHECK(!landed(&produced,0) && !landed(&consumed,0) && *result==sentinel && P(nvnEventGetValue)(&event)==0,"nothing has run while the gate holds the GPU");
    gate.signaledValue=1;   // always release the GPU before cleanup, including assertion failures
    require_returned(&pj,pr); require_returned(&cj,cr);
    int done=landed(&produced,5000000000ull) && landed(&consumed,5000000000ull);
    CHECK(done && *result==after,"the consumer's copy reads what the producer wrote after the first signal"); if(!done) { P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1); _Exit(2); }
    CHECK(P(nvnEventGetValue)(&event)==1 && P(nvnEventGetValue)(&second)==7,"both events hold their signalled values");
    P(nvnSyncFinalize)(&produced); P(nvnSyncFinalize)(&consumed); P(nvnEventFinalize)(&second);
    nq_signal_node=saved;
}
// The submissions of one frame share a command allocator, and one that counts no samples takes no visibility buffer (PR #2090): 24 of them with the GPU held, three times
// the pool, all encode without a wait for the GPU, which would never return here
static void frame_shares_allocator(void) {
    enum { N=24 };
    printf("CASE a frame's submissions share a command allocator\n");
    *source=before; *result=sentinel;
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1];
    uint64_t waits=g_alloc_waits, shares=g_alloc_shares; int pool=g_alloc_n, ring=g_vis_ring_n; pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    static NVNsync fences[N]; static job jobs[N]; int submitted=0, encoded=0;
    for(int i=0;i<N;i++) {
        P(nvnSyncInitialize)(&fences[i],&device); enqueue(&jobs[i],&queues[0],consumer(0,0,&fences[i],0));
        if(!returned(&jobs[i],2000000000ull) || !receipt_encoded(&fences[i],2000000000ull)) break;
        submitted++; encoded++;
    }
    CHECK(submitted==N && encoded==N,"24 submissions encode while the GPU is held");
    pthread_mutex_lock(&g_sub_mu);
    CHECK(g_alloc_waits==waits,"none waited for the GPU to free an allocator");
    CHECK(g_alloc_n<=pool+1 && g_alloc_shares-shares>=N-2,"they share the frame's allocator");
    CHECK(g_vis_ring_n==ring,"none took a visibility buffer");
    pthread_mutex_unlock(&g_sub_mu);
    CHECK(*result==sentinel,"nothing has run while the gate holds the GPU");
    gate.signaledValue=1;   // always release the GPU before cleanup, including assertion failures
    if(submitted<N) { fprintf(stderr,"a submission waited for the held GPU\n"); _Exit(2); }
    int done=1; for(int i=0;i<N;i++) done&=landed(&fences[i],5000000000ull);
    CHECK(done && *result==before,"all of them complete once the GPU runs"); if(!done) _Exit(2);
    for(int i=0;i<N;i++) P(nvnSyncFinalize)(&fences[i]);
}
// More than POST_RING submissions in flight (the GPU held; the frame's submissions share one allocator and take no visibility buffer, so nothing else holds them back): the one whose post-ring
// slot still holds a fence the GPU has not completed waits for it in mtl_sub_commit. The wait ledger (DM_NVN_WAITS=1) counts that wait as the post ring's: counted as the allocator's, it disagreed
// with g_alloc_waits (the allocator pool's own figure, which it does not touch) and pointed at ALLOC_MAX / ALLOC_SHARE instead of POST_RING
static void post_ring_wait(void) {
    enum { N=POST_RING+16 };
    printf("CASE more than POST_RING submissions in flight\n");
    if(!ws_on()) { printf("SKIP: the wait ledger is off (run with DM_NVN_WAITS=1)\n"); return; }
    int post=-1; for(int i=0;i<WS_N;i++) if(!strcmp(ws_name[i],"post ring")) post=i;
    *source=before; *result=sentinel;
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1];
    uint64_t waits=g_alloc_waits; pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    uint64_t blk0[WS_N]; for(int i=0;i<WS_N;i++) blk0[i]=atomic_load(&g_ws_blk[i]);
    static NVNsync fences[N]; static job jobs[N]; int n=0, held=-1, held_returned=0;
    while(n<N) {   // up to the post ring each one encodes at once; past it, the one that does not within 300 ms is the one waiting for the held GPU
        uint64_t wait=n<POST_RING-4?2000000000ull:300000000ull;
        P(nvnSyncInitialize)(&fences[n],&device); enqueue(&jobs[n],&queues[0],consumer(0,0,&fences[n],0));
        int back=returned(&jobs[n],wait), ok=back && receipt_encoded(&fences[n],wait); n++;
        if(!ok) { held=n-1; held_returned=back; break; }
    }
    printf("submission %d of those made with the GPU held waits (POST_RING %d)\n",held,(int)POST_RING);
    CHECK(held>=POST_RING/2,"a submission past the post ring waits for the held GPU");
    CHECK(*result==sentinel,"nothing has run while the gate holds the GPU");
    gate.signaledValue=1;   // always release the GPU before cleanup, including assertion failures
    if(held>=0 && !held_returned && !returned(&jobs[held],5000000000ull)) { fprintf(stderr,"the waiting submission did not return once the GPU ran\n"); _Exit(2); }
    int done=1; for(int i=0;i<n;i++) done&=landed(&fences[i],5000000000ull);
    CHECK(done && *result==before,"all of them complete once the GPU runs"); if(!done) _Exit(2);
    pthread_mutex_lock(&g_sub_mu); uint64_t alloc_waits=g_alloc_waits-waits; pthread_mutex_unlock(&g_sub_mu);
    uint64_t alloc_blk=atomic_load(&g_ws_blk[WS_ALLOC])-blk0[WS_ALLOC], post_blk=post>=0?atomic_load(&g_ws_blk[post])-blk0[post]:0;
    printf("blocked waits: allocator row %llu, allocator pool %llu, post-ring row %llu\n",(unsigned long long)alloc_blk,(unsigned long long)alloc_waits,(unsigned long long)post_blk);
    CHECK(alloc_blk==alloc_waits,"the ledger's allocator row counts only the allocator pool's waits (g_alloc_waits)");
    CHECK(post>=0 && post_blk>=1,"the post-ring wait is on the ledger as the post ring");
    for(int i=0;i<n;i++) P(nvnSyncFinalize)(&fences[i]);
}
// A wait on a sync no fence has reached when it is submitted is already satisfied: the queue's own later work, its fence included, runs (issue #1808)
static void receipt_unfenced(int command_wait) {
    printf("CASE %s wait on a never-fenced sync does not park its queue\n",command_wait?"command-buffer":"queue");
    *source=before; *result=sentinel;
    NVNsync never,consumed; P(nvnSyncInitialize)(&never,&device); P(nvnSyncInitialize)(&consumed,&device);
    if(!command_wait) CHECK(P(nvnQueueWaitSync)(&queues[0],&never),"queue accepts a wait on a never-fenced sync");
    begin_cmd(0); if(command_wait) P(nvnCommandBufferWaitSync)(&commands[0],&never);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[0],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[0],&consumed,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    job j; enqueue(&j,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); int r=returned(&j,250000000ull);
    int done=landed(&consumed,5000000000ull);
    CHECK(r && done && *result==before,"the work after the wait runs and its fence lands"); if(!done) _Exit(2);
    P(nvnSyncFinalize)(&never); P(nvnSyncFinalize)(&consumed);
}
static void receipt_tests(void) {
    receipt_unrelated_completion(); receipt_snapshot(0); receipt_snapshot(1); receipt_wait_only(0); receipt_wait_only(1); receipt_unfenced(0); receipt_unfenced(1);
}
static void event_mirror_publication(void) {
    printf("CASE terminal event publishes after the render pass's store into storage\n");
    NVNtextureBuilder tb; NVNtexture texture; P(nvnTextureBuilderSetDefaults)(&tb);
    P(nvnTextureBuilderSetDevice)(&tb,&device); P(nvnTextureBuilderSetWidth)(&tb,8); P(nvnTextureBuilderSetHeight)(&tb,4);
    P(nvnTextureBuilderSetFormat)(&tb,NVN_FORMAT_RGBA8); P(nvnTextureBuilderSetStorage)(&tb,&pool,98304);
    NVNpackagedTextureLayout layout={{1,0,0,0,7,0,1,0}}; P(nvnTextureBuilderSetPackagedTextureLayout)(&tb,&layout);
    CHECK(P(nvnTextureInitialize)(&texture,&tb),"storage-backed render target initializes");
    memset(memory+98304,0xee,(size_t)P(nvnTextureGetStorageSize)(&texture));
    atomic_store(&event_test_pixel,0); atomic_store(&event_test_storage,(uintptr_t)(memory+98304));
    P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNsync fence; P(nvnSyncInitialize)(&fence,&device);
    begin_cmd(0); const NVNtexture *colors[]={&texture}; float rgba[]={0.2f,0.4f,0.6f,1.f};
    P(nvnCommandBufferSetRenderTargets)(&commands[0],1,colors,NULL,NULL,NULL);
    P(nvnCommandBufferClearColor)(&commands[0],0,rgba,15);
    P(nvnCommandBufferSignalEvent)(&commands[0],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,11);
    P(nvnCommandBufferFenceSync)(&commands[0],&fence,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    job submitted; enqueue(&submitted,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); int sr=returned(&submitted,250000000ull);
    require_returned(&submitted,sr); int done=landed(&fence,5000000000ull);
    CHECK(done,"render clear and terminal signal complete"); if(!done) _Exit(2);
    CHECK(atomic_load(&event_test_pixel)==0xff996633u,"rendered bytes are already in guest storage when the event is published");
    CHECK(P(nvnEventGetValue)(&event)==11,"the terminal event publishes once the storage is visible");
    atomic_store(&event_test_storage,0); P(nvnSyncFinalize)(&fence); P(nvnTextureFinalize)(&texture);
}
// Profile key signal_events (nvn_queue.inc nq_signals_in_node). node: the signals of a command node stay in it, the node is one Metal submission, and they publish in recorded
// order once it completes, ADD signals adding up in that order (the default); split: each signal ends its node, one submission each. Either way nothing publishes before the GPU has
// run the work, and a wait still ends its node, so a wait on a signal of the same command buffer is released
static volatile uint32_t *event_storage(NVNevent *e) { return ((ev_t *)e)->val; }
static void signals_in_node(int node) {
    printf("CASE signal_events %s: four signals in one command buffer\n",node?"node":"split");
    int saved=nq_signals_in_node(); nq_signal_node=node;
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0); P(nvnEventSignal)(&event2,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1]; pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    NVNsync fence; P(nvnSyncInitialize)(&fence,&device);
    begin_cmd(0); uint32_t payload=after;
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[0],source_addr,4,0,4,&payload);
    P(nvnCommandBufferSignalEvent)(&commands[0],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,1);
    P(nvnCommandBufferSignalEvent)(&commands[0],&event2,NVN_EVENT_SIGNAL_MODE_ADD,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,2);
    P(nvnCommandBufferSignalEvent)(&commands[0],&event,NVN_EVENT_SIGNAL_MODE_ADD,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,3);
    P(nvnCommandBufferSignalEvent)(&commands[0],&event2,NVN_EVENT_SIGNAL_MODE_ADD,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,5);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[0],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[0],&fence,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    atomic_store(&pub_n,0); uint64_t f0=mtl_last_fence();
    job j; enqueue(&j,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); int r=returned(&j,250000000ull);
    int encoded=receipt_encoded(&fence,1000000000ull); uint64_t f1=mtl_last_fence();
    CHECK(r && encoded,"the command buffer encodes while the gate holds the GPU");
    CHECK(f1-f0==(node?2u:5u),node?"node: four signals on two events leave the command buffer two Metal submissions (the first event's second signal starts a node)":"split: each signal ends a submission (four, then the copy)");
    CHECK(!atomic_load(&pub_n) && P(nvnEventGetValue)(&event)==0 && P(nvnEventGetValue)(&event2)==0,"no signal publishes before the GPU has run its work");
    gate.signaledValue=1;
    require_returned(&j,r); int done=landed(&fence,5000000000ull);
    if(!done) { fprintf(stderr,"signal fixture did not complete\n"); _Exit(2); }
    for(int k=0;k<200 && atomic_load(&pub_n)<4;k++) usleep(1000);   // the last submission's events publish in its completion, which the fence's waiter may have run (post_early)
    int n=atomic_load(&pub_n);
    CHECK(n==4,"four publications");
    int order=n==4 && pub_log[0].word==event_storage(&event) && pub_log[0].mode==0 && pub_log[0].value==1 && pub_log[1].word==event_storage(&event2) && pub_log[1].mode==1 && pub_log[1].value==2
              && pub_log[2].word==event_storage(&event) && pub_log[2].mode==1 && pub_log[2].value==3 && pub_log[3].word==event_storage(&event2) && pub_log[3].mode==1 && pub_log[3].value==5;
    CHECK(order,"the signals publish in recorded order with their modes");
    CHECK(P(nvnEventGetValue)(&event)==4 && P(nvnEventGetValue)(&event2)==7,"WRITE then ADD, and two ADDs, leave the values the order gives (4 and 7)");
    CHECK(*result==after,"the work after the signals ran with the payload before them");
    P(nvnSyncFinalize)(&fence);
    // A wait on a signal of the same command buffer still ends the node: the producer's submission is committed before the wait, and the work after it runs
    printf("CASE signal_events %s: a wait on the same command buffer's signal\n",node?"node":"split");
    *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNsync waited; P(nvnSyncInitialize)(&waited,&device);
    begin_cmd(0);
    P(nvnCommandBufferSignalEvent)(&commands[0],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,9);
    P(nvnCommandBufferWaitEvent)(&commands[0],&event,NVN_EVENT_WAIT_MODE_EQUAL,9);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[0],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[0],&waited,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    f0=mtl_last_fence(); job w; enqueue(&w,&queues[0],P(nvnCommandBufferEndRecording)(&commands[0])); int wr=returned(&w,250000000ull);
    int wdone=landed(&waited,5000000000ull);
    if(!wdone) P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,9);   // rescue before failing
    require_returned(&w,wr);
    CHECK(wr && wdone && *result==after,"the wait on its own command buffer's signal is released and the copy after it runs");
    CHECK(mtl_last_fence()-f0==2,"the wait ends the node: two submissions");
    if(!wdone) { landed(&waited,5000000000ull); }
    P(nvnSyncFinalize)(&waited);
    nq_signal_node=saved;
}
// A node keeps one signal of each event word (nq_flatten): a command buffer on one queue writes 1 and then 2 to an event, and another queue waits EQUAL 1 behind work of its own. The wait is
// released when the producer's WRITE 1 is encoded, while a shared-event gate still holds the GPU, as split always did. With both WRITEs in one node only 2 was recorded at encode, and the wait was
// left to the release at publish, which a wait the replay first looks at after the producer has landed never gets (it then parks for good)
static void signal_overwritten(int node) {
    printf("CASE signal_events %s: a wait on another queue for a value the same command buffer overwrites\n",node?"node":"split");
    int saved=nq_signals_in_node(); nq_signal_node=node;
    *source=before; *result=sentinel; P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,0);
    id<MTLSharedEvent> gate=[g_dev newSharedEvent];
    if (!gate) abort();
    pthread_mutex_lock(&g_sub_mu); pthread_mutex_lock(&g_res_mu); [g_q4 waitForEvent:gate value:1]; pthread_mutex_unlock(&g_res_mu); pthread_mutex_unlock(&g_sub_mu);
    NVNsync consumed,produced; P(nvnSyncInitialize)(&consumed,&device); P(nvnSyncInitialize)(&produced,&device);
    begin_cmd(0); uint32_t own=sentinel;
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[0],result_addr,4,0,4,&own);   // work of its own before the wait: the wait is not the queue's head when the replay starts
    P(nvnCommandBufferWaitEvent)(&commands[0],&event,NVN_EVENT_WAIT_MODE_EQUAL,1);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[0],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[0],&consumed,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    NVNcommandHandle ch=P(nvnCommandBufferEndRecording)(&commands[0]);
    begin_cmd(1); uint32_t payload=after;
    P(nvnCommandBufferUpdateUniformBuffer)(&commands[1],source_addr,4,0,4,&payload);
    P(nvnCommandBufferSignalEvent)(&commands[1],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,1);
    P(nvnCommandBufferSignalEvent)(&commands[1],&event,NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,2);
    P(nvnCommandBufferFenceSync)(&commands[1],&produced,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    NVNcommandHandle ph=P(nvnCommandBufferEndRecording)(&commands[1]);
    nvn_queue_test_hold(1);   // both jobs are queued before the replay takes either
    job cj,pj; enqueue(&cj,&queues[0],ch); int cr=returned(&cj,250000000ull); enqueue(&pj,&queues[1],ph); int pr=returned(&pj,250000000ull);
    uint64_t f0=mtl_last_fence();
    nvn_queue_test_hold(0);
    int released=receipt_encoded(&consumed,1000000000ull) && receipt_encoded(&produced,1000000000ull);
    CHECK(cr && pr && released,"the wait for the overwritten value is released at the producer's encode, while the GPU is held");
    CHECK(mtl_last_fence()-f0==4,"four submissions: the producer's two writes of one event in two, and the consumer's work before and after its wait");
    gate.signaledValue=1;   // always release the GPU before cleanup
    int done=landed(&produced,5000000000ull) && landed(&consumed,2000000000ull);
    if(!done) { P(nvnEventSignal)(&event,NVN_EVENT_SIGNAL_MODE_WRITE,1); done=landed(&consumed,5000000000ull); }   // rescue before failing
    require_returned(&cj,cr); require_returned(&pj,pr);
    CHECK(done && *result==after,"the consumer runs after the producer's payload and WRITE 1");
    CHECK(P(nvnEventGetValue)(&event)==2,"the event ends at the producer's last value");
    if(!done) _Exit(2);
    P(nvnSyncFinalize)(&consumed); P(nvnSyncFinalize)(&produced);
    nq_signal_node=saved;
}
static int env_is(const char *k,const char *v) { const char *e=getenv(k); return e && !strcmp(e,v); }
// Waits until the replay has taken every queued job (each job's nodes are back in the free list or freed when its queue's first job moves on)
static int queue_idle(uint64_t timeout) {
    uint64_t start=now_ns(); int idle=0; pthread_mutex_lock(&nq_mu);
    for(;;) {
        idle=1; for(nq_queue *q=nq_queues;q;q=q->next) if(q->first) idle=0;
        uint64_t elapsed=now_ns()-start; if(idle || elapsed>=timeout) break;
        struct timespec ts={0,1000000}; pthread_cond_timedwait_relative_np(&nq_cv,&nq_mu,&ts);
    }
    pthread_mutex_unlock(&nq_mu); return idle;
}
// The submit-cost probes (nq_cost_begin / nq_cost_end) read the thread's times with one thread_info call each and make no thread port (DM_NVN_SUBMIT_PROBES=full: clock_gettime plus
// mach_thread_self, thread_info and the port's release, as before), and the CPU time they add up matches the thread's own clock
static void probe_cost(void) {
    int full=env_is("DM_NVN_SUBMIT_PROBES","full");
    printf("CASE submit-cost probes (%s)\n",full?"full":"default");
    enum { N=4000 };
    uint64_t c0=atomic_load(&g_cum_sub_cpu_ns), s0=atomic_load(&g_cum_sub_sys_ns), k0=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID);
    unsigned self0=t_thread_self, info0=t_thread_info; volatile double x=1;
    for(int i=0;i<N;i++) { nq_cost c=nq_cost_begin(); for(int k=0;k<3000;k++) x*=1.0000001; nq_cost_end(c); }
    uint64_t k1=clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID), c1=atomic_load(&g_cum_sub_cpu_ns), s1=atomic_load(&g_cum_sub_sys_ns);
    unsigned self=t_thread_self-self0, info=t_thread_info-info0;
    uint64_t t0=now_ns(); for(int i=0;i<N;i++) nq_cost_end(nq_cost_begin()); double per=(double)(now_ns()-t0)/N;
    printf("probes: %u thread port calls and %u thread_info calls for %d scopes; %.0f ns a scope with nothing in it; CPU %.3f ms counted of %.3f ms on the thread's clock, kernel %.3f ms\n",
           self,info,N,per,(c1-c0)/1e6,(k1-k0)/1e6,(s1-s0)/1e6);
    if(full) CHECK(self==2u*N && info==2u*N,"DM_NVN_SUBMIT_PROBES=full: a thread port and a thread_info call per reading, as before");
    else CHECK(self==0 && info==2u*N,"one thread_info call per reading and no thread port made");
    double ratio=k1>k0?(double)(c1-c0)/(double)(k1-k0):0;
    CHECK(ratio>0.85 && ratio<1.02,"the probes' CPU time matches the thread's clock");
    CHECK(s1-s0<=c1-c0,"the kernel time is part of the CPU time");
}
// GPU event bookkeeping (nq_event_issued, nq_event_pending, nvn_queue_gpu_progress): three rounds of 2,000 fresh words and a rewrite of the first round, as three frames of a game's 2,000 signals
// in flight. Each word holds its last write; writes whose fence has completed are forgotten, the others kept. With the hash map this takes well under a millisecond; the list walked every
// word written for each signal (about 30 ms on an M4 Max). DM_NVN_EVENT_MAP=0 keeps the list, and the time is not checked then
static uint32_t ev_words[8000];
static void event_bookkeeping(void) {
    int list=env_is("DM_NVN_EVENT_MAP","0");
    printf("CASE GPU event bookkeeping with 6,000 words in flight (%s)\n",list?"list":"map");
    pthread_mutex_lock(&nq_mu);
    uint64_t done=mtl_completed_fence(), F=mtl_last_fence()+1000000; unsigned base=nq_event_inflight();   // earlier cases' writes not yet dropped
    uint64_t t0=now_ns();
    for(int r=0;r<3;r++) for(int i=0;i<2000;i++) nq_event_issued(&ev_words[r*2000+i],F+r,0,(uint32_t)i);
    for(int i=0;i<2000;i++) nq_event_issued(&ev_words[i],F+3,1,7);
    for(int i=0;i<6000;i++) (void)nq_event_pending(&ev_words[i]);
    uint64_t dt=now_ns()-t0;
    int good=1;
    for(int i=0;i<6000;i++) { nq_event_write *w=nq_event_write_of(&ev_words[i]); int r=i/2000;
        good&=w && w->word==&ev_words[i] && w->fence==(r?F+r:F+3) && w->value==(r?(uint32_t)(i%2000):7u) && w->exact==(r!=0) && nq_event_pending(&ev_words[i])==w->fence; }
    CHECK(good,"each word holds its last write: fence, value and whether it is exact");
    // The queue line's words in flight (nq_event_inflight) count the entries with the list too: with DM_NVN_EVENT_MAP=0 they read 0 now and 0 at most before
    unsigned inflight=nq_event_inflight(), peak=nq_stat_event_peak;
    CHECK(inflight==base+6000 && peak>=inflight,"the queue line counts 6,000 event words in flight and at most at least as many");
    // The first round lands (fence 1); a write with a fence between the oldest and the newest goes to its place
    for(int i=0;i<2000;i++) nq_event_issued(&ev_words[i],1,0,1);
    nq_event_issued(&ev_words[6000],F+1,0,5);
    pthread_mutex_unlock(&nq_mu);
    nvn_queue_gpu_progress();
    pthread_mutex_lock(&nq_mu);
    good=1; for(int i=0;i<2000;i++) good&=!nq_event_pending(&ev_words[i]);
    for(int i=2000;i<6000;i++) good&=nq_event_pending(&ev_words[i])==F+i/2000;
    good&=nq_event_pending(&ev_words[6000])==F+1;
    CHECK(good && done>=1,"the writes whose fence has completed are forgotten, the others kept");
    for(int i=2000;i<=6000;i++) nq_event_issued(&ev_words[i],1,0,1);
    pthread_mutex_unlock(&nq_mu);
    nvn_queue_gpu_progress();
    pthread_mutex_lock(&nq_mu); int empty=!nq_event_writes; good=1; for(int i=0;i<=6000;i++) good&=!nq_event_pending(&ev_words[i]); inflight=nq_event_inflight(); peak=nq_stat_event_peak; pthread_mutex_unlock(&nq_mu);
    CHECK(empty && good,"once every write has landed nothing is kept");
    printf("event words in flight once landed %u, at most %u\n",inflight,peak);
    CHECK(inflight==0 && peak>=6001,"the queue line counts none in flight once they land, and at most the 6,001 words");
    printf("event bookkeeping: %.3f ms for 8,000 writes and 6,000 lookups\n",dt/1e6);
    if(!list) CHECK(dt<4000000,"8,000 writes with 6,000 words in flight take under 4 ms");
}
// When the queue line is due (nq_report_due): once per multiple of 300 frames, never on a frame that went back. The replay's frame goes back when jobs of two queues interleave: a job of frame
// 599 on one queue replayed after the frame-600 job it waits on. Compared by its multiple of 300 alone, frame 599 after 600 wrote a line over 2^64 - 1 frames and moved the baseline back,
// and the next job of frame 600 wrote another over 1 frame
static void report_due(void) {
    printf("CASE the queue line's frames with jobs of two queues interleaved\n");
    static const uint64_t seq[]={UINT64_MAX,5,6,299,300,301,599,600,599,600,598,601,899,900,1200,1199,1500};
    static const uint64_t want[]={0,0,0,0,295,0,0,300,0,0,0,0,0,300,300,0,300};
    uint64_t reported=UINT64_MAX; int good=1;
    for(unsigned i=0;i<sizeof seq/sizeof *seq;i++) { uint64_t f=nq_report_due(seq[i],&reported); if(f!=want[i]) { good=0; printf("frame %llu: line over %llu frames, expected %llu\n",(unsigned long long)seq[i],(unsigned long long)f,(unsigned long long)want[i]); } }
    CHECK(good,"one line per multiple of 300 over the frames since the last, and none for a frame that went back");
}
// A node holds one signal of each word (nq_signal_on): 8,000 signals on 8,000 words in one node, each looked up before it is added. Past 16 signals the node's words are marked in a map
// instead of scanned; the scan was n squared (about 10 ms here). DM_NVN_EVENT_MAP=0 scans, and the time is not checked then
static void signal_set(void) {
    int list=env_is("DM_NVN_EVENT_MAP","0");
    printf("CASE one signal of each word in a node of 8,000 signals (%s)\n",list?"scan":"map");
    nq_node n; memset(&n,0,sizeof n); n.kind=NQ_COMMANDS; uint8_t a[16];
    pthread_mutex_lock(&g_sub_mu);
    uint64_t t0=now_ns(); int found=0;
    for(int i=0;i<8000;i++) { volatile uint32_t *w=&ev_words[i]; uint32_t mode=i%3==0, value=(uint32_t)i; memcpy(a,&w,8); memcpy(a+8,&mode,4); memcpy(a+12,&value,4); found+=nq_signal_on(&n,a); nq_signal_add(&n,a); }
    uint64_t dt=now_ns()-t0;
    int good=!found && n.nsignals==8000;
    for(int i=0;i<8000 && good;i++) { volatile uint32_t *w=&ev_words[i]; memcpy(a,&w,8); good&=nq_signal_on(&n,a) && n.signals[i].word==w && n.signals[i].mode==(unsigned)(i%3==0) && n.signals[i].value==(uint32_t)i; }
    uint32_t other; volatile uint32_t *ow=&other; memcpy(a,&ow,8); good&=!nq_signal_on(&n,a);
    pthread_mutex_unlock(&g_sub_mu);
    CHECK(good,"every word is found once added, in recorded order with its mode and value, and no other");
    printf("signal lookups: %.3f ms for 8,000 signals in one node\n",dt/1e6);
    if(!list) CHECK(dt<2000000,"8,000 signals in one node take under 2 ms");
    free(n.signals);   // past the first signal the signals are in an allocated array
    // Marks left by earlier nodes (each node's mark is a number no other node gets) and the map's reset once it passes NQ_SIGNAL_WORDS words, which happens only as a node takes its mark,
    // never in the middle of one. A node of 20 signals on words 0-19, then a second one on the same words, finds none of them before adding each and all of them after. A node of 17,000 fresh
    // words then passes 16,384 in its middle and keeps every word, and the next node of 20 empties the map and marks its words again, the 16 it scanned first among them
    pthread_mutex_lock(&g_sub_mu);
    good=1; nq_node m[4]; memset(m,0,sizeof m);
    for(int k=0;k<2;k++) {
        for(int i=0;i<20;i++) { volatile uint32_t *w=&ev_words[i]; uint32_t mode=0, value=(uint32_t)i; memcpy(a,&w,8); memcpy(a+8,&mode,4); memcpy(a+12,&value,4); good&=!nq_signal_on(&m[k],a); nq_signal_add(&m[k],a); }
        for(int i=0;i<20;i++) { volatile uint32_t *w=&ev_words[i]; memcpy(a,&w,8); good&=nq_signal_on(&m[k],a); }
        good&=m[k].nsignals==20 && (list || m[k].signal_set);
    }
    if(!list) good&=m[0].signal_set!=m[1].signal_set;
    static uint32_t many[17000]; int kept=1, seen=0, big=list?0:17000;   // the scan keeps no map
    for(int i=0;i<big;i++) { volatile uint32_t *w=&many[i]; uint32_t mode=0, value=0; memcpy(a,&w,8); memcpy(a+8,&mode,4); memcpy(a+12,&value,4); seen+=nq_signal_on(&m[2],a); nq_signal_add(&m[2],a); }
    for(int i=0;i<big;i++) { volatile uint32_t *w=&many[i]; memcpy(a,&w,8); kept&=nq_signal_on(&m[2],a); }
    unsigned before=nq_signal_words.n;
    for(int i=0;i<20;i++) { volatile uint32_t *w=&ev_words[i]; uint32_t mode=1, value=(uint32_t)i; memcpy(a,&w,8); memcpy(a+8,&mode,4); memcpy(a+12,&value,4); good&=!nq_signal_on(&m[3],a); nq_signal_add(&m[3],a); }
    for(int i=0;i<20;i++) { volatile uint32_t *w=&ev_words[i]; memcpy(a,&w,8); good&=nq_signal_on(&m[3],a); }
    { volatile uint32_t *w=&many[0]; memcpy(a,&w,8); good&=!nq_signal_on(&m[3],a); }
    unsigned after=nq_signal_words.n;
    pthread_mutex_unlock(&g_sub_mu);
    printf("signal map: %u words after the node of 17,000, %u after the next node of 20\n",before,after);
    CHECK(good,"a node of 20 signals on words an earlier node marked finds none of them before adding each and all of them after");
    CHECK(!seen && kept,"a node whose words pass the map's limit in its middle keeps every one of them");
    if(!list) CHECK(before>16384 && after==20,"the map is emptied when the next node takes its mark, and that node's words are marked again");
    for(int k=0;k<4;k++) if(m[k].signals!=&m[k].signal0) free(m[k].signals);
}
// 2,000 GPU event signals on 2,000 events in one command buffer: one node with signal_events node, 2,000 with split. They publish in recorded order with their modes and values, and a wait on
// another queue, submitted first, for the last word's value is released and sees the payload written before the signals
static NVNmemoryPool pool2; static uint8_t *memory2; static NVNevent evs[2000]; static NVNcommandBuffer bigcmd;
static NVNcommandHandle record_signals(int count,NVNsync *fence) {
    P(nvnCommandBufferInitialize)(&bigcmd,&device);
    P(nvnCommandBufferAddCommandMemory)(&bigcmd,&pool2,65536,262144);
    P(nvnCommandBufferBeginRecording)(&bigcmd);
    uint32_t payload=after; P(nvnCommandBufferUpdateUniformBuffer)(&bigcmd,source_addr,4,0,4,&payload);
    for(int i=0;i<count;i++) P(nvnCommandBufferSignalEvent)(&bigcmd,&evs[i],i%5==0?NVN_EVENT_SIGNAL_MODE_ADD:NVN_EVENT_SIGNAL_MODE_WRITE,NVN_EVENT_SIGNAL_LOCATION_BOTTOM,0,(uint32_t)(3*i+1));
    P(nvnCommandBufferFenceSync)(&bigcmd,fence,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    return P(nvnCommandBufferEndRecording)(&bigcmd);
}
static void signals_2000(int node) {
    printf("CASE signal_events %s: 2,000 signals on 2,000 events in one command buffer\n",node?"node":"split");
    int saved=nq_signals_in_node(); nq_signal_node=node;
    *source=before; *result=sentinel; for(int i=0;i<2000;i++) P(nvnEventSignal)(&evs[i],NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNsync produced,consumed; P(nvnSyncInitialize)(&produced,&device); P(nvnSyncInitialize)(&consumed,&device);
    begin_cmd(0); P(nvnCommandBufferWaitEvent)(&commands[0],&evs[1999],NVN_EVENT_WAIT_MODE_EQUAL,3*1999+1);
    P(nvnCommandBufferCopyBufferToBuffer)(&commands[0],source_addr,result_addr,4,0);
    P(nvnCommandBufferFenceSync)(&commands[0],&consumed,NVN_SYNC_CONDITION_ALL_GPU_COMMANDS_COMPLETE,0);
    NVNcommandHandle ch=P(nvnCommandBufferEndRecording)(&commands[0]), ph=record_signals(2000,&produced);
    atomic_store(&pub_n,0);
    nvn_queue_test_hold(1);   // the consumer is queued before the producer
    job cj,pj; enqueue(&cj,&queues[0],ch); int cr=returned(&cj,250000000ull); enqueue(&pj,&queues[1],ph); int pr=returned(&pj,1000000000ull);
    uint64_t f0=mtl_last_fence();
    nvn_queue_test_hold(0);
    int done=landed(&produced,10000000000ull) && landed(&consumed,5000000000ull);
    if(!done) { P(nvnEventSignal)(&evs[1999],NVN_EVENT_SIGNAL_MODE_WRITE,3*1999+1); done=landed(&consumed,5000000000ull); }   // rescue before failing
    require_returned(&cj,cr); require_returned(&pj,pr);
    CHECK(cr && pr && done && *result==after,"the wait on another queue for the last signal is released and its copy sees the payload before the signals");
    uint64_t subs=mtl_last_fence()-f0;
    CHECK(subs==(node?2u:2001u),node?"node: the producer is one Metal submission, the consumer one":"split: each signal ends a submission (2,000), the consumer one");
    for(int k=0;k<2000 && atomic_load(&pub_n)<2000;k++) usleep(1000);
    int n=atomic_load(&pub_n), order=n==2000;
    for(int i=0;i<2000 && order;i++) order=pub_log[i].word==event_storage(&evs[i]) && pub_log[i].mode==(unsigned)(i%5==0) && pub_log[i].value==(uint32_t)(3*i+1);
    CHECK(order,"2,000 publications in recorded order with their modes and values");
    int values=1; for(int i=0;i<2000;i++) values&=P(nvnEventGetValue)(&evs[i])==(uint32_t)(3*i+1);
    CHECK(values,"every event holds its signal's value (an ADD to 0 or a WRITE)");
    if(!done) _Exit(2);
    P(nvnSyncFinalize)(&produced); P(nvnSyncFinalize)(&consumed); P(nvnCommandBufferFinalize)(&bigcmd);
    nq_signal_node=saved;
}
// Allocations per signal in split mode (nq_pooled): 400 signals in one command buffer, submitted twice. The second submission takes its nodes and receipts from the free lists and keeps each
// node's one signal inline, so it allocates about one command copy per signal (the spares, 4 or 32 with replay_spares, cover the first nodes); each signal took two nodes, a receipt and a signals array as well before
// (DM_NVN_NODE_POOL=0, checked to be at least 4 a signal)
static void split_allocations(void) {
    int off=env_is("DM_NVN_NODE_POOL","0");
    printf("CASE allocations per signal in split mode (%s)\n",off?"no free lists":"free lists");
    int saved=nq_signals_in_node(); nq_signal_node=0;
    for(int i=0;i<400;i++) P(nvnEventSignal)(&evs[i],NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNsync produced; P(nvnSyncInitialize)(&produced,&device);
    NVNcommandHandle h=record_signals(400,&produced);
    unsigned allocs[2]={0,0}; int done=1;
    for(int round=0;round<2;round++) {
        CHECK(queue_idle(5000000000ull),"the replay has taken every queued job");
        t_allocs=0; t_count_allocs=1; P(nvnQueueSubmitCommands)(&queues[0],1,&h); t_count_allocs=0; allocs[round]=t_allocs;
        done&=landed(&produced,10000000000ull);
    }
    CHECK(done && queue_idle(5000000000ull),"both submissions complete");
    double per=allocs[1]/400.0;
    printf("allocations on the submitting thread: %u for the first submission, %u for the second (%.2f a signal); a node is %zu bytes, a receipt %zu\n",allocs[0],allocs[1],per,sizeof(nq_node),sizeof(nq_receipt));
    if(off) CHECK(per>=4,"DM_NVN_NODE_POOL=0: two nodes, a receipt and a signals array per signal, as before");
    else CHECK(per<1.5,"the second submission allocates at most about a command copy per signal");
    if(!done) _Exit(2);
    P(nvnSyncFinalize)(&produced); P(nvnCommandBufferFinalize)(&bigcmd);
    nq_signal_node=saved;
}
// Spare command copies (nq_spare_take / nq_spare_give; profile key replay_spares, DM_REPLAY_SPARES): split mode makes a command node per signal, so 20 signals a submission are about 21 command
// nodes, as Ocarina of Time's ~20 a frame. Submitted three times: with replay_spares (32 kept) the third starts every node from a spare, with 4 at least 16 start without one, as before
// (the queue line's 'command nodes without a spare copy'). Then copies of 4 MB: with replay_spares the kept ones stay within NQ_SPARE_BYTES; one over NQ_SPARE_MAX is never kept
static void spare_copies(void) {
    int on=nvn_replay_spares(); printf("CASE spare command copies (%s)\n",on?"replay_spares, 32":"4, as X1.0");
    int saved=nq_signals_in_node(); nq_signal_node=0;
    for(int i=0;i<20;i++) P(nvnEventSignal)(&evs[i],NVN_EVENT_SIGNAL_MODE_WRITE,0);
    NVNsync produced; P(nvnSyncInitialize)(&produced,&device);
    NVNcommandHandle h=record_signals(20,&produced);
    uint64_t miss[3]={0,0,0}, nodes[3]={0,0,0}; int done=1;
    for(int round=0;round<3;round++) {
        done&=queue_idle(5000000000ull);
        uint64_t m0=atomic_load(&nq_stat_no_spare), n0=atomic_load(&nq_stat_nodes); P(nvnQueueSubmitCommands)(&queues[0],1,&h);
        miss[round]=atomic_load(&nq_stat_no_spare)-m0; nodes[round]=atomic_load(&nq_stat_nodes)-n0;
        done&=landed(&produced,10000000000ull);
    }
    done&=queue_idle(5000000000ull);
    printf("nodes per submission %llu; command nodes without a spare copy %llu, %llu, %llu; spare copies kept %llu (%.3f MB)\n",(unsigned long long)nodes[2],(unsigned long long)miss[0],(unsigned long long)miss[1],(unsigned long long)miss[2],
           (unsigned long long)atomic_load(&nq_stat_spares),atomic_load(&nq_stat_spare_bytes)/1048576.0);
    CHECK(done,"three submissions of 20 signals complete");
    if(on) CHECK(miss[2]==0,"replay_spares: every command node of the third starts from a spare");
    else CHECK(miss[2]>=16,"4 spares: 16 or more of its command nodes start without one, as before");
    pthread_mutex_lock(&g_sub_mu);
    nq_node held[NQ_SPARES_MAX]; memset(held,0,sizeof held); int nheld=0;
    while(nq_nspare) nq_spare_take(&held[nheld++]);   // the small spares out, so the big copies meet an empty set
    CHECK(nq_spare_bytes==0,"the spares' bytes counted back to 0");
    nq_node big[6]; memset(big,0,sizeof big);
    for(int i=0;i<6;i++) { big[i].capacity=i<5?NQ_SPARE_MAX:NQ_SPARE_MAX+4096; big[i].bytes=malloc(big[i].capacity); nq_spare_give(&big[i]); }
    int kept=nq_nspare; size_t bytes=nq_spare_bytes;
    CHECK(big[5].bytes!=NULL,"a copy over 4 MB is never kept");
    if(on) CHECK(kept==4 && bytes==NQ_SPARE_BYTES && big[4].bytes!=NULL,"replay_spares: four copies of 4 MB kept, the fifth not: 16 MB in all");
    else CHECK(kept==4 && big[4].bytes!=NULL,"4 spares: four kept, as before");
    for(int i=0;i<kept;i++) { nq_node t; memset(&t,0,sizeof t); nq_spare_take(&t); free(t.bytes); }
    for(int i=0;i<6;i++) free(big[i].bytes);
    for(int i=nheld-1;i>=0;i--) nq_spare_give(&held[i]);
    CHECK(nq_nspare==nheld,"the small spares back");
    pthread_mutex_unlock(&g_sub_mu);
    P(nvnSyncFinalize)(&produced); P(nvnCommandBufferFinalize)(&bigcmd);
    nq_signal_node=saved;
}
// DM_NVN_SIGNAL_EVENTS takes exactly node or split; unset or empty, the profile's signal_events. Any other value is logged and the profile's taken: Split, 0 or off chose node before (any
// value but split), the opposite of what an A/B meant to restore, with only the startup line to tell
static void signal_events_switch(void) {
    printf("CASE DM_NVN_SIGNAL_EVENTS values\n");
    CHECK(nq_signal_events_mode("node",0)==1 && nq_signal_events_mode("split",1)==0,"node and split choose their mode whatever the profile's");
    CHECK(nq_signal_events_mode(NULL,0)==0 && nq_signal_events_mode(NULL,1)==1 && nq_signal_events_mode("",0)==0 && nq_signal_events_mode("",1)==1,"unset or empty: the profile's");
    int other=1; const char *bad[]={"Split","SPLIT","0","off","Node","1"};
    for(unsigned i=0;i<sizeof bad/sizeof bad[0];i++) other&=nq_signal_events_mode(bad[i],0)==0 && nq_signal_events_mode(bad[i],1)==1;
    CHECK(other,"any other value (Split, SPLIT, 0, off, Node, 1): the profile's, not node");
    const char *was=getenv("DM_NVN_SIGNAL_EVENTS"); char keep[32]={0}; if(was) snprintf(keep,sizeof keep,"%s",was);
    int saved=nq_signal_node; setenv("DM_NVN_SIGNAL_EVENTS","Split",1); nq_signal_node=-1;
    CHECK(nq_signals_in_node()==DM_GAME_SIGNAL_EVENTS_NODE,"nq_signals_in_node takes the profile's for an unknown value");
    if(was) setenv("DM_NVN_SIGNAL_EVENTS",keep,1); else unsetenv("DM_NVN_SIGNAL_EVENTS");
    nq_signal_node=saved;
}
// The translation detail line's split and waits (nq_wait_stats, mtl_wait_stats, wait_split): a submission counts its copy apart from the replay; a submit that finds g_sub_mu held waits
// for it and counts that wait, an uncontended one none; the replay's g_rmu waits apart from another thread's; the encode thread's drains (DM_NVN_ENC_THREAD=1); and the line's text
static void *hold_sub_mu(void *arg) { pthread_mutex_lock(&g_sub_mu); dispatch_semaphore_signal((__bridge dispatch_semaphore_t)arg); usleep(20000); pthread_mutex_unlock(&g_sub_mu); return NULL; }
static void *hold_rmu(void *arg) { os_unfair_lock_lock(&g_rmu); dispatch_semaphore_signal((__bridge dispatch_semaphore_t)arg); usleep(20000); os_unfair_lock_unlock(&g_rmu); return NULL; }
static void wait_counters(void) {
    printf("CASE the submit's split and its waits\n");
    CHECK(queue_idle(5000000000ull),"the replay has taken every queued job");
    uint64_t q0[7], m0[7], q1[7], m1[7]; nq_wait_stats(q0); mtl_wait_stats(m0); uint64_t w0=atomic_load(&g_cum_sub_wall_ns), c0=atomic_load(&g_cum_sub_cpu_ns);
    NVNsync s; P(nvnSyncInitialize)(&s,&device); NVNcommandHandle h=consumer(0,0,&s,0); P(nvnQueueSubmitCommands)(&queues[0],1,&h);
    int fine=landed(&s,5000000000ull) && queue_idle(5000000000ull); P(nvnSyncFinalize)(&s);
    nq_wait_stats(q1); mtl_wait_stats(m1); uint64_t w1=atomic_load(&g_cum_sub_wall_ns), c1=atomic_load(&g_cum_sub_cpu_ns);
    CHECK(fine && q1[0]==q0[0]+1,"one submit counted");
    CHECK(q1[1]>q0[1] && q1[1]-q0[1]<w1-w0 && q1[2]-q0[2]<=c1-c0,"its copy's wall and CPU time, a part of the submit cost (the rest the replay's)");
    if(rec_on()) CHECK(m1[4]>m0[4],"the replay drained the encode thread");
    else CHECK(m1[4]==m0[4],"no encode thread, no drains");
    dispatch_semaphore_t held=dispatch_semaphore_create(0); pthread_t th;
    pthread_create(&th,NULL,hold_sub_mu,(__bridge void *)held); dispatch_semaphore_wait(held,DISPATCH_TIME_FOREVER);
    nq_sub_lock(0); pthread_mutex_unlock(&g_sub_mu); pthread_join(th,NULL); nq_wait_stats(q0);
    CHECK(q0[4]==q1[4]+1 && q0[3]-q1[3]>=10000000ull,"a submit behind a held g_sub_mu: one wait, about the 20 ms it was held");
    nq_sub_lock(0); pthread_mutex_unlock(&g_sub_mu); nq_wait_stats(q1);
    CHECK(q1[4]==q0[4] && q1[3]==q0[3],"an uncontended g_sub_mu: no wait counted");
    pthread_create(&th,NULL,hold_rmu,(__bridge void *)held); dispatch_semaphore_wait(held,DISPATCH_TIME_FOREVER);
    mtl_wait_stats(m0); rmu_lock(); os_unfair_lock_unlock(&g_rmu); pthread_join(th,NULL); mtl_wait_stats(m1);
    CHECK(m1[3]==m0[3]+1 && m1[2]-m0[2]>=10000000ull && m1[1]==m0[1],"a g_rmu wait off the replay thread counts as another thread's");
    uint64_t pq[7]={0}, pm[7]={0}, q[7]={600,30000000,15000000,6000000,120,3000000,60}, m[7]={9000000,600,1200000,60,1200,600,12000000};
    char line[768]; wait_split(line,sizeof line,q,pq,m,pm,300,300e6,150e6);
    printf("line:%s\n",line);
    CHECK(strstr(line,"command copy CPU 0.050 ms / wall 0.100 ms (2.0 submits) and the replay CPU 0.450 ms / wall 0.900 ms")!=NULL,"the line splits the copy from the replay");
    CHECK(strstr(line,"submits for g_sub_mu 0.020 ms (0.4 waits), the replay for g_sub_mu 0.010 ms (0.2), for g_rmu 0.030 ms (2.0), other threads for g_rmu 0.004 ms (0.2), the replay for the encode thread 0.040 ms (2.0 of 4.0 drains blocked)")!=NULL,"and gives each wait per frame");
}
// The replay threads' time-constraint policy (nvn_rt.h; profile key replay_rt, DM_REPLAY_RT): once a present period is known, the replay thread declares one at the first node of a new
// frame and the encode thread (DM_NVN_ENC_THREAD=1) after its first block of one, each in effect on that thread; with it off neither declares anything
static int rt_on_port(mach_port_t p) { thread_time_constraint_policy_data_t tp; mach_msg_type_number_t tc=THREAD_TIME_CONSTRAINT_POLICY_COUNT; boolean_t def=0;
    return p && thread_policy_get(p,THREAD_TIME_CONSTRAINT_POLICY,(thread_policy_t)&tp,&tc,&def)==KERN_SUCCESS && !def; }
static void replay_rt_case(void) {
    int on=nvn_replay_rt(); printf("CASE the replay threads' time-constraint policy (%s)\n",on?"on":"off");
    CHECK(!nq_rtw.started && !g_rec_rtw.started,"no declaration before a present period is known");
    atomic_store(&g_rt_frame_ns,16666667ull); uint64_t f0=atomic_load(&g_frame); int done=1;
    for(int k=1;k<=3;k++) {
        atomic_store(&g_frame,f0+1000+(uint64_t)k); NVNsync s; P(nvnSyncInitialize)(&s,&device);
        NVNcommandHandle h=consumer(0,0,&s,0); P(nvnQueueSubmitCommands)(&queues[0],1,&h); done&=landed(&s,5000000000ull); P(nvnSyncFinalize)(&s);
    }
    CHECK(done,"three frames' submissions complete");
    for(int i=0;i<200 && on && rec_on() && !g_rec_rtw.started;i++) usleep(5000);   // the encode thread ticks after its block, which may finish after the GPU did
    if(on) {
        CHECK(nq_rtw.started && nq_rtw.comp_ms>0 && nq_rtw.period_ms>16 && rt_on_port(nq_rtw.port),"the replay thread declared its policy, in effect on it");
        if(rec_on()) CHECK(g_rec_rtw.started && g_rec_rtw.comp_ms>0 && rt_on_port(g_rec_rtw.port),"the encode thread declared its own");
        else CHECK(!g_rec_rtw.started,"no encode thread (DM_NVN_ENC_THREAD=0): nothing declared for it");
    } else CHECK(!nq_rtw.started && !g_rec_rtw.started && !g_nrtw,"DM_REPLAY_RT=0: neither thread declares one");
    char st[512]; rtw_states(st,sizeof st); printf("policy line part:%s\n",st);
    atomic_store(&g_frame,f0); atomic_store(&g_rt_frame_ns,0);
}
int main(void) { @autoreleasepool {
    if (setvbuf(stdout, NULL, _IONBF, 0)) abort(); setenv("DM_PSO_PREPARE","0",1);
    mtl_init();
    NVNdeviceBuilder db={0}; P(nvnDeviceBuilderSetDefaults)(&db); CHECK(P(nvnDeviceInitialize)(&device,&db),"device initialized");
    for(int i=0;i<2;i++) { NVNqueueBuilder qb={0}; P(nvnQueueBuilderSetDefaults)(&qb); P(nvnQueueBuilderSetDevice)(&qb,&device); CHECK(P(nvnQueueInitialize)(&queues[i],&qb),"NVN queue initialized"); }
    CHECK(!posix_memalign((void **)&memory,getpagesize(),131072),"pool storage allocated"); if(!memory) return 2; memset(memory,0,131072);
    NVNmemoryPoolBuilder pb={0}; P(nvnMemoryPoolBuilderSetDefaults)(&pb); P(nvnMemoryPoolBuilderSetDevice)(&pb,&device); P(nvnMemoryPoolBuilderSetStorage)(&pb,memory,131072); P(nvnMemoryPoolBuilderSetFlags)(&pb,0x24);
    CHECK(P(nvnMemoryPoolInitialize)(&pool,&pb),"memory pool initialized");
    source=(volatile uint32_t *)(memory+65536); result=(volatile uint32_t *)(memory+65540);
    NVNbufferBuilder bb={0}; NVNbuffer buffer; P(nvnBufferBuilderSetDefaults)(&bb); P(nvnBufferBuilderSetDevice)(&bb,&device); P(nvnBufferBuilderSetStorage)(&bb,&pool,65536,16); CHECK(P(nvnBufferInitialize)(&buffer,&bb),"buffer initialized");
    source_addr=P(nvnBufferGetAddress)(&buffer); result_addr=source_addr+4;
    NVNeventBuilder eb={0}; P(nvnEventBuilderSetDefaults)(&eb); P(nvnEventBuilderSetStorage)(&eb,&pool,65544); CHECK(P(nvnEventInitialize)(&event,&eb),"event initialized");
    P(nvnEventBuilderSetStorage)(&eb,&pool,65600); CHECK(P(nvnEventInitialize)(&event2,&eb),"second event initialized");
    pthread_t worker; if(pthread_create(&worker,NULL,submit_worker,NULL)) return 2;
    // Warm the actual copy/fence path before making bounded negative assertions.
    *source=before; *result=sentinel; NVNsync warm; P(nvnSyncInitialize)(&warm,&device); job w; enqueue(&w,&queues[0],consumer(0,0,&warm,0));
    require_returned(&w,0); int warm_ok=landed(&warm,5000000000ull); CHECK(warm_ok && *result==before,"real GPU copy and fence warm-up"); if(!warm_ok) _Exit(2); P(nvnSyncFinalize)(&warm);
    case_wait("CPU release equality",0,0,1,0);
    case_wait("equality rejects a larger value",0,2,1,0);
    case_wait("wrap accepts zero after ffffffff",1,0,0xffffffff,1);
    case_wait("wrap rejects ffffffff before zero",1,0xffffffff,0,0);
    case_wait("wrap accepts half-range minus one",1,0x7fffffff,0,1);
    case_wait("wrap rejects exactly half-range",1,0x80000000,0,0);
    case_cross_queue();
    event_stale_gpu_reset();
    event_queued_write(NVN_EVENT_SIGNAL_MODE_WRITE);
    event_queued_write(NVN_EVENT_SIGNAL_MODE_ADD);
    event_signal_no_cut();
    frame_shares_allocator();
    post_ring_wait();
    signal_events_switch();
    receipt_tests();
    event_mirror_publication();
    signals_in_node(1); signals_in_node(0);
    signal_overwritten(1); signal_overwritten(0);
    CHECK(!posix_memalign((void **)&memory2,getpagesize(),524288),"second pool storage allocated"); if(!memory2) return 2; memset(memory2,0,524288);
    P(nvnMemoryPoolBuilderSetStorage)(&pb,memory2,524288); CHECK(P(nvnMemoryPoolInitialize)(&pool2,&pb),"second memory pool initialized");
    { int good=1; for(int i=0;i<2000;i++) { P(nvnEventBuilderSetStorage)(&eb,&pool2,16*i); good&=P(nvnEventInitialize)(&evs[i],&eb); } CHECK(good,"2,000 events initialized"); }
    report_due(); probe_cost(); event_bookkeeping(); signal_set();
    signals_2000(1); signals_2000(0);
    split_allocations();
    spare_copies();
    wait_counters();
    replay_rt_case();
    pthread_mutex_lock(&jobs_mu); jobs_stop=1; pthread_cond_signal(&jobs_cv); pthread_mutex_unlock(&jobs_mu); pthread_join(worker,NULL);
    printf("wait-event fixture: %d checks, %d failed\n",checks,fails);
    // The process owns the fixture pool until all callbacks have retired.
    return fails?1:0;
} }
