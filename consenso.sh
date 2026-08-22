#!/usr/bin/env bash
# consenso.sh — orquestador mecánico del flujo de consenso multiagente.
# Compatible con bash 3.2. Depende de: jq, git, utilidades POSIX.
set -u

consenso_build_prompt() {
  # $1 = fichero de rol, $2 = fichero de contenido, $3 = (opcional) modo
  # diff|plan (default diff). Imprime el prompt completo.
  local rol_file="$1"
  local content_file="$2"
  local modo="${3:-diff}"
  case "$modo" in
    diff|plan) : ;;
    *) echo "consenso_build_prompt: modo desconocido: $modo" >&2; return 64 ;;
  esac
  if [ ! -f "$rol_file" ] || [ ! -f "$content_file" ]; then
    echo "consenso: falta rol o contenido" >&2
    return 2
  fi
  cat "$rol_file"
  echo ""
  if [ "$modo" = "plan" ]; then
    echo "NOTA: lo que sigue es un PLAN DE IMPLEMENTACIÓN en prosa, no un diff."
    echo "Evalúa el diseño con tu lente: riesgos, pasos que faltan, supuestos"
    echo "dudosos y alternativas más simples. En 'ubicacion' referencia la"
    echo "sección o el paso del plan."
    echo ""
    echo "----- PLAN A REVISAR -----"
  else
    echo "----- DIFF A REVISAR -----"
  fi
  cat "$content_file"
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
  # $1 = codex|agy, $2 = prompt, $3 = fichero de salida. Uso: respuestas en
  # prosa (debate). Para hallazgos en JSON usa run_agent_json.
  local agent="$1"
  local prompt="$2"
  local out="$3"
  local timeout="${CONSENSO_TIMEOUT:-120}"
  local codex_cmd="${CONSENSO_CODEX_CMD:-codex}"
  # La lente de arquitectura la provee `agy` (Antigravity, multi-modelo) con un
  # modelo Gemini fijado, para preservar la diversidad de modelos del consenso.
  # Se usa Flash y no Pro (High): Pro (High) tardaba >7 min en un diff real y el
  # timeout lo mataba; Flash (High) revisa el mismo diff en ~20-30s con JSON válido.
  # `--dangerously-skip-permissions` es obligatorio: consenso corre headless y
  # `agy` se colgaría esperando a un prompt de permisos.
  local agy_cmd="${CONSENSO_AGY_CMD:-agy}"
  local agy_model="${CONSENSO_AGY_MODEL:-Gemini 3.5 Flash (High)}"
  case "$agent" in
    codex)
      # stdin explícitamente cerrado: si se hereda el stdin del script (p.ej.
      # al lanzar codex en background con run_with_timeout), codex >=0.14x
      # imprime "Reading additional input from stdin..." y espera/anexa ese
      # stdin al prompt, añadiendo ruido y latencia (~20s) al override.
      run_with_timeout "$timeout" "$codex_cmd" exec --skip-git-repo-check "$prompt" < /dev/null >"$out" 2>"$out.err"
      return $?
      ;;
    agy)
      run_with_timeout "$timeout" "$agy_cmd" --dangerously-skip-permissions --model "$agy_model" -p "$prompt" < /dev/null >"$out" 2>"$out.err"
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

run_agent_json() {
  # $1 = codex|agy, $2 = prompt, $3 = out_file. Escribe el array JSON de
  # hallazgos en $out (o [] si el agente no participó). 0 si hay array válido.
  #
  # A diferencia de run_agent, no pide "responde solo JSON" en el prompt y
  # raspa la respuesta: fuerza el JSON Schema nativo de cada CLI
  # (--output-schema de codex, --json-schema de agy — ambos disponibles desde
  # las versiones actuales), así que la salida es JSON válido o el CLI falla
  # explícitamente. Diagnóstico ante fallo: $out.err (stderr real del CLI) y
  # $out.raw (última respuesta cruda, si la hubo).
  local agent="$1"
  local prompt="$2"
  local out="$3"
  local timeout="${CONSENSO_TIMEOUT:-120}"
  local codex_cmd="${CONSENSO_CODEX_CMD:-codex}"
  local agy_cmd="${CONSENSO_AGY_CMD:-agy}"
  local agy_model="${CONSENSO_AGY_MODEL:-Gemini 3.5 Flash (High)}"
  local schema="$CONSENSO_HOME/prompts/hallazgos.schema.json"
  local raw="$out.raw"
  local rc

  case "$agent" in
    codex)
      run_with_timeout "$timeout" "$codex_cmd" exec --skip-git-repo-check \
        --output-schema "$schema" -o "$raw" "$prompt" \
        < /dev/null >"$out.stdout" 2>"$out.err"
      rc=$?
      ;;
    agy)
      run_with_timeout "$timeout" "$agy_cmd" --dangerously-skip-permissions \
        --model "$agy_model" --output-format json --json-schema "$schema" \
        -p "$prompt" < /dev/null >"$raw" 2>"$out.err"
      rc=$?
      ;;
    *)
      echo "run_agent_json: agente desconocido: $agent" >&2
      return 2
      ;;
  esac

  if [ "$rc" -ne 0 ] || [ ! -s "$raw" ]; then
    return 1
  fi

  case "$agent" in
    codex) jq -e '.hallazgos' "$raw" >"$out" 2>>"$out.err" ;;
    agy)   jq -e '.structured_output.hallazgos' "$raw" >"$out" 2>>"$out.err" ;;
  esac
  if [ $? -ne 0 ]; then
    return 1
  fi
  consenso_validate_json "$out"
}

consenso_agent_with_retry() {
  # $1 = agente, $2 = prompt, $3 = out_file. 0 si validó, 1 si agotó reintentos.
  local agent="$1"
  local prompt="$2"
  local out="$3"
  if run_agent_json "$agent" "$prompt" "$out"; then
    return 0
  fi
  # Reintento simple: la única causa de fallo con JSON Schema forzado es un
  # error transitorio del CLI/API (timeout, capacidad, etc.), no un problema
  # de formato — no hace falta variar el prompt.
  if run_agent_json "$agent" "$prompt" "$out"; then
    return 0
  fi
  echo "agente sin salida válida tras reintento; tratado como no participante" >> "$out.err"
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

CONSENSO_REGISTRY="${CONSENSO_REGISTRY:-$CONSENSO_HOME/agents/registry.json}"

consenso_registry_validar() {
  # $1 = fichero de registro. 0 si válido; 65 si no (el registro se trata como
  # configuración no confiable aunque viva en el repo).
  if jq -e '
    (.agentes | type=="array" and length>0)
    and ([.agentes[] | select(
          (.id? | type=="string" and test("^[a-z0-9_]+$"))
      and (.bin? | type=="string" and length>0)
      and (.lente? | type=="string" and length>0)
      and (.rol? | type=="string" and length>0)
      and (.prioridad? | type=="number")
      and (.prosa_argv? | type=="array" and length>0 and all(.[]; type=="string"))
      and ((.prompt_via // "argv") as $p | ["argv","stdin"] | index($p) != null)
      and (.json.via? as $v | ["schema","prompt"] | index($v) != null)
      and (.json.salida? as $s | ["stdout","fichero"] | index($s) != null)
      and (.json.argv? | type=="array" and length>0 and all(.[]; type=="string"))
      and (.json.extract? | type=="string" and test("^\\.([a-zA-Z0-9_]+(\\.[a-zA-Z0-9_]+)*)?$"))
    )] | length) == (.agentes | length)
    and ([.agentes[].id] | unique | length) == (.agentes | length)
  ' "$1" >/dev/null 2>&1; then
    return 0
  fi
  echo "consenso: registro inválido: $1" >&2
  return 65
}

consenso_agente_json() {
  # $1 = id. Imprime el objeto del agente en una línea; rc 2 si no existe.
  local obj
  obj="$(jq -c --arg id "$1" '.agentes[] | select(.id==$id)' "$CONSENSO_REGISTRY")"
  if [ -z "$obj" ]; then
    echo "consenso: agente desconocido en el registro: $1" >&2
    return 2
  fi
  printf '%s' "$obj"
}

consenso_rol_de() {
  # $1 = id. Imprime la ruta (relativa a CONSENSO_HOME) del prompt de rol.
  consenso_agente_json "$1" | jq -r '.rol'
}

consenso_bin_de() {
  # $1 = id. Binario resuelto: CONSENSO_<ID>_BIN o el bin del registro.
  local var="CONSENSO_$(printf '%s' "$1" | tr 'a-z' 'A-Z')_BIN"
  local override="${!var:-}"
  if [ -n "$override" ]; then
    printf '%s' "$override"
  else
    consenso_agente_json "$1" | jq -r '.bin'
  fi
}

consenso_model_de() {
  # $1 = id. Modelo resuelto: CONSENSO_<ID>_MODEL o modelo_default (o vacío).
  local var="CONSENSO_$(printf '%s' "$1" | tr 'a-z' 'A-Z')_MODEL"
  local override="${!var:-}"
  if [ -n "$override" ]; then
    printf '%s' "$override"
  else
    consenso_agente_json "$1" | jq -r '.modelo_default // ""'
  fi
}

consenso_timeout_de() {
  # $1 = id. Timeout: el del agente en el registro, o CONSENSO_TIMEOUT, o 120.
  local propio
  propio="$(consenso_agente_json "$1" | jq -r '.timeout // ""')"
  if [ -n "$propio" ]; then
    printf '%s' "$propio"
  else
    printf '%s' "${CONSENSO_TIMEOUT:-120}"
  fi
}

consenso_get_content() {
  # $1 = workdir, $2 = (opcional) fichero de contenido (diff o plan). Imprime
  # el fichero tal cual, o `git diff HEAD` del workdir si no se da; 3 si vacío.
  local workdir="$1"
  local content_file="${2:-}"
  local content=""
  if [ -n "$content_file" ]; then
    content="$(cat "$content_file")"
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
  local plan_file=""
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
      --plan)
        if [ $# -lt 2 ]; then
          echo "round0: falta valor para --plan" >&2
          return 64
        fi
        plan_file="$2"; shift 2 ;;
      *) echo "round0: opción desconocida: $1" >&2; return 64 ;;
    esac
  done

  if [ -n "$plan_file" ] && [ -n "$diff_file" ]; then
    echo "round0: --plan y --diff son excluyentes" >&2
    return 64
  fi
  local modo="diff"
  [ -n "$plan_file" ] && modo="plan"

  local content_tmp
  content_tmp="$(mktemp)"
  if ! consenso_get_content "$workdir" "${plan_file:-$diff_file}" > "$content_tmp"; then
    echo "consenso: no hay contenido que revisar (diff o plan vacío)" >&2
    rm -f "$content_tmp"
    return 3
  fi

  local run_dir titulo
  run_dir="$(consenso_run_dir "$workdir")"
  titulo="Ronda 0 — revisión independiente"
  [ "$modo" = "plan" ] && titulo="$titulo (plan)"
  consenso_init_log "$run_dir" "$titulo"
  # Persistir el modo para que el debate adapte su instrucción a este run.
  printf '%s' "$modo" > "$run_dir/modo"

  # Ronda 0 corre codex y agy EN PARALELO (spec: "en paralelo"). Cada uno
  # escribe en su propio fichero, así que no hay colisión. Lanzamos ambos en
  # background, esperamos a cada uno por separado y solo entonces logueamos,
  # en orden determinista (codex, luego agy) según el estado capturado.
  local prompt_codex prompt_agy
  prompt_codex="$(consenso_build_prompt "$CONSENSO_HOME/prompts/codex.md" "$content_tmp" "$modo")" \
    || { rm -f "$content_tmp"; return 2; }
  prompt_agy="$(consenso_build_prompt "$CONSENSO_HOME/prompts/agy.md" "$content_tmp" "$modo")" \
    || { rm -f "$content_tmp"; return 2; }

  local pid_codex pid_agy rc_codex rc_agy
  consenso_agent_with_retry codex "$prompt_codex" "$run_dir/codex.json" &
  pid_codex=$!
  consenso_agent_with_retry agy "$prompt_agy" "$run_dir/agy.json" &
  pid_agy=$!

  wait "$pid_codex"
  rc_codex=$?
  wait "$pid_agy"
  rc_agy=$?

  if [ "$rc_codex" -eq 0 ]; then
    consenso_log_append "$run_dir" "- codex: participó"
  else
    consenso_log_append "$run_dir" "- codex: NO participó (salida inválida o fallo del CLI)"
  fi
  if [ "$rc_agy" -eq 0 ]; then
    consenso_log_append "$run_dir" "- agy: participó"
  else
    consenso_log_append "$run_dir" "- agy: NO participó (salida inválida o fallo del CLI)"
  fi

  rm -f "$content_tmp"
  # Última línea de stdout: el run_dir, para que Claude sepa dónde leer.
  printf '%s\n' "$run_dir"
}

consenso_debate_instruccion() {
  # $1 = run_dir. Imprime la instrucción del debate según el modo persistido
  # por round0 en $run_dir/modo (sin fichero o modo diff: revisión de código).
  local contexto="una revisión de código"
  if [ -f "$1/modo" ] && [ "$(cat "$1/modo")" = "plan" ]; then
    contexto="la revisión de un plan de implementación (prosa, no código)"
  fi
  printf 'Estos son puntos en disputa de %s, con las críticas cruzadas de los otros revisores. Para cada punto, responde en prosa: ¿lo MANTIENES, lo REBATES o CEDES? Da un argumento técnico breve por cada uno.' "$contexto"
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

  local instruccion
  instruccion="$(consenso_debate_instruccion "$run_dir")"
  local points
  points="$(cat "$points_file")"
  local prompt="$instruccion

$points"

  local agent
  for agent in codex agy; do
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
