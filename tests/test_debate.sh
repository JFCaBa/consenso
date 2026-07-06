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

out2="$(STUB_CODEX_OUT='Mantengo X porque...' STUB_GEMINI_OUT='Cedo, X es correcto.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir" --round 2)"
rd2="$(printf '%s\n' "$out2" | tail -1)"
assert_eq "$rd2" "$run_dir" "debate --round 2 imprime el run-dir"
assert_contains "$(cat "$run_dir/debate-2-codex.md")" "Mantengo X" "guarda respuesta de codex en ronda 2"
assert_contains "$(cat "$run_dir/debate-2-gemini.md")" "Cedo" "guarda respuesta de gemini en ronda 2"

# Un agente falla (rc!=0): el log debe reflejar NO respondió para ese agente,
# mientras el otro sigue mostrando "respondió".
out3="$(STUB_CODEX_RC=1 STUB_CODEX_OUT='boom' STUB_GEMINI_OUT='Cedo, X es correcto.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir" --round 3)"
rd3="$(printf '%s\n' "$out3" | tail -1)"
log3="$(cat "$rd3/log.md")"
assert_contains "$log3" "debate ronda 3: codex NO respondió" "el log marca a codex como NO respondió"
assert_contains "$log3" "debate ronda 3: gemini respondió" "el log marca a gemini como respondió"

rm -rf "$tmp"
echo "OK test_debate"
