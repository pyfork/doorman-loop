#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-10-28
# Unit test for clip() in templates/.github/workflows/slice-review.yml, step
# "Run locked checks": a check's saved output keeps its head and its tail,
# so a failure after 50 KB of install noise still reaches results.txt.
# Run from anywhere: bash guards/tests/clip-output-test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
wf="$here/../templates/.github/workflows/slice-review.yml"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0
sed -n '/# clip-begin/,/# clip-end/p' "$wf" | sed 's/^          //' > "$work/clip.sh"
grep -q '^clip()' "$work/clip.sh" || { echo "FAIL: clip() not found in $wf"; exit 1; }
# shellcheck disable=SC1091
. "$work/clip.sh"
ok() { echo "PASS $1"; }
no() { echo "FAIL $1"; fails=1; }

# C1: 50 KB of noise, then the failing assertion, as the workflow writes it
R="$work"
{ echo "Collecting first-package"; for i in $(seq 1 1000); do echo "Requirement already satisfied: pkg$i in /venv (1.0)"; done
  echo "E   AssertionError: page count 3 != 2"; echo "FAIL check-redesign"; } > "$R/out.txt"
size=$(( $(wc -c < "$R/out.txt") )); [ "$size" -gt 50000 ] && ok "C0: noise is $size bytes" || no "C0: noise only $size bytes"
{ echo "FAIL checks/redesign.sh"; clip "$R/out.txt"; echo; echo; } >> "$R/results.txt"
grep -q '^    E   AssertionError: page count 3 != 2$' "$R/results.txt" && ok "C1: the assertion is kept" || no "C1: the assertion was lost"
grep -q '^    Collecting first-package$' "$R/results.txt" && ok "C2: the head is kept" || no "C2: the head was lost"
grep -q "^    … $((size - 4000)) bytes cut …$" "$R/results.txt" && ok "C3: the cut is marked with its size" || no "C3: no cut marker"
[ "$(wc -c < "$R/results.txt")" -lt 5000 ] && ok "C4: the entry stays small" || no "C4: the entry is $(wc -c < "$R/results.txt") bytes"

# C5: short output is kept whole, with no marker
printf 'one\ntwo\n' > "$work/short.txt"
[ "$(clip "$work/short.txt")" = "$(printf '    one\n    two')" ] && ok "C5: short output kept whole" || no "C5: short output changed"

# C6: no head-only or tail-only cut of check output is left in the step
if grep -nE '(head|tail) -c [0-9]+ "\$R/out.txt"' "$wf"; then no "C6: a one-sided cut is left"; else ok "C6: every cut goes through clip"; fi

[ "$fails" -eq 0 ] && echo "clip-output-test: all passed" || echo "clip-output-test: FAILED"
exit "$fails"
