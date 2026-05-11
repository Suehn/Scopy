# Markdown/LaTeX 渲染迁移蓝图

> 状态：实施前蓝图
> 目标：在尽量小影响的前提下，把 Scopy 的 Markdown + LaTeX 预览链路改造成边界清晰、可回滚、可验证、长期可演进的渲染体系。
> 输入资料：`doc/implementation/GPT-Pro-迁移md渲染.md`

## 1. 目标与判定标准

本迁移的核心目标不是“换一个 Markdown renderer”，而是解决当前管线里最危险的问题：**在 Markdown parser 之前对原始 Markdown 做全局 destructive transform**。这类 transform 会把 link、image、reference、code、HTML、URL、file path 等 Markdown syntax island 误当成 loose LaTeX，导致预览错乱。

成功标准：

1. 普通 authored Markdown 默认保语义，不被 loose LaTeX repair 改写。
2. ChatGPT/网页复制出来的 Markdown 能稳定渲染 link、file path、列表、表格、footnote、code、CJK emphasis。
3. 显式公式 `$...$`、`$$...$$`、`\(...\)`、`\[...\]` 稳定渲染，不被 Markdown emphasis 拆坏。
4. PDF/OCR/富文本复制出来的 loose LaTeX 仍可修复，但只能在明确允许的 source profile 中运行。
5. preview、file preview、PNG export 继续消费同一种 HTML 文档，避免预览与导出分叉。
6. 所有阶段都能通过 feature flag/cache namespace 回滚，不污染旧缓存。
7. 每个迁移阶段都有 focused tests、unit gates 和必要的性能/导出验收。

非目标：

1. 不把 Scopy 变成完整 LaTeX 编译器。
2. 不默认引入 Pandoc/Quarto/Mathpix 作为 hover preview 主路径。
3. 不为了 unified 一次性移除现有 markdown-it/KaTeX 体系。
4. 不为了 loose LaTeX repair 牺牲 Markdown 原文语义。

## 2. 当前链路事实

当前渲染入口在 `MarkdownHTMLRenderer.render(markdown:)`。它按以下顺序处理：

```text
raw markdown
-> LaTeXDocumentNormalizer.normalize
-> MathNormalizer.wrapLooseLaTeX
-> MathProtector.protectMath
-> LaTeXInlineTextNormalizer.normalize
-> normalizeATXHeadings
-> MarkdownCJKEmphasisNormalizer
-> MarkdownSafeHTMLSubset.extract
-> markdown-it in WKWebView
-> restore math placeholders
-> apply safe HTML replacements
-> KaTeX auto-render
```

关键证据：

| 事实 | 证据 |
| --- | --- |
| `wrapLooseLaTeX` 在 markdown-it 前全局运行 | `Scopy/Views/History/MarkdownHTMLRenderer.swift:7` 到 `Scopy/Views/History/MarkdownHTMLRenderer.swift:11` |
| markdown-it 在 WebView 内运行，Swift 只生成 HTML shell | `Scopy/Views/History/MarkdownHTMLRenderer.swift:877` 到 `Scopy/Views/History/MarkdownHTMLRenderer.swift:895` |
| KaTeX 当前通过 `window.__scopyRenderMath()` 扫 DOM | `Scopy/Views/History/MarkdownHTMLRenderer.swift:915` 到 `Scopy/Views/History/MarkdownHTMLRenderer.swift:917` |
| Markdown feature set 包含 linkify、breaks、table、footnote、deflist、highlight、math | `Scopy/Views/History/MarkdownRenderFeatureSet.swift:17` 到 `Scopy/Views/History/MarkdownRenderFeatureSet.swift:30` |
| hover preview cache 当前按 `contentHash` 取 HTML/metrics | `Scopy/Views/History/HistoryHoverPreviewPipeline.swift:539` 到 `Scopy/Views/History/HistoryHoverPreviewPipeline.swift:565` |
| markdown render 性能指标写入 `hover.markdown_render_ms` | `Scopy/Views/History/HistoryHoverPreviewPipeline.swift:618` 到 `Scopy/Views/History/HistoryHoverPreviewPipeline.swift:628` |
| WebView 使用 non-persistent store 并阻断 http/https | `Scopy/Views/History/MarkdownPreviewWebView.swift:180` 到 `Scopy/Views/History/MarkdownPreviewWebView.swift:187` |
| WebView link navigation 只允许同文档 fragment | `Scopy/Views/History/MarkdownPreviewWebView.swift:108` 到 `Scopy/Views/History/MarkdownPreviewWebView.swift:123` |
| MarkdownPreview assets 已通过 project.yml stage 到 app bundle | `project.yml:138` 到 `project.yml:158` |
| Export 只消费完整 HTML，不关心 HTML 来自哪个 renderer | `Scopy/Services/Export/MarkdownExportService.swift:52` 到 `Scopy/Services/Export/MarkdownExportService.swift:60` |

现有 stopgap 已经能避免 inline link destination `(...path...)` 被括号公式误包，但它不是结构性方案。结构性问题仍然存在：`MathNormalizer` 仍会在 Markdown parser 前扫描普通文本段，当前只知道 code fence/inline code，不知道 link/image/reference/html/path 这些 Markdown 语义边界。

## 3. 根因分类

当前 bug 属于“预处理边界错误”，不是单纯 renderer bug。

| 层级 | 当前问题 | 正确边界 |
| --- | --- | --- |
| clipboard extraction | rich/plain text 可能来自 HTML、RTF、ChatGPT、PDF、KaTeX DOM | 只负责尽量保真提取，不决定 repair policy |
| Markdown detection | `isLikelyMarkdown` 同时被 math/LaTeX 信号触发 | 只能决定是否进入 Markdown preview，不能决定是否允许 loose repair |
| source profile | 当前缺失 | 决定 authored Markdown、ChatGPT Markdown、LaTeX doc、PDF/OCR scientific 等策略 |
| loose repair | 当前全局运行 | 只能在允许 profile 的未保护 text segment 运行 |
| syntax island | 当前只保护 code | 必须保护 link、image、reference、definition、autolink、HTML、URL/path |
| renderer | markdown-it 与 KaTeX auto-render 混在 HTML shell 中 | 短期保留，长期抽象为 legacy/unified renderer |
| cache | 当前只按 contentHash 缓存 | 必须包含 renderer kind、profile、policy version |

结论：**Scopy 不缺 Markdown renderer，缺的是明确的 render context 和 transform ownership。**

## 4. 目标架构

目标架构采用 profile + policy + renderer abstraction。默认优先保 Markdown 语义，只有 source profile 明确时才启用 destructive repair。

```text
clipboard/plain source
-> MarkdownSourceProfileDetector
-> MarkdownRenderContext
-> MarkdownSyntaxProtector
-> profile-gated LaTeXDocumentNormalizer
-> profile-gated loose math repair
-> restore syntax islands
-> explicit math protection/parser
-> renderer facade
-> sanitized/local HTML document
-> WKWebView preview / PNG export
```

### 4.1 Source Profile

建议 profile：

| Profile | 典型来源 | 默认策略 |
| --- | --- | --- |
| `authoredMarkdown` | 手写 Markdown、README、笔记 | 禁用 loose repair，仅处理显式 math |
| `chatGPTMarkdown` | ChatGPT/Codex 输出、带 file link 的答案 | 禁用 loose repair，优先保护链接和代码 |
| `scientificMarkdown` | Markdown 科学笔记、显式公式较多 | 禁用 destructive repair，可启用显式 math 和 AMS env |
| `latexDocumentLike` | `\documentclass`、`\section`、`\begin{document}` | 允许 LaTeX document normalize，谨慎 repair |
| `pdfOCRScientific` | PDF/OCR/论文复制，公式 delimiter 缺失 | 允许 loose repair，但阈值最高、保护最多 |
| `richHTML` | HTML/RTF 提取文本，可能含 details/kbd/sub/sup | 禁用 loose repair，保 safe HTML subset |
| `plainTextUnknown` | 普通纯文本 | 默认禁用 loose repair，除非检测强科学文本 |

### 4.2 Repair Policy

`MarkdownDetector.isLikelyMarkdown` 不应继续承担读取策略。新增 policy：

```swift
enum MarkdownRendererKind: String {
    case legacyMarkdownIt
    case unified
}

enum MarkdownSourceProfile: String {
    case authoredMarkdown
    case chatGPTMarkdown
    case scientificMarkdown
    case latexDocumentLike
    case pdfOCRScientific
    case richHTML
    case plainTextUnknown
}

struct MarkdownRepairPolicy: Equatable {
    let allowLatexDocumentNormalize: Bool
    let allowLatexInlineTextNormalize: Bool
    let allowExplicitMath: Bool
    let allowBackslashMath: Bool
    let allowLooseMathRepair: Bool
    let allowSafeHTMLSubset: Bool
    let allowRawHTML: Bool
}

struct MarkdownRenderContext: Equatable {
    let renderer: MarkdownRendererKind
    let profile: MarkdownSourceProfile
    let policy: MarkdownRepairPolicy
    let policyVersion: String
    let cacheNamespace: String
}
```

默认 policy：

| Profile | document normalize | inline text normalize | explicit math | backslash math | loose repair | safe HTML subset | raw HTML |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `authoredMarkdown` | false | false | true | true | false | true | false |
| `chatGPTMarkdown` | false | false | true | true | false | true | false |
| `scientificMarkdown` | false | true | true | true | false | true | false |
| `latexDocumentLike` | true | true | true | true | true | true | false |
| `pdfOCRScientific` | true | true | true | true | true | true | false |
| `richHTML` | false | false | true | true | false | true | false |
| `plainTextUnknown` | false | false | true | true | false | true | false |

原则：**loose repair 默认关闭，显式 math 默认开启。**

### 4.3 Renderer Abstraction

新增 facade，避免 UI 层知道 legacy/unified 细节：

```swift
protocol MarkdownPreviewRenderer {
    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput
}

struct MarkdownRenderOutput: Equatable {
    let html: String
    let diagnostics: MarkdownRenderDiagnostics
}

struct MarkdownRenderDiagnostics: Equatable {
    let renderer: MarkdownRendererKind
    let profile: MarkdownSourceProfile
    let repairedMathCount: Int
    let protectedIslandCount: Int
    let warnings: [String]
}
```

早期可以让 `MarkdownHTMLRenderer.render(markdown:)` 继续存在，内部转调 legacy facade，降低调用点改动。

### 4.4 成熟方案取舍

迁移应借鉴成熟方案的边界设计，而不是直接整包替换。

| 方案 | 定位 | 是否进入默认 preview 主线 | 取舍 |
| --- | --- | ---: | --- |
| 当前 markdown-it 路径 | 现有 production renderer | 短期保留 | 改动小、风险低，但字符串预处理边界需要补强 |
| unified / remark / rehype | 中期 AST renderer | 是，先 shadow 再切 safe profiles | AST node 边界最适合解决 link/code/path 被 repair 误伤 |
| markdown-it-texmath / dollarmath | markdown-it 显式 math 插件 | 可做短期参考，不作为根修复 | 能改善 delimiter parsing，但不解决 source profile 和 syntax island |
| Pandoc / Quarto | 长文档 publishing/export | 不作为 hover preview 默认路径 | 能力强但重，binary/sandbox/延迟/行为差异都不适合默认 hover |
| MyST Markdown | scientific Markdown dialect | 不默认采用，可借鉴 profile 设计 | 适合科学写作，但 Scopy 不能默认把普通剪贴板文本解释成 MyST |
| Mathpix Markdown | STEM/OCR Markdown 超集 | 不默认采用 | 对 OCR/公式很强，但过度解释普通 Markdown/路径/网页文本的风险高 |
| MathJax | 浏览器公式渲染 | 不作为主线替换 KaTeX | 功能强但重；当前本地 KaTeX 资源与 export 链路已经稳定 |

决策：**默认 preview 继续轻量、本地、可缓存；高级 publishing/export 能力可以作为未来独立路线，不和 hover preview 主线绑定。**

## 5. 分阶段迁移方案

### Phase 0：冻结基线与语料

目的：在任何进一步修改前，把当前行为和风险样例固定下来。

实施内容：

1. 整理 `ScopyTests/Fixtures/MarkdownRenderingCorpus/`。
2. 收集至少 8 类输入：ChatGPT file links、local path、image path、reference link、explicit math、loose LaTeX、currency/shell vars、CJK mixed Markdown。
3. 为 corpus 记录预期：是否允许 repair、是否应有 KaTeX、是否应保留原始 link/path、是否允许 raw HTML。
4. 新增一个轻量 corpus runner，用同一批样例跑 `MathNormalizer`、`MarkdownHTMLRenderer`、后续 unified renderer。

验收：

```text
make build
make test-unit
```

风险：

如果没有先冻结 corpus，后续 unified 迁移会变成“看起来能渲染”，但无法判断是否悄悄改变了 Markdown 语义。

### Phase 1：Legacy Stopgap Hardening

目的：在现有 markdown-it 路径内先止血，不引入新 renderer。

实施内容：

1. 在 `MathNormalizer.shouldWrapAsMath` 增加 path/url/currency hard reject。
2. 覆盖 `/Users/`、`~/`、`./`、`../`、`file://`、`mailto:`、`.md:25`、图片/pdf 扩展名、URL query、slash-heavy path。
3. 保留当前 inline link destination stopgap，但明确它只是防线之一。
4. 增加 image/reference/path/currency regression。

新增测试：

```text
[open](/Users/alice/my_file_v2.md:25)
![img](/Users/alice/Pictures/img(1)_v2.png)
[paper]: /Users/alice/papers/file_v2.md:25 "title"
[x_i](/Users/alice/file.md:25)
[price](https://example.com/a_(b)?q=x_y&price=$20) costs $20.
[打开](/Users/王小明/论文/第1章_v2.md:25)
```

验收：

```text
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/MarkdownMathRenderingTests
make build
make test-unit
```

回滚：

只回滚 `MathNormalizer` hard reject 和测试，不影响 renderer。

### Phase 2：MarkdownSyntaxProtector

目的：从根上阻止 loose repair 触碰 Markdown syntax island。

新增文件：

```text
Scopy/Views/History/MarkdownSyntaxProtector.swift
ScopyTests/MarkdownSyntaxProtectorTests.swift
```

API 草案：

```swift
struct MarkdownSyntaxProtectionResult {
    let markdown: String
    let placeholders: [(placeholder: String, original: String, kind: MarkdownSyntaxIslandKind)]
}

enum MarkdownSyntaxIslandKind {
    case fencedCode
    case inlineCode
    case inlineLink
    case image
    case referenceLink
    case shortcutReference
    case referenceDefinition
    case autolink
    case safeHTML
    case url
    case filePath
}

enum MarkdownSyntaxProtector {
    static func protectForLooseMathRepair(_ markdown: String) -> MarkdownSyntaxProtectionResult
    static func restore(_ markdown: String, placeholders: [(placeholder: String, original: String, kind: MarkdownSyntaxIslandKind)]) -> String
}
```

保护优先级：

1. fenced code
2. inline code
3. image
4. inline link
5. reference definition
6. reference/full/shortcut link
7. autolink
8. safe/raw HTML spans
9. bare URL/local file path

关键决策：

应保护整个 `[label](dest)`，不是只保护 `dest`。原因是 `MathNormalizer` 也会处理 `[...]`，link label `[x_i]` 也可能被误判为 square bracket math。

Legacy pipeline 改造为：

```text
raw markdown
-> context/profile
-> syntax protect
-> optional LaTeXDocumentNormalizer
-> optional MathNormalizer.wrapLooseLaTeX
-> syntax restore
-> MathProtector
-> rest of legacy pipeline
```

验收：

```text
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/MarkdownSyntaxProtectorTests
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/MarkdownMathRenderingTests
make build
make test-unit
```

### Phase 3：Source Profile + Policy

目的：把“是否 Markdown”和“是否允许 repair”拆开。

新增文件：

```text
Scopy/Views/History/MarkdownRenderContext.swift
Scopy/Views/History/MarkdownSourceProfileDetector.swift
ScopyTests/MarkdownSourceProfileDetectorTests.swift
```

Profile detector 输入应尽量包含：

| 输入 | 来源 |
| --- | --- |
| source text | `ClipboardItemDTO.plainText` |
| item type | `.text`、`.rtf`、`.html`、`.file` |
| app bundle id | 未来可用于 ChatGPT/browser profile，但第一版不要硬依赖 |
| rich extraction signal | HTML/RTF 是否 TeX-heavy，后续可从 ingest diagnostics 补 |

第一版可以只从 text heuristic 推断，不改存储 schema。后续如果需要更精确，再把 Clipboard ingest diagnostics 持久化。

Profile heuristic 初版：

| 条件 | Profile |
| --- | --- |
| `\documentclass` 或 `\begin{document}` | `latexDocumentLike` |
| 大量 `\section`、`\begin{equation}`、`\begin{tabular}` | `latexDocumentLike` |
| Markdown link/code/list 密度高，且包含 ChatGPT 风格 local file links | `chatGPTMarkdown` |
| GFM 表格、列表、heading、code fence 明显 | `authoredMarkdown` |
| TeX command 密度高、delimiter 缺失、短行/碎片多 | `pdfOCRScientific` |
| HTML subset tag 明显 | `richHTML` |
| 其他 | `plainTextUnknown` |

迁移要点：

1. `MarkdownDetector.isLikelyMarkdown` 保持轻量，继续决定是否进入 preview。
2. `MarkdownSourceProfileDetector` 只在 render 阶段决定 policy。
3. `HistoryItemPresentationCache` 仍可缓存 `isMarkdown`，不要缓存 repair policy，避免 profile 策略升级后旧状态不刷新。

验收：

```text
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/MarkdownDetectorTests
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/MarkdownSourceProfileDetectorTests
make build
make test-unit
```

### Phase 4：Renderer Abstraction + Cache Namespace

目的：让 legacy 和 unified 能并行存在，并避免缓存污染。

改造点：

1. 新增 `MarkdownPreviewRenderer` facade。
2. 保留 `MarkdownHTMLRenderer.render(markdown:)` 作为兼容入口。
3. `HistoryHoverPreviewPipeline.MarkdownRenderRequest` 增加 `context`。
4. `MarkdownPreviewCache` key 增加 renderer/profile/policy version。
5. file preview cache 同样区分 renderer output。

Cache key 建议：

```text
md|<renderer>|<cacheNamespace>|<profile>|<policyVersion>|<contentHash>
```

示例：

```text
md|legacyMarkdownIt|v1|chatGPTMarkdown|policy1|<hash>
md|unified|v1|chatGPTMarkdown|policy1|<hash>
```

风险：

如果 cache key 不包含 renderer/profile/policy，shadow renderer 切换时会复用 legacy HTML，导致误判迁移质量。

验收：

```text
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/HistoryHoverPreviewPipelineTests
make build
make test-unit
```

### Phase 5：Unified Shadow Renderer

目的：引入 unified/remark/rehype，但不影响用户默认路径。

目录建议：

```text
Tools/MarkdownRenderer/
  package.json
  tsconfig.json
  src/
    index.ts
    scopyPolicy.ts
    remarkScopyBackslashMath.ts
    remarkScopyLooseMathRepair.ts
    rehypeScopySafeHTML.ts
  test/
    corpus/
Scopy/Resources/MarkdownPreview/scopy-unified-renderer.iife.js
```

技术栈建议：

```text
unified
remark-parse
remark-gfm
remark-breaks
remark-math
custom micromark extension for \( ... \) and \[ ... \]
remark-rehype
rehype-sanitize
rehype-katex
rehype-stringify
```

注意：

1. `remark-math` 主要覆盖 dollar math，Scopy 仍需要 `\(...\)` / `\[...\]`。
2. `\(...\)` / `\[...\]` 最好用 micromark extension，不要在 parsed text node 后补救，否则 CommonMark backslash escape 可能已经改变原始文本。
3. 第一版 unified renderer 只做 shadow render，输出 diagnostics，不进入 UI。
4. bundle 必须本地化，放入 `Scopy/Resources/MarkdownPreview`，继续由 `project.yml` stage。

WebView API 草案：

```ts
window.ScopyUnifiedMarkdown = {
  render(source: string, policy: ScopyRenderPolicy): {
    html: string;
    metadata: {
      mathCount: number;
      repairedMathCount: number;
      warnings: string[];
    };
  }
};
```

验收：

```text
npm test --prefix Tools/MarkdownRenderer
npm run build --prefix Tools/MarkdownRenderer
make build
make test-unit
```

如果仓库暂不接受 Node build 作为默认依赖，则先把 bundle 作为 vendored asset 提交，并用显式脚本更新。

### Phase 6：Safe Profile Cutover

目的：只把低风险 profile 切到 unified。

第一批切换：

| Profile | 原因 |
| --- | --- |
| `authoredMarkdown` | 主要是标准 Markdown，AST renderer 风险最低 |
| `chatGPTMarkdown` | 当前 bug 主要来自这类输入，link/code/path 保护收益最大 |
| plain Markdown file preview | 输入较规范，便于 corpus 对比 |

继续保留 legacy：

| Profile | 原因 |
| --- | --- |
| `latexDocumentLike` | 依赖现有 LaTeXDocumentNormalizer 能力 |
| `pdfOCRScientific` | loose repair 行为复杂，先不迁 |
| `richHTML` | safe HTML subset 需要完全等价后再迁 |
| `plainTextUnknown` | 避免普通文本被过度解释 |

切换策略：

1. 默认隐藏 feature flag：`MarkdownRendererKind.defaultForProfile(profile)`。
2. 支持 runtime fallback：unified render 失败、空 HTML、diagnostics fatal 时自动走 legacy。
3. 记录 diagnostics 到 debug log/perf profile，不暴露给普通 UI。

验收：

```text
make build
make test-unit
make perf-frontend-profile
```

需要检查：

1. hover 初次显示延迟。
2. `hover.markdown_render_ms` p95。
3. WebView height report 是否稳定。
4. footnote anchor、task list、table overflow、CJK emphasis 是否退化。
5. export PNG 是否仍使用同一 HTML shell。

### Phase 7：AST Loose Repair

目的：把 loose LaTeX repair 从 Swift 全局字符串扫描迁移到 AST text node plugin。

新增 unified plugin：

```text
remarkScopyLooseMathRepair
```

核心规则：

```ts
visitParents(tree, "text", (node, ancestors) => {
  if (!policy.allowLooseMathRepair) return;
  if (ancestors.some(isProtectedAncestor)) return;

  const candidates = detectLooseMathCandidates(node.value, {
    rejectURL: true,
    rejectFilePath: true,
    rejectCurrency: true,
    rejectCJKHeavyText: true,
    profile,
  });

  replaceTextNodeWithTextAndMathNodes(node, candidates);
});
```

Protected ancestors：

```text
link
image
definition
code
inlineCode
html
footnoteDefinition
footnoteReference
table
```

迁移规则：

1. 先只对 `pdfOCRScientific` shadow render。
2. 对比 Swift `MathNormalizer` 输出和 AST plugin 输出。
3. 对“应该不同”的行为做显式记录，例如 AST plugin 不应修 link label/destination。
4. 逐步把 `latexDocumentLike` / `pdfOCRScientific` 切到 unified。

验收：

```text
npm test --prefix Tools/MarkdownRenderer
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/MarkdownMathRenderingTests
xcodebuild test -scheme Scopy -destination 'platform=macOS' -only-testing:ScopyTests/KaTeXRenderToStringTests
make build
make test-unit
make perf-frontend-profile-standard
```

### Phase 4-7 中阶段实现详案：从 legacy 到 unified renderer replacement

这一段是后续实现的主蓝图。目标不是只“引入一个 unified 包”，而是把 renderer 从当前单体 `MarkdownHTMLRenderer` 替换成可并行、可回滚、可观测的 renderer pipeline。

中阶段完成后的目标状态：

```text
HistoryHoverPreviewPipeline / Export Controller
-> MarkdownRenderContextResolver
-> MarkdownPreviewRendererFacade
   -> LegacyMarkdownItRenderer
   -> UnifiedMarkdownRenderer
   -> Optional ShadowComparator
-> MarkdownHTMLDocumentBuilder
-> MarkdownPreviewWebView / MarkdownExportService
```

#### 4-7.1 Swift 文件与职责拆分

建议新增/拆分文件：

| 文件 | 阶段 | 职责 |
| --- | --- | --- |
| `MarkdownRenderContext.swift` | Phase 3/4 | 定义 renderer kind、source profile、repair policy、policy version、cache namespace |
| `MarkdownSourceProfileDetector.swift` | Phase 3 | 从 source text 推断 profile，不负责 Markdown detection |
| `MarkdownSyntaxProtector.swift` | Phase 2 | 在 loose repair 前保护 Markdown syntax island |
| `MarkdownPreviewRenderer.swift` | Phase 4 | 定义 renderer protocol、output、diagnostics |
| `MarkdownPreviewRendererFacade.swift` | Phase 4 | 统一选择 legacy/unified/shadow/fallback |
| `LegacyMarkdownItRenderer.swift` | Phase 4 | 承接当前 `MarkdownHTMLRenderer.render` 的 legacy 逻辑 |
| `UnifiedMarkdownRenderer.swift` | Phase 5 | 生成 unified HTML shell 或调用 unified bundle |
| `MarkdownHTMLDocumentBuilder.swift` | Phase 4/5 | 统一组装 HTML document、CSP、assets、fallback `<pre>`、height report JS |
| `MarkdownRenderCacheKey.swift` | Phase 4 | 生成 renderer/profile/policy/version aware cache key |
| `MarkdownRenderDiagnostics.swift` | Phase 4/5 | 承载 warnings、fallback reason、math count、repair count、duration |
| `MarkdownRendererFeatureFlags.swift` | Phase 4/5 | 控制 legacy/unified/shadow/cutover，不暴露普通 UI 设置 |

第一步不要立刻重命名 `MarkdownHTMLRenderer.swift`，可以先让它变成兼容 facade：

```swift
enum MarkdownHTMLRenderer {
    static func render(markdown: String) -> String {
        let context = MarkdownRenderContextResolver.defaultContext(for: markdown)
        return MarkdownPreviewRendererFacade.render(markdown: markdown, context: context).html
    }

    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput {
        MarkdownPreviewRendererFacade.render(markdown: markdown, context: context)
    }
}
```

这样现有调用点先不必全部改，随后再逐个把调用点迁到 context-aware API。

#### 4-7.2 Renderer protocol 与输出合同

中阶段所有 renderer 必须输出同一种 `MarkdownRenderOutput`：

```swift
protocol MarkdownPreviewRenderer {
    static var kind: MarkdownRendererKind { get }
    static func render(markdown: String, context: MarkdownRenderContext) -> MarkdownRenderOutput
}

struct MarkdownRenderOutput: Equatable {
    let html: String
    let diagnostics: MarkdownRenderDiagnostics
}

struct MarkdownRenderDiagnostics: Equatable {
    let renderer: MarkdownRendererKind
    let profile: MarkdownSourceProfile
    let policyVersion: String
    let protectedIslandCount: Int
    let explicitMathCount: Int
    let repairedMathCount: Int
    let fallbackReason: String?
    let warnings: [String]
}
```

合同要求：

1. `html` 必须是完整 HTML document，不是 fragment。
2. `html` 必须可被 `MarkdownPreviewWebView.loadHTMLString(..., baseURL: MarkdownPreview)` 直接加载。
3. `html` 必须同样适用于 `MarkdownExportService`。
4. renderer 内部失败不能返回半成品 HTML；要么 fallback legacy，要么返回 escaped fallback `<pre>`。
5. diagnostics 只能用于日志、测试、profile，不影响普通 UI。

#### 4-7.3 Legacy renderer 如何从现有代码抽出来

现有 `MarkdownHTMLRenderer.render` 的 legacy 主体不要大改搬迁。建议先做机械拆分：

```text
MarkdownHTMLRenderer.render
-> MarkdownPreviewRendererFacade.render
-> LegacyMarkdownItRenderer.render
-> MarkdownHTMLDocumentBuilder.legacyDocument(...)
```

`LegacyMarkdownItRenderer.render` 第一版保持当前顺序，但接入 context/policy：

```text
raw markdown
-> MarkdownSyntaxProtector.protectForLooseMathRepair
-> policy.allowLatexDocumentNormalize ? LaTeXDocumentNormalizer.normalize : identity
-> policy.allowLooseMathRepair ? MathNormalizer.wrapLooseLaTeX : identity
-> MarkdownSyntaxProtector.restore
-> MathProtector.protectMath
-> policy.allowLatexInlineTextNormalize ? LaTeXInlineTextNormalizer.normalize : identity
-> normalizeATXHeadings
-> MarkdownCJKEmphasisNormalizer
-> MarkdownSafeHTMLSubset.extract
-> MarkdownHTMLDocumentBuilder.legacyDocument
```

关键约束：

1. Phase 4 只抽 facade/cache，不改变 legacy 输出。
2. Phase 4 如果需要接入 policy，也先让默认 policy 模拟旧行为，再由 Phase 3/6 切 profile 策略。
3. legacy 的 `window.__scopyRenderMath`、auto-render、highlight、safe HTML replacements 先原样保留。

#### 4-7.4 HTML document builder 的替换边界

当前 renderer 把 Markdown source、assets、CSS、JS runtime、KaTeX auto-render、fallback `<pre>` 都写在一个函数里。中阶段要把 HTML shell 变成共享 builder：

```swift
enum MarkdownHTMLDocumentBuilder {
    static func legacyDocument(
        markdownSourceForMarkdownIt: String,
        mathPlaceholders: [(placeholder: String, original: String)],
        safeHTMLReplacements: [String: MarkdownSafeHTMLSubset.Replacement],
        fallbackText: String,
        featureSet: MarkdownRenderFeatureSet,
        renderSentinel: String?
    ) -> String

    static func unifiedDocument(
        markdownSource: String,
        context: MarkdownRenderContext,
        fallbackText: String
    ) -> String
}
```

共享责任：

1. CSP meta tag。
2. base CSS。
3. fallback `<pre>`。
4. height report / resize observer。
5. render-ready state。
6. link navigation 继续交给 `MarkdownPreviewWebView`。

分离责任：

| Legacy document | Unified document |
| --- | --- |
| 加载 `markdown-it.min.js`、footnote、deflist、highlight、KaTeX auto-render | 加载 `scopy-unified-renderer.iife.js`、KaTeX CSS、可选 highlight |
| JS 内部 `md.render(src)` | JS 内部 `window.ScopyUnifiedMarkdown.render(src, policy)` |
| restore math placeholders 后再 auto-render | unified bundle 输出已渲染 KaTeX HTML，默认不再 auto-render |
| `window.__scopyRenderMath` 有实现 | `window.__scopyRenderMath` 可以是 no-op 兼容函数 |

必须保留 `window.__scopyRenderMath` 兼容入口。`MarkdownPreviewWebView` 和 export 里已有刷新调用，统一 renderer 上线前不要同步改掉这些调用；unified document 可以定义：

```js
window.__scopyRenderMath = window.__scopyRenderMath || function () {
  if (window.__scopyReportHeight) { window.__scopyReportHeight(); }
};
```

#### 4-7.5 Unified JS bundle 的具体实现

`Tools/MarkdownRenderer` 作为本地 build-time 工具，不作为 runtime Node 依赖。

建议 package 结构：

```text
Tools/MarkdownRenderer/
  package.json
  package-lock.json
  tsconfig.json
  vite.config.ts 或 esbuild.config.mjs
  src/
    index.ts
    render.ts
    policy.ts
    sanitizeSchema.ts
    plugins/
      remarkScopyBackslashMath.ts
      remarkScopyLooseMathRepair.ts
      rehypeScopySafeHTML.ts
      rehypeScopyLinks.ts
  test/
    render.test.ts
    corpus.test.ts
    corpus/
      chatgpt-file-links.md
      authored-markdown.md
      explicit-math.md
      backslash-math.md
      safe-html.md
      currency-shell.md
```

Build 输出：

```text
Scopy/Resources/MarkdownPreview/contrib/scopy-unified-renderer.iife.js
Scopy/Resources/MarkdownPreview/contrib/scopy-unified-renderer.iife.js.sha256
```

Runtime API 必须稳定：

```ts
type ScopyRenderPolicy = {
  profile: string;
  allowExplicitMath: boolean;
  allowBackslashMath: boolean;
  allowLooseMathRepair: boolean;
  allowSafeHTMLSubset: boolean;
  allowRawHTML: boolean;
  policyVersion: string;
};

type ScopyRenderResult = {
  html: string;
  metadata: {
    renderer: "unified";
    mathCount: number;
    repairedMathCount: number;
    warnings: string[];
  };
};

window.ScopyUnifiedMarkdown.render = function (source, policy): ScopyRenderResult;
```

第一版 unified bundle 必须只接受 JSON policy，不读取全局 Swift 状态，不访问网络，不动态 import。

#### 4-7.6 Unified pipeline 的实现顺序

第一版 unified renderer：

```text
source
-> remark-parse
-> remark-gfm
-> remark-breaks
-> remark-math
-> remarkScopyBackslashMath
-> remark-rehype
-> rehype-sanitize
-> rehype-katex
-> rehype-stringify
```

第一版不要启用 loose repair，也不要启用 raw HTML。

第二版增加 safe HTML subset：

```text
source
-> protect/parse safe subset 或 rehypeScopySafeHTML
-> strict rehype-sanitize schema
```

第三版才增加：

```text
remarkScopyLooseMathRepair
```

原因：显式 math、GFM 和 HTML sanitize 已经足够复杂，loose repair 是最高风险插件，必须等 shadow 对比机制稳定后再上。

#### 4-7.7 `\(...\)` / `\[...\]` 的实现边界

必须把 backslash math 当成 parser-level extension，而不是 HTML 后处理。

推荐实现：

1. `remarkScopyBackslashMath` 基于 micromark extension，把 `\(...\)` 变成 `inlineMath`，把 `\[...\]` 变成 `math`。
2. tokenizer 必须跳过 code、html、link destination。
3. 如果第一版 micromark extension 成本过高，可以做 pre-tokenizer，但必须复用 `MarkdownSyntaxProtector` 的同等规则，不允许裸 regex 扫全篇。

不允许的实现：

```text
source.replace(/\\\((.*?)\\\)/g, "$$$1$")
```

原因：会碰 code、link、HTML attribute，并复现当前 bug 类型。

#### 4-7.8 Shadow renderer 如何接入

Shadow mode 不改变 UI 输出，只做离线对比：

```swift
let primary = LegacyMarkdownItRenderer.render(markdown: source, context: legacyContext)
if MarkdownRendererFeatureFlags.shadowUnifiedEnabled,
   context.profile.isSafeForUnifiedShadow {
    let shadow = UnifiedMarkdownRenderer.render(markdown: source, context: unifiedContext)
    MarkdownRenderShadowComparator.record(primary: primary, shadow: shadow, source: source, context: context)
}
return primary
```

Shadow comparator 第一版不要做完整 HTML diff，只记录结构信号：

| 信号 | 目的 |
| --- | --- |
| primary/shadow HTML 是否为空 | 防止 unified 失败 |
| link count | 发现 link 丢失 |
| code block count | 发现 code 被吞 |
| table count | 发现 GFM 表格退化 |
| footnote marker count | 发现 footnote anchor 差异 |
| math count | 发现公式丢失或重复 |
| contains external URL in assets | 安全检查 |
| render duration | 性能检查 |

Shadow diagnostics 不写入 DB，不影响剪贴板 item，不进入普通 UI。可以先只在 `ScrollPerformanceProfile.isEnabled` 或 debug flag 下记录。

#### 4-7.9 Cutover/fallback 策略

Cutover 不应是全局开关，应是 profile-based：

```swift
enum MarkdownRendererSelector {
    static func rendererKind(for context: MarkdownRenderContext) -> MarkdownRendererKind {
        if MarkdownRendererFeatureFlags.forceLegacy { return .legacyMarkdownIt }
        if MarkdownRendererFeatureFlags.forceUnified { return .unified }

        switch context.profile {
        case .authoredMarkdown, .chatGPTMarkdown:
            return MarkdownRendererFeatureFlags.unifiedSafeProfilesEnabled ? .unified : .legacyMarkdownIt
        case .scientificMarkdown:
            return MarkdownRendererFeatureFlags.unifiedScientificEnabled ? .unified : .legacyMarkdownIt
        case .latexDocumentLike, .pdfOCRScientific, .richHTML, .plainTextUnknown:
            return .legacyMarkdownIt
        }
    }
}
```

Fallback 条件：

1. unified JS API 不存在。
2. unified render throw。
3. unified result HTML 为空。
4. unified result 包含明显 fatal marker。
5. diagnostics 显示 math/link/code 数量异常，且 source 属于高风险 profile。

Fallback 输出必须使用 legacy renderer，并在 diagnostics 里记录 `fallbackReason`。

#### 4-7.10 Cache 与 request 实现

当前 `MarkdownRenderRequest` 只有 source/target，中阶段要改为：

```swift
struct MarkdownRenderRequest {
    enum Target {
        case text(cacheKey: String)
        case file(cacheKey: String)
    }

    let source: String
    let context: MarkdownRenderContext
    let target: Target

    var renderCacheKey: String {
        MarkdownRenderCacheKey.make(sourceHash: target.contentHash, context: context)
    }
}
```

如果不想改 `Target`，可以保留原 target cacheKey，但所有 cache 读写必须经：

```swift
let renderKey = MarkdownRenderCacheKey.make(contentHash: cacheKey, context: context)
```

必须改的点：

| 当前点 | 改造 |
| --- | --- |
| `MarkdownPreviewCache.shared.html(forKey: item.contentHash)` | 使用 render-aware key |
| `MarkdownPreviewCache.shared.metrics(forKey: item.contentHash)` | 使用 render-aware key |
| `setHTML(html, forKey: cacheKey)` | 使用 render-aware key |
| file preview entry html | 同一 file content 在不同 renderer 下分开缓存 |
| metrics | 和 HTML 同 namespace，避免 unified/legacy 高度串用 |

不要把 source profile 缓存在 `HistoryItemPresentationCache.cachedMarkdownExportCapability` 里。profile/policy 是 renderer 策略，可能随版本升级变化；缓存 `isMarkdown` 可以，缓存 policy 会造成难刷新的旧行为。

#### 4-7.11 WebView 与 export 实现影响

`MarkdownPreviewWebView` 理论上不需要知道 renderer kind，但需要兼容 unified document：

1. `baseURL` 仍然是 `Bundle.main.resourceURL/MarkdownPreview`。
2. `__scopyIsRenderReady` 必须继续存在。
3. `__scopyRenderMath` 必须存在或 graceful no-op。
4. height report payload `{ width, height, overflowX }` 不变。
5. external navigation policy 不变。

`MarkdownExportService` 也不应该知道 renderer kind。唯一要保证的是 unified HTML document 在 export offscreen WebView 里也定义 render-ready/math no-op，并且不会因为没有 auto-render 二次扫描而超时。

建议新增 focused tests：

```text
MarkdownHTMLRendererTests.testUnifiedDocumentDefinesRenderReadyHooks
MarkdownPreviewNavigationPolicyTests 继续不变
MarkdownExportServiceTests 加一个 unified shell smoke，如果构建期已有 bundle
```

#### 4-7.12 中阶段 PR 拆分到实现任务

如果要把 Phase 4-7 交给后续实现，建议按下面拆，不要合并成一个大 PR：

| 实现任务 | 文件范围 | 完成定义 |
| --- | --- | --- |
| M1 renderer context/facade | `MarkdownRenderContext.swift`、`MarkdownPreviewRenderer.swift`、`MarkdownPreviewRendererFacade.swift` | 旧调用仍走 legacy，HTML snapshot 不变 |
| M2 legacy extraction | `LegacyMarkdownItRenderer.swift`、`MarkdownHTMLDocumentBuilder.swift` | `MarkdownHTMLRenderer.render` 输出关键 assets/hooks 不变 |
| M3 cache namespace | `HistoryHoverPreviewPipeline.swift`、`MarkdownPreviewCache.swift`、tests | legacy key 从 raw contentHash 升级为 render-aware key |
| M4 unified vendored bundle scaffold | `Tools/MarkdownRenderer`、`Scopy/Resources/MarkdownPreview/contrib` | build 产物本地化，`make build` 能 stage |
| M5 unified document smoke | `UnifiedMarkdownRenderer.swift`、builder、tests | authored Markdown shadow render 不影响 UI |
| M6 shadow comparator | diagnostics/comparator/perf hooks | 只记录，不影响用户输出 |
| M7 safe profile cutover | selector/feature flag/tests | authored/chatGPT profile 可切 unified，失败 fallback legacy |
| M8 AST loose repair | unified plugin/corpus/tests | `pdfOCRScientific` shadow 先通过，再考虑 cutover |

每个任务都必须更新 corpus 或 focused tests，不能只改实现。

#### 4-7.13 什么时候才算“替换 renderer 完成”

不要把“unified bundle 能跑”当成替换完成。完成定义是：

1. `authoredMarkdown` 和 `chatGPTMarkdown` 默认走 unified。
2. legacy fallback 仍存在且可强制启用。
3. render-aware cache key 已覆盖 text/file preview HTML 和 metrics。
4. Preview/export 使用同一 unified HTML document。
5. `window.__scopyRenderMath` 兼容入口不再导致重复 KaTeX 渲染。
6. corpus 覆盖 link/image/reference/code/math/path/currency/CJK/HTML。
7. `make build`、`make test-unit`、`make perf-frontend-profile` 均通过。
8. 文档记录哪些 profile 仍走 legacy，以及为什么。

### Phase 8：Legacy 收敛

目的：在 unified 覆盖足够后，决定 legacy 去留。

建议不要急着删除 legacy。至少保留一个版本周期作为 fallback。

可删除条件：

1. 所有 profile 都可用 unified 渲染。
2. corpus 覆盖 ChatGPT/PDF/OCR/LaTeX/HTML/CJK/code/path/currency。
3. export PNG 与 hover preview 通过同源 HTML 验收。
4. `make test-unit`、`make perf-frontend-profile-standard` 连续稳定。
5. 已有 fallback telemetry 证明 legacy fallback 触发率接近 0。

## 6. Unified Feature Mapping

| Scopy 当前能力 | 当前实现 | unified 对应 | 风险 |
| --- | --- | --- | --- |
| Markdown parse | markdown-it | `remark-parse` | CommonMark/GFM DOM 差异 |
| table/strike/task | markdown-it enable/runtime | `remark-gfm` | task checkbox HTML class 差异 |
| footnote | `markdown-it-footnote` | `remark-gfm` footnote | anchor/id/样式差异 |
| definition list | `markdown-it-deflist` | `remark-deflist` 或 custom plugin | 生态成熟度较低 |
| hard breaks | `breaks: true` | `remark-breaks` | 必须保留，否则 PDF/clipboard 单换行变差 |
| linkify | markdown-it `linkify` | `remark-gfm` autolink literal 或 custom linkify | bare URL 行为差异 |
| typographer | markdown-it `typographer` | smartypants plugin 或暂不迁 | 标点输出差异 |
| code highlight | highlight.js runtime | 先继续 highlight.js，后续 `rehype-highlight` | bundle size/主题差异 |
| safe HTML subset | `MarkdownSafeHTMLSubset` | `rehypeScopySafeHTML` + `rehype-sanitize` | 安全边界必须等价 |
| `$...$` / `$$...$$` | `MathProtector` + KaTeX auto-render | `remark-math` + `rehype-katex` | delimiter 行为差异 |
| `\(...\)` / `\[...\]` | `MathProtector` | custom micromark extension | 不能靠后置 regex |
| loose LaTeX | `MathNormalizer` | AST text-node repair plugin | 迁移风险最高 |
| mhchem | `mhchem.min.js` | bundle `katex/contrib/mhchem` | 确认 `\ce{}` 支持 |
| preview/export | same HTML shell | 继续 same HTML shell | 不要引入两套渲染产物 |

## 7. 回归语料矩阵

每个样例至少记录：

```text
id
profile
input
expected renderer
expected repair policy
mustContain
mustNotContain
visual risk
export risk
```

必备样例：

| 类别 | 样例 | 预期 |
| --- | --- | --- |
| ChatGPT local link | `[doc](/Users/a/b.md:25)` | link/path 不被 math wrap |
| image path | `![img](/Users/a/img(1)_v2.png)` | image 保持 image syntax |
| reference definition | `[paper]: /Users/a/file_v2.md:25 "title"` | definition 不被 repair |
| link label math-like | `[x_i](/tmp/a.md)` | label 不被 square bracket math wrap |
| explicit inline math | `$x_i^2$` | KaTeX 渲染且 Markdown 不拆 `_` |
| backslash inline math | `\(x_i^2\)` | KaTeX 渲染 |
| display math | `$$x^2$$` / `\[x^2\]` | block math |
| loose paren math | `(T_{io}=12.4)ms` | 只在 repair profile wrap |
| LaTeX document | `\section{...}` + `\begin{equation}` | legacy/late phase unified 保结构 |
| tabular | `\begin{tabular}` | 保持现有 table normalize 能力 |
| currency | `$5 and $6` | 不进入 math |
| shell vars | `$HOME $PATH` | 不进入 math |
| CJK emphasis | `**重要：**请注意` | 保持 CJK strong 视觉 |
| HTML subset | `<details><summary>...</summary>` | 只允许 safe subset |
| code fence | fenced code with `\frac{x}{y}` | 不渲染成 math |
| inline code | `` `x_i` `` | 不渲染成 math |
| URL query | `https://x.test/a_(b)?q=x_y` | 不被 repair |

## 8. 安全、性能与导出要求

### 8.1 安全

1. 所有 renderer asset 必须本地加载。
2. 禁止默认外链脚本、外链 CSS、远程字体。
3. WebView 继续使用 non-persistent data store。
4. `http/https` request 继续被 content rule list 阻断。
5. link click 继续只允许同文档 fragment navigation。
6. `allowRawHTML` 默认 false。
7. 如引入 `rehype-raw`，只能在显式 profile + strict sanitize schema 下启用。

### 8.2 性能

性能约束：

1. hover render 仍在 detached utility task 里执行。
2. 大文本继续保留 200k 级别上限，避免 hover 卡顿。
3. unified bundle 首次加载成本必须通过 profile 量化。
4. cache key 必须隔离 renderer/profile/policy。
5. `hover.markdown_render_ms` 必须持续记录。

性能验收：

```text
make perf-frontend-profile
make perf-frontend-profile-standard
```

### 8.3 导出

导出原则：

1. Preview 和 export 必须使用同一 HTML document。
2. Export 不应知道 renderer kind，只消费 `html`。
3. 如果 unified 预渲染 KaTeX，export 不应再次 auto-render 导致重复。
4. 任何 HTML shell 变化都要跑 Markdown export focused tests。

## 9. 风险矩阵

| 风险 | 影响 | 防线 |
| --- | --- | --- |
| unified DOM 与 markdown-it DOM 差异 | CSS/截图/export 退化 | shadow renderer + corpus + visual spot check |
| cache 污染 | 切换 renderer 后显示旧 HTML | cache namespace |
| `\(...\)` 被 CommonMark escape 破坏 | backslash math 丢失 | micromark extension |
| safe HTML 放大攻击面 | XSS/外链 | sanitize schema + raw HTML 默认关 |
| loose repair 过度解释普通文本 | Markdown/path/currency 被误改 | profile-gated + syntax protector |
| bundle 变大/首次加载慢 | hover 延迟 | local bundle、perf profile、分 profile cutover |
| export 与 preview 不一致 | 用户看到和导出不同 | same HTML document contract |
| dependency supply chain | 构建不稳定 | vendored locked bundle + lockfile + checksum |
| macOS 14/Swift 5.9 兼容 | build failure | 不引入新 Swift API；JS bundle 本地化 |

## 10. Grill-Me 自问自答

问题 1：为什么不直接用 unified 替换全部 renderer？

推荐答案：不能。当前 Scopy 有大量 legacy 能力：safe HTML subset、CJK emphasis、PDF/OCR loose LaTeX、LaTeX document normalize、导出 PNG、WebView height reporting。一次性替换会把风险集中到一个 PR，且难以判断退化来源。正确路线是 renderer abstraction + shadow renderer + safe profile cutover。

问题 2：为什么不把 `MathNormalizer` 删掉？

推荐答案：不能。`MathNormalizer` 承担的是 PDF/OCR/富文本复制后的公式修复能力，不是普通 math parser。问题不是它存在，而是它默认全局运行且不知道 Markdown syntax island。应保留能力，但用 source profile 和 syntax protection 限制作用范围。

问题 3：默认应该保 Markdown 还是尽量修公式？

推荐答案：默认保 Markdown。显式 math 继续渲染；loose repair 只在 `latexDocumentLike` / `pdfOCRScientific` profile 启用。理由是 Markdown 是用户明确写下的语法，loose repair 是猜测。

问题 4：为什么 `MarkdownDetector` 不够？

推荐答案：它回答的是“是否值得 Markdown preview”，不是“是否允许改写原文”。检测和 repair policy 是两个不同问题。把它们混在一起会导致只要文本像 Markdown/LaTeX，就触发高风险修复。

问题 5：为什么必须保护整个 link，而不是只保护 destination？

推荐答案：因为 loose repair 不只处理 `(...)`，也处理 `[...]`。`[x_i](/tmp/a.md)` 的 label 也可能被当作 square bracket math，所以必须保护整个 Markdown inline link/image/reference。

问题 6：为什么 Pandoc/Quarto/Mathpix 不作为默认预览？

推荐答案：它们更适合 publishing/STEM/OCR 转换，不适合 Scopy 的低延迟 hover preview、local WKWebView、缓存、PNG export 和普通剪贴板文本。它们可以作为长期 export/advanced mode 参考，不应做默认 renderer。

问题 7：为什么 unified 仍不能自动解决 loose LaTeX？

推荐答案：`remark-math` 主要处理显式 delimiter。loose LaTeX repair 仍要自研，但 AST 让 repair 只访问安全 text node，避免碰 link/image/code/definition。

问题 8：什么情况下可以关闭 legacy fallback？

推荐答案：至少等 unified 覆盖所有 profile，corpus 和 export 验收稳定，性能 profile 无明显退化，并且 fallback telemetry 显示真实触发率接近 0。否则 legacy 应保留一个版本周期。

## 11. 后续实现顺序

推荐 PR 切分：

| PR | 内容 | 用户影响 | 回滚难度 |
| --- | --- | --- | --- |
| 1 | hard reject + regression | 修 bug，无架构变化 | 低 |
| 2 | `MarkdownSyntaxProtector` | 降低误修概率 | 低 |
| 3 | source profile + repair policy | 改策略边界 | 中 |
| 4 | renderer abstraction + cache namespace | 为并行 renderer 铺路 | 中 |
| 5 | unified shadow renderer | 默认无用户影响 | 中 |
| 6 | safe profile cutover | authored/chatGPT Markdown 改走 unified | 中高 |
| 7 | AST loose repair | 科学/PDF/OCR 输入迁移 | 高 |
| 8 | legacy 收敛 | 删除或保留 fallback | 高 |

每个 PR 的完成定义：

1. 有 focused tests。
2. `make build` 通过。
3. `make test-unit` 通过。
4. 如果影响 hover/render/WebView，至少跑 `make perf-frontend-profile`。
5. 如果影响 export HTML，跑 Markdown export focused tests。
6. 如果修改 asset/bundle，确认 `project.yml` stage 路径和 app bundle 路径。
7. 文档更新说明 profile/policy/cache 变化。

## 12. 最终建议

最稳路线是：

```text
先保护当前 markdown-it legacy 链路
-> 拆出 source profile 和 repair policy
-> 抽象 renderer 和 cache namespace
-> 引入 unified shadow renderer
-> 先迁移 authored/chatGPT Markdown
-> 最后把 loose repair 迁到 AST text-node plugin
```

这条路线把最大风险拆成可验证的小步：短期解决误渲染，中期修正架构边界，长期才替换底层 renderer。它也符合 Scopy 的实际约束：本地 WKWebView、同源 HTML preview/export、低延迟 hover、现有 Markdown/LaTeX 修复能力都不能被一次性推倒。

## 13. 蓝图覆盖审计清单

| 明确要求 | 文档落点 | 证据 |
| --- | --- | --- |
| 查看 GPT Pro 调研文档 | 本文输入资料声明 | 顶部“输入资料” |
| 构建完备详细迁移蓝图 | 目标、架构、阶段、测试、风险全链路 | 第 1 到第 12 节 |
| 对其他影响较小 | 分阶段 PR、legacy fallback、cache namespace、feature flag | 第 5、8、11 节 |
| Markdown 支持尽量完整 | feature mapping、syntax protector、corpus matrix | 第 4、6、7 节 |
| LaTeX 支持尽量完整 | explicit math、backslash math、loose repair、LaTeX document profile | 第 4、5、6、7 节 |
| 包含 renderer replacement 中阶段实现 | Swift facade、legacy extraction、unified bundle、HTML builder、shadow comparator、cutover、fallback、cache、WebView/export 兼容 | “Phase 4-7 中阶段实现详案” |
| 稳定可回滚 | 每阶段验收、cache namespace、legacy fallback | 第 5、8、9、11 节 |
| 便于后续实现 | PR 切分、API 草案、文件建议、命令门 | 第 4、5、11 节 |
| 考虑方方面面 | 安全、性能、导出、WebView、cache、dependency、test gates | 第 8、9 节 |
| `$grill-me` 自问自答 | 关键设计问题与推荐答案 | 第 10 节 |
