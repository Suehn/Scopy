# Scopy 搜索后端性能优化参考报告（代码深度 Review + 可落地方案）

更新日期：2025-12-16  
当前版本基线：v0.44.fix8（见 `doc/implemented-doc/README.md`）  
目标：把“后端搜索”在真实用户数据形态下（长文/大库/高频输入）做成 **更稳、更省内存、更低尾延迟**，并为后续迭代提供一份可直接照着执行的优化清单与验证方法。

> 本文是“现状梳理 + 风险点 + 优化方案 + 验证用例设计”的合并版；后续优化时建议先按 **P0 → P1 → P2** 推进，每一步都用 `ScopyTests/PerformanceTests.swift` 的基线用例做 A/B 验证。

### 本文的硬约束（避免影响功能/准确性）

为满足“优化不改功能”的要求，本文默认只推荐 **语义等价（Semantics-Preserving）** 的改进：

- **匹配语义不变**：同一输入 query、同一过滤条件下，最终返回的 items 集合与排序规则保持一致。
- **不引入“结果不完整”的新路径**：除非系统已经存在该语义（例如 fuzzy 的 prefilter 返回 `total=-1` 且 UI 会 refine），否则不新增“先快后全”的不完整返回。
- **任何预筛/近似**：只能作为内部加速，并必须有机制保证最终结果等价（例如 query-scope 缓存 / 必要时回退全量）。
- **原理优先**：优先减少重复工作（prepare/回表/索引 churn）、控制长期退化（tombstone/碎片化）、提升可观测性（分段计时）。

---

## 0. 一页纸总结（What / Why / Result）

### What（现状）

Scopy 当前搜索后端是一个组合系统：

- **exact**：短词（≤2）走最近 2000 条缓存；长词走 **SQLite FTS5**。
- **fuzzy / fuzzyPlus**：构建“全量内存索引”（items + char postings）做候选生成与打分；在候选集过大且 query 为 ASCII 长 query 时，使用 FTS 做预筛降载。
- **regex**：限定在缓存（recentItemsCache）里跑。
- 取消/超时：`SearchEngineImpl` 使用 `sqlite3_interrupt` 兜底，避免旧请求拖死新请求。

相关实现入口与关键文件：

- 后端入口：`Scopy/Infrastructure/Search/SearchEngineImpl.swift`
- FTS query 构造：`Scopy/Infrastructure/Search/FTSQueryBuilder.swift`
- FTS schema & 触发器：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`
- SQLite 连接封装：`Scopy/Infrastructure/Persistence/SQLiteConnection.swift`
- UI 侧 debounce + cancel + prefilter→refine：`Scopy/Observables/HistoryViewModel.swift`

### Why（为什么还要优化）

目前基准性能在“测试数据形态”下很好，但代码结构和真实使用习惯会暴露几个常见风险：

- 高频输入时，每次查询 **重新 prepare SQL** 的固定开销会稳定叠加。
- 全量 fuzzy 索引保存 `plainTextLower`（全文 lowercased 复制）+ Character postings：在 **长文 + 大库** 场景内存/构建时间会被放大。
- FTS schema 默认保留较多“全文检索引擎能力”（位置列表、列大小等）。如果产品语义主要是“token presence + AND/OR + 时间/pin 排序”，这些能力可能在为“没用到的特性”付费。

### Result（这份报告交付什么）

1) 清晰列出当前搜索 pipeline、热点与风险点（到文件/函数粒度）；  
2) 给出按 P0/P1/P2 分级的优化 backlog（含收益/风险/落地点/验证方式）；  
3) 给出在现有 `PerformanceTests` 基础上如何“加压”的具体用例设计；  
4) 给出迁移类方案（FTS5 schema 改造、trigram/contentless/prefix）需要的探测与回滚策略。

---

## 1. 现状梳理（你现在的后端搜索结构）

### 1.1 UI 侧（触发频率与取消）

- UI 侧做了 debounce + cancel + “prefilter 后 refine 全量”的渐进策略（打字过程尽量先出首屏，再补全）。  
  参考：`Scopy/Observables/HistoryViewModel.swift`

补充：UI 与后端的“契约点”（对优化很关键）

- 后端返回 `total == -1` 表示“总数未知/结果可能不完整”（例如 prefilter）。
- UI 在 fuzzy 模式下如果拿到 `total == -1`：
  - 会在短延迟后触发一次 `forceFullFuzzy=true` 的 refine（首屏稳定后补全）。
  - 在用户滚动分页时，会先强制 full fuzzy 再继续 paging（避免 prefilter 分页不正确）。

因此：

- 现有体系允许 fuzzy 的 prefilter 用 `total=-1` 表达“不完整/待补全”，UI 已经能承接并 refine。
- 在“避免影响功能/准确性”的约束下，不建议把 `total=-1` 扩展到更多模式或更多场景；优先选择“语义等价”的手段（statement cache、分页结果序列缓存、索引一致性修复）来提速首屏。

### 1.2 SearchEngineImpl：模式路由与超时/取消

- 后端入口：`SearchEngineImpl.search(request:)`（actor）
  - 对 `.fuzzy/.fuzzyPlus` 在“首次建索引”给更长 timeout；其他模式用统一 timeout。
  - 取消/timeout 时调用 `sqlite3_interrupt` 中断正在执行的 SQLite 查询，避免旧任务占用读连接。

### 1.3 exact：短词缓存 + FTS

- `exact`：
  - query 为空：走 `searchAllWithFilters`
  - query ≤ 2：走 `recentItemsCache` 的内存过滤
  - query 更长：`FTSQueryBuilder.build` 生成 FTS query，走 `searchWithFTS`

### 1.4 fuzzy/fuzzyPlus：全量内存索引 + 可选 FTS 预筛

- `fuzzy/fuzzyPlus`：
  - 非短词：构建或复用 `FullFuzzyIndex`（items + idToSlot + charPostings）
  - 候选集很大且 query 满足条件（ASCII、多词/较长）：用 FTS 预筛得到 slots 集合，再做 fuzzy 打分

### 1.5 FTS schema：外部内容表 + unicode61

- FTS 表：`clipboard_fts`（fts5）
  - `content='clipboard_items'`
  - `content_rowid='rowid'`
  - `tokenize='unicode61 remove_diacritics 2'`
  - 通过触发器在 `clipboard_items` 的 insert/delete/update 时维护 FTS。

参考：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`

---

## 2. 当前可观测基线（来自仓库内性能日志）

以 `test-perf.log`（2025-12-16）为例：

- 磁盘 25k（fuzzyPlus）：
  - 冷启动（fullIndex 构建）：~759ms
  - 稳态 P95：~64ms
- 内存 10k（fuzzyPlus）：P95 ~52ms
- 内存 5k（fuzzyPlus）：P95 ~5ms

这些数据说明：当前实现对“条目数量压力（≤25k）”已经不错；后续优化更值得盯住：

- 长文本（单条几十万字符）/大库（>100k）/长期运行碎片化
- 输入过程（频繁查询、prepare/分配固定成本）
- 多语言与路径/子串类 query（unicode61 的分词边界与 fuzzy 的候选生成成本）

---

## 3. 从代码推断的主要瓶颈/风险点（按发生概率排序）

### 3.1 高频输入：每次查询都重新 prepare SQL（固定开销）

现状：

- `SQLiteConnection.prepare()` 每次都 `sqlite3_prepare_v2`，`SQLiteStatement` 析构即 finalize。
- `SearchEngineImpl` 的热路径 SQL（`searchWithFTS` / `ftsPrefilterIDs` / `fetchRecentSummaries` / `fetchItemsByIDs`）在打字过程会被频繁调用。

风险：

- 这会形成稳定的“每次搜索固定成本”，在负载上升或系统降频时直接反映为 P95/P99 抬升。

### 3.2（新增，P0 级风险）：fuzzy 分页的 heap 容量可能随 offset/limit 爆炸

现状（关键点）：

- `searchInFullIndex` 在 `totalIsUnknown == false` 时使用一个 `BinaryHeap` 维护 topK，且 `reserveCapacity(desiredTopCount)`，其中：
  - `desiredTopCount = request.offset + request.limit + 1`
- UI 侧在 fuzzy 模式下为了规避 “total=-1 的 prefilter 无法稳定分页”，采取了两类策略（见 `Scopy/Observables/HistoryViewModel.swift`）：
  - 当 `totalCount == -1`：先 `forceFullFuzzy=true` 再 paging（但它选择 `offset=0, limit=loadedCount+50` 的“递增 limit”策略）
  - 当 `totalCount != -1`：正常使用 `offset=loadedCount, limit=50`

风险：

- 无论是“递增 limit”还是“offset paging”，只要用户在 fuzzy 结果中滚动很深，`desiredTopCount` 都会变大：
  - offset/limit 增长会导致 **heap 预分配数组** 变大（内存瞬时峰值）；
  - 并且算法需要扫描所有 candidate 并维护 topK，CPU 成本随 `desiredTopCount` 变得更不稳定。

为什么这是“隐藏风险”：

- 现有 perf 用例大多测的是 offset=0、limit=50 的首屏；分页深处的最坏路径在测试里几乎不出现。

建议（见后文 P0/P1 方案）：

- **P0**：让 fuzzy 的分页算法避免 `offset+limit` 级别的 topK heap（例如“缓存本次 query 的匹配 slots”或“cursor-based pagination”），在不改变 `total/hasMore` 语义的前提下稳定深分页成本。
- **P1**：如果排序语义继续以 pinned/time 为主（见 3.5），可把分页排序从“全局 topK”改成“按 pinned/time 的稳定顺序流式取第 N 页”，不必维护大 heap。

### 3.2 全量 fuzzy 索引：长文 + 大库时的内存与构建时间放大

现状：

- `IndexedItem` 里保存 `plainTextLower`（整段 lowercased 的复制）
- `charPostings` 以 `Character` 为 key（Set/Dictionary 哈希重、内存占用大）
- `uniqueNonWhitespaceCharacters` 会遍历整段文本并维护 `Set<Character>`，长文下成本很高

风险：

- “长文复制/大段文本”会把 **lowercased 拷贝 + postings** 的内存直接打爆
- 首次构建 fullIndex 的冷启动时间可能显著上升（>30s timeout 风险）

### 3.3（新增，长期退化风险）：删除/清理会产生“索引空洞 + postings 陈旧膨胀”

现状：

- 删除时：`handleDeletion(id:)` 把 `index.items[slot] = nil`，并从 `idToSlot` 移除，但 **不会** 从 `charPostings` 的各个 postings list 中移除该 slot。
- 清理会周期性执行（Storage cleanup），因此长期运行后，fullIndex 可能积累大量 `nil` slot（tombstones）。

风险：

- candidateSlots 的 postings intersection 会越来越“膨胀”（包含大量已删除 slot），导致：
  - intersection 输入 list 变大，交集成本升高；
  - 搜索循环中跳过 `nil` 的比例增加，CPU 被无效 slot 消耗；
  - prefilter 的阈值判断（`candidateSlots.count >= 6000`）更容易被触发，从而改变策略分支，造成抖动。

建议：

- **P0**：当 tombstone 比例超过阈值（例如 `nilCount / items.count > 0.2`）时，将 `fullIndexStale=true`，下次查询触发重建。
- **P1**：将 postings 结构从 `[Character: [Int]]` 变为更易 compaction 的形式（例如位图/分段数组），或维护一个“活跃 slot bitset”来快速过滤。
- **P1**：在 cleanup 完成后（批量删除），直接 `invalidateCache()` 或标记 fullIndex stale（避免长期退化）。

### 3.3 非 ASCII fuzzyMatchScore：潜在 O(n*m) 放大

现状：

- 非 ASCII 分支使用 `firstIndex(of:)` + `distance` / `utf16Offset` 等高层 String 操作，最坏情况在长文本上开销很大。

风险：

- 输入稍长的 query + 长文本库，会触发不可控的尾延迟。

### 3.4（新增，真实性能风险）：搜索结果一次性读取 `plain_text`（长文命中时 I/O + 分配陡增）

现状：

- 无论是 FTS 还是 fuzzy，最终都会通过 `fetchItemsByIDs` / `parseStoredItemSummary` 把 `plain_text` 整段读回内存，作为 UI 列表的数据源。

风险：

- 如果用户复制了“几万字/几十万字”的长文，且查询命中多条，首屏 50 条就可能把几十 MB 的字符串一次性读回：
  - SQLite 读放大；
  - Swift `String` 分配与 ARC 成本；
  - 内存峰值与尾延迟抬升（尤其在磁盘库与后台运行状态）。

建议（见 4.8）：

- **P0（语义等价）**：搜索返回“轻字段 DTO”（不含全文），但 UI 展示仍按需拉取并显示原始全文（或至少显示与当前一致的那部分），避免一次性把全文都读回。
- **非目标（默认不做）**：把列表展示改成 FTS `snippet()` 会改变可见内容与匹配直觉，属于功能变化；除非明确产品要“命中摘要视图”，否则不作为默认优化方向。

### 3.5（新增，语义/性能耦合点）：当前 fuzzy 的排序把“相关性”放在最后

现状（`searchInFullIndex` 的 `isBetterSlot`）：

排序优先级为：

1) pinned  
2) lastUsedAt（越新越靠前）  
3) fuzzy score（仅在 pinned/时间完全相同时才起作用）  
4) id（稳定性）

影响：

- 对性能：绝大多数情况下，score 不会改变最终排序（因为 lastUsedAt 先分胜负），但你仍为每个 candidate 计算了 score（尤其是非 ASCII 分支成本高）。
- 对分页：如果排序主要由 pinned/time 决定，就更适合使用“流式扫描/游标分页”，而不是全局 topK heap（见 3.2）。

建议：

- **P0（语义等价）**：在不改变 comparator 的前提下，把“计算成本”从热路径移走：
  - 让分页策略避免全局 topK heap（见 4.3），减少必须对海量 candidates 计算 score 的次数；
  - 对于 score 只用于 tie-break 的场景，尽量把“计算 score”推迟到“需要比较时”再算（例如 query-scope 缓存 score，或按 pinned/time 分组后仅对同组内候选计算）。
- **非目标（默认不做）**：调整排序优先级或简化 score 逻辑会改变结果顺序，属于功能变化，不作为默认优化方向（见第 8 节）。

### 3.6 FTS schema 默认“全功能”，可能为未使用能力付费

现状：

- 当前 exact 生成的 query 主要是 token AND（每个 token 引号包裹），不依赖 phrase/NEAR 等高级能力。
- 排序大多由 pinned/time 决定（FTS 内部 bm25 的作用有限，甚至可能没被使用）。

风险：

- FTS 索引仍可能存储大量“位置列表/列大小”信息；在长文数据下，索引体积与维护成本会膨胀，影响写入与查询缓存命中。

### 3.7（新增，极高 ROI 的写入侧问题）：FTS update trigger 会在“仅更新元数据”时反复重建索引条目

现状（`SQLiteMigrations.setupFTS`）：

- 你当前的 FTS 维护 trigger 是：
  - `AFTER INSERT`：插入 FTS ✅（合理）
  - `AFTER DELETE`：delete FTS ✅（合理）
  - `AFTER UPDATE ON clipboard_items`：**无条件**执行 `delete old` + `insert new` ❌（高频无意义）

为什么这很要命：

- Scopy 的日常写入模式里，“更新元数据”极高频：
  - 去重命中时会 `UPDATE last_used_at/use_count`（见 `SQLiteClipboardRepository.updateUsage`）
  - 用户复制条目/置顶/取消置顶会更新 `last_used_at/use_count/is_pinned`（见 `SQLiteClipboardRepository.updateItemMetadata`）
- 这些更新 **并不会改变** `plain_text`，按 FTS 外部内容表的语义，根本不需要更新 FTS；但当前 trigger 会导致：
  - FTS 段不断膨胀/碎片化（查询期更容易抖动）
  - WAL 增长更快（更频繁 checkpoint/更多写放大）
  - 在重度使用下，写入侧会为“完全没变的全文索引”付出长期成本

建议（P0，强烈优先）：

- 将 update trigger 改成 **仅在 `plain_text` 发生变化时**才更新 FTS，例如：
  - `AFTER UPDATE OF plain_text ON clipboard_items ...`
  - 或增加 `WHEN OLD.plain_text IS NOT NEW.plain_text`

迁移影响：

- 需要做一次 schema migration（drop old trigger + create new trigger），通常不需要重建 FTS 表。

已落地（v0.44.fix8，语义等价）：

- migration bump：`PRAGMA user_version` 从 1 → 2（`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`）。
- 将 `clipboard_au` 改为仅在 `plain_text` 变化时才触发：
  - `DROP TRIGGER IF EXISTS clipboard_au`
  - `CREATE TRIGGER clipboard_au AFTER UPDATE OF plain_text ... WHEN OLD.plain_text IS NOT NEW.plain_text ...`
- 回归测试：`SearchServiceTests.testFTSUpdateTriggerOnlyFiresOnPlainTextChange`（直接检查 `sqlite_master` 中 trigger SQL）。

验证：

- 新增/补充单测：对同一条 item 连续执行 100 次 `updateUsage/updateItemMetadata` 后：
  - 搜索命中不变
  - （可选）观测 `clipboard_fts` 的 `sqlite_master`/`dbstat` 或 WAL 增长显著下降（在 perf heavy env 下更明显）

### 3.8（新增，语义取舍点）：exact 的短 query（≤2）目前只搜索最近缓存，可能漏掉旧历史

现状：

- `searchExact` 对 `request.query.count <= 2` 直接走 `searchInCache`（仅 `shortQueryCacheSize = 2000` 条），并不会触发 “prefilter→refine” 的全量补全（因为这是 exact 模式）。

影响：

- 如果用户切到 exact 模式搜索 1-2 个字符（尤其是 CJK 单字/双字），会出现“只在最近 2000 条里找”的行为，语义上更像“快速过滤”而非“全量精确搜索”。

结论（在“避免影响功能/准确性”的约束下）：

- **保持现状并文档化**：exact 的短词被定义为“仅最近缓存的快速过滤”，不把它当作全量精确搜索。

备注：

- 让 exact 短词也走全量（prefilter/refine、trigram、prefix 等）都属于“功能/能力变化”，如未来要做，应按第 8 节的标准单独立项与验证。

### 3.9（新增，正确性 + 长期退化风险）：后台 cleanup 删除未通知 SearchEngineImpl，fullIndex/缓存可能长期“漂移”

现状：

- 显式删除/清空：`ClipboardService.delete/clearAll` 会调用 `search.handleDeletion/handleClearAll` ✅
- 但后台定时/阈值 cleanup：`ClipboardService.scheduleCleanup → storage.performCleanup(...)` 过程中会批量删除 DB 记录（`deleteItemsBatchInTransaction`），**没有**同步通知 `SearchEngineImpl` 更新 fullIndex / cache。

潜在影响：

- 正确性：fullIndex 仍保存已删除 item 的 `IndexedItem`，match 阶段会把这些“幽灵 item”算作命中；最后 `fetchItemsByIDs` 回表拿不到，会导致：
  - 返回条数少于 `limit`
  - `hasMore/total` 推断更不准（尤其在深分页/大量删除后）
- 性能：这些幽灵 item 会让 candidateSlots 更大、无效扫描更多（与 3.3 的 tombstone 问题叠加）。

建议（P0）：

- cleanup 完成后，至少执行一次 `search.invalidateCache()`（或标记 `fullIndexStale=true`），保证下一次 search 重建索引与缓存。
- 更精细的做法：让 `StorageService.performCleanup` 返回被删除的 ids（或通过事件流发布），由 `ClipboardService` 逐个调用 `search.handleDeletion`（但批量删除时逐个回调也可能有开销，需要权衡）。

已落地（v0.44.fix8，语义等价）：

- cleanup 成功后统一 `await search.invalidateCache()`，保证 search-side 的 fullIndex / short-query cache 与 DB 状态一致：
  - 定时 cleanup：`Scopy/Application/ClipboardService.swift`
  - settings 更新后触发的 cleanup：`Scopy/Application/ClipboardService.swift`

### 3.10（新增，正确性风险）：pinned 变更未使 short-query cache 失效，可能导致短词结果排序/置顶状态短时间不一致

现状：

- short-query（≤2）会走 `recentItemsCache`（见 `searchExact → searchInCache`）。
- `handlePinnedChange(id:pinned:)` 只更新 `fullIndex`，**不会** 清空/失效 `recentItemsCache`。

潜在影响：

- 用户 pin/unpin 后立刻用短词搜索（exact 或 fuzzy 的短词 prefilter）：
  - `isPinned` 可能仍是旧值；
  - 排序（pinned 优先）可能不符合最新状态；
  - 直到 cache 过期（默认 30s）或被其他路径清空才恢复一致。

建议（P0，语义等价修复）：

- 在 `handlePinnedChange` 内同步清空 `recentItemsCache`（或将 `cacheTimestamp` 置为 `.distantPast`），让下一次短词搜索立即从 DB 刷新。

已落地（v0.44.fix8，语义等价）：

- `SearchEngineImpl.handlePinnedChange` 现在会同步失效 short-query cache（`recentItemsCache/cacheTimestamp`），并清空分页缓存。
- 回归测试：`SearchBackendConsistencyTests.testPinnedChangeInvalidatesShortQueryCacheThroughClipboardService`（通过 service-path 验证 pin 后短词搜索立即生效）。

---

## 4. 优化方向与可执行 backlog（按收益/风险排序）

> 分级解释：
> - P0：低风险、可快速落地、通常不改变用户语义
> - P1：中风险，可能需要迁移/行为调整，但潜在收益高
> - P2：架构级改造，能解决长文/超大库根因，但需要明确产品语义与迁移策略

### 4.1 P0：Prepared Statement 复用/缓存（低风险，高稳定收益）

目标：把“每次查询固定成本”压下去，提升输入过程的稳态延迟。

建议做法：

- 在 `SearchEngineImpl`（actor 串行）内部维护一个 statement cache：
  - key：SQL 字符串（或枚举化的 query 类型）
  - value：`SQLiteStatement`
  - 每次使用前 `reset()` + `clear_bindings`
- 对 SQLite 允许的情况下，可考虑 `sqlite3_prepare_v3(..., SQLITE_PREPARE_PERSISTENT, ...)` 提示长期使用（需要你封装层支持）。

注意点：

- `fetchItemsByIDs` / `IN (?,?,...)` 这种“变长占位符”的 SQL 不好复用；可考虑：
  - 方案 A：对 IDs 先写入临时表（或 `WITH` values）再 join（可复用固定 SQL）
  - 方案 B：保留现状，只缓存“固定形态”的几个 SQL（FTS、recent、all）
- 取消/超时会触发 `sqlite3_interrupt`：如果引入 statement cache，需要确保被 interrupt 的 statement 在下次复用前：
  - `reset()` + `clear_bindings`
  - 正确处理 `SQLITE_INTERRUPT`/错误态（必要时丢弃该 statement 并重新 prepare）
- `SearchEngineImpl.close()` 目前直接 `connection?.close()`：如果 statement 长期存活，需要在 close 前主动清空/析构 cache，避免 `sqlite3_close` 因未 finalize 而失败（或静默失败）。

验证：

- 在 `PerformanceTests` 增加一个“高频短查询 200 次”的 micro-benchmark：对比平均耗时与 P95。

已落地（v0.44.fix8，语义等价）：

- 在 `SearchEngineImpl` 内加入 statement cache（actor 串行，天然安全）：
  - 以 SQL 字符串作为 key，复用 `SQLiteStatement`
  - 每次使用前后 `reset()`（含 `clear_bindings`）
  - cache 上限 32 条，超限时清空（避免潜在的无界增长）
- 覆盖热路径 SQL：`fetchRecentSummaries`、`fetchAllSummaries`、`searchWithFTS`、`ftsPrefilterIDs`、`fetchItemsByIDs`（按占位符数量形成少量固定 SQL）。

### 4.2（新增，P0）：缓存一致性修复（短词 cache / cleanup / pinned）

这是纯“正确性修复 + 长期稳定性”的优化项：不改变功能语义，只消除缓存/索引与真实 DB 状态之间的短暂不一致。

优先级建议：

1) cleanup 后让 `SearchEngineImpl` cache/index 失效（见 3.9）  
2) pinned 变更使 `recentItemsCache` 失效（见 3.10）  
3) tombstone 比例高时触发 fullIndex 重建（见 3.3）  

验证：

- 单测：pin/unpin 后立刻短词搜索，确保 pinned 排序与状态一致。
- perf：启用后台 cleanup 的情况下反复搜索，确保不会出现“返回条数不足/hasMore 异常”的漂移现象。

顺手的语义等价 micro-opt（可同批落地）：

- `searchInCache` 当前会在过滤后再次 `sort`（pinned/time），但 `recentItemsCache` 本身就是按 `is_pinned DESC, last_used_at DESC` 拉取的；对它做 `filter` 不会破坏相对顺序，因此二次排序在语义上是冗余的，可直接移除以降低短词热路径的 CPU/分配。

### 4.3 P0：把 SQLite/FTS 维护工作改成可控后台任务（减少随机抖动）

目标：长期使用后（大量写入/更新/删除）保持查询计划稳定、FTS 段数可控。

建议增加一个“空闲维护任务”（例如：启动后延迟执行；或每 N 次 upsert；或每 X 小时）：

- `PRAGMA optimize;`
- FTS5 special command：`INSERT INTO clipboard_fts(clipboard_fts) VALUES('optimize');`
- 仍保留你已有的 WAL checkpoint 策略（已存在）。

验证：

- 设计一个“写入 50k + 删除/更新混合 + 搜索稳定性”用例（可以放到 heavy perf env 下）。

### 4.4 P0：抑制 fuzzy 深分页的 heap 放大（让分页成本可控）

目标：避免 `offset+limit` 级别的 heap 预分配与全量扫描导致的抖动与内存峰值。

可选路径（按落地难度从低到高）：

1) **为 fuzzy 增加 per-query 的结果缓存（slots 缓存）**（推荐，语义等价）  
   - 当 query/version 不变时，缓存“已匹配并按排序规则排列的 slot 列表”（或缓存到某个 offset）。  
   - 下一页直接切片返回，避免重复扫描与大 heap。  
   - 适合 clipboard 场景：用户通常会在同一个 query 下滚动几页。

2) **游标分页（cursor-based）替代 offset**（中风险，仍可语义等价）  
   - 返回下一页游标（例如最后一条的 `(isPinned,lastUsedAt,id)`），后端继续从该位置向后扫描匹配。  
   - 需要你在 fuzzy 内部有一个“全局稳定顺序”的遍历序列（例如维护一个按 pinned/time 的 slots 列表，并增量更新）。

验证建议：

- 增加一个 perf 用例：同一 query 连续请求第 1/2/3/…/20 页（或 limit 递增到 1000+），观察：
  - 峰值 RSS（或至少观察是否出现明显的 latency jump）
  - P95/P99 是否随页数线性上升

一个非常实际的取舍建议：

- 在 fuzzy 的排序规则里（pinned/time 优先），深分页时“全局 topK heap + 全量扫描”是最大的不稳定来源；  
  语义等价且工程上更稳的做法是：**固定 comparator 不变，但把分页从“重复全量 topK”改成“本次 query 的结果序列复用（cache/cursor）”**。

已落地（v0.44.fix8，语义等价）：

- `SearchEngineImpl.searchInFullIndex` 对 offset>0 的分页请求，会按原 comparator 计算并缓存“本次 query 的全量有序 matches 列表”，后续页直接切片返回：
  - key：`mode + queryLower + filters + forceFullFuzzy + indexGeneration`
  - index 变更（upsert/pin/delete/clear/cleanup）会 bump generation 并清空缓存，避免语义漂移。


### 4.5 P0：修复 FTS update trigger 的无意义索引重写（写入侧降载，间接提升搜索稳定性）

目标：把日常高频的“更新 last_used_at/use_count/is_pinned”从 FTS 维护路径里移除。

落地步骤（建议）：

1) bump `PRAGMA user_version`（新增 migration 版本）  
2) migration 中 `DROP TRIGGER IF EXISTS clipboard_au`  
3) 重新创建 trigger，仅对 `plain_text` 更新生效（`AFTER UPDATE OF plain_text ...` 或 `WHEN` 条件）  
4) 发布后观察：
   - WAL 文件增长速度（`StorageService` 已有监控/checkpoint）
   - 搜索 P95/P99 是否更稳定（长期运行/重度操作更明显）

示例 SQL（用于 migration，按你现有 schema 调整字段名即可）：

```sql
DROP TRIGGER IF EXISTS clipboard_au;

CREATE TRIGGER IF NOT EXISTS clipboard_au
AFTER UPDATE OF plain_text ON clipboard_items
BEGIN
  INSERT INTO clipboard_fts(clipboard_fts, rowid, plain_text)
  VALUES('delete', OLD.rowid, OLD.plain_text);

  INSERT INTO clipboard_fts(rowid, plain_text)
  VALUES(NEW.rowid, NEW.plain_text);
END;
```

风险：

- 极低：只要保证“plain_text 改变时仍更新 FTS”，搜索语义不变；日常元数据更新不再导致 FTS churn。

### 4.6（新增，P0）：为搜索建立“可解释的分段计时与计数器”（让每一步优化可量化）

动机：

当前 perf 输出主要是 end-to-end latency；但要把优化做得“稳且不走弯路”，建议把搜索拆成可观测的阶段：

- `prepare`（SQL prepare/bind）
- `fts`（FTS 查询/预筛耗时）
- `fullIndexBuild`（首次构建）
- `candidateGen`（postings intersection）
- `matchScan`（computeScore/过滤）
- `fetchByIDs`（回表取 DTO）

并记录关键计数：

- `itemCount`（全量库大小）
- `candidateSlots.count`
- `tombstoneRatio`（nil slot 比例）
- `ftsPrefilterLimit`、`ftsHits`
- “每次 search 使用的 SQL 形态”（便于对照 query plan）

落地建议：

- 在 `SearchEngineImpl.search(request:)` 内部用轻量计时（例如 `CFAbsoluteTimeGetCurrent()`）汇总到日志或 `PerformanceMetrics`；
- 只在 Debug 或采样开启（避免引入额外开销与隐私风险）。

语义等价的“护栏”（强烈建议同批加入）：

- 为所有“性能优化 PR”提供一个可复用的等价性测试方法：在同一份测试数据上，对同一组 queries 同时跑“旧路径/新路径”，断言：
  - `items.map(\.id)` 完全一致（集合 + 顺序）
  - `hasMore/total` 语义一致（允许 `total=-1` 的既有路径保持不变）
- 这类测试可以用 env 控制（例如只在 `RUN_PERF_TESTS` 或新 env 下运行），避免拖慢默认 test-run。

### 4.7（保守原则）：FTS schema 级改动默认不纳入“语义不变优化”

像 `detail=...` / `columnsize=...` / contentless / tokenizer 变更 等属于 **schema 语义级** 调整：

- 即使当前代码路径“看起来没用到”，它也会改变 FTS 的能力边界（phrase/NEAR/snippet/highlight/bm25 等）；
- 一旦将来 UI/功能演进依赖这些能力，会出现隐性回退；
- 且迁移成本高（rebuild、双写、回滚）。

因此：在“避免影响功能/准确性”的要求下，本文默认 **不推荐** 把 FTS schema 降配作为近期优化手段。  
如未来确有明确产品约束（例如明确不支持 phrase/snippet，且愿意以能力换吞吐），再单独开文档/版本做迁移与验证。

### 4.8 P1：更激进地用 FTS 做 fuzzyPlus 的候选生成（降低 CPU 峰值）

说明（与“语义不变”约束对齐）：

- 任何“限制候选集”的做法都可能漏结果，除非你能证明候选集是 **包含真实答案的超集**。
- 因此这里的“更激进”建议只应作为 **内部加速且保证最终等价** 的方案，例如：
  - 只用 FTS 来改进“扫描顺序/局部优先级”（不丢弃候选）；
  - 或仅作为 fuzzy 既有的 prefilter（`total=-1`）路径，并确保 UI refine 或后端 query-scope cache 能产出最终等价结果。

如果不能保证最终等价，就不属于本文推荐范围（见第 8 节）。

### 4.9 P1：SQL 形态与 query plan：避免过度 `INDEXED BY` 与 `rowid IN (subquery)` 的计划锁死

现状：

- `SearchEngineImpl.searchWithFTS` / `ftsPrefilterIDs` 使用：
  - `FROM clipboard_items INDEXED BY idx_pinned`
  - `WHERE rowid IN (SELECT rowid FROM clipboard_fts WHERE MATCH ?)`
  - `ORDER BY is_pinned DESC, last_used_at DESC`

风险：

- `INDEXED BY` 会强制 SQLite 使用 `idx_pinned`，可能在某些数据分布下反而阻止更好的计划。
- `rowid IN (subquery)` 在一些情况下会构造中间 rowid 集合；当命中 rowid 很多时，可能会出现不必要的中间结构或排序/扫描。

建议：

- **P0**：用真实用户库做 `EXPLAIN QUERY PLAN` 对比（保留/去掉 `INDEXED BY`、改为 join/CTE 的差异），再决定是否移除强制索引。
- **P1**：对“仅取 ID 作为 prefilter”的查询，优先把 SQL 写成“只取最少列 + LIMIT”的形态，减少回表与排序压力。

### 4.10（保守原则）：trigram/子串索引默认不纳入“语义不变优化”

trigram tokenizer 或其他“子串专用索引”通常会改变：

- 命中集合（尤其短 query、标点、CJK/emoji 混排的边界）
- 召回与排序的可解释性
- 多索引路由带来的边界一致性

因此在“避免影响功能/准确性”的要求下，本文默认不把 trigram 路线作为近期优化项。  
如果未来确有明确的“子串搜索”产品需求，可把 trigram 作为 **新增功能** 单独设计，并以“功能新增”的标准补齐测试与回退策略。

### 4.11（保守原则）：截断/分块/contentless/改写 Unicode 匹配算法默认不纳入“语义不变优化”

以下方案通常会改变搜索召回或 Unicode 语义，属于“功能/准确性”层面的变更：

- 限制/截断进入索引的文本体积（会漏掉尾部命中）
- chunking（命中聚合与排序会变复杂）
- contentless FTS（snippet/展示/一致性要重新设计）
- 用 UTF-16/UTF-8 的近似算法替代 Swift `String` 语义（可能改变 grapheme/大小写/locale 行为）

在本轮“只做语义等价优化”的约束下，这些方向统一归入 **明确不做**（见第 8 节）。  
如果未来确实要解决“极端长文/超大库”的根因，需要以“功能变更/能力约束”的方式单独立项与验证。

### 4.12（新增，P0→P1）：去重/统一两套 FTS 搜索实现，避免长期维护与语义漂移

现状：

- `SQLiteClipboardRepository` 内仍存在一套 FTS 搜索（两段式：先取 rowid + bm25 排序，再回表并用 CASE 保序）。
- `SearchEngineImpl` 也实现了一套 FTS 搜索（rowid IN + pinned/time 排序）。

风险：

- 两套实现会导致：
  - bug 修复与优化难以同步；
  - exact 语义（按相关性 vs 按时间/pin）可能在不同路径出现不一致；
  - 未来做 statement cache / query plan 调优时需要重复工作。

建议：

- 明确“exact 的排序语义”是否应该是：
  - A) pinned/time 优先（当前 SearchEngineImpl 的做法）
  - B) 相关性优先（bm25/snippet）
  - C) 两者混合（例如 pinned 优先，其余按 bm25）
- 然后将另一套实现收敛为：
  - 仅保留一个权威实现（SSOT），或
  - 把两套实现明确分工（例如 repository 用于某些旧路径/测试，但不再用于主流程）

---

## 5. 快速验证/排查建议（不改代码也能先做）

### 5.1 SQLite 能力探测

建议记录并在调试日志里打印：

- `sqlite3_libversion()` / `sqlite3_sourceid()`
- `PRAGMA compile_options;`

说明：

- 这些信息用于后续定位“同一份代码在不同机器/不同系统 SQLite 构建下”的性能差异。
- tokenizer/trigram 等能力探测属于“潜在新增能力/功能变更”的准备工作，本轮语义等价优化不需要做。

### 5.2 EXPLAIN QUERY PLAN：确认 FTS 查询结构是否产生临时表/排序

对当前 SQL 做：

```sql
EXPLAIN QUERY PLAN
SELECT id
FROM clipboard_items INDEXED BY idx_pinned
WHERE rowid IN (
  SELECT rowid FROM clipboard_fts WHERE clipboard_fts MATCH ?
)
ORDER BY is_pinned DESC, last_used_at DESC
LIMIT ?;
```

观察：

- 是否有效利用 `idx_pinned`
- `rowid IN (...)` 是否导致临时结构/额外扫描
- 是否可以通过 join/CTE/union 结构改写减少中间结果

---

## 6. 建议的推进顺序（两周内最可能立竿见影）

### 第一阶段（P0，1-2 天）

1) statement cache（优先缓存固定形态 SQL）  
2) 修复 FTS update trigger：仅 `plain_text` 变化才更新 FTS（写入侧降载）  
3) 加入空闲维护任务：`PRAGMA optimize` + `FTS optimize`（可配置开关）  
4) 增强 perf 用例：高频查询、长文本（轻量版）、fuzzy 深分页（至少 10 页）  
5) 缓存一致性修复：cleanup 后使搜索索引失效 + pinned 变更使 short cache 失效（避免短期不一致）  
6) 处理 fullIndex 的 tombstone 膨胀：阈值触发重建，避免 postings 长期膨胀  
7) short-query 热路径 micro-opt：移除 `searchInCache` 的冗余二次排序（语义等价）  

### 第二阶段（P1，3-7 天）

8) SQL 形态与 query plan 调优（验证是否需要 `INDEXED BY`、是否改写 join/CTE）  
9) fuzzy 深分页语义等价方案落地（query-scope slots cache / cursor），并补齐分页压力测试  
10) 收敛两套 FTS 查询实现（SSOT），避免优化与 bugfix 分叉  

### 第三阶段（P2，视产品语义决定）

11) 仅在明确产品约束下，再讨论 FTS schema 级改动/子串索引/长文策略（这类属于“能力变更”，默认不做）  

---

## 7. 参考资料（后续优化时可直接查）

> 这些链接是为后续实现时快速定位官方语义与边界；实现前建议再次确认与你本机 SQLite 版本匹配。

- SQLite `sqlite3_prepare_v3` / `SQLITE_PREPARE_PERSISTENT`：https://www.sqlite.org/c3ref/prepare.html  
- SQLite `PRAGMA optimize`：https://www.sqlite.org/pragma.html#pragma_optimize  
- SQLite FTS5 总览：https://www.sqlite.org/fts5.html  
- FTS5 “special commands”（含 optimize/merge/automerge 等）：https://www.sqlite.org/fts5.html#special_commands_for_fts5_tables  
- FTS5 `detail=` 选项：https://www.sqlite.org/fts5.html#the_detail_option  
- FTS5 `columnsize=` 选项：https://www.sqlite.org/fts5.html#the_columnsize_option  

补充（交叉验证用的高信誉实践来源，非规范本身）：

- APSW（Python SQLite wrapper）FAQ：关于 `SQLITE_INTERRUPT`/busy/statement reset 的行为说明：https://rogerbinns.github.io/apsw/faq.html  
- SQLite Forum：`sqlite3_interrupt` 的语义与影响范围讨论：https://sqlite.org/forum/forumpost/0978c521f3  
- Stack Overflow：prepared statement cache/prepare 成本讨论（用于实践校验，不作为规范来源）：https://stackoverflow.com/questions/677065/sqlite3-prepared-statements-performance  

---

## 8. 明确不做（默认排除，避免影响功能/准确性）

为避免“优化变成功能变化”，下列方向在本轮默认不做（除非未来明确立项为功能变更，并补齐回归测试与迁移方案）：

- 改变 fuzzy 的排序优先级/打分逻辑（会改变结果顺序与可解释性）
- 让更多模式返回“不完整结果”（除既有 fuzzy prefilter 语义外）
- FTS schema 降配（`detail`/`columnsize`/contentless/tokenizer 变更）
- trigram/子串索引作为主检索路径（命中集合与边界会变化）
- 超长文本截断、chunking（召回语义变化）
- 用 UTF-16/UTF-8 近似替代 Swift `String` 语义的匹配算法（可能改变 Unicode/locale 行为）

如果未来确实要解决“极端长文/超大库”的根因，建议把这些方向改写为“能力约束/功能新增”的正式提案（含用户可见说明与迁移计划）。

---

## 9. 附录：你当前实现里“最值得优先动刀”的位置清单

（方便开工时快速定位）

- 语句 prepare/复用入口：`Scopy/Infrastructure/Persistence/SQLiteConnection.swift`
- 热路径 SQL：
  - `SearchEngineImpl.searchWithFTS(...)`
  - `SearchEngineImpl.ftsPrefilterIDs(...)`
  - `SearchEngineImpl.fetchRecentSummaries(...)`
  - `SearchEngineImpl.fetchItemsByIDs(...)`
- 全量索引构建与 postings：
  - `SearchEngineImpl.buildFullIndex()`
  - `SearchEngineImpl.uniqueNonWhitespaceCharacters(_:)`
  - `SearchEngineImpl.fuzzyMatchScore(...)`
- FTS schema/触发器：
  - `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`
