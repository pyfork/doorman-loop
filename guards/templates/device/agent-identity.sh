#!/usr/bin/env bash
# guard-builder-Opus5.5-agent
# PreToolUse hook for Bash, installed once per device in ~/.claude/settings.json
# so it runs in every agent session on the device and never for a human.
# Agent commits carry the agent login set by the owner in
# ~/.claude/agent-identity (one line: email = <address>), whatever the
# repository, worktree or device git config says. Refused:
#   - identity overrides in the command: --author, -c user.*/author.*/committer.*,
#     GIT_AUTHOR_* / GIT_COMMITTER_* / EMAIL= assignments;
#   - git config writes to user.name / user.email (any scope);
#   - a commit-making git command (commit, merge, revert, cherry-pick, rebase,
#     am, pull) whose resolved author or committer email is not the agent login;
#   - shell edits to the identity file, this hook or the device settings.
# A missing or empty identity file refuses every commit-making command.
set -euo pipefail

input="$(cat)"
id_file="${AGENT_IDENTITY_FILE:-$HOME/.claude/agent-identity}"

deny() {
  printf '%s\n' "$1" >&2
  exit 2
}

# A function, not $(... <<heredoc), which bash 3.2 misparses
check() {
  INPUT="$input" ID_FILE="$id_file" python3 - <<'PY'
import json, os, re, shlex, subprocess

try:
    data = json.loads(os.environ["INPUT"])
except Exception:
    raise SystemExit(0)
cmd = (data.get("tool_input") or {}).get("command") or ""
cwd = data.get("cwd") or os.getcwd()
id_file = os.environ["ID_FILE"]

def out(m):
    print(m)
    raise SystemExit(0)

# Shell edits to the guard's own files
guard = r"\.claude/(agent-identity|hooks/agent-identity\.sh|settings\.json)"
if re.search(guard, cmd) and (
    re.search(r">[>|]?\s*[\"']?[^\s;&|]*" + guard, cmd)
    or re.search(r"(^|[^\w.-])(rm|mv|cp|tee|ln|chmod|truncate)\s.*" + guard, cmd)
    or re.search(r"(^|[^\w.-])sed\s(.*\s)?(-\w*i|--in-place).*" + guard, cmd)
):
    out("Agent identity guard: editing the identity file, this hook or the device settings needs the owner.")

# Identity overrides written into the command itself
if re.search(r"(^|[\s;&|(])(GIT_(AUTHOR|COMMITTER)_(NAME|EMAIL)|EMAIL)=", cmd):
    out("Agent identity guard: no GIT_AUTHOR_*, GIT_COMMITTER_* or EMAIL= in agent commands; commits use the agent login.")
if re.search(r"(^|[\s;&|(])git\b[^;&|]*\s-c\s*['\"]?(user|author|committer)\.(name|email)=", cmd):
    out("Agent identity guard: no -c user/author/committer overrides; commits use the agent login.")
if re.search(r"(^|[\s;&|(])git\b[^;&|]*\s--author([=\s]|$)", cmd):
    out("Agent identity guard: no --author; commits use the agent login.")

# Split into simple commands, tracking cd so each git call knows its folder
segments = re.split(r"&&|\|\||;|\||\n", cmd)
here = cwd
makes = {"commit", "merge", "revert", "cherry-pick", "rebase", "am", "pull"}
check_dirs = []
for seg in segments:
    try:
        w = shlex.split(seg)
    except ValueError:
        w = seg.split()
    w = [x for x in w if x not in ("(", ")", "{", "}")]
    if not w:
        continue
    if w[0] == "cd" and len(w) > 1:
        here = os.path.normpath(os.path.join(here, os.path.expanduser(w[1])))
        continue
    if os.path.basename(w[0]) != "git":
        continue
    i, gdir = 1, here
    while i < len(w) and w[i].startswith("-"):
        if w[i] == "-C" and i + 1 < len(w):
            gdir = os.path.normpath(os.path.join(gdir, os.path.expanduser(w[i + 1])))
            i += 2
        elif w[i] in ("-c", "--git-dir", "--work-tree", "--namespace"):
            i += 2
        else:
            i += 1
    if i >= len(w):
        continue
    sub, rest = w[i], w[i + 1:]
    if sub == "config":
        # A write is a key followed by a value; reads (--get, --list, key only) and --unset pass
        if any(a.startswith("--unset") or a in ("--get", "--get-all", "--list", "-l") for a in rest):
            continue
        args = [a for a in rest if not a.startswith("-")]
        if args and re.fullmatch(r"(user|author|committer)\.(name|email)", args[0], re.I) and len(args) > 1:
            out("Agent identity guard: agents never set git user.name or user.email; the owner sets the device identity.")
    elif sub in makes:
        check_dirs.append(gdir)

if not check_dirs:
    raise SystemExit(0)

want = ""
try:
    for line in open(id_file):
        m = re.match(r"\s*email\s*=\s*(\S+)", line)
        if m:
            want = m.group(1).lower()
except OSError:
    pass
if not want:
    out(f"Agent identity guard: {id_file} is missing or has no 'email = <address>' line, so agent commits are refused. The owner creates it.")

for d in check_dirs:
    if not os.path.isdir(d):
        d = cwd
    for var in ("GIT_AUTHOR_IDENT", "GIT_COMMITTER_IDENT"):
        r = subprocess.run(["git", "-C", d, "var", var], capture_output=True, text=True)
        m = re.search(r"<([^>]*)>", r.stdout)
        got = m.group(1).lower() if m else ""
        if got != want:
            out(f"Agent identity guard: in {d} git would commit as <{got or 'unset'}>, not the agent login <{want}>. Remove the repository or worktree override (git config --unset user.email), or ask the owner to fix the device identity.")
PY
}

msg="$(check)"
[ -z "$msg" ] || deny "$msg"
exit 0
