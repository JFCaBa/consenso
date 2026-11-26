# Tareas, objeciones y report (parte A) — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Revisión por consenso (2026-11-26):** codex y agy; opencode falló (clave). Aceptado: (codex) reserva atómica de `v1` con `mkdir` sin `-p` + test concurrente; `objeciones.json` ligado a la versión (`{version, objeciones}`) y `report` rechaza la discrepancia. (agy) marcador `completo` y mensajes distintos para v1 completo/incompleto (sin remitir a un `revise` que aún no existe); `report` idempotente (`informe.md` sobrescrito + una línea en `log.md`); regex de id unificada. Rechazado (agy, hipotético y preexistente): derivar el repo sin `${run_dir%/.consenso/*}`.

**Consenso sobre el diff (tarea `tareas`, gate 2):** codex 0 hallazgos; agy 3, los tres aceptados (report rechaza una versión sin `completo`; comparaciones portables en vez de `IN()` de jq ≥ 1.6; fallo de `mkdir` del SO → rc 2). Informe generado con el propio `report`.

**Goal:** `round0 --task T --gate N` agrupa los runs de una tarea por gate y versión, las objeciones tienen ids estables en `objeciones.json`, y `report` genera siempre el mismo informe de 4 secciones.

**Architecture:** el run_dir de una tarea es `.consenso/<T>/g<N>/v<k>/` (un run_dir normal); `objeciones.json` vive en `g<N>/`. `report` lo valida y anexa el informe al `log.md` de la última versión. Sin `--task`, nada cambia.

**Tech Stack:** bash (3.2 y ≥5.2), jq.

**Spec:** `docs/superpowers/specs/2026-11-26-tareas-y-gates-design.md`

## Global Constraints

- `--task`: `^[a-z0-9][a-z0-9_-]*$`; `--gate`: entero ≥ 1 sin ceros a la izquierda. `--task` sin `--gate` o al revés → rc 64.
- `objeciones.json`: `{version, objeciones}`; `version` entero ≥ 1; `objeciones` array de `{id, hallazgo, estado, nota}`; `id` `^O[1-9][0-9]*$` único; `estado` ∈ `abierta` | `acordada` | `resuelta` | `rechazada` | `fuera_de_alcance`; `hallazgo` y `nota` strings. Inválido → rc 65.
- Secciones del informe, en este orden y con estos títulos: `### Acordado`, `### Resuelto por debate`, `### Sin resolver`, `### Fuera de alcance`. Sección vacía → `- (ninguno)`. Fuera de alcance vacía se omite.
- `v<k>` se reserva con `mkdir` (sin `-p`) antes de escribir nada; round0 escribe `v<k>/completo` al terminar. v1 existente → rc 64: completo → "g<N> ya tiene v1"; sin `completo` → "v1 incompleto: borra <ruta> y relanza".
- `report` escribe `v<k>/informe.md` (sobrescribe), lo imprime y añade a `log.md` la línea `- informe: informe.md (<n> objeciones: <a> abiertas)`.
- Bash 3.2: sin `declare -A`, `mapfile`, `${x,,}`.

## Review Focus

1. `round0 --task T --gate 1` dos veces → la segunda rc 64 y no toca `v1` (Task 1).
2. `report` sin `objeciones.json` → rc 64 con mensaje que dice qué escribir (Task 2).
3. `hallazgo` o `nota` con `|` o saltos de línea → la tabla no se rompe (`|` → `\|`, salto → espacio) (Task 2).
4. `report` dos veces → `informe.md` igual al de la segunda; `log.md` con dos líneas de puntero, no dos informes (Task 2).
5. `debate` sobre un run_dir de tarea → el repo se deriva bien (`${run_dir%/.consenso/*}`) (Task 1).

---

### Task 1: round0 con --task/--gate

**Files:**
- Modify: `consenso.sh` (`cmd_round0`: opciones; `consenso_run_dir` recibe un subdirectorio opcional)
- Test: `tests/test_round0.sh`, `tests/test_debate.sh`

**Interfaces:**
- Produces: `consenso_tarea_dir <workdir> <task> <gate>` → imprime `<workdir>/.consenso/<task>/g<gate>`; `consenso_validar_tarea <task> <gate>` → 0 o rc 64 con mensaje.

- [ ] **Step 1: tests que fallan**
  - `round0 --task demo --gate 1 --diff d.txt --workdir $tmp` → última línea `$tmp/.consenso/demo/g1/v1` (absoluta) con `entrada`, `agentes`, `log.md`; `.consenso/.gitignore` existe.
  - `v1/completo` existe al terminar.
  - repetir → rc 64 con "ya tiene v1"; `v1/log.md` sin cambios (cmp con copia previa).
  - `v1` sin `completo` → rc 64 con "incompleto".
  - dos round0 simultáneos (`STUB_CODEX_SLEEP=1`, `CONSENSO_AGENTS=codex`, en background) → exactamente uno rc 0 y otro rc 64.
  - rc 64: `--task demo` solo; `--gate 1` solo; `--task "Mal Id"`; `--gate 0`; `--gate 01`; `--gate x`.
  - test_debate: debate sobre `$tmp/.consenso/demo/g1/v1` (run de tarea con stubs) → CLI con cwd `$tmp`.
- [ ] **Step 2:** `bash tests/run.sh` → FAIL.
- [ ] **Step 3:** implementar. El log de la versión lleva `Tarea: <T> · gate <N> · v1`.
- [ ] **Step 4:** `bash tests/run.sh` → verde.

### Task 2: objeciones.json y report

**Files:**
- Modify: `consenso.sh` (`cmd_report`, `consenso_validar_objeciones`, `consenso_informe`, `main`)
- Test: `tests/test_report.sh` (nuevo), `tests/run.sh` cuenta 18

**Interfaces:**
- Consumes: `consenso_tarea_dir`, `consenso_validar_tarea` (Task 1).
- Produces: `report --task T --gate N [--workdir W]` → imprime el informe y lo anexa a `g<N>/v<última>/log.md`; `consenso_informe <objeciones.json>` imprime el Markdown.

- [ ] **Step 1: tests que fallan** (`tests/test_report.sh`)
  - objeciones O1 acordada, O2 resuelta, O3 rechazada, O4 abierta, O5 fuera_de_alcance → stdout tiene las 4 secciones en orden; O1 bajo Acordado; O2 y O3 bajo Resuelto por debate; O4 bajo Sin resolver; O5 bajo Fuera de alcance; tabla con fila `| O4 | abierta |`.
  - `v1/informe.md` = stdout, con encabezado `## Informe (gate 1, v1)`; `log.md` contiene `- informe: informe.md (5 objeciones: 1 abiertas)`.
  - segundo `report` tras cambiar O4 a resuelta → `informe.md` sin O4 bajo Sin resolver; `log.md` no contiene `### Acordado`.
  - con `v2` presente y `version: 1` → rc 64 ("es de v1 y la última es v2"); con `version: 2` → `v2/informe.md`.
  - solo acordadas → Sin resolver y Resuelto `- (ninguno)`; sin `### Fuera de alcance`.
  - `hallazgo` con `a|b` y salto de línea → fila de tabla en una sola línea con `a\|b`.
  - rc 65: id `X1`, id `O0`, id repetido, estado `pendiente`, falta `nota`, `objeciones` no es array, falta `version`.
  - rc 64: sin `objeciones.json`; gate sin versiones; sin `--task`.
- [ ] **Step 2:** FAIL.
- [ ] **Step 3:** implementar. Versión "última" = mayor `k` numérico de `v<k>` (v10 > v9).
- [ ] **Step 4:** verde.

### Task 3: skill, README y validación

**Files:**
- Modify: `skills/consenso/SKILL.md` (sección **Tareas**: cuándo usar `--task/--gate`; tras la síntesis, escribir `g<N>/objeciones.json` con ids que continúan la numeración y nunca se renumeran; `nota` dice quién respaldó o quién cedió; luego `report` en vez de redactar el informe a mano. Sin `--task`, el informe a mano sigue como hoy.)
- Modify: `README.md` (uso de `--task/--gate` y `report`)
- Test: `tests/test_prompts.sh` (SKILL.md contiene `objeciones.json` y `consenso.sh" report`)

- [ ] **Step 1:** test que falla → implementar → verde en bash 3.2 y 5.2.
- [ ] **Step 2:** consenso sobre el diff usando la propia tarea (`--task tareas --gate 2`), objeciones y `report` reales.
- [ ] **Step 3:** versión 1.7.0, commit.
