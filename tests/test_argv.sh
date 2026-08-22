#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

# Prosa de codex: sustituye {PROMPT} preservando saltos de línea y comillas.
prompt='línea 1
línea "dos" con espacios'
consenso_argv codex prosa "$prompt" "" "" ""
assert_eq "${#ARGV[@]}" "3" "codex prosa: 3 argumentos"
assert_eq "${ARGV[0]}" "exec" "primer argumento literal"
assert_eq "${ARGV[2]}" "$prompt" "el prompt llega intacto (newline y comillas)"

# JSON de agy: sustituye {MODEL}, {SCHEMA} y {PROMPT}.
consenso_argv agy json "p" "/ruta/schema.json" "/ruta/raw.json" "Modelo X"
assert_eq "${ARGV[2]}" "Modelo X" "sustituye {MODEL}"
assert_contains "${ARGV[*]}" "/ruta/schema.json" "sustituye {SCHEMA}"

# Errores de uso.
assert_exit 2 consenso_argv inexistente prosa p "" "" ""
assert_exit 64 consenso_argv codex chorra p "" "" ""

# Orden de sustitución: {PROMPT} debe sustituirse EL ÚLTIMO. Si el propio
# texto del prompt contiene literalmente "{SCHEMA}" o "{MODEL}" (p.ej. consenso
# revisando el diff de su propio registro), esos tokens no deben reescribirse.
prompt_con_tokens='En este diff hay literales {SCHEMA} y {MODEL} en el registro.'
consenso_argv codex prosa "$prompt_con_tokens" "" "" ""
assert_contains "${ARGV[2]}" "{SCHEMA}" "el prompt conserva el literal {SCHEMA}"
assert_contains "${ARGV[2]}" "{MODEL}" "el prompt conserva el literal {MODEL}"

echo "OK test_argv"
