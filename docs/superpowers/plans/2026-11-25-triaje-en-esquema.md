# Triaje en el esquema de hallazgos — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revisión por consenso (2026-11-25):** aceptado de agy: `false` explícito obligatorio en los prompts; Goal reformulado (campos y recuentos estructurados, no filtro en el script); `"true"` string también cuenta; un solo jq por agente. Rechazado: duplicar la regla de alcance en cada prompt de rol (el bloque ALCANCE ya se inyecta a todos; claude.md lo lleva porque Claude lo lee sin pasar por el script).

**Goal:** Que "fuera de alcance" y "entrada hipotética" sean campos booleanos del hallazgo, no prefijos de texto: datos estructurados que la síntesis lee sin interpretar prosa, y un recuento por agente en `log.md`.

**Architecture:** Dos campos nuevos obligatorios en `prompts/hallazgos.schema.json` (`fuera_de_alcance`, `hipotetica`). Los prompts piden el campo en vez del prefijo. round0 resume en `log.md` cuántos hallazgos hay de cada tipo. La skill filtra por campo.

**Tech Stack:** bash (3.2 y ≥5.2), jq.

**Spec (diseño corto aprobado 2026-11-25, opción 1):** dos booleanos obligatorios; se descartan `escenario`, `refutacion` y `frecuencia` (más salida y más riesgo de incumplir el esquema sin uso mecánico en la síntesis) y dejar "hipotética" como prefijo.

## Global Constraints

- Esquema estricto (codex `--output-schema`): todo campo en `properties` va en `required`; `additionalProperties: false`.
- Agentes `via=prompt` (qwen, opencode) no validan campos: un campo ausente cuenta como `false`; `true` o `"true"` cuentan como verdadero.
- Los prompts dicen que ambos campos van en TODOS los hallazgos, con `false` cuando no apliquen.
- La regla de severidad se mantiene: fuera de alcance o hipotético → como mucho `menor`.
- Nombres exactos: `fuera_de_alcance`, `hipotetica` (sin tilde, como los demás campos).

## Review Focus

1. Hallazgo de agente `via=prompt` sin los campos nuevos → no rompe round0; cuenta como `false` (Task 2).
2. Codex/agy reales con el esquema nuevo → JSON válido con los dos campos (Task 3, run real).
3. `[]` → resumen "0 hallazgos" sin error de jq (Task 2).
4. Campo como string `"true"` en un agente `via=prompt` → cuenta como verdadero (Task 2).
5. Un agente FALLÓ → sin resumen de recuento (no hay `<id>.json`) (Task 2).

---

### Task 1: Esquema y prompts

**Files:**
- Modify: `prompts/hallazgos.schema.json` (añadir `"fuera_de_alcance": {"type":"boolean"}`, `"hipotetica": {"type":"boolean"}` a `properties` y a `required`)
- Modify: `prompts/_formato.md`, `prompts/{codex,agy,qwen,opencode,claude}.md` (en la sección de formato, los dos campos con una línea cada uno; en "Calibra por realismo", "márcalo como mucho `menor` y pon `hipotetica: true`" en lugar de "dilo en `problema` ("entrada hipotética: …")"; en claude.md, "Alcance" pide `fuera_de_alcance: true`)
- Modify: `consenso.sh` `consenso_build_prompt` (bloque ALCANCE: `fuera_de_alcance: true` en lugar del prefijo)
- Test: `tests/test_prompts.sh`, `tests/test_build_prompt.sh`, `tests/test_registry.sh`

- [ ] **Step 1: tests que fallan**
  - test_prompts: para codex, agy, qwen, opencode, claude y `_formato.md`: contienen `fuera_de_alcance` y `hipotetica`; ya no contienen `"entrada hipotética: …"` (assert de ausencia con `case`); `_formato.md` contiene `false`.
  - test_build_prompt: el bloque ALCANCE contiene `fuera_de_alcance: true` (sustituye al assert de `fuera de alcance:`).
  - test_registry (o nuevo assert en test_prompts): `jq -e '.properties.hallazgos.items | (.required | index("fuera_de_alcance") and index("hipotetica")) and .properties.fuera_de_alcance.type=="boolean" and .properties.hipotetica.type=="boolean"' prompts/hallazgos.schema.json`.
- [ ] **Step 2:** `bash tests/run.sh` → FAIL en esos tests.
- [ ] **Step 3:** implementar los cambios de ficheros de arriba.
- [ ] **Step 4:** `bash tests/run.sh` → 17/17 OK.

### Task 2: Recuento en log.md y skill

**Files:**
- Modify: `consenso.sh` `cmd_round0` (línea "participó": `- <id>: participó (<n> hallazgos; <f> fuera de alcance, <h> hipotéticos)` con una sola invocación de jq que devuelve los tres números; verdadero = `true` o `"true"`)
- Modify: `skills/consenso/SKILL.md` (paso 3: filtra por `fuera_de_alcance: true`, y juzga tú aunque no lo marquen; paso 6: señal "los hallazgos llevan `hipotetica: true`")
- Modify: `tests/stubs/codex` (default de hallazgos incluye los dos campos a `false`)
- Test: `tests/test_round0.sh`, `tests/test_prompts.sh`

- [ ] **Step 1: tests que fallan**
  - round0 con `STUB_CODEX_OUT='[{…,"fuera_de_alcance":true,"hipotetica":false},{…,"fuera_de_alcance":false,"hipotetica":true},{…,"fuera_de_alcance":false,"hipotetica":false}]'` y `CONSENSO_AGENTS=codex` → log contiene `codex: participó (3 hallazgos; 1 fuera de alcance, 1 hipotéticos)`.
  - `STUB_CODEX_OUT='[]'` → log contiene `codex: participó (0 hallazgos; 0 fuera de alcance, 0 hipotéticos)`.
  - opencode (`via=prompt`) con hallazgo sin los campos y otro con `"fuera_de_alcance":"true"` (string) → `2 hallazgos; 1 fuera de alcance, 0 hipotéticos`.
  - test_prompts: SKILL.md contiene `fuera_de_alcance: true` y `hipotetica: true`.
- [ ] **Step 2:** `bash tests/run.sh` → FAIL.
- [ ] **Step 3:** implementar.
- [ ] **Step 4:** `bash tests/run.sh` en bash 3.2 y en `docker run bash:5.2` → 17/17 OK.

### Task 3: Validación real y commit

- [ ] **Step 1:** `consenso.sh round0 --workdir .` real: codex y agy participan y sus `<id>.json` llevan los dos campos en cada hallazgo (`jq -e 'all(.[]; has("fuera_de_alcance") and has("hipotetica"))'`).
- [ ] **Step 2:** síntesis del consenso, versión 1.4.0 en `.claude-plugin/{plugin,marketplace}.json`, commit.
