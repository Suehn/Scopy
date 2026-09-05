---
doc_type: review
status: historical
owner: maintainers
last_reviewed: 2026-09-05
canonical: false
---

# Scopy 系统性精简审查 — 2026-09-05

## 范围与完成条件

从 `d214a13`（当前 v0.80.1 发布后的 main）重新审查源码、测试、仓库相关 skills、开发指导和架构。判断依据是当前消费者、产品契约和执行结果，而非历史投入、文件长度或测试数量。前一次 [代码/工具链审查](./code-audit-2026-09-05.md) 是独立历史记录，本次不重复计算它的成果。

在隔离分支 `codex/scopy-simplification-20260905` 完成三个任务包：

1. **采集实现与测试合一**：测试观察生产采集事件，删除第二套解析实现；原有内容语义断言通过。
2. **删除无消费者的机制**：设置广播和测试辅助框架有明确的零调用证据；保留真实产品边界和被使用的辅助方法。
3. **开发规则与 skill 去重**：AGENTS、产品契约、开发指南、发布 runbook 各有清晰职责；所有必要发布验收仍有唯一可达位置。

停止条件是上述三个任务的实现、验证和裁决记录完成。本报告不宣称整个代码库已不存在冗余，不用没有测量的性能提升作为成果。

## 结论与实际实施

| 范围 | 当前证据 | 裁决与结果 |
| --- | --- | --- |
| 剪贴板解析 | `readCurrentClipboard -> extractContent` 只被测试调用；运行时走 `checkClipboard -> extractRawData -> contentStream`，存在两套优先级/富文本/图片处理 | 删除同步解析分支、旧图片转换入口及无调用的轻量指纹代码。46 个旧读取调用点改为真实轮询与事件断言，图片经过生产 durable worker |
| 测试可信度 | 两个 KaTeX 测试在旧解析器上通过，切到生产流程后失败 | 修复生产快路径漏判：`application/x-tex` annotation 即使没有 `$` 或反斜杠，也可能产生 TeX 内容，必须提取。保留并重命名原语义测试，而非放宽断言 |
| 设置事件 | `SettingsStore.observeSettings` 没有消费者；实际设置通知走 service event stream 与 `.settingsChanged` | 删除 subscriber 表、注册/终止任务和广播；保留保存、缓存、热键合并和 Save/Cancel 行为 |
| 测试辅助 | 四个 helper 文件混有无调用的异步计时、内存测量、通用断言、场景工厂、旧 debounce SLO、mock reset API | 只删零消费者内容，保留被 `PerformanceTests` 等使用的测量/统计方法；所有测试源码参与编译 |
| 无效测试 | 初始化测试仅检查非可选对象非空；应用 ID 测试只打印前台应用信息 | 删除这两个测试。其他小测试只要约束真实行为就保留，不按行数或断言数裁撤 |
| AGENTS / CLAUDE | 重复工程原则、验证、渲染和发布规则；CLAUDE 还复制了会漂移的功能/版本模板 | AGENTS 成为共享操作入口，CLAUDE 只导入 AGENTS；行为和数值指向所属 canonical 文档 |
| 发布 skill | 175 行包含重复 runbook、强制 coauthor、一次事故的全局 Git 配置/固定临时目录删除配方 | 精简至 19 行，保留目标版本、tag、两份 cask、安装和环境阻塞的关键决策。完整 Homebrew 验收集中到 runbook，未执行发布 |
| 开发/架构文档 | renderer 契约被多处复述；开发指南同页出现 load-more 100 与 500 两种数值 | 删除第二套功能矩阵和渲染规范，修正过时的 100 条说明，保留模块映射、生命周期/存储约束与独有操作线索 |
| 历史发布证据 | 日常 runbook 连续叠加多个版本的历史数值，容易误认成当前验收 | 历史证据逐字移至 archive 并保留链接；runbook 聚焦执行。归档移动不算代码删除或证据消失 |

## 找到的真实缺陷

HTML 为 KaTeX annotation `E = mc^2`，plain-text 为 `Equation E equals m c squared` 时，生产 `mayContainTeXCharacters` 只检查字符/实体，错误地认为 HTML 导入不能改变文本。类似问题也影响 RTF + HTML 的 `$W_p$` 恢复。

迁移后的两个测试先失败，修复 annotation 检查后通过。另一个初次迁移失败来自测试启动过早，使 replay fixture 在监控启动后才落盘；已将启动限定到各个采集测试，保留回放测试原有生命周期。没有为解决夹具问题修改生产回放协议。

现在采集测试在独立命名 pasteboard 和临时 spool 中启动监控，调用同一个内部 `checkClipboard`，等待 `contentStream`。直接轮询避免依赖 timer 碰巧触发；durable replay/队列/转换测试继续验证实际异步边界。重复内容哈希测试通过真正的第二次复制触发第二个事件。

## 明确保留的复杂度

| 候选 | 保留理由 |
| --- | --- |
| `RealClipboardService` 转发层 | 它是 `@MainActor ClipboardServiceProtocol` 到后端 actor 的隔离适配器。删除需要重做 UI 协议隔离，不能仅凭“转发很多”判为兼容垃圾；已改掉误导的兼容层注释 |
| durable ingest、receipt、cleanup revalidation | 分别保护重启回放、幂等入库和提交时删除身份，属于数据一致性职责 |
| 搜索 coverage、generation、cache revision | 防止旧结果发布、错误复用与缺失结果；并非多个名字表示同一状态就可合并 |
| WebView owner lease/render ID/readiness | 生命周期竞态与导出完整性有真实回归覆盖；不以删除等待/校验换取表面速度 |
| 性能 A/B flags 与 harness | `PerfFeatureFlags` 的当前对照轴被 profiling 脚本消费。应先完成同方法验收并退役实验轴，再成组删除旧分支和脚本；不能同时删掉证据来源再宣布更快 |
| 大型 SearchEngine/ClipboardService/Markdown 文件 | 行数说明维护成本，不自动证明功能冗余。优先删重复状态或职责，再根据可验证边界拆分；本次不做机械搬文件 |
| `scopy-export-png` 共享 skill | 它包含真实应用自动导出入口、环境变量和 PNG 检查，是发布 skill 没有覆盖的能力；检查后保留。无关研究/插件 skills 不属于 Scopy 本次裁撤范围 |

## 数量变化

以基线 Git blob 与本次文件逐行计数，非运行时性能指标：

| 范围 | 前 | 后 | 净变化 |
| --- | ---: | ---: | ---: |
| 三个修改的运行时文件 | 3,348 | 3,040 | -308 |
| 测试 helpers 目录 | 1,185 | 631 | -554 |
| AGENTS + CLAUDE + 发布 skill | 575 | 73 | -502 |
| 三份 active 架构/开发/发布文档 | 761 | 496 | -265，部分内容归档保留 |

AGENTS 135 → 49 行；CLAUDE 265 → 5 行；发布 skill 175 → 19 行。采集测试因显式启动、异步事件验证增加了代码，这是替换无效测试入口所需的成本，不追求每个文件都缩短。

## 验证与限制

环境：Apple M3 Pro、macOS 15.7.3、Xcode 26.1.1（17B100）；项目 Swift/最低系统版本未改变。

| 验证 | 结果 |
| --- | --- |
| 最终 `make build` | 通过 |
| 采集 + 设置定向 XCTest | 59 项，零失败 |
| 普通 build-for-testing + 单测范围直接 XCTest | 828 项，4 skipped，零失败 |
| `SWIFT_STRICT_CONCURRENCY=complete` build-for-testing + 同范围直接 XCTest | 828 项，4 skipped，零失败 |
| `make docs-validate` / `make release-validate` | 通过 |
| `make test-tooling` | 7 shell/Make、17 source-manifest、36 warm-scroll 检查及 quality-manifest self-test 通过 |
| `make test-release-policy` | 15 项通过 |
| skill-creator `quick_validate.py` | 通过；通过 `uv run --with pyyaml` 提供隔离依赖，无仓库依赖变更 |
| 文档本地链接 / 历史证据逐字比对 / `git diff --check` | 通过 |

当前会话之前已确认 IDE-managed XCTest 在 host/IDE session 初始化阶段停滞，本次用 `xcodebuild build-for-testing` 产物直接运行 XCTest；不是把 `make test-unit` / `make test-strict` 的 IDE 调度路径记为通过。类选择与这两个 Make 目标一致：排除 `IntegrationTests`、`PollingIntervalSettingTests`、`ClipboardServiceContentFilteringIntegrationTests`、`PerformanceTests`。命令和排除列表保存在日志 JSON 中。

四个跳过项分别需要 row snapshot 输出目录、网络开关、`SCOPY_PERF_METRICS=1`、`RUN_PERF_TESTS`。Strict 编译仍报告未改动的 export raw-pointer、NSCache 和 SDK key-path Sendable 警告；本次通过不等于 Swift 6 零警告迁移完成。未改 renderer、搜索、清理或滚动策略，未跑新 PNG、TSan 或真实 DB/前端性能验收；不声称这些路径本次被重新验收，也不声称 runtime 速度提升。

日志保留于隔离 checkout 的 `logs/simplification-*.log` 和 `logs/simplification-*-command.json`；交付时复制到主工作区 `logs/simplification-audit-20260905/`。用户原有三个 UI 文件的未提交 diff 在合并前后逐字核验，不纳入此提交。

## 后续候选及启动条件

这些是裁决后的候选，不是本次未完成的实施承诺：

1. **退役性能实验轴**：列出每个 flag 的生产分支、脚本消费者与最后一份已验收同方法对照；冻结生产选择，再同时删分支/配置/场景，跑 snapshot + 真实滚动回归。验收标准是产品语义及 SLO 不退化，不是单纯减少开关数。
2. **测试磁盘副作用**：本次单测生成了以 `file:scopy_test_...?...mode=memory...` 命名的 index sidecar。后续需统一 SQLite URI 与磁盘缓存路径资格判断，并证明内存 DB 不落 sidecar、真实 DB 仍能重启复用缓存。本次只清理隔离 checkout 内由此次测试产生的文件，未修改搜索缓存逻辑。
3. **并发警告清账**：逐个核对现有 raw pointer / NSCache 的实际隔离，不用 `@unchecked Sendable` 批量消警告。与 Swift 6 基线迁移分开验收。

开放 PR/旧分支的上一轮裁决在前次报告中。本次没有远程合并、发布、删除分支或卸载全局插件；范围集中在当前实现及其维护负担。
