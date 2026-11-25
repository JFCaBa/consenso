#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

# {PROMPT} en argv: los agentes del repo van por stdin, pero un registro de
# terceros puede seguir usándolo, en prosa y en JSON.
tmp="$(mktemp -d)"
printf '%s' '{"agentes":[{"id":"x","bin":"x","lente":"l","rol":"r","prioridad":1,
  "prosa_argv":["exec","{PROMPT}"],
  "json":{"via":"schema","argv":["run","--schema","{SCHEMA}","{PROMPT}"],"salida":"stdout","extract":".x"}}]}' > "$tmp/reg.json"
REAL_REGISTRY="$CONSENSO_REGISTRY"
CONSENSO_REGISTRY="$tmp/reg.json"

# Sustituye {PROMPT} preservando saltos de línea y comillas.
prompt='línea 1
línea "dos" con espacios'
consenso_argv x prosa "$prompt" "" "" ""
assert_eq "${#ARGV[@]}" "2" "prosa: 2 argumentos"
assert_eq "${ARGV[0]}" "exec" "primer argumento literal"
assert_eq "${ARGV[1]}" "$prompt" "el prompt llega intacto (newline y comillas)"
consenso_argv x json "$prompt" "/ruta/s.json" "" ""
assert_eq "${ARGV[2]}" "/ruta/s.json" "json: sustituye {SCHEMA}"
assert_eq "${ARGV[3]}" "$prompt" "json: sustituye {PROMPT}"

# Orden de sustitución: {PROMPT} debe sustituirse EL ÚLTIMO. Si el propio
# texto del prompt contiene literalmente "{SCHEMA}" o "{MODEL}" (p.ej. consenso
# revisando el diff de su propio registro), esos tokens no deben reescribirse.
prompt_con_tokens='En este diff hay literales {SCHEMA} y {MODEL} en el registro.'
consenso_argv x prosa "$prompt_con_tokens" "" "" ""
assert_contains "${ARGV[1]}" "{SCHEMA}" "el prompt conserva el literal {SCHEMA}"
assert_contains "${ARGV[1]}" "{MODEL}" "el prompt conserva el literal {MODEL}"
CONSENSO_REGISTRY="$REAL_REGISTRY"
rm -rf "$tmp"

# JSON de agy: sustituye {MODEL} y {SCHEMA}.
# El valor se busca tras --model, no por posición: añadir flags al registro
# (p.ej. --print-timeout) no debe romper el test.
consenso_argv agy json "p" "/ruta/schema.json" "/ruta/raw.json" "Modelo X"
modelo=""; prev=""
for a in "${ARGV[@]}"; do
  [ "$prev" = "--model" ] && modelo="$a"
  prev="$a"
done
assert_eq "$modelo" "Modelo X" "sustituye {MODEL}"
assert_contains "${ARGV[*]}" "/ruta/schema.json" "sustituye {SCHEMA}"

# Errores de uso.
assert_exit 2 consenso_argv inexistente prosa p "" "" ""
assert_exit 64 consenso_argv codex chorra p "" "" ""

echo "OK test_argv"
