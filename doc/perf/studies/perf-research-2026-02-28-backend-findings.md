# 后端性能研究发现（2026-02-28）

## 1. 观察摘要
后端核心搜索路径在 Release 模式下已具备很强性能余量。
证据（ScopyBench release）：
- Engine：`cm p95=6.055ms`，`数学 p95=11.458ms`，`cmd p95=0.123ms`
- Service：`cm p95=5.171ms`，`数学 p95=11.333ms`，`cmd p95=0.118ms`

## 2. 热点清单（按优先级）

### P0. External cleanup 仍受 I/O 与流程结构影响
证据：
- `External Cleanup Performance (10k items): 1019.45ms`（`logs/test-perf-heavy-after-fix.log`）
主要位置：
- `Scopy/Services/StorageService.swift`：`performCleanup`、`cleanupByCount`、`cleanupExternalStorage`、`getExternalStorageSize` / `calculateDirectorySize`
- `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`：`planCleanupExternalStorage(..., excludingIDs:)`、`sumExternalBytes(ids:)`、`deleteItemsBatchInTransaction`
研究判断：
1. 组合清理已避免“count + external”重叠选集，但文件删除 I/O 仍是主耗时来源。
2. 已将 count plan 释放字节估算改为 DB 聚合，避免 9k 文件 `stat` 扫描；仍需持续观测磁盘抖动。
3. 批量删除并发参数在不同磁盘类型下仍有精细化空间。

### P1. SearchEngine 长路径有复杂度压力点，但当前基线可控
主要位置：
- `Scopy/Infrastructure/Search/SearchEngineImpl.swift` 中：`fts_prefilter`、short-query paths、full-index prefilter / candidate sort、offset+limit 分页窗口裁剪。
研究判断：
1. 当前 release 数据下余量充足，但在更大库与长查询组合下仍需防止 O(n log n) 排序放大。
2. 需要持续观测 `full_index_prefilter_candidate_slots` 与 `short_query_short_index_candidates` 指标。

### P1. SQL 与分页路径的一致性成本
主要位置：
- `SQLiteClipboardRepository` 的 `fetchRecent/searchWithFTS` 等 offset 分页路径。
研究判断：
- 大 offset 时仍需关注查询执行计划与回表成本，建议保留 benchmark 覆盖。

## 3. 本轮量化结论
1. Release 搜索性能（engine/service）已达低毫秒级。
2. heavy cleanup 已收敛到 ~1.0s 量级（10k 外部项），相比失败样本 1918ms 显著改善。
3. perf-audit 全流程通过，说明当前实现在稳定性与性能上可作为优化起点。

## 4. 后端实施候选（仅研究结论）
1. 清理合并规划：减少多阶段重复清理与重复遍历。
2. external size 元数据增量维护：替代频繁目录全扫描。
3. cleanup plan 批次与并发策略精细化：在 I/O 瓶颈下稳态提速。
4. 搜索候选裁剪与 top-k 策略回归压测：防止数据规模扩大后退化。
