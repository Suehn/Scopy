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
INCLUDE_HOVER=0
SKIP_AX_LIST_QUERY="${SCOPY_PROFILE_SKIP_AX_LIST_QUERY:-0}"

TEST_ACCESSIBILITY="ScopyUITests/HistoryListUITests/testScrollProfileRealSnapshotAccessibility"
TEST_MIXED="ScopyUITests/HistoryListUITests/testScrollProfileRealSnapshotMixed"
TEST_TEXT_BIAS="ScopyUITests/HistoryListUITests/testScrollProfileRealSnapshotTextBias"
TEST_SEARCH_EVIDENCE="ScopyUITests/HistoryListUITests/testScrollProfileRealSnapshotSearchEvidence"
TEST_HOVER_MARKDOWN="ScopyUITests/HistoryItemViewUITests/testHoverPreviewMarkdownProfileSmoke"
TEST_HOVER_IMAGE="ScopyUITests/HistoryItemViewUITests/testHoverPreviewImageProfileSmoke"

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
  --include-hover        Also run hover-preview profile smoke and require hover buckets
  -h, --help             Show this help

Environment:
  SCOPY_PROFILE_XCTEST_ITEM_QUERY=1
                         Enable the extra XCUI row-count diagnostic. It is off
                         by default because broad accessibility counts can hang
                         the smoke gate on large real snapshot datasets.
  SCOPY_PROFILE_SKIP_AX_LIST_QUERY=1
                         Skip the XCUI list lookup and rely on app-side
                         automated scrolling. Default: 0.

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
    --include-hover)
      INCLUDE_HOVER=1
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
RUNNER_OUTPUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scopy-frontend-profile.XXXXXX")"
RUNNER_DB_PATH="$RUNNER_OUTPUT_ROOT/clipboard.db"
# Keep XCTest and the profiled app away from Documents-backed repo paths. On macOS, opening
# inputs or outputs there can block in file coordination/TCC until unrelated UI activity occurs.
# The immutable source snapshot remains the auditable input; each profile invocation uses this
# disposable copy so migrations or WAL files cannot mutate it.
cp "$DB_PATH" "$RUNNER_DB_PATH"

terminate_scopy_processes() {
  if command -v osascript >/dev/null 2>&1; then
    osascript -e 'tell application id "com.scopy.app" to quit' >/dev/null 2>&1 || true
  fi
  sleep 1
  pkill -x Scopy >/dev/null 2>&1 || true
}

cleanup() {
  terminate_scopy_processes
  rm -rf "$RUNNER_OUTPUT_ROOT"
}
trap cleanup EXIT
terminate_scopy_processes

if [[ "$SKIP_SETUP" -eq 0 ]]; then
  bash "$PROJECT_DIR/scripts/xcodegen-generate-if-needed.sh" > "$OUT_DIR/setup.log" 2>&1
fi

cd "$PROJECT_DIR"

run_variant_repeat() {
  local variant="$1"
  local repeat="$2"
  local run_id="r$repeat"
  local profile_dir="$OUT_DIR/raw/$variant"
  local runner_profile_dir="$RUNNER_OUTPUT_ROOT/raw/$variant"
  local log_file="$OUT_DIR/xcodebuild.$variant.$run_id.log"
  mkdir -p "$runner_profile_dir"

  local perf_index=1
  local perf_scroll_cache=1
  local perf_markdown_cache=1
  local perf_short_debounce=1

  if [[ "$variant" == "baseline" ]]; then
    perf_index=0
    perf_scroll_cache=0
    perf_markdown_cache=0
    perf_short_debounce=0
  fi

  local profile_scenarios=(
    "real-snapshot-accessibility"
    "real-snapshot-mixed"
    "real-snapshot-text-bias"
    "real-snapshot-search-evidence"
  )
  local profile_tests=(
    "$TEST_ACCESSIBILITY"
    "$TEST_MIXED"
    "$TEST_TEXT_BIAS"
    "$TEST_SEARCH_EVIDENCE"
  )
  if [[ "$INCLUDE_HOVER" -eq 1 ]]; then
    profile_scenarios+=(
      "hover-preview-markdown-text"
      "hover-preview-image"
    )
    profile_tests+=(
      "$TEST_HOVER_MARKDOWN"
      "$TEST_HOVER_IMAGE"
    )
  fi

  local scenario
  for scenario in "${profile_scenarios[@]}"; do
    rm -f \
      "$runner_profile_dir/$scenario-$run_id.json" \
      "$profile_dir/$scenario-$run_id.json"
  done

  run_profile_tests() {
    local run_log="$1"
    shift
    local only_testing_args=()
    local test_name
    for test_name in "$@"; do
      only_testing_args+=(-only-testing:"$test_name")
    done

    env \
      TEST_RUNNER_SCOPY_RUN_PROFILE_UI_TESTS=1 \
      TEST_RUNNER_SCOPY_UI_PROFILE_DB_PATH="$RUNNER_DB_PATH" \
      TEST_RUNNER_SCOPY_UI_PROFILE_OUTPUT_DIR="$runner_profile_dir" \
      TEST_RUNNER_SCOPY_UI_PROFILE_RUN_ID="$run_id" \
      TEST_RUNNER_SCOPY_UI_PROFILE_DURATION_SEC="$DURATION_SEC" \
      TEST_RUNNER_SCOPY_UI_PROFILE_MIN_SAMPLES="$MIN_SAMPLES" \
      TEST_RUNNER_SCOPY_PROFILE_SKIP_AX_LIST_QUERY="$SKIP_AX_LIST_QUERY" \
      TEST_RUNNER_SCOPY_PERF_HISTORY_INDEX="$perf_index" \
      TEST_RUNNER_SCOPY_PERF_SCROLL_RESOLVER_CACHE="$perf_scroll_cache" \
      TEST_RUNNER_SCOPY_PERF_MARKDOWN_RESOLVER_CACHE="$perf_markdown_cache" \
      TEST_RUNNER_SCOPY_PERF_SHORT_QUERY_DEBOUNCE="$perf_short_debounce" \
      xcodebuild -quiet test \
        -project Scopy.xcodeproj \
        -scheme Scopy \
        -destination "$DESTINATION" \
        "${only_testing_args[@]}" \
        2>&1 | tee "$run_log"
  }

  missing_profile_indexes() {
    local index
    for index in "${!profile_scenarios[@]}"; do
      local scenario="${profile_scenarios[$index]}"
      local profile_path="$runner_profile_dir/$scenario-$run_id.json"
      if [[ ! -f "$profile_path" ]]; then
        printf '%s\n' "$index"
      fi
    done
  }

  retry_missing_profiles_once() {
    local missing
    local retried=0
    while IFS= read -r missing; do
      [[ -n "$missing" ]] || continue
      retried=1
      local scenario="${profile_scenarios[$missing]}"
      local test_name="${profile_tests[$missing]}"
      local retry_log="$OUT_DIR/xcodebuild.$variant.$run_id.retry.$scenario.log"
      echo "Retrying missing profile output: $variant/$scenario $run_id"
      terminate_scopy_processes
      run_profile_tests "$retry_log" "$test_name" || return 1
    done < <(missing_profile_indexes)

    if [[ "$retried" -eq 0 ]]; then
      return 0
    fi

    local remaining
    remaining="$(missing_profile_indexes)"
    if [[ -n "$remaining" ]]; then
      echo "Missing profile outputs after retry:" >&2
      printf '%s\n' "$remaining" >&2
      return 1
    fi
  }

  terminate_scopy_processes
  if ! run_profile_tests "$log_file" "${profile_tests[@]}"; then
    if grep -q "Not authorized for performing UI testing actions" "$log_file"; then
      echo "UI testing permission is missing. Enable Automation/Accessibility for XCTest/Xcode and rerun." >&2
    fi
    if grep -q "Profile output not found" "$log_file"; then
      retry_missing_profiles_once || return 1
    else
      return 1
    fi
  fi
  retry_missing_profiles_once || return 1
  for scenario in "${profile_scenarios[@]}"; do
    cp \
      "$runner_profile_dir/$scenario-$run_id.json" \
      "$profile_dir/$scenario-$run_id.json"
  done
  terminate_scopy_processes
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

python3 - "$OUT_DIR" "$REPEATS" "$DURATION_SEC" "$MIN_SAMPLES" "$INCLUDE_HOVER" <<'PY'
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
include_hover = sys.argv[5] == "1"

raw_root = os.path.join(out_dir, "raw")
variants = ["baseline", "current"]

metric_bucket_keys = [
    "row.display_model_ms",
    "row.file_preview_ms",
    "swiftui.row_body_ms",
    "swiftui.row_equatable_ms",
    "text.title_ms",
    "text.metadata_ms",
    "text.markdown_detect_ms",
    "image.thumbnail_decode_ms",
    "image.thumbnail_queue_wait_ms",
    "image.thumbnail_inflight_wait_ms",
    "image.thumbnail_imageio_decode_ms",
    "image.thumbnail_main_commit_ms",
    "image.thumbnail_load_total_ms",
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
        active_frame = payload.get("active_frame_ms", {})
        main_runloop = payload.get("main_runloop_active_ms", {})
        accessibility_tree = payload.get("accessibility_tree") or {}
        accessibility_view_tree = accessibility_tree.get("view_tree") or {}
        xctest_accessibility_query = payload.get("xctest_accessibility_query") or {}
        buckets = payload.get("buckets_ms", {})
        hover_preview_evidence = payload.get("hover_preview_evidence") or {}
        fixed_workload = payload.get("fixed_workload") or {}
        records[variant][scenario].append({
            "path": path,
            "frame_p95": frame.get("p95"),
            "frame_avg": frame.get("avg"),
            "frame_count": frame.get("count"),
            "drop_ratio": payload.get("drop_ratio"),
            "active_frame_p95": active_frame.get("p95"),
            "active_frame_avg": active_frame.get("avg"),
            "active_frame_count": active_frame.get("count"),
            "active_drop_ratio": payload.get("active_drop_ratio"),
            "main_runloop_active_p95": main_runloop.get("p95"),
            "main_runloop_active_avg": main_runloop.get("avg"),
            "main_runloop_active_count": main_runloop.get("count"),
            "scroll_sample_health": payload.get("scroll_sample_health") or {},
            "long_frame_attribution": payload.get("long_frame_attribution") or {},
            "main_thread_long_frame_attribution": payload.get("main_thread_long_frame_attribution") or {},
            "accessibility_snapshot_ms": accessibility_tree.get("snapshot_ms"),
            "accessibility_ax_query_ms": accessibility_tree.get("ax_query_ms"),
            "accessibility_ax_children_count": accessibility_tree.get("ax_children_count"),
            "accessibility_ax_rows_count": accessibility_tree.get("ax_rows_count"),
            "accessibility_view_count": accessibility_view_tree.get("view_count"),
            "xctest_history_item_query_ms": xctest_accessibility_query.get("history_item_query_ms"),
            "xctest_history_item_count": xctest_accessibility_query.get("history_item_count"),
            "hover_preview_evidence": hover_preview_evidence,
            "workload_loaded_count": fixed_workload.get("loaded_count"),
            "workload_search_evidence_count": fixed_workload.get("search_evidence_count"),
            "workload_search_query": fixed_workload.get("search_query"),
            "workload_search_mode": fixed_workload.get("search_mode"),
            "workload_search_ready": fixed_workload.get("search_ready"),
            "bucket_p95": {
                key: ((buckets.get(key) or {}).get("p95"))
                for key in metric_bucket_keys
            },
        })

def scalar_summary(entries, key):
    vals = [e.get(key) for e in entries if isinstance(e.get(key), (int, float))]
    return {
        "median": median(vals),
        "mean": mean(vals),
        "min": min_v(vals),
        "max": max_v(vals),
    }

def summarize_long_frame_attribution(entries, field="long_frame_attribution"):
    by_metric = {}
    long_frame_count = 0
    metric_event_count = 0
    total_frame_ms = 0.0
    attributed_union_ms = 0.0
    unattributed_ms = 0.0
    for entry in entries:
        attribution = entry.get(field) or {}
        long_frame_count += int(attribution.get("long_frame_count") or 0)
        metric_event_count += int(attribution.get("metric_event_count") or 0)
        total_frame_ms += float(attribution.get("total_frame_ms") or 0)
        attributed_union_ms += float(attribution.get("attributed_union_ms") or 0)
        unattributed_ms += float(attribution.get("unattributed_ms") or 0)
        for metric in attribution.get("top_metrics") or []:
            name = metric.get("name")
            if not name:
                continue
            aggregate = by_metric.setdefault(name, {
                "name": name,
                "count": 0,
                "frame_count": 0,
                "total_ms": 0.0,
                "overlap_ms": 0.0,
                "max_ms": 0.0,
            })
            aggregate["count"] += int(metric.get("count") or 0)
            aggregate["frame_count"] += int(metric.get("frame_count") or 0)
            aggregate["total_ms"] += float(metric.get("total_ms") or 0)
            aggregate["overlap_ms"] += float(metric.get("overlap_ms") or 0)
            aggregate["max_ms"] = max(aggregate["max_ms"], float(metric.get("max_ms") or 0))

    top_metrics = sorted(
        by_metric.values(),
        key=lambda item: (item["overlap_ms"], item["total_ms"]),
        reverse=True,
    )[:8]
    return {
        "long_frame_count": long_frame_count,
        "metric_event_count": metric_event_count,
        "total_frame_ms": total_frame_ms,
        "attributed_union_ms": attributed_union_ms,
        "unattributed_ms": unattributed_ms,
        "attribution_coverage_ratio": (attributed_union_ms / total_frame_ms) if total_frame_ms else None,
        "top_metrics": top_metrics,
    }

def summarize_hover_preview_evidence(entries):
    required = set()
    missing = set()
    bucket_counts = defaultdict(list)
    data_sources = set()
    harness_scenarios = set()
    preview_identifiers = set()
    preview_triggered = False
    preview_accessibility_found = False

    for entry in entries:
        evidence = entry.get("hover_preview_evidence") or {}
        preview_triggered = preview_triggered or bool(
            evidence.get("preview_opened")
            or evidence.get("preview_triggered")
            or evidence.get("text_preview_opened")
            or evidence.get("image_preview_opened")
        )
        preview_accessibility_found = preview_accessibility_found or bool(evidence.get("preview_accessibility_found"))
        data_source = evidence.get("data_source")
        if data_source:
            data_sources.add(str(data_source))
        harness_scenario = evidence.get("harness_scenario")
        if harness_scenario:
            harness_scenarios.add(str(harness_scenario))
        preview_identifier = evidence.get("preview_identifier")
        if preview_identifier:
            preview_identifiers.add(str(preview_identifier))
        for name in evidence.get("required_buckets") or []:
            required.add(str(name))
        for name in evidence.get("missing_required_buckets") or []:
            missing.add(str(name))
        for name, count in (evidence.get("bucket_counts") or {}).items():
            if isinstance(count, (int, float)):
                bucket_counts[str(name)].append(int(count))

    return {
        "preview_triggered": preview_triggered,
        "preview_accessibility_found": preview_accessibility_found,
        "harness_scenarios": sorted(harness_scenarios),
        "preview_identifiers": sorted(preview_identifiers),
        "required_buckets": sorted(required),
        "missing_required_buckets": sorted(missing),
        "bucket_counts": {
            name: {
                "median": median(values),
                "min": min_v(values),
                "max": max_v(values),
            }
            for name, values in sorted(bucket_counts.items())
        },
        "data_sources": sorted(data_sources),
    }

summary = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "repeats_requested": repeats,
    "duration_seconds": duration_sec,
    "min_samples": min_samples,
    "include_hover": include_hover,
    "variants": {},
}

for variant in variants:
    scenario_map = {}
    for scenario, entries in sorted(records[variant].items()):
        frame_p95 = [e["frame_p95"] for e in entries if isinstance(e["frame_p95"], (int, float))]
        frame_avg = [e["frame_avg"] for e in entries if isinstance(e["frame_avg"], (int, float))]
        frame_count = [e["frame_count"] for e in entries if isinstance(e["frame_count"], (int, float))]
        drop_ratio = [e["drop_ratio"] for e in entries if isinstance(e["drop_ratio"], (int, float))]
        active_frame_p95 = [e["active_frame_p95"] for e in entries if isinstance(e["active_frame_p95"], (int, float))]
        active_frame_avg = [e["active_frame_avg"] for e in entries if isinstance(e["active_frame_avg"], (int, float))]
        active_frame_count = [e["active_frame_count"] for e in entries if isinstance(e["active_frame_count"], (int, float))]
        active_drop_ratio = [e["active_drop_ratio"] for e in entries if isinstance(e["active_drop_ratio"], (int, float))]
        main_runloop_active_p95 = [e["main_runloop_active_p95"] for e in entries if isinstance(e["main_runloop_active_p95"], (int, float))]
        main_runloop_active_avg = [e["main_runloop_active_avg"] for e in entries if isinstance(e["main_runloop_active_avg"], (int, float))]
        main_runloop_active_count = [e["main_runloop_active_count"] for e in entries if isinstance(e["main_runloop_active_count"], (int, float))]

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
            "active_frame_p95_ms": {
                "median": median(active_frame_p95),
                "mean": mean(active_frame_p95),
                "min": min_v(active_frame_p95),
                "max": max_v(active_frame_p95),
            },
            "active_frame_avg_ms": {
                "median": median(active_frame_avg),
                "mean": mean(active_frame_avg),
                "min": min_v(active_frame_avg),
                "max": max_v(active_frame_avg),
            },
            "active_frame_sample_count": {
                "median": median(active_frame_count),
                "mean": mean(active_frame_count),
                "min": min_v(active_frame_count),
                "max": max_v(active_frame_count),
            },
            "active_drop_ratio": {
                "median": median(active_drop_ratio),
                "mean": mean(active_drop_ratio),
                "min": min_v(active_drop_ratio),
                "max": max_v(active_drop_ratio),
            },
            "main_runloop_active_p95_ms": {
                "median": median(main_runloop_active_p95),
                "mean": mean(main_runloop_active_p95),
                "min": min_v(main_runloop_active_p95),
                "max": max_v(main_runloop_active_p95),
            },
            "main_runloop_active_avg_ms": {
                "median": median(main_runloop_active_avg),
                "mean": mean(main_runloop_active_avg),
                "min": min_v(main_runloop_active_avg),
                "max": max_v(main_runloop_active_avg),
            },
            "main_runloop_active_count": {
                "median": median(main_runloop_active_count),
                "mean": mean(main_runloop_active_count),
                "min": min_v(main_runloop_active_count),
                "max": max_v(main_runloop_active_count),
            },
            "accessibility_snapshot_ms": scalar_summary(entries, "accessibility_snapshot_ms"),
            "accessibility_ax_query_ms": scalar_summary(entries, "accessibility_ax_query_ms"),
            "accessibility_ax_children_count": scalar_summary(entries, "accessibility_ax_children_count"),
            "accessibility_ax_rows_count": scalar_summary(entries, "accessibility_ax_rows_count"),
            "accessibility_view_count": scalar_summary(entries, "accessibility_view_count"),
            "xctest_history_item_query_ms": scalar_summary(entries, "xctest_history_item_query_ms"),
            "xctest_history_item_count": scalar_summary(entries, "xctest_history_item_count"),
            "search_workload": {
                "loaded_count": scalar_summary(entries, "workload_loaded_count"),
                "evidence_count": scalar_summary(entries, "workload_search_evidence_count"),
                "queries": sorted({
                    e["workload_search_query"]
                    for e in entries
                    if isinstance(e.get("workload_search_query"), str)
                    and e["workload_search_query"]
                }),
                "modes": sorted({
                    e["workload_search_mode"]
                    for e in entries
                    if isinstance(e.get("workload_search_mode"), str)
                    and e["workload_search_mode"]
                }),
                "ready_runs": sum(e.get("workload_search_ready") is True for e in entries),
            },
            "bucket_p95_ms": bucket_summary,
            "long_frame_attribution": summarize_long_frame_attribution(entries),
            "main_thread_long_frame_attribution": summarize_long_frame_attribution(
                entries,
                field="main_thread_long_frame_attribution",
            ),
            "hover_preview_evidence": summarize_hover_preview_evidence(entries),
        }
    summary["variants"][variant] = scenario_map

expected_scenarios = {
    "real-snapshot-accessibility",
    "real-snapshot-mixed",
    "real-snapshot-text-bias",
    "real-snapshot-search-evidence",
}
if include_hover:
    expected_scenarios.add("hover-preview-markdown-text")
    expected_scenarios.add("hover-preview-image")
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

    search_entries = records[variant].get("real-snapshot-search-evidence", [])
    for entry in search_entries:
        source = entry.get("path") or "<unknown>"
        loaded_count = entry.get("workload_loaded_count")
        evidence_count = entry.get("workload_search_evidence_count")
        if entry.get("workload_search_query") != ".":
            errors.append(f"{variant}:search query mismatch in {source}")
        if entry.get("workload_search_mode") != "regex":
            errors.append(f"{variant}:search mode mismatch in {source}")
        if entry.get("workload_search_ready") is not True:
            errors.append(f"{variant}:search workload was not ready in {source}")
        if not isinstance(loaded_count, int) or loaded_count <= 0:
            errors.append(f"{variant}:search workload loaded no rows in {source}")
        if evidence_count != loaded_count:
            errors.append(
                f"{variant}:search evidence {evidence_count} != loaded rows {loaded_count} in {source}"
            )

if include_hover:
    hover_scenarios = ["hover-preview-markdown-text", "hover-preview-image"]
    for variant in variants:
        for scenario in hover_scenarios:
            hover_entries = records[variant].get(scenario, [])
            if len(hover_entries) != repeats:
                errors.append(f"{variant}:{scenario} expected raw entries={repeats}, got={len(hover_entries)}")
            for entry in hover_entries:
                evidence = entry.get("hover_preview_evidence") or {}
                source = entry.get("path") or "<unknown>"
                if not (evidence.get("preview_opened") or evidence.get("preview_triggered")):
                    errors.append(f"{variant}:{scenario} preview was not triggered in {source}")
                missing_buckets = evidence.get("missing_required_buckets") or []
                if missing_buckets:
                    errors.append(f"{variant}:{scenario} missing hover buckets {missing_buckets} in {source}")

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
md_lines.append(f"- Include hover preview smoke: {str(include_hover).lower()}")
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
        ("active_frame_p95_ms", baseline.get("active_frame_p95_ms", {}).get("median"), current.get("active_frame_p95_ms", {}).get("median")),
        ("active_drop_ratio", baseline.get("active_drop_ratio", {}).get("median"), current.get("active_drop_ratio", {}).get("median")),
        ("main_runloop_active_p95_ms", baseline.get("main_runloop_active_p95_ms", {}).get("median"), current.get("main_runloop_active_p95_ms", {}).get("median")),
        ("swiftui.row_body_ms.p95", baseline.get("bucket_p95_ms", {}).get("swiftui.row_body_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("swiftui.row_body_ms", {}).get("median")),
        ("swiftui.row_equatable_ms.p95", baseline.get("bucket_p95_ms", {}).get("swiftui.row_equatable_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("swiftui.row_equatable_ms", {}).get("median")),
        ("row.display_model_ms.p95", baseline.get("bucket_p95_ms", {}).get("row.display_model_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("row.display_model_ms", {}).get("median")),
        ("row.file_preview_ms.p95", baseline.get("bucket_p95_ms", {}).get("row.file_preview_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("row.file_preview_ms", {}).get("median")),
        ("accessibility.snapshot_ms", baseline.get("accessibility_snapshot_ms", {}).get("median"), current.get("accessibility_snapshot_ms", {}).get("median")),
        ("accessibility.ax_query_ms", baseline.get("accessibility_ax_query_ms", {}).get("median"), current.get("accessibility_ax_query_ms", {}).get("median")),
        ("accessibility.ax_children_count", baseline.get("accessibility_ax_children_count", {}).get("median"), current.get("accessibility_ax_children_count", {}).get("median")),
        ("accessibility.ax_rows_count", baseline.get("accessibility_ax_rows_count", {}).get("median"), current.get("accessibility_ax_rows_count", {}).get("median")),
        ("accessibility.view_count", baseline.get("accessibility_view_count", {}).get("median"), current.get("accessibility_view_count", {}).get("median")),
        ("xctest.history_item_query_ms", baseline.get("xctest_history_item_query_ms", {}).get("median"), current.get("xctest_history_item_query_ms", {}).get("median")),
        ("xctest.history_item_count", baseline.get("xctest_history_item_count", {}).get("median"), current.get("xctest_history_item_count", {}).get("median")),
        ("text.metadata_ms.p95", baseline.get("bucket_p95_ms", {}).get("text.metadata_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("text.metadata_ms", {}).get("median")),
        ("text.markdown_detect_ms.p95", baseline.get("bucket_p95_ms", {}).get("text.markdown_detect_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("text.markdown_detect_ms", {}).get("median")),
        ("image.thumbnail_decode_ms.p95", baseline.get("bucket_p95_ms", {}).get("image.thumbnail_decode_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("image.thumbnail_decode_ms", {}).get("median")),
        ("image.thumbnail_queue_wait_ms.p95", baseline.get("bucket_p95_ms", {}).get("image.thumbnail_queue_wait_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("image.thumbnail_queue_wait_ms", {}).get("median")),
        ("image.thumbnail_imageio_decode_ms.p95", baseline.get("bucket_p95_ms", {}).get("image.thumbnail_imageio_decode_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("image.thumbnail_imageio_decode_ms", {}).get("median")),
        ("image.thumbnail_main_commit_ms.p95", baseline.get("bucket_p95_ms", {}).get("image.thumbnail_main_commit_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("image.thumbnail_main_commit_ms", {}).get("median")),
        ("image.thumbnail_load_total_ms.p95", baseline.get("bucket_p95_ms", {}).get("image.thumbnail_load_total_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("image.thumbnail_load_total_ms", {}).get("median")),
        ("hover.markdown_render_ms.p95", baseline.get("bucket_p95_ms", {}).get("hover.markdown_render_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("hover.markdown_render_ms", {}).get("median")),
        ("hover.preview_image_decode_ms.p95", baseline.get("bucket_p95_ms", {}).get("hover.preview_image_decode_ms", {}).get("median"), current.get("bucket_p95_ms", {}).get("hover.preview_image_decode_ms", {}).get("median")),
    ]
    for metric, base, curr in pairs:
        delta = None if base is None or curr is None else (curr - base)
        md_lines.append(
            f"| {scenario} | {metric} | {fmt(base)} | {fmt(curr)} | {fmt(delta)} | {pct(base, curr)} |"
        )

md_lines.append("")
md_lines.append("## Long Frame Attribution")
md_lines.append("")
md_lines.append("| Scenario | Variant | Long Frames | App Attributed | App Unattributed | App Coverage | Main Thread Coverage | Top Correlated App Metrics |")
md_lines.append("|---|---:|---:|---:|---:|---:|---:|---|")
for scenario in all_scenarios:
    for variant in variants:
        scenario_summary = summary["variants"].get(variant, {}).get(scenario, {})
        attribution = scenario_summary.get("long_frame_attribution", {})
        main_thread_attribution = scenario_summary.get("main_thread_long_frame_attribution", {})
        top_metrics = []
        for metric in attribution.get("top_metrics") or []:
            name = metric.get("name") or ""
            overlap = metric.get("overlap_ms")
            count = metric.get("count")
            if name and isinstance(overlap, (int, float)):
                top_metrics.append(f"{name} {overlap:.2f}ms/{int(count or 0)}x")
        top_text = ", ".join(top_metrics[:5]) if top_metrics else "-"
        attributed = attribution.get("attributed_union_ms")
        unattributed = attribution.get("unattributed_ms")
        coverage = attribution.get("attribution_coverage_ratio")
        attributed_text = f"{attributed:.2f}ms" if isinstance(attributed, (int, float)) else "-"
        unattributed_text = f"{unattributed:.2f}ms" if isinstance(unattributed, (int, float)) else "-"
        coverage_text = f"{coverage * 100:.1f}%" if isinstance(coverage, (int, float)) else "-"
        main_thread_coverage = main_thread_attribution.get("attribution_coverage_ratio")
        main_thread_coverage_text = f"{main_thread_coverage * 100:.1f}%" if isinstance(main_thread_coverage, (int, float)) else "-"
        md_lines.append(
            f"| {scenario} | {variant} | {int(attribution.get('long_frame_count') or 0)} | {attributed_text} | {unattributed_text} | {coverage_text} | {main_thread_coverage_text} | {top_text} |"
        )

if include_hover:
    md_lines.append("")
    md_lines.append("## Hover Preview Evidence")
    md_lines.append("")
    md_lines.append("| Scenario | Variant | Runs | Preview Triggered | Accessibility Found | Missing Buckets | Bucket Counts |")
    md_lines.append("|---|---|---:|---:|---:|---|---|")
    for scenario in ["hover-preview-markdown-text", "hover-preview-image"]:
        for variant in variants:
            scenario_summary = summary["variants"].get(variant, {}).get(scenario, {})
            evidence = scenario_summary.get("hover_preview_evidence") or {}
            counts = []
            for name, count_summary in (evidence.get("bucket_counts") or {}).items():
                value = count_summary.get("median")
                if isinstance(value, (int, float)):
                    counts.append(f"{name}: {value:.0f}")
            missing = ", ".join(evidence.get("missing_required_buckets") or []) or "-"
            count_text = ", ".join(counts) if counts else "-"
            md_lines.append(
                f"| {scenario} | {variant} | {int(scenario_summary.get('runs') or 0)} | {evidence.get('preview_triggered')} | {evidence.get('preview_accessibility_found')} | {missing} | {count_text} |"
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
