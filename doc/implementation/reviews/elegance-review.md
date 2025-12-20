# Code Elegance Deep Review

## Review Meta
- 项目：Scopy
- 目标：优雅性/稳定性/可维护性
- 状态：进行中
- 最近更新：2025-12-19 16:52

## Review 记录规范
- 分级：S1（高风险/稳定性），S2（可维护性/一致性），S3（风格/可读性）
- 每条记录必须包含：位置(file:line)、问题描述、影响、建议
- 每个模块必须包含：High-level 观察 + Low-level 观察 + 模块小结

## 模块进度
- [x] App/UI（已审）
- [x] Observables（已审）
- [x] Services（已审）
- [x] Infrastructure（已审）
- [x] Utilities（已审）
- [x] Tests/Scripts（已审）

## High-level 总结（待补充）
- AppDelegate/HistoryItemView 等核心入口承担过多职责，需通过小型助手方法/模型重置来削弱“超级函数”倾向。
- Search/Clipboard 的缓存与复制逻辑存在重复路径，适合收敛为统一的内部 helper，降低维护风险。

## Low-level 总结（待补充）
- `HistoryItemView` 在 hover/scroll/disappear 的状态清理重复且易漏字段，已集中到 `resetPreviewState`/`HoverPreviewModel.reset()`。
- `AsyncBoundedQueue` 旧实现 `removeFirst()` 为 O(n)，改为 ring buffer 保持 O(1) 出队。
- SearchEngineImpl 的 cache reset 逻辑重复，已提取 `resetQueryCaches`/`resetFullIndex`。

---

# 模块：App/UI

## High-level 观察
- AppDelegate 承担窗口创建/热键/事件监控/UITest 等多职责，容易形成“超级入口”，影响可维护性。
- HistoryItemView 同时处理渲染与复杂任务生命周期，易出现状态散落与重复清理。

## Low-level 观察
- 启动流程拆分为 `resolveLaunchContext`/`makeHostingWindow`/`installLocalEventMonitor` 等私有方法，降低单函数复杂度。(`Scopy/AppDelegate.swift:30`)
- hover/scroll/disappear 多处清理逻辑已统一到 `resetPreviewState` 与 `HoverPreviewModel.reset()`，避免遗漏。(`Scopy/Views/History/HistoryItemView.swift:240` / `Scopy/Views/History/HoverPreviewModel.swift:20`)
- MarkdownPreviewWebView 的消息解析逻辑已抽离为统一 helper，减少双实现分叉。(`Scopy/Views/History/MarkdownPreviewWebView.swift:22`)

## 问题清单
- S2 `Scopy/AppDelegate.swift:30` 启动流程集中在一个方法中，职责交织（窗口/热键/事件监控）。建议拆分为私有 helper（已落地）。
- S2 `Scopy/Views/History/HistoryItemView.swift:240` 预览状态清理重复且易漏字段（exportErrorMessage）。建议集中 reset（已落地）。
- S3 `Scopy/Views/History/MarkdownPreviewWebView.swift:120` 消息解析重复，建议提取统一解析器（已落地）。

## 模块小结
- App/UI 入口职责已初步拆分，但 HistoryItemView 仍偏大，后续可考虑进一步抽离预览状态机/任务协调器。

---

# 模块：Observables

## High-level 观察
- AppState 作为应用状态聚合层，同时承担启动/回退/事件分发；需要避免在事件路径里出现重复的设置逻辑。
- HistoryViewModel 承担加载/搜索/滚动/选择等多类职责，需通过小步 helper 降低分支复杂度。

## Low-level 观察
- settingsChanged 的设置同步已收敛到 `refreshSettings`/`applyHotKeyIfNeeded`，避免重复分支。(`Scopy/Observables/AppState.swift:135`)
- `HistoryViewModel` 过滤判断/任务取消集中为 helper，减少重复判断与任务泄漏风险。(`Scopy/Observables/HistoryViewModel.swift:40`)
- `PerformanceMetrics` 统一延迟格式化与采样逻辑，避免重复实现。(`Scopy/Observables/PerformanceMetrics.swift:12`)

## 问题清单
- S3 `Scopy/Observables/AppState.swift:135` settingsChanged 与启动流程存在重复的设置应用逻辑，建议提取 helper（已落地）。
- S2 `Scopy/Observables/HistoryViewModel.swift:40` 过滤判断/任务取消重复，建议抽 helper（已落地）。
- S3 `Scopy/Observables/PerformanceMetrics.swift:12` 延迟格式化逻辑重复，建议统一 helper（已落地）。

## 模块小结
- Observables 层开始收敛重复逻辑，HistoryViewModel 仍是复杂模块，后续可继续审视职责边界与任务拆分。

---

# 模块：Services

## High-level 观察
- ClipboardService 在单函数内处理多类型 pasteboard 路径，复杂度偏高，易引入分支遗漏。
- StorageService 结构仍偏重，后续可评估进一步模块化，但不宜一次性大改。

## Low-level 观察
- `copyToClipboard` 已拆分为 `copyPlainText/copyRichPayload/copyFilePayload`，逻辑更清晰。(`Scopy/Application/ClipboardService.swift:240`)
- StorageService 的目录创建逻辑已集中到 helper，减少重复错误处理。(`Scopy/Services/StorageService.swift:99`)

## 问题清单
- S2 `Scopy/Application/ClipboardService.swift:240` 复制逻辑过长且多分支，建议抽出 helper（已落地）。
- S2 `Scopy/Services/StorageService.swift:1` 大型类职责集中（数据/文件/清理/统计），建议后续拆分策略对象或子服务（部分整理，仍需阶段性拆分）。

## 模块小结
- Services 已完成 ClipboardService 的局部重构，StorageService 进行了小步整理，仍需分阶段拆分。

---

# 模块：Infrastructure

## High-level 观察
- SearchEngineImpl 的缓存/索引无效化逻辑分散，容易出现变更时的漏改。

## Low-level 观察
- 缓存 reset 已统一至 `resetQueryCaches`/`resetFullIndex`，重复逻辑收敛。(`Scopy/Infrastructure/Search/SearchEngineImpl.swift:204`)

## 问题清单
- S3 `Scopy/Infrastructure/Search/SearchEngineImpl.swift:204` cache reset 重复，建议集中封装（已落地）。

## 模块小结
- Infrastructure 先完成小步整洁性优化，暂未触及算法层/索引架构调整。

---

# 模块：Utilities

## High-level 观察
- AsyncBoundedQueue 原实现出队 O(n) 影响性能，且在高频事件流下可能放大延迟。

## Low-level 观察
- 队列改为 ring buffer，出队 O(1) 并保留原有背压语义。(`Scopy/Utilities/AsyncBoundedQueue.swift:8`)

## 问题清单
- S2 `Scopy/Utilities/AsyncBoundedQueue.swift:8` `removeFirst()` 导致 O(n) 退化，建议 ring buffer（已落地）。

## 模块小结
- Utilities 已完成关键性能点的修正，后续可补充更细粒度的队列测试场景。

---

# 模块：Tests/Scripts

## High-level 观察
- UI 测试覆盖导出/预览等关键路径，但依赖多处超时与坐标点击，存在一定不稳定性风险。
- 部署脚本结构清晰，未发现影响稳定性的结构问题。

## Low-level 观察
- `ExportMarkdownPNGUITests` 通过坐标网格兜底点击按钮，建议将等待/点击策略集中到统一 helper，减少重复配置。(`ScopyUITests/ExportMarkdownPNGUITests.swift:40`)

## 问题清单
- S2 `ScopyUITests/ExportMarkdownPNGUITests.swift:40` UI 测试 fallback 点击策略重复且易受环境影响，建议提取公共 helper（待处理）。

## 模块小结
- Tests/Scripts 已完成阅读，暂无需立即改动脚本；UI 测试可在后续阶段做稳定性增强。
