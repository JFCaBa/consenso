#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
tmp="$(mktemp -d)"

# validate: array válido pasa, prosa no.
printf '%s' '[{"a":1}]' > "$tmp/ok.json"
assert_exit 0 consenso_validate_json "$tmp/ok.json"
printf '%s' 'esto no es json' > "$tmp/bad.json"
assert_exit 1 consenso_validate_json "$tmp/bad.json"

# retry: stub devuelve basura las dos veces -> out queda en [] y rc 1.
STUB_CODEX_OUT="basura no-json" consenso_agent_with_retry codex "p" "$tmp/r.json"
rc=$?
assert_eq "$rc" "1" "retry agotado devuelve 1"
assert_eq "$(cat "$tmp/r.json")" "[]" "retry agotado deja array vacio"

# retry: stub devuelve JSON válido -> rc 0.
assert_exit 0 bash -c ". '$HERE/../consenso.sh'; CONSENSO_CODEX_CMD='$CONSENSO_CODEX_CMD' consenso_agent_with_retry codex p '$tmp/g.json'"

# retry: primera llamada basura, segunda llamada (tras recordatorio) JSON válido -> rc 0 y contenido válido en el out.
: > "$tmp/rs.counter"
STUB_CODEX_COUNTER="$tmp/rs.counter" \
STUB_CODEX_OUT="basura no-json" \
STUB_CODEX_OUT2='[{"severidad":"menor","ubicacion":"x","problema":"y","propuesta":"z"}]' \
consenso_agent_with_retry codex "p" "$tmp/rs.json"
rc=$?
assert_eq "$rc" "0" "reintenta y acierta devuelve 0"
case "$(cat "$tmp/rs.json")" in
  *'"severidad"'*) : ;;
  *) echo "FAIL: out no contiene el JSON valido de la 2a llamada" >&2; exit 1 ;;
esac

# extract: salida con fence ```json ... ``` debe tolerarse (agentes reales suelen envolver así).
fenced='```json
[{"severidad":"menor","ubicacion":"x","problema":"fenced","propuesta":"z"}]
```'
STUB_CODEX_OUT="$fenced" consenso_agent_with_retry codex "p" "$tmp/fenced.json"
rc=$?
assert_eq "$rc" "0" "JSON con fence de codigo se acepta"
assert_exit 0 consenso_validate_json "$tmp/fenced.json"
assert_contains "$(cat "$tmp/fenced.json")" "fenced" "el out conserva el hallazgo del JSON con fence"

# extract: salida con prosa antes del array también debe tolerarse.
prosed='Aquí están los hallazgos:
[{"severidad":"menor","ubicacion":"x","problema":"prosed","propuesta":"z"}]'
STUB_CODEX_OUT="$prosed" consenso_agent_with_retry codex "p" "$tmp/prosed.json"
rc=$?
assert_eq "$rc" "0" "JSON con prosa delante se acepta"
assert_exit 0 consenso_validate_json "$tmp/prosed.json"
assert_contains "$(cat "$tmp/prosed.json")" "prosed" "el out conserva el hallazgo del JSON con prosa"

rm -rf "$tmp"
echo "OK test_validate_retry"
