#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/" in messages is meant literally
#
# Run this on the freshly installed system, from the graphical session,
# as a normal user (it asks for sudo when needed). Safe to run more than once.
#   ./install.sh [--yes] [profile]    (no profile = "default", read from profiles/default)
#
# It reads the profile and applies it: packages, system tweaks, desktop
# settings and dotfiles. Before changing anything it shows what it is going
# to do and asks to continue (--yes skips the question).
# Steps that fail are collected and listed at the end.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd -P)"
. "$ROOT/lib/common.sh"

[[ $EUID -eq 0 ]] && die "do not run this with sudo, run it as your normal user"

ASSUME_YES=false PROFILE_ARG=""
for arg in "$@"; do
    case $arg in
        -y|--yes) ASSUME_YES=true ;;
        -*)       die "unknown option: $arg (usage: ./install.sh [--yes] [profile])" ;;
        *)        [[ -z $PROFILE_ARG ]] || die "give only one profile"; PROFILE_ARG=$arg ;;
    esac
done

resolve_profile "$PROFILE_ARG"
step "Profile: $PROFILE_DIR"
[[ -d $PROFILE_DIR ]] || die "profile not found (create it with ./backup.sh on the old system)"
check_distro
load_config
FAILED=()

# --- Plan ---------------------------------------------------------------------
# Show what is going to happen, before asking for sudo or changing anything.
# It only reads the profile and the home folder, and follows the same rules
# as the steps below.

group() { printf '\n   \033[1m%s\033[0m\n' "$*"; }
row()  { printf '     %-18s %s\n' "$1" "$2"; }
off()  { row "$1" "skipped ($2=false)"; }
join() { local IFS=,; echo "${*}" | sed 's/,/, /g'; }   # a b c -> "a, b, c"
count_list() { read_list "$1" | wc -l; }

step "Plan"

group "Packages"
if ! is_true "$DO_APT"; then
    off "apt repositories" DO_APT
elif [[ -d $PROFILE_DIR/apt-repos/sources ]]; then
    names=()
    for f in "$PROFILE_DIR"/apt-repos/sources/*; do n=$(basename "$f"); names+=("${n%.*}"); done
    row "apt repositories" "${#names[@]} to add: $(join "${names[@]}")"
    saved=$(cat "$PROFILE_DIR/apt-repos/codename" 2>/dev/null || true)
    current=$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
    if [[ -n $saved && $saved != "$current" ]]; then
        row "" "! saved for '$saved', this system is '$current': some may not work"
    fi
else
    row "apt repositories" "none"
fi

if is_true "$DO_UPGRADE"; then row "System upgrade" "yes (apt full-upgrade)"; else off "System upgrade" DO_UPGRADE; fi

if is_true "$DO_APT"; then
    row "apt packages" "$(count_list "$PROFILE_DIR/packages/apt.txt") to install"
else
    off "apt packages" DO_APT
fi

if is_true "$DO_FLATPAK"; then
    mapfile -t list < <(read_list "$PROFILE_DIR/packages/flatpak.txt")
    if ((${#list[@]})); then row "Flatpak apps" "${#list[@]} to install: $(join "${list[@]}")"; else row "Flatpak apps" "none"; fi
else
    off "Flatpak apps" DO_FLATPAK
fi

if is_true "$DO_SNAP"; then
    n=$(count_list "$PROFILE_DIR/packages/snap.txt")
    if ((n)) && ! command -v snap >/dev/null; then
        row "Snap apps" "$n, but snap is not installed: they will be skipped"
    elif ((n)); then
        row "Snap apps" "$n to install"
    else
        row "Snap apps" "none"
    fi
else
    off "Snap apps" DO_SNAP
fi

group "System"
row "Swappiness" "${SWAPPINESS:-unchanged}"
if is_true "$ENABLE_TRIM"; then row "TRIM" "weekly timer on"; else row "TRIM" "unchanged"; fi

group "Desktop and home folder"
if ! is_true "$DO_DCONF"; then
    off "Desktop settings" DO_DCONF
elif ! command -v dconf >/dev/null; then
    row "Desktop settings" "skipped (dconf is not installed)"
else
    list=()
    for ini in "$PROFILE_DIR"/dconf/*.ini; do if [[ -s $ini ]]; then list+=("$(dconf_path_for "$ini")"); fi; done
    if ((${#list[@]})); then row "Desktop settings" "${#list[@]} dconf branches: $(join "${list[@]}")"; else row "Desktop settings" "none"; fi
fi

if ! is_true "$DO_DOTFILES"; then
    off "Dotfiles" DO_DOTFILES
else
    new=0 bak=0 linked=0
    while IFS= read -r -d '' src; do
        rel=${src#"$PROFILE_DIR/dotfiles/"}
        [[ $(basename "$rel") == .gitkeep ]] && continue
        dst="$HOME/$rel"
        if [[ $(readlink -f "$dst" 2>/dev/null) == "$src" ]]; then linked=$((linked + 1))
        elif [[ -e $dst || -L $dst ]]; then bak=$((bak + 1))
        else new=$((new + 1)); fi
    done < <(find "$PROFILE_DIR/dotfiles" -type f -print0 2>/dev/null)
    if ((new + bak + linked == 0)); then
        row "Dotfiles" "none"
    else
        row "Dotfiles" "$((new + bak)) to link, $linked already linked"
        if ((bak)); then row "" "$bak existing file(s) in your home will be renamed to .bak.<date>"; fi
    fi
fi

group "Your own scripts"
if is_true "$DO_HOOKS"; then
    list=()
    for h in "$PROFILE_DIR"/hooks/pre-*.sh "$PROFILE_DIR"/hooks/post-*.sh; do if [[ -f $h ]]; then list+=("$(basename "$h")"); fi; done
    if ((${#list[@]})); then row "Hooks" "${#list[@]} to run: $(join "${list[@]}")"; else row "Hooks" "none"; fi
else
    off "Hooks" DO_HOOKS
fi

echo
if ! is_true "$ASSUME_YES"; then
    [[ -t 0 ]] || die "can't ask for confirmation here: run it with --yes to skip the question"
    echo "Nothing has been changed yet. If you continue, you will be asked for your password."
    read -r -p "Continue? [y/N] " answer
    [[ ${answer,,} =~ ^(y|yes)$ ]] || { echo "Stopped, nothing was changed."; exit 1; }
fi

# Ask for the sudo password once, then keep it alive in the background
# so it does not expire during long installs.
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done >/dev/null 2>&1 &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

# apt without questions: packages that ask something while installing (wireshark,
# for example) get their default answer, and config files you changed are kept.
apt_get() {
    sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
        -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold "$@"
}

# Run the profile's hooks/pre-*.sh or hooks/post-*.sh scripts, in name order.
run_hooks() {   # $1 = pre | post
    is_true "$DO_HOOKS" || return 0
    local h found=0
    for h in "$PROFILE_DIR"/hooks/"$1"-*.sh; do
        [[ -f $h ]] || continue
        ((found)) || { step "Hooks ($1)"; found=1; }
        info "$(basename "$h")"
        bash "$h" || FAILED+=("hook: $(basename "$h")")
    done
}

run_hooks pre

# Put back the third-party repositories saved by backup.sh, with their keys.
# apt then checks every package from them against those keys, as usual.
REPOS="$PROFILE_DIR/apt-repos"
if is_true "$DO_APT" && [[ -d $REPOS/sources ]]; then
    step "Third-party apt repositories"
    saved=$(cat "$REPOS/codename" 2>/dev/null || true)
    current=$(. /etc/os-release; echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}")
    if [[ -n $saved && $saved != "$current" ]]; then
        warn "these repositories were set up for '$saved', this system is '$current': some may not work"
    fi
    if [[ -d $REPOS/keys ]]; then
        while IFS= read -r -d '' key; do
            sudo install -D -m 0644 "$key" "${key#"$REPOS/keys"}" || FAILED+=("apt key: ${key#"$REPOS/keys"}")
        done < <(find "$REPOS/keys" -type f -print0)
    fi
    for src in "$REPOS"/sources/*; do
        if sudo install -m 0644 "$src" /etc/apt/sources.list.d/; then
            info "$(basename "$src")"
        else
            FAILED+=("apt repository: $(basename "$src")")
        fi
    done
fi

if is_true "$DO_APT" || is_true "$DO_UPGRADE"; then
    step "System update"
    # A repository with a bad or expired key makes "apt-get update" fail, but the
    # others are still updated, so this is reported instead of stopping here.
    apt_get update || FAILED+=("apt-get update: a repository failed, see the messages above")
    if is_true "$DO_UPGRADE"; then
        # If the upgrade fails, apt itself is in trouble: installing more
        # packages on top would only make it worse, so this one stops the script.
        apt_get full-upgrade || die "the system upgrade failed: fix apt (see the messages above) and run this script again"
    fi
fi

if is_true "$DO_APT"; then
    step "apt packages"
    mapfile -t WANTED < <(read_list "$PROFILE_DIR/packages/apt.txt")
    # Keep only packages that exist in this release, so one bad name
    # does not break the whole install.
    PKGS=()
    for p in "${WANTED[@]}"; do
        if apt-cache show "$p" >/dev/null 2>&1; then PKGS+=("$p"); else FAILED+=("apt: $p (not found)"); fi
    done
    if ((${#PKGS[@]})); then
        apt_get install "${PKGS[@]}" || {
            warn "bulk install failed, trying one package at a time..."
            for p in "${PKGS[@]}"; do apt_get install "$p" || FAILED+=("apt: $p"); done
        }
    fi
fi

if is_true "$DO_FLATPAK"; then
    mapfile -t APPS < <(read_list "$PROFILE_DIR/packages/flatpak.txt")
    if ((${#APPS[@]})); then
        step "Flatpak apps"
        command -v flatpak >/dev/null || apt_get install flatpak || true
        if ! command -v flatpak >/dev/null; then
            FAILED+=("flatpak: could not install flatpak, ${#APPS[@]} apps not installed")
        elif sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
            for a in "${APPS[@]}"; do
                sudo flatpak install -y --noninteractive flathub "$a" || FAILED+=("flatpak: $a")
            done
        else
            FAILED+=("flatpak: could not add Flathub, ${#APPS[@]} apps not installed")
        fi
    fi
fi

if is_true "$DO_SNAP"; then
    mapfile -t SNAPS < <(read_list "$PROFILE_DIR/packages/snap.txt")
    if ((${#SNAPS[@]})); then
        step "Snap apps"
        if command -v snap >/dev/null; then
            for line in "${SNAPS[@]}"; do
                read -ra args <<< "$line"     # e.g. "code --classic"
                sudo snap install "${args[@]}" || FAILED+=("snap: ${args[0]}")
            done
        else
            warn "snap is not available (Linux Mint disables it by default), skipping"
            FAILED+=("snap: ${#SNAPS[@]} apps not installed")
        fi
    fi
fi

if [[ -n $SWAPPINESS ]] || is_true "$ENABLE_TRIM"; then
    step "System tweaks"
    if [[ -n $SWAPPINESS ]]; then
        if echo "vm.swappiness=$SWAPPINESS" | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null \
                && sudo sysctl --system >/dev/null; then
            info "swappiness = $SWAPPINESS"
        else
            FAILED+=("swappiness")
        fi
    fi
    if is_true "$ENABLE_TRIM"; then
        sudo systemctl enable --now fstrim.timer >/dev/null 2>&1 && info "weekly TRIM enabled" || FAILED+=("fstrim.timer")
    fi
fi

if is_true "$DO_DCONF" && command -v dconf >/dev/null; then
    step "Desktop settings (dconf)"
    for ini in "$PROFILE_DIR"/dconf/*.ini; do
        [[ -s $ini ]] || continue
        path=$(dconf_path_for "$ini")
        dconf load "$path" < "$ini" && info "$path" || FAILED+=("dconf: $path")
    done
fi

if is_true "$DO_DOTFILES" && [[ -d $PROFILE_DIR/dotfiles ]]; then
    step "Dotfiles"
    # Dotfiles are linked, not copied: ~/.bashrc becomes a symlink to the
    # file in the profile, so editing it edits the repo copy.
    while IFS= read -r -d '' src; do
        rel=${src#"$PROFILE_DIR/dotfiles/"}
        [[ $(basename "$rel") == .gitkeep ]] && continue
        dst="$HOME/$rel"
        if [[ $(readlink -f "$dst" 2>/dev/null) == "$src" ]]; then info "~/$rel (already linked)"; continue; fi
        mkdir -p "$(dirname "$dst")"
        # Never overwrite: an existing file is renamed to .bak.<date> first.
        [[ -e $dst || -L $dst ]] && mv "$dst" "$dst.bak.$(date +%Y%m%d-%H%M%S)"
        ln -s "$src" "$dst"
        info "~/$rel -> profile"
    done < <(find "$PROFILE_DIR/dotfiles" -type f -print0)
fi

run_hooks post

step "Done"
if ((${#FAILED[@]})); then
    printf '\033[1;33mCheck these by hand:\033[0m\n'; printf '  - %s\n' "${FAILED[@]}"
    echo "The rest is done. Reboot (or log out and back in) to apply it."
    # Exit with an error, so a script that runs this one can tell something failed.
    exit 1
fi
echo "All good. Reboot (or log out and back in) to apply everything."
