---
doc_type: guide
status: active
owner: maintainers
last_reviewed: 2026-09-05
canonical: true
related_versions:
  - v0.65.2
---

# High-Leverage Change Selection Guide

> **Purpose**: Spend engineering effort on changes with material user, reliability, performance, or delivery impact before polishing low-consequence details.

---

## Selection Rule

Use this guide to select work in an open-ended audit or roadmap request. An explicit user request, including focused cleanup, defines the task; this guide does not require replacing it with a different priority.

Rank candidate work by evidence, not novelty:

```
priority = severity x affected surface x recurrence or likelihood x confidence
           ---------------------------------------------------------------
                         implementation and rollback cost
```

The formula is a comparison aid, not a fake precision score. A candidate should have a concrete failure mode, bottleneck, or violated invariant plus evidence from current code, tests, profiles, runtime data, or release wiring.

## High-Leverage Signals

Prefer work that removes one or more of these:

- deterministic crashes, data loss, corruption, privacy or security failures;
- incorrect deletion, persistence, synchronization, or recovery behavior;
- release paths that can publish without required quality gates;
- measured hot-path latency, memory, CPU, I/O, or unbounded-work bottlenecks affecting many operations;
- architectural seams that repeatedly cause cross-layer defects or block safe extension;
- missing observability or rollback boundaries for high-risk production behavior.

## Evidence Proportional To The Decision

For a material bug or bottleneck, reproduce it or trace the failing boundary, identify affected behavior, and select evidence that distinguishes the fix from the baseline. Compare alternatives when there is a real architectural, performance, or rollback tradeoff; a small local fix needs no artificial second design.

For requested cleanup, verify callers, runtime entrypoints, and the behavior each test protects. Remove a wrapper or obsolete path when its responsibility is already covered. Retain distinct failure coverage even when tests look similar. The useful result is less maintenance with preserved behavior, not a deletion quota or a new abstraction.

Name user-visible invariants and the rollback surface for cross-module or risky changes. Keep these in the working plan unless durable review is needed.

## Quality Is A Constraint, Not A Substitute For Impact

Every selected change must still preserve:

- performance or a measured performance budget;
- stability and user-visible behavior;
- clear ownership and extensible boundaries;
- maintainability, tests, documentation, and coherent Git rollback;
- compatibility with the current deployment baseline.

Elegant implementation does not rescue a low-value target. High impact does not excuse an unsafe implementation.

## Stop Or Re-Scope When

- the claimed impact cannot be reproduced or measured;
- the fix expands across unrelated subsystems without stronger evidence;
- regression coverage cannot observe the failure boundary;
- rollback would require reverting unrelated behavior;
- a higher-severity confirmed issue makes the current plan unsafe or invalid; explain the impact and reconcile the scope rather than silently switching tasks.

## Completion Evidence

Before calling a high-leverage change complete:

- [ ] The original failure or bottleneck is directly covered.
- [ ] Full risk-proportional gates pass, not only focused tests.
- [ ] Performance claims use before/after evidence on a realistic workload.
- [ ] No user-facing contract drift is hidden inside the change.
- [ ] Affected canonical docs and verification evidence agree; release records change only within release scope or to correct release facts.

Stop when the requested outcome and applicable gates are satisfied. Re-rank remaining candidates only if the user requested ongoing roadmap selection; a completed fix does not automatically start another task.
