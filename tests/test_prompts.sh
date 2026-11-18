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
  assert_contains "$(cat "$P/$f.md")" "entrada hipotética" "prompts/$f.md marca las entradas hipotéticas"
done
assert_contains "$(cat "$P/alternativa.md")" "No ves esa" "alternativa diseña sin ver la propuesta"
assert_contains "$(cat "$P/alternativa.md")" "NO mires el repositorio" "alternativa no explora el repo"
assert_contains "$(cat "$HERE/../skills/consenso/SKILL.md")" "consenso.sh\" alternativa" "la skill dispara el rediseño a ciegas"

echo "OK test_prompts"
