# Catherine: Full Body (0100BF00112C0000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py;
# MATCH_FRAME_STEP as described there ("Registered patches").
# Port of upstream NXNative 8d44bd6ac ("rewriter/catherine: enable the game's 60 fps mode"): GFD's 60 fps startup rate and the game's own 60 Hz timing branch, selected together.
# Upstream cuts both sites for good (MATCH_CUTS); in NX 18 they follow the frame-rate target the loader writes at state +0 when the game starts (fps_target 60 in game.tsv, the
# launcher's Frame rate, DM_FPS_TARGET; Battery Saver 30), so 30 keeps the stock code and the Switch's 30 fps.
import struct

from nso_asm import ADRP, B, CBNZW

# nnMain hands GFD a configuration whose rate is 30 (mov w8,#30 at +0x84; 1.0.1a main+0x9f304). GFD's initializer stores the rate for its animation timing and picks present
# interval 1 for 60, 2 otherwise. The game reads its own 60 Hz flag through a three-instruction getter (adrp x8; ldrb w0,[x8,#0x360]; ret; 1.0.1a main+0xf6320): the tick
# callback (main+0x9c900, its bl at +0x1c) takes one tick per frame instead of two, the sequencer a step of 1/60 s instead of 1/30, and other readers halve per-frame animation
# steps and double frame-based durations. The getter's fingerprint alone matches more than one function, so it is found through the tick callback's call (nso_match called_by).
# With the target at 60 both stubs take the game's 60 Hz path, and the getter publishes a step the game fixes at 1 vsync (state +0x24, as Breath of the Wild's VFR override and
# Mario Kart World's 30 fps mode do): the game's steps are fixed, so the host must not hold its frames 2 vsyncs (a movie, the heat or Low Power Mode cap), which would play it at
# half speed. At 30 or 0 both run the original instructions and the game asks for interval 2 itself. Both parts or neither: when the getter is not found the stub writes
# nothing, and the rewriter then leaves the main without a state page (stock timing, the game's own present interval), as upstream keeps stock timing when either site fails.
# Only x8 (the startup site's own destination) and x0 / x8 (the getter's result and its own adrp register) are written; no flags.
sixty_hi = 0x427   # the float 60.0 (0x42700000) >> 20; the loader writes only 0, 30.0 (0x41f00000) or 60.0 at state +0, so this is zero for 60 alone


def sixty_fps(ctx):
    getter = ctx.others.get('timing getter')
    if getter is None: return   # both or neither (the locator printed the red line)
    here, emit, state = ctx.here, ctx.emit, ctx.state
    startup = ctx.base + 0x84
    ctx.site(startup, 'e80f1f32')   # mov w8,#30 (orr w8,wzr,#0x1e): GFD's startup rate
    flag = ctx.address(getter)      # the flag the getter's adrp x8 and ldrb w0,[x8,#lo] read
    load = 0x39400100 | (flag & 0xfff) << 10   # ldrb w0,[x8,#lo]
    ctx.site(getter + 4, struct.pack('<I', load).hex())

    start = here(); emit(ADRP(8, here(), state))
    emit(0xb9400108)                      # ldr w8,[x8]            target fps (float bits)
    emit(0x53147d08)                      # lsr w8,w8,#20
    emit(0x51109d08)                      # sub w8,w8,#0x427       zero at 60 only
    emit(CBNZW(8, here(), here() + 12))   # cbnz w8,stock
    emit(0x52800788)                      # mov w8,#60
    emit(B(here(), startup + 4))
    emit(0x321f0fe8)                      # stock: mov w8,#30
    emit(B(here(), startup + 4))
    ctx.put(startup, [B(startup, start)], "GFD's startup rate: 60 at a 60 fps target, else the game's 30 (state page target fps)")

    start = here(); emit(ADRP(0, here(), state))
    emit(0xb9400000)                      # ldr w0,[x0]            target fps (float bits)
    emit(0x53147c00)                      # lsr w0,w0,#20
    emit(0x51109c00)                      # sub w0,w0,#0x427
    emit(CBNZW(0, here(), here() + 20))   # cbnz w0,stock
    emit(ADRP(8, here(), state))
    emit(0x52800020)                      # mov w0,#1              the game's 60 Hz timing
    emit(0xb9002500)                      # str w0,[x8,#0x24]      a step the game fixes: 1 vsync
    emit(B(here(), getter + 8))           # to its ret
    emit(ADRP(8, here(), flag))           # stock: adrp x8,flag
    emit(load)                            # ldrb w0,[x8,#lo]
    emit(B(here(), getter + 8))
    ctx.put(getter + 4, [B(getter + 4, start)], "the game's 60 Hz timing flag: 1 at a 60 fps target, with a fixed step of 1 vsync; else the game's own flag (state page target fps)")


MATCH_FRAME_STEP = {'main': [
    {'name': 'Catherine 60 fps startup and simulation', 'stub': sixty_fps,
     # nnMain: sets the GFD configuration's rate to 30; GFD uses it for the present interval and animation timing (1.0.1a main+0x9f280)
     'size': 0xf0, 'fingerprints': ['966cc9817a3a57178dd0c34b1b2e395c10b0dc2d77fafd0569591870f0dab82b'],
     # the timing flag's getter, through the tick callback's call to it: its three-instruction body alone is ambiguous
     'others': {'timing getter': {'size': 0xc, 'fingerprints': ['b97c00f11cf12cbd431bf2acae8edd252d54bff76014491cf77bffccfd5da6cd'],
                                  'called_by': {'size': 0xa4, 'fingerprints': ['102b6acefb704f84502d732696e70949d4c5e87511f67131e43597f56e2bb9ec'], 'call': 0x1c}}}},
]}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md)
BINDING = [
    {'what': 'Catherine 60 fps startup and simulation', 'now': 'game', 'goal': 'game', 'purpose': 'frame rate',
     'checked': '1.0.1a startup, tick callback and timing getter verified by disassembly (upstream NXNative 8d44bd6ac; NX 18 has not run it)',
     'why': "GFD already accepts 60 at startup, but the title also selects its own fixed steps. Both sites must match together; no SDK or host setting selects the title's timing "
            'mode. In NX 18 both follow the frame-rate target at start (Battery Saver keeps the stock 30).'},
]
