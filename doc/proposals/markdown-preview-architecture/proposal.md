---
doc_type: proposal
status: draft
owner: maintainers
last_reviewed: 2026-07-11
canonical: false
---

# Markdown Preview and Clipboard Architecture

## Goal

Design a stable, extensible, regression-resistant architecture for Scopy's Markdown preview, PNG export, clipboard capture, persistence, deduplication, and replay. The design must preserve source fidelity, make renderer behavior deterministic, keep preview/export semantics aligned, and allow future Markdown features without reintroducing route-dependent behavior.

## What I already know

- Scopy currently reduces a pasteboard item with multiple representations to one primary type, one payload, and one `plainText` value.
- Capture currently prefers RTF over HTML, while Typora commonly prefers HTML when converting pasted rich content back into Markdown.
- Text, RTF, and HTML deduplication share a normalized `plainText` hash, and an existing item is not upgraded with later richer representations.
- Markdown preview first passes through heuristic detection, then source profiling, then one of two renderers with different feature sets and preprocessors.
- CJK punctuation-adjacent emphasis normalization is applied only to the legacy renderer, causing deterministic route-dependent failures in the unified renderer.
- Preview and PNG export share much of the rendering path, but resource loading, image base URLs, errors, and WebView recovery still have gaps.
- The repository baseline is macOS 14 and Swift/API availability must follow `project.yml`.
- This proposal is architecture and planning only. Product code changes are out of scope until the design is approved.

## Assumptions (temporary)

- Backward compatibility with existing clipboard history is required; a destructive database reset is unacceptable.
- Default copy should preserve original clipboard representations when available rather than silently converting formats.
- Scopy should target a documented CommonMark/GFM-based contract plus explicit extensions, not attempt unlimited Typora parity.
- Security-sensitive capabilities such as remote images and raw HTML must remain policy-controlled and observable to the user.
- A staged migration with shadow comparison and rollback is preferable to a big-bang renderer replacement.

## Open Questions

- Whether the product should optimize primarily for exact original clipboard replay or for Markdown-centric smart conversion when the two goals conflict.

## Requirements (evolving)

- Preserve original source separately from normalized search/dedup text.
- Preserve a set of clipboard representations and their provenance, not only one winning payload.
- Make deduplication merge or upgrade compatible representations deterministically.
- Define one versioned Markdown dialect and one canonical preprocessing/rendering contract.
- Remove content-dependent semantic switching between renderers from normal operation.
- Keep preview, PNG export, and future rich-copy output on the same render artifact.
- Provide explicit policy and user feedback for blocked HTML, remote resources, unsupported syntax, and renderer failure.
- Support staged migration, telemetry without sensitive content, rollback, and old-record compatibility.

## Acceptance Criteria (evolving)

- [ ] The same Markdown source produces equivalent semantic output in preview and PNG export.
- [ ] Adding an unrelated heading or list cannot change the interpretation of an existing emphasis, footnote, image, definition list, or math block.
- [ ] HTML + RTF + plain text can survive capture, persistence, deduplication, and replay without silent representation loss.
- [ ] Plain-to-rich and rich-to-plain duplicate sequences have a documented, deterministic merge result.
- [ ] Original Markdown source bytes remain available even when normalized text is used for indexing or deduplication.
- [ ] Valid supported Markdown is not silently rejected solely by heuristic detection; users have an explicit override.
- [ ] CJK punctuation-adjacent emphasis is covered across parser, preview, export, code spans, and fenced blocks.
- [ ] Renderer/resource failures have an explicit state, retry path, raw-source fallback, and regression tests.
- [ ] Existing database records migrate lazily or compatibly without loss.

## Definition of Done (team quality bar)

- Architecture decision and data contracts are approved before implementation.
- Unit, integration, WebView DOM, image-pixel, clipboard round-trip, and differential corpus tests are defined.
- Migration, rollback, cache invalidation, privacy, observability, and performance budgets are documented.
- Implementation is split into independently releasable, reversible PRs.
- Project release metadata and documentation are updated only when behavior changes are implemented.

## Out of Scope (explicit)

- Product code changes in this design proposal.
- Full Typora extension parity such as Mermaid, YAML front matter, or every raw HTML behavior unless separately approved.
- Storing arbitrary unbounded pasteboard types without an allowlist, size budget, and privacy policy.
- Enabling unrestricted network access inside Markdown previews.

## Technical Notes

- Current audit evidence centers on `ClipboardMonitor`, `StorageService`, `MarkdownDetector`, `MarkdownSourceProfileDetector`, `MarkdownRendererFeatureFlags`, `UnifiedMarkdownRenderer`, `MarkdownHTMLRenderer`, `MarkdownPreviewWebView`, and `MarkdownExportService`.
- The current product specification promises clipboard fidelity, CommonMark/GFM-oriented rendering, CJK punctuation-adjacent emphasis compatibility, and preview/export consistency.
- The design should use raw UTI identifiers where newer typed APIs exceed the macOS deployment baseline.
- No sensitive clipboard body should be included in diagnostics; types, byte counts, hashes, route/version, and result codes are sufficient.

## Architecture Options

### Approach A: Immutable captures plus one canonical compiler (recommended)

- Preserve each copy event as an immutable capture snapshot containing an allowlisted set of original pasteboard representations.
- Keep semantic grouping/deduplication separate from the exact capture fingerprint.
- Resolve a preview source explicitly, run optional source transforms as versioned derived artifacts, and compile every Markdown document with one canonical dialect/compiler.
- Let preview, PNG export, and rendered rich-copy consume the same compiled artifact.
- Keep the legacy renderer only as a temporary migration kill switch, never as a content-dependent normal route.

Benefits:

- Eliminates first-representation-wins data loss and renderer-route semantic drift.
- Makes transformations, fallback, cache invalidation, diagnostics, and future extensions explicit and versioned.
- Supports staged migration and rollback without rewriting old history.

Costs:

- Requires a sidecar representation schema, a source resolver, and compiler/presentation contract work.
- Needs a deliberate rollout rather than one small parser patch.

### Approach B: Keep the current item schema and dual renderers, add shared preprocessors

- Add CJK, math, footnote, and image fixes around the current paths.
- Preserve current single-payload persistence and source-profile renderer selection.

Benefits:

- Lowest initial implementation cost.

Costs:

- Cannot solve representation loss or first-wins deduplication.
- Every new syntax feature must maintain parity across two engines and two resource paths.
- Content-dependent route changes remain a permanent regression source.

### Approach C: Store rendered HTML snapshots at ingest time

- Convert likely Markdown/rich content once and persist the resulting HTML for preview and replay.

Benefits:

- Stable historical appearance and fast repeat preview.

Costs:

- Freezes renderer bugs, sanitizer policy, theme, and dependency versions into stored content.
- Makes future fixes and accessibility/theme changes difficult.
- Increases storage and still does not preserve the original pasteboard representation set unless combined with Approach A.

Recommendation: adopt Approach A. Use cached compiled artifacts for performance, but treat them as evictable derivatives rather than stored truth.

## Technical Approach

### 1. Core invariants

1. **Originals are immutable.** Capture never normalizes, trims, converts, or overwrites original representation bytes.
2. **Derivations are explicit.** Search text, extracted plain text, HTML-to-Markdown, OCR/LaTeX repair, sanitized HTML, and rendered PNG are derived artifacts with generator and policy versions.
3. **Deduplication never destroys information.** Exact duplicate events may increment counters; semantically similar but representation-different events retain a distinct capture snapshot.
4. **One dialect, one normal compiler.** A content heuristic may select preview mode or a source transform, but it must not silently select a different Markdown language implementation.
5. **Compile once, present many.** Preview, PNG, and rendered rich-copy consume the same semantic render artifact.
6. **No silent fallback.** Every blocked resource, unsupported extension, compiler failure, or legacy rollback has a typed diagnostic and observable user state.
7. **All behavior is versioned.** Dialect, transforms, sanitizer, compiler bundle, theme, resources, and cache keys have independent versions.

### 2. Clipboard content model

Use three levels rather than one overloaded row:

```text
ClipboardEntry                 semantic grouping and history-row metadata
  └─ CaptureSnapshot           one exact copy-event representation set
       └─ Representation       one item-index + UTI + original byte payload
```

Conceptual contracts:

```swift
struct ClipboardEntry {
    let id: UUID
    let semanticKey: String?
    let activeSnapshotID: UUID
    let useCount: Int
}

struct CaptureSnapshot {
    let id: UUID
    let entryID: UUID
    let exactFingerprint: String
    let capturedAt: Date
    let sourceApplication: String?
}

struct ClipboardRepresentation {
    let snapshotID: UUID
    let itemIndex: Int
    let uti: String
    let role: RepresentationRole       // original or derived
    let byteDigest: String
    let byteCount: Int
    let storage: RepresentationStorage
    let generator: GeneratorIdentity?  // present only for derived data
}
```

`itemIndex` preserves multi-item pasteboard boundaries without requiring the UI to expose them immediately. Only allowlisted representation codecs store payload bytes; unknown types may retain metadata without arbitrary data retention.

Recommended initial allowlist:

- UTF-8/plain string and explicit Markdown UTIs.
- HTML, RTF, and supported rich-text variants.
- PNG/TIFF and the existing file-URL representation.
- Additional types only through a registered codec with size, privacy, and replay policy.

### 3. Deduplication semantics

Maintain two fingerprints with different jobs:

- `exactFingerprint`: ordered digest of item boundaries, UTI identifiers, and representation byte digests. It answers whether two capture snapshots are exactly the same supported content.
- `semanticKey`: digest of a separately derived, normalized search/display text. It finds possible history-row grouping candidates but never authorizes payload deletion.

Rules:

1. Same exact fingerprint: increment use count and timestamps; do not duplicate bytes.
2. Same semantic key, new non-conflicting representation set: attach a new snapshot and make it active.
3. Same semantic key and same UTI with different bytes: retain a distinct snapshot; never overwrite silently.
4. Default original replay uses the active/latest exact snapshot.
5. Derived artifacts are independently evictable and never participate as original content identity.

This preserves the current compact one-row history experience while removing first-wins data loss.

### 4. Ingest pipeline

```text
NSPasteboard
  -> PasteboardCaptureAdapter       copy supported item/type bytes quickly
  -> immutable CaptureEnvelope      no normalization or primary-type choice
  -> CaptureAnalysisActor           hashes, text candidates, provenance
  -> DedupDecision                  exact repeat / related new snapshot / new entry
  -> atomic ContentStore commit
```

- Main-actor work is limited to reading pasteboard state and copying required values.
- Hashing, rich-text extraction, quality scoring, and external-file staging run off the main thread.
- One serialized ingest actor owns dedup decisions and transactional commits.
- Each representation stores its own size and digest; storage-budget accounting includes originals while derived caches use a separate budget.

### 5. Source resolution is not rendering

Replace the Boolean `isLikelyMarkdown` gate with a decision object:

```swift
struct SourceResolution {
    let format: SourceFormat             // markdown, richHTML, plainText, file
    let representationID: UUID
    let confidence: SourceConfidence
    let evidence: [SourceEvidence]
    let userOverride: SourceFormat?
    let resourceContext: ResourceContext
}
```

Decision precedence:

1. Explicit Markdown UTI or Markdown file extension.
2. Persisted user override.
3. Strong parser/classifier evidence from original plain source.
4. Safe rich-HTML preview when rich structure exists but no trustworthy Markdown source exists.
5. Plain-text fallback.

Detection becomes advisory and explainable. It may choose `markdown` versus `plainText`, but all Markdown uses the same compiler. A user-visible “Preview as Markdown / Preview as Plain Text” override removes false-negative dead ends.

### 6. Destructive repair becomes a derived-source transform

Source profiles should no longer choose a renderer. OCR cleanup, loose LaTeX repair, and HTML-to-Markdown conversion become optional versioned transforms:

```text
OriginalSource
  -> TransformPlan (optional, provenance/policy controlled)
  -> DerivedSource + diagnostics + source map
  -> canonical Markdown compiler
```

- Authored Markdown is compiled without destructive repair.
- Explicit math syntax remains part of the documented dialect.
- OCR/PDF loose repair may run only under an explicit policy and never replaces the original.
- Users and diagnostics can identify whether the displayed result came from original or transformed source.

### 7. Versioned Scopy Markdown dialect

Define a capability manifest instead of inheriting accidental library defaults:

```text
Scopy Markdown v1
  CommonMark baseline
  GFM tables, strikethrough, task lists, autolinks
  footnotes and definition lists
  explicit math: $, $$, \(...\), \[...\], supported AMS environments
  syntax highlighting
  source citations
  documented safe-HTML subset
  CJK punctuation-adjacent emphasis extension
  current hard-line-break behavior for backward compatibility
```

Every extension owns:

- a stable ID and version;
- parser/tokenizer or AST transform;
- sanitizer schema contribution;
- CSS/assets;
- positive, negative, interaction, and migration corpus cases.

Future features such as Mermaid or broader HTML become opt-in dialect extensions rather than ad-hoc string transforms in the document builder.

### 8. Canonical compiler and render artifact

Use the existing unified/remark/rehype stack as the target canonical compiler because it already exists in the repository and exposes syntax-tree extension points. Do not replace it with another engine until a corpus proves a material advantage.

The compiler boundary must not depend on WebView presentation:

```swift
struct MarkdownCompileRequest {
    let exactSourceDigest: String
    let source: String
    let dialectVersion: String
    let transformManifest: TransformManifest
    let sanitizerVersion: String
    let resourceContext: ResourceContext
}

struct CompiledDocument {
    let semanticHTML: String
    let semanticDigest: String
    let diagnostics: [RenderDiagnostic]
    let resourceManifest: ResourceManifest
    let compilerManifest: CompilerManifest
}
```

The execution runtime remains behind a `MarkdownCompiler` protocol. A focused spike should compare isolated JavaScriptCore execution with the current WKWebView-hosted bundle. If JavaScriptCore cannot run the exact corpus reliably, use an isolated compiler WebView initially; consumers still receive the same `CompiledDocument` contract.

CJK emphasis should be implemented as a tokenizer/parser extension or a syntax-aware lexical transform owned by the compiler. It must never be a renderer-specific line regex.

### 9. Presentation and output consumers

```text
CompiledDocument
  -> PresentationDocumentBuilder(theme, scale, viewport, resource manifest)
       ├─ HoverPreviewPresenter
       ├─ PNGExportConsumer
       └─ RichClipboardConsumer
```

- The WebView becomes a local presentation host, not the owner of Markdown parsing policy.
- Preview and PNG use the same semantic HTML, theme assets, KaTeX assets, sanitizer result, and resolved resource bytes.
- WebView process termination, navigation failure, and renderer failure reset the session and expose Retry plus raw-source fallback.
- Session/revision tokens prevent a late render from updating a reused hover preview.
- Rich-copy can generate HTML + RTF + plain display text from the same compiled artifact without modifying the original capture snapshot.

Explicit copy intents:

- `Copy Original`: replay the active original representation set.
- `Copy Markdown Source`: write Markdown UTI plus source/plain representation.
- `Copy Rendered`: write generated HTML + RTF + plain display text.
- `Copy Plain`: write only the selected plain representation.

### 10. Resource resolver and security policy

Markdown parsers discover references; an app-layer resolver decides whether and how they load:

- Markdown files carry their real base-directory context.
- Clipboard-only Markdown with relative paths has no inferred base directory and receives an unresolved-resource diagnostic.
- Local resources are validated against allowed roots, size/MIME limits, and current file access.
- Remote images remain blocked by default. If later enabled, the app fetches, validates, caches, and serves them locally; the WebView never makes arbitrary network requests.
- A custom local resource scheme or materialized isolated directory gives preview and PNG identical bytes.
- Blocked and missing resources render explicit placeholders and reasons.

Safe HTML must be implemented in the AST/sanitizer layer, not by nested regular-expression extraction. CSP remains local-only.

### 11. Two-level caches

- `CompileKey`: exact source digest + dialect + transforms + compiler bundle + sanitizer + resource-context identity.
- `PresentationKey`: compiled semantic digest + theme + layout scale + viewport/output mode + resolved-resource digest.

Success, warning, and failure states are part of cached values. A size-only metric change must never suppress a render-state transition. Derived caches are disposable and can always be rebuilt from originals.

### 12. Build manifest and observability

Ship a renderer manifest containing:

- dialect, compiler, extension, sanitizer, and cache-schema versions;
- JS bundle and CSS asset SHA-256 values;
- exact KaTeX JS/CSS version pairing;
- required resource list.

Build and startup validation fail explicitly on an incomplete manifest.

Privacy-preserving render traces may record only:

- entry/revision digest, source format, decision evidence codes;
- dialect/compiler/policy versions;
- stage durations, result state, fallback/error code;
- blocked/missing resource counts.

Never log clipboard body text, HTML, paths, or representation bytes by default.

## Regression Prevention Strategy

### Contract and corpus layers

1. **Pasteboard contract tests** using named pasteboards: multi-item and HTML + RTF + string + Markdown UTI round trips.
2. **Persistence/migration tests**: v1 records, dual-write records, lazy materialization, rollback reads, storage cleanup, and active-snapshot selection.
3. **Compiler corpus**: semantic AST/DOM assertions for every dialect feature, not only raw HTML substring snapshots.
4. **Metamorphic tests**: adding an unrelated heading/list cannot alter an existing emphasis, footnote, math block, or image subtree.
5. **WebView DOM tests**: footnote target integrity, resource natural sizes, error/retry state, process termination, and same-content re-hover.
6. **PNG visual tests**: preview/export use the same fixture, scale, theme, resources, and perceptual comparison threshold.
7. **Target-application release matrix**: Typora, Notes/Pages, a browser contenteditable target, and a code editor.
8. **Fuzz/property tests** for delimiter runs, Unicode punctuation/symbols, nested emphasis, code spans, fences, links, and math boundaries.

### Rollout gates

- Freeze current failing and successful examples before behavior changes.
- Run the canonical compiler in shadow mode and compare semantic signatures, diagnostics, latency, and failure rate.
- Classify differences as expected dialect corrections or regressions; do not use raw HTML equality as the only oracle.
- Flip the canonical compiler through a versioned flag only after the approved corpus and preview/export visual gates pass.
- Keep a hard legacy kill switch for at least one stable release after cutover, but remove automatic content-based renderer selection.
- Every behavior change bumps the relevant manifest/cache namespace and has a documented rollback path.
- Establish performance and storage budgets from a measured baseline before implementation; do not invent thresholds during design.

## Migration Plan (small, reversible PRs)

1. **PR0 — Contracts and gates, no behavior change**
   - Add architecture contracts, renderer manifest schema, failure codes, expanded corpus, differential runner, and baseline metrics.
2. **PR1 — Representation sidecar and dual write**
   - Add snapshot/representation tables, capture all allowlisted representations, preserve existing columns and replay behavior.
3. **PR2 — Lossless dedup and original replay**
   - Introduce exact fingerprints, semantic grouping, active snapshots, and v2-first/v1-fallback reads. Keep old-app rollback viable through dual write.
4. **PR3 — Source resolver and user override**
   - Replace Boolean gating with evidence-based resolution; add explicit Markdown/plain override without changing the compiler default yet.
5. **PR4 — Canonical compiler parity**
   - Fix CJK emphasis, footnotes, definition lists, AMS environments, safe HTML, images, and matched KaTeX assets behind shadow mode.
6. **PR5 — Compile-once presentation**
   - Make hover and PNG consume one compiled artifact; add resource resolver, typed failures, Retry, raw fallback, and WebView recovery.
7. **PR6 — Controlled cutover**
   - Make the canonical compiler the only normal Markdown path, retain an explicit kill switch, and remove content-dependent renderer selection.
8. **PR7 — Explicit copy intents and cleanup**
   - Add original/source/rendered/plain copy actions, measure adoption, then plan legacy schema/renderer retirement separately.

Existing records are never destructively rewritten. They are exposed through a synthetic `legacy-import-v1` snapshot until naturally materialized; new versions dual-write enough v1 state for rollback during the migration window.

## Decision (ADR-lite, proposed)

**Context**: The current architecture mixes capture choice, semantic identity, Markdown detection, repair policy, renderer choice, and presentation. This causes irreversible representation loss and content-dependent rendering behavior.

**Decision**: Adopt immutable capture snapshots plus one versioned canonical Markdown compiler. Preserve originals, treat every conversion/render as a derived artifact, and use sidecar schema plus shadow rollout for migration.

**Consequences**:

- More up-front contract and migration work, but substantially lower long-term regression cost.
- Clipboard fidelity and Markdown rendering become independently testable.
- New syntax, resource policies, and output formats can be added through explicit extension/consumer boundaries.
- The existing legacy renderer remains useful for rollback but is no longer a permanent alternate language definition.

## Research References

- [`research/architecture-patterns.md`](research/architecture-patterns.md) — bounded comparison of AppKit representation sets, Typora source/rich semantics, AST compilation, versioned artifacts, and three feasible architecture approaches.
