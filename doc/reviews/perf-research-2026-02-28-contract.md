# Scopy 性能研究契约（2026-02-28）

## 1. 目标
在功能稳定、用户无感前提下，持续压缩前后端性能开销，输出可落地优化路线与门禁。

## 2. 固定输入
- 研究分支：`research/perf-stability-front-back-2026-02-28`
- 研究日志目录：`logs/perf-research-2026-02-28`
- 基线环境：`logs/perf-research-2026-02-28/env.txt`
- 样本库：`perf-db/clipboard.db`

## 3. 功能不变契约（必须保持）
1. 搜索语义不变：同 query/mode/sort/filters 下，结果集合与顺序一致（允许稳定 tie-breaker，但不可改变可见语义）。
2. 分页行为不变：offset/limit 语义保持，不出现“旧请求结果混入新请求”。
3. Settings 行为不变：Save/Cancel 事务模型保持，外部更新合并语义不变。
4. 热键行为不变：单次按键触发一次，不出现重复触发。
5. 清理行为不变：Pinned 保护语义、cleanupImagesOnly 语义、DB 与外部文件一致性语义不变。
6. UI 可见行为不变：无新增可见 loading 抖动、无新交互步骤、无视觉回归。

## 4. 性能研究验证契约
必须完整执行以下矩阵并保留日志：
1. `make build`
2. `make test-unit`
3. `make test-perf`
4. `make test-perf-heavy`
5. `make test-snapshot-perf`
6. `SCOPY_SNAPSHOT_STRICT_SLO=1 make test-snapshot-perf`
7. `make test-snapshot-perf-release`
8. `bash scripts/perf-audit.sh --bench-metrics --strict`
9. Release 分层 Bench（engine/service，query=`cm/数学/cmd`）

## 5. 本轮基线结论（证据）
- 全部步骤 exit code = 0（见 `logs/perf-research-2026-02-28/summary.txt`）。
- 所有核心测试均 `** TEST SUCCEEDED **`（同上）。
- 关键数值：
  - External cleanup 10k：`1019.45ms`
  - Snapshot Debug `cm` P95：`75.47ms`
  - Snapshot Strict 请求下（Debug）`cm` P95：`74.38ms`
  - Release bench：`cmd=0.180ms`，`cm=5.833ms`

## 6. 研究边界
- 本轮仅做研究与文档沉淀，不引入功能变更。
- 若进入实现阶段，必须先加 feature flag 与回滚点，再做默认路径切换。
