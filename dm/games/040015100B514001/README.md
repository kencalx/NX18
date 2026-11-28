# Super Mario Bros. Wonder – Nintendo Switch 2 Edition + Meetup in Bellabel Park

Program `040015100B514001`, build 1.2.1, the Switch 2 program (program 1) of an application whose
Switch 1 program is [`010015100B514000`](../010015100B514000/README.md). SDK 21.4.1 built for the
Switch 2 (`Ounce`), NVN2 shaders (`*.Nin_Ounce_NVN2`), Nintendo EPD's engine (sead, agl, gsys,
Havok). The loaded modules are `main`, `subsdk0` (NintendoSDK_movie) and `sdk`.

The profile and everything below except [On NX 18](#on-nx-18) are upstream's (NXNative `f35ebba74`,
PR #2957, by seedds with Josh Haines, made from a legally owned and acquired copy).

## On NX 18

- Build it from your legally owned and acquired NUP of this exact build (1.2.1, `main`
  `ec47e6f8…`); no other build is registered. It is program 1 of the application, which NX 18
  builds only with the development switch on (`NX18_DEV`, [docs/development.md](../../../docs/development.md));
  without it the build stops with `This program isn't supported yet`. With both programs in the NUP
  and both profiles in the repository, the build picks this one, the Switch 2 program; `--program 0`
  builds the Switch 1 game.
- NX 18 serves one RomFS for every index: this program's own. Upstream packed program 0's RomFS
  beside it (`romfs_programs/0.img`, not taken); the NUP the owner built from holds a merged RomFS in
  program 1 (37,221 entries), which the game booted from.
- Run once on an iPhone 18 Pro Max (2026-11-27, from build `96ed6c798` through NX Play, before this
  profile existed: the build's provisional profile, with the same memory values). It booted to the
  opening with the Switch 2's 9 GB pool in files (9.88 GB of guest files, heap 4.94 GB, footprint
  0.53 GB, 7.96 GB of room to the memory limit). Two problems, both general and fixed by upstream
  commits that are ported on their own:
  - 30 fps: about 13 s in, the game set the present interval 1 → 2 (`main+0x1bc1f0`, its interval
    controller) and stayed there. Upstream's fix is `c17a54984` (`nvnWindowAcquireTexture`'s waits
    moved to `nvnSyncWait`, see [Found on this game](#found-on-this-game)).
  - An abort at the opening movie: the game connected to `auddmg:u` itself, which the host does not
    serve, and aborted with `0xa99` (`sdk+0x22100c`). Upstream's fix is `037b869d6` (the virtual
    output device's properties and the output stream opened without flags).
- Run again on the iPhone 18 Pro Max (2026-11-27, build `53dd77a29` through NX Play, still from the
  provisional profile, with both fixes): it booted into the game and played at about 57 fps (57.6 to
  60.0 in its power ticks), memory pool 9.00 GB, heap 4.94 GB. Its one red graphics line was
  `SetRenderEnableConditional: the host draws anyway for now`, and the picture showed why: the
  draws the game makes only where an occlusion query passed (Mario's silhouette behind scenery, a
  slab under the fountain) were drawn every frame, so Mario's body was solid navy and the floor under
  the fountain a solid blue slab.
- `mem_map_limit on` and `render_cond on` are in [`game.tsv`](game.tsv): upstream's host has both
  for this game (the pool limit for every Switch 2 game, `a694f1799`; conditional rendering for
  every game) and was played so. NX 18's defaults are off, and the provisional profile had neither.
  `render_cond on` makes the host evaluate those conditions, which is what draws the silhouettes
  only where they belong; the red line goes with it.
- No shader tables are registered: `tables_from split` in [`game.tsv`](game.tsv) makes each build
  take them from its own `shader_split.py` run over the legally owned and acquired files it is built
  from, in a shader-only derived profile in the build folder (`<build folder>/profile/040015100B514001`,
  as for installed DLC: every registered key and fix applies, only the tables are the build's). The
  NX 18 build of a registered profile otherwise compares the split with the profile's tables byte for
  byte, and no one set fits this game: the merged 1.2.1 NUP the owner built from splits to 37,306 keys
  with NX 18's reader, while upstream registered 30,630, read from the two-program layout without the
  merged image's two `SecredUber` archives and with its newer BAHS reader (`5df3dbe88`, not in NX 18:
  the stray descriptor at `agl_technique_pfx.sharcb+0x10eda4` left out, and the duplicate shaders in
  `main` filed under other variations). Upstream's tables made a rebuild stop with
  `the split shader tables differ`, so they are not taken. The empty `shader_map.tsv.conflicts.tsv`
  (no key-conflict rulings) is kept.
- [`pso_manifest.tsv`](pso_manifest.tsv): 7,243 rows (6,990 S, 237 R, 1 C, 15 K) from the two iPhone
  runs' own `pso_user.tsv` (the second holds the first's 6,302 rows, then 941 more), in the order of
  first use. The phone recorded only keys of its build's split, and every row checks clean against
  upstream's map (`pso_seed.py`; all the keys lie in the 30,630 the two layouts share). With no
  committed map to check against, the build checks the list against its own split's map
  (`prewarm list: 7,243 rows, every one in this build's shader map`, or a red line naming what is not),
  and the app leaves out any row whose key its map lacks, as for every game. The K rows are one-draw
  passes the phone drew with no pass-as-compute kernel: the next shader build makes those kernels, as
  for Ocarina of Time's 2026-11-25 phone rows.
- Upstream's `validated.tsv` (a green run on upstream's chain) is not taken: it records a result
  of upstream's chain, not NX 18's.

## What it needs

| Setting | Where | Why |
|---|---|---|
| `mem_reserve 0x278000000`, `mem_alias 0x118000000`, `mem_stack 0x10000000`, `app_pool 0x240000000` | [`game.tsv`](game.tsv) | the Switch 2's 9 GB pool; the heap check (2026-11-14) found the first request did not fit and then a 4.94 GB heap, so `mem_reserve` holds it. These are the values the game was played with |
| `sys_resource 0x1000000` | `game.tsv` | the NPDM declares 16 MB of system resource |
| `modules main subsdk0 sdk` | `game.tsv` | the Switch 1 program has no `subsdk0` |
| `romfs_marker System/RegionLangMask.txt` | `game.tsv` | a file in Program 1's stub and merged RomFS layouts. The packer checks the marker in that program's image |

No game-specific executable cuts and no `patches.py`: the rewriter rewrites `main`, `subsdk0` and
`sdk` (`ec47e6f8846d2a7b6892e2682845c725`, `3fddebac0ad5c3f9e018dcadca9e55ed`,
`31945f745022d0232d2562252641b3d3`), and the heap check found no address regions to handle. No
`pad_layout`, so the virtual gamepad starts in the 2D layout.

## Files

- Upstream packed it from `Super Mario Bros Wonder - Nintendo Switch 2 Edition.nup` (8.84 GB): this
  program, program 0's RomFS beside it and the upgrade add-on `010015100B515001` (5.26 GB) as DLC.
- Shaders: upstream's two-program split had 30,629 rows (compute 338, pixel 18,718, vertex 11,573),
  from `Shader/` (11,431, filed as `other`), `Effect/` (10,184), `Lib/` (8,703), `Layout/` (271) and
  40 in `main`; NX 18 registers none (see [On NX 18](#on-nx-18)).
- A merged 1.2.1 NUP tested upstream on 2026-11-19 has the same three program modules and puts
  `System/AddressTable` in Program 1's own RomFS. Two `SecredUber` archives in that image add 6,676
  shader keys, so its 37,305-shader split failed upstream's strict comparison against its registered
  tables. A read-only split omitting those two archives recovered all 30,630 keys.

## Tested and open

- Upstream ([PR #2957](https://github.com/seedds/nxnative/pull/2957)) reports 50–60 fps on an M3
  Pro (macOS 27.2.1, 2026-11-14 to 2026-11-17): the first levels and local co-op courses in Meetup
  in Bellabel Park, save and reload, sound and movies. A merged NUP on an M4 Pro reached the title
  menu and committed its first save.
- Route: [`smoke.tsv`](smoke.tsv) plays a `DM_REC` recording from an empty save: the first-boot
  screens (including the online tutorial) to the opening scene of the Flower Kingdom's castle,
  where the screenshot at 100 s is taken; it does not reach a level. The steps are frame numbers,
  so load time does not move them, and the last hold is stretched to 20,000 frames because a host
  whose scripted input ends exits by itself.
- Tested on NX 18: an iPhone 18 Pro Max (2026-11-27, build `53dd77a29` through NX Play,
  provisional profile) booted into the game at about 57 fps, with the silhouette faults above.
- Open on NX 18: a build from this registered profile (`render_cond on`) with the silhouettes right,
  60 fps in play, Bellabel Park, save and reload, power and heat on the iPhone.

## Found on this game

- Blocking inside `nvnWindowAcquireTexture` inflates a game's measured CPU frame time (upstream
  `c17a54984`): `sead::GameFrameworkNx` (`main+0x1bba10`, interval controller `main+0x1bbee0`,
  `waitDrawDone_` `main+0x184660`) calls `nvnWindowAcquireTexture` before recording draw work and
  measures its CPU frame time before calling `nvnSyncWait(acquire_sync, -1)`, while a presentation
  thread (`main+0xc5900`) submits and presents in parallel. A vsync wait inside the acquire counts
  as CPU time, so the game never steps back from interval 2 (30 fps) to 1 (60 fps).
