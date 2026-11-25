// Command list calls nested past EXEC_CALL_MAX (nvn_mtl.m mtl_exec): each call level is a frame of mtl_exec on the replay thread's stack, so a call chain that loops back on
// itself ran into the stack guard. Run on a thread with the replay thread's stack (nq_worker: the default 512 KB): a list that calls itself stops at the cap with one red line
// and every level's caller goes on (all fills land); a chain of distinct lists just below the cap runs whole. Expectations by hand: the fills' words, the level counts
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int fail, count;
#define EXPECT(n,w,v) do { uint64_t a_=(w), b_=(v); count++; \
    printf("%-60s expected %llu → got %llu %s\n",n,(unsigned long long)a_,(unsigned long long)b_,a_==b_?"✓":"✗"); fail+=a_!=b_; } while(0)
static void emit(uint8_t *p, size_t *n, unsigned op, const void *a, size_t len) {
    size_t sz=(8+len+7)&~7ull; op_hdr h={op,(uint32_t)sz}; memcpy(p+*n,&h,8); if(len) memcpy(p+*n+8,a,len); *n+=sz;
}
#define LISTS 64
#define LIST_BYTES 256
static uint8_t *g_lists, *g_dst;   // command lists; the fills' destination (pool memory)
static int g_case;
static void *run(void *unused) {
    (void)unused; @autoreleasepool {
        state_reset(); memset(&R,0,sizeof R); mtl_sub_begin();
        mtl_exec(g_case == 0 ? g_lists : g_lists + LIST_BYTES);
        mtl_wait(mtl_sub_commit(),5000000000ull);
    }
    return NULL;
}
static void run_on_replay_stack(void) {
    pthread_attr_t at; pthread_attr_init(&at); pthread_attr_setstacksize(&at,512u<<10); pthread_t th;
    if(pthread_create(&th,&at,run,NULL)) abort(); pthread_join(th,NULL); pthread_attr_destroy(&at);
}
int main(void) { @autoreleasepool {
    setvbuf(stdout,NULL,_IONBF,0); mtl_init();
    size_t page=(size_t)getpagesize();
    if(posix_memalign((void **)&g_lists,page,LISTS*LIST_BYTES+page)||posix_memalign((void **)&g_dst,page,page)) return 2;
    memset(g_lists,0,LISTS*LIST_BYTES+page); mtl_pool_add(g_dst,page);
    // Case 0: list 0 calls itself, then fills word 0 with 0x5a5a5a5a. Without the cap: unbounded recursion into the stack guard
    { size_t n=0; uint64_t self=(uint64_t)(uintptr_t)g_lists; emit(g_lists,&n,OP_CALL,&self,8);
      p_clear_buf f={(uint64_t)(uintptr_t)g_dst,4,0x5a5a5a5au}; emit(g_lists,&n,OP_CLEAR_BUF,&f,sizeof f); emit(g_lists,&n,OP_END,NULL,0); }
    memset(g_dst,0,page); int red0=g_red_once[174]; g_case=0; run_on_replay_stack();
    EXPECT("self-call: the call past the cap is skipped once (red line)",1,(uint64_t)(g_red_once[174]-red0));
    EXPECT("self-call: the callers go on after the skipped call (fill)",0x5a5a5a5au,((uint32_t *)g_dst)[0]);
    EXPECT("self-call: the call levels are all returned",0,(uint64_t)g_ret_n);
    // Case 1: lists 1..EXEC_CALL_MAX-1 each fill their own word and call the next, the last only fills: 62 nested calls, all followed
    for(int i=1;i<LISTS;i++) { uint8_t *l=g_lists+(size_t)i*LIST_BYTES; size_t n=0;
        p_clear_buf f={(uint64_t)(uintptr_t)(g_dst+4*i),4,0x1000u+(uint32_t)i}; emit(l,&n,OP_CLEAR_BUF,&f,sizeof f);
        if(i+1<LISTS) { uint64_t next=(uint64_t)(uintptr_t)(l+LIST_BYTES); emit(l,&n,OP_CALL,&next,8); }
        emit(l,&n,OP_END,NULL,0); }
    memset(g_dst,0,page); red0=g_red_once[174]; g_case=1; run_on_replay_stack();
    int landed=0; for(int i=1;i<LISTS;i++) landed+=((uint32_t *)g_dst)[i]==0x1000u+(uint32_t)i;
    EXPECT("62 nested calls (below the cap): all 63 fills land",LISTS-1,(uint64_t)landed);
    EXPECT("a chain below the cap: no red line",0,(uint64_t)(g_red_once[174]-red0));
    EXPECT("cap is 64 levels",64,EXEC_CALL_MAX);
    mtl_pool_del(g_dst); mtl_drain();
    printf("call depth: %d checks, %d failed\n",count,fail); return fail!=0;
}}
