# shellcheck shell=bash
# shellcheck disable=SC2034  # the config variables are used by the scripts that source this file
#
# Shared helpers for backup.sh and install.sh.
# This file is sourced, never run directly.

# --- Output helpers ---------------------------------------------------------

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '   %s\n' "$*"; }
warn() { printf '\033[1;33m   ! %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mError: %s\033[0m\n' "$*" >&2; exit 1; }

# True for "true", "yes" or "1" (any case). Used for the DO_* switches.
is_true() { local v=${1:-}; [[ ${v,,} =~ ^(true|yes|1)$ ]]; }

# Print the entries of a list file, skipping empty lines and # comments.
read_list() {
    [[ -f $1 ]] || return 0
    sed 's/#.*//; s/^[[:space:]]*//; s/[[:space:]]*$//' "$1" | grep -v '^$' || true
}

# --- Distro check -----------------------------------------------------------

# Only Ubuntu and Ubuntu-based distros are supported (Mint, Pop!_OS, Zorin...).
# They all say so in /etc/os-release, either as ID or in ID_LIKE.
check_distro() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found"
    local id like pretty
    id=$(. /etc/os-release; echo "${ID:-}")
    like=$(. /etc/os-release; echo "${ID_LIKE:-}")
    pretty=$(. /etc/os-release; echo "${PRETTY_NAME:-$id}")
    if [[ $id == ubuntu || " $like " == *" ubuntu "* ]]; then
        info "Distro: $pretty"
    elif [[ ${FORCE:-0} == 1 ]]; then
        warn "$pretty is not Ubuntu-based, continuing because FORCE=1"
    else
        die "$pretty is not Ubuntu-based (use FORCE=1 to try anyway)"
    fi
}

# --- Profiles ---------------------------------------------------------------

# The profile is whatever you pass as the first argument.
# A plain name ("andre") means profiles/andre. Anything with a "/" is used as a path.
# With no argument the name is "default".
resolve_profile() {
    local arg=${1:-default}
    if [[ $arg == */* ]]; then
        PROFILE_DIR=$(realpath -m "$arg")
    elif [[ $arg == .* ]]; then
        die "'$arg' is not a valid profile name"
    else
        PROFILE_DIR="$ROOT/profiles/$arg"
    fi
    export PROFILE_DIR
}

# Set the defaults, then source the profile's setup.conf on top of them.
load_config() {
    DO_UPGRADE=true DO_APT=true DO_FLATPAK=true DO_SNAP=true DO_DCONF=true DO_DOTFILES=true DO_HOOKS=true
    SWAPPINESS="" ENABLE_TRIM=true
    DOTFILES=() DCONF_PATHS=()
    local conf="$PROFILE_DIR/setup.conf"
    [[ -f $conf ]] || die "missing $conf"
    # shellcheck disable=SC1090
    . "$conf"
}

# --- Laptop -----------------------------------------------------------------

# True if the machine has its own battery. A battery with scope=Device (a
# Bluetooth mouse, headphones...) does not count. POWER_SUPPLY_DIR is only
# there so the tests can point it at a fake folder.
is_laptop() {
    local dir=${POWER_SUPPLY_DIR:-/sys/class/power_supply} d
    for d in "$dir"/*/; do
        [[ -r $d/type ]] || continue
        [[ $(< "$d/type") == Battery ]] || continue
        if [[ -r $d/scope && $(< "$d/scope") == Device ]]; then continue; fi
        return 0
    done
    return 1
}

# --- dconf ------------------------------------------------------------------

# dconf branches to save, chosen from the desktop environment in use.
default_dconf_paths() {
    local de=${XDG_CURRENT_DESKTOP:-}
    case ${de,,} in
        *cinnamon*) echo /org/cinnamon/ /org/nemo/ /org/x/ /org/gnome/terminal/ ;;
        *mate*)     echo /org/mate/ ;;
        *budgie*)   echo /com/solus-project/ /org/gnome/ ;;
        *pantheon*) echo /io/elementary/ /org/gnome/ ;;
        *gnome*|*unity*) echo /org/gnome/ ;;
    esac
}

# A dconf path becomes a file name and back: /org/cinnamon/ <-> org.cinnamon.ini
dconf_file_for() { local p=${1#/}; p=${p%/}; echo "${p//\//.}.ini"; }
dconf_path_for() { local n; n=$(basename "$1" .ini); echo "/${n//.//}/"; }

# The dconf path of the power settings (sleep, lid, battery...) for this desktop.
# Prints nothing for a desktop we do not know.
power_dconf_path() {
    local de=${XDG_CURRENT_DESKTOP:-}
    case ${de,,} in
        *cinnamon*) echo /org/cinnamon/settings-daemon/plugins/power/ ;;
        *mate*)     echo /org/mate/power-manager/ ;;
        *budgie*|*pantheon*|*gnome*|*unity*) echo /org/gnome/settings-daemon/plugins/power/ ;;
    esac
}

# Remove the section [SECTION] from a dconf dump file, in place. A section is
# its header plus the lines after it, up to the next header. The empty line
# before a section is kept, the one after a removed section goes with it.
dconf_drop_section() {
    local file=$1 section=$2 tmp
    tmp=$(mktemp "$file.XXXXXX")
    awk -v s="[$section]" '
        /^\[/ { skip = ($0 == s) }
        skip { next }
        /^$/ { blank = blank "\n"; next }
        { printf "%s%s\n", blank, $0; blank = "" }
    ' "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}
