# Xenoblade Chronicles: Definitive Edition (`0100FF500E34A000`)

Base title ID `0100FF500E34A000`, update 1.1.2 (`v196608`), SDK 9.3.1,
Monolith's engine, NVN. Modules: `main`, `subsdk0` (NintendoSDK_movie), `sdk`.

## Current status

Mac gameplay tested (2026-10-28, Apple M6): title, opening movies and real-time
events, the Sword Valley battle through its boss, targeting, movement, Monado
arts and Shulk / Reyn's first Colony 9 combat, with real audio. Frames during
the opening battle take about 33 ms. The unsigned 1.1.2 IPA builds successfully
(13.2 GiB), with all 15,129 shader libraries and a complete CRC check. Further
story progression and saving / reloading remain open. On the iPhone 18 Pro Max
(the 0.5 build, 2026-11-11, and X1.0, 2026-11-12) about 8 minutes of a new game
held 60 fps with the 60 fps mod each time ([On the iPhone](#on-the-iphone)).

## Memory

The NPDM declares no system resource. The 4 GB guest reservation,
with 256 MB each for alias memory and stacks, holds the game's 3.14 GB heap.
The application memory pool remains `0xCD500000`. No game-specific cuts are used;
the SDK takes the existing function-matched address-region adaptations.

**Resolved, streamed texture lifetime:** the first opening-battle run grew to
4.8 GB resident / 5.2 GB GPU while pool and serial counts stayed nearly flat.
A descriptor census found 3,227 finalized textures' cached views retaining
1.1 GB of Switch texture storage. With the general
[descriptor-view retirement fix](../../../docs/reference/nvn-objects.md#finalized-textures-kept-by-registered-descriptor-views),
28,643 retired descriptors held zero cached views; the battle stayed near
2.1 GB resident / 2.5 GB GPU through frame 18,600. Late command replay and
compatible views are covered by the Metal texture tests.
At the first Colony 9 tutorial the final run stayed at 2,230 MB resident /
2,512 MB GPU through frame 53,700, then exited cleanly.

## Files and shaders

The merged RomFS contains 18,539 files (13.61 GiB). Its shaders are loose HCPS
programs, XBC1-compressed effect/map files and DRSM model streams containing
XBC1 resources. There is no ARH/ARD archive.

**Resolved, extraction:** the original split found only the six boot stages in
`main`, at `main+0x11ac820`. Dispatching the loose containers through the existing
[Monolith decoder](../../../docs/reference/shaders.md#monolith-arh1-xbc1-and-hcpsslct-shader-containers)
finds 15,129 keys: 5,147 vertex, 9,966 pixel, three geometry and 13 compute,
with 10,681 variation pairs. Sources contribute 8,109 map keys, 3,506 character
keys, 2,732 shared shader keys, 776 effect keys and six from `main`.
All 199 shader keys absent during the first title run match this inventory.

## Rendering

- **Resolved: scenery darkened during the first Colony 9 bridge reply by Shulk** ([PR #365](https://github.com/seedds/nxnative/pull/365)). In version 1.1.2 on the Mac, the depth-of-field initialization draw takes a Float3 position through a uint4 shader declaration. Its missing `w` caused the draw to be clipped, leaving a black depth-of-field buffer that a later composite blended over textured scenery. The general fix and synthetic regression are linked below.

## Running on the Mac

Build with `scripts/build_ipa_from_nsp.py <NSP folder> -k <prod.keys> --platform mac`;
it prints the run command. The tested interactive runs used `DM_PRESENT_LINK=0`
for direct presentation. With the default display link, a background window
stopped presenting; no profile override is retained. `Plus`, then `A`, skips an
opening event. In battle, close tutorial pages with `A`, target with `R`, start
with `A`, and approach with the left stick. Select arts with the directional
buttons and confirm with `A`. Each opening event needs its own skip.

## On the iPhone

The owner's run on an iPhone 18 Pro Max (iOS 27.3), the 0.5 build
(`5b302cd0`, chain `ac67cb709fa0`), update 1.1.2, docked, the 60 fps mod from
the mods folder (`DM_MOD_FPS=1`), Picture Stretch, no upscaling, no edge
smoothing: the first start after a fresh install, then about 8 minutes of a new
game (28,600 frames).
From its `log.txt` (`scripts/devlog.py`):

- **Frames:** 60 fps throughout; frame time p50 16.68 ms, p95 17.27 ms; 18 of
  28,489 frames dropped (0.06%); game GPU time p50 12 ms. 58 frames over the
  long-frame mark (about one a minute), 47 of them the game's own work; the
  longest, 808 ms, was the first frame's new pipelines.
- **Power and heat:** CPU 2.18 W median (36 mJ a frame); thermal state 1 only in
  the last 70 s. Same-core handoffs about 1,260 a second (80 ms of polling a
  second), the same-core handoff cost found in Catherine: Full Body, whose wait
  no longer polls after 0.5 (not measured on this game since).
- **Memory:** footprint 976 MB at the title to 1.9 GB at most, GPU allocated at
  most 2.07 GB, at least 6.29 GB of headroom to the app's limit.
- **Audio:** one gap, 23 underruns (119 ms) on the second output while the game
  loaded about 300 MB.
- **Display:** game enqueue to target display p50 46 ms (no present trim in
  0.5; after it the iPhone trims at K = 60 by default, not measured on
  this game).

The owner's second run, on the same iPhone with X1.0 (`6448f757`, chain
`222e58e346d6`), the same settings (docked, the 60 fps mod, Picture Stretch, no
upscaling, no edge smoothing), a controller: a later start of X1.0 installed
over 0.5 (the device's `pso_user.tsv` held 219 lines, the 0.5 run's 215 rows and
4 an earlier X1.0 start wrote; its archive 2 files), then about 8 minutes of a
new game (29,070 frames on screen). From its `log.txt` (`scripts/devlog.py`):

- **Frames:** 60 fps; frame time p50 16.67 ms, p95 17.34 ms; 43 frames dropped
  (0.15%); game GPU time p50 11.96 ms. 43 frames over the long-frame mark (5.2
  a minute), 10 of them new pipelines first. The longest, 434 ms at 236 s
  (frame 13,683), built one new pipeline (423 ms of making it, with 173 draws on
  a hybrid pipeline meanwhile), right after a 126 ms frame that loaded 124
  shader libraries (107 ms).
- **Pipelines:** the prepare step took 0.14 s (3,870 lines, no progress screen):
  8 bases compiled, 505 from the archive (501 of them layout bases from the
  archive bundled with the app), 56 reused. In play 271 more bases were compiled
  (10.1 s of compile time on all threads); the submit thread waited 1.60 s for
  pipelines and 0.12 s for shader libraries in all.
- **Power and heat:** CPU 2.22 W median (36.9 mJ a frame); thermal state 0
  throughout.
- **Memory:** footprint 970 MB at the start to 2.07 GB at most, GPU allocated at
  most 2.81 GB, at least 6.12 GB of headroom to the app's limit.
- **Audio:** no underruns.
- **Display:** game enqueue to target display p50 29 ms.

### Pipelines on a first start

On 0.5 the prepare step with the shipped list (3,659 rows, 3,653 used) took 2.98 s
before the first frame, behind the progress screen: 391 bases compiled, none
from the bundled archive, 30 reused. In play 139 more bases were compiled
(5.01 s of compile time on all threads), none of them on a frame over 60 ms
after the first. That run's `Documents/pso_user.tsv`, which records only what
the list did not hold, gave 215 rows, 69 shaders (`S`) and 146 render pipelines
(`R`), all checked against [`shader_map.tsv`](shader_map.tsv) (the build's map,
byte for byte) by `dm/tools/pso_seed.py`; they follow the first rows in
[`pso_manifest.tsv`](pso_manifest.tsv) below their own note, in recorded order.
The X1.0 run's `Documents/pso_user.tsv` (1,055 lines) gave 838 rows the list
did not hold, 568 `S` and 270 `R`, checked the same way (`shader_map.tsv` is the
X1.0 build's, byte for byte) and added below their own note: the other 217 lines
are rows the list already held (the 0.5 run's 215, and the two `_bgv` render
pipelines of the six rows below, which `pso_seed.py` refuses), X1.0's `R` rows
carry the border field (1,024 hex digits), and none of the 838 was refused.
The list now has 4,712 rows (3,873 `S`, 839 `R`). Six of the first rows, the
`_bg0` / `_bgv` geometry variants of two shaders, are not library keys of the
map and the prewarm drops them at load (`shader keys not in the shader map 4`
plus their two `R` rows); `pso_seed.py check` refuses them, and the test expects
exactly those six.

- **Its cost on a first start** (an estimate, not measured): with 0.5, each
  added `R` row takes at most one base, so at most 146 more in the prepare step;
  at that start's rate (2.98 s for 391 bases, about 7.6 ms a base on 6 workers)
  about 1.1 s more, so about 4 s in all with 0.5's archive.
- **With the X1.0 rows** (an estimate, not measured): the next build's
  `pso_offline.py` compiles the new `R` rows' layout bases (at most 270) into the archive
  bundled with the app ([Pipelines with a vertex layout compiled at a fresh install's prepare step](../../../docs/reference/shaders.md#pipelines-with-a-vertex-layout-compiled-at-a-fresh-installs-prepare-step)),
  so a fresh install takes them from the app as the X1.0 run took its 501, and
  the step stays about 0.2-0.3 s (0.14 s for 3,870 lines on that run). If the
  app's archive does not serve them, each takes at most one base, so at most 270
  more; at the 0.5 first start's rate (about 7.6 ms a base on 6 workers) about
  2.1 s more, so about 2.3 s. Either way the bases the X1.0 run compiled in play
  (271, the 434 ms frame's pipeline among them: `pso_user.tsv` records each
  pipeline built on the spot) are built before the first frame.
- **The settings:** the 60 fps mod changes the game's pacing and Picture Stretch
  is the host's present; a row's pipeline key holds no picture size, so the rows
  name the same pipelines at 30 fps and without the stretch.
- **What it does not cover:** places past those two runs' 8 minutes each, which
  still build their pipelines at their first draw, and `pso_user.tsv` records
  them.

## Checks

The full Metal graphics suite passes, including 56 CPU-texture / descriptor
lifetime checks. The Monolith decoder's 12 synthetic tests and the graphics,
tool and documentation suites pass (the Mac-packaging subset was rerun on the
external drive after the internal-disk free-space guard stopped its first run).
Mac and iOS full shader builds both report 15,129 of 15,129 successful shaders;
the Mac pipeline prebuild built all 10,681 pairs with zero failures.

The full five-game `regress.py check --baseline HEAD` report is
`0100FF500E34A000-work/regress-harness/reports/20261028-145620-check/report.md`
in the NSP folder. Xenoblade 2 and 3 cover the shared Monolith decoder; Wonder
and Dread cover other NVN engines; Three Houses covers frequent descriptor
registrations. All five have unchanged MSL and zero new shader or interface
failures. Wonder's gameplay route passes. Dread, Three Houses and Xenoblade 3
have no smoke route and receive static checks only. Xenoblade 2's timed route
reports different screenshots and 2,032 → 2,348 MB peak memory, with no new RED
lines. Inspection shows the baseline still in the cloud movie and the candidate
already at the King Crustip tutorial: screenshots and memory compare different
scenes. The earlier tool-only comparison also captured different loading
stages. This result is inconclusive; further gameplay testing was stopped at
the user's request.

## Found on this game

- [Float32 vertex padding through integer inputs](../../../docs/reference/rendering.md#float32-vertex-padding-through-integer-inputs).
- [Monolith ARH1, XBC1 and HCPS/SLCT shader containers](../../../docs/reference/shaders.md#monolith-arh1-xbc1-and-hcpsslct-shader-containers): loose programs, effects and model/map streams.
- [Finalized textures kept by registered descriptor views](../../../docs/reference/nvn-objects.md#finalized-textures-kept-by-registered-descriptor-views).

## Open

- Further story progression and saving / reloading, on the Mac and the iPhone.
- A fresh install's prepare step with the 4,712-row prewarm list on X1.0's next build, estimated at about 0.2-0.3 s with the app's archive (about 2.3 s if it does not serve the new layout bases), and play over the same 8 minutes without the X1.0 run's new-pipeline frames ([Pipelines on a first start](#pipelines-on-a-first-start)).
- The six `_bg0` / `_bgv` rows of the prewarm list, which the prewarm drops: recorded by an earlier build; whether the host should prewarm geometry variants is open.
- Repeat the Xenoblade 2 comparison with a deterministic route when requested.
