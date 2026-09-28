#!/bin/bash

set -euo pipefail

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/base-test.sh"
require_command jq

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

home="$tmpdir/home dir"
effects="$home/.config/omarchy/screensaver/effects"
logo="$home/.config/omarchy/branding/screensaver.txt"
mkdir -p "$tmpdir/bin" "$(dirname "$logo")"
: >"$logo"

cat >"$tmpdir/bin/hyprctl" <<'SH'
#!/bin/bash
[[ $1 == activewindow ]] && printf '{"class":"org.omarchy.screensaver"}\n'
exit 0
SH
# Three built-in effects. Every effect records itself, and after $STOP_AFTER
# runs one stops the screensaver the way it is normally stopped.
cat >"$tmpdir/bin/ttfx" <<'SH'
#!/bin/bash
if [[ $1 == --help ]]; then
  [[ -n ${TTFX_NO_COMMANDS:-} ]] && exit 0
  printf 'Usage: ttfx [OPTIONS] [COMMAND]\n\nCommands:\n  beams    Beams\n  decrypt  Decrypt\n  matrix   Matrix\n  help     Print this message\n\nOptions:\n  -h, --help\n'
  exit 0
fi
printf 'ttfx %s\n' "$*" >>"$TEST_DIR/runs"
(($(wc -l <"$TEST_DIR/runs") >= STOP_AFTER)) && kill -TERM $PPID
exit 0
SH
# shuf answers with the scripted draws, in order, and records what was asked.
cat >"$tmpdir/bin/shuf" <<'SH'
#!/bin/bash
printf '%s\n' "$*" >>"$TEST_DIR/draws-asked"
mapfile -t draws <"$TEST_DIR/draws"
n=$(($(wc -l <"$TEST_DIR/draws-asked") - 1))
echo "${draws[n % ${#draws[@]}]}"
SH
printf '#!/bin/bash\necho "30 100"\n' >"$tmpdir/bin/stty"
printf '#!/bin/bash\nexit 0\n' >"$tmpdir/bin/pkill"
chmod +x "$tmpdir/bin/"*

custom_effect() { # name
  mkdir -p "$effects"
  cat >"$effects/$1" <<SH
#!/bin/bash
printf '$1 %s %s\n' "\$#" "\$1" >>"\$TEST_DIR/runs"
((\$(wc -l <"\$TEST_DIR/runs") >= STOP_AFTER)) && kill -TERM \$PPID
exit 0
SH
  chmod +x "$effects/$1"
}

run_screensaver() { # draws...
  : >"$tmpdir/runs"
  : >"$tmpdir/draws-asked"
  printf '%s\n' "${@:-0}" >"$tmpdir/draws"
  PATH="$tmpdir/bin:$PATH" HOME="$home" TEST_DIR="$tmpdir" STOP_AFTER="${STOP_AFTER:-4}" \
    timeout 10 "$ROOT/bin/omarchy-screensaver" </dev/null >/dev/null 2>&1 || true
}

stock_run="ttfx -i $logo --frame-rate 120 --canvas-width 0 --canvas-height 0 --reuse-canvas --anchor-canvas c --anchor-text c --random-effect --no-eol --no-restore-cursor"

run_screensaver
[[ $(sort -u "$tmpdir/runs") == "$stock_run" && $(wc -l <"$tmpdir/runs") -eq 4 ]] ||
  fail "without an effects directory, ttfx runs exactly as before" "$(cat "$tmpdir/runs")"
[[ ! -s $tmpdir/draws-asked ]] || fail "without custom effects nothing is drawn" "$(cat "$tmpdir/draws-asked")"
pass "without an effects directory, ttfx runs exactly as before"

mkdir -p "$effects"
run_screensaver
[[ $(sort -u "$tmpdir/runs") == "$stock_run" && ! -s $tmpdir/draws-asked ]] ||
  fail "an empty effects directory changes nothing" "$(cat "$tmpdir/runs")"
pass "an empty effects directory changes nothing"

custom_effect aurora
custom_effect blackhole
custom_effect example.sample
printf '#!/bin/bash\necho notes >>"$TEST_DIR/runs"\n' >"$effects/notes"
mkdir -p "$effects/subdir"

run_screensaver 0 1 2 4
[[ $(sort -u "$tmpdir/draws-asked") == "-i 0-4 -n 1" ]] ||
  fail "custom effects share one draw with the built-in ones, a slot each" "$(sort -u "$tmpdir/draws-asked")"
[[ $(cut -d' ' -f1 "$tmpdir/runs" | paste -sd' ') == "aurora blackhole ttfx ttfx" ]] ||
  fail "each draw runs the matching effect, and the next one starts when it's done" "$(cat "$tmpdir/runs")"
pass "custom effects are as likely as each built-in one, and take turns with them"

grep -qxF "aurora 1 $logo" "$tmpdir/runs" ||
  fail "a custom effect gets the logo path as its only argument" "$(cat "$tmpdir/runs")"
pass "a custom effect gets the logo path as its only argument, spaces and all"

run_screensaver 2 3 4 0
! grep -qE '^(example|notes)' "$tmpdir/runs" || fail "samples, non-executables and directories are left out" "$(cat "$tmpdir/runs")"
pass "samples, non-executables and directories are left out"

rm "$effects/aurora"
TTFX_NO_COMMANDS=1 run_screensaver 1
[[ $(sort -u "$tmpdir/draws-asked") == "-i 0-1 -n 1" ]] ||
  fail "if ttfx lists no effects, it still counts as one" "$(sort -u "$tmpdir/draws-asked")"
pass "if ttfx lists no effects, it still counts as one"

# A key while a custom effect runs stops it along with the screensaver.
cat >"$effects/blackhole" <<'SH'
#!/bin/bash
echo $$ >"$TEST_DIR/effect.pid"
exec sleep 30
SH
: >"$tmpdir/draws-asked"
printf '0\n' >"$tmpdir/draws"
printf 'x' | PATH="$tmpdir/bin:$PATH" HOME="$home" TEST_DIR="$tmpdir" \
  timeout 10 "$ROOT/bin/omarchy-screensaver" >/dev/null 2>&1 || fail "a key exits the screensaver"
sleep 0.2
if kill -0 "$(<"$tmpdir/effect.pid")" 2>/dev/null; then
  kill "$(<"$tmpdir/effect.pid")"
  fail "a key stops the running custom effect"
fi
pass "a key stops the screensaver and the running custom effect"
