#!/usr/bin/env bash
# guard-builder-Opus5.5-agent
# Guard 3 test lock (AC-9, AC-10). Usage: test-lock.sh <main-dir> <pr-dir>
# Plans and lock files are read from main; check files from the PR. Prints
# one line per problem and exits 1 if there are any.
set -u
main="$1"; pr="$2"; problems=0
say() { echo "$1"; problems=$((problems + 1)); }
sum() { if command -v sha256sum >/dev/null; then sha256sum "$1" | awk '{print $1}'; else shasum -a 256 "$1" | awk '{print $1}'; fi; }

for plan in "$main"/plans/*.md; do
  [ -f "$plan" ] || continue
  name="$(basename "$plan" .md)"
  locked="$(grep -oE '^[[:space:]]*LOCKED: [^[:space:]]+' "$plan" | awk '{print $2}' | sort -u)"
  [ -n "$locked" ] || continue
  lock="$main/docs-public/guard-data/locks/$name.lock"
  if [ ! -f "$lock" ]; then say "NO LOCK FILE: plans/$name.md has locked checks but docs-public/guard-data/locks/$name.lock is missing on main"; continue; fi
  for c in $locked; do
    grep -qE "[[:space:]]$c\$" "$lock" || say "NOT IN LOCK: $c is locked in plans/$name.md but has no fingerprint"
  done
  while read -r want path; do
    [ -n "${want:-}" ] || continue
    printf '%s\n' "$locked" | grep -qxF "$path" || { say "UNKNOWN CHECK: docs-public/guard-data/locks/$name.lock names $path, which plans/$name.md does not lock"; continue; }
    if [ ! -f "$pr/$path" ]; then say "DELETED: $path (locked by plans/$name.md)"; continue; fi
    got="$(sum "$pr/$path")"
    [ "$got" = "$want" ] || say "CHANGED: $path (locked by plans/$name.md; fingerprint ${want:0:12}… is now ${got:0:12}…)"
  done < "$lock"
done

# kit-keeper-Opus5.5-agent, 2026-10-27: a routine slice may be
# planned and built in one PR. Its first commit, the plan commit, holds
# only plan paths; plans and locks only grow; it adds one slice whose risk
# class is none; it touches no path in main's risk map; its checks don't
# change after the plan commit; and each new lock line is the plan
# commit's file. With no risk map on main, every slice is risky: plans
# change only in a plan PR, as before.
plan_paths='^(specs/|plans/|acceptance/|docs-public/guard-data/locks/|docs-public/retro-log\.md$|README-brief-amended\.md$)'
g() { git -C "$pr" "$@"; }
sum_blob() { if command -v sha256sum >/dev/null; then g show "$1" | sha256sum | awk '{print $1}'; else g show "$1" | shasum -a 256 | awk '{print $1}'; fi; }

one_pr_slice() { # <base> <map>
  local base="$1" map="$2" first n f c want path got cls glob rest line hit
  # The risk map: one class and one pathspec glob per line
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    case "$line" in ''|'#'*) continue ;; esac
    read -r cls glob rest <<< "$line"
    case "$cls" in DATA|ACCESS|SHARED) ;; *) say "RISK MAP: line $n of docs-public/guard-data/risk-map.txt is not '<DATA|ACCESS|SHARED> <path glob>': $line"; continue ;; esac
    if [ -z "${glob:-}" ] || [ -n "${rest:-}" ]; then say "RISK MAP: line $n of docs-public/guard-data/risk-map.txt is not '<DATA|ACCESS|SHARED> <path glob>': $line"; continue; fi
    hit="$(g diff --name-only "$base" HEAD -- ":(glob)$glob")"
    for f in $hit; do say "RISKY PATH: $f is $cls in the risk map ($glob). Plan it as a risky slice, in its own plan PR"; done
  done < "$map"

  first="$(g rev-list --reverse --first-parent "$base..HEAD" | head -1)"
  for f in $(g diff --name-only "$first^" "$first"); do
    printf '%s\n' "$f" | grep -qE "$plan_paths" || say "PLAN COMMIT: ${first:0:7}, the PR's first commit, also changes $f. It holds only plans, checks, locks and the slice brief; the code comes after it"
  done
  [ -n "$(g diff --name-only "$first^" "$first" -- plans)" ] || say "PLAN COMMIT: ${first:0:7}, the PR's first commit, adds no slice to plans/. The plan comes first"

  while read -r add del f; do
    [ "${del:-0}" = 0 ] || say "PLAN CHANGE: $f loses or changes $del line(s). A one-PR slice only adds; changing a plan or lock is a re-plan, with the owner's bypass"
  done < <(g diff --numstat "$base" HEAD -- plans docs-public/guard-data/locks)

  local added slices risk
  added="$(g diff -U0 "$base" HEAD -- plans | grep -E '^\+' | grep -vE '^\+\+\+ ' || true)"
  slices="$(printf '%s\n' "$added" | grep -cE '^\+## Slice ' || true)"
  if [ "$slices" != 1 ]; then
    say "NOT ROUTINE: the PR adds $slices slice sections to plans/. A one-PR slice adds exactly one"
  else
    risk="$(printf '%s\n' "$added" | grep -E '^\+- \*\*Risk class:\*\*' | head -1 | sed -E 's/^\+- \*\*Risk class:\*\*[[:space:]]*//')"
    case "$risk" in none|none[[:space:].,\;]*) ;; *) say "NOT ROUTINE: the new slice's risk class is '${risk:-missing}'. Only a slice with risk class none is planned and built in one PR" ;; esac
  fi

  for f in $(g diff --name-only "$first" HEAD -- acceptance plans docs-public/guard-data/locks); do
    say "CHECKS EDITED: $f changed after the plan commit ${first:0:7}. A check is fixed once it is planned; changing it is a re-plan"
  done

  # New lock lines are the plan commit's files; each new LOCKED line has one
  while read -r want path; do
    if ! g cat-file -e "$first:$path" 2>/dev/null; then say "LOCK MISMATCH: $path has a new lock line but is not in the plan commit ${first:0:7}"; continue; fi
    got="$(sum_blob "$first:$path")"
    [ "$got" = "$want" ] || say "LOCK MISMATCH: $path's new lock line says ${want:0:12}…, its file in the plan commit is ${got:0:12}…"
  done < <(g diff -U0 "$base" HEAD -- docs-public/guard-data/locks | grep -E '^\+[0-9a-f]{64} ' | sed 's/^+//')
  for plan in "$pr"/plans/*.md; do
    [ -f "$plan" ] || continue
    local name; name="$(basename "$plan" .md)"
    for c in $(g diff -U0 "$base" HEAD -- "plans/$name.md" | grep -oE '^\+[[:space:]]*LOCKED: [^[:space:]]+' | awk '{print $NF}' | sort -u); do
      grep -qE "^\+[0-9a-f]{64}[[:space:]]+$c\$" <(g diff -U0 "$base" HEAD -- "docs-public/guard-data/locks/$name.lock") \
        || say "NOT IN LOCK: $c is newly locked in plans/$name.md but has no new line in docs-public/guard-data/locks/$name.lock"
    done
  done
  [ "$problems" -ne 0 ] || echo "One-PR slice: plan commit ${first:0:7}, risk class none, no path in the risk map, checks unchanged since."
}

if [ -d "$pr/.git" ]; then
  base="$(g merge-base origin/main HEAD 2>/dev/null || true)"
  changed="$(g diff --name-only origin/main...HEAD -- plans docs-public/guard-data/locks 2>/dev/null || true)"
  if [ -n "$changed" ]; then
    other="$(g diff --name-only origin/main...HEAD 2>/dev/null | grep -vE "$plan_paths" || true)"
    map="$main/docs-public/guard-data/risk-map.txt"
    if [ -n "$other" ] && [ -f "$map" ] && [ -n "$base" ]; then
      one_pr_slice "$base" "$map"
    else
      # A plan PR, or no risk map on main. Changing plans or locks is a
      # re-plan: a plan PR the owner approves and merges with the admin
      # bypass (AC-11, AC-12)
      why=""; [ -n "$other" ] && [ ! -f "$map" ] && why=" (no risk map on main, so every slice has its own plan PR)"
      for f in $changed; do say "PLAN CHANGE: $f. Re-plans need the owner's approval and merge with the admin bypass$why"; done
    fi
  fi
fi

# guard-builder-Opus5.5-agent, 2026-10-28: with a map on main,
# a new file whose path names a risky thing (pay, credit, ledger, auth,
# notice, terms, deploy) must sit under a mapped path. Otherwise CODEOWNERS
# doesn't hold it for the owner and a routine PR could auto-merge it. Plan
# paths are exempt: they are the plan, not the thing.
risky_words='pay|credit|ledger|auth|notice|terms|deploy'
map="$main/docs-public/guard-data/risk-map.txt"
if [ -d "$pr/.git" ] && [ -f "$map" ]; then
  globs="$(grep -vE '^[[:space:]]*(#|$)' "$map" | awk '{print ":(glob)" $2}')"
  for f in $(g diff --name-only --diff-filter=A origin/main...HEAD 2>/dev/null | grep -iE "$risky_words" | grep -vE "$plan_paths" || true); do
    # shellcheck disable=SC2086
    [ -n "$globs" ] && [ -n "$(g ls-files -- $globs 2>/dev/null | grep -Fx -- "$f")" ] && continue
    say "RISKY NAME: $f is new and its path names a risky thing ($(printf '%s' "$f" | grep -ioE "$risky_words" | head -1)), but no line of main's risk map covers it. Add its path to the map in a plan PR the owner merges, or rename it if it isn't risky"
  done
fi

[ "$problems" -eq 0 ] && echo "All locked checks match their fingerprints on main."
[ "$problems" -eq 0 ]
