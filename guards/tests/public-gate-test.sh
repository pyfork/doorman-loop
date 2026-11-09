#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-11-09
# Unit test for .github/scripts/public-gate.sh, with made-up patterns only.
set -u
gate="$(cd "$(dirname "$0")/../../.github/scripts" && pwd)/public-gate.sh"
w="$(mktemp -d)"; trap 'rm -rf "$w"' EXIT
pass=0; fail=0
want() { # want <ok|fail> <name>; reads $w/p, $w/d, optional $w/t
  local out rc=0 t=""; [ -f "$w/t" ] && t="$w/t"
  out="$(bash "$gate" "$w/p" "$w/d" $t 2>&1)" || rc=$?
  local got=ok; [ "$rc" -ne 0 ] && got=fail
  if [ "$got" = "$1" ] && ! printf '%s' "$out" | grep -qi 'zebra'; then pass=$((pass+1)); echo "PASS $2"
  else fail=$((fail+1)); echo "FAIL $2 (want $1, got $got, or the match was printed)"; printf '%s\n' "$out" | sed 's/^/    /'; fi
}
fresh() { rm -rf "$w/d" "$w/t"; mkdir -p "$w/d/.git"; printf '# a comment\n\nzebra|okapi\n' > "$w/p"; echo "plain text" > "$w/d/a.txt"; }
fresh; want ok "G1 clean tree passes"
fresh; echo "see Zebra here" >> "$w/d/a.txt"; want fail "G2 a file match fails, case-insensitive, match not printed"
fresh; mkdir -p "$w/d/sub"; echo okapi > "$w/d/sub/b.md"; want fail "G3 a match in a subfolder fails"
fresh; echo zebra > "$w/d/.git/x"; want ok "G4 .git is skipped"
fresh; printf 'title\nbranch-zebra\n' > "$w/t"; want fail "G5 a match in the PR text fails"
fresh; printf 'title\nplain body\n' > "$w/t"; want ok "G6 clean PR text passes"
fresh; rm "$w/p"; want fail "G7 a missing list fails closed"
fresh; printf '# only comments\n\n' > "$w/p"; want fail "G8 an empty list fails closed"
fresh; printf 'a(\n' > "$w/p"; want fail "G9 a broken pattern fails closed"
echo "public-gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
