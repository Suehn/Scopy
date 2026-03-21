#!/bin/bash
# Measure full-index warm-load latency and peak RSS using the release ScopyBench binary.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

OUT_DIR_DEFAULT="$PROJECT_DIR/logs/perf-search-warm-load-$(date +"%Y-%m-%d_%H-%M-%S")"
DB_DEFAULT="$PROJECT_DIR/perf-db/clipboard.db"
BENCH_BIN_DEFAULT="$PROJECT_DIR/.build/release/ScopyBench"

OUT_DIR="$OUT_DIR_DEFAULT"
DB_PATH="$DB_DEFAULT"
QUERY="cmd"
MODE="fuzzy"
SORT="relevance"
FORCE_FULL_FUZZY=1
SKIP_BUILD=0
BENCH_BIN="$BENCH_BIN_DEFAULT"

print_help() {
  cat <<EOF
Measure search full-index warm-load latency and peak RSS.

Usage:
  bash scripts/perf-search-warm-load.sh [options]

Options:
  --db <path>            Snapshot DB path (default: $DB_DEFAULT)
  --out <dir>            Output directory (default: $OUT_DIR_DEFAULT)
  --query <text>         Search query used for warm-load (default: $QUERY)
  --bench-bin <path>     Existing ScopyBench binary (default: $BENCH_BIN_DEFAULT)
  --skip-build           Reuse the existing ScopyBench binary
  -h, --help             Show this help

Outputs:
  <out>/warm-load-prime.jsonl
  <out>/warm-load-engine.jsonl
  <out>/warm-load-engine.time.log
  <out>/warm-load-summary.json
  <out>/warm-load-summary.md
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
    --db)
      DB_PATH="$2"
      shift 2
      ;;
    --out)
      OUT_DIR="$2"
      shift 2
      ;;
    --query)
      QUERY="$2"
      shift 2
      ;;
    --bench-bin)
      BENCH_BIN="$2"
      shift 2
      ;;
    --skip-build)
      SKIP_BUILD=1
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
BENCH_BIN="$(abs_path "$BENCH_BIN")"

if [[ ! -f "$DB_PATH" ]]; then
  echo "Missing snapshot DB: $DB_PATH" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"

if [[ "$SKIP_BUILD" -eq 0 ]]; then
  swift build -c release --product ScopyBench > "$OUT_DIR/scopybench.build.log" 2>&1
fi

if [[ ! -x "$BENCH_BIN" ]]; then
  echo "Missing ScopyBench binary: $BENCH_BIN" >&2
  exit 1
fi

PRIME_JSON="$OUT_DIR/warm-load-prime.jsonl"
RAW_JSON="$OUT_DIR/warm-load-engine.jsonl"
TIME_LOG="$OUT_DIR/warm-load-engine.time.log"
SUMMARY_JSON="$OUT_DIR/warm-load-summary.json"
SUMMARY_MD="$OUT_DIR/warm-load-summary.md"

COMMON_ARGS=(
  --layer engine
  --db "$DB_PATH"
  --mode "$MODE"
  --sort "$SORT"
  --query "$QUERY"
  --iters 1
  --warmup 0
  --json
)

if [[ "$FORCE_FULL_FUZZY" -eq 1 ]]; then
  COMMON_ARGS+=(--force-full-fuzzy)
fi

"$BENCH_BIN" "${COMMON_ARGS[@]}" --label "warm-load:prime" > "$PRIME_JSON"
/usr/bin/time -l "$BENCH_BIN" "${COMMON_ARGS[@]}" --label "warm-load:engine" > "$RAW_JSON" 2> "$TIME_LOG"

python3 - "$DB_PATH" "$QUERY" "$RAW_JSON" "$TIME_LOG" "$SUMMARY_JSON" "$SUMMARY_MD" <<'PY'
import json
import re
import sys
from datetime import datetime, timezone

db_path = sys.argv[1]
query = sys.argv[2]
raw_json_path = sys.argv[3]
time_log_path = sys.argv[4]
summary_json_path = sys.argv[5]
summary_md_path = sys.argv[6]

with open(raw_json_path, "r", encoding="utf-8") as f:
    raw_line = next((line.strip() for line in f if line.strip()), "")
if not raw_line:
    raise SystemExit("warm-load JSON output is empty")

payload = json.loads(raw_line)
warm_load_ms = float(payload.get("p95_ms"))
db_bytes = payload.get("db_bytes")
db_item_count = payload.get("db_item_count")

with open(time_log_path, "r", encoding="utf-8") as f:
    time_text = f.read()

match = re.search(r"^\s*(\d+)\s+maximum resident set size$", time_text, re.MULTILINE)
if not match:
    raise SystemExit("failed to parse maximum resident set size from time output")

peak_rss_bytes = int(match.group(1))
peak_rss_kb = peak_rss_bytes / 1024.0
peak_rss_mb = peak_rss_bytes / (1024.0 * 1024.0)

summary = {
    "generated_at": datetime.now(timezone.utc).isoformat(),
    "db_path": db_path,
    "db_bytes": db_bytes,
    "db_item_count": db_item_count,
    "query": query,
    "mode": payload.get("request", {}).get("mode"),
    "sort": payload.get("request", {}).get("sort"),
    "force_full_fuzzy": payload.get("request", {}).get("forceFullFuzzy"),
    "warm_load_ms": warm_load_ms,
    "peak_rss_bytes": peak_rss_bytes,
    "peak_rss_kb": peak_rss_kb,
    "peak_rss_mb": peak_rss_mb,
    "raw_json_path": raw_json_path,
    "time_log_path": time_log_path,
}

with open(summary_json_path, "w", encoding="utf-8") as f:
    json.dump(summary, f, ensure_ascii=False, indent=2)

md_lines = [
    "# Search Warm-Load Summary",
    "",
    f"- Generated at: {summary['generated_at']}",
    f"- DB: `{db_path}`",
    f"- Query: `{query}`",
    f"- Mode: `{summary['mode']}`",
    f"- Sort: `{summary['sort']}`",
    f"- Force full fuzzy: `{summary['force_full_fuzzy']}`",
    f"- Warm-load latency: `{warm_load_ms:.3f} ms`",
    f"- Peak RSS: `{peak_rss_mb:.2f} MB` ({peak_rss_bytes} bytes)",
]
if isinstance(db_bytes, int):
    md_lines.append(f"- DB bytes: `{db_bytes}`")
if isinstance(db_item_count, int):
    md_lines.append(f"- DB items: `{db_item_count}`")

with open(summary_md_path, "w", encoding="utf-8") as f:
    f.write("\n".join(md_lines) + "\n")

print(summary_json_path)
print(summary_md_path)
PY

echo "Warm-load summary JSON: $SUMMARY_JSON"
echo "Warm-load summary MD:   $SUMMARY_MD"
