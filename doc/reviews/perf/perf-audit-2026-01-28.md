# Scopy 性能审计：O(n)+ 热点与瓶颈（2026-01-28）

> 范围：前端（SwiftUI/List/hover preview）+ 后端（SearchEngine/SQLite/Storage/ClipboardService）。  
> 目标：定位 **O(n)** 及以上（含 **O(n·L)** / **O(n log n)** / **O(offset)**）的热路径，给出可验证、可落地的优化建议与风险。  
> 说明：本文偏“复杂度与热路径”审计；定量基准请配合 `doc/reviews/perf-audit-2026-01-27.md` 与 `logs/*` 使用。

## 0. 本次采用的方法（可复现）

1. 量化：跑了 release bench + phase/counter metrics：
   - `bash scripts/perf-audit.sh --skip-tests --bench-metrics`
   - 输出：`logs/perf-audit-2026-01-29_03-22-58/`（jsonl + env；旧基线：`logs/perf-audit-2026-01-29_01-52-54/`）
2. 回归：跑了 scaling/perf suite（Debug 配置）：
   - `make test-perf`（输出：`logs/test-perf.log`）
3. 静态审计：对 UI/Service/Search/SQLite 做 “O(n)+ 操作” 扫描与人工 review（含 sub-agent）。
4. 外部资料核对：Swift Concurrency（Task/actor 继承语义）+ SQLite OFFSET 语义。

## 1. 定量信号（用于佐证“热路径”）

### 1.1 SearchEngine (release, ScopyBench)

来源：`logs/perf-audit-2026-01-29_03-22-58/scopybench.jsonl`

- `cm`（fuzzyPlus/relevance, engine）P95 ~ 5.58ms
- `数学`（fuzzyPlus/relevance, engine）P95 ~ 9.15ms
- `cmd`（fuzzyPlus/relevance, engine）P95 ~ 0.14ms（FTS 预筛快路径）

来源：`logs/perf-audit-2026-01-29_03-22-58/scopybench.metrics.jsonl`（phase/counters）

- `cm`：`short_query_short_index_fetch` 为主要开销（候选约 604）
- `数学`：`short_query_short_index_sql_fetch` 为主要开销（候选约 262）
- `cmd`：`fts_prefilter` 为主要开销（返回 3）

### 1.2 Scaling（Debug perf tests）

来源：`logs/test-perf.log`

- 5k items：P95 ~ 5.25ms；cold ~ 91ms
- 10k items：P95 ~ 35.45ms；cold ~ 273ms
- 25k items（disk）：P95 ~ 54.78ms；cold ~ 962ms

解释：Debug (-Onone) 会系统性放大 CPU-heavy 路径；主要用于“随 n 增长是否退化”的趋势判断，而不是发布体验的绝对值。

## 2. 前端（UI）O(n)+ 热点（优先级从高到低）

### 2.1 [P0] Hover Markdown 渲染在 MainActor 上执行（会卡顿）

**现象**：`HistoryItemView` 是 `@MainActor`。在 `@MainActor` 作用域内直接 `Task {}` 创建的任务会继承调用方 actor/executor，因此即使设置了 `priority: .utility`，同步 CPU 工作仍会跑在主线程上（详见 Apple/Swift Concurrency 资料）。  
**影响**：hover 触发 Markdown HTML 渲染时可能造成滚动/hover 卡顿，属于典型 “O(L)” CPU work 抢主线程。

**位置**：
- `Scopy/Views/History/HistoryItemView.swift:182`（file preview：MarkdownHTMLRenderer.render）
- `Scopy/Views/History/HistoryItemView.swift:1399`（text preview：MarkdownHTMLRenderer.render）

**状态**：已修复 —— render 迁移到 `Task.detached`（后台）并只在 `MainActor.run` 写回 UI。  

**验证**：
- 开启 `SCOPY_SCROLL_PROFILE=1`，在 hover Markdown 时观察 `/tmp/scopy_scroll_profile.json` 的 `buckets_ms.hover.markdown_render_ms` 与 `drop_ratio`（采样逻辑：`ScopyUISupport/ScrollPerformanceProfile.swift:144`）。

### 2.2 [P0] MainActor 上对 `items` 的 O(n) 数组操作（事件频繁时会放大 UI diff 成本）

`HistoryViewModel` 是 `@MainActor` 且 `items` 会直接驱动 `List`。在以下事件中存在多次 O(n) 扫描/删除：

**位置**：
- `Scopy/Observables/HistoryViewModel.swift:47` / `:54`：`items.filter`（pinned/unpinned 分割，O(n)；虽有 cache，但 `items` 变更即失效）
- `Scopy/Observables/HistoryViewModel.swift:167` / `:221` / `:243` / `:590`：`items.removeAll { ... }`（O(n)）
- `Scopy/Observables/HistoryViewModel.swift:190` / `:212` / `:233` / `:254` / `:259`：`items.firstIndex(where:)`（O(n)）
- `Scopy/Observables/HistoryViewModel.swift:242`：`items.contains(where:)`（O(n)）

**风险场景**：
- 用户滚动加载到几千条后，后台 thumbnail/fileSize 更新事件频繁（每次都 `firstIndex` / `removeAll`）→ 主线程可见抖动。

**建议（两档）**：
1. **轻量（低风险）**：减少“无效赋值”触发 SwiftUI diff：例如 `.thumbnailUpdated` 事件中若路径一致则不写（已做）；对 `items = result.items` 在 ids 不变时跳过赋值（需要小心 selection/metadata）。
2. **结构性（收益大）**：维护 `id -> index` 映射/有序容器（例如 OrderedDictionary/自研索引），把 “去重/查找/替换” 从 O(n) 降到均摊 O(1)，并在 List 侧尽量做局部变更。

**验证**：
- Time Profiler：看 `HistoryViewModel.handleEvent` 栈是否成为主线程热点。
- 统计：对 `handleEvent` 内部加 `Perf.signposts` 或 debug counter（仅 debug/PROFILE gate）。

### 2.3 [P1] 搜索输入变更导致高频 search + List diff（潜在 O(n) UI 更新）

**位置**：
- `Scopy/Views/HeaderView.swift:27`：`onChange(of: searchQuery)` 每次键入立即触发 `historyViewModel.search()`
- `Scopy/Observables/HistoryViewModel.swift:15`：production `searchDebounceNs = 0`
- `Scopy/Observables/HistoryViewModel.swift:468` 起：search task 会 `items = result.items`

**问题本质**：即使后端 search 很快，List diff/重绘仍可能是 O(n)（n=当前显示 items 数）。

**建议**：
- 对短 query（例如长度 ≤2）启用 30–80ms debounce（与后端短词策略一致），或采用“两阶段 UI”：
  - 立即显示 prefilter（轻量）
  - 停顿后/idle 后再替换 items（重 diff）

**验证**：Instruments -> SwiftUI view update/commit 频率；或者给 `search()` 增加 debug 计数输出。

### 2.4 [P1] List 滚动监控：view tree 递归查找 scrollView（最坏 O(n)）

**位置**：
- `Scopy/Views/History/ListLiveScrollObserverView.swift:17`：`updateNSView` 每次 update 调 `attachIfNeeded`
- `Scopy/Views/History/ListLiveScrollObserverView.swift:52` / `:127`：`findFirstScrollView` 递归扫描 view tree（O(nodes)）

**建议**：
- 缓存已 attach 的 `NSScrollView`（已存在 `observedScrollView`，但仍会反复尝试 resolve）；可以把 resolve 的调用从 `updateNSView` 移除或仅在 window/superview 变化时触发。

### 2.5 [P1] MarkdownPreviewWebView 每次 update 都 resolve scrollView（递归）

**位置**：
- `Scopy/Views/History/MarkdownPreviewWebView.swift:152`：`configureScrollers` resolve
- `Scopy/Views/History/MarkdownPreviewWebView.swift:211`：`attachScrollbarAutoHiderIfPossible` resolve
- resolver：`Scopy/Views/History/MarkdownPreviewWebView.swift:8`

**建议**：Coordinator 缓存 scrollView（weak）并仅在 nil 时 resolve；减少递归扫描。

### 2.6 [P1] 缩略图加载 priority 不区分滚动状态

**位置**：
- `Scopy/Views/History/HistoryItemThumbnailView.swift:59`：统一 `.userInitiated`

**状态**：已修复 —— 滚动期间降级为 `.utility`，停止滚动/静止时用 `.userInitiated`。

## 3. 后端（Search/SQLite/Storage）O(n)+ 热点

### 3.0 [P0] Search 热路径里周期性触发全表指标扫描（O(n)）

**位置**：
- `Scopy/Infrastructure/Search/SearchEngineImpl.swift:3666`（`refreshCorpusMetricsIfNeeded`：search 入口每次都会调用）
- `Scopy/Infrastructure/Search/SearchEngineImpl.swift:3680`（`computeCorpusMetrics`：`COUNT/AVG/MAX` 全表聚合）

**问题本质**：
- 该指标用于启发式决策（例如是否偏向 FTS prefilter、shortQueryIndex wait timeout、是否 warmup index），但它被放在 `searchInternal()` 的同步路径里；
- 即便有 30s TTL，仍会造成“每隔 30s 某一次搜索突然变慢”的抖动（n 越大越明显）。

**建议**（收益/风险从低到高）：
1. **不阻塞搜索（低风险）**：当 metrics 过期时，改为后台刷新（Task.detached）并继续使用旧值/默认值；避免把 O(n) 聚合塞进交互搜索的 P99。
2. **持久化增量统计（中风险）**：在 `scopy_meta` 中维护 `item_count/avg_len/max_len`（或近似统计），通过写入路径增量更新或 trigger 维护；读侧变为 O(1)。
3. **更便宜的近似（中风险）**：仅对最近 K 条（如 2k/5k）计算 avg/max，用于 “是否重文本库” 的启发式判断；牺牲精确换取稳定性。

### 3.1 [P0] 深分页 OFFSET = O(offset)（SQLite/FTS/Recent）

**位置**：
- Recent：`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:300`（`LIMIT ? OFFSET ?`）
- Filtered list：`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:429`（`LIMIT ? OFFSET ?`）
- FTS：`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:485`（FTS rowid + offset）

**问题本质**：SQLite 在语义上需要“跳过” OFFSET 行，这意味着随着 offset 增大，扫描工作也线性增大（尤其在深分页/大量历史时）。

**建议**：
- 对 Recent / 非 FTS 的分页改成 keyset pagination（基于 `last_used_at` + `id`），把 deep paging 从 O(offset) 收敛到 O(limit)。
- pinned 与 unpinned 可拆两路：pinned 通常很小，不必用同一 keyset；避免混合排序导致复杂 where。

**验证**：构造 offset=0/1000/5000 的对照 bench（ScopyBench 支持 `--offset`），观察时间随 offset 的线性增长趋势。

### 3.2 [P0] 短词 cache scan（O(n·L)）与 regex scan（O(n·L)）

**位置**：
- `searchInCache`：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:2159`（遍历 `recentItemsCache`）
- `refreshCacheIfNeeded`：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:2197`（2000 条构建 `combined.lowercased()`）
- `searchRegex`：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:2074`（每条跑 regex）

**现状**：有 `shortQueryCacheSize=2000` 的硬上限，属于“可控 O(n)”。

**建议**（如果要进一步压极限）：
- 对 regex / exact short query 做更严格的 gate（例如强制只在 Recent 模式下可用；或提示用户切 fuzzy）。
- 对 `refreshCacheIfNeeded` 的 lowercased/combined 建议只在需要的 mode 下构建（lazy），减少非必要 work。

### 3.3 [P1] FullIndex candidate 交集 + 扫描（最坏 O(n)）

**位置**：
- 候选交集：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:2665`（lists sort + `intersectSorted`）
- 预筛 recent 下的 candidateSlots sort：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:2843`（O(k log k)）
- 打分/遍历：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:2890` 起（对 candidateSlots 做 filter + score）

**解释**：FullIndex 方案本质上是 “先缩小候选，再对候选做打分/排序”。若 query 很短或 corpus 分布导致 postings 很大，k 会变大，趋近 O(n)。

**建议**：
- 对 sortMode==recent 的 prefilter 分支，考虑用 top-K heap 按 lastUsedAt 选取而不是全量 sort（避免 O(k log k)）。
- 对 “极宽短 query” 已有候选占比阈值回退（>0.85）；建议把阈值与 metrics 打印出来（便于现场诊断）。

### 3.4 [P1] 短词 shortQueryIndex 候选过滤仍可能退化（O(k·L)）

**位置**：
- 候选 JSON 构建：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:4238`
- Swift 扫描 plain/note bytes：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:4383`（每行 `instrASCIIInsensitiveUTF8`，O(textLen)）
- ✅ 已落地：top‑K heap + 对 K 项排序（O(k log K)）：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:4249`

**现状**：k 有阈值回退（>4096 且占比 >0.85），因此更像 “可控 O(k)”。

**建议**：继续用 `scopybench.metrics.jsonl` 的 `short_query_short_index_candidates` 观察 k 分布，必要时调整阈值或扩展索引粒度（例如 3-gram/更多非 ASCII 覆盖）。

### 3.5 [P2] 全量 summaries 读取（O(n)）与磁盘缓存一致性

**位置**：
- `fetchAllSummaries`：`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:340`
- SearchEngine 会在索引缺失/失效时触发 build（O(n·L)）：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:2570` 起

**建议**：
- 确保 disk cache 命中率（DB/WAL/SHM fingerprint + mutation_seq）稳定；避免频繁失效导致后台重建反复抢资源。

## 4. 本次实际落地的改动（语义不变）

- 修复 perf-audit 脚本在 `set -u` 下空数组展开崩溃：`scripts/perf-audit.sh`（service bench 的 `--no-thumbnails` 参数拼装）
- UI：hover Markdown 渲染迁移到后台 executor：`Scopy/Views/History/HistoryItemView.swift:182` / `:1399`
- UI：滚动期间缩略图 decode 降优先级：`Scopy/Views/History/HistoryItemThumbnailView.swift:59`
- Search：`computeCorpusMetrics` 从“按时间周期刷新”改为“仅 stale/force 刷新”，消除周期性 O(n) 聚合抖动：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:3665`
- Search：短查询候选页从全量排序改为 top‑K heap（取 `offset+limit+1`），避免 O(k log k)：`Scopy/Infrastructure/Search/SearchEngineImpl.swift:4249`
- SQLite：在 `scopy_meta` 增量维护 `item_count/unpinned_count/total_size_bytes` 并用触发器保持精确，读侧 `getItemCount/getTotalSize` 变为 O(1)：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:86`、`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:403`
- SQLite：补充 `idx_recent_order/idx_app_last_used`，降低常见排序/分组的常数成本：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:164`

## 5. 建议的下一步（按收益排序）

1.（高收益）为 `HistoryViewModel` 引入 `id->index` 映射或有序容器，收敛 MainActor 上的 O(n) 变更成本（特别是 thumbnailUpdated 高频场景）。
2.（高收益）Recent/filtered list 的分页从 OFFSET 改为 keyset（深分页体验与 CPU/IO 都更稳；⚠️ 可能影响分页语义/接口形态，本轮“零行为变更”未做）。
3.（中收益）缓存 `ListLiveScrollObserverView` / `MarkdownPreviewWebView` 的 scrollView resolve，减少递归 view tree 扫描。
4.✅ 已落地：对 short query 候选排序做 heap 化（避免大 k 时 O(k log k)）。
5.（可选）补一个 “deep paging offset scaling” bench（offset=0/1k/5k）并纳入 perf-audit 输出，防止未来回退。
