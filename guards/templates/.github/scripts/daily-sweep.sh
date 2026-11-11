#!/usr/bin/env bash
# guard-builder-Opus5.5-agent
# Guard 4 daily sweep (AC-13 to AC-19). Writes a plain-words report to
# stdout, worst item first. Needs GH_TOKEN and GH_REPO. Optional:
# SINCE (ISO time, default 24 hours ago). Needs REVIEWER_APP_ID.
set -euo pipefail
repo="$GH_REPO"
since="${SINCE:-}"; [ -n "$since" ] || since="$(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-24H +%Y-%m-%dT%H:%M:%SZ)"
app="${REVIEWER_APP_ID:?Set the REVIEWER_APP_ID repository variable}"
guard_paths='^(\.github/|docs-public/|plans/|CODEOWNERS)'
# kit-keeper-Opus5.5-agent, 2026-10-13: a bypass merge that
# changed only these paths is a plan approval (feature, slice-plan, re-plan
# or closing retro PR), listed on its own line with its files
plan_paths='^(plans/|specs/|acceptance/|docs-public/retro-log\.md$|README-brief-amended\.md$|docs-public/guard-data/locks/)'
out="$(mktemp)"
section() { printf '\n### %s\n\n' "$1" >> "$out"; }
found=0

# 1. Guard settings changed (AC-18): live rules on main vs the recorded copy
live="$(gh api "repos/$repo/rules/branches/main" --jq '[.[] | {type, parameters}] | sort_by(.type)')"
if [ ! -f docs-public/guard-data/expected-protection.json ]; then
  found=1; section "⚠️ The protection on main is not recorded yet"
  echo "\`docs-public/guard-data/expected-protection.json\` is missing, so changes to the rules on main can't be spotted. Finish the setup checklist (step 11)." >> "$out"
elif ! diff <(printf '%s' "$live" | jq -S .) <(jq -S . docs-public/guard-data/expected-protection.json) > /dev/null; then
  found=1; section "⚠️ The protection on main has changed"
  echo "The rules GitHub applies to \`main\` no longer match the saved copy. Someone switched a guard off or changed it:" >> "$out"
  echo >> "$out"
  plain() { case "$1" in
    deletion) echo "Block deleting main" ;;
    non_fast_forward) echo "Block force pushes" ;;
    pull_request) echo "Require a pull request (with approval and code-owner review)" ;;
    required_status_checks) echo "Require the signed checks (slice-review, test-lock)" ;;
    *) echo "$1" ;;
  esac; }
  saved="$(jq -S . docs-public/guard-data/expected-protection.json)"; now="$(printf '%s' "$live" | jq -S .)"
  for t in $(printf '%s\n%s' "$saved" "$now" | jq -rs 'map(.[].type) | unique | .[]'); do
    was="$(printf '%s' "$saved" | jq -c --arg t "$t" '.[] | select(.type == $t)')"
    is="$(printf '%s' "$now" | jq -c --arg t "$t" '.[] | select(.type == $t)')"
    if [ -n "$was" ] && [ -z "$is" ]; then echo "- **Switched off:** $(plain "$t")" >> "$out"
    elif [ -z "$was" ] && [ -n "$is" ]; then echo "- **Added:** $(plain "$t")" >> "$out"
    elif [ "$was" != "$is" ]; then echo "- **Changed:** $(plain "$t")" >> "$out"; fi
  done
  { echo; echo "<details><summary>Technical detail</summary>"; echo; echo '```diff'
    diff <(printf '%s' "$saved") <(printf '%s' "$now") | head -60 || true
    echo '```'; echo "</details>"; } >> "$out"
fi

# guard-builder-Opus5.5-agent, 2026-10-20: the reviewer's secrets are safe
# only while the `reviewer` environment is limited to main. Widening it is a
# setting change no file shows, so check it here (AC-18).
if ! envcheck="$(bash .github/scripts/verify-install.sh environment 2>&1)"; then
  found=1; section "⚠️ The reviewer's environment has changed"
  echo "The \`reviewer\` environment holds the reviewer app's key and the Claude token. Only \`main\` may use it:" >> "$out"
  echo >> "$out"; printf '%s\n' "$envcheck" | grep '^PROBLEM' | sed 's/^PROBLEM  /- /' >> "$out"
fi

# guard-builder-Opus5.5-agent, 2026-11-10: on public repositories GitHub
# blocks pull_request_target unless an Actions policy allows it; a blocked
# run never starts, so the required checks it posts never arrive
nostart="$(gh api "repos/$repo/actions/runs?event=pull_request_target&created=>=$since&per_page=100" \
  --jq '[.workflow_runs[] | select(.conclusion == "startup_failure")] | group_by(.name) | .[] | "- `\(.[0].name)`: \(length) run(s), last \(.[0].created_at) (\(.[0].html_url))"' 2>&1)" || {
  found=1; section "⚠️ Couldn't check whether guard checks started"
  echo "Listing \`pull_request_target\` runs failed:" >> "$out"; echo >> "$out"; printf '%s\n' "$nostart" | head -3 | sed 's/^/- /' >> "$out"; nostart=""; }
if [ -n "$nostart" ]; then
  found=1; section "⚠️ Guard checks did not start"
  echo "These \`pull_request_target\` workflows failed to start, so their required checks never reached the PR. Open one run: if its error names the \`pull_request_target\` policy, add or fix the repository's Actions policy (Settings, Actions, Policies: Active, \`.github/workflows/*.yml\`, Restrict events with \`pull_request_target\` allowed). Any other error: a workflow file is broken." >> "$out"
  echo >> "$out"; printf '%s\n' "$nostart" >> "$out"
fi

# guard-builder-Opus5.5-agent, 2026-10-25: locked-checks runs only
# on the runtime the record on main names; a broken record stops it
if ! rtcheck="$(bash .github/scripts/verify-install.sh runtime 2>&1)"; then
  found=1; section "⚠️ The runtime record is missing or broken"
  echo "\`locked-checks\` reads the server's OS and language version from \`docs-public/guard-data/runtime.txt\` on main, and runs nothing without it:" >> "$out"
  echo >> "$out"; printf '%s\n' "$rtcheck" | grep '^PROBLEM' | sed 's/^PROBLEM  /- /' >> "$out"
fi

# kit-keeper-Opus5.5-agent, 2026-10-27: a broken risk map line
# makes every one-PR slice fail
if ! mapcheck="$(bash .github/scripts/verify-install.sh risk-map 2>&1)"; then
  found=1; section "⚠️ The risk map on main is broken"
  echo "\`test-lock\` reads \`docs-public/guard-data/risk-map.txt\` from main to decide which slices may be planned and built in one PR:" >> "$out"
  echo >> "$out"; printf '%s\n' "$mapcheck" | grep '^PROBLEM' | sed 's/^PROBLEM  /- /' >> "$out"
fi

# kit-keeper-Opus5.5-agent, 2026-09-28: the kit is private. Any kit file
# (docs/, CLAUDE*.md) tracked on main is public, and stays in history.
leaked="$(git ls-files -- docs ':(glob)**/CLAUDE*.md' | head -20)"
if [ -n "$leaked" ]; then
  found=1; section "⚠️ Private kit files are public on main"
  echo "These files belong to the private kit but are saved in this public repository. Deleting them is not enough: they stay in the history. Ask the agent for a history clean-up plan." >> "$out"
  echo >> "$out"; printf '%s\n' "$leaked" | sed 's/^/- `/; s/$/`/' >> "$out"
fi

# guard-builder-Opus5.5-agent, 2026-10-26:
# an advisory published after a lock merged; the PR's audit can't see it
scan=0; vulns="$(python3 -I .github/scripts/scan-locks.py)" || scan=$?
if [ "$scan" -eq 1 ]; then
  found=1; section "⚠️ Known vulnerabilities in main's locks"
  echo "OSV lists these for versions locked on main: an advisory published after the merge, or a lock that came in without the audit. Ask the agent for a slice that moves each to its fixed version (a security fix may skip the 7-day cooldown, named in the PR):" >> "$out"
  echo >> "$out"; printf '%s\n' "$vulns" >> "$out"
elif [ "$scan" -ne 0 ]; then
  found=1; section "⚠️ The re-scan of main's locks couldn't run"
  echo "Today's check for newly published vulnerabilities didn't happen, so no news here is not good news:" >> "$out"
  echo >> "$out"; printf '%s\n' "${vulns:-- scan-locks.py stopped with exit $scan}" >> "$out"
fi

# 2. Anything merged without a PASS (AC-14), and guard files changed (AC-18)
nopass=""; approvals=""; guardchg=""; oneprs=""; owned=""
for pr in $(gh api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=50" \
    --jq ".[] | select(.merged_at != null and .merged_at >= \"$since\") | .number"); do
  sha="$(gh api "repos/$repo/pulls/$pr" --jq .head.sha)"
  title="$(gh api "repos/$repo/pulls/$pr" --jq .title)"
  # kit-keeper-Opus5.5-agent, 2026-10-15: a PASS counts only
  # if it finished before the merge; a PASS posted after it is a bypass.
  merged="$(gh api "repos/$repo/pulls/$pr" --jq .merged_at)"
  missing=""
  for chk in slice-review test-lock; do
    ok="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=$chk" \
      --jq "[.check_runs[] | select(.app.id == $app and .conclusion == \"success\" and .completed_at <= \"$merged\")] | length")"
    [ "$ok" -gt 0 ] || missing="$missing $chk"
  done
  all="$(gh api "repos/$repo/pulls/$pr/files?per_page=100" --paginate --jq '.[].filename')"
  if [ -n "$missing" ] && [ -n "$all" ] && ! printf '%s\n' "$all" | grep -qvE "$plan_paths"; then
    approvals="$approvals- #$pr $title: $(printf '%s' "$all" | tr '\n' ' ')"$'\n'
    continue
  fi
  [ -z "$missing" ] || nopass="$nopass- #$pr $title (no PASS from:$missing)"$'\n'
  # kit-reviewer-Opus5.5-agent, 2026-11-01: a PASS the owner's
  # approval gave, listed so each one is seen
  n="$(gh api "repos/$repo/commits/$sha/check-runs?check_name=slice-review" \
    --jq "[.check_runs[] | select(.app.id == $app and .conclusion == \"success\" and (.output.title // \"\" | test(\"owner approved\")))] | length")"
  [ "$n" = 0 ] || owned="$owned- #$pr $title"$'\n'
  # kit-keeper-Opus5.5-agent, 2026-10-27: a PR that passed and
  # changed both plans and code is a one-PR slice. Listed on its own, its
  # plan files left out of "Guard files changed", so a project where no
  # slice is ever risky stands out
  if [ -z "$missing" ] && printf '%s\n' "$all" | grep -qE '^plans/' && printf '%s\n' "$all" | grep -qvE "$plan_paths"; then
    oneprs="$oneprs- #$pr $title"$'\n'
    all="$(printf '%s\n' "$all" | grep -vE "$plan_paths" || true)"
  fi
  files="$(printf '%s\n' "$all" | grep -E "$guard_paths" || true)"
  [ -z "$files" ] || guardchg="$guardchg- #$pr $title: $(printf '%s' "$files" | tr '\n' ' ')"$'\n'
done
# Commits that reached main without a PR at all
direct=""
for sha in $(gh api "repos/$repo/commits?sha=main&since=$since&per_page=100" --jq '.[].sha'); do
  n="$(gh api "repos/$repo/commits/$sha/pulls" --jq '[.[] | select(.merged_at != null)] | length')"
  [ "$n" -gt 0 ] || direct="$direct- \`${sha:0:7}\` $(gh api "repos/$repo/commits/$sha" --jq '.commit.message | split("\n")[0]')"$'\n'
done
if [ -n "$direct" ]; then found=1; section "⚠️ Changes that reached main without a pull request"; printf '%s' "$direct" >> "$out"; fi
if [ -n "$nopass" ]; then found=1; section "Merged without a PASS"; echo "These were merged although the reviewer or the test lock did not pass. Usually an owner bypass (guard, setup, proof or re-plan PRs). Check each one was meant." >> "$out"; echo >> "$out"; printf '%s' "$nopass" >> "$out"; fi
if [ -n "$guardchg" ]; then found=1; section "Guard files changed"; printf '%s' "$guardchg" >> "$out"; fi
if [ -n "$oneprs" ]; then found=1; section "One-PR slices merged (routine: plan and code in one PR, checked by the test lock)"; echo "Each passed the reviewer and the test lock. If no slice is ever risky, check the risk map still covers the data, sign-in and shared code." >> "$out"; echo >> "$out"; printf '%s' "$oneprs" >> "$out"; fi
if [ -n "$owned" ]; then found=1; section "Merged on your approval"; echo "Plan, guard, brief and needs-owner PRs your Approve turned green. Check each is one you meant." >> "$out"; echo >> "$out"; printf '%s' "$owned" >> "$out"; fi
if [ -n "$approvals" ]; then found=1; section "Plans bypass-merged (only plan files changed)"; echo "A plan is approved with an ordinary Approve; a bypass is break-glass. Check each is one you meant." >> "$out"; echo >> "$out"; printf '%s' "$approvals" >> "$out"; fi

# kit-reviewer-Opus5.5-agent, 2026-11-01: on Mondays (or
# WEEKLY=1), how often the owner was needed in the last 7 days, against the
# target (a share of PRs: the pace varies), and one PR that merged itself
# for the Lead's weekly read
# shortcut: reads the last 100 closed PRs; past 100 merges a week, add --paginate
owner="${GUARD_OWNER_LOGIN:-}"
if [ -n "$owner" ] && { [ "$(date -u +%u)" = 1 ] || [ "${WEEKLY:-}" = 1 ]; }; then
  week="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)"
  merged=0; touched=""; selfs=""
  for pr in $(gh api "repos/$repo/pulls?state=closed&sort=updated&direction=desc&per_page=100" \
      --jq ".[] | select(.merged_at != null and .merged_at >= \"$week\") | .number"); do
    merged=$((merged + 1))
    by="$(gh api "repos/$repo/pulls/$pr" --jq '.merged_by.login // ""')"
    appr="$(gh api "repos/$repo/pulls/$pr/reviews" --paginate --jq "[.[] | select((.user.login | ascii_downcase) == (\"$owner\" | ascii_downcase) and .state == \"APPROVED\")] | length" | awk '{s += $1} END {print s + 0}')"
    if [ "$(printf '%s' "$by" | tr '[:upper:]' '[:lower:]')" = "$(printf '%s' "$owner" | tr '[:upper:]' '[:lower:]')" ] || [ "$appr" != 0 ]; then
      touched="$touched #$pr"
    else selfs="$selfs $pr"; fi
  done
  need="$(printf '%s' "$touched" | wc -w | tr -d ' ')"
  found=1; section "This week: how often you were needed"
  echo "- $merged PRs merged; $((merged - need)) merged themselves; $need needed you${touched:+ ($touched )}." >> "$out"
  share=0; [ "$merged" -eq 0 ] || share=$((need * 100 / merged))
  over=""; [ "$share" -lt 25 ] || over=" **Over the target.**"
  echo "- You were needed on $share% of PRs. Target: under 25%, each one data, sign-in, legal text, deploy, guards, the brief or a plan.$over Two weeks over it: revisit the risk map and the second approver." >> "$out"
  # shellcheck disable=SC2086
  [ -z "$selfs" ] || echo "- Sample for the Lead's weekly read: #$(printf '%s\n' $selfs | shuf -n 1 2>/dev/null || printf '%s\n' $selfs | head -1)" >> "$out"
fi

# Open guard-breach issues from the tripwire
breach="$(gh api "repos/$repo/issues?labels=guard-breach&state=open&per_page=50" --jq '.[] | "- #\(.number) \(.title)"')"
if [ -n "$breach" ]; then found=1; section "Open guard-breach alerts"; printf '%s\n' "$breach" >> "$out"; fi

# Open PRs older than three days
cutoff="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-3d +%Y-%m-%dT%H:%M:%SZ)"
stale="$(gh api "repos/$repo/pulls?state=open&sort=created&direction=asc&per_page=100" \
  --jq ".[] | select(.created_at < \"$cutoff\") | \"- #\\(.number) \\(.title) (open since \\(.created_at[:10]))\"")"
if [ -n "$stale" ]; then found=1; section "Pull requests open more than three days (oldest first)"; printf '%s\n' "$stale" >> "$out"; fi

# 3. Questions waiting on the owner, oldest first (AC-15)
waiting="$(gh api "repos/$repo/issues?labels=waiting-on-owner&state=open&sort=created&direction=asc&per_page=50" \
  --jq '.[] | "- #\(.number) \(.title) (waiting since \(.created_at[:10]))"')"
if [ -n "$waiting" ]; then found=1; section "Questions waiting on you (oldest first)"; printf '%s\n' "$waiting" >> "$out"; fi

# 4. Off-switches (flags) whose removal isn't confirmed (AC-16)
flags=""
for plan in plans/*.md; do
  [ -f "$plan" ] || continue
  while IFS= read -r line; do
    val="$(printf '%s' "$line" | sed -E 's/.*\*\*Flags:\*\*[[:space:]]*//')"
    case "$(printf '%s' "$val" | tr '[:upper:]' '[:lower:]')" in none|none.|"none "*|"none,"*|"none("*|"") ;; *) flags="$flags- $plan: $val"$'\n' ;; esac
  done < <(grep -E '\*\*Flags:\*\*' "$plan" || true)
done
if [ -n "$flags" ]; then found=1; section "Off-switches still in plans"; echo "Each needs its removal slice merged." >> "$out"; echo >> "$out"; printf '%s' "$flags" >> "$out"; fi

# 5. Costly machines (AC-17): not set up yet
machines_note="Costly machine check: not set up yet (deferred; see Known limits in the kit README)."

if [ "$found" -eq 0 ]; then
  echo "Nothing to report since $since. $machines_note"
else
  echo "Daily sweep since $since, worst first."
  cat "$out"
  printf '\n---\n%s\n' "$machines_note"
fi
