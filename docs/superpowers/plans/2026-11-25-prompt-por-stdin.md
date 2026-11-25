# Prompt por stdin — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revisión por consenso (2026-11-25):** qwen y opencode se quedan en argv hasta validarlos con credenciales (codex+agy); test de SIGPIPE con 1,2 MB contra stub que no lee stdin (codex+agy); marcador al final del diff (codex); STUB_CODEX_ARGS_FILE se conserva (agy); {PROMPT} sintético también en json.argv (agy). Rechazado: `head -c` no portable (sí lo es en macOS, verificado).

**Resultado de la ejecución:** agy se queda en argv. Con `-p` ignora stdin: su log muestra `promptLength` = solo el `-p`, y cuando se le dice que mire stdin sale a buscar el contenido con herramientas (ps, ficheros, el repo), lo que hizo pasar las pruebas en vivo como falsos positivos. Lo detectó agy en el debate de consenso. Solo codex pasa a stdin. El stdin se entrega desde un fichero (no pipe) para evitar SIGPIPE.

**Goal:** Que codex y agy no reciban el prompt por argv, para que un plan o diff grande no falle con E2BIG (`Argument list too long`).

**Architecture:** `prompt_via: "stdin"` ya está implementado en `run_agent` y `run_agent_json` (consenso.sh) pero ningún agente del registro lo usa. Se activa en los cuatro y se quita `{PROMPT}` de sus argv. El placeholder `{PROMPT}` sigue soportado para registros de terceros.

**Tech Stack:** bash (3.2 y ≥5.2), jq.

**Spec (diseño corto, aprobado en conversación 2026-11-25):**
- codex: sin prompt posicional lee stdin (verificado en vivo).
- agy: `-p "<instrucción corta>"` + prompt por stdin, que agy añade (verificado en vivo). `-p ""` falla ("empty prompt").
- qwen: sin `-p`, lee stdin (aceptado; falló después por 401 de API).
- opencode: sin mensaje posicional, lee stdin (aceptado; falló después por API key caducada).
- Descartado: fichero + `--file` (solo opencode; a agy se le prohíbe leer ficheros) y un mero aviso por tamaño (no arregla).

## Global Constraints

- Compatible con bash 3.2 (macOS) y bash 5.2 (Linux); la suite debe pasar en ambos (`docker run bash:5.2`).
- `shopt -u patsub_replacement` se queda: `{SCHEMA}`, `{RAW}` y `{MODEL}` siguen sustituyéndose.
- Instrucción exacta de agy en `-p`: `Revisa según las instrucciones que llegan por stdin.`

## Review Focus

1. Prompt > ARG_MAX (1 MB en macOS, 128 KB por argumento en Linux): debe llegar entero al CLI → test de 1,2 MB en Task 2.
2. Un CLI que no lee todo stdin: printf recibe SIGPIPE; no debe colgar ni abortar round0 → cubierto por los stubs que no leen stdin (agy/qwen/opencode) en la suite existente.
3. Registros de terceros con `{PROMPT}` en argv siguen funcionando → test_argv con registro sintético en Task 1.
4. Debate (prosa) también por stdin → assert en Task 2 sobre `run_agent`.
5. Prompt con `&` y literales `{SCHEMA}` intactos por stdin → test de `&` adaptado en Task 2.

---

### Task 1: Registro por stdin y tests de argv

**Files:**
- Modify: `agents/registry.json` (codex y agy: `"prompt_via": "stdin"`; quitar `{PROMPT}` de `prosa_argv` y `json.argv`; en agy sustituir `"-p","{PROMPT}"` por `"-p","Revisa según las instrucciones que llegan por stdin."`. qwen y opencode sin cambios)
- Modify: `tests/test_argv.sh` (los casos de sustitución de `{PROMPT}` pasan a un registro sintético vía `CONSENSO_REGISTRY`)
- Modify: `tests/test_registry.sh`

- [ ] **Step 1: tests que fallan** — en `test_registry.sh`:
  `assert_eq "$(jq '[.agentes[] | select((.id=="codex" or .id=="agy") and .prompt_via != "stdin")] | length' "$CONSENSO_REGISTRY")" "0" "codex y agy reciben el prompt por stdin"`
  `assert_eq "$(jq '[.agentes[] | select(.prompt_via == "stdin") | (.prosa_argv + .json.argv)[] | select(contains("{PROMPT}"))] | length' "$CONSENSO_REGISTRY")" "0" "con stdin, ningún argv lleva {PROMPT}"`
- [ ] **Step 2:** `bash tests/run.sh` → FAIL en test_registry.
- [ ] **Step 3:** editar el registro y mover los asserts de `{PROMPT}` de `test_argv.sh` a un registro sintético (un agente `x` con `{PROMPT}` en `prosa_argv` y en `json.argv`), conservando: prompt intacto con newline y comillas, y orden de sustitución (literales `{SCHEMA}`/`{MODEL}` conservados).
- [ ] **Step 4:** `bash tests/run.sh` → 17/17 OK.

### Task 2: Stubs por stdin y prompt grande

**Files:**
- Modify: `tests/stubs/codex` (añadir `STUB_CODEX_STDIN_FILE`: si está, `cat > "$STUB_CODEX_STDIN_FILE"`; `STUB_CODEX_ARGS_FILE` se conserva)
- Modify: `tests/test_round0.sh`, `tests/test_debate.sh`

- [ ] **Step 1: tests**
  - round0 con un diff de 1,2 MB (`head -c 1200000 /dev/zero | tr '\0' 'x'` con prefijo `+`) y `CONSENSO_AGENTS=codex`: `codex.json` existe y contiene "division por cero"; `STUB_CODEX_STDIN_FILE` contiene el marcador `FIN-DEL-DIFF-GRANDE` puesto al final del diff.
  - SIGPIPE: el mismo diff de 1,2 MB con `CONSENSO_AGENTS=agy` (su stub no lee stdin): `agy.json` existe con su hallazgo y el log dice "agy: participó".
  - test de `&`: el contenido de `STUB_CODEX_STDIN_FILE` contiene `+a && b & c`.
  - debate: `STUB_CODEX_STDIN_FILE` contiene el texto del fichero de puntos.
- [ ] **Step 2:** con el registro antiguo (git stash del registro) el test de 1,2 MB falla con E2BIG; con el nuevo, pasa.
- [ ] **Step 3:** `bash tests/run.sh` en bash 3.2 y en `docker run bash:5.2` → 17/17 OK en ambos.

### Task 3: Validación real y commit

- [ ] **Step 1:** `consenso.sh round0 --workdir .` real sobre el diff: codex y agy participan (qwen/opencode quedan en argv, pendientes de validar con credenciales) (no `FALLÓ`). Si agy agota el timeout, ver `.err`; distinguir timeout de rechazo del prompt.
- [ ] **Step 2:** README: mencionar que el prompt va por stdin (sección de registro/agentes).
- [ ] **Step 3:** subir versión a 1.3.0 en `.claude-plugin/{plugin,marketplace}.json`; commit tras consenso.
