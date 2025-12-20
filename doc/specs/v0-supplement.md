# v0 补充设计：稳定性与性能提升（无功能变更）

**目标**：在不改变 v0 功能与对外接口的前提下，提升稳定性与端到端性能；避免主线程阻塞、任务泄漏和不必要的 I/O。所有改进均基于当前实现和 v0 规范复核后提出。

## 设计原则
- 不改动协议/接口语义，不改变现有功能和行为预期。
- 主线程只做 UI 与轻量状态变更；I/O、哈希、文件扫描全部后台化。
- 优先用结构化并发与事务批处理，避免泄漏与写放大。
- 排序与过滤与 v0 约定保持一致（Pinned 优先，其次时间/命中顺序）。

## 改进建议

### 1) 存储层（StorageService / RealClipboardService）
- **外部存储/统计后台化，增量计数**  
  - 现状：`getExternalStorageSizeForStats` 在主线程全量枚举文件 (`StorageService.swift` ~528-590)，`RealClipboardService.start` 同步调用，首屏加载会阻塞 UI。  
  - 建议：将统计放到后台 Task，完成后回主线程更新；维护总大小/外部大小的增量计数（insert/delete/cleanup 时更新），定期或开关触发时再做全量校验。
- **Orphan 清理异步化**  
  - 现状：启动时在 `@MainActor` 调用 `cleanupOrphanedFiles`，内部 `DispatchGroup.wait()` 阻塞 (`RealClipboardService.swift` ~57-86, `StorageService.swift` ~639-740)。  
  - 建议：改为 `async` + `withTaskGroup` 在后台执行，启动阶段只触发任务，不阻塞主线程。
- **复合索引补齐**  
  - 现状：仅 `idx_type`，type 过滤还需按 `last_used_at` 排序 (`StorageService.swift` ~209-217)。  
  - 建议：增加 `(type, last_used_at DESC)` 复合索引，减少排序 + 回表。
- **事务与写放大控制**  
  - 已有批量删除事务；建议将清理各步骤（count/age/space/external/housekeeping）包裹在单事务或串行批处理，避免多次 fsync。
- **缩略图/外部文件 I/O 后台化**  
  - 现状：缩略图清理/生成和外部写入在主线程可被调用。  
  - 建议：统一通过后台队列执行，主线程只接收路径结果；文件写失败时记录日志并不中断主流程。

### 2) 搜索层（SearchService）
- **Pinned 优先的稳定排序**  
  - 现状：非空查询 FTS 主表阶段仅按 bm25 顺序，忽略 pinned (`SearchService.swift` ~223-226)。  
  - 建议：在主表结果按 `(is_pinned DESC, ftsOrder, last_used_at DESC)` 稳定排序；或 SQL `ORDER BY is_pinned DESC, CASE ...` 保留命中顺序。
- **预编译 SQL + 内存排序，移除动态 CASE 拼接**  
  - 现状：每次拼接 `CASE WHEN rowid ...` 字符串。  
  - 建议：主查询 SQL 预编译为模板；取回后用 `rowid → order` 映射在内存排序，减少解析开销并提升安全性。
- **结构化并发超时**  
  - 现状：`runOnQueueWithTimeout` 用 detached 任务 + 手动取消 (`SearchService.swift` ~448-469)，存在泄漏风险。  
  - 建议：改为 `withThrowingTaskGroup`/`withTimeout` 封装，确保超时和子任务统一取消。
- **缓存刷新读写分离**  
  - 现状：`NSLock` 独占，短查询可能阻塞 (`SearchService.swift` ~317-334)。  
  - 建议：读写锁或双缓冲（刷新到副本，再无锁切换指针），降低热点锁竞争。

### 3) UI/状态（AppState / Views）
- **Pinned/Unpinned 结果缓存与失效**  
  - 现状：每次访问都 O(n) 过滤 (`AppState.swift` ~41-47)，`HistoryListView` 多次访问同属性。  
  - 建议：维护缓存并在 items 变更时失效，避免重复遍历。
- **存储统计后台化与节流**  
  - 现状：首屏/设置变更在主线程同步计算 (`AppState.swift` ~284-299 调用 `getStorageStats`)。  
  - 建议：在后台计算并节流更新 UI；与增量计数结合，减少频繁全量扫描。
- **启动/事件重工作业后台化**  
  - 启动的 orphan 清理、图标预加载、缩略图生成都应放在后台队列，并在主线程仅做状态合并。

### 4) 观测与防护
- **错误可观测性**  
  - 对当前 `try?` 静默路径（如 `RealClipboardService` 更新、文件删除）至少输出日志标签，便于排查而不改变用户流程。
- **回压与熔断策略**  
  - 当后台队列积压或磁盘超阈值时，暂停新写入/缩略图生成，提示状态；恢复后自动重试。  
  - 这些策略在逻辑上只增加保护，不改变正常功能路径。

## 兼容性说明
- 所有建议均保持 v0 接口/行为一致，不涉及新增对外 API。  
- 排序调整（Pinned 优先）与 v0 规范一致，可视为一致性修正。  
- 后台化与缓存/增量计数仅优化执行路径，不影响结果正确性。  
- 引入后台任务需使用结构化并发，避免新增泄漏点；事务范围需与现有迁移/清理顺序兼容。

## 已落实（v0.16）
- 搜索：Pinned 优先排序一致性、mainStmt 安全访问、结构化超时、缓存排序、removeLast 优化。  
- 剪贴板：流关闭守卫、强制解包移除。  
- 存储：外部/缩略图统计后台化、文件删除异步、生成缩略图尺寸校验、TTL 180s、`idx_type_recent` 复合索引、溢出保护。  
- 状态：pinned/unpinned 缓存与失效、负值格式化防护、stop 取消任务。  
- 启动：孤儿清理后台执行。
