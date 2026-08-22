# consenso

Flujo de trabajo multiagente para programación: **Claude, Agy y Codex** revisan el
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
  - **Agy** (Antigravity, con un modelo Gemini) → arquitectura, contexto amplio, dependencias, coherencia del sistema
  - **Claude** → síntesis, legibilidad, mantenibilidad + orquesta el debate
- **Resolución por debate:** cada agente ve las críticas de los otros y rebate, cede o
  matiza. Si tras 1–2 rondas no convergen, escala a decisión humana.

## Estado

Implementación completa e instalable: `consenso.sh` (orquestador) y el comando
`/consenso` ya están listos para usarse (ver Instalación y Uso más abajo). Ver
el diseño original en
[`docs/superpowers/specs/2026-07-06-consenso-multiagente-design.md`](docs/superpowers/specs/2026-07-06-consenso-multiagente-design.md).

## Requisitos

CLIs en modo headless: `codex` (`codex exec`), `agy` (Antigravity,
`agy --model "Gemini …" -p`; provee la lente de arquitectura con un modelo
Gemini), `claude` como orquestador.

Overrides: `CONSENSO_AGY_CMD` (default `agy`) y `CONSENSO_AGY_MODEL`
(default `Gemini 3.5 Flash (High)`). Con un modelo de la familia Pro, sube
`CONSENSO_TIMEOUT` (default 120s): Pro (High) puede tardar >7 min por revisión.

## Instalación

```bash
git clone https://github.com/JFCaBa/consenso
cd consenso
bash install.sh   # symlinka /consenso en ~/.claude/commands
```

## Uso

En Claude Code, invoca `/consenso` sobre el cambio actual, o deja que Claude lo
dispare automáticamente en puntos críticos. Por debajo:

```bash
bash consenso.sh round0 --workdir .        # revisión independiente (codex+agy)
bash consenso.sh round0 --plan plan.md --workdir .   # revisión de un plan (prosa)
bash consenso.sh debate --points p.txt --run-dir .consenso/<ts>   # ronda de debate
```

Los artefactos y el log quedan en `.consenso/<timestamp>/`.

## Tests

```bash
bash tests/run.sh
```

Los tests usan stubs de los CLIs (`tests/stubs/`) — no llaman a los modelos reales.

## Smoke test manual (CLIs reales)

No automatizado (cuesta tokens y es no determinista). Con `codex` y `agy`
autenticados, sobre un repo con cambios sin commitear:

```bash
bash consenso.sh round0 --workdir /ruta/a/tu/repo
cat /ruta/a/tu/repo/.consenso/*/codex.json
cat /ruta/a/tu/repo/.consenso/*/agy.json
```

Verifica que ambos devuelven un array JSON de hallazgos sobre tu diff.
