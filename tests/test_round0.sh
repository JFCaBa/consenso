#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
export CONSENSO_CODEX_BIN="$HERE/stubs/codex"
export CONSENSO_AGY_BIN="$HERE/stubs/agy"
export CONSENSO_QWEN_BIN="$HERE/stubs/qwen"
export CONSENSO_OPENCODE_BIN="$HERE/stubs/opencode"
export CONSENSO_TIMESTAMP="2026-07-06-1200"
SCRIPT="$HERE/../consenso.sh"

tmp="$(mktemp -d)"
printf 'diff --git a/foo.py b/foo.py\n+return 1/0\n' > "$tmp/d.txt"

# round0 con diff explícito.
out="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir="$(printf '%s\n' "$out" | tail -1)"
assert_eq "$run_dir" "$tmp/.consenso/2026-07-06-1200" "imprime el run_dir en la ultima linea"
assert_contains "$(cat "$run_dir/codex.json")" "division por cero" "escribe codex.json"
assert_contains "$(cat "$run_dir/agy.json")" "docstring" "escribe agy.json"
assert_contains "$(cat "$run_dir/log.md")" "codex" "el log menciona a codex"
assert_eq "$(cat "$run_dir/modo")" "diff" "diff: persiste el modo en run_dir"

# Elenco completo: 4 agentes -> 4 json + fichero agentes.
out4="$(bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir4="$(printf '%s\n' "$out4" | tail -1)"
assert_eq "$(cat "$run_dir4/agentes")" "codex
agy
qwen
opencode" "persiste el elenco completo en orden"
assert_contains "$(cat "$run_dir4/qwen.json")" "sin test" "escribe qwen.json"
assert_contains "$(cat "$run_dir4/opencode.json")" "error silenciado" "escribe opencode.json"

# Degradación a 1 -> aviso.
out1="$(CONSENSO_AGENTS=codex bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir1="$(printf '%s\n' "$out1" | tail -1)"
assert_contains "$(cat "$run_dir1/log.md")" "consenso debilitado" "avisa con 1 solo agente"

# CONSENSO_AGENTS con id desconocido: consenso_detectar devuelve rc 64, y ese
# rc no debe perderse tras la limpieza del content_tmp en round0.
assert_exit 64 env CONSENSO_AGENTS=codex,noexiste bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"

# 0 agentes -> rc 4.
assert_exit 4 env CONSENSO_CODEX_BIN=/no/existe CONSENSO_AGY_BIN=/no/existe \
  CONSENSO_QWEN_BIN=/no/existe CONSENSO_OPENCODE_BIN=/no/existe \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"

# Diff vacío -> exit 3.
printf '' > "$tmp/empty.txt"
assert_exit 3 bash "$SCRIPT" round0 --diff "$tmp/empty.txt" --workdir "$tmp"

# Registro inválido -> rc 65 antes de crear nada.
printf '{"agentes":[]}' > "$tmp/reg-malo.json"
assert_exit 65 env CONSENSO_REGISTRY="$tmp/reg-malo.json" \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp"

# Un agente falla (rc!=0 y salida basura): el otro sigue, round0 no aborta.
out2="$(STUB_CODEX_RC=1 STUB_CODEX_OUT='boom' bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp")"
run_dir2="$(printf '%s\n' "$out2" | tail -1)"
# Un fallo no puede parecer una revisión sin hallazgos: sin <id>.json y el log
# lo dice claro.
[ ! -e "$run_dir2/codex.json" ] || fail "codex fallido no debe dejar codex.json (parecería [] = OK)"
assert_contains "$(cat "$run_dir2/log.md")" "codex: FALLÓ" "el log marca la revisión fallida"
assert_contains "$(cat "$run_dir2/agy.json")" "docstring" "agy sigue funcionando"

# El revisor trabaja en el repo revisado, no en el directorio del llamante.
mkdir -p "$tmp/repo" "$tmp/otro"
( cd "$tmp/otro" && STUB_CODEX_PWD_FILE="$tmp/pwd.txt" CONSENSO_AGENTS=codex \
    bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp/repo" >/dev/null )
assert_eq "$(cat "$tmp/pwd.txt")" "$(cd "$tmp/repo" && pwd)" "round0 lanza el CLI en --workdir"

# Rutas relativas de binario y registro siguen valiendo tras el cd al workdir.
mkdir -p "$tmp/llamante/bin"
cp "$HERE/stubs/codex" "$tmp/llamante/bin/codex"
cp "$HERE/../agents/registry.json" "$tmp/llamante/reg.json"
out_rel="$( cd "$tmp/llamante" && CONSENSO_AGENTS=codex CONSENSO_CODEX_BIN=./bin/codex \
    CONSENSO_REGISTRY=reg.json bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp/repo" )"
assert_contains "$(cat "$(printf '%s\n' "$out_rel" | tail -1)/codex.json")" "division por cero" \
  "binario y registro relativos se resuelven desde el llamante"

# .consenso/ no ensucia el git status del repo revisado.
assert_eq "$(cat "$tmp/repo/.consenso/.gitignore")" "*" "crea .consenso/.gitignore"

# Un prompt con & llega intacto (bash 5.2 activa patsub_replacement).
printf '+a && b & c\n' > "$tmp/amp.txt"
CONSENSO_AGENTS=codex STUB_CODEX_STDIN_FILE="$tmp/stdin.txt" \
  bash "$SCRIPT" round0 --diff "$tmp/amp.txt" --workdir "$tmp/repo" >/dev/null
assert_contains "$(cat "$tmp/stdin.txt")" "+a && b & c" "los & del prompt llegan intactos"

# Prompt mayor que ARG_MAX (1 MB macOS; 128 KB por argumento en Linux): por
# stdin llega entero, hasta el final.
{ printf '+'; head -c 1200000 /dev/zero | tr '\0' 'x'; printf '\n+FIN-DEL-DIFF-GRANDE\n'; } > "$tmp/grande.txt"
out_g="$(CONSENSO_AGENTS=codex STUB_CODEX_STDIN_FILE="$tmp/stdin-g.txt" \
  bash "$SCRIPT" round0 --diff "$tmp/grande.txt" --workdir "$tmp/repo")"
assert_contains "$(cat "$(printf '%s\n' "$out_g" | tail -1)/codex.json")" "division por cero" "prompt grande: codex revisa"
assert_contains "$(tail -c 100 "$tmp/stdin-g.txt")" "FIN-DEL-DIFF-GRANDE" "prompt grande: llega entero"

# stdin viene de un fichero, no de un pipe (sin SIGPIPE si el CLI no lo lee).
CONSENSO_AGENTS=codex STUB_CODEX_STDIN_KIND_FILE="$tmp/kind.txt" \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp/repo" >/dev/null
assert_eq "$(cat "$tmp/kind.txt")" "fichero" "round0: stdin redirigido desde fichero"

# Un CLI que no lee stdin no rompe la revisión (el stub de codex solo lo lee
# con STUB_CODEX_STDIN_FILE).
out_p="$(CONSENSO_AGENTS=codex bash "$SCRIPT" round0 --diff "$tmp/grande.txt" --workdir "$tmp/repo")"
rd_p="$(printf '%s\n' "$out_p" | tail -1)"
assert_contains "$(cat "$rd_p/codex.json")" "division por cero" "prompt grande sin leer stdin: codex revisa igual"
assert_contains "$(cat "$rd_p/log.md")" "codex: participó" "prompt grande sin leer stdin: codex participó"

# Triaje: el log resume cuántos hallazgos van fuera de alcance o son hipotéticos.
H='"severidad":"menor","ubicacion":"x","problema":"p","propuesta":"q"'
out_t="$(CONSENSO_AGENTS=codex STUB_CODEX_OUT="[{$H,\"fuera_de_alcance\":true,\"hipotetica\":false},{$H,\"fuera_de_alcance\":false,\"hipotetica\":true},{$H,\"fuera_de_alcance\":false,\"hipotetica\":false}]" \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp/repo")"
assert_contains "$(cat "$(printf '%s\n' "$out_t" | tail -1)/log.md")" "codex: participó (3 hallazgos; 1 fuera de alcance, 1 hipotéticos)" "recuento de triaje en el log"
out_v="$(CONSENSO_AGENTS=codex STUB_CODEX_OUT='[]' bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp/repo")"
assert_contains "$(cat "$(printf '%s\n' "$out_v" | tail -1)/log.md")" "codex: participó (0 hallazgos; 0 fuera de alcance, 0 hipotéticos)" "recuento con []"
# via=prompt: campo ausente cuenta como false; "true" como string, como true.
out_o="$(CONSENSO_AGENTS=opencode STUB_OPENCODE_OUT="[{$H},{$H,\"fuera_de_alcance\":\"true\"}]" \
  bash "$SCRIPT" round0 --diff "$tmp/d.txt" --workdir "$tmp/repo")"
assert_contains "$(cat "$(printf '%s\n' "$out_o" | tail -1)/log.md")" "opencode: participó (2 hallazgos; 1 fuera de alcance, 0 hipotéticos)" "recuento tolerante en via=prompt"

# round0 con --plan: revisa el plan como prosa y lo marca en el log.
printf '# Plan\n1. Anadir endpoint\n2. Migrar tabla usuarios\n' > "$tmp/plan.md"
out3="$(bash "$SCRIPT" round0 --plan "$tmp/plan.md" --workdir "$tmp")"
run_dir3="$(printf '%s\n' "$out3" | tail -1)"
assert_contains "$(cat "$run_dir3/codex.json")" "division por cero" "plan: escribe codex.json"
assert_contains "$(cat "$run_dir3/agy.json")" "docstring" "plan: escribe agy.json"
assert_contains "$(cat "$run_dir3/log.md")" "plan" "plan: el log distingue el modo"
assert_eq "$(cat "$run_dir3/modo")" "plan" "plan: persiste el modo en run_dir"

# Si la construcción del prompt falla (rol inexistente), round0 aborta limpio.
( . "$SCRIPT"; CONSENSO_HOME="/no/existe"; cmd_round0 --diff "$tmp/d.txt" --workdir "$tmp" ) >/dev/null 2>&1
assert_eq "$?" "2" "round0 aborta si falla la construcción del prompt"

# Plan vacío -> exit 3 (igual que diff vacío).
assert_exit 3 bash "$SCRIPT" round0 --plan "$tmp/empty.txt" --workdir "$tmp"

# --plan y --diff a la vez: excluyentes -> error de uso.
assert_exit 64 bash "$SCRIPT" round0 --plan "$tmp/plan.md" --diff "$tmp/d.txt" --workdir "$tmp"

# flag sin valor (última posición): error de uso limpio, no crash por set -u.
assert_exit 64 bash "$SCRIPT" round0 --workdir
assert_exit 64 bash "$SCRIPT" round0 --diff
assert_exit 64 bash "$SCRIPT" round0 --plan

rm -rf "$tmp"
echo "OK test_round0"
