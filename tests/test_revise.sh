#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"
export CONSENSO_AGENTS=codex
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
w="$tmp/repo"; mkdir -p "$w"
g="$w/.consenso/demo/g1"
printf 'diff --git a/foo.py b/foo.py\n+return 1/0\n' > "$tmp/d1.txt"
printf 'diff --git a/foo.py b/foo.py\n+if d: return 1/d\n' > "$tmp/d2.txt"
revise() { bash "$SCRIPT" revise --task demo --gate 1 --workdir "$w" "$@"; }
obj() { printf '{"version":%s,"objeciones":%s}' "$1" "$2" > "$g/objeciones.json"; }
O3='[{"id":"O1","hallazgo":"div por cero","estado":"abierta","nota":""},{"id":"O2","hallazgo":"falta test","estado":"acordada","nota":""},{"id":"O3","hallazgo":"nombre","estado":"resuelta","nota":""}]'

# Sin v1 en el gate -> rc 64 que remite a round0.
err="$(revise --diff "$tmp/d2.txt" 2>&1 >/dev/null)"
assert_contains "$err" "round0 --task" "sin v1 remite a round0"
assert_exit 64 revise --diff "$tmp/d2.txt"

bash "$SCRIPT" round0 --task demo --gate 1 --diff "$tmp/d1.txt" --workdir "$w" >/dev/null

# Sin objeciones.json -> rc 64, sin v2.
err="$(revise --diff "$tmp/d2.txt" 2>&1 >/dev/null)"
assert_contains "$err" "objeciones.json" "pide sintetizar antes"
assert_exit 64 revise --diff "$tmp/d2.txt"
assert_exit 1 test -e "$g/v2"

# --- revise de v1 a v2 ---
obj 1 "$O3"
out="$(STUB_CODEX_STDIN_FILE="$tmp/stdin.txt" \
  STUB_CODEX_SEGUIMIENTO='[{"objecion":"O1","estado":"resuelta","argumento":"ya valida d"}]' \
  revise --diff "$tmp/d2.txt")"
v2="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$v2" "$(cd "$w" && pwd)/.consenso/demo/g1/v2" "imprime g1/v2 absoluto"
for f in entrada cambios contexto pendientes.json completo codex.json codex.seguimiento.json; do
  assert_exit 0 test -f "$v2/$f"
done
assert_contains "$(cat "$v2/cambios")" "-+return 1/0" "cambios: línea quitada"
assert_contains "$(cat "$v2/cambios")" "++if d: return 1/d" "cambios: línea añadida"
s="$(cat "$tmp/stdin.txt")"
assert_contains "$s" "if d: return 1/d" "prompt: artefacto completo nuevo"
assert_contains "$s" "CAMBIOS RESPECTO A v1" "prompt: cambios"
assert_contains "$s" "OBJECIONES PENDIENTES" "prompt: objeciones pendientes"
assert_contains "$s" '"O1"' "prompt: O1 (abierta)"
assert_contains "$s" '"O2"' "prompt: O2 (acordada, se verifica)"
case "$s" in *'"O3"'*) fail "prompt: O3 (resuelta) no es pendiente" ;; esac
log="$(cat "$v2/log.md")"
assert_contains "$log" "Tarea: demo · gate 1 · v2 (revisión de v1)" "log: tarea y versión"
assert_contains "$log" "seguimiento: 1 resueltas, 0 siguen abiertas; sin seguimiento: O2" "log: seguimiento y pendiente sin respuesta"

# --- Precondiciones sobre la versión nueva ---
err="$(revise --diff "$tmp/d2.txt" 2>&1 >/dev/null)"
assert_contains "$err" "es de v1" "objeciones de v1 con v2 presente"
assert_exit 64 revise --diff "$tmp/d2.txt"
obj 2 "$O3"
err="$(revise --diff "$tmp/d2.txt" 2>&1 >/dev/null)"
assert_contains "$err" "no cambió" "misma entrada que la última versión"
assert_exit 1 test -e "$g/v3"

# Seguimiento con un id que no estaba pendiente -> fuera de contrato.
out="$(STUB_CODEX_SEGUIMIENTO='[{"objecion":"O9","estado":"resuelta","argumento":"x"}]' revise --diff "$tmp/d1.txt")"
v3="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$v3" "$(cd "$w" && pwd)/.consenso/demo/g1/v3" "volver al contenido de v1 crea v3"
assert_exit 0 test -f "$v3/codex.json"
assert_exit 1 test -e "$v3/codex.seguimiento.json"
assert_contains "$(cat "$v3/log.md")" "seguimiento fuera de contrato" "log: seguimiento inválido"

# Sin pendientes: el prompt lo dice.
obj 3 '[{"id":"O1","hallazgo":"a","estado":"resuelta","nota":""}]'
STUB_CODEX_STDIN_FILE="$tmp/stdin4.txt" revise --diff "$tmp/d2.txt" >/dev/null
assert_contains "$(cat "$tmp/stdin4.txt")" "sin objeciones pendientes" "prompt: sin pendientes"

# Todos fallan -> sin completo; relanzar dice incompleto.
obj 4 '[]'
STUB_CODEX_RC=1 revise --diff "$tmp/d1.txt" >/dev/null 2>&1
assert_exit 1 test -e "$g/v5/completo"
assert_contains "$(cat "$g/v5/log.md")" "codex: FALLÓ" "log: FALLÓ"
err="$(revise --diff "$tmp/d2.txt" 2>&1 >/dev/null)"
assert_contains "$err" "incompleta" "versión sin completo bloquea con mensaje"
assert_exit 64 revise --diff "$tmp/d2.txt"
rm -rf "$g/v5"

# Uno de dos falla -> completo, y sin ficheros del que falló.
v6="$(CONSENSO_AGENTS=codex,agy STUB_CODEX_RC=1 revise --diff "$tmp/d1.txt" 2>/dev/null | tail -1)"
assert_exit 0 test -f "$v6/completo"
assert_exit 1 test -e "$v6/codex.json"
assert_exit 1 test -e "$v6/codex.seguimiento.json"
assert_exit 0 test -f "$v6/agy.json"

# --plan en un gate que empezó con --diff: se permite; modo de la versión nueva.
obj 5 '[]'
printf '# Plan nuevo\nPaso 1\n' > "$tmp/plan.md"
v7="$(revise --plan "$tmp/plan.md" | tail -1)"
assert_eq "$(cat "$v7/modo")" "plan" "modo de la versión nueva"

# Dos revise simultáneos: uno reserva v7, el otro rc 64.
obj 6 '[]'
( STUB_CODEX_SLEEP=1 revise --diff "$tmp/d2.txt" >/dev/null 2>&1; echo $? > "$tmp/rc-a" ) &
( STUB_CODEX_SLEEP=1 revise --diff "$tmp/d2.txt" >/dev/null 2>&1; echo $? > "$tmp/rc-b" ) &
wait
assert_eq "$(sort "$tmp/rc-a" "$tmp/rc-b" | tr '\n' ' ')" "0 64 " "concurrencia: uno gana, otro rc 64"

# Guards.
assert_exit 64 bash "$SCRIPT" revise --gate 1 --diff "$tmp/d2.txt" --workdir "$w"
assert_exit 64 bash "$SCRIPT" revise --task demo --gate 1 --diff "$tmp/d2.txt" --plan "$tmp/plan.md" --workdir "$w"

rm -rf "$tmp"
echo "OK test_revise"
