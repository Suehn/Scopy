#!/usr/bin/env python3
"""Reject GitHub workflows that create or push Git tags.

Release tags are a deliberate maintainer action in Scopy. Workflows may react
to a tag, but branch-push automation must not create one. This validator scans
the executable ``run`` and ``uses`` surfaces without adding a YAML dependency.
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
from pathlib import Path
import re
import sys
from typing import Iterable


RUN_LINE = re.compile(r"^(?P<indent>[ \t]*)(?:-[ \t]+)?run:[ \t]*(?P<value>.*)$")
USES_LINE = re.compile(r"^(?P<indent>[ \t]*)(?:-[ \t]+)?uses:[ \t]*(?P<value>.+?)\s*$")
BLOCK_SCALARS = {"|", "|-", "|+", ">", ">-", ">+"}
GIT_PUSH = re.compile(r"\bgit\s+push\b[^;&|]*", re.IGNORECASE)
GIT_TAG = re.compile(r"\bgit\s+tag(?:\s|$)", re.IGNORECASE)
ALLOWED_BRANCH_PUSH = re.compile(r"^git\s+push\s+origin\s+HEAD:main$", re.IGNORECASE)
FORBIDDEN_USES_FRAGMENTS = (
    "github-tag-action",
    "create-tag-action",
    "git-tag-action",
)
CONTENTS_WRITE = re.compile(r"^[ \t]*contents:[ \t]*write[ \t]*(?:#.*)?$", re.IGNORECASE | re.MULTILINE)
INLINE_CONTENTS_WRITE = re.compile(
    r"^[ \t]*permissions:[ \t]*\{[^}\n]*\bcontents[ \t]*:[ \t]*write\b[^}\n]*\}",
    re.IGNORECASE | re.MULTILINE,
)
WRITE_ALL = re.compile(
    r"^[ \t]*permissions:[ \t]*(?:['\"])?write-all(?:['\"])?[ \t]*(?:#.*)?$",
    re.IGNORECASE | re.MULTILINE,
)


@dataclass(frozen=True)
class Violation:
    path: Path
    line: int
    reason: str
    excerpt: str


@dataclass(frozen=True)
class RunScript:
    start_line: int
    text: str


def _unquote_scalar(value: str) -> str:
    value = value.strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in {"'", '"'}:
        return value[1:-1]
    return value


def _leading_width(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def _extract_run_scripts(source: str) -> list[RunScript]:
    lines = source.splitlines()
    scripts: list[RunScript] = []
    index = 0
    while index < len(lines):
        match = RUN_LINE.match(lines[index])
        if match is None:
            index += 1
            continue

        value = match.group("value").strip()
        start_line = index + 1
        if value not in BLOCK_SCALARS:
            scripts.append(RunScript(start_line, _unquote_scalar(value)))
            index += 1
            continue

        base_indent = len(match.group("indent"))
        block: list[str] = []
        index += 1
        while index < len(lines):
            line = lines[index]
            if line.strip() and _leading_width(line) <= base_indent:
                break
            block.append(line.lstrip(" \t"))
            index += 1
        separator = " " if value.startswith(">") else "\n"
        scripts.append(RunScript(start_line + 1, separator.join(block)))
    return scripts


def _strip_shell_comment(line: str) -> str:
    single_quoted = False
    double_quoted = False
    escaped = False
    for index, char in enumerate(line):
        if escaped:
            escaped = False
            continue
        if char == "\\" and not single_quoted:
            escaped = True
            continue
        if char == "'" and not double_quoted:
            single_quoted = not single_quoted
            continue
        if char == '"' and not single_quoted:
            double_quoted = not double_quoted
            continue
        if char == "#" and not single_quoted and not double_quoted:
            return line[:index]
    return line


def _logical_commands(script: RunScript) -> Iterable[tuple[int, str]]:
    lines = script.text.replace("\\\n", " ").splitlines()
    for offset, raw_line in enumerate(lines):
        command = _strip_shell_comment(raw_line).strip()
        if command:
            yield script.start_line + offset, command


def _validate_run_script(path: Path, script: RunScript) -> list[Violation]:
    violations: list[Violation] = []
    for line_number, command in _logical_commands(script):
        lowered = command.lower()
        if "tag-from-doc.sh" in lowered:
            violations.append(Violation(path, line_number, "workflow invokes the tag creation helper", command))
        if GIT_TAG.search(command):
            violations.append(Violation(path, line_number, "workflow executes git tag", command))
        if "refs/tags" in lowered:
            violations.append(Violation(path, line_number, "workflow command references a tag ref", command))
        if re.search(r"\b(?:gh|hub)\s+release\s+create\b", command, re.IGNORECASE):
            violations.append(Violation(path, line_number, "workflow can create a release tag", command))

        for match in GIT_PUSH.finditer(command):
            push_command = " ".join(match.group(0).split())
            if not ALLOWED_BRANCH_PUSH.fullmatch(push_command):
                violations.append(
                    Violation(
                        path,
                        line_number,
                        "workflow git push is not the allowlisted branch-only 'HEAD:main' update",
                        push_command,
                    )
                )
    return violations


def validate_workflow_file(path: Path) -> list[Violation]:
    source = path.read_text(encoding="utf-8")
    violations: list[Violation] = []

    if path.name == "auto-tag.yml":
        violations.append(Violation(path, 1, "retired automatic tag workflow filename is present", path.name))

    if path.name != "release.yml":
        for pattern, reason in (
            (CONTENTS_WRITE, "non-release workflow grants contents: write"),
            (INLINE_CONTENTS_WRITE, "non-release workflow grants inline contents: write"),
            (WRITE_ALL, "non-release workflow grants write-all"),
        ):
            match = pattern.search(source)
            if match is not None:
                line_number = source.count("\n", 0, match.start()) + 1
                violations.append(Violation(path, line_number, reason, match.group(0).strip()))

    if path.name == "release.yml":
        trigger_header = source.split("\njobs:\n", maxsplit=1)[0]
        required_fragments = ("  push:", "    tags:", '      - "v*"', "  workflow_dispatch:")
        for fragment in required_fragments:
            if fragment not in trigger_header:
                violations.append(
                    Violation(path, 1, f"release workflow is missing trigger fragment {fragment.strip()!r}", fragment)
                )
        for forbidden in ("branches:", "paths:", "pull_request:", "schedule:", "workflow_run:"):
            if forbidden in trigger_header:
                line_number = trigger_header[: trigger_header.index(forbidden)].count("\n") + 1
                violations.append(
                    Violation(path, line_number, f"release workflow has forbidden trigger {forbidden}", forbidden)
                )

    for script in _extract_run_scripts(source):
        violations.extend(_validate_run_script(path, script))

    for line_number, line in enumerate(source.splitlines(), start=1):
        match = USES_LINE.match(line)
        if match is None:
            continue
        action = _unquote_scalar(match.group("value")).lower()
        for fragment in FORBIDDEN_USES_FRAGMENTS:
            if fragment in action:
                violations.append(
                    Violation(path, line_number, f"workflow uses a tag-creation action ({fragment})", line.strip())
                )
                break
    return violations


def workflow_files(workflow_dir: Path) -> list[Path]:
    return sorted({*workflow_dir.glob("*.yml"), *workflow_dir.glob("*.yaml")})


def validate_workflow_dir(workflow_dir: Path) -> tuple[list[Path], list[Violation]]:
    files = workflow_files(workflow_dir)
    violations: list[Violation] = []
    for path in files:
        violations.extend(validate_workflow_file(path))
    return files, violations


def default_workflow_dir() -> Path:
    return Path(__file__).resolve().parents[2] / ".github" / "workflows"


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workflow-dir", type=Path, default=default_workflow_dir())
    args = parser.parse_args(argv)

    if not args.workflow_dir.is_dir():
        print(f"Missing workflow directory: {args.workflow_dir}", file=sys.stderr)
        return 2

    files, violations = validate_workflow_dir(args.workflow_dir)
    if not files:
        print(f"No workflow files found in: {args.workflow_dir}", file=sys.stderr)
        return 2

    if violations:
        print("Release workflow tag policy failed:", file=sys.stderr)
        for violation in violations:
            print(
                f"  {violation.path}:{violation.line}: {violation.reason}: {violation.excerpt}",
                file=sys.stderr,
            )
        return 1

    print(f"Release workflow tag policy OK: {len(files)} workflow(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
