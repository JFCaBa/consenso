#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
P="$HERE/../prompts"

for f in codex gemini claude; do
  assert_exit 0 test -f "$P/$f.md"
  # Cada prompt de rol debe declarar el contrato de hallazgo.
  assert_contains "$(cat "$P/$f.md")" "severidad" "prompts/$f.md declara el contrato"
  assert_contains "$(cat "$P/$f.md")" "propuesta" "prompts/$f.md declara propuesta"
done

assert_contains "$(cat "$P/codex.md")" "edge-case" "codex declara su lente"
assert_contains "$(cat "$P/gemini.md")" "arquitectura" "gemini declara su lente"
assert_contains "$(cat "$P/claude.md")" "legibilidad" "claude declara su lente"

echo "OK test_prompts"
