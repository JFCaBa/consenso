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
  # $1 = fichero. 0 si el contenido es EXACTAMENTE un array JSON, 1 si no.
  # -s (slurp) evita aceptar un stream de varios valores (p.ej. "[1]\n[2]"),
  # que no es un único array aunque cada parte lo sea.
  if jq -e -s 'length==1 and (.[0]|type=="array")' "$1" >/dev/null 2>&1; then
    return 0
  else
    return 1
  fi
}

consenso_extract_json() {
  # $1 = fichero. Normaliza el fichero IN PLACE a un array JSON pelado,
  # tolerando fences de código (```json ... ```) o prosa antes/después.
  # Si ya valida como array, no toca nada. Si la extracción no produce un
  # array válido, deja el fichero tal cual (para que el flujo de reintento
  # y el fallback a [] sigan aplicando).
  local file="$1"
  if consenso_validate_json "$file"; then
    return 0
  fi
  local content
  content="$(sed '/^```/d' "$file")"
  case "$content" in
    *'['*']'*) : ;;
    *) return 1 ;;
  esac
  local body
  body="[${content#*[}"
  body="${body%]*}]"
  local tmp_extract
  tmp_extract="$(mktemp)"
  printf '%s' "$body" > "$tmp_extract"
  if consenso_validate_json "$tmp_extract"; then
    mv "$tmp_extract" "$file"
    return 0
  fi
  rm -f "$tmp_extract"
  return 1
}

consenso_agent_with_retry() {
  # $1 = agente, $2 = prompt, $3 = out_file. 0 si validó, 1 si agotó reintentos.
  local agent="$1"
  local prompt="$2"
  local out="$3"
  run_agent "$agent" "$prompt" "$out"
  consenso_extract_json "$out"
  if consenso_validate_json "$out"; then
    return 0
  fi
  # Reintento con recordatorio de formato.
  local prompt2="$prompt

IMPORTANTE: responde EXCLUSIVAMENTE con un array JSON de hallazgos, sin texto adicional."
  run_agent "$agent" "$prompt2" "$out"
  consenso_extract_json "$out"
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
      --workdir)
        if [ $# -lt 2 ]; then
          echo "round0: falta valor para --workdir" >&2
          return 64
        fi
        workdir="$2"; shift 2 ;;
      --diff)
        if [ $# -lt 2 ]; then
          echo "round0: falta valor para --diff" >&2
          return 64
        fi
        diff_file="$2"; shift 2 ;;
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

  # Ronda 0 corre codex y gemini EN PARALELO (spec: "en paralelo"). Cada uno
  # escribe en su propio fichero, así que no hay colisión. Lanzamos ambos en
  # background, esperamos a cada uno por separado y solo entonces logueamos,
  # en orden determinista (codex, luego gemini) según el estado capturado.
  local prompt_codex prompt_gemini
  prompt_codex="$(consenso_build_prompt "$CONSENSO_HOME/prompts/codex.md" "$diff_tmp")"
  prompt_gemini="$(consenso_build_prompt "$CONSENSO_HOME/prompts/gemini.md" "$diff_tmp")"

  local pid_codex pid_gemini rc_codex rc_gemini
  consenso_agent_with_retry codex "$prompt_codex" "$run_dir/codex.json" &
  pid_codex=$!
  consenso_agent_with_retry gemini "$prompt_gemini" "$run_dir/gemini.json" &
  pid_gemini=$!

  wait "$pid_codex"
  rc_codex=$?
  wait "$pid_gemini"
  rc_gemini=$?

  if [ "$rc_codex" -eq 0 ]; then
    consenso_log_append "$run_dir" "- codex: participó"
  else
    consenso_log_append "$run_dir" "- codex: NO participó (salida inválida o fallo del CLI)"
  fi
  if [ "$rc_gemini" -eq 0 ]; then
    consenso_log_append "$run_dir" "- gemini: participó"
  else
    consenso_log_append "$run_dir" "- gemini: NO participó (salida inválida o fallo del CLI)"
  fi

  rm -f "$diff_tmp"
  # Última línea de stdout: el run_dir, para que Claude sepa dónde leer.
  printf '%s\n' "$run_dir"
}

cmd_debate() {
  local points_file=""
  local run_dir=""
  local round="1"
  while [ $# -gt 0 ]; do
    case "$1" in
      --points)
        if [ $# -lt 2 ]; then
          echo "debate: falta valor para --points" >&2
          return 64
        fi
        points_file="$2"; shift 2 ;;
      --run-dir)
        if [ $# -lt 2 ]; then
          echo "debate: falta valor para --run-dir" >&2
          return 64
        fi
        run_dir="$2"; shift 2 ;;
      --round)
        if [ $# -lt 2 ]; then
          echo "debate: falta valor para --round" >&2
          return 64
        fi
        round="$2"; shift 2 ;;
      *) echo "debate: opción desconocida: $1" >&2; return 64 ;;
    esac
  done
  if [ ! -f "$points_file" ] || [ -z "$run_dir" ]; then
    echo "debate: faltan --points o --run-dir" >&2
    return 64
  fi

  local instruccion="Estos son puntos en disputa de una revisión de código, con las críticas cruzadas de los otros revisores. Para cada punto, responde en prosa: ¿lo MANTIENES, lo REBATES o CEDES? Da un argumento técnico breve por cada uno.

"
  local points
  points="$(cat "$points_file")"
  local prompt="$instruccion$points"

  local agent
  for agent in codex gemini; do
    if run_agent "$agent" "$prompt" "$run_dir/debate-$round-$agent.md"; then
      consenso_log_append "$run_dir" "- debate ronda $round: $agent respondió"
    else
      consenso_log_append "$run_dir" "- debate ronda $round: $agent NO respondió (fallo del CLI o timeout)"
    fi
  done

  printf '%s\n' "$run_dir"
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    round0) cmd_round0 "$@" ;;
    debate) cmd_debate "$@" ;;
    "") echo "uso: consenso.sh <round0|debate> [opciones]" >&2; return 64 ;;
    *) echo "consenso: subcomando desconocido: $sub" >&2; return 64 ;;
  esac
}

# Solo ejecutar main si se invoca directamente (no al hacer source).
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
  main "$@"
fi
