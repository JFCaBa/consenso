#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
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
assert_exit 0 bash -c ". '$HERE/../consenso.sh'; CONSENSO_CODEX_BIN='$CONSENSO_CODEX_BIN' consenso_agent_with_retry codex p '$tmp/g.json'"

# retry: 1a llamada falla (transitorio), 2a llamada (mismo prompt) responde
# bien -> rc 0 y contenido válido en el out.
: > "$tmp/rs.counter"
STUB_CODEX_COUNTER="$tmp/rs.counter" \
STUB_CODEX_FAIL_FIRST=1 \
consenso_agent_with_retry codex "p" "$tmp/rs.json"
rc=$?
assert_eq "$rc" "0" "reintenta tras fallo transitorio y acierta"
assert_contains "$(cat "$tmp/rs.json")" "severidad" "el out conserva el hallazgo de la 2a llamada"

# retry: el 1er intento falla con un error real en stderr; el 2o intento
# agota igual pero sin escribir nada en stderr. run_agent_json reabre
# $out.err con ">" en cada llamada, así que el 2o intento no debe borrar el
# diagnóstico del 1o: es la única pista real que tenemos del fallo.
: > "$tmp/errperdido.counter"
STUB_CODEX_COUNTER="$tmp/errperdido.counter" \
STUB_CODEX_STDERR_FIRST="fallo real: conexion rechazada" \
STUB_CODEX_RC=1 \
consenso_agent_with_retry codex "p" "$tmp/errperdido.json"
rc=$?
assert_eq "$rc" "1" "retry agotado devuelve 1 (con error real en el 1er intento)"
assert_contains "$(cat "$tmp/errperdido.json.err")" "fallo real: conexion rechazada" \
  "el error real del 1er intento no se pierde aunque el 2o intento sea mudo"
case "$(cat "$tmp/errperdido.json.err")" in
  *"intento 2:"*) fail "no debe fabricarse una sección 'intento 2:' si el 2o intento fue mudo" ;;
esac

# retry: ambos intentos fallan con un error real y DISTINTO cada uno -> los
# dos deben quedar en $out.err, correctamente etiquetados (y no perderse el
# del 2o intento por la sobreescritura de $out.err vía el bloque compuesto).
: > "$tmp/errdoble.counter"
STUB_CODEX_COUNTER="$tmp/errdoble.counter" \
STUB_CODEX_STDERR_FIRST="fallo real intento 1: timeout de conexion" \
STUB_CODEX_STDERR_SECOND="fallo real intento 2: rate limit excedido" \
STUB_CODEX_RC=1 \
consenso_agent_with_retry codex "p" "$tmp/errdoble.json"
rc=$?
assert_eq "$rc" "1" "retry agotado devuelve 1 (con error real en ambos intentos)"
out_err="$(cat "$tmp/errdoble.json.err")"
assert_contains "$out_err" "fallo real intento 1: timeout de conexion" \
  "se conserva el error real del 1er intento"
assert_contains "$out_err" "fallo real intento 2: rate limit excedido" \
  "se conserva el error real del 2o intento, no se pierde por el truncado del bloque compuesto"

rm -rf "$tmp"
echo "OK test_validate_retry"
