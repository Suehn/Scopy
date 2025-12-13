
以下是基于你当前仓库源码（Scopy/ 下的 App / Protocols / Services / Observables / Views / Utilities 等我已逐文件核对；重点读了 `RealClipboardService.swift / StorageService.swift / SearchService.swift / ClipboardMonitor.swift / AppState.swift / HistoryListView.swift`，并对照了现有测试 `ScopyTests/*` 的行为期望）整理的 **终极版重构开发文档**。

文档目标是：你可以直接保存为 markdown / 文档，然后交给 Codex 按阶段执行重构；每个阶段都有明确的“做什么、为什么、怎么做、验收标准”。

---

# Scopy vNext 终极版重构开发文档

## 0. 文档范围与底线

**范围**：仅讨论当前应用内“前端=SwiftUI UI 层 / 后端=剪贴板监控+存储+搜索+设置”等一体化架构的重构与稳定性改造，不涉及产品功能大改（除非为修复稳定性/并发根因必须调整接口语义）。

**底线（Non‑negotiables）**
重构必须实现：

1. **并发模型可证明正确**：消除当前 `@MainActor` 服务 + `DispatchQueue` 绕隔离 + SQLite 同连接跨线程混用的根因风险。
2. **搜索/存储性能不回退**：至少维持现有 10k+ 历史可用体验；保留“渐进搜索 refine”的用户体验（可重做实现，但不能回退）。
3. **行为兼容**：保留现有功能集合与 UI 行为（RTF/HTML/图片/文件、多模式搜索、置顶、清理、缩略图、HotKey、过滤、hover 预览等），并让现有测试尽量小改即可通过。
4. **可维护性显著提升**：拆分巨型文件（`SearchService.swift ~1161 行`，`ClipboardMonitor.swift ~819 行`，`HistoryListView.swift ~872 行`）为可测试组件。

---

## 1. 现状快速结论（以代码为准）

### 1.1 当前运行时数据流（代码事实）

* `main.swift` → `ScopyApp`（MenuBarExtra）→ `AppDelegate.applicationDidFinishLaunching`
* `AppDelegate` 创建 `FloatingPanel`，面板根 `ContentView().environment(AppState.shared)`
* `AppState`（`@Observable @MainActor` 单例）内部按环境变量选择 `MockClipboardService` 或 `RealClipboardService`，并监听 `eventStream` 驱动 UI 更新。
* `RealClipboardService`（`@MainActor`）组合：

  * `ClipboardMonitor`：轮询 pasteboard `changeCount`，抽取类型/数据，计算 hash，向 `contentStream` 发出 `ClipboardContent`。
  * `StorageService`：SQLite + FTS5 + 分级存储（内联/外部文件）+ 缩略图目录 + cleanup。
  * `SearchService`：FTS5 + 短词缓存 + 全量 fuzzy 索引 + 渐进预筛/校准（forceFullFuzzy）。
* UI 搜索：`AppState.search()` 首屏请求 → 若 total = -1（预筛）则后台再发起 `forceFullFuzzy=true` refine 请求，覆盖首屏结果（前提：用户未 loadMore）。

### 1.2 已经很强的地方（保留并“组件化”即可）

* “协议+Mock”让 UI 与后端可分离演进。
* 搜索策略体系完整（FTS/短词 cache/full fuzzy/topK/渐进 refine）。
* 存储分级+清理策略工程化（WAL、vacuum、孤儿文件清理）。
* 对稳定性/竞态做了很多补丁（锁/取消任务/actor tracker），说明你已经在向正确方向努力。

---

## 2. 现状核心问题（根因级）

> 这里会比“表面代码不优雅”更聚焦：哪些点是你感觉“不稳定/原理没考虑全面”的真正来源。

### P0：并发与 SQLite 的“结构性风险”（必须优先处理）

#### P0-1 `@MainActor` + 手动 DispatchQueue 绕隔离（高风险）

* `SearchService` 标记为 `@MainActor`，但大量逻辑通过 `runOnQueue{}` / `runOnQueueWithTimeout{}` 扔到 `DispatchQueue(label: "com.scopy.search")`。
* 在这些 queue closure 内部，出现 **同步调用** `StorageService.fetchRecent()`、访问 `recentItemsCache/fullIndex`、甚至直接用 `sqlite3_*` 操作 `db` 指针等行为。
* 这在严格并发检查（Strict Concurrency=Complete）下属于典型隔离违规；即使当前能跑，也会产生“隐性数据竞争 + 难复现的波动”。

**结论**：你现在很多“偶发慢/偶发空结果/偶发 UI 不一致”的问题，本质上来自这类隔离破坏（不是算法本身）。

#### P0-2 SQLite 单连接跨线程/跨 executor 混用

* `StorageService.open()` 创建一个 `sqlite3* db`，同时 `SearchService.setDatabase(storage.database)` 把同一个连接交给搜索。
* 搜索在 search queue 上读、存储在 MainActor 上写，SQLite 的锁争用、busy、性能抖动、甚至偶发错误不可控。

**结论**：必须做到“连接隔离”或“单点串行化访问”。推荐：写连接（Repository actor）+ 读连接（Search actor）分离。

#### P0-3 搜索“超时/取消”语义不可靠

* `runOnQueueWithTimeout` 通过 TaskGroup 抛 timeout，但底层 `DispatchQueue.async` 的 work **不会被取消**，仍会继续运行并可能修改缓存/索引。
* 这会导致“超时返回了，但 CPU 还在跑，甚至改变内存状态”的非确定性。

---

### P1：耦合与可维护性风险（中期会持续拖慢你）

#### P1-1 领域模型与 UI 表现耦合

* `ClipboardItemDTO` 在协议层直接预计算 `cachedTitle/cachedMetadata`，这是 presentation concern。
* 结果是：后端/协议被 UI 展示格式绑死；以后 UI 改标题策略，会引发协议层变动。

#### P1-2 Settings 多源写入

* `AppDelegate` 与 `RealClipboardService` 都用 `"ScopySettings"` 直接读写 UserDefaults，且靠事件“间接同步”。
* 这是隐式耦合：热键与其他设置的状态一致性靠运气而不是机制。

#### P1-3 缓存体系分散且重复

* 图标：`IconCache actor` + `IconCacheSync` + 部分 View 内自建静态缓存。
* 缩略图：磁盘目录 + View 内 NSCache + `ThumbnailGenerationTracker`。
* 缓存策略分散导致调优困难、容易引入重复加载或缓存不一致。

#### P1-4 文件 I/O 仍可能落在主线程热路径

* 例如 `StorageService.deleteItem` 删除外部文件是同步 FileManager 调用（虽不一定频繁，但属于边界卡顿点）。

---

### P2：清洁度与一致性问题（可顺带解决）

* `RealClipboardService.db` 永远返回 nil（死字段）。
* `IconCache.getCached` 永远返回 nil（死接口）。
* `SearchService.fuzzyPlusMatch` 在当前实现中**定义但未被使用**（可移除或真正整合）。
* README 声称“inline < 50KB”，但 `StorageService.externalStorageThreshold = 100KB`（应统一并集中配置）。

---

## 3. vNext 重构目标：明确需求（Functional / Non-functional）

### 3.1 功能需求（必须保留）

1. 监控剪贴板并记录：text/rtf/html/image/file/other
2. 去重：以内容 hash 为主键，重复复制更新 `useCount/lastUsedAt`
3. 置顶/取消置顶
4. 删除、清空（保留 pinned）
5. 复制回系统剪贴板：对每种类型写入正确 pasteboard 类型（file URLs、rtf/html/png/text）
6. 搜索：

   * exact（FTS）
   * fuzzy（字符序列匹配打分）
   * fuzzyPlus（分词 + 额外约束：ASCII 长词要求连续子串，避免路径噪音弱相关；现有测试依赖这一点）
   * regex
   * appFilter、typeFilter、typeFilters
   * 分页、hasMore
   * 渐进 refine（首屏可快、后台校准）
7. 缩略图与 hover 预览（配置：开关/高度/延迟）
8. HotKey（默认 ⇧⌘C，可配置）
9. 存储统计（db / 外部 / thumbnails / total）

### 3.2 非功能需求（本次重构的“主要交付”）

1. **并发正确性**：开启 Strict Concurrency（或至少在 CI/测试 target 开启）后无关键违规
2. **SQLite 访问模型正确**：不再共享同一连接跨线程；读写隔离或串行化
3. **取消/超时可预测**：搜索超时不会继续偷偷跑并改内存状态
4. **UI 不卡顿**：I/O、hash、缩略图、清理都不阻塞主线程
5. **可维护性**：核心服务拆分组件；单文件目标 < 300 行（除算法文件可允许更大但必须拆 module）
6. **可测试性**：Domain / Infra 有明确边界，可用 in-memory shared SQLite 做单测

---

## 4. vNext 目标架构（最终形态）

> 关键思想：把“前后端分离”从“逻辑上写在一个文件里”变成“在代码结构与并发模型上强制成立”。

### 4.1 分层与边界

* **Presentation（前端）**：SwiftUI Views + ViewModels（MainActor）
* **Application（用例层）**：`ClipboardService`（actor），聚合 monitor/repository/search/settings，向 UI 暴露稳定 API
* **Domain（领域层）**：纯 `Sendable` 模型与协议（不 import AppKit/SQLite）
* **Infrastructure（基础设施层）**：SQLite、文件系统、pasteboard、hotkey、icon/thumbnail cache 等实现

### 4.2 并发模型（最终必须写入 dev doc，并落实到代码）

1. UI/ViewModel：`@MainActor`
2. AppKit 边界（pasteboard 读写、NSWorkspace、hotkey 注册）：`@MainActor`
3. 存储：`actor SQLiteClipboardRepository`（单写连接，串行写/清理/文件引用管理）
4. 搜索：`actor SearchEngineImpl`（独立**只读连接** + 内存索引；与写连接分离）
5. 设置：`actor SettingsStore`（统一 UserDefaults 入口，提供 settingsStream）
6. 事件流：由 `ClipboardService` actor 持有 continuation，不再需要 NSLock 保护（actor 自带串行保证）

---

## 5. vNext 目录结构与文件规划（可直接作为重构目标）

当前项目已有 `Scopy/Design, Extensions, Observables, Protocols, Services, Utilities, Views`。建议升级为更清晰的“分层目录”，并逐步迁移。

### 5.1 推荐结构（单 target 先落地，后续可抽 Swift Package）

```
Scopy/
  App/
    main.swift
    ScopyApp.swift
    AppDelegate.swift
    FloatingPanel.swift
    AppEnvironment.swift            // 组装 DI（service/repo/search/settings）
    HotKeyCoordinator.swift         // App 层协调 hotkey 与 settings

  Domain/
    Models/
      ClipboardItem.swift
      ClipboardItemSummary.swift
      ClipboardItemType.swift
      SearchMode.swift
      SearchRequest.swift
      SearchResultPage.swift
      Settings.swift
      StorageStats.swift
      ClipboardEvent.swift
    Protocols/
      ClipboardServiceProtocol.swift        // UI-facing
      ClipboardRepository.swift             // 存储仓库
      SearchEngine.swift                    // 搜索引擎
      ClipboardMonitorProtocol.swift        // 监控接口
      PasteboardClient.swift                // 读写剪贴板（AppKit 边界）
      SettingsStoreProtocol.swift
      HotKeyManagerProtocol.swift

  Infrastructure/
    Clipboard/
      PasteboardMonitor.swift               // 轮询 changeCount + 产生 snapshot
      ClipboardReader.swift                 // 提取类型与 Data（不做 DB）
      ContentHasher.swift                   // SHA256（可选 CryptoKit）
      ClipboardMonitorAdapter.swift         // 将 reader+hasher 组合成 monitor protocol
      PasteboardClientImpl.swift            // copy/write，实现 PasteboardClient

    Persistence/
      SQLiteConnection.swift                // sqlite3* 封装 + statement helper
      SQLiteMigrations.swift                // schema + migration runner（PRAGMA user_version）
      SQLitePaths.swift                     // AppSupport 路径、content/thumbnails 目录
      FileStore.swift                       // 外部文件原子写/读/删
      ThumbnailStore.swift                  // 缩略图目录管理
      SQLiteClipboardRepository.swift       // actor，实现 ClipboardRepository

    Search/
      SearchEngineImpl.swift                // actor，组合以下组件
      FTSQueryEngine.swift                  // FTS 查询 + LIMIT+1
      FullFuzzyIndex.swift                  // postings/slot/idToSlot（纯结构）
      FuzzyScorer.swift                     // fuzzyMatchScore
      CandidatePrefilter.swift              // 渐进预筛策略（ASCII/FTS）
      TopKSelector.swift                    // BinaryHeap/partial sort
      SearchCache.swift                     // 短词缓存（内存 + TTL）

    Settings/
      SettingsStore.swift                   // actor，实现 SettingsStoreProtocol

    HotKey/
      HotKeyService.swift                   // AppKit/Carbon 边界实现

    Caching/
      IconService.swift                     // 单一图标/名称缓存入口
      ThumbnailCache.swift                  // 内存缓存（NSCache）+ 生成协调器
      ThumbnailGenerationTracker.swift      // 如保留，可放此处

  Presentation/
    ViewModels/
      AppState.swift                        // 或拆为 HistoryVM/SettingsVM
      HistoryViewModel.swift
      SettingsViewModel.swift
    Views/
      ContentView.swift
      HeaderView.swift
      HistoryListView.swift
      HistoryItemView.swift
      FooterView.swift
      SettingsView.swift
    Design/
      ...

  Utilities/
    NSLock+Extensions.swift                 // 逐步移除（actor 化后应减少）
    PerformanceMetrics.swift
    PerformanceProfiler.swift
    AppVersion.swift
```

### 5.2 强制依赖方向

* Presentation 只能依赖 Domain + Application（ClipboardServiceProtocol）
* Infrastructure 依赖 Domain
* Domain 不依赖任何其他层

---

## 6. vNext 后端 API 规格（“前后端接口”最终定稿）

> 这是 Codex 重构时最关键的“边界契约”。先定协议，后改实现。

### 6.1 Domain 模型（建议）

#### ClipboardItemType / SearchMode

沿用现有枚举即可（保持 rawValue 兼容 DB）。

#### ClipboardItemSummary（用于列表/搜索结果）

* 必须 `Sendable`
* **不包含**大字段 rawData（避免把 Data 带进 UI 热路径）

字段建议：

* id: UUID
* type: ClipboardItemType
* contentHash: String
* plainText: String
* appBundleID: String?
* createdAt: Date
* lastUsedAt: Date
* useCount: Int
* isPinned: Bool
* sizeBytes: Int
* storageRef: String? (外部文件路径，仅后端用；UI 可用它判断“可预览”但不直接读)

#### ClipboardItem（用于 copy/preview）

等同 summary + `payloadRef`（或 `rawData`）。

建议用显式 payload 结构，避免“image/file 都叫 getOriginalImageData”这类命名错位：

```swift
enum ClipboardPayloadRef: Sendable {
  case inline(Data)
  case external(path: String)
  case none
}
```

#### Settings

把现有 SettingsDTO 迁为 Domain.Settings（可 Codable），并由 SettingsStore 负责持久化。

#### ClipboardEvent（语义纯化）

建议将现有 `.settingsChanged` 拆分，不再复用“设置变更”表示“清空历史”。

```swift
enum ClipboardEvent: Sendable {
  case itemInserted(ClipboardItemSummary)
  case itemUpdated(ClipboardItemSummary)      // 使用统计变化、置顶变化等
  case itemDeleted(UUID)
  case itemsCleared(keepPinned: Bool)
  case settingsChanged(Settings)
}
```

### 6.2 UI-facing 服务协议（最终）

建议从 `@MainActor protocol ClipboardServiceProtocol` **移除 `@MainActor`**，让服务可以是 actor（后台），UI 用 `await` 调用即可。
AppKit 相关操作由 service 内部在 MainActor 边界完成。

```swift
protocol ClipboardServiceProtocol: AnyObject, Sendable {
  func start() async throws
  func stop() async

  func fetchRecent(limit: Int, offset: Int) async throws -> [ClipboardItemSummary]
  func search(_ request: SearchRequest) async throws -> SearchResultPage

  func pin(id: UUID) async throws
  func unpin(id: UUID) async throws
  func delete(id: UUID) async throws
  func clearAll(keepPinned: Bool) async throws

  func copyToPasteboard(id: UUID) async throws
  func loadPreviewData(id: UUID) async throws -> Data?      // 图片预览
  func getRecentApps(limit: Int) async throws -> [String]

  func getSettings() async throws -> Settings
  func updateSettings(_ settings: Settings) async throws

  func getStorageStats() async throws -> StorageStats

  var events: AsyncStream<ClipboardEvent> { get }
}
```

> 兼容策略：你可以先保留旧 DTO 协议作为“兼容层”，内部用 adapter 映射到新 Domain 类型；最后再删除旧 DTO。

---

## 7. 关键原理改进（“为什么这样设计会更稳定/更快”）

### 7.1 SQLite 连接隔离：写连接与读连接分离

* 写：Repository actor 串行执行（不会出现“写锁把读锁卡死 + UI 卡顿”）
* 读：Search actor 用独立只读连接，配合 WAL，读取不会被写长时间阻塞
* 这比“一个连接靠 SQLite 自己 serialized”更稳定：你不再依赖 SQLite 内部调度，而是依赖你可控的 actor 串行

### 7.2 消灭“绕过 actor 隔离”的 DispatchQueue 模式

* 现状 `SearchService.runOnQueue` 最大问题不是“用了 GCD”，而是：

  * 在 GCD closure 里同步调用 MainActor 隔离对象（StorageService）
  * GCD work 不可取消，超时只是“放弃等待”，并不会停下
* 改造后：

  * Search actor 内运行纯 Swift 计算（可插入 cancellation checks）
  * DB 读取用 search actor 的 read connection（不再调用 StorageService）

### 7.3 事件流的线程安全由 actor 保证

* 现在的 `NSLock + isEventStreamFinished` 本质是因为你让多个线程竞争 yield/finish。
* 让 `ClipboardService` 成为 actor 并持有 continuation 后：

  * yield/finish 都在同一 actor 串行执行
  * stop 时把 continuation 置 nil 并 finish，一步到位

### 7.4 SettingsStore 单写入源（SSOT）

* 热键与后端设置必须来自同一个 settings stream
* `AppDelegate` 不再“自己读写 UserDefaults”，而是：

  * 启动时 `SettingsStore.load()`
  * 订阅 `settingsStream`，在变更时 re-register hotkey
* 后端 service 更新 settings 时只调用 `SettingsStore.save()`

---

## 8. 后端实现规格（可按模块逐个重写）

### 8.1 ClipboardMonitor（读取与 hash 的职责切分）

**目标**：Monitor 只负责“检测 pasteboard 变化 + 抽取内容 + 产出结构化事件”，hash/图片转换等重计算可独立组件化，且可测试。

建议拆为：

1. `ClipboardReader`（MainActor）：

   * `read(from pasteboard) -> RawClipboardSnapshot?`
   * 仅做类型识别与 Data 抽取
   * 保留你当前的类型优先级：File URLs > Image > RTF > HTML > Text

2. `ContentHasher`（非 MainActor）：

   * `hash(data: Data) -> String`
   * 可选用 CryptoKit SHA256（若你之前确有 import 问题，可保留当前自实现作为 fallback）
   * 必须加单测：随机数据与参考实现 hash 一致（防止自实现出 bug）

3. `PasteboardMonitor`（MainActor）：

   * Timer/DispatchSourceTimer 轮询 changeCount
   * 对大内容：读 snapshot 后将 hash 计算 offload（Task.detached），再回主线程 yield
   * AsyncStream 使用 `bufferingNewest(N)`（建议 N=200），避免极端情况下无限积压

**关键行为规范（写入 dev doc）**

* 允许最多并发处理任务（现在是 3），但不要“无声丢弃”。如果需要丢弃，必须：

  * 明确日志/metric
  * 只丢弃“旧的未处理任务”（保留最新），并在文档写明“极端快速复制大内容可能跳过部分历史”
    （如果你希望“绝不丢”，则要引入磁盘 spool 或更复杂的背压策略；可作为 vNext+1）

### 8.2 Repository（SQLiteClipboardRepository actor）

**职责**：DB 真相源 + 外部文件/缩略图目录管理 + 清理策略落地。

必须具备：

* `open()`：设置 WAL、cache、temp_store、busy_timeout；运行 migration
* `upsert(snapshot)`：

  * 先查 hash 去重 → 更新 useCount/lastUsedAt
  * 不存在则插入：决定 inline vs external
  * external 写入必须原子，且 **DB insert 失败要回滚删除文件**（减少孤儿）
* `fetchRecent(limit, offset)`：只返回 summary（不带 rawData）
* `findByID`：按需返回 payload（copy/preview 使用）
* `delete(id)` / `clearAll(keepPinned)`：同时清理外部文件、缩略图
* `cleanup(mode)`：light/full 分层（你现有策略可迁移，但要放到 actor 内）

**SQLite schema / migration（强制）**
你现在有 `schema_version` 表但没实际 migration runner。vNext 要求：

* 使用 `PRAGMA user_version` 维护 schema version（推荐）
* migration steps 以 `switch oldVersion { case 0: ...; case 1: ... }` 方式执行
* 建议把建表/建索引/FTS/triggers 放在 migration 里可复用

> 兼容：保持现有表结构不变，先把 migration runner 写出来，即使版本只有 1 也要有框架。

**测试要求**

* 用 shared in-memory SQLite：`file:scopy_test?mode=memory&cache=shared` + `SQLITE_OPEN_URI`
* 保证 Repository 与 SearchEngine 可同时打开各自连接用于测试。

### 8.3 SearchEngine（actor + 只读连接）

**目标**：保留你现在的算法优势，但把实现拆分成可维护组件，同时消除 GCD 绕隔离与不可取消问题。

#### 8.3.1 组件拆分建议（沿用你现有思路）

* `FTSQueryEngine`：负责 exact/FTS 的 SQL、escape、绑定参数、LIMIT+1
* `SearchCache`：短词缓存（现在 `recentItemsCache + TTL + size`）
* `FullFuzzyIndex`：items/slot/idToSlot/charPostings（纯结构体/类，只在 actor 内访问，无锁）
* `FuzzyScorer`：当前 `fuzzyMatchScore` 的实现（带 ASCII 连续子串快路径、短词 <=2 连续语义）
* `CandidatePrefilter`：你现在的“ASCII 单词 + 可选 FTS 加速预筛”
* `TopKSelector`：BinaryHeap 或 partial sort（独立出来便于测试与调优）

#### 8.3.2 渐进搜索（progressive refine）的最终规范

保持你现有 UI 逻辑（total = -1 表示未知，后台 refine），但使其更可证明：

* SearchEngine.search(request):

  * 若 `forceFullFuzzy=false` 且满足预筛条件：

    * 返回首屏（limit）
    * `total = -1`（或另加字段 `isTotalAccurate=false`）
  * 若 `forceFullFuzzy=true`：

    * 走全量 fuzzy，返回更准确的 total/hasMore
* 必须保证：同一个 request（forceFullFuzzy=true）在相同 DB 快照下是确定性的（不依赖 cache 的竞态）。

#### 8.3.3 取消与超时（必须可预测）

* 禁止再用 `DispatchQueue.async` 执行核心搜索逻辑
* 采用 actor 内同步执行 + 在长循环内 `Task.checkCancellation()`：

  * 构建候选集循环
  * 计算 score 循环
  * heap 维护循环

对于“真 DB 慢查询”：

* 可选增强：为 read connection 设置 `sqlite3_progress_handler` 或在任务取消时 `sqlite3_interrupt(db)`（可作为 vNext+1；本次先把算法计算取消做对，通常就足够）

---

## 9. Presentation/UI 重构原则（不追求花活，只追求边界清晰）

### 9.1 AppState 的最终职责

* UI 状态：items、selection、filters、loading、pagination、面板开关回调、性能摘要展示
* **不再**承担：

  * settings 的持久化细节
  * icon/thumbnail 多套缓存策略
  * DB/SQLite 细节

建议拆分：

* `HistoryViewModel`：列表/搜索/分页/selection
* `SettingsViewModel`：设置读写、存储统计
* AppState 作为组合容器（或直接取消单例，改 AppEnvironment 注入）

### 9.2 缓存收口（强制）

* 图标：只保留一个入口（建议 `IconService`，内部 NSCache 或 LRU），移除 `IconCacheSync` 与 View 静态缓存重复
* 缩略图：只保留一个 `ThumbnailCache`（内存 NSCache）+ `ThumbnailStore`（磁盘）+ `ThumbnailGenerationCoordinator`
* View 内只做：

  * 请求：`thumbnailProvider.thumbnail(for: itemID/contentHash)`
  * 渲染：拿到 Data/NSImage 后展示
  * 不自己管理“全局缓存策略”

---

## 10. 分阶段重构路线图（Codex 可直接按阶段做）

> 重点：每个 Phase 都要求“可编译、测试通过、行为不变”，避免一把梭导致失控。

### Phase 0：建立新分层骨架（不改行为）

**目标**：先把目录与类型归位，保持旧实现仍能跑。

任务清单：

1. 新建 `Domain/Models` 与 `Domain/Protocols`，把 `SearchMode/ClipboardItemType/SearchRequest/SearchResultPage/SettingsDTO/StorageStatsDTO/ClipboardEvent` 拆出为 Domain 版本（先保留原命名也行）。
2. 旧 `ClipboardServiceProtocol.swift` 变为“兼容层”：

   * 继续暴露旧 DTO，但内部 typealias 到 Domain 或做映射（过渡用）。
3. 新建 `App/AppEnvironment.swift`（哪怕只返回 `AppState.shared`），为后续 DI 做入口。

验收：

* `make test` 全过
* App 可运行

---

### Phase 1：Settings 单一真相源（SSOT）

**目标**：消灭 AppDelegate/RealClipboardService 双写 UserDefaults。

任务清单：

1. 新建 `Infrastructure/Settings/SettingsStore.swift`（actor）：

   * `load()`, `save(Settings)`, `settingsStream`
2. 修改：

   * `RealClipboardService.getSettings/updateSettings` → 调用 SettingsStore
   * `AppDelegate` 热键读写 → 也调用 SettingsStore（或由 HotKeyCoordinator 订阅 settingsStream）
3. ClipboardEvent 调整：

   * `settingsChanged(Settings)`（带 payload）
4. UI SettingsView 改为：只通过 service 的 get/update settings（service 内部再调用 store）

验收：

* 热键设置保存/重启后恢复一致
* `ScopyTests/HotKeyServiceTests` 通过（可能需要小改注入）

---

### Phase 2：StorageService → SQLiteClipboardRepository actor（写连接收口）

**目标**：DB 写与文件管理进 actor，清理掉 MainActor + 外部锁的混杂。

任务清单：

1. 新建 `Infrastructure/Persistence/SQLiteClipboardRepository.swift`（actor）：

   * 迁移 `open/close/schema/createIndexes/FTS/triggers/CRUD/cleanup/externalStore/thumbnailStore`
2. 新建 `SQLiteConnection.swift`：封装 prepare/bind/step/finalize，集中 SQLITE_TRANSIENT、safeColumnText 等工具
3. `StorageService` 先保留为薄 wrapper（deprecated），内部转调 repository（或直接替换 RealClipboardService 使用 repository）
4. 处理测试：

   * 用 shared in-memory URI 让 repo 与 search engine 可同时打开（为 Phase 3 准备）

验收：

* `StorageServiceTests` 迁移后仍通过（或改为 `SQLiteClipboardRepositoryTests`）
* 清理/孤儿文件清理逻辑跑通

---

### Phase 3：SearchService → SearchEngineImpl actor（读连接分离 + 去 GCD）

**目标**：彻底移除 `runOnQueue/runOnQueueWithTimeout`；Search 不再调用 StorageService；Search 自持 read connection。

任务清单：

1. 新建 `SearchEngineImpl.swift`（actor）：

   * `openReadConnection(path)`
   * `search(request) -> SearchResultPage`
   * `handleUpsert/handlePinnedChange/handleDeletion/handleClearAll`（索引更新）
2. 拆出组件：FTSQueryEngine / FullFuzzyIndex / FuzzyScorer / SearchCache / TopKSelector
3. 搜索取消：长循环内加入 cancellation checks
4. 删除/修正死代码：

   * 移除未使用的 `fuzzyPlusMatch` 或把它整合为 fuzzyPlus 的 token 过滤逻辑（推荐：删除并由 scorer+tokenize 统一实现）
5. 更新测试：

   * `SearchServiceTests` 改为针对 SearchEngineImpl（或保留 SearchService 外观层转调新实现）

验收：

* `SearchServiceTests`、`ConcurrencyTests`、`PerformanceTests` 通过
* 开启严格并发检查时不再出现“MainActor 方法在非隔离上下文调用”类问题

---

### Phase 4：RealClipboardService → ClipboardService actor（用例层定型）

**目标**：形成唯一对 UI 暴露的后端门面（actor），事件语义纯化，删除旧 service 竞态锁。

任务清单：

1. 新建 `Application/ClipboardService.swift`（actor）实现 `ClipboardServiceProtocol`：

   * 持有 monitor/repo/search/settingsStore/pasteboardClient
   * start：依次 open repo → open search → start monitor → consume stream → upsert → update index → emit events
2. 事件语义修复：

   * `clearAll()` 发 `.itemsCleared(keepPinned: true)`（或 `.itemsCleared(keepPinned: Bool)`），不再复用 settingsChanged
3. `copyToClipboard` 重构为 `copyToPasteboard`：

   * repo 提供 `loadPayload(id)`，按 type 返回正确 Data/URLs
   * pasteboardClient 在 MainActor 写入
   * 更新 usage stats + 发 `.itemUpdated(summary)`
4. 删除 `RealClipboardService` 或保留为 deprecated adapter（短期过渡）

验收：

* UI 功能不回退
* stop/start 不再需要 NSLock 保护 continuation（actor 内保证）
* 清空历史不再触发 settingsChanged 的“语义混淆兜底”

---

### Phase 5：Presentation 收口（缓存、ViewModel、巨型 View 拆分）

**目标**：提升可维护性，减少 View 内状态与缓存重复。

任务清单：

1. 引入 `IconService` / `ThumbnailCache` 单一入口
2. `HistoryListView.swift` 拆为：

   * HistoryListView（列表框架）
   * HistoryRowView（单行）
   * ThumbnailView（缩略图）
   * HoverPreview（预览）
3. AppState 拆分（可选但建议）：

   * `HistoryViewModel`：搜索/分页/selection
   * `SettingsViewModel`：设置与统计
4. 清理 `IconCache.getCached`、移除 View 内静态 LRU 等重复逻辑

验收：

* UI 行为一致
* 内存稳定（长时间运行不增长）
* 图片 hover/缩略图加载不阻塞主线程

---

### Phase 6（可选，长期收益很大）：抽成 Swift Package（强制边界）

**目标**：用编译器强制“Domain/Infra 不被 UI 反向污染”。

* 新增 package target：`ScopyKit`（library）
* Scopy（executable）仅包含 App+Presentation
* tests 更容易只测 ScopyKit

---

## 11. 工程规范与验收标准（最终 DoD）

### 11.1 并发与编译设置（建议写进 CI / Makefile）

* Xcode / SwiftPM：开启严格并发警告（至少测试 target）
* 禁止在 `@MainActor` 隔离对象中用 GCD 绕开隔离访问自身/其他 MainActor 对象
* 非 Sendable 类型（NSImage/NSAttributedString/NSPasteboard/NSWorkspace/NSPanel）禁止进入 Domain

### 11.2 性能指标（建议沿用 README 的口径，但以测试为准）

* 搜索首屏 P95：

  * ≤ 5k：≤ 50ms
  * 10k：≤ 150ms（你现在通常更快）
* copy 热路径：主线程阻塞 ≤ 3ms（hash/文件写入/缩略图生成都后台）
* 10k items 内存：< 100MB（你 README 目标是 ~50MB，保持即可）

### 11.3 数据一致性

* external 文件写入与 DB insert 必须“失败回滚删除文件”
* clearAll/删除后不会残留明显 orphan（full cleanup 能清理历史遗留）

---

## 12. 给 Codex 的执行说明（务必按这个节奏）

1. **严格分阶段**：每个 Phase 一个 PR/commit 范围
2. 每次变更后必须跑：

   * `make test`（或 swift test）
   * 至少 `SearchServiceTests`、`StorageServiceTests`、`ConcurrencyTests`
3. “先建新代码，再替换旧引用”：

   * 先新增新模块/actor
   * 再在旧服务里做 adapter
   * 最后删除旧实现
4. 每个阶段完成后，整理一次 dead code 清单并删除（避免“兼容层”无限堆积）

---

## 13. 你现在最优先的三件事（如果只能做最少改动）

如果你希望最快把“稳定性/性能波动”的根因掐掉，优先级是：

1. **SearchService 去 `DispatchQueue`，改为 actor + 自持 read connection**（解决 P0-1/P0-2/P0-3 的 80%）
2. **StorageService 改为 repository actor（写连接收口）**（解决 DB 访问不可控与主线程 I/O）
3. **SettingsStore SSOT**（避免设置/热键一致性靠事件兜底）

---

如果你希望我再加一层“Codex 可直接照抄的重构指令格式”（例如每个 Phase 细化到“新增哪些文件、每个文件有哪些 public API、旧文件如何改成 wrapper、哪些测试需要改哪几行”），我也可以在同一条消息里把 Phase 0~5 拆成更“脚本化”的操作清单。
