#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCORE="$ROOT/scripts/score_stress_run.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

outdir="$tmp/out"
mkdir -p "$outdir"

cat >"$outdir/iter_1.log" <<'EOF'
assistant says: E_SEND_NOT_CONFIRMED (this is not marker)
RUN_END iter=1 scenario=S01 result=PASS run_status=0 assert_status=0
EOF

cat >"$outdir/iter_1.markers" <<'EOF'
RUN_END iter=1 scenario=S01 result=PASS run_status=0 assert_status=0
ITER_RESULT outcome=PASS reason=ok send=1 reuse=0 evidence=0 run_id=run-x
EOF

out="$("$SCORE" "$outdir"/iter_1.markers 2>&1)"
echo "$out" | rg -q -- 'unexpected_send_unconfirmed=0'
echo "$out" | rg -q -- 'fail_without_evidence=0'
echo "$out" | rg -q -- 'SCORE=100'

pushd "$outdir" >/dev/null
out_default="$("$SCORE" 2>&1)"
popd >/dev/null
echo "$out_default" | rg -q -- 'SCORE=100'

echo "OK"
