#!/usr/bin/env bash
# Runs every offline scenario in its own Lua process. The persistence pair shares a saved-variables file.
set -uo pipefail
cd "$(dirname "$0")/.."
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
status=0
run() { lua5.1 tests/run.lua "$@" || status=1; }
run fresh "$tmp/saved.lua"
run persisted "$tmp/saved.lua"
for s in corrupt newer_schema store no_guild module_failure not_forever serializer members_ui migrate_guild_keys activities activities_ui events events_ui professions professions_ui bulletin analytics bulletin_ui blacklist blacklist_ui prices prices_ui; do run "$s"; done
run sync "$tmp/sync.lua"
run sync_relog "$tmp/sync.lua"
[ $status -eq 0 ] && echo "ALL PASSED" || echo "FAILURES"
exit $status
