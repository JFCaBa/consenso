# Consenso multiagente — Diseño

**Fecha:** 2026-07-06
**Estado:** Aprobado (diseño), pendiente de plan de implementación

## Propósito

Convertir en un flujo repetible el patrón ad-hoc que funcionó en el proyecto `sail`
(donde Claude consultaba a Codex y se incorporaban sus revisiones, elevando la calidad
del código y del análisis). El flujo hace que **Claude, Gemini y Codex** revisen trabajo
de programación cada uno con su fortaleza, y exige un **consenso mediante debate cruzado**
antes de dar algo por bueno.

## Alcance

- **Global y reutilizable**: se instala una vez en `~/.claude/` y está disponible en
  cualquier proyecto. No lleva configuración por proyecto (YAGNI; se puede añadir después).
- **Puerta de consenso en dos momentos**, no en cada cambio:
  1. **Revisión de código** — sobre un diff ya escrito.
  2. **Puntos críticos/de riesgo** — decisiones irreversibles o peligrosas.
- No aplica a cada paso ni a toda decisión de diseño: ese era el punto óptimo
  calidad/coste elegido.

## Agentes y herramientas

Los tres CLIs están instalados y corren en modo headless:

| Agente | CLI | Invocación headless |
|---|---|---|
| Codex | `codex` 0.141 | `codex exec "<prompt>"` (o `codex review` para revisión dedicada) |
| Gemini | `gemini` 0.44 | `gemini -p "<prompt>" -o json` |
| Claude | `claude` 2.1 | es el orquestador; revisa en la propia sesión |

## Roles fijos (lente principal)

Cada agente revisa con un ángulo asignado para maximizar cobertura y minimizar solapamiento:

| Agente | Lente |
|---|---|
| **Codex** | Corrección, edge-cases, lógica fina, bordes de seguridad |
| **Gemini** | Arquitectura, contexto amplio, dependencias, coherencia del sistema |
| **Claude** | Síntesis, legibilidad, mantenibilidad + orquesta el debate |

## Arquitectura

**Empaquetado:** slash command global `/consenso` en `~/.claude/commands/consenso.md`,
apoyado por un script `consenso.sh`.

- **`consenso.sh` (determinismo + trazabilidad):** reparte el diff/contexto a cada agente
  con el mismo formato de prompt, recoge sus salidas, gestiona las rondas y escribe el log.
- **Claude (juicio):** deduplica y clasifica hallazgos, decide qué va a debate, pesa
  argumentos, redacta el informe final.

La parte mecánica no depende de improvisación; la parte de criterio no se encierra en un
script rígido.

## Flujo de consenso

```
DISPARO: revisión de código  ó  punto crítico detectado
   │
   ▼
RONDA 0 — Revisión independiente (en paralelo, cada uno con su lente)
   Codex ─┐
   Gemini ─┼─► hallazgos: {severidad, ubicación, problema, propuesta}
   Claude ─┘
   │
   ▼
SÍNTESIS (Claude): deduplica y clasifica
   • ACUERDO   → varios señalan lo mismo  → alta confianza, aplicar
   • SINGLETON → solo uno lo ve           → a debate
   • CONFLICTO → A dice X, B dice no-X     → a debate
   │
   ▼
RONDA 1 — Debate cruzado (solo singletons y conflictos)
   Cada agente ve las críticas de los otros → rebate / cede / matiza, con argumento
   │
   ▼
¿Convergen?  ── sí ─► RESUELTO
   │ no (tras 1–2 rondas)
   ▼
FALLBACK: Claude sintetiza recomendación + presenta el desacuerdo vivo → decide el humano
   │
   ▼
INFORME DE CONSENSO  (+ log con trazabilidad completa)
```

### Detalle de cada fase

- **Ronda 0 (paralela):** cada agente recibe el diff + su prompt de rol + el formato de
  salida (lista de hallazgos estructurados). Codex vía `codex exec`, Gemini vía
  `gemini -p -o json`, Claude en la sesión.
- **Síntesis:** Claude agrupa hallazgos equivalentes (misma ubicación + mismo problema),
  marca acuerdos (alta confianza), y separa singletons y conflictos para debate.
- **Ronda 1 (debate):** solo sobre lo contestado. A cada agente se le muestran las
  críticas de los otros sobre esos puntos y se le pide: mantener / rebatir / ceder, con
  argumento técnico. Máximo 2 rondas.
- **Convergencia:** lo que queda respaldado sin oposición pasa a resuelto.
- **Fallback (deadlock real tras 1–2 rondas):** Claude redacta una recomendación y
  presenta ambas posturas enfrentadas al humano, que decide. Solo se activa si de verdad
  no convergen — no molesta al usuario en el caso normal.

## Disparo automático — qué cuenta como "punto crítico"

Claude invoca `/consenso` automáticamente cuando va a hacer alguna de estas cosas
(checklist embebido en el command):

- Migración o borrado de datos
- Cambio de una API pública / contrato externo
- Autenticación, secretos o permisos
- Introducción de una dependencia nueva y pesada
- Cualquier acción irreversible

El usuario también puede invocar `/consenso` manualmente sobre cualquier diff.

## Salida

**Informe de consenso** con tres secciones:

1. **Acordado** → aplicar (con qué agentes lo respaldaron).
2. **Resuelto por debate** → qué se decidió, quién cedió y por qué.
3. **Sin resolver** → decisión del humano, con las dos posturas enfrentadas.

**Log de trazabilidad** guardado en el proyecto activo bajo `.consenso/YYYY-MM-DD-HHMM.md`
con las salidas crudas de cada ronda, para poder auditar cómo se llegó a cada decisión.

## Formato de hallazgo (contrato entre agentes)

Cada agente devuelve una lista de hallazgos. Campos:

- `severidad`: `bloqueante` | `importante` | `menor` | `nit`
- `ubicación`: `ruta:línea` o descripción del punto
- `problema`: qué está mal / qué riesgo hay
- `propuesta`: cambio concreto sugerido

Formato estable (JSON o lista markdown acotada) para que la síntesis sea mecánica y no
dependa de parsear prosa libre.

## Manejo de errores

- **Un agente no responde / falla el CLI:** el flujo continúa con los que sí respondieron
  y el informe deja constancia de quién no participó. El consenso no se bloquea por una
  caída de un CLI.
- **Salida malformada de un agente:** se reintenta una vez pidiendo el formato; si vuelve a
  fallar, se trata como "no participó" en esa ronda.
- **Sin cambios que revisar (diff vacío):** el command lo detecta y termina sin llamar a
  nadie.
- **Timeout por agente:** límite de tiempo por llamada para que una cuelga no bloquee todo.

## Componentes (unidades con propósito único)

1. **`consenso.sh`** — orquestador mecánico: fan-out a los CLIs, recogida de salidas,
   gestión de rondas, escritura del log. Interfaz: recibe diff + ruta de trabajo; produce
   salidas por agente y log.
2. **`~/.claude/commands/consenso.md`** — el slash command: instrucciones para que Claude
   dispare el flujo, la checklist de puntos críticos, el formato de hallazgo y cómo
   redactar el informe.
3. **Prompts de rol** — un prompt por agente que fija su lente y el formato de salida.
   Pueden vivir dentro de `consenso.sh` o como ficheros aparte en el proyecto.

## Criterios de éxito

- Ejecutar `/consenso` sobre un diff real produce un informe con las tres secciones y un
  log de trazabilidad.
- Los tres agentes revisan con su lente y sus hallazgos se deduplican correctamente.
- Un desacuerdo genuino pasa por ≥1 ronda de debate y, si no converge, escala al humano.
- La caída de un CLI no bloquea el flujo.
- Reproduce (o mejora) la calidad que dio el patrón ad-hoc en `sail`.

## Fuera de alcance (por ahora)

- Configuración por proyecto (roles, agentes participantes, definición de "crítico"):
  posible extensión futura.
- Consenso en decisiones de diseño previas al código o en cada paso.
- Integración con CI/hooks de git (podría venir después).
