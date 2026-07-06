#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_GEMINI_CMD="$HERE/stubs/gemini"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
run_dir="$tmp/.consenso/2026-07-06-1200"
mkdir -p "$run_dir"
printf '# Punto en disputa\nCodex dice X, Gemini dice no-X.\n' > "$tmp/points.txt"

out="$(STUB_CODEX_OUT='Mantengo X porque...' STUB_GEMINI_OUT='Cedo, X es correcto.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir")"
rd="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$rd" "$run_dir" "debate imprime el run-dir"
assert_contains "$(cat "$run_dir/debate-1-codex.md")" "Mantengo X" "guarda respuesta de codex"
assert_contains "$(cat "$run_dir/debate-1-gemini.md")" "Cedo" "guarda respuesta de gemini"
assert_contains "$(cat "$run_dir/log.md")" "debate" "el log menciona el debate"

rm -rf "$tmp"
echo "OK test_debate"
