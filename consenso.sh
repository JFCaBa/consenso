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

consenso_validate_json() {
  # $1 = fichero. 0 si es array JSON, 1 si no.
  if jq -e 'type=="array"' "$1" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

consenso_agent_with_retry() {
  # $1 = agente, $2 = prompt, $3 = out_file. 0 si validó, 1 si agotó reintentos.
  local agent="$1"
  local prompt="$2"
  local out="$3"
  run_agent "$agent" "$prompt" "$out"
  if consenso_validate_json "$out"; then
    return 0
  fi
  # Reintento con recordatorio de formato.
  local prompt2="$prompt

IMPORTANTE: responde EXCLUSIVAMENTE con un array JSON de hallazgos, sin texto adicional."
  run_agent "$agent" "$prompt2" "$out"
  if consenso_validate_json "$out"; then
    return 0
  fi
  echo "salida no-JSON tras reintento; agente tratado como no participante" > "$out.err"
  printf '%s' "[]" > "$out"
  return 1
}

consenso_run_dir() {
  # $1 = workdir. Imprime y crea <workdir>/.consenso/<timestamp>.
  local workdir="$1"
  local ts="${CONSENSO_TIMESTAMP:-$(date +%Y-%m-%d-%H%M%S)}"
  local dir="$workdir/.consenso/$ts"
  mkdir -p "$dir"
  printf '%s' "$dir"
}

consenso_init_log() {
  # $1 = run_dir, $2 = titulo.
  local dir="$1"
  local titulo="$2"
  {
    echo "# Consenso — $titulo"
    echo ""
    echo "Directorio: $dir"
    echo ""
  } > "$dir/log.md"
}

consenso_log_append() {
  # $1 = run_dir, $2 = texto.
  echo "$2" >> "$1/log.md"
}

# Ruta al directorio del propio script (para localizar prompts/).
CONSENSO_HOME="$(cd "$(dirname "${BASH_SOURCE:-$0}")" && pwd)"

consenso_get_diff() {
  # $1 = workdir, $2 = (opcional) fichero de diff. Imprime el diff; 3 si vacío.
  local workdir="$1"
  local diff_file="${2:-}"
  local content=""
  if [ -n "$diff_file" ]; then
    content="$(cat "$diff_file")"
  else
    content="$(git -C "$workdir" diff HEAD 2>/dev/null)"
  fi
  if [ -z "$content" ]; then
    return 3
  fi
  printf '%s' "$content"
}

cmd_round0() {
  local workdir="."
  local diff_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir) workdir="$2"; shift 2 ;;
      --diff) diff_file="$2"; shift 2 ;;
      *) echo "round0: opción desconocida: $1" >&2; return 64 ;;
    esac
  done

  local diff_tmp
  diff_tmp="$(mktemp)"
  if ! consenso_get_diff "$workdir" "$diff_file" > "$diff_tmp"; then
    echo "consenso: no hay cambios que revisar (diff vacío)" >&2
    rm -f "$diff_tmp"
    return 3
  fi

  local run_dir
  run_dir="$(consenso_run_dir "$workdir")"
  consenso_init_log "$run_dir" "Ronda 0 — revisión independiente"

  local agent
  for agent in codex gemini; do
    local prompt
    prompt="$(consenso_build_prompt "$CONSENSO_HOME/prompts/$agent.md" "$diff_tmp")"
    if consenso_agent_with_retry "$agent" "$prompt" "$run_dir/$agent.json"; then
      consenso_log_append "$run_dir" "- $agent: participó"
    else
      consenso_log_append "$run_dir" "- $agent: NO participó (salida inválida o fallo del CLI)"
    fi
  done

  rm -f "$diff_tmp"
  # Última línea de stdout: el run_dir, para que Claude sepa dónde leer.
  printf '%s\n' "$run_dir"
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    round0) cmd_round0 "$@" ;;
    "") echo "uso: consenso.sh <round0|debate> [opciones]" >&2; return 64 ;;
    *) echo "consenso: subcomando desconocido: $sub" >&2; return 64 ;;
  esac
}

# Solo ejecutar main si se invoca directamente (no al hacer source).
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
  main "$@"
fi
