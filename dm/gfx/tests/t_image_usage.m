// RegisterImage on a COMPRESSIBLE-only render texture: first use adds image usage, keeps the open pass's clear and every mip, and updates sampled aliases.
// Then a dispatch's uint image slot over an RG32F texture without the format-view usage, upgraded before the dispatch (class_view_case).
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
static void read_level(id<MTLTexture> texture, unsigned level, uint16_t *out) {
    NSUInteger n = texture.width >> level;
    id<MTLBuffer> readback = [g_dev newBufferWithLength:n * n * 2 options:MTLResourceStorageModeShared];
    if (!readback) { CHECK(0, "readback buffer allocated"); memset(out, 0, n * n * 2); return; }
    T4 *command = t4_begin(); id<MTL4ComputeCommandEncoder> copy = t4_copy(command);
    t4_use(command, texture), t4_use(command, readback), [copy copyFromTexture:texture sourceSlice:0 sourceLevel:level sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(n,n,1)
                toBuffer:readback destinationOffset:0 destinationBytesPerRow:n * 2 destinationBytesPerImage:n * n * 2];
    t4_end(command, copy); t4_wait(command);
    CHECK(command->status == MTLCommandBufferStatusCompleted, "readback completed");
    memcpy(out, readback.contents, n * n * 2);
}
static void image_case(int explicit_image) { @autoreleasepool {
    tex_t texture = {.magic=MAGIC('T','E','X',0), .serial=99501 + 10 * explicit_image, .off=(uint64_t)explicit_image << 20};
    texture.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_R16F, .flags=NVN_TEXTURE_FLAGS_COMPRESSIBLE,
                            .width=8, .height=8, .depth=1, .levels=2, .samples=1};
    nvn_tex_layout(&texture.d, &texture.L); mtl_tex_init(&texture);
    tex_t alias = texture; alias.serial++; mtl_tex_init(&alias);
    id<MTLTexture> old = tex_mtl(&texture);
    CHECK(old && !(old.usage & MTLTextureUsageShaderWrite), "ordinary render target keeps its original usage");
    CHECK(tex_mtl(&alias) == old, "another serial shares the original backing");
    // Seed the smaller mip before the production render pass clears level 0.
    T4 *seed = t4_begin(); MTLRenderPassDescriptor *rp = [MTLRenderPassDescriptor renderPassDescriptor];
    rp.colorAttachments[0].texture = old; rp.colorAttachments[0].level = 1; rp.colorAttachments[0].loadAction = MTLLoadActionClear;
    rp.colorAttachments[0].storeAction = MTLStoreActionStore; rp.colorAttachments[0].clearColor = MTLClearColorMake(0.75,0,0,1);
    t4_end(seed, t4_pass(seed, rp)); t4_wait(seed);
    CHECK(seed->status == MTLCommandBufferStatusCompleted, "smaller mip seeded");
    mtl_reg_tex(601, &alias, NULL);
    os_unfair_lock_lock(&g_rmu); CHECK(tex_by_id(601) == old, "sampled descriptor caches the old backing"); os_unfair_lock_unlock(&g_rmu);
    mtl_sub_begin(); memset(&R, 0, sizeof R); R.has_rt = 1; R.rt.n = 1; R.rt.color[0] = &texture;
    R.clear_c[0] = 1; R.cc[0] = MTLClearColorMake(0.5,0,0,1);
    CHECK(rp_begin() != nil && g_enc != nil, "production render pass is open before image registration");
    view_t mip = {.set_levels=1, .base_level=1, .nlevels=1};
    if (explicit_image) mtl_reg_image(602, &texture, &mip); else mtl_reg_tex(602, &texture, &mip);
    CHECK(texture.d.flags == NVN_TEXTURE_FLAGS_COMPRESSIBLE, "image registration leaves the guest texture flags alone");
    NvProg *program = [NvProg new]; NvShader *shader = [NvShader new]; program->sh[5] = shader;
    shader->rf.nb = 1; shader->rf.b[0] = (nvn_rbind){.kind=NVN_RB_IMG, .dtt=MTLTextureType2D, .dpf=NVN_DPF_FLOAT, .reg=0};
    S.img[5][0] = 602; image_prepare(program, 0x20);
    os_unfair_lock_lock(&g_rmu); uint64_t read_rid; int read_real;
    id<MTLTexture> read_only = img_binding(602, &shader->rf.b[0], &read_rid, &read_real);
    CHECK(read_real && read_only && !(read_only.usage & MTLTextureUsageShaderWrite), "load-only image accepts a read-only texture");
    CHECK(tex_mtl(&texture) == old && g_enc != nil, "load-only image does not upgrade storage or end the render pass");
    os_unfair_lock_unlock(&g_rmu);
    shader->rf.b[0].rw = 1; program->c_img = 0; image_prepare(program, 0x20);   // c_img: image_prepare caches the program's written image slots; a real program's shaders never change
    CHECK(!g_enc, "image preparation ends the previous render pass before copying it");
    id<MTLTexture> upgraded = tex_mtl(&texture);
    CHECK(upgraded != old && (upgraded.usage & MTLTextureUsageShaderWrite), "explicit image use upgrades only its backing");
    CHECK(tex_mtl(&alias) == upgraded, "sampled alias follows the upgraded backing");
    os_unfair_lock_lock(&g_rmu);
    id<MTLTexture> sampled = tex_by_id(601); uint64_t rid; int real;
    id<MTLTexture> image = img_binding(602, &shader->rf.b[0], &rid, &real);
    CHECK(sampled == upgraded, "cached sampled descriptor follows the replacement");
    CHECK(real && image.width == 4 && image.parentRelativeLevel == 1 && (image.usage & MTLTextureUsageShaderWrite), "image descriptor keeps its mip range and writable backing");
    CHECK(rid == image.gpuResourceID._impl, "image argument names the real view");
    os_unfair_lock_unlock(&g_rmu);
    mtl_sub_commit(); mtl_drain();
    uint16_t pixels[64]; read_level(upgraded, 0, pixels);
    int same = 1; for (int i = 0; i < 64; i++) same &= pixels[i] == 0x3800; CHECK(same, "upgrade preserves the clear from the pass it ended");
    read_level(upgraded, 1, pixels); same = 1; for (int i = 0; i < 16; i++) same &= pixels[i] == 0x3a00; CHECK(same, "upgrade preserves the other mip");
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\nkernel void put(texture2d<float, access::write> t [[texture(0)]]) { t.write(float4(0.25),uint2(1,1)); }\n", nil, &error);
    id<MTLComputePipelineState> pipeline = t4_cps(t4_fn(lib, @"put"), &error);
    CHECK(pipeline != nil, "image writer compiled");
    T4 *write = t4_begin(); id<MTL4ComputeCommandEncoder> encoder = t4_compute(write);
    [encoder setComputePipelineState:t4_keep(write, pipeline)]; t4_tex(write, encoder, T4_CS, image, 0);
    [encoder dispatchThreads:MTLSizeMake(1,1,1) threadsPerThreadgroup:MTLSizeMake(1,1,1)]; t4_end(write, encoder); t4_wait(write);
    CHECK(write->status == MTLCommandBufferStatusCompleted, "image write completed");
    read_level(tex_mtl(&alias), 1, pixels); same = 1; for (int i = 0; i < 16; i++) same &= pixels[i] == (i == 5 ? 0x3400 : 0x3a00);
    CHECK(same, "sampled alias sees the image write and untouched pixels");
} }
// A dispatch's image slot declared uint over an RG32F texture made without the format-view usage (ported from S2Arm 2e9a6ce7): img_fit_prescan upgrades it before the dispatch's
// encoder, so the slot gets the RG32Uint view at once and a kernel's write through it reaches the texture its other names see. Without it the slot was bound as is until the next draw pass
static void class_view_case(void) { @autoreleasepool {
    tex_t texture = {.magic=MAGIC('T','E','X',0), .serial=99701, .off=3 << 20};
    texture.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_RG32F, .flags=NVN_TEXTURE_FLAGS_IMAGE, .width=4, .height=4, .depth=1, .levels=1, .samples=1};
    nvn_tex_layout(&texture.d, &texture.L); mtl_tex_init(&texture);
    tex_t alias = texture; alias.serial++; alias.d.flags = 0; mtl_tex_init(&alias);
    id<MTLTexture> old = tex_mtl(&texture);
    CHECK(old && old.pixelFormat == MTLPixelFormatRG32Float && !(old.usage & MTLTextureUsagePixelFormatView), "the RG32F texture is made without the format-view usage");
    mtl_reg_image(604, &texture, NULL);
    mtl_sub_begin();
    NvShader *shader = [NvShader new];
    shader->rf.nb = 1; shader->rf.b[0] = (nvn_rbind){.kind=NVN_RB_IMG, .dtt=MTLTextureType2D, .dpf=NVN_DPF_UINT, .reg=1, .rw=1};
    S.img[5][1] = 604;
    img_fit_prescan(shader);
    id<MTLTexture> up = tex_mtl(&texture);
    CHECK(up != old && (up.usage & MTLTextureUsagePixelFormatView) && !g_imfit_npend, "the dispatch's prescan upgrades the texture before its encoder");
    CHECK(tex_mtl(&alias) == up, "the other name follows the upgraded texture");
    os_unfair_lock_lock(&g_rmu); uint64_t rid; int real;
    id<MTLTexture> image = img_binding(604, &shader->rf.b[0], &rid, &real);
    os_unfair_lock_unlock(&g_rmu);
    CHECK(real && image.pixelFormat == MTLPixelFormatRG32Uint && image.parentTexture == up, "the slot gets the uint view of the upgraded texture at once");
    mtl_sub_commit(); mtl_drain();
    NSError *error = nil;
    id<MTLLibrary> lib = t4_lib(@"#include <metal_stdlib>\nusing namespace metal;\nkernel void put(texture2d<uint, access::write> t [[texture(0)]], uint2 p [[thread_position_in_grid]]) { t.write(uint4(0x3f800000u + p.x, 0x40000000u + p.y, 0, 0), p); }\n", nil, &error);
    id<MTLComputePipelineState> pipeline = t4_cps(t4_fn(lib, @"put"), &error);
    CHECK(pipeline != nil, "uint image writer compiled");
    T4 *write = t4_begin(); id<MTL4ComputeCommandEncoder> encoder = t4_compute(write);
    [encoder setComputePipelineState:t4_keep(write, pipeline)]; t4_tex(write, encoder, T4_CS, image, 0);
    [encoder dispatchThreads:MTLSizeMake(4,4,1) threadsPerThreadgroup:MTLSizeMake(4,4,1)]; t4_end(write, encoder); t4_wait(write);
    id<MTLBuffer> rb = [g_dev newBufferWithLength:4 * 4 * 8 options:MTLResourceStorageModeShared];
    T4 *rd = t4_begin(); id<MTL4ComputeCommandEncoder> copy = t4_copy(rd); id<MTLTexture> seen = tex_mtl(&alias);
    t4_use(rd, seen), t4_use(rd, rb), [copy copyFromTexture:seen sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(4,4,1) toBuffer:rb destinationOffset:0 destinationBytesPerRow:32 destinationBytesPerImage:128];
    t4_end(rd, copy); t4_wait(rd);
    const uint32_t *w = rb.contents; int ok = 1;
    for (int y = 0; y < 4; y++) for (int x = 0; x < 4; x++) ok &= w[(x + y * 4) * 2] == 0x3f800000u + x && w[(x + y * 4) * 2 + 1] == 0x40000000u + y;
    CHECK(ok, "every word the kernel wrote through the uint view is in the texture the other name sees");
    mtl_tex_release(&texture); mtl_tex_release(&alias);
} }
int main(void) { @autoreleasepool {
    mtl_init(); image_case(0); image_case(1); class_view_case();
    printf("explicit image usage: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
