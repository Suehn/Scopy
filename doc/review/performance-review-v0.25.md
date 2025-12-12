# Scopy 性能深度评审（v0.25）

> 目标：对照 `doc/dev-doc/v0.md` 的性能目标与当前实现（含 v0.25 全量模糊搜索），定位真实热点与成因，给出可从原理上优化的方向。  
> 范围：SwiftUI 前端、`SearchService` / `StorageService` / `RealClipboardService` / `ClipboardMonitor` 后端。  
> 分级：P0 立即影响体验；P1 规模化风险或明显影响；P2 次要/边界场景。

## 总体评价

- 关键性能基础已齐备：List 虚拟化、DTO 预计算、FTS5 两步查询+LIMIT+1、分级存储、rawData 剥离缓存、缩略图/图标 LRU、WAL 与 SQLite cache。
- v0.25 补齐了规格缺口：**Fuzzy/Fuzzy+ 全量历史模糊搜索**，语义准确且性能可扩展。
- 仍存在 2 个主线程/热路径 O(N) 问题，是当前最大性能风险（见 1.2 与 3.2 P0）。

## 1. 前端 / 渲染性能

### 1.1 已经做对的点

- `List` 替代 `LazyVStack`（v0.18）实现真正的视图回收，10k 级列表内存可控。
- `HistoryItemView` 使用 Equatable + 局部 `@State`，避免悬停/预览引发全局重绘。
- `ClipboardItemDTO` 预计算 title/metadata（v0.21），渲染期避免 O(n) 字符串操作。

### 1.2 真实热点与根因

#### [P0] 缩略图磁盘读取在 MainActor 同步发生

**位置**：`Scopy/Views/HistoryListView.swift:getCachedThumbnail`  
**现象**：`NSImage(contentsOfFile:)` 在主线程 + 锁内加载磁盘 PNG，冷滚动/快速滚动仍可能掉帧。  
**原理**：同步 I/O + 解码占用 UI 线程；锁内 I/O 延长锁持有时间，阻塞后续缩略图访问。

**优化方向**：

- 行 `onAppear` 异步预取缩略图（后台读/解码，回主线程写缓存；UI 先占位）。
- 用 `NSCache<String, NSImage>` 代替手写 LRU（线程安全 + 自动回收）。
- 进一步：存储层生成“展示级”更小缩略图，减少 UI 解码成本。

#### [P1] hover 图片/文本预览仍可能触发主线程重活

**链路**：`HistoryItemView.startPreviewTask` → `service.getImageData` → `StorageService.getOriginalImageData`  
**现象**：预览时读取原图 Data、`NSImage(data:)` 全量解码在 MainActor 上发生。  
**原理**：虽然调用在 Task 内 await，但实际 I/O/解码仍在 MainActor 上，导致 hover 时瞬时卡顿与内存峰值。

**优化方向**：

- 原图读取/下采样移到后台（ImageIO `CGImageSourceCreateThumbnailAtIndex` 限制 maxPixelSize），再回主线程赋值。
- 增加预览缓存（按 `contentHash`），避免重复解码。

#### [P1] 单体 `@Observable AppState` 仍有过度依赖风险

**现象**：高频属性（`searchQuery`、`isLoading`、`selectedID`）变化时，容易让更多视图无谓 invalidation。  
**原理**：Observation 按“访问依赖”追踪，大对象使视图更易“顺带读取”无关状态，导致重排。

**优化方向**：

- 拆分为 SearchState/ListState/StatsState 三个 `@Observable`。
- 对 handler/service 等低频属性 `@ObservationIgnored`，减少依赖面。

## 2. 搜索性能

### 2.1 已经做对的点

- Exact：FTS5 两步查询 + LIMIT+1（`SearchService.searchWithFTS`）避免 JOIN/COUNT，规模化性能最优。
- v0.25：**全量模糊索引两阶段搜索**（`SearchService.FullFuzzyIndex` + `searchInFullIndex`）  
  - 倒排字符 postings 先交集得到候选集；  
  - 对候选做严格 subsequence fuzzyMatchScore（与旧 fuzzy 语义一致，零漏召回）；  
  - Pinned→score→lastUsedAt 排序分页。
- 索引增量更新：新增/置顶/删除时通过 `RealClipboardService` 调用 `handleUpsertedItem/handlePinnedChange/handleDeletion` 更新索引，避免每次搜索重建。
- AppState 层 150ms 防抖 + 搜索版本号避免搜索风暴。

### 2.2 真实热点与根因

#### [P1] 全量模糊索引的内存与首次构建成本

**位置**：`SearchService.buildFullIndex`（首次 fuzzy/fuzzyPlus 查询惰性构建）。  
**现象**：首次全量模糊搜索会扫描全表并构建 postings；数据量极大时会有一次性 CPU/内存开销。  
**原理**：全量索引是用内存换查询速度；IndexedItem 保存 `plainText` + `plainTextLower`（重复字符串）放大内存。

**优化方向**：

- 仅保留 `plainTextLower`（或按需 lowercased 缓存），减少 1 倍文本副本。
- 对超大文本存摘要用于模糊索引（与 FTS 摘要一致）。
- 若历史 100k+ 且文本很长，可考虑 postings 用 bitset/压缩数组降低交集开销。

#### [P1] 高频字符导致候选集过大时，二次验证仍可能接近 O(N)

**现象**：query 由常见字符组成（如 “ing”、“的”）时 postings 交集仍大，fuzzyMatchScore 会在大量候选上运行。  
**原理**：字符倒排仅能过滤“不含字符”的项，对高频字符区分力弱。

**优化方向（不改变语义）**：

- 对长 query（≥3 或多词）先用 FTS 取 top‑K 候选（如 5k rowid），再在候选上 fuzzy 评分排序。
- 针对高频字符可引入 stop‑chars（仅用于候选交集，不影响最终匹配准确性）。

#### [P2] SearchService `@MainActor` + 自建后台队列的语义混用

**位置**：`SearchService` 标注 `@MainActor`，但 SQLite 与索引构建在 `queue` 中执行。  
**风险**：语义违背可能带来未来竞态或锁竞争复杂化；当前已通过 cache 快照规避一处数据竞争。  
**优化方向**：将 SearchService 改为独立 `actor`（内部串行），或移除 `@MainActor` 统一由 `queue` 管理状态。

## 3. 数据 / 内存 / 存储性能

### 3.1 已经做对的点

- 分级存储（100KB 阈值）+ 外部内容目录；WAL + cache_size + temp_store=MEMORY。
- Search recent cache 去 rawData；缩略图与 app icon LRU 上界明确。
- 清理逻辑深度优化为批量事务删除。

### 3.2 真实热点与根因

#### [P0] `performCleanup` 仍在每次新条目热路径同步执行

**位置**：`RealClipboardService.handleNewContent` → `StorageService.performCleanup`  
**现象**：每次复制都可能触发 itemCount/size 统计、incremental_vacuum、`cleanupOrphanedFiles`（全表 + 全目录扫描）。  
**原理**：高频路径内放 O(N) 维护操作，规模越大写入越慢并拖 UI。

**优化方向**：

- 维护 `lastCleanupAt`，≥30–60s 或超阈值才触发。
- `cleanupOrphanedFiles` 改为启动或低频定时任务（小时/天级）。
- vacuum 仅在大批量删除后或 idle 时执行。

#### [P1] 缩略图生成仍依赖 MainActor 的全量解码/重采样

**位置**：`RealClipboardService.handleNewContent` 新图同步 `generateThumbnail`；后台补缩略图仍 `MainActor.run`。  
**原理**：NSImage 解码/绘制/编码 CPU+内存密集，主线程执行会卡 UI。  
**优化方向**：用 ImageIO 后台 downsample 生成缩略图，完成后再通知 UI。

#### [P1] 大文本未外部化，可能导致 DB/FTS 与模糊索引膨胀

**现象**：`.text` 内容 rawData=nil 时永远内联 `plain_text`，超大文本会直接进入主表与 FTS、同时进入 full fuzzy index。  
**优化方向**：

- 对超阈值 text 外部化存储，`plain_text` 保留索引摘要（4–8k 字符）。
- 模糊索引仅用摘要，避免内存暴涨。

## 4. 优先级行动清单

- **P0**
  1. 将 `performCleanup` 从热路径节流/后台化；`cleanupOrphanedFiles` 改低频。
  2. 缩略图读取与生成离开 MainActor（UI 预取 + 后台 downsample）。
- **P1**
  1. 控制全量模糊索引内存（去重 lower 文本、摘要化长文本）。
  2. 长 query 采用 FTS 候选集 + fuzzy 二次排序，避免高频字符候选爆炸。
  3. SearchService actor 化统一并发语义。
  4. AppState 拆分降低重绘依赖面。

## 5. 建议验证方式

- 继续使用 `make benchmark` / `PerformanceProfiler`：  
  - 10k/50k/100k 历史下测 fuzzy/fuzzyPlus P95、首次构建索引耗时与内存峰值。  
  - 测新条目写入 latency（对比节流前后 cleanup）。  
- Instruments 主线程热区：File I/O、Image Decode、sqlite3_step、List diff。  

