// Stencil-only views of depth-stencil textures (PR #106): Metal allows an X32_Stencil8 view only of a texture with the format-view usage, and its API validation layer aborts the
// process at the first view of one made without it. Run under MTL_DEBUG_LAYER=1: for both NVN depth-stencil formats (Depth32Float_Stencil8 in Metal), a texture is filled with a
// per-pixel depth and stencil, read through a stencil-mode view, a texture built in stencil mode and the depth-stencil copy draw, and the copy's destination is read back.
// Then the copy draw's other format pairs and regions (copy_kinds, ported from S2Arm c5eb1fd7 and 52452def)
#include "../nvn/nvn_mtl.m"
#include "t_mtl4.h"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s\n", label); } } while (0)
enum { W = 8, H = 8 };
static float depth_at(int x, int y) { return (float)(x + y * W) / (W * H); }
static uint8_t stencil_at(int x, int y) { return (uint8_t)(x * 7 + y * 13 + 1); }
// Each plane of a Depth32Float_Stencil8 texture goes through a buffer with the plane's blit option (classic queue, waited on)
static void plane_io(id<MTLTexture> t, int stencil, int to_tex, void *bytes) {
    NSUInteger bpp = stencil ? 1 : 4;
    id<MTLBuffer> b = [g_dev newBufferWithLength:W * H * bpp options:MTLResourceStorageModeShared];
    if (to_tex) memcpy(b.contents, bytes, W * H * bpp);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb);
    MTLBlitOption o = stencil ? MTLBlitOptionStencilFromDepthStencil : MTLBlitOptionDepthFromDepthStencil;
    if (to_tex) t4_use(cb, b), t4_use(cb, t), [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:W * bpp sourceBytesPerImage:W * H * bpp sourceSize:MTLSizeMake(W, H, 1) toTexture:t destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0, 0, 0) options:o];
    else t4_use(cb, t), t4_use(cb, b), [e copyFromTexture:t sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0) sourceSize:MTLSizeMake(W, H, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:W * bpp destinationBytesPerImage:W * H * bpp options:o];
    t4_end(cb, e); t4_wait(cb);
    if (!to_tex) memcpy(bytes, b.contents, W * H * bpp);
}
// Any plane / slice of any texture through a buffer (classic fixture queue, waited on); opt picks a depth-stencil plane
static void tex_io(id<MTLTexture> t, NSUInteger slice, NSUInteger bpp, MTLBlitOption opt, int to_tex, void *bytes) {
    NSUInteger w = t.width, h = t.height, n = w * h * bpp, is3 = t.textureType == MTLTextureType3D;
    id<MTLBuffer> b = [g_dev newBufferWithLength:n options:MTLResourceStorageModeShared];
    if (to_tex) memcpy(b.contents, bytes, n);
    T4 *cb = t4_begin(); id<MTL4ComputeCommandEncoder> e = t4_copy(cb); t4_use(cb, b); t4_use(cb, t);
    MTLOrigin o = MTLOriginMake(0, 0, is3 ? slice : 0); NSUInteger sl = is3 ? 0 : slice;
    if (to_tex) [e copyFromBuffer:b sourceOffset:0 sourceBytesPerRow:w * bpp sourceBytesPerImage:n sourceSize:MTLSizeMake(w, h, 1) toTexture:t destinationSlice:sl destinationLevel:0 destinationOrigin:o options:opt];
    else [e copyFromTexture:t sourceSlice:sl sourceLevel:0 sourceOrigin:o sourceSize:MTLSizeMake(w, h, 1) toBuffer:b destinationOffset:0 destinationBytesPerRow:w * bpp destinationBytesPerImage:n options:opt];
    t4_end(cb, e); t4_wait(cb);
    if (!to_tex) memcpy(bytes, b.contents, n);
}
static id<MTLTexture> mk(MTLPixelFormat pf, NSUInteger w, NSUInteger h, NSUInteger depth, MTLTextureUsage usage) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:pf width:w height:h mipmapped:NO];
    if (depth > 1) { d.textureType = MTLTextureType3D; d.depth = depth; }
    d.storageMode = MTLStorageModePrivate; d.usage = usage;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); return t;
}
enum { RT = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget };
// Texture → texture copies the draw path takes since S2Arm c5eb1fd7 and 52452def: depth across depth formats, depth into a float colour and back, integer formats of one signedness,
// a destination region past the destination's edge (clipped), a 2D source into a slice of a 3D texture, and a scaled depth copy into a depth texture made without render-target use
static void copy_kinds(void) {
    enum { S = 16, D = 8 };
    NVNcopyRegion sr = {.width=S, .height=S, .depth=1}, dr = {.width=D, .height=D, .depth=1}, r8 = {.width=D, .height=D, .depth=1};
    // ① Depth16Unorm 16x16 halved into Depth32Float 8x8: nearest, destination texel (x, y) reads source texel (2x+1, 2y+1)
    { id<MTLTexture> a = mk(MTLPixelFormatDepth16Unorm, S, S, 1, RT), b = mk(MTLPixelFormatDepth32Float, D, D, 1, RT);
      uint16_t in[S * S]; for (int i = 0; i < S * S; i++) in[i] = (uint16_t)(i * 251); tex_io(a, 0, 2, MTLBlitOptionNone, 1, in);
      mtl_sub_begin(); CHECK(copy_t2t_draw(a, b, 0, 0, 0, 0, &sr, &dr, 1, 0), "Depth16Unorm → Depth32Float scaled is drawn"); mtl_sub_commit(); mtl_drain();
      float out[D * D]; tex_io(b, 0, 4, MTLBlitOptionNone, 0, out); int ok = 1;
      for (int y = 0; y < D; y++) for (int x = 0; x < D; x++) ok &= fabsf(out[x + y * D] - in[(2 * x + 1) + (2 * y + 1) * S] / 65535.f) < 1e-6f;
      CHECK(ok, "every depth value crosses depth formats, nearest"); }
    // ② Depth32Float_Stencil8 → R32Float (depth into the first channel), ③ R32Float → Depth32Float (the first channel into depth), same size
    { id<MTLTexture> a = mk(MTLPixelFormatDepth32Float_Stencil8, D, D, 1, RT), b = mk(MTLPixelFormatR32Float, D, D, 1, RT), c = mk(MTLPixelFormatDepth32Float, D, D, 1, RT);
      float in[D * D]; for (int i = 0; i < D * D; i++) in[i] = (float)i / (D * D) + 1.f / 1024; tex_io(a, 0, 4, MTLBlitOptionDepthFromDepthStencil, 1, in);
      mtl_sub_begin(); CHECK(copy_t2t_draw(a, b, 0, 0, 0, 0, &r8, &r8, 0, 0), "Depth32Float_Stencil8 → R32Float is drawn");
      CHECK(copy_t2t_draw(b, c, 0, 0, 0, 0, &r8, &r8, 0, 0), "R32Float → Depth32Float is drawn"); mtl_sub_commit(); mtl_drain();
      float o1[D * D], o2[D * D]; tex_io(b, 0, 4, MTLBlitOptionNone, 0, o1); tex_io(c, 0, 4, MTLBlitOptionNone, 0, o2);
      CHECK(!memcmp(in, o1, sizeof in), "depth lands in the colour's first channel, exactly");
      CHECK(!memcmp(in, o2, sizeof in), "the colour's first channel lands in depth, exactly"); }
    // ④ R32Uint 16x16 halved into R32Uint (texels read as they are), ⑤ R16Sint → R32Sint (the sign kept), ⑥ R32Uint → R32Float refused (no defined conversion)
    { id<MTLTexture> a = mk(MTLPixelFormatR32Uint, S, S, 1, RT), b = mk(MTLPixelFormatR32Uint, D, D, 1, RT), c = mk(MTLPixelFormatR16Sint, D, D, 1, RT), e = mk(MTLPixelFormatR32Sint, D, D, 1, RT), f = mk(MTLPixelFormatR32Float, D, D, 1, RT);
      uint32_t in[S * S]; for (int i = 0; i < S * S; i++) in[i] = 0x10000001u * (uint32_t)i + 7; tex_io(a, 0, 4, MTLBlitOptionNone, 1, in);
      int16_t si[D * D]; for (int i = 0; i < D * D; i++) si[i] = (int16_t)(i * 997 - 30000); tex_io(c, 0, 2, MTLBlitOptionNone, 1, si);
      mtl_sub_begin(); CHECK(copy_t2t_draw(a, b, 0, 0, 0, 0, &sr, &dr, 1, 0), "R32Uint scaled is drawn"); CHECK(copy_t2t_draw(c, e, 0, 0, 0, 0, &r8, &r8, 0, 0), "R16Sint → R32Sint is drawn");
      CHECK(!copy_t2t_draw(a, f, 0, 0, 0, 0, &sr, &dr, 0, 0), "R32Uint → R32Float is not drawn"); mtl_sub_commit(); mtl_drain();
      uint32_t o[D * D]; int32_t o2[D * D]; tex_io(b, 0, 4, MTLBlitOptionNone, 0, o); tex_io(e, 0, 4, MTLBlitOptionNone, 0, o2); int ok = 1, ok2 = 1;
      for (int y = 0; y < D; y++) for (int x = 0; x < D; x++) { ok &= o[x + y * D] == in[(2 * x + 1) + (2 * y + 1) * S]; ok2 &= o2[x + y * D] == si[x + y * D]; }
      CHECK(ok, "integer texels are copied unfiltered, every bit"); CHECK(ok2, "a signed integer keeps its sign across widths"); }
    // ⑦ A destination region at (4, 4) of 8x8 in an 8x8 texture: its top-left 4x4 is drawn from source (0..3, 0..3), the rest of the texture keeps its content
    { id<MTLTexture> a = mk(MTLPixelFormatR32Float, D, D, 1, RT), b = mk(MTLPixelFormatR32Float, D, D, 1, RT);
      float in[D * D], old[D * D]; for (int i = 0; i < D * D; i++) { in[i] = (float)i; old[i] = -1; } tex_io(a, 0, 4, MTLBlitOptionNone, 1, in); tex_io(b, 0, 4, MTLBlitOptionNone, 1, old);
      NVNcopyRegion over = {.xoffset=4, .yoffset=4, .width=D, .height=D, .depth=1};
      mtl_sub_begin(); CHECK(copy_t2t_draw(a, b, 0, 0, 0, 0, &r8, &over, 0, 0), "a destination region past the texture's edge is drawn"); mtl_sub_commit(); mtl_drain();
      float o[D * D]; tex_io(b, 0, 4, MTLBlitOptionNone, 0, o); int ok = 1;
      for (int y = 0; y < D; y++) for (int x = 0; x < D; x++) ok &= o[x + y * D] == (x >= 4 && y >= 4 ? in[(x - 4) + (y - 4) * D] : -1);
      CHECK(ok, "the part inside the texture takes the source, mapped as the whole regions are; outside it nothing changes"); }
    // ⑧ A 2D source into slice 2 of a 3D texture 8x8x4: that slice takes it, slices 0, 1 and 3 keep theirs
    { id<MTLTexture> a = mk(MTLPixelFormatRGBA8Unorm, D, D, 1, RT), b = mk(MTLPixelFormatRGBA8Unorm, D, D, 4, RT);
      uint32_t in[D * D], old[D * D]; for (int i = 0; i < D * D; i++) { in[i] = 0xff000000u | (uint32_t)i * 0x010203u; old[i] = 0x11223344; } tex_io(a, 0, 4, MTLBlitOptionNone, 1, in);
      for (int z = 0; z < 4; z++) tex_io(b, z, 4, MTLBlitOptionNone, 1, old);
      NVNcopyRegion dz = {.zoffset=2, .width=D, .height=D, .depth=1};
      mtl_sub_begin(); CHECK(copy_t2t_draw(a, b, 0, 0, 0, 0, &r8, &dz, 0, 0), "a 2D source into a slice of a 3D texture is drawn"); mtl_sub_commit(); mtl_drain();
      int ok = 1; for (int z = 0; z < 4; z++) { uint32_t o[D * D]; tex_io(b, z, 4, MTLBlitOptionNone, 0, o); ok &= !memcmp(o, z == 2 ? in : old, sizeof o); }
      CHECK(ok, "slice 2 takes the source, the other slices keep their content"); }
    // ⑨ copy_t2t_enc: a scaled Depth32Float copy into a Depth32Float texture made without render-target use (a packaged one) gets the use first and is drawn (S2Arm 52452def)
    { tex_t ts = {.magic=MAGIC('T','E','X',0), .serial=99601}, td = ts; td.serial = 99602; td.off = 0x200000;
      ts.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=NVN_FORMAT_DEPTH32F, .width=S, .height=S, .depth=1, .levels=1, .samples=1}; nvn_tex_layout(&ts.d, &ts.L);
      td.d = ts.d; td.d.width = td.d.height = D; nvn_tex_layout(&td.d, &td.L);
      mtl_tex_init(&ts); mtl_tex_init(&td);
      id<MTLTexture> a = tex_mtl(&ts), b = mk(MTLPixelFormatDepth32Float, D, D, 1, MTLTextureUsageShaderRead); tex_put(td.serial, b);
      mtl_drain();
      float in[S * S], old[D * D]; for (int i = 0; i < S * S; i++) in[i] = (float)i / (S * S); for (int i = 0; i < D * D; i++) old[i] = 1;
      tex_io(a, 0, 4, MTLBlitOptionNone, 1, in); tex_io(b, 0, 4, MTLBlitOptionNone, 1, old);
      CHECK(tex_mtl(&td) == b && !(b.usage & MTLTextureUsageRenderTarget), "the destination is a depth texture without render-target use");
      mtl_sub_begin(); id<MTLTexture> got = copy_t2t_enc(&(p_copy_t2t){.src=&ts, .dst=&td, .sr=sr, .dr=dr}); mtl_sub_commit(); mtl_drain();
      CHECK(got && got != b && (got.usage & MTLTextureUsageRenderTarget) && tex_mtl(&td) == got, "the copy upgrades it to render-target use");
      float o[D * D]; int ok = 1; if (got) tex_io(got, 0, 4, MTLBlitOptionNone, 0, o); else ok = 0;
      for (int y = 0; ok && y < D; y++) for (int x = 0; x < D; x++) ok &= o[x + y * D] == in[(2 * x + 1) + (2 * y + 1) * S];
      CHECK(ok, "the scaled depth reaches it");
      mtl_tex_release(&ts); mtl_tex_release(&td); }
}
int main(void) { @autoreleasepool {
    mtl_init();
    const int formats[] = {NVN_FORMAT_DEPTH24_STENCIL8, NVN_FORMAT_DEPTH32F_STENCIL8};
    for (int i = 0; i < 2; i++) {
        tex_t s = {.magic=MAGIC('T','E','X',0), .serial=99501u + 4 * i};
        s.d = (nvn_texdesc){.target=NVN_TEXTURE_TARGET_2D, .format=formats[i], .width=W, .height=H, .depth=1, .levels=1, .samples=1};
        nvn_tex_layout(&s.d, &s.L);
        tex_t sb = s, d = s; sb.serial++; sb.stencil = 1; d.serial += 2;   // sb: the same storage built in stencil mode; d: the copy's destination
        sb.d.flags |= NVN_TEXTURE_FLAGS_IMAGE;   // usage-only difference, as in Xenoblade Chronicles 3
        d.off = 0x100000;   // a separate destination, not another descriptor of the source storage
        mtl_tex_init(&s); mtl_tex_init(&sb); mtl_tex_init(&d);
        id<MTLTexture> base = tex_mtl(&s), dst = tex_mtl(&d);
        mtl_drain();   // finish production initialization before the fixture writes on its independent classic queue
        CHECK(base && base.pixelFormat == MTLPixelFormatDepth32Float_Stencil8, "the depth-stencil texture is Depth32Float_Stencil8");
        CHECK(base.usage & MTLTextureUsagePixelFormatView, "a depth-stencil texture is made with the format-view usage");
        if (!base || !dst) continue;
        float dz[W * H]; uint8_t st[W * H];
        for (int y = 0; y < H; y++) for (int x = 0; x < W; x++) { dz[x + y * W] = depth_at(x, y); st[x + y * W] = stencil_at(x, y); }
        plane_io(base, 0, 1, dz); plane_io(base, 1, 1, st);

        mtl_sub_begin();
        id<MTLTexture> image = tex_mtl(&sb);
        mtl_sub_commit(); mtl_drain();   // adding IMAGE to a sampling descriptor retains both populated planes
        base = tex_get(s.serial);
        CHECK(image == base, "IMAGE usage and render descriptors share their populated storage");

        // A stencil-mode view, and the texture built in stencil mode, are X32_Stencil8 views of the depth-stencil storage itself (no upgraded copy)
        view_t v = {.set_dsmode=1, .dsmode=NVN_TEXTURE_DEPTH_STENCIL_MODE_STENCIL};
        mtl_reg_tex(800 + 2 * i, &s, &v); mtl_reg_tex(801 + 2 * i, &sb, NULL);
        os_unfair_lock_lock(&g_rmu); id<MTLTexture> sv = tex_by_id(800 + 2 * i), bv = tex_by_id(801 + 2 * i); os_unfair_lock_unlock(&g_rmu);
        CHECK(sv.pixelFormat == MTLPixelFormatX32_Stencil8 && sv.parentTexture == base, "a stencil-mode view reads the stencil of the texture's own storage");
        CHECK(bv.pixelFormat == MTLPixelFormatX32_Stencil8 && bv.parentTexture == base, "a texture built in stencil mode reads the stencil of the same storage");
        CHECK(tex_get(s.serial) == base, "the depth-stencil texture is not replaced");

        // The depth-stencil copy draw reads the source's stencil through its own X32_Stencil8 view and writes it with the depth
        // A registered source can already be a view, with nonzero mip and layer offsets: the copy's own views must name the resident root (upstream 81e22cca1, PR #1696)
        MTLTextureDescriptor *rd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:base.pixelFormat width:2*W height:2*H mipmapped:YES];
        rd.textureType = MTLTextureType2DArray; rd.arrayLength = 2;
        rd.storageMode = MTLStorageModePrivate; rd.usage = MTLTextureUsageShaderRead | MTLTextureUsagePixelFormatView;
        id<MTLTexture> root = [g_dev newTextureWithDescriptor:rd]; res_add(root);
        id<MTLTexture> source_view = [root newTextureViewWithPixelFormat:root.pixelFormat textureType:MTLTextureType2D levels:NSMakeRange(1, 1) slices:NSMakeRange(1, 1)];
        CHECK(source_view && source_view.width == W && source_view.height == H, "the source view selects mip 1, layer 1");
        plane_io(source_view, 0, 1, dz); plane_io(source_view, 1, 1, st);
        mtl_sub_begin();
        NVNcopyRegion r = {.width=W, .height=H, .depth=1};
        CHECK(copy_t2t_draw(source_view, dst, 0, 0, 0, 0, &r, &r, 0, 0), "the depth-stencil copy is drawn");
        mtl_sub_commit(); mtl_drain();
        float dz2[W * H]; uint8_t st2[W * H];
        plane_io(dst, 0, 0, dz2); plane_io(dst, 1, 0, st2);
        CHECK(!memcmp(dz, dz2, sizeof dz), "the copy carries every depth value");
        CHECK(!memcmp(st, st2, sizeof st), "the copy carries every stencil value, read through the stencil-only view");
    }
    copy_kinds();
    printf("stencil views: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
