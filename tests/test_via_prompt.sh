#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"

tmp="$(mktemp -d)"

# qwen: sobre {"response":"```json ... ```"} -> array validado.
assert_exit 0 run_agent_json qwen "p" "$tmp/q.json"
assert_contains "$(cat "$tmp/q.json")" "sin test" "qwen: desenvuelve response y quita fences"
assert_exit 0 consenso_validate_json "$tmp/q.json"

# opencode: stdout con fences directamente -> array validado.
assert_exit 0 run_agent_json opencode "p" "$tmp/o.json"
assert_contains "$(cat "$tmp/o.json")" "error silenciado" "opencode: quita fences del stdout"

# Texto alrededor del JSON -> inválido (validación estricta, no rescate laxo).
STUB_OPENCODE_OUT='Aquí tienes: [{"severidad":"menor","ubicacion":"x","problema":"p","propuesta":"q"}] espero que sirva' \
  run_agent_json opencode "p" "$tmp/malo.json"
assert_exit 1 consenso_validate_json "$tmp/malo.json"

# El prompt JSON de un agente via prompt incluye las instrucciones de formato.
# (el stub no las ve, pero la función debe montarlas: se comprueba indirectamente
# con un stub 'espejo' que devuelve el prompt recibido)
cat > "$tmp/espejo" <<'EOF'
#!/usr/bin/env bash
last=""
for a in "$@"; do last="$a"; done
printf '{"response":"[]"}'
printf '%s' "$last" > "${STUB_ESPEJO_CAPTURA:-/dev/null}"
EOF
chmod +x "$tmp/espejo"
reg="$tmp/registry-espejo.json"
cat > "$reg" <<'EOF'
{"agentes":[{"id":"espejo","bin":"espejo","lente":"l","rol":"prompts/codex.md","prioridad":1,
  "prosa_argv":["{PROMPT}"],
  "json":{"via":"prompt","argv":["{PROMPT}"],"salida":"stdout","extract":".response"}}]}
EOF
CONSENSO_REGISTRY="$reg" CONSENSO_ESPEJO_BIN="$tmp/espejo" STUB_ESPEJO_CAPTURA="$tmp/captura.txt" \
  run_agent_json espejo "revisa esto" "$tmp/e.json"
assert_contains "$(cat "$tmp/captura.txt")" "Formato de salida" "via prompt añade _formato.md al prompt"

rm -rf "$tmp"
echo "OK test_via_prompt"
