# Debate con memoria y veredicto JSON — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revisión por consenso (2026-11-26):** codex y agy; opencode falló (clave). Aceptado: (agy) repetir una ronda relanza solo a los agentes sin `debate-<N>-<id>.json`; los puntos de cada ronda se guardan en `run_dir/puntos-<N>.json`; la regla de convergencia se corrige (dos `mantengo` de posturas opuestas no convergen); el debate rechaza con rc 65 un agente via=schema cuyo `extract` no lleva `{CLAVE}`; `consenso_extraer_hallazgos` pasa a `consenso_extraer_json`. (codex) los veredictos se validan en local tras normalizar (campos, tipos, enum, ids sin repetir); si no cumplen, reintento y luego fallo. Rechazado (agy): exigir que los puntos de la ronda 2 sean idénticos a los de la 1 — la ronda 2 legítimamente debate solo lo que no convergió.

**Goal:** El debate entrega a cada agente la entrada original, sus hallazgos de ronda 0 y (en ronda 2) los veredictos de la ronda 1; cada agente responde un veredicto JSON por punto; el script impone 2 rondas como máximo.

**Architecture:** round0 persiste la entrada en `run_dir/entrada`. Claude escribe los puntos como JSON con id. `run_agent_json` se generaliza (esquema, clave y formato como parámetros) y el debate lo usa con `prompts/veredictos.schema.json`, con la misma extracción y reintento que round0. El registro usa `{CLAVE}` en `extract`. El log resume los veredictos por agente y avisa de puntos sin veredicto.

**Tech Stack:** bash (3.2 y ≥5.2), jq.

**Spec (diseño corto aprobado 2026-11-26):** feedback de David, punto 4. Descartado: prosa con bloque JSON final (se rompería en los agentes sin esquema nativo).

## Global Constraints

- Puntos (`--points`): array JSON no vacío de `{id, punto, posturas}`, los tres strings, `id` único. Si no, rc 64 sin lanzar agentes.
- Veredicto: `{"veredictos":[{punto, veredicto, argumento}]}`; `punto` = id del punto; `veredicto` ∈ `mantengo` | `rebato` | `cedo`. Esquema estricto (todo en `required`, `additionalProperties: false`).
- `--round` ∈ {1, 2}; otro valor → rc 64. Ronda 2 exige al menos un `debate-1-*.json`. Repetir una ronda relanza solo a los agentes del elenco sin `debate-<N>-<id>.json` (log: `ya respondió, se omite`); si todos lo tienen → rc 64. Ronda 1 con algún `debate-2-*.json` ya existente → rc 64.
- Los puntos de cada ronda se copian a `run_dir/puntos-<N>.json` (fijados al primer intento: relanzar con otros puntos → rc 64; consenso sobre el diff, codex).
- Contrato local del veredicto (todos los agentes, tras normalizar): cada elemento es objeto con `punto` string, `veredicto` del enum y `argumento` string; `punto` sin repetir. Si no cumple → reintento; si persiste → fallo como round0 (sin fichero, causa en `.err`).
- Debate con un agente via=schema cuyo `extract` no contiene `{CLAVE}` → rc 65 antes de lanzar nada.
- Salida: `debate-<N>-<id>.json` (array de veredictos). Fallo → sin fichero y `.err`, como round0.
- Registro: `extract` admite el segmento `{CLAVE}` (`.{CLAVE}`, `.structured_output.{CLAVE}`); se sustituye por `hallazgos` o `veredictos`. Un `extract` sin `{CLAVE}` sigue valiendo para round0.
- Bash 3.2: nada de `declare -A`, `mapfile`, `${x,,}`.

## Review Focus

1. Run_dir de una versión anterior sin `entrada` → el debate sigue, sin ese bloque, y lo anota en el log (Task 2).
2. Veredicto que no cubre todos los puntos, o con un id desconocido → log: `sin veredicto: P2` / `id desconocido: P9`; el fichero se guarda igual (Task 2).
3. Agente via=prompt (qwen, opencode) responde el array entre fences → se normaliza como en round0 (Task 2).
4. Ronda 1 con un agente fallido de tres → relanzar la ronda 1 corre solo ese agente (Task 2).
5. Veredicto via=prompt con `veredicto: "acepto"` o con P1 repetido → reintento y fallo (Task 1).

---

### Task 1: Generalizar la salida JSON

**Files:**
- Create: `prompts/veredictos.schema.json`, `prompts/_formato_veredictos.md`
- Modify: `consenso.sh` (`run_agent_json`, `consenso_agent_with_retry`, `consenso_extraer_hallazgos` → `consenso_extraer_json <id> <raw> <out> [clave]`, `consenso_registry_validar`; nuevo `consenso_validar_veredictos <fichero>`)
- Modify: `agents/registry.json` (`extract` de codex `.{CLAVE}`, agy `.structured_output.{CLAVE}`)
- Modify: `tests/stubs/codex`, `tests/stubs/agy` (en modo JSON, la clave envolvente es `.required[0]` del esquema recibido; default de veredictos si la clave es `veredictos`: `[{"punto":"P1","veredicto":"mantengo","argumento":"stub"}]`)
- Test: `tests/test_registry.sh`, `tests/test_run_agent.sh`

**Interfaces:**
- Produces: `run_agent_json <id> <prompt> <out> [schema] [clave] [formato]` y `consenso_agent_with_retry <id> <prompt> <out> [schema] [clave] [formato]`; defaults `prompts/hallazgos.schema.json`, `hallazgos`, `prompts/_formato.md`.

- [ ] **Step 1: tests que fallan**
  - test_registry: el registro real valida; `extract` `.{CLAVE}` y `.a.{CLAVE}` validan; `.{OTRA}` → 65; codex y agy llevan `{CLAVE}`.
  - test_run_agent: `run_agent_json codex … veredictos.schema.json veredictos _formato_veredictos.md` con `STUB_CODEX_OUT='[{"punto":"P1","veredicto":"cedo","argumento":"x"}]'` → out contiene `"cedo"`; lo mismo con agy; con qwen (via=prompt, salida entre fences) → array válido y el prompt (`STUB_QWEN_ARGS_FILE` si existe, o el stub ampliado) lleva `_formato_veredictos.md` y no `_formato.md`.
  - qwen con `[{"punto":"P1","veredicto":"acepto","argumento":"x"}]` → rc 1, sin out; con P1 dos veces → rc 1, sin out.
  - Los tests de round0 existentes siguen verdes sin tocarlos (defaults).
- [ ] **Step 2:** `bash tests/run.sh` → FAIL.
- [ ] **Step 3:** implementar. En `consenso_extraer_hallazgos`, `extract="${extract//\{CLAVE\}/$clave}"`.
- [ ] **Step 4:** `bash tests/run.sh` → verde.

### Task 2: Debate con memoria y límite de rondas

**Files:**
- Modify: `consenso.sh` (`cmd_round0`: copiar el contenido a `run_dir/entrada`; `cmd_debate`: validar puntos y ronda, construir prompt, llamar `consenso_agent_with_retry` con el esquema de veredictos, resumir en log; `consenso_debate_instruccion`: pide veredicto por punto, no prosa)
- Create: `consenso_debate_prompt <run_dir> <id> <ronda> <points_file>` (imprime: instrucción; `ENTRADA REVISADA` + `entrada`; `TUS HALLAZGOS EN RONDA 0` + `<id>.json` si existe; en ronda 2 `VEREDICTOS DE LA RONDA 1` + cada `debate-1-<x>.json` etiquetado con su agente; `PUNTOS EN DISPUTA` + puntos)
- Create: `consenso_resumen_veredictos <veredictos.json> <points_file>` → `3 veredictos: 1 mantengo, 1 rebato, 1 cedo` + `; sin veredicto: P2` / `; id desconocido: P9` si aplica
- Test: `tests/test_debate.sh` (reescrito: un run_dir nuevo por caso), `tests/test_round0.sh`

- [ ] **Step 1: tests que fallan**
  - round0 deja `entrada` con el diff (`return 1/0` del fixture).
  - debate ronda 1: el stdin de codex contiene la entrada, `TUS HALLAZGOS EN RONDA 0` con su `codex.json`, y el id `P1` de los puntos; NO contiene `VEREDICTOS DE LA RONDA 1`.
  - debate ronda 2 tras ronda 1: el prompt contiene `VEREDICTOS DE LA RONDA 1` y el argumento de agy de la ronda 1.
  - `debate-1-codex.json` válido; log `debate ronda 1: codex respondió (1 veredictos: 0 mantengo, 0 rebato, 1 cedo)`.
  - puntos P1,P2 y veredicto solo de P1 → log contiene `sin veredicto: P2`; veredicto de P9 → `id desconocido: P9`.
  - rc 64: `--round 3`, `--round 0`, `--round x`; ronda 2 sin ronda 1; ronda 1 con todos los `debate-1-<id>.json` presentes; ronda 1 con `debate-2-*.json` presente; puntos no-JSON; puntos `[]`; ids duplicados; falta `posturas`.
  - ronda 1 con codex fallando y agy OK → solo `debate-1-agy.json`; relanzar ronda 1 → codex corre, agy no (log `agy: ya respondió, se omite`).
  - `puntos-1.json` es copia de los puntos.
  - registro con codex `extract: ".hallazgos"` → debate rc 65.
  - run_dir sin `entrada` → debate rc 0 y log `sin entrada original`.
  - Se mantienen: cwd del repo, stdin desde fichero, binario relativo, elenco de 3, run-dir vacío rc 64, guards de flags, registro inválido rc 65, instrucción según modo.
- [ ] **Step 2:** `bash tests/run.sh` → FAIL.
- [ ] **Step 3:** implementar.
- [ ] **Step 4:** `bash tests/run.sh` en bash 3.2 y `docker run bash:5.2` → todo OK.

### Task 3: Skill, README y validación

**Files:**
- Modify: `skills/consenso/SKILL.md` (paso 4: puntos JSON `{id, punto, posturas}` con `posturas` = las críticas cruzadas incluida la tuya; leer `debate-N-<id>.json`; un punto converge cuando todos los que respondieron quedan en una misma postura (los demás `cedo`); si dos o más mantienen o rebaten desde posturas distintas, no converge — la postura de cada uno se juzga por su argumento, no solo por la palabra; el script no admite ronda 3; puntos sin veredicto cuentan como no resueltos)
- Modify: `README.md` (debate y `{CLAVE}` en registros propios)
- Test: `tests/test_prompts.sh` (SKILL.md contiene `debate-N-<id>.json` y `"posturas"`)

- [ ] **Step 1:** test que falla → implementar → verde.
- [ ] **Step 2:** debate real sobre un run_dir real (codex + agy): ambos escriben `debate-1-<id>.json` válido.
- [ ] **Step 3:** consenso sobre el diff, informe en `log.md`, versión 1.6.0, commit.
