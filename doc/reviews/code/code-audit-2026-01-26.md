# Scopy 代码审计报告（含 Swift 6 / Xcode 26 迁移核对）

**审计日期**：2026-01-26  
**审计目标**：可维护性/可扩展性/性能效率/稳定性与正确性 + Swift 6 / 新 SDK 迁移风险  
**审计范围**：全仓库（`Scopy/`、`ScopyTests/`、`ScopyUITests/`、`Tools/`、`scripts/`、`deploy.sh`、`Makefile`、`Casks/`、`doc/`）  
**当前版本**：`doc/implementation/README.md` 标注为 **v0.59.fix1**  
**代码基线**：`git rev-parse HEAD` = `22106ff2e2f20104051aa78647c82dec9ca629df`（本地存在未提交改动，见“前置说明”）  
**审计环境**：Xcode 26.2（17C52）/ Swift 6.2.3 / macOS 26.3（25D5101c）  

---

## 前置说明（重要）

1. **本次审计/修复基于当前工作区状态**：`git status` 显示存在已修改但未提交的文件（主要为 Swift 6/TSan/Makefile 修复与文档更新），因此本报告中的“编译/测试输出与告警”可能与主分支干净状态略有差异；具体改动见第 6 节。
2. 本报告前半部分提供问题清单与修复方向；**按你的后续要求，本次已实际落地修复（见第 6 节）**，并补齐验证与变更记录。

---

## 0. 结论摘要（可直接拿去排期）

### ✅ 现状结论

- **功能/架构总体成熟**：从实现文档与测试覆盖看，Scopy 已经进入“以正确性与性能回归为主”的阶段（大量回归测试 + 性能基线文档）。
- **在当前环境下可构建与多数测试通过**：`make build`、`make test-unit`、`make test-strict` 均通过。

### ⚠️ 主要风险（按优先级）

#### P0（会误导 CI/自动化 或 阻塞 Swift 6 迁移）

1. **Makefile 的测试命令会吞掉失败退出码**：`xcodebuild … | tee …` 未启用 `pipefail`，导致即使 `xcodebuild` 输出 `** TEST FAILED **`，`make` 仍返回成功（本次 `make test-tsan` 就出现该现象）。见 `Makefile:58`、`Makefile:71`、`Makefile:141`。
2. **Swift 6 迁移阻塞级告警（Strict Concurrency / Region Isolation）**：`make test-strict` 输出多处 “this is an error in the Swift 6 language mode”。集中在：
   - Markdown/WKWebView 相关（delegate 签名、MainActor 隔离、@Sendable 捕获）  
     `Scopy/Views/History/MarkdownPreviewWebView.swift:10`、`:225`、`:411`、`:574`、`:560-621`
   - 共享 cache 的并发安全  
     `Scopy/Views/History/MarkdownPreviewCache.swift:5`  
   - 继续使用非 Sendable 值跨并发边界（continuation / task group）  
     `Scopy/Views/History/MarkdownExportService.swift:1619`、`Scopy/Views/Settings/HotKeyRecorderView.swift:127`
3. **WebKit delegate 方法签名与新 SDK 声明不完全匹配**：`WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` 在新版 SDK 中带 `@MainActor`（且 `decisionHandler` 亦要求主 actor 语义）。当前实现触发“nearly matches optional requirement”告警，属于迁移高风险点（尤其是 Swift 6 模式下）。见 `Scopy/Views/History/MarkdownPreviewWebView.swift:225`、`:411`。

#### P1（TSan/并发正确性、迁移后更容易暴露）

1. **TSan 报告 1 个 data race**：发生在 `HistoryViewModel.loadedCount`（`HistoryViewModel.swift:499` 写）与测试轮询读取（`ScopyTests/SearchStateMachineTests.swift:119` 读）。详见 `logs/test-tsan.log` 中的 ThreadSanitizer 报告片段。
2. **TSan 下有 1 个测试因性能断言失败**：`ScopyTests/SearchServiceTests.swift:315`，在 TSan 开销下搜索耗时超过阈值（本次 123ms > 100ms）。这会导致 `test-tsan` 在某些机器/系统上“必然失败”，降低 TSan 作为并发回归手段的可用性。
3. **AVFoundation 弃用 API**：视频 natural size 计算仍在用同步 API（macOS 13 起弃用），建议切换到 `loadTracks` + `load(.naturalSize)` 等异步加载。见 `Scopy/Utilities/FilePreviewSupport.swift:175-176`。

#### P2（清洁度/可维护性）

- 一些“never mutated / unused value”类 warning，可作为低风险清理项：  
  `Scopy/Infrastructure/Settings/SettingsStore.swift:119`、`:131`、`Scopy/Views/History/HistoryItemFilePreviewView.swift:115`

---

## 1. 构建与测试证据（审计时 / 修复前）

> 说明：以下为本次在 **2026-01-26**（Xcode 26.2 / macOS 26.3）实际运行。

- ✅ `make build`：通过（Debug）。
- ✅ `make test-unit`：通过（`ScopyTests` 执行 266 tests，1 skipped，0 failures）。日志：`logs/test-unit.log`。
- ✅ `make test-strict`：通过（同样 266 tests，1 skipped，0 failures），但输出大量 Swift 6 迁移相关 warning。日志：`logs/strict-concurrency-test.log`。
- ❌ `make test-tsan`：`xcodebuild` 输出 `** TEST FAILED **`，且 ThreadSanitizer 报告 1 warning 并在结束阶段 abort；但 **Makefile 因 `tee` 吞退出码导致该目标整体返回成功**。日志：`logs/test-tsan.log`。

---

## 2. P0 - 构建/测试管线与 Swift 6 迁移阻塞项

### P0-1：Makefile 测试目标会吞掉 xcodebuild 的失败退出码

**证据**：

- `Makefile:62-68`、`Makefile:74-82` 等测试目标使用 `xcodebuild … 2>&1 | tee …`。
- 本次 `make test-tsan` 的 `logs/test-tsan.log` 明确包含 `** TEST FAILED **`，但 `make` 仍返回成功（因为 shell 的 pipeline 返回的是 `tee` 的退出码）。

**影响**：

- CI/自动化/本地脚本会把失败当成功（最危险的是“测试已挂但你以为绿了”）。
- 会直接破坏“验证闭环”，让回归不可依赖。

**建议修复方向**（不在本报告中改代码）：

- 方案 A（推荐，简单）：在 Makefile 里强制 `bash -o pipefail -c 'xcodebuild … | tee …'`。
- 方案 B：每个 pipeline 后显式检查 `${PIPESTATUS[0]}`（bash），或将日志重定向改为 `tee` 的进程替换方式。

---

### P0-2：Swift 6 / Xcode 26 严格并发诊断（会升级为编译错误）

**证据**：`logs/strict-concurrency-test.log` 中出现多条：

- “this is an error in the Swift 6 language mode”
- “main actor-isolated property … can not be referenced from a nonisolated context”
- “passing closure as a 'sending' parameter risks causing data races”

**高密度区域**：

#### (A) Markdown/WKWebView 预览链路

- `MarkdownPreviewCache.shared` 非 Sendable 的全局共享实例  
  `Scopy/Views/History/MarkdownPreviewCache.swift:5`
- `WKNavigationDelegate` method 签名/隔离域不匹配（见下一条 P0-3）  
  `Scopy/Views/History/MarkdownPreviewWebView.swift:225`、`:411`
- AppKit/WebKit API 在新 SDK 下被标注为 `@MainActor`：当前解析器/滚动视图遍历/滚动条隐藏器未标注主 actor，触发大量隔离告警  
  `Scopy/Views/History/MarkdownPreviewWebView.swift:10`、`:15`、`:25`、`:29`、`:32`、`:35`、`:560-621`、`:595-621`

#### (B) Export/设置相关的 Sendable/continuation/task group

- `withCheckedThrowingContinuation` 传递 `Any?`（非 Sendable）  
  `Scopy/Views/History/MarkdownExportService.swift:1619`
- `withTaskGroup.addTask` 捕获非 Sendable 的 `AsyncStream.Iterator`  
  `Scopy/Views/Settings/HotKeyRecorderView.swift:127`

#### (C) QuickLook 预览

- `QLPreviewView` 与 coordinator 未显式主 actor 隔离  
  `Scopy/Views/History/QuickLookPreviewView.swift:49`

#### (D) Tests（会影响 Swift 6 迁移）

- `@testable import Scopy` 但 target 依赖关系没有声明完整，触发 Xcode dependency scan 告警  
  `ScopyTests/ClipboardItemDisplayTextTests.swift:5` 等（见 `logs/strict-concurrency-test.log` 的 “missing dependency”）
- 非 MainActor 的测试在读写 `@MainActor` view model（Swift 6 下会更严格）  
  `ScopyTests/SearchStateMachineTests.swift:119`、`:129` + `ScopyTests/Helpers/XCTestExtensions.swift:8`

**影响**：

- 一旦切到 Swift 6 language mode（或启用更多 upcoming flags），这些 warning 会升级为 error，成为迁移阻塞。

**建议修复方向（迁移路线）**：

1. 先把 UI 相关 helper（滚动解析器、message parser、scrollbar hider、QuickLook coordinator）整体收敛到 `@MainActor`；
2. 再逐个解决 “sending parameter / non-Sendable capture / continuation value not Sendable”：
   - 对 `Any?` 返回值，改为“只返回可 Sendable 的具体类型”（例如 `Bool`/`Double`/`String`）或将函数标记为 `@MainActor` 并避免跨隔离域传递；
   - 对 `TaskGroup` 捕获 iterator 的逻辑，改成单任务 + 超时 `Task.sleep` 的结构，或将数据流改为 `AsyncSequence` 拉取的方式（避免把 iterator 放进并发任务）。
3. 统一修测试：将使用 `@MainActor` view model 的测试标注 `@MainActor`，或用 `await MainActor.run { … }` 访问/断言；并调整 `waitForCondition` 使其具备 MainActor 版本。

> 机制解释（为什么会出现 “sending”）可以参考 Swift Evolution 的 Region Based Isolation（SE-0414，Swift 6 实现）。  
> `swift-evolution://SE-0414`

---

### P0-3：WKNavigationDelegate 的声明已变化，当前实现触发 “nearly matches” 告警

**证据**：

- 编译告警：  
  `Scopy/Views/History/MarkdownPreviewWebView.swift:225`、`:411`
- Apple 文档声明（含 async 变体）：  
  `WKNavigationDelegate.webView(_:decidePolicyFor:decisionHandler:)` 为 `@MainActor`，并提供 `async -> WKNavigationActionPolicy` 版本（见 Apple doc）。  
  `apple-docs://webkit/documentation_webkit_wknavigationdelegate_webview_decidepolicyfor_decisionhandler_-2ni62_a8b05ef7`

**风险**：

- 迁移到更严格的 SDK/Swift 版本后，可能出现：
  - delegate 方法不被识别/不被调用（策略失效，安全与 UX 退化）
  - 或者由于隔离域不匹配导致新的并发诊断/行为变化

**建议修复方向**：

- 优先考虑切换到 **async 版** `decidePolicyFor`（能天然规避 completionHandler 的并发标注差异）；或将现有方法签名对齐新版声明（`@MainActor` + closure 的主 actor 语义）。

---

## 3. P1 - 并发正确性与 TSan 可用性问题

### P1-1：TSan 报告 data race（HistoryViewModel.loadedCount）

**证据**：`logs/test-tsan.log` 中 ThreadSanitizer 报告显示：

- 写：主线程，在 `HistoryViewModel.search()` 里更新 `loadedCount`  
  `Scopy/Observables/HistoryViewModel.swift:499`
- 读：GCD worker thread，在测试轮询条件里读取 `viewModel.loadedCount`  
  `ScopyTests/SearchStateMachineTests.swift:119`（通过 `ScopyTests/Helpers/XCTestExtensions.swift:8` 的 `waitForCondition`）

**影响**：

- 当前更像是“测试代码没有尊重 @MainActor 隔离”，但它暴露了一个事实：这类轮询/后台读取一旦出现在业务代码里，会成为真实数据竞争。

**建议修复方向**：

- 让 `waitForCondition` 提供 `@MainActor` 版本，或要求传入 `async` condition 并在内部 `await MainActor.run { … }`。
- 对 view model 的跨任务访问进行统一规范：UI 状态只能在 MainActor 访问，后台任务只能产出数据，通过 MainActor hop 回写。

---

### P1-2：TSan 下的性能断言导致 test-tsan 不稳定/易失败

**证据**：

- `ScopyTests/SearchServiceTests.swift:315`：`XCTAssertLessThan(result.searchTimeMs, 100, …)`  
  本次在 TSan 环境下耗时 123ms 导致失败。

**影响**：

- TSan 会显著放大开销；把“性能阈值断言”放进 TSan 套件，会让 `test-tsan` 失去作为并发回归的稳定信号。

**建议修复方向**：

- 在 `ScopyTSanTests`（`-DSCOPY_TSAN_TESTS`）下跳过该断言或放宽阈值；更推荐把性能阈值断言放在非 sanitizer 的 perf job 上跑。

---

### P1-3：TSan 结束阶段出现 IconRendering metallib “invalid format” 日志

**证据**：`logs/test-tsan.log` 末尾出现：

- `precondition failure: unable to load binary archive for shader library ... IconRendering.framework ... binary.metallib ... invalid format`

**研判**：

- 该类日志在 macOS Tahoe（26）上已有人报告为 WebKit/WKWebView 相关的系统层问题（见 WebKit bug）。  
  WebKit Bug 302212: “Unable to load binary archive for shader library … binary.metallib has an invalid format.”（2026-01-14）  
  - https://bugs.webkit.org/show_bug.cgi?id=302212

**建议**：

- 如果该日志仅在 TSan/某些系统版本出现，可视为系统噪声；但若在非 TSan 的正常运行也可复现，则需要进一步缩小触发路径（是否与 WKWebView 初始化/图标渲染有关）。

---

## 4. P1/P2 - API 弃用与可维护性清洁项

### P1：AVFoundation 视频轨道同步属性已弃用

**证据**：

- `Scopy/Utilities/FilePreviewSupport.swift:175-176`：  
  `tracks(withMediaType:)`、`naturalSize`、`preferredTransform` 在 macOS 13 起弃用（严格并发构建日志可见）。

**建议修复方向**：

- 使用异步 API：  
  `AVAsset.loadTracks(withMediaType:)`（macOS 12+）  
  `AVAsynchronousKeyValueLoading.load(_:)` 加载 `.naturalSize`/`.preferredTransform`  
  参考 Apple 文档：  
  `apple-docs://avfoundation/documentation_avfoundation_avasset_loadtracks_withmediatype_completionhandler_080b5b87`  
  `apple-docs://avfoundation/documentation_avfoundation_avasynchronouskeyvalueloading_load_isolation_6db3056c`

---

### P2：低风险 warning 清理（可合并到任意 refactor PR）

- `Scopy/Infrastructure/Settings/SettingsStore.swift:119`、`:131`：局部 `var` 未被修改，可改 `let`（减少噪音）。
- `Scopy/Views/History/HistoryItemFilePreviewView.swift:115`：未使用的 `filePath`。

---

## 5. 建议的修复顺序（不改代码的排期建议）

1. **先修 Makefile（P0）**：确保任何测试失败都能可靠地让 `make` 失败，恢复验证闭环。
2. **Swift 6 迁移收敛（P0）**：先集中处理 `MarkdownPreviewWebView.swift`/`MarkdownExportService.swift`/`HotKeyRecorderView.swift`/`QuickLookPreviewView.swift` 的主 actor/Sendable 问题，目标是 `make test-strict` 无 “Swift 6 language mode error” 类 warning。
3. **TSan 变得可用（P1）**：  
   - 跳过/放宽 TSan 下的性能断言；  
   - 修复/规避 data race（至少让 TSan 不再 abort）；  
   - 最后再验证是否仍会出现 IconRendering 相关系统日志。
4. **API 弃用清理（P1）**：FilePreviewSupport 的 AVFoundation 异步加载替换（顺带提升性能与未来兼容）。
5. **测试结构统一（P1/P2）**：减少 “ScopyTests 同时编译源码 + @testable import Scopy” 的混合形态，避免 Xcode dependency scan 告警演进为硬错误。

---

## 6. 修复落地与验证结果（2026-01-26）

> 本节记录“审计后”已经实际落地的改动与验证结果，目标是：**不改变既有功能语义**，仅修复工具链/迁移/并发稳定性问题。

### 6.1 已落地修复清单（对应前文风险项）

**P0：验证闭环 / Swift 6 迁移阻塞**

- ✅ Makefile：为所有 `xcodebuild … | tee …` 目标启用 `pipefail`，避免测试失败被误判为成功。参考：`Makefile:62`。
- ✅ Swift 6 Strict Concurrency：收敛 “this is an error in the Swift 6 language mode” 类阻塞告警（MainActor/Sendable/region isolation），覆盖 Markdown 预览与导出路径。参考：  
  - `Scopy/Views/History/MarkdownPreviewWebView.swift:236`  
  - `Scopy/Views/History/MarkdownPreviewWebView.swift:563`  
  - `Scopy/Views/History/MarkdownExportService.swift:1410`  
  - `Scopy/Views/Settings/HotKeyRecorderView.swift:74`  
  - `Scopy/Views/History/MarkdownPreviewCache.swift:6`

**P1：TSan 可用性 / 并发正确性**

- ✅ TSan data race：将测试轮询 helper 迁移到 MainActor，避免从后台线程直接读取 MainActor state。参考：`ScopyTests/Helpers/XCTestExtensions.swift:8`、`ScopyTests/SearchStateMachineTests.swift:119`。
- ✅ TSan 稳定性：在 `SCOPY_TSAN_TESTS` 下放宽一处性能阈值断言，避免 sanitizer 开销导致的误失败。参考：`ScopyTests/SearchServiceTests.swift:314`。

**P1：API 弃用**

- ✅ AVFoundation：替换弃用的同步 track 属性访问，使用 `loadTracks(withMediaType:)` + `load(.naturalSize/.preferredTransform)`。参考：`Scopy/Utilities/FilePreviewSupport.swift:172`。

**P2：低风险 warning**

- ✅ 清理一个 unused value warning（`HistoryItemFilePreviewView.swift`）。参考：`Scopy/Views/History/HistoryItemFilePreviewView.swift:115`。

### 6.2 修复后验证结果（本机）

- ✅ `make build`：**BUILD SUCCEEDED**（2026-01-26）
- ✅ `make test-unit`：Executed 266 tests, 1 skipped, 0 failures（2026-01-26）
- ✅ `make test-strict`：Executed 266 tests, 1 skipped, 0 failures（2026-01-26）
- ✅ `make test-tsan`：Executed 256 tests, 1 skipped, 0 failures（2026-01-26）

### 6.3 仍需关注（非阻塞）

- `IconRendering.framework … binary.metallib invalid format` 日志在 `make test-tsan` 结束阶段仍可能出现，但 `** TEST SUCCEEDED **`；目前倾向于系统噪声（WebKit/Metal），建议继续观察是否会在非 TSan 运行路径复现。参考：`logs/test-tsan.log`。
