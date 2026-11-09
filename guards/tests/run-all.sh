#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-11-09: every unit test, from the repo root. Exit 1 on any failure.
set -uo pipefail
cd "$(dirname "$0")/../.."
git config --global user.email >/dev/null 2>&1 || { git config --global user.email ci@example.com; git config --global user.name ci; }
fail=0; o="$(mktemp)"
for t in guards/tests/*-test.sh; do
  if bash "$t" >"$o" 2>&1; then echo "ok   $t"; else echo "FAIL $t"; tail -20 "$o"; fail=1; fi
done
for t in guards/tests/*-test.py; do
  if python3 -I "$t" >"$o" 2>&1; then echo "ok   $t"; else echo "FAIL $t"; tail -20 "$o"; fail=1; fi
done
if bash .github/scripts/pin-lint.sh >"$o" 2>&1; then echo "ok   pin-lint"; else echo "FAIL pin-lint"; cat "$o"; fail=1; fi
rm -f "$o"
exit "$fail"
