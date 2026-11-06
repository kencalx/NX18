// Vulkan pipelines compiled while the game goes on (DM_VK_PSO_ASYNC, hle_vk.m pipe_make; the protocol is vk_pending.h, t_vk_pending.c), through the layer on the Mac's GPU:
// 256 pipelines, most with a fragment shader specialized by a constant (each a compile of its own) and a vertex shader specialized by another, created from four threads
// at once, whose create infos are overwritten as soon as each call returns and whose shader modules are destroyed right after; each pipeline then draws into its own 4x4
// cell of a 64x64 target, recorded and submitted at once (so with the switch on the submission waits for the compiles, most of them queued behind the limit), and the
// target is read back. With the switch off (each pipeline compiled on its creating thread, as before) and on, the pixels must be the same bytes and each cell its
// pipeline's colour. A pipeline Metal refuses (a blend that reads a second source the shader does not write) leaves its cell clear the same way in both; each thread also
// destroys a pipeline right after creating it; the built-pipeline count goes up by the same in both; vkDestroyDevice waits for every compile. Then going to the background
// while a submission waits for a compile (gate): the suspend must not wait for it. make GAME=<id> check_t_vk_pso (MTL_DEBUG_LAYER=1 checks Metal's use as well)
#include "../vk/hle_vk.m"
int dm_guest_as_contains(uintptr_t address) { (void)address; return 0; }
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return clock_gettime_nsec_np(CLOCK_UPTIME_RAW); }
void dm_vi_layer_crop(int c[4]) { c[0] = c[1] = c[2] = c[3] = 0; }
int dm_opmode(void) { return 1; }
static _Atomic int checks, fails;   // the creating threads check too
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; fprintf(stderr, "FAIL: " __VA_ARGS__); fputc('\n', stderr); } } while (0)

// The shaders, as vk_shaders.py names them (vk_<key>): a full-screen triangle with and without a specialization constant, a fragment shader whose colour is its constant
// k_id, and one without constants
static const char *SRC =
    "#include <metal_stdlib>\nusing namespace metal;\n"
    "struct V { float4 pos [[position]]; };\n"
    "constant bool k_flip [[function_constant(1)]];\n"
    "constant uint k_id [[function_constant(0)]];\n"
    "vertex V vk_00000000000000a1(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); if (k_flip) o.pos.y = -o.pos.y; return o; }\n"
    "vertex V vk_00000000000000a2(uint vid [[vertex_id]]) { float2 p = float2((vid << 1) & 2, vid & 2); V o; o.pos = float4(p * 2.0 - 1.0, 0.0, 1.0); return o; }\n"
    "fragment float4 vk_00000000000000f1(V in [[stage_in]]) { return float4(float(k_id & 255u), float((k_id >> 8) & 255u), float((k_id * 37u) & 255u), 255.0) / 255.0; }\n"
    "fragment float4 vk_00000000000000f2(V in [[stage_in]]) { return float4(1.0, 0.0, 1.0, 1.0); }\n";
#define N 256        // pipelines, one per 4x4 cell of the 64x64 target
#define THREADS 4
#define BAD 77       // the pipeline Metal refuses
static uint32_t cell_id(int i) { return (uint32_t)i * 7u + 3u; }
static int kind(int i) { return i == BAD || i % 5 == 4 ? 2 : 1; }   // fragment shader: 1 specialized (k_id), 2 without constants
static int plain_vs(int i) { return i % 7 == 6; }                   // the vertex shader without constants: some pipelines compile nothing but their state

static shinfo g_si[4];
static VkShaderModule mod(int k, const char *key, int frag) {
    VkShaderModule m = zalloc(sizeof *m); strlcpy(m->key, key, sizeof m->key);
    memcpy(g_si[k].key, key, 16); g_si[k].frag = frag; m->si = &g_si[k];
    m->fn = [g_lib newFunctionWithName:[NSString stringWithFormat:@"vk_%s", key]];
    return m;
}
static VkShaderModule g_vs1, g_vs2, g_fs1, g_fs2; static VkRenderPass g_rp; static VkPipelineLayout g_pl;

// Everything one create info points at, owned by the caller and overwritten once vkCreateGraphicsPipelines returns
typedef struct {
    VkGraphicsPipelineCreateInfo ci; VkPipelineShaderStageCreateInfo st[2]; VkSpecializationMapEntry fe, ve; VkSpecializationInfo fsi, vsi; uint32_t id; VkBool32 flip;
    VkPipelineVertexInputStateCreateInfo vi; VkPipelineInputAssemblyStateCreateInfo ia; VkPipelineViewportStateCreateInfo vp; VkPipelineRasterizationStateCreateInfo rs;
    VkPipelineMultisampleStateCreateInfo ms; VkPipelineColorBlendAttachmentState ba; VkPipelineColorBlendStateCreateInfo cb; VkDynamicState dyn[2]; VkPipelineDynamicStateCreateInfo dy;
} pci_t;
static void pci_fill(pci_t *p, int i) {
    memset(p, 0, sizeof *p);
    p->id = cell_id(i); p->flip = i & 1;
    p->fe = (VkSpecializationMapEntry){0, 0, 4}; p->fsi = (VkSpecializationInfo){1, &p->fe, 4, &p->id};
    p->ve = (VkSpecializationMapEntry){1, 0, 4}; p->vsi = (VkSpecializationInfo){1, &p->ve, 4, &p->flip};
    p->st[0] = (VkPipelineShaderStageCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_VERTEX_BIT, .module = plain_vs(i) ? g_vs2 : g_vs1,
                                                 .pName = "main", .pSpecializationInfo = plain_vs(i) ? NULL : &p->vsi};
    p->st[1] = (VkPipelineShaderStageCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO, .stage = VK_SHADER_STAGE_FRAGMENT_BIT, .module = kind(i) == 1 ? g_fs1 : g_fs2,
                                                 .pName = "main", .pSpecializationInfo = kind(i) == 1 ? &p->fsi : NULL};
    p->vi.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    p->ia = (VkPipelineInputAssemblyStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO, .topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST};
    p->vp = (VkPipelineViewportStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO, .viewportCount = 1, .scissorCount = 1};
    p->rs = (VkPipelineRasterizationStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO, .polygonMode = VK_POLYGON_MODE_FILL, .cullMode = VK_CULL_MODE_NONE,
                                                     .frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE, .lineWidth = 1};
    p->ms = (VkPipelineMultisampleStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO, .rasterizationSamples = VK_SAMPLE_COUNT_1_BIT};
    p->ba.colorWriteMask = 0xf;
    if (i == BAD) { p->ba.blendEnable = 1; p->ba.srcColorBlendFactor = VK_BLEND_FACTOR_SRC1_COLOR; p->ba.dstColorBlendFactor = VK_BLEND_FACTOR_ZERO; p->ba.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE; }
    p->cb = (VkPipelineColorBlendStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO, .attachmentCount = 1, .pAttachments = &p->ba};
    p->dyn[0] = VK_DYNAMIC_STATE_VIEWPORT; p->dyn[1] = VK_DYNAMIC_STATE_SCISSOR;
    p->dy = (VkPipelineDynamicStateCreateInfo){.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO, .dynamicStateCount = 2, .pDynamicStates = p->dyn};
    p->ci = (VkGraphicsPipelineCreateInfo){.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO, .stageCount = 2, .pStages = p->st, .pVertexInputState = &p->vi, .pInputAssemblyState = &p->ia,
                                           .pViewportState = &p->vp, .pRasterizationState = &p->rs, .pMultisampleState = &p->ms, .pColorBlendState = &p->cb, .pDynamicState = &p->dy,
                                           .layout = g_pl, .renderPass = g_rp};
}
// A creating thread: its share of the pipelines, 16 to a call, and one more it destroys right after creating it
static VkPipeline g_pipe[N];
static void *creator(void *arg) {
    int t = (int)(intptr_t)arg, per = N / THREADS;
    static pci_t pc[THREADS][16]; VkGraphicsPipelineCreateInfo ci[16];
    for (int c = 0; c < per; c += 16) {
        for (int k = 0; k < 16; k++) { pci_fill(&pc[t][k], t * per + c + k); ci[k] = pc[t][k].ci; }
        CHECK(h_vkCreateGraphicsPipelines(&g_device, NULL, 16, ci, NULL, &g_pipe[t * per + c]) == VK_SUCCESS, "pipelines created");
        memset(pc[t], 0xa5, sizeof pc[t]); memset(ci, 0xa5, sizeof ci);   // the caller's again: nothing may read them after the return
    }
    pci_t one; pci_fill(&one, t); VkPipeline p = NULL;
    h_vkCreateGraphicsPipelines(&g_device, NULL, 1, &one.ci, NULL, &p); memset(&one, 0xa5, sizeof one);
    h_vkDestroyPipeline(&g_device, p, NULL);   // destroyed while it compiles (the switch on): its completion handler frees it
    return NULL;
}

static VkImage g_im; static VkFramebuffer g_fb; static VkBuffer g_rb; static VkDeviceMemory g_rm; static VkCommandPool g_cp;
// One run: modules, pipelines from THREADS threads, the modules destroyed, every pipeline drawn into its cell, the target read back into px
static void run(int async, uint8_t *px, uint64_t *built) {
    g_pso_async = async; uint64_t n0 = g_n_pso;
    g_vs1 = mod(0, "00000000000000a1", 0); g_vs2 = mod(1, "00000000000000a2", 0); g_fs1 = mod(2, "00000000000000f1", 1); g_fs2 = mod(3, "00000000000000f2", 1);
    CHECK(g_vs1->fn && g_vs2->fn && g_fs1->fn && g_fs2->fn, "the test library has its functions");
    pthread_t th[THREADS];
    for (int t = 0; t < THREADS; t++) pthread_create(&th[t], NULL, creator, (void *)(intptr_t)t);
    for (int t = 0; t < THREADS; t++) pthread_join(th[t], NULL);
    h_vkDestroyShaderModule(&g_device, g_vs1, NULL); h_vkDestroyShaderModule(&g_device, g_vs2, NULL); h_vkDestroyShaderModule(&g_device, g_fs1, NULL); h_vkDestroyShaderModule(&g_device, g_fs2, NULL);
    VkCommandBuffer cb; VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = g_cp, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    h_vkAllocateCommandBuffers(&g_device, &ai, &cb);
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; h_vkBeginCommandBuffer(cb, &bi);
    VkClearValue cv = {.color = {.float32 = {0, 0, 0, 0}}};
    VkRenderPassBeginInfo rbi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = g_rp, .framebuffer = g_fb, .renderArea = {{0, 0}, {64, 64}}, .clearValueCount = 1, .pClearValues = &cv};
    h_vkCmdBeginRenderPass(cb, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport v = {0, 0, 64, 64, 0, 1}; h_vkCmdSetViewport(cb, 0, 1, &v);
    for (int i = 0; i < N; i++) {
        h_vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, g_pipe[i]);
        VkRect2D r = {{(i % 16) * 4, (i / 16) * 4}, {4, 4}}; h_vkCmdSetScissor(cb, 0, 1, &r);
        h_vkCmdDraw(cb, 3, 1, 0, 0);
    }
    h_vkCmdEndRenderPass(cb);
    VkBufferImageCopy c = {.imageSubresource = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 0, 1}, .imageExtent = {64, 64, 1}};
    h_vkCmdCopyImageToBuffer(cb, g_im, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL, g_rb, 1, &c);
    h_vkEndCommandBuffer(cb);
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; VkFence f; h_vkCreateFence(&g_device, &fci, NULL, &f);
    VkSubmitInfo si = {.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    uint64_t t0 = now_ns();
    CHECK(h_vkQueueSubmit(&g_queue, 1, &si, f) == VK_SUCCESS && h_vkWaitForFences(&g_device, 1, &f, VK_TRUE, 30000000000ull) == VK_SUCCESS, "the draws completed");
    uint64_t t1 = now_ns();
    void *m = NULL; h_vkMapMemory(&g_device, g_rm, 0, VK_WHOLE_SIZE, 0, &m); memcpy(px, m, 64 * 64 * 4);
    vkp_wait_all(&g_pp);   // the destroyed pipelines' compiles
    *built = g_n_pso - n0;
    pthread_mutex_lock(&g_pp.mu); uint64_t nw = g_pp.b.nwait; uint32_t run_max = g_pp.b.peak_run; pthread_mutex_unlock(&g_pp.mu);
    printf("switch %s: %llu pipelines built, submit and wait %.1f ms, %llu compiles the submission waited for, at most %u at Metal's compiler (limit %u)\n", async ? "on" : "off (DM_VK_PSO_ASYNC=0)",
           (unsigned long long)*built, (t1 - t0) / 1e6, (unsigned long long)nw, run_max, g_pp.limit);
    CHECK(async || nw == 0, "with the switch off nothing waits for a compile (%llu)", (unsigned long long)nw);
    CHECK(!async || run_max <= g_pp.limit, "with the switch on at most the limit at the compiler (%u of %u)", run_max, g_pp.limit);
    pipe_report(0);   // the [vk] pipelines line
    for (int i = 0; i < N; i++) { h_vkDestroyPipeline(&g_device, g_pipe[i], NULL); g_pipe[i] = NULL; }
    h_vkDestroyFence(&g_device, f, NULL); h_vkFreeCommandBuffers(&g_device, g_cp, 1, &cb);
}

// Going to the background (iOS sceneDidEnterBackground, a minimized Mac window) while a submission waits for a pipeline's compile: the submission waits before the graphics
// gate (pipe_wait_sub), so dm_gfx_suspend does not wait for the compile; the submission then waits at the closed gate and goes on at resume. The compile is the test's: a
// built pipeline marked as compiling (vkp_begin) until the test ends it as its handler would
static dispatch_semaphore_t g_sub_done, g_susp_done; static VkSubmitInfo g_gsi; static VkFence g_gf;
static void *gate_submit(void *arg) { (void)arg; CHECK(h_vkQueueSubmit(&g_queue, 1, &g_gsi, g_gf) == VK_SUCCESS, "the gate's submission"); dispatch_semaphore_signal(g_sub_done); return NULL; }
static void *gate_suspend(void *arg) { (void)arg; dm_gfx_suspend(1); dispatch_semaphore_signal(g_susp_done); return NULL; }
static int gate(void) {
    g_pso_async = 0;
    g_vs1 = mod(0, "00000000000000a1", 0); g_vs2 = mod(1, "00000000000000a2", 0); g_fs1 = mod(2, "00000000000000f1", 1); g_fs2 = mod(3, "00000000000000f2", 1);
    pci_t pc; pci_fill(&pc, 0); VkPipeline p = NULL;
    CHECK(h_vkCreateGraphicsPipelines(&g_device, NULL, 1, &pc.ci, NULL, &p) == VK_SUCCESS && p && p->pso, "the gate's pipeline built");
    h_vkDestroyShaderModule(&g_device, g_vs1, NULL); h_vkDestroyShaderModule(&g_device, g_vs2, NULL); h_vkDestroyShaderModule(&g_device, g_fs1, NULL); h_vkDestroyShaderModule(&g_device, g_fs2, NULL);
    if (!p || !p->pso) return 0;
    g_pso_async = 1;
    vkp_begin(&g_pp, &p->pend, vkp_clock()); (void)vkp_start(&g_pp, &p->pend, 0);   // compiling, until the test ends it
    static VkCommandBuffer cb; VkCommandBufferAllocateInfo ai = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO, .commandPool = g_cp, .level = VK_COMMAND_BUFFER_LEVEL_PRIMARY, .commandBufferCount = 1};
    h_vkAllocateCommandBuffers(&g_device, &ai, &cb);
    VkCommandBufferBeginInfo bi = {.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO}; h_vkBeginCommandBuffer(cb, &bi);
    VkClearValue cv = {.color = {.float32 = {0, 0, 0, 0}}};
    VkRenderPassBeginInfo rbi = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO, .renderPass = g_rp, .framebuffer = g_fb, .renderArea = {{0, 0}, {64, 64}}, .clearValueCount = 1, .pClearValues = &cv};
    h_vkCmdBeginRenderPass(cb, &rbi, VK_SUBPASS_CONTENTS_INLINE);
    VkViewport v = {0, 0, 64, 64, 0, 1}; h_vkCmdSetViewport(cb, 0, 1, &v); VkRect2D r = {{0, 0}, {4, 4}}; h_vkCmdSetScissor(cb, 0, 1, &r);
    h_vkCmdBindPipeline(cb, VK_PIPELINE_BIND_POINT_GRAPHICS, p); h_vkCmdDraw(cb, 3, 1, 0, 0);
    h_vkCmdEndRenderPass(cb); h_vkEndCommandBuffer(cb);
    VkFenceCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO}; h_vkCreateFence(&g_device, &fci, NULL, &g_gf);
    g_gsi = (VkSubmitInfo){.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO, .commandBufferCount = 1, .pCommandBuffers = &cb};
    g_sub_done = dispatch_semaphore_create(0); g_susp_done = dispatch_semaphore_create(0);
    pthread_t st, ut; pthread_create(&st, NULL, gate_submit, NULL);
    usleep(100000);
    CHECK(dispatch_semaphore_wait(g_sub_done, DISPATCH_TIME_NOW) != 0, "the submission waits for its pipeline's compile");
    uint64_t t0 = now_ns(); pthread_create(&ut, NULL, gate_suspend, NULL);
    int susp = !dispatch_semaphore_wait(g_susp_done, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    CHECK(susp, "going to the background does not wait for the compile (%s)", susp ? "returned" : "still waiting after 5 s");
    printf("gate: dm_gfx_suspend(1) returned after %.1f ms while the submission waited for a compile\n", (now_ns() - t0) / 1e6);
    if (!susp) return 0;   // the threads are left: the test fails
    pthread_join(ut, NULL);
    vkp_finish(&g_pp, &p->pend, 0, vkp_clock()); (void)vkp_end(&g_pp, 1);   // the compile ends, as its handler would
    CHECK(dispatch_semaphore_wait(g_sub_done, dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC)) != 0, "in the background the submission then waits at the closed gate");
    dm_gfx_suspend(0);
    int done = !dispatch_semaphore_wait(g_sub_done, dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC));
    CHECK(done, "and goes on at resume");
    if (!done) return 0;
    pthread_join(st, NULL);
    CHECK(h_vkWaitForFences(&g_device, 1, &g_gf, VK_TRUE, 30000000000ull) == VK_SUCCESS, "its draw completed");
    h_vkDestroyPipeline(&g_device, p, NULL); h_vkDestroyFence(&g_device, g_gf, NULL); h_vkFreeCommandBuffers(&g_device, g_cp, 1, &cb);
    return 1;
}

int main(void) {
    static uint8_t a[64 * 64 * 4], b[64 * 64 * 4]; uint64_t na = 0, nb = 0;
    @autoreleasepool {
        dev_init();
        NSError *err = nil; g_lib = [g_dev newLibraryWithSource:@(SRC) options:nil error:&err];
        if (!g_lib) { fprintf(stderr, "FAIL: the test library: %s\n", err.localizedDescription.UTF8String); return 1; }
        VkDevice dev = &g_device;
        VkImageCreateInfo ici = {.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO, .imageType = VK_IMAGE_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM, .extent = {64, 64, 1}, .mipLevels = 1,
                                 .arrayLayers = 1, .samples = VK_SAMPLE_COUNT_1_BIT, .tiling = VK_IMAGE_TILING_OPTIMAL, .usage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | VK_IMAGE_USAGE_TRANSFER_SRC_BIT};
        CHECK(h_vkCreateImage(dev, &ici, NULL, &g_im) == VK_SUCCESS, "target image");
        VkImageViewCreateInfo vci = {.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO, .image = g_im, .viewType = VK_IMAGE_VIEW_TYPE_2D, .format = VK_FORMAT_R8G8B8A8_UNORM,
                                     .subresourceRange = {VK_IMAGE_ASPECT_COLOR_BIT, 0, 1, 0, 1}};
        VkImageView view; h_vkCreateImageView(dev, &vci, NULL, &view);
        VkAttachmentDescription ad = {0, VK_FORMAT_R8G8B8A8_UNORM, VK_SAMPLE_COUNT_1_BIT, VK_ATTACHMENT_LOAD_OP_CLEAR, VK_ATTACHMENT_STORE_OP_STORE, VK_ATTACHMENT_LOAD_OP_DONT_CARE,
                                      VK_ATTACHMENT_STORE_OP_DONT_CARE, VK_IMAGE_LAYOUT_UNDEFINED, VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL};
        VkAttachmentReference ar = {0, VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL};
        VkSubpassDescription sp = {.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS, .colorAttachmentCount = 1, .pColorAttachments = &ar};
        VkRenderPassCreateInfo rci = {.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO, .attachmentCount = 1, .pAttachments = &ad, .subpassCount = 1, .pSubpasses = &sp};
        h_vkCreateRenderPass(dev, &rci, NULL, &g_rp);
        VkFramebufferCreateInfo fci = {.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO, .renderPass = g_rp, .attachmentCount = 1, .pAttachments = &view, .width = 64, .height = 64, .layers = 1};
        h_vkCreateFramebuffer(dev, &fci, NULL, &g_fb);
        VkPipelineLayoutCreateInfo lci = {.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO}; h_vkCreatePipelineLayout(dev, &lci, NULL, &g_pl);
        VkBufferCreateInfo bci = {.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO, .size = 64 * 64 * 4, .usage = VK_BUFFER_USAGE_TRANSFER_DST_BIT}; h_vkCreateBuffer(dev, &bci, NULL, &g_rb);
        VkMemoryAllocateInfo mai = {.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO, .allocationSize = 64 * 64 * 4, .memoryTypeIndex = 1}; h_vkAllocateMemory(dev, &mai, NULL, &g_rm);
        CHECK(h_vkBindBufferMemory(dev, g_rb, g_rm, 0) == VK_SUCCESS, "read-back buffer");
        VkCommandPoolCreateInfo pci = {.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO}; h_vkCreateCommandPool(dev, &pci, NULL, &g_cp);

        run(0, a, &na);
        run(1, b, &nb);
        CHECK(!memcmp(a, b, sizeof a), "the switch on gives the same pixels as off");
        CHECK(na == nb && na >= N - 1, "the same pipelines built in both (%llu, %llu)", (unsigned long long)na, (unsigned long long)nb);
        int bad = 0;
        for (int i = 0; i < N; i++)
            for (int y = 0; y < 4; y++)
                for (int x = 0; x < 4; x++) {
                    const uint8_t *q = &b[(((i / 16) * 4 + y) * 64 + (i % 16) * 4 + x) * 4]; uint32_t id = cell_id(i);
                    uint8_t want[4] = {(uint8_t)id, (uint8_t)(id >> 8), (uint8_t)(id * 37u), 255}, mag[4] = {255, 0, 255, 255};
                    if (i == BAD) { bad |= q[3] != 0; continue; }
                    CHECK(!memcmp(q, kind(i) == 1 ? want : mag, 4), "cell %d pixel %d,%d: %u %u %u %u", i, x, y, q[0], q[1], q[2], q[3]);
                }
        printf("the pipeline that blends from a second source the shader does not write: %s in both modes\n", bad ? "drawn (Metal took it)" : "refused, its cell left clear");
        if (!gate()) { printf("Vulkan pipelines compiled while the game goes on: %d checks, %d failed (stopped in gate)\n", checks, fails); return 1; }
        h_vkDestroyDevice(dev, NULL);
        CHECK(g_pp.inflight == 0, "vkDestroyDevice waited for every compile");
    }
    printf("Vulkan pipelines compiled while the game goes on: %d checks, %d failed\n", checks, fails);
    return fails != 0;
}
