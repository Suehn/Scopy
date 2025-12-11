# Scopy 性能深度评审（v0.23）

> 目标：根据 `doc/dev-doc/v0.md` 的性能目标与当前实现，定位真实性能瓶颈（UI、搜索、存储/内存），给出可从原理上优化的方向。  
> 范围：SwiftUI 前端、`SearchService` / `StorageService` / `RealClipboardService` / `ClipboardMonitor` 后端。  
> 结论分级：P0 立即影响体验；P1 明显影响或规模化风险；P2 次要或在极端规模下。

## 总体评价

- 已实现的关键优化：List 真正虚拟化、DTO 预计算 metadata、FTS5 两步查询 + LIMIT+1、rawData 剥离缓存、缩略图 LRU、WAL + `cache_size`。
- 当前仍有两个“热路径 O(N)”问题 + 多处主线程 I/O/解码，是现阶段主要性能风险。

## 1. 前端 / 渲染性能

### 1.1 已经做对的点

- List 替代 LazyVStack（v0.18）解决视图不回收导致的内存膨胀。
- `HistoryItemView` 采用 Equatable + 局部 `@State` 悬停/预览，减少全局重绘。
- 元数据预计算（v0.21）避免字符串 O(n) 在渲染期重复执行。

### 1.2 真实热点与根因

#### [P0] 缩略图磁盘读取在 MainActor 同步发生

**位置**：`Scopy/Views/HistoryListView.swift:502`（`getCachedThumbnail`）  
**现象**：首次滚动到新缩略图时，`NSImage(contentsOfFile:)`（同文件:515）在主线程+锁内执行。即使有 LRU，冷启动/快速滚动仍可能出现卡顿。  
**原理**：UI 线程被同步 I/O + 解码占用，导致帧率下降；锁内 I/O 延长锁持有时间，影响后续缩略图访问。

**优化方向**：

- 在行 `onAppear` 中异步预取缩略图：后台读取/解码，回主线程写入缓存；UI 先显示占位。
- 用 `NSCache<String, NSImage>` 替代手写 LRU：线程安全、自动内存回收、避免双数组维护开销。
- 若追求极致：存储层生成更小的“展示级”缩略图，避免 UI 再解码大 PNG。

#### [P1] 图片 hover 预览可能阻塞主线程

**位置链路**：

- `Scopy/Views/HistoryListView.swift:589`（`startPreviewTask`）调用 `getImageData`
- `Scopy/Services/RealClipboardService.swift:303` → `Scopy/Services/StorageService.swift:1367`（`getOriginalImageData`）

**现象**：hover 时读取原图 Data，再在 `imagePreviewView` 中 `NSImage(data:)`（`HistoryListView.swift:560`附近）解码。`StorageService` / `RealClipboardService` 都在 `@MainActor`，外部文件读取是同步的。  
**原理**：虽然在 Task 中 await，但实际 I/O/解码仍在 MainActor 上执行，导致 hover 或滚动瞬间掉帧；大图会造成瞬时内存峰值。

**优化方向**：

- 把原图读取/下采样移到后台：`Task.detached { read+downsample }`，回主线程赋值。
- 用 ImageIO 下采样（`CGImageSourceCreateThumbnailAtIndex`）替代 `NSImage(data:)` 全量解码；限制 `maxPixelSize`。
- 增加预览缓存（按 `contentHash`），命中直接显示。

#### [P1] 单体 @Observable AppState 体量大，搜索输入仍触发较多 view invalidation

**位置**：`Scopy/Observables/AppState.swift`（单一 `@Observable` 包含 20+ 属性）  
**现象**：搜索框输入（`searchQuery`）会使 `HistoryListView` 重新计算 body，Pinned 区域显示逻辑也依赖 `searchQuery`（`HistoryListView.swift` 顶部条件），List diff 频繁。  
**原理**：Observation 是按属性追踪，但大对象容易让视图“顺带读取”更多属性，引入不必要依赖；高频属性变化导致重排。

**优化方向**：

- 拆分状态：SearchState / ListState / StatsState 三个 `@Observable`，分别注入需要的视图。
- 对低频属性使用 `@ObservationIgnored`（如 handler、service 引用），避免引入依赖。
- 对 List 部分进一步用局部 `@State`/绑定缓存高频值。

## 2. 搜索性能

### 2.1 已经做对的点

- FTS5 两步查询 + LIMIT+1（`Scopy/Services/SearchService.swift:168` 起）显著降低 JOIN/COUNT 成本。
- 短词/模糊搜索走最近缓存（2000 条）避免全表扫描。
- AppState 层 150ms 防抖 + 版本号（`AppState.swift:498`）避免搜索风暴。

### 2.2 真实热点与根因

#### [P1] Fuzzy / Fuzzy+ 仅在最近 2000 条上 O(k log k) 扫描

**位置**：`Scopy/Services/SearchService.swift:122`、`:153` → `searchInCache`  
**现象**：模糊搜索不会命中更早历史；对 2000 条每次 filter+sort，当前规模 OK，但默认模式 fuzzyPlus 让多数搜索都走这条路径。  
**原理**：这是“用扫描换准确模糊匹配”的权衡；规模到 50k 时仍然只扫 2000，并且 fuzzyPlus 多词会增加每条匹配成本。

**优化方向（兼顾正确性+性能）**：

- **混合候选集**：先用 FTS/LIKE 获取较小候选（如 top 5k rowid），再对候选做 fuzzy/fuzzyPlus 排序过滤。
- **按 query 长度切换策略**：≥3 字符或含空格时走 FTS 候选；短词仍用最近缓存。
- 若目标是“真正全量模糊搜索”，可考虑追加 trigram/edge-ngram 索引表，或引入 sqlite 自定义函数做 fuzzy 并在 SQL 内排序。

#### [P2] Exact FTS 始终 `ORDER BY bm25` 可能对超常见词产生额外代价

**位置**：`Scopy/Services/SearchService.swift:180`  
**原理**：`bm25` 排序需要维护 top‑K 堆；对极高频词仍可能遍历大量 posting。短词已走缓存，但“长且高频”的词仍会触发。  
**优化方向**：

- 对“极常见词”或候选过多时退化到按 `last_used_at` 排序，或加入 stopwords。
- 仅对多词/长词启用 `bm25`。

#### [P2] SearchService 标记 @MainActor 但内部用 DispatchQueue + NSLock

**位置**：`Scopy/Services/SearchService.swift:6` + `runOnQueue*` 系列  
**原理**：后台队列读写主 actor 隔离状态是语义违背，未来可能导致 race、锁竞争上升和不可预测延迟。  
**优化方向**：

- 把 SearchService 改成独立 `actor`，所有状态和 SQLite 操作都在 actor 内串行执行；UI 调用只 await。
- 或取消 @MainActor，并用单一 serial queue 管理内部状态。

## 3. 数据 / 内存 / 存储性能

### 3.1 已经做对的点

- 分级存储：图片/大内容外部化，主库 WAL + `cache_size`、`temp_store=MEMORY`。
- Search 最近缓存剥离 rawData，缩略图和 app icon LRU，显著控制内存。
- 清理逻辑深度优化为批量事务删除。

### 3.2 真实热点与根因

#### [P0] performCleanup 每次新条目都同步跑全套清理（含 O(N) 扫描）

**位置链路**：

- `Scopy/Services/RealClipboardService.swift:336-339` 调用
- `Scopy/Services/StorageService.swift:734`（`performCleanup`）

**现象**：每次复制新内容都会执行 `getItemCount`、可能的 size 统计、`PRAGMA incremental_vacuum`（`StorageService.swift:763`）以及 `cleanupOrphanedFiles`（`StorageService.swift:766`）。
其中 `cleanupOrphanedFiles` 先全表扫描 `storage_ref`（`StorageService.swift:776-792`）再枚举外部目录（`StorageService.swift:794-808`），是典型 O(N) 热路径。  
**原理**：复制事件是高频路径，把一致性/维护型工作放这里会直接拖慢写入和 UI 响应，规模越大越明显。

**优化方向**：

- **节流 / 分离**：
  - 维护 `lastCleanupAt`，只在间隔 ≥30–60s 或超阈值时触发。
  - `cleanupOrphanedFiles` 移到启动或低频定时（如每小时/每天），不在热路径执行。
- **外部大小增量维护**：避免 invalidate 后每次 `getExternalStorageSize()` 重新遍历目录。
- **vacuum 策略调整**：incremental_vacuum 仅在大量删除后或 idle 时运行。

预期收益：大历史 + 多外部文件场景下，新条目写入延迟从“随 N 增长”降到稳定常数级。

#### [P1] 缩略图生成仍在 MainActor 上做全量解码 + 重采样

**位置**：

- 新条目：`Scopy/Services/RealClipboardService.swift:322-330`
- 后台补缩略图：`Scopy/Services/RealClipboardService.swift:396-405` 仍 `MainActor.run`
- 实现：`Scopy/Services/StorageService.swift:1316`（NSImage + lockFocus + PNG）

**原理**：NSImage 解码/绘制/编码是 CPU+内存密集操作；放主线程会卡 UI。  
**优化方向**：

- 将 StorageService 缩略图生成抽成后台安全函数（不依赖 MainActor），用 ImageIO 快速 downsample。
- 生成完成后再通过事件通知 UI 更新对应行。

#### [P1] fetch / search 使用 `SELECT *`，会无谓读取大字段

**位置**：`Scopy/Services/StorageService.swift:429`（fetchRecent）、`SearchService` Step2 / `searchAllWithFilters`  
**现象**：列表和搜索结果只需要 id/type/hash/plain_text/app/时间/pin/size/thumbnailPath，却始终读取 `raw_data` 和完整 `plain_text`。  
**原理**：SQLite 读出整行，BLOB/TEXT 大字段会显著放大 I/O 与内存拷贝。

**优化方向**：

- 新增 `parseItemSummary` + 对应 `SELECT id,type,content_hash,plain_text,...,storage_ref`；列表/搜索只走 summary。
- 仅在 copy/preview 时通过 `findByID` 获取 raw_data 或外部文件。

#### [P1] 大文本未按阈值外部化，可能导致 DB / FTS 膨胀

**位置**：`StorageService.upsertItem` 外部化条件依赖 `rawData`，而 `.text` 内容 `rawData=nil`。  
**原理**：超大 text 会直接存进 `plain_text` 主表并触发 FTS5 索引，插入成本上升且数据库迅速增长。  
**优化方向**：

- 对 `.text` 超阈值：生成 `rawData = Data(plainText.utf8)` 并外部存储；`plain_text` 只保留可索引摘要（如前 4–8k 字符）。
- 或独立 `search_text` 列用于 FTS。

## 4. 优先级行动清单

- **P0（建议先做）**
  1. 将 `performCleanup` 从热路径移除/节流；`cleanupOrphanedFiles` 改为低频任务。
  2. 缩略图磁盘读取与生成离开 MainActor（UI 预取 + 后台 downsample）。

- **P1**
  1. 列表/搜索使用 summary 查询避免 `SELECT *`。
  2. 大文本外部化 + FTS 摘要化。
  3. 预览图后台读取/下采样 + 缓存。
  4. 拆分 AppState 或降低依赖面。

- **P2**
  1. fuzzy 模式引入 FTS 候选集混合。
  2. SearchService actor 隔离语义整理。
  3. bm25/stopwords 策略优化。

## 5. 建议的验证方式

- 使用现有 `make benchmark` 或 `PerformanceProfiler`：
  - 复制 1k/10k/50k 条后测新条目写入 latency、panel 打开首屏、搜索 P95。
  - 单独测：performCleanup 耗时分布、缩略图生成/预览耗时与内存峰值。
- Instruments 重点看 Main Thread 的 File I/O、Image Decode、sqlite3_step 热区。
