#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
SCRIPT="$HERE/../consenso.sh"

# codex responde, agy falla, qwen/opencode no instalados.
out="$(CONSENSO_CODEX_BIN="$HERE/stubs/codex" \
       CONSENSO_AGY_BIN="$HERE/stubs/agy" STUB_AGY_RC=1 \
       CONSENSO_QWEN_BIN=/no/existe CONSENSO_OPENCODE_BIN=/no/existe \
       bash "$SCRIPT" doctor)"
assert_contains "$out" "codex: OK" "codex OK"
assert_contains "$out" "agy: FALLO" "agy FALLO"
assert_contains "$out" "qwen: NOT FOUND" "qwen no instalado"
assert_contains "$out" "opencode: NOT FOUND" "opencode no instalado"

echo "OK test_doctor"
