---
doc_type: proposal
status: draft
owner: hh
created: 2026-09-24
audience: maintainer decision + implementing agent
---

# 可维护性、命名与文档准确性评审（2026-09-24）

基线：`407f7db`（v0.81.0）。工作区里 `Scopy/FloatingPanel.swift`、`Scopy/Views/ContentView.swift`、`Scopy/Views/HistoryListView.swift` 的 `SCOPY_EXP_OPAQUE_ROWS` 改动未提交；本文涉及这三个文件时一律用 `git show HEAD:<path>` 核对。每条结论都在 HEAD 上用 `rg`/`sed`/`git` 重新核实，行号以 `407f7db` 为准。本文不给性能设计；巨型文件怎么拆归各面评审，本文只定拆分约定。

## 0. 结论

| 编号 | 改进 | 优先级 | 规模 | 预期收益 | 主要风险 |
| --- | --- | --- | --- | --- | --- |
| M1 | 按 §1 表修正 canonical 文档里 35 条与 HEAD 不符的陈述（其中 12 条是事实错误） | P0 | S | 代理与维护者不再按错误契约"修回"代码（如把分页改回 500） | 无；纯文档 |
| M2 | 删除 82 个已跟踪的兼容符号链接（`doc/profiles` 49、`doc/reviews` 根目录 21、`doc/specs` 6、`doc/implementation` 5、`DEPLOYMENT.md` 1）和 `doc/README.md` 的 Compatibility 节 | P1 | S | 兑现硬约束 1 与 development-guide:284 的既有规则；消除两份 canonical 文档的直接矛盾 | 外部书签失效（按硬约束 1 接受）；已核实 0 条仓内 Markdown 链接、0 处脚本经过这些链接 |
| M3 | AGENTS.md / CLAUDE.md 按 §6 修订：性能门禁两行改成实际可执行的写法；访问控制改为可检查的规则；补全源码目录；给出技能路径；加入 D7 一句 | P1 | S | 门禁与实践一致；"explicit access control" 不再是被 185 处声明违反的空规则 | 改门禁措辞需要 hh 认可 |
| M4 | 把 §4 的代码结构约定放进 development-guide，并在 `make test-tooling` 加一个"`Package.swift` 与 `project.yml` 的 exclude 恰好划分 `Scopy/` 顶层目录"的自测 | P1 | S | §8.3 那类双模块编译缺陷再次出现时直接失败；拆大文件有统一口径 | 自测本身要维护（约 40 行 Python） |
| M5 | 术语表写进 development-guide；只做 6 处真正误导的改名（§2.3） | P2 | S | 读者不再把 `isPrefilter`、`SearchPlanner`、`MarkdownPreviewRenderer.swift`、"pinned" 预览、`ClipboardServiceProtocol` 读错 | 改名触及 UI 测试标识符（仅 pinned 一项） |
| M6 | 代码注释统一英文；删除 98 行版本号流水账注释（22 个文件）与 18 处 `v0.md` 引用；修正 §3.3 列出的与代码不符的注释 | P2 | M | 注释只描述当前代码；中文/英文混杂的 45 个文件收敛 | 除 C8 删除一条建表语句外都是纯注释改动；工作量在机械替换 |
| M7 | 文档元数据收敛：删除无消费者、已漂移的 `last_reviewed` / `related_versions` / `owner` / `canonical` 字段（或改为脚本校验，见 D8） | P2 | S | 14 个带 `last_reviewed` 的文档里 7 个已在该日期之后被修改，字段在误导 | 需要 hh 选择删除还是校验 |
| M8 | 门户与提案目录清理：6 个已实施或已过时的 proposal 移出 "Current Contents"；`doc/perf/README.md` 删掉手写的当前版本事实 | P2 | S | 门户只列活文档 | 无 |
| M9 | Makefile 卫生：`help` 补齐 16 个漏列目标、删 `clean` 对已跟踪 `Scopy.xcodeproj` 的删除、修 `.PHONY`、删不存在目录、移正错位注释 | P2 | S | `make help` 成为可信目录 | `clean` 语义变化 |
| M10 | 日志类目收敛：3 个绕过 `ScopyLog` 的 `Logger` 与 1 处 `NSLog` 归入类目；删除零调用的 `ScopyLog.persistence` | P2 | S | development-guide 的日志规则与代码一致 | 无 |

总体判断：

- 文档的问题不是"缺"，而是"曾经对、现在错"。development-guide 列出的 70 多个类型/函数在 HEAD 全部存在；错的是数值与因果（分页 500→100、`AppState` 何时选服务、`SearchPlanner` 是否参与路由、A/B 默认轴），这类错误对执行型代理危害最大，因为代理把 canonical 文档当成要恢复的契约。
- 仓库自己的规则彼此冲突的地方有三处：兼容符号链接（development-guide:284 与 maintainer-guide:65 说不保留，doc/README.md:33-36 说保留，磁盘上保留了 82 个）；"active docs" 的目录集合（development-guide:283 三个，maintainer-guide:65 六个）；AGENTS.md 性能门禁与实际发版记录。
- 校验脚本只查链接可达与发布元数据一致（§1.2），不查任何事实；这决定了修文档必须靠本表逐句替换，不能指望 `make docs-validate` 兜底。
- 命名总体健康：158 个产品文件里 152 个文件名与主类型一致，`Policy`/`Snapshot`/`Token`/`Outcome` 用法一致。真正误导的只有 6 处（另有 1 个文件名），改名总成本约 140 处引用，其中 61 处是删除一个 typealias 的机械替换。
- 语言是最大的一致性债务：464 行中文注释分布在 45 个文件，UI 字符串中文集中在 14 个文件的 142 行。代码注释可以直接定政策；UI 语言属于本地化 P0 的产品决定，本文只列选项（§3.2）。
- 卫生审计 D1-D7 彼此耦合，尤其 D1 依赖 D3：只要 D3 退役 Release 配置下的 A/B 装置，D1 就退化为 `#if DEBUG`，不需要新编译条件（§5.1）。

## 0.1 终审修正（2026-09-24，主线程 + Codex 第二方复核）

以下裁定优先于本文正文；证据见 [review-roadmap-2026-09-24.md](./review-roadmap-2026-09-24.md) §9。

- **M2 同批修消费者**：`scripts/docs/validate-docs.sh:42` 仍枚举 `DEPLOYMENT.md`，`project.yml:54` 的注释引用它；删除 82 个符号链接时一并更新，不留替代路径。
- **M4 由硬规则改为指导**：不设"超过阈值必须拆""禁止跨文件 extension"的绝对规则（与 F14、B3 的逐步提取冲突）；保留模块归属自测、`public` 只用于 ScopyKit API、注释英文、日志只经 `ScopyLog`。
- **M5 改名只做真正误导语义的 R1（`isPrefilter`）、R2（`SearchPlanner`）、R4（JS `currentRenderGeneration`）、R5（`StoredItem` typealias）**；R6（`ClipboardService` → `ClipboardBackend`）与 B3-D6 同批；R3 / D13（pin → detached）本轮不做。
- **M6 的 C8（删除 `schema_version` 建表）是功能改动**，单独提交并跑 build + unit；注释英文化按模块一次性完成，不作为架构质量门槛。
- **D1 不整体 `#if DEBUG`**：mock 与 harness 视图 DEBUG 化并移到 app 侧，但保留 `--uitesting` 自动导出（`AppDelegate.swift:93, 353`）这条 Release 真实 PNG 验证入口。
- **D4 先确认独有覆盖**：删除已被 ScopyBench 覆盖的 12 个方法；其余 15 个中仍需要的清理/摄取数字先移植为 ScopyBench 场景再删。
- **D3 折叠 flag 后，工具链按消费者驱动删除**：`perf-warm-scroll-ab.sh`、`summarize-warm-scroll-ab.py`、`source-manifest.py`、`ScopyWarmProfile` scheme 若确认只服务 flag A/B 则删；`perf-frontend-profile` 改为单变体跨提交比较。
- **D11 不列为 P0**：本地化是独立产品决定；Codex 建议 P2 用 `xcstrings` 跟随系统（先英文与简体中文）。
- 修正一句表述：`make test-strict` 并非"从不失败"（编译与测试失败会失败），准确说法是"并发诊断没有升级为失败"。

## 1. 文档准确性审计

### 1.1 逐句核对表

"类别"：错 = 与代码/命令输出矛盾；漏 = 陈述正确但遗漏了会误导读者的部分；旧 = 过时、自相矛盾或无法执行。"建议改文"是可直接替换的英文句子（canonical 文档为英文）。

| # | 文档:行 | 现文（摘要） | 事实（HEAD） | 类别 | 建议改文 |
| --- | --- | --- | --- | --- | --- |
| A1 | product-spec.md:100 | "load-more pages fetch 500 unpinned items" | `HistoryViewModel.swift:323` `static let loadMorePageSize = 100`；自 `dae61b1`（v0.77.0 "shrink page loads"）起 | 错 | `Pinned items are independent of recent pagination; the first recent unpinned page is 50 items and each load-more page fetches 100 unpinned items, applied to the list in 20-row chunks` |
| A2 | development-guide.md:77 | "the initial recent page is 50 and load-more pages are 500" | 同 A1；`loadMore()` 在 `:928-1033` | 错 | `…with the current unpinned count as offset; the initial recent page is 50 items and load-more pages are 100 (HistoryViewModel.initialPageSize / loadMorePageSize).` |
| A3 | development-guide.md:155 | "applies the page in `loadMoreApplyChunkRows` (20) row chunks one display frame apart" | `HistoryViewModel.swift:1021` 块间 `Task.sleep(nanoseconds: 20_000_000)`；`:924` 注释又写 "per run-loop turn"，两处都不准 | 旧 | `…applies the page in loadMoreApplyChunkRows (20) row chunks separated by a 20 ms sleep, so no single List update spans several frames.` |
| A4 | development-guide.md:59 | "`AppState.start()` chooses the service implementation, starts it, subscribes…" | 服务在 `AppState.init(service:)` 选定（`AppState.swift:149-173`，`ClipboardServiceFactory.create`）；`start()`（`:178-198`）只负责 start、`startEventListener()`、`refreshSettings`、`loadRecentApps`、`load` | 错 | `AppState selects the service implementation in its initializer (ClipboardServiceFactory; the mock only for --uitesting, or USE_MOCK_SERVICE=1 in Debug). AppState.start() starts it, subscribes to eventStream, applies settings, and triggers the initial loads.` |
| A5 | development-guide.md:80（同义句 :235） | "Exact search planning and execution must share `SearchPlanner.normalizedExactQuery(_:)` so whitespace trimming affects both coverage decisions and matching" | `SearchPlanner.plan` 只写入 `perf?.addReason`（`SearchEngineImpl.swift:1928-1930`），路由是 `switch request.mode`（`:1932-1941`）；recent-only 判定在 `searchExact`（`:1955-1961`）；另一个共享者是 `SearchMatchContextBuilder.swift:378` | 错 | `Exact search execution (SearchEngineImpl.searchExact) and match-evidence generation (SearchMatchContextBuilder) must share SearchPlanner.normalizedExactQuery(_:), so trimming affects the recent-only cutoff, matching, and evidence identically. SearchPlanner.plan is diagnostic only; it does not route queries.` |
| A6 | development-guide.md:83 | "Its `isPrefilter` predicate describes staged coverage for match-context generation" | `SearchCoverage.swift:9-11` `isPrefilter` = `self != .complete`，对 `.stagedRefine`、`.incomplete`、`.recentOnly` 都为真；调用点 `SearchMatchContextBuilder.swift:399,582,631` | 错 | `SearchCoverage.isPrefilter is true for every non-complete coverage (stagedRefine, incomplete, recentOnly); match-evidence generation uses it to add FTS phrase evidence.`（改名见 §2.3 R1） |
| A7 | development-guide.md:210 | "The default `passive-row` axis… Require at least two repeats" | `scripts/perf-warm-scroll-ab.sh:22` `AXIS="all"`，`:39` "Default: --axis all (formal shared-build 20-run evidence)"；`:147-148` 正式证据要求 `--repeats >= 5` 且 `--commands 1440`；`--repeats >= 2` 只是诊断下限 | 错 | `scripts/perf-warm-scroll-ab.sh runs both axes by default (--axis all: formal evidence, --repeats >= 5, --commands 1440); --axis passive-row or --axis markdown-menu-cache is a diagnostic single-axis run that still requires --repeats >= 2 for AB/BA order validation.`（若 D3 退役该脚本，整句删除） |
| A8 | development-guide.md:284 与 doc/README.md:33-36 | 前者："not compatibility entrypoints… Remove obsolete active links and paths instead of adding redirects, aliases"；后者："remain only as compatibility links for old references" | 82 个 git 符号链接（mode `120000`）：`doc/profiles/` 49、`doc/reviews/*.md`（根目录）21、`doc/specs/` 6、`doc/implementation/` 5、`DEPLOYMENT.md -> doc/current/release-runbook.md`；非归档文档中经过它们的 Markdown 链接 0 条；`scripts`/`Makefile`/`.github`/`Tools` 引用 0 处 | 错（互相矛盾） | 执行 M2 后：development-guide.md:284 改为 `Legacy doc directories (doc/implementation, doc/profiles, doc/specs) and root aliases were removed; do not recreate redirects or symlinks.`；doc/README.md 删除 "Compatibility" 整节 |
| A9 | development-guide.md:287 | "Every source file belongs to exactly one module. `Package.swift` and `project.yml` exclude the same directories from opposite sides" | ScopyKit 与 app 之间成立（`Package.swift:18-31` ↔ `project.yml:75-85`）；但 app 侧源码按"独立测试 bundle"设计同时编进 `ScopyTests`（`project.yml:168-184`）与 `ScopyTSanTests`（`:226-243`）；且三个 target 都排除了不存在的 `Models/**`、`Protocols/**`（`:79-80,180-181,239-240`，这两个目录在 `Scopy/Domain/` 下） | 错 | `Every ScopyKit source compiles only into ScopyKit. Package.swift (ScopyKit excludes) and project.yml (app and test-bundle excludes) must partition the top-level entries of Scopy/; make test-tooling checks this. App-side sources are also compiled directly into ScopyTests and ScopyTSanTests by design (no TEST_HOST).` |
| A10 | development-guide.md:293 | "Use the subsystem-specific `ScopyLog` categories (`app`, `monitor`, `storage`, `persistence`, `search`, `ui`, and `hotkey`)" | `ScopyLog.persistence`（`ScopyLogger.swift:10`）零调用；绕过类目的 `Logger`：`PngquantService.swift:6`（"pngquant"）、`MarkdownExportService.swift:11`（"export"）、`LinkEnrichmentStore.swift:23`（subsystem 硬编码 `"com.scopy.app"`）；`ScrollCursorSetCoalescer.swift:45` 用 `NSLog` | 错 | M10 之后：`Log only through ScopyLog (app, monitor, storage, search, ui, hotkey, export); do not create ad hoc Logger instances or call print/NSLog in production code.` |
| A11 | development-guide.md:29-32、38-53 | 分层表与目录表 | 分层表漏 `Scopy/Design`、`Scopy/FloatingPanel.swift`（app），`Scopy/Utilities`、`Scopy/Extensions`、`Scopy/Runtime`（ScopyKit），`Tools/MarkdownRenderer`（Node 渲染器）；目录表 `Scopy/Views` 一行没说 `Views/History` 里有整条 Markdown 渲染链（`MarkdownHTMLRenderer`、2,871 行的 `MarkdownHTMLDocumentBuilder`、`MarkdownPreviewWebView`、`MathProtector` 等约 20 个文件），读者会去 `Services/Export` 找 | 漏 | 目录表 `Scopy/Views` 行改为 `Main panel, header, history rows, settings pages, UI-test harnesses, and the Markdown preview pipeline (Views/History/Markdown*, MathProtector, LaTeX*)`；补行：`Scopy/Design` / `Scopy/Presentation` / `Scopy/Utilities` / `ScopyUISupport` (`ScrollPerformanceProfile`, `ThumbnailCache`, `IconService`; app and tests only) / `ScopyTestHost` (TSan host app) / `Tools/MarkdownRenderer` (Node renderer whose bundle is checked into `Scopy/Resources/MarkdownPreview`) / `Tools/ScopyBench` |
| A12 | development-guide.md:137 | 小节号 "4.5" 紧接 "4.2"；该节 23 条 | 无 4.3/4.4；第 18 条（采集）、19（搜索索引磁盘缓存）、20（hover 图片缓存）、22（固定预览）、23（`FloatingPanel` 关闭策略）不属于"List Interaction Coordination" | 旧 | 改为 `### 4.3 List Interaction Coordination`；第 18 条移入 §2 Clipboard Ingest，19 移入 §3，20/22 移入 §4 Preview And Export，23 新建 `### 4.4 Panel Window` |
| A13 | architecture.md:18-22 | "Current System Shape" 五条 | 漏：Sparkle 2.9.6（`project.yml:61-63`，`AppDelegate.swift:44` 创建 updater）；Node 渲染器（`Tools/MarkdownRenderer` → `Scopy/Resources/MarkdownPreview`）；`ScopyUISupport` 实际 2,798 行中 2,232 行是 `ScrollPerformanceProfile`，只被 app 与测试 import（21 处） | 漏 | 追加：`Tools/MarkdownRenderer is the Node (remark/rehype/KaTeX) renderer; its bundle and asset manifest are checked into Scopy/Resources/MarkdownPreview and loaded by WKWebView.`；`Sparkle provides update checks and installation.`；ScopyUISupport 行改为 `ScopyUISupport holds the scroll profiler, ThumbnailCache, IconService, and WeakScriptMessageHandler; only the app target and tests import it.` |
| A14 | architecture.md:29-31 | 三行连用 "publishes"：写 spool、发事件、放置文件 | 代码里 `publish*` 函数只指事件/状态发布（`ClipboardService.swift:1936,1952,2373,2795`、`ClipboardMonitor.swift:1169`）；文件放置只在注释里叫 publish（`StorageService.swift:513,795,2205`） | 旧（歧义） | :29 `…writes durable external captures to an Application Support-owned ingest spool…`；:31 `…retains the source, places the payload at a unique managed path, and commits…`；:30 保留 "publishes"（事件） |
| A15 | architecture.md:31 | "the schema-v8 `ingest_receipts` row" | `SQLiteMigrations.swift:4` `currentUserVersion = 9`；receipts 在 v8 引入（`:34-35`） | 旧 | `…plus the ingest_receipts row (introduced in schema user_version 8; current 9)…` |
| A16 | product-spec.md:107-124 | 设置表 13 行 | 与 `SettingsDTO.swift:44-70` 逐项一致；但漏两项已上线设置：`siteIconsEnabled` 默认 `true`（Appearance，`AppearanceSettingsPage.swift:82`）、`linkEnrichmentEnabled` 默认 `false`（`:87`），正文 :76 描述了它们 | 漏 | 追加两行：`Appearance \| Website icons \| true \| Fetch origin-only favicons and cache them for offline preview/export` 与 `Appearance \| Link enrichment \| false \| Fetch Open Graph titles/images for bare links in assistant content and freeze them locally` |
| A17 | maintainer-guide.md:14-23 | canonical 列表 | 漏 `high-leverage-change-guide.md`；:23 把 architecture.md 称作 "Architecture/optimization guidance"，但优化补充已移入归档（architecture.md:14） | 漏 | 补 `- Work selection: [high-leverage-change-guide.md](./high-leverage-change-guide.md)`；:23 改为 `Architecture boundaries and invariants: [architecture.md](./architecture.md)` |
| A18 | doc/current/README.md:11-17 | 当前文档门户 | 同样漏 `high-leverage-change-guide.md`；`validate-docs.sh:15-33` 的必需文件表也不含它、`architecture.md`、`product-spec.md` 与样式契约 | 漏 | 补一行 `- [high-leverage-change-guide.md](./high-leverage-change-guide.md): how to rank open-ended work` |
| A19 | development-guide.md:283 与 maintainer-guide.md:60,65 | 前者 active docs = `doc/current`、`doc/releases`、`doc/meta`；后者 canonical 位置含 `doc/perf`、`doc/reviews`、`doc/proposals` | `doc/perf/README.md`、`doc/proposals/README.md` 等门户 frontmatter 均为 `status: active, canonical: true`，而 proposals 门户自述"not the active source of truth" | 旧（定义冲突） | development-guide.md:283 改为 `Normative docs live under doc/current and doc/meta; doc/releases is the release record. doc/perf, doc/reviews, and doc/proposals hold evidence and drafts and never override doc/current.`，maintainer-guide.md:65 同步 |
| A20 | doc/perf/README.md:37 | "Latest release without a dedicated profile: `v0.80.0`" | 当前 `v0.81.0`、`profile_doc: null`（`release-current.yml:1,6`）；v0.80.2-v0.81.0 都没有 profile（`release-profiles/` 最新为 v0.80.1）；且违反 release-runbook.md:38 "Do not hand-maintain current version/date in multiple active docs" | 错 | 删除该行 |
| A21 | doc/perf/README.md:38 | "Latest cross-cutting study: perf-front-back-unified-2026-02-28" | 更新的滚动研究 `studies/perf-scroll-ceiling-2026-09-04.md` 已是滚动工作的结论依据 | 旧 | 追加 `- Latest scroll study (ceiling reached): [studies/perf-scroll-ceiling-2026-09-04.md](./studies/perf-scroll-ceiling-2026-09-04.md)` |
| A22 | doc/perf/studies/README.md:5 | `last_reviewed: 2026-03-07` | `7fa46e0`（2026-09-04）新增了 :11 | 旧 | 按 D8 删除字段或改为 2026-09-04 |
| A23 | doc/proposals/README.md:21-27 | "Current Contents" 列 8 项 | `renderer-hardening-gate-plan.md`、`rich-fidelity-pass.md` 的 frontmatter 为 `status: implemented`；`search-backend-performance-optimization.md`（基线 v0.44.fix8）、`semantic-search-offline-v1.md`（product-spec.md:167 已把语义检索列为 Out Of Scope）、`v0.11-*` 两篇均无 frontmatter、最后实质更新于 2025 年 | 旧 | 这 6 篇移到 `doc/archive/proposals/`（或删除，git 保留历史）；"Current Contents" 只列 `architecture-review-2026-09.md`、`code-hygiene-audit-2026-09-19.md`、`markdown-preview-architecture/proposal.md` 与本文 |
| A24 | release-runbook.md:87 | 2026-09-05 的工具链验证数字 | 同文档 :127-129 规定历史观测移入归档 | 旧 | 移到 `doc/archive/release-runbook-evidence-2026-09-05.md`，原处保留 `make test-tooling runs these correctness checks locally and in CI.` |
| A25 | AGENTS.md:37 | "Frontend performance: `make perf-frontend-profile` smoke; standard recommended before commit, full required before release" | `release-current.yml` 历史：`390a8cc`、`6681c9b`、`68c5caa` 的 full profile 为 `environment_blocked_*`；`5c83597`、`dae61b1`、`7a17d0b` 以真实输入 profile 替代；development-guide.md:149 自述该回调间隔 harness "cannot see hitches or attribute time" | 旧（不可执行） | 见 §6 修订稿 |
| A26 | AGENTS.md:38 | "Performance conclusions: `make perf-unified-table`" | 该目标需要 `perf-audit` 的前后端目录与 `perf-frontend-profile` 摘要（`Makefile:409-413`），对 `scripts/perf-scroll/` 的真实输入测量不适用；`0d3c840`、`37e7417`、`390a8cc`、`7a17d0b` 均记为 `not_run_*` | 旧（不可执行） | 见 §6 |
| A27 | AGENTS.md:48 | "Source and tests live in `Scopy/`, `ScopyTests/`, and `ScopyUITests/`" | 漏 `ScopyUISupport/`（产品代码，`Package.swift:36-39`）、`ScopyTestHost/`、`Tools/ScopyBench`、`Tools/MarkdownRenderer` | 漏 | 见 §6 |
| A28 | AGENTS.md:48 | "explicit access control" | 顶层声明约 185 处无访问修饰符、约 103 处有（`Scopy/Views` 121:32，`Scopy/Design` 11:0，`ScopyUISupport` 11:5）；规则未被遵守也无从检查 | 旧（不可执行） | 见 §4 与 §6 |
| A29 | AGENTS.md:51 | "the repository `scopy-release-homebrew` skill" | 技能在 `.agents/skills/scopy-release-homebrew/SKILL.md`；`.claude/skills/` 为空，Claude Code 不会自动发现它 | 漏 | 见 §6（写明路径） |
| A30 | README.md:121 | "Select and paste \| Enter" | ⏎ → `selectCurrent()`（`git show HEAD:Scopy/Views/ContentView.swift` :97-98；`HistoryViewModel.swift:1403-1407`）→ `select(_:)` 复制并关闭面板（`HistoryViewModel.swift:1230-1238`）；这是 hh 的既定设计，不粘贴 | 错 | `Copy and close panel \| Enter` |
| A31 | README.md:41、:64 | "explicit load-more" / "load-more pages are explicit" | 列表末尾 `LoadMoreTriggerView` 出现即自动加载（`git show HEAD:Scopy/Views/HistoryListView.swift` :125-131），`rowDidAppear` 在末尾前 40 行预取（`HistoryViewModel.swift:916-922`）；只有筛选状态下 footer 才有 "Load more" 按钮（`FooterView.swift:60-72`） | 错 | :41 `…grouped rich-text filters, automatic paging`；:64 `Pinned rows load separately, the first recent page is 50 rows, and further 100-row pages load automatically as you scroll.` |
| A32 | project.yml:53-54、:73-74 | "版本号配置 (v0.6) … 详见 scripts/version.sh 与 DEPLOYMENT.md"；"Phase 7 (v0.43): … Backend (Domain/Application/Infrastructure/Services/Utilities)" | `DEPLOYMENT.md` 是 M2 要删的别名；后端目录还包括 `Extensions`、`Runtime`；`Models/**`、`Protocols/**` 已不存在 | 旧 | :53-54 改为 `# Release versions come from the git tag via scripts/version.sh (doc/current/release-runbook.md).`；:73-74 改为 `# Backend sources belong to the ScopyKit package (Package.swift); keep these excludes the complement of its excludes.`；删 6 行 `Models/**`、`Protocols/**` |
| A33 | Makefile:2、:482 | "符合 v0.md 的构建和测试流程"；`push-release` 配方里打印 "Performance Targets (v0.md)" | `v0.md` 只是 `doc/specs/v0.md` 符号链接指向的归档文件；:481-485 的 echo 卫生审计已列 | 旧 | 删除 :2 注释与 :481-485 |
| A34 | Makefile:385-386 | A/B 目标说明写在 `perf-scroll-tools` 上方 | 实际目标在 :405-406 | 旧 | 把两行注释移到 `perf-warm-scroll-ab:` 上方（D3 退役则一并删除） |
| A35 | doc/current/markdown-chatgpt-wacz-style-contract.md:1、:16-19 | 无 frontmatter；示例命令硬编码 `/Users/hh/Downloads/my-archiving-session.wacz` | 同目录其余 canonical 文档都有 frontmatter；脚本本身按参数取路径（`analyze-chatgpt-wacz-markdown.py:56`） | 旧 | 由渲染面负责人改为 `<path-to-chatgpt-capture>.wacz`；frontmatter 按 D8 的结论处理 |

核对后确认正确、无需修改的要点（节选，便于实施者不重复核对）：product-spec 设置默认值与 `SettingsDTO.swift:44-70`、`SettingsStore.swift:82-146` 一致；搜索分发 0 ms / 短查询 16 ms（`HistoryViewModel.swift:1690-1694`）；recent-only 2000（`SearchEngineImpl.swift:881`）；WAL `synchronous=NORMAL`、`busy_timeout=500`（`SQLiteClipboardRepository.swift:116-118`）；ingest 结果三态（`SQLiteClipboardRepository.swift:50-54`）；hover 常量 16.67 ms / 500 ms / 300 ms / 120 ms / 256 MB / 320 MB / 0.12 s（`HoverPreviewIntentPolicy.swift:31-32`、`HistoryHoverPreviewPipeline.swift:135`、`HistoryItemView.swift:2028`、`HoverPreviewImageCache.swift:30,66`、`ListLiveScrollObserverView.swift:78`）；索引缓存文件名 `fullindex.v5` / `shortindex.v3`（`SearchIndexDiskCache.swift:6-8,105,114`）；`Runtime/` 只编进 ScopyKit（`project.yml:81,182,241`，`482e067` 起，即 §8.3 已解决）；CI 权限与 TSan 跳过条件（`ci.yml:14-15`、`Makefile:186-188`）；DerivedData 分变体（`Makefile:108-217`）；release-runbook 的 Homebrew 步骤与 `release.yml` 一致；high-leverage-change-guide 不含可核对的代码事实，未发现错误。

统计：35 行，其中事实错误 12 条（A1 A2 A4 A5 A6 A7 A8 A9 A10 A20 A30 A31），遗漏 7 条（A11 A13 A16 A17 A18 A27 A29），过时/自相矛盾/不可执行 16 条。

### 1.2 两个校验目标实际校验什么

- `make docs-validate`（`scripts/docs/validate-docs.sh`）：17 个必需文件存在（:15-39，不含 `architecture.md`、`product-spec.md`、`high-leverage-change-guide.md`、样式契约）；`README.md`、`CLAUDE.md`、`AGENTS.md`、`DEPLOYMENT.md` 与 `doc/**/*.md`（跳过 `doc/archive`，去掉代码块与行内代码后）的相对 Markdown 链接目标存在（:41-71）；元数据 `version`/`date`/`release_doc` 与发布门户、CHANGELOG 标题一致，`profile_doc` 为 null 时门户写 `none`（:74-117）。
- `make release-validate`（`scripts/release/validate-release-docs.sh`）：元数据文件、release note、CHANGELOG 存在，release note 文件名等于版本，CHANGELOG 有该版本标题（:9-37），再跑工作流打 tag 策略（:39）。
- 都不校验：frontmatter 任何字段（`last_reviewed`、`related_versions`、`doc_type`、`status`、`canonical`，全仓脚本 0 处读取）；`profile_doc` 非 null 时文件是否存在；`spec_doc`/`architecture_doc`/`runbook_doc` 键（只校验了 `development_doc`，:80-85）；文档里点名的 Make 目标或代码符号是否存在。
- 结论：`related_versions` 与 `last_reviewed` 的"维护语义"没有任何执行者，漂移已经发生（M7/D8）。若 hh 选择保留字段，最小校验是 `profile_doc` 存在性一行加 frontmatter 必填字段检查；若删除字段，两个脚本无需改动。

### 1.3 Makefile 目标与说明的覆盖

54 个目标中：

- `make help` 与 canonical 文档都没提到的 13 个：`all`、`bench-snapshot-search`、`markdown-assets-gate`、`markdown-renderer-deps`、`perf-audit`、`perf-capture`、`perf-frontend-profile-smoke`、`perf-scroll-tools`、`perf-scroll-wheel`、`perf-search-type`、`perf-warm-scroll-ab`、`release-bump-patch`、`test-real-db`。其中 `perf-capture`、`perf-scroll-wheel`、`perf-search-type` 是 v0.76 之后实际使用的真实输入测量入口，最该出现在 help 里。
- 文档提到但 `help` 漏掉的：`test-tsan`、`release-validate`、`snapshot-perf-db`。
- `.PHONY` 漏掉：`release`、`quick-build`、`test-integration`、`format`、`lint`、`stats`、`help`、`docs-validate`。
- 行为与名字不符：`clean`（:55-60）`rm -rf Scopy.xcodeproj` 删除了已跟踪的 `project.pbxproj` 与 3 个共享 scheme；`rm -rf build/ DerivedData/` 针对的目录在当前构建布局下不存在。`stats`（:338）遍历不存在的 `Scopy/Protocols`。
- 由卫生审计决定去留的：`test-flow`、`test-flow-quick`、`health-check`（审计 §4.1 建议删）、`test-perf`、`test-perf-heavy`、`benchmark`、`test-snapshot-perf`、`test-real-db`（D4 与审计 §3.1）。建议在这些决定落地后一次性重写 `help`，按"构建 / 必需门禁 / 性能测量 / 发布"四组列出全部保留目标，避免改两遍。

## 2. 术语表与命名一致性

### 2.1 方法

统计范围 `Scopy/` + `ScopyUISupport/` 的 158 个 Swift 文件（HEAD）；"类型"按 `class|struct|enum|actor|protocol|typealias` 声明名统计，"出现"为大小写不敏感的子串命中，改名成本按精确标识符 `rg -o '\b…\b'`（含 `ScopyTests`/`ScopyUITests`）计。只对"名字让读者得出错误结论"的情况建议改名。

### 2.2 术语表

| 术语 | 定义（一句话） | 规范名 | 现有别名 / 冲突 | 规模 | 建议 |
| --- | --- | --- | --- | --- | --- |
| capture / ingest | capture = 从 pasteboard 读出并规范化一次变化；ingest = 把 capture 结果幂等地写入存储的整条路径 | 同左 | 无冲突 | ingest 8 文件 443 处；capture 13 文件 44 处 | 保留 |
| ingest spool / pending envelope / terminal marker / receipt | spool = Application Support 下的持久暂存目录；envelope = 一次外部载荷 capture 的待回放描述（`PendingIngestEnvelope`）；terminal marker = 已确认、不再回放的状态；receipt = `ingest_receipts` 表中"该 envelope 已提交"的记录 | 同左 | 无冲突 | spool 4 文件；envelope 6 文件 189 处；receipt 4 文件 48 处 | 保留；写进 development-guide §2 |
| publish | 把已提交的状态作为事件发给 UI/搜索（`ClipboardEventQueue.PublicationToken`，`ClipboardService.swift:363-420`；`publish*` 函数 6 个） | publish | 文档与注释还用它指"写 spool"（architecture.md:29）和"把文件放到托管路径"（architecture.md:31、`StorageService.swift:513,795,2205` 注释） | publication 3 文件 93 处；publish 12 文件 80 处 | 文件放置在文档/注释中改称 place；无标识符改名 |
| content revision | 条目内容身份的值类型，用于让旧的预览/备注/导出结果失效（`ClipboardItemContentRevision`） | content revision | `HistoryViewModel.itemsRevision` 是列表变更计数器，不是内容身份 | 79 处 / 12 文件 | 保留；术语表注明两者不同 |
| render ID | 每次 WebView 导航的标识，旧回调据此丢弃 | render ID | JS 侧函数叫 `currentRenderGeneration()`，却读 `data-scopy-render-id`（`MarkdownHTMLDocumentBuilder.swift:2345-2347`） | Swift `renderID` 34 + `currentRenderID` 15；JS 10 处 | 改名 R4（同文件 10 处） |
| generation | 单调递增的失效计数器：结果带回的 generation 与当前不等即丢弃（`monitorGeneration` 19、`clearGeneration` 17、`workerGeneration` 14、`cacheGeneration` 14、`fullIndexBuildGeneration` 8 等） | generation | 缩略图"生成"也叫 generation（`thumbnailGenerationQueue` 12、`ThumbnailGenerationWork` 7 等约 40 处） | — | 不改；语境足以区分，改名成本约 40 处而收益低 |
| lease | 一段可撤销的独占权：持有期间他人不得执行同一动作 | lease | 四处用法语义一致：`ClipboardItemMutationGate.Lease`（`ClipboardService.swift:572`）、`ExternalImageSourceLease`（`StorageService.swift:173`）、`MarkdownExportService.PasteboardWriteLease`（`:40`）、WebView owner lease（文档用词；代码注释称 ownership，`MarkdownPreviewWebView.swift:663,1082`） | 18 文件 | 保留 |
| session | 有明确开始与结束的一段交互 | session | 三种：hover 转移会话（`HoverPreviewIntentPolicy.Session`）、行交互会话（`HistoryItemInteractionSessionStore`）、`URLSession`（`LinkEnrichmentSessionBox`） | 18 文件 | 保留 |
| policy | 纯决策类型：无副作用、无计时、可穷举测试 | policy | 8 个类型全部符合（`FloatingPanelDismissPolicy`、`HoverPreviewIntentPolicy` 等）；`PanelReopenSearchResetPolicy.shouldClearSearch` 是无人调用的复制品（卫生审计 §2.1） | 8 类型 / 20 文件 | 把"Policy = 纯决策"写成约定（§4） |
| coordinator / controller / state / model | coordinator 协调多个对象的生命周期；controller 持有一个可观察 UI 单元的动作；state 是可观察的数据；model 是视图的数据源 | 同左 | 行级集群有 5 个对象：`HistoryItemInteractionState`、`HistoryItemRowController`、`HistoryItemPreviewCoordinator`、`HoverPreviewModel`、`HistoryItemInteractionSessionStore`；SwiftUI `NSViewRepresentable.Coordinator` 另有 7 个同名嵌套类（框架约定） | coordinator 22 文件；controller 18 文件 | 保留；development-guide §4.3 用一段话说明行级集群的所有权 |
| pipeline | 按固定顺序、带取消与缓存的多阶段加工 | pipeline | 只有 `HistoryHoverPreviewPipeline` 一个类型；文档另称渲染链为 "rendering pipeline" | 9 文件 | 保留 |
| plan / commit（清理） | plan = 事务外的建议性候选快照（`DeletePlan`）；commit = 事务内重新校验后的实际删除（`commitDeletePlan`） | 同左 | 与搜索的 "plan" 同名不同义（下一行） | Plan 10 类型；Commit 6 类型 | 保留 |
| search plan | 名义上的搜索路由规划 | —（应消失） | `SearchPlanner.plan` 只写诊断原因（`SearchEngineImpl.swift:1928-1930`），不参与路由；`SearchPlanner` 其余被产品使用的成员是 3 个查询规范化函数（`normalizedExactQuery`、`fuzzyPlusTokens`、`shouldUseSubstringOnlyFallbackForFuzzyPlus`） | 产品 8 处引用，测试 `SearchPlannerTests` | 改名 R2（与卫生审计 §1.1 删除 `plan` 同批） |
| coverage / prefilter / staged refine / recent-only | coverage 说明结果集相对完整历史的完备程度（`SearchCoverage`）；staged refine = 先给首屏、后台收敛到完整结果；recent-only = 有意只查最近 2000 条 | 同左 | `isPrefilter` 名为"预筛"，实为"非 complete"，对 recent-only 也为真 | prefilter 6 文件 65 处 | 改名 R1 |
| match evidence | 搜索结果行上显示的命中片段、来源与计数 | match evidence（产品与文档）/ `SearchMatchContext`（代码） | 同一概念两套名字；development-guide:83 写 "match-context generation"，product-spec 写 "match evidence" | evidence 8 文件 32 处；MatchContext 10 文件 83 处 | 不改代码；术语表建立映射，文档统一写 "match evidence (`SearchMatchContext`)" |
| summary | 三种含义：不带 blob 的行投影（`fetchRecentSummaries`、`parseStoredItemSummary`）；聚合统计（`PerformanceSummary`、`ClipboardIngestSummary`、`FileDeletionSummary`）；预览摘要文本（`FilePreviewSummary`） | 行投影称 summary row | 架构评审 #9 "summary 查询"容易被读成聚合 | 21 文件 155 处 | 不改；术语表写明 |
| DTO / stored item | DTO = 跨 UI 协议边界的值类型（`ClipboardItemDTO` 等 4 个）；stored item = 仓储层行（`ClipboardStoredItem`） | 同左 | `StorageService.StoredItem` 是 `ClipboardStoredItem` 的 typealias（`StorageService.swift:126`），同一类型两个名字 | `ClipboardItemDTO` 264 处 / 42 文件；`StoredItem` 61 处 / 3 文件；`ClipboardStoredItem` 94 处 / 8 文件 | 删除 typealias（R5；硬约束 1：别名即兼容层） |
| tombstone | 搜索内存索引中已删除条目的占位槽 | tombstone | 无冲突 | 3 文件 84 处 | 保留 |
| outcome / result | outcome = 互斥结果的枚举（7 个，如 `IngestUpsertOutcome`）；result = 计数/集合的结构体（`CleanupResult`、`DeleteCommitResult`） | 同左 | 一致 | — | 写成约定 |
| token | 用于身份比较的不透明值，旧 token 的回调被拒绝 | token | 8 个类型，一致；`Unicode61Tokenizer` 是分词器，无歧义 | 22 文件 | 保留 |
| snapshot | 某时刻状态的不可变拷贝 | snapshot | 12 个类型，一致；`ClipboardService.swift:34` 与 `AsyncPermitPool.swift:4` 的嵌套 `Snapshot` 是通名 | 21 文件 | 保留 |
| pin | 条目置顶：`isPinned`（139 处）、`fetchPinned`、`pinnedItems`、`.itemPinned` 事件、右键 "Pin/Unpin" | pin（只指条目） | 预览"固定为独立窗口"也叫 pin：`PinnedPreviewController`、`PinnedPreviewPanel`、`isPreviewPinningActive`、无障碍标识 `PinnedPreview.*`、`History.Preview.Pin`；"保持在最前"开关同样用 `pin`/`pin.fill` 图标（`PreviewControls.swift:17`） | 预览相关标识符 41 处 / 8 文件 | 改名 R3（代码改称 detached preview；UI 图标是 hh 的设计决定） |
| profile | 四种含义：性能插桩（`ScrollPerformanceProfile`、`SCOPY_SCROLL_PROFILE`、`perf-frontend-profile`）；Markdown 来源分类（`MarkdownSourceProfile`）；Markdown 版式档位（product-spec:82 "layout profile"）；Xcode scheme `ScopyWarmProfile` 与发布 `profile_doc` | 视上下文 | 语境清楚，未发现误读证据 | 12 类型 / 22 文件 | 保留 |
| harness / probe | 只为 UI 测试存在的视图（`*HarnessView`）与无障碍探针（`HistoryListUITestProbe`） | 同左 | 一致；去留见 D1 | 4 + 2 类型 | 保留 |
| UI 服务协议 | UI 通过它访问后端的 `@MainActor` 协议 | `ClipboardServiceProtocol` | 名字暗示由 `ClipboardService` 实现，实际实现者是 `RealClipboardService`（主 actor 适配器，转发给 `actor ClipboardService`）与 `MockClipboardService`；architecture.md:19 为此专门加了一句解释 | 协议 32 处 / 15 文件；actor `ClipboardService` 19 处 / 10 文件 | 改名 R6（改 actor，不改协议） |
| `SearchEngineImpl` | 搜索 actor | — | `Impl` 暗示有 `SearchEngine` 协议，仓内唯一的协议是 `ClipboardServiceProtocol` | 102 处 / 17 文件 | 暂不改；若搜索面评审拆分该文件，同批改为 `SearchEngine` |

### 2.3 建议执行的改名（只有这 6 项）

| # | 现名 | 新名 | 为什么误导 | 成本 |
| --- | --- | --- | --- | --- |
| R1 | `SearchCoverage.isPrefilter` | 删除，调用点写 `coverage != .complete`，或改为 `isComplete` 取反 | 对 `.recentOnly`（正则、≤2 字符 exact）这种终态结果也为真；development-guide:83 因此写错 | 定义 1 + 调用 3（`SearchMatchContextBuilder.swift:399,582,631`）。同时请搜索面确认 recent-only 是否本就不该进入 FTS 短语证据路径 |
| R2 | `SearchPlanner` | 卫生审计删除 `plan`/`SearchPlan*`/`SearchPlanDiagnostic` 后，剩余 3 个函数移入 `SearchQueryNormalization`（`enum`，同目录） | 名为 planner 却不规划执行；development-guide:80 因此写错 | 产品 5 处 + `SearchPlannerTests` 1 个文件 |
| R3 | `PinnedPreviewController`、`PinnedPreviewPanel`、`PinnedPreviewWindowView`、`isPreviewPinningActive`、`isPinnedPreviewWindow`、无障碍标识 `PinnedPreview.*` | `DetachedPreview…`、`isPreviewDetached…`、`DetachedPreview.*` | 与条目 pin 同词不同义，读代码时无法分辨 `pinned` 指条目还是窗口 | 41 处 / 8 文件（含 UI 测试标识符）。持久化键 `ScopyPinnedPreviewKeepsOnTop`、autosave 名 `ScopyPinnedPreviewPanel` 保留原字符串：它们是存储键，不是读者看到的名字，改了只会丢用户的已存偏好 |
| R4 | JS `currentRenderGeneration()` | `currentRenderID()` | 与 Swift 侧 render ID 同一概念、两个名字，而 generation 在 Swift 里另有含义 | `MarkdownHTMLDocumentBuilder.swift` 内 10 处，属渲染面，须跑渲染器门禁 |
| R5 | `StorageService.StoredItem`（typealias） | 直接用 `ClipboardStoredItem` | 同一类型两个名字 | 61 处 / 3 文件，机械替换 |
| R6 | `actor ClipboardService` | `ClipboardBackend` | 让 `ClipboardServiceProtocol` / `RealClipboardService` / `ClipboardService` 三者关系一眼可读：协议是 UI 边界，`Real…` 是适配器，backend 是 actor | 19 处 / 10 文件；文件 `Scopy/Application/ClipboardService.swift` 同名改 |

另有一个文件名误导：`Scopy/Views/History/MarkdownPreviewRenderer.swift` 不声明 `MarkdownPreviewRenderer`，只有 `MarkdownRenderOutput` 与死代码 `MarkdownRenderDiagnostics`。在 AGENTS.md 明令"不得引入第二个 renderer"的前提下，这个文件名会让读者以为存在第三条渲染链。删除 diagnostics 后改名为 `MarkdownRenderOutput.swift`（0 处引用受影响）。`ScopyLogger.swift` 声明的是 `ScopyLog`，顺带改名。其余 152/158 个文件名与主类型一致。

明确不改名：`SearchEngineImpl`（见上）、`generation` 的两种用法、`HistoryItemRowController`（development-guide:140 "Do not restore eager row controllers" 指的是急切创建，不是这个类型）、`ScrollCursorSetCoalescer`（名字说滚动而实际合并所有重复 `NSCursor.set`，但其文档注释 `:4-13` 把原因讲清楚了，改名收益小于成本）。

## 3. 注释与语言策略

### 3.1 现状（HEAD 实测）

- 代码注释：158 个 Swift 文件中 121 个含注释，其中 45 个含中文注释；注释行共 1,956 行，中文 464 行（23.7%）。中文集中在老文件：`StorageService.swift` 63 行、`ClipboardMonitor.swift` 54、`HotKeyService.swift` 43、`ScopySize.swift` 42、`ClipboardServiceProtocol.swift` 29。近半年新增的文件几乎全是英文注释。
- 版本号流水账注释：98 行分布在 22 个文件（如 `HotKeyService.swift:4-14` 连续五行 `v0.11:`/`v0.17.1:`/`v0.23:`）；引用归档规格 `v0.md` 的注释 18 行（`StorageService.swift:99,180,201,447,512` 等），外加 `Makefile:2,482`、`project.yml:53`。
- 文档语言：`doc/current` 与 `doc/meta` 英文（例外：`doc/current/troubleshooting/test-hanging-fix.md` 是中文历史笔记，门户自称 "historical fix notes"，放错了目录）；release note 自 v0.75.0 起全部英文；`CHANGELOG.md` 同一版本的条目却是中文；proposals（13 篇中 10 篇）与 reviews（47 篇中 40 篇）以中文为主。
- UI 字符串：中文字面量 142 行分布在 14 个文件——设置页 9 个文件，另有 5 个非设置文件把中文带进英文主面板：`ClipboardItemDisplayText.swift`（行元数据）、`SearchMatchPresentation.swift` 与 `SearchMatchContextBuilder.swift`（搜索证据）、`HistoryViewModel.swift`、`HistoryItemView.swift`。

### 3.2 政策（建议写进 development-guide 的 "Code Conventions" 一节）

1. **代码注释只用英文。** 理由：标识符、canonical 文档、release note 都是英文，76% 的注释行已是英文；混合语言让 `rg` 检索和代理阅读都要猜两套词。M6 按模块一次性完成（ScopyKit 一个提交、app 一个提交），不做"碰到再改"——那等于永远处于半迁移状态，违背硬约束 7。
2. **注释只写当前代码为什么这样做**：不变量、测得的原因、被否决过的方案。不写版本号和改动历史（`git log -L`/`git blame` 是历史的唯一来源），不引用归档文档，不复述代码本身。非显然的常量要写出依据（测量或测试名）。`ScrollCursorSetCoalescer.swift:4-13` 与 `HistoryItemView.swift:918-925` 是本仓库的范例。
3. **文档按目录定语言**：`doc/current`、`doc/meta`、`AGENTS.md`、`CLAUDE.md`、根 `README.md`、`doc/releases/history/`（新增条目）用英文；`doc/proposals`、`doc/reviews`、`doc/perf/studies` 可用中文（hh 的工作语言），标识符、命令、路径保持英文原文。`CHANGELOG.md` 需要 hh 选一种（D12）；建议从下一个版本起英文，与同版本 release note 一致，历史条目不改。
4. **UI 字符串是本地化 P0 的产品决定，本文不设计**，只列 hh 需要选择的选项（D11）：
   - (a) 单一英文 UI：设置页与行元数据/搜索证据改为英文，不引入本地化资源；最小改动，但放弃中文界面。
   - (b) 单一中文 UI：主面板改为中文；与英文 README、Homebrew 受众不一致。
   - (c) 以英文为开发语言，引入 `Localizable.xcstrings` 并提供 zh-Hans；界面随系统语言切换；工程量最大，但与架构评审 §7.5 的方向一致。
   - 无论选哪一项，卫生审计 §2.4 / D5 的 `formatBytes` 统一都应先落地，因为字节格式是所有选项共用的一部分。

### 3.3 注释与代码不符（抽样 15 处）

| # | 位置 | 问题 | 事实 | 处理 |
| --- | --- | --- | --- | --- |
| C1 | `StorageService.swift:435` | 不符 | `performWALCheckpoint` 注释写"定期调用以控制 WAL 文件大小"，产品零调用，只有 `PerformanceTests.swift:572,613,641,672` 在调；产品 checkpoint 走 `walCheckpointTruncate()`（`:1500`） | 随卫生审计 §2.1 删除函数 |
| C2 | `StorageService.swift:440` | 不符（夸大） | `close()` 注释"关闭前执行 WAL 检查点，确保数据完整写入"；实际是 `repository.close()` 里一次 PASSIVE checkpoint（`SQLiteClipboardRepository.swift:133-136`），不保证完成，已提交数据本就在 WAL 中持久（D1） | `/// Closes the database after a best-effort passive WAL checkpoint; committed data is already durable in the WAL.` |
| C3 | `StorageService.swift:430` | 不符 | `open()` 只有一行 `try await repository.open()`，注释描述的"临时变量、失败清理"在 `SQLiteClipboardRepository.swift:109-131` | 删除注释 |
| C4 | `StorageService.swift:446-448` | 不符 | `upsertItem` 注释写去重与"大内容外部写入后台化"，函数本身只是把 `.alreadyApplied(nil)` 转成抛错的薄包装（`:449-455`），产品零调用 | 随卫生审计 §2.1 移到测试侧 |
| C5 | `HotKeyService.swift:12-14` | 不符 | 三行历史注释互相矛盾："v0.17.1: 使用 withLock" 描述的锁已不存在，函数用串行队列（`:10,23`） | `/// Appends to /tmp/scopy_hotkey.log on a serial utility queue and rotates at 10 MB; AGENTS.md uses this log as hotkey evidence.` |
| C6 | `ClipboardMonitor.swift:2336` | 不符（漏主效应） | 注释称"for consistent hashing"，但同一结果也成为存储的 `plainText`（`:2054-2069`），首尾空白与 NBSP 因此不回贴（架构评审 §3.2，已冻结） | `/// Canonical text for both the content hash and the stored plain text: unifies line separators, replaces NBSP, removes BOM, trims surrounding whitespace. Replayed text therefore loses surrounding whitespace (architecture-review-2026-09 §3.2).` |
| C7 | `HistoryViewModel.swift:924-925` | 不符 | "applied … per run-loop turn"；实际块间睡眠 20 ms（`:1021`） | `/// Rows applied per chunk; chunks are 20 ms apart so a 100-row page costs five small List updates.` |
| C8 | `SQLiteMigrations.swift:72` | 不符（且违背硬约束 1） | "Legacy table kept for backward compatibility"：`schema_version` 在全仓零读取，每个新库仍会创建（`:73-80`） | 删除建表与注释；旧库里残留的空表无害，不需要迁移（卫生审计漏列） |
| C9 | `ScopySize.swift:3-4` | 不符 | "修改 unit 可以缩放整个 UI"：13 个文件里 24 处 `.frame(width:/height:)` 用字面量绕过它 | 删除该句或改为 `/// Size tokens on a 4 pt grid; views outside ScopySize still use literal sizes.` |
| C10 | `ScopySize.swift:13-26` | 显然 | `static let xs = u * 3 // 12pt - 小图标`：复述算式与名字 | 删除行尾注释 |
| C11 | `SettingsDTO.swift:32` | 显然 + 版本号 | `// 缩略图设置 (v0.8)` | 删除 |
| C12 | `MockClipboardService.swift:5-6` | 过时引用 | "符合 v0.md 的解耦验收标准"，`v0.md` 只能经符号链接 `doc/specs/v0.md` 找到 | `/// In-memory ClipboardServiceProtocol for UI tests (--uitesting) and unit tests.` |
| C13 | `ClipboardServiceProtocol.swift:5-6` | 过时引用 + 加重命名误导 | "对应 v0.md 中的前后端接口设计" | `/// Main-actor boundary between the UI and the clipboard backend; implemented by RealClipboardService (adapter over the backend actor) and MockClipboardService.` |
| C14 | `SearchMode.swift:3,7` | 过时引用 + 版本号 | "对应 v0.md 中的 SearchMode"；`case fuzzyPlus // v0.19.1: 分词 + 每词模糊匹配` | 类型注释删除；`fuzzyPlus` 改为 `// Tokenized; every token must fuzzy-match.` |
| C15 | `SettingsStore.swift:3-6` | 部分不符 | 自称"Settings 的唯一真相源"，但另有 5 处 `UserDefaults.standard` 读写（`HistoryViewModel.swift:519,1224`、`PinnedPreviewController.swift:98,188`、`HistoryItemMarkdownExportController.swift:65`、`HistoryItemTextPreviewView.swift:294-305`、`MarkdownPreviewLayoutScalePreference.swift:11-13`）；它们是按设计不走 Save/Cancel 的预览局部偏好（development-guide.md:94） | `/// Persists SettingsDTO, the transactional Save/Cancel settings. Preview-local UI preferences (FTS sort, preview scale, export resolution, keep-on-top) are stored separately.` |

## 4. 代码结构约定

### 4.1 现状

- 超过 2,000 行的产品文件是 8 个（不是 7 个；第 8 个在 `ScopyUISupport`）：`SearchEngineImpl` 5,241、`ClipboardService` 2,924、`MarkdownHTMLDocumentBuilder` 2,871、`MarkdownExportService` 2,810、`ClipboardMonitor` 2,728、`StorageService` 2,435、`ScrollPerformanceProfile` 2,232（11 个顶层类型）、`HistoryItemView` 2,174。测试侧另有 `ExportMarkdownPNGUITests` 2,158。
- 行数会误导：`MarkdownHTMLDocumentBuilder.swift` 2,871 行中 2,799 行（97%）在 Swift 多行字符串字面量里，是 CSS 与 JS；`MarkdownExportService.swift` 有 680 行（24%）。它们的问题不是 Swift 太长，而是另一门语言藏在 Swift 字符串里，不能被 lint、测试或 Node 渲染器门禁覆盖。
- `// MARK: - ` 格式统一（143 处，0 处其他格式），但只有 35/158 个文件使用；1,604 行的 `SQLiteClipboardRepository` 只有 1 个 MARK，`MarkdownHTMLDocumentBuilder` 为 0。
- 最大的 10 个文件中 9 个没有任何 `extension` 块：本仓库的实际做法是"一个类型体 + MARK 分段"，没有"extension-per-concern"的惯例。跨文件 extension 访问不到 `private` 成员，会逼着把 actor 状态放宽到 internal，所以不建议引入这种惯例。
- 访问控制：顶层声明约 185 处无修饰符、103 处有；app target 里有 33 个 `public`（`PerformanceMetrics.swift`、`AppVersion.swift`），在 app 里没有任何意义；ScopyKit 有 460 个 `public`，测试用 `@testable import ScopyKit`（34 个文件）。
- `Runtime/` 双 target 编译已在 `482e067`（v0.80.0）解决：三个 target 都排除 `Runtime/**`（`project.yml:81,182,241`），`PerfFeatureFlags` 为 `public` 且只在 ScopyKit。当前没有任何自动检查防止回归。
- UI 测试支撑进 Release：`Scopy/Views/UITesting/`（4 个文件 1,069 行）与 `Scopy/Services/MockClipboardService.swift`（751 行，位于 ScopyKit）均无 `#if` 包裹；产品代码中 `--uitesting`/`UITest`/`SCOPY_UITEST` 分支共 141 处、14 个文件。处理见 D1。每次访问都读 `ProcessInfo.arguments` 的只剩 `HistoryItemTextPreviewView.swift:236-238`（`HistoryItemView` 已改为 `static let`，`:64-66`）。
- 测试接缝命名三套并存：`…ForTesting`（13 个声明）、`debug…`（22 个，其中 `SearchEngineImpl` 16 个、`SearchIndexDiskCache` 4 个）、`forTesting`/`createForTesting`（4 个）；`#if DEBUG` 只在 5 个文件出现。

### 4.2 约定文本（可直接放进 development-guide，英文）

```markdown
## Code Conventions

- **Module ownership.** Backend code (Application, Domain, Infrastructure, Services, Utilities, Extensions, Runtime) belongs to ScopyKit; app code (Design, Observables, Presentation, Views, top-level files) belongs to the Scopy target. Package.swift and project.yml excludes must partition `Scopy/`; `make test-tooling` fails otherwise.
- **Access control.** In ScopyKit, mark `public` exactly what the app or ScopyBench uses; leave other declarations internal (tests use `@testable import`). The app target never uses `public`. Use `private` for anything used by one file; use `fileprivate` only for a same-file extension.
- **One primary type per file**, named after the file. A second top-level type is allowed only when it is private to the primary type's implementation.
- **File size.** Treat 1,000 Swift lines (excluding embedded literals) as the point to look for a seam and 2,000 as the point where a change that adds code must also split. Split along ownership seams into separate types with explicit inputs and outputs (a store, a pure policy, a SQL gateway, a state machine), not into cross-file extensions of one type, which would force `private` state to internal.
- **No foreign-language source in Swift strings.** CSS, JS, or HTML longer than about 50 lines lives under Scopy/Resources and is covered by the asset manifest; Swift only fills parameters.
- **Sections.** Use `// MARK: - Title` for every file over 300 lines; one section per responsibility, in the order: lifecycle, public API, private helpers.
- **Naming roles.** `…Policy` is a pure decision type (no side effects, no clock, no async). `…Snapshot` is an immutable copy. `…Outcome` is an enum of alternative results; `…Result` is a struct of counts. `…Token` is compared by identity to reject stale callbacks. `generation` is a staleness counter. Terms follow the glossary in this guide.
- **Test seams.** A production symbol that exists only for tests is named `…ForTesting`, is compiled only under `#if DEBUG`, and has no production caller. Prefer a test-target extension when the seam needs no private state.
- **UI-test and profiling hooks.** Launch arguments and environment variables are read once into `static let` values; never per row or per frame. A hook without a script, test, or document that sets it is deleted.
- **Comments.** English only. Explain why, invariants, and measured causes; no version tags, change history, or references to archived documents.
- **Logging.** Only through `ScopyLog` categories; no ad hoc `Logger`, `print`, or `NSLog`.
- **Experiments.** Experimental switches and A/B paths stay on branches; merged code has one implementation per behavior.
```

（12 条、共 14 行，满足 ≤30 行。其中"模块归属自测"是 M4 的一部分：约 40 行 Python，放在 `scripts/tests/`，解析 `Package.swift` 的 `ScopyKit` exclude 与 `project.yml` 三个 target 的 exclude，断言 `Scopy/` 顶层每个 Swift 目录/文件恰好属于一侧，且每个 exclude 条目都存在——它会同时抓住 §8.3 那类漏排除和今天仍在的 `Models/**`、`Protocols/**` 死条目。）

## 5. 卫生审计 D1-D7：架构师建议与 Phase 1 抽查

本节引用 `doc/proposals/code-hygiene-audit-2026-09-19.md`（下称"审计"），不重复其删除清单。

### 5.1 D1-D7 建议（供 hh 一次决定）

D1 与 D3、D4 与 perf-audit 互相耦合，建议按 D3 → D1 → D4 的顺序决定。

| # | 建议 | 理由与证据 |
| --- | --- | --- |
| D1 | **选 `#if DEBUG`，前提是 D3 选择退役 A/B 装置**；否则按审计选项 (b) 用自定义编译条件。无论哪种都把 `MockClipboardService.swift` 从 `Scopy/Services/`（ScopyKit）移到 `Scopy/Views/UITesting/`（app 侧），`ClipboardServiceFactory`（`RealClipboardService.swift:128-140`）只保留真实服务，mock 选择留在 `AppState`（`AppState.swift:122-147`） | 以 Release 配置跑 UI 测试的唯一入口是 `perf-warm-scroll-ab.sh:367-370`（`-scheme ScopyWarmProfile -configuration Release`）。`perf-frontend-profile.sh:223-227` 用 scheme `Scopy`，其 test 动作是 Debug；`scripts/perf-scroll/*.py` 以 `USE_MOCK_SERVICE=0` 驱动 Release app，只用 `SCOPY_PROFILE_*` / `SCOPY_SCROLL_PROFILE` 插桩（`profile_scroll.py:46-51`、`profile_search.py:70-72`、`profile_capture.py:85-87`），不需要 harness 与 mock。ScopyTests 直接编译 app 源码（`project.yml:168-184`），10 个用到 mock 的测试文件不受影响。待编译确认：ScopyKit（SwiftPM target）在 Debug 下是否定义 `DEBUG`——若把 mock 移到 app 侧，这个问题就不存在 |
| D2 | **同意审计建议，并统一接缝命名**：全部改为 `…ForTesting` 且位于 `#if DEBUG` 内；能用测试侧 extension 表达的（`queuedWaiterCount`、`isSafePublicURL` 等）移到测试 target | 现在三套命名并存（`…ForTesting` 13、`debug…` 22、`forTesting`/`createForTesting` 4），`#if DEBUG` 只覆盖 5 个文件。`SearchEngineImpl` 的 16 个 `debug…` 与搜索面拆分同批改名，避免同一文件改两次 |
| D3 | **全部折叠（11 个 flag）并退役 A/B 装置** | 滚动研究已结论（`doc/perf/studies/perf-scroll-ceiling-2026-09-04.md`），development-guide.md:159 已把两项实验记为"不得在无新证据时重试"；flag 的非默认分支是旧实现（`PerfFeatureFlags.swift:5-6` 自述保留 "eager legacy observer path"），与硬约束 1 冲突。审计未计入的连带删除：`scripts/perf-warm-scroll-ab.sh` 492 行、`scripts/quality/summarize-warm-scroll-ab.py` 2,153 行、`scripts/quality/source-manifest.py` 1,222 行（只服务 A/B，`perf-warm-scroll-ab.sh:24-25`）、`ScopyWarmProfile` scheme（`project.yml:20-32` 与已跟踪的 `ScopyWarmProfile.xcscheme`）、`make perf-warm-scroll-ab`、`make test-tooling` 的两个自测（`Makefile:289-290`），合计约 3,870 行工具链。**需要 hh 认可的门禁变化**：`perf-frontend-profile.sh:160-169` 把 4 个 flag 全关当作 "baseline" 变体，等于二进制里永久保留 4 条旧路径做对照；折叠后它变成单变体，与上一次提交或发布保存的摘要比较（与 `scripts/perf-scroll` 的真实输入测量做法一致）。以后需要同二进制 A/B 时在分支上临时加开关，合并前删除 |
| D4 | **整文件删除** `PerformanceTests.swift`（1,205 行）与 `Helpers/PerformanceHelpers.swift`（117 行），删除 `test-perf`、`test-perf-heavy`、`benchmark` 目标、`Makefile:95,216` 的 skip 行与 `project.yml:222` 的排除行；仍需要的批量插入/清理/内存数字改写为 ScopyBench 场景 | 15 个非重复方法阈值依赖机器、从未在 CI 运行，按"无消费者即删"。审计漏掉的耦合：`scripts/perf-audit.sh:171-177` 默认调用 `make test-perf` / `test-perf-heavy` / `test-snapshot-perf`，而 `make perf-unified-table` 的后端输入来自 perf-audit（`Makefile:409-413`）；删测试时 perf-audit 必须同时收缩为只跑 ScopyBench，审计 §3.1 删除 `SnapshotPerformanceTests` 也受同一耦合约束 |
| D5 | **同意统一到 Foundation `ByteCountFormatter`**（硬约束 5、6），接受 "900 B" → "0.9 KB" 这类可见变化 | 6 份副本、3 处已漂移（审计 §2.4）；`ClipboardItemDisplayText` 的私有实现用二进制除数标十进制单位（架构评审 §7.5）。它是 D11 任一选项的共同前提，应先做 |
| D6 | **删除**研究工具，不移入 `doc/perf/studies/tools/`；`scripts/quality/analyze-chatgpt-wacz-markdown.py` 不在删除之列 | 文档目录不放可执行代码；研究结论已写进 studies，源码留在 git 历史。WACZ 分析脚本是样式契约的复现工具（契约 :16-19），路径通过参数传入（脚本 :56），只需把契约示例里的 `/Users/hh/Downloads/…` 改为占位符 |
| D7 | **同意，但写成一句并入 Working Agreement**，不新增清单；措辞见 §6 | 清单式条目会在每次 PR 被勾选而不被执行；一句约束加上 §4.2 的 "Test seams / Experiments" 两条已足够，且给 `#if DEBUG` 的 `…ForTesting` 接缝留出明确例外 |

### 5.2 Phase 1 清单抽查（HEAD `407f7db`，审计基线 `5e2c168`）

| 审计条目 | HEAD 结果 | 证据 |
| --- | --- | --- |
| `ScopyComponents.swift` 五个符号无引用 | 准确 | `CapsuleFilterButtonStyle`、`InfoTag`、`ScopyCard`、`ScopyBadge` 全仓各 1 处（声明）；`ScopyButton` 4 处全在该文件内 |
| `SettingsFeatureRow.swift` 无引用 | 准确 | 全仓 1 处（声明） |
| `backgroundMediaSchedulingSnapshot()` + 类型 | 准确 | `ClipboardService.swift:711,2507,2510`，无调用者 |
| `SearchEngineImpl.fetchAllSummaries()` 是 repository 的重复 | 不完整 | 两份都没有调用者：`SearchEngineImpl.swift:3971` 与 `SQLiteClipboardRepository.swift:605`；两份都应删除 |
| `AppVersion.versionWithDate` + "随之孤立的 `buildDate`" | **不准确** | `versionWithDate`（`AppVersion.swift:36`）确无引用；但 `buildDate` 被 About 页使用（`AboutSettingsPage.swift:32` `Text("构建于 \(AppVersion.buildDate)")`），只能删前者 |
| `parseHeightsFromLayoutDebugInfo` | 准确，行号未漂移 | `MarkdownExportService.swift:2054`，1 处 |
| `katexDelimitersJSArrayLiteral`、`recentOnlyLimit`、`refreshStorageStats`、`resetShared`、`HistoryItemView.cancelPreviewTask` | 准确 | 各 1 处；`cancelPreviewTask()`（单数，`HistoryItemView.swift:1525`）无调用，另有同名复数方法 `cancelPreviewTasks()` 在用，删除时勿混淆 |
| `ScopyLog.persistence` 零调用 | 准确 | `rg 'ScopyLog\.persistence'` 0 处 |
| `SCOPY_PERF_SIGNPOSTS` 与唯一一对 signpost | 准确 | `SearchEngineImpl.swift:99,1779-1798`；仓内无设置者 |
| 每次搜索执行 `SearchPlanner.plan` | 准确 | `SearchEngineImpl.swift:1928-1930` 结果只进 `perf?.addReason`，路由在 `:1932-1941` |
| `MarkdownRenderDiagnostics` 无读取者 | 准确 | 全仓没有读取 `MarkdownRenderOutput.diagnostics` 的代码；测试里的 `.diagnostics` 属于 `StartupFailure` 与 `SearchPlan` |
| `testShortQueryUsesCache` 零断言 | 准确 | `SearchServiceTests.swift:742-758`，结尾 `print` |
| `Makefile:481-485` 误放的 echo | 准确 | 见 A33 |
| `axat.swift` 未编译、`mouseloc.swift` 编译但无人调用、`verify_hover_preview.sh` 依赖不存在的 `build/axat` | 准确 | `build-tools.sh:6` 列表含 `mouseloc` 不含 `axat`；`verify_hover_preview.sh:24` |
| `verify:assets:checked-in` 仅此一处 | 准确 | `Tools/MarkdownRenderer/package.json:10` |
| `render.js:38-42` 多余第三参数 | 准确 | `render()` 传 `(source, policy, 0)`，`renderInternal(source, policy)` 只收两个 |
| 无 setter 的环境变量（6 个） | 准确 | `SCOPY_TEST_RUN_ID`、`SCOPY_UITEST_PNGQUANT_EXPORT_DEFAULTS`、`SCOPY_UITEST_MARKDOWN_LAYOUT_SCALE`、`SCOPY_EXPORT_TEST_MARKDOWN`、`SCOPY_MOCK_THUMBNAIL_SIZE`、`SCOPY_RENDER_ID__` 在 tests/scripts/Makefile/CI 中 0 处设置 |

结论：抽查 17 项，15 项准确，1 项不完整（`fetchAllSummaries` 两份都死），1 项不准确（`buildDate` 仍在使用）。审计的 Phase 1 可以执行，但执行者须按本表修正这两项。

### 5.3 审计未列、本评审发现的同类项

| 项 | 证据 | 建议 |
| --- | --- | --- |
| `schema_version` 表只写不读 | `SQLiteMigrations.swift:72-80`；全仓无读取 | 删除建表语句与"backward compatibility"注释（C8） |
| `scripts/quality/record-gate-result.py`（668 行）只剩自测这一个消费者 | 唯一调用 `Makefile:285`（自测）；v0.7.7（2026-05-07）后发布证据改由 `release-current.yml` 的 `verification:` 记录 | 删除脚本、`make quality-manifest-self-test` 与 development-guide.md:226、maintainer-guide.md:53 两行；需 hh 确认该清单格式已被取代 |
| 82 个兼容符号链接 | 见 A8 | M2 / D9 |
| `StorageService.StoredItem` typealias | `StorageService.swift:126` | R5 |
| 3 个 ad hoc `Logger` 与 1 处 `NSLog` | 见 A10 | M10 |
| `make clean` 删除已跟踪的 `Scopy.xcodeproj` | `Makefile:60`；`git ls-files Scopy.xcodeproj` 4 个文件 | 改为只清 DerivedData 与 `.build` |
| app target 里 33 个无意义的 `public` | `PerformanceMetrics.swift`、`AppVersion.swift` | 按 §4.2 去掉 |
| `perf-audit.sh` 与 D4、审计 §3.1 的耦合 | `scripts/perf-audit.sh:171-177` | 见 D4 |
| D3 的约 3,870 行工具链 | 见 D3 | 见 D3 |

## 6. AGENTS.md / CLAUDE.md 修订稿

### 6.1 判断

- 整体清楚且足够短（AGENTS.md 51 行、CLAUDE.md 5 行），不需要重写。问题集中在 5 句：两条性能门禁与实际发版记录不符（A25、A26）；"explicit access control" 被 185 处声明违反且无法检查（A28）；源码目录不全（A27）；发布技能路径对 Claude Code 不可见（A29：技能在 `.agents/skills/`，`.claude/skills/` 为空，本会话的可用技能列表里也没有 `scopy-release-homebrew`）。
- "Remove obsolete paths instead of adding compatibility layers" 在代码侧被执行，在文档侧没有（82 个别名链接），补一个 "aliases" 让规则明确覆盖文档路径。
- D7 以一句话并入 Working Agreement。
- 渲染器那两条（AGENTS.md:25-27）术语密集，但归渲染面负责，本文不改。

### 6.2 AGENTS.md（diff，勿直接应用，需 hh 认可 D7 与门禁措辞）

```diff
@@ ## Working Agreement
-- Choose the simplest implementation that fully meets current requirements. Remove obsolete paths instead of adding compatibility layers, speculative abstractions, or temporary replacements. Keep concerns modular and each increment working end to end.
+- Choose the simplest implementation that fully meets current requirements. Remove obsolete code and document paths instead of adding compatibility layers, aliases, speculative abstractions, or temporary replacements. Keep concerns modular and each increment working end to end.
+- Do not merge code whose only consumer is a test (other than a `#if DEBUG` `…ForTesting` seam), an environment variable that nothing sets, or a finished experiment; experiments and A/B switches stay on branches. Tests must be able to fail on a real regression: no print-only, timing-only, or assertion-free tests.
@@ ## Sources Of Truth
-- [product-spec.md](doc/current/product-spec.md) owns product behavior; [architecture.md](doc/current/architecture.md) owns module boundaries and data-safety invariants; [development-guide.md](doc/current/development-guide.md) maps changes to runtime entrypoints.
-- `project.yml` owns Swift, deployment-target, and Xcode baselines. Do not change them without an explicit requirement. Newer system APIs need availability handling encapsulated at the component boundary.
+- [product-spec.md](doc/current/product-spec.md) owns product behavior; [architecture.md](doc/current/architecture.md) owns module boundaries and data-safety invariants; [development-guide.md](doc/current/development-guide.md) maps changes to runtime entrypoints and owns the code conventions and glossary.
+- `project.yml` owns Swift, deployment-target, and Xcode baselines, and `Package.swift` must match them. Do not change them without an explicit requirement. Newer system APIs need availability handling encapsulated at the component boundary.
@@ ## Validation By Change Scope
-| Frontend performance | `make perf-frontend-profile` smoke; standard recommended before commit, full required before release |
-| Performance conclusions | `make perf-unified-table`; record environment, scenarios, actual numbers, and causal limits in the runbook or its linked evidence |
+| Frontend performance | `make perf-frontend-profile` as a regression smoke; `make perf-frontend-profile-full` before a release that changes frontend code. It measures callback cadence, not hitches |
+| Performance claims | Measure the claimed path on a Release build: `make perf-scroll-wheel`, `make perf-search-type`, or `make perf-capture` for interaction latency; `make test-snapshot-perf-release` for backend search. Use `make perf-unified-table` only when combining `perf-audit` and frontend-profile output. Record environment, scenarios, numbers, and causal limits in the release note or a study under `doc/perf/studies` |
@@ ## Build And Release Entry Points
-- Source and tests live in `Scopy/`, `ScopyTests/`, and `ScopyUITests/`; `Package.swift` and `project.yml` define module ownership. Use Swift with four-space indentation, explicit access control, and names matching types.
+- Swift sources live in `Scopy/` (app and ScopyKit), `ScopyUISupport/`, `ScopyTests/`, `ScopyUITests/`, `ScopyTestHost/`, and `Tools/ScopyBench/`; the Node renderer lives in `Tools/MarkdownRenderer/`. `Package.swift` and `project.yml` define module ownership. Use four-space indentation and the development guide's code conventions (one primary type per file, `public` only on ScopyKit API, English comments).
@@
-- For an authorized release, follow [release-runbook.md](doc/current/release-runbook.md) or the repository `scopy-release-homebrew` skill. Version authority is an explicit Git tag, never commit count. …
+- For an authorized release, follow [release-runbook.md](doc/current/release-runbook.md); the `scopy-release-homebrew` skill (`.agents/skills/scopy-release-homebrew/SKILL.md`) only points to it. Version authority is an explicit Git tag, never commit count. …
```

若 D3 选择退役 A/B 装置，"Frontend performance" 一行不变；若 hh 采纳架构评审 §8.7 把热键日志移出 `/tmp`，"Hotkeys" 一行须同批改路径。

### 6.3 CLAUDE.md（diff）

```diff
 Shared repository instructions live in `AGENTS.md`. Read task-specific canonical documents through its links; keep product rules and workflows in their owning documents instead of duplicating them here.
+
+Repository skills live in `.agents/skills/`, which Claude Code does not load automatically; when a task matches a skill's description, read its `SKILL.md` directly.
```

## 7. 明确不做；需要 hh 决定的事项；实施顺序

### 7.1 明确不做

- 不给巨型文件的拆分方案（归前端、后端、流水线三面评审）；本文只提供 §4.2 的拆分约定与"内嵌 CSS/JS 不算 Swift 行数"的度量口径。
- 不为改名而改名：`SearchEngineImpl`、`generation` 的两种用法、`ScrollCursorSetCoalescer`、SwiftUI `Coordinator` 均不改。
- 不设计本地化方案，只列 D11 的选项；不重新提出 ⏎ 语义、保留全部剪贴板内容、原文/规范文本分离（冻结）、滚动天花板、固定预览等已裁决事项。
- 不改历史文档（release notes、reviews、`doc/archive`，taxonomy 规定只追加）；只改 canonical 文档、门户与本仓库的配置注释。
- 不扩展文档校验器去核对代码事实；校验器只在 D8 选择"保留字段"时加最小检查，另加 M4 的模块归属自测。
- 不重复卫生审计的删除清单；§5 只修正它的两处错误并补充漏项。
- 不改样式契约内容（A35 只标记给渲染面）。

### 7.2 需要 hh 决定

| # | 决定 | 建议 |
| --- | --- | --- |
| D1 | UI 测试 harness 与 mock 是否进 Release | `#if DEBUG` + mock 移到 app 侧（以 D3 退役为前提） |
| D2 | 测试接缝收口 | 同意审计；统一 `…ForTesting` + `#if DEBUG` |
| D3 | 11 个 `PerfFeatureFlags` | 全部折叠，退役 A/B 装置（约 3,870 行工具链）；`perf-frontend-profile` 改为单变体、跨提交对比 |
| D4 | `PerformanceTests.swift` | 整文件删除，同时收缩 `perf-audit.sh`；需要的数字迁到 ScopyBench |
| D5 | `formatBytes` 统一 | 同意，用 `ByteCountFormatter`，接受可见文本变化 |
| D6 | perf-scroll 研究工具 | 删除；保留 WACZ 分析脚本 |
| D7 | AGENTS.md 增加 PR 检查 | 同意，按 §6.2 写成一句 |
| D8 | frontmatter 的 `last_reviewed` / `related_versions` / `owner` / `canonical` | 删除（无消费者，7/14 已漂移），只留 `doc_type` 与 `status`；备选是在 `validate-docs.sh` 中校验 |
| D9 | 82 个兼容符号链接 | 删除（M2） |
| D10 | 6 个已实施或过时的 proposal | 移到 `doc/archive/proposals/`（或删除） |
| D11 | UI 字符串语言 | 产品决定；选项见 §3.2 第 4 条，本文不给建议 |
| D12 | `CHANGELOG.md` 语言 | 从下一版起英文，与 release note 一致；历史不改 |
| D13 | "pin" 预览改称 detached preview | 代码与 product-spec 改名（R3）；预览按钮与"保持最前"是否继续用图钉图标由 hh 定 |

### 7.3 实施顺序

每一步单独提交、可单独回滚；门禁按 AGENTS.md 表。

1. **M1（不依赖任何决定的文档修正）**：A1-A6、A9、A11、A12、A13-A21、A24、A27、A30、A31、A33（v0.md 两处）、A34。门禁：`make docs-validate`。
2. **M2（D9）**：删除 82 个符号链接与 doc/README.md "Compatibility" 节，改写 A8；同批改 `project.yml` 注释并删除 `Models/**`、`Protocols/**` 死条目（A32）。门禁：`make docs-validate`、`make test-tooling`；`project.yml` 变动会触发重新生成，追加 `make build`，若已跟踪的 `project.pbxproj` 有差异一并提交。
3. **M4**：约定写入 development-guide（§4.2）并加入模块归属自测。门禁：`make test-tooling`、`make docs-validate`。
4. **hh 决定 D3 → D1 → D4 → D2/D5/D6**，按审计 Phase 1/2 执行（先修正 §5.2 的两项）；随后更新受影响的文档行（A7、A10、A25、A26 与 development-guide:210、:226）。门禁按审计 §7。
5. **M3**：AGENTS.md / CLAUDE.md 按 §6 修订（依赖 D3、D7 的结论）。门禁：`make docs-validate`。
6. **M5 改名 R1-R6**（在审计删除 `SearchPlanner.plan` 与 `MarkdownRenderDiagnostics` 之后）。门禁：`make build`、`make test-unit`；R1 触及搜索证据，加 `make test-strict`；R4 触及渲染器，跑渲染器门禁；R3 改无障碍标识符，UI 测试在本机常被 testmanagerd 阻断，须如实记为 environment-blocked 或在可用环境补跑。
7. **M6 注释统一**（改名之后，注释才能引用最终名字）：ScopyKit 与 app 各一个提交，含 §3.3 的 15 处修正与 C8 的建表删除。门禁：`make build`、`make test-unit`（C8 改了 SQL，属功能改动）。
8. **M7-M10**：D8、D10、D12 落地；`make help` 在 D3/D4/审计 §4.1 的目标删除之后一次性重写；日志类目收敛。门禁：`make docs-validate`、`make test-tooling`；M10 触及产品代码加 `make build`、`make test-unit`。

本文件被接受后，需在 `doc/proposals/README.md` 的 "Current Contents" 中加入一行链接（本评审按规则未修改该文件）。
