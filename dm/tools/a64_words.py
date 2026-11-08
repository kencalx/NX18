#!/usr/bin/env python3
"""AArch64 words: the targets of the PC-relative forms and the pairing of an adrp with the instruction that adds its page's low bits. Shared by scripts/cheat_anchor.py
(cheats anchored on the game's code) and game_mods.py (a mod's code must branch inside the module's code: an iPhone runs only signed pages). Plain functions of a 32-bit
word and its address; nothing here reads a file."""


def signed(n: int, bits: int) -> int:
    """The two's-complement value of the low bits of n (an instruction's signed immediate field)."""
    return n - (1 << bits) if n & (1 << (bits - 1)) else n


def branch_target(w: int, pc: int) -> int | None:
    """Target of a B / BL at pc, or None for any other word (the only PC-relative forms cheat_anchor re-encodes)."""
    if w & 0x7c000000 == 0x14000000: return pc + signed(w & 0x3ffffff, 26) * 4
    return None


def direct_branch_target(w: int, pc: int) -> int | None:
    """Target of a direct branch at pc: B / BL (imm26), B.cond / CBZ / CBNZ (imm19), TBZ / TBNZ (imm14); None for any other word. An indirect one
    (BR / BLR / RET, a register's target) has none."""
    t = branch_target(w, pc)
    if t is not None: return t
    if w & 0xff000010 == 0x54000000 or w & 0x7e000000 == 0x34000000: return pc + signed((w >> 5) & 0x7ffff, 19) * 4
    if w & 0x7e000000 == 0x36000000: return pc + signed((w >> 5) & 0x3fff, 14) * 4
    return None


def pc_relative_target(w: int, pc: int) -> int | None:
    """Target of any PC-relative word (B / BL, B.cond, CBZ / CBNZ, TBZ / TBNZ, ADR, ADRP's page, literal load), else None."""
    t = direct_branch_target(w, pc)
    if t is not None: return t
    if w & 0x1f000000 == 0x10000000:
        imm = signed(((w >> 29) & 3) | ((w >> 5) & 0x7ffff) << 2, 21)
        return (pc & ~0xfff) + (imm << 12) if w & 0x80000000 else pc + imm
    if w & 0x3b000000 == 0x18000000: return pc + signed((w >> 5) & 0x7ffff, 19) * 4
    return None


def is_adrp(w: int) -> bool:
    """True for an ADRP (ADR's page form: pc_relative_target gives its page)."""
    return w & 0x9f000000 == 0x90000000


def adrp_user_lo(u: int, rd: int) -> int | None:
    """The low page offset an add (64-bit immediate) or a ldr / str (unsigned offset) with base register rd adds to an
    adrp's page, or None when u is not such an instruction (the pairing rule of nso_match and nso_fnmap)."""
    if (u >> 5) & 31 != rd: return None
    if u & 0xff800000 == 0x91000000: return (u >> 10) & 0xfff
    if u & 0x3b000000 == 0x39000000:
        sh = 4 if u & 0x04800000 == 0x04800000 else u >> 30   # 128-bit SIMD / FP registers scale by 16
        return ((u >> 10) & 0xfff) << sh
    return None


def ends_pairing(u: int, rd: int) -> bool:
    """True when u ends the search for an adrp's user: any branch, or an instruction that writes rd other than a store.
    Conservative on purpose: a missed pair only costs one reference, a wrong pair would anchor a wrong address."""
    if u & 0x7c000000 == 0x14000000 or u & 0xff000010 == 0x54000000 or u & 0x7e000000 in (0x34000000, 0x36000000): return True
    if u & 0xfffffc1f in (0xd61f0000, 0xd63f0000, 0xd65f0000): return True    # br / blr / ret
    is_store = u & 0x3b000000 == 0x39000000 and not (u >> 22) & 1             # str (unsigned offset): Rt is read, not written
    return u & 31 == rd and not is_store
