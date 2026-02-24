#!/usr/bin/env bash
set -euo pipefail

POOL_RUN_DIR=""
FLEET_SUMMARY_JSON=""
SUMMARY_JSONL=""
OUT_MD=""
OUT_JSON=""
MAX_LAST_LINES=80
INCLUDE_LOGS=0
GATE_STATUS=""
GATE_REASON=""

usage() {
  cat <<'USAGE'
Usage:
  scripts/pool_report.sh --pool-run-dir DIR [options]

Required:
  --pool-run-dir DIR

Options:
  --fleet-summary-json FILE   default: <pool-run-dir>/fleet.summary.json
  --summary-jsonl FILE        default: <pool-run-dir>/summary.jsonl
  --out-md FILE               default: <pool-run-dir>/pool_report.md
  --out-json FILE             default: <pool-run-dir>/pool_report.json
  --max-last-lines N          default: 80
  --include-logs 0|1          default: 0
  --gate-status VALUE         optional
  --gate-reason VALUE         optional
  -h, --help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --pool-run-dir) POOL_RUN_DIR="${2:-}"; shift 2 ;;
    --fleet-summary-json) FLEET_SUMMARY_JSON="${2:-}"; shift 2 ;;
    --summary-jsonl) SUMMARY_JSONL="${2:-}"; shift 2 ;;
    --out-md) OUT_MD="${2:-}"; shift 2 ;;
    --out-json) OUT_JSON="${2:-}"; shift 2 ;;
    --max-last-lines) MAX_LAST_LINES="${2:-}"; shift 2 ;;
    --include-logs) INCLUDE_LOGS="${2:-}"; shift 2 ;;
    --gate-status) GATE_STATUS="${2:-}"; shift 2 ;;
    --gate-reason) GATE_REASON="${2:-}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if [[ -z "$POOL_RUN_DIR" ]]; then
  usage >&2
  exit 2
fi
if [[ -z "$FLEET_SUMMARY_JSON" ]]; then
  FLEET_SUMMARY_JSON="$POOL_RUN_DIR/fleet.summary.json"
fi
if [[ -z "$SUMMARY_JSONL" ]]; then
  SUMMARY_JSONL="$POOL_RUN_DIR/summary.jsonl"
fi
if [[ -z "$OUT_MD" ]]; then
  OUT_MD="$POOL_RUN_DIR/pool_report.md"
fi
if [[ -z "$OUT_JSON" ]]; then
  OUT_JSON="$POOL_RUN_DIR/pool_report.json"
fi

if [[ ! "$MAX_LAST_LINES" =~ ^[0-9]+$ ]]; then
  echo "--max-last-lines must be numeric" >&2
  exit 2
fi
if [[ ! "$INCLUDE_LOGS" =~ ^[01]$ ]]; then
  echo "--include-logs must be 0 or 1" >&2
  exit 2
fi

mkdir -p "$(dirname "$OUT_MD")"
mkdir -p "$(dirname "$OUT_JSON")"

python3 - "$POOL_RUN_DIR" "$FLEET_SUMMARY_JSON" "$SUMMARY_JSONL" "$OUT_MD" "$OUT_JSON" "$MAX_LAST_LINES" "$INCLUDE_LOGS" "$GATE_STATUS" "$GATE_REASON" <<'PY'
import datetime as dt
import json
import pathlib
import sys
from typing import Any, Dict, List


def read_json(path: pathlib.Path, default: Any) -> Any:
    if not path.exists():
        return default
    try:
        return json.loads(path.read_text(encoding="utf-8", errors="replace"))
    except Exception:
        return default


def read_jsonl(path: pathlib.Path) -> List[Dict[str, Any]]:
    if not path.exists():
        return []
    rows: List[Dict[str, Any]] = []
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = raw.strip()
        if not line:
            continue
        try:
            obj = json.loads(line)
        except Exception:
            continue
        if isinstance(obj, dict):
            rows.append(obj)
    return rows


def as_int(v: Any, default: int = 0) -> int:
    if isinstance(v, bool):
        return int(v)
    if isinstance(v, int):
        return v
    if isinstance(v, str) and v.strip().lstrip("-").isdigit():
        return int(v.strip())
    return default


def short_text(s: str, limit: int = 180) -> str:
    t = " ".join((s or "").replace("\r", " ").split())
    return t[:limit]


def read_text(path: pathlib.Path) -> str:
    if not path.exists():
        return ""
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except Exception:
        return ""


def md_escape(s: str) -> str:
    return (s or "").replace("|", "\\|")


def tail_lines(path: pathlib.Path, n: int) -> List[str]:
    if n <= 0:
        return []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except Exception:
        return []
    return lines[-n:]


def preview_from_files(last_file: pathlib.Path, result_json: pathlib.Path) -> str:
    if last_file.exists():
        try:
            lines = last_file.read_text(encoding="utf-8", errors="replace").splitlines()
            for line in reversed(lines):
                if "CHILD_RESULT:" in line:
                    return short_text(line)
            for line in reversed(lines):
                if line.strip():
                    return short_text(line.strip())
            return "(empty last file)"
        except Exception:
            return "(last file unreadable)"
    if result_json.exists():
        try:
            obj = json.loads(result_json.read_text(encoding="utf-8", errors="replace"))
            status = str(obj.get("status", ""))
            exit_code = obj.get("exit_code", "")
            return short_text(f"result_json status={status} exit_code={exit_code}")
        except Exception:
            return "(result json unreadable)"
    return "(no last file)"


pool_run_dir = pathlib.Path(sys.argv[1])
fleet_summary_path = pathlib.Path(sys.argv[2])
summary_jsonl_path = pathlib.Path(sys.argv[3])
out_md_path = pathlib.Path(sys.argv[4])
out_json_path = pathlib.Path(sys.argv[5])
max_last_lines = as_int(sys.argv[6], 80)
include_logs = sys.argv[7] == "1"
gate_status = (sys.argv[8] or "").strip()
gate_reason = (sys.argv[9] or "").strip()
early_abort_flag_path = pool_run_dir / ".early_abort"
early_abort_reason_path = pool_run_dir / ".early_abort.reason"
early_abort_ids_path = pool_run_dir / ".early_abort.ids"
early_abort_meta_path = pool_run_dir / "early_abort.meta.json"
early_abort_reason = short_text(read_text(early_abort_reason_path), 400)
early_abort_meta = read_json(early_abort_meta_path, {})
early_abort_ids: List[Dict[str, str]] = []
if early_abort_ids_path.exists():
    for raw in read_text(early_abort_ids_path).splitlines():
        line = raw.strip()
        if not line:
            continue
        parts = line.split("\t")
        agent_id = parts[0].strip() if len(parts) >= 1 else ""
        run_id = parts[1].strip() if len(parts) >= 2 else ""
        state_class = parts[2].strip() if len(parts) >= 3 else ""
        early_abort_ids.append(
            {"agent_id": agent_id, "run_id": run_id, "state_class": state_class}
        )
early_abort_blame_agents = {
    row["agent_id"] for row in early_abort_ids if row.get("agent_id", "")
}
early_abort_triggered = int(
    early_abort_flag_path.exists()
    or bool(early_abort_reason)
    or bool(early_abort_ids)
    or bool(early_abort_meta)
)

fleet = read_json(fleet_summary_path, {})
fleet_agents = fleet.get("agents") if isinstance(fleet, dict) else []
if not isinstance(fleet_agents, list):
    fleet_agents = []

summary_rows = read_jsonl(summary_jsonl_path)
latest_by_run: Dict[str, Dict[str, Any]] = {}
for row in summary_rows:
    run_id = str(row.get("child_run_id", "")).strip()
    if not run_id:
        continue
    attempt = as_int(row.get("attempt"), 0)
    prev = latest_by_run.get(run_id)
    if prev is None or attempt >= as_int(prev.get("attempt"), 0):
        latest_by_run[run_id] = row

rows: List[Dict[str, Any]] = []
for idx, agent in enumerate(fleet_agents, start=1):
    run_id = str(agent.get("run_id", "") or "")
    summary_row = latest_by_run.get(run_id, {})
    attempt = summary_row.get("attempt")
    duration_sec = summary_row.get("duration_sec")
    exit_code = agent.get("exit_code")
    if exit_code is None:
        exit_code = summary_row.get("exit_code")

    last_file = pathlib.Path(str(agent.get("last_file", "") or ""))
    result_json = pathlib.Path(str(agent.get("result_json", "") or ""))
    preview = preview_from_files(last_file, result_json)

    row = {
        "idx": idx,
        "agent_id": agent.get("agent_id"),
        "run_id": run_id,
        "attempt": attempt,
        "state_class": str(agent.get("state_class", "") or ""),
        "reason": str(agent.get("reason", "") or ""),
        "exit_code": exit_code,
        "duration_sec": duration_sec,
        "chat_proof": str(agent.get("chat_proof", "unknown") or "unknown"),
        "assigned_chat_url_norm": str(agent.get("assigned_chat_url_norm", "") or ""),
        "observed_chat_url_norm": str(agent.get("observed_chat_url_norm", "") or ""),
        "preview": preview,
        "last_file": str(last_file),
        "log_file": str(agent.get("log_file", "") or ""),
        "result_json": str(result_json),
        "early_abort_blame": 1 if str(agent.get("agent_id", "") or "") in early_abort_blame_agents else 0,
    }
    rows.append(row)

if not rows:
    # Fallback when summary.jsonl/fleet agents are absent.
    rows = []

totals = {
    "done_ok": as_int(fleet.get("done_ok"), as_int(fleet.get("done"), 0)),
    "done_fail": as_int(fleet.get("done_fail"), 0),
    "stuck": as_int(fleet.get("stuck"), 0),
    "orphaned": as_int(fleet.get("orphaned"), 0),
    "unknown": as_int(fleet.get("unknown"), 0),
    "chat_ok_total": as_int(fleet.get("chat_ok_total"), 0),
    "chat_mismatch_total": as_int(fleet.get("chat_mismatch_total"), 0),
    "chat_unknown_total": as_int(fleet.get("chat_unknown_total"), 0),
    "disk_status": str(fleet.get("disk_status", "unknown") or "unknown"),
    "disk_free_pct": fleet.get("disk_free_pct"),
}

if not gate_status:
    gate_status = "UNKNOWN"
if not gate_reason:
    gate_reason = "unknown"

fail_rows: List[Dict[str, Any]] = []
for row in rows:
    state = row["state_class"]
    proof = row["chat_proof"]
    if proof in ("mismatch", "unknown") or state in ("DONE_FAIL", "STUCK", "ORPHANED"):
        fail_rows.append(row)

report_obj = {
    "generated_at": dt.datetime.now(dt.timezone.utc).isoformat(),
    "pool_run_dir": str(pool_run_dir),
    "gate_status": gate_status,
    "gate_reason": gate_reason,
    "totals": totals,
    "rows": rows,
    "failures": fail_rows,
    "early_abort": {
        "triggered": early_abort_triggered,
        "reason": early_abort_reason,
        "ids_count": len(early_abort_ids),
        "ids": early_abort_ids,
        "meta": early_abort_meta if isinstance(early_abort_meta, dict) else {},
        "files": {
            "flag": str(early_abort_flag_path),
            "reason": str(early_abort_reason_path),
            "ids": str(early_abort_ids_path),
            "meta_json": str(early_abort_meta_path),
        },
    },
    "sources": {
        "fleet_summary_json": str(fleet_summary_path),
        "summary_jsonl": str(summary_jsonl_path),
    },
}

out_json_path.write_text(json.dumps(report_obj, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

md_lines: List[str] = []
md_lines.append("# Pool Report")
md_lines.append("")
md_lines.append(f"- Generated (UTC): `{report_obj['generated_at']}`")
md_lines.append(f"- `POOL_RUN_DIR`: `{pool_run_dir}`")
md_lines.append(f"- `POOL_FLEET_GATE_STATUS`: `{gate_status}`")
md_lines.append(f"- `POOL_FLEET_GATE_REASON`: `{gate_reason}`")
md_lines.append("")
md_lines.append("## Totals")
md_lines.append("")
md_lines.append(f"- `ok`: `{totals['done_ok']}`")
md_lines.append(f"- `fail`: `{totals['done_fail']}`")
md_lines.append(f"- `stuck`: `{totals['stuck']}`")
md_lines.append(f"- `orphaned`: `{totals['orphaned']}`")
md_lines.append(f"- `unknown`: `{totals['unknown']}`")
md_lines.append(f"- `chat_ok`: `{totals['chat_ok_total']}`")
md_lines.append(f"- `chat_mismatch`: `{totals['chat_mismatch_total']}`")
md_lines.append(f"- `chat_unknown`: `{totals['chat_unknown_total']}`")
md_lines.append(f"- `disk_status`: `{totals['disk_status']}`")
md_lines.append(f"- `disk_free_pct`: `{totals['disk_free_pct']}`")
md_lines.append("")
md_lines.append("## Early Abort")
md_lines.append("")
md_lines.append(f"- `triggered`: `{report_obj['early_abort']['triggered']}`")
md_lines.append(f"- `reason`: `{report_obj['early_abort']['reason'] or 'none'}`")
md_lines.append(f"- `ids_count`: `{report_obj['early_abort']['ids_count']}`")
if isinstance(report_obj["early_abort"]["meta"], dict) and report_obj["early_abort"]["meta"]:
    meta = report_obj["early_abort"]["meta"]
    meta_line = ", ".join(
        [
            f"reason={meta.get('reason', 'none')}",
            f"stuck={meta.get('stuck', 0)}",
            f"orphaned={meta.get('orphaned', 0)}",
            f"confirm_ticks={meta.get('confirm_ticks', 0)}",
            f"bad_ticks={meta.get('bad_ticks', 0)}",
        ]
    )
    md_lines.append(f"- `meta`: `{meta_line}`")
if report_obj["early_abort"]["ids"]:
    md_lines.append("")
    md_lines.append("| blame_agent_id | run_id | state_class |")
    md_lines.append("| --- | --- | --- |")
    for blame in report_obj["early_abort"]["ids"]:
        md_lines.append(
            "| "
            + " | ".join(
                [
                    md_escape(str(blame.get("agent_id", ""))),
                    md_escape(str(blame.get("run_id", ""))),
                    md_escape(str(blame.get("state_class", ""))),
                ]
            )
            + " |"
        )
md_lines.append("")
md_lines.append("## Agents")
md_lines.append("")
md_lines.append("| idx | run_id | attempt | state | exit_code | duration_sec | chat_proof | early_abort_blame | assigned_chat | observed_chat | result_preview |")
md_lines.append("| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |")
for row in rows:
    md_lines.append(
        "| "
        + " | ".join(
            [
                str(row.get("idx", "")),
                md_escape(str(row.get("run_id", ""))),
                md_escape(str(row.get("attempt", ""))),
                md_escape(str(row.get("state_class", ""))),
                md_escape(str(row.get("exit_code", ""))),
                md_escape(str(row.get("duration_sec", ""))),
                md_escape(str(row.get("chat_proof", ""))),
                md_escape(str(row.get("early_abort_blame", 0))),
                md_escape(str(row.get("assigned_chat_url_norm", ""))),
                md_escape(str(row.get("observed_chat_url_norm", ""))),
                md_escape(str(row.get("preview", ""))),
            ]
        )
        + " |"
    )

md_lines.append("")
md_lines.append("## Failures / Alerts")
md_lines.append("")
if fail_rows:
    for row in fail_rows:
        parts = [
            f"run_id={row.get('run_id')}",
            f"state={row.get('state_class')}",
            f"chat_proof={row.get('chat_proof')}",
            f"reason={row.get('reason')}",
        ]
        if row.get("early_abort_blame") == 1:
            parts.append("early_abort_blame=1")
        if row.get("assigned_chat_url_norm"):
            parts.append(f"assigned={row.get('assigned_chat_url_norm')}")
        if row.get("observed_chat_url_norm"):
            parts.append(f"observed={row.get('observed_chat_url_norm')}")
        if include_logs:
            if row.get("log_file"):
                parts.append(f"log={row.get('log_file')}")
            if row.get("result_json"):
                parts.append(f"result_json={row.get('result_json')}")
        md_lines.append("- " + ", ".join(parts))
else:
    md_lines.append("- none")

if fail_rows:
    md_lines.append("")
    md_lines.append("## Failure LAST Tails")
    md_lines.append("")
    for row in fail_rows:
        lf = pathlib.Path(str(row.get("last_file") or ""))
        md_lines.append(f"### run_id `{row.get('run_id')}`")
        if not lf.exists():
            md_lines.append("- `(no last file)`")
            md_lines.append("")
            continue
        lines = tail_lines(lf, max_last_lines)
        md_lines.append("```text")
        md_lines.extend(lines if lines else ["(empty)"])
        md_lines.append("```")
        md_lines.append("")

out_md_path.write_text("\n".join(md_lines).rstrip() + "\n", encoding="utf-8")
PY
