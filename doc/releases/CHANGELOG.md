# Scopy 变更日志

所有重要变更记录在此文件中。

格式基于 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.0.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

## [Unreleased]

### Notes

- No unreleased entries.

## [v0.7.2] - 2026-04-24

### Fix/Concurrency

- `HistoryViewModel.load()` now guards each awaited writeback with the current search version, cancellation state, and unfiltered-list state, so stale recent-list loads no longer overwrite newer search results or loading state.

### Fix/Thumbnails

- Thumbnail settings changes now invalidate the in-memory thumbnail index before and after disk cache reset, and indexed thumbnail paths are rechecked on disk before being returned.
- `StorageService.clearThumbnailCache()` now waits for the thumbnail directory to be removed and recreated before returning, making settings-driven cache resets deterministic.

### Markdown/Preview

- Added CJK asterisk-emphasis normalization so cases like `**重要：**请注意` and `这是**《重点》**内容` render as strong emphasis in preview/export while inline code and fenced code stay untouched.
- Added focused renderer coverage for CJK emphasis normalization using the bundled local `markdown-it` runtime.

### Build/Versioning

- `scripts/version.sh` now falls back to the nearest reachable release tag instead of the highest version-sorted merged tag, so post-release commits after `v0.7.1` no longer build as older `0.64` binaries.
- `scripts/build-release.sh` now uses `scripts/version.sh --tag` as its single tag resolver and refuses packaging when the resolved marketing version disagrees with the HEAD release tag.

### Verification

- make build：BUILD SUCCEEDED（2026-04-24）
- make test-unit：Executed 367 tests, 1 skipped, 0 failures（2026-04-24）
- make test-strict：Executed 367 tests, 1 skipped, 0 failures（2026-04-24）
- xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/ConcurrencyTests/testLoadDoesNotOverwriteNewerSearchResults -only-testing:ScopyTests/StorageServiceTests/testClearThumbnailCacheWaitsForDirectoryReset -only-testing:ScopyTests/StorageServiceTests/testThumbnailCacheIndexDropsMissingIndexedPath：passed（2026-04-24）
- xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/KaTeXRenderToStringTests/testCJKEmphasisNormalizerFixesTrailingPunctuationAdjacentToCJKText -only-testing:ScopyTests/KaTeXRenderToStringTests/testCJKEmphasisNormalizerFixesBracketWrappedStrongAdjacentToCJKText -only-testing:ScopyTests/KaTeXRenderToStringTests/testCJKEmphasisNormalizerSkipsInlineCodeAndFencedCode：passed（2026-04-24）
- scripts/version.sh temp-repo resolver smoke：malformed `v0foo` and legacy `v0.18.1` ignored, valid `v0.7.1` resolved（2026-04-24）
- make docs-validate：passed（2026-04-24）
- make release-validate：passed（2026-04-24）

## [v0.7.1] - 2026-03-26

### Markdown/Footnotes

- `MathNormalizer` no longer mistakes markdown footnote syntax like `[^1]` and `[^1]: ...` for loose math, so release builds and exports preserve real footnote parsing.
- Footnote references now render as blue superscript digits instead of plain bracket text, and the footnote renderer emits numeric captions directly to keep preview and export output aligned.

### Markdown/Export

- Markdown export no longer depends on external highlight theme timing alone; inline highlight token colors now keep code blocks colored in release builds and PNG output.
- Export readiness checks now tolerate HTML-only harnesses while still waiting for markdown render completion when available, reducing false-zero height measurements in export preparation.

### Verification

- make build：BUILD SUCCEEDED（2026-03-26）
- make test-unit：Executed 361 tests, 1 skipped, 0 failures（2026-03-26）
- make test-strict：Executed 361 tests, 1 skipped, 0 failures（2026-03-26）
- xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/MarkdownMathRenderingTests/testMathNormalizerPreservesMarkdownFootnoteSyntax -only-testing:ScopyTests/KaTeXRenderToStringTests/testMarkdownRendererHighlightsFootnoteRefsAndExposesRenderReadyState -only-testing:ScopyUITests/ExportMarkdownPNGUITests/testAutoExportMarkdownFixtureRendersStandardCase：passed（2026-03-26）
- make docs-validate：passed（2026-03-26）
- make release-validate：passed（2026-03-26）

## [v0.7.0] - 2026-03-26

### Markdown/Preview

- Markdown preview and PNG export now share a single feature-set driven renderer with `CommonMark + GFM + footnotes + math`, local `highlight.js`, and a safe HTML subset for `details/summary`, `u`, `kbd`, `mark`, `sub`, and `sup`.
- GFM task lists are rendered by a local runtime instead of a remote/runtime dependency; autolink literals, tables, strikethrough, definition lists, footnotes, and math now ship as first-class supported syntax.
- Preview navigation policy is centralized so `http/https`, `target=_blank`, and `linkActivated` remain blocked while in-document safe navigation stays allowed.

### Export/Long Content

- Markdown export now aligns layout width with preview, uses a light high-contrast surface for readability, and preserves code-block readability with preview horizontal scroll plus export-only wrap for overwide code.
- Ultra-tall export paths gained stronger height reconciliation, tile interval stitching, and top/middle/bottom regression coverage to reduce clipping, blank seams, and missing leading content in long PNG exports.
- Forced PDF export now preflights real PDF page-box raster size and can shrink export scale inside the PDF branch itself, avoiding the historical viewport-vs-page-box mismatch captured by `SCOPY_EXPORT_PDF_GLOBAL_SCALE_MISMATCH`.

### Verification

- make build：BUILD SUCCEEDED（2026-03-26）
- make test-unit：Executed 359 tests, 1 skipped, 0 failures（2026-03-26）
- make test-strict：Executed 359 tests, 1 skipped, 0 failures（2026-03-26）
- xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/ExportMarkdownPNGUITests：Executed 20 tests, 0 failures（2026-03-26）
- xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/HistoryItemViewUITests：Executed 4 tests, 0 failures（2026-03-26）
- make docs-validate：passed（2026-03-26）
- make release-validate：passed（2026-03-26）

## [v0.64] - 2026-03-25

### Perf/Search

- full-index warm-load 的磁盘缓存路径补上 sidecar metadata preflight、failure reason 归因和更轻的 payload decode；warm-load 从上一轮基线 3049.715ms 收敛到 612.389ms，reason 固化为 disk_cache_hit。
- SearchEngineImpl 内部新增 full-index builder、disk-cache codec、warm-load metrics 边界，保留现有 Exact <= 2 recent-only、Regex recent-only、Fuzzy/Fuzzy+ staged-refine 和 SearchCoverage 契约不变。
- staged-refine 的后台 full-index build 改成按查询会话去重且可取消，避免查询切换或清空后继续做无意义的 warm-load 成本。

### Refactor/Preview

- HistoryItemView 的 hover、popover、dismiss 生命周期抽到 HistoryItemPreviewCoordinator，统一 image、text、file preview 的 observer、token 与 task 清理。
- 修复 UITest tap-open preview 场景下滚动不关闭的真实回归，保证 scroll dismiss、hover exit、system dismiss 三条路径的最终状态一致。
- HistoryItemRowController 移除多余 preview 状态持有，row 层继续只保留布局与轻量交互入口。

### Infra/Observability

- 新增 AsyncPermitPool，收口文件大小计算与缩略图生成的 permit/waiter 队列实现。
- 新增 BestEffortFileOps，为 ClipboardService、ClipboardMonitor、StorageService 里的 cleanup、restore、pending payload 辅助路径补可检索日志上下文。
- Tools/ScopyBench 和 scripts/perf-search-warm-load.sh 现在会稳定输出 phase、counter、reason 证据，便于直接定位 warm-load 是 cache hit 还是 fallback rebuild。

### Verification

- make test-unit：Executed 349 tests, 1 skipped, 0 failures（2026-03-25）
- make test-strict：Executed 349 tests, 1 skipped, 0 failures（2026-03-25）
- xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/FullIndexDiskCacheHardeningTests：Executed 7 tests, 0 failures（2026-03-25）
- xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/HistoryItemViewUITests：Executed 4 tests, 0 failures（2026-03-25）
- xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/HistoryListUITests/testHoverPreviewDismissesOnScroll：passed（2026-03-25）
- make perf-search-warm-load：warm-load=612.389ms、peak RSS=219.05MB、reason=disk_cache_hit（2026-03-25）
- make build：BUILD SUCCEEDED（2026-03-25）
- make docs-validate：passed（2026-03-25）
- make release-validate：passed（2026-03-25）

## [v0.60.3] - 2026-03-13

### Fix/Clipboard

- 为图片历史项增加显式的 “Paste-optimized for Codex” 动作；普通历史回放继续保持标准 PNG 语义，仅显式优化路径才会给窄读取链路补兼容表示。
- 普通图片历史回放和 Codex 优化回放的边界拆开，避免为了单一目标应用破坏日常回放语义。

### Fix/Export

- Markdown/LaTeX 导出 PNG 的默认高度预算提升到原始值的 10 倍；导出宽度与布局逻辑保持不变，减少超长内容触发 `exportLimitExceeded` 的概率。
- 超长导出在必要时改走 file-backed tiled snapshot，并对极长内容跳过脆弱的 PDF 路径。
- 修复 tiled snapshot 在最后一片被 WebKit clamp 后仍从视口顶部取图，导致底部轻微截断的问题；现在会按实际 scroll 偏移截取最后一片。

### Fix/Preview

- 超长图片 preview 不再因为超大固定高度布局而白屏。
- 超长图片 preview 的降采样策略放宽：不再围绕超过原图宽度的目标做预算，并提高长边/总像素阈值，减少超长图预览发糊。

### Verification

- `make build`：BUILD SUCCEEDED（2026-03-13）
- `make test-unit`：Executed 300 tests, 1 skipped, 0 failures（2026-03-13）
- `make test-strict`：Executed 300 tests, 1 skipped, 0 failures（2026-03-13）
- `xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyUITests/ExportMarkdownPNGUITests/testAutoExportTallContentKeepsBottomContentVisible`：passed（2026-03-13）
- `make docs-validate`：passed（2026-03-13）
- `make release-validate`：passed（2026-03-13）

## [v0.60.2] - 2026-03-07

### Fix/Clipboard

- 历史图片回放不再为了兼容 Codex 直接重写 palette PNG：标准 PNG 保留原始 `public.png` bytes；高风险 palette/indexed PNG 保留原始 `public.png`，并额外补一份 rasterized `public.tiff` fallback 给窄读取链路使用。
- 修复“图片先进历史后再回放给 Codex 失败”的边界，同时保留普通应用对原始 PNG 表示的可见性，避免“刚复制立即粘贴”和“从历史回放粘贴”在 PNG bytes 上被无差别改写。
- 文件回放语义继续收紧在正确边界：临时/误分类图片文件 URL 回放为图片；普通 Finder 图片文件和普通文本文件仍按 file URL 回放，不被错误降级成图片复制。

### Tooling/Test

- `project.yml` 排除 `ScopyTests/Fixtures/**`，避免 `xcodegen` / `make build` 把回归 fixture 和说明文件重新加入测试资源阶段，保证 release 验证后工作树保持干净。
- 新增安全真实截图 fixture `ScopyTests/Fixtures/history-replay-real-screenshot-paletted.png`，锁定 Codex/macOS 剪贴板回放回归；同时补充 `ClipboardMonitorTests`、`ClipboardServiceCopyToClipboardTests`、`MarkdownExportServiceTests` 覆盖历史图片回放、临时图片文件 URL、旧类型清理等边界。

### Verification

- `make build`：BUILD SUCCEEDED（2026-03-07）
- `make test-unit`：Executed 290 tests, 1 skipped, 0 failures（2026-03-07）
- `make test-strict`：Executed 290 tests, 1 skipped, 0 failures（2026-03-07）
- `make docs-validate`：passed（2026-03-07）
- `make release-validate`：passed（2026-03-07）


## [v0.60.1] - 2026-02-28

### Perf/Backend

- Cleanup 组合路径优化：count-plan 释放空间估算改为 DB 聚合（`sumExternalBytes(ids:)`），移除 10k 清理场景下逐文件 `stat` 扫描。
- Cleanup 组合路径去重修复：`planCleanupExternalStorage(..., excludingIDs:)` 排除已选 count-plan，减少重复规划与二次清理。
- Makefile release perf 门禁修复：`test-snapshot-perf-release` 对 p95 解析做数值校验，避免解析失败假绿。

### Perf/Frontend

- 新增真实场景 UI profile 基准链路：`make perf-frontend-profile`（snapshot DB、accessibility/mixed/text-bias、baseline/current 对照）。
- 前端 profile 分层：`make perf-frontend-profile`（smoke，默认）/ `make perf-frontend-profile-standard`（提交前）/ `make perf-frontend-profile-full`（发布前）。
- 新增前后端统一同表：`make perf-unified-table`（合并 backend perf-audit 与 frontend profile）。
- UI profile 滚动驱动稳定性修复：改为窗口坐标拖拽，规避 AX 失效导致的偶发用例失败。
- UI profile 在权限缺失时给出明确提示（Automation/Accessibility），减少排障时间。

### Tooling/Project

- `project.yml` 相关脚本阶段设置 `basedOnDependencyAnalysis: false`，确保资源 staging 与权限修复不被增量构建漏执行。

### Verification

- `make build`：BUILD SUCCEEDED（2026-02-28）
- `make test-unit`：Executed 276 tests, 1 skipped, 0 failures（2026-02-28）
- `make test-strict`：Executed 276 tests, 1 skipped, 0 failures（2026-02-28）
- `make test-perf-heavy`：Executed 25 tests, 0 failures；`External Cleanup Performance (10k items): 1170.10ms`（2026-02-28）
- `make test-snapshot-perf-release`：cmd p95=0.115ms（target 50）、cm p95=5.274ms（target 20）（2026-02-28）
- 前端 profile（smoke）产物：`logs/perf-frontend-profile-2026-02-28_19-38-53`（2026-02-28）

## [v0.60] - 2026-01-30

### Refactor/Settings

- 设置保存改为“字段级 patch merge 到 latest”后再写回，避免并发更新时被旧快照覆盖（hotkey 字段保持“录制后立即生效 + 独立持久化”，不会走 Save/Cancel 事务）。
- 修复设置页 `恢复默认` 与 hotkey 独立持久化语义不一致导致的 UI 误导（Reset 会保留当前 hotkey）。

### Fix/Storage

- 删除路径改为 DB-first：DB 删除成功后再 best-effort 删除外部文件；并将批量文件删除改为有界并发，避免 I/O 风暴与主线程卡顿。
- 强化 `storageRef` 校验：拒绝越界/目录/软链接；并让单条删除的 `storageRef` 读取与行删除在同一事务内完成，减少极端竞态孤儿文件窗口。
- 新增确定性回归：DB busy 时不应删除外部文件。

### Fix/HotKey

- `currentHotKeyID` lock-isolated，并在进入共享状态锁前 snapshot，降低潜在 data race/锁顺序风险。

### Fix/Concurrency

- 移除 `nonisolated(unsafe)` timer 存储热点，改为显式锁盒子托管，提升 Strict Concurrency/TSan 稳定性。

### Tooling/CI

- 新增 CI（build + unit + strict），并对齐 `project.yml` 的 Xcode 基线为 16.0。

### Test

- `make build`：**BUILD SUCCEEDED**（2026-01-30）
- `make test-unit`：Executed 276 tests, 1 skipped, 0 failures（2026-01-30）
- `make test-strict`：Executed 276 tests, 1 skipped, 0 failures（2026-01-30）
- `make test-tsan`：Executed 266 tests, 1 skipped, 0 failures（2026-01-30）
- `make test-perf`：Executed 25 tests, 7 skipped, 0 failures（2026-01-30）

## [v0.59.fix3] - 2026-01-29

### Perf/Search

- `computeCorpusMetrics` 刷新从“时间驱动”改为“仅 stale/force 刷新”，消除周期性 O(n) 聚合抖动（保持搜索语义不变）。
- 短词（≤2 chars）候选分页：用 top‑K heap 取 `offset+limit+1` 替代全量排序，避免 O(k log k)（保持排序 comparator 不变），并新增深分页一致性回归测试。

### Perf/UI

- hover Markdown 渲染移出 MainActor，减少滚动/hover 卡顿。
- 滚动期间缩略图 decode 降优先级，减少主线程竞争。

### Infra/SQLite

- DB user_version bump 到 `6`：在 `scopy_meta` 增量维护 `item_count/unpinned_count/total_size_bytes` 并通过 trigger 保持精确一致；统计读侧从 O(n) 收敛到 O(1)（旧库自动 fallback 到原 SQL）。
- 新增索引 `idx_recent_order` / `idx_app_last_used`，降低常见排序与 recent apps 分组查询的常数开销（语义不变）。

### Tooling/Perf

- 修复 `scripts/perf-audit.sh` 在 `set -u` 下空数组展开崩溃，便于稳定输出基准日志。

### Test

- `make build`：**BUILD SUCCEEDED**（2026-01-29）
- `make test-unit`：Executed 272 tests, 1 skipped, 0 failures（2026-01-29）
- `make test-strict`：Executed 272 tests, 1 skipped, 0 failures（2026-01-29）
- `make test-tsan`：Executed 262 tests, 1 skipped, 0 failures（2026-01-29）
- `make test-perf`：Executed 25 tests, 7 skipped, 0 failures（2026-01-29）

## [v0.59.fix2] - 2026-01-27

### Tooling/Test

- 修复 `make test*` 系列目标的“假绿”：为所有 `xcodebuild … | tee …` pipeline 启用 `pipefail`，确保测试失败会正确让 `make` 返回非 0。

### Fix/Swift 6 Concurrency

- 收敛 Swift 6 Strict Concurrency 阻塞级告警：为 Markdown/WKWebView 渲染与导出路径补齐 MainActor/Sendable 语义并修正 WebKit delegate 签名，避免 Swift 6 language mode error 类诊断。
- Settings 热键录制：以有界轮询等待 Settings 持久化回写，避免跨并发边界传递非 Sendable 值导致的诊断与潜在不稳定。

### Fix/TSan

- 修复 TSan 下的测试 data race：将测试轮询 helper 迁移到 MainActor 访问 UI state，并在 `SCOPY_TSAN_TESTS` 下放宽一处性能断言，提升 `make test-tsan` 稳定性。

### Fix/AVFoundation

- 替换弃用的同步 track 属性访问：使用 `loadTracks(withMediaType:)` 与 `load(.naturalSize/.preferredTransform)` 异步加载，兼容新版 SDK 并避免主线程阻塞。

### Test

- `make build`：**BUILD SUCCEEDED**（2026-01-27）
- `make test-unit`：Executed 266 tests, 1 skipped, 0 failures（2026-01-27）
- `make test-strict`：Executed 266 tests, 1 skipped, 0 failures（2026-01-27）
- `make test-tsan`：Executed 256 tests, 1 skipped, 0 failures（2026-01-27）

## [v0.59.fix1] - 2026-01-19

### Perf/Search

- **fullIndex 磁盘缓存 hardening（best-effort）**：缓存升级到 v3（DB/WAL/SHM fingerprint + `*.sha256` 旁路校验）；校验失败自动回退 DB 重建，保证准确性优先。
- **full-history correctness 兜底（外部写入/漏回调）**：引入 `scopy_meta.mutation_seq`（commit counter）作为 change token；检测到未观测提交时丢弃内存索引并回退 SQL 扫描/重建，避免 full-history 不完整。
- **tombstone 衰退兜底**：upsert（文本/备注）产生 tombstone 同样纳入 stale 判定，达到阈值触发后台重建，避免 postings 膨胀导致 refine 逐步变慢。
- **深分页成本收敛**：deep paging 采用 bounded top-K 缓存，避免大 offset 反复扫描或无界内存增长。
- **close/pending 体验**：写盘改为后台任务 + time budget 等待；build 取消/失败也清理 pending 队列。

### DB/Migration

- 新增 `scopy_meta`（`mutation_seq` commit counter）；DB user_version bump 到 `5`。

### Test

- `make test-unit`：Executed 266 tests, 1 skipped, 0 failures（2026-01-19）
- `make test-strict`：Executed 266 tests, 1 skipped, 0 failures（2026-01-19）
- `make test-real-db`：Executed 2 tests, 0 failures（2026-01-19）

## [v0.59] - 2026-01-13

### Perf/Search

- **冷启动首次 refine（forceFullFuzzy）大幅收敛（不减搜索范围）**：prefilter 命中后后台预热 fullIndex，并新增 fullIndex 磁盘冷启动缓存（best-effort，fingerprint 校验不匹配则放弃加载）。  
  - 真实 DB 对照（`make test-real-db`，`~/Library/Application Support/Scopy/clipboard.db` ≈ 148.6MB）：prefilter ~1.30ms；prefilter+预热 refine ~16.33ms；冷启动直接 refine ~2305.90ms；磁盘缓存加载 refine ~861.03ms；缓存文件 ~38.8MB。
- **低风险热路径收敛**：query 预处理（避免 per-item 分配）、ASCII postings 快路径（减少 Character 字典开销）、statement cache LRU、`json_each` 固定 SQL shape + 保序 fetch 等，保持语义与排序一致。

### Tooling/Test

- 新增真实 DB 对照回归：验证 “prefilter+prewarm 的 refine” 与 “冷启动直接 refine” 结果集合 + 排序一致；验证磁盘缓存加载与重建结果一致。
- 新增 `make test-real-db` 入口（可选，需 `-DSCOPY_REAL_DB_TESTS`）。

### Test

- `make test-unit`：Executed 259 tests, 1 skipped, 0 failures（2026-01-13）
- `make test-strict`：Executed 259 tests, 1 skipped, 0 failures（2026-01-13）

## [v0.58.fix2] - 2026-01-12

### Perf/Search

- **2 字中文/非 ASCII 短词提速（不减搜索范围）**：`ShortQueryIndex` 新增非 ASCII UTF16 bigram postings；短词（≤2）在 index 就绪后优先走“候选集 + SQL instr 排序”路径，避免对全表执行 `instr(...)` substring 扫描；语义与排序保持一致，且候选集不会漏项（必要时仍会回退到全表扫描）。  
  - 真实 143MB / 6k+ 项快照库（`perf-db/clipboard.db`，release `ScopyBench`，warmup 20/iters 30）：`数学` avg ~10ms，P95 ~13ms（此前 ~31ms avg）。

### Test

- `make test-unit`：Executed 256 tests, 1 skipped, 0 failures（2026-01-12）
- `make test-strict`：Executed 256 tests, 1 skipped, 0 failures（2026-01-12）

## [v0.58.fix1] - 2026-01-11

### Perf/Search

- **2 字短词进一步提速**：为 ASCII 1/2 字符短词引入内存 `ShortQueryIndex`（char/bigram 稀疏 postings），用候选集快速定位并以 Swift UTF-8 bytes 扫描计算 matchPos，避免 SQLite `lower(...)`/`instr(...)` 全表扫描的高开销（覆盖不漏项，排序语义保持一致）。

### Infra/SQLite

- `SQLiteStatement.columnTextBytes(_:)`：支持零拷贝读取 UTF-8 字节，供高性能扫描使用。

### Test

- 新增短词 pinned 命中回归测试（SearchServiceTests）。
- `make test-unit`：Executed 255 tests, 1 skipped, 0 failures（2026-01-11）
- `make test-strict`：Executed 255 tests, 1 skipped, 0 failures（2026-01-11）

## [v0.58] - 2026-01-11

### Perf/Search

- **Fuzzy（ASCII 长词）大幅提速**：将 ASCII 子序列匹配从 `Character` 遍历改为 UTF16 单次扫描，显著降低 6k+ 大文本历史下的全量 fuzzy 延迟（稳定性/语义保持不变，排序仍由 score + lastUsedAt 决定）。
- **渐进式全量校准（不减搜索范围）**：长文本语料优先返回 FTS 预筛首屏，并在后台自动触发全量校准（UI 提示“正在全量校准”，排序/漏项会更新）。
- **短词（≤2）全量覆盖**：Fuzzy/Fuzzy+ 的短词不再依赖 cache-limited prefilter；在未预热全量索引时使用 SQL substring 扫描保障全量匹配，索引已存在时优先走内存索引以进一步降低延迟。

### Fix/UX

- **搜索时显示 Pinned 命中结果**：Pinned 区域不再仅在空搜索时展示；搜索状态下如有 pinned 命中会稳定显示。

### Perf/UI

- **缩略图路径判断降载**：DTO 转换避免对每条结果重复触盘检查缩略图文件；启动时异步建立 thumbnail cache 文件名索引，并在生成缩略图时增量更新索引，降低端到端搜索/滚动抖动。

### Tooling/Perf

- **真实性能基准**：新增 `make snapshot-perf-db`（从 `~/Library/Application Support/Scopy/clipboard.db` 复制最新快照到仓库目录，文件不提交）与 `make bench-snapshot-search`（release 级基准）。
- **可选端到端快照测试**：新增 `make test-snapshot-perf`（需先准备 `perf-db/clipboard.db`）。

### DB/Migration

- **可选 Trigram FTS**：在 SQLite 支持 trigram tokenizer 时创建 `clipboard_fts_trigram`（不支持则跳过，保持数据库可用）。

### Test

- `make test-unit`：Executed 254 tests, 1 skipped, 0 failures（2026-01-11）
- `make test-strict`：Executed 254 tests, 1 skipped, 0 failures（2026-01-11）

## [v0.57.fix2] - 2026-01-03

### Fix/Clipboard

- **Excel 复制单元格误识别为图片**：当剪贴板同时包含“图片预览 + Office 表格类富文本/文本”时，优先存储 HTML/RTF/文本语义，图片降级为兜底，避免历史记录变成图片并影响粘贴行为。

### Test

- `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 283 tests, 25 skipped, 0 failures（2026-01-03）

## [v0.57.fix1] - 2026-01-02

### Fix/Clipboard

- **ChatGPT 网页复制公式纯文本错乱**：当网页使用 KaTeX/MathML 渲染公式且剪贴板 `.string` 发生“拆字/换行”时，从 HTML 的 `<annotation encoding="application/x-tex">` 提取 LaTeX，并生成 `$...$`/`$$...$$` 形式的可粘贴文本。
- **RTF + HTML 共存择优**：当剪贴板同时包含 RTF/HTML 时，优先采用 HTML 提取的 TeX 纯文本（而非碎片化 plain text），避免历史内容被污染。

### Dev/Release

- **Homebrew cask 不再被同步回滚**：发布后保持 `Casks/scopy.rb` 与 release 版本/sha 一致（作为 `Suehn/homebrew-scopy` 的同步源），避免 Homebrew 长期停留在旧版本。

### Test

- `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：Executed 280 tests, 25 skipped, 0 failures

> 2025 entries moved to doc/archive/changelog/2025.md.
