#!/usr/bin/env bash
# kit-reviewer-Opus5.5-agent, 2026-11-01: the owner's approval
# stands in for a red check that is the owner's call, so the owner approves
# instead of bypass-merging, and every other required check still holds.
# Usage: owner-call.sh <reviews.json> <owner-login> <sha> <lane> [labels.txt]
#   reviews.json: GET pulls/<n>/reviews, all pages, as one array
#   lane: pr-lane.sh's word; labels.txt: the PR's labels, one per line
# Exit 0 only when both hold:
# - the owner's latest deciding review (approve, request changes, or a
#   dismissed one) is APPROVED on <sha>, so a push after it needs a new one
# - the red check is the owner's call: a plan PR, a PR of owner-owned files
#   only (lane OWNED), or a PR the review loop sent to them (needs-owner)
set -euo pipefail
reviews="$1"; owner="$2"; sha="$3"; lane="$4"; labels="${5:-/dev/null}"
case "$lane" in
  PLAN|OWNED) ;;
  *) grep -qx needs-owner "$labels" || exit 1 ;;
esac
jq -e --arg o "$owner" --arg s "$sha" '
  [ .[] | select((.user.login | ascii_downcase) == ($o | ascii_downcase)
                 and (.state == "APPROVED" or .state == "CHANGES_REQUESTED" or .state == "DISMISSED")) ]
  | sort_by(.submitted_at) | last // {} | (.state == "APPROVED" and .commit_id == $s)' "$reviews" > /dev/null
