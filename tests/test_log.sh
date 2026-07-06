#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
tmp="$(mktemp -d)"

export CONSENSO_TIMESTAMP="2026-07-06-1200"
dir="$(consenso_run_dir "$tmp")"
assert_eq "$dir" "$tmp/.consenso/2026-07-06-1200" "run_dir usa el timestamp"
assert_exit 0 test -d "$dir"

consenso_init_log "$dir" "Revisión demo"
assert_contains "$(cat "$dir/log.md")" "Revisión demo" "init_log escribe el titulo"

consenso_log_append "$dir" "linea de prueba"
assert_contains "$(cat "$dir/log.md")" "linea de prueba" "log_append anade"

rm -rf "$tmp"
echo "OK test_log"
