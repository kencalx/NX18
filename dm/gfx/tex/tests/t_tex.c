// Block-linear deswizzle unit tests (seconds). A round trip; B hand-calculated addresses; E hand-built 3D; R / T region writes and sparse tiles against the per-run loops they replaced.
// Usage: t_tex
#include "../nvn_deswizzle.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int checks, fails;
#define CHECK(c, ...) do { checks++; if (!(c)) { fails++; printf("  ✗ "); printf(__VA_ARGS__); printf("\n"); } } while (0)
static uint32_t mipd(uint32_t s, unsigned l) { s >>= l; return s ? s : 1; }
static uint64_t rng = 0x9E3779B97F4A7C15ull;
static uint8_t rnd(void) { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17; return (uint8_t)rng; }

// Linear size of this level (computed independently on the test side: width-in-blocks bytes, block rows, slices)
static void dims(const nvn_texdesc *d, unsigned l, uint32_t *rb, uint32_t *rows, uint32_t *sl) {
    int bw, bh, bpb = nvn_fmt_bpb(d->format, &bw, &bh);
    *rb = (mipd(d->width, l) + bw - 1) / bw * bpb; *rows = (mipd(d->height, l) + bh - 1) / bh;
    *sl = d->target == 2 ? mipd(d->depth, l) : 1;
}

// ---------- A round trip: first write different random data into every level / layer, then decode them all and compare (overlap between levels or between layers, or out-of-bounds, all fail) ----------
static void roundtrip(const char *tag, int target, int fmt, uint32_t w, uint32_t h, uint32_t depth, uint32_t levels) {
    nvn_texdesc d = {target, fmt, 0, 0, w, h, depth, levels, 0};
    nvn_texlayout L; nvn_tex_layout(&d, &L);
    size_t guard = 4096; uint8_t *st = malloc(L.size + guard); memset(st, 0, L.size); memset(st + L.size, 0xAB, guard);
    uint8_t *ref[64][16] = {{0}}; uint64_t bytes = 0;
    for (unsigned y = 0; y < L.layers; y++) for (unsigned l = 0; l < levels; l++) {
        uint32_t rb, rows, sl; dims(&d, l, &rb, &rows, &sl);
        size_t n = (size_t)rb * rows * sl; ref[y][l] = malloc(n); for (size_t i = 0; i < n; i++) ref[y][l][i] = rnd();
        CHECK(!nvn_swizzle(&d, l, y, ref[y][l], rb, st), "%s write failed layer %u level %u", tag, y, l);
    }
    int guard_ok = 1; for (size_t i = 0; i < guard; i++) guard_ok &= st[L.size + i] == 0xAB;
    CHECK(guard_ok, "%s wrote past the end of storage (out of bounds)", tag);
    int ok = 1;
    for (unsigned y = 0; y < L.layers; y++) for (unsigned l = 0; l < levels; l++) {
        uint32_t rb, rows, sl; dims(&d, l, &rb, &rows, &sl);
        size_t n = (size_t)rb * rows * sl; uint8_t *out = malloc(n);
        CHECK(!nvn_deswizzle(&d, l, y, st, out, rb), "%s decode failed", tag);
        if (memcmp(out, ref[y][l], n)) { ok = 0; printf("  ✗ %s layer %u level %u round trip differs\n", tag, y, l); }
        bytes += n; free(out); free(ref[y][l]);
    }
    checks++; if (!ok) fails++;
    printf("  A %-34s layers %u × levels %u, round trip %llu bytes %s\n", tag, L.layers, levels, (unsigned long long)bytes, ok ? "identical" : "differ");
    free(st);
}

// Compare both copy directions against byte addresses, independently of move()'s segment arithmetic.
// Comparing all storage bytes and padded rows also checks that tails leave unrelated data untouched.
static void differential(const nvn_texdesc *d, unsigned level, unsigned layer) {
    uint32_t rb, rows, slices, bpb; uint64_t base; unsigned th, td;
    int rc = nvn_deswizzle_geom(d, level, layer, &rb, &rows, &slices, &base, &th, &td, &bpb);
    CHECK(!rc, "D geometry failed"); if (rc) return;
    nvn_texlayout L; nvn_tex_layout(d, &L);
    size_t pitch = rb + 1 + (rnd() & 31), nlin = pitch * rows * slices, nst = L.size + 32;
    uint8_t *storage = malloc(nst), *expected = malloc(nst), *linear = malloc(nlin + 32), *out = malloc(nlin + 32);
    for (size_t i = 0; i < nst; i++) storage[i] = rnd();
    memset(linear, 0xAB, nlin + 32); memset(out, 0xAB, nlin + 32);
    uint32_t lb = nvn_tex_level_gobs(d, level) * 64;
    if (lb < rb) lb = rb;
    for (uint32_t z = 0; z < slices; z++) for (uint32_t y = 0; y < rows; y++) for (uint32_t x = 0; x < rb; x++)
        linear[((size_t)z * rows + y) * pitch + x] = storage[base + nvn_bl_offset(x, y, z, lb, rows, th, td)];
    CHECK(!nvn_deswizzle(d, level, layer, storage, out, pitch) && !memcmp(linear, out, nlin + 32),
          "D read differs target %d format %#x flags %#x mip %u layer %u", d->target, d->format, d->flags, level, layer);
    for (size_t i = 0; i < nlin; i++) linear[i] = rnd();
    memcpy(expected, storage, nst);
    for (uint32_t z = 0; z < slices; z++) for (uint32_t y = 0; y < rows; y++) for (uint32_t x = 0; x < rb; x++)
        expected[base + nvn_bl_offset(x, y, z, lb, rows, th, td)] = linear[((size_t)z * rows + y) * pitch + x];
    CHECK(!nvn_swizzle(d, level, layer, linear, pitch, storage) && !memcmp(storage, expected, nst),
          "D write differs target %d format %#x flags %#x mip %u layer %u", d->target, d->format, d->flags, level, layer);
    CHECK(nvn_swizzle(d, level, layer, linear, rb - 1, storage) == -1 && !memcmp(storage, expected, nst),
          "D short source pitch accepted");
    CHECK(nvn_deswizzle(d, level, layer, storage, out, rb - 1) == -1,
          "D short destination pitch accepted");
    free(storage); free(expected); free(linear); free(out);
}

static void differential_shapes(void) {
    static const int formats[] = {0x01, 0x0D, 0x19, 0x1D, 0x22, 0x25, 0x29, 0x2E, 0x42, 0x44, 0x82, 0x85};
    static const int targets[] = {0, 1, 2, 3, 4, 7, 8, 9};
    static const uint32_t widths[] = {1, 3, 7, 15, 16, 17, 31, 32, 33, 63, 64, 65, 127, 129};
    unsigned cases = 0;
    for (unsigned i = 0; i < 256; i++) {
        nvn_texdesc d = {0};
        d.target = targets[i % 8]; d.format = formats[(i / 8) % 12];
        d.width = widths[rnd() % 14]; d.height = 1 + rnd() % 65; d.depth = 1 + rnd() % 9; d.levels = 4;
        if (d.target == 3) d.height = 3;
        if (d.target == 9) d.depth = 12;
        if ((i / 8) & 1) d.pkg_block_h = 1 + (rnd() % 4) + (d.target == 2 ? (rnd() % 3) * 16 : 0);
        if ((i / 16) & 1) d.flags = 0x20;
        nvn_texlayout L; nvn_tex_layout(&d, &L);
        for (unsigned l = 0; l < d.levels; l++) {
            differential(&d, l, L.layers - 1); cases++;
        }
    }
    // Sparse levels wide enough for padded GOB columns, followed by their mip tails.
    nvn_texdesc sparse = {1, 0x7D, 0x20, 0, 1024, 1024, 1, 5, 0, 0};
    for (unsigned l = 0; l < sparse.levels; l++) { differential(&sparse, l, 0); cases++; }
    printf("  D %u layouts: both directions equal byte-address oracle, including pitch padding and tails\n", cases);
}

// ---------- R / T hoisted runs (DM_BL_HOIST): nvn_bl_write_region (hle_nvn.c write_region_bl) and nvn_deswizzle_tile against the loops they replaced, one nvn_bl_offset per 16-byte run,
// kept here as the reference. Each case runs both on two copies of one random buffer and compares all of it: the bytes around the region and the canaries past the end too ----------
static void ref_write_region(uint8_t *bl, uint32_t x0, uint32_t y0, size_t wb, size_t hb, const uint8_t *src, size_t row, uint32_t lb, uint32_t rows, unsigned th, unsigned td) {
    for (size_t y = 0; y < hb; y++)
        for (size_t x = 0; x < wb;) {
            uint32_t bx = x0 + (uint32_t)x; size_t n = 16 - bx % 16; if (n > wb - x) n = wb - x;
            memcpy(bl + nvn_bl_offset(bx, y0 + (uint32_t)y, 0, lb, rows, th, td), src + y * row + x, n); x += n;
        }
}
static int ref_tile(const nvn_texdesc *d, unsigned level, uint32_t tx, uint32_t ty, const void *tile, void *dst, size_t pitch, uint32_t *wb, uint32_t *nrows) {
    uint32_t row_bytes, rows, slices, bpb; uint64_t base; unsigned th, td;
    *wb = *nrows = 0;
    if (nvn_deswizzle_geom(d, level, 0, &row_bytes, &rows, &slices, &base, &th, &td, &bpb) || td || slices != 1 || th > 7) return -1;
    uint32_t trb = (128u >> th) * 64, trows = 8u << th, x0 = tx * trb, y0 = ty * trows;
    if (x0 >= row_bytes || y0 >= rows) return 0;
    uint32_t w = row_bytes - x0 < trb ? row_bytes - x0 : trb, h = rows - y0 < trows ? rows - y0 : trows;
    if (pitch < w) return -1;
    const uint8_t *s = tile; uint8_t *o = dst;
    for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x += 16) memcpy(o + (size_t)y * pitch + x, s + nvn_bl_offset(x, y, 0, trb, trows, th, 0), w - x < 16 ? w - x : 16);
    *wb = w; *nrows = h;
    return 0;
}
static void fill(uint8_t *b, size_t n) { for (size_t i = 0; i < n; i += 8) { rnd(); memcpy(b + i, &rng, n - i < 8 ? n - i : 8); } }   // random bytes, 8 at a time
static uint8_t *rnd_buf(size_t n) { uint8_t *b = malloc(n); fill(b, n); return b; }
static size_t bl_bytes(uint32_t lb, uint32_t rows, unsigned th, unsigned td) { return (size_t)((lb + 63) / 64) * ((rows + (8u << th) - 1) >> (3 + th)) * (512u << (th + td)); }
static uint8_t *g_src; enum { SRC_N = 1 << 20 };   // the source rows: a random 1 MB, read from a random place each case
static unsigned rcases, rdiff, rpadded;
// One region written both ways into a and b (n bytes each, equal before): returns whether they are equal after
static int region_same(uint8_t *a, uint8_t *b, size_t n, uint32_t x0, uint32_t y0, size_t wb, size_t hb, size_t pitch, uint32_t lb, uint32_t rows, unsigned th, unsigned td) {
    const uint8_t *src = g_src + (hb ? rnd() * 61u % (SRC_N - (hb - 1) * pitch - wb + 1) : 0);
    ref_write_region(a, x0, y0, wb, hb, src, pitch, lb, rows, th, td); nvn_bl_write_region(b, x0, y0, wb, hb, src, pitch, lb, rows, th, td);
    rcases++; if (!memcmp(a, b, n)) return 1;
    if (++rdiff <= 8) printf("  ✗ R x0 %u y0 %u %zu×%zu bytes pitch %zu row %u rows %u block %u/%u order %d hoist %d: storage differs\n", x0, y0, wb, hb, pitch, lb, rows, th, td, nvn_gob_switch2, nvn_bl_hoist);
    memcpy(b, a, n); return 0;
}
static void regions(void) {
    g_src = rnd_buf(SRC_N);
    // Every x0 and width of a 136-byte row (2 GOB columns and a part, laid out padded to 3, as a sparse texture's tiled levels are), for blocks 1-32 GOBs high, both GOB orders, a random
    // block row of 1-3 rows each: first runs from every x0 % 16, every width's last run, whole pieces across GOB and block columns
    unsigned before = rcases, d0 = rdiff;
    for (int order = 0; order < 2; order++) for (unsigned th = 0; th <= 5; th++) {
        nvn_gob_switch2 = order; nvn_bl_hoist = 1;
        uint32_t R = 136, lb = 192, rows = 8u << th; size_t n = bl_bytes(lb, rows, th, 0) + 64;
        uint8_t *a = rnd_buf(n), *b = malloc(n); memcpy(b, a, n);
        for (uint32_t x0 = 0; x0 < R; x0++) for (size_t wb = 0; wb <= R - x0; wb++) {
            size_t hb = 1 + rnd() % 3; uint32_t y0 = rnd() % (rows - hb + 1);
            region_same(a, b, n, x0, y0, wb, hb, wb + rnd() % 40, lb, rows, th, 0);
        }
        free(a); free(b);
    }
    CHECK(rdiff == d0, "R every x0 and width: %u of %u region writes differ", rdiff - d0, rcases - before);
    printf("  R every x0 and width of a 136-byte row, blocks 1-32 GOBs high, both GOB orders: %u region writes, %u differ\n", rcases - before, rdiff - d0);
    // Random shapes, both paths of nvn_bl_write_region (hoisted, and DM_BL_HOIST=0's per-run loop): rows of 1-700 bytes, padded or not, blocks 1-128 GOBs high and 1-4 deep (a 2D
    // array's levels are 1 deep; the block's size still takes the depth), any region in the level; then blocks 256 to 2^15 GOBs high over a narrow level (a packaged layout's nibble reaches 15)
    before = rcases; d0 = rdiff;
    for (unsigned i = 0; i < 2016; i++) {
        nvn_gob_switch2 = i & 1; nvn_bl_hoist = (i >> 1) & 1; int wide = i < 2000;
        unsigned th = wide ? rnd() % 8 : 8 + (i - 2000) / 2, td = wide && rnd() % 4 == 0 ? 1 + rnd() % 2 : 0;
        uint32_t R = wide ? 1 + (rnd() | rnd() << 8) % 700 : 1 + rnd() % 64, lb = rnd() & 1 || !wide ? R : (R + 63) / 64 * 64 + 64 * (rnd() % 3);
        uint32_t rows = 1 + (rnd() | rnd() << 8) % (wide ? 300 : 40); size_t n = bl_bytes(lb, rows, th, td) + 64;
        uint32_t x0 = rnd() % 4 ? (rnd() | rnd() << 8) % R : 0; size_t wb = rnd() % 8 ? (rnd() | rnd() << 8) % (R - x0 + 1) : R - x0;
        uint32_t y0 = rnd() % 4 ? (rnd() | rnd() << 8) % rows : 0; size_t hb = rnd() % 8 ? 1 + (rnd() | rnd() << 8) % (rows - y0) : rows - y0;
        uint8_t *a = rnd_buf(n), *b = malloc(n); memcpy(b, a, n);
        region_same(a, b, n, x0, y0, wb, hb, wb + rnd() % 64, lb, rows, th, td);
        free(a); free(b);
    }
    CHECK(rdiff == d0, "R random shapes: %u of %u region writes differ", rdiff - d0, rcases - before);
    printf("  R random rows and regions, blocks 1 to 2^15 GOBs high and 1-4 deep, both paths, both GOB orders: %u region writes, %u differ\n", rcases - before, rdiff - d0);
    nvn_gob_switch2 = 0; nvn_bl_hoist = 1;
}
// As write_region_bl: a texel region of one level and layer of a texture, from its NVNcopyRegion to bytes and block rows, into the whole storage
static int texel_region(const nvn_texdesc *d, uint8_t *a, uint8_t *b, size_t n, unsigned level, unsigned layer, int xo, int yo, int w, int h) {
    uint32_t row_bytes, rows, slices, gbpb; uint64_t base; unsigned th, td; int bw, bh, bpb = nvn_fmt_bpb(d->format, &bw, &bh);
    if (nvn_deswizzle_geom(d, level, layer, &row_bytes, &rows, &slices, &base, &th, &td, &gbpb) || (int)gbpb != bpb) return 1;
    uint32_t x0 = (uint32_t)(xo / bw) * (uint32_t)bpb, y0 = (uint32_t)(yo / bh);
    size_t wb = (size_t)((w + bw - 1) / bw) * (size_t)bpb, hb = (size_t)((h + bh - 1) / bh);
    if (x0 + wb > row_bytes || y0 + hb > rows) return 1;
    uint32_t lb = nvn_tex_level_gobs(d, level) * 64; if (lb < row_bytes) lb = row_bytes;
    rpadded += lb > (row_bytes + 63) / 64 * 64;
    size_t need = hb ? (hb - 1) * (wb + 8) + wb : 0; uint8_t *own = need > SRC_N / 2 ? rnd_buf(need) : NULL;   // a whole large level reads more than g_src holds
    const uint8_t *src = own ? own : g_src + rnd() * 61u % (SRC_N / 2);
    ref_write_region(a + base, x0, y0, wb, hb, src, wb + 8, lb, rows, th, td); nvn_bl_write_region(b + base, x0, y0, wb, hb, src, wb + 8, lb, rows, th, td);
    free(own); rcases++; if (!memcmp(a, b, n)) return 1;
    if (++rdiff <= 8) printf("  ✗ R format %#x %ux%u level %u layer %u region (%d,%d) %dx%d: storage differs\n", d->format, d->width, d->height, level, layer, xo, yo, w, h);
    memcpy(b, a, n); return 0;
}
static void texel_regions(void) {
    // Bytes per block 1, 2, 3, 4, 6, 8, 12 and 16, BC1 / BC3 (4x4 blocks), ASTC 6x6 and 12x10; 2D, 2D arrays and cubes; packaged block heights, sparse textures with padded rows
    static const int formats[] = {0x01, 0x0D, 0x19, 0x25, 0x1D, 0x29, 0x22, 0x2E, 0x42, 0x44, 0x7D, 0x85};
    static const int targets[] = {1, 4, 7, 1};
    unsigned before = rcases, d0 = rdiff;
    for (unsigned i = 0; i < 192; i++) {
        nvn_texdesc d = {0};
        d.target = targets[i % 4]; d.format = formats[(i / 4) % 12]; d.levels = 1 + rnd() % 4;
        d.width = 1 + (rnd() | rnd() << 8) % 400; d.height = d.target == 7 ? d.width : 1 + (rnd() | rnd() << 8) % 300; d.depth = d.target == 4 ? 1 + rnd() % 3 : d.target == 7 ? 6 : 1;
        if (i % 4 == 3) { d.flags = 0x20; d.width = 300 + (rnd() | rnd() << 8) % 900; d.height = 64 + (rnd() | rnd() << 8) % 400; }   // sparse: tiled levels padded to whole 64 KB tiles
        if ((i / 48) & 1) d.pkg_block_h = 1 + rnd() % 6;
        nvn_gob_switch2 = (i / 96) & 1; nvn_bl_hoist = 1;
        nvn_texlayout L; nvn_tex_layout(&d, &L);
        size_t n = L.size + 64; uint8_t *a = rnd_buf(n), *b = malloc(n); memcpy(b, a, n);
        int bw, bh; nvn_fmt_bpb(d.format, &bw, &bh);
        for (unsigned k = 0; k < 24; k++) {
            unsigned level = rnd() % d.levels, layer = rnd() % L.layers;
            int lw = (int)mipd(d.width, level), lh = (int)mipd(d.height, level), xo = rnd() % lw, yo = rnd() % lh;
            int w = k == 0 ? lw : k == 1 ? 1 : 1 + rnd() % (lw - xo), h = k == 0 ? lh : k == 1 ? 1 : 1 + rnd() % (lh - yo);
            if (k == 0) xo = yo = 0;
            texel_region(&d, a, b, n, level, layer, xo, yo, w, h);
        }
        free(a); free(b);
    }
    // Every texel of small textures written one at a time (Metroid Dread's minimap calls WriteTexels once per texel)
    for (unsigned f = 0; f < 4; f++) {
        static const int fm[4] = {0x01, 0x25, 0x19, 0x2E};
        nvn_texdesc d = {1, fm[f], 0, 0, 37, 21, 1, 1, 0, 0}; nvn_texlayout L; nvn_tex_layout(&d, &L);
        nvn_gob_switch2 = f & 1;
        size_t n = L.size + 64; uint8_t *a = rnd_buf(n), *b = malloc(n); memcpy(b, a, n);
        for (int y = 0; y < 21; y++) for (int x = 0; x < 37; x++) texel_region(&d, a, b, n, 0, 0, x, y, 1, 1);
        free(a); free(b);
    }
    nvn_gob_switch2 = 0;
    CHECK(rdiff == d0, "R texture regions: %u of %u differ", rdiff - d0, rcases - before);
    printf("  R texture regions as write_region_bl takes them (bytes per block 1-16, BC, ASTC, arrays, cubes, single texels): %u region writes (%u in sparse rows padded to whole tiles), %u differ\n",
           rcases - before, rpadded, rdiff - d0);
}
static void tiles(void) {
    static const int formats[] = {0x01, 0x0D, 0x19, 0x25, 0x1D, 0x29, 0x22, 0x2E, 0x42, 0x44, 0x7D};
    uint8_t *tile = malloc(65536); unsigned cases = 0, diff = 0, written = 0, refused = 0;
    for (unsigned i = 0; i < 2 * 11 * 10; i++) {
        nvn_gob_switch2 = i & 1; nvn_bl_hoist = (i >> 1) & 1;
        int f = formats[(i / 2) % 11], bw, bh, bpb = nvn_fmt_bpb(f, &bw, &bh); unsigned th = (i / 22) % 10;   // 8: a sparse texture's own tile shape, 9: blocks 256 GOBs high (refused)
        nvn_texdesc d = {1, f, 0x20, 0, 0, 0, 1, 3, 0, th < 8 ? (int)th + 1 : th == 9 ? 9 : 0};
        uint32_t trb = (128u >> (th < 8 ? th : 3)) * 64, trows = 8u << (th < 8 ? th : 3);
        d.width = (uint32_t)((trb * 2 + rnd() % trb + 1) / (uint32_t)bpb * (uint32_t)bw); d.height = (uint32_t)((trows * 2 + rnd() % trows + 1) * (uint32_t)bh);   // 2 to 3 tiles each way
        if (th == 9) { d.width = 64; d.height = 1100 * (uint32_t)bh; }   // tall enough to keep its 256-GOB blocks
        for (unsigned level = 0; level < 3; level++) {
            uint32_t rb, rows, sl; dims(&d, level, &rb, &rows, &sl);
            unsigned lt, ld; nvn_tex_level_tiles(&d, level, &lt, &ld); if (lt > 7) lt = 7;
            size_t n = ((128u >> lt) * 64 + 40) * (8u << lt) + 64; uint8_t *a = rnd_buf(n), *b = malloc(n); memcpy(b, a, n);   // the tiles of a level decode into one buffer each way
            for (uint32_t ty = 0; ty <= rows / (8u << lt) + 1; ty++) for (uint32_t tx = 0; tx <= rb / ((128u >> lt) * 64) + 1; tx++) {   // one past the level each way
                fill(tile, 65536);
                size_t pitch = (tx + ty) % 7 == 3 ? rb % 64 : (128u >> lt) * 64 + rnd() % 40;   // sometimes too short for the tile's width (−1 both ways)
                if (!pitch) pitch = 1;
                uint32_t wa = 7, ra = 7, wn = 9, rn = 9;
                int rca = ref_tile(&d, level, tx, ty, tile, a, pitch, &wa, &ra), rcn = nvn_deswizzle_tile(&d, level, tx, ty, tile, b, pitch, &wn, &rn);
                cases++; written += wa != 0; refused += rca < 0;
                if (rca != rcn || wa != wn || ra != rn || memcmp(a, b, n)) {
                    if (++diff <= 8) printf("  ✗ T format %#x %ux%u block %u level %u tile (%u,%u) pitch %zu order %d hoist %d: %d %u×%u, reference %d %u×%u%s\n", f, d.width, d.height, th, level, tx, ty, pitch,
                                            nvn_gob_switch2, nvn_bl_hoist, rcn, wn, rn, rca, wa, ra, memcmp(a, b, n) ? ", bytes differ" : "");
                    memcpy(b, a, n);
                }
            }
            free(a); free(b);
        }
    }
    nvn_texdesc d3 = {2, 0x25, 0x20, 0, 256, 256, 64, 1, 0, 0}; uint32_t w3, r3;   // a 3D texture's blocks have depth: refused both ways
    CHECK(nvn_deswizzle_tile(&d3, 0, 0, 0, tile, tile, 65536, &w3, &r3) == -1 && ref_tile(&d3, 0, 0, 0, tile, tile, 65536, &w3, &r3) == -1, "T a 3D tile must be refused");
    nvn_gob_switch2 = 0; nvn_bl_hoist = 1; free(tile);
    CHECK(!diff, "T %u of %u tiles differ", diff, cases);
    printf("  T sparse tiles (bytes per block 1-16, blocks 1-256 GOBs high, edge and past-the-level tiles, short pitches, both paths, both GOB orders): %u tiles (%u with bytes, %u refused), %u differ\n", cases, written, refused, diff);
}
// DM_BL_HOIST is read once, at the first call: 0 takes the per-run loop, anything else or nothing the hoisted one
static void bl_switch(void) {
    static const struct { const char *v; int want; } S[] = {{NULL, 1}, {"0", 0}, {"1", 1}, {"", 1}};
    uint8_t st[512] = {0}, src[16] = {1}; int ok = 1;
    for (unsigned i = 0; i < 4; i++) {
        if (S[i].v) setenv("DM_BL_HOIST", S[i].v, 1); else unsetenv("DM_BL_HOIST");
        nvn_bl_hoist = -1; nvn_bl_write_region(st, 0, 0, 16, 1, src, 16, 64, 8, 0, 0); ok &= nvn_bl_hoist == S[i].want;
        setenv("DM_BL_HOIST", S[i].want ? "0" : "1", 1); nvn_bl_write_region(st, 0, 0, 16, 1, src, 16, 64, 8, 0, 0); ok &= nvn_bl_hoist == S[i].want;   // not read again
    }
    unsetenv("DM_BL_HOIST"); nvn_bl_hoist = 1;
    CHECK(ok, "R DM_BL_HOIST must be read once: unset, 1 or empty hoisted, 0 per run");
}

int main(void) {
    printf("D differential copy checks\n");
    differential_shapes();
    printf("L linear render targets without the separate LINEAR flag\n");
    {
        // Persona 5 Royal asks for 16x16 RGBA8, flags 0x44, stride 128: 2 KB,
        // including row padding. Treating it as block-linear returned only 1 KB.
        nvn_texdesc d = {1, 0x25, 0x44, 0, 16, 16, 1, 1, 128, 0};
        nvn_texlayout L; nvn_tex_layout(&d, &L);
        CHECK(L.size == 2048 && L.layer_size == 2048 && L.align == 128,
              "L render target storage %llu alignment %u, expected 2048 / 128", (unsigned long long)L.size, L.align);
        CHECK(nvn_tex_level_gobs(&d, 0) == 0 && nvn_tex_level_offset(&d, 0) == 0,
              "L linear render target must not have block-linear GOB columns");
        uint8_t storage[2048] = {0}, pixels[1024] = {0};
        CHECK(nvn_deswizzle(&d, 0, 0, storage, pixels, 64) == -1,
              "L linear render target must not be deswizzled");
        d.stride = 0; nvn_tex_layout(&d, &L);
        CHECK(L.size == 2048 && L.align == 128, "L implicit render target stride must align to 128");
        d.flags |= 0x10; nvn_tex_layout(&d, &L);
        CHECK(L.size == 2048 && L.align == 128, "L both linear flags must keep render target alignment");
        d.flags = 0x10; nvn_tex_layout(&d, &L);
        CHECK(L.size == 1024 && L.align == 32, "L ordinary linear texture keeps 32-byte alignment");
        d.flags = 0x44; d.stride = 256; nvn_tex_layout(&d, &L);
        CHECK(L.size == 4096, "L explicit padded stride must be preserved");
    }
    printf("A round trip (random data, non-power-of-2 sizes)\n");
    roundtrip("2D 100×37 R8 4 levels", 1, 0x01, 100, 37, 1, 4);
    roundtrip("2D 100×37 RG8 4 levels", 1, 0x0D, 100, 37, 1, 4);
    roundtrip("2D 100×37 RGBA8 4 levels", 1, 0x25, 100, 37, 1, 4);
    roundtrip("2D 100×37 RGBA16F 4 levels", 1, 0x29, 100, 37, 1, 4);
    roundtrip("2D 100×37 RGBA32F 4 levels", 1, 0x2E, 100, 37, 1, 4);
    roundtrip("2D 100×37 BC3(16B/block) 4 levels", 1, 0x44, 100, 37, 1, 4);
    roundtrip("2D 300×300 BC1(8B/block) 5 levels", 1, 0x42, 300, 300, 1, 5);
    roundtrip("2D array 100×37×3 layers RGBA8 3 levels", 4, 0x25, 100, 37, 3, 3);
    roundtrip("2D array 64×64×2 layers BC3 4 levels", 4, 0x44, 64, 64, 2, 4);
    roundtrip("3D 100×37×5 RGBA8 3 levels", 2, 0x25, 100, 37, 5, 3);
    roundtrip("3D 64×64×20 R8 4 levels", 2, 0x01, 64, 64, 20, 4);
    roundtrip("3D 40×30×9 RGBA32F 3 levels", 2, 0x2E, 40, 30, 9, 3);

    printf("B address formula (expected values hand-calculated from the public GOB 64B×8-row layout)\n");
    struct { uint32_t x, y, z, rb, rows; unsigned th, td; uint64_t want; const char *how; } B[] = {
        {0, 0, 0, 64, 8, 0, 0, 0, "origin"},
        {17, 3, 0, 64, 8, 0, 0, 113, "within GOB: (3/2)·64 + (17%32/16)·32 + (3%2)·16 + 17%16 = 64+32+16+1"},
        {70, 9, 0, 128, 32, 1, 0, 1558, "block height 2: block column 1 1024 + GOB 1 within the block 512 + within GOB (9%2)·16 + 6 = 22"},
        {0, 0, 1, 64, 8, 0, 1, 512, "block depth 2: GOB 1 within the block (z%2·block height 1) = 512"},
        {0, 0, 2, 64, 8, 0, 1, 1024, "block depth 2: block layer 1 = 1 column × 1 row × 1024"},
        {200, 40, 0, 256, 64, 2, 0, 9284, "block height 4 (32 rows): block row 1 4·2048=8192 + block column 3 3·2048=6144? see below"},
    };
    // Last hand-calculated case: rb=256 → 4 GOBs wide; block height 4 GOBs = 32 rows, block 2048 bytes; y=40 → block row 1: 4×2048 = 8192;
    // x=200 → block column 3: 3×2048 = 6144; GOB within the block = (40%32)/8 = 1 → 512; within the GOB x%64=8, y%8=0 → 8. Total 8192+6144+512+8 = 14856
    B[5].want = 14856; B[5].how = "block height 4: block row 8192 + block column 6144 + GOB within block 512 + within GOB 8";
    for (unsigned i = 0; i < sizeof B / sizeof *B; i++) {
        uint64_t got = nvn_bl_offset(B[i].x, B[i].y, B[i].z, B[i].rb, B[i].rows, B[i].th, B[i].td);
        CHECK(got == B[i].want, "B%u got %llu expected %llu", i, (unsigned long long)got, (unsigned long long)B[i].want);
        printf("  B%u (%u,%u,%u) → %llu %s  %s\n", i, B[i].x, B[i].y, B[i].z, (unsigned long long)got, got == B[i].want ? "✓" : "✗", B[i].how);
    }
    // The Switch 2's order inside a GOB (nvn_deswizzle.h): bits 5 and 6 of the offset exchanged, x%32/16 at 64 and y%4/2 at 32. Where only one of the two is set the orders differ
    printf("B2 address formula, the Switch 2's order inside a GOB: (x%%64/32)·256 + (y%%8/4)·128 + (x%%32/16)·64 + (y%%4/2)·32 + (y%%2)·16 + x%%16\n");
    struct { uint32_t x, y; uint64_t want, x1; } B2[] = {{16, 0, 64, 32}, {0, 2, 32, 64}, {21, 5, 213, 181}, {17, 3, 113, 113}, {70, 9, 1558, 1558}};
    nvn_gob_switch2 = 1;
    for (unsigned i = 0; i < sizeof B2 / sizeof *B2; i++) {
        uint64_t got = nvn_bl_offset(B2[i].x, B2[i].y, 0, 128, 32, 1, 0);
        CHECK(got == B2[i].want, "B2 (%u,%u) got %llu expected %llu", B2[i].x, B2[i].y, (unsigned long long)got, (unsigned long long)B2[i].want);
        printf("  B2 (%u,%u) → %llu %s (the X1's order: %llu)\n", B2[i].x, B2[i].y, (unsigned long long)got, got == B2[i].want ? "✓" : "✗", (unsigned long long)B2[i].x1);
    }
    nvn_gob_switch2 = 0;
    for (unsigned i = 0; i < sizeof B2 / sizeof *B2; i++)
        CHECK(nvn_bl_offset(B2[i].x, B2[i].y, 0, 128, 32, 1, 0) == B2[i].x1, "B2 (%u,%u) in the X1's order expected %llu", B2[i].x, B2[i].y, (unsigned long long)B2[i].x1);

    // ---------- E hand-built 3D: place markers into block-linear storage at hand-calculated addresses, decode, and verify where the markers land (round trip A only proves self-consistency, not whether the layout is right) ----------
    // Source of the block height / block depth rule: deko3d dk_image.cpp - for 3D textures block height is fixed at 1 GOB, block depth = pickTileSize(depth + depth/2).
    printf("E hand-built 3D block-linear (markers at hand-calculated addresses, landing points checked after deswizzle)\n");
    {
        nvn_texdesc d = {2, 0x25, 0, 0, 32, 16, 20, 1, 0, 0};   // 3D RGBA8 32×16×20: row 128 bytes = 2 GOBs wide, 16 rows = 2 GOBs high
        nvn_texlayout L; nvn_tex_layout(&d, &L);
        // Block depth: 20 + 10 = 30 ≥ 16 → 16 slices (log2 = 4); block = 512 × 16 = 8192 bytes; one block layer = 2 columns × 2 rows × 8192 = 32768; ceil(20/16) = 2 layers → 65536
        CHECK(L.tileH == 0 && L.tileD == 4, "E 32×16×20 block height/depth = %u/%u, expected 0/4", L.tileH, L.tileD);
        CHECK(L.size == 65536, "E 32×16×20 storage %llu expected 65536", (unsigned long long)L.size);
        struct { uint32_t x, y, z; uint64_t addr; const char *how; } V[] = {
            {0, 0, 0, 0, "origin"},
            {20, 11, 3, 26224, "block row 1·2·8192=16384 + block column (80/64=1)·8192 + GOB within block z%16=3·512=1536 + within GOB (x80%64=16,y3) 64+32+16 = 112"},
            {31, 15, 17, 58364, "depth block 1·32768 + block row 16384 + block column 8192 + GOB within block 1·512 + within GOB (x60,y7) 256+192+32+16+12 = 508"},
            {5, 2, 19, 34404, "depth block 32768 + GOB within block 3·512=1536 + within GOB (x20,y2) 64+32+4 = 100"},
        };
        uint8_t *st = calloc(L.size, 1), *lin = calloc(128 * 16 * 20, 1);
        for (unsigned i = 0; i < 4; i++) for (int k = 0; k < 4; k++) st[V[i].addr + k] = (uint8_t)(0x10 * (i + 1) + k + 1);
        CHECK(!nvn_deswizzle(&d, 0, 0, st, lin, 128), "E deswizzle failed");
        for (unsigned i = 0; i < 4; i++) {
            const uint8_t *p = lin + ((size_t)V[i].z * 16 + V[i].y) * 128 + V[i].x * 4; int ok = 1;
            for (int k = 0; k < 4; k++) ok &= p[k] == (uint8_t)(0x10 * (i + 1) + k + 1);
            CHECK(ok, "E voxel (%u,%u,%u) did not get the marker at hand-calculated address %llu", V[i].x, V[i].y, V[i].z, (unsigned long long)V[i].addr);
            printf("  E (%2u,%2u,%2u) ← storage %5llu %s  %s\n", V[i].x, V[i].y, V[i].z, (unsigned long long)V[i].addr, ok ? "✓" : "✗", V[i].how);
        }
        size_t nz = 0; for (size_t j = 0; j < 128 * 16 * 20; j++) nz += lin[j] != 0;
        CHECK(nz == 16, "E nonzero decoded bytes %zu expected 16 (there should be no data outside the markers)", nz);
        free(st); free(lin);
        // Shape of the real color lookup table on the character select screen: 32³ RGBA16F (ser 17 / 16). Block depth 32 + 16 = 48 ≥ 16 → 16 slices; row 256 bytes = 4 GOBs wide, 32 rows = 4 GOBs high, 2 block layers → 4·4·2·8192 = 262144
        nvn_texdesc lut = {2, 0x29, 0, 0, 32, 32, 32, 1, 0, 0}; nvn_tex_layout(&lut, &L);
        CHECK(L.tileH == 0 && L.tileD == 4 && L.size == 4 * 4 * 2 * 8192ull, "E 32³ RGBA16F block height/depth %u/%u storage %llu, expected 0/4, 262144", L.tileH, L.tileD, (unsigned long long)L.size);
        printf("  E 32³ RGBA16F (the shape of a 32³ color lookup table) block height/depth %u/%u, storage %llu (expected 0/4, 262144)\n", L.tileH, L.tileD, (unsigned long long)L.size);
    }

    // Packaged 32³ RGBA8: markers computed independently with block height/depth 0/0 or 2/1.
    // For byte 0x12, (20,11,3) is at depth block 8192 + column 4096 + GOB 2560 + intra-GOB 112 = 14960.
    // For byte 0x00, the same voxel is at slice 12288 + row 1024 + column 512 + intra-GOB 112 = 13936.
    printf("E packaged 3D block dimensions and mip reductions\n");
    for (unsigned c = 0; c < 2; c++) {
        nvn_texdesc d = {2, 0x25, 0, 0, 32, 32, 32, 3, 0, c ? 0x13 : 1};
        nvn_texlayout L; nvn_tex_layout(&d, &L);
        CHECK(L.size == 151552, "E packaged storage %llu expected 151552", (unsigned long long)L.size);
        for (unsigned l = 0; l < 3; l++) {
            unsigned th, td; nvn_tex_level_tiles(&d, l, &th, &td);
            CHECK(th == (c ? 2 - l : 0) && td == (c ? 1 : 0),
                  "E packaged byte %#x mip %u block %u/%u", d.pkg_block_h - 1, l, th, td);
        }
        CHECK(nvn_tex_level_offset(&d, 1) == 131072 && nvn_tex_level_offset(&d, 2) == 147456,
              "E packaged mip offsets must be 131072 / 147456");
        static const uint32_t xyz[3][3] = {{20,11,3}, {5,2,1}, {31,31,31}};
        static const uint64_t addr[2][3] = {{13936,4196,131068}, {14960,2148,131068}};
        uint8_t *st = calloc(L.size, 1), *lin = calloc(131072, 1);
        for (unsigned i = 0; i < 3; i++) for (unsigned k = 0; k < 4; k++) st[addr[c][i] + k] = (uint8_t)(i * 16 + k + 1);
        CHECK(!nvn_deswizzle(&d, 0, 0, st, lin, 128), "E packaged deswizzle failed");
        for (unsigned i = 0; i < 3; i++) {
            const uint8_t *p = lin + ((size_t)xyz[i][2] * 32 + xyz[i][1]) * 128 + xyz[i][0] * 4;
            int ok = 1; for (unsigned k = 0; k < 4; k++) ok &= p[k] == (uint8_t)(i * 16 + k + 1);
            CHECK(ok, "E packaged byte %#x marker %u at %llu decoded at the wrong voxel", d.pkg_block_h - 1, i, (unsigned long long)addr[c][i]);
        }
        free(st); free(lin);
    }

    // ---------- S sparse layout: Monster Hunter Rise's streamed 1024×1024 ASTC 6×6 sRGB textures (flag SPARSE, packaged block height 8 GOBs), level 0 checked against the game's data ----------
    // A 64 KB tile is 16 GOBs × 8 GOBs here. Level 0 (171 block columns = 43 GOBs) is padded to 48 GOBs × 3 block rows = 9 tiles: its dumped data decodes with no all-zero block that way
    // (2,183 unpadded). Level 1 (86 = 22 GOBs → 32, 2 block rows) is 4 tiles; level 2 (43 block columns, less than a tile's 64) starts the mip tail, packed as before; storage in whole tiles
    printf("S sparse layout (64 KB tiles: tiled levels padded to whole tiles, then the mip tail)\n");
    {
        nvn_texdesc d = {1, 0x8B, 0x20, 0, 1024, 1024, 1, 8, 0, 4}; nvn_texlayout L; nvn_tex_layout(&d, &L);
        static const uint64_t off[8] = {0, 0x90000, 0xD0000, 0xDB000, 0xDE000, 0xDEC00, 0xDF000, 0xDF200};
        static const uint32_t gobs[3] = {48, 32, 11};
        for (unsigned l = 0; l < 8; l++) CHECK(nvn_tex_level_offset(&d, l) == off[l], "S level %u offset %#llx expected %#llx", l, (unsigned long long)nvn_tex_level_offset(&d, l), (unsigned long long)off[l]);
        for (unsigned l = 0; l < 3; l++) CHECK(nvn_tex_level_gobs(&d, l) == gobs[l], "S level %u laid out %u GOBs wide, expected %u", l, nvn_tex_level_gobs(&d, l), gobs[l]);
        CHECK(L.size == 0xE0000 && L.align == 0x10000, "S storage %#llx alignment %#x, expected 0xe0000 / 0x10000", (unsigned long long)L.size, L.align);
        printf("  S 1024×1024 ASTC 6×6 sparse: levels at 0, %#llx, %#llx …, storage %#llx (expected 0x90000, 0xd0000, 0xe0000)\n", (unsigned long long)nvn_tex_level_offset(&d, 1), (unsigned long long)nvn_tex_level_offset(&d, 2), (unsigned long long)L.size);
        d.flags = 0; nvn_tex_layout(&d, &L);   // the same texture not sparse keeps the packed layout
        CHECK(nvn_tex_level_offset(&d, 1) == 0x81000 && L.size == 0xBC400 && nvn_tex_level_gobs(&d, 0) == 43, "S not sparse: level 1 %#llx storage %#llx, expected 0x81000 / 0xbc400",
              (unsigned long long)nvn_tex_level_offset(&d, 1), (unsigned long long)L.size);
    }

    printf("R region writes and T sparse tiles: the hoisted runs against one nvn_bl_offset per 16-byte run (DM_BL_HOIST)\n");
    regions(); texel_regions(); tiles(); bl_switch();

    printf("%s: %d/%d checks passed\n", fails ? "RED" : "all passed", checks - fails, checks);
    return fails ? 1 : 0;
}
