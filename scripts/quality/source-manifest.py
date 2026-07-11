#!/usr/bin/env python3
"""Create and verify a byte-exact manifest for Scopy build/profile inputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterable


SCHEMA = "scopy-source-manifest-v1"
BUILD_ARTIFACT_SCHEMA = "scopy-profile-build-artifacts-v1"
ENVIRONMENT_SCHEMA = "scopy-profile-environment-v1"
SUITE_SCHEMA = "scopy-profile-suite-v1"
VCS_SCHEMA = "scopy-profile-vcs-v1"
HASH_DOMAIN = (SCHEMA + "\0").encode("utf-8")
ENVIRONMENT_HASH_DOMAIN = (ENVIRONMENT_SCHEMA + "\0").encode("utf-8")
SUITE_HASH_DOMAIN = (SUITE_SCHEMA + "\0").encode("utf-8")
VCS_HASH_DOMAIN = (VCS_SCHEMA + "\0").encode("utf-8")
TOP_LEVEL_FILES = (
    "Makefile",
    "Package.swift",
    "Package.resolved",
    "project.yml",
)
SOURCE_ROOTS = (
    "Scopy",
    "ScopyTestHost",
    "ScopyTests",
    "ScopyUISupport",
    "ScopyUITests",
    "Tools",
    "scripts",
)
PROJECT_FILES = (
    "Scopy.xcodeproj/project.pbxproj",
    "Scopy.xcodeproj/project.xcworkspace/contents.xcworkspacedata",
    "Scopy.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
)
PROJECT_ROOTS = (
    "Scopy.xcodeproj/xcshareddata/xcschemes",
)
EXCLUDED_DIRECTORY_NAMES = frozenset(
    {
        ".build",
        ".codex",
        ".git",
        ".swiftpm",
        "__pycache__",
        "Build",
        "DerivedData",
        "build",
        "logs",
        "node_modules",
        "xcuserdata",
    }
)
EXCLUDED_FILE_NAMES = frozenset({".DS_Store"})


class ManifestError(RuntimeError):
    """Raised when a source manifest cannot be created or verified."""


def _utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


CommandRunner = Callable[[list[str]], tuple[int, str]]
WhichRunner = Callable[[str], str | None]


def _run_command(arguments: list[str]) -> tuple[int, str]:
    try:
        result = subprocess.run(
            arguments,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return 127, ""
    return result.returncode, result.stdout.strip()


def _probe(arguments: list[str], runner: CommandRunner) -> str:
    return_code, output = runner(arguments)
    return output.strip() if return_code == 0 and output.strip() else "unavailable"


def _resolved_tool_path(tool: str, which_runner: WhichRunner) -> str:
    path = which_runner(tool)
    if not path:
        return "unavailable"
    try:
        return str(Path(path).resolve())
    except OSError:
        return str(path)


def _environment_fingerprint(environment: dict[str, Any]) -> str:
    canonical_payload = {key: value for key, value in environment.items() if key != "fingerprint"}
    canonical = json.dumps(
        canonical_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    digest = hashlib.sha256(ENVIRONMENT_HASH_DOMAIN + canonical).hexdigest()
    return "sha256:" + digest


def _with_environment_fingerprint(environment: dict[str, Any]) -> dict[str, Any]:
    payload = dict(environment)
    payload["fingerprint"] = _environment_fingerprint(payload)
    return payload


def _suite_fingerprint(suite: dict[str, Any]) -> str:
    canonical_payload = {key: value for key, value in suite.items() if key != "fingerprint"}
    canonical = json.dumps(
        canonical_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(SUITE_HASH_DOMAIN + canonical).hexdigest()


def _with_suite_fingerprint(suite: dict[str, Any]) -> dict[str, Any]:
    payload = dict(suite)
    payload["fingerprint"] = _suite_fingerprint(payload)
    return payload


def _vcs_fingerprint(vcs: dict[str, Any]) -> str:
    canonical_payload = {key: value for key, value in vcs.items() if key != "fingerprint"}
    canonical = json.dumps(
        canonical_payload,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    ).encode("utf-8")
    return "sha256:" + hashlib.sha256(VCS_HASH_DOMAIN + canonical).hexdigest()


def _with_vcs_fingerprint(vcs: dict[str, Any]) -> dict[str, Any]:
    payload = dict(vcs)
    payload["fingerprint"] = _vcs_fingerprint(payload)
    return payload


def _parse_xcode_version(raw: str) -> tuple[str, str]:
    version = "unavailable"
    build = "unavailable"
    for line in raw.splitlines():
        stripped = line.strip()
        if stripped.startswith("Xcode ") and len(stripped) > len("Xcode "):
            version = stripped[len("Xcode ") :]
        elif stripped.startswith("Build version ") and len(stripped) > len("Build version "):
            build = stripped[len("Build version ") :]
    return version, build


def capture_environment(
    *,
    xcodebuild_bin: str = "xcodebuild",
    command_runner: CommandRunner = _run_command,
    which_runner: WhichRunner = shutil.which,
) -> dict[str, Any]:
    """Capture the stable machine/toolchain fields required by formal profile evidence."""
    xcodebuild_path = _resolved_tool_path(xcodebuild_bin, which_runner)
    xcode_command = xcodebuild_path if xcodebuild_path != "unavailable" else xcodebuild_bin
    xcode_raw = _probe([xcode_command, "-version"], command_runner)
    xcode_version, xcode_build = _parse_xcode_version(xcode_raw)

    memory_raw = _probe(["/usr/sbin/sysctl", "-n", "hw.memsize"], command_runner)
    physical_memory_bytes: int | str
    try:
        physical_memory_bytes = int(memory_raw)
        if physical_memory_bytes <= 0:
            physical_memory_bytes = "unavailable"
    except ValueError:
        physical_memory_bytes = "unavailable"

    xcodegen_path = _resolved_tool_path("xcodegen", which_runner)
    xcodegen_version = (
        _probe([xcodegen_path, "--version"], command_runner)
        if xcodegen_path != "unavailable"
        else "unavailable"
    )
    xcrun_path = _resolved_tool_path("xcrun", which_runner)
    xcrun_command = xcrun_path if xcrun_path != "unavailable" else "xcrun"
    sdk_prefix = ["--sdk", "macosx"]
    sdk_version_arguments = [*sdk_prefix, "--show-sdk-version"]
    sdk_build_arguments = [*sdk_prefix, "--show-sdk-build-version"]
    sdk_path_arguments = [*sdk_prefix, "--show-sdk-path"]
    environment = {
        "schema": ENVIRONMENT_SCHEMA,
        "macos": {
            "product_name": _probe(["/usr/bin/sw_vers", "-productName"], command_runner),
            "product_version": _probe(["/usr/bin/sw_vers", "-productVersion"], command_runner),
            "build_version": _probe(["/usr/bin/sw_vers", "-buildVersion"], command_runner),
        },
        "hardware": {
            "architecture": _probe(["/usr/bin/uname", "-m"], command_runner),
            "model": _probe(["/usr/sbin/sysctl", "-n", "hw.model"], command_runner),
            "chip": _probe(
                ["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"],
                command_runner,
            ),
            "physical_memory_bytes": physical_memory_bytes,
        },
        "xcode": {
            "version": xcode_version,
            "build_version": xcode_build,
            "developer_dir": _probe(["/usr/bin/xcode-select", "-p"], command_runner),
            "tool_path": xcodebuild_path,
            "version_arguments": ["-version"],
        },
        "sdk": {
            "name": "macosx",
            "version": _probe([xcrun_command, *sdk_version_arguments], command_runner),
            "build_version": _probe([xcrun_command, *sdk_build_arguments], command_runner),
            "path": _probe([xcrun_command, *sdk_path_arguments], command_runner),
            "tool_path": xcrun_path,
            "version_arguments": sdk_version_arguments,
            "build_version_arguments": sdk_build_arguments,
            "path_arguments": sdk_path_arguments,
        },
        "xcodegen": {
            "path": xcodegen_path,
            "version": xcodegen_version,
            "version_arguments": ["--version"],
        },
    }
    return _with_environment_fingerprint(environment)


def _validate_environment(environment: Any, label: str = "manifest.environment") -> dict[str, Any]:
    if not isinstance(environment, dict):
        raise ManifestError(f"{label} must be an object")
    if environment.get("schema") != ENVIRONMENT_SCHEMA:
        raise ManifestError(f"{label}.schema must be {ENVIRONMENT_SCHEMA}")
    fingerprint = environment.get("fingerprint")
    if not isinstance(fingerprint, str) or fingerprint != _environment_fingerprint(environment):
        raise ManifestError(f"{label}.fingerprint is missing or invalid")
    for section_name, required_fields in (
        ("macos", ("product_name", "product_version", "build_version")),
        ("hardware", ("architecture", "model", "chip", "physical_memory_bytes")),
        ("xcode", ("version", "build_version", "developer_dir", "tool_path")),
        ("sdk", ("name", "version", "build_version", "path", "tool_path")),
        ("xcodegen", ("path", "version")),
    ):
        section = environment.get(section_name)
        if not isinstance(section, dict):
            raise ManifestError(f"{label}.{section_name} must be an object")
        for field in required_fields:
            value = section.get(field)
            if field == "physical_memory_bytes":
                if not (
                    (
                        isinstance(value, int)
                        and not isinstance(value, bool)
                        and value > 0
                    )
                    or value == "unavailable"
                ):
                    raise ManifestError(
                        f"{label}.{section_name}.{field} must be a positive integer or unavailable"
                    )
            elif not isinstance(value, str) or not value:
                raise ManifestError(f"{label}.{section_name}.{field} must be a non-empty string")
    for section_name, argument_fields in (
        ("xcode", ("version_arguments",)),
        ("sdk", ("version_arguments", "build_version_arguments", "path_arguments")),
        ("xcodegen", ("version_arguments",)),
    ):
        section = environment[section_name]
        for field in argument_fields:
            arguments = section.get(field)
            if not isinstance(arguments, list) or not arguments or any(
                not isinstance(argument, str) or not argument for argument in arguments
            ):
                raise ManifestError(f"{label}.{section_name}.{field} must be a string array")
    return environment


def _is_excluded(relative_path: Path) -> bool:
    return (
        relative_path.name in EXCLUDED_FILE_NAMES
        or any(part in EXCLUDED_DIRECTORY_NAMES for part in relative_path.parts[:-1])
    )


def _walk_files(root: Path, relative_root: str) -> Iterable[Path]:
    directory = root / relative_root
    if not directory.is_dir():
        return
    for current, directory_names, file_names in os.walk(directory, followlinks=False):
        directory_names[:] = sorted(
            name for name in directory_names if name not in EXCLUDED_DIRECTORY_NAMES
        )
        current_path = Path(current)
        for file_name in sorted(file_names):
            path = current_path / file_name
            relative_path = path.relative_to(root)
            if not _is_excluded(relative_path) and path.is_file():
                yield path


def discover_inputs(root: Path) -> list[Path]:
    """Return every selected build/profile input, including untracked files."""
    candidates: set[Path] = set()
    for relative_path in TOP_LEVEL_FILES + PROJECT_FILES:
        path = root / relative_path
        if path.is_file() and not _is_excluded(Path(relative_path)):
            candidates.add(path)
    for relative_root in SOURCE_ROOTS + PROJECT_ROOTS:
        candidates.update(_walk_files(root, relative_root))
    return sorted(candidates, key=lambda path: path.relative_to(root).as_posix().encode("utf-8"))


def snapshot(root: Path) -> dict[str, Any]:
    files: list[dict[str, Any]] = []
    canonical = hashlib.sha256()
    canonical.update(HASH_DOMAIN)
    for path in discover_inputs(root):
        relative_path = path.relative_to(root).as_posix()
        path_bytes = relative_path.encode("utf-8")
        try:
            data = path.read_bytes()
        except OSError as exc:
            raise ManifestError(f"cannot read source input {relative_path}: {exc}") from exc
        canonical.update(len(path_bytes).to_bytes(8, "big"))
        canonical.update(path_bytes)
        canonical.update(len(data).to_bytes(8, "big"))
        canonical.update(data)
        files.append(
            {
                "path": relative_path,
                "bytes": len(data),
                "sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
            }
        )
    if not files:
        raise ManifestError(f"no source inputs found under {root}")
    return {
        "fingerprint": "sha256:" + canonical.hexdigest(),
        "file_count": len(files),
        "files": files,
    }


def _run_repo_command(root: Path, arguments: list[str]) -> tuple[int, str]:
    try:
        result = subprocess.run(
            arguments,
            cwd=root,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except OSError:
        return 127, ""
    return result.returncode, result.stdout.rstrip()


def _repo_probe(root: Path, arguments: list[str]) -> str:
    return_code, output = _run_repo_command(root, arguments)
    return output.strip() if return_code == 0 and output.strip() else "unavailable"


def capture_vcs_metadata(root: Path) -> dict[str, Any]:
    """Capture repository state whose drift invalidates a formal profile suite."""
    status_code, status_output = _run_repo_command(
        root,
        ["git", "status", "--short", "--untracked-files=all"],
    )
    status_short = status_output.splitlines() if status_code == 0 else ["unavailable"]
    head = _repo_probe(root, ["git", "rev-parse", "HEAD"])
    exact_tag = _repo_probe(root, ["git", "describe", "--tags", "--exact-match", "HEAD"])
    nearest_tag = _repo_probe(
        root,
        ["git", "describe", "--tags", "--abbrev=0", "--match", "v[0-9]*", "HEAD"],
    )
    return _with_vcs_fingerprint(
        {
            "schema": VCS_SCHEMA,
            "head": head,
            "exact_tag": exact_tag,
            "nearest_tag": nearest_tag,
            "dirty": bool(status_short) if status_code == 0 else "unavailable",
            "status_entry_count": len(status_short) if status_code == 0 else "unavailable",
            "status_short": status_short,
        }
    )


def capture_suite_metadata(
    root: Path,
    *,
    runner_script: str = "unavailable",
    runner_arguments: list[str] | None = None,
    effective_runner_arguments: list[str] | None = None,
    version_arguments: list[str] | None = None,
    now: datetime | None = None,
) -> dict[str, Any]:
    """Capture per-suite timing, VCS, invocation, and build-version evidence."""
    captured_local = now if now is not None else datetime.now().astimezone()
    if captured_local.tzinfo is None:
        raise ManifestError("suite capture time must include a timezone")
    suite = {
        "schema": SUITE_SCHEMA,
        "captured_at_utc": captured_local.astimezone(timezone.utc).isoformat(),
        "captured_at_local": captured_local.isoformat(),
        "local_timezone": captured_local.tzname() or "unavailable",
        "vcs": capture_vcs_metadata(root),
        "runner": {
            "script": runner_script,
            "original_arguments": list(runner_arguments or []),
            "effective_arguments": list(effective_runner_arguments or []),
            "version_arguments": list(version_arguments or []),
        },
    }
    return _with_suite_fingerprint(suite)


def _validate_string_array(value: Any, label: str, *, allow_empty: bool) -> list[str]:
    if not isinstance(value, list) or (not allow_empty and not value) or any(
        not isinstance(item, str) or not item for item in value
    ):
        expectation = "string array" if allow_empty else "non-empty string array"
        raise ManifestError(f"{label} must be a {expectation}")
    return value


def _validate_suite(suite: Any, label: str = "manifest.suite") -> dict[str, Any]:
    if not isinstance(suite, dict):
        raise ManifestError(f"{label} must be an object")
    if suite.get("schema") != SUITE_SCHEMA:
        raise ManifestError(f"{label}.schema must be {SUITE_SCHEMA}")
    fingerprint = suite.get("fingerprint")
    if not isinstance(fingerprint, str) or fingerprint != _suite_fingerprint(suite):
        raise ManifestError(f"{label}.fingerprint is missing or invalid")
    for field in ("captured_at_utc", "captured_at_local", "local_timezone"):
        value = suite.get(field)
        if not isinstance(value, str) or not value:
            raise ManifestError(f"{label}.{field} must be a non-empty string")
    vcs = suite.get("vcs")
    if not isinstance(vcs, dict):
        raise ManifestError(f"{label}.vcs must be an object")
    if vcs.get("schema") != VCS_SCHEMA:
        raise ManifestError(f"{label}.vcs.schema must be {VCS_SCHEMA}")
    vcs_fingerprint = vcs.get("fingerprint")
    if not isinstance(vcs_fingerprint, str) or vcs_fingerprint != _vcs_fingerprint(vcs):
        raise ManifestError(f"{label}.vcs.fingerprint is missing or invalid")
    for field in ("head", "exact_tag", "nearest_tag"):
        value = vcs.get(field)
        if not isinstance(value, str) or not value:
            raise ManifestError(f"{label}.vcs.{field} must be a non-empty string")
    dirty = vcs.get("dirty")
    if not isinstance(dirty, bool) and dirty != "unavailable":
        raise ManifestError(f"{label}.vcs.dirty must be a boolean or unavailable")
    status_count = vcs.get("status_entry_count")
    if not (
        (isinstance(status_count, int) and not isinstance(status_count, bool) and status_count >= 0)
        or status_count == "unavailable"
    ):
        raise ManifestError(f"{label}.vcs.status_entry_count must be a non-negative integer or unavailable")
    status_short = _validate_string_array(
        vcs.get("status_short"),
        f"{label}.vcs.status_short",
        allow_empty=True,
    )
    if isinstance(status_count, int) and status_count != len(status_short):
        raise ManifestError(f"{label}.vcs.status_entry_count does not match status_short")
    runner = suite.get("runner")
    if not isinstance(runner, dict):
        raise ManifestError(f"{label}.runner must be an object")
    script = runner.get("script")
    if not isinstance(script, str) or not script:
        raise ManifestError(f"{label}.runner.script must be a non-empty string")
    _validate_string_array(
        runner.get("original_arguments"),
        f"{label}.runner.original_arguments",
        allow_empty=True,
    )
    _validate_string_array(
        runner.get("effective_arguments"),
        f"{label}.runner.effective_arguments",
        allow_empty=True,
    )
    _validate_string_array(
        runner.get("version_arguments"),
        f"{label}.runner.version_arguments",
        allow_empty=True,
    )
    return suite


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w",
        encoding="utf-8",
        dir=path.parent,
        prefix=path.name + ".",
        suffix=".tmp",
        delete=False,
    ) as handle:
        temporary_path = Path(handle.name)
        json.dump(payload, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    os.replace(temporary_path, path)


def _load_manifest(manifest_path: Path) -> dict[str, Any]:
    try:
        payload = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read {manifest_path}: {exc}") from exc
    if not isinstance(payload, dict) or payload.get("schema") != SCHEMA:
        raise ManifestError(f"manifest schema must be {SCHEMA}")
    _validate_environment(payload.get("environment"))
    _validate_suite(payload.get("suite"))
    return payload


def _artifact_entry(path: Path) -> dict[str, Any]:
    try:
        data = path.read_bytes()
    except OSError as exc:
        raise ManifestError(f"cannot read build artifact {path}: {exc}") from exc
    return {
        "path": str(path),
        "bytes": len(data),
        "sha256": "sha256:" + hashlib.sha256(data).hexdigest(),
    }


def _build_artifact_snapshot(
    app_executable: Path,
    ui_test_executable: Path,
    xctestrun: Path,
) -> dict[str, Any]:
    entries = {
        "app_executable": _artifact_entry(app_executable),
        "ui_test_executable": _artifact_entry(ui_test_executable),
        "xctestrun": _artifact_entry(xctestrun),
    }
    canonical = hashlib.sha256()
    canonical.update((BUILD_ARTIFACT_SCHEMA + "\0").encode("utf-8"))
    for name in sorted(entries):
        name_bytes = name.encode("utf-8")
        digest_bytes = entries[name]["sha256"].encode("ascii")
        canonical.update(len(name_bytes).to_bytes(8, "big"))
        canonical.update(name_bytes)
        canonical.update(len(digest_bytes).to_bytes(8, "big"))
        canonical.update(digest_bytes)
    return {
        "schema": BUILD_ARTIFACT_SCHEMA,
        "fingerprint": "sha256:" + canonical.hexdigest(),
        **entries,
    }


def record_build_artifacts(
    manifest_path: Path,
    app_executable: Path,
    ui_test_executable: Path,
    xctestrun: Path,
) -> dict[str, Any]:
    payload = _load_manifest(manifest_path)
    artifacts = _build_artifact_snapshot(app_executable, ui_test_executable, xctestrun)
    artifacts["recorded_at"] = _utc_now()
    artifacts["verifications"] = []
    payload["build_artifacts"] = artifacts
    _write_json_atomic(manifest_path, payload)
    return payload


def verify_build_artifacts(
    manifest_path: Path,
    app_executable: Path,
    ui_test_executable: Path,
    xctestrun: Path,
    stage: str,
) -> tuple[dict[str, Any], bool]:
    payload = _load_manifest(manifest_path)
    expected = payload.get("build_artifacts")
    if not isinstance(expected, dict) or expected.get("schema") != BUILD_ARTIFACT_SCHEMA:
        raise ManifestError("manifest.build_artifacts is missing or invalid")
    current = _build_artifact_snapshot(app_executable, ui_test_executable, xctestrun)
    stable = expected.get("fingerprint") == current["fingerprint"]
    environment = _validate_environment(payload.get("environment"))
    suite = _validate_suite(payload.get("suite"))
    verifications = expected.get("verifications")
    if not isinstance(verifications, list):
        verifications = []
    verifications.append(
        {
            "stage": stage,
            "checked_at": _utc_now(),
            "stable": stable,
            "fingerprint": current["fingerprint"],
            "environment_fingerprint": environment["fingerprint"],
            "vcs_fingerprint": suite["vcs"]["fingerprint"],
        }
    )
    expected["verifications"] = verifications
    expected["last_verified_fingerprint"] = current["fingerprint"]
    expected["artifacts_stable"] = stable
    payload["build_artifacts"] = expected
    _write_json_atomic(manifest_path, payload)
    return payload, stable


def create_manifest(
    root: Path,
    output: Path,
    *,
    environment: dict[str, Any] | None = None,
    suite: dict[str, Any] | None = None,
    xcodebuild_bin: str = "xcodebuild",
    runner_script: str = "unavailable",
    runner_arguments: list[str] | None = None,
    effective_runner_arguments: list[str] | None = None,
    version_arguments: list[str] | None = None,
) -> dict[str, Any]:
    current = snapshot(root)
    captured_environment = _validate_environment(
        environment if environment is not None else capture_environment(xcodebuild_bin=xcodebuild_bin)
    )
    captured_suite = _validate_suite(
        suite
        if suite is not None
        else capture_suite_metadata(
            root,
            runner_script=runner_script,
            runner_arguments=runner_arguments,
            effective_runner_arguments=effective_runner_arguments,
            version_arguments=version_arguments,
        )
    )
    payload: dict[str, Any] = {
        "schema": SCHEMA,
        "canonicalization": "sha256(domain + repeated uint64be(path_bytes) + path_bytes + uint64be(file_bytes) + file_bytes)",
        "generated_at": _utc_now(),
        "git_head": captured_suite["vcs"]["head"],
        "environment": captured_environment,
        "suite": captured_suite,
        **current,
        # A pending manifest cannot be mistaken for post-run-verified evidence.
        "post_run_fingerprint": None,
        "post_run_checked_at": None,
        "source_stable": None,
        "post_run_changed_paths": [],
        "post_run_environment_fingerprint": None,
        "environment_stable": None,
        "environment_verifications": [],
        "post_run_vcs_fingerprint": None,
        "vcs_stable": None,
        "vcs_verifications": [],
    }
    _write_json_atomic(output, payload)
    return payload


def _file_map(files: Any) -> dict[str, tuple[int, str]]:
    if not isinstance(files, list):
        raise ManifestError("manifest.files must be an array")
    result: dict[str, tuple[int, str]] = {}
    for entry in files:
        if not isinstance(entry, dict):
            raise ManifestError("manifest.files entries must be objects")
        path = entry.get("path")
        byte_count = entry.get("bytes")
        digest = entry.get("sha256")
        if not isinstance(path, str) or not isinstance(byte_count, int) or not isinstance(digest, str):
            raise ManifestError("manifest.files entry has invalid path, bytes, or sha256")
        result[path] = (byte_count, digest)
    return result


def verify_manifest(
    root: Path,
    manifest_path: Path,
    stage: str = "post-run",
    *,
    environment: dict[str, Any] | None = None,
    vcs: dict[str, Any] | None = None,
    xcodebuild_bin: str = "xcodebuild",
) -> tuple[dict[str, Any], bool]:
    payload = _load_manifest(manifest_path)

    initial_fingerprint = payload.get("fingerprint")
    if not isinstance(initial_fingerprint, str):
        raise ManifestError("manifest.fingerprint must be a string")
    before = _file_map(payload.get("files"))
    current = snapshot(root)
    after = _file_map(current["files"])
    changed_paths = sorted(
        path for path in set(before) | set(after) if before.get(path) != after.get(path)
    )
    source_stable = initial_fingerprint == current["fingerprint"]
    expected_environment = _validate_environment(payload.get("environment"))
    current_environment = _validate_environment(
        environment if environment is not None else capture_environment(xcodebuild_bin=xcodebuild_bin),
        label="current environment",
    )
    environment_stable = (
        expected_environment["fingerprint"] == current_environment["fingerprint"]
    )
    suite = _validate_suite(payload.get("suite"))
    expected_vcs = suite["vcs"]
    current_vcs = vcs if vcs is not None else capture_vcs_metadata(root)
    if not isinstance(current_vcs, dict) or current_vcs.get("fingerprint") != _vcs_fingerprint(
        current_vcs
    ):
        raise ManifestError("current VCS metadata is missing or invalid")
    vcs_stable = expected_vcs["fingerprint"] == current_vcs["fingerprint"]
    stable = source_stable and environment_stable and vcs_stable
    verifications = payload.get("source_verifications")
    if not isinstance(verifications, list):
        verifications = []
    verifications.append(
        {
            "stage": stage,
            "checked_at": _utc_now(),
            "stable": source_stable,
            "fingerprint": current["fingerprint"],
            "changed_paths": changed_paths,
        }
    )
    environment_verifications = payload.get("environment_verifications")
    if not isinstance(environment_verifications, list):
        environment_verifications = []
    environment_verifications.append(
        {
            "stage": stage,
            "checked_at": _utc_now(),
            "stable": environment_stable,
            "fingerprint": current_environment["fingerprint"],
        }
    )
    vcs_verifications = payload.get("vcs_verifications")
    if not isinstance(vcs_verifications, list):
        vcs_verifications = []
    vcs_verifications.append(
        {
            "stage": stage,
            "checked_at": _utc_now(),
            "stable": vcs_stable,
            "fingerprint": current_vcs["fingerprint"],
        }
    )
    payload.update(
        {
            "post_run_fingerprint": current["fingerprint"],
            "post_run_checked_at": _utc_now(),
            "post_run_file_count": current["file_count"],
            "source_stable": source_stable,
            "post_run_changed_paths": changed_paths,
            "source_verifications": verifications,
            "post_run_environment_fingerprint": current_environment["fingerprint"],
            "environment_stable": environment_stable,
            "environment_verifications": environment_verifications,
            "post_run_vcs_fingerprint": current_vcs["fingerprint"],
            "vcs_stable": vcs_stable,
            "vcs_verifications": vcs_verifications,
        }
    )
    _write_json_atomic(manifest_path, payload)
    return payload, stable


def stamp_run_environment(manifest_path: Path, run_path: Path) -> dict[str, Any]:
    manifest = _load_manifest(manifest_path)
    environment = _validate_environment(manifest.get("environment"))
    suite = _validate_suite(manifest.get("suite"))
    try:
        payload = json.loads(run_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read raw run {run_path}: {exc}") from exc
    if not isinstance(payload, dict):
        raise ManifestError(f"raw run {run_path} must contain a JSON object")
    config = payload.get("config")
    if not isinstance(config, dict):
        raise ManifestError(f"raw run {run_path}.config must be an object")
    config["environment_fingerprint"] = environment["fingerprint"]
    config["suite_fingerprint"] = suite["fingerprint"]
    payload["environment"] = environment
    payload["suite"] = suite
    _write_json_atomic(run_path, payload)
    return payload


def run_self_test() -> int:
    with tempfile.TemporaryDirectory(prefix="scopy-source-manifest-") as directory:
        root = Path(directory)
        fixtures = {
            "Makefile": b"test:\n\t@true\n",
            "Package.swift": b"// package\n",
            "project.yml": b"name: Test\n",
            "Scopy/main.swift": b"print(1)\n",
            "ScopyUITests/ProfileTests.swift": b"// test\n",
            "scripts/perf-warm-scroll-ab.sh": b"#!/bin/bash\n",
            "Scopy.xcodeproj/project.pbxproj": b"// project\n",
            "Scopy.xcodeproj/xcshareddata/xcschemes/Profile.xcscheme": b"<Scheme/>\n",
            "logs/ignored.json": b"runtime\n",
            ".build/ignored.swift": b"generated\n",
            "Scopy.xcodeproj/xcuserdata/user.xcuserdatad/scheme.xcscheme": b"user\n",
            "Tools/MarkdownRenderer/node_modules/package/index.js": b"dependency\n",
        }
        for relative_path, data in fixtures.items():
            path = root / relative_path
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)

        command_outputs: dict[tuple[str, ...], tuple[int, str]] = {
            ("/usr/bin/sw_vers", "-productName"): (0, "macOS"),
            ("/usr/bin/sw_vers", "-productVersion"): (0, "15.7.3"),
            ("/usr/bin/sw_vers", "-buildVersion"): (0, "24G419"),
            ("/usr/bin/uname", "-m"): (0, "arm64"),
            ("/usr/sbin/sysctl", "-n", "hw.model"): (0, "Mac15,6"),
            ("/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"): (0, "Apple M3 Pro"),
            ("/usr/sbin/sysctl", "-n", "hw.memsize"): (0, "38654705664"),
            ("/usr/bin/xcode-select", "-p"): (0, "/Applications/Xcode.app/Contents/Developer"),
            ("/fixture/bin/xcodebuild", "-version"): (
                0,
                "Xcode 26.1.1\nBuild version 17B100",
            ),
            ("/fixture/bin/xcrun", "--sdk", "macosx", "--show-sdk-version"): (0, "26.1"),
            ("/fixture/bin/xcrun", "--sdk", "macosx", "--show-sdk-build-version"): (
                0,
                "25B74",
            ),
            ("/fixture/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"): (
                0,
                "/Applications/Xcode.app/SDKs/MacOSX26.1.sdk",
            ),
            ("/fixture/bin/xcodegen", "--version"): (0, "Version: 2.44.1"),
        }

        def fixture_command_runner(arguments: list[str]) -> tuple[int, str]:
            return command_outputs.get(tuple(arguments), (127, ""))

        def fixture_which(tool: str) -> str | None:
            return {
                "xcodebuild": "/fixture/bin/xcodebuild",
                "xcrun": "/fixture/bin/xcrun",
                "xcodegen": "/fixture/bin/xcodegen",
            }.get(tool)

        fixture_environment = capture_environment(
            command_runner=fixture_command_runner,
            which_runner=fixture_which,
        )
        if fixture_environment["hardware"]["physical_memory_bytes"] != 38_654_705_664:
            raise ManifestError("environment fixture did not parse physical memory")
        if fixture_environment["xcode"] != {
            "version": "26.1.1",
            "build_version": "17B100",
            "developer_dir": "/Applications/Xcode.app/Contents/Developer",
            "tool_path": "/fixture/bin/xcodebuild",
            "version_arguments": ["-version"],
        }:
            raise ManifestError("environment fixture did not parse Xcode metadata")
        if fixture_environment["sdk"]["version"] != "26.1" or (
            fixture_environment["sdk"]["build_version"] != "25B74"
        ):
            raise ManifestError("environment fixture did not parse SDK metadata")

        fixture_suite = _with_suite_fingerprint(
            {
                "schema": SUITE_SCHEMA,
                "captured_at_utc": "2026-07-11T04:00:00+00:00",
                "captured_at_local": "2026-07-11T12:00:00+08:00",
                "local_timezone": "CST",
                "vcs": _with_vcs_fingerprint(
                    {
                        "schema": VCS_SCHEMA,
                        "head": "0123456789abcdef0123456789abcdef01234567",
                        "exact_tag": "unavailable",
                        "nearest_tag": "v0.8.8",
                        "dirty": True,
                        "status_entry_count": 1,
                        "status_short": [" M Scopy/main.swift"],
                    }
                ),
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
        )

        first = snapshot(root)
        expected_paths = {
            path
            for path in fixtures
            if not path.startswith(("logs/", ".build/"))
            and "xcuserdata" not in path
            and "node_modules" not in path
        }
        actual_paths = {entry["path"] for entry in first["files"]}
        if actual_paths != expected_paths:
            raise ManifestError(f"input selection mismatch: {actual_paths} != {expected_paths}")
        if snapshot(root)["fingerprint"] != first["fingerprint"]:
            raise ManifestError("unchanged input produced a different fingerprint")

        manifest_path = root / "logs" / "source-manifest.json"
        created = create_manifest(
            root,
            manifest_path,
            environment=fixture_environment,
            suite=fixture_suite,
        )
        verified, stable = verify_manifest(
            root,
            manifest_path,
            stage="unchanged",
            environment=fixture_environment,
            vcs=fixture_suite["vcs"],
        )
        if not stable or verified["post_run_fingerprint"] != created["fingerprint"]:
            raise ManifestError("unchanged manifest did not verify")
        if not verified["environment_stable"]:
            raise ManifestError("unchanged environment did not verify")

        missing_environment_path = root / "logs" / "missing-environment.json"
        missing_environment_payload = json.loads(json.dumps(created))
        missing_environment_payload.pop("environment")
        _write_json_atomic(missing_environment_path, missing_environment_payload)
        try:
            _load_manifest(missing_environment_path)
        except ManifestError:
            pass
        else:
            raise ManifestError("missing environment was accepted")

        missing_suite_path = root / "logs" / "missing-suite.json"
        missing_suite_payload = json.loads(json.dumps(created))
        missing_suite_payload.pop("suite")
        _write_json_atomic(missing_suite_path, missing_suite_payload)
        try:
            _load_manifest(missing_suite_path)
        except ManifestError:
            pass
        else:
            raise ManifestError("missing suite metadata was accepted")

        drift_manifest_path = root / "logs" / "environment-drift.json"
        create_manifest(
            root,
            drift_manifest_path,
            environment=fixture_environment,
            suite=fixture_suite,
        )
        drift_environment = json.loads(json.dumps(fixture_environment))
        drift_environment["hardware"]["chip"] = "Apple M4 Pro"
        drift_environment = _with_environment_fingerprint(drift_environment)
        drifted, stable = verify_manifest(
            root,
            drift_manifest_path,
            stage="environment-drift",
            environment=drift_environment,
            vcs=fixture_suite["vcs"],
        )
        if stable or drifted["environment_stable"] is not False:
            raise ManifestError("environment drift was not detected")

        vcs_drift_path = root / "logs" / "vcs-drift.json"
        create_manifest(
            root,
            vcs_drift_path,
            environment=fixture_environment,
            suite=fixture_suite,
        )
        drift_vcs = json.loads(json.dumps(fixture_suite["vcs"]))
        drift_vcs["exact_tag"] = "v0.8.9"
        drift_vcs = _with_vcs_fingerprint(drift_vcs)
        vcs_drifted, stable = verify_manifest(
            root,
            vcs_drift_path,
            stage="vcs-drift",
            environment=fixture_environment,
            vcs=drift_vcs,
        )
        if stable or vcs_drifted["vcs_stable"] is not False:
            raise ManifestError("VCS drift was not detected")

        artifact_root = root / "DerivedData"
        app_executable = artifact_root / "Scopy.app" / "Contents" / "MacOS" / "Scopy"
        ui_test_executable = artifact_root / "ScopyUITests.xctest" / "Contents" / "MacOS" / "ScopyUITests"
        xctestrun = artifact_root / "ScopyWarmProfile.xctestrun"
        for path, data in (
            (app_executable, b"app-binary"),
            (ui_test_executable, b"ui-test-binary"),
            (xctestrun, b"xctestrun"),
        ):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        recorded = record_build_artifacts(
            manifest_path,
            app_executable,
            ui_test_executable,
            xctestrun,
        )
        app_digest = recorded["build_artifacts"]["app_executable"]["sha256"]
        if app_digest != "sha256:" + hashlib.sha256(b"app-binary").hexdigest():
            raise ManifestError("app executable fingerprint mismatch")
        verified_build, stable = verify_build_artifacts(
            manifest_path,
            app_executable,
            ui_test_executable,
            xctestrun,
            stage="self-test-stable",
        )
        if not stable or not verified_build["build_artifacts"]["artifacts_stable"]:
            raise ManifestError("unchanged build artifacts did not verify")
        ui_test_executable.write_bytes(b"mutated-ui-test-binary")
        _, stable = verify_build_artifacts(
            manifest_path,
            app_executable,
            ui_test_executable,
            xctestrun,
            stage="self-test-mutated",
        )
        if stable:
            raise ManifestError("build artifact drift was not detected")

        raw_run_path = root / "logs" / "raw-run.json"
        _write_json_atomic(raw_run_path, {"config": {}, "duration_seconds": 1})
        stamped_run = stamp_run_environment(manifest_path, raw_run_path)
        if stamped_run["environment"] != fixture_environment or (
            stamped_run["config"].get("environment_fingerprint")
            != fixture_environment["fingerprint"]
        ):
            raise ManifestError("raw run did not receive the manifest environment")
        if stamped_run["suite"] != fixture_suite or (
            stamped_run["config"].get("suite_fingerprint") != fixture_suite["fingerprint"]
        ):
            raise ManifestError("raw run did not receive the suite metadata")

        (root / "Scopy/main.swift").write_bytes(b"print(2)\n")
        changed, stable = verify_manifest(
            root,
            manifest_path,
            environment=fixture_environment,
            vcs=fixture_suite["vcs"],
        )
        if stable or changed["post_run_changed_paths"] != ["Scopy/main.swift"]:
            raise ManifestError("source drift was not detected precisely")

        (root / "Scopy/NewFile.swift").write_bytes(b"// untracked source\n")
        if "Scopy/NewFile.swift" not in {entry["path"] for entry in snapshot(root)["files"]}:
            raise ManifestError("untracked source was not selected")

    print("source-manifest self-test: 17 checks passed")
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    create = subparsers.add_parser("create", help="write the pre-run source manifest")
    create.add_argument("--root", required=True)
    create.add_argument("--output", required=True)
    create.add_argument("--xcodebuild-bin", default="xcodebuild")
    create.add_argument("--runner-script", default="unavailable")
    create.add_argument("--runner-arguments-json", default="[]")
    create.add_argument("--effective-runner-arguments-json", default="[]")
    create.add_argument("--version-arguments-json", default="[]")

    verify = subparsers.add_parser("verify", help="record and verify the post-run fingerprint")
    verify.add_argument("--root", required=True)
    verify.add_argument("--manifest", required=True)
    verify.add_argument("--stage", default="post-run")
    verify.add_argument("--xcodebuild-bin", default="xcodebuild")

    record_build = subparsers.add_parser(
        "record-build",
        help="record the exact app, UI-test, and xctestrun build artifacts",
    )
    record_build.add_argument("--manifest", required=True)
    record_build.add_argument("--app-executable", required=True)
    record_build.add_argument("--ui-test-executable", required=True)
    record_build.add_argument("--xctestrun", required=True)

    verify_build = subparsers.add_parser(
        "verify-build",
        help="verify the exact app, UI-test, and xctestrun build artifacts",
    )
    verify_build.add_argument("--manifest", required=True)
    verify_build.add_argument("--app-executable", required=True)
    verify_build.add_argument("--ui-test-executable", required=True)
    verify_build.add_argument("--xctestrun", required=True)
    verify_build.add_argument("--stage", required=True)

    stamp_run = subparsers.add_parser(
        "stamp-run",
        help="embed the source manifest environment in one raw profile manifest",
    )
    stamp_run.add_argument("--manifest", required=True)
    stamp_run.add_argument("--run", required=True)

    subparsers.add_parser("self-test", help="run deterministic selection and drift tests")
    return parser


def _parse_json_string_array(raw: str, label: str) -> list[str]:
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as exc:
        raise ManifestError(f"{label} must be valid JSON: {exc}") from exc
    return _validate_string_array(value, label, allow_empty=True)


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        if args.command == "create":
            payload = create_manifest(
                Path(args.root).resolve(),
                Path(args.output).resolve(),
                xcodebuild_bin=args.xcodebuild_bin,
                runner_script=args.runner_script,
                runner_arguments=_parse_json_string_array(
                    args.runner_arguments_json,
                    "--runner-arguments-json",
                ),
                effective_runner_arguments=_parse_json_string_array(
                    args.effective_runner_arguments_json,
                    "--effective-runner-arguments-json",
                ),
                version_arguments=_parse_json_string_array(
                    args.version_arguments_json,
                    "--version-arguments-json",
                ),
            )
            print(payload["fingerprint"])
            return 0
        if args.command == "verify":
            payload, stable = verify_manifest(
                Path(args.root).resolve(),
                Path(args.manifest).resolve(),
                stage=args.stage,
                xcodebuild_bin=args.xcodebuild_bin,
            )
            print(payload["post_run_fingerprint"])
            if not stable:
                if payload["post_run_changed_paths"]:
                    print(
                        "source inputs changed during profile: "
                        + ", ".join(payload["post_run_changed_paths"]),
                        file=sys.stderr,
                    )
                if payload.get("environment_stable") is not True:
                    print(
                        "profile environment changed: "
                        + str(payload.get("post_run_environment_fingerprint", "unavailable")),
                        file=sys.stderr,
                    )
                if payload.get("vcs_stable") is not True:
                    print(
                        "profile VCS state changed: "
                        + str(payload.get("post_run_vcs_fingerprint", "unavailable")),
                        file=sys.stderr,
                    )
            return 0 if stable else 1
        if args.command == "record-build":
            payload = record_build_artifacts(
                Path(args.manifest).resolve(),
                Path(args.app_executable).resolve(),
                Path(args.ui_test_executable).resolve(),
                Path(args.xctestrun).resolve(),
            )
            print(payload["build_artifacts"]["app_executable"]["sha256"])
            return 0
        if args.command == "verify-build":
            payload, stable = verify_build_artifacts(
                Path(args.manifest).resolve(),
                Path(args.app_executable).resolve(),
                Path(args.ui_test_executable).resolve(),
                Path(args.xctestrun).resolve(),
                stage=args.stage,
            )
            print(payload["build_artifacts"]["last_verified_fingerprint"])
            return 0 if stable else 1
        if args.command == "stamp-run":
            payload = stamp_run_environment(
                Path(args.manifest).resolve(),
                Path(args.run).resolve(),
            )
            print(payload["environment"]["fingerprint"])
            return 0
        return run_self_test()
    except ManifestError as exc:
        print(f"source-manifest error: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
