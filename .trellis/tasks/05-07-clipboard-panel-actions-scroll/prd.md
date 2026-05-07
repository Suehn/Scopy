# fix clipboard panel actions and scroll behavior

## Goal

Fix the pinned-item pagination bug and add requested clipboard panel actions/interaction behavior without regressions. The user provided six concrete requirements covering scroll loading, context menu file actions, Codex paste ergonomics, stale search reset, and focus behavior.

## What I already know

* Repository: Scopy native macOS Swift app in /Users/ziyi/Documents/code/Scopy.
* Current branch is main and worktree was clean at task start.
* User wants the changes implemented, not just reviewed.
* Feature set touches UI/menu interactions, search/list pagination, clipboard paste behavior, app focus/window lifecycle, and likely AppKit file actions.
* Project rules require preserving backward compatibility, using project.yml baselines, verifying Apple/Swift APIs instead of guessing, and running make build + make test-unit after code changes.

## Assumptions (temporary)

* "scoll more" means the history/pinned list incremental pagination/load-more behavior.
* "pin太多的时候，会导致没法加载scroll more" means pinned items should not prevent additional non-pinned/remaining results from loading.
* "每次scroll more从多加载100变成多加载500" means the incremental page/load-more amount should be 500 items.
* User clarified that pinned content must not consume the initialPageSize quota; pinned and recent/unpinned pagination need separate quota accounting.
* "菜单" refers to the item context/menu actions shown in the provided screenshots, likely the history item menu.
* "打开所在文件夹" applies when a clipboard item represents a file path/file URL.
* "隔空投送" should use macOS native AirDrop share behavior for file URLs.
* "粘贴到codex变成点击后复制到剪切板并直接粘贴" means the Codex-specific action should copy the item to the system clipboard and immediately paste into the frontmost target, not merely require a second manual paste.
* "面板关闭超过3分钟" refers to elapsed time since the floating panel was hidden/closed; on next hotkey show, clear the search/input field if elapsed time is greater than 180 seconds.
* "当焦点在输入框的时候，候选列表自动失焦" means the candidate/list selection/focus should be cleared or visually de-emphasized when the search input has keyboard focus.

## Open Questions

* None blocking at start; implementation can infer behavior from existing code and tests. If screenshots reveal a different target menu/action name than code supports, update PRD after inspection.

## Requirements (evolving)

1. Pinned-heavy lists must still support loading more results.
2. Pinned items must not occupy the initial recent page quota; initial recent/unpinned loading should still provide its full page size independently of the pinned section.
3. Scroll/load-more increment must change from 100 to 500.
4. Item menu must include a native AirDrop action for file items and directly send selected files.
5. Item menu must include an "open containing folder" action for file items.
6. Codex paste action must copy the item to the clipboard and immediately paste into the target app.
7. If the panel has been closed for more than 3 minutes, the next hotkey show must clear the input/search field.
8. When the input field has focus, the candidate list should automatically lose focus/selection state.
9. Existing menu, paste, search, pin, and list behavior must not regress.

## Acceptance Criteria (evolving)

* [ ] There is a code-level fix for load-more with many pinned items.
* [ ] Initial load uses separate pinned/recent quota accounting so pinned items do not reduce the initial recent page.
* [ ] The per-scroll additional load count is 500, and tests/docs/constants reflect this.
* [ ] File item menu exposes AirDrop, guarded so non-file items do not get invalid file actions.
* [ ] File item menu exposes reveal/open-containing-folder, guarded for valid file paths.
* [ ] Codex paste action copies the item then synthesizes/immediately performs paste through the existing paste path.
* [ ] Reopening the panel via hotkey after more than 180 seconds closed clears the input field.
* [ ] Reopening within 180 seconds keeps current input behavior.
* [ ] Focusing the input clears candidate/list focus without breaking keyboard navigation after list focus returns.
* [ ] make build passes.
* [ ] make test-unit passes.
* [ ] Focused tests or equivalent evidence cover the changed pagination/stale-reset/action behavior.

## Definition of Done (team quality bar)

* Tests added/updated where practical for pagination and state behavior.
* make build + make test-unit green.
* If UI-only behavior is not fully covered by automated tests, manual/evidence-based code audit identifies the event path.
* Docs/notes updated only if user-facing release docs are required; no release metadata changes unless doing a release.
* Rollback considered: all changes should be localized to UI/state/action handlers.

## Out of Scope (explicit)

* No release/tag/Homebrew work.
* No redesign of Settings or clipboard storage schema unless required by the fix.
* No change to project.yml baselines.
* No broad UI restyle beyond requested menu/action/focus behavior.

## Technical Notes

* Relevant specs: .trellis/spec/frontend/index.md, .trellis/spec/backend/index.md, .trellis/spec/guides/index.md.
* Need code inspection for existing HistoryViewModel paging, pinned item handling, context menu action model, paste-to-Codex handler, floating panel show/hide lifecycle, and focused input/list state.
