#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
g="$tmp/.consenso/demo/g1"
mkdir -p "$g/v1"
printf '# log v1\n' > "$g/v1/log.md"
: > "$g/v1/completo"

obj() {
  # $1 = versión; resto = objetos JSON de objeción.
  local v="$1"; shift
  local IFS=,
  printf '{"version":%s,"objeciones":[%s]}' "$v" "$*" > "$g/objeciones.json"
}
o() { printf '{"id":"%s","hallazgo":"%s","estado":"%s","nota":"%s"}' "$1" "$2" "$3" "${4:-}"; }
report() { bash "$SCRIPT" report --task demo --gate 1 --workdir "$tmp" "$@"; }

# --- Las 4 secciones, en orden, y la tabla ---
obj 1 "$(o O1 h-acordada acordada 'codex y Claude')" "$(o O2 h-resuelta resuelta 'agy cedió')" \
  "$(o O3 h-rechazada rechazada)" "$(o O4 h-abierta abierta)" "$(o O5 h-fuera fuera_de_alcance)"
out="$(report)"
assert_exit 0 cmp -s <(printf '%s\n' "$out") "$g/v1/informe.md"
assert_contains "$out" "## Informe (gate 1, v1)" "encabezado con gate y versión"
orden="$(printf '%s\n' "$out" | grep -n '^### ' | cut -d: -f2 | tr '\n' '|')"
assert_eq "$orden" "### Acordado|### Resuelto por debate|### Sin resolver|### Fuera de alcance|" "secciones en orden"
seccion() { printf '%s\n' "$out" | awk -v s="### $1" '$0==s{on=1;next} /^#/{on=0} on'; }
assert_contains "$(seccion Acordado)" "O1" "O1 en Acordado"
assert_contains "$(seccion Acordado)" "codex y Claude" "la nota acompaña al hallazgo"
assert_contains "$(seccion 'Resuelto por debate')" "O2" "O2 en Resuelto"
assert_contains "$(seccion 'Resuelto por debate')" "O3" "O3 (rechazada) en Resuelto"
assert_contains "$(seccion 'Sin resolver')" "O4" "O4 en Sin resolver"
assert_contains "$(seccion 'Fuera de alcance')" "O5" "O5 en Fuera de alcance"
assert_contains "$out" "| O4 | abierta |" "fila de tabla de O4"
assert_contains "$(cat "$g/v1/log.md")" "- informe: informe.md (5 objeciones: 1 abiertas)" "puntero en log.md"

# --- Idempotente: informe.md se sobrescribe; log.md solo acumula punteros ---
obj 1 "$(o O1 h-acordada acordada)" "$(o O4 h-abierta resuelta)"
out="$(report)"
assert_exit 0 cmp -s <(printf '%s\n' "$out") "$g/v1/informe.md"
case "$(seccion 'Sin resolver')" in *O4*) fail "O4 ya no está sin resolver" ;; esac
assert_eq "$(grep -c '^- informe: ' "$g/v1/log.md")" "2" "dos punteros en log.md"
case "$(cat "$g/v1/log.md")" in *"### Acordado"*) fail "log.md no lleva el informe entero" ;; esac

# --- Secciones vacías ---
obj 1 "$(o O1 solo-acordada acordada)"
out="$(report)"
assert_contains "$(seccion 'Sin resolver')" "- (ninguno)" "Sin resolver vacía"
assert_contains "$(seccion 'Resuelto por debate')" "- (ninguno)" "Resuelto vacía"
case "$out" in *"### Fuera de alcance"*) fail "Fuera de alcance vacía se omite" ;; esac

# --- Tabla a salvo de | y saltos de línea ---
printf '{"version":1,"objeciones":[{"id":"O1","hallazgo":"a|b\\nc","estado":"abierta","nota":""}]}' > "$g/objeciones.json"
out="$(report)"
assert_contains "$out" '| O1 | abierta | a\|b c |' "escapa | y aplana saltos"

# --- Versión: el registro debe ser de la última ---
mkdir -p "$g/v2" "$g/v10"
printf '# log v10\n' > "$g/v10/log.md"
: > "$g/v10/completo"
obj 1 "$(o O1 x abierta)"
err="$(report 2>&1 >/dev/null)"
assert_contains "$err" "es de v1 y la última es v10" "rechaza objeciones de otra versión (v10 > v2)"
assert_exit 64 report
obj 10 "$(o O1 x abierta)"
report >/dev/null
assert_exit 0 test -f "$g/v10/informe.md"
# Última versión sin marca de completa -> rc 64 sin escribir informe.
rm -f "$g/v10/completo" "$g/v10/informe.md"
err="$(report 2>&1 >/dev/null)"
assert_contains "$err" "v10 está incompleta" "rechaza informe sobre versión incompleta"
assert_exit 1 test -e "$g/v10/informe.md"
rm -rf "$g/v2" "$g/v10"

# --- objeciones.json inválido -> rc 65 ---
for bad in \
  '{"version":1,"objeciones":[{"id":"X1","hallazgo":"h","estado":"abierta","nota":""}]}' \
  '{"version":1,"objeciones":[{"id":"O0","hallazgo":"h","estado":"abierta","nota":""}]}' \
  '{"version":1,"objeciones":[{"id":"O1","hallazgo":"h","estado":"abierta","nota":""},{"id":"O1","hallazgo":"i","estado":"abierta","nota":""}]}' \
  '{"version":1,"objeciones":[{"id":"O1","hallazgo":"h","estado":"pendiente","nota":""}]}' \
  '{"version":1,"objeciones":[{"id":"O1","hallazgo":"h","estado":"abierta"}]}' \
  '{"version":1,"objeciones":{}}' \
  '{"objeciones":[]}' \
  'no es json'; do
  printf '%s' "$bad" > "$g/objeciones.json"
  assert_exit 65 report
done

# --- rc 64: sin objeciones.json, gate sin versiones, sin --task ---
rm -f "$g/objeciones.json"
err="$(report 2>&1 >/dev/null)"
assert_contains "$err" "objeciones.json" "dice qué fichero falta"
assert_exit 64 report
mkdir -p "$tmp/.consenso/demo/g2"
printf '{"version":1,"objeciones":[]}' > "$tmp/.consenso/demo/g2/objeciones.json"
assert_exit 64 bash "$SCRIPT" report --task demo --gate 2 --workdir "$tmp"
assert_exit 64 bash "$SCRIPT" report --gate 1 --workdir "$tmp"

rm -rf "$tmp"
echo "OK test_report"
