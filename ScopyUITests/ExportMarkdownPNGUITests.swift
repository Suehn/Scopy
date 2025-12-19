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

        let exportButton = app.buttons["History.Preview.ExportButton"]
        if exportButton.waitForExistence(timeout: 5) {
            exportButton.click()
        } else {
            // Overlay buttons on top of WebView can be hard to hit deterministically in XCUITest. Click a small grid near
            // the top-right area (and mirrored vertically for coordinate-origin differences) until export starts.
            let xs: [CGFloat] = [0.80, 0.86, 0.92, 0.96]
            let ys: [CGFloat] = [0.08, 0.12, 0.16, 0.84, 0.88, 0.92]
            for y in ys {
                for x in xs {
                    if FileManager.default.fileExists(atPath: dumpPath) { break }
                    if FileManager.default.fileExists(atPath: errorPath) { break }
                    window.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).click()
                    RunLoop.current.run(until: Date().addingTimeInterval(0.35))
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

        // This fixture includes moderate-width data tables (≈8–10 columns) that should be readable without applying a
        // strong downscale transform. If they get a very small scale factor, we regress into the "tiny table" bug.
        let candidateTables = tables.filter { $0.cols >= 8 }
        XCTAssertGreaterThanOrEqual(candidateTables.count, 2)

        for t in candidateTables {
            XCTAssertGreaterThanOrEqual(
                t.scale,
                0.92,
                "Expected table scale to stay near 1.0 for temp.txt. got scale=\(t.scale), cols=\(t.cols), width=\(t.width), targetWidth=\(targetWidth), wrapped=\(t.wrapped)"
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
}
