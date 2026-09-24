---
doc_type: proposal
status: draft
owner: hh
created: 2026-09-24
audience: maintainer decision + implementing agent
---

# Scopy 前端交互性能与体验评审（2026-09-24）

基线：`407f7db`（v0.81.0）。工作树里未提交的 `SCOPY_EXP_OPAQUE_ROWS` 实验不计入；`Scopy/FloatingPanel.swift`、`Scopy/Views/ContentView.swift`、`Scopy/Views/HistoryListView.swift` 三个文件的行号一律取自 `git show 407f7db:<path>`，其余文件工作树与 HEAD 相同。所有结论都是本次在 HEAD 重读代码得到的；性能数字只引用 2026-09-03/04 已测事实（Release、146 MB 快照库），本评审**没有运行任何构建、测试或 perf 脚本**，文中所有"预期"都是待实测的假设，并给出判定用的指标与门槛。

范围：`Scopy/Views/**`、`Scopy/Observables/**`、`Scopy/Presentation/**`、`Scopy/FloatingPanel.swift`、`Scopy/AppDelegate.swift` 的键盘/面板部分、`ScopyUISupport`。后端引擎（`SearchEngineImpl`、`StorageService`）只作为协议边界；Markdown 渲染链归渲染评审，这里只处理 hover popover 的呈现、尺寸与就绪。死代码/冗余测试清单见 [code-hygiene-audit-2026-09-19.md](./code-hygiene-audit-2026-09-19.md)，本文只引用不重复。

## 0. 结论

| 编号 | 改进 | 优先级 | 规模 | 预期收益（可测量） | 主要回归风险 |
| --- | --- | --- | --- | --- | --- |
| F0 | 测量前置：`profile_search.py` 复制 v5/v3 索引缓存，输出 `list.body`、发布次数与主线程最长阻塞 | P1 | S | 让 F1–F4 的前后对比可信（当前每次运行都在 settle 期重建全量索引） | 无（工具） |
| F1 | 空结果时不卸载 List；不发布空的 staged 预筛页 | P1 | S | 零结果键（`zqxjv` 类）不再每键销毁/重建 List；Fuzzy+ 半词输入不再闪 "No results" | 空态覆盖层的点击/无障碍 |
| F2 | 行级实时状态扇出（选中 + 证据）+ 行集合与分页的观察拆分 | P1 | M | 证据-only、分页-only、"相同 refine"发布 → 0 次 `HistoryListView.body` | 行错过扇出更新 |
| F3 | 每键一次发布：staged 预筛页进"截止槽"，refine 在截止前到达则只发布一次；去掉瞬时"预筛"提示行 | P1 | M | 每键 List 更新 ≈1.5 → ≈1.0；头部不再每键伸缩一行、列表不再每键上下跳 | 截止竞态；慢 refine 时首屏最多晚 50 ms |
| F4 | 可见行优先的分块替换（首块 = 可见行预算，尾块按帧追加、新键即作废） | P1 | M | 每键主线程最长阻塞 90–180 ms → **< 50 ms**（`runloop busy max`） | ↓/⏎ 在尾块未到时的边界 |
| F5 | 悬停：呈现状态扇出 + 呈现前确定并冻结尺寸 + QuickLook 构造移出首帧 | P1 | M | 呈现/关闭不再触发整表 diff；呈现后窗口 resize 次数 → 0（Markdown ≤ 1）；单次呈现停顿目标 < 50 ms | 尺寸估计偏差造成多余滚动条 |
| F6 | 悬停：列表级 AppKit popover 宿主（`NSHostingController.sizingOptions = []`，显式 `contentSize`）——**条件项** | P1（条件） | L | 直接去掉已归因的 `updateWindowContentSizeExtremaIfNecessary → setFrame → _layoutViewTree` 栈 | 转移走廊几何、关闭语义、UI 测试 |
| F7 | 内存：悬停位图随面板生命周期释放、内存压力响应、revision memo 不持有全文、清理循环按需、缩略图字节上限 | P1 | S×5 | 关面板后 footprint 回落到基线 + ε；压力下前端可释放 ≥ 320 MB 上限 | 重开面板后重新解码 |
| F8 | 可撤销删除（5 s 单槽，含"删后又复制"竞态） | P0 | M | 误删（含搜索框里按 ⌥⌫）可恢复 | 延迟提交与后端事件交错 |
| F9 | 键盘导航、⏎、⌥⌫ 不再命中折叠后看不见的置顶行 | P0 | S | 不再静默复制/删除看不见的置顶项 | 无 |
| F10 | 悬停改选中只在指针真实移动之后 | P1 | S | 键盘导航时选中不被静止指针下滚过的行抢走 | 规格 `product-spec.md:156` 语义细化 |
| F11 | ⌘1–9 快选（复制并关闭，与 ⏎ 同语义） | P1 | S | 前 9 行一键取用 | 非 US 键位 |
| F12 | 面板记住尺寸 | P2 | S | 调整后的尺寸跨会话保留 | 多屏夹取 |
| F13 | 其余体验项：失败可见、去掉 Recent 段头遥测、状态栏右键菜单、Launch at Login 等 | P1/P2 | S 各 | 见 §2.13 | 见 §2.13 |
| F14 | 结构拆分与术语统一（ViewModel/行视图/Pipeline/Coordinator） | P2 | M（增量） | 大文件 ≤ ~500 行；搜索状态机脱离 SwiftUI 可单测 | 纯重构回归 |

总体判断：

1. 搜索打字的 90–180 ms 不是一个成本，而是四个在 HEAD 可逐行定位的乘数叠加：一次按键发布两次（F3）；两次发布都整组替换最多 50 行（F4）；"相同 refine"和分页-only 变更仍然让整张 List 重跑（F2，旧评审认为已修，实际只修了一半）；零结果和空预筛让 List 在 `EmptyStateView` 与 List 之间来回卸载重建、提示行让列表每键跳一行（F1、F3）。
2. 最有把握的收益来自 F4：v0.80.1 已用 20 行分块把分页最长回调从 91.7 ms 压到 58.3 ms，按同一模型首块 ≤ 16 行可落在 50 ms 以下；F1–F3 再把"每键更新次数"和"每次更新涉及行数"降下来。
3. 旧评审否决"每键一次发布"的理由（需要 deadline race）在 HEAD 可以用"两个 MainActor 任务 + 一个带版本号的槽"实现，不需要任何并发原语，所有分支可枚举成 8 个单测；收益也比当时估计的"1.5→1.0 次更新"大（还顺带消掉空页闪烁、提示行抖动与 FTS 排序→fuzzy 排序的重排）。
4. 悬停停顿的已归因栈是 popover 窗口因 SwiftUI 尺寸极值变化而同步 resize；F5 先让尺寸在呈现前确定并冻结、让呈现不再触发整表 diff，F6 只有在 F5 实测后仍 > 50 ms 时才做。
5. 体验缺口里最该先做的是两个 P0：可撤销删除（⌥⌫ 在搜索框里删的是悬停选中的条目，且无撤销）和折叠置顶区的键盘导航错位。其余都是 S 级。
6. 所有设计都不触碰滚动路径（天花板已关闭）、不改 ⏎ 语义、不做隐私跳过、不改渲染契约。

## 0.1 终审修正（2026-09-24，主线程 + Codex 第二方复核）

以下裁定优先于本文正文；证据见 [review-roadmap-2026-09-24.md](./review-roadmap-2026-09-24.md) §9。

- **F3、F4 改为条件项。** 先落地 F1 与缩小的 F2，用修好的 `profile_search.py`（`--reuse-db`）复测；只有单键阻塞仍 ≥ 50 ms 才重新设计。F4 若重启，首块行数用常量 16 而不是视图写入 VM 的 `visibleRowBudget`，且必须解决"尾块中的选中项不在 `items` 中而 `selectCurrent()` 按 `items` 查找"与滚动锚点保留的问题；`hasMore` 只表示服务端还有数据。
- **F2 按实际消费者扩展现有 selection fanout**（先分离 projection 与分页的观察边界，再加证据通道），不预建通用的行状态与动作体系。
- **F8 拆为两项。** F8a（P0，S）：⌥⌫ 的 AppKit 监视器按事件所属窗口与 first responder 判定，任何文本编辑（搜索框、备注编辑器）中不删除条目；F8b（撤销，产品 P2，需 hh 决定）。
- **F11 与 F13 的菜单/登录项降为 P2**；F13 的"失败可见"（pin/delete/clear）保持 P1。
- **F5 中"hover 一律用静态 QuickLook 图"是产品变化**，需 hh 决定；几何预计算、hash 只算一次（与 P-R2 合并）先做。
- **K7（隐藏预测量）不按"以代码为准改规格"处理**：先实机验证 prewarm 的 paint-timeout 路径（300 ms 预热、最长 2 s 延迟、1,500 ms 离屏 watchdog）再定规格措辞。
- **新增 F15（P1，S）：搜索失败不得显示为"无结果"。** `HistoryViewModel.startSearch` 的失败分支调用 `clearSearchProjection()` 并把 `searchCoverage` 设为 `.complete`（`HistoryViewModel.swift:1154-1157`），空列表随即显示 "No results"；首次 `load()` 与 `loadMore()` 的失败也只写日志。Codex 第二轮按路径精确核实：事件刷新失败保留旧行并标 `.incomplete`（Regex/短 Exact 的范围提示会遮住 Partial，`:437, 1167`）；`load()` 行已发布但 stats 失败时列表有行、Footer 0 items、不能分页（`:823, 838`）；`loadMore()` 强制 refine 失败不更新 coverage，可能一直显示 Calibrating（`:956, 974, 1027`）。修复须区分这些终态并提供重试，不是一条通用 toast。
- **F13 附注：** `PinnedPreviewController` 读取逐条目 frame 名却只保存共享名（`PinnedPreviewController.swift:104-105, 121`），删除无消费者的逐条目分支。
- F14 的拆分不以行数驱动，只在被功能改动触及时按职责缝提取；不为未批准的 F3 预建 `HistorySearchSession`。

## 1. 现状与证据

### 1.1 尺寸与热点

| 文件（HEAD） | 行数 | 说明 |
| --- | ---: | --- |
| `Scopy/Views/History/HistoryItemView.swift` | 2,174 | 行视图 + hover FSM + 导出/备注/优化编排；约 130 行是对 `interactionState` 的 get/set 转发（`:185-318`），三个 popover 块 80% 重复（`:1098-1234`） |
| `Scopy/Observables/HistoryViewModel.swift` | 1,703 | 前 272 行是 revision 注册表；搜索状态机（`:1053-1165`）与发布原语（`:1571-1667`）混在一起 |
| `Scopy/Views/History/HistoryHoverPreviewPipeline.swift` | 792 | 请求/计划（纯）、四条异步流程、缓存策略、计时日志（带进程全局 `textHoverStartedAt`，`:557`） |
| `Scopy/Views/History/HistoryItemTextPreviewView.swift` | 791 | body 每次求值都重算文本尺寸与 3 次全文哈希（`:77-82`、`:96-103`） |
| `Scopy/Views/HistoryListView.swift` | 672 | List + popover 呈现协调（`:326-487`）+ 行闭包工厂 |
| `Scopy/Views/History/HistoryListInteractionCoordinator.swift` | 475 | 含只为测试存在的非 token API 与 legacy 广播（`:108-110`、`:232-238`、`:296-299`、`:315-325`、`:344-347`、`:450-456`） |

### 1.2 搜索打字：HEAD 的真实数据流

一次按键（Fuzzy/Fuzzy+，≥ 3 字符，FTS 预筛命中）在 HEAD 依次发生：

1. `HeaderView.swift:22-29`：`TextField` 绑定 `searchQuery`，`.onChange` 调 `historyViewModel.search()`。
2. `HistoryViewModel.swift:1053-1080`：取消旧任务、`searchVersion += 1`、`isLoading = true`（`:1074`）；`isLoading` 在 searchTask 结束时（预筛发布并派生 refine 之后，而不是 refine 完成之后）置回 false（`:1076-1080`）。
3. `:1100-1104`：第一次 `service.search` → `replaceSearchPage(with:)`（`:1571-1594`：`listState.replacePage` + `searchMatchContexts = contexts`）→ **发布 #1** → `searchCoverage = .stagedRefine`。
4. `:1106-1141`：refine（`forceFullFuzzy`，≤ 2 字符先等 10 ms）→ `replaceSearchPage(skippingIdenticalRefine: true)` → **发布 #2**；即使结果与预筛相同，也走 `listState.updatePagination`（`:1580-1585`）。
5. `:1151-1153`：每键两次 actor 跳转（`recordSearchLatency`、`getSummary`）只为 "Recent" 段头显示平均值。

列表侧的四个乘数（全部已在代码中核实）：

- **(a) 单一观察单元。** `listState` 是 `@Observable` 类里一个未忽略的存储属性（`HistoryViewModel.swift:326`），`pinnedItems/unpinnedItems/items/canLoadMore/loadedCount/totalCount/itemsRevision` 全部经它读取（`:348-432`）。Observation 宏为存储属性生成的 `_modify` 对任何原地修改都无条件通知，所以 `updatePagination`（`HistoryListState.swift:70-73`）、`updateTotalCount`（`HistoryViewModel.swift:841`，每次 `load()` 之后）都会让 `HistoryListView.body` 重跑。旧评审 §5.7 第一条"相同判定包含 total"在 HEAD 已修（`:1580-1582` 只比 items 与 contexts），但"相同 refine 不重建 List"仍不成立；`development-guide.md:154` 写的"`replaceSearchPage` is a no-op"与代码不符。
- **(b) 每键变化的状态进了 List body。** `HistoryListView.swift:85-89` 用整个 `searchMatchContexts` 字典和 `activePopover`（`@State`，`:42`）构造 `HistoryRowContext` 传给每一行。这直接违反 `development-guide.md:151` 自己定的规则（"anything else that changes per interaction should reach rows the same way"）。每行的 `HistorySelectionAwareRow`（`:615-646`）带内容闭包、不可比较，所以每次 body 重跑，所有已挂载行的包装 body 都会重跑并重新 `init` `HistoryItemView`（计数器 `row.init`，`HistoryItemView.swift:126`；实测 8 键 1,423 次）。
- **(c) 空结果卸载整张 List。** `HistoryListView.swift:56-61`：`items.isEmpty && !isLoading` 时用 `EmptyStateView` 替换整个 `ScrollViewReader { List }`。零结果状态下每次按键：`isLoading = true` → List 重新创建（`:70-77` 的 ProgressView 行）→ 结果为空、`isLoading = false` → List 再次销毁。后端在 FTS 预筛为空时返回空的 `.stagedRefine` 页（`SearchEngineImpl.swift:2310-2312`），于是 Fuzzy+ 的半词输入（refine 能命中、FTS 不能）也会先闪一次 "No results" 并卸载 List，refine 到达后再整表重建。这很可能是"零结果 `zqxjv` 仍 175 ms"的主要来源（待 F0 计数确认）。
- **(d) 提示行让列表每键跳一行。** `HeaderView.swift:58-64` 在 `searchCoverageHint != nil` 时多出一行 footnote；`.stagedRefine` 对应一句约 30 字的提示（`HistoryViewModel.swift:444-445`），refine 后变回 `.complete` 即消失。头部与 List 在同一 `VStack`（`ContentView.swift:59-75`），所以每键 List 高度先缩后涨，NSTableView 的可见区两次变化。

行高：行本身已是"按形状固定"——正文与次行都 `lineLimit(1)`（`HistoryItemView.swift:848-856`、`:869-873`、`:877-885`），证据行与元数据行同一字体；`.frame(minHeight:)`（`:1017`）只作下限。SwiftUI List 在 macOS 上不暴露固定行高或 `estimatedRowHeight`，滚动研究已测得逐行 `.frame(height:)` 更差（4.13 s）。因此"可变高度"在这里的真实含义是：**每次更新里内容变化或新插入的行数**决定了 `_doAutomaticRowHeightsForInsertedAndVisibleRows` 的工作量——这是 F2/F4 的杠杆，而不是把高度写死。

### 1.3 悬停呈现：HEAD 的真实数据流

1. `HistoryItemView.swift:1345-1398` `handleHover` → `:1400-1441` `activateHoverActionsIfAllowed`：先 `dismissOtherPopovers()`（异步改列表 `@State`，`HistoryListView.swift:333-356`），150 ms 后写 `selectedID`（`:1413-1426`），再启动 pipeline。
2. Pipeline 300 ms 预取（`HistoryHoverPreviewPipeline.swift:135`），到设置延迟（默认 1.0 s）发 `.present(kind)`。
3. `presentPopover`（`HistoryListView.swift:430-475`）写 `activePopover`（`@State`），List body 因 `:87` 读取而**整表重跑**；源行 `isXPreviewPresented` 变 true（`:509-512`），行上的 `.popover(isPresented:)`（`HistoryItemView.swift:1098-1234`）创建 popover。一次行间移动 = 关闭一次 + 呈现一次 = 两次整表 diff。
4. popover 内容的尺寸在每次 body 求值时现算：`HoverPreviewSizeBudget` 每次访问都读 `NSEvent.mouseLocation` 与 `NSScreen.screens`（`HoverPreviewSizeBudget.swift:19-29` → `HoverPreviewScreenMetrics.swift:6-41`）；纯文本在 body 里做 TextKit 测量（`HistoryItemTextPreviewView.swift:64-82`，Markdown 也会算一遍兜底高度）；body 还做 3 次全文 SHA-256（两次 `markdownRenderKey` + 一次 `enrichmentFingerprint`，`:96-103`，`HoverPreviewModel.swift:41-66`）。
5. 呈现后的尺寸变化（每次都触发一次极值重算与窗口 `setFrame`）：图片解码完成前高度用缩略图比例或 120 pt 占位（`HistoryItemImagePreviewView.swift:70-88`）；文件的 `isFileAvailable` 在异步存在性检查后翻转，高度从图标比例跳到最大高（`HistoryItemFilePreviewView.swift:87-90`、`:194-196`、`:220-237`）；视频自然尺寸异步到达（`:88-89`、`:184-192`）；Markdown 终态 metrics 与预热探针不同（`HistoryItemTextPreviewView.swift:86-89`、`:268-291`）。
6. QuickLook：`.other` 类文件在可用后直接在主线程构造 `QLPreviewView`（`HistoryItemFilePreviewView.swift:98-99` → `QuickLookPreviewView.swift:22-30`）。Pipeline 其实已经写好了离主线程的 QL 缩略图分支（`HistoryHoverPreviewPipeline.swift:391-396`），但 `FilePlan.shouldPrefetchImage` 只对 image/video 为真（`:216`），预取任务在 `:366` 就返回——**这段代码在 HEAD 不可达**。

已测归因（2026-09-03）：`NSHostingView.updateWindowContentSizeExtremaIfNecessary → -[_NSPopoverWindow setFrame:display:] → _layoutViewTree`，约占悬停窗口主线程样本 9%，与停顿总量吻合。

### 1.4 内存：HEAD 的实际上限

| 缓存 | HEAD 上限 | 证据 | 释放时机 |
| --- | --- | --- | --- |
| `HoverPreviewImageCache` | 40 项 / 320 MB，单项 ≤ 256 MB（= 64 Mpx 解码预算 × 4 B） | `HoverPreviewImageCache.swift:26-30`、`:66-69` | 60 s 滑动 TTL；15 s 清扫循环从首次访问起永不停止（`:88-99`）；NSCache 系统压力回收 |
| `ThumbnailCache` | 1,000 项，无字节上限 | `ScopyUISupport/ThumbnailCache.swift:425`、`:433` 无 cost | NSCache 自动。快照实测 182 个缩略图，平均解码 28 KB、最大 592×60（`sips` 读取 `perf-db/thumbnails`），现实 ≤ 30 MB，但宽度无界时无保护 |
| `MarkdownPreviewCache` | HTML 200 项 / 8 MB；metrics 400；文件预览 64 项 / 16 MB | `MarkdownPreviewCache.swift:36-45` | NSCache 自动 |
| `ClipboardItemContentRevision.memo` | 8,192 项，**每项持有整段 `plainText`** | `ClipboardItemContentRevision.swift:48-83`（`:58`、`:67`） | 仅 NSCache 压力回收；文本族条目已有 `contentHash`，持文本只为 `matches` 比较 |
| `HistoryItemPresentationCache` | 5 × 4,096 项 | `HistoryItemPresentationCache.swift:57`、`:85-89` | 无 |
| `ClipboardItemDisplayText` | 2 × 20,000 项（`reserveCapacity` 预分配） | `ClipboardItemDisplayText.swift:136`、`:152-153`、`:13-18` | 无 |
| `IconService` | 500 图标 + 500 名称；**未命中（已卸载应用）不缓存**，每次行 body 都走一次 LaunchServices | `ScopyUISupport/IconService.swift:14-18`、`:26-37` | NSCache 自动 |
| 悬停 WKWebView | 列表构造时即创建并常驻（`HistoryListView.swift:35`），每个 `.nonPersistent()` 独立数据存储（`MarkdownPreviewWebView.swift:639-658`） | — | 生命周期由渲染评审处理 |

全仓无 `DispatchSource.makeMemoryPressureSource`。已测"一次搜索会话后 93 → 192 MB 不回落"主要归后端 fuzzy 索引；前端可控部分是 revision memo 持有的正文（本快照正文合计 19.5 MB）与悬停位图的 60–75 s 滞留。

### 1.5 体验缺口在 HEAD 的核实

| 缺口 | HEAD 状态 | 证据 |
| --- | --- | --- |
| ⌘1–9 快选 | 仍缺 | `ContentView.swift:77-110` 只处理 ↑↓⏎⎋⌥⌫⌘⌫；`AppDelegate.swift:249-278` 只拦 ⌥⌫ 与 ⌘, |
| 删除可撤销 | 仍缺；且 ⌥⌫ 在 AppKit 层被截获，只要 `selectedID != nil` 就删除，搜索框里的"删一个词"永远删的是条目（`AppDelegate.swift:254-267`）；UI 测试把它固定为行为（`KeyboardNavigationUITests.swift:57`） | `HistoryViewModel.swift:1308-1318` 直接调用 `service.delete` |
| ⌥⌫ 注册 | 三处 + 页脚按钮：`AppDelegate.swift:256-267`、`ContentView.swift:79-82`、`HistoryListView.swift:178-184`、`FooterView.swift:82-84`；后两个 SwiftUI 处理器只在 `selectedID == nil` 时才收到事件，而此时 `deleteSelectedItem` 立即返回——实际是死路径 | 同左 |
| 悬停写 `selectedID` | 仍在（150 ms 后）；**但它是规格要求**：`product-spec.md:156` "hover can still update row selection while the field is focused" | `HistoryItemView.swift:1413-1426` |
| 键盘导航进入折叠的置顶区 | **新发现**：`highlightNext/Previous` 遍历含置顶项的 `items`，不看 `isPinnedCollapsed`；从无选中按 ↓ 会选中看不见的置顶项，⏎ 复制它、⌥⌫ 删除它 | `HistoryViewModel.swift:1356-1382`、`:806-814`、`HistoryListView.swift:106-110` |
| 面板记住尺寸 | 仍缺（`.resizable` 但无 autosave） | `FloatingPanel.swift:58`（HEAD） |
| `resignKey` 一刀切 | 已部分处理：点击落在固定预览窗口时不关（`FloatingPanel.swift:206-215`、`:29-43`，v0.80.0）；点击 hover popover 内部是否使 popover 成为 key 并关闭面板**无法静态确定**（见 §5 待核实） | — |
| 状态栏右键菜单 | 仍缺；Quit 在页脚与删除相邻 | `AppDelegate.swift:29-35`、`FooterView.swift:81-96` |
| Launch at Login | 仍缺（全仓无 `SMAppService`） | — |
| 失败可见 | 复制与 Codex 复制已进页脚（`HistoryViewModel.swift:1230-1262`）；置顶、删除、清空仍只写日志（`:1294-1336`）；AirDrop 不可用、无文件可揭示时静默返回（`:1270-1284`）；备注保存失败在编辑器内可见 | 同左 |
| Recent 段头遥测 | 仍在，且每键付出两次 actor 跳转 | `SectionHeader.swift:32-44`、`HistoryViewModel.swift:1151-1153` |
| About 遥测 | 仍在（"性能监测""Ingest 诊断"）；**规格要求** "lightweight performance metrics"（`product-spec.md:92`） | `AboutSettingsPage.swift:65`、`:96` |

### 1.6 与旧评审（2026-09-03）对照

| 旧条目 | HEAD 结论 |
| --- | --- |
| §5.7 "相同判定包含 total，守卫几乎不生效" | 判定已修（`HistoryViewModel.swift:1580-1582`），但跳过路径仍修改 `listState` 并重跑整表 → 由 F2 收尾 |
| §5.7 "翻过第一页后 refine 被跳过" | 排序已收敛：staged 状态下 load-more 强制全量并先追加后原子替换（`:955-979`、`:1596-1617`）；剩余问题是被 `loadedCount <= initialPageSize` 丢弃的 refine 让 coverage 停在 staged 直到下一次 load-more（`:1106-1108`、`:1138`） |
| §5.7 "refine 落地时选中不在新页即丢失" | 仍成立（`:1663-1667`），F4 需按整页而非首块判定 |
| §7.2 悬停写 `selectedID` | 仍成立，但受 `product-spec.md:156` 约束，不能删除，只能细化为 F10 |
| §7.3 `Settings { EmptyView() }` 打开空窗口 | **不成立于用户路径**：`Info.plist:35-36` `LSUIElement = true`，无应用菜单栏 |
| §7.3 `resignKey` 无条件关闭 | 部分已处理（固定预览例外）；popover 内点击待实机核实 |
| §7.4 失败只写日志 | 复制类已处理；置顶/删除/清空仍缺 → F13 |
| §8.6 `HoverPreviewImageCache` 回到 160/128 MB | 与 64 Mpx 解码预算冲突（单项需 256 MB 才能缓存最大解码，round 2 为此上调），改为 F7 的生命周期释放，不下调上限 |
| §8.6 WebView 启动即常驻 | 仍成立（归渲染评审）；另见 F7 附注 |
| §8.8 `ProcessInfo.arguments` 每次调用 | 行 `onAppear` 已修为 `static let`（`HistoryItemView.swift:64-66`）；仍有 `HistoryItemTextPreviewView.swift:236-238`（每次 body 多次）与 `MarkdownPreviewWebView.swift:1071`（每次 `updateNSView`） |
| 第三轮记忆"prefilter/refine 合并回归风险大于收益" | 重新评估见 F3：风险可控、收益更大 |

## 2. 逐项改进

### 2.0 F0 测量前置（P1，S）

**问题。** `scripts/perf-scroll/profile_search.py:54` 复制的仍是已不存在的 `clipboard.db.fullindex.v4.plist`，而 `profile_scroll.py:34-35` 已改为 v5/v3 `.bin`。结果是每次 `make perf-search-type` 都在 6 s settle 期内重建全量索引，staged/refine 路径与用户真实状态不同。输出也只打印计数器名字不打印 `list.body` 的值。

**设计。**
- `make_db()` 复用 `profile_scroll.py` 的文件列表（v5 full index、v3 short index 及其 `.sha256`/metadata）。
- 结果段额外打印 `list.body`、`row.init`、`list.pagination_search_chunk`、新增的 `search.publication`（F3 引入，每次对 projection 的替换/追加 +1）与 `search.keystroke` 计数。
- 可选：在打字窗口内并行运行 `build/hoverstall`（指针停在头部而不是列表上），输出每次 > 50 ms 的停顿；`runloop busy max` 仍是主门槛。

**验收基线（F1–F4 共用，`QUERY=markdown RATE=8`，warm `--reuse-db`，Release）。** 记录：`cpu over typing + 2s tail`、`app profiler: runloop busy ms <total> p95 <p95> max <max>`、`row.init`、`list.body`、`search.publication`。已知参考：阻塞总计 440 ms、单块最大 131–177 ms、`row.init` 1,423、CPU 2.53 s。

**门禁。** `make test-tooling`。注意代码卫生审计 D6 建议归档 `hoverstall.swift`：本提案依赖它做交叉验证，归档前需把停顿计并入 `profile_search.py`。

### 2.1 F1 空结果不卸载 List；不发布空 staged 页（P1，S）

**问题。** 见 §1.2 (c)。

**设计。**
- `HistoryListView.body` 不再在 List 与 `EmptyStateView` 之间切换：List 始终挂载，空态改为叶子覆盖层：

```swift
// HistoryListView.swift
ScrollViewReader { proxy in List { /* 不再含 isLoading 的 ProgressView 行 */ } ... }
    .overlay { HistoryListEmptyOverlay(openSettings: openSettings) }

private struct HistoryListEmptyOverlay: View {          // 叶子：只有它读 isLoading/hasActiveFilters
    @Environment(HistoryViewModel.self) private var vm
    let openSettings: (() -> Void)?
    var body: some View {
        if vm.items.isEmpty {
            if vm.isLoading { ProgressView().controlSize(.small) }
            else { EmptyStateView(hasFilters: vm.hasActiveFilters, openSettings: openSettings) }
        }
    }
}
```

  这样 `HistoryListView.body` 完全不再读取 `isLoading`（今天 `:56`、`:70` 在空列表时读取）。
- ViewModel：staged 预筛页为空且 refine 将要运行时不发布（保留当前行，符合 `development-guide.md:154` "keeps the current rows on screen until the versioned replacement arrives"），并让 `isLoading` 覆盖到 refine 结束或失败，而不是 searchTask 结束（`:1076-1080`）。最终结果为空才显示空态。

**实现步骤。** ① 覆盖层替换分支（纯视图）；② VM 的"空 staged 页不发布 + in-flight 覆盖 refine"。两步可分开提交。

**涉及文件。** `Scopy/Views/HistoryListView.swift`、`Scopy/Views/History/EmptyStateView.swift`（不变，仅被覆盖层使用）、`Scopy/Observables/HistoryViewModel.swift`。

**门禁。** `make build`、`make test-unit`；VM 任务时序改动加 `make test-strict`；`make perf-frontend-profile` smoke；`make perf-search-type QUERY=zqxjv` 与 `QUERY=arkdo`（半词）。

**守护测试。**
- `SearchStateMachineTests.testEmptyStagedPrefilterIsNotPublishedWhileRefineIsPending`：staged 空页 + 挂起的 refine → `items` 保持上一键的行、`isLoading == true`；refine 恢复后一次替换。
- `testEmptyFinalResultEndsLoading`：refine 最终为空 → `items.isEmpty && !isLoading`。
- 计数验收：`profile_search` 打 `zqxjv` 时 `ListLiveScrollObserverView` 的 scroll view attach 次数在整个会话中为 1（今天每个零结果键 +1，用现有 `onScrollViewAttach` 计数）。

**风险。** 覆盖层遮挡 List 的命中测试：空态时 List 无行，不存在遮挡；非空时覆盖层不渲染任何视图。

### 2.2 F2 行级实时状态扇出 + projection 与分页的观察拆分（P1，M）

**问题。** 见 §1.2 (a)(b)。

**证据。** `HistoryViewModel.swift:326`、`:348-432`、`:1580-1591`；`HistoryListView.swift:85-89`、`:491-573`、`:615-646`；`HistoryRowSelectionFanout.swift:9-44`。

**设计 1：一个扇出类型承载所有"每次交互都变"的行状态。** 把 `HistoryRowSelectionFanout` 泛化（不新增第二套机制）：

```swift
// Scopy/Views/History/HistoryRowLiveState.swift（替换 HistoryRowSelectionFanout.swift）
struct HistoryRowLiveState: Equatable {
    var isSelected = false
    var evidence: SearchMatchContext?
    var presentedPreview: HoverPreviewPopoverKind?      // F5 使用；F2 先恒为 nil
}

@MainActor
final class HistoryRowLiveStateFanout {
    private(set) var selectedID: UUID?
    private var evidence: [UUID: SearchMatchContext] = [:]
    private var presented: HoverPreviewPopoverState?
    private var sinks: [UUID: (HistoryRowLiveState) -> Void] = [:]
    var onSelectionChanged: ((UUID?, Bool) -> Void)?

    func state(for id: UUID) -> HistoryRowLiveState
    @discardableResult func register(itemID: UUID, sink: @escaping (HistoryRowLiveState) -> Void) -> HistoryRowLiveState
    func unregister(itemID: UUID)
    func updateSelection(_ id: UUID?, follow: Bool)             // 通知旧/新两行
    func replaceEvidence(_ next: [UUID: SearchMatchContext])    // 只通知已注册且值变化的行，O(旧∪新)
    func updatePresentedPreview(_ next: HoverPreviewPopoverState?)
}
```

`HistorySelectionAwareRow` 改名 `HistoryLiveRow`，持有 `@State var live: HistoryRowLiveState`（init 取 `fanout.state(for:)`，`onAppear` 注册、`onDisappear` 注销），把 `live.isSelected/live.evidence` 作为 `HistoryItemView` 的输入。`HistoryRowContext` 只剩 `settings`。**顺序约束**：VM 必须先更新扇出（证据），再修改 `listState`，这样同一轮新插入的行在 init 时就能读到自己的证据——等价于 `appendSearchPage` 现有的"证据与行同一 actor 回合"不变量（`HistoryViewModel.swift:1632-1633`）。

**设计 2：行集合与分页分开观察。**

```swift
// HistoryViewModel
@ObservationIgnored private var listState = HistoryListState()
private(set) var itemsRevision: UInt64 = 0      // 观察单元：仅当行数组变化时写
private(set) var totalCount = 0                  // 仅在值变化时写
private(set) var canLoadMore = false             // 仅在值变化时写
var pinnedItems: [ClipboardItemDTO] { _ = itemsRevision; return listState.pinnedItems }
var unpinnedItems: [ClipboardItemDTO] { _ = itemsRevision; return listState.unpinnedItems }
var items: [ClipboardItemDTO] { _ = itemsRevision; return listState.items }

private func mutateProjection(_ change: (inout HistoryListState) -> Void) {
    change(&listState)
    if itemsRevision != listState.itemsRevision { itemsRevision = listState.itemsRevision }
    if totalCount != listState.totalCount { totalCount = listState.totalCount }
    if canLoadMore != listState.canLoadMore { canLoadMore = listState.canLoadMore }
}
```

所有 `listState.x(...)` 调用点（约 20 处）改为 `mutateProjection { $0.x(...) }`。`replaceSearchPage` 在"ID 序列相同"时只做逐项 `setItemIfChanged`、证据走扇出、分页走守卫写入——结果是证据-only 与分页-only 的发布对 `HistoryListView.body` 为 0 次。

**可选子步 F2c（仅当 F0 计数显示包装 body 重跑仍占主导）。** 把行闭包（`HistoryListView.swift:518-555` 每行每次 body 约 15 个闭包）收成一个列表级引用 `HistoryRowActions`（方法以 item 为参数），`HistoryLiveRow` 变为可 `Equatable`（item 可变字段 + settings 子集 + actions 身份），List body 重跑时未变化的行连包装 body 都不求值。

**实现步骤。** ① 泛化扇出，只迁移选中，零行为变化；② 证据改走扇出，List body 不再读 `searchMatchContexts`；③ `mutateProjection` 拆分观察；④（可选）F2c。

**涉及文件。** `Scopy/Views/History/HistoryRowSelectionFanout.swift`（替换）、`Scopy/Views/HistoryListView.swift`、`Scopy/Views/History/HistoryItemView.swift`（输入不变，仅来源变化）、`Scopy/Observables/HistoryViewModel.swift`、`Scopy/Views/UITesting/HistoryItemHarnessView.swift`（构造参数）、`ScopyTests/HistoryRowSelectionFanoutTests.swift`。

**门禁。** `make build`、`make test-unit`、`make test-strict`；`make perf-frontend-profile`（standard 建议）；`make perf-search-type`；滚动无关但行包装变化，按 `development-guide.md:149` 跑一次 `perf-scroll-wheel` 确认不回归（±4% 内）。

**守护测试（写出断言意图）。**
- `HistoryViewModelRegressionTests.testIdenticalRefineDoesNotInvalidateListRows`：`withObservationTracking { _ = vm.pinnedItems; _ = vm.unpinnedItems; _ = vm.canLoadMore } onChange: { XCTFail }` 包住一次 total 从 -1 变为 50、`hasMore` 不变的相同 refine。**这条测试在 HEAD 会失败**，可作为第一步的"先红后绿"证据。
- `testEvidenceOnlyChangeNotifiesOnlyChangedRegisteredRows`（扇出单测）：注册 A、B，替换证据只改 A → 只有 A 的 sink 被调用；未注册的 C 在注册时拿到最新证据。
- `testNewRowSeesEvidenceAtInit`：先写扇出再改 projection 的顺序被破坏时失败。
- 现有 `testIdenticalRefinedPrefixUpdatesTotalsWithoutRebuildingRows` 保留。

**风险。** 行在 `onAppear` 之前的一帧读到旧 `@State`：与今天选中扇出相同的时序，已被 `HistoryRowSelectionFanoutTests` 覆盖；新增证据用例同样覆盖。

### 2.3 F3 每键一次发布（staged 截止槽）+ 去掉瞬时提示行（P1，M；需 hh 决定）

**问题。** 见 §1.2 第 3–4 步与 (d)。一次按键两次整表发布，第二次常常只是把 FTS 排序换成 fuzzy 排序；两次之间提示行出现又消失。

**为什么这次风险可控。** 旧的否决理由是"需要 deadline race"。这里不做 race 原语，而是两个 `@MainActor` 任务共享一个带版本号的槽，谁先到谁消费，所有分支都在主 actor 上串行：

```swift
// Scopy/Observables/HistorySearchSession.swift（F14 抽出的新类型；VM 持有）
@MainActor
final class HistorySearchSession {
    struct Timing { var debounceNs: UInt64; var shortQueryMinDelayNs: UInt64
                    var refineShortQueryDelayNs: UInt64; var stagedPublishDeadlineNs: UInt64 }
    enum Output { case replace(SearchResultPage, coverage: SearchCoverage, skipIfIdentical: Bool)
                  case coverage(SearchCoverage); case failed(clearsProjection: Bool); case inFlight(Bool) }

    private(set) var version = 0
    private var searchTask, refineTask, deadlineTask: Task<Void, Never>?
    private var pendingStaged: (version: Int, page: SearchResultPage)?   // 唯一的槽

    func start(_ request: SearchRequest, refine: SearchRequest?, clearsProjectionOnFailure: Bool) {
        cancel(); version &+= 1; let v = version
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timing.stagedPublishDeadlineNs))
        output(.inFlight(true))
        searchTask = Task {
            try? await Task.sleep(nanoseconds: timing.debounceNs)       // 现有 0/16 ms 规则不变
            guard v == version else { return }
            do {
                let first = try await service.search(query: request)
                guard v == version else { return }
                guard first.coverage.isStagedRefine, let refine else {
                    output(.replace(first, coverage: first.coverage, skipIfIdentical: false)); output(.inFlight(false)); return
                }
                pendingStaged = (v, first)
                deadlineTask = Task { try? await Task.sleep(until: deadline); self.publishPendingStaged(v) }
                refineTask = Task { await self.runRefine(refine, version: v) }
            } catch { guard v == version else { return }; output(.failed(clearsProjection: clearsProjectionOnFailure)); output(.inFlight(false)) }
        }
    }

    private func publishPendingStaged(_ v: Int) {            // 截止先到
        guard v == version, let p = pendingStaged, p.version == v else { return }
        pendingStaged = nil
        guard !p.page.hits.isEmpty else { return }           // F1：空 staged 页从不发布
        output(.replace(p.page, coverage: .stagedRefine, skipIfIdentical: false))
    }

    private func runRefine(_ request: SearchRequest, version v: Int) async {   // refine 先到或失败
        do {
            let refined = try await service.search(query: request)
            guard v == version else { return }
            let prefilterWasPublished = pendingStaged == nil
            pendingStaged = nil; deadlineTask?.cancel()
            output(.replace(refined, coverage: refined.coverage, skipIfIdentical: prefilterWasPublished))
        } catch {
            guard v == version else { return }
            if let p = pendingStaged, p.version == v { pendingStaged = nil; deadlineTask?.cancel()
                output(.replace(p.page, coverage: .incomplete, skipIfIdentical: false)) }
            else { output(.coverage(.incomplete)) }
        }
        output(.inFlight(false))
    }
}
```

- 截止时间从**按键时刻**起算，建议初值 50 ms（`Timing.production.stagedPublishDeadlineNs`；测试用现有 `Timing.tests` 模式注入）。已测"应用自身搜索 12–39 ms"、`test-snapshot-perf-release` 的 cmd p95 0.575 ms、cm p95 5 ms，warm 状态下 refine 预计几乎总在截止前到达；冷索引或 10 万条时退化为今天的两次发布，首屏最多晚 50 ms。
- `loadMore` 仍以 `!isLoading` 守卫（`HistoryViewModel.swift:944`）；因为 in-flight 覆盖到 refine 结束，挂起槽期间不会翻页，`loadedCount <= initialPageSize` 的丢弃分支（`:1106-1108`、`:1138`）随之消失。
- **提示行**：`searchCoverageHint`（`:437-458`）对 `.stagedRefine` 返回 nil；"Calibrating" 仍在模式菜单标签里（`HeaderView.swift:100`、`HistoryViewModel.swift:460-474`）。`.recentOnly` 与 `.incomplete` 是持续状态，保留提示行（`product-spec.md` 对 Exact ≤ 2 与 Regex 要求"must say so in the UI"，不受影响）。

**实现步骤。** ① 纯搬移：把 `startSearch`/refine/`effectiveSearchDebounceNs` 搬进 `HistorySearchSession`，输出通过 `Output` 回调调用 VM 现有的 `replaceSearchPage/clearSearchProjection`，行为不变；② 引入截止槽；③ 去掉 staged 提示行；④ 删掉 VM 里每键的 `getSummary`（与 F13 的 Recent 段头遥测一起）。

**涉及文件。** 新增 `Scopy/Observables/HistorySearchSession.swift`；`Scopy/Observables/HistoryViewModel.swift`；`ScopyTests/SearchStateMachineTests.swift`、`ScopyTests/HistoryViewModelRegressionTests.swift`（沿用 `suspendNextRefine/resumeRefine/returnsStagedFirstPage` 夹具）。

**门禁。** `make build`、`make test-unit`、`make test-strict`（任务时序）；`make perf-search-type`（`markdown`、`the`、`状态`、`zqxjv`）；结论写入 `make perf-unified-table` 并记录环境与数字。

**守护测试（8 条，覆盖全部分支）。**
1. `testRefineBeforeDeadlinePublishesOnce`：`search.publication` = 1，最终顺序 = refine 顺序，`searchCoverage` 在观察期内从未等于 `.stagedRefine`。
2. `testDeadlineBeforeRefinePublishesPrefilterThenRefine`：2 次发布，staged → complete。
3. `testRefineFailureBeforeDeadlinePublishesPrefilterAsIncomplete`。
4. `testRefineFailureAfterDeadlineKeepsRowsAndMarksIncomplete`。
5. `testNewKeystrokeWhilePendingDropsPrefilterAndRefine`：旧版本任何输出都不到达。
6. `testEmptyStagedPageIsNeverPublished`（与 F1 共享）。
7. `testLoadMoreIsBlockedUntilRefineCompletes`。
8. `testSelectionSurvivesSinglePublication`：选中行在最终页中则保留。

**需要 hh 决定。** (a) 采纳"每键一次发布"，推翻 2026-09-03 的否决；(b) 截止初值 50 ms；(c) 去掉瞬时 staged 提示行、仅保留 "Calibrating" 标签。若否决 (a)，F1、F2、F4 仍可独立交付并满足单块 < 50 ms 的门槛，只是总 CPU 降得少。

### 2.4 F4 可见行优先的分块替换（P1，M）

**问题。** 搜索首页 50 行（`HistoryViewModel.swift:322`）在一次 `replacePage` 里原子替换（`:1586-1593`），而面板只看得见约 11–12 行（640 pt 面板，约 47 pt/行）。分页路径早已分块（`:1619-1655`，20 行/块、20 ms 间隔），替换路径没有。

**证据与估算。** v0.80.1 的 20 行分块把分页最长回调从 91.7 ms 降到 58.3 ms（`doc/perf/release-profiles/v0.80.1-profile.md`），折合约 2.5 ms/行（含帧基线）。按同一模型：首块 12–16 行 ≈ 30–40 ms，尾块 10 行 ≈ 25 ms，均低于 50 ms。这个线性模型需要 F0 的计数验证：若 `row.init`/行 body 次数随首块大小线性下降而单块时长不降，说明成本不在插入行数，F4 应停下，转查 F2c。

**设计。**

```swift
// HistoryViewModel
@ObservationIgnored var visibleRowBudget = 16      // HistoryListView 在 scroll view attach/resize 时写入 ceil(可见高度/最小行高)+2
static let searchTailChunkRows = 10

private func publishSearchPage(_ page: SearchResultPage, coverage: SearchCoverage, version: Int) async {
    let hits = acceptedSearchHits(page.hits)
    rowLiveState.replaceEvidence(contexts(of: hits))                   // 全部证据先行（F2 顺序约束）
    let headCount = displayHeadCount(hits, budget: visibleRowBudget)     // 折叠的置顶项不占预算
    mutateProjection { $0.replacePage(items: hits.prefix(headCount).map(\.item),
                                      total: page.total, hasMore: headCount < hits.count || page.hasMore) }
    reconcileSelection(againstFullPage: hits)                             // 按整页判定，不按首块
    searchCoverage = coverage
    await appendSearchTail(Array(hits.dropFirst(headCount)), page: page, version: version,
                           chunkRows: Self.searchTailChunkRows)          // 复用 appendSearchPage 的循环
}
```

- 尾块在每块前检查 `version`，新按键即作废——按 8 字符/秒打字时大部分尾块根本不会执行。
- 尾块期间 in-flight 为真，`LoadMoreTriggerView` 与 `rowDidAppear` 预取都被 `!isLoading` 挡住（`HistoryViewModel.swift:918-921`、`:944`）。
- `highlightNext` 在尾块未完成时到达末行不回绕到第一行（今天末行 → `items.first`，`:1360-1366`）。

**实现步骤。** ① `visibleRowBudget` 由 `HistoryListView` 写入（纯 plumbing）；② `replaceSearchPage` 走首块 + 尾块；③ 选中与键盘边界。

**涉及文件。** `Scopy/Observables/HistoryViewModel.swift`（或 F14 后的 `HistorySearchSession`）、`Scopy/Views/HistoryListView.swift`。

**门禁。** `make build`、`make test-unit`、`make test-strict`；`make perf-search-type`；`make perf-frontend-profile-standard`。

**验收（`make perf-search-type QUERY=markdown RATE=8`，warm，Release，与 F0 基线同机）。**
- `app profiler: runloop busy max` < 50 ms（今天单块 131–177 ms）；`hoverstall` 打字期间无 > 50 ms 停顿。
- `runloop busy total` ≤ 220 ms（今天阻塞总计 440 ms）。
- `row.init` ≤ 600（今天 1,423）；`list.body` ≤ 1.2/键。
- `cpu over typing + 2s tail` ≤ 1.5 s（今天 2.53 s，profiler 开启）。
- 功能：AX readback 字段值正确、最终 `search_ready`（证据条数 = 行数）。

**守护测试。**
- `testSearchReplacementPublishesHeadThenTail`：第一次 `itemsRevision` 变化时行数 = 预算，最终 = 50，每一块发布时每行都有证据。
- `testNewKeystrokeCancelsRemainingTailChunks`。
- `testSelectedRowInTailIsKeptAcrossChunkedReplacement`。
- `testHighlightNextDoesNotWrapWhileTailIsPending`。
- `testCollapsedPinnedHitsDoNotConsumeHeadBudget`。

### 2.5 F5 悬停：呈现状态扇出 + 呈现前定尺寸 + QuickLook 移出首帧（P1，M）

**问题与证据。** 见 §1.3。

**H0 先归因（S，不改代码）。** 用 `hoverstall <pid> x y --seconds 8 --move 6 --step 46` 依次走过已知类型的行（纯文本、Markdown、图片、PDF），并行 `sample`，用 `analyze_sample.py --thread main --grep 'updateWindowContentSizeExtrema|OutlineListCoordinator|QLPreviewView|NSTextView|NSLayoutManager|WKWebView|viewDidMoveToWindow|WebPageProxy'` 按类型给出份额。这一步决定 F6 是否需要。

**H1 呈现状态扇出。** 把 `HistoryListView.swift:326-487` 的 `activePopover/pendingPopover/lastDismissedPopover` 与 `presentPopover/dismissPopoverIfActive/dismissAnyPopover/schedulePopoverPresentation/pinPreview` 抽成列表级 `@MainActor final class HoverPreviewPresentation`（新文件），状态存在引用里而非 `@State`，每次变化只调用 `rowLiveState.updatePresentedPreview(...)`（F2 的第三个通道）。`HistoryItemView` 的三个布尔输入（`:44-46`）合并为 `presentedPreview: HoverPreviewPopoverKind?`，`==` 相应更新。结果：呈现与关闭各只让源行和旧行重算，List body 为 0 次。异步一拍的关闭（`:343`）、转移所有权守卫（`:344-348`、`:432-436`）、250 ms 重开冷却（`:47`、`:383-388`）原样搬入。

**H2 呈现前确定并冻结尺寸。**

```swift
// HoverPreviewModel.swift（新增）
struct HoverPreviewGeometry: Equatable {
    let budget: CGSize        // 悬停开始时冻结：maxPopoverWidthPoints × maxPopoverHeightPoints
    var content: CGSize       // popover 内容尺寸
}
var geometry: HoverPreviewGeometry?   // 由 pipeline 在 .present 之前写入；之后只因显式原因改变

// HistoryHoverPreviewPipeline.Event（新增）
case geometry(HoverPreviewGeometry)
```

各类型在预取阶段（300 ms，已离主线程或已异步）算出尺寸：
- 图片：`HoverPreviewLoader.computeRequestedMaxPixelSize` 已读取 ImageIO 头部像素尺寸（`HoverPreviewLoader.swift:43-62`），把它作为结果的一部分返回，按冻结宽度算精确高度；解码结果到达时高度不变。缩略图比例（40 px 高取整，误差可达数 pt）不再参与。
- 文件：存在性检查（`HistoryItemFilePreviewView.swift:220-237`）与视频自然尺寸（`:239-253`）移入 pipeline 预取；`.other` 可用时尺寸 = 冻结预算。
- 纯文本：`HoverPreviewTextSizing` 的测量在预取窗口内完成一次（先用 Cupertino 核实 `NSString.size(withAttributes:)` 与独立 TextKit 1 对象的离主线程可用性；若不能确认，就在 `.present` 时于主线程算一次写入 model，而不是每次 body 都算）。
- Markdown：沿用预热探针 metrics（`MarkdownPreviewWebView.swift:873-896`），无则用预算高度；终态 metrics 与探针相差 > 1 pt 时允许一次调整。

预览视图（`HistoryItemImagePreviewView`、`HistoryItemFilePreviewView`、`HistoryItemTextPreviewView`）在 popover 宿主里只用 `model.geometry.content`；`hoverPreviewSizeBudget` 环境值只留给固定窗口（显式窗口尺寸）。`HistoryItemTextPreviewView` 的 render key 在 model 里按 `(text, scale, enrichment fingerprint)` 记忆，body 不再做全文哈希（`:96-103`）。

**H3 QuickLook。** 打开 `FilePlan.shouldPrefetchImage` 对 `.other` 的预取（`HistoryHoverPreviewPipeline.swift:216`），让已写好的 `QLThumbnailGenerator` 分支（`:391-396`）生效；hover 首帧显示静态 QL 缩略图，`QuickLookPreviewView` 不参与首次布局。两种后续：(a) popover 稳定一帧后再构造 live `QLPreviewView`（仍在主线程，但不在呈现布局里，尺寸已冻结不引起 resize）；(b) hover 只显示静态首页，live `QLPreviewView` 只在固定窗口里出现。`NSWorkspace.shared.icon(forFile:)` 在 body 里的两次调用（`HistoryItemFilePreviewView.swift:122`、`:206`）一并移入预取。

**与样式契约逐条对照。**

| 契约条款 | 本设计 |
| --- | --- |
| 816 px 输出面、逻辑视口 `816/scale`、fit-to-host 仅显示缩放（`markdown-chatgpt-wacz-style-contract.md` "Width, Scale, and Overflow"） | 宿主宽度仍是 `maxMarkdownPopoverWidthPoints()`，只是在悬停开始时冻结；视口、换行、缓存键不变 |
| 控件浮于内容边缘、不占 header 行 | `PreviewControls` 不变 |
| 每次加载新 render ID；主 frame、当前 render ID、当前导航三重门控 | 不触碰 WebView 消息路径 |
| metrics 去重比较宽/高/溢出/成败/原因/render ID | 不变；H2 只消费结果 |
| 终态就绪前遮罩；失败保留源码与原因 | 遮罩逻辑不变；预设尺寸只决定宿主 frame，不决定可见性 |
| `product-spec.md:80` "one current visible owner"、`:81` 缓存 metrics 仅对当前 scale 有效 | 预热仍是无 owner 加载；H2 的 metrics 键含 layout scale（`MarkdownRenderCacheKey`） |
| `product-spec.md:82` 缩放时保留上一次渲染 | scale 变化只在新 metrics 到达后显式调整一次尺寸 |
| hover 转移走廊需要 popover 屏幕 frame（`development-guide.md:110`） | `PopoverWindowObserver` 保留在内容里，回调不变 |

契约与规格之间已有一处冲突需要先改文档：`product-spec.md:80` 与 `development-guide.md:94` 写 "Hidden premeasurement is forbidden / must not share this controller"，而 `development-guide.md:153` 与 `MarkdownPreviewWebView.swift:760-768`、`:873-896` 正是在共享控制器里做无 owner 的离屏预热与高度探针。按 `AGENTS.md` "Correct conflicting active documentation"，应把规格改为"无 owner 时允许预热加载，探针高度只用于宿主几何，不代表就绪"。H2 依赖这句话成立。

**实现步骤。** H0 → H1 → H2（图片 → 文件 → 文本 → Markdown，逐类型提交）→ H3。

**涉及文件。** 新增 `Scopy/Views/History/HoverPreviewPresentation.swift`；`HistoryListView.swift`、`HistoryItemView.swift`、`HoverPreviewModel.swift`、`HistoryHoverPreviewPipeline.swift`、`HoverPreviewLoader.swift`、`HistoryItemImagePreviewView.swift`、`HistoryItemFilePreviewView.swift`、`HistoryItemTextPreviewView.swift`、`PreviewControls.swift`。

**门禁。** `make build`、`make test-unit`、`make test-strict`；`scripts/perf-frontend-profile.sh --include-hover`（`development-guide.md:260`）；hover 转移相关按 `development-guide.md:261-262` 覆盖纯几何、控制器取消、列表级转移所有权、过期 token 几何与走廊内外 XCUI 轨迹；渲染器未改，Node 门禁不适用，但需一次真实应用的 Markdown hover 截图核对遮罩与尺寸。

**验收。** `hoverstall` 走 6 行：最大停顿 < 50 ms；单行 hover 在 1 s 延迟点的停顿 < 50 ms（今天 77 ms，范围 65–156 ms）；新增计数 `hover.popover_resize_after_present`：图片/文件/文本为 0，Markdown ≤ 1；每次 hover `list.body` 增量 0（今天每次行间移动 2）。

**守护测试。**
- `HoverPreviewPresentationTests`：A→B 切换只通知 A（nil）与 B（kind）；转移所有者期间不抢占；关闭后 250 ms 内重开延迟生效。
- `HistoryHoverPreviewPipelineTests.testImageFlowEmitsExactGeometryBeforePresent`、`testFileFlowResolvesAvailabilityBeforePresent`、`testOtherFileKindPrefetchesQuickLookThumbnail`、`testNoGeometryChangeAfterPresentExceptMarkdownTerminalMetrics`。
- `WebViewLifecycleTests` 全绿（未改但受影响）。

**需要 hh 决定。** H3 取 (a) 延后构造 live QL，还是 (b) hover 只显示静态首页、live 仅在固定窗口。建议 (b)：hover 本就是一瞥，翻页阅读正是固定预览的用途。

### 2.6 F6 列表级 AppKit popover 宿主（P1 条件项，L）

**触发条件。** F5 完成后 H0 口径复测，任一类型的呈现停顿仍 > 50 ms，且样本仍落在 `updateWindowContentSizeExtremaIfNecessary` 下。

**设计。** 行上的三个 `.popover`（`HistoryItemView.swift:1098-1234`）移除，由 H1 的 `HoverPreviewPresentation` 持有唯一一个宿主：

```swift
@MainActor
final class HoverPreviewPopoverHost: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let hosting = NSHostingController(rootView: AnyView(EmptyView()))
    override init() {
        super.init()
        hosting.sizingOptions = []                 // 不再由 SwiftUI 推导窗口极值（macOS 13+，基线 14）
        popover.contentViewController = hosting
        popover.behavior = .applicationDefined; popover.animates = false; popover.delegate = self
    }
    func present(_ content: AnyView, size: CGSize, anchor: NSView, token: UUID)   // contentSize 显式
    func resize(to size: CGSize, token: UUID)      // 只由用户拖拽、Markdown 终态、scale 变化调用
    func dismiss(token: UUID)
    func popoverDidClose(_ notification: Notification)   // → 原 handlePopoverSystemDismiss(kind:token:)
}
```

锚点：只有被扇出标记为 `presentedPreview != nil` 的那一行安装一个零尺寸 `NSViewRepresentable` 锚（单行结构切换，不是全表逐行切换；滚动研究否决的是"每行常驻标记视图"）。`ResizablePreview` 的拖拽改为调用 `host.resize`。附带收益：每行少三个 `.popover` 修饰符，属于滚动研究里 0.12 s "popovers, context menu, onChange" 桶的一部分（不作为滚动优化目标，只记录不回归）。

**风险与守护。** 这是 hover 转移协议（`development-guide.md:105-114`）的宿主替换，必须保留：按 kind/token 拒绝过期几何与关闭回调；关闭、替换、滚动、系统关闭、失效、拆除各释放一次转移所有权。测试：`HoverPreviewPopoverHostTests`（`sizingOptions == []`、`contentSize` 只经显式调用改变、过期 token 的 `popoverDidClose` 被忽略）；XCUI：`HistoryListUITests.testHoverPreviewDismissesOnScroll`、`testMultiplePinnedPreviewsKeepHoverAvailableAndHideHistory` 与走廊轨迹用例。

**门禁。** 同 F5，另加 `make test-strict` 与 TSan（主 actor 任务生命周期）。

**需要 hh 决定。** 是否在 F5 实测后启动 F6。

### 2.7 F7 内存：有上限、随生命周期释放、响应压力（P1，S×5）

**M1 悬停位图随面板关闭释放（S）。** `FloatingPanel.close()`（HEAD `:199-204`）回调 `onDidClose`，`AppDelegate` 在其中调用 `HoverPreviewImageCache.shared.removeAll()`。固定窗口持有自己 `HoverPreviewModel` 快照里的 `CGImage` 引用，不受影响。上限（40/320/256 MB）不下调——单项 256 MB 是 64 Mpx 解码预算的直接结果，下调会让最高的长截图每次悬停都重新解码（round 2 已测，且 `HoverPreviewImageQualityPolicyTests` 的清晰度守卫依赖该预算）。
**M2 内存压力响应（S-M）。** 一个应用级 `ScopyMemoryPressureMonitor`（`AppDelegate` 持有，`DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)`）。`.warning`：清空 `HoverPreviewImageCache`、`MarkdownPreviewCache` 的 HTML 与文件预览（保留 metrics）、`ClipboardItemDisplayText` 与 `HistoryItemPresentationCache`（`BoundedPresentationCache` 增加 `removeAll()`）。`.critical`：再通知后端（经服务协议，由后端评审定义），并请求渲染评审定义的"无 owner 时释放共享 WebView"。不新增注册表抽象：一个函数直接调用这几个单例。
**M3 revision memo 不持有全文（S）。** `MemoEntry`（`ClipboardItemContentRevision.swift:55-83`）对文本族（`contentHash` 非空、supplemental 为 nil）只比较 hash 与尺寸字段，不再存 `plainText`；image/file/other 保留（路径/分辨率短文本）；`contentHash` 为空的回退路径本来就把全文放在 revision 里，不变。顺带去掉每次行 init 时对新取回 DTO 的 O(n) 字符串比较。
**M4 清扫循环按需（S）。** `HoverPreviewImageCache` 在首次 `setImage` 时启动 15 s 循环、`expiresAt` 为空时退出，而不是从单例构造起永远每 15 s 唤醒一次（`:22-34`、`:88-99`）。
**M5 缩略图字节上限（S）。** `ThumbnailCache.store` 带 cost（`bytesPerRow × height`），`totalCostLimit = 32 MB`；快照现实值约 5 MB，这是对宽度无界缩略图的保险，不改变正常命中率。
**附注（先计数再决定）。** `HistoryListView` 的 `@State private var … = MarkdownPreviewWebViewController()` 等引用类型初值（`:35-45`）在每次该 struct 被父视图重新实例化时都会被求值一次再丢弃（Apple 对 `State` 的文档说明默认值随视图实例化而实例化）。加计数器 `list.runtime_init`，若一次面板会话 > 1，再把这些列表级对象收进一个由 `AppState` 持有的 `HistoryListRuntime`；否则不动。

**验收。** 悬停 10 张长截图后关闭面板，2 s 内 `footprint <pid>` 回到打开前 + ≤ 20 MB；单测模拟 `.warning` 后各缓存为空；一次搜索会话后 memo 不再持有正文（对比 `vmmap --summary` 的 MALLOC 区，记录在 perf 证据中）。

**守护测试。** `HoverPreviewImageCacheTests.testCleanupLoopStopsWhenEmpty`、`testPanelCloseEvictsHoverBitmapsButNotPinnedSnapshots`；`ClipboardItemContentRevisionTests.testMemoResolvesTextFamilyByHashWithoutRetainingText`、`testFallbackRevisionStillComparesText`；`ScopyMemoryPressureMonitorTests.testWarningPurgesFrontendCaches`（注入事件）；`ThumbnailCacheTests.testCostLimitBoundsWidePanoramas`。

**门禁。** `make build`、`make test-unit`；M2 涉及 DispatchSource 与主队列，加 `make test-strict`。

**需要 hh 决定。** M1 是否接受"重开面板后悬停同一张大图需要重新解码（预取在 300 ms 时已开始，多数情况下不可感知）"。

### 2.8 F8 可撤销删除（P0，M；需 hh 决定）

**问题。** 删除立即提交（`HistoryViewModel.swift:1308-1318`），无撤销；⌥⌫ 在 AppKit 层被截获（`AppDelegate.swift:254-267`），搜索框里按"删一个词"会删掉悬停选中的条目；页脚垃圾桶按钮（`FooterView.swift:82-84`）同样无撤销。

**设计（纯前端、单槽、延迟提交）。**

```swift
// HistoryViewModel
struct UndoableDeletion: Equatable { let itemID: UUID; let label: String }
private(set) var undoableDeletion: UndoableDeletion?           // 只由 FooterView 读取
@ObservationIgnored private var pendingDeletion: (item: ClipboardItemDTO, token: UUID, commit: Task<Void, Never>)?

@discardableResult
func delete(_ item: ClipboardItemDTO) async -> Bool {
    await commitPendingDeletionNow()                              // 单槽：新删除先提交旧的
    invalidateKnownContentRevision(itemID: item.id)               // 墓碑：事件/搜索/加载都不会复活它
    _ = removeItem(withID: item.id)                               // 本地立即消失，选中照旧移动
    let token = UUID()
    pendingDeletion = (item, token, Task { [weak self] in
        try? await Task.sleep(nanoseconds: 5_000_000_000); await self?.commitPendingDeletion(token: token) })
    undoableDeletion = UndoableDeletion(itemID: item.id, label: ...)
    return true
}
func undoPendingDeletion() async      // 取消提交；registry.merge(allowRevivingDeletedItems: true)；按当前模式 load()/search()；恢复选中
func commitPendingDeletionNow() async // 面板关闭、clearAll 之前、下一次删除之前调用
private func commitPendingDeletion(token: UUID) async   // service.delete；失败 → 复活 + 重载 + reportActionFailure
```

- **"删后又复制"竞态**：待提交期间若收到该 ID 的 `.newItem/.itemUpdated/.itemContentUpdated`（用户在 5 s 内又复制了同样内容，后端去重命中这一行），视为隐式撤销：取消提交、复活。否则提交会删掉用户刚刚复制进来的历史。
- 复活后用重载而不是按下标插回：条目仍在库里，重载天然得到正确位置与证据；撤销是低频动作，一次整表更新可以接受。
- 面板关闭时立即提交，保证"关掉面板后看到的就是库里的"；应用退出时若未提交则条目保留（安全方向）。
- 固定窗口：墓碑会按现有 reconcile 关闭该条目的固定窗口（`PinnedPreviewController.swift:130-143`），撤销不重开，在规格里写明。
- UI：页脚复用 `actionErrorMessage` 的槽位样式显示"已删除 · 撤销"，可点击；⌘Z 仅在 `undoableDeletion != nil` 的 5 s 内由 `AppDelegate` 本地监视器截获，其余时间交还搜索框的文本撤销。
- ⌥⌫：保留"总是删除条目"的现状（有撤销后可恢复），或改为"搜索框非空时交给文本编辑"。二选一由 hh 决定；同时删除 `ContentView.swift:79-82` 与 `HistoryListView.swift:178-184` 两个死处理器，只留 `AppDelegate` 一处。

**实现步骤。** ① 暂存/提交/撤销状态机 + 页脚 UI；② 竞态与面板关闭提交；③ ⌘Z；④ ⌥⌫ 收敛为一处。

**涉及文件。** `Scopy/Observables/HistoryViewModel.swift`、`Scopy/Views/FooterView.swift`、`Scopy/AppDelegate.swift`、`Scopy/Views/ContentView.swift`、`Scopy/Views/HistoryListView.swift`、`Scopy/FloatingPanel.swift`（关闭回调，与 M1 共用）、`doc/current/product-spec.md`（History Browsing 增加撤销语义）。

**门禁。** `make build`、`make test-unit`、`make test-strict`；`make docs-validate`。

**守护测试。** `testDeleteRemovesRowImmediatelyAndCommitsAfterWindow`、`testUndoRestoresRowAndSelection`、`testRecaptureDuringUndoWindowCancelsDeletion`、`testSecondDeleteCommitsFirstImmediately`、`testPanelCloseCommitsPendingDeletion`、`testCommitFailureRevivesRowAndReportsError`、`testClearAllCommitsPendingDeletionFirst`；更新 `KeyboardNavigationUITests.testOptionDeleteDeletesSelectedItemEvenWhenSearchFocused`（行仍在 5 s 内消失，断言不变）。

**需要 hh 决定。** 单槽 5 s；⌘Z 在窗口内截获；⌥⌫ 在搜索框非空时的归属。

### 2.9 F9 键盘导航、⏎、⌥⌫ 不命中折叠的置顶区（P0，S）

**问题与证据。** `HistoryViewModel.swift:1356-1382` 用 `items`（置顶在前，`:806-814`）导航，不看 `isPinnedCollapsed`（`:396`；视图只在 `HistoryListView.swift:106-110` 隐藏）。从无选中按 ↓ 选中的是看不见的 `pinned[0]`，`scrollTo` 无处可滚，⏎ 复制它、⌥⌫ 删除它。

**设计。** 一个派生序列同时服务 ↑↓、⌘n（F11）与选中合法性：

```swift
var displayOrderItems: [ClipboardItemDTO] { (isPinnedCollapsed ? [] : pinnedItems) + unpinnedItems }
// highlightNext/Previous 遍历 displayOrderItems；selectCurrent/deleteSelectedItem 要求选中项在其中
// isPinnedCollapsed.didSet：若选中的是置顶项且被折叠 → selectedID = nil
```

**涉及文件。** `Scopy/Observables/HistoryViewModel.swift`。**门禁。** `make build`、`make test-unit`。**守护测试。** `testKeyboardNavigationSkipsCollapsedPinnedRows`、`testCollapsingPinnedClearsHiddenSelection`、`testOptionDeleteCannotTargetCollapsedPinnedRow`。

### 2.10 F10 悬停改选中只在指针真实移动之后（P1，S；需 hh 确认）

**问题。** 键盘跟随滚动被 `ListProgrammaticScrollGate` 排除在"滚动"之外（`ListLiveScrollObserverView.swift:9-26`，`HistoryListView.swift:166-172`），因此不会触发悬停抑制；行在静止指针下滚过时会收到 hover，150 ms 后写 `selectedID`（`HistoryItemView.swift:1413-1426`），把键盘选中抢走。这是静态推断（取决于 AppKit 在内容滚动时是否对静止指针下的行发出 enter 事件，整个"滚动后恢复悬停候选"设计的存在说明会发），需实机确认：指针停在列表上连按 ↓ 五次，观察选中是否跳走。

**设计（保持 `product-spec.md:156` 的"hover can still update row selection"）。**

```swift
// HistoryViewModel
@ObservationIgnored var pointerLocation: () -> CGPoint = { NSEvent.mouseLocation }   // 测试注入
@ObservationIgnored private var keyboardSelectionPointerAnchor: CGPoint?
// highlightNext/Previous：keyboardSelectionPointerAnchor = pointerLocation()
func acceptHoverSelection(_ id: UUID) {
    if let anchor = keyboardSelectionPointerAnchor {
        let p = pointerLocation()
        guard hypot(p.x - anchor.x, p.y - anchor.y) > 3 else { return }   // 指针没动：键盘选中优先
        keyboardSelectionPointerAnchor = nil
    }
    lastSelectionSource = .mouse; selectedID = id
}
```

`HistoryListView.swift:522-526` 的 `onHoverSelect` 改调 `acceptHoverSelection`。**门禁。** `make build`、`make test-unit`。**守护测试。** `testHoverSelectionIgnoredUntilPointerMovesAfterKeyboardNavigation`、`testHoverSelectionResumesAfterRealPointerMotion`；XCUI（环境允许时）`KeyboardNavigationUITests.testArrowNavigationWithPointerOverListKeepsKeyboardSelection`。

### 2.11 F11 ⌘1–9 快选（P1，S）

**设计。** 与 ⌘, 同处在 `AppDelegate.installLocalEventMonitor`（`:249-278`）处理，理由同现有注释（SwiftUI 文本框可能先消费）：

```swift
if flags == .command, panel?.isVisible == true,
   let slot = QuickSlotKey.slot(forKeyCode: event.keyCode) {        // kVK_ANSI_1…9 = 18,19,20,21,23,22,26,28,25
    Task { await appState.historyViewModel.selectQuickSlot(slot) }; return nil
}
// HistoryViewModel
func selectQuickSlot(_ n: Int) async {
    let rows = displayOrderItems; guard (1...9).contains(n), n <= rows.count else { return }
    await select(rows[n - 1])                                          // 与 ⏎ 相同：复制并关闭，失败留在面板
}
```

用 keyCode 而不是 `charactersIgnoringModifiers`：AZERTY 等键位下 ⌘1 的字符是 `&`。行上显示 ⌘n 提示是第二步：只在按住 ⌘ 时（`flagsChanged`）经 F2 扇出给前 9 行各加一个 `quickSlot` 值，替换相对时间文字，不改行高；是否显示由 hh 定。

**涉及文件。** `Scopy/AppDelegate.swift`、`Scopy/Observables/HistoryViewModel.swift`、`doc/current/product-spec.md`。**门禁。** `make build`、`make test-unit`（本地快捷键，不涉及全局热键注册，无需热键日志门禁）。**守护测试。** `QuickSlotKeyTests.testMapsANSIDigitKeyCodes`、`testSelectQuickSlotCopiesNthDisplayedRow`、`testQuickSlotRespectsCollapsedPinned`、`testQuickSlotBeyondRowCountIsIgnored`。

### 2.12 F12 面板记住尺寸（P2，S）

**设计。** `FloatingPanel.init` 设 `setFrameAutosaveName("ScopyHistoryPanel")` 与 `minSize`；`open()`（HEAD `:98-117`）在计算原点前把尺寸夹到目标屏幕 `visibleFrame` 内。原点每次打开都按鼠标/状态栏重算，自动保存的原点被覆盖，无副作用。**门禁。** `make build`、`make test-unit`。**守护测试。** `FloatingPanelTests.testRestoredSizeIsClampedToTargetScreen`（抽出纯函数 `clampedSize(_:to:)`）。

### 2.13 F13 其余体验项（按"可感知 × 成本"排序）

| 项 | 设计要点 | 优先级 / 规模 | 备注 |
| --- | --- | --- | --- |
| 失败可见 | `togglePin`/`delete` 提交失败/`clearAll`/AirDrop 不可用/无可揭示文件 → `reportActionFailure`（`HistoryViewModel.swift:1253-1262`），复用页脚槽位 | P1 / S | 备注失败已在编辑器内可见，不重复 |
| 去掉 Recent 段头遥测 | 删 `SectionHeader.swift:32-44` 的性能摘要与 VM 的 `performanceSummary`（`:435`、`:835`、`:1153`）；`PerformanceMetrics` 仍记录，About 继续展示 | P1 / S | 顺带去掉每键两次 actor 跳转 |
| 状态栏右键菜单 | `statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])`，`togglePanel` 中右键弹出菜单：打开 Scopy、设置…、检查更新…（`updaterController`）、退出 | P2 / S | 不加"暂停采集"（无后端 API）；页脚 Quit 是否移走由 hh 定 |
| Launch at Login | General 页一个开关；状态以 `SMAppService.mainApp.status` 为准，不进 `SettingsDTO`；Save 时 `register()/unregister()`，Cancel 丢弃；`requiresApproval` 时提示并提供 `SMAppService.openSystemSettingsLoginItems()` | P2 / S-M | 先按 AGENTS.md 用 Cupertino 核实签名；规格设置表加一行 |
| About 诊断 | "性能监测""Ingest 诊断"受 `product-spec.md:92` 约束，保留或折叠到"诊断"披露组 | P2 / S | 需 hh 决定 |
| 两个 load-more 入口 | 自动触发的 `LoadMoreTriggerView` 保留，删页脚筛选态的 "Load more" 按钮（`FooterView.swift:60-72`） | P2 / S | — |
| 固定窗口 autosave 键无限增长 | `PinnedPreviewController.swift:174` 每个条目一个 `NSWindow Frame ScopyPinnedPreviewPanel.<uuid>` 键；只保留共享名 | P2 / S | 重新固定同一条目回到上次位置的能力会丢失，需 hh 确认 |
| `resignKey` 与 popover | 先实机核实点击 hover popover 内部是否关闭面板；若是，把"事件窗口是本面板的子窗口"加入 `FloatingPanelDismissPolicy`（`FloatingPanel.swift:29-43`） | P2 / S | 待核实 |
| `IconService` 负结果缓存 | 未安装应用的 bundle ID 缓存为"无图标"，避免每次行 body 查询 LaunchServices（`IconService.swift:26-37`） | P2 / S | 搜索与滚动都受益，量小 |

### 2.14 F14 结构拆分与术语（P2，M 增量）

原则：先搬移、零行为变化、每步独立提交；只在已有 MARK/职责缝上切。跨文件扩展需要把被访问的 `private` 成员放宽为 `internal`（应用 target 内部，可接受）；能用"把逻辑移进已有引用类型"解决的优先移进去。

**`HistoryViewModel.swift`（1,703 行）→**

| 目标文件 | 单一职责 |
| --- | --- |
| `Observables/HistoryContentRevisionRegistry.swift` | 内容 revision 与删除墓碑的有界注册表及其快照（现 `:1-272`，纯值类型） |
| `Observables/HistoryViewModel.swift` | 可观察的 projection（行、证据、覆盖度、选中）与唯一的发布原语 `mutateProjection`/`publishSearchPage` |
| `Observables/HistorySearchSession.swift` | 搜索状态机：版本、任务、staged 截止槽、refine、in-flight（F3） |
| `Observables/HistoryViewModel+Loading.swift` | 首屏加载、load-more、存储统计刷新（`:784-1036`） |
| `Observables/HistoryViewModel+Events.swift` | 后端事件到 projection 的归并、设置同步、最近应用（`:561-782`） |
| `Observables/HistoryViewModel+Actions.swift` | 复制/置顶/删除与撤销/备注/清空/AirDrop/揭示/键盘导航/快选（`:1228-1408`） |
| `Presentation/SearchStatusPresentation.swift` | 覆盖度提示、状态标签、状态摘要与模式名的纯函数（`:437-495`、`:1167-1220`），将来本地化落点 |

**`HistoryItemView.swift`（2,174 行）→**

| 目标文件 | 单一职责 |
| --- | --- |
| `HistoryItemView.swift` | 输入、`Equatable`、body 组合、生命周期修饰符、上下文菜单 |
| `HistoryItemRowLabel.swift` | 纯绘制：置顶条、应用图标、按类型的内容、次行（证据/元数据）、状态、相对时间（现 `:804-888`、`:938-980`） |
| `HistoryItemView+Session.swift` | 交互 session 的创建、认领、恢复、释放、拆除与附着（`:336-546`）；删除 `:185-318` 的转移访问器，改为显式传 `state` |
| `HistoryItemView+Hover.swift` | hover 处理、预览任务启动、pipeline 事件应用、退出清理与滚轮关闭（`:1345-1523`、`:1738-1897`、`:1964-2090`）；F6 后大幅缩小 |
| `HistoryItemView+Actions.swift` | PNG 导出、备注编辑、图片优化、主操作（`:1562-1735`、`:1898-1962`） |
| `HistoryItemPreviewPopover.swift` | 三个 popover 合一的内容构建与 `ScrollWheelDismissMonitor`（`:1092-1235`、`:2128-2174`）；F6 后移出行 |

**`HistoryHoverPreviewPipeline.swift`（792 行）→** `HoverPreviewRequests.swift`（请求/计划/事件与纯计划函数）、`HoverPreviewImageFlow.swift`、`HoverPreviewFileFlow.swift`（含 Markdown 文件）、`HoverPreviewTextFlow.swift`、`HoverPreviewWorkBudget.swift`（`AsyncPermitPool` 与 `runBudgetedDetached`）。`logHoverStage` 与进程全局 `textHoverStartedAt`（`:557-563`）按代码卫生审计 §1.1 收进 `ScrollPerformanceProfile.isEnabled` 门后，并同步修改 `development-guide.md:153` 的最后一句。

**`HistoryListInteractionCoordinator.swift`（475 行）→** 仍是一个文件，职责一句话："列表范围内滚动/滚动条指针抑制、唯一活动行槽位、被抑制的悬停恢复候选与悬停转移所有者的仲裁者"。删除只为测试存在的非 token API（`beginHoverPreviewTransfer(for:)`、`endHoverPreviewTransfer(for:)`、`endPointerInteraction()`，生产零调用，测试 10 处改用 token 版本）；legacy 广播随代码卫生审计 D3 决定一并删除。

**`HistoryListView.swift`（672 行）→** popover 协调抽到 `HoverPreviewPresentation.swift`（F5-H1），空态覆盖层（F1），视图剩约 450 行。

**门禁。** 每步 `make build`、`make test-unit`；动到任务/actor 边界的步骤加 `make test-strict`。

## 3. 可读性与命名

只列"名字在误导读者"的情况；引用数由 `rg -c` 统计 `Scopy/`、`ScopyTests/`、`ScopyUITests/`（及相关 `doc/current`）。

| 名字 | 误导之处 | 引用数 | 建议 |
| --- | --- | ---: | --- |
| `isKeyboardSelected` | 悬停也会写同一个选中（`HistoryListView.swift:522-526`），它表示"⏎ 目标"，不是"键盘选中" | 23 | 改 `isSelected`，随 F2 改行输入时一起做 |
| `HistorySelectionAwareRow` | F2 后承载选中、证据、呈现三类状态 | 2 | 改 `HistoryLiveRow` |
| `mainRowButton` | 注释明确说它故意不是 `Button`（`HistoryItemView.swift:918-925`） | 2 | 改 `rowActivationSurface` |
| `HistoryItemMarkdownExportController` | 是无状态 `enum` 命名空间（`HistoryItemMarkdownExportController.swift:5`），而同目录的 `*Controller` 都持有生命周期对象 | 24 | 改 `HistoryItemMarkdownExport`；低优先级 |
| `HistoryItemInteractionState` | 其注释、`HistoryItemInteractionSessionStore`、计数器 `interaction.session_*` 都叫它 session | 54 | 改 `HistoryItemInteractionSession`；可选，F14 拆分时做 |
| `itemsRevision` | 本仓库 "revision" 指内容身份（`ClipboardItemContentRevision`），计数器一律叫 generation（`clearGeneration`、`cooldownGeneration`、`deletionEvictionGeneration`） | 17 | 改 `projectionGeneration`，随 F2 把它变成独立观察单元时一起做 |
| `Hover*`（`HoverPreviewModel` 43、`HoverPreviewPopoverKind` 25、`HoverPreviewSizeBudget` 10） | v0.80.0 起也服务固定窗口 | 78 | **不改**：成本大于收益；若 F6 落地再议 |

注释与文档不一致：

1. `product-spec.md:100` 与 `development-guide.md:77` 写 load-more 每页 500；代码 `HistoryViewModel.swift:323` 为 100（v0.77.0 `dae61b1` 起）。规格是权威文档，应改为 100。
2. `product-spec.md:80`、`development-guide.md:94`（"Hidden premeasurement is forbidden / must not share this controller"）与 `development-guide.md:153`、`MarkdownPreviewWebView.swift:760-768`、`:873-896`（共享控制器的无 owner 预热与高度探针）冲突，见 §2.5。
3. `development-guide.md:154` "`replaceSearchPage` is a no-op when the refine pass reproduces the prefilter page"：代码仍修改 `listState`（`HistoryViewModel.swift:1583`）并重跑整表。F2 后成立，文档届时同步。
4. `development-guide.md:151` 的规则被 `HistoryListView.swift:85-89`（`searchMatchContexts`、`activePopover`）违反；F2/F5 后成立。
5. `AppState.swift:30` `MARK: - Singleton (兼容层)`：`AppState.shared` 是生产入口（`AppDelegate.swift:19`），不是兼容层；与硬约束 1 的语义冲突，改为 "Shared instance"。
6. `HistoryListView.swift:25` "符合 v0.md 的懒加载设计"：`doc/specs/v0.md` 按 `development-guide.md:284` 是非规范性历史证据，注释不应把它当依据。

前端术语（建议写入 `development-guide.md` §4.5，一次定义）：

- **projection / publish**：VM 暴露给列表的当前行、证据、覆盖度；"发布"指对 projection 的一次原子修改（`mutateProjection`）。代码里已有 41 处 "projection"，沿用，不引入后端的 "publication"。
- **revision vs generation**：revision 只指内容身份；单调计数器叫 generation；`contentRevisionReconciliationToken` 是 token，不改。
- **session**：行的懒创建交互状态（上表建议统一类型名）。
- **ownership（lease）**：WebView 所有权。代码用 `beginOwnership/owns/endOwnership`（21 处），文档用 "owner lease"（`architecture.md:45`）；文档写成 "ownership lease"，代码不改。
- **coordinator / controller / policy / pipeline**：coordinator = 仲裁多个参与者的有状态对象；controller = 持有一个 AppKit/WebKit 对象生命周期；policy = 纯判定或纯状态机（`FloatingPanelDismissPolicy`、`HoverPreviewIntentPolicy`、`HoverPreviewLivenessPolicy`、`HoverPreviewImageQualityPolicy` 一致；`PanelReopenSearchResetPolicy.shouldClearSearch` 是死复制品，见代码卫生审计 §2.1）；pipeline = 若干异步 flow 的命名空间。
- **fan-out**：F2 后只有一个 `HistoryRowLiveStateFanout`，承载一切"按交互变化、只关乎少数行"的状态。

## 4. 明确不做

- **滚动优化**：天花板已由 `doc/perf/studies/perf-scroll-ceiling-2026-09-04.md` 关闭；F6 顺带去掉的行级 popover 修饰符只记录"不回归"，不作为滚动收益主张。不透明面板与每行少画元素是 hh 的产品取舍，不提。
- **固定行高、换 NSTableView、`estimatedRowHeight`**：SwiftUI List 在 macOS 不暴露；逐行 `.frame(height:)` 已测更差；NSTableView 宿主已测忙时间差 52%。F4 用"每次更新涉及的行数"替代"行高"这个杠杆。
- **加大搜索防抖或缩小搜索首页**：违反 `product-spec.md` 搜索契约的 0 ms 派发；分块替换已足够。
- **下调 `HoverPreviewImageCache` 上限**：与 64 Mpx 解码预算和清晰度测试冲突（§1.6）。
- **⏎ 粘贴、通用回贴、纯文本粘贴；按 Concealed/Transient 等标记跳过采集；原文/规范文本与按表示去重；`</head>` 导出**：均已裁决。
- **后端内存（fuzzy 索引常驻）、列表 summary 查询、退出落盘与事件流重订阅**：归后端/生命周期评审；F7 的 `.critical` 只留调用点。
- **Markdown 渲染链、WebView 懒创建与释放、暗色模式**：归渲染评审。
- **本地化与选中/悬停视觉重做**：旧评审 §7.5、§7.1 仍然有效，本文不重复提出；字号材质需 hh 定稿。
- **"暂停采集"菜单项**：没有后端 API，按硬约束 2 不为它造接口。
- **撤销栈**：单槽已覆盖误删场景，多级撤销没有现实消费者。

## 5. 实施顺序与依赖

1. **F0**（工具）→ 记录基线。
2. **F9、F10、F12、F13 的小项**：互相独立，可并行，不依赖测量。
3. **F1** → **F2**（先"泛化扇出只迁移选中"，再证据，再 `mutateProjection`）→ **F14 的 `HistorySearchSession` 纯搬移** → **F3** → **F4**。每步后跑 `make perf-search-type` 对照 F0 基线；F4 的线性假设若被计数否定，停在 F3，转 F2c。
4. **F5**：H0 归因 → H1（复用 F2 扇出的第三个通道）→ H2（逐类型）→ H3 → 复测 → 决定 **F6**。
5. **F7**：M3、M4、M5 随时可做；M1 与 F8 共享面板关闭回调，先做 M1；M2 与后端/渲染评审约定 `.critical` 的调用点后再合入。
6. **F8** 在 F9 之后（共享 `displayOrderItems` 与选中合法性）；**F11** 在 F9 之后。
7. **F14** 其余拆分穿插在各项之间，只在所在文件被功能改动触及时顺带进行。
8. 文档：F2/F3/F5 合入时同步 `development-guide.md` §4.5 第 13、15、16 条与 §4 "Hover Transfer Contract"；F8/F11/F13 同步 `product-spec.md`；§3 的两处规格冲突可先于代码单独修正（`make docs-validate`）。

待实机核实（本评审环境不允许运行应用或 perf 脚本）：F4 的"成本随插入行数线性"假设；F10 的悬停抢选中是否在真实输入下发生；点击 hover popover 内部是否使面板 `resignKey`；`HistoryListView` 在一次面板会话中被实例化的次数；H2 所需的 TextKit 离主线程可用性与 F6/F13 用到的 `NSHostingController.sizingOptions`、`SMAppService`、`DispatchSource.makeMemoryPressureSource` 的签名与可用性（按 `AGENTS.md` 用 Cupertino 核实后立即编译）。
