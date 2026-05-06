# Local Context Injection System

Trellis context injection aims to make AI read the right files at the right time instead of relying on model memory. In a user project, injection is implemented by `.trellis/` scripts together with platform hooks, agents, and skills.

## Injected Context Types

| Type | Source | Purpose |
| --- | --- | --- |
| session context | `.trellis/scripts/get_context.py` | Current developer, git status, active task, active tasks, journal, packages. |
| workflow context | `.trellis/workflow.md` | Current Trellis flow and next action. |
| spec context | `.trellis/spec/` + task JSONL | Specs that must be followed during implementation/checking. |
| task context | `.trellis/tasks/<task>/prd.md`, `info.md`, `research/` | Current task requirements, design, and research. |
| platform context | Platform hooks/settings/agents | Lets different AI tools read the files above through their own mechanisms. |

## session-start

Platforms with session-start support inject a Trellis overview when a session starts, clears, compacts, or receives a similar event. Injected content usually includes:

- workflow summary.
- current task status.
- active tasks.
- spec index paths.
- developer identity and git status.

If the user feels the AI does not know the current task in a new session, first check whether the platform's session-start hook or equivalent mechanism is installed and running.

## workflow-state

workflow-state is a lightweight hint injected around each user turn. Based on current task status, it selects a block from `.trellis/workflow.md`, such as `no_task`, `planning`, `in_progress`, or `completed`.

If the user wants to change "what the AI should do next in a given state," edit the corresponding state block in `.trellis/workflow.md` first.

## sub-agent context

Implement and check agents need task context. Trellis has two loading modes:

1. **hook push**: a platform hook injects `prd.md` and the files referenced by `implement.jsonl` / `check.jsonl` before the agent starts.
2. **agent pull**: the agent definition instructs the agent to read the active task, PRD, and JSONL context after startup.

In both modes, JSONL files in the task directory are the key interface.

### Codex `TASK_DIR` override

Codex sub-agents can start in isolated sessions where their local active task is empty even though the parent session selected a task. For Codex, an explicit `TASK_DIR=<task-dir>` in the parent prompt has higher priority than the sub-agent's local active-task state. The agent must verify `<task-dir>/prd.md`; if it exists, `NO ACTIVE TASK` and `task.py current --source` returning `Current task: (none)` are diagnostic only, not a reason to ask the parent to choose a task.

Exact Trellis Codex agents (`trellis-research`, `trellis-implement`, `trellis-check`) must carry this rule in their agent prelude and are required for TASK_DIR-critical Trellis work. If GPT-5.5/high/other model override is needed for research, grilling, decisions, implementation, or checking, apply that override to the exact Trellis agent type instead of switching to a generic/default/explorer agent.

Generic/explorer/default Codex agents do not receive the curated Trellis role prelude or JSONL loading contract. Use them only for non-authoritative scouting or non-Trellis work. For Trellis TASK_DIR work they are forbidden unless the main session explicitly accepts a known-fallible diagnostic-only path; in that exception, the prompt must include a manual prelude that verifies `TASK_DIR`, treats it as authoritative, and avoids no-task-only replies once `prd.md` verifies.

## JSONL Reading Rules

`implement.jsonl` and `check.jsonl` contain one JSON object per line:

```jsonl
{"file": ".trellis/spec/backend/index.md", "reason": "Backend rules"}
```

Readers should skip seed rows without a `file` field. When configuring JSONL, the AI should include only spec/research files, not pre-register code files that will be modified.

## Active Task And Context Key

Active task state lives in `.trellis/.runtime/sessions/` and is isolated per session. Hooks try to resolve the context key from platform events, environment variables, transcript paths, or `TRELLIS_CONTEXT_ID`.

If shell commands cannot see the same context key, `task.py current --source` may report no active task. In that case, check whether the platform passes session identity into the shell instead of hand-writing a global current-task file.

## Local Customization Points

| Need | Edit location |
| --- | --- |
| Change session-start injected content | The platform's `session-start` hook or plugin file. |
| Change per-turn workflow-state rules | State blocks in `.trellis/workflow.md` and the platform workflow-state hook. |
| Change how sub-agents read context | Platform agent definitions, the `inject-subagent-context` hook, or agent preludes. |
| Change JSONL validation/display | `.trellis/scripts/common/task_context.py`. |
| Change active task resolution | `.trellis/scripts/common/active_task.py`. |

When modifying context injection, verify two things: new sessions can see the correct task, and exact Trellis sub-agents can see the correct PRD/spec/research. For Codex, also smoke-test an isolated exact Trellis sub-agent prompt containing explicit `TASK_DIR=<task-dir>`; success means it verifies `prd.md` and proceeds instead of replying with task-selection or no-active-task guidance. A generic/default/explorer smoke test can only prove the diagnostic fallback path, not authoritative Trellis readiness.
