#!/bin/bash
# Builds a game's IPA from its folder: what the "Drag Here" droplet (scripts/make_drag_here.sh) runs in Terminal for each folder dropped on it, one after another in one window. Also runs by hand:
#   scripts/drop_build.sh "<game folder>" [iphone | ipad | both]
# The folder holds the game's NSPs (or a dump / a NUP), and may hold its mods folder (mods/, which the NSP script takes on its own) and prod.keys. The keys are the first of:
# <folder>/prod.keys, the folder above it, ~/.switch/prod.keys, or one other *.keys file in the folder. The device is the second argument, else DEVICE, else iphone.
# DRY_RUN=1 prints the command instead of running it (dm/tools/tests/test_drop_build.py).
set -u
repo=$(cd "$(dirname "$0")/.." && pwd)
dir=${1:-}; device=${2:-${DEVICE:-iphone}}
pause() { [ -n "${DRY_RUN:-}" ] || [ ! -t 0 ] || { echo; read -r -p "Press Return to close this window. " _; }; }
fail() { echo "[RED] $*" >&2; pause; exit 1; }
[ -n "$dir" ] || fail "usage: $0 <game folder> [iphone | ipad | both]"
dir=${dir%/}
if [ -f "$dir" ] && [[ $dir == *.[nN][uU][pP] ]]; then :   # a NUP container itself
else [ -d "$dir" ] || fail "not a folder: $dir (drop the folder that holds the game's NSPs)"; fi
case $device in iphone | ipad | both) ;; *) fail "the device is iphone, ipad or both: $device";; esac
keys=; others=
for k in "$dir/prod.keys" "$(dirname "$dir")/prod.keys" "$HOME/.switch/prod.keys"; do [ -f "$k" ] && { keys=$k; break; }; done
if [ -z "$keys" ]; then
    [ -d "$dir" ] && others=$(find "$dir" -maxdepth 1 -name '*.keys' ! -name 'title.keys' 2>/dev/null)
    [ "$(printf '%s\n' "$others" | grep -c .)" = 1 ] && keys=$others
fi
cmd=(python3 "$repo/scripts/build_ipa_from_nsp.py" "$dir" --device "$device")
# A dump folder (scripts/pack_dump.py is_dump: base/exefs/main.npdm, and a RomFS in base/ or updates/<version>/) or a NUP needs no keys
is_dump() { [ -f "$1/base/exefs/main.npdm" ] && { [ -d "$1/base/romfs" ] || ls -d "$1"/updates/*/romfs > /dev/null 2>&1; }; }
if [ -n "$keys" ]; then cmd+=(-k "$keys")
elif ! { [ -f "$dir" ] || is_dump "$dir" || ls "$dir" | grep -qiE '\.nup$'; }; then fail "no prod.keys: put it in $dir (or ~/.switch/prod.keys)"; fi
[ ! -d "$dir/mods" ] || echo "mods: $dir/mods (patches, replacement files and cheats are packed in)"
echo "device: $device"
if [ -n "${DRY_RUN:-}" ]; then printf '%q ' "${cmd[@]}"; echo; exit 0; fi
cd "$repo" || fail "cannot enter $repo"
printf '$ '; printf '%q ' "${cmd[@]}"; echo; echo
"${cmd[@]}"; rc=$?
echo
if [ "$rc" = 0 ]; then echo "Done. The IPA is in $dir (the last lines above name it)."
else echo "[RED] The build stopped (exit code $rc). Its lines above say why; the full logs are in the game's _build/logs folder."; fi
pause
exit "$rc"
