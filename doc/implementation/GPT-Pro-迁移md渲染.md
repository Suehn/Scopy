
我看了 `Suehn/Scopy` 里 Markdown 相关实现。结论是：

**中期最佳方案是 `unified / remark / rehype + KaTeX`，但不要直接替换现有 renderer。**
对你的 repo 来说，最稳妥的路线是：

```text
先保留现有 markdown-it/WKWebView 路径
-> 加 source profile + syntax island protection + policy-gated loose repair
-> 引入 unified 作为 shadow renderer
-> 先迁移 authored/chatgpt Markdown
-> 最后再迁移 PDF/OCR loose LaTeX repair
```

不要选 Pandoc / Quarto / Mathpix Markdown 作为默认 hover preview 主线。它们不适合 Scopy 当前的本地 WKWebView、缓存、导出 PNG、低延迟 hover 架构。也不要只换成 `markdown-it-texmath`；它能改善显式 math delimiter parsing，但不能解决你现在的 root cause。

---

## 1. 你的 repo 当前链路有什么关键事实

### 1.1 当前 `MarkdownHTMLRenderer.render` 的顺序确实是问题核心

你现在的顺序是：

```swift
let latexNormalized = LaTeXDocumentNormalizer.normalize(markdown)
let normalizedMarkdown = MathNormalizer.wrapLooseLaTeX(latexNormalized)
let protected = MathProtector.protectMath(in: normalizedMarkdown)
let inlineNormalizedMarkdown = LaTeXInlineTextNormalizer.normalize(protected.markdown)
...
let safeHTMLExtraction = MarkdownSafeHTMLSubset.extract(...)
...
htmlDocument(...)
```

也就是：**loose LaTeX repair 在 Markdown parser 之前全局运行，而且在 `MathProtector` 之前运行。** 这和你描述的 bug 完全吻合。`MathProtector` 放在后面，只能保护已经被 normalizer 处理后的 math，不能保护 link/image/reference 这些 Markdown syntax islands。

### 1.2 你当前 feature set 已经很完整，不应一次性推倒

默认 feature set 是：

```swift
html: false
linkify: true
typographer: true
breaks: true
tables: true
strikethrough: true
taskLists: true
footnotes: true
definitionLists: true
safeHTMLSubset: true
codeHighlighting: true
math: true
```

并且本地加载 `markdown-it.min.js`、footnote、deflist、highlight.js 等资源。

这意味着中期迁移不能只说“换 remark”。你还要对齐这些行为：

```text
breaks: true
linkify
typographer
tables
strikethrough
task list
footnote
definition list
safe HTML subset
highlight.js
math
KaTeX/mhchem
```

### 1.3 `MathNormalizer` 不是简单 bug；它已经承担了大量 PDF/OCR 修复能力

你的 `MathNormalizer` 已经做了很多定制逻辑：

```text
bracketed math wrapping
\left...\right run wrapping
standalone TeX command wrapping
[ ... ] display block -> $$ ... $$
full-width parentheses
table cell loose math
set notation repair
```

相关测试也覆盖了 Wasserstein snippet、tabular 转表格、adjacent inline math、equation environment、CJK mixed text 等复杂场景。

所以不能简单删掉 `MathNormalizer`。正确做法是：**保留能力，但限制它只能在允许 repair 的 source profile 和未保护 text segment 中运行。**

### 1.4 `MathNormalizer.shouldWrapAsMath` 当前防护不够

它目前只显式排除了：

```swift
http://
https://
```

但没有排除：

```text
/Users/
~/
./
../
file:
.md:25
.png
.pdf
:line
path-like slash-heavy strings
Markdown link destination
Markdown image destination
reference definition
URL query
currency
```

这就是 `[label](/Users/xxx/file.md:25)` 会被误判的直接原因。

### 1.5 `MarkdownCodeSkipper` 已经有，但只保护 code，不保护 Markdown 结构

你已经有 `MarkdownCodeSkipper`，能处理 fenced code 和 inline code。

这很好，但不够。你现在缺的是：

```text
MarkdownSyntaxProtector
  - inline link: [label](dest)
  - image: ![alt](src)
  - reference definition: [id]: dest "title"
  - reference link: [label][id]
  - shortcut reference: [id]
  - autolink: <https://...>
  - raw HTML attributes
  - bare URL / file path
```

### 1.6 安全基础不错，但 renderer migration 要保留这些安全边界

你的 WKWebView preview 使用 non-persistent data store、network blocker、navigation policy，阻止 http/https 和 link-activated navigation，只允许同文档 fragment navigation。

Export 也使用 offscreen WKWebView，并有网络阻断规则。

这说明 migration 的目标不是“找个库直接输出 HTML”，而是继续保持：

```text
local assets
non-persistent WKWebView
network blocked
navigation blocked
same HTML for preview/export
controlled CSS
no external scripts
```

### 1.7 你的项目结构适合“本地 JS bundle renderer”

`project.yml` 已经有 `Stage MarkdownPreview Assets`，会把 `Scopy/Resources/MarkdownPreview` 整体复制进 app bundle。

因此中期最适合的 unified 集成方式不是在 Swift 里硬跑 Node，也不是引入 Pandoc binary，而是：

```text
Tools/MarkdownRenderer
  -> bundle unified/remark/rehype/katex into IIFE JS
  -> output Scopy/Resources/MarkdownPreview/scopy-unified-renderer.iife.js
  -> WKWebView 加载本地 bundle
```

这和你现有本地 `markdown-it.min.js` 资源模式兼容。

---

## 2. 最佳方案选择

### 推荐方案

```text
unified
+ remark-parse
+ remark-gfm
+ remark-breaks
+ remark-math
+ custom micromark extension for \( \), \[ \]
+ custom remarkScopyLooseMathRepair
+ remark-rehype
+ rehype-sanitize
+ rehype-katex
+ rehype-stringify
```

打包成：

```text
Scopy/Resources/MarkdownPreview/scopy-unified-renderer.iife.js
```

由 WKWebView 本地加载。

---

## 3. 为什么这对 Scopy 最合适

### 不选 Pandoc / Quarto

它们适合 long-form scientific publishing，不适合 Scopy 的 hover preview。原因：

```text
启动/调用成本高
binary/sandbox 成本高
行为和普通 Markdown 差异大
安全面更复杂
不解决 loose LaTeX repair
```

可以保留为未来高级 export，不应做默认 preview。

### 不选 Mathpix Markdown 默认模式

Mathpix Markdown 偏 STEM/OCR dialect。Scopy 的普通剪贴板内容包含：

```text
ChatGPT Markdown
网页文本
本地路径
URL
currency
CJK
代码片段
HTML fragment
```

Mathpix-like parser 很容易过度解释。

### 不选 markdown-it-texmath 作为中期主线

它可以做短期显式 math 插件，但不能解决你的核心问题：

```text
Markdown 语法边界
source profile
loose repair policy
AST node protection
safe transform order
```

### 不选 MathJax auto-render 作为主线

你现在用 KaTeX auto-render 扫 DOM text nodes。它能工作，但中期更稳的是：

```text
Markdown AST
-> math node
-> rehype-katex 输出 HTML
-> WKWebView 只展示结果
```

也就是不要让 math renderer 扫整页 DOM 来猜。

---

## 4. repo-specific 中期目标架构

建议把当前 `MarkdownHTMLRenderer` 抽象成 renderer protocol，而不是直接改死。

```swift
enum MarkdownRendererKind: String {
    case legacyMarkdownIt
    case unified
}

enum MarkdownSourceProfile: String {
    case authoredMarkdown
    case chatGPTMarkdown
    case latexDocumentLike
    case pdfOCRScientific
    case richHTML
    case webPlainText
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
    let cacheNamespace: String
}
```

然后：

```swift
protocol MarkdownPreviewRenderer {
    static func render(markdown: String, context: MarkdownRenderContext) -> String
}
```

当前文件可以先改名为：

```text
MarkdownHTMLRenderer.swift
-> LegacyMarkdownItHTMLRenderer.swift
```

再新增：

```text
UnifiedMarkdownHTMLRenderer.swift
MarkdownRenderContext.swift
MarkdownSourceProfileDetector.swift
MarkdownSyntaxProtector.swift
```

---

## 5. 当前 pipeline 应该改成什么

### 现在

```text
raw markdown
-> LaTeXDocumentNormalizer
-> MathNormalizer.wrapLooseLaTeX
-> MathProtector
-> LaTeXInlineTextNormalizer
-> heading/CJK/safeHTML
-> markdown-it in WKWebView
-> KaTeX auto-render
```

### 短中期正确顺序

```text
raw source
-> source profile detection
-> syntax island protection
-> profile-gated LaTeXDocumentNormalizer
-> profile-gated loose math repair on unprotected segments only
-> restore syntax islands
-> explicit math protection/parser
-> markdown renderer
-> safe HTML / sanitize
-> KaTeX render
-> WKWebView / export
```

对你当前代码，第一步不是 unified，而是把 `MathNormalizer` 从全局 destructive transform 改成：

```text
protected segment transform
```

---

## 6. Phase 1：先止血，保留 markdown-it

### 6.1 新增 `MarkdownSyntaxProtector.swift`

建议 API：

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
    case referenceDefinition
    case autolink
    case rawHTML
    case url
    case filePath
}

enum MarkdownSyntaxProtector {
    static func protectForLooseMathRepair(_ markdown: String) -> MarkdownSyntaxProtectionResult
    static func restore(_ markdown: String, placeholders: [(placeholder: String, original: String, kind: MarkdownSyntaxIslandKind)]) -> String
}
```

保护范围优先级：

```text
1. fenced code
2. inline code
3. image
4. inline link
5. reference definition
6. autolink
7. safe/raw HTML spans
8. bare URL / local file path
```

关键点：**loose repair 阶段最好保护整个 `[label](dest)`，不是只保护 destination。**

原因是当前 `MathNormalizer` 也会扫描 `[...]`，可能把 link label `[x_i]` 或 reference label `[T_{io}]` 当作 square bracket math。

---

### 6.2 修改 `MarkdownHTMLRenderer.render`

把当前：

```swift
let latexNormalized = LaTeXDocumentNormalizer.normalize(markdown)
let normalizedMarkdown = MathNormalizer.wrapLooseLaTeX(latexNormalized)
let protected = MathProtector.protectMath(in: normalizedMarkdown)
```

改成概念上：

```swift
let context = MarkdownSourceProfileDetector.context(for: markdown)

let syntaxProtected = MarkdownSyntaxProtector.protectForLooseMathRepair(markdown)

let latexNormalized = context.policy.allowLatexDocumentNormalize
    ? LaTeXDocumentNormalizer.normalize(syntaxProtected.markdown)
    : syntaxProtected.markdown

let mathNormalized = context.policy.allowLooseMathRepair
    ? MathNormalizer.wrapLooseLaTeX(latexNormalized)
    : latexNormalized

let restoredMarkdown = MarkdownSyntaxProtector.restore(
    mathNormalized,
    placeholders: syntaxProtected.placeholders
)

let protected = MathProtector.protectMath(in: restoredMarkdown)
```

这一步就能阻止：

```md
[label](/Users/xxx/file.md:25)
```

在 loose repair 阶段被改写。

---

### 6.3 修改 `MathNormalizer.shouldWrapAsMath`

增加 hard reject：

```swift
private static func isPathLikeOrURLLike(_ s: String) -> Bool {
    let lower = s.lowercased()

    if lower.contains("http://") || lower.contains("https://") { return true }
    if lower.contains("file://") || lower.contains("mailto:") { return true }

    if s.contains("/Users/") || s.contains("/Volumes/") { return true }
    if s.hasPrefix("~/") || s.hasPrefix("./") || s.hasPrefix("../") { return true }

    if s.contains(".md:") || s.contains(".markdown:") || s.contains(".tex:") { return true }
    if s.contains(".png") || s.contains(".jpg") || s.contains(".jpeg") || s.contains(".pdf") { return true }

    if s.contains("?") && s.contains("=") { return true }
    if s.contains("#") && s.contains("/") { return true }

    let slashCount = s.filter { $0 == "/" }.count
    if slashCount >= 2 { return true }

    return false
}
```

然后在 `shouldWrapAsMath` 里：

```swift
if isPathLikeOrURLLike(s) { return false }
if isCurrencyLike(s) { return false }
```

不要只靠 `http://` / `https://`。当前 bug 是 local path，不是 web URL。

---

### 6.4 加 source profile，不要再让 `MarkdownDetector` 决定 repair policy

你当前 `MarkdownDetector.isLikelyMarkdown` 会因为 math、`\begin{}`、`\section{}`、link、fence、table 等进入 Markdown preview。

这没有问题，但它只能回答：

```text
是否值得用 Markdown preview
```

不能回答：

```text
是否允许 loose LaTeX repair
```

建议拆成两个概念：

```swift
MarkdownDetector.isLikelyMarkdown(_:)
MarkdownSourceProfileDetector.detect(_:)
```

默认 policy：

| profile             | allowLatexDocumentNormalize | allowLooseMathRepair |
| ------------------- | --------------------------: | -------------------: |
| `authoredMarkdown`  |                       false |                false |
| `chatGPTMarkdown`   |                       false |                false |
| `webPlainText`      |                       false |                false |
| `plainTextUnknown`  |                       false |                false |
| `latexDocumentLike` |                        true |   true, conservative |
| `pdfOCRScientific`  |                        true | true, high threshold |
| `richHTML`          |                       false |                false |

对 Scopy 来说，**loose repair 默认应该关**。只在 LaTeX/PDF/OCR scientific profile 开。

---

## 7. Phase 2：引入 renderer abstraction 和 cache namespace

当前 `HistoryHoverPreviewPipeline` 里 Markdown render request 只有：

```swift
struct MarkdownRenderRequest {
    let source: String
    let target: Target
}
```

然后调用：

```swift
MarkdownHTMLRenderer.render(markdown: source)
```

并用 `contentHash` 做 cache key。

中期迁移时必须改这里。否则 unified/legacy 输出会互相污染 cache。

建议改成：

```swift
struct MarkdownRenderRequest {
    let source: String
    let context: MarkdownRenderContext
    let target: Target
}
```

cache key 改成：

```swift
let markdownCacheKey = [
    "md",
    context.renderer.rawValue,
    context.cacheNamespace,
    context.profile.rawValue,
    item.contentHash
].joined(separator: "|")
```

例如：

```text
md|legacyMarkdownIt|v1|authoredMarkdown|<contentHash>
md|unified|v1|authoredMarkdown|<contentHash>
```

这对 shadow renderer 很重要。

---

## 8. Phase 3：做 unified shadow renderer

### 8.1 新增 JS renderer package

建议目录：

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
```

build 输出：

```text
Scopy/Resources/MarkdownPreview/scopy-unified-renderer.iife.js
```

你的 `project.yml` 已经会 stage `Scopy/Resources/MarkdownPreview`，所以这个资产路径和现有构建方式兼容。

### 8.2 unified bundle 暴露一个稳定 API

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

Swift 生成 HTML document 时：

```html
<script defer src="scopy-unified-renderer.iife.js"></script>
<script>
  const src = "...";
  const policy = {...};
  const result = window.ScopyUnifiedMarkdown.render(src, policy);
  document.getElementById("content").innerHTML = result.html;
  window.__scopyReportHeight();
</script>
```

### 8.3 unified renderer 不要先处理所有 profile

第一批只迁移：

```text
authoredMarkdown
chatGPTMarkdown
plain Markdown file preview
```

继续走 legacy 的：

```text
latexDocumentLike
pdfOCRScientific
richHTML-heavy
unknownPlainText with loose math
```

原因是你的 `MathNormalizer` 和 `LaTeXDocumentNormalizer` 已经有大量科学文本修复逻辑，迁移这些能力风险最大。

---

## 9. unified feature mapping：你的 featureSet 怎么对齐

| Scopy 当前能力                | 当前实现                                 | unified 迁移对应                                         |
| ------------------------- | ------------------------------------ | ---------------------------------------------------- |
| Markdown parse            | markdown-it                          | `remark-parse`                                       |
| GFM table/strike/task     | markdown-it enable + runtime         | `remark-gfm`                                         |
| footnote                  | `markdown-it-footnote`               | `remark-gfm` footnote；需检查 DOM 差异                     |
| definition list           | `markdown-it-deflist`                | `remark-deflist` / custom plugin                     |
| hard breaks               | `breaks: true`                       | `remark-breaks`                                      |
| linkify                   | `linkify: true`                      | `remark-gfm` autolink literal；必要时 custom linkify     |
| typographer               | `typographer: true`                  | 暂不迁移或用 smartypants plugin                            |
| code highlighting         | highlight.js runtime                 | 先保留 highlight.js；后续可 `rehype-highlight`              |
| safe HTML subset          | `MarkdownSafeHTMLSubset` placeholder | `rehypeScopySafeHTML` + `rehype-sanitize` schema     |
| math `$...$`, `$$...$$`   | `MathProtector` + KaTeX auto-render  | `remark-math` + `rehype-katex`                       |
| math `\(...\)`, `\[...\]` | `MathProtector`                      | custom micromark extension，或 protected pre-tokenizer |
| loose LaTeX repair        | `MathNormalizer`                     | 后续 `remarkScopyLooseMathRepair`，只访问 text nodes       |
| KaTeX rendering           | browser auto-render                  | `rehype-katex` pre-rendered HTML                     |
| mhchem                    | `mhchem.min.js`                      | bundle `katex/contrib/mhchem`                        |
| preview/export            | same HTML into WKWebView             | 保持 same HTML                                         |

特别注意：你的当前 renderer 有 `breaks: true`，注释里也明确为了 clipboard/PDF copied text 保留单换行。
所以 unified 里必须加 `remark-breaks`，否则视觉结果会变。

---

## 10. `\(...\)` / `\[...\]` 的处理不能偷懒

`remark-math` 主要解决 dollar math。Scopy 还要支持：

```latex
\( ... \)
\[ ... \]
```

这里有一个重要坑：CommonMark 解析阶段可能把 `\(` 当普通 backslash escape 处理。如果你在 `remark-parse` 之后的 text node 里找 `\(`，可能已经丢失原始 backslash。

所以中期有两个选择：

### 推荐做法

写 custom micromark extension：

```text
micromarkScopyBackslashMath
  \( ... \) -> inlineMath
  \[ ... \] -> math
```

这是最干净的。

### 临时做法

在 Markdown parse 前做一个 **只处理 explicit delimiter 的 protected tokenizer**：

```text
\(...\)
\[...\]
```

但它必须跳过：

```text
fenced code
inline code
link/image/reference
raw HTML
```

不要用全局 regex。

---

## 11. loose repair 在 unified 中应该怎么实现

不要把 Swift 里的 `MathNormalizer.wrapLooseLaTeX` 原样搬到 unified 前面。

正确做法是写：

```text
remarkScopyLooseMathRepair
```

它只访问 mdast 的普通 text node。

伪代码：

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

  if (candidates.length === 0) return;

  replaceTextNodeWithTextAndMathNodes(node, candidates);
});
```

protected ancestors：

```ts
function isProtectedAncestor(node) {
  return [
    "link",
    "image",
    "definition",
    "code",
    "inlineCode",
    "html",
    "footnoteDefinition"
  ].includes(node.type);
}
```

这就是 AST-first 的核心价值：`[label](/Users/xxx/file.md:25)` 的 destination 根本不会被当成 text node repair。

---

## 12. Safe HTML 迁移建议

你现在的 `MarkdownSafeHTMLSubset` 是手写 subset：

```text
comments removed
<details>
<summary>
<u>
<kbd>
<mark>
<sub>
<sup>
```

并且保护 fenced code。
测试也覆盖了 comments、details、inline tags、code fence、不碰 placeholder。

迁移时不要直接 `rehype-raw` 全开。

建议：

```text
Phase 3:
  继续使用当前 MarkdownSafeHTMLSubset

Phase 4:
  用 rehypeScopySafeHTML 复刻相同 subset
  配合 rehype-sanitize schema

默认:
  allowRawHTML = false
```

只有明确 profile 允许时才启用 raw HTML parsing。

---

## 13. KaTeX 渲染策略

### 当前

```text
Markdown -> HTML
-> restore escaped math placeholders
-> KaTeX auto-render scans DOM
```

当前 HTML 会加载：

```text
katex.min.css
katex.min.js
mhchem.min.js
auto-render.min.js
```

并配置 ignored tags。

### unified 目标

```text
Markdown AST
-> math node
-> rehype-katex
-> already-rendered KaTeX HTML
-> WKWebView
```

好处：

```text
不需要 auto-render 扫 DOM
preview/export 更一致
减少 render timing race
减少 __scopyRenderMath 重复调用
```

但你需要保留：

```text
katex.min.css
```

如果要继续支持 `\ce{}`：

```ts
import "katex/contrib/mhchem";
```

---

## 14. 对 `MarkdownPreviewWebView` 和 export 的影响

`MarkdownPreviewWebView` 不需要大改。它已经负责：

```text
loadHTMLString
baseURL = MarkdownPreview resources
network blocker
navigation policy
height report
math refresh fallback
```

统一 renderer 后，`window.__scopyRenderMath` 可以保留为 no-op 或只用于 legacy renderer。

`MarkdownExportService` 也不需要先改，因为它消费的是完整 HTML。它已经用 offscreen WKWebView 渲染同一份 HTML 并导出 PNG。

这正是为什么建议 unified 仍然输出同一种 HTML document，而不是引入 Pandoc/Quarto 的原因。

---

## 15. repo-specific regression tests

你已经有 `MarkdownMathRenderingTests`，可以直接补这些测试。

### 15.1 当前 bug 级别测试

```swift
func testMarkdownLinkDestinationLocalFilePathIsNotWrappedAsLooseMath() {
    let input = "[open](/Users/alice/my_file_v2.md:25)"

    let normalized = MathNormalizer.wrapLooseLaTeX(input)

    XCTAssertEqual(normalized, input)
    XCTAssertFalse(normalized.contains("\\left(/Users"))
    XCTAssertFalse(normalized.contains("$\\left"))
}
```

### 15.2 image path

```swift
func testMarkdownImageDestinationWithParenthesesIsNotWrappedAsLooseMath() {
    let input = "![img](/Users/alice/Pictures/img(1)_v2.png)"

    let normalized = MathNormalizer.wrapLooseLaTeX(input)

    XCTAssertEqual(normalized, input)
}
```

### 15.3 reference definition

```swift
func testReferenceDefinitionPathIsNotWrappedAsLooseMath() {
    let input = """
    [paper]: /Users/alice/papers/file_v2.md:25 "title"
    [open][paper]
    """

    let normalized = MathNormalizer.wrapLooseLaTeX(input)

    XCTAssertEqual(normalized, input)
}
```

### 15.4 link label with underscore

```swift
func testMarkdownLinkLabelWithUnderscoreIsNotLooseMathWrapped() {
    let input = "[x_i](/Users/alice/file.md:25)"

    let normalized = MathNormalizer.wrapLooseLaTeX(input)

    XCTAssertEqual(normalized, input)
}
```

### 15.5 URL query and currency

```swift
func testURLQueryAndCurrencyAreNotLooseMath() {
    let input = "[price](https://example.com/a_(b)?q=x_y&price=$20) costs $20."

    let normalized = MathNormalizer.wrapLooseLaTeX(input)

    XCTAssertEqual(normalized, input)
}
```

### 15.6 CJK path

```swift
func testCJKLocalPathIsNotLooseMath() {
    let input = "[打开](/Users/王小明/论文/第1章_v2.md:25)"

    let normalized = MathNormalizer.wrapLooseLaTeX(input)

    XCTAssertEqual(normalized, input)
}
```

### 15.7 explicit math inside link label still works

```swift
func testExplicitMathInsideLinkLabelSurvives() {
    let input = "[$x_i$](/Users/alice/file.md:25)"

    let html = MarkdownHTMLRenderer.render(markdown: input)

    XCTAssertTrue(html.contains("$x_i$"))
    XCTAssertTrue(html.contains("katex.min.js"))
}
```

### 15.8 authored Markdown should not run loose repair

```swift
func testAuthoredMarkdownPolicyDisablesLooseRepair() {
    let input = """
    [open](/Users/alice/file.md:25)

    Text: (T_{io}=12.4)ms
    """

    let context = MarkdownSourceProfileDetector.context(for: input)
    XCTAssertEqual(context.profile, .authoredMarkdown)
    XCTAssertFalse(context.policy.allowLooseMathRepair)
}
```

---

## 16. 建议的 PR 拆分

### PR 1：regression + hard reject

改：

```text
ScopyTests/MarkdownMathRenderingTests.swift
Scopy/Views/History/MathNormalizer.swift
```

加：

```text
path/url/currency hard reject
```

目标：马上修 `[label](/Users/xxx/file.md:25)`。

---

### PR 2：`MarkdownSyntaxProtector`

新增：

```text
Scopy/Views/History/MarkdownSyntaxProtector.swift
ScopyTests/MarkdownSyntaxProtectorTests.swift
```

改：

```text
MarkdownHTMLRenderer.render
```

目标：loose repair 不再碰 link/image/ref/code/html/url/path。

---

### PR 3：source profile + policy

新增：

```text
MarkdownRenderContext.swift
MarkdownSourceProfileDetector.swift
```

改：

```text
MarkdownDetector.swift
HistoryHoverPreviewPipeline.swift
MarkdownHTMLRenderer.swift
```

目标：`MarkdownDetector` 不再负责 repair policy。

---

### PR 4：renderer abstraction + cache namespace

新增：

```text
MarkdownPreviewRenderer.swift
LegacyMarkdownItHTMLRenderer.swift
UnifiedMarkdownHTMLRenderer.swift
```

改：

```text
HistoryHoverPreviewPipeline.MarkdownRenderRequest
MarkdownPreviewCache cache key
```

目标：支持 legacy/unified 并行，避免 cache 污染。

---

### PR 5：unified shadow renderer

新增：

```text
Tools/MarkdownRenderer/
Scopy/Resources/MarkdownPreview/scopy-unified-renderer.iife.js
```

改：

```text
project.yml 或 build script
MarkdownHTMLRenderer wrapper
```

目标：shadow 运行，不影响 UI。

---

### PR 6：先迁移 safe profiles

切换：

```text
authoredMarkdown
chatGPTMarkdown
plain markdown file
```

仍保留 legacy：

```text
latexDocumentLike
pdfOCRScientific
richHTML-heavy
unknown loose math
```

---

### PR 7：AST loose repair

实现：

```text
remarkScopyLooseMathRepair
```

迁移条件：

```text
现有 MarkdownMathRenderingTests 全通过
新增 corpus 全通过
preview/export PNG snapshot 没明显退化
```

---

## 17. 中期 renderer 选择的最终判断

### 选这个

```text
unified / remark / rehype + KaTeX
作为本地 JS bundle
在 WKWebView 中运行
legacy markdown-it fallback 保留
```

### 不选这个

```text
Pandoc default preview
Quarto
Mathpix Markdown default parser
MathJax full-page auto-render
markdown-it-texmath as root fix
全局 wrapLooseLaTeX
```

---

## 18. 最稳妥迁移路线

按你的 repo 状态，我建议的路线是：

```text
1. 先修 MathNormalizer 的 path/link false positive
2. 加 MarkdownSyntaxProtector
3. 加 source profile + repair policy
4. 把 MarkdownHTMLRenderer 抽象成 renderer facade
5. 加 unified shadow renderer
6. 只迁移 authored/chatgpt/plain markdown
7. 保留 legacy 处理 LaTeX document / PDF OCR scientific
8. 最后把 loose repair 从 Swift string normalizer 迁到 remark AST plugin
```

最重要的一点：

**不要把 Scopy 当前的 `MathNormalizer` 当成普通 Markdown math parser。它是 OCR/PDF/LaTeX repair engine，必须受 source profile 和 syntax island 保护。**

你的 repo 现在最大的问题不是库选错，而是 destructive transform 的边界不够清晰。中期引入 unified 是正确方向，但只有在完成：

```text
source profile
syntax island protection
renderer abstraction
cache namespace
regression corpus
```

之后再切，风险才可控。
