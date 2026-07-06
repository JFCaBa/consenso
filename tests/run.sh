#!/usr/bin/env bash
# Ejecuta todos los tests/test_*.sh y agrega resultados.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
failed=0
total=0
for t in "$HERE"/test_*.sh; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  if bash "$t"; then
    echo "PASS $(basename "$t")"
  else
    echo "FAIL $(basename "$t")"
    failed=$((failed + 1))
  fi
done
echo "----"
echo "$((total - failed))/$total OK"
[ "$failed" -eq 0 ]
