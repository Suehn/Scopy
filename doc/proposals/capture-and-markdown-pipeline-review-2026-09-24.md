---
doc_type: proposal
status: draft
owner: hh
created: 2026-09-24
audience: maintainer decision + implementing agent
---

# 采集与 Markdown 预览/导出流水线评审（2026-09-24）

基线：`407f7db`（v0.81.0）。范围：`ClipboardMonitor` 与采集相关 Domain 类型；Swift 预处理链（`MarkdownHTMLRenderer` 上的 protector/normalizer/detector）；`MarkdownHTMLDocumentBuilder`；`MarkdownPreviewWebView`（controller、租约、render ID）；`MarkdownPreviewCache`；导出（`MarkdownExportService`、`HistoryItemMarkdownExportController`）；`Scopy/Services/LinkMetadata/**` 与网站图标；`Tools/MarkdownRenderer/{src,test,scripts}`。hover popover 的窗口尺寸/呈现归前端评审，存储/索引归后端评审；两处交叉点在文中标"交接"。

方法：只读。每条结论都在 HEAD 重新读代码核实，`file:line` 以 `407f7db` 为准；数据分布来自 `sqlite3 -readonly perf-db/clipboard.db` 与 `perf-db/thumbnails/`。本次没有运行构建、测试或 perf 脚本，所以凡是没有实测数字的"收益"都标成"估算"或"待测"，实施时用每项给出的门禁取证。已有清单只引用、不重复：`doc/proposals/code-hygiene-audit-2026-09-19.md`（下称"卫生审计"）。

## 0. 结论

| 编号 | 改进 | 优先级 | 规模 | 预期收益（可测量/用户可见） | 主要回归风险 |
| --- | --- | --- | --- | --- | --- |
| C1 | 采集基线：记录自写、每个 changeCount 只评估一次、单 Task 轮询循环（突发轮询待 hh 定） | P1 | M | 自写被重采降为 0（竞态测试在 HEAD 上失败、修复后通过）；消除"托管图片被重采成 `.file` 行"；抽取为空或落盘失败时不再每 tick 在主线程重读；唤醒可被系统合并 | 基线逻辑写错会漏采或重采；59 个监控测试依赖的轮询时序 |
| C2 | 每次变化只读一轮剪贴板（读取会话）+ 类型决策只看会话 + 图片编码与 KaTeX 解析移出主线程（HTML 导入预算待 hh 定） | P1 | M | 纯文本/富文本复制少 3 次无结果的图片读取；Office 表格+图片复制的 html/rtf/string 各只读 1 次（现在最多 2 次）；临时图文件和 `NSImage` 回退的 TIFF→PNG 不再占用主线程；读取期间剪贴板被改写时不再把两份内容混存 | 类型优先级的边界（Office/微信/临时图/`<img`） |
| C3 | ingest 串行有序、回放按创建时间排序、TIFF 用真实扩展名、拆分 `ClipboardMonitor` | P2 | L | 历史顺序等于复制顺序（测试 + `make perf-capture` 顺序检查）；`ClipboardMonitor.swift` 从 2,728 行降到约 250 行；删掉 `queueLock`、`TimerBox` 和被生产代码读取的全局测试旋钮 | 连续多张大 TIFF 截图时吞吐下降；纯移动的 diff 很大 |
| R1 | 渲染热路径：默认 profile 跳过 protector 往返、删掉没人读的诊断、protector 改成线性 | P1 | S | 默认 profile 每次渲染省掉 protect 扫描、O(占位符数×文档长度) 的 restore 和 1 次 `containsMath`；长行代价从 O(L²) 降到 O(L)（快照里有 15 条类 Markdown 文本的最长行 ≥5 KB，估算单次数十到数百毫秒，用 `hover.markdown_render_ms` p95 取证） | 输出应逐字节不变（有等价测试） |
| R2 | 渲染输入只算一次：context、内容键、enrichment 指纹各算一次；从预览发起的导出直接用屏幕上的文档 | P2 | M | 去掉 popover `body` 每次求值在主线程做的 5 次全文 SHA-256；已富化文档每次求值还要重编码约 0.6 MB 的 enrichment JSON 三次（估算），一并去掉；预览与导出用同一个字符串 | 缓存键格式变化导致进程内缓存一次性全部失效；pinned 快照复制 |
| R3 | Swift/JS 收敛：Swift 只决定能否渲染、profile 和 policy，源改写全部交给 JS；补齐跨语言契约测试（科学 profile 规范化的迁移待 hh 定） | P1 | M（科学部分 L） | Node 测试喂的输入与生产一致（默认 profile）；删 Swift 259 行和测试 97 行；profile 判定第一次有测试；文档字节跨进程确定 | ATX 在 JS 中的 fence/缩进判定与 Swift 有细微差别 |
| R4 | 文档运行时与基础 CSS 迁入渲染器包，Swift 只拼一个薄外壳；CSP 去掉脚本的 `'unsafe-inline'`；样式断言改为结构化 | P2 | L | 文档固定外壳从约 115–125 KB 降到约 2 KB（另加源码）；`MarkdownHTMLDocumentBuilder` 少约 2,700 行；182 个子串断言改成计算样式/行为断言；即使渲染器插件回归也不会执行内联事件属性 | 就绪门控（样式表/字体）时序；资产契约扩展 |
| E1 | 导出：删死判断和重复变量、真彩色测试进 CI、settle 改推送、显示阶段并提供取消、拆分 | P2 | M | rich v2 真彩色第一次有 CI 可见的测试；去掉一个预览/导出漂移源；每个 settle 阶段从最多约 1,500 次 IPC 轮询改为事件驱动；长导出可以取消 | PDF/分片路径时序；遮挡时推送的兜底 |
| W1 | WebKit 宿主统一：删生产不可达的一次性 WebView 和死探针，WebView 配置与拦截规则收成一个工厂 | P2 | S | 少约 270 行；只剩一个 WebView 生命周期实现；首个预览不再有拦截规则挂载竞态 | 极低 |

总体判断：

- **采集的实质问题在基线，不在性能**：`lastChangeCount` 会被 await 之后的旧值覆盖，Scopy 自己的写入可能被重采（最坏时产生一条指向 Scopy 内部存储文件的 `.file` 行）；抽取为空或落盘失败时，同一个 changeCount 每个 tick 都重读。修法小而确定（C1）。
- **渲染链在 HEAD 的真实形状**：Swift 预处理后，把源码以 JSON 嵌进一个约 120 KB 的外壳；每个 WebView 各自用 882 KB 的 IIFE 在页内解析。契约和 AGENTS.md 说的"共享 parse result"，实际是"同一输入 + 同一 bundle，所以确定性地得到同一 parse"。要改的是措辞，不是代码。
- **默认 profile 有无用功**：默认 profile 覆盖绝大多数文本条目（快照 6,888 条文本类里只有 134 条含显式数学定界符）。这条路径上 Swift 做一次无效往返和一次没人读的扫描，protector 的 URL/路径探测还对每个字符复制整行尾部。R1 在输出零变化的前提下去掉它们。
- **Swift/JS 双实现**：表格管道转义纯粹重复；ATX 只在 Swift 做，导致 Node 测试喂的不是生产输入；科学 profile 的 1,726 行 Swift 规范化几乎没有直接单测。方向是 Swift 只做判定、JS 做全部改写（R3）。科学部分的迁移是 L 级，需要 hh 决定。
- **两套 WebView 生命周期**：HEAD 里已经不是 hover 与 pinned 两套——两者共用 controller 和租约——而是一个生产代码到不了的一次性 representable（W1 删除）。
- **预览与导出共享 HTML**：目前靠两边调用同一个函数重算来保证，但有两个漂移源：导出样式重复定义了 7 个布局变量；rich v2 真彩色有一段死的 Swift 字串判断和一条只测它的测试，真正起作用的 DOM 判断没有 CI 测试（E1）。
- **文档与代码有一处硬冲突**：product-spec:80 和 development-guide:94 禁止"隐藏预测量"，而 development-guide:153 与代码里的 prewarm/probe 恰好是在共享 controller 上做隐藏预测量。需要 hh 定哪边为准（§1.6 K7）。
- **本面没有 P0**：没发现数据丢失、隐私或整页静默失败级别的问题。最接近的是 C1。

## 0.1 终审修正（2026-09-24，主线程 + Codex 第二方复核）

以下裁定优先于本文正文；证据见 [review-roadmap-2026-09-24.md](./review-roadmap-2026-09-24.md) §9。

- **C1 不做"持久化三次失败即 settle 并丢弃"**：这违反"保留所有剪贴板内容"。落盘失败时缓存已抽取的 rawData 重试，不再从 pasteboard 重读；Timer → Task 循环不是必要修复，可随 C1 步骤 ② 做也可不做。突发轮询不做。
- **C2 不做"HTML > 4 MiB 且有 `.string` 时跳过导入"**：它改变 `plainText` 选择与去重输入，触及冻结的规范文本决策。只做读取会话、类型决策只看会话、图片编码与 KaTeX 解析外移。排队临时文件 URL 不能代替取得载荷所有权。
- **C3 的队列必须有界并保留背压**（复用 `AsyncBoundedQueue`），小内容也进同一 FIFO；creationDate 只改善回放排序，不证明严格复制顺序。八文件纯搬移与语义改动分开提交；legacy spool 迁移沿用卫生审计结论，本轮不动。
- **P-R1 只声明"去掉已识别的分配"，不声明整体 O(L)**：未闭合括号反复扫尾、autolink 尾串复制、逐占位符全文 restore 仍在（`MarkdownSyntaxProtector.swift:37, 200, 224, 283`）。收益以 `hover.markdown_render_ms` p95 实测为准。
- **P-R2 的导出复用只在 source/profile/policy/scale/enrichment 精确匹配时成立**（本文 `resolveDocument` 已如此），不得拿仍在显示的旧 scale 文档。
- **新增 E0（P1，S）：导出取消后仍会重建 WebView 与窗口。** 取得并发名额后启动的 Task 未保存（`MarkdownExportService.swift:889`），`startWebViewAndLoadHTML` 只在入口检查 `isCompleted`（`:895`），随后 `await ExportNetworkBlocker.ruleList()`（`:905`）返回后不再检查即创建 WebView、展示隐藏面板并加载 HTML（`:911-954`）。保存启动 Task、取消时处理它、await 恢复后创建资源前复查终态。E0 先于 E1 的取消按钮；"取消链完整、只差按钮"的说法撤回。
- **P-R3 步骤 5（科学 profile 迁 JS）与 P-R4 的表格模型前移、断言全替换降为 P2**，分别在默认契约稳定后再决定；P-R4 的 CSS/运行时原样外置与 `script-src` 收紧保留。
- **K7 先实机验证 prewarm 的 paint-timeout 路径**（`HistoryHoverPreviewPipeline.swift:573, 614`；`MarkdownPreviewWebView.swift:782, 870`；builder 的 1,500 ms watchdog）再统一规格措辞。

## 1. 现状与证据

### 1.1 尺寸

| 文件 | 行 | 说明 |
| --- | ---: | --- |
| `Scopy/Services/ClipboardMonitor.swift` | 2,728 | 轮询、读取、类型决策、文本抽取（约 720 行纯静态）、spool 状态机（约 560 行纯静态）、ingest worker、指标 actor、剪贴板写入（约 290 行）全在一个类型里 |
| `Scopy/Views/History/MarkdownHTMLDocumentBuilder.swift` | 2,871 | 基础 CSS 约 77.4 KB（253-2289，插值只有 `:root` 的 9 个变量 383-391）；表格运行时 JS 约 13.2 KB（13-251）；文档运行时 JS 约 27.6 KB（2303-2848）。字节数按 Swift 源行估算 |
| `Scopy/Services/Export/MarkdownExportService.swift` | 2,810 | 其中约 330 行是 JS 字符串（1491-1825、2258-2323） |
| `Scopy/Views/History/MarkdownPreviewWebView.swift` | 1,232 | 一次性 representable（349-607）、controller（609-1034）、租约 representable（1036-1087）、滚动条隐藏 |
| 科学 profile 的 Swift 预处理 | 1,726 | `MathProtector` 769、`LaTeXDocumentNormalizer` 387、`MarkdownSyntaxProtector` 304、`LaTeXInlineTextNormalizer` 102、`MathEnvironmentSupport` 85、`MarkdownCodeSkipper` 79 |
| 所有 profile 都跑的 Swift 预处理 | 259 | `MarkdownTableCodeSpanPipeNormalizer` 171、`MarkdownATXHeadingNormalizer` 88 |
| `Scopy/Services/LinkMetadata/**` | 845 | `LinkEnrichmentFetcher` 654、`SourceIconService` 100、`SourceIconSchemeHandler` 68 |
| `Tools/MarkdownRenderer` | 7,726 | `src` 4,882、`test` 2,284（约 113 个测试）、`scripts` 560；产物 IIFE 881,938 B、`katex.min.css` 23,804 B、60 个字体 |

### 1.2 采集路径（HEAD）

1. 每 500 ms 一个 `Timer`，每次触发新建一个 `Task`（`ClipboardMonitor.swift:1084-1096`，没有 `tolerance`），进入 `checkClipboard`（786）。用 `isCheckingClipboard` 防重入（262、788-791）。
2. 比较 changeCount（793-797）。跳变 >1 只写 debug 日志并记数（797-803）。
3. `extractRawData`（1687-1777）在主线程执行：取前台 App；`readObjects(NSURL)`；判断临时图片文件；做 Office/表格嗅探；读图片；读 rtf/html/string；把文本处理放进 detached 任务（`makeTextRawData` 2005-2079），HTML 导入经闭包回到主线程（1743-1745）。
4. 每次采集在主线程拼字符串，写一条 `.info` 日志（809-810）。
5. 分流：图片或 ≥50 KB 的内容先在 detached 任务里写信封（1119-1153），再登记，由最多 3 个并发 detached worker 处理（903-1021：加载、TIFF→PNG、哈希、`buildPayload`、会话检查、入队）；其余在主线程算哈希（841）后直接入队（850）。
6. `ClipboardService` 串行消费（`ClipboardService.swift:986-990`）：设置过滤、pngquant、upsert（时间戳为落库时刻 `Date()`，`StorageService.swift:467、494、504`）、发布事件、确认信封。

### 1.3 一次 hover Markdown 渲染在 HEAD 做了什么

| 步 | 位置 | 线程 | 内容 |
| --- | --- | --- | --- |
| 1 | `HistoryHoverPreviewPipeline.swift:135`、566 起 | Main | 指针停留 300 ms 后开始 |
| 2 | 同文件 658-676 | detached | `MarkdownDetector.isLikelyMarkdown`（先查 presentation cache） |
| 3 | 591-594 | detached | `MarkdownRenderContextResolver.defaultContext`：profile 检测（80k 前缀，`MarkdownSourceProfileDetector.swift:4-32`）、全文 SHA-256 查 enrichment（`MarkdownRenderContext.swift:72-74`）、拼缓存键（`MarkdownRenderCacheKey.swift:4-14`） |
| 4 | 597-606、709-720 | detached（许可池） | 缓存未命中时调用 `MarkdownHTMLRenderer.render`（`MarkdownHTMLRenderer.swift:9-51`）：protect（总是跑）→ [LaTeXDocument] → restore（总是跑）→ [MathProtector + LaTeXInline] → ATX → 表格管道 → `document()` → `containsMath`（结果丢弃） |
| 5 | `MarkdownHTMLDocumentBuilder.swift:2303-2848` | 同上 | 外壳：源码的 JSON 字面量（大小写不敏感地替换 `</script`）、policy JSON（未排序的字典）、约 77 KB CSS、约 45 KB 内联 JS |
| 6 | `HistoryHoverPreviewPipeline.swift:610` → `MarkdownPreviewWebView.swift:760-768`、941-953 | Main | 把文档 prewarm 到无 owner 的共享 WebView：注入 render ID（整串复制）、`loadHTMLString(baseURL: Resources/MarkdownPreview)` |
| 7 | WebContent 进程 | — | 加载 `katex.min.css` 和 882 KB IIFE（defer）；DOMContentLoaded 时 `ScopyUnifiedMarkdown.render(source, policy)`（builder 2780；`render.js:42-103`：remark→rehype→sanitize→KaTeX→highlight→stringify）→ `innerHTML` → 任务列表 → `hydrateRich` → `layoutChatGPTTables`（再走一遍 DOM）→ 就绪合取：图片 1.5 s/图标 10 s、字体 3 s、样式表（只查 KaTeX 的，2556-2584）、两帧 paint → `postMessage` |
| 8 | `MarkdownPreviewWebView.swift:873-896` | Main | 离屏时 rAF 不跑：每 25 ms 探测一次 `__scopyProbeLayoutHeight`，最多 40 次，用来预填 metrics 缓存 |
| 9 | `HistoryHoverPreviewPipeline.swift:617-652`；`MarkdownPreviewWebView.swift:1058-1076` | Main | 延迟到点 → 弹出 popover → 租约 representable 取得 owner → 同一份 HTML 回放 metrics → 上屏后的真实终态报告 |

主线程上的渲染相关工作是编排、`loadHTMLString`（传入约 120 KB 字符串）和消息处理，外加 R2 列出的重复哈希；渲染本身在后台（与已测事实一致）。popover 尺寸阻塞归前端评审。

`MarkdownPreviewCache`：HTML 和 metrics 共用一个键，`md|rendererVersion|profile|scale|enrichmentFP|revisionKey`。`revisionKey` 含条目 ID，所以同内容的不同条目不共享缓存。成本上限 8 MB（`MarkdownPreviewCache.swift:37-38`，cost = UTF-16 数 × 2），按当前外壳大小约能放 30 余份。命中率没有计数器，只有 `logHoverStage("html cache hit")` 这条 info 日志（`HistoryHoverPreviewPipeline.swift:598`）。metrics 缓存有 4 个写入点（`HistoryHoverPreviewPipeline.swift:544、628`；`MarkdownPreviewWebView.swift:889、923`；`HistoryItemView.swift:1838`），其中 prewarm 写入的是"DOM 构建高度"，不是终态高度。

### 1.4 导出路径

`HistoryItemMarkdownExportController.exportMarkdownToClipboard` 从源码重新调用 `MarkdownHTMLRenderer.render`（103-109），交给 `MarkdownExportService.exportToPNGClipboard`，后者新建 WebView 并挂在 alpha 0.01 的 `.statusBar` 级面板上（`MarkdownExportService.swift:894-955`），加载时注入导出样式（957-1019）。之后依次：页侧准备和就绪等待（每 8 ms 轮询一次，1486-1825、2389-2436）、按需全局缩放、DOM 真彩色判断（1075-1080）、PDF → 单次快照 → 分片三种策略、编码、剪贴板提交（`PasteboardWriteLease` 比较 changeCount，40-52）。

预览与导出共用"同一份 HTML"，在 HEAD 靠同一个函数重算来保证。已发现的偏离种子：导出样式重复定义布局变量（E1）；预览与导出在不同时刻读取 enrichment（R2）。没发现第二个解析器或选择器。UI 测试有一个原始 HTML 导出入口（`AppDelegate.swift:372-392`，`SCOPY_UITEST_AUTO_EXPORT_HTML_PATH`），专门测导出机制，喂的是合成文档。为此，watcher 在页面没有 `__scopyIsRenderReady` 时把 ready 视为 true（`MarkdownExportService.swift:2296`）——这条测试放宽也作用于生产路径；生产文档总会定义该函数，所以只在运行时脚本出错时才有影响。

### 1.5 旧评审（2026-09-03）本面条目在 HEAD 的状态

| 旧条目 | HEAD 状态 | 证据 |
| --- | --- | --- |
| §3.3 自粘贴竞争 | 仍然存在 | 写入设基线在 `ClipboardMonitor.swift:509、537、545、578、591、766`；await 之后回退基线在 814、820、835、851 |
| §3.3 同一 changeCount 多次读取 | 仍然存在 | html/rtf/string 在 1840-1849 与 1739-1741 各读一次；图片在 1861 与 1723 各读一次 |
| §3.3 采集大小上限 | 仍然没有；建议与 hh 的"保留所有内容"裁决协调（C2） | 快照最大值：image 23.4 MB、rtf 1.0 MB、html 0.55 MB |
| §3.3 自适应轮询/锁屏暂停 | 仍是固定间隔、没有 tolerance；锁屏/睡眠门控建议不做（§4） | 1084-1096 |
| §3.3/§8.4 死的 `extractContent` 路径 | **已删除**（`e1d7846`，2026-09-05）；测试改为经命名 pasteboard 驱动生产的 `checkClipboard` | `ClipboardMonitorTests.swift:1489-1503` |
| §3.3 回放顺序 | 仍然存在：按随机 UUID 文件名排序 | 1204-1216 |
| §3.3/§4.3 缩略图 40 px | 仍然存在（交接后端，见 C3 末尾） | `StorageService.swift:2314-2330、2355-2374`；`HistoryItemThumbnailView.swift:20-23` |
| §4.7 TIFF 转换失败仍用 `.png` 后缀 | 仍然存在 | 953-957、1055-1060；`StorageService.swift:2223-2226` |
| §6.2 默认 profile 的 protector 往返 | 仍然存在；另外发现长行上是 O(L²) | `MarkdownHTMLRenderer.swift:11-20`；`MarkdownSyntaxProtector.swift:120-130、244-263` |
| §6.2 CSS/JS 外置 | 没有做，尺寸不变 | §1.1 |
| §6.2 `.sortedKeys` | 仍然存在；用户可见影响为零（生产侧 enrichment 候选上限 13，JS 截取 48） | builder 2297-2300、2849-2859；`LinkEnrichmentEligibility.swift:7` |
| §6.2 契约同步三处 | ATX 仍只在 Swift 做；"canonical stylesheet"仍只指 KaTeX 样式表；rich v2 真彩色**已改为 DOM 判断**，但 Swift 里留下一段死字串判断 | builder 2556-2584；`MarkdownExportService.swift:1075-1080`；`HistoryItemMarkdownExportController.swift:170` |
| §6.3 表格管道 Swift/JS 重复 | 仍然存在 | `MarkdownTableCodeSpanPipeNormalizer.swift`；`render.js:465-656` |
| §6.3 数学词表三处 | 仍有三份；判定为回答不同问题，不合并（§4） | `MarkdownDetector.swift:73-87`；`MarkdownSourceProfileDetector.swift:149-157`；`remarkScopyLooseMathRepair.js:1-18` |
| §6.3 表格桶阈值三处 | 仍然存在 | builder 40-45、2220-2240；契约 :396-403 |
| §6.3 两套 WebView 生命周期 | **需修正**：hover 与 pinned 已共用 controller 和租约；多出来的是生产不可达的一次性 representable，现有 1 个测试覆盖 | `HistoryListView.swift:416-418`；`WebViewLifecycleTests.swift:138` |
| §6.4 `npm test` 进 CI | **已实施** | `.github/workflows/ci.yml:52-53` |
| §6.4 子串断言、Swift↔JS 对等测试 | 仍然存在（182 个 `contains`）；对等测试没有做 | `ChatGPTMarkdownRendererTests.swift` |
| §6.5 阶段文案与取消 | 仍然没有；取消链路其实已端到端存在，只缺按钮 | `HistoryItemTextPreviewView.swift:576、614、618` |
| §6.5 rich v2 子串判断 | **已被 DOM 判断取代**；Swift 残留一段死判断，外加一条只测它的测试 | 同上 |
| §6.5 8 ms 轮询 | 仍然存在；`callAsyncJavaScript` 方案已被代码注释否决 | `MarkdownExportService.swift:1487-1488` |
| §8.7 每次采集一条 info 日志 | 仍然存在 | 809-810 |

### 1.6 契约/文档与代码不一致（独立发现）

- **K1**：契约 :80-89 的流程图（"MarkdownHTMLRenderer → local unified bundle → DocumentBuilder"）、:441 "Preview and export consume the same parse result"，以及 AGENTS.md 里的 "preview and PNG share the parse result"，都暗示解析在 Swift 侧完成一次、结果被共享。实际上 Swift 从不解析：源码以 JSON 嵌入（builder 2780），每个 WebView 各自解析，导出也在自己的 WebView 里再解析一遍（`render.js:87`）。建议措辞改为："load the same document (source + policy payload, base CSS, runtime) and parse it with the same bundle; the parse is identical by determinism"。
- **K2**：契约 :93 说 `MarkdownHTMLRenderer.swift` 负责"bounded, code-aware source normalization"，但 JS 同样在做源改写（`render.js:46-47`：表格管道、`\[…\]` 转换）。
- **K3**：契约 :234 与 :251-252 把 `#标题` 修复写成渲染语义，实现只在 Swift（Node 夹具测试覆盖不到）；表格管道转义两边各做一次。
- **K4**：契约 :424 "Both preview WebView implementations"——其中一个在生产不可达（W1）。
- **K5**：契约 :443 "Each WebView load receives a new opaque render ID"——导出 WebView 不注入 render ID（占位符原样保留，`MarkdownExportService.swift:952-954`），它也不走消息通道。应限定为 preview load。
- **K6**：契约 :451 的 "canonical stylesheet"——代码只等待 `katex.min.css`（builder 2556-2584），基础 CSS 是内联的。
- **K7**：`product-spec.md:80` 写 "Hidden premeasurement is forbidden"，`development-guide.md:94` 写 "Hidden premeasurement must not share this controller"，`renderer-hardening-gate-plan.md` 不变式 4 也禁止；而 `development-guide.md:153` 与代码（`MarkdownPreviewWebView.swift:760-768` 的 prewarm、873-896 的 probe）恰恰在共享 controller 上做离屏预测量。两边必须统一，需要 hh 决定（我建议保留代码行为，把规格改为"只允许把 popover 即将显示的同一文档预加载到无 owner 的 WebView；它不对外发布就绪状态，也不改变可见性；探测高度只按精确的 render cache key 写入缓存"）。
- **K8**：契约 :309 说渲染器"reports" `mathStrictCount` 等——App 从不读取 `result.metadata`（builder 2780-2789 只用 `result.html`），唯一的消费者是 Node 测试。
- **K9**：契约 :370 "only the first 48 frozen entries are considered"——"first" 的顺序没有定义（Swift 字典未排序编码）；而生产侧候选本来就不超过 13 个。
- **K10**：契约 :226/:366 与代码：真正生效的是 DOM 判断；`HistoryItemMarkdownExportController.swift:168-170` 的注释描述的是一个永远不会命中的判断。
- **K11**：契约 Required Verification（:489-506）与 AGENTS.md Renderer 行各写一份且不一致：契约有 `perf-frontend-profile --include-hover` 没有 PNG 目视，AGENTS 正好相反。AGENTS 自己声明契约"alone owns … rendering evidence requirements"。
- **K12**：导出样式在 `:root` 重复定义 7 个布局变量（`MarkdownExportService.swift:960-973`），与 builder 386-411 逐字相同。这违背硬化计划的"token 唯一定义点"（`renderer-hardening-gate-plan.md:232`），也为契约 :453 禁止的"导出改变内容宽度"留了口子（E1）。
- **K13**：契约 :5-20 证据范围里写着维护者本机的绝对路径（`/Users/hh/Downloads/…`、`/tmp/…`）；正文可读性差（卫生审计 §4.2 已建议归档提取脚本）。

### 1.7 回归防护现状

- Node：约 113 个测试，已进 CI。`user-fixtures`、`source-icons`、`delimiters`、`corpus` 读取仓库内共享夹具，但喂给 `render()` 的是原始源，不是生产里经 Swift 预处理后的输入（ATX 修复与科学 profile 的改写没被覆盖）。
- Swift↔JS 契约：只有"源码原样到达运行时"这类子串断言（`ChatGPTMarkdownRendererTests.swift:5-15、283-298`）。`MarkdownRenderingCorpus/cases.json` 的 `expectedProfile` 没被任何 Swift 测试校验。policy 键集合在两边各自定义，没有测试把它们钉在一起。
- 科学 profile 预处理：`MathProtector`、`LaTeXDocumentNormalizer`、`LaTeXInlineTextNormalizer` 没有直接单测，只有 `MarkdownSyntaxProtectorTests`（47 行）。
- 导出：`MarkdownExportServiceTests` 9 个用例只覆盖剪贴板提交、并发闸和取消句柄。`ExportMarkdownPNGUITests` 27 个用例覆盖真实导出，但 `ScopyUITests` 不在 CI 和 Makefile 门禁里，本机又常被系统权限拦住（environment-blocked）。rich v2 真彩色在 CI 里只有一条测死分支的测试（E1）。
- 样式与运行时：`ChatGPTMarkdownRendererTests.swift` 用 182 个 `contains` 钉住 JS 函数名与 CSS 字面量；`WebViewLifecycleTests.swift:350-419` 已有真实 WebKit 几何测试的夹具，可以复用来做计算样式断言（R4）。

### 1.8 LinkMetadata 与网站图标：核实结论

结构上没发现需要单列的问题：图标只在原生端获取，WebView 的 http(s) 请求被 CSP 和拦截规则两层挡住；origin 校验严格（`SourceIconSchemeHandler.swift:34-45`）；单飞去重和许可池有界（`SourceIconService.swift:20-72`）。三处小问题，不单列成改进项：

- 每个图标请求都完整读一次设置（`SourceIconSchemeHandler.swift:12-19`，每份文档最多 24 个 origin）。
- 生产代码里用 `NSClassFromString("XCTestCase")` 判断是否在测试（同文件 16-17）。
- 超过 256 个时，`persist` 的排序比较器里每次都读 `resourceValues`（`SourceIconService.swift:89-98`）。

归入卫生审计的后续批次即可。

## 2. 逐项改进

### C1 采集基线：记录自写、每个 changeCount 只评估一次、单 Task 轮询循环（P1，M）

**问题**

1. **自写竞争**。`checkClipboard` 开头读取 `currentChangeCount`（793），随后在 `await extractRawData`（807，内部有 `await Task.detached` 和主线程 HTML 导入）或 `await processLargeContentAsync`（830）处挂起。挂起期间 MainActor 可以执行 `ClipboardService.copyToClipboard` → `monitor.copyToClipboard(...)`，把基线设成自己写入后的值（509/537/545/578/591/766）。检查恢复后执行 `lastChangeCount = currentChangeCount`（835/851，以及 814/820），基线被退回写入之前，下一 tick 就把自己的写入当成新变化采集了。以下后果由代码推导，没有运行复现：
   - 文本/RTF/HTML：哈希相同，走 `.updated`，`use_count` 在 `incrementUsage`（`ClipboardService.swift:1240`）之外再加 1。
   - 有托管文件的大图：走 `copyToClipboard(imageData:fileURL:)` 写入文件 URL（548-579）。重采时 `shouldPreferImageOverFileURLs`（1857-1865）认定托管路径不是临时图片，于是作为 `.file` 采集，产生一条指向 `Application Support/Scopy/content/<uuid>.png` 的文件行；原图片条目被清理后，这一行就悬空了。
   - codex 模式栅格化的 PNG：哈希变了，多出一条重复的图片行。

   竞争窗口等于一次外部采集的 await 时长：文本解析、HTML 导入（0.3–0.7 s/MB）、信封落盘。"在别的 App 复制后立刻用热键从 Scopy 回贴另一条"就会撞上。
2. **同一个 changeCount 被重复评估**。有两个分支不推进基线：`extractRawData` 返回 nil（807，例如剪贴板被清空——密码管理器定时清空正是这种——或只有私有类型），以及信封落盘失败（830）。结果是每个 tick 都在主线程重读一遍；磁盘满时，每 500 ms 在主线程重读一整张大图。
3. **轮询的形状**。`Timer` 没有 `tolerance`，每 tick 新建一个 `Task`（1084-1096）。为了在 `deinit` 里让 timer 失效，引入了 `TimerBox`/`SendableTimer`（105-126）和 `DispatchQueue.main.async`（376-399）。重入靠 `isCheckingClipboard`（262、788-791）防护。两处 clamp 互不一致：监控器是 0.1–5 s（314、434），设置层与 UI 是 100–2000 ms（`SettingsStore.swift:86-87`；`ClipboardSettingsPage.swift:245`）。
4. **同一轮询窗口内的连续复制**。第一份在第二份写入时已经被覆盖，轮询模型下物理上找不回来；`recordChangeDelta`（797-803）只记数，显示在 About 页的 `changeJumpCount`（`AboutSettingsPage.swift:243`）。注意 delta>1 不一定意味着丢失：Scopy 自己的 `copyToClipboard(data:type:.png)` 就是 `clearContents` 加 `declareTypes`，递增两次（522-524）。

**设计**

```swift
// ClipboardMonitor（@MainActor）
private var handledChangeCount: Int        // 原 lastChangeCount：最后一个"已处理完"的 changeCount
private var ownWriteGeneration: UInt64 = 0 // Scopy 每写一次剪贴板 +1
private var persistRetry: (changeCount: Int, attempts: Int)?

/// 每个写剪贴板的出口，在 clearContents() 之后调用（setData 成败都调用）。
private func recordOwnWrite() {
    handledChangeCount = pasteboard.changeCount
    ownWriteGeneration &+= 1
}

enum CheckOutcome: Equatable { case unchanged, settled, deferred }

@discardableResult
func checkClipboard() async -> CheckOutcome {
    let observed = pasteboard.changeCount
    guard observed != handledChangeCount else { return .unchanged }
    let generation = ownWriteGeneration, session = monitoringSessionID
    switch await captureChange(observed) {          // 抽取 → 路由 → 入队或落盘
    case .captured, .nothingToCapture:
        settle(observed, generation, session); return .settled
    case .persistFailed:
        if shouldRetry(observed, maxAttempts: 3) { return .deferred }
        settle(observed, generation, session)
        Task { await ClipboardIngestMetrics.shared.recordCaptureDropped() }
        return .settled
    case .staleRead:                                  // C2：读取期间 changeCount 变了
        return .deferred
    }
}

private func settle(_ observed: Int, _ generation: UInt64, _ session: UInt64) {
    // 挂起期间如果发生过自写，基线已由 recordOwnWrite 设到更新的值，不能再退回。
    guard session == monitoringSessionID, generation == ownWriteGeneration else { return }
    handledChangeCount = observed
}
```

这里不依赖 changeCount 单调递增，也不用 `max()`：pboard 守护进程重启后计数可能归零，单调假设会让采集永久停住。比较 generation 只回答一个问题——挂起期间有没有自写。

用 Task 循环替换 Timer：

```swift
private var pollTask: Task<Void, Never>?

public func startMonitoring() {
    guard pollTask == nil else { return }
    monitoringSessionID &+= 1
    handledChangeCount = pasteboard.changeCount
    replayPendingLargeContentFromDisk()
    let session = monitoringSessionID
    pollTask = Task { @MainActor [weak self] in
        var burstUntil = ContinuousClock.now
        while !Task.isCancelled {
            guard let interval = self?.nextInterval(now: .now, burstUntil: burstUntil) else { return }
            try? await Task.sleep(for: interval, tolerance: interval / 5)
            guard let self, self.monitoringSessionID == session, !Task.isCancelled else { return }
            if await self.checkClipboard() == .settled { burstUntil = .now + Self.burstWindow }
        }
    }
}
```

- 删除 `TimerBox`、`SendableTimer`、`installMonitoringTimer`、`isCheckingClipboard`，以及 `deinit` 里的 timer 分支。循环只持有 `weak self`，对象释放后下一轮自然退出。循环串行执行，所以不需要防重入。
- `setPollingInterval` 只改属性，下一轮生效。监控器只保留"大于 0"的下限，上限归设置层管。
- `nextInterval` 是纯函数：`burstUntil` 之前返回 `min(burstInterval, pollingInterval)`，之后返回 `pollingInterval`。不启用突发轮询时 `burstWindow = .zero`，函数退化为常量。
- 采集的 `.info` 日志（809-810）降为 `.debug`。
- 导出写剪贴板（`MarkdownExportService.swift:245-256`）**不**登记为自写。导出的 PNG 作为外部变化进入历史是现状，本项不改；把它登记为自写属于另一个产品决定。

**实现步骤**（每步可单独提交）：① `recordOwnWrite`、generation、`settle`，把 nil/空结果与落盘失败纳入"只评估一次"；把 `lastChangeCount` 改名为 `handledChangeCount`（14 处，同一文件）。② Timer 换成 Task 循环，删掉 `TimerBox` 等，日志降级。③ hh 批准后加突发轮询。

**涉及文件**：`Scopy/Services/ClipboardMonitor.swift`（含 8-93 的 `ClipboardIngestMetrics`，新增 `recordCaptureDropped`）、`ScopyTests/ClipboardMonitorTests.swift`；如需展示丢弃计数，再改 `AboutSettingsPage.swift`。

**验证门禁**：功能代码跑 `make build` + `make test-unit`；MainActor 循环与取消跑 `make test-strict`；采集行为跑 `make perf-capture SCENARIO=text COUNT=10 INTERVAL=1`，前后对照（脚本会检查新行是否排在 Recent 顶部，并打印主线程等待）。突发轮询另跑 `INTERVAL=0.15 COUNT=10`，比较落库行数。

**回归风险与守护测试**：

- `testOwnWriteDuringSuspendedCaptureIsNotRecaptured`：在命名 pasteboard 写入外部文本；`let t = Task { await monitor.checkClipboard() }`；`await Task.yield()`（检查此时挂在 detached 文本处理上）；同步调用 `monitor.copyToClipboard(text:)`；`await t.value`；再调一次 `checkClipboard()`，断言返回 `.unchanged`，且 contentStream 只收到外部那一条。这条测试在 HEAD 上应该失败，证明它能抓住回归。
- `testFileBackedImageOwnWriteIsNotRecapturedAsFile`：同样的流程，写入换成 `copyToClipboard(imageData:fileURL:)`，断言不出现 `.file`。
- `testUnsupportedOnlyChangeIsEvaluatedOnce`：只写私有类型 `com.scopy.test.private`；第一次调用返回 `.settled`，第二次返回 `.unchanged`。
- `testPersistFailureRetriesBoundedThenSettles`：写入 ≥50 KB 文本（强制走信封路径），把 ingest 目录设为 `chmod 0500` 让信封写入失败；前两次返回 `.deferred`，第三次返回 `.settled`，丢弃计数为 1。
- `testNextIntervalBurstWindow`：纯函数测试。
- 现有 59 个用例的断言不改。
- 风险：基线写错会导致漏采或重采，上面四条覆盖了"推进、不推进、推进过早"三种结局。Task 循环在 run loop tracking mode（菜单、拖拽）下的调度：MainActor 作业经主队列执行，主队列在 common modes 下被服务，与原 Timer 加入 `.common` 等价，但需要在实机上边拖滚动条/开菜单边复制验证一次。

**规模**：M（步骤 ① 为 S）。

**需要 hh 决定**：是否启用突发轮询。推荐：检测到变化后 1.5 s 内以 100 ms 轮询。启用后设置项的语义变成"空闲轮询间隔"，产品规格表 `Polling interval` 一行要改措辞。

### C2 每次变化只读一轮剪贴板 + 类型决策只看会话 + 主线程图片编码外移（P1，M）

**问题（证据）**

- **同一表示读两次**。带图片的 Office/表格复制：`shouldPreferRichTypesOverImage` 为了嗅探读一次 html/rtf/string（1840-1849），第 3–5 步再读一次（1739-1741）。临时图片文件：`shouldPreferImageOverFileURLs` 调一次 `extractImageDataForIngest`（1861），第 2 步再调一次（1723）。
- **文本复制先绕一圈图片读取**。最常见的纯文本/富文本复制，也要先无条件尝试 `.png`、`.tiff`、`NSImage(pasteboard:)`（2706-2718），才走到文本分支。
- **图片编码在主线程**。`NSImage(pasteboard:)` 分支在主线程做 `tiffRepresentation` 和 `convertTIFFToPNG`（2714-2718）；`loadImageFileDataAsPNG` 读文件、可能做 TIFF→PNG（1890-1905），而且在 `shouldPreferImageOverFileURLs` 里就执行过一次（1864）。这与 1722 的注释"TIFF 转 PNG 延迟到后台"矛盾。
- **KaTeX 解析在主线程**。`parseHTMLOnMain`（1743-1745）调用 `extractPlainTextFromHTML`（2364-2380），先在主线程做编码探测和 KaTeX HTML→Markdown 的字符串解析；真正必须在主线程的只有随后的 `NSAttributedString` HTML 导入。
- **没有原子性**。读取跨多次 IPC；期间别的进程写入，可能出现 html 来自 A、string 来自 B。现在没有读后复核 changeCount。
- **没有大小上限**。快照观测到的最大值：image 23.4 MB、html 0.55 MB、rtf 1.0 MB。读取发生在得知大小之前，上限也挡不住读取本身。

**设计**

```swift
@MainActor
final class PasteboardReadSession {                 // 每次 checkClipboard 一个，用完即弃
    let changeCount: Int
    let types: Set<NSPasteboard.PasteboardType>
    private let pasteboard: NSPasteboard
    private var dataCache: [NSPasteboard.PasteboardType: Data?] = [:]

    init(_ pasteboard: NSPasteboard) {
        self.pasteboard = pasteboard
        changeCount = pasteboard.changeCount
        types = Set(pasteboard.types ?? [])
    }
    lazy var fileURLs: [URL] = (pasteboard.readObjects(forClasses: [NSURL.self],
        options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    lazy var string: String? = pasteboard.string(forType: .string)
    lazy var hasImageRepresentation: Bool =
        !types.isDisjoint(with: NSImage.imageTypes.map(NSPasteboard.PasteboardType.init))
    func data(_ type: NSPasteboard.PasteboardType) -> Data? {   // 每种类型最多一次 IPC
        if let cached = dataCache[type] { return cached }
        let value = pasteboard.data(forType: type)
        dataCache[type] = value
        return value
    }
    var isStillCurrent: Bool { pasteboard.changeCount == changeCount }
}

enum CaptureDecision {
    case files([URL])
    case image(ImageCapture)        // .png(Data) | .tiff(Data) | .imageFile(URL)：编码交给 ingest 管线
    case text(rtf: Data?, html: Data?, string: String?)
    case nothing
}

enum CapturePolicy {                // 只接收 session，碰不到 NSPasteboard
    @MainActor static func decide(_ session: PasteboardReadSession) -> CaptureDecision
}
```

- `CapturePolicy.decide` 原样移植 HEAD 的优先级：文件 > 图片 > RTF > HTML > 纯文本，包括 Office/表格和临时图片两个例外。只有两处差别：
  - 当 `hasImageRepresentation == false` 时跳过图片读取。此时 `NSImage(pasteboard:)` 本来就返回 nil，行为不变。
  - TIFF→PNG 和文件读取全部推迟到 ingest 管线。图片总是走信封路径（828），决策只带原始字节和"需要转换"标记，复用现有的 `imageDataWasTIFF`。
- 读取结束后 `guard session.isStillCurrent else { return .staleRead }`，对应 C1 的 `.deferred`：不推进基线，下一 tick 用新的 changeCount 重读。
- 文本抽取 `CapturedTextExtraction.make(rtf:html:string:importHTML:)` 在 detached 任务里运行，编码探测和 KaTeX 解析也移进去。回主线程的闭包只做 `NSAttributedString(data:options:[.documentType: .html])`。
- 大小：不设载荷上限，与 hh 的"保留所有剪贴板内容"一致。唯一建议的预算：HTML 导入按 0.3–0.7 s/MB 阻塞主线程（2019-2020 注释）。当 html > 4 MiB 且 `.string` 非空时跳过导入，直接用 `.string`，代价是超大 TeX 页面失去 HTML 侧的修正。快照里最大的 HTML 只有 0.55 MB，这个预算在已观测数据上一次都不会触发。

**实现步骤**：① 引入 session，现有抽取与启发式改为读 session（行为不变）。② 图片编码外移，加 `hasImageRepresentation` 门控。③ KaTeX 解析外移。④ 读后复核。⑤ hh 批准后加 HTML 导入预算。

**涉及文件**：`ClipboardMonitor.swift`（C3 拆分后落在 `Capture/PasteboardReadSession.swift`、`Capture/CapturePolicy.swift`、`Capture/CapturedTextExtraction.swift`）、`ClipboardMonitorTests.swift`。

**验证门禁**：`make build`、`make test-unit`；改动了 detached 与 MainActor 的边界，加跑 `make test-strict`。用 `make perf-capture SCENARIO=rich` 和 `SCENARIO=image` 前后对照主线程等待（C1 把日志降级后，用脚本的 `--sample` 输出或 `log stream --debug`）。

**回归风险与守护测试**：

- 现有 59 条原样通过。它们经命名 pasteboard 驱动生产的 `checkClipboard`，已覆盖 Office 表格、微信临时图、KaTeX、中文表格、`<img` 优先级。
- 新增 `testNSImageOnlyPasteboardEmitsPNGPayload`：只写 `public.jpeg`，没有 png/tiff；断言最终载荷是 PNG 且在管线里完成转换。
- 新增 `testTemporaryTIFFImageFileIsConvertedInPipeline`。
- "同一类型只读一次"由结构保证：决策代码只能经 session 读取。不写计数型测试（剪贴板服务会缓存 provider 提供的数据，计数无法观测）。
- 风险：如果 `NSImage.imageTypes` 与 `NSImage(pasteboard:)` 能读的类型不完全一致，可以保留 `NSImage(pasteboard:)` 的尝试，只跳过 png/tiff 的读取。

**规模**：M。

**需要 hh 决定**：是否要 HTML 导入预算。

### C3 ingest 串行有序、回放按创建时间、TIFF 用真实扩展名、拆分 `ClipboardMonitor`（P2，L）

**问题（证据）**

- **顺序**。小内容走同步路径，直接入队（840-851）；图片和 ≥50 KB 的内容走信封加最多 3 个并发 detached worker（903-1021，`ScopyThresholds.ingestMaxConcurrentTasks = 3`）。入队顺序等于完成顺序，而落库时间戳是 upsert 时刻（`StorageService.swift:467、494、504`）。所以当图片处理时长超过一个轮询间隔时，"先复制大图、后复制文本"可能以相反顺序出现在历史里。
- **回放**。`discoverPendingEnvelopeURLs` 按文件名排序（1204-1216），而文件名是随机 UUID，崩溃后回放顺序等于随机；信封里没有时间字段（229-238）。
- **TIFF**。worker 里 TIFF→PNG 失败时保留 TIFF 字节（953-957），`buildPayload` 却用 `.png` 命名临时文件（1055-1060），`StorageService.makeExternalPath` 对 `.image` 也固定用 `.png`（`StorageService.swift:2223-2226`）。结果是磁盘上出现内容为 TIFF 的 `.png`，AirDrop 或共享给按扩展名识别的第三方时会出问题。
- **结构**。一个类型同时负责轮询、读取、类型决策、文本规范化、载荷落盘、spool 状态机、回放、指标 actor 和写剪贴板。`queueLock`（269）只是为了让 `deinit` 能碰隔离状态；`testingAsyncProcessingDelayNs`（281）是一个 `nonisolated(unsafe)` 全局测试旋钮，生产 worker 会读它（924-926）。

**设计**

1. **串行 FIFO 管线**：

```swift
@MainActor
final class IngestPipeline {
    enum Job { case ready(ClipboardMonitor.ClipboardContent); case envelope(URL) }
    private var queue: [Job] = []
    private var worker: Task<Void, Never>?
    init(spool: IngestSpool, output: AsyncBoundedQueue<ClipboardMonitor.ClipboardContent>,
         processingDelay: Duration = .zero)          // 取代全局 testingAsyncProcessingDelayNs
    func submit(_ job: Job)                           // 追加；需要时启动 worker
    func replay(_ envelopes: [URL])                   // 调用方已按 (creationDate, 文件名) 排好序
    func cancelAll()
}
```

   worker 一次取一个 job。`.ready` 直接 `output.enqueue`；`.envelope` 在 detached 任务里做加载 → TIFF→PNG → 哈希 → `buildPayload`，再回 MainActor 检查会话并入队。小内容也通过 `submit(.ready)` 进队，排在正在处理的大图后面，所以顺序等于采集顺序。删除 `activeIngestTasks`、`startNextIngestTasksIfNeeded`、`finishIngestTask`、`queueLock`、`maxConcurrentTasks`。

   代价：失去监控器一侧最多 3 路的并行（TIFF→PNG 与 SHA-256）。下游 `ClipboardService` 本来就是串行 `for await`（`ClipboardService.swift:986-990`），每张图还要串行跑 pngquant，所以端到端吞吐只在"连续多张大 TIFF 截图"时下降。
2. **回放排序**：`discoverPendingEnvelopeURLs` 读 `.creationDateKey`，按 (creationDate, 文件名) 排序。`writeAtomically` 先写 `.tmp` 再 rename（`StorageService.swift:2150-2165`），creationDate 约等于采集时刻。**不改信封格式**，这样就不必在"旧信封解不出 → 被隔离 → 丢失待回放内容"和"可选字段兼容层"之间二选一。落库时间戳仍是落库时刻（与现状一致）；要保留采集时刻，得由后端在 `ClipboardContent` 上加 `capturedAt`（交接后端评审）。
3. **TIFF 用真实扩展名**：转换失败时保留字节，扩展名由 `CGImageSourceGetType` 嗅探决定（得到 `tiff`，识别不了时用 `dat`）。`buildPayload` 与 `StorageService.makeExternalPath` 共用同一个 `ImageFileExtension.sniff(_:)`，后者属后端，交接。
4. **拆分**：先做纯移动、零行为变化，再在新文件里做 C2/C3 的实质改动。目录 `Scopy/Services/Capture/`，仍属 ScopyKit（`Package.swift` 按目录收录；新增文件后跑 `bash scripts/xcodegen-generate-if-needed.sh`）。

| 新文件 | 来源（HEAD 行） | 约行数 | 职责 |
| --- | --- | ---: | --- |
| `ClipboardMonitor.swift` | 97-493、786-853 | 250 | 生命周期、轮询循环、基线、编排；`ClipboardContent`、`TerminalIngestAcknowledgement` 仍是它的嵌套类型（`ClipboardService` 用全名引用，不做无意义改名） |
| `PasteboardWriter.swift` | 495-785；并入 `MarkdownExportService.swift:245-318` | 260 | 所有剪贴板写入；每次写后调用监控器的 `recordOwnWrite` |
| `PasteboardReadSession.swift` | 新增（C2） | 90 | 每次变化一轮读取 |
| `CapturePolicy.swift` | 1687-1945、2681-2727 | 260 | 类型决策、临时图/Office 嗅探、哈希策略（1779-1824） |
| `CapturedTextExtraction.swift` | 1946-2667 | 720 | 文本候选选择、Markdown/TeX 启发式、RTF/HTML/KaTeX 抽取、`normalizeText` |
| `IngestSpool.swift` | 229-256、1119-1680 | 560 | 信封格式、落盘、校验、终态、隔离、清扫、legacy 迁移 |
| `IngestPipeline.swift` | 855-1118（重写） | 150 | 串行处理与回放 |
| `ClipboardIngestMetrics.swift` | 8-93 | 90 | 指标 actor |

   原文件 138 行注释中有 54 行中文，移动时统一译为英文，不单独提交。

**实现步骤**：① 纯移动拆分（diff 只有移动和访问修饰符）。② 管线串行化，测试旋钮改为注入。③ 回放排序。④ TIFF 扩展名（与后端同一提交，或先落监控器一侧）。

**验证门禁**：`make build`、`make test-unit`、`make test-strict`。管线并发语义有变，加跑 `make test-tsan`；本机若跳过，以 hosted CI 的 TSan job 为准（`release-current.yml` 记录为 `pass_hosted`）。用 `make perf-capture SCENARIO=image COUNT=5 INTERVAL=0.3` 和 `SCENARIO=text` 核对行顺序，脚本自带 Recent 顺序检查。

**回归风险与守护测试**：

- `testSlowLargeCaptureStillPrecedesLaterSmallCapture`：用 `IngestPipeline(processingDelay: .milliseconds(300))`，先写 60 KB 文本、再写 10 字节文本，断言 contentStream 顺序。在 HEAD 上应该失败。
- `testReplayOrdersEnvelopesByCreationDate`：手工写 3 个信封，用 `FileManager.setAttributes([.creationDate: …])` 设定与 UUID 字典序相反的时间，断言按时间回放。
- `testTIFFConversionFailureKeepsBytesWithTIFFExtension`：用 `II*\0` 头加垃圾字节构造一个"能识别为 TIFF、但编码不出 PNG"的载荷。
- 既有的 `testPendingLargeContentReplaysAfterMonitorRestart`、`testLargeTIFFConversionEmitsPNGPayloadFile`、`testCorruptPendingEnvelopeWithoutPayloadIsDiscardedOnReplay` 原样通过。

**规模**：L（拆分 M + 管线 M）。

**需要 hh 决定**：是否接受监控器一侧并行度从 3 降到 1（推荐接受）。legacy 的 Caches→App Support spool 迁移（1507-1611，v0.65.0 引入）沿用卫生审计 §2.3 的保留结论，本提案不改。

**交接（后端）：缩略图像素**。`StorageService.makeThumbnailPNG`（2314-2350、2355-2392）把 `thumbnailHeight`（单位 pt）直接当作像素上限，长边取 `max(width*scale, maxHeight)`，不限宽；行内用 `.frame(height:)` + `.aspectRatio(.fit)` 显示（`HistoryItemThumbnailView.swift:20-23`）。结果是 Retina 屏上放大 2 倍、发虚，全景图生成超宽位图并按比例把行撑宽。快照 `perf-db/thumbnails` 抽样 182 张：高度只有 40 或 60 px 两种，最宽 592 px。方向：
- 像素高 = pt × 2，用常量，不随屏幕变化，避免在不同屏幕间来回重生成；
- 长边不超过 4 倍高度；
- 显示侧加 `.frame(maxWidth: height * 4)`（前端）；
- 旧缓存靠新的文件名后缀一次性重建，不写兼容读取。

### R1 渲染热路径：默认 profile 跳过无效往返、删掉没人读的诊断、protector 改成线性（P1，S）

**问题/证据**

- `MarkdownHTMLRenderer.render`（`MarkdownHTMLRenderer.swift:9-51`）对所有 profile 都执行 `MarkdownSyntaxProtector.protectForLooseMathRepair`（11）和 `restore`（17-20）。protector 唯一的受益者是 `LaTeXDocumentNormalizer`（13-15），而后者只在 `latexDocumentLike/pdfOCRScientific` 下启用（`MarkdownRenderContext.swift:21-26`）。默认 profile 下 `restore(protect(x)) == x`：按 `"\n"` 切分再拼接，精确还原；占位前缀保证在源码里不出现（`MarkdownSyntaxProtector.swift:145-151`）；形如 `P<n>X` 的 token 互不为子串。所以这是纯往返，跳过它输出不变。
- **二次方**：`protectInlineSyntax` 在行内**每一个字符位置**都调用 `urlSpan` 和 `filePathSpan`（120-130），这两个函数都先 `String(line[index...])` 复制整段行尾，再 `lowercased()`（244-263），每行代价 O(L²)。快照里 716 条类 Markdown 文本（1k–200k 字符）中，15 条的最长行 ≥5 KB，2 条 ≥20 KB（awk 按字节统计）。估算一条 20 KB 的行要复制约 4×10⁸–8×10⁸ 字节，量级是数百毫秒，占着预览许可池里的一个名额。未实测。
- **死诊断**：`MarkdownRenderDiagnostics.explicitMathDetected` 每次渲染都跑一次 `MarkdownDetector.containsMath`（47），但所有调用者都只取 `.html`（`HistoryHoverPreviewPipeline.swift:713、718`；`HistoryItemTextPreviewView.swift:433`；`HistoryItemMarkdownExportController.swift:108`；`MarkdownHTMLRenderer.swift:6`）。卫生审计 §1.1 已列入。

**设计**

```swift
enum MarkdownHTMLRenderer {
    /// Returns "" when cancelled; callers already treat empty HTML as "no document".
    static func render(markdown: String, context: MarkdownRenderContext) -> String {
        var source = markdown
        if context.policy.allowLatexDocumentNormalize {
            let islands = MarkdownSyntaxProtector.protectForLaTeXDocumentNormalization(source)
            guard !Task.isCancelled else { return "" }
            source = MarkdownSyntaxProtector.restore(
                LaTeXDocumentNormalizer.normalize(islands.markdown), placeholders: islands.placeholders)
        }
        if context.policy.allowLatexInlineTextNormalize {
            let math = MathProtector.protectMath(in: source)
            source = MathProtector.restoreMath(in: LaTeXInlineTextNormalizer.normalize(math.markdown),
                                               placeholders: math.placeholders, escape: { $0 })
        }
        source = MarkdownATXHeadingNormalizer.normalize(source)          // R3 步骤 2 后删除
        source = MarkdownTableCodeSpanPipeNormalizer.normalize(source)   // R3 步骤 1 后删除
        guard !Task.isCancelled else { return "" }
        return MarkdownHTMLDocumentBuilder.document(markdown: source, context: context)
    }
}
```

- `urlSpan`/`filePathSpan` 改为在 `line.utf8[index...]` 上做不分配内存、ASCII 大小写不敏感的前缀比较：先看首字节是不是 `h/H/f/F/./~//`，再逐字节比。之后只有科学 profile 还会走到这段。
- 删除 `MarkdownPreviewRenderer.swift`：12 行，只有两个 struct，文件名也名不副实。

**实现步骤**：① 门控 + 删诊断，一个提交。② 前缀比较去掉分配，一个提交。

**涉及文件**：`MarkdownHTMLRenderer.swift`、`MarkdownPreviewRenderer.swift`（删）、`MarkdownSyntaxProtector.swift`、5 处调用点（去掉 `.html`）、`MarkdownSyntaxProtectorTests.swift`。

**验证门禁**：跑 AGENTS"Renderer"行中适用于 Swift 的部分：`make build`、`make test-unit`、`make test-strict`，外加一次真实 App 的 PNG 目视检查。输出应逐字节不变，可以用 `SCOPY_EXPORT_DUMP_PATH` 对同一夹具前后各导出一次再 `cmp`。没改 JS，Node 门禁不涉及。收益用 `scripts/perf-frontend-profile.sh --include-hover` 取证，看 `hover.markdown_render_ms` p95（脚本内建基线对照，`perf-frontend-profile.sh:775`）。

**回归风险与守护测试**：

- `testDefaultProfilesEmbedSourceAfterOnlyHeadingAndPipeRepair`：用 `MarkdownRenderingCorpus/*.md` 和 `markdown_delimiter_repro.md` 里默认 profile 的样本，从文档中**解码**出嵌入的 JSON 源（定位 `ScopyUnifiedMarkdown.render(` 后用 `JSONDecoder`，不用子串匹配），断言等于 `TablePipe(ATX(source))`。
- `testSyntaxProtectorRoundTripIsIdentity`：用同一批文件，加上含 URL、路径、反引号、引用定义的构造输入，断言 `restore(protect(x)) == x`。这是科学 profile 路径成立的前提。
- `testSyntaxProtectorLongLineIslands`：一条 60,000 字符的单行，URL 与路径分布在行首、行中、行尾，断言占位与还原都正确。不做计时断言。
- 风险极低，唯一的语义面是取消时返回 ""，与现状一致。

**规模**：S。

### R2 渲染输入只算一次：context、内容键、enrichment 指纹各算一次；从预览发起的导出直接用屏幕上的文档（P2，M）

**问题/证据**

- `MarkdownRenderContextResolver.defaultContext`（`MarkdownRenderContext.swift:63-76`）包含三件事：profile 检测（80k 前缀、十几次全文 `contains`、一次 `lowercased()` 拷贝，`MarkdownSourceProfileDetector.swift:4-32`）、全文 SHA-256（`LinkEnrichmentModel.swift:33-35`）、enrichment 存储查找（未命中时读盘，`LinkEnrichmentStore.swift:31-44`）。它在主线程上被调用：`markdownRenderEvent`（753，调用方 444、549 在 `@MainActor runMarkdownFilePreview`（422）里，649 在 `@MainActor runTextPreview` 里），文件预览路径 436、452、516，以及 `HistoryItemView.swift:1827`。
- popover 的 SwiftUI `body` 每次求值，都调用两次 `markdownRenderKey`、一次 `enrichmentFingerprint`（`HistoryItemTextPreviewView.swift:96-103`），合计 3 次全文 SHA-256，再加 2 次 `deterministicTextCacheKey`（也是 SHA-256，`ClipboardItemContentRevision.swift:138-174`）。
- `LinkEnrichmentPayload.fingerprint` 是计算属性，每次访问都把所有 entry 用 `JSONEncoder` 编码一遍再 SHA-256（`LinkEnrichmentModel.swift:17-29`）。entry 里有 data-URI 图片（解码后预算 480 KB，`LinkEnrichmentFetcher.swift:16`）。对已富化的文档，每次 `body` 求值会在主线程把约 0.6 MB 的 JSON 重编码三次（估算）；拖动缩放滑块时 `body` 频繁求值。
- 导出从源码重算（`HistoryItemMarkdownExportController.swift:103-109`）。`exportToPNG` 在 `model.text` 为空时会把**整份 HTML 文档当成 Markdown 源**传进去（`HistoryItemTextPreviewView.swift:643`：`model.text ?? html`）。这个回退分支走不到，但语义是错的。
- context 在 5 处分别构造：上面 4 处，加上 `HistoryItemTextPreviewView.swift:429`。

**设计**

```swift
/// 决定文档字节的全部输入；在主线程之外算一次。
struct MarkdownRenderInput: Sendable, Equatable {
    let source: String
    let contentKey: String                  // SHA-256(source)，与 LinkEnrichmentContentKey 同值
    let context: MarkdownRenderContext      // profile + policy + layoutScale + enrichment
    let enrichmentFingerprint: String       // 读取 payload 上已存好的属性
    var renderKey: String { "\(context.layoutScale.cacheKey)|\(enrichmentFingerprint)|\(contentKey)" }
    nonisolated static func make(source: String, layoutScale: MarkdownChatGPTLayoutScalePercent) -> Self
}

struct MarkdownDocument: Sendable, Equatable {   // 预览与导出共用的唯一产物
    let input: MarkdownRenderInput
    let html: String
}
```

- `LinkEnrichmentPayload.fingerprint` 改成存储属性，在 `init` 和解码后算一次。算法不变，所以现有缓存键的值不变。
- `HoverPreviewModel` 改为持有一个 `MarkdownDocument`，取代现在分散的三个字段 `markdownHTML`、`markdownHTMLLayoutScale`、`markdownHTMLEnrichmentFingerprint`。删掉 `markdownRenderKey`/`enrichmentFingerprint` 两个静态函数，`body` 只比较已经存好的键。
- `MarkdownRenderCacheKey.make(contentHash:context:)` 改成 `make(input:itemKey:)`，参数名不再把"修订键"叫作"内容哈希"。
- 导出接口改为 `exportMarkdownToClipboard(document: MarkdownDocument, …)`。从预览发起时传入屏幕上的文档，与显示的逐字节相同；从行菜单发起时，先 `MarkdownRenderInput.make` 再渲染。删掉 `model.text ?? html` 回退，改成 `guard let source = model.text`。

**实现步骤**：① 指纹改成存储属性（S，可单独提交）。② 引入 `MarkdownRenderInput`，替换 5 处 context 构造。③ `MarkdownDocument` 贯通 `HoverPreviewModel` 与导出。

**涉及文件**：`LinkEnrichmentModel.swift`、`MarkdownRenderContext.swift`、`MarkdownRenderCacheKey.swift`、`HoverPreviewModel.swift`、`HistoryItemTextPreviewView.swift`、`HistoryHoverPreviewPipeline.swift`、`HistoryItemView.swift`、`HistoryItemMarkdownExportController.swift`、`PinnedPreviewController.swift`（`adoptRenderedContent` 要复制新字段）。与前端评审的交叉：这里只动这些类型中的渲染键和文档字段，不动 popover 尺寸逻辑。

**验证门禁**：`make build`、`make test-unit`；跨 actor 传递 Sendable 值，加跑 `make test-strict`。前端性能跑 `make perf-frontend-profile`（smoke）和 `--include-hover`；再做一次真实 PNG 目视。

**回归风险与守护测试**：

- `testEnrichmentFingerprintUnchangedByStoredProperty`：固定一个 payload，断言指纹等于写死的十六进制期望值（即旧算法的输出）。
- `testRenderInputKeysChangeWithScaleAndEnrichmentOnly`。
- `testPreviewLaunchedExportUsesDisplayedDocument`：针对纯函数 `HistoryItemMarkdownExportController.resolveDocument(displayed:source:layoutScale:)`，键一致时返回显示中的文档本身，不一致时重新渲染。
- `PinnedPreviewControllerTests` 现有用例覆盖文档移交。
- 风险：缓存键格式一变，进程内缓存会一次性全部未命中（重启即恢复，没有持久影响）；`HoverPreviewModel` 字段合并会波及 pinned 快照的复制。

**规模**：M。

### R3 Swift/JS 收敛：Swift 只做判定，JS 做全部源改写；补齐跨语言契约测试（P1，M；科学 profile 迁移 L，需 hh 定）

**现状**

| 预处理 | Swift | JS | 生产中的执行 |
| --- | --- | --- | --- |
| 表格行内 code span 的管道转义 | `MarkdownTableCodeSpanPipeNormalizer.swift`（171 行，测试 54 行） | `render.js:465-656` 中的 `protectTableCodeSpanPipes` | 两边各跑一次；JS 对已转义的管道幂等 |
| ATX `#标题` 补空格 | `MarkdownATXHeadingNormalizer.swift`（88 行，测试 43 行） | 无 | 只在 Swift；Node 夹具测试喂的是未修复的源 |
| `\[ … \]` 转 `$$` 等 | 无 | `scopyBackslashMathPreprocessor.js`（225 行） | JS，所有 profile |
| 宽松数学修复 | 无 | `remarkScopyLooseMathRepair.js`（AST 级，受 `allowLooseMathRepair` 控制） | JS，latexDocumentLike/pdfOCR |
| LaTeX 文档结构、行内格式、数学段规范化 | 1,726 行（§1.1） | 无 | Swift，scientific/latexDocumentLike/pdfOCR；除 protector 外没有直接单测 |
| fence 识别 | `MarkdownCodeSkipper.fencePrefix`（按 `.whitespaces` 修剪） | `render.js:518-529`、`scopyBackslashMathPreprocessor.js` 各一份（按 `trim()` 修剪） | 三份，"空白"的定义不同 |

跨语言契约的缺口：

- `MarkdownRenderingCorpus/cases.json` 给每个样本写了 `expectedProfile`/`allowLooseMathRepair`，但只有 Node 把它们当**输入**传给 `render`（`corpus.test.js:14-18`）。Swift 的 `MarkdownSourceProfileDetector` 从没被这份 corpus 校验过（全仓没有 Swift 引用它）。
- policy 载荷：Swift 发送 `profile/nativeSourceIcons/allowLooseMathRepair/policyVersion/linkEnrichment` 五个键（builder 2849-2859）；JS 只用其中的 `allowLooseMathRepair/nativeSourceIcons/linkEnrichment`（`render.js:453-463`；`profile`、`policyVersion` 读进来就丢，见卫生审计 §4.1）；`nativeSourceIcons` 在生产中恒为 true。编码没用 `.sortedKeys`（2297-2300），同一输入生成的文档字节会随进程的字典哈希种子变化，违反硬化计划"同源同 context ⇒ 字节相同"的约束（`renderer-hardening-gate-plan.md:236`）。

**设计（终态）**：`MarkdownHTMLRenderer`（或者并入 builder 后的 `document(source:context:)`）只做 `source + context → 文档`。所有源改写都在 `render.js` 里完成，发生在 parse 之前或 AST 上。这样 Node 测试看到的输入就是生产输入。

**步骤**（每一步都先加对等测试，再删旧实现）：

1. **删 Swift 表格管道转义（S）**：把 `MarkdownTableCodeSpanPipeNormalizerTests` 的 5 个用例移植到 `render.test.js`，断言 JS 输出的单元格结构（例如一个单元格内的 code 里保留原始管道）；通过后删除 Swift 文件和测试。两者的差别只在"空白"的修剪定义（JS 的 `trim()` 还会去掉 `\r` 和 BOM），只影响病态输入。删除后的行为 = JS 的行为 = Node 测试测的行为。
2. **ATX 移入渲染器（S）**：在 `render.js` 新增 `repairATXHeadings(source)`，放在 `protectTableCodeSpanPipes` **之前**。这与 Swift 现在的顺序一致，避免以 `#` 开头的扁平表头行先被当成表格处理。`fencePrefix`/`leadingIndentSpaces` 抽到新模块 `src/scopyLineScan.js`，同时替换 `scopyBackslashMathPreprocessor.js` 里的那份副本。规则逐条照搬 Swift：1–6 个 `#`、缩进不超过 3 个空格、`#!` 例外、剩余部分不超过 200 字符。把 `MarkdownATXHeadingNormalizerTests` 和 `ChatGPTMarkdownRendererTests.testRendererNormalizesATXHeadingsWithoutTouchingCode` 移植成 Node 测试后删除 Swift 实现；同时 bump `rendererVersion`（`MarkdownRenderContext.swift:54`）。
3. **corpus 的 profile 契约（S）**：新增 Swift 测试 `MarkdownRenderingCorpusContractTests`，读取同一份 `cases.json`，断言 `MarkdownSourceProfileDetector.detect(source) == expectedProfile`，且 `conservativeDefault(for:).allowLooseMathRepair == allowLooseMathRepair`。
4. **policy 契约收窄（S）**：载荷只保留 `allowLooseMathRepair`，以及非空时的 `linkEnrichment`；`JSONEncoder.outputFormatting = [.sortedKeys]`。**不得**加 `.withoutEscapingSlashes`：§0.1 关于 `</head>` 的裁决依赖默认的 `/` 转义，要加一个测试钉住。JS 的 `normalizePolicy` 删掉 `profile/policyVersion/nativeSourceIcons`（最后一个改为常开，见卫生审计 §4.3）。新增共享夹具 `Tools/MarkdownRenderer/test/fixtures/policy-contract.json`：
   - Swift 测试经 `#filePath` 读取它（`WebViewLifecycleTests.swift:360` 已有同样的做法），断言三种 context 的编码结果与夹具逐字节相等；
   - Node 测试断言 `render` 接受夹具里的每个 policy，并按它行事（比如 `allowLooseMathRepair` 决定 `repairedMathCount`）。
5. **科学 profile 规范化的迁移（L，需 hh 决定）**：
   - `LaTeXInlineTextNormalizer`（`\textbf/\emph/\textit` → strong/emphasis）和 `MathProtector.normalizeMathSegment` 改成 mdast 变换。AST 本来就区分 code/link/math 节点，protector 就用不着了。
   - `LaTeXDocumentNormalizer` 改成 parse 之前的行级变换，复用 `scopyLineScan.js`。
   - 方法：先用现在的 Swift 实现，为每条规则生成**合成**夹具的黄金输出（不得使用用户剪贴板里的真实内容）；Swift 测试校验"黄金 = 现实现"；JS 移植必须逐字节复现黄金，才能删 Swift。
   - 完成后 Swift 侧约少 1,726 行。

**不合并三处数学词表**：`MarkdownDetector.swift:73-87` 判断能否渲染，`MarkdownSourceProfileDetector.swift:149-157` 判断 profile，`remarkScopyLooseMathRepair.js:1-18` 决定修什么——回答的是三个不同的问题。前两个必须留在 Swift（决定用不用 WebView、决定缓存键）；合并会把修复词表的演进和预览资格绑死在一起。

**涉及文件**：`MarkdownHTMLRenderer.swift`；删除 `MarkdownTableCodeSpanPipeNormalizer.swift`、`MarkdownATXHeadingNormalizer.swift` 及其测试；`MarkdownHTMLDocumentBuilder.swift`（policy）；`Tools/MarkdownRenderer/src/{render.js,scopyLineScan.js,scopyBackslashMathPreprocessor.js}`；`test/{render.test.js,corpus.test.js}`；新增的 Swift 契约测试；契约 :93、:234、:250-254。

**验证门禁**（Renderer 行全套）：`npm test`、`npm run build`、`npm run verify:assets`；`make build`、`make test-unit`、`make test-strict`；真实 App 的 PNG 目视（用户 stress 夹具与中文表格夹具）；`make docs-validate`。

**回归风险与守护测试**：ATX 移到 JS 后，fence 识别与 Swift 不同（`trim()` 对 `.whitespaces`），在含 `\r` 或 BOM 的行上会有差别。靠步骤 2 移植的测试和 `user_markdown_stress.md` 全夹具断言兜底。

**规模**：步骤 1–4 合计 M；步骤 5 为 L。

**需要 hh 决定**：做不做步骤 5。推荐做，但排在 R4 之后。完成之前，契约 :93 应如实写"科学 profile 的源修复仍在 Swift"。

### R4 文档运行时与基础 CSS 迁入渲染器包，Swift 只拼薄外壳；CSP 收紧；断言结构化（P2，L）

**问题/证据**

- `MarkdownHTMLDocumentBuilder.swift` 的 2,871 行几乎都是别的语言：基础 CSS 77.4 KB（253-2289，插值只有 `:root` 的 9 个变量，383-391）、文档内联 JS 27.6 KB、表格运行时 13.2 KB、任务列表运行时（`MarkdownTaskListRuntime.swift`，199 行，CSS 加 JS）。导出还有约 330 行 JS 字符串。
- 每份文档带着约 115–125 KB 的固定外壳，`MarkdownPreviewCache` 8 MB 的上限大约只放得下 30 余份。
- CSP 为 `script-src 'self' 'unsafe-inline' file:`（8-10），必须放行内联脚本。渲染器的 `rehypeScopyLinkSemantics`、`rehypeScopyNativeSourceIcons`、`rehypeScopyKatex`、`rehypeHighlight` 都在 `rehype-sanitize` **之后**运行（`render.js:79-85`）。它们是受信的构建器，但只要其中一个回归、产出了事件处理属性，`'unsafe-inline'` 就会让它执行。
- JS 写在 Swift 字符串里：没有 lint，没有 Node 单测。`ChatGPTMarkdownRendererTests.swift` 用 182 个 `contains` 钉住 JS 函数名和 CSS 字面量（例如 32-69、111-196）。
- 表格列宽档位的阈值有三份：运行时 JS（40-45）、CSS（2220-2240）、契约（:396-403）。`wrapChatGPTTables`（69）在渲染完成后再走一遍 DOM，生成渲染器本可以直接输出的结构。

**设计**

- `Tools/MarkdownRenderer/src/documentRuntime.js`：收纳现在的文档内联脚本、表格运行时、任务列表 bootstrap，以及导出页侧的准备和 watcher，打进**同一个** IIFE，不新增 JS 资源。对外暴露 `window.ScopyDocument = { boot, probeLayoutHeight, export: { prepare, adjustWideContent, watchLayout } }`。
- `Tools/MarkdownRenderer/src/styles/scopy-document.css`：基础 CSS，含任务列表与脚注样式。由 `scripts/build.mjs` 复制到 `Scopy/Resources/MarkdownPreview/scopy-document.css`；`asset-contract.mjs` 把它写进 manifest（sha256/bytes）；`verify-assets.mjs` 和 App bundle 校验随之覆盖。
- 表格模型前移：新增 rehype 插件 `rehypeScopyTableModel`，放在 KaTeX/highlight 之后，按单元格 textContent 折叠空白后的长度分档，直接输出 `.scopy-chatgpt-table-container > .scopy-chatgpt-table-wrapper > table` 和 `data-col-size`。阈值只在 JS 里有一份，契约表引用它。
- Swift 外壳（约 40 行）：

```html
<!doctype html>
<html data-scopy-render-id="__SCOPY_RENDER_ID__">
<head>
  <meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'none'; base-uri 'none'; form-action 'none';
    object-src 'none'; frame-src 'none'; connect-src 'none'; img-src 'self' data: scopy-source-icon:;
    style-src 'self' 'unsafe-inline' file:; script-src 'self' file:; font-src 'self' data: file:;">
  <link id="scopy-document-stylesheet" rel="stylesheet" href="scopy-document.css">
  <link id="scopy-katex-stylesheet" rel="stylesheet" href="katex.min.css">
  <style>:root { /* 按 layoutScale 生成的 9 个布局变量 */ }</style>
  <script type="application/json" id="scopy-render-input">{"policy":{…},"source":"…"}</script>
  <script defer src="contrib/scopy-unified-renderer.iife.js"></script>
</head>
<body><div id="content-scale-shell"><div id="content" dir="auto"></div></div></body>
</html>
```

  - `style-src` 仍需要 `'unsafe-inline'`：KaTeX 的 HTML 输出有大量内联 `style` 属性，还有 `:root` 那一块。
  - `script-src` 去掉 `'unsafe-inline'`，内联事件处理属性也一并被挡住。JSON 数据块不会执行，不受 `script-src` 约束。
  - JSON 仍用默认 `JSONEncoder`，它会把 `/` 转义成 `\/`，所以 `</script` 不可能出现；现有的替换保留作为第二道防护。
- 就绪判断：`awaitStylesheetReady` 同时等两张样式表，契约 :451 的 "canonical stylesheet" 从此名副其实。
- 导出的 Swift 侧只剩对 `ScopyDocument.export.*` 的一行调用。

**契约修订**（与实现同一提交）：:91-106 的权威实现面（builder 不再拥有 CSS 和运行时；新增 `documentRuntime.js`、`scopy-document.css`、`rehypeScopyTableModel`）；:310 的原子资产集加入基础 CSS；:386-405 改为表格模型由渲染器输出；:451 改为两张样式表；:508-516 的证据测试清单按下文调整。

**测试改造**（与契约 :515 协调）：

- 保留并改为结构断言（解析外壳而不是匹配子串）：`testRendererBuildsOneLocalStandaloneDocument`、`testScriptBreakingSourceIsEncodedAsData`，以及源码直通、缓存键、render ID 的各个测试。
- 断言 JS 文本的测试（32-69、337-358、389-420 等，约 7 个）：删掉，改由两类测试承担：
  - Node 对 `documentRuntime.js` 纯函数的单测；
  - `WebViewLifecycleTests` 里真实加载的行为测试：坏图片 → `imagesReady` 置真并出现终态回退；删掉 `katex.min.css` → 终态失败，原因为 `stylesheet failed`。
- 断言 CSS 字面量的测试（71-82、111-196、213-262、360-368，约 6 个）：改为新的 `MarkdownComputedStyleTests`。复用 `WebViewLifecycleTests.swift:350-419` 的真实 WebKit 夹具（抽到 `ScopyTests/Helpers/LiveMarkdownDocument.swift`），按契约的排版表（:318-331）、引用竖条伪元素（:333）、行内代码与代码卡（:335-337）、表格规则（:384-394）逐项读 `getComputedStyle`。
- 顺序：先加计算样式测试（在旧代码上也要通过）→ 改契约 :515 的清单 → 再删子串断言。
- 一次性迁移证据：对 `user_markdown_stress.md`，断言旧运行时分配的 `data-col-size` 与新插件的输出逐列相等（WebView 测试）。迁移完成后删掉这条对照测试。

**验证门禁**：Renderer 全套；`make test-strict`；`scripts/perf-frontend-profile.sh --include-hover`（契约 :503）；真实 App 预览（80/100/200%）与 PNG 目视；`make docs-validate`。文档体积、WebKit 样式表复用、缓存容量这几项性能收益，没有实测之前不写进 release 文案。

**回归风险**：
- 样式表加载时序：外链 CSS 会阻塞后续脚本执行，defer 脚本要等样式表就绪才执行，需要在实机上确认首帧没有"无样式闪烁"。
- 资产契约扩展：新文件如果漏进 App bundle，会被 verify 拦下，这是预期中的失败。
- 导出 JS 搬家会改变 PDF 和分片路径的时序。

**规模**：L。

**需要 hh 决定**：要不要把"持久宿主页 + 页内重渲染（缩放不再触发导航）"立为后续提案。本项完成后才具备条件，而且要修订契约 :443"每次加载新 render ID"。

### E1 导出：删死判断和重复变量、真彩色进 CI、settle 改推送、显示阶段并可取消（P2，M）

**问题/证据**

1. **死的 rich-v2 判断**。`HistoryItemMarkdownExportController.pngquantOptions(settings:renderedHTML:)` 在**还没渲染的文档外壳**里找 `data-scopy-version="2"`（170）。外壳里没有这个字面量（builder 全文没有 `scopy-version`）；源码经过 JSON 编码后引号变成 `\"`，也不可能命中。所以这个判断恒为假。真正起作用的判断在导出页就绪之后查询 DOM（`MarkdownExportService.swift:1075-1080`，注释里写明了原因）。唯一测它的 `testRichSurfaceExportsBypassPaletteReduction`（`HistoryItemMarkdownExportControllerTests.swift:144-161`）用的是生产永远不会产生的合成 HTML。真实的 DOM 判断只有 UI 测试覆盖，而 UI 测试不在 CI 里。
2. **漂移种子（K12）**。`injectExportStyles` 在 `:root` 里重新定义了 7 个布局变量（960-973），与 builder 386-411 的定义逐字相同，而且因为排在后面而生效。今天两者等价；以后改 builder 的公式时，导出不会跟着变。
3. **settle 轮询**。`awaitLayoutSettled`（2389-2436）每 8 ms 做一次 `evaluateJavaScript` + JSON 往返，最长等 12 s（1768），最坏约 1,500 次 IPC；`waitForAnimationFrames`（2438-2449）同理。`callAsyncJavaScript` 已被代码注释否决（1487-1488：UI 测试下间歇返回 nil）。
4. **阶段与取消**。`ExportStage` 有 11 个阶段，只写日志（59-71、797-801）；UI 只有一个不确定进度加 `.disabled(model.isExporting)`（`HistoryItemTextPreviewView.swift:576、614、618`）。取消链路其实已经端到端打通：任务取消 → `MarkdownExportCancellationRelay` → `CancellationHandle.cancel` → `ExportCoordinator.cancel`（`HistoryItemMarkdownExportController.swift:118-135、181-207`；`MarkdownExportService.swift:26-38、868-870`），只差一个按钮。
5. **重复实现**。导出写剪贴板时的 PNG 规范化（245-318）与 `ClipboardMonitor` 里的（594-750）同构。导出结果总是 PNG（pngquant 或 ImageIO 编码），所以导出侧的栅格化分支走不到。

**设计**

1. 删除 170 行的判断和 `renderedHTML` 参数，删除那条测试；新增 CI 能看到的真彩色单测（见下）。
2. `injectExportStyles` 只保留导出专属的规则：白底、边距、`print-color-adjust`、隐藏滚动条、钉死 `#content` 宽度；删掉对 `:root` 变量的重定义。
3. 推送：导出 WebView 注册一个 `scopyExportLayout` 消息处理器。页侧 watcher（现在的 `layoutWatcherJS`）在三种情况下 `postMessage`：`stableFrames` 第一次达到阈值、`renderFailed` 变化、`phase` 令牌改变。

```swift
/// phase 由 Swift 递增，随 ScopyDocument.export.watchLayout(phase) 传进页面；较早 phase 的迟到消息丢弃。
private func awaitLayoutSettled(phase: Int, requireRenderReady: Bool,
                                timeout: Duration) async throws -> (LayoutSample, Bool) {
    // 1) 等本 phase 的"已稳定"消息；
    // 2) 截止前没等到（rAF 被节流或窗口被遮挡）→ 回退为一次 readLayoutSample()，
    //    沿用现有"帧停滞 0.3 s 且高度稳定 0.45 s"的时间兜底。
}
```

4. 进度：`exportToPNGClipboard(..., onProgress: @MainActor (ExportProgress) -> Void)`，`ExportProgress` 为 `rendering | capturing(tile: Int, of: Int) | compressing | writing`，由内部 11 个阶段映射而来（内部枚举不动）。UI 用文案替换不确定进度，旁边加一个取消按钮，调用现有的 `model.cancelExportTasks()`。
5. 用 C3 抽出来的 `PasteboardWriter.writePNG(_:)` 供两处共用，导出侧删掉走不到的栅格化。
6. 拆分（R4 把 JS 搬走之后再做，免得搬两次）：

| 新文件 | 内容 | 约行数 |
| --- | --- | ---: |
| `MarkdownExportService.swift` | 门面、错误、阶段、剪贴板提交 | 250 |
| `ExportConcurrencyGate.swift` | 并发闸 | 60 |
| `ExportBitmapCanvas.swift` | 445-733 加 2507-2583 的编码；v0.81.0 刚重建，只移动不改 | 370 |
| `ExportWebViewHost.swift` | WebView 配置、宿主面板、导航、JS 桥 | 250 |
| `ExportLayoutPreparation.swift` | Swift 侧的准备、缩放、settle | 300 |
| `ExportCaptureStrategies.swift` | PDF 栅格化、单次快照、分片 | 450 |
| `ExportDiagnostics.swift` | `SCOPY_EXPORT_TABLE_METRICS_PATH` 等 UI 测试诊断，去留随卫生审计 D1 | 230 |

**验证门禁**：`make build`、`make test-unit`、`make test-strict`。导出属于渲染链，要做真实 App 的 PNG 目视（普通夹具加 rich 夹具，确认 rich 输出是 RGB/RGBA）。按 `development-guide.md:100` 的要求，本机跑一次 `ExportMarkdownPNGUITests.testAutoExportGlobalScalePDFDoesNotLeaveBlankRight`；被环境拦住就如实记录。UI 改动附截图。

**回归风险与守护测试**：

- `testRichSurfaceExportKeepsTrueColorWithPaletteEnabled`（新增，宿主单测）：经 `#filePath` 读取 `ScopyUITests/Fixtures/chatgpt_rich_surfaces.md` 并渲染，用 `MarkdownExportService.exportToPNGData(pngquantOptions: 16 色)` 导出，断言 `stats.pngquantApplied == false` 且 IHDR 颜色类型为 2 或 6。
- `testOrdinaryMarkdownExportAppliesPalette`：普通夹具断言 `pngquantApplied == true`。依赖内置的 pngquant；v0.81.0 的单测已经在跑内置二进制的往返。
- `testExportAndPreviewResolveIdenticalLayoutVariables`：同一文档分别以预览模式和导出模式（注入导出样式）载入真实 WebView，断言 7 个变量的计算值两边相等。
- `testLateLayoutMessageFromPreviousPhaseIsIgnored`；`testOccludedExportFallsBackToTimeBasedSettle`（宿主面板 `orderOut` 之后，导出仍能完成）。
- `MarkdownExportServiceTests` 现有 9 个用例原样通过。
- 风险：遮挡或低帧率时要靠兜底；PDF 和分片路径的时序会变，靠在实机上跑一遍 UI 导出套件兜底。

**规模**：M（步骤 1、2、5 各为 S，步骤 3、4 各为 M；拆分另算，排在 R4 之后）。

**需要 hh 决定**：阶段文案和取消按钮的位置与样式。推荐沿用现有 `PreviewControls` 右上角的控件组。

### W1 WebKit 宿主统一：删掉生产走不到的一次性 WebView 和死探针，配置与拦截规则收成一个工厂（P2，S）

**问题/证据**

- 所谓"两套 WebView 生命周期"，在 HEAD 已经不是 hover 与 pinned 两套：两者都用 `MarkdownPreviewWebViewController` 加 `ReusableMarkdownPreviewWebView` 租约（`MarkdownPreviewWebView.swift:609-1087`）。固定时，列表把自己的 controller 连同 WebView 交给固定窗口，自己再换一个新的（`HistoryListView.swift:416-418`）。这正是契约和 architecture.md 描述的形状，不需要再"共享"什么。
- 真正多余的是一次性的 `MarkdownPreviewWebView`（349-607，约 260 行，含 Coordinator 和网络拦截规则编译）。它只在 `markdownWebViewController == nil && model.isMarkdown` 时才会被用到（`HistoryItemTextPreviewView.swift:112-135`）。可是 hover 行持有的是非可选的 controller（`HistoryItemView.swift:40`），固定窗口也只在 `isMarkdown` 时才传 controller（`HistoryListView.swift:416`），所以生产代码走不到它。它只被 `WebViewLifecycleTests.testOneShotDeferredMetricsCannotCrossRenderOrCallbackBoundary`（138）覆盖；controller 的同类不变量已经由同文件第 90 行的测试覆盖。
- `window.__scopyRenderMath` 现在只是"再报一次高度"的别名（builder 2358-2362）。预览侧有两处先探测再调用（`MarkdownPreviewWebView.swift:531-534、1024-1027`），导出侧一处（`MarkdownExportService.swift:1506`）。名字误导，而且紧接着的 `__scopyReportHeight` 调用做的是同一件事。
- `WKWebViewConfiguration` 在三处逐行重复（`MarkdownPreviewWebView.swift:370-381、634-655`；`MarkdownExportService.swift:898-910`），网络拦截规则有两套编译器（`MarkdownPreviewWebView.swift:430-464`；`MarkdownExportService.swift:742-780`）。
  - 预览侧第一次编译时，规则是编译完才经 `DispatchQueue.main.async` 挂到等待中的 controller 上（453-462），第一个预览可能在规则挂上之前就开始加载。CSP 仍会拦 http(s)，所以这是纵深防御上的缺口，不是漏洞。
  - 导出侧在 `--uitesting` 下不装规则（902-906）。

**设计**

- 删除 `MarkdownPreviewWebView`（representable 加 Coordinator）和测试 138。`HistoryItemTextPreviewView` 的 WebView 分支改为 `if model.isMarkdown, let html, let controller = markdownWebViewController`。
- 删除 `__scopyRenderMath`（定义和三处调用）。
- 新增 `MarkdownWebKitEnvironment`（@MainActor），预览 controller 与导出共用：
  - `static func makeConfiguration() -> WKWebViewConfiguration`：scheme handler、非持久数据存储、禁止 JS 开窗、`WKUserContentController`、已编译好的规则；
  - `static func prepareRules() async`：App 启动时在 AppDelegate 里调一次。
- 导出在 UI 测试下也装规则。那些测试依赖的是命名剪贴板和环境变量，不依赖网络。

**验证门禁**：`make build`、`make test-unit`、`make test-strict`；在实机上 hover 一次，确认第一个 hover 不白屏。

**回归风险与守护测试**：`WebViewLifecycleTests` 其余 11 个用例原样通过；新增 `testPreviewAndExportConfigurationsShareRulesAndSchemeHandler`，断言两处配置都注册了 `scopy-source-icon` 和同一个规则列表标识。风险极低。

**规模**：S。

## 3. 可读性与命名

只列"名字在误导读者"的情况，改名成本按 `rg` 统计。

| 名称 | 为什么误导 | 引用数 | 建议 |
| --- | --- | --- | --- |
| `MarkdownHTMLRenderer` | 它并不渲染 HTML：它预处理源码并把源码嵌进外壳，HTML 是 JS 在 WebView 里生成的。名字助长了"Swift 侧产出共享 parse 结果"的误解（K1） | 29 处/9 个文件，文档里 7 处 | R3 完成后它只剩一个转发，届时并入 `MarkdownHTMLDocumentBuilder.document(source:context:)`，同时改 AGENTS.md 与契约里的链名；不为改名单独提交 |
| `MarkdownPreviewRenderer.swift`（文件） | 里面只有 `MarkdownRenderOutput`/`MarkdownRenderDiagnostics` 两个 struct | 0 | 随 R1 删除 |
| `MarkdownSyntaxProtector.protectForLooseMathRepair` | 它服务的是 `LaTeXDocumentNormalizer`，与控制 JS 插件的 policy 位 `allowLooseMathRepair` 毫无关系 | 4 | 改为 `protectForLaTeXDocumentNormalization`（R1 顺手） |
| `MarkdownRenderCacheKey.make(contentHash:)` | 传进来的是条目修订键（含条目 ID）或文件预览键，不是内容哈希 | 10 | R2 改签名 |
| `lastChangeCount` | 语义是"最后一个处理完的 changeCount" | 14/1 个文件 | 改为 `handledChangeCount`（C1） |
| `ScopyThresholds.ingestHashOffloadBytes` | 实际决定内容是否走持久信封路径（`ClipboardMonitor.swift:828`），注释却说是"把哈希移出主线程"（`ScopyThresholds.swift:4-5`） | 2 | 改为 `ingestDurableEnvelopeBytes` |
| `window.__scopyRenderMath` | 已经不渲染数学，只是再报一次高度 | 8 | 删除（W1） |
| `ClipboardMonitor` | 同时是剪贴板写入者（6 个 `copyToClipboard`） | — | C3 拆出 `PasteboardWriter` |

注释与代码不一致：

- `MathProtector.swift:14-23` 的文档注释描述的是"Markdown→HTML 之后，把占位符 HTML 转义还原，避免破坏 KaTeX auto-render"——那是旧的 markdown-it 流程。HEAD 在渲染之前就用 `escape: { $0 }` 还原（`MarkdownHTMLRenderer.swift:32-36`），auto-render 也早已不存在（`ChatGPTMarkdownRendererTests.swift:28` 断言它不在）。注释应改为现在的用途：保护数学段不被 `LaTeXInlineTextNormalizer` 改写，并规范化段内内容。
- `ClipboardMonitor.swift:95`（"符合 v0.md 第1节"）、2336（"v0.md 3.2"）以及多处 `v0.10.x` 注释，引用的是已归档的 v0 文档和历史版本。C3 移动时删掉这些版本考古，只保留"为什么"。
- `ClipboardMonitor.swift:1722` 注释说"TIFF 转 PNG 延迟到后台"，但 2714-2718、1890-1905 恰好在主线程做转换。C2 改完代码后，这条注释才成真。
- 混合语言：`ClipboardMonitor.swift` 的 138 行注释中有 54 行中文，其余四个大文件全是英文。C3 移动时统一为英文，不单独提交。

契约措辞（与代码术语对齐，按 §1.6 编号）：

- K1 的新措辞见 §1.6。
- :424 在 W1 之后改为单数。
- :443 限定为 "each preview WebView load"。
- :309 改为 "returned in render metadata and asserted by renderer tests; the app does not consume them"。
- :370 改为"按 URL 排序；生产侧候选上限 13"。
- :5-20 的本机路径移到"证据附录"。
- K11：AGENTS.md 的 Renderer 行改为"见契约 Required Verification"，契约补一条 PNG 目视。
- K7 由 hh 决定后，同步统一 product-spec、development-guide 与硬化计划不变式 4。

## 4. 明确不做

- **不按 Concealed/Transient/1Password 标记跳过采集**，不改 ⏎（复制并关闭），不做回贴服务或纯文本粘贴。这些都是已有裁决。
- **不做原文/规范文本分离，也不按 representation 去重**：已冻结，等 data epoch 决定。C1–C3 都不碰哈希公式或 `plain_text` 的语义。
- **R3 步骤 4 的 `.sortedKeys` 只是排序**，不改 `/` 的转义；`</head>` 的裁决依赖默认转义，必须保持，并用测试钉住。
- **不做锁屏/睡眠门控**：系统睡眠时 timer 不触发，醒来后一个 tick 就补上；锁屏时后台进程仍可能写剪贴板，按"保留所有内容"就应该继续采集；能耗问题由 `tolerance` 和系统合并唤醒解决。
- **不加用户可配置的采集大小上限**：与"保留所有内容"冲突，而且读取发生在得知大小之前。只保留 C2 的主线程 HTML 导入预算，待 hh 决定。
- **不删 legacy spool 迁移**：卫生审计 §2.3 的结论，属于"最低支持升级版本"的产品决定。
- **不用 `callAsyncJavaScript` 做导出推送**：代码注释记录了它在 UI 测试下间歇返回 nil（`MarkdownExportService.swift:1487-1488`）。
- **不做持久宿主页、页内缩放重渲染**：要先修订契约 :443，且以 R4 为前提（R4 里列为 hh 决定）。
- **不合并三处数学词表**（理由见 R3）。
- **不重做 pngquant 和 `ExportBitmapCanvas`**：v0.81.0 刚重建；E1 的拆分对它只移动、不改动。
- **不做 WebView 的懒创建与空闲释放**：没有测量依据，而且 WebContent 进程其实在第一次导航时才启动，未必"从启动常驻"。
- **不做暗色主题**：契约要求先有 hydrated 捕获或实测。
- **不提滚动性能**：已到天花板。
- **不做"另存为 PNG"**：这是新产品能力，不属于本面的结构评审。

## 5. 实施顺序与依赖

1. **第一批（互不依赖，都是 S）**：R1、W1、E1 步骤 1–2（加真彩色测试）、C1 步骤 1–2、R2 步骤 1（指纹改存储属性）。K7 等 hh 定了再改文档；K1、K4、K5、K6、K8、K9 的措辞修订随对应代码提交一起改。
2. **第二批**：R3 步骤 1–4（依赖 R1，因为 R1 把两个 normalizer 标成"待删"）；C2（依赖 C1 的 `CheckOutcome`，读取会话要用 `.deferred`）；E1 步骤 4（进度与取消按钮，不依赖 R4）。
3. **第三批**：C3（纯移动拆分 → 管线 → 回放 → TIFF；`PasteboardWriter` 抽出后 E1 步骤 5 才能做）；R2 步骤 2–3。
4. **第四批**：R4（依赖 R3：运行时只接收原始源码和收窄后的 policy）；然后 E1 步骤 3、6（推送与拆分，都依赖 R4 把导出 JS 搬进运行时）；如果 hh 批准，最后做 R3 步骤 5（科学 profile 迁移，依赖 R4 的 `scopyLineScan.js` 与运行时结构）。

每一步都单独提交，门禁见各项。凡是触及渲染链的提交（R1–R4、E1、W1），都做一次真实 App 的 PNG 目视，并在提交信息里如实写明哪些门禁跑了、哪些没跑、哪些被环境拦住。

需要 hh 决定的事项汇总：

1. C1：是否启用突发轮询（设置项语义变为"空闲间隔"）。
2. C2：是否要 HTML 导入预算（>4 MiB 且有 `.string` 时跳过 WebKit 导入）。
3. C3：是否接受监控器一侧并行度从 3 降到 1。
4. R3 步骤 5：科学 profile 的 1,726 行 Swift 规范化是否迁到 JS。
5. R4：R4 完成后，是否另立"持久宿主页"提案。
6. E1：阶段文案和取消按钮的位置与样式。
7. K7：产品规格里"禁止隐藏预测量"与 prewarm 实现，以哪边为准。
