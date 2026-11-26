# Revisor único como modo de primera clase — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revisión por consenso (2026-11-26):** codex 0 hallazgos; opencode falló (clave). Aceptado de agy: un hallazgo que solo ve una parte no va a debate si la otra lo valida (Claude evalúa los del revisor; los de Claude sin respaldo sí se debaten, porque nadie más los ha evaluado); test del caso "el único revisor falló". Rechazado: "cmd_debate no recibe la postura de Claude" — la recibe: Claude escribe el fichero `--points` con su crítica cruzada, igual que con varios revisores.

**Goal:** Con un solo agente externo, consenso deja de avisar de "consenso debilitado" y la skill tiene una síntesis propia de dos partes (revisor + Claude).

**Architecture:** round0 registra `Modo: revisor único (<id>)` en `log.md` en vez del AVISO. La skill añade una regla para el revisor único: lo que ven los dos va a Acuerdo; lo que solo ve uno, o lo que uno rebate, va a debate con ese revisor (cmd_debate ya funciona con elenco de 1), máximo 2 rondas. README al día.

**Tech Stack:** bash (3.2 y ≥5.2), jq.

**Spec (diseño corto aprobado 2026-11-26):** feedback de David, punto 6: un aviso que sale en cada ejecución con un solo revisor deja de informar. Descartado: mantener el aviso con otro tono.

## Global Constraints

- Texto exacto del log: `Modo: revisor único (<id>)`.
- La palabra "debilitado" desaparece de consenso.sh, SKILL.md y README.md.
- El filtro de Fuera de alcance va antes, igual que con varios revisores.

## Review Focus

1. Elenco de 1 → el log lleva "revisor único" y no "debilitado" (Task 1).
2. Elenco de 2+ → no aparece "revisor único" (Task 1).
3. El único revisor FALLÓ → la skill no puede sintetizar con dos partes; debe decirlo y seguir solo con la lente de Claude, haciéndolo constar (Task 1, SKILL.md).

---

### Task 1: Log, skill y README

**Files:**
- Modify: `consenso.sh` (cmd_round0, bloque `if [ "$n" -eq 1 ]`)
- Modify: `skills/consenso/SKILL.md` (paso 1: quitar "pesa más tu propia lente"; paso 3: subsección **Revisor único**)
- Modify: `README.md` (línea de requisitos)
- Test: `tests/test_round0.sh`, `tests/test_prompts.sh`

- [ ] **Step 1: tests que fallan**
  - test_round0 (elenco codex): log contiene `Modo: revisor único (codex)`; con `case`, falla si contiene `debilitado`.
  - test_round0 (elenco de 4 ya existente, run_dir4): falla si el log contiene `revisor único`.
  - test_prompts: SKILL.md contiene `**Revisor único**` y `solo de Claude` (caso del revisor que falló); ni SKILL.md ni README.md contienen `debilitado`.
- [ ] **Step 2:** `bash tests/run.sh` → FAIL en esos tests.
- [ ] **Step 3:** implementar. SKILL.md, subsección: con un solo revisor externo no hay "varios". Lo ven los dos → Acuerdo. Hallazgo del revisor que Claude valida → Acuerdo; que Claude rebate → debate. Hallazgo de Claude que el revisor no vio → debate, para que el revisor lo evalúe. Debate con ese revisor, máx. 2 rondas; sin convergencia, al informe como desacuerdo para el usuario. Si el único revisor FALLÓ, dilo en el informe: la revisión es solo de Claude.
- [ ] **Step 4:** `bash tests/run.sh` en bash 3.2 y `docker run bash:5.2` → 17/17 OK.

### Task 2: Validación y commit

- [ ] **Step 1:** consenso sobre el diff; informe en `log.md`.
- [ ] **Step 2:** versión 1.5.0 en `.claude-plugin/{plugin,marketplace}.json`, commit.
