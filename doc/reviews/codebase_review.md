# Scopy 代码库深度审查报告

> 版本基线: v0.60.3 (2026-03-13)
> 审查日期: 2026-03-14
> 审查维度: 架构质量、性能、稳定性、功能体验一致性
> 审查方式: 本地源码深读 + 多轮 subagent 交叉审查 + 当前工作区构建、测试、性能实跑
> 代码规模: 核心超大文件 7 个，共 14550 行 Swift

---

## 0. 本轮验证基线

本轮结论不是只基于静态读代码，而是结合了当前工作区重新验证：

| 项目 | 结果 | 备注 |
|---|---|---|
| make build | BUILD SUCCEEDED | 当前工作区可构建 |
| make test-unit | 300 tests, 1 skipped, 0 failures | 单测基线通过 |
| make test-strict | 300 tests, 1 skipped, 0 failures | 严格并发回归通过 |
| make test-tsan | ScopyTestHost bootstrap early exit, Error 65 | 仍按 test-path / 环境边界处理，不作为本轮代码回归证据 |
| make test-snapshot-perf-release | 通过 | 当前 snapshot release gate: cmd p95 = 0.177ms, cm p95 = 7.328ms |

### 结论边界

- 本轮可以确认: steady-state / release-path fuzzyPlus 搜索很快，而不是搜索整体语义已经健康。
- 本轮不能确认: TSan 当前环境下的真实覆盖结论；它仍然在 test host 建连前早退。
- 本轮特别重视契约是否正确与失败时用户是否被误导，优先级高于文件是否过大。

---

## 1. 执行摘要

### 当前最高优先级问题

1. 真实服务启动失败时静默切到 mock history，这是产品信任边界问题，不是单纯技术债。
2. Exact 小于等于 2 字符与 Regex 如果保留 recent-only，必须成为显式契约，而不是隐式实现细节。
3. Clipboard ingest 是 best-effort，不是 durable-acknowledged。
4. 搜索结果完成度模型不够表达力，当前 isPrefilter 同时表达 staged 首屏与永久受限结果。
5. Settings、Hotkey、Header Search Mode 的用户心智不一致。

### 不应排在最前面的事

- 现在不应该先做 SearchEngineImpl 文件拆分。
- 现在不应该先把问题主要框成内存压力。
- 现在不应该继续把 SettingsStore 并发读写当成高优先级风险。

---

## 2. 最高优先级 Findings

### P0.1 真实服务失败回退到 Mock History

AppState.start() 在真实服务启动失败后，会直接创建 mock service 并让 SettingsViewModel 与 HistoryViewModel 指向它：
[AppState.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Observables/AppState.swift#L127)
[AppState.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Observables/AppState.swift#L135)

而 MockClipboardService 会生成示例数据：
[MockClipboardService.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/MockClipboardService.swift#L16)
[MockClipboardService.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/MockClipboardService.swift#L76)

这意味着在 release 语境下，用户可能看到能正常工作的历史列表，但那不是自己的真实历史。这个行为还被测试固化成预期：
[AppStateTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/AppStateTests.swift#L942)

这不是优雅降级，而是把故障伪装成成功。

### P0.2 Exact 小于等于 2 与 Regex 必须显式收口为 recent-only 契约

当 Exact 小于等于 2 与 Regex 继续保留 recent-only 时，产品必须把它明确定义为受限模式，而不是让实现与文档长期分叉：
[product-spec.md](file:///Users/ziyi/Documents/code/Scopy/doc/current/product-spec.md#L69)

实现上：

- Exact 小于等于 2 直接走 recent cache:
  [SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L2054)
- Regex 全部走 recent cache:
  [SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L2106)
- recent cache 固定为最近 2000 条:
  [SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L819)
  [SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L2234)

UI 侧只给提示，不做后续 refine：
[HistoryViewModel.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift#L99)

测试也已经把这个限制行为固化了：
[IntegrationTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/IntegrationTests.swift#L633)

这已经不是单纯 UX hint 问题，而是实现与 active product contract 的直接偏差。

---

## 3. P1 Findings

### P1.1 Clipboard ingest 存在 silent drop 风险

ClipboardMonitor.checkClipboard() 在确认 pasteboard 变化后，先写回 lastChangeCount，再提取内容：
[ClipboardMonitor.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L524)
[ClipboardMonitor.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L532)
[ClipboardMonitor.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L535)

一旦 extractRawData() 返回 nil，该 revision 不会重试或回补。

大内容异步 ingest 的 backlog 满时会直接丢最老 pending item：
[ClipboardMonitor.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L580)
[ClipboardMonitor.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L584)

更改 polling interval 会 stop 再 start，同时取消 active ingest、清空 pending 队列：
[ClipboardMonitor.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L246)
[ClipboardMonitor.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Services/ClipboardMonitor.swift#L237)

这意味着：

- 提取失败可永久漏记
- backlog 满可永久漏记
- 用户保存 polling interval 设置也可能造成漏记

### P1.2 搜索完成度模型不够表达当前真实状态

当前 SearchRequest 只有 forceFullFuzzy，它本质上只服务 fuzzy：
[SearchRequest.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Domain/Models/SearchRequest.swift#L13)

但 searchInCache() 返回的 recent-only 结果也会被标成 isPrefilter = true：
[SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L2225)

同时：

- HistoryViewModel 的 progressive hint 只对 fuzzy 和 fuzzyPlus 生效：
  [HistoryViewModel.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift#L114)
- refine task 只对 fuzzy 和 fuzzyPlus 生效：
  [HistoryViewModel.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift#L503)
- loadMore() 也只对 fuzzy prefilter 做强制全量收敛：
  [HistoryViewModel.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Observables/HistoryViewModel.swift#L386)

结果就是，isPrefilter 同时在表达三件本质不同的事：fuzzy staged 首屏、Exact 短词 recent subset、Regex recent subset。这是模型层面的问题，不只是文案不准。

### P1.3 Header Search Mode 会直接持久化默认值

用户在主界面切换搜索模式时，不只是修改当前 session mode，还会直接写回默认设置：
[HeaderView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/HeaderView.swift#L93)
[HeaderView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/HeaderView.swift#L101)

而 Settings 页里也有默认搜索模式作为正式设置项：
[GeneralSettingsPage.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/GeneralSettingsPage.swift#L15)

这让当前模式和默认偏好两个概念被混在一起。

### P1.4 Settings 与 Hotkey 是有意双轨，但用户心智不直观

当前产品和开发文档都明确要求：

- 其余设置保持 Save/Cancel 事务模型
- Hotkey 录制完成后立即生效并持久化

证据：
[product-spec.md](file:///Users/ziyi/Documents/code/Scopy/doc/current/product-spec.md#L64)
[development-guide.md](file:///Users/ziyi/Documents/code/Scopy/doc/current/development-guide.md#L89)

实现上：

- Settings dirty 计算和保存都显式 droppingHotkey():
  [SettingsView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/SettingsView.swift#L82)
  [SettingsView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/SettingsView.swift#L168)
- Shortcuts 页文案明确写了录制完成后立即生效并持久化：
  [ShortcutsSettingsPage.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/ShortcutsSettingsPage.swift#L10)
- HotKeyRecorderView 在录制成功后立刻调用 runtime apply，再等待持久化回读：
  [HotKeyRecorderView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/HotKeyRecorderView.swift#L37)
  [HotKeyRecorderView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/HotKeyRecorderView.swift#L74)

这条链是工程上自洽的。真正的问题是：

- 改 hotkey 再点 Cancel，不会回滚 hotkey
- 恢复默认也不会恢复 hotkey 默认值，而是保留当前 hotkey
  [SettingsView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/Settings/SettingsView.swift#L125)

### P1.5 冷启动与 warm-load 成本被当前文档低估

上一版报告把搜索性能风险主要框成内存压力，但当前更需要前置的是冷启动与 warm-load 的真实成本。

FullFuzzyIndex 在内存中保留 plainTextLower：
[SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L163)

full-index disk cache 也会持久化同样的 plainTextLower：
[SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L299)

warm load 时不是简单映射文件，而是：

- 读或映射 cache
- 校验 checksum / fingerprint / postings
- PropertyListDecoder 解码完整 cache

证据：
[SearchEngineImpl.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Infrastructure/Search/SearchEngineImpl.swift#L1572)

这里的主风险不只是 steady-state RSS，而是全文字符串集合同时存在于运行时对象和 disk cache，warm-load 成本仍随体积线性增长。

### P1.6 HistoryItemView 已经演化成行级状态机

HistoryItemView 不只是 row view，而是同时管理：

- PreviewTaskBudget
  [HistoryItemView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L13)
- 多组 hover、preview、markdown、optimize、exit task
  [HistoryItemView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L83)
- 多套 popover token 与 cleanup 逻辑
  [HistoryItemView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L601)

当前唯一比较贴近真实交互的 UI 覆盖是 preview on scroll dismiss：
[HistoryListUITests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyUITests/HistoryListUITests.swift#L257)

所以这块的主要风险不再是还没做 Equatable，而是 row-level state machine 过重。

### P1.7 导出功能发现性低仍然成立，而且比上一版写得更严重

当前 row context menu 没有 export：
[HistoryItemView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemView.swift#L764)

真正的 export 按钮藏在 hover preview 内部：
[HistoryItemTextPreviewView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemTextPreviewView.swift#L150)

失败反馈主要依赖 help text：
[HistoryItemTextPreviewView.swift](file:///Users/ziyi/Documents/code/Scopy/Scopy/Views/History/HistoryItemTextPreviewView.swift#L330)

这意味着普通用户若不知道先 hover 再点 preview 内按钮，基本发现不了这个能力。

---

## 4. 架构与设计判断

### 4.1 仍然成立的判断

- SearchEngineImpl 过大且职责过多
- MarkdownExportService 放在 Views/History 下仍然层次不清
- AppState 兼容 façade 仍然存在且边界不清
- HistoryItemView 仍过于复杂

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
  - [FullIndexDiskCacheHardeningTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/FullIndexDiskCacheHardeningTests.swift)
  - [ShortQueryIndexDiskCacheHardeningTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/ShortQueryIndexDiskCacheHardeningTests.swift)
  - [FullIndexTombstoneUpsertStaleTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/FullIndexTombstoneUpsertStaleTests.swift)
- Clipboard priority rules:
  - [ClipboardMonitorTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardMonitorTests.swift#L456)
  - [ClipboardMonitorTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardMonitorTests.swift#L717)
  - [ClipboardMonitorTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/ClipboardMonitorTests.swift#L774)
- Settings merge / hotkey protection:
  - [SettingsConcurrencyMergeTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/SettingsConcurrencyMergeTests.swift#L9)
  - [SettingsConcurrencyMergeTests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyTests/SettingsConcurrencyMergeTests.swift#L28)
- UI tests 面比只有导出相关测试更广:
  - [ScopyUITests/SettingsUITests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyUITests/SettingsUITests.swift)
  - [ScopyUITests/ContextMenuUITests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyUITests/ContextMenuUITests.swift)
  - [ScopyUITests/HistoryListUITests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyUITests/HistoryListUITests.swift)
  - [ScopyUITests/KeyboardNavigationUITests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyUITests/KeyboardNavigationUITests.swift)
  - [ScopyUITests/MainWindowUITests.swift](file:///Users/ziyi/Documents/code/Scopy/ScopyUITests/MainWindowUITests.swift)

### 6.2 当前真正缺的测试

1. Exact <= 2 与 Regex 的契约级完整性测试
2. Search result coverage model 的状态机测试
3. Clipboard ingest 的失败路径测试:
   - extractRawData == nil 后是否永久漏记
   - pendingLargeContent overflow 行为
   - setPollingInterval() 中断 in-flight ingest
4. Settings 事务的用户路径测试:
   - record hotkey -> Cancel
   - record hotkey -> Reset
   - record invalid hotkey -> rollback
   - save non-hotkey settings -> hotkey remains stable
5. HistoryItemView 的直接行为测试 / snapshot test
6. Search warm-load / peak RSS 指标测试

---

## 7. 对上一版审查文档的校正

### 7.1 仍然保留

- SearchEngineImpl 超大文件问题
- MarkdownExportService 放错层
- AppState 兼容层 / 全局 shared 问题
- HistoryItemView 复杂度问题
- 搜索模式覆盖不一致，但需要上调优先级

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

- startup failure 到 mock fallback 是 P0 产品风险
- Header Search Mode 直接持久化默认值是 P1 一致性问题
- ClipboardMonitor silent drop / overflow / interval-change side effects 是 P1 稳定性问题
- 搜索完成度模型不够表达 current behavior 是 P1 架构问题
- warm-load / multi-copy cache cost 是 P1 性能与架构边界问题

---

## 8. 改进路线图

### Phase 1: 先修产品信任与契约

1. 移除 startup failure 到 mock fallback 的 release 默认行为
2. 定义搜索完成度模型:
   - complete
   - stagedInitial
   - recentSubset(limit: 2000)
3. 明确 Exact <= 2 / Regex 的产品决策:
   - 正式定义为 recent-only，并同步文档与 UI
   - 或增加后台 full-history continuation / refine
4. 修复 Clipboard ingest 的确认时机与 destructive interval-change
5. 修正文档与验证表述

### Phase 2: 补契约级测试

1. Exact <= 2 / Regex 在 >2000 历史规模下的契约测试
2. coverage 状态机测试
3. Clipboard silent drop / overflow / interval-change 测试
4. Settings 事务与 hotkey 双轨测试
5. startup failure 不展示 synthetic history 的测试
6. HistoryItemView 行为测试 / snapshot test

### Phase 3: 再做结构收敛

1. 缩小 AppState，让它回到 lifecycle / event coordinator
2. 重构 SearchEngineImpl，但顺序在契约之后:
   - QueryPlanner
   - CoverageModel
   - RecentSubsetSearch
   - FullIndexSearch
   - FTS / Substring fallback
   - SearchBenchmarks
3. 把 Preview / Export 从 View 结构中拆出来
4. 拆 HistoryItemView 行级状态机

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

Scopy 现在最该优先处理的，不是代码太长，而是三件更接近产品真相的事：

1. 失败时不能伪装成功，startup failure 到 mock history 必须改。
2. 搜索模式必须符合明确契约，Exact <= 2 与 Regex 不能再以 recent-only 子集伪装成正常搜索模式。
3. ingest 不能 silently drop，lastChangeCount 提前确认、backlog drop、interval-change 清空 in-flight ingest 都需要修。

在这三件事之前，SearchEngineImpl 拆文件、HistoryItemView 美化拆分、MarkdownExportService 挪目录，都是重要但次一级的工作。下一版审查和实施计划，建议以“契约正确、失败诚实、证据可信”为先，而不是以“文件看起来更整洁”为先。
