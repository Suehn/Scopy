# 前端性能研究发现（2026-02-28）

## 1. 观察摘要
本轮基线下，前端端到端表现优于此前波动值，但仍存在可压缩的结构性成本。
证据：
- Snapshot Debug `query=cm` P95 = `75.47ms`（`logs/perf-research-2026-02-28/test_snapshot_perf.log`）
- Snapshot Strict 请求（Debug）`query=cm` P95 = `74.38ms`（`logs/perf-research-2026-02-28/test_snapshot_perf_strict.log`）

## 2. 热点清单（按优先级）

### P0. 列表更新路径仍有多处 O(n) 查找/替换
主要位置：
- `Scopy/Observables/HistoryViewModel.swift` 中多处 `firstIndex(where:)`、`removeAll`、`contains`。
风险：
- 高频事件（thumbnail 更新、item 状态变更）下会放大主线程开销。
研究建议：
1. 建立 `id -> index` 辅助索引并维护一致性。
2. 对无变化值写回做短路，避免触发额外 SwiftUI diff。
3. 对 event path 增加 lightweight counter（debug gate）用于测得变更前后触发频次。

### P1. 输入触发与搜索刷新节流策略可细化
主要位置：
- `Scopy/Views/HeaderView.swift`：`onChange(of: searchQuery)`
- `Scopy/Observables/HistoryViewModel.swift`：`searchDebounceNs`
观察：
- 生产路径目前 debounce 值较激进，短词高频输入时 UI 层刷新密度仍偏高。
研究建议：
1. 对 `<=2` 字查询应用单独 debounce（例如 30-60ms）。
2. 引入“输入稳定窗口”后再更新可见 items（用户体感更稳）。

### P1. ScrollView 查找递归与 attach 频度
主要位置：
- `Scopy/Views/History/ListLiveScrollObserverView.swift`：`attachIfNeeded` / `findFirstScrollView`
- `Scopy/Views/History/MarkdownPreviewWebView.swift`：resolver 递归路径
风险：
- view tree 较深时重复递归查找有额外成本。
研究建议：
1. 缓存已解析的 `NSScrollView`，仅在 hierarchy 变化时失效。
2. 通过 signpost 比较 `resolve` 次数和耗时。

### P1. 预览/解码任务在滚动阶段的优先级与取消策略
主要位置：
- `Scopy/Views/History/HistoryItemView.swift` 多个 `Task` / `Task.detached` 分支。
风险：
- 滚动与 hover 高频切换时会有任务取消与重建抖动。
研究建议：
1. 统一预览任务预算（最大并发、取消窗口）。
2. 对 hover-preview 路径做“最近一次请求”去抖聚合。

## 3. 本轮前端量化信号
- `test_perf.log` 中多个 P95 已落在低毫秒至中等毫秒量级（4.72ms / 20.90ms / 24.46ms 等）。
- Snapshot Debug `cm` P95 已从此前 ~120ms 区间下降到 ~75ms，但依然有继续压缩空间。
- 真实滚动 profile（`logs/perf-frontend-profile-2026-02-28-final`）显示：
  - mixed 场景改善明显：frame p95 25.000ms -> 16.667ms；drop ratio 0.029 -> 0.015。
  - accessibility / text-bias 场景存在回退信号（drop ratio 或 frame p95 上升），需继续压 UI 事件密度与渲染抖动。

## 4. 前端实施候选（仅研究结论）
1. 行级索引 + 写回短路（低风险，高收益）。
2. 短词输入分层节流（中风险，中高收益）。
3. 观察器 attach 优化与 resolver 缓存（低风险，中收益）。
4. 预览任务预算与取消策略统一（中风险，中收益）。
