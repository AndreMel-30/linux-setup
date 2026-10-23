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
