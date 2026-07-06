#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

# El command declara las piezas clave.
assert_contains "$(cat "$ROOT/commands/consenso.md")" "round0" "el command usa round0"
assert_contains "$(cat "$ROOT/commands/consenso.md")" "Acordado" "el command define el informe"
assert_contains "$(cat "$ROOT/commands/consenso.md")" "punto crítico" "el command lista puntos críticos"

# install.sh symlinka en el dir override.
tmp="$(mktemp -d)"
CLAUDE_COMMANDS_DIR="$tmp/commands" bash "$ROOT/install.sh"
assert_exit 0 test -L "$tmp/commands/consenso.md"
assert_contains "$(cat "$tmp/commands/consenso.md")" "round0" "el symlink apunta al command real"
assert_exit 0 test -x "$ROOT/consenso.sh"

rm -rf "$tmp"
echo "OK test_install"
