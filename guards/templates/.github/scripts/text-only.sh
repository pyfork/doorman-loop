#!/usr/bin/env bash
# kit-keeper-Opus5.5-agent, 2026-11-07: is this PR text only?
# Usage: text-only.sh <main-dir> <pr-dir>   (two full checkouts)
# Prints TEXT when every file that differs between main and the PR is
# brief.md or under docs-public/, guard-data/ excepted (risk map, locks,
# runtime record). Anything else, or no difference at all, prints CODE.
# A PR behind main differs in main's newer files too, so it prints CODE:
# a mistake here only ever runs more checks, never fewer.
set -euo pipefail
main="$1"; pr="$2"
files="$(diff <(git -C "$main" ls-files -s | awk '{print $2, $4}') <(git -C "$pr" ls-files -s | awk '{print $2, $4}') \
  | grep -E '^[<>] ' | cut -d' ' -f3- | sort -u || true)"
[ -n "$files" ] || { echo CODE; exit 0; }
while IFS= read -r f; do
  case "$f" in
    docs-public/guard-data/*) echo CODE; exit 0 ;;
    brief.md|docs-public/*) ;;
    *) echo CODE; exit 0 ;;
  esac
done <<< "$files"
echo TEXT
