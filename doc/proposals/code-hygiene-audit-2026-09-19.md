---
doc_type: proposal
status: draft
owner: hh
created: 2026-09-19
audience: maintainer decision + implementing agent
---

# Scopy 代码卫生审计（2026-09-19）：冗余测试、假设行为、研究期残留

基线：`5e2c168`（v0.80.7）加工作区未提交改动。审计问题来自一条被广泛转发的观察："和 AI 结对写 PR 之后，如果不仔细看代码，你不知道有多少冗余测试、假设的行为、以及只该在研究期发生的断言正悄悄混进代码库；直到代码库比需要的大 10 倍、代理性能因此直线下降。"本文回答三个问题：Scopy 里是否存在这些问题、具体在哪、怎样清理而不改变任何功能与性能。

四个并行的只读审计各自覆盖一个面（运行时研究残留、产品代码死代码与测试缝隙、测试套件、渲染器与工具链），主线程对每类抽查了关键结论。行号以 `5e2c168` 为准，实施前须重新定位。

## 0. 结论

| 维度 | 规模 | 现状 |
| --- | --- | --- |
| 产品 Swift（`Scopy/`） | 154 文件 / 51,107 行 | 约 670 行可零行为变化删除；约 2,430 行只为测试存在（其中约 2,100 行 UI 测试 harness 编进 Release 包）；约 245 行推测路径 |
| 单元/UI 测试 | 96 文件 / 32,635 行 | 约 57 个方法 / 1,780 行不检出任何回归；`PerformanceTests` 1,320 行从不在 CI 运行且 12 个方法已被 `ScopyBench` 门禁逐字覆盖 |
| 工具链与渲染器 | `scripts/` 10,631 行，渲染器 7,726 行 | 约 580 行无任何引用；约 1,217 行一次性研究工具仍在 live tree；渲染器运行时本身干净 |
| 运行时断言 | 8 处 | 全部是真实不变量，没有 `fatalError`，无需处理 |

三类问题都存在，但集中且可定位，不是弥漫性的。运行时性能影响真实但小，且全部可零风险移除：搜索每次按键完整执行一次被丢弃的 `SearchPlanner.plan`；每次 Markdown 渲染多做一次无人读取的 `containsMath` 扫描；模糊搜索每次 4 个无条件时钟读取；每次 hover 一条带计时的 info 日志。

最直观的一条：工作区里未提交的 `SCOPY_EXP_OPAQUE_ROWS` 实验（`FloatingPanel.swift`、`ContentView.swift`、`HistoryListView.swift`，17 行）来自 2026-09-04 的滚动天花板研究，结论当天已写进 `doc/perf/studies/perf-scroll-ceiling-2026-09-04.md`，代码却在工作区躺了 15 天。

## 1. 研究期残留（运行在产品里）

### 1.1 直接删除，零行为变化（约 136 行）

| 项 | 位置 | 证据 |
| --- | --- | --- |
| `SCOPY_EXP_OPAQUE_ROWS` 实验 | 工作区未提交：`Scopy/FloatingPanel.swift:75`、`Scopy/Views/ContentView.swift:14`、`Scopy/Views/HistoryListView.swift:49-51,140` | 注释自述 `// EXPERIMENT:`；仓库内无任何脚本/测试设置它；研究结论已归档 |
| `SCOPY_PERF_SIGNPOSTS` + 唯一一对 `os_signpost` | `SearchEngineImpl.swift:99, 1784-1798` | 无脚本、Makefile、文档、测试设置它 |
| `SCOPY_CLEANUP_SHADOW_COMPARE` | `Scopy/Runtime/PerfFeatureFlags.swift:36-38`、`StorageService.swift:1698-1702` | 默认 false，只产生日志，无 setter |
| 4 个无消费者的 `PerfFeatureFlags` 折叠为默认路径 | `cleanupCompositePlan`（`StorageService.swift:1380,1668`）、`externalSizeMeta`（`:1231`）、`searchAdaptiveTuning`（`SearchEngineImpl.swift:119-145`）、`fuzzyFirstPageCache`（`:3183`） | 全仓无引用；非默认分支各 1-50 行随之删除 |
| 每次搜索执行的 `SearchPlanner.plan` | `SearchEngineImpl.swift:1928-1930, 1944-1951` | 结果只进 `perf?.addReason`，`perf` 仅在 `SCOPY_PERF_METRICS=1` 时非 nil；路由由 `switch request.mode` 决定，与 plan 无关。改为 `if let perf { ... }` 内执行，或连同 `SearchPlanDiagnostic`（`SearchPlanner.swift:8,51-54,249-256`，唯一读者 `SearchPlannerTests.swift:152`）一起删除 |
| 4 个无条件时钟读取 | `SearchEngineImpl.swift:3026, 3050, 3098, 3129` | 配对的 `perf?.addPhase` 在 perf 关闭时丢弃结果；同文件 `:2700-2710` 已用 `if let perf` 正确写法 |
| `MarkdownRenderDiagnostics` | `MarkdownPreviewRenderer.swift:5-12`、`MarkdownHTMLRenderer.swift:45-60` | 所有调用者只取 `.html`；每次渲染额外跑一次 `MarkdownDetector.containsMath` |
| 纯计时日志 | `SearchIndexDiskCache.swift:299-301, 352-357`（`#if DEBUG`）、`SearchEngineImpl.swift:1251-1254, 1309-1312`、`HistoryViewModel.swift:880-882`、`HistoryHoverPreviewPipeline.swift:557-563`（每次 hover）、`PngquantService.swift:164,171-173`、`MarkdownExportService.swift:2511,2539-2543` | 无消费者，只是 `.info`/`.debug` 文本 |
| `ScopyLog.persistence` | `ScopyLogger.swift:10` | 全仓零调用 |

### 1.2 保留，并说明为什么

- `HotKeyService.logToFile` 与 `/tmp/scopy_hotkey.log`（24 处调用）：`AGENTS.md:39` 把它列为热键改动的验证证据，是文档化门禁，不是残留。
- `SCOPY_PERF_METRICS`、`SearchPerfMetrics`、`PerfContext`：`Tools/ScopyBench/main.swift:224` 与 `make test-snapshot-perf-release` 门禁依赖。
- `PerformanceMetrics`、`ClipboardIngestMetrics`、`CorpusMetrics`、`MarkdownContentMetrics`、`PDFRasterMetrics`：驱动 footer/About 页/搜索路径选择/预览尺寸/栅格预算，是产品行为。
- `ScrollPerformanceProfile.recordTiming` 包装（`HistoryItemView.swift:132-140, 893-901` 等 10 处）：由 `static let isEnabled` 短路，关闭时只剩一次布尔读取；`scripts/perf-frontend-profile.sh` 与 `development-guide.md:149` 要求它。
- 7 个仍被 `scripts/perf-warm-scroll-ab.sh` / `perf-frontend-profile.sh` 切换的 A/B 开关（`passiveRow`、`markdownMenuSignalCache`、`historyIndex`、`scrollResolverCache`、`markdownResolverCache`、`shortQueryDebounce` 等）：见 §5 决策 D3。

## 2. 假设行为与死代码（产品代码）

### 2.1 直接删除，零行为变化（约 530 行）

整文件：

| 文件 | 行 | 证据 |
| --- | --- | --- |
| `Scopy/Design/ScopyComponents.swift`（`CapsuleFilterButtonStyle`、`InfoTag`、`ScopyButton`、`ScopyCard`、`ScopyBadge`） | 184 | 五个顶层符号在所有 Swift 源中只出现在声明处 |
| `Scopy/Views/Settings/SettingsFeatureRow.swift` | 24 | 同上 |

函数与属性（每项全仓仅声明处一次出现）：

| 项 | 位置 | 行 |
| --- | --- | --- |
| `backgroundMediaSchedulingSnapshot()` + `BackgroundMediaSchedulingSnapshot` | `ClipboardService.swift:2507-2523, 711-723` | 30 |
| `SearchEngineImpl.fetchAllSummaries()`（且是 `SQLiteClipboardRepository.swift:605` 的重复） | `SearchEngineImpl.swift:3971-3988` | 18 |
| `parseHeightsFromLayoutDebugInfo` | `MarkdownExportService.swift:2054-2071` | 18 |
| `MockClipboardService.simulateNewClipboardItem` | `MockClipboardService.swift:710-729` | 20 |
| `AppVersion.versionWithDate` + 随之孤立的 `buildDate` | `AppVersion.swift:23-38` | 14 |
| `katexDelimitersJSArrayLiteral` | `MathEnvironmentSupport.swift:66-75` | 10 |
| `MarkdownPreviewCache.updateFilePreviewHTML/Metrics` | `MarkdownPreviewCache.swift:76-86` | 10 |
| `SettingsViewModel.refreshStorageStats` | `SettingsViewModel.swift:93-98` | 6 |
| `SearchCoverage.recentOnlyLimit` | `SearchCoverage.swift:20-25` | 6 |
| `PerformanceMetrics.searchSampleCount/loadSampleCount` | `PerformanceMetrics.swift:64-71` | 8 |
| `AppState.resetShared`、`HistoryItemView.cancelPreviewTask`、`chatGPTRenderWidth`、`ScopyColors.headerBackground`、`ScopySpacing.xxl/xxxl`、`ScopyTypography.sidebarLabel`、`MarkdownSyntaxProtectionKind.shortcutReference` | 各自文件 | 12 |
| `MarkdownRenderLayoutConstants.renderWidth(for:)`：忽略参数返回常量，唯一调用者是 `ChatGPTMarkdownRendererTests.swift:236` 断言 `== 816` | `MarkdownRenderLayoutConstants.swift:79-82` | 4 + 测试 |

未建成的功能与产品从不调用的 API：

| 项 | 位置 | 事实 | 处理 |
| --- | --- | --- | --- |
| `ignoredApps` 过滤 | `ClipboardMonitor.swift:285, 487-489, 813-816` | 唯一写入者是测试用 `setIgnoredApps`；无设置项、无 UI、无 DTO 字段；产品中永远为空集 | 删除 setter 与过滤分支（7 行）及其测试 |
| `StorageService.upsertItem` | `StorageService.swift:449-456` | 产品零调用，测试调用 243 次。它是 `upsertItemWithOutcome` 的薄包装，把产品当作 no-op 的 `.alreadyApplied(nil)` 转成抛错。测试因此看不到 `.inserted/.updated/.alreadyApplied` 三种结果 | 删除；在测试 target 加一个同签名的 `extension StorageService` 辅助函数走 `upsertItemWithOutcome`，243 处调用点无需改动 |
| `PanelReopenSearchResetPolicy.shouldClearSearch` | `FloatingPanel.swift:13-16` | 与产品实际使用的 `FloatingPanel.wasClosedLongerThan`（`:124-127`，`AppDelegate.swift:315` 调用）逐行相同；`AppStateTests.swift:841-849` 断言的是没人调用的复制品 | 删除，测试改为断言 `wasClosedLongerThan` |
| `performWALCheckpoint` | `StorageService.swift:436-438` | 产品用 `walCheckpointTruncate()`（`:1500`）；测试验证的是产品不跑的 passive 模式 | 删除，测试改指 truncate |
| `findByHash`、`updateDefaultSearchMode` | `StorageService.swift:721-723`、`SettingsViewModel.swift:47-56` | 产品零调用（分别走 `repository.fetchItemByHash`、Picker → `updateSettings`） | 删除 |
| 无 setter 的环境变量分支 | `SCOPY_TEST_RUN_ID`（`StorageService.swift:391`）、`SCOPY_UITEST_PNGQUANT_EXPORT_DEFAULTS`（`AppDelegate.swift:432-437`）、`SCOPY_UITEST_MARKDOWN_LAYOUT_SCALE`（`:421-425`）、`SCOPY_EXPORT_TEST_MARKDOWN`、`SCOPY_MOCK_THUMBNAIL_SIZE`、`SCOPY_RENDER_ID__` | 全仓无任何地方设置 | 删除（约 35 行） |

### 2.2 只为测试存在的产品代码（约 2,430 行，见 §5 决策 D1/D2）

- UI 测试 harness 全部编进 Release `Scopy` app（`project.yml:63-79` 的 excludes 不含 `Views/`；`Package.swift:18-31` 的 `ScopyKit` 含 `Services/`）：`Scopy/Views/UITesting/` 四个文件 1,069 行、`MockClipboardService.swift` 751 行、`AppDelegate.swift:51-63,93,103-165,355-378,418-440` 约 120 行、`AppState.swift:100-147` 约 45 行、`MarkdownExportService.swift`、`HistoryItemTextPreviewView.swift:450-480` 与 `HistoryItemMarkdownExportController.swift:138-160`（两份验证规则不同的 `parseExportResolutionPercent`）等散落分支约 280 行。CI（`.github/workflows/ci.yml`）与 Makefile 从不运行 `ScopyUITests`；唯一自动消费者是 `scripts/perf-warm-scroll-ab.sh:455` 与 `perf-frontend-profile.sh:208`。
- 单元测试缝隙约 330 行：`SearchEngineImpl.swift:5154-5240` 的 17 个 `debug*`（`#if DEBUG`，87 行）暴露 `fullIndexStale`、`tombstoneCount`、`buildGeneration` 等私有状态并允许测试注入伪造的 build task；`SearchIndexDiskCache.swift:652-674` 的 4 个 `debug*` 编解码器未加 `#if DEBUG`；`HotKeyService.swift:351-405` 测试模式 55 行（`isRegistered` 在 Debug 下语义被改变）；`AppState.forTesting`、`RealClipboardService.createForTesting`、`cachedTitle/cachedMetadata/cachedFilePreview/cachedRowDescriptor`、`queuedWaiterCount`（`snapshot()` 已暴露同值）、`isSafePublicURL/isSafeRedirectURL` 等。
- 遗留 eager-observer 行路径（`HistoryItemView.swift:336-338,383-392`、`HistoryListInteractionCoordinator.swift:108-110,232-238,450-456` 与 `notifyLegacyObservers`、`HistoryListInteractionObservation.swift`，约 60 行）自述为"transitional compatibility path"，只在 `SCOPY_PERF_PASSIVE_ROW=0` 或 `ListLiveScrollObserverHarnessView.swift:104` 时可达。

### 2.3 保留的"看似推测"路径

- SQLite `user_version 1→9` 迁移（`SQLiteMigrations.swift:4-42`）与 ingest spool 从 Caches 到 App Support 的迁移（`ClipboardMonitor.swift:1507-1615`，约 110 行）：每一步都对应已发布版本，真实用户可达；删除是"最低支持升级版本"的产品决定。
- `SettingsStore.decode` 逐键 `?? default`（`SettingsStore.swift:82-146`）：这就是设置格式的前后兼容方式。
- `ClipboardItemContentRevision.fallbackText`（`:13-24,85-87`）：触发条件 `contentHash.isEmpty`，而 `content_hash NOT NULL` 且所有采集路径都计算它，疑似不可达，但未穷举所有 DTO 构造点，暂留。

### 2.4 重复实现（约 120 行，含 3 处已漂移）

| 概念 | 副本 | 漂移 |
| --- | --- | --- |
| `formatBytes` | `Localization.swift:6`（ByteCountFormatter）、`ClipboardMonitor.swift:2668`、`ClipboardItemDisplayText.swift:619`、`StorageStatsDTO.swift:44`、`SettingsViewModel.swift:157`、`HistoryItemView.swift:2123` | 单位分级不同：900 字节在统计页显示 "0.9 KB"，在条目元数据显示 "900 B"。统一会改变可见文本，见 D5 |
| `verifySchema` | `SQLiteClipboardRepository.swift:1489-1508`（3 表）vs `SearchEngineImpl.swift:3894-3904`（2 表，漏 `ingest_receipts`） | 搜索侧漏检一张表，是潜在 bug |
| `parseStoredItemSummary`、`searchWithFTS`、`searchAllWithFilters` | repository 各 1 份 vs `SearchEngineImpl` 各 1-2 份 | 搜索引擎自带一套平行 SQLite 访问层；合并是重构不是清理，列入 §6 |
| `loadThumbnailIfNeeded` ×4、`hasSamePayload` ×2、`resolvedFileURLs` ×2、`previewHeight(width:)` ×2 | 各自文件 | 无漂移 |

## 3. 冗余测试

事实前提：`make test-unit` 与 `make test-strict` 都是 `-only-testing:ScopyTests` 并 `-skip-testing` `IntegrationTests`、`PollingIntervalSettingTests`、`ClipboardServiceContentFilteringIntegrationTests`、`PerformanceTests`（`Makefile:88-95, 207-215`）。CI 只跑这两个加 build 与文档/发布策略检查。`ScopyUITests` 没有任何 Makefile 或 CI 入口。

### 3.1 删除，零覆盖损失（约 57 个方法 / 1,780 行）

| 测试 | 位置 | 为什么不检出回归 | 现有覆盖 |
| --- | --- | --- | --- |
| `IntegrationTests` 类 12 个方法 | `IntegrationTests.swift:56-411` | 已被 Makefile 跳过；同文件其他类（`PollingIntervalSettingTests`、`SettingsStorePersistenceTests`、`SearchHintTests`）保留 | `StorageServiceTests`、`ClipboardServiceCopyToClipboardTests`、`StorageStatsSemanticsTests` |
| `ScrollPerformanceTests` 前 10 个方法 | `ScrollPerformanceTests.swift:47-305` | 不是性能测试，且被严格包含 | `ListLiveScrollObserverViewTests.swift:102-486` 用注入的 `hitView`/`testPart` 覆盖同一入口并多测 disabled/faded/detached 滚动条 |
| `SnapshotPerformanceTests` | 整文件 171 行 | `#if SCOPY_SNAPSHOT_PERF_TESTS` 编译排除，再依赖本地 DB 文件；断言的数字与 `make test-snapshot-perf-release` 相同（`maxP95: 50` ≡ `CMD_TARGET:=50`） | 该 Makefile 门禁 |
| `RealDatabaseRegressionTests` | 整文件 143 行 | `#if SCOPY_REAL_DB_TESTS` 编译排除，`make test-real-db` 无人调用 | 无（放弃即删） |
| `HistoryRowPixelSnapshotTests` | 121 行 | 需要 `SCOPY_ROW_SNAPSHOT_DIR`，全仓无人设置；断言只有 `width > 0` | 无 |
| `SearchServiceTests.testShortQueryUsesCache` | `:742-758` | 零断言，末尾 `print` 并注释 "soft assertion" | `testCacheInvalidation:762` |
| `SearchServiceTests.testSearchPerformance5kItems`、`testSearchPerformanceTiming`、`testPerfMetricsIncludeMatchEvidenceInsideSearchTotal` | `:703-738, 276-295` | 分别依赖无法传入的 `RUN_PERF_TESTS`（缺 `TEST_RUNNER_` 前缀）、`searchTimeMs < 100` 壁钟阈值、`SCOPY_PERF_METRICS`（只对 ScopyBench 二进制设置） | `ScopyBench`、`SearchMatchContextBuilderTests` |
| `HoverPreviewIntentPolicyTests.testSafeTriangleContains100kPerformance` | `:247-262` | `measure` 无阈值，每次单元运行跑 100k 点只记录数字 | `:9,29,40` |
| `ConcurrencyTests.testSearchTimeout`、`testConcurrentCleanupAndSearch`、`testDeduplication`、`testSequentialInsertAndSearch`、`testSearchResultConsistency` | `:372,405,168,118,319` | 分别是 `elapsed < 5.0`、`A \|\| B` 必过、重复、一半计数无条件自增、重复 | `SearchServiceTests:298`、`StorageServiceTests:949-1136`、`:470,519`、`SearchBackendConsistencyTests` |
| `ResourceCleanupTests` 4 个 | `:40,113,196,224` | 重复 | `StorageServiceTests:1137,411`、`SearchServiceTests:762`、`SearchStateMachineTests:474,521` |
| `AppStateTests` 6 个 `DoesNotCrash`/工厂冒烟 | `:86,402,415,428,444,483` | 唯一断言 `XCTAssertNotNil` | `:339,349,379,389` |
| `ReviewFix24Tests.IndexLifecycleTests` | `:8-60` | 与 `FullIndexTombstoneUpsertStaleTests` 同夹具同断言，中段被 `if !health.isStale` 自我中和；文件另两个类保留并改名 | `FullIndexTombstoneUpsertStaleTests:7` |
| `SearchPlannerTests` 3 个空白填充变体 | `:21,40,58` | 与 `:12,31,49` 只差空白，`normalizedExactQuery` 一次剥掉 | 合并 |
| `ContextMenuUITests` 3 个、`MainWindowUITests.testSearchFieldClearButton` | `:67,90,111`；`:60` | skip 消息自述平台永不暴露该元素；后者无条件 `throw XCTSkip` | 无需 |
| `ExportMarkdownPNGUITests` 1.5× 两个 | `:265,423` | 与 2× 版本结构相同（108 行中 44 行只差 "150"/"200" 与文件名），同一代码路径 | 2× 版本 |

### 3.2 `PerformanceTests.swift`（27 个方法，1,205 行）+ `Helpers/PerformanceHelpers.swift`（117 行）

从不在 CI 运行（被 `-skip-testing` 且每个方法 `XCTSkipIf(!shouldRunPerf())`），但被 `ScopyTests` 与 `ScopyTSanTests` 各编译一次（`project.yml:162,217`），78 个 `print` 无任何脚本解析。12 个搜索延迟方法与 `Tools/ScopyBench` + `make test-snapshot-perf-release` 逐字重复；其余 15 个（批量插入、内存、清理、去重）阈值依赖机器。见 D4。

### 3.3 实现镜像断言（本轮不动，登记备查）

`ChatGPTMarkdownRendererTests.swift:111-196` 约 95 个 CSS 字面量 `contains`：`doc/current/markdown-chatgpt-wacz-style-contract.md:515` 明确把该文件列为样式契约证据，修剪须先改契约。其余：`MarkdownExportServiceTests.swift:184-197`（重算私有预算常量、私有阈值 off-by-one）、`SearchServiceTests.swift:615-618`（断言 SQLite 触发器 SQL 文本）、`FullIndexDiskCacheHardeningTests` 的内部 reason 字符串、`ScrollPerformanceTests.swift:502-547`（硬编码 "abc" 的 SHA-256、`count == 14` 魔数、文档字符串内容）、`HistoryHoverPreviewPipelineTests.swift:70,148-171`（cache key 格式）。

### 3.4 sleep 与 print

声明的 sleep 共 60.4 s，其中 40 s 是 5 个故意永不完成、被取消的 10 s 挂起（正确写法）；实际增加单元运行约 6-8 s。可用 `HistoryRowThumbnailLifecycleSchedulerTests.swift:31-34` 已验证的注入时钟模式收回约 4 s：`SourceIconTests.swift:99`（3.2 s 真实延迟打真实 WKWebView）、`AsyncPermitPoolTests` 4×50 ms、`*DiskCacheHardeningTests` 固定 50 ms 等后台索引。99 个真实 `print` 中 95 个在上述三个编译排除文件里，随文件消失。

## 4. 工具链与渲染器

### 4.1 删除，无任何门禁/文档/CI 引用（约 580 行 + 零碎）

- `scripts/health-check.sh`（168）、`scripts/test-flow.sh`（284，重复 `deploy.sh` 且安装到 `/Applications`）及 Makefile 的 `health-check`、`test-flow`、`test-flow-quick` 目标。
- `scripts/perf-scroll/axat.swift`（38，`build-tools.sh:6` 不编译它）、`mouseloc.swift`（3，编译但无人调用）、`verify_hover_preview.sh`（46，依赖不存在的 `build/axat`，已坏）、`verify_hover_after_scroll.sh`（41）。
- `Tools/MarkdownRenderer/package.json:10` 的 `verify:assets:checked-in`（全仓唯一出现处）。
- `Tools/MarkdownRenderer/src/render.js:38-42`（`render` 传给 `renderInternal` 的第三个参数已不存在）、`:456,458`（`profile`、`policyVersion` 归一化后从未被读取）。
- `Tools/MarkdownRenderer/test/fixtures/codex-icons/globe-12.svg`、`globe-16.svg`（无测试加载）；`test/user-fixtures.test.js:32-38` 断言 fixture 文件字节数与 SHA（测的是 fixture 不是渲染器）。
- `Makefile:481-485`：四行 "Performance Targets (v0.md)" 的 `@echo` 误放在 `push-release` 配方里，发布推送会打印帮助文本。
- 未跟踪的本地残留：`scripts/perf-scroll/build/`（16 个二进制）、4 个 `__pycache__`、4 个 `.DS_Store`。

### 4.2 研究工具归档（约 1,217 行，见 D6）

`scripts/perf-scroll/` 的 `ab_scroll.py`、`profile_interaction.py`、`analyze_sample.py`、`verify_row_click.sh`、`compare_row_snapshots.py`、`hoverstall.swift`、`panelwatch.swift`、`enterlatency.swift`、`panelready.swift`（仅被 `doc/perf/studies/`、`doc/releases/history/` 或自身 README 提及）；`scripts/quality/analyze-chatgpt-wacz-markdown.py`（664 行，样式契约 `:16` 引用，但调用示例硬编码 `/Users/hh/Downloads/...wacz`）。保留 `profile_scroll/search/capture.py`、`sample.sh`、`build-tools.sh` 及其 Swift 小工具：`development-guide.md:149` 要求。

### 4.3 渲染器结论

`src/` 无 `console.*`、`performance.*`、`process.env`、debug 属性；npm 依赖全部被引用；`render.js:92-102` 的 math 计数元数据 app 不读但 5 个测试文件断言，是测试契约，保留。`nativeSourceIcons` 策略位产品侧恒为 `true`（`MarkdownHTMLDocumentBuilder.swift:2850`），`{enabled:false}` 分支只有测试走，可内联为常开。`chatgpt-wacz-20260828.test.js` 11 个测试中约 6 个与 `render.test.js`/`safe-html.test.js`/`delimiters.test.js` 重复。

## 5. 需要维护者决定的事项

| # | 决定 | 选项与建议 |
| --- | --- | --- |
| D1 | UI 测试 harness（约 2,100 行）是否继续编进 Release | (a) 现状；(b) 用独立编译条件 `SCOPY_UITEST_SUPPORT` 包裹，Debug 与 `ScopyWarmProfile` 配置开启、Release 关闭（不能用 `#if DEBUG`，perf 脚本用 Release 配置跑 UI 测试）；(c) 连同从不在 CI 运行的 `ScopyUITests`（约 4,680 行，其中 6 个方法是 perf 脚本入口）一起删除。建议 (b)，因为 6 个 perf 入口有 runbook 引用 |
| D2 | 单元测试缝隙（约 330 行）是否收口 | 建议：`SearchIndexDiskCache.debug*` 补 `#if DEBUG`；`queuedWaiterCount`、`isSafePublicURL/isSafeRedirectURL` 等薄包装改为测试侧 extension；`SearchEngineImpl.debug*` 是 5 个 hardening 测试文件的基础，本轮保留 |
| D3 | 7 个仍被 A/B 脚本引用的 `PerfFeatureFlags` | 每个开关都让一条非默认实现活着（如 `passiveRow` 的 eager-observer 路径 60 行）。若 A/B 脚本已完成使命（滚动天花板 2026-09-04 已关闭），可全部折叠并简化 `perf-warm-scroll-ab.sh`；否则保留 |
| D4 | `PerformanceTests.swift` 去留 | 建议删除 12 个已被 ScopyBench 门禁覆盖的方法与 `PerformanceHelpers.swift`；其余 15 个要么移到独立 `ScopyPerfTests` target 停止双重编译，要么按"无消费者即删"原则一并删除，并移除 `make test-perf`/`test-perf-heavy` |
| D5 | `formatBytes` 统一 | 统一到 `Localization.formatBytes` 会改变部分可见文本（"0.9 KB" vs "900 B"）。是修一致性 bug，但不是"完全不影响功能"，需明确同意 |
| D6 | `scripts/perf-scroll/` 研究工具归档去向 | 移到 `doc/perf/studies/tools/` 或直接删除（研究文档已记录结论）；同时修剪 `build-tools.sh:6` 与 `scripts/perf-scroll/README.md` |
| D7 | 是否在 `AGENTS.md` 增加 PR 后检查项 | 建议一条："PR 完成前检查：没有新增只被测试调用的产品符号；没有无消费者的环境变量开关或 feature flag；没有只打印数字、无阈值或无断言的测试；实验代码不进工作区提交。" |

## 6. 不属于本轮的重构

- `SearchEngineImpl`（5,241 行）内的平行 SQLite 访问层（`parseStoredItemSummary`、`searchWithFTS` ×2、`searchAllWithFilters` ×2、`verifySchema`）合并到 `SQLiteClipboardRepository`。
- `AppStateTests`（64）通过 `ScopyTests/AppStateTestCompatibility.swift`（161 行测试侧门面）测试 `HistoryViewModel`，与 `HistoryViewModelRegressionTests`（17）的真实重叠需逐行比对。
- 固定 sleep 改注入时钟（§3.4）。

## 7. 实施顺序与验证

**Phase 1（纯删除，零行为变化）**：§1.1、§2.1、§3.1、§4.1，以及 D4 中已被 ScopyBench 覆盖的 12 个方法。建议按面分 4 个 commit（产品死代码 / 运行时残留 / 测试 / 工具链），每个独立可回滚。

| 改动 | 门禁 |
| --- | --- |
| 产品 Swift | `make build`、`make test-unit`；触及 `SearchEngineImpl`、`StorageService`、`ClipboardService` 的删除加 `make test-strict` |
| `SearchPlanner.plan` 与时钟读取移入 perf 分支 | 属后端搜索性能改动：`make test-snapshot-perf-release`（用新鲜的 `make snapshot-perf-db` 副本），预期 p95 持平或更好 |
| 渲染器 | `Tools/MarkdownRenderer` 内 `npm test`、`npm run build`、`npm run verify:assets`；bundle 变化后 app 侧 build + unit |
| Makefile/scripts | `make test-tooling`；触及发布目标（`push-release` 的误放 echo）加 `make test-release-policy` |
| 文档 | `make docs-validate` |

**Phase 2**：D1-D7 决定后逐项执行，同样的门禁；D1(b) 需额外 `./deploy.sh --no-launch` 后确认 `/Applications/Scopy.app` 内不再含 harness 符号（`nm`/`strings` 抽查 `HistoryItemHarnessView`）。

**Phase 3**：§6。

预估 Phase 1 净减约 4,300 行（产品约 670、测试约 3,100、工具链约 580），全部无消费者或已被更好的测试/门禁覆盖；Phase 2 视决定再减 2,000-6,000 行。
