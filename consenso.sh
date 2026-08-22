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
  # $1 = id del registro, $2 = prompt, $3 = fichero de salida. Uso: respuestas
  # en prosa (debate). Para hallazgos en JSON usa run_agent_json.
  # stdin cerrado salvo prompt_via=stdin (codex >=0.14x anexa stdin al prompt).
  local id="$1" prompt="$2" out="$3"
  local bin model timeout via
  bin="$(consenso_bin_de "$id")" || return 2
  # El modelo por defecto (p.ej. Gemini Flash para la lente de arquitectura de
  # agy) vive en modelo_default del registro: se prefirió Flash a Pro (High)
  # porque Pro tardaba >7 min en un diff real y el timeout lo mataba, mientras
  # que Flash (High) responde en ~20-30s con JSON válido. Para usar un modelo
  # Pro hay que subir CONSENSO_TIMEOUT (ver README).
  model="$(consenso_model_de "$id")"
  timeout="$(consenso_timeout_de "$id")"
  via="$(consenso_agente_json "$id" | jq -r '.prompt_via // "argv"')"
  consenso_argv "$id" prosa "$prompt" "" "" "$model" || return $?
  if [ "$via" = "stdin" ]; then
    printf '%s' "$prompt" | run_with_timeout "$timeout" "$bin" "${ARGV[@]}" >"$out" 2>"$out.err"
  else
    # stdin explícitamente cerrado: codex >=0.14x (y en general cualquier CLI
    # con semántica propia de stdin) lee el stdin heredado y lo anexa al
    # prompt, añadiendo ruido y ~20s de latencia si no se cierra.
    run_with_timeout "$timeout" "$bin" "${ARGV[@]}" < /dev/null >"$out" 2>"$out.err"
  fi
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

consenso_desenfence() {
  # $1 = fichero. Imprime el contenido quitando SOLO la primera y la última
  # línea si son fences de markdown — nunca líneas interiores, que pueden ser
  # contenido legítimo de un hallazgo.
  awk 'NR==FNR { total=FNR; next }
       FNR==1 && $0 ~ /^[[:space:]]*```/ { next }
       FNR==total && $0 ~ /^[[:space:]]*```[[:space:]]*$/ { next }
       { print }' "$1" "$1"
}

consenso_extraer_hallazgos() {
  # $1=id, $2=fichero raw, $3=out. Aplica extract del registro y, para
  # via=prompt, normaliza en dos pasos: si el valor extraído es un string,
  # quita los fences exteriores y lo parsea como JSON. Valida el contrato final.
  local id="$1" raw="$2" out="$3"
  local via extract
  via="$(consenso_agente_json "$id" | jq -r '.json.via')"
  extract="$(consenso_agente_json "$id" | jq -r '.json.extract')"
  if [ "$via" = "schema" ]; then
    jq -e "$extract" "$raw" >"$out" 2>>"$out.err" || return 1
  else
    # El raw de un agente via prompt puede no ser JSON (p.ej. opencode imprime
    # el texto del modelo tal cual): si jq no lo parsea, quitar los fences
    # exteriores y tratar el conjunto como el JSON.
    if jq -e . "$raw" >/dev/null 2>&1; then
      jq -e "$extract" "$raw" >"$out.tmp" 2>>"$out.err" || return 1
      if jq -e 'type=="string"' "$out.tmp" >/dev/null 2>&1; then
        jq -r '.' "$out.tmp" >"$out.txt"
        consenso_desenfence "$out.txt" | jq -e '.' >"$out" 2>>"$out.err"
        local rc_norm=$?
        rm -f "$out.tmp" "$out.txt"
        [ "$rc_norm" -eq 0 ] || return 1
      else
        mv "$out.tmp" "$out"
      fi
    else
      consenso_desenfence "$raw" | jq -e '.' >"$out" 2>>"$out.err" || return 1
    fi
  fi
  consenso_validate_json "$out"
}

run_agent_json() {
  # $1 = id del registro, $2 = prompt, $3 = out_file. Escribe el array JSON de
  # hallazgos en $out (o [] si el agente no participó). 0 si hay array válido.
  # via=schema: JSON Schema nativo del CLI (codex --output-schema, agy
  # --json-schema); via=prompt: instrucciones de _formato.md + normalización.
  local id="$1" prompt="$2" out="$3"
  local bin model timeout via salida raw rc
  bin="$(consenso_bin_de "$id")" || return 2
  model="$(consenso_model_de "$id")"
  timeout="$(consenso_timeout_de "$id")"
  via="$(consenso_agente_json "$id" | jq -r '.json.via')"
  salida="$(consenso_agente_json "$id" | jq -r '.json.salida')"
  raw="$out.raw"
  # Limpiar restos de ejecuciones/reintentos anteriores: un raw viejo podría
  # extraerse como éxito falso si el CLI falla sin escribir nada.
  rm -f "$raw" "$out.stdout"
  if [ "$via" = "prompt" ]; then
    prompt="$prompt

$(cat "$CONSENSO_HOME/prompts/_formato.md")"
  fi
  consenso_argv "$id" json "$prompt" "$CONSENSO_HOME/prompts/hallazgos.schema.json" "$raw" "$model" || return $?
  # Destino del stdout: $raw si el JSON sale por stdout; ruido a $out.stdout
  # si el CLI escribe {RAW} él mismo (codex -o). Fuente del stdin: el prompt
  # con prompt_via=stdin, /dev/null si no.
  local stdout_dest="$out.stdout"
  [ "$salida" = "stdout" ] && stdout_dest="$raw"
  if [ "$(consenso_agente_json "$id" | jq -r '.prompt_via // "argv"')" = "stdin" ]; then
    printf '%s' "$prompt" | run_with_timeout "$timeout" "$bin" "${ARGV[@]}" >"$stdout_dest" 2>"$out.err"
  else
    run_with_timeout "$timeout" "$bin" "${ARGV[@]}" < /dev/null >"$stdout_dest" 2>"$out.err"
  fi
  rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$raw" ]; then
    return 1
  fi
  consenso_extraer_hallazgos "$id" "$raw" "$out"
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
  local obj
  obj="$(consenso_agente_json "$1")" || return $?
  printf '%s' "$obj" | jq -r '.rol'
}

consenso_bin_de() {
  # $1 = id. Binario resuelto: CONSENSO_<ID>_BIN o el bin del registro.
  local var="CONSENSO_$(printf '%s' "$1" | tr 'a-z' 'A-Z')_BIN"
  local override="${!var:-}"
  if [ -n "$override" ]; then
    printf '%s' "$override"
  else
    local obj
    obj="$(consenso_agente_json "$1")" || return $?
    printf '%s' "$obj" | jq -r '.bin'
  fi
}

consenso_model_de() {
  # $1 = id. Modelo resuelto: CONSENSO_<ID>_MODEL o modelo_default (o vacío).
  local var="CONSENSO_$(printf '%s' "$1" | tr 'a-z' 'A-Z')_MODEL"
  local override="${!var:-}"
  if [ -n "$override" ]; then
    printf '%s' "$override"
  else
    local obj
    obj="$(consenso_agente_json "$1")" || return $?
    printf '%s' "$obj" | jq -r '.modelo_default // ""'
  fi
}

consenso_timeout_de() {
  # $1 = id. Timeout: el del agente en el registro, o CONSENSO_TIMEOUT, o 120.
  local obj
  obj="$(consenso_agente_json "$1")" || return $?
  local propio
  propio="$(printf '%s' "$obj" | jq -r '.timeout // ""')"
  if [ -n "$propio" ]; then
    printf '%s' "$propio"
  else
    printf '%s' "${CONSENSO_TIMEOUT:-120}"
  fi
}

consenso_detectar() {
  # Imprime los ids de agentes cuyo binario está en el PATH, en orden de
  # prioridad del registro. CONSENSO_AGENTS="a,b" restringe a ese subconjunto
  # (validado contra el registro: rc 64 si hay ids vacíos/desconocidos/dupes).
  local ids id bin
  if [ -n "${CONSENSO_AGENTS:-}" ]; then
    # Comas al principio/final o dobles = token vacío (la command substitution
    # de jq no distinguiría "codex," de "codex"): guardia previa.
    case "$CONSENSO_AGENTS" in
      ,*|*,|*,,*)
        echo "consenso: CONSENSO_AGENTS contiene un id vacío" >&2
        return 64 ;;
    esac
    # Validación + filtrado en jq (ya es dependencia): error() -> rc != 0.
    ids="$(jq -r --arg lista "$CONSENSO_AGENTS" '
      ($lista | split(",")) as $pedido
      | [.agentes[].id] as $conocidos
      | if ($pedido | unique | length) != ($pedido | length) then error("dup")
        elif ([$pedido[] | select(. as $p | $conocidos | index($p) == null)] | length) > 0 then error("desconocido")
        else .agentes | sort_by(.prioridad) | .[].id | select(. as $i | $pedido | index($i) != null)
        end' "$CONSENSO_REGISTRY" 2>/dev/null)" || {
      echo "consenso: CONSENSO_AGENTS contiene ids desconocidos o duplicados" >&2
      return 64
    }
  else
    ids="$(jq -r '.agentes | sort_by(.prioridad) | .[].id' "$CONSENSO_REGISTRY")"
  fi
  for id in $ids; do
    bin="$(consenso_bin_de "$id")"
    if command -v "$bin" >/dev/null 2>&1; then
      printf '%s\n' "$id"
    fi
  done
  return 0
}

consenso_argv() {
  # $1=id, $2=prosa|json, $3=prompt, $4=schema, $5=raw, $6=model.
  # Rellena el array global ARGV con los argumentos del registro, sustituyendo
  # placeholders. Sin eval; delimitador NUL para preservar saltos de línea.
  local id="$1" modo="$2" prompt="$3" schema="$4" raw="$5" model="$6"
  local filtro elem agente
  case "$modo" in
    prosa) filtro='.prosa_argv[]' ;;
    json)  filtro='.json.argv[]' ;;
    *) echo "consenso_argv: modo desconocido: $modo" >&2; return 64 ;;
  esac
  agente="$(consenso_agente_json "$id")" || return 2
  ARGV=()
  while IFS= read -r -d '' elem; do
    elem="${elem//\{PROMPT\}/$prompt}"
    elem="${elem//\{SCHEMA\}/$schema}"
    elem="${elem//\{RAW\}/$raw}"
    elem="${elem//\{MODEL\}/$model}"
    ARGV[${#ARGV[@]}]="$elem"
  done < <(printf '%s' "$agente" | jq -j "$filtro | (., \"\\u0000\")")
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
