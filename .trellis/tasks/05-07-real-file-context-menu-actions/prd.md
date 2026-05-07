# fix real file context menu actions

## Goal

Make AirDrop and Open Containing Folder actions appear in the actual Scopy context menu for history items that carry a file-backed payload, including image/file clipboard items where the item type is not strictly `.file` but Scopy can resolve a usable local URL.

## What I already know

* User screenshot shows the real menu still only has Copy, Pin, Delete.
* Existing implementation only shows AirDrop/Open Folder when `item.type == .file` and `FilePreviewSupport.fileURLs(from: item.plainText, requireExists: true)` returns URLs.
* UI harness previously proved a synthetic `.file` item, but did not prove real image/file-backed history rows.

## Requirements

* Context menu actions must appear for actual file-backed history items, not only `.file` rows.
* AirDrop should share resolved local file URLs.
* Open Containing Folder should reveal resolved local file URLs in Finder.
* Keep non-file/plain text rows free of irrelevant file actions.
* Preserve existing Copy, Pin, Delete, Export PNG, note behavior.

## Acceptance Criteria

* [ ] Context menu visibility uses the same service/view-model file URL resolution source as the actions.
* [ ] Image/file-backed rows with `storageRef` or file path show AirDrop and Open Containing Folder.
* [ ] Plain text rows without file URLs do not show those actions.
* [ ] Focused UI tests cover image/file-backed context menu visibility and action triggers.
* [ ] make build and make test-unit pass.

## Definition of Done

* Tests added/updated.
* Build/unit gates pass.
* Focused UI context-menu test proves the user-visible menu entries exist.
