#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
P="$HERE/../prompts"

for f in codex agy claude; do
  assert_exit 0 test -f "$P/$f.md"
  # Cada prompt de rol debe declarar el contrato de hallazgo.
  assert_contains "$(cat "$P/$f.md")" "severidad" "prompts/$f.md declara el contrato"
  assert_contains "$(cat "$P/$f.md")" "propuesta" "prompts/$f.md declara propuesta"
done

assert_contains "$(cat "$P/codex.md")" "edge-case" "codex declara su lente"
assert_contains "$(cat "$P/agy.md")" "arquitectura" "agy declara su lente"
assert_contains "$(cat "$P/agy.md")" "NO lances subagentes" "agy no debe explorar ni delegar"
assert_contains "$(cat "$P/claude.md")" "legibilidad" "claude declara su lente"

for f in codex agy qwen opencode claude; do
  assert_contains "$(cat "$P/$f.md")" "Calibra por realismo" "prompts/$f.md calibra por realismo"
  assert_contains "$(cat "$P/$f.md")" "hipotetica" "prompts/$f.md marca las entradas hipotéticas con el campo"
  case "$(cat "$P/$f.md")" in
    *"(\"entrada hipotética: …\")"*) fail "prompts/$f.md ya no debe pedir el prefijo de texto" ;;
  esac
done
assert_contains "$(cat "$P/alternativa.md")" "No ves esa" "alternativa diseña sin ver la propuesta"
assert_contains "$(cat "$P/alternativa.md")" "NO mires el repositorio" "alternativa no explora el repo"
assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "consenso.sh\" alternativa" "la skill dispara el rediseño a ciegas"
assert_contains "$(cat "$P/claude.md")" "fuera_de_alcance: true" "claude también marca lo ajeno al cambio"
# Contrato de triaje: dos booleanos obligatorios en el esquema y en el formato.
assert_exit 0 jq -e '.properties.hallazgos.items | (.required | index("fuera_de_alcance") and index("hipotetica")) and .properties.fuera_de_alcance.type=="boolean" and .properties.hipotetica.type=="boolean"' "$P/hallazgos.schema.json"
for f in _formato codex agy qwen opencode claude; do
  assert_contains "$(cat "$P/$f.md")" "\`fuera_de_alcance\`" "prompts/$f.md declara fuera_de_alcance"
  assert_contains "$(cat "$P/$f.md")" "\`false\`" "prompts/$f.md exige false explícito"
done
assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "**Fuera de alcance**" "la síntesis separa lo ajeno al cambio"
assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "no se debate" "lo ajeno al cambio no entra en el debate"

assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "fuera_de_alcance: true" "la skill filtra por el campo"
assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "hipotetica: true" "la regla del bucle usa el campo"
assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "**Revisor único**" "la skill sintetiza con un solo revisor"
assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "solo de Claude" "la skill cubre el revisor único que falló"
for f in "$HERE/../skills/consenso/SKILL.md" "$HERE/../README.md"; do
  case "$(cat "$f")" in
    *debilitado*) fail "$f ya no habla de consenso debilitado" ;;
  esac
done

echo "OK test_prompts"
