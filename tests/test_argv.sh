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

echo "OK test_argv"
