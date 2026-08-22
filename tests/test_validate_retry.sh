#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_AGY_CMD="$HERE/stubs/agy"
tmp="$(mktemp -d)"

# validate: array válido pasa, prosa no.
printf '%s' '[{"a":1}]' > "$tmp/ok.json"
assert_exit 0 consenso_validate_json "$tmp/ok.json"
printf '%s' 'esto no es json' > "$tmp/bad.json"
assert_exit 1 consenso_validate_json "$tmp/bad.json"
# validate: un stream de varios arrays NO es un array único -> se rechaza.
printf '%s' '[1,2]
[3,4]' > "$tmp/stream.json"
assert_exit 1 consenso_validate_json "$tmp/stream.json"
# validate: un array vacío sí es válido (agente sin hallazgos).
printf '%s' '[]' > "$tmp/empty.json"
assert_exit 0 consenso_validate_json "$tmp/empty.json"
# validate: un objeto JSON no es un array -> se rechaza.
printf '%s' '{"a":1}' > "$tmp/obj.json"
assert_exit 1 consenso_validate_json "$tmp/obj.json"

# run_agent_json: el stub escribe {"hallazgos":[...]} en el fichero de -o;
# run_agent_json debe desenvolverlo a un array pelado.
assert_exit 0 run_agent_json codex "p" "$tmp/j.json"
assert_exit 0 consenso_validate_json "$tmp/j.json"
assert_contains "$(cat "$tmp/j.json")" "division por cero" "run_agent_json codex desenvuelve hallazgos"

assert_exit 0 run_agent_json agy "p" "$tmp/jg.json"
assert_exit 0 consenso_validate_json "$tmp/jg.json"
assert_contains "$(cat "$tmp/jg.json")" "docstring" "run_agent_json agy desenvuelve structured_output.hallazgos"

# run_agent_json: rc!=0 del CLI -> falla, sin tocar out.
STUB_CODEX_RC=1 run_agent_json codex "p" "$tmp/fail.json"
rc=$?
assert_eq "$rc" "1" "rc!=0 del CLI se propaga como fallo"

# run_agent_json: salida vacía (rc=0 pero -o vacío) -> falla.
STUB_CODEX_EMPTY=1 run_agent_json codex "p" "$tmp/empty2.json"
rc=$?
assert_eq "$rc" "1" "salida vacia se trata como fallo"

# retry: agente falla las dos veces -> out queda en [] y rc 1, con
# diagnóstico preservado en $out.err.
STUB_CODEX_RC=1 consenso_agent_with_retry codex "p" "$tmp/r.json"
rc=$?
assert_eq "$rc" "1" "retry agotado devuelve 1"
assert_eq "$(cat "$tmp/r.json")" "[]" "retry agotado deja array vacio"
assert_contains "$(cat "$tmp/r.json.err")" "no participante" "el diagnostico queda en out.err"

# retry: agente responde bien a la primera -> rc 0.
assert_exit 0 bash -c ". '$HERE/../consenso.sh'; CONSENSO_CODEX_CMD='$CONSENSO_CODEX_CMD' consenso_agent_with_retry codex p '$tmp/g.json'"

# retry: 1a llamada falla (transitorio), 2a llamada (mismo prompt) responde
# bien -> rc 0 y contenido válido en el out.
: > "$tmp/rs.counter"
STUB_CODEX_COUNTER="$tmp/rs.counter" \
STUB_CODEX_FAIL_FIRST=1 \
consenso_agent_with_retry codex "p" "$tmp/rs.json"
rc=$?
assert_eq "$rc" "0" "reintenta tras fallo transitorio y acierta"
assert_contains "$(cat "$tmp/rs.json")" "severidad" "el out conserva el hallazgo de la 2a llamada"

rm -rf "$tmp"
echo "OK test_validate_retry"
