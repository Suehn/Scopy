#!/bin/bash
# Run a reproducible performance audit locally (bench + perf tests).
#
# This script is designed to be:
# - repeatable: stable queries + warmup/iters
# - scriptable: JSONL outputs for ScopyBench
# - non-invasive: no code paths changed at runtime unless env-gated in tests

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BENCH_DB_DEFAULT="${PROJECT_DIR}/perf-db/clipboard.db"
OUT_DIR_DEFAULT="${PROJECT_DIR}/logs/perf-audit-$(date +"%Y-%m-%d_%H-%M-%S")"

BENCH_DB="${BENCH_DB_DEFAULT}"
SNAPSHOT_DB=""
OUT_DIR="${OUT_DIR_DEFAULT}"
WARMUP=20
ITERS=30
SKIP_TESTS=0
SKIP_BENCH=0
RUN_STRICT=0
RUN_TSAN=0
RUN_HEAVY=0
BENCH_METRICS=0

cd "${PROJECT_DIR}"

failure_trap() {
    local code=$?
    echo "FAILED (exit ${code}). Output dir: ${OUT_DIR:-<unset>}" >&2
}
trap failure_trap ERR

print_help() {
    cat <<EOF
Scopy performance audit (local).

Usage:
  bash scripts/perf-audit.sh [options]

Options:
  --bench-db <path>        DB for ScopyBench (default: ${BENCH_DB_DEFAULT})
  --snapshot-db <path>     DB for SnapshotPerformanceTests (default: same as --bench-db)
  --out <dir>              Output directory (default: ${OUT_DIR_DEFAULT})
  --warmup <n>             Bench warmup iterations (default: ${WARMUP})
  --iters <n>              Bench iterations (default: ${ITERS})
  --skip-tests             Skip xcodebuild perf/snapshot perf tests
  --skip-bench             Skip ScopyBench JSON runs
  --bench-metrics          Also run ScopyBench with SCOPY_PERF_METRICS=1 (phase/counter sample)
  --strict                 Also run Strict Concurrency regression (make test-strict)
  --tsan                   Also run Thread Sanitizer regression (make test-tsan)
  --heavy                  Also run heavy perf tests (make test-perf-heavy)
  -h, --help               Show help

Outputs:
  - ScopyBench JSONL: <out>/scopybench.jsonl
  - Logs: <out>/*.log
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --bench-db)
            BENCH_DB="${2:-}"
            shift 2
            ;;
        --snapshot-db)
            SNAPSHOT_DB="${2:-}"
            shift 2
            ;;
        --out)
            OUT_DIR="${2:-}"
            shift 2
            ;;
        --warmup)
            WARMUP="${2:-}"
            shift 2
            ;;
        --iters)
            ITERS="${2:-}"
            shift 2
            ;;
        --skip-tests)
            SKIP_TESTS=1
            shift 1
            ;;
        --skip-bench)
            SKIP_BENCH=1
            shift 1
            ;;
        --bench-metrics)
            BENCH_METRICS=1
            shift 1
            ;;
        --strict)
            RUN_STRICT=1
            shift 1
            ;;
        --tsan)
            RUN_TSAN=1
            shift 1
            ;;
        --heavy)
            RUN_HEAVY=1
            shift 1
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        *)
            echo "Unknown argument: $1" >&2
            echo "" >&2
            print_help >&2
            exit 2
            ;;
    esac
done

if [[ -z "${BENCH_DB}" ]]; then
    echo "Error: --bench-db must not be empty" >&2
    exit 2
fi

if [[ -z "${SNAPSHOT_DB}" ]]; then
    SNAPSHOT_DB="${BENCH_DB}"
fi

mkdir -p "${OUT_DIR}"

{
    echo "timestamp: $(date -Iseconds)"
    echo "pwd: ${PROJECT_DIR}"
    echo "bench_db: ${BENCH_DB}"
    echo "snapshot_db: ${SNAPSHOT_DB}"
    echo ""
    echo "sw_vers:"
    sw_vers || true
    echo ""
    echo "xcodebuild -version:"
    xcodebuild -version || true
    echo ""
    echo "swiftc --version:"
    xcrun --sdk macosx swiftc --version || true
    echo ""
    echo "hardware:"
    sysctl -n machdep.cpu.brand_string 2>/dev/null || true
    sysctl -n hw.memsize 2>/dev/null || true
} > "${OUT_DIR}/env.txt"

echo "Output dir: ${OUT_DIR}"

if [[ "${SKIP_TESTS}" -eq 0 ]]; then
    echo "Running build + unit tests..."
    make LOG_DIR="${OUT_DIR}" build > "${OUT_DIR}/build.log" 2>&1
    make LOG_DIR="${OUT_DIR}" test-unit

    if [[ "${RUN_STRICT}" -eq 1 ]]; then
        make LOG_DIR="${OUT_DIR}" test-strict
    fi
    if [[ "${RUN_TSAN}" -eq 1 ]]; then
        make LOG_DIR="${OUT_DIR}" test-tsan
    fi

    echo "Running perf tests..."
    if [[ "${RUN_HEAVY}" -eq 1 ]]; then
        make LOG_DIR="${OUT_DIR}" test-perf-heavy
    else
        make LOG_DIR="${OUT_DIR}" test-perf
    fi

    echo "Running snapshot perf tests..."
    SCOPY_SNAPSHOT_DB_PATH="${SNAPSHOT_DB}" make LOG_DIR="${OUT_DIR}" test-snapshot-perf
fi

if [[ "${SKIP_BENCH}" -eq 0 ]]; then
    if [[ ! -f "${BENCH_DB}" ]]; then
        echo "Error: bench db not found: ${BENCH_DB}" >&2
        exit 1
    fi

    echo "Building ScopyBench (release)..."
    swift build -c release --product ScopyBench > "${OUT_DIR}/scopybench.build.log" 2>&1
    BENCH_BIN="${PROJECT_DIR}/.build/release/ScopyBench"
    if [[ ! -x "${BENCH_BIN}" ]]; then
        echo "Error: ScopyBench binary not found: ${BENCH_BIN}" >&2
        exit 1
    fi

    echo "Running ScopyBench (release)..."
    BENCH_OUT="${OUT_DIR}/scopybench.jsonl"
    : > "${BENCH_OUT}"

    run_bench() {
        local label="$1"
        local mode="$2"
        local sort="$3"
        local query="$4"
        local force="${5:-0}"

        if [[ "${force}" -eq 1 ]]; then
            "${BENCH_BIN}" \
                --layer engine \
                --db "${BENCH_DB}" \
                --label "${label}" \
                --mode "${mode}" \
                --sort "${sort}" \
                --query "${query}" \
                --iters "${ITERS}" \
                --warmup "${WARMUP}" \
                --json \
                --force-full-fuzzy >> "${BENCH_OUT}"
            return
        fi

        "${BENCH_BIN}" \
            --layer engine \
            --db "${BENCH_DB}" \
            --label "${label}" \
            --mode "${mode}" \
            --sort "${sort}" \
            --query "${query}" \
            --iters "${ITERS}" \
            --warmup "${WARMUP}" \
            --json >> "${BENCH_OUT}"
    }

    run_bench "snapshot:fuzzyPlus:relevance:cm" "fuzzyPlus" "relevance" "cm" 0
    run_bench "snapshot:fuzzyPlus:relevance:数学" "fuzzyPlus" "relevance" "数学" 0
    run_bench "snapshot:fuzzyPlus:relevance:cmd" "fuzzyPlus" "relevance" "cmd" 0
    run_bench "snapshot:fuzzyPlus:relevance:cm:forceFullFuzzy" "fuzzyPlus" "relevance" "cm" 1
    run_bench "snapshot:fuzzy:relevance:abc:forceFullFuzzy" "fuzzy" "relevance" "abc" 1
    run_bench "snapshot:fuzzy:relevance:cmd:forceFullFuzzy" "fuzzy" "relevance" "cmd" 1

    echo "ScopyBench JSONL saved to: ${BENCH_OUT}"

    echo "Running ScopyBench (release, ClipboardService)..."
    BENCH_OUT_SERVICE="${OUT_DIR}/scopybench.service.jsonl"
    : > "${BENCH_OUT_SERVICE}"

    run_service_bench() {
        local label="$1"
        local mode="$2"
        local sort="$3"
        local query="$4"
        local force="${5:-0}"
        local no_thumbnails="${6:-0}"

        local cmd=(
            "${BENCH_BIN}"
            --layer service
            --db "${BENCH_DB}"
            --label "${label}"
            --mode "${mode}"
            --sort "${sort}"
            --query "${query}"
            --iters "${ITERS}"
            --warmup "${WARMUP}"
            --json
        )

        if [[ "${no_thumbnails}" -eq 1 ]]; then
            cmd+=(--no-thumbnails)
        fi
        if [[ "${force}" -eq 1 ]]; then
            cmd+=(--force-full-fuzzy)
        fi

        "${cmd[@]}" >> "${BENCH_OUT_SERVICE}"
    }

    run_service_bench "snapshot:service:fuzzyPlus:relevance:cm" "fuzzyPlus" "relevance" "cm" 0
    run_service_bench "snapshot:service:fuzzyPlus:relevance:数学" "fuzzyPlus" "relevance" "数学" 0
    run_service_bench "snapshot:service:fuzzyPlus:relevance:cmd" "fuzzyPlus" "relevance" "cmd" 0
    run_service_bench "snapshot:service:fuzzyPlus:relevance:cm:noThumb" "fuzzyPlus" "relevance" "cm" 0 1

    echo "ScopyBench service JSONL saved to: ${BENCH_OUT_SERVICE}"

    if [[ "${BENCH_METRICS}" -eq 1 ]]; then
        echo "Running ScopyBench with SCOPY_PERF_METRICS=1 (release)..."
        BENCH_OUT_METRICS="${OUT_DIR}/scopybench.metrics.jsonl"
        : > "${BENCH_OUT_METRICS}"

        run_bench_metrics() {
            local label="$1"
            local mode="$2"
            local sort="$3"
            local query="$4"
            local force="${5:-0}"

            if [[ "${force}" -eq 1 ]]; then
                SCOPY_PERF_METRICS=1 "${BENCH_BIN}" \
                    --layer engine \
                    --db "${BENCH_DB}" \
                    --label "${label}" \
                    --mode "${mode}" \
                    --sort "${sort}" \
                    --query "${query}" \
                    --iters "${ITERS}" \
                    --warmup "${WARMUP}" \
                    --json \
                    --force-full-fuzzy >> "${BENCH_OUT_METRICS}"
                return
            fi

            SCOPY_PERF_METRICS=1 "${BENCH_BIN}" \
                --layer engine \
                --db "${BENCH_DB}" \
                --label "${label}" \
                --mode "${mode}" \
                --sort "${sort}" \
                --query "${query}" \
                --iters "${ITERS}" \
                --warmup "${WARMUP}" \
                --json >> "${BENCH_OUT_METRICS}"
        }

        run_bench_metrics "snapshot:metrics:fuzzyPlus:relevance:cm" "fuzzyPlus" "relevance" "cm" 0
        run_bench_metrics "snapshot:metrics:fuzzyPlus:relevance:数学" "fuzzyPlus" "relevance" "数学" 0
        run_bench_metrics "snapshot:metrics:fuzzyPlus:relevance:cmd" "fuzzyPlus" "relevance" "cmd" 0
        run_bench_metrics "snapshot:metrics:fuzzyPlus:relevance:cm:forceFullFuzzy" "fuzzyPlus" "relevance" "cm" 1

        echo "ScopyBench metrics JSONL saved to: ${BENCH_OUT_METRICS}"
    fi
fi

echo "Done."
