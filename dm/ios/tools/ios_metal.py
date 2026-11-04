# The single compile standard for the iOS shader packaging chain: MSL from any source (PC chain / constant patches / in future, the Switch original translated via Ryujinx) → iphoneos metallib.
# Compile parameters are defined only once, here; the chain.metal record in the reflection json is generated from the same parameters, record == actual.
import os, subprocess, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '../../gfx/tools')); import dmsh_pch   # the precompiled header, which changes no output (so RECORD does not name it)
# -fmetal-math-mode=relaxed: keep fast math's reassociation / contraction, but forbid assuming there are no NaN / Inf. The translated shaders reproduce Maxwell's NaN semantics with isnan selects (8337 / 12809 use them),
# and the default fast mode lets each GPU's backend compiler treat them as always false; on the A20 Pro the opening course's odd frames had 727k NaN pixels in the main image (a few dozen with the same AIR on the M4 Pro), which became the black band / black-edged glow
# -fpreserve-invariance: [[invariant]] position outputs only agree across shaders with this flag (as dmsh_build.py's MAC_METAL: a depth pre-pass followed by a less-or-equal G-buffer)
# -O1: -O2's switch folding leaves a control-flow graph Apple's GPU backend can only lower slowly into very large code (as dmsh_build.py's MAC_METAL)
# -mios-version-min=27.0: the system the app needs (dm/ios/project.yml). -std=metal4.1: the newest Metal Shading Language, the one Apple's specification (version 4.1, 2026-06-04,
# "Compiler Options Controlling the Language Version") gives for iOS 27, named rather than left to the compiler's default. A shader Metal 4.1 rejects is compiled again in Metal 3.2
# (FALLBACK_STD: the language of this convention's earlier iOS 18 minimum, the one these shaders were tested in), and says so
STD, FALLBACK_STD = '-std=metal4.1', '-std=metal3.2'
METAL = ['xcrun', '-sdk', 'iphoneos', 'metal', '-c', '-O1', '-mios-version-min=27.0', STD, '-fmetal-math-mode=relaxed', '-fpreserve-invariance']
METAL_FALLBACK = [FALLBACK_STD if a == STD else a for a in METAL]
METALLIB = ['xcrun', '-sdk', 'iphoneos', 'metallib']
RECORD = ' '.join(METAL) + f' (else {FALLBACK_STD}); ' + ' '.join(METALLIB)          # Written into json chain.metal

def compile(msl, air, lib):
    try: dmsh_pch.compile(METAL, msl, air)
    except subprocess.CalledProcessError:
        print(f'{msl}: compiled in Metal 3.2 ({FALLBACK_STD}): Metal 4.1 rejects it (its messages are above)', file=sys.stderr, flush=True)
        dmsh_pch.compile(METAL_FALLBACK, msl, air)
    subprocess.run([*METALLIB, air, '-o', lib], check=True)
