#!/usr/bin/env bash
# guard-builder-Opus5.5-agent, 2026-10-20
# Install check: reads the GitHub settings the guards depend on and prints
# one line per setting, OK or PROBLEM. Exits 1 on any PROBLEM.
#
# Usage: verify-install.sh [section ...]   (default: every section)
#   files codeowners rules bypass environment variables secrets runtime risk-map
#   workflow-runs
# Needs GH_REPO (owner/name) and a gh login. Run it as the agent login at
# install (checklist step 12): a collaborator can read every section. The
# daily sweep runs only the sections its own token can read
# (environment, runtime, risk-map).
#
# What it can't see: the ruleset's bypass list itself (GitHub returns it
# only to a token that can change the ruleset). "bypass" checks the next
# best thing: the login running this script can never bypass.
set -uo pipefail
repo="${GH_REPO:?Set GH_REPO to owner/name}"
sections="${*:-files codeowners rules bypass environment variables secrets runtime risk-map workflow-runs}"
here="$(cd "$(dirname "$0")" && pwd)"
problems=0
ok()  { echo "OK       $1"; }
bad() { echo "PROBLEM  $1"; problems=$((problems + 1)); }
api() { gh api "repos/$repo/$1" 2>/dev/null; }
repo_var() { api "actions/variables/$1" | jq -r '.value // empty'; }

for s in $sections; do case "$s" in
files)
  for f in .github/workflows/slice-review.yml .github/workflows/test-lock.yml \
           .github/workflows/daily-sweep.yml .github/workflows/main-tripwire.yml \
           .github/scripts/test-lock.sh .github/scripts/daily-sweep.sh \
           .github/scripts/runtime-check.sh .github/scripts/review-rounds.sh \
           .github/scripts/text-only.sh \
           docs-public/guard-data/expected-protection.json; do
    if api "contents/$f?ref=main" > /dev/null; then ok "on main: $f"; else bad "missing on main: $f"; fi
  done ;;

# guard-builder-Opus5.5-agent, 2026-10-28: CODEOWNERS follows the
# risk map line for line. No map: the one line "* @owner"
codeowners)
  owner="$(repo_var GUARD_OWNER_LOGIN)"
  body="$(api "contents/.github/CODEOWNERS?ref=main" | jq -r '.content // empty' | base64 --decode 2>/dev/null || true)"
  map="$(api "contents/docs-public/guard-data/risk-map.txt?ref=main" | jq -r '.content // empty' | base64 --decode 2>/dev/null || true)"
  have="$(printf '%s\n' "$body" | grep -vE '^[[:space:]]*(#|$)' | awk '{$1=$1; print}')"
  if [ -z "$body" ]; then bad "no .github/CODEOWNERS on main"
  elif [ -z "$owner" ]; then bad "GUARD_OWNER_LOGIN is unset: can't check CODEOWNERS"
  elif [ -z "$(printf '%s\n' "$map" | grep -vE '^[[:space:]]*(#|$)')" ]; then
    [ "$have" = "* @$owner" ] && ok "CODEOWNERS: * @$owner (no risk map on main, so every PR waits for the owner)" \
      || bad "CODEOWNERS is not the one line '* @$owner', and there is no risk map on main"
  else
    want="$(printf '%s\n' "$map" | grep -vE '^[[:space:]]*(#|$)' | awk -v o="@$owner" '{print "/" $2 " " o}')"
    badglob="$(printf '%s\n' "$map" | grep -vE '^[[:space:]]*(#|$)' | awk '{print $2}' | grep -E '^/|[^A-Za-z0-9._/*-]' || true)"
    if [ -n "$badglob" ]; then bad "risk map glob(s) CODEOWNERS can't read (leading /, or ! [ ] ? \\ space): $(printf '%s' "$badglob" | tr '\n' ' ')"
    elif [ "$have" = "$want" ]; then ok "CODEOWNERS: @$owner on the risk map's $(printf '%s\n' "$want" | wc -l | tr -d ' ') path(s), nothing else"
    else bad "CODEOWNERS doesn't match the risk map line for line. Want: $(printf '%s' "$want" | tr '\n' ';')"; fi
  fi ;;

rules)
  app="$(repo_var REVIEWER_APP_ID)"; [ -n "$app" ] || app="${REVIEWER_APP_ID:-}"
  rules="$(api rules/branches/main)"
  if [ -z "$rules" ]; then bad "can't read the rules on main"; continue; fi
  for t in deletion non_fast_forward; do
    printf '%s' "$rules" | jq -e --arg t "$t" 'any(.[]; .type == $t)' > /dev/null && ok "rule on main: $t" || bad "rule missing on main: $t"
  done
  printf '%s' "$rules" | jq -e 'any(.[]; .type == "pull_request" and .parameters.require_code_owner_review and .parameters.required_approving_review_count == 0)' > /dev/null \
    && ok "rule on main: pull request, 0 approvals, code-owner review" || bad "rule on main: pull request with 0 approvals and code-owner review is missing (the owner reviews only the risk map's paths)"
  # the owner's approval turns checks green, so a push after it must
  # dismiss it (owner-call.sh also counts only an approval of the head commit).
  # Last-push approval stays off: GitHub applies it even at 0 approvals, and the
  # agent login pushes every PR, so it held every routine PR
  printf '%s' "$rules" | jq -e 'any(.[]; .type == "pull_request" and .parameters.dismiss_stale_reviews_on_push and (.parameters.require_last_push_approval | not))' > /dev/null \
    && ok "rule on main: stale approvals dismissed, last-push approval off" || bad "rule on main: 'Dismiss stale pull request approvals when new commits are pushed' must be on and 'Require approval of the most recent reviewable push' off (on, it holds every routine PR)"
  # routine PRs merge themselves, so repo auto-merge must be on
  repojson="$(gh api "repos/$repo" 2>/dev/null)"
  [ "$(printf '%s' "$repojson" | jq -r '.allow_auto_merge')" = "true" ] && ok "repository: auto-merge allowed" || bad "repository: 'Allow auto-merge' is off (Settings, General, Pull Requests)"
  # one commit per PR, and its message is the PR description, so the
  # commit on main ends with the PR's signature line
  printf '%s' "$rules" | jq -e 'any(.[]; .type == "pull_request" and ((.parameters.allowed_merge_methods // []) | sort) == ["squash"])' > /dev/null \
    && ok "rule on main: squash merges only" || bad "rule on main: allowed merge methods must be squash only (ruleset, Require a pull request, Allowed merge methods)"
  [ "$(printf '%s' "$repojson" | jq -r '.squash_merge_commit_message')" = "PR_BODY" ] && ok "repository: squash message is the PR description" \
    || bad "repository: the squash default message must be 'Pull request title and description' (Settings, General, Pull Requests); otherwise text lands after the signature line"
  # the daily sweep compares the live rules with the saved copy; a copy that
  # already differs at install hides every later change
  saved="$(api "contents/docs-public/guard-data/expected-protection.json?ref=main" | jq -r '.content // empty' | base64 -d 2>/dev/null | jq -S . 2>/dev/null)"
  livecopy="$(printf '%s' "$rules" | jq -S '[.[] | {type, parameters}] | sort_by(.type)')"
  [ -n "$saved" ] && [ "$saved" = "$livecopy" ] && ok "saved copy of the rules matches main" \
    || bad "docs-public/guard-data/expected-protection.json on main does not match the live rules on main: update it in a PR the owner merges"
  printf '%s' "$rules" | jq -e 'any(.[]; .type == "required_status_checks" and .parameters.strict_required_status_checks_policy)' > /dev/null \
    && ok "rule on main: branches up to date" || bad "rule on main: 'require branches to be up to date' is off"
  for c in slice-review test-lock; do
    printf '%s' "$rules" | jq -e --arg c "$c" --argjson a "${app:-0}" \
      'any(.[]; .type == "required_status_checks" and any(.parameters.required_status_checks[]; .context == $c and .integration_id == $a))' > /dev/null \
      && ok "required check: $c from app ${app:-?}" || bad "required check $c from the reviewer app (${app:-REVIEWER_APP_ID unset}) is missing"
  done ;;

bypass)
  me="$(gh api user --jq .login 2>/dev/null || echo '?')"
  can="$(api rulesets | jq -r '.[].id' | while read -r id; do api "rulesets/$id" | jq -r '.current_user_can_bypass // "unknown"'; done | sort -u | tr '\n' ' ')"
  case "$can" in
    "never ") ok "bypass: $me can never bypass the rules on main" ;;
    "") bad "bypass: no ruleset found" ;;
    *) bad "bypass: $me can bypass ($can). Only the owner may; remove this login from the bypass list" ;;
  esac ;;

environment)
  env="$(api environments/reviewer)"
  if [ -z "$env" ]; then bad "no 'reviewer' environment"; continue; fi
  printf '%s' "$env" | jq -e '.deployment_branch_policy.custom_branch_policies == true and .deployment_branch_policy.protected_branches == false' > /dev/null \
    || { bad "environment 'reviewer' is open to every branch: limit it to 'Selected branches' with main only"; continue; }
  pol="$(api "environments/reviewer/deployment-branch-policies" | jq -c '[.branch_policies[] | {name, type}]')"
  [ "$pol" = '[{"name":"main","type":"branch"}]' ] && ok "environment 'reviewer': main only" \
    || bad "environment 'reviewer' branch rules are $pol, not main only" ;;

variables)
  for v in GUARD_OWNER_LOGIN GUARD_AGENT_LOGIN REVIEWER_APP_ID GUARD_KIT_OWNER GUARD_KIT_REPO GUARD_TEST_COMMAND; do
    [ -n "$(repo_var "$v")" ] && ok "repository variable: $v" || bad "repository variable $v is missing (a 'reviewer' environment variable doesn't count: two jobs run outside the environment)"
  done
  envvars="$(api "environments/reviewer/variables" | jq -r '.variables[].name')"
  printf '%s\n' "$envvars" | grep -qx REVIEWER_APP_CLIENT_ID && ok "environment variable: REVIEWER_APP_CLIENT_ID" \
    || bad "environment variable REVIEWER_APP_CLIENT_ID is missing from 'reviewer'" ;;

secrets)
  names="$(api "environments/reviewer/secrets" | jq -r '.secrets[].name')"
  for v in REVIEWER_APP_PRIVATE_KEY CLAUDE_CODE_OAUTH_TOKEN; do
    printf '%s\n' "$names" | grep -qx "$v" && ok "environment secret: $v" || bad "environment secret $v is missing from 'reviewer'"
  done
  printf '%s\n' "$names" | grep -qx REVIEWER_APP_CLIENT_ID \
    && bad "REVIEWER_APP_CLIENT_ID is saved as a secret: workflows read it as a variable, so it comes through empty" \
    || ok "REVIEWER_APP_CLIENT_ID is not a secret" ;;

# guard-builder-Opus5.5-agent, 2026-10-25: the runtime record on
# main, checked as locked-checks reads it
runtime)
  rec="$(mktemp)"
  if ! api "contents/docs-public/guard-data/runtime.txt?ref=main" | jq -r '.content // empty' | base64 --decode > "$rec" 2>/dev/null || [ ! -s "$rec" ]; then
    bad "no docs-public/guard-data/runtime.txt on main: locked-checks won't run (README-GUARDS, 'Runtime record')"
  elif line="$(bash "$here/runtime-check.sh" record "$rec")"; then
    ok "runtime record: $(printf '%s\n' "$line" | sed -n 's/^lang=//p') $(printf '%s\n' "$line" | sed -n 's/^version=//p') on $(printf '%s\n' "$line" | sed -n 's/^runner=//p')"
  else
    bad "$(printf '%s' "$line" | sed 's/^PROBLEM  //')"
  fi
  rm -f "$rec" ;;

# kit-keeper-Opus5.5-agent, 2026-10-27: the risk map on main, read
# as test-lock reads it. No map is valid: every slice is then risky
risk-map)
  map="$(mktemp)"
  if ! api "contents/docs-public/guard-data/risk-map.txt?ref=main" | jq -r '.content // empty' | base64 --decode > "$map" 2>/dev/null || [ ! -s "$map" ]; then
    ok "risk map: none on main, so every slice is risky and has its own plan PR"
  else
    n=0; lines=0; badmap=0
    while IFS= read -r line || [ -n "$line" ]; do
      n=$((n + 1))
      case "$line" in ''|'#'*) continue ;; esac
      read -r cls glob rest <<< "$line"
      case "$cls" in DATA|ACCESS|SHARED) ;; *) cls="" ;; esac
      if [ -z "$cls" ] || [ -z "${glob:-}" ] || [ -n "${rest:-}" ]; then
        bad "risk map line $n is not '<DATA|ACCESS|SHARED> <path glob>': every one-PR slice fails until it is fixed"; badmap=1
      else lines=$((lines + 1)); fi
    done < "$map"
    [ "$badmap" -eq 1 ] || ok "risk map: $lines path(s) on main"
  fi
  rm -f "$map" ;;

# guard-builder-Opus5.5-agent, 2026-11-10: a public repository blocks
# pull_request_target unless an Actions policy allows it, and only an admin
# can read the policy; a blocked run shows as startup_failure
workflow-runs)
  since="$(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-7d +%Y-%m-%dT%H:%M:%SZ)"
  if ! runs="$(api "actions/runs?event=pull_request_target&created=>=$since&per_page=100")"; then
    bad "can't list the pull_request_target runs"; continue; fi
  # each workflow's latest run decides: an older blocked run fixed since is fine
  blocked="$(printf '%s' "$runs" | jq -r '[.workflow_runs | group_by(.name)[] | max_by(.created_at) | select(.conclusion == "startup_failure") | .name] | join(", ")')"
  [ -z "$blocked" ] && ok "pull_request_target runs: each workflow's latest run started" \
    || bad "pull_request_target workflows whose latest run failed to start ($blocked): on a public repository, add the Actions policy (Settings, Actions, Policies: Active, .github/workflows/*.yml, Restrict events with every event allowed)" ;;

*) bad "unknown section: $s" ;;
esac; done

[ "$problems" -eq 0 ] && echo "All guard settings OK." || echo "$problems problem(s)."
[ "$problems" -eq 0 ]
