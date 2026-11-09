#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-11-09
# public-gate: nothing in this repository, or in the text around a change,
# matches a private pattern. The patterns come from a file kept outside the
# repository (in CI, a secret), so this script holds none of them, and it
# prints only where a match is, never what matched.
#
# Usage: public-gate.sh <patterns-file> <dir> [text-file]
#   patterns-file  one extended regex per line, matched case-insensitively;
#                  blank lines and lines starting with # are skipped
#   dir            checked recursively, .git skipped
#   text-file      optional: PR title, body, branch name, commit messages
# Exit 1 on any match, on a missing or empty pattern list, or when grep
# can't run.
set -uo pipefail
pf="${1:?usage: public-gate.sh <patterns-file> <dir> [text-file]}"
dir="${2:?usage: public-gate.sh <patterns-file> <dir> [text-file]}"
text="${3:-}"
[ -s "$pf" ] || { echo "PUBLIC-GATE: no pattern list; refusing (fail closed)"; exit 1; }
pats="$(grep -vE '^[[:space:]]*(#|$)' "$pf" || true)"
[ -n "$pats" ] || { echo "PUBLIC-GATE: the pattern list is empty; refusing (fail closed)"; exit 1; }
bad=0; n=0
while IFS= read -r p; do
  n=$((n+1))
  rc=0; hits="$(grep -rniIE --exclude-dir=.git -- "$p" "$dir" | cut -d: -f1,2)" || rc=$?
  [ "$rc" -gt 1 ] && { echo "PUBLIC-GATE: pattern $n could not run (grep exit $rc)"; bad=1; continue; }
  [ -n "$hits" ] && { printf '%s\n' "$hits" | sed "s|^|PUBLIC-GATE: pattern $n at |"; bad=1; }
  if [ -n "$text" ]; then
    rc=0; lines="$(grep -niE -- "$p" "$text" | cut -d: -f1 | tr '\n' ' ')" || rc=$?
    [ "$rc" -gt 1 ] && { echo "PUBLIC-GATE: pattern $n could not run on the PR text (grep exit $rc)"; bad=1; continue; }
    [ -n "$lines" ] && { echo "PUBLIC-GATE: pattern $n in the PR text, lines $lines"; bad=1; }
  fi
done <<< "$pats"
[ "$bad" -eq 0 ] || { echo "PUBLIC-GATE: FAILED"; exit 1; }
echo "PUBLIC-GATE: OK ($n patterns)"
