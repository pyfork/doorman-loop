#!/usr/bin/env bash
# compare each stand-in page with its baseline (check), or replace the baselines (update).
# Optional: SCREENS_START starts the app; SCREENS_BASE_URL is waited for and prefixes relative targets.
# senior-lead-Opus5.5-agent, 2026-11-02
set -euo pipefail
mode="${1:-check}"
[ -f acceptance/screens/pages.txt ] || { echo "No acceptance/screens/pages.txt: list the stand-in pages"; exit 1; }
if [ -n "${SCREENS_START:-}" ]; then
  bash -c "$SCREENS_START" > screens-server.log 2>&1 &
  for _ in $(seq 1 60); do curl -fsS -o /dev/null "$SCREENS_BASE_URL" && break; sleep 1; done
  curl -fsS -o /dev/null "$SCREENS_BASE_URL" || { echo "The app did not start:"; tail -20 screens-server.log; exit 1; }
fi
update=none
[ "$mode" = update ] && update=all
npx playwright test --config .github/scripts/screens.config.mjs --update-snapshots="$update"
