// Reflection conversion unit tests: real B reflection json (translation of the original Switch shaders, build/cache/metal_shader_cache/<key>_b.json) → C arrays, expectations hand-copied from the json text.
// Dummy texture type MTLTextureType: 1D=0 1DArray=1 2D=2 2DArray=3 Cube=5 CubeArray=6 3D=7
#import "../nvn/nvn_refl.h"
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#include <stdio.h>
#include <string.h>
#include "dmsh_chain.h"   // dm/gfx/nvn (-I from the Makefile)
#include "msl_image.h"    // a game's shader library image (DM_REFL_IMG), read in place

enum { C = NVN_RB_CBUF, S = NVN_RB_SAMP, T = NVN_RB_TEX, I = NVN_RB_IMG, TB = NVN_RB_TBUF };
enum { F = NVN_DPF_FLOAT, U = NVN_DPF_UINT, D = NVN_DPF_DEPTH };
static int fail, n, skipped;
static void check(const char *what, long want, long got) {
    n++; int ok = want == got; fail += !ok;
    if (!ok) printf("  %-40s expected %ld → got %ld ✗\n", what, want, got);
}
static NSDictionary *load(const char *key) {
    NSString *p = [NSString stringWithFormat:@"%s%s/build/cache/metal_shader_cache/b-%s/%s.json", getenv("DM_ROOT") ?: getenv("HOME"), getenv("DM_ROOT") ? "" : "/dm-work", DMSH_CHAIN, key];   // the library of the current translation chain version
    NSData *d = [NSData dataWithContentsOfFile:p];
    if (!d) { printf("SKIP: no reflection sample %s (the samples are translated shaders of Super Mario Bros. Wonder in the NSP script's build cache; DM_ROOT or ~/dm-work/build/cache/metal_shader_cache), the checks on it do not run\n", p.UTF8String); skipped++; return nil; }
    return [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
}

// Two conversions of one json are the same reflection: every field, the bindings b[0..nb), the readable-tile tables and c1. The pointers and the room differ by design (cap, tail)
static int same_refl(const nvn_refl *a, const nvn_refl *b, char *why, size_t wl) {
    nvn_refl x = *a, y = *b; x.b = y.b = NULL; x.fc = y.fc = NULL; x.uv = y.uv = NULL; x.tail = y.tail = NULL; x.cap = y.cap = 0; x.c1 = y.c1 = NULL;
    if (memcmp(&x, &y, sizeof x)) { snprintf(why, wl, "scalar fields differ"); return 0; }
    if (a->nb && memcmp(a->b, b->b, (size_t)a->nb * sizeof *a->b)) { snprintf(why, wl, "bindings differ"); return 0; }
    if (memcmp(a->fc, b->fc, sizeof *a->fc)) { snprintf(why, wl, "fragment readable-tile tables differ"); return 0; }
    if (memcmp(a->uv, b->uv, sizeof *a->uv)) { snprintf(why, wl, "vertex readable-tile tables differ"); return 0; }
    if (a->c1_len && memcmp(a->c1, b->c1, a->c1_len)) { snprintf(why, wl, "c1 differs"); return 0; }
    return 1;
}
static const long FIXED_BLOCK = (long)(sizeof(nvn_refl_fc) + sizeof(nvn_refl_uv) + NVN_REFL_MAXB * sizeof(nvn_rbind));   // what DM_NVN_REFL_FIXED=1 gives every shader
// The tail block's layout: bindings at their real number, each table part only for a shader with entries in it, nothing at all for a shader with neither; DM_NVN_REFL_FIXED=1 the
// old fixed block
static void layout_cases(nvn_refl *r) {
    char err[160] = ""; int f1 = fail; uint64_t t0, b0, t1, b1;
    NSDictionary *two = @{@"route": @"B", @"bindings": @[@{@"kind": @"cbuf", @"reg": @0, @"arg_id": @0, @"msl_name": @"vp_c3", @"msl_type": @"constant vp_c3_t*"},
        @{@"kind": @"tex", @"reg": @1, @"arg_id": @1, @"msl_name": @"vp_t_1", @"msl_type": @"texture2d<float>"}]};
    NSDictionary *none = @{@"route": @"B", @"bindings": @[]};
    NSDictionary *fetch = @{@"route": @"B", @"stage": @"ps", @"bindings": @[@{@"kind": @"tex", @"reg": @1, @"arg_id": @0, @"msl_name": @"fp_t_1", @"msl_type": @"texture2d<float>"}],
        @"fetch": @{@"calls": @[@{@"fc": @0, @"tex_reg": @1, @"varying_locn": @3}], @"mixed_regs": @[@200]}};
    NSDictionary *uv = @{@"route": @"B", @"stage": @"vs", @"bindings": @[], @"raster": @{@"pos_attr": @0, @"uv_from_attr": @{@"5": @2}}};
    nvn_refl_set_fixed(0);
    nvn_refl_stats(&t0, &b0);
    check("tail: two bindings convert", 0, nvn_refl_from_json(two, r, err, sizeof err));
    nvn_refl_stats(&t1, &b1);
    check("tail: room for exactly the two bindings", 2, r->cap);
    check("tail: no tables of its own", 1, r->fc == &nvn_refl_fc_none && r->uv == &nvn_refl_uv_none);
    check("tail: one block of two bindings counted", (long)(2 * sizeof(nvn_rbind)), (long)(b1 - b0));
    check("tail: the bindings come back", NVN_RB_TEX, r->b[1].kind); check("tail: binding 1 slot", 1, r->b[1].reg);
    check("tail: an empty table reads -1 for uv_attr", -1, r->uv->uv_attr[31]); check("tail: an empty table reads -1 for uv_aff_attr", -1, r->uv->uv_aff_attr[0]);
    check("tail: an empty table reads 0 for fc_mixed", 0, (long)r->fc->fc_mixed[3]);
    check("tail: no bindings converts", 0, nvn_refl_from_json(none, r, err, sizeof err));
    check("tail: no bindings, no block", 1, r->tail == NULL && r->b == NULL && r->cap == 0);
    nvn_refl_stats(&t1, &b1); check("tail: the earlier block was released", (long)t0, (long)t1);
    check("tail: fetch calls convert", 0, nvn_refl_from_json(fetch, r, err, sizeof err));
    check("tail: fetch calls give fragment tables of its own, first in the block", 1, r->fc != &nvn_refl_fc_none && (const void *)r->fc == r->tail && r->uv == &nvn_refl_uv_none);
    check("tail: and one binding after them", 1, r->cap == 1 && (const char *)r->b == (const char *)r->tail + sizeof(nvn_refl_fc));
    nvn_refl_stats(&t1, &b1); check("tail: fragment tables and one binding counted", (long)(sizeof(nvn_refl_fc) + sizeof(nvn_rbind)), (long)(b1 - b0));
    check("tail: fc_reg kept", 1, r->fc->fc_reg[0]); check("tail: fc_locn kept", 3, r->fc->fc_locn[0]); check("tail: mixed slot 200", 1, (long)(r->fc->fc_mixed[3] >> 8 & 1));
    check("tail: uv_attr still reads -1", -1, r->uv->uv_attr[0]);
    check("tail: a vertex uv fact converts", 0, nvn_refl_from_json(uv, r, err, sizeof err));
    check("tail: a vertex uv fact gives vertex tables of its own only", 1, r->uv != &nvn_refl_uv_none && r->fc == &nvn_refl_fc_none && r->cap == 0 && (const void *)r->uv == r->tail);
    check("tail: uv_attr[5] = attribute 2", 2, r->uv->uv_attr[5]); check("tail: uv_attr[4] none", -1, r->uv->uv_attr[4]);
    check("tail: a refused json leaves no block", 1, nvn_refl_from_json(@{@"route": @"B", @"bindings": @[@{@"kind": @"foo", @"arg_id": @0, @"msl_name": @"x", @"msl_type": @"x"}]}, r, err, sizeof err) && !r->tail && r->fc == &nvn_refl_fc_none && r->uv == &nvn_refl_uv_none);
    nvn_refl_stats(&t1, &b1); check("tail: every block released", (long)t0, (long)t1); check("tail: every byte released", (long)b0, (long)b1);
    nvn_refl_set_fixed(1);
    check("fixed: two bindings convert", 0, nvn_refl_from_json(two, r, err, sizeof err));
    check("fixed: room for NVN_REFL_MAXB bindings", NVN_REFL_MAXB, r->cap);
    check("fixed: both tables of its own", 1, r->fc != &nvn_refl_fc_none && r->uv != &nvn_refl_uv_none);
    int zero = 1; for (int i = r->nb; i < r->cap; i++) { nvn_rbind z = {0}; if (memcmp(&r->b[i], &z, sizeof z)) zero = 0; }
    check("fixed: zeros past nb, as the embedded array had", 1, zero);
    nvn_refl_stats(&t1, &b1); check("fixed: the old block's size counted", FIXED_BLOCK, (long)(b1 - b0));
    nvn_refl_free(r); nvn_refl_set_fixed(-1);
    nvn_refl h = {0}; check("reserve: a shader made by hand gets room", 1, nvn_refl_reserve(&h, NVN_REFL_MAXB, 1) && h.cap == NVN_REFL_MAXB);
    h.nb = 1; h.b[0] = (nvn_rbind){.kind = NVN_RB_IMG, .reg = 7}; nvn_refl_fcw(&h)->fc_reg[0] = 9; nvn_refl_uvw(&h)->uv_attr[2] = 4;
    check("reserve: the tables written in place", 1, h.fc->fc_reg[0] == 9 && h.uv->uv_attr[2] == 4 && h.uv->uv_attr[3] == -1);
    nvn_refl g = {0}; g.nb = 0; check("reserve: a table alone keeps the bindings it has", 1, nvn_refl_fcw(&g) && g.cap == 0 && g.uv == &nvn_refl_uv_none);
    nvn_refl_free(&g); nvn_refl_free(&h);
    printf("%-60s %s\n", "reflection tail block: real length, tables only when used, fixed layout behind DM_NVN_REFL_FIXED=1", fail == f1 ? "✓" : "✗");
}
// Every reflection json of a game's shader library image (DM_REFL_IMG=<build>/shader/<platform>/b-<chain>.img), converted in the fixed layout and in the tail layout: the same reflection
// each time, and the tail's bytes against the fixed block's
static void roundtrip_image(const char *path) {
    if (!path || !*path) { printf("SKIP: DM_REFL_IMG unset (a game's shader library image, b-<chain>.img): the round trip over a real library does not run\n"); skipped++; return; }
    romfs_img *m = romfs_image_open(path);
    if (!m) { printf("SKIP: %s does not open as a shader library image: the round trip does not run\n", path); skipped++; return; }
    int f1 = fail; unsigned long shaders = 0, refused = 0, own_fc = 0, own_uv = 0, diff = 0, nb_sum = 0, le8 = 0; uint64_t fixed_bytes = 0, tail_bytes = 0;
    const img_ent *root = &m->e[0];
    for (uint64_t k = root->a; k < root->a + root->b; k++) @autoreleasepool {
        const img_ent *x = &m->e[k]; const char *nm = m->names + x->name;
        if (!x->type || x->nlen < 5 || memcmp(nm + x->nlen - 5, ".json", 5)) continue;
        NSMutableData *d = [NSMutableData dataWithLength:(NSUInteger)x->b];
        if (!romfs_image_read(m->fd, d.mutableBytes, (size_t)x->b, (off_t)x->a)) continue;
        NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:nil];
        if (![j isKindOfClass:[NSDictionary class]] || ![j[@"route"] isEqual:@"B"]) continue;
        nvn_refl a = {0}, b = {0}; char ea[160] = "", eb[160] = "", why[64] = ""; uint64_t t0, b0, t1, b1;
        nvn_refl_set_fixed(1); int ra = nvn_refl_from_json(j, &a, ea, sizeof ea);
        nvn_refl_set_fixed(0); nvn_refl_stats(&t0, &b0); int rb = nvn_refl_from_json(j, &b, eb, sizeof eb); nvn_refl_stats(&t1, &b1);
        shaders++;
        int fc_ok = (b.fc != &nvn_refl_fc_none) == !!memcmp(b.fc, &nvn_refl_fc_none, sizeof *b.fc), uv_ok = (b.uv != &nvn_refl_uv_none) == !!memcmp(b.uv, &nvn_refl_uv_none, sizeof *b.uv);
        if (ra != rb || (ra && strcmp(ea, eb))) { if (diff++ < 5) printf("  %.*s: fixed %d (%s), tail %d (%s)\n", (int)x->nlen, nm, ra, ea, rb, eb); }
        else if (ra) refused++;
        else if (!same_refl(&a, &b, why, sizeof why) || b.cap != b.nb || !fc_ok || !uv_ok) {
            if (diff++ < 5) printf("  %.*s: %s (cap %d, nb %d)\n", (int)x->nlen, nm, why[0] ? why : "tail not at the real length", b.cap, b.nb); }
        else { own_fc += b.fc != &nvn_refl_fc_none; own_uv += b.uv != &nvn_refl_uv_none; nb_sum += (unsigned long)b.nb; le8 += b.nb <= 8; tail_bytes += b1 - b0; fixed_bytes += (uint64_t)FIXED_BLOCK; }
        nvn_refl_free(&a); nvn_refl_free(&b);
    }
    nvn_refl_set_fixed(-1); romfs_image_close(m);
    check("round trip: shaders in the library", 1, shaders > 0);
    check("round trip: shaders whose two conversions differ", 0, (long)diff);
    unsigned long ok = shaders - refused - diff;
    printf("round trip of %lu reflections in %s: %lu the same both ways, %lu refused both ways, %lu differ; %lu with fragment and %lu with vertex readable-tile tables, %lu with 8 bindings or fewer, "
           "%.1f bindings on average; blocks %.1f KB fixed against %.1f KB in tails (%.0f bytes a shader against %.0f)\n", shaders, path, ok, refused, diff, own_fc, own_uv, le8, ok ? (double)nb_sum / ok : 0.0,
           fixed_bytes / 1024.0, tail_bytes / 1024.0, ok ? (double)fixed_bytes / ok : 0.0, ok ? (double)tail_bytes / ok : 0.0);
    printf("%-60s %s\n", "round trip over a real library: fixed and tail layouts agree", fail == f1 ? "✓" : "✗");
}

int main(void) { @autoreleasepool {
    nvn_refl r = {0}; char err[160] = "";
    {   // native image atomics (dmsh_atomic.py): one read_write image, marked atomic by the build; an image the shader only stores to is not
        NSDictionary *j = @{@"route": @"B", @"bindings": @[
            @{@"kind": @"img", @"reg": @2, @"arg_id": @0, @"msl_name": @"cp_i_cb2_4C_r32ui", @"msl_type": @"texture_buffer<uint, access::read_write>", @"atomic": @YES},
            @{@"kind": @"img", @"reg": @3, @"arg_id": @1, @"msl_name": @"cp_i_cb2_4E_r32ui", @"msl_type": @"texture3d<uint, access::write>"}]};
        check("atomic image: conversion succeeds", 0, nvn_refl_from_json(j, &r, err, sizeof err));
        check("atomic image: IMG kind", NVN_RB_IMG, r.b[0].kind);
        check("atomic image: texture type", MTLTextureTypeTextureBuffer, r.b[0].dtt);
        check("atomic image: unsigned format", NVN_DPF_UINT, r.b[0].dpf);
        check("atomic image: written", 1, r.b[0].rw);
        check("atomic image: atomic flag", 1, r.b[0].atom);
        check("stored image: 3D texture type", MTLTextureType3D, r.b[1].dtt);
        check("stored image: no atomic flag", 0, r.b[1].atom);
    }
    {   // readable-tile calls (dmsh_fetch.py): one at an interpolated output, one projective, one at the pixel position times c[6].xy (frag_pos, Splatoon Raiders' ink stamps)
        NSDictionary *j = @{@"route": @"B", @"stage": @"ps", @"bindings": @[], @"fetch": @{@"calls": @[@{@"fc": @0, @"tex_reg": @1, @"varying_locn": @3},
            @{@"fc": @1, @"tex_reg": @2, @"varying_locn": @4, @"proj": @1}, @{@"fc": @2, @"tex_reg": @3, @"frag_pos": @[@[@0, @6, @0], @[@0, @6, @1]]}]}};
        check("fetch calls: conversion succeeds", 0, nvn_refl_from_json(j, &r, err, sizeof err));
        check("fetch calls: three", 3, r.nfc);
        check("fetch calls: projective bit", 2, r.fc_proj);
        check("fetch calls: pixel-position bit", 4, r.fc_fpos);
        check("fetch calls: pixel-position has no interpolated output", 0xff, r.fc->fc_locn[2]);
        check("fetch calls: x scale c[6].x", 6 << 2, r.fc->fc_scale[2][0]);
        check("fetch calls: y scale c[6].y", 6 << 2 | 1, r.fc->fc_scale[2][1]);
        NSDictionary *far = @{@"route": @"B", @"stage": @"ps", @"bindings": @[], @"fetch": @{@"calls": @[@{@"fc": @0, @"tex_reg": @6, @"frag_pos": @[@[@6, @989, @0], @[@6, @989, @1]]}]}};
        check("fetch calls: a vector past c[x][63] converts (Mario Kart World's c6[989])", 0, nvn_refl_from_json(far, &r, err, sizeof err));
        check("fetch calls: slot 6, vector 989, x", 6 << 16 | 989 << 2, r.fc->fc_scale[0][0]);
        NSDictionary *bad = @{@"route": @"B", @"stage": @"ps", @"bindings": @[], @"fetch": @{@"calls": @[@{@"fc": @0, @"tex_reg": @3, @"frag_pos": @[@[@16, @6, @0], @[@0, @6, @1]]}]}};
        check("fetch calls: a uniform slot out of range is refused", 1, nvn_refl_from_json(bad, &r, err, sizeof err) != 0);
    }
    {   int f0 = fail;   // Route A is retired: PC-chain reflection (no route = B) must be rejected
        NSDictionary *pc = @{@"arg_buffer_index": @0, @"bindings": @[@{@"type": @"cbuffer", @"reg": @10, @"arg_id": @0, @"access": @"constant", @"msl_type": @"constant cb1_struct*"}], @"vertex_inputs": @[]};
        check("PC chain reflection (no route = B) fails", 1, nvn_refl_from_json(pc, &r, err, sizeof err) != 0);
        printf("%-60s %s\n", "negative control: PC chain reflection rejected (route A retired)", fail == f0 ? "✓" : "✗");
    }

    // Route B (translation of the original Switch shaders, produced by tools/dmsh_build.py): real reflection ps_models_p#0 / vs_models_v#0, expectations hand-copied from the json text
    {   NSDictionary *j = load("5c1ca4e7c3e4657c_b");
        if (j) { int f1 = fail;
            check("B fragment: conversion succeeds", 0, nvn_refl_from_json(j, &r, err, sizeof err));
            check("B fragment: B flag", 1, r.route_b); check("B fragment: argument buffer slot", 0, r.abi); check("B fragment: binding count", 44, r.nb); check("B fragment: vertex input count", 0, r.nv);
            check("B fragment: has c1", 1, r.has_c1); check("B fragment: c1 length 256 (control section field)", 256, r.c1_len);
            uint32_t c1w; memcpy(&c1w, r.c1, 4); check("B fragment: first c1 word = −√1.5 (0xbf9cc471)", 0xbf9cc471u, c1w);
            struct { int i, kind, reg, aid, rw, dtt, dpf; } w[] = {
                {0, NVN_RB_SUPPORT, 0, 0, 0, -1, -1}, {1, C, 10, 1, 0, -1, -1}, {4, NVN_RB_C1, 0, 4, 0, -1, -1}, {7, NVN_RB_DRV0, 0, 7, 0, -1, -1},
                {8, NVN_RB_DRV2, 0, 8, 0, -1, -1}, {11, NVN_RB_SBUFP, 4, 11, 0, -1, -1}, {13, TB, 8, 13, 0, -1, -1}, {14, T, 41, 14, 0, 2, F},
                {15, S, 3, 15, 0, -1, -1}, {28, T, 39, 28, 0, 3, D}, {34, T, 33, 34, 0, 5, D}, {36, T, 46, 36, 0, 7, F}};
            for (unsigned k = 0; k < sizeof w / sizeof *w; k++) {
                const nvn_rbind *g = &r.b[w[k].i]; char m[64];
                snprintf(m, sizeof m, "B binding[%d] kind", w[k].i); check(m, w[k].kind, g->kind);
                snprintf(m, sizeof m, "B binding[%d] slot", w[k].i); check(m, w[k].reg, g->reg);
                snprintf(m, sizeof m, "B binding[%d] argument index", w[k].i); check(m, w[k].aid, g->aid);
                snprintf(m, sizeof m, "B binding[%d] read-write", w[k].i); check(m, w[k].rw, g->rw);
                if (w[k].dtt >= 0) { snprintf(m, sizeof m, "B binding[%d] dummy texture type", w[k].i); check(m, w[k].dtt, g->dtt);
                                     snprintf(m, sizeof m, "B binding[%d] dummy texture pixel class", w[k].i); check(m, w[k].dpf, g->dpf); }
            }
            printf("%-60s %s\n", "B fragment ps_models_p#0: 44 bindings (incl. support / c1 / driver section / storage buffer pointers)", fail == f1 ? "✓" : "✗");
        } }
    {   NSDictionary *j = load("54f730a6c0efc118_b");
        if (j) { int f1 = fail;
            check("B vertex: conversion succeeds", 0, nvn_refl_from_json(j, &r, err, sizeof err));
            check("B vertex: binding count", 2, r.nb); check("B vertex: input count", 4, r.nv); check("B vertex: c1 length 0 (control section +0x704 − +0x700) → no c1", 0, r.has_c1);
            for (int i = 0; i < 4 && i < r.nv; i++) { char m[48]; snprintf(m, sizeof m, "B vertex input[%d] attribute = location", i); check(m, i, r.v[i].nvn); check(m, i, r.v[i].loc); check("B vertex component float", NVN_CT_FLOAT, r.v[i].ct); }
            check("B vertex: binding[0] uniform slot 0", 0, r.b[0].reg); check("B vertex: binding[1] uniform slot 3", 3, r.b[1].reg);
            printf("%-60s %s\n", "B vertex vs_models_v#0: 4 attributes (attribute = MSL attribute)", fail == f1 ? "✓" : "✗");
        } }
    {   int f1 = fail;   // an array of handles in a uniform buffer (Paper Mario: The Thousand-Year Door b352f7af1c86e9fa_b, its last four bindings): array<…, 32> takes 32 argument entries each
        NSDictionary *j = @{@"route": @"B", @"bindings": @[
            @{@"kind": @"tex_ubo", @"reg": @11, @"off": @16, @"arg_id": @14, @"msl_name": @"fp_t_cb14_4", @"msl_type": @"texture2d<float>"},
            @{@"kind": @"samp_ubo", @"reg": @11, @"off": @16, @"arg_id": @15, @"msl_name": @"fp_t_cb14_4Smplr", @"msl_type": @"sampler"},
            @{@"kind": @"tex_ubo", @"reg": @11, @"off": @0, @"arg_id": @16, @"msl_name": @"fp_t2d_cb14_0", @"msl_type": @"array<texture2d<float>, 32>"},
            @{@"kind": @"samp_ubo", @"reg": @11, @"off": @0, @"arg_id": @48, @"msl_name": @"fp_t2d_cb14_0Smplr", @"msl_type": @"array<sampler, 32>"}]};
        check("B handle array: conversion succeeds", 0, nvn_refl_from_json(j, &r, err, sizeof err));
        check("B handle array: single texture n", 0, r.b[0].n); check("B handle array: single texture offset", 16, r.b[0].off); check("B handle array: single sampler n", 0, r.b[1].n);
        check("B handle array: texture kind", NVN_RB_TEXU, r.b[2].kind); check("B handle array: texture n", 32, r.b[2].n); check("B handle array: texture dummy type 2D", 2, r.b[2].dtt); check("B handle array: texture slot", 11, r.b[2].reg);
        check("B handle array: sampler kind", NVN_RB_SAMPU, r.b[3].kind); check("B handle array: sampler n", 32, r.b[3].n); check("B handle array: bindless", 1, r.bindless);
        printf("%-60s %s\n", "B array of 32 handles in uniform slot 11 (texture + sampler)", fail == f1 ? "✓" : "✗");
    }
    {   int f1 = fail;   // handles in a uniform buffer beyond textures: Unreal Engine 5.4 on the Switch 2 keeps images and buffer textures there, and ORs a texture and a sampler word in either order
        NSDictionary *j = @{@"route": @"B", @"bindings": @[
            @{@"kind": @"img_ubo", @"reg": @0, @"off": @8, @"arg_id": @0, @"msl_name": @"cp_i_cb3_2_", @"msl_type": @"texture_buffer<float, access::write>", @"atomic": @YES},
            @{@"kind": @"tbuf_ubo", @"reg": @1, @"off": @16, @"arg_id": @1, @"msl_name": @"cp_tb_cb4_4", @"msl_type": @"texture_buffer<uint>"},
            @{@"kind": @"tex_ubo", @"reg": @0, @"off": @88, @"soff": @0, @"sreg": @2, @"arg_id": @2, @"msl_name": @"fp_t_cb262147_10000016", @"msl_type": @"texture2d<float>"},
            @{@"kind": @"tex_ubo", @"reg": @0, @"off": @24, @"arg_id": @3, @"msl_name": @"fp_t_cb3_6", @"msl_type": @"texture2d<float>"}]};
        check("B uniform handles: conversion succeeds", 0, nvn_refl_from_json(j, &r, err, sizeof err));
        check("B uniform handles: image kind", NVN_RB_IMGU, r.b[0].kind); check("B uniform handles: image offset", 8, r.b[0].off); check("B uniform handles: image written", 1, r.b[0].rw); check("B uniform handles: image atomic", 1, r.b[0].atom);
        check("B uniform handles: buffer texture kind", NVN_RB_TBUFU, r.b[1].kind); check("B uniform handles: buffer texture slot", 1, r.b[1].reg); check("B uniform handles: bindless", 1, r.bindless);
        check("B uniform handles: other word at byte 0 of slot 2", 1, r.b[2].soff); check("B uniform handles: its slot", 2, r.b[2].sreg); check("B uniform handles: one word has no other", 0, r.b[3].soff);
        printf("%-60s %s\n", "B images, buffer textures and two-word handles in uniform slots", fail == f1 ? "✓" : "✗");
    }
    {   int f1 = fail;
        NSDictionary *b1 = @{@"route": @"B", @"bindings": @[@{@"kind": @"foo", @"arg_id": @0, @"msl_name": @"x", @"msl_type": @"constant _16*"}]};
        NSDictionary *b2 = @{@"route": @"B", @"bindings": @[@{@"kind": @"tex", @"reg": [NSNull null], @"arg_id": @0, @"msl_name": @"fp_t_x", @"msl_type": @"texture2d<float>"}]};
        check("B unknown kind fails", 1, nvn_refl_from_json(b1, &r, err, sizeof err) != 0);
        check("B texture without a resolved slot fails", 1, nvn_refl_from_json(b2, &r, err, sizeof err) != 0);
        printf("%-60s %s\n", "B negative control: unknown kind / missing slot", fail == f1 ? "✓" : "✗");
    }
    layout_cases(&r);
    roundtrip_image(getenv("DM_REFL_IMG"));
    nvn_refl_free(&r);
    printf("== %d checks, %d failed, %d sample files missing (those checks skipped) ==\n", n, fail, skipped);
    return fail != 0;
} }
