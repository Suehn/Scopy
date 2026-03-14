import AppKit
import XCTest
import ScopyKit

/// ClipboardMonitor 单元测试
/// 验证剪贴板监控和内容提取功能
@MainActor
final class ClipboardMonitorTests: XCTestCase {

    var monitor: ClipboardMonitor!
    private var pasteboard: NSPasteboard!
    private var ingestSpoolDirectory: URL!

    override func setUp() async throws {
        pasteboard = NSPasteboard.withUniqueName()
        ingestSpoolDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-clipboard-monitor-ingest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: ingestSpoolDirectory, withIntermediateDirectories: true)
        ClipboardMonitor.testingAsyncProcessingDelayNs = 0
        monitor = ClipboardMonitor(pasteboard: pasteboard, ingestSpoolDirectory: ingestSpoolDirectory)
    }

    override func tearDown() async throws {
        monitor.stopMonitoring()
        monitor = nil
        pasteboard = nil
        ClipboardMonitor.testingAsyncProcessingDelayNs = 0
        if let ingestSpoolDirectory {
            try? FileManager.default.removeItem(at: ingestSpoolDirectory)
        }
        ingestSpoolDirectory = nil
    }

    // MARK: - Initialization Tests

    func testInitialization() {
        XCTAssertNotNil(monitor)
        XCTAssertNotNil(monitor.contentStream)
    }

    // MARK: - Configuration Tests

    func testPollingIntervalConfiguration() {
        // Test setting valid interval
        monitor.setPollingInterval(1.0)
        XCTAssertEqual(monitor.pollingInterval, 1.0)

        // Test clamping to minimum
        monitor.setPollingInterval(0.01)
        XCTAssertEqual(monitor.pollingInterval, 0.1)

        // Test clamping to maximum
        monitor.setPollingInterval(10.0)
        XCTAssertEqual(monitor.pollingInterval, 5.0)
    }

    func testSHA256HashVectors() {
        // NIST / FIPS 180-4 standard vectors (hex).
        XCTAssertEqual(
            ClipboardMonitor.computeHashStatic(Data()),
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
        XCTAssertEqual(
            ClipboardMonitor.computeHashStatic(Data("abc".utf8)),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
        XCTAssertEqual(
            ClipboardMonitor.computeHashStatic(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)),
            "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1"
        )
    }

    func testIgnoredAppsConfiguration() {
        let apps: Set<String> = ["com.app1", "com.app2"]
        monitor.setIgnoredApps(apps)
        XCTAssertEqual(monitor.ignoredApps, apps)
    }

    // MARK: - Clipboard Read Tests

    func testReadCurrentClipboard() {
        // Set something to clipboard
        pasteboard.clearContents()
        pasteboard.setString("Test clipboard content", forType: .string)

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.type, .text)
        XCTAssertEqual(content?.plainText, "Test clipboard content")
    }

    func testReadEmptyClipboard() {
        // Clear clipboard
        pasteboard.clearContents()

        let content = monitor.readCurrentClipboard()
        // Empty clipboard returns nil
        XCTAssertNil(content)
    }

    func testReadCurrentClipboardHTMLNonUTF8ProvidesPlainTextFallback() {
        let html = "<html><body>你好 Hello</body></html>"
        guard let htmlData = html.data(using: .utf16) else {
            XCTFail("Failed to encode HTML data")
            return
        }

        pasteboard.clearContents()
        pasteboard.setData(htmlData, forType: .html)

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.type, .html)
        XCTAssertTrue(content?.plainText.contains("你好") ?? false)
        XCTAssertTrue(content?.plainText.contains("Hello") ?? false)
    }

    func testReadCurrentClipboardHTMLUsesRichPayloadPlainTextEvenWhenStringIsCorrupted() {
        let expected = #"[\mathbf{e}^L_i = \mathbf{e}_i + \sum_{u\in\mathcal{N}_i} \frac{1}{\sqrt{|\mathcal{N}_i|}\sqrt{|\mathcal{N}_u|}} \mathbf{e}_u]"#
        let html = "<html><body><pre>\(expected)</pre></body></html>"
        let htmlData = Data(html.utf8)

        let corruptedPlain = """
        \\mathbf{e}^L_i
        ==================
        \\mathbf{e}*i + \\sum*{u\\in\\mathcal{N}_i} \\frac{1}{\\sqrt{|\\mathcal{N}_i|}\\sqrt{|\\mathcal{N}_u|}} \\mathbf{e}_u
        """

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(corruptedPlain, forType: .string)
        item.setData(htmlData, forType: .html)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.type, .html)
        let text = content?.plainText ?? ""

        XCTAssertTrue(text.contains("\\sum_{u\\in\\mathcal{N}_i}"))
        XCTAssertTrue(text.contains("\\mathbf{e}_i"))
        XCTAssertFalse(text.contains("\\sum*{"))
        XCTAssertFalse(text.contains("================"))
    }

    func testReadCurrentClipboardHTMLKaTeXUsesAnnotationTeXForPlainText() {
        let html = """
        <html><body>
        <h3>符号与公式层面的关键修正</h3>
        <p>(1) 不要用 <span class="katex"><span class="katex-mathml"><math><semantics>
        <annotation encoding="application/x-tex">W_p</annotation>
        </semantics></math></span><span class="katex-html" aria-hidden="true">Wp</span></span> 表示 unbiased Sinkhorn</p>
        <p>你在第3章写：</p>
        <span class="katex-display"><span class="katex"><span class="katex-mathml"><math><semantics>
        <annotation encoding="application/x-tex">W_p(P,Q)=W_\\varepsilon(P,Q)-\\frac12 W_\\varepsilon(P,P)-\\frac12 W_\\varepsilon(Q,Q).\\quad(3.17)</annotation>
        </semantics></math></span><span class="katex-html" aria-hidden="true">...</span></span></span>
        </body></html>
        """
        let htmlData = Data(html.utf8)

        let corruptedPlain = """
        W
        p
        (P,Q)=W
        """

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(corruptedPlain, forType: .string)
        item.setData(htmlData, forType: .html)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.type, .html)

        let text = content?.plainText ?? ""
        XCTAssertTrue(text.contains("$W_p$"))
        XCTAssertTrue(text.contains("$$"))
        XCTAssertTrue(text.contains("W_\\varepsilon(P,Q)"))
        XCTAssertTrue(text.contains("\\frac12"))
        XCTAssertFalse(text.contains("katex"))
    }

    func testReadCurrentClipboardRTFPrefersKaTeXAnnotationFromHTMLWhenAvailable() throws {
        let html = """
        <html><body>
        <p>Eq: <span class="katex"><span class="katex-mathml"><math><semantics>
        <annotation encoding="application/x-tex">W_p</annotation>
        </semantics></math></span><span class="katex-html" aria-hidden="true">Wp</span></span></p>
        </body></html>
        """
        let htmlData = Data(html.utf8)

        let attributed = NSAttributedString(string: "RTF fallback W p")
        let range = NSRange(location: 0, length: attributed.length)
        let rtfData = try attributed.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtf
        ])

        let corruptedPlain = """
        W
        p
        """

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(corruptedPlain, forType: .string)
        item.setData(rtfData, forType: .rtf)
        item.setData(htmlData, forType: .html)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.type, .rtf)

        let text = content?.plainText ?? ""
        XCTAssertTrue(text.contains("$W_p$"))
        XCTAssertFalse(text.contains("RTF fallback"))
    }

    func testReadCurrentClipboardRTFUsesRichPayloadPlainTextEvenWhenStringIsCorrupted() throws {
        let expected = #"[\mathbf{e}^L_i = \mathbf{e}_i + \sum_{u\in\mathcal{N}_i} \frac{1}{\sqrt{|\mathcal{N}_i|}\sqrt{|\mathcal{N}_u|}} \mathbf{e}_u]"#
        let attributed = NSAttributedString(string: expected)
        let range = NSRange(location: 0, length: attributed.length)
        let rtfData = try attributed.data(from: range, documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtf
        ])

        let corruptedPlain = """
        \\mathbf{e}^L_i
        ==================
        \\mathbf{e}*i + \\sum*{u\\in\\mathcal{N}_i} \\frac{1}{\\sqrt{|\\mathcal{N}_i|}\\sqrt{|\\mathcal{N}_u|}} \\mathbf{e}_u
        """

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(corruptedPlain, forType: .string)
        item.setData(rtfData, forType: .rtf)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.type, .rtf)
        let text = content?.plainText ?? ""

        XCTAssertTrue(text.contains("\\sum_{u\\in\\mathcal{N}_i}"))
        XCTAssertTrue(text.contains("\\mathbf{e}_i"))
        XCTAssertFalse(text.contains("\\sum*{"))
        XCTAssertFalse(text.contains("================"))
    }

    // MARK: - Copy To Clipboard Tests

    func testCopyTextToClipboard() {
        monitor.copyToClipboard(text: "Copied text")

        XCTAssertEqual(pasteboard.string(forType: .string), "Copied text")
    }

    func testCopyDataToClipboard() {
        let data = "Binary data".data(using: .utf8)!
        monitor.copyToClipboard(data: data, type: .string)

        let retrieved = pasteboard.data(forType: .string)
        XCTAssertEqual(retrieved, data)
    }

    func testCopyInvalidPNGDataKeepsPreviousClipboardContent() {
        pasteboard.clearContents()
        pasteboard.setString("baseline", forType: .string)

        monitor.copyToClipboard(data: Data([0x00, 0x01, 0x02]), type: .png)

        XCTAssertEqual(pasteboard.string(forType: .string), "baseline")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testCopyPNGDataProducesCodexReadableImagePayload() throws {
        let pngData = try makeSolidColorPNGData()

        pasteboard.clearContents()
        pasteboard.setString("baseline", forType: .string)

        monitor.copyToClipboard(data: pngData, type: .png, imageWriteMode: .codexOptimized)

        guard let copiedPNGData = pasteboard.data(forType: .png) else {
            XCTFail("Expected PNG payload on pasteboard")
            return
        }

        XCTAssertTrue(isLikelyPNG(copiedPNGData))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
        XCTAssertNil(pasteboard.string(forType: .string))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
    }

    func testCopyRichTextProvidesPlainTextFallback() throws {
        let attributed = NSAttributedString(string: "Rich text")
        let range = NSRange(location: 0, length: attributed.length)
        let rtfData = try attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf]
        )

        monitor.copyToClipboard(text: "Rich text", data: rtfData, type: .rtf)

        XCTAssertEqual(pasteboard.string(forType: .string), "Rich text")
        XCTAssertEqual(pasteboard.data(forType: .rtf), rtfData)
    }

    func testCopyHTMLProvidesPlainTextFallback() throws {
        let attributed = NSAttributedString(string: "Hello <World>")
        let range = NSRange(location: 0, length: attributed.length)
        let htmlData = try attributed.data(
            from: range,
            documentAttributes: [.documentType: NSAttributedString.DocumentType.html]
        )

        monitor.copyToClipboard(text: "Hello <World>", data: htmlData, type: .html)

        XCTAssertEqual(pasteboard.string(forType: .string), "Hello <World>")
        XCTAssertEqual(pasteboard.data(forType: .html), htmlData)
    }

    // MARK: - Content Type Detection Tests

    func testTextContentDetection() {
        pasteboard.clearContents()
        pasteboard.setString("Plain text content", forType: .string)

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .text)
    }

    func testImageContentDetection() {
        // Create test image
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 10, height: 10))
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation else { return }

        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .image)
        XCTAssertNotNil(content?.rawData)
    }

    func testImageWithTemporaryImageFileURLPrefersImageContent() throws {
        guard let tiffData = makeSolidColorTIFFData() else {
            XCTFail("Failed to generate image data")
            return
        }
        let tempImageURL = try makeTemporaryImageFileURL()
        defer { try? FileManager.default.removeItem(at: tempImageURL.deletingLastPathComponent()) }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(tempImageURL.absoluteString, forType: .fileURL)
        item.setString(tempImageURL.path, forType: .string)
        item.setData(tiffData, forType: .tiff)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .image)
        XCTAssertNotNil(content?.rawData)
    }

    func testTemporaryImageFileURLWithoutImageTypesButDecodableFileStillPrefersImage() throws {
        let tempImageURL = try makeTemporaryValidPNGFileURL()
        defer { try? FileManager.default.removeItem(at: tempImageURL.deletingLastPathComponent()) }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(tempImageURL.absoluteString, forType: .fileURL)
        item.setString(tempImageURL.path, forType: .string)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .image)
        guard let rawData = content?.rawData else {
            XCTFail("Expected image payload data")
            return
        }
        XCTAssertTrue(isLikelyPNG(rawData))
    }

    func testWeChatContainerImageFileURLWithoutImageTypesStillPrefersImage() throws {
        let rootDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("scopy-wechat-path-\(UUID().uuidString)", isDirectory: true)
        let weChatTempDirectory = rootDirectory
            .appendingPathComponent(
                "Library/Containers/com.tencent.xinWeChat/Data/Documents/xwechat_files/wxid_test/temp/RWTemp/2026-03",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: weChatTempDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: rootDirectory) }

        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        NSColor.systemTeal.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            XCTFail("Failed to generate PNG data")
            return
        }

        let imageURL = weChatTempDirectory.appendingPathComponent("wechat-\(UUID().uuidString).png")
        try pngData.write(to: imageURL, options: .atomic)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(imageURL.absoluteString, forType: .fileURL)
        item.setString(imageURL.path, forType: .string)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .image)
        guard let rawData = content?.rawData else {
            XCTFail("Expected image payload data")
            return
        }
        XCTAssertTrue(isLikelyPNG(rawData))
    }

    func testTemporaryNonImageFileURLStillDetectedAsFile() throws {
        let tempTextURL = try makeTemporaryTextFileURL()
        defer { try? FileManager.default.removeItem(at: tempTextURL.deletingLastPathComponent()) }

        pasteboard.clearContents()
        pasteboard.writeObjects([tempTextURL as NSURL])

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .file)
        XCTAssertTrue(content?.plainText.contains(tempTextURL.path) ?? false)
    }

    func testNonTemporaryImageFileURLWithFileListTypeStillDetectedAsFile() throws {
        guard let tiffData = makeSolidColorTIFFData() else {
            XCTFail("Failed to generate image data")
            return
        }
        let imageURL = try makeNonTemporaryImageFileURL()
        defer { try? FileManager.default.removeItem(at: imageURL.deletingLastPathComponent()) }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(imageURL.absoluteString, forType: .fileURL)
        item.setString(imageURL.path, forType: .string)
        item.setData(tiffData, forType: .tiff)
        pasteboard.writeObjects([item])
        pasteboard.setPropertyList([imageURL.path], forType: NSPasteboard.PasteboardType("NSFilenamesPboardType"))

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .file)
    }

    func testTableHTMLPrefersHTMLOverImageWhenBothExist() {
        // Simulate Office/Excel: image preview + HTML table + plain text.
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 10, height: 10))
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation else { return }

        let html = """
        <html xmlns:x="urn:schemas-microsoft-com:office:excel"><body>
        <table><tr><td>1</td><td>2</td></tr></table>
        </body></html>
        """
        let htmlData = Data(html.utf8)
        let plainText = "1\t2"

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(plainText, forType: .string)
        item.setData(htmlData, forType: .html)
        item.setData(tiffData, forType: .tiff)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .html)
        XCTAssertEqual(content?.plainText, plainText)
        XCTAssertEqual(content?.rawData, htmlData)
    }

    func testImageHTMLKeepsImageWhenHTMLLooksLikeImage() {
        // Copy image from browser often includes a small <img ...> HTML snippet; should remain image.
        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 10, height: 10))
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation else { return }

        let html = #"<html><body><img src="https://example.com/a.png" /></body></html>"#
        let htmlData = Data(html.utf8)
        let plainText = "https://example.com/a.png"

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(plainText, forType: .string)
        item.setData(htmlData, forType: .html)
        item.setData(tiffData, forType: .tiff)
        pasteboard.writeObjects([item])

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .image)
        XCTAssertNotNil(content?.rawData)
    }

    // MARK: - Hash Tests (v0.md 3.2)

    func testContentHashConsistency() {
        pasteboard.clearContents()
        pasteboard.setString("Hash test content", forType: .string)

        let content1 = monitor.readCurrentClipboard()
        let content2 = monitor.readCurrentClipboard()

        // Same content should produce same hash
        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    func testContentHashDifferent() {
        pasteboard.clearContents()
        pasteboard.setString("Content A", forType: .string)
        let content1 = monitor.readCurrentClipboard()

        pasteboard.clearContents()
        pasteboard.setString("Content B", forType: .string)
        let content2 = monitor.readCurrentClipboard()

        // Different content should produce different hash
        XCTAssertNotEqual(content1?.contentHash, content2?.contentHash)
    }

    func testTextNormalization() {
        // Test with leading/trailing whitespace
        pasteboard.clearContents()
        pasteboard.setString("   normalized   ", forType: .string)
        let content1 = monitor.readCurrentClipboard()

        // Same text without whitespace
        pasteboard.clearContents()
        pasteboard.setString("normalized", forType: .string)
        let content2 = monitor.readCurrentClipboard()

        // Hashes should be equal after normalization
        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    func testLineEndingNormalization() {
        // Windows line endings
        pasteboard.clearContents()
        pasteboard.setString("line1\r\nline2", forType: .string)
        let content1 = monitor.readCurrentClipboard()

        // Unix line endings
        pasteboard.clearContents()
        pasteboard.setString("line1\nline2", forType: .string)
        let content2 = monitor.readCurrentClipboard()

        // Should have same hash after normalization
        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    func testUnicodeLineSeparatorNormalization() {
        // Unicode line separator
        pasteboard.clearContents()
        pasteboard.setString("line1\u{2028}line2", forType: .string)
        let content1 = monitor.readCurrentClipboard()

        // Unix line endings
        pasteboard.clearContents()
        pasteboard.setString("line1\nline2", forType: .string)
        let content2 = monitor.readCurrentClipboard()

        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    func testNBSPAndBOMNormalization() {
        pasteboard.clearContents()
        pasteboard.setString("\u{FEFF}\u{00A0}Normalized\u{00A0}\u{FEFF}", forType: .string)
        let content1 = monitor.readCurrentClipboard()

        pasteboard.clearContents()
        pasteboard.setString("Normalized", forType: .string)
        let content2 = monitor.readCurrentClipboard()

        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    func testRTFContentHashUsesNormalizedPlainTextNotRawPayload() throws {
        let plainText = "Duplicate rich text"

        let a1 = NSMutableAttributedString(string: plainText)
        a1.addAttribute(.font, value: NSFont.systemFont(ofSize: 12), range: NSRange(location: 0, length: a1.length))
        let rtf1 = try a1.data(from: NSRange(location: 0, length: a1.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtf
        ])

        let a2 = NSMutableAttributedString(string: plainText)
        a2.addAttribute(.font, value: NSFont.boldSystemFont(ofSize: 14), range: NSRange(location: 0, length: a2.length))
        let rtf2 = try a2.data(from: NSRange(location: 0, length: a2.length), documentAttributes: [
            .documentType: NSAttributedString.DocumentType.rtf
        ])

        XCTAssertNotEqual(rtf1, rtf2)

        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        pasteboard.setData(rtf1, forType: .rtf)
        let content1 = monitor.readCurrentClipboard()

        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        pasteboard.setData(rtf2, forType: .rtf)
        let content2 = monitor.readCurrentClipboard()

        XCTAssertEqual(content1?.type, .rtf)
        XCTAssertEqual(content2?.type, .rtf)
        XCTAssertEqual(content1?.plainText, plainText)
        XCTAssertEqual(content2?.plainText, plainText)
        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    func testHTMLContentHashUsesNormalizedPlainTextNotRawPayload() {
        let plainText = "Hello <World>"
        let html1 = Data("<html><body><b>Hello <World></b></body></html>".utf8)
        let html2 = Data("<div style=\"color:red\">Hello <World></div>".utf8)
        XCTAssertNotEqual(html1, html2)

        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        pasteboard.setData(html1, forType: .html)
        let content1 = monitor.readCurrentClipboard()

        pasteboard.clearContents()
        pasteboard.setString(plainText, forType: .string)
        pasteboard.setData(html2, forType: .html)
        let content2 = monitor.readCurrentClipboard()

        XCTAssertEqual(content1?.type, .html)
        XCTAssertEqual(content2?.type, .html)
        XCTAssertEqual(content1?.plainText, plainText)
        XCTAssertEqual(content2?.plainText, plainText)
        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    // MARK: - Size Calculation Tests

    func testSizeCalculation() {
        pasteboard.clearContents()
        pasteboard.setString("12345", forType: .string) // 5 bytes

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.sizeBytes, 5)
    }

    func testUTF8SizeCalculation() {
        pasteboard.clearContents()
        pasteboard.setString("你好", forType: .string) // 6 bytes in UTF-8

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.sizeBytes, 6)
    }

    // MARK: - Monitoring Tests

    func testStartStopMonitoring() {
        // Should not crash
        monitor.startMonitoring()
        monitor.startMonitoring() // Double start should be safe
        monitor.stopMonitoring()
        monitor.stopMonitoring() // Double stop should be safe
    }

    func testMonitorDetectsChanges() async {
        var receivedContent: ClipboardMonitor.ClipboardContent?
        let expectedPrefix = "New clipboard content"

        monitor.setPollingInterval(0.1)

        pasteboard.clearContents()
        pasteboard.setString("Baseline \(UUID())", forType: .string)

        // Start monitoring (baseline should not trigger)
        monitor.startMonitoring()

        // Listen for events
        let expectation = XCTestExpectation(description: "Clipboard change detected")
        let task = Task {
            for await content in monitor.contentStream {
                if content.plainText.contains(expectedPrefix) {
                    receivedContent = content
                    expectation.fulfill()
                    break
                }
            }
        }

        // Wait a bit then change clipboard
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        pasteboard.clearContents()
        pasteboard.setString("\(expectedPrefix) \(UUID())", forType: .string)

        await fulfillment(of: [expectation], timeout: 3.0)
        task.cancel()

        XCTAssertNotNil(receivedContent)
        XCTAssertTrue(receivedContent?.plainText.contains(expectedPrefix) ?? false)
    }

    func testMonitorPrefersHTMLTableOverImageWhenBothExist() async {
        var receivedContent: ClipboardMonitor.ClipboardContent?
        let expectedText = "1\t2"

        monitor.setPollingInterval(0.1)

        pasteboard.clearContents()
        pasteboard.setString("Baseline \(UUID())", forType: .string)

        monitor.startMonitoring()

        let expectation = XCTestExpectation(description: "Clipboard change detected as HTML table")
        let task = Task {
            for await content in monitor.contentStream {
                if content.type == .html, content.plainText == expectedText {
                    receivedContent = content
                    expectation.fulfill()
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let image = NSImage(size: NSSize(width: 10, height: 10))
        image.lockFocus()
        NSColor.red.set()
        NSBezierPath.fill(NSRect(x: 0, y: 0, width: 10, height: 10))
        image.unlockFocus()
        guard let tiffData = image.tiffRepresentation else {
            task.cancel()
            XCTFail("Failed to generate test image TIFF")
            return
        }

        let html = """
        <html xmlns:x="urn:schemas-microsoft-com:office:excel"><body>
        <table><tr><td>1</td><td>2</td></tr></table>
        </body></html>
        """
        let htmlData = Data(html.utf8)

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(expectedText, forType: .string)
        item.setData(htmlData, forType: .html)
        item.setData(tiffData, forType: .tiff)
        pasteboard.writeObjects([item])

        await fulfillment(of: [expectation], timeout: 3.0)
        task.cancel()

        XCTAssertNotNil(receivedContent)
        XCTAssertEqual(receivedContent?.type, .html)
        XCTAssertEqual(receivedContent?.plainText, expectedText)
    }

    func testMonitorPrefersImageWhenTemporaryImageFileURLAndImageBothExist() async throws {
        var receivedContent: ClipboardMonitor.ClipboardContent?

        monitor.setPollingInterval(0.1)
        pasteboard.clearContents()
        pasteboard.setString("Baseline \(UUID())", forType: .string)
        monitor.startMonitoring()

        let expectation = XCTestExpectation(description: "Clipboard change detected as image")
        let task = Task {
            for await content in monitor.contentStream {
                if content.type == .image {
                    receivedContent = content
                    expectation.fulfill()
                    break
                }
            }
        }

        try? await Task.sleep(nanoseconds: 100_000_000)

        guard let tiffData = makeSolidColorTIFFData() else {
            task.cancel()
            XCTFail("Failed to generate image data")
            return
        }
        let tempImageURL = try makeTemporaryImageFileURL()
        defer { try? FileManager.default.removeItem(at: tempImageURL.deletingLastPathComponent()) }

        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(tempImageURL.absoluteString, forType: .fileURL)
        item.setString(tempImageURL.path, forType: .string)
        item.setData(tiffData, forType: .tiff)
        pasteboard.writeObjects([item])

        await fulfillment(of: [expectation], timeout: 3.0)
        task.cancel()

        XCTAssertEqual(receivedContent?.type, .image)
    }

    func testLargeContentSurvivesPollingIntervalChange() async throws {
        ClipboardMonitor.testingAsyncProcessingDelayNs = 300_000_000
        monitor.setPollingInterval(0.1)

        pasteboard.clearContents()
        pasteboard.setString("Baseline \(UUID())", forType: .string)
        monitor.startMonitoring()

        let expectation = XCTestExpectation(description: "Large content delivered after polling interval change")
        let task = Task {
            for await content in monitor.contentStream where content.type == .image {
                if let envelopeURL = content.ingestEnvelopeURL {
                    monitor.acknowledgeIngestEnvelope(at: envelopeURL)
                }
                expectation.fulfill()
                break
            }
        }
        defer { task.cancel() }

        try await Task.sleep(nanoseconds: 100_000_000)
        guard let tiffData = makeLargeSolidColorTIFFData() else {
            XCTFail("Failed to generate large TIFF")
            return
        }

        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)

        try await Task.sleep(nanoseconds: 150_000_000)
        monitor.setPollingInterval(0.2)

        await fulfillment(of: [expectation], timeout: 5.0)
        await assertEventually(timeout: 2.0, pollInterval: 0.05, {
            self.pendingEnvelopeCount() == 0
        }, message: "Ingest envelopes should be acknowledged after delivery")
    }

    func testPendingLargeContentReplaysAfterMonitorRestart() async throws {
        ClipboardMonitor.testingAsyncProcessingDelayNs = 300_000_000
        monitor.setPollingInterval(0.1)

        pasteboard.clearContents()
        pasteboard.setString("Baseline \(UUID())", forType: .string)
        monitor.startMonitoring()

        try await Task.sleep(nanoseconds: 100_000_000)
        guard let tiffData = makeLargeSolidColorTIFFData() else {
            XCTFail("Failed to generate large TIFF")
            return
        }

        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)

        try await Task.sleep(nanoseconds: 150_000_000)
        monitor.stopMonitoring()

        ClipboardMonitor.testingAsyncProcessingDelayNs = 0
        let expectation = XCTestExpectation(description: "Pending envelope replayed after restart")
        let task = Task {
            for await content in monitor.contentStream where content.type == .image {
                if let envelopeURL = content.ingestEnvelopeURL {
                    monitor.acknowledgeIngestEnvelope(at: envelopeURL)
                }
                expectation.fulfill()
                break
            }
        }
        defer { task.cancel() }

        monitor.startMonitoring()

        await fulfillment(of: [expectation], timeout: 5.0)
        await assertEventually(timeout: 2.0, pollInterval: 0.05, {
            self.pendingEnvelopeCount() == 0
        }, message: "Replayed ingest envelope should be acknowledged after storage")
    }

    // MARK: - App Bundle ID Tests

    func testAppBundleIDCapture() {
        // Note: This tests the current frontmost app, which may vary
        pasteboard.clearContents()
        pasteboard.setString("Test", forType: .string)

        let content = monitor.readCurrentClipboard()

        // In test environment, this will be XCTest runner
        // Just verify it doesn't crash and returns something
        print("Captured app bundle ID: \(content?.appBundleID ?? "nil")")
    }

    // MARK: - Edge Cases

    func testVeryLongText() {
        let longText = String(repeating: "a", count: 100_000) // 100KB

        pasteboard.clearContents()
        pasteboard.setString(longText, forType: .string)

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.sizeBytes, 100_000)
        XCTAssertNotNil(content?.contentHash)
    }

    func testSpecialCharacters() {
        let specialText = "Hello 👋 World 🌍 \n\t\r Special \"quotes\" 'and' <html>"

        pasteboard.clearContents()
        pasteboard.setString(specialText, forType: .string)

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertTrue(content?.plainText.contains("👋") ?? false)
    }

    private func makeSolidColorTIFFData() -> Data? {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        NSColor.systemGreen.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }

    private func makeSolidColorPNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClipboardMonitorTests", code: 3)
        }

        return pngData
    }

    private func makeLargeSolidColorTIFFData() -> Data? {
        let image = NSImage(size: NSSize(width: 640, height: 640))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 640, height: 640)).fill()
        image.unlockFocus()
        return image.tiffRepresentation
    }

    private func makeTemporaryImageFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-clipboard-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("image-\(UUID().uuidString).png")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: url, options: .atomic)
        return url
    }

    private func makeTemporaryValidPNGFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-clipboard-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("image-\(UUID().uuidString).png")

        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClipboardMonitorTests", code: 1)
        }

        try pngData.write(to: url, options: .atomic)
        return url
    }

    private func makeTemporaryTextFileURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-clipboard-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("note-\(UUID().uuidString).txt")
        try Data("not-image".utf8).write(to: url, options: .atomic)
        return url
    }

    private func makeNonTemporaryImageFileURL() throws -> URL {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("scopy-clipboard-monitor-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("image-\(UUID().uuidString).png")

        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 12, height: 12)).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "ClipboardMonitorTests", code: 2)
        }

        try pngData.write(to: url, options: .atomic)
        return url
    }

    private func isLikelyPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return data.prefix(signature.count).elementsEqual(signature)
    }

    private func pendingEnvelopeCount() -> Int {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: ingestSpoolDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }
        return urls.filter { $0.lastPathComponent.hasSuffix(".envelope.json") }.count
    }
}
