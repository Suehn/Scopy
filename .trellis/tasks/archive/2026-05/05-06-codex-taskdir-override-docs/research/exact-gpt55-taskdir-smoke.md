# Research: exact GPT-5.5 TASK_DIR smoke

- Query: Verify that an exact Codex Trellis research agent with explicit TASK_DIR proceeds from that task and observes the exact-agent/model-override policy.
- Scope: internal
- Date: 2026-05-07

## Findings

### Files found

- `.trellis/tasks/05-06-codex-taskdir-override-docs/prd.md` - Authoritative task PRD for the Codex TASK_DIR hardening work.
- `.trellis/workflow.md` - Durable Trellis workflow policy, including Codex TASK_DIR contract and exact-agent routing.
- `.codex/agents/trellis-research.toml` - Exact Codex research agent instructions and write boundary.
- `.agents/skills/trellis-meta/references/customize-local/change-agents.md` - Local customization reference for Trellis agent files.
- `.agents/skills/trellis-meta/references/local-architecture/context-injection.md` - Architecture reference for Codex TASK_DIR override behavior.
- `.agents/skills/trellis-meta/references/platform-files/agents.md` - Platform-agent reference documenting agent-pull read order and exact-agent requirements.
- `.trellis/spec/backend/index.md` and `.trellis/spec/frontend/index.md` - Available package spec indexes; no product/backend/frontend spec was more specific than the Trellis meta references for this smoke topic.

### Code patterns

- The PRD requires explicit `TASK_DIR=<task-dir>` to be the highest-priority task source for Codex sub-agents, with local no-task state treated as diagnostic after `prd.md` verifies: `.trellis/tasks/05-06-codex-taskdir-override-docs/prd.md:16` and `.trellis/tasks/05-06-codex-taskdir-override-docs/prd.md:17`.
- The PRD requires exact Trellis Codex agent types for TASK_DIR-critical work and says GPT-5.5/high/other model overrides must be applied to `trellis-research`, `trellis-implement`, or `trellis-check`: `.trellis/tasks/05-06-codex-taskdir-override-docs/prd.md:19` and `.trellis/tasks/05-06-codex-taskdir-override-docs/prd.md:20`.
- The workflow states that a Codex sub-agent must verify `<task-dir>/prd.md` and then treat that directory as authoritative; exact Trellis agents are required for TASK_DIR-critical work, with model overrides applied to the exact agent type: `.trellis/workflow.md:78`.
- The research phase specifically requires `trellis-research` and says GPT-5.5/high/other overrides should be applied there, not by switching to a generic/default/explorer agent: `.trellis/workflow.md:238`, `.trellis/workflow.md:242`, and `.trellis/workflow.md:244`.
- The in-progress workflow state repeats the dispatch rule: use exact `trellis-implement`, `trellis-check`, or `trellis-research`, and keep model overrides on the exact Trellis agent type: `.trellis/workflow.md:598` and `.trellis/workflow.md:599`.
- The exact `trellis-research` agent prelude says a prompt-provided `TASK_DIR` must be verified first and used as authoritative after `prd.md` exists: `.codex/agents/trellis-research.toml:16` and `.codex/agents/trellis-research.toml:20`.
- The exact `trellis-research` agent prelude says this agent is the authoritative research path and that GPT-5.5/high/another model setting should be an override on this agent, not a generic/default/explorer substitution: `.codex/agents/trellis-research.toml:18`.
- The agent customization docs preserve the same read order and exact-agent/model-override rule: `.agents/skills/trellis-meta/references/customize-local/change-agents.md:52`, `.agents/skills/trellis-meta/references/customize-local/change-agents.md:54`, and `.agents/skills/trellis-meta/references/customize-local/change-agents.md:56`.
- The context-injection reference states that explicit `TASK_DIR` outranks local active-task state and that exact Trellis Codex agents must carry this rule: `.agents/skills/trellis-meta/references/local-architecture/context-injection.md:44` and `.agents/skills/trellis-meta/references/local-architecture/context-injection.md:46`.
- The platform-agent reference documents `TASK_DIR` as the first agent-pull input and repeats the exact-agent/model-override policy: `.agents/skills/trellis-meta/references/platform-files/agents.md:52` and `.agents/skills/trellis-meta/references/platform-files/agents.md:61`.

### Smoke result

This exact `trellis-research` run did proceed from the explicit `TASK_DIR=/Users/ziyi/Documents/code/Scopy/.trellis/tasks/05-06-codex-taskdir-override-docs`: it verified `TASK_DIR/prd.md`, treated missing local active-task state as diagnostic, read the task PRD and Trellis policy, created `TASK_DIR/research/`, and wrote this file inside that directory.

The exact-agent/model-override policy is present in the task PRD, the durable workflow, the exact `trellis-research` agent instructions, and the Trellis meta reference docs. The parent prompt identified this smoke test as using exact `agent_type=trellis-research` with `model=gpt-5.5` and high reasoning; repository files can verify the required policy text and this agent's TASK_DIR behavior, but they cannot independently introspect the runtime model selection.

### External references

No external references were needed. The smoke scope is local Trellis behavior and repository policy text.

### Related specs

- `.trellis/spec/backend/index.md` - Available backend spec index; no backend-specific contract applies to this Trellis meta smoke.
- `.trellis/spec/frontend/index.md` - Available frontend spec index; no frontend-specific contract applies to this Trellis meta smoke.

## Caveats / Not Found

- `TASK_DIR/info.md` is absent; this is allowed by the `trellis-research` workflow, which says to read it if it exists.
- This research file proves that this exact agent did not stop on local `NO ACTIVE TASK` and proceeded from explicit `TASK_DIR`; it does not prove generic/default/explorer readiness.
- Runtime model identity is not exposed through the repository files inspected here. The model override part of the smoke is therefore confirmed as policy observed and parent-prompt intent, not independently verified runtime metadata.

