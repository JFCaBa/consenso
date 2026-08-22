# Agentes dinámicos y plugin — Plan de implementación

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sustituir los agentes hardcodeados de `consenso.sh` por un registro declarativo con detección dinámica (codex, agy, qwen, opencode), añadir el subcomando `doctor`, y empaquetar el repo como plugin de Claude Code.

**Architecture:** Un `agents/registry.json` describe cada CLI (invocación, extracción, lente); `consenso.sh` gana un runner genérico que interpreta esas entradas sin `eval` (argv por delimitador NUL) y detecta el elenco por PATH con degradación avisada. La fase 2 añade `.claude-plugin/` (plugin + marketplace propio, patrón superpowers) con la skill auto-disparable.

**Tech Stack:** bash 3.2 (macOS), jq, git; tests en bash plano con stubs (`tests/lib.sh`).

**Spec:** `docs/superpowers/specs/2026-08-22-agentes-dinamicos-y-plugin-design.md`

## Global Constraints

- Compatible **bash 3.2** (macOS): sin `declare -A`, sin `mapfile`; sí `${!var}`, arrays y `+=`.
- **Sin `eval`** en ninguna construcción de comandos.
- `id` de agente: `^[a-z0-9_]+$` (sirve como nombre de fichero y raíz de env var).
- Códigos de salida: `2` fallo de construcción/registro-agente desconocido, `3` contenido vacío, `4` cero agentes externos detectados, `64` error de uso, `65` registro inválido.
- Env vars nuevas: `CONSENSO_<ID>_BIN`, `CONSENSO_<ID>_MODEL`, `CONSENSO_AGENTS`; se eliminan `CONSENSO_CODEX_CMD` y `CONSENSO_AGY_CMD` **sin fallback** (decisión de consenso previa).
- Mensajes y comentarios en español, estilo del repo.
- Cada tarea termina con `bash tests/run.sh` en verde (`N/N OK`) antes de commitear.
- `tests/run.sh` ejecuta `tests/test_*.sh` por glob: los tests nuevos se recogen solos.

---

### Task 1: Registro de agentes y validación

**Files:**
- Create: `agents/registry.json`
- Create: `prompts/qwen.md`, `prompts/opencode.md`
- Modify: `consenso.sh` (tras la definición de `CONSENSO_HOME`, línea ~201)
- Test: `tests/test_registry.sh`

**Interfaces:**
- Produces: `CONSENSO_REGISTRY` (var global, ruta al registro; sobreescribible en tests), `consenso_registry_validar <fichero>` (rc 0/65), `consenso_agente_json <id>` (imprime el objeto JSON compacto del agente; rc 2 si no existe), `consenso_rol_de <id>`, `consenso_bin_de <id>`, `consenso_model_de <id>`, `consenso_timeout_de <id>` (imprimen valor resuelto con overrides).

- [ ] **Step 1: Escribir `agents/registry.json`**

```json
{
  "agentes": [
    {
      "id": "codex",
      "bin": "codex",
      "lente": "corrección, edge-cases, lógica fina, bordes de seguridad",
      "rol": "prompts/codex.md",
      "prioridad": 1,
      "prosa_argv": ["exec", "--skip-git-repo-check", "{PROMPT}"],
      "json": {
        "via": "schema",
        "argv": ["exec", "--skip-git-repo-check", "--output-schema", "{SCHEMA}", "-o", "{RAW}", "{PROMPT}"],
        "salida": "fichero",
        "extract": ".hallazgos"
      }
    },
    {
      "id": "agy",
      "bin": "agy",
      "lente": "arquitectura, contexto amplio, dependencias, coherencia del sistema",
      "rol": "prompts/agy.md",
      "prioridad": 2,
      "modelo_default": "Gemini 3.5 Flash (High)",
      "prosa_argv": ["--dangerously-skip-permissions", "--model", "{MODEL}", "-p", "{PROMPT}"],
      "json": {
        "via": "schema",
        "argv": ["--dangerously-skip-permissions", "--model", "{MODEL}", "--output-format", "json", "--json-schema", "{SCHEMA}", "-p", "{PROMPT}"],
        "salida": "stdout",
        "extract": ".structured_output.hallazgos"
      }
    },
    {
      "id": "qwen",
      "bin": "qwen",
      "lente": "tests, cobertura y rendimiento",
      "rol": "prompts/qwen.md",
      "prioridad": 3,
      "prosa_argv": ["--approval-mode", "yolo", "-p", "{PROMPT}"],
      "json": {
        "via": "prompt",
        "argv": ["--approval-mode", "yolo", "--output-format", "json", "-p", "{PROMPT}"],
        "salida": "stdout",
        "extract": ".response"
      }
    },
    {
      "id": "opencode",
      "bin": "opencode",
      "lente": "seguridad y manejo de errores",
      "rol": "prompts/opencode.md",
      "prioridad": 4,
      "prosa_argv": ["run", "{PROMPT}"],
      "json": {
        "via": "prompt",
        "argv": ["run", "{PROMPT}"],
        "salida": "stdout",
        "extract": "."
      }
    }
  ]
}
```

Nota: los flags de qwen/opencode son la mejor hipótesis verificable localmente; la Task 10 los contrasta con los CLIs reales y ajusta el registro si hace falta (los tests usan stubs, no dependen de los flags exactos).

- [ ] **Step 2: Escribir los prompts de rol nuevos**

`prompts/qwen.md`:

```markdown
Eres Qwen, revisor de código. Tu lente principal: **tests, cobertura y
rendimiento**. Busca comportamientos sin test, casos límite sin cubrir,
tests que no fallarían aunque el código estuviera roto, y costes evitables
(bucles innecesarios, trabajo repetido, I/O dentro de bucles). Puedes señalar
cualquier otra cosa que veas, pero prioriza tu lente.
```

`prompts/opencode.md`:

```markdown
Eres OpenCode, revisor de código. Tu lente principal: **seguridad y manejo de
errores**. Busca entradas sin validar, inyección (shell, SQL, rutas), secretos
expuestos, condiciones de error silenciadas o mal propagadas, y recursos sin
liberar. Puedes señalar cualquier otra cosa que veas, pero prioriza tu lente.
```

A ambos se les añade al final el mismo bloque `## Formato de salida (obligatorio)` que ya llevan `prompts/codex.md` y `prompts/agy.md` (copiarlo literal de `prompts/codex.md`).

- [ ] **Step 3: Escribir el test que falla** — `tests/test_registry.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

# El registro del repo es válido y sus ficheros de rol existen.
assert_exit 0 consenso_registry_validar "$HERE/../agents/registry.json"
for rol in $(jq -r '.agentes[].rol' "$HERE/../agents/registry.json"); do
  [ -f "$HERE/../$rol" ] || fail "falta el fichero de rol: $rol"
done

# Registros inválidos -> rc 65.
tmp="$(mktemp -d)"
printf '{"agentes":[]}' > "$tmp/vacio.json"
assert_exit 65 consenso_registry_validar "$tmp/vacio.json"
printf '{"agentes":[{"id":"MAL ID","bin":"x","lente":"l","rol":"r","prioridad":1,"prosa_argv":["a"],"json":{"via":"schema","argv":["a"],"salida":"stdout","extract":".x"}}]}' > "$tmp/id.json"
assert_exit 65 consenso_registry_validar "$tmp/id.json"
printf '{"agentes":[{"id":"a","bin":"x","lente":"l","rol":"r","prioridad":1,"prosa_argv":["a"],"json":{"via":"magia","argv":["a"],"salida":"stdout","extract":".x"}}]}' > "$tmp/via.json"
assert_exit 65 consenso_registry_validar "$tmp/via.json"
printf '{"agentes":[{"id":"a","bin":"x","lente":"l","rol":"r","prioridad":1,"prosa_argv":["a"],"json":{"via":"schema","argv":["a"],"salida":"stdout","extract":"map(.x)"}}]}' > "$tmp/extract.json"
assert_exit 65 consenso_registry_validar "$tmp/extract.json"

# Acceso a agentes.
assert_contains "$(consenso_agente_json codex)" '"id":"codex"' "devuelve el objeto de codex"
assert_exit 2 consenso_agente_json inexistente
assert_eq "$(consenso_rol_de agy)" "prompts/agy.md" "rol de agy"

# Overrides por entorno.
assert_eq "$(consenso_bin_de codex)" "codex" "bin por defecto"
assert_eq "$(CONSENSO_CODEX_BIN=/tmp/otro consenso_bin_de codex)" "/tmp/otro" "override de bin"
assert_eq "$(consenso_model_de agy)" "Gemini 3.5 Flash (High)" "modelo por defecto"
assert_eq "$(CONSENSO_AGY_MODEL=OtroModelo consenso_model_de agy)" "OtroModelo" "override de modelo"
assert_eq "$(consenso_model_de codex)" "" "sin modelo_default -> vacío"
assert_eq "$(consenso_timeout_de codex)" "120" "timeout global por defecto"
assert_eq "$(CONSENSO_TIMEOUT=7 consenso_timeout_de codex)" "7" "override global de timeout"

rm -rf "$tmp"
echo "OK test_registry"
```

- [ ] **Step 4: Verificar que falla**

Run: `bash tests/test_registry.sh`
Expected: FAIL — `consenso_registry_validar: command not found`.

- [ ] **Step 5: Implementar en `consenso.sh`** (justo después de `CONSENSO_HOME=...`):

```bash
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
```

- [ ] **Step 6: Verificar que pasa y que todo sigue verde**

Run: `bash tests/test_registry.sh && bash tests/run.sh`
Expected: `OK test_registry` y `11/11 OK`.

- [ ] **Step 7: Commit**

```bash
git add agents/registry.json prompts/qwen.md prompts/opencode.md consenso.sh tests/test_registry.sh
git commit -m "feat: registro declarativo de agentes con validación y overrides"
```

---

### Task 2: Detección y elenco

**Files:**
- Modify: `consenso.sh` (tras las funciones de Task 1)
- Test: `tests/test_detect.sh`

**Interfaces:**
- Consumes: `consenso_bin_de`, `CONSENSO_REGISTRY`.
- Produces: `consenso_detectar` — imprime los ids detectados (uno por línea, orden de prioridad); respeta `CONSENSO_AGENTS` (rc 64 si trae ids vacíos/desconocidos/duplicados). No imprime nada y rc 0 si no detecta ninguno (el llamante decide la degradación).

- [ ] **Step 1: Escribir el test que falla** — `tests/test_detect.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

# PATH controlado: solo existen los stubs que creamos aquí.
tmp="$(mktemp -d)"
mkdir "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/codex"; chmod +x "$tmp/bin/codex"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/qwen";  chmod +x "$tmp/bin/qwen"
export PATH="$tmp/bin"

# Detecta solo los presentes, en orden de prioridad del registro.
assert_eq "$(consenso_detectar)" "codex
qwen" "detecta codex y qwen en orden"

# Override de bin apunta a un binario existente -> el agente aparece.
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/agy-custom"; chmod +x "$tmp/bin/agy-custom"
assert_eq "$(CONSENSO_AGY_BIN="$tmp/bin/agy-custom" consenso_detectar)" "codex
agy
qwen" "override de bin activa a agy"

# CONSENSO_AGENTS filtra (en orden de prioridad, no de la lista).
assert_eq "$(CONSENSO_AGENTS=qwen,codex consenso_detectar)" "codex
qwen" "subconjunto respeta prioridad"

# CONSENSO_AGENTS inválido -> rc 64.
assert_exit 64 env CONSENSO_AGENTS=codex,noexiste bash -c ". '$HERE/../consenso.sh'; consenso_detectar"
assert_exit 64 env CONSENSO_AGENTS=codex,codex bash -c ". '$HERE/../consenso.sh'; consenso_detectar"
assert_exit 64 env CONSENSO_AGENTS=codex,, bash -c ". '$HERE/../consenso.sh'; consenso_detectar"

# Sin binarios -> imprime vacío, rc 0.
rm "$tmp/bin/codex" "$tmp/bin/qwen"
assert_eq "$(consenso_detectar)" "" "sin CLIs -> elenco vacío"

rm -rf "$tmp"
echo "OK test_detect"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_detect.sh`
Expected: FAIL — `consenso_detectar: command not found`.

- [ ] **Step 3: Implementar `consenso_detectar` en `consenso.sh`:**

```bash
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
```

- [ ] **Step 4: Verificar que pasa y que todo sigue verde**

Run: `bash tests/test_detect.sh && bash tests/run.sh`
Expected: `OK test_detect` y `12/12 OK`.

- [ ] **Step 5: Commit**

```bash
git add consenso.sh tests/test_detect.sh
git commit -m "feat: deteccion dinamica de agentes por PATH con CONSENSO_AGENTS"
```

---

### Task 3: Constructor de argv sin eval

**Files:**
- Modify: `consenso.sh`
- Test: `tests/test_argv.sh`

**Interfaces:**
- Consumes: `consenso_agente_json`.
- Produces: `consenso_argv <id> <prosa|json> <prompt> <schema> <raw> <model>` — rellena el array global `ARGV` con los argumentos sustituidos. Rc 2 si el agente no existe, 64 si el modo no es prosa|json.

- [ ] **Step 1: Escribir el test que falla** — `tests/test_argv.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

# Prosa de codex: sustituye {PROMPT} preservando saltos de línea y comillas.
prompt='línea 1
línea "dos" con espacios'
consenso_argv codex prosa "$prompt" "" "" ""
assert_eq "${#ARGV[@]}" "3" "codex prosa: 3 argumentos"
assert_eq "${ARGV[0]}" "exec" "primer argumento literal"
assert_eq "${ARGV[2]}" "$prompt" "el prompt llega intacto (newline y comillas)"

# JSON de agy: sustituye {MODEL}, {SCHEMA} y {PROMPT}.
consenso_argv agy json "p" "/ruta/schema.json" "/ruta/raw.json" "Modelo X"
assert_eq "${ARGV[2]}" "Modelo X" "sustituye {MODEL}"
assert_contains "${ARGV[*]}" "/ruta/schema.json" "sustituye {SCHEMA}"

# Errores de uso.
assert_exit 2 consenso_argv inexistente prosa p "" "" ""
assert_exit 64 consenso_argv codex chorra p "" "" ""

echo "OK test_argv"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_argv.sh`
Expected: FAIL — `consenso_argv: command not found`.

- [ ] **Step 3: Implementar `consenso_argv` en `consenso.sh`:**

```bash
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
  done < <(printf '%s' "$agente" | jq -j "$filtro | (., \"\u0000\")")
}
```

- [ ] **Step 4: Verificar que pasa y que todo sigue verde**

Run: `bash tests/test_argv.sh && bash tests/run.sh`
Expected: `OK test_argv` y `13/13 OK`.

- [ ] **Step 5: Commit**

```bash
git add consenso.sh tests/test_argv.sh
git commit -m "feat: constructor de argv desde el registro, sin eval y con NUL"
```

---

### Task 4: run_agent genérico (prosa) y stubs por CONSENSO_<ID>_BIN

**Files:**
- Modify: `consenso.sh` (`run_agent` completo)
- Modify: `tests/test_run_agent.sh`, `tests/test_debate.sh`, `tests/test_e2e.sh`, `tests/test_round0.sh`, `tests/test_validate_retry.sh` (renombrar exports `CONSENSO_CODEX_CMD`→`CONSENSO_CODEX_BIN`, `CONSENSO_AGY_CMD`→`CONSENSO_AGY_BIN`)

**Interfaces:**
- Consumes: `consenso_argv`, `consenso_bin_de`, `consenso_model_de`, `consenso_timeout_de`.
- Produces: `run_agent <id> <prompt> <out>` — igual contrato que hoy pero para cualquier id del registro; soporta `prompt_via: stdin` (el prompt entra por stdin y `{PROMPT}` se sustituye por cadena vacía... no: los argv de un agente stdin no llevan `{PROMPT}`).

- [ ] **Step 1: Ampliar el test** — en `tests/test_run_agent.sh`, sustituir los exports y añadir al final (antes del `echo "OK..."`):

```bash
# Los exports de la cabecera pasan a ser:
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"

# run_agent con id desconocido -> rc 2.
assert_exit 2 run_agent inexistente "p" "$tmp/x.json"

# prompt_via stdin: registro sintético con un agente que lee stdin.
reg="$tmp/registry-stdin.json"
cat > "$reg" <<'EOF'
{"agentes":[{"id":"lector","bin":"cat","lente":"l","rol":"prompts/codex.md","prioridad":1,
  "prompt_via":"stdin","prosa_argv":["-"],
  "json":{"via":"prompt","argv":["-"],"salida":"stdout","extract":"."}}]}
EOF
out_stdin="$( (CONSENSO_REGISTRY="$reg"; run_agent lector "hola por stdin" "$tmp/stdin.txt"); cat "$tmp/stdin.txt")"
assert_contains "$out_stdin" "hola por stdin" "prompt_via stdin entrega el prompt por stdin"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_run_agent.sh`
Expected: FAIL — `run_agent` actual no conoce `CONSENSO_CODEX_BIN` ni ids fuera de codex/agy (el primer assert que rompe es el del stub renombrado o el rc 2).

- [ ] **Step 3: Reescribir `run_agent` en `consenso.sh`** (sustituye la función entera; el comentario sobre agy/Flash se conserva encima de la lógica de modelo del registro, resumido):

```bash
run_agent() {
  # $1 = id del registro, $2 = prompt, $3 = fichero de salida. Uso: respuestas
  # en prosa (debate). Para hallazgos en JSON usa run_agent_json.
  # stdin cerrado salvo prompt_via=stdin (codex >=0.14x anexa stdin al prompt).
  local id="$1" prompt="$2" out="$3"
  local bin model timeout via
  bin="$(consenso_bin_de "$id")" || return 2
  model="$(consenso_model_de "$id")"
  timeout="$(consenso_timeout_de "$id")"
  via="$(consenso_agente_json "$id" | jq -r '.prompt_via // "argv"')"
  consenso_argv "$id" prosa "$prompt" "" "" "$model" || return $?
  if [ "$via" = "stdin" ]; then
    printf '%s' "$prompt" | run_with_timeout "$timeout" "$bin" "${ARGV[@]}" >"$out" 2>"$out.err"
  else
    run_with_timeout "$timeout" "$bin" "${ARGV[@]}" < /dev/null >"$out" 2>"$out.err"
  fi
}
```

Nota: con `prompt_via: stdin` los argv del agente no deben contener `{PROMPT}` (el prompt viaja solo por stdin); el registro real de v1 no activa stdin en ningún agente (decisión de consenso: solo tras smoke test).

- [ ] **Step 4: Actualizar los exports en el resto de tests**

En `tests/test_debate.sh`, `tests/test_e2e.sh`, `tests/test_round0.sh` y `tests/test_validate_retry.sh`: `CONSENSO_CODEX_CMD` → `CONSENSO_CODEX_BIN` y `CONSENSO_AGY_CMD` → `CONSENSO_AGY_BIN` (mismo valor).

- [ ] **Step 5: Verificar que pasa y que todo sigue verde**

Run: `bash tests/run.sh`
Expected: `13/13 OK` (test_validate_retry seguirá pasando porque `run_agent_json` aún es el antiguo y lee las vars viejas — si falla por las vars, la Task 5 lo arregla; en ese caso ejecutar los demás y dejar constancia). Si `run_agent_json` rompe aquí, adelantar solo el renombrado de vars dentro de `run_agent_json` (dos líneas: `codex_cmd="${CONSENSO_CODEX_BIN:-codex}"`, `agy_cmd="${CONSENSO_AGY_BIN:-agy}"`) para mantener el verde.

- [ ] **Step 6: Commit**

```bash
git add consenso.sh tests/
git commit -m "feat: run_agent generico desde el registro (prosa + prompt_via stdin)"
```

---

### Task 5: run_agent_json genérico (via schema y via prompt con normalización)

**Files:**
- Modify: `consenso.sh` (`run_agent_json` completo + helper `consenso_extraer_hallazgos`)
- Create: `tests/stubs/qwen`, `tests/stubs/opencode`
- Modify: `tests/test_validate_retry.sh`
- Test: `tests/test_via_prompt.sh`

**Interfaces:**
- Consumes: `consenso_argv`, `consenso_bin_de`, `consenso_model_de`, `consenso_timeout_de`, `consenso_validate_json`.
- Produces: `run_agent_json <id> <prompt> <out>` — mismo contrato que hoy para cualquier id; `consenso_extraer_hallazgos <id> <raw> <out>` (rc 0 si `out` queda con un array válido).

- [ ] **Step 1: Crear los stubs nuevos**

`tests/stubs/qwen` (emula `qwen -p` con `--output-format json`: sobre `{"response": "<texto del modelo>"}`; el texto trae fences para ejercitar la normalización):

```bash
#!/usr/bin/env bash
# Stub de qwen. JSON: sobre {"response":"..."} donde response es un string con
# el array de hallazgos dentro de fences markdown. Prosa: texto plano.
# Variables: STUB_QWEN_OUT, STUB_QWEN_EMPTY, STUB_QWEN_RC, STUB_QWEN_SLEEP.
sleep "${STUB_QWEN_SLEEP:-0}"
json_mode=0
for a in "$@"; do [ "$a" = "--output-format" ] && json_mode=1; done
if [ -z "${STUB_QWEN_EMPTY:-}" ]; then
  if [ "$json_mode" = "1" ]; then
    body="${STUB_QWEN_OUT:-[{\"severidad\":\"menor\",\"ubicacion\":\"foo.py:1\",\"problema\":\"sin test\",\"propuesta\":\"anadir test\"}]}"
    printf '{"response":"```json\\n%s\\n```"}' "$(printf '%s' "$body" | sed 's/"/\\"/g')"
  else
    printf '%s' "${STUB_QWEN_OUT:-qwen prosa de prueba: sin test}"
  fi
fi
exit "${STUB_QWEN_RC:-0}"
```

`tests/stubs/opencode` (emula `opencode run`: imprime el texto del modelo a stdout, con fences en modo "JSON pedido por prompt"):

```bash
#!/usr/bin/env bash
# Stub de opencode. Imprime STUB_OPENCODE_OUT (default: array de hallazgos
# entre fences, como respondería un modelo al que se le pide solo JSON).
# Variables: STUB_OPENCODE_OUT, STUB_OPENCODE_EMPTY, STUB_OPENCODE_RC, STUB_OPENCODE_SLEEP.
sleep "${STUB_OPENCODE_SLEEP:-0}"
if [ -z "${STUB_OPENCODE_EMPTY:-}" ]; then
  if [ -n "${STUB_OPENCODE_OUT:-}" ]; then
    printf '%s' "$STUB_OPENCODE_OUT"
  else
    printf '```json\n[{"severidad":"menor","ubicacion":"foo.py:1","problema":"error silenciado","propuesta":"propagar el error"}]\n```'
  fi
fi
exit "${STUB_OPENCODE_RC:-0}"
```

`chmod +x tests/stubs/qwen tests/stubs/opencode`

- [ ] **Step 2: Escribir el test que falla** — `tests/test_via_prompt.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"

tmp="$(mktemp -d)"

# qwen: sobre {"response":"```json ... ```"} -> array validado.
assert_exit 0 run_agent_json qwen "p" "$tmp/q.json"
assert_contains "$(cat "$tmp/q.json")" "sin test" "qwen: desenvuelve response y quita fences"
assert_exit 0 consenso_validate_json "$tmp/q.json"

# opencode: stdout con fences directamente -> array validado.
assert_exit 0 run_agent_json opencode "p" "$tmp/o.json"
assert_contains "$(cat "$tmp/o.json")" "error silenciado" "opencode: quita fences del stdout"

# Texto alrededor del JSON -> inválido (validación estricta, no rescate laxo).
STUB_OPENCODE_OUT='Aquí tienes: [{"severidad":"menor","ubicacion":"x","problema":"p","propuesta":"q"}] espero que sirva' \
  run_agent_json opencode "p" "$tmp/malo.json"
assert_exit 1 consenso_validate_json "$tmp/malo.json"

# El prompt JSON de un agente via prompt incluye las instrucciones de formato.
# (el stub no las ve, pero la función debe montarlas: se comprueba indirectamente
# con un stub 'espejo' que devuelve el prompt recibido)
cat > "$tmp/espejo" <<'EOF'
#!/usr/bin/env bash
last=""
for a in "$@"; do last="$a"; done
printf '{"response":"[]"}'
printf '%s' "$last" > "${STUB_ESPEJO_CAPTURA:-/dev/null}"
EOF
chmod +x "$tmp/espejo"
reg="$tmp/registry-espejo.json"
cat > "$reg" <<'EOF'
{"agentes":[{"id":"espejo","bin":"espejo","lente":"l","rol":"prompts/codex.md","prioridad":1,
  "prosa_argv":["{PROMPT}"],
  "json":{"via":"prompt","argv":["{PROMPT}"],"salida":"stdout","extract":".response"}}]}
EOF
CONSENSO_REGISTRY="$reg" CONSENSO_ESPEJO_BIN="$tmp/espejo" STUB_ESPEJO_CAPTURA="$tmp/captura.txt" \
  run_agent_json espejo "revisa esto" "$tmp/e.json"
assert_contains "$(cat "$tmp/captura.txt")" "Formato de salida" "via prompt añade _formato.md al prompt"

rm -rf "$tmp"
echo "OK test_via_prompt"
```

- [ ] **Step 3: Verificar que falla**

Run: `bash tests/test_via_prompt.sh`
Expected: FAIL — `run_agent_json` actual no conoce el id `qwen` (case sin rama → rc 2).

- [ ] **Step 4: Reescribir `run_agent_json` + helper en `consenso.sh`** (sustituye la función entera; conservar el comentario existente sobre el JSON Schema nativo, adaptado):

```bash
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
```

- [ ] **Step 5: Actualizar `tests/test_validate_retry.sh`** — ya usa ids `codex`/`agy`, solo asegurarse de que los exports son `CONSENSO_CODEX_BIN`/`CONSENSO_AGY_BIN` (hecho en Task 4) y de que sigue pasando.

- [ ] **Step 6: Verificar que pasa y que todo sigue verde**

Run: `bash tests/test_via_prompt.sh && bash tests/run.sh`
Expected: `OK test_via_prompt` y `14/14 OK`.

- [ ] **Step 7: Commit**

```bash
git add consenso.sh tests/
git commit -m "feat: run_agent_json generico con via schema/prompt y normalizacion de fences"
```

---

### Task 6: round0 N-ario con degradación y elenco persistido

**Files:**
- Modify: `consenso.sh` (`cmd_round0`)
- Modify: `tests/test_round0.sh`, `tests/test_e2e.sh`

**Interfaces:**
- Consumes: `consenso_detectar`, `consenso_rol_de`, `run_agent_json` (vía `consenso_agent_with_retry`, sin cambios).
- Produces: `run_dir/agentes` (ids del elenco, uno por línea), `run_dir/<id>.json` por agente; rc 4 sin agentes; `AVISO: consenso debilitado` en el log con 1. Contrato: **todo `<id>.json` del elenco existe y es un array válido** (`[]` si el agente no participó — lo garantiza `consenso_agent_with_retry`, que ya escribe `[]` al agotar reintentos); el log dice quién participó.

- [ ] **Step 1: Ampliar el test** — en `tests/test_round0.sh` (los exports ya apuntan a los stubs de codex y agy; el PATH real no tiene qwen/opencode en CI, así que fijar elenco explícito donde importe):

```bash
# Al principio, tras los exports existentes:
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"

# (sustituir las aserciones de codex.json/agy.json existentes: siguen valiendo)
# Elenco completo: 4 agentes -> 4 json + fichero agentes.
out4="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir4="$(printf '%s\n' "$out4" | tail -1)"
assert_eq "$(cat "$run_dir4/agentes")" "codex
agy
qwen
opencode" "persiste el elenco completo en orden"
assert_contains "$(cat "$run_dir4/qwen.json")" "sin test" "escribe qwen.json"
assert_contains "$(cat "$run_dir4/opencode.json")" "error silenciado" "escribe opencode.json"

# Degradación a 1 -> aviso.
out1="$(CONSENSO_AGENTS=codex bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir1="$(printf '%s\n' "$out1" | tail -1)"
assert_contains "$(cat "$run_dir1/log.md")" "consenso debilitado" "avisa con 1 solo agente"

# 0 agentes -> rc 4.
assert_exit 4 env PATH=/nonexistent CONSENSO_CODEX_BIN=/no CONSENSO_AGY_BIN=/no \
  CONSENSO_QWEN_BIN=/no CONSENSO_OPENCODE_BIN=/no \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"
```

Nota: `bash` y las utilidades del script deben seguir resolviéndose con `PATH=/nonexistent`… no resuelven. En su lugar, el caso 0 se cubre con overrides `CONSENSO_<ID>_BIN=/no/existe` para los 4 y el PATH intacto:

```bash
assert_exit 4 env CONSENSO_CODEX_BIN=/no/existe CONSENSO_AGY_BIN=/no/existe \
  CONSENSO_QWEN_BIN=/no/existe CONSENSO_OPENCODE_BIN=/no/existe \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_round0.sh`
Expected: FAIL — no existe `run_dir/agentes` ni `qwen.json`.

- [ ] **Step 3: Reescribir el tramo de agentes de `cmd_round0`** (desde `local prompt_codex prompt_agy` hasta los dos bloques de log inclusive) por:

```bash
  local elenco n id rol
  elenco="$(consenso_detectar)" || { rm -f "$content_tmp"; return $?; }
  n="$(printf '%s' "$elenco" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    echo "consenso: ningún agente externo detectado. Instala alguno de:" >&2
    jq -r '.agentes[] | "  - \(.bin) (\(.id))"' "$CONSENSO_REGISTRY" >&2
    rm -f "$content_tmp"
    return 4
  fi
  printf '%s\n' "$elenco" > "$run_dir/agentes"
  if [ "$n" -eq 1 ]; then
    consenso_log_append "$run_dir" "AVISO: consenso debilitado (1 solo agente externo: $elenco)"
  fi

  # Construir TODOS los prompts antes de lanzar nada: si uno falla, abortamos
  # sin dejar procesos huérfanos en background.
  local prompts=() ids=() prompt
  for id in $elenco; do
    rol="$(consenso_rol_de "$id")"
    prompt="$(consenso_build_prompt "$CONSENSO_HOME/$rol" "$content_tmp" "$modo")" \
      || { rm -f "$content_tmp"; return 2; }
    prompts[${#prompts[@]}]="$prompt"
    ids[${#ids[@]}]="$id"
  done

  # Lanzar todos en paralelo; esperar por pid para saber quién participó.
  local pids=() j=0
  for id in "${ids[@]}"; do
    consenso_agent_with_retry "$id" "${prompts[$j]}" "$run_dir/$id.json" &
    pids[${#pids[@]}]=$!
    j=$((j + 1))
  done
  local i=0 rc_agente
  for id in "${ids[@]}"; do
    wait "${pids[$i]}"
    rc_agente=$?
    if [ "$rc_agente" -eq 0 ]; then
      consenso_log_append "$run_dir" "- $id: participó"
    else
      consenso_log_append "$run_dir" "- $id: NO participó (salida inválida o fallo del CLI)"
    fi
    i=$((i + 1))
  done
```

- [ ] **Step 4: Actualizar `tests/test_e2e.sh`** — añadir los exports de qwen/opencode como en round0 y ampliar la aserción a los 4 `<id>.json` (mismas aserciones `jq -e .` que ya hace con codex/agy).

- [ ] **Step 5: Verificar que pasa y que todo sigue verde**

Run: `bash tests/run.sh`
Expected: `14/14 OK`.

- [ ] **Step 6: Commit**

```bash
git add consenso.sh tests/
git commit -m "feat: round0 N-ario con elenco detectado, persistido y degradacion avisada"
```

---

### Task 7: debate N-ario con fallback desde artefactos

**Files:**
- Modify: `consenso.sh` (`cmd_debate`)
- Modify: `tests/test_debate.sh`

**Interfaces:**
- Consumes: `run_dir/agentes` (Task 6), `run_agent`.
- Produces: `debate-<ronda>-<id>.md` por cada id del elenco; `consenso_elenco_de <run_dir>` (imprime el elenco: fichero `agentes` o, si falta, los `<id>.json` presentes).

- [ ] **Step 1: Ampliar el test** — en `tests/test_debate.sh` (los stubs de qwen/opencode exportados como en round0):

```bash
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"

# El run_dir del test declara un elenco de 3: el debate escribe 3 ficheros.
printf 'codex\nagy\nqwen\n' > "$run_dir/agentes"
out5="$(STUB_CODEX_OUT='Mantengo' STUB_AGY_OUT='Cedo' STUB_QWEN_OUT='Matizo' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir" --round 4)"
assert_contains "$(cat "$run_dir/debate-4-qwen.md")" "Matizo" "debate llega al tercer agente"

# Sin fichero agentes: reconstruye desde <id>.json (nunca redetecta).
rd_legacy="$tmp/.consenso/legacy"
mkdir -p "$rd_legacy"
printf '[]' > "$rd_legacy/codex.json"
printf '[]' > "$rd_legacy/agy.json"
. "$SCRIPT"
assert_eq "$(consenso_elenco_de "$rd_legacy")" "codex
agy" "reconstruye elenco desde artefactos"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_debate.sh`
Expected: FAIL — no existe `debate-4-qwen.md` (el bucle actual es `for agent in codex agy`).

- [ ] **Step 3: Implementar** — en `consenso.sh`, añadir helper y cambiar el bucle de `cmd_debate`:

```bash
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
```

En `cmd_debate`, sustituir `for agent in codex agy; do` por:

```bash
  local agent
  for agent in $(consenso_elenco_de "$run_dir"); do
```

(el cuerpo del bucle no cambia).

- [ ] **Step 4: Verificar que pasa y que todo sigue verde**

Run: `bash tests/run.sh`
Expected: `14/14 OK`.

- [ ] **Step 5: Commit**

```bash
git add consenso.sh tests/test_debate.sh
git commit -m "feat: debate N-ario sobre el elenco persistido, con fallback desde artefactos"
```

---

### Task 8: subcomando doctor

**Files:**
- Modify: `consenso.sh` (`cmd_doctor` + rama en `main`)
- Test: `tests/test_doctor.sh`

**Interfaces:**
- Consumes: `CONSENSO_REGISTRY`, `consenso_bin_de`, `run_agent_json`.
- Produces: `consenso.sh doctor` — una línea por agente del registro: `<id>: OK (<seg>s)`, `<id>: FALLO (...)` o `<id>: NOT FOUND (...)`. Rc 0 siempre que el registro sea válido (doctor informa, no falla).

- [ ] **Step 1: Escribir el test que falla** — `tests/test_doctor.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
SCRIPT="$HERE/../consenso.sh"

# codex responde, agy falla, qwen/opencode no instalados.
out="$(CONSENSO_CODEX_BIN="$HERE/stubs/codex" \
       CONSENSO_AGY_BIN="$HERE/stubs/agy" STUB_AGY_RC=1 \
       CONSENSO_QWEN_BIN=/no/existe CONSENSO_OPENCODE_BIN=/no/existe \
       bash "$SCRIPT" doctor)"
assert_contains "$out" "codex: OK" "codex OK"
assert_contains "$out" "agy: FALLO" "agy FALLO"
assert_contains "$out" "qwen: NOT FOUND" "qwen no instalado"
assert_contains "$out" "opencode: NOT FOUND" "opencode no instalado"

echo "OK test_doctor"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_doctor.sh`
Expected: FAIL — `consenso: subcomando desconocido: doctor` (rc 64, sin las líneas esperadas).

- [ ] **Step 3: Implementar `cmd_doctor`** en `consenso.sh` y registrar `doctor) cmd_doctor "$@" ;;` en `main`:

```bash
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
```

- [ ] **Step 4: Verificar que pasa y que todo sigue verde**

Run: `bash tests/test_doctor.sh && bash tests/run.sh`
Expected: `OK test_doctor` y `15/15 OK`.

- [ ] **Step 5: Commit**

```bash
git add consenso.sh tests/test_doctor.sh
git commit -m "feat: subcomando doctor con probe real y NOT FOUND instalable"
```

---

### Task 9: validación del registro en round0 y limpieza de vars muertas

**Files:**
- Modify: `consenso.sh`

**Interfaces:**
- Consumes: `consenso_registry_validar`.
- Produces: `cmd_round0` y `cmd_debate` fallan con rc 65 ante un registro inválido antes de tocar nada.

- [ ] **Step 1: Ampliar el test** — en `tests/test_round0.sh`:

```bash
# Registro inválido -> rc 65 antes de crear nada.
printf '{"agentes":[]}' > "$tmp/reg-malo.json"
assert_exit 65 env CONSENSO_REGISTRY="$tmp/reg-malo.json" \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"
```

Y el caso simétrico en `tests/test_debate.sh` (debate también valida antes de tocar nada):

```bash
printf '{"agentes":[]}' > "$tmp/reg-malo.json"
assert_exit 65 env CONSENSO_REGISTRY="$tmp/reg-malo.json" \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_round0.sh`
Expected: FAIL — round0 no valida el registro (rc distinto de 65).

- [ ] **Step 3: Implementar** — primera línea del cuerpo de `cmd_round0` y de `cmd_debate` (tras el parseo de flags):

```bash
  consenso_registry_validar "$CONSENSO_REGISTRY" || return $?
```

Además, borrar de `consenso.sh` cualquier resto de las vars legacy `CONSENSO_CODEX_CMD` y `CONSENSO_AGY_CMD` (verificar con `grep -n 'CONSENSO_\(CODEX\|AGY\)_CMD' consenso.sh` → sin resultados). Ojo: `CONSENSO_AGY_MODEL` NO es legacy — es la instancia válida del override genérico `CONSENSO_<ID>_MODEL` y los tests la usan.

- [ ] **Step 4: Verificar que pasa y que todo sigue verde**

Run: `bash tests/run.sh`
Expected: `15/15 OK`.

- [ ] **Step 5: Commit**

```bash
git add consenso.sh tests/test_round0.sh
git commit -m "feat: valida el registro al entrar y elimina las vars legacy"
```

---

### Task 10: smoke test real de qwen y opencode + docs de fase 1

**Files:**
- Modify: `agents/registry.json` (solo si el smoke test exige ajustar flags)
- Modify: `README.md`, `commands/consenso.md`

**Interfaces:**
- Consumes: todo lo anterior.
- Produces: registro contrastado con los CLIs reales; docs al día.

- [ ] **Step 1: Smoke test real (manual, gasta tokens)** — sobre este mismo repo con cambios sin commitear o un diff de prueba:

```bash
bash consenso.sh doctor
```

Expected: `codex: OK`, `agy: OK`, y `qwen`/`opencode` OK o FALLO. Si FALLO: leer el `.err` indicado, ajustar `prosa_argv`/`json.argv`/`extract` de esa entrada en `agents/registry.json` (p.ej. si `qwen` no acepta `--approval-mode yolo`, probar `--yolo`; si el sobre no es `.response`, mirar el raw y fijar el path real) y repetir hasta OK. Documentar en el commit qué flags reales quedaron.

- [ ] **Step 2: Verificar el elenco completo con una ronda real**

```bash
printf 'diff --git a/x.py b/x.py\n+def f(a,b): return a/b\n' > /tmp/diff-humo.txt
bash consenso.sh round0 --diff /tmp/diff-humo.txt --workdir .
cat .consenso/*/agentes .consenso/*/qwen.json .consenso/*/opencode.json
```

Expected: los 4 en `agentes`, arrays JSON válidos de los 4.

- [ ] **Step 3: Actualizar `README.md`** — sustituir la sección de Requisitos/Overrides por el elenco dinámico:

```markdown
## Requisitos

`jq`, `git`, y al menos un CLI de agente en modo headless. Los soportados
están en `agents/registry.json`: `codex`, `agy` (Antigravity), `qwen` y
`opencode`. Consenso detecta los instalados en cada ejecución y corre con los
que haya (con 1 solo agente lo marca como "consenso debilitado"; con 0, error).

`bash consenso.sh doctor` comprueba de verdad cada agente del registro
(instalado + llamada de prueba) y te dice cuáles participarían.

Overrides: `CONSENSO_<ID>_BIN`, `CONSENSO_<ID>_MODEL` (p.ej.
`CONSENSO_AGY_MODEL="Gemini 3.5 Flash (High)"`), `CONSENSO_AGENTS="codex,agy"`
para forzar un subconjunto, `CONSENSO_TIMEOUT` global (cede ante el `timeout`
por agente del registro). Con un modelo de la familia Pro, sube el timeout:
Pro (High) puede tardar >7 min por revisión.
```

- [ ] **Step 4: Actualizar `commands/consenso.md`** — en el paso 1 del Flujo, sustituir la mención fija a `codex.json`/`agy.json` por:

```markdown
1. **Ronda 0.** Ejecuta `bash <ruta>/consenso.sh round0 --workdir <repo>` (o
   `--diff <fichero>` / `--plan <fichero>`). Lee la última línea de la salida:
   es el `run_dir`. Lee `run_dir/agentes` (el elenco detectado) y el
   `run_dir/<id>.json` de cada agente listado ahí — no un glob de `*.json`.
   Si el log avisa de "consenso debilitado", pesa más tu propia lente y hazlo
   constar en el informe.
```

Y en el paso 4 (debate), `debate-1-codex.md / debate-1-agy.md` → `debate-1-<id>.md de cada agente del elenco`.

- [ ] **Step 5: Tests en verde y commit**

Run: `bash tests/run.sh`
Expected: `15/15 OK`.

```bash
git add agents/registry.json README.md commands/consenso.md
git commit -m "docs: elenco dinamico en README y command; registro contrastado con CLIs reales"
```

---

### Task 11: empaquetado como plugin de Claude Code

**Files:**
- Create: `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
- Create: `skills/consenso/SKILL.md`
- Modify: `commands/consenso.md` (se convierte en wrapper fino)
- Test: `tests/test_plugin.sh`

**Interfaces:**
- Consumes: `commands/consenso.md` actual (su contenido pasa a la skill).
- Produces: plugin instalable (`/plugin marketplace add JFCaBa/consenso` + `/plugin install consenso@consenso`).

- [ ] **Step 1: Escribir el test que falla** — `tests/test_plugin.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

jq -e . "$ROOT/.claude-plugin/plugin.json" >/dev/null || fail "plugin.json no es JSON válido"
assert_eq "$(jq -r .name "$ROOT/.claude-plugin/plugin.json")" "consenso" "nombre del plugin"
jq -e .version "$ROOT/.claude-plugin/plugin.json" >/dev/null || fail "plugin.json sin version"

jq -e . "$ROOT/.claude-plugin/marketplace.json" >/dev/null || fail "marketplace.json no es JSON válido"
assert_eq "$(jq -r '.plugins[0].source' "$ROOT/.claude-plugin/marketplace.json")" "./" "marketplace apunta al propio repo"
assert_eq "$(jq -r '.plugins[0].name' "$ROOT/.claude-plugin/marketplace.json")" "consenso" "marketplace publica consenso"

skill="$ROOT/skills/consenso/SKILL.md"
[ -f "$skill" ] || fail "falta skills/consenso/SKILL.md"
frontmatter="$(sed -n '2,/^---$/p' "$skill")"
assert_contains "$frontmatter" "name: consenso" "frontmatter con name"
assert_contains "$frontmatter" "antes de commitear" "descripción auto-disparable"
assert_contains "$(cat "$skill")" 'CLAUDE_PLUGIN_ROOT' "la skill usa CLAUDE_PLUGIN_ROOT"

echo "OK test_plugin"
```

- [ ] **Step 2: Verificar que falla**

Run: `bash tests/test_plugin.sh`
Expected: FAIL — no existe `.claude-plugin/plugin.json`.

- [ ] **Step 3: Crear los manifests**

`.claude-plugin/plugin.json`:

```json
{
  "name": "consenso",
  "description": "Revisión por consenso multiagente (Codex + Agy + Qwen + OpenCode + Claude) con debate cruzado, detección dinámica de CLIs y validación de planes y diffs",
  "version": "1.0.0",
  "author": { "name": "Jose", "email": "jfca68@gmail.com" },
  "homepage": "https://github.com/JFCaBa/consenso",
  "repository": "https://github.com/JFCaBa/consenso",
  "license": "MIT",
  "keywords": ["review", "consensus", "multi-agent", "codex", "gemini", "qwen", "opencode"]
}
```

`.claude-plugin/marketplace.json`:

```json
{
  "name": "consenso",
  "description": "Marketplace del plugin consenso",
  "owner": { "name": "Jose", "email": "jfca68@gmail.com" },
  "plugins": [
    {
      "name": "consenso",
      "description": "Revisión por consenso multiagente con debate cruzado y detección dinámica de CLIs",
      "version": "1.0.0",
      "source": "./",
      "author": { "name": "Jose", "email": "jfca68@gmail.com" }
    }
  ]
}
```

- [ ] **Step 4: Crear `skills/consenso/SKILL.md`** — el contenido íntegro del `commands/consenso.md` actual con este frontmatter y las rutas al script vía plugin root:

```markdown
---
name: consenso
description: Use SIEMPRE tras escribir un plan de implementación y antes de commitear un diff — revisión por consenso multiagente con debate cruzado y detección dinámica de CLIs (codex, agy, qwen, opencode)
---
```

Y en todos los comandos del cuerpo, `bash <ruta>/consenso.sh` pasa a:

```markdown
bash "${CLAUDE_PLUGIN_ROOT}/consenso.sh" round0 --workdir <repo>
```

(El CWD de una sesión es el workspace del usuario, no el plugin; `${CLAUDE_PLUGIN_ROOT}` la define Claude Code al cargar contenido del plugin.)

- [ ] **Step 5: Convertir `commands/consenso.md` en wrapper fino** — sustituir todo el cuerpo (manteniendo el frontmatter `description` actual) por:

```markdown
Invoca la skill `consenso` (este mismo plugin) y sigue su flujo completo sobre
el cambio o plan actual. Si la skill no está cargada, su fuente es
`skills/consenso/SKILL.md` junto a este fichero (instalación legacy por
symlink: el script es `consenso.sh` en la raíz del repo del command).
```

- [ ] **Step 6: Verificar que pasa y que todo sigue verde**

Run: `bash tests/test_plugin.sh && bash tests/run.sh`
Expected: `OK test_plugin` y `16/16 OK` (test_install sigue verde: `install.sh` no cambia).

- [ ] **Step 7: Commit**

```bash
git add .claude-plugin skills commands/consenso.md tests/test_plugin.sh
git commit -m "feat: empaqueta consenso como plugin de Claude Code con marketplace propio"
```

---

### Task 12: instalación local, migración y cierre

**Files:**
- Modify: `README.md` (sección Instalación)
- Delete (fuera del repo): `~/.claude/commands/consenso.md` (symlink legacy)

**Interfaces:**
- Consumes: el plugin de Task 11.
- Produces: plugin instalado en esta máquina sin duplicados; README con la instalación nueva.

- [ ] **Step 1: Actualizar la sección Instalación del README:**

```markdown
## Instalación

Como plugin de Claude Code (recomendado):

```
/plugin marketplace add JFCaBa/consenso
/plugin install consenso@consenso
```

Vía legacy sin plugins (symlink del slash command):

```bash
git clone https://github.com/JFCaBa/consenso
cd consenso
bash install.sh   # symlinka /consenso en ~/.claude/commands
```

No mezcles ambas: si instalas el plugin, borra el symlink
(`rm ~/.claude/commands/consenso.md`) para no duplicar la skill.
```

- [ ] **Step 2: Migrar esta máquina** — borrar el symlink legacy:

```bash
rm ~/.claude/commands/consenso.md
```

y pedir al usuario que ejecute en Claude Code: `/plugin marketplace add JFCaBa/consenso` y `/plugin install consenso@consenso` (o con el path local del repo si prefiere la copia de trabajo). Verificar después que la skill `consenso` aparece listada con la descripción nueva.

- [ ] **Step 3: Tests en verde**

Run: `bash tests/run.sh`
Expected: `16/16 OK`.

- [ ] **Step 4: Puerta de consenso final y push**

```bash
bash consenso.sh round0 --workdir .
# sintetizar/debatir según el flujo del command; aplicar lo acordado
git add -A
git commit -m "docs: instalacion como plugin y migracion del symlink legacy"
git push
```

Expected: informe de consenso en el `run_dir` y `main` pusheado.

---

## Self-review del plan

- **Cobertura del spec:** registro+validación (T1, T9), detección+CONSENSO_AGENTS+degradación (T2, T6), argv NUL sin eval (T3), prompt_via (T4), via schema/prompt+normalización (T5), elenco persistido+debate fallback (T6, T7), doctor completo (T8), lentes qwen/opencode (T1), smoke real+flags (T10), plugin+marketplace+SKILL con CLAUDE_PLUGIN_ROOT (T11), migración (T12). Backlog (rutas relativas) queda fuera, como manda el spec.
- **Placeholders:** ninguno — todo paso tiene código o comando concreto; el único punto abierto legítimo (flags reales de qwen/opencode) es una verificación empírica con instrucciones de ajuste (T10), decisión tomada en el spec.
- **Consistencia de tipos/nombres:** `consenso_agente_json`, `consenso_bin_de`, `consenso_model_de`, `consenso_timeout_de`, `consenso_rol_de`, `consenso_detectar`, `consenso_argv`/`ARGV`, `consenso_extraer_hallazgos`, `consenso_elenco_de` — usados con esas grafías en todas las tareas.
