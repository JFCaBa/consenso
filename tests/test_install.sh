#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

# La skill declara las piezas clave.
assert_contains "$(cat "$ROOT/skills/consenso/SKILL.md")" "round0" "la skill usa round0"
assert_contains "$(cat "$ROOT/skills/consenso/SKILL.md")" "Acordado" "la skill define el informe"
assert_contains "$(cat "$ROOT/skills/consenso/SKILL.md")" "punto crítico" "la skill lista puntos críticos"

# install.sh symlinka en el dir override.
tmp="$(mktemp -d)"
CLAUDE_COMMANDS_DIR="$tmp/commands" bash "$ROOT/install.sh"
assert_exit 0 test -L "$tmp/commands/consenso.md"
assert_contains "$(cat "$tmp/commands/consenso.md")" "skill" "el wrapper invoca la skill"
assert_exit 0 test -x "$ROOT/consenso.sh"

rm -rf "$tmp"
echo "OK test_install"
