#!/usr/bin/env bash
# kit-reviewer-Opus5.5-agent, 2026-11-01: which lane a PR is in.
# Usage: pr-lane.sh <main-dir> <pr-dir>   (pr-dir: a clone with origin/main)
# Prints one word:
#   PLAN   every changed file is a plan path: red until the owner approves
#   OWNED  every changed file is in main's risk map or a plan path (guards,
#          briefs, the map): the owner owns every line, so their approval
#          decides; the reviewer's "Not a slice" needs no bypass
#   CHORE  only new or added-to test files and CHANGELOG.md, nothing in
#          main's risk map: no model review, it merges on a green suite
#   OTHER  everything else: the normal review
# With no risk map on main nothing is a chore: every slice is risky.
set -euo pipefail
main="$1"; pr="$2"
# Same list as test-lock.sh and the reviewer's "Plan PRs"
plan_paths='^(specs/|plans/|acceptance/|docs-public/guard-data/locks/|docs-public/retro-log\.md$|README-brief-amended\.md$)'
# Test cases only, never helpers (support.py, conftest.py, fixtures): a
# helper changes how every other test runs
chore_test='^(tests?/)(.*/)?(test_[^/]*|[^/]*_test\.[^/]*|[^/]*\.test\.[^/]*)$'
map="$main/docs-public/guard-data/risk-map.txt"

files="$(git -C "$pr" diff --name-only origin/main...HEAD)"
[ -n "$files" ] || { echo OTHER; exit 0; }
if ! printf '%s\n' "$files" | grep -qvE "$plan_paths"; then echo PLAN; exit 0; fi
[ -f "$map" ] || { echo OTHER; exit 0; }
globs="$(grep -vE '^[[:space:]]*(#|$)' "$map" | awk '{print ":(glob)" $2}')"
# shellcheck disable=SC2086
mapped="$(git -C "$pr" diff --name-only origin/main...HEAD -- $globs)"
if ! printf '%s\n' "$files" | grep -vE "$plan_paths" | grep -qvxF -- "$mapped"; then echo OWNED; exit 0; fi

# Every file a test case that only gains lines, or CHANGELOG.md
while read -r add del f; do
  if [ "$f" = CHANGELOG.md ]; then continue; fi
  printf '%s\n' "$f" | grep -qE "$chore_test" && [ "$del" = 0 ] || { echo OTHER; exit 0; }
done < <(git -C "$pr" diff --numstat origin/main...HEAD)

# None in main's risk map
[ -z "$mapped" ] || { echo OTHER; exit 0; }
echo CHORE
