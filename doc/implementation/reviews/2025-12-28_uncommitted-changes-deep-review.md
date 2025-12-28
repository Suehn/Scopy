# Uncommitted Changes Deep Review (2025-12-28)

## Review Meta
- 项目：Scopy
- 范围：当前工作区未提交改动（`git diff`）
- 目标：优雅性 / 稳定性 / 性能 / 向后兼容（尽可能“零回归”）
- 最近更新：2025-12-28（重新 review）
- 构建/测试结果：
  - ⏸ 本次未复验（未运行 build/test）

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

## 未提交文件清单（便于后续继续修）
> 说明：该列表用于快速定位影响面；具体问题与修复建议见下文“发现清单”。

**Modified**
- `Scopy.xcodeproj/project.pbxproj`
- `Scopy/Application/ClipboardService.swift`
- `Scopy/Domain/Models/ClipboardItemDTO.swift`
- `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`
- `Scopy/Infrastructure/Persistence/ClipboardStoredItem.swift`
- `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`
- `Scopy/Infrastructure/Persistence/SQLiteConnection.swift`
- `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`
- `Scopy/Infrastructure/Search/SearchEngineImpl.swift`
- `Scopy/Observables/HistoryViewModel.swift`
- `Scopy/Presentation/ClipboardItemDisplayText.swift`
- `Scopy/Services/ClipboardMonitor.swift`
- `Scopy/Services/MockClipboardService.swift`
- `Scopy/Services/RealClipboardService.swift`
- `Scopy/Services/StorageService.swift`
- `Scopy/Views/History/HistoryItemTextPreviewView.swift`
- `Scopy/Views/History/HistoryItemView.swift`
- `Scopy/Views/HistoryListView.swift`
- `doc/implementation/CHANGELOG.md`
- `doc/implementation/README.md`

**Added (untracked)**
- `Scopy/Utilities/FilePreviewSupport.swift`
- `Scopy/Views/History/HistoryItemFileNoteEditorView.swift`
- `Scopy/Views/History/HistoryItemFilePreviewView.swift`
- `Scopy/Views/History/HistoryItemFileThumbnailView.swift`
- `Scopy/Views/History/QuickLookPreviewView.swift`
- `doc/implementation/releases/v0.50.fix20.md`

## 关键结论（TL;DR）
- **架构方向正确**：DB/Repository/FTS 的演进方式稳健，Search 合并 `note` 的策略符合产品预期，UI 预览的任务取消与 popover 协调也比较细致。
- **存在 4 类必须优先处理的问题**：
  1) 主线程/热路径的文件 IO（可能造成粘贴板检测卡顿、滚动卡顿）；  
  2) Markdown 文件预览缓存 key 的语义问题（可能出现“内容已变但预览仍旧”或 “text/HTML 不一致”）；  
  3) `toDTO` 重复扫盘（列表/事件触发时反复读文件大小）；  
  4) 测试 target 编译阻塞（多个 stub/mock 与 DTO 初始化未更新，无法用自动化证明“无回归”）。

---

# 发现清单

> 分级：S1（高风险/可能回归），S2（可维护性/一致性），S3（风格/可读性/优化建议）
> 每条包含：位置(file:line)、问题、影响、建议、验证方式（可执行）

## S1：高风险 / 可能回归

### S1-1 性能回归风险：文件拷贝时在主线程遍历文件并读取大小
- 位置：
  - `Scopy/Services/ClipboardMonitor.swift:329`（`fileSizeBytesBestEffort` 同步遍历 + `resourceValues(.fileSizeKey)`）
  - `Scopy/Services/ClipboardMonitor.swift:559`（`extractRawData` 主线程路径）
  - `Scopy/Services/ClipboardMonitor.swift:671`（`extractContent` 主线程路径）
- 问题：
  - `ClipboardMonitor` 是 `@MainActor`，而文件复制路径会调用 `fileSizeBytesBestEffort(fileURLs)`，对每个 URL 做 `fileExists` + 读取 `fileSizeKey`。
  - 大量文件、网络盘/外置盘、或 Finder 暂时卡住时，可能阻塞剪贴板轮询与 UI 交互（包括 hover/scroll）。
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
- 位置：
  - `Scopy/Views/History/HistoryItemView.swift:166`（Markdown 文件缓存 key：`"file|\\(cacheKeyBase)"`）
  - `Scopy/Views/History/HistoryItemView.swift:896`（`cacheKeyBase` 默认使用 `item.contentHash`；对 `.file` 这是“路径 hash”而不是“文件内容 hash”）
- 问题：
  - Markdown 文件预览会读取磁盘内容并赋值 `previewModel.text = preview`，但 HTML/metrics 复用缓存时只看 key，不校验“缓存是否与当前文件内容一致”。
  - 对同一路径的文件：当磁盘内容变化时，仍可能使用旧 HTML/metrics，出现预览内容陈旧或 `text` 与 `markdownHTML` 不一致（尤其当缓存命中）。
- 影响：
  - 用户感知为：hover 一个 Markdown 文件，预览显示旧内容；或先 hover 看到旧内容，稍后再 hover 仍旧旧内容。
- 建议：
  1. **明确语义（必须先定）**：文件预览到底是“复制时快照”还是“实时读盘内容”？
     - 若是“实时读盘”：缓存 key 需要包含文件版本（例如 `mtime + size`），或直接以读取到的内容 hash 作为 key。
     - 若是“快照”：则不应每次读盘；应该在入库时把快照文本持久化（或持久化渲染产物/缩略图），并用 DB 内容作为渲染源。
  2. **最小改动建议（偏实时语义）**：
     - 生成 `cacheKey = "file|\\(url.path)|\\(mtime)|\\(size)"`（或 `mtime`），避免内容变更后误命中旧缓存。
     - 或在命中缓存前，校验缓存对应的 `previewModel.text`/hash 一致，否则丢弃缓存并重算。
- 验证方式：
  - 手动：复制一个 `.md` 文件到 Scopy → hover 出预览 → 修改磁盘内容（保存）→ 再 hover，确认预览随之变化且不会“卡在旧 HTML”。

### S1-3 性能隐患：`toDTO` 在 `fileSizeBytes == nil` 时同步扫描磁盘，且可能重复发生
- 位置：`Scopy/Application/ClipboardService.swift:853`
- 问题：
  - `toDTO` 在文件条目 `fileSizeBytes == nil` 时会调用 `FilePreviewSupport.totalFileSizeBytes(from:)`，同步遍历路径并读取 `fileSizeKey`。
  - `toDTO` 会在 `fetchRecent/search`、事件处理（如 `.itemUpdated`/`.itemContentUpdated`）等多处被调用；若 DB 中 `file_size_bytes` 为 NULL（旧数据/迁移前数据），则可能多次重复 IO。
- 影响：
  - 列表刷新、搜索、滚动过程中出现重复磁盘扫描，导致吞吐下降与延迟抖动。
- 建议：
  1. **避免在 `toDTO` 做磁盘扫描**：改为后台懒加载（一次计算 + 写回 DB），UI 初次显示可先展示“未知大小”。
  2. **只对可见/选中项计算**：比如 hover/选中时才触发计算，避免加载一页就扫盘。
  3. **对多文件条目做上限**：文件数过多时直接降级不计算，避免 O(n) 扫盘扩大。
- 验证方式：
  - 手动：历史中存在大量旧 file item（`fileSizeBytes == nil`）时，打开/滚动/搜索的 CPU 与磁盘访问是否明显上升。

### S1-4 回归证明缺口：测试 target 编译失败，当前无法用单测证明“无回归”
- 位置：
  - `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift:33`（新增 `updateNote`，无默认实现）
  - `Scopy/Domain/Models/ClipboardItemDTO.swift:22`（initializer 新增必填参数 `note`/`fileSizeBytes`）
  - Stub 未实现 `updateNote`：
    - `ScopyTests/ScrollPerformanceTests.swift:8`
    - `ScopyTests/SearchStateMachineTests.swift:7`
    - `ScopyTests/AppStateTests.swift:653`
    - `ScopyTests/Helpers/MockServices.swift:10`
  - DTO 构造未补参（示例）：
    - `ScopyTests/Helpers/TestDataFactory.swift:74`
    - `ScopyTests/Helpers/MockServices.swift:55`
- 问题：
  - 协议/DTO 签名变化导致多个测试 stub/mock 不 conform 或构造失败，从而 `xcodebuild test` 在编译阶段终止。
- 影响：
  - 这会掩盖真实回归（尤其 UI/服务联动改动较多时），降低交付置信度。
- 建议：
  1. **`ClipboardServiceProtocol.updateNote` 提供默认实现**（类似已有 `stopAndWait`），让旧 stub 不必立刻实现；或批量补齐所有测试 stub 的空实现。
  2. **为 `ClipboardItemDTO` 的新增参数提供默认值 `= nil`**，保持向后兼容（测试/调用点无需“全仓库补参”）。
- 验证方式：
  - 目标：`xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests` 恢复可运行，并尽量全绿。

---

## S2：中风险 / 可维护性与一致性

### S2-1 0-byte 文件被显示为“未知大小”
- 位置：`Scopy/Presentation/ClipboardItemDisplayText.swift:331`
- 问题：
  - `computeFileMetadata` 用 `fileSizeBytes > 0` 判断“已知大小”，导致合法的 0-byte 文件被误判为“未知大小”。
- 影响：
  - UI 信息不准确（尤其空文件/占位文件）。
- 建议：
  - 只要 `fileSizeBytes != nil` 就显示大小（即使是 0），或显示 `0 B`（建议 `formatBytes` 支持 B/KB/MB）。
- 验证方式：
  - 手动：复制一个 0-byte 文件到 Scopy，metadata 显示应为 0（而不是“未知大小”）。

### S2-2 “文件条目语义”需要明确：路径快照 vs 磁盘实时内容
- 位置（相关链路）：
  - 去重 hash：`Scopy/Services/ClipboardMonitor.swift:647`（file 以路径文本 hash）
  - Markdown 文件预览读盘：`Scopy/Views/History/HistoryItemView.swift:137`
  - 文件缩略图/缓存命名基于 `contentHash`：`Scopy/Services/StorageService.swift:1084`
- 说明：
  - 当前实现混合了“路径去重”（内容 hash 不随文件变化）与“实时预览读盘”（内容随磁盘变化）。
  - 这不是必然错误，但会影响缓存策略、缩略图更新策略、以及用户预期。
- 建议：
  - 在规格/实现文档中明确语义，并据此调整：
    - 实时语义：缓存 key 必须包含文件版本；缩略图也应支持刷新（或明确“缩略图是历史快照”）。
    - 快照语义：需要在写入时持久化预览所需数据，而不是每次读盘。

### S2-3 迁移策略：FTS rebuild 稳健但可能带来“升级首次启动耗时”
- 位置：`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:15`、`Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:135`
- 说明：
  - `userVersion < 3` 时会 `DROP TABLE clipboard_fts` 并触发 rebuild，这是正确但可能耗时的方案。
- 建议：
  - 在 release note 或升级提示中说明“首次启动可能需要重建索引”；必要时可考虑显示 loading/进度（如果产品需要）。

### S2-4 UI 回归风险：文件缩略图缺失时显示空白而非图标
- 位置：
  - `Scopy/Views/History/HistoryItemView.swift:284`（`canShowFileThumbnail` 为真时直接走 `HistoryItemFileThumbnailView`）
  - `Scopy/Views/History/HistoryItemFileThumbnailView.swift:15`（无缩略图时展示 `Color.clear`）
- 问题：
  - 当文件支持缩略图但 `thumbnailPath == nil`（首次生成/生成失败）时，左侧会出现空白占位，缺少文件图标回退。
- 影响：
  - 视觉回归：历史列表出现“空白方块”，用户无法区分文件类型。
- 建议：
  - `canShowFileThumbnail` 增加 `thumbnailPath != nil` 限制；或在 `HistoryItemFileThumbnailView` 内部加入图标回退。

---

## S3：建议项 / 风格与小优化

### S3-1 `ClipboardMonitor.fileSizeBytesBestEffort` 与 `FilePreviewSupport.totalFileSizeBytes` 功能重复
- 位置：`Scopy/Services/ClipboardMonitor.swift:329`、`Scopy/Utilities/FilePreviewSupport.swift:86`
- 说明：
  - 两处实现都做“遍历 url -> 读 fileSizeKey -> sum”，长期可能造成行为细微不一致（例如是否跳过目录/不存在文件）。
- 建议：
  - 收敛到单一实现（例如都走 `FilePreviewSupport`），并把“是否 requireExists/是否跳目录/阈值”参数化。

---

# 修复建议的优先级（推荐）
1. **恢复测试可编译 + 可跑**（S1-4）：先把“回归证明能力”拿回来。
2. **移除主线程文件大小 IO**（S1-1）：避免最明显的性能回归。
3. **修正 Markdown 文件预览缓存语义**（S1-2）：避免预览内容陈旧/错乱。
4. **避免 `toDTO` 重复扫盘**（S1-3）：降低列表刷新与事件触发抖动。
5. **修复 0-byte 显示问题**（S2-1）：小但能提升一致性。

# 建议的验证清单（手动 + 自动化）
- 自动化：
  - 先修复 stub/mock 与 DTO 构造缺参后，再运行：
    - `xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests`
- 手动回归（建议最少覆盖）：
  1. 大量文件复制（含网络盘）时 UI 是否卡顿（对应 S1-1）
  2. 修改磁盘上的 `.md` 内容后再 hover，预览是否更新且一致（对应 S1-2）
  3. 旧数据迁移后：FTS/搜索是否能搜到备注（`note`）（对应迁移链路）
  4. 历史中存在 `fileSizeBytes == nil` 的旧 file item 时，滚动/刷新是否出现重复 IO 卡顿（对应 S1-3）
