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

    func testClickExportButtonWithResolution1_5xProducesSinglePNGWidth1620() throws {
        let dumpPath = "/tmp/scopy_uitest_export_click_1_5x.png"
        let errorPath = "/tmp/scopy_uitest_export_click_1_5x_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_EXPORT_HARNESS"] = "1"
        app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "150"
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
        XCTAssertEqual(props.width, 1620, "Expected PNG width to be 1620px (1.5x)")
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

    func testExportResolution1_5xScalesContentComparedTo1x() throws {
        let fixture = fixturePath(relative: "Fixtures/resolution_scale.md")

        let dump1x = "/tmp/scopy_uitest_export_resolution_1x.png"
        let error1x = "/tmp/scopy_uitest_export_resolution_1x_error.txt"
        let dump1_5x = "/tmp/scopy_uitest_export_resolution_1_5x.png"
        let error1_5x = "/tmp/scopy_uitest_export_resolution_1_5x_error.txt"

        try? FileManager.default.removeItem(atPath: dump1x)
        try? FileManager.default.removeItem(atPath: error1x)
        try? FileManager.default.removeItem(atPath: dump1_5x)
        try? FileManager.default.removeItem(atPath: error1_5x)

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

        // 1.5x export
        do {
            let app = XCUIApplication()
            app.launchArguments = ["--uitesting"]
            app.launchEnvironment["SCOPY_UITEST_EXPORT_HARNESS"] = "1"
            app.launchEnvironment["SCOPY_UITEST_EXPORT_MARKDOWN_PATH"] = fixture
            app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "150"
            app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dump1_5x
            app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = error1_5x
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
                        if FileManager.default.fileExists(atPath: dump1_5x) { break }
                        if FileManager.default.fileExists(atPath: error1_5x) { break }
                        clickSurface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
                        RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                    }
                    if FileManager.default.fileExists(atPath: dump1_5x) { break }
                    if FileManager.default.fileExists(atPath: error1_5x) { break }
                }
            }

            waitForExport(dumpPath: dump1_5x, errorPath: error1_5x, timeoutSeconds: 40)
            try assertNoExportError(errorPath: error1_5x)
        }

        let png1x = try readPNGProperties(atPath: dump1x)
        let png1_5x = try readPNGProperties(atPath: dump1_5x)
        XCTAssertEqual(png1x.width, 1080)
        XCTAssertEqual(png1_5x.width, 1620)

        let contentHeight1x = nonWhiteContentHeight(png1x.cgImage)
        let contentHeight1_5x = nonWhiteContentHeight(png1_5x.cgImage)
        XCTAssertGreaterThan(contentHeight1x, 40)
        XCTAssertGreaterThan(contentHeight1_5x, 60)

        let ratio = Double(contentHeight1_5x) / Double(max(1, contentHeight1x))
        XCTAssertGreaterThanOrEqual(ratio, 1.35, "Expected content height to scale ~1.5x. got ratio=\(ratio)")
        XCTAssertLessThanOrEqual(ratio, 1.65, "Expected content height to scale ~1.5x. got ratio=\(ratio)")
    }

    func testExportResolution2xDoesNotLeaveBlankRightWhenGlobalScaleApplies() throws {
        let metricsPath = "/tmp/scopy_uitest_export_resolution_wide_long_2x_metrics.json"
        let htmlPath = "/tmp/scopy_uitest_export_resolution_wide_long_\(UUID().uuidString).html"

        // Use a deterministic tall spacer to trigger global-scale without expensive reflow from hundreds of paragraphs.
        // This keeps the test fast while still exercising the global-scale + PDF pipeline.
        let bodyHTML = """
        <h1>SCOPY_EXPORT_RESOLUTION_WIDE_LONG_PDF</h1>
        <p>Spacer below should be scaled by global export scale.</p>
        <div style="height: 16000px;"></div>
        """
        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              :root { color-scheme: light; }
              html, body { margin: 0; padding: 0; background: #fff; color: #000; font: -apple-system-body; }
              #content {
                box-sizing: border-box;
                padding: 16px;
                width: 100%;
                border-right: 80px solid #000;
              }
              h1 { margin: 0 0 12px 0; font-size: 20px; }
              p { margin: 0 0 10px 0; }
            </style>
          </head>
          <body>
            <div id="content">
              <h1>SCOPY_EXPORT_RESOLUTION_WIDE_LONG</h1>
              \(bodyHTML)
            </div>
          </body>
        </html>
        """
        try Data(html.utf8).write(to: URL(fileURLWithPath: htmlPath), options: [.atomic])

        let dumpPath = "/tmp/scopy_uitest_export_resolution_wide_long_2x.png"
        let errorPath = "/tmp/scopy_uitest_export_resolution_wide_long_2x_error.txt"

        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)
        try? FileManager.default.removeItem(atPath: metricsPath)

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_EXPORT_HARNESS"] = "1"
        app.launchEnvironment["SCOPY_UITEST_EXPORT_HTML_PATH"] = htmlPath
        app.launchEnvironment["SCOPY_UITEST_MARKDOWN_EXPORT_RESOLUTION"] = "200"
        // Reduce pixel budget to make global-scale kick in quickly, keeping the test fast and deterministic.
        app.launchEnvironment["SCOPY_UITEST_EXPORT_MAX_TOTAL_PIXELS"] = "10000000"
        app.launchEnvironment["SCOPY_EXPORT_TABLE_METRICS_PATH"] = metricsPath
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
            let xs: [CGFloat] = [0.80, 0.86, 0.92, 0.96]
            let ys: [CGFloat] = [0.08, 0.12, 0.16, 0.84, 0.88, 0.92]
            for y in ys {
                for x in xs {
                    if FileManager.default.fileExists(atPath: dumpPath) { break }
                    if FileManager.default.fileExists(atPath: errorPath) { break }
                    clickSurface.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
                }
                if FileManager.default.fileExists(atPath: dumpPath) { break }
                if FileManager.default.fileExists(atPath: errorPath) { break }
            }
        }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 40)
        try assertNoExportError(errorPath: errorPath)

        let png = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(png.width, 2160)
        XCTAssertGreaterThan(png.height, 800)

        let metricsDebug: String = {
            guard FileManager.default.fileExists(atPath: metricsPath) else { return "no-metrics" }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: metricsPath)),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            else { return "invalid-metrics" }

            let exportScale = (obj["exportScale"] as? NSNumber)?.doubleValue ?? 0
            let usesTransform = (obj["usesTransform"] as? Bool) ?? false
            let innerWidth = (obj["innerWidth"] as? NSNumber)?.intValue ?? 0
            let contentRectWidth = (obj["contentRectWidth"] as? NSNumber)?.intValue ?? 0
            let contentScrollWidth = (obj["contentScrollWidth"] as? NSNumber)?.intValue ?? 0
            let contentStyleWidth = (obj["contentStyleWidth"] as? String) ?? ""
            let contentStyleTransform = (obj["contentStyleTransform"] as? String) ?? ""
            let bodyOverflowX = (obj["bodyOverflowX"] as? String) ?? ""
            let htmlOverflowX = (obj["htmlOverflowX"] as? String) ?? ""
            return "exportScale=\(exportScale) usesTransform=\(usesTransform) innerWidth=\(innerWidth) contentRectWidth=\(contentRectWidth) contentScrollWidth=\(contentScrollWidth) contentStyleWidth=\(contentStyleWidth) contentStyleTransform=\(contentStyleTransform) overflowX(body=\(bodyOverflowX),html=\(htmlOverflowX))"
        }()

        XCTAssertTrue(
            imageHasDarkPixelNearRightEdge(png.cgImage, tolerancePixels: 200),
            "Expected content to reach near the right edge under global-scale; if missing, export may leave a blank right margin. metrics=\(metricsDebug)"
        )
    }

    func testAutoExportGlobalScalePDFDoesNotLeaveBlankRight() throws {
        let htmlPath = "/tmp/scopy_uitest_export_global_scale_pdf.html"
        let dumpPath = "/tmp/scopy_uitest_export_global_scale_pdf.png"
        let errorPath = "/tmp/scopy_uitest_export_global_scale_pdf_error.txt"

        try? FileManager.default.removeItem(atPath: htmlPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              :root { color-scheme: light; }
              html, body { margin: 0; padding: 0; background: #fff; color: #000; font: -apple-system-body; }
              #content {
                box-sizing: border-box;
                padding: 16px;
                width: 100%;
                border-right: 80px solid #000;
              }
              h1 { margin: 0 0 12px 0; font-size: 20px; }
              p { margin: 0 0 10px 0; }
            </style>
          </head>
          <body>
            <div id="content">
              <h1>SCOPY_EXPORT_GLOBAL_SCALE_PDF</h1>
              <p>Spacer below should be scaled by global export scale.</p>
              <div style="height: 8000px;"></div>
            </div>
          </body>
        </html>
        """
        try Data(html.utf8).write(to: URL(fileURLWithPath: htmlPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"] = htmlPath
        app.launchEnvironment["SCOPY_UITEST_ENABLE_PDF_EXPORT"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_REQUIRE_PDF"] = "1"
        // Force global-scale in a controlled way while keeping the export reasonably fast.
        // Keep a small buffer above 10M to avoid rounding pushing rasterization just over the limit.
        app.launchEnvironment["SCOPY_UITEST_EXPORT_MAX_TOTAL_PIXELS"] = "10000000"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 40)
        try assertNoExportError(errorPath: errorPath)

        let png = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(png.width, 1080)
        XCTAssertGreaterThan(png.height, 800)

        XCTAssertTrue(
            imageHasDarkPixelNearRightEdge(png.cgImage, tolerancePixels: 200),
            "Expected content to reach near the right edge under global-scale in PDF export; if missing, export may leave a blank right margin."
        )
    }

    func testAutoExportHTMLDelayedHeightStillExportsSinglePNGWidth1080() throws {
        let htmlPath = "/tmp/scopy_uitest_export_delayed.html"
        let dumpPath = "/tmp/scopy_uitest_export_delayed.png"
        let errorPath = "/tmp/scopy_uitest_export_delayed_error.txt"

        try? FileManager.default.removeItem(atPath: htmlPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              body { margin: 0; padding: 0; font: -apple-system-body; }
              #content { padding: 16px; display: inline-block; }
              table { border-collapse: collapse; }
              th, td { border: 1px solid #888; padding: 6px 8px; }
            </style>
          </head>
          <body>
            <div id="content"></div>
            <script>
              // Simulate async render (e.g. markdown-it / KaTeX / fonts) so initial height is 0.
              setTimeout(function () {
                var el = document.getElementById('content');
                if (!el) { return; }
                var rows = [];
                rows.push('<h1>Delayed Render</h1>');
                rows.push('<p>Line 1</p>');
                rows.push('<p>Line 2</p>');
                rows.push('<p>Line 3</p>');
                rows.push('<p>Line 4</p>');
                rows.push('<p>Line 5</p>');
                rows.push('<h2>Wide Table</h2>');
                rows.push('<table><thead><tr>' +
                  '<th>very_long_header_col_01</th><th>very_long_header_col_02</th><th>very_long_header_col_03</th><th>very_long_header_col_04</th>' +
                  '<th>very_long_header_col_05</th><th>very_long_header_col_06</th><th>very_long_header_col_07</th><th>very_long_header_col_08</th>' +
                  '<th>very_long_header_col_09</th><th>very_long_header_col_10</th>' +
                '</tr></thead><tbody>' +
                  '<tr><td>1</td><td>2</td><td>3</td><td>4</td><td>5</td><td>6</td><td>7</td><td>8</td><td>9</td><td>10</td></tr>' +
                '</tbody></table>');
                el.innerHTML = rows.join('');
              }, 350);
            </script>
          </body>
        </html>
        """
        try Data(html.utf8).write(to: URL(fileURLWithPath: htmlPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"] = htmlPath
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 25)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080, "Expected PNG width to be 1080px")
        XCTAssertGreaterThan(props.height, 500, "Expected delayed content export to capture full content height")
    }

    func testAutoExportShortContentIsNotPaddedToLargeHeight() throws {
        let htmlPath = "/tmp/scopy_uitest_export_short.html"
        let dumpPath = "/tmp/scopy_uitest_export_short.png"
        let errorPath = "/tmp/scopy_uitest_export_short_error.txt"

        try? FileManager.default.removeItem(atPath: htmlPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              :root { color-scheme: light; }
              html, body { margin: 0; padding: 0; background: #fff; color: #000; font: -apple-system-body; }
              #content { padding: 16px; display: inline-block; }
            </style>
          </head>
          <body>
            <div id="content">
              <h1>Short</h1>
              <p>Two lines.</p>
            </div>
          </body>
        </html>
        """
        try Data(html.utf8).write(to: URL(fileURLWithPath: htmlPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"] = htmlPath
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 20)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080, "Expected PNG width to be 1080px")
        XCTAssertLessThan(props.height, 900, "Expected short content export to have dynamic (small) height, not a padded large canvas")
        XCTAssertGreaterThan(props.height, 200, "Expected short content export height to be non-trivial (background + padding)")
    }

    func testAutoExportWideTableFitsWidthWithoutOverShrink() throws {
        let htmlPath = "/tmp/scopy_uitest_export_widetable.html"
        let dumpPath = "/tmp/scopy_uitest_export_widetable.png"
        let errorPath = "/tmp/scopy_uitest_export_widetable_error.txt"

        try? FileManager.default.removeItem(atPath: htmlPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              html, body { margin: 0; padding: 0; background: #fff; color: #000; font: -apple-system-body; }
              #content { padding: 0; }
              table { border-collapse: collapse; margin: 0; }
              th, td { border: 1px solid #000; padding: 6px 10px; white-space: nowrap; min-width: 240px; }
              td.last { background: rgb(0, 0, 0) !important; }
            </style>
          </head>
          <body>
            <div id="content">
              <h1>Wide Table Fit Test</h1>
              <p>Only the last column has a solid black background; it should touch the right edge after scaling.</p>
              <table id="t"></table>
            </div>
            <script>
              (function () {
                var cols = 60; // wide enough to force scaling
                var tbl = document.getElementById('t');
                var h = '<thead><tr>';
                for (var i = 1; i <= cols; i++) { h += '<th>col_' + i + '</th>'; }
                h += '</tr></thead>';
                var r1 = '<tr>';
                for (var j = 1; j <= cols; j++) {
                  r1 += '<td' + (j === cols ? ' class="last"' : '') + '>' + j + '</td>';
                }
                r1 += '</tr>';
                var r2 = '<tr>';
                for (var k = 1; k <= cols; k++) {
                  r2 += '<td' + (k === cols ? ' class="last"' : '') + '>' + (k * 2) + '</td>';
                }
                r2 += '</tr>';
                tbl.innerHTML = h + '<tbody>' + r1 + r2 + '</tbody>';
              })();
            </script>
          </body>
        </html>
        """
        try Data(html.utf8).write(to: URL(fileURLWithPath: htmlPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"] = htmlPath
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(props.height, 160)

        XCTAssertTrue(
            imageHasDarkPixelNearRightEdge(props.cgImage, tolerancePixels: 40),
            "Expected dark pixels near the right edge (≤40px) from the table last-column background/border; if missing, table likely scaled too small."
        )
    }

    func testAutoExportWideTablePDFStillFitsWidthWithoutOverShrink() throws {
        let htmlPath = "/tmp/scopy_uitest_export_widetable_pdf.html"
        let dumpPath = "/tmp/scopy_uitest_export_widetable_pdf.png"
        let errorPath = "/tmp/scopy_uitest_export_widetable_pdf_error.txt"

        try? FileManager.default.removeItem(atPath: htmlPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              html, body { margin: 0; padding: 0; background: #fff; color: #000; font: -apple-system-body; }
              #content { padding: 0; }
              table { border-collapse: collapse; margin: 0; }
              th, td { border: 1px solid #000; padding: 6px 10px; white-space: nowrap; min-width: 240px; }
              td.last { background: rgb(0, 0, 0) !important; }
            </style>
          </head>
          <body>
            <div id="content">
              <h1>Wide Table Fit Test (PDF)</h1>
              <p>Only the last column has a solid black background; it should touch the right edge after scaling.</p>
              <table id="t"></table>
            </div>
            <script>
              (function () {
                var cols = 60; // wide enough to force scaling
                var tbl = document.getElementById('t');
                var h = '<thead><tr>';
                for (var i = 1; i <= cols; i++) { h += '<th>col_' + i + '</th>'; }
                h += '</tr></thead>';
                var r1 = '<tr>';
                for (var j = 1; j <= cols; j++) {
                  r1 += '<td' + (j === cols ? ' class="last"' : '') + '>' + j + '</td>';
                }
                r1 += '</tr>';
                var r2 = '<tr>';
                for (var k = 1; k <= cols; k++) {
                  r2 += '<td' + (k === cols ? ' class="last"' : '') + '>' + (k * 2) + '</td>';
                }
                r2 += '</tr>';
                tbl.innerHTML = h + '<tbody>' + r1 + r2 + '</tbody>';
              })();
            </script>
          </body>
        </html>
        """
        try Data(html.utf8).write(to: URL(fileURLWithPath: htmlPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"] = htmlPath
        app.launchEnvironment["SCOPY_UITEST_ENABLE_PDF_EXPORT"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_REQUIRE_PDF"] = "1"
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 50)
        try assertNoExportError(errorPath: errorPath)

        let props = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(props.width, 1080)
        XCTAssertGreaterThan(props.height, 160)

        XCTAssertTrue(
            imageHasDarkPixelNearRightEdge(props.cgImage, tolerancePixels: 40),
            "Expected dark pixels near the right edge (≤40px) from the table last-column background/border under PDF export; if missing, table likely did not scale to fit."
        )
    }

    func testAutoExportModeratelyWideTableScalesDownInsteadOfWrapping() throws {
        let htmlPath = "/tmp/scopy_uitest_export_mediumtable.html"
        let dumpPath = "/tmp/scopy_uitest_export_mediumtable.png"
        let errorPath = "/tmp/scopy_uitest_export_mediumtable_error.txt"
        let metricsPath = "/tmp/scopy_uitest_export_mediumtable_metrics.json"

        try? FileManager.default.removeItem(atPath: htmlPath)
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)
        try? FileManager.default.removeItem(atPath: metricsPath)

        // A 10-column table that should require downscaling. We validate the export pipeline uses transform scaling
        // (like previous behavior), rather than squeezing columns / wrapping content to "fit".
        let html = """
        <!doctype html>
        <html>
          <head>
            <meta charset="utf-8">
            <meta name="viewport" content="width=device-width, initial-scale=1">
            <style>
              :root { color-scheme: light; }
              html, body { margin: 0; padding: 0; background: #fff; color: #000; font: -apple-system-body; }
              #content { padding: 0; }
              table { display: block; overflow-x: auto; border-collapse: collapse; margin: 0; width: 100%; }
              th, td { border: 1px solid #000; padding: 6px 10px; white-space: nowrap; overflow-wrap: normal; word-break: normal; }
            </style>
          </head>
          <body>
            <div id="content">
              <h1>Moderate Table Scale Test</h1>
              <table id="t">
                <thead>
                  <tr>
                    <th>col_1</th><th>col_2</th><th>col_3</th><th>col_4</th><th>col_5</th>
                    <th>col_6</th><th>col_7</th><th>col_8</th><th>col_9</th><th>col_10</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>AAAAAAAAAAAAAA</td><td>BBBBBBBBBBBBBB</td><td>CCCCCCCCCCCCCC</td><td>DDDDDDDDDDDDDD</td><td>EEEEEEEEEEEEEE</td>
                    <td>FFFFFFFFFFFFFF</td><td>GGGGGGGGGGGGGG</td><td>HHHHHHHHHHHHHH</td><td>IIIIIIIIIIIIII</td><td>JJJJJJJJJJJJJJ</td>
                  </tr>
                </tbody>
              </table>
            </div>
          </body>
        </html>
        """
        try Data(html.utf8).write(to: URL(fileURLWithPath: htmlPath), options: [.atomic])

        let app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"] = htmlPath
        app.launchEnvironment["SCOPY_EXPORT_TABLE_METRICS_PATH"] = metricsPath
        app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        app.launch()
        defer { app.terminate() }

        waitForExport(dumpPath: dumpPath, errorPath: errorPath, timeoutSeconds: 30)
        try assertNoExportError(errorPath: errorPath)

        let png = try readPNGProperties(atPath: dumpPath)
        XCTAssertEqual(png.width, 1080)
        XCTAssertGreaterThan(png.height, 120)

        let (_, tables) = try readTableMetrics(atPath: metricsPath)
        XCTAssertGreaterThanOrEqual(tables.count, 1)

        guard let table = tables.first(where: { $0.cols == 10 }) else {
            XCTFail("Expected a 10-column table entry in table metrics")
            return
        }

        XCTAssertTrue(table.wrapped, "Expected export to wrap the table with a fixed-width wrapper before scaling. metric=\(table)")
        XCTAssertLessThan(
            table.scale,
            0.999,
            "Expected export to apply transform scaling (scale < 1). got scale=\(table.scale), width=\(table.width), targetWidth=\(table.targetWidth)"
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
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] = "1"
        app.launchEnvironment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"] = tempFixture
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

    private func imageHasDarkPixelNearRightEdge(_ image: CGImage, tolerancePixels: Int) -> Bool {
        let w = image.width
        let h = image.height
        guard w > 8, h > 8 else { return false }

        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let cs = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: &pixels,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: bitmapInfo
        ) else {
            return false
        }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        let tol = max(1, min(tolerancePixels, w - 1))
        let minX = max(0, w - 1 - tol)
        let step = max(1, h / 220)

        for y in stride(from: 0, to: h, by: step) {
            for x in stride(from: w - 2, through: minX, by: -1) {
                let i = (y * w + x) * 4
                if i + 2 >= pixels.count { continue }
                let r = pixels[i + 0]
                let g = pixels[i + 1]
                let b = pixels[i + 2]
                if r < 60 && g < 60 && b < 60 {
                    return true
                }
            }
        }

        return false
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

        // Scan from the bottom (bitmap context origin is bottom-left) until we find content.
        var firstNonWhiteFromBottomY: Int?
        for y in 0..<h {
            if !rowIsMostlyWhite(y) {
                firstNonWhiteFromBottomY = y
                break
            }
        }

        guard let firstNonWhiteFromBottomY else { return h }
        return max(0, firstNonWhiteFromBottomY)
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
}
