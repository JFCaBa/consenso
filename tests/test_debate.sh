#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
nuevo_run() {
  # Imprime un run_dir nuevo como lo deja round0: elenco codex+agy, entrada
  # revisada y los hallazgos de ronda 0 de codex. mktemp y no un contador: se
  # llama dentro de $(...), donde un contador no avanzaría.
  local d
  d="$(mktemp -d "$tmp/repo.XXXXXX")/.consenso/ts"
  mkdir -p "$d"
  printf 'codex\nagy\n' > "$d/agentes"
  printf 'diff original con return 1/0\n' > "$d/entrada"
  printf '[{"severidad":"menor","ubicacion":"a:1","problema":"hallazgo-r0-codex","propuesta":"x","fuera_de_alcance":false,"hipotetica":false}]' > "$d/codex.json"
  printf '%s' "$d"
}
v() { printf '[{"punto":"%s","veredicto":"%s","argumento":"%s"}]' "$1" "$2" "$3"; }

printf '[{"id":"P1","punto":"Codex dice X","posturas":"Agy dice no-X"}]' > "$tmp/p1.json"
printf '[{"id":"P1","punto":"a","posturas":"b"},{"id":"P2","punto":"c","posturas":"d"}]' > "$tmp/p12.json"

# --- Ronda 1: memoria (entrada + hallazgos propios), veredicto JSON, log ---
rd="$(nuevo_run)"
out="$(STUB_CODEX_STDIN_FILE="$tmp/stdin1.txt" STUB_CODEX_OUT="$(v P1 cedo ok)" STUB_AGY_OUT="$(v P1 mantengo arg-agy-r1)" \
  bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd")"
assert_eq "$(printf '%s\n' "$out" | tail -1)" "$rd" "debate imprime el run-dir"
assert_eq "$(jq -r '.[0].veredicto' "$rd/debate-1-codex.json")" "cedo" "guarda el veredicto de codex"
assert_eq "$(jq -r '.[0].veredicto' "$rd/debate-1-agy.json")" "mantengo" "guarda el veredicto de agy"
s1="$(cat "$tmp/stdin1.txt")"
assert_contains "$s1" "diff original con return 1/0" "ronda 1: lleva la entrada original"
assert_contains "$s1" "TUS HALLAZGOS EN RONDA 0" "ronda 1: lleva los hallazgos propios"
assert_contains "$s1" "hallazgo-r0-codex" "ronda 1: los hallazgos son los de codex"
assert_contains "$s1" '"id":"P1"' "ronda 1: lleva los puntos con id"
case "$s1" in
  *"VEREDICTOS DE LA RONDA 1"*) fail "ronda 1: no lleva veredictos previos" ;;
esac
assert_contains "$(cat "$rd/log.md")" "debate ronda 1: codex respondió (1 veredictos: 0 mantengo, 0 rebato, 1 cedo)" "log resume los veredictos"
assert_exit 0 cmp -s "$tmp/p1.json" "$rd/puntos-1.json"

# --- Ronda 2: lleva los veredictos de la ronda 1 ---
STUB_CODEX_STDIN_FILE="$tmp/stdin2.txt" STUB_CODEX_OUT="$(v P1 cedo ok)" STUB_AGY_OUT="$(v P1 cedo ok)" \
  bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" --round 2 >/dev/null
s2="$(cat "$tmp/stdin2.txt")"
assert_contains "$s2" "VEREDICTOS DE LA RONDA 1" "ronda 2: lleva los veredictos previos"
assert_contains "$s2" "arg-agy-r1" "ronda 2: incluye el argumento de agy en ronda 1"
assert_eq "$(jq -r '.[0].veredicto' "$rd/debate-2-agy.json")" "cedo" "ronda 2: guarda el veredicto"

# --- Límite de rondas ---
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" --round 2
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" --round 1
for r in 0 3 x; do
  assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$(nuevo_run)" --round "$r"
done
rd_sin1="$(nuevo_run)"
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd_sin1" --round 2
assert_exit 1 test -e "$rd_sin1/debate-2-codex.json"

# --- Fallo parcial: relanzar la ronda corre solo al que falta ---
rd="$(nuevo_run)"
STUB_CODEX_RC=1 STUB_AGY_OUT="$(v P1 mantengo primera)" \
  bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" >/dev/null
assert_exit 1 test -e "$rd/debate-1-codex.json"
assert_contains "$(cat "$rd/log.md")" "debate ronda 1: codex NO respondió" "log marca al que falló"
STUB_CODEX_OUT="$(v P1 cedo ok)" STUB_AGY_OUT="$(v P1 mantengo segunda)" \
  bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" >/dev/null
assert_eq "$(jq -r '.[0].veredicto' "$rd/debate-1-codex.json")" "cedo" "relanzar: codex corre"
assert_contains "$(cat "$rd/debate-1-agy.json")" "primera" "relanzar: agy no corre de nuevo"
assert_contains "$(cat "$rd/log.md")" "debate ronda 1: agy ya respondió, se omite" "log marca al omitido"
# Los puntos quedan fijados al primer intento de la ronda.
rd="$(nuevo_run)"
STUB_CODEX_RC=1 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" >/dev/null
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p12.json" --run-dir "$rd"
assert_exit 0 bash "$SCRIPT" debate --points "$rd/puntos-1.json" --run-dir "$rd"

# --- Cobertura de puntos ---
rd="$(nuevo_run)"
STUB_CODEX_OUT="$(v P1 cedo ok)" STUB_AGY_OUT="$(v P9 rebato no)" \
  bash "$SCRIPT" debate --points "$tmp/p12.json" --run-dir "$rd" >/dev/null
log="$(cat "$rd/log.md")"
assert_contains "$log" "codex respondió (1 veredictos: 0 mantengo, 0 rebato, 1 cedo; sin veredicto: P2)" "log: punto sin veredicto"
assert_contains "$log" "id desconocido: P9" "log: id desconocido"

# --- Puntos mal formados -> rc 64 sin lanzar agentes ---
printf 'no es json' > "$tmp/mal1"
printf '[]' > "$tmp/mal2"
printf '[{"id":"P1","punto":"a","posturas":"b"},{"id":"P1","punto":"c","posturas":"d"}]' > "$tmp/mal3"
printf '[{"id":"P1","punto":"a"}]' > "$tmp/mal4"
for m in mal1 mal2 mal3 mal4; do
  rd="$(nuevo_run)"
  assert_exit 64 bash "$SCRIPT" debate --points "$tmp/$m" --run-dir "$rd"
  assert_exit 1 test -e "$rd/debate-1-codex.json"
done

# --- Run de una versión anterior sin entrada: sigue y lo anota ---
rd="$(nuevo_run)"
rm -f "$rd/entrada"
assert_exit 0 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd"
assert_contains "$(cat "$rd/log.md")" "sin entrada original" "log: run sin entrada"

# --- Agente via=schema sin {CLAVE} en extract -> rc 65 antes de lanzar ---
jq '(.agentes[] | select(.id=="codex") | .json.extract) = ".hallazgos"' "$HERE/../agents/registry.json" > "$tmp/reg-sin-clave.json"
rd="$(nuevo_run)"
assert_exit 65 env CONSENSO_REGISTRY="$tmp/reg-sin-clave.json" \
  bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd"
assert_exit 1 test -e "$rd/debate-1-agy.json"

# --- cwd, stdin desde fichero, binario relativo ---
rd="$(nuevo_run)"
( cd / && STUB_CODEX_PWD_FILE="$tmp/pwd.txt" STUB_CODEX_STDIN_KIND_FILE="$tmp/kind.txt" \
    bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" >/dev/null )
assert_eq "$(cat "$tmp/pwd.txt")" "$(cd "$rd/../.." && pwd)" "debate lanza el CLI en el repo del run"
assert_eq "$(cat "$tmp/kind.txt")" "fichero" "debate: stdin redirigido desde fichero"

rd="$(nuevo_run)"
mkdir -p "$tmp/llamante/bin"
cp "$HERE/stubs/codex" "$tmp/llamante/bin/codex"
( cd "$tmp/llamante" && CONSENSO_CODEX_BIN=./bin/codex STUB_CODEX_OUT="$(v P1 rebato rel-ok)" \
    bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" >/dev/null )
assert_contains "$(cat "$rd/debate-1-codex.json")" "rel-ok" "debate: binario relativo se resuelve desde el llamante"

# --- Elenco de 3 con un agente via=prompt (fences) ---
rd="$(nuevo_run)"
printf 'codex\nagy\nqwen\n' > "$rd/agentes"
STUB_QWEN_OUT="$(printf '```json\n%s\n```' "$(v P1 cedo matizo)")" \
  bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" >/dev/null
assert_contains "$(cat "$rd/debate-1-qwen.json")" "matizo" "debate llega al tercer agente (via=prompt)"

# --- Instrucción según el modo persistido por round0 ---
. "$SCRIPT"
rd="$(nuevo_run)"
assert_contains "$(consenso_debate_instruccion "$rd")" "revisión de código" "sin fichero de modo: instrucción de código"
printf 'plan' > "$rd/modo"
con_plan="$(consenso_debate_instruccion "$rd")"
assert_contains "$con_plan" "plan de implementación" "modo plan: instrucción de plan"
case "$con_plan" in
  *"revisión de código"*) fail "modo plan: no debe hablar de revisión de código" ;;
esac

# --- Guards de uso ---
rd="$(nuevo_run)"
assert_exit 64 bash "$SCRIPT" debate --points
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd" --round
printf '{"agentes":[]}' > "$tmp/reg-malo.json"
assert_exit 65 env CONSENSO_REGISTRY="$tmp/reg-malo.json" \
  bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd"

# run-dir existente pero con elenco vacío -> rc 64, no un no-op con rc 0.
rd_vacio="$tmp/repo-vacio/.consenso/vacio"
mkdir -p "$rd_vacio"
assert_exit 64 bash "$SCRIPT" debate --points "$tmp/p1.json" --run-dir "$rd_vacio"

# Sin fichero agentes: reconstruye desde <id>.json (nunca redetecta).
rd_legacy="$tmp/repo-legacy/.consenso/legacy"
mkdir -p "$rd_legacy"
printf '[]' > "$rd_legacy/codex.json"
printf '[]' > "$rd_legacy/agy.json"
assert_eq "$(consenso_elenco_de "$rd_legacy")" "codex
agy" "reconstruye elenco desde artefactos"

rm -rf "$tmp"
echo "OK test_debate"
