"""The rewriter's per-build patch files (dm/tools/sdk_patches.py, dm/games/<id>/patches.py, loaded by dm/tools/patch_nso.py): no build ID is claimed twice, every entry has
the form patch_nso.py expects, a game's file names only builds of its own profile's non-sdk modules, sdk_patches.py only sdk modules some profile ships; and the NSP script's
rewrite step keys its reuse on the patch files of the game's builds only. No game files needed (temporary files only in a temporary folder)."""
import ast
import glob
import importlib.util
import os
from pathlib import Path
import re
import shutil
import struct
import sys
import tempfile
from typing import Any
import runpy
import unittest
from unittest import mock

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO / 'dm/tools')); sys.path.insert(0, str(REPO / 'dm/games'))
import game   # noqa: E402
import docs_patches   # noqa: E402

FILES = [REPO / 'dm/tools/sdk_patches.py'] + sorted((REPO / 'dm/games').glob('*/patches.py'))


def load(path, n):
    spec = importlib.util.spec_from_file_location(f'patches_{n}', path); m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
    return m


MODS = {p: load(p, n) for n, p in enumerate(FILES)}
HEX = re.compile(r'[0-9a-f]+$')

# Execute the driver's actual file discovery and registry without loading a game image.
source = REPO / 'dm/tools/patch_nso.py'; tree = ast.parse(source.read_text())
start = next(i for i, n in enumerate(tree.body) if isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == 'SHARED')   # the shared files, then PATCH_FILES
end = next(i for i, n in enumerate(tree.body[start:], start) if isinstance(n, ast.Assign) and ast.unparse(n.targets[0]) == 'BUILD_ID')
REGISTRY_CODE = compile(ast.Module(body=tree.body[start:end], type_ignores=[]), str(source), 'exec')


def builds_of(g):   # {build ID: module name} of a profile's build rows (a profile or its title ID)
    return {bid: m for row in (game.load(g) if isinstance(g, str) else g).builds().values() for m, bid in row.items() if m != 'display'}


class Registry(unittest.TestCase):
    def test_no_build_claimed_twice(self):
        for kind in ('CUTS', 'OBS', 'FRAME_STEP', 'STUBS', 'CAPABILITIES'):
            seen = {}
            for p, m in MODS.items():
                for bid in getattr(m, kind, {}):
                    self.assertNotIn(bid, seen, f'{kind} of {bid} in {seen.get(bid)} and {p}'); seen[bid] = p

    def test_entry_forms(self):
        for p, m in MODS.items():
            for bid, cuts in getattr(m, 'CUTS', {}).items():
                self.assertRegex(bid, r'^[0-9a-f]{32}$')
                for off, ob, nb, why in cuts:
                    self.assertTrue(isinstance(off, int) and HEX.match(ob) and HEX.match(nb) and len(ob) == len(nb) and len(ob) % 8 == 0 and why, f'{p} {bid} {off:#x}')
            for bid, gates in getattr(m, 'OBS', {}).items():
                for off, oid, word, why in gates:
                    self.assertTrue(isinstance(off, int) and isinstance(oid, int) and HEX.match(word) and len(word) == 8 and why, f'{p} {bid} {off:#x}')
            for kind in ('FRAME_STEP', 'STUBS'):
                for bid, fn in getattr(m, kind, {}).items():
                    self.assertTrue(callable(fn), f'{p} {kind} {bid}')
            for bid, names in getattr(m, 'CAPABILITIES', {}).items():
                self.assertRegex(bid, r'^[0-9a-f]{32}$')
                self.assertEqual(len(names), len(set(names)))
                for name in names: self.assertRegex(name, r'^[A-Z][A-Z0-9_]*$')
            self.assertFalse({k for k in vars(m) if k.isupper() and k not in ('CUTS', 'OBS', 'FRAME_STEP', 'STUBS', 'CAPABILITIES', 'MATCH_CUTS', 'MATCH_FRAME_STEP', 'MATCH_OBS', 'MATCH_SURVEY', 'BINDING')} - set(dir(__import__('nso_asm'))),
                             f'{p}: a table patch_nso.py does not read')
            # every patch file states each patch's binding (docs_patches.py "Binding"), and no goal is tighter than the binding now
            self.assertTrue(getattr(m, 'BINDING', None), f'{p}: no BINDING (docs/agents/game-patches.md, "Binding")')
            for e in m.BINDING: self.assertIsNone(docs_patches.binding_error(e, own=p.name == 'patches.py'), f'{p}')

    def test_unreviewed_goals_stay_in_a_games_own_build_bound_patches(self):
        e = {'what': 'a cut', 'now': 'build', 'goal': 'unreviewed', 'purpose': 'memory', 'why': 'found at bring-up'}
        self.assertIsNone(docs_patches.binding_error(e, own=True))
        self.assertIsNotNone(docs_patches.binding_error(e))   # sdk_patches.py, host rows, translator rules and switches review theirs
        self.assertIsNotNone(docs_patches.binding_error(dict(e, now='game'), own=True))
        self.assertIsNotNone(docs_patches.binding_error(dict(e, blocked='why'), own=True))
        self.assertEqual(docs_patches.status(e), 'unreviewed')
        reviewed = (dict(e, goal='sdk'), [], {'a', 'b'})
        self.assertLess(docs_patches.payoff(reviewed), docs_patches.payoff((e, [], {'a', 'b', 'c'})))   # after every reviewed gap

    def test_function_match_rules(self):
        from nso_match import validate
        for p, m in MODS.items():
            for module, rules in getattr(m, 'MATCH_CUTS', {}).items():
                if p.name == 'sdk_patches.py':   # SDK-wide: Nintendo's sdk module of any game
                    self.assertEqual(module, 'sdk')
                else:
                    self.assertEqual(p.name, 'patches.py')
                    self.assertIn(module, game.load(p.parent.name).words('modules'))
                    self.assertNotEqual(module, 'sdk', 'SDK fixes belong in sdk_patches.py, for every game')
                self.assertTrue(rules)
                for rule in rules: validate(rule)

    def test_function_matched_gates(self):
        # observation gates placed by function (MATCH_OBS), in a game's own patches.py: each rule valid (nso_match.validate_gates)
        from nso_match import validate_gates
        for p, m in MODS.items():
            for module, rules in getattr(m, 'MATCH_OBS', {}).items():
                self.assertEqual(p.name, 'patches.py', f'{p}: gates placed by function belong to a game')
                self.assertIn(module, game.load(p.parent.name).words('modules'), f'{p}: MATCH_OBS of {module!r}, a module the profile lacks (patch_nso.py would never read it)')
                self.assertTrue(rules)
                for rule in rules: validate_gates(rule)

    def test_engine_rules(self):
        # engine-wide rules (engine_patches.py): function-matched cuts of a game's own modules, never of Nintendo's sdk, whatever the profile
        from nso_match import validate
        m = runpy.run_path(str(REPO / 'dm/tools/engine_patches.py'))
        self.assertTrue(m['MATCH_CUTS'])
        self.assertFalse({k for k in m if k.isupper()} - {'MATCH_CUTS'}, 'engine_patches.py holds only MATCH_CUTS: no build-keyed tables')
        for module, rules in m['MATCH_CUTS'].items():
            self.assertNotEqual(module, 'sdk', "Nintendo's SDK fixes belong in sdk_patches.py")
            for rule in rules: validate(rule)

    def test_function_surveys(self):
        # read-only surveys (MATCH_SURVEY), in a game's own patches.py, of a module its profile loads, each valid (nso_match.validate_survey), beside a MATCH_CUTS rule they serve
        from nso_match import validate_survey
        for p, m in MODS.items():
            for module, entries in getattr(m, 'MATCH_SURVEY', {}).items():
                self.assertEqual(p.name, 'patches.py', f'{p}: surveys belong to a game')
                self.assertIn(module, game.load(p.parent.name).words('modules'))
                self.assertTrue(getattr(m, 'MATCH_CUTS', {}).get(module), f'{p}: a survey of {module!r} runs only after a MATCH_CUTS rule of it misses')
                for entry in entries: validate_survey(entry)

    def test_xenoblade_x_switch_2_takes_the_switch_1_allocator_rule(self):
        # Xenoblade Chronicles X Switch 2 Edition: upstream's rule for the Switch 1 program (NXNative b32d0bf3b, dm/games/0100453019AA8000/patches.py), its fingerprints and arena
        # cuts unchanged; only the outer region is 12 GB (movz x0,#0x3,lsl#32), which the profile's alias region holds beside the SDK's node area and the game's 64 MB region
        m = MODS[REPO / 'dm/games/0400453019AA8001/patches.py']
        (rule,) = m.MATCH_CUTS['main']
        arena, outer = rule['functions']
        self.assertEqual((arena['size'], arena['fingerprints']), (696, ['b00403a9284d46d15659fc765ce9c0d0474170eb6b9fe2369a4fb69f5458bba2']))
        self.assertEqual([c[:3] for c in arena['cuts']], [(0x10, 'e98340b2', 'e9ff9fd2'), (0x20, '4900a0f2', '4900a4f2'), (0xa4, 'ea7b5fb2', 'ea8361b2'),
                                                          (0xac, 'caffbff2', 'caffbbf2'), (0xbc, '2800c0f2', '4800a4f2')])
        self.assertEqual((outer['size'], outer['fingerprints']), (16, ['df6920c64d84efc7c01f51f9b17e9bd252f9058ed5903bfe6fd5a7ff1a7f4ca3']))
        (off, old, new, _), = outer['cuts']
        word = struct.unpack('<I', bytes.fromhex(new))[0]
        self.assertEqual((off, old), (0, 'e001c0d2'))
        self.assertEqual(word & 0xffe0001f, 0xd2c00000, 'movz x0, #imm, lsl #32')
        region = ((word >> 5) & 0xffff) << 32
        self.assertEqual(region, 12 << 30)
        g = game.load('0400453019AA8001')
        alias, reserve, stack = g.int('mem_alias'), g.int('mem_reserve'), g.int('mem_stack')
        self.assertLessEqual(0x3e00000 + region + (64 << 20) + (256 << 20), alias, 'node area, the 12 GB region, the 64 MB region and room for later ones')
        self.assertEqual(reserve - alias - stack - 0x10000000, 128 << 20, 'the heap region as before the larger alias region')
        self.assertLessEqual(reserve, 0x550000000, "no larger than Fire Emblem Fortune's Weave's block, which plays on the iPhone 18 Pro Max")

    def test_unity_stream_buffer_writer_sleep_fingerprints(self):
        # the writer-sleep function's fingerprints: FFCC 1.0.3, Raging Loop / FFCC 1.0.0's log helper, a third body, and Thronebreaker 1.0.2's (upstream ffe0d357b); one cut, the same
        # ldr -> ldar at +0x168 for all of them (a fingerprint is a whole function, so one of another body never reaches the cut's check bytes)
        m = runpy.run_path(str(REPO / 'dm/tools/engine_patches.py'))
        rule = next(r for r in m['MATCH_CUTS']['main'] if r['name'].startswith('Unity 2018 ThreadedStreamBuffer'))
        sleep = next(f for f in rule['functions'] if f['size'] == 576)
        self.assertEqual(len(sleep['fingerprints']), 4)
        self.assertEqual(len(set(sleep['fingerprints'])), 4, 'no fingerprint twice')
        self.assertIn('e1bff2e6d23005e70825edfaa2b79abb67f475c3615a6d364cebc76befd49815', sleep['fingerprints'])   # Thronebreaker 1.0.2 main+0x2ba7290
        self.assertEqual([c[:3] for c in sleep['cuts']], [(0x168, '290140b9', '29fddf88')])
        self.assertEqual(sum(len(f['cuts']) for f in rule['functions']), 8, 'eight sites in four functions')

    def test_function_matched_frame_steps(self):
        # one frame step per main, in a game's own patches.py; its stub writes only inside the function it was matched by and the other functions it names (docs_patches.frame_step_sites
        # with that base), and writes no site in another function it could not find (ctx.others[label] None)
        from nso_match import validate_stub
        for p, m in MODS.items():
            for module, rules in getattr(m, 'MATCH_FRAME_STEP', {}).items():
                self.assertEqual((p.name, module), ('patches.py', 'main'), f'{p}')
                self.assertTrue(rules); self.assertEqual(len({r['name'] for r in rules}), 1, f'{p}: a main has one frame step')
                for rule in rules:
                    validate_stub(rule)
                    if 'calls' in rule:   # anchored: with each reviewed result of its find, the stub writes at the function's start plus the offset it found
                        for found in rule['reviewed']:
                            sites, _, _, _ = docs_patches.frame_step_sites(rule['stub'], base=0x100000, found=found)
                            self.assertTrue(sites, f'{p}: {rule["name"]} writes no site')
                            self.assertTrue(all(0x100000 <= off < 0x100000 + 0x100000 for off, _ in sites), f'{p}: {rule["name"]} writes outside its function')
                        continue
                    sites, _, in_others, _ = docs_patches.frame_step_sites(rule['stub'], base=0x100000, others=rule.get('others', {}))
                    self.assertTrue(sites, f'{p}: {rule["name"]} writes no site')
                    for off, why in sites: self.assertTrue(0x100000 <= off < 0x100000 + rule['size'], f'{p}: {rule["name"]} site {off:#x} outside its function')
                    for label, got in in_others.items():   # a function named only as a precondition (its fields read) has no site
                        for off, why in got: self.assertTrue(0 <= off < rule['others'][label]['size'], f'{p}: {label} site {off:#x} outside its function')
                    if rule.get('others'):   # none found: the stub leaves those parts out
                        rest = []
                        ctx = docs_patches.types.SimpleNamespace(here=lambda: 0x8000000, emit=lambda w: None, site=lambda off, orig: None, put=lambda off, words, why, rest=rest: rest.append(off),
                                                                 state=0x9000000, render_scale=0, step_max=0, base=0x100000, others={label: None for label in rule['others']}, capabilities=set())
                        rule['stub'](ctx)
                        self.assertTrue(all(0x100000 <= off < 0x100000 + rule['size'] for off in rest), f'{p}: {rule["name"]} writes outside its function without its others')

    def test_mario_kart_world_declares_its_largest_step(self):
        # its stub caps the step it gives the game at 2 (mov w8,#2; csel ls), the game's own intervals, and says so (ctx.step_max), or the host holds frames 3 vsyncs while the game
        # steps 2 (slow motion) and loses the debt it pays back with a step of 3 (upstream NXNative 1e3fd031)
        m = MODS[REPO / 'dm/games/0400C3F00006E000/patches.py']
        words = []
        ctx = docs_patches.types.SimpleNamespace(here=lambda: 0x8000000, emit=words.append, site=lambda off, orig: None, put=lambda off, words, why: None, state=0x9000000,
                                                 render_scale=0, step_max=0, base=0x100000, others={}, found=None, capabilities=set(), address=lambda off: 0)
        m.MATCH_FRAME_STEP['main'][0]['stub'](ctx)
        self.assertIn(0x52800048, words)   # mov w8,#2: the cap
        self.assertEqual(ctx.step_max, 2)

    def test_sdk_wide_rules_change_what_their_names_say(self):
        # the rules were taken from registered SDK cuts, and the builds they reproduce exactly have no row any more: each cut replaces the constant its rule names (0x3fe00000, the node
        # area; 0x400000, 0x2000000 and 0x40000000, the alignments of the 4 MB, 32 MB and 1 GB classes; as movz or orr from wzr) with the reviewed one (62 MB; SDK 20's 2 MB) in the same register
        m = MODS[REPO / 'dm/tools/sdk_patches.py']
        words = {m.node_area: ({'08fca752', '09fca752', 'e8230b32', 'e9230b32'}, {'087ca052', '097ca052'}),
                 m.alignment: ({'0808a052', 'e8030a32', '0b40a052', 'eb030732', '0a00a852', 'ea030232'}, {'0804a052', '0b04a052', '0a04a052'})}
        for rule in m.MATCH_CUTS['sdk']:
            old_words, new_words = words[rule['name']]
            for delta, old, new, why in rule['cuts']:
                self.assertIn(old, old_words, why); self.assertIn(new, new_words, why)
                self.assertEqual(int(old[:2], 16) & 31, int(new[:2], 16) & 31, why)

    def test_game_files_name_their_own_builds(self):
        for p, m in MODS.items():
            if p.name != 'patches.py' or not (p.parent / 'game.tsv').is_file(): continue
            own = builds_of(p.parent.name)
            for kind in ('CUTS', 'OBS', 'FRAME_STEP', 'STUBS', 'CAPABILITIES'):
                for bid in getattr(m, kind, {}):
                    self.assertIn(bid, own, f'{p}: {kind} of {bid}, which is no build of profile {p.parent.name}')
                    self.assertNotEqual(own[bid], 'sdk', f'{p}: {bid} is an sdk build; its patches go in dm/tools/sdk_patches.py')

    def test_sdk_file_names_sdk_builds(self):
        sdk = {bid for g in game.all_games() for bid, m in builds_of(g).items() if m == 'sdk'}
        m = MODS[REPO / 'dm/tools/sdk_patches.py']
        self.assertFalse(getattr(m, 'OBS', {}) or getattr(m, 'FRAME_STEP', {}) or getattr(m, 'STUBS', {}))
        for bid in m.CUTS: self.assertIn(bid, sdk, f'sdk_patches.py: {bid} is no sdk build of any profile')


# The render-scale stubs that read the host's live factor at state +0x14 (heat ladder step 4, hle_nvn.c scale_set): run on a small evaluator of the instructions they use, with
# the player's Render scale at +0x10, the factor at +0x14 and the game's own scale in its register, so what each combination draws at is checked, not only the words
AREA, STATE = 0x8000000, 0x9000000
def f32(x): return struct.unpack('<f', struct.pack('<f', x))[0]


def a64(code, pc, x, s, mem, stop):
    """Run the stub's words (code at AREA) from pc until a branch leaves the patch area: returns that target; x / s (registers) and the flags change in place. mem(addr, size)
    reads memory. Only the instructions the render-scale stubs use: adrp, ldr (unsigned offset: w, x, s), fcmp, b.cond, b, cbz / cbnz, fmov (immediate, register, from w),
    fmul, fminnm, mov (movz) and eor w8,w8,#0x3f800000"""
    n = z = c = v = 0
    for _ in range(200):
        if not AREA <= pc < AREA + len(code): return pc
        w = struct.unpack_from('<I', code, pc - AREA)[0]; nxt = pc + 4
        rd, rn, rm = w & 31, (w >> 5) & 31, (w >> 16) & 31
        sx = lambda val, bits: val - (1 << bits) if val & 1 << (bits - 1) else val
        if w & 0x9f000000 == 0x90000000:   # adrp
            x[rd] = (pc & ~0xfff) + (sx(((w >> 5) & 0x7ffff) << 2 | (w >> 29) & 3, 21) << 12)
        elif w & 0x3b400000 == 0x39400000:   # ldr (unsigned offset)
            size, fp = w >> 30, (w >> 26) & 1; a = x[rn] + (((w >> 10) & 0xfff) << size)
            if fp: assert size == 2; s[rd] = struct.unpack('<f', mem(a, 4))[0]
            else: x[rd] = int.from_bytes(mem(a, 1 << size), 'little')
        elif w & 0xffe0fc17 == 0x1e202000:   # fcmp s, s / #0.0
            a, b = s[rn], 0.0 if w & 8 else s[rm]
            n, z, c, v = (1, 0, 0, 0) if a < b else (0, 1, 1, 0) if a == b else (0, 0, 1, 0) if a > b else (0, 0, 1, 1)
        elif w & 0xff000010 == 0x54000000:   # b.cond
            cond = w & 15; take = {0: z, 1: not z, 0xa: n == v, 0xb: n != v, 0xc: not z and n == v, 0xd: z or n != v}[cond]
            if take: nxt = pc + 4 * sx((w >> 5) & 0x7ffff, 19)
        elif w & 0xfc000000 == 0x14000000: nxt = pc + 4 * sx(w & 0x3ffffff, 26)   # b
        elif w & 0xfe000000 == 0x34000000:   # cbz / cbnz (32-bit)
            if ((x[rd] & 0xffffffff) == 0) != bool(w & 0x01000000): nxt = pc + 4 * sx((w >> 5) & 0x7ffff, 19)
        elif w & 0xff201fe0 == 0x1e201000:   # fmov s, #imm
            i8 = (w >> 13) & 0xff; b6 = (i8 >> 6) & 1
            s[rd] = struct.unpack('<f', struct.pack('<I', (i8 >> 7) << 31 | ((1 - b6) << 7 | (0x1f if b6 else 0) << 2 | (i8 >> 4) & 3) << 23 | (i8 & 15) << 19))[0]
        elif w & 0xfffffc00 == 0x1e204000: s[rd] = s[rn]   # fmov s, s
        elif w & 0xffe0fc00 == 0x1e200800: s[rd] = f32(s[rn] * s[rm])   # fmul
        elif w & 0xffe0fc00 == 0x1e207800: s[rd] = min(s[rn], s[rm])   # fminnm (no NaN here)
        elif w == 0x52091908: x[8] = (x[8] ^ 0x3f800000) & 0xffffffff   # eor w8,w8,#0x3f800000
        elif w & 0xff800000 == 0x52800000: x[rd] = ((w >> 5) & 0xffff) << (16 * ((w >> 21) & 3))   # mov (movz) w, #imm
        elif w & 0xfffffc00 == 0x1e270000: s[rd] = struct.unpack('<f', struct.pack('<I', x[rn] & 0xffffffff))[0]   # fmov s, w
        else: raise AssertionError(f'{pc:#x}: {w:08x} is not an instruction this evaluator knows')
        pc = nxt
    raise AssertionError('no exit in 200 instructions')


def stub_run(path, call):
    """Assemble a game's frame step stubs at AREA against a recording ctx: (code, {site: (words, why)}, ctx)"""
    m = load(path, 'live'); words, puts = [], {}
    ctx = docs_patches.types.SimpleNamespace(here=lambda: AREA + 4 * len(words), emit=words.append, site=lambda off, orig: None, put=lambda off, ws, why: puts.__setitem__(off, (ws, why)),
                                             state=STATE, render_scale=0, live_scale=0, step_max=0, base=0x100000, others={}, found=None, capabilities=set(), address=lambda off: 0)
    call(m, ctx)
    return b''.join(struct.pack('<I', w) for w in words), puts, ctx


def branch_target(puts, site):
    (w,), why = puts[site]
    assert w & 0xfc000000 == 0x14000000, f'{site:#x}: not a branch'
    d = w & 0x3ffffff; d -= (d & 0x2000000) << 1
    return site + 4 * d, why


def state_mem(p, h, extra=None):
    page = bytearray(0x40); struct.pack_into('<ff', page, 0x10, p, h)
    def mem(a, size):
        if STATE <= a < STATE + 0x40: return bytes(page[a - STATE:a - STATE + size])
        if extra and a in extra: return extra[a]
        return bytes(size)
    return mem


class LiveScaleStubs(unittest.TestCase):
    # (player's Render scale at +0x10 (0: unset), the host's factor at +0x14 (0: none yet), the game's own scale) -> what the 3D views are drawn at
    CASES = [(0, 0, 0.9, 0.9), (1.0, 0, 0.9, 0.9), (0.75, 0, 0.9, 0.75),   # no factor: as before LIVE_SCALE (the game's own, or the player's fixed scale)
             (1.0, 0.85, 0.9, 0.85), (1.0, 0.85, 0.8, 0.8), (0, 0.7, 1.0, 0.7), (1.0, 0.5, 0.5, 0.5),   # at the game's own scale: the lower of it and the factor
             (0.75, 0.85, 0.9, 0.6375), (0.5, 1.0, 0.9, 0.5), (0.75, 0.6667, 1.0, 0.500025),   # under a fixed scale: player x factor (the host floors the product at 0.5)
             (1.0, 1.0, 0.8, 0.8), (0.75, 1.0, 0.9, 0.75)]   # the factor back at 1.0: the game's own scale or the player's, at once

    def test_breath_of_the_wild(self):
        code, puts, ctx = stub_run(REPO / 'dm/games/01007EF00011E000/patches.py', lambda m, c: m.frame_step(c))
        self.assertEqual((ctx.render_scale, ctx.live_scale), (1, 1), 'a render-scale stub that reads +0x14: the fixups table says LIVE_SCALE')
        apply, why = branch_target(puts, 0x1266880); self.assertIn('+0x14', why)
        for p, h, game_scale, want in self.CASES:
            x, sv = [0] * 32, [0.0] * 32; x[20] = 0x7000000; sv[8] = f32(game_scale)
            out = a64(code, apply, x, sv, state_mem(p, h, {0x7000158: struct.pack('<Q', 0xabcdef)}), None)
            self.assertEqual(out, 0x1266884, 'back after the replaced load')
            self.assertEqual(x[8], 0xabcdef, 'the replaced ldr x8,[x20,#0x158] still runs')
            self.assertAlmostEqual(sv[8], f32(want), 6, f'player {p}, factor {h}, the game at {game_scale}: s8 {sv[8]}, want {want}')
        skip, _ = branch_target(puts, 0x126686c)
        for p, h, taken in ((0, 0, False), (1.0, 0, False), (0.75, 0, True), (1.0, 0.85, True), (0, 1.0, True), (1.0, 1.0, True)):
            out = a64(code, skip, [0] * 32, [0.0] * 32, state_mem(p, h), None)
            self.assertEqual(out, 0x1266880 if taken else 0x1266950, f'player {p}, factor {h}, at the skip site (reached only with the dynamic mode off): {"the apply block" if taken else "the original skip"}')

    def test_tears_of_the_kingdom(self):
        view = 0x600000
        code, puts, ctx = stub_run(REPO / 'dm/games/0100F2C0115B6000/patches.py', lambda m, c: m.stub(c, 0x100000, 0x200000, 0x300000, 0x400000, 0x500000, view))
        self.assertEqual((ctx.render_scale, ctx.live_scale), (1, 1), 'a render-scale stub that reads +0x14: the fixups table says LIVE_SCALE')
        size, _ = branch_target(puts, view + 0x9c); dyn, why = branch_target(puts, view + 0x15c); self.assertIn('+0x14', why)
        for p, h, game_scale, want in self.CASES:
            # the size: the extents x the player's scale (main+0xd5cc0, unchanged), then x the multiplier this stub leaves in s6
            x, sv = [0] * 32, [0.0] * 32; sv[2], sv[5], sv[3], sv[4] = 1600.0, 1.0, 896.0, 1.0
            self.assertEqual(a64(code, size, x, sv, state_mem(p, h), None), view + 0xac)
            extent = sv[0]
            x, sv = [0] * 32, [0.0] * 32; x[8] = 0x7000000
            self.assertEqual(a64(code, dyn, x, sv, state_mem(p, h, {0x7000028: struct.pack('<f', game_scale)}), None), view + 0x160)
            self.assertAlmostEqual(extent * sv[6] / 1600.0, f32(want), 5, f'player {p}, factor {h}, the game at {game_scale}: {extent} x {sv[6]}, want {want} of 1600')


class CatherineSixty(unittest.TestCase):
    # Catherine: Full Body (upstream NXNative 8d44bd6ac, NX 18's form): GFD's startup rate and the game's 60 Hz flag follow the target the loader writes at state +0 (0, 30.0 or
    # 60.0): at 60 the rate is 60, the flag 1 and a fixed step of 1 vsync is published at +0x24; at 0 or 30 the original instructions run (Battery Saver keeps the stock 30)
    BASE, GETTER, FLAG = 0x100000, 0x200000, 0x300360

    def assemble(self, others):
        m = load(REPO / 'dm/games/0100BF00112C0000/patches.py', 'catherine'); words, puts, sites = [], {}, []
        ctx = docs_patches.types.SimpleNamespace(here=lambda: AREA + 4 * len(words), emit=words.append, site=lambda off, orig: sites.append((off, orig)),
                                                 put=lambda off, ws, why: puts.__setitem__(off, (ws, why)), state=STATE, base=self.BASE, others=others,
                                                 address=lambda off: self.FLAG if off == self.GETTER else 0)
        m.MATCH_FRAME_STEP['main'][0]['stub'](ctx)
        return b''.join(struct.pack('<I', w) for w in words), puts, sites

    def test_both_or_neither(self):
        code, puts, _ = self.assemble({'timing getter': None})
        self.assertEqual((code, puts), (b'', {}), 'without the getter nothing is written (the rewriter then leaves no state page)')
        _, puts, sites = self.assemble({'timing getter': self.GETTER})
        self.assertEqual(sorted(puts), [self.BASE + 0x84, self.GETTER + 4])
        self.assertEqual(sites, [(self.BASE + 0x84, 'e80f1f32'), (self.GETTER + 4, '00814d39')], 'the original mov w8,#30 and ldrb w0,[x8,#0x360]')

    def test_target_selects_the_mode(self):
        try:
            from unicorn import Uc, UC_ARCH_ARM64, UC_MODE_ARM  # pyright: ignore[reportMissingImports]   (optional: skipped without it)
            from unicorn.arm64_const import UC_ARM64_REG_PC, UC_ARM64_REG_X0, UC_ARM64_REG_X8, UC_ARM64_REG_NZCV  # pyright: ignore[reportMissingImports]
        except ImportError: self.skipTest('unicorn not installed')
        code, puts, _ = self.assemble({'timing getter': self.GETTER})
        rate, _ = branch_target(puts, self.BASE + 0x84); timing, _ = branch_target(puts, self.GETTER + 4)
        for target, mode in ((0.0, 0), (30.0, 0), (60.0, 1)):
            for game_flag in (0, 1):
                uc = Uc(UC_ARCH_ARM64, UC_MODE_ARM)
                for page in (AREA, STATE, self.BASE, self.GETTER, self.FLAG & ~0xfff): uc.mem_map(page, 0x1000)
                uc.mem_write(AREA, code); uc.mem_write(STATE, struct.pack('<f', target)); uc.mem_write(self.FLAG, bytes([game_flag]))
                uc.reg_write(UC_ARM64_REG_NZCV, 0x60000000); uc.reg_write(UC_ARM64_REG_X8, 0xdead)
                uc.emu_start(rate, self.BASE + 0x88, count=20)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_PC), self.BASE + 0x88)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_X8), 60 if mode else 30, f'target {target}: the startup rate')
                uc.reg_write(UC_ARM64_REG_X8, self.FLAG & ~0xfff)   # the getter's own adrp x8 ran before the site
                uc.emu_start(timing, self.GETTER + 8, count=20)
                self.assertEqual(uc.reg_read(UC_ARM64_REG_PC), self.GETTER + 8, 'back at the getter\'s ret')
                self.assertEqual(uc.reg_read(UC_ARM64_REG_X0), 1 if mode else game_flag, f'target {target}, the game\'s flag {game_flag}')
                self.assertEqual(struct.unpack('<I', uc.mem_read(STATE + 0x24, 4))[0], mode, f'target {target}: the fixed step (+0x24)')
                self.assertEqual(uc.reg_read(UC_ARM64_REG_NZCV), 0x60000000, 'the flags are left alone')


class ExternalRegistry(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, self.tmp)
        self.tools = self.tmp / 'repo/tools'; self.tools.mkdir(parents=True)
        (self.tools / 'sdk_patches.py').write_text('')
        (self.tools / 'engine_patches.py').write_text('')
        self.gid = '0100000000000000'
        self.external = self.tmp / 'profiles'

    def patch_file(self, root, text):
        p = root / self.gid / 'patches.py'; p.parent.mkdir(parents=True, exist_ok=True); p.write_text(text)
        return p

    def registry(self, roots=None):
        ns: dict[str, Any] = dict(__file__=str(self.tools / 'patch_nso.py'), os=os, glob=glob, importlib=importlib)   # exec adds the registry's tables to these globals
        with mock.patch.dict(os.environ, DM_GAMES_DIR=os.pathsep.join(map(str, roots or [self.external]))):
            exec(REGISTRY_CODE, ns)
        return ns['PATCHES'], ns['PATCH_WHERE']

    def test_external_registered_patches_are_loaded(self):
        bid = '5e' * 16
        p = self.patch_file(self.external, f"CUTS = {{'{bid}': []}}\nOBS = {{'{bid}': []}}\nFRAME_STEP = {{'{bid}': lambda ctx: None}}\n")
        tables, where = self.registry()
        for kind in ('CUTS', 'OBS', 'FRAME_STEP'):
            self.assertIn(bid, tables[kind]); self.assertEqual(Path(where[kind, bid]), p)

    def test_shared_rules_merge_by_module(self):
        (self.tools / 'sdk_patches.py').write_text("MATCH_CUTS = {'sdk': ['sdk rule']}\n")
        (self.tools / 'engine_patches.py').write_text("MATCH_CUTS = {'main': ['engine rule'], 'sdk': ['engine sdk rule']}\n")
        tables, _ = self.registry()
        self.assertEqual(tables['SDK_MATCH_CUTS'], {'sdk': ['sdk rule', 'engine sdk rule'], 'main': ['engine rule']})

    def test_repository_patches_under_bracketed_directory(self):
        tools = self.tmp / 'game [0400486024DEC000][v131072]' / 'dm/tools'; tools.mkdir(parents=True)
        for f in ('sdk_patches.py', 'engine_patches.py'): (tools / f).write_text('')
        bid = '6a' * 16
        patch = self.patch_file(tools.parent / 'games', f"FRAME_STEP = {{'{bid}': lambda ctx: None}}\n")
        with mock.patch.object(self, 'tools', tools):
            tables, where = self.registry()
        self.assertIn(bid, tables['FRAME_STEP'])
        self.assertEqual(Path(where['FRAME_STEP', bid]).resolve(), patch.resolve())

    def test_derived_profile_keeps_repository_match_rules(self):
        self.patch_file(self.tools.parent / 'games', "MATCH_CUTS = {'main': ['repository']}\n")
        self.patch_file(self.external, "MATCH_CUTS = {'main': ['external']}\n")
        tables, _ = self.registry()
        self.assertEqual(tables['MATCH_CUTS'][self.gid], {'main': ['repository']})

    def test_frame_step_rules_are_scoped_like_match_rules(self):
        self.patch_file(self.tools.parent / 'games', "MATCH_FRAME_STEP = {'main': ['repository']}\n")
        self.patch_file(self.external, "MATCH_FRAME_STEP = {'main': ['external']}\n")
        tables, _ = self.registry()
        self.assertEqual(tables['MATCH_FRAME_STEP'][self.gid], {'main': ['repository']})

    def test_external_rules_cannot_enroll_a_repository_profile(self):
        (self.tools.parent / 'games' / self.gid).mkdir(parents=True)
        self.patch_file(self.external, "MATCH_CUTS = {'main': ['external']}\n")
        tables, _ = self.registry()
        self.assertNotIn(self.gid, tables['MATCH_CUTS'])

    def test_provisional_profile_can_supply_match_rules(self):
        self.patch_file(self.external, "MATCH_CUTS = {'main': ['external']}\n")
        tables, _ = self.registry()
        self.assertEqual(tables['MATCH_CUTS'][self.gid], {'main': ['external']})

    def test_provisional_rules_follow_the_first_profile(self):
        second = self.tmp / 'second'
        self.patch_file(second, "MATCH_CUTS = {'main': ['second']}\n")
        first = self.patch_file(self.external, "MATCH_CUTS = {'main': ['first']}\n")
        tables, _ = self.registry([self.external, second])
        self.assertEqual(tables['MATCH_CUTS'][self.gid], {'main': ['first']})
        first.unlink()   # a selected profile with no rules must not inherit another directory's rules
        tables, _ = self.registry([self.external, second])
        self.assertNotIn(self.gid, tables['MATCH_CUTS'])

    def test_repeated_roots_do_not_load_a_file_twice(self):
        self.patch_file(self.external, "CUTS = {'" + '5e' * 16 + "': []}\n")
        alias = self.tmp / 'alias'; alias.symlink_to(self.external, target_is_directory=True)
        tables, _ = self.registry([self.external, self.external, alias])
        self.assertEqual(len(tables['CUTS']), 1)

    def test_distinct_files_cannot_claim_the_same_build(self):
        text = "CUTS = {'" + '5e' * 16 + "': []}\n"
        self.patch_file(self.tools.parent / 'games', text)
        self.patch_file(self.external, text)
        with self.assertRaisesRegex(AssertionError, 'in both'):
            self.registry()


class RewriteKey(unittest.TestCase):
    def test_patch_files_of_the_games_builds(self):
        spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp)
        gid = '0100ECD018EBE000'   # Paper Mario: The Thousand-Year Door: a main in its own patches.py, an sdk build in sdk_patches.py
        for bid, m in builds_of(gid).items():
            if m in ('main', 'sdk'): (tmp / m).write_bytes(b'NSO0' + bytes(0x3c) + bytes.fromhex(bid))
        got = nsp.patch_files(REPO, tmp, ['main', 'sdk'])
        self.assertEqual(got, [REPO / 'dm/tools/sdk_patches.py', REPO / 'dm/tools/engine_patches.py', REPO / 'dm/games' / gid / 'patches.py'])
        (tmp / 'main').write_bytes(b'NSO0' + bytes(0x3c) + bytes(16)); (tmp / 'sdk').write_bytes(b'NSO0' + bytes(0x3c) + bytes(16))
        sdk_wide = [REPO / 'dm/tools/sdk_patches.py', REPO / 'dm/tools/engine_patches.py']   # their SDK-wide and engine-wide MATCH_CUTS apply to any build, so they always count
        self.assertEqual(nsp.patch_files(REPO, tmp, ['main', 'sdk']), sdk_wide)   # an unregistered build: no game's patch file counts
        self.assertEqual(nsp.patch_files(REPO, tmp, ['main', 'sdk'], gid), sdk_wide + [REPO / 'dm/games' / gid / 'patches.py'])
        g = game.load(gid)
        self.assertNotIn(REPO / 'dm/games' / gid / 'patches.py', nsp.profile_files(g))   # only the rewrite step reads it

    def test_patch_files_of_a_provisional_profile(self):
        spec = importlib.util.spec_from_file_location('build_ipa_from_nsp', REPO / 'scripts/build_ipa_from_nsp.py')
        nsp = importlib.util.module_from_spec(spec); spec.loader.exec_module(nsp)
        tmp = Path(tempfile.mkdtemp()); self.addCleanup(shutil.rmtree, tmp)
        bid = '5e' * 16   # a build that no repository profile knows
        (tmp / 'exe').mkdir(); (tmp / 'exe/main').write_bytes(b'NSO0' + bytes(0x3c) + bytes.fromhex(bid))
        mine, other = tmp / 'profiles/0100000000000000/patches.py', tmp / 'profiles/0100000000000001/patches.py'
        for f, text in ((mine, f"CUTS = {{'{bid}': []}}\n"), (other, "CUTS = {'" + '6f' * 16 + "': []}\n")):
            f.parent.mkdir(parents=True); f.write_text(text)
        sdk_wide = [REPO / 'dm/tools/sdk_patches.py', REPO / 'dm/tools/engine_patches.py']
        with mock.patch.dict(os.environ, {'DM_GAMES_DIR': str(tmp / 'profiles')}):
            self.assertEqual(nsp.patch_files(REPO, tmp / 'exe', ['main']), sdk_wide + [mine])   # of the games' files, only the one that names the module's build
            self.assertEqual(nsp.patch_files(REPO, tmp / 'exe', ['main'], '0100000000000001'), sdk_wide + [mine, other])   # the selected game's file counts for any build
        with mock.patch.dict(os.environ, {'DM_GAMES_DIR': ''}):
            self.assertEqual(nsp.patch_files(REPO, tmp / 'exe', ['main']), sdk_wide)
        with mock.patch.dict(os.environ, {'DM_GAMES_DIR': os.pathsep.join([str(tmp / 'profiles')] * 2)}):
            self.assertEqual(nsp.patch_files(REPO, tmp / 'exe', ['main']), sdk_wide + [mine])


if __name__ == '__main__':
    unittest.main()
