// The 'other' page-ins by step (DM_NVN_PF_PARTS): off, a mark changes nothing; on, a mark moves the step and the long-frame text lists the steps that took page-ins, the largest first,
// up to six, and resets them
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(label, c) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } } while (0)
int main(void) { @autoreleasepool {
    char t[720];
    pfm(PFM_D_FB);
    CHECK("off: a mark changes nothing", t_pfm == PFM_CMD);
    g_pf_on = 1; mtl_pf_scope(1);
    CHECK("a scope starts in 'other'", t_pf_sec == PF_OTHER);
    pfm(PFM_D_FB); CHECK("on: the mark moves the step", t_pfm == PFM_D_FB);
    int prev = pf_enter(PF_TEX); CHECK("a named part inside a step", t_pf_sec == PF_TEX && t_pfm == PFM_D_FB); pf_leave(prev);
    CHECK("back in 'other', same step", t_pf_sec == PF_OTHER && t_pfm == PFM_D_FB);
    sop_tick(OP_DRAW); CHECK("a command starts at its own step", t_pfm == PFM_CMD);
    mtl_pf_scope(0);
    for (int k = 0; k < PFM_N; k++) atomic_store(&g_pfo[k], 0);
    atomic_store(&g_pfo[PFM_D_FB], 900); atomic_store(&g_pfo[PFM_RT], 40); atomic_store(&g_pfo[PFM_C_FILL], 300);
    for (int k = 0; k < SOP_N; k++) { atomic_store(&g_sop_n[k], 0); atomic_store(&g_sop_ns[k], 0); }
    for (int k = 0; k < PFM_N; k++) atomic_store(&g_pfw[k], 0);
    atomic_store(&g_pfw[PFM_D_RP], 12500000); atomic_store(&g_pfw[PFM_CMD], 400000);
    mtl_sop_text(t, sizeof t);
    CHECK("the steps, largest first", strstr(t, "'other' page-ins by step: draw: feedback snapshots 900, dispatch: buffer fills, uniform updates 300, set_rt 40") != NULL);
    CHECK("waits of 1 ms or more, in ms", strstr(t, "; the replay's own waits by step (wall less its CPU): draw: render pass begin 12.5 ms") && !strstr(t, "the command (before its first step) 0.4"));
    mtl_sop_text(t, sizeof t);
    CHECK("reset after", t[0] == 0);
    {   // a real wait: a step that sleeps is counted as off the CPU
        g_pf_on = 1; mtl_pf_scope(1); pfm(PFM_RT); usleep(20000); pfm(PFM_CMD); mtl_pf_scope(0);
        CHECK("a 20 ms sleep in set_rt is a wait of about 20 ms", atomic_load(&g_pfw[PFM_RT]) >= 15000000 && atomic_load(&g_pfw[PFM_RT]) < 200000000); }
    printf("t_pf_steps: %d checks, %d failed\n", checks, failed);
    if (failed) fprintf(stderr, "text: %s\n", t);
    return failed != 0;
}}
