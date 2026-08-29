---
doc_type: proposal
status: implemented
owner: hh
created: 2026-08-28
audience: implementing agent (Codex/GPT) + maintainer review
---

# Markdown 渲染硬化门槛：审查结论与落地方案

本方案是对当前工作区未提交改动（"Renderer Hardening Gate"波次）的完整代码审查、需求冻结与分阶段落地计划。实现者（GPT）按第 4 节顺序执行即可；第 1–3 节是口径与依据，第 6 节是实现方式与排版/字体细节的方向性约束（复刻方法论、五层渲染模型、排版 token 细则），遇到歧义以 `doc/current/markdown-chatgpt-wacz-style-contract.md`（canonical 契约）为准。

## 0. 一页纸总结

**What**：2026-08-28 的 WACZ 取证（Codex 会话）确定了 ChatGPT 真实渲染机制并被固化为 canonical 契约；v0.65.4 完成风格对齐、v0.70.0 完成交互式 rich 渲染。当前工作区存有一个约 1,700 行新增的未提交波次，包含五大支柱：safe-HTML 白名单子集、公共图片组适配器 + exact-URL 本地资产映射、原子资产契约、WebView 终态就绪/防白屏生命周期、数学结果计数与 authored 源直通修复。

**审查结论**：方向正确、工程质量高、fail-closed 设计一致、测试与文档同步完整。发现时唯一的硬阻塞是 renderer bundle 过期（`RENDERER_SOURCE_DRIFT`，缺少 `scopy-math-inline-host` 等最后一轮源码改动），导致 `make build` 在新资产门禁处失败——审查过程中已执行 `npm run build` 修复并使全部本地门禁转绿。

**Result（2026-08-28/29 实测）**：Node 契约测试 99/99；`verify:assets` 通过（KaTeX 0.16.45，60 字体，renderer sha256 `dc71d101…`）；`make build` 通过；`make test-unit` 与 `make test-strict` 均为 762 执行 / 2 跳过 / 0 失败；真实构建直接导出 safe-HTML 1080×1526、公共拷贝 1080×14534、69304px 超长 stress，均非空且无截断。公共拷贝与 stress 的输出和审查阶段已人工检查的 100% 证据逐字节一致。真实预览 harness 在 80%/100%/200% 首次打开均直接进入 `rendered`，100% 滚动后保持终态；18 组渲染探针（safe-HTML 嵌套/错配、注释、数学三态、exact-URL 图组、RTL/组合字符等）全部确定性且 fail-closed 正确。

**实现状态**：F2–F7 已按手术单完成，预览与导出运行时证据已补齐。macOS XCUITest 宿主仍在产品场景前报 `Application 'com.scopy.app' has not loaded accessibility`，因此相关 UI 套件如实记为 environment-blocked；同一 Debug 构建已通过不依赖 Accessibility 的真实应用自动导出与视觉层预览操作。发布收尾未获本次任务授权，未执行；版本建议仍是 v0.71.0。

## 1. 需求（冻结口径）

以下六条是本波次要交付的完整需求集，全部已有实现，验收标准见第 4 节。

- **R1 单链路 ChatGPT 对齐渲染**：预览与 PNG 导出消费同一 `MarkdownHTMLRenderer -> MarkdownHTMLDocumentBuilder` 产物；语义、排版、宽度、溢出策略遵守 canonical 契约；缺资产=可见失败，永不静默换引擎。
- **R2 封闭 safe-HTML 扩展**（用户要求的、有意的对 ChatGPT 全字面化的偏离，契约已标注为 Scopy 行为而非归档证据）：仅无属性成对 `u`/`kbd`/`mark`/`sub`/`sup` 与精确形态 `details`+非空 `summary` 进入受信 AST；完整注释隐藏；其余一切 HTML 字面化；`<script>` 永不成为元素。
- **R3 公共拷贝的确定性离线渲染**：≥2 个连续 image-only 段落复用 image-grid/lightbox 呈现，仅使用可见 `src`/`alt`/`title`；fixture 中两个精确 ChatGPT Search URL（全串精确匹配含 query）映射到打包本地图；其余远程图保持离线占位，绝不联网、绝不推断私有卡片。
- **R4 永不白屏/半渲染**：终态就绪 = renderer ∧ stylesheet ∧ `document.fonts` ∧ 全部本地图片终态 ∧ hydration ∧ 两帧 paint ∧ 当前 layout epoch；就绪前 SwiftUI shield 遮挡、WebView alpha=0；终态失败保留源文与原因（不空白、不需要二次 hover 修复）；缓存指标仅在精确 `layoutScalePercent` 下有效；resize/toggle 经 rAF 合并；导出对非终态 DOM 抛错（12s deadline）而非快照。
- **R5 原子资产契约为发布门禁**：renderer IIFE + sidecar + KaTeX CSS + 全部 CSS 引用字体 + `asset-manifest.json` 是一个由 `package-lock.json` 派生的整体；仓库内与最终 app bundle 内都要校验；bundle 根目录扁平重复资源 = 构建失败。
- **R6 数学可观测性与源直通**：`mathStrictCount`/`mathRelaxedCount`/`mathErrorCount` 来自真实渲染结果；authored/ChatGPT profile 的源字节直通 unified（MathProtector/LaTeX 归一仅在科学修复 profile 下运行）。

证据边界不变：WACZ 只证明代码路径/资源/文本存在；无 hydrated DOM、computed style、暗色、字体生效结论；本波次不新增任何像素级/暗色/live-Edge 声明。

## 2. 现状审查

### 2.1 五大支柱实现质量

| 支柱 | 核心文件 | 审查评价 |
| --- | --- | --- |
| safe-HTML | `Tools/MarkdownRenderer/src/remarkScopySafeHTML.js` + `test/safe-html.test.js`（13 测试） | 单遍栈式识别、深度上限 64、summary ≤4096、错配整段字面化、注释白名单精确（拒 `<!-->`/`--!>` 等）；handler 输出固定 className，sanitizer schema 按标签精确放行。fail-closed 彻底。 |
| 图片组适配器 | `remarkScopyImageGroups.js` + `scopyLocalImageAssets.js` | 仅 ≥2 连续 image-only 段落成组（≤12/组），仅保留 src/alt/title；exact-URL 表全串匹配（fixture 的 `\&` 经 CommonMark 反转义后与表键一致，已有测试钉死近似 URL 不命中）；BUNDLED_IMAGE_ASSETS 收敛为单一模块供 rich 与适配器共用。 |
| 原子资产契约 | `scripts/asset-contract.mjs`（核心）、`build.mjs`/`sync-katex-assets.mjs`/`verify-assets.mjs`、`asset-manifest.json`、Makefile 门禁、`project.yml` 改为 post-build staging、`build-release.sh` 校验最终 app 内资产并拒绝扁平重复 | 锁文件派生、字体集与 CSS 引用集恒等校验、原子写入、manifest 最后落盘。`make build/test*` 前置 `markdown-assets-verify`，发布走 `markdown-assets-gate`（含 `npm ci`）。设计闭环。 |
| 终态就绪生命周期 | `MarkdownHTMLDocumentBuilder.swift`（就绪运行时 JS）、`MarkdownPreviewWebView.swift`（alpha 门控、导航失败/进程终止处理、owner/renderID/callback 三元身份守卫投递）、`HoverPreviewModel.swift`（renderKey 生命周期）、`HistoryItemTextPreviewView.swift`（shield + 失败面）、`HistoryItemView.swift`（精确 scale 缓存写入） | 就绪合取 + 超时全部走可见失败（stylesheet 2.5s / fonts 3s / paint 1.5s watchdog）；`reportHeightNow` 在 renderComplete 前不发指标；generation-scoped ResizeObserver/toggle/keydown 合并上报；同 owner 终态失败不无限重试、新 owner 可重试。测试覆盖（WebViewLifecycleTests +154 行、HoverPreviewModelTests +83 行）到位。 |
| 数学 | `rehypeScopyKatex.js`（host 类 + 三档计数；relaxed 重试改 `throwOnError: true`，失败落到稳定 `.katex-error` 字面面）、`MarkdownHTMLRenderer.swift`（MathProtector 仅科学 profile 运行）、导出 `scaleWideMath`（display+inline 位图适配缩放） | 行为收敛正确：relaxed 只在真渲染成功时计数，坏公式统一走 Scopy 错误面。stress fixture 计数钉死 132=131+1+0。 |

导出宿主为 alpha=0.01 的在屏 NSPanel（`MarkdownExportService.swift:850` 起），rAF 可正常驱动两帧 paint 确认；预览侧仅 view alpha=0、窗口可见，同样不受节流影响。导出就绪轮询在 `renderFailed` 时提前抛错，不会傻等 12s。

### 2.2 审查中实测的验证状态

| 门禁 | 结果（2026-08-28，本机） |
| --- | --- |
| `npm test`（Tools/MarkdownRenderer） | 99/99 通过（含单行/独立块 `$$` 两条 F5 契约） |
| `npm run verify:assets` | 通过（katex 0.16.45 / 60 fonts / renderer `dc71d101…`）——修复 F1 后 |
| `make build`（Debug，含资产门禁） | 通过 |
| `make test-unit` | 762 执行 / 2 跳过 / 0 失败 |
| `make test-strict` | 762 执行 / 2 跳过 / 0 失败，TEST SUCCEEDED |
| 真实应用导出（标准 fixture） | ✅ 1080×4501，排版正确（2026-08-29 实测） |
| 真实应用导出（公共拷贝 fixture） | ✅ 1080×14534：本地映射图入三槽 search rail、display 数学居中、citation pill、表格列桶、单 `$` 字面——均经人工视觉核查 |
| 真实应用导出（2728 行 stress fixture） | ✅ 内容层面完整：1080×69304、顶部实测留白 34px、底部 76px、无截断；测试**断言**失败源于 F7（helper 方向互换），非渲染缺陷 |
| 真实应用导出（safe-HTML torture） | ✅ F6 修复后由同一 Debug 构建直接导出 1080×1526；正文、safe HTML、代码、表格、脚注与数学均有可见内容 |
| 真实应用导出（公共拷贝 / stress） | ✅ F2–F7 后分别为 1080×14534 / 1080×69304，且与此前人工检查的 100% PNG 逐字节一致 |
| 预览侧真实 harness | ✅ 80%/100%/200% 首开均直接为 `rendered`；100% 滚动两页后仍为 `rendered`。details toggle/高度上报及局部溢出由运行时与 Swift 契约测试覆盖 |
| XCUITest UI 套件 | environment-blocked：两个定向导出用例均在进入产品断言前被宿主的 `Application 'com.scopy.app' has not loaded accessibility` 拦截；未记通过、未无效重跑全套 |
| 线上 ChatGPT live 计量（Chrome） | environment-blocked：浏览器扩展未连接（两次尝试，2026-08-29） |

### 2.3 审查发现

- **F1（已修复，无需再做）**：checked-in bundle 落后于源码（缺 `scopy-math-inline-host`/新 KaTeX host 逻辑），`RENDERER_SOURCE_DRIFT` 使 `make build` 失败。审查中已重建（`npm run build`），bundle/sidecar/`katex.min.css`/manifest 现与源码、锁文件一致。教训已固化在门禁里：改 renderer 源码后必须 `npm run build`。
- **F2（已修复，文档一致性）**：`doc/current/markdown-chatgpt-wacz-style-contract.md` "KaTeX behavior" 第 2 条原写 relaxed 重试 `throwOnError: false`，与代码（`rehypeScopyKatex.js` 重试 `throwOnError: true`，失败 fall-through 到 `.katex-error`）不一致；现已修为 `strict: "ignore"`、`throwOnError: true`，并保留"Captured Runtime Pipeline"表中 ChatGPT 捕获行为（`throwOnError:false`）作为归档证据。
- **F3（已修复，死代码）**：已删除 `MarkdownRenderCacheKey.make(contentHash:markdown:)`；唯一测试调用方显式改用 canonical `MarkdownRenderContextResolver.defaultContext(for:)`，未增加兼容入口。
- **F4（已修复，验证证据）**：保留 `.gitignore` 的 `artifacts/render-validation/`，该目录已有 README 与真实导出/裁剪证据；runbook 已写明它是忽略的本地运行时证据而非 release artifact。
- **F5（已修复，契约精度）**：契约 Formula 表已拆为单行 `$$x$$`（inline）和独立多行块（display），Node 各新增一条断言；未改渲染器语义。
- **F6（已修复，UI 测试隔离）**：`defaultResolutionScale()` 在 `--uitesting` 且环境变量缺省时恒返回 1.0，绝不读取真实 UserDefaults；不设分辨率环境变量的同一 Debug 构建已直接导出 safe-HTML 1080×1526。
- **F7（已修复，测试坐标）**：`topWhitespaceRows` 从视觉顶部（内存第 0 行）向下扫，`bottomWhitespaceRows` 从视觉底部向上扫；阈值保持 top<72 / bottom<160 未放宽。新 stress PNG 与已测得 34px/76px 的旧 100% 输出逐字节一致。

**验证盲区**（2026-08-29 亲测后的剩余量）：

1. ~~12s 导出就绪 deadline 对超长文档足够~~ → **已实测通过**：stress fixture 在导出宿主中完成终态就绪并产出 1080×69304 完整 PNG，无截断、无空白段。
2. ~~公共拷贝 fixture 本地映射图与数学的导出表现~~ → **已实测通过**：见 §2.2 表；导出侧（离屏 NSPanel 宿主）的 rAF 两帧就绪确认随之得到实证。
3. ~~预览侧首次打开与滚动终态~~ → **已由真实 harness 验证**：80%/100%/200% 首开直接 `rendered`，100% 滚动后仍为 `rendered`；details toggle/高度上报、局部溢出和 scale-key 切换另有运行时/Swift 契约测试。XCUITest Accessibility 宿主仍 blocked，不冒充通过。
4. ~~F6/F7 修复后 safe-HTML torture 与 stress 真实导出~~ → **已通过无 Accessibility 依赖的真实应用路径**：1080×1526 / 1080×69304；XCUITest wrapper 在 `app.launch()` 阶段被系统 Accessibility 拦截，未进入产品断言。
5. **blocked**：线上 ChatGPT 完成态 computed-style 计量（Chrome 扩展未连接）；协议已在 §6.1 工具箱，不阻塞本门槛。

### 2.4 实现验收（2026-08-29）

- F2–F7 均按本方案的手术单落地，没有新增 renderer、fallback、feature flag、远程抓图或兼容层。
- Node：99/99；资产 source/bundle/manifest 校验通过；Debug app 内 KaTeX 0.16.45 / 60 fonts / renderer `dc71d101…`，Resources 根目录无 renderer 扁平重复。
- Swift：`make build` 通过；normal/strict 各 762 执行、2 跳过、0 失败；`WebViewLifecycleTests` 10/10、`HoverPreviewModelTests` 3/3。
- 真实应用：safe HTML、公共拷贝与超长 stress 三张新 PNG 已写入忽略目录；完整长图有持续内容，公共拷贝/stress 与前次人工核查输出逐字节一致。
- 真实预览：80%/100%/200% 首次打开均报告 `History.Preview.RenderStatus=rendered`；100% 连续滚动后仍为 `rendered`，无需移开再悬停。
- 环境边界：两个定向 XCUITest 在场景前因 Accessibility 未加载失败；同一可执行文件的直接导出与视觉层操作成功，故记录为 test-host environment-blocked，不记录为产品失败或 UI 套件通过。
- Phase 3 未执行：本次没有 commit/tag/push/release 授权。

## 3. 架构设计（确认并锁定）

### 3.1 单链路

```text
剪贴板 Markdown 源
  -> MarkdownSourceProfile 判定（authored / chatgpt / OCR-scientific / …）
  -> 有界语法感知归一（ATX 空格、表格行内 code-span pipe；科学 profile 才有 MathProtector + 宽松修复）
  -> MarkdownHTMLRenderer（唯一入口）
       -> 本地 unified/remark/rehype bundle（scopy-unified-renderer.iife.js）
            remarkScopyRich(严格 v2) -> remarkScopyImageGroups(公共图组适配)
            -> remarkScopyRichOrdinals -> remarkScopySafeHTML(白名单折叠)
            -> remarkLiteralHTML(其余全部字面化)
            -> remark-rehype(allowDangerousHtml:false + 显式 handlers)
            -> rehypeScopyKatex(HTML-only, strict->relaxed->error, 三档计数)
            -> rehype-sanitize(闭合 schema)
  -> MarkdownHTMLDocumentBuilder.document（CSS/本地资产/就绪运行时/指标脚本）
  -> 同一 standalone HTML
       -> MarkdownPreviewWebView(Controller)  预览：hydrate + 终态就绪 + alpha/shield 门控
       -> MarkdownExportService               导出：freeze + 位图适配 + PDF/快照策略
```

### 3.2 不变式（实现者不得破坏）

1. 一条链路：无 renderer selector、feature flag、shadow renderer、markdown-it fallback、第二套 export parser。
2. Fail-closed：无效 rich fence 保持代码块；不认识的 HTML 字面化；缺/坏资产 = 可见渲染失败；无效数学 = 字面错误面。禁止任何"降级成功"。
3. 原子资产：renderer 源码改动 ⇒ `npm run build`（重建 IIFE+sidecar+CSS+fonts+manifest）⇒ `npm run verify:assets`。永不手改 bundle/manifest。
4. WebView 单 owner + render ID 门：指标只被 (owner, renderID, renderKey/callbackID) 三元组匹配的当前投递接受；禁止隐藏预测量。
5. 缓存有效性含精确 layout scale 与 renderer 版本（`MarkdownRenderCacheKey` = `md|版本|profile|scale|hash`）。
6. 局部溢出：代码/表格/公式各自局部横滚，永不扩宽 popover/页面/PNG 画布。
7. 证据分档：任何新"ChatGPT 如此"结论必须给出 WACZ 代码路径或标注 live/runtime-derived；否则标 Scopy stability adaptation。
8. 仓库 7 条架构硬约束（不留向后兼容、最简实现、分层交付、模块化、成熟库优先、先查现有能力、按长期架构合入）适用于每一处修改。

### 3.3 关键取舍（为什么这样设计，勿反复）

- **safe-HTML 白名单 vs ChatGPT 全字面化**：ChatGPT 把 raw HTML 全部字面化（WACZ 证实）；Scopy 作为剪贴板管理器要渲染用户自己写的 `<details>`/`<kbd>` 等，故开一个**无属性、精确形态、fail-closed**的白名单，并在契约中明确标注这是用户要求的 Scopy 行为，不冒充归档证据。不扩白名单（`div`/`br`/`table` 等一律字面化）。
- **exact-URL 映射 vs 通用远程渲染**：只映射 fixture 里两个全串精确 URL 到打包资产，其余远程图一律离线占位。这是"跨机器确定性"的最小实现，不是远程抓取的开端；禁止扩展为模式匹配或按域放行。
- **就绪合取 vs 启发式高度**：旧方案"有非零高度就当可用"造成白屏/半渲染导出。新方案宁可失败可见（超时=失败+原因+源文），不做部分成功。导出同理：非终态就抛错。

## 4. 落地计划（按序执行）

### Phase 1 一致性与测试基建修复（小、必须、全部有手术单）

1. F2：修契约 KaTeX 第 2 条（`throwOnError: true` 口径），检查同文档无其他残留旧口径。
2. F3：删 `MarkdownRenderCacheKey.make(contentHash:markdown:)` 及因此失去调用者的辅助形态。
3. F4：按第 2.3 节决定处理 `artifacts/render-validation/`（推荐保留 + runbook 写明用途）。
4. F5：契约 Formula 表把 `$$...$$` 拆成单行（inline）与块形（display）两行；`render.test.js` 补两条钉死断言（单行 → `scopy-math-inline-host`；块形 → `katex-display`）。不改渲染器。
5. F6：`defaultResolutionScale()` 在 `--uitesting` 且分辨率环境变量缺省时恒返回 1.0，绝不读真实 UserDefaults。
6. F7：对调 `topWhitespaceRows` / `bottomWhitespaceRows` 的扫描方向并修正错误注释；阈值（top<72 / bottom<160）不动。
7. 回归：`cd Tools/MarkdownRenderer && npm test && npm run build && npm run verify:assets`；`make build && make test-unit && make test-strict`。全绿才进 Phase 2。

**完成定义**：上述命令零失败；`git diff` 只包含 F2–F7 的最小改动；且下述两个此前失败的用例重跑转绿：

```bash
xcodebuild test -project Scopy.xcodeproj -scheme Scopy \
  -only-testing:ScopyUITests/ExportMarkdownPNGUITests/testAutoExportSafeHTMLMarkdownUsesRenderedUnifiedPath \
  -only-testing:ScopyUITests/ExportMarkdownPNGUITests/testAutoExportUserMarkdownStressFixtureCompletesWithoutBlankOrTruncation
```

### Phase 2 预览侧运行时验证（导出侧已由本审查实测覆盖）

导出侧结论（2026-08-29 实测，PNG 证据在 `/tmp/scopy_uitest_export_*.png`，应收档至 `artifacts/render-validation/`）：标准 fixture、公共拷贝（本地映射图 + display 数学 + citation pill + 表格列桶）、69304px 超长 stress 均正确完成；导出宿主（离屏 NSPanel）的两帧 paint 就绪机制得到实证。剩余验证集中在**预览（hover popover）宿主**——它与导出宿主不同，rAF/就绪行为需独立确认：

1. 完整导出回归一次（确认 Phase 1 修复无连带回归）：

```bash
xcodebuild test -project Scopy.xcodeproj -scheme Scopy \
  -only-testing:ScopyUITests/ExportMarkdownPNGUITests \
  2>&1 | tee logs/uitest-export.log
```

   重点补跑本审查未覆盖的 `testAutoExportGlobalScalePDFDoesNotLeaveBlankRight` 与各分辨率用例。
2. Hover 生命周期 UI 场景：`-only-testing:ScopyUITests/HistoryItemViewUITests`（含新 `testLongMarkdownPreviewFirstOpenAndScrollStayTerminallyRendered`）。若 macOS automation 授权无法进入场景，如实记 `environment-blocked`，不得记通过。
3. 人工视觉检查一次（真实 Scopy.app）：复制 `chatgpt_public_copy_markdown_sample.md` 与含 safe-HTML/公式/宽表的样例 → hover 预览检查四项：无白屏首开、details 开合高度联动无闪烁、行内长公式局部滚动不扩宽 popover、80%→200% 拖动缩放稳定。截图收档 `artifacts/render-validation/`，结论记入 runbook 硬化门槛小节。
4. 若上述暴露假失败（如 paint/字体超时误伤），修复原则：调整该超时或该等待项的完成条件，**不得**移除失败可见性、不得恢复"非终态快照"兜底。

**完成定义**：导出套件全绿；hover 场景绿或如实 environment-blocked；预览四项现象人工确认并留档。

### Phase 3 发布收尾

1. 版本定 **v0.71.0**（功能级波次；若 hh 另有指示以其为准）。
2. 文档：`doc/meta/release-current.yml`（版本、日期、verification 各项如实填写，包括 blocked 项）＋ `doc/releases/history/v0.71.0.md`（按版本文档模板六段）＋ `doc/releases/README.md` ＋ `doc/releases/CHANGELOG.md`；runbook 把"Current Renderer Hardening Gate (unreleased)"改为该版本的正式小节并补 Phase 2 数据；本 proposal 状态改为 implemented（持久契约已在 canonical 文档，无需搬运）。
3. 门禁与发布：`make release-validate` → 单提交合入（含 bundle/manifest 产物）→ `make tag-release` → `make push-release` → 等 CI DMG/sha256 → cask 更新到同版本 → `brew fetch --cask scopy` 验证。
4. 无性能声明：本波次不改搜索/清理/滚动路径，`profile_doc: null`；不跑性能矩阵。

**完成定义**：CLAUDE.md 发布检查表全项通过；Homebrew 闭环验证完成。

## 5. 明确不做（out of scope，勿顺手实现）

- 暗色主题预览/导出（契约无暗色证据；需要新的 hydrated 捕获或 live 测量后另立提案）。
- 单张（非成组）图片的 exact-URL 本地映射；任何通用远程图片抓取或 URL 模式推断。
- CodeMirror 化代码卡、ChatGPT 的 Run/Preview 按钮、feature-flag 标题折叠（`<section><details>`）——非 Scopy 需求。
- 扩大 safe-HTML 白名单或给白名单元素放行任何 source 属性。
- merchant/product/map/entity 等新 rich 类型；v2 之外的 envelope 版本兼容。
- 第 49 节 `|r|` 类未转义 pipe 的"智能修复"——契约规定表格语义不由启发式改写，由源作者转义。

## 6. 实现方式与细节：方向性探索与约束

本节回答三个"怎么做"：怎么才算真正复刻官网效果、渲染应当被怎样理解与设计、排版字体的具体处理细则。全部以当前实现的真实符号为锚（文件与常量已逐一核实），实现者改动这些区域时以本节为方向约束。

### 6.1 复刻官网效果的方法论

"复刻"不是像素模仿，而是**四层保真 + 一张显式偏离表**。每层有自己的验收方式；不在偏离表里的差异都是缺陷。

| 层 | 含义 | 保真标准 | 验收方式 |
| --- | --- | --- | --- |
| 语义 | parser 对源文的解释 | 与捕获的 ChatGPT parser 配置**逐项等价**：`singleTilde:false`、`singleDollarTextMath:false`、raw HTML 字面化（Scopy 在其上加白名单）、未转义 pipe 分列、嵌套 fence、footnote | Node AST/HTML 断言（`render.test.js` 等） |
| 结构 | DOM 拓扑 | 与 ChatGPT 组件**同构而不必同名**：表格 container/wrapper 两层、KaTeX host（`role="math"`+`data-math-source`）、citation pill；类名允许 `scopy-*` | HTML 结构断言 + sanitizer schema |
| 视觉 | 排版常量 | 每个常量都能指回捕获 CSS 的 completed `.markdown.prose.markdown-new-styling` 路径（16/26、24/32、4px 节奏、bucket 阈值、40/48rem） | pinned CSS 字符串断言 + 真实 PNG 对照 |
| 行为 | 溢出/响应式/交互策略 | 正文任意断行、代码/表/公式局部横滚、页面永不横滚；响应式由**逻辑视口**驱动 | WebView metrics 测试 + 导出 UI 测试 |

**显式偏离表**（复刻的另一半是诚实记账；只能在此表增删，禁止隐式偏离）：

| 偏离 | 理由 |
| --- | --- |
| safe-HTML 白名单（ChatGPT 全字面化） | 用户要求；契约已标注为 Scopy 行为非归档证据 |
| highlight.js `detect:false` 替代 CodeMirror viewer | 离线静态预览无需编辑器基建；显式语言保证跨版本着色稳定 |
| KaTeX 0.16.45 替代捕获的 0.16.21 | 取上游修复；行为口径由 Scopy 自己的三档计数测试钉住，不依赖版本巧合 |
| 系统字体栈替代 OpenAI Sans | 归档不能证明正文实际使用 OpenAI Sans（初始 body 无 `data-type-stack`）；授权不明；确定性优先 |
| 全部 60 个 KaTeX 字体打包（归档仅 11 face 有字节） | 数学层不允许环境差异；避免异形公式（SansSerif/Script/Typewriter）回退 |
| 离线图片（exact-URL 映射 + 占位） | 永不联网是产品边界 |
| 无 Run/Preview 按钮、无 feature-flag 标题折叠、无暗色 | 非 Scopy 需求 / 无证据 |

**证据准入协议**（发现"不像官网"时的唯一流程）：先取证——WACZ 代码路径、或新的完整 hydrated 捕获、或标注 `live/runtime-derived` 的 DevTools 计量，三选一 → 写入契约（带证据档位）→ 改**一处** token → 钉 pinned 测试。禁止"看截图手调"。

**保真证据工具箱**（backlog，不属于本门槛；将来要提高保真上限时按此做）：
1. 完整捕获协议：等回答**完成后**用 DevTools 抓 Elements 全量 outerHTML + 逐 surface `getComputedStyle` 清单 + node screenshot——ArchiveWeb.page 的文本索引不含 hydrated DOM，是当前证据上限的根因。
2. 对照 harness：同一 Markdown 分别在 ChatGPT 网页与 Scopy 渲染，等逻辑宽度出 PNG 叠差；差异回到证据准入协议处理。
3. 每个 surface 固定的 computed-style 检查清单（字号/行高/margin/padding/颜色/字重），避免每次临时决定量什么。

### 6.2 渲染的理解与设计模型：五层权威

渲染链是五个层，每层恰好一个权威、一类测试；跨层修补是本项目最主要的腐化路径，禁止。

1. **语义层**（remark 插件 + 选项）：唯一决定"这段源文是什么"。语义只能在 AST 阶段决定；CSS、运行时 JS、Swift 后处理都不得改写语义。现有 `layoutChatGPTTables` 是合法样例——它只加包装容器与测量属性（`data-col-size`），不改行列结构；这就是"结构增强"与"语义改写"的分界。
2. **结构层**（rehype handlers + sanitizer）：受信 DOM 只能由 handler 产生；sanitizer 是闭合白名单，且"放行标签"永远绑定"固定 className/属性集"（如 `details` 仅 `["className","scopy-safe-details"]+open`）。新增受信元素 = handler + schema 条目 + 测试，三件套缺一不可。
3. **样式层**（一张 token 表）：全部排版常量是 `MarkdownHTMLDocumentBuilder.baseStyle` 里的 `--scopy-chatgpt-*` 变量（唯一定义点），组件规则只消费 token。禁止在组件规则里写裸常量复制品；改常量 = 改 token + 改契约 + 改 pinned 测试，三处同步。
4. **布局层**（逻辑视口）：`MarkdownRenderLayoutConstants` 固定 816px 输出面；逻辑视口 = `816 × (100/scale)`；`#content` 按逻辑宽排版后 `transform: scale()`，shell 预留放大后尺寸。rem 阈值（856px = 53.5rem 切 640→768px thread 宽）因此在任何缩放下语义一致，预览与 PNG 同构。禁止读物理 WKWebView 宽度做任何布局分支；宽内容唯一合法出口是局部横滚容器。
5. **时机层**（就绪合取 + 冻结）：预览 = hydrate、导出 = freeze，同一文档两种模式。就绪条件只能收紧不能放松；任何新的异步资源类型（新字体、新图片类别、新 hydration 步骤）必须并入 `awaitTerminalReadiness` 合取项，否则就是白屏窗口回归。

横切两条：**确定性**——同源 + 同 `MarkdownRenderContext` ⇒ 字节级相同 HTML；一切 ID 派生自源次序；每次加载唯一的只有 `data-scopy-render-id` 且它不参与结构语义。**失败面**——每层有自己的可见失败形态（parser→字面化/保持代码块，KaTeX→`.katex-error`，资产→render failure，WebView→terminal failure + 原因，导出→抛错），任何一层都不许把失败伪装成低配成功。

### 6.3 排版与字体处理细则

**字体分层决策**（每层的确定性等级不同，这是有意设计）：

- 正文/标题：macOS 系统栈（`-apple-system-body` 起，CJK 落 PingFang）。复刻目标定义为"**macOS 上的** ChatGPT"，接受跨机器字宽差异，换取零网络、零授权风险。
- 数学：打包 KaTeX 60 字体全集，字节级锁定（manifest 校验）。数学层**不允许任何**环境差异。
- 代码：`ui-monospace, SF Mono, Menlo…` 系统 mono 栈。
- 禁止：打包 OpenAI Sans；任何网络字体；因"归档里有字体文件"而推断正文应使用它。

**排版 token 核对表**（与实现逐一核实过；改动任何一项须走 6.1 证据准入协议）：

| Token | 值 | 备注 |
| --- | --- | --- |
| body | 16/26 · 400 | `--scopy-chatgpt-body-*` |
| h1 / h2 / h3 / h4 | 24/32 · 20/28 · 18/28 · 16/24，均 600 | h1 下 8px；h2/h3 上 16 下 4；h4 上 16 |
| 段落节奏 | 基础 4px；相邻 `p+p` 16px | 间距所有权见下 |
| 列表 | 26px 起始缩进；item 6px 起始 padding；marker 加粗 | |
| blockquote | 16/24；左 padding 24px、上下 8px；4px 伪元素竖条（圆角 2、上下内缩 8） | 不是 border-left |
| hr | 上下 28px | |
| inline code | 0.875em · 500 · padding 2.4/4.8px · 圆角 4 | 标题内同规则，无 h3 特例 |
| code card | 14/20 mono · 24px 圆角 · 语言标签 · `pre`+`max-content` | wrap 仅作导出位图适配 |
| table | 14/24，表头 600；列桶 >40 md、>100 lg、>160 xl（字符数） | 桶宽为 thread 宽度份额 |
| KaTeX host | 1.21em/1.2 · LTR isolate | 内部 strut/vlist 禁止覆盖 |

**间距所有权原则**：每个垂直间距恰好属于一个元素（例如相邻段落间距由 `p + p` 相邻选择器补足，而不是两个 p 各出一半）。新 surface 接入时先声明它挂在哪个节奏档；两个相邻元素同时出 margin 即视为缺陷。

**换行与多文种**：正文 `overflow-wrap: anywhere` + `word-break: normal`（长 token 有兜底断点、CJK 仍按正常规则断行，二者缺一不可，禁止换成 `break-word`/`break-all`）；容器 `dir="auto"` + 逻辑属性（`margin-inline`/`inset-block`），RTL 不写死左右；数字、ticker、公式 LTR isolate；字符不做 NFC 归一化，combining/emoji 逐字节保真，字形呈现交给 WebView。

**数学排版边界**：Scopy 与 KaTeX 的接口只有三个 host 类（`scopy-math-host` / `-inline-host` / `-display-host`）与 20em 几何上限；`.katex` 内部结构（strut、vlist、负 vertical-align 基线机制）是 KaTeX 私有实现，任何视觉问题都先怀疑 host 层，禁止给内部节点写样式补丁。行内公式局部横滚、display 公式居中上下 1em、导出侧 `scaleWideMath` 缩放——都作用于 host/容器层。

**缩放架构**：80–200%、5% 磁吸（`MarkdownChatGPTLayoutScalePercent`）；缩放改变的是逻辑视口（进而可能翻转 640/768 阈值），**不是**字号 token（`fontScale` 恒为 1，视觉放大由 transform 完成）；缓存 key、指标有效性、导出目标宽都含精确 scale。实现者不得引入第二种缩放机制（如改 root font-size 或 zoom 属性）。

## 7. 实现者护栏（每次改动前自检）

1. 改 `Tools/MarkdownRenderer/src/**` ⇒ 同步改 Node 测试 ⇒ `npm test && npm run build && npm run verify:assets`。
2. 改渲染语义 ⇒ 同步 `ScopyTests/ChatGPTMarkdownRendererTests.swift` 与相关 fixture 断言（fixture 字节精确：公共拷贝 fixture 不得引入尾随换行）。
3. 改 WebView/导出生命周期 ⇒ 跑 `make test-strict`；涉线程再加 `make test-tsan`。
4. 任何文档改动不得与 canonical 契约冲突；发现冲突旧文按"非规范历史材料"改正或删除，不留兼容表述。
5. 提交信息如实记录跑过/未跑的门禁及原因。
