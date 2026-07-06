#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_GEMINI_CMD="$HERE/stubs/gemini"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
printf 'diff --git a/foo.py b/foo.py\n+return 1/0\n' > "$tmp/d.txt"

# round0
rd="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp" | tail -1)"
jq -e . "$rd/codex.json" >/dev/null || fail "codex.json no es JSON válido"
jq -e . "$rd/gemini.json" >/dev/null || fail "gemini.json no es JSON válido"

# debate encadenado sobre el mismo run_dir
printf 'Punto: division por cero. Codex importante, Gemini no lo ve.\n' > "$tmp/points.txt"
STUB_CODEX_OUT='Mantengo: es un fallo real.' STUB_GEMINI_OUT='Cedo.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$rd" --round 1 >/dev/null
assert_exit 0 test -f "$rd/debate-1-codex.md"

# el log acumula ambas fases
log="$(cat "$rd/log.md")"
assert_contains "$log" "Ronda 0" "log tiene round0"
assert_contains "$log" "debate ronda 1" "log tiene debate"

rm -rf "$tmp"
echo "OK test_e2e"
