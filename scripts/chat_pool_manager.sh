#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHATGPT_SEND_BIN="$ROOT_DIR/bin/chatgpt_send"

usage() {
  cat <<'USAGE'
Usage:
  scripts/chat_pool_manager.sh <command> [options]

Commands:
  init   --size N --out FILE
  add    --url URL --file FILE
  check  --file FILE [--size N]
  probe  --file FILE [--transport cdp|mock] [--chatgpt-send-path PATH] [--no-send]

Notes:
  - URLs must be in format: https://chatgpt.com/c/<id>
  - probe is opt-in live action; requires RUN_LIVE_CDP_E2E=1 for transport=cdp
USAGE
}

is_chat_url() {
  local url="$1"
  [[ "$url" =~ ^https://chatgpt\.com/c/[A-Za-z0-9-]+$ ]]
}

read_pool_urls() {
  local file="$1"
  sed -e 's/\r$//' "$file" | sed -e '/^[[:space:]]*#/d' -e '/^[[:space:]]*$/d'
}

cmd="${1:-}"
if [[ -z "$cmd" ]]; then
  usage >&2
  exit 2
fi
shift || true

case "$cmd" in
  init)
    size=""
    out_file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --size) size="${2:-}"; shift 2 ;;
        --out) out_file="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg for init: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$size" || -z "$out_file" ]]; then
      echo "init requires --size and --out" >&2
      exit 2
    fi
    if [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1 )); then
      echo "invalid --size: $size" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$out_file")"
    {
      echo "# chat pool file"
      echo "# one URL per line: https://chatgpt.com/c/<id>"
      echo "# target size: $size"
      for ((i=1; i<=size; i++)); do
        echo "# slot-$i: https://chatgpt.com/c/<id>"
      done
    } >"$out_file"
    echo "POOL_INIT_OK=1"
    echo "POOL_FILE=$out_file"
    echo "POOL_TARGET_SIZE=$size"
    ;;

  add)
    url=""
    file=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --url) url="${2:-}"; shift 2 ;;
        --file) file="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg for add: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$url" || -z "$file" ]]; then
      echo "add requires --url and --file" >&2
      exit 2
    fi
    if ! is_chat_url "$url"; then
      echo "invalid chat URL: $url" >&2
      exit 2
    fi
    mkdir -p "$(dirname "$file")"
    touch "$file"
    if read_pool_urls "$file" | rg -x --fixed-strings "$url" >/dev/null 2>&1; then
      echo "POOL_ADD_OK=1"
      echo "POOL_ADD_DUP=1"
      echo "POOL_FILE=$file"
      echo "POOL_URL=$url"
      exit 0
    fi
    printf '%s\n' "$url" >>"$file"
    echo "POOL_ADD_OK=1"
    echo "POOL_ADD_DUP=0"
    echo "POOL_FILE=$file"
    echo "POOL_URL=$url"
    ;;

  check)
    file=""
    size=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) file="${2:-}"; shift 2 ;;
        --size) size="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg for check: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$file" ]]; then
      echo "check requires --file" >&2
      exit 2
    fi
    if [[ ! -f "$file" ]]; then
      echo "pool file not found: $file" >&2
      exit 2
    fi
    if [[ -n "$size" ]] && { [[ ! "$size" =~ ^[0-9]+$ ]] || (( size < 1 )); }; then
      echo "invalid --size: $size" >&2
      exit 2
    fi

    mapfile -t urls < <(read_pool_urls "$file")
    total=${#urls[@]}
    dup_count=0
    bad_count=0
    valid_count=0
    declare -A seen=()
    for u in "${urls[@]}"; do
      if ! is_chat_url "$u"; then
        bad_count=$((bad_count + 1))
      else
        valid_count=$((valid_count + 1))
      fi
      if [[ -n "${seen[$u]:-}" ]]; then
        dup_count=$((dup_count + 1))
      else
        seen["$u"]=1
      fi
    done

    check_ok=1
    if (( bad_count > 0 || dup_count > 0 || total == 0 )); then
      check_ok=0
    fi
    if [[ -n "$size" ]] && (( total < size )); then
      check_ok=0
    fi

    echo "POOL_CHECK_OK=$check_ok"
    echo "POOL_FILE=$file"
    echo "POOL_TOTAL=$total"
    echo "POOL_VALID_COUNT=$valid_count"
    echo "POOL_BAD_COUNT=$bad_count"
    echo "POOL_DUP_COUNT=$dup_count"
    if [[ -n "$size" ]]; then
      echo "POOL_TARGET_SIZE=$size"
    fi
    if [[ "$check_ok" != "1" ]]; then
      exit 1
    fi
    ;;

  probe)
    file=""
    transport="cdp"
    no_send=0
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --file) file="${2:-}"; shift 2 ;;
        --transport) transport="${2:-}"; shift 2 ;;
        --chatgpt-send-path) CHATGPT_SEND_BIN="${2:-}"; shift 2 ;;
        --no-send) no_send=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg for probe: $1" >&2; exit 2 ;;
      esac
    done
    if [[ -z "$file" ]]; then
      echo "probe requires --file" >&2
      exit 2
    fi
    if [[ ! -f "$file" ]]; then
      echo "pool file not found: $file" >&2
      exit 2
    fi
    if [[ ! "$transport" =~ ^(cdp|mock)$ ]]; then
      echo "invalid --transport: $transport" >&2
      exit 2
    fi
    if [[ ! -x "$CHATGPT_SEND_BIN" ]]; then
      echo "chatgpt_send not executable: $CHATGPT_SEND_BIN" >&2
      exit 2
    fi
    if [[ "$transport" == "cdp" ]] && [[ "${RUN_LIVE_CDP_E2E:-0}" != "1" ]]; then
      echo "SKIP_RUN_LIVE_CDP_E2E"
      exit 0
    fi

    mapfile -t urls < <(read_pool_urls "$file")
    if (( ${#urls[@]} == 0 )); then
      echo "POOL_PROBE_OK=0"
      echo "POOL_PROBE_REASON=empty_pool"
      exit 1
    fi
    for u in "${urls[@]}"; do
      if ! is_chat_url "$u"; then
        echo "POOL_PROBE_OK=0"
        echo "POOL_PROBE_REASON=invalid_url"
        echo "POOL_BAD_URL=$u"
        exit 1
      fi
    done

    probe_run_id="chatpool-$(date +%Y%m%d-%H%M%S)-$RANDOM"
    probe_dir="$ROOT_DIR/state/runs/$probe_run_id"
    mkdir -p "$probe_dir"
    report_jsonl="$probe_dir/report.jsonl"
    report_csv="$probe_dir/report.csv"
    printf 'index,expected_url,observed_url,status\n' >"$report_csv"
    : >"$report_jsonl"

    ok_count=0
    mismatch_count=0
    fail_count=0
    idx=0
    for expected_url in "${urls[@]}"; do
      idx=$((idx + 1))
      observed_url=""
      status="OK"
      show_out=""
      run_env=("CHATGPT_SEND_TRANSPORT=$transport")
      if [[ "$transport" == "mock" ]]; then
        run_env+=("CHATGPT_SEND_MOCK_CHAT_URL=$expected_url")
      fi
      if [[ "$no_send" == "1" ]]; then
        # no-send mode: only route/open/show checks, no prompt dispatch.
        env "${run_env[@]}" "$CHATGPT_SEND_BIN" --chatgpt-url "$expected_url" --open-browser >/dev/null 2>&1 || true
      fi
      set +e
      show_out="$(env "${run_env[@]}" "$CHATGPT_SEND_BIN" --chatgpt-url "$expected_url" --show-chatgpt-url 2>&1)"
      rc=$?
      set -e
      observed_url="$(printf '%s\n' "$show_out" | tail -n 1 | tr -d '\r' | xargs || true)"
      if [[ "$rc" != "0" ]]; then
        status="ERROR"
        fail_count=$((fail_count + 1))
      elif [[ "$observed_url" != "$expected_url" ]]; then
        status="MISMATCH"
        mismatch_count=$((mismatch_count + 1))
      else
        ok_count=$((ok_count + 1))
      fi

      python3 - "$idx" "$expected_url" "$observed_url" "$status" <<'PY' >>"$report_jsonl"
import json, sys
print(json.dumps({
    "index": int(sys.argv[1]),
    "expected_url": sys.argv[2],
    "observed_url": sys.argv[3],
    "status": sys.argv[4],
}, ensure_ascii=False))
PY
      python3 - "$idx" "$expected_url" "$observed_url" "$status" <<'PY' >>"$report_csv"
import csv, sys
w = csv.writer(sys.stdout, lineterminator="\n")
w.writerow(sys.argv[1:])
PY
    done

    probe_ok=1
    if (( mismatch_count > 0 || fail_count > 0 )); then
      probe_ok=0
    fi
    echo "POOL_PROBE_OK=$probe_ok"
    echo "POOL_PROBE_TOTAL=${#urls[@]}"
    echo "POOL_PROBE_OK_COUNT=$ok_count"
    echo "POOL_PROBE_MISMATCH_COUNT=$mismatch_count"
    echo "POOL_PROBE_FAIL_COUNT=$fail_count"
    echo "POOL_PROBE_REPORT_JSONL=$report_jsonl"
    echo "POOL_PROBE_REPORT_CSV=$report_csv"
    if [[ "$probe_ok" != "1" ]]; then
      exit 1
    fi
    ;;

  -h|--help)
    usage
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    usage >&2
    exit 2
    ;;
esac
