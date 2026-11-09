#!/usr/bin/env bash
# guard-builder-Opus5.5-agent, 2026-10-25
# Unit test for .github/scripts/pin-lint.sh: pinned, local and digest-pinned
# actions pass; a tag, a branch, a short hash or a missing release comment
# each fail and are named.
# Run from the repo root: bash guards/tests/pin-lint-test.sh
set -uo pipefail
script="$(pwd)/.github/scripts/pin-lint.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0
sha=d23441a48e516b6c34aea4fa41551a30e30af803

wf() { # wf <case> <uses line>: a workflow with one step
  mkdir -p "$work/$1"
  printf 'jobs:\n  j:\n    runs-on: ubuntu-24.04\n    steps:\n%s\n' "$2" > "$work/$1/w.yml"
}
expect() { # expect <id> <case> <pass|fail> <text>
  out="$(bash "$script" "$work/$2" 2>&1)"; rc=$?
  if { [ "$3" = pass ] && [ "$rc" -eq 0 ]; } || { [ "$3" = fail ] && [ "$rc" -ne 0 ]; }; then
    if printf '%s' "$out" | grep -qF -- "$4"; then echo "PASS $1: $4"; return; fi
  fi
  echo "FAIL $1: expected $3 with '$4', got rc=$rc:"; echo "$out" | sed 's/^/    /'; fails=1
}

wf pinned "      - uses: actions/checkout@$sha # v6.1.0"
expect T1 pinned pass "OK"
wf named "      - name: Check out
        uses: actions/checkout@$sha # v6.1.0"
expect T2 named pass "OK"
wf local "      - uses: ./.github/actions/local"
expect T3 local pass "OK"
wf digest "      - uses: docker://alpine@sha256:$(printf 'a%.0s' $(seq 64))"
expect T4 digest pass "OK"
wf tag "      - uses: actions/checkout@v6"
expect T5 tag fail "'actions/checkout@v6' is not pinned"
wf branch "      - uses: actions/checkout@main"
expect T6 branch fail "is not pinned"
wf short "      - uses: actions/checkout@d23441a # v6.1.0"
expect T7 short fail "is not pinned"
wf nocomment "      - uses: actions/checkout@$sha"
expect T8 nocomment fail "has no release comment"
wf quoted "      - uses: 'actions/checkout@v6'"
expect T9 quoted fail "is not pinned"
wf dockertag "      - uses: docker://alpine:3.20"
expect T10 dockertag fail "is not pinned"
# The real templates and the kit's own CI are all pinned
out="$(cd "$(dirname "$script")/../.." && bash .github/scripts/pin-lint.sh 2>&1)" \
  && echo "PASS T11: the kit's templates and CI are pinned" \
  || { echo "FAIL T11: the kit itself has unpinned actions:"; echo "$out" | sed 's/^/    /'; fails=1; }

[ "$fails" -eq 0 ] && echo "pin-lint-test: all passed" || echo "pin-lint-test: FAILED"
exit "$fails"
