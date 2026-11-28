#include <pthread.h>
static int pending_cond_wait(pthread_cond_t *cv, pthread_mutex_t *mu);
#define pthread_cond_wait pending_cond_wait
#include "../nvn/nvn_mtl.m"
#undef pthread_cond_wait
#include <errno.h>
#include <pthread.h>
#include <time.h>
#include <mach/mach.h>
#include <pthread/qos.h>

void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }

static int g_checks, g_failed;
#define EXPECT_EQ(name, want, got) do { \
    long long w_ = (long long)(want), g_ = (long long)(got); g_checks++; \
    printf("%s expected %lld -> got %lld %s\n", name, w_, g_, w_ == g_ ? "OK" : "FAIL"); \
    g_failed += w_ != g_; \
} while (0)
#define EXPECT_TRUE(name, condition) EXPECT_EQ(name, 1, !!(condition))

// Hold a notified consumer before it reacquires the table lock, so admission can deterministically run in the completion-to-consumption window (upstream 9d3a58364)
static _Atomic int g_take_gate;
static dispatch_semaphore_t g_take_waiting, g_take_notified, g_take_resume;
static int pending_cond_wait(pthread_cond_t *cv, pthread_mutex_t *mu) {
    int gate = cv == &g_pp_cv && atomic_exchange(&g_take_gate, 0);
    if (gate) dispatch_semaphore_signal(g_take_waiting);
    int result = pthread_cond_wait(cv, mu);
    if (gate) {
        pthread_mutex_unlock(mu);
        dispatch_semaphore_signal(g_take_notified);
        dispatch_semaphore_wait(g_take_resume, DISPATCH_TIME_FOREVER);
        pthread_mutex_lock(mu);
    }
    return result;
}

@interface TestPipelineState : NSObject { @public int call; } @end
@implementation TestPipelineState @end
// A fake base: what pso_build_ex specializes from (spec_desc asks it for the descriptor to fill)
@interface TestBase : NSObject @end
@implementation TestBase
- (MTL4RenderPipelineDescriptor *)newRenderPipelineDescriptorForSpecialization { return [MTL4RenderPipelineDescriptor new]; }
@end
// Fake functions and their library: every function a pipeline is built from has a Metal 4 descriptor (fn4_note), and the fake compiler never reads one
@interface TestFunction : NSObject { @public MTLFunctionType type; } @end
@implementation TestFunction
- (NSString *)name { return @"pending-fake"; }
- (MTLFunctionType)functionType { return type; }
- (NSDictionary<NSString *, MTLFunctionConstant *> *)functionConstantsDictionary { return @{}; }   // none: fn4_note asks since 441247175 (a function with constants is noted with its defaults)
@end
@interface TestLibrary : NSObject @end
@implementation TestLibrary
- (id<MTLFunction>)newFunctionWithName:(NSString *)name { (void)name; return nil; }   // fn_off asks the entry for its constants: none, so no border-off variant
@end
static id<MTLFunction> test_function(MTLFunctionType type) {
    static id<MTLLibrary> lib; if (!lib) lib = (id<MTLLibrary>)[TestLibrary new];
    TestFunction *f = [TestFunction new]; f->type = type;
    return fn4_note((id<MTLFunction>)f, lib, @"pending-fake", nil);
}
static NvShader *test_shader(const char *key, MTLFunctionType type) {
    NvShader *s = [NvShader new]; snprintf(s->key, sizeof s->key, "%s", key); s->fn = test_function(type); return s;
}

// The fake MTL4Compiler, put in g_comp4 before the first pipeline (nvn_mtl.m makes its own only when g_comp4 is nil). A pipeline is a base, built once per shader pair
// (newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:, never held), then specialized for its colour state: the specialization is the compile each pipeline makes,
// and it blocks selected invocation numbers, so the test can hold real pso_pend_kick workers in the compiler without relying on driver timing.
@interface GateCompiler : NSObject {
    pthread_mutex_t _mu;
    pthread_cond_t _cv;
    int _entered, _released, _block_through, _nil_call;
    int _sync_calls, _async_calls;
    pthread_t _submitter;
    NSMutableArray *_results;
    BOOL _submitter_call[1024];
    int _check_absent_call;
    pso_key _absent_key;
    BOOL _absent_key_observed[1024];
    qos_class_t _call_qos[1024];
    mach_port_t _call_thread[1024];
}
- (instancetype)initBlockingThrough:(int)call nilCall:(int)nilCall;
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor compilerTaskOptions:(MTL4CompilerTaskOptions *)options error:(NSError **)error;
- (id<MTLRenderPipelineState>)newRenderPipelineStateBySpecializationWithDescriptor:(MTL4PipelineDescriptor *)descriptor pipeline:(id<MTLRenderPipelineState>)base error:(NSError **)error;
- (BOOL)waitForEntered:(int)count timeoutMs:(int)timeoutMs;
- (void)releaseThrough:(int)count;
- (void)releaseAll;
- (int)entered;
- (int)syncCalls;
- (int)asyncCalls;
- (BOOL)callWasOnSubmitter:(int)call;
- (void)expectAbsentPendingKey:(const pso_key *)key onSubmitterCall:(int)call;
- (BOOL)submitterCallObservedKeyAbsent:(int)call;
- (TestPipelineState *)resultForCall:(int)call;
- (qos_class_t)qosOfCall:(int)call;
- (mach_port_t)threadOfCall:(int)call;
@end

@implementation GateCompiler
- (instancetype)initBlockingThrough:(int)call nilCall:(int)nilCall {
    if ((self = [super init])) {
        pthread_mutex_init(&_mu, NULL); pthread_cond_init(&_cv, NULL);
        _block_through = call; _nil_call = nilCall; _submitter = pthread_self();
        _results = [NSMutableArray array];
    }
    return self;
}
- (void)dealloc { pthread_cond_destroy(&_cv); pthread_mutex_destroy(&_mu); }
- (id<MTLRenderPipelineState>)newRenderPipelineStateWithDescriptor:(MTL4PipelineDescriptor *)descriptor compilerTaskOptions:(MTL4CompilerTaskOptions *)options error:(NSError **)error {
    (void)descriptor; (void)options;
    if (error) *error = nil;
    return (id<MTLRenderPipelineState>)[TestBase new];
}
- (id<MTLRenderPipelineState>)newRenderPipelineStateBySpecializationWithDescriptor:(MTL4PipelineDescriptor *)descriptor pipeline:(id<MTLRenderPipelineState>)base error:(NSError **)error {
    (void)descriptor; (void)base;
    pthread_mutex_lock(&_mu);
    int n = ++_entered;
    TestPipelineState *result = [TestPipelineState new]; result->call = n;
    [_results addObject:result];
    BOOL on_submitter = pthread_equal(pthread_self(), _submitter);
    _submitter_call[n] = on_submitter;
    if (n < 1024) { _call_qos[n] = qos_class_self(); _call_thread[n] = pthread_mach_thread_np(pthread_self()); }
    BOOL check_absent = on_submitter && n == _check_absent_call;
    pso_key absent_key = _absent_key;
    if (on_submitter) _sync_calls++; else _async_calls++;
    pthread_cond_broadcast(&_cv);
    while (n <= _block_through && _released < n) pthread_cond_wait(&_cv, &_mu);
    BOOL fail = n == _nil_call;
    pthread_mutex_unlock(&_mu);
    if (check_absent) {
        pthread_mutex_lock(&g_pp_mu); BOOL absent = pso_pend_find(&absent_key) < 0; pthread_mutex_unlock(&g_pp_mu);
        pthread_mutex_lock(&_mu); _absent_key_observed[n] = absent; pthread_mutex_unlock(&_mu);
    }
    if (error) *error = nil;
    return fail ? nil : (id<MTLRenderPipelineState>)result;
}
- (BOOL)waitForEntered:(int)count timeoutMs:(int)timeoutMs {
    struct timespec end; clock_gettime(CLOCK_REALTIME, &end);
    end.tv_sec += timeoutMs / 1000; end.tv_nsec += (long)(timeoutMs % 1000) * 1000000L;
    if (end.tv_nsec >= 1000000000L) { end.tv_sec++; end.tv_nsec -= 1000000000L; }
    pthread_mutex_lock(&_mu);
    int rc = 0;
    while (_entered < count && rc != ETIMEDOUT) rc = pthread_cond_timedwait(&_cv, &_mu, &end);
    BOOL ok = _entered >= count;
    pthread_mutex_unlock(&_mu);
    return ok;
}
- (void)releaseThrough:(int)count {
    pthread_mutex_lock(&_mu); if (count > _released) _released = count; pthread_cond_broadcast(&_cv); pthread_mutex_unlock(&_mu);
}
- (void)releaseAll { [self releaseThrough:INT_MAX]; }
- (int)entered { pthread_mutex_lock(&_mu); int n = _entered; pthread_mutex_unlock(&_mu); return n; }
- (int)syncCalls { pthread_mutex_lock(&_mu); int n = _sync_calls; pthread_mutex_unlock(&_mu); return n; }
- (int)asyncCalls { pthread_mutex_lock(&_mu); int n = _async_calls; pthread_mutex_unlock(&_mu); return n; }
- (BOOL)callWasOnSubmitter:(int)call { pthread_mutex_lock(&_mu); BOOL b = call > 0 && call < 1024 && _submitter_call[call]; pthread_mutex_unlock(&_mu); return b; }
- (void)expectAbsentPendingKey:(const pso_key *)key onSubmitterCall:(int)call {
    pthread_mutex_lock(&_mu); if (key) _absent_key = *key; _check_absent_call = call; pthread_mutex_unlock(&_mu);
}
- (BOOL)submitterCallObservedKeyAbsent:(int)call {
    pthread_mutex_lock(&_mu); BOOL b = call > 0 && call < 1024 && _absent_key_observed[call]; pthread_mutex_unlock(&_mu); return b;
}
- (qos_class_t)qosOfCall:(int)call { pthread_mutex_lock(&_mu); qos_class_t q = call > 0 && call < 1024 ? _call_qos[call] : QOS_CLASS_UNSPECIFIED; pthread_mutex_unlock(&_mu); return q; }
- (mach_port_t)threadOfCall:(int)call { pthread_mutex_lock(&_mu); mach_port_t t = call > 0 && call < 1024 ? _call_thread[call] : MACH_PORT_NULL; pthread_mutex_unlock(&_mu); return t; }
- (TestPipelineState *)resultForCall:(int)call {
    pthread_mutex_lock(&_mu); TestPipelineState *o = call > 0 && call <= (int)_results.count ? _results[(NSUInteger)call - 1] : nil; pthread_mutex_unlock(&_mu); return o;
}
@end

// A device that only counts texture allocations (and makes none): put in g_dev for the prediction's attachment case, where the test otherwise runs with no device
@interface CountingDevice : NSObject { @public int texture_allocations; } @end
@implementation CountingDevice
- (id<MTLTexture>)newTextureWithDescriptor:(MTLTextureDescriptor *)descriptor { (void)descriptor; texture_allocations++; return nil; }
@end

static struct timespec deadline_after_ms(int timeout_ms) {
    struct timespec end; clock_gettime(CLOCK_REALTIME, &end);
    end.tv_sec += timeout_ms / 1000; end.tv_nsec += (long)(timeout_ms % 1000) * 1000000L;
    if (end.tv_nsec >= 1000000000L) { end.tv_sec++; end.tv_nsec -= 1000000000L; }
    return end;
}

static int pending_done(const pso_key *k, int timeout_ms) {
    struct timespec end = deadline_after_ms(timeout_ms);
    pthread_mutex_lock(&g_pp_mu);
    int at = pso_pend_find(k), rc = 0;
    while (at >= 0 && !g_pp[at].done && rc != ETIMEDOUT) {
        rc = pthread_cond_timedwait(&g_pp_cv, &g_pp_mu, &end);
        at = pso_pend_find(k);
    }
    int done = at >= 0 && g_pp[at].done;
    pthread_mutex_unlock(&g_pp_mu);
    return done;
}

static int queue_index(const pso_key *k) {
    pthread_mutex_lock(&g_pp_mu); int at = pso_pend_find(k); pthread_mutex_unlock(&g_pp_mu); return at;
}
static int queue_used_count(void) {
    int n = 0; pthread_mutex_lock(&g_pp_mu);
    for (int i = 0; i < PSO_PEND_MAX; i++) n += g_pp[i].used != 0;
    pthread_mutex_unlock(&g_pp_mu); return n;
}
static int queue_active_count(void) {
    int n = 0; pthread_mutex_lock(&g_pp_mu);
    for (int i = 0; i < PSO_PEND_MAX; i++) n += g_pp[i].used && !g_pp[i].done;
    pthread_mutex_unlock(&g_pp_mu); return n;
}
static int queue_done_at(int at) {
    pthread_mutex_lock(&g_pp_mu); int done = at >= 0 && at < PSO_PEND_MAX ? g_pp[at].done : -1; pthread_mutex_unlock(&g_pp_mu); return done;
}
static int drain_queue(int timeout_ms) {
    struct timespec end = deadline_after_ms(timeout_ms);
    pthread_mutex_lock(&g_pp_mu);
    int active = 1, rc = 0;
    while (active && rc != ETIMEDOUT) {
        active = 0;
        for (int i = 0; i < PSO_PEND_MAX; i++) active |= g_pp[i].used && !g_pp[i].done;
        if (active) rc = pthread_cond_timedwait(&g_pp_cv, &g_pp_mu, &end);
    }
    pthread_mutex_unlock(&g_pp_mu);
    return !active;
}
static void reset_queue(void) {
    pthread_mutex_lock(&g_pp_mu);
    for (int i = 0; i < PSO_PEND_MAX; i++) {
        g_pp[i].ps = nil; memset(&g_pp[i].k, 0, sizeof g_pp[i].k);
        g_pp[i].used = g_pp[i].done = g_pp[i].taking = 0; g_pp[i].order = 0;
    }
    g_pp_kicked = g_pp_taken = 0;
    pthread_mutex_unlock(&g_pp_mu);
}
static void release_cf_value(void *p) { if (p) CFRelease(p); }
static void reset_pso_cache(void) {
    nvn_hm_clear(&g_pso, release_cf_value);
    nvn_hm_clear(&g_pso_fail, release_cf_value);
}

static NvShader *test_vs, *test_fs;
static uint64_t g_key_vs[1024], g_key_fs[1024];
static pso_key make_key(unsigned tag) {
    pso_key k = {0};
    g_key_vs[tag] = tag * 3 + 1; g_key_fs[tag] = tag * 3 + 2;
    k.vs = &g_key_vs[tag]; k.fs = &g_key_fs[tag];
    k.cfmt[0] = MTLPixelFormatRGBA8Unorm; k.samples = 1; k.chmask = 0xffffffffu;
    return k;
}

typedef struct { pso_key k; NvShader *vs, *fs; pthread_mutex_t mu; pthread_cond_t cv; int done, result; } kick_job;
static void *kick_job_main(void *arg) {
    kick_job *j = arg; int result = pso_pend_kick(&j->k, j->vs, j->fs);
    pthread_mutex_lock(&j->mu); j->result = result; j->done = 1; pthread_cond_broadcast(&j->cv); pthread_mutex_unlock(&j->mu);
    return NULL;
}
static int wait_kick_job(kick_job *j, int timeout_ms) {
    struct timespec end = deadline_after_ms(timeout_ms);
    pthread_mutex_lock(&j->mu); int rc = 0;
    while (!j->done && rc != ETIMEDOUT) rc = pthread_cond_timedwait(&j->cv, &j->mu, &end);
    int done = j->done; pthread_mutex_unlock(&j->mu); return done;
}

static void test_two_active_exact_take_and_release(void) {
    reset_queue();
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:2 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    pso_key a = make_key(1), b = make_key(2), c = make_key(3), wrong_attachment = a;
    wrong_attachment.cfmt[0] = MTLPixelFormatBGRA8Unorm;
    EXPECT_EQ("first prediction admitted", 1, pso_pend_kick(&a, test_vs, test_fs));
    if (![dev waitForEntered:1 timeoutMs:5000]) { EXPECT_TRUE("first worker entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    EXPECT_EQ("second prediction admitted", 1, pso_pend_kick(&b, test_vs, test_fs));
    if (![dev waitForEntered:2 timeoutMs:5000]) { EXPECT_TRUE("second worker entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    EXPECT_EQ("two compilation slots are outstanding", 2, queue_active_count());
    kick_job job = {.k = c, .vs = test_vs, .fs = test_fs}; pthread_mutex_init(&job.mu, NULL); pthread_cond_init(&job.cv, NULL);
    pthread_t thread; int thread_error = pthread_create(&thread, NULL, kick_job_main, &job);
    EXPECT_EQ("start bounded third-kick check", 0, thread_error);
    if (thread_error) { [dev releaseAll]; drain_queue(5000); reset_queue(); pthread_cond_destroy(&job.cv); pthread_mutex_destroy(&job.mu); return; }
    int returned_without_wait = wait_kick_job(&job, 1000);
    EXPECT_TRUE("third kick returns while both compiler gates remain closed", returned_without_wait);
    if (!returned_without_wait) [dev releaseAll];
    pthread_join(thread, NULL);
    EXPECT_EQ("third prediction is rejected at active limit", 0, job.result);
    pthread_cond_destroy(&job.cv); pthread_mutex_destroy(&job.mu);
    if (!returned_without_wait) { drain_queue(5000); reset_queue(); return; }
    EXPECT_EQ("rejected third prediction never reaches compiler", 2, [dev entered]);
    EXPECT_EQ("rejected third prediction does not consume an admission order", 2, g_pp_kicked);
    EXPECT_TRUE("different attachment key does not match pending key", pso_pend_take(&wrong_attachment) == nil);
    EXPECT_TRUE("wrong-key take leaves original pending", queue_index(&a) >= 0);

    [dev releaseThrough:1];
    EXPECT_TRUE("first worker completes", pending_done(&a, 5000));
    TestPipelineState *expected_a = [dev resultForCall:1];
    id<MTLRenderPipelineState> taken_a = pso_pend_take(&a);
    EXPECT_TRUE("exact-key take returns first compilation", taken_a != nil && (__bridge void *)taken_a == (__bridge void *)expected_a);
    EXPECT_EQ("taking completed result releases its slot", -1, queue_index(&a));
    EXPECT_EQ("other worker remains active in its slot", 1, queue_active_count());

    [dev releaseThrough:2];
    EXPECT_TRUE("second worker completes", pending_done(&b, 5000));
    TestPipelineState *expected_b = [dev resultForCall:2];
    id<MTLRenderPipelineState> taken_b = pso_pend_take(&b);
    EXPECT_TRUE("second exact-key take returns its own result", taken_b != nil && (__bridge void *)taken_b == (__bridge void *)expected_b);
    EXPECT_EQ("both take operations leave no active workers", 0, queue_active_count());
    reset_queue();
}

// A later draw of the submission (pso_pend_kick_next) is admitted while PSO_PEND_ACTIVE guesses run, on pp_bg_queue's serial queues (NX 18; upstream PR #1344 puts it on the
// global queue); a guess still is not. With one such queue the two later draws run one after the other
static void test_next_draws_pass_the_guess_limit(void) {
    reset_queue();
    int bg = pp_bg_count(), want = bg >= 2 ? 4 : 3;
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:4 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    pso_key a = make_key(600), b = make_key(601), c = make_key(602), d = make_key(603), guess = make_key(604);
    EXPECT_EQ("first guess admitted", 1, pso_pend_kick(&a, test_vs, test_fs));
    EXPECT_EQ("second guess admitted", 1, pso_pend_kick(&b, test_vs, test_fs));
    if (![dev waitForEntered:2 timeoutMs:5000]) { EXPECT_TRUE("guess workers entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    EXPECT_EQ("a later draw is admitted at the guess limit", 1, pso_pend_kick_next(&c, test_vs, test_fs));
    EXPECT_EQ("another later draw is admitted", 1, pso_pend_kick_next(&d, test_vs, test_fs));
    EXPECT_TRUE("the later draws compile beside the guesses on the background queues", [dev waitForEntered:want timeoutMs:5000]);
    EXPECT_EQ("a guess is still refused while builds run", 0, pso_pend_kick(&guess, test_vs, test_fs));
    EXPECT_EQ("a later draw already in the table is not admitted twice", 0, pso_pend_kick_next(&c, test_vs, test_fs));
    [dev releaseAll];
    EXPECT_TRUE("later draws complete", pending_done(&c, 5000) && pending_done(&d, 5000));
    EXPECT_TRUE("their draws take them", pso_pend_take(&c) != nil && pso_pend_take(&d) != nil);
    drain_queue(5000); reset_queue();
}

// A backlog of later draws' builds on pp_bg_queue does not count toward PSO_PEND_ACTIVE: the next look-ahead's first two (pso_pend_kick) are still admitted, start on the global
// queue at user-initiated QoS as before upstream PR #1344, and its guesses keep their bound of two. The later draws run at utility QoS (pp_bg_queue)
static void test_next_backlog_keeps_first_two_on_global_queue(void) {
    reset_queue();
    int bg = pp_bg_count(), nb = bg < 3 ? bg : 3;   // three later draws round robin over the queues: as many enter the compiler at once as there are queues, up to 3
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:nb + 2 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    pso_key c = make_key(620), d = make_key(621), e = make_key(622), a = make_key(623), b = make_key(624), guess = make_key(625);
    EXPECT_EQ("later draws admitted (1)", 1, pso_pend_kick_next(&c, test_vs, test_fs));
    EXPECT_EQ("later draws admitted (2)", 1, pso_pend_kick_next(&d, test_vs, test_fs));
    EXPECT_EQ("later draws admitted (3)", 1, pso_pend_kick_next(&e, test_vs, test_fs));
    if (![dev waitForEntered:nb timeoutMs:5000]) { EXPECT_TRUE("later-draw workers entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    int utility = 1; for (int i = 1; i <= nb; i++) utility &= [dev qosOfCall:i] == QOS_CLASS_UTILITY;
    EXPECT_TRUE("the later draws' builds run at utility QoS (pp_bg_queue)", utility);
    EXPECT_EQ("three later draws' builds pending", 3, queue_active_count());
    EXPECT_EQ("first look-ahead build admitted beside the backlog", 1, pso_pend_kick(&a, test_vs, test_fs));
    EXPECT_EQ("second look-ahead build admitted beside the backlog", 1, pso_pend_kick(&b, test_vs, test_fs));
    EXPECT_TRUE("both start at once", [dev waitForEntered:nb + 2 timeoutMs:5000]);
    EXPECT_TRUE("both run at user-initiated QoS (the global queue)", [dev qosOfCall:nb + 1] == QOS_CLASS_USER_INITIATED && [dev qosOfCall:nb + 2] == QOS_CLASS_USER_INITIATED);
    EXPECT_EQ("a third guess is refused: two guesses run", 0, pso_pend_kick(&guess, test_vs, test_fs));
    [dev releaseAll];
    EXPECT_TRUE("all builds complete", pending_done(&a, 5000) && pending_done(&b, 5000) && pending_done(&c, 5000) && pending_done(&d, 5000) && pending_done(&e, 5000));
    drain_queue(5000); reset_queue();
}

static int thread_curpri(mach_port_t t) {
    thread_extended_info_data_t info; mach_msg_type_number_t n = THREAD_EXTENDED_INFO_COUNT;
    return t != MACH_PORT_NULL && thread_info(t, THREAD_EXTENDED_INFO, (thread_info_t)&info, &n) == KERN_SUCCESS ? info.pth_curpri : -1;
}
typedef struct { GateCompiler *dev; uint64_t boost0; mach_port_t worker; int seen, pri; } lend_job;
static void *lend_job_main(void *arg) {
    lend_job *j = arg; struct timespec end = deadline_after_ms(5000), now;
    for (;;) {
        pthread_mutex_lock(&g_pp_mu); int seen = g_pp_boost > j->boost0; pthread_mutex_unlock(&g_pp_mu);
        if (seen) { j->seen = 1; break; }
        clock_gettime(CLOCK_REALTIME, &now); if (now.tv_sec > end.tv_sec || (now.tv_sec == end.tv_sec && now.tv_nsec >= end.tv_nsec)) break;
        usleep(1000);
    }
    if (j->seen) { usleep(20000); j->pri = thread_curpri(j->worker); }
    [j->dev releaseAll];
    return NULL;
}
// A draw that reaches a later draw's build its utility-QoS worker already runs waits for it with the worker raised to the waiting thread's QoS until it ends, as it had
// compiled the pipeline itself at that QoS before the look-ahead admitted it
static void test_wait_on_running_next_build_lends_qos(void) {
    reset_queue();
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:1 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    pso_key c = make_key(630);
    EXPECT_EQ("later draw admitted", 1, pso_pend_kick_next(&c, test_vs, test_fs));
    if (![dev waitForEntered:1 timeoutMs:5000]) { EXPECT_TRUE("later-draw worker entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    mach_port_t worker = [dev threadOfCall:1]; int pri0 = thread_curpri(worker);
    qos_class_t own = qos_class_self(); pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    lend_job j = {.dev = dev, .worker = worker}; pthread_mutex_lock(&g_pp_mu); j.boost0 = g_pp_boost; pthread_mutex_unlock(&g_pp_mu);
    pthread_t th; pthread_create(&th, NULL, lend_job_main, &j);
    id<MTLRenderPipelineState> got = pso_pend_take(&c);
    pthread_join(th, NULL); if (own != QOS_CLASS_UNSPECIFIED) pthread_set_qos_class_self_np(own, 0);
    EXPECT_TRUE("the draw takes the worker's pipeline", got != nil && [dev syncCalls] == 0);
    EXPECT_TRUE("the wait lent its QoS to the running worker", j.seen);
    printf("worker priority %d at utility QoS, %d while a user-initiated draw waits\n", pri0, j.pri);
    EXPECT_TRUE("the worker runs above its utility priority while the draw waits", pri0 > 0 && j.pri > pri0);
    pthread_mutex_lock(&g_pp_mu); uint64_t b = g_pp_boost; pthread_mutex_unlock(&g_pp_mu);
    EXPECT_EQ("one wait lent its QoS", 1, (int)(b - j.boost0));
    drain_queue(5000); reset_queue();
}

static void test_full_table_reclaims_done_not_running(void) {
    reset_queue();
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:2 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    pso_key oldest = make_key(4), running = make_key(5);
    EXPECT_EQ("oldest slot admitted", 1, pso_pend_kick(&oldest, test_vs, test_fs));
    if (![dev waitForEntered:1 timeoutMs:5000]) { EXPECT_TRUE("oldest worker entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    EXPECT_EQ("running slot admitted", 1, pso_pend_kick(&running, test_vs, test_fs));
    if (![dev waitForEntered:2 timeoutMs:5000]) { EXPECT_TRUE("running worker entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    int oldest_slot = queue_index(&oldest), running_slot = queue_index(&running);
    [dev releaseThrough:1];
    EXPECT_TRUE("oldest prediction becomes completed but remains in table", pending_done(&oldest, 5000));

    int filled = 0;
    for (int i = 0; i < PSO_PEND_MAX - 2; i++) {
        pso_key k = make_key((unsigned)(10 + i));
        if (pso_pend_kick(&k, test_vs, test_fs) != 1 || !pending_done(&k, 5000)) break;
        filled++;
    }
    EXPECT_EQ("completed entries fill all remaining slots", PSO_PEND_MAX - 2, filled);
    EXPECT_EQ("table is full before overflow admission", PSO_PEND_MAX, queue_used_count());
    EXPECT_EQ("one existing worker remains active in full table", 1, queue_active_count());

    pso_key newest = make_key(500);
    EXPECT_EQ("full table admits by reclaiming a completed entry", 1, pso_pend_kick(&newest, test_vs, test_fs));
    EXPECT_TRUE("overflow compilation completes", pending_done(&newest, 5000));
    EXPECT_EQ("oldest completed key was reclaimed", -1, queue_index(&oldest));
    EXPECT_EQ("new key reused oldest completed slot", oldest_slot, queue_index(&newest));
    EXPECT_EQ("running key kept its original slot", running_slot, queue_index(&running));
    EXPECT_EQ("running slot is still not done", 0, queue_done_at(running_slot));
    EXPECT_EQ("table remains full after replacing done entry", PSO_PEND_MAX, queue_used_count());

    [dev releaseThrough:2];
    EXPECT_TRUE("running compilation eventually completes", pending_done(&running, 5000));
    id<MTLRenderPipelineState> got_running = pso_pend_take(&running);
    EXPECT_TRUE("running result is still retrievable", got_running != nil && (__bridge void *)got_running == (__bridge void *)[dev resultForCall:2]);
    id<MTLRenderPipelineState> got_newest = pso_pend_take(&newest);
    EXPECT_TRUE("replacement result is retrievable", got_newest != nil && (__bridge void *)got_newest == (__bridge void *)[dev resultForCall:PSO_PEND_MAX + 1]);
    EXPECT_TRUE("reclaimed key cannot be taken", pso_pend_take(&oldest) == nil);
    EXPECT_EQ("no workers remain after takes", 0, queue_active_count());
    reset_queue();
}

static void append_op(uint8_t *buf, size_t *used, unsigned op, const void *payload, size_t n) {
    size_t size = (8 + n + 7) & ~7ull;
    op_hdr h = {op, (uint32_t)size}; memcpy(buf + *used, &h, sizeof h);
    if (n) memcpy(buf + *used + 8, payload, n);
    *used += size;
}

static void test_completed_slot_kept_for_waiting_draw(void) {
    reset_queue();
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:1 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    pso_key waiting = make_key(710), replacement = make_key(711);
    EXPECT_EQ("waiting draw's build admitted", 1, pso_pend_kick_next(&waiting, test_vs, test_fs));
    if (![dev waitForEntered:1 timeoutMs:5000]) { EXPECT_TRUE("waiting build entered", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    int original_slot = queue_index(&waiting);
    pthread_mutex_lock(&g_pp_mu);
    for (int i = 0; i < PSO_PEND_MAX; i++) if (!g_pp[i].used) {
        g_pp[i].k = make_key((unsigned)i + 1); g_pp[i].used = g_pp[i].done = 1;
        g_pp[i].run = 0; g_pp[i].d = nil; g_pp[i].order = ++g_pp_kicked;
    }
    pthread_mutex_unlock(&g_pp_mu);
    g_take_waiting = dispatch_semaphore_create(0); g_take_notified = dispatch_semaphore_create(0); g_take_resume = dispatch_semaphore_create(0);
    atomic_store(&g_take_gate, 1);
    dispatch_group_t consumer = dispatch_group_create(); __block id<MTLRenderPipelineState> result = nil;
    dispatch_group_async(consumer, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{ result = pso_pend_take(&waiting); });
    EXPECT_EQ("draw waits for its running build", 0, dispatch_semaphore_wait(g_take_waiting, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    [dev releaseThrough:1];
    EXPECT_EQ("draw is notified but has not consumed its pipeline", 0, dispatch_semaphore_wait(g_take_notified, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    EXPECT_EQ("background admission still uses another completed slot", 1, pso_pend_kick_d(&replacement, pso_desc(&replacement, test_vs, test_fs, nil, 0), 2, nil));
    EXPECT_TRUE("replacement build completes", pending_done(&replacement, 5000));
    EXPECT_TRUE("waiting draw's completed slot is not reclaimed", queue_index(&replacement) != original_slot);
    dispatch_semaphore_signal(g_take_resume);
    EXPECT_EQ("waiting draw returns", 0, dispatch_group_wait(consumer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)));
    EXPECT_TRUE("waiting draw receives its own pipeline", (__bridge void *)result == (__bridge void *)[dev resultForCall:1]);
    EXPECT_TRUE("replacement remains available to its own draw", pso_pend_take(&replacement) != nil);
    [dev releaseAll]; drain_queue(5000); reset_queue();
}

// A lookup worker and the submit thread use the same admission operation. Two
// predictions may finish in A, A, B, A order, even after earlier builds retire.
static void test_interleaved_prediction_budgets(void) {
    reset_queue();
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:0 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    PsoPredictBudget *older = [PsoPredictBudget new], *newer = [PsoPredictBudget new];
    for (unsigned i = 0; i < 2; i++) {
        pso_key k = make_key(700 + i);
        EXPECT_EQ("older prediction admits a guess", 1, pso_pend_kick_d(&k, pso_desc(&k, test_vs, test_fs, nil, 0), 1, older));
        EXPECT_TRUE("older guess finishes and is taken", pending_done(&k, 5000) && pso_pend_take(&k) != nil);
    }
    pso_key b = make_key(702), a = make_key(703), c = make_key(704), demand = make_key(705);
    EXPECT_EQ("newer prediction has a separate budget", 1, pso_pend_kick_budget(&b, test_vs, test_fs, 1, newer));
    EXPECT_TRUE("newer guess finishes", pending_done(&b, 5000));
    EXPECT_EQ("interleaved older worker cannot replenish its budget", 0, pso_pend_kick_d(&a, pso_desc(&a, test_vs, test_fs, nil, 0), 1, older));
    EXPECT_EQ("duplicate admission does not spend the newer budget", 0, pso_pend_kick_d(&b, pso_desc(&b, test_vs, test_fs, nil, 0), 1, newer));
    EXPECT_EQ("submitter and worker share the newer budget", 1, pso_pend_kick_d(&c, pso_desc(&c, test_vs, test_fs, nil, 0), 1, newer));
    EXPECT_TRUE("second newer guess finishes", pending_done(&c, 5000));
    EXPECT_EQ("submitter cannot exceed the worker's budget", 0, pso_pend_kick_budget(&a, test_vs, test_fs, 1, newer));
    EXPECT_EQ("a later draw remains outside the guess budget", 1, pso_pend_kick_d(&demand, pso_desc(&demand, test_vs, test_fs, nil, 0), 2, older));
    EXPECT_TRUE("later draw finishes", pending_done(&demand, 5000));
    EXPECT_EQ("older prediction spent exactly two guesses", 2, older->admitted);
    EXPECT_EQ("newer prediction spent exactly two guesses", 2, newer->admitted);
    drain_queue(5000); reset_queue();
}

static _Atomic int g_counts_stop;
static void *completed_counts_main(void *unused) {
    (void)unused; uint64_t count = 0;
    while (!atomic_load(&g_counts_stop)) {
        pthread_mutex_lock(&g_pp_mu);
        g_pp_kicked = ++count; g_pp_done_n = count;
        pthread_mutex_unlock(&g_pp_mu);
    }
    return NULL;
}
static void test_inflight_counter_snapshot(void) {
    pthread_mutex_lock(&g_pp_mu);
    uint64_t kicked = g_pp_kicked, done = g_pp_done_n, stolen = g_pp_stolen;
    g_pp_kicked = g_pp_done_n = g_pp_stolen = 0;
    pthread_mutex_unlock(&g_pp_mu);
    atomic_store(&g_counts_stop, 0); pthread_t writer;
    int rc = pthread_create(&writer, NULL, completed_counts_main, NULL);
    EXPECT_EQ("start concurrent admission/completion counters", 0, rc);
    if (!rc) {
        int valid = 1; char line[4096];
        for (int i = 0; i < 20000 && valid; i++) {
            mtl_pso_line(line, sizeof line);
            const char *at = strstr(line, "in flight ");
            valid = at && strtoull(at + strlen("in flight "), NULL, 10) <= 1;
        }
        atomic_store(&g_counts_stop, 1); pthread_join(writer, NULL);
        EXPECT_TRUE("concurrent counter snapshots never underflow", valid);
    }
    pthread_mutex_lock(&g_pp_mu); g_pp_kicked = kicked; g_pp_done_n = done; g_pp_stolen = stolen; pthread_mutex_unlock(&g_pp_mu);
}

static void test_nil_prediction_falls_back_then_predicts(void) {
    reset_queue(); reset_pso_cache(); state_reset();
    unsetenv("DM_NVN_HILITE"); unsetenv("DM_NVN_MAGSCAN"); unsetenv("DM_PSO_RECORD"); unsetenv("DM_PSO_USER"); unsetenv("DM_SAVE");
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:1 nilCall:1]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    NvShader *vs1 = test_shader("pending-vs1", MTLFunctionTypeVertex), *fs1 = test_shader("pending-fs1", MTLFunctionTypeFragment);
    NvShader *vs2 = test_shader("pending-vs2", MTLFunctionTypeVertex), *fs2 = test_shader("pending-fs2", MTLFunctionTypeFragment);
    NvProg *demand = [NvProg new]; demand->sh[0] = vs1; demand->sh[1] = fs1;
    NvProg *predicted = [NvProg new]; predicted->sh[0] = vs2; predicted->sh[1] = fs2;
    pso_key demand_key; pso_key_fill(&demand_key, vs1, fs1, g_pass.cfmt, g_pass.dfmt, g_pass.sfmt, g_pass.samples, 0);
    EXPECT_EQ("speculative version admitted", 1, pso_pend_kick(&demand_key, vs1, fs1));
    if (![dev waitForEntered:1 timeoutMs:5000]) { EXPECT_TRUE("speculative worker entered fake compiler", 0); [dev releaseAll]; drain_queue(5000); reset_queue(); return; }
    [dev releaseThrough:1];
    EXPECT_TRUE("fake compiler can complete speculative job with nil", pending_done(&demand_key, 5000));
    EXPECT_TRUE("completed nil result remains available to demand lookup", queue_index(&demand_key) >= 0);

    // A repeated demanded draw must use the freshly populated cache, while a
    // second program supplies a real prediction without a Metal encoder.
    prog_t predicted_control = {.magic = MAGIC('P', 'R', 'O', 'G'), .nstage = 2, .serial = 0x7f010001};
    serial_put(predicted_control.serial, predicted);
    prog_t demand_control = {.magic = MAGIC('P', 'R', 'O', 'G'), .nstage = 2, .serial = 0x7f010002};
    serial_put(demand_control.serial, demand);
    uint8_t stream[256] = {0}; size_t used = 0;
    p_bind_program repeated = {&demand_control, 3}; append_op(stream, &used, OP_BIND_PROGRAM, &repeated, sizeof repeated);
    p_draw repeated_draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .first = 0, .count = 3, .instances = 1};
    append_op(stream, &used, OP_DRAW, &repeated_draw, sizeof repeated_draw);
    p_bind_program bind = {&predicted_control, 3}; append_op(stream, &used, OP_BIND_PROGRAM, &bind, sizeof bind);
    p_draw draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .first = 0, .count = 3, .instances = 1};
    append_op(stream, &used, OP_DRAW, &draw, sizeof draw); append_op(stream, &used, OP_END, NULL, 0);
    pso_key predicted_key; pso_key_fill(&predicted_key, vs2, fs2, g_pass.cfmt, g_pass.dfmt, g_pass.sfmt, g_pass.samples, 0);
    [dev expectAbsentPendingKey:&predicted_key onSubmitterCall:2];
    g_exec_next = stream; g_sub_serial = 1; g_pp_submit_mark = 0;

    id<MTLRenderPipelineState> got = pso_get_(demand);
    EXPECT_TRUE("demand compile synchronously falls back after speculative nil", got != nil && (__bridge void *)got == (__bridge void *)[dev resultForCall:2]);
    EXPECT_TRUE("repeated demanded draw is not queued as duplicate speculation", queue_index(&demand_key) < 0);
    EXPECT_TRUE("demand compiler call ran on submitter thread", [dev callWasOnSubmitter:2]);
    EXPECT_TRUE("predicted key was not reserved when demand compile entered", [dev submitterCallObservedKeyAbsent:2]);
    EXPECT_TRUE("prediction compiler call ran after demand call", [dev waitForEntered:3 timeoutMs:5000] && ![dev callWasOnSubmitter:3]);
    EXPECT_EQ("fake compiler observed one synchronous and two async calls", 1, [dev syncCalls]);
    EXPECT_EQ("fake compiler observed speculative and predicted async calls", 2, [dev asyncCalls]);
    EXPECT_TRUE("lookahead prediction was admitted after demand", pending_done(&predicted_key, 5000));
    id<MTLRenderPipelineState> pred_result = pso_pend_take(&predicted_key);
    EXPECT_TRUE("predicted key remains distinct from demanded key", pred_result != nil && queue_index(&demand_key) < 0);

    [dev releaseAll]; EXPECT_TRUE("all fake compiler work has drained", drain_queue(5000));
    g_exec_next = NULL; reset_queue(); reset_pso_cache();
}

// The look-ahead admits every later draw that would wait (upstream PR #1344): with six such draws after the demanded one, the first PSO_PREDICT_BUDGET go to the global queue
// and the rest to pp_bg_queue, none on the submit thread; DM_NVN_PREDICT_NEXT=0 (read once, so a run of its own; =ab by its phase) keeps the old bound of two
static void test_prediction_admits_every_later_draw(void) {
    enum { NP = 6 };
    reset_queue(); reset_pso_cache(); state_reset();
    int off = !sw_on(predict_next_mode()), want = off ? PSO_PREDICT_BUDGET : NP;   // =ab: the phase of frame 0 decides
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:1 + NP nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    [dev releaseThrough:1];   // the demanded draw's own build, on the submit thread
    NvShader *dvs = test_shader("next-demand-vs", MTLFunctionTypeVertex), *dfs = test_shader("next-demand-fs", MTLFunctionTypeFragment);
    NvProg *demand = [NvProg new]; demand->sh[0] = dvs; demand->sh[1] = dfs;
    prog_t dctl = {.magic = MAGIC('P', 'R', 'O', 'G'), .nstage = 2, .serial = 0x7f020000}; serial_put(dctl.serial, demand);
    static prog_t ctl[NP]; pso_key keys[NP]; uint8_t stream[1024] = {0}; size_t used = 0;
    p_draw draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .first = 0, .count = 3, .instances = 1};
    for (int i = 0; i < NP; i++) {
        char vn[32], fn[32]; snprintf(vn, sizeof vn, "next-vs%d", i); snprintf(fn, sizeof fn, "next-fs%d", i);
        NvShader *vs = test_shader(vn, MTLFunctionTypeVertex), *fs = test_shader(fn, MTLFunctionTypeFragment);
        NvProg *pr = [NvProg new]; pr->sh[0] = vs; pr->sh[1] = fs;
        ctl[i] = (prog_t){.magic = MAGIC('P', 'R', 'O', 'G'), .nstage = 2, .serial = 0x7f020001 + (uint64_t)i}; serial_put(ctl[i].serial, pr);
        p_bind_program bind = {&ctl[i], 3}; append_op(stream, &used, OP_BIND_PROGRAM, &bind, sizeof bind); append_op(stream, &used, OP_DRAW, &draw, sizeof draw);
        pso_key_fill(&keys[i], vs, fs, g_pass.cfmt, g_pass.dfmt, g_pass.sfmt, g_pass.samples, 0);
    }
    append_op(stream, &used, OP_END, NULL, 0);
    g_exec_next = stream; g_sub_serial = 7; g_pp_submit_mark = 0; uint64_t admit0 = g_pp_admit;
    id<MTLRenderPipelineState> got = pso_get_(demand);
    EXPECT_TRUE("the demanded draw's pipeline is built on the submit thread", got != nil && [dev callWasOnSubmitter:1]);
    int in = 0; for (int i = 0; i < NP; i++) in += queue_index(&keys[i]) >= 0;
    char what[120]; snprintf(what, sizeof what, "later draws admitted%s", off ? " (DM_NVN_PREDICT_NEXT=0: the bound of two)" : " (each of them)");
    EXPECT_EQ(what, want, in);
    EXPECT_EQ("the look-ahead counts them", want, (int)(g_pp_admit - admit0));
    EXPECT_EQ("no later draw is built on the submit thread", 1, [dev syncCalls]);
    [dev releaseAll];
    int done = 1; for (int i = 0; i < NP; i++) if (queue_index(&keys[i]) >= 0) done &= pending_done(&keys[i], 5000);
    EXPECT_TRUE("the admitted builds complete", done);
    EXPECT_TRUE("all fake compiler work has drained", drain_queue(5000));
    // NX 18's split: the first PSO_PREDICT_BUDGET on the global queue at user-initiated QoS, every further later draw on pp_bg_queue at utility QoS
    int ui = 0, ut = 0; for (int c = 2; c <= 1 + want; c++) { qos_class_t q = [dev qosOfCall:c]; ui += q == QOS_CLASS_USER_INITIATED; ut += q == QOS_CLASS_UTILITY; }
    EXPECT_EQ("look-ahead builds at user-initiated QoS (the global queue)", PSO_PREDICT_BUDGET, ui);
    EXPECT_EQ("look-ahead builds at utility QoS (pp_bg_queue)", want - PSO_PREDICT_BUDGET, ut);
    g_exec_next = NULL; reset_queue(); reset_pso_cache();
}

static void test_prediction_restores_scissor(void) {
    state_reset();
    uint8_t stream[64] = {0}; size_t used = 0;
    p_scissor future = {0, 0, 50, 28};
    append_op(stream, &used, OP_SCISSOR, &future, sizeof future);
    append_op(stream, &used, OP_END, NULL, 0);
    p_scissor original = {13, 17, 111, 119};
    for (int known = 0; known <= 1; known++) {
        R.sc = original; R.has_sc = known; g_exec_next = stream;
        pso_predict_rest();
        EXPECT_EQ("prediction preserves current scissor", 0, memcmp(&R.sc, &original, sizeof original));
        EXPECT_EQ("prediction preserves scissor validity", known, R.has_sc);
    }
    g_exec_next = NULL;
}

// The prediction reads only attachments already made (tex_made): resolving a future one (tex_mtl) could upload it and wait for the GPU, ending the render encoder of the draw
// whose pipeline miss started the prediction, which then bound its pipeline on the ended encoder (upstream 5012821ef: Mario Kart World 1.8.0 crashed at start-up). A pass whose
// attachment is not made yet is skipped, and the prediction goes on at the next pass whose attachments are known
static void test_prediction_only_reads_existing_targets(void) {
    reset_queue(); reset_pso_cache(); state_reset();
    GateCompiler *dev = [[GateCompiler alloc] initBlockingThrough:0 nilCall:0]; g_comp4 = (id<MTL4Compiler>)(id)dev;
    CountingDevice *counting = [CountingDevice new]; id<MTLDevice> dev0 = g_dev; g_dev = (id<MTLDevice>)(id)counting;
    // A shader pair of its own: the shared test pair's base is made by the earlier cases, and a predicted key whose base is made needs no compile here (pso_base_made_d)
    NvProg *program = [NvProg new]; program->sh[0] = test_shader("target-vs", MTLFunctionTypeVertex); program->sh[1] = test_shader("target-fs", MTLFunctionTypeFragment);
    prog_t control = {.magic = MAGIC('P', 'R', 'O', 'G'), .nstage = 2, .serial = 0x7f010003};
    serial_put(control.serial, program);
    tex_t cold = {.magic = MAGIC('T', 'E', 'X', 0), .serial = 0x7f010004,
                  .d = {.target = NVN_TEXTURE_TARGET_2D, .format = NVN_FORMAT_RGBA8, .width = 16, .height = 16, .depth = 1, .levels = 1, .samples = 1}};
    tex_t ready = cold; ready.serial++;
    // For a target without a view, the descriptor supplies the format and sample count a texture would report.
    tex_put(ready.serial, tex_desc(&ready, 0));
    p_set_rt cold_pass = {.n = 1, .color = {&cold}}, ready_pass = {.n = 1, .color = {&ready}};
    p_bind_program bind = {&control, 3};
    p_draw draw = {.prim = NVN_DRAW_PRIMITIVE_TRIANGLES, .count = 3, .instances = 1};
    uint8_t stream[2048] = {0}; size_t used = 0;
    append_op(stream, &used, OP_BIND_PROGRAM, &bind, sizeof bind);
    append_op(stream, &used, OP_SET_RT, &cold_pass, sizeof cold_pass);
    append_op(stream, &used, OP_DRAW, &draw, sizeof draw);
    append_op(stream, &used, OP_SET_RT, &ready_pass, sizeof ready_pass);
    append_op(stream, &used, OP_DRAW, &draw, sizeof draw);
    append_op(stream, &used, OP_END, NULL, 0);

    g_exec_next = stream; pso_predict_rest(); g_exec_next = NULL;
    EXPECT_TRUE("prediction reaches the later pass with a realized target", [dev waitForEntered:1 timeoutMs:5000]);
    EXPECT_TRUE("target prediction drains its compiler work", drain_queue(5000));
    EXPECT_EQ("prediction only compiles for known attachments", 1, [dev entered]);
    EXPECT_EQ("prediction does not allocate future textures", 0, counting->texture_allocations);
    g_dev = dev0; tex_put(ready.serial, nil); serial_del(control.serial);
    reset_queue(); reset_pso_cache();
}

// The prediction runs once per submission, at its first new miss: a draw whose own build is already under way drew in an earlier frame and does not start it (issue #2438)
static void test_prediction_at_first_new_miss(void) {
    g_sub_serial = 100; g_pp_submit_mark = 0;
    EXPECT_EQ("a stand-in draw whose build is under way does not start the prediction", 0, pso_predict_due(0));
    EXPECT_EQ("nor does it use up the submission's prediction", 0, (int)(g_pp_submit_mark == g_sub_serial));
    EXPECT_EQ("the submission's first new miss starts it", 1, pso_predict_due(1));
    EXPECT_EQ("a second new miss in the same submission does not", 0, pso_predict_due(1));
    g_sub_serial++;
    EXPECT_EQ("the next submission's first new miss starts its own", 1, pso_predict_due(1));
    g_sub_serial = 0; g_pp_submit_mark = 0;
}

int main(void) {
    @autoreleasepool {
        setvbuf(stdout, NULL, _IONBF, 0);
        // no archive (none is opened: no device messages), no hybrid stand-ins (no pulling bases): each pipeline is a compile of the fake compiler
        setenv("DM_PSO_ARCHIVE", "off", 1); unsetenv("DM_PSO_BUNDLE"); setenv("DM_PSO_HYBRID", "0", 1);
        test_vs = test_shader("pending-base-vs", MTLFunctionTypeVertex); test_fs = test_shader("pending-base-fs", MTLFunctionTypeFragment);
        test_two_active_exact_take_and_release();
        test_next_draws_pass_the_guess_limit();
        test_next_backlog_keeps_first_two_on_global_queue();
        test_wait_on_running_next_build_lends_qos();
        test_interleaved_prediction_budgets();
        test_full_table_reclaims_done_not_running();
        test_completed_slot_kept_for_waiting_draw();
        test_nil_prediction_falls_back_then_predicts();
        test_prediction_admits_every_later_draw();
        test_prediction_restores_scissor();
        test_prediction_only_reads_existing_targets();
        test_prediction_at_first_new_miss();
        test_inflight_counter_snapshot();
        printf("== %d PSO pending checks, %d failed ==\n", g_checks, g_failed);
        return g_failed != 0;
    }
}
