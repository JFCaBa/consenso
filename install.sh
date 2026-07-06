#!/usr/bin/env bash
# Instala el slash command de consenso y deja consenso.sh ejecutable.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
commands_dir="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
mkdir -p "$commands_dir"
ln -sf "$HERE/commands/consenso.md" "$commands_dir/consenso.md"
chmod +x "$HERE/consenso.sh"
echo "Instalado: $commands_dir/consenso.md -> $HERE/commands/consenso.md"
