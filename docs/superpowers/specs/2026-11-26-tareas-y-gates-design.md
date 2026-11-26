# Iteraciones de una tarea (--task / --gate, revise, report) — diseño

**Origen:** feedback de David sobre v1.2.0, punto 5 (versión mínima).

## Intención

Hoy cada versión nueva de un plan o diff abre un run desde cero, y la
orquestación entre versiones (puntos, enlaces entre runs, informe final) se
hace a mano. En el uso de David, menos de la mitad de los runs acabaron con
informe, cada uno con su formato. El objetivo es que una tarea y sus revisiones
sucesivas sean un concepto del plugin, y que el informe salga siempre igual.

## Objetivos

- Agrupar los runs de una tarea por **gate** (etapa de revisión: 1 = plan,
  2 = diff, …) y por **versión** dentro de cada gate.
- Objeciones con **ids estables** (`O1`, `O2`, …) que sobreviven entre
  versiones.
- `report`: informe de 4 secciones generado por el script.
- `revise`: re-revisión de una versión nueva con el artefacto completo, lo que
  cambió y las objeciones abiertas.

## No objetivos

- Reanudar la sesión del CLI entre rondas (David pide medirlo antes).
- `prune` y compresión de `.err` (punto 8, aplazado).
- Que el script decida estados: los decide Claude en la síntesis; el script
  valida, conserva y presenta.

## Anti-objetivos

- Romper el uso sin `--task`: sin la opción, todo sigue como hoy.
- Ids que cambian entre versiones.

## Decisiones (aprobadas 2026-11-26)

- `--gate <n>` = etapa de revisión (elegido por el usuario frente a "número de
  versión").
- Layout: `.consenso/<task>/g<n>/v<k>/` es un run_dir normal (mismos ficheros
  que hoy); `.consenso/<task>/g<n>/objeciones.json` es del gate.
- `objeciones.json`: objeto `{version, objeciones}`; `version` = k de la
  versión sintetizada; `objeciones` = array de `{id, hallazgo, estado, nota}`;
  `id` `^O[1-9][0-9]*$` único; `estado` ∈ `abierta` | `acordada` | `resuelta` | `rechazada` |
  `fuera_de_alcance`; `nota` string (puede ser vacía). Lo escribe Claude tras
  la síntesis; ids nuevos continúan la numeración, nunca se renumera.
- `report` mapea estados a secciones: `acordada` → Acordado; `resuelta` y
  `rechazada` → Resuelto por debate; `abierta` → Sin resolver;
  `fuera_de_alcance` → Fuera de alcance. Añade una tabla id | estado |
  hallazgo. Lo escribe en `v<k>/informe.md` (sobrescribe: idempotente), lo
  imprime y deja una línea en `log.md`. Rechaza un `objeciones.json` cuya
  `version` no sea la última.

## Enfoques considerados

- **Índice de runs** (`.consenso/<task>.json` que enlaza run_dirs con
  timestamp): menos cambio en round0, pero dos sitios que mantener
  sincronizados. Descartado.
- **Layout por tarea/gate/versión** (elegido): el directorio ya es el índice.
- **Script asigna ids** a partir de los hallazgos: exigiría deduplicar
  hallazgos entre agentes en bash. Descartado: Claude ya hace esa síntesis.

## Partes

- **A — tarea, objeciones y report.** `round0 --task T --gate N` crea
  `g<N>/v1`; si ya existe → rc 64 ("usa revise"). `report --task T --gate N`.
  Validación de `objeciones.json`. Skill: con `--task`, tras la síntesis
  escribe `objeciones.json` y llama a `report`.
- **B — revise.** `revise --task T --gate N [--diff|--plan|--workdir]` crea
  `v<k+1>`, guarda `cambios` (`diff -u` entre entradas) y pide a cada agente,
  en una sola llamada con esquema combinado, hallazgos nuevos y un
  seguimiento por objeción abierta (`resuelta` | `sigue_abierta` +
  argumento). Se diseña en detalle al terminar A.

## Lo que queda al implementador

Mensajes de error exactos, nombres de funciones auxiliares, formato visual de
la tabla Markdown.
