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

# Timeout: el stub duerme 5s pero el timeout es 1s -> rc 124. Registro sin
# timeout propio para que mande CONSENSO_TIMEOUT.
registro_sin_timeouts "$tmp/sin-timeouts.json"
assert_exit 124 bash -c "export STUB_CODEX_SLEEP=5 CONSENSO_TIMEOUT=1 CONSENSO_REGISTRY='$tmp/sin-timeouts.json' CONSENSO_CODEX_BIN='$CONSENSO_CODEX_BIN'; . '$HERE/../consenso.sh'; run_agent codex x '$tmp/slow2.json'"

# El timeout mata también los descendientes del launcher. Si el hijo sobrevive,
# podría escribir una respuesta tardía encima del raw de un reintento posterior.
late="$tmp/respuesta-tardia"
assert_exit 124 run_with_timeout 1 bash -c '(sleep 2; printf late > "$1") & sleep 5' _ "$late"
sleep 2
assert_exit 1 test -e "$late"

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

# Salida JSON generalizada: veredictos con su esquema, clave y formato.
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
P="$HERE/../prompts"
V1='[{"punto":"P1","veredicto":"cedo","argumento":"x"}]'
STUB_CODEX_OUT="$V1" run_agent_json codex "p" "$tmp/v-codex.json" "$P/veredictos.schema.json" veredictos "$P/_formato_veredictos.md"
assert_eq "$(jq -r '.[0].veredicto' "$tmp/v-codex.json")" "cedo" "codex: veredictos por esquema"
STUB_AGY_OUT="$V1" run_agent_json agy "p" "$tmp/v-agy.json" "$P/veredictos.schema.json" veredictos "$P/_formato_veredictos.md"
assert_eq "$(jq -r '.[0].veredicto' "$tmp/v-agy.json")" "cedo" "agy: veredictos por esquema"
STUB_QWEN_ARGS_FILE="$tmp/qwen-args.txt" STUB_QWEN_OUT="$(printf '```json\n%s\n```' "$V1")" \
  run_agent_json qwen "p" "$tmp/v-qwen.json" "$P/veredictos.schema.json" veredictos "$P/_formato_veredictos.md"
assert_eq "$(jq -r '.[0].veredicto' "$tmp/v-qwen.json")" "cedo" "qwen: veredictos entre fences"
assert_contains "$(cat "$tmp/qwen-args.txt")" "mantengo" "qwen: el prompt lleva el formato de veredictos"
case "$(cat "$tmp/qwen-args.txt")" in
  *severidad*) fail "qwen: el prompt de veredictos no lleva el formato de hallazgos" ;;
esac
# Contrato local de veredictos: enum y ids sin repetir.
assert_exit 1 env STUB_QWEN_OUT='[{"punto":"P1","veredicto":"acepto","argumento":"x"}]' \
  bash -c ". '$HERE/../consenso.sh'; consenso_agent_with_retry qwen p '$tmp/v-mal.json' '$P/veredictos.schema.json' veredictos '$P/_formato_veredictos.md'"
assert_exit 1 test -e "$tmp/v-mal.json"
assert_exit 1 env STUB_QWEN_OUT='[{"punto":"P1","veredicto":"cedo","argumento":"x"},{"punto":"P1","veredicto":"mantengo","argumento":"y"}]' \
  bash -c ". '$HERE/../consenso.sh'; consenso_agent_with_retry qwen p '$tmp/v-dup.json' '$P/veredictos.schema.json' veredictos '$P/_formato_veredictos.md'"
assert_exit 1 test -e "$tmp/v-dup.json"

# revise: un esquema con dos claves; del mismo raw salen hallazgos y seguimiento.
RS="$P/revise.schema.json"; RF="$P/_formato_revise.md"
SEG='[{"objecion":"O1","estado":"resuelta","argumento":"x"}]'
STUB_CODEX_SEGUIMIENTO="$SEG" run_agent_json codex "p" "$tmp/r-codex.json" "$RS" hallazgos "$RF"
assert_contains "$(cat "$tmp/r-codex.json")" "division por cero" "revise codex: hallazgos"
consenso_extraer_json codex "$tmp/r-codex.json.raw" "$tmp/r-codex.seg.json" seguimiento
assert_eq "$(jq -r '.[0].estado' "$tmp/r-codex.seg.json")" "resuelta" "revise codex: seguimiento del mismo raw"
STUB_AGY_SEGUIMIENTO="$SEG" run_agent_json agy "p" "$tmp/r-agy.json" "$RS" hallazgos "$RF"
consenso_extraer_json agy "$tmp/r-agy.json.raw" "$tmp/r-agy.seg.json" seguimiento
assert_eq "$(jq -r '.[0].estado' "$tmp/r-agy.seg.json")" "resuelta" "revise agy: seguimiento"
STUB_QWEN_ARGS_FILE="$tmp/qwen-r.txt" STUB_QWEN_OUT="$(printf '```json\n{"hallazgos":[],"seguimiento":%s}\n```' "$SEG")" \
  run_agent_json qwen "p" "$tmp/r-qwen.json" "$RS" hallazgos "$RF"
assert_eq "$(cat "$tmp/r-qwen.json")" "[]" "revise qwen: hallazgos del objeto"
consenso_extraer_json qwen "$tmp/r-qwen.json.raw" "$tmp/r-qwen.seg.json" seguimiento
assert_eq "$(jq -r '.[0].objecion' "$tmp/r-qwen.seg.json")" "O1" "revise qwen: seguimiento del objeto"
assert_contains "$(cat "$tmp/qwen-r.txt")" "sigue_abierta" "revise qwen: el prompt lleva el formato de revise"
# Contrato del seguimiento: estado, ids repetidos y ids que no estaban pendientes.
printf '[{"id":"O1"},{"id":"O2"}]' > "$tmp/pend.json"
printf '%s' "$SEG" > "$tmp/seg-ok.json"
assert_exit 0 consenso_validar_seguimiento "$tmp/seg-ok.json" "$tmp/pend.json"
printf '[]' > "$tmp/seg-vacio.json"
assert_exit 0 consenso_validar_seguimiento "$tmp/seg-vacio.json" "$tmp/pend.json"
printf '[{"objecion":"O1","estado":"quizas","argumento":"x"}]' > "$tmp/seg-1.json"
printf '[{"objecion":"O1","estado":"resuelta","argumento":"x"},{"objecion":"O1","estado":"sigue_abierta","argumento":"y"}]' > "$tmp/seg-2.json"
printf '[{"objecion":"O9","estado":"resuelta","argumento":"x"}]' > "$tmp/seg-3.json"
for f in seg-1 seg-2 seg-3; do
  assert_exit 1 consenso_validar_seguimiento "$tmp/$f.json" "$tmp/pend.json"
done

rm -rf "$tmp"
echo "OK test_run_agent"
