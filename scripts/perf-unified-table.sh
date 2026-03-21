#!/bin/bash
# Merge backend perf-audit metrics and frontend scroll/profile metrics into one table.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

BACKEND_BASELINE=""
BACKEND_CURRENT=""
FRONTEND_SUMMARY=""
OUT_MD_DEFAULT="$PROJECT_DIR/logs/perf-unified-$(date +"%Y-%m-%d_%H-%M-%S").md"
OUT_MD="$OUT_MD_DEFAULT"

print_help() {
  cat <<EOH
Generate one unified comparison table for backend + frontend performance.

Usage:
  bash scripts/perf-unified-table.sh \
    --backend-baseline <dir> \
    --backend-current <dir> \
    --frontend-summary <json> \
    [--out <markdown-path>]
EOH
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend-baseline)
      BACKEND_BASELINE="$2"
      shift 2
      ;;
    --backend-current)
      BACKEND_CURRENT="$2"
      shift 2
      ;;
    --frontend-summary)
      FRONTEND_SUMMARY="$2"
      shift 2
      ;;
    --out)
      OUT_MD="$2"
      shift 2
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      print_help >&2
      exit 2
      ;;
  esac
done

if [[ -z "$BACKEND_BASELINE" || -z "$BACKEND_CURRENT" || -z "$FRONTEND_SUMMARY" ]]; then
  print_help >&2
  exit 2
fi

if [[ ! -d "$BACKEND_BASELINE" ]]; then
  echo "Missing backend baseline dir: $BACKEND_BASELINE" >&2
  exit 1
fi
if [[ ! -d "$BACKEND_CURRENT" ]]; then
  echo "Missing backend current dir: $BACKEND_CURRENT" >&2
  exit 1
fi
if [[ ! -f "$FRONTEND_SUMMARY" ]]; then
  echo "Missing frontend summary: $FRONTEND_SUMMARY" >&2
  exit 1
fi

mkdir -p "$(dirname "$OUT_MD")"
OUT_JSON="$(printf '%s' "$OUT_MD" | sed 's/\.md$/.json/')"

python3 - "$BACKEND_BASELINE" "$BACKEND_CURRENT" "$FRONTEND_SUMMARY" "$OUT_MD" "$OUT_JSON" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

backend_baseline_dir = sys.argv[1]
backend_current_dir = sys.argv[2]
frontend_summary_path = sys.argv[3]
out_md = sys.argv[4]
out_json = sys.argv[5]

backend_labels = [
    ("backend.engine.cm.p95_ms", "scopybench.jsonl", "snapshot:fuzzyPlus:relevance:cm"),
    ("backend.engine.math.p95_ms", "scopybench.jsonl", "snapshot:fuzzyPlus:relevance:数学"),
    ("backend.engine.cmd.p95_ms", "scopybench.jsonl", "snapshot:fuzzyPlus:relevance:cmd"),
    ("backend.engine.cm.force_full_fuzzy.p95_ms", "scopybench.jsonl", "snapshot:fuzzyPlus:relevance:cm:forceFullFuzzy"),
    ("backend.engine.abc.force_full_fuzzy.p95_ms", "scopybench.jsonl", "snapshot:fuzzy:relevance:abc:forceFullFuzzy"),
    ("backend.engine.cmd.force_full_fuzzy.p95_ms", "scopybench.jsonl", "snapshot:fuzzy:relevance:cmd:forceFullFuzzy"),
    ("backend.service.cm.p95_ms", "scopybench.service.jsonl", "snapshot:service:fuzzyPlus:relevance:cm"),
    ("backend.service.math.p95_ms", "scopybench.service.jsonl", "snapshot:service:fuzzyPlus:relevance:数学"),
    ("backend.service.cmd.p95_ms", "scopybench.service.jsonl", "snapshot:service:fuzzyPlus:relevance:cmd"),
    ("backend.service.cm.no_thumb.p95_ms", "scopybench.service.jsonl", "snapshot:service:fuzzyPlus:relevance:cm:noThumb"),
]

def read_jsonl(path):
    rows = []
    if not os.path.isfile(path):
        return rows
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            try:
                rows.append(json.loads(line))
            except json.JSONDecodeError:
                continue
    return rows

def load_backend_metrics(root):
    metric_map = {}
    for _, filename, _ in backend_labels:
        path = os.path.join(root, filename)
        for row in read_jsonl(path):
            label = row.get("label")
            p95 = row.get("p95_ms")
            if label and isinstance(p95, (int, float)):
                metric_map[label] = float(p95)
    return metric_map

def load_warm_load_summary(root):
    path = os.path.join(root, "warm-load-summary.json")
    if not os.path.isfile(path):
        return {}
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    summary = {}
    if isinstance(data.get("warm_load_ms"), (int, float)):
        summary["warm_load_ms"] = float(data["warm_load_ms"])
    if isinstance(data.get("peak_rss_mb"), (int, float)):
        summary["peak_rss_mb"] = float(data["peak_rss_mb"])
    return summary

def metric_from_summary(variant_data, scenario, path):
    node = variant_data.get(scenario, {})
    for key in path:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    if isinstance(node, (int, float)):
        return float(node)
    return None

backend_baseline = load_backend_metrics(backend_baseline_dir)
backend_current = load_backend_metrics(backend_current_dir)
backend_warm_baseline = load_warm_load_summary(backend_baseline_dir)
backend_warm_current = load_warm_load_summary(backend_current_dir)

with open(frontend_summary_path, "r", encoding="utf-8") as f:
    frontend_summary = json.load(f)

frontend_baseline = (frontend_summary.get("variants") or {}).get("baseline", {})
frontend_current = (frontend_summary.get("variants") or {}).get("current", {})
frontend_scenarios = sorted(set(frontend_baseline.keys()) | set(frontend_current.keys()))

rows = []

for metric_name, _, label in backend_labels:
    rows.append({
        "domain": "backend",
        "metric": metric_name,
        "baseline": backend_baseline.get(label),
        "current": backend_current.get(label),
        "unit": "ms",
        "source": label,
    })

rows.append({
    "domain": "backend",
    "metric": "backend.engine.full_index.warm_load_ms",
    "baseline": backend_warm_baseline.get("warm_load_ms"),
    "current": backend_warm_current.get("warm_load_ms"),
    "unit": "ms",
    "source": "warm-load-summary.json",
})
rows.append({
    "domain": "backend",
    "metric": "backend.engine.full_index.peak_rss_mb",
    "baseline": backend_warm_baseline.get("peak_rss_mb"),
    "current": backend_warm_current.get("peak_rss_mb"),
    "unit": "MB",
    "source": "warm-load-summary.json",
})

frontend_metric_specs = [
    ("frontend.frame.p95_ms", ("frame_p95_ms", "median"), "ms"),
    ("frontend.drop_ratio", ("drop_ratio", "median"), "ratio"),
    ("frontend.text.metadata.p95_ms", ("bucket_p95_ms", "text.metadata_ms", "median"), "ms"),
    ("frontend.image.thumbnail_decode.p95_ms", ("bucket_p95_ms", "image.thumbnail_decode_ms", "median"), "ms"),
]

for scenario in frontend_scenarios:
    for metric_prefix, path, unit in frontend_metric_specs:
        rows.append({
            "domain": "frontend",
            "metric": f"{metric_prefix}[{scenario}]",
            "baseline": metric_from_summary(frontend_baseline, scenario, path),
            "current": metric_from_summary(frontend_current, scenario, path),
            "unit": unit,
            "source": scenario,
        })

def calc_delta(base, current):
    if base is None or current is None:
        return None
    return current - base

def calc_change_pct(base, current):
    if base in (None, 0) or current is None:
        return None
    return (current - base) / base * 100.0

for row in rows:
    base = row["baseline"]
    current = row["current"]
    row["delta"] = calc_delta(base, current)
    row["change_pct"] = calc_change_pct(base, current)

def fmt(value, digits=3):
    if value is None:
        return "-"
    return f"{value:.{digits}f}"

def fmt_pct(value):
    if value is None:
        return "-"
    return f"{value:.2f}%"

md_lines = []
md_lines.append("# Unified Performance Comparison (Backend + Frontend)")
md_lines.append("")
md_lines.append(f"- Generated at: {datetime.now(timezone.utc).isoformat()}")
md_lines.append(f"- Backend baseline: `{backend_baseline_dir}`")
md_lines.append(f"- Backend current: `{backend_current_dir}`")
md_lines.append(f"- Frontend summary: `{frontend_summary_path}`")
md_lines.append("")
md_lines.append("| Domain | Metric | Baseline | Current | Delta | Change | Unit |")
md_lines.append("|---|---|---:|---:|---:|---:|---:|")
for row in rows:
    md_lines.append(
        f"| {row['domain']} | {row['metric']} | {fmt(row['baseline'])} | {fmt(row['current'])} | {fmt(row['delta'])} | {fmt_pct(row['change_pct'])} | {row['unit']} |"
    )

with open(out_md, "w", encoding="utf-8") as f:
    f.write("\n".join(md_lines) + "\n")

payload = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "backend_baseline_dir": backend_baseline_dir,
    "backend_current_dir": backend_current_dir,
    "frontend_summary_path": frontend_summary_path,
    "rows": rows,
}
with open(out_json, "w", encoding="utf-8") as f:
    json.dump(payload, f, ensure_ascii=False, indent=2)

print(out_md)
print(out_json)
PY

echo "Done."
echo "Unified table MD:   $OUT_MD"
echo "Unified table JSON: $OUT_JSON"
