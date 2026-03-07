# Uncommitted Changes Deep Review (2025-12-28)

## Review Meta
- 项目：Scopy
- 范围：当前工作区未提交改动（`git diff`）
- 目标：优雅性 / 稳定性 / 性能 / 向后兼容（尽可能“零回归”）
- 最近更新：2025-12-28（重新 review）
- 构建/测试结果：
  - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`：通过（2025-12-28）

## 改动概览（高层）
本次未提交改动主要引入了：
1. **文件条目增强**：Quick Look 预览 + Markdown 文件渲染预览 + 文件缩略图 + 文件备注编辑。
2. **可搜索备注**：DB 新增 `note` 字段，并纳入 FTS 与 fuzzy 搜索文本。
3. **文件大小展示**：新增 `fileSizeBytes`（与历史的 `sizeBytes` 区分：`sizeBytes` 更偏“剪贴板载荷/序列化成本”，`fileSizeBytes` 更偏“磁盘文件实际大小”）。

涉及的核心文件：
- Persistence / Migration：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`、`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`
- Service：`Scopy/Application/ClipboardService.swift`、`Scopy/Services/ClipboardMonitor.swift`、`Scopy/Services/StorageService.swift`
- Search：`Scopy/Infrastructure/Search/SearchEngineImpl.swift`
- UI：`Scopy/Views/History/HistoryItemView.swift`、`Scopy/Views/HistoryListView.swift`、新增 `Scopy/Views/History/*File*.swift`、`Scopy/Views/History/QuickLookPreviewView.swift`

## 未提交文件清单（当前工作区，2025-12-28）
> 说明：以 `git diff --name-only` 为准；该列表会随修复滚动更新。

**Modified**
- `Scopy/Application/ClipboardService.swift`
- `Scopy/Domain/Models/ClipboardItemDTO.swift`
- `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`
- `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`
- `Scopy/Presentation/ClipboardItemDisplayText.swift`
- `Scopy/Services/ClipboardMonitor.swift`
- `Scopy/Services/StorageService.swift`
- `Scopy/Utilities/FilePreviewSupport.swift`
- `Scopy/Views/History/HistoryItemFilePreviewView.swift`
- `Scopy/Views/History/HistoryItemFileThumbnailView.swift`
- `Scopy/Views/History/HistoryItemView.swift`
- `Scopy/Views/History/MarkdownPreviewCache.swift`
- `doc/implementation/reviews/2025-12-28_uncommitted-changes-deep-review.md`

## 关键结论（TL;DR）
- **架构方向正确**：DB/Repository/FTS 的演进方式稳健，Search 合并 `note` 的策略符合产品预期，UI 预览的任务取消与 popover 协调也比较细致。
- **存在 4 类必须优先处理的问题**：
  1) 主线程/热路径的文件 IO（可能造成粘贴板检测卡顿、滚动卡顿）；  
  2) Markdown 文件预览缓存 key 的语义问题（可能出现“内容已变但预览仍旧”或 “text/HTML 不一致”）；  
  3) `toDTO` 重复扫盘（列表/事件触发时反复读文件大小）；  
  4) 测试 target 编译阻塞（多个 stub/mock 与 DTO 初始化未更新，无法用自动化证明“无回归”）。

## 修复进度（2025-12-28）
> 目标：保留新功能不变，同时消除性能/稳定性回归风险。

- S1-1（主线程文件大小 IO）：已修复，移除 `ClipboardMonitor` 的 `fileSizeKey` 同步遍历；改为后台计算并写回 DB。参考：
  - `Scopy/Services/ClipboardMonitor.swift`（不再读取 `fileSizeKey`）
  - `Scopy/Application/ClipboardService.swift:886`（`scheduleFileSizeComputationIfNeeded`）
  - `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:212`（`updateItemFileSizeBytes`）
  - `Scopy/Services/StorageService.swift:368`（`updateFileSizeBytes`）
- S1-2（Markdown 文件预览缓存语义/一致性）：已修复，引入 3h TTL 的“读盘预览缓存”，缓存 `text/html/metrics/fetchedAt`，避免 text/HTML 不一致。参考：
  - `Scopy/Views/History/HistoryItemView.swift:129`（`markdownFilePreviewCacheTTL` + `startMarkdownFilePreviewTask`）
  - `Scopy/Views/History/MarkdownPreviewCache.swift:15`（`FilePreviewEntry`）
- S1-3（`toDTO` 重复扫盘）：已修复，移除 `toDTO` 内同步读盘，改为 lazy 后台刷新。参考：
  - `Scopy/Application/ClipboardService.swift:866`（`toDTO` 内触发后台刷新）
- S1-4（测试 target 编译阻塞）：已修复（向后兼容策略），并已全量跑通 ScopyTests。参考：
  - `Scopy/Domain/Models/ClipboardItemDTO.swift:22`（新增参数默认值）
  - `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift:81`（`updateNote` 默认 no-op）
- S2-1（0-byte 文件显示“未知大小”）：已修复，`0 B` 作为合法显示。参考：
  - `Scopy/Presentation/ClipboardItemDisplayText.swift:317`（`computeFileMetadata` / `formatBytes`）
- S2-4（文件缩略图缺失空白占位）：已修复，缩略图不存在/加载失败时回退到文件类型图标。参考：
  - `Scopy/Views/History/HistoryItemFileThumbnailView.swift:51`（placeholder 图标回退）

## 二次 review 追加修复（2025-12-28）
- 文件大小后台计算不再“丢任务”：避免分页 `limit=100` 时部分 file item 永久不触发计算（`Scopy/Application/ClipboardService.swift:886`）。
- 文件预览启动不再同步 `fileExists`：`startFilePreviewTask` 使用 `requireExists: false`，降低网络盘/外置盘路径导致的 UI 卡顿概率（`Scopy/Views/History/HistoryItemView.swift:975`）。
- Markdown 文件预览 metrics 也写回缓存：减少 re-hover 时的尺寸抖动与重复测量（`Scopy/Views/History/HistoryItemView.swift:753`）。

## 三次 review 追加修复（2025-12-28）
- 文件预览视图避免主线程 `fileExists`：将存在性检查移到后台并缓存到 `@State`（`Scopy/Views/History/HistoryItemFilePreviewView.swift:53`、`Scopy/Views/History/HistoryItemFilePreviewView.swift:147`）。
- fileSizeBytes 写回 DB 降低 SQL 往返：`updateFileSizeBytes` 值未变化时不写 DB；`applyComputedFileSizeBytes` 去掉重复读取（`Scopy/Services/StorageService.swift:368`、`Scopy/Application/ClipboardService.swift:948`）。
- `readTextFile` 读取失败不再误判为空文件：读取异常返回 `nil`，避免“空预览”掩盖错误（`Scopy/Utilities/FilePreviewSupport.swift:100`）。

## 四次 review 追加修复（2025-12-28）
- UI 性能：文件条目 title/metadata 计算避免全量 split/数组分配，改为单次扫描统计（降低“复制大量文件后历史列表渲染/滚动卡顿”的风险）。参考：
  - `Scopy/Presentation/ClipboardItemDisplayText.swift:212`（`computeTitle`）
  - `Scopy/Presentation/ClipboardItemDisplayText.swift:343`（`summarizeFilePlainText`）
  - `ScopyTests/ClipboardItemDisplayTextTests.swift:33`（新增回归测试，确保行为不变）
- 解析优化：`primaryFileURL` 在只需要首个文件时不再对整段 plainText 做全量 split（避免对超长路径列表产生额外分配）。参考：
  - `Scopy/Utilities/FilePreviewSupport.swift:51`（`primaryFileURL`）
- 内存/状态清理：fileSizeBytes 写回成功后清理 `fileSizeComputationLastAttemptAt`，避免长期运行后字典增长。参考：
  - `Scopy/Application/ClipboardService.swift:960`（成功写回后 `removeValue(forKey:)`）
- 后台并发控制：缩略图生成增加并发上限（避免大量缺失缩略图时后台任务并发过高抢占 CPU/IO）。参考：
  - `Scopy/Application/ClipboardService.swift:969`（`acquireThumbnailGenerationSlot`）
  - `Scopy/Application/ClipboardService.swift:1035`（生成任务中 acquire/release）

---

# 发现清单

> 分级：S1（高风险/可能回归），S2（可维护性/一致性），S3（风格/可读性/优化建议）
> 每条包含：位置(file:line)、问题、影响、建议、验证方式（可执行）

## S1：高风险 / 可能回归

### S1-1 性能回归风险：文件拷贝时在主线程遍历文件并读取大小
- 状态：✅ 已修复（2025-12-28）
- 位置：
  - `Scopy/Application/ClipboardService.swift:866`（`toDTO` 触发后台计算）
  - `Scopy/Application/ClipboardService.swift:886`（`scheduleFileSizeComputationIfNeeded`）
  - `Scopy/Services/StorageService.swift:368`（计算完成后写回 DB）
- 问题：
  - 修复前：`ClipboardMonitor`（`@MainActor`）在文件复制路径会同步遍历 URL 并读取 `fileSizeKey`，大量文件/网络盘/外置盘场景可能阻塞剪贴板轮询与 UI。
  - 修复后：主线程不再读取 `fileSizeKey`；文件大小改为后台 best-effort 计算（限流/去重/3h 重试）并持久化。
- 影响：
  - 用户感知为：复制大量文件后 Scopy 卡顿、历史列表滚动掉帧、hover 预览延迟抖动。
- 建议（从保守到激进）：
  1. **保守修复**：主线程只收集路径/序列化数据，不读文件大小；将文件大小统计移到后台任务（例如 ingest 的 `Task.detached` 分支）并附带超时/数量上限。
  2. **延迟 + 持久化**：`fileSizeBytes` 在后台计算后写回 DB（避免每次加载都重复扫描）。
  3. **降级策略**：当文件数 > N / 路径位于网络卷 / 读取超时，直接返回 `nil`，metadata 显示“未知大小”，但保证 UI 不阻塞。
- 验证方式：
  - 手动：复制 1000+ 文件、网络盘文件、或包含“失联挂载点”的文件列表，观察 Scopy 的 CPU 峰值与 UI 响应。
  - 自动化（可选）：加入 micro-benchmark 或 profile log（如已有 `ScrollPerformanceProfile`）。

### S1-2 预览正确性：Markdown 文件预览缓存 key 可能导致“内容变了但 HTML/metrics 仍旧”
- 状态：✅ 已修复（2025-12-28）
- 位置：
  - `Scopy/Views/History/HistoryItemView.swift:129`（`markdownFilePreviewCacheTTL`）
  - `Scopy/Views/History/HistoryItemView.swift:131`（`startMarkdownFilePreviewTask`）
  - `Scopy/Views/History/MarkdownPreviewCache.swift:15`（`FilePreviewEntry`）
- 问题：
  - 修复前：Markdown 文件预览缓存只看 key，可能在磁盘内容变化后复用旧 HTML/metrics，导致预览陈旧或 `text` 与 `markdownHTML` 不一致（尤其当缓存命中）。
  - 修复后：引入 3 小时 TTL 的文件预览缓存，缓存 `text/html/metrics/fetchedAt`，并保证命中缓存时 `text/html/metrics` 同源。
- 影响：
  - 用户感知为：hover 一个 Markdown 文件，预览显示旧内容；或先 hover 看到旧内容，稍后再 hover 仍旧旧内容。
- 建议：
  - 已选择“读盘语义 + 3 小时最多刷新一次”的折中（避免 hover 频繁读盘造成 UI 抖动/IO 风暴）。
  - 若未来需要更实时：可升级为 `mtime/size` 参与 key，或监听文件变更事件触发失效。
- 验证方式：
  - 手动：复制一个 `.md` 文件到 Scopy → hover 出预览 → 修改磁盘内容（保存）→ 再 hover，确认预览随之变化且不会“卡在旧 HTML”。

### S1-3 性能隐患：`toDTO` 在 `fileSizeBytes == nil` 时同步扫描磁盘，且可能重复发生
- 状态：✅ 已修复（2025-12-28）
- 位置：`Scopy/Application/ClipboardService.swift:866`
- 问题：
  - 修复前：`toDTO` 在 `fileSizeBytes == nil` 时同步遍历磁盘读取 `fileSizeKey`，并可能在列表/搜索/事件路径重复触发。
  - 修复后：`toDTO` 只触发后台计算（限流/去重/3h 重试），计算完成写回 DB 并发出 `.itemContentUpdated` 刷新 UI。
- 影响：
  - 列表刷新、搜索、滚动过程中出现重复磁盘扫描，导致吞吐下降与延迟抖动。
- 建议：
  1. **避免在 `toDTO` 做磁盘扫描**：改为后台懒加载（一次计算 + 写回 DB），UI 初次显示可先展示“未知大小”。
  2. **只对可见/选中项计算**：比如 hover/选中时才触发计算，避免加载一页就扫盘。
  3. **对多文件条目做上限**：文件数过多时直接降级不计算，避免 O(n) 扫盘扩大。
- 验证方式：
  - 手动：历史中存在大量旧 file item（`fileSizeBytes == nil`）时，打开/滚动/搜索的 CPU 与磁盘访问是否明显上升。

### S1-4 回归证明缺口：测试 target 编译失败，当前无法用单测证明“无回归”
- 状态：✅ 已修复（2025-12-28）
- 位置：
  - `Scopy/Domain/Models/ClipboardItemDTO.swift:20`（新增参数提供默认值）
  - `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift:76`（`updateNote` 默认 no-op）
- 问题：
  - 修复前：协议/DTO 签名变化导致多个测试 stub/mock 不 conform 或构造失败，从而 `xcodebuild test` 在编译阶段终止。
  - 修复后：通过“向后兼容默认值/默认实现”恢复测试可编译可运行。
- 影响：
  - 这会掩盖真实回归（尤其 UI/服务联动改动较多时），降低交付置信度。
- 建议：
  1. **`ClipboardServiceProtocol.updateNote` 提供默认实现**（类似已有 `stopAndWait`），让旧 stub 不必立刻实现；或批量补齐所有测试 stub 的空实现。
  2. **为 `ClipboardItemDTO` 的新增参数提供默认值 `= nil`**，保持向后兼容（测试/调用点无需“全仓库补参”）。
- 验证方式：
  - 目标：`xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests` 恢复可运行，并尽量全绿。

### S1-5 性能回归风险：文件预览 Popover 在主线程同步 `fileExists`
- 状态：✅ 已修复（2025-12-28）
- 位置：
  - `Scopy/Views/History/HistoryItemFilePreviewView.swift:60`（`previewContent`）
  - `Scopy/Views/History/HistoryItemFilePreviewView.swift:100`（`isFileAvailable`）
  - `Scopy/Views/History/HistoryItemFilePreviewView.swift:147`（`updateFileExists`）
- 问题：
  - 修复前：`HistoryItemFilePreviewView` 在 `body` 的多个分支中同步调用 `FileManager.default.fileExists`；网络盘/外置盘/失联挂载点可能阻塞主线程。
  - 修复后：存在性检查移到 `.task(id: filePath)` 的后台任务，结果缓存到 `@State`，渲染路径不再触发同步 IO。
- 影响：
  - hover 出现文件预览 popover 时卡顿，甚至影响列表滚动/热键响应。
- 验证方式：
  - 手动：复制一个位于网络卷/外置盘/失联挂载点的文件路径，hover 触发文件预览，确认 UI 不会被 `fileExists` 卡住（预览可降级为 icon/thumbnail）。

---

## S2：中风险 / 可维护性与一致性

### S2-1 0-byte 文件被显示为“未知大小”
- 状态：✅ 已修复（2025-12-28）
- 位置：`Scopy/Presentation/ClipboardItemDisplayText.swift:317`
- 问题：
  - 修复前：`computeFileMetadata` 用 `fileSizeBytes > 0` 判断“已知大小”，导致合法的 0-byte 文件被误判为“未知大小”。
  - 修复后：只要 `fileSizeBytes != nil` 就显示（包含 `0 B`）。
- 影响：
  - UI 信息不准确（尤其空文件/占位文件）。
- 建议：
  - 只要 `fileSizeBytes != nil` 就显示大小（即使是 0），或显示 `0 B`（建议 `formatBytes` 支持 B/KB/MB）。
- 验证方式：
  - 手动：复制一个 0-byte 文件到 Scopy，metadata 显示应为 0（而不是“未知大小”）。

### S2-2 “文件条目语义”需要明确：路径快照 vs 磁盘实时内容
- 状态：✅ 已明确（读盘 + 定期刷新，2025-12-28）
- 位置（相关链路）：
  - 去重 hash：`Scopy/Services/ClipboardMonitor.swift:647`（file 以路径文本 hash）
  - Markdown 文件预览读盘：`Scopy/Views/History/HistoryItemView.swift:129`（3h TTL）
  - 文件缩略图/缓存命名基于 `contentHash`：`Scopy/Services/StorageService.swift:1084`
- 说明：
  - 当前实现混合了“路径去重”（内容 hash 不随文件变化）与“实时预览读盘”（内容随磁盘变化）。
  - 这不是必然错误，但会影响缓存策略、缩略图更新策略、以及用户预期。
- 建议：
  - 已选择“读盘语义”，并采用“每 3 小时最多刷新一次”的折中（避免 hover 频繁读盘造成抖动）。

### S2-3 迁移策略：FTS rebuild 稳健但可能带来“升级首次启动耗时”
- 位置：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:15`、`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:135`
- 说明：
  - `userVersion < 3` 时会 `DROP TABLE clipboard_fts` 并触发 rebuild，这是正确但可能耗时的方案。
- 建议：
  - 在 release note 或升级提示中说明“首次启动可能需要重建索引”；必要时可考虑显示 loading/进度（如果产品需要）。

### S2-4 UI 回归风险：文件缩略图缺失时显示空白而非图标
- 状态：✅ 已修复（2025-12-28）
- 位置：
  - `Scopy/Views/History/HistoryItemView.swift:284`（`canShowFileThumbnail` 为真时直接走 `HistoryItemFileThumbnailView`）
  - `Scopy/Views/History/HistoryItemFileThumbnailView.swift:51`（无缩略图时回退图标）
- 问题：
  - 修复前：当文件支持缩略图但 `thumbnailPath == nil`（首次生成/生成失败）时，左侧会出现空白占位，缺少文件图标回退。
  - 修复后：placeholder 回退到文件类型图标，避免视觉空洞。
- 影响：
  - 视觉回归：历史列表出现“空白方块”，用户无法区分文件类型。
- 建议：
  - `canShowFileThumbnail` 增加 `thumbnailPath != nil` 限制；或在 `HistoryItemFileThumbnailView` 内部加入图标回退。

### S2-5 预览健壮性：读取失败被误判为“空文件预览”
- 状态：✅ 已修复（2025-12-28）
- 位置：`Scopy/Utilities/FilePreviewSupport.swift:100`
- 问题：
  - 修复前：`readTextFile` 读取失败时会走 `Data()` 回退，导致上层把“读取错误/不可读”误判成“空文件”，出现误导性预览（例如显示 `(Empty)`）。
  - 修复后：读取异常返回 `nil`，让上层走降级/保持旧缓存的路径，不把错误伪装成空内容。
- 影响：
  - 正确性风险：用户可能把“读取失败”误认为文件确实为空，从而做出错误判断。
- 验证方式：
  - 手动：对某个 `.md` 设置不可读权限或在 hover 时断开网络卷，确认不会出现“空文件预览”误导。

---

## S3：建议项 / 风格与小优化

### S3-1 `ClipboardMonitor.fileSizeBytesBestEffort` 与 `FilePreviewSupport.totalFileSizeBytes` 功能重复
- 状态：✅ 已修复（2025-12-28）
- 位置：`Scopy/Utilities/FilePreviewSupport.swift:79`
- 说明：
  - 修复前：两处实现都做“遍历 url -> 读 fileSizeKey -> sum”，长期可能造成行为细微不一致（例如是否跳过目录/不存在文件）。
  - 修复后：移除 `ClipboardMonitor` 中的重复实现，统一走 `FilePreviewSupport.totalFileSizeBytes`（后台计算）。
- 建议：
  - 收敛到单一实现（例如都走 `FilePreviewSupport`），并把“是否 requireExists/是否跳目录/阈值”参数化。

### S3-2 小优化：fileSizeBytes 写回链路避免重复读取
- 状态：✅ 已修复（2025-12-28）
- 位置：
  - `Scopy/Application/ClipboardService.swift:948`（`applyComputedFileSizeBytes`）
  - `Scopy/Services/StorageService.swift:368`（`updateFileSizeBytes`）
- 说明：
  - 修复前：写回路径会先 `findByID` 再 `updateFileSizeBytes`（内部再次 `fetchItemByID`），导致 1 次更新触发多次 SQL 往返。
  - 修复后：`updateFileSizeBytes` 内部比较旧值，未变化直接返回；调用侧移除重复读取。
- 收益：
  - 批量补齐 `fileSizeBytes` 时减少 DB 压力，降低 UI 刷新抖动概率。

---

# 修复建议的优先级（已完成）
1. ✅ **恢复测试可编译 + 可跑**（S1-4）
2. ✅ **移除主线程文件大小 IO**（S1-1）
3. ✅ **修正 Markdown 文件预览缓存语义**（S1-2）
4. ✅ **避免 `toDTO` 重复扫盘**（S1-3）
5. ✅ **修复 0-byte 显示问题**（S2-1）

# 建议的验证清单（手动 + 自动化）
- 自动化：
  - 已通过（2025-12-28）：
    - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`
- 手动回归（建议最少覆盖）：
  1. 大量文件复制（含网络盘）时 UI 是否卡顿（对应 S1-1）
  2. 修改磁盘上的 `.md` 内容后再 hover，预览是否更新且一致（对应 S1-2）
  3. 旧数据迁移后：FTS/搜索是否能搜到备注（`note`）（对应迁移链路）
  4. 历史中存在 `fileSizeBytes == nil` 的旧 file item 时，滚动/刷新是否出现重复 IO 卡顿（对应 S1-3）
  5. 网络盘/外置盘/失联挂载点路径的文件条目：hover 文件预览 popover 是否会卡住 UI（对应 S1-5）
