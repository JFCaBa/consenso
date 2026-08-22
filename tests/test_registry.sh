#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

# El registro del repo es válido y sus ficheros de rol existen.
assert_exit 0 consenso_registry_validar "$HERE/../agents/registry.json"
for rol in $(jq -r '.agentes[].rol' "$HERE/../agents/registry.json"); do
  [ -f "$HERE/../$rol" ] || fail "falta el fichero de rol: $rol"
done

# Registros inválidos -> rc 65.
tmp="$(mktemp -d)"
printf '{"agentes":[]}' > "$tmp/vacio.json"
assert_exit 65 consenso_registry_validar "$tmp/vacio.json"
printf '{"agentes":[{"id":"MAL ID","bin":"x","lente":"l","rol":"r","prioridad":1,"prosa_argv":["a"],"json":{"via":"schema","argv":["a"],"salida":"stdout","extract":".x"}}]}' > "$tmp/id.json"
assert_exit 65 consenso_registry_validar "$tmp/id.json"
printf '{"agentes":[{"id":"a","bin":"x","lente":"l","rol":"r","prioridad":1,"prosa_argv":["a"],"json":{"via":"magia","argv":["a"],"salida":"stdout","extract":".x"}}]}' > "$tmp/via.json"
assert_exit 65 consenso_registry_validar "$tmp/via.json"
printf '{"agentes":[{"id":"a","bin":"x","lente":"l","rol":"r","prioridad":1,"prosa_argv":["a"],"json":{"via":"schema","argv":["a"],"salida":"stdout","extract":"map(.x)"}}]}' > "$tmp/extract.json"
assert_exit 65 consenso_registry_validar "$tmp/extract.json"

# Acceso a agentes.
assert_contains "$(consenso_agente_json codex)" '"id":"codex"' "devuelve el objeto de codex"
assert_exit 2 consenso_agente_json inexistente
assert_eq "$(consenso_rol_de agy)" "prompts/agy.md" "rol de agy"

# Overrides por entorno.
assert_eq "$(consenso_bin_de codex)" "codex" "bin por defecto"
assert_eq "$(CONSENSO_CODEX_BIN=/tmp/otro consenso_bin_de codex)" "/tmp/otro" "override de bin"
assert_eq "$(consenso_model_de agy)" "Gemini 3.5 Flash (High)" "modelo por defecto"
assert_eq "$(CONSENSO_AGY_MODEL=OtroModelo consenso_model_de agy)" "OtroModelo" "override de modelo"
assert_eq "$(consenso_model_de codex)" "" "sin modelo_default -> vacío"
assert_eq "$(consenso_timeout_de codex)" "120" "timeout global por defecto"
assert_eq "$(CONSENSO_TIMEOUT=7 consenso_timeout_de codex)" "7" "override global de timeout"

rm -rf "$tmp"
echo "OK test_registry"
