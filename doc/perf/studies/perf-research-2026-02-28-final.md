# Scopy 前后端性能研究最终报告（2026-02-28）

## 1. 执行结果
本次研究计划已完整执行，且实验矩阵全部通过。
证据目录：`logs/perf-research-2026-02-28`。
统一同表：`logs/perf-unified-2026-02-28-front-back-final.md` / `logs/perf-unified-2026-02-28-front-back-final.json`。

## 2. 关键结论
1. 当前代码在 Release 维度下的搜索性能充足（cm ~5ms，数学 ~11ms，cmd ~0.1ms）。
2. 当前用户体感风险主要来自：
- Debug 端到端短查询刷新链路（仍有进一步优化空间）。
- cleanup 大批量 I/O 路径（已达标，但仍可进一步稳态压缩）。
3. 继续优化应以“无感稳定优先”：先压 UI 更新与调度抖动，再压清理流程结构成本。
4. 前端真实场景滚动 profile 呈现“分场景改善 + 局部回退”：
- mixed：frame p95 25.000ms -> 16.667ms（-33.33%），drop ratio 0.029 -> 0.015（-48.15%）
- accessibility：frame p95 持平（25.000ms），但 drop ratio 0.024 -> 0.042（有回退）
- text-bias：frame p95 16.667ms -> 25.000ms（有回退），drop ratio 基本持平（0.020 -> 0.020）

## 3. 已确认基线
- External cleanup 10k：1019.45ms
- Snapshot Debug cm P95：75.47ms
- Snapshot strict 断言：仅 Release 路径生效（Debug 下保持默认 SLO）
- Release bench：cmd 0.180ms / cm 5.833ms
- 测试状态：build/unit/strict/heavy/snapshot-release 均通过（见 logs/gate-*.log 与 logs/test-perf-heavy-after-fix.log）

## 4. 推荐实施顺序（可直接进入开发）
1. Phase 1：前端低风险优化（行级索引、写回短路、resolver 缓存、任务预算）。
2. Phase 2：后端结构优化（cleanup 合并规划、external size 增量维护）。
3. Phase 3：大规模场景专项优化（top-k 与候选裁剪，硬件自适应）。

## 5. 实施约束
1. 不改变任何用户可见语义。
2. 每项改动都要有 feature flag 和回滚路径。
3. 每阶段必须跑完整门禁并落日志。
4. 性能提升声明必须附基线对比与重复测量结果。

## 6. 文档索引
- 契约：`doc/reviews/perf-research-2026-02-28-contract.md`
- 前端发现：`doc/reviews/perf-research-2026-02-28-frontend-findings.md`
- 后端发现：`doc/reviews/perf-research-2026-02-28-backend-findings.md`
- 因果链：`doc/reviews/perf-research-2026-02-28-e2e-causality.md`
- 路线图：`doc/reviews/perf-research-2026-02-28-roadmap.md`
- 验收手册：`doc/reviews/perf-research-2026-02-28-acceptance.md`
