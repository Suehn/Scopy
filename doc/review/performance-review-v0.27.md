# Scopy 性能深度评审（v0.27）

> 目标：对照 `doc/dev-doc/v0.md` 的性能目标与当前实现（含 v0.27 全量模糊搜索 + P0 性能修复），定位真实热点与成因，给出可从原理上优化的点。  
> 范围：SwiftUI 前端、`AppState`、`SearchService` / `StorageService` / `RealClipboardService` / `ClipboardMonitor` 后端。  
> 分级：P0 立即影响体验/准确性；P1 规模化风险或明显影响；P2 次要/边界场景。

## 总体评价

- **规格对齐度高**：前后端解耦（协议驱动）、无限历史 + 分级存储、FTS5 主索引、全量 Fuzzy/Fuzzy+、150ms 防抖、List 虚拟化等核心目标均已落地。
- **v0.26–v0.27 已解决主要 P0**：
  - 新条目热路径 O(N) 清理 → 防抖/节流 + light/full 分级清理。
  - 历史列表缩略图冷加载主线程磁盘 I/O → 后台读取 + MainActor 赋值。
  - 搜索分页竞态导致“后面出现不相关 item” → 搜索/分页版本一致性保护。
- **剩余瓶颈集中在“主线程重活 + 大规模 fuzzy 候选过大”**，继续优化可把 50k/75k 磁盘极限用例拉回 v0.md 目标。

---

## 1. 前端 / 渲染性能

### 1.1 已经做对的点（稳定且可扩展）

- `List` 替代 `LazyVStack`（`Scopy/Views/HistoryListView.swift`）带来真正的视图回收，10k+ 历史下内存稳定。
- `HistoryItemView` 采用 `Equatable` + 局部 `@State`（hover/preview/thumbnail）降低全局重绘。
- DTO 预计算 title/metadata（`ClipboardItemDTO`）避免渲染期字符串 O(n)。
- v0.27：**搜索与分页版本一致性**（`Scopy/Observables/AppState.swift`）防止旧分页混入新搜索，保障准确性与避免无意义渲染。

### 1.2 真实热点与根因

#### [P0] Hover 预览仍在 MainActor 读取/解码原图

**链路**：`HistoryItemView.startPreviewTask` → `service.getImageData` → `StorageService.getOriginalImageData` → `NSImage(data:)`  
**现象**：hover 时偶发卡顿、内存峰值上升（原图 Data + 全量解码）。  
**原理**：`StorageService` 为 `@MainActor`，外部文件读取与 `NSImage(data:)` 解码在主线程完成；当前实现中 `getImageData()` await 会跳回主线程。

**优化方向**：
- 后台读取 + ImageIO downsample（`CGImageSourceCreateThumbnailAtIndex`，限制 maxPixelSize），只把缩放后的 `CGImage/NSImage` 回主线程。
- 预览缓存按 `contentHash` 复用，避免重复解码。

#### [P1] `AppState` 单体 `@Observable` 依赖面偏大

**现象**：`searchQuery/isLoading/selectedID` 等高频变化可能让更多视图 invalidation。  
**原理**：Observation 依赖按“访问追踪”，大对象更易被视图“顺带读取”。

**优化方向**：
- 拆分为 `SearchState` / `ListState` / `StatsState` 三个 `@Observable`，降低重绘半径。
- 对 handler/service 等低频字段 `@ObservationIgnored`。

#### [P2] 静态 LRU 手写缓存仍有锁竞争/回收粗糙风险

**位置**：`HistoryItemView.iconCache/thumbnailCache`  
**原理**：`NSLock + Array LRU` 在高频滚动下会产生锁竞争与 O(k) LRU 更新。

**优化方向**：
- 使用 `NSCache` 替代（线程安全、自动回收、O(1)）。
- 或将 LRU 更新移到后台批量执行（降低锁频率）。

---

## 2. 搜索性能

### 2.1 已经做对的点

- Exact：FTS5 两步查询 + LIMIT+1（`SearchService.searchWithFTS`）是大规模文本搜索的最佳实践。
- 全量 Fuzzy/Fuzzy+：
  - 字符倒排 postings 交集 → 候选集（保证零漏召回）。
  - 候选上严格 subsequence `fuzzyMatchScore`（语义与旧版本一致）。
  - Pinned → score → lastUsedAt 排序分页。
- v0.26：短词（≤2）改为连续子串语义，仍全量历史覆盖，但避免 subsequence 弱相关噪音。

### 2.2 真实热点与根因

#### [P1] 大规模 fuzzy 候选集过大导致二次验证 + 全量排序成本上升

**位置**：`SearchService.searchInFullIndex`  
**现象**：高频字符/短 query 的 postings 交集仍很大，随后：
1. 每候选做 subsequence 评分（近似 O(M·|q|)）  
2. 对所有 scored 做 sort（O(M log M)）

**优化方向（不改变语义、保证零漏召回）**：
- **postings 交集优化**：用有序数组双指针交集替代 `Set.formIntersection`，减少临时分配与哈希开销。
- **Partial top‑K 排序**：只维护 `offset+limit+1` 的小顶堆/选择算法，避免全量 sort（仍对全部候选评分，语义不变）。
- **可选 FTS 加速**：仅作为“候选优先级/短路加速”，不可作为硬过滤；否则会破坏全量 fuzzy 的召回（FTS 分词/边界不等价于 subsequence）。

#### [P2] 重复字符查询会放大候选集

**现象**：`queryChars` 采用 unique 字符集合，重复字符（如 "aaa"）不会收紧候选；候选放大后由 `fuzzyMatchScore` 二次过滤。  
**原理**：字符倒排是“必要条件预筛”，对重复字符只做存在性过滤。  
**优化方向**：如需进一步压候选，可引入“字符计数”快速验证（按需，不作为 P0）。

#### [P1] 全量模糊索引内存仍有放大空间

**现状**：`IndexedItem` 存 `plainText` + `plainTextLower`；长文本会双份驻留。  
**优化方向**：
- 仅存 `plainTextLower`（或 lower 按需生成），`plainText` 用 DB/缓存按页回填。
- 对超大文本索引摘要（4–8k 字符），与 FTS 摘要一致，避免 postings/内存膨胀。

#### [P2] SearchService `@MainActor` + 自建 queue 并发语义混用

**风险**：未来演进时易引入竞态或锁顺序问题。  
**优化方向**：
- 改为独立 `actor SearchService`（内部串行，天然线程安全），或移除 `@MainActor` 只用 queue 管状态。

---

## 3. 数据 / 内存 / 存储性能

### 3.1 已经做对的点

- 分级存储（100KB 阈值）+ 外部文件目录；WAL + cache_size + temp_store=MEMORY。
- recent cache 去 rawData（v0.19），缩略图/图标缓存有明确上限。
- v0.26：清理从热路径移除，孤儿文件扫描/ vacuum 低频运行。

### 3.2 真实热点与根因

#### [P1] 大内容外部写入仍在 MainActor 同步执行

**位置**：`StorageService.storeExternally` → `writeAtomically`  
**现象**：复制大图/大文本时，主线程发生 `Data.write` 与文件移动，可能短暂卡 UI。  
**原理**：`StorageService` 为 `@MainActor`，写入路径同步。

**优化方向**：
- 将外部文件写入移到后台（utility QoS），主线程只写 DB 元数据；必要时用 actor/队列保证顺序。
- 对超大 text 也外部化，`plain_text` 仅保留索引摘要。

#### [P0] 缩略图生成依赖 MainActor 的 NSImage 绘制/编码

**位置**：`StorageService.generateThumbnail`、`RealClipboardService.scheduleThumbnailGeneration`  
**现象**：即使在后台 Task 中触发，实际生成仍 `MainActor.run`。  
**原理**：`NSImage.lockFocus` 绘制 + PNG 编码是 CPU/内存密集型。

**优化方向**：
- 全流程改为 ImageIO 后台 downsample + 编码（避免 AppKit 绘制）。
- 只在主线程写入“生成完成事件”，不做解码/重采样。

#### [P2] WAL checkpoint 与 incremental vacuum 调度可更智能

**现状**：checkpoint/ vacuum 由清理触发或关闭时触发。  
**优化方向**：
- 监控 WAL 大小阈值（如 >256MB）或大批量删除后再触发 vacuum。
- idle 时段（用户无交互）执行 housekeeping。

---

## 4. 设计/规格准确性对齐（v0.md）

- **前后端解耦**：UI 只通过 `ClipboardServiceProtocol` 访问后端，Mock 可驱动测试 ✅
- **无限历史 + 分级存储 + 懒加载**：分页 fetchRecent / search(limit+offset)；外部大内容；List 虚拟化 ✅
- **搜索三模式**：exact / fuzzy / fuzzyPlus / regex 语义与接口结构一致 ✅
- **性能目标**：≤10k fuzzy P95 已满足；50k/75k 磁盘极限 fuzzy 仍偏高（Debug 环境）⚠️

---

## 5. 下一步优先级建议

- **P0（体验/准确性）**
  1. 全量 fuzzy 50k+ 稳态提速：postings 有序交集 + top‑K partial 排序（无语义/召回变更）。
  2. 缩略图/hover 预览全链路后台化：ImageIO downsample + 编码，主线程仅做状态更新。
- **P1（规模化与主线程重活）**
  1. 大内容外部写入后台化（特别是大图/大文本）。
  2. SearchService actor 化统一并发语义。
  3. AppState 拆分降低重绘依赖面。
  4. 可选 FTS 加速做“优先级/短路”，但保持全量 fallback。
- **P2（结构/细节）**
  1. 重复字符候选压缩（字符计数等）。
  2. postings/缓存结构微优化。
  3. WAL/ vacuum 按阈值与 idle 调度。

---

## 6. 建议验证方式

- `make test-perf` / Instruments：
  - 10k/50k/100k fuzzy/fuzzyPlus 的 P95、候选集规模、排序耗时。
  - 首次构建 full fuzzy index 的 CPU/内存峰值。
  - 主线程热区：File I/O、Image Decode、List diff、sqlite3_step。
