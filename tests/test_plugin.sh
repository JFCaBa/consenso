#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

jq -e . "$ROOT/.claude-plugin/plugin.json" >/dev/null || fail "plugin.json no es JSON válido"
assert_eq "$(jq -r .name "$ROOT/.claude-plugin/plugin.json")" "consenso" "nombre del plugin"
jq -e .version "$ROOT/.claude-plugin/plugin.json" >/dev/null || fail "plugin.json sin version"

jq -e . "$ROOT/.claude-plugin/marketplace.json" >/dev/null || fail "marketplace.json no es JSON válido"
assert_eq "$(jq -r '.plugins[0].source' "$ROOT/.claude-plugin/marketplace.json")" "./" "marketplace apunta al propio repo"
assert_eq "$(jq -r '.plugins[0].name' "$ROOT/.claude-plugin/marketplace.json")" "consenso" "marketplace publica consenso"

skill="$ROOT/skills/consenso/SKILL.md"
[ -f "$skill" ] || fail "falta skills/consenso/SKILL.md"
frontmatter="$(sed -n '2,/^---$/p' "$skill")"
assert_contains "$frontmatter" "name: consenso" "frontmatter con name"
assert_contains "$frontmatter" "antes de commitear" "descripción auto-disparable"
assert_contains "$(cat "$skill")" 'CLAUDE_PLUGIN_ROOT' "la skill usa CLAUDE_PLUGIN_ROOT"

echo "OK test_plugin"
