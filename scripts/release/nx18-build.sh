#!/bin/bash
# nx18-build.sh: builds one of your games with NX 18 (https://github.com/kencalx/NX18) into an iPhone or
# iPad IPA or a Mac app. Run nx18-setup.sh once first; it installs what this needs.
#
#   1. Copy this file somewhere outside the NX 18 folder (e.g. ~/nx18-build.sh) and edit SETTINGS below.
#   2. In Terminal:  bash ~/nx18-build.sh
#
# Options of the build script that are not settings here go after the script's name, e.g.
#   bash ~/nx18-build.sh --language ja
# A first build takes 30-60 minutes and needs free space of about twice the game's size plus 10 GB.
# Your keys stay on this Mac: this script never prints, copies, logs or sends them, and it has no telemetry.
# The only download is the launcher's key art (from titledb, or SteamGridDB when STEAMGRIDDB_KEY is set);
# EXTRA_ARGS=(--no-art-online) keeps the build offline.

# a mistake in the settings (a path with spaces but no quotes) stops here, naming its line
set -e; trap 'echo "nx18-build: a setting above has a mistake (the line number is in the message above): keep the quotes, e.g. GAME=\"/Users/me/My Games/Zelda\"" >&2' ERR

# ================================== SETTINGS: edit these ==================================
# Paths start with / (or ~/ for your home folder). Keep the quotes; spaces in folder names are fine
# (do not add backslashes). Each setting can also be given as the environment variable in its
# comment, which wins over the value written here, e.g.:
#   NX18_GAME="$HOME/Games/MarioWonder" NX18_TARGET=mac-app bash nx18-build.sh

# The NX 18 folder nx18-setup.sh made.                                          (env NX18_DIR)
CHECKOUT="$HOME/NX18"

# Your game, one of:                                                            (env NX18_GAME)
#   - a folder with the game's .nsp / .xci / .nsz / .xcz files (base game, plus its update and DLC)
#   - a folder with the game's files as a dump (base/, updates/<version>/, dlc/, or exefs/ and romfs/)
#   - a .nup or .nx file (Switch 2 games and others), or a folder that holds one
GAME="/Users/YOUR-NAME/Games/YOUR-GAME"

# Your prod.keys. Only .nsp / .xci / .nsz / .xcz games need it.                 (env NX18_KEYS)
KEYS="$HOME/keys/prod.keys"

# What to build: iphone, ipad or mac-app                                       (env NX18_TARGET)
#   iphone and ipad make the same IPA, made for the iPhone 18 Pro Max's chip (iOS / iPadOS 27.3 or later).
#   Its ready-made shader pipelines are for that iPhone; another device builds its own at first start,
#   and its log names its GPU, which EXTRA_ARGS=(--gpu <name>) adds to the next build.
TARGET="iphone"

# Optional: where the result goes; empty = in the game's folder.               (env NX18_OUTPUT)
#   iphone / ipad: a path ending in .ipa; mac-app: a path ending in .app
OUTPUT=""

# Optional: the build folder (extracted files, shader caches); empty = <title ID>_build in the
# game's folder. Put it on a drive with room (twice the game's size plus 10 GB). (env NX18_WORK_DIR)
WORK_DIR=""

# Common options: yes or no.
NO_MODS="no"          # yes = leave out the game's mods folder                  (env NX18_NO_MODS)
ROMFS_SEPARATE="no"   # iphone/ipad: yes = keep the game files out of the IPA, for a game too big to
                      #   install; copy them once with the command printed at the end (env NX18_ROMFS_SEPARATE)
SHADER_FILES="no"     # iphone/ipad: yes = the shader library as separate files, for AltServer, which
                      #   cannot install a file of 2 GiB or more (use with ROMFS_SEPARATE="yes") (env NX18_SHADER_FILES)

# Optional: the app's name on the home screen or in Finder; empty = the game's name. (env NX18_APP_NAME)
APP_NAME=""

# Optional: more options of scripts/build_ipa_from_nsp.py, one quoted word each
# (python3 scripts/build_ipa_from_nsp.py -h lists them), e.g.
#   EXTRA_ARGS=(--language ja --no-art-online --art "/Users/me/My Art/art.png")
# (env NX18_EXTRA_ARGS: one string, quoted as on a command line)
EXTRA_ARGS=()
# ================================ end of SETTINGS ==========================================

if [ -z "${BASH_VERSION:-}" ]; then
    echo "nx18-build.sh is a bash script: run it with  bash nx18-build.sh" >&2
    exit 2
fi
if shopt -oq posix; then set +o posix; fi   # sh nx18-build.sh runs bash in POSIX mode: leave it
trap - ERR
set -euo pipefail
set +x   # never trace: the command line names the keys file

NEED_XCODE="27.3"   # read again from the checkout's dm/gfx/tools/own_compilers.py

die()  { printf '\nnx18-build: %s\n' "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }
note() { printf 'nx18-build: %s\n' "$1"; }

# environment variables win over the values above
CHECKOUT="${NX18_DIR:-$CHECKOUT}"
GAME="${NX18_GAME:-$GAME}"
KEYS="${NX18_KEYS:-$KEYS}"
TARGET="${NX18_TARGET:-$TARGET}"
OUTPUT="${NX18_OUTPUT:-$OUTPUT}"
WORK_DIR="${NX18_WORK_DIR:-$WORK_DIR}"
NO_MODS="${NX18_NO_MODS:-$NO_MODS}"
ROMFS_SEPARATE="${NX18_ROMFS_SEPARATE:-$ROMFS_SEPARATE}"
SHADER_FILES="${NX18_SHADER_FILES:-$SHADER_FILES}"
APP_NAME="${NX18_APP_NAME:-$APP_NAME}"
case "${NX18_EXTRA_ARGS:-}" in *[![:space:]]*)
    # split like a command line (quotes allowed) without running it: xargs does the quoting, printf the output
    printf '%s' "$NX18_EXTRA_ARGS" | xargs printf '%s' >/dev/null 2>&1 || die "NX18_EXTRA_ARGS: an unmatched quote in: $NX18_EXTRA_ARGS"
    words="$(printf '%s' "$NX18_EXTRA_ARGS" | xargs printf '%s\n')"   # one word per line
    while IFS= read -r w; do EXTRA_ARGS+=("$w"); done <<WORDS
$words
WORDS
    ;;
esac
EXTRA_ARGS+=("$@")   # options after the script's name

# ---- checking the settings -------------------------------------------------------------------
# path_setting NAME VALUE: prints the cleaned path; stops on a placeholder, a relative path or backslashes
path_setting() {
    local name="$1" p="$2" env="NX18_$1"
    [ "$name" = CHECKOUT ] && env=NX18_DIR
    while [ "${p% }" != "$p" ]; do p="${p% }"; done          # a trailing space from drag and drop
    case "$p" in *YOUR-NAME*|*YOUR-GAME*) die "$name is still the example value ($p): edit $name in the SETTINGS at the top of $0 (or set $env)." ;; esac
    case "$p" in *'\ '*) die "$name has backslashes before spaces ($p): inside the quotes, write the spaces without backslashes." ;; esac
    case "$p" in "~") p="$HOME" ;; "~/"*) p="$HOME/${p#\~/}" ;; esac
    case "$p" in
        /*) ;;
        "") die "$name is empty: set it in the SETTINGS at the top of $0." ;;
        *) die "$name must be a full path starting with / (or ~/), not '$p'." "Tip: drag the file or folder from Finder into Terminal to see its full path." ;;
    esac
    [ "$p" = / ] || p="${p%/}"
    printf '%s\n' "$p"
}
# on_mounted_drive NAME PATH: a path under /Volumes/<drive> needs that drive connected; an unmounted drive
# leaves an empty /Volumes/<drive> folder on the startup disk, and writing there fills the startup disk
on_mounted_drive() {
    local v
    case "$2" in /Volumes/?*) ;; *) return 0 ;; esac
    v="${2#/Volumes/}"; v="/Volumes/${v%%/*}"
    [ -L "$v" ] && return 0   # /Volumes/Macintosh HD: a link to the startup disk
    if [ ! -d "$v" ] || [ "$(stat -f %d "$v")" = "$(stat -f %d /Volumes)" ]; then
        die "$1 is on the drive $v, which is not connected (or not mounted): $2" "Connect the drive (check Finder's sidebar), then run this again."
    fi
}
yes_no() {   # yes_no NAME VALUE: prints yes or no
    case "$2" in
        [yY]|[yY][eE][sS]|[tT][rR][uU][eE]|1|[oO][nN]) echo yes ;;
        [nN]|[nN][oO]|[fF][aA][lL][sS][eE]|0|[oO][fF][fF]|"") echo no ;;
        *) die "$1 must be yes or no, not '$2'." ;;
    esac
}

CHECKOUT="$(path_setting CHECKOUT "$CHECKOUT")"
on_mounted_drive CHECKOUT "$CHECKOUT"
BUILD_PY="$CHECKOUT/scripts/build_ipa_from_nsp.py"
[ -f "$BUILD_PY" ] || die "CHECKOUT is not an NX 18 folder (no scripts/build_ipa_from_nsp.py): $CHECKOUT" \
    "Run nx18-setup.sh first, or set CHECKOUT (NX18_DIR) to the folder it made."

GAME="$(path_setting GAME "$GAME")"
on_mounted_drive GAME "$GAME"
[ -e "$GAME" ] || die "GAME does not exist: $GAME" "Check the spelling (names are case sensitive on some drives), or drag the folder into Terminal to see its path."

NO_MODS="$(yes_no NO_MODS "$NO_MODS")"
ROMFS_SEPARATE="$(yes_no ROMFS_SEPARATE "$ROMFS_SEPARATE")"
SHADER_FILES="$(yes_no SHADER_FILES "$SHADER_FILES")"

case "$TARGET" in
    iphone|iPhone|IPHONE) TARGET=iphone; PLATFORM=ios ;;
    ipad|iPad|IPAD)       TARGET=ipad;   PLATFORM=ios ;;
    mac-app|mac|Mac|macapp|mac_app) TARGET=mac-app; PLATFORM=mac-app ;;
    *) die "TARGET must be iphone, ipad or mac-app, not '$TARGET'." ;;
esac
if [ "$PLATFORM" = mac-app ]; then
    [ "$ROMFS_SEPARATE" = no ] || die "ROMFS_SEPARATE=\"yes\" is for iphone and ipad: a Mac app runs from its own files. Set it to \"no\"."
    [ "$SHADER_FILES" = no ] || die "SHADER_FILES=\"yes\" is for iphone and ipad installs. Set it to \"no\"."
fi

# what the game is, and whether it needs prod.keys
shopt -s nullglob nocaseglob
GAME_DIR="$GAME"
NEEDS_KEYS=no
if [ -f "$GAME" ]; then
    case "$GAME" in
        *.[nN][uU][pP]|*.[nN][xX]) GAME_DIR="$(dirname "$GAME")" ;;
        *.[nN][sS][pP]|*.[xX][cC][iI]|*.[nN][sS][zZ]|*.[xX][cC][zZ])
            die "GAME is one file ($GAME): give the folder that holds it, with the game's update and DLC beside it." "GAME=\"$(dirname "$GAME")\"" ;;
        *) die "GAME is a file that is not a .nup or .nx: $GAME" ;;
    esac
elif [ -d "$GAME" ]; then
    nsps=("$GAME"/*.nsp "$GAME"/*.xci "$GAME"/*.nsz "$GAME"/*.xcz)
    packs=("$GAME"/*.nup "$GAME"/*.nx)
    if [ "${#nsps[@]}" -gt 0 ]; then
        NEEDS_KEYS=yes
    elif [ "${#packs[@]}" -gt 1 ]; then
        die "GAME holds ${#packs[@]} .nup / .nx files: keep one per folder, or set GAME to the file itself."
    elif [ "${#packs[@]}" -eq 1 ]; then
        :
    elif [ -d "$GAME/base" ] || [ -d "$GAME/updates" ] || [ -d "$GAME/exefs" ] || [ -d "$GAME/romfs" ]; then
        :
    else
        die "GAME holds no game files: $GAME" \
            "Expected .nsp / .xci / .nsz / .xcz files, one .nup or .nx file, or a dump (base/, updates/<version>/, dlc/, or exefs/ and romfs/)."
    fi
else
    die "GAME is neither a folder nor a file: $GAME"
fi
shopt -u nullglob nocaseglob

if [ "$NEEDS_KEYS" = yes ]; then
    KEYS="$(path_setting KEYS "$KEYS")"
    on_mounted_drive KEYS "$KEYS"
    [ -e "$KEYS" ] || die "KEYS: no prod.keys at $KEYS" "This game's .nsp / .xci files need your console's prod.keys: set KEYS to where it is."
    [ -f "$KEYS" ] || die "KEYS is not a file: $KEYS"
    [ -r "$KEYS" ] || die "KEYS cannot be read (permissions): $KEYS"
    [ -s "$KEYS" ] || die "KEYS is empty: $KEYS"
    # a quiet look for the key every prod.keys has; nothing of the file is printed
    grep -qiE '^[[:space:]]*header_key[[:space:]]*=' "$KEYS" 2>/dev/null \
        || die "KEYS does not look like a prod.keys file (it has no header_key line): $KEYS" "Its contents are not shown. Point KEYS at your prod.keys (not title.keys)."
    case "$KEYS/" in "$CHECKOUT"/*) note "warning: KEYS is inside the NX 18 folder; never commit or share that folder with it in." ;; esac
else
    KEYS=""   # a dump, .nup or .nx needs none: the keys are not passed
fi

if [ -n "$OUTPUT" ]; then
    OUTPUT="$(path_setting OUTPUT "$OUTPUT")"
    on_mounted_drive OUTPUT "$OUTPUT"
    case "$PLATFORM:$OUTPUT" in
        ios:*.ipa|mac-app:*.app) ;;
        ios:*) die "OUTPUT must end in .ipa for $TARGET: $OUTPUT" ;;
        *) die "OUTPUT must end in .app for mac-app: $OUTPUT" ;;
    esac
    [ -d "$(dirname "$OUTPUT")" ] || die "OUTPUT's folder does not exist: $(dirname "$OUTPUT")"
    [ -w "$(dirname "$OUTPUT")" ] || die "OUTPUT's folder cannot be written to: $(dirname "$OUTPUT")"
fi
if [ -n "$WORK_DIR" ]; then
    WORK_DIR="$(path_setting WORK_DIR "$WORK_DIR")"
    on_mounted_drive WORK_DIR "$WORK_DIR"
    [ -d "$(dirname "$WORK_DIR")" ] || die "WORK_DIR's parent folder does not exist: $(dirname "$WORK_DIR")"
    if [ -e "$WORK_DIR" ] && [ ! -d "$WORK_DIR" ]; then die "WORK_DIR is a file, not a folder: $WORK_DIR"; fi
    if [ ! -e "$WORK_DIR" ] || [ -z "$OUTPUT" ]; then   # the build makes WORK_DIR there, and without OUTPUT the result goes there
        [ -w "$(dirname "$WORK_DIR")" ] || die "WORK_DIR's parent folder cannot be written to: $(dirname "$WORK_DIR")"
    fi
else
    [ -w "$GAME_DIR" ] || die "the game's folder cannot be written to, and the build folder goes there: $GAME_DIR" "Set WORK_DIR and OUTPUT to a folder you can write to."
fi

# ---- the Mac, Xcode and Python ---------------------------------------------------------------
[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] || die "NX 18 builds need an Apple silicon Mac."
if [ -x /opt/homebrew/bin/brew ]; then
    case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *) export PATH="/opt/homebrew/bin:$PATH" ;; esac   # xcodegen, zstd
fi

v="$(sed -n "s/^XCODE_VERSION = '\([0-9.]*\)'.*/\1/p" "$CHECKOUT/dm/gfx/tools/own_compilers.py" 2>/dev/null | head -n 1 || true)"
[ -n "$v" ] && NEED_XCODE="$v"
LOCK_METAL="$(awk -F'\t' '$1=="metal_macosx"{print $2}' "$CHECKOUT/dm/gfx/tools/dmsh_chain.lock" 2>/dev/null || true)"
xcode_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true; }
is_need_xcode() { case "$(xcode_version "$1")" in "$NEED_XCODE"|"$NEED_XCODE".*) return 0 ;; *) return 1 ;; esac; }
app_of_devdir() { case "$1" in *.app/Contents/Developer|*.app/Contents/Developer/) local d="${1%/}"; printf '%s\n' "${d%/Contents/Developer}" ;; *) printf '\n' ;; esac; }

if [ -n "${DEVELOPER_DIR:-}" ]; then
    app="$(app_of_devdir "$DEVELOPER_DIR")"
    if [ -z "$app" ]; then
        # the Command Line Tools (or another folder that is no Xcode): no iOS SDK and no Metal toolchain, so pick Xcode below
        note "DEVELOPER_DIR=$DEVELOPER_DIR is not an Xcode; looking for Xcode $NEED_XCODE instead"
        unset DEVELOPER_DIR
    else
        [ -d "$DEVELOPER_DIR" ] || die "DEVELOPER_DIR does not exist: $DEVELOPER_DIR"
        is_need_xcode "$app" || note "warning: DEVELOPER_DIR=$DEVELOPER_DIR is not Xcode $NEED_XCODE; the build checks its Metal compiler"
    fi
fi
if [ -z "${DEVELOPER_DIR:-}" ]; then
    sel="$(xcode-select -p 2>/dev/null || true)"
    app="$(app_of_devdir "$sel")"
    if [ -n "$app" ] && is_need_xcode "$app"; then
        :   # the selected Xcode is the one
    else
        pick=""; first=""
        for a in "/Applications/Xcode-$NEED_XCODE.app" /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
            [ -d "$a/Contents/Developer" ] && is_need_xcode "$a" || continue
            [ -n "$first" ] || first="$a"
            if [ -n "$LOCK_METAL" ] && [ "$(DEVELOPER_DIR="$a/Contents/Developer" xcrun -sdk macosx metal --version 2>/dev/null | head -n 1 || true)" = "$LOCK_METAL" ]; then pick="$a"; break; fi
        done
        [ -n "$pick" ] || pick="$first"
        if [ -n "$pick" ]; then
            export DEVELOPER_DIR="$pick/Contents/Developer"
            note "using $(basename "$pick") (Xcode $(xcode_version "$pick")) for this build: DEVELOPER_DIR=$DEVELOPER_DIR"
        elif [ -z "$app" ]; then
            die "Xcode $NEED_XCODE was not found, and xcode-select points at ${sel:-nothing} (not an Xcode)." \
                "Install Xcode $NEED_XCODE in /Applications (bash nx18-setup.sh --check says how), or set DEVELOPER_DIR to its Contents/Developer folder."
        else
            note "warning: Xcode $NEED_XCODE was not found; building with $(basename "$app") ($(xcode_version "$app")), whose Metal compiler the build checks"
        fi
    fi
fi
if [ "$PLATFORM" = ios ] && ! xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
    die "the selected Xcode has no iOS platform, which $TARGET builds need." \
        "Install it in Xcode > Settings > Components, or run: xcodebuild -downloadPlatform iOS (or bash nx18-setup.sh)."
fi

VENV="$CHECKOUT/.venv"
if [ -n "${NX18_PYTHON:-}" ]; then
    PY="$NX18_PYTHON"   # advanced: a Python of your own that has the modules
elif [ -x "$VENV/bin/python" ]; then
    export VIRTUAL_ENV="$VENV"
    export PATH="$VENV/bin:$PATH"
    unset PYTHONHOME
    PY="$VENV/bin/python"
else
    die "no Python virtualenv in $VENV." "Run nx18-setup.sh first: it makes it and installs the modules the build needs."
fi
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)' >/dev/null 2>&1 \
    || die "$PY does not run, or is older than Python 3.12." "Run nx18-setup.sh again: it makes the virtualenv again when its Python was updated."
# the modules the build imports (nx18-setup.sh checks the same list): missing ones would stop it only after the extraction
MODCHECK='
import importlib.util as u
def has(m):
    try: return u.find_spec(m) is not None
    except Exception: return False
bad = [m for m in ("lz4.block", "capstone", "fontTools", "zbic", "nsz") if not has(m)]
if not (has("compression.zstd") or has("backports.zstd")): bad.append("backports.zstd")
print(" ".join(bad))
'
bad="$("$PY" -c "$MODCHECK" 2>/dev/null || echo '?')"
[ -z "$bad" ] || die "Python modules the build needs are missing in $PY: $bad" \
    "Run nx18-setup.sh again (bash nx18-setup.sh): it installs them into the virtualenv."

# ---- the build -------------------------------------------------------------------------------
ARGS=("$BUILD_PY" "$GAME" --platform "$PLATFORM")
[ -n "$KEYS" ] && ARGS+=(-k "$KEYS")
[ -n "$OUTPUT" ] && ARGS+=(-o "$OUTPUT")
[ -n "$WORK_DIR" ] && ARGS+=(--work-dir "$WORK_DIR")
[ "$NO_MODS" = yes ] && ARGS+=(--no-mods)
[ "$ROMFS_SEPARATE" = yes ] && ARGS+=(--romfs separate)
[ "$SHADER_FILES" = yes ] && ARGS+=(--shader-files)
[ -n "$APP_NAME" ] && ARGS+=(--app-name "$APP_NAME")
if [ "${#EXTRA_ARGS[@]}" -gt 0 ]; then
    for a in "${EXTRA_ARGS[@]}"; do if [ -n "$a" ]; then ARGS+=("$a"); fi; done   # EXTRA_ARGS="" leaves an empty word
fi

note "building $TARGET from $GAME"
printf '  $ %q' "$PY"; printf ' %q' "${ARGS[@]}"; printf '\n\n'   # paths only; the keys file is named, never read here

MARK="$(mktemp -t nx18-build)"
trap 'rm -f "$MARK"' EXIT
START=$(date +%s)
set +e
caffeinate -i "$PY" "${ARGS[@]}"   # caffeinate: the Mac does not sleep during a long build
rc=$?
set -e
MINS=$(( ($(date +%s) - START + 59) / 60 ))

if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 130 ]; then die "the build was interrupted after $MINS min; running this again goes on from what is done."; fi
    die "the build stopped after $MINS min (exit status $rc): the reason is in the lines above." \
        "Each step's full output is in the build folder's logs/ (<title ID>_build/logs in the game's folder, or WORK_DIR/logs)." \
        "Missing tools or modules: bash nx18-setup.sh --check"
fi

# where the result is
if [ -n "$OUTPUT" ]; then
    RESULT="$OUTPUT"
else
    if [ -n "$WORK_DIR" ]; then look="$(dirname "$WORK_DIR")"; else look="$GAME_DIR"; fi
    if [ "$PLATFORM" = mac-app ]; then pat='*.app'; else pat='*.ipa'; fi
    RESULT="$(find "$look" -maxdepth 1 -name "$pat" -newer "$MARK" 2>/dev/null | head -n 1 || true)"
fi
printf '\n'
if [ -n "$RESULT" ] && [ -e "$RESULT" ]; then
    note "done in $MINS min: $RESULT"
    if [ "$PLATFORM" = mac-app ]; then
        echo "  Open it from Finder, or:  open \"$RESULT\""
    else
        echo "  Install it on your $([ "$TARGET" = ipad ] && echo iPad || echo iPhone) with AltStore, Sideloadly or LiveContainer;"
        echo "  turn on Increased Memory Limit if your tool offers it."
        [ "$ROMFS_SEPARATE" = yes ] && echo "  ROMFS_SEPARATE: copy the game files to the device once with the push_romfs.sh command printed above."
    fi
    echo "  Show it in Finder:  open -R \"$RESULT\""
else
    note "done in $MINS min. The result is in ${look:-the folder named above}; the build's last lines above name it."
fi
