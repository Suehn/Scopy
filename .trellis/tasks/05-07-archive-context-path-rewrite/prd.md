# Fix Archived Task Context Validation

## Problem

Completion audit found that archived Trellis tasks can fail `task.py validate` after `task.py archive` moves a task directory. The failure is caused by `implement.jsonl` and `check.jsonl` entries that point at task-local research files under the original active task path, for example:

`.trellis/tasks/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md`

After archive, the files live under:

`.trellis/tasks/archive/2026-05/05-06-architecture-improvement-discovery/research/candidate3-row-asset-scope.md`

The archived task should remain self-validating and audit-friendly.

## Acceptance Criteria

1. `python3 ./.trellis/scripts/task.py archive <task> --no-commit` rewrites task-local JSONL context paths from the original task directory to the archived task directory.
2. Existing archived tasks from this session validate again:
   - `python3 ./.trellis/scripts/task.py validate .trellis/tasks/archive/2026-05/05-06-architecture-improvement-discovery`
   - `python3 ./.trellis/scripts/task.py validate .trellis/tasks/archive/2026-05/05-06-codex-taskdir-override-docs`
3. Add focused tests or a deterministic script-level regression check that proves archive path rewriting works for task-local research entries while preserving non-task paths.
4. Keep the change scoped to Trellis local scripts/docs. Do not alter Scopy app behavior.
5. Commit with the required Codex co-author trailer after check passes.
