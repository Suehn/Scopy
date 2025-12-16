# Scopy 搜索后端性能优化参考报告（代码深度 Review + 可落地方案）

更新日期：2025-12-16  
当前版本基线：v0.44.fix5（见 `doc/implemented-doc/README.md`）  
目标：把“后端搜索”在真实用户数据形态下（长文/大库/高频输入）做成 **更稳、更省内存、更低尾延迟**，并为后续迭代提供一份可直接照着执行的优化清单与验证方法。

> 本文是“现状梳理 + 风险点 + 优化方案 + 验证用例设计”的合并版；后续优化时建议先按 **P0 → P1 → P2** 推进，每一步都用 `ScopyTests/PerformanceTests.swift` 的基线用例做 A/B 验证。

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

### 3.2 全量 fuzzy 索引：长文 + 大库时的内存与构建时间放大

现状：

- `IndexedItem` 里保存 `plainTextLower`（整段 lowercased 的复制）
- `charPostings` 以 `Character` 为 key（Set/Dictionary 哈希重、内存占用大）
- `uniqueNonWhitespaceCharacters` 会遍历整段文本并维护 `Set<Character>`，长文下成本很高

风险：

- “长文复制/大段文本”会把 **lowercased 拷贝 + postings** 的内存直接打爆
- 首次构建 fullIndex 的冷启动时间可能显著上升（>30s timeout 风险）

### 3.3 非 ASCII fuzzyMatchScore：潜在 O(n*m) 放大

现状：

- 非 ASCII 分支使用 `firstIndex(of:)` + `distance` / `utf16Offset` 等高层 String 操作，最坏情况在长文本上开销很大。

风险：

- 输入稍长的 query + 长文本库，会触发不可控的尾延迟。

### 3.4 FTS schema 默认“全功能”，可能为未使用能力付费

现状：

- 当前 exact 生成的 query 主要是 token AND（每个 token 引号包裹），不依赖 phrase/NEAR 等高级能力。
- 排序大多由 pinned/time 决定（FTS 内部 bm25 的作用有限，甚至可能没被使用）。

风险：

- FTS 索引仍可能存储大量“位置列表/列大小”信息；在长文数据下，索引体积与维护成本会膨胀，影响写入与查询缓存命中。

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

验证：

- 在 `PerformanceTests` 增加一个“高频短查询 200 次”的 micro-benchmark：对比平均耗时与 P95。

### 4.2 P0：把 SQLite/FTS 维护工作改成可控后台任务（减少随机抖动）

目标：长期使用后（大量写入/更新/删除）保持查询计划稳定、FTS 段数可控。

建议增加一个“空闲维护任务”（例如：启动后延迟执行；或每 N 次 upsert；或每 X 小时）：

- `PRAGMA optimize;`
- FTS5 special command：`INSERT INTO clipboard_fts(clipboard_fts) VALUES('optimize');`
- 仍保留你已有的 WAL checkpoint 策略（已存在）。

验证：

- 设计一个“写入 50k + 删除/更新混合 + 搜索稳定性”用例（可以放到 heavy perf env 下）。

### 4.3 P1：FTS5 schema “降配”换吞吐/体积（中风险，高收益，需迁移）

前提：你要先明确产品语义是否需要以下能力：

- phrase / NEAR
- snippet/highlight
- 基于列长度的 bm25 排名（或强相关性排序）

如果你主要需求是“token presence + AND/OR + pin/time 排序”，可以考虑：

- `detail=none` 或 `detail=column`：减少位置列表相关存储与开销。
- `columnsize=0`：减少列大小统计信息的存储（如果不依赖 bm25/列长度相关 ranking）。

风险：

- 这是 schema 迁移（需要 rebuild FTS）。
- 会影响 phrase/NEAR/snippet/highlight/bm25 等能力（取决于选项）。

迁移策略建议：

- 新建 `clipboard_fts_v2`（新选项），后台重建并双写一段时间，切换查询后再删除旧表。
- 或版本升级时一次性 rebuild（需要可接受的升级时间窗口）。

验证：

- 建立“长文（单条 200k/500k chars）+ 25k 条”压测用例，观察：
  - DB size / FTS size
  - 写入触发器成本
  - exact 查询 P95/P99

### 4.4 P1：更激进地用 FTS 做 fuzzyPlus 的候选生成（降低 CPU 峰值）

你现在只在候选集很大时启用 FTS 预筛；可以考虑进一步把“ASCII 多词、每词≥3、且非短词”的 query 更早路由到：

- FTS topK → fuzzy score 精排（只对 topK 计算 fuzzyMatchScore）
- 甚至直接用 FTS 结果做首屏（offset=0）以保证输入体验，再异步 refine

好处：

- 把最坏情况从“全量遍历 + 字符匹配”变成“倒排索引过滤 + 小集合精排”，尾延迟更稳。

验证：

- 在 `PerformanceTests` 加入“长 query（含多个 token）+ 25k 磁盘库”的稳定性测试，对比 P95 与 CPU time。

### 4.5 P1：trigram tokenizer 做子串/路径/无空格语言专用索引（中风险）

动机：

- unicode61 对“文件路径片段/无空格 CJK 子串”并不总是友好。
- 你自建 fuzzy 的 Character postings 在 CJK 字符集上 key 数会非常大，内存压力更高。

方案：

- 增加第二张 FTS：`clipboard_fts_trigram`（tokenize=trigram）
- query 形态路由：
  - 含空格、多词：优先 unicode61
  - 连续无空格且长度≥3、或明显路径片段：用 trigram
  - 两者可做 fallback（先快路径，后补全）

注意：

- trigram 是否可用与 SQLite 构建有关，建议 runtime 探测：
  - 启动时尝试 `CREATE VIRTUAL TABLE ... tokenize='trigram'`，失败则禁用该路径。

验证：

- 新增“路径子串”与“无空格 CJK 子串”用例，关注命中率与延迟。

### 4.6 P2：限制进入索引/内存的文本体积（根因级优化）

这是最可能“救长文”的根因方案，但会影响语义，需要产品选择：

方案选项：

- A) 双字段：`plain_text_preview`（展示/索引）+ 外部 full text（复制时取外部），并明确“超长文本只保证前 N 字符可搜索”。
- B) 分块（chunking）：超长文本拆成多个 chunk 行进入 FTS，命中后聚合回 item。
- C) contentless FTS + 外部内容：FTS 只存索引不存全文，展示用字段单独维护。

验证：

- 必须增加“尾部 token 命中”与“超长文本检索语义”的回归测试，避免用户感知回退。

### 4.7 P2：自建 fuzzy 索引结构与算法替换（中风险，可渐进）

方向：

- postings key 从 `Character` 改为更轻的表示（例如 ASCII 用 bitset，Unicode 用 `Unicode.Scalar`/UTF-16 code unit）
- `fuzzyMatchScore` 非 ASCII 分支改成基于 UTF-16 的线性扫描与 offset 计数，避免多次 `distance`（Swift 的 `String` 语义正确但很贵）
- fullIndex 不存整段 `plainTextLower`：改成只存一份原文 + “必要时再 lowercased”，或存 UTF-16 缓冲（取舍内存/CPU）

验证：

- 用 “200k chars 文本 + 50k items” 的重负载测试对比：
  - fullIndex build time
  - peak RSS
  - fuzzyPlus P95/P99

---

## 5. 快速验证/排查建议（不改代码也能先做）

### 5.1 SQLite 能力探测

建议记录并在调试日志里打印：

- `sqlite3_libversion()` / `sqlite3_sourceid()`
- `PRAGMA compile_options;`

并做特性探测（例如 trigram tokenizer 是否可用）：

```sql
CREATE VIRTUAL TABLE __probe_trigram USING fts5(x, tokenize='trigram');
DROP TABLE __probe_trigram;
```

失败则禁用 trigram 路由，不影响主功能。

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
2) 加入空闲维护任务：`PRAGMA optimize` + `FTS optimize`（可配置开关）  
3) 增强 perf 用例：高频查询、长文本（轻量版）  

### 第二阶段（P1，3-7 天）

4) fuzzyPlus 更激进的 FTS prefilter/topK 策略（减少 CPU 峰值）  
5) 探测 trigram 可用性并做“子串/路径”路由（可选）  

### 第三阶段（P2，视产品语义决定）

6) 超长文本策略（截断/分块/contentless）  
7) 自建 fuzzy 索引结构替换（逐步迁移，保留回退）  

---

## 7. 参考资料（后续优化时可直接查）

> 这些链接是为后续实现时快速定位官方语义与边界；实现前建议再次确认与你本机 SQLite 版本匹配。

- SQLite `sqlite3_prepare_v3` / `SQLITE_PREPARE_PERSISTENT`：https://www.sqlite.org/c3ref/prepare.html  
- SQLite `PRAGMA optimize`：https://www.sqlite.org/pragma.html#pragma_optimize  
- SQLite FTS5 总览：https://www.sqlite.org/fts5.html  
- FTS5 “special commands”（含 optimize/merge/automerge 等）：https://www.sqlite.org/fts5.html#special_commands_for_fts5_tables  
- FTS5 `detail=` 选项：https://www.sqlite.org/fts5.html#the_detail_option  
- FTS5 `columnsize=` 选项：https://www.sqlite.org/fts5.html#the_columnsize_option  

---

## 8. 附录：你当前实现里“最值得优先动刀”的位置清单

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

