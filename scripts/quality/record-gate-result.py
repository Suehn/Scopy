#!/usr/bin/env python3
"""Record and summarize Scopy quality gate evidence.

This module is intentionally a manifest writer, not a test runner. Existing
Makefile gates keep their current behavior; this script records their evidence
after the fact and can combine records into JSON and Markdown manifests.
"""

from __future__ import annotations

import argparse
import json
import platform
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta
from pathlib import Path
from typing import Any, Iterable


SCHEMA_VERSION = 1
RECORD_TYPE = "quality_gate_result"
STATUSES = ("passed", "failed", "skipped", "not_run")
CODE_TICK = chr(96)


class ManifestError(ValueError):
    """Raised when a record or manifest input is invalid."""


def local_now() -> datetime:
    return datetime.now().astimezone()


def filename_timestamp(now: datetime | None = None) -> str:
    return (now or local_now()).strftime("%Y-%m-%d_%H-%M-%S")


def format_datetime(value: datetime) -> str:
    return value.astimezone().isoformat(timespec="seconds")


def parse_datetime(raw: str) -> datetime:
    value = raw.strip()
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=local_now().tzinfo)
    return parsed


def normalize_times(
    started_at: str | None,
    ended_at: str | None,
    duration_seconds: float | None,
) -> tuple[datetime, datetime, float]:
    started = parse_datetime(started_at) if started_at else None
    ended = parse_datetime(ended_at) if ended_at else None

    if duration_seconds is not None and duration_seconds < 0:
        raise ManifestError("duration_seconds must be non-negative")

    if started is None and ended is None:
        ended = local_now()
        started = ended - timedelta(seconds=duration_seconds or 0)
    elif started is None and ended is not None:
        started = ended - timedelta(seconds=duration_seconds or 0)
    elif started is not None and ended is None:
        ended = started + timedelta(seconds=duration_seconds) if duration_seconds is not None else local_now()

    assert started is not None
    assert ended is not None

    if duration_seconds is None:
        duration_seconds = (ended - started).total_seconds()

    if duration_seconds < 0:
        raise ManifestError("ended_at must be after started_at")

    return started, ended, round(duration_seconds, 3)


def parse_scalar(raw: str) -> Any:
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return raw


def parse_key_value(raw: str, flag_name: str) -> tuple[str, Any]:
    if "=" not in raw:
        raise ManifestError(f"{flag_name} expects KEY=VALUE, got: {raw}")
    key, value = raw.split("=", 1)
    key = key.strip()
    if not key:
        raise ManifestError(f"{flag_name} key must not be empty")
    return key, parse_scalar(value)


def parse_labeled_path(raw: str) -> tuple[str, str]:
    if "=" in raw:
        left, right = raw.split("=", 1)
        if left and right and "/" not in left and "\\" not in left:
            return left.strip(), right.strip()
    path = raw.strip()
    label = Path(path).name or path
    return label, path


def inspect_artifact(raw: str, checked_at: str) -> dict[str, Any]:
    label, artifact_path = parse_labeled_path(raw)
    probe_path = Path(artifact_path).expanduser()
    artifact: dict[str, Any] = {
        "label": label,
        "path": artifact_path,
        "exists": False,
        "kind": "missing",
        "size_bytes": None,
        "checked_at": checked_at,
    }

    try:
        if probe_path.exists():
            artifact["exists"] = True
            if probe_path.is_file():
                artifact["kind"] = "file"
                artifact["size_bytes"] = probe_path.stat().st_size
            elif probe_path.is_dir():
                artifact["kind"] = "directory"
            else:
                artifact["kind"] = "other"
    except OSError as exc:
        artifact["error"] = str(exc)

    return artifact


def run_git(args: list[str]) -> str | None:
    try:
        result = subprocess.run(
            ["git", *args],
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return result.stdout.strip()


def collect_environment(extra: dict[str, Any] | None = None) -> dict[str, Any]:
    environment: dict[str, Any] = {
        "platform": platform.platform(),
        "python_version": platform.python_version(),
        "cwd": str(Path.cwd()),
    }

    git_head = run_git(["rev-parse", "--short=12", "HEAD"])
    git_branch = run_git(["rev-parse", "--abbrev-ref", "HEAD"])
    git_status = run_git(["status", "--short"])
    if git_head:
        environment["git_head"] = git_head
    if git_branch:
        environment["git_branch"] = git_branch
    if git_status is not None:
        environment["git_dirty"] = bool(git_status)

    if extra:
        environment.update(extra)
    return environment


def exit_status(exit_code: int | None) -> dict[str, Any]:
    if exit_code is None:
        return {"code": None, "description": "not run", "success": None}
    return {
        "code": exit_code,
        "description": f"exit {exit_code}",
        "success": exit_code == 0,
    }


def validate_record(record: dict[str, Any]) -> None:
    status = record.get("status")
    if status not in STATUSES:
        raise ManifestError(f"status must be one of {', '.join(STATUSES)}")

    code = record.get("exit_status", {}).get("code")
    if status == "passed" and code not in (0, None):
        raise ManifestError("passed records must use exit code 0 or omit the code")
    if status == "not_run" and code is not None:
        raise ManifestError("not_run records must not have an exit code")
    if status == "skipped" and not record.get("skip_reason"):
        raise ManifestError("skipped records require --skip-reason")

    for artifact in record.get("artifacts", []):
        if "path" not in artifact or "exists" not in artifact:
            raise ManifestError("artifact entries must include path and exists")


def build_record(
    *,
    name: str,
    command: str,
    status: str,
    exit_code: int | None,
    started_at: str | None = None,
    ended_at: str | None = None,
    duration_seconds: float | None = None,
    artifact_specs: Iterable[str] = (),
    metrics: dict[str, Any] | None = None,
    environment: dict[str, Any] | None = None,
    skip_reason: str | None = None,
    notes: str | None = None,
) -> dict[str, Any]:
    if not name.strip():
        raise ManifestError("name must not be empty")
    if status not in STATUSES:
        raise ManifestError(f"status must be one of {', '.join(STATUSES)}")

    started, ended, duration = normalize_times(started_at, ended_at, duration_seconds)
    checked_at = format_datetime(local_now())
    record = {
        "schema_version": SCHEMA_VERSION,
        "record_type": RECORD_TYPE,
        "name": name,
        "command": command,
        "status": status,
        "started_at": format_datetime(started),
        "ended_at": format_datetime(ended),
        "duration_seconds": duration,
        "exit_status": exit_status(exit_code),
        "artifacts": [inspect_artifact(spec, checked_at) for spec in artifact_specs],
        "metrics": metrics or {},
        "environment": collect_environment(environment),
        "skip_reason": skip_reason,
        "notes": notes,
    }
    validate_record(record)
    return record


def write_json(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def unique_path(path: Path) -> Path:
    if not path.exists():
        return path
    for suffix in range(1, 1000):
        candidate = path.with_name(f"{path.stem}-{suffix}{path.suffix}")
        if not candidate.exists():
            return candidate
    raise ManifestError(f"could not create a unique path near {path}")


def unique_output_pair(json_path: Path, markdown_path: Path) -> tuple[Path, Path]:
    if not json_path.exists() and not markdown_path.exists():
        return json_path, markdown_path
    for suffix in range(1, 1000):
        json_candidate = json_path.with_name(f"{json_path.stem}-{suffix}{json_path.suffix}")
        markdown_candidate = markdown_path.with_name(
            f"{markdown_path.stem}-{suffix}{markdown_path.suffix}"
        )
        if not json_candidate.exists() and not markdown_candidate.exists():
            return json_candidate, markdown_candidate
    raise ManifestError(f"could not create a unique output pair near {json_path}")


def read_record(path: Path) -> dict[str, Any]:
    try:
        record = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        raise ManifestError(f"{path}: invalid JSON: {exc}") from exc
    if record.get("schema_version") != SCHEMA_VERSION:
        raise ManifestError(f"{path}: unsupported schema_version")
    if record.get("record_type") != RECORD_TYPE:
        raise ManifestError(f"{path}: unsupported record_type")
    validate_record(record)
    return record


def output_paths(output_prefix: str | None, output_dir: str | None) -> tuple[Path, Path]:
    if output_prefix:
        prefix = Path(output_prefix)
    else:
        prefix = Path(output_dir or "logs") / f"quality-manifest-{filename_timestamp()}"
    json_path = Path(str(prefix) + ".json")
    markdown_path = Path(str(prefix) + ".md")
    return unique_output_pair(json_path, markdown_path)


def summarize(
    record_paths: list[Path],
    output_prefix: str | None = None,
    output_dir: str | None = "logs",
) -> dict[str, Any]:
    if not record_paths:
        raise ManifestError("summarize requires at least one record path")

    records = [read_record(path) for path in record_paths]
    status_counts = {status: 0 for status in STATUSES}
    total_artifacts = 0
    present_artifacts = 0
    missing_artifacts = 0
    for record in records:
        status_counts[record["status"]] += 1
        for artifact in record.get("artifacts", []):
            total_artifacts += 1
            if artifact.get("exists"):
                present_artifacts += 1
            else:
                missing_artifacts += 1

    if status_counts["failed"]:
        overall_status = "failed"
    elif status_counts["not_run"]:
        overall_status = "incomplete"
    elif status_counts["skipped"] and not status_counts["passed"]:
        overall_status = "skipped"
    elif status_counts["skipped"]:
        overall_status = "passed_with_skips"
    else:
        overall_status = "passed"

    json_path, markdown_path = output_paths(output_prefix, output_dir)
    manifest = {
        "schema_version": SCHEMA_VERSION,
        "manifest_type": "quality_manifest",
        "generated_at": format_datetime(local_now()),
        "overall_status": overall_status,
        "summary": {
            "record_count": len(records),
            "status_counts": status_counts,
            "artifact_count": total_artifacts,
            "present_artifact_count": present_artifacts,
            "missing_artifact_count": missing_artifacts,
        },
        "outputs": {
            "json": str(json_path),
            "markdown": str(markdown_path),
        },
        "source_records": [str(path) for path in record_paths],
        "records": records,
    }

    write_json(json_path, manifest)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.write_text(render_markdown(manifest), encoding="utf-8")
    return manifest


def table_cell(value: Any, limit: int = 120) -> str:
    rendered = str(value).replace("\n", " ").replace("|", "\\|")
    if len(rendered) > limit:
        rendered = rendered[: limit - 1] + "..."
    return rendered


def inline_code(value: Any, limit: int = 120) -> str:
    escaped = table_cell(value, limit).replace(CODE_TICK, "\\" + CODE_TICK)
    return CODE_TICK + escaped + CODE_TICK


def render_markdown(manifest: dict[str, Any]) -> str:
    summary = manifest["summary"]
    counts = summary["status_counts"]
    lines = [
        "# Quality Manifest",
        "",
        f"- Generated: {manifest['generated_at']}",
        f"- Overall status: {manifest['overall_status']}",
        f"- Records: {summary['record_count']}",
        "- Status counts: "
        + ", ".join(f"{status}={counts.get(status, 0)}" for status in STATUSES),
        "- Artifacts: "
        + f"{summary['present_artifact_count']} present, "
        + f"{summary['missing_artifact_count']} missing, "
        + f"{summary['artifact_count']} total",
        "",
        "| Gate | Status | Exit | Duration | Artifacts | Command |",
        "| --- | --- | --- | ---: | --- | --- |",
    ]

    for record in manifest["records"]:
        artifacts = record.get("artifacts", [])
        present = sum(1 for artifact in artifacts if artifact.get("exists"))
        missing = len(artifacts) - present
        artifact_text = f"{present}/{len(artifacts)} present"
        if missing:
            artifact_text += f", {missing} missing"
        code = record.get("exit_status", {}).get("code")
        exit_text = "n/a" if code is None else str(code)
        lines.append(
            "| "
            + " | ".join(
                [
                    table_cell(record["name"]),
                    table_cell(record["status"]),
                    table_cell(exit_text),
                    table_cell(record["duration_seconds"]),
                    table_cell(artifact_text),
                    inline_code(record["command"]),
                ]
            )
            + " |"
        )

    lines.append("")
    lines.append("## Record Details")
    for record in manifest["records"]:
        lines.extend(
            [
                "",
                f"### {record['name']}",
                "",
                f"- Status: {record['status']}",
                f"- Command: {inline_code(record['command'], 240)}",
                f"- Started: {record['started_at']}",
                f"- Ended: {record['ended_at']}",
                f"- Duration seconds: {record['duration_seconds']}",
                f"- Exit: {record['exit_status']['description']}",
            ]
        )
        if record.get("skip_reason"):
            lines.append(f"- Skip reason: {record['skip_reason']}")
        if record.get("metrics"):
            metrics = json.dumps(record["metrics"], sort_keys=True)
            lines.append(f"- Metrics: {inline_code(metrics, 240)}")
        if record.get("artifacts"):
            lines.append("- Artifacts:")
            for artifact in record["artifacts"]:
                exists = "present" if artifact.get("exists") else "missing"
                lines.append(f"  - {artifact['label']}: {artifact['path']} ({exists})")

    return "\n".join(lines) + "\n"


def slugify(value: str) -> str:
    pieces = []
    for char in value.lower():
        if char.isalnum():
            pieces.append(char)
        elif pieces and pieces[-1] != "-":
            pieces.append("-")
    slug = "".join(pieces).strip("-")
    return slug or "gate"


def command_record(args: argparse.Namespace) -> int:
    metrics = dict(parse_key_value(item, "--metric") for item in args.metric)
    environment = dict(parse_key_value(item, "--env") for item in args.env)
    record = build_record(
        name=args.name,
        command=args.command,
        status=args.status,
        exit_code=args.exit_code,
        started_at=args.started_at,
        ended_at=args.ended_at,
        duration_seconds=args.duration_seconds,
        artifact_specs=args.artifact,
        metrics=metrics,
        environment=environment,
        skip_reason=args.skip_reason,
        notes=args.notes,
    )
    output = (
        Path(args.output)
        if args.output
        else Path("logs") / f"gate-result-{slugify(args.name)}-{filename_timestamp()}.json"
    )
    if not args.output:
        output = unique_path(output)
    write_json(output, record)
    print(output)
    return 0


def command_summarize(args: argparse.Namespace) -> int:
    manifest = summarize([Path(path) for path in args.records], args.output_prefix, args.output_dir)
    print(manifest["outputs"]["json"])
    print(manifest["outputs"]["markdown"])
    return 0


def assert_equal(actual: Any, expected: Any, message: str) -> None:
    if actual != expected:
        raise AssertionError(f"{message}: expected {expected!r}, got {actual!r}")


def create_self_test_root(output_dir: str | None) -> tuple[Path, tempfile.TemporaryDirectory[str] | None]:
    if output_dir is None:
        temp_root = tempfile.TemporaryDirectory(prefix="quality-manifest-self-test-")
        return Path(temp_root.name), temp_root

    base_dir = Path(output_dir)
    base_dir.mkdir(parents=True, exist_ok=True)
    stem = f"quality-manifest-self-test-{filename_timestamp()}"
    for suffix in range(1000):
        run_dir = base_dir / (stem if suffix == 0 else f"{stem}-{suffix}")
        try:
            run_dir.mkdir()
            return run_dir, None
        except FileExistsError:
            continue
    raise ManifestError(f"could not create a unique self-test directory under {base_dir}")


def run_self_test(output_dir: str | None) -> tuple[Path, Path]:
    root, temp_root = create_self_test_root(output_dir)

    try:
        fixture_dir = root / "fixtures"
        records_dir = root / "records"
        fixture_dir.mkdir(parents=True, exist_ok=True)
        records_dir.mkdir(parents=True, exist_ok=True)
        existing_artifact = fixture_dir / "existing.log"
        missing_artifact = fixture_dir / "missing.log"
        existing_artifact.write_text("fixture log\n", encoding="utf-8")

        base_started = "2026-01-01T00:00:00+00:00"
        base_ended = "2026-01-01T00:00:02+00:00"
        fixture_specs = [
            {
                "name": "passed-fixture",
                "command": "make build",
                "status": "passed",
                "exit_code": 0,
                "artifacts": [f"existing={existing_artifact}", f"missing={missing_artifact}"],
                "metrics": {"p95_ms": 12.5},
                "skip_reason": None,
            },
            {
                "name": "failed-fixture",
                "command": "make test-unit",
                "status": "failed",
                "exit_code": 65,
                "artifacts": [f"unit_log={existing_artifact}"],
                "metrics": {},
                "skip_reason": None,
            },
            {
                "name": "skipped-fixture",
                "command": "make test-tsan",
                "status": "skipped",
                "exit_code": 0,
                "artifacts": [],
                "metrics": {},
                "skip_reason": "local hosted TSan runtime is known-bad on this toolchain",
            },
            {
                "name": "not-run-fixture",
                "command": "make perf-frontend-profile",
                "status": "not_run",
                "exit_code": None,
                "artifacts": [],
                "metrics": {},
                "skip_reason": "not required for tooling-only manifest self-test",
            },
        ]

        record_paths: list[Path] = []
        for spec in fixture_specs:
            record = build_record(
                name=spec["name"],
                command=spec["command"],
                status=spec["status"],
                exit_code=spec["exit_code"],
                started_at=base_started,
                ended_at=base_ended,
                artifact_specs=spec["artifacts"],
                metrics=spec["metrics"],
                environment={"self_test": True},
                skip_reason=spec["skip_reason"],
            )
            path = records_dir / f"{spec['name']}.json"
            write_json(path, record)
            record_paths.append(path)

        manifest = summarize(
            record_paths,
            output_prefix=str(root / "quality-manifest-self-test"),
            output_dir=None,
        )
        summary = manifest["summary"]
        assert_equal(summary["status_counts"], {status: 1 for status in STATUSES}, "status counts")
        assert_equal(summary["record_count"], 4, "record count")
        assert_equal(summary["present_artifact_count"], 2, "present artifact count")
        assert_equal(summary["missing_artifact_count"], 1, "missing artifact count")
        assert_equal(summary["artifact_count"], 3, "artifact count")

        passed_record = manifest["records"][0]
        artifact_states = {artifact["label"]: artifact["exists"] for artifact in passed_record["artifacts"]}
        assert_equal(artifact_states, {"existing": True, "missing": False}, "artifact existence states")

        json_path = Path(manifest["outputs"]["json"])
        markdown_path = Path(manifest["outputs"]["markdown"])
        if not json_path.exists() or not markdown_path.exists():
            raise AssertionError("summary output files were not written")
        markdown = markdown_path.read_text(encoding="utf-8")
        for status in STATUSES:
            if status not in markdown:
                raise AssertionError(f"markdown summary missing status {status}")

        return json_path, markdown_path
    finally:
        if temp_root is not None:
            temp_root.cleanup()


def command_self_test(args: argparse.Namespace) -> int:
    json_path, markdown_path = run_self_test(args.output_dir)
    print(f"Self-test passed: {json_path}")
    print(f"Self-test summary: {markdown_path}")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command_name", required=True)

    record = subparsers.add_parser("record", help="write one quality gate record")
    record.add_argument("--name", required=True, help="stable gate name, for example make-build")
    record.add_argument("--command", required=True, help="command that produced this result")
    record.add_argument("--status", required=True, choices=STATUSES)
    record.add_argument("--exit-code", type=int, default=None)
    record.add_argument("--started-at", default=None, help="ISO-8601 timestamp")
    record.add_argument("--ended-at", default=None, help="ISO-8601 timestamp")
    record.add_argument("--duration-seconds", type=float, default=None)
    record.add_argument("--artifact", action="append", default=[], help="artifact path, or LABEL=PATH")
    record.add_argument("--metric", action="append", default=[], help="metric as KEY=JSON_VALUE")
    record.add_argument("--env", action="append", default=[], help="environment fact as KEY=JSON_VALUE")
    record.add_argument("--skip-reason", default=None)
    record.add_argument("--notes", default=None)
    record.add_argument("--output", default=None, help="record JSON path")
    record.set_defaults(func=command_record)

    summarize_parser = subparsers.add_parser("summarize", help="combine record JSON files into a manifest")
    summarize_parser.add_argument("records", nargs="+", help="record JSON files")
    summarize_parser.add_argument("--output-prefix", default=None, help="output path prefix without .json/.md")
    summarize_parser.add_argument("--output-dir", default="logs", help="directory for timestamped outputs")
    summarize_parser.set_defaults(func=command_summarize)

    self_test = subparsers.add_parser("self-test", help="run fixture-driven manifest checks")
    self_test.add_argument("--output-dir", default=None, help="optional parent directory to keep self-test artifacts")
    self_test.set_defaults(func=command_self_test)

    return parser


def main(argv: list[str] | None = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except (ManifestError, AssertionError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
