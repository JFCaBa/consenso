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

# round0 con diff explícito.
out="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$run_dir" "$tmp/.consenso/2026-07-06-1200" "imprime el run_dir en la ultima linea"
assert_contains "$(cat "$run_dir/codex.json")" "division por cero" "escribe codex.json"
assert_contains "$(cat "$run_dir/agy.json")" "docstring" "escribe agy.json"
assert_contains "$(cat "$run_dir/log.md")" "codex" "el log menciona a codex"
assert_eq "$(cat "$run_dir/modo")" "diff" "diff: persiste el modo en run_dir"

# Elenco completo: 4 agentes -> 4 json + fichero agentes.
out4="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir4="$(printf '%s\n' "$out4" | tail -1)"
assert_eq "$(cat "$run_dir4/agentes")" "codex
agy
qwen
opencode" "persiste el elenco completo en orden"
assert_contains "$(cat "$run_dir4/qwen.json")" "sin test" "escribe qwen.json"
assert_contains "$(cat "$run_dir4/opencode.json")" "error silenciado" "escribe opencode.json"

# Degradación a 1 -> aviso.
out1="$(CONSENSO_AGENTS=codex bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir1="$(printf '%s\n' "$out1" | tail -1)"
assert_contains "$(cat "$run_dir1/log.md")" "consenso debilitado" "avisa con 1 solo agente"

# CONSENSO_AGENTS con id desconocido: consenso_detectar devuelve rc 64, y ese
# rc no debe perderse tras la limpieza del content_tmp en round0.
assert_exit 64 env CONSENSO_AGENTS=codex,noexiste bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"

# 0 agentes -> rc 4.
assert_exit 4 env CONSENSO_CODEX_BIN=/no/existe CONSENSO_AGY_BIN=/no/existe \
  CONSENSO_QWEN_BIN=/no/existe CONSENSO_OPENCODE_BIN=/no/existe \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"

# Diff vacío -> exit 3.
printf '' > "$tmp/empty.txt"
assert_exit 3 bash "$SCRIPT" round0 --diff "$tmp/empty.txt" --workdir "$tmp"

# Un agente falla (rc!=0 y salida basura): el otro sigue, round0 no aborta.
out2="$(STUB_CODEX_RC=1 STUB_CODEX_OUT='boom' bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir2="$(printf '%s\n' "$out2" | tail -1)"
assert_eq "$(cat "$run_dir2/codex.json")" "[]" "codex fallido queda en []"
assert_contains "$(cat "$run_dir2/agy.json")" "docstring" "agy sigue funcionando"

# round0 con --plan: revisa el plan como prosa y lo marca en el log.
printf '# Plan\n1. Anadir endpoint\n2. Migrar tabla usuarios\n' > "$tmp/plan.md"
out3="$(bash "$SCRIPT" round0 --plan "$tmp/plan.md" --workdir "$tmp")"
run_dir3="$(printf '%s\n' "$out3" | tail -1)"
assert_contains "$(cat "$run_dir3/codex.json")" "division por cero" "plan: escribe codex.json"
assert_contains "$(cat "$run_dir3/agy.json")" "docstring" "plan: escribe agy.json"
assert_contains "$(cat "$run_dir3/log.md")" "plan" "plan: el log distingue el modo"
assert_eq "$(cat "$run_dir3/modo")" "plan" "plan: persiste el modo en run_dir"

# Si la construcción del prompt falla (rol inexistente), round0 aborta limpio.
( . "$SCRIPT"; CONSENSO_HOME="/no/existe"; cmd_round0 --diff "$tmp/d.txt" --workdir "$tmp" ) >/dev/null 2>&1
assert_eq "$?" "2" "round0 aborta si falla la construcción del prompt"

# Plan vacío -> exit 3 (igual que diff vacío).
assert_exit 3 bash "$SCRIPT" round0 --plan "$tmp/empty.txt" --workdir "$tmp"

# --plan y --diff a la vez: excluyentes -> error de uso.
assert_exit 64 bash "$SCRIPT" round0 --plan "$tmp/plan.md" --diff "$tmp/d.txt" --workdir "$tmp"

# flag sin valor (última posición): error de uso limpio, no crash por set -u.
assert_exit 64 bash "$SCRIPT" round0 --workdir
assert_exit 64 bash "$SCRIPT" round0 --diff
assert_exit 64 bash "$SCRIPT" round0 --plan

rm -rf "$tmp"
echo "OK test_round0"
