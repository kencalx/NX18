// The iPhone's touch controls drawn into the frame by the live present (nvn_mtl.m touch_draw, dm/host/touch_draw.h): the picture placed where the front end's canvas puts it
// with black around it, a control blended over it as premultiplied alpha (as Core Animation laid its layer over the game's), nothing drawn for a drawable of another size, for a
// frame that is off or for another atlas, never in a screenshot (the offscreen present), a replaced or released atlas kept until the presents that sampled it have completed, a
// frame that is off placing nothing once a drawable of another size came, and the frame each present drew from. Real Metal 4
// queue, no window
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(name, ok) do { int pass = !!(ok); checks++; failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)

enum { W = 64, H = 32 };
static uint8_t g_out[W * 2 * H * 4];
// The live present (the persistent scaler and the touch controls: g_fx_present) of src into a w x h BGRA8 texture, read back into g_out; its kind
static int present_live(id<MTLTexture> src, int w, int h) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:w height:h mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> out = [g_dev newTextureWithDescriptor:d]; res_add(out); res_commit();
    id<MTL4CommandAllocator> al = [g_dev newCommandAllocator]; id<MTL4CommandBuffer> cb = [g_dev newCommandBuffer]; id<MTLSharedEvent> ev = [g_dev newSharedEvent];
    [cb beginCommandBufferWithAllocator:al]; int kind = present_encode_m4(cb, src, out, NULL, g_present_uv[0], &g_fx_present, &g_aa_present); [cb endCommandBuffer];
    [g_q4 commit:&cb count:1]; [g_q4 signalEvent:ev value:1];
    if (![ev waitUntilSignaledValue:1 timeoutMS:10000]) { printf("the live present did not complete\n"); failed++; }
    [out getBytes:g_out bytesPerRow:w * 4 fromRegion:MTLRegionMake2D(0, 0, w, h) mipmapLevel:0];
    res_remove(out); return kind;
}
static const uint8_t *px(int w, int x, int y) { return g_out + (y * w + x) * 4; }   // B, G, R, A
static int near(const uint8_t *p, int b, int g, int r) { return abs(p[0] - b) <= 2 && abs(p[1] - g) <= 2 && abs(p[2] - r) <= 2; }

int main(void) { @autoreleasepool {
    alarm(60); setvbuf(stdout, NULL, _IONBF, 0);
    setenv("DM_PRESENT_UPSCALE", "off", 1);   // the bilinear pass: the picture's colour is exact
    mtl_init();
    // The game's picture: 16 x 9, green
    MTLTextureDescriptor *sd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm width:16 height:9 mipmapped:NO];
    sd.storageMode = MTLStorageModeShared; sd.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> src = [g_dev newTextureWithDescriptor:sd]; uint8_t green[16 * 9 * 4];
    for (int i = 0; i < 16 * 9; i++) { green[i * 4] = 0; green[i * 4 + 1] = 255; green[i * 4 + 2] = 0; green[i * 4 + 3] = 255; }
    [src replaceRegion:MTLRegionMake2D(0, 0, 16, 9) mipmapLevel:0 withBytes:green bytesPerRow:16 * 4]; res_add(src); res_commit();

    present_live(src, W, H);
    CHECK("no frame from a front end: the picture's own fit (bars left and right of 16:9 in 64 x 32)", near(px(W, 1, 16), 0, 0, 0) && near(px(W, 32, 16), 0, 255, 0));

    // The atlas: 8 x 8, a 4 x 4 control at (2, 2), red at half its alpha (premultiplied: 128 of red at alpha 128)
    uint8_t atlas[8 * 8 * 4] = {0};
    for (int y = 2; y < 6; y++) for (int x = 2; x < 6; x++) { uint8_t *p = atlas + (y * 8 + x) * 4; p[0] = 0; p[1] = 0; p[2] = 128; p[3] = 128; }
    CHECK("the front end's atlas is taken", mtl_present_touch_atlas(atlas, 8, 8, 8 * 4, 4, 1));
    // The canvas: the drawable's 64 x 32; the picture at x 16..47, y 4..21; the control at pixels 10..13 across and down
    touch_frame f = {.canvas_w = W, .canvas_h = H, .on = TOUCH_ON, .atlas = 1, .n = 1, .pic = {16.f / W, 4.f / H, 32.f / W, 18.f / H}};
    f.q[0] = (touch_quad){{10.f / W, 10.f / H, 4.f / W, 4.f / H}, {2 / 8.f, 2 / 8.f, 4 / 8.f, 4 / 8.f}};
    mtl_present_touch(&f);
    present_live(src, W, H);
    CHECK("the picture where the canvas puts it", near(px(W, 16, 4), 0, 255, 0) && near(px(W, 47, 21), 0, 255, 0));
    CHECK("black around it (above, left, below, right)", near(px(W, 30, 2), 0, 0, 0) && near(px(W, 8, 25), 0, 0, 0) && near(px(W, 30, 23), 0, 0, 0) && near(px(W, 50, 10), 0, 0, 0));
    CHECK("the control over the bar: its own colour", near(px(W, 11, 11), 0, 0, 128));
    CHECK("the control's pixels and no more", near(px(W, 9, 11), 0, 0, 0) && near(px(W, 14, 11), 0, 0, 0) && near(px(W, 13, 13), 0, 0, 128));
    CHECK("the atlas is in use, generation 1", g_touch_tex && g_touch_gen == 1);

    // Over the picture: premultiplied alpha over green
    f.q[0].dst[0] = 20.f / W;
    mtl_present_touch(&f);
    present_live(src, W, H);
    const uint8_t *o = px(W, 21, 11);
    CHECK("the control over the picture: premultiplied over (red 128, green 255 x (1 - 128/255))", near(o, 0, 127, 128));
    CHECK("the picture beside it untouched", near(px(W, 25, 11), 0, 255, 0));

    // A drawable of another size (made before the layout the frame is for): the picture's own fit, no control
    present_live(src, W * 2, H);
    CHECK("another drawable size: no control, the picture's own fit", near(px(W * 2, 41, 11), 0, 255, 0) && near(px(W * 2, 2, 11), 0, 0, 0));

    // The front end leaving: the frame off keeps the picture's place, draws nothing over it
    f.on = TOUCH_OFF; mtl_present_touch(&f);
    present_live(src, W, H);
    CHECK("a frame that is off: the picture where the canvas puts it, no control", near(px(W, 21, 11), 0, 255, 0) && near(px(W, 30, 2), 0, 0, 0));
    CHECK("nothing drawn: no answer to the front end", g_touch_drew == 0);
    // Then the game view leaves the canvas (a drawable of another size), and a later layout's drawable happens to have the canvas's pixels (Picture Stretch with
    // DM_DRAWABLE_NATIVE): the frame that is off places nothing there any more, the present's own fit does
    present_live(src, W * 2, H);
    present_live(src, W, H);
    CHECK("an off frame after a drawable of another size: the picture's own fit, not the old canvas's place", near(px(W, 8, 25), 0, 255, 0) && near(px(W, 1, 16), 0, 0, 0));
    // A frame placing the picture while the front end makes the controls for a new canvas: drawables from before do not end it, and no control is drawn
    f.on = TOUCH_PLACE; mtl_present_touch(&f);
    present_live(src, W * 2, H); present_live(src, W, H);
    CHECK("placing: the picture where the canvas puts it, no control, after a drawable of another size too", near(px(W, 21, 11), 0, 255, 0) && near(px(W, 8, 25), 0, 0, 0) && g_touch_drew == 0);
    f.on = TOUCH_ON;
    uint32_t seq = mtl_present_touch(&f);
    present_live(src, W, H);
    CHECK("a present that drew the controls names the frame it drew them from (present_now's completion hands it to the front end)", g_touch_drew == seq && seq);
    CHECK("and the time since the last live present is short", mtl_present_touch_idle_ns() < 5000000000ull);

    // A frame for an atlas the present has not taken: nothing drawn over the picture that present
    f.atlas = 2; mtl_present_touch(&f);
    present_live(src, W, H);
    CHECK("a frame for another atlas: no control", near(px(W, 21, 11), 0, 255, 0));

    // A new atlas (generation 2, the control blue): the one it replaced stays resident until the present that took the new one completes (present_now's feedback)
    for (int y = 2; y < 6; y++) for (int x = 2; x < 6; x++) { uint8_t *p = atlas + (y * 8 + x) * 4; p[0] = 255; p[1] = 0; p[2] = 0; p[3] = 255; }
    id<MTLTexture> first = g_touch_tex;
    CHECK("the second atlas is taken", mtl_present_touch_atlas(atlas, 8, 8, 8 * 4, 4, 2));
    present_live(src, W, H);
    CHECK("the frame for atlas 2 draws from it", near(px(W, 21, 11), 255, 0, 0) && g_touch_gen == 2);
    int kept = 0; for (int i = 0; i < 4; i++) kept += g_touch_old[i].tex == first;
    CHECK("the first atlas is kept while that present may be in flight", kept == 1);
    atomic_store(&g_touch_done, g_touch_seq);   // as present_now's feedback reports once it completed
    present_live(src, W, H);
    kept = 0; for (int i = 0; i < 4; i++) kept += g_touch_old[i].tex != nil;
    CHECK("then it is let go", kept == 0);

    // Drawables the frame that is on does not fit, many in a row (the drawable changed size without a layout of the root): counted for the front end (touch_unfit_step)
    for (int i = 0; i < TOUCH_UNFIT; i++) present_live(src, W * 2, H);
    CHECK("the presents in a row that the frame does not fit are counted", g_touch_unfit == TOUCH_UNFIT);
    present_live(src, W, H);
    CHECK("a fitting one ends the run", g_touch_unfit == 0);

    // A grey and alpha atlas (two bytes a pixel: the controls' whites and blacks): grey 200 at alpha 200 (premultiplied white at 78 %) over green
    uint8_t rg[8 * 8 * 2] = {0};
    for (int y = 2; y < 6; y++) for (int x = 2; x < 6; x++) { rg[(y * 8 + x) * 2] = 200; rg[(y * 8 + x) * 2 + 1] = 200; }
    CHECK("a grey and alpha atlas is taken", mtl_present_touch_atlas(rg, 8, 8, 8 * 2, 2, 3) && (f.atlas = 3));
    mtl_present_touch(&f);
    present_live(src, W, H);
    CHECK("it is drawn as grey over the picture (200 + 255 x (1 - 200/255) of green)", g_touch_tex.pixelFormat == MTLPixelFormatRG8Unorm && near(px(W, 21, 11), 200, 255, 200));
    CHECK("and over the bar as its own grey", (f.q[0].dst[0] = 10.f / W, mtl_present_touch(&f), present_live(src, W, H), near(px(W, 11, 11), 200, 200, 200)));

    // The front end stops drawing the controls (a controller in use): the atlas is let go, out of the residency set once the presents that sampled it completed
    id<MTLTexture> last = g_touch_tex;
    f.on = TOUCH_OFF; mtl_present_touch(&f); mtl_present_touch_release();
    present_live(src, W, H);
    kept = 0; for (int i = 0; i < 4; i++) kept += g_touch_old[i].tex == last;
    CHECK("released: no atlas in use, the last one kept while the present that sampled it may be in flight", !g_touch_tex && !g_touch_gen && kept == 1);
    atomic_store(&g_touch_done, g_touch_seq);
    present_live(src, W, H);
    kept = 0; for (int i = 0; i < 4; i++) kept += g_touch_old[i].tex != nil;
    CHECK("then it is let go", kept == 0 && !g_touch_tex);
    CHECK("a new atlas after a release is taken", mtl_present_touch_atlas(rg, 8, 8, 8 * 2, 2, 4) && (f.atlas = 4, f.on = TOUCH_ON, mtl_present_touch(&f), present_live(src, W, H), g_touch_gen == 4 && near(px(W, 11, 11), 200, 200, 200)));

    // A screenshot (the offscreen present) shows the game's picture alone
    MTLTextureDescriptor *od = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:W height:H mipmapped:NO];
    od.storageMode = MTLStorageModeShared; od.usage = MTLTextureUsageRenderTarget;
    id<MTLTexture> shot = [g_dev newTextureWithDescriptor:od];
    CHECK("the offscreen present completes", present_offscreen_wait(src, NULL, shot) != PRESENT_FAILED);
    [shot getBytes:g_out bytesPerRow:W * 4 fromRegion:MTLRegionMake2D(0, 0, W, H) mipmapLevel:0 ];
    CHECK("a screenshot: no control, the picture's own fit", near(px(W, 21, 11), 0, 255, 0) && near(px(W, 11, 11), 0, 255, 0) && near(px(W, 1, 16), 0, 0, 0));
    CHECK("the controls' pipelines were made", g_touch_pso[0] && g_touch_pso[1] && !g_touch_failed);

    printf("t_present_touch: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
