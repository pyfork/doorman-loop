#!/usr/bin/env bash
# guard-builder-Opus5.5-agent, 2026-10-28
# The review loop: the reviewer gates, the judge rules on two fix rounds,
# then the owner. slice-review.yml calls it; it calls no model itself.
#
#   review-rounds.sh state  <reviews.json>             -> state JSON
#   review-rounds.sh filter <runA> <runB|-> <root>     -> filtered findings JSON
#   review-rounds.sh decide <state> <filtered> <judge|-> <sha> [results.txt]
#                                                      -> decision JSON
#   review-rounds.sh seal   <record JSON>              -> marker line to post
#
# State lives in the reviewer app's own PR reviews, one sealed record per
# run: a submitted review can't be deleted, and the seal is an HMAC with
# REVIEW_STATE_KEY (the app's private key), so an edited record is caught.
# The round count is per PR, not per commit: a force push resets nothing.
# A finding's key is the rule it cites, "<file>#<section>".
set -euo pipefail
marker='kip-review-state'

hmac() { printf '%s' "$1" | openssl dgst -sha256 -hmac "${REVIEW_STATE_KEY:?REVIEW_STATE_KEY unset}" -r | awk '{print $1}'; }

case "${1:-}" in
seal)
  body="$(printf '%s' "$2" | jq -c . | base64 | tr -d '\n')"
  echo "<!-- $marker $body $(hmac "$body") -->" ;;

# Every sealed record in the app's reviews, oldest first. Any record whose
# seal doesn't match: tampered, and the PR goes to the owner.
state)
  # Each line is "<review submitted_at> <marker comment>"; the time is
  # GitHub's, outside the seal, and only says since when the judge reads
  # the PR's comments: since the FAIL that opened the current findings
  #
  recs="[]"; tampered=false
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    read -r at _ _ body mac _ <<< "$line"
    if [ "$(hmac "$body")" = "$mac" ] && rec="$(printf '%s' "$body" | base64 --decode 2>/dev/null | jq -c . 2>/dev/null)"; then
      recs="$(jq -c --argjson r "$rec" --arg at "$at" '. + [$r + {at: $at}]' <<< "$recs")"
    else tampered=true; fi
  done < <(jq -r --arg m "$marker" '.[] | (.submitted_at // "-") as $t | (.body // "") | scan("<!-- \($m) [^ ]* [^ ]* -->") | "\($t) \(.)"' "$2" || true)
  jq -n --argjson r "$recs" --argjson t "$tampered" '{
      tampered: $t,
      judged: ([$r[] | select(.kind == "judged")] | length),
      open: (($r | last // {}).open // []),
      sha: (($r | last // {}).sha // ""),
      since: (([range(0; $r | length) | select(($r[.].open // []) | length == 0)] | last // -1) as $i
        | ($r[$i + 1].at // "")),
      with_owner: (($r | last // {}).with_owner // false)
    }' ;;

# A finding blocks only if it cites a rule file that exists under the root
# (main plus the kit's rules) with a heading naming its section, and, when
# a second run exists, the second run cites the same rule. The rest are
# notes (no rule) or flaky (didn't repeat).
filter)
  a="$2"; b="$3"; root="$4"
  verdict="$(jq -r '.verdict // "FAIL"' "$a")"
  out='{"blocking":[],"notes":[],"flaky":[]}'
  # A repeat is the same rule file in the re-run: the two runs name one
  # section differently ("10. TESTS", "Time in tests")
  keysb="[]"; [ "$b" != - ] && keysb="$(jq -c '[.findings // [] | .[] | select(.rule_file != "") | .rule_file]' "$b")"
  while IFS= read -r f; do
    file="$(jq -r '.rule_file // ""' <<< "$f")"; sec="$(jq -r '.rule_section // ""' <<< "$f")"; key="$file#$sec"
    ok=false
    case "$file" in ''|/*|*..*|pr-head/*) ;; *)
      # the kit's rules don't all use markdown headings
      # ("THE RULE"), so the section is any line of the file naming it
      [ -f "$root/$file" ] && [ -n "$sec" ] && grep -qiF -- "$sec" "$root/$file" && ok=true ;;
    esac
    if [ "$ok" != true ]; then out="$(jq -c --argjson f "$f" '.notes += [$f]' <<< "$out")"
    elif [ "$b" != - ] && ! jq -e --arg k "$file" 'index($k)' <<< "$keysb" > /dev/null; then out="$(jq -c --argjson f "$f" '.flaky += [$f]' <<< "$out")"
    else out="$(jq -c --argjson f "$f" --arg k "$key" '.blocking += [$f + {key: $k}] | .blocking |= unique_by(.key)' <<< "$out")"; fi
  done < <(jq -c '.findings // [] | .[]' "$a")
  # Fails closed: a FAIL that lists no finding at all still blocks, and so
  # does a FAIL whose cited rules all failed the check (else a real FAIL
  # would become a PASS), and so does a FAIL made only of uncited notes.
  # Flaky findings drop only when the re-run did not FAIL too: two FAILs
  # whose cites don't match are not a PASS (a re-run that cites nothing
  # would make every finding of the first run look unrepeated)
  verdictb=-; [ "$b" != - ] && verdictb="$(jq -r '.verdict // "FAIL"' "$b")"
  if [ "$verdict" = FAIL ] && [ "$(jq '.findings // [] | length' "$a")" -eq 0 ]; then
    out="$(jq -c '.blocking += [{key: "reviewer#no findings", rule_file: "", rule_section: "", text: "The reviewer said FAIL but listed no finding"}]' <<< "$out")"
  elif [ "$verdict" = FAIL ] && [ "$(jq '.blocking | length' <<< "$out")" -eq 0 ]; then
    [ "$verdictb" = FAIL ] && out="$(jq -c '.blocking = ([.flaky[] | . + {key: "\(.rule_file)#\(.rule_section)"}] | unique_by(.key)) | .flaky = []' <<< "$out")"
    while IFS= read -r f; do
      out="$(jq -c --argjson f "$f" '.blocking += [$f + {key: "\($f.rule_file)#\($f.rule_section)", text: ("Cited rule not found as given: " + $f.text)}] | .notes -= [$f]' <<< "$out")"
    done < <(jq -c '.notes[] | select(.rule_file != "")' <<< "$out")
    # The uncited ones as one finding with a fixed key, so the judge can
    # rule on it and a later round's uncited FAIL isn't "new"
    out="$(jq -c 'if (.blocking | length) == 0 and (.notes | length) > 0 then
        .blocking += [{key: "reviewer#FAIL citing no rule", rule_file: "", rule_section: "", text: ("The reviewer said FAIL citing no rule: " + ([.notes[].text] | join(" | ")))}] | .notes = []
      else . end' <<< "$out")"
  fi
  jq -c --arg v "$verdict" '. + {verdict: $v}' <<< "$out" ;;

# One run's outcome. pass = the check passes; record = what to seal.
decide)
  st="$2"; fl="$3"; jd="$4"; sha="$5"; res="${6:-}"
  judge='{"rulings":[]}'; [ "$jd" != - ] && judge="$(cat "$jd")"
  # the test command is where scripted project rules
  # run, so its FAIL fails the check by itself, with no model in between
  suite=false; [ -n "$res" ] && [ -f "$res" ] && grep -q '^FAIL: ' "$res" && suite=true
  jq -n --argjson s "$(cat "$st")" --argjson f "$(cat "$fl")" --argjson j "$judge" --arg sha "$sha" --argjson suite "$suite" --arg lane "${LANE:-OTHER}" '
    def keys(x): [x[] | .key];
    ($f.blocking) as $found
    | if $s.tampered then
        {pass:false, owner:true, why:"A review-state record on this PR was edited, so the round count cannot be trusted. The owner decides.", unsolved:$s.open, record:null}
      elif $suite then
        {pass:false, owner:false, why:"The test command failed (a test or a scripted project rule is red; see the locked-checks results). Fix it on the branch: not a judge round.", unsolved:$s.open, record:null}
      elif $f.verdict == "BLOCKED" then
        {pass:false, owner:false, why:"The reviewer was BLOCKED (missing inputs). Not a fix round.", unsolved:$s.open, record:null}
      # a PR that is not a slice is for the Lead to close
      # or plan, so it never goes to the owner, whatever the round
      elif any($found[]; (.rule_file | endswith("slice-pr-reviewer.md")) and (.rule_section | test("not a slice"; "i"))) then
        # PLAN and OWNED: every file is owned by the owner, so their Approve decides (owner-call.sh)
        (if ($lane == "PLAN" or $lane == "OWNED") then "Not a slice, but every file is owner-owned (lane \($lane)): the owner approves; no bypass."
         else "Not a slice: the Lead closes this PR or plans the slice first. Not a call for the owner." end) as $why
        | {pass:false, owner:false, why:$why, unsolved:$found, record:null}
      elif $s.with_owner then
        {pass:false, owner:true, why:"Two judge rounds left findings unsolved. The owner decides.", unsolved:$s.open, record:null}
      elif ($s.open | length) > 0 and $s.sha == $sha then
        {pass:false, owner:false, why:"No new commit since the FAIL: the judge runs on the next push.", unsolved:$s.open, record:null}
      elif ($s.open | length) > 0 then
        ($s.judged + 1) as $round
        | [ $s.open[] | . as $o | select(([$j.rulings[] | select(.key == $o.key and .solved == true)] | length) == 0) ] as $unsolved
        # A "reviewer#" finding (a FAIL citing no rule) is for the reviewer to
        # call this round, whatever the judge said of the last one
        | [ $found[] | select(.key as $k | ($k | startswith("reviewer#")) or (keys($s.open) | index($k)) == null) ] as $new
        | ([ $unsolved[] | select(.key as $k | (keys($new) | index($k)) == null) ] + $new) as $left
        | if ($left | length) == 0 then
            {pass:true, owner:false, why:"Judge round \($round): every finding solved.", unsolved:[], record:{kind:"judged", round:$round, sha:$sha, open:[]}}
          elif $round >= 2 then
            {pass:false, owner:true, why:"Judge round \($round): \($left | length) finding(s) still unsolved. The owner decides.", unsolved:$left, record:{kind:"judged", round:$round, sha:$sha, open:$left, with_owner:true}}
          else
            {pass:false, owner:false, why:"Judge round \($round): \($left | length) finding(s) unsolved. Back to the agent for fixes; round 2 is the last before the owner.", unsolved:$left, record:{kind:"judged", round:$round, sha:$sha, open:$left}}
          end
      elif ($found | length) == 0 then
        {pass:true, owner:false, why:"No blocking finding.", unsolved:[], record:{kind:"pass", sha:$sha, open:[]}}
      elif $s.judged >= 2 then
        {pass:false, owner:true, why:"New blocking finding(s) after two judge rounds. The owner decides.", unsolved:$found, record:{kind:"fail", sha:$sha, open:$found, with_owner:true}}
      else
        {pass:false, owner:false, why:"\($found | length) blocking finding(s). Sent back to the agent for fixes; the judge rules on the next push.", unsolved:$found, record:{kind:"fail", sha:$sha, open:$found}}
      end' ;;

*) echo "usage: review-rounds.sh state|filter|decide|seal ..." >&2; exit 2 ;;
esac
