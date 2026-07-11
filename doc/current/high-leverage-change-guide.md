---
doc_type: guide
status: active
owner: maintainers
last_reviewed: 2026-07-11
canonical: true
related_versions:
  - v0.65.2
---

# High-Leverage Change Selection Guide

> **Purpose**: Spend engineering effort on changes with material user, reliability, performance, or delivery impact before polishing low-consequence details.

---

## Selection Rule

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

## Required Evidence Before Implementation

- [ ] Reproduce or trace the current failure/bottleneck end to end.
- [ ] Name the affected users, operations, layers, and worst credible outcome.
- [ ] Compare at least the smallest correct systemic fix and one alternative.
- [ ] Define user-visible invariants and rollback surface.
- [ ] Choose tests or measurements that would fail before and pass after.
- [ ] Confirm the work is not merely cleanup adjacent to a higher-impact unresolved issue.

## Small Changes

A small change is worth doing when it directly:

- closes a high-severity failure mode;
- enables or proves a larger high-leverage change;
- removes a recurring maintenance hazard with broad reach;
- makes the current change safely testable, reversible, or observable.

Defer cosmetic cleanup, speculative abstraction, and isolated micro-optimization when they do not meet one of those conditions.

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
- a higher-severity confirmed issue becomes available.

## Completion Evidence

Before calling a high-leverage change complete:

- [ ] The original failure or bottleneck is directly covered.
- [ ] Full risk-proportional gates pass, not only focused tests.
- [ ] Performance claims use before/after evidence on a realistic workload.
- [ ] No user-facing contract drift is hidden inside the change.
- [ ] Specs, release notes, verification data, and rollback instructions agree.
- [ ] The next roadmap item is re-ranked from current evidence.
