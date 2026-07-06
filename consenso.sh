#!/usr/bin/env bash
# consenso.sh — orquestador mecánico del flujo de consenso multiagente.
# Compatible con bash 3.2. Depende de: jq, git, utilidades POSIX.
set -u

consenso_build_prompt() {
  # $1 = fichero de rol, $2 = fichero de diff. Imprime el prompt completo.
  local rol_file="$1"
  local diff_file="$2"
  if [ ! -f "$rol_file" ] || [ ! -f "$diff_file" ]; then
    echo "consenso: falta rol o diff" >&2
    return 2
  fi
  cat "$rol_file"
  echo ""
  echo "----- DIFF A REVISAR -----"
  cat "$diff_file"
}

main() {
  echo "consenso: subcomando no implementado todavía" >&2
  return 64
}

# Solo ejecutar main si se invoca directamente (no al hacer source).
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
  main "$@"
fi
