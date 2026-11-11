#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-10-29: unit test for the agent hook's merge
# rule: turning on auto-merge is allowed, every other merge refused.
set -uo pipefail
H="$(dirname "$0")/../templates/.claude/hooks/block-merge.sh"
fails=0
t() {
  printf '{"tool_input":{"command":"%s"}}' "$2" | bash "$H" > /dev/null 2>&1
  got=$?
  if [ "$got" = "$1" ]; then echo "ok   $got $2"; else echo "FAIL want $1 got $got: $2"; fails=$((fails + 1)); fi
}
t 0 "gh pr merge 5 --auto --squash"
t 0 "gh pr ready 5 && gh pr merge 5 --auto --squash"
t 0 "gh pr merge 5 --auto --merge"
t 2 "gh pr merge 5"
t 2 "gh pr merge 5 --merge"
t 2 "gh pr merge 5 --squash"
t 2 "gh pr merge 5 --auto --squash --admin"
t 2 "gh pr merge 5 --auto --merge --admin"
t 2 "gh pr merge 5 --admin --auto"
t 2 "gh pr merge 5 --auto --squash && gh pr merge 6 --squash"
t 2 "gh pr merge 5 --autox"
t 2 "git merge feature-x"
t 2 "git push origin main"
t 0 "git status"
[ "$fails" -eq 0 ] && echo "block-merge: all OK" || { echo "block-merge: $fails failed"; exit 1; }
