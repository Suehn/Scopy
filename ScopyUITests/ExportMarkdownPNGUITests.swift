import XCTest
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor
final class ExportMarkdownPNGUITests: XCTestCase {

    private struct PNGProperties {
        let width: Int
        let height: Int
        let cgImage: CGImage
    }

    private struct TableMetric {
        let index: Int
        let cols: Int
        let width: Int
        let scrollWidth: Int
        let clientWidth: Int
        let wrapped: Bool
        let wrapperWidth: Int
        let scale: Double
        let targetWidth: Int
    }

    func testAutoExportMarkdownFixtureRendersStandardCase() throws {
        let fixture = fixturePath(relative: "Fixtures/rich_markdown.md")
        let dumpPath = "/tmp/scopy_uitest_export_rich_markdown.png"
        let errorPath = "/tmp/scopy_uitest_export_rich_markdown_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_EXPORT_PASTEBOARD_NAME"] = "ScopyUITests.ChatGPTRendering.\(UUID().uuidString)"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = fixture
        app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "100"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 20)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(props.height, 1_400)
        XCTAssertGreaterThan(nonWhiteContentHeight(props.cgImage), 1_100)
        XCTAssertLessThan(topWhitespaceRows(props.cgImage), 72)
        XCTAssertLessThan(bottomWhitespaceRows(props.cgImage), 120)
    }

    func testAutoExportChatGPTRichSurfacesFixtureProducesSubstantialOfflinePNG() throws {
        let fixture = fixturePath(relative: "Fixtures/chatgpt_rich_surfaces.md")
        let dumpPath = "/tmp/scopy_uitest_export_chatgpt_rich_surfaces.png"
        let errorPath = "/tmp/scopy_uitest_export_chatgpt_rich_surfaces_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_EXPORT_PASTEBOARD_NAME"] = "ScopyUITests.ChatGPTRichSurfaces.\(UUID().uuidString)"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = fixture
        app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "100"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(props.height, 1_500)
        XCTAssertGreaterThan(nonWhiteContentHeight(props.cgImage), 1_200)
        XCTAssertLessThan(topWhitespaceRows(props.cgImage), 72)
        XCTAssertLessThan(bottomWhitespaceRows(props.cgImage), 120)
    }

    func testAutoExportCodexIconsPreservesOriginalColors() throws {
        try assertUserFixtureExport(
            fixtureName: "markdown_codex_icons.md",
            dumpStem: "markdown_codex_icons",
            timeoutSeconds: 45,
            minimumHeight: 900,
            minimumContentHeight: 800,
            forcePaletteReduction: true
        )
        let data = try Data(contentsOf: URL(fileURLWithPath: "/tmp/scopy_uitest_export_markdown_codex_icons.png"))
        XCTAssertGreaterThan(data.count, 26)
        // IHDR color type must remain RGB/RGBA even when lossy export is enabled.
        XCTAssertTrue([UInt8(2), UInt8(6)].contains(data[25]))
    }

    func testAutoExportSourceIconsFixture() throws {
        try assertUserFixtureExport(
            fixtureName: "markdown_link_icons.md",
            dumpStem: "markdown_link_icons",
            timeoutSeconds: 45,
            minimumHeight: 800,
            minimumContentHeight: 600
        )
    }

    func testAutoExportUserMarkdownStressFixtureCompletesWithoutBlankOrTruncation() throws {
        try assertUserFixtureExport(
            fixtureName: "user_markdown_stress.md",
            dumpStem: "user_markdown_stress",
            timeoutSeconds: 90,
            minimumHeight: 8_000,
            minimumContentHeight: 6_000
        )
    }

    func testAutoExportCopiedChatGPTRichProseFixtureCompletesAsOrdinaryMarkdown() throws {
        try assertUserFixtureExport(
            fixtureName: "chatgpt_rich_copy_sample.md",
            dumpStem: "chatgpt_rich_copy_sample",
            timeoutSeconds: 45,
            minimumHeight: 1_200,
            minimumContentHeight: 900
        )
    }

    func testAutoExportExactPublicChatGPTCopyCompletesWithLocalImagesAndMath() throws {
        try assertUserFixtureExport(
            fixtureName: "chatgpt_public_copy_markdown_sample.md",
            dumpStem: "chatgpt_public_copy_markdown_sample",
            timeoutSeconds: 60,
            minimumHeight: 10_000,
            minimumContentHeight: 8_000
        )
    }

    func testAutoExportMarkdownProducesSinglePNGWidth1080() throws {
        let dumpPath = "/tmp/scopy_uitest_export.png"
        let errorPath = "/tmp/scopy_uitest_export_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 20)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080, "Expected PNG width to be 1080px")
        XCTAssertGreaterThan(props.height, 400, "Expected PNG height to be larger than a trivial snapshot")
    }

    func testClickExportButtonProducesSinglePNGWidth1080() throws {
        let dumpPath = "/tmp/scopy_uitest_export_click.png"
        let errorPath = "/tmp/scopy_uitest_export_click_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_EXPORT_HARNESS"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.anyElement("UITest.ExportPreviewHarness").waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)

        let exportButton = app.anyElement("UITest.ExportPreviewHarness.ExportNow")
        if exportButton.waitForExistence(timeout: 5) {
            exportButton.click()
        } else {
            // Overlay buttons on top of WebView can be hard to hit deterministically in XCUITest. Click a small grid near
            // the top-right area (and mirrored vertically for coordinate-origin differences) until export starts.
            let clickSurface = window
            // Prefer very-right clicks to avoid the resolution menu pill.
            let xs: [CGFloat] = [0.90, 0.94, 0.97, 0.99]
            let ys: [CGFloat] = [0.06, 0.09, 0.12, 0.88, 0.91, 0.94]
            for y in ys {
                for x in xs {
                    if FileManager.default.fileExists(atPath: dumpPath) { break }
                    if FileManager.default.fileExists(atPath: errorPath) { break }
                    clickSurface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                }
                if FileManager.default.fileExists(atPath: dumpPath) { break }
                if FileManager.default.fileExists(atPath: errorPath) { break }
            }
        }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080, "Expected PNG width to be 1080px")
        XCTAssertGreaterThan(props.height, 400, "Expected PNG height to be larger than a trivial snapshot")
    }

    func testClickExportButtonWithResolution2xProducesSinglePNGWidth2160() throws {
        let dumpPath = "/tmp/scopy_uitest_export_click_2x.png"
        let errorPath = "/tmp/scopy_uitest_export_click_2x_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_EXPORT_HARNESS"] = "1"
        app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "200"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.anyElement("UITest.ExportPreviewHarness").waitForExistence(timeout: 10))

        let window = app.windows.firstMatch
        XCTAssertTrue(window.exists)

        let exportButton = app.anyElement("UITest.ExportPreviewHarness.ExportNow")
        if exportButton.waitForExistence(timeout: 5) {
            exportButton.click()
        } else {
            // Overlay buttons on top of WebView can be hard to hit deterministically in XCUITest. Click a small grid near
            // the top-right area (and mirrored vertically for coordinate-origin differences) until export starts.
            let clickSurface = window
            let xs: [CGFloat] = [0.90, 0.94, 0.97, 0.99]
            let ys: [CGFloat] = [0.06, 0.09, 0.12, 0.88, 0.91, 0.94]
            for y in ys {
                for x in xs {
                    if FileManager.default.fileExists(atPath: dumpPath) { break }
                    if FileManager.default.fileExists(atPath: errorPath) { break }
                    clickSurface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                }
                if FileManager.default.fileExists(atPath: dumpPath) { break }
                if FileManager.default.fileExists(atPath: errorPath) { break }
            }
        }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 40)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 2160, "Expected PNG width to be 2160px (2x)")
        XCTAssertGreaterThan(props.height, 240, "Expected PNG height to be larger than a trivial snapshot")
    }

    func testExportResolution2xScalesContentComparedTo1x() throws {
        let fixture = fixturePath(relative: "Fixtures/resolution_scale.md")

        let dump1x = "/tmp/scopy_uitest_export_resolution_1x.png"
        let error1x = "/tmp/scopy_uitest_export_resolution_1x_error.txt"
        let dump2x = "/tmp/scopy_uitest_export_resolution_2x.png"
        let error2x = "/tmp/scopy_uitest_export_resolution_2x_error.txt"

        try? FileManager.default.removeItem(atPath: dump1x)
        try? FileManager.default.removeItem(atPath: error1x)
        try? FileManager.default.removeItem(atPath: dump2x)
        try? FileManager.default.removeItem(atPath: error2x)

        // 1x export
        do {
            let app = XCUIApplication()
            app.launchArguments = ["--uitesting"]
            app.launchEnvironment["SCOPY_UITEST_EXPORT_HARNESS"] = "1"
            app.launchEnvironment["SCOPY_UITEST_EXPORT_MARKDOWN_PATH"] = fixture
            app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "100"
            app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dump1x
            app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = error1x
            app.launch()
            defer { app.terminate() }

            XCTAssertTrue(app.anyElement("UITest.ExportPreviewHarness").waitForExistence(timeout: 10))

            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists)

            let exportButton = app.anyElement("UITest.ExportPreviewHarness.ExportNow")
            if exportButton.waitForExistence(timeout: 5) {
                exportButton.click()
            } else {
                let clickSurface = window
                let xs: [CGFloat] = [0.80, 0.86, 0.92, 0.96]
                let ys: [CGFloat] = [0.08, 0.12, 0.16, 0.84, 0.88, 0.92]
                for y in ys {
                    for x in xs {
                        if FileManager.default.fileExists(atPath: dump1x) { break }
                        if FileManager.default.fileExists(atPath: error1x) { break }
                        clickSurface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                    }
                    if FileManager.default.fileExists(atPath: dump1x) { break }
                    if FileManager.default.fileExists(atPath: error1x) { break }
                }
            }

            waitForExport(dumpPath: dump1x, errorPath: error1x, timeoutSeconds: 30)
            try assertNoExportError(errorPath: error1x)
        }

        // 2x export
        do {
            let app = XCUIApplication()
            app.launchArguments = ["--uitesting"]
            app.launchEnvironment["SCOPY_UITEST_EXPORT_HARNESS"] = "1"
            app.launchEnvironment["SCOPY_UITEST_EXPORT_MARKDOWN_PATH"] = fixture
            app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "200"
            app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dump2x
            app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = error2x
            app.launch()
            defer { app.terminate() }

            XCTAssertTrue(app.anyElement("UITest.ExportPreviewHarness").waitForExistence(timeout: 10))

            let window = app.windows.firstMatch
            XCTAssertTrue(window.exists)

            let exportButton = app.anyElement("UITest.ExportPreviewHarness.ExportNow")
            if exportButton.waitForExistence(timeout: 5) {
                exportButton.click()
            } else {
                let clickSurface = window
                let xs: [CGFloat] = [0.80, 0.86, 0.92, 0.96]
                let ys: [CGFloat] = [0.08, 0.12, 0.16, 0.84, 0.88, 0.92]
                for y in ys {
                    for x in xs {
                        if FileManager.default.fileExists(atPath: dump2x) { break }
                        if FileManager.default.fileExists(atPath: error2x) { break }
                        clickSurface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                    }
                    if FileManager.default.fileExists(atPath: dump2x) { break }
                    if FileManager.default.fileExists(atPath: error2x) { break }
                }
            }

            waitForExport(dumpPath: dump2x, errorPath: error2x, timeoutSeconds: 40)
            try assertNoExportError(errorPath: error2x)
        }

        let png1x = try readPNGProperties(atPath: dump1x)
        let png2x = try readPNGProperties(atPath: dump2x)
        XCTAssertEqual(png1x.width, 1080)
        XCTAssertEqual(png2x.width, 2160)

        let contentHeight1x = nonWhiteContentHeight(png1x.cgImage)
        let contentHeight2x = nonWhiteContentHeight(png2x.cgImage)
        XCTAssertGreaterThan(contentHeight1x, 40)
        XCTAssertGreaterThan(contentHeight2x, 80)

        let ratio = Double(contentHeight2x) / Double(max(1, contentHeight1x))
        XCTAssertGreaterThanOrEqual(ratio, 1.85, "Expected content height to scale ~2x. got ratio=\(ratio)")
        XCTAssertLessThanOrEqual(ratio, 2.15, "Expected content height to scale ~2x. got ratio=\(ratio)")
    }

    func testAutoExportWideCodeBlockWrapsInsteadOfClipping() throws {
        let markdownPath = "/tmp/scopy_uitest_export_wide_code.md"
        let dumpPath = "/tmp/scopy_uitest_export_wide_code.png"
        let errorPath = "/tmp/scopy_uitest_export_wide_code_error.txt"

        try? FileManager.default.removeItem(atPath: markdownPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let longToken = String(repeating: "veryLongIdentifier1234567890", count: 28)
        let markdown = """
        # Wide Code Export

        Below should wrap for PNG export, not clip at the right edge.

        ```swift
        let payload = "\(longToken)"
        ```
        """
        try Data(markdown.utf8).write(to: URL(fileURLWithPath: markdownPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = markdownPath
        app.launchEnvironment["SCOPY_EXPORT_DISABLE_PDF"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(
            props.height,
            420,
            "Expected wide code block export to wrap and become meaningfully taller, instead of staying as a clipped single line"
        )
        XCTAssertLessThan(bottomWhitespaceRows(props.cgImage), 120)
    }

    func testAutoExportCodeHighlightingKeepsColoredTokens() throws {
        let markdownPath = "/tmp/scopy_uitest_export_code_highlight.md"
        let dumpPath = "/tmp/scopy_uitest_export_code_highlight.png"
        let errorPath = "/tmp/scopy_uitest_export_code_highlight_error.txt"

        try? FileManager.default.removeItem(atPath: markdownPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let markdown = """
        # Highlight Export

        ```python
        def greet(name: str) -> str:
            return f"Hello, {name}!"
        ```
        """
        try Data(markdown.utf8).write(to: URL(fileURLWithPath: markdownPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = markdownPath
        app.launchEnvironment["SCOPY_EXPORT_DISABLE_PDF"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertTrue(
            imageHasMeaningfulNonGrayInk(props.cgImage),
            "Expected exported highlighted code block to retain colored syntax tokens instead of flattening to gray text"
        )
    }

    func testAutoExportSafeHTMLMarkdownUsesRenderedUnifiedPath() throws {
        let markdownPath = fixturePath(relative: "Fixtures/markdown_safe_html_torture.md")
        let dumpPath = "/tmp/scopy_uitest_export_safe_html_markdown.png"
        let errorPath = "/tmp/scopy_uitest_export_safe_html_markdown_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = markdownPath
        app.launchEnvironment["SCOPY_EXPORT_DISABLE_PDF"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(props.height, 1_200)
        XCTAssertLessThan(props.height, 3_800)
        XCTAssertGreaterThan(nonWhiteContentHeight(props.cgImage), 1_000)
        XCTAssertLessThan(topWhitespaceRows(props.cgImage), 72)
        XCTAssertLessThan(bottomWhitespaceRows(props.cgImage), 160)
    }

    func testAutoExportLongMarkdownDenseLinksKeepsBottomMarkerVisible() throws {
        let markdownPath = "/tmp/scopy_uitest_export_long_markdown.md"
        let dumpPath = "/tmp/scopy_uitest_export_long_markdown.png"
        let errorPath = "/tmp/scopy_uitest_export_long_markdown_error.txt"

        try? FileManager.default.removeItem(atPath: markdownPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let longTail = String(repeating: "segment-with-many-words-and-links-", count: 10)
        let rows = (1...320).map { index in
            let repoURL = "https://example.com/research/\(index)/\(longTail)\(index)"
            return """
            - Item \(index): [\(repoURL)](\(repoURL))

              这一段专门模拟长 Markdown 导出里的长链接、长段落和密集列表。第 \(index) 项会重复说明 export 不应在进入长图 tiled snapshot 后丢失末尾内容；同时保留大量可换行文本，逼近真实聊天导出。
            """
        }.joined(separator: "\n\n")

        let markerDataURL = try solidPNGDataURL(width: 1200, height: 96, color: NSColor(calibratedWhite: 0.07, alpha: 1))
        let markdown = """
        # Long Markdown Export Regression

        这份回归样本模拟了长对话导出：大量列表、长链接和连续段落会让导出高度在 export 态持续增长。

        \(rows)

        ## Tail Marker

        ![bottom-marker](\(markerDataURL))
        """
        try Data(markdown.utf8).write(to: URL(fileURLWithPath: markdownPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = markdownPath
        app.launchEnvironment["SCOPY_EXPORT_DISABLE_PDF"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 50)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(props.height, 24_000)
        XCTAssertLessThanOrEqual(topWhitespaceRows(props.cgImage), 72)
        XCTAssertLessThanOrEqual(bottomWhitespaceRows(props.cgImage), 24)
        XCTAssertLessThanOrEqual(
            maxInteriorMostlyWhiteRun(props.cgImage),
            80,
            "Expected long markdown export to stay continuous through the middle instead of introducing a large internal blank seam"
        )
        XCTAssertTrue(
            imageHasMostlyDarkBandNearBottom(props.cgImage, searchDepth: 220),
            "Expected the final dark marker near the end of a long markdown export to remain visible instead of being truncated"
        )
    }

    func testAutoExportTempFixtureTablesAreNotOverScaled() throws {
        let dumpPath = "/tmp/scopy_uitest_export_temp.png"
        let errorPath = "/tmp/scopy_uitest_export_temp_error.txt"
        let metricsPath = "/tmp/scopy_uitest_export_temp_table_metrics.json"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)
        try? FileManager.default.removeItem(atPath: metricsPath)

        let tempFixture = fixturePath(relative: "Fixtures/temp.txt")

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting", "-ScopyMarkdownExportResolutionPercent", "100"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = tempFixture
        app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "100"
        app.launchEnvironment["SCOPY_EXPORT_TABLE_METRICS_PATH"] = metricsPath
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let png = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(png.width, 1080)
        XCTAssertGreaterThan(png.height, 600)
        XCTAssertLessThanOrEqual(
            bottomWhitespaceRows(png.cgImage),
            96,
            "Expected export to trim excessive bottom whitespace for temp.txt"
        )

        let (targetWidth, tables) = try readTableMetrics(atPath: metricsPath)
        XCTAssertGreaterThan(targetWidth, 0)
        XCTAssertGreaterThanOrEqual(tables.count, 2)

        // This fixture includes moderate-width data tables (≈8–10 columns). They may be scaled down to fit, but should
        // not be squashed into a near-minimum transform scale (which would make the table unreadable).
        let candidateTables = tables.filter { $0.cols >= 8 }
        XCTAssertGreaterThanOrEqual(candidateTables.count, 2)

        for t in candidateTables {
            XCTAssertGreaterThanOrEqual(
                t.scale,
                0.40,
                "Expected table scale to remain reasonably readable for temp.txt. got scale=\(t.scale), cols=\(t.cols), width=\(t.width), targetWidth=\(targetWidth), wrapped=\(t.wrapped)"
            )
        }
    }

    func testAutoExportWritesOnlyPNGToPasteboard() throws {
        let pasteboardName = "ScopyUITests.ExportOnlyPNG.\(UUID().uuidString)"
        let dumpPath = "/tmp/scopy_uitest_export_pasteboard.png"
        let errorPath = "/tmp/scopy_uitest_export_pasteboard_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let pb = NSPasteboard(name: NSPasteboard.Name(pasteboardName))
        pb.clearContents()

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_PASTEBOARD_NAME"] = pasteboardName
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: errorPath) { break }
            if pb.data(forType: .png) != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }

        try assertNoExportError(errorPath: errorPath)

        guard let pngData = pb.data(forType: .png) else {
            XCTFail("Expected PNG data to be written to the export pasteboard")
            return
        }

        let types = pb.types ?? []
        XCTAssertTrue(types.contains(.png))
        // NOTE: macOS may expose additional derived image representations (e.g. TIFF) on the pasteboard for
        // compatibility even if we only write PNG. The contract we enforce here is: the source-of-truth payload
        // is PNG data (and we do not write PDF).
        XCTAssertFalse(types.contains(.pdf), "Expected pasteboard not to advertise PDF for export")
        XCTAssertNil(pb.data(forType: .pdf), "Expected pasteboard not to provide PDF data for export")
        XCTAssertEqual(Array(pngData.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else {
            XCTFail("Failed to read pasted PNG properties")
            return
        }

        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        XCTAssertEqual(width, 1080, "Expected pasted PNG width to be 1080px")
    }

    // MARK: - Helpers

    private func assertUserFixtureExport(
        fixtureName: String,
        dumpStem: String,
        timeoutSeconds: TimeInterval,
        minimumHeight: Int,
        minimumContentHeight: Int,
        forcePaletteReduction: Bool = false
    ) throws {
        let fixture = fixturePath(relative: "Fixtures/\(fixtureName)")
        let dumpPath = "/tmp/scopy_uitest_export_\(dumpStem).png"
        let errorPath = "/tmp/scopy_uitest_export_\(dumpStem)_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_EXPORT_PASTEBOARD_NAME"] = "ScopyUITests.UserFixture.\(UUID().uuidString)"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = fixture
        app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "100"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        if forcePaletteReduction {
            app.launchEnvironment["SCOPY_UITEST_FORCE_PNGQUANT_MARKDOWN_EXPORT"] = "1"
        }
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: timeoutSeconds)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(props.height, minimumHeight)
        XCTAssertGreaterThan(nonWhiteContentHeight(props.cgImage), minimumContentHeight)
        XCTAssertLessThan(topWhitespaceRows(props.cgImage), 72)
        XCTAssertLessThan(bottomWhitespaceRows(props.cgImage), 160)
    }

    private func waitForExport(dumpPath: String, errorPath: String, timeoutSeconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: dumpPath) { return }
            if FileManager.default.fileExists(atPath: errorPath) { return }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func assertNoExportError(errorPath: String) throws {
        guard FileManager.default.fileExists(atPath: errorPath) else { return }
        let msg = (try? String(contentsOfFile: errorPath, encoding: .utf8)) ?? "Unknown export error"
        XCTFail("Export failed: \(msg)")
        throw NSError(domain: "ScopyUITests", code: 999, userInfo: [NSLocalizedDescriptionKey: msg])
    }

    private func readPNGProperties(atPath path: String) throws -> PNGProperties {
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Expected export PNG at \(path)")

        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        XCTAssertGreaterThan(data.count, 16)
        XCTAssertEqual(Array(data.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw NSError(domain: "ScopyUITests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create CGImageSource from PNG"])
        }
        guard let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw NSError(domain: "ScopyUITests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to decode CGImage from PNG"])
        }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            throw NSError(domain: "ScopyUITests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to read PNG properties"])
        }

        let width = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        return PNGProperties(width: width, height: height, cgImage: cgImage)
    }

    private func fixturePath(relative: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent(relative)
            .path
    }

    private func readTableMetrics(atPath path: String) throws -> (targetWidth: Int, tables: [TableMetric]) {
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Expected table metrics file at \(path)")
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "ScopyUITests", code: 20, userInfo: [NSLocalizedDescriptionKey: "Invalid metrics JSON"])
        }

        let targetWidth = (obj["targetWidth"] as? NSNumber)?.intValue ?? 0
        let rawTables = obj["tables"] as? [[String: Any]] ?? []

        let tables: [TableMetric] = rawTables.compactMap { t in
            let index = (t["index"] as? NSNumber)?.intValue ?? 0
            let cols = (t["cols"] as? NSNumber)?.intValue ?? 0
            let width = (t["width"] as? NSNumber)?.intValue ?? 0
            let scrollWidth = (t["scrollWidth"] as? NSNumber)?.intValue ?? 0
            let clientWidth = (t["clientWidth"] as? NSNumber)?.intValue ?? 0
            let wrapped = (t["wrapped"] as? Bool) ?? false
            let wrapperWidth = (t["wrapperWidth"] as? NSNumber)?.intValue ?? 0
            let scale = (t["scale"] as? NSNumber)?.doubleValue ?? 1.0
            let perTargetWidth = (t["targetWidth"] as? NSNumber)?.intValue ?? targetWidth
            return TableMetric(
                index: index,
                cols: cols,
                width: width,
                scrollWidth: scrollWidth,
                clientWidth: clientWidth,
                wrapped: wrapped,
                wrapperWidth: wrapperWidth,
                scale: scale,
                targetWidth: perTargetWidth
            )
        }

        return (targetWidth: targetWidth, tables: tables)
    }

    private func bottomWhitespaceRows(_ image: CGImage) -> Int {
        let w = image.width
        let h = image.height
        guard w > 8, h > 8 else { return 0 }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return 0
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let stepX = 8
        let whiteThreshold: UInt8 = 250
        func rowIsMostlyWhite(_ y: Int) -> Bool {
            let start = y * bytesPerRow
            var darkCount = 0
            var sampleCount = 0

            var x = 0
            while x < w {
                let idx = start + x * 4
                if idx + 2 < pixels.count {
                    let r = pixels[idx]
                    let g = pixels[idx + 1]
                    let b = pixels[idx + 2]
                    if r < whiteThreshold || g < whiteThreshold || b < whiteThreshold {
                        darkCount += 1
                    }
                    sampleCount += 1
                }
                x += stepX
            }

            return darkCount <= max(6, sampleCount / 180)
        }

        // CGBitmapContext row 0 is the visual top; scan backward from the visual bottom.
        for y in stride(from: h - 1, through: 0, by: -1) {
            if !rowIsMostlyWhite(y) {
                return max(0, (h - 1) - y)
            }
        }

        return h
    }

    private func topWhitespaceRows(_ image: CGImage) -> Int {
        let w = image.width
        let h = image.height
        guard w > 8, h > 8 else { return 0 }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return 0
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let stepX = 8
        let whiteThreshold: UInt8 = 250
        func rowIsMostlyWhite(_ y: Int) -> Bool {
            let start = y * bytesPerRow
            var darkCount = 0
            var sampleCount = 0

            var x = 0
            while x < w {
                let idx = start + x * 4
                if idx + 2 < pixels.count {
                    let r = pixels[idx]
                    let g = pixels[idx + 1]
                    let b = pixels[idx + 2]
                    if r < whiteThreshold || g < whiteThreshold || b < whiteThreshold {
                        darkCount += 1
                    }
                    sampleCount += 1
                }
                x += stepX
            }

            return darkCount <= max(6, sampleCount / 180)
        }

        // CGBitmapContext row 0 is the visual top.
        for y in 0..<h {
            if !rowIsMostlyWhite(y) {
                return y
            }
        }

        return h
    }

    private func nonWhiteContentHeight(_ image: CGImage) -> Int {
        let w = image.width
        let h = image.height
        guard w > 8, h > 8 else { return 0 }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return 0
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let stepX = 4
        let whiteThreshold: UInt8 = 245
        func rowHasContent(_ y: Int) -> Bool {
            let start = y * bytesPerRow
            var x = 0
            while x < w {
                let idx = start + x * 4
                if idx + 2 < pixels.count {
                    let r = pixels[idx]
                    let g = pixels[idx + 1]
                    let b = pixels[idx + 2]
                    if r < whiteThreshold || g < whiteThreshold || b < whiteThreshold {
                        return true
                    }
                }
                x += stepX
            }
            return false
        }

        var minY: Int?
        var maxY: Int?
        for y in 0..<h {
            if rowHasContent(y) {
                if minY == nil { minY = y }
                maxY = y
            }
        }
        guard let minY, let maxY else { return 0 }
        return max(0, maxY - minY + 1)
    }

    private func maxInteriorMostlyWhiteRun(_ image: CGImage) -> Int {
        let w = image.width
        let h = image.height
        guard w > 8, h > 8 else { return 0 }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return 0
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let stepX = 8
        let whiteThreshold: UInt8 = 250
        let ignoreMargin = min(16, max(0, h / 40))

        func rowIsMostlyWhite(_ y: Int) -> Bool {
            let start = y * bytesPerRow
            var darkCount = 0
            var sampleCount = 0
            var x = 0
            while x < w {
                let idx = start + x * 4
                if idx + 2 < pixels.count {
                    let r = pixels[idx]
                    let g = pixels[idx + 1]
                    let b = pixels[idx + 2]
                    if r < whiteThreshold || g < whiteThreshold || b < whiteThreshold {
                        darkCount += 1
                    }
                    sampleCount += 1
                }
                x += stepX
            }
            return darkCount <= max(6, sampleCount / 180)
        }

        var longestRun = 0
        var currentRun = 0
        for y in ignoreMargin..<(h - ignoreMargin) {
            if rowIsMostlyWhite(y) {
                currentRun += 1
                longestRun = max(longestRun, currentRun)
            } else {
                currentRun = 0
            }
        }
        return longestRun
    }

    private func imageHasMostlyDarkBandNearBottom(_ image: CGImage, searchDepth: Int) -> Bool {
        let w = image.width
        let h = image.height
        guard w > 16, h > 16 else { return false }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let depth = max(1, min(searchDepth, h))
        let startY = max(0, h - depth)
        let sampleStep = max(1, w / 180)
        for y in startY..<h {
            var darkSamples = 0
            var totalSamples = 0
            var x = 0
            while x < w {
                let idx = y * bytesPerRow + x * 4
                if idx + 2 < pixels.count {
                    let r = pixels[idx]
                    let g = pixels[idx + 1]
                    let b = pixels[idx + 2]
                    if r < 48 && g < 48 && b < 48 {
                        darkSamples += 1
                    }
                    totalSamples += 1
                }
                x += sampleStep
            }

            if totalSamples > 0 && Double(darkSamples) / Double(totalSamples) >= 0.60 {
                return true
            }
        }

        return false
    }

    private func imageHasMeaningfulNonGrayInk(_ image: CGImage) -> Bool {
        let w = image.width
        let h = image.height
        guard w > 16, h > 16 else { return false }

        let bytesPerRow = w * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * h)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let sampleStepX = max(1, w / 180)
        let sampleStepY = max(1, h / 140)
        var colorfulSamples = 0
        var eligibleSamples = 0

        var y = 0
        while y < h {
            var x = 0
            while x < w {
                let idx = y * bytesPerRow + x * 4
                if idx + 2 < pixels.count {
                    let r = Int(pixels[idx])
                    let g = Int(pixels[idx + 1])
                    let b = Int(pixels[idx + 2])
                    let maxChannel = max(r, g, b)
                    let minChannel = min(r, g, b)
                    if maxChannel < 245 {
                        eligibleSamples += 1
                        if (maxChannel - minChannel) >= 18 {
                            colorfulSamples += 1
                        }
                    }
                }
                x += sampleStepX
            }
            y += sampleStepY
        }

        guard eligibleSamples > 0 else { return false }
        return colorfulSamples >= max(24, eligibleSamples / 40)
    }

    private func solidPNGDataURL(width: Int, height: Int, color: NSColor) throws -> String {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else {
            throw NSError(domain: "ScopyUITests", code: 31, userInfo: [NSLocalizedDescriptionKey: "Failed to allocate marker bitmap"])
        }

        NSGraphicsContext.saveGraphicsState()
        guard let graphicsContext = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState()
            throw NSError(domain: "ScopyUITests", code: 32, userInfo: [NSLocalizedDescriptionKey: "Failed to create marker graphics context"])
        }

        NSGraphicsContext.current = graphicsContext
        color.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: width, height: height)).fill()
        graphicsContext.flushGraphics()
        NSGraphicsContext.restoreGraphicsState()

        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ScopyUITests", code: 33, userInfo: [NSLocalizedDescriptionKey: "Failed to encode marker PNG"])
        }

        return "data:image/png;base64,\(data.base64EncodedString())"
    }
}
