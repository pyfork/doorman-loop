# doorman-loop

A bounded delivery loop for AI agents: two fix rounds, then a judge, then the
owner. Risky changes go to the owner; routine ones merge themselves.

## Who did what

| Work | Who |
|---|---|
| Writing the code | AI agents |
| Identifying the business problems | me |
| Translating them into technical solutions | me |
| Delivering those solutions | me |
| Taking ownership of the outcomes | me |

Comments signed `<role>-<model>-agent` name the agent role that wrote them.

## The loop

Each change meets these guards in order. They run on GitHub (rulesets,
Actions, a GitHub App), and none of them trusts the PR it checks.

| Step | Guard | What it stops |
|---|---|---|
| Before work | `pre-push` hook, agent hook `block-merge.sh` | the agent pushing to `main`, merging, or editing its own guards |
| Plan | locked checks: a fingerprint of the acceptance tests, set when the plan merges | weakening a test later: a change to a locked check blocks the merge |
| PR opened | `pr-lane.sh`, the risk map, `CODEOWNERS` | risky paths go to the owner; a new file named like `auth` or `ledger` outside the map fails |
| Checks | `locked-checks`: `main`'s copy of every locked check runs on the PR's code, as an unprivileged user, on the production runtime | a PR rewriting its own checks, forging results, or passing only on the wrong OS |
| Review | `slice-review`: an AI reviewer that runs from `main` and signs its verdict as a GitHub App | a PR rewriting its own judge |
| Fix rounds | `review-rounds.sh`: two fix rounds, a judge on what's left, then the owner; the round count is sealed with an HMAC in the app's own reviews | endless loops, and resetting the count with a force push |
| Merge | ruleset on `main`: the signed checks must be green; routine PRs auto-merge, risky ones need the owner's Approve | merging around the checks |
| After | `main-tripwire`, `daily-sweep`, `scan-locks.py` | a push that skipped a PR, ruleset drift, newly published vulnerabilities in pinned locks |

Every `uses:` in every workflow is pinned by commit hash (`pin-lint.sh`).

The reviewer's role and rules are not in this repository. The workflows
fetch them on every run, so a PR can't read them and tune itself to pass.

## Run the tests

```sh
bash guards/tests/run-all.sh
```

Needs bash, git, jq, openssl and python3. No network.

## Layout

| Path | What |
|---|---|
| `guards/templates/` | the workflows, scripts and hooks a project installs |
| `guards/hooks/pre-push` | the local push guard |
| `guards/stacks/` | the new-dependency check |
| `guards/tests/` | unit tests for all of the above |

MIT licensed. Security reports: [SECURITY.md](SECURITY.md).
