#!/usr/bin/env bash
# Runs install.sh for real with a small profile, twice. It changes the system,
# so it only runs on a throwaway machine (GitHub Actions sets CI=true).
#   CI=true tests/install-smoke.sh
set -uo pipefail
[[ ${CI:-} == true ]] || { echo "This test changes the system: it only runs in CI."; exit 1; }
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT" || exit 1
fails=0
check() {
    if [[ $2 == "$3" ]]; then printf '  ok    %s\n' "$1"
    else printf '  FAIL  %s (expected %q, got %q)\n' "$1" "$2" "$3"; fails=$((fails + 1)); fi
}

# A small profile: one real package, one that does not exist, one dotfile.
p=profiles/ci
rm -rf "$p"
mkdir -p "$p/packages" "$p/dotfiles"
cp profiles/example/setup.conf "$p/"
sed -i 's/^DO_UPGRADE=.*/DO_UPGRADE=false/; s/^DO_FLATPAK=.*/DO_FLATPAK=false/; s/^DO_SNAP=.*/DO_SNAP=false/;
        s/^DO_DCONF=.*/DO_DCONF=false/; s/^SWAPPINESS=.*/SWAPPINESS=10/; s/^ENABLE_TRIM=.*/ENABLE_TRIM=false/' "$p/setup.conf"
printf 'figlet\nno-such-package-xyz\n' > "$p/packages/apt.txt"
echo 'from the profile' > "$p/dotfiles/.linux-setup-test"
echo 'already here' > "$HOME/.linux-setup-test"

echo "first run"
out=$(./install.sh --yes ci 2>&1); code=$?
echo "$out" | sed 's/^/    | /'
check "exits with 1 because one package is missing" 1 "$code"
check "the missing package is in the final list" yes "$(grep -q 'no-such-package-xyz (not found)' <<< "$out" && echo yes || echo no)"
check "figlet is installed" yes "$(command -v figlet >/dev/null && echo yes || echo no)"
check "swappiness is 10" 10 "$(cat /proc/sys/vm/swappiness)"
check "the dotfile is a link to the profile" "$ROOT/$p/dotfiles/.linux-setup-test" "$(readlink "$HOME/.linux-setup-test")"
check "the old file was kept as .bak" "already here" "$(cat "$HOME"/.linux-setup-test.bak.* 2>/dev/null)"

echo "second run"
out=$(./install.sh --yes ci 2>&1); code=$?
check "same exit code" 1 "$code"
check "the dotfile is reported as already linked" yes "$(grep -q 'already linked' <<< "$out" && echo yes || echo no)"
check "no new .bak file" 1 "$(find "$HOME" -maxdepth 1 -name '.linux-setup-test.bak.*' | wc -l)"

rm -rf "$p"
echo
if ((fails)); then echo "$fails test(s) failed"; exit 1; fi
echo "All tests passed"
