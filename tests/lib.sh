# Helpers de aserción para tests en bash plano. Hacer `source`.

# Tests herméticos: ninguna variable CONSENSO_* del entorno del usuario (p.ej.
# CONSENSO_AGENTS para excluir un agente sin crédito, o CONSENSO_TIMEOUT) debe
# cambiar el resultado. Cada test fija después las que necesita.
for _consenso_var in $(compgen -e | grep '^CONSENSO_'); do
  unset "$_consenso_var"
done
unset _consenso_var

registro_sin_timeouts() {
  # $1 = fichero destino. Copia del registro sin `timeout` por agente, para
  # probar el fallback a CONSENSO_TIMEOUT (el timeout propio tiene prioridad).
  jq 'del(.agentes[].timeout)' "$(dirname "${BASH_SOURCE[0]}")/../agents/registry.json" > "$1"
}
fail() {
  echo "ASSERT FAIL: $1" >&2
  exit 1
}

assert_eq() {
  # $1 actual, $2 esperado, $3 msg
  if [ "$1" != "$2" ]; then
    fail "${3:-assert_eq}: esperado [$2], obtenido [$1]"
  fi
}

assert_contains() {
  # $1 haystack, $2 needle, $3 msg
  case "$1" in
    *"$2"*) : ;;
    *) fail "${3:-assert_contains}: [$1] no contiene [$2]" ;;
  esac
}

assert_exit() {
  # $1 código esperado, resto = comando
  local expected="$1"; shift
  "$@"
  local rc=$?
  if [ "$rc" != "$expected" ]; then
    fail "assert_exit: esperado rc=$expected, obtenido rc=$rc (cmd: $*)"
  fi
}
