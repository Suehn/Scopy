# Research: Whole-system TASK_DIR coverage audit

- Query: Audit the whole local Trellis system for remaining documentation, platform prompt, hook, or agent wording that could cause Codex or generated platform sub-agents to stop on isolated NO ACTIVE TASK instead of obeying explicit TASK_DIR.
- Scope: internal
- Date: 2026-05-07

## Findings

### Files Found

| File Path | Description |
| --- | --- |
| `.trellis/tasks/05-06-codex-taskdir-override-docs/prd.md` | Current hardening task PRD and acceptance criteria. |
| `.trellis/workflow.md` | Shared Trellis workflow and Codex routing source of truth. |
| `.codex/hooks/session-start.py` | Codex SessionStart hook that injects the explicit TASK_DIR contract. |
| `.codex/hooks/inject-workflow-state.py` | Codex UserPromptSubmit hook and fallback workflow-state breadcrumbs. |
| `.codex/agents/trellis-research.toml` | Exact Codex research agent prelude. |
| `.codex/agents/trellis-implement.toml` | Exact Codex implement agent prelude and JSONL loading contract. |
| `.codex/agents/trellis-check.toml` | Exact Codex check agent prelude and JSONL loading contract. |
| `.agents/skills/trellis-meta/references/customize-local/change-agents.md` | Shared trellis-meta source reference for changing local agent files. |
| `.agents/skills/trellis-meta/references/customize-local/change-context-loading.md` | Shared trellis-meta source reference for context loading changes. |
| `.agents/skills/trellis-meta/references/local-architecture/context-injection.md` | Shared trellis-meta source reference for hook/agent context injection. |
| `.agents/skills/trellis-meta/references/local-architecture/task-system.md` | Shared trellis-meta source reference for active task behavior. |
| `.agents/skills/trellis-meta/references/platform-files/agents.md` | Shared trellis-meta source reference for platform agent context-loading modes. |
| `.claude/agents/trellis-research.md` | Generated Claude research agent; still active-task-first. |
| `.cursor/agents/trellis-research.md` | Generated Cursor research agent; still active-task-first. |
| `.claude/hooks/inject-subagent-context.py` | Claude sub-agent context hook; injects task context for implement/check, not required for research. |
| `.cursor/hooks/inject-subagent-context.py` | Cursor sub-agent context hook; same behavior as Claude. |
| `.claude/skills/trellis-meta/references/**` | Generated Claude trellis-meta copy; still older than shared `.agents` reference files. |
| `.cursor/skills/trellis-meta/references/**` | Generated Cursor trellis-meta copy; same stale hashes and wording as Claude copy. |
| `.trellis/.template-hashes.json` | Template hash registry; confirms generated platform skill files are tracked but should not be hand-edited for business rules. |

### Already Hardened

Codex's shared workflow is hardened at the top-level task-system description: `.trellis/workflow.md:78` says Codex sub-agents may see `Current task: (none)`, must verify explicit `TASK_DIR=<task-dir>`, and must treat verified TASK_DIR as authoritative. The same line requires exact `trellis-research`, `trellis-implement`, and `trellis-check` for TASK_DIR-critical work, with model overrides applied to exact Trellis agents rather than generic/default/explorer agents.

Research routing repeats the same rule: `.trellis/workflow.md:242` through `.trellis/workflow.md:257` requires `trellis-research`, forbids generic/default/explorer for authoritative Trellis research, and provides the mandatory diagnostic-only prelude for any explicitly accepted generic-agent exception.

Implementation and checking dispatch are also hardened. `.trellis/workflow.md:365` through `.trellis/workflow.md:379` tells the main session to start and verify the task, include `TASK_DIR=<task-dir>`, and tells Codex sub-agents to load explicit TASK_DIR first. `.trellis/workflow.md:386` through `.trellis/workflow.md:391` states that the Codex implement agent first checks explicit TASK_DIR and falls back to `task.py current --source` only when TASK_DIR is absent. `.trellis/workflow.md:444` through `.trellis/workflow.md:457` repeats the same contract for `trellis-check`.

Workflow-state breadcrumbs are aligned. The no-task block at `.trellis/workflow.md:579` through `.trellis/workflow.md:586` says explicit TASK_DIR overrides no-task state after PRD verification. The in-progress block at `.trellis/workflow.md:594` through `.trellis/workflow.md:600` requires exact Trellis agent types, keeps model overrides on those exact types, and limits generic/default/generalPurpose agents to non-authoritative or explicitly accepted diagnostic-only paths.

The Codex SessionStart hook injects the contract directly. `.codex/hooks/session-start.py:28` through `.codex/hooks/session-start.py:35` defines `CODEX_TASK_DIR_NOTICE`, including TASK_DIR-first loading, diagnostic-only NO ACTIVE TASK/current-none, JSONL/spec loading, exact-agent requirement, and generic-agent limits. The no-task status path at `.codex/hooks/session-start.py:157` through `.codex/hooks/session-start.py:167` also tells isolated Codex sub-agents with TASK_DIR to proceed from that directory instead of asking for task selection. The guidelines block at `.codex/hooks/session-start.py:306` through `.codex/hooks/session-start.py:323` repeats the exact-agent and mandatory-prelude rules, and the ready block at `.codex/hooks/session-start.py:375` through `.codex/hooks/session-start.py:379` repeats the override.

The per-turn Codex hook is aligned. `.codex/hooks/inject-workflow-state.py:144` through `.codex/hooks/inject-workflow-state.py:173` embeds the no-task TASK_DIR override in fallback breadcrumbs. `.codex/hooks/inject-workflow-state.py:181` through `.codex/hooks/inject-workflow-state.py:206` embeds exact-agent and generic-agent limits for in-progress tasks.

The exact Codex agents are aligned. `.codex/agents/trellis-research.toml:16` through `.codex/agents/trellis-research.toml:29` says explicit TASK_DIR outranks local no-task state and fallback current-none only applies when TASK_DIR is absent. `.codex/agents/trellis-implement.toml:10` through `.codex/agents/trellis-implement.toml:34` and `.codex/agents/trellis-check.toml:10` through `.codex/agents/trellis-check.toml:34` do the same for implement/check, including JSONL rows without `file` being skipped at `.codex/agents/trellis-implement.toml:28` through `.codex/agents/trellis-implement.toml:32` and `.codex/agents/trellis-check.toml:28` through `.codex/agents/trellis-check.toml:32`.

The shared `.agents` trellis-meta references are mostly hardened. `.agents/skills/trellis-meta/references/customize-local/change-agents.md:44` makes read order `TASK_DIR` first, and `.agents/skills/trellis-meta/references/customize-local/change-agents.md:52` through `.agents/skills/trellis-meta/references/customize-local/change-agents.md:56` documents the Codex TASK_DIR override and generic-agent limits. `.agents/skills/trellis-meta/references/customize-local/change-context-loading.md:64` through `.agents/skills/trellis-meta/references/customize-local/change-context-loading.md:86` says TASK_DIR comes before active task and warns not to treat current-none inside isolated Codex sub-agents as decisive. `.agents/skills/trellis-meta/references/local-architecture/context-injection.md:42` through `.agents/skills/trellis-meta/references/local-architecture/context-injection.md:48` and `.agents/skills/trellis-meta/references/local-architecture/task-system.md:59` through `.agents/skills/trellis-meta/references/local-architecture/task-system.md:61` document the same rule. `.agents/skills/trellis-meta/references/platform-files/agents.md:50` through `.agents/skills/trellis-meta/references/platform-files/agents.md:63` now says agent-pull starts from explicit TASK_DIR when present.

### Stale Or Conflicting Wording

Must-fix stale wording remains in generated Claude/Cursor research agents if those platform agents can be spawned with an explicit TASK_DIR prompt in an isolated or missing-active-task state. `.claude/agents/trellis-research.md:30` through `.claude/agents/trellis-research.md:37` says to run `task.py current --source` first and ask the user where to write output if no active task is set. `.cursor/agents/trellis-research.md:30` through `.cursor/agents/trellis-research.md:37` has the same text. Because Claude/Cursor `inject-subagent-context.py` excludes research from `AGENTS_REQUIRE_TASK`, this is not fully neutralized by hook injection: `.claude/hooks/inject-subagent-context.py:60` through `.claude/hooks/inject-subagent-context.py:63` and `.cursor/hooks/inject-subagent-context.py:60` through `.cursor/hooks/inject-subagent-context.py:63` require task context only for implement/check. The hook comments at `.claude/hooks/inject-subagent-context.py:680` through `.claude/hooks/inject-subagent-context.py:713` and `.cursor/hooks/inject-subagent-context.py:680` through `.cursor/hooks/inject-subagent-context.py:713` explicitly say research can work without a task directory, so the research agent's own active-task-first instruction remains important.

Should-fix stale wording remains in generated Claude/Cursor trellis-meta copies. `.claude/skills/trellis-meta/references/customize-local/change-agents.md:40` through `.claude/skills/trellis-meta/references/customize-local/change-agents.md:54` and `.cursor/skills/trellis-meta/references/customize-local/change-agents.md:40` through `.cursor/skills/trellis-meta/references/customize-local/change-agents.md:54` still say read order is `active task -> PRD -> info -> JSONL -> spec/research` and lack the Codex-specific TASK_DIR override notes present in the shared `.agents` copy. `.claude/skills/trellis-meta/references/customize-local/change-context-loading.md:57` through `.claude/skills/trellis-meta/references/customize-local/change-context-loading.md:81` and `.cursor/skills/trellis-meta/references/customize-local/change-context-loading.md:57` through `.cursor/skills/trellis-meta/references/customize-local/change-context-loading.md:81` still make active task the first context source and put `task.py current --source` first in troubleshooting. `.claude/skills/trellis-meta/references/platform-files/agents.md:48` through `.claude/skills/trellis-meta/references/platform-files/agents.md:79` and the matching Cursor file at `.cursor/skills/trellis-meta/references/platform-files/agents.md:48` through `.cursor/skills/trellis-meta/references/platform-files/agents.md:79` still describe agent-pull as current-task first.

The generated Claude/Cursor copies of `local-architecture/context-injection.md` are also stale but lower severity. `.claude/skills/trellis-meta/references/local-architecture/context-injection.md:33` through `.claude/skills/trellis-meta/references/local-architecture/context-injection.md:68` and `.cursor/skills/trellis-meta/references/local-architecture/context-injection.md:33` through `.cursor/skills/trellis-meta/references/local-architecture/context-injection.md:68` lack the Codex TASK_DIR override section found in `.agents/skills/trellis-meta/references/local-architecture/context-injection.md:42` through `.agents/skills/trellis-meta/references/local-architecture/context-injection.md:48`. This does not directly alter Codex runtime behavior, but it can mislead future Trellis customization work from Claude/Cursor sessions.

The shared `.agents/skills/trellis-meta/references/platform-files/overview.md:37` through `.agents/skills/trellis-meta/references/platform-files/overview.md:41` still says pull-based agent files read the active task, PRD, and JSONL after startup. The same sentence appears in `.claude/skills/trellis-meta/references/platform-files/overview.md:37` through `.claude/skills/trellis-meta/references/platform-files/overview.md:41` and `.cursor/skills/trellis-meta/references/platform-files/overview.md:37` through `.cursor/skills/trellis-meta/references/platform-files/overview.md:41`. This is should-fix wording: it is broad explanatory text, but it is now inconsistent with the stronger TASK_DIR-first read order.

### Generated Platform Scope

I found no `.opencode`, `.kiro`, `.gemini`, `.qoder`, `.codebuddy`, `.factory`, `.pi`, `.kilocode`, `.agent`, or `.windsurf` directory in this workspace. `.github` exists, but the searched TASK_DIR/NO ACTIVE TASK/agent-context strings did not surface a generated Trellis platform set comparable to `.claude`, `.cursor`, or `.codex`.

The generated Claude/Cursor files do not need Codex-specific TASK_DIR language merely to operate as Claude/Cursor. Their hook-push model uses `inject-subagent-context.py` to inject active task context for implement/check, and their active-task resolver is platform/session-specific. However, because the trellis-meta skill explains local Trellis customization across platforms and names Codex paths, the generated Claude/Cursor trellis-meta copies should either be synchronized with the shared `.agents` source references or explicitly mark the Codex TASK_DIR override as Codex-only. For the research agent files, the safer cross-platform wording is not Codex-specific: make them accept explicit `TASK_DIR=<task-dir>` when present, verify `prd.md`, and fall back to active task only when TASK_DIR is absent.

### Recommended Edits

Must:

1. Update `.claude/agents/trellis-research.md:30` through `.claude/agents/trellis-research.md:37` and `.cursor/agents/trellis-research.md:30` through `.cursor/agents/trellis-research.md:37` so research agents first look for explicit `TASK_DIR=<task-dir>`, verify `<task-dir>/prd.md`, proceed from it, and only then fall back to `task.py current --source`. If no TASK_DIR and no active task, ask for a task path.
2. When changing those research agents, keep the write boundary unchanged: only `{TASK_DIR}/research/*.md`, creating the directory if needed.

Should:

1. Synchronize generated `.claude/skills/trellis-meta/references/customize-local/change-agents.md`, `.cursor/skills/trellis-meta/references/customize-local/change-agents.md`, `.claude/skills/trellis-meta/references/customize-local/change-context-loading.md`, `.cursor/skills/trellis-meta/references/customize-local/change-context-loading.md`, `.claude/skills/trellis-meta/references/local-architecture/context-injection.md`, `.cursor/skills/trellis-meta/references/local-architecture/context-injection.md`, `.claude/skills/trellis-meta/references/local-architecture/task-system.md`, `.cursor/skills/trellis-meta/references/local-architecture/task-system.md`, `.claude/skills/trellis-meta/references/platform-files/agents.md`, and `.cursor/skills/trellis-meta/references/platform-files/agents.md` with the now-hardened shared `.agents` versions. The SHA-256 comparison shows Claude and Cursor copies are identical to each other but stale versus `.agents` for these files.
2. Update `.agents/skills/trellis-meta/references/platform-files/overview.md:37` through `.agents/skills/trellis-meta/references/platform-files/overview.md:41` and matching Claude/Cursor generated copies so pull-based agents read explicit TASK_DIR first when present, then active task fallback, PRD, and JSONL.
3. Consider changing `.claude/hooks/inject-subagent-context.py` and `.cursor/hooks/inject-subagent-context.py` comments around research from "Research can work without task directory" to "Research can work without an active task only when the prompt supplies or the user confirms a TASK_DIR." This is documentation-level unless code behavior is also changed to parse explicit TASK_DIR from prompt.

Not needed:

1. Do not add Codex-specific TASK_DIR language to Claude/Cursor implement/check agent files solely for Codex's isolated-session problem. Those generated agents are hook-push and do not carry Codex TOML preludes.
2. Do not hand-edit `.trellis/.template-hashes.json`. `.agents/skills/trellis-meta/references/local-architecture/generated-files.md:50` through `.agents/skills/trellis-meta/references/local-architecture/generated-files.md:60` explains hashes are update bookkeeping, not a business-rule source.
3. Do not edit upstream Trellis source or global npm install directories for this local hardening task. The PRD explicitly scopes the work to this repository's Trellis installation.

### Validation Checklist After Edits

1. Run `rg -n "active task ->|start from the active task|If no active task is set, ask the user where|Run \`python3 ./\\.trellis/scripts/task.py current --source\`" .agents .claude .cursor .codex .trellis` and verify remaining hits are either historical research notes, non-agent fallback documentation, or deliberately platform-specific.
2. Run `PYTHONDONTWRITEBYTECODE=1 python3 -m py_compile .codex/hooks/session-start.py .codex/hooks/inject-workflow-state.py .claude/hooks/session-start.py .claude/hooks/inject-workflow-state.py .claude/hooks/inject-subagent-context.py .cursor/hooks/session-start.py .cursor/hooks/inject-workflow-state.py .cursor/hooks/inject-subagent-context.py`.
3. Parse Codex agent TOML with Python `tomllib` for `.codex/agents/trellis-research.toml`, `.codex/agents/trellis-implement.toml`, `.codex/agents/trellis-check.toml`, and `.codex/config.toml`.
4. Run `git diff --check`.
5. Spawn an exact `trellis-research` Codex agent with `TASK_DIR=<task-dir>` while local active task is none or unrelated; pass condition is that it verifies `prd.md`, writes a research file under `TASK_DIR/research/`, and does not ask for task selection.
6. Spawn exact `trellis-implement` and `trellis-check` dry/smoke prompts with explicit TASK_DIR and confirm they read PRD plus role JSONL/spec context before any work.
7. Optional but useful: spawn a generic/default/explorer diagnostic-only Codex agent with the mandatory prelude and confirm its output is labelled non-authoritative and not used as research/implementation/checking readiness.

## Caveats / Not Found

- I did not edit any code, hook, agent, or generated platform file outside this research artifact.
- I did not inspect upstream Trellis templates or global installs because the task PRD marks those out of scope.
- I did not execute live Claude/Cursor sub-agent spawns; the Claude/Cursor risk is based on local generated agent text and hook logic.
- `/Users/ziyi/.codex/memories/MEMORY.md` had no relevant TASK_DIR/Codex sub-agent hit in the quick memory pass, so this audit relies on current workspace files.
