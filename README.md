# consenso

Flujo de trabajo multiagente para programación: **Claude, Gemini y Codex** revisan el
mismo trabajo, cada uno con su fortaleza, y exigen un **consenso mediante debate cruzado**
antes de dar algo por bueno.

Nace de un patrón que funcionó en la práctica: consultar a un segundo modelo (Codex) sobre
el código escrito elevó de forma notable la calidad. Esto lo convierte en un flujo
repetible y global.

## Idea

- **Puerta de consenso** en dos momentos, no en cada cambio: **revisión de código** y
  **puntos críticos/de riesgo** (migraciones, borrados, API pública, auth/secretos,
  dependencias nuevas, acciones irreversibles).
- **Roles fijos por fortaleza:**
  - **Codex** → corrección, edge-cases, lógica fina, bordes de seguridad
  - **Gemini** → arquitectura, contexto amplio, dependencias, coherencia del sistema
  - **Claude** → síntesis, legibilidad, mantenibilidad + orquesta el debate
- **Resolución por debate:** cada agente ve las críticas de los otros y rebate, cede o
  matiza. Si tras 1–2 rondas no convergen, escala a decisión humana.

## Estado

Diseño aprobado. Ver
[`docs/superpowers/specs/2026-07-06-consenso-multiagente-design.md`](docs/superpowers/specs/2026-07-06-consenso-multiagente-design.md).
Implementación pendiente.

## Requisitos

CLIs en modo headless: `codex` (`codex exec`), `gemini` (`gemini -p`), `claude` como
orquestador.
