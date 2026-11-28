# Xenoblade Chronicles X: Definitive Edition – Nintendo Switch 2 Edition

Program `0400453019AA8001`, version 2.0.0 (`v0` in the supplied NUP), SDK
20.5.14 for Switch 2 (Ounce), NVN2 API 231.30, Monolith's engine and Wwise
audio. The loaded modules are `main` and `sdk`. The host supplies the imports
from the shipped NintendoSDK_movie module (`subsdk0`).

**Crashes at boot on the iPhone** (NX 18 `904d2c01a`, two runs on an iPhone 18 Pro Max, 2026-11-27);
not yet run on NX 18's Mac. The profile and everything below except this paragraph,
[On NX 18](#on-nx-18) and [On the iPhone](#on-the-iphone) are upstream's (NXNative `0834cb6ae`, by
seedds, made from a legally owned and acquired copy).

## On NX 18

- Build it from your legally owned and acquired NUP of this exact build (2.0.0, `main`
  `cecd4049…`); no other version is registered. The NUP holds this Switch 2 program
  alone (program 1 of the application), which NX 18 builds only with the development
  switch on (`NX18_DEV`, [docs/development.md](../../../docs/development.md)); without
  it the build stops with `This program isn't supported yet`.
- Monolith's 60 GiB reservation fits the Mac's 64 GB alias region, not an iPhone's: see
  [On the iPhone](#on-the-iphone) for what the profile tries there.
- `mem_map_limit on` is in [`game.tsv`](game.tsv): upstream's host turns the pool
  limit on for every Switch 2 game (NXNative `a694f1799`), and it ran this game so.
- Upstream's `geo_pairs.tsv` (four vertex/geometry pairs, for its mesh libraries of
  every variation's geometry pair) is not taken: NX 18 builds mesh libraries only for
  lean pairs a recording met (`G` rows) or `geo_mesh.tsv` names, and draws the
  others through the compute path, which records them for the next build.
- `MountRom` with this program's own index (1, `romo:`) mounts its RomFS without
  the red line ([Mounting the current program's RomFS by index](../../../docs/reference/services.md#mounting-the-current-programs-romfs-by-index)).
- The shader split reads this game's shaders (2026-11-27). Before, it stopped with
  `[RED] main#SLCT@0x18a01a0 HCPS: truncated control`: `main`'s shader programs have NVN2
  (Switch 2) control sections, which are shorter than the Maxwell ones NX 18's Monolith
  reader expected, and the reader did not open the RomFS's ARH2 archive indexes
  (`sts.arh`, `stso.arh`), whose shaders would have been left out. Both are read now, as
  upstream reads them (NXNative `b32d0bf3b`; [Monolith's shader containers](../../../docs/reference/shaders.md#monolith-arh1-xbc1-and-hcpsslct-shader-containers)).
  The other Monolith games' splits are unchanged. Not yet checked against the game's files:
  the next build's split should find upstream's 24,815 keys (this profile's `shader_map.tsv`).
  The `skipped` lines in `rewrite_main.log` and `rewrite_sdk.log` are function patches that do not
  apply to this build and are expected.

## On the iPhone

Both runs of NX 18 `904d2c01a` on the owner's iPhone 18 Pro Max (5 GB block, 4.375 GB alias
region) stopped right after `>>> nninitStartup` with `CRASH sig=11 addr=0 pc=sdk+0x6d6448
lr=main+0xae38d0`: `memset` (the PLT target in `x16`) of `0x20000` bytes to null, from the
function that clears the first arena's 128 KB of bookkeeping. That is the stop upstream's Mac
run with the iPhone's alias region reached (below), so the cause is the 60 GiB reservation
the alias region cannot hold: the SDK refuses it, Monolith does not check, and its first
arena comes from a region that does not exist. The Switch 1 program had the same stop, and
upstream fixed it there in Monolith's own code (`0100453019AA8000`, NXNative `b32d0bf3b`):
the SDK's StandardAllocator gate cannot size a region the game asks for with
`nn::os::AllocateAddressRegion` itself.

What the profile does now (2026-11-27), without this program's `main` at hand to check:

- [`patches.py`](patches.py) carries upstream's Switch 1 rule, matched by its two complete
  function fingerprints: it applies only if this build's functions and their callees are the
  same code, word for word. The first arena becomes 512 MB + 128 KB, as upstream's, and the
  outer region 12 GB rather than upstream's 4 GB, since this program opened pages up to
  8.01 GiB into its region within 15 seconds on the Mac, beside the 4 GB first arena.
- [`game.tsv`](game.tsv) gives the iPhone a 16 GB alias region (`mem_alias 0x400000000`,
  `mem_reserve 0x428000000`), Fire Emblem Fortune's Weave's, which plays on this phone; the heap
  and stack regions are as before, and the Mac's block is unchanged.
- If the rule does not match, `rewrite_main.log` says so in a red line
  (`function patch 'Monolith malloc region and first arena' skipped: …`) and the survey after
  it lists this build's candidate functions with offsets, sizes and fingerprints
  (`function survey 'Monolith malloc region size (60 GB)': …`, `function survey 'Monolith first
  arena (4 GB + 128 KB)': …`), which is what enrolling the rule for this build needs. The game
  then still stops at boot.
- The run's log names a refused reservation in every game now:
  `[RED] [mem] address region of 60.000 GB asked, returning to main+0x…: the alias region (…) has
  … GB free in all, so it cannot hold it`, and, at a crash before any address was given,
  `[RED] [mem] the last address region asked, … got no address before the crash`.

## Current status

On an Apple M6 Mac mini (16 GiB, macOS 27.2.1, Xcode 27.2), a fresh game
rendered the title, opening movie, avatar creation, name entry and the first
field in Starfall Basin with Elma. The 3840×2160 swapchain had a 16.63 ms
median frame over the last 300 frames of that run. The host reported 3,294 MB
resident and 2,363 MB allocated by Metal at the end. The host reported both
add-on licenses, opened stereo output and logged two slow residency commits
(205.5 ms and 116.9 ms). No shaders were missing. Combat, later areas,
save/reload and iOS devices remain untested.

The 17.2 GiB Mac app passed signature verification. Its first launch reached
the 2.0.0 title in about 2 minutes 20 seconds and used the bundled pipeline
archive.

## Running on the Mac

Build it from the NUP with `scripts/build_ipa_from_nsp.py <folder> --platform mac-app`
(with `NX18_DEV=1` on NX 18).
Choose New Game, create an avatar and follow the opening prompts. `Plus`
then `A` skips a scene after the confirmation appears.

## Address space

Monolith reserves 60 GiB from `main+0xae54c4` before `nnMain`. In the first 15
seconds of `nnMain`, the reservation had 3.11 GiB mapped and had opened pages
up to 8.01 GiB within it. A separate 64 MiB region brings total reservation
reach to alias +60.13 GiB. Upstream's Mac gives a Switch 2 game a 128 GiB alias
region; NX 18's Mac gives every game 64 GiB, which also holds both.
The NPDM declares 96 MiB of system resource and the SDK identifies the 9 GiB
Switch 2 application pool. The existing SDK rewriter matches the address
region node-area implementation. There are no game executable cuts.

The version's 60 GiB request exceeds the current 4.375 GiB iPhone and iPad
layout. A Mac run forced to that layout stopped in `nninitStartup` before
`nnMain`, at `memset` (`sdk+0x6d6448`, called from `main+0xae38d0`) with a
null destination. Device bring-up is open.

## Files and shaders

- The NUP has one program with its full RomFS and two license-only add-ons.
  The RomFS contains `sts.ard` and `stso.ard` with ARH2 indexes, two sets of
  46 WebM movies and five Wwise sound packs.
- The shared Monolith reader found 24,815 shader keys, 19,058 vertex/pixel
  variation pairs and four vertex/geometry pairs. The map covers all 749
  keys requested during the first 15 seconds of boot. The split reported six
  control sections in `main` for which it found no code area.
- All 24,815 Mac shader libraries built on chain `343aa69bfb7a`. The Mac host
  prebuilt all 19,058 variation bases without a failure. The Mac app bundles
  an `applegpu_g18g` archive with 19,058 render bases and 36 compute pipelines.
- [`pso_manifest.tsv`](pso_manifest.tsv), the prewarm list the app ships, held no rows until
  2026-11-27. It now holds upstream's list (NXNative `a2412f2a8`): 5,353 rows, 4,801 shaders
  (`S`) and 552 render pipelines (`R`), captured by upstream's players on game 2.0.0, not on
  NX 18's devices. Every row checks clean against this shader map (`pso_seed.py check`). Its
  effect on a first start's prepare step on the iPhone is not measured yet: the 552 `R` rows
  give the next build's archive its layout bases, and most `S` rows load after the first frame.

## Found on this game

- [Indexed RomFS mounts](../../../docs/reference/services.md#mounting-the-current-programs-romfs-by-index)
  of the running program's own index (`romo:`, index 1) are its RomFS, with no red line.
- [The Mac's console-sized alias region](../../../docs/reference/memory.md#the-macs-alias-region-is-the-switchs-64-gb)
  holds Monolith's startup reservation.
- [Monolith's shader containers](../../../docs/reference/shaders.md#monolith-arh1-xbc1-and-hcpsslct-shader-containers)
  cover both archive indexes.
