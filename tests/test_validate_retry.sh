#!/usr/bin/env bash
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib.sh"
. "$HERE/../consenso.sh"
export CONSENSO_CODEX_CMD="$HERE/stubs/codex"
tmp="$(mktemp -d)"

# validate: array válido pasa, prosa no.
printf '%s' '[{"a":1}]' > "$tmp/ok.json"
assert_exit 0 consenso_validate_json "$tmp/ok.json"
printf '%s' 'esto no es json' > "$tmp/bad.json"
assert_exit 1 consenso_validate_json "$tmp/bad.json"

# retry: stub devuelve basura las dos veces -> out queda en [] y rc 1.
STUB_CODEX_OUT="basura no-json" consenso_agent_with_retry codex "p" "$tmp/r.json"
rc=$?
assert_eq "$rc" "1" "retry agotado devuelve 1"
assert_eq "$(cat "$tmp/r.json")" "[]" "retry agotado deja array vacio"

# retry: stub devuelve JSON válido -> rc 0.
assert_exit 0 bash -c ". '$HERE/../consenso.sh'; CONSENSO_CODEX_CMD='$CONSENSO_CODEX_CMD' consenso_agent_with_retry codex p '$tmp/g.json'"

rm -rf "$tmp"
echo "OK test_validate_retry"
