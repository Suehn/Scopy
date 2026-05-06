# Archive Context Path Rewrite Design

## Grill Loop

Q1: Should the fix rewrite task-local JSONL paths during archive, or change validate to resolve old active paths from archived root?

Answer: Rewrite task-local JSONL paths during archive.

Why: Archived tasks should be self-validating and audit-friendly using the paths they actually contain after the move. Keeping `validate` strict also preserves its current contract: a `file` entry must exist at the repo-relative path recorded in the JSONL. Teaching `validate` to guess an old active-task root would make every validation depend on historical path inference, and would hide stale manifests instead of fixing them at the lifecycle boundary that created the stale paths.

Q2: What must not be rewritten?

Answer: Only the top-level JSONL `file` value is eligible, and only when it points at the exact task directory being archived or a descendant of that directory.

Must not rewrite:

- Spec, source, doc, and other non-task paths such as `.trellis/spec/...`, `scripts/...`, or `doc/...`.
- Sibling task paths that merely share a prefix, such as `.trellis/tasks/05-07-example-other/...`.
- Seed/comment rows without a `file` field.
- Reasons or other metadata text, even if that text mentions the old path.
- Malformed JSONL rows; validation remains responsible for reporting malformed context.

## Implementation Evidence

- `rewrite_archived_task_context_paths` rewrites task-local `implement.jsonl` and `check.jsonl` entries after the task directory is moved.
- `archive_task_complete` calls the rewrite immediately after `archive_task_dir`, before hooks and optional archive commit.
- Existing archived contexts were migrated once with the same helper: 16 paths for `05-06-architecture-improvement-discovery`, and 2 paths for `05-06-codex-taskdir-override-docs`.
- Regression coverage lives in `.trellis/scripts/tests/test_task_archive_context_paths.py` and covers task-local file entries, task-local directory entries, leading `./`, Windows separators, sibling task paths, spec paths, seed rows, reasons, malformed rows, and idempotence.
