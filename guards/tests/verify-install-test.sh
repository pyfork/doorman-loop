#!/usr/bin/env bash
# guard-builder-Opus5.5-agent, 2026-10-20
# Unit test for templates/.github/scripts/verify-install.sh. A stub `gh`
# serves canned API answers: one good install, then one wrong setting at a
# time (the slips seen on a real install), each of which must give PROBLEM.
# Run from the repo root: bash guards/tests/verify-install-test.sh
set -uo pipefail
script="$(pwd)/guards/templates/.github/scripts/verify-install.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0

# --- the stub: `gh api user --jq .login` and `gh api repos/<repo>/<path>`
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
[ "$2" = user ] && { echo agent; exit 0; }
path="${2#repos/o/r/}"; path="${path%%\?*}"
f="$FIXTURES/$(printf '%s' "$path" | tr '/' '_').json"
[ -f "$f" ] && cat "$f" || exit 1
STUB
chmod +x "$work/bin/gh"

runtime_record() { # runtime_record <dir> <body>: main's runtime.txt as the API serves it
  printf '{"content":"%s"}' "$(printf '%b' "$2" | base64 | tr -d '\n')" > "$1/contents_docs-public_guard-data_runtime.txt.json"
}

saved_copy() { # saved_copy <dir>: expected-protection.json on main = the live rules
  printf '{"content":"%s"}' "$(jq -S '[.[] | {type, parameters}] | sort_by(.type)' "$1/rules_branches_main.json" | base64 | tr -d '\n')" \
    > "$1/contents_docs-public_guard-data_expected-protection.json.json"
}

good() { # writes a correct install into $1
  d="$1"; mkdir -p "$d"
  for f in .github/workflows/slice-review.yml .github/workflows/test-lock.yml .github/workflows/daily-sweep.yml \
           .github/workflows/main-tripwire.yml .github/scripts/test-lock.sh .github/scripts/daily-sweep.sh \
           .github/scripts/runtime-check.sh .github/scripts/review-rounds.sh .github/scripts/text-only.sh docs-public/guard-data/expected-protection.json; do
    echo '{}' > "$d/contents_$(printf '%s' "$f" | tr '/' '_').json"; done
  printf '{"content":"%s"}' "$(printf '* @owner\n' | base64)" > "$d/contents_.github_CODEOWNERS.json"
  runtime_record "$d" 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=python 3.10\nINSTALL=scripts/install.sh\n'
  for v in GUARD_OWNER_LOGIN:owner GUARD_AGENT_LOGIN:agent REVIEWER_APP_ID:42 GUARD_KIT_OWNER:owner GUARD_KIT_REPO:kit GUARD_TEST_COMMAND:true; do
    printf '{"value":"%s"}' "${v#*:}" > "$d/actions_variables_${v%%:*}.json"; done
  cat > "$d/rules_branches_main.json" <<'J'
[{"type":"deletion"},{"type":"non_fast_forward"},
 {"type":"pull_request","parameters":{"require_code_owner_review":true,"required_approving_review_count":0,"require_last_push_approval":false,"dismiss_stale_reviews_on_push":true,"allowed_merge_methods":["squash"]}},
 {"type":"required_status_checks","parameters":{"strict_required_status_checks_policy":true,
   "required_status_checks":[{"context":"slice-review","integration_id":42},{"context":"test-lock","integration_id":42}]}}]
J
  echo '{"allow_auto_merge":true,"squash_merge_commit_message":"PR_BODY"}' > "$d/repos_o_r.json"
  saved_copy "$d"
  echo '{"workflow_runs":[{"name":"test-lock","conclusion":"success","created_at":"2026-11-10T00:00:00Z"},{"name":"test-lock","conclusion":"startup_failure","created_at":"2026-11-09T16:00:00Z"}]}' > "$d/actions_runs.json"
  echo '[{"id":7}]' > "$d/rulesets.json"
  echo '{"current_user_can_bypass":"never"}' > "$d/rulesets_7.json"
  echo '{"deployment_branch_policy":{"custom_branch_policies":true,"protected_branches":false}}' > "$d/environments_reviewer.json"
  echo '{"branch_policies":[{"name":"main","type":"branch"}]}' > "$d/environments_reviewer_deployment-branch-policies.json"
  echo '{"variables":[{"name":"REVIEWER_APP_CLIENT_ID"}]}' > "$d/environments_reviewer_variables.json"
  echo '{"secrets":[{"name":"REVIEWER_APP_PRIVATE_KEY"},{"name":"CLAUDE_CODE_OAUTH_TOKEN"}]}' > "$d/environments_reviewer_secrets.json"
}

run() { FIXTURES="$1" GH_REPO=o/r PATH="$work/bin:$PATH" bash "$script" > "$work/out" 2>&1; }

# T1: a correct install passes
good "$work/t1"; if run "$work/t1"; then echo "PASS T1 correct install: all OK"; else echo "FAIL T1 correct install"; cat "$work/out"; fails=1; fi

# T2..: one slip each must exit 1 and name it
slip() { # slip <id> <expected text> <shell that breaks the fixture in $d>
  d="$work/$1"; good "$d"; ( cd "$d" && eval "$3" )
  if run "$d"; then echo "FAIL $1: passed, expected PROBLEM '$2'"; fails=1
  elif grep -q "PROBLEM.*$2" "$work/out"; then echo "PASS $1: $2"
  else echo "FAIL $1: no PROBLEM line with '$2'"; cat "$work/out"; fails=1; fi
}
slip T2 "open to every branch" \
  "echo '{\"deployment_branch_policy\":null}' > environments_reviewer.json"
slip T3 "saved as a secret" \
  "echo '{\"secrets\":[{\"name\":\"REVIEWER_APP_PRIVATE_KEY\"},{\"name\":\"CLAUDE_CODE_OAUTH_TOKEN\"},{\"name\":\"REVIEWER_APP_CLIENT_ID\"}]}' > environments_reviewer_secrets.json; echo '{\"variables\":[]}' > environments_reviewer_variables.json"
slip T4 "repository variable GUARD_OWNER_LOGIN is missing" \
  "rm actions_variables_GUARD_OWNER_LOGIN.json"
slip T5 "can bypass" \
  "echo '{\"current_user_can_bypass\":\"pull_requests_only\"}' > rulesets_7.json"
slip T6 "test-lock from the reviewer app" \
  "sed -i.bak 's/{\"context\":\"test-lock\",\"integration_id\":42}/{\"context\":\"test-lock\",\"integration_id\":99}/' rules_branches_main.json"
slip T7 "be up to date" \
  "sed -i.bak 's/\"strict_required_status_checks_policy\":true/\"strict_required_status_checks_policy\":false/' rules_branches_main.json"
slip T8 "main only" \
  "echo '{\"branch_policies\":[{\"name\":\"main\",\"type\":\"branch\"},{\"name\":\"*\",\"type\":\"branch\"}]}' > environments_reviewer_deployment-branch-policies.json"
slip T9 "CODEOWNERS" \
  "rm contents_.github_CODEOWNERS.json"
# guard-builder-Opus5.5-agent, 2026-10-25: the runtime record
slip T10 "no docs-public/guard-data/runtime.txt on main" \
  "rm contents_docs-public_guard-data_runtime.txt.json"
slip T11 "moving label" \
  "runtime_record . 'RUNNER=ubuntu-latest\\nOS=ubuntu 24.04\\nRUNTIME=python 3.12\\nINSTALL=x\\n'"

# kit-keeper-Opus5.5-agent, 2026-10-27: the risk map (none is OK)
slip T12 "risk map line 2" \
  "printf '{\"content\":\"%s\"}' \"\$(printf 'DATA migrations/**\\nSECRET app/**\\n' | base64 | tr -d '\\n')\" > contents_docs-public_guard-data_risk-map.txt.json"

# guard-builder-Opus5.5-agent, 2026-10-28: 0 approvals, auto-merge,
# CODEOWNERS line for line with the risk map
map_and_owners() { # map_and_owners <map body> <CODEOWNERS body>
  printf '{"content":"%s"}' "$(printf '%b' "$1" | base64 | tr -d '\n')" > contents_docs-public_guard-data_risk-map.txt.json
  printf '{"content":"%s"}' "$(printf '%b' "$2" | base64 | tr -d '\n')" > contents_.github_CODEOWNERS.json
}
d="$work/t1b"; good "$d"; ( cd "$d" && map_and_owners '# map\nSHARED  .github/**\nDATA app/pay/**\n' '# owners\n/.github/** @owner\n/app/pay/** @owner\n' )
if run "$d"; then echo "PASS T1b map and matching CODEOWNERS: all OK"; else echo "FAIL T1b map and matching CODEOWNERS"; cat "$work/out"; fails=1; fi
slip T13 "pull request with 0 approvals" \
  "sed -i.bak 's/\"required_approving_review_count\":0/\"required_approving_review_count\":1/' rules_branches_main.json"
slip T14 "Allow auto-merge" \
  "echo '{\"allow_auto_merge\":false}' > repos_o_r.json"
slip T15 "match the risk map line for line" \
  "map_and_owners 'SHARED .github/**\nDATA app/pay/**\n' '/.github/** @owner\n'"
slip T16 "match the risk map line for line" \
  "map_and_owners 'SHARED .github/**\n' '* @owner\n/.github/** @owner\n'"
slip T17 "not the one line" \
  "printf '{\"content\":\"%s\"}' \"\$(printf '/app/** @owner\n' | base64)\" > contents_.github_CODEOWNERS.json"
slip T18 "CODEOWNERS can't read" \
  "map_and_owners 'DATA app/[ab]/**\n' '/app/[ab]/** @owner\n'"
# kit-reviewer-Opus5.5-agent, 2026-11-01; senior-lead-Opus5.5-agent, 2026-11-03: last-push
# approval on holds every agent-pushed PR, routine ones too, so turning it on is the slip
slip T19 "approval of the most recent reviewable push" \
  "sed -i.bak 's/\"require_last_push_approval\":false/\"require_last_push_approval\":true/' rules_branches_main.json"
slip T20 "Dismiss stale pull request approvals" \
  "sed -i.bak 's/\"dismiss_stale_reviews_on_push\":true/\"dismiss_stale_reviews_on_push\":false/' rules_branches_main.json"

# guard-builder-Opus5.5-agent, 2026-11-10: squash only, the squash message,
# the saved copy of the rules, pull_request_target runs that never started
# (T1's fixture holds an older blocked run fixed since: still OK)
slip T21 "squash only" \
  "sed -i.bak 's/\"allowed_merge_methods\":\[\"squash\"\]/\"allowed_merge_methods\":[\"merge\",\"squash\"]/' rules_branches_main.json"
slip T22 "Pull request title and description" \
  "echo '{\"allow_auto_merge\":true,\"squash_merge_commit_message\":\"COMMIT_MESSAGES\"}' > repos_o_r.json"
slip T23 "does not match the live rules" \
  "sed -i.bak 's/\"require_code_owner_review\":true/\"require_code_owner_review\":false/' rules_branches_main.json"
slip T24 "latest run failed to start (new-file-check, test-lock)" \
  "echo '{\"workflow_runs\":[{\"name\":\"test-lock\",\"conclusion\":\"startup_failure\",\"created_at\":\"2026-11-10T01:00:00Z\"},{\"name\":\"test-lock\",\"conclusion\":\"success\",\"created_at\":\"2026-11-09T01:00:00Z\"},{\"name\":\"new-file-check\",\"conclusion\":\"startup_failure\",\"created_at\":\"2026-11-10T01:00:00Z\"},{\"name\":\"ci\",\"conclusion\":\"success\",\"created_at\":\"2026-11-10T01:00:00Z\"}]}' > actions_runs.json"
slip T25 "can't list the pull_request_target runs" \
  "rm actions_runs.json"

[ "$fails" -eq 0 ] && echo "verify-install-test: all passed" || echo "verify-install-test: FAILED"
exit "$fails"
