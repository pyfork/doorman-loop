#!/usr/bin/env bash
# guard-builder-Sonnet5-agent
# PreToolUse hook for Bash: blocks the agent from merging into main,
# pushing to main, or editing this guard's own files. Part of Guard 1B.
# On Path A it is an optional early warning; GitHub does the real blocking.
set -euo pipefail

input="$(cat)"
command="$(printf '%s' "$input" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tool_input",{}).get("command",""))' 2>/dev/null || true)"

deny() {
  printf '%s\n' "$1" >&2
  exit 2
}

# Block pushing straight to main
# guard-builder-Opus5.5-agent: rewritten without (?!...), which macOS grep -E
# can't parse. Looks only at the text of each `git push` segment.
while IFS= read -r push_seg; do
  [ -n "$push_seg" ] || continue
  # Any refspec naming main as the target: main, :main, HEAD:main, +main,
  # refs/heads/main
  if printf '%s' "$push_seg" | grep -Eq '(^|[[:space:]:+])(refs/heads/)?main([[:space:]]|$)' \
     || printf '%s' "$push_seg" | grep -Eq '[[:space:]]--(all|mirror)([[:space:]]|$)'; then
    deny "Guard 1B: agent sessions never push to main directly. Open a PR instead."
  fi
  # Bare `git push` / `git push origin` / `git push origin HEAD` while main
  # is checked out also pushes main
  current_branch="$(git -C "${CLAUDE_PROJECT_DIR:-.}" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
  if [ "$current_branch" = "main" ]; then
    read -ra words <<< "${push_seg#*push}"
    args=()
    for word in ${words[@]+"${words[@]}"}; do
      case "$word" in -*) ;; *) args+=("$word") ;; esac
    done
    if [ "${#args[@]}" -lt 2 ] || [ "${args[1]}" = "HEAD" ]; then
      deny "Guard 1B: main is checked out, so this push would update main. Push a branch and open a PR instead."
    fi
  fi
done <<< "$(printf '%s' "$command" | grep -Eo 'git[[:space:]]+push[^;&|]*' || true)"

# Block local merges into main
if printf '%s' "$command" | grep -Eq 'git[[:space:]]+merge'; then
  deny "Guard 1B: agent sessions never merge locally. The owner merges, after the slice-review check passes."
fi

# Block merging a PR via gh. The one exception is turning on auto-merge
#: `gh pr merge <n> --auto`, never with --admin. GitHub then merges
# a routine PR only once every required check is green, and holds a PR on a
# risk-map path for the owner's approval (CODEOWNERS), so the agent still
# never merges anything itself.
# kit-keeper-Opus5.5-agent, 2026-10-29
while IFS= read -r merge_seg; do
  [ -n "$merge_seg" ] || continue
  if printf '%s' "$merge_seg" | grep -Eq '[[:space:]]--admin([[:space:]=]|$)' \
     || ! printf '%s' "$merge_seg" | grep -Eq '[[:space:]]--auto([[:space:]]|$)'; then
    deny "Guard 1B: agent sessions never merge PRs. Turn on auto-merge instead (gh pr merge <n> --auto --squash); the owner merges risky PRs."
  fi
done <<< "$(printf '%s' "$command" | grep -Eo 'gh[[:space:]]+pr[[:space:]]+merge[^;&|]*' || true)"

# Block editing the hook or its settings without owner approval this session
guard_path_re='\.claude/(settings\.json|hooks/block-merge\.sh)'
word_start='(^|[^[:alnum:]_.-])'
if printf '%s' "$command" | grep -Eq "$guard_path_re"; then
  # Redirect (>, >>, >|) whose target is a guard file, allowing quotes and a
  # path prefix such as ./ or "$PWD/"
  if printf '%s' "$command" | grep -Eq ">[>|]?[[:space:]]*[\"']?[^[:space:];&|]*$guard_path_re" \
     || printf '%s' "$command" | grep -Eq "${word_start}(rm|mv|cp)[[:space:]].*$guard_path_re" \
     || printf '%s' "$command" | grep -Eq "${word_start}tee[[:space:]].*$guard_path_re" \
     || printf '%s' "$command" | grep -Eq "${word_start}sed[[:space:]](.*[[:space:]])?(-[[:alnum:]]*i|--in-place).*$guard_path_re"; then
    deny "Guard 1B: editing the guard hook or its settings needs the owner's explicit approval in this session first."
  fi
fi

exit 0
