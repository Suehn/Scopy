import XCTest
import ScopyKit

final class MarkdownPreviewRendererFacadeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UnifiedMarkdownRenderer.bundleAvailabilityOverride = { true }
    }

    override func tearDown() {
        UnifiedMarkdownRenderer.bundleAvailabilityOverride = nil
        super.tearDown()
    }

    func testLegacyContextReturnsMarkdownItOutputAndDiagnostics() {
        let input = "Inline math: $x_1$ and [doc](/Users/alice/a.md:1)"
        let context = MarkdownRenderContextResolver.defaultContext(for: input, flags: .disabled)

        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertFalse(output.html.isEmpty)
        XCTAssertTrue(output.html.contains("markdown-it.min.js"))
        XCTAssertTrue(output.html.contains("window.__scopyIsRenderReady"))
        XCTAssertTrue(output.html.contains("[doc](/Users/alice/a.md:1)"))
        XCTAssertEqual(output.diagnostics.renderer, .legacyMarkdownIt)
        XCTAssertEqual(output.diagnostics.profile, .chatGPTMarkdown)
        XCTAssertGreaterThan(output.diagnostics.protectedIslandCount, 0)
        XCTAssertGreaterThan(output.diagnostics.explicitMathCount, 0)
    }

    func testDefaultResolverCutsChatGPTMarkdownToUnified() {
        let input = "Inline math: $x_1$ and [doc](/Users/alice/a.md:1)"

        let context = MarkdownRenderContextResolver.defaultContext(for: input)
        let directHTML = MarkdownHTMLRenderer.render(markdown: input)
        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertFalse(directHTML.isEmpty)
        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertEqual(output.diagnostics.profile, .chatGPTMarkdown)
        XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"))
        XCTAssertFalse(output.html.contains("markdown-it.min.js"))
    }

    func testUnifiedContextUsesUnifiedShellWhenRequested() {
        let input = "# Title\n\nText"
        let base = MarkdownRenderContextResolver.defaultContext(for: input)
        let unifiedContext = MarkdownRenderContext(
            renderer: .unified,
            profile: base.profile,
            policy: base.policy,
            policyVersion: base.policyVersion,
            cacheNamespace: base.cacheNamespace,
            layoutScale: base.layoutScale
        )

        let output = MarkdownHTMLRenderer.render(markdown: input, context: unifiedContext)

        XCTAssertFalse(output.html.isEmpty)
        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertNil(output.diagnostics.fallbackReason)
        XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"))
    }

    func testLayoutScaleControlsLayoutViewportWithoutChangingSurfaceWidth() {
        let input = "# Title\n\nMarkdown 是一种轻量标记语言。"
        let context = MarkdownRenderContextResolver.defaultContext(for: input, layoutScale: .percent125)

        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertEqual(context.layoutScale, .percent125)
        XCTAssertTrue(output.html.contains("--scopy-chatgpt-layout-font-scale: 1.0;"))
        XCTAssertTrue(output.html.contains("--scopy-chatgpt-browser-zoom: 1.25;"))
        XCTAssertTrue(output.html.contains("--scopy-chatgpt-inverse-browser-zoom: 0.8;"))
        XCTAssertTrue(output.html.contains("--scopy-chatgpt-thread-content-max-width: 768.0px;"))
        XCTAssertTrue(output.html.contains("--scopy-chatgpt-output-surface-width: 816.0px;"))
        XCTAssertTrue(output.html.contains("--scopy-chatgpt-layout-viewport-width:"))
        XCTAssertTrue(output.html.contains("--scopy-chatgpt-render-width: var(--scopy-chatgpt-layout-viewport-width);"))
        XCTAssertTrue(output.html.contains("width: calc(var(--scopy-chatgpt-render-width) * var(--scopy-chatgpt-preview-scale));"))
        XCTAssertTrue(output.html.contains("transform: scale(var(--scopy-chatgpt-preview-scale));"))
        XCTAssertTrue(output.html.contains("Math.max(1, Math.round(renderWidth * scale)) + 'px'"))
        XCTAssertEqual(MarkdownChatGPTLayoutScalePercent.percent100.fontScale, 1.0)
        XCTAssertEqual(MarkdownChatGPTLayoutScalePercent.percent125.fontScale, 1.0)
        XCTAssertEqual(MarkdownChatGPTLayoutScalePercent.percent125.layoutViewportWidth(outputSurfaceWidth: 816), 652.8, accuracy: 0.001)
        XCTAssertEqual(MarkdownRenderLayoutConstants.renderWidth(for: .percent100), 816)
        XCTAssertEqual(MarkdownRenderLayoutConstants.renderWidth(for: .percent125), 816)
    }

    func testDefaultResolverCutsAuthoredMarkdownToUnified() {
        let input = """
        # Title

        - item
        """

        let context = MarkdownRenderContextResolver.defaultContext(for: input)
        let directHTML = MarkdownHTMLRenderer.render(markdown: input)
        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertFalse(directHTML.isEmpty)
        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertEqual(output.diagnostics.profile, .authoredMarkdown)
        XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"))
        XCTAssertFalse(output.html.contains("markdown-it.min.js"))
    }

    func testDefaultResolverCutsAuthoredSafeHTMLMarkdownToUnified() {
        let input = """
        # Title

        行内 HTML：<kbd>Cmd</kbd> + <mark>K</mark>

        <details>
        <summary>More</summary>

        - item
        - **bold**

        </details>
        """

        let context = MarkdownRenderContextResolver.defaultContext(for: input)
        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertEqual(output.diagnostics.renderer, .unified)
        XCTAssertEqual(output.diagnostics.profile, .authoredMarkdown)
        XCTAssertTrue(output.html.contains("scopy-unified-renderer.iife.js"))
        XCTAssertFalse(output.html.contains("markdown-it.min.js"))
    }

    func testDefaultResolverKeepsHTMLContainerWithNestedMarkdownOnLegacy() {
        let input = """
        <details>
        <summary>More</summary>

        - item
        - **bold**

        </details>
        """

        let context = MarkdownRenderContextResolver.defaultContext(for: input)
        let output = MarkdownHTMLRenderer.render(markdown: input, context: context)

        XCTAssertEqual(output.diagnostics.renderer, .legacyMarkdownIt)
        XCTAssertEqual(output.diagnostics.profile, .richHTML)
        XCTAssertTrue(output.html.contains("markdown-it.min.js"))
        XCTAssertFalse(output.html.contains("scopy-unified-renderer.iife.js"))
    }

    func testUnifiedContextResolverUsesConservativePolicyAndNamespace() {
        let input = """
        # Title

        - item
        """
        let flags = MarkdownRendererFlagSet(
            forceLegacy: false,
            forceUnified: false,
            unifiedSafeProfilesEnabled: true,
            unifiedScientificEnabled: false,
            shadowUnifiedEnabled: false
        )

        let context = MarkdownRenderContextResolver.defaultContext(for: input, flags: flags)

        XCTAssertEqual(context.renderer, .unified)
        XCTAssertEqual(context.profile, .authoredMarkdown)
        XCTAssertFalse(context.policy.allowLooseMathRepair)
        XCTAssertFalse(context.policy.allowLatexDocumentNormalize)
        XCTAssertEqual(context.policyVersion, MarkdownRenderContextResolver.unifiedPolicyVersion)
        XCTAssertEqual(context.cacheNamespace, MarkdownRenderContextResolver.unifiedCacheNamespace)
    }
}
