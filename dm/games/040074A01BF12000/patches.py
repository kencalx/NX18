# Donkey Kong Bananza (040074A01BF12000): patches of this game's own builds, keyed by NSO build ID.
# OBS: an observation gate in the game's frame-rate controller (main+0x204a18, v458752). At the gate (its test of its off switch, main+0x204a44) x20 is the controller, x8 its
# measure of the frame in system ticks (from the frame's start to the later of its submission and the GPU's end), w9 its off switch. The host's callback (dm/host/hle_fctl.c,
# number 27 = OBS_FPS_CTL in dm/host/dm.h) hands it the measure nvn_fctl.h decides: the phone lowers its clocks at 30 fps, so the game's own measure never saw 60 fit again
# (the game's note, Frame rate on the iPhone). The instruction is the gate's original one, run after the callback
OBS = {
  'e25c90c1c136638885659fd55bf8a03b': [
    (0x204a44, 27, '7100013f', "frame-rate controller: its measure of the frame (x8, system ticks) judged with the host's clocks; cmp w9, #0 (its off switch) runs after the callback"),
  ],
}

# How general each patch is and could be (dm/tools/docs_patches.py "Binding", listed in docs/agents/game-patches.md)
BINDING = [
    {'what': "frame-rate controller's measure judged with the host's clocks", 'now': 'build', 'goal': 'game', 'purpose': 'frame rate',
     'checked': "v458752's main: the controller main+0x204a18, its one caller main+0x203718 (the controller is the frame object's +0x218), its settings in its first 0x14 bytes and the interval at +0x40 (2026-11-15)",
     'why': "the game's own controller and its registers at one instruction; a fingerprint of the function would carry it to updates that keep it",
     'blocked': "observation gates are placed by build ID only: patch_nso.py has no function-matched form of OBS (MATCH_CUTS and MATCH_FRAME_STEP only)"},
]
