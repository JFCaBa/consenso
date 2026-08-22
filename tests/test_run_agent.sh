#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
chmod +x "$CONSENSO_CODEX_BIN" "$CONSENSO_AGY_BIN"

tmp="$(mktemp -d)"

# run_agent codex captura JSON del stub.
run_agent codex "prompt de prueba" "$tmp/codex.json"
assert_contains "$(cat "$tmp/codex.json")" "division por cero" "codex escribe su salida"

# run_agent agy.
run_agent agy "prompt de prueba" "$tmp/agy.json"
assert_contains "$(cat "$tmp/agy.json")" "docstring" "agy escribe su salida"

# Timeout: el stub duerme 5s pero el timeout es 1s -> rc 124.
assert_exit 124 bash -c "export STUB_CODEX_SLEEP=5 CONSENSO_TIMEOUT=1 CONSENSO_CODEX_BIN='$CONSENSO_CODEX_BIN'; . '$HERE/../consenso.sh'; run_agent codex x '$tmp/slow2.json'"

# run_agent con id desconocido -> rc 2.
assert_exit 2 run_agent inexistente "p" "$tmp/x.json"

# prompt_via stdin: registro sintético con un agente que lee stdin.
reg="$tmp/registry-stdin.json"
cat > "$reg" <<'EOF'
{"agentes":[{"id":"lector","bin":"cat","lente":"l","rol":"prompts/codex.md","prioridad":1,
  "prompt_via":"stdin","prosa_argv":["-"],
  "json":{"via":"prompt","argv":["-"],"salida":"stdout","extract":"."}}]}
EOF
out_stdin="$( (CONSENSO_REGISTRY="$reg"; run_agent lector "hola por stdin" "$tmp/stdin.txt"); cat "$tmp/stdin.txt")"
assert_contains "$out_stdin" "hola por stdin" "prompt_via stdin entrega el prompt por stdin"

rm -rf "$tmp"
echo "OK test_run_agent"
