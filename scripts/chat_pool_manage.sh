#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEFAULT_STATE_CHATS="$ROOT_DIR/state/chats.json"

usage() {
  cat <<'USAGE'
Usage:
  scripts/chat_pool_manage.sh validate --chat-pool-file FILE [--min N]
  scripts/chat_pool_manage.sh extract  --out FILE [--state-chats FILE] [--count N] [--exclude-url URL]

Commands:
  validate  Validate pool file (URL format, uniqueness, optional minimum size).
  extract   Extract unique chat URLs from state json using tolerant regex scan.
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
  validate)
    chat_pool_file=""
    min_count=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --chat-pool-file) chat_pool_file="${2:-}"; shift 2 ;;
        --min) min_count="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg for validate: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    if [[ -z "$chat_pool_file" ]]; then
      echo "validate requires --chat-pool-file" >&2
      exit 2
    fi
    if [[ ! -f "$chat_pool_file" ]]; then
      echo "CHAT_POOL_OK=0"
      echo "CHAT_POOL_FILE=$chat_pool_file"
      echo "E_CHAT_POOL_INVALID reason=file_not_found"
      exit 2
    fi
    if [[ -n "$min_count" ]] && { [[ ! "$min_count" =~ ^[0-9]+$ ]] || (( min_count < 1 )); }; then
      echo "validate: invalid --min: $min_count" >&2
      exit 2
    fi

    mapfile -t urls < <(read_pool_urls "$chat_pool_file")
    total=${#urls[@]}
    invalid_count=0
    dup_count=0
    declare -A seen=()
    for u in "${urls[@]}"; do
      if ! is_chat_url "$u"; then
        invalid_count=$((invalid_count + 1))
      fi
      if [[ -n "${seen[$u]:-}" ]]; then
        dup_count=$((dup_count + 1))
      else
        seen["$u"]=1
      fi
    done

    reason="ok"
    ok=1
    if (( total == 0 )); then
      ok=0
      reason="empty"
    elif (( invalid_count > 0 )); then
      ok=0
      reason="invalid_url"
    elif (( dup_count > 0 )); then
      ok=0
      reason="duplicate"
    elif [[ -n "$min_count" ]] && (( total < min_count )); then
      ok=0
      reason="below_min"
    fi

    echo "CHAT_POOL_OK=$ok"
    echo "CHAT_POOL_FILE=$chat_pool_file"
    echo "CHAT_POOL_COUNT=$total"
    echo "CHAT_POOL_INVALID_COUNT=$invalid_count"
    echo "CHAT_POOL_DUP_COUNT=$dup_count"
    if [[ -n "$min_count" ]]; then
      echo "CHAT_POOL_MIN_REQUIRED=$min_count"
    fi
    if [[ "$ok" != "1" ]]; then
      echo "E_CHAT_POOL_INVALID reason=$reason"
      exit 2
    fi
    ;;

  extract)
    state_chats="$DEFAULT_STATE_CHATS"
    out_file=""
    count=10
    exclude_url=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --state-chats) state_chats="${2:-}"; shift 2 ;;
        --out) out_file="${2:-}"; shift 2 ;;
        --count) count="${2:-}"; shift 2 ;;
        --exclude-url) exclude_url="${2:-}"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown arg for extract: $1" >&2; usage >&2; exit 2 ;;
      esac
    done

    if [[ -z "$out_file" ]]; then
      echo "extract requires --out" >&2
      exit 2
    fi
    if [[ ! "$count" =~ ^[0-9]+$ ]] || (( count < 1 )); then
      echo "extract: invalid --count: $count" >&2
      exit 2
    fi
    if [[ -n "$exclude_url" ]] && ! is_chat_url "$exclude_url"; then
      echo "extract: invalid --exclude-url: $exclude_url" >&2
      exit 2
    fi

    if [[ ! -f "$state_chats" ]]; then
      mkdir -p "$(dirname "$out_file")"
      {
        echo "# chat pool extracted from state"
        echo "# source: $state_chats (missing)"
        echo "# generated_at: $(date -Iseconds)"
      } >"$out_file"
      echo "CHAT_POOL_WRITTEN=0"
      echo "CHAT_POOL_FILE=$out_file"
      echo "CHAT_POOL_SOURCE=$state_chats"
      echo "CHAT_POOL_REQUESTED=$count"
      echo "CHAT_POOL_FOUND=0"
      echo "E_CHAT_POOL_NOT_ENOUGH found=0 need=$count source=$state_chats"
      exit 11
    fi

    mapfile -t extracted_urls < <(python3 - "$state_chats" "$exclude_url" <<'PY'
import pathlib
import re
import sys

state_path = pathlib.Path(sys.argv[1])
exclude = sys.argv[2].strip()
text = state_path.read_bytes().decode("utf-8", errors="ignore")
pattern = re.compile(r"https://chatgpt\.com/c/[A-Za-z0-9-]+")

seen = set()
out = []
for match in pattern.finditer(text):
    url = match.group(0)
    if exclude and url == exclude:
        continue
    if url in seen:
        continue
    seen.add(url)
    out.append(url)

for item in out:
    print(item)
PY
)

    found=${#extracted_urls[@]}
    write_count=$count
    if (( found < write_count )); then
      write_count=$found
    fi

    mkdir -p "$(dirname "$out_file")"
    {
      echo "# chat pool extracted from state"
      echo "# source: $state_chats"
      echo "# generated_at: $(date -Iseconds)"
      if [[ -n "$exclude_url" ]]; then
        echo "# exclude_url: $exclude_url"
      fi
      for ((i=0; i<write_count; i++)); do
        echo "${extracted_urls[$i]}"
      done
    } >"$out_file"

    echo "CHAT_POOL_WRITTEN=$write_count"
    echo "CHAT_POOL_FILE=$out_file"
    echo "CHAT_POOL_SOURCE=$state_chats"
    echo "CHAT_POOL_REQUESTED=$count"
    echo "CHAT_POOL_FOUND=$found"
    if (( found < count )); then
      echo "E_CHAT_POOL_NOT_ENOUGH found=$found need=$count source=$state_chats"
      exit 11
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
