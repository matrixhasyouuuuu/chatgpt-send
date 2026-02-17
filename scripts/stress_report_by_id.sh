#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ID="${1:-}"

usage() {
  cat <<'EOF'
Usage:
  scripts/stress_report_by_id.sh <TEST_ID>
EOF
}

if [[ -z "${TEST_ID}" ]]; then
  usage >&2
  exit 2
fi

OUTDIR="${TMPDIR:-/tmp}/chatgpt_send_stress/${TEST_ID}"
if [[ ! -d "$OUTDIR" ]]; then
  echo "OUTDIR not found: $OUTDIR" >&2
  exit 2
fi

shopt -s nullglob
logs=( "$OUTDIR"/iter_*.log )
markers=( "$OUTDIR"/iter_*.markers )
shopt -u nullglob

echo "REPORT_START test_id=${TEST_ID} outdir=${OUTDIR} logs=${#logs[@]} markers=${#markers[@]}"

if [[ -f "$OUTDIR/harness_end.txt" ]]; then
  cat "$OUTDIR/harness_end.txt"
else
  echo "W_REPORT_NO_HARNESS_END outdir=${OUTDIR}"
fi

if [[ -f "$OUTDIR/stress_summary.txt" ]]; then
  cat "$OUTDIR/stress_summary.txt"
else
  echo "W_REPORT_NO_STRESS_SUMMARY outdir=${OUTDIR}"
fi

if [[ -f "$OUTDIR/score.txt" ]]; then
  cat "$OUTDIR/score.txt"
elif [[ ${#markers[@]} -gt 0 ]]; then
  "$ROOT/scripts/score_stress_run.sh" "${markers[@]}"
elif [[ ${#logs[@]} -gt 0 ]]; then
  "$ROOT/scripts/score_stress_run.sh" "${logs[@]}"
else
  echo "W_REPORT_NO_LOGS outdir=${OUTDIR}"
fi

if [[ ${#logs[@]} -eq 0 ]] && [[ ${#markers[@]} -eq 0 ]]; then
  exit 0
fi

if [[ ${#markers[@]} -gt 0 ]]; then
  report_sources=( "${markers[@]}" )
else
  report_sources=( "${logs[@]}" )
fi

echo "ITER_RESULT_TAIL"
rg --no-filename '^(ITER_RESULT|RUN_END)' "${report_sources[@]}" | tail -n 80 || true

echo "RED_FLAGS_TAIL"
rg --no-filename '^(E_[A-Z0-9_]+|RUN_END .*result=FAIL|ITER_RESULT outcome=FAIL|ITER_RESULT outcome=BLOCK)' "${report_sources[@]}" | tail -n 120 || true

run_id="$(rg --no-filename -o 'run-[0-9]+-[0-9]+' "${report_sources[@]}" | tail -n 1 || true)"
if [[ -n "${run_id:-}" ]]; then
  evidence_dir="$ROOT/state/runs/${run_id}/evidence"
  if [[ -d "$evidence_dir" ]]; then
    echo "EVIDENCE_SNAPSHOT run_id=${run_id} dir=${evidence_dir}"
    ls -1 "$evidence_dir" | sed -n '1,40p'
  else
    echo "EVIDENCE_MISSING run_id=${run_id} dir=${evidence_dir}"
  fi
fi
