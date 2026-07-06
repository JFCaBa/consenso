#!/usr/bin/env bash
# Autotest del propio arnés.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"

assert_eq "abc" "abc" "assert_eq iguales"
assert_contains "hola mundo" "mundo" "assert_contains encuentra"
assert_exit 3 bash -c 'exit 3'

# Comprueba que un fallo de aserción sale != 0 en un subshell aislado.
if ( assert_eq "x" "y" "debe fallar" ) 2>/dev/null; then
  fail "assert_eq debería haber fallado con valores distintos"
fi

echo "OK test_harness"
