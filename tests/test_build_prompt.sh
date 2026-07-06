#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

out="$(consenso_build_prompt "$HERE/fixtures/rol_demo.md" "$HERE/fixtures/diff_demo.txt")"
assert_contains "$out" "Lente: demo" "incluye el rol"
assert_contains "$out" "return 1/0" "incluye el diff"

# Ficheros inexistentes -> exit 2
assert_exit 2 consenso_build_prompt "/no/existe.md" "$HERE/fixtures/diff_demo.txt"

echo "OK test_build_prompt"
