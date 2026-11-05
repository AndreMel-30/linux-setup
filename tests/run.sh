#!/usr/bin/env bash
# Tests that are safe to run anywhere: the helpers in lib/common.sh, then
# backup.sh against a fake home folder. Nothing on the system is changed.
#   tests/run.sh
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT" || exit 1
fails=0

check() {   # check "what is tested" expected actual
    if [[ $2 == "$3" ]]; then
        printf '  ok    %s\n' "$1"
    else
        printf '  FAIL  %s\n        expected: %q\n        got:      %q\n' "$1" "$2" "$3"
        fails=$((fails + 1))
    fi
}

# Run a helper in a subshell, so a "die" does not end the tests.
lib() { ( . lib/common.sh; "$@" ) 2>&1; }

echo "is_true"
for v in true TRUE yes 1; do check "'$v' is true" yes "$(lib is_true "$v" && echo yes || echo no)"; done
for v in false no 0 ""; do check "'$v' is false" no "$(lib is_true "$v" && echo yes || echo no)"; done

echo "read_list"
list=$(mktemp)
printf 'git\r\n  curl  \n# a comment\n\nbtop # tool\ncode --classic\n' > "$list"
check "comments, blanks, spaces and CRLF are dropped" $'git\ncurl\nbtop\ncode --classic' "$(lib read_list "$list")"
check "a missing file gives nothing" "" "$(lib read_list /nonexistent)"
rm -f "$list"

echo "dconf paths"
for p in /org/cinnamon/ /org/gnome/terminal/ /com/solus-project/; do
    check "$p survives the round trip" "$p" "$(lib dconf_path_for "$(lib dconf_file_for "$p")")"
done
check "file name of /org/nemo/" org.nemo.ini "$(lib dconf_file_for /org/nemo/)"

echo "resolve_profile"
profile() { ( ROOT=$ROOT; . lib/common.sh; resolve_profile "$1"; echo "$PROFILE_DIR" ) 2>&1; }
check "no name means default" "$ROOT/profiles/default" "$(profile "")"
check "a plain name" "$ROOT/profiles/alice" "$(profile alice)"
check "a path is used as it is" "/tmp/my-profile" "$(profile /tmp/my-profile)"
out=$(profile ..)
check "'..' is refused" yes "$(grep -q 'not a valid profile name' <<< "$out" && echo yes || echo no)"

echo "is_laptop"
ps=$(mktemp -d)
mkdir -p "$ps/a/BAT0" "$ps/a/AC" "$ps/b/AC" "$ps/c/hid" "$ps/d/BAT0"
echo Battery > "$ps/a/BAT0/type"; echo Mains > "$ps/a/AC/type"
echo Mains > "$ps/b/AC/type"
echo Battery > "$ps/c/hid/type"; echo Device > "$ps/c/hid/scope"
echo Battery > "$ps/d/BAT0/type"; echo System > "$ps/d/BAT0/scope"
check "battery and mains adapter is a laptop" yes "$(POWER_SUPPLY_DIR=$ps/a lib is_laptop && echo yes || echo no)"
check "only a mains adapter is not a laptop" no "$(POWER_SUPPLY_DIR=$ps/b lib is_laptop && echo yes || echo no)"
check "a battery with scope=Device is not a laptop" no "$(POWER_SUPPLY_DIR=$ps/c lib is_laptop && echo yes || echo no)"
check "a battery with scope=System is a laptop" yes "$(POWER_SUPPLY_DIR=$ps/d lib is_laptop && echo yes || echo no)"
check "a missing folder is not a laptop" no "$(POWER_SUPPLY_DIR=$ps/nope lib is_laptop && echo yes || echo no)"
rm -rf "$ps"

echo "power_dconf_path"
check "Cinnamon" /org/cinnamon/settings-daemon/plugins/power/ "$(XDG_CURRENT_DESKTOP=X-Cinnamon lib power_dconf_path)"
check "GNOME" /org/gnome/settings-daemon/plugins/power/ "$(XDG_CURRENT_DESKTOP=GNOME lib power_dconf_path)"
check "ubuntu:GNOME" /org/gnome/settings-daemon/plugins/power/ "$(XDG_CURRENT_DESKTOP=ubuntu:GNOME lib power_dconf_path)"
check "MATE" /org/mate/power-manager/ "$(XDG_CURRENT_DESKTOP=MATE lib power_dconf_path)"
check "Budgie:GNOME" /org/gnome/settings-daemon/plugins/power/ "$(XDG_CURRENT_DESKTOP=Budgie:GNOME lib power_dconf_path)"
check "an unknown desktop gives nothing" "" "$(XDG_CURRENT_DESKTOP=KDE lib power_dconf_path)"

echo "dconf_drop_section"
f=$(mktemp)
make_ini() {   # make_ini FILE: three sections, the power one in the middle
    printf '%s\n' '[a]' 'x=1' '' '[settings-daemon/plugins/power]' 'sleep=0' 'low=10' '' '[theme]' "name='cinnamon'" > "$1"
}
make_ini "$f"
lib dconf_drop_section "$f" settings-daemon/plugins/power
check "the middle section is removed, the others are kept" $'[a]\nx=1\n\n[theme]\nname=\'cinnamon\'' "$(cat "$f")"
make_ini "$f"
lib dconf_drop_section "$f" theme
check "the last section is removed" $'[a]\nx=1\n\n[settings-daemon/plugins/power]\nsleep=0\nlow=10' "$(cat "$f")"
make_ini "$f"
before=$(cat "$f")
lib dconf_drop_section "$f" missing/section
check "a missing section leaves the file unchanged" "$before" "$(cat "$f")"
rm -f "$f"

echo "backup.sh with a fake home"
home=$(mktemp -d)
mkdir -p "$home/.config/app"
echo 'alias ll="ls -l"' > "$home/.bashrc"
echo 'x = 1' > "$home/.config/app/app.conf"
echo 'real' > "$home/real-file" && ln -s "$home/real-file" "$home/.vimrc"
rm -rf profiles/test
mkdir -p profiles/test
cp profiles/example/setup.conf profiles/test/
sed -i 's|^DOTFILES=.*|DOTFILES=(.bashrc .vimrc .config/app .missing)|; s|^DO_SNAP=.*|DO_SNAP=false|' profiles/test/setup.conf
out=$(HOME=$home FORCE=1 ./backup.sh test 2>&1); code=$?
check "backup.sh exits with 0" 0 "$code"
check "apt list is written" yes "$([[ -f profiles/test/packages/apt.txt ]] && echo yes || echo no)"
check ".bashrc is saved" yes "$(cmp -s "$home/.bashrc" profiles/test/dotfiles/.bashrc && echo yes || echo no)"
check "a folder entry is saved" yes "$([[ -f profiles/test/dotfiles/.config/app/app.conf ]] && echo yes || echo no)"
check "a symlinked dotfile is saved" real "$(cat profiles/test/dotfiles/.vimrc 2>/dev/null)"
check "a missing entry is skipped quietly" no "$(grep -q missing <<< "$out" && echo yes || echo no)"
out=$(./backup.sh example 2>&1)
check "backup into 'example' is refused" yes "$(grep -q 'template' <<< "$out" && echo yes || echo no)"
rm -rf profiles/test "$home"

echo
if ((fails)); then echo "$fails test(s) failed"; exit 1; fi
echo "All tests passed"
