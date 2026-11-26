#!/usr/bin/env bash
# consenso.sh — orquestador mecánico del flujo de consenso multiagente.
# Compatible con bash 3.2. Depende de: jq, git, utilidades POSIX.
set -u
# bash >=5.2 activa patsub_replacement: en ${var//pat/$rep} cada & de $rep se
# sustituye por el texto buscado, y el prompt ("a && b") llegaría corrupto. No
# vale entrecomillar "$rep": bash 3.2 (macOS) metería las comillas literales.
shopt -u patsub_replacement 2>/dev/null || true

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
  # Alcance: sin esto los revisores objetan código preexistente y un fix de
  # 20 líneas acaba arrastrando reescrituras ajenas al cambio.
  echo "ALCANCE: revisa solo el cambio (en un plan, lo que el plan propone) y"
  echo "lo que el cambio rompa o empeore. Si ves un problema en código o diseño"
  echo "que ya existía y que el cambio no toca ni agrava, o una ampliación que"
  echo "no sirve al objetivo, puedes señalarlo, pero márcalo como mucho \`menor\`"
  echo "y pon fuera_de_alcance: true. No propongas ampliar el cambio para"
  echo "arreglarlo."
  echo ""
  if [ "$modo" = "plan" ]; then
    echo "NOTA: lo que sigue es un PLAN DE IMPLEMENTACIÓN en prosa, no un diff."
    echo "Evalúa el diseño con tu lente: riesgos, pasos que faltan"
    echo "para el objetivo del plan, supuestos dudosos y alternativas más"
    echo "simples. En 'ubicacion' referencia la sección o el paso del plan."
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
  local had_monitor=0 timeout_dir timeout_marker
  case "$-" in *m*) had_monitor=1 ;; esac

  # Con job control, cada proceso lanzado en background lidera su propio grupo.
  # Es importante matar el grupo completo: varios CLIs son launchers que dejan
  # un hijo trabajando si solo se mata $cmd_pid. Ese hijo puede escribir una
  # respuesta tardía encima de los artefactos del reintento.
  timeout_dir="$(mktemp -d "${TMPDIR:-/tmp}/consenso-timeout.XXXXXX")" || {
    echo "consenso: no se pudo crear el estado temporal del timeout" >&2
    return 2
  }
  timeout_marker="$timeout_dir/fired"
  if ! set -m; then
    rmdir "$timeout_dir"
    echo "consenso: no se pudo aislar el grupo de procesos del comando" >&2
    return 2
  fi
  "$@" &
  local cmd_pid=$!
  (
    sleep "$secs"
    if kill -0 "$cmd_pid" 2>/dev/null; then
      : > "$timeout_marker"
      kill -KILL -- "-$cmd_pid" 2>/dev/null
      exit 124
    fi
  ) &
  local watcher=$!
  [ "$had_monitor" -eq 1 ] || set +m

  wait "$cmd_pid" 2>/dev/null
  local rc=$?

  if kill -0 "$watcher" 2>/dev/null; then
    # El watcher también tiene grupo propio; matar solo el subshell dejaría su
    # sleep vivo hasta agotar el timeout.
    kill -KILL -- "-$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
  else
    wait "$watcher" 2>/dev/null
  fi
  if [ -e "$timeout_marker" ]; then
    rm -f "$timeout_marker"
    rmdir "$timeout_dir"
    return 124
  fi
  rmdir "$timeout_dir"
  return "$rc"
}

consenso_run_cli_stdin() {
  # $1 = segundos de timeout, $2 = prompt, $3 = stdout, $4 = stderr, resto =
  # comando. Entrega el prompt por stdin desde un fichero, no por un pipe: así
  # un CLI que no lee stdin (o lo lee a medias) no provoca SIGPIPE con un
  # prompt grande. El fichero va junto a
  # la salida (en el run_dir, ignorado por git) y no en /tmp: si se interrumpe
  # el run, el sobrante no se acumula fuera de la vista.
  local t="$1" prompt="$2" out="$3" err="$4" pf="$3.prompt" rc
  shift 4
  printf '%s' "$prompt" > "$pf" || return 2
  run_with_timeout "$t" "$@" < "$pf" >"$out" 2>"$err"
  rc=$?
  rm -f "$pf"
  return "$rc"
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
    consenso_run_cli_stdin "$timeout" "$prompt" "$out" "$out.err" "$bin" "${ARGV[@]}"
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

consenso_validar_veredictos() {
  # $1 = fichero con el array de veredictos. 0 si cada elemento cumple el
  # contrato (punto y argumento string, veredicto del enum) y ningún punto se
  # repite. Los agentes via=prompt no validan esquema: esto lo hace por ellos.
  jq -e 'all(.[]; type=="object"
           and (.punto | type=="string")
           and (.argumento | type=="string")
           and (.veredicto | type=="string" and (. == "mantengo" or . == "rebato" or . == "cedo")))
         and ([.[].punto] | length == (unique | length))' "$1" >/dev/null 2>&1
}

consenso_validar_seguimiento() {
  # $1 = seguimiento (array), $2 = pendientes enviadas (array de {id, …}). 0 si
  # cada elemento cumple el contrato (objecion de las pendientes, estado
  # resuelta|sigue_abierta, argumento string) y ninguna objeción se repite.
  jq -e --slurpfile p "$2" '($p[0] | map(.id)) as $ids
    | type=="array"
    and all(.[]; type=="object"
      and (.objecion | type=="string") and (.objecion as $o | $ids | index($o) != null)
      and (.argumento | type=="string")
      and (.estado | type=="string" and (. == "resuelta" or . == "sigue_abierta")))
    and ([.[].objecion] | length == (unique | length))' "$1" >/dev/null 2>&1
}

consenso_extraer_json() {
  # $1=id, $2=fichero raw, $3=out, $4=clave (hallazgos por defecto, o
  # veredictos). Aplica extract del registro ({CLAVE} -> clave) y, para
  # via=prompt, normaliza en dos pasos: si el valor extraído es un string,
  # quita los fences exteriores y lo parsea como JSON. Valida el contrato final.
  local id="$1" raw="$2" out="$3" clave="${4:-hallazgos}"
  local via extract
  via="$(consenso_agente_json "$id" | jq -r '.json.via')"
  extract="$(consenso_agente_json "$id" | jq -r '.json.extract')"
  extract="${extract//\{CLAVE\}/$clave}"
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
  # Un esquema de varias claves (revise) llega como objeto también por
  # via=prompt: se toma la clave pedida.
  if jq -e --arg c "$clave" 'type=="object" and has($c)' "$out" >/dev/null 2>&1; then
    jq --arg c "$clave" '.[$c]' "$out" > "$out.clave" && mv "$out.clave" "$out"
  fi
  consenso_validate_json "$out" || return 1
  if [ "$clave" = "veredictos" ] && ! consenso_validar_veredictos "$out"; then
    echo "veredictos fuera de contrato (campos, enum o punto repetido)" >>"$out.err"
    return 1
  fi
}

run_agent_json() {
  # $1 = id del registro, $2 = prompt, $3 = out_file, y opcionales $4 =
  # esquema, $5 = clave envolvente, $6 = formato para via=prompt (por defecto,
  # los de hallazgos). Escribe el array JSON en $out. 0 si hay array válido.
  # via=schema: JSON Schema nativo del CLI (codex --output-schema, agy
  # --json-schema); via=prompt: instrucciones de _formato.md + normalización.
  local id="$1" prompt="$2" out="$3"
  local schema="${4:-$CONSENSO_HOME/prompts/hallazgos.schema.json}"
  local clave="${5:-hallazgos}"
  local formato="${6:-$CONSENSO_HOME/prompts/_formato.md}"
  local bin model timeout json_via prompt_via salida raw rc
  bin="$(consenso_bin_de "$id")" || return 2
  model="$(consenso_model_de "$id")"
  timeout="$(consenso_timeout_de "$id")"
  json_via="$(consenso_agente_json "$id" | jq -r '.json.via')"
  prompt_via="$(consenso_agente_json "$id" | jq -r '.prompt_via // "argv"')"
  salida="$(consenso_agente_json "$id" | jq -r '.json.salida')"
  raw="$out.raw"
  # Limpiar restos de ejecuciones/reintentos anteriores: un raw viejo podría
  # extraerse como éxito falso si el CLI falla sin escribir nada.
  rm -f "$raw" "$out.stdout"
  if [ "$json_via" = "prompt" ]; then
    prompt="$prompt

$(cat "$formato")"
  fi
  consenso_argv "$id" json "$prompt" "$schema" "$raw" "$model" || return $?
  # Destino del stdout: $raw si el JSON sale por stdout; ruido a $out.stdout
  # si el CLI escribe {RAW} él mismo (codex -o). Fuente del stdin: el prompt
  # con prompt_via=stdin, /dev/null si no.
  local stdout_dest="$out.stdout"
  [ "$salida" = "stdout" ] && stdout_dest="$raw"
  if [ "$prompt_via" = "stdin" ]; then
    consenso_run_cli_stdin "$timeout" "$prompt" "$stdout_dest" "$out.err" "$bin" "${ARGV[@]}"
  else
    run_with_timeout "$timeout" "$bin" "${ARGV[@]}" < /dev/null >"$stdout_dest" 2>"$out.err"
  fi
  rc=$?
  if [ "$rc" -ne 0 ] || [ ! -s "$raw" ]; then
    return 1
  fi
  consenso_extraer_json "$id" "$raw" "$out" "$clave"
}

consenso_agent_with_retry() {
  # $1 = agente, $2 = prompt, $3 = out_file, $4-$6 opcionales como en
  # run_agent_json (esquema, clave, formato). 0 si validó, 1 si agotó reintentos.
  local agent="$1"
  local prompt="$2"
  local out="$3"
  if run_agent_json "$agent" "$prompt" "$out" "${@:4}"; then
    return 0
  fi
  # Guardar el diagnóstico del 1er intento antes de reintentar: run_agent_json
  # reabre $out.err con ">" en cada llamada, así que si el 2o intento agota
  # sin escribir nada en stderr (fallo mudo), se perdería el único error real
  # que teníamos.
  local intento1_err=""
  [ -s "$out.err" ] && intento1_err="$(cat "$out.err")"
  # Reintento simple: la única causa de fallo con JSON Schema forzado es un
  # error transitorio del CLI/API (timeout, capacidad, etc.), no un problema
  # de formato — no hace falta variar el prompt.
  if run_agent_json "$agent" "$prompt" "$out" "${@:4}"; then
    return 0
  fi
  # La redirección de este bloque abre y trunca "$out.err" antes de ejecutar
  # nada dentro de él, así que hay que leer el stderr del 2o intento a una
  # variable ANTES de abrir el bloque, o siempre se leería ya vacío.
  local intento2_err=""
  [ -s "$out.err" ] && intento2_err="$(cat "$out.err")"
  {
    [ -n "$intento1_err" ] && printf 'intento 1:\n%s\n' "$intento1_err"
    [ -n "$intento2_err" ] && printf 'intento 2:\n%s\n' "$intento2_err"
    case "$intento1_err$intento2_err" in
      *"Argument list too long"*)
        echo "causa: prompt demasiado grande para pasarlo por argv (E2BIG)" ;;
    esac
    echo "agente sin salida válida tras reintento; tratado como no participante"
  } > "$out.err"
  # Sin $out a propósito: un [] sería indistinguible de "revisión sin
  # hallazgos" y un fallo se leería como un OK.
  rm -f "$out"
  return 1
}

consenso_resumen_triaje() {
  # $1 = <id>.json. Imprime "N hallazgos; F fuera de alcance, H hipotéticos".
  # Agentes via=prompt no validan campos: ausente = false, y "true" como
  # string cuenta como true (los modelos sin esquema a veces lo entrecomillan).
  jq -r 'def si(c): [.[] | select(c == true or c == "true")] | length;
    "\(length) hallazgos; \(si(.fuera_de_alcance)) fuera de alcance, \(si(.hipotetica)) hipotéticos"' "$1"
}

consenso_run_dir() {
  # $1 = workdir. Imprime y crea <workdir>/.consenso/<timestamp>.
  local workdir="$1"
  local ts="${CONSENSO_TIMESTAMP:-$(date +%Y-%m-%d-%H%M%S)}"
  local dir="$workdir/.consenso/$ts"
  mkdir -p "$dir"
  # Los runs son artefactos locales: que no aparezcan en el git status del repo.
  [ -e "$workdir/.consenso/.gitignore" ] || printf '*\n' > "$workdir/.consenso/.gitignore"
  printf '%s' "$dir"
}

consenso_validar_tarea() {
  # $1 = task, $2 = gate. 0 si ambos vacíos (sin tarea) o ambos válidos.
  local task="$1" gate="$2"
  [ -z "$task" ] && [ -z "$gate" ] && return 0
  if [ -z "$task" ] || [ -z "$gate" ]; then
    echo "consenso: --task y --gate van juntos" >&2
    return 64
  fi
  if ! printf '%s' "$task" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
    echo "consenso: --task inválido: '$task' (minúsculas, dígitos, _ y -)" >&2
    return 64
  fi
  if ! printf '%s' "$gate" | grep -Eq '^[1-9][0-9]*$'; then
    echo "consenso: --gate inválido: '$gate' (entero >= 1)" >&2
    return 64
  fi
}

consenso_tarea_dir() {
  # $1 = workdir, $2 = task, $3 = gate. Imprime <workdir>/.consenso/<task>/g<gate>.
  printf '%s/.consenso/%s/g%s' "$1" "$2" "$3"
}

consenso_reservar_version() {
  # $1 = workdir, $2 = task, $3 = gate, $4 = versión. Crea g<gate>/v<k> con
  # mkdir sin -p (atómico: de dos llamadas simultáneas solo una lo crea) e
  # imprime la ruta. rc 64 si ya existe.
  local gdir="$(consenso_tarea_dir "$1" "$2" "$3")" k="$4"
  mkdir -p "$gdir" || return 2
  [ -e "$1/.consenso/.gitignore" ] || printf '*\n' > "$1/.consenso/.gitignore"
  if ! mkdir "$gdir/v$k" 2>/dev/null; then
    if [ ! -d "$gdir/v$k" ]; then
      echo "consenso: no se pudo crear $gdir/v$k" >&2
      return 2
    fi
    if [ -f "$gdir/v$k/completo" ]; then
      echo "consenso: la tarea $2, gate $3, ya tiene v$k" >&2
    else
      echo "consenso: v$k incompleto (run interrumpido o en curso): borra $gdir/v$k y relanza" >&2
    fi
    return 64
  fi
  printf '%s' "$gdir/v$k"
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
      and (.json.extract? | type=="string" and test("^\\.(([a-zA-Z0-9_]+|\\{CLAVE\\})(\\.([a-zA-Z0-9_]+|\\{CLAVE\\}))*)?$"))
      and (.modelo_auto == null or (.modelo_auto | type=="object"
            and (.args | type=="array" and length>0 and all(.[]; type=="string"))
            and (.match | type=="string" and length>0)))
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

consenso_fijar_rutas() {
  # $1 = id. Llamar en un subshell ANTES de cambiar de directorio: fija como
  # absolutas las rutas relativas del registro y del binario del agente (p.ej.
  # CONSENSO_CODEX_BIN=./bin/codex), que tras el cd dejarían de resolverse.
  # Un nombre sin '/' sigue resolviéndose por PATH.
  local bin_var bin
  case "$CONSENSO_REGISTRY" in
    /*) : ;;
    *) CONSENSO_REGISTRY="$PWD/$CONSENSO_REGISTRY" ;;
  esac
  bin_var="CONSENSO_$(printf '%s' "$1" | tr 'a-z' 'A-Z')_BIN"
  bin="$(consenso_bin_de "$1")" || return $?
  case "$bin" in
    /*) : ;;
    */*) bin="$PWD/$bin" ;;
  esac
  printf -v "$bin_var" '%s' "$bin"
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

consenso_resolver_modelo_auto() {
  # $1 = id, $2 = objeto modelo_auto (JSON: {args:[...], match:"regex"}). Imprime
  # el ID de modelo MÁS NUEVO que case con .match en la salida de
  # `<bin> <args...>` (formato "ID<TAB>nombre", como `agy models`). "Más nuevo" =
  # mayor número de versión embebido en el ID. Vacío si el CLI falla, tarda o no
  # hay match: así consenso_model_de puede caer a modelo_default sin ruido.
  local id="$1" auto="$2"
  local bin match
  bin="$(consenso_bin_de "$id")" || return 0
  match="$(printf '%s' "$auto" | jq -r '.match')"
  local args=() a
  while IFS= read -r a; do
    [ -n "$a" ] && args[${#args[@]}]="$a"
  done < <(printf '%s' "$auto" | jq -r '.args[]')
  [ "${#args[@]}" -eq 0 ] && return 0
  # Timeout corto: consultar metadatos no debe bloquear el consenso.
  local out
  out="$(run_with_timeout 20 "$bin" "${args[@]}" < /dev/null 2>/dev/null)" || return 0
  # Del primer campo (ID) de las líneas que casan con .match, el más nuevo por
  # orden de versión. `sort -V` compara componente a componente (3.10 > 3.9 >
  # 3.8, y trata bien sufijos de parche), evitando el error de comparar como
  # float donde 3.10 se leería como 3.1 < 3.8.
  printf '%s' "$out" \
    | awk -F'\t' -v pat="$match" '$1 ~ pat { print $1 }' \
    | sort -V | tail -n 1
}

consenso_model_de() {
  # $1 = id. Modelo resuelto, por precedencia: CONSENSO_<ID>_MODEL (override) >
  # resolución dinámica vía modelo_auto (el CLI cambia de versión sin tocar el
  # registro) > modelo_default > vacío.
  local var="CONSENSO_$(printf '%s' "$1" | tr 'a-z' 'A-Z')_MODEL"
  local override="${!var:-}"
  if [ -n "$override" ]; then
    printf '%s' "$override"
    return 0
  fi
  local obj
  obj="$(consenso_agente_json "$1")" || return $?
  local auto
  auto="$(printf '%s' "$obj" | jq -c '.modelo_auto // empty')"
  if [ -n "$auto" ]; then
    local resuelto
    resuelto="$(consenso_resolver_modelo_auto "$1" "$auto")"
    if [ -n "$resuelto" ]; then
      printf '%s' "$resuelto"
      return 0
    fi
  fi
  printf '%s' "$obj" | jq -r '.modelo_default // ""'
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
  local ids id bin lista
  if [ -n "${CONSENSO_AGENTS:-}" ]; then
    # Tolera espacios alrededor de ids/comas (copiar-pegar, tecleo a mano).
    lista="${CONSENSO_AGENTS//[[:space:]]/}"
    # Comas al principio/final o dobles = token vacío (la command substitution
    # de jq no distinguiría "codex," de "codex"): guardia previa.
    case "$lista" in
      ,*|*,|*,,*)
        echo "consenso: CONSENSO_AGENTS contiene un id vacío" >&2
        return 64 ;;
    esac
    # Validación + filtrado en jq (ya es dependencia): error() -> rc != 0.
    ids="$(jq -r --arg lista "$lista" '
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
    # {PROMPT} se sustituye EL ÚLTIMO: si el propio prompt contiene literales
    # como "{SCHEMA}" (p.ej. consenso revisando el diff de su propio
    # registro), sustituir antes reescribiría ese texto por error.
    elem="${elem//\{SCHEMA\}/$schema}"
    elem="${elem//\{RAW\}/$raw}"
    elem="${elem//\{MODEL\}/$model}"
    elem="${elem//\{PROMPT\}/$prompt}"
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
  local task="" gate=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task|--gate)
        if [ $# -lt 2 ]; then
          echo "round0: falta valor para $1" >&2
          return 64
        fi
        if [ "$1" = "--task" ]; then task="$2"; else gate="$2"; fi
        shift 2 ;;
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

  consenso_registry_validar "$CONSENSO_REGISTRY" || return $?
  consenso_validar_tarea "$task" "$gate" || return $?

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
  if [ -n "$task" ]; then
    run_dir="$(consenso_reservar_version "$workdir" "$task" "$gate" 1)" || { local rc_res=$?; rm -f "$content_tmp"; return "$rc_res"; }
  else
    run_dir="$(consenso_run_dir "$workdir")"
  fi
  # Absoluto: los agentes se lanzan con cwd=$workdir (ver abajo).
  run_dir="$(cd "$run_dir" && pwd)"
  titulo="Ronda 0 — revisión independiente"
  [ "$modo" = "plan" ] && titulo="$titulo (plan)"
  consenso_init_log "$run_dir" "$titulo"
  # Persistir el modo para que el debate adapte su instrucción a este run, y
  # la entrada revisada para que el debate se la dé a los agentes (memoria).
  printf '%s' "$modo" > "$run_dir/modo"
  cp "$content_tmp" "$run_dir/entrada"
  [ -n "$task" ] && consenso_log_append "$run_dir" "Tarea: $task · gate $gate · v1"

  local elenco id rc
  elenco="$(consenso_preparar_elenco "$run_dir")" || { rc=$?; rm -f "$content_tmp"; return "$rc"; }
  consenso_escribir_prompts "$run_dir" "$content_tmp" "$modo" "" $elenco || { rm -f "$content_tmp"; return 2; }
  rm -f "$content_tmp"

  local resultados participo=0
  resultados="$(consenso_ejecutar_elenco "$run_dir" "$workdir" \
    "$CONSENSO_HOME/prompts/hallazgos.schema.json" "$CONSENSO_HOME/prompts/_formato.md" $elenco)"
  while read -r id rc; do
    [ -n "$id" ] || continue
    if [ "$rc" -eq 0 ]; then
      participo=1
      consenso_log_append "$run_dir" "- $id: participó ($(consenso_resumen_triaje "$run_dir/$id.json"))"
    else
      consenso_log_append "$run_dir" "$(consenso_linea_fallo "$id")"
    fi
  done <<EOF_RES
$resultados
EOF_RES

  # Marca de run terminado: distingue una versión completa de una interrumpida
  # o en la que no participó nadie (que se puede relanzar).
  [ "$participo" -eq 1 ] && : > "$run_dir/completo"
  # Última línea de stdout: el run_dir, para que Claude sepa dónde leer.
  printf '%s\n' "$run_dir"
}

consenso_preparar_elenco() {
  # $1 = run_dir. Detecta el elenco, lo persiste en run_dir/agentes, anota el
  # modo revisor único y lo imprime. rc 4 si no hay ningún agente.
  local run_dir="$1" elenco n
  elenco="$(consenso_detectar)" || return $?
  n="$(printf '%s' "$elenco" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    echo "consenso: ningún agente externo detectado. Instala alguno de:" >&2
    jq -r '.agentes[] | "  - \(.bin) (\(.id))"' "$CONSENSO_REGISTRY" >&2
    return 4
  fi
  printf '%s\n' "$elenco" > "$run_dir/agentes"
  [ "$n" -eq 1 ] && consenso_log_append "$run_dir" "Modo: revisor único ($elenco)"
  printf '%s\n' "$elenco"
}

consenso_escribir_prompts() {
  # $1 = run_dir, $2 = contenido, $3 = modo, $4 = fichero de contexto extra
  # (o vacío), resto = ids. Escribe run_dir/prompt-<id>.txt para cada agente
  # ANTES de lanzar nada: si uno falla, se aborta sin procesos huérfanos.
  local run_dir="$1" content="$2" modo="$3" contexto="$4" id rol
  shift 4
  for id in "$@"; do
    rol="$(consenso_rol_de "$id")" || return 2
    # Subshell, no grupo: el exit de un fallo no debe matar al script.
    (
      consenso_build_prompt "$CONSENSO_HOME/$rol" "$content" "$modo" || exit 2
      if [ -n "$contexto" ]; then
        printf '\n\n'
        cat "$contexto"
      fi
    ) > "$run_dir/prompt-$id.txt" || return 2
  done
}

consenso_ejecutar_elenco() {
  # $1 = run_dir, $2 = workdir, $3 = esquema, $4 = formato (via=prompt), resto
  # = ids. Lanza cada agente EN PARALELO con su run_dir/prompt-<id>.txt y
  # salida run_dir/<id>.json, e imprime "<id> <rc>" por agente, en orden.
  local run_dir="$1" workdir="$2" schema="$3" formato="$4" id
  shift 4
  local pids=() ids=() prompt
  for id in "$@"; do
    prompt="$(cat "$run_dir/prompt-$id.txt")"
    rm -f "$run_dir/prompt-$id.txt"
    # cwd = repo revisado: si el CLI explora, que explore ese repo y no el
    # directorio desde el que se llamó a consenso.
    ( consenso_fijar_rutas "$id" && cd "$workdir" \
        && consenso_agent_with_retry "$id" "$prompt" "$run_dir/$id.json" "$schema" hallazgos "$formato" ) &
    pids[${#pids[@]}]=$!
    ids[${#ids[@]}]="$id"
  done
  local i=0
  for id in "${ids[@]}"; do
    wait "${pids[$i]}"
    printf '%s %s\n' "$id" "$?"
    i=$((i + 1))
  done
}

consenso_linea_fallo() {
  # $1 = id. Línea de log de un agente que no dejó revisión.
  printf -- '- %s: FALLÓ — revisión fallida, no "sin hallazgos"; no hay %s.json (causa en %s.json.err)' "$1" "$1" "$1"
}

consenso_resumen_seguimiento() {
  # $1 = seguimiento validado, $2 = pendientes enviadas.
  jq -r --slurpfile p "$2" '
    ($p[0] | map(.id)) as $ids | ([.[].objecion]) as $vs
    | "seguimiento: \(map(select(.estado == "resuelta")) | length) resueltas, \(map(select(.estado == "sigue_abierta")) | length) siguen abiertas"
    + (($ids - $vs) | if length > 0 then "; sin seguimiento: \(join(", "))" else "" end)' "$1"
}

cmd_revise() {
  # Versión nueva de una tarea: reserva g<N>/v<k+1> y pide a cada agente, en
  # una llamada, hallazgos nuevos y un seguimiento de las objeciones pendientes.
  local workdir="." task="" gate="" diff_file="" plan_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task|--gate|--workdir|--diff|--plan)
        if [ $# -lt 2 ]; then
          echo "revise: falta valor para $1" >&2
          return 64
        fi
        case "$1" in
          --task) task="$2" ;;
          --gate) gate="$2" ;;
          --workdir) workdir="$2" ;;
          --diff) diff_file="$2" ;;
          --plan) plan_file="$2" ;;
        esac
        shift 2 ;;
      *) echo "revise: opción desconocida: $1" >&2; return 64 ;;
    esac
  done
  consenso_registry_validar "$CONSENSO_REGISTRY" || return $?
  if [ -z "$task" ]; then
    echo "revise: falta --task (y --gate)" >&2
    return 64
  fi
  consenso_validar_tarea "$task" "$gate" || return $?
  if [ -n "$plan_file" ] && [ -n "$diff_file" ]; then
    echo "revise: --plan y --diff son excluyentes" >&2
    return 64
  fi
  local modo="diff"
  [ -n "$plan_file" ] && modo="plan"

  local gdir k prev obj
  gdir="$(consenso_tarea_dir "$workdir" "$task" "$gate")"
  k="$(consenso_ultima_version "$gdir")"
  if [ -z "$k" ]; then
    echo "revise: la tarea $task, gate $gate, no tiene v1 (lanza round0 --task $task --gate $gate)" >&2
    return 64
  fi
  prev="$gdir/v$k"
  if [ ! -f "$prev/completo" ]; then
    echo "revise: v$k está incompleta (run interrumpido o sin participantes); borra $prev y relanza" >&2
    return 64
  fi
  obj="$gdir/objeciones.json"
  if [ ! -f "$obj" ]; then
    echo "revise: falta $obj; sintetiza v$k y escribe objeciones.json antes de revise" >&2
    return 64
  fi
  if ! consenso_validar_objeciones "$obj"; then
    echo "revise: $obj no cumple el contrato (version, ids O<n> únicos, estado válido, nota)" >&2
    return 65
  fi
  if [ "$(jq -r '.version' "$obj")" != "$k" ]; then
    echo "revise: objeciones.json es de v$(jq -r '.version' "$obj") y la última es v$k; sintetiza v$k antes de revise" >&2
    return 64
  fi

  local content_tmp
  content_tmp="$(mktemp)"
  if ! consenso_get_content "$workdir" "${plan_file:-$diff_file}" > "$content_tmp"; then
    echo "consenso: no hay contenido que revisar (diff o plan vacío)" >&2
    rm -f "$content_tmp"
    return 3
  fi
  if cmp -s "$content_tmp" "$prev/entrada"; then
    echo "revise: la entrada no cambió respecto a v$k" >&2
    rm -f "$content_tmp"
    return 64
  fi

  local nk=$((k + 1)) run_dir rc
  run_dir="$(consenso_reservar_version "$workdir" "$task" "$gate" "$nk")" || { rc=$?; rm -f "$content_tmp"; return "$rc"; }
  run_dir="$(cd "$run_dir" && pwd)"
  consenso_init_log "$run_dir" "Revisión de v$k"
  printf '%s' "$modo" > "$run_dir/modo"
  cp "$content_tmp" "$run_dir/entrada"
  rm -f "$content_tmp"
  consenso_log_append "$run_dir" "Tarea: $task · gate $gate · v$nk (revisión de v$k)"

  # Lo acordado también es pendiente: el revisor comprueba que se aplicó.
  jq '[.objeciones[] | select(.estado == "abierta" or .estado == "acordada") | {id, hallazgo, estado}]' "$obj" > "$run_dir/pendientes.json"
  diff -u -L "v$k/entrada" -L "v$nk/entrada" "$prev/entrada" "$run_dir/entrada" > "$run_dir/cambios"
  {
    printf '=== CAMBIOS RESPECTO A v%s ===\n' "$k"
    cat "$run_dir/cambios"
    printf '=== FIN DE LOS CAMBIOS ===\n\n=== OBJECIONES PENDIENTES ===\n'
    if [ "$(jq 'length' "$run_dir/pendientes.json")" -eq 0 ]; then
      printf 'sin objeciones pendientes\n'
    else
      cat "$run_dir/pendientes.json"
      printf '\n'
    fi
    printf '=== FIN DE LAS OBJECIONES ===\n\n'
    printf 'Esta es la versión v%s. Para CADA objeción pendiente, di en `seguimiento` si esta versión la resuelve (`resuelta`) o no (`sigue_abierta`), con el argumento. En `hallazgos`, solo problemas NUEVOS de esta versión.\n' "$nk"
  } > "$run_dir/contexto"

  local elenco id
  elenco="$(consenso_preparar_elenco "$run_dir")" || return $?
  consenso_escribir_prompts "$run_dir" "$run_dir/entrada" "$modo" "$run_dir/contexto" $elenco || return 2

  local resultados participo=0 linea seg
  resultados="$(consenso_ejecutar_elenco "$run_dir" "$workdir" \
    "$CONSENSO_HOME/prompts/revise.schema.json" "$CONSENSO_HOME/prompts/_formato_revise.md" $elenco)"
  while read -r id rc; do
    [ -n "$id" ] || continue
    if [ "$rc" -ne 0 ]; then
      consenso_log_append "$run_dir" "$(consenso_linea_fallo "$id")"
      continue
    fi
    participo=1
    linea="- $id: participó ($(consenso_resumen_triaje "$run_dir/$id.json")"
    seg="$run_dir/$id.seguimiento.json"
    if consenso_extraer_json "$id" "$run_dir/$id.json.raw" "$seg" seguimiento \
        && consenso_validar_seguimiento "$seg" "$run_dir/pendientes.json"; then
      linea="$linea; $(consenso_resumen_seguimiento "$seg" "$run_dir/pendientes.json"))"
    else
      rm -f "$seg"
      linea="$linea; seguimiento fuera de contrato, causa en $id.seguimiento.json.err)"
    fi
    consenso_log_append "$run_dir" "$linea"
  done <<EOF_RES
$resultados
EOF_RES

  [ "$participo" -eq 1 ] && : > "$run_dir/completo"
  printf '%s\n' "$run_dir"
}

consenso_elenco_de() {
  # $1 = run_dir. Imprime el elenco de la run: el fichero `agentes` o, si es
  # una run de una versión anterior, los <id>.json presentes cuyo basename es
  # un id del registro (nunca redetecta, para no mezclar elencos; y nunca
  # infiere agentes de JSON auxiliares como summary.json).
  local run_dir="$1" id
  if [ -f "$run_dir/agentes" ]; then
    cat "$run_dir/agentes"
    return 0
  fi
  for id in $(jq -r '.agentes | sort_by(.prioridad) | .[].id' "$CONSENSO_REGISTRY"); do
    if [ -f "$run_dir/$id.json" ]; then
      printf '%s\n' "$id"
    fi
  done
}

consenso_debate_instruccion() {
  # $1 = run_dir. Imprime la instrucción del debate según el modo persistido
  # por round0 en $run_dir/modo (sin fichero o modo diff: revisión de código).
  local contexto="una revisión de código"
  if [ -f "$1/modo" ] && [ "$(cat "$1/modo")" = "plan" ]; then
    contexto="la revisión de un plan de implementación (prosa, no código)"
  fi
  printf 'Estos son puntos en disputa de %s, con las críticas cruzadas de los otros revisores. Para CADA punto, por su id, da tu veredicto: lo MANTIENES, lo REBATES o CEDES, con un argumento técnico breve. Más abajo tienes la entrada revisada y tus hallazgos de la ronda 0: no hace falta que los busques.' "$contexto"
}

consenso_validar_puntos() {
  # $1 = fichero de puntos. 0 si es un array JSON no vacío de {id, punto,
  # posturas}, los tres strings (id no vacío) e id sin repetir.
  jq -e 'type=="array" and length>0
         and all(.[]; type=="object"
           and (.id | type=="string" and length>0)
           and (.punto | type=="string")
           and (.posturas | type=="string"))
         and ([.[].id] | length == (unique | length))' "$1" >/dev/null 2>&1
}

consenso_ronda_tiene() {
  # $1 = run_dir, $2 = ronda. 0 si algún agente dejó ya su veredicto.
  local f
  for f in "$1"/debate-"$2"-*.json; do
    [ -e "$f" ] && return 0
  done
  return 1
}

consenso_debate_prompt() {
  # $1 = run_dir, $2 = id, $3 = ronda, $4 = fichero de puntos. Imprime el
  # prompt del debate: instrucción, entrada revisada, hallazgos propios de la
  # ronda 0, veredictos de la ronda 1 (solo en la 2) y los puntos.
  local run_dir="$1" id="$2" ronda="$3" points="$4" x
  consenso_debate_instruccion "$run_dir"
  printf '\n'
  if [ -f "$run_dir/entrada" ]; then
    printf '\n=== ENTRADA REVISADA ===\n'
    cat "$run_dir/entrada"
    printf '\n=== FIN DE LA ENTRADA ===\n'
  fi
  if [ -f "$run_dir/$id.json" ]; then
    printf '\n=== TUS HALLAZGOS EN RONDA 0 ===\n'
    cat "$run_dir/$id.json"
    printf '\n'
  fi
  if [ "$ronda" = "2" ]; then
    printf '\n=== VEREDICTOS DE LA RONDA 1 ===\n'
    for x in $(consenso_elenco_de "$run_dir"); do
      if [ -f "$run_dir/debate-1-$x.json" ]; then
        printf -- '--- %s ---\n' "$x"
        cat "$run_dir/debate-1-$x.json"
        printf '\n'
      fi
    done
  fi
  printf '\n=== PUNTOS EN DISPUTA ===\n'
  cat "$points"
  printf '\n'
}

consenso_resumen_veredictos() {
  # $1 = veredictos de un agente, $2 = fichero de puntos. Imprime el recuento
  # por veredicto y, si aplica, los puntos sin veredicto y los ids desconocidos.
  jq -r --slurpfile p "$2" '
    ($p[0] | map(.id)) as $ids | ([.[].punto]) as $vs
    | def n(v): map(select(.veredicto == v)) | length;
    "\(length) veredictos: \(n("mantengo")) mantengo, \(n("rebato")) rebato, \(n("cedo")) cedo"
    + (($ids - $vs) | if length > 0 then "; sin veredicto: \(join(", "))" else "" end)
    + (($vs - $ids) | if length > 0 then "; id desconocido: \(join(", "))" else "" end)' "$1"
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

  consenso_registry_validar "$CONSENSO_REGISTRY" || return $?

  if [ ! -f "$points_file" ] || [ -z "$run_dir" ]; then
    echo "debate: faltan --points o --run-dir" >&2
    return 64
  fi
  case "$round" in
    1|2) ;;
    *) echo "debate: --round admite 1 o 2 (máximo 2 rondas; sin convergencia, al informe)" >&2
       return 64 ;;
  esac
  if ! consenso_validar_puntos "$points_file"; then
    echo "debate: --points debe ser un array JSON no vacío de {id, punto, posturas} con id único" >&2
    return 64
  fi

  local elenco
  elenco="$(consenso_elenco_de "$run_dir")"
  if [ -z "$elenco" ]; then
    echo "debate: elenco vacío en $run_dir (¿run-dir correcto?)" >&2
    return 64
  fi

  # Un agente via=schema sin {CLAVE} en extract solo sabe extraer hallazgos:
  # fallaría en cada llamada. Mejor un error de configuración antes de nada.
  local agent
  for agent in $elenco; do
    if consenso_agente_json "$agent" | jq -e '.json.via == "schema" and (.json.extract | contains("{CLAVE}") | not)' >/dev/null; then
      echo "debate: $agent extrae una clave fija; usa {CLAVE} en json.extract del registro" >&2
      return 65
    fi
  done

  if [ "$round" = "2" ] && ! consenso_ronda_tiene "$run_dir" 1; then
    echo "debate: la ronda 2 exige veredictos de la ronda 1" >&2
    return 64
  fi
  if [ "$round" = "1" ] && consenso_ronda_tiene "$run_dir" 2; then
    echo "debate: la ronda 2 ya empezó; no se vuelve a la ronda 1" >&2
    return 64
  fi
  local pendientes=""
  for agent in $elenco; do
    [ -f "$run_dir/debate-$round-$agent.json" ] || pendientes="$pendientes $agent"
  done
  if [ -z "$pendientes" ]; then
    echo "debate: la ronda $round ya está completa (máximo 2 rondas)" >&2
    return 64
  fi

  # cwd = repo del run (<repo>/.consenso/<ts>), igual que en round0.
  run_dir="$(cd "$run_dir" && pwd)"
  local repo="${run_dir%/.consenso/*}"
  # Los puntos de una ronda quedan fijados al primer intento: si al relanzarla
  # cambiaran, el run tendría veredictos sobre dos versiones del mismo id.
  local fijados="$run_dir/puntos-$round.json"
  if [ -f "$fijados" ]; then
    if ! cmp -s "$points_file" "$fijados"; then
      echo "debate: los puntos de la ronda $round ya están fijados; relánzala con --points $fijados" >&2
      return 64
    fi
  else
    cp "$points_file" "$fijados"
  fi
  [ -f "$run_dir/entrada" ] || consenso_log_append "$run_dir" "- debate ronda $round: sin entrada original (run de una versión anterior)"

  local prompt out
  for agent in $elenco; do
    out="$run_dir/debate-$round-$agent.json"
    if [ -f "$out" ]; then
      consenso_log_append "$run_dir" "- debate ronda $round: $agent ya respondió, se omite"
      continue
    fi
    prompt="$(consenso_debate_prompt "$run_dir" "$agent" "$round" "$points_file")"
    if ( consenso_fijar_rutas "$agent" && cd "$repo" && consenso_agent_with_retry "$agent" "$prompt" "$out" \
          "$CONSENSO_HOME/prompts/veredictos.schema.json" veredictos "$CONSENSO_HOME/prompts/_formato_veredictos.md" ); then
      consenso_log_append "$run_dir" "- debate ronda $round: $agent respondió ($(consenso_resumen_veredictos "$out" "$points_file"))"
    else
      consenso_log_append "$run_dir" "- debate ronda $round: $agent NO respondió (fallo del CLI, timeout o veredicto fuera de contrato; causa en $(basename "$out").err)"
    fi
  done

  printf '%s\n' "$run_dir"
}

consenso_validar_objeciones() {
  # $1 = objeciones.json. 0 si cumple el contrato: {version, objeciones} con
  # version entero >= 1 y objeciones de {id, hallazgo, estado, nota}; id
  # O<n> sin ceros a la izquierda y sin repetir.
  jq -e 'type=="object"
         and (.version | type=="number" and . >= 1 and . == floor)
         and (.objeciones | type=="array")
         and all(.objeciones[]; type=="object"
           and (.id | type=="string" and test("^O[1-9][0-9]*$"))
           and (.hallazgo | type=="string")
           and (.nota | type=="string")
           and (.estado | . == "abierta" or . == "acordada" or . == "resuelta" or . == "rechazada" or . == "fuera_de_alcance"))
         and ([.objeciones[].id] | length == (unique | length))' "$1" >/dev/null 2>&1
}

consenso_ultima_version() {
  # $1 = dir del gate. Imprime el mayor k de los v<k> (numérico: v10 > v9), o
  # nada si no hay versiones.
  local d k max=""
  for d in "$1"/v*; do
    [ -d "$d" ] || continue
    k="${d##*/v}"
    case "$k" in ''|*[!0-9]*) continue ;; esac
    if [ -z "$max" ] || [ "$k" -gt "$max" ]; then max="$k"; fi
  done
  printf '%s' "$max"
}

consenso_informe() {
  # $1 = objeciones.json, $2 = gate, $3 = versión. Imprime el informe de 4
  # secciones (Fuera de alcance solo si hay) y la tabla id | estado | hallazgo.
  jq -r --arg g "$2" --arg v "$3" '
    def plano: gsub("\n"; " ");
    def celda: plano | gsub("\\|"; "\\|");
    def item: "- **\(.id)** \(.hallazgo | plano)" + (if .nota != "" then " — \(.nota | plano)" else "" end);
    def seccion(t; ests): ([.objeciones[] | select(.estado as $e | ests | index($e) != null)]) as $xs
      | "### \(t)\n" + (if ($xs | length) == 0 then "- (ninguno)" else ($xs | map(item) | join("\n")) end) + "\n";
    "## Informe (gate \($g), v\($v))\n",
    seccion("Acordado"; ["acordada"]),
    seccion("Resuelto"; ["resuelta", "rechazada"]),
    seccion("Sin resolver"; ["abierta"]),
    (if any(.objeciones[]; .estado == "fuera_de_alcance") then seccion("Fuera de alcance"; ["fuera_de_alcance"]) else empty end),
    "#### Estado por objeción\n",
    "| id | estado | hallazgo |",
    "|---|---|---|",
    (.objeciones[] | "| \(.id) | \(.estado) | \(.hallazgo | celda) |")' "$1"
}

cmd_report() {
  # Informe de una tarea y gate a partir de g<N>/objeciones.json: lo escribe
  # en v<última>/informe.md (sobrescribe), lo imprime y deja un puntero en log.md.
  local workdir="." task="" gate=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --task|--gate|--workdir)
        if [ $# -lt 2 ]; then
          echo "report: falta valor para $1" >&2
          return 64
        fi
        case "$1" in
          --task) task="$2" ;;
          --gate) gate="$2" ;;
          --workdir) workdir="$2" ;;
        esac
        shift 2 ;;
      *) echo "report: opción desconocida: $1" >&2; return 64 ;;
    esac
  done
  if [ -z "$task" ]; then
    echo "report: falta --task (y --gate)" >&2
    return 64
  fi
  consenso_validar_tarea "$task" "$gate" || return $?

  local gdir obj k vdir
  gdir="$(consenso_tarea_dir "$workdir" "$task" "$gate")"
  obj="$gdir/objeciones.json"
  k="$(consenso_ultima_version "$gdir")"
  if [ -z "$k" ]; then
    echo "report: la tarea $task, gate $gate, no tiene versiones (lanza round0 --task $task --gate $gate)" >&2
    return 64
  fi
  if [ ! -f "$obj" ]; then
    echo "report: falta $obj; escríbelo tras la síntesis: {\"version\": $k, \"objeciones\": [{\"id\": \"O1\", \"hallazgo\", \"estado\", \"nota\"}]}" >&2
    return 64
  fi
  if ! consenso_validar_objeciones "$obj"; then
    echo "report: $obj no cumple el contrato (version, ids O<n> únicos, estado válido, nota)" >&2
    return 65
  fi
  local v_obj
  v_obj="$(jq -r '.version' "$obj")"
  if [ "$v_obj" != "$k" ]; then
    echo "report: objeciones.json es de v$v_obj y la última es v$k; actualízalo tras sintetizar v$k" >&2
    return 64
  fi

  vdir="$gdir/v$k"
  if [ ! -f "$vdir/completo" ]; then
    echo "report: v$k está incompleta (run interrumpido o en curso); termínala o borra $vdir" >&2
    return 64
  fi
  consenso_informe "$obj" "$gate" "$k" > "$vdir/informe.md" || return 2
  consenso_log_append "$vdir" "- informe: informe.md ($(jq -r '"\(.objeciones | length) objeciones: \([.objeciones[] | select(.estado == "abierta")] | length) abiertas"' "$obj"))"
  cat "$vdir/informe.md"
}

cmd_alternativa() {
  # Rediseño a ciegas: un agente (por defecto el de mayor prioridad detectado,
  # normalmente codex) diseña su propia solución leyendo SOLO el enunciado del
  # problema, sin ver la propuesta de Claude. Rompe el bucle de casos límite
  # cambiando de rol: el revisor pasa a diseñar.
  local workdir="."
  local problem_file=""
  local agent=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --workdir|--problem|--agent)
        if [ $# -lt 2 ]; then
          echo "alternativa: falta valor para $1" >&2
          return 64
        fi
        case "$1" in
          --workdir) workdir="$2" ;;
          --problem) problem_file="$2" ;;
          --agent) agent="$2" ;;
        esac
        shift 2 ;;
      *) echo "alternativa: opción desconocida: $1" >&2; return 64 ;;
    esac
  done

  consenso_registry_validar "$CONSENSO_REGISTRY" || return $?

  if [ -z "$problem_file" ] || [ ! -s "$problem_file" ]; then
    echo "alternativa: falta --problem <fichero> (o está vacío)" >&2
    return 64
  fi

  local elenco rc_detect
  elenco="$(consenso_detectar)" || { rc_detect=$?; return "$rc_detect"; }
  if [ -z "$agent" ]; then
    agent="$(printf '%s\n' "$elenco" | head -1)"
    if [ -z "$agent" ]; then
      echo "alternativa: ningún agente externo detectado" >&2
      return 4
    fi
  elif ! printf '%s\n' "$elenco" | grep -qxF "$agent"; then
    echo "alternativa: el agente '$agent' no está en el elenco detectado" >&2
    return 64
  fi

  local prompt
  prompt="$(cat "$CONSENSO_HOME/prompts/alternativa.md")

$(cat "$problem_file")"

  local run_dir out
  run_dir="$(consenso_run_dir "$workdir")"
  run_dir="$(cd "$run_dir" && pwd)"
  consenso_init_log "$run_dir" "Rediseño a ciegas ($agent)"
  out="$run_dir/alternativa-$agent.md"

  # El agente corre desde un directorio vacío: si se lanzara en el repo, un
  # CLI agéntico podría leer el árbol de trabajo y ver la propuesta que
  # precisamente debe ignorar.
  local ciego rc
  ciego="$(mktemp -d)"
  (
    consenso_fijar_rutas "$agent" && cd "$ciego" && run_agent "$agent" "$prompt" "$out"
  )
  rc=$?
  rmdir "$ciego" 2>/dev/null || rm -rf "$ciego"
  if [ "$rc" -eq 0 ]; then
    consenso_log_append "$run_dir" "- alternativa: $agent respondió"
  else
    consenso_log_append "$run_dir" "- alternativa: $agent NO respondió (fallo del CLI o timeout)"
  fi

  printf '%s\n' "$run_dir"
  return "$rc"
}

cmd_doctor() {
  # Diagnóstico: recorre TODO el registro. NOT FOUND para los no instalados
  # (con cómo sumarlos); para los instalados, una llamada real mínima por su
  # misma vía JSON — la respuesta correcta es el array vacío [], porque un
  # "OK" en texto no puede satisfacer a los CLIs con schema forzado.
  local id bin t0 t1 tmp
  consenso_registry_validar "$CONSENSO_REGISTRY" || return $?
  tmp="$(mktemp -d)"
  for id in $(jq -r '.agentes | sort_by(.prioridad) | .[].id' "$CONSENSO_REGISTRY"); do
    bin="$(consenso_bin_de "$id")"
    if ! command -v "$bin" >/dev/null 2>&1; then
      echo "$id: NOT FOUND ($bin no está en el PATH; instálalo para sumarlo al consenso)"
      continue
    fi
    t0="$(date +%s)"
    if run_agent_json "$id" "Prueba de conectividad: no hay nada que revisar. Devuelve un array de hallazgos vacío." "$tmp/$id.json"; then
      t1="$(date +%s)"
      echo "$id: OK ($((t1 - t0))s)"
    else
      echo "$id: FALLO (CLI presente pero sin salida válida). Últimas líneas de su stderr:"
      tail -5 "$tmp/$id.json.err" 2>/dev/null | sed 's/^/    /'
    fi
  done
  rm -rf "$tmp"
}

main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    round0) cmd_round0 "$@" ;;
    debate) cmd_debate "$@" ;;
    alternativa) cmd_alternativa "$@" ;;
    doctor) cmd_doctor "$@" ;;
    report) cmd_report "$@" ;;
    revise) cmd_revise "$@" ;;
    "") echo "uso: consenso.sh <round0|revise|debate|report|alternativa|doctor> [opciones]" >&2; return 64 ;;
    *) echo "consenso: subcomando desconocido: $sub" >&2; return 64 ;;
  esac
}

# Solo ejecutar main si se invoca directamente (no al hacer source).
if [ "${BASH_SOURCE:-$0}" = "$0" ]; then
  main "$@"
fi
