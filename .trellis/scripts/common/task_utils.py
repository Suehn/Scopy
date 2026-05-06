#!/usr/bin/env python3
"""
Task utility functions.

Provides:
    is_safe_task_path   - Validate task path is safe to operate on
    find_task_by_name   - Find task directory by name
    resolve_task_dir    - Resolve task directory from name, relative, or absolute path
    archive_task_dir    - Archive task to monthly directory
    run_task_hooks      - Run lifecycle hooks for task events
"""

from __future__ import annotations

import json
import shutil
import sys
from datetime import datetime
from pathlib import Path

from .paths import get_repo_root, get_tasks_dir

_CONTEXT_JSONL_FILES = ("implement.jsonl", "check.jsonl")


# =============================================================================
# Path Safety
# =============================================================================

def is_safe_task_path(task_path: str, repo_root: Path | None = None) -> bool:
    """Check if a relative task path is safe to operate on.

    Args:
        task_path: Task path (relative to repo_root).
        repo_root: Repository root path. Defaults to auto-detected.

    Returns:
        True if safe, False if dangerous.
    """
    if repo_root is None:
        repo_root = get_repo_root()

    normalized = task_path.replace("\\", "/")

    # Check empty or null
    if not normalized or normalized == "null":
        print("Error: empty or null task path", file=sys.stderr)
        return False

    # Reject absolute paths
    if Path(task_path).is_absolute():
        print(f"Error: absolute path not allowed: {task_path}", file=sys.stderr)
        return False

    # Reject ".", "..", paths starting with "./" or "../", or containing ".."
    if normalized in (".", "..") or normalized.startswith("./") or normalized.startswith("../") or ".." in normalized:
        print(f"Error: path traversal not allowed: {task_path}", file=sys.stderr)
        return False

    # Final check: ensure resolved path is not the repo root
    abs_path = repo_root / Path(normalized)
    if abs_path.exists():
        try:
            resolved = abs_path.resolve()
            root_resolved = repo_root.resolve()
            if resolved == root_resolved:
                print(f"Error: path resolves to repo root: {task_path}", file=sys.stderr)
                return False
        except (OSError, IOError):
            pass

    return True


# =============================================================================
# Task Lookup
# =============================================================================

def find_task_by_name(task_name: str, tasks_dir: Path) -> Path | None:
    """Find task directory by name (exact or suffix match).

    Args:
        task_name: Task name to find.
        tasks_dir: Tasks directory path.

    Returns:
        Absolute path to task directory, or None if not found.
    """
    if not task_name or not tasks_dir or not tasks_dir.is_dir():
        return None

    # Try exact match first
    exact_match = tasks_dir / task_name
    if exact_match.is_dir():
        return exact_match

    # Try suffix match (e.g., "my-task" matches "01-21-my-task")
    for d in tasks_dir.iterdir():
        if d.is_dir() and d.name.endswith(f"-{task_name}"):
            return d

    return None


# =============================================================================
# Archive Operations
# =============================================================================

def archive_task_dir(task_dir_abs: Path, repo_root: Path | None = None) -> Path | None:
    """Archive a task directory to archive/{YYYY-MM}/.

    Args:
        task_dir_abs: Absolute path to task directory.
        repo_root: Repository root path. Defaults to auto-detected.

    Returns:
        Path to archived directory, or None on error.
    """
    if not task_dir_abs.is_dir():
        print(f"Error: task directory not found: {task_dir_abs}", file=sys.stderr)
        return None

    # Get tasks directory (parent of the task)
    tasks_dir = task_dir_abs.parent
    archive_dir = tasks_dir / "archive"
    year_month = datetime.now().strftime("%Y-%m")
    month_dir = archive_dir / year_month

    # Create archive directory
    try:
        month_dir.mkdir(parents=True, exist_ok=True)
    except (OSError, IOError) as e:
        print(f"Error: Failed to create archive directory: {e}", file=sys.stderr)
        return None

    # Move task to archive
    task_name = task_dir_abs.name
    dest = month_dir / task_name

    try:
        shutil.move(str(task_dir_abs), str(dest))
    except (OSError, IOError, shutil.Error) as e:
        print(f"Error: Failed to move task to archive: {e}", file=sys.stderr)
        return None

    return dest


def _repo_relative_posix(path: Path, repo_root: Path) -> str:
    """Return a repo-relative POSIX path without requiring the path to exist."""
    try:
        return path.relative_to(repo_root).as_posix()
    except ValueError:
        try:
            return path.resolve().relative_to(repo_root.resolve()).as_posix()
        except ValueError:
            return path.as_posix()


def _normalize_context_path(path: str) -> str:
    """Normalize JSONL context paths for prefix comparison."""
    normalized = path.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]
    return normalized


def _rewrite_task_local_path(file_path: str, source_task_rel: str, archive_task_rel: str) -> str | None:
    """Return the archived path when a context path points inside the source task."""
    normalized = _normalize_context_path(file_path)
    if normalized == source_task_rel:
        return archive_task_rel
    if normalized.startswith(f"{source_task_rel}/"):
        return f"{archive_task_rel}{normalized[len(source_task_rel):]}"
    return None


def _split_eol(line: str) -> tuple[str, str]:
    """Split one line into body and its original end-of-line marker."""
    if line.endswith("\r\n"):
        return line[:-2], "\r\n"
    if line.endswith("\n"):
        return line[:-1], "\n"
    return line, ""


def _rewrite_context_jsonl_paths(jsonl_file: Path, source_task_rel: str, archive_task_rel: str) -> int:
    """Rewrite task-local file entries in one context JSONL file."""
    if not jsonl_file.is_file():
        return 0

    rewritten = 0
    output_lines: list[str] = []
    for line in jsonl_file.read_text(encoding="utf-8").splitlines(keepends=True):
        body, eol = _split_eol(line)
        if not body.strip():
            output_lines.append(line)
            continue

        try:
            data = json.loads(body)
        except json.JSONDecodeError:
            output_lines.append(line)
            continue

        if not isinstance(data, dict):
            output_lines.append(line)
            continue

        file_path = data.get("file")
        if not isinstance(file_path, str):
            output_lines.append(line)
            continue

        rewritten_path = _rewrite_task_local_path(file_path, source_task_rel, archive_task_rel)
        if rewritten_path is None:
            output_lines.append(line)
            continue

        data["file"] = rewritten_path
        output_lines.append(json.dumps(data, ensure_ascii=False) + eol)
        rewritten += 1

    if rewritten:
        jsonl_file.write_text("".join(output_lines), encoding="utf-8")

    return rewritten


def rewrite_archived_task_context_paths(
    source_task_dir_abs: Path,
    archive_task_dir_abs: Path,
    repo_root: Path | None = None,
) -> int:
    """Rewrite archived task context JSONL paths that pointed at the source task.

    Only the top-level file field is rewritten, and only when it points at the
    exact task directory being archived. Specs, docs, sibling tasks, seed rows,
    reasons, and malformed rows are left untouched.
    """
    if repo_root is None:
        repo_root = get_repo_root()

    source_task_rel = _repo_relative_posix(source_task_dir_abs, repo_root)
    archive_task_rel = _repo_relative_posix(archive_task_dir_abs, repo_root)

    rewritten = 0
    for jsonl_name in _CONTEXT_JSONL_FILES:
        rewritten += _rewrite_context_jsonl_paths(
            archive_task_dir_abs / jsonl_name,
            source_task_rel,
            archive_task_rel,
        )
    return rewritten


def archive_task_complete(
    task_dir_abs: Path,
    repo_root: Path | None = None
) -> dict[str, str]:
    """Complete archive workflow: archive directory.

    Args:
        task_dir_abs: Absolute path to task directory.
        repo_root: Repository root path. Defaults to auto-detected.

    Returns:
        Dict with archive result info.
    """
    if not task_dir_abs.is_dir():
        print(f"Error: task directory not found: {task_dir_abs}", file=sys.stderr)
        return {}

    if repo_root is None:
        repo_root = get_repo_root()

    archive_dest = archive_task_dir(task_dir_abs, repo_root)
    if archive_dest:
        rewritten = rewrite_archived_task_context_paths(task_dir_abs, archive_dest, repo_root)
        return {"archived_to": str(archive_dest), "context_paths_rewritten": str(rewritten)}

    return {}


# =============================================================================
# Task Directory Resolution
# =============================================================================

def resolve_task_dir(target_dir: str, repo_root: Path) -> Path:
    """Resolve task directory to absolute path.

    Supports:
    - Absolute path: /path/to/task
    - Relative path: .trellis/tasks/01-31-my-task
    - Task name: my-task (uses find_task_by_name for lookup)

    Args:
        target_dir: Task directory specification.
        repo_root: Repository root path.

    Returns:
        Resolved absolute path.
    """
    if not target_dir:
        return Path()

    normalized = target_dir.replace("\\", "/")
    while normalized.startswith("./"):
        normalized = normalized[2:]

    # Absolute path
    if Path(target_dir).is_absolute():
        return Path(target_dir)

    # Relative path (contains path separator or starts with .trellis)
    if "/" in normalized or normalized.startswith(".trellis"):
        return repo_root / Path(normalized)

    # Task name - try to find in tasks directory
    tasks_dir = get_tasks_dir(repo_root)
    found = find_task_by_name(target_dir, tasks_dir)
    if found:
        return found

    # Fallback to treating as relative path
    return repo_root / Path(normalized)


# =============================================================================
# Lifecycle Hooks
# =============================================================================

def run_task_hooks(event: str, task_json_path: Path, repo_root: Path) -> None:
    """Run lifecycle hooks for a task event.

    Args:
        event: Event name (e.g. "after_create").
        task_json_path: Absolute path to the task's task.json.
        repo_root: Repository root for cwd and config lookup.
    """
    import os
    import subprocess

    from .config import get_hooks
    from .log import Colors, colored

    commands = get_hooks(event, repo_root)
    if not commands:
        return

    env = {**os.environ, "TASK_JSON_PATH": str(task_json_path)}

    for cmd in commands:
        try:
            result = subprocess.run(
                cmd,
                shell=True,
                cwd=repo_root,
                env=env,
                capture_output=True,
                text=True,
                encoding="utf-8",
                errors="replace",
            )
            if result.returncode != 0:
                print(
                    colored(f"[WARN] Hook failed ({event}): {cmd}", Colors.YELLOW),
                    file=sys.stderr,
                )
                if result.stderr.strip():
                    print(f"  {result.stderr.strip()}", file=sys.stderr)
        except Exception as e:
            print(
                colored(f"[WARN] Hook error ({event}): {cmd} — {e}", Colors.YELLOW),
                file=sys.stderr,
            )


# =============================================================================
# Main Entry (for testing)
# =============================================================================

if __name__ == "__main__":
    repo = get_repo_root()
    tasks = get_tasks_dir(repo)

    print(f"Tasks dir: {tasks}")
    print(f"is_safe_task_path('.trellis/tasks/test'): {is_safe_task_path('.trellis/tasks/test', repo)}")
    print(f"is_safe_task_path('../test'): {is_safe_task_path('../test', repo)}")
