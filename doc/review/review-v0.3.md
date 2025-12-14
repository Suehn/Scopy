# Scopy 深度 Review & vNext 重构方案 / Dev 文档（单一真相源）

> 说明：本文用于指导后续“稳定性优先”的长期重构（含 Codex 执行）。`doc/review/review-v0.3-2.md` 为历史草案/补充材料，其中关键内容已合并到本文；后续以本文为准。

- 最后更新：2025-12-14
- 代码基线：`v0.43.2`
- 重构状态：Phase 0-7 已完成（至 `v0.43.2`）
- 关联文档：
  - 当前实现状态索引：`doc/implemented-doc/README.md`
  - 近期变更：`doc/implemented-doc/CHANGELOG.md`
  - 规格参考：`doc/dev-doc/v0.md`
  - 协作规范：`CLAUDE.md`、`AGENTS.md`

---

## 0. 文档使用方式（给未来自己 / 给 Codex）

本文组织方式：

1. **代码事实**：当前系统怎么跑（以源码为准）
2. **根因问题**：为什么你会体感“不优雅/不稳定”（结构性矛盾）
3. **目标架构与边界契约**：未来要变成什么样（并发/DB/事件/设置）
4. **分阶段计划 + DoD**：怎么按阶段落地、怎么验收、怎么回滚（可直接喂给 Codex）

全局执行原则（必须遵守）：

- 每个 Phase 必须 **可编译、可运行、可回滚**；禁止“大爆改后一把梭”。
- 先新增新模块与适配层，再替换引用，最后删除旧实现（避免半途不可用）。
- 任何“行为变化”必须有测试或文档说明；稳定性优先于“重命名/美化”。
- 任何涉及性能/部署变化：按 `CLAUDE.md` 要求更新 `DEPLOYMENT.md`（含环境与具体数值）。
- 每个 Phase 完成视为一次“开发完成”：必须更新 `doc/implemented-doc/vX.X(.X).md`、`doc/implemented-doc/README.md`、`doc/implemented-doc/CHANGELOG.md`（按 `CLAUDE.md`）。

---

## 1. 范围与底线（Non‑negotiables）

### 1.1 本轮范围

- 只做“架构/稳定性/性能确定性”的重构：并发模型、SQLite 归属、设置写入口、事件语义、缓存收口、文件结构。
- 不做 UI 视觉重做、不引入云同步/网络后端、不新增大型功能（除非为了稳定性必须改接口语义）。

### 1.2 必须达成的底线

1. **并发模型可证明正确**：消灭“`@MainActor` 声明 + 私下跑到 DispatchQueue/Task.detached 执行核心逻辑”的绕隔离模式。
2. **SQLite 归属清晰**：不再跨组件传递 `OpaquePointer`；连接策略明确（单连接 actor 或读写分离连接）。
3. **取消/超时语义可预测**：超时/取消至少保证“不会回写 UI、不会积压无意义工作、不会偷偷修改缓存状态”。
4. **行为兼容优先**：功能集合与 UI 行为保持一致（搜索模式、渐进 refine、分页、置顶、清理、缩略图、热键等）。
5. **性能不回退**：搜索与写入并发时抖动更小；主线程负载更低；性能基准不低于当前主版本（以测试为准）。

---

## 2. 现状（以代码为准）

### 2.1 关键入口与装配

- 启动链路：`Scopy/main.swift` → `Scopy/ScopyApp.swift` → `Scopy/AppDelegate.swift`
- UI 注入：`AppDelegate` 创建 `FloatingPanel`，根视图 `ContentView().environment(AppState.shared)`
- 关键回调：
  - `AppState.shared.applyHotKeyHandler` / `unregisterHotKeyHandler` 由 `AppDelegate` 注入
  - SettingsView 保存通过 `SettingsViewModel.updateSettingsOrThrow(...)` 写入；失败时留在窗口并提示错误，成功后由 `ClipboardService` 发出 `.settingsChanged`，`AppState` 统一驱动“reload settings + applyHotKeyHandler + reload list”

### 2.2 当前“前后端边界”

- UI 通过 `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift` 里的 `@MainActor protocol ClipboardServiceProtocol` 调用后端（`RealClipboardService` 为兼容层 adapter）。
- DTO/请求/事件/设置模型已拆到 `Scopy/Domain/Models/*`（Phase 0 已完成）。

### 2.3 当前运行时数据流（事实）

1. `ClipboardMonitor`（`@MainActor`）使用 `Timer` 轮询 `NSPasteboard.general.changeCount`
2. 提取 `RawClipboardData`（主线程），对大内容/图片走 `Task.detached` + 后台 hash
3. `ClipboardMonitor.contentStream: AsyncStream<ClipboardContent>` 发出事件
4. `Application/ClipboardService`（actor）消费 `contentStream`，协调 storage/search/settings，并统一发事件
5. `StorageService.upsertItem` 写入（DB 访问经 `SQLiteClipboardRepository` actor；外部文件/缩略图仍由 StorageService 负责）
6. `SearchEngineImpl`（actor）维护搜索索引（自持只读连接），并消费 upsert/delete/pin/clear 事件增量更新
7. `ClipboardService.eventStream` 发出 `ClipboardEvent`；`RealClipboardService` 仅转发该 stream
8. `AppState`（`@Observable @MainActor`）消费 `eventStream` → 更新 items/pagination/state → SwiftUI 刷新

### 2.4 关键文件规模（当前维护成本的直接来源）

| 文件 | 行数 | 主要职责（现状） |
|---|---:|---|
| `Scopy/Infrastructure/Search/SearchEngineImpl.swift` | 1063 | Search actor：只读连接 + fuzzy 索引 + 渐进 refine |
| `Scopy/Services/StorageService.swift` | 845 | 分级存储/缩略图/清理；DB 访问通过 repository |
| `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift` | 746 | SQLite write actor：CRUD/FTS/统计/清理 SQL |
| `Scopy/Services/ClipboardMonitor.swift` | 819 | pasteboard 轮询 + 提取 + hash + 任务队列 + AsyncStream |
| `Scopy/Application/ClipboardService.swift` | 499 | Application 门面 actor：生命周期 + 事件流 + 清理调度 |
| `Scopy/Observables/AppState.swift` | 756 | UI 状态 + 搜索/分页/过滤/事件消费 + 设置加载 |
| `Scopy/Views/HistoryListView.swift` | 129 | 列表框架（分区/触底加载） |
| `Scopy/Views/History/HistoryItemView.swift` | 473 | Row（缩略图/hover/操作） |
| `Scopy/Services/RealClipboardService.swift` | 110 | 兼容层 adapter：协议转发 |

---

## 3. 根因问题清单（按风险等级）

> 你体感“不稳定/不优雅”的根因，主要不是“算法不行”，而是“并发域/边界契约不自洽”。

### P0（必须先解的结构性风险）

#### P0-1：`@MainActor` 标注与实际执行上下文不一致（绕隔离）

现状（已解决：v0.32）：

- 搜索逻辑已迁入 `Scopy/Infrastructure/Search/SearchEngineImpl.swift`（actor），并移除 `DispatchQueue(label: "com.scopy.search")` / `runOnQueue*`
- 取消/超时改为结构化并发语义：在长循环中加入 `Task.checkCancellation()`，timeout/cancel 后不再回写 UI 可见状态

#### P0-2：SQLite 连接归属不清（`OpaquePointer` 跨组件/跨线程共享）

现状（已解决：v0.31–v0.32）：

- `OpaquePointer` 仅存在于 `Scopy/Infrastructure/Persistence/*`（连接封装与 repository actor 内部）
- 写入：`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`（actor）统一持有/串行化 DB 写连接
- 读取/搜索：`Scopy/Infrastructure/Search/SearchEngineImpl.swift` 自持独立 **只读连接**（`query_only` + `busy_timeout`），避免与写连接争用与跨线程共享

#### P0-3：取消/超时语义不严格（会继续偷偷跑）

现状（已解决：v0.43.2 完成增强）：

- 取消/超时由结构化并发控制：超时/取消后结果被丢弃，不再污染可见状态
- 已增强（v0.43.2）：取消/超时时对 read connection 调用 `sqlite3_interrupt`，进一步降低尾部浪费

#### P0-7：Low Power Mode 快速滚动仍可能卡顿（已解决：v0.43.2）

现状（v0.43.2）：

- List live scroll 时标记 `HistoryViewModel.isScrolling`（通过 `NSScrollView.didLiveScrollNotification` 监听）
- 滚动期间降载：
  - 暂停缩略图异步加载（避免 IO/解码抢占）
  - 禁用 hover 预览与 hover 选中（避免 popover 与频繁 selection 更新）
  - 滚动期减少动画开销（降低主线程合成压力）

效果：

- 在低功耗场景下快速滚动更稳（优先保证滚动流畅，滚动结束后恢复加载与预览）。

#### P0-4：设置与热键持久化多源写入（已解决：v0.30）

现状（v0.36）：

- Settings 持久化唯一入口：`Scopy/Infrastructure/Settings/SettingsStore.swift`（actor），统一读写 `UserDefaults["ScopySettings"]`
- 热键应用入口仍在 `AppDelegate.applyHotKey`（遵循 `AGENTS.md`），持久化通过 `SettingsStore.updateHotkey(...)` 完成
- Settings 保存：
  - UI 调用 `SettingsViewModel.updateSettingsOrThrow(...)` → service.updateSettings → `SettingsStore.save(...)`
  - 热键应用由 `ClipboardService` 发 `.settingsChanged`，`AppState` 统一驱动 `applyHotKeyHandler`；`AppDelegate.applyHotKey` 幂等，避免重复 unregister/register

剩余风险：

- 无（v0.43.1 已将保存路径与热键应用收敛为单一路径）

#### P0-5：事件语义不纯（已解决：v0.33）

现状（v0.36）：

- `clearAll()` 发 `ClipboardEvent.itemsCleared(keepPinned: true)`，不再触发 `.settingsChanged`
- `AppState.handleEvent(.itemsCleared)` 最小处理为 `await load()`；设置变更仍由 `.settingsChanged` 独立承载

#### P0-6：Clipboard ingest 背压策略不可控（已解决：v0.37）

现状（v0.37）：

- `ClipboardMonitor` 大内容处理改为“有界并发 + backlog”：
  - 不再在队列满时 cancel oldest task；改为 pending queue（超限仅丢弃最旧 pending，并记录 error log）
- 大 payload（默认 ≥ `ScopyThresholds.ingestSpoolBytes`）会先写入 `~/Library/Caches/Scopy/ingest/`，`contentStream` 仅传递 file ref：
  - `ClipboardMonitor.contentStream`：`.unbounded`（payload 不再携带大 `Data`）
  - `StorageService.upsertItem` 接收 file ref 并 move/copy 到最终 external storage；dedupe/失败路径会清理 ingest 文件
  - `ClipboardService` 在 settings 禁用图片/文件时也会清理 ingest 文件，避免泄漏

效果：

- 在常见 burst 场景下避免无声丢历史：背压主要转移到磁盘（ingest spool），内存峰值更可控。
- 仍存在极端情况下的丢弃策略（pending queue 超限丢弃最旧项），但会明确记录日志，便于诊断与后续 UI 提示扩展。

### P1（性能/维护性问题：重构时顺手解决）

#### P1-1：外部文件写入与 DB 插入缺少“失败回滚”（已解决：v0.31）

现状（v0.36）：

- `StorageService.upsertItem` 在 “外部写入成功但 DB insert 失败” 时执行 best-effort rollback（删除外部文件），避免 orphan 长期累积

#### P1-2：缓存体系重复、边界不清（已解决：v0.34）

现状（v0.36）：

- 图标：`Scopy/Infrastructure/Caching/IconService.swift` 作为单一入口（NSCache）
- 缩略图：`Scopy/Infrastructure/Caching/ThumbnailCache.swift` 作为单一入口（NSCache）；View 内静态缓存已移除

### P2（清洁度/一致性：Phase 6 收尾）

- 已完成（v0.36）：`AsyncStream` buffering policy 显式化（`ClipboardMonitor.contentStream`、`ClipboardService.eventStream`、`MockClipboardService.eventStream`）
- 已完成（v0.36）：日志统一到 `os.Logger`（保留热键文件日志 `/tmp/scopy_hotkey.log`）
- 已完成（v0.36）：阈值集中到 `ScopyThresholds`（ingest/hash offload、external storage）
- 已完成（v0.36.1）：Thread Sanitizer 回归（Hosted tests，`make test-tsan`）
- 已完成（v0.37）：P0-6 ingest 背压确定性（ingest spool + `.unbounded` stream）
- 已完成（v0.39）：Strict Concurrency 回归

---

## 4. vNext 目标（需求与质量门槛）

### 4.1 必须保留的功能（兼容清单）

- 监控剪贴板：text/rtf/html/image/file/other
- 去重：基于 `contentHash`；重复复制更新 `useCount/lastUsedAt`
- 置顶/取消置顶、删除、清空（保留 pinned）
- copy 回系统剪贴板：按 type 写入正确的 pasteboard 类型（含 file URLs）
- 搜索：
  - exact / fuzzy / fuzzyPlus / regex
  - appFilter / typeFilter / typeFilters
  - 分页 + `hasMore`
  - 渐进 refine（首屏预筛 + 后台全量校准），当前语义：`total == -1` 表示 total 不准确
- 缩略图与 hover 预览（含延迟/高度开关）
- 全局热键（默认 ⇧⌘C，可配置），并保持 `/tmp/scopy_hotkey.log` 自查能力
- 存储统计（db/external/thumbnails/total）

### 4.2 vNext 的主要交付（非功能）

- 并发正确性：最少做到“核心服务不再靠 GCD 绕隔离”；可逐步开启 Strict Concurrency/TSan 回归。
- SQLite 访问模型正确：不再共享同一连接跨线程；读写分离或 actor 串行化。
- 性能确定性：减少抖动与尾部；搜索取消/超时不再浪费资源。
- 可维护性：拆分巨型文件；形成可替换组件与清晰目录结构。

---

## 5. vNext 目标架构（原则 + 并发模型 + 事件语义）

### 5.1 分层（物理结构即边界）

建议最终形态（可渐进落地）：

- `App/`：AppDelegate/FloatingPanel/生命周期装配（唯一允许触碰窗口/菜单栏/Carbon 注册）
- `Presentation/`：SwiftUI Views + ViewModels（`@MainActor`）
- `Application/`：用例层（协调 monitor/repo/search/settings/pasteboard），推荐 actor
- `Domain/`：纯模型与协议（`Sendable`，不 import AppKit/SQLite/Carbon）
- `Infrastructure/`：Domain 协议实现（SQLite、文件系统、搜索引擎、monitor、hotkey、settings）
- `Utilities/`：通用工具

硬规则：

- Domain 不得 import `AppKit`/`SQLite3`/`Carbon`/`ImageIO`
- Presentation 不得 import `SQLite3`，也不直接读写外部文件路径
- `OpaquePointer` 只能出现在 `Infrastructure/Persistence/*` 目录下（其余目录禁止出现）

### 5.2 并发模型（最终必须落实）

- UI/ViewModel：`@MainActor`
- AppKit 边界（NSPasteboard/NSWorkspace/窗口/热键注册）：`@MainActor`
- Settings：`SettingsStore`（actor，SSOT）
- Persistence：`SQLiteClipboardRepository`（actor，写连接归属）
- Search：`SearchEngineImpl`（actor，独立只读连接 + 内存索引）
- Clipboard ingest：`PasteboardMonitor`（MainActor 轮询）+ 后台 hash/spool（可选）
- Application 门面：`ClipboardService`（actor），持有 continuation，统一事件语义

### 5.3 事件语义（必须纯化）

当前 `ClipboardEvent` 只有 `.settingsChanged` 无 payload，且被滥用。vNext 建议：

- 事件表达“发生了什么”，而不是“UI 该怎么刷新”。
- 不允许 “clearAll → settingsChanged” 这种复用。

建议事件（可渐进迁移，先保留旧 case 再替换）：

```swift
enum ClipboardEvent: Sendable {
    case itemInserted(ClipboardItemDTO)          // 或 Summary
    case itemUpdated(ClipboardItemDTO)
    case itemDeleted(UUID)
    case itemsCleared(keepPinned: Bool)
    case settingsChanged(SettingsDTO)            // 建议带 payload
    case statsChanged(StorageStatsDTO)           // 可选：减少 UI 主动轮询
}
```

事件流（AsyncStream）必须显式 buffering policy（例如 `.bufferingNewest(200)`），并对高频事件做合并策略。

---

## 6. vNext “前后端接口”（边界契约）

> 先定契约，再重构实现。契约稳定后，内部可以随意替换。

### 6.1 Domain 模型建议（最终形态）

当前 `ClipboardItemDTO` 同时承担“列表/搜索结果/展示派生字段”。vNext 建议拆为：

- `ClipboardItemSummary`：列表/搜索用（不带 rawData，避免大对象进 UI 热路径）
- `ClipboardItemPayload`：copy/preview 用（按需加载）

但为了低风险迁移，建议分两步：

1. Phase 0 先把现有 DTO 从 `ClipboardServiceProtocol.swift` 拆到 `Domain/`（不改名，不改字段）
2. Phase 5 再把 UI-only 的派生字段（如 `cachedTitle/cachedMetadata`）迁到 Presentation 层

### 6.2 vNext 服务协议建议（最终）

当前 `ClipboardServiceProtocol` 标注 `@MainActor`，会迫使“后端门面”也跑在 MainActor。vNext 的方向是把后端做成 actor 并在内部处理 AppKit 边界。

推荐最终协议（可作为新协议并通过 adapter 迁移）：

```swift
protocol ClipboardServiceVNext: AnyObject, Sendable {
    func start() async throws
    func stop() async

    func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemSummary]
    func search(_ request: SearchRequest) async throws -> SearchResultPage

    func pin(id: UUID) async throws
    func unpin(id: UUID) async throws
    func delete(id: UUID) async throws
    func clearAll(keepPinned: Bool) async throws

    func copyToPasteboard(id: UUID) async throws
    func loadPreviewData(id: UUID) async throws -> Data?

    func getSettings() async throws -> SettingsDTO
    func updateSettings(_ settings: SettingsDTO) async throws
    func getStorageStats() async throws -> StorageStatsDTO

    var events: AsyncStream<ClipboardEvent> { get }
}
```

兼容策略：

- Phase 0/1 先不改现有 `ClipboardServiceProtocol` 的 shape，只做“内部重构 + 适配层”
- Phase 3/4 再引入 `ClipboardServiceVNext` 并让 `AppState` 逐步迁移

---

## 7. 目标目录结构与迁移映射

### 7.1 推荐目录结构（落地目标）

```
Scopy/
  App/
    AppDelegate.swift
    FloatingPanel.swift
    HotKeyCoordinator.swift
    AppEnvironment.swift

  Presentation/
    ViewModels/
      AppState.swift                // 可拆：HistoryVM/SettingsVM
    Views/
      ContentView.swift
      HistoryListView.swift
      SettingsView.swift

  Domain/
    Models/
      ClipboardItemDTO.swift
      SearchRequest.swift
      SearchResultPage.swift
      SettingsDTO.swift
      StorageStatsDTO.swift
      ClipboardEvent.swift
    Protocols/
      ClipboardServiceProtocol.swift

  Application/
    ClipboardService.swift           // vNext 门面 actor

  Infrastructure/
    Clipboard/
      PasteboardMonitor.swift
      ClipboardReader.swift
      ContentHasher.swift
      PasteboardClient.swift
    Persistence/
      SQLiteConnection.swift
      SQLiteMigrations.swift
      SQLitePaths.swift
      FileStore.swift
      ThumbnailStore.swift
      SQLiteClipboardRepository.swift
    Search/
      SearchEngineImpl.swift
      FTSQueryEngine.swift
      FullFuzzyIndex.swift
      FuzzyScorer.swift
      CandidatePrefilter.swift
      TopKSelector.swift
      SearchCache.swift
    Settings/
      SettingsStore.swift
    HotKey/
      HotKeyService.swift
    Caching/
      IconService.swift
      ThumbnailCache.swift

  Utilities/
    ...
```

### 7.2 迁移映射（从现状到目标）

| 现有文件/类型 | vNext 归属 |
|---|---|
| `Scopy/Services/StorageService.swift` | `Infrastructure/Persistence/SQLiteClipboardRepository.swift`（actor）+ `FileStore/ThumbnailStore` |
| `Scopy/Services/SearchService.swift` | `Infrastructure/Search/SearchEngineImpl.swift`（actor）+ 组件拆分 |
| `Scopy/Services/ClipboardMonitor.swift` | `Infrastructure/Clipboard/PasteboardMonitor.swift`（MainActor）+ reader/hasher 拆分 |
| `Scopy/Services/RealClipboardService.swift` | `Application/ClipboardService.swift`（actor），旧类短期变 adapter |
| `Scopy/Protocols/ClipboardServiceProtocol.swift` | `Domain/Models/*` + `Domain/Protocols/ClipboardServiceProtocol.swift`（只保留协议） |
| `Scopy/Views/HistoryListView.swift` | Presentation 拆分 + 缓存收口到 `Infrastructure/Caching/*` |

---

## 8. 模块级实现规格（原理与落地要点）

### 8.1 Clipboard ingest（监控/提取/hash/背压）

目标：monitor 只负责“检测变化 + 产出结构化 snapshot”，重计算/大内存 payload 处理要可控。

建议拆分：

- `PasteboardMonitor`（MainActor）：轮询 `changeCount`，输出 `RawClipboardSnapshot`
- `ClipboardReader`（MainActor）：负责识别类型与提取 Data/URLs（不触碰 DB）
- `ContentHasher`（后台）：统一 hash（建议 SHA256）；可加单测对齐

背压策略（必须在文档里写清楚）：

- 最少：显式 `AsyncStream` buffering policy（建议 `.bufferingNewest(200)`）
- 若继续丢弃任务：必须记录 drop 次数（日志/指标），并在文档写明“极端 burst 可能跳过部分历史”
- 推荐（更稳）：引入 `IngestSpool`（可选，vNext+1）
  - 对大 payload 先落盘到 `~/Library/Caches/Scopy/ingest/`
  - event 只携带引用路径/元数据，避免内存峰值

### 8.2 Persistence（SQLite + 文件/缩略图的事务式语义）

目标：DB 真相源，外部文件与 DB 记录具有“失败回滚”的一致性。

必须具备：

- `SQLiteConnection`：封装 prepare/bind/step/finalize；集中 `SQLITE_TRANSIENT` 与 column 读取 helper
- `SQLiteMigrations`：使用 `PRAGMA user_version` 做 migration runner（即使当前只有 v1 也要有框架）
- `SQLiteClipboardRepository`（actor）：
  - writer connection 串行化写入/清理/housekeeping
  - 外部文件写入：先写临时文件 → fsync/atomic move → DB insert；DB insert 失败则删除文件

连接策略：

- 优先建议：读写分离（writer conn + reader conn）+ WAL + busy_timeout（减少锁等待抖动）
- 备选：单连接 + actor 串行化所有 SQL（最稳但吞吐略差）

测试要求：

- 需要 repo 与 search 同时打开同一个 DB：测试使用 URI shared memory
  - `file:scopy_test?mode=memory&cache=shared` + `SQLITE_OPEN_URI`

当前 schema（来自 `StorageService.createTables/createIndexes/setupFTS`，重构时优先保持兼容，避免数据迁移风险）：

- 主表：`clipboard_items`
  - `id TEXT PRIMARY KEY`
  - `type TEXT NOT NULL`
  - `content_hash TEXT NOT NULL`
  - `plain_text TEXT`
  - `app_bundle_id TEXT`
  - `created_at REAL NOT NULL`
  - `last_used_at REAL NOT NULL`
  - `use_count INTEGER DEFAULT 1`
  - `is_pinned INTEGER DEFAULT 0`
  - `size_bytes INTEGER NOT NULL`
  - `storage_ref TEXT`
  - `raw_data BLOB`
- FTS：`clipboard_fts`（content=`clipboard_items`，triggers 同步）
- 索引：created_at/last_used_at/pinned/hash/type/app/type_recent
- 版本：当前用 `schema_version` 表；vNext 建议逐步迁到 `PRAGMA user_version`（可兼容并存一段时间）

### 8.3 Search（actor + 只读连接 + 可取消计算）

目标：保留现有搜索策略，但去掉 `DispatchQueue` 绕隔离与不可取消问题。

组件拆分建议（与现有实现一一对应）：

- `FTSQueryEngine`：FTS 查询与两步查询（rowid → 批量取主表）
- `SearchCache`：短词缓存（TTL + 大小）
- `FullFuzzyIndex`：全量 fuzzy 内存索引（postings/idToSlot）
- `FuzzyScorer`：`fuzzyMatchScore`（含短词连续语义、ASCII 连续子串语义）
- `CandidatePrefilter`：大候选集首屏 FTS 预筛（保留 `total == -1` 语义以兼容 UI/测试）
- `TopKSelector`：top‑K 小堆或 partial sort

取消语义：

- 全量评分循环中加入 `Task.checkCancellation()`（或定期检查 `Task.isCancelled`）
- timeout 不强求“强杀 SQL”，但必须保证“结果丢弃 + 不污染可见状态”
- 已增强（v0.43.2）：取消/超时时调用 `sqlite3_interrupt(readDb)`

### 8.4 Settings（SSOT）

目标：所有 settings/hotkey 只通过一个入口读写，消灭多源写入。

- `SettingsStore`（actor）负责：
  - load/save（UserDefaults 编码/解码）
  - `settingsStream`（AsyncStream）用于订阅变更

热键应用原则（遵循 `AGENTS.md`）：

- 统一入口仍是 `AppDelegate.applyHotKey`：注册 + 持久化（但持久化通过 `SettingsStore` 完成）
- 后端只发布 `settingsChanged(Settings)`，不直接触碰 Carbon 注册

### 8.5 UI/缓存收口

- 图标：只保留一个 `IconService`（内部用 NSCache/LRU），View 不再静态缓存图标
- 缩略图：只保留一个 `ThumbnailCache` + `ThumbnailStore` + 生成协调器
- `HistoryListView.swift` 拆分为更小的 View 组件；将复杂 I/O/缓存策略移出 View

---

## 9. 分阶段重构计划（可直接喂给 Codex）

> 每个 Phase 必须“先新增再替换”，并在最后删除旧代码。每个 Phase 的 Notes 记录关键决策与风险。

### Phase 0：Domain 抽离（文件结构先行，零行为变化）

目标：把 DTO/协议拆开，建立分层目录，为后续重构提供“物理边界”。

任务清单（脚本化）：

1. 新建目录：`Scopy/Domain/Models`、`Scopy/Domain/Protocols`
2. 把以下类型从 `Scopy/Protocols/ClipboardServiceProtocol.swift` 拆到独立文件（不改类型名/字段）：
   - `SearchMode`
   - `ClipboardItemType`
   - `ClipboardItemDTO`
   - `SearchRequest`
   - `SearchResultPage`
   - `ClipboardEvent`
   - `SettingsDTO`
   - `StorageStatsDTO`
3. `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift` 仅保留 `ClipboardServiceProtocol` 声明
4. 全仓修正 import（确保 tests 也能编译）

建议文件名（与类型一致，便于后续移动/重构）：

- `Scopy/Domain/Models/SearchMode.swift`
- `Scopy/Domain/Models/ClipboardItemType.swift`
- `Scopy/Domain/Models/ClipboardItemDTO.swift`
- `Scopy/Domain/Models/SearchRequest.swift`
- `Scopy/Domain/Models/SearchResultPage.swift`
- `Scopy/Domain/Models/ClipboardEvent.swift`
- `Scopy/Domain/Models/SettingsDTO.swift`
- `Scopy/Domain/Models/StorageStatsDTO.swift`
- `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`

验收（DoD）：

- `make test-unit`
- `xcodebuild -scheme Scopy -destination 'platform=macOS' build`

回滚：

- 仅文件移动/拆分；可通过 git revert 回滚，不涉及数据/行为。

Notes：

- 已完成（2025-12-12）：DTO/事件/请求/设置模型已拆分到 `Scopy/Domain/Models/*`，协议移动到 `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`；`make test-unit` 通过（53 tests passed，1 perf skipped）。

### Phase 1：SettingsStore（SSOT）+ 热键/设置写入口统一

目标：消灭 `UserDefaults["ScopySettings"]` 多点读写；保持热键应用入口仍在 `AppDelegate.applyHotKey`。

任务清单（脚本化）：

1. 新增 `Infrastructure/Settings/SettingsStore.swift`（actor）
   - 提供 `load() / save(SettingsDTO) / settingsStream`
   - 定义单一存储 key（沿用现有 `ScopySettings`，保持兼容）
2. 改造 `RealClipboardService`：
   - `getSettings/updateSettings` 只调用 SettingsStore，不再直接读写 UserDefaults
3. 改造 `AppDelegate`：
   - `loadHotkeySettings/persistHotkeySettings` 改为调用 SettingsStore（仍由 `applyHotKey` 触发持久化）
4. 改造 `SettingsView`：
   - 保存设置不再直接写 UserDefaults；可逐步减少对 `applyHotKeyHandler` 的重复调用（以 settingsStream 自动应用为目标）
5. 事件语义准备：
   - 先保留 `ClipboardEvent.settingsChanged`，但确保只在 settings 变更时触发

建议“改动点定位”（方便 Codex 精确修改，不误伤）：

- `Scopy/AppDelegate.swift`：`loadHotkeySettings()`、`persistHotkeySettings(...)`、`applyHotKey(...)`
- `Scopy/Services/RealClipboardService.swift`：`saveSettingsToDefaults(...)`、`loadSettingsFromDefaults()`、`updateSettings(...)`、`getSettings()`
- `Scopy/Views/SettingsView.swift`：`saveSettings()`（减少重复 applyHotKey 的路径，避免多源写入）
- `Scopy/Observables/AppState.swift`：`handleEvent(.settingsChanged)`（最终可改为订阅 SettingsStore 或接收带 payload 的 event）

机械校验（阶段性）：

- `rg -n \"UserDefaults\\.standard.*ScopySettings|settingsKey\\s*=\\s*\\\"ScopySettings\\\"\" Scopy`：除 `SettingsStore` 外逐步清零
- `rg -n \"settingsChanged\" Scopy`：确认只在 settings 变更触发（clearAll 不再复用）

验收（DoD）：

- `make test-unit`
- 热键自查：`/tmp/scopy_hotkey.log` 应出现 `updateHotKey()`，按下只触发一次
- 重启后设置与热键一致

回滚：

- 先以“并行写入+对照日志”方式灰度：短期保留旧读写路径但加 assert/日志，确认一致后再删除旧路径。

Notes：

- 已完成（2025-12-12）：新增 `Scopy/Infrastructure/Settings/SettingsStore.swift`（actor），`AppDelegate`/`RealClipboardService` 已迁移为通过 SettingsStore 读写 `ScopySettings`；仓库内 `UserDefaults.standard` 仅剩 SettingsStore；`make test-unit` 通过（53 tests passed，1 perf skipped）。

### Phase 2：Persistence actor（SQLiteClipboardRepository）+ 禁止 OpaquePointer 外泄

目标：SQLite 指针只存在于 persistence 层；为读写分离和 actor 化打地基。

任务清单（脚本化）：

1. 新增 `Infrastructure/Persistence/SQLiteConnection.swift`
   - 封装 open_v2/prepare/bind/step/finalize
   - 支持 URI（为 shared in-memory 测试铺路）
2. 新增 `Infrastructure/Persistence/SQLiteMigrations.swift`
   - 使用 `PRAGMA user_version` 跑 migration
3. 新增 `Infrastructure/Persistence/SQLiteClipboardRepository.swift`（actor）
   - 先迁移 StorageService 的“纯 DB”能力（CRUD/统计/cleanup 的 SQL）
   - 外部文件/缩略图先保持调用旧实现（可分 2a/2b）
4. 改造 `StorageService`：
   - 变成薄 wrapper（deprecated），内部转调 repository
   - 删除 `var database: OpaquePointer?`（或至少标记为 internal 并只用于迁移过渡）

建议拆成两个子阶段（更稳、更可回滚）：

- Phase 2a（DB-only）：先把 `clipboard_items/clipboard_fts` 的 SQL 与 migration 迁入 repository，仍复用现有文件/缩略图路径与工具函数。
- Phase 2b（FS）：再把外部内容写入、缩略图目录、orphan cleanup、vacuum/WAL checkpoint 等迁到 `FileStore/ThumbnailStore`，并补齐“写文件+入库失败回滚”。

验收（DoD）：

- `make test-unit`（必要时迁移 `StorageServiceTests` 到 repository tests）
- `Scopy/` 全仓 `rg "OpaquePointer"` 只命中 `Infrastructure/Persistence/*`

Notes：

- 已完成（2025-12-13）：
  - 新增 `Scopy/Infrastructure/Persistence/*`：`SQLiteConnection`（statement 封装）、`SQLiteMigrations`（`PRAGMA user_version`）、`SQLiteClipboardRepository`（actor，统一 DB 访问）与 `ClipboardStoredItem`（DB 行模型）。
  - `StorageService` 已移除 SQLite3 直接访问与 `database: OpaquePointer` 暴露，DB CRUD/统计/cleanup 均转调 repository；相关接口改为 `async` 并同步更新调用方。
  - 搜索侧的 SQLite 指针共享路径已移除；后续 Phase 3 已进一步删除 `SearchService`，替换为 `SearchEngineImpl` actor + 独立只读连接。
  - `SQLiteHelpers.swift` 已删除；DB 访问收口到 persistence/search 的封装层。
  - 机械校验：`Scopy/` 全仓 `rg "OpaquePointer"` 仅命中 `Infrastructure/Persistence/*`。
  - 测试：`make test-unit` 通过（53 tests passed，1 perf skipped）。

### Phase 3：Search actor（SearchEngineImpl）+ 只读连接分离 + 去 GCD

目标：消灭 `SearchService.runOnQueue*` 与共享 db 指针；搜索取消语义可预测。

任务清单（脚本化）：

1. 新增 `Infrastructure/Search/SearchEngineImpl.swift`（actor）
   - 自持 read connection（WAL + busy_timeout）
   - 把现有 `SearchService` 的算法逻辑迁入，并拆出组件文件
2. 迁移渐进 refine 语义：
   - 保持 `total == -1` 代表 total 不准确（兼容 `AppState` 与 `AppStateTests`）
3. 在长循环加入 cancellation checks
4. 更新测试：
   - 使用 shared in-memory DB URI，让 repo 与 search 同时打开同一 DB
   - `SearchServiceTests/ConcurrencyTests/PerformanceTests` 迁到新 SearchEngine 或 adapter

建议组件拆分（与现有 `SearchService` 一一对应，减少理解成本）：

- `FTSQueryEngine.swift`：对应 `searchWithFTS`（两步查询 + LIMIT+1）
- `FullFuzzyIndex.swift`：对应 `FullFuzzyIndex`/`buildFullIndex`/`charPostings`
- `FuzzyScorer.swift`：对应 `fuzzyMatchScore`（含短词连续语义、ASCII 连续子串语义）
- `CandidatePrefilter.swift`：对应 `ftsPrefilterSlots` + “totalIsUnknown/-1” 语义
- `TopKSelector.swift`：对应 `BinaryHeap` 与 top‑K 逻辑
- `SearchCache.swift`：对应 `recentItemsCache` + TTL + refresh 并发控制

必须保留/重点回归点（当前测试已覆盖，重构时不能破）：

- fuzzyPlus 的 ASCII 长词必须连续子串（`SearchServiceTests.testFuzzyPlusRequiresContiguousASCIIWords`）
- 渐进 refine：首屏 `total=-1`，后台 `forceFullFuzzy=true` 校准（`AppStateTests.testProgressiveRefine...`）
- 搜索切换与分页版本一致性：旧 loadMore 不能混入（`AppStateTests.testLoadMoreDoesNotAppendAfterSearchChange`）

机械校验（阶段性）：

- `rg -n \"DispatchQueue\\(label: \\\"com\\.scopy\\.search\\\"|runOnQueueWithTimeout|runOnQueue\\(\" Scopy`：应为 0
- `rg -n \"sqlite3_\" Scopy`：逐步收敛到 `Infrastructure/Persistence/*`（Search 只持 read connection 的封装）

验收（DoD）：

- `make test-unit`
- `make test-perf`（至少跑一次，确认无性能大回退）

Notes：

- 已完成（2025-12-13）：
  - 新增 `Scopy/Infrastructure/Search/SearchEngineImpl.swift`（actor），搜索逻辑迁入 actor；自持独立只读连接（`PRAGMA query_only` + `busy_timeout`）。
  - 删除旧 `Scopy/Services/SearchService.swift`，并在 `RealClipboardService` 完成装配替换（`start()` 中 `await search.open()`；数据变更回调改为 `await`）。
  - 搜索层不再使用 `DispatchQueue(label: "com.scopy.search")`/`runOnQueue*`；超时/取消语义由结构化并发 + `Task.checkCancellation()` 保证可预测。
  - DB 读取 SQL 迁入 SearchEngineImpl（通过 `SQLiteConnection` 封装执行），`sqlite3_*` 仍仅存在于 `Infrastructure/Persistence/*`。
  - 测试完成迁移：
    - 多连接测试统一改用 shared in-memory DB URI（`file:...mode=memory&cache=shared`）
    - 性能测试：heavy 场景改为 `RUN_HEAVY_PERF_TESTS=1` 才运行；磁盘用例清理先关闭连接避免 SQLite 警告。
  - 验收：`make test-unit` 通过（53 tests passed，1 skipped）；`make test-perf` 通过（22 tests passed，6 skipped）。

### Phase 4：ClipboardService actor（Application 层门面）+ 事件语义纯化

目标：形成唯一 UI-facing 后端门面；移除 `NSLock` 保护 continuation；clearAll 不再复用 settingsChanged。

任务清单（脚本化）：

1. 新增 `Application/ClipboardService.swift`（actor）
   - 持有 monitor/repo/search/settingsStore/pasteboardClient
   - 统一 start/stop 生命周期
   - 事件流由 actor 串行 yield/finish
2. 引入语义事件：
   - `itemsCleared(keepPinned:)`（替代 clearAll→settingsChanged）
3. `RealClipboardService` 降级为 adapter（短期），最终删除

建议“改动点定位”：

- `Scopy/Services/RealClipboardService.swift`：
  - `clearAll()`：改为发 `itemsCleared(keepPinned: true)`（或新事件），不再 `settingsChanged`
  - `eventStreamLock/isEventStreamFinished`：迁移到 actor 后应可删除
- `Scopy/Observables/AppState.swift`：
  - `handleEvent`：新增对 `itemsCleared` 的处理（最小行为：`await load()`）
  - 如果仍保留 `settingsChanged`：确保只用于 settings 变更

机械校验（阶段性）：

- `rg -n \"eventStreamLock|isEventStreamFinished\" Scopy`：最终应为 0（由 actor 串行保证）
- `rg -n \"\\.settingsChanged\" Scopy/Services/RealClipboardService.swift`：只允许出现在 settings 更新路径

验收（DoD）：

- `make test-unit`
- 手动验收：呼出窗口/搜索/复制/置顶/删除/清空/设置/热键

Notes：

- 已完成（2025-12-13）：
  - 新增 `Scopy/Application/ClipboardService.swift`（actor）：持有 continuation，统一 start/stop 生命周期与事件发射。
  - `RealClipboardService` 降级为 adapter（兼容层）：转发到 `ClipboardService`；移除 `eventStreamLock/isEventStreamFinished`。
  - 事件语义纯化：新增 `ClipboardEvent.itemsCleared(keepPinned:)`；`clearAll()` 发该事件，不再复用 `.settingsChanged`。
  - `AppState` 新增对 `.itemsCleared` 的处理（最小行为：`await load()`）；`MockClipboardService.clearAll()` 同步改为发 `.itemsCleared`。
  - 测试 DB：`ClipboardServiceFactory.createForTesting()` 改为 shared in-memory URI（多连接共享同一 DB）。
  - 验收：
    - `make test-unit` 通过（53 tests passed，1 skipped）
    - `xcodebuild test -only-testing:ScopyTests/AppStateTests -only-testing:ScopyTests/AppStateFallbackTests` 通过（46 tests passed）
    - `make test-perf` 通过（22 tests passed，6 skipped）

### Phase 5：Presentation 收口（ViewModel/缓存/巨型 View 拆分）

目标：把业务策略从 View 移走，让 UI 只做“状态 + 呈现”；缓存只有一个入口。

任务清单（脚本化）：

1. 缓存统一：
   - 新增 `Infrastructure/Caching/IconService.swift`、`Infrastructure/Caching/ThumbnailCache.swift`
   - 移除 `HistoryItemView` 静态 `NSCache` 与 `IconCacheSync`（或降级为内部实现）
2. 拆分 `HistoryListView.swift`：
   - 列表框架 / Row / Thumbnail / HoverPreview 分文件
3. 拆分 `AppState`（可选但建议）：
   - `HistoryViewModel` / `SettingsViewModel`，减少 Observation 半径

建议“改动点定位”（避免漏掉隐藏缓存）：

- `Scopy/Views/HistoryListView.swift`：
  - `HistoryItemView` 静态 `NSCache`（icon/thumbnail）与 `loadThumbnailIfNeeded`
  - `relativeTime` 静态缓存与锁
- `Scopy/Services/IconCache.swift`：
  - `IconCacheSync` 与 `IconCache` 的双套实现（最终只保留一个入口）
- `Scopy/Protocols/ClipboardServiceProtocol.swift`：
  - `ClipboardItemDTO.cachedTitle/cachedMetadata` 属于 UI 派生字段，建议迁到 Presentation（Phase 5 的“Domain vs UI”收口点）

机械校验（阶段性）：

- `rg -n \"static let (iconCache|thumbnailCache): NSCache\" Scopy/Views`：逐步清零（缓存入口收口）
- `rg -n \"IconCacheSync\\.shared\" Scopy`：逐步收敛到 `IconService`（单一入口）

验收（DoD）：

- UI 行为一致（不做 UI redesign）
- 运行一段时间内存不持续增长（至少通过肉眼观察 + Instruments 抽检）

Notes：

- 已完成（2025-12-13，部分）：
  - 新增 `Scopy/Infrastructure/Caching/IconService.swift`、`Scopy/Infrastructure/Caching/ThumbnailCache.swift`：收口 icon/thumbnail 内存缓存入口。
  - `Scopy/Views/HistoryListView.swift`：移除 `HistoryItemView` 静态 `NSCache`；缩略图加载改为复用 `ThumbnailCache`。
  - `Scopy/Observables/AppState.swift`：预加载图标改为使用 `IconService`；仓库内 `IconCacheSync` 引用清零。
  - 删除 `Scopy/Services/IconCache.swift`（旧 `IconCacheSync/IconCache` 双套实现）。
  - 性能测试稳定性：`ScopyTests/PerformanceTests.swift` 的 `testMixedContentIndexingOnDisk` 增加 warmup 查询，降低一次性抖动导致的误报。
  - 拆分巨型 View：将 `Scopy/Views/HistoryListView.swift` 拆分为 List/Row/Thumbnail/Preview 分文件（新增 `Scopy/Views/History/*`），降低维护成本并便于后续继续收口 Presentation。
  - 验收：
    - `make test-unit` 通过（53 tests passed，1 skipped）
    - `xcodebuild test -only-testing:ScopyTests/AppStateTests -only-testing:ScopyTests/AppStateFallbackTests` 通过（46 tests passed）
    - `make test-perf` 通过（22 tests passed，6 skipped）

- 已完成（2025-12-13，v0.38）：
  - `ClipboardItemDTO.cachedTitle/cachedMetadata` 的 Presentation 收口：
    - Domain：`Scopy/Domain/Models/ClipboardItemDTO.swift` 移除 UI-only 派生字段（DTO 只保留事实数据）
    - Presentation：新增 `Scopy/Presentation/ClipboardItemDisplayText.swift`（`NSCache`）为 `ClipboardItemDTO.title/metadata` 提供计算 + 缓存
  - `HeaderView.AppFilterButton` 移除 View 内静态 LRU 缓存，统一改为 `IconService`（图标/名称缓存入口收口）
  - 验收：
    - `make test-unit` 通过（53 tests passed，1 skipped）
    - `make test-perf` 通过（22 tests passed，6 skipped）
    - `make test-tsan` 通过（132 tests passed，1 skipped）

- 已完成（v0.40）：
  - （可选）拆分 `AppState`（History/Settings ViewModel）：
    - 新增 `Scopy/Observables/HistoryViewModel.swift`、`Scopy/Observables/SettingsViewModel.swift`
    - `AppState` 收敛为启动/事件分发协调器（保留兼容 API，降低一次性大改风险）
    - `AppDelegate` 在 Environment 注入 `AppState + HistoryViewModel + SettingsViewModel`
  - （可选）继续收口 Presentation（减少 View 内策略代码）：
    - 主窗口相关视图改为直接依赖 `HistoryViewModel`（search/paging/selection/actions）
    - 设置窗口改为依赖 `SettingsViewModel`（settings 读写与 stats 获取）

### Phase 6：清理与观测（收尾）

任务：

- 为 `AsyncStream` 显式指定 buffering policy（`ClipboardMonitor.contentStream`、`ClipboardService.eventStream`、`MockClipboardService.eventStream`）
- 日志统一：除热键文件日志外迁到 `os.Logger`（分类：monitor/search/db/cleanup/ui）
- 集中配置并文档化关键阈值（如 ingest/hash offload、external storage threshold）
- 严格并发/TSan 回归（至少在测试 target 打开跑一次）

验收（DoD）：

- `make test-unit`
- `make test-perf`（关键用例）
- `/tmp/scopy_hotkey.log` 自查通过

Notes：

- 已完成（2025-12-13，v0.36）：
  - `AsyncStream` 显式 buffering policy：
    - `ClipboardMonitor.contentStream`：`.bufferingNewest(8)`
    - `ClipboardService.eventStream` / `MockClipboardService.eventStream`：`.unbounded`
  - 日志统一：新增 `ScopyLog`（`os.Logger`），并将仓库内 `print(...)` 全量迁移到 `os.Logger`（保留热键文件日志 `/tmp/scopy_hotkey.log`）
  - 阈值集中：新增 `ScopyThresholds`，统一 ingest/hash offload 与 external storage 阈值
  - 验收：
    - `make test-unit` 通过（53 tests passed，1 skipped）
    - `xcodebuild test -only-testing:ScopyTests/AppStateTests -only-testing:ScopyTests/AppStateFallbackTests` 通过（46 tests passed）
    - `make test-perf` 通过（22 tests passed，6 skipped）
- 已完成（2025-12-13，v0.36.1）：
  - Thread Sanitizer 回归跑通（Hosted tests）：
    - 新增 `ScopyTestHost`（最小 AppKit host）+ `ScopyTSanTests`（Hosted unit tests）+ scheme `ScopyTSan`
    - `make test-tsan` 通过（132 tests passed，1 skipped）
    - 修复注入时崩溃：unit-test bundle 显式设置 `NSPrincipalClass = XCTestCase`，避免 “Creating more than one Application”
- 已完成（2025-12-13，v0.37）：
  - P0-6 ingest 背压确定性：引入 ingest spool（`~/Library/Caches/Scopy/ingest/`）+ 有界并发队列
  - `ClipboardMonitor.contentStream` 调整为 `.unbounded`（payload 为 file ref，不携带大 `Data`）
- 已完成（2025-12-13，v0.39）：
  - Strict Concurrency 渐进回归（先从 tests target 开始）：
    - 命令：`xcodebuild test -project Scopy.xcodeproj -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`
    - 结果：通过（无并发 warnings；`ScopyTests` 166 tests passed，7 skipped）
    - 关键修复点：UI 缓存/展示辅助 `@MainActor` 收口、HotKeyService Carbon 回调 hop 到 MainActor、tests/UI tests 的 `Sendable` 捕获修正

- 已完成（2025-12-13，v0.43）：
  - Phase 7（可选）完成落地：强制 ScopyKit module 边界（后端从 App target 移出）
  - 关键点：
    - `project.yml`：App target 排除后端目录（Domain/Application/Infrastructure/Services/Utilities 等），并让 tests targets 依赖 `ScopyKit`
    - 构建设置补齐：在 `BUILD_DIR=.build` 前提下，增加 `SWIFT_INCLUDE_PATHS`/`FRAMEWORK_SEARCH_PATHS` 指向 DerivedData `Build/Products/*`，确保 App/Test targets 可稳定 `import ScopyKit`
    - 测试代码对齐：不再引用 `RealClipboardService`/`MockClipboardService` 具体类型，改走 `ClipboardServiceFactory`

- 已完成（2025-12-13，v0.41）：
  - （可选）将 Strict Concurrency 固化为 CI/Makefile 回归门槛：
    - Makefile 新增 `make test-strict`：
      - `xcodebuild test -only-testing:ScopyTests SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`
      - 输出写入 `strict-concurrency-test.log` 便于审计

### Phase 7（可选）：抽成 Swift Package（强制边界）

目标：用编译器强制“UI 不可能 import SQLite/AppKit”，减少回归概率。

- 新增 package：`ScopyKit`（Domain + Infrastructure + Application）
- App target 仅保留 App + Presentation

Notes：

- 已完成（2025-12-13，v0.42）：
  - SwiftPM 接入：根目录 `Package.swift` 新增本地 library `ScopyKit`（源码来自 `Scopy/`，排除 App/Presentation 相关文件），并链接 `sqlite3`。
  - XcodeGen 接入：`project.yml` 增加本地 `packages`，并让 App target 依赖 `ScopyKit` product（构建/测试会看到 `Resolve Package Graph`）。
- 已完成（2025-12-13，v0.43）：
  - 强制边界：App target 只保留 App/UI/Presentation；后端由 `ScopyKit` 提供，UI 通过 `import ScopyKit` 使用协议/DTO/服务入口。
  - 构建链路：补齐 DerivedData `Build/Products/*` 搜索路径，使 `BUILD_DIR=.build` 时也能稳定 `import ScopyKit`。
  - Tests：`ScopyTests`/`ScopyTSanTests` 统一依赖 `ScopyKit`，不再将后端源码直接编进 test bundle。

---

## 10. Dev 文档（构建/测试/性能/调试）

### 10.1 构建与测试

- Debug build：`./deploy.sh` 或 `make build`
- 单测：`make test-unit`（仓库已配置）
- Thread Sanitizer：`make test-tsan`（Hosted tests，scheme `ScopyTSan`）
- Strict Concurrency：`make test-strict`（tests target，Swift 6）
- 全量测试：`make test`
- 性能测试：`make test-perf`（内部会设置 `RUN_PERF_TESTS=1`）
- 测试流程：`make test-flow`（脚本化 kill→build→install→launch→health-check）

### 10.2 运行时目录约定

- App Support：`~/Library/Application Support/Scopy/`
  - SQLite：`clipboard.db`（含 `-wal/-shm`）
  - 外部内容：`content/`
  - 缩略图：`thumbnails/`
- Ingest 临时目录：`~/Library/Caches/Scopy/ingest/`（大 payload spool；入库后会 move/copy 到 App Support）

### 10.3 热键自查

- 日志：`/tmp/scopy_hotkey.log`
- 期望：出现 `updateHotKey()`；按下只触发一次（按住不应连发）

### 10.4 性能目标（以测试为准）

- ≤5k items：搜索首屏 P95 ≤ 50ms
- 10k–100k：首屏（前 50 条）P95 ≤ 120–150ms
- Debounce：150–200ms（当前 `AppState.search()` 为 150ms）

### 10.5 并发回归建议（强烈建议每个大 Phase 做一次）

- Thread Sanitizer：跑 `make test-tsan`（`ScopyTests` 为独立 bundle 模式，直接开 TSan 可能触发 “loaded too late”）
- Strict Concurrency（建议先从测试 target 开始，避免一次性引爆）：
  - `make test-strict`（等价命令：`xcodebuild test -only-testing:ScopyTests SWIFT_STRICT_CONCURRENCY=complete SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`）

---

## 11. Codex 执行方式建议（减少返工）

每次只做一个 Phase，并强制输出：

1. 改动文件清单（新增/修改/删除）
2. 跑过的命令与结果（build/test/perf）
3. 关键 trade‑off 与已知风险（写回本文 Phase Notes）
4. 对 `doc/implemented-doc/*` 的同步更新（按 `CLAUDE.md`）

推荐给 Codex 的输入模板：

```
请按 doc/review/review-v0.3.md 的 Phase {N} 执行重构。

硬约束：
- 每个阶段必须可编译可运行
- 禁止跨模块传递 sqlite3 OpaquePointer
- 禁止新增 “@MainActor 类型 + DispatchQueue 执行核心逻辑” 的模式
- AsyncStream 必须显式 buffering policy
- 变更完成后按 CLAUDE.md 更新版本文档/README/CHANGELOG（如涉及性能/部署更新 DEPLOYMENT.md）

验收：
- make test-unit
- 需要时 make test-perf
- 热键自查：/tmp/scopy_hotkey.log 按下仅触发一次

输出：
- 文件清单 + 关键代码点
- 运行命令与结果
- 下一阶段注意事项（写入 doc/review/review-v0.3.md 对应 Phase Notes）
```
