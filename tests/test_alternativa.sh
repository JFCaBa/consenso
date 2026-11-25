#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
export CONSENSO_AGENTS="codex,agy"
export CONSENSO_TIMESTAMP="2026-11-18-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
tmp="$(cd "$tmp" && pwd)"
printf 'Limitar llamadas a Overpass ante 429. Datos reales: 1 solo 429 en la medición.\n' > "$tmp/problema.md"

# Por defecto: el agente de mayor prioridad del elenco (codex).
out="$(cd "$tmp" && STUB_CODEX_OUT='Enfoque: Retry-After o 30 s fijos.' \
  bash "$SCRIPT" alternativa --problem "$tmp/problema.md")"
rd="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$rd" "$tmp/.consenso/2026-11-18-1200" "imprime el run-dir absoluto"
assert_contains "$(cat "$rd/alternativa-codex.md")" "Retry-After" "guarda el diseño de codex"
assert_contains "$(cat "$rd/log.md")" "Rediseño a ciegas (codex)" "el log titula el rediseño"
assert_contains "$(cat "$rd/log.md")" "alternativa: codex respondió" "el log registra la respuesta"

# --agent elige otro agente del elenco.
export CONSENSO_TIMESTAMP="2026-11-18-1201"
out="$(cd "$tmp" && STUB_AGY_OUT='Diseño de agy' \
  bash "$SCRIPT" alternativa --problem "$tmp/problema.md" --agent agy)"
rd="$(printf '%s\n' "$out" | tail -1)"
assert_contains "$(cat "$rd/alternativa-agy.md")" "Diseño de agy" "--agent agy usa agy"

# A ciegas: el agente corre fuera del repo y el prompt lleva enunciado + rol,
# nunca el diff.
fake="$tmp/fake-codex"
cat > "$fake" <<'EOF'
#!/usr/bin/env bash
echo "CWD=$(pwd)"
cat  # el prompt llega por stdin
EOF
chmod +x "$fake"
export CONSENSO_TIMESTAMP="2026-11-18-1202"
out="$(cd "$tmp" && CONSENSO_CODEX_BIN="$fake" \
  bash "$SCRIPT" alternativa --problem "$tmp/problema.md")"
rd="$(printf '%s\n' "$out" | tail -1)"
resp="$(cat "$rd/alternativa-codex.md")"
case "$resp" in
  *"CWD=$tmp"*) fail "el agente no debe correr dentro del workdir" ;;
esac
assert_contains "$resp" "No ves esa" "el prompt incluye el rol de rediseño"
assert_contains "$resp" "1 solo 429" "el prompt incluye el enunciado"

# Rutas relativas (binario y registro) siguen valiendo tras el cd al dir ciego.
mkdir -p "$tmp/bin"
cp "$fake" "$tmp/bin/codex-rel"
cp "$HERE/../agents/registry.json" "$tmp/reg.json"
export CONSENSO_TIMESTAMP="2026-11-18-1204"
out="$(cd "$tmp" && CONSENSO_CODEX_BIN=./bin/codex-rel CONSENSO_REGISTRY=reg.json \
  bash "$SCRIPT" alternativa --problem problema.md)"
rc=$?
assert_eq "$rc" "0" "rutas relativas de binario y registro funcionan"
rd="$(printf '%s\n' "$out" | tail -1)"
assert_contains "$(cat "$rd/alternativa-codex.md")" "1 solo 429" "el binario relativo recibe el prompt"

# Agente que falla: rc != 0 y el log lo refleja.
export CONSENSO_TIMESTAMP="2026-11-18-1203"
out="$(cd "$tmp" && STUB_CODEX_RC=1 bash "$SCRIPT" alternativa --problem "$tmp/problema.md")"
rc=$?
[ "$rc" -ne 0 ] || fail "un agente que falla debe propagar rc != 0"
rd="$(printf '%s\n' "$out" | tail -1)"
assert_contains "$(cat "$rd/log.md")" "alternativa: codex NO respondió" "el log marca el fallo"

# Guards de uso.
assert_exit 64 bash "$SCRIPT" alternativa
assert_exit 64 bash "$SCRIPT" alternativa --problem
assert_exit 64 bash "$SCRIPT" alternativa --problem "$tmp/no-existe.md"
: > "$tmp/vacio.md"
assert_exit 64 bash "$SCRIPT" alternativa --problem "$tmp/vacio.md"
assert_exit 64 bash "$SCRIPT" alternativa --problem "$tmp/problema.md" --agent qwen
assert_exit 64 bash "$SCRIPT" alternativa --otra

# Sin agentes detectados -> rc 4.
assert_exit 4 env CONSENSO_CODEX_BIN=/no/existe CONSENSO_AGY_BIN=/no/existe \
  bash "$SCRIPT" alternativa --problem "$tmp/problema.md" --workdir "$tmp"

rm -rf "$tmp"
echo "OK test_alternativa"
