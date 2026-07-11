#!/usr/bin/env python3
"""Validate and summarize Scopy's deterministic warm-scroll A/B evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import statistics
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable


AXES = ("passive-row", "markdown-menu-cache")
FORMAL_MIN_REPEATS = 5
FORMAL_COMMANDS = 1_440
DIAGNOSTIC_MIN_REPEATS = 2
DIAGNOSTIC_MIN_COMMANDS = 60
FIXED_ITEMS = 50
FIXED_TEXT_BYTES = 4_096
FIXED_PINNED = 2
FIXED_STEP_PX = 36.0
FIXED_WARM_ROUNDS = 2
FIXED_DATASET_ID = "fixed-warm-text-v1"
FIXED_DATASET_SCHEMA = "history-profile-dataset-v1"
SOURCE_MANIFEST_SCHEMA = "scopy-source-manifest-v1"
BUILD_ARTIFACT_SCHEMA = "scopy-profile-build-artifacts-v1"
ENVIRONMENT_SCHEMA = "scopy-profile-environment-v1"
SUITE_SCHEMA = "scopy-profile-suite-v1"
VCS_SCHEMA = "scopy-profile-vcs-v1"
ENVIRONMENT_HASH_DOMAIN = (ENVIRONMENT_SCHEMA + "\0").encode("utf-8")
SUITE_HASH_DOMAIN = (SUITE_SCHEMA + "\0").encode("utf-8")
VCS_HASH_DOMAIN = (VCS_SCHEMA + "\0").encode("utf-8")
SHA256_PATTERN = re.compile(r"^sha256:[0-9a-f]{64}$")
RUN_NAME_PATTERN = re.compile(
    r"^fixed-warm-text-pair(?P<pair>[0-9]+)-(?P<order>AB|BA)-(?P<variant>baseline|current)\.json$"
)

REQUIRED_COUNTERS = (
    "interaction.session_init",
    "interaction.observer_install",
    "interaction.idle_disappear_fast_path",
    "row.descriptor_cache_hit",
    "row.descriptor_cache_miss",
    "row.relative_time_cache_hit",
    "row.relative_time_cache_miss",
    "list.load_more_attempt",
    "list.pagination_request",
    "row.markdown_menu_signal_cache_hit",
    "row.markdown_menu_signal_cache_miss",
    "row.markdown_menu_signal_uncached",
    "profile.ingress_coalesced",
    "profile.ingress_dropped",
)
REQUIRED_GAUGES = (
    "active_slot_max",
    "suppressed_candidate_max",
)
FIXED_ENABLED_FLAGS = (
    "SCOPY_PERF_HISTORY_INDEX",
    "SCOPY_PERF_SCROLL_RESOLVER_CACHE",
    "SCOPY_PERF_MARKDOWN_RESOLVER_CACHE",
    "SCOPY_PERF_PREVIEW_TASK_BUDGET",
    "SCOPY_PERF_SHORT_QUERY_DEBOUNCE",
)


class SummaryValidationError(RuntimeError):
    pass


def _mapping(value: Any, label: str, errors: list[str]) -> dict[str, Any]:
    if isinstance(value, dict):
        return value
    errors.append(f"{label}: expected object")
    return {}


def _number(mapping: dict[str, Any], key: str, label: str, errors: list[str]) -> float:
    if key not in mapping:
        errors.append(f"{label}: missing required field {key}")
        return 0.0
    value = mapping[key]
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(float(value)):
        errors.append(f"{label}.{key}: expected finite number")
        return 0.0
    return float(value)


def _integer(mapping: dict[str, Any], key: str, label: str, errors: list[str]) -> int:
    value = _number(mapping, key, label, errors)
    if not value.is_integer():
        errors.append(f"{label}.{key}: expected integer")
    return int(value)


def _string(mapping: dict[str, Any], key: str, label: str, errors: list[str]) -> str:
    if key not in mapping:
        errors.append(f"{label}: missing required field {key}")
        return ""
    value = mapping[key]
    if not isinstance(value, str) or not value:
        errors.append(f"{label}.{key}: expected non-empty string")
        return ""
    return value


def _environment_fingerprint(environment: dict[str, Any]) -> str:
    canonical_payload = {key: value for key, value in environment.items() if key != "fingerprint"}
    canonical = json.dumps(
        canonical_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(ENVIRONMENT_HASH_DOMAIN + canonical).hexdigest()


def _suite_fingerprint(suite: dict[str, Any]) -> str:
    canonical_payload = {key: value for key, value in suite.items() if key != "fingerprint"}
    canonical = json.dumps(
        canonical_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(SUITE_HASH_DOMAIN + canonical).hexdigest()


def _vcs_fingerprint(vcs: dict[str, Any]) -> str:
    canonical_payload = {key: value for key, value in vcs.items() if key != "fingerprint"}
    canonical = json.dumps(
        canonical_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(VCS_HASH_DOMAIN + canonical).hexdigest()


def _string_array(
    value: Any,
    label: str,
    errors: list[str],
    *,
    allow_empty: bool,
) -> list[str]:
    if not isinstance(value, list) or (not allow_empty and not value) or any(
        not isinstance(item, str) or not item for item in value
    ):
        errors.append(f"{label}: expected {'string array' if allow_empty else 'non-empty string array'}")
        return []
    return value


def _validate_environment(value: Any, label: str, errors: list[str]) -> dict[str, Any]:
    environment = _mapping(value, label, errors)
    if environment.get("schema") != ENVIRONMENT_SCHEMA:
        errors.append(f"{label}.schema: expected {ENVIRONMENT_SCHEMA}")
    fingerprint = _string(environment, "fingerprint", label, errors)
    if fingerprint and not SHA256_PATTERN.fullmatch(fingerprint):
        errors.append(f"{label}.fingerprint: invalid SHA-256")
    if fingerprint and fingerprint != _environment_fingerprint(environment):
        errors.append(f"{label}.fingerprint: does not match canonical environment fields")

    for section_name, fields in (
        ("macos", ("product_name", "product_version", "build_version")),
        ("hardware", ("architecture", "model", "chip")),
        ("xcode", ("version", "build_version", "developer_dir", "tool_path")),
        ("sdk", ("name", "version", "build_version", "path", "tool_path")),
        ("xcodegen", ("path", "version")),
    ):
        section = _mapping(environment.get(section_name), f"{label}.{section_name}", errors)
        for field in fields:
            _string(section, field, f"{label}.{section_name}", errors)
    hardware = _mapping(environment.get("hardware"), f"{label}.hardware", errors)
    memory = hardware.get("physical_memory_bytes")
    if not ((isinstance(memory, int) and not isinstance(memory, bool) and memory > 0) or memory == "unavailable"):
        errors.append(
            f"{label}.hardware.physical_memory_bytes: expected positive integer or unavailable"
        )
    for section_name, argument_fields in (
        ("xcode", ("version_arguments",)),
        ("sdk", ("version_arguments", "build_version_arguments", "path_arguments")),
        ("xcodegen", ("version_arguments",)),
    ):
        section = _mapping(environment.get(section_name), f"{label}.{section_name}", errors)
        for field in argument_fields:
            _string_array(
                section.get(field),
                f"{label}.{section_name}.{field}",
                errors,
                allow_empty=False,
            )
    return environment


def _validate_suite(value: Any, label: str, errors: list[str]) -> dict[str, Any]:
    suite = _mapping(value, label, errors)
    if suite.get("schema") != SUITE_SCHEMA:
        errors.append(f"{label}.schema: expected {SUITE_SCHEMA}")
    fingerprint = _string(suite, "fingerprint", label, errors)
    if fingerprint and not SHA256_PATTERN.fullmatch(fingerprint):
        errors.append(f"{label}.fingerprint: invalid SHA-256")
    if fingerprint and fingerprint != _suite_fingerprint(suite):
        errors.append(f"{label}.fingerprint: does not match canonical suite fields")
    for field in ("captured_at_utc", "captured_at_local", "local_timezone"):
        _string(suite, field, label, errors)
    vcs = _mapping(suite.get("vcs"), f"{label}.vcs", errors)
    if vcs.get("schema") != VCS_SCHEMA:
        errors.append(f"{label}.vcs.schema: expected {VCS_SCHEMA}")
    vcs_fingerprint = _string(vcs, "fingerprint", f"{label}.vcs", errors)
    if vcs_fingerprint and not SHA256_PATTERN.fullmatch(vcs_fingerprint):
        errors.append(f"{label}.vcs.fingerprint: invalid SHA-256")
    if vcs_fingerprint and vcs_fingerprint != _vcs_fingerprint(vcs):
        errors.append(f"{label}.vcs.fingerprint: does not match canonical VCS fields")
    for field in ("head", "exact_tag", "nearest_tag"):
        _string(vcs, field, f"{label}.vcs", errors)
    if vcs.get("head") == "unavailable":
        errors.append(f"{label}.vcs.head: unavailable is not valid formal evidence")
    if not isinstance(vcs.get("dirty"), bool) and vcs.get("dirty") != "unavailable":
        errors.append(f"{label}.vcs.dirty: expected boolean or unavailable")
    if vcs.get("dirty") == "unavailable":
        errors.append(f"{label}.vcs.dirty: unavailable is not valid formal evidence")
    status_count = vcs.get("status_entry_count")
    if not (
        (isinstance(status_count, int) and not isinstance(status_count, bool) and status_count >= 0)
        or status_count == "unavailable"
    ):
        errors.append(f"{label}.vcs.status_entry_count: expected non-negative integer or unavailable")
    status_short = _string_array(
        vcs.get("status_short"),
        f"{label}.vcs.status_short",
        errors,
        allow_empty=True,
    )
    if isinstance(status_count, int) and status_count != len(status_short):
        errors.append(f"{label}.vcs.status_entry_count: does not match status_short")
    runner = _mapping(suite.get("runner"), f"{label}.runner", errors)
    _string(runner, "script", f"{label}.runner", errors)
    if runner.get("script") == "unavailable":
        errors.append(f"{label}.runner.script: unavailable is not valid formal evidence")
    _string_array(
        runner.get("original_arguments"),
        f"{label}.runner.original_arguments",
        errors,
        allow_empty=True,
    )
    _string_array(
        runner.get("effective_arguments"),
        f"{label}.runner.effective_arguments",
        errors,
        allow_empty=False,
    )
    version_arguments = _string_array(
        runner.get("version_arguments"),
        f"{label}.runner.version_arguments",
        errors,
        allow_empty=False,
    )
    if not any(argument.startswith("MARKETING_VERSION=") for argument in version_arguments):
        errors.append(f"{label}.runner.version_arguments: missing MARKETING_VERSION")
    if not any(argument.startswith("CURRENT_PROJECT_VERSION=") for argument in version_arguments):
        errors.append(f"{label}.runner.version_arguments: missing CURRENT_PROJECT_VERSION")
    return suite


def _flag(mapping: dict[str, Any], key: str) -> str:
    value = mapping.get(key, "")
    if isinstance(value, bool):
        return "1" if value else "0"
    return str(value)


def _percent_change(baseline: float, current: float) -> float | None:
    if baseline == 0:
        return None
    return (current - baseline) / baseline * 100.0


def _median(rows: list[dict[str, Any]], key: str) -> float:
    return float(statistics.median(float(row[key]) for row in rows)) if rows else 0.0


def _load_source_manifest(
    out_dir: Path,
    errors: list[str],
    *,
    allow_missing_summary_after: bool,
) -> dict[str, Any]:
    path = out_dir / "source-manifest.json"
    if not path.is_file():
        errors.append(f"missing source manifest: {path}")
        return {
            "source": "",
            "executable": "",
            "build": "",
            "environment": {},
            "suite": {},
        }
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"invalid source manifest {path}: {exc}")
        return {
            "source": "",
            "executable": "",
            "build": "",
            "environment": {},
            "suite": {},
        }
    payload = _mapping(payload, "source-manifest", errors)
    if payload.get("schema") != SOURCE_MANIFEST_SCHEMA:
        errors.append(f"source-manifest.schema: expected {SOURCE_MANIFEST_SCHEMA}")
    fingerprint = _string(payload, "fingerprint", "source-manifest", errors)
    post_run = _string(payload, "post_run_fingerprint", "source-manifest", errors)
    if fingerprint and not SHA256_PATTERN.fullmatch(fingerprint):
        errors.append("source-manifest.fingerprint: expected sha256:<64 lowercase hex>")
    if post_run and not SHA256_PATTERN.fullmatch(post_run):
        errors.append("source-manifest.post_run_fingerprint: expected sha256:<64 lowercase hex>")
    if fingerprint and post_run and fingerprint != post_run:
        errors.append("source manifest changed while the A/B suite was running")
    environment = _validate_environment(
        payload.get("environment"),
        "source-manifest.environment",
        errors,
    )
    environment_fingerprint = str(environment.get("fingerprint", ""))
    suite = _validate_suite(payload.get("suite"), "source-manifest.suite", errors)
    suite_fingerprint = str(suite.get("fingerprint", ""))
    vcs = _mapping(suite.get("vcs"), "source-manifest.suite.vcs", errors)
    vcs_fingerprint = str(vcs.get("fingerprint", ""))
    post_run_vcs_fingerprint = _string(
        payload,
        "post_run_vcs_fingerprint",
        "source-manifest",
        errors,
    )
    if vcs_fingerprint != post_run_vcs_fingerprint:
        errors.append("VCS state changed while the A/B suite was running")
    post_run_environment_fingerprint = _string(
        payload,
        "post_run_environment_fingerprint",
        "source-manifest",
        errors,
    )
    if environment_fingerprint != post_run_environment_fingerprint:
        errors.append("environment changed while the A/B suite was running")

    required_stages = ["build-after", "run-after"]
    if not allow_missing_summary_after:
        required_stages.append("summary-after")

    source_verifications = payload.get("source_verifications")
    if not isinstance(source_verifications, list):
        errors.append("source-manifest.source_verifications: expected array")
        source_verifications = []
    source_stages = {
        entry.get("stage")
        for entry in source_verifications
        if (
            isinstance(entry, dict)
            and entry.get("stable") is True
            and entry.get("fingerprint") == fingerprint
        )
    }
    for required_stage in required_stages:
        if required_stage not in source_stages:
            errors.append(f"source manifest missing stable {required_stage} verification")
    if any(
        not isinstance(entry, dict)
        or entry.get("stable") is not True
        or entry.get("fingerprint") != fingerprint
        for entry in source_verifications
    ):
        errors.append("source manifest contains an unstable or mismatched verification")

    environment_verifications = payload.get("environment_verifications")
    if not isinstance(environment_verifications, list):
        errors.append("source-manifest.environment_verifications: expected array")
        environment_verifications = []
    environment_stages = {
        entry.get("stage")
        for entry in environment_verifications
        if isinstance(entry, dict) and entry.get("stable") is True
    }
    for required_stage in required_stages:
        if required_stage not in environment_stages:
            errors.append(f"environment manifest missing stable {required_stage} verification")
    if any(
        not isinstance(entry, dict)
        or entry.get("stable") is not True
        or entry.get("fingerprint") != environment_fingerprint
        for entry in environment_verifications
    ):
        errors.append("environment manifest contains an unstable or mismatched verification")
    if payload.get("environment_stable") is not True:
        errors.append("source-manifest.environment_stable: expected true")

    vcs_verifications = payload.get("vcs_verifications")
    if not isinstance(vcs_verifications, list):
        errors.append("source-manifest.vcs_verifications: expected array")
        vcs_verifications = []
    vcs_stages = {
        entry.get("stage")
        for entry in vcs_verifications
        if (
            isinstance(entry, dict)
            and entry.get("stable") is True
            and entry.get("fingerprint") == vcs_fingerprint
        )
    }
    for required_stage in required_stages:
        if required_stage not in vcs_stages:
            errors.append(f"VCS manifest missing stable {required_stage} verification")
    if any(
        not isinstance(entry, dict)
        or entry.get("stable") is not True
        or entry.get("fingerprint") != vcs_fingerprint
        for entry in vcs_verifications
    ):
        errors.append("VCS manifest contains an unstable or mismatched verification")
    if payload.get("vcs_stable") is not True:
        errors.append("source-manifest.vcs_stable: expected true")

    build = _mapping(payload.get("build_artifacts"), "source-manifest.build_artifacts", errors)
    if build.get("schema") != BUILD_ARTIFACT_SCHEMA:
        errors.append(f"source-manifest.build_artifacts.schema: expected {BUILD_ARTIFACT_SCHEMA}")
    build_fingerprint = _string(build, "fingerprint", "source-manifest.build_artifacts", errors)
    app_artifact = _mapping(
        build.get("app_executable"),
        "source-manifest.build_artifacts.app_executable",
        errors,
    )
    executable_fingerprint = _string(
        app_artifact,
        "sha256",
        "source-manifest.build_artifacts.app_executable",
        errors,
    )
    for label in ("ui_test_executable", "xctestrun"):
        artifact = _mapping(build.get(label), f"source-manifest.build_artifacts.{label}", errors)
        digest = _string(artifact, "sha256", f"source-manifest.build_artifacts.{label}", errors)
        if digest and not SHA256_PATTERN.fullmatch(digest):
            errors.append(f"source-manifest.build_artifacts.{label}.sha256: invalid SHA-256")
    for label, digest in (
        ("fingerprint", build_fingerprint),
        ("app_executable.sha256", executable_fingerprint),
    ):
        if digest and not SHA256_PATTERN.fullmatch(digest):
            errors.append(f"source-manifest.build_artifacts.{label}: invalid SHA-256")
    build_verifications = build.get("verifications")
    if not isinstance(build_verifications, list) or not build_verifications:
        errors.append("source-manifest.build_artifacts.verifications: expected non-empty array")
    else:
        build_stages = {
            entry.get("stage")
            for entry in build_verifications
            if (
                isinstance(entry, dict)
                and entry.get("stable") is True
                and entry.get("fingerprint") == build_fingerprint
                and entry.get("environment_fingerprint") == environment_fingerprint
                and entry.get("vcs_fingerprint") == vcs_fingerprint
            )
        }
        for required_stage in required_stages:
            if required_stage not in build_stages:
                errors.append(f"build artifacts missing stable {required_stage} verification")
        if any(
            not isinstance(entry, dict)
            or entry.get("stable") is not True
            or entry.get("fingerprint") != build_fingerprint
            or entry.get("environment_fingerprint") != environment_fingerprint
            or entry.get("vcs_fingerprint") != vcs_fingerprint
            for entry in build_verifications
        ):
            errors.append("build artifacts contain an unstable or mismatched verification")
    if build.get("artifacts_stable") is not True:
        errors.append("source-manifest.build_artifacts.artifacts_stable: expected true")
    return {
        "source": fingerprint,
        "executable": executable_fingerprint,
        "build": build_fingerprint,
        "environment": environment,
        "environment_fingerprint": environment_fingerprint,
        "suite": suite,
        "suite_fingerprint": suite_fingerprint,
        "vcs_fingerprint": vcs_fingerprint,
    }


def _parse_run(
    path: Path,
    variant: str,
    axis: str,
    repeats: int,
    commands: int,
    step_px: float,
    warm_rounds: int,
    manifest_fingerprints: dict[str, Any],
    errors: list[str],
) -> dict[str, Any] | None:
    match = RUN_NAME_PATTERN.fullmatch(path.name)
    if not match:
        errors.append(f"{variant}: unexpected raw filename {path.name}")
        return None
    if match.group("variant") != variant:
        errors.append(f"{path.name}: filename variant does not match directory {variant}")
    pair = int(match.group("pair"))
    order = match.group("order")
    label = f"{variant}/pair{pair:02d}-{order}"

    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"{label}: invalid JSON: {exc}")
        return None
    payload = _mapping(payload, label, errors)
    run_environment = _validate_environment(payload.get("environment"), f"{label}.environment", errors)
    run_environment_fingerprint = str(run_environment.get("fingerprint", ""))
    expected_environment_fingerprint = str(
        manifest_fingerprints.get("environment_fingerprint", "")
    )
    if run_environment_fingerprint != expected_environment_fingerprint:
        errors.append(f"{label}: environment fingerprint differs from source-manifest.json")
    run_suite = _validate_suite(payload.get("suite"), f"{label}.suite", errors)
    run_suite_fingerprint = str(run_suite.get("fingerprint", ""))
    expected_suite_fingerprint = str(manifest_fingerprints.get("suite_fingerprint", ""))
    if run_suite_fingerprint != expected_suite_fingerprint:
        errors.append(f"{label}: suite fingerprint differs from source-manifest.json")
    workload = _mapping(payload.get("fixed_workload"), f"{label}.fixed_workload", errors)
    config = _mapping(payload.get("config"), f"{label}.config", errors)
    config_environment_fingerprint = _string(
        config,
        "environment_fingerprint",
        f"{label}.config",
        errors,
    )
    if config_environment_fingerprint != expected_environment_fingerprint:
        errors.append(f"{label}.config.environment_fingerprint: does not match manifest")
    config_suite_fingerprint = _string(
        config,
        "suite_fingerprint",
        f"{label}.config",
        errors,
    )
    if config_suite_fingerprint != expected_suite_fingerprint:
        errors.append(f"{label}.config.suite_fingerprint: does not match manifest")
    counters = _mapping(payload.get("counters"), f"{label}.counters", errors)
    gauges = _mapping(payload.get("gauges"), f"{label}.gauges", errors)
    buckets = _mapping(payload.get("timing_buckets_ms"), f"{label}.timing_buckets_ms", errors)
    row_bucket = _mapping(buckets.get("swiftui.row_body_ms"), f"{label}.swiftui.row_body_ms", errors)
    runloop = _mapping(payload.get("main_runloop_active_ms"), f"{label}.main_runloop_active_ms", errors)
    callback = _mapping(
        payload.get("animation_callback_interval_ms"),
        f"{label}.animation_callback_interval_ms",
        errors,
    )
    sample_health = _mapping(
        payload.get("scroll_sample_health"),
        f"{label}.scroll_sample_health",
        errors,
    )
    timing_event_retention = _mapping(
        payload.get("timing_event_retention"),
        f"{label}.timing_event_retention",
        errors,
    )
    runloop_event_retention = _mapping(
        payload.get("main_runloop_event_retention"),
        f"{label}.main_runloop_event_retention",
        errors,
    )
    dataset = _mapping(workload.get("dataset"), f"{label}.fixed_workload.dataset", errors)

    duration = _number(payload, "duration_seconds", label, errors)
    row_count = _integer(row_bucket, "total_count", f"{label}.swiftui.row_body_ms", errors)
    row_total_ms = _number(row_bucket, "total_ms", f"{label}.swiftui.row_body_ms", errors)
    runloop_count = _integer(runloop, "total_count", f"{label}.main_runloop_active_ms", errors)
    runloop_total_ms = _number(runloop, "total_ms", f"{label}.main_runloop_active_ms", errors)
    runloop_p95 = _number(runloop, "p95", f"{label}.main_runloop_active_ms", errors)
    if duration <= 0:
        errors.append(f"{label}: duration_seconds must be > 0")
        duration = 1.0
    if row_count <= 0:
        errors.append(f"{label}: row-body count must be > 0")
    if runloop_count <= 0:
        errors.append(f"{label}: main-run-loop count must be > 0")
    if row_total_ms <= 0:
        errors.append(f"{label}: row-body total_ms must be > 0")
    if runloop_total_ms <= 0:
        errors.append(f"{label}: main-run-loop total_ms must be > 0")

    for metric_label, metric in (
        ("swiftui.row_body_ms", row_bucket),
        ("main_runloop_active_ms", runloop),
        ("animation_callback_interval_ms", callback),
    ):
        retained_count = _integer(metric, "retained_count", f"{label}.{metric_label}", errors)
        total_count = _integer(metric, "total_count", f"{label}.{metric_label}", errors)
        overwritten_count = _integer(
            metric,
            "overwritten_count",
            f"{label}.{metric_label}",
            errors,
        )
        if overwritten_count != 0 or retained_count != total_count:
            errors.append(f"{label}.{metric_label}: formal evidence is truncated")
        if "p95" not in metric:
            errors.append(f"{label}.{metric_label}: untruncated formal evidence requires p95")
    for bucket_name, bucket_value in buckets.items():
        bucket = _mapping(bucket_value, f"{label}.timing_buckets_ms.{bucket_name}", errors)
        retained = _integer(bucket, "retained_count", f"{label}.{bucket_name}", errors)
        total = _integer(bucket, "total_count", f"{label}.{bucket_name}", errors)
        overwritten = _integer(bucket, "overwritten_count", f"{label}.{bucket_name}", errors)
        _number(bucket, "total_ms", f"{label}.{bucket_name}", errors)
        if overwritten != 0 or retained != total:
            errors.append(f"{label}.timing_buckets_ms.{bucket_name}: formal evidence is truncated")
        if "p95" not in bucket:
            errors.append(f"{label}.timing_buckets_ms.{bucket_name}: untruncated evidence requires p95")
    for retention_label, retention in (
        ("timing_event_retention", timing_event_retention),
        ("main_runloop_event_retention", runloop_event_retention),
    ):
        retained = _integer(retention, "retained_count", f"{label}.{retention_label}", errors)
        total = _integer(retention, "total_count", f"{label}.{retention_label}", errors)
        overwritten = _integer(retention, "overwritten_count", f"{label}.{retention_label}", errors)
        if overwritten != 0 or retained != total:
            errors.append(f"{label}.{retention_label}: formal evidence is truncated")

    expected_order = "AB" if pair % 2 == 1 else "BA"
    if order != expected_order:
        errors.append(f"{label}: expected {expected_order} order")
    if not 1 <= pair <= repeats:
        errors.append(f"{label}: pair is outside 1...{repeats}")

    expected_passive = "0" if axis == "passive-row" and variant == "baseline" else "1"
    expected_menu_cache = "0" if axis == "markdown-menu-cache" and variant == "baseline" else "1"
    expected_config = {
        "mock_dataset_id": FIXED_DATASET_ID,
        "mock_item_count": str(FIXED_ITEMS),
        "mock_image_count": "0",
        "mock_text_length": str(FIXED_TEXT_BYTES),
        "mock_show_thumbnails": "0",
        "profile_accessibility": "0",
        "profile_auto_scroll": "1",
        "passive_row": expected_passive,
        "markdown_menu_signal_cache": expected_menu_cache,
        "build_configuration": "Release",
        "animation_callback_source": "NSScreen CADisplayLink",
    }
    for key, expected in expected_config.items():
        if _flag(config, key) != expected:
            errors.append(f"{label}.config.{key}: expected {expected!r}, found {_flag(config, key)!r}")
    for key in FIXED_ENABLED_FLAGS:
        if _flag(config, key) != "1":
            errors.append(f"{label}.config.{key}: expected '1'")
    run_source_fingerprint = _string(config, "source_fingerprint", f"{label}.config", errors)
    if run_source_fingerprint and not SHA256_PATTERN.fullmatch(run_source_fingerprint):
        errors.append(f"{label}.config.source_fingerprint: invalid SHA-256 fingerprint")
    source_fingerprint = manifest_fingerprints.get("source", "")
    if source_fingerprint and run_source_fingerprint != source_fingerprint:
        errors.append(f"{label}: source fingerprint differs from source-manifest.json")
    executable_fingerprint = _string(config, "executable_fingerprint", f"{label}.config", errors)
    runner_executable_fingerprint = _string(
        config,
        "runner_executable_fingerprint",
        f"{label}.config",
        errors,
    )
    expected_executable_fingerprint = manifest_fingerprints.get("executable", "")
    for fingerprint_label, fingerprint in (
        ("executable_fingerprint", executable_fingerprint),
        ("runner_executable_fingerprint", runner_executable_fingerprint),
    ):
        if fingerprint and not SHA256_PATTERN.fullmatch(fingerprint):
            errors.append(f"{label}.config.{fingerprint_label}: invalid SHA-256 fingerprint")
    if (
        executable_fingerprint != runner_executable_fingerprint
        or executable_fingerprint != expected_executable_fingerprint
    ):
        errors.append(f"{label}: executable fingerprint differs from the recorded build")
    max_samples = _integer(config, "max_samples", f"{label}.config", errors)
    if max_samples != 131_072:
        errors.append(f"{label}.config.max_samples: expected 131072")

    intended_path = commands * step_px
    workload_checks = {
        "enabled": workload.get("enabled") is True,
        "completed": workload.get("completed") is True,
        "command_target": _integer(workload, "command_target", f"{label}.fixed_workload", errors) == commands,
        "command_count": _integer(workload, "command_count", f"{label}.fixed_workload", errors) == commands,
        "issued_command_count": _integer(
            workload,
            "issued_command_count",
            f"{label}.fixed_workload",
            errors,
        ) == commands,
        "measured_command_response_count": _integer(
            workload,
            "measured_command_response_count",
            f"{label}.fixed_workload",
            errors,
        ) == commands,
        "pre_measurement_settle_callback_count": _integer(
            workload,
            "pre_measurement_settle_callback_count",
            f"{label}.fixed_workload",
            errors,
        ) == 1,
        "post_measurement_settle_callback_count": _integer(
            workload,
            "post_measurement_settle_callback_count",
            f"{label}.fixed_workload",
            errors,
        ) == 1,
        "finalization_state": workload.get("finalization_state") == "response_captured_and_drained",
        "step_px": abs(_number(workload, "step_px", f"{label}.fixed_workload", errors) - step_px) < 1e-9,
        "intended_path_px": abs(
            _number(workload, "intended_path_px", f"{label}.fixed_workload", errors) - intended_path
        ) < 1e-9,
        "warm_rounds": _integer(workload, "warm_rounds", f"{label}.fixed_workload", errors) == warm_rounds,
        "loaded_count": _integer(workload, "loaded_count", f"{label}.fixed_workload", errors) == FIXED_ITEMS,
        "total_count": _integer(workload, "total_count", f"{label}.fixed_workload", errors) == FIXED_ITEMS,
        "can_load_more": workload.get("can_load_more") is False,
    }
    for key, passed in workload_checks.items():
        if not passed:
            errors.append(f"{label}.fixed_workload.{key}: contract failed")
    observed_path = _number(workload, "observed_path_px", f"{label}.fixed_workload", errors)
    if not 0 < observed_path <= intended_path:
        errors.append(f"{label}.fixed_workload.observed_path_px: expected 0 < observed <= intended")
    screen_fps = _integer(
        workload,
        "screen_maximum_frames_per_second",
        f"{label}.fixed_workload",
        errors,
    )
    if screen_fps <= 0:
        errors.append(f"{label}.fixed_workload.screen_maximum_frames_per_second: expected > 0")

    callback_total_count = _integer(
        callback,
        "total_count",
        f"{label}.animation_callback_interval_ms",
        errors,
    )
    callback_total_ms = _number(
        callback,
        "total_ms",
        f"{label}.animation_callback_interval_ms",
        errors,
    )
    if callback_total_count != commands:
        errors.append(
            f"{label}.animation_callback_interval_ms.total_count: expected {commands}"
        )
    health_callback_count = _integer(
        sample_health,
        "animation_callback_total_count",
        f"{label}.scroll_sample_health",
        errors,
    )
    health_callback_overwrite = _integer(
        sample_health,
        "animation_callback_overwritten_count",
        f"{label}.scroll_sample_health",
        errors,
    )
    active_callback_count = _integer(
        sample_health,
        "active_animation_callback_count",
        f"{label}.scroll_sample_health",
        errors,
    )
    moving_callback_count = _integer(
        sample_health,
        "moving_animation_callback_count",
        f"{label}.scroll_sample_health",
        errors,
    )
    live_callback_count = _integer(
        sample_health,
        "live_scroll_animation_callback_count",
        f"{label}.scroll_sample_health",
        errors,
    )
    if health_callback_count != commands or health_callback_overwrite != 0:
        errors.append(f"{label}: callback sample health does not cover all commands")
    if active_callback_count < math.ceil(commands * 0.95):
        errors.append(f"{label}: active callback coverage is below 95%")
    if moving_callback_count < math.ceil(commands * 0.90):
        errors.append(f"{label}: moving callback coverage is below 90%")
    if live_callback_count < math.ceil(commands * 0.95):
        errors.append(f"{label}: live-scroll callback coverage is below 95%")
    cadence_coverage = callback_total_ms / (duration * 1000.0) if duration > 0 else 0
    if not 0.90 <= cadence_coverage <= 1.05:
        errors.append(f"{label}: callback cadence does not cover the fixed measurement duration")

    dataset_string_expected = {
        "schema": FIXED_DATASET_SCHEMA,
        "id": FIXED_DATASET_ID,
    }
    dataset_integer_expected = {
        "item_count": FIXED_ITEMS,
        "text_item_count": FIXED_ITEMS,
        "image_item_count": 0,
        "pinned_item_count": FIXED_PINNED,
        "unique_item_id_count": FIXED_ITEMS,
        "text_utf8_bytes_min": FIXED_TEXT_BYTES,
        "text_utf8_bytes_max": FIXED_TEXT_BYTES,
    }
    for key, expected in dataset_string_expected.items():
        actual = _string(dataset, key, f"{label}.fixed_workload.dataset", errors)
        if actual and actual != expected:
            errors.append(
                f"{label}.fixed_workload.dataset.{key}: expected {expected!r}, found {actual!r}"
            )
    for key, expected in dataset_integer_expected.items():
        actual = _integer(dataset, key, f"{label}.fixed_workload.dataset", errors)
        if actual != expected:
            errors.append(f"{label}.fixed_workload.dataset.{key}: expected {expected}, found {actual}")
    dataset_fingerprint = _string(dataset, "fingerprint", f"{label}.fixed_workload.dataset", errors)
    if dataset_fingerprint and not SHA256_PATTERN.fullmatch(dataset_fingerprint):
        errors.append(f"{label}.fixed_workload.dataset.fingerprint: invalid SHA-256 fingerprint")

    counter_values: dict[str, int] = {}
    for key in REQUIRED_COUNTERS:
        counter_values[key] = _integer(counters, key, f"{label}.counters", errors)
        if counter_values[key] < 0:
            errors.append(f"{label}.counters.{key}: expected >= 0")
    gauge_values: dict[str, int] = {}
    for key in REQUIRED_GAUGES:
        gauge_values[key] = _integer(gauges, key, f"{label}.gauges", errors)
        if not 0 <= gauge_values[key] <= 1:
            errors.append(f"{label}.gauges.{key}: expected 0...1")

    if counter_values["row.descriptor_cache_hit"] <= 0:
        errors.append(f"{label}: descriptor cache must record measurement hits")
    if counter_values["row.descriptor_cache_miss"] != 0:
        errors.append(f"{label}: descriptor cache must have zero measurement misses")
    if counter_values["row.relative_time_cache_hit"] <= 0:
        errors.append(f"{label}: relative-time cache must record measurement hits")
    if counter_values["row.relative_time_cache_miss"] != 0:
        errors.append(f"{label}: relative-time cache must have zero measurement misses")
    if counter_values["list.load_more_attempt"] != 0:
        errors.append(f"{label}: fixed workload attempted load-more")
    if counter_values["list.pagination_request"] != 0:
        errors.append(f"{label}: fixed workload issued a pagination request")
    if counter_values["profile.ingress_dropped"] != 0:
        errors.append(f"{label}: metric ingress dropped records")

    session_init = counter_values["interaction.session_init"]
    observer_install = counter_values["interaction.observer_install"]
    idle_fast_path = counter_values["interaction.idle_disappear_fast_path"]
    menu_hit = counter_values["row.markdown_menu_signal_cache_hit"]
    menu_miss = counter_values["row.markdown_menu_signal_cache_miss"]
    menu_uncached = counter_values["row.markdown_menu_signal_uncached"]
    if axis == "passive-row":
        if variant == "current":
            if session_init != 0 or observer_install != 0:
                errors.append(f"{label}: passive current created a session or legacy observer")
            if idle_fast_path <= 0:
                errors.append(f"{label}: passive current did not exercise the idle-disappear fast path")
        elif session_init <= 0 or observer_install <= 0:
            errors.append(f"{label}: legacy baseline did not exercise eager sessions and observers")
    else:
        if session_init != 0 or observer_install != 0:
            errors.append(f"{label}: menu-cache axis must keep both variants passive")
        if idle_fast_path <= 0:
            errors.append(f"{label}: menu-cache axis did not exercise passive row recycling")
        if variant == "current":
            if menu_hit <= 0 or menu_miss != 0 or menu_uncached != 0:
                errors.append(f"{label}: menu-cache current requires hits and zero misses/uncached scans")
        elif menu_uncached <= 0 or menu_hit != 0 or menu_miss != 0:
            errors.append(f"{label}: menu-cache baseline did not isolate uncached scanning")

    return {
        "path": str(path),
        "run_id": path.stem.removeprefix("fixed-warm-text-"),
        "pair": pair,
        "order": order,
        "duration": duration,
        "row_total_count": float(row_count),
        "row_total_ms": row_total_ms,
        "runloop_total_ms": runloop_total_ms,
        "runloop_p95_ms": runloop_p95,
        "callback_total_count": callback_total_count,
        "callback_total_ms": callback_total_ms,
        "callback_cadence_coverage": cadence_coverage,
        "observed_path_px": observed_path,
        "screen_maximum_frames_per_second": screen_fps,
        "dataset_fingerprint": dataset_fingerprint,
        "source_fingerprint": run_source_fingerprint,
        "executable_fingerprint": executable_fingerprint,
        "environment_fingerprint": run_environment_fingerprint,
        "suite_fingerprint": run_suite_fingerprint,
        "counters": counter_values,
        "gauges": gauge_values,
    }


def build_summary(
    out_dir: Path,
    repeats: int,
    commands: int,
    step_px: float,
    warm_rounds: int,
    axis: str,
    *,
    allow_missing_summary_after: bool = False,
    diagnostic: bool = False,
) -> dict[str, Any]:
    errors: list[str] = []
    if axis not in AXES:
        errors.append(f"unsupported axis: {axis}")
    if diagnostic:
        if repeats < DIAGNOSTIC_MIN_REPEATS:
            errors.append(
                f"diagnostic evidence requires at least {DIAGNOSTIC_MIN_REPEATS} complete pairs"
            )
        if commands < DIAGNOSTIC_MIN_COMMANDS:
            errors.append(
                f"diagnostic evidence requires at least {DIAGNOSTIC_MIN_COMMANDS} commands"
            )
    else:
        if repeats < FORMAL_MIN_REPEATS:
            errors.append(f"formal evidence requires at least {FORMAL_MIN_REPEATS} complete pairs")
        if commands != FORMAL_COMMANDS:
            errors.append(f"formal evidence requires exactly {FORMAL_COMMANDS} commands")
        if abs(step_px - FIXED_STEP_PX) > 1e-9:
            errors.append(f"formal evidence requires a {FIXED_STEP_PX:g}px step")
        if warm_rounds != FIXED_WARM_ROUNDS:
            errors.append(f"formal evidence requires {FIXED_WARM_ROUNDS} warm rounds")

    manifest_fingerprints = _load_source_manifest(
        out_dir,
        errors,
        allow_missing_summary_after=allow_missing_summary_after,
    )
    variants: dict[str, list[dict[str, Any]]] = {"baseline": [], "current": []}
    for variant in variants:
        raw_dir = out_dir / "raw" / variant
        if not raw_dir.is_dir():
            errors.append(f"missing raw directory: {raw_dir}")
            continue
        for path in sorted(raw_dir.glob("*.json")):
            row = _parse_run(
                path,
                variant,
                axis,
                repeats,
                commands,
                step_px,
                warm_rounds,
                manifest_fingerprints,
                errors,
            )
            if row is not None:
                variants[variant].append(row)

    expected_pairs = list(range(1, repeats + 1))
    for variant, rows in variants.items():
        actual_pairs = sorted(row["pair"] for row in rows)
        if actual_pairs != expected_pairs:
            errors.append(f"{variant}: expected pairs {expected_pairs}, found {actual_pairs}")

    all_rows = variants["baseline"] + variants["current"]
    dataset_fingerprints = {row["dataset_fingerprint"] for row in all_rows if row["dataset_fingerprint"]}
    if len(dataset_fingerprints) != 1:
        errors.append(f"expected one dataset fingerprint across all runs, found {sorted(dataset_fingerprints)}")
    source_fingerprints = {row["source_fingerprint"] for row in all_rows if row["source_fingerprint"]}
    if len(source_fingerprints) != 1:
        errors.append(f"expected one source fingerprint across all runs, found {sorted(source_fingerprints)}")
    executable_fingerprints = {
        row["executable_fingerprint"] for row in all_rows if row["executable_fingerprint"]
    }
    if executable_fingerprints != {manifest_fingerprints.get("executable", "")}:
        errors.append(
            "expected every raw run to use the exact recorded app executable fingerprint"
        )
    environment_fingerprints = {
        row["environment_fingerprint"]
        for row in all_rows
        if row["environment_fingerprint"]
    }
    if environment_fingerprints != {
        manifest_fingerprints.get("environment_fingerprint", "")
    }:
        errors.append("expected every raw run to use the exact recorded environment fingerprint")
    suite_fingerprints = {
        row["suite_fingerprint"] for row in all_rows if row["suite_fingerprint"]
    }
    if suite_fingerprints != {manifest_fingerprints.get("suite_fingerprint", "")}:
        errors.append("expected every raw run to use the exact recorded suite fingerprint")
    observed_paths = {row["observed_path_px"] for row in all_rows}
    if len(observed_paths) != 1:
        errors.append(f"observed path differs across runs: {sorted(observed_paths)}")
    screen_refresh_rates = {row["screen_maximum_frames_per_second"] for row in all_rows}
    if len(screen_refresh_rates) != 1:
        errors.append(f"screen maximum FPS differs across runs: {sorted(screen_refresh_rates)}")

    metric_keys = (
        "duration",
        "row_total_count",
        "row_total_ms",
        "runloop_total_ms",
        "runloop_p95_ms",
    )
    metrics: dict[str, dict[str, float | None]] = {}
    for key in metric_keys:
        baseline = _median(variants["baseline"], key)
        current = _median(variants["current"], key)
        metrics[key] = {
            "baseline_median": baseline,
            "current_median": current,
            "change_percent": _percent_change(baseline, current),
        }

    runloop_p95_change = metrics["runloop_p95_ms"]["change_percent"]
    if not diagnostic and (runloop_p95_change is None or runloop_p95_change > 10):
        errors.append("main-run-loop p95 median regressed by more than 10% or was not measurable")

    pairs: list[dict[str, Any]] = []
    for pair in expected_pairs:
        baseline = next((row for row in variants["baseline"] if row["pair"] == pair), None)
        current = next((row for row in variants["current"] if row["pair"] == pair), None)
        if baseline is None or current is None:
            continue
        if baseline["order"] != current["order"]:
            errors.append(f"pair {pair}: baseline/current order labels differ")
        duration_change = _percent_change(baseline["duration"], current["duration"])
        row_count_change = _percent_change(baseline["row_total_count"], current["row_total_count"])
        row_total_change = _percent_change(
            baseline["row_total_ms"], current["row_total_ms"]
        )
        runloop_total_change = _percent_change(
            baseline["runloop_total_ms"], current["runloop_total_ms"]
        )
        pair_runloop_p95_change = _percent_change(
            baseline["runloop_p95_ms"], current["runloop_p95_ms"]
        )
        pair_payload = {
            "pair": pair,
            "order": baseline["order"],
            "duration_change_percent": duration_change,
            "row_body_count_change_percent": row_count_change,
            "row_body_total_change_percent": row_total_change,
            "runloop_total_change_percent": runloop_total_change,
            "runloop_p95_change_percent": pair_runloop_p95_change,
        }
        pairs.append(pair_payload)
        if not diagnostic:
            if duration_change is None or duration_change > 10:
                errors.append(f"pair {pair}: duration regressed by more than 10%")
            if axis == "passive-row":
                if row_count_change is None or row_count_change > -10:
                    errors.append(f"pair {pair}: passive row-body count did not improve by at least 10%")
                if row_total_change is None or row_total_change >= 0:
                    errors.append(f"pair {pair}: passive row-body total work did not improve")
            elif row_total_change is None or row_total_change >= 0:
                errors.append(f"pair {pair}: menu-cache row-body total work did not improve")
            if runloop_total_change is None or runloop_total_change >= 0:
                errors.append(f"pair {pair}: main-run-loop total work did not improve")
            if pair_runloop_p95_change is None or pair_runloop_p95_change > 10:
                errors.append(f"pair {pair}: main-run-loop p95 regressed by more than 10%")

    if len(pairs) != repeats:
        errors.append(f"expected {repeats} complete pairs, found {len(pairs)}")
    if not any(pair["order"] == "AB" for pair in pairs) or not any(pair["order"] == "BA" for pair in pairs):
        errors.append("both AB and BA orderings are required")

    dataset_fingerprint = next(iter(dataset_fingerprints), "")
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "gate_passed": not errors,
        "errors": errors,
        "contract": {
            "axis": axis,
            "evidence_level": "diagnostic" if diagnostic else "formal",
            "performance_thresholds_enforced": not diagnostic,
            "configuration": "Release",
            "dataset_schema": FIXED_DATASET_SCHEMA,
            "dataset_id": FIXED_DATASET_ID,
            "dataset_fingerprint": dataset_fingerprint,
            "source_fingerprint": manifest_fingerprints.get("source", ""),
            "executable_fingerprint": manifest_fingerprints.get("executable", ""),
            "build_artifacts_fingerprint": manifest_fingerprints.get("build", ""),
            "environment_schema": ENVIRONMENT_SCHEMA,
            "environment_fingerprint": manifest_fingerprints.get(
                "environment_fingerprint", ""
            ),
            "environment": manifest_fingerprints.get("environment", {}),
            "suite_schema": SUITE_SCHEMA,
            "suite_fingerprint": manifest_fingerprints.get("suite_fingerprint", ""),
            "suite": manifest_fingerprints.get("suite", {}),
            "summary_stage_policy": (
                "preliminary-may-omit-summary-after"
                if allow_missing_summary_after
                else "final-requires-build-after-run-after-summary-after"
            ),
            "items": FIXED_ITEMS,
            "images": 0,
            "text_utf8_bytes": FIXED_TEXT_BYTES,
            "pinned": FIXED_PINNED,
            "commands": commands,
            "step_px": step_px,
            "intended_path_px": commands * step_px,
            "observed_path_px": next(iter(observed_paths), None) if len(observed_paths) == 1 else None,
            "display_sampling": {
                "screen_maximum_frames_per_second": (
                    next(iter(screen_refresh_rates), None)
                    if len(screen_refresh_rates) == 1
                    else None
                ),
                "refresh_range": "not-recorded-by-raw-profile",
                "basis": (
                    "NSScreen.maximumFramesPerSecond is captured once per raw run and must "
                    "match across all runs; this is a display capability, not measured FPS or "
                    "a variable-refresh-rate range"
                ),
            },
            "warm_rounds": warm_rounds,
            "orders": ["AB", "BA"],
            "minimum_complete_pairs": (
                DIAGNOSTIC_MIN_REPEATS if diagnostic else FORMAL_MIN_REPEATS
            ),
            "single_variable": (
                "SCOPY_PERF_PASSIVE_ROW"
                if axis == "passive-row"
                else "SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE"
            ),
        },
        "metrics": metrics,
        "pairs": pairs,
        "variants": variants,
    }


def _write_summary(out_dir: Path, summary: dict[str, Any]) -> tuple[Path, Path]:
    json_path = out_dir / "warm-scroll-ab-summary.json"
    markdown_path = out_dir / "warm-scroll-ab-summary.md"
    json_path.write_text(json.dumps(summary, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

    contract = summary["contract"]
    environment = contract["environment"]
    macos = environment.get("macos", {})
    hardware = environment.get("hardware", {})
    xcode = environment.get("xcode", {})
    sdk = environment.get("sdk", {})
    xcodegen = environment.get("xcodegen", {})
    suite = contract.get("suite", {})
    vcs = suite.get("vcs", {})
    runner = suite.get("runner", {})
    display_sampling = contract.get("display_sampling", {})
    lines = [
        "# Fixed Warm Scroll A/B",
        "",
        f"- Axis: `{contract['axis']}`",
        f"- Evidence: `{contract['evidence_level']}`",
        (
            "- Performance thresholds: "
            + ("enforced" if contract["performance_thresholds_enforced"] else "reported only")
        ),
        f"- Gate: **{'PASS' if summary['gate_passed'] else 'FAIL'}**",
        f"- Dataset: `{contract['dataset_id']}` / `{contract['dataset_fingerprint']}`",
        f"- Source: `{contract['source_fingerprint']}`",
        f"- App executable: `{contract['executable_fingerprint']}`",
        f"- Build artifacts: `{contract['build_artifacts_fingerprint']}`",
        f"- Environment: `{contract['environment_fingerprint']}`",
        f"- Suite: `{contract['suite_fingerprint']}`",
        (
            f"- Suite time: UTC={suite.get('captured_at_utc', 'unavailable')}; "
            f"local={suite.get('captured_at_local', 'unavailable')} "
            f"({suite.get('local_timezone', 'unavailable')})"
        ),
        (
            f"- VCS: HEAD={vcs.get('head', 'unavailable')}; "
            f"exact_tag={vcs.get('exact_tag', 'unavailable')}; "
            f"nearest_tag={vcs.get('nearest_tag', 'unavailable')}; "
            f"dirty={vcs.get('dirty', 'unavailable')}; "
            f"status_entries={vcs.get('status_entry_count', 'unavailable')}"
        ),
        (
            f"- macOS: {macos.get('product_version', 'unavailable')} "
            f"({macos.get('build_version', 'unavailable')}); "
            f"arch={hardware.get('architecture', 'unavailable')}"
        ),
        (
            f"- Hardware: model={hardware.get('model', 'unavailable')}; "
            f"chip={hardware.get('chip', 'unavailable')}; "
            f"memory={hardware.get('physical_memory_bytes', 'unavailable')} bytes"
        ),
        (
            f"- Xcode: {xcode.get('version', 'unavailable')} "
            f"({xcode.get('build_version', 'unavailable')}); "
            f"developer={xcode.get('developer_dir', 'unavailable')}; "
            f"tool={xcode.get('tool_path', 'unavailable')}"
        ),
        (
            f"- SDK: {sdk.get('name', 'unavailable')} {sdk.get('version', 'unavailable')} "
            f"({sdk.get('build_version', 'unavailable')}); "
            f"tool={sdk.get('tool_path', 'unavailable')}; "
            f"path={sdk.get('path', 'unavailable')}"
        ),
        (
            f"- XcodeGen: {xcodegen.get('version', 'unavailable')}; "
            f"tool={xcodegen.get('path', 'unavailable')}"
        ),
        (
            f"- Runner: {runner.get('script', 'unavailable')}; "
            f"original_args={json.dumps(runner.get('original_arguments', []), ensure_ascii=False)}; "
            f"effective_args={json.dumps(runner.get('effective_arguments', []), ensure_ascii=False)}"
        ),
        (
            "- Build version args: "
            + json.dumps(runner.get("version_arguments", []), ensure_ascii=False)
        ),
        (
            "- Display sampling: "
            f"maximumFramesPerSecond={display_sampling.get('screen_maximum_frames_per_second', 'unavailable')}; "
            f"refresh_range={display_sampling.get('refresh_range', 'unavailable')}; "
            f"basis={display_sampling.get('basis', 'unavailable')}"
        ),
        (
            f"- Work: {contract['commands']} × {contract['step_px']:g}px; "
            f"{contract['warm_rounds']} warm rounds; Release; AB/BA"
        ),
        "",
        "| Metric | Baseline median | Current median | Change |",
        "|---|---:|---:|---:|",
    ]
    labels = (
        ("duration", "Duration s"),
        ("row_total_count", "Row body whole-run count"),
        ("row_total_ms", "Row body whole-run total ms"),
        ("runloop_total_ms", "Main run-loop whole-run total ms"),
        ("runloop_p95_ms", "Main run-loop p95 ms"),
    )
    for key, label in labels:
        metric = summary["metrics"][key]
        change = metric["change_percent"]
        rendered_change = "n/a" if change is None else f"{change:.2f}%"
        lines.append(
            f"| {label} | {metric['baseline_median']:.3f} | "
            f"{metric['current_median']:.3f} | {rendered_change} |"
        )
    if summary["errors"]:
        lines.extend(["", "## Gate errors", ""])
        lines.extend(f"- {error}" for error in summary["errors"])
    markdown_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return json_path, markdown_path


def _fixture_environment() -> dict[str, Any]:
    environment = {
        "schema": ENVIRONMENT_SCHEMA,
        "macos": {
            "product_name": "macOS",
            "product_version": "15.7.3",
            "build_version": "24G419",
        },
        "hardware": {
            "architecture": "arm64",
            "model": "Mac15,6",
            "chip": "Apple M3 Pro",
            "physical_memory_bytes": 38_654_705_664,
        },
        "xcode": {
            "version": "26.1.1",
            "build_version": "17B100",
            "developer_dir": "/Applications/Xcode.app/Contents/Developer",
            "tool_path": "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild",
            "version_arguments": ["-version"],
        },
        "sdk": {
            "name": "macosx",
            "version": "26.1",
            "build_version": "25B74",
            "path": "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX26.1.sdk",
            "tool_path": "/usr/bin/xcrun",
            "version_arguments": ["--sdk", "macosx", "--show-sdk-version"],
            "build_version_arguments": ["--sdk", "macosx", "--show-sdk-build-version"],
            "path_arguments": ["--sdk", "macosx", "--show-sdk-path"],
        },
        "xcodegen": {
            "path": "/opt/homebrew/bin/xcodegen",
            "version": "Version: 2.44.1",
            "version_arguments": ["--version"],
        },
    }
    environment["fingerprint"] = _environment_fingerprint(environment)
    return environment


def _fixture_suite() -> dict[str, Any]:
    vcs = {
        "schema": VCS_SCHEMA,
        "head": "0123456789abcdef0123456789abcdef01234567",
        "exact_tag": "unavailable",
        "nearest_tag": "v0.8.8",
        "dirty": True,
        "status_entry_count": 1,
        "status_short": [" M Scopy/main.swift"],
    }
    vcs["fingerprint"] = _vcs_fingerprint(vcs)
    suite = {
        "schema": SUITE_SCHEMA,
        "captured_at_utc": "2026-07-11T04:00:00+00:00",
        "captured_at_local": "2026-07-11T12:00:00+08:00",
        "local_timezone": "CST",
        "vcs": vcs,
        "runner": {
            "script": "scripts/perf-warm-scroll-ab.sh",
            "original_arguments": ["--axis", "all"],
            "effective_arguments": ["--axis", "all", "--repeats", "5"],
            "version_arguments": [
                "MARKETING_VERSION=0.8.8",
                "CURRENT_PROJECT_VERSION=409",
            ],
        },
    }
    suite["fingerprint"] = _suite_fingerprint(suite)
    return suite


def _fixture_payload(axis: str, variant: str, pair: int, commands: int) -> dict[str, Any]:
    is_current = variant == "current"
    passive = "0" if axis == "passive-row" and not is_current else "1"
    menu_cache = "0" if axis == "markdown-menu-cache" and not is_current else "1"
    counters = {key: 0 for key in REQUIRED_COUNTERS}
    counters["row.descriptor_cache_hit"] = 800
    counters["row.relative_time_cache_hit"] = 800
    if axis == "passive-row":
        if is_current:
            counters["interaction.idle_disappear_fast_path"] = 800
        else:
            counters["interaction.session_init"] = 800
            counters["interaction.observer_install"] = 800
    else:
        counters["interaction.idle_disappear_fast_path"] = 800
        if is_current:
            counters["row.markdown_menu_signal_cache_hit"] = 800
        else:
            counters["row.markdown_menu_signal_uncached"] = 800

    if axis == "passive-row":
        row_count = 800 if is_current else 1_000
        row_avg = 1.5 if is_current else 2.0
    else:
        row_count = 1_000
        row_avg = 0.5 if is_current else 2.0
    runloop_avg = 4.0 if is_current else 5.0
    source_fingerprint = "sha256:" + "b" * 64
    executable_fingerprint = "sha256:" + "c" * 64
    dataset_fingerprint = "sha256:" + "a" * 64
    environment = _fixture_environment()
    suite = _fixture_suite()
    config: dict[str, Any] = {
        "mock_dataset_id": FIXED_DATASET_ID,
        "mock_item_count": "50",
        "mock_image_count": "0",
        "mock_text_length": "4096",
        "mock_show_thumbnails": "0",
        "profile_accessibility": "0",
        "profile_auto_scroll": "1",
        "passive_row": passive,
        "markdown_menu_signal_cache": menu_cache,
        "build_configuration": "Release",
        "animation_callback_source": "NSScreen CADisplayLink",
        "source_fingerprint": source_fingerprint,
        "executable_fingerprint": executable_fingerprint,
        "runner_executable_fingerprint": executable_fingerprint,
        "environment_fingerprint": environment["fingerprint"],
        "suite_fingerprint": suite["fingerprint"],
        "max_samples": 131_072,
    }
    config.update({key: "1" for key in FIXED_ENABLED_FLAGS})
    return {
        "environment": environment,
        "suite": suite,
        "duration_seconds": 10.0,
        "timing_buckets_ms": {
            "swiftui.row_body_ms": {
                "count": row_count,
                "retained_count": row_count,
                "total_count": row_count,
                "overwritten_count": 0,
                "total_ms": row_count * row_avg,
                "avg": row_avg,
                "p50": row_avg,
                "p95": row_avg * 1.2,
            }
        },
        "main_runloop_active_ms": {
            "count": 500,
            "retained_count": 500,
            "total_count": 500,
            "overwritten_count": 0,
            "total_ms": 500 * runloop_avg,
            "avg": runloop_avg,
            "p95": 7.0 if is_current else 8.0,
        },
        "animation_callback_interval_ms": {
            "count": commands,
            "retained_count": commands,
            "total_count": commands,
            "overwritten_count": 0,
            "total_ms": 10_000.0,
            "avg": 10_000.0 / commands,
            "p95": 8.0,
        },
        "scroll_sample_health": {
            "animation_callback_count": commands,
            "animation_callback_retained_count": commands,
            "animation_callback_total_count": commands,
            "animation_callback_overwritten_count": 0,
            "active_animation_callback_count": commands,
            "moving_animation_callback_count": commands,
            "live_scroll_animation_callback_count": commands,
        },
        "timing_event_retention": {
            "retained_count": row_count,
            "total_count": row_count,
            "overwritten_count": 0,
        },
        "main_runloop_event_retention": {
            "retained_count": 500,
            "total_count": 500,
            "overwritten_count": 0,
        },
        "counters": counters,
        "gauges": {key: 0 for key in REQUIRED_GAUGES},
        "config": config,
        "fixed_workload": {
            "enabled": True,
            "completed": True,
            "command_target": commands,
            "command_count": commands,
            "issued_command_count": commands,
            "measured_command_response_count": commands,
            "pre_measurement_settle_callback_count": 1,
            "post_measurement_settle_callback_count": 1,
            "finalization_state": "response_captured_and_drained",
            "measurement_generation": 1,
            "step_px": FIXED_STEP_PX,
            "intended_path_px": commands * FIXED_STEP_PX,
            "observed_path_px": min(commands * FIXED_STEP_PX, 51_270),
            "warm_rounds": FIXED_WARM_ROUNDS,
            "screen_maximum_frames_per_second": 120,
            "loaded_count": FIXED_ITEMS,
            "total_count": FIXED_ITEMS,
            "can_load_more": False,
            "dataset": {
                "schema": FIXED_DATASET_SCHEMA,
                "id": FIXED_DATASET_ID,
                "fingerprint": dataset_fingerprint,
                "item_count": FIXED_ITEMS,
                "text_item_count": FIXED_ITEMS,
                "image_item_count": 0,
                "pinned_item_count": FIXED_PINNED,
                "unique_item_id_count": FIXED_ITEMS,
                "text_utf8_bytes_min": FIXED_TEXT_BYTES,
                "text_utf8_bytes_max": FIXED_TEXT_BYTES,
            },
        },
    }


def _write_fixture(root: Path, axis: str, repeats: int = 5, commands: int = 1_440) -> None:
    for variant in ("baseline", "current"):
        (root / "raw" / variant).mkdir(parents=True, exist_ok=True)
    source_fingerprint = "sha256:" + "b" * 64
    executable_fingerprint = "sha256:" + "c" * 64
    build_fingerprint = "sha256:" + "d" * 64
    environment = _fixture_environment()
    suite = _fixture_suite()
    (root / "source-manifest.json").write_text(
        json.dumps(
            {
                "schema": SOURCE_MANIFEST_SCHEMA,
                "fingerprint": source_fingerprint,
                "post_run_fingerprint": source_fingerprint,
                "git_head": "fixture",
                "environment": environment,
                "suite": suite,
                "post_run_environment_fingerprint": environment["fingerprint"],
                "environment_stable": True,
                "post_run_vcs_fingerprint": suite["vcs"]["fingerprint"],
                "vcs_stable": True,
                "source_verifications": [
                    {
                        "stage": "build-after",
                        "stable": True,
                        "fingerprint": source_fingerprint,
                    },
                    {
                        "stage": "run-after",
                        "stable": True,
                        "fingerprint": source_fingerprint,
                    },
                    {
                        "stage": "summary-after",
                        "stable": True,
                        "fingerprint": source_fingerprint,
                    },
                ],
                "environment_verifications": [
                    {
                        "stage": stage,
                        "stable": True,
                        "fingerprint": environment["fingerprint"],
                    }
                    for stage in ("build-after", "run-after", "summary-after")
                ],
                "vcs_verifications": [
                    {
                        "stage": stage,
                        "stable": True,
                        "fingerprint": suite["vcs"]["fingerprint"],
                    }
                    for stage in ("build-after", "run-after", "summary-after")
                ],
                "build_artifacts": {
                    "schema": BUILD_ARTIFACT_SCHEMA,
                    "fingerprint": build_fingerprint,
                    "app_executable": {"sha256": executable_fingerprint},
                    "ui_test_executable": {"sha256": "sha256:" + "e" * 64},
                    "xctestrun": {"sha256": "sha256:" + "f" * 64},
                    "artifacts_stable": True,
                    "verifications": [
                        {
                            "stage": "build-after",
                            "stable": True,
                            "fingerprint": build_fingerprint,
                            "environment_fingerprint": environment["fingerprint"],
                            "vcs_fingerprint": suite["vcs"]["fingerprint"],
                        },
                        {
                            "stage": "run-after",
                            "stable": True,
                            "fingerprint": build_fingerprint,
                            "environment_fingerprint": environment["fingerprint"],
                            "vcs_fingerprint": suite["vcs"]["fingerprint"],
                        },
                        {
                            "stage": "summary-after",
                            "stable": True,
                            "fingerprint": build_fingerprint,
                            "environment_fingerprint": environment["fingerprint"],
                            "vcs_fingerprint": suite["vcs"]["fingerprint"],
                        },
                    ],
                },
            },
            indent=2,
        )
        + "\n",
        encoding="utf-8",
    )
    for pair in range(1, repeats + 1):
        order = "AB" if pair % 2 == 1 else "BA"
        for variant in ("baseline", "current"):
            payload = _fixture_payload(axis, variant, pair, commands)
            path = root / "raw" / variant / f"fixed-warm-text-pair{pair:02d}-{order}-{variant}.json"
            path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _mutate_fixture_file(
    root: Path,
    variant: str,
    pair: int,
    mutate: Callable[[dict[str, Any]], None],
) -> None:
    order = "AB" if pair % 2 == 1 else "BA"
    path = root / "raw" / variant / f"fixed-warm-text-pair{pair:02d}-{order}-{variant}.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    mutate(payload)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def _mutate_source_manifest(root: Path, mutate: Callable[[dict[str, Any]], None]) -> None:
    path = root / "source-manifest.json"
    payload = json.loads(path.read_text(encoding="utf-8"))
    mutate(payload)
    path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")


def run_self_test() -> int:
    checks = 0

    def expect_valid(
        axis: str,
        *,
        mutate: Callable[[Path], None] | None = None,
        allow_missing_summary_after: bool = False,
        repeats: int = 5,
        commands: int = 1_440,
        diagnostic: bool = False,
    ) -> None:
        nonlocal checks
        with tempfile.TemporaryDirectory(prefix="scopy-warm-summary-") as directory:
            root = Path(directory)
            _write_fixture(root, axis, repeats=repeats, commands=commands)
            if mutate is not None:
                mutate(root)
            summary = build_summary(
                root,
                repeats,
                commands,
                36,
                2,
                axis,
                allow_missing_summary_after=allow_missing_summary_after,
                diagnostic=diagnostic,
            )
            if summary["errors"]:
                raise SummaryValidationError(f"valid {axis} fixture failed: {summary['errors']}")
            contract = summary["contract"]
            if contract["environment"].get("sdk", {}).get("version") != "26.1":
                raise SummaryValidationError("valid fixture omitted SDK metadata")
            if contract["suite"].get("runner", {}).get("version_arguments") != [
                "MARKETING_VERSION=0.8.8",
                "CURRENT_PROJECT_VERSION=409",
            ]:
                raise SummaryValidationError("valid fixture omitted exact build version arguments")
            if contract["display_sampling"].get("screen_maximum_frames_per_second") != 120:
                raise SummaryValidationError("valid fixture omitted display capability")
            expected_evidence_level = "diagnostic" if diagnostic else "formal"
            if contract.get("evidence_level") != expected_evidence_level:
                raise SummaryValidationError("valid fixture mislabeled its evidence level")
            _, markdown_path = _write_summary(root, summary)
            markdown = markdown_path.read_text(encoding="utf-8")
            if "refresh_range=not-recorded-by-raw-profile" not in markdown:
                raise SummaryValidationError("valid fixture omitted the refresh-range sampling basis")
        checks += 1

    def expect_invalid(
        name: str,
        mutate: Callable[[Path], None],
        expected_fragment: str,
        *,
        axis: str = "passive-row",
        repeats: int = 5,
        commands: int = 1_440,
        allow_missing_summary_after: bool = False,
        diagnostic: bool = False,
    ) -> None:
        nonlocal checks
        with tempfile.TemporaryDirectory(prefix="scopy-warm-summary-") as directory:
            root = Path(directory)
            _write_fixture(root, axis, repeats=repeats, commands=commands)
            mutate(root)
            summary = build_summary(
                root,
                repeats,
                commands,
                36,
                2,
                axis,
                allow_missing_summary_after=allow_missing_summary_after,
                diagnostic=diagnostic,
            )
            joined = "\n".join(summary["errors"])
            if expected_fragment not in joined:
                raise SummaryValidationError(
                    f"{name}: expected error containing {expected_fragment!r}, found {summary['errors']}"
                )
        checks += 1

    expect_valid("passive-row")
    expect_valid("markdown-menu-cache")
    expect_valid("passive-row", repeats=2, commands=60, diagnostic=True)
    expect_valid(
        "passive-row",
        mutate=lambda root: _mutate_source_manifest(
            root,
            lambda payload: (
                payload.update(
                    {
                        "source_verifications": [
                            entry
                            for entry in payload["source_verifications"]
                            if entry["stage"] != "summary-after"
                        ],
                        "environment_verifications": [
                            entry
                            for entry in payload["environment_verifications"]
                            if entry["stage"] != "summary-after"
                        ],
                        "vcs_verifications": [
                            entry
                            for entry in payload["vcs_verifications"]
                            if entry["stage"] != "summary-after"
                        ],
                    }
                ),
                payload["build_artifacts"].update(
                    {
                        "verifications": [
                            entry
                            for entry in payload["build_artifacts"]["verifications"]
                            if entry["stage"] != "summary-after"
                        ]
                    }
                ),
            ),
        ),
        allow_missing_summary_after=True,
    )
    expect_invalid(
        "strict final source stage",
        lambda root: _mutate_source_manifest(
            root,
            lambda payload: payload.update(
                {
                    "source_verifications": [
                        entry
                        for entry in payload["source_verifications"]
                        if entry["stage"] != "summary-after"
                    ]
                }
            ),
        ),
        "source manifest missing stable summary-after verification",
    )
    expect_invalid(
        "strict final environment stage",
        lambda root: _mutate_source_manifest(
            root,
            lambda payload: payload.update(
                {
                    "environment_verifications": [
                        entry
                        for entry in payload["environment_verifications"]
                        if entry["stage"] != "summary-after"
                    ]
                }
            ),
        ),
        "environment manifest missing stable summary-after verification",
    )
    expect_invalid(
        "strict final build stage",
        lambda root: _mutate_source_manifest(
            root,
            lambda payload: payload["build_artifacts"].update(
                {
                    "verifications": [
                        entry
                        for entry in payload["build_artifacts"]["verifications"]
                        if entry["stage"] != "summary-after"
                    ]
                }
            ),
        ),
        "build artifacts missing stable summary-after verification",
    )
    expect_invalid(
        "strict final VCS stage",
        lambda root: _mutate_source_manifest(
            root,
            lambda payload: payload.update(
                {
                    "vcs_verifications": [
                        entry
                        for entry in payload["vcs_verifications"]
                        if entry["stage"] != "summary-after"
                    ]
                }
            ),
        ),
        "VCS manifest missing stable summary-after verification",
    )
    expect_invalid(
        "preliminary still requires run-after",
        lambda root: _mutate_source_manifest(
            root,
            lambda payload: payload.update(
                {
                    "source_verifications": [
                        entry
                        for entry in payload["source_verifications"]
                        if entry["stage"] != "run-after"
                    ]
                }
            ),
        ),
        "source manifest missing stable run-after verification",
        allow_missing_summary_after=True,
    )
    expect_invalid(
        "missing manifest environment",
        lambda root: _mutate_source_manifest(root, lambda payload: payload.pop("environment")),
        "source-manifest.environment: expected object",
    )
    expect_invalid(
        "missing raw environment",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload.pop("environment"),
        ),
        "current/pair01-AB.environment: expected object",
    )
    expect_invalid(
        "missing SDK environment",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["environment"].pop("sdk"),
        ),
        "current/pair01-AB.environment.sdk: expected object",
    )
    expect_invalid(
        "raw environment drift",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: (
                payload["environment"]["hardware"].update({"chip": "Apple M4 Pro"}),
                payload["environment"].update(
                    {"fingerprint": _environment_fingerprint(payload["environment"])}
                ),
                payload["config"].update(
                    {"environment_fingerprint": payload["environment"]["fingerprint"]}
                ),
            ),
        ),
        "environment fingerprint differs from source-manifest.json",
    )
    expect_invalid(
        "environment verification drift",
        lambda root: _mutate_source_manifest(
            root,
            lambda payload: payload["environment_verifications"][-1].update(
                {"stable": False, "fingerprint": "sha256:" + "9" * 64}
            ),
        ),
        "environment manifest contains an unstable or mismatched verification",
    )
    expect_invalid(
        "missing manifest suite",
        lambda root: _mutate_source_manifest(root, lambda payload: payload.pop("suite")),
        "source-manifest.suite: expected object",
    )
    expect_invalid(
        "raw suite drift",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: (
                payload["suite"]["runner"].update(
                    {"effective_arguments": ["--axis", "passive-row"]}
                ),
                payload["suite"].update({"fingerprint": _suite_fingerprint(payload["suite"])}),
                payload["config"].update(
                    {"suite_fingerprint": payload["suite"]["fingerprint"]}
                ),
            ),
        ),
        "suite fingerprint differs from source-manifest.json",
    )
    expect_invalid(
        "VCS verification drift",
        lambda root: _mutate_source_manifest(
            root,
            lambda payload: payload["vcs_verifications"][-1].update(
                {"stable": False, "fingerprint": "sha256:" + "8" * 64}
            ),
        ),
        "VCS manifest contains an unstable or mismatched verification",
    )
    expect_invalid(
        "short diagnostic",
        lambda _: None,
        "formal evidence requires at least 5 complete pairs",
        repeats=2,
        commands=360,
    )
    expect_invalid(
        "undersized diagnostic",
        lambda _: None,
        "diagnostic evidence requires at least 60 commands",
        repeats=2,
        commands=59,
        diagnostic=True,
    )
    expect_invalid(
        "BA regression",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            2,
            lambda payload: (
                payload["timing_buckets_ms"]["swiftui.row_body_ms"].update(
                    {
                        "count": 1_200,
                        "retained_count": 1_200,
                        "total_count": 1_200,
                        "total_ms": 2_400.0,
                    }
                ),
                payload["main_runloop_active_ms"].update({"total_ms": 3_000.0}),
            ),
        ),
        "pair 2: passive row-body count did not improve",
    )
    expect_invalid(
        "dataset mismatch",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["fixed_workload"]["dataset"].update(
                {"fingerprint": "sha256:" + "c" * 64}
            ),
        ),
        "expected one dataset fingerprint across all runs",
    )
    expect_invalid(
        "dataset shape",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["fixed_workload"]["dataset"].update({"pinned_item_count": 3}),
        ),
        "pinned_item_count: expected 2, found 3",
    )
    expect_invalid(
        "source mismatch",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["config"].update({"source_fingerprint": "sha256:" + "c" * 64}),
        ),
        "source fingerprint differs from source-manifest.json",
    )
    expect_invalid(
        "executable mismatch",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["config"].update(
                {"executable_fingerprint": "sha256:" + "d" * 64}
            ),
        ),
        "executable fingerprint differs from the recorded build",
    )
    expect_invalid(
        "truncated row samples",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["timing_buckets_ms"]["swiftui.row_body_ms"].update(
                {"retained_count": 799, "overwritten_count": 1}
            ),
        ),
        "swiftui.row_body_ms: formal evidence is truncated",
    )
    expect_invalid(
        "duration rate paradox",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: (
                payload.update({"duration_seconds": 20.0}),
                payload["animation_callback_interval_ms"].update({"total_ms": 20_000.0}),
            ),
        ),
        "pair 1: duration regressed by more than 10%",
    )
    expect_invalid(
        "callback count mismatch",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["animation_callback_interval_ms"].update(
                {"count": 1_439, "retained_count": 1_439, "total_count": 1_439}
            ),
        ),
        "animation_callback_interval_ms.total_count: expected 1440",
    )
    expect_invalid(
        "missing counter",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["counters"].pop("row.relative_time_cache_miss"),
        ),
        "missing required field row.relative_time_cache_miss",
    )
    expect_invalid(
        "cache miss",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["counters"].update(
                {"row.descriptor_cache_miss": 1, "row.relative_time_cache_miss": 1}
            ),
        ),
        "descriptor cache must have zero measurement misses",
    )
    expect_invalid(
        "O(1) gauge",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["gauges"].update({"active_slot_max": 2}),
        ),
        "active_slot_max: expected 0...1",
    )
    expect_invalid(
        "pagination",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["counters"].update({"list.pagination_request": 1}),
        ),
        "fixed workload issued a pagination request",
    )
    expect_invalid(
        "metric ingress drop",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["counters"].update({"profile.ingress_dropped": 1}),
        ),
        "metric ingress dropped records",
    )
    expect_invalid(
        "observed path",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["fixed_workload"].update({"observed_path_px": 51_269}),
        ),
        "observed path differs across runs",
    )
    expect_invalid(
        "screen maximum FPS mismatch",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["fixed_workload"].update(
                {"screen_maximum_frames_per_second": 60}
            ),
        ),
        "screen maximum FPS differs across runs",
    )
    expect_invalid(
        "build configuration",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["config"].update({"build_configuration": "Debug"}),
        ),
        "build_configuration: expected 'Release'",
    )
    expect_invalid(
        "axis flag",
        lambda root: _mutate_fixture_file(
            root,
            "current",
            1,
            lambda payload: payload["config"].update({"passive_row": "0"}),
        ),
        "passive_row: expected '1'",
    )

    print(f"warm-scroll summary self-test: {checks} checks passed")
    return 0


def command_summarize(args: argparse.Namespace) -> int:
    out_dir = Path(args.out).expanduser().resolve()
    if not out_dir.is_dir():
        print(f"output directory does not exist: {out_dir}", file=sys.stderr)
        return 2
    summary = build_summary(
        out_dir,
        repeats=args.repeats,
        commands=args.commands,
        step_px=args.step_px,
        warm_rounds=args.warm_rounds,
        axis=args.axis,
        allow_missing_summary_after=args.allow_missing_summary_after,
        diagnostic=args.diagnostic,
    )
    json_path, markdown_path = _write_summary(out_dir, summary)
    print(markdown_path)
    print(json_path)
    return 0 if summary["gate_passed"] else 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    summarize = subparsers.add_parser("summarize", help="validate raw runs and write JSON/Markdown summaries")
    summarize.add_argument("--out", required=True, help="warm-scroll output directory")
    summarize.add_argument("--axis", choices=AXES, required=True)
    summarize.add_argument("--repeats", type=int, required=True)
    summarize.add_argument("--commands", type=int, required=True)
    summarize.add_argument("--step-px", type=float, default=FIXED_STEP_PX)
    summarize.add_argument("--warm-rounds", type=int, default=FIXED_WARM_ROUNDS)
    summarize.add_argument(
        "--diagnostic",
        action="store_true",
        help="validate provenance/workload with at least two AB/BA pairs without formal improvement thresholds",
    )
    summarize.add_argument(
        "--allow-missing-summary-after",
        action="store_true",
        help="allow only the summary-after source/environment/build stage to be absent",
    )
    summarize.set_defaults(func=command_summarize)

    self_test = subparsers.add_parser("self-test", help="run fixture-driven schema and gate checks")
    self_test.set_defaults(func=lambda _: run_self_test())
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
