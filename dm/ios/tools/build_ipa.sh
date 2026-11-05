#!/bin/bash
# Build one unsigned all-in-one IPA: the rewritten modules compiled into the executable, iOS shader libraries at DmIOS.app/msl, and the game files (RomFS) at DmIOS.app/romfs.
# In IPA mode Xcode skips the large resource copy; tools/pack_ipa.py packs the shader libraries, add-on content and RomFS straight from where they are (no Payload/ copy, nothing through the home disk).
# In --prepare-xcode mode the generated project copies those resources before Xcode signs it with the team the user selects. IPA mode signs only the executable ad-hoc to carry entitlements; this script never installs anything.
# Prerequisites: the rewriter (patched directory) and the iOS shader build (IOSOUT) have been run as in the README; Xcode and xcodegen are installed.
# Usage: dm/ios/tools/build_ipa.sh [output.ipa | --prepare-xcode]; --prepare-xcode generates the project without building, signing or packing.
#   Environment: GAME=game profile (dm/games/<base game title ID>, or one in DM_GAMES_DIR; required), W=the game's work folder (required: <NSP folder>/<title ID>-work, never the home folder), PATCHED / ROMFS / MSL_IOS can each be overridden
#   DM_COPY_ROMFS=NO leaves the game files (RomFS) out of the IPA, as it does for the Xcode build phase: the package then stays small (a large game's full package can exceed what iOS extracts), and the app takes the files from Documents/romfs.img (scripts/push_romfs.sh); default: they are packed
#   DM_ENTITLEMENTS=<plist> is the entitlements, for the prepared Xcode project and the unsigned IPA's ad-hoc signature alike (default: Increased Memory Limit and Extended Virtual Addressing; an empty string = none)
#   AOC=add-on content directory (default $W/data/aoc; when it exists it goes to DmIOS.app/aoc/<index>/; an empty string = none), GFXAPI=nvn / vulkan (default: by the shader libraries in MSL_IOS)
#   The app name is the game name in the base NSP's control data ($W/data/v0/control.nacp, else the one next to the RomFS), the app version is the display version in the packed game's control data (the one next to the RomFS:
#   nx_extract saves the update's there when an update is packed, else the base game's), the bundle ID is org.nxnative.<base game title ID in lowercase> (DM_DISPLAY_NAME / DM_APP_VERSION / DM_BUNDLE_ID override them);
#   CONTROL=<control.nacp> is the file whose languages the launcher's settings offer (the NSP script's languages_control; default: the packed game's control data as above);
#   DM_METAL_CAPTURE=1 makes a development build that can write GPU frame captures (MetalCaptureEnabled in Info.plist, for the host's DM_GPU_CAPTURE switch);
#   DM_SHOW_FPS=1 turns the frame-rate counter on (DMShowFPS in Info.plist; DM_SHOW_FPS in the app's Documents/env.txt overrides it on the phone);
#   DM_LANG=<language code> is the game language (DMLanguage in Info.plist, default en-US; DM_LANG in the app's Documents/env.txt overrides it on the phone);
#   both are also the launcher's defaults (dm/launcher.json from dm/games/settings.py; the player's choice there wins over them, Documents/env.txt over the choice);
#   the IPA name, code modules, RomFS marker and shader tables come from the game profile
#   PROGRAMS_TSV=<file> (the NSP script, a multi-program application: Super Mario 3D All-Stars): one app holding several programs, one row each, "<index>\t<profile>\t<patched>\t<RomFS>\t<iOS shaders>\t<graphics API>",
#   program 0's being GAME / PATCHED / ROMFS / MSL_IOS / GFXAPI (the app's name, version, icon and identity are its). Each program's modules go in sections tagged p<N> (gen_embed.py --tag),
#   its tables and launcher settings in dm/p<N>/, its RomFS and offline HTML pages in p<N>/, its shader libraries in msl/p<N>/, and the host is built over a table of their profiles
#   (game.py header_multi, the first program's profile lists them); main.m picks the program the last oe::ExecuteProgram recorded (Documents/program.bin). With --prepare-xcode the project's build phase copies them so (stage_resources.sh)
#   DM_GEN_REUSE=0 deletes Gen/ and writes all of it again at every run, runs xcodegen every time and signs the executable in Xcode's build folder, as before (default 1: Gen/ is generated in
#   Gen/.stage and only the files whose bytes changed replace Gen/'s, the Xcode project is generated again only when its inputs changed, and the IPA's executable is signed in a copy of the app);
#   DM_SIGN_REUSE=0 signs the executable in Xcode's build folder at every build, as before, and packs it from there (default: it is signed in a copy of the app, $O/sign/DmIOS.app, which is
#   packed instead and kept while the app Xcode built, the entitlements, codesign and macOS are the same)
set -u
cd "$(dirname "$0")/.." || exit 1
IOS_SOURCE=$PWD; IOS=$PWD; DM=$(cd .. && pwd)
t() { echo "[$(date +%T)] $*"; }; die() { t "FAIL: $*"; exit 1; }
[ -n "${GAME:-}" ] || die "GAME is not set: GAME=<base game title ID> $0; profiles: $(python3 "$DM/games/game.py" list | awk -F'\t' '{printf "%s (%s)  ", $1, $3}')"
export GAME; GD=$(python3 "$DM/games/game.py" dir "$GAME") || die "no game profile $GAME"   # dm/games/<id>, or a profile in DM_GAMES_DIR (the NSP script's provisional one); the make that gen_build.py runs uses the same GAME
gp() { python3 "$DM/games/game.py" "$GAME" "$1" || die "game profile $GD: $1"; }   # read a key of the game profile
[ -f "$GD/game.tsv" ] || die "no game profile $GD/game.tsv"
[ -n "${W:-}" ] || die "W is not set: W=<NSP folder>/$GAME-work (the game's work folder) $0"
PKG=$(gp package)
if [ -z "${ROMFS:-}" ] && [ -f "$W/data/$PKG/RomFS.img" ]; then ROMFS=$W/data/$PKG/RomFS.img; fi
PATCHED=${PATCHED:-$W/build/patched_$PKG}; ROMFS=${ROMFS:-$W/data/$PKG/RomFS}; MSL_IOS=${MSL_IOS:-$W/build/ios/dmsh_b}; AOC=${AOC-$W/data/aoc}
PREPARE_XCODE=NO; [ "${1:-}" != --prepare-xcode ] || PREPARE_XCODE=YES
OUT_IPA=${1:-$(dirname "$W")/$(gp ipa)}; O=$W/build/ios/pkg; DD=$O/dd
XCODE_DD=${DM_XCODE_DERIVED_DATA:-$W/build/ios/xcode-dd}
MARKER=$(gp romfs_marker)
NACP=$W/data/v0/control.nacp; [ -f "$NACP" ] || NACP=$(dirname "$ROMFS")/control.nacp
[ -n "${DM_DISPLAY_NAME:-}" ] || DM_DISPLAY_NAME=$(python3 "$DM/tools/nacp.py" "$NACP") || die "no game name in $NACP (re-extract with nx_extract, or set DM_DISPLAY_NAME)"
VNACP=$(dirname "$ROMFS")/control.nacp; [ -f "$VNACP" ] || VNACP=$W/data/v0/control.nacp
[ -n "${DM_APP_VERSION:-}" ] || DM_APP_VERSION=$(python3 "$DM/tools/nacp.py" --version "$VNACP") || { t "no display version in $VNACP: the app version is 1.0"; DM_APP_VERSION=1.0; }
VNACP=${CONTROL:-$VNACP}   # from here on, the file that lists the game's languages for the launcher's settings
export LC_ALL=C DM_BUNDLE_ID=${DM_BUNDLE_ID:-org.nxnative.$(echo "$GAME" | tr 'A-Z' 'a-z')} DM_DISPLAY_NAME DM_APP_VERSION DM_APP_CATEGORY=$(gp app_category) DM_TEAM_ID=${DM_TEAM_ID:-0000000000}   # placeholder identity: unsigned, the install tool replaces it
if [ "${DM_SHOW_FPS:-0}" = 1 ]; then export DM_SHOW_FPS=YES; else export DM_SHOW_FPS=NO; fi
export DM_LANG=${DM_LANG:-en-US}
if [ "$PREPARE_XCODE" = YES ]; then
  IOS=${DM_XCODE_PROJECT_DIR:-$W/xcode}
  mkdir -p "$IOS" || die "mkdir $IOS"
  IOS=$(cd "$IOS" && pwd)
  [ "$IOS" != "$IOS_SOURCE" ] || die "the per-game Xcode project must be outside dm/ios"
  # Source links follow repository edits; generated files and build products belong to this game only. Linked again each time: a project prepared from another checkout (a removed worktree) follows this one
  for item in Sources tools; do ln -sfn "$IOS_SOURCE/$item" "$IOS/$item" || die "link $item"; done
  cp "$IOS_SOURCE/project.yml" "$IOS/project.yml" || die "copy project template"
  cd "$IOS" || die "cd $IOS"
  DM_SCHEME_NAME="$(echo "$DM_DISPLAY_NAME" | tr '/:' '__') ($GAME)"   # the scheme file is named after it

else DM_SCHEME_NAME=DmIOS; fi
export DM_SCHEME_NAME
# The checks of one program's inputs (GAME, GD, PATCHED, ROMFS, MSL_IOS, GFXAPI, MODS, MARKER as set): every program of a game of several programs passes them
check_program() {
[ -f "$PATCHED/main.fixups.tsv" ] || die "no rewritten main in $PATCHED (run dm/tools/patch_nso.py first)"
MODS=$(python3 "$DM/games/game.py" modules "$GAME" "$PATCHED") || die "game profile $GD: modules"   # main's build row, as the host picks them: a version may lack a module another has
for f in $MODS; do [ -f "$PATCHED/$f.patched.bin" ] && [ -f "$PATCHED/$f.fixups.tsv" ] || die "no rewritten module $PATCHED/$f (run dm/tools/patch_nso.py first)"; done
python3 "$DM/tools/romfs.py" "$ROMFS" "$MARKER" || die "no RomFS at $ROMFS (missing $MARKER)"
V=${V:-$(sed -n 's/^#define DMSH_CHAIN "\(.*\)"/\1/p' "$DM/gfx/nvn/dmsh_chain.h")}   # the chain version the host is compiled with, one for every game
# A Vulkan game (Hades): the shaders are the game's SPIR-V, translated by dm/gfx/tools/vk_shaders.py into $MSL_IOS/vk; an OpenGL game (Digimon Story Cyber Sleuth): its GLSL, translated by
# dm/gfx/tools/gl_shaders.py into $MSL_IOS/gl; neither has NVN chain libraries. GFXAPI=nvn / vulkan / gl says which (the NSP script passes what main imports); without it, the shader
# libraries in $MSL_IOS tell: the chain's b-$V, else vk, else gl
if [ -z "${GFXAPI:-}" ]; then if ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$'; then GFXAPI=nvn; elif [ -f "$MSL_IOS/vk/vk_shaders.metallib" ]; then GFXAPI=vulkan;
  elif [ -f "$MSL_IOS/gl/gl_shaders.metallib" ]; then GFXAPI=gl; else GFXAPI=nvn; fi; fi
if [ "$GFXAPI" = vulkan ]; then [ -f "$MSL_IOS/vk/vk_shaders.metallib" ] || die "no iOS Vulkan shader library $MSL_IOS/vk (dm/gfx/tools/vk_shaders.py \"$ROMFS\" <Mac dir> --ios \"$MSL_IOS\")"
elif [ "$GFXAPI" = gl ]; then [ -f "$MSL_IOS/gl/gl_shaders.metallib" ] || die "no iOS GL shader library $MSL_IOS/gl (dm/gfx/tools/gl_shaders.py \"$ROMFS\" <main> <Mac dir> --ios \"$MSL_IOS\")"
else [ -n "$V" ] && ls "$MSL_IOS/b-$V" 2> /dev/null | grep -q '_b.metallib$' || die "no iOS shader libraries $MSL_IOS/b-$V (IOSOUT=$MSL_IOS dmsh_build.py ...)"
  # One chain version serves every game and every state of a profile's tables: the libraries' stamp (b-$V/inputs.tsv, written by a full dmsh_build.py run) must name this game and the
  # digest of its profile's current inputs, and c1_full.tsv (not in the repository: the same build makes it, and cb_extent.tsv, from its Mac outputs) must name that digest, or the host ignores it
  IN=$(DM_GAME="$GAME" python3 "$DM/gfx/tools/dmsh_chain.py" --inputs) || die "dmsh_chain.py --inputs (game profile $GD)"
  grep -qxF "$(printf 'game\t%s' "$GAME")" "$MSL_IOS/b-$V/inputs.tsv" 2> /dev/null && grep -qxF "$(printf 'inputs\t%s' "$IN")" "$MSL_IOS/b-$V/inputs.tsv" ||
    die "the iOS shader libraries $MSL_IOS/b-$V are not a full build from this profile's current tables (inputs $IN; their stamp: $([ -f "$MSL_IOS/b-$V/inputs.tsv" ] && grep -v '^#' "$MSL_IOS/b-$V/inputs.tsv" | tr '\n\t' '  ' || echo none)): build them again (IOSOUT=$MSL_IOS dmsh_build.py ...)"
  head -1 "$GD/c1_full.tsv" 2> /dev/null | grep -q "^# chain b-$V inputs $IN " || die "$GD/c1_full.tsv is missing or not made from these libraries (chain $V, inputs $IN): a full dmsh_build.py run makes it and cb_extent.tsv"; fi
}
check_program
P0=$GAME; P0_PATCHED=$PATCHED; P0_ROMFS=$ROMFS; P0_MSL=$MSL_IOS; P0_GFX=$GFXAPI
prog_rows() { grep -v '^#' "$PROGRAMS_TSV" | grep -v '^$'; }   # index, profile, patched, RomFS, iOS shaders, graphics API
prog_set() {   # the globals of one row's program
  IFS=$'\t' read -r PN GAME PATCHED ROMFS MSL_IOS GFXAPI <<< "$1"; export GAME
  GD=$(python3 "$DM/games/game.py" dir "$GAME") || die "no game profile $GAME"; MODS=$(gp modules); MARKER=$(gp romfs_marker)
  if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; elif [ "$GFXAPI" = gl ]; then MSLDIR=gl; else MSLDIR=b-$V; fi
}
prog_back() { GAME=$P0; export GAME; GD=$(python3 "$DM/games/game.py" dir "$GAME"); PATCHED=$P0_PATCHED; ROMFS=$P0_ROMFS; MSL_IOS=$P0_MSL; GFXAPI=$P0_GFX; MODS=$(gp modules); MARKER=$(gp romfs_marker); }
if [ -n "${PROGRAMS_TSV:-}" ]; then
  [ -f "$PROGRAMS_TSV" ] || die "no PROGRAMS_TSV $PROGRAMS_TSV"
  while IFS= read -r row; do prog_set "$row"; t "program $PN: $GAME ($(gp name)), $GFXAPI"; check_program; done < <(prog_rows)
  prog_back
fi

t "app: $DM_DISPLAY_NAME $DM_APP_VERSION ($DM_BUNDLE_ID), language $DM_LANG$([ $DM_SHOW_FPS = YES ] && echo ', frame-rate counter on')"
# One IPA build at a time per checkout, from generating Gen/ to the end of xcodebuild: in IPA mode every game's build writes the same dm/ios/Gen (its modules, tables, launcher settings, icon
# and Info.plist) and DmIOS.xcodeproj, so two at once (the Drag Here droplet, the Builder, a Terminal) would delete each other's Gen/ or build one game's app from another's code and tables.
# The lock is flock(2) on dm/ios/.ipa-build.lock (git ignores it), taken by python3 on this shell's fd 9: it holds until that fd closes, after xcodebuild or at any exit (a failure, Ctrl-C,
# a closed window, kill -9). xcodebuild, pso_offline.py and git (git status can start its fsmonitor daemon, which stays) run without fd 9, so a process they leave behind cannot keep it. The file names its holder. DM_IPA_LOCK=0 builds without it
ipa_lock() {
  [ "${DM_IPA_LOCK:-1}" != 0 ] || { t "build lock: off (DM_IPA_LOCK=0)"; return 0; }
  local L="$IOS_SOURCE/.ipa-build.lock" who err rc
  local try='import fcntl, sys
try: fcntl.flock(9, fcntl.LOCK_EX | fcntl.LOCK_NB)
except BlockingIOError: sys.exit(3)
except OSError as e: sys.exit(e.strerror or str(e))'   # 3: another build holds it
  exec 9>> "$L" || die "build lock $L"
  err=$(python3 -I -c "$try" 2>&1); rc=$?
  if [ "$rc" = 3 ]; then
    who=$(head -1 "$L" 2> /dev/null)
    t "waiting for another IPA build in this checkout to finish its app build: ${who:-unknown} (Gen/ and the Xcode project are one per checkout; DM_IPA_LOCK=0 builds without waiting)"
    python3 -I -c 'import fcntl, signal; signal.signal(signal.SIGINT, signal.SIG_DFL); fcntl.flock(9, fcntl.LOCK_EX)' || die "build lock $L"
    t "the other IPA build's app is built: going on"
  elif [ "$rc" != 0 ]; then exec 9>&-; t "build lock: none, flock does not work on $L (${err:-exit $rc}): building without it"; return 0; fi   # a volume without flock (some network shares)
  echo "$GAME ($DM_DISPLAY_NAME), pid $$, since $(date +%T)" > "$L"
}
[ "$PREPARE_XCODE" = YES ] || ipa_lock   # a prepared project has its own folder
# Every run makes all of Gen/ again, from nothing, in the generation folder G. With DM_GEN_REUSE on (the default) G is Gen/.stage, and dm/ios/tools/gen_reuse.py sync then makes Gen/ the same
# as it: a file whose bytes did not change stays as it is, times and all, any other file is replaced, and a file this run did not make (another game's tables, cheats, icon or variants pages)
# goes. Xcode's build goes by the size and modification time of each input (and keeps working across the NSP script's tar of its derived data, tree_tar.py, which keeps the times), so a
# repeat build of the same game assembles embed.S, links, runs actool and copies the tables only when they changed, and another game's build gets exactly its own files. embed.S names
# the sha256 of every file it includes (gen_embed.py), since Xcode cannot see a change in them. Gen/.reuse holds what tells a later run that the icon and the Xcode project are this run's.
# DM_GEN_REUSE=0: G is Gen/ itself, deleted first, as before
GEN_REUSE=1; [ "${DM_GEN_REUSE:-1}" != 0 ] || GEN_REUSE=0
t "generate Gen/ (host sources, embedded modules, tables$([ "$GEN_REUSE" = 1 ] && echo '; only the files that changed replace those in Gen/' || echo '; DM_GEN_REUSE=0: all of them again'))"
if [ "$GEN_REUSE" = 1 ]; then G=Gen/.stage; { [ -d Gen ] && [ ! -L Gen ]; } || rm -rf Gen; rm -rf "$G" && mkdir -p "$G/dm" Gen/.reuse || die "mkdir $G"
else G=Gen; rm -rf Gen && mkdir -p Gen/dm || die "mkdir Gen"; fi
python3 tools/gen_build.py "$DM/host" "$G" > "$G/dm.xcconfig" || die "gen_build"
if [ -n "${PROGRAMS_TSV:-}" ]; then   # each program's modules under its tag (the host is built over a table of the programs' profiles: the first program's profile lists them, game.py header_multi)
  F=; : > "$G/embed.S"
  while IFS= read -r row; do prog_set "$row"
    J=(); [ -f "$(dirname "$ROMFS")/jit/jit.img" ] && J=(--jit "$(dirname "$ROMFS")/jit/jit.img")   # the nn::jit image (dm/tools/jit_capture.py), beside the RomFS
    F="$F $(python3 tools/gen_embed.py --tag "p$PN" --ref-dir "$IOS/Gen" ${J[@]+"${J[@]}"} "$PATCHED" "$G/embed_p$PN.S" $MODS)" || die "gen_embed (program $PN)"
    cat "$G/embed_p$PN.S" >> "$G/embed.S" && rm "$G/embed_p$PN.S"
  done < <(prog_rows); prog_back
else J=(); [ -f "$(dirname "$ROMFS")/jit/jit.img" ] && J=(--jit "$(dirname "$ROMFS")/jit/jit.img")
  F=$(python3 tools/gen_embed.py --ref-dir "$IOS/Gen" ${J[@]+"${J[@]}"} "$PATCHED" "$G/embed.S" $MODS) || die "gen_embed"; fi   # --ref-dir: the variants pages' .incbin names Gen/, where they end up
echo "OTHER_LDFLAGS = \$(inherited) \$(DM_FRAMEWORKS) $F" >> "$G/dm.xcconfig"
# The Swift language mode of the app's Swift (project.yml SWIFT_VERSION): 6.0, the newest; DM_SWIFT_VERSION=5 builds in the Swift 5 mode, should a newer compiler find fault with the 6 mode
echo "DM_SWIFT_VERSION = ${DM_SWIFT_VERSION:-6.0}" >> "$G/dm.xcconfig"
case "${DM_DEVICE_FAMILY:-1,2}" in 1 | 2 | 1,2) ;; *) die "DM_DEVICE_FAMILY must be 1 (iPhone), 2 (iPad) or 1,2: $DM_DEVICE_FAMILY";; esac
echo "DM_DEVICE_FAMILY = ${DM_DEVICE_FAMILY:-1,2}" >> "$G/dm.xcconfig"   # the devices the app installs on (TARGETED_DEVICE_FAMILY, project.yml): the NSP script's --device
# One program's tables into TD: the rewriter's, the shader tables and the launcher's settings
program_tables() {
cp "$PATCHED"/*.fixups.tsv "$PATCHED"/*.gates.tsv "$PATCHED"/*.cuts.tsv "$PATCHED"/*.obs.tsv $TD/ || die "copy rewriter tables"
if [ -f "$PATCHED/nro.tsv" ]; then cp "$PATCHED/nro.tsv" $TD/ || die "copy the NRO table"; fi   # the NRO modules the game loads with nn::ro (hle_ro.c), embedded by gen_embed.py
if [ "$GFXAPI" = vulkan ] || [ "$GFXAPI" = gl ]; then cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" $TD/ || die "copy shader tables"   # empty NVN tables: the NVN layer draws nothing
else cp "$GD/shader_map.tsv" "$GD/pso_manifest.tsv" "$GD/c1_full.tsv" $TD/ || die "copy shader tables"
  if [ -f "$GD/cb_extent.tsv" ]; then cp "$GD/cb_extent.tsv" $TD/ || die "copy cb_extent.tsv"; else t "no $GD/cb_extent.tsv: the host copies whole uniform bindings"; fi
  # the shader pairs, beside the shader map where the pipeline prebuild reads them (nvn_mtl.m pso_prebuild): without them the app makes no pulling bases, and a hybrid draw has no stand-in
  for f in shader_pairs.tsv pso_pairs.tsv; do if [ -f "$GD/$f" ]; then cp "$GD/$f" $TD/ || die "copy $f"; fi; done; fi   # optional
# The launcher's settings for this game (Launcher.swift): dm/games/settings.tsv filtered by the profile, main's rewriter table and the game's languages (dm/games/settings.py)
L=$(GFXAPI="$GFXAPI" python3 "$DM/games/settings.py" "$GAME" "$PATCHED" "$VNACP" $TD/launcher.json) || die "launcher settings (dm/games/settings.py)"; t "launcher: $L"
}
if [ -n "${PROGRAMS_TSV:-}" ]; then
  : > "$G/dm/programs.txt"
  while IFS= read -r row; do prog_set "$row"; TD=$G/dm/p$PN; mkdir -p "$TD" || die "mkdir $TD"; VNACP=$(dirname "$ROMFS")/control.nacp; [ "$PN" != 0 ] || VNACP=${CONTROL:-$VNACP}; program_tables; echo "$PN" >> "$G/dm/programs.txt"; done < <(prog_rows)
  prog_back
  LJ=$G/dm/p0/launcher.json
else TD=$G/dm; program_tables; LJ=$G/dm/launcher.json; fi
# The pipeline archive made offline (dm/gfx/tools/pso_offline.py): the base of every shader pair, compiled here by metal-tt for each GPU architecture in DM_PSO_GPUS (comma-separated, as
# MTLDevice.architecture names them: g19p = the A20 Pro of the iPhone 18 Pro Max, g16g = the M4 of the iPad Pro; none = no archive), so the device does not build them on its first start
# (Breath of the Wild: 15,767 bases, 7-8 minutes on an iPhone 17 Pro Max). The host opens only the archive named after its device's GPU (nvn_mtl.m pso_bundle_open).
# Without DM_PSO_GPUS a game whose profile sets pso_mtl4 on gets the archive for the GPUs of the devices the app is for, as the NSP script makes it (its DEVICE_ARCH): DM_DEVICE_FAMILY 1 = g19p,
# 2 = g16g, 1,2 = both. 13 Sentinels crashed Metal 4 on an A20 Pro with a g18p archive and ran with a g19p one (dm/games/01003FC01670C000/README.md); the profile's pso_gpu key does not
# change this default. The games that do not set pso_mtl4 on get none. It goes into the app as pso/ (main.m hands it to the host as
# DM_PSO_BUNDLE), with the pulling vertex libraries the bases are made of. Each architecture adds about 650 MB to the app (Breath of the Wild; 220 MB in the IPA) and 4 minutes to the first build;
# made again only when its inputs change (the libraries, the pairs, the profile's depth_mode, metal-tt)
PSO=; P4=$(python3 "$DM/games/game.py" "$GAME" pso_mtl4 off) || die "game profile $GD: pso_mtl4"; PG=$(python3 "$DM/games/game.py" "$GAME" pso_gpu '') || die "game profile $GD: pso_gpu"
case "${DM_DEVICE_FAMILY:-1,2}" in 1) PGK=g19p ;; 2) PGK=g16g ;; *) PGK=g19p,g16g ;; esac   # the GPUs of the devices the app installs on
if [ -n "${DM_PSO_GPUS+set}" ]; then GPUS=$DM_PSO_GPUS; elif [ "$P4" = on ]; then GPUS=$PGK
  [ -z "$PG" ] || t "profile $GD: pso_gpu '$PG' is not used: the archive is made for the GPUs of the devices the app is for, $PGK (DM_PSO_GPUS names others)"
else GPUS=none; fi
if [ "$GFXAPI" = nvn ] && [ -n "$GPUS" ] && [ "$GPUS" != none ] && [ -f "$GD/shader_pairs.tsv" ]; then
  PSO=$W/build/ios/pso/bundle
  t "pipeline archive for $GPUS (metal-tt; minutes when its inputs changed)"
  python3 "$DM/gfx/tools/pso_offline.py" --game "$GAME" --msl "$MSL_IOS/b-$V" --out "$PSO" --work "$W/build/ios/pso/work" --gpu "$GPUS" ${DM_PSO_IOS_MIN:+--os-min "$DM_PSO_IOS_MIN"} 9>&- \
    | while IFS= read -r ln; do t "$ln"; done
  if [ "${PIPESTATUS[0]}" != 0 ]; then   # an optimization: the device builds the bases on its first start without it
    t "[RED] pipeline archive: pso_offline.py failed (its output is above); the app is built without one and the device builds its pipeline bases on its first start (DM_PSO_GPUS=none skips this step)"
    rm -rf "$PSO"; PSO=
  fi
else [ "$GFXAPI" != nvn ] || t "no pipeline archive ($([ -n "${DM_PSO_GPUS+set}" ] && echo "DM_PSO_GPUS=${GPUS:-empty}" || echo "the profile does not set pso_mtl4 on; DM_PSO_GPUS=$PGK builds one")$([ -f "$GD/shader_pairs.tsv" ] || echo ', no shader_pairs.tsv'))"; fi
# The packed language (DMLanguage) is the Game language row's default, which settings.py makes the game's first language when it lacks DM_LANG: the screen and DM_LAUNCHER=0 then agree
LD=$(python3 -c 'import json, sys; print(next((s["default"] for s in json.load(open(sys.argv[1]))["settings"] if s["env"] == "DM_LANG"), ""))' $LJ) || die "launcher settings ($LJ)"
if [ -n "$LD" ] && [ "$LD" != "$DM_LANG" ]; then t "game language: the game has no $DM_LANG; packing $LD, its first"; export DM_LANG=$LD; fi
# Diagnostic build: DM_ENV_FILE=file → dm/env.txt in the bundle (main.m sets one environment variable per line at boot)
if [ -n "${DM_ENV_FILE:-}" ]; then cp "$DM_ENV_FILE" "$G/dm/env.txt" || die "copy DM_ENV_FILE"; t "env: $(grep -v '^#' "$DM_ENV_FILE" | tr '\n' ' ')"; fi
# Cheats from the NSP script's mods folder (DM_PACKED_CHEATS, dm/tools/game_mods.py): dm/cheats in the bundle, which main.m copies into Documents/cheats at the first start (a file the player has there is kept)
if [ -n "${DM_PACKED_CHEATS:-}" ] && [ -d "$DM_PACKED_CHEATS" ]; then mkdir -p "$G/dm/cheats" && cp "$DM_PACKED_CHEATS"/*.txt "$G/dm/cheats/" || die "copy DM_PACKED_CHEATS"; t "cheats: $(cd "$DM_PACKED_CHEATS" && ls *.txt | tr '\n' ' ')"; fi
# The shader libraries go into the archive as DmIOS.app/msl/<folder> (main.m sets DM_MSL_DIR to it)
if [ "$GFXAPI" = vulkan ]; then MSLDIR=vk; elif [ "$GFXAPI" = gl ]; then MSLDIR=gl; else MSLDIR=b-$V; fi
# Shared-font stand-ins: standard = macOS's Arial Unicode (absent on iOS), Nintendo extension = button icons generated by make_ext_font.py (needs fontTools; FONT_PY names a python that has it)
mkdir -p "$G/dm/font" && cp "${STD_FONT:-/System/Library/Fonts/Supplemental/Arial Unicode.ttf}" "$G/dm/font/standard.ttf" || die "copy standard font (STD_FONT=a TTF)"
# fontTools stamps the font's head table (created, modified) with the time it is made, unless SOURCE_DATE_EPOCH names another (fontTools 4.0 and later, for reproducible builds). With
# DM_GEN_REUSE on it is a fixed date, 2020-01-01, unless the environment sets one: the same font then has the same bytes and Gen/dm, which Xcode copies whole into the app, stays unchanged.
# Font readers do not use these dates
FE=; [ "$GEN_REUSE" != 1 ] || FE=${SOURCE_DATE_EPOCH:-1577836800}
( [ -z "$FE" ] || export SOURCE_DATE_EPOCH="$FE"; exec "${FONT_PY:-python3}" "$DM/tools/make_ext_font.py" "$G/dm/font/nintendo_ext.ttf" ) > /dev/null || die "make_ext_font.py (pip install fonttools, or FONT_PY=python with fontTools)"
# App icon: the game's own icon (icon.jpg saved from the control data by nx_extract, the English 256x256 one). DM_ICON can point at another image; by default the icon.jpg next to the RomFS is used.
# It is scaled to a 1024x1024 PNG in the asset catalog Gen/Assets.xcassets (a single-size app icon; actool generates the other sizes); with neither, no icon is set and the home-screen icon is blank.
# The catalog is always created (the project always lists it, see project.yml); without an icon it stays empty and DM_APPICON is not set
ICON=${DM_ICON:-$(dirname "$ROMFS")/icon.jpg}
mkdir -p "$G/Assets.xcassets" && printf '{"info":{"author":"xcode","version":1}}\n' > "$G/Assets.xcassets/Contents.json" || die "asset catalog"
# With DM_GEN_REUSE on, the PNG Gen/ has is used again when the last build made it from an image with the same bytes (Gen/.reuse/icon: that image's sha256 with the macOS build, then the
# PNG's sha256), so sips does not run and the catalog keeps its bytes, whether or not sips writes the same PNG twice; another image, another game's, is converted
IK=; IP=Gen/Assets.xcassets/AppIcon.appiconset/icon.png
if [ -f "$ICON" ]; then
  AI=$G/Assets.xcassets/AppIcon.appiconset; mkdir -p "$AI" || die "mkdir $AI"
  [ "$GEN_REUSE" != 1 ] || IK=$(python3 -I tools/gen_reuse.py digest --text "sips -s format png -z 1024 1024, macOS $(sw_vers -buildVersion 2> /dev/null)" --file "$ICON") || die "the icon's key"
  if [ -n "$IK" ] && [ -f "$IP" ] && [ "$(cat Gen/.reuse/icon 2> /dev/null)" = "$IK $(python3 -I tools/gen_reuse.py digest --file "$IP")" ]; then cp "$IP" "$AI/icon.png" || die "copy the icon"
  else sips -s format png -z 1024 1024 "$ICON" --out "$AI/icon.png" > /dev/null || die "sips: cannot convert the icon $ICON"; fi
  printf '{"images":[{"filename":"icon.png","idiom":"universal","platform":"ios","size":"1024x1024"}],"info":{"author":"xcode","version":1}}\n' > "$AI/Contents.json"
  echo "DM_APPICON = AppIcon" >> "$G/dm.xcconfig"
  t "app icon: $ICON"
else t "no app icon ($ICON not found): the home-screen icon stays blank"; fi
# The memory entitlements every build asks for: Increased Memory Limit (iOS lets the app use more of the device's RAM before it closes it; the bigger games need it) and Extended Virtual
# Addressing (iOS lets the app reserve more address space than the 5 to 6 GB it gets without it, docs/reference/memory.md: games that reserve a large block need it; it costs nothing
# otherwise). Both need a team that can provision them: an Apple Developer Program team provisions both, a free Personal Team only Increased Memory Limit, so a free team's build
# gives DM_ENTITLEMENTS a plist without the second
ENT_DEFAULT='<plist version="1.0"><dict><key>com.apple.developer.kernel.increased-memory-limit</key><true/><key>com.apple.developer.kernel.extended-virtual-addressing</key><true/></dict></plist>'
# A prepared Xcode project is signed in Xcode, so it asks for them; DM_ENTITLEMENTS=another plist, or empty for none.
# The unsigned IPA carries the same request in its executable's ad-hoc signature below; the install tool replaces that signature.
if [ "$PREPARE_XCODE" = YES ] && [ -n "${DM_ENTITLEMENTS-default}" ]; then
  if [ -n "${DM_ENTITLEMENTS:-}" ]; then cp "$DM_ENTITLEMENTS" "$G/DmIOS.entitlements" || die "copy DM_ENTITLEMENTS"
  else printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    "$ENT_DEFAULT" > "$G/DmIOS.entitlements" || die "entitlements"; fi
  echo "CODE_SIGN_ENTITLEMENTS = Gen/DmIOS.entitlements" >> "$G/dm.xcconfig"
  t "entitlements: $(plutil -convert json -o - "$G/DmIOS.entitlements")"
fi
# DM_COPY_ROMFS=NO also for the prepared project: its Copy game resources phase (stage_resources.sh) then leaves the game files out and writes the image's identity; Gen/dm.xcconfig is made again by every run
[ "${DM_COPY_ROMFS:-YES}" != NO ] || [ "$PREPARE_XCODE" != YES ] || echo "DM_COPY_ROMFS = NO" >> "$G/dm.xcconfig"
RP=; if [ -n "${PROGRAMS_TSV:-}" ]; then   # a game of several programs: each program's files, which the Xcode build phase copies under p<index> as the IPA has them (stage_resources.sh)
  RP=Gen/resources_programs.tsv; printf '# program\tRomFS\tmarker\tiOS shaders\tshader folder (build_ipa.sh)\n' > "$G/resources_programs.tsv"   # RP: the path resources.env names
  M0=$MSLDIR; while IFS= read -r row; do prog_set "$row"; printf '%s\t%s\t%s\t%s\t%s\n' "$PN" "$ROMFS" "$MARKER" "$MSL_IOS/$MSLDIR" "$MSLDIR" >> "$G/resources_programs.tsv"; done < <(prog_rows); prog_back; MSLDIR=$M0; fi
gen_res() { DM_RESOURCE_BUILD=${PKG:-} GAME=$GAME python3 tools/gen_resources.py "$@" "$IOS" "$ROMFS" "$MARKER" "$MSL_IOS/$MSLDIR" "$MSLDIR" "$AOC" "$XCODE_DD" "$DM/gfx/nvn/dmsh_chain.h" "$PSO" $RP || die "generate Xcode resource paths"; }
if [ "$GEN_REUSE" = 1 ]; then   # resources.env and the derived data line into G too, then G becomes Gen/ (the icon's record goes first and is written again for this run's icon)
  gen_res --gen "$G" --no-workspace
  rm -f Gen/.reuse/icon
  S=$(python3 -I tools/gen_reuse.py sync "$G" Gen --keep .reuse --keep Info.plist) || die "update Gen/ from $G"; t "Gen/: $S"
  [ -z "$IK" ] || [ ! -f "$IP" ] || echo "$IK $(python3 -I tools/gen_reuse.py digest --file "$IP")" > Gen/.reuse/icon || die "Gen/.reuse/icon"
fi
# DMCommit / DMChain: the checkout that built the app (+dirty with uncommitted changes to tracked files) and the shader chain it carries, which the host logs at start (main.c)
COMMIT=$(git -C "$DM" rev-parse --short=12 HEAD 2> /dev/null 9>&-) && { [ -z "$(git -C "$DM" status --porcelain --untracked-files=no 2> /dev/null 9>&-)" ] || COMMIT=$COMMIT+dirty; } || COMMIT=
plist_keys() {   # what this script adds to the Info.plist xcodegen writes
  [ -z "$COMMIT" ] || /usr/libexec/PlistBuddy -c "Add :DMCommit string $COMMIT" Gen/Info.plist > /dev/null || die "DMCommit"
  case "$MSLDIR" in b-*) /usr/libexec/PlistBuddy -c "Add :DMChain string ${MSLDIR#b-}" Gen/Info.plist > /dev/null || die "DMChain";; esac
  # DM_METAL_CAPTURE=1: a development build that may write GPU frame captures (MetalCaptureEnabled; the host's DM_GPU_CAPTURE switch writes them to Documents/gpu_captures)
  [ "${DM_METAL_CAPTURE:-0}" != 1 ] || /usr/libexec/PlistBuddy -c "Add :MetalCaptureEnabled bool true" Gen/Info.plist > /dev/null || die "MetalCaptureEnabled"
}
# With DM_GEN_REUSE on, xcodegen runs only when the project's inputs changed: project.yml, the environment values it names (the app's name, bundle ID, version, language, frame-rate counter,
# scheme), xcodegen's version, the files it lists (Sources/ and Gen/, not inside the folder Gen/dm or the catalog), Gen/dm.xcconfig, the entitlements and the keys plist_keys adds; and only
# when the project and Info.plist are still what it wrote then (Gen/.reuse/xcodegen: both digests). Otherwise it runs as before, and an Info.plist with the bytes of the last one keeps its times
xc_out() { python3 -I tools/gen_reuse.py digest --file DmIOS.xcodeproj/project.pbxproj --file DmIOS.xcodeproj/project.xcworkspace/contents.xcworkspacedata --tree DmIOS.xcodeproj/xcshareddata --file Gen/Info.plist; }
XK=; [ "$GEN_REUSE" != 1 ] || XK=$(python3 -I tools/gen_reuse.py digest --text "$IOS" --text "$(xcodegen --version 2>&1)" --file project.yml --env-of project.yml --file Gen/dm.xcconfig \
  --file Gen/DmIOS.entitlements --list Sources --list Gen --skip Gen/.reuse --skip Gen/.stage --skip Gen/Info.plist --shallow Gen/dm --shallow Gen/Assets.xcassets \
  --text "DMCommit $COMMIT, $MSLDIR, MetalCaptureEnabled ${DM_METAL_CAPTURE:-0}") || die "the Xcode project's inputs"
if [ -n "$XK" ] && [ "$(cat Gen/.reuse/xcodegen 2> /dev/null)" = "$XK $(xc_out)" ]; then t "Xcode project: its inputs are unchanged, kept (DM_GEN_REUSE=0 generates it again)"
else
  [ "$GEN_REUSE" != 1 ] || [ ! -f Gen/Info.plist ] || mv -f Gen/Info.plist Gen/.reuse/Info.plist.last || die "Info.plist"
  xcodegen generate -q > /dev/null || die "xcodegen"
  plist_keys
  if [ "$GEN_REUSE" = 1 ]; then
    if [ -f Gen/.reuse/Info.plist.last ] && cmp -s Gen/.reuse/Info.plist.last Gen/Info.plist; then mv -f Gen/.reuse/Info.plist.last Gen/Info.plist || die "Info.plist"; else rm -f Gen/.reuse/Info.plist.last; fi
    echo "$XK $(xc_out)" > Gen/.reuse/xcodegen || die "Gen/.reuse/xcodegen"
  fi
fi
[ -z "$COMMIT" ] || t "source: $COMMIT"
[ "${DM_METAL_CAPTURE:-0}" != 1 ] || t "Metal frame capture: enabled (DM_METAL_CAPTURE=1)"
if [ "$GEN_REUSE" = 1 ]; then gen_res --workspace-only; else gen_res; fi   # the workspace settings after xcodegen; DM_GEN_REUSE=0 writes the Gen files here too, as before
if [ "$PREPARE_XCODE" = YES ]; then
  t "Xcode project: $IOS/DmIOS.xcodeproj"
  t "Xcode derived data: $XCODE_DD"
  t "scheme: $DM_SCHEME_NAME"
  t "ready: select your Team in Signing & Capabilities, select a physical device, and Run (Release)"
  exit 0
fi

t "xcodebuild (Release, unsigned, iPhone + iPad)"
mkdir -p "$O"
xcodebuild -project DmIOS.xcodeproj -scheme DmIOS -configuration Release -destination 'generic/platform=iOS' -derivedDataPath "$DD" \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY= DM_COPY_GAME_RESOURCES=NO \
  DM_XCODE_OUTPUT_ROOT="$DD" SYMROOT="$DD/Build/Products" OBJROOT="$DD/Build/Intermediates.noindex" build > "$O/build.log" 2>&1 9>&- \
  || { grep -E 'error:' "$O/build.log" | head -20; die "xcodebuild, log $O/build.log"; }
exec 9>&-   # the build lock (ipa_lock): signing and packing below read only this game's files
# SYMROOT and OBJROOT above keep the unsigned build separate from the interactive Xcode app.
APP=$DD/Build/Products/Release-iphoneos/DmIOS.app
[ -n "$APP" ] && [ -d "$APP" ] || die "no built app"; t "app: $APP"

# Straight from the sources: the app without its signature, and without the folders an app built before pack_ipa.py still has (DerivedData keeps resources that left the project;
# msl/ is also deleted there, it took 1.5 GB of the home disk), then the shader libraries, the add-on content (the RomFS extracted from the player's DLC NSPs, one folder per index:
# the app sets DM_AOC_DIR at launch, the host reports them as owned and mounts them from it) and the RomFS
rm -rf "$APP/msl" "$O/Payload"   # Payload/: what the copy-and-zip packing left behind, as was out.ipa (and its index) unless it is the IPA packed here, which a repeat pack reuses
[ "$O/out.ipa" -ef "$OUT_IPA" ] || rm -f "$O/out.ipa"; [ "$O/out.ipa.idx" -ef "$OUT_IPA.idx" ] || rm -f "$O/out.ipa.idx"
# The entitlements of an unsigned IPA: an unsigned build has no signature for a sideloader to read them from, so the Increased Memory Limit request would be lost (AltStore and others carry over
# the entitlements of the signature they replace; the Xcode project gets them through CODE_SIGN_ENTITLEMENTS, above). The executable gets an ad-hoc signature that carries them: the sideloader
# replaces the signature and keeps the entitlements. Only the executable is signed: the bundle's resources are packed from elsewhere and the signature is replaced anyway
# Where: in a copy of the app, $O/sign/DmIOS.app (an APFS clone where the volume can: no space, no time), which is then packed in its place. Signed in Xcode's own product, the executable
# looked changed to Xcode, which linked it again at the next build, and to pack_ipa.py, which keeps an IPA entry only while its file's size, times and inode are the same, so it was deflated
# again. The copy is signed again only when the app Xcode built (every file but the folders the packing skips: codesign signs the app the executable is in, so its resources count), the
# entitlements, codesign or the macOS build differ from the last signing, or the copy was touched since ($O/sign/key); a repeat build then packs the same signed executable.
# DM_SIGN_REUSE=0 (or DM_GEN_REUSE=0) signs Xcode's product in place at every build, as before
PACK_APP=$APP   # the app the IPA is packed from
if [ -n "${DM_ENTITLEMENTS-default}" ]; then
  ENT=$O/DmIOS.entitlements
  if [ -n "${DM_ENTITLEMENTS:-}" ]; then cp "$DM_ENTITLEMENTS" "$ENT" || die "copy DM_ENTITLEMENTS"
  else printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
    "$ENT_DEFAULT" > "$ENT" || die "entitlements"; fi
  EXE=$APP/DmIOS; [ ! -f "$APP/Info.plist" ] || EXE=$APP/$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Info.plist") || die "CFBundleExecutable of $APP"
  if [ "${DM_GEN_REUSE:-1}" != 0 ] && [ "${DM_SIGN_REUSE:-1}" != 0 ]; then
    SD=$O/sign; SA=$O/sign/DmIOS.app; SX=$SA/${EXE##*/}; CS=(); TS=()
    for f in _CodeSignature embedded.mobileprovision msl aoc romfs romfs.img romfs.id html jit; do CS+=(--skip "$f"); TS+=(--skip "$APP/$f"); done   # the packing's SKIP below
    SK=$(python3 -I tools/gen_reuse.py digest --text "codesign --force --sign - --entitlements, $(command -v codesign), macOS $(sw_vers -buildVersion 2> /dev/null)" --file "$ENT" --tree "$APP" "${TS[@]}") ||
      die "the signature's inputs ($APP)"
    if [ -f "$SX" ] && [ "$(cat "$SD/key" 2> /dev/null)" = "$SK $(python3 -I tools/gen_reuse.py digest --stat "$SA")" ] && codesign -d --entitlements - "$SX" > /dev/null 2>&1; then
      t "entitlements: the app is the one signed last time, its ad-hoc signature is kept ($SA; DM_SIGN_REUSE=0 signs it again)"
    else
      rm -f "$SD/key"; mkdir -p "$SD" || die "mkdir $SD"
      python3 -I tools/gen_reuse.py copy-app "$APP" "$SA" "${CS[@]}" || die "copy $APP to $SA"
      xattr -cr "$SA" 2> /dev/null   # codesign refuses a file with a resource fork, Finder information or quarantine attributes
      codesign --force --sign - --entitlements "$ENT" "$SX" || die "ad-hoc signature with the entitlements"
      codesign -d --entitlements - "$SX" > /dev/null 2>&1 || die "the executable's signature has no entitlements"
      echo "$SK $(python3 -I tools/gen_reuse.py digest --stat "$SA")" > "$SD/key" || die "$SD/key"
      t "entitlements in the executable's ad-hoc signature (the install tool re-signs and keeps them)"
    fi
    PACK_APP=$SA
  else
    xattr -cr "$EXE" 2> /dev/null   # codesign refuses a file with a resource fork, Finder information or quarantine attributes
    codesign --force --sign - --entitlements "$ENT" "$EXE" || die "ad-hoc signature with the entitlements"
    codesign -d --entitlements - "$EXE" > /dev/null 2>&1 || die "the executable's signature has no entitlements"
    t "entitlements in the executable's ad-hoc signature (the install tool re-signs and keeps them)"
  fi
fi
P=Payload/DmIOS.app
SKIP=(--skip $P/_CodeSignature --skip $P/embedded.mobileprovision --skip $P/msl --skip $P/aoc --skip $P/romfs --skip $P/romfs.img --skip $P/romfs.id --skip $P/html --skip $P/jit)
if [ -n "${PROGRAMS_TSV:-}" ]; then   # each program's shader libraries, RomFS, offline HTML pages and nn::jit image under its own folder
  [ "${DM_COPY_ROMFS:-YES}" != NO ] || die "DM_COPY_ROMFS=NO: a game of several programs keeps its programs' files in the app"
  MAPS=("$P=${PACK_APP:-$APP}")   # PACK_APP: the signed copy (above)
  if [ -n "$AOC" ] && [ -d "$AOC" ]; then MAPS+=("$P/aoc=$AOC"); fi
  while IFS= read -r row; do prog_set "$row"; SKIP+=(--skip "$P/p$PN")
    if [ -f "$ROMFS" ]; then MAPS+=("$P/p$PN/romfs.img=$ROMFS"); else MAPS+=("$P/p$PN/romfs=$ROMFS"); fi
    MAPS+=("$P/msl/p$PN/$MSLDIR=$MSL_IOS/$MSLDIR")
    if [ -d "$(dirname "$ROMFS")/html" ]; then MAPS+=("$P/p$PN/html=$(dirname "$ROMFS")/html"); fi
    if [ -d "$(dirname "$ROMFS")/jit" ]; then MAPS+=("$P/p$PN/jit=$(dirname "$ROMFS")/jit"); t "program $PN: nn::jit image $(dirname "$ROMFS")/jit"; fi   # beside its RomFS (loader.c dm_jit_serve_dir)
  done < <(prog_rows); prog_back
else
MAPS=()
if [ "${DM_COPY_ROMFS:-YES}" = NO ]; then
  t "no game files in the IPA (DM_COPY_ROMFS=NO): the app takes Documents/romfs.img (scripts/push_romfs.sh)"
  # The image's identity (dm/host/romfs_identity.h) goes into the app as romfs.id: main.m then uses only a Documents/romfs.img with the same size and index hash, and says so when it is another version or missing.
  # A RomFS folder has no image to name yet (push_romfs.sh packs it on the Mac), so such a build carries no identity and accepts any complete image
  if [ -f "$ROMFS" ]; then
    mkdir -p "$O" && python3 -I "$DM/tools/romfs_image.py" --identity "$ROMFS" "$GAME" "$DM_APP_VERSION" "${PKG:-}" > "$O/romfs.id" || die "identity of $ROMFS"
    MAPS=("$P/romfs.id=$O/romfs.id"); t "game files identity: $(cat "$O/romfs.id")"
  fi
elif [ -f "$ROMFS" ]; then MAPS=("$P/romfs.img=$ROMFS"); else MAPS=("$P/romfs=$ROMFS"); fi
if [ -n "$AOC" ] && [ -d "$AOC" ]; then MAPS+=("$P/aoc=$AOC"); t "add-on content: $(ls "$AOC" | tr '\n' ' ')"; fi
if [ -n "${PSO:-}" ]; then MAPS+=("$P/pso=$PSO"); fi
MAPS+=("$P/msl/$MSLDIR=$MSL_IOS/$MSLDIR" "$P=${PACK_APP:-$APP}")   # PACK_APP: the signed copy (above)
  if [ -d "$(dirname "$ROMFS")/html" ]; then MAPS+=("$P/html=$(dirname "$ROMFS")/html"); t "offline HTML pages: $(dirname "$ROMFS")/html"; fi   # beside its RomFS, where the host finds them (hle_web.c)
  if [ -d "$(dirname "$ROMFS")/jit" ]; then MAPS+=("$P/jit=$(dirname "$ROMFS")/jit"); t "nn::jit image: $(dirname "$ROMFS")/jit"; fi
fi
t "pack IPA (already-compressed game files stored, everything else deflated)"
# The pulling vertex libraries (<key>_bp, dm/gfx/tools/dmsh_pull.py) serve the hybrid pipelines, which every game uses on iOS now that Metal 4 pipelines are on by default (nvn_mtl.m
# pso4_on), so they are packed by default; IOS_PULL=0 leaves them out (a game then run with Metal 4 pipelines builds each new pipeline before drawing it). The pipeline archive's bases are
# made of them, so an IPA with an archive (pso/) always carries them, whatever IOS_PULL says (an Xcode build copies them always).
PULL=1
# Keep this array nonempty: macOS Bash 3.2 treats an empty array as unset under set -u.
ZS=$(gp zip_store); [ -z "${PROGRAMS_TSV:-}" ] || ZS=$(for g in $(prog_rows | cut -f2); do python3 "$DM/games/game.py" "$g" zip_store; done | tr ':' '\n' | sort -u | paste -sd: -)   # every program's
PACK_OPTS=(--store "$ZS"); [ -n "${PSO:-}" ] || [ "${IOS_PULL:-$PULL}" = 1 ] || PACK_OPTS+=(--skip-suffix _bp.metallib)
python3 tools/pack_ipa.py "$OUT_IPA" "${PACK_OPTS[@]}" "${SKIP[@]}" "${MAPS[@]}" || die "pack_ipa"
t "done: $OUT_IPA ($(du -h "$OUT_IPA" | cut -f1))"
