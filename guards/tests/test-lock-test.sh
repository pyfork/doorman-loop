#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-10-27
# Unit test for guards/templates/.github/scripts/test-lock.sh on fixture
# repos (local, no network): the fingerprint checks, plan PRs, and one-PR
# slices with and without a risk map on main.
# Usage: bash guards/tests/test-lock-test.sh   (exit 0 = all pass)
set -u
script="$(cd "$(dirname "$0")/../templates/.github/scripts" && pwd)/test-lock.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
sha() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

slice() { # slice <n> <risk> <check path>: a plan section in the template's format
  printf '\n## Slice %s\n- **Statement:** s%s\n- **Risk class:** %s\n- **Locked checks:** happy path\n  LOCKED: %s\n' "$1" "$1" "$2" "$3"
}
new_main() { # new_main [map]: main with slice 1 locked and built, and an optional risk map
  rm -rf "$tmp/remote.git" "$tmp/seed" "$tmp/main" "$tmp/pr"
  git init -q --bare -b main "$tmp/remote.git"
  git init -q -b main "$tmp/seed"; cd "$tmp/seed" || exit 1
  git config user.email t@example.com; git config user.name t
  mkdir -p plans acceptance app docs-public/guard-data/locks
  printf '# Plan: wc\n' > plans/wc-plan.md; slice 1 none acceptance/s1.sh >> plans/wc-plan.md
  echo 'exit 0' > acceptance/s1.sh; echo one > app/count.py; echo m > migrations.txt
  sha acceptance/s1.sh > docs-public/guard-data/locks/wc-plan.lock
  [ -z "${1:-}" ] || printf '# risk map\nDATA    migrations.txt\nACCESS  app/auth/**\n' > docs-public/guard-data/risk-map.txt
  git add -A; git commit -qm base; git remote add origin "$tmp/remote.git"; git push -q origin main
  git clone -q "$tmp/remote.git" "$tmp/main"
  git clone -q "$tmp/remote.git" "$tmp/pr"; cd "$tmp/pr" || exit 1
  git config user.email t@example.com; git config user.name t; git checkout -q -b feat
}
plan_commit() { # plan_commit [risk]: the plan commit of slice 2, checks and lock line only
  slice 2 "${1:-none}" acceptance/s2.sh >> plans/wc-plan.md
  echo 'exit 1' > acceptance/s2.sh; sha acceptance/s2.sh >> docs-public/guard-data/locks/wc-plan.lock
  git add -A; git commit -qm "plan slice 2"
}
code_commit() { echo two >> app/count.py; git add -A; git commit -qm "build slice 2"; }
expect() { # expect <ok|LINE PREFIX> <name>
  local out rc=0
  out="$(bash "$script" "$tmp/main" "$tmp/pr" 2>&1)" || rc=$?
  if { [ "$1" = ok ] && [ "$rc" -eq 0 ]; } || { [ "$1" != ok ] && [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -q "^$1"; }; then
    pass=$((pass+1)); echo "PASS $2"
  else
    fail=$((fail+1)); echo "FAIL $2 (want $1, exit $rc)"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

# Unchanged behaviour
new_main; echo x >> app/count.py; git commit -qam x; expect ok "T1 a build PR with no plan change passes"
new_main; echo 'exit 0 # weaker' > acceptance/s1.sh; git commit -qam x; expect "CHANGED: acceptance/s1.sh" "T2 a locked check changed"
new_main; git rm -q acceptance/s1.sh; git commit -qm x; expect "DELETED: acceptance/s1.sh" "T3 a locked check deleted"
new_main map; plan_commit; expect "PLAN CHANGE: plans/wc-plan.md" "T4 a plan PR (plan paths only) is a re-plan, map or not"
new_main; plan_commit; code_commit; expect "PLAN CHANGE: plans/wc-plan.md. Re-plans need the owner's approval and merge with the admin bypass (no risk map" "T5 no risk map on main: a one-PR slice is a plan change"

# One-PR slices, with a risk map on main
new_main map; plan_commit; code_commit; expect ok "T6 a routine one-PR slice passes"
new_main map; plan_commit; code_commit; git checkout -q main; git pull -q; cd "$tmp/seed" && echo y > other.txt && git add -A && git commit -qm y && git push -q origin main; cd "$tmp/pr" && git fetch -q && git checkout -q feat && git merge -q --no-edit origin/main; rm -rf "$tmp/main" && git clone -q "$tmp/remote.git" "$tmp/main"
expect ok "T7 main merged into the branch: the plan commit is still found"
new_main map; slice 2 none acceptance/s2.sh >> plans/wc-plan.md; echo 'exit 1' > acceptance/s2.sh; sha acceptance/s2.sh >> docs-public/guard-data/locks/wc-plan.lock; echo two >> app/count.py; git add -A; git commit -qm "plan and code"
expect "PLAN COMMIT: " "T8 product code in the plan commit"
new_main map; code_commit; plan_commit; expect "PLAN COMMIT: " "T9 code first, plan after"
new_main map; plan_commit DATA; code_commit; expect "NOT ROUTINE: the new slice's risk class is 'DATA'" "T10 a DATA slice in one PR"
new_main map; slice 2 none acceptance/s2.sh >> plans/wc-plan.md; sed -i.bak '/Risk class/d' plans/wc-plan.md; rm plans/wc-plan.md.bak; git checkout -q plans; slice 2 none acceptance/s2.sh | grep -v 'Risk class' >> plans/wc-plan.md; echo 'exit 1' > acceptance/s2.sh; sha acceptance/s2.sh >> docs-public/guard-data/locks/wc-plan.lock; git add -A; git commit -qm plan; code_commit
expect "NOT ROUTINE: the new slice's risk class is 'missing'" "T11 no risk class line: not routine"
new_main map; slice 3 none acceptance/s3.sh >> plans/wc-plan.md; plan_commit; code_commit; expect "NOT ROUTINE: the PR adds 2 slice sections" "T12 two slices in one PR"
new_main map; plan_commit; echo m2 >> migrations.txt; git commit -qam x; expect "RISKY PATH: migrations.txt is DATA" "T13 a mapped file touched"
new_main map; plan_commit; mkdir -p app/auth; echo s > app/auth/login.py; git add -A; git commit -qm x; expect "RISKY PATH: app/auth/login.py is ACCESS" "T14 a mapped glob touched"
new_main map; plan_commit; code_commit; echo 'exit 0' > acceptance/s2.sh; git commit -qam weaken; expect "CHECKS EDITED: acceptance/s2.sh" "T15 a new check weakened after the plan commit"
new_main map; slice 2 none acceptance/s2.sh >> plans/wc-plan.md; echo 'exit 1' > acceptance/s2.sh; echo "$(printf '0%.0s' $(seq 64))  acceptance/s2.sh" >> docs-public/guard-data/locks/wc-plan.lock; git add -A; git commit -qm plan; code_commit
expect "LOCK MISMATCH: acceptance/s2.sh" "T16 a new lock line that isn't the file"
new_main map; slice 2 none acceptance/s2.sh >> plans/wc-plan.md; echo 'exit 1' > acceptance/s2.sh; git add -A; git commit -qm plan; code_commit
expect "NOT IN LOCK: acceptance/s2.sh is newly locked" "T17 a new LOCKED line with no lock line"
new_main map; sed -i.bak 's/^- \*\*Statement:\*\* s1$/- **Statement:** s1, reworded/' plans/wc-plan.md; rm plans/wc-plan.md.bak; plan_commit; code_commit
expect "PLAN CHANGE: plans/wc-plan.md loses or changes 1 line" "T18 an existing slice section changed in the plan commit"
new_main map; cd "$tmp/seed" && echo 'DATA' >> docs-public/guard-data/risk-map.txt && git commit -qam badmap && git push -q origin main; rm -rf "$tmp/main" "$tmp/pr"; git clone -q "$tmp/remote.git" "$tmp/main"; git clone -q "$tmp/remote.git" "$tmp/pr"; cd "$tmp/pr" && git config user.email t@example.com && git config user.name t && git checkout -q -b feat; plan_commit; code_commit
expect "RISK MAP: line 4" "T19 a malformed risk map line fails closed"
new_main; printf 'DATA app/nothing\n' > docs-public/guard-data/risk-map.txt; plan_commit; code_commit
expect "PLAN CHANGE: plans/wc-plan.md. Re-plans need the owner's approval and merge with the admin bypass (no risk map" "T20 a risk map the PR adds itself doesn't count"

# guard-builder-Opus5.5-agent, 2026-10-28: risky names outside the map
new_main map; mkdir -p app/billing; echo p > app/billing/PayOut.py; git add -A; git commit -qm x; expect "RISKY NAME: app/billing/PayOut.py" "T21 a new file named for payments, unmapped"
new_main map; mkdir -p app/auth; echo s > app/auth/token.py; git add -A; git commit -qm x; expect ok "T22 a new auth file under a mapped path passes the name check"
new_main; mkdir -p app; echo d > app/deploy.sh; git add -A; git commit -qm x; expect ok "T23 no map on main: no name check (every slice is risky, CODEOWNERS is *)"
new_main map; plan_commit; code_commit; mkdir -p specs/features/payments; echo b > specs/features/payments/brief.md; git add -A; git commit -qm x; expect ok "T24 plan paths are exempt from the name check"

echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
