# fix Codex TASK_DIR override docs

## Goal

Harden this project's local Trellis system so Codex sub-agents with an explicit `TASK_DIR=<task-dir>` load that task and continue instead of stopping on isolated `NO ACTIVE TASK` state.

## What I already know

* Codex sub-agents can start in isolated Trellis sessions where `task.py current --source` legitimately reports no active task.
* A generic Codex explorer stopped with a task-selection prompt even though the parent prompt included `TASK_DIR=/Users/ziyi/Documents/code/Scopy/.trellis/tasks/05-06-architecture-improvement-discovery`.
* A second explorer with the same explicit task path did proceed, so the failure is prompt/system guidance fragility rather than a missing task directory.
* `.codex/hooks/session-start.py`, `.codex/hooks/inject-workflow-state.py`, `.codex/agents/trellis-*.toml`, `.trellis/workflow.md`, and `trellis-meta` references are the local Trellis surfaces that shape this behavior.

## Requirements

* Make explicit `TASK_DIR=<task-dir>` the highest-priority task source for Codex sub-agents when present.
* State that local no-task status is diagnostic only in that case, not a reason to ask the parent to choose a task.
* Apply the rule to research/exploration/implementation/checking, not only `trellis-implement` and `trellis-check`.
* Tell the main session that exact Trellis Codex agent types are required for TASK_DIR-critical Trellis work.
* If GPT-5.5/high/other model override is needed for grilling, decisions, research, implementation, or checking, apply it to `trellis-research`, `trellis-implement`, or `trellis-check` rather than using a generic/default/explorer agent.
* State that generic/default/explorer Codex agents are allowed only for non-authoritative scouting or non-Trellis work; for Trellis TASK_DIR work they are forbidden unless the main session explicitly accepts a known-fallible diagnostic-only path with a mandatory prelude.
* Update both injected hook text and durable local docs so the behavior survives new sessions.
* Keep the change local to this repository's Trellis installation; do not edit upstream Trellis source or global installs.

## Acceptance Criteria

* [x] `.codex/hooks/session-start.py` injects a stronger `TASK_DIR` contract for isolated Codex sub-agents.
* [x] `.codex/hooks/inject-workflow-state.py` fallback no-task/in-progress text matches the stronger contract.
* [x] `.codex/agents/trellis-research.toml`, `trellis-implement.toml`, and `trellis-check.toml` explicitly require `TASK_DIR`-first loading and forbid asking for task selection when `prd.md` exists.
* [x] `.trellis/workflow.md` documents the general Codex sub-agent `TASK_DIR` contract, exact-agent requirement, model override rule, and diagnostic-only generic-agent exception.
* [x] `trellis-meta` reference docs explain the isolated Codex sub-agent failure mode and correct customization points.
* [x] Generated Claude/Cursor Trellis agent docs and sub-agent context hooks honor explicit `TASK_DIR` before active-task fallback, including research persistence to `{TASK_DIR}/research/`.
* [x] `git diff --check` passes.
* [x] Exact Trellis Codex agent instructions preserve the `TASK_DIR`-first contract and forbid no-task-only replies once `prd.md` verifies.

## Verification

* `PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile .codex/hooks/session-start.py .codex/hooks/inject-workflow-state.py .claude/hooks/session-start.py .claude/hooks/inject-workflow-state.py .claude/hooks/inject-subagent-context.py .cursor/hooks/session-start.py .cursor/hooks/inject-workflow-state.py .cursor/hooks/inject-subagent-context.py`: pass.
* Python `tomllib` parse for `.codex/agents/trellis-check.toml`, `trellis-implement.toml`, `trellis-research.toml`, and `.codex/config.toml`: pass.
* `git diff --check`: pass.
* `python3 ./.trellis/scripts/task.py validate 05-06-codex-taskdir-override-docs`: pass.
* `python3 ./.trellis/scripts/task.py validate 05-06-architecture-improvement-discovery`: pass after hardening changes; this confirms the paused architecture task still has valid context files.
* Exact Trellis agent TOML instructions verified by parse and diff review: `trellis-research`, `trellis-implement`, and `trellis-check` all say TASK_DIR-critical work must stay on exact Trellis agents, with model overrides applied there.
* Generic/default Codex sub-agent smoke from the earlier hardening only proves the diagnostic fallback path; it is no longer treated as authoritative Trellis readiness.
* Claude/Cursor `inject-subagent-context.py` smoke with explicit `TASK_DIR=/Users/ziyi/Documents/code/Scopy/.trellis/tasks/05-06-codex-taskdir-override-docs` and no reliable active task: pass. Both hooks injected resolved task dir, PRD content, original prompt, and research persistence constraints; neither injected the stale "Modify any files" research conflict.
* GPT-5.5/high exact `trellis-research` coverage audit wrote `.trellis/tasks/05-06-codex-taskdir-override-docs/research/whole-system-taskdir-coverage-audit.md`: pass.
* GPT-5.5/high exact `trellis-check` whole-system hardening review: pass, no issues found, no self-fixes required. It verified hook simulation while local `task.py current --source` returned `Current task: (none)`, covering the isolated-session failure mode directly.

## Out of Scope

* No product architecture refactor in this task.
* No upstream Trellis template edits.
* No broad rewrite of active-task resolution scripts unless the documentation and prompt hardening proves insufficient.

## Technical Notes

* Active task: `.trellis/tasks/05-06-codex-taskdir-override-docs`.
* Observed failing response pattern: the sub-agent repeated local active task choices instead of verifying the explicit `TASK_DIR` from the parent prompt.
* This task should be completed before resuming `.trellis/tasks/05-06-architecture-improvement-discovery`.
