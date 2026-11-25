// Buffer textures share one view by storage (nvn_mtl.m tex_mtl_, tex_buffer, tbuf_usage; upstream NXNative 0929dd69e, MIT): texture objects made again over the same range of a
// pool with the same description, as Unreal does every frame (FINAL FANTASY RESONANCE added and removed about 79,000 views every 300 frames on an iPhone), resolve to one view,
// which the residency set holds once; it is made with every usage it can take, so an image object and a plain one share it; another range or format makes its own; an RGBA8 one
// (BGRA8 storage takes read only) is made too. make GAME=<id> t_tbuf_share
#include "../nvn/nvn_mtl.m"
void *front_metal_layer(void) { return NULL; }
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
uint64_t now_ns(void) { return bp_now(); }
static int checks, failed;
#define CHECK(c, label) do { checks++; if (!(c)) { failed++; fprintf(stderr, "FAIL: %s (line %d)\n", label, __LINE__); } else printf("PASS: %s\n", label); } while (0)
enum { POOL = 1 << 20, W = 256 };
static tex_t buffer_texture(pool_t *pool, uint64_t off, uint64_t serial, uint32_t format, uint32_t flags) {
    tex_t t = {.magic = MAGIC('T','E','X',0), .serial = serial, .pool = pool, .mem = pool->mem + off, .off = (int64_t)off};
    t.d = (nvn_texdesc){.target = NVN_TEXTURE_TARGET_BUFFER, .format = format, .flags = flags, .width = W, .height = 1, .depth = 1, .levels = 1, .samples = 1};
    nvn_tex_layout(&t.d, &t.L); mtl_tex_init(&t);
    return t;
}
static unsigned in_set(void) { res_mu_lock(); unsigned n = (unsigned)g_res_objects.count; res_mu_unlock(); return n; }
int main(void) { @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    mtl_init(); mtl_sub_begin();
    uint8_t *mem; if (posix_memalign((void **)&mem, (size_t)getpagesize(), POOL)) abort();
    memset(mem, 0, POOL); mtl_pool_add(mem, POOL);
    pool_t pool = {.magic = MAGIC('P','O','O','L'), .mem = mem, .size = POOL, .flags = NVN_MEMORY_POOL_FLAGS_CPU_UNCACHED | NVN_MEMORY_POOL_FLAGS_GPU_CACHED};
    tex_t a = buffer_texture(&pool, 0x1000, 997001, NVN_FORMAT_R32UI, 0);
    id<MTLTexture> va = tex_mtl(&a);
    CHECK(va && va.textureType == MTLTextureTypeTextureBuffer, "a buffer texture resolves to a texture-buffer view");
    // tbuf_usage asks for the atomic usage too for R32 integer formats; Metal does not keep it on a texture-buffer view (usage 0x13 on an M4 Max), as upstream's view had it
    CHECK(va && (va.usage & MTLTextureUsageShaderWrite) && (va.usage & MTLTextureUsagePixelFormatView), "made with write and format-view usage, whatever its IMAGE flag");
    unsigned n0 = in_set();
    // Unreal's way: a new object over the same range every frame
    int same = 1;
    for (int i = 0; i < 64; i++) { tex_t b = buffer_texture(&pool, 0x1000, 997100 + (uint64_t)i, NVN_FORMAT_R32UI, i & 1 ? NVN_TEXTURE_FLAGS_IMAGE : 0); same &= tex_mtl(&b) == va; mtl_tex_release(&b); }
    CHECK(same, "64 objects made again over the same range, image ones among them, resolve to the same view");
    CHECK(in_set() == n0, "and add nothing to the residency set");
    tex_t c = buffer_texture(&pool, 0x2000, 997200, NVN_FORMAT_R32UI, 0), f = buffer_texture(&pool, 0x1000, 997201, NVN_FORMAT_R32F, 0);
    id<MTLTexture> vc = tex_mtl(&c), vf = tex_mtl(&f);
    CHECK(vc && vc != va && vf && vf != va && vf.pixelFormat == MTLPixelFormatR32Float, "another range or another format makes its own view");
    tex_t g = buffer_texture(&pool, 0x4000, 997202, NVN_FORMAT_BGRA8, 0);
    id<MTLTexture> vg = tex_mtl(&g);
    CHECK(!vg || !(vg.usage & MTLTextureUsageShaderWrite), "a BGRA8 view takes read usage only (Metal makes no writable BGRA8Unorm texture buffer)");
    printf("t_tbuf_share: %d checks, %d failed\n", checks, failed); return failed != 0;
} }
