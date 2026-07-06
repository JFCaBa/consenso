# Consenso multiagente — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Construir un flujo global reutilizable donde Codex y Gemini revisan un diff cada uno con su lente, Claude sintetiza y orquesta un debate cruzado, y se produce un informe de consenso con trazabilidad.

**Architecture:** Un script `consenso.sh` (parte mecánica: fan-out a los CLIs, timeout, validación, logging) expone dos subcomandos primitivos — `round0` (revisión independiente) y `debate` (ronda de rebatir/ceder). Un slash command `~/.claude/commands/consenso.md` instruye a Claude para disparar el flujo, añadir su propia revisión, deduplicar/clasificar hallazgos, decidir qué va a debate y redactar el informe. Claude revisa en la sesión; el script solo invoca `codex` y `gemini` como subprocesos.

**Tech Stack:** Bash, `jq`, `git`, CLIs `codex` (`codex exec`) y `gemini` (`gemini -p`). Tests en bash plano con stubs de los CLIs (no hay `bats`).

## Global Constraints

- **Bash 3.2 compatible**: sin arrays asociativos, sin `mapfile`, sin `${var,,}`, sin `timeout` de GNU. Usar ficheros temporales en vez de arrays asociativos y un helper propio de timeout.
- **Dependencias permitidas**: solo `jq` (presente), `git`, utilidades POSIX estándar. Prohibido depender de `bats`, `shellcheck`, `gtimeout`.
- **Contrato de hallazgo**: cada agente devuelve un array JSON de objetos con las claves exactas `severidad`, `ubicacion`, `problema`, `propuesta`. `severidad` ∈ `{bloqueante, importante, menor, nit}`.
- **Agentes**: `codex` se invoca como `codex exec "<prompt>"`; `gemini` como `gemini -p "<prompt>"`. Claude NO se invoca como subproceso — revisa en la sesión.
- **Comandos overridables** (para tests): `CONSENSO_CODEX_CMD` (default `codex`), `CONSENSO_GEMINI_CMD` (default `gemini`).
- **Timestamp overridable** (para tests): `CONSENSO_TIMESTAMP` (default `date +%Y-%m-%d-%H%M%S`).
- **Salida/log**: bajo `<workdir>/.consenso/<timestamp>/`. `.consenso/` va en `.gitignore`.
- **Timeout por agente**: default 120s, override con `CONSENSO_TIMEOUT`.
- **Commits frecuentes**: uno por tarea como mínimo.

---

## File Structure

- `consenso.sh` — orquestador mecánico. Al hacer `source` define funciones; al ejecutar corre `main`. Contiene: `consenso_get_diff`, `consenso_build_prompt`, `run_with_timeout`, `run_agent`, `consenso_validate_json`, `consenso_agent_with_retry`, `consenso_init_log`, `consenso_log_append`, `cmd_round0`, `cmd_debate`, `main`.
- `prompts/codex.md` — prompt de rol de Codex (lente: corrección/edge-cases) + instrucción de formato.
- `prompts/gemini.md` — prompt de rol de Gemini (lente: arquitectura/dependencias) + formato.
- `prompts/claude.md` — prompt de rol de Claude (lente: legibilidad/mantenibilidad); lo usa Claude en la sesión.
- `prompts/_formato.md` — bloque compartido con el contrato de hallazgo (JSON). Incluido por los tres.
- `commands/consenso.md` — el slash command (fuente); se instala/symlinka en `~/.claude/commands/consenso.md`.
- `install.sh` — symlinka `commands/consenso.md` en `~/.claude/commands/` y hace `consenso.sh` ejecutable.
- `tests/lib.sh` — helpers de aserción (`assert_eq`, `assert_contains`, `assert_exit`, `fail`).
- `tests/run.sh` — runner: ejecuta todos los `tests/test_*.sh`, agrega resultados.
- `tests/stubs/` — stubs de `codex` y `gemini` configurables por variables de entorno.
- `tests/test_*.sh` — un fichero de test por área.

---

## Task 1: Test harness

**Files:**
- Create: `tests/lib.sh`
- Create: `tests/run.sh`
- Create: `tests/test_harness.sh`
- Modify: `.gitignore`

**Interfaces:**
- Produces: `assert_eq <actual> <expected> [msg]`, `assert_contains <haystack> <needle> [msg]`, `assert_exit <expected_code> <cmd...>`, `fail <msg>`. Cada test file es un script ejecutable que hace `source tests/lib.sh`, corre aserciones, y sale 0 si todas pasan. `tests/run.sh` ejecuta `tests/test_*.sh` y sale != 0 si alguno falla.

- [ ] **Step 1: Write the failing test**

Create `tests/test_harness.sh`:

```bash
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_harness.sh`
Expected: FAIL — `tests/lib.sh: No such file or directory`

- [ ] **Step 3: Write the assertion library**

Create `tests/lib.sh`:

```bash
# Helpers de aserción para tests en bash plano. Hacer `source`.
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
```

- [ ] **Step 4: Write the test runner**

Create `tests/run.sh`:

```bash
#!/usr/bin/env bash
# Ejecuta todos los tests/test_*.sh y agrega resultados.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
failed=0
total=0
for t in "$HERE"/test_*.sh; do
  [ -e "$t" ] || continue
  total=$((total + 1))
  if bash "$t"; then
    echo "PASS $(basename "$t")"
  else
    echo "FAIL $(basename "$t")"
    failed=$((failed + 1))
  fi
done
echo "----"
echo "$((total - failed))/$total OK"
[ "$failed" -eq 0 ]
```

- [ ] **Step 5: Add .consenso to .gitignore**

Ensure `.gitignore` contains (ya existe la línea de commits previos; añadir si falta):

```
.consenso/
.DS_Store
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `bash tests/run.sh`
Expected: PASS — `PASS test_harness.sh` y `1/1 OK`, exit 0.

- [ ] **Step 7: Commit**

```bash
chmod +x tests/run.sh tests/test_harness.sh
git add tests/ .gitignore
git commit -m "test: arnés de tests en bash plano con stubs"
```

---

## Task 2: `consenso_build_prompt` (función pura)

**Files:**
- Create: `consenso.sh`
- Create: `tests/test_build_prompt.sh`
- Create: `tests/fixtures/rol_demo.md`
- Create: `tests/fixtures/diff_demo.txt`

**Interfaces:**
- Produces: `consenso_build_prompt <rol_file> <diff_file>` imprime en stdout el prompt completo = contenido de `<rol_file>` + separador + el diff. Termina 0. Si `<rol_file>` o `<diff_file>` no existen, sale 2. `consenso.sh` usa el patrón: al hacer `source` define funciones; solo ejecuta `main "$@"` si se invoca directamente.

- [ ] **Step 1: Write the failing test**

Create `tests/fixtures/rol_demo.md`:

```
Eres un revisor. Lente: demo.
Devuelve solo hallazgos.
```

Create `tests/fixtures/diff_demo.txt`:

```
+++ b/foo.py
+def foo():
+    return 1/0
```

Create `tests/test_build_prompt.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

out="$(consenso_build_prompt "$HERE/fixtures/rol_demo.md" "$HERE/fixtures/diff_demo.txt")"
assert_contains "$out" "Lente: demo" "incluye el rol"
assert_contains "$out" "return 1/0" "incluye el diff"

# Ficheros inexistentes -> exit 2
assert_exit 2 consenso_build_prompt "/no/existe.md" "$HERE/fixtures/diff_demo.txt"

echo "OK test_build_prompt"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_build_prompt.sh`
Expected: FAIL — `consenso.sh: No such file or directory`

- [ ] **Step 3: Create consenso.sh with the function and the source/exec guard**

Create `consenso.sh`:

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_build_prompt.sh`
Expected: PASS — `OK test_build_prompt`

- [ ] **Step 5: Commit**

```bash
chmod +x consenso.sh tests/test_build_prompt.sh
git add consenso.sh tests/test_build_prompt.sh tests/fixtures/
git commit -m "feat: consenso_build_prompt (rol + diff)"
```

---

## Task 3: `run_with_timeout` y `run_agent` (con stubs)

**Files:**
- Modify: `consenso.sh`
- Create: `tests/stubs/codex`
- Create: `tests/stubs/gemini`
- Create: `tests/test_run_agent.sh`

**Interfaces:**
- Consumes: `consenso_build_prompt` (Task 2).
- Produces:
  - `run_with_timeout <segundos> <cmd...>` ejecuta el comando; si excede el tiempo lo mata y devuelve 124; si no, devuelve el código del comando. Respeta la redirección de stdout del llamante.
  - `run_agent <agente> <prompt_string> <out_file>` con `agente` ∈ `codex|gemini`. Invoca el CLI correspondiente (`$CONSENSO_CODEX_CMD exec` / `$CONSENSO_GEMINI_CMD -p`), captura stdout en `<out_file>`, stderr en `<out_file>.err`. Devuelve el código del CLI (124 si timeout). Usa `CONSENSO_TIMEOUT` (default 120).

- [ ] **Step 1: Write the stubs**

Create `tests/stubs/codex`:

```bash
#!/usr/bin/env bash
# Stub de codex para tests. Comportamiento controlado por variables de entorno:
#   STUB_CODEX_OUT   -> texto a emitir por stdout (default: JSON válido de 1 hallazgo)
#   STUB_CODEX_SLEEP -> segundos a dormir antes de responder (default 0)
#   STUB_CODEX_RC    -> código de salida (default 0)
# Se espera invocación: codex exec "<prompt>"
sleep "${STUB_CODEX_SLEEP:-0}"
if [ -n "${STUB_CODEX_OUT:-}" ]; then
  printf '%s' "$STUB_CODEX_OUT"
else
  printf '%s' '[{"severidad":"importante","ubicacion":"foo.py:2","problema":"division por cero","propuesta":"validar divisor"}]'
fi
exit "${STUB_CODEX_RC:-0}"
```

Create `tests/stubs/gemini`:

```bash
#!/usr/bin/env bash
# Stub de gemini para tests. Variables:
#   STUB_GEMINI_OUT / STUB_GEMINI_SLEEP / STUB_GEMINI_RC (análogas al stub de codex)
# Se espera invocación: gemini -p "<prompt>"
sleep "${STUB_GEMINI_SLEEP:-0}"
if [ -n "${STUB_GEMINI_OUT:-}" ]; then
  printf '%s' "$STUB_GEMINI_OUT"
else
  printf '%s' '[{"severidad":"menor","ubicacion":"foo.py:1","problema":"sin docstring","propuesta":"anadir docstring"}]'
fi
exit "${STUB_GEMINI_RC:-0}"
```

- [ ] **Step 2: Write the failing test**

Create `tests/test_run_agent.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_GEMINI_CMD="$HERE/stubs/gemini"
chmod +x "$CONSENSO_CODEX_CMD" "$CONSENSO_GEMINI_CMD"

tmp="$(mktemp -d)"

# run_agent codex captura JSON del stub.
run_agent codex "prompt de prueba" "$tmp/codex.json"
assert_contains "$(cat "$tmp/codex.json")" "division por cero" "codex escribe su salida"

# run_agent gemini.
run_agent gemini "prompt de prueba" "$tmp/gemini.json"
assert_contains "$(cat "$tmp/gemini.json")" "docstring" "gemini escribe su salida"

# Timeout: el stub duerme 5s pero el timeout es 1s -> rc 124.
STUB_CODEX_SLEEP=5 CONSENSO_TIMEOUT=1 run_agent codex "x" "$tmp/slow.json"
assert_exit 124 bash -c "STUB_CODEX_SLEEP=5 CONSENSO_TIMEOUT=1 CONSENSO_CODEX_CMD='$CONSENSO_CODEX_CMD'; . '$HERE/../consenso.sh'; run_agent codex x '$tmp/slow2.json'"

rm -rf "$tmp"
echo "OK test_run_agent"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash tests/test_run_agent.sh`
Expected: FAIL — `run_agent: command not found`

- [ ] **Step 4: Implement run_with_timeout and run_agent**

Add to `consenso.sh` (antes de `main`):

```bash
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_run_agent.sh`
Expected: PASS — `OK test_run_agent`

- [ ] **Step 6: Commit**

```bash
chmod +x tests/stubs/codex tests/stubs/gemini tests/test_run_agent.sh
git add consenso.sh tests/stubs/ tests/test_run_agent.sh
git commit -m "feat: run_agent con timeout portable y stubs de CLI"
```

---

## Task 4: Validación JSON y reintento

**Files:**
- Modify: `consenso.sh`
- Create: `tests/test_validate_retry.sh`

**Interfaces:**
- Consumes: `run_agent` (Task 3).
- Produces:
  - `consenso_validate_json <file>` devuelve 0 si el contenido es un array JSON, 1 si no. Usa `jq -e 'type=="array"'`.
  - `consenso_agent_with_retry <agente> <prompt> <out_file>` llama a `run_agent`; si la salida no valida como array JSON, reintenta UNA vez añadiendo al prompt un recordatorio de formato; si sigue sin validar, escribe `[]` en `<out_file>`, un motivo en `<out_file>.err`, y devuelve 1 (el agente "no participó"). Devuelve 0 si validó.

- [ ] **Step 1: Write the failing test**

Create `tests/test_validate_retry.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
tmp="$(mktemp -d)"

# validate: array válido pasa, prosa no.
printf '%s' '[{"a":1}]' > "$tmp/ok.json"
assert_exit 0 consenso_validate_json "$tmp/ok.json"
printf '%s' 'esto no es json' > "$tmp/bad.json"
assert_exit 1 consenso_validate_json "$tmp/bad.json"

# retry: stub devuelve basura las dos veces -> out queda en [] y rc 1.
STUB_CODEX_OUT="basura no-json" consenso_agent_with_retry codex "p" "$tmp/r.json"
rc=$?
assert_eq "$rc" "1" "retry agotado devuelve 1"
assert_eq "$(cat "$tmp/r.json")" "[]" "retry agotado deja array vacio"

# retry: stub devuelve JSON válido -> rc 0.
assert_exit 0 bash -c ". '$HERE/../consenso.sh'; CONSENSO_CODEX_CMD='$CONSENSO_CODEX_CMD' consenso_agent_with_retry codex p '$tmp/g.json'"

rm -rf "$tmp"
echo "OK test_validate_retry"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_validate_retry.sh`
Expected: FAIL — `consenso_validate_json: command not found`

- [ ] **Step 3: Implement validation and retry**

Add to `consenso.sh` (antes de `main`):

```bash
consenso_validate_json() {
  # $1 = fichero. 0 si es array JSON, 1 si no.
  jq -e 'type=="array"' "$1" >/dev/null 2>&1
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_validate_retry.sh`
Expected: PASS — `OK test_validate_retry`

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_validate_retry.sh
git add consenso.sh tests/test_validate_retry.sh
git commit -m "feat: validacion JSON y reintento de formato por agente"
```

---

## Task 5: Logging con timestamp overridable

**Files:**
- Modify: `consenso.sh`
- Create: `tests/test_log.sh`

**Interfaces:**
- Produces:
  - `consenso_run_dir <workdir>` imprime `<workdir>/.consenso/<timestamp>` (usando `CONSENSO_TIMESTAMP` si está, si no `date +%Y-%m-%d-%H%M%S`), creando el directorio. 
  - `consenso_init_log <run_dir> <titulo>` crea `<run_dir>/log.md` con una cabecera.
  - `consenso_log_append <run_dir> <texto>` añade una línea al `log.md`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_log.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
tmp="$(mktemp -d)"

export CONSENSO_TIMESTAMP="2026-07-06-1200"
dir="$(consenso_run_dir "$tmp")"
assert_eq "$dir" "$tmp/.consenso/2026-07-06-1200" "run_dir usa el timestamp"
assert_exit 0 test -d "$dir" "run_dir crea el directorio"

consenso_init_log "$dir" "Revisión demo"
assert_contains "$(cat "$dir/log.md")" "Revisión demo" "init_log escribe el titulo"

consenso_log_append "$dir" "linea de prueba"
assert_contains "$(cat "$dir/log.md")" "linea de prueba" "log_append anade"

rm -rf "$tmp"
echo "OK test_log"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_log.sh`
Expected: FAIL — `consenso_run_dir: command not found`

- [ ] **Step 3: Implement logging**

Add to `consenso.sh` (antes de `main`):

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_log.sh`
Expected: PASS — `OK test_log`

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_log.sh
git add consenso.sh tests/test_log.sh
git commit -m "feat: logging con directorio de run y timestamp overridable"
```

---

## Task 6: Prompts de rol

**Files:**
- Create: `prompts/_formato.md`
- Create: `prompts/codex.md`
- Create: `prompts/gemini.md`
- Create: `prompts/claude.md`
- Create: `tests/test_prompts.sh`

**Interfaces:**
- Produces: cuatro ficheros de prompt. Los de rol (`codex.md`, `gemini.md`, `claude.md`) terminan con el contenido de `_formato.md` embebido (copiado), de modo que cada uno es autosuficiente para `consenso_build_prompt`.

- [ ] **Step 1: Write the failing test**

Create `tests/test_prompts.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
P="$HERE/../prompts"

for f in codex gemini claude; do
  assert_exit 0 test -f "$P/$f.md" "existe prompts/$f.md"
  # Cada prompt de rol debe declarar el contrato de hallazgo.
  assert_contains "$(cat "$P/$f.md")" "severidad" "prompts/$f.md declara el contrato"
  assert_contains "$(cat "$P/$f.md")" "propuesta" "prompts/$f.md declara propuesta"
done

assert_contains "$(cat "$P/codex.md")" "edge-case" "codex declara su lente"
assert_contains "$(cat "$P/gemini.md")" "arquitectura" "gemini declara su lente"
assert_contains "$(cat "$P/claude.md")" "legibilidad" "claude declara su lente"

echo "OK test_prompts"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_prompts.sh`
Expected: FAIL — `existe prompts/codex.md` (fichero no existe)

- [ ] **Step 3: Create the shared format block**

Create `prompts/_formato.md`:

```markdown
## Formato de salida (obligatorio)

Responde EXCLUSIVAMENTE con un array JSON, sin texto antes ni después. Cada
elemento es un hallazgo con estas claves exactas:

- `severidad`: uno de `bloqueante` | `importante` | `menor` | `nit`
- `ubicacion`: `ruta:linea` o descripción del punto
- `problema`: qué está mal o qué riesgo hay
- `propuesta`: el cambio concreto sugerido

Si no encuentras nada, responde `[]`.
```

- [ ] **Step 4: Create the three role prompts (con el formato embebido)**

Create `prompts/codex.md`:

```markdown
Eres Codex, revisor de código. Tu lente principal: **corrección, edge-cases,
lógica fina y bordes de seguridad**. Busca fallos que rompen en runtime, casos
límite no cubiertos, errores off-by-one, condiciones de carrera, entradas no
validadas y bordes de seguridad. Puedes señalar cualquier otra cosa que veas,
pero prioriza tu lente.

## Formato de salida (obligatorio)

Responde EXCLUSIVAMENTE con un array JSON, sin texto antes ni después. Cada
elemento es un hallazgo con estas claves exactas:

- `severidad`: uno de `bloqueante` | `importante` | `menor` | `nit`
- `ubicacion`: `ruta:linea` o descripción del punto
- `problema`: qué está mal o qué riesgo hay
- `propuesta`: el cambio concreto sugerido

Si no encuentras nada, responde `[]`.
```

Create `prompts/gemini.md`:

```markdown
Eres Gemini, revisor de código. Tu lente principal: **arquitectura, contexto
amplio, dependencias y coherencia del sistema**. Busca decisiones de diseño
cuestionables, acoplamientos, incoherencias con el resto del sistema, nuevas
dependencias injustificadas y problemas que solo se ven mirando el conjunto.
Puedes señalar cualquier otra cosa que veas, pero prioriza tu lente.

## Formato de salida (obligatorio)

Responde EXCLUSIVAMENTE con un array JSON, sin texto antes ni después. Cada
elemento es un hallazgo con estas claves exactas:

- `severidad`: uno de `bloqueante` | `importante` | `menor` | `nit`
- `ubicacion`: `ruta:linea` o descripción del punto
- `problema`: qué está mal o qué riesgo hay
- `propuesta`: el cambio concreto sugerido

Si no encuentras nada, responde `[]`.
```

Create `prompts/claude.md`:

```markdown
Eres Claude, revisor de código y orquestador. Tu lente principal:
**legibilidad, mantenibilidad y claridad**. Busca nombres confusos, funciones
que hacen demasiado, duplicación, y código que costará mantener. Además
orquestas el debate: no incluyas aquí la síntesis, solo tus hallazgos con tu
lente.

## Formato de salida (obligatorio)

Responde EXCLUSIVAMENTE con un array JSON, sin texto antes ni después. Cada
elemento es un hallazgo con estas claves exactas:

- `severidad`: uno de `bloqueante` | `importante` | `menor` | `nit`
- `ubicacion`: `ruta:linea` o descripción del punto
- `problema`: qué está mal o qué riesgo hay
- `propuesta`: el cambio concreto sugerido

Si no encuentras nada, responde `[]`.
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_prompts.sh`
Expected: PASS — `OK test_prompts`

- [ ] **Step 6: Commit**

```bash
chmod +x tests/test_prompts.sh
git add prompts/ tests/test_prompts.sh
git commit -m "feat: prompts de rol (codex/gemini/claude) con contrato de hallazgo"
```

---

## Task 7: Subcomando `round0`

**Files:**
- Modify: `consenso.sh`
- Create: `tests/test_round0.sh`

**Interfaces:**
- Consumes: `consenso_get_diff` (nuevo, ver abajo), `consenso_build_prompt`, `consenso_agent_with_retry`, `consenso_run_dir`, `consenso_init_log`, `consenso_log_append`.
- Produces:
  - `consenso_get_diff <workdir> [diff_file]` imprime el diff: si se pasa `diff_file` usa su contenido; si no, `git -C <workdir> diff HEAD`. Devuelve 3 si el diff resultante está vacío.
  - `cmd_round0` (invocado como `consenso.sh round0 [--diff FILE] [--workdir DIR]`): obtiene el diff (si vacío, imprime aviso y sale 3), crea run_dir, para `codex` y `gemini` construye el prompt (rol + diff) y llama a `consenso_agent_with_retry`, escribe `<run_dir>/codex.json` y `<run_dir>/gemini.json`, registra en el log quién participó, y en la ÚLTIMA línea de stdout imprime el run_dir (para que Claude sepa dónde leer). El fallo de un agente NO aborta: se registra y se continúa.

- [ ] **Step 1: Write the failing test**

Create `tests/test_round0.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_GEMINI_CMD="$HERE/stubs/gemini"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
printf 'diff --git a/foo.py b/foo.py\n+return 1/0\n' > "$tmp/d.txt"

# round0 con diff explícito.
out="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$run_dir" "$tmp/.consenso/2026-07-06-1200" "imprime el run_dir en la ultima linea"
assert_contains "$(cat "$run_dir/codex.json")" "division por cero" "escribe codex.json"
assert_contains "$(cat "$run_dir/gemini.json")" "docstring" "escribe gemini.json"
assert_contains "$(cat "$run_dir/log.md")" "codex" "el log menciona a codex"

# Diff vacío -> exit 3.
printf '' > "$tmp/empty.txt"
assert_exit 3 bash "$SCRIPT" round0 --diff "$tmp/empty.txt" --workdir "$tmp"

# Un agente falla (rc!=0 y salida basura): el otro sigue, round0 no aborta.
out2="$(STUB_CODEX_RC=1 STUB_CODEX_OUT='boom' bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir2="$(printf '%s\n' "$out2" | tail -1)"
assert_eq "$(cat "$run_dir2/codex.json")" "[]" "codex fallido queda en []"
assert_contains "$(cat "$run_dir2/gemini.json")" "docstring" "gemini sigue funcionando"

rm -rf "$tmp"
echo "OK test_round0"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_round0.sh`
Expected: FAIL — `consenso: subcomando no implementado todavía` / aserción de run_dir falla.

- [ ] **Step 3: Implement get_diff, cmd_round0, and main dispatch**

Add to `consenso.sh` (antes de `main`):

```bash
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
```

Replace the `main` function body with a dispatcher:

```bash
main() {
  local sub="${1:-}"
  [ $# -gt 0 ] && shift
  case "$sub" in
    round0) cmd_round0 "$@" ;;
    "") echo "uso: consenso.sh <round0|debate> [opciones]" >&2; return 64 ;;
    *) echo "consenso: subcomando desconocido: $sub" >&2; return 64 ;;
  esac
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_round0.sh`
Expected: PASS — `OK test_round0`

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_round0.sh
git add consenso.sh tests/test_round0.sh
git commit -m "feat: subcomando round0 (fan-out, diff vacío, resiliencia a fallo de agente)"
```

---

## Task 8: Subcomando `debate`

**Files:**
- Modify: `consenso.sh`
- Create: `tests/test_debate.sh`

**Interfaces:**
- Consumes: `run_with_timeout`, `run_agent`, `consenso_run_dir`, `consenso_log_append`.
- Produces:
  - `cmd_debate` (invocado como `consenso.sh debate --points FILE --run-dir DIR [--round N]`): lee un fichero `--points` (texto libre preparado por Claude con los puntos en disputa y las críticas cruzadas), lo envía a `codex` y `gemini` pidiendo mantener/rebatir/ceder con argumento, escribe `<run-dir>/debate-<N>-codex.md` y `<run-dir>/debate-<N>-gemini.md` (N default 1), registra en el log, e imprime en la última línea de stdout el run-dir. La respuesta del debate es prosa (no JSON), así que NO se valida como JSON.

- [ ] **Step 1: Write the failing test**

Create `tests/test_debate.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_GEMINI_CMD="$HERE/stubs/gemini"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
run_dir="$tmp/.consenso/2026-07-06-1200"
mkdir -p "$run_dir"
printf '# Punto en disputa\nCodex dice X, Gemini dice no-X.\n' > "$tmp/points.txt"

out="$(STUB_CODEX_OUT='Mantengo X porque...' STUB_GEMINI_OUT='Cedo, X es correcto.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$run_dir")"
rd="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$rd" "$run_dir" "debate imprime el run-dir"
assert_contains "$(cat "$run_dir/debate-1-codex.md")" "Mantengo X" "guarda respuesta de codex"
assert_contains "$(cat "$run_dir/debate-1-gemini.md")" "Cedo" "guarda respuesta de gemini"
assert_contains "$(cat "$run_dir/log.md")" "debate" "el log menciona el debate"

rm -rf "$tmp"
echo "OK test_debate"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_debate.sh`
Expected: FAIL — `subcomando desconocido: debate`

- [ ] **Step 3: Implement cmd_debate and add to dispatcher**

Add to `consenso.sh` (antes de `main`):

```bash
cmd_debate() {
  local points_file=""
  local run_dir=""
  local round="1"
  while [ $# -gt 0 ]; do
    case "$1" in
      --points) points_file="$2"; shift 2 ;;
      --run-dir) run_dir="$2"; shift 2 ;;
      --round) round="$2"; shift 2 ;;
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
    run_agent "$agent" "$prompt" "$run_dir/debate-$round-$agent.md"
    consenso_log_append "$run_dir" "- debate ronda $round: $agent respondió"
  done

  printf '%s\n' "$run_dir"
}
```

Update the `main` dispatcher's `case` to add the `debate` branch:

```bash
    debate) cmd_debate "$@" ;;
```

(colócalo junto a la línea `round0) cmd_round0 "$@" ;;`)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash tests/test_debate.sh`
Expected: PASS — `OK test_debate`

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_debate.sh
git add consenso.sh tests/test_debate.sh
git commit -m "feat: subcomando debate (ronda de rebatir/ceder cruzada)"
```

---

## Task 9: Slash command e instalador

**Files:**
- Create: `commands/consenso.md`
- Create: `install.sh`
- Create: `tests/test_install.sh`

**Interfaces:**
- Consumes: `consenso.sh round0`, `consenso.sh debate`.
- Produces:
  - `commands/consenso.md`: el prompt del slash command para Claude. Contiene la checklist de puntos críticos, el flujo (round0 → síntesis → debate → informe), y el formato del informe de 3 secciones.
  - `install.sh`: hace `consenso.sh` ejecutable y symlinka `commands/consenso.md` en `~/.claude/commands/consenso.md` (crea el directorio si falta). Acepta `CLAUDE_COMMANDS_DIR` para override en tests.

- [ ] **Step 1: Write the failing test**

Create `tests/test_install.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
ROOT="$HERE/.."

# El command declara las piezas clave.
assert_contains "$(cat "$ROOT/commands/consenso.md")" "round0" "el command usa round0"
assert_contains "$(cat "$ROOT/commands/consenso.md")" "Acordado" "el command define el informe"
assert_contains "$(cat "$ROOT/commands/consenso.md")" "punto crítico" "el command lista puntos críticos"

# install.sh symlinka en el dir override.
tmp="$(mktemp -d)"
CLAUDE_COMMANDS_DIR="$tmp/commands" bash "$ROOT/install.sh"
assert_exit 0 test -L "$tmp/commands/consenso.md" "instala symlink del command"
assert_contains "$(cat "$tmp/commands/consenso.md")" "round0" "el symlink apunta al command real"
assert_exit 0 test -x "$ROOT/consenso.sh" "consenso.sh queda ejecutable"

rm -rf "$tmp"
echo "OK test_install"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_install.sh`
Expected: FAIL — `commands/consenso.md` no existe.

- [ ] **Step 3: Write the slash command**

Create `commands/consenso.md`:

```markdown
---
description: Revisión por consenso multiagente (Codex + Gemini + Claude) con debate cruzado
---

Orquestas una revisión por **consenso** del cambio actual usando `consenso.sh`
(en el mismo repo que este command) más tu propio juicio. Codex y Gemini se
invocan por el script; tú (Claude) aportas tu lente de legibilidad y sintetizas.

## Cuándo disparar esto automáticamente (puntos críticos)

Dispara este flujo sin que te lo pidan cuando vayas a hacer algo de esta lista:

- Migración o borrado de datos
- Cambio de una API pública o contrato externo
- Autenticación, secretos o permisos
- Introducir una dependencia nueva y pesada
- Cualquier acción irreversible

También cuando el usuario pida explícitamente revisar un diff.

## Flujo

1. **Ronda 0.** Ejecuta `bash <ruta>/consenso.sh round0 --workdir <repo>` (o
   `--diff <fichero>` si ya tienes el diff aislado). Lee la última línea de la
   salida: es el `run_dir`. Lee `run_dir/codex.json` y `run_dir/gemini.json`.

2. **Tu revisión.** Revisa tú el mismo diff con tu lente (legibilidad,
   mantenibilidad) y produce tus propios hallazgos en el mismo formato.

3. **Síntesis.** Junta los tres conjuntos de hallazgos y clasifícalos:
   - **Acuerdo**: varios señalan lo mismo (misma ubicación + mismo problema) →
     alta confianza.
   - **Singleton**: solo uno lo ve → candidato a debate.
   - **Conflicto**: uno propone X y otro lo contradice → a debate.

4. **Debate (solo si hay singletons/conflictos).** Escribe un fichero de puntos
   en disputa con las críticas cruzadas y ejecuta
   `bash <ruta>/consenso.sh debate --points <fichero> --run-dir <run_dir> --round 1`.
   Lee las respuestas `debate-1-codex.md` / `debate-1-gemini.md`. Si convergen,
   cierra. Si no, una **ronda 2** como máximo.

5. **Fallback (deadlock tras 1–2 rondas).** No fuerces un ganador: presenta al
   usuario las dos posturas enfrentadas con tu recomendación y deja que decida.

## Informe (siempre, 3 secciones)

- **Acordado** → aplicar (indica qué agentes lo respaldaron).
- **Resuelto por debate** → qué se decidió, quién cedió y por qué.
- **Sin resolver** → decisión del usuario, con las dos posturas.

Añade el informe final al `run_dir/log.md` para trazabilidad. Si un agente no
participó (lo dice el log de round0), sigue adelante y hazlo constar en el
informe.
```

- [ ] **Step 4: Write the installer**

Create `install.sh`:

```bash
#!/usr/bin/env bash
# Instala el slash command de consenso y deja consenso.sh ejecutable.
set -eu
HERE="$(cd "$(dirname "$0")" && pwd)"
commands_dir="${CLAUDE_COMMANDS_DIR:-$HOME/.claude/commands}"
mkdir -p "$commands_dir"
ln -sf "$HERE/commands/consenso.md" "$commands_dir/consenso.md"
chmod +x "$HERE/consenso.sh"
echo "Instalado: $commands_dir/consenso.md -> $HERE/commands/consenso.md"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash tests/test_install.sh`
Expected: PASS — `OK test_install`

- [ ] **Step 6: Commit**

```bash
chmod +x install.sh tests/test_install.sh
git add commands/ install.sh tests/test_install.sh
git commit -m "feat: slash command /consenso e instalador"
```

---

## Task 10: Integración end-to-end + README + smoke test manual

**Files:**
- Create: `tests/test_e2e.sh`
- Modify: `README.md`

**Interfaces:**
- Consumes: todo lo anterior, vía los stubs.
- Produces: un test e2e que simula round0 → debate con stubs y verifica que los artefactos y el log quedan coherentes; y una sección en el README con instalación, uso y cómo correr los tests + un smoke test manual con los CLIs reales (no automatizado, porque cuesta tokens y es no determinista).

- [ ] **Step 1: Write the failing e2e test**

Create `tests/test_e2e.sh`:

```bash
#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
export CONSENSO_GEMINI_CMD="$HERE/stubs/gemini"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
printf 'diff --git a/foo.py b/foo.py\n+return 1/0\n' > "$tmp/d.txt"

# round0
rd="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp" | tail -1)"
jq -e . "$rd/codex.json" >/dev/null || fail "codex.json no es JSON válido"
jq -e . "$rd/gemini.json" >/dev/null || fail "gemini.json no es JSON válido"

# debate encadenado sobre el mismo run_dir
printf 'Punto: division por cero. Codex importante, Gemini no lo ve.\n' > "$tmp/points.txt"
STUB_CODEX_OUT='Mantengo: es un fallo real.' STUB_GEMINI_OUT='Cedo.' \
  bash "$SCRIPT" debate --points "$tmp/points.txt" --run-dir "$rd" --round 1 >/dev/null
assert_exit 0 test -f "$rd/debate-1-codex.md" "existe la respuesta de debate"

# el log acumula ambas fases
log="$(cat "$rd/log.md")"
assert_contains "$log" "Ronda 0" "log tiene round0"
assert_contains "$log" "debate ronda 1" "log tiene debate"

rm -rf "$tmp"
echo "OK test_e2e"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash tests/test_e2e.sh`
Expected: PASS si las Tasks 1–9 están hechas (encadena round0 + debate sobre el mismo run_dir con stubs). Si lo ejecutas antes de completar alguna tarea previa, FAIL en la fase correspondiente.

- [ ] **Step 3: Run the full suite**

Run: `bash tests/run.sh`
Expected: todos los `test_*.sh` en PASS y `8/8 OK`, exit 0.

- [ ] **Step 4: Update README with usage and manual smoke test**

Add to `README.md` (al final, nueva sección):

```markdown
## Instalación

```bash
git clone https://github.com/JFCaBa/consenso
cd consenso
bash install.sh   # symlinka /consenso en ~/.claude/commands
```

## Uso

En Claude Code, invoca `/consenso` sobre el cambio actual, o deja que Claude lo
dispare automáticamente en puntos críticos. Por debajo:

```bash
bash consenso.sh round0 --workdir .        # revisión independiente (codex+gemini)
bash consenso.sh debate --points p.txt --run-dir .consenso/<ts>   # ronda de debate
```

Los artefactos y el log quedan en `.consenso/<timestamp>/`.

## Tests

```bash
bash tests/run.sh
```

Los tests usan stubs de los CLIs (`tests/stubs/`) — no llaman a los modelos reales.

## Smoke test manual (CLIs reales)

No automatizado (cuesta tokens y es no determinista). Con `codex` y `gemini`
autenticados, sobre un repo con cambios sin commitear:

```bash
bash consenso.sh round0 --workdir /ruta/a/tu/repo
cat /ruta/a/tu/repo/.consenso/*/codex.json
cat /ruta/a/tu/repo/.consenso/*/gemini.json
```

Verifica que ambos devuelven un array JSON de hallazgos sobre tu diff.
```

- [ ] **Step 5: Commit**

```bash
chmod +x tests/test_e2e.sh
git add tests/test_e2e.sh README.md
git commit -m "test: integración e2e + docs de uso y smoke test manual"
```

- [ ] **Step 6: Install and push**

```bash
bash install.sh
git push
```

Expected: `/consenso` disponible en Claude Code; repo actualizado en GitHub.

---

## Self-Review

**1. Spec coverage:**
- Alcance global reutilizable → Task 9 (install en `~/.claude/commands`). ✅
- Puerta en revisión de código y puntos críticos → checklist en Task 9. ✅
- Roles fijos por fortaleza → Task 6 (prompts). ✅
- Resolución por debate + fallback humano → Task 8 (debate) + command (Task 9). ✅
- Agentes/CLIs headless → Task 3 (`run_agent`). ✅
- Contrato de hallazgo → Task 6 (`_formato`) + validación Task 4. ✅
- Flujo round0→síntesis→debate→informe → Tasks 7, 8, 9. ✅
- Disparo automático (puntos críticos) → command Task 9. ✅
- Salida en 3 secciones + log de trazabilidad → command Task 9 + logging Task 5. ✅
- Manejo de errores (agente caído, salida malformada, diff vacío, timeout) → Tasks 3, 4, 7. ✅
- Criterios de éxito → cubiertos por tests unitarios + e2e (Task 10). ✅

**2. Placeholder scan:** sin TBD/TODO ni código deliberadamente roto. Todos los tests nacen correctos.

**3. Type consistency:** nombres de función consistentes entre tareas — `consenso_build_prompt`, `run_agent`, `consenso_agent_with_retry`, `consenso_validate_json`, `consenso_run_dir`, `consenso_init_log`, `consenso_log_append`, `consenso_get_diff`, `cmd_round0`, `cmd_debate`, `main`. Rutas de artefacto consistentes: `<run_dir>/{codex,gemini}.json`, `<run_dir>/debate-<N>-<agente>.md`, `<run_dir>/log.md`. Contrato de hallazgo idéntico en `_formato.md` y en los tres prompts de rol.
