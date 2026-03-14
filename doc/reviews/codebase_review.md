# Scopy 代码库深度审查报告

> 版本基线: v0.60.3 (2026-03-13)
> 审查日期: 2026-03-15
> 审查维度: 架构质量、性能、稳定性、功能体验一致性
> 审查方式: 本地源码深读 + 多轮 subagent 交叉审查 + 当前工作区构建、测试、性能实跑
> 代码规模: 核心超大文件 7 个，共 14550 行 Swift

---

## 0. 本轮验证基线

本轮结论不是只基于静态读代码，而是结合了当前工作区重新验证：

| 项目 | 结果 | 备注 |
|---|---|---|
| make build | BUILD SUCCEEDED | 当前工作区可构建 |
| make test-unit | 318 tests, 1 skipped, 0 failures | 单测基线通过 |
| make test-strict | 318 tests, 1 skipped, 0 failures | 严格并发回归通过 |
| make test-tsan | ScopyTestHost bootstrap early exit, Error 65 | 仍按 test-path / 环境边界处理，不作为本轮代码回归证据 |
| make test-snapshot-perf-release | 通过 | 当前 snapshot release gate: cmd p95 = 0.123ms, cm p95 = 5.160ms |
| make perf-frontend-profile-standard | 通过 | 产物: logs/perf-frontend-profile-2026-03-15_03-17-56 |

### 结论边界

- 本轮可以确认: steady-state / release-path fuzzyPlus 搜索很快，而不是搜索整体语义已经健康。
- 本轮不能确认: TSan 当前环境下的真实覆盖结论；它仍然在 test host 建连前早退。
- 本轮特别重视契约是否正确与失败时用户是否被误导，优先级高于文件是否过大。

---

## 1. 执行摘要

### 当前最高优先级问题

1. AppState 仍保留一层 compatibility façade，lifecycle coordinator 和业务状态边界还没有完全收口。
2. SearchEngineImpl 与 HistoryItemView 仍然偏大，当前 helper/coordinator 抽取只完成了第一刀。
3. warm-load full-index latency、peak RSS、row-level invalidation 还没有形成长期量化基线。
4. HistoryItemView 的直接行为测试 / snapshot test 仍然缺位，复杂交互主要靠集成和 UI smoke 兜底。
5. Export PNG 的发现性仍然偏低，一级入口和成功/失败反馈还可以继续收口。

### 不应排在最前面的事

- 现在不应该先做 SearchEngineImpl 文件拆分。
- 现在不应该先把问题主要框成内存压力。
- 现在不应该继续把 SettingsStore 并发读写当成高优先级风险。

---

## 2. 最高优先级 Findings

### P0.1 已完成: 启动失败不再回退到 Mock History

当前实现只在 `DEBUG` 且显式启用 `USE_MOCK_SERVICE` 时才允许 mock service；真实服务启动失败会进入 `startupFailed`，并暴露重试与诊断复制路径，而不是伪装成一份可用的假历史：
[AppState.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/AppState.swift#L119)
[AppState.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/AppState.swift#L155)
[AppState.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/AppState.swift#L179)

原始风险已经关闭；这里保留 P0 的目的，是提醒后续版本不要重新引入 silent fallback。

### P0.2 已完成: Exact 小于等于 2 与 Regex 明确收口为 recent-only 契约

当前实现已经把 `SearchCoverage` 升级为显式契约；`Exact <= 2` 与 `Regex` 明确走 `.recentOnly(limit: 2000)`，并由 UI 文案直接表达限制，而不是再借 `isPrefilter` 隐含表示：
[SearchCoverage.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Domain/Models/SearchCoverage.swift#L3)
[SearchEngineImpl.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L2082)
[SearchEngineImpl.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L2133)
[HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift#L107)
[product-spec.md](/Users/ziyi/Documents/code/Scopy/doc/current/product-spec.md#L69)

原始风险已经关闭；保留这一项，是为了强调 recent-only 必须始终作为产品契约而不是隐藏实现细节。

---

## 3. P1 Findings

### P1.1 已完成: Clipboard ingest 的 silent drop 风险已收敛

当前实现已经把大内容 ingest 改成 envelope + durable replay 路径；monitor 启动时会 replay disk 上的 pending 内容，并把 replay / soft-limit / active ingest 暴露到诊断面板，避免 silent drop 继续藏在内部状态里：
[ClipboardMonitor.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L331)
[ClipboardMonitor.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L910)
[AboutSettingsPage.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/AboutSettingsPage.swift#L106)

原始风险已经关闭；这里保留 P1 的目的，是提醒后续不要回退到“满了就丢、失败就算”的 best-effort ingest。

### P1.2 已完成: 搜索完成度模型已升级为 SearchCoverage

`SearchCoverage` 现在显式区分 `complete`、`stagedRefine` 和 `recentOnly(limit:)`；ViewModel 也直接基于 coverage 生成状态文本和限制提示，不再让一个布尔值同时表达多种结果语义：
[SearchCoverage.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Domain/Models/SearchCoverage.swift#L3)
[HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift#L103)
[HistoryViewModel.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift#L128)

原始模型问题已经关闭；后续要继续盯的是 coverage 与分页、排序、性能证据是否持续一致。

### P1.3 已完成: Header Search Mode 不再直接持久化默认值

当前 Header 的模式切换只更新当前会话的 `historyViewModel.searchMode` 并立即重新搜索；默认模式仍然只在设置页管理，二者的用户心智已经拆开：
[HeaderView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HeaderView.swift#L82)
[HeaderView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/HeaderView.swift#L109)
[GeneralSettingsPage.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/GeneralSettingsPage.swift#L15)

原始心智冲突已经关闭；后续可继续优化的是模式命名、提示密度和 discoverability，而不是再把 default/session 混回一起。

### P1.4 Settings 与 Hotkey 是有意双轨，但用户心智不直观

当前产品和开发文档都明确要求：

- 其余设置保持 Save/Cancel 事务模型
- Hotkey 录制完成后立即生效并持久化

证据：
[product-spec.md](/Users/ziyi/Documents/code/Scopy/doc/current/product-spec.md#L64)
[development-guide.md](/Users/ziyi/Documents/code/Scopy/doc/current/development-guide.md#L89)

实现上：

- Settings dirty 计算和保存都显式 droppingHotkey():
  [SettingsView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/SettingsView.swift#L82)
  [SettingsView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/SettingsView.swift#L168)
- Shortcuts 页文案明确写了录制完成后立即生效并持久化：
  [ShortcutsSettingsPage.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/ShortcutsSettingsPage.swift#L10)
- HotKeyRecorderView 在录制成功后立刻调用 runtime apply，再等待持久化回读：
  [HotKeyRecorderView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/HotKeyRecorderView.swift#L37)
  [HotKeyRecorderView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/HotKeyRecorderView.swift#L74)

这条链是工程上自洽的。真正的问题是：

- 改 hotkey 再点 Cancel，不会回滚 hotkey
- 恢复默认也不会恢复 hotkey 默认值，而是保留当前 hotkey
  [SettingsView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/SettingsView.swift#L125)

### P1.5 冷启动与 warm-load 成本被当前文档低估

上一版报告把搜索性能风险主要框成内存压力，但当前更需要前置的是冷启动与 warm-load 的真实成本。

FullFuzzyIndex 在内存中保留 plainTextLower：
[SearchEngineImpl.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L163)

full-index disk cache 也会持久化同样的 plainTextLower：
[SearchEngineImpl.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L299)

warm load 时不是简单映射文件，而是：

- 读或映射 cache
- 校验 checksum / fingerprint / postings
- PropertyListDecoder 解码完整 cache

证据：
[SearchEngineImpl.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L1572)

这里的主风险不只是 steady-state RSS，而是全文字符串集合同时存在于运行时对象和 disk cache，warm-load 成本仍随体积线性增长。

### P1.6 HistoryItemView 已经演化成行级状态机

HistoryItemView 不只是 row view，而是同时管理：

- PreviewTaskBudget
  [HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L13)
- 多组 hover、preview、markdown、optimize、exit task
  [HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L83)
- 多套 popover token 与 cleanup 逻辑
  [HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L601)

当前唯一比较贴近真实交互的 UI 覆盖是 preview on scroll dismiss：
[HistoryListUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/HistoryListUITests.swift#L257)

所以这块的主要风险不再是还没做 Equatable，而是 row-level state machine 过重。

### P1.7 导出功能发现性低仍然成立，而且比上一版写得更严重

当前 row context menu 没有 export：
[HistoryItemView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L764)

真正的 export 按钮藏在 hover preview 内部：
[HistoryItemTextPreviewView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemTextPreviewView.swift#L150)

失败反馈主要依赖 help text：
[HistoryItemTextPreviewView.swift](/Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemTextPreviewView.swift#L330)

这意味着普通用户若不知道先 hover 再点 preview 内按钮，基本发现不了这个能力。

---

## 4. 架构与设计判断

### 4.1 仍然成立的判断

- SearchEngineImpl 仍然过大且职责过多，但 fuzzy 主路径已经开始 helper 化
- AppState 兼容 façade 仍然存在且边界不清
- HistoryItemView 仍过于复杂
- Preview 状态机虽然稳定了，但还没有完全从 row view 中抽离

### 4.2 已经过时或需要降级的判断

- SettingsStore 并发读写风险已过时，它现在已经是 actor。
- 缺少 pasteboard 多类型优先级测试已过时，相关优先级测试已经存在。
- 缺 regex 边界测试 / 大 offset 分页回归表述不够准确，已有基础 regex 和分页测试，但缺的是契约级完整性测试。
- TSan 已覆盖应降级为 target 存在，但当前环境仍有 test-host 启动边界。

### 4.3 之前文档漏掉的重要问题

- AppState startup failure 到 mock fallback
- Header Search Mode 直接持久化默认值
- ClipboardMonitor 的 silent drop / overflow / interval-change side effects
- 搜索完成度模型不够表达 current behavior
- warm-load / disk-cache decode 成本

---

## 5. 搜索模式现状矩阵

| 模式 | 当前覆盖范围 | 是否最终收敛 | 分页语义 | 排序语义 | 评语 |
|---|---|---|---|---|---|
| Exact <= 2 | 最近 2000 条 | 否 | 仅对 capped subset 分页 | 排序禁用 | 与契约冲突 |
| Exact >= 3 | 全量 FTS / substring path | 是 | 完整分页 | recent / relevance 可用 | 基本符合契约 |
| Regex | 最近 2000 条 | 否 | 仅对 capped subset 分页 | 排序禁用 | 与契约冲突 |
| Fuzzy / Fuzzy+ | 首屏可 prefilter | 是 | loadMore 会强制 full fuzzy 再扩展 | recent / relevance 可用 | staged 但可收敛 |

---

## 6. 测试与证据现状

### 6.1 已有覆盖比上一版报告写得更强的地方

- Search hardening:
  - [FullIndexDiskCacheHardeningTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/FullIndexDiskCacheHardeningTests.swift)
  - [ShortQueryIndexDiskCacheHardeningTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ShortQueryIndexDiskCacheHardeningTests.swift)
  - [FullIndexTombstoneUpsertStaleTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/FullIndexTombstoneUpsertStaleTests.swift)
- Clipboard priority rules:
  - [ClipboardMonitorTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardMonitorTests.swift#L456)
  - [ClipboardMonitorTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardMonitorTests.swift#L717)
  - [ClipboardMonitorTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardMonitorTests.swift#L774)
- Settings merge / hotkey protection:
  - [SettingsConcurrencyMergeTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/SettingsConcurrencyMergeTests.swift#L9)
  - [SettingsConcurrencyMergeTests.swift](/Users/ziyi/Documents/code/Scopy/ScopyTests/SettingsConcurrencyMergeTests.swift#L28)
- UI tests 面比只有导出相关测试更广:
  - [ScopyUITests/SettingsUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/SettingsUITests.swift)
  - [ScopyUITests/ContextMenuUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/ContextMenuUITests.swift)
  - [ScopyUITests/HistoryListUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/HistoryListUITests.swift)
  - [ScopyUITests/KeyboardNavigationUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/KeyboardNavigationUITests.swift)
  - [ScopyUITests/MainWindowUITests.swift](/Users/ziyi/Documents/code/Scopy/ScopyUITests/MainWindowUITests.swift)

### 6.2 当前真正缺的测试

1. HistoryItemView 的直接行为测试 / snapshot test
2. Search warm-load / peak RSS 指标测试
3. 真实前端 profile 与 row-level invalidation 的长期基线比较

---

## 7. 对上一版审查文档的校正

### 7.1 仍然保留

- SearchEngineImpl 超大文件问题
- AppState 兼容层 / 全局 shared 问题
- HistoryItemView 复杂度问题
- 搜索模式覆盖不一致，但当前已经改成显式契约

### 7.2 需要降级或重写

| 原判断 | 当前结论 |
|---|---|
| SettingsStore 并发读写风险高 | 已过时，当前已 actor 化 |
| 缺少 pasteboard 多类型优先级测试 | 已过时，已有多组优先级测试 |
| 缺 regex 边界测试 / 大 offset 分页回归 | 不准确，已有基础测试；真正缺的是契约级完整性测试 |
| TSan 已覆盖 | 需改成 target 存在，但当前环境下仍有启动边界 |
| UI tests 仅有导出相关 | 不准确，当前 UI suite 更广 |
| EmptyState 只是简单文本 | 细节过时，应改成信息架构偏轻、缺 onboarding / CTA |

### 7.3 新增应写入的结论

- startup failure 到 mock fallback 已经修复为显式 degraded state
- Header Search Mode 直接持久化默认值已修复为 session-only
- ClipboardMonitor silent drop / overflow / interval-change side effects 已经收敛到 durable replay + diagnostics
- 搜索完成度模型已升级为 SearchCoverage，并完成 UI 契约表达
- warm-load / multi-copy cache cost 仍然是 P1 性能与架构边界问题

---

## 8. 改进路线图

### Phase 1: 先修产品信任与契约

1. 已完成：移除 startup failure 到 mock fallback 的 release 默认行为
2. 已完成：定义搜索完成度模型:
   - complete
   - stagedRefine
   - recentOnly(limit: 2000)
3. 已完成：Exact <= 2 / Regex 正式定义为 recent-only，并同步文档与 UI
4. 已完成：修复 Clipboard ingest 的确认时机与 destructive interval-change
5. 已完成：修正文档与验证表述

### Phase 2: 补契约级测试

1. 已完成：Exact <= 2 / Regex 在 >2000 历史规模下的契约测试
2. 已完成：coverage 状态机测试
3. 已完成：Clipboard silent drop / overflow / interval-change 测试
4. 已完成：Settings 事务与 hotkey 双轨测试
5. 已完成：startup failure 不展示 synthetic history 的测试
6. 未完成：HistoryItemView 行为测试 / snapshot test

### Phase 3: 再做结构收敛

1. 部分完成：缩小 AppState，让它回到 lifecycle / event coordinator
2. 部分完成：重构 SearchEngineImpl，但顺序在契约之后:
   - QueryPlanner
   - CoverageModel
   - RecentSubsetSearch
   - FullIndexSearch
   - FTS / Substring fallback
   - SearchBenchmarks
3. 部分完成：把 Preview / Export 从 View 结构中拆出来
4. 未完成：拆 HistoryItemView 行级状态机

### Phase 4: 性能与体验优化

1. warm-load full-index latency 指标
2. full-index build/load 后 peak RSS 指标
3. full-index / disk-cache schema compaction
4. memory-pressure / idle-based full-index eviction
5. Search mode / coverage / sort 的显式联动 UI
6. Export PNG 一级入口与更直接的成功 / 失败反馈
7. Empty state 的 onboarding / hotkey / clear-filters CTA

---

## 9. 总结

Scopy 这一轮已经先把产品信任和契约问题收掉了，当前剩下的优先级开始转向结构收敛与证据补齐：

1. 继续压缩 AppState compatibility façade，让 lifecycle 与业务状态彻底解耦。
2. 继续拆 SearchEngineImpl 和 HistoryItemView，把“大文件”问题变成真实的职责边界，而不是只换目录。
3. 补齐 HistoryItemView 的直接行为测试 / snapshot test，再把剩余 preview/export 副作用迁出 row view。

下一版审查和实施计划，应该从“契约正确、失败诚实”转到“结构边界可维护、测试证据持续可回归”，而不是只做表层 UI 或机械拆文件。
