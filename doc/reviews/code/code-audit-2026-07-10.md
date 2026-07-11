---
doc_type: review
status: historical
owner: maintainers
last_reviewed: 2026-07-10
canonical: false
---

# Scopy 质量审查与迭代路线 — 2026-07-10

> 时间边界：本报告冻结在安全三角与 DerivedData 隔离完成之后、`v0.65.0` passive-row / menu-cache 工作开始之前。文中的测试数值与待办只代表该审查切片；后续已关闭或改写的结论以 [v0.65.0 Frontend Scroll Profile](../../perf/release-profiles/v0.65.0-profile.md) 和当前规格为准。

## 结论先行

Scopy 已具备不错的工程基础：服务与仓储普遍采用 actor 隔离，搜索和真实数据库性能门禁完整度较高，剪贴板采集已有 durable envelope、背压和并发上限，删除路径也有集中式计划。当前主要问题不是“整体不可维护”，而是少数跨数据库、文件系统和 UI 状态的契约还没有闭环。

本轮已完成两项直接改进：

1. 预览 row-to-popover 使用方向感知安全三角，支持任意方位、多屏负坐标、窗口移动/缩放、相邻行转移所有权及完整取消生命周期。
2. Xcode 产物恢复到 DerivedData，与 SwiftPM `.build` 分离；`deploy.sh release --no-launch` 已连续两次无清理构建并部署成功，消除了 Finder/resource-fork 元数据导致的 CodeSign 重复失败。

剩余风险中有两个真正的 P0：合法的 `>2 GiB` 文件大小会触发整数转换崩溃；自动打 tag 流程不等待完整质量门禁。后续迭代应先修正确性和发布可信度，再做大文件拆分。

## 证据基线

环境：Apple M3 Pro、arm64、macOS 15.7.3 (`24G419`)、Xcode 26.1.1 (`17B100`)。

| 验证项 | 当前结果 | 结论边界 |
|---|---:|---|
| Release 部署 | 连续 2 次通过 | `./deploy.sh release --no-launch`，无清理重复执行 |
| Debug build | 通过 | `make build` |
| 单元测试 | 534 passed，1 skipped | 最终工作树全量基线 |
| Strict concurrency | 534 passed，1 skipped | 新功能文件无新增 strict warning；仓库仍有既存 warning |
| TSan | 514 passed，1 skipped | Hosted test bundle 在当前主机真实运行 |
| Safe-triangle focused | 37 passed | pure policy、controller、coordinator、list ownership |
| Safe-triangle UI | 3 passed | 真实 CGEvent 穿越、离开、返回轨迹 |
| Snapshot release perf | `cmd p95 0.265ms`; `cm p95 2.310ms` | 门槛分别为 50ms / 20ms |
| Safe-triangle microbench | 100k 次约 9.4ms | 约 94ns/次，steady-state 缓存几何 |
| Frontend include-hover | 两项 preview smoke 通过 | 完整 profile 被系统通知中心弹窗干扰；不宣称 corridor 性能证据 |

## 本轮安全三角审查

### 已满足的契约

- `HoverPreviewIntentPolicy` 是纯几何/时间状态机，不依赖 AppKit、异步调度或 observable state。
- `HoverPreviewIntentController` 只在 row-to-popover 转移期间以约 60Hz 采样，硬上限 500ms；每次采样不触发 SwiftUI 重绘。
- 安全三角只在目标 frame 实际变化时重建，steady-state 不分配集合、不重复执行三角函数。
- `PopoverWindowObserver` 在 attach、move、resize、screen-change、close 更新屏幕坐标 frame，并移除全部通知观察者。
- preview kind/token 拒绝过期窗口回调；列表级 owner 阻止相邻行在走廊期间抢占或关闭源预览。
- re-entry、scroll、replace、system close、explicit dismiss、invalidate 和直接析构都有 finish-once 释放路径。

### 尚未阻断发布的后续验证

- 增加真实双行、屏幕边缘重定位的 AppKit UI harness，而不是用普通 `VStack` 伪造走廊几何。
- 增加 `PopoverWindowObserver` attach/move/resize/close/reattach 的隔离测试。
- 在不同 backing scale 的双屏环境做人工协议测试，确认预览尺寸不会因鼠标先跨屏而跳变。

## P0 — 立即处理

### P0.1 合法大文件可确定性崩溃

`Scopy/Infrastructure/Persistence/SQLiteConnection.swift:133` 的 `bindInt` 将 Swift `Int` 直接转为 `Int32`。文件项会在 `Scopy/Utilities/FilePreviewSupport.swift:137` 计算真实总大小，并经 `Scopy/Application/ClipboardService.swift:1138`、`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:244` 写回。任一正常的 4K 视频、磁盘镜像或多文件总计超过 2 GiB 时都会 runtime trap；项目已经入库，重启后可能再次计算并形成重复崩溃。

改进：所有 byte count/持久计数使用 `Int64` + `sqlite3_bind_int64`；多文件求和使用 checked 或 saturating addition；分页参数单独做范围验证。

验收：5 GiB sparse file 完成采集、重启、读取、排序、删除；大小精确 round-trip，零崩溃、零 overflow。

### P0.2 自动 tag 可绕过质量门禁发布

`.github/workflows/auto-tag.yml:3` 在 main 的 release/docs 路径变化后触发，`:27` 只执行弱版 release-doc 校验，随后直接推 tag；它不等待 `.github/workflows/ci.yml:14` 的 build/unit/strict，也不验证 docs、UI smoke 或性能结果。

改进：优先取消自动 tag，保留显式 `make tag-release`；若必须自动化，使用 `workflow_dispatch + commit SHA`，在同一 workflow 的完整 required jobs 成功后才创建 tag。

验收：故意制造 build 失败、broken docs 或 metadata/index 漂移时绝不产生 tag；成功路径只产生一个目标 tag。

## P1 — 正确性、性能和一致性

### P1.1 文件系统与数据库缺少统一提交协议

- 外部图片优化先原地改文件，之后才更新 DB：`Scopy/Application/ClipboardService.swift:696`。中途崩溃会让 hash、size、thumbnail 与文件内容分裂，备份还可能被 orphan cleanup 删除。
- `>=100 KiB` durable payload 在 DB insert 前被移动；insert 失败后 payload 被删但 envelope 保留：`Scopy/Services/ClipboardMonitor.swift:835`、`Scopy/Services/StorageService.swift:278`，重启无法真正重放。
- actor 方法跨 `await` 不是逻辑事务，repository UPDATE 又不检查 affected rows：`Scopy/Application/ClipboardService.swift:349`、`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:170`，可能产生 ghost search/UI event。

改进：受管文件采用“写新版本→校验→CAS 切换 storage_ref→提交后删旧文件”；durable spool 在 DB commit 前不转移所有权；mutation 返回 `updated/notFound/conflict`，只有持久化成功后才更新索引和发事件。

验收：对写完新文件、DB commit 前后、旧文件删除前逐点故障注入；对 copy/optimize 与 delete 做确定性交错；任一重启点 DB、文件、hash、搜索和 UI 都一致。

### P1.2 主线程和外部进程缺少明确预算

- `ClipboardMonitor` 为 `@MainActor`，大 payload spool、RTF/HTML 解析仍可能在主线程执行：`Scopy/Services/ClipboardMonitor.swift:732`、`:1666`。
- `PngquantService` 阻塞写 pipe、顺序读 stdout/stderr、无限 `waitUntilExit`：`Scopy/Services/PngquantService.swift:95`。异常 binary 可永久挂起或 pipe deadlock。
- UI 在主线程重复 `fileExists`/storage-ref 解析：`Scopy/Views/History/HistoryItemView.swift:373`、`Scopy/Observables/HistoryViewModel.swift:834`。

改进：主线程只做 pasteboard snapshot；spool/解析/hash 进入有界 worker。抽 `BoundedProcessRunner`，并发 drain、输出上限、deadline、cancel→terminate→kill。文件动作由 backend 提供 typed async capability，点击时重验。

验收：1/10/100 MiB PNG、TIFF、RTF、HTML 的主线程单段 P99 `<8ms`；never-exit/flood fake process 在 deadline+grace 内结束且无子进程；网络卷 stat 不出现在 row body。

### P1.3 缓存和后台任务在规模增长后行为退化

- `HistoryItemPresentationCache` 达到 4096 后拒绝所有新 key，旧热集永久冻结：`Scopy/Presentation/HistoryItemPresentationCache.swift:40`、`:67`；display-text 20k cache 有相同模式。
- pinned 启动读取全部 raw payload，并为大量 DTO 创建独立衍生任务：`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:381`、`Scopy/Application/ClipboardService.swift:1098`。
- 50MB thumbnail cleanup 只有定义没有调用：`Scopy/Services/StorageService.swift:1421`，磁盘缓存实际无界。

改进：统一 bounded LRU/clock cache；pinned 使用 summary + 分页，只为 visible/prefetch 创建有界 job；缩略图删除与统一预算器联动并离开主线程。

验收：第 4097/20001 个 key 可命中且旧项按策略淘汰；10k pinned 首屏工作量为 `O(visible + prefetch)`；生成再删除 10k 缩略图后磁盘不超过预算+单文件余量。

### P1.4 UI 状态模型仍有“看似成功/一直加载”路径

- 图片或 Markdown 预览失败会落入永久 spinner：`Scopy/Views/History/HistoryHoverPreviewPipeline.swift:341`、`:519`，以及两个 preview view 的 nil/loading 分支。
- Settings 读取失败静默回退 `.default`，用户保存可能覆盖原配置：`Scopy/Observables/SettingsViewModel.swift:62`、`Scopy/Views/Settings/SettingsView.swift:199`。
- 多个 copy/pin/delete/note/clear 错误只写日志：`Scopy/Observables/HistoryViewModel.swift:677`。

改进：统一 `loading/ready/empty/failed` 和 `OperationFeedback`；设置加载失败禁止编辑/保存，只提供重试和诊断；错误通过可访问性 live announcement 播报。

验收：损坏图片、被移动文件、权限错误、DB 读取失败和 mutation 失败都有确定终态、原因和可重试路径；不存在任务已结束但 spinner 超过 2 秒。

### P1.5 View equality 与真实动作依赖不一致

`HistoryItemView.==` 只比较四个 settings 字段（`Scopy/Views/History/HistoryItemView.swift:103`），但上下文菜单 PNG 导出闭包会消费全部 pngquant 配置（`:983`、`Scopy/Views/History/HistoryItemMarkdownExportController.swift:77`）。仅修改压缩设置时，`.equatable()` 可能保留旧闭包，导致两个导出入口配置不同。

改进：建立完整的 `HistoryItemRenderKey/ActionConfiguration`，或让动作触发时从单一设置源读取当前值，避免在 Equatable view 中捕获设置快照。

验收：逐一修改 pngquant 开关、路径、质量、速度、颜色后，无需刷新列表，两个入口都收到同一新配置。

### P1.6 性能与 CI 证据尚未形成真正门禁

- frontend profile 只验证 bucket/样本存在，不断言 frame/drop SLO：`scripts/perf-frontend-profile.sh:614`；历史 profile 曾有 drop ratio 0.141，仍可返回成功。
- PR CI 跳过 31 个 integration tests、全部 UI、docs/release validation：`.github/workflows/ci.yml:14`。
- Strict 已暴露既存 Swift 6 隔离 warning，例如 `UnifiedMarkdownRenderer.bundleAvailabilityOverride`，但当前并未按“新增 warning 为零”自动比较。

改进：建立单一机器可读 SLO；strict profile 用三次 median + 绝对上限返回非零。PR required 加 docs/release/quick integration；UI smoke 覆盖 launch、settings Save/Cancel、安全三角三条；nightly/release 跑 full UI、heavy perf、TSan。

验收：人工构造超阈值 summary、broken link、clipboard regression 或 safe-triangle UI regression 时，对应 gate 必须变红。

## P2 — 结构与产品一致性

- `SearchEngineImpl.swift` 仍超过 5k 行，并同时负责索引生命周期、执行、SQLite 和 scoring。保留单 actor façade，按 `SearchReadStore/IndexLifecycle/SearchExecutor/Scorer/DiskCacheStore` 做行为切片，不做一次性重写。
- `HistoryItemView.swift` 仍超过 1.4k 行。安全三角抽取方向正确，下一步拆 `RowContent/ActionMenu/PreviewHost`，同时用 render key 和 UI 回归锁行为。
- hover 预览缺少键盘等价入口；建议 Space 打开当前选中项，popover 恢复焦点，比例控件可由键盘/VoiceOver 展开与调整。
- Pinned header、图标筛选 Menu、多个 Slider 缺少稳定 AX label/value；主列表与设置中英文混用，需统一 String Catalog 和可访问性检查表。
- Settings 的 hotkey 立即持久化与整体 Save/Cancel 事务模型不一致。若保留例外，必须独立呈现并明确 Cancel 不撤销；更一致的方案是 Save 提交、Cancel 恢复 baseline 注册。
- `ClipboardServiceProtocol` 部分默认实现静默 no-op/空结果，建议拆 capability protocol 或显式 `unsupported`，避免新 backend 编译通过但语义缺失。

## 推荐迭代顺序

### Sprint 0 — 发布可信度与崩溃热修（1–2 天）

1. Int64 文件大小迁移 + 5 GiB sparse-file 回归。
2. 关闭/重构 auto-tag；把 docs/release/build/unit/strict 变为 tag 前置条件。
3. 合并本轮 safe-triangle 与 DerivedData 构建隔离，锁定 release metadata。

### Sprint 1 — 存储事务与有界执行（约 1 周）

1. 外部文件版本化提交协议与 failure injection。
2. durable spool ownership/ack、affected-row/CAS、item mutation generation。
3. `BoundedProcessRunner`、ingest cancellation cleanup、100MB capture/restore 统一契约。

### Sprint 2 — UI 状态和一致性（约 1 周）

1. Preview/Settings/Mutation 统一显式状态与反馈。
2. 修复 Equatable action settings；固定 preview session 的 anchor-screen metrics。
3. 键盘预览、焦点恢复、AX label/value、hotkey Save/Cancel 决策。

### Sprint 3 — 规模性能和结构收敛（持续）

1. bounded cache、pinned summary pagination、thumbnail budget、真正有界 job queue。
2. 把 frontend SLO、warm-load/RSS 趋势和 UI smoke 变为 CI/release gate。
3. 在行为测试保护下拆分 HistoryItemView 和 SearchEngine 内部职责。

## 关闭或降级的旧结论

- warm-load/RSS 已有 `v0.64` 基线和 `make perf-search-warm-load`，问题已从“没有证据”降为“缺自动阈值/趋势”。
- AppState 已收敛到约 281 行，继续拆分是 P2，不再是首要架构风险。
- UI suite 已比旧审查广泛，但仍未进入 PR required gates。
- Hosted TSan 路径和本地可运行 TSan 已存在，不再把“只有 target”列为缺陷。

## 审查边界

本报告来自当前源码、现有测试、真实本机构建/性能运行和三个并行专项审查。UI 审查未获得本轮运行时截图、对比度测量或 VoiceOver 实机结论；双显示器结论仍需在不同 backing scale 的真实硬件上验证。未实测项已明确写为建议或验收指标，不当作已确认性能事实。
