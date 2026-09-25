---
doc_type: proposal
status: draft
owner: hh
created: 2026-09-24
audience: maintainer decision + implementing agent
---

# Scopy 评审与改进路线图（2026-09-24）

基线：`407f7db`（v0.81.0）。本文是总纲：定方向、排顺序、裁冲突、列出需要 hh 一次决定的事项。证据与逐项设计在五份分面提案里，每条都有 HEAD 的 `file:line`：

| 面 | 提案 | 编号前缀 |
| --- | --- | --- |
| 前端交互性能与体验 | [frontend-interaction-review-2026-09-24.md](./frontend-interaction-review-2026-09-24.md) | F0–F14 |
| 后端搜索、存储、并发、生命周期 | [backend-search-storage-review-2026-09-24.md](./backend-search-storage-review-2026-09-24.md) | B1–B8 |
| 采集与 Markdown 预览/导出流水线 | [capture-and-markdown-pipeline-review-2026-09-24.md](./capture-and-markdown-pipeline-review-2026-09-24.md) | C1–C3、R1–R4（本文写作 P-R1…）、E1、W1 |
| 可维护性、命名、文档准确性 | [maintainability-and-docs-review-2026-09-24.md](./maintainability-and-docs-review-2026-09-24.md) | M1–M10、D8–D13 |
| 回归防护网 | [regression-safety-net-2026-09-24.md](./regression-safety-net-2026-09-24.md) | R1–R15 |

前两份评审的关系：[architecture-review-2026-09.md](./architecture-review-2026-09.md)（2026-09-03）的 39 条方向中，已实施、已否决或证据不再成立的条目由各分面提案逐条标注；[code-hygiene-audit-2026-09-19.md](./code-hygiene-audit-2026-09-19.md) 的删除清单继续有效，本文只修正它的三处错误（§4）。

## 0. 结论

1. **性能剩下的是两个交互成本和一个生命周期问题，不是算法。** 搜索打字每键主线程阻塞 90–180 ms，在 HEAD 可逐行定位为四个乘数的叠加（每键两次发布、整组替换、"相同 refine"与分页变更仍重跑整张 List、零结果时卸载 List）；hover 呈现的 65–156 ms 是 popover 窗口同步自适应尺寸；一次搜索会话后内存 +100 MB 不回落，其中约 50 MB 是从不释放的全量索引与最近缓存。三者都有可独立提交的 S/M 级设计，验收指标是现有工具已能输出的数字。
2. **正确性方面没有新的 P0 数据风险，但有三个 P0 级体验/基线缺陷**：搜索框里按 ⌥⌫ 会删除悬停选中的条目且无撤销（F8）；键盘导航会命中折叠后看不见的置顶行并静默复制/删除（F9）；Scopy 自己写入 pasteboard 后可能被重采，最坏产生一条指向内部存储文件的 `.file` 行（C1）。
3. **门禁比代码更需要修。** `make test-strict` 从不失败；真实 UI 与 PNG 导出断言在任何地方都不运行；AGENTS.md 验证表里两条性能行本机不可执行且测的是 flag 差异；canonical 文档有 35 处与 HEAD 不符，其中 12 处是事实错误（例如分页 500 实为 100），执行型代理会照着错误契约把代码"修回去"。这些全是 S 级改动，应最先做。
4. **结构收敛有明确的缝，但顺序要对。** `SearchEngineImpl`（5,241 行）、`ClipboardMonitor`（2,728）、`MarkdownHTMLDocumentBuilder`（2,871）、`MarkdownExportService`（2,810）、`HistoryItemView`（2,174）各有分解方案；每一步都要求"行为不变 + 先有守护测试"。卫生审计里"把引擎的平行 SQL 层合并进 repository"方向反了：repository 那五个查询全仓零调用，该删的是它们。
5. **可读性的债务集中在语言与少数误导性名字。** 45 个文件含中文注释、canonical 文档英文、changelog 中文、UI 中英混合；真正误导读者的名字只有六处（如 `isPrefilter` 对"只搜最近 2,000 条"也为真、`SearchPlanner` 不参与路由）。代码注释统一英文可以直接定；UI 语言是产品决定。

## 1. 不变的前提

- hh 的 7 条硬约束：不留向后兼容层、最简实现、纵切交付、模块化、成熟库优先、先查现有能力、按长期架构合入。五份提案末尾各自逐条对照过。
- 已裁决、不再讨论：⏎ = 复制并关闭；保留所有剪贴板内容；原文/规范文本与按表示去重冻结待 data epoch；`</head>` 导出缺陷不成立；滚动性能已到天花板；固定预览已实施；pngquant 已重建。
- 已测得、直接采用：热键到面板、点击复制、冷启动、方向键、删除、滚动都已健康；后端快照门禁 cmd p95 0.53 ms。
- 分面提案的收益数字除注明外都是读代码推算的假设，每条都写了取证工具与通过阈值；实施时先测基线再改。

## 2. 分面提案对旧结论的修正（跨面一致性）

| 旧结论 | 修正 | 依据 |
| --- | --- | --- |
| 架构评审 §4.4：VACUUM / auto_vacuum / 定时 checkpoint 是 P0 | 证据不成立：快照空闲页 0.56%，系统 SQLite 默认已限制 WAL；缺的是发现损坏（B6） | 后端 §1.5 |
| 架构评审 §8.7：57 处 `.private` 改 `.public` | 否决：引擎错误串会回显查询文本；改为公开记录 SQLite 结果码 | 后端 B6 |
| 架构评审 §6.3：两套 WebView 生命周期 | 不成立：hover 与 pinned 共用 controller 与租约；多出来的是生产不可达的一次性 WebView（W1 删） | 流水线 §1.5 |
| 架构评审 §5.7 / dev-guide:154：相同 refine 是 no-op | 只修了一半：跳过路径仍写分页状态，整张 List 仍重跑 | 前端 F2，主线程核实 `HistoryViewModel.swift:1583` |
| 2026-09-03 否决"每键一次发布"（需要 deadline race） | 重新提出：两个 MainActor 任务共享一个带版本号的槽，8 个分支可枚举成单测 | 前端 F3（需 hh 决定） |
| 卫生审计 §6：合并引擎的平行 SQL 层进 repository | 方向反了：repository 的 `searchWithFTS`/`searchAllWithFilters`/`ftsPrefilterIDs`/`fetchItemsByIDs`/`fetchAllSummaries` 全仓零调用，应删除 | 后端 B3-D0，主线程核实 |
| 卫生审计：`verifySchema` 少检 `ingest_receipts` 是潜在 bug | 不是：引擎从不读该表；该统一的是引擎只接受当前 `user_version` | 后端 §0 |
| 卫生审计：删 `AppVersion.buildDate` | 错：About 页仍用；只能删 `versionWithDate` | 文档 §5.2 |
| 卫生审计：删 `ScopyLog.persistence` | 保留：B6 用它记录 SQLite 结果码 | 后端 B6 |
| 契约与 AGENTS.md："预览与导出共享 parse result" | 措辞不准：两边加载同一输入、同一 bundle 各自解析，靠确定性得到同一结果；改措辞不改代码 | 流水线 §0 |
| product-spec:80 / dev-guide:94 禁止隐藏预测量 | 与 dev-guide:153 及 prewarm/probe 代码硬冲突；建议保留代码、改规格措辞（K7，需 hh 定） | 流水线 §1.6 |

## 3. 执行阶段与总优先级

> 本节是第一版排序，保留为分面提案的索引；**执行顺序以 §9.5 为准**，与 §9.3 冲突处以 §9.3 为准。

规模：S ≤ 半天，M 1–3 天，L 一周以上。每条单独提交、可单独回滚；门禁按 §5。

### Phase 0：让门禁、文档和工具说真话（全 S，零行为变化，不等任何决定）

| # | 改动 | 收益 | 守护 |
| --- | --- | --- | --- |
| R1 + M1 | 重写 AGENTS.md 验证表（删本机不可执行的两行，补 UI/内存/采集/导出四行）；修正 canonical 文档 35 处（含分页 100、`SearchPlanner` 不路由、`isPrefilter` 语义） | 代理不再按错误契约改代码 | `make docs-validate` |
| R2 | 先修掉 4 条 Swift 6 诊断，再让 `make test-strict` 遇到新诊断失败 | 并发改动首次有能失败的闸门 | CI + 本机各跑一次 |
| R3 | 把 Save images/files 与轮询测试放回 test-unit / strict / TSan；删 `test`、`coverage`、`benchmark`、`test-integration` | 产品设置首次进 CI；去掉会弄挂 testmanagerd 的入口 | `make test-unit` |
| F0 + R5a | `profile_search.py` / `profile_capture.py` 拷贝 v5/v3 索引缓存；打印 `list.body` 与发布次数 | Phase 1 的前后对比可信 | `make perf-search-type` 冒烟 |
| B3-D0 | 删 repository 五个死查询、只喂诊断的 `SearchPlanner.plan`、`MarkdownRenderDiagnostics` 及卫生审计 §1.1 其余运行时残留 | 每键与每次渲染少做无人读的工作 | build、unit、strict |
| P-R1 | 默认 profile 跳过 protector 往返；protector O(L²) → O(L) | 长行 Markdown 渲染省数十到数百毫秒，输出逐字节不变 | 等价测试 + `npm test` |
| W1 | 删生产不可达的一次性 WebView 与死探针；WebView 配置收成一个工厂 | 只剩一套 WebView 生命周期 | build、unit、真实 PNG 目视 |

### Phase 1：可测量的交互性能、内存与 P0 体验（两条并行线）

**线 A：性能（先 R6 协议与 `ab.py`，先测 A/A 噪声底）**

| # | 改动 | 目标 | 依赖 |
| --- | --- | --- | --- |
| R4 | 列表发布次数测试（每键 1 次、相同 refine 0 次） | 先于 F1–F4 落地，F 系列每步不得使其变红 | F0 |
| F1 → F2 → F3 → F4 | 空结果不卸载 List；行级证据扇出 + 观察拆分；每键一次发布（需决定）；可见行优先分块替换 | 每键主线程最长阻塞 < 50 ms；List 更新 ≈1.5 → 1.0 次/键 | R4；F3 需 hh |
| F5 → (F6) | hover 呈现状态扇出、呈现前冻结尺寸、QuickLook 移出首帧；仍 > 50 ms 才做 AppKit popover 宿主 | 单次呈现停顿 < 50 ms；呈现后 resize 0 次 | F2 的扇出通道 |
| B1 | 清理提交按删除集维护索引，删回调计数器 | 条目达上限后不再每分钟整套重建索引 | 无 |
| B2a → B2b → B2c + F7 | postings 改 32 位；会话空闲释放全量索引并从磁盘回填；内存压力响应；hover 位图随面板关闭释放 | 关面板后 footprint 回到基线；空闲基线约 −12 MB | B1；B2b 阈值需 hh；R11 |
| C1 → C2 | 记录自写、每个 changeCount 只评估一次、单 Task 轮询加 tolerance；每次变化只读一轮 | 自写重采 0 次（先写在 HEAD 失败的测试）；纯文本复制少 3 次无结果读取 | 无；C1 突发轮询需 hh |

**线 B：P0 体验与卫生删除（不依赖测量，可并行）**

| # | 改动 | 依赖 |
| --- | --- | --- |
| F9 | 键盘导航、⏎、⌥⌫ 不命中折叠的置顶行 | 无 |
| F8 | 可撤销删除（5 s 单槽） | F9；语义需 hh |
| F10、F11、F12、F13 | 悬停改选中只在指针真实移动后；⌘1–9；面板记住尺寸；失败可见、去掉 Recent 段头遥测、状态栏右键菜单、Launch at Login | F10 需 hh 确认 |
| 卫生审计 Phase 1 | 按审计 §7 四个 commit 执行，先套用 §4 的三处修正 | D3 决定后再做 D1/D4 |
| M2 + M9 | 删 82 个兼容符号链接与 doc/README 的 Compatibility 节；Makefile `help`/`.PHONY`/错位 echo | D9 |

### Phase 2：结构收敛（每步先有守护测试，行为不变）

| # | 改动 | 前置 |
| --- | --- | --- |
| B4 | `StorageService` 由 `@MainActor` 改 actor，清理与删除的文件系统调用移出主线程 | R10（退出路径测试形状）；strict 可失败 |
| B5 | 存储根单写者守卫 | 第二实例行为需 hh |
| B3 D1–D6 | `SearchEngineImpl` 按查询规划 / SQL 访问 / 内存索引 / 磁盘缓存 / 证据 / 诊断分解；SQL 列清单与行解码下沉 Persistence | B3-D0；每步 golden SQL 测试 |
| R9 → P-R3(1–4) | 先加 Swift→渲染器输入黄金文件，再让 Swift 只做判定、JS 做全部源改写 | P-R1 |
| C3 | ingest 串行有序、回放按创建时间、TIFF 真实扩展名、`ClipboardMonitor` 拆分 | C1、C2；并行度 3→1 需 hh |
| F14 | `HistoryViewModel`/`HistoryItemView`/Pipeline/Coordinator 按缝拆分，搜索状态机脱离 SwiftUI | 随 F1–F5 触及时顺带 |
| M4 + M5 + M6 | 结构约定写入 dev guide 并加模块归属自测；只做六处误导性改名；注释统一英文、删 98 行版本流水账 | 改名在 B3-D0 之后；注释在改名之后 |
| R13 | 测试按面分目录，删 `AppStateTestCompatibility` 门面，9 个替身收敛为 1–2 个 | 上述拆分之后一次做完 |

### Phase 3：长尾与需决定的项

P-R4（文档外壳与 CSS 迁入渲染器包、CSP 收紧、182 个子串断言改结构断言）、E1（导出 settle 改推送、阶段与取消）、P-R3 步骤 5（科学 profile 迁 JS）、B6/B7/B8、R8（托管 CI 试跑 XCUITest）、R12/R14/R15、M7/M8/M10、D8/D10/D12/D13。

## 4. 冲突裁定（架构层）

- **卫生审计 vs 回归防护的观测点**：审计要删的 hover 阶段日志、磁盘缓存命中日志、`hoverstall`/`panelwatch`/`enterlatency`、`HistoryRowPixelSnapshotTests`，恰是 R5/R7 的证据来源。裁定：保留这些（日志均为 info 级且不含正文），在 dev guide 登记为证据消费者；已坏的 `verify_hover_preview.sh`/`axat` 按 R7 修复而不是删除；其余研究脚本按 D6 删除。
- **D1 依赖 D3**：只要 D3 退役 Release 配置下的 A/B 装置（约 3,870 行工具链随之退役），D1 就退化为 `#if DEBUG`，不需要新的编译条件。建议先决定 D3。
- **索引截断 vs 规格**：B2 的"每条只索引前 N KB"会改变 fuzzy 召回，与 product-spec 的"Fuzzy 收敛到完整结果"冲突。裁定：默认不截断；B2b 的会话释放已能拿到主要收益。
- **隐藏预测量**：保留 prewarm/probe 代码（有就绪门控且是 v0.80.x 有意实现），修改 product-spec:80 与 dev-guide:94 的措辞为"不得在无就绪门控的情况下隐藏预测量"。待 hh 确认（K7）。
- **hover 位图缓存上限**：不下调（与 64 Mpx 解码预算冲突），改为随面板关闭释放（F7），采前端方案。
- **工作树里的 `SCOPY_EXP_OPAQUE_ROWS` 实验**：研究结论已归档，建议丢弃这 17 行改动；这是 hh 的工作树，本轮未触碰。

## 5. 验证协议

- 每类改动的最少门禁以回归提案 §1.5 的表为准，并在 Phase 0 用它替换 AGENTS.md:31-41。
- 性能结论按回归提案 §4：先 A/A 测噪声底，ABBA 交错，热库副本并记录快照 SHA-256，`SCOPY_SCROLL_PROFILE` 开关状态、环境、场景、实际数字与因果限制一并记录；不建 `make perf-gate`。
- UI 改动在本机按回归提案 §5：直接启动 + AX + `CGWindowList` + 私有 pasteboard + 日志计数；XCUITest 被系统认证挡住时如实记 environment-blocked，不得记 pass。
- 触及渲染链的每个提交都做一次真实 App PNG 目视，并在提交信息里写明跑了哪些门禁、哪些被环境拦住。

## 6. 需要 hh 一次决定的事项

> 本表是第一版平铺；**决策分级以 §9.7 为准**（阻塞项只剩 4 项，其余按建议默认执行）。

| # | 决定 | 建议 | 影响的条目 |
| --- | --- | --- | --- |
| 1 | 丢弃工作树里的 `SCOPY_EXP_OPAQUE_ROWS` 实验 | 丢弃 | Phase 0 起点 |
| 2 | D3：11 个 `PerfFeatureFlags` 全部折叠、退役 A/B 装置与约 3,870 行工具链 | 折叠 | D1、perf-frontend-profile、卫生审计 Phase 2 |
| 3 | strict 门禁：修完 4 条诊断后"出现诊断即失败" | 失败 | R2 |
| 4 | 删 `make test` / `make coverage`（会拉起 XCUITest 弄挂 testmanagerd） | 删除 | R3 |
| 5 | F3：采纳"每键一次发布"（50 ms 截止槽，去掉瞬时提示行），推翻 09-03 否决 | 采纳 | Phase 1 线 A |
| 6 | F8：可撤销删除的语义（单槽 5 s；⌘Z 只在窗口内；⌥⌫ 在非空搜索框是否编辑文本） | 单槽 5 s；⌥⌫ 在非空搜索框只编辑文本 | F8 |
| 7 | F10：悬停改选中只在指针真实移动后（细化 product-spec:156） | 采纳 | F10 |
| 8 | F5：文件预览 hover 用静态 QuickLook 图，实时视图只在固定窗口 | 采纳 | F5 |
| 9 | B2：全量索引空闲释放阈值（默认 60 s）；不截断索引 | 60 s；不截断 | B2b、R11 |
| 10 | B5：第二实例启动即失败并提示；开发时 Debug 用 `SCOPY_SERVICE_DB_PATH` | 失败并提示 | B5 |
| 11 | C1：是否启用突发轮询（设置项语义变为"空闲间隔"） | 不启用，先做基线修复 | C1 |
| 12 | C2：HTML > 4 MiB 且有纯文本时跳过主线程 WebKit 导入 | 采纳 | C2 |
| 13 | K7：隐藏预测量以代码为准、改规格措辞 | 改规格 | M1、F5 |
| 14 | D1：UI 测试 harness 与 mock 用 `#if DEBUG` 并移到 app 侧 | 采纳（D3 之后） | 卫生审计 |
| 15 | D4：整文件删除 `PerformanceTests.swift` 并收缩 `perf-audit.sh` | 采纳 | 卫生审计 |
| 16 | D5：`formatBytes` 统一到 `ByteCountFormatter`，接受可见文本变化 | 采纳 | 卫生审计 |
| 17 | D6：删除 perf-scroll 研究工具但保留 §4 裁定的观测点与 WACZ 分析脚本 | 按 §4 | R5、R7 |
| 18 | D9：删除 82 个兼容符号链接 | 删除 | M2 |
| 19 | D8：删除 frontmatter 的 `last_reviewed`/`related_versions`/`owner`/`canonical` | 删除 | M7 |
| 20 | D10：6 个已实施或过时的 proposal 移到 archive | 移到 archive | M8 |
| 21 | D11：UI 字符串语言（全英 / 全中 / xcstrings 跟随系统） | 产品决定，本文不建议 | 本地化 P0 |
| 22 | D12：CHANGELOG 从下一版起英文 | 采纳 | 发布流程 |
| 23 | D13："pin" 预览在代码与规格中改称 detached preview | 采纳；图标由 hh 定 | M5 |
| 24 | R8：托管 CI 试跑 XCUITest（先 workflow_dispatch） | 先 spike | 门禁 |
| 25 | B8：退出时 `.terminateLater` 等最多 1 s 落盘索引缓存 | 不做，继续暂缓 | B8 |
| 26 | C3：监控器并行度 3 → 1 以换取顺序正确 | 采纳 | C3 |
| 27 | P-R3 步骤 5：科学 profile 1,726 行 Swift 规范化迁到 JS | 排在 P-R4 之后再定 | Phase 3 |
| 28 | About 页诊断去留、Quit 是否移到状态栏菜单、固定窗口逐条目记忆 | 诊断折叠；Quit 两处都留；不做逐条目记忆 | F13 |

## 7. 明确不做

- 滚动优化、换 NSTableView、固定行高、加大搜索防抖或缩小首页。
- ⏎ 粘贴与任何回贴服务；按隐私标记跳过采集；原文/规范文本分离与按表示去重；`hash_version`、双读、legacy decoder。
- VACUUM/定时 checkpoint、提高 `busy_timeout`、repository 语句缓存与只读连接、六个 continuation 队列收敛、把引擎 SQL 搬进 repository actor。
- 采集大小上限、锁屏/睡眠门控、持久宿主页、暗色主题、WebView 懒创建。
- 带阈值的 `make perf-gate`、CI 黄金截图、第三方测试框架、覆盖率门槛、CI 中跑真实输入 perf 脚本。
- 为改名而改名；扩展文档校验器去核对代码事实。

## 8. 环境与方法说明

五份分面评审均为只读：没有构建、跑测试、跑 perf 脚本或启动 app，工作树的未提交改动未被触碰。主线程对每份提案抽查了至少两条与旧文档相反的结论并在 HEAD 代码中证实。本文与五份提案在 `make docs-validate` 下链接可达；`doc/proposals/README.md` 的索引行由本轮补充。

## 9. 终审（2026-09-24，主线程 + 第二方复核）

### 9.1 方法

- 主线程（Claude）通读五份提案全文，逐份至少两条与旧文档相反的结论在 HEAD 代码中核实（§8）。
- 第二方（Codex CLI，`gpt-6-astra`，reasoning `xhigh`，只读沙箱）独立复核六份文档，给出逐项判定、五个新发现（N1–N5）和自己的前 12 项；主线程对其新发现逐条在代码中核实后，与它做了一轮对辩（§9.4）。
- 各分面提案顶部的 "0.1 终审修正" 记录了对该面的最终裁定，优先于其正文。

### 9.2 Codex 新发现（主线程已核实）

| # | 发现 | 证据 | 处理 |
| --- | --- | --- | --- |
| N1 | 手动删除与清空直接删文件，不复用 cleanup 的"仍被幸存行引用则不删"协议 | `SQLiteClipboardRepository.swift:464, 493`；`StorageService.swift:1073-1095`；安全协议在 `:1962-1988` 与测试 `testCleanupDoesNotUnlinkCommittedRefStillOwnedBySurvivingRow` | **撤回 P1**：Codex 第二轮追踪全部生产路径（新采集生成 UUID 路径、去重只更新 usage、优化提交生成新路径、CAS 只改同一行；`updateItemPayload` 的调用者只有测试），未找到共享 `storage_ref` 的生产者。降为防御性一致性观察 B9（P2，随 B4 顺带让两条删除路径复用同一协议） |
| N2 | 写入无上限、读取固定拒绝 > 100 MiB 且错误被吞：存得进、读不出 | `StorageService.swift:2238, 2290-2291` | 新增 B10（P1，S）：修正读写契约、保留错误原因 |
| N3 | 搜索失败被显示为"无结果"：失败分支清空 projection 并把 coverage 设为 `.complete` | `HistoryViewModel.swift:1154-1157`；`EmptyStateView` | 新增 F15（P1，S）。精确语义：用户首轮搜索失败→清空并标 `.complete`（No results）；事件刷新失败→保留旧行标 `.incomplete`（Regex/短 Exact 的范围提示会遮住 Partial）；首次 `load()` 失败→只记日志显示 No items yet；`load()` 行已发布但 stats 失败→行在、Footer 0 items、不能分页；`loadMore()` 失败→只记日志；强制 refine 失败→可能一直显示 Calibrating。修复须区分这些终态并提供重试，不是一条通用 toast |
| N4 | 导出取消后仍重建 WebView 与隐藏窗口：启动 Task 未保存，`await ruleList()` 之后不复查终态 | `MarkdownExportService.swift:889, 895, 905-954` | 新增 E0（P1，S），先于 E1 的取消按钮 |
| N5 | 验证与测量脚本 fail-open：`build-tools.sh:7` `\|\| true`、`verify_row_click.sh:22, 25` 空输出即 OK、`profile_search.py:109, 127`、`profile_capture.py:135-150` | 同左 | 并入 Phase 0 的工具修复（R5 前置） |

### 9.3 终审裁定（取代 §3/§4 中与之冲突的内容）

| 条目 | 原案 | 裁定 | 理由 |
| --- | --- | --- | --- |
| F3、F4 | Phase 1 主线 | **条件项**：F1 + 缩小的 F2 后按 `--reuse-db` 复测，单键阻塞仍 ≥ 50 ms 才重新设计；F4 若重启用常量首块并解决尾块选中项不在 `items` 的问题 | Codex 指出 F3 慢 refine 仍两次发布、F4 与 `selectCurrent()` 冲突，且与 R4 互相矛盾 |
| R4 | 每键恰好一轮发布 | 改为"过期版本不发布、行与证据同轮到达、相同 refine 零失效" | 同上 |
| B1 | 用 `known == current` 判定"全部观察到" | 先做"每笔提交一次通知并携带 `mutation_seq`，缺口即失效"，再做批量增量删除 | 置顶两次回调之间的未通知提交会被误认（`SearchEngineImpl.swift:1729-1735`） |
| B2b | released + pending 回放 | 紧凑化 + 空闲释放到 `.absent` + 现有加载/重建路径；先测 DB 重建耗时 | 硬约束 2/3；主线程与 Codex 一致 |
| B3-D3 | `user_version` 一致即结构完整 | 引擎显式检查所需表并明确失败 | 迁移在 trigram 不支持时仍写 9 |
| B5 | 锁在 `storage.open()` | 锁在 `ClipboardService.start()` 起点，早于 spool 准备 | spool 目录修改先于 open |
| C1 / C2 / C3 | 三次失败丢弃；4 MiB 跳过文本判定；无界队列 | 失败缓存 rawData 重试不丢弃；不做 4 MiB 分支；有界 FIFO 含小内容 | 分别触及保留语义、冻结的规范文本决策、背压 |
| F8 | 5 s 单槽撤销 | F8a（P0）按事件窗口与 first responder 修 ⌥⌫ 误删；F8b 撤销为产品 P2 | 误删修复不应等撤销设计 |
| F11、F13 菜单/登录、D13 | P1 / 本轮 | P2 / 本轮不做 | 产品新增不挤占正确性修复 |
| K7 | 以代码为准改规格 | 先实机验证 prewarm 的 paint-timeout 路径再定措辞 | 隐藏期间 1,500 ms watchdog 可能替换 DOM |
| D1 | 整体 `#if DEBUG` | mock 与 harness DEBUG 化；保留 `--uitesting` 自动导出这条 Release 真实 PNG 入口 | 回归验证依赖该入口 |
| M4 | 硬规则 | 指导；不禁止同模块 extension | 与 F14/B3 的逐步提取冲突 |
| P-R1 | 整体 O(L) | 只去掉已识别分配，收益实测 | 其余二次方路径仍在 |
| R2 / R3 表述 | strict "从不失败"；设置测试"从未运行" | "并发诊断未升级为失败"；"不在 unit/strict/TSan 门禁内" | 编译与测试失败会失败；本地 integration 有通过记录 |
| R2 机制 | grep 固定短语 | strict 变体的 `xcodebuild` 命令行加 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`（`Makefile:218` 附近），沿用 `pipefail` 退出码；首次实施验收 ScopyKit、ScopyUISupport、App 与测试 target 的实际 Swift 命令都含 complete 与 `-warnings-as-errors`。2026-09-04 日志的 110 条 warning 是 4 种并发消息的重复（4/40/40/23）加 3 条 AppIntents 工具警告，不是 110 个问题 | Codex 核实 `Swift.xcspec:1262`；历史 strict 构建日志证明 complete 已到达 ScopyKit（`-enable-upcoming-feature StrictConcurrency`） |
| R10 | B4 前置 | 只在采纳 B8 后需要 | 不在测试里引入未批准契约 |

### 9.4 对辩记录（三个争议点）

- **Phase 0 的位置。** Codex 把"修门禁与测量工具 + 文档纠错 + 死代码"排在第 7；主线程坚持它是第 1：全部 S 级、零行为变化、不需决定，且是后续每一项前后对比可信的前提；Codex 的正确性修复紧随其后作为 Phase 1a。（Codex 第二轮回应见 §9.6。）
- **`make test` / `make coverage`。** 主线程按硬约束 1 倾向删除（无 canonical 消费者、本机会弄挂 testmanagerd）；Codex 认为不必作为恢复覆盖的前置。两者不矛盾：删除是独立的 P2 卫生项，不阻塞 R3。
- **D3 连带工具链。** 主线程：`perf-warm-scroll-ab.sh`、`summarize-warm-scroll-ab.py`、`source-manifest.py`、`ScopyWarmProfile` 只服务 flag A/B，折叠后无消费者即删；`perf-frontend-profile` 改单变体。Codex 要求消费者驱动逐项确认。裁定：按消费者驱动，删除前 `rg` 逐个确认无其他调用者。

### 9.5 最终执行清单

**Phase 0（S，不需决定，立即开工；并非全部零行为变化：删 `SearchPlanner.plan` 改变诊断输出与工作量，修 strict 触发的代码未必机械——各提交按实际改动验证，性能基线在 Phase 0 之后重新取得）**

1. R1 + M1：重写 AGENTS.md 验证表、修正 canonical 文档 35 处（含 R2/R3 的准确表述）。
2. N5 + F0 + R5a：脚本 fail-closed；`profile_search.py`/`profile_capture.py` 拷贝 v5/v3 缓存；打印 `list.body`。（Codex 建议 Phase 0 内部顺序：工具 → strict/R3 → M1 → D0。）
3. R2：在 HEAD 重新收集并发诊断 → 修掉 → strict 变体加 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` 并验收各 target 的实际编译命令（§9.3）。
4. R3：Save images/files 与轮询测试回 unit/strict/TSan。
5. B3-D0 + 卫生审计 §1.1 运行时残留 + W1 + P-R1 步骤 ①（门控与删诊断）。

**Phase 1a（正确性，P0/P1，S）**

6. F9（折叠置顶区键盘错位）+ F8a（⌥⌫ 按窗口/first responder）。
7. B5（单写者锁，`start()` 起点，覆盖完整生命周期）。
8. C1 步骤 ①（自写基线、单次评估、失败缓存重试）+ C2 所有权边界 + C3 有界顺序（语义改动；八文件拆分另提交）。
9. B10（> 100 MiB 读写契约）+ F15（按 §9.2 的失败路径区分终态）+ F13 失败可见 + B6 结果码。
10. E0（导出取消竞态）。

**Phase 1b（性能与内存，先复测基线）**

11. 基线复测（`--reuse-db`，A/A 噪声底）→ F1 → 缩小的 F2 → 复测 → 决定 F3/F4 是否重启。
12. B1'（提交通知携带序号）→ B1 批量增量删除。
13. B4（StorageService actor）。
14. B2a → B2b 简化版 → B2c + F7（M1/M3/M4/M5，M2 压力响应）。
15. F5（H0 归因 → H1 → H2）+ P-R2（输入只算一次）；K7 实机验证后同步规格；F6 视复测结果。

**Phase 2（结构与长尾）**

16. C3 拆分（纯搬移）、回放排序、TIFF 扩展名；B9 防御性一致性随 B4 顺带。
17. R9 → P-R3 步骤 1–4；E1 步骤 1–2、4；P-R4 的 CSS/运行时外置与 CSP 收紧。
18. 卫生审计 Phase 1（D3 → D1 → D4 之后）；M2、M5（R1/R2/R4/R5）、M6、M9、M10。
19. B3 D1–D6（含 R6 改名）、B7、R13–R15、M7/M8；F14 随触及提取。
20. 产品项待 hh：F8b 撤销、F11、F13 菜单/登录、D11 本地化、D13。

### 9.6 Codex 第二轮回应（已收敛）

- **Phase 0 第一**：Codex 接受，未找到"先做 Phase 0 会损害正确性修复"的反例；修正措辞为"并非全部零行为变化"（已并入 §9.5）。
- **`make test` / `make coverage`**：Codex 同意删除且不留别名（两个目标直接跑含 UI tests 的 `Scopy` scheme，`Makefile:72, 237`；无独立消费者，`scripts/test-flow.sh:279` 只是提示文本）；同步 `.PHONY`、help 与 `test-flow.sh`。
- **D3 四项工具**：Codex 逐项核实后撤回保留意见：`perf-warm-scroll-ab.sh` 只接受两条 flag 轴（`:47, 408, 443`）、`summarize-warm-scroll-ab.py` 固定这两轴（`:19, 29, 40`）、`source-manifest.py` 的唯一工作流调用者是 warm-scroll runner（`:24, 356, 392`）、`ScopyWarmProfile` 只被该 runner 使用（`project.yml:20`）；`Makefile:289-290` 的自测是维护依赖。flag 折叠后删除四项并同步入口与文档。
- **N1**：撤回 P1（见 §9.2）。
- **N3**：维持 P1，按失败路径精确表述（见 §9.2）；另注明 `service.start()` 失败已有 Retry UI，漏掉的是启动成功后的 fetch/stats 失败。
- **R2**：选方案 (b)（见 §9.3）。
- **Codex 修订后的前 12 项**与 §9.5 一致：Phase 0 → F8a+F9 → B5 → C1+C2+C3 语义 → B10 → F15+F13+B6 → E0 → F1+缩小 F2（复测后定 F3/F4）→ B4 → B1′ → B2 简化 + F7 → F5 + P-R2（先验证 K7）。P-R1、W1、E1 小型冗余清理排在这十二项之后（本文把 P-R1 步骤 ① 与 W1 留在 Phase 0，因为它们无消费者且有等价测试；这是两者唯一的排序差异，不影响依赖关系）。

### 9.7 决策分级（取代 §6）

**阻塞执行的 4 项（需 hh 明确回答）**

| # | 决定 | 建议 | 阻塞什么 |
| --- | --- | --- | --- |
| 1 | 丢弃工作树里的 `SCOPY_EXP_OPAQUE_ROWS` 实验（17 行） | 丢弃 | Phase 0 起点（hh 的工作树，本轮未动） |
| 2 | D3：折叠 11 个 `PerfFeatureFlags`；只服务 flag A/B 的工具链按消费者驱动删除 | 折叠 | 卫生审计 Phase 1、D1、D4 |
| 3 | B5：第二实例启动即失败并提示；Debug 用 `SCOPY_SERVICE_DB_PATH` | 失败并提示 | Phase 1a #7 |
| 4 | F5：hover 的文件预览是否改为静态 QuickLook 图（实时视图只在固定窗口） | 采纳 | Phase 1b #15 的 H3 |

**按建议默认执行、hh 反对再改**：strict 出现并发诊断即失败；删 `make test`/`coverage`（独立 P2 卫生项）；F10 悬停改选中只在指针真实移动后（阈值实机定）；B2 空闲阈值 60 s、不截断索引；C1 不做突发轮询；C2 不做 4 MiB 分支（已裁定）；D1 mock/harness DEBUG 化并保留 `--uitesting` 导出入口；D4 先移植独有场景到 ScopyBench 再删；D5 `ByteCountFormatter`（复用 `Localization.swift:6`）；D6 消费者驱动删研究工具、保留观测点与 WACZ 脚本；D8 删无人维护的 frontmatter 字段（`owner` 逐项看）；D9 删 82 个符号链接并同批修消费者；D10 归档 6 个旧提案；D12 CHANGELOG 下一版起英文；B8 不做 `.terminateLater`；C3 有界 FIFO；P-R3 步骤 5 与 P-R4 表格模型 P2；R8 先 spike；About 诊断折叠、Quit 两处都留、固定窗口只用共享尺寸并删逐条目分支。

**产品项，不阻塞任何工程项**：F8b 撤销、F11 ⌘1–9、F13 状态栏菜单与 Launch at Login、D11 UI 语言（Codex 建议 P2 用 `xcstrings` 跟随系统）、D13 pin → detached（本轮不做）。

## 10. 实施状态（2026-09-24，分支 `review-2026-09-24`）

hh 的决定：丢弃工作树实验；D3 折叠 flag；B5 第二实例失败提示；F5 静态 QuickLook。实施由主线程加两个并行实现者（后端线、前端线，各自独立 worktree）完成，每项单独提交。

**已完成**

| 阶段 | 条目 | 说明 |
| --- | --- | --- |
| Phase 0 | R1 + M1 | AGENTS.md 验证表重写；canonical 文档 35 处纠正；新增代码约定、术语表、性能证据协议、本机 UI 验证路径 |
| Phase 0 | N5 + F0 + R5a | 脚本 fail-closed；索引缓存文件名 v6；打印 `list.body`；`perf-frontend-profile` 改单变体 + `--compare` |
| Phase 0 | R2 | 6 条并发诊断全部修掉；strict 变体 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES` |
| Phase 0 | R3 + D4 | 设置过滤与轮询测试回 unit/strict/TSan；删 `test`/`coverage`/`benchmark`/`test-integration`/`test-perf*`/`test-snapshot-perf`/`test-real-db`/`test-flow*`/`health-check`/`quality-manifest-self-test`/`perf-audit`/`perf-warm-scroll-ab`/`perf-unified-table` 及其脚本；删 `PerformanceTests`、`SnapshotPerformanceTests`、`RealDatabaseRegressionTests`、`IntegrationTests` 类 |
| Phase 0 | B3-D0 + W1 + P-R1 ①② + 卫生 §1.1/§2.1/§3.1/§4.1 | repository 五个死查询、`SearchPlanner.plan`、诊断、一次性 WebView、`__scopyRenderMath`、无消费者符号与环境变量、冗余测试与 UI 测试、82 个兼容符号链接、`DEPLOYMENT.md`、legacy doc 目录 |
| Phase 0 | D3 | 11 个 `PerfFeatureFlags` 全部折叠；`Scopy/Runtime` 删除；`ScopyWarmProfile` scheme 与 A/B 工具链删除 |
| Phase 1a | F9 + F8a | 键盘/⏎/⌥⌫ 按展示顺序；⌥⌫ 在文本编辑态不删条目 |
| Phase 1a | B5 | `StorageRootLock`（flock）在 `ClipboardService.start()` 起点取得 |
| Phase 1a | C1 ① + C2（两点）+ C3 语义 | 自写基线 + generation；每个 changeCount 只评估一次；落盘失败缓存重试；串行有界 FIFO（32）；回放按创建时间；TIFF 真实扩展名；Timer 加 tolerance |
| Phase 1a | B10 + B6（结果码） | 读取无 100 MiB 上限；SQLite 扩展结果码进错误与 `persistence` 日志 |
| Phase 1a | F15 + F13 | 搜索/加载/分页失败保留旧行并在页脚可重试；pin/delete/clear/AirDrop/Reveal 失败可见；Recent 段头遥测删除 |
| Phase 1a | E0 + E1 ①② | 导出取消竞态修复；恒假 rich-v2 判断与重复布局变量删除 |
| Phase 1b | F1 + F2（缩小版） | List 常驻、空态覆盖层、空 staged 页推迟；`listState` 观察拆分 + `HistoryRowLiveStateFanout` |
| Phase 1b | B4 | `StorageService` 改 actor，`CleanupPolicy` 按值传入 |
| Phase 1b | B1′ | `StorageCommitJournal`：每笔提交一条带序号的变更，缺口即重置；清理批量墓碑 |
| Phase 1b | B2a + B2b 简化 + B2c + F7 | `UInt32` postings、缓存 v6、空闲 60 s 裁剪、内存压力响应；前端缓存随面板关闭释放、memo 不持全文、缩略图字节上限 |
| Phase 1b | F5（H1 + H3 + 部分 H2）+ P-R2 | 呈现状态扇出；`.other` 文件静态 QuickLook；图片/文件几何在 present 前确定；指纹存储属性；body 不再做全文 SHA；导出复用屏幕文档 |
| Phase 1b | F10 + F12 + 小项 | 指针真实移动后才 hover 改选中；面板记住尺寸；固定窗口逐条目 frame 分支删除；IconService 负缓存 |
| Phase 2 | D1 | mock 与三个 harness 视图只编进 Debug；`ClipboardServiceFactory` 只保留真实服务 |
| Phase 2 | M2、M9、M10 部分、R13 部分 | 符号链接与 Compatibility 节删除；Makefile `help`/`.PHONY`/`clean`；`ScrollPerformanceTests` 改名 `ScrollPerformanceProfileTests` |

**未做（本轮明确留下）**

- F3/F4：条件项，等复测（需要安静桌面上的真实输入测量）；F6 同。
- B3 D1–D6（`SearchEngineImpl` 分解）、C3 八文件拆分、P-R4（CSS/运行时外置）、P-R3（Swift/JS 收敛）、R9、E1 ③④⑥（推送、进度/取消 UI、拆分）：L 级结构改动，无用户可见收益，留待下一轮。
- B6 每周 `quick_check` 与设置页提示、B7 以外的持久化项、B8（退出落盘，维持暂缓）。
- M5 改名（R3 pin→detached 不做；R6 与 B3-D6 同批）、M6 注释英文化、M7 frontmatter 字段、M8 旧提案归档、R12/R14/R15。
- 产品项：F8b 撤销、F11 ⌘1–9、状态栏菜单、Launch at Login、D11 本地化。

**验证记录（合并后，2026-09-24 晚）**

- `make build`、`make release`：通过。`make test-unit`：813 项、2 项跳过、0 失败。`make test-strict`（warning 即失败）：813 项通过，Swift warning 0。`make test-tooling`、`make docs-validate`：通过。
- `make test-snapshot-perf-release`（新鲜 `make snapshot-perf-db` 副本，157 MB）：cmd p95 0.55 ms（目标 50）、预热 cm p95 4.90 ms（目标 20）、冷 cm 45.5 ms；v0.79.0 记录为 0.53 / 4.42 / 59.5。
- 真实输入测量（`make perf-search-type`、hover 停顿）**未取得**：本会话的 shell 由 Claude 桌面 app 派生，`AXIsProcessTrusted` 为 false，合成输入不投递、AX 读回为空，脚本按 fail-closed 退出。需在有 Accessibility 授权的 Terminal 里按性能证据协议执行：先 `make release && make perf-scroll-tools`，再 `python3 scripts/perf-scroll/profile_search.py <Release app> before --query markdown --rate 8 --reuse-db --sample`（基线用 `4fbcd89` 的 Release 构建，交错 ABBA）。F3/F4 是否重启以该复测为准。
- 前端线在其分支上做了真实 App 的 PNG 导出字节对比（两个夹具改前改后 `cmp` 一致）；渲染器 JS 未改动。
- 未跑：XCUITest（本机被系统认证阻断）、`make test-tsan`（以托管 CI 为准）。

## 11. 第二轮实施状态（2026-09-25，分支 `review-2026-09-24`）

hh 的决定：内部结构项全做，并设红队复核；产品项全部加上；子代理用 Opus 5.5（high），数量减少；前端样式暂不改、前端性能不回归。三条实现线各在独立 worktree，主线程整合并完成捕获线（C3 八文件拆分，779aa98/61b1e13）。

**已完成**

| 线 | 条目 | 说明 |
| --- | --- | --- |
| 搜索 | B3 D1–D6 | `SearchEngineImpl` 3,546 → 1,412 行：`FuzzyMatcher`、`FullIndexRanker`、`SearchReadStore`（全部 SQL + `ClipboardItemRow` 解码，与 repository 共用）、`FullIndexStore`/`ShortIndexStore`（detached 构建，搜索等待构建而不在 actor 上同步扫表）、`SearchMatchContextBuilder.attach(to:request:)`、`SearchSQLGoldenTests`（200 例锁定每条 SQL 路径的 id/total/hasMore） |
| 搜索 | B3-D3 | `SQLiteSchema.requireCurrentSchema`（user_version + 5 张必需表）；trigram 可选路径、LIKE 回退、data_version 令牌、COUNT(*) 回退、只写不读的 `schema_version` 表全部删除 |
| 搜索 | M5/M6 后端部分 | 并发原语移到 `Scopy/Application/Concurrency/`；actor `ClipboardService → ClipboardBackend`（协议/工厂/`RealClipboardService` 名字不变）；`StoredItem` 别名删除；后端注释英文化；pngquant 日志走 `ScopyLog.pngquant`；与 Foundation 重复的 `NSLock.withLock` 扩展删除 |
| 渲染 | P-R3 | 表格管道转义、`#标题` 修复、科学 profile 的 LaTeX 规范化（约 1,675 行 Swift）全部迁入渲染器包（render.js、scopyLatexDocument.js、scopyLatexInline.js、scopyLineScan.js、scopyATXHeadings.js）；Swift 只嵌入 source + policy；34 个合成黄金逐字节复现，3,000 例随机 Swift/JS 对照零差异；rendererVersion v13 |
| 渲染 | P-R4 | 基础 CSS 外置 `scopy-document.css`（manifest 校验）；内联脚本、表格运行时、任务列表、导出页侧逻辑合并为 `documentRuntime.js`（`window.ScopyDocument`）；CSP 去掉 script 的 `'unsafe-inline'`；就绪等两张样式表；文档外壳每份约 99 KB → 1.4 KB |
| 渲染 | E1 ③④⑥ | 导出等待布局改为页面推送（phase 编号、迟到消息丢弃、无动画帧时按时间回退）；`ExportProgress` + 取消按钮；导出服务拆为 `Scopy/Services/Export/` 七个文件 |
| 渲染 | R6 + K7 | `MarkdownHTMLRenderer` 并入 `MarkdownHTMLDocumentBuilder.document(source:context:)`；K7 修代码：离屏预热的绘制期限从文档可见才计时，不再把失败 DOM 交给 popover；契约 K1–K13 措辞更新 |
| 产品 | F8b、F11、F13、D11 | 撤销删除 5 s 窗口（页脚 Undo / ⌘Z）；⌘1–9 复制第 n 个显示行并在按住 ⌘ 时提示；状态栏右键菜单（Open / Settings… / Check for Updates… / Quit）；Launch at Login（`SMAppService.mainApp`，在 Save/Cancel 事务内，待审批时窗口保持并链接到登录项设置）；About 诊断折叠、页脚 Load more 删除；`Scopy/Localization/Localizable.xcstrings`（en 源 + zh-Hans，跟随系统语言；Exact/Fuzzy/Markdown 等模式名与诊断术语不翻译）；app 侧注释英文化与改名 `isSelected`、`rowActivationSurface`、`projectionGeneration` |
| 整合 | 主线程 | 搜索证据标签本地化；ScopyKit 里的"（空内容）"占位改为空 fragment + 展示层 "(Blank content)"；ScopyKit 排除 `Localization`；裸 HTML 导出入口（`SCOPY_UITEST_*EXPORT_HTML_PATH`）与依赖它的 10 个 UI 测试删除（页面没有文档运行时已不能导出）；`richInteractionRuntime.js` 改走 `ScopyDocument.reportHeight`（合并后审出）；测试注释英文化 |

**红队复核（Codex astra xhigh，只读）**

- 第一轮（搜索 + 产品）9 项：P1 撤销删除跨 `await` 覆盖待删槽（连续删除时第三条留在数据库却被隐藏）→ 8c38e47 在任何 await 前接管槽；P2 延迟删除与分页 offset 不一致 → `pagingOffset`；P2 撤销深页行丢分页 → 就地插回原索引并恢复证据；P2 ⌘ 提示不随顺序变 → 投影变化时重算；P2 冷索引构建 `try?` 静默漏行 → 构建失败并报错；P2 冷构建等待不可取消 → 等待者可取消、共享构建继续；P2 为测试 seam 放宽 `private` 与无消费者接口 → seam 回同文件、恢复 private、删 `buildTrigger`/`TopKSelector.count`；P2 登录项审批状态回到应用后不刷新 → `didBecomeActive` 与 Save 前重读；P2 本地化测试只验证了未查到资源的原串 → 改为校验编译进 bundle 的 `.strings`/`.stringsdict`。
- 第二轮（渲染线 + 当日整合）14 项：P1 连续删除后真实 `.itemDeleted` 事件递增 `searchVersion` 使最新 Undo 与分页补偿失效 → 待删槽改键在 `projectionIdentity`（只在换查询/清空时变）；P2 撤销用旧整数索引在新捕获后顺序错 → 按删除时的前后邻居插回；P2 竞态测试没进入声称的交错 → 用 60 s 窗口让第二次删除亲自提交第一次并在其中挂起；P2 停止位移日志会把 400 ms 内的新滚动算进去 → 按滚动代次与程序滚动门过滤。渲染侧 P1 导出取消不停止 detached 工作且提前释放并发槽、P1 `\begin{tabular*}` 吞掉表格与后文并被固化为 golden，以及 P2 fence scanner 缩进代码边界、Unicode 扫描上限语义、无动画帧时的陈旧缓存、K7 二次隐藏、Swift 残留的导出 CSS/JS 与 `</head>` 回退、只供测试的 `policyPayloadJSON`、UI 测试删除后的无消费者 hook、导出拆分扩大 internal 状态——交渲染线子代理修。

**滚动停止跳变（hh 2026-09-25 实机反馈，已定位到单个提交并修复）**

- 产品线曾以 a35bc06 把 List 未测量行估高设为 43 pt；hh 在含该提交的构建上仍看到跳变，且它把段头抬到 43 pt，违反"样式不变"，已回滚（d186bac）。
- 逐帧日志（e7c8837/64554eb，`log stream --level info`）证明：向下快滚时单帧内文档高度骤降 526–1669 pt、视口顶边下的行跳 28–50 行，紧接着分页块按估计高度追加；即使无分页的向上快滚，文档高度也每帧 ±900–2300 pt 摆动。机制是 SwiftUI `List` 底层 NSTableView 丢掉已测行高、按估计值重排。
- hh 指出"渐进加载之前没有这个问题"。用同一份数据逐版本实机二分：v0.77.1 不跳、v0.78.0（分块分页 + 40 行预取）不跳、v0.79.0 不跳、v0.80.0 不跳、**456abdf 跳**、v0.80.1 跳、v0.81.0 跳。当前树关掉 40 行预取仍跳；当前树恢复行上的 `.id(item.id)` 不跳。
- 根因：456abdf（09-04 "Stop rebuilding row state SwiftUI never draws from"）认为 `ForEach` 已按 id 识别子视图、行上的 `.id(item.id)` 是多余的身份作用域而删掉；实际上没有显式身份时 List 每次更新都让 NSTableView 丢失已测行高。修复 98b7e05 恢复该行并在开发指南加规则 14。
- 同批保留：8fd9ffb 每页 100 → 300、每块 20 → 50（hh 提议，减少快速滚动时的分页次数）；观测点 `Layout moved the list …` / `Scroll settled …` / `Projection changed …`。`ListScrollAnchorKeeper`（25a9832）是在找到根因前加的补偿；hh 实机确认只恢复 `.id` 即不跳后已删除。

**未做（明确留下）**

- 滚动锚定修复与 300 行分页的帧时间 A/B 未做（需要有 Accessibility 授权的 Terminal）；hh 实机确认为准。
- F3/F4/F6 仍是条件项；前端性能 A/B（`make perf-search-type`、`profile_scroll.py`、`hoverstall`、`list.body`/`row.init`）需要在有 Accessibility 授权的 Terminal 里按性能证据协议做，本会话 shell 不能注入输入。
- 搜索结果行每次 body 求值都构造 Accessibility 描述（约 7 次本地化调用，改动前也是每次拼接中文），Codex 建议纳入 A/B。
- B6 每周 `quick_check`、B8、D13 pin → detached、旧提案归档（M8）。
