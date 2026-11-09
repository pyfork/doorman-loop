#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-11-07
# Unit test for guards/templates/.github/scripts/text-only.sh on fixture
# repos (local, no network). Usage: bash guards/tests/text-only-test.sh
set -u
dir="$(cd "$(dirname "$0")/../templates/.github/scripts" && pwd)"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
pass=0; fail=0
ok() { pass=$((pass+1)); echo "PASS $1"; }
no() { fail=$((fail+1)); echo "FAIL $1"; }

new_main() {
  rm -rf "$tmp/main" "$tmp/pr"
  git init -q -b main "$tmp/main"; cd "$tmp/main" || exit 1
  git config user.email t@example.com; git config user.name t
  mkdir -p app docs-public/guard-data .github/workflows
  echo b > brief.md; echo r > docs-public/project-rules.md; echo m > docs-public/guard-data/risk-map.txt
  echo c > app/main.py; echo w > .github/workflows/ci.yml
  git add -A; git commit -qm base
  git clone -q "$tmp/main" "$tmp/pr"; cd "$tmp/pr" || exit 1
  git config user.email t@example.com; git config user.name t
}
want() { # want <TEXT|CODE> <name>
  git add -A; git commit -qm x --allow-empty
  local got; got="$(bash "$dir/text-only.sh" "$tmp/main" "$tmp/pr" 2>&1)"
  [ "$got" = "$1" ] && ok "$2" || no "$2 (want $1, got $got)"
}

new_main; echo more >> brief.md; want TEXT "T1 brief.md only: text"
new_main; echo more >> docs-public/project-rules.md; echo n > docs-public/new.md; want TEXT "T2 docs-public/ files: text"
new_main; echo more >> brief.md; echo more >> docs-public/project-rules.md; want TEXT "T3 brief.md and docs-public/: text"
new_main; echo more >> docs-public/guard-data/risk-map.txt; want CODE "T4 the risk map (guard-data): code"
new_main; mkdir -p docs-public/guard-data/locks; echo l > docs-public/guard-data/locks/x.lock; want CODE "T5 a new lock under guard-data: code"
new_main; echo more >> brief.md; echo c2 >> app/main.py; want CODE "T6 brief.md plus product code: code"
new_main; git mv app/main.py docs-public/main.py; want CODE "T7 code moved into docs-public/: the old path counts, code"
new_main; echo w2 >> .github/workflows/ci.yml; want CODE "T8 a workflow: code"
new_main; echo b > app/brief.md; want CODE "T9 brief.md in a subfolder: code"
new_main; mkdir docs-public-x; echo x > docs-public-x/a.md; want CODE "T10 a look-alike folder docs-public-x/: code"
new_main; want CODE "T11 no difference at all: code"
new_main; git rm -q brief.md; want TEXT "T12 brief.md deleted: text"
new_main; chmod +x docs-public/project-rules.md; want CODE "T13 only a mode change: no content difference, code"
new_main; echo more >> brief.md; git -C "$tmp/main" commit -q --allow-empty -m e; echo c3 >> "$tmp/main/app/main.py"; git -C "$tmp/main" commit -qam ahead; want CODE "T14 PR behind main (main changed code since): code"
new_main; echo 'x' > "docs-public/a b.md"; want TEXT "T15 a docs-public/ file name with a space: text"

echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
