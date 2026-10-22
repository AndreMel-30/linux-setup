#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/" in messages is meant literally
#
# Run this on the freshly installed system, from the graphical session,
# as a normal user (it asks for sudo when needed). Safe to run more than once.
#   ./install.sh [profile]    (no argument = "default", read from profiles/default)
#
# It reads the profile and applies it: packages, system tweaks, desktop
# settings and dotfiles. Steps that fail are collected and listed at the end.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/common.sh"

[[ $EUID -eq 0 ]] && die "do not run this with sudo, run it as your normal user"

resolve_profile "${1:-}"
step "Profile: $PROFILE_DIR"
[[ -d $PROFILE_DIR ]] || die "profile not found (create it with ./backup.sh on the old system)"
check_distro
load_config
FAILED=()

# Ask for the sudo password once, then keep it alive in the background
# so it does not expire during long installs.
sudo -v
while true; do sudo -n true; sleep 50; kill -0 "$$" 2>/dev/null || exit; done 2>/dev/null &
SUDO_KEEPALIVE=$!
trap 'kill "$SUDO_KEEPALIVE" 2>/dev/null || true' EXIT

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
            sudo install -D -m 0644 "$key" "${key#"$REPOS/keys"}"
        done < <(find "$REPOS/keys" -type f -print0)
    fi
    for src in "$REPOS"/sources/*; do
        sudo install -m 0644 "$src" /etc/apt/sources.list.d/
        info "$(basename "$src")"
    done
fi

step "System update"
# A repository with a bad or expired key makes "apt-get update" fail, but the
# others are still updated, so this is reported instead of stopping here.
sudo apt-get update || FAILED+=("apt-get update: a repository failed, see the messages above")
sudo apt-get full-upgrade -y

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
        sudo apt-get install -y "${PKGS[@]}" || {
            warn "bulk install failed, trying one package at a time..."
            for p in "${PKGS[@]}"; do sudo apt-get install -y "$p" || FAILED+=("apt: $p"); done
        }
    fi
fi

if is_true "$DO_FLATPAK"; then
    mapfile -t APPS < <(read_list "$PROFILE_DIR/packages/flatpak.txt")
    if ((${#APPS[@]})); then
        step "Flatpak apps"
        command -v flatpak >/dev/null || sudo apt-get install -y flatpak
        if sudo flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo; then
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
        echo "vm.swappiness=$SWAPPINESS" | sudo tee /etc/sysctl.d/99-swappiness.conf >/dev/null
        sudo sysctl --system >/dev/null
        info "swappiness = $SWAPPINESS"
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
else
    echo "All good. Reboot (or log out and back in) to apply everything."
fi
