---
doc_type: proposal
status: draft
owner: hh
created: 2026-09-24
audience: maintainer decision + implementing agent
---

# 回归防护网：测试架构、CI/Makefile 门禁与性能证据协议（2026-09-24）

基线 `407f7db`（v0.81.0）。所有 `file:line` 以该 commit 为准；工作区未提交的 `SCOPY_EXP_OPAQUE_ROWS` 实验不计入，`Scopy/Views/HistoryListView.swift` 的行号取自 `git show HEAD:`。本文只回答"某类改动改错了，由谁、在哪里抓住"，不设计产品改进。冗余测试的删除清单见 `doc/proposals/code-hygiene-audit-2026-09-19.md` §3，本文只引用、不重做。

证据边界：结论全部在 HEAD 上重新读代码核实。运行时数字只引用本机已有日志——`logs/strict-concurrency-test.log`（2026-09-04）、`logs/test-unit.log`（2026-09-04）、`logs/test-integration.log`（2026-09-02）、`logs/perf-audit-v0.78.2-current-2026-09-03_02-18/warm-load-summary.json`、`logs/perf-scroll/typecount/profile.json`（2026-09-03）。本轮没有运行任何构建、测试或 perf 脚本。

## 0. 结论

| # | 改进 | 优先级 | 规模 | 预期收益 | 主要风险 |
| --- | --- | --- | --- | --- | --- |
| R1 | 重写 AGENTS 验证表，并对齐 dev guide / runbook / 样式契约的验证段：删掉本机不可执行的 frontend 行和 unified-table 行，补上 UI、内存、采集、导出四行（§1.5） | P0 | S | 代理不再把被挡住的工具当门禁，也不再默认填写 "environment-blocked" | 纯文档改动，需同步 4 处 |
| R2 | 出现 Swift 6 模式诊断时让 `make test-strict` 失败（先修掉现存 4 条） | P0 | S | 并发改动第一次有了能失败的编译期闸门 | CI（Xcode 16.0）与本机（26.1.1）的诊断集合可能不同 |
| R3 | 把产品设置测试和轮询测试放回 test-unit / strict / TSan；删除 `test`、`coverage`、`benchmark`、`test-integration` 目标 | P0 | S | "Save images/files" 规格首次进入 CI；去掉会弄挂 testmanagerd 的入口 | test-unit 多约 2.5 s |
| R4 | 列表输入发布次数测试（每次按键 1 次、相同 refine 0 次），配套统一的 `HistoryViewModelTestService` 和 `ListInputTurnRecorder` | P1 | M | 搜索打字优化最容易引入的回归（发布次数翻倍）能在 CI 被抓住 | A2 预计在 HEAD 上为红，需先确认再决定修代码还是改断言 |
| R5 | 修补真实输入工具：缓存文件名、打印 `list.body`、`footprint` 采样；新增交错驱动 `ab.py`（替代 `ab_scroll.py`），以及 `winwatch`、`pixeldiff` | P1 | S+M | §4 的协议和 §5 的路径可以照着执行，不必手工拼凑 | 须与卫生审计 D6 的归档决定一致 |
| R6 | 把性能证据协议写进 dev guide：A/A 噪声底、ABBA 顺序、热库、profiler 开关、记录模板、声明规则 | P1 | S | 结论不再被后来的测量推翻 | 无 |
| R7 | 本机 UI 验证标准路径：直接 exec 启动 + AX + CGWindowList + 私有 pasteboard + 日志计数；修复 `verify_hover_preview.sh` | P1 | M | XCUITest 不可用时，UI 改动仍有可复用的验收证据 | AX 标识符只在 profile 模式下暴露，带约 5.8% 开销，只能做功能判定 |
| R8 | 托管 CI 跑 `ExportMarkdownPNGUITests` / `HistoryItemViewUITests` 的 spike（先 workflow_dispatch） | P1 | S | 29 个 PNG 导出测试从"从不运行"变为"每次 push 都运行" | 托管 runner 从未跑过本 app 的 XCUITest，可行性未知 |
| R9 | Swift↔JS 渲染输入一致性夹具：给语料加 `rendererInput` 黄金文件 | P1 | M | Swift 预处理的变化第一次受跨语言断言约束 | §6.3 收敛后必须删除，不能变成永久层 |
| R10 | 退出路径的三层测试：服务级、终止协调器、真实 app 退出检查 | P1（随面 B） | S | 退出落盘从零测试变为有守护 | 依赖面 B 协调器的形状 |
| R11 | 内存守护：行为式上限测试、warm-load A/B、footprint 会话协议、确定性字节 LRU | P1（随面 B） | M | "+100 MB 不回落"成为可复现、可做 A/B 的数字 | 索引前缀上限与 product-spec 的 "Fuzzy 收敛到完整结果"冲突 |
| R12 | 采集 → 存储 → 回贴 → 再采集的往返矩阵 | P2 | M | 冻结的原文/去重模型一旦被意外改动就会变红 | 夹具较重（两个私有 pasteboard） |
| R13 | 测试按面分目录并统一命名；删除 `AppStateTestCompatibility` 门面；9 个服务替身收敛为 1-2 个 | P2 | M/L | 从文件名就能看出被测面，新增测试不必再复制 24 个协议成员 | `git mv` 量大；TSan target 按文件名排除，须同步修改 |
| R14 | 推广注入 sleep；用 `MainActorStallRecorder` 替换"1 秒内 tick 一次"式的弱断言 | P2 | M | 去掉 flake；主线程响应性有了真实上限 | 生产代码会多几个闭包参数 |
| R15 | `docs-validate` 校验反引号中的 `make` 目标与仓库路径 | P2 | S | 卫生审计删脚本之后，文档断链能当场报错 | 现存真缺失为 0，收益在于防回退 |

总体判断：

- 后端（存储提交协议、搜索、采集矩阵、hover 状态机）的单元测试是真测试，每次 push 在托管 CI 上跑三遍（unit、strict、TSan）。薄弱之处不是测试数量少，而是四个结构性空洞。
- 空洞一：所有真实 UI 与 PNG 导出断言（`ScopyUITests`，10 个文件 4,680 行、86 个方法，其中 29 个是 PNG 导出测试），在 CI 和 hh 本机上都从不运行。样式契约（`doc/current/markdown-chatgpt-wacz-style-contract.md:527`）把这种状态登记为 environment-blocked。
- 空洞二：`make test-strict` 不会因为新的并发诊断而失败，是一扇永远亮绿灯的门。
- 空洞三：前端交互不变量（"body 不读 X"、每次按键只发布一次）只写在 dev guide 里。唯一的观测值（`list.body` / `row.init` 计数）存在于真实 app 的 profile 中，但没有脚本把它打印出来。
- 空洞四：AGENTS 表里的两条性能行指向本机不可执行的工具，而且那些工具测量的并不是改动本身。
- 最划算的修复都是 S 级：改表、让 strict 能失败、把每条只要 0.25 s 的产品设置测试放回 test-unit、修 `profile_search.py` 的两行。
- 不建 `make perf-gate`。缺的是一个交错 A/B 驱动（约 80 行，替代只跑单一变体的 `ab_scroll.py`），外加一份把规则写清楚的协议（§4）。
- 需要 hh 拍板的事项有 7 件（§7.3），其中 2 件与卫生审计的删除建议冲突：审计要删的若干日志和脚本，恰好是本文 UI/性能证据的观测点。

## 0.1 终审修正（2026-09-24，主线程 + Codex 第二方复核）

以下裁定优先于本文正文；证据见 [review-roadmap-2026-09-24.md](./review-roadmap-2026-09-24.md) §9。

- **R2 表述与机制**：`test-strict` 已有 `pipefail`，编译与测试失败会失败，准确说法是"并发诊断没有升级为失败"；先在 HEAD 重新收集实际诊断（不以 2026-09-04 日志的"4 条"为准），再选机制。机制已定：strict 变体的 `xcodebuild` 命令行加 `SWIFT_TREAT_WARNINGS_AS_ERRORS=YES`（`Makefile:218` 附近，沿用 `pipefail`），首次实施验收 ScopyKit、ScopyUISupport、App 与测试 target 的实际 Swift 命令都含 complete 与 `-warnings-as-errors`；历史 strict 日志已证明 complete 到达 ScopyKit。2026-09-04 日志的 110 条 warning 是 4 种并发消息的重复加 3 条 AppIntents 工具警告，不是 110 个问题。
- **R3 表述**：设置过滤与轮询测试"不在 unit/strict/TSan 门禁内"，而非"任何地方都没跑过"（`release-current.yml` 记录了本地 integration 通过）。恢复覆盖不以删除 `make test`/`coverage` 为前置。
- **R4 的断言改写**：不再要求"每键恰好一轮发布"（与 F3/F4 的条件设计冲突，且 runloop 轮次不是 SwiftUI body 次数的等价替身）；改为断言"过期版本不发布、行与证据同一轮到达、相同 refine 零失效"。
- **R5 先做 fail-closed**（N5）：`build-tools.sh:7` 的 `|| true`、`verify_row_click.sh:22, 25` 的空输出即 OK、`profile_search.py:109, 127` 重试耗尽仍继续、`profile_capture.py:135-150` 只打印不失败——先让工具在失败时失败，再补 `list.body` 打印与交错驱动。
- **R10 只在 hh 采纳 B8 后才需要**，不作为 B4 前置；不在测试里引入"两个缓存必最新、WAL 必为零、3 s 必返回"这类未批准的契约。
- **R11 不为断言字节数而先把 `NSCache` 换成确定性 LRU**；内存以实机 footprint 会话协议为准。
- **R6 的判定规则是工程约定不是统计证明**：三对交错、2 倍合并 sd 只是最低要求，效应小于噪声底时不得下结论；profiler 5.8% 开销是滚动路径的数字，打字与 hover 须各自测。
- **R12 逐类型定义"等价"**（文件降级、临时图片转换等既有语义），不要求所有类型 payload 逐字节相同。
- **R13 只删 `AppStateTestCompatibility` 门面与合并明显重复的替身**；目录搬迁随面落地时做，且同步 `project.yml:217-222` 的 TSan 排除路径。

## 1. 门禁地图

### 1.1 CI 实际跑什么

- `ci.yml` 由 `push: main`、`pull_request`、`workflow_dispatch` 触发（`.github/workflows/ci.yml:3-8`），并设置了 `cancel-in-progress`（:10-12）。
  - `release_policy`（ubuntu）：`docs-validate`、`release-validate`、`test-release-policy`、`test-tooling`（:24-34）。
  - `build`（macos-15，Xcode 16.0）：先 `npm ci && npm test`（:52-53），再 `make build`（:56）。后者包含 `verify:assets`：它会从 `src/` 重新打包，并与提交进仓库的 bundle 比对（`Tools/MarkdownRenderer/scripts/asset-contract.mjs:407-420`），所以"改了 src 却没跑 `npm run build`"在 CI 中会失败。
  - `unit_tests`：`make test-unit`（:75）。
  - `strict_concurrency`：`make test-strict`（:102）。
- `tsan.yml` 在同样的事件上跑 `make test-tsan`（`.github/workflows/tsan.yml:3-8, 35`）。所以 TSan 不是"按需"执行，而是每次 push 都在托管 macos-15 上真跑。
- `release.yml` 只由 tag 或 dispatch 触发，只负责打包，不跑任何测试。
- hh 直接推 main（最近 40 个 commit 中，唯一的合并提交是本地合并），因此 CI 只是事后信号，真正的闸门在本机。连续推送时，`cancel-in-progress` 会让中间的 commit 拿不到完整的 CI 结果；发布证据必须引用针对发布 commit 本身的 run（v0.81.0 的 metadata 已经这样做）。
- 架构评审 §6.4 所说的"CI 不跑 npm test"在 HEAD 上已不成立：`ca728cd`（2026-09-03）已加入该步骤。

### 1.2 Makefile 的 test-* / perf-* 目标全表

| 目标 | 实际内容 | CI | hh 本机 | 依赖 / 排除 | 判定 |
| --- | --- | --- | --- | --- | --- |
| `test-unit`（`Makefile:84-97`） | ScopyTests 去掉 4 个类（`-skip-testing` 在 :92-95） | unit_tests | 可跑（2026-09-04 日志：822 例 33.4 s；v0.81.0：847 例） | 排除 `IntegrationTests`、`PollingIntervalSettingTests`、`ClipboardServiceContentFilteringIntegrationTests`、`PerformanceTests`。另有 4 个默认 skip：`HistoryRowPixelSnapshotTests`、LinkEnrichment live fetch、`SearchServiceTests` 的两个 perf 测试 | 主门禁 |
| `test-strict`（:205-220） | 与 test-unit 同一范围，加 `SWIFT_STRICT_CONCURRENCY=complete` | strict_concurrency | 可跑 | 警告不导致失败：本机日志有 110 条 warning，其中 4 条带 "error in the Swift 6 language mode"，日志结尾仍是 `** TEST SUCCEEDED **` | 空门禁（R2） |
| `test-tsan`（:181-202） | `ScopyTSanTests`：由 ScopyTests 源码去掉 3 个文件组成，经 `ScopyTestHost` 托管（`project.yml:213-252`） | tsan.yml | 本机组合 macOS 15.7.3 + Xcode 17B100 不在 :187 的跳过表里，理论上会真跑（未核实） | — | 真门禁（托管） |
| `test-integration`（:223-234） | 3 个类共 15 例，6.5 s（2026-09-02 日志） | 无 | 可跑 | 不在 `.PHONY` 里 | 只在本机、无人调用（R3） |
| `test`（:72-81）/ `coverage`（:237-250） | scheme 下所有 test target，含 `ScopyUITests`（`project.yml:16-19`） | 无 | 危险：会拉起 XCUITest，进而弄挂 testmanagerd | canonical 文档中没有消费者 | 删除（R3） |
| `test-perf` / `test-perf-heavy` / `benchmark`（:100-125, :253-267） | `PerformanceTests`（`-DSCOPY_PERF_TESTS`）。`benchmark` 设置的 `RUN_PERF_TESTS=1` 没有 `TEST_RUNNER_` 前缀，传不进测试，不起作用 | 无 | 可跑 | 唯一调用者是 `scripts/perf-audit.sh:170-173` | 见卫生审计 D4 |
| `test-snapshot-perf`（:129-140） | `SnapshotPerformanceTests`（受编译条件控制，需要 perf-db） | 无 | 可跑 | perf-db | 与下一行阈值相同，审计 §3.1 建议删除 |
| `test-snapshot-perf-release`（:143-164） | ScopyBench 跑 3 次：service 层 `cmd` 要求 p95≤50，engine 层预热后 `cm` 要求 p95≤20，冷启动 `cm` 只记录不判定（:155-163） | 无 | 可跑 | perf-db | 真门禁，但只覆盖 3 个查询、0 个清理基准（AGENTS:36 却写的是 "search/cleanup"） |
| `test-real-db`（:167-178） | `RealDatabaseRegressionTests` | 无 | 可跑 | 编译条件 | 审计 §3.1 建议删除 |
| `bench-snapshot-search`（:352-360） | ScopyBench 跑 6 次，无阈值 | 无 | 可跑 | perf-db | 与 perf-audit 重复 |
| `perf-search-warm-load`（:363-364） | 用 `/usr/bin/time -l` 包住 ScopyBench，输出 warm-load 耗时和 peak RSS（基线 50.5 ms / 117.1 MB，9,566 行，2026-09-03） | 无 | 可跑 | perf-db | 无阈值、无 A/B，但它是内存方面唯一现成的读数 |
| `perf-audit`（:367-368） | build + test-unit + test-perf + test-snapshot-perf + ScopyBench（`scripts/perf-audit.sh:159-177`） | 无 | 可跑 | perf-db | 依赖两个将被删除的目标 |
| `perf-frontend-profile{,-smoke,-standard,-full}`（:371-383） | XCUITest `HistoryListUITests.testScrollProfileRealSnapshot*`，Debug 配置（`-scheme Scopy` 不带 `-configuration`，`scripts/perf-frontend-profile.sh:223-228`）；baseline 是把 4 个 `PerfFeatureFlags` 置 0（:160-169）；每轮固定 AB 顺序（:293-298） | 无 | 被系统认证挡住 | perf-db、XCUITest | 不可执行；而且测的是 flag 差异，不是改动差异 |
| `perf-warm-scroll-ab`（:405-406） | XCUITest，`ScopyWarmProfile` scheme、Release 配置，两个 flag 轴（`scripts/perf-warm-scroll-ab.sh:368-369, 443-451`） | 无 | 被挡住 | XCUITest | 同上 |
| `perf-unified-table`（:409-413） | 把三个输入合成一张表的格式化器（`scripts/perf-unified-table.sh:59-77`） | 无 | 需要的前端 summary 来自被挡住的工具 | — | 本身不产生证据 |
| `perf-scroll-wheel` / `perf-search-type` / `perf-capture`（:391-403） | 真实 CGEvent 输入 + AX 读回 + `sample`，Release 配置 | 无 | 可跑（需终端有 Accessibility 信任、桌面保持安静） | perf-db | 本机唯一可执行的前端证据来源 |
| `test-flow` / `test-flow-quick` / `health-check`（:272-281） | 安装到 /Applications | 无 | — | — | 审计 §4.1 建议删除 |
| `test-tooling`（:287-291） | 7 个 shell/Make 测试 + 3 个 self-test | release_policy | 可跑 | — | 3 个 self-test 里，2 个服务于被挡住的 warm-scroll A/B；第 3 个 `record-gate-result.py`（668 行）没有任何真实调用者，只被 `Makefile:285` 的 self-test 调用 |
| `test-release-policy`（:490-491） | 15 例 | release_policy | 可跑 | — | 真门禁 |
| `markdown-assets-verify` / `-gate`（:300-309） | `verify:assets` 重新打包比对 + manifest 校验 | 经 `make build` | 可跑 | npm | 真门禁 |
| `ScopyUITests`（没有 Make 入口） | 10 个文件 4,680 行、86 个方法 | 无 | 被挡住 | XCUITest | 只有 perf 脚本通过 `-only-testing` 调用其中 6 个 profile 方法 |

### 1.3 AGENTS.md 验证表逐行判定（`AGENTS.md:33-41`）

- :33 Documentation：可执行，描述准确。
- :34 Functional code：可执行。但 :50 要求 "include UI evidence for UI changes"，而仓库里没有任何 UI 证据的可执行定义。
- :35 Concurrency：`test-strict` 不会失败（§1.2），是空门禁。"TSan when warranted" 也与现实不符：托管 TSan 每次 push 都会自动跑。
- :36 Backend search/cleanup performance：只覆盖 3 个搜索查询，完全没有清理。"fresh snapshot" 还与 A/B 的可比性冲突：新快照复制自每天都在变化的 live DB，跨天的数字不可比，除非记录快照的 SHA-256（`doc/perf/release-profiles/v0.80.1-profile.md:31` 就记录了）。
- :37 Frontend performance：本机不可执行。即便能执行，它也是 Debug 配置下的同二进制 flag A/B，比较的不是改动前后。这一行具有误导性。
- :38 Performance conclusions：`perf-unified-table` 只是格式化器，它所需的前端 summary 本应来自被挡住的 `perf-frontend-profile`。v0.80.1 当时该工具被挡（该 profile 的 :71），所用的 `frontend-release-summary.json` 是另行整理的（:48）。这一行没有给出任何得出结论的方法。
- :39 Hotkeys：可执行（`scripts/perf-scroll/panelwatch.swift:36-40` 可以直接发出 ⇧⌘+vk）。
- :40 Renderer：Node 的三项已在 CI 中执行。"real-app PNG visual check" 在没有 Screen Recording 权限时唯一可行的做法没有写出来：带 `--uitesting`、`SCOPY_UITEST_AUTO_EXPORT_MARKDOWN`、`SCOPY_EXPORT_DUMP_PATH` 直接启动 app（`Scopy/AppDelegate.swift:93-97, 354-385`）。另外，样式契约 :503 要求执行 `perf-frontend-profile.sh --include-hover`，而它在本机被挡住；dev guide :100 要求保持一个从未有人运行的 UI 测试为绿。
- :41 Build/test/release tooling：描述准确。
- 缺失的行：UI 行为、内存、采集语义、退出与生命周期。

### 1.4 缺口（按严重度排序）

1. 真实 UI 和 PNG 导出的回归在任何地方都没有可执行的自动门禁（§1.2 最后一行）。样式契约的 Required Verification（:489-527）和 dev guide 的 :100、:214、:260 都依赖被挡住的 XCUITest。
2. `test-strict` 是空门禁（§1.2）。AGENTS 表中 Concurrency 行的主要证据因此失效。
3. AGENTS 表 :37 和 :38 不可执行且具有误导性（§1.3）。dev guide :206-218 与 runbook :96-101 重复了同样的内容。
4. 前端交互不变量（dev guide :147、:151、:154 列出的"body 不得读取 X"）没有任何自动守护。唯一的观测值是真实 app profile 中的 `list.body` / `row.init`（`HistoryListView.swift:66`@HEAD、`HistoryItemView.swift:126`），而 `profile_search.py:123` 只打印名字里含 `search` 或 `row.` 的计数，`list.body` 只以键名出现，没有数值。
5. 产品设置 "Save images/files" 的唯一测试（`ScopyTests/ClipboardServiceContentFilteringIntegrationTests.swift:39, 69`，每条约 0.25 s）被 test-unit 和 test-strict 排除（`Makefile:94, 215`），TSan target 也不编译它（`project.yml:221`）。
6. 内存没有任何门禁。没有 phys_footprint 的测量协议；warm-load 只报 peak RSS，没有阈值也没有 A/B；图片缓存用 `NSCache`（`ScopyUISupport/ThumbnailCache.swift:421-425`、`Scopy/Views/History/HoverPreviewImageCache.swift:18-30`），淘汰时机不确定，无法写单测。
7. 退出路径没有测试。`applicationWillTerminate` 调用的 stop 是 fire-and-forget（`Scopy/AppDelegate.swift:285-295`、`Scopy/Services/RealClipboardService.swift:33-37`）；`SearchEngineImpl.close` 在 0.25 s 和 2 s 超时后静默放弃持久化（`Scopy/Infrastructure/Search/SearchEngineImpl.swift:1004-1016`）。
8. 没有 Swift↔JS 一致性测试。语料只被 Node 消费（`Tools/MarkdownRenderer/test/corpus.test.js:7-9`）；Swift 侧的预处理链（`Scopy/Views/History/MarkdownHTMLRenderer.swift:11-38`：LaTeX、ATX、table-pipe）的输出不受任何跨语言断言约束。
9. 真实输入工具的新鲜 DB 副本拷贝的是过期的索引缓存文件名：`profile_search.py:54` 和 `profile_capture.py:33` 仍拷贝 `fullindex.v4.plist`，而当前编解码器写的是 `*.fullindex.v5.bin` / `*.shortindex.v3.bin`（`SearchIndexDiskCache.swift:105, 114`，`profile_scroll.py:33-35` 已是对的）。结果是：不带 `--reuse-db` 的打字测量，会在测量窗口内构建冷的短查询索引。
10. ScopyBench 门禁连续 50 次重复同一个查询（`Tools/ScopyBench/main.swift:224-262`），测到的是稳态热路径；30 个样本时的 p95 实际就是第 2 大值（:261）。它不覆盖逐键变化的查询序列，也不覆盖清理。
11. `make test` 和 `make coverage` 会拉起 ScopyUITests，在 hh 的机器上会弄挂 testmanagerd，导致后续 `make test-unit` 假失败。
12. `docs-validate`（`scripts/docs/validate-docs.sh:41-71`）只检查 Markdown 链接，不检查反引号里的路径和 `make` 目标。按 2026-09-24 的扫描，现存真缺失为 0。

### 1.5 目标表：每类改动最少跑什么、在哪里跑（用于替换 `AGENTS.md:31-41`）

| 改动类别 | 本机最少门禁（闸门） | CI 自动执行（事后信号） | 声称性能收益或行为变化时追加 |
| --- | --- | --- | --- |
| 文档 / 元数据 | `make docs-validate`、`make release-validate` | release_policy | — |
| Swift 功能代码（非 UI） | `make build`、`make test-unit`（先跑相关的聚焦测试） | build、unit_tests、strict、tsan | — |
| 并发 / actor / 生命周期 | 在上一行基础上加 `make test-strict`（R2 之后才能失败） | strict、托管 TSan | 本机 `make test-tsan` 可选 |
| 列表更新 / 搜索打字 / hover / 键盘 | 单测（含 §2.A 的发布次数测试）+ §5 的 AX 功能检查 | unit | §4 协议下的交错 A/B：`profile_search`、`hoverstall`、计数 |
| 后端搜索或清理性能 | `make test-snapshot-perf-release`（A、B 两侧用同一快照，并记录 SHA-256） | — | §4 协议下的 ScopyBench 交错 A/B |
| 内存上限 | 单测（§2.B 的行为式上限）+ `make perf-search-warm-load` A/B | unit | §2.B 的 footprint 会话协议 |
| 采集语义 | 单测（采集矩阵，加上 R3 移回的内容过滤测试） | unit、tsan | `make perf-capture` 测主线程成本 |
| 渲染器 / 导出 | Node 三项（经 `make build`）+ 单测（含 R9 一致性夹具）+ §2.C 的导出像素 A/B | build（npm test + verify）、unit | 若 R8 spike 成功，再加托管 XCUITest 导出测试 |
| UI 行为（views / panel） | 单测 + §5 标准路径 | unit | 若 hh 采纳 R8，再加托管 XCUITest |
| 热键 | 检查 `/tmp/scopy_hotkey.log` 中出现 `updateHotKey()` 且每次按键只有一次动作 | — | — |
| 工具 / 脚本 / workflow | `make test-tooling`（改发布相关时加 `make test-release-policy`） | release_policy | — |

## 2. 四类改进的守护设计

### 2.0 共用夹具（放在 `ScopyTests/Support/`，均为测试代码，不新增生产符号）

- `HistoryViewModelTestService`：由 `ScopyTests/HistoryViewModelRegressionTests.swift:684` 的私有服务提升而来。它已具备 staged 首页、可挂起的 refine / 分页 / 统计、证据开关和失败注入。用它替代其余 8 个 `ClipboardServiceProtocol` 测试替身：`AppStateTests.swift:890, 1192`、`SearchStateMachineTests.swift:11, 99, 233, 351`、`IntegrationTests.swift:657`、`Helpers/MockServices.swift:10`。该协议有 24 个成员（`Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`），目前每个替身都在全量重写这些成员。
- `ListInputTurnRecorder`：统计"列表输入在多少个 runloop 轮次里发生了变化"。
  - 在主 runloop 上挂一个 `CFRunLoopObserver`（`.beforeWaiting`），每次触发把轮次号加 1。SwiftUI 也是在这个时机提交更新，所以按轮次计数与真实的 body 失效粒度一致。
  - 用 `withObservationTracking` 监视列表输入，并在 `onChange` 里同步重新布防，确保每一次写入都被看到，然后把当前轮次号记入集合。
  - 被监视的列表输入 = `HistoryListView.body` 在非空分支中读取的值（`HistoryListView.swift:81-125`@HEAD）：`items`、`pinnedItems`、`unpinnedItems`、`searchMatchContexts`、`canLoadMore`、`isPinnedCollapsed`，外加 `settingsViewModel.settings`。
  - 测量器必须先自证：写一个 `ListInputTurnRecorderTests`，其中两次写入被一个真实挂起点隔开，必须计为 2；同一轮里的两次写入必须计为 1。自证通过前，不得用它证明"只发布 1 次"。
- `MainActorStallRecorder`：在 MainActor 上每 5 ms 自调度一次，用 `ContinuousClock` 记录最大间隔。它用来替换 `ReviewFix24Tests.swift:128-138` 那种"1 秒内能 tick 一次就算通过"的弱断言：那种写法下，主线程即使被阻塞 900 ms 也能通过。

### 2.A 列表更新 / 搜索打字 / hover / 键盘

现有手段分别能抓住什么、抓不住什么：

| 手段 | 抓得住 | 抓不住 |
| --- | --- | --- |
| ScopyBench（`Tools/ScopyBench/main.swift`） | engine 层和 service 层的搜索延迟；设置 `SCOPY_PERF_METRICS` 后还有分阶段耗时 | 主线程成本、SwiftUI 发布、带取消的逐键序列（c→cm→cmd）、证据扇出到行。它重复同一查询（:224-262），测到的是热稳态 |
| `profile_search.py` | 输入窗口内的进程 CPU（`sample.sh:5`）、`sample` 调用树、app 的 runloop busy 总量 / p95 / max、AX 读回的查询值与行 | 单键延迟分布（`typekeys.swift:44-51` 不输出单键时间戳）、`list.body` 数值（:123）；另有冷索引污染（:54） |
| `hoverstall.swift` | 主线程停顿的 p50 / p95 / max，以及每一次超过 50 ms 的停顿和它的时间偏移（:22-26, 43-46） | 停顿原因（需要配合 `sample`）、popover 可见耗时、主线程以外的工作 |
| 离屏行像素证明（`c882c83`：`HistoryRowPixelSnapshotTests` + `compare_row_snapshots.py`） | 5 种行形态（普通、选中、置顶、长文本、文件）在 480 pt @2x 下的像素变化 | 搜索证据行、缩略图、hover 态、暗色外观、List 的行高与 inset、`NSViewRepresentable` 内容。另外：它靠环境变量开启（:17-24），默认 skip；比对依赖本机没有安装的 `magick`（`compare_row_snapshots.py:25`）；A 与 B 两次截取之间如果跨越相对时间的分桶边界，也会产生误差 |
| 现有单测 | `HistoryViewModelRegressionTests.testIdenticalRefinedPrefixUpdatesTotalsWithoutRebuildingRows`（:463-496，用 `itemsRevision` 作代理）、`AppStateTests.testSearchCoalescesRapidInputWithoutDebounce`（:152-178，统计后端调用次数）、`HistoryRowSelectionFanoutTests`、`HistoryHoverPreviewPipelineTests.testTextPreviewUsesCachedMarkdownCapabilityAndCachedHTMLMetrics`、`WebViewLifecycleTests.testRepeatedIdenticalUpdatesDoNotRestartNavigationOrReconfigureBridge` | 都没有统计"列表输入被发布了几次"。`itemsRevision` 不变，不代表 `listState` 没有被写：见 A2 |

需要新增的测试：

**A1 `HistoryViewModelPublicationTests.testKeystrokeWithNewResultsChangesListInputInOneRunLoopTurn`**
- 夹具：`HistoryViewModelTestService`，200 条数据，打开证据；`configureTiming(.immediateRegressionTests)`；使用 `ListInputTurnRecorder`。
- 步骤：`load()` → 开始记录 → `searchQuery = "needle 1"; search()` → 等待搜索完成。
- 断言：`recorder.turns == 1`，并且 `service.searchCallCount == 1`。
- 阈值：恰好 1。依据：SwiftUI 每个 runloop 轮次只提交一次；多出的每一轮都会重跑 `HistoryListView.body`，而 body 会重新初始化所有 ForEach 子项（dev guide :151）。实测佐证：`typecount` profile 中 28 次 `list.body` 对应 1,423 次 `row.init`，约每次 body 重建 51 行。
- 在哪跑：CI（unit、strict、TSan）。
- 能抓住：发布被 `await` 拆开、证据晚于行到达、把 `isLoading` 或 `performanceSummary` 挪进列表输入。
- 抓不住：body 读取了声明集合之外的属性。这类问题由 A4 的真实 app 计数负责。

**A2 `testIdenticalRefineDoesNotChangeListInput`**
- 夹具：staged 首页返回 50 行且 `hasMore=false`；refine 返回相同的行、证据和 `hasMore`，只有 `total` 从 -1 变为 50。
- 断言：refine 期间 `recorder.turns == 0`。
- 依据：dev guide :154 规定 "replaceSearchPage is a no-op when the refine pass reproduces the prefilter page"。
- 预计在 HEAD 上为红。`HistoryViewModel.swift:1583` 在跳过路径上仍调用 `listState.updatePagination`，它会经 `_modify` 通知 `listState`（声明在 :326，未标 `@ObservationIgnored`）的所有读者，而 body 在 :125 读取了 `canLoadMore`。
- 实施者须先运行这条测试确认。如果确认为红，由面 A 决定是把分页字段移出列表输入，还是接受这次失效；如果选择接受，必须修改 dev guide :154，不能让测试去迁就代码。

**A3 `testThreeKeystrokesInOneTurnPublishOnlyTheFinalQuery`**
- 在一个轮次内连写 "h"、"he"、"hel"，每次都调用 `search()`。
- 断言：后端调用 1 次（已有断言），列表输入变化 1 轮，并且最终 `items` 就是 "hel" 的结果。

**A4 真实 app 计数（本机）**
- 前提：`profile_search.py` 打印 `list.body` 与 `row.init` 的差值，并支持空查询作为零键基线（R5，S）。
- 断言：`(list.body[输入 run] − list.body[零键 run]) / 键数 ≤ 1.0`；`row.init / list.body ≤ loadedCount`。
- 键盘：用 `--query '<down><down><down><down><down>'` 做一次 run，断言 `list.body` 差值 = 0。依据：dev guide :151 规定选择状态不得流经 List body。
- 这是唯一能发现"body 多读了某个属性"的守护。它只在本机运行，按 §4 协议记录。

**A5 `HistoryRowEvidenceFanoutTests.testEvidenceChangeNotifiesOnlyTheChangedRow`（仅当面 A 把证据改为按行扇出时才加）**
- 结构照搬 `HistoryRowSelectionFanoutTests.swift:6-21`：注册 3 行，只更新 b 的证据，只有 b 的 sink 被调用；再次写入相同证据，不调用任何 sink。
- VM 层补充 `testEvidenceOnlyUpdateReachesOneRowWithoutListInputChange`：复用 `SearchStateMachineTests.testContentUpdateReplacesThenRemovesEvidenceForActiveQuery` 的场景，断言 `recorder.turns == 0`，且扇出只投递 1 次。

**A6 popover 尺寸不重复计算**
- 现状：尺寸在 `HistoryItemTextPreviewView.body` 里计算（`HistoryItemTextPreviewView.swift:62-89` → `HoverPreviewTextSizing.preferredWidth` / `preferredTextHeight`，定义在 `HoverPreviewTextSizing.swift:6, 39`），每次 body 求值都会重新测量少于 1,500 个 UTF-16 单位的文本。
- 单测 `HoverPreviewSizeCacheTests.testSameRevisionWidthAndScaleMeasuresOnce`：注入测量闭包并计数（沿用 `HistoryRowThumbnailLifecycleScheduler` 的闭包注入形状）。同一个 `(contentRevision, maxWidth, scale)` 第二次请求时测量次数为 0；宽度变化后为 1。阈值：精确次数。
- 真实 app：对同一行 hover 两次。
  - 用 `winwatch`（R5）记录 popover 窗口首次出现之后的 bounds 变化次数，断言为 0。依据：dev guide :153 规定 popover "opens at its final size"。
  - 用 `hoverstall` 测第二次 hover，max 目标 ≤ 50 ms；当前实测为 65-156 ms。50 ms 与 hoverstall 的停顿阈值（:45）一致。
  - 第二次 hover 的日志中 `webview navigation start`（`MarkdownPreviewWebView.swift:949`）出现 0 次。

不建议现在做：用源码 lint 禁止 `HistoryListView` 读取 `selectedID`、`isScrolling`、`performanceSummary`。它能抓住已知回归，但对重构很脆弱，而 A4 的计数能覆盖同一类问题。如果 A4 长期没人执行，再重新考虑。

### 2.B 索引内存上限 / `StorageService` 改为 actor / 退出落盘

**内存（R11）**

- B1 行为式上限：`FullFuzzyIndexCapTests.testTokenBeyondIndexedPrefixFollowsSpecifiedCoverage`。
  - 插入一条 1 MB 的文本，在 1 KB 和 900 KB 两个位置各放一个唯一 token，分别做 fuzzy 搜索。
  - 断言的预期由 hh 事先定下的语义决定（§7.3 第 4 条）：要么两个 token 都能找到（上限只作用于内存索引，由 SQLite 路径补全，符合 `product-spec.md:102` 的"收敛到完整结果"），要么修改规格，接受前缀之外漏检，同时要求 coverage 标记为非 complete。
  - 这条测试不需要任何内省，上限本身就是可观察的行为。
- B2 缓存字节上限：只有当上限用确定性 LRU 实现（仓库已有 count-bounded 的 `BoundedPresentationCache`，`ClipboardItemDisplayText.swift:7`），而不是 `NSCache` 时，才写 `retainedBytes ≤ cap` 的单测。`NSCache` 的淘汰时机不确定，在它上面写的单测要么永远是绿的，要么时绿时红。
- B3 基准内存：`make perf-search-warm-load` 在同一快照上做 A/B，各跑 3 次，记录 peak RSS 与 warm-load 耗时（基线 117.1 MB / 50.5 ms）。
- B4 真实 app 会话（本机，§4 协议）：
  - Release 包 + 热库，稳定 10 s 后用 `footprint --pid <pid> --noCategories -f bytes` 读出 F0。
  - 打开面板，用 `typekeys` 依次输入 `the`、`<cmd-a>cm`、`<cmd-a>数学`，hover 3 行，再用 `<esc>` 关闭。
  - 等待 30 s 后读出 F1；用 `heap <pid> -s` 列出按类统计的前 20 项，作为归因。
  - 记录 ΔF = F1 − F0；当前实测约 +100 MB 且不回落。
  - 不在单元测试里断言 phys_footprint：同一进程中其它测试留下的分配会污染读数。

**`StorageService` 改为 actor**

- 隔离本身由编译器守护，不写运行时测试。当前的 `@MainActor`（`StorageService.swift:100-101`）去掉后，所有调用点都必须显式 `await`。
- 真正的风险在语义层面：代码是否依赖"storage 调用与其它 MainActor 状态在同一个 executor 上串行"来获得原子性。守护手段是现有的 interlock 驱动测试：`StorageCommitProtocolTests`（2 处）、`StorageServiceTests`（10 处）、`ClipboardServiceCleanupTests`（1 处）、`ClipboardServiceImageOptimizationTests`（7 处）。它们必须在 unit、strict（R2 之后能失败）、托管 TSan 三处都为绿。
- 新增 `ClipboardServiceIngestTests.testBurstOfLargeRichItemsKeepsMainActorResponsive`：通过私有 pasteboard 写入 50 条约 200 KB 的 rich 项，用 `MainActorStallRecorder` 断言 max gap < 100 ms。
  - 阈值依据：hoverstall 在空闲 M3 Pro 上以 50 ms 作为停顿线；托管 runner 是 3 vCPU 的虚拟机，调度抖动更大，所以取两倍，并且仍远低于 Apple 250 ms 的 hang 线。
- 卫生审计 §3.1 建议删除 `ConcurrencyTests` 中断言较弱的测试。在 TSan 下，这类测试的价值在于它们制造的交错，而不在断言。删除前，须确认 `ScopyTSanTests` 里仍有测试覆盖相同的并发路径，例如清理与搜索并发。

**退出落盘（R10）**

- B5 服务级测试 `ClipboardServiceShutdownTests.testStopAndWaitPersistsSearchIndexCachesAtCurrentMutationSequence`：
  - 在临时目录里启动真实的 `ClipboardService`，绑定私有 pasteboard，写入 30 条。
  - 先做一次 fuzzy 搜索来构建全量索引，再做一次 2 字符搜索来构建短查询索引，然后再写入 1 条，让缓存过期。
  - 执行 `await stopAndWait()`。
  - 断言：`clipboard.db.fullindex.v5.bin` 和 `.shortindex.v3.bin` 都存在，且头部的 mutation 序号等于 DB 当前序号（用现有的 `SearchIndexDiskCache` debug 解码器读取）；`clipboard.db-wal` 为 0 字节（TRUNCATE checkpoint）；`stopAndWait` 在 3 s 内返回。
  - 3 s 取自架构评审 §8.2 建议的硬超时。如果这里超时，真实退出就会走超时分支。
- B6 协调器测试（在面 B 实现 `.terminateLater` 之后）：
  - `AppTerminationTests.testTerminateLaterRepliesOnceAfterStopCompletes`、`testTerminateLaterRepliesOnceAtTimeoutWhenStopStalls`、`testSecondTerminateRequestDoesNotStopTwice`。
  - sleep 通过注入提供（形状同 `HoverPreviewIntentController.swift:26`），服务 stop 被挂起时不需要真的等 3 s。
  - 断言 reply 恰好 1 次，并且发生的时机正确。
- B7 真实 app（本机）：
  - 用 `pbwrite` 写入 5 条后，执行 `osascript -e 'tell application id "com.scopy.app" to quit'`（与 `perf-frontend-profile.sh` 的退出方式相同）。
  - 断言两个缓存文件的 mtime 晚于最后一次写入。
  - 重新启动后，日志中出现 `Full index disk cache load hit`（`SearchEngineImpl.swift:1312`）。
  - 这条日志正在卫生审计 §1.1 的删除清单上，见 §7.3 第 2 条。

### 2.C 采集语义与渲染链收敛

**采集矩阵在 HEAD 上的状态**

- `e1d7846`（Unify capture tests）删掉了死路径 `extractContent`（`ClipboardMonitor.swift` 减少 290 行）。`ClipboardMonitorTests` 的 59 个方法现在都走生产入口：私有命名 pasteboard → `checkClipboard()` → `contentStream`（`ClipboardMonitorTests.swift:1489-1503`）。四类 marker 通过轮询路径被锁定（:1122-1166）。架构评审 §8.4 所说的"测的是死代码"已经解决。
- 剩余缺口：
  1. 内容过滤设置不在任何门禁内（R3）。
  2. 没有"Scopy 写入 pasteboard 后又把自己的写入采集回来"的测试（评审 §3.3 的自粘贴竞争）。
  3. 采集与回贴分属两批测试，中间没有往返断言。
- R12 `CaptureReplayRoundTripTests.testEveryCapturedTypeReplaysToAnEquivalentPasteboard`，以表驱动：
  - 用现有矩阵的 fixture（text、rtf、html、png、tiff、file、folder、marker）写入私有 pasteboard A → monitor 采集 → `ClipboardService` 存储 → `copyToClipboard` 写到私有 pasteboard B → 第二个 monitor 采集 B。
  - 断言类型相同、`plainText` 相同、payload 的哈希相同（图片比较解码后的像素）。
  - 它锁定的就是当前被冻结的原文/去重模型（例如首尾空白会被规范化）。任何意外改动都会让它变红，这正是"冻结"要求的效果。
  - 它不检查剪贴板的第三方消费者（其它 app 读回时看到什么）。

**Swift↔JS 一致性（R9）**

- 在 `ScopyTests/Fixtures/MarkdownRenderingCorpus/cases.json` 的每个 case 里增加字段 `rendererInput`，指向一个黄金文件 `<name>.renderer-input.md`，内容是 Swift 预处理的实际输出。
- Swift 侧 `MarkdownRenderingCorpusParityTests.testSwiftPreprocessingProducesCommittedRendererInput`：
  - 对每个 case 断言 `MarkdownRenderContextResolver.defaultContext(for:)` 得到的 profile 等于 `expectedProfile`。
  - 断言预处理输出与黄金文件逐字节相等。这需要把 `MarkdownHTMLRenderer.swift:11-38` 的链条提取成一个 internal 的 `preprocess(markdown:context:)`，生产代码仍只走这一条路径。
- Node 侧：`corpus.test.js` 改为渲染 `rendererInput` 而不是原始源文件，这样 Node 断言作用于生产真正送进 `render()` 的输入。
- 能抓住：Swift 预处理（ATX、table-pipe、LaTeX 规范化）的变化悄悄改变了渲染输入；Swift 的 profile 检测与语料声明不一致。
- 抓不住：WebView 运行时的水合与 CSS；Swift 与 JS 两份重复逻辑在语料之外的输入上出现分歧。
- 退出条件：当 §6.3 把 Swift 侧的变换移成 remark 插件之后，黄金文件会与源文件完全一致。届时删除 `rendererInput` 字段（约束 1）。

**导出像素回归**

- 本机 A/B（R5 的 `ab.py export`）：
  - 分别用基线 app 和候选 app，按以下参数直接启动每个 fixture：`--uitesting`、`SCOPY_UITEST_AUTO_EXPORT_MARKDOWN=1`、`SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH=<fixture>`、`SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION=100|200`、`SCOPY_EXPORT_DUMP_PATH`、`SCOPY_EXPORT_ERROR_DUMP_PATH`、`SCOPY_EXPORT_PASTEBOARD_NAME=<私有>`。
  - fixture 只用 `ScopyUITests/Fixtures/` 下已跟踪的 8 个 `.md` 文件。v0.81.0 使用的 `preview-fixture.md` 没有进 git，不能复现。
  - 用 `pixeldiff` 比较每对输出：若改动不打算影响视觉，要求差异像素为 0；若有差异，报告差异像素数、占比、最大通道差、MSE 和差异包围盒，交给人工审阅。v0.81.0 在 tile 边界处 0.0006% 的像素差异就是按这种方式说明后被接受的。
- 托管 CI（R8 spike）：在 `ci.yml` 中加一个只在 `workflow_dispatch` 时运行的 job，执行 `xcodebuild test -scheme Scopy -only-testing:ScopyUITests/ExportMarkdownPNGUITests -only-testing:ScopyUITests/HistoryItemViewUITests`，并上传 xcresult。连续 3 次绿灯后再提升为 push 触发。这 29 个导出测试断言的是宽度、空白、相对比例和颜色保留等阈值，不是黄金图，受 runner 字体差异的影响较小，但仍须由 spike 确认。
- 行像素证明：作为 A/B 工具保留（是否保留见 §7.3 第 2 条）。
  - 改用 `pixeldiff`，去掉对 `magick` 的依赖。
  - 增加 `searchEvidence` 和 `thumbnail` 两种形态。
  - 规定 A、B 两次截取必须在同一台机器、同一次会话中完成。
  - 它不进 CI：`ImageRenderer` 对 material 的保真度未经验证，并且跨系统版本不稳定。

### 2.D 文档

- `docs-validate`（`scripts/docs/validate-docs.sh`）能检查的：
  - 必需文档是否存在（:15-39）；
  - 非 archive 文档中、代码块之外的相对链接能否解析（:41-71）；
  - `release-current.yml` 与索引、changelog 的版本和日期是否一致（:74-117）。
- `release-validate` 能检查的：发布文档与 changelog 标题，以及 workflow 不创建 tag（`validate-release-docs.sh:19-39`）。
- 两者都不能检查的：
  - 反引号中的路径、`make` 目标、环境变量和 `file:line`；
  - 文档要求的门禁是否真有 runner 在执行（dev guide :100、契约 :503）；
  - 文档中的陈述是否仍然成立（例如评审 §6.4 "CI 不跑 npm test"已经过时）；
  - frontmatter 的取值。
- R15：在 `validate-docs.sh` 中加入两条检查，约 15 行——`AGENTS.md`、`CLAUDE.md`、`doc/current/**` 中反引号里的 `make <target>` 必须存在于 Makefile；反引号里的 `scripts/`、`Scopy/`、`ScopyTests/`、`ScopyUITests/`、`Tools/` 路径必须存在。2026-09-24 按这两条扫描，唯一命中的是省略了 `.swift` 后缀的 `Scopy/Services/Export/MarkdownExportService`（写法问题，不算真缺失）。它的价值在卫生审计 Phase 1 删除脚本之后才会体现。
- "文档要求了一个没人运行的门禁"无法自动检查，改为人工审查项，写进 §4 的记录模板："本次引用的每个门禁，本次是否真的执行了？"

## 3. 测试套件的目标结构与"真实回归测试"判定标准

现状：`ScopyTests` 有 86 个 Swift 文件 27,955 行，`ScopyUITests` 有 10 个文件 4,680 行，合计 96 个文件 32,635 行。除 `Helpers/` 外，所有文件都平铺在根目录。一个文件里放多个主体的情况包括 `IntegrationTests.swift`（4 个类）、`ReviewFix24Tests.swift`（3 个类）、`AppStateTests.swift`（2 个类）等。`AppStateTests` 的 64 个方法大多通过 `AppStateTestCompatibility.swift:1-161` 这个门面在测 `HistoryViewModel`。这个门面本身就是一个兼容层，违反约束 1。

### 3.1 目标目录（XcodeGen 会递归收录 `ScopyTests/` 下的子目录，`project.yml:161-166` 不需要改）

```text
ScopyTests/
  Support/     HistoryViewModelTestService, ListInputTurnRecorder, MainActorStallRecorder, TestFixture, waits
  Capture/     ClipboardMonitor*, CaptureReplayRoundTrip, ClipboardServiceContentFiltering, PollingInterval
  Storage/     StorageService*, StorageCommitProtocol, SQLite*, ClipboardServiceCleanup, Thumbnail*
  Search/      SearchEngine (原 SearchServiceTests), SearchMatchContextBuilder, SearchPlanner, *IndexDiskCacheHardening, SearchBackendConsistency
  History/     HistoryViewModel{Load,Search,Selection,Events,Publication}Tests, HistoryListState, HistoryListInteractionCoordinator, HistoryRowSelectionFanout, row descriptor/presentation, ListLiveScrollObserverView
  Preview/     HistoryHoverPreviewPipeline, HoverPreviewIntent*, HistoryItemPreviewCoordinator, PinnedPreviewController, WebViewLifecycle, HoverPreviewImageCache
  Renderer/    ChatGPTMarkdownRenderer, Markdown*, MarkdownRenderingCorpusParity, LinkEnrichment, SourceIcon
  Export/      MarkdownExportService, PngquantService, HistoryItemMarkdownExportController
  App/         AppState (只保留服务选择 / settingsChanged / 启动失败), HotKeyService, FloatingPanelDismissPolicy, SettingsWindowCoordinator
  Tooling/     ScrollPerformanceProfile (原 ScrollPerformanceTests 后半), HistoryProfileDatasetFingerprint
```

实施时必须同步修改的一处：`ScopyTSanTests` 按相对 `ScopyTests/` 的文件名排除（`project.yml:220-222`）。文件移进子目录后，排除规则要改成新路径；否则被排除的测试会悄悄进入 TSan target，或者本应排除的文件没有被排除。

### 3.2 判定标准：什么算能检出真实回归的测试

1. 它在一个真正执行的门禁里运行（CI，或 §1.5 列出的本机门禁），没有被 skip、编译条件或环境变量关掉。否则它是工具，不是测试。
2. 作者能说出一个具体的错误改动，并且这个改动会让它失败（变异检验）。说不出来，就不要加。
3. 断言的是外部可观察的契约：返回值、发布的事件、持久化状态、pasteboard 内容、AX 状态、观察到的发布次数。不断言私有常量、SQL 文本、JS 源码子串或内部 reason 字符串。
4. 断言不可能恒真：没有恒真的 `A` 或 `B`，不以 `XCTAssertNotNil` 作为唯一断言，不以 "DoesNotCrash" 作为唯一含义，不用 `print` 代替断言。
5. 结果不由时间决定：不用固定 sleep 等待异步完成；与时间相关的逻辑通过注入的 sleep 或调度器驱动。墙钟阈值只出现在 §4 的协议里，唯一例外是有依据的数量级上限（例如 3 s 的退出超时、100 ms 的主线程停顿）。
6. 不与已有测试重复：同一个入口、同一个夹具、同一组断言已经存在时，不再新增。
7. 失败信息能定位问题：写明契约和实际值，例如 "expected 1 list-input turn per keystroke, got 2"。
8. 走生产路径：通过 `checkClipboard()`、`ClipboardService`、`HistoryViewModel` 这些生产入口进入，不经过兼容门面，也不测试生产代码的复制品（例如 `PanelReopenSearchResetPolicy`，见审计 §2.1）。
9. 夹具最小且确定：使用私有 pasteboard、临时目录、固定时间和 UUID；不依赖本机 DB、网络、用户剪贴板或当前日期。
10. 有明确归属：文件名和类名说明被测的是哪个类型或哪个面，一个类只测一个主体。

### 3.3 注入 sleep 的推广清单

2026-09-04 的日志显示整套 822 例只用 33.4 s。所以注入时钟的收益是确定性（消除 flake），不是缩短时长。

| 组件 | 位置 | 测试现在怎么等 | 处理 |
| --- | --- | --- | --- |
| 分页分块，每块 20 ms | `HistoryViewModel.swift:1021, 1612, 1651` | 真实等待 20 ms × 块数 | 并入已有的 `Timing`（:281-305，`configureTiming` 在 :525） |
| hover 选中 150 ms / 退出宽限 120 ms / 1.5 s / 2 s | `HistoryItemView.swift:1417, 2028, 1641, 1932` | 视图内的常量，协调器测试用真实 sleep | 移入已有的协调器，使用 `sleep:` 闭包（形状同 `HoverPreviewIntentController.swift:26`） |
| 清理 debounce | `ClipboardService.swift:2404` | 真实等待 | 作为 init 参数注入 |
| 滚动冷却 | `HistoryListInteractionCoordinator.swift:464` | 真实等待 | 注入 `sleep:` |
| 15 s 清扫循环 | `HoverPreviewImageCache.swift:93` | TTL 已经通过 `now:` 注入（`HoverPreviewImageCacheTests.swift:10`） | 清扫改为仅在有条目时运行，由同一个 `now:` 驱动 |
| `testingAsyncProcessingDelayNs` | `ClipboardMonitor.swift:925` | 全局可变的静态测试旋钮，生产路径会读取它 | 改为 init 参数，删掉静态变量 |
| 测试侧轮询 | `Helpers/XCTestExtensions.swift:7-86`（100 ms 轮询，`waitForCondition` 与 `assertEventually` 重复） | 轮询 | 对 `@Observable` 状态改用观察驱动的等待；只有后端不可观察的状态才保留轮询，并把两个函数合并为一个 |

不引入 `any Clock` 抽象或 swift-clocks 依赖：闭包注入已经在 `HistoryRowThumbnailLifecycleScheduler.swift:21`、`HoverPreviewIntentController.swift:26`、`HistoryRelativeTimeClock.swift:42` 三处得到验证，足以满足需求（约束 2、5、6）。

## 4. 性能证据协议（用于替换 `AGENTS.md:37-38`）

### 4.1 反例：历史上被推翻的结论，以及推翻它的原因

以下均出自 `doc/perf/studies/perf-scroll-ceiling-2026-09-04.md`，除非另注。

- "94 ms 滚动卡顿"其实是一次预览弹出。停止滚动后指针还留在列表上，悬停预览的呈现落进了测量窗口（:25-29）。对策：工作负载有效性检查，外加 park 指针。
- 0.80 s 看起来是一次巨大的优化，实际上列表根本没有动：`winpos` 选中了更大的 popover 窗口，输入全被 popover 吞掉（:18-21）。对策：每次 run 必须证明工作负载确实发生了。
- profiler 开销起初按单对测量估计约 1%，每侧 3 次测量后确定为 5.8%（:31-37）。对策：不用单对测量下结论；说绝对 CPU 时必须关掉 profiler。
- "少画一点每行能省 27%"是推理，不是测量。实测去掉元数据行反而慢了 6.6%，因为行变矮、挂载的行变多（:188-202）。对策：先声明指标和预期，再测量；注意改变工作负载的混杂因素。
- 以为 NSTableView 容器是杠杆，实测 busy 反而差 52%（:102, 115-117）。
- v0.80.1 把结论严格限定在 "max callback −36%"，明确写了 "not an application-wide 1.5–2x speedup"；单次 run 的对照标为 "exploratory, not acceptance samples"（`v0.80.1-profile.md:11, 61`）。这是正例。
- 仓库里没有交错驱动。`ab_scroll.py` 只重复运行同一个变体（:1-10）；`perf-frontend-profile.sh` 固定按 AB AB 的顺序运行（:293-298）。研究里的交错 A/B 是手工完成的（:145）。

### 4.2 流程

1. **先声明。** 在测量之前写下：指标（CPU、runloop busy、单键停顿、ΔF 等）、工作负载（脚本名和参数）、判定阈值、预期方向。
2. **构建。** A 与 B 都是 Release 配置，各自从干净的 commit 构建（使用 worktree）。记录两侧的 `git rev-parse HEAD` 和 `Contents/MacOS/Scopy` 的 SHA-256（照 `v0.80.1-profile.md:31-33` 的格式）。
3. **数据。** 一次 `make snapshot-perf-db` 生成一份快照，记录它的 SHA-256 和行数。A、B 两侧各有一份热副本，各先跑 1 次并丢弃结果（生成缩略图和索引缓存）。只有在确认 B 没有改变存储或索引格式时，才允许两侧共用同一份热库。
4. **环境。** 桌面保持安静，关掉其它 Scopy 实例（v0.80.1 有一个空闲的 QA 实例未关，已在该文档中注明），接通电源，固定显示器刷新率，把指针 park 到列表之外。记录芯片、内存、macOS build、Xcode build。
5. **先测 A/A 噪声底。** 同一个 build 交错跑 3 对，得到该工作负载的分辨率。滚动 CPU 的已知 sd 为 0.03-0.08 s（约 1%，研究 :9-10）；打字和 hover 的噪声底目前未知，第一次使用时必须先测出来。
6. **交错运行。** 按 ABBA 或 ABBAAB 的顺序，至少 3 对；预期效应小于 5% 时至少 5 对。
7. **profiler 开关。** 做比例比较时两侧都打开（`scroll_speed`、计数和 AX 读回是工作负载有效性的证据）；声称绝对 CPU 时，另外用 `--no-app-profile`（`profile_scroll.py:20`）跑一组，并注明 5.8% 的仪器开销。
8. **有效性检查。** 每次 run 都要证明工作负载确实发生了：滚动时 `active count > 0`；打字时 AX 读回的查询值等于预期（`profile_search.py:112`）；hover 时 `winwatch` 看到了预览窗口；采集时出现 `UI check: OK`。无效的 run 丢弃，并计入报告。
9. **记录数字。**
   - 每次 run 的原始值：Scopy CPU、WindowServer CPU、runloop busy 总量 / p95 / max、`list.body`、`row.init`、hoverstall 的 p95 / max / 超过 50 ms 的次数、footprint。
   - 每侧的 mean ± sd、min / max。
   - Δ、比值，以及两侧区间是否重叠。
10. **判定规则。** 只有当所有 B 的 run 都优于所有 A 的 run，或者 |Δmean| 大于 2 倍合并 sd 且大于 A/A 分辨率时，才下结论。max 类指标一律报告"各次 run 最大值的中位数"，不引用单个最大值。
11. **写结论。**
    - 指标要写准：CPU 不等于流畅度；callback 间隔不等于 presented frames（dev guide :218）。
    - 同时给出绝对值和相对值。
    - 写明没有测量的内容，例如其它工作负载、presented frame、冷启动。
    - 不外推到"整个 app 快 N 倍"。
    - 因果只归于单一变量，即一个 commit 或一个 flag。
12. **存放。** 结论写进 `doc/perf/studies/` 或发布说明；原始数据放在 `logs/`（已被 gitignore）。`.trace` 文件内嵌了录制进程的完整环境变量，不能直接附到任何地方（研究 :169-171）。

### 4.3 是否值得做 `make perf-gate`

不值得。理由有四：

1. 它的输入只存在于本机：私有的 perf-db、Accessibility 信任、安静的桌面。CI 无法执行，而阈值门禁如果只在本机跑，只会变成新的"假通过 / 假失败"来源。
2. 绝对阈值依赖机器：现有数字都来自 M3 Pro。
3. 唯一稳健的比较方式是同一会话内对两个构建做交错 A/B，这需要一个基线 app，Make 目标还得再去构建一个 worktree。
4. 后端已经有 `test-snapshot-perf-release` 作为门禁。

缺的只是三样东西：一个交错驱动（R5 的 `ab.py`）、`profile_search.py` 中的两处修补，以及本节协议。

`ab.py` 的形状：`scripts/perf-scroll/ab.py <scroll|search|capture|hover|export> --a A.app --b B.app --pairs 3 [--order abba] -- <透传参数>`。
- 按顺序交替调用对应的 `profile_*.py`，对每个工作负载用一组正则解析出数字和有效性证据，输出 JSON 和一张 Markdown 表。
- `--a` 与 `--b` 指向同一个 app 时就是 A/A 模式。
- 它替代 `ab_scroll.py`（约束 1）。

## 5. 本机 UI 验证标准路径（XCUITest 不可用时）

### 5.1 环境约束

- 不要在本机运行任何 `xcodebuild test`（包括 `ScopyUITests`、`make test`、`make coverage`、`make perf-frontend-profile*`、`perf-warm-scroll-ab`）。这些命令一旦失败，就会弄挂 testmanagerd；随后 `make test-unit` 出现 "runner hung" 时，先执行 `kill -9 $(pgrep -x testmanagerd)`。
- 不要用 `--uitesting` 验证面板行为。它会把 NSPanel 换成普通窗口（`AppDelegate.swift:68-72`），并在 Release 下默认使用 mock 服务（`AppStateTests.testReleaseUITestingDefaultsToMockUnlessExplicitlyDisabled`）。`--uitesting` 只用于自动导出。
- 没有 Screen Recording 权限：不截图，改用 AX 读取值和几何信息、CGWindowList 读取窗口层级和 bounds，行像素用 `ImageRenderer`，文档像素用导出 dump。
- 状态栏图标不可点击（Ice）：用 `SCOPY_PROFILE_OPEN_PANEL=1`（`AppDelegate.swift:82`）或全局热键 ⇧⌘C（`panelwatch <pid> --hotkey 8`）打开面板。
- 面板是非激活的 NSPanel：发送键盘事件之前，必须先点一下面板里的某处（通常是搜索框），否则事件会送到前台 app（`scripts/perf-scroll/README.md:83-84`）。
- SwiftUI 父容器上的 `.accessibilityIdentifier` 会覆盖子控件的标识符，需要配合 `.accessibilityElement(children: .contain)` 使用。仓库中已有 5 处这样写，例如 `HistoryItemTextPreviewView.swift:186, 198`。新增需要被 AX 定位的控件时照此处理。
- 行的 AX 标识符和选中值只在两种情况下暴露：`SCOPY_SCROLL_PROFILE=1` 加 `SCOPY_PROFILE_ACCESSIBILITY=1`，或者 `--uitesting`（`HistoryListView.swift:50-52, 560-567`@HEAD）。profile 模式有 5.8% 的开销，所以带这两个环境变量的运行只能做功能判定，不能取性能数字。

### 5.2 步骤模板（每个检查写成一个 `verify_<name>.sh`，输出 `OK` 或 `FAIL`，并以退出码表示结果）

1. 构建：`make release`（或 `make build`）和 `make perf-scroll-tools`。不要用 `deploy.sh`：它会替换已安装的 app。
2. 数据：准备一个临时目录，要么放一份 perf-db 的热副本（真实数据），要么放一个空 DB，再用 `pbwrite` 通过私有 pasteboard 写入种子数据（确定性数据）。
3. park 指针：`warp 1400 40`。
4. 启动：
   `env USE_MOCK_SERVICE=0 SCOPY_SERVICE_DB_PATH=<tmp>/clipboard.db SCOPY_SERVICE_MONITOR_PASTEBOARD=ScopyVerify.$$ SCOPY_PROFILE_OPEN_PANEL=1 [SCOPY_SCROLL_PROFILE=1 SCOPY_PROFILE_ACCESSIBILITY=1 SCOPY_PROFILE_DURATION_SEC=600] "$APP/Contents/MacOS/Scopy" &`
   这些环境变量由 `AppState.swift:78-79, 137-147` 解析。
5. 等待面板出现：循环调用 `winpos $PID`（它会优先返回最高窗口层级的窗口，`winpos.swift:13-24`）。
6. 操作：
   - 点击：`click x y`
   - 键盘：`typekeys <rate> <text>`，支持 `<down>`、`<up>`、`<ret>`、`<esc>`、`<cmd-a>`、`<bs>`
   - hover：`warp`
   - 滚动：`wheel`
   - 热键：`panelwatch --hotkey 8`
7. 观察：
   - AX：`axsearch`、`axrows`，以及 R5 新增的通用 `axquery <pid> <identifier> [attr]`，读取 `AXValue`、`AXPosition`、`AXSize`，并可对元素执行 `kAXPressAction`。
   - 窗口：R5 的 `winwatch <pid> [--seconds N]`，打印每个窗口的 layer 和 bounds 以及它们的变化。它替代 `/tmp/winlist`、不存在的 `build/panelcount`，以及只测面板的 `panelwatch`。
   - pasteboard：由 `enterlatency` 轮询私有 pasteboard 的 changeCount。
   - 日志：在操作之前启动 `log stream --level info --predicate 'subsystem == "com.scopy.app"'`（subsystem 取自 `ScopyLogger.swift:5` 的 bundle id）。
   - 停顿：`hoverstall`。
   - 计数：读取 profile JSON。
8. 断言：写出明确的期望值，例如"窗口数从 1 变为 2 再回到 1"、"`kCGWindowLayer` 从 3 变为 0 再回到 3"。
9. 清理：发送 `SIGTERM`，删除临时目录。
10. 记录：在 PR 或发布说明中写下命令、app 的 SHA-256 和输出。

### 5.3 首批标准检查

| 检查 | 现有脚本 | 断言 |
| --- | --- | --- |
| 点击行会复制并关闭面板 | `verify_row_click.sh` 可用，但依赖 `logs/perf-scroll/db-warm`（:10） | `pasteboard_ms` 与 `hidden_ms` 都不是 nan |
| hover 打开预览，离开后关闭，且 hover 中的行就是指针下的行 | `verify_hover_preview.sh` 目前是坏的：依赖 `/tmp/winlist`、`build/panelcount` 和未编译的 `build/axat`（:20-26） | 窗口数从 n 变为 n+1 再回到 n；指针下那一行的 AX 值为 `selected` |
| 键盘 ⏎ 复制并关闭面板 | `enterlatency`（默认按 return） | 同第一行 |
| 固定预览的窗口层级切换 | 无，§7.7 的实机验证当时是临时手工完成的 | `kCGWindowLayer` 3 → 0 → 3；主面板关闭后固定窗口仍然存在 |
| 输入的查询确实落进搜索框、列表随之变化 | `axsearch` | 字段值等于预期；行的前缀发生变化 |
| popover 以最终尺寸打开 | 由 `winwatch` 提供 | 首次出现之后 bounds 变化次数为 0 |

## 6. 可读性：测试命名

规则：

- 一个文件对应一个 `XCTestCase` 类，文件名就是类名；类名 = 被测的生产类型名 + `Tests`；需要按行为拆分时，写成 `<Type><Area>Tests`。
- 方法名写成 `test<行为><条件>` 形式的句子，沿用仓库里已有的好写法，例如 `testReceiptPreventsDeletedItemResurrection`。
- 禁止用来源（`ReviewFix24`）、层级（`Integration`）或性质（`Concurrency`、`Regression`、`Performance`）命名，除非那就是被测的主体。
- perf 脚本的入口方法以 `Profile` 结尾，放进单独的类，并在类的注释里说明它不是断言性测试。

误导性或无法定位的名字：

| 现在的名字 | 实际被测的内容 | 建议 |
| --- | --- | --- |
| `ScrollPerformanceTests`（29 个方法） | 前 10 个测 `ListLiveScrollObserverView` 的滚动条和指针；后 19 个测 `ScrollPerformanceProfile` 仪器本身 | 前 10 个删除（审计 §3.1）；其余改名为 `ScrollPerformanceProfileTests`，放进 `Tooling/`。其中 `testLegacyLongFrameAliasesPreserveExistingScriptContract`（:751）测的是提供给脚本的 legacy 别名，属于约束 1 的清理对象 |
| `AppStateTests` | 64 个方法中大部分经门面测 `HistoryViewModel` | 拆成 `HistoryViewModel*Tests`，删除门面；`AppStateTests` 只保留测真实 `AppState` 的方法 |
| `HistoryViewModelRegressionTests` | `HistoryViewModel` | 合并到上一行；"Regression" 不携带任何信息 |
| `SearchServiceTests` | `SearchEngineImpl`（:14-16） | 改名为 `SearchEngineTests` |
| `ConcurrencyTests`、`ResourceCleanupTests` | 搜索版本、引擎并发、任务取消、连接关闭混在一起 | 按主体拆开，或按审计删除 |
| `IntegrationTests.swift`（4 个类）、`ReviewFix24Tests.swift`（3 个类） | 多个不相关的主体 | 拆成一类一文件，例如 `ClipboardServiceStartTests`、`StorageServiceClearAllTests`、`SettingsStorePersistenceTests` |
| `ClipboardCopyContractTests` 与 `ClipboardServiceCopyToClipboardTests` | 同一个主体 | 合并为 `ClipboardServiceCopyTests` |
| `HistoryRowPixelSnapshotTests` | 不是测试：靠环境变量开启，唯一的断言是 `width > 0`（:35-36） | 移出 ScopyTests 作为工具，或者删除（§7.3） |
| `HistoryListUITests.testScrollProfile*` | perf 入口，不是测试 | 如果保留，移入 `HistoryListScrollProfile` 类 |

## 7. 明确不做、实施顺序与待决事项

### 7.1 明确不做

- 不建带阈值的 `make perf-gate`（理由见 §4.3）。
- CI 中不做黄金截图比对：不同系统版本和字体下结果不稳定，而且契约 :529 要求使用隔离的 harness。
- 不引入第三方测试框架，包括 swift-snapshot-testing、swift-clocks、Quick/Nimble（约束 5、6：已有能力足够）。
- 不设覆盖率门槛。
- 不在 CI 中运行真实输入的 perf 脚本：它们会向桌面注入事件，并依赖 perf-db。
- 不修 `perf-frontend-profile` 在本机的可用性：阻碍来自系统认证，属于环境问题。
- 不在单元测试里断言 phys_footprint（理由见 §2.B）。
- 不重做卫生审计的删除清单，也不设计产品改进。

### 7.2 实施顺序（每步独立可回滚；每步都按 §1.5 的对应行验证）

1. **Phase 0（全部为 S，互不依赖）**
   - R1 改表。
   - R3 调整 Makefile 与 project.yml。
   - R2：先修掉 4 条 Swift 6 诊断——3 条是 `<unknown>:0` 处 AttributedString 属性 KeyPath 的 Sendable 问题，1 条是 `ClipboardItemContentRevision.swift:49` 的 `memo`。修完后，在 `test-strict` 配方末尾加上 `! grep -q 'error in the Swift 6 language mode' $(LOG_DIR)/strict-concurrency-test.log`，CI 与本机各跑一次。
   - R5 的前两项：修正 `profile_search.py` / `profile_capture.py` 拷贝的缓存文件名，打印 `list.body`。
2. **Phase 1**
   - R6 协议与 R5 的 `ab.py`，然后用 A/A 模式测出打字和 hover 的噪声底。
   - R7：新增 `winwatch`、`axquery`、`pixeldiff`，修复 `verify_hover_preview.sh`。
   - R8 spike。
3. **Phase 2（随各个面落地）**
   - 面 A 开工之前：先落地 R4 和 A4。
   - 面 B：R10、R11。
   - 渲染收敛之前：R9。
4. **Phase 3**
   - R12、R13、R14、R15。R13 做完之后，一次性修改 TSan 的排除路径。

### 7.3 需要 hh 决定

1. **托管 CI 是否运行 XCUITest。** 先用 workflow_dispatch 做 spike；若可行，再决定是每次 push 运行，还是只在渲染器/导出相关路径变化时运行，或者只在发布前运行。
2. **与卫生审计的冲突。** 审计要删除的若干对象，恰好是本文的证据观测点：
   - hover 阶段日志（`HistoryHoverPreviewPipeline.swift:557-563`）；
   - 磁盘缓存命中日志（`SearchEngineImpl.swift:1251-1254, 1309-1312`）；
   - `verify_hover_preview.sh` 与 `axat.swift`；
   - `HistoryRowPixelSnapshotTests`；
   - 要归档的 `hoverstall`、`panelwatch`、`enterlatency`、`ab_scroll.py`。

   二选一：保留它们，并在 dev guide 中登记为证据的消费者；或者删除它们，并接受对应的检查不可做。
3. **PerfFeatureFlags 是否折叠（审计 D3）。** 一旦折叠，`perf-frontend-profile` 的 baseline 与 `perf-warm-scroll-ab` 就失去意义。是否一并删除这些基于 XCUITest 的 perf 目标，以及约 3.4k 行 quality 工具（`summarize-warm-scroll-ab.py` 2,153 行 + `source-manifest.py` 1,222 行，另有已经没有调用者的 `record-gate-result.py` 668 行）。
4. **索引内存上限的语义。** 前缀截断之后，是允许漏检，还是必须由 SQLite 路径补全，这与 `product-spec.md:102` 相关。B1 的断言取决于这个决定。
5. **`make test` / `make coverage`。** 删除，还是改为只运行 ScopyTests。本文建议删除（约束 1）。
6. **strict 门禁。** 修完之后改为"出现诊断即失败"，还是保持只告警。本文建议失败。
7. **默认 skip 的测试。** 例如 LinkEnrichment 的 live fetch：给它一个入口，还是删除。

### 7.4 无法核实的点

- 托管 macos-15 runner 能否运行本 app 的 XCUITest：从未跑过。
- 通过命令行传入的 `SWIFT_STRICT_CONCURRENCY=complete` 是否作用于 SwiftPM 包 target `ScopyKit`。日志中的 4 条诊断都不在包源码里，这既可能说明包源码是干净的，也可能说明包没有被检查；需要查看 ScopyKit 编译命令中的 `-strict-concurrency` 参数。
- A2 在 HEAD 上是否真的为红：没有运行。
- 已测得的"每键 90-180 ms"是否来自带 `--reuse-db` 的 run。如果不是，其中可能包含冷短查询索引的构建成本（缺口 9）。
- 本机 `make test-tsan` 是否真的会运行（本机组合不在跳过表里）。
- CI 各个 job 的实际耗时：没有访问 GitHub。
- `ListInputTurnRecorder` 在 XCTest 的 async 测试中能否按预期收到 `.beforeWaiting`：须由 §2.0 的自证测试确认。
- `ImageRenderer` 对行内 material 和 vibrancy 的渲染保真度。

### 7.5 与 hh 七条硬约束的对照

| 约束 | 本文的做法 |
| --- | --- |
| 1 不保留向后兼容 | 删除 `AppStateTestCompatibility` 门面、`ab_scroll.py`（由 `ab.py` 取代）、legacy long-frame 别名测试，以及不可执行的 Make 目标。R9 的黄金文件带有明确的删除条件 |
| 2 最简实现 | 不做 perf-gate，不做 Clock 抽象，不做覆盖率门槛；只有在上限用确定性 LRU 实现时才写字节断言 |
| 3 先交付端到端纵切 | Phase 0 只改表、Makefile 和两行脚本，就能让现有门禁变得诚实 |
| 4 模块化 | 按面分目录；一类一文件；夹具集中在 `Support/` |
| 5 成熟库优先 | 使用系统自带的 `footprint`、`heap`、ImageIO、Observation 和 CFRunLoopObserver；不自研 profiler |
| 6 先查现有能力 | 复用 interlock 钩子、闭包注入、`SCOPY_PROFILE_*` 环境变量、自动导出路径和 `perf-search-warm-load` |
| 7 按长期架构合入 | 每个新测试都有明确的门禁和退出条件；`ListInputTurnRecorder` 必须先自证；与审计冲突的事项显式交给 hh 决定 |
