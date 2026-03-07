# 前后端统一量化对比（2026-02-28）

## 数据来源
- 后端 baseline：`logs/perf-audit-2026-02-28_01-49-15`
- 后端 current：`logs/perf-audit-2026-02-28_02-38-45`
- 前端真实场景 profile：`logs/perf-frontend-profile-2026-02-28-final`
- 统一合表产物：`logs/perf-unified-2026-02-28-front-back-final.md` / `logs/perf-unified-2026-02-28-front-back-final.json`

## 前端采样口径（非玩具）
- 数据源：真实 snapshot DB（`perf-db/clipboard.db`，通过 UI test real service 注入）
- 场景：`real-snapshot-accessibility` / `real-snapshot-mixed` / `real-snapshot-text-bias`
- 运行：baseline/current 交错各 3 轮（共 6 轮）
- 每轮时长：10s
- 最低帧样本：260
- 指标：`frame_p95_ms`、`drop_ratio`、`text.metadata_ms.p95`、`image.thumbnail_decode_ms.p95`

## 统一同表（后端 + 前端）
| Domain | Metric | Baseline | Current | Delta | Change | Unit |
|---|---|---:|---:|---:|---:|---:|
| backend | backend.engine.cm.p95_ms | 5.184 | 5.170 | -0.014 | -0.27% | ms |
| backend | backend.engine.math.p95_ms | 9.002 | 8.696 | -0.306 | -3.40% | ms |
| backend | backend.engine.cmd.p95_ms | 0.115 | 0.117 | 0.002 | 1.76% | ms |
| backend | backend.engine.cm.force_full_fuzzy.p95_ms | 5.143 | 6.439 | 1.296 | 25.20% | ms |
| backend | backend.engine.abc.force_full_fuzzy.p95_ms | 2.554 | 2.483 | -0.071 | -2.78% | ms |
| backend | backend.engine.cmd.force_full_fuzzy.p95_ms | 2.793 | 7.217 | 4.424 | 158.40% | ms |
| backend | backend.service.cm.p95_ms | 5.146 | 5.850 | 0.704 | 13.68% | ms |
| backend | backend.service.math.p95_ms | 14.669 | 9.652 | -5.017 | -34.20% | ms |
| backend | backend.service.cmd.p95_ms | 0.195 | 0.114 | -0.081 | -41.50% | ms |
| backend | backend.service.cm.no_thumb.p95_ms | 9.276 | 5.085 | -4.191 | -45.18% | ms |
| frontend | frontend.frame.p95_ms[real-snapshot-accessibility] | 25.000 | 25.000 | 0.000 | 0.00% | ms |
| frontend | frontend.drop_ratio[real-snapshot-accessibility] | 0.024 | 0.042 | 0.017 | 70.49% | ratio |
| frontend | frontend.text.metadata.p95_ms[real-snapshot-accessibility] | 1.120 | 1.763 | 0.643 | 57.42% | ms |
| frontend | frontend.image.thumbnail_decode.p95_ms[real-snapshot-accessibility] | - | - | - | - | ms |
| frontend | frontend.frame.p95_ms[real-snapshot-mixed] | 25.000 | 16.667 | -8.333 | -33.33% | ms |
| frontend | frontend.drop_ratio[real-snapshot-mixed] | 0.029 | 0.015 | -0.014 | -48.15% | ratio |
| frontend | frontend.text.metadata.p95_ms[real-snapshot-mixed] | 1.750 | 1.117 | -0.633 | -36.18% | ms |
| frontend | frontend.image.thumbnail_decode.p95_ms[real-snapshot-mixed] | - | - | - | - | ms |
| frontend | frontend.frame.p95_ms[real-snapshot-text-bias] | 16.667 | 25.000 | 8.333 | 50.00% | ms |
| frontend | frontend.drop_ratio[real-snapshot-text-bias] | 0.020 | 0.020 | 0.001 | 4.54% | ratio |
| frontend | frontend.text.metadata.p95_ms[real-snapshot-text-bias] | 1.118 | 1.129 | 0.011 | 0.97% | ms |
| frontend | frontend.image.thumbnail_decode.p95_ms[real-snapshot-text-bias] | - | - | - | - | ms |

## 读表说明
- 前端 `image.thumbnail_decode_ms.p95` 在本轮 baseline/current 都为 `-`，表示采样窗口内没有拿到该 bucket 的有效样本，而不是 0ms。
- 对于同一指标，负变化（Delta < 0）表示 current 优于 baseline。
- 该表反映“真实滚动场景 + feature flags baseline/current 对照”的结果：mixed 场景明显改善，accessibility/text-bias 仍有优化空间。
