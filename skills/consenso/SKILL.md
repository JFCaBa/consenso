---
name: consenso
description: Use SIEMPRE tras escribir un plan de implementación y antes de commitear un diff — revisión por consenso multiagente con debate cruzado y detección dinámica de CLIs (codex, agy, qwen, opencode)
---

Orquestas una revisión por **consenso** del cambio actual usando `consenso.sh`
(en el mismo repo que este command) más tu propio juicio. El script invoca al
elenco de agentes detectado (ver `agents/registry.json`); tú (Claude) aportas
tu lente de legibilidad y sintetizas.

## Cuándo disparar esto automáticamente

Dispara este flujo sin que te lo pidan en estos dos momentos del flujo de
trabajo (incluidos los de superpowers):

- **Plan escrito** — al terminar un plan de implementación (p.ej. la skill
  writing-plans) y antes de ejecutarlo: valida el plan por consenso.
- **Antes de commitear** — con el diff listo y antes de `git commit`: valida
  el diff por consenso.

Y además ante cualquier punto crítico, aunque no haya commit inminente:

- Migración o borrado de datos
- Cambio de una API pública o contrato externo
- Autenticación, secretos o permisos
- Introducir una dependencia nueva y pesada
- Cualquier acción irreversible

También cuando el usuario pida explícitamente revisar un diff o un plan.
Excepción: cambios triviales (typos, formato, docs sin efecto en código) no
necesitan consenso; y si el usuario dice explícitamente que se salte la
revisión, sáltala.

## Validar un plan (no un diff)

Pasa el fichero del plan (p.ej. el `.md` del plan ya escrito) con
`--plan <fichero>` en vez de `--diff`: el prompt lleva el encabezado
"PLAN A REVISAR" y una nota que
orienta a los agentes a evaluar prosa (riesgos, pasos que faltan, supuestos
dudosos, alternativas más simples) en lugar de código.

## Flujo

1. **Ronda 0.** Ejecuta `bash "${CLAUDE_PLUGIN_ROOT}/consenso.sh" round0 --workdir <repo>` (o
   `--diff <fichero>` / `--plan <fichero>`). Lee la última línea de la
   salida: es el `run_dir`. Lee `run_dir/agentes` (el elenco detectado) y el
   `run_dir/<id>.json` de cada agente listado ahí — no un glob de `*.json`.
   Si el log avisa de "consenso debilitado", pesa más tu propia lente y hazlo
   constar en el informe.

2. **Tu revisión.** Revisa tú el mismo diff con tu lente (legibilidad,
   mantenibilidad) y produce tus propios hallazgos en el mismo formato.

3. **Síntesis.** Junta los tres conjuntos de hallazgos y clasifícalos:
   - **Acuerdo**: varios señalan lo mismo (misma ubicación + mismo problema) →
     alta confianza.
   - **Singleton**: solo uno lo ve → candidato a debate.
   - **Conflicto**: uno propone X y otro lo contradice → a debate.

4. **Debate (solo si hay singletons/conflictos).** Escribe un fichero de puntos
   en disputa con las críticas cruzadas y ejecuta
   `bash "${CLAUDE_PLUGIN_ROOT}/consenso.sh" debate --points <fichero> --run-dir <run_dir> --round 1`.
   Lee las respuestas `debate-1-<id>.md` de cada agente del elenco. Si
   convergen, cierra. Si no, una **ronda 2** como máximo.

5. **Fallback (deadlock tras 1–2 rondas).** No fuerces un ganador: presenta al
   usuario las dos posturas enfrentadas con tu recomendación y deja que decida.

6. **Bucle de casos límite → cambio de roles.** Cuenta los ciclos
   revisión → arreglo → revisión sobre el mismo cambio. Para a partir del
   **tercer ciclo** si los hallazgos nuevos que siguen apareciendo son sobre
   todo casos límite en la misma zona y con entradas que los datos reales no
   producen. Señales: cada parche abre otro caso, el código de esa zona crece
   mucho más que el arreglo de fondo, o los hallazgos llevan "entrada
   hipotética". En ese caso **no apliques otro parche**:
   1. Escribe un enunciado del problema **sin tu solución**: objetivo,
      restricciones, datos reales medidos (p.ej. "en la medición hubo un solo
      429") e interfaces existentes que deba respetar. No incluyas tu diseño,
      tu código ni los hallazgos anteriores: eso sesgaría el rediseño.
   2. Ejecuta
      `bash "${CLAUDE_PLUGIN_ROOT}/consenso.sh" alternativa --problem <fichero> --workdir <repo>`
      (por defecto usa el agente de mayor prioridad, normalmente codex; con
      `--agent <id>` eliges otro). El agente diseña su solución a ciegas, desde
      un directorio vacío. Lee el único `alternativa-*.md` del `run_dir` (el
      título de `log.md` dice qué agente lo hizo). Si no hay exactamente uno, la
      ejecución falló: mira `log.md` y el `.err` del agente.
   3. Compara las dos soluciones: tamaño, piezas móviles y qué deja cada una
      fuera de alcance a propósito. Presenta al usuario tu recomendación: la
      tuya simplificada, la suya, o una mezcla. **Que decida el usuario.** Si
      elige rehacer, la nueva versión pasa por una sola ronda de consenso sobre
      el diff.

   Los casos límite con entradas reales o de impacto grave (seguridad, pérdida
   de datos) no cuentan para esta regla: se arreglan.

## Informe (siempre, 3 secciones)

- **Acordado** → aplicar (indica qué agentes lo respaldaron).
- **Resuelto por debate** → qué se decidió, quién cedió y por qué.
- **Sin resolver** → decisión del usuario, con las dos posturas.

Añade el informe final al `run_dir/log.md` para trazabilidad. Si un agente no
participó (lo dice el log de round0), sigue adelante y hazlo constar en el
informe.
