#!/usr/bin/env bash
# Runs every offline scenario in its own Lua process. The persistence pair shares a saved-variables file.
set -uo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
status=0
run() { lua5.1 tests/run.lua "$@" || status=1; }
run fresh "$tmp/saved.lua"
run persisted "$tmp/saved.lua"
for s in corrupt newer_schema store no_guild module_failure not_forever; do run "$s"; done
[ $status -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit $status
