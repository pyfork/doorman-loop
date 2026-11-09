#!/usr/bin/env bash
# kit-reviewer-Opus5.5-agent, 2026-11-01
# Unit test for guards/templates/.github/scripts/pr-lane.sh and
# owner-call.sh on fixture repos and review lists (local, no network).
# Usage: bash guards/tests/pr-lane-test.sh   (exit 0 = all pass)
set -u
dir="$(cd "$(dirname "$0")/../templates/.github/scripts" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1"; }

new_main() { # new_main [nomap]
  rm -rf "$tmp/remote.git" "$tmp/seed" "$tmp/main" "$tmp/pr"
  git init -q --bare -b main "$tmp/remote.git"
  git init -q -b main "$tmp/seed"; cd "$tmp/seed" || exit 1
  git config user.email t@example.com; git config user.name t
  mkdir -p plans tests app docs-public/guard-data
  echo p > plans/p.md; echo 'def test_a(): pass' > tests/test_a.py; echo h > tests/support.py
  echo c > app/count.py; echo m > migrations.txt; echo '# log' > CHANGELOG.md
  [ "${1:-}" = nomap ] || printf 'DATA    migrations.txt\nSHARED  tests/test_money.py\n' > docs-public/guard-data/risk-map.txt
  git add -A; git commit -qm base; git remote add origin "$tmp/remote.git"; git push -q origin main
  git clone -q "$tmp/remote.git" "$tmp/main"
  git clone -q "$tmp/remote.git" "$tmp/pr"; cd "$tmp/pr" || exit 1
  git config user.email t@example.com; git config user.name t; git checkout -q -b feat
}
lane() { # lane <want> <name>
  local got; got="$(bash "$dir/pr-lane.sh" "$tmp/main" "$tmp/pr" 2>&1)"
  [ "$got" = "$1" ] && ok "$2" || { no "$2 (want $1, got $got)"; }
}
commit() { git add -A; git commit -qm x; }

new_main; echo 'def test_b(): pass' >> tests/test_a.py; echo '- x' >> CHANGELOG.md; commit; lane CHORE "L1 lines added to a test case and CHANGELOG: chore"
new_main; echo 'def test_c(): pass' > tests/test_new.py; commit; lane CHORE "L2 a new test file: chore"
new_main; echo 'def test_a(): assert 1' > tests/test_a.py; commit; lane OTHER "L3 a test loses a line: not a chore"
new_main; echo h2 >> tests/support.py; commit; lane OTHER "L4 a test helper (support.py) changes: not a chore"
new_main; echo 'def test_m(): pass' > tests/test_money.py; commit; lane OWNED "L5 only a test file in the risk map: owned by the owner, not a chore"
new_main; echo 'def test_b(): pass' >> tests/test_a.py; echo c2 >> app/count.py; commit; lane OTHER "L6 a test plus product code: not a chore"
new_main nomap; echo 'def test_b(): pass' >> tests/test_a.py; commit; lane OTHER "L7 no risk map on main: nothing is a chore"
new_main; echo p2 >> plans/p.md; commit; lane PLAN "L8 plan paths only: plan"
new_main; echo p2 >> plans/p.md; echo c2 >> app/count.py; commit; lane OTHER "L9 a plan plus code (one-PR slice): other"
new_main; mkdir -p scripts; echo 'exit 0' > scripts/test.sh; commit; lane OTHER "L10 the test runner script: not a chore"
new_main; mkdir -p tests/unit; echo 'x' > tests/unit/conftest.py; commit; lane OTHER "L11 a new conftest.py: not a chore"
new_main; mkdir -p .github; printf 'DATA    migrations.txt\nSHARED  .github/**\n' > docs-public/guard-data/risk-map.txt; git add -A; git commit -qm map; git push -q origin feat:main; git fetch -q; rm -rf "$tmp/main"; git clone -q "$tmp/remote.git" "$tmp/main"
echo w > .github/ci.yml; commit; lane OWNED "L12 guard files only (all mapped): owned"
echo m2 >> migrations.txt; echo p2 >> plans/p.md; commit; lane OWNED "L13 mapped files plus a plan path: owned"
echo c2 >> app/count.py; commit; lane OTHER "L14 mapped files plus product code: other"
new_main; echo 'def test_b(): pass' >> tests/test_a.py; echo m2 >> migrations.txt; commit; lane OTHER "L15 a test plus a mapped file: other"

# owner-call.sh
call() { # call <want 0|1> <name> <lane> <reviews json> [labels]
  printf '%s' "$4" > "$tmp/r.json"; printf '%s' "${5:-}" > "$tmp/l.txt"
  local rc=0; bash "$dir/owner-call.sh" "$tmp/r.json" Owner abc "$3" "$tmp/l.txt" || rc=$?
  [ "$rc" = "$1" ] && ok "$2" || no "$2 (want exit $1, got $rc)"
}
r() { printf '{"user":{"login":"%s"},"state":"%s","commit_id":"%s","submitted_at":"%s"}' "$1" "$2" "$3" "$4"; }
call 0 "O1 owner approved the head commit of a plan PR" PLAN "[$(r owner APPROVED abc 2026-11-01T01)]"
call 1 "O2 owner approved an older commit" PLAN "[$(r owner APPROVED old 2026-11-01T01)]"
call 1 "O3 the agent approved, not the owner" PLAN "[$(r agent APPROVED abc 2026-11-01T01)]"
call 1 "O4 owner approved, then requested changes" PLAN "[$(r owner APPROVED abc 2026-11-01T01),$(r owner CHANGES_REQUESTED abc 2026-11-01T02)]"
call 0 "O5 a later comment doesn't undo an approval" PLAN "[$(r owner APPROVED abc 2026-11-01T01),$(r owner COMMENTED abc 2026-11-01T02)]"
call 1 "O6 an approval that was dismissed" PLAN "[$(r owner DISMISSED abc 2026-11-01T01)]"
call 1 "O7 owner approved a normal PR: not the owner's call" OTHER "[$(r owner APPROVED abc 2026-11-01T01)]"
call 0 "O8 owner approved a PR the review loop sent to them" OTHER "[$(r owner APPROVED abc 2026-11-01T01)]" "needs-owner"
call 1 "O9 no reviews" PLAN "[]"
call 0 "O10 owner approved a PR of owner-owned files only" OWNED "[$(r owner APPROVED abc 2026-11-01T01)]"

echo; echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
