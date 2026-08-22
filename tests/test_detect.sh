#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"

# Elenco determinista en cualquier máquina: cada agente se fija con su
# override CONSENSO_<ID>_BIN (a un stub que existe o a una ruta inexistente).
# NUNCA manipular PATH a secas: rompería jq/grep dentro de consenso_detectar
# y en máquinas con los CLIs reales instalados el resultado variaría.
tmp="$(mktemp -d)"
mkdir "$tmp/bin"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/codex"; chmod +x "$tmp/bin/codex"
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/qwen";  chmod +x "$tmp/bin/qwen"
export CONSENSO_CODEX_BIN="$tmp/bin/codex"
export CONSENSO_AGY_BIN=/no/existe
export CONSENSO_QWEN_BIN="$tmp/bin/qwen"
export CONSENSO_OPENCODE_BIN=/no/existe

# Detecta solo los presentes, en orden de prioridad del registro.
assert_eq "$(consenso_detectar)" "codex
qwen" "detecta codex y qwen en orden"

# Override de bin apunta a un binario existente -> el agente aparece.
printf '#!/bin/sh\nexit 0\n' > "$tmp/bin/agy-custom"; chmod +x "$tmp/bin/agy-custom"
assert_eq "$(CONSENSO_AGY_BIN="$tmp/bin/agy-custom" consenso_detectar)" "codex
agy
qwen" "override de bin activa a agy"

# CONSENSO_AGENTS filtra (en orden de prioridad, no de la lista).
assert_eq "$(CONSENSO_AGENTS=qwen,codex consenso_detectar)" "codex
qwen" "subconjunto respeta prioridad"

# CONSENSO_AGENTS tolera espacios alrededor de las comas (p.ej. copiado del
# README o tecleado a mano): mismo resultado que sin espacios.
assert_eq "$(CONSENSO_AGENTS='qwen, codex' consenso_detectar)" "codex
qwen" "tolera espacios en CONSENSO_AGENTS"

# CONSENSO_AGENTS inválido -> rc 64 (heredan los CONSENSO_*_BIN exportados).
assert_exit 64 env CONSENSO_AGENTS=codex,noexiste bash -c ". '$HERE/../consenso.sh'; consenso_detectar"
assert_exit 64 env CONSENSO_AGENTS=codex,codex bash -c ". '$HERE/../consenso.sh'; consenso_detectar"
assert_exit 64 env CONSENSO_AGENTS=codex,, bash -c ". '$HERE/../consenso.sh'; consenso_detectar"

# Sin binarios -> imprime vacío, rc 0.
assert_eq "$(CONSENSO_CODEX_BIN=/no/existe CONSENSO_QWEN_BIN=/no/existe consenso_detectar)" "" "sin CLIs -> elenco vacío"

rm -rf "$tmp"
echo "OK test_detect"
