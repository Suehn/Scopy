# 验收与回滚手册（2026-02-28）

## 1. 验收门禁（必须全部通过）
```bash
make build
make test-unit
make test-strict
make test-perf
make test-perf-heavy
make test-snapshot-perf
make test-snapshot-perf-release
bash scripts/perf-audit.sh --bench-metrics --strict
bash scripts/perf-frontend-profile.sh --db perf-db/clipboard.db --repeats 3
bash scripts/perf-unified-table.sh \
  --backend-baseline logs/perf-audit-<baseline> \
  --backend-current logs/perf-audit-<current> \
  --frontend-summary logs/perf-frontend-profile-<run>/frontend-scroll-profile-summary.json \
  --out logs/perf-unified-<run>.md
```

## 2. 核心验收指标（本轮基线）
1. External cleanup 10k：<= 1800ms（当前 1019.45ms）。
2. Snapshot Debug query=cm：<= 150ms（当前 75.47ms）。
3. Release bench：
- cmd p95 <= 50ms（当前 0.180ms）
- cm p95 <= 20ms（当前 5.833ms）
4. Frontend 真实场景 scroll/profile（real-snapshot-*）：
- frame p95 <= 25ms（当前 16.667~25.000ms）
- drop_ratio <= 0.05（当前 0.015~0.042）
5. 所有测试日志必须出现 `** TEST SUCCEEDED **`。

> 说明：`SCOPY_SNAPSHOT_STRICT_SLO=1` 在 Debug 构建中不会启用 strict 断言；strict target 仅在 Release 基准路径生效。

## 3. 功能不变验收
1. 搜索结果集合/排序/分页一致性用例必须通过。
2. Settings Save/Cancel 与 hotkey 语义用例必须通过。
3. cleanupImagesOnly 与 pinned 保护语义必须通过。

## 4. 失败判定（任一触发即 NO-GO）
1. 任一门禁命令非 0。
2. 端到端 query=cm P95 超过 150ms 且可复现。
3. heavy cleanup 回退超过 15% 且可复现。
4. 出现用户可见行为回归或交互变化。

## 5. 回滚策略
1. 所有实施项必须挂 feature flag，默认旧路径。
2. 发布阶段先灰度打开，观测不达标立即关 flag。
3. 任何语义风险改动必须提供“一键恢复旧逻辑”开关。
4. 回滚后立即重跑上方门禁矩阵并存档日志。
