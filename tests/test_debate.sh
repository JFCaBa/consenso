#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
run_dir="$tmp/.consenso/2026-07-06-1200"
mkdir -p "$run_dir"
printf '# Punto en disputa\nCodex dice X, Agy dice no-X.\n' > "$tmp/points.txt"

out="$(STUB_CODEX_OUT='Mantengo X porque...' STUB_AGY_OUT='Cedo, X es correcto.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir")"
rd="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$rd" "$run_dir" "debate imprime el run-dir"
assert_contains "$(cat "$run_dir/debate-1-codex.md")" "Mantengo X" "guarda respuesta de codex"
assert_contains "$(cat "$run_dir/debate-1-agy.md")" "Cedo" "guarda respuesta de agy"
assert_contains "$(cat "$run_dir/log.md")" "debate" "el log menciona el debate"

out2="$(STUB_CODEX_OUT='Mantengo X porque...' STUB_AGY_OUT='Cedo, X es correcto.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir" --round 2)"
rd2="$(printf '%s\n' "$out2" | tail -1)"
assert_eq "$rd2" "$run_dir" "debate --round 2 imprime el run-dir"
assert_contains "$(cat "$run_dir/debate-2-codex.md")" "Mantengo X" "guarda respuesta de codex en ronda 2"
assert_contains "$(cat "$run_dir/debate-2-agy.md")" "Cedo" "guarda respuesta de agy en ronda 2"

# Un agente falla (rc!=0): el log debe reflejar NO respondió para ese agente,
# mientras el otro sigue mostrando "respondió".
out3="$(STUB_CODEX_RC=1 STUB_CODEX_OUT='boom' STUB_AGY_OUT='Cedo, X es correcto.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir" --round 3)"
rd3="$(printf '%s\n' "$out3" | tail -1)"
log3="$(cat "$rd3/log.md")"
assert_contains "$log3" "debate ronda 3: codex NO respondió" "el log marca a codex como NO respondió"
assert_contains "$log3" "debate ronda 3: agy respondió" "el log marca a agy como respondió"

# La instrucción del debate se adapta al modo persistido por round0.
. "$SCRIPT"
sin_modo="$(consenso_debate_instruccion "$tmp")"
assert_contains "$sin_modo" "revisión de código" "sin fichero de modo: instrucción de código"
printf 'plan' > "$run_dir/modo"
con_plan="$(consenso_debate_instruccion "$run_dir")"
assert_contains "$con_plan" "plan de implementación" "modo plan: instrucción de plan"
case "$con_plan" in
  *"revisión de código"*) fail "modo plan: no debe hablar de revisión de código" ;;
esac

# Guards de uso: un flag que espera valor pero es el último token -> rc 64 (no crash set -u).
assert_exit 64 bash "$SCRIPT" debate --points
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir" --round

rm -rf "$tmp"
echo "OK test_debate"
