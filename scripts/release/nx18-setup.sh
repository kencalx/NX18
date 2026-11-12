#!/bin/bash
# nx18-setup.sh: gets a Mac ready to build games with NX 18 (https://github.com/kencalx/NX18) from
# your legally owned and acquired game files.
#
# It checks the Mac, Xcode 27.3 and its Metal toolchain, installs the Homebrew tools and the Python
# modules the build needs (in a virtualenv inside the checkout), and clones or updates NX 18.
# It asks before every install or download; nothing is sent anywhere except the git, Homebrew, pip
# and Apple downloads you approve. It never uses sudo and never changes a folder that holds your own
# work. Running it again only does what is still missing.
#
#   bash nx18-setup.sh             set up (asks before each install or download)
#   bash nx18-setup.sh --check     only report what is missing; installs and downloads nothing
#   bash nx18-setup.sh --yes       answer yes to every question
#   bash nx18-setup.sh --dir ~/Code/NX18 --ref <tag>
#
# Then edit nx18-build.sh (the release's other script) and run it: bash nx18-build.sh

if [ -z "${BASH_VERSION:-}" ]; then
    echo "nx18-setup.sh is a bash script: run it with  bash nx18-setup.sh" >&2
    exit 2
fi
if shopt -oq posix; then set +o posix; fi   # sh nx18-setup.sh runs bash in POSIX mode: leave it
set -euo pipefail

REPO_URL="https://github.com/kencalx/NX18.git"
REPO_SLUG="kencalx/nx18"            # lower case, for comparing remote URLs
DEFAULT_REF="main"
NEED_MACOS="27.3"
NEED_XCODE="27.3"                   # read again from the checkout's dm/gfx/tools/own_compilers.py when there is one
# The Metal compiler the shaders were tested with, as dm/gfx/tools/dmsh_chain.lock records it (read from the checkout when there is one).
FALLBACK_METAL="Apple metal version 32023.925 (metalfe-32023.925.6)"
PY_MODULES_PIP=(lz4 "capstone>=5,<6" fonttools nsz zbic 'backports.zstd; python_version < "3.14"')   # shown in single quotes: no single quote inside
BREW_TOOLS="xcodegen zstd"

usage() {
    cat <<EOF
Usage: bash nx18-setup.sh [options]

Gets this Mac ready to build games with NX 18 from your legally owned and acquired game files:
checks macOS, Xcode $NEED_XCODE and its Metal toolchain, installs xcodegen and zstd with Homebrew,
makes a Python virtualenv with the modules the build needs, and clones or updates $REPO_URL.

Options:
  --check        report what is missing; install, download and change nothing
  -y, --yes      do not ask: answer yes to every install and download
  --dir DIR      the NX 18 folder (default: \$NX18_DIR, else ~/NX18)
  --ref REF      the branch or tag to check out (default: \$NX18_REF, else $DEFAULT_REF),
                 e.g. a release tag
  -h, --help     show this help

Environment: NX18_DIR and NX18_REF as the options above.
Exit status: 0 when everything is ready, 1 when something is missing or the script stopped, 2 for
a wrong option.
EOF
}

CHECK=0
YES=0
DIR="${NX18_DIR:-$HOME/NX18}"
REF="${NX18_REF:-$DEFAULT_REF}"
while [ $# -gt 0 ]; do
    case "$1" in
        --check) CHECK=1 ;;
        -y|--yes) YES=1 ;;
        --dir) [ $# -ge 2 ] || { echo "--dir needs a folder" >&2; exit 2; }; DIR="$2"; shift ;;
        --dir=*) DIR="${1#--dir=}" ;;
        --ref|--tag|--branch) [ $# -ge 2 ] || { echo "$1 needs a branch or tag name" >&2; exit 2; }; REF="$2"; shift ;;
        --ref=*|--tag=*|--branch=*) REF="${1#*=}" ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $1 (bash nx18-setup.sh --help lists the options)" >&2; exit 2 ;;
    esac
    shift
done

[ -n "$DIR" ] || { echo "--dir: the folder is empty" >&2; exit 2; }
case "$DIR" in "~") DIR="$HOME" ;; "~/"*) DIR="$HOME/${DIR#\~/}" ;; esac
case "$DIR" in /*) ;; *) DIR="$PWD/$DIR" ;; esac
while [ "${DIR%/}" != "$DIR" ]; do DIR="${DIR%/}"; done
[ -n "$DIR" ] || { echo "--dir: not / itself: give the folder for NX 18, e.g. ~/NX18" >&2; exit 2; }
case "$REF" in ""|-*|*" "*|*..*) echo "--ref: not a branch or tag name: '$REF'" >&2; exit 2 ;; esac

# ---- output ----------------------------------------------------------------------------------
if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=; G=; Y=; R=; N=; fi
SUMMARY=""                           # one line per item: "ok|missing|warn<TAB>text"
MISSING=0
section() { printf '\n%s== %s ==%s\n' "$B" "$1" "$N"; }
ok()      { printf '  %sok%s       %s\n' "$G" "$N" "$1"; SUMMARY="${SUMMARY}ok	$1
"; }
warn()    { printf '  %swarning%s  %s\n' "$Y" "$N" "$1"; SUMMARY="${SUMMARY}warn	$1
"; }
missing() { printf '  %smissing%s  %s\n' "$R" "$N" "$1"; SUMMARY="${SUMMARY}missing	$1
"; MISSING=$((MISSING + 1)); }
info()    { printf '           %s\n' "$1"; }
stop()    { printf '\n%sstopped:%s %s\n' "$R" "$N" "$1" >&2; shift; for l in "$@"; do printf '  %s\n' "$l" >&2; done; exit 1; }

# ask "question": 0 = yes. --yes answers yes, --check answers no without asking. The answer is read from
# the terminal (also when the script itself arrives on stdin), else from stdin; no answer means no.
ask() {
    local answer=""
    if [ "$CHECK" = 1 ]; then return 1; fi
    if [ "$YES" = 1 ]; then printf '  %s yes (--yes)\n' "$1"; return 0; fi
    printf '  %s [y/N] ' "$1"
    if [ -t 0 ]; then
        IFS= read -r answer || answer=""
    elif (exec 3</dev/tty) 2>/dev/null; then
        IFS= read -r answer </dev/tty || answer=""
    else
        IFS= read -r answer || answer=""
        printf '%s\n' "$answer"
    fi
    case "$answer" in [yY]|[yY][eE][sS]) return 0 ;; *) return 1 ;; esac
}

# run a command the user approved, showing it first
run() { printf '  $'; printf ' %q' "$@"; printf '\n'; "$@"; }

ver_ge() {   # ver_ge 27.3.1 27.3: numeric, dot by dot
    local a="$1" b="$2" x y
    while [ -n "$a" ] || [ -n "$b" ]; do
        x="${a%%.*}"; y="${b%%.*}"
        case "$a" in *.*) a="${a#*.}" ;; *) a="" ;; esac
        case "$b" in *.*) b="${b#*.}" ;; *) b="" ;; esac
        x="${x//[!0-9]/}"; y="${y//[!0-9]/}"
        x=$((10#${x:-0})); y=$((10#${y:-0}))
        [ "$x" -gt "$y" ] && return 0
        [ "$x" -lt "$y" ] && return 1
    done
    return 0
}
same_series() { case "$1" in "$2"|"$2".*) return 0 ;; *) return 1 ;; esac; }   # 27.3.1 is a 27.3

export HOMEBREW_NO_ANALYTICS=1 HOMEBREW_NO_ENV_HINTS=1 PIP_DISABLE_PIP_VERSION_CHECK=1
git_ro() { git -C "$DIR" --no-optional-locks "$@"; }    # read-only git: does not even refresh the index

printf '%sNX 18 setup%s%s\n' "$B" "$N" "$([ "$CHECK" = 1 ] && echo ' (--check: nothing is installed, downloaded or changed)')"
printf 'folder: %s   ref: %s\n' "$DIR" "$REF"

# ---- 1. the Mac --------------------------------------------------------------------------------
section "Mac"
if [ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
    ok "Apple silicon"
    if [ "$(uname -m)" != arm64 ]; then
        warn "this shell runs under Rosetta (x86_64): open Terminal without \"Open using Rosetta\" so the tools are the arm64 ones"
    fi
else
    stop "this Mac has an Intel processor: NX 18 needs an Apple silicon Mac (README.md, Requirements)."
fi
MACOS="$(sw_vers -productVersion 2>/dev/null || echo 0)"
if ver_ge "$MACOS" "$NEED_MACOS"; then ok "macOS $MACOS"; else missing "macOS $NEED_MACOS or later (this Mac has $MACOS): update in System Settings > General > Software Update"; fi
if [ "$(/usr/sbin/sysctl -n kern.hv_vmm_present 2>/dev/null || echo 0)" = 1 ]; then
    warn "this is a virtual Mac: its GPU has no Metal 4, which NX 18 needs to play games (building may still work)"
fi

# ---- the checkout's requirements, when it is there (read only) ---------------------------------
LOCK_METAL_MAC="$FALLBACK_METAL"; LOCK_METAL_IOS="$FALLBACK_METAL"; LOCK_FROM="this script's copy of the lock"
read_requirements() {
    local f="$DIR/dm/gfx/tools/dmsh_chain.lock" g="$DIR/dm/gfx/tools/own_compilers.py" v
    if [ -f "$f" ]; then
        v="$(awk -F'\t' '$1=="metal_macosx"{print $2}' "$f")"; [ -n "$v" ] && LOCK_METAL_MAC="$v"
        v="$(awk -F'\t' '$1=="metal_iphoneos"{print $2}' "$f")"; [ -n "$v" ] && LOCK_METAL_IOS="$v"
        LOCK_FROM="dm/gfx/tools/dmsh_chain.lock"
    fi
    if [ -f "$g" ]; then
        v="$(sed -n "s/^XCODE_VERSION = '\([0-9.]*\)'.*/\1/p" "$g" | head -n 1)"; [ -n "$v" ] && NEED_XCODE="$v"
    fi
    return 0
}
read_requirements

# ---- 2. Xcode ----------------------------------------------------------------------------------
section "Xcode $NEED_XCODE"
app_of_devdir() { case "$1" in *.app/Contents/Developer) printf '%s\n' "${1%/Contents/Developer}" ;; *) printf '\n' ;; esac; }
xcode_version() { /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true; }
xcode_build()   { /usr/libexec/PlistBuddy -c 'Print :ProductBuildVersion' "$1/Contents/version.plist" 2>/dev/null || true; }
metal_of()      { DEVELOPER_DIR="$1" xcrun -sdk "$2" metal --version 2>/dev/null | head -n 1 || true; }   # empty: no Metal toolchain

SELECTED_DEV="$(xcode-select -p 2>/dev/null || true)"
SELECTED_APP="$(app_of_devdir "$SELECTED_DEV")"
CANDIDATES=""
add_candidate() { [ -d "$1/Contents/Developer" ] || return 0; case "
$CANDIDATES" in *"
$1
"*) return 0 ;; esac; CANDIDATES="$CANDIDATES$1
"; }
if [ -n "${DEVELOPER_DIR:-}" ]; then add_candidate "$(app_of_devdir "$DEVELOPER_DIR")"; fi
if [ -n "$SELECTED_APP" ]; then add_candidate "$SELECTED_APP"; fi
for a in "/Applications/Xcode-$NEED_XCODE.app" /Applications/Xcode.app /Applications/Xcode-beta.app /Applications/Xcode*.app "$HOME"/Applications/Xcode*.app; do
    add_candidate "$a"
done

XCODE_APP=""     # the Xcode NEED_XCODE to build with: the one whose Metal compiler matches the lock first
XCODE_ANY=""
while IFS= read -r a; do
    [ -n "$a" ] || continue
    v="$(xcode_version "$a")"
    same_series "$v" "$NEED_XCODE" || continue
    [ -n "$XCODE_ANY" ] || XCODE_ANY="$a"
    if [ "$(metal_of "$a/Contents/Developer" macosx)" = "$LOCK_METAL_MAC" ]; then XCODE_APP="$a"; break; fi
done <<EOF
$CANDIDATES
EOF
[ -n "$XCODE_APP" ] || XCODE_APP="$XCODE_ANY"

OTHER_XCODES=""
while IFS= read -r a; do
    if [ -n "$a" ] && [ "$a" != "$XCODE_APP" ]; then OTHER_XCODES="$OTHER_XCODES $(basename "$a") ($(xcode_version "$a"))"; fi
done <<EOF
$CANDIDATES
EOF

DEV=""
NEED_DEVELOPER_DIR=0
if [ -z "$XCODE_APP" ]; then
    missing "Xcode $NEED_XCODE${OTHER_XCODES:+ (found:$OTHER_XCODES)}"
    info "Download Xcode $NEED_XCODE from https://developer.apple.com/download/all/?q=Xcode%20$NEED_XCODE (free Apple account),"
    info "unpack it and move it to /Applications. Beside another Xcode, rename it Xcode-$NEED_XCODE.app."
    info "Open it once to finish installing. A script cannot download Xcode for you."
else
    DEV="$XCODE_APP/Contents/Developer"
    ok "$(basename "$XCODE_APP") is Xcode $(xcode_version "$XCODE_APP") ($(xcode_build "$XCODE_APP"))"
    if [ -n "${DEVELOPER_DIR:-}" ] && [ "${DEVELOPER_DIR%/}" = "$DEV" ]; then
        ok "selected for this shell (DEVELOPER_DIR)"
    elif [ "$SELECTED_APP" = "$XCODE_APP" ] && [ -z "${DEVELOPER_DIR:-}" ]; then
        ok "selected (xcode-select -p: $SELECTED_DEV)"
    else
        NEED_DEVELOPER_DIR=1
        warn "not the selected Xcode (xcode-select -p: ${SELECTED_DEV:-none}${DEVELOPER_DIR:+, DEVELOPER_DIR=$DEVELOPER_DIR})"
        info "nx18-build.sh picks it by itself. To use it everywhere, run yourself (it asks for your password):"
        info "  sudo xcode-select -s \"$XCODE_APP\""
        info "or for one shell:  export DEVELOPER_DIR=\"$DEV\""
    fi
    if ! DEVELOPER_DIR="$DEV" xcodebuild -license check >/dev/null 2>&1; then
        missing "Xcode's license is not accepted: open $(basename "$XCODE_APP") once, or run yourself: sudo xcodebuild -license accept"
    fi
    if ! DEVELOPER_DIR="$DEV" xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
        missing "Xcode's first-launch setup has not run: open $(basename "$XCODE_APP") once (or run yourself: sudo xcodebuild -runFirstLaunch)"
    fi
fi

# ---- 3. Homebrew, git, xcodegen, zstd ---------------------------------------------------------
section "Homebrew tools"
BREW=""
if [ -x /opt/homebrew/bin/brew ]; then
    BREW=/opt/homebrew/bin/brew
    case ":$PATH:" in *:/opt/homebrew/bin:*) ;; *)
        export PATH="/opt/homebrew/bin:$PATH"
        warn "Homebrew is not on this shell's PATH; add it yourself to ~/.zprofile:  eval \"\$(/opt/homebrew/bin/brew shellenv)\""
        ;;
    esac
    ok "Homebrew ($BREW)"
else
    if [ -x /usr/local/bin/brew ]; then
        missing "an Apple silicon Homebrew in /opt/homebrew (only an Intel one in /usr/local was found)"
    else
        missing "Homebrew"
    fi
    info "Install it yourself from https://brew.sh (its installer asks for your password; this script never runs sudo),"
    info "then run this script again."
fi
WANT=""
for t in $BREW_TOOLS; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t ($(command -v "$t"))"; else WANT="$WANT $t"; fi
done
WANT="${WANT# }"
if [ -n "$WANT" ]; then
    if [ -n "$BREW" ] && ask "Install $WANT with Homebrew?"; then
        # shellcheck disable=SC2086 # the tool names are words
        run "$BREW" install $WANT || warn "brew install $WANT failed"
    fi
    for t in $WANT; do
        if command -v "$t" >/dev/null 2>&1; then ok "$t ($(command -v "$t"))"; else missing "$t: brew install $t"; fi
    done
fi
if git --version >/dev/null 2>&1; then ok "git ($(git --version | sed 's/git version //'))"; else missing "git: it comes with Xcode, or brew install git"; fi

# ---- 4. the NX 18 checkout ---------------------------------------------------------------------
section "NX 18 checkout"
REPO_STATE=""    # absent | empty | ours | dirty | other
is_our_remote() {
    local u
    u="$(git_ro remote get-url origin 2>/dev/null | tr '[:upper:]' '[:lower:]')"
    u="${u%/}"; u="${u%.git}"
    case "$u" in
        "https://github.com/$REPO_SLUG"|"http://github.com/$REPO_SLUG"|"git@github.com:$REPO_SLUG"|"ssh://git@github.com/$REPO_SLUG"|"git://github.com/$REPO_SLUG") return 0 ;;
    esac
    return 1
}
DIRTY_LIST=""
repo_state() {
    if [ ! -e "$DIR" ]; then REPO_STATE=absent; return; fi
    if [ ! -d "$DIR" ]; then REPO_STATE=other; return; fi
    if [ -z "$(ls -A "$DIR" 2>/dev/null)" ]; then REPO_STATE=empty; return; fi
    local top
    top="$(git_ro rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -z "$top" ] || [ "$(cd "$top" && pwd -P)" != "$(cd "$DIR" && pwd -P)" ] || ! is_our_remote; then REPO_STATE=other; return; fi
    local gd; gd="$(git_ro rev-parse --absolute-git-dir 2>/dev/null || true)"
    local op
    for op in MERGE_HEAD rebase-merge rebase-apply CHERRY_PICK_HEAD REVERT_HEAD BISECT_LOG; do
        if [ -n "$gd" ] && [ -e "$gd/$op" ]; then DIRTY_LIST="a git operation is in progress ($op)"; REPO_STATE=dirty; return; fi
    done
    # the virtualenv this script makes is not local work, even in a tree whose .gitignore predates it
    DIRTY_LIST="$(git_ro status --porcelain --untracked-files=normal -- . ':(exclude).venv' 2>/dev/null | head -n 12)"
    if [ -n "$DIRTY_LIST" ]; then REPO_STATE=dirty; else REPO_STATE=ours; fi
}
describe_head() {
    local b; b="$(git_ro symbolic-ref -q --short HEAD 2>/dev/null || true)"
    printf '%s at %s' "${b:-detached HEAD}" "$(git_ro log -1 --format='%h %cs' 2>/dev/null || echo '?')"
}
NOT_OURS_HINT="Choose another folder with --dir <folder> (or NX18_DIR), or sort out that folder yourself and run this again."
stop_not_ours() {
    stop "$DIR is not a clean clone of $REPO_URL, so this script leaves it exactly as it is." "$@" "$NOT_OURS_HINT"
}

# A folder on an external drive (/Volumes/<name>/...): the drive must be mounted, or git would write to a bare
# /Volumes/<name> folder on the startup disk.
case "$DIR" in /Volumes/?*)
    v="${DIR#/Volumes/}"; v="/Volumes/${v%%/*}"
    if [ -L "$v" ]; then :   # /Volumes/Macintosh HD: a link to the startup disk
    elif [ ! -d "$v" ] || [ "$(stat -f %d "$v")" = "$(stat -f %d /Volumes)" ]; then
        stop "$DIR is on the drive $v, which is not connected (or not mounted): connect it, or choose another folder with --dir."
    fi ;;
esac
repo_state
case "$REPO_STATE" in
    other|dirty)
        if [ "$REPO_STATE" = other ]; then why="It is not a git clone whose origin is $REPO_URL (or it is a file)."
        else
            printf '%s\n' "$DIRTY_LIST" | sed 's/^/    /' >&2
            why="It has local changes or files (above): they are yours, so nothing is stashed, reset, deleted or overwritten."
        fi
        if [ "$CHECK" = 1 ]; then
            missing "a clean clone of $REPO_URL in $DIR (this one would stop the setup)"
            info "$why"
            info "$NOT_OURS_HINT"
        else
            stop_not_ours "$why"
        fi ;;
    absent|empty)
        if [ "$CHECK" = 1 ]; then
            missing "the NX 18 checkout in $DIR (this script clones it)"
        elif ask "Clone $REPO_URL ($REF) into $DIR (a few hundred MB)?"; then
            run git clone --branch "$REF" "$REPO_URL" "$DIR" || stop "git clone failed (is '$REF' a branch or tag of $REPO_URL?)"
            repo_state
            ok "cloned: $(describe_head)"
        else
            missing "the NX 18 checkout in $DIR"
        fi ;;
    ours)
        ok "$DIR is a clean clone: $(describe_head)"
        if [ "$CHECK" = 1 ]; then
            info "(--check does not contact GitHub; run without --check to update to the newest $REF)"
        elif ask "Fetch from GitHub and update $DIR to the newest $REF?"; then
            run git -C "$DIR" fetch --tags origin || stop "git fetch failed: check the network and run this again."
            cur="$(git_ro symbolic-ref -q --short HEAD 2>/dev/null || true)"
            if git_ro show-ref --verify --quiet "refs/remotes/origin/$REF"; then
                if [ -z "$cur" ] && [ -n "$(git_ro rev-list -n 1 HEAD --not --remotes --tags 2>/dev/null)" ]; then
                    stop_not_ours "Its detached HEAD has commits that are on no branch or tag of GitHub; switching would leave them behind."
                fi
                if [ "$cur" != "$REF" ]; then
                    if git_ro show-ref --verify --quiet "refs/heads/$REF"; then
                        run git -C "$DIR" checkout "$REF" --
                    else
                        run git -C "$DIR" checkout -b "$REF" --track "origin/$REF"
                    fi
                    if [ -n "$cur" ]; then info "(your branch $cur is kept as it was)"; fi
                fi
                ahead="$(git_ro rev-list --count "origin/$REF..$REF")"
                behind="$(git_ro rev-list --count "$REF..origin/$REF")"
                if [ "$ahead" != 0 ] && [ "$behind" != 0 ]; then
                    stop_not_ours "Its branch $REF has $ahead commit(s) that are not on GitHub and is $behind behind: it is left as it is."
                elif [ "$behind" != 0 ]; then
                    run git -C "$DIR" merge --ff-only --quiet "origin/$REF"
                    ok "updated: $(describe_head)"
                elif [ "$ahead" != 0 ]; then
                    warn "your branch $REF has $ahead commit(s) that are not on GitHub; it is left as it is"
                else
                    ok "already the newest $REF"
                fi
            elif git_ro show-ref --verify --quiet "refs/tags/$REF"; then
                want="$(git_ro rev-parse "refs/tags/$REF^{commit}")"
                if [ "$(git_ro rev-parse HEAD)" = "$want" ]; then
                    ok "already at tag $REF"
                else
                    if [ -z "$cur" ] && [ -n "$(git_ro rev-list -n 1 HEAD --not --remotes --tags 2>/dev/null)" ]; then
                        stop_not_ours "Its detached HEAD has commits that are on no branch or tag of GitHub; switching would leave them behind."
                    fi
                    run git -C "$DIR" checkout --detach "refs/tags/$REF"
                    if [ -n "$cur" ]; then info "(your branch $cur is kept as it was)"; fi
                    ok "at tag $REF: $(describe_head)"
                fi
            else
                stop "'$REF' is neither a branch nor a tag of $REPO_URL."
            fi
        else
            info "(not updated)"
        fi ;;
esac
HAVE_REPO=0
if [ "$REPO_STATE" = ours ] && [ -f "$DIR/scripts/build_ipa_from_nsp.py" ]; then
    HAVE_REPO=1
    read_requirements
fi

# ---- 5. the Metal toolchain and the iOS platform (after the checkout, whose lock names the compiler) ----
section "Metal toolchain"
if [ -n "$DEV" ]; then
    m="$(metal_of "$DEV" macosx)"
    if [ -z "$m" ]; then
        if ask "The Metal toolchain of $(basename "$XCODE_APP") is not installed. Download it from Apple now (about 700 MB)?"; then
            run env DEVELOPER_DIR="$DEV" xcodebuild -downloadComponent MetalToolchain || warn "the Metal toolchain download failed"
            m="$(metal_of "$DEV" macosx)"
        fi
    fi
    if [ -z "$m" ]; then
        missing "the Metal toolchain: DEVELOPER_DIR=\"$DEV\" xcodebuild -downloadComponent MetalToolchain"
    elif [ "$m" = "$LOCK_METAL_MAC" ]; then
        ok "Metal compiler for macOS: $m (matches $LOCK_FROM)"
    else
        missing "Metal compiler $m: the shaders were tested with $LOCK_METAL_MAC ($LOCK_FROM)"
        info "Install the Xcode $NEED_XCODE build named in README.md (Requirements) and its Metal toolchain,"
        info "or build anyway with --allow-other-metal in nx18-build.sh's EXTRA_ARGS (untested shaders can render wrong pictures)."
    fi
    # iPhone and iPad builds: the iOS platform and its Metal compiler
    if DEVELOPER_DIR="$DEV" xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
        ok "iOS platform (for iPhone and iPad builds)"
    else
        if ask "Xcode's iOS platform is not installed; iPhone and iPad builds need it (Mac apps do not). Download it from Apple now (several GB)?"; then
            run env DEVELOPER_DIR="$DEV" xcodebuild -downloadPlatform iOS || warn "the iOS platform download failed"
        fi
        if DEVELOPER_DIR="$DEV" xcrun -sdk iphoneos --show-sdk-path >/dev/null 2>&1; then
            ok "iOS platform (for iPhone and iPad builds)"
        else
            missing "Xcode's iOS platform, for iPhone and iPad builds only: Xcode > Settings > Components, or DEVELOPER_DIR=\"$DEV\" xcodebuild -downloadPlatform iOS"
        fi
    fi
    mi="$(metal_of "$DEV" iphoneos)"
    if [ -n "$mi" ] && [ "$mi" != "$LOCK_METAL_IOS" ]; then
        missing "Metal compiler for iOS $mi: the shaders were tested with $LOCK_METAL_IOS ($LOCK_FROM)"
    fi
else
    missing "the Metal toolchain (install Xcode $NEED_XCODE first)"
fi

# ---- 6. Python and its modules -----------------------------------------------------------------
section "Python"
py_ok() {   # py_ok <python>: an arm64 Python 3.12 or newer
    "$1" -c 'import sys, platform; sys.exit(0 if sys.version_info >= (3, 12) and platform.machine() == "arm64" else 1)' >/dev/null 2>&1
}
py_desc() { "$1" -c 'import sys, platform; print("Python %d.%d.%d (%s)" % (sys.version_info[:3] + (platform.machine(),)))' 2>/dev/null || echo "?"; }
find_python() {
    local p
    for p in "$(command -v python3 2>/dev/null || true)" /opt/homebrew/bin/python3 /opt/homebrew/bin/python3.15 /opt/homebrew/bin/python3.14 /opt/homebrew/bin/python3.13 /opt/homebrew/bin/python3.12; do
        [ -n "$p" ] && [ -x "$p" ] && [ "$p" != /usr/bin/python3 ] && py_ok "$p" && { printf '%s\n' "$p"; return 0; }
    done
    return 1
}
PY="$(find_python || true)"
if [ -z "$PY" ] && [ -n "$BREW" ]; then
    if ask "No arm64 Python 3.12 or newer was found (macOS's own python3 is too old). Install Python with Homebrew?"; then
        run "$BREW" install python || warn "brew install python failed"
        PY="$(find_python || true)"
    fi
fi
if [ -z "$PY" ]; then
    missing "an arm64 Python 3.12 or newer: brew install python"
else
    ok "$(py_desc "$PY") at $PY"
fi

VENV="$DIR/.venv"
VPY="$VENV/bin/python"
MODCHECK='
import importlib.util as u, sys
def has(m):
    try: return u.find_spec(m) is not None
    except Exception: return False
bad = [m for m in ("lz4.block", "capstone", "fontTools", "zbic", "nsz") if not has(m)]
if not (has("compression.zstd") or has("backports.zstd")): bad.append("backports.zstd")
if "capstone" not in bad:
    try:
        import capstone
        if capstone.cs_version()[0] != 5: bad.append("capstone 5.x (found %s)" % capstone.__version__)
    except Exception: bad.append("capstone (does not load)")
print(" ".join(bad))
'
if [ "$HAVE_REPO" = 1 ] || [ -d "$VENV" ]; then
    if [ -d "$VENV" ] && ! py_ok "$VPY"; then
        if [ -n "$PY" ] && ask "The virtualenv in $VENV does not run (its Python was updated or removed). Make it again with $PY?"; then
            run "$PY" -m venv --clear "$VENV" || warn "making the virtualenv failed"
        fi
    elif [ ! -d "$VENV" ] && [ -n "$PY" ]; then
        if ask "Make a Python virtualenv for NX 18 in $VENV (the modules go there, not into your system Python)?"; then
            run "$PY" -m venv "$VENV" || warn "making the virtualenv failed"
        fi
    fi
    if py_ok "$VPY"; then
        ok "virtualenv $VENV ($(py_desc "$VPY"))"
        bad="$("$VPY" -c "$MODCHECK" 2>/dev/null || echo '?')"
        if [ -n "$bad" ]; then
            if ask "Install the Python modules NX 18 needs into the virtualenv (missing: $bad) with pip?"; then
                run "$VPY" -m pip install "${PY_MODULES_PIP[@]}" || warn "pip install failed"
                bad="$("$VPY" -c "$MODCHECK" 2>/dev/null || echo '?')"
            fi
        fi
        if [ -z "$bad" ]; then
            ok "Python modules: lz4, capstone 5, fonttools, nsz, zbic, zstd"
        else
            missing "Python modules in the virtualenv: $bad"
            info "\"$VPY\" -m pip install $(printf "'%s' " "${PY_MODULES_PIP[@]}")"
        fi
    else
        missing "the virtualenv $VENV: ${PY:-python3} -m venv \"$VENV\""
    fi
elif [ "$REPO_STATE" = absent ] || [ "$REPO_STATE" = empty ]; then
    missing "the virtualenv and Python modules (made inside the checkout, once it is cloned)"
else
    missing "the virtualenv and Python modules (made inside the checkout, once it is a clean clone)"
fi

# ---- summary -----------------------------------------------------------------------------------
section "Summary"
printf '%s' "$SUMMARY" | while IFS='	' read -r kind text; do
    case "$kind" in
        missing) printf '  %smissing%s  %s\n' "$R" "$N" "$text" ;;
        warn)    printf '  %swarning%s  %s\n' "$Y" "$N" "$text" ;;
    esac
done
if [ "$MISSING" -gt 0 ]; then
    printf '\n%d thing(s) missing. ' "$MISSING"
    if [ "$CHECK" = 1 ]; then printf 'Run  bash nx18-setup.sh  (without --check) to install what a script can install.\n'
    else printf 'Fix them (see above) and run this script again; it only does what is still missing.\n'; fi
    exit 1
fi
printf '\n%sReady to build.%s NX 18 is in %s\n' "$G" "$N" "$DIR"
if [ -f "$HOME/nx18-build.sh" ]; then
    printf '\nNext step: build a game with your copy of nx18-build.sh (check the settings at its top%s):\n' "$([ "$DIR" != "$HOME/NX18" ] && printf ', CHECKOUT="%s" among them' "$DIR")"
else
    if [ -f "$DIR/scripts/release/nx18-build.sh" ]; then
        printf '\nNext step: build a game with nx18-build.sh. Copy it out of the NX 18 folder first (an edited file in\n'
        printf 'the folder stops this script from updating it):\n'
        printf '  cp -n "%s/scripts/release/nx18-build.sh" ~/nx18-build.sh\n' "$DIR"
    else
        printf '\nNext step: build a game with nx18-build.sh, from the release page: save it as ~/nx18-build.sh.\n'
    fi
    printf 'Edit the settings at its top (GAME, KEYS, TARGET%s), then run:\n' "$([ "$DIR" != "$HOME/NX18" ] && printf ', and CHECKOUT="%s"' "$DIR")"
fi
printf '  bash ~/nx18-build.sh\n'
if [ "$NEED_DEVELOPER_DIR" = 1 ]; then printf '(nx18-build.sh selects %s for the build by itself.)\n' "$(basename "$XCODE_APP")"; fi
exit 0
