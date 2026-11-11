#!/usr/bin/env bash
# guard-builder-Opus5.5-agent: unit test for the device hook agent-identity.sh.
# Builds a throwaway HOME with a device identity, an identity file and two
# repositories, then feeds the hook commands. 0 = allowed, 2 = refused.
set -uo pipefail
H="$(cd "$(dirname "$0")/../templates/device" && pwd)/agent-identity.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_NOSYSTEM=1
unset GIT_AUTHOR_NAME GIT_AUTHOR_EMAIL GIT_COMMITTER_NAME GIT_COMMITTER_EMAIL EMAIL AGENT_IDENTITY_FILE
mkdir -p "$HOME/.claude"
git config --global user.name agent
git config --global user.email agent@example.com
printf 'email = agent@example.com\n' > "$HOME/.claude/agent-identity"
git init -q "$T/good"
git init -q "$T/bad"; git -C "$T/bad" config user.email owner@example.com

fails=0
t() { # t <want> <cwd> <command>
  printf '%s' "$3" | python3 -c 'import json,sys; print(json.dumps({"cwd": sys.argv[1], "tool_input": {"command": sys.stdin.read()}}))' "$2" \
    | bash "$H" > /dev/null 2>&1
  got=$?
  if [ "$got" = "$1" ]; then echo "ok   $got $3"; else echo "FAIL want $1 got $got: $3"; fails=$((fails + 1)); fi
}
G="$T/good"; B="$T/bad"

t 0 "$G" "git status"
t 0 "$G" "git commit -m x"
t 0 "$G" "git add -A && git commit -qm 'x' && git push -u origin feat"
t 0 "$G" "git config user.email"
t 0 "$G" "git config --get user.email"
t 0 "$G" "git config --show-origin --get-all user.email"
t 0 "$B" "git config --unset user.email"
t 0 "$G" "ADMIN_EMAIL=a@b python3 app.py"
t 0 "$G" "bash scripts/test.sh"
t 2 "$B" "git commit -m x"
t 2 "$B" "git merge feat"
t 2 "$B" "git revert --no-edit HEAD"
t 2 "$B" "git cherry-pick abc"
t 2 "$B" "git rebase main"
t 2 "$B" "git pull"
t 2 "$G" "cd $B && git commit -m x"
t 2 "$G" "git -C $B commit -m x"
t 2 "$G" "git -c user.email=x@x commit -m x"
t 2 "$G" "git -c user.name=x -c user.email=x@x revert --no-edit HEAD"
t 2 "$G" "git commit --author='X <x@x>' -m x"
t 2 "$G" "git commit --author 'X <x@x>' -m x"
t 2 "$G" "GIT_AUTHOR_EMAIL=x@x git commit -m x"
t 2 "$G" "export GIT_COMMITTER_EMAIL=x@x; git commit -m x"
t 2 "$G" "EMAIL=x@x git commit -m x"
t 2 "$G" "git config user.email owner@example.com"
t 2 "$G" "git config --global user.email owner@example.com"
t 2 "$G" "git config --local user.name Owner"
t 2 "$G" "git -C $B config user.email owner@example.com"
t 2 "$G" "echo 'email = x@x' > ~/.claude/agent-identity"
t 2 "$G" "rm ~/.claude/agent-identity"
t 2 "$G" "sed -i '' 's/a/b/' ~/.claude/hooks/agent-identity.sh"
t 2 "$G" "cp x.json ~/.claude/settings.json"

# The device identity itself is wrong: commits are refused
git config --global user.email owner@example.com
t 2 "$G" "git commit -m x"
t 0 "$G" "git status"
git config --global user.email agent@example.com

# No identity file: fail closed for commits only
rm "$HOME/.claude/agent-identity"
t 2 "$G" "git commit -m x"
t 0 "$G" "git log --oneline -1"
printf '# no email line\n' > "$HOME/.claude/agent-identity"
t 2 "$G" "git commit -m x"

[ "$fails" -eq 0 ] && echo "agent-identity: all OK" || { echo "agent-identity: $fails failed"; exit 1; }
