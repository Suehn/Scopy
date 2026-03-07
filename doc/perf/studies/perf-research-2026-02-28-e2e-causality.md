# 端到端因果链分析（2026-02-28）

## 1. 分析目标
解释“同一功能在不同模式/链路下的性能差异”，明确主要耗时属于前端、后端还是环境配置。

## 2. 因果链 A：输入搜索（query=cm）
链路：
1. Header 输入变更触发 search 请求。
2. HistoryViewModel 组织请求与任务调度。
3. SearchEngine 执行 short-query path（short index / SQL fetch / prefilter）。
4. Service 返回 DTO。
5. SwiftUI List 应用 items 更新并重绘。

证据：
- Debug Snapshot：P95 ~75ms（端到端）
- Release Bench（Service）：P95 ~5.17ms
推断：
- 当前主要差异来自 debug 与 release 执行配置，以及 UI 层刷新成本叠加，而非后端算法能力不足。

## 3. 因果链 B：heavy cleanup（10k）
链路：
1. 触发 `performCleanup`。
2. 计划删除集合（count/size/external 规则）。
3. DB transaction 批量删除。
4. 外部文件并发删除。
5. external size 统计与缓存失效处理。

证据：
- `logs/test-perf-heavy-after-fix.log`：external cleanup 10k = 1019.45ms（通过）
推断：
- 主要成本仍在文件系统 I/O + 清理流程结构；算法层优化空间次于 I/O 组织优化。

## 4. 因果链 C：Release 校验链路
链路：
1. `make test-snapshot-perf-release` 使用 ScopyBench release。
2. 同库同 query 跑 cmd/cm。
3. shell 断言 p95 阈值。

证据：
- cmd 0.180ms，cm 5.833ms，均明显低于阈值。
结论：
- Release 性能门禁链路已稳定，可作为持续集成的真实体验代理信号。

## 5. 结论
1. 短查询端到端主要是“调度 + 渲染 + debug 配置”叠加成本。
2. heavy cleanup 主要是 I/O 路径和流程编排成本。
3. 后续优化优先级应按“用户体感贡献 × 风险”排序，而非单点微优化。
