#!/usr/bin/env bash
# shellcheck disable=SC2088  # "~/" in messages is meant literally
#
# Run this on your CURRENT system, before reinstalling.
#   ./backup.sh [profile]     (no argument = "default", saved in profiles/default)
#
# It reads the system and saves what it finds into the profile: apt, Flatpak
# and Snap packages, desktop settings (dconf) and dotfiles.
# It only reads from the system; the only things it writes are inside the profile.
# What to save is controlled by profiles/<profile>/setup.conf.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
. "$ROOT/lib/common.sh"

resolve_profile "${1:-}"
step "Profile: $PROFILE_DIR"
check_distro

# First run for this profile: start from a copy of the example config.
if [[ ! -f $PROFILE_DIR/setup.conf ]]; then
    mkdir -p "$PROFILE_DIR"
    cp "$ROOT/profiles/example/setup.conf" "$PROFILE_DIR/"
    info "new profile: copied setup.conf from the example (edit it if you need to)"
fi
load_config
mkdir -p "$PROFILE_DIR"/{packages,dconf,dotfiles,hooks}

if is_true "$DO_APT"; then
    step "Manually installed apt packages"
    out="$PROFILE_DIR/packages/apt.txt"
    initial=/var/log/installer/initial-status.gz
    if [[ -r $initial ]]; then
        # "Manual" packages include everything the installer put there.
        # Subtract the list from install time to keep only what you added.
        comm -23 <(apt-mark showmanual | sort -u) \
                 <(gzip -dc "$initial" | sed -n 's/^Package: //p' | sort -u) > "$out"
    else
        warn "$initial not found, saving all manual packages (review the list)"
        apt-mark showmanual | sort -u > "$out"
    fi
    # Kernel packages tied to one version (linux-image-6.8.0-106-generic...) pile up
    # with updates. The new system brings its own kernel, so they are left out.
    sed -i -E '/^linux-(image|headers|modules|modules-extra|tools|cloud-tools)-[0-9]/d' "$out"
    info "$(wc -l < "$out") packages -> packages/apt.txt"

    # Only a reminder: third-party repositories are not restored automatically.
    # Re-add them with a pre-*.sh hook.
    # Mint keeps its official mirrors (which may be local ones) in
    # official-package-repositories.list, so that file is skipped.
    find /etc/apt/sources.list.d -type f ! -name official-package-repositories.list \
            -exec grep -hE '^(deb |URIs:)' {} + 2>/dev/null \
        | grep -v -e 'linuxmint.com' -e 'ubuntu.com' | sort -u \
        > "$PROFILE_DIR/packages/apt-sources.txt" || true
    if [[ -s $PROFILE_DIR/packages/apt-sources.txt ]]; then
        info "third-party repositories -> packages/apt-sources.txt (recreate them with a hook)"
    fi
fi

if is_true "$DO_FLATPAK" && command -v flatpak >/dev/null; then
    step "Flatpak apps"
    flatpak list --app --columns=application | sort -u > "$PROFILE_DIR/packages/flatpak.txt"
    info "$(wc -l < "$PROFILE_DIR/packages/flatpak.txt") apps -> packages/flatpak.txt"
fi

if is_true "$DO_SNAP" && command -v snap >/dev/null; then
    step "Snap apps"
    # Skip runtimes and base snaps, keep real apps (and their --classic flag).
    snap list 2>/dev/null | awk 'NR>1 && $1 !~ /^(core[0-9]*|snapd|bare|gtk-common-themes|gnome-[0-9-]+|kf[56]-.*|mesa-.*)$/ {
        print $1 ($NF ~ /classic/ ? " --classic" : "") }' > "$PROFILE_DIR/packages/snap.txt"
    info "$(wc -l < "$PROFILE_DIR/packages/snap.txt") apps -> packages/snap.txt"
fi

if is_true "$DO_DCONF" && command -v dconf >/dev/null; then
    step "Desktop settings (dconf)"
    ((${#DCONF_PATHS[@]})) || read -ra DCONF_PATHS <<< "$(default_dconf_paths)"
    if ((${#DCONF_PATHS[@]})); then
        for p in "${DCONF_PATHS[@]}"; do
            f=$(dconf_file_for "$p")
            dconf dump "$p" > "$PROFILE_DIR/dconf/$f"
            info "$p -> dconf/$f"
        done
    else
        warn "desktop '${XDG_CURRENT_DESKTOP:-?}' not recognised: set DCONF_PATHS in setup.conf"
    fi
fi

if is_true "$DO_DOTFILES"; then
    step "Dotfiles"
    for f in "${DOTFILES[@]}"; do
        [[ -e $HOME/$f ]] || continue
        # Each entry can be a file or a folder. find -type f only returns real files,
        # so anything that is already a symlink into the repo is skipped.
        while IFS= read -r -d '' src; do
            rel=${src#"$HOME"/}
            mkdir -p "$(dirname "$PROFILE_DIR/dotfiles/$rel")"
            cp "$src" "$PROFILE_DIR/dotfiles/$rel"
            info "~/$rel"
        done < <(find "$HOME/$f" -type f -print0)
    done
    if grep -rIlE '(token|secret|passw(or)?d|api[_-]?key)[[:space:]]*[=:]' "$PROFILE_DIR/dotfiles" 2>/dev/null; then
        warn "the files above look like they contain credentials: check them before you push"
    fi
fi

echo
echo "Done. Review the changes with 'git diff', then:"
echo "  git add -A && git commit -m 'backup' && git push"
