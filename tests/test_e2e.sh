#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
printf 'diff --git a/foo.py b/foo.py\n+return 1/0\n' > "$tmp/d.txt"

# round0
rd="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp" | tail -1)"
jq -e . "$rd/codex.json" >/dev/null || fail "codex.json no es JSON válido"
jq -e . "$rd/agy.json" >/dev/null || fail "agy.json no es JSON válido"
jq -e . "$rd/qwen.json" >/dev/null || fail "qwen.json no es JSON válido"
jq -e . "$rd/opencode.json" >/dev/null || fail "opencode.json no es JSON válido"

# debate encadenado sobre el mismo run_dir: puntos JSON, veredictos JSON
printf '[{"id":"P1","punto":"division por cero","posturas":"Codex importante, Agy no lo ve"}]' > "$tmp/points.json"
V='[{"punto":"P1","veredicto":"mantengo","argumento":"es un fallo real"}]'
STUB_CODEX_OUT="$V" STUB_AGY_OUT="$V" STUB_QWEN_OUT="$V" STUB_OPENCODE_OUT="$V" \
  bash "$SCRIPT" debate --points "$tmp/points.json" --run-dir "$rd" --round 1 >/dev/null
for id in codex agy qwen opencode; do
  assert_eq "$(jq -r '.[0].veredicto' "$rd/debate-1-$id.json")" "mantengo" "debate-1-$id.json con veredicto"
done

# el log acumula ambas fases
log="$(cat "$rd/log.md")"
assert_contains "$log" "Ronda 0" "log tiene round0"
assert_contains "$log" "debate ronda 1" "log tiene debate"

rm -rf "$tmp"
echo "OK test_e2e"
