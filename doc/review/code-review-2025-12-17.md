# Scopy 深度代码 Review

**Review 日期**: 2025-12-17  
**基于版本**: v0.44.fix20（见 `doc/implemented-doc/README.md`，最后更新 2025-12-16）  
**基于提交**: 7418acc  
**Review 范围**: 稳定性 / 性能（前后端）/ 规格实现准确性（对照 `doc/dev-doc/v0.md`）/ 代码优雅性与可维护性  

> 说明：本文是**静态代码 review**（不包含运行时 profile 与真实数据集压测）。个别结论涉及系统行为（RunLoop/Timer、CryptoKit 可用性等）时，已附外部参考链接；仍建议按“验证方式”做一次本地复现/压测以最终确认。

---

## Review 计划与方法

### Review 计划（本次执行）

1. 阅读：`doc/implemented-doc/README.md` / `doc/implemented-doc/CHANGELOG.md` / `doc/dev-doc/v0.md`，明确当前版本与验收口径。
2. 盘点：按模块列出 Swift 源码文件（ScopyKit 后端 / SwiftUI 前端 / ScopyUISupport / Tests）。
3. 聚焦关键路径：clipboard ingest → dedup/hash → storage → search → UI（hotkey/panel/settings/hover preview）。
4. 逐文件检查：并发边界、I/O/大数据路径、错误处理与回滚、缓存与分页语义、与 v0.md 的一致性。
5. 汇总：按优先级输出发现项，并为每项给出验证方式与修复建议（尽量最小改动）。

### 备注

- 本文不包含运行时 profile；性能结论主要来自“代码路径复杂度 + 明显的拷贝/扫描热点 + 现有测试/日志”。
- “逐模块/逐文件”结论见文末的文件清单（并用 ID 关联到上方详细分析）。

---

## 结论摘要

- **存在少量“可导致用户数据缺失/功能不符合直觉”的问题**：例如剪贴板轮询计时器在某些 RunLoop 模式下可能暂停，导致“中间多次复制”被合并为最后一次；exact 短词（≤2）（以及 regex 模式）当前只查 recent cache，可能“永远搜不到更早的匹配”；`ClipboardService.start()` 的失败路径存在“半初始化”风险点。
- **存在若干后端性能与长期稳定性风险**：自实现 SHA256 在大数据上存在明显的拷贝/搬移开销且缺少测试向量；全量 fuzzy 索引对长文本会显著放大内存，并且删除后 postings 不清理导致长期运行的性能漂移；Markdown hover-preview 的可复用 WKWebView controller 存在潜在 retain-cycle 泄漏风险；存储清理在极端情况下会创建大量并发删除任务/blocks（调度与 I/O 抖动风险），另一路径 Clear All 也可能在主线程同步删大量外部文件导致卡 UI；以及“存储统计”在首屏加载中存在重复/昂贵计算导致的额外 I/O 与加载延迟。
- **存在与 v0.md 的若干偏离点**：FTS 结果排序未纳入匹配度；大文本未外部化（当前实现选择“全文入库 + FTS”）。
- **代码整体结构清晰**（服务分层、actor/后台队列隔离、FTS statement cache 等），问题集中在少数关键路径与边界语义。

---

## 发现项总览（按优先级）

| ID | 优先级 | 类型 | 一句话摘要 | 关键定位 |
|---|---|---|---|---|
| P1-1 | P1 | 稳定性 / 数据完整性 | `Timer` 默认 mode 可能暂停轮询，导致“漏记录中间复制” | `Scopy/Services/ClipboardMonitor.swift:207` |
| P1-2 | P1 | 实现准确性 / UX | exact 短词（≤2）只查 recent cache，可能隐藏更早匹配且无法 refine | `Scopy/Infrastructure/Search/SearchEngineImpl.swift:320-335`，`Scopy/Observables/HistoryViewModel.swift:340-500` |
| P2-1 | P2 | 后端性能 / 正确性保障 | 自实现 SHA256 对大 payload 有明显拷贝/搬移开销且缺少测试向量 | `Scopy/Services/ClipboardMonitor.swift:924-1021` |
| P2-2 | P2 | 后端性能 / 长期稳定 | 全量 fuzzy 索引：`plainTextLower` 内存放大 + tombstone/postings 漂移 | `Scopy/Infrastructure/Search/SearchEngineImpl.swift:34-62`，`:239-248`，`:501-528` |
| P2-3 | P2 | 规格偏离 | FTS 排序未纳入匹配度（bm25/rank），与 v0.md “匹配度+最近使用”不一致 | `Scopy/Infrastructure/Search/SearchEngineImpl.swift:1165-1216`，`doc/dev-doc/v0.md:158-163` |
| P2-4 | P2 | 规格偏离 / 存储策略 | 大文本未外部化：`.text` payload 为 `.none`，全文仍入库/FTS | `Scopy/Services/ClipboardMonitor.swift:584-593`，`Scopy/Services/StorageService.swift:244-271`，`doc/dev-doc/v0.md:50-53` |
| P2-5 | P2 | 稳定性 / 生命周期 | `ClipboardService.start()` 抛错时可能留下半初始化状态，需要 stop 才能恢复 | `Scopy/Application/ClipboardService.swift:58-120` |
| P2-6 | P2 | 稳定性 / 性能（长期） | Markdown hover-preview 复用 WebView：`WKScriptMessageHandler` 形成 retain cycle，controller 可能无法释放 | `Scopy/Views/History/MarkdownPreviewWebView.swift:275-302` |
| P2-7 | P2 | 性能 / 稳定性（极端） | 清理大量文件时会创建海量并发删除任务/blocks（无并发上限） | `Scopy/Services/StorageService.swift:557-589`，`:707-737` |
| P2-8 | P2 | 前后端性能 / I/O | `getStorageStats()` 与 `getDetailedStorageStats()` 重复做全量遍历，首屏/刷新可能触发两次重扫描 | `Scopy/Application/ClipboardService.swift:353-378`，`Scopy/Observables/HistoryViewModel.swift:282-307`，`Scopy/Observables/SettingsViewModel.swift:70-90` |
| P2-9 | P2 | 稳定性 / UX（竞态） | 清空搜索/筛选时未版本化/未取消 in-flight paging，旧任务可能污染新列表；部分 UI 还会重复触发 `search()` | `Scopy/Observables/HistoryViewModel.swift:414-429`，`Scopy/Views/HeaderView.swift:21-45`，`Scopy/Views/ContentView.swift:74-81` |
| P2-10 | P2 | 性能 / UX（极端） | Clear All 会在主线程同步删除大量外部文件，极端情况下可能卡 UI | `Scopy/Services/StorageService.swift:353-370`，`Scopy/Application/ClipboardService.swift:220-226` |
| P3-1 | P3 | 语义/文案 | “内联存储上限”实际按 `SUM(size_bytes)`，与“数据库文件大小”可能偏离 | `Scopy/Views/Settings/StorageSettingsPage.swift:36-49`，`Scopy/Services/StorageService.swift:517-522`，`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:280-285` |
| P3-2 | P3 | 代码优雅性 | `getOriginalImageData` 实际是“取 raw payload”，被用于 file/rtf/html，命名误导 | `Scopy/Services/StorageService.swift:960-982`，`Scopy/Application/ClipboardService.swift:236-298` |
| P3-3 | P3 | 微优化 | HotKey 事件处理在锁内做日志/构造数组，临界区偏大 | `Scopy/Services/HotKeyService.swift:311-326` |
| P3-4 | P3 | 测试稳定性 | 部分 UI 测试依赖固定 sleep 等待 debounce/动画，可能 flaky | `ScopyUITests/*` |
| P3-5 | P3 | 微优化 / 前端性能 | hover Markdown 渲染任务取消不够“及时”（CPU 浪费风险，低优先级） | `Scopy/Views/History/HistoryItemView.swift:522-568` |
| P3-6 | P3 | 稳健性 / 升级兼容 | 外部 content 的 FTS5 初次创建不会自动回填索引；若迁移未 rebuild，旧数据可能“MATCH 搜不到” | `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:1-86` |
| P3-7 | P3 | 稳健性 / UX | HotKey 录制后用固定 sleep 读取持久化设置，极端调度下可能误判“快捷键不可用”并回滚 UI | `Scopy/Views/Settings/HotKeyRecorderView.swift:63-93` |

---

## P1-1：ClipboardMonitor 轮询 Timer 可能暂停，导致“漏记录中间多次复制”

**定位**

- `Scopy/Services/ClipboardMonitor.swift:207`：`Timer.scheduledTimer(withTimeInterval:repeats:block:)` 创建并自动加入当前 RunLoop。
- `Scopy/Services/ClipboardMonitor.swift:326-351`：`changeCount` 发生跳变时只读取一次当前内容，无法补回“跳变期间的中间内容”。

**现象/风险**

- `Timer.scheduledTimer` 默认会被加入到 RunLoop 的 **default mode**。当主线程 RunLoop 进入某些非 default 的 mode（典型是 UI tracking，如滚动、菜单 tracking、鼠标拖拽等）时，default-mode 的 timer 可能不会触发。
- 由于 Scopy 的剪贴板监控是通过轮询 `NSPasteboard.changeCount` 实现的，一旦 timer 暂停，`changeCount` 可能在下一次触发时出现“跳变”（>1）。当前实现只会读取最后一次内容并写入历史，中间多次复制将无法被记录。

**为什么是“稳定性问题”**

- 这属于**用户数据丢失（历史缺条）**而不是 crash，属于 P1：难复现但一旦触发会显著影响信任感（“我明明复制了，怎么没记录”）。

**根因分析**

- RunLoop 机制：Timer/Source 绑定到特定 mode，如果 RunLoop 当前处于不同 mode，该 Timer 不会被调度。  
  参考（RunLoop & Timer 与 mode 的关系）：  
  - Apple archived doc（Run Loops）https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/Multithreading/RunLoopManagement/RunLoopManagement.html  
  - Apple archived doc（Timer：`scheduledTimer...` 会 schedule 到当前 RunLoop 的 default mode）https://developer.apple.com/library/archive/documentation/Cocoa/Reference/Foundation/Classes/NSTimer_Class/  
  - 经验复现说明（scheduledTimer + default mode + UI tracking）：https://mattrajca.com/2019/10/07/timers-in-scrollviews.html

**建议修复（不改变现有架构）**

1. **把轮询 Timer 加入 `.common` modes**（优先建议，改动最小）  
   - 用 `Timer(timeInterval:repeats:block:)` 创建未调度 timer，然后 `RunLoop.main.add(timer, forMode: .common)`。  
   - 或在 `scheduledTimer` 之后额外 `RunLoop.main.add(timer, forMode: .common)`（注意避免重复 add 的副作用，最好改用未调度版本）。
2. 或 **改用 `DispatchSourceTimer`**（不依赖 RunLoop mode，行为更稳定）  
   - 在 main queue 或专用 queue 上 tick，再 `Task { @MainActor in await checkClipboard() }`。

**验证方式**

- 复现思路：打开 Scopy 主窗口，持续滚动列表 / 打开状态栏菜单时，快速连续复制多次不同文本（例如 1 秒内 5 次）。观察历史是否完整出现 5 条，或只出现最后 1 条。
- 辅助验证：在 `checkClipboard()` 内增加临时 debug log（或用现有日志）记录 `currentChangeCount - lastChangeCount` 是否出现 >1。

---

## P1-2：exact 短词（≤2）只查 recent cache，可能隐藏更早匹配且无法 refine

**定位**

- `Scopy/Infrastructure/Search/SearchEngineImpl.swift:325-329`：`searchExact` 对 `query.count <= 2` 直接走 `searchInCache`（`shortQueryCacheSize = 2000`）。
- `Scopy/Infrastructure/Search/SearchEngineImpl.swift:382-419`：`searchInCache` 只在 `recentItemsCache` 上过滤与排序。
- `Scopy/Observables/HistoryViewModel.swift:458-499`：仅 fuzzy/fuzzyPlus 对 `total == -1` 触发 refine；exact 不会触发。
- `Scopy/Observables/HistoryViewModel.swift:352-375`：loadMore 的“prefilter → 强制 full fuzzy”只对 fuzzy/fuzzyPlus 生效；exact 不生效。

**现象/风险**

- 在 exact 模式下，输入 1–2 个字符时，搜索**只覆盖最近 2000 条**，更早的匹配会被“永远隐藏”。  
  例如：第 5000 条里包含 “OK”，但最近 2000 条不包含；用户搜索 “ok” 会得到“无结果”，且不会自动 refine。
- 更糟的是：当用户尝试翻页（load more）时，后续请求仍走 `searchInCache`，等价于“只能在 recent cache 里分页”，用户无法到达更早历史的匹配。
- 备注：**regex 模式目前也只在 recent cache 上做匹配**（`SearchEngineImpl.searchRegex` → `searchInCache`），且没有 fuzzy 那样的 prefilter/refine 机制。v0.md 允许 regex “限制子集以避免 O(n)”，但如果 UI 暴露 “Regex” 模式给用户，建议明确说明“只搜最近 N 条”或提供可控的全量策略（需评估性能）。

**这和 v0.md 的关系**

- `doc/dev-doc/v0.md` 4.2 “短词/长词优化”写的是“短词可以先在内存缓存最近 N 条快速过滤”，语义上更像**prefilter**而不是“只搜最近 N 条作为最终结果”。当前 fuzzy 已按 prefilter 思路实现（短词先 cache，随后 refine full fuzzy），但 exact 没有同样机制。

**建议修复（先明确产品语义）**

先在产品层明确：**exact 短词**到底是“仅最近 N 条”（一种产品选择）还是“先最近 N 条、随后全量补齐”（prefilter）。

1. 如果希望“短词也应可搜全量历史”（更符合用户直觉）  
   - 方案 A（对齐 fuzzy）：exact 短词首次返回视作 prefilter，`total = -1`，并在 `HistoryViewModel` 侧增加 refine（类似 fuzzy）去做 full FTS/全量扫描。  
   - 方案 B：为 exact 增加 `forceFullExact`（或通用 `forceFullSearch`）参数；首次 cache，翻页/停顿后触发 full。
2. 如果产品选择就是“短词只搜最近 N 条”（性能优先）  
   - UI 明确告知：例如在搜索框下提示“短词仅搜索最近 2000 条，输入 ≥3 字符可全量搜索”，避免“误以为历史不存在”。

**验证方式**

- 构造数据：插入 >2000 条，其中第 2500 条包含关键词 “ab”，最近 2000 条不包含；exact 搜索 “ab” 应能在明确语义下得到可解释结果：  
  - 若支持全量：最终应能出现第 2500 条；  
  - 若仅 recent：UI 应提示并且行为一致。

---

## P2-1：自实现 SHA256 对大 payload 有明显拷贝/搬移开销，且缺少测试向量

**定位**

- `Scopy/Services/ClipboardMonitor.swift:922-1021`：`private struct SHA256`（注释写 “avoid CryptoKit import issues”）。
- `Scopy/Services/ClipboardMonitor.swift:944-952`：`update(data:)` 每 64B：
  - `Array(buffer.prefix(64))` 复制一份 chunk
  - `buffer.removeFirst(64)` 触发数组搬移（潜在 O(n)）

**现象/风险**

1. **性能风险（可预期）**  
   - 对大数据（大图、长 HTML/RTF、外部 payload）做哈希时，`removeFirst` 的持续搬移会带来明显的 CPU 与内存带宽消耗，理论复杂度接近 O(n²)（取决于 buffer 规模与 Swift Array 实现细节，但至少是高拷贝路径）。
   - 这会直接影响 ingest 吞吐，表现为：大内容复制时 CPU 飙高、后台 ingest backlog 增大、历史入库延迟变大。
2. **正确性保障不足**  
   - 自实现 cryptographic hash 若无测试向量，很容易在边界（padding、长度计数、分块）上出现 subtle bug；一旦 hash 错误，会直接影响去重一致性与索引稳定性（重复入库/误去重）。

**建议修复**

- 优先建议：**用系统实现替代**（本项目 `project.yml` 显示部署目标 macOS 14.0，使用 CryptoKit 没有平台障碍）  
  - 直接 `import CryptoKit`，用 `SHA256.hash(data:)` 或增量 `SHA256()` + `update`。  
  - API 参考（Swift Crypto 文档，接口与 CryptoKit 高度一致）：https://apple.github.io/swift-crypto/docs/current/Crypto/documentation/crypto/sha256/
- 如果必须保留自实现：  
  1) 把 `buffer` 改为“环形/偏移指针”的设计，避免 `removeFirst`；  
  2) 使用 `Data.withUnsafeBytes` 直接分块处理，避免频繁 `Array(prefix:)`；  
  3) 增加单元测试（至少 NIST/RFC 的经典向量，比如 `"abc"`、空串、长消息）。

**验证方式**

- 单测：加入 SHA256 测试向量（空串、"abc"、多 block 输入），并与 CryptoKit/SwiftCrypto 输出比对。
- 性能：对 1MB/10MB/50MB payload 做 hash 基准，对比“现实现 vs CryptoKit”耗时与峰值内存。

---

## P2-2：全量 fuzzy 索引存在内存放大与 tombstone/postings 漂移（长期运行性能退化）

**定位**

- 内存放大：
  - `Scopy/Infrastructure/Search/SearchEngineImpl.swift:34-62`：`IndexedItem` 将每条 `plainText` 额外存一份 `plainTextLower = lowercased()`。
  - `Scopy/Infrastructure/Search/SearchEngineImpl.swift:1042-1058`：`fetchAllSummaries()` 全量拉取 `plain_text` 构建索引。
- tombstone 漂移：
  - `Scopy/Infrastructure/Search/SearchEngineImpl.swift:239-248`：`handleDeletion` 只做 `items[slot] = nil`，未清理 `charPostings`。
  - `Scopy/Infrastructure/Search/SearchEngineImpl.swift:501-528`：构建 `charPostings[ch].append(slot)`，list 会持续累积历史 slot。

**现象/风险**

1. **内存放大**  
   - 对长文本条目，`lowercased()` 会产生接近同等大小的新字符串；全量索引时会把数据库里的 `plain_text` 全部加载到内存，再复制一份 lowercased，内存占用会显著上升。  
   - 对“逻辑无限历史/10k–100k items”的目标来说，如果存在大量长文本，full index build 可能触发超时或压力（尤其在用户首次使用 fuzzy、或缓存失效重建时）。
2. **长期运行性能漂移**  
   - 删除条目时 postings 不清理，候选集合的 postings 交集会持续包含已删除 slot（tombstones），导致候选扫描量逐渐变大，搜索成本随时间漂移。  
   - 目前没有“tombstone 比例阈值 → 重建 fullIndex”的机制（`fullIndexStale` 仅在 `invalidateCache()` 时设 true）。

**建议修复（按成本从低到高）**

1. **引入“索引健康度阈值”并触发重建**（低成本、收益明确）  
   - 记录 `tombstoneCount` 或“aliveCount vs items.count”，当 tombstone 比例超过阈值（例如 20–30%）时，将 `fullIndexStale = true`，下一次 fuzzy 走重建。
2. **限制进入 full index 的文本规模**（更像“工程化兜底”）  
   - 对 `plainText` 超过一定长度的条目：只索引前 N 字符用于 fuzzy（或直接跳过 full fuzzy，改走 FTS），避免极端长文本拖垮内存。
3. **删除时增量维护 postings（较高成本）**  
   - 真正从 `charPostings` 各列表移除该 slot 代价很高（需要在每个 char 列表里删除），通常不建议逐次做；更现实的方式是“标记 tombstone + 周期性 compact”。

**验证方式**

- 构造“插入/删除交替”的长时间运行场景（例如插入 50k、删除 30k、再插入 30k），观察 fuzzy 搜索延迟与内存是否随时间漂移。
- 加入一条极长文本（例如 1MB），观察首次 fuzzy 时 full index build 的内存/耗时。

---

## P2-3：FTS 结果排序未纳入匹配度（与 v0.md 排序描述不一致）

**定位**

- `Scopy/Infrastructure/Search/SearchEngineImpl.swift:1165-1216`：FTS 查询 `ORDER BY is_pinned DESC, last_used_at DESC`。
- `doc/dev-doc/v0.md` 4.3（约 158–163 行附近）写的是：默认“匹配度 + 最近使用时间组合排序”。

**现象/风险**

- 用户输入较长 query 时（走 FTS），结果更像“按最近使用时间排序的匹配集”，而不是“更相关的排在前面”。  
  常见感受：我搜 “foobar baz”，更相关但较旧的条目可能被较新的弱匹配顶下去。

**建议修复（需要权衡性能与体验）**

- 引入 FTS rank（FTS5 的 `bm25()` 或自定义 rank），并与 `last_used_at` 做组合排序：  
  - 示例（思路）：`ORDER BY is_pinned DESC, bm25(clipboard_fts) ASC, last_used_at DESC`  
  - 或将 `last_used_at` 折算为一个轻权重加到 rank 上，形成单一 score（便于稳定分页）。
- 注意：rank 排序可能带来额外 CPU 成本，需要结合现有性能目标做基准测试。

**验证方式**

- 加入“同一 query 的强/弱匹配”用例，验证更相关者在前；同时跑 5k/10k/50k 的搜索性能基准，确保 p95 不回归。

---

## P2-4：大文本未外部化（当前实现选择“全文入库 + FTS”，与 v0.md 分级存储描述不一致）

**定位**

- `doc/dev-doc/v0.md` 2.1：分级存储写到“图片 / 大文本 / 文件 ≥ X KB 外部文件 + DB 存 path/元数据”。
- 现实现：
  - `Scopy/Services/ClipboardMonitor.swift:584-593`：`.text` rawData 为 `nil`，payload 为 `.none`（纯文本没有 payload）。
  - `Scopy/Services/StorageService.swift:244-271`：外部化决策只基于 `content.payload`，`.none` 永远不会走外部存储；但 `plainText` 总会被写入 DB，并由 FTS 索引。

**现象/风险**

- 当前行为实际上是：**文本始终完整进入 SQLite（并被 FTS 索引）**，不存在“大文本外部化”。  
- 风险在于：当用户复制大量长文本（代码、日志、PDF 抽取文本等），DB/FTS 体积可能快速膨胀，进而影响：
  - DB 文件增长（磁盘）
  - 全量 fuzzy 索引构建（内存/耗时）
  - vacuum/cleanup 成本（I/O）

**重要说明（规格需要澄清）**

- 如果你希望“对长文本也能全文搜索”，那么 **FTS 必然需要索引这些文本**；仅把文本放到外部文件而不在 DB/FTS 中保留可索引内容，会导致全文搜索不可用。  
  v0.md 里 `plainText` 的定义包含“可索引的文本内容/摘要”，这意味着对大文本可以选择只存“摘要/截断”，把全文外部化；但这会改变搜索语义（只能搜摘要）。

**建议下一步（先决策再改实现）**

1. 明确产品/规格：大文本是否需要“全文可搜索”？  
2. 若只需摘要可搜索：  
   - `plainText` 存摘要（前 N KB/前 N 字符）  
   - 全文写外部文件（storageRef），展示/复制时按需加载
3. 若必须全文可搜索：  
   - 接受“全文入库 + FTS”作为现实实现，并把 v0.md 的“大文本外部化”条款调整为“可选/仅在不要求全文搜索时启用”；或探索 contentless FTS5（只存索引不存原文）等更复杂方案（实现成本高）。

**验证方式**

- 构造 1MB 文本复制 100 次的压力场景，观察 DB/FTS 增长、search p95、vacuum 时间、内存峰值。

---

## P2-5：`ClipboardService.start()` 抛错时可能留下半初始化状态（需要 stop 才能恢复）

**定位**

- `Scopy/Application/ClipboardService.swift:58-120`：`start()` 在可能抛错的操作（`storage.open()` / `search.open()`）之前先设置 `isStarted = true`，并在 open 成功前就把 `monitor/storage/search` 赋给成员变量。

**现象/风险**

- 如果 DB 打开/迁移失败（路径权限、磁盘只读、SQLite error 等），`start()` 会抛错，但 actor 内部可能已经：
  - `isStarted == true`（后续再调用 `start()` 会被 `guard !isStarted` 直接短路）；
  - 持有部分初始化过的 `monitor/storage/search` 对象（生命周期与资源清理不够“原子”）。
- 当前 `AppState.start()` 在捕获启动失败后会调用 `service.stopAndWait()`，因此主路径上该问题被部分掩盖；但从代码稳健性角度仍属于可修复的“半初始化”风险点。

**建议修复（最小改动）**

- 采用“局部变量 + 成功后一次性提交”的方式：
  1. 在 `start()` 内用 local `monitor/storage/search` 完成创建与 open；
  2. 所有 open 成功后再 `self.monitor = ...` / `self.storage = ...` / `self.search = ...` 并设置 `isStarted = true`；
  3. 失败时在 `catch` 中 best-effort close（或用 `defer` 统一清理）。

**验证方式**

- 通过传入一个必然失败的 DB 路径（只读目录/非法 URI）触发 `start()` 抛错，验证：
  - 再次调用 `start()` 仍然会尝试启动而不是直接 return；
  - 不需要额外 `stop()` 才能恢复到可重试状态。

---

## P2-6：Markdown hover-preview 复用 WebView：`WKScriptMessageHandler` 可能形成 retain cycle，导致 controller 不释放

**定位**

- `Scopy/Views/History/MarkdownPreviewWebView.swift:275-302`：`MarkdownPreviewWebViewController` 持有 `webView: WKWebView`（强引用）。
- `Scopy/Views/History/MarkdownPreviewWebView.swift:298`：`config.userContentController.add(self, name: "scopySize")` 把 controller 自身注册为 `WKScriptMessageHandler`。
- 文件内未见对 `"scopySize"` 的 `removeScriptMessageHandler(forName:)`；`MarkdownPreviewWebViewController` 也没有 `deinit/cleanup()` 主动解除绑定。

**现象/风险**

- WebKit 的 `WKUserContentController` 实现会强引用其注册的 `WKScriptMessageHandler`（见下方 WebKit open source）。在当前实现下，很容易形成典型 retain cycle：
  - `MarkdownPreviewWebViewController` → `WKWebView` → `WKWebViewConfiguration` → `WKUserContentController` → `MarkdownPreviewWebViewController`
- 结果是：一旦某个 `HistoryItemView` 触发创建 `MarkdownPreviewWebViewController`（例如 hover 到被判定为 Markdown 的文本），当该 row/view 生命周期结束时 controller 可能无法释放，导致：
  - **长期运行内存增长**（滚动/列表复用过程中更明显）；
  - 关联资源（WebKit 进程、scroll observer 等）无法回收，进而产生间歇性卡顿或最终 OOM 风险（取决于使用频率与内容大小）。

**外部参考（交叉验证：官方实现 + 官方 API + 社区复现）**

- WebKit Open Source：`WKUserContentController` 内部的 `ScriptMessageHandlerDelegate` 使用 `RetainPtr<id> m_handler` 保存 handler（强引用），因此“controller 持有 webView 且把 self 注册为 handler”会形成环。  
  https://raw.githubusercontent.com/WebKit/WebKit/main/Source/WebKit/UIProcess/API/Cocoa/WKUserContentController.mm
- Apple Developer Documentation：提供显式卸载 API `removeScriptMessageHandler(forName:)`（用于解除 message handler 绑定）。  
  https://developer.apple.com/documentation/webkit/wkusercontentcontroller/removescriptmessagehandler(forname:)

- StackOverflow：`WKUserContentController retains its message handlers`（典型泄漏原因与解决方式：remove 或弱代理）。  
  https://stackoverflow.com/questions/26383031/wkwebview-causes-my-view-controller-to-leak
- Bart Jacobs / Cocoacasts：同类说明与修复模式（弱代理 + remove）。  
  https://cocoacasts.com/avoiding-retain-cycles-with-wkwebview-and-wkscriptmessagehandler

**建议修复（从“根因断环”，避免仅靠 deinit）**

1. **弱代理（推荐）**：不要让 controller 直接做 handler  
   - 新建 `WeakScriptMessageHandler`（强持有 proxy，proxy `weak var delegate`），注册 proxy 而不是 `self`。  
   - 这样即使忘记 remove，也不会形成环：`userContentController -> proxy -> (weak) controller`。
2. **显式拆解（配合 weak 代理或作为兜底）**  
   - 在合适的生命周期（例如 `ReusableMarkdownPreviewWebView` 的 `dismantleNSView`、或 row `onDisappear`）主动调用：  
     - `webView.configuration.userContentController.removeScriptMessageHandler(forName: "scopySize")`  
     - 并将 `navigationDelegate/uiDelegate` 置 `nil`（减少 WebKit 侧潜在引用链）。

**验证方式**

- 最直接：给 `MarkdownPreviewWebViewController` 临时加 `deinit { ScopyLog.ui.debug("deinit ...") }`，在列表中反复 hover/滚动触发创建后，观察 controller 是否能随着 row 销毁而 deinit。
- Instruments：`Leaks` / `Allocations` 观察 `MarkdownPreviewWebViewController` 与 `WKUserContentController` 的实例数量是否单调上升。

---

## P2-7：清理大量文件时会创建海量并发删除任务/blocks（无并发上限）

**定位**

- `Scopy/Services/StorageService.swift:557-589`：`cleanupOrphanedFiles()` 对每个 orphan file `group.addTask { removeItem(...) }`。
- `Scopy/Services/StorageService.swift:707-737`：`deleteFilesInParallel(_:)` 为每个路径 `queue.async { removeItem(...) }`，同样没有并发上限（且不等待结束）。

**现象/风险**

- 当 orphaned 文件数量非常大（例如外部存储目录历史遗留、或 DB/文件不一致导致积累）时：
  - `withTaskGroup` 会一次性创建 **N 个 task**；`deleteFilesInParallel` 会一次性提交 **N 个 block** 到并发队列。
  - 在 N 达到几千/几万时，会出现明显的调度开销、内存压力、以及文件系统抖动（I/O contention）。在极端情况下会反过来影响 UI 响应与 ingest/search 延迟。
- 这类路径通常发生在“长时间运行 + 清理/迁移/异常恢复”场景，属于典型的“平时不痛、出事很痛”的稳定性/性能风险点。

**建议修复（把并发变成“有上限的并发”）**

1. `cleanupOrphanedFiles()`：使用“限流 TaskGroup”  
   - 例如并发度 `maxConcurrentDeletes = 4/8`：先填满 N 个 task，然后每 `await group.next()` 完成一个再补一个，避免瞬间创建海量 task。
2. `deleteFilesInParallel(_:)`：避免为每个文件都 `queue.async`  
   - 可改为 `OperationQueue`（`maxConcurrentOperationCount`）或批处理删除（例如按 batch 100/500 分段提交）。
3. 可选：为删除失败的计数/采样日志提供可观测性（debug level 即可），便于发现“删除失败导致的存储泄漏回潮”。

**验证方式**

- 构造外部目录 10k+ orphan file 的本地场景，触发 `cleanupOrphanedFiles()`：比较修复前后 CPU 峰值、耗时、主线程卡顿（可用 `os_signpost` 或 Instruments Time Profiler）。

---

## P2-8：`getStorageStats()` / `getDetailedStorageStats()` 重复做全量遍历，首屏/刷新可能触发两次重扫描

**定位**

- `Scopy/Application/ClipboardService.swift:353-378`：
  - `getStorageStats()` 与 `getDetailedStorageStats()` 都会计算：`getDatabaseFileSize()` + `getExternalStorageSizeForStats()`（全量遍历）+ `getThumbnailCacheSize()`（全量遍历）。
- `Scopy/Observables/HistoryViewModel.swift:282-307`：
  - `load()` 会 `await service.getStorageStats()`，紧接着又 `await settingsViewModel.refreshDiskSizeIfNeeded()`。
- `Scopy/Observables/SettingsViewModel.swift:70-90`：
  - `refreshDiskSizeIfNeeded()` 在缓存 miss 时调用 `service.getDetailedStorageStats()`（再次遍历）。

**现象/风险**

- `getExternalStorageSizeForStats()` / `getThumbnailCacheSize()` 都是“枚举目录计算大小”的 I/O 重操作（外部存储与缩略图目录中文件越多越慢）。
- 由于 `getStorageStats()` 与 `getDetailedStorageStats()` 实现几乎相同：
  - **首屏加载**（`HistoryViewModel.load()`）在 disk size cache 失效的场景下，可能会触发 **两次** 目录遍历（一次来自 `getStorageStats()`，一次来自 `getDetailedStorageStats()`）。
  - 即使 cache 命中，`getStorageStats()` 仍会每次做全量遍历（因为它走的是 `ForStats` 版本，绕过 `getExternalStorageSize()` 的 180s 缓存）。
- 这会带来：
  - 不必要的后台 I/O 与能耗；
  - 首屏/刷新路径 `isLoading` 拉长（用户交互“被认为还在加载中”，例如 loadMore 被禁用）。

**建议修复（先明确“getStorageStats 的语义”）**

> 当前 UI（Footer）显示 `storageSizeText = "\(contentSize) / \(diskSize)"`，看起来更像“内容估算 / 实际磁盘占用”两种口径。

1. 如果 `getStorageStats()` 的目标是“便宜的内容估算”（推荐）  
   - `sizeBytes` 改为 `SUM(size_bytes)`（`StorageService.getTotalSize()`），避免任何目录遍历。  
   - `getDetailedStorageStats()` 保留做真实磁盘占用（目录遍历 + DB/WAL/SHM stat），并由 `SettingsViewModel` 缓存（现有 TTL=120s 已有）。
2. 如果 `getStorageStats()` 的目标是“快速得到磁盘占用”  
   - 直接让 `getStorageStats()` 复用 `getDetailedStorageStats()` 的结果（或共享一个内部实现 + 可选缓存），避免两套几乎相同的逻辑；  
   - 并在 `HistoryViewModel.load()` 里避免“先算一次总量、随后又算一次详细”的重复调用（例如先只拿 itemCount，磁盘统计异步刷新 UI）。

**验证方式**

- 构造外部存储/缩略图目录有 10k+ 文件的场景，测 `HistoryViewModel.load()` 的 elapsedMs（已有 `PerformanceMetrics`），并用 Instruments 观察目录枚举次数与 I/O 时间；确认是否存在重复遍历以及修复后的改善幅度。

---

## P2-9：清空搜索/筛选时未版本化/未取消 in-flight paging，旧任务可能污染新列表；部分 UI 还会重复触发 `search()`

**定位**

- `Scopy/Observables/HistoryViewModel.swift:414-429`：
  - `search()` 在 “无搜索/无过滤” 时走早返回：`Task { await load() }`，**没有** `searchVersion += 1`，也 **没有** `loadMoreTask?.cancel()`。
- `Scopy/Views/HeaderView.swift:21-45`：
  - `TextField(...).onChange(of: searchQuery) { historyViewModel.search() }`
  - Clear 按钮同时 `searchQuery = ""` 且显式调用 `historyViewModel.search()`（与 `onChange` 叠加）。
- `Scopy/Views/ContentView.swift:74-81`：
  - `Esc` 清空搜索时，同样 `searchQuery = ""` 且显式调用 `historyViewModel.search()`（与 `onChange` 叠加）。

**现象/风险**

1. **旧 loadMore 任务可能污染新列表（竞态）**  
   - `loadMore()` 通过 `currentVersion == searchVersion` 来拒绝旧请求结果；但当清空搜索/过滤走早返回路径时，`searchVersion` 不变、`loadMoreTask` 也不取消。  
   - 如果用户在搜索结果中触发了分页加载（`loadMoreTask` in-flight），并在其完成前清空搜索/过滤，那么旧 `loadMoreTask` 可能在之后继续把“旧搜索的下一页结果” append 到“新加载的 unfiltered 列表”上，造成列表混入无关条目、计数错乱或短暂闪烁。
2. **重复触发 `search()`（导致重复 load / 版本抖动）**  
   - Clear/Esc 路径里同时 “改 searchQuery” + “手动调用 search()”，会导致 `onChange` 再触发一次 `search()`。  
   - 典型结果是：清空搜索时可能触发两次 `load()`（顺序串行但会重复 I/O），并且让任务取消/版本逻辑更难推理。

**建议修复（让状态机更“原子 + 可推理”）**

1. 清空搜索/过滤也应视为一次“新 query”  
   - 在 `HistoryViewModel.search()` 的早返回分支里同样：
     - `searchVersion += 1`
     - `loadMoreTask?.cancel(); loadMoreTask = nil`
     - （可选）引入 `loadTask` 并在新 query 时 cancel，避免 `load()` 与搜索任务交错覆盖。
2. 统一“触发 search 的单一来源”  
   - 要么只依赖 `HeaderView` 的 `onChange`；要么移除 `onChange` 改为显式触发（但两者不要叠加）。  
   - Clear/Esc 分支仅设置 `searchQuery` 即可（由 `onChange` 触发后续），避免双触发。

**验证方式**

- 人工制造慢查询：在 debug 下让 `service.search`/`service.fetchRecent` 增加延迟（或用 Instruments 降速），复现步骤：
  1) 输入搜索词 → 滚动到底触发 `loadMore()`；  
  2) 在 loadMore 未完成前立刻清空搜索；  
  3) 观察列表是否出现“旧搜索结果混入”或计数异常。  
- 加临时 debug log：打印 `searchVersion`、`currentVersion`、`loadedCount/totalCount` 的变化，确认旧任务是否仍在 apply。

---

## P2-10：Clear All（deleteAllExceptPinned）在主线程同步删除大量外部文件，极端情况下会卡 UI

**定位**

- `Scopy/Application/ClipboardService.swift:220-226`：`clearAll()` 调用 `storage.deleteAllExceptPinned()`。
- `Scopy/Services/StorageService.swift:353-370`：`deleteAllExceptPinned()` 在 `@MainActor` 上遍历 `storageRefsForUnpinned`，同步执行 `FileManager.default.removeItem(atPath:)`。

**现象/风险**

- 在“外部存储文件数很多”（例如大量截图/图片、RTF/HTML 外部化、历史较大且清理策略较宽松）的情况下，Clear All 会在主线程做大量同步 I/O：
  - UI 线程可能被长时间占用（窗口卡顿/无响应）；
  - 删除过程无并发上限/无节流（顺序删除虽不会创建海量并发任务，但会在 main 上持续阻塞）。
- 这不是 crash，但属于明显的 UX/可用性问题：用户在“想快速清空”时反而感知到应用“卡死”。

**建议修复（复用现有能力，避免大改）**

1. **把批量文件删除移出主线程**  
   - 复用现有 `deleteFilesInParallel(_:)`（或改造成 bounded concurrency 的 async 版本），并在后台执行。
2. **可选：为 Clear All 做“分段/进度”**  
   - 如果要做到更稳健：在 UI 上提供进度/状态（例如 “Clearing…”），并允许取消（取消语义需明确）。

**验证方式**

- 构造 10k+ 外部文件的场景（可用测试数据目录或脚本生成空文件模拟），然后触发 Clear All：
  - 观察主窗口是否卡住、卡住多久；
  - Instruments（Main Thread）查看是否大量时间消耗在 `FileManager.removeItem` / filesystem calls。

---

## P3-1：“内联存储上限”语义可能误导：实际约束 `SUM(size_bytes)` 而非数据库文件大小

**定位**

- UI 文案：`Scopy/Views/Settings/StorageSettingsPage.swift:36-49`（“内联存储上限”）
- cleanup 判定：`Scopy/Services/StorageService.swift:517-522`：`let dbSize = try await getTotalSize()`
- 统计口径：`Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift:280-285`：`SELECT SUM(size_bytes)`
- UI 展示数据库大小：`Scopy/Application/ClipboardService.swift:364-377` 用 `getDatabaseFileSize()`（包含 wal/shm）

**现象/风险**

- 用户直觉上会把“内联存储上限”理解为“数据库文件大小上限”。但当前 cleanup 用的是 `SUM(size_bytes)`（内容大小估算），而 UI 同时又展示真实的 DB 文件大小。两者可能偏离较大（索引、WAL、SQLite 页开销都会让 DB file size > SUM(size_bytes)）。

**建议修复**

- 二选一（或都做）：
  1) **改文案/说明**：明确上限按 `sizeBytes` 累加，不等同数据库文件体积；  
  2) **改实现口径**：按 `getDatabaseFileSize()`（或 DB+WAL）做阈值判断；  
  3) UI 同时展示两种口径（“内容估算/DB 文件大小”），避免误解。

---

## P3-2：命名误导：`getOriginalImageData` 实际是“取 raw payload”，被用于 file/rtf/html

**定位**

- `Scopy/Services/StorageService.swift:960-982`：`func getOriginalImageData(for item: StoredItem) -> Data?`
- `Scopy/Application/ClipboardService.swift:236-298`：对 `.rtf/.html/.file` 也调用该函数（file 分支甚至用变量名 `urlData` 接收）。

**问题**

- 函数名表达的是“图片原始数据”，但实际语义是“取回 item 的 raw payload（可能来自 rawData 或 storageRef 外部文件或 DB 重新加载）”。这种命名会误导后续维护者：
  - 可能在非 image 类型上误用/误判；
  - 难以通过名字理解它是“通用 payload loader”。

**建议**

- 重命名为更贴近语义的名称，例如 `getPayloadData(for:)` / `loadPayloadData(for:)`；或拆分为 `getImageData` / `getRTFData` / `getFileURLData` 等类型专用方法，提升可读性与类型安全。

---

## P3-3：HotKeyService 在锁内做日志/构造数组，临界区偏大（低优先级）

**定位**

- `Scopy/Services/HotKeyService.swift:311-326`：`sharedState.withValue { ... }` 内部构造 `availableKeys` + `logToFile(...)`。

**影响**

- 热键事件频率不高，因此这是“微优化”。但在 lock 内做不必要的分配与日志拼接会放大临界区，理论上增加争用风险，也不利于未来扩展（例如多热键、更多 handler）。

**建议**

- 在锁内只做“读取 handler + 更新 lastFire”这类必须原子化的操作；把 `availableKeys` 构造与日志输出搬到锁外（必要时复制一份轻量 snapshot）。

---

## P3-4：部分 UI 测试依赖固定 sleep，可能在慢机器/CI 上 flaky

**定位**

- `ScopyUITests/ContextMenuUITests.swift` / `ScopyUITests/HistoryListUITests.swift` / `ScopyUITests/KeyboardNavigationUITests.swift`：多处使用 `Thread.sleep(forTimeInterval:)` 等待 UI debounce/动画。

**影响**

- 固定 sleep 在性能波动或 CI 繁忙时容易不足，导致间歇性失败；也会让测试总时长不必要增加（为了“保守”只能把 sleep 写长）。

**建议**

- 优先用“条件等待”替代固定 sleep：例如 `XCTWaiter` + predicate / `XCTNSPredicateExpectation` 等待某个 element 出现/状态变化，或复用 `ScopyTests/Helpers/XCTestExtensions.swift` 的轮询等待工具。
- 如果必须 sleep：把 sleep 值集中封装为常量并与 UI debounce 值（例如 150–200ms）绑定解释，方便统一调整。

---

## P3-5：hover Markdown 渲染任务取消不够“及时”（CPU 浪费风险，低优先级）

**定位**

- `Scopy/Views/History/HistoryItemView.swift:522-568`：hover 预览触发后，对 Markdown 的 HTML 渲染使用 `hoverMarkdownTask = Task.detached { MarkdownHTMLRenderer.render(...) ... }`。

**现象/风险**

- 取消是“协作式”的：当用户快速移动鼠标/滚动列表时，旧的 `hoverMarkdownTask` 会被取消，但 `MarkdownHTMLRenderer.render(markdown:)` 是同步 CPU 工作，不会自动停下（除非内部显式检查取消）。
- 结果是：在频繁 hover 的场景中，可能出现“渲染结果不会落到 UI（被 guard 掉），但 CPU 仍然做了无用功”的浪费；一般不影响正确性，但会让风扇更容易转、影响电量与瞬时流畅度。

**建议**

- 最小改动：在进入重渲染前补一次快速取消检查（减少无谓渲染的触发概率）：
  - `guard !Task.isCancelled else { return }`（在调用 `MarkdownHTMLRenderer.render` 前）。
- 若要更彻底：让 `MarkdownHTMLRenderer.render` 内部在关键阶段插入 `Task.checkCancellation()`（需要评估改动范围与维护成本）。

**验证方式**

- 用 Instruments Time Profiler 在“快速划过多条 Markdown item”场景观察 CPU 峰值；或临时记录 `Task.isCancelled` 与渲染耗时分布，确认是否存在较多“被取消但仍耗时渲染”的任务。

---

## P3-6：SQLiteMigrations 创建外部 content FTS5 后未做 rebuild（仅影响：FTS 第一次在“已有数据”的 content table 上创建）

**定位**

- `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift:45-86`：`setupFTS(_:)` 负责：
  - `CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(...)`
  - 创建 insert/delete/update trigger（v2 仅在 `plain_text` 变化时更新 FTS）
- 迁移流程中未见对 FTS 的 `rebuild`（例如 `INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild')`）。

**外部参考（交叉验证：官方文档 + 官方论坛）**

- SQLite 官方文档：External Content Table Pitfalls 明确描述了“先 populate content table，再创建 external content FTS”时，FTS index 为空导致 `MATCH` 返回 0 的不一致行为。  
  https://sqlite.org/fts5.html#external_content_table_pitfalls
- SQLite 官方文档：`rebuild` 命令会删除并基于 content table 重建全量索引（external content / 普通表均可用）。  
  https://sqlite.org/fts5.html#the_rebuild_command
- SQLite 官方论坛（SQLite User Forum）：维护者在 external content 场景中建议使用 `rebuild`（并附官方文档链接）。  
  https://sqlite.org/forum/forumpost/413819ed723cc00741a4030e72d3a59f3a2891490be670b17dc75f5c1bf1c7ec

**现象/风险（取决于“是否存在第一次创建 FTS 的升级路径”）**

- 对“正常从已有 FTS 的版本升级”的用户：大概率无影响（FTS 表已存在且由 trigger 持续维护）。
- 但在以下场景中可能出现高影响问题：
  1) 旧数据库存在 `clipboard_items` 但缺少 `clipboard_fts`（或 `clipboard_fts` 是新创建的空索引）；
  2) 迁移仅 `CREATE VIRTUAL TABLE` + 安装 trigger，会让“后续变更”保持同步，但**已存在 rows 不会自动回填进索引**（官方文档已明确该 pitfall）；
  3) 结果是：UI 能加载 Recent（来自 `clipboard_items`），但 exact（FTS）路径搜索命中为空，表现为“历史在，但搜索搜不到”。

**建议修复（低成本，避免未来踩坑）**

1. 仅在检测到 FTS 表“首次创建”时执行一次 rebuild  
   - 例如：在 `setupFTS` 前先查 `sqlite_master` 是否已有 `clipboard_fts`；若是新建，则在最后执行：  
     - `INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild')`
2. 或在迁移版本变更时按需 rebuild（如果未来还有 FTS schema/tokenizer 变更）  
   - 注意：rebuild 可能是 O(n) 且耗时，需要结合启动体验与数据量（可放后台并在完成前降级 search 行为）。

**验证方式**

- 构造一个“只有 `clipboard_items`、没有 `clipboard_fts`”的 DB：
  1) 插入若干条 `plain_text`；
  2) 设置 `PRAGMA user_version` 低于 `SQLiteMigrations.currentUserVersion`；
  3) 启动 app 触发迁移后，立刻用 exact 长词（>2）搜索这些已存在数据；
  4) 若搜索为空但 Recent 能看到数据，则说明需要 rebuild。

---

## P3-7：HotKeyRecorderView 用固定 sleep 同步持久化 hotkey，存在竞态与误报风险（低优先级）

**定位**

- `Scopy/Views/Settings/HotKeyRecorderView.swift:63-93`：`syncFromPersistedSettings(...)`：
  - `Task.sleep(50ms)` 后 `await settingsViewModel.loadSettings()`；
  - 若持久化 hotkey 与 `expectedKeyCode/modifiers` 不一致，则把 UI 的 `keyCode/modifiers` 回滚到持久化值，并提示“快捷键不可用”。

**现象/风险**

- 这里的 sleep 是为了给异步持久化（`AppDelegate.applyHotKey` 内部 `Task { await settingsStore.updateHotkey(...) }`）一个调度窗口。  
  但固定 50ms 并不能从机制上保证“持久化一定已经完成”：
  - 在系统负载较高/主线程很忙/Task 调度被延迟时，`loadSettings()` 仍可能读到旧值；
  - 进而触发 **误判**：“快捷键不可用”提示 + UI 回滚到旧热键（即便新热键可能已经注册成功）。

**建议（更确定的同步方式，避免 time-based 假设）**

1. 把 `applyHotKeyHandler` 升级为 async（或带 completion），并返回“最终生效的 hotkey（或失败原因）”，UI 只以该结果更新展示。
2. 或改为订阅 settings 变更：等待 `SettingsStore`/`.settingsChanged` 广播到达后再做一致性校验，而不是固定 sleep。
3. 最小改动兜底：将 50ms 改为“重试 N 次（短间隔）直到读到一致”并设上限（避免极端情况下误报）。

**验证方式**

- 人为制造调度延迟：在 Debug 下临时给 `SettingsStore.updateHotkey` 增加可控 delay（或在 applyHotKey 持久化前后加重 CPU 负载），观察是否能触发误报与 UI 回滚。

---

## 补充：本次 review 中“暂未发现明显问题”的点（避免强行找问题）

- Search 取消与超时：`SearchEngineImpl.search` 使用 `withTaskCancellationHandler` + `sqlite3_interrupt`，并有 `withTimeout` 包裹（整体方向正确）。
- 大内容 ingest：`ClipboardMonitor` 对图片/大内容走后台 Task，并提供 ingest spool 文件清理（结构化并发、取消路径基本齐全）。
- Storage 外部存储清理：`cleanupOrphanedFiles` 有“测试环境保护 + 根目录一致性保护”（安全性意识较强）；但“极端大量文件删除”的并发上限仍建议补齐（见 P2-7）。

---

## 后续建议（如果要把这些问题转成可执行任务）

1. 先确认产品语义：exact 短词是否允许只搜最近 N 条；大文本是否要求全文可搜索。
2. 以最小改动闭环高价值问题：优先修 P1-1（Timer common modes / DispatchSourceTimer）与 P1-2（exact 短词 prefilter/refine 或 UI 提示）。
3. 统一 hash 方案并补齐测试：用 CryptoKit（或保留 fallback）+ 加入 SHA256 测试向量。
4. 为 full fuzzy index 加入“健康度阈值/重建”机制，避免 tombstone 漂移导致的长期性能退化。
5. 修复生命周期原子性：让 `ClipboardService.start()` 在抛错后仍可重试（P2-5）。
6. 修复 hover Markdown preview 可能的 WebView retain cycle 泄漏（P2-6）。
7. 为“大量文件删除”增加并发上限/批处理（含 cleanup 与 Clear All），避免清理时出现调度/I/O 抖动（P2-7/P2-10）。
8. 降低 UI 测试 flaky：用条件等待替代固定 sleep（P3-4）。
9. 让“清空搜索/过滤”的行为也走统一的版本化/取消逻辑，避免旧分页任务污染新列表（P2-9）。
10. 拆分“内容估算 vs 磁盘占用”的统计口径，并消除首屏加载的重复目录遍历（P2-8）。
11. 为 SQLite FTS 迁移补齐 rebuild（仅在首次创建/必要时），并用验证用例确认旧数据可被 FTS 搜到（P3-6）。
12. 去掉 HotKey 录制后的固定 sleep 同步方式，改为明确的“结果回传/订阅确认”（P3-7）。

---

## 第二轮（更细粒度）深挖：重点文件详评

> 说明：本节挑“关键路径 + 体积最大/复杂度最高/最可能出稳定性与性能问题”的文件做更细粒度 review；其余文件仍保持 Quick Notes（见后文），避免为了“逐文件”而强行放大低价值细节。

### `Scopy/Views/History/MarkdownPreviewWebView.swift`

- **职责**：承载 Markdown hover-preview 的 `WKWebView` 渲染、网络阻断（content rule list）、与 JS→Swift 的 size bridge（`scopySize`）。
- **做得好的点**：`nonPersistent` data store、禁用外链/新窗口、网络阻断 + CSP 组合，整体安全边界比较清晰。
- **关键风险**：复用 controller 通过 `WKScriptMessageHandler` 注册自身，存在典型 retain cycle（P2-6）。
- **建议验证**：对频繁 hover/滚动场景用 Instruments 验证 controller 是否可释放；一旦确认泄漏，优先用“弱代理 handler”断环。

### `Scopy/Views/History/HistoryItemView.swift`

- **职责**：列表单行渲染、hover-preview 任务编排、Markdown 检测与缓存、预览延迟/取消等。
- **做得好的点**：对大文本做阈值保护（`utf16.count <= 200_000`）、缓存命中直接复用 controller、任务取消逻辑整体较完整。
- **可改进点**：Markdown 渲染是同步 CPU 工作，取消只能“阻止 UI 更新”，无法阻止渲染本身（P3-5，低优先级）。

### `Scopy/Services/StorageService.swift`

- **职责**：DB + 外部存储读写、清理策略（count/age/size/external）、缩略图与 size 统计、孤立文件回收。
- **做得好的点**：多处路径安全检查（path normalize / traversal 防护）、测试环境保护、清理策略分层清晰。
- **关键风险**：清理路径在“海量文件”下缺少并发上限（`cleanupOrphanedFiles`/`deleteFilesInParallel`）（P2-7）。
- **另一路径**：Clear All（`deleteAllExceptPinned`）在 `@MainActor` 上顺序删文件，极端情况下会卡 UI（P2-10）。
- **建议验证**：用 10k/25k 文件场景跑一次 cleanup，观察主线程与 I/O 抖动；确认后引入 bounded concurrency。

### `Scopy/Infrastructure/Search/SearchEngineImpl.swift`

- **职责**：recent cache / FTS / fuzzy / regex 多策略搜索，分页、取消与超时。
- **做得好的点**：循环内 `Task.checkCancellation()`、`sqlite3_interrupt` 取消、`withTimeout` 包裹，整体健壮性方向正确。
- **主要问题已在上文覆盖**：exact 短词 cache-only（P1-2）、fuzzy tombstone 漂移（P2-2）、FTS rank 偏离（P2-3）。

### `Scopy/Services/ClipboardMonitor.swift`

- **职责**：轮询剪贴板变化、提取/归一化、去重 hash、ingest spool、与存储/索引衔接。
- **关键风险**：Timer RunLoop mode（P1-1）、自实现 SHA256（P2-1）、大文本策略偏离（P2-4）。
- **做得好的点**：图片重编码延迟到后台、对 ingest payload 的落盘与取消清理、整体链路分层清晰。

### `Scopy/Application/ClipboardService.swift`

- **职责**：组合 monitor/storage/search、对外暴露 API、事件流与 UI 侧消费。
- **关键风险**：启动的原子性（P2-5）。
- **额外关注**：`getStorageStats()` 与 `getDetailedStorageStats()` 的重复/昂贵统计逻辑，会放大首屏与刷新路径的 I/O（P2-8）。
- **做得好的点**：启动失败回退到 mock 的用户体验兜底较完善（由 `AppState` 协同）。

---

### `Scopy/Observables/HistoryViewModel.swift`

- **职责**：搜索/过滤/分页、滚动状态、选中项与 keyboard nav、与设置/统计联动。
- **做得好的点**：search debounce + fuzzy refine 机制、分页前强制 full fuzzy 的兜底（对齐“prefilter→refine”思路）。
- **关键风险**：清空搜索/过滤的早返回路径未版本化/未取消 loadMoreTask，存在旧任务污染新列表的竞态（P2-9）。

### `Scopy/Views/HeaderView.swift` / `Scopy/Views/ContentView.swift`

- **职责**：搜索输入与快捷键交互（清空/提交/选择），以及 filter/mode 的 UI 入口。
- **做得好的点**：把“耗时工作”下沉到 ViewModel（debounce/refine），UI 侧只做轻量触发。
- **关注点**：Clear/Esc 路径里“手动 `search()` + `onChange`”叠加会造成双触发，建议统一触发源（P2-9）。

### `Scopy/AppDelegate.swift`

- **职责**：面板/设置窗口生命周期、热键注册与持久化、与 `AppState` 的回调桥接。
- **做得好的点**：`applyHotKey` 有失败回退与持久化兜底；local event monitor 在 `applicationWillTerminate` 解除注册，避免泄漏。

### `Scopy/Infrastructure/Settings/SettingsStore.swift`

- **职责**：UserDefaults 的 Settings SSOT（actor），并提供 `AsyncStream` 订阅。
- **做得好的点**：订阅端 `onTermination` 会从 actor 内移除 continuation；suiteName init 兼容 strict concurrency 的 Sendable 限制（整体实现稳健）。

## 逐模块 / 逐文件 Review（Quick Notes）

> 说明：这里是“逐文件的一句话结论/关注点”。详细问题见上方对应 ID（例如 P1-1/P2-2 等）；未特别标注的一般表示“未发现明显问题（或问题已在上文覆盖）”。

### App 入口与窗口（Frontend Shell）

- `Scopy/main.swift`：应用入口（支持测试模式分离）；OK。
- `Scopy/ScopyApp.swift`：SwiftUI App 壳（`MenuBarExtra` hidden 场景）；OK。
- `Scopy/AppDelegate.swift`：状态栏/面板/设置窗口/热键应用与持久化；OK（hotkey 失败回退逻辑健壮）。
- `Scopy/FloatingPanel.swift`：浮动面板定位与自动关闭；OK。

### Application（ScopyKit）

- `Scopy/Application/ClipboardService.swift`：组合 monitor/storage/search + event stream + cleanup/thumbnail；关注启动原子性（P2-5）与存储统计重复遍历/重复计算（P2-8）。

### Services（ScopyKit）

- `Scopy/Services/ClipboardMonitor.swift`：NSPasteboard 轮询 + extract + ingest spool + hash/dedup；关注 Timer runloop mode（P1-1）与自实现 SHA256（P2-1），以及大文本策略（P2-4）。
- `Scopy/Services/StorageService.swift`：SQLite + 外部存储 + cleanup + thumbnails；关注大文本策略（P2-4）、“清理大量文件”的并发上限（P2-7）、Clear All 批量删文件主线程阻塞风险（P2-10）、size 口径（P3-1）、payload loader 命名（P3-2）；路径校验/防 traversal 做得好。
- `Scopy/Services/HotKeyService.swift`：Carbon 热键注册/节流/日志；关注锁内日志微优化（P3-3）。
- `Scopy/Services/RealClipboardService.swift`：UI adapter（转发到 actor）；OK。
- `Scopy/Services/MockClipboardService.swift`：mock backend（UI/测试）；OK。
- `Scopy/Services/PerformanceProfiler.swift`：指标采样/基准跑器；OK（percentile 口径为简化实现，作为展示/调试足够）。
- `Scopy/Services/ThumbnailGenerationTracker.swift`：缩略图生成去重 tracker（actor）；OK。

### Infrastructure（ScopyKit）

#### Configuration

- `Scopy/Infrastructure/Configuration/ScopyThresholds.swift`：阈值集中定义；OK（建议在文档里解释 shortQueryCacheSize=2000 与 100KB 阈值的 UX/性能取舍）。

#### Persistence

- `Scopy/Infrastructure/Persistence/SQLiteConnection.swift`：SQLite wrapper（prepare/bind/step）；OK。
- `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`：schema + FTS5 triggers；注意“external content FTS 第一次创建在已有数据上”需要 rebuild 才能让旧数据可被 MATCH 命中（P3-6）；v2 trigger 仅在 plain_text 更新时刷新，降低写放大。
- `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`：actor repo + SQL；OK（统计口径相关见 P3-1）。
- `Scopy/Infrastructure/Persistence/ClipboardStoredItem.swift`：DB row model；OK。

#### Search

- `Scopy/Infrastructure/Search/FTSQueryBuilder.swift`：FTS5 query 构造/转义；OK。
- `Scopy/Infrastructure/Search/SearchEngineImpl.swift`：cache/FTS/fuzzy/regex + cancellation + statement cache；关注 exact 短词 cache-only（P1-2）、fuzzy index tombstone 漂移（P2-2）、FTS rank（P2-3）；regex 也是 cache-only（见 P1-2 备注）。

#### Settings

- `Scopy/Infrastructure/Settings/SettingsStore.swift`：Settings SSOT + AsyncStream；OK。

### Domain（ScopyKit）

- `Scopy/Domain/Models/ClipboardEvent.swift`：事件枚举；OK。
- `Scopy/Domain/Models/ClipboardItemDTO.swift`：前端 DTO；OK。
- `Scopy/Domain/Models/ClipboardItemType.swift`：类型枚举；OK。
- `Scopy/Domain/Models/SearchMode.swift`：搜索模式；OK。
- `Scopy/Domain/Models/SearchRequest.swift`：搜索请求（含 typeFilters/forceFullFuzzy）；OK。
- `Scopy/Domain/Models/SearchResultPage.swift`：分页结果；OK。
- `Scopy/Domain/Models/SettingsDTO.swift`：设置 DTO；OK。
- `Scopy/Domain/Models/StorageStatsDTO.swift`：存储统计 DTO；OK（formatBytes 仅到 MB，属于 UI 取舍）。
- `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`：前后端接口；OK（命名一致性相关见 P3-2）。
- `Scopy/Domain/Utilities/TextMetrics.swift`：字/词计数；OK（CJK/Latin 兼容性考虑到位）。

### Utilities & Extensions（ScopyKit）

- `Scopy/Utilities/AsyncBoundedQueue.swift`：有界 async queue（backpressure）；OK（`removeFirst` 为 O(n) 但容量受限、场景可接受）。
- `Scopy/Utilities/ScopyLogger.swift`：os.Logger 分类；OK。
- `Scopy/Extensions/NSLock+Extensions.swift`：`withLock` helper；OK。

### Observables（Frontend State）

- `Scopy/Observables/AppState.swift`：service lifecycle + event fan-out；OK（启动失败 fallback 到 mock）。
- `Scopy/Observables/HistoryViewModel.swift`：load/search/paging/keyboard nav + refine；关注与 P1-2（prefilter/refine 语义）耦合点，以及清空搜索/过滤时的版本化/取消竞态（P2-9）。
- `Scopy/Observables/SettingsViewModel.swift`：设置与存储统计；OK（含 diskSize cache）。
- `Scopy/Observables/PerformanceMetrics.swift`：指标收集与展示；OK（sample==0 的 N/A 已修复）。

### Presentation（Frontend）

- `Scopy/Presentation/ClipboardItemDisplayText.swift`：title/metadata 派生缓存；OK。

### Design（Frontend）

- `Scopy/Design/Localization.swift`：本地化 key/文案入口；OK。
- `Scopy/Design/ScopyColors.swift`：颜色 token；OK。
- `Scopy/Design/ScopyComponents.swift`：组件样式 token；OK。
- `Scopy/Design/ScopyIcons.swift`：SFSymbols 映射；OK。
- `Scopy/Design/ScopySize.swift`：尺寸 token；OK。
- `Scopy/Design/ScopySpacing.swift`：间距 token；OK。
- `Scopy/Design/ScopyTypography.swift`：字体 token；OK。

### Views（Frontend）

#### Root Views

- `Scopy/Views/ContentView.swift`：主界面容器 + 快捷键处理；Esc 清空搜索时避免重复触发 `search()`（与 Header `onChange` 叠加，见 P2-9）。
- `Scopy/Views/HeaderView.swift`：搜索框 + filter/menu；注意 Clear 时避免“手动 `search()` + `onChange` 再触发一次”的双触发（P2-9）。
- `Scopy/Views/HistoryListView.swift`：List 虚拟列表 + loadMore trigger；OK（10k+ 内存优化已落地）。
- `Scopy/Views/FooterView.swift`：状态栏统计 + actions；OK。

#### History Subviews

- `Scopy/Views/History/EmptyStateView.swift`：空态；OK。
- `Scopy/Views/History/HistoryItemImagePreviewView.swift`：图片 hover 预览；OK。
- `Scopy/Views/History/HistoryItemTextPreviewView.swift`：文本/Markdown hover 预览；OK（安全策略见下）。
- `Scopy/Views/History/HistoryItemThumbnailView.swift`：缩略图加载/缓存；OK。
- `Scopy/Views/History/HistoryItemView.swift`：单行渲染 + hover 任务管理；关注 hover Markdown 渲染任务的取消细节（P3-5）（逻辑复杂但取消与清理较完整）。
- `Scopy/Views/History/HoverPreviewModel.swift`：preview state；OK。
- `Scopy/Views/History/HoverPreviewScreenMetrics.swift`：popover 屏幕约束；OK。
- `Scopy/Views/History/HoverPreviewTextSizing.swift`：文本尺寸估算/测量；OK（大文本 fast-path 合理）。
- `Scopy/Views/History/LaTeXDocumentNormalizer.swift`：LaTeX→Markdown 正则归一化；OK（建议持续靠回归测试防退化）。
- `Scopy/Views/History/LaTeXInlineTextNormalizer.swift`：inline LaTeX 文本归一化；OK（code-skip 思路正确）。
- `Scopy/Views/History/ListLiveScrollObserverView.swift`：滚动检测；OK。
- `Scopy/Views/History/LoadMoreTriggerView.swift`：分页触发；OK。
- `Scopy/Views/History/MarkdownCodeSkipper.swift`：跳过 code 段处理；OK。
- `Scopy/Views/History/MarkdownDetector.swift`：Markdown/Math 检测；OK（避免误判货币/变量的处理较稳健）。
- `Scopy/Views/History/MarkdownHTMLRenderer.swift`：Markdown+KaTeX HTML 生成；OK（CSP + JSON literal + HTML escaping + 禁用 HTML 渲染，安全性意识到位）。
- `Scopy/Views/History/MarkdownPreviewCache.swift`：HTML cache；OK。
- `Scopy/Views/History/MarkdownPreviewWebView.swift`：WKWebView render + 网络阻断 + size bridge；关注可复用 controller 的 message handler retain cycle 风险（P2-6）。
- `Scopy/Views/History/MathEnvironmentSupport.swift`：KaTeX delimiter/support；OK。
- `Scopy/Views/History/MathNormalizer.swift`：loose LaTeX/括号包裹等；OK（建议持续用真实题目样本做回归）。
- `Scopy/Views/History/MathProtector.swift`：math segment 保护/还原；OK（属于关键安全/正确性组件，已见较多回归测试）。
- `Scopy/Views/History/SectionHeader.swift`：列表 header；OK。

#### Settings Subviews

- `Scopy/Views/Settings/SettingsView.swift`：Save/Cancel 事务模型（isDirty）；OK（符合仓库约定：非 autosave）。
- `Scopy/Views/Settings/SettingsPage.swift` / `SettingsPageHeader.swift` / `SettingsComponents.swift` / `SettingsFeatureRow.swift`：设置页框架/组件；OK。
- `Scopy/Views/Settings/GeneralSettingsPage.swift` / `ShortcutsSettingsPage.swift` / `ClipboardSettingsPage.swift` / `AppearanceSettingsPage.swift` / `StorageSettingsPage.swift` / `AboutSettingsPage.swift`：各设置页；关注 Storage 文案口径（P3-1）。
- `Scopy/Views/Settings/HotKeyRecorder.swift` / `HotKeyRecorderView.swift`：热键录制；OK（包含恢复旧热键与冲突回退提示）。
- `Scopy/Views/Settings/AppVersion.swift`：版本展示；OK。

### ScopyUISupport（Support Lib）

- `ScopyUISupport/IconService.swift`：app icon/name cache；OK。
- `ScopyUISupport/ThumbnailCache.swift`：缩略图内存 cache + async load；OK。

### Tests

#### Unit Tests（ScopyTests）

- `ScopyTests/AppStateTests.swift`：事件流/状态机覆盖；OK（注意少量 `Task.sleep` 属于异步测试常见取舍）。
- `ScopyTests/ClipboardMonitorTests.swift`：extract/hash/ingest 行为；OK（建议补齐 SHA256 测试向量覆盖，见 P2-1）。
- `ScopyTests/ClipboardServiceCopyToClipboardTests.swift`：copyToClipboard 行为；OK。
- `ScopyTests/ConcurrencyTests.swift`：并发/取消路径覆盖；OK。
- `ScopyTests/FTSQueryBuilderTests.swift`：FTS query 构造；OK。
- `ScopyTests/HotKeyServiceTests.swift`：热键逻辑；OK。
- `ScopyTests/HoverPreviewTextSizingTests.swift`：文本测量；OK。
- `ScopyTests/IntegrationTests.swift`：集成流；OK。
- `ScopyTests/KaTeXRenderToStringTests.swift` / `MarkdownMathRenderingTests.swift` / `MarkdownDetectorTests.swift`：Markdown/KaTeX 正确性回归；OK（属于高价值测试资产）。
- `ScopyTests/PerformanceProfilerTests.swift` / `PerformanceTests.swift`：性能回归；OK。
- `ScopyTests/ResourceCleanupTests.swift`：资源/文件清理；OK。
- `ScopyTests/SearchBackendConsistencyTests.swift` / `SearchServiceTests.swift`：搜索一致性/分页/特殊字符；OK（与 P1-2/P2-2/P2-3 相关的语义建议继续补齐）。
- `ScopyTests/StorageServiceTests.swift`：存储/去重/清理；OK。
- `ScopyTests/TextMetricsTests.swift`：文本计数；OK。
- `ScopyTests/ThumbnailPipelineTests.swift`：缩略图链路；OK。
- `ScopyTests/Helpers/*`：测试工具；OK（`XCTestExtensions.swift` 可用于替代 UI 测试固定 sleep，见 P3-4）。

#### UI Tests（ScopyUITests）

- `ScopyUITests/MainWindowUITests.swift` / `HistoryListUITests.swift` / `KeyboardNavigationUITests.swift` / `ContextMenuUITests.swift` / `SettingsUITests.swift`：主流程覆盖；关注固定 sleep 可能导致 flaky（P3-4）。

### 资源与第三方

- `Scopy/Resources/MarkdownPreview/*`：KaTeX/markdown-it 等第三方 minified 资源；本次未逐行审阅第三方库实现，但应用侧已做网络阻断 + CSP + 禁用 HTML 渲染等安全措施（参见 `MarkdownHTMLRenderer` / `MarkdownPreviewWebView`）。

---

## 第三轮（更细粒度）逐模块 / 逐文件 Review（Expanded Notes）

> 目标：在 Quick Notes 的基础上，把“每个文件”至少落到 **职责/关键路径/关注点** 三类信息，便于后续拆 issue/任务；对不确定点明确写验证方式，避免被已有文档误导或 overclaim。

### ScopyKit（Backend）

#### Application

- `Scopy/Application/ClipboardService.swift`
  - 职责：组合 `ClipboardMonitor/StorageService/SearchEngineImpl/SettingsStore`，对外提供 CRUD/search/settings API；以 `AsyncBoundedQueue` 承载事件流；调度 cleanup 与 thumbnail generation。
  - 关键路径：monitor content stream → `handleNewContent` → `storage.upsertItemWithOutcome` → `search.handleUpsertedItem` → yield UI event。
  - 关注点：启动原子性（P2-5）；首屏/设置页 stats 重复扫描（P2-8）；thumbnail generation 的 detached 任务需注意生命周期与 settings 开关（目前有 `ThumbnailGenerationTracker` 与 `settings.showImageThumbnails` guard）。

#### Services

- `Scopy/Services/ClipboardMonitor.swift`
  - 职责：轮询 NSPasteboard changeCount；按类型提取（file/image/rtf/html/text）；标准化文本；hash 去重；大内容 ingest spool；以 `AsyncBoundedQueue` 暴露 content stream。
  - 关键路径：`Timer` tick → `checkClipboard()` → extractRawData → small sync / large async ingest → enqueue stream。
  - 关注点：RunLoop mode 导致 polling 暂停（P1-1）；自实现 SHA256 性能与正确性保障（P2-1）；纯文本 payload 为 `.none` 导致“大文本外部化”无法触发（P2-4）。

- `Scopy/Services/StorageService.swift`
  - 职责：SQLite 持久化 + 分级存储（inline blob / external file）；dedup 写入；cleanup（count/age/size/external/orphan）；thumbnail 生成/缓存路径管理；存储统计。
  - 关键路径：`upsertItemWithOutcome` 的 externalize 决策 + 写文件/插入 DB 的失败回滚；`performCleanup` 的 plan→delete→transaction。
  - 关注点：清理大批文件缺少 bounded concurrency（P2-7）；Clear All 的批量删文件在 `@MainActor` 同步执行（P2-10）；“内联存储上限”口径（P3-1）；payload loader 命名误导（P3-2）。

- `Scopy/Services/HotKeyService.swift`
  - 职责：Carbon 全局热键注册/卸载；事件回调桥接到 Swift handler；按住重复触发做轻节流；写入 `/tmp/scopy_hotkey.log`。
  - 关键点：共享 handler map + lastFire 需要原子访问（自定义 `Locked`）。
  - 关注点：锁内日志/数组构造（P3-3，低优先级）。

- `Scopy/Services/RealClipboardService.swift`
  - 职责：UI 侧 `ClipboardServiceProtocol` 兼容层（adapter），把调用转发给 `actor ClipboardService`；提供 `createForTesting` 的 shared-cache in-memory URI。
  - 关注点：整体职责单一清晰；静态审阅未见明显问题。

- `Scopy/Services/MockClipboardService.swift`
  - 职责：用于 UI 开发/故障 fallback 的 mock backend；提供分页、搜索、pin/delete/clear 的最小行为。
  - 关注点：`getRecentApps(limit:)` 对 Set 的顺序非确定（仅影响 UI 下拉顺序，非关键）；其它未见明显问题。

- `Scopy/Services/PerformanceProfiler.swift`
  - 职责：轻量性能计时采样与 report（metrics + p50/p95/p99）；benchmark runner（sync/async）。
  - 关注点：percentile 算法为简化实现（工程上可接受）；未见明显正确性风险。

- `Scopy/Services/ThumbnailGenerationTracker.swift`
  - 职责：actor 级别的“同一 contentHash 缩略图生成去重”。
  - 关注点：实现简单明确；未见明显问题。

#### Infrastructure

- `Scopy/Infrastructure/Configuration/ScopyThresholds.swift`
  - 职责：集中阈值（hash offload、ingest spool、并发上限、externalStorage threshold、stream buffer）。
  - 关注点：建议把阈值背后的 UX/性能取舍在文档/注释里再补一层（尤其是短词 cache 2000、externalStorage 100KB）。

- `Scopy/Infrastructure/Persistence/SQLiteConnection.swift`
  - 职责：SQLite 打开/关闭、prepare、bind、step、column 读取的轻量封装（RAII finalize）。
  - 关注点：`bindInt` 使用 Int32（大数需用 `bindInt64`）；目前调用点大多可控，未见明显溢出风险。

- `Scopy/Infrastructure/Persistence/SQLiteMigrations.swift`
  - 职责：schema/索引/FTS5 + trigger 建立；用 `PRAGMA user_version` 管迁移版本。
  - 关注点：FTS 触发器“plain_text-only update”能降低写放大；若存在“首次创建 external content FTS 于已有数据”的升级路径，需要 rebuild 才能索引旧数据（P3-6）。

- `Scopy/Infrastructure/Persistence/SQLiteClipboardRepository.swift`
  - 职责：actor repo，承载绝大多数 SQL（fetchRecent/search/cleanup plan/stats/refs）。
  - 关注点：`getTotalSize()` 已做 Int64→Int 钳制（避免溢出）；FTS SQL 构造与分页策略（LIMIT+1）整体比较成熟。

- `Scopy/Infrastructure/Persistence/ClipboardStoredItem.swift`
  - 职责：内部持久化模型（DB row）；用于 Storage/Search，不直接暴露给 UI。
  - 关注点：`rawData` 可为空（summary 查询不一定载入 blob）；使用方需注意 nil 分支（当前已有 fallback）。

- `Scopy/Infrastructure/Search/FTSQueryBuilder.swift`
  - 职责：把用户输入构造成“更不容易崩”的 FTS5 query（剥离 `*`、拆词 AND、引号转义）。
  - 关注点：属于“安全优先”的构造器；可能牺牲少量高级语法（可接受）。

- `Scopy/Infrastructure/Search/SearchEngineImpl.swift`
  - 职责：search 聚合层：recent cache / FTS / full fuzzy / regex；超时、取消、statement cache；对上层暴露统一 `search(request:)`。
  - 关键点：取消链路完整（`withTaskCancellationHandler` + `sqlite3_interrupt` + loop 内 `Task.checkCancellation()`）。
  - 关注点：exact 短词与 regex cache-only（P1-2）；full fuzzy index tombstone 漂移（P2-2）；FTS rank 偏离 v0.md（P2-3）。

- `Scopy/Infrastructure/Settings/SettingsStore.swift`
  - 职责：actor SSOT，封装 UserDefaults 编解码；支持 AsyncStream 订阅设置变化；提供 hotkey 局部更新。
  - 关注点：`onTermination` 异步移除 subscriber 的实现稳健；未见明显问题。

#### Domain & Utilities

- `Scopy/Domain/Models/*` / `Scopy/Domain/Protocols/ClipboardServiceProtocol.swift`
  - 职责：协议 + DTO + 枚举 + request/response；保证前后端解耦的稳定边界。
  - 关注点：字段与 v0.md 对齐程度较高；建议长期保持 DTO 不塞 UI 派生字段（当前已通过 `Presentation` 层缓存实现）。

- `Scopy/Domain/Utilities/TextMetrics.swift`
  - 职责：中英混排“字/词”统计（CJK 按字计数、Latin/numeric 按词计数）。
  - 关注点：规则清晰且测试覆盖；未见明显问题。

- `Scopy/Utilities/AsyncBoundedQueue.swift`
  - 职责：可 backpressure 的 async queue，用于 bridging 到 `AsyncStream(unfolding:)`；避免 `.unbounded`。
  - 关注点：内部 `removeFirst` 为 O(n)，但容量上限小、可接受；取消路径考虑较完整。

- `Scopy/Utilities/ScopyLogger.swift` / `Scopy/Extensions/NSLock+Extensions.swift`
  - 职责：日志分类与锁 helper。
  - 关注点：未见明显问题。

### SwiftUI Frontend（App/UI）

#### App 入口与窗口

- `Scopy/main.swift`：显式入口（避免测试 target 启动 App）；静态审阅未见问题。
- `Scopy/ScopyApp.swift`：用隐藏 `MenuBarExtra` 满足 SwiftUI Scene 要求；静态审阅未见问题。
- `Scopy/AppDelegate.swift`：窗口/状态栏/设置窗/热键持久化的总控；关注点主要与 hotkey/Settings 生命周期相关（目前实现符合“关闭 settings 不退出应用”的约定）。
- `Scopy/FloatingPanel.swift`：面板定位（状态栏/鼠标位置）+ 失焦自动关闭；静态审阅未见明显问题。

#### Observables（State）

- `Scopy/Observables/AppState.swift`
  - 职责：service lifecycle；start 失败 fallback 到 mock；事件流 fan-out 到 view models；settingsChanged 时兜底重应用 hotkey。
  - 关注点：fallback 会先 `stopAndWait` 再替换 service（能缓解 P2-5 的半初始化）；未见明显资源泄漏。

- `Scopy/Observables/HistoryViewModel.swift`
  - 职责：load/search/paging/selection/keyboard nav；search debounce + fuzzy refine；与 performance metrics/Settings stats 联动。
  - 关注点：清空搜索/过滤的版本化与取消（P2-9）；首屏 load 时 stats 调用链导致重复目录遍历（P2-8）。

- `Scopy/Observables/SettingsViewModel.swift`
  - 职责：settings 读写；存储统计 refresh；diskSize TTL cache。
  - 关注点：首次 refresh 会触发 `getStorageStats` + `getDetailedStorageStats` 双重扫描（P2-8）。

- `Scopy/Observables/PerformanceMetrics.swift`
  - 职责：search/load latency 的滑动窗口采样与 UI 展示格式化。
  - 关注点：`ms==0` 的 N/A 与 sampleCount 的判断分离后更合理；未见明显问题。

#### Presentation / Design

- `Scopy/Presentation/ClipboardItemDisplayText.swift`
  - 职责：把 DTO 转成 UI title/metadata；用 NSCache 避免重复派生计算。
  - 关注点：cache key 采用 `type+contentHash`，能随内容变化自然失效；未见明显问题。

- `Scopy/Design/*`
  - 职责：设计 token（颜色/间距/字体/尺寸/图标/本地化格式）。
  - 关注点：整体符合“设计系统集中定义”的可维护方向；未见明显问题。

#### Views

- `Scopy/Views/ContentView.swift`
  - 职责：主界面容器 + 键盘快捷键（delete/clearAll/esc 等）。
  - 关注点：Esc 清空搜索时的双触发（P2-9 备注）；Clear All 对大库可能触发长时间清理（与 P2-10 相关，需 UI 侧给出反馈更佳）。

- `Scopy/Views/HeaderView.swift`
  - 职责：搜索框 + filter/menu。
  - 关注点：Clear 按钮同时 set query + 手动 `search()`，与 `onChange` 叠加（P2-9 备注）。

- `Scopy/Views/HistoryListView.swift` / `Scopy/Views/FooterView.swift`
  - 职责：虚拟列表与底部状态/动作区。
  - 关注点：List 视图回收是关键性能优化点（已落地）；未见明显正确性问题。

- `Scopy/Views/History/EmptyStateView.swift`：空态展示与引导入口；未见明显问题。
- `Scopy/Views/History/HistoryItemThumbnailView.swift`：列表缩略图懒加载（滚动时暂停加载）；未见明显问题。
- `Scopy/Views/History/HistoryItemImagePreviewView.swift`：图片 hover 预览（必要时滚动）；未见明显问题。
- `Scopy/Views/History/HistoryItemTextPreviewView.swift`：文本/Markdown hover 预览容器（WebView or TextView）；关注点主要与 `MarkdownPreviewWebViewController` 生命周期一致（P2-6 关联）。
- `Scopy/Views/History/HistoryItemView.swift`：单行渲染 + hover-preview 任务编排；关注 Markdown render 的 CPU cancel 细节（P3-5），以及 markdown controller 的创建/释放链路（P2-6）。
- `Scopy/Views/History/HoverPreviewModel.swift`：preview state model；未见明显问题。
- `Scopy/Views/History/HoverPreviewScreenMetrics.swift`：popover 屏幕约束与最大宽高；未见明显问题。
- `Scopy/Views/History/HoverPreviewTextSizing.swift`：TextKit 测量 + 大文本 fast-path；未见明显问题。
- `Scopy/Views/History/ListLiveScrollObserverView.swift`：List 滚动检测桥接；未见明显问题。
- `Scopy/Views/History/LoadMoreTriggerView.swift`：分页触底触发；未见明显问题。
- `Scopy/Views/History/SectionHeader.swift`：Pinned/Recent header 行；未见明显问题。
- `Scopy/Views/History/MarkdownPreviewCache.swift`：HTML cache；未见明显问题。
- `Scopy/Views/History/MarkdownPreviewWebView.swift`：WKWebView 承载 Markdown/KaTeX + 网络阻断 + size bridge；关注 `WKScriptMessageHandler` retain cycle（P2-6）；安全策略整体方向正确（禁外链/阻断网络/禁 HTML 渲染）。
- `Scopy/Views/History/MarkdownHTMLRenderer.swift`：Markdown→HTML（math 保护/KaTeX/禁 HTML/linkify=false）；属于高风险字符串管线，但已有较多回归测试护航。
- `Scopy/Views/History/MarkdownDetector.swift`：Markdown/Math heuristics；属于高回归风险区域（误判会触发更重渲染），目前实现较稳健。
- `Scopy/Views/History/MarkdownCodeSkipper.swift`：code segment 跳过策略；未见明显问题。
- `Scopy/Views/History/LaTeXDocumentNormalizer.swift` / `LaTeXInlineTextNormalizer.swift`：LaTeX→Markdown/inline 归一化；建议持续以真实样例回归测试防退化。
- `Scopy/Views/History/MathEnvironmentSupport.swift` / `MathNormalizer.swift` / `MathProtector.swift`：math delimiter/support + loose LaTeX 包裹 + protect/restore；属于正确性/安全关键组件，现有测试是重要护栏。

- `Scopy/Views/Settings/SettingsView.swift`：Save/Cancel 事务模型（isDirty）；符合仓库约定（非 autosave）。
- `Scopy/Views/Settings/SettingsPage.swift`：Settings sidebar 枚举与元数据；未见明显问题。
- `Scopy/Views/Settings/SettingsPageHeader.swift`：Settings page header 容器；未见明显问题。
- `Scopy/Views/Settings/SettingsComponents.swift`：Settings UI 组件；未见明显问题。
- `Scopy/Views/Settings/SettingsFeatureRow.swift`：Settings sidebar feature rows；未见明显问题。
- `Scopy/Views/Settings/GeneralSettingsPage.swift`：通用设置页；未见明显问题。
- `Scopy/Views/Settings/ShortcutsSettingsPage.swift`：快捷键设置页；未见明显问题（HotKey 录制回退逻辑另见 P3-7）。
- `Scopy/Views/Settings/ClipboardSettingsPage.swift`：内容类型设置页；未见明显问题。
- `Scopy/Views/Settings/AppearanceSettingsPage.swift`：缩略图/预览设置页；未见明显问题。
- `Scopy/Views/Settings/HotKeyRecorder.swift`：热键录制（local/global monitor）；未见明显问题（注意与 `HotKeyService` 的 unregister/applyHotKey 约定保持一致）。
- `Scopy/Views/Settings/HotKeyRecorderView.swift`：热键录制 UI；关注持久化读回的 time-based 同步方式（P3-7，低优先级）。
- `Scopy/Views/Settings/StorageSettingsPage.swift`：存储限制与占用展示；关注“内联存储上限”口径与用户直觉偏离（P3-1）。
- `Scopy/Views/Settings/AboutSettingsPage.swift` / `AppVersion.swift`：About/版本展示；未见明显问题。

### ScopyUISupport（Support Lib）

- `ScopyUISupport/IconService.swift`：app icon/name cache；静态审阅未见明显问题。
- `ScopyUISupport/ThumbnailCache.swift`：缩略图内存 cache + async load；滚动时延迟加载策略合理；静态审阅未见明显问题。

### Tests


#### Unit Tests（ScopyTests）

- `ScopyTests/AppStateTests.swift`：AppState/service fallback/事件流覆盖；未见明显问题。
- `ScopyTests/ClipboardMonitorTests.swift`：extract/hash/ingest 覆盖；关注 SHA256 测试向量缺口（P2-1）。
- `ScopyTests/ClipboardServiceCopyToClipboardTests.swift`：copyToClipboard 行为覆盖；未见明显问题。
- `ScopyTests/ConcurrencyTests.swift`：取消/超时/并发路径覆盖；未见明显问题。
- `ScopyTests/FTSQueryBuilderTests.swift`：FTS query 构造覆盖；未见明显问题。
- `ScopyTests/HotKeyServiceTests.swift`：热键录制/触发/节流覆盖；未见明显问题。
- `ScopyTests/HoverPreviewTextSizingTests.swift`：TextKit 测量回归；未见明显问题。
- `ScopyTests/IntegrationTests.swift`：端到端集成流覆盖；未见明显问题。
- `ScopyTests/KaTeXRenderToStringTests.swift`：预览渲染正确性回归；属于高价值测试资产。
- `ScopyTests/MarkdownMathRenderingTests.swift`：预览渲染正确性回归；属于高价值测试资产。
- `ScopyTests/MarkdownDetectorTests.swift`：预览渲染正确性回归；属于高价值测试资产。
- `ScopyTests/PerformanceProfilerTests.swift`：性能回归与 profiler 行为覆盖；未见明显问题。
- `ScopyTests/PerformanceTests.swift`：性能回归与 profiler 行为覆盖；未见明显问题。
- `ScopyTests/ResourceCleanupTests.swift`：清理/孤立文件回归；未见明显问题（并发上限属于实现侧问题，见 P2-7）。
- `ScopyTests/SearchBackendConsistencyTests.swift`：搜索一致性/分页/特殊字符覆盖；与 P1-2/P2-2/P2-3 的语义建议继续补齐。
- `ScopyTests/SearchServiceTests.swift`：SearchEngineImpl 直连测试；建议补一条“external content FTS 首次创建 + rebuild”覆盖（P3-6）。
- `ScopyTests/StorageServiceTests.swift`：存储/去重/清理覆盖；未见明显问题（Clear All 主线程删文件另见 P2-10）。
- `ScopyTests/TextMetricsTests.swift`：文本计数覆盖；未见明显问题。
- `ScopyTests/ThumbnailPipelineTests.swift`：缩略图链路覆盖；未见明显问题。
- `ScopyTests/Helpers/PerformanceHelpers.swift`：perf 测量与 SLO 校验 helper；未见明显问题（`getCurrentMemoryUsage` 使用 mach_task_basic_info）。
- `ScopyTests/Helpers/MockServices.swift`：可复用 mock service 与 mock storage；未见明显问题（Set→Array 顺序不保证，仅影响 UI 顺序断言时需留意）。
- `ScopyTests/Helpers/TestDataFactory.swift`：统一测试数据工厂；未见明显问题（hashValue 仅用于测试数据，避免用于跨进程一致性假设）。
- `ScopyTests/Helpers/XCTestExtensions.swift`：轮询等待 helper；建议更多场景复用以替代 sleep。

#### UI Tests（ScopyUITests）

- `ScopyUITests/MainWindowUITests.swift`：主窗口基本交互覆盖；未见明显问题。
- `ScopyUITests/HistoryListUITests.swift`：列表/搜索交互覆盖；关注固定 `Thread.sleep`（P3-4）。
- `ScopyUITests/KeyboardNavigationUITests.swift`：键盘导航覆盖；关注固定 `Thread.sleep`（P3-4）。
- `ScopyUITests/ContextMenuUITests.swift`：右键菜单覆盖；关注固定 `Thread.sleep`（P3-4）。
- `ScopyUITests/SettingsUITests.swift`：Settings 流程覆盖；未见明显问题（但同样建议减少 sleep 依赖）。
