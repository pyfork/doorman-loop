#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-10-14
# Unit test for claude-pkg/TEMPLATE-pre-push on fixture repos (local, no
# network). Uses a made-up private string, never a real one.
# Usage: bash guards/tests/pre-push-test.sh   (exit 0 = all pass)
set -u
hook="$(cd "$(dirname "$0")/../hooks" && pwd)/pre-push"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
secret="Zebra-Notes-Fixture"
pass=0; fail=0

new_repo() { # fresh clone with the hook, a remote and a first pushed commit
  rm -rf "$tmp/remote.git" "$tmp/w"
  git init -q --bare "$tmp/remote.git"
  git init -q -b main "$tmp/w"
  cd "$tmp/w" || exit 1
  git config user.email t@example.com; git config user.name t
  git remote add origin "$tmp/remote.git"
  cp "$hook" .git/hooks/pre-push; chmod +x .git/hooks/pre-push
  mkdir -p .git/info; printf '# private strings\n%s\n' "$secret" > .git/info/private-strings
  echo base > a.txt; git add a.txt; git commit -qm base; git push -q origin main 2>/dev/null
}
expect() { # expect <refused|ok> <name>
  local out rc=0
  out="$(git push origin HEAD:main 2>&1)" || rc=$?
  local got=ok; [ "$rc" -ne 0 ] && got=refused
  if [ "$got" = "$1" ] && ! printf '%s' "$out" | grep -qiF "$secret"; then
    pass=$((pass+1)); echo "PASS $2"
  else
    fail=$((fail+1)); echo "FAIL $2 (want $1, got $got; or output repeated the string)"; printf '%s\n' "$out" | sed 's/^/    /'
  fi
}

new_repo; echo clean >> a.txt; git commit -qam "plain change"; expect ok "T1 clean commit pushes"
new_repo; echo "see ${secret}/projects" >> a.txt; git commit -qam "x"; expect refused "T2 string in added line"
new_repo; echo y >> a.txt; git commit -qam "notes in ${secret}"; expect refused "T3 string in commit message"
new_repo; echo y > "${secret}.md"; git add .; git commit -qm "x"; expect refused "T4 string in a new file name"
new_repo; echo "zebra-notes-fixture" >> a.txt; git commit -qam "x"; expect refused "T5 case-insensitive"
new_repo; echo "$secret" >> a.txt; git commit -qam "add"; sed -i.bak '$d' a.txt; rm a.txt.bak; git commit -qam "remove"; expect refused "T6 added then removed is still refused"
new_repo; git mv a.txt "${secret}.txt"; git commit -qm "x"; expect refused "T7 rename to a private name"
new_repo; rm .git/info/private-strings; echo y >> a.txt; git commit -qam "x"; expect refused "T8 missing list fails closed"
new_repo; : > .git/info/private-strings; echo "$secret" >> a.txt; git commit -qam "x"; expect ok "T9 empty list means no strings"
new_repo; echo "Zebra-Notes" >> a.txt; git commit -qam "x"; expect ok "T10 a part of the string is not a match"
new_repo; mkdir docs; echo k > docs/k.md; git add -f docs; git commit -qm "x"; expect refused "T11 kit file check still works"
new_repo; git checkout -q -b feat; echo "$secret" >> a.txt; git commit -qam "x"; out="$(git push origin feat 2>&1)"; rc=$?
if [ $rc -ne 0 ]; then pass=$((pass+1)); echo "PASS T12 new branch is checked"; else fail=$((fail+1)); echo "FAIL T12 new branch is checked"; fi

# kit-keeper-Opus5.5-agent, 2026-10-19: a linked worktree shares the main
# .git's hook and list (--git-common-dir); its own git dir has neither.
new_repo; git worktree add -q -b wt "$tmp/wt" 2>/dev/null; cd "$tmp/wt" || exit 1
echo clean >> a.txt; git commit -qam "plain change"; expect ok "T13 clean push from a worktree"
echo "$secret" >> a.txt; git commit -qam "x"; expect refused "T14 string pushed from a worktree"
cd "$tmp/w"; git worktree remove --force "$tmp/wt"

echo "Total: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
