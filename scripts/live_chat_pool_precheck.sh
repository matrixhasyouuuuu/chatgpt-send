#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHAT_POOL_MANAGER="${ROOT_DIR}/scripts/chat_pool_manage.sh"

CHAT_POOL_FILE=""
CONCURRENCY=""
CHATGPT_SEND_BIN="${ROOT_DIR}/bin/chatgpt_send"
TRANSPORT="${CHATGPT_SEND_TRANSPORT:-cdp}"
OUT_JSONL=""
OUT_SUMMARY_JSON=""
FAIL_FAST=1

usage() {
  cat <<'USAGE'
Usage:
  scripts/live_chat_pool_precheck.sh --chat-pool-file FILE --concurrency N [options]

Options:
  --chat-pool-file FILE          required
  --concurrency N                required (checks first N URLs)
  --chatgpt-send PATH            default: bin/chatgpt_send
  --transport cdp|mock           default: $CHATGPT_SEND_TRANSPORT or cdp
  --out-jsonl PATH               default: state/precheck/chat_pool_precheck_<ts>.jsonl
  --out-summary-json PATH        default: state/precheck/chat_pool_precheck_<ts>.summary.json
  --fail-fast 0|1                default: 1
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat-pool-file) CHAT_POOL_FILE="${2:-}"; shift 2 ;;
    --concurrency) CONCURRENCY="${2:-}"; shift 2 ;;
    --chatgpt-send) CHATGPT_SEND_BIN="${2:-}"; shift 2 ;;
    --transport) TRANSPORT="${2:-}"; shift 2 ;;
    --out-jsonl) OUT_JSONL="${2:-}"; shift 2 ;;
    --out-summary-json) OUT_SUMMARY_JSON="${2:-}"; shift 2 ;;
    --fail-fast) FAIL_FAST="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$CHAT_POOL_FILE" || -z "$CONCURRENCY" ]]; then
  usage >&2
  exit 2
fi
if [[ ! "$CONCURRENCY" =~ ^[0-9]+$ ]] || (( CONCURRENCY < 1 )); then
  echo "invalid --concurrency: $CONCURRENCY" >&2
  exit 2
fi
if [[ ! "$FAIL_FAST" =~ ^[01]$ ]]; then
  echo "invalid --fail-fast: $FAIL_FAST (expected 0 or 1)" >&2
  exit 2
fi
if [[ ! "$TRANSPORT" =~ ^(cdp|mock)$ ]]; then
  echo "invalid --transport: $TRANSPORT" >&2
  exit 2
fi
if [[ ! -x "$CHATGPT_SEND_BIN" ]]; then
  echo "chatgpt_send not executable: $CHATGPT_SEND_BIN" >&2
  exit 2
fi
if [[ ! -x "$CHAT_POOL_MANAGER" ]]; then
  echo "chat pool manager not executable: $CHAT_POOL_MANAGER" >&2
  exit 2
fi

stamp="$(date +%Y%m%d-%H%M%S)-$RANDOM"
if [[ -z "$OUT_JSONL" ]]; then
  OUT_JSONL="$ROOT_DIR/state/precheck/chat_pool_precheck_${stamp}.jsonl"
fi
if [[ -z "$OUT_SUMMARY_JSON" ]]; then
  OUT_SUMMARY_JSON="$ROOT_DIR/state/precheck/chat_pool_precheck_${stamp}.summary.json"
fi
mkdir -p "$(dirname "$OUT_JSONL")" "$(dirname "$OUT_SUMMARY_JSON")"
: >"$OUT_JSONL"

set +e
validate_out="$("$CHAT_POOL_MANAGER" validate --chat-pool-file "$CHAT_POOL_FILE" --min "$CONCURRENCY" 2>&1)"
validate_rc=$?
set -e
echo "$validate_out"
if [[ "$validate_rc" != "0" ]]; then
  echo "CHAT_POOL_PRECHECK_FAIL total=0 fail=1 code_top=E_CHAT_POOL_INVALID" >&2
  exit 16
fi

mapfile -t urls < <(sed -e 's/\r$//' "$CHAT_POOL_FILE" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d' | head -n "$CONCURRENCY")
if (( ${#urls[@]} < CONCURRENCY )); then
  echo "CHAT_POOL_PRECHECK_FAIL total=${#urls[@]} fail=1 code_top=E_CHAT_POOL_NOT_ENOUGH" >&2
  exit 16
fi

idx=0
for url in "${urls[@]}"; do
  idx=$((idx + 1))
  set +e
  probe_out="$(
    CHATGPT_SEND_TRANSPORT="$TRANSPORT" \
    CHATGPT_SEND_SKIP_STATE_WRITE=1 \
    "$CHATGPT_SEND_BIN" --probe-chat-url "$url" --no-state-write 2>&1
  )"
  rc=$?
  set -e

  ok=0
  code="OK"
  if [[ "$rc" == "0" ]]; then
    ok=1
  else
    code="$(printf '%s\n' "$probe_out" | sed -n 's/^E_PROBE_CHAT_FAILED .*code=\([^[:space:]]*\).*/\1/p' | tail -n 1)"
    if [[ -z "${code:-}" ]]; then
      code="E_PROBE_CHAT_FAILED"
    fi
  fi

  stdout_tail="$(printf '%s\n' "$probe_out" | tail -n 8)"
  printf '%s' "$stdout_tail" | python3 - "$OUT_JSONL" "$idx" "$url" "$ok" "$rc" "$code" <<'PY'
import json
import pathlib
import sys
import time

path = pathlib.Path(sys.argv[1])
row = {
    "ts_ms": int(time.time() * 1000),
    "index": int(sys.argv[2]),
    "url": sys.argv[3],
    "ok": int(sys.argv[4]),
    "rc": int(sys.argv[5]),
    "code": sys.argv[6],
    "stdout_tail": sys.stdin.read(),
}
with path.open("a", encoding="utf-8") as f:
    f.write(json.dumps(row, ensure_ascii=False) + "\n")
PY

  if [[ "$ok" != "1" ]] && [[ "$FAIL_FAST" == "1" ]]; then
    break
  fi
done

summary_emit="$(
  python3 - "$OUT_JSONL" "$OUT_SUMMARY_JSON" "$CHAT_POOL_FILE" "$TRANSPORT" "$CONCURRENCY" <<'PY'
import collections
import json
import pathlib
import sys
import time

jsonl_path = pathlib.Path(sys.argv[1])
summary_path = pathlib.Path(sys.argv[2])
pool_file = sys.argv[3]
transport = sys.argv[4]
expected = int(sys.argv[5])

rows = []
for line in jsonl_path.read_text(encoding="utf-8", errors="replace").splitlines():
    line = line.strip()
    if not line:
        continue
    try:
        rows.append(json.loads(line))
    except Exception:
        continue

total = len(rows)
ok = sum(1 for row in rows if int(row.get("ok") or 0) == 1)
fail = total - ok
codes = collections.Counter()
for row in rows:
    if int(row.get("ok") or 0) != 1:
        code = str(row.get("code") or "E_PROBE_CHAT_FAILED").strip() or "E_PROBE_CHAT_FAILED"
        codes[code] += 1

top_code = "none"
if codes:
    top_code = sorted(codes.items(), key=lambda kv: (-kv[1], kv[0]))[0][0]

summary = {
    "ts_ms": int(time.time() * 1000),
    "chat_pool_file": pool_file,
    "transport": transport,
    "expected_concurrency": expected,
    "total": total,
    "ok": ok,
    "fail": fail,
    "fail_codes": dict(codes),
    "top_code": top_code,
    "out_jsonl": str(jsonl_path),
}
summary_path.write_text(json.dumps(summary, ensure_ascii=False, sort_keys=True, indent=2) + "\n", encoding="utf-8")

print(f"TOTAL={total}")
print(f"OK={ok}")
print(f"FAIL={fail}")
print(f"TOP_CODE={top_code}")
PY
)"

total_checked="$(printf '%s\n' "$summary_emit" | sed -n 's/^TOTAL=//p' | tail -n 1)"
ok_count="$(printf '%s\n' "$summary_emit" | sed -n 's/^OK=//p' | tail -n 1)"
fail_count="$(printf '%s\n' "$summary_emit" | sed -n 's/^FAIL=//p' | tail -n 1)"
top_code="$(printf '%s\n' "$summary_emit" | sed -n 's/^TOP_CODE=//p' | tail -n 1)"
[[ "$total_checked" =~ ^[0-9]+$ ]] || total_checked=0
[[ "$ok_count" =~ ^[0-9]+$ ]] || ok_count=0
[[ "$fail_count" =~ ^[0-9]+$ ]] || fail_count=0
[[ -n "${top_code:-}" ]] || top_code="none"

echo "CHAT_POOL_PRECHECK_JSONL=$OUT_JSONL"
echo "CHAT_POOL_PRECHECK_SUMMARY_JSON=$OUT_SUMMARY_JSON"

if (( fail_count == 0 )) && (( total_checked >= CONCURRENCY )); then
  echo "CHAT_POOL_PRECHECK_OK total=$total_checked ok=$ok_count"
  exit 0
fi

echo "CHAT_POOL_PRECHECK_FAIL total=$total_checked fail=$fail_count code_top=$top_code"
exit 16
