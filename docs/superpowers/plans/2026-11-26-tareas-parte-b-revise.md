# revise: nueva versión de una tarea (parte B) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revisión por consenso (2026-11-26):** codex y agy; opencode falló. Aceptado: (agy) ejecutor común de bajo nivel `consenso_ejecutar_elenco <run_dir> <workdir> <schema> <formato> <id>…` que lee `prompt-<id>.txt` e imprime `<id> <rc>` por línea; el log lo hace cada comando. (agy) contexto en `v<k+1>/contexto`. (agy) `completo` solo si participó al menos un agente (también en round0): si no, la versión queda incompleta y se puede relanzar. (agy + codex) los ids del seguimiento deben ser de las pendientes enviadas; si no, fuera de contrato. (codex) el test de "no cambió" compara con la última versión; volver al contenido de v1 desde v2 se permite. Rechazado (agy): "codex/agy no extraerían la clave" — su `extract` es `.{CLAVE}` y el raw es `{hallazgos, seguimiento}`, así que cada extracción toma su clave.

**Consenso sobre el diff (revise real, tarea `tareas`, gate 2, v2):** codex 0 hallazgos nuevos y seguimiento vacío (no había pendientes: O1–O3 ya resueltas en 1.7.0); agy FALLÓ por timeout de 6 min (no por el esquema); opencode, clave caducada. Revisión propia: un `exit` dentro de un grupo `{ }` habría matado el script (pasa a subshell) y `diff --label` → `-L` (portable a busybox).

**Goal:** `revise --task T --gate N` revisa la versión nueva de una tarea: cada agente recibe el artefacto completo, lo que cambió respecto a la versión anterior y las objeciones pendientes con sus ids, y responde en una sola llamada un seguimiento por objeción y los hallazgos nuevos.

**Architecture:** `revise` reserva `g<N>/v<k+1>` (como round0 con v1), guarda `entrada` y `cambios` (`diff -u` entre entradas) y lanza al elenco en paralelo con `prompts/revise.schema.json` (`{hallazgos, seguimiento}`). Del mismo raw se extraen dos claves: `<id>.json` (hallazgos, como round0) y `<id>.seguimiento.json`. La ejecución paralela de round0 se extrae a una función común para no duplicarla.

**Tech Stack:** bash (3.2 y ≥5.2), jq.

**Spec:** `docs/superpowers/specs/2026-11-26-tareas-y-gates-design.md` (parte B).

## Global Constraints

- Precondiciones (rc 64, sin reservar nada): `v<k>` existe y tiene `completo`; `g<N>/objeciones.json` existe, es válido y su `version` = k ("sintetiza v<k> y escribe objeciones.json antes de revise"); la entrada nueva difiere de `v<k>/entrada` ("la entrada no cambió").
- Objeciones pendientes = estado `abierta` o `acordada` (lo acordado también se verifica: ¿se aplicó?).
- Seguimiento: `[{objecion, estado, argumento}]`; `objecion` = id de una pendiente enviada; `estado` ∈ `resuelta` | `sigue_abierta`; ids sin repetir. Validación local: `consenso_validar_seguimiento <fichero> <pendientes.json>`.
- `v<k+1>/contexto`: bloques `=== CAMBIOS RESPECTO A v<k> ===` (cambios) y `=== OBJECIONES PENDIENTES ===` (array JSON `{id, hallazgo, estado}` o el texto `sin objeciones pendientes`) más la instrucción de seguimiento; se añade al prompt de cada agente tras el bloque de la entrada. `v<k+1>/pendientes.json` guarda las pendientes enviadas.
- `completo` (round0 y revise) solo si al menos un agente participó.
- Esquema estricto: `revise.schema.json` con `hallazgos` (mismos items que `hallazgos.schema.json`) y `seguimiento`, ambos en `required`.
- Agentes via=prompt devuelven el objeto `{hallazgos, seguimiento}`; tras normalizar, si el resultado es un objeto con la clave pedida, se toma esa clave.
- Hallazgos válidos y seguimiento inválido → el agente participa (cuenta su `<id>.json`); log `seguimiento fuera de contrato`, sin `<id>.seguimiento.json`.
- Log de la versión: `Tarea: <T> · gate <N> · v<k+1> (revisión de v<k>)`; por agente, el resumen de triaje de round0 + `; seguimiento: <r> resueltas, <a> siguen abiertas` + `; sin seguimiento: O3` si falta alguna pendiente.

## Review Focus

1. Objeciones sin pendientes (todas resueltas/rechazadas) → revise funciona; el prompt dice que no hay pendientes y el seguimiento esperado es `[]` (Task 2).
2. `--plan` en un gate cuyo v1 fue `--diff` → se permite; `modo` es el de la versión nueva (Task 2).
3. Agente que FALLA → sin `<id>.json` ni `<id>.seguimiento.json`, log `FALLÓ` (Task 2).
4. Dos revise simultáneos → uno reserva v<k+1>, el otro rc 64 (heredado de la reserva; Task 2).
5. `revise` sin `v1` en el gate → rc 64 que remite a `round0 --task` (Task 2).

---

### Task 1: Esquema, formato y extracción de dos claves

**Files:**
- Create: `prompts/revise.schema.json`, `prompts/_formato_revise.md`
- Modify: `consenso.sh` (`consenso_extraer_json`: objeto con la clave en via=prompt; `consenso_validar_seguimiento <fichero>`; validación por clave `seguimiento`)
- Modify: `tests/stubs/codex`, `tests/stubs/agy` (clave envolvente: si el esquema exige varias claves, el stub escribe `{"hallazgos": <OUT o default>, "seguimiento": <STUB_*_SEGUIMIENTO o []>}`)
- Test: `tests/test_run_agent.sh`

**Interfaces:**
- Produces: `consenso_extraer_json <id> <raw> <out> seguimiento` sobre el mismo raw que dejó `run_agent_json`.

- [ ] **Step 1: tests que fallan**
  - codex con `revise.schema.json`, clave `hallazgos`, y `STUB_CODEX_SEGUIMIENTO='[{"objecion":"O1","estado":"resuelta","argumento":"x"}]'` → `<out>` hallazgos válido; `consenso_extraer_json codex <out>.raw <out2> seguimiento` → `.[0].estado == "resuelta"`.
  - qwen con `{"hallazgos":[],"seguimiento":[…]}` entre fences → ambas extracciones válidas.
  - seguimiento con `estado: "quizas"` o O1 repetido → `consenso_extraer_json … seguimiento` rc 1.
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** verde.

### Task 2: cmd_revise

**Files:**
- Modify: `consenso.sh` (extraer de `cmd_round0` la ejecución paralela a `consenso_ejecutar_elenco <run_dir> <workdir> <schema> <formato> <id>…`; `cmd_round0` y `cmd_revise` construyen los prompts y escriben el log; `main`)
- Test: `tests/test_revise.sh` (nuevo; run.sh pasa a 19)

**Interfaces:**
- Consumes: `consenso_reservar_version`, `consenso_ultima_version`, `consenso_validar_objeciones`, `consenso_tarea_dir` (parte A).
- Produces: `revise --task T --gate N [--diff f | --plan f] [--workdir W]` → última línea: `g<N>/v<k+1>` absoluto.

- [ ] **Step 1: tests que fallan** (tarea creada con `round0 --task demo --gate 1` y stubs, `CONSENSO_AGENTS=codex`)
  - sin objeciones.json → rc 64, sin `v2`.
  - objeciones `version: 1` con O1 abierta, O2 acordada, O3 resuelta; diff nuevo → imprime `…/g1/v2`; `v2/entrada`, `v2/cambios` (contiene `-` y `+` de las líneas cambiadas), `v2/completo`.
  - stdin de codex (`STUB_CODEX_STDIN_FILE`) contiene el diff nuevo completo, `CAMBIOS RESPECTO A v1`, `OBJECIONES PENDIENTES`, `O1` y `O2`, y NO `O3`.
  - con `STUB_CODEX_SEGUIMIENTO` de O1 resuelta → `v2/codex.seguimiento.json`; log `seguimiento: 1 resueltas, 0 siguen abiertas; sin seguimiento: O2`.
  - misma entrada que v2 → rc 64 "no cambió", sin `v3`; con objeciones de v2, volver al contenido de v1 → crea `v3`.
  - seguimiento con id `O9` (no pendiente) → sin `codex.seguimiento.json`, log `seguimiento fuera de contrato`.
  - todos los agentes fallan → sin `completo`; relanzar revise → rc 64 "incompleto".
  - objeciones de v1 cuando ya hay `v2` → rc 64.
  - `v2` sin `completo` → revise rc 64.
  - todas resueltas → stdin contiene `sin objeciones pendientes`.
  - elenco codex+agy, codex falla (`STUB_CODEX_RC=1`) → log `FALLÓ` para codex, sin `codex.json` ni `codex.seguimiento.json`; `completo` existe (agy participó).
  - dos revise simultáneos → `0 64`.
  - round0 sigue verde (refactor sin cambio de comportamiento).
- [ ] **Step 2:** FAIL. **Step 3:** implementar. **Step 4:** verde en bash 3.2 y 5.2.

### Task 3: skill, README y validación

**Files:**
- Modify: `skills/consenso/SKILL.md` (sección **Tareas**: para una versión nueva, `revise` en vez de `round0`; síntesis: con el seguimiento de cada agente y tu juicio, cada pendiente pasa a `resuelta` o sigue `abierta` (si discrepan, debate sobre `v<k+1>`); hallazgos nuevos reciben ids nuevos; `version` = k+1; luego `report`)
- Modify: `README.md` (revise)
- Test: `tests/test_prompts.sh` (SKILL.md contiene `consenso.sh" revise`)

- [ ] **Step 1:** test → implementar → verde.
- [ ] **Step 2:** consenso sobre el diff con `--task tareas --gate 2` vía `revise` (v2 de la tarea real), objeciones y report.
- [ ] **Step 3:** versión 1.8.0, commit.
