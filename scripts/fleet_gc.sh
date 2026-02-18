#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUNS_ROOT="${FLEET_GC_ROOT:-$ROOT_DIR/state/runs}"
KEEP_LAST="${FLEET_GC_KEEP_LAST:-20}"
KEEP_HOURS="${FLEET_GC_KEEP_HOURS:-72}"
MAX_TOTAL_MB="${FLEET_GC_MAX_TOTAL_MB:-2048}"
DRY_RUN=0
VERBOSE=0
ACTIVE_HEARTBEAT_SEC="${FLEET_GC_ACTIVE_HEARTBEAT_SEC:-120}"

usage() {
  cat <<'USAGE'
Usage:
  scripts/fleet_gc.sh [options]

Options:
  --root DIR           root with pool-run directories (default: state/runs)
  --keep-last N        keep N newest run directories (default: 20)
  --keep-hours H       keep runs newer than H hours for TTL pruning (default: 72)
  --max-total-mb M     if total exceeds M, delete oldest (after keep-last) until under limit (default: 2048)
  --dry-run            only print actions, do not delete
  --verbose            print per-dir scan details
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) RUNS_ROOT="${2:-}"; shift 2 ;;
    --keep-last) KEEP_LAST="${2:-}"; shift 2 ;;
    --keep-hours) KEEP_HOURS="${2:-}"; shift 2 ;;
    --max-total-mb) MAX_TOTAL_MB="${2:-}"; shift 2 ;;
    --dry-run) DRY_RUN=1; shift ;;
    --verbose) VERBOSE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

for n in "$KEEP_LAST" "$KEEP_HOURS" "$MAX_TOTAL_MB" "$ACTIVE_HEARTBEAT_SEC"; do
  if [[ ! "$n" =~ ^[0-9]+$ ]]; then
    echo "numeric option expected, got: $n" >&2
    exit 2
  fi
done

if [[ ! -d "$RUNS_ROOT" ]]; then
  echo "GC_START root=${RUNS_ROOT} keep_last=${KEEP_LAST} keep_hours=${KEEP_HOURS} max_total_mb=${MAX_TOTAL_MB} dry_run=${DRY_RUN} verbose=${VERBOSE}"
  echo "GC_SUMMARY kept=0 deleted=0 freed_mb=0 total_mb_before=0 total_mb_after=0"
  exit 0
fi

dir_size_mb() {
  local d="$1"
  du -sm "$d" 2>/dev/null | awk '{print $1+0}' | head -n 1
}

has_run_signature() {
  local d="$1"
  [[ -f "$d/fleet.summary.json" || -f "$d/fleet_roster.jsonl" || -f "$d/fleet_registry.jsonl" ]]
}

is_active_run() {
  local d="$1"
  if [[ -f "$d/.pool.active" ]]; then
    return 0
  fi
  local hb="$d/fleet.heartbeat"
  if [[ -f "$hb" ]]; then
    local now_ts mtime age
    now_ts="$(date +%s)"
    mtime="$(stat -c '%Y' "$hb" 2>/dev/null || printf '0')"
    if [[ "$mtime" =~ ^[0-9]+$ ]] && (( mtime > 0 )); then
      if (( now_ts >= mtime )); then
        age=$((now_ts - mtime))
      else
        age=0
      fi
      if (( age < ACTIVE_HEARTBEAT_SEC )); then
        return 0
      fi
    fi
  fi
  return 1
}

echo "GC_START root=${RUNS_ROOT} keep_last=${KEEP_LAST} keep_hours=${KEEP_HOURS} max_total_mb=${MAX_TOTAL_MB} dry_run=${DRY_RUN} verbose=${VERBOSE}"

declare -a RUN_ROWS=()
while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  if ! has_run_signature "$dir"; then
    continue
  fi
  mtime="$(stat -c '%Y' "$dir" 2>/dev/null || printf '0')"
  [[ "$mtime" =~ ^[0-9]+$ ]] || mtime=0
  size_mb="$(dir_size_mb "$dir")"
  [[ "$size_mb" =~ ^[0-9]+$ ]] || size_mb=0
  RUN_ROWS+=("${mtime}|${dir}|${size_mb}")
done < <(find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)

if (( ${#RUN_ROWS[@]} == 0 )); then
  echo "GC_SUMMARY kept=0 deleted=0 freed_mb=0 total_mb_before=0 total_mb_after=0"
  exit 0
fi

mapfile -t SORTED_ROWS < <(printf '%s\n' "${RUN_ROWS[@]}" | sort -t'|' -k1,1nr)

declare -A KEEP_SET=()
declare -A ACTIVE_SET=()
declare -A SIZE_MB=()
declare -A MTIME=()
declare -a SORTED_DIRS=()
for row in "${SORTED_ROWS[@]}"; do
  IFS='|' read -r m d s <<<"$row"
  [[ -n "$d" ]] || continue
  MTIME["$d"]="$m"
  SIZE_MB["$d"]="$s"
  SORTED_DIRS+=("$d")
done

for i in "${!SORTED_DIRS[@]}"; do
  if (( i < KEEP_LAST )); then
    KEEP_SET["${SORTED_DIRS[$i]}"]="1"
  fi
done

total_before=0
for d in "${SORTED_DIRS[@]}"; do
  total_before=$((total_before + ${SIZE_MB["$d"]:-0}))
  if is_active_run "$d"; then
    ACTIVE_SET["$d"]="1"
  fi
done
total_current="$total_before"
freed_mb=0
deleted=0

now_ts="$(date +%s)"
ttl_cutoff=$((now_ts - KEEP_HOURS * 3600))

delete_dir() {
  local d="$1"
  local reason="$2"
  local sz="${SIZE_MB["$d"]:-0}"
  if [[ "$DRY_RUN" == "1" ]]; then
    echo "GC_DELETE dir=${d} reason=${reason} dry_run=1 size_mb=${sz}"
    return 0
  fi
  rm -rf "$d"
  echo "GC_DELETE dir=${d} reason=${reason} dry_run=0 size_mb=${sz}"
  deleted=$((deleted + 1))
  freed_mb=$((freed_mb + sz))
  total_current=$((total_current - sz))
  if (( total_current < 0 )); then
    total_current=0
  fi
}

for d in "${SORTED_DIRS[@]}"; do
  local_mtime="${MTIME["$d"]:-0}"
  if [[ "${ACTIVE_SET["$d"]:-}" == "1" ]]; then
    echo "GC_SKIP_ACTIVE dir=${d}"
    continue
  fi
  if [[ "${KEEP_SET["$d"]:-}" == "1" ]]; then
    [[ "$VERBOSE" == "1" ]] && echo "GC_KEEP dir=${d} reason=keep_last"
    continue
  fi
  if (( local_mtime >= ttl_cutoff )); then
    [[ "$VERBOSE" == "1" ]] && echo "GC_KEEP dir=${d} reason=ttl_window"
    continue
  fi
  delete_dir "$d" "ttl"
done

if (( total_current > MAX_TOTAL_MB )); then
  # Delete oldest first, but never remove active/keep-last.
  mapfile -t OLDEST_ROWS < <(printf '%s\n' "${RUN_ROWS[@]}" | sort -t'|' -k1,1n)
  for row in "${OLDEST_ROWS[@]}"; do
    IFS='|' read -r _ d _ <<<"$row"
    [[ -n "$d" ]] || continue
    if [[ ! -d "$d" ]]; then
      continue
    fi
    if [[ "${ACTIVE_SET["$d"]:-}" == "1" ]]; then
      echo "GC_SKIP_ACTIVE dir=${d}"
      continue
    fi
    if [[ "${KEEP_SET["$d"]:-}" == "1" ]]; then
      [[ "$VERBOSE" == "1" ]] && echo "GC_KEEP dir=${d} reason=keep_last"
      continue
    fi
    if (( total_current <= MAX_TOTAL_MB )); then
      break
    fi
    delete_dir "$d" "max_total"
  done
fi

if [[ "$DRY_RUN" == "1" ]]; then
  # In dry-run, recompute projected values from actions.
  total_after=$((total_before - freed_mb))
  if (( total_after < 0 )); then
    total_after=0
  fi
else
  total_after=0
  while IFS= read -r dir; do
    [[ -n "$dir" ]] || continue
    if has_run_signature "$dir"; then
      sz="$(dir_size_mb "$dir")"
      [[ "$sz" =~ ^[0-9]+$ ]] || sz=0
      total_after=$((total_after + sz))
    fi
  done < <(find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)
fi

kept=0
while IFS= read -r dir; do
  [[ -n "$dir" ]] || continue
  if has_run_signature "$dir"; then
    kept=$((kept + 1))
  fi
done < <(find "$RUNS_ROOT" -mindepth 1 -maxdepth 1 -type d | sort)

echo "GC_SUMMARY kept=${kept} deleted=${deleted} freed_mb=${freed_mb} total_mb_before=${total_before} total_mb_after=${total_after}"
