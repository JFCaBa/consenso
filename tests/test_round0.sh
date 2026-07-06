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

# round0 con diff explícito.
out="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$run_dir" "$tmp/.consenso/2026-07-06-1200" "imprime el run_dir en la ultima linea"
assert_contains "$(cat "$run_dir/codex.json")" "division por cero" "escribe codex.json"
assert_contains "$(cat "$run_dir/gemini.json")" "docstring" "escribe gemini.json"
assert_contains "$(cat "$run_dir/log.md")" "codex" "el log menciona a codex"

# Diff vacío -> exit 3.
printf '' > "$tmp/empty.txt"
assert_exit 3 bash "$SCRIPT" round0 --diff "$tmp/empty.txt" --workdir "$tmp"

# Un agente falla (rc!=0 y salida basura): el otro sigue, round0 no aborta.
out2="$(STUB_CODEX_RC=1 STUB_CODEX_OUT='boom' bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir2="$(printf '%s\n' "$out2" | tail -1)"
assert_eq "$(cat "$run_dir2/codex.json")" "[]" "codex fallido queda en []"
assert_contains "$(cat "$run_dir2/gemini.json")" "docstring" "gemini sigue funcionando"

rm -rf "$tmp"
echo "OK test_round0"
