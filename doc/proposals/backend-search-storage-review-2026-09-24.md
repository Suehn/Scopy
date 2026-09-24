---
doc_type: proposal
status: draft
owner: hh
created: 2026-09-24
audience: maintainer decision + implementing agent
---

# 后端评审：搜索引擎、持久化、并发模型与进程生命周期（2026-09-24）

基线：`407f7db`（v0.81.0），下文行号均以此 commit 为准。所有权：`Scopy/Infrastructure/**`、`Scopy/Services/StorageService.swift`、`Scopy/Application/**`、`Scopy/Services/RealClipboardService.swift`、`Scopy/Domain/**`、`Scopy/Runtime/**`、`AppState` 的 start/stop/quit、`Tools/ScopyBench`、`Package.swift`/`project.yml` 模块边界。采集（`ClipboardMonitor`）与前端只在接口处引用。

方法：逐段通读 `SearchEngineImpl.swift`（5,241 行）、`ClipboardService.swift`（2,924）、`StorageService.swift`（2,435）、`SQLiteClipboardRepository.swift`（1,604）、`SQLiteConnection`/`SQLiteMigrations`、`SearchIndexDiskCache`/`SearchIndexBinaryCodec`、`SearchPlanner`、`SearchMatchContextBuilder`（路由段）、`AppState`/`AppDelegate` 生命周期段、`ScopyBench`、Makefile 性能目标。数据事实来自 `perf-db/clipboard.db`（9,566 条）的只读查询（`immutable=1`）与只读 Python 统计。没有构建、跑测试、跑 perf 脚本或启动 app；标“估”的字节数是按 Swift 数据布局推算，实测归属命令写在对应条目里。已裁决事项（⏎ 语义、保留全部内容、原文/去重冻结、`</head>`、滚动天花板、固定预览）不重提。卫生审计（`doc/proposals/code-hygiene-audit-2026-09-19.md`）的删除清单只引用、不重复。

## 0. 结论

| 编号 | 改进 | 优先级 | 规模 | 预期收益（可测） | 主要回归风险 |
| --- | --- | --- | --- | --- | --- |
| B1 | 清理提交与置顶按提交精确维护搜索索引；删除“回调计数器” | P1 | S | 条目数到 `maxItems` 后，每次清理提交（采集期间至多每 60 s 一次）不再丢弃两套内存索引、不再触发短索引 DB 重建（未命中代价实测 ≈1.4 s 后台 CPU）和下一次 fuzzy 的全量重建；后台构建期间置顶不再作废构建结果 | 批量墓碑后的重建阈值；外部提交检测必须保持 |
| B2 | 搜索内存：postings 改 `UInt32`；会话空闲 60 s 释放全量索引并从磁盘回填；内存压力响应 | P1 | S + M + S | 估：空闲基线 −12 MB；会话结束后释放 ≈50 MB 引擎结构（全量索引 ≈31 MB + 最近缓存 ≈20 MB）并交还 malloc 空闲页；`critical` 压力下再释放短索引 ≈26 MB | 会话首个 ≥3 字符 fuzzy 的 refine 多一次磁盘回填（≈50 ms 级）；回放不成立时退化为现有 DB 重建 |
| B3 | `SearchEngineImpl` 按真实缝分解；SQL 词汇统一到 Persistence；删除 repository 中零调用的平行查询层 | P2（D0 为零风险 S，可先做） | L | 引擎 5,241 → ≈900 行；删 ≈230 行死查询；SQL 过滤子句 10 份、分页收尾 8 份、摘要列清单 25 份各收敛为 1 份；引擎不再在 actor 上同步做 DB 全量构建 | SQL 文本或排序比较器被无意改动 → 每步先写 golden 测试 |
| B4 | `StorageService` 由 `@MainActor` 改为 `actor`，纯转发方法 `nonisolated`；清理策略按值传入；删外置大小缓存与锁 | P1 | M | 每次存储调用的主线程跳转 2 → 0；清理/删除/载荷发布路径上的逐文件 stat/lstat/rename 移出主线程；采集、翻页不再排在主线程 90-180 ms 的列表更新之后（静止状态预期无可测差异） | 约 60 处测试改写；隔离等价性由现有 interlock 测试证明 |
| B5 | 存储根单写者守卫（`flock`） | P1 | S | 第二个实例（Debug 与 Release 共用同一 App Support 根）启动即失败并提示，消除跨进程孤儿清理误删新发布载荷与同一复制被双采集 | 开发流程需用 `SCOPY_SERVICE_DB_PATH`（需 hh 决定） |
| B6 | SQLite 扩展结果码进入错误类型与公开日志；每周一次只读 `quick_check` | P2 | S | 损坏可被发现；Console 可区分 BUSY/FULL/CORRUPT/READONLY，而不是一律 `<private>` | 每周一次 ≈146 MB 顺序读（utility，WAL 读者不阻塞写者） |
| B7 | 缩略图缓存按引用清扫 | P2 | S | `thumbnails/` 有上界（与存活 image/file 条目一致） | 与生成并发时可能删掉刚生成的缩略图 → 下次显示重建 |
| B8 | 退出落盘（`.terminateLater`，≤1 s）与生命周期小项 | P2 | S | 若采纳：正常退出后磁盘缓存新鲜，下次启动省 ≈1.4 s 后台 CPU；最坏退出延迟 +1 s | Sparkle 重启、注销路径——需 hh 决定，默认不做 |

总体判断：

1. 后端热路径本身健康（快照门禁 cmd p95 0.53 ms、预热 cm 4.42 ms、冷 cm 59.5 ms；应用自身搜索 12-39 ms），剩余问题集中在“状态的生命周期”，而不是算法：内存索引只增不减；一次清理提交把两套索引整体作废；存储层绑定主线程；进程之间没有写者互斥。
2. 旧评审 §4.4 的 P0（VACUUM、auto_vacuum、定时 checkpoint）在 HEAD 上证据不成立：快照 freelist 201/35,707 页（0.56%）；系统 SQLite 3.43.2 默认 `wal_autocheckpoint=1000`、`journal_size_limit=32768` 已约束 WAL。真正缺的是“发现损坏”（B6）。
3. 卫生审计把“引擎自带平行 SQL 层”列为待合并的重复。复核结果相反：`SQLiteClipboardRepository` 里的 `searchWithFTS`/`searchAllWithFilters`/`ftsPrefilterIDs`/`fetchItemsByIDs`/`fetchAllSummaries` 全仓（含测试）零调用，且排序语义已与引擎漂移；活代码是引擎那一份。正确做法是删 repository 的死副本、把列清单与行解码下沉到 Persistence 共用，而不是把引擎查询搬进 repository actor（会与写事务串行，且引擎超时用的 `sqlite3_interrupt` 会打断写事务）。
4. “引擎 `verifySchema` 少检 `ingest_receipts`”不是缺陷：引擎从不读该表。该统一的是 schema 契约本身——引擎应要求 `user_version == SQLiteMigrations.currentUserVersion`，随之删掉产品不可达的 `data_version`/无 trigram 兼容分支。
5. 建议顺序：先做零语义变化、可测的 S 级（B3-D0、B1、B2a、B5），再做 M/L 级结构（B4、B3），最后是需要 hh 决定的生命周期项（B8）。

## 0.1 终审修正（2026-09-24，主线程 + Codex 第二方复核）

以下裁定优先于本文正文；证据见 [review-roadmap-2026-09-24.md](./review-roadmap-2026-09-24.md) §9。

- **B1 先修通知与提交的对应关系。** `knownDBChangeToken == mutation_seq` 不能证明每笔提交都被观察：置顶产生两次回调（`ClipboardService.swift:1131`、`:2035`），若两次之间发生一笔未通知的提交，第二次回调会把那个 +1 当作自身提交接受（`SearchEngineImpl.swift:1729-1735`）。改为：每笔提交恰好一次通知并携带该提交的 `mutation_seq`，序号出现缺口即明确失效；之后再做批量增量删除。
- **B2b 简化。** 首轮只做 B2a 紧凑化 + 空闲 60 s 释放（缓存过期则先落盘）到 `.absent` + 下次会话走现有加载/构建路径；不做 `released + pending + persistTask` 回放状态机。先用 ScopyBench 首迭代测 DB 重建耗时，只有重建被证明显著才升级。
- **B3-D3 不以 `user_version` 代替结构检查。** 迁移在 trigram 不支持时仍会把版本设为 9（`SQLiteMigrations.swift:337` 附近的 `IfSupported`），已为 9 的库不会再迁移；引擎应显式检查所需表并明确失败。B3 的十余类型目标表降为"按实际修改边界逐步提取"，D0（死代码）保持 Phase 0。
- **B5 的锁在任何共享目录修改之前取得**：在 `ClipboardService.start()` 起点，早于 spool 准备（`ClipboardService.swift:908-945`），释放晚于所有相关工作结束。
- **B6 拆开**：结果码进入错误类型与公开日志（S）先做；每周 `quick_check`、旁路状态文件与设置页提示是 P2 产品设计。
- **B8 维持暂缓**；R10 的退出路径测试不作为 B4 的前置。
- **新增 B9（P2，防御性一致性，随 B4 顺带）：手动删除与清空复用现有安全 unlink 协议。** Codex 第二轮追踪全部生产路径未找到共享 `storage_ref` 的生产者（`updateItemPayload` 的调用者只有测试），因此不是生产 P1。 `deleteItemReturningStorageRef` / `deleteAllExceptPinnedReturningStorageRefs`（`SQLiteClipboardRepository.swift:464, 493`）返回被删行的 `storage_ref`，`StorageService.deleteItem`（`:1073-1095`）与 clearAll 随后直接删文件，不检查是否仍被幸存行引用；cleanup 路径已有在路径预约下复核 `unreferencedStorageRefs` 的协议（`StorageService.swift:1962-1988`，测试 `testCleanupDoesNotUnlinkCommittedRefStillOwnedBySurvivingRow`）。两条删除路径应复用同一协议以消除不一致，但不为此新增引用计数或单独排期。
- **新增 B10（P1，S）：大于 100 MiB 的载荷存得进、读不出。** 写入路径无上限，读取固定拒绝超过 `maxExternalFileSize`（`StorageService.swift:2238, 2290-2291`）且错误被吞成 nil，`.rtf/.html/.image` 复制都先要求这份 data。修正读写契约并保留错误原因；不通过新增采集上限解决。

## 1. 现状与证据

### 1.1 尺寸

| 文件 | 行数 | 说明 |
| --- | ---: | --- |
| `Scopy/Infrastructure/Search/SearchEngineImpl.swift` | 5,241 | 一个 actor 同时承担路由、两套内存索引、磁盘缓存编排、约 1,300 行 SQL、诊断、17 个 DEBUG 缝 |
| `Scopy/Application/ClipboardService.swift` | 2,924 | `:1-653` 是四个与剪贴板无关的并发原语 |
| `Scopy/Services/StorageService.swift` | 2,435 | `@MainActor`，大多数方法是对 repository 的一行转发 |
| `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift` | 1,604 | 写连接；含 ≈230 行零调用查询 |
| `Scopy/Infrastructure/Search/SearchMatchContextBuilder.swift` | 1,177 | 证据构建 |
| `Scopy/Infrastructure/Search/SearchIndexDiskCache.swift` + `SearchIndexBinaryCodec.swift` | 676 + 346 | 磁盘缓存 |

模块边界在 HEAD 一致：`Runtime/**` 只编进 ScopyKit（`project.yml` 三个 target 都排除 `Runtime/**`，`Package.swift:14-33` 由 ScopyKit 编译），旧评审 §8.3 已修复；`ScrollCursorSetCoalescer` 已移到 `Scopy/Views/History/`。无需改模块边界。

### 1.2 运行时拓扑与隔离跳数

```
UI (MainActor) ─► RealClipboardService (MainActor) ─► ClipboardService (actor)
                                                        ├─► ClipboardMonitor (MainActor)             [采集面]
                                                        ├─► StorageService (MainActor) ─► SQLiteClipboardRepository (actor, 唯一写连接)
                                                        ├─► SearchEngineImpl (actor, 只读连接) ─► detached 构建任务（各自开只读连接）
                                                        └─► SettingsStore (actor)
```

- 每次存储调用：`ClipboardService` → 主线程（`StorageService`）→ repository actor → 主线程 → `ClipboardService`，两次落在主线程。`ClipboardService` 中 `await storage.` 48 处、`MainActor.run` 17 处、`await search.` 14 处。
- `StorageService` 在主线程上做的文件系统调用：`validatedExternalFileURLs`（`StorageService.swift:1130-1153`）对每个 ref 调 `validateStorageRef`（`:2240-2280`：`fileExists` + `attributesOfItem` + `resolvingSymlinksInPath`），由 `applyDeletePlan`（`:1744`）与 `deleteAllExceptPinned`（`:1113`）调用；`deleteItem` 的校验（`:1079`）；`getWALFileSize`（`:1508-1515`）；`shouldRefuseOrphanCleanupForMismatchedDatabaseRoot`（`:1576-1592`）；`externalReservationKey`（`:2099-2101`，lstat 链）在 `:522/:546/:811/:860/:913`；`replaceFileAtomically` 的 rename（`:823`）；十余处 `try? FileManager.default.removeItem`（`:473-497`、`:573`、`:600-603`、`:661-695`、`:835/:844`）；`StorageService.init` 建目录（由 `ClipboardService.swift:908` 在主线程构造）。这与 AGENTS.md “Heavy capture, search, cleanup, and media work remains bounded and off the UI thread” 不符。
- 外置大小缓存用 `NSLock`（`StorageService.swift:279`，`:1226-1253`、`:1280-1282`）保护本已被 `@MainActor` 隔离的状态；生产路径实际读的是 `scopy_meta.external_size_bytes`（`:1231-1243`，flag 默认开）。

### 1.3 内存：结构、字节、生命周期、释放点（回答“必须回答 1”）

快照 `plain_text` 分布（UTF-8 字节）：≤256 B 6,565 行；256 B-1 KB 1,483；1-4 KB 770；4-16 KB 472；16-64 KB 246；64-256 KB 26；>256 KB 4（最大 1,014,052）。合计 19,491,780 字节（11,125,267 字符，大量 CJK）。>4 KB 的 748 行持有 16.84 MB（86%）正文与短索引 68% 的 postings（1.98 M / 2.90 M）。最近 2,000 行（按列表顺序）正文合计 9,632,335 字节。

| 结构 | 何时建 | 何时释放 | 估算常驻 | 依据 |
| --- | --- | --- | --- | --- |
| `ShortQueryIndex`（`SearchEngineImpl.swift:401-792`） | 启动：`openIfNeeded`（`:3849`）→ `startShortQueryIndexBuildIfNeeded`（`:1236-1259`），条目 ≥2,000 即建/载 | 从不；只在墓碑比例 ≥25% 时重建；`close()` 置 nil（`:1009`） | ≈37-40 MB（含在“空闲 93 MB”里） | postings 2.90 M × 8 B = 23.2 MB（`[Int]`，`:414-422`；ASCII 字符 ≈0.17 M、ASCII 二元组 0.73 M/4,246 键、非 ASCII 二元组 2.00 M/187,789 键）；≈19.2 万个小数组头 ≈6 MB + malloc 取整 ≈1.5 MB；字典桶 ≈3.3 MB；槽位字符串（UUID/内容哈希/非 text 的 SHA-256）≈2.5 MB；DB 构建后常驻的草稿 `seenNonASCIIBigramStamp`（`:428`，仅在 stamp 回绕时清空）≈2-3 MB |
| `FullFuzzyIndex`（`:181-248`） | 首个需要全量 fuzzy 的查询：`:2235`，或预筛成功后的交互预热 `:2330/:2409/:2422` | 从不：`close()`（`:994-1028`）也不释放 | ≈31 MB | 小写全文副本 19.49 MB（`IndexedItem.plainTextLower`，`:194-212`）；postings 0.84 M × 8 = 6.7 MB（3,496 个非 ASCII 字符键）；`IndexedItem` 9,566 × ≈152 B + 字符串 ≈3.3 MB；`idToSlot` ≈0.4 MB。另：`contentHash`、`createdAt`、`useCount`、`sizeBytes`、`storageRef` 五个字段搜索从不读取（只在 `:194-238` 写入并随磁盘缓存往返） |
| `recentItemsCache`（`:878`，`:2177-2193`） | exact ≤2、regex、fuzzy 最近缓存回退 | 任一变更回调（`:1046` 等）；30 s TTL 只决定何时刷新，不释放 | ≈20 MB | 9.63 MB 原文 + 9.63 MB `combinedLower` |
| `fuzzySortedMatchesCache`（`:931-948`） | 翻页 | 索引变更 | ≤0.8 MB | ≤50,000 × 16 B |
| 引擎读连接页缓存/语句缓存（`:3829-3833`，`:922-929`） | 打开即 | 不 | 小；`cache_size` 上限 64 MB | mmap 读取不复制进页缓存；WAL 帧与 FTS blob 读会复制 |

结论：一次搜索会话后 phys_footprint 的 +99 MB 中，可直接归因于引擎的是 ≈50 MB（全量索引 + 最近缓存）；其余需要 `footprint -v`/`heap` 分类才能归属（构建与解码的瞬时峰值留下的 malloc 空闲页、写连接页缓存（`SQLiteClipboardRepository.swift:119` 同样 64 MB 上限）、前端持有的结果 DTO 全文等）。RSS 211→399 MB 还包含两条连接各自 256 MB mmap 的干净文件页，它们不计入 phys_footprint。空闲 93 MB 中短索引约占 40%。

### 1.4 搜索路由与索引使用（HEAD 实际行为）

| 请求 | 路径 | 覆盖 |
| --- | --- | --- |
| 空查询（任意模式） | `searchAllWithFilters` SQL | complete |
| exact ≤2 字符 / regex | 最近 2,000 条内存扫描（`:1960-1964`、`:2012-2023`） | recentOnly |
| exact ≥3 | FTS unicode61；无结果且非 ASCII 时 instr/trigram 子串（`:1967-1995`） | complete |
| fuzzy/fuzzy+，重文本语料（平均 ≥1 KB 或最大 ≥100 KB；快照平均 2,038 B → 是），未强制，≥3 字符 | FTS 预筛 → fuzzy+ 全 ASCII≥3 词走 LIKE/trigram → 非 ASCII 子串 → 最近缓存（≤6 字符）→ 空的 staged 结果；前三者成功会启动全量索引预热（`:2267-2424`） | stagedRefine（fuzzy+ ASCII 路径为 complete） |
| fuzzy/fuzzy+ ≤2 字符 | 全量索引就绪则用之；否则短索引二元组 + SQL 取行；再否则 `instr` 全表扫（`:2426-2645`） | complete |
| 其余（含 refine `forceFullFuzzy`） | 等待后台构建（`:2743-2753`）或在 actor 上同步全量构建（`getOrBuildFullIndex` `:2707-2716` → `buildFullIndex` `:2755-2812`，占用引擎 actor 与其读连接直到建完） | complete |

`SearchPlanner.plan`（`:1928-1930`）每次搜索都执行，但结果只写入 `perf?.addReason`；它的决策树与上表并不一致（例如不描述预筛失败后的四级回退），属于只用于诊断的影子路由。

### 1.5 持久化事实（快照，只读）

- `PRAGMA user_version = 9`；`page_size 4096`、`page_count 35,707`、`freelist_count 201`（0.56%）。
- `scopy_meta`：`mutation_seq 7240`、`item_count 9566`、`unpinned_count 9551`、`total_size_bytes 1,008,971,892`、`external_size_bytes 838,471,755`；内联字节 170,500,137；外置行 1,143。`total_size_bytes` 由触发器按全部行的 `size_bytes` 维护（`SQLiteMigrations.swift:128-131`、`:144`、`:158`），包括外置行。
- `ingest_receipts`：0 行。ack（`ClipboardService.swift:2329-2348`）与启动恢复（`:948-976`）都会删除。
- 系统 SQLite 3.43.2：`DEFAULT_JOURNAL_SIZE_LIMIT=32768`、`DEFAULT_WAL_AUTOCHECKPOINT=1000`、`THREADSAFE=2`、`ENABLE_FTS5`；trigram 分词器自 3.34 起内置，macOS 14 基线恒可用。
- 清理规划走索引、提前结束：`EXPLAIN QUERY PLAN` 显示 `planCleanupByTotalSize` 的查询 `SEARCH clipboard_items USING INDEX idx_pinned (is_pinned=?)`，累计达标即 `break`（`SQLiteClipboardRepository.swift:1062-1070`）。
- 缩略图（快照副本）：182 个文件、1.2 MB、0 个孤儿；副本不代表线上目录的增长情况。

### 1.6 与旧评审（§4、§5、§8）逐条对照

| 旧条目 | HEAD 状态 | 证据 |
| --- | --- | --- |
| §4.3 列表分页 SELECT 带 `raw_data` | 已实施：三个列表查询走摘要列 | `SQLiteClipboardRepository.swift:547-603` |
| §4.3 `planCleanupByTotalSize` 加 LIMIT | 不需要 | 见 §1.5 查询计划 |
| §4.4 `incrementalVacuum` 空操作 | 已删除 | `StorageService.swift:1493-1497` 注释 |
| §4.4 VACUUM + `auto_vacuum` + `journal_size_limit` | 证据不支持 | freelist 0.56%；默认已限制 WAL |
| §4.4 checkpoint 时机 | 已由 SQLite 自动 checkpoint 覆盖；`WAL > 128 MB` 才截断的分支（`StorageService.swift:1498-1501`）在单写者、`journal_size_limit=32 KB` 下实际不可达 | §1.5 |
| §4.4 `performWALCheckpoint` 仅测试调用 | 仍是 | `StorageService.swift:436-438`（卫生审计已列删除） |
| §4.4 `integrity_check`、备份/恢复 | 仍无 | 检测 → B6；备份/恢复是产品功能，不在本评审 |
| §4.4 envelope 校验和、`fsync` | 超出 D1 契约（architecture.md:57） | 采集面 |
| §4.5 `StorageService` `@MainActor`、两跳隔离、主线程文件调用 | 仍成立 | §1.2 → B4 |
| §4.5 repository 每次 `prepare`、`busy_timeout 500` | 仍成立（`:1480-1487`、`:118`） | 不建议改，见 §4 |
| §4.6 内容预算含外置字节；800 MB 隐藏上限 | 仍成立（`StorageService.swift:1444-1447`、`:206`） | 产品语义，§4；名称误导 → §3 |
| §4.6 缩略图不随条目删除 | 仍成立：全仓只有设置变更时的 `clearThumbnailCache`（`StorageService.swift:2426-2433`，`ClipboardService.swift:1512-1518`） | B7 |
| §4.6 `ingest_receipts` 按时间回收 | 低杠杆：快照 0 行 | §4 |
| §4.6 全部 pinned 时清理空转 | 不成立：`planCleanupByCount` 用 `unpinned_count`，删除数 ≤0 即返回空计划（`:966-980`）；仅多一条 info 日志（`StorageService.swift:1411-1413`） | §4 |
| §5.1 证据缺失清空整页 | 已实施：保留结果并计数告警 | `SearchEngineImpl.swift:1883-1898`、`:1846-1857` |
| §5.3 正则超时只能靠 `sqlite3_interrupt` | 部分过时：`hasRegexMatch` 用 `.reportProgress` 回调检查取消 | `:2025-2054` |
| §5.4 regex 与 ≤2 字符 exact 构造 tokenizer 后不用 | 仍成立，原因是 `isPrefilter` 把 `.recentOnly` 当预筛 | `SearchMatchContextBuilder.swift:398-399` → §3 |
| §5.4 证据在搜索 actor 上串行 | 已不成立：在超时任务组的子任务里执行，不占 actor | `SearchEngineImpl.swift:1813-1838` |
| §5.6 `SearchPlanner` 只用于日志 | 仍成立 | `:1928-1930` → B3-D0 |
| §8.1 事件流 stop→start 后永久死亡 | 缺陷仍在，仍无产品入口 | B8 |
| §8.2 正常退出不落盘 | 仍成立 | B8 |
| §8.3 `Runtime/` 双模块编译 | 已修复 | §1.1 |
| §8.4 `isDatabaseCorrupted` 只写不读 | 已删除 | 全仓无此符号 |
| §8.5 六个手写 continuation 队列 | 仍在 | 正确，不建议现在收敛（§4） |
| §8.6 内存压力、单实例 | 仍无 | B2c、B5 |
| §8.7 57 处 `.private` 改 `.public` | 否决原方向：引擎错误串可能回显查询文本（如 FTS5 语法错误 `fts5: syntax error near "..."`） | 改为公开记录结果码 → B6 |
| §8.8 大文件 | `SearchEngineImpl` 5,241、`ClipboardService` 2,924、`StorageService` 2,435 | B3 |

## 2. 逐项改进

### B1 清理提交与置顶：按提交精确维护搜索索引（P1，S）

问题：

1. 清理提交后整体作废。`publishCommittedCleanup`（`ClipboardService.swift:2373-2386`）在 `:2380` 调 `search.invalidateCache()`；后者（`SearchEngineImpl.swift:1032-1039`）清空最近缓存、丢弃全量索引、丢弃短索引并立刻从 DB 重建短索引——此时磁盘缓存必然过期，因为清理提交推进了 `mutation_seq`。条目数达到 `maxItems`（默认 10,000；快照 9,566、外置 838.47 MB 已贴近 800 MiB 上限）后，每次采集的 2 s 防抖、至多每 60 s 一次的 light cleanup（`:2400-2431`、`:835-837`）都会删最旧的几行，于是每分钟一次整套作废：短索引 DB 重建（2026-09-03 实测短索引未命中 ≈1.4 s 后台 CPU）+ 下一次 fuzzy 搜索重建全量索引。
2. 回调计数器误判。引擎用 `observedMutationCounter`（`:886`，`:1042/:1087/:1115/:1151`）数回调次数，在 `finishFullIndexBuild`（`:1623-1640`）与 `mutation_seq` 增量比较。一次置顶提交会产生两次回调：`setPinned`（`ClipboardService.swift:1131-1138`）先 `handlePinnedChange`，再经 `publishAuthoritativeItemState → synchronizeSearchWithCurrentItem`（`:2014-2057`）`handleUpsertedItem`。后台构建期间置顶 → 计数 +2、seq +1 → 判为“未观测的外部提交” → 丢弃构建结果并重置短索引（`:1632-1637`）。正确性不受影响，代价是一次无谓的重建。
3. `syncExternalImageSizeBytesFromDisk`（`ClipboardService.swift:1575-1582` → `StorageService.swift:1177-1220`）提交后不通知搜索，下次搜索开头 `invalidateInMemoryIndexesIfDBChangedExternally`（`SearchEngineImpl.swift:1755-1772`）把这次 +1 当外部写入，整套重置。

设计：

```swift
// SearchEngineImpl
func handleCommittedDeletions(_ ids: [UUID]) {
    guard !ids.isEmpty else { return }
    // 一次清理阶段 = 一次提交：接受 +1，其余作废（沿用 :1720-1753）
    if invalidateInMemoryIndexesIfDBChangedExternallyBeforeApplyingInternalMutationIfNeeded() { return }
    markCorpusMetricsStale()
    resetQueryCaches()
    applyShortIndexDeletions(ids)   // handleShortQueryIndexDeletion 的批量版：逐 id markDeleted，末尾一次比例检查
    applyFullIndexDeletions(ids)    // 构建中 → pending；就绪 → 逐 id 墓碑，末尾一次 shouldMarkFullIndexStaleDueToTombstones
}

func acknowledgeCommitWithoutIndexChange() {   // size_bytes 同步这类不改索引内容的提交
    _ = invalidateInMemoryIndexesIfDBChangedExternallyBeforeApplyingInternalMutationIfNeeded()
}
```

- `publishCommittedCleanup` 把 `search.invalidateCache()` 换成 `search.handleCommittedDeletions(deletedItemIDs)`。`clearAll` 仍走 `handleClearAll`（几乎全删，重建合理）。
- 删除 `observedMutationCounter` 与 `startedMutationCounter`。`finishFullIndexBuild` 的判定改为“当前 `mutation_seq` 等于 `knownDBChangeToken`”：每个回调都已被逐次校验（+0 或 +1 接受，否则全部作废并推进构建 generation，使构建结果被丢弃），所以二者相等当且仅当构建期间的每个提交都有回调。回调与提交交错时仍会保守重置，与现状相同。
- `syncExternalImageSizeBytesFromDisk` 在 `updated > 0` 时 `await search?.acknowledgeCommitWithoutIndexChange()`。

实现步骤（3 个提交）：① 删计数器、改等值判定，附置顶测试；② 批量删除 API 并接入清理；③ size 同步通知。

涉及文件：`SearchEngineImpl.swift`、`ClipboardService.swift`、测试；`doc/current/development-guide.md:121`（4.1 第 4 步改为“applies the exact committed deletion set to the search indexes”）。

验证门禁：`make build`、`make test-unit`、`make test-strict`、`make test-snapshot-perf-release`（新鲜 `make snapshot-perf-db` 副本）、`make docs-validate`。

守护测试：
- `SearchIndexMaintenanceTests.testCommittedDeletionsTombstoneWithoutDroppingIndexes`：2,500 行（≥2,000 才会建短索引），先建两套索引；删 10 个 → `debugFullIndexHealth()` 仍 `isBuilt`、`tombstones == 10`，`debugShortQueryIndexStats().isBuilt`，被删 id 不出现在 fuzzy 与 1-2 字符结果里，其余可搜。
- `testCommittedDeletionsAboveTombstoneRatioRebuildWithCompleteResults`：删 30% → 标记重建，结果完整。
- `testPinDuringFullIndexBuildKeepsBuildResult`：新增 DEBUG 缝 `debugInstallPendingFullIndexBuild`（仿 `:5226`）挂起构建，期间发出置顶的两次回调，放行后全量索引已建、短索引未重置。
- `KnownDataVersionExternalWriteTests` 必须保持通过（未观测的外部提交仍被发现）。
- `ClipboardServiceCleanupTests` 增一条：`maxItems` 缩小触发清理后，剩余条目可搜，被删条目不可搜。

风险：大批删除仍按 25% 墓碑阈值触发重建（现有语义）。规模：S。需 hh 决定：无。

### B2 搜索内存：紧凑化、会话级全量索引、内存压力（P1，S + M + S）

问题：见 §1.3。全量索引与最近缓存在会话后不释放；短索引以 `[Int]` 保存本就以 Int32 落盘的 postings；`close()` 也不释放全量索引。

设计（三部分，可分别提交）：

**B2a 紧凑化（S，零语义变化）**

- 两套索引的 postings 由 `[Int]` 改为 `[UInt32]`。磁盘格式本来就是小端 Int32（`SearchIndexBinaryCodec.swift:52-60`、`:120-130`），因此两种缓存格式都不变、无需 bump；`Reader.postings()` 直接产出 `[UInt32]`，省掉逐元素加宽。估：短索引 −11.6 MB、全量 −3.4 MB。
- 删除 `IndexedItem` 中搜索不读取的 5 个字段。这会改变全量缓存格式：`fullIndexDiskCacheVersion` 5 → 6，旧 v5 文件由现有 `removeStaleCacheFiles`（`SearchIndexDiskCache.swift:124-139`）删除，不保留旧解码器。估 −1.6 MB，缓存文件 −0.9 MB。
- 短索引批量构建结束时清空 ingest 草稿（`seenNonASCIIBigramStamp` 等，`:424-428`），估 −2-3 MB（只影响 DB 构建来源）。

**B2b 会话级全量索引：空闲释放 + 磁盘回填（M）**

状态机（建议在 B3-D4 的 `FullIndexStore` 中落地；若先做 B2b，可在现文件内以同一枚举替换 `fullIndex`/`fullIndexStale`/`fullIndexBuildTask`/`fullIndexPendingEvents`/`fullIndexBuildTrigger`）：

```swift
enum FullIndexState {
    case absent                        // 未建或已作废：按现有路径加载/构建
    case building(FullIndexBuild)      // task + generation + trigger + pendingEvents（现有字段）
    case ready(FullFuzzyIndex)
    case released(ReleasedFullIndex)   // 已落盘，等待回填
}

struct ReleasedFullIndex {
    let stamp: DBContentStamp          // 落盘时的 mutation_seq 与存活条数
    var pending: [FullIndexPendingEvent]  // 释放后观察到的提交；upsert 只存 IndexedItem，不带 rawData
    var pendingBytes: Int
    let persistTask: Task<Void, Never>?
}
```

- 触发：引擎内至多一个“空闲裁剪”任务。`search()` 入口 `activeSearchCount += 1` 并记录 `lastSearchUptime`，出口 `-1` 后 `armIdleTrimIfNeeded()`；任务醒来时若距最后一次搜索 ≥ `sessionIdleTrimDelay`（60 s）且无进行中的搜索就裁剪，否则睡剩余时间。每个会话只分配一个 Task。面板关闭即会话结束，因此不需要 UI 通知。
- `trimSessionMemory(.idle)`：① `recentItemsCache = []`、`fuzzySortedMatchesCache = nil`、清空语句缓存、对读连接调 `sqlite3_db_release_memory`；② `.ready(index)` 且未过期：若磁盘缓存已是当前 stamp 则直接转 `.released`；否则用现有 `makeFullPersistRequest`（`SearchIndexDiskCache.swift:387-416`）在 detached 任务写盘，状态立即转 `.released(stamp, pending: [], persistTask)`，写完即释放请求持有的索引引用；③ `.building` → 取消，转 `.absent`；④ 最后 `malloc_zone_pressure_relief(nil, 0)` 把空闲页交还系统（否则 phys_footprint 未必下降）。
- 释放期间的提交：各 `handle*` 在 token 校验通过后把精简事件追加进 `pending`；超过 1,024 条或 16 MB 即转 `.absent`（下次走 DB 重建）；校验失败也转 `.absent`。
- 回填：会话中第一个非空 fuzzy 查询（包括 1-2 字符，此时仍由短索引应答）就启动回填任务：`await persistTask` → `SearchIndexDiskCache.loadFullSnapshot(dbPath:expecting: stamp)`（新增 `expecting` 参数：校验缓存头 seq 与存活条数等于释放时的 stamp；现有启动路径传当前 DB stamp，`preflightFullIndex` 在 `:262`、`:276` 的比较改为比较传入值）→ 回到 actor，按序应用 `pending` 与加载期间的新事件 → 若 `knownDBChangeToken == 当前 mutation_seq` 则 `.ready`，否则丢弃并走现有 DB 构建。DB 构建是现有的正确性路径，不是兼容层。
- 正确性：快照等于释放时的内存索引（checksum 保证）；释放后的每个提交都经过逐回调校验，未观测提交会让状态退回 `.absent`；因此“快照 + 按序回放”与“常驻并增量维护”等价。

**B2c 内存压力（S）**

`ClipboardService.start()` 创建 `DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))`，`stop()` 取消。`.warning` → `search.trimSessionMemory(.pressure)`：同 idle，但不写盘（编码会再分配 ≈25 MB），全量索引直接 `.absent`；`.critical` → 另外丢弃短索引（下次从磁盘缓存 ≈55 ms 载入或 DB 重建），并 `await repository.releaseMemory()`（写连接 `sqlite3_db_release_memory`）。前端缓存（hover 图片、缩略图、memo）由前端各自订阅，不做中央总线。

不默认做（需 hh 决定）：每条只索引前 N KB。它改变 fuzzy/fuzzy+ 对长文尾部的召回（exact/FTS 不受影响），而空闲释放已经拿走大部分收益：

| 每条上限 | 受影响行 | 全量索引文本 | 全量 postings | 短索引 postings |
| --- | ---: | ---: | ---: | ---: |
| 无 | 0 | 19.49 MB | 839,030 | 2,896,023 |
| 64 KB | 30 | 15.64 MB | 833,009 | 2,700,641 |
| 16 KB | 276 | 11.20 MB | 803,093 | 2,300,458 |
| 8 KB | 486 | 8.21 MB | 755,236 | 1,940,864 |

对 `make test-snapshot-perf-release` 三个指标的预期：
- cmd p95（service 层 fuzzyPlus，重文本语料走 FTS 预筛 `:2267-2313`）：不变；基准 20 次预热 + 30 次迭代连续执行，不会触发 60 s 空闲裁剪。
- 预热 cm p95（engine 层 + `--prepare-short-index`）：postings 变窄，预期持平或略好，须实测。
- 冷 cm：不变；短索引加载少一次加宽循环。

新增证据（B2 的性能结论必须有）：
- `scripts/perf-search-warm-load.sh` 额外解析 `/usr/bin/time -l` 已输出的 `peak memory footprint` 行（与 `:171` 的 RSS 解析并列）。
- ScopyBench engine 层新增 `--trim-between-iterations`：每次迭代前 `trimSessionMemory(.idle)` 并注入 1 个 upsert 事件，报告“释放后首搜”p95，并在 JSON 中记录 `task_info(TASK_VM_INFO).phys_footprint`（打开后、预热后、裁剪后）。
- 真实 app（手工，记录到 runbook 或其链接证据）：`footprint -p Scopy` 取空闲、8 键搜索会话后、会话结束 70 s 后三个点。验收：第三点比第二点低 ≥40 MB；空闲点比 v0.81.0 低 ≈10 MB。不达标即说明其余增长在前端或 SQLite，须用 `footprint -v` 分类后再议。

实现步骤：① B2a 的 `UInt32` postings（两个索引各一提交）；② `IndexedItem` 瘦身 + 缓存 v6；③ 状态枚举替换散落字段（行为不变）；④ 空闲裁剪 + 回填；⑤ 内存压力；⑥ 工具与证据。

涉及文件：`SearchEngineImpl.swift`（或 B3 后的 `FullIndexStore.swift`/`ShortQueryIndex.swift`/`FullFuzzyIndex.swift`）、`SearchIndexDiskCache.swift`、`SearchIndexBinaryCodec.swift`、`ClipboardService.swift`、`SQLiteConnection.swift`（`releaseMemory()`）、`SQLiteClipboardRepository.swift`、`Tools/ScopyBench/main.swift`、`scripts/perf-search-warm-load.sh`、`doc/current/development-guide.md:157`（缓存文件名 v5 → v6）。按 AGENTS.md 在调用前用 Cupertino 核对 `malloc_zone_pressure_relief`、`DispatchSource.makeMemoryPressureSource`、`task_info` 的签名与可用性。

验证门禁：`make build`、`make test-unit`、`make test-strict`、`make test-tsan`（新增任务生命周期）、`make test-snapshot-perf-release`、`make perf-search-warm-load`、`make perf-unified-table`（性能结论）、`make test-tooling`（脚本改动）、`make docs-validate`。

守护测试：
- `SearchSessionMemoryTests.testIdleTrimReleasesFullIndexAndReloadsFromDiskWithReplay`：DEBUG 缝 `debugTrimSessionMemory(.idle)`；释放后插入 3 条并回调；首个 fuzzy 查询命中新条目，`debugFullIndexLastSnapshotSource() == "diskCache"`。
- `testTrimIsDeferredWhileSearchInFlight`。
- `testUnobservedCommitWhileReleasedFallsBackToDatabaseRebuild`（`KnownDataVersionExternalWriteTests` 的释放态版本）。
- `testPendingOverflowFallsBackToDatabaseRebuild`（DEBUG 注入小上限）。
- `testPressureWarningDropsWithoutPersistAndCriticalDropsShortIndex`。
- `FullIndexDiskCacheHardeningTests`、`ShortQueryIndexDiskCacheHardeningTests` 在 `UInt32` 改动后保持通过；新增 `testFullIndexCacheV5IsRemovedAndRebuiltAsV6`。

风险：会话首个 ≥3 字符 fuzzy 的 refine 多一次磁盘回填（v0.78.2 记录的磁盘加载 ≈50.5 ms）；回放不成立时退化为 DB 重建（本机无干净的 DB 重建耗时记录，实施时用 ScopyBench 首迭代测量）；每个有变更的搜索会话写一次 ≈25 MB 缓存。规模：S + M + S。

需 hh 决定：60 s 空闲阈值；是否要每条前 N KB 上限（默认不做）。

### B3 `SearchEngineImpl` 分解与 SQL 访问层统一（P2，L；D0 可先做）

问题：一个 actor 文件承担六件事；SQL 过滤子句 10 份、内存过滤 6 份、分页收尾 8 份、摘要列清单引擎 15 份 + repository 10 份、pinned 优先比较器 5 份；`computeScore` 两份（`:2904-2934`、`:3338-3370`）；recent 排序闭包两份只差计时（`:3009-3024`、`:3027-3042`）；top-K 堆循环三份（`:3094-3124`、`:3196-3225`、`:3244-3274`）。索引值类型嵌套在 actor 里，`SearchIndexDiskCache` 反向依赖 `SearchEngineImpl.FullFuzzyIndex` 等嵌套类型，形成文件级环。

关于“把引擎的 SQLite 访问层合并进 `SQLiteClipboardRepository`”的复核结论：

- repository 中下列方法全仓（含测试）零调用，排序语义已漂移（例如 repository 的 `searchWithFTS` 先按 bm25 取 rowid、再按 pinned 排，`:796-879`；引擎是 pinned → 时间/bm25 → id，`SearchEngineImpl.swift:4100-4180`）：`fetchAllSummaries`（`:605-618`）、`fetchItemsByIDs`（`:620-645`）、`searchAllWithFilters`（`:740-794`）、`searchWithFTS`（`:796-879`）、`ftsPrefilterIDs`（`:881-902`）、`deleteItem(id:)`（`:455-462`）、`deleteAllExceptPinned()`（`:487-491`），约 230 行。它们应当删除，而不是作为合并目标。
- 引擎的查询不能搬进 repository actor：① 引擎在超时与取消时对自己的连接调用 `sqlite3_interrupt`（`SearchEngineImpl.swift:1811-1843`），共享写连接会打断进行中的采集或清理事务；② repository actor 串行执行，10-40 ms 的 FTS/trigram 查询会与 `BEGIN IMMEDIATE` 写事务互相排队；③ 会丢掉 WAL 下独立读连接的并发。
- 所以“合并”的正确含义是：一份 SQL 词汇与行解码（Persistence），两条连接。
- `verifySchema` 两份（引擎 `:3894-3904` 查 2 张表，repository `:1489-1508` 查 3 张表）：引擎不读 `ingest_receipts`，少检不构成缺陷。统一为 `SQLiteSchema.requireCurrentVersion(_:)`：比较 `PRAGMA user_version` 与 `SQLiteMigrations.currentUserVersion`（`SQLiteMigrations.swift:4`）；repository 在迁移后调用，引擎在打开只读连接时调用。版本一致即保证全部表（含 `scopy_meta`、trigram、receipts）存在，随之删除产品不可达的兼容分支：引擎的 `usesMutationSeq`/`data_version` 路径（`:875`、`:1527`、`:1551`、`:1623`、`:1698-1710`、`:1729-1744`、`:3836`；全部 31 处 `SearchEngineImpl(dbPath:)` 调用点的库都经过 StorageService 迁移），`supportsTrigramFTS`（4 处）与迁移中吞掉 trigram 失败的 `IfSupported`（`SQLiteMigrations.swift:322-343`），repository 中 `scopy_meta` 缺失时的 `COUNT(*)` 回退（`:668-678`、`:680-692`、`:694-712`、`:966-977`）。

目标类型（全部留在 ScopyKit）：

| 目标 | 来源（HEAD 行） | 性质 | 估算行数 |
| --- | --- | --- | ---: |
| `SearchEngineImpl`（actor） | 路由 `:1776-2645`、生命周期 `:963-1039`、变更入口 `:1041-1235`、超时 `:3786-3813` | 编排；唯一 actor | ≈900 |
| `extension SearchEngineImpl` 公共类型（`SearchError`、`SearchResult`、`SearchPerfMetrics`） | `:8-91` | 值类型，保留嵌套名以免改 ScopyBench/测试 | ≈90 |
| `FullFuzzyIndex` + `IndexedItem`（顶层） | `:181-248`、`:3458-3520`、`:2814-2827`、`:1375-1508` | 纯值类型：`upsert`/`remove`/`setPinned`/`build(rows:)`/`needsRebuild` | ≈300 |
| `ShortQueryIndex`（顶层） | `:391-792` | 纯值类型，原样搬 | ≈400 |
| `FuzzyMatcher` | `:3522-3782`、两份 `computeScore` | 纯函数：`PreparedFuzzyQuery`、子序列打分、UTF-16 快路径、fuzzy+ 词打分 | ≈330 |
| `FullIndexRanker` | `:2829-3310`、`:806-869`、`:931-948` | 纯函数：候选交集、预筛合并、top-K、排序缓存、唯一比较器 | ≈450 |
| `RecentItemsCache` | `:176-179`、`:2121-2193`、`:3312-3428` | 值类型 + 过滤 | ≈200 |
| `FullIndexStore` / `ShortIndexStore` | `:883-912`、`:1165-1323`、`:1521-1689`、`:2647-2753` | 封闭在引擎 actor 内的非 Sendable 状态机（B2 的状态枚举在此） | ≈500 |
| `SearchReadStore` | `:3815-5145` 去死代码与重复 | 只读连接 + 语句 LRU + 全部查询；统一 `appendFilters`、`PageWindow` | ≈850 |
| `ClipboardItemRow`（Persistence） | 引擎 `:5109-5145`，repository `:1510-1585` | 摘要/完整列清单常量 + 行解码，两个连接共用 | ≈90 |
| `SQLiteSchema`（Persistence） | 两份 `verifySchema` | `requireCurrentVersion` | ≈30 |
| `SearchDiagnostics` | `:97-174`、`:312-367`、`:1510-1519` | `PerfContext`、`SearchWarmLoadMetrics` | ≈150 |
| `SearchEngineImpl+DebugSeams.swift`（`#if DEBUG`） | `:5154-5240` | 测试缝，接口不变 | ≈90 |
| `SearchQueryText` | `SearchPlanner.swift:259-278` | `normalizedExactQuery`、`fuzzyPlusTokens`、`shouldUseSubstringOnlyFallbackForFuzzyPlus` | ≈30 |

证据附着 `attachingMatchContexts`（`:1869-1909`）移为 `SearchMatchContextBuilder.attach(to:request:)`。

依赖方向（无环）：

```
ClipboardService ─► SearchEngineImpl (actor)
                      ├─► SearchReadStore ─────────────┐
                      ├─► FullIndexStore / ShortIndexStore ─► FullFuzzyIndex / ShortQueryIndex (值)
                      │        ├─► SearchIndexDiskCache ─► SearchIndexBinaryCodec
                      │        └─► 构建任务（detached，自开只读连接）──┤
                      ├─► FullIndexRanker ─► FuzzyMatcher (纯)       │
                      ├─► RecentItemsCache                          │
                      └─► SearchMatchContextBuilder (纯，任务组子任务)  │
SQLiteClipboardRepository (actor) ─────────────────────────────────┴─► Persistence: SQLiteConnection、ClipboardItemRow、SQLiteSchema、SQLiteMigrations
```

实现步骤（每步独立提交，行为不变；先写守护测试再搬）：

- D0（S）死代码：repository 上述 7 个方法；引擎 `fetchAllSummaries`（`:3971-3988`）；每次搜索执行的 `SearchPlanner.plan` 与 `SearchPlan*` 类型（保留三个纯函数，`SearchPlannerTests` 中非计划部分保留）；以及卫生审计已列的 signpost 与两个折叠 flag。同步 `development-guide.md:80`、`:235`。门禁：build、unit、strict。
- D1（S）把值类型提到顶层（纯移动）：`IndexedItem`、`FullFuzzyIndex`、`ShortQueryIndex`、`DBContentStamp`、快照/磁盘缓存元数据类型、`SearchWarmLoadMetrics`。约 41 处 `SearchEngineImpl.X` 引用改名（`Scopy/` 与测试）。门禁：build、unit。
- D2（M）`FuzzyMatcher` + `FullIndexRanker`：先加 `FullIndexRankerGoldenTests`（内存索引夹具，无 DB）锁定现有排序：pinned 优先；recent 与 relevance 的 tie-break；uuidString 兜底；预筛 recent 路径与堆路径对同一候选集排序一致；深翻页缓存命中与未命中返回同页；fuzzy+ 对 ASCII ≥3 词做子串打分、<3 做子序列打分。再搬迁并把 5 个比较器合成 1 个。门禁：build、unit、strict、snapshot perf。
- D3（M）`SearchReadStore` + `ClipboardItemRow` + `SQLiteSchema`：先加 `SearchSQLGoldenTests`（约 200 行确定性夹具：CJK、note、pinned、3 个 app、全部类型；对每个查询函数 × 过滤组合记录有序 id、`total`、`hasMore`），再重构使其逐字节一致；随后单独一个提交删除兼容分支并让 trigram 成为必需（附 `testEngineRejectsDatabaseBelowCurrentUserVersion`）。门禁：build、unit、strict、snapshot perf、`SQLiteTextFidelityTests`。
- D4（M）`FullIndexStore`/`ShortIndexStore`：状态枚举；全量构建一律走 detached 构建并 await，删除 actor 上同步构建的 `buildFullIndex`（`:2755-2812`），使 refine 等待时引擎 actor 不再被阻塞。守护：`FullIndexWarmupContinuityTests`、`FullIndexPendingEventsCleanupTests`、`FullIndexTombstoneUpsertStaleTests`、`KnownDataVersionExternalWriteTests`、`ReviewFix24Tests`、两个 `*DiskCacheHardeningTests`、`ConcurrencyTests`。门禁：build、unit、strict、TSan、snapshot perf。
- D5（S）证据附着移入 builder；诊断与 DEBUG 缝各自成文件。守护：`SearchMatchContextBuilderTests`。
- D6（S）`ClipboardService.swift:1-653` 的四个并发原语（`BoundedCoalescingWorkerQueue`、`BoundedRetryTimestamps`、`ClipboardEventQueue`、`ClipboardItemMutationGate`）移到 `Scopy/Application/Concurrency/`，纯移动（`ClipboardItemMutationGate` 由 `private` 改 `internal`）。门禁：build、unit、strict。

风险：SQL 文本变化会让语句缓存键与查询计划变化——D3 要求重构前后同一路径生成相同 SQL；比较器合并最易引入排序差异——由 D2 golden 测试把关。规模：L（D0、D1、D5、D6 各 S）。需 hh 决定：无。

### B4 `StorageService` 脱离主线程（P1，M）

问题：见 §1.2。`StorageService` 标 `@MainActor`（`StorageService.swift:100-101`），不使用 AppKit 界面 API；每次调用两次主线程跳转；清理与删除在主线程逐文件 stat/lstat；外置大小缓存加了多余的锁；清理配置 `cleanupSettings`（`:202-210`，`:272`）与 `ClipboardService.settings` 重复，需要 `MainActor.run` 同步（`ClipboardService.swift:977-981`、`:1506-1510`）。

设计：

- `public actor StorageService`。状态型成员仍由这个 actor 隔离：`protectedExternalFilenameRefCounts`、`externalPayloadCommitGeneration`、`externalImageSourceLeaseReservations`（`:280-284`）与测试 interlock。读写它们的方法（`upsertItemWithOutcome` `:457`、`commitOptimizedExternalImagePayload` `:801`、`withExternalImageSourceLease` `:849`、`reconcileExternalImageSourceOwnership` `:888`、`cleanupOrphanedFiles` `:1521`）都是同一 actor 的方法，“取 generation 快照 → 枚举 → 比较”仍在同一串行执行器上。MainActor 与自定义 actor 都是在 `await` 处可重入的串行执行器，重入窗口与现在完全相同，现有 interlock 测试就是等价性证明。
- 为何不选“nonisolated 助手 + 小协调 actor”：状态与读取它的代码本就同处一个类型，拆出第二个 actor 只会增加跳转，而保护的仍是同一组不变量（硬约束 2）。
- `nonisolated`：不可变成员（`dbPath`、`rootDirectory`、`externalStoragePath`、`thumbnailCachePath`、`fileOps`、`repository`、`databaseFilePath`）与纯转发方法（`findByHash`、`findByID`、`fetch*`、`incrementUsage`、`updateNote`、`updateFileSizeBytes`、`updateItemPayload`、`compareAndSwapItemPayload`、`setPin`、`getItemCount`、`getTotalSize`、`removeIngestReceipt`、`loadPayloadData`、`getDatabaseFileSize`、统计类），这样调用方只跳一次（→ repository）。
- `init` 保持同步 nonisolated，`ClipboardService` 直接构造（删 `:908` 的 `MainActor.run`）。

实现步骤：

- S0（S）：删除外置大小缓存与 `NSLock`：`getExternalStorageSize` 直接读 `repository.getExternalSize()`（O(1) 的 `scopy_meta`，生产已走此路径），删 `invalidateExternalSizeCache` 的 8 处调用与目录扫描回退（折叠 `externalSizeMetaFastPathEnabled`，卫生审计已列）；目录扫描只留给设置页统计 `getExternalStorageSizeForStats`。
- S1（M）：改为 actor，按上表标注 nonisolated；测试中的 interlock setter 加 `await`；更新 `ClipboardService.swift:655-659` 的类型注释。
- S2（S）：`CleanupPolicy` 值类型（`maxItems`、`maxContentBytes`、`maxExternalBytes`、`imagesOnly`、`maxAge`）作为 `performCleanup(mode:policy:onCommitted:)` 的参数，由 `ClipboardService` 每次从 `settings` 构造（`:1522`、`:2422`）；删除 `CleanupSettings`/`cleanupSettings` 与两处 `MainActor.run`；测试 53 处 `cleanupSettings.x = …` 改为显式策略。
- 不做：repository 语句缓存、只读列表连接、提高 `busy_timeout`（理由见 §4）。

涉及文件：`StorageService.swift`、`ClipboardService.swift`、`SQLiteClipboardRepository.swift`（无接口变化）、约 10 个测试文件。

验证门禁：`make build`、`make test-unit`、`make test-strict`、`make test-tsan`（本机被跳过时以 `.github/workflows/tsan.yml` 托管运行为准）。

守护测试：
- `StorageCommitProtocolTests`（receipt 与孤儿 interlock）、`StorageServiceTests`（清理提交时复核、字节精度）、`ClipboardServiceImageOptimizationTests`（lease/reconcile/interlock）、`ClipboardServiceCleanupTests`、`ResourceCleanupTests`、`ConcurrencyTests` 全部保持通过。
- 新增 `StorageServiceExecutorTests.testCommitAndCleanupCompleteWhileMainThreadIsBlocked`：非 MainActor 测试类；用 `DispatchQueue.main.async { semaphore.wait() }` 阻塞主线程，在 detached 任务里依次做 upsert、删除、清理，5 s 截止。改前这里必然超时，改后通过——这正是要守住的性质。

风险：执行优先级不再固定为主线程 QoS，改为继承调用方（copy 路径为 userInitiated，actor 会做优先级提升）；测试改写量约 60 处。规模：M。需 hh 决定：无。

### B5 存储根单写者守卫（P1，S）

问题：

- Debug 与 Release 构建使用同一 bundle id（`project.yml:49`，`com.scopy.app`）与同一存储根（`StorageService.swift:347-368`：非测试运行一律 `Application Support/Scopy`，除非设置 `SCOPY_SERVICE_DB_PATH`，`AppState.swift:76-81`）。从 Xcode 运行 Debug 时若已安装的 Scopy 在运行，或 `open -n`，就会有两个进程写同一个库。
- 孤儿清理的保护是进程内的：`sharedExternalFileReservations` 注释即说明是 “Process-wide”（`StorageService.swift:93-96`），`protectedExternalFilenameRefCounts` 是实例状态（`:280-281`）。进程 A 的 `cleanupOrphanedFiles`（启动时 `ClipboardService.swift:1004-1006` 与每小时 full cleanup `StorageService.swift:1504`）会删除 `content/` 中数据库尚未引用的文件（`:1531-1570`），其中可能包括进程 B 已写好（`:515-575`）、尚未提交（`:582-638`）的新载荷；B 提交后行指向已删除文件。
- 两个进程轮询同一个 `.general` 剪贴板：同一次复制被采集两次（第二次去重为使用次数 +1），并共用同一个 `ingest/` spool。

设计：

```swift
// Scopy/Infrastructure/Persistence/StorageRootLock.swift
final class StorageRootLock {
    enum Failure: Error { case heldByAnotherProcess(root: String) }
    // 进程内注册表：规范化根路径 → (fd, refCount)，同进程重开（Retry、测试）共享同一把锁
    static func acquire(root: URL) throws -> StorageRootLock
    // open(root/.scopy-writer.lock, O_RDWR | O_CREAT | O_CLOEXEC, 0o600); flock(fd, LOCK_EX | LOCK_NB)
    // EWOULDBLOCK → .heldByAnotherProcess；进程崩溃由内核释放
    func release()
}
```

`StorageService.open()` 在 `repository.open()` 前获取，`close()` 释放。`AppState.start()`（`:178-201`）已有的 `StartupFailureView` 展示消息，Retry 在另一实例退出后可恢复。

守护测试：`StorageRootLockTests.testSecondOpenFileDescriptionCannotAcquire`（绕过注册表直接测原语：同进程两个独立 open 的 flock 互斥）、`testSameProcessReopenSharesLock`、`testLockReleasedOnClose`；可选 `testForeignProcessCannotAcquire`（`Process` 启动 `/usr/bin/python3 -c "fcntl.flock(...)"` 断言失败退出码）。

门禁：`make build`、`make test-unit`、`make test-strict`。规模：S。

需 hh 决定：第二实例的行为——(a) 显示启动失败（建议）；(b) 激活已有实例后退出。开发时运行 Debug 需设置 `SCOPY_SERVICE_DB_PATH`（或采纳 (b)）。

### B6 SQLite 结果码与完整性检查（P2，S）

问题：`SQLiteConnectionError`（`SQLiteConnection.swift:5-21`）与 `RepositoryError.queryFailed(String)`（`SQLiteClipboardRepository.swift:5-17`，`:1471-1487`）只保留消息字符串，丢了结果码；`ClipboardService` 9 处、`StorageService` 12 处以 `.private` 记录 `error.localizedDescription`，发布版 Console 全是 `<private>`；`ROLLBACK` 失败时 `recoverDatabase()`（`:1600-1603`）只是 close + open；损坏只会表现为零散的加载或采集失败。

设计：
1. 错误带码：`SQLiteConnectionError` 各 case 携带 `code: Int32 = sqlite3_extended_errcode(db)`；`RepositoryError` 改为 `.sqlite(code: Int32, message: String)`；`SQLiteResultCategory(code)` 映射为 `.busy/.full/.corrupt/.readonly/.ioerr/.constraint/.other`。
2. 日志：`ScopyLog.persistence.error("op=… code=\(code, privacy: .public) category=\(category, privacy: .public) message=\(message, privacy: .private)")`。这里需要启用目前零调用的 `persistence` 类别——与卫生审计“删除 `ScopyLog.persistence`”的建议冲突，以本条为准。
3. 完整性检查：`StorageIntegrity.checkIfDue(dbPath:)` 在独立只读连接上执行 `PRAGMA quick_check(1)`（WAL 读者不阻塞写者），由 `ClipboardService.start()` 启动后与 `cleanupOrphanedFiles` 同一个后台块（`:1004-1006`）以 utility 优先级调用；节流记录在旁路文件 `clipboard.db.integrity.plist`（`{checkedAt, ok, detail}`）：7 天一次；任何操作报告 `corrupt`/`notadb` 后下次启动立即检查。
4. 暴露：`StorageStatsDTO` 增加 `integrity`（上次检查时间与结果）。设置页如何提示由 hh 决定（前端）。

守护测试：`StorageIntegrityTests.testQuickCheckDetectsCorruptedPage`（临时库关闭后向一个 b-tree 页写入垃圾）、`testIntegrityCheckIsThrottled`、`testRepositoryErrorCarriesExtendedCode`（重复主键 → 1555 `SQLITE_CONSTRAINT_PRIMARYKEY`）、`testCorruptErrorSchedulesImmediateCheck`。

门禁：`make build`、`make test-unit`、`make test-strict`。成本：每周一次整库顺序读（≈146 MB）。规模：S。

需 hh 决定：检查失败时用户看到什么——建议设置 › 存储页显示警告与“在 Finder 中显示数据库”，不阻断启动。

### B7 缩略图缓存按引用清扫（P2，S）

问题：缩略图按内容哈希命名（`<hash>.png`、`file_<hash>.png`，`StorageService.swift:2308-2310`，`ClipboardService.swift:2771-2774`），条目删除、清理、清空后都不删除；唯一的删除是设置变更时整体 `clearThumbnailCache`（`StorageService.swift:2426-2433`）。平均 ≈6.6 KB/个（快照副本 182 个 1.2 MB），增长量等于被删除的 image/file 条目中生成过缩略图的数量。

设计：`performCleanup(.full)` 在孤儿清理之后（`:1503-1505`）调用 `cleanupOrphanedThumbnails()`：
1. `referenced = try await repository.fetchThumbnailContentHashes()`：`SELECT DISTINCT content_hash FROM clipboard_items WHERE type IN ('image','file')`（查询计划走 `idx_type_recent`）。
2. detached 枚举 `thumbnails/`，只处理严格匹配 `^(file_)?[0-9a-f]{64}\.png$` 的文件名，哈希不在集合中即删除；其他文件名一律不碰。
3. 与生成并发时可能删掉刚为新行生成的缩略图：它是可再生缓存，`ThumbnailCacheIndex.pathIfExists` 会复查存在性（`ClipboardService.swift:800-813`）并重新调度生成。因此不需要引用计数或事务（硬约束 2）。

守护测试：`ThumbnailSweepTests.testFullCleanupRemovesOnlyUnreferencedThumbnails`（删除图片 A、保留图片 B 与文件 C、异名文件不动）、`testSharedContentHashKeepsThumbnail`。门禁：`make build`、`make test-unit`。规模：S。需 hh 决定：无。

### B8 退出落盘与进程生命周期（P2，S；需 hh 决定）

现状（逐条核实）：

- 退出：`applicationWillTerminate`（`AppDelegate.swift:285-295`）→ `AppState.stop()`（`AppState.swift:208-215`）→ `RealClipboardService.stop()` 发出不等待的 Task（`RealClipboardService.swift:33-37`）→ `ClipboardService.stop()`（`:1017-1054`）来不及执行，`search.close()` 中的两次落盘（`SearchEngineImpl.swift:1004-1016`）不发生。实测：退出 0.23 s 返回，缓存 mtime 不变，下次启动短索引未命中，多 ≈1.4 s 后台 CPU。已提交的 WAL 不受影响（D1）。
- §8.1 事件流：`eventStream` 仍在 `init` 中以 `AsyncStream(unfolding:)` 创建一次（`ClipboardService.swift:876-878`），消费者被取消时 `dequeue()` 返回 nil（`:489`、`:555-559`），流永久结束。产品入口仍然没有：只有退出会取消监听（`AppState.swift:208-210`）；启动失败后的 Retry（HEAD `ContentView.swift:24-27`）不会触发，因为监听只在启动成功后才开始（`AppState.swift:189-196`），失败的那次从未消费过这条流。
- 轮询：`installMonitoringTimer`（`ClipboardMonitor.swift:1084-1095`）未设 `tolerance`，每 tick 分配一个 Task——属于采集面。
- 睡眠/锁屏：系统睡眠时计时器本就不触发；锁屏时 500 ms 计时器继续运行（每秒 2 次唤醒）。空闲实测 0.04% 核，不值得为此加暂停机制。
- 内存压力：无响应 → B2c。

设计 A（仅当 hh 要求退出后缓存必新鲜时采用）：

```swift
// AppDelegate
func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if terminationReplyPending { return .terminateLater }        // 幂等
    terminationReplyPending = true
    Task { @MainActor in
        await appState.persistForTermination(deadline: .seconds(1))
        NSApp.reply(toApplicationShouldTerminate: true)
    }
    return .terminateLater
}
// AppState → service.persistForTermination(deadline:) → ClipboardService → search.persistIndexCaches(deadline:)
// SearchEngineImpl.persistIndexCaches：短索引与（就绪时的）全量索引，seq 未变则跳过；withTimeout 约束总时长；复用 B2b 的落盘函数
```

只做唯一有价值的动作（落盘），不做完整 stop：缩略图与 QuickLook 工作可能无法及时取消。`applicationWillTerminate` 保持不变。

守护测试：`SearchEngineTerminationPersistTests.testPersistWritesCurrentMutationSeq`、`testPersistIsBoundedByDeadline`（DEBUG 钩子延迟写入）、`testPersistSkipsWhenCachesAreCurrent`。手工证据：`osascript -e 'quit app "Scopy"'` 后缓存 mtime 更新，下次启动日志出现 `Short index disk cache load hit`；Sparkle 安装重启与注销各验证一次。

方案 B（空闲周期落盘，退出时不等待）不建议：每个安静期写 14.7 + 24.7 MB，换来的只是每次启动 ≈1.4 s 后台 CPU。

§8.1 若将来引入同进程 stop→start，最小修复为：协议的 `var eventStream` 改为 `func makeEventStream() -> AsyncStream<ClipboardEvent>`，`ClipboardService` 以 `nonisolated func makeEventStream()` 每次包一条新的 `AsyncStream(unfolding: { [eventQueue] in await eventQueue.dequeue() })`，并注明单消费者；配测试 `testEventsFlowAfterListenerRestart`。本提案的所有设计都刻意避免 stop→start（例如 B2c 只裁剪不重启），因此建议继续暂缓。

建议：采集面加计时器 `tolerance`（一行，交采集评审）；§8.1、§8.2 保持暂缓，除非 hh 选择 A。规模：A 为 S。门禁（若做 A）：`make build`、`make test-unit`、`make test-strict`，外加上述手工证据。

## 3. 可读性与命名

只列“名字在误导读者”的情况；调用点为 `rg` 统计（源码 / 测试 / 文档脚本）。

| 名字 | 位置 | 误导在哪 | 改法 | 调用点 |
| --- | --- | --- | --- | --- |
| `SearchCoverage.isPrefilter` | `SearchCoverage.swift:9-11`；用于 `SearchMatchContextBuilder.swift:399/:582/:631` | 对 `.recentOnly` 也为真，使 regex 与 ≤2 字符 exact 每次搜索都新开内存 SQLite 并建 fts5 tokenizer（`:143-224`）却不用；`development-guide.md:83` 写的是“staged coverage” | 删除该属性，三处改用 `isStagedRefine`（仅省掉无用 tokenizer，输出不变）；同步 dev guide | 4 / 0 / 1 |
| `observedMutationCounter` | `SearchEngineImpl.swift:886` | 数的是回调不是提交 | 删除（B1） | 7 / 0 / 0 |
| `knownDBChangeToken`、`usesMutationSeq` | `:875-876` | “token”可能是 `data_version`，那是产品不可达的兼容路径 | B3-D3 删分支后改名 `knownMutationSeq` | 14 + 8 / 0 / 0 |
| `CleanupSettings.maxSmallStorageMB` 与注释 “By space (small content / database)” | `StorageService.swift:205`、`:1444` | 实际比较的是含外置字节的 `total_size_bytes` | B4-S2 中改为 `CleanupPolicy.maxContentBytes`，注释改正 | 5 / 13 / 0 |
| `maxLargeStorageMB` | `StorageService.swift:206` | 是外置存储上限（硬编码 800） | `maxExternalBytes` | 2 / 14 / 0 |
| `externalPayloadCommitGeneration` | `StorageService.swift:281` | 在开始与结束保护文件名时推进，不是“提交代数” | `protectedPayloadEpoch` | 6 / 0 / 0 |
| `FullIndexDiskCacheLoadReason.fingerprintMismatch`（`"fingerprint_mismatch"`） | `SearchEngineImpl.swift:274` | 指纹早已改为 `mutation_seq` | `mutationSeqMismatch` / `"mutation_seq_mismatch"` | 5 + 1 / 1 / 0 |
| `FullIndexDiskCacheV4`、`ShortQueryIndexDiskCacheV2`、`FullIndexDiskCacheMetadataV2` | `SearchIndexDiskCache.swift:35-50`、`SearchEngineImpl.swift:283` | 类型名里的版本号与磁盘版本（full v5、short v3、metadata v2）不一致 | `FullIndexDiskPayload`、`ShortIndexDiskPayload`、`FullIndexDiskMetadata`，版本只留在常量 | 4 / 10 + 1 / 12 |
| `SearchPlanner`、`SearchPlan*` | `SearchPlanner.swift` | 名为 planner，实际只产诊断，路由在引擎 | B3-D0 删除计划部分，余下为 `SearchQueryText` | 9 + 8 / 20 / 2 |
| `fullIndexGeneration` | `SearchEngineImpl.swift:885` | 与 5 个“任务身份/作废纪元”式的 generation 同名，它其实是索引内容版本（排序缓存键） | `fullIndexContentVersion` | 3 / 0 / 0 |
| “publication” 的三种含义 | 事件水位 `ClipboardEventQueue.PublicationToken`；文件发布 `releaseExternalPublicationGuards`（`StorageService.swift:705`）；搜索同步（`ClipboardService.swift:2011` 注释、`beforeSearchPublication`） | 同一个词指三个不相关协议 | 保留事件水位的用法；文件侧改称 placement（`releaseExternalPlacementGuards`）；搜索侧注释改称 search sync，`beforeSearchPublication` → `beforeAuthoritativePublish` | 5 + 2 / 2 / 0 |
| 日志类别 | `ClipboardService` 用 `ScopyLog.app` 记录存储/采集失败（`:2232`、`:2429`、`:2672`、`:2725`、`:2790`） | 类别与子系统不符 | 存储类失败改 `storage`；SQLite 结果码用 `persistence`（B6） | 5 / 0 / 0 |

`receipt`、`envelope`、`outcome`、`plan/commit`、`tombstone` 在后端各处含义一致，不需要改。

注释/文档与代码不一致：
- `development-guide.md:83`：`isPrefilter` 的描述与代码不符（见上）。
- `development-guide.md:80`、`:235`：`SearchPlanner.planExact` 与执行共享规范化——D0 后改为 `SearchQueryText.normalizedExactQuery`。
- `development-guide.md:121`：清理后“invalidates … search state”——B1 后改为按提交集维护索引。
- `ClipboardService.swift:655-659`：称 `StorageService` 为 `@MainActor`——B4 后更新。
- `SearchIndexDiskCache.swift:489-491`：“never migrated by StorageService 的库不参与缓存”——D3 要求当前 schema 后删除。

## 4. 明确不做

- VACUUM / `auto_vacuum=INCREMENTAL` / `journal_size_limit` / 定时 checkpoint：freelist 0.56%，系统默认已限制 WAL（§1.5）。`WAL > 128 MB` 截断分支建议随卫生清理删除，而不是扩展。
- repository 语句缓存与只读列表连接：一次采集 ≈8-12 次 prepare，每次 10-20 µs，合计 <0.25 ms；采集 12 次实测总 CPU 0.328 s、点击复制 7-9 ms，没有可见收益。主线程耦合由 B4 解决。
- 提高 `busy_timeout`：单写者架构下只有第二个进程才会遇到 BUSY，根因由 B5 消除。
- 把引擎 SQL 搬进 repository actor：会被 `sqlite3_interrupt` 波及并与写事务互相排队（B3）。
- 每条只索引前 N KB、`preview_text` 列、`plain_text` 上限（旧 §4.1/§5.6）：改变召回语义，且与冻结的“规范文本”决策相关；数据已在 B2 给出，由 hh 决定。
- 2/3-gram 统一索引（旧 §5.6）、短索引 CSR 化（可再省 ≈17 MB）：先完成 B2 并实测，再决定是否 spike。
- 内容预算是否只计内联字节、800 MB 外置上限是否进设置（旧 §4.6）：产品语义，只做 §3 的改名。
- `ingest_receipts` 按时间回收：快照 0 行，ack 与启动恢复都会删除；若日后出现积累，只能删除 spool 中已无 pending/terminal 工件的 receipt（否则会破坏“回放不重复施加”）。
- 全部 pinned 的清理：不存在空转（§1.6）。
- 事件流重订阅（§8.1）：无产品入口，最小修复已写在 B8，暂缓。
- 锁屏/睡眠暂停轮询：收益低于噪声（空闲 0.04% 核）；只建议 `tolerance`。
- 六个 continuation 队列收敛成一个原语（旧 §8.5）：现有实现正确，收敛风险大于收益；D6 只做文件移动。
- 把 57 处 `.private` 改为 `.public`（旧 §8.7）：否决，改为公开记录结果码（B6）。
- 任何 `hash_version`、双读、legacy decoder、哈希公式变更：冻结事项。

## 5. 实施顺序与依赖

| 顺序 | 条目 | 依赖 | 门禁（AGENTS.md） |
| ---: | --- | --- | --- |
| 1 | B3-D0 死代码删除 | 无 | build、unit、strict；docs-validate |
| 2 | B1 精确索引维护 | 无 | build、unit、strict、snapshot perf |
| 3 | B2a `UInt32` postings、`IndexedItem` 瘦身（缓存 v6） | 无 | build、unit、snapshot perf、perf-search-warm-load |
| 4 | B5 单写者守卫 | hh 决定第二实例行为 | build、unit、strict |
| 5 | B4 S0 → S1 → S2 | 无（先于 B6、B7，避免冲突） | build、unit、strict、TSan |
| 6 | B3 D1 → D2 → D3 → D4 → D5 → D6 | D0 | 每步 build、unit、strict；D2/D3/D4 加 snapshot perf；D4 加 TSan |
| 7 | B2b → B2c | B1（批量删除作为 pending 事件）；建议在 D4 之后 | build、unit、strict、TSan、snapshot perf、perf-search-warm-load、perf-unified-table、test-tooling；footprint 记录 |
| 8 | B6、B7 | B4 | build、unit、strict |
| 9 | B8（方案 A） | hh 决定；复用 B2b 的落盘函数 | build、unit、strict + 手工退出证据 |

性能门禁一律使用新鲜的 `make snapshot-perf-db` 副本；任何性能结论按 AGENTS.md 记录环境、场景、实际数字与因果限制。需要 hh 决定的事项：B2 的空闲阈值与“每条前 N KB”；B5 第二实例的行为与开发流程；B6 失败时的用户提示；B8 是否采用 `.terminateLater`。
