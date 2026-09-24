---
doc_type: portal
status: active
owner: maintainers
last_reviewed: 2026-09-03
canonical: true
---

# Proposals

These documents are not the active source of truth. They are research or draft design material preserved for future work.

Creating a proposal is optional. Use one only when a complex or high-risk change needs durable design review, staged implementation, or decisions that future maintainers must revisit. Small, well-bounded changes should proceed directly with a short working plan when needed; they do not require a task directory, PRD, journal, or proposal.

Once a proposal is implemented, move its lasting contracts into the appropriate canonical document under `doc/current/`. Do not treat proposal presence or status as a development gate.

## Current Contents

- [Review and improvement roadmap, 2026-09-24 (phases, cross-face priorities, conflict rulings, decision register)](./review-roadmap-2026-09-24.md)
- [Frontend interaction review, 2026-09-24 (search typing, hover presentation, memory, keyboard and feedback gaps)](./frontend-interaction-review-2026-09-24.md)
- [Backend search/storage review, 2026-09-24 (index memory, engine decomposition, StorageService isolation, lifecycle)](./backend-search-storage-review-2026-09-24.md)
- [Capture and Markdown pipeline review, 2026-09-24 (capture baseline, render hot path, Swift/JS convergence, export)](./capture-and-markdown-pipeline-review-2026-09-24.md)
- [Maintainability and docs review, 2026-09-24 (doc accuracy table, glossary, comment language, conventions, D1-D13)](./maintainability-and-docs-review-2026-09-24.md)
- [Regression safety net, 2026-09-24 (gate map, guard tests per change class, performance evidence protocol, local UI verification)](./regression-safety-net-2026-09-24.md)
- [Code hygiene audit, 2026-09-19 (redundant tests, assumed behaviour, research-time residue; cleanup plan and decisions)](./code-hygiene-audit-2026-09-19.md)
- [Whole-repo architecture review, 2026-09 (capture, storage, search, preview/export, UI, concurrency)](./architecture-review-2026-09.md)
- [Rich fidelity pass: root causes and surgical fixes](./rich-fidelity-pass.md)
- [Renderer hardening gate: review and implementation plan](./renderer-hardening-gate-plan.md)
- [Markdown preview and clipboard architecture](./markdown-preview-architecture/proposal.md)
- `search-backend-performance-optimization.md`
- `semantic-search-offline-v1.md`
- `v0.11-frontend-design.md`
- `v0.11-improvement-plan.md`
