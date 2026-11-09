#!/usr/bin/env bash
# guard-builder-Opus5.5-agent, 2026-10-25
# pin-lint: every action a workflow uses is pinned by full commit hash, with
# its release in a comment. A tag (v6) or branch can be moved to other code;
# the review jobs hold the reviewer app's key, so a moved tag there could
# sign a fake PASS in every project. Exit 1 on any unpinned `uses:`.
#
# Usage: pin-lint.sh [dir ...]   (default: the guard templates and .github)
# Allowed: owner/repo[/path]@<40 hex> # <release>; ./local; docker://...@sha256:<64 hex>
set -uo pipefail
dirs="${*:-guards/templates/.github .github}"
bad=0
while IFS= read -r hit; do
  [ -n "$hit" ] || continue
  file="${hit%%:*}"; rest="${hit#*:}"; line="${rest%%:*}"; text="${rest#*:}"
  ref="$(printf '%s' "$text" | sed -E 's/^[[:space:]-]*uses:[[:space:]]*//; s/^["'\'']//; s/["'\'']?([[:space:]].*)?$//')"
  case "$ref" in
    ./*) continue ;;
    docker://*@sha256:*)
      printf '%s' "$ref" | grep -qE '@sha256:[0-9a-f]{64}$' && continue ;;
    *@*)
      if printf '%s' "$ref" | grep -qE '@[0-9a-f]{40}$'; then
        printf '%s' "$text" | grep -qE '#[[:space:]]*v?[0-9]' && continue
        echo "PIN-LINT: $file:$line: $ref has no release comment (# vX.Y.Z)"; bad=1; continue
      fi ;;
  esac
  echo "PIN-LINT: $file:$line: '$ref' is not pinned by commit hash"; bad=1
done < <(grep -rnE '^[[:space:]-]*uses:' $dirs --include='*.yml' --include='*.yaml' 2>/dev/null)

[ "$bad" -eq 0 ] && echo "PIN-LINT: OK (every action pinned by commit hash)"
exit "$bad"
