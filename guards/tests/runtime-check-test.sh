#!/usr/bin/env bash
# guard-builder-Opus5.5-agent, 2026-10-25
# Unit test for templates/.github/scripts/runtime-check.sh. Stub language
# binaries and an os-release fixture stand in for the runner: a good record
# and a matching machine pass; each slip must fail and name itself.
# Run from anywhere: bash guards/tests/runtime-check-test.sh
set -uo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../templates/.github/scripts/runtime-check.sh"
work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
fails=0

# --- stubs: each language reports the version in $HAVE
mkdir -p "$work/bin"
printf '#!/bin/sh\necho "$HAVE"\n' > "$work/bin/python3"
printf '#!/bin/sh\necho "go$HAVE"\n' > "$work/bin/go"
printf '#!/bin/sh\necho "openjdk version \\"$HAVE\\" 2024-07-16" >&2\n' > "$work/bin/java"
printf '#!/bin/sh\necho "$HAVE"\n' > "$work/bin/node"
chmod +x "$work/bin/"*
printf 'ID=ubuntu\nVERSION_ID="22.04"\n' > "$work/os-2204"
printf 'ID=ubuntu\nVERSION_ID="24.04"\n' > "$work/os-2404"

record() { # record <name> <body>: write a record file
  printf '%b' "$2" > "$work/$1.env"
}
good='RUNNER=ubuntu-22.04   # server release\nOS=ubuntu 22.04\nRUNTIME=python 3.10\nINSTALL=scripts/install.sh\n'

# expect <id> <want: pass|fail> <text> <mode> <record> <have version> <os-release>
expect() {
  out="$(HAVE="$6" OS_RELEASE="$work/$7" PATH="$work/bin:$PATH" bash "$script" "$4" "$work/$5.env" 2>&1)"; rc=$?
  if [ "$2" = pass ] && [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q -- "$3"; then echo "PASS $1: $3"
  elif [ "$2" = fail ] && [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q -- "$3"; then echo "PASS $1: $3"
  else echo "FAIL $1: expected $2 with '$3', got rc=$rc:"; echo "$out" | sed 's/^/    /'; fails=1; fi
}

record good "$good"
expect T1 pass "runner=ubuntu-22.04" record good "" os-2204
expect T2 pass "version=3.10" record good "" os-2204
expect T3 pass "RUNTIME python 3.10.12 on ubuntu 22.04: matches" machine good 3.10.12 os-2204

# The record: missing, empty, moving or vague values fail closed
expect T4 fail "no runtime record" record missing "" os-2204
record noos 'RUNNER=ubuntu-22.04\nRUNTIME=python 3.10\nINSTALL=scripts/install.sh\n'
expect T5 fail "OS is empty" record noos "" os-2204
record latest 'RUNNER=ubuntu-latest\nOS=ubuntu 24.04\nRUNTIME=python 3.12\nINSTALL=x\n'
expect T6 fail "moving label" record latest "" os-2204
record split 'RUNNER=ubuntu-24.04\nOS=ubuntu 22.04\nRUNTIME=python 3.10\nINSTALL=x\n'
expect T7 fail "runs ubuntu 24.04, but OS says" record split "" os-2204
record lang 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=ruby 3.3\nINSTALL=x\n'
expect T8 fail "language must be" record lang "" os-2204
record ver 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=python latest\nINSTALL=x\n'
expect T9 fail "version must be" record ver "" os-2204
record nojdk 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=java 21\nINSTALL=x\n'
expect T10 fail "JDK is empty" record nojdk "" os-2204

# Allow-list: only known keys, each once; a
# rejected value is never printed, since CI logs on a public repo are public
base='RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=python 3.10\n'
record extra "${base}INSTALL=scripts/install.sh\nSERVER=203.0.113.7\n"
expect T20 fail "line 5 has key SERVER; only RUNNER" record extra "" os-2204
out="$(bash "$script" record "$work/extra.env" 2>&1)"
if printf '%s' "$out" | grep -q 203.0.113.7; then echo "FAIL T21: the rejected value was printed"; fails=1; else echo "PASS T21: the rejected value is not printed"; fi
record notkv "${base}INSTALL=scripts/install.sh\nexport TOKEN=abc\n"
expect T22 fail "line 5 is not KEY=value" record notkv "" os-2204
record twice "${base}RUNTIME=python 3.12\nINSTALL=scripts/install.sh\n"
expect T23 fail "RUNTIME is set more than once" record twice "" os-2204
record spaced "${base}INSTALL=bash scripts/install.sh && curl x\n"
expect T24 fail "INSTALL must be a path inside the repo" record spaced "" os-2204
record up "${base}INSTALL=../other/install.sh\n"
expect T25 fail "must not leave the repo" record up "" os-2204
record abs "${base}INSTALL=/usr/local/bin/install\n"
expect T26 fail "INSTALL must be a path inside the repo" record abs "" os-2204
record badjdk 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=java 21\nINSTALL=scripts/build.sh\nJDK=temurin; rm -rf /\n'
expect T27 fail "JDK must be a distribution name" record badjdk "" os-2204
record jdkpy "${base}INSTALL=scripts/install.sh\nJDK=temurin\n"
expect T28 fail "JDK is set, but RUNTIME is not java" record jdkpy "" os-2204
record comments "# heading\n\n  # indented comment\n${base}INSTALL=./scripts/install.sh   # trailing\n"
expect T29 pass "install=./scripts/install.sh" record comments "" os-2204

# The machine: the original gap (3.12 on 24.04), a near-miss version, the OS
expect T11 fail "FAIL RUNTIME: the record says python 3.10 on ubuntu 22.04; this runner has python 3.12.3 on ubuntu 24.04" machine good 3.12.3 os-2404
expect T12 fail "FAIL RUNTIME" machine good 3.1 os-2204
expect T13 fail "FAIL RUNTIME" machine good 3.100.1 os-2204
expect T14 fail "on ubuntu 24.04" machine good 3.10.12 os-2404
record exact 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=python 3.10.12\nINSTALL=x\n'
expect T15 fail "FAIL RUNTIME" machine exact 3.10.14 os-2204
expect T16 fail "not found" machine good "" os-2204

# Other languages read their own version command
record go 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=go 1.23\nINSTALL=scripts/build.sh\n'
expect T17 pass "RUNTIME go 1.23.4" machine go 1.23.4 os-2204
record java 'RUNNER=ubuntu-22.04\nOS=ubuntu 22.04\nRUNTIME=java 21\nINSTALL=scripts/build.sh\nJDK=temurin\n'
expect T18 pass "RUNTIME java 21.0.4" machine java 21.0.4 os-2204
expect T19 fail "FAIL RUNTIME" machine java 17.0.12 os-2204

# TOOLS (apt names) and CHECK_ENV (NAME=/absolute/path), both
# optional; a record without them prints empty values, as before
expect T30 pass "tools=$" record good "" os-2204
expect T31 pass "check_env=$" record good "" os-2204
record tools "${base}INSTALL=scripts/install.sh\nTOOLS=poppler-utils chromium   # pdf and browser\nCHECK_ENV=APP_CHROME=/usr/bin/google-chrome X_2=/opt/a/b\n"
expect T32 pass "tools=poppler-utils chromium" record tools "" os-2204
expect T33 pass "check_env=APP_CHROME=/usr/bin/google-chrome X_2=/opt/a/b" record tools "" os-2204
record badtool "${base}INSTALL=x\nTOOLS=poppler-utils;curl\n"
expect T34 fail "TOOLS must be apt package names" record badtool "" os-2204
record globtool "${base}INSTALL=x\nTOOLS=*\n"
expect T35 fail "TOOLS must be apt package names" record globtool "" os-2204
record relenv "${base}INSTALL=x\nCHECK_ENV=CHROME=usr/bin/chrome\n"
expect T36 fail "CHECK_ENV must be NAME=/absolute/path" record relenv "" os-2204
record homeenv "${base}INSTALL=x\nCHECK_ENV=HOME=/root\n"
expect T37 fail "CHECK_ENV can't set HOME" record homeenv "" os-2204
record ldenv "${base}INSTALL=x\nCHECK_ENV=LD_PRELOAD=/tmp/x.so\n"
expect T38 fail "CHECK_ENV can't set LD_PRELOAD" record ldenv "" os-2204
record upenv "${base}INSTALL=x\nCHECK_ENV=CHROME=/usr/../tmp/chrome\n"
expect T39 fail "must not contain .." record upenv "" os-2204
record valenv "${base}INSTALL=x\nCHECK_ENV=CHROME=/usr/bin/x\$(id)\n"
expect T40 fail "CHECK_ENV must be NAME=/absolute/path" record valenv "" os-2204

[ "$fails" -eq 0 ] && echo "runtime-check-test: all passed" || echo "runtime-check-test: FAILED"
exit "$fails"
