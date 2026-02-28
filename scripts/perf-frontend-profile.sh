#!/bin/bash
# Run realistic frontend scroll/profile benchmarks (baseline vs current).
# Produces repeatable JSON + Markdown summaries under logs/.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR_DEFAULT="$PROJECT_DIR/logs/perf-frontend-profile-$(date +"%Y-%m-%d_%H-%M-%S")"
DB_DEFAULT="$PROJECT_DIR/perf-db/clipboard.db"

OUT_DIR="$OUT_DIR_DEFAULT"
DB_PATH="$DB_DEFAULT"
REPEATS=3
DURATION_SEC=10
MIN_SAMPLES=260
SKIP_SETUP=0
DESTINATION="platform=macOS"

TEST_ACCESSIBILITY="ScopyUITests/HistoryListUITests/testScrollProfileRealSnapshotAccessibility"
TEST_MIXED="ScopyUITests/HistoryListUITests/testScrollProfileRealSnapshotMixed"
TEST_TEXT_BIAS="ScopyUITests/HistoryListUITests/testScrollProfileRealSnapshotTextBias"

print_help() {
  cat <<EOF
Run frontend scroll/profile benchmark with realistic snapshot DB scenarios.

Usage:
  bash scripts/perf-frontend-profile.sh [options]

Options:
  --out <dir>            Output directory (default: $OUT_DIR_DEFAULT)
  --db <path>            Snapshot DB path (default: $DB_DEFAULT)
  --repeats <n>          Repeats per variant (default: $REPEATS)
  --duration <sec>       Profile duration per scenario (default: $DURATION_SEC)
  --min-samples <n>      Minimum frame samples (default: $MIN_SAMPLES)
  --skip-setup           Skip xcodegen regenerate check
  -h, --help             Show this help

Outputs:
  <out>/raw/<variant>/*.json
  <out>/frontend-scroll-profile-summary.json
  <out>/frontend-scroll-profile-summary.md
EOF
}

abs_path() {
  local input="$1"
  if [[ "$input" = /* ]]; then
    printf '%s\n' "$input"
  else
    printf '%s\n' "$PROJECT_DIR/$input"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --db)
      DB_PATH="$2"
      shift 2
      ;;
    --repeats)
      REPEATS="$2"
      shift 2
      ;;
    --duration)
      DURATION_SEC="$2"
      shift 2
      ;;
    --min-samples)
      MIN_SAMPLES="$2"
      shift 2
      ;;
    --skip-setup)
      SKIP_SETUP=1
      shift 1
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

OUT_DIR="$(abs_path "$OUT_DIR")"
DB_PATH="$(abs_path "$DB_PATH")"
if [[ ! -f "$DB_PATH" ]]; then
  echo "Missing snapshot DB: $DB_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR/raw/baseline" "$OUT_DIR/raw/current"

if [[ "$SKIP_SETUP" -eq 0 ]]; then
  bash "$PROJECT_DIR/scripts/xcodegen-generate-if-needed.sh" > "$OUT_DIR/setup.log" 2>&1
fi

cd "$PROJECT_DIR"

run_variant_repeat() {
  local variant="$1"
  local repeat="$2"
  local run_id="r$repeat"
  local profile_dir="$OUT_DIR/raw/$variant"
  local log_file="$OUT_DIR/xcodebuild.$variant.$run_id.log"

  local perf_index=1
  local perf_scroll_cache=1
  local perf_markdown_cache=1
  local perf_preview_budget=1
  local perf_short_debounce=1

  if [[ "$variant" == "baseline" ]]; then
    perf_index=0
    perf_scroll_cache=0
    perf_markdown_cache=0
    perf_preview_budget=0
    perf_short_debounce=0
  fi

  if ! env \
    TEST_RUNNER_SCOPY_RUN_PROFILE_UI_TESTS=1 \
    TEST_RUNNER_SCOPY_UI_PROFILE_DB_PATH="$DB_PATH" \
    TEST_RUNNER_SCOPY_UI_PROFILE_OUTPUT_DIR="$profile_dir" \
    TEST_RUNNER_SCOPY_UI_PROFILE_RUN_ID="$run_id" \
    TEST_RUNNER_SCOPY_UI_PROFILE_DURATION_SEC="$DURATION_SEC" \
    TEST_RUNNER_SCOPY_UI_PROFILE_MIN_SAMPLES="$MIN_SAMPLES" \
    TEST_RUNNER_SCOPY_PERF_HISTORY_INDEX="$perf_index" \
    TEST_RUNNER_SCOPY_PERF_SCROLL_RESOLVER_CACHE="$perf_scroll_cache" \
    TEST_RUNNER_SCOPY_PERF_MARKDOWN_RESOLVER_CACHE="$perf_markdown_cache" \
    TEST_RUNNER_SCOPY_PERF_PREVIEW_TASK_BUDGET="$perf_preview_budget" \
    TEST_RUNNER_SCOPY_PERF_SHORT_QUERY_DEBOUNCE="$perf_short_debounce" \
    xcodebuild test \
      -project Scopy.xcodeproj \
      -scheme Scopy \
      -destination "$DESTINATION" \
      -only-testing:"$TEST_ACCESSIBILITY" \
      -only-testing:"$TEST_MIXED" \
      -only-testing:"$TEST_TEXT_BIAS" \
      2>&1 | tee "$log_file"; then
    if grep -q "Not authorized for performing UI testing actions" "$log_file"; then
      echo "UI testing permission is missing. Enable Automation/Accessibility for XCTest/Xcode and rerun." >&2
    fi
    return 1
  fi
}

echo "Output dir: $OUT_DIR"
echo "DB: $DB_PATH"
echo "Repeats: $REPEATS"

for repeat in $(seq 1 "$REPEATS"); do
  echo "== Repeat $repeat/$REPEATS: baseline =="
  run_variant_repeat "baseline" "$repeat"
  echo "== Repeat $repeat/$REPEATS: current =="
  run_variant_repeat "current" "$repeat"
done

python3 - "$OUT_DIR" "$REPEATS" "$DURATION_SEC" "$MIN_SAMPLES" <<'PY'
import json
import os
import statistics
import sys
from collections import defaultdict
from datetime import datetime, timezone

out_dir = sys.argv[1]
repeats = int(sys.argv[2])
duration_sec = float(sys.argv[3])
min_samples = int(sys.argv[4])

raw_root = os.path.join(out_dir, "raw")
variants = ["baseline", "current"]

metric_bucket_keys = [
    "text.title_ms",
    "text.metadata_ms",
    "image.thumbnail_decode_ms",
    "hover.markdown_render_ms",
    "hover.preview_image_decode_ms",
]

def median(values):
    if not values:
        return None
    return float(statistics.median(values))

def mean(values):
    if not values:
        return None
    return float(statistics.fmean(values))

def min_v(values):
    if not values:
        return None
    return float(min(values))

def max_v(values):
    if not values:
        return None
    return float(max(values))

records = defaultdict(lambda: defaultdict(list))

for variant in variants:
    variant_dir = os.path.join(raw_root, variant)
    if not os.path.isdir(variant_dir):
        continue
    for name in sorted(os.listdir(variant_dir)):
        if not name.endswith(".json"):
            continue
        path = os.path.join(variant_dir, name)
        try:
            with open(path, "r", encoding="utf-8") as f:
                payload = json.load(f)
        except Exception:
            continue
        scenario = payload.get("profile_scenario") or os.path.splitext(name)[0]
        frame = payload.get("frame_ms", {})
        buckets = payload.get("buckets_ms", {})
        records[variant][scenario].append({
            "path": path,
            "frame_p95": frame.get("p95"),
            "frame_avg": frame.get("avg"),
            "frame_count": frame.get("count"),
            "drop_ratio": payload.get("drop_ratio"),
            "bucket_p95": {
                key: ((buckets.get(key) or {}).get("p95"))
                for key in metric_bucket_keys
            },
        })

summary = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "repeats_requested": repeats,
    "duration_seconds": duration_sec,
    "min_samples": min_samples,
    "variants": {},
}

for variant in variants:
    scenario_map = {}
    for scenario, entries in sorted(records[variant].items()):
        frame_p95 = [e["frame_p95"] for e in entries if isinstance(e["frame_p95"], (int, float))]
        frame_avg = [e["frame_avg"] for e in entries if isinstance(e["frame_avg"], (int, float))]
        frame_count = [e["frame_count"] for e in entries if isinstance(e["frame_count"], (int, float))]
        drop_ratio = [e["drop_ratio"] for e in entries if isinstance(e["drop_ratio"], (int, float))]

        bucket_summary = {}
        for key in metric_bucket_keys:
            vals = [e["bucket_p95"].get(key) for e in entries if isinstance(e["bucket_p95"].get(key), (int, float))]
            bucket_summary[key] = {
                "median": median(vals),
                "mean": mean(vals),
                "min": min_v(vals),
                "max": max_v(vals),
            }

        scenario_map[scenario] = {
            "runs": len(entries),
            "source_files": [e["path"] for e in entries],
            "frame_p95_ms": {
                "median": median(frame_p95),
                "mean": mean(frame_p95),
                "min": min_v(frame_p95),
                "max": max_v(frame_p95),
            },
            "frame_avg_ms": {
                "median": median(frame_avg),
                "mean": mean(frame_avg),
                "min": min_v(frame_avg),
                "max": max_v(frame_avg),
            },
            "frame_sample_count": {
                "median": median(frame_count),
                "mean": mean(frame_count),
                "min": min_v(frame_count),
                "max": max_v(frame_count),
            },
            "drop_ratio": {
                "median": median(drop_ratio),
                "mean": mean(drop_ratio),
                "min": min_v(drop_ratio),
                "max": max_v(drop_ratio),
            },
            "bucket_p95_ms": bucket_summary,
        }
    summary["variants"][variant] = scenario_map

expected_scenarios = {
    "real-snapshot-accessibility",
    "real-snapshot-mixed",
    "real-snapshot-text-bias",
}
errors = []
for variant in variants:
    scenario_map = summary["variants"].get(variant, {})
    missing = sorted(expected_scenarios - set(scenario_map.keys()))
    if missing:
        errors.append(f"{variant}: missing scenarios {missing}")
    for scenario in sorted(expected_scenarios):
        runs = int((scenario_map.get(scenario) or {}).get("runs") or 0)
        if runs != repeats:
            errors.append(f"{variant}:{scenario} expected runs={repeats}, got={runs}")

if errors:
    for err in errors:
        print(f"ERROR: {err}", file=sys.stderr)
    raise SystemExit(1)

json_out = os.path.join(out_dir, "frontend-scroll-profile-summary.json")
with open(json_out, "w", encoding="utf-8") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)

def fmt(value, digits=3):
    if value is None:
        return "-"
    return f"{value:.{digits}f}"

def pct(base, current):
    if base in (None, 0) or current is None:
        return "-"
    return f"{((current - base) / base) * 100:.2f}%"

md_lines = []
md_lines.append("# Frontend Scroll/Profile Benchmark Summary")
md_lines.append("")
md_lines.append(f"- Generated at: {summary['generated_at']}")
md_lines.append(f"- Repeats requested: {repeats}")
md_lines.append(f"- Duration per scenario: {duration_sec:.1f}s")
md_lines.append(f"- Min samples: {min_samples}")
md_lines.append("")
md_lines.append("| Scenario | Metric | Baseline | Current | Delta | Change |")
md_lines.append("|---|---:|---:|---:|---:|---:|")

all_scenarios = sorted(set(summary["variants"].get("baseline", {}).keys()) | set(summary["variants"].get("current", {}).keys()))
for scenario in all_scenarios:
    baseline = summary["variants"].get("baseline", {}).get(scenario, {})
    current = summary["variants"].get("current", {}).get(scenario, {})
    pairs = [
        ("frame_p95_ms", baseline.get("frame_p95_ms", {}).get("median"), current.get("frame_p95_ms", {}).get("median")),
        ("drop_ratio", baseline.get("drop_ratio", {}).get("median"), current.get("drop_ratio", {}).get("median")),
        ("text.metadata_ms.p95", baseline.get("bucket_p95_ms", {}).get("text.metadata_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("text.metadata_ms", {}).get("median")),
        ("image.thumbnail_decode_ms.p95", baseline.get("bucket_p95_ms", {}).get("image.thumbnail_decode_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("image.thumbnail_decode_ms", {}).get("median")),
    ]
    for metric, base, curr in pairs:
        delta = None if base is None or curr is None else (curr - base)
        md_lines.append(
            f"| {scenario} | {metric} | {fmt(base)} | {fmt(curr)} | {fmt(delta)} | {pct(base, curr)} |"
        )

md_out = os.path.join(out_dir, "frontend-scroll-profile-summary.md")
with open(md_out, "w", encoding="utf-8") as f:
    f.write("\n".join(md_lines) + "\n")

print(json_out)
print(md_out)
PY

echo "Done."
echo "Frontend summary JSON: $OUT_DIR/frontend-scroll-profile-summary.json"
echo "Frontend summary MD:   $OUT_DIR/frontend-scroll-profile-summary.md"
