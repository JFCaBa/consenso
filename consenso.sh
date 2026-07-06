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

run_with_timeout() {
  # $1 = segundos, resto = comando. Devuelve 124 si se excede.
  local secs="$1"; shift
  "$@" &
  local cmd_pid=$!
  ( sleep "$secs"; kill -9 "$cmd_pid" 2>/dev/null ) &
  local watcher=$!
  wait "$cmd_pid" 2>/dev/null
  local rc=$?
  # Si el watcher ya no existe, el comando fue matado por timeout.
  if kill -0 "$watcher" 2>/dev/null; then
    pkill -P "$watcher" 2>/dev/null   # mata el sleep hijo mientras el watcher sigue vivo
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return "$rc"
  fi
  return 124
}

run_agent() {
  # $1 = codex|gemini, $2 = prompt, $3 = fichero de salida.
  local agent="$1"
  local prompt="$2"
  local out="$3"
  local timeout="${CONSENSO_TIMEOUT:-120}"
  local codex_cmd="${CONSENSO_CODEX_CMD:-codex}"
  local gemini_cmd="${CONSENSO_GEMINI_CMD:-gemini}"
  case "$agent" in
    codex)
      run_with_timeout "$timeout" "$codex_cmd" exec "$prompt" >"$out" 2>"$out.err"
      return $?
      ;;
    gemini)
      run_with_timeout "$timeout" "$gemini_cmd" -p "$prompt" >"$out" 2>"$out.err"
      return $?
      ;;
    *)
      echo "run_agent: agente desconocido: $agent" >&2
      return 2
      ;;
  esac
}

main() {
  echo "consenso: subcomando no implementado todavía" >&2
  return 64
}

# Solo ejecutar main si se invoca directamente (no al hacer source).
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
  main "$@"
fi
