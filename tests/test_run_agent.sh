#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_GEMINI_CMD="$HERE/stubs/gemini"
chmod +x "$CONSENSO_CODEX_CMD" "$CONSENSO_GEMINI_CMD"

tmp="$(mktemp -d)"

# run_agent codex captura JSON del stub.
run_agent codex "prompt de prueba" "$tmp/codex.json"
assert_contains "$(cat "$tmp/codex.json")" "division por cero" "codex escribe su salida"

# run_agent gemini.
run_agent gemini "prompt de prueba" "$tmp/gemini.json"
assert_contains "$(cat "$tmp/gemini.json")" "docstring" "gemini escribe su salida"

# Timeout: el stub duerme 5s pero el timeout es 1s -> rc 124.
STUB_CODEX_SLEEP=5 CONSENSO_TIMEOUT=1 run_agent codex "x" "$tmp/slow.json"
assert_exit 124 bash -c "export STUB_CODEX_SLEEP=5 CONSENSO_TIMEOUT=1 CONSENSO_CODEX_CMD='$CONSENSO_CODEX_CMD'; . '$HERE/../consenso.sh'; run_agent codex x '$tmp/slow2.json'"

rm -rf "$tmp"
echo "OK test_run_agent"
