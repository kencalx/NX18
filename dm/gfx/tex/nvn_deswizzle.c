//     (x%64/32)·256 + (y%8/2)·64 + (x%32/16)·32 + (y%2)·16 + x%16
// Tegra X1 block-linear layout (public descriptions: deko3d / Ryujinx BlockLinearLayout):
//   GOB = 64 bytes × 8 rows = 512 bytes; offset of (x byte, y row) within a GOB =
//     (x%64/32)·256 + (y%8/2)·64 + (x%32/16)·32 + (y%2)·16 + x%16
//   The Switch 2 (NVN2) orders a GOB's 16-byte pieces otherwise: (x%64/32)·256 + (y%8/4)·128 + (x%32/16)·64 + (y%4/2)·32 + (y%2)·16 + x%16 (nvn_gob_switch2)
//   block = 1 GOB wide × 2^tileH GOBs high × 2^tileD GOBs deep, ordered y first then z within a block; blocks fill the level in x → y → z row-major order.
// Level / layer start offsets and the actual block height and block depth of this level come from nvn_tex.c; here we only do intra-level addressing and copying.
#include "nvn_deswizzle.h"
#include <stdlib.h>
#include <string.h>

int nvn_gob_switch2;   // see nvn_deswizzle.h
int nvn_bl_hoist = -1;   // see nvn_deswizzle.h

static uint32_t gob_off(uint32_t x, uint32_t y) {
    if (nvn_gob_switch2) return (x % 64 / 32) * 256 + (y % 8 / 4) * 128 + (x % 32 / 16) * 64 + (y % 4 / 2) * 32 + (y % 2) * 16 + x % 16;
    return (x % 64 / 32) * 256 + (y % 8 / 2) * 64 + (x % 32 / 16) * 32 + (y % 2) * 16 + x % 16;
}

uint64_t nvn_bl_offset(uint32_t x, uint32_t y, uint32_t z, uint32_t row_bytes, uint32_t rows, unsigned th, unsigned td) {
    uint32_t bh = 1u << th, bd = 1u << td;
    uint64_t gobs_x = (row_bytes + 63) / 64, blocks_y = (rows + 8 * bh - 1) / (8 * bh);
    uint64_t block = 512ull * bh * bd;                                  // bytes in one block
    return (z / bd) * gobs_x * blocks_y * block                        // which block layer (along depth)
         + (y / (8 * bh)) * gobs_x * block                             // which block row
         + (x / 64) * block                                            // which block column
         + ((z % bd) * bh + (y % (8 * bh)) / 8) * 512ull               // which GOB within the block
         + gob_off(x, y);
}

static uint32_t mip(uint32_t s, unsigned l) { s >>= l; return s ? s : 1; }

// Geometry of this level: width-in-blocks byte count, block row count, slice count, and where this level and layer starts in storage; returns -1 for unsupported textures
int nvn_deswizzle_geom(const nvn_texdesc *d, unsigned level, unsigned layer,
                       uint32_t *row_bytes, uint32_t *rows, uint32_t *slices, uint64_t *base, unsigned *th, unsigned *td, uint32_t *bpb) {
    if (d->target == 5 || d->target == 6 || d->target == 10 || (d->flags & 0x50) || d->samples > 1) return -1;   // MS / BUFFER / LINEAR / LINEAR_RENDER_TARGET
    int bw, bh; *bpb = (uint32_t)nvn_fmt_bpb(d->format, &bw, &bh);
    if (!*bpb || level >= (d->levels ? d->levels : 1)) return -1;
    nvn_texlayout L; nvn_tex_layout(d, &L);
    if (layer >= L.layers) return -1;
    int one_d = d->target == 0 || d->target == 3;
    uint32_t w = mip(d->width, level), h = one_d ? 1 : mip(d->height, level);
    *slices = d->target == 2 ? mip(d->depth ? d->depth : 1, level) : 1;
    *row_bytes = (w + bw - 1) / bw * *bpb; *rows = (h + bh - 1) / bh;
    *base = (uint64_t)layer * L.layer_size + nvn_tex_level_offset(d, level);
    nvn_tex_level_tiles(d, level, th, td);
    return 0;
}

// A GOB's 16-byte pieces: the piece at x%64 = 0/16/32/48 of row y%8 starts at kox[x%64/16] + koy[y%8] (gob_off without x%16)
static const uint16_t kox1[4] = {0, 32, 256, 288};                        // the 16-byte piece's start in its GOB row (x%16 not included: a run starting inside a piece adds it)
static const uint16_t koy1[8] = {0, 16, 64, 80, 128, 144, 192, 208};      // (y%8/2)*64 + (y%2)*16
static const uint16_t kox2[4] = {0, 64, 256, 320};                        // the Switch 2's order (gob_off): x%32/16 at 64
static const uint16_t koy2[8] = {0, 16, 32, 48, 128, 144, 160, 176};      // (y%8/4)*128 + (y%4/2)*32 + (y%2)*16

static int move(const nvn_texdesc *d, unsigned level, unsigned layer, uint8_t *bl, uint64_t bl_at, uint8_t *lin, size_t pitch, int to_linear) {   // bl: the storage from byte bl_at on
    uint32_t row_bytes, rows, slices, bpb; uint64_t base; unsigned th, td;
    if (nvn_deswizzle_geom(d, level, layer, &row_bytes, &rows, &slices, &base, &th, &td, &bpb)) return -1;
    if (pitch < row_bytes || base < bl_at) return -1;
    bl += base - bl_at; uint32_t lb = nvn_tex_level_gobs(d, level) * 64;   // the row as laid out (padded in a sparse texture's tiled levels)
    if (lb < row_bytes) lb = row_bytes;
    // Hoist nvn_bl_offset's slice and row terms out of the segment loop. The block height and depth are powers of two,
    // so their division / remainder become shifts and masks. At x = 16*j the block column is j >> 2, and the segment
    // has one of four positions inside the GOB (x%64 = 0/16/32/48 -> 0/32/256/288); the y part depends only on y%8.
    const uint16_t *kox = nvn_gob_switch2 ? kox2 : kox1, *koy = nvn_gob_switch2 ? koy2 : koy1;
    uint32_t bh = 1u << th, bd = 1u << td;
    uint64_t block = 512ull * bh * bd, gobs_x = (uint64_t)(lb + 63) >> 6, blocks_y = ((uint64_t)rows + 8 * bh - 1) >> (3 + th);
    for (uint32_t z = 0; z < slices; z++) {
        uint64_t zb = (uint64_t)(z >> td) * gobs_x * blocks_y * block + (uint64_t)(z & (bd - 1)) * bh * 512;
        for (uint32_t y = 0; y < rows; y++) {
            uint64_t p = (uint64_t)(y >> (3 + th)) * gobs_x * block + (uint64_t)((y & (8 * bh - 1)) >> 3) * 512 + koy[y & 7];
            uint8_t *row = lin + ((size_t)z * rows + y) * pitch;
            uint64_t yb = zb + p;   // the row's segments: block column (j >> 2) at yb + j>>2 times block + kox[j & 3]
            uint32_t nfull = row_bytes >> 4, tail = row_bytes & 15;
            // The full 16-byte segments take a constant-size copy (a memcpy of a runtime length is a call per segment);
            // a row whose byte count is not divisible by 16 has a tail (e.g. R8 or RGB formats at an odd width).
            if (to_linear) {
                for (uint32_t j = 0; j < nfull; j++) memcpy(row + (j << 4), bl + yb + ((uint64_t)(j >> 2) * block) + kox[j & 3], 16);
                if (tail) memcpy(row + (nfull << 4), bl + yb + ((uint64_t)(nfull >> 2) * block) + kox[nfull & 3], tail);
            } else {
                for (uint32_t j = 0; j < nfull; j++) memcpy(bl + yb + ((uint64_t)(j >> 2) * block) + kox[j & 3], row + (j << 4), 16);
                if (tail) memcpy(bl + yb + ((uint64_t)(nfull >> 2) * block) + kox[nfull & 3], row + (nfull << 4), tail);
            }
        }
    }
    return 0;
}

int nvn_deswizzle(const nvn_texdesc *d, unsigned level, unsigned layer, const void *src, void *dst, size_t dst_pitch) {
    return move(d, level, layer, (uint8_t *)src, 0, (uint8_t *)dst, dst_pitch, 1);
}
int nvn_swizzle(const nvn_texdesc *d, unsigned level, unsigned layer, const void *src, size_t src_pitch, void *dst) {
    return move(d, level, layer, (uint8_t *)dst, 0, (uint8_t *)src, src_pitch, 0);
}

// DM_BL_HOIST=0: nvn_deswizzle_tile and nvn_bl_write_region take one nvn_bl_offset per 16-byte run, as before (nvn_deswizzle.h); read at the first call
static int bl_hoist(void) { if (nvn_bl_hoist < 0) { const char *e = getenv("DM_BL_HOIST"); nvn_bl_hoist = !(e && !strcmp(e, "0")); } return nvn_bl_hoist; }

// A region of slice 0 of a level's block-linear storage bl (the level's start) to or from linear lin (block rows pitch bytes apart): wb bytes from byte x0 of hb block rows from row y0.
// The memcpy calls of one nvn_bl_offset per 16-byte run, the same ones in the same order, with move()'s terms hoisted: per row the block row, the GOB in the block and y%8, per run
// the block column (j >> 2) and the place in the GOB (kox[j & 3]) of the 16-byte piece j = x / 16. A run never crosses a piece, so an x0 that is not a multiple of 16 (WriteTexels of
// a texel, a copy at an odd offset) starts with a run to its piece's end, at x0%16 in it; a region whose width is not a multiple of 16 ends with a shorter run. On x86-64 a 64 KB tile went
// from 14-17 to 3.3-3.9 us (Mario Kart World maps 21,796 in its flyover's first minute), Tears of the Kingdom's four read-back targets from 0.70-0.86 to 0.14-0.15 ms a frame (rendering.md)
static void region(uint8_t *bl, uint8_t *lin, size_t pitch, uint32_t x0, uint32_t y0, size_t wb, size_t hb, uint32_t lb, unsigned th, unsigned td, int to_linear) {
    const uint16_t *kox = nvn_gob_switch2 ? kox2 : kox1, *koy = nvn_gob_switch2 ? koy2 : koy1;
    uint32_t bh = 1u << th, bd = 1u << td;
    uint64_t block = 512ull * bh * bd, gobs_x = (uint64_t)(lb + 63) >> 6;
    size_t head = x0 & 15 ? 16 - (x0 & 15) : 0; if (head > wb) head = wb;   // the first run's bytes up to its piece's end
    uint32_t j0 = (uint32_t)((x0 + head) >> 4), nfull = (uint32_t)((wb - head) >> 4), tail = (uint32_t)((wb - head) & 15), jt = j0 + nfull;
    uint64_t ho = (uint64_t)(x0 >> 6) * block + kox[(x0 >> 4) & 3] + (x0 & 15), to = (uint64_t)(jt >> 2) * block + kox[jt & 3];   // the first and the last run in the row
    for (size_t y = 0; y < hb; y++) {
        uint32_t yy = y0 + (uint32_t)y;
        uint8_t *b = bl + (uint64_t)(yy >> (3 + th)) * gobs_x * block + (uint64_t)((yy & (8 * bh - 1)) >> 3) * 512 + koy[yy & 7], *l = lin + y * pitch + head;
        if (to_linear) {
            if (head) memcpy(l - head, b + ho, head);
            for (uint32_t j = j0; j < jt; j++, l += 16) memcpy(l, b + (uint64_t)(j >> 2) * block + kox[j & 3], 16);
            if (tail) memcpy(l, b + to, tail);
        } else {
            if (head) memcpy(b + ho, l - head, head);
            for (uint32_t j = j0; j < jt; j++, l += 16) memcpy(b + (uint64_t)(j >> 2) * block + kox[j & 3], l, 16);
            if (tail) memcpy(b + to, l, tail);
        }
    }
}

void nvn_bl_write_region(void *bl, uint32_t x0, uint32_t y0, size_t wb, size_t hb, const void *src, size_t pitch, uint32_t lb, uint32_t rows, unsigned th, unsigned td) {
    uint8_t *o = bl; const uint8_t *s = src;
    // A row past 4 GB (only a negative region width that wrapped write_region_bl's bounds check) keeps the per-run loop, whose x wraps at 32 bits as it always did
    if (bl_hoist() && wb <= (1ull << 32) - x0) { region(o, (uint8_t *)s, pitch, x0, y0, wb, hb, lb, th, td, 0); return; }
    for (size_t y = 0; y < hb; y++)
        for (size_t x = 0; x < wb;) {   // 16-byte runs are contiguous within a GOB
            uint32_t bx = x0 + (uint32_t)x; size_t n = 16 - bx % 16; if (n > wb - x) n = wb - x;
            memcpy(o + nvn_bl_offset(bx, y0 + (uint32_t)y, 0, lb, rows, th, td), s + y * pitch + x, n); x += n;
        }
}

// One 64 KB tile of a sparse texture's tiled level (2D, one slice). Such a level is laid out with its width padded to whole tiles (nvn_tex.c level_walk), and a tile is one block row of
// 128 / block height GOB columns: 64 KB of its own, at the level's start + (ty × tiles across + tx) × 64 KB. So it decodes as a block-linear surface of that size; the part inside the level
// goes to dst (block rows of pitch bytes). *wb and *rows: the bytes and block rows written (0 for a tile past the level)
int nvn_deswizzle_tile(const nvn_texdesc *d, unsigned level, uint32_t tx, uint32_t ty, const void *tile, void *dst, size_t pitch, uint32_t *wb, uint32_t *nrows) {
    uint32_t row_bytes, rows, slices, bpb; uint64_t base; unsigned th, td;
    *wb = *nrows = 0;
    if (nvn_deswizzle_geom(d, level, 0, &row_bytes, &rows, &slices, &base, &th, &td, &bpb) || td || slices != 1 || th > 7) return -1;
    uint32_t trb = (128u >> th) * 64, trows = 8u << th, x0 = tx * trb, y0 = ty * trows;
    if (x0 >= row_bytes || y0 >= rows) return 0;
    uint32_t w = row_bytes - x0 < trb ? row_bytes - x0 : trb, h = rows - y0 < trows ? rows - y0 : trows;
    if (pitch < w) return -1;
    const uint8_t *s = tile; uint8_t *o = dst;
    if (bl_hoist()) region((uint8_t *)s, o, pitch, 0, 0, w, h, trb, th, 0, 1);
    else for (uint32_t y = 0; y < h; y++)
        for (uint32_t x = 0; x < w; x += 16) memcpy(o + (size_t)y * pitch + x, s + nvn_bl_offset(x, y, 0, trb, trows, th, 0), w - x < 16 ? w - x : 16);
    *wb = w; *nrows = h;
    return 0;
}
// nvn_deswizzle with the storage given from byte src_at on (a sparse texture's mip tail gathered on its own): the level must lie at or after it
int nvn_deswizzle_from(const nvn_texdesc *d, unsigned level, unsigned layer, const void *src, uint64_t src_at, void *dst, size_t dst_pitch) {
    return move(d, level, layer, (uint8_t *)src, src_at, (uint8_t *)dst, dst_pitch, 1);
}
