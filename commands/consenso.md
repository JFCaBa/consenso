---
description: Revisión por consenso multiagente (Codex + Gemini + Claude) con debate cruzado
---

Orquestas una revisión por **consenso** del cambio actual usando `consenso.sh`
(en el mismo repo que este command) más tu propio juicio. Codex y Gemini se
invocan por el script; tú (Claude) aportas tu lente de legibilidad y sintetizas.

## Cuándo disparar esto automáticamente (puntos críticos)

Dispara este flujo sin que te lo pidan cuando vayas a hacer algo de esta
lista; basta con que se dé un solo punto crítico:

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
