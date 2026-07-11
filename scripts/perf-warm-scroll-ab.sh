#!/bin/bash
# Deterministic Release micro A/B for one or both selected warm-scroll axes. `--axis all`
# is the formal path: both 5-pair axes reuse one build-for-testing product and therefore
# one byte-exact app/UI-test/xctestrun artifact set across all 20 raw runs.

set -eEuo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OUT_DIR="$PROJECT_DIR/logs/perf-warm-scroll-$(date +"%Y-%m-%d_%H-%M-%S")"
REPEATS=5
COMMANDS=1440
STEP_PX=36
WARM_ROUNDS=2
MAX_SAMPLES=131072
MIN_SAMPLES=120
MIN_DIAGNOSTIC_COMMANDS=60
PROFILE_DURATION=12
DESTINATION="platform=macOS"
SKIP_SETUP=0
SELF_TEST=0
AXIS="all"
DATASET_ID="fixed-warm-text-v1"
MANIFEST_TOOL="$PROJECT_DIR/scripts/quality/source-manifest.py"
SUMMARY_TOOL="$PROJECT_DIR/scripts/quality/summarize-warm-scroll-ab.py"
XCODEBUILD_BIN="${SCOPY_XCODEBUILD_BIN:-xcodebuild}"
ORIGINAL_ARGUMENTS=("$@")

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --repeats) REPEATS="$2"; shift 2 ;;
    --commands) COMMANDS="$2"; shift 2 ;;
    --axis) AXIS="$2"; shift 2 ;;
    --skip-setup) SKIP_SETUP=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    -h|--help)
      echo "Usage: bash scripts/perf-warm-scroll-ab.sh [--axis all|passive-row|markdown-menu-cache] [--out DIR] [--repeats N] [--commands N] [--skip-setup] [--self-test]"
      echo "Default: --axis all (formal shared-build 20-run evidence); single-axis modes are diagnostic."
      echo "Diagnostic runs require at least $MIN_DIAGNOSTIC_COMMANDS commands and validate provenance/workload without enforcing formal improvement thresholds."
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$AXIS" in
  passive-row|markdown-menu-cache) AXES_TO_RUN=("$AXIS") ;;
  all) AXES_TO_RUN=("passive-row" "markdown-menu-cache") ;;
  *) echo "Unsupported axis: $AXIS" >&2; exit 2 ;;
esac

runner_contract_check() {
  local description="$1"
  shift
  if ! "$@"; then
    echo "warm-scroll runner self-test failed: $description" >&2
    return 1
  fi
  (( runner_contract_check_count += 1 ))
}

runner_body_has() {
  grep -Fq -- "$1" <<<"$runner_contract_body"
}

runner_contract_self_test() {
  local build_calls test_calls xcodebuild_manifest_calls mock_setup_gate
  local runner_contract_body runner_contract_check_count=0
  runner_contract_body="$(awk '
    /^runner_contract_check\(\)/ { self_test_helpers = 1 }
    /^if \(\( SELF_TEST == 1 \)\); then$/ { self_test_helpers = 0 }
    !self_test_helpers { print }
  ' "$0")"
  runner_contract_check "shell syntax" bash -n "$0" || return 1
  runner_contract_check "source manifest fixtures" \
    python3 "$MANIFEST_TOOL" self-test >/dev/null || return 1
  runner_contract_check "summary fixtures" \
    python3 "$SUMMARY_TOOL" self-test >/dev/null || return 1
  build_calls="$(awk 'index($0, "\"$XCODEBUILD_BIN\" -quiet build-for-" "testing") { count += 1 } END { print count + 0 }' <<<"$runner_contract_body")"
  test_calls="$(awk 'index($0, "\"$XCODEBUILD_BIN\" -quiet test-without-" "building") { count += 1 } END { print count + 0 }' <<<"$runner_contract_body")"
  runner_contract_check "one shared build-for-testing" test "$build_calls" = "1" || return 1
  runner_contract_check "one test-without-building call site" test "$test_calls" = "1" || return 1
  runner_contract_check "both formal axes" runner_body_has \
    'AXES_TO_RUN=("passive-row" "markdown-menu-cache")' || return 1
  runner_contract_check "preserve original failure" runner_body_has \
    'final_status="$original_status"' || return 1
  xcodebuild_manifest_calls="$(grep -Fc -- '--xcodebuild-bin "$XCODEBUILD_BIN"' <<<"$runner_contract_body")"
  runner_contract_check "capture and recapture selected Xcode tool" \
    test "$xcodebuild_manifest_calls" = "3" || return 1
  runner_contract_check "stamp raw run" runner_body_has \
    'stamp-run --manifest "$SOURCE_MANIFEST" --run "$expected"' || return 1
  runner_contract_check "preliminary summary flag" runner_body_has \
    'run_summaries "before-final-source-verification" 1' || return 1
  runner_contract_check "strict final summary" runner_body_has \
    'run_summaries "final" 0' || return 1
  runner_contract_check "single-axis summaries are diagnostic" runner_body_has \
    'summary_arguments+=(--diagnostic)' || return 1
  runner_contract_check "retain per-run xcresult evidence" runner_body_has \
    '-resultBundlePath "$result_bundle"' || return 1
  runner_contract_check "source build stage" runner_body_has \
    'verify_source "build-after"' || return 1
  runner_contract_check "source run stage" runner_body_has \
    'verify_source "run-after"' || return 1
  runner_contract_check "source summary stage" runner_body_has \
    'verify_source "summary-after"' || return 1
  runner_contract_check "build artifact build stage" runner_body_has \
    'verify_build "build-after"' || return 1
  runner_contract_check "build artifact run stage" runner_body_has \
    'verify_build "run-after"' || return 1
  runner_contract_check "build artifact summary stage" runner_body_has \
    'verify_build "summary-after"' || return 1
  runner_contract_check "build version arguments injected" runner_body_has \
    '"${VERSION_ARGUMENTS[@]}"' || return 1
  runner_contract_check "runner arguments recorded" runner_body_has \
    '--effective-runner-arguments-json "$EFFECTIVE_RUNNER_ARGUMENTS_JSON"' || return 1
  runner_contract_check "original arguments recorded" runner_body_has \
    '--runner-arguments-json "$RUNNER_ARGUMENTS_JSON"' || return 1
  runner_contract_check "version arguments recorded" runner_body_has \
    '--version-arguments-json "$VERSION_ARGUMENTS_JSON"' || return 1
  runner_contract_check "version arguments resolved from repository policy" runner_body_has \
    'scripts/version.sh" --xcodebuild-args' || return 1
  mock_setup_gate="$(awk '
    /override func setUp\(\) async throws/ { in_setup = 1 }
    in_setup && /app\.launchEnvironment\["USE_MOCK_SERVICE"\] = "1"/ { gate = 1 }
    in_setup && /app\.launch\(\)/ { found = 1; result = gate; exit }
    END { print (found && result ? 1 : 0) }
  ' "$PROJECT_DIR/ScopyUITests/HistoryListUITests.swift")"
  runner_contract_check "setUp uses mock service before first launch" \
    test "$mock_setup_gate" = "1" || return 1
  echo "warm-scroll runner self-test: $runner_contract_check_count checks passed"
}

if (( SELF_TEST == 1 )); then
  runner_contract_self_test
  exit 0
fi

if ! [[ "$REPEATS" =~ ^[0-9]+$ ]] || (( REPEATS < 2 )); then
  echo "--repeats must be an integer >= 2 so both AB and BA orders are exercised" >&2
  exit 2
fi
if ! [[ "$COMMANDS" =~ ^[0-9]+$ ]] || (( COMMANDS < MIN_DIAGNOSTIC_COMMANDS )); then
  echo "--commands must be an integer >= $MIN_DIAGNOSTIC_COMMANDS so the UI profile can satisfy its minimum callback contract" >&2
  exit 2
fi
if [[ "$AXIS" == "all" ]] && (( REPEATS < 5 || COMMANDS != 1440 )); then
  echo "Formal --axis all evidence requires --repeats >= 5 and --commands 1440" >&2
  exit 2
fi
EFFECTIVE_MIN_SAMPLES="$MIN_SAMPLES"
if (( COMMANDS < EFFECTIVE_MIN_SAMPLES )); then
  EFFECTIVE_MIN_SAMPLES="$COMMANDS"
fi
if (( COMMANDS < 720 )); then PROFILE_DURATION=6; fi

if [[ "$OUT_DIR" != /* ]]; then OUT_DIR="$PROJECT_DIR/$OUT_DIR"; fi
mkdir -p "$OUT_DIR/logs"

json_string_array() {
  python3 - "$@" <<'PY'
import json
import sys

print(json.dumps(sys.argv[1:], separators=(",", ":")))
PY
}

VERSION_ARGUMENTS_TEXT="$(bash "$PROJECT_DIR/scripts/version.sh" --xcodebuild-args)"
read -r -a VERSION_ARGUMENTS <<<"$VERSION_ARGUMENTS_TEXT"
if (( ${#VERSION_ARGUMENTS[@]} != 2 )); then
  echo "Expected MARKETING_VERSION and CURRENT_PROJECT_VERSION arguments, found: $VERSION_ARGUMENTS_TEXT" >&2
  exit 2
fi
if [[ "${VERSION_ARGUMENTS[0]}" != MARKETING_VERSION=* ]] || \
   [[ "${VERSION_ARGUMENTS[1]}" != CURRENT_PROJECT_VERSION=* ]]; then
  echo "Invalid build version arguments: $VERSION_ARGUMENTS_TEXT" >&2
  exit 2
fi
EFFECTIVE_RUNNER_ARGUMENTS=(
  --axis "$AXIS"
  --out "$OUT_DIR"
  --repeats "$REPEATS"
  --commands "$COMMANDS"
  --step-px "$STEP_PX"
  --warm-rounds "$WARM_ROUNDS"
  --max-samples "$MAX_SAMPLES"
  --min-samples "$EFFECTIVE_MIN_SAMPLES"
  --profile-duration "$PROFILE_DURATION"
  --destination "$DESTINATION"
  --skip-setup "$SKIP_SETUP"
  --xcodebuild-bin "$XCODEBUILD_BIN"
)
RUNNER_ARGUMENTS_JSON="$(json_string_array "${ORIGINAL_ARGUMENTS[@]}")"
EFFECTIVE_RUNNER_ARGUMENTS_JSON="$(json_string_array "${EFFECTIVE_RUNNER_ARGUMENTS[@]}")"
VERSION_ARGUMENTS_JSON="$(json_string_array "${VERSION_ARGUMENTS[@]}")"

RUNNER_OUTPUT_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/scopy-warm-scroll.XXXXXX")"
DERIVED_DATA="$RUNNER_OUTPUT_ROOT/DerivedData"
SOURCE_MANIFEST="$OUT_DIR/source-manifest.json"
SOURCE_FINGERPRINT=""
EXECUTABLE_FINGERPRINT=""
APP_EXECUTABLE=""
UI_TEST_EXECUTABLE=""
XCTESTRUN_PATH=""

axis_output_dir() {
  local axis="$1"
  if [[ "$AXIS" == "all" ]]; then
    echo "$OUT_DIR/$axis"
  else
    echo "$OUT_DIR"
  fi
}

prepare_axis_directories() {
  local axis axis_dir
  for axis in "${AXES_TO_RUN[@]}"; do
    axis_dir="$(axis_output_dir "$axis")"
    mkdir -p "$axis_dir/raw/baseline" "$axis_dir/raw/current" "$axis_dir/logs"
  done
}

terminate_scopy() {
  osascript -e 'tell application id "com.scopy.app" to quit' >/dev/null 2>&1 || true
  sleep 1
  pkill -x Scopy >/dev/null 2>&1 || true
}

verify_source() {
  local stage="$1"
  python3 "$MANIFEST_TOOL" verify \
    --root "$PROJECT_DIR" \
    --manifest "$SOURCE_MANIFEST" \
    --stage "$stage" \
    --xcodebuild-bin "$XCODEBUILD_BIN" \
    >>"$OUT_DIR/logs/source-manifest-verifications.log" 2>&1
}

verify_build() {
  local stage="$1"
  [[ -n "$APP_EXECUTABLE" && -n "$UI_TEST_EXECUTABLE" && -n "$XCTESTRUN_PATH" ]] || return 2
  python3 "$MANIFEST_TOOL" verify-build \
    --manifest "$SOURCE_MANIFEST" \
    --app-executable "$APP_EXECUTABLE" \
    --ui-test-executable "$UI_TEST_EXECUTABLE" \
    --xctestrun "$XCTESTRUN_PATH" \
    --stage "$stage" \
    >>"$OUT_DIR/logs/build-artifact-verifications.log" 2>&1
}

copy_manifest_to_axis_directories() {
  local axis axis_dir
  for axis in "${AXES_TO_RUN[@]}"; do
    axis_dir="$(axis_output_dir "$axis")"
    if [[ "$axis_dir" != "$OUT_DIR" ]]; then
      cp "$SOURCE_MANIFEST" "$axis_dir/source-manifest.json"
    fi
  done
}

run_summaries() {
  local log_suffix="$1"
  local allow_missing_summary_after="$2"
  local axis axis_dir status=0 command_status
  local -a summary_arguments
  for axis in "${AXES_TO_RUN[@]}"; do
    axis_dir="$(axis_output_dir "$axis")"
    command_status=0
    summary_arguments=(
      summarize
      --out "$axis_dir"
      --axis "$axis"
      --repeats "$REPEATS"
      --commands "$COMMANDS"
      --step-px "$STEP_PX"
      --warm-rounds "$WARM_ROUNDS"
    )
    if (( allow_missing_summary_after == 1 )); then
      summary_arguments+=(--allow-missing-summary-after)
    fi
    if [[ "$AXIS" != "all" ]]; then
      summary_arguments+=(--diagnostic)
    fi
    python3 "$SUMMARY_TOOL" "${summary_arguments[@]}" \
      >"$OUT_DIR/logs/summarize-$axis-$log_suffix.log" 2>&1 || command_status=$?
    cat "$OUT_DIR/logs/summarize-$axis-$log_suffix.log"
    if (( command_status != 0 )); then status="$command_status"; fi
  done
  return "$status"
}

finalize_run() {
  local original_status="$1"
  local final_status="$original_status"
  local source_status=0 build_status=0 preliminary_summary_status=0 summary_status=0
  trap - EXIT
  set +e
  terminate_scopy

  if [[ -f "$SOURCE_MANIFEST" ]]; then
    verify_source "run-after"
    source_status=$?
    if [[ -n "$APP_EXECUTABLE" ]]; then
      verify_build "run-after"
      build_status=$?
    else
      build_status=1
    fi
    copy_manifest_to_axis_directories
    run_summaries "before-final-source-verification" 1
    preliminary_summary_status=$?

    verify_source "summary-after"
    if (( $? != 0 )); then source_status=1; fi
    if [[ -n "$APP_EXECUTABLE" ]]; then
      verify_build "summary-after"
      if (( $? != 0 )); then build_status=1; fi
    fi
    copy_manifest_to_axis_directories
    run_summaries "final" 0
    summary_status=$?
  else
    echo "Source manifest was not created; no formal summary is possible." >&2
    source_status=1
    build_status=1
    summary_status=1
  fi

  if (( original_status != 0 )); then
    final_status="$original_status"
  elif (( source_status != 0 || build_status != 0 || preliminary_summary_status != 0 || summary_status != 0 )); then
    final_status=1
  fi

  if (( final_status != 0 )); then
    mkdir -p "$OUT_DIR/runner-artifacts"
    cp -R "$RUNNER_OUTPUT_ROOT/runtime" "$OUT_DIR/runner-artifacts/" 2>/dev/null || true
    cp -R "$DERIVED_DATA/Logs/Test" "$OUT_DIR/runner-artifacts/TestLogs" 2>/dev/null || true
    echo "Warm A/B gate failed with status $final_status; retained evidence: $OUT_DIR" >&2
  elif [[ "$AXIS" == "all" ]]; then
    echo "Warm A/B gates passed: $OUT_DIR/passive-row and $OUT_DIR/markdown-menu-cache"
  else
    echo "Warm A/B gate passed: $OUT_DIR/warm-scroll-ab-summary.md"
  fi
  rm -rf "$RUNNER_OUTPUT_ROOT"
  exit "$final_status"
}
trap 'finalize_run $?' EXIT

prepare_axis_directories
if [[ "$SKIP_SETUP" -eq 0 ]]; then
  bash "$PROJECT_DIR/scripts/xcodegen-generate-if-needed.sh"
fi

SOURCE_FINGERPRINT="$(python3 "$MANIFEST_TOOL" create \
  --root "$PROJECT_DIR" \
  --output "$SOURCE_MANIFEST" \
  --xcodebuild-bin "$XCODEBUILD_BIN" \
  --runner-script "scripts/perf-warm-scroll-ab.sh" \
  --runner-arguments-json "$RUNNER_ARGUMENTS_JSON" \
  --effective-runner-arguments-json "$EFFECTIVE_RUNNER_ARGUMENTS_JSON" \
  --version-arguments-json "$VERSION_ARGUMENTS_JSON")"

build_status=0
"$XCODEBUILD_BIN" -quiet build-for-testing \
  -project Scopy.xcodeproj \
  -scheme ScopyWarmProfile \
  -configuration Release \
  -destination "$DESTINATION" \
  -derivedDataPath "$DERIVED_DATA" \
  "${VERSION_ARGUMENTS[@]}" \
  2>&1 | tee "$OUT_DIR/logs/build-for-testing.log" || build_status=$?
if (( build_status != 0 )); then
  echo "Release build-for-testing failed with status $build_status" >&2
  exit "$build_status"
fi

verify_source "build-after"

APP_EXECUTABLE="$DERIVED_DATA/Build/Products/Release/Scopy.app/Contents/MacOS/Scopy"
if [[ ! -f "$APP_EXECUTABLE" ]]; then
  APP_EXECUTABLE="$(find "$DERIVED_DATA/Build/Products" -type f -path '*/Scopy.app/Contents/MacOS/Scopy' -print -quit)"
fi
UI_TEST_EXECUTABLE="$(find "$DERIVED_DATA/Build/Products" -type f -path '*/ScopyUITests.xctest/Contents/MacOS/ScopyUITests' -print -quit)"
XCTESTRUN_PATH="$(find "$DERIVED_DATA/Build/Products" -type f -name '*.xctestrun' -print -quit)"
if [[ ! -f "$APP_EXECUTABLE" || ! -f "$UI_TEST_EXECUTABLE" || ! -f "$XCTESTRUN_PATH" ]]; then
  echo "Build succeeded but the app, UI-test executable, or xctestrun artifact is missing" >&2
  exit 1
fi

EXECUTABLE_FINGERPRINT="$(python3 "$MANIFEST_TOOL" record-build \
  --manifest "$SOURCE_MANIFEST" \
  --app-executable "$APP_EXECUTABLE" \
  --ui-test-executable "$UI_TEST_EXECUTABLE" \
  --xctestrun "$XCTESTRUN_PATH")"
if ! [[ "$EXECUTABLE_FINGERPRINT" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "Invalid recorded app executable fingerprint: $EXECUTABLE_FINGERPRINT" >&2
  exit 1
fi
verify_build "build-after"

run_variant() {
  local axis="$1"
  local pair="$2"
  local order="$3"
  local variant="$4"
  local passive=1 markdown_menu_cache=1 command_status=0
  local axis_dir run_id raw_dir runner_dir runner_output expected log result_bundle
  if [[ "$axis" == "passive-row" ]]; then
    if [[ "$variant" == "baseline" ]]; then passive=0; fi
  else
    if [[ "$variant" == "baseline" ]]; then markdown_menu_cache=0; fi
  fi
  axis_dir="$(axis_output_dir "$axis")"
  run_id="pair$(printf '%02d' "$pair")-${order}-${variant}"
  raw_dir="$axis_dir/raw/$variant"
  runner_dir="$RUNNER_OUTPUT_ROOT/runtime/$axis/$variant"
  runner_output="$runner_dir/fixed-warm-text-$run_id.json"
  expected="$raw_dir/fixed-warm-text-$run_id.json"
  log="$OUT_DIR/logs/$axis-$run_id.log"
  result_bundle="$RUNNER_OUTPUT_ROOT/runtime/xcresults/$axis-$run_id.xcresult"
  mkdir -p "$runner_dir"
  mkdir -p "$(dirname "$result_bundle")"
  rm -f "$runner_output" "$expected"
  rm -rf "$result_bundle"
  terminate_scopy
  verify_source "before-$axis-$run_id"
  verify_build "before-$axis-$run_id"

  env \
    SCOPY_MOCK_DATASET_ID="$DATASET_ID" \
    TEST_RUNNER_SCOPY_RUN_PROFILE_UI_TESTS=1 \
    TEST_RUNNER_SCOPY_UI_PROFILE_OUTPUT_DIR="$runner_dir" \
    TEST_RUNNER_SCOPY_UI_PROFILE_RUN_ID="$run_id" \
    TEST_RUNNER_SCOPY_UI_PROFILE_DURATION_SEC="$PROFILE_DURATION" \
    TEST_RUNNER_SCOPY_UI_PROFILE_MIN_SAMPLES="$EFFECTIVE_MIN_SAMPLES" \
    TEST_RUNNER_SCOPY_PROFILE_SKIP_AX_LIST_QUERY=1 \
    TEST_RUNNER_SCOPY_MOCK_DATASET_ID="$DATASET_ID" \
    TEST_RUNNER_SCOPY_PROFILE_SOURCE_FINGERPRINT="$SOURCE_FINGERPRINT" \
    TEST_RUNNER_SCOPY_PROFILE_EXECUTABLE_FINGERPRINT="$EXECUTABLE_FINGERPRINT" \
    TEST_RUNNER_SCOPY_PROFILE_MAX_SAMPLES="$MAX_SAMPLES" \
    TEST_RUNNER_SCOPY_PERF_PASSIVE_ROW="$passive" \
    TEST_RUNNER_SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE="$markdown_menu_cache" \
    TEST_RUNNER_SCOPY_PROFILE_FIXED_COMMAND_COUNT="$COMMANDS" \
    TEST_RUNNER_SCOPY_PROFILE_WARM_ROUNDS="$WARM_ROUNDS" \
    TEST_RUNNER_SCOPY_PROFILE_AUTO_SCROLL_STEP_PX="$STEP_PX" \
    TEST_RUNNER_SCOPY_PERF_HISTORY_INDEX=1 \
    TEST_RUNNER_SCOPY_PERF_SCROLL_RESOLVER_CACHE=1 \
    TEST_RUNNER_SCOPY_PERF_MARKDOWN_RESOLVER_CACHE=1 \
    TEST_RUNNER_SCOPY_PERF_PREVIEW_TASK_BUDGET=1 \
    TEST_RUNNER_SCOPY_PERF_SHORT_QUERY_DEBOUNCE=1 \
    "$XCODEBUILD_BIN" -quiet test-without-building \
      -xctestrun "$XCTESTRUN_PATH" \
      -destination "$DESTINATION" \
      -only-testing:ScopyUITests/HistoryListUITests/testScrollProfileFixedWarmText \
      -resultBundlePath "$result_bundle" \
      2>&1 | tee "$log" || command_status=$?

  if [[ -f "$runner_output" ]]; then
    cp "$runner_output" "$expected"
    if ! python3 "$MANIFEST_TOOL" stamp-run --manifest "$SOURCE_MANIFEST" --run "$expected" \
      >>"$OUT_DIR/logs/source-manifest-verifications.log" 2>&1; then
      echo "Failed to stamp profile environment: $expected" >&2
      return 1
    fi
  fi
  verify_source "after-$axis-$run_id"
  verify_build "after-$axis-$run_id"
  if (( command_status != 0 )); then
    echo "Profile command failed for $axis/$run_id with status $command_status" >&2
    return "$command_status"
  fi
  if [[ ! -f "$expected" ]]; then
    echo "Missing profile: $runner_output" >&2
    return 1
  fi
}

echo "Deterministic warm A/B axis=$AXIS source=$SOURCE_FINGERPRINT executable=$EXECUTABLE_FINGERPRINT output=$OUT_DIR"
for axis in "${AXES_TO_RUN[@]}"; do
  for pair in $(seq 1 "$REPEATS"); do
    if (( pair % 2 == 1 )); then
      order="AB"
      run_variant "$axis" "$pair" "$order" baseline
      run_variant "$axis" "$pair" "$order" current
    else
      order="BA"
      run_variant "$axis" "$pair" "$order" current
      run_variant "$axis" "$pair" "$order" baseline
    fi
  done
done
