# Luigi's Mansion 3 (0100DCA0064A6000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py; STUBS as described there
# ("Registered patches", "Stubs"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADDI, ADRP, B, LDRX

# The Ghost Gallery crash (upstream NXNative 089c1e5b1, seedds with Eduard Rotaru; upstream issue #672): SIGSEGV / SIGBUS at main+0x4723a0 / +0x4723c8 (once +0x47241c in
# normal play) on 1.4.0. Inside RenderManager::RenderFrame (main+0x464920 on 1.4.0) the pass over ECS component list 0x3cd (vtable 0x16babf0: screen-space glow / halo
# billboards) projects up to 5 bones of each entity's model ([comp + 0xb8] -> vtable +0x98 -> skeleton instance) and builds a 4-vertex quad. For each bone hash it takes the
# skeleton handle ([x0]), indexes the engine's handle table (main+0x18868e0: 0x20000 pointers indexed by handle & 0x1ffff, a u16 generation per slot at
# table + 0xffff8 + slot * 2 compared with handle >> 17), binary-searches the skeleton's sorted {hash, index} pairs (count +0x14, offset +0xc) and reads the bone matrix at
# [x0 + 0x10] + index * 64.
# Two bugs in this reader (upstream's reading, by disassembly of the game's own main):
# 1. Unlike 113 other skeleton handle lookups in main (component 0x3cd's own activation helper main+0x48b7b0 among them), it checks neither the handle's generation nor the
#    slot pointer. When ProcessBundleUnloadQueue (main+0x96ece0) frees a ghost's skeleton while its component 0x3cd is still registered, the handle-free routine
#    (main+0x7cb760) puts a free-list link (next_slot | 1) in the slot and bumps its generation, so the lookup reads an odd non-pointer, or an unrelated object once reused.
# 2. A skeleton with no bone pairs, or a hash not found, leaves the index at -1, and the matrix read zero-extends it: +0xffffffff * 64 (+256 GiB), a fault at +0x47241c.
# The stub checks x0 != 0, a non-zero generation equal to table + 0xffff8 + slot * 2, a non-null even slot pointer and a non-zero pair count, then goes on with the search at
# `ldr w11, [x9, #0xc]` (lookup + 0x1c). Any failed check, and a missing hash (the search's b.ne and its mov wN, #-1 now branch to the same exit), restores the component
# loop's index register from its stack slot, sets x22 = 0x100000000 and branches to the loop's own clean skip (main+0x4730b0), so no quad is built from uninitialized
# coordinates.
# NX 18 has no function-matched STUBS (upstream's MATCH_STUBS, which places this on 1.0.0 and 1.4.0 by RenderManager::RenderFrame's fingerprint), so this is a STUBS entry
# of the 1.4.0 main alone (its build ID is the profile's, game.tsv) at upstream's offsets. Without the game's files here, the offsets and original words are upstream's (its
# full rewrites of both mains and instruction replay of every path, 2026-11-28); patch_nso.py asserts the three sites' original words, that none is a rewrite site, and that
# the adrp in the lookup and the one in the handle-free routine name the same table (main+0x18868e0 in upstream's reading), before anything is written. Upstream's live Ghost Gallery retest is still pending.
handle_table = 0x18868e0   # the engine's handle table (1.4.0, upstream's reading; the stub takes it from the lookup's adrp, which must name what the handle-free routine's does)
at_140 = {'lookup': 0x464920 + 0xda34,       # ldr w8, [x0]: the skeleton handle
          'bne': 0x464920 + 0xdacc,          # b.ne +0x14: the search's not-equal exit, into the matrix read with index -1
          'not_found': 0x464920 + 0xdadc,    # mov w28, #-1
          'not_found_orig': '1c008012',
          'skip': 0x464920 + 0xe790,         # the component loop's clean skip
          'idx_reg': 16, 'idx_sp': 0xf0,     # the loop's component index, x16, kept at [sp, #0xf0]
          'handle_free': 0x7cb760}           # the handle-free routine: its adrp at +0x24 names the same table


def _cbz(is64, reg, frm, to):
    off = to - frm
    assert -(1 << 20) <= off < (1 << 20) and off % 4 == 0
    return (0xB4000000 if is64 else 0x34000000) | (((off >> 2) & 0x7FFFF) << 5) | reg


def _bne(frm, to):
    off = to - frm
    assert -(1 << 20) <= off < (1 << 20) and off % 4 == 0
    return 0x54000001 | (((off >> 2) & 0x7FFFF) << 5)


def _tbnz_w(reg, bit, frm, to):
    off = to - frm
    assert -(1 << 15) <= off < (1 << 15) and off % 4 == 0
    return 0x37000000 | ((bit & 0x1F) << 19) | (((off >> 2) & 0x3FFF) << 5) | reg


def skeleton_guard(ctx, at):
    """The billboard skeleton lookup's guard (at: the build's offsets, as at_140)"""
    lookup, bne_site, not_found, skip_target = at['lookup'], at['bne'], at['not_found'], at['skip']
    got = ctx.address(lookup + 8)
    assert got == ctx.address(at['handle_free'] + 0x24), 'billboard skeleton lookup: the handle table address disagrees with the handle-free routine'
    ctx.site(lookup, '080040b9')                 # ldr w8, [x0]
    ctx.site(bne_site, 'a1000054')               # b.ne +0x14
    ctx.site(not_found, at['not_found_orig'])    # mov w28 / w27, #-1

    start = ctx.here()
    skip = start + 18 * 4
    ctx.emit(_cbz(True, 0, ctx.here(), skip))          # cbz x0, skip
    ctx.emit(0xB9400008)                               # ldr w8, [x0]
    ctx.emit(0xD3517D0A)                               # ubfx x10, x8, #17, #15      the handle's generation
    ctx.emit(_cbz(False, 10, ctx.here(), skip))        # cbz w10, skip
    ctx.emit(0x92404108)                               # and x8, x8, #0x1ffff       the slot
    ctx.emit(ADRP(9, ctx.here(), got))                 # adrp x9, table
    ctx.emit(ADDI(9, 9, got & 0xFFF))                  # add x9, x9, #(table & 0xfff)
    ctx.emit(0x8B08052B)                               # add x11, x9, x8, lsl #1
    ctx.emit(0x321D43EC)                               # mov w12, #0xffff8          the generation table
    ctx.emit(0x786C696B)                               # ldrh w11, [x11, x12]
    ctx.emit(0x6B0B015F)                               # cmp w10, w11
    ctx.emit(_bne(ctx.here(), skip))                   # b.ne skip                  a freed or reused slot
    ctx.emit(0xF8687929)                               # ldr x9, [x9, x8, lsl #3]
    ctx.emit(_cbz(True, 9, ctx.here(), skip))          # cbz x9, skip               a null slot
    ctx.emit(_tbnz_w(9, 0, ctx.here(), skip))          # tbnz w9, #0, skip          a free-list link
    ctx.emit(0xB940152A)                               # ldr w10, [x9, #0x14]       the bone pair count
    ctx.emit(_cbz(False, 10, ctx.here(), skip))        # cbz w10, skip              no bones
    ctx.emit(B(ctx.here(), lookup + 0x1C))             # b lookup + 0x1c            ldr w11, [x9, #0xc]: the search
    assert ctx.here() == skip
    ctx.emit(LDRX(at['idx_reg'], 31, at['idx_sp'] // 8))   # ldr xN, [sp, #off]   the component loop's index, which the bone loop overwrote
    ctx.emit(0xD2C00036)                                   # movz x22, #1, lsl #32
    ctx.emit(B(ctx.here(), skip_target))                   # the loop's clean skip: no quad for this component

    ctx.put(lookup, [B(lookup, start)], 'billboard skeleton lookup (Ghost Gallery crash): check the handle\'s generation, the slot pointer and the bone count first')
    ctx.put(bne_site, [0x54000081], 'billboard skeleton lookup (Ghost Gallery crash): a missing bone hash goes to the skip, not on with index -1')
    ctx.put(not_found, [B(not_found, skip)], 'billboard skeleton lookup (Ghost Gallery crash): skip the component when the bone hash is not found')


STUBS = {'79e5950ffa85acf63e28c9aec051eac2': lambda ctx: skeleton_guard(ctx, at_140)}   # 1.4.0 (v327680) main

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md)
BINDING = [
    {'what': 'RenderManager::RenderFrame\'s billboard skeleton lookup checks the handle and skips missing bones (the Ghost Gallery crash)', 'now': 'build', 'goal': 'game', 'purpose': 'runtime',
     'why': "the game's own billboard pass reads a skeleton handle without the generation check of the game's other lookups and goes on with index -1 for a missing bone hash; "
            "upstream NXNative 089c1e5b1 places it by the function's fingerprint on 1.0.0 and 1.4.0",
     'blocked': 'NX 18 has no function-matched STUBS (upstream\'s MATCH_STUBS): a STUBS entry of the 1.4.0 main at upstream\'s offsets, its three sites\' words and the handle table\'s address asserted',
     'checked': "upstream's: 1.0.0 and 1.4.0 mains by disassembly, full rewrites and instruction replay of every path (2026-11-28); not on the game's files here"},
]
