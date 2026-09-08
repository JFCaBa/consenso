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
# modelo_auto es opcional, pero si existe debe estar bien formado (args no vacío, match string).
printf '{"agentes":[{"id":"a","bin":"x","lente":"l","rol":"r","prioridad":1,"modelo_auto":{"args":[],"match":"x"},"prosa_argv":["a"],"json":{"via":"schema","argv":["a"],"salida":"stdout","extract":".x"}}]}' > "$tmp/modelo_auto.json"
assert_exit 65 consenso_registry_validar "$tmp/modelo_auto.json"

# Acceso a agentes.
assert_contains "$(consenso_agente_json codex)" '"id":"codex"' "devuelve el objeto de codex"
assert_exit 2 consenso_agente_json inexistente
assert_eq "$(consenso_rol_de agy)" "prompts/agy.md" "rol de agy"

# Propagación de rc 2 en accesores cuando no existe el agente.
assert_exit 2 consenso_rol_de inexistente
assert_exit 2 consenso_bin_de inexistente
assert_exit 2 consenso_model_de inexistente
assert_exit 2 consenso_timeout_de inexistente

# Overrides por entorno.
assert_eq "$(consenso_bin_de codex)" "codex" "bin por defecto"
assert_eq "$(CONSENSO_CODEX_BIN=/tmp/otro consenso_bin_de codex)" "/tmp/otro" "override de bin"

# Resolución de modelo de agy (con stub de `agy models`).
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
chmod +x "$CONSENSO_AGY_BIN"
# modelo_auto elige el ID flash-high MÁS NUEVO por orden de versión. El stub
# lista 3.10/3.9/3.8/... : debe ganar 3.10 (no 3.8 por comparación float, ni el
# modelo_default 3.8 por fallback) -> prueba resolución dinámica y orden real.
assert_eq "$(consenso_model_de agy)" "gemini-3.10-flash-high" "resolución dinámica: flash-high más nuevo (3.10 > 3.9 > 3.8)"
# El override por entorno gana sin consultar al CLI.
assert_eq "$(CONSENSO_AGY_MODEL=OtroModelo consenso_model_de agy)" "OtroModelo" "override de modelo"
# Si `agy models` no devuelve modelos, cae a modelo_default.
assert_eq "$(STUB_AGY_MODELS_EMPTY=1 consenso_model_de agy)" "gemini-3.8-flash-high" "fallback a modelo_default sin lista"
unset CONSENSO_AGY_BIN
assert_eq "$(consenso_model_de codex)" "" "sin modelo_default -> vacío"
assert_eq "$(consenso_timeout_de codex)" "120" "timeout global por defecto"
assert_eq "$(CONSENSO_TIMEOUT=7 consenso_timeout_de codex)" "7" "override global de timeout"

rm -rf "$tmp"
echo "OK test_registry"
