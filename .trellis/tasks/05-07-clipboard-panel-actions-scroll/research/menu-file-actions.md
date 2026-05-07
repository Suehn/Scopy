# Research: menu-file-actions

- Query: For task 05-07-clipboard-panel-actions-scroll requirements 3 and 4, identify the code paths for file-item context menu actions that should support native AirDrop direct send and open containing folder, with concrete implementation seams, AppKit API constraints, and test updates.
- Scope: mixed
- Date: 2026-05-07

## Findings

### Task and spec context

- Requirement source is the task PRD: file-item menu must expose native AirDrop and open-containing-folder actions, only for valid file items. See \`.trellis/tasks/05-07-clipboard-panel-actions-scroll/prd.md\`.
- Frontend spec points UI/menu/state changes toward the app target UI layer and says backend spec should also be considered when service contracts or file semantics are touched. See \`.trellis/spec/frontend/index.md\` and \`.trellis/spec/backend/index.md\`.

### Existing menu construction seam

- The row context menu is assembled directly inside \`HistoryItemView\` rather than through a separate menu builder. Current actions are \`Copy\`, image-only \`Paste-optimized for Codex\`, optional \`Export PNG\`, \`Pin/Unpin\`, file-only note actions, and \`Delete\`. The file-only block currently starts at [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:649).
- Concrete current menu lines:
  - \`Copy\`: [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:628)
  - \`Paste-optimized for Codex\`: [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:632)
  - \`Export PNG\`: [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:638)
  - \`Pin/Unpin\`: [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:645)
  - file-note actions: [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:649)
  - \`Delete\`: [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:663)
- \`HistoryItemView\` already receives action closures from its parent (\`onSelect\`, \`onSelectOptimizedForCodex\`, \`onTogglePin\`, \`onDelete\`, \`onUpdateNote\`) and therefore new file-system actions can follow the same dependency-injection pattern instead of embedding all side effects inside the view. See [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:17).

### Existing file-item data seam

- \`HistoryItemView\` does not fetch file URLs itself. It derives file preview metadata via \`HistoryItemRowDescriptor\`, which exposes \`filePreviewInfo\`, \`filePreviewPath\`, and \`filePreviewKind\`. See [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:318) and [Scopy/Presentation/HistoryItemRowDescriptor.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Presentation/HistoryItemRowDescriptor.swift:26).
- \`HistoryItemRowDescriptor\` only gives a single display/preview path (\`filePreviewPath\`) and not the authoritative full file-URL list for replay. For direct AirDrop send and reveal-in-Finder behavior, the safer source of truth is the stored file payload path list already used by clipboard replay, not preview-only metadata. See [Scopy/Presentation/HistoryItemRowDescriptor.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Presentation/HistoryItemRowDescriptor.swift:63).

### Existing file replay / URL restoration path

- \`ClipboardService.copyToClipboard(itemID:)\` delegates file items into \`copyFilePayload\`, which is the current authoritative path for restoring stored file URLs. See [Scopy/Application/ClipboardService.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Application/ClipboardService.swift:303) and [Scopy/Application/ClipboardService.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Application/ClipboardService.swift:393).
- \`copyFilePayload\` first loads serialized payload data, deserializes it via \`ClipboardMonitor.deserializeFileURLs\`, and only falls back to newline-separated \`plainText\` paths when payload data is missing. This is the strongest reusable pattern for requirements 3 and 4 because it already encodes the app's file-item truth model. See [Scopy/Application/ClipboardService.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Application/ClipboardService.swift:399), [Scopy/Application/ClipboardService.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Application/ClipboardService.swift:416), and [Scopy/Services/ClipboardMonitor.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift:627).
- \`ClipboardMonitor.copyToClipboard(fileURLs:)\` writes both NSURL objects and legacy \`NSFilenamesPboardType\`, showing that the codebase already carries Finder-compatibility logic for file URLs. See [Scopy/Services/ClipboardMonitor.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift:596).
- Existing tests already verify this replay contract for Finder-style file items:
  - file URLs preserved for Finder image file items: [ScopyTests/ClipboardServiceCopyToClipboardTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardServiceCopyToClipboardTests.swift:382)
  - single text file still publishes file URLs: [ScopyTests/ClipboardServiceCopyToClipboardTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardServiceCopyToClipboardTests.swift:401)
  - temporary image files may intentionally downgrade to PNG instead of file URLs: [ScopyTests/ClipboardServiceCopyToClipboardTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardServiceCopyToClipboardTests.swift:362)

### Recommended implementation seam for new actions

- New menu items should likely be added in the existing \`if item.type == .file\` block in \`HistoryItemView\`, but the actual side effects should be delegated to new closures or an app/service helper, matching the current \`onDelete\` / \`onTogglePin\` pattern. Primary menu insertion point: [Scopy/Views/History/HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift:649).
- The most coherent reusable backend-facing helper would live next to \`copyFilePayload\` in \`ClipboardService\`, because that layer already knows how to reconstruct valid stored file URLs and can reuse the same fallback ordering. This avoids duplicating file deserialization logic in the SwiftUI view layer.
- The actual system actions are naturally AppKit-main-thread actions:
  - reveal/open containing folder can use \`NSWorkspace.shared.activateFileViewerSelecting([URL])\`
  - AirDrop can be dispatched through \`NSSharingService(named: .sendViaAirDrop)\`
- Therefore a likely split is:
  - \`ClipboardService\` or a small helper returns resolved \`[URL]\` for a file item
  - UI/AppKit-facing code on the main actor invokes \`NSWorkspace\` / \`NSSharingService\`

### Verified AppKit API concerns

- \`NSWorkspace.shared.activateFileViewerSelecting([URL])\` compiles in the current environment and is a valid direct way to reveal file selections in Finder. Verified by live \`xcrun swift\` compile/run on 2026-05-07.
- \`NSSharingService(named: .sendViaAirDrop)\` also compiled and returned non-nil in the current environment, which strongly supports using it as the native AirDrop path for file URLs. Verified by live \`xcrun swift\` compile/run on 2026-05-07.
- Even with compile confirmation, implementation should still keep the AppKit interaction in a guarded UI path:
  - only show/enable file actions when resolved file URLs are non-empty
  - skip temporary-image-file cases that intentionally replay as PNG rather than raw file URLs, unless product explicitly wants AirDrop/reveal for those transient file-backed image items too

### Existing test seams to extend

- General context-menu smoke tests exist but are broad and partly flaky in macOS XCUITest:
  - [ScopyUITests/ContextMenuUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/ContextMenuUITests.swift:33)
  - they currently verify \`Copy\`, \`Pin/Unpin\`, and \`Delete\`, while explicitly skipping when menu items are not reliably exposed.
- The more targeted harness-based row UI tests are a better extension point because they already open the row context menu and assert action identifiers deterministically:
  - harness launch and scenario control: [ScopyUITests/HistoryItemViewUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/HistoryItemViewUITests.swift:96)
  - existing context-menu assertion helper: [ScopyUITests/HistoryItemViewUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/HistoryItemViewUITests.swift:302)
  - existing \`Export PNG\` assertion pattern: [ScopyUITests/HistoryItemViewUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/HistoryItemViewUITests.swift:308)
- Suggested test additions:
  - add harness scenarios for real file items and non-file items
  - assert file scenario shows \`HistoryItem.ContextMenu.SendViaAirDrop\` and \`HistoryItem.ContextMenu.OpenContainingFolder\`
  - assert plain-text/image scenarios do not show those file-only items
  - add unit tests around any new helper that resolves \`[URL]\` from stored file items, reusing fixtures similar to \`ClipboardServiceCopyToClipboardTests\`
  - if system side effects are abstracted behind closures/helpers, unit-test that the right URLs are passed rather than trying to fully automate Finder/AirDrop UI

### Related code patterns

- Context-menu feature growth is already happening in \`HistoryItemView\`; prior review notes mention export had been promoted into the row context menu and uses row-local state/feedback. See [doc/reviews/codebase_review.md](/Users/ziyi/Documents/code/Scopy/doc/reviews/codebase_review.md:173).
- This supports adding more row actions there, but also confirms \`HistoryItemView\` is already heavy, so reusing closures/helpers is preferable to introducing more raw AppKit logic directly in the view body.

## Caveats / Not Found

- I did not find an existing helper dedicated to “resolve authoritative stored file URLs for arbitrary row actions”; current code only exposes that logic inside \`ClipboardService.copyFilePayload\`, so implementation will likely need an extracted helper or a new method to avoid duplication.
- I did not find existing AirDrop-specific UI or service abstractions in the repo; this path will be net-new even though the underlying AppKit signature is verified.
- I did not verify with Cupertino docs in this turn; the AppKit API names above are compile-verified locally, which is strong evidence but still not a substitute for official doc lookup if the implementation introduces availability or behavior questions.
