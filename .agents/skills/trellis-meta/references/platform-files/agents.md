# Agents

Trellis agent files define specialized roles. Common Trellis agents in a user project are:

- `trellis-research`
- `trellis-implement`
- `trellis-check`

File locations and formats differ by platform, but responsibility boundaries should stay consistent.

## Agent Responsibilities

| Agent | Responsibility |
| --- | --- |
| `trellis-research` | Investigate the question and write findings into the current task's `research/`. |
| `trellis-implement` | Implement against `prd.md`, `info.md`, `implement.jsonl`, and related spec/research. |
| `trellis-check` | Review changes, fix discovered issues, and run necessary checks. |

Agent files should not become generic chat prompts. They should define input sources, write boundaries, whether code may be changed, and how results are reported.

## Common Paths

| Platform | Agent path |
| --- | --- |
| Claude Code | `.claude/agents/trellis-*.md` |
| Cursor | `.cursor/agents/trellis-*.md` |
| OpenCode | `.opencode/agents/trellis-*.md` |
| Codex | `.codex/agents/trellis-*.toml` |
| Kiro | `.kiro/agents/trellis-*.json` |
| Gemini CLI | `.gemini/agents/trellis-*.md` |
| Qoder | `.qoder/agents/trellis-*.md` |
| CodeBuddy | `.codebuddy/agents/trellis-*.md` |
| Factory Droid | `.factory/droids/trellis-*.md` |
| Pi Agent | `.pi/agents/trellis-*.md` |

GitHub Copilot agent/prompt support is provided by a combination of directories such as `.github/agents/`, `.github/prompts/`, and `.github/skills/`; inspect the files actually generated in the user project.

Main-session workflow platforms such as Kilo, Antigravity, and Windsurf may not have Trellis sub-agent files. They usually rely on workflows/skills to guide the main session.

## Two Context Loading Modes

### hook push

The platform hook injects task context before the agent starts. The agent file itself can focus more on responsibilities and boundaries.

Common on platforms that support agent hooks.

### agent pull

The agent file instructs the agent to read after startup:

- explicit `TASK_DIR=<task-dir>` from the parent prompt, if present.
- `python3 ./.trellis/scripts/task.py current --source`
- current task `prd.md`
- `info.md`
- `implement.jsonl` or `check.jsonl`
- spec/research files referenced by JSONL

This mode fits platforms whose hooks cannot reliably rewrite sub-agent prompts.

For Codex agent-pull files, `TASK_DIR` is first priority. If `<TASK_DIR>/prd.md` exists, local `NO ACTIVE TASK` state is diagnostic only and the agent must proceed from `TASK_DIR` instead of asking for task selection. Exact Codex Trellis agent types are required for TASK_DIR-critical Trellis work. If GPT-5.5/high/other model override is needed, apply it to `trellis-research`, `trellis-implement`, or `trellis-check`; do not switch to generic/default/explorer for model strength.

Generic/explorer/default Codex agents do not load these Trellis agent files. Use them only for non-authoritative scouting or non-Trellis work. For Trellis TASK_DIR work they are forbidden unless the main session explicitly accepts a known-fallible diagnostic-only path and includes the same `TASK_DIR` prelude in the prompt.

## Local Change Scenarios

| User need | Edit location |
| --- | --- |
| Implement agent must follow extra restrictions | The platform's `trellis-implement` agent file. |
| Check agent must run project-specific commands | `trellis-check` agent file, and `.trellis/spec/` if needed. |
| Research agent must output a fixed format | `trellis-research` agent file. |
| Agent cannot read task context | Agent prelude or `inject-subagent-context` hook. |
| Add a project-specific agent | Platform agent directory + related workflow/command/skill entry point. |

## Modification Principles

1. **Keep responsibilities single-purpose**. Do not mix research, implement, and check responsibilities into one agent.
2. **Specify the read order**. Agents must know to start from explicit `TASK_DIR` when present, then fall back to active task, PRD, and JSONL.
3. **Specify write boundaries**. Research usually only writes `research/`; implement can write code; check can fix issues.
4. **Keep semantics synchronized in multi-platform projects**. If the user configured Claude, Codex, and Cursor together, decide whether changes to one platform's agent also need to be applied to others.

## Do Not Default To Editing Upstream Templates

Local AI should default to modifying platform agent files inside the user project. Discuss upstream template source only when the user explicitly wants to contribute the change back to Trellis.
