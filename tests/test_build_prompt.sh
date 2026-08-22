#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

out="$(consenso_build_prompt "$HERE/fixtures/rol_demo.md" "$HERE/fixtures/diff_demo.txt")"
assert_contains "$out" "Lente: demo" "incluye el rol"
assert_contains "$out" "return 1/0" "incluye el diff"
assert_contains "$out" "DIFF A REVISAR" "modo por defecto: encabezado de diff"

# Modo plan: encabezado propio + nota que adapta la revisión a prosa.
out_plan="$(consenso_build_prompt "$HERE/fixtures/rol_demo.md" "$HERE/fixtures/diff_demo.txt" plan)"
assert_contains "$out_plan" "PLAN A REVISAR" "modo plan: encabezado de plan"
assert_contains "$out_plan" "prosa" "modo plan: nota de prosa, no diff"
case "$out_plan" in
  *"DIFF A REVISAR"*) fail "modo plan: no debe llevar encabezado de diff" ;;
esac

# Modo desconocido -> exit 64
assert_exit 64 consenso_build_prompt "$HERE/fixtures/rol_demo.md" "$HERE/fixtures/diff_demo.txt" chorra

# Ficheros inexistentes -> exit 2
assert_exit 2 consenso_build_prompt "/no/existe.md" "$HERE/fixtures/diff_demo.txt"

echo "OK test_build_prompt"
