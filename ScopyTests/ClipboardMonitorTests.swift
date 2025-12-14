import AppKit
import XCTest
import ScopyKit

/// ClipboardMonitor 单元测试
/// 验证剪贴板监控和内容提取功能
@MainActor
final class ClipboardMonitorTests: XCTestCase {

    var monitor: ClipboardMonitor!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        pasteboard = NSPasteboard.withUniqueName()
        monitor = ClipboardMonitor(pasteboard: pasteboard)
    }

    override func tearDown() async throws {
        monitor.stopMonitoring()
        monitor = nil
        pasteboard = nil
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
}
