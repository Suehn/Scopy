import XCTest
@testable import Scopy

/// ClipboardMonitor 单元测试
/// 验证剪贴板监控和内容提取功能
@MainActor
final class ClipboardMonitorTests: XCTestCase {

    var monitor: ClipboardMonitor!

    override func setUp() async throws {
        try await super.setUp()
        monitor = ClipboardMonitor()
    }

    override func tearDown() async throws {
        monitor.stopMonitoring()
        monitor = nil
        try await super.tearDown()
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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Test clipboard content", forType: .string)

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertEqual(content?.type, .text)
        XCTAssertEqual(content?.plainText, "Test clipboard content")
    }

    func testReadEmptyClipboard() {
        // Clear clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        let content = monitor.readCurrentClipboard()
        // Empty clipboard returns nil
        XCTAssertNil(content)
    }

    // MARK: - Copy To Clipboard Tests

    func testCopyTextToClipboard() {
        monitor.copyToClipboard(text: "Copied text")

        let pasteboard = NSPasteboard.general
        XCTAssertEqual(pasteboard.string(forType: .string), "Copied text")
    }

    func testCopyDataToClipboard() {
        let data = "Binary data".data(using: .utf8)!
        monitor.copyToClipboard(data: data, type: .string)

        let pasteboard = NSPasteboard.general
        let retrieved = pasteboard.data(forType: .string)
        XCTAssertEqual(retrieved, data)
    }

    // MARK: - Content Type Detection Tests

    func testTextContentDetection() {
        let pasteboard = NSPasteboard.general
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

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(tiffData, forType: .tiff)

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.type, .image)
        XCTAssertNotNil(content?.rawData)
    }

    // MARK: - Hash Tests (v0.md 3.2)

    func testContentHashConsistency() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("Hash test content", forType: .string)

        let content1 = monitor.readCurrentClipboard()
        let content2 = monitor.readCurrentClipboard()

        // Same content should produce same hash
        XCTAssertEqual(content1?.contentHash, content2?.contentHash)
    }

    func testContentHashDifferent() {
        let pasteboard = NSPasteboard.general

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
        let pasteboard = NSPasteboard.general

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
        let pasteboard = NSPasteboard.general

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
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("12345", forType: .string) // 5 bytes

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.sizeBytes, 5)
    }

    func testUTF8SizeCalculation() {
        let pasteboard = NSPasteboard.general
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

        // Start monitoring
        monitor.startMonitoring()

        // Listen for events
        let expectation = XCTestExpectation(description: "Clipboard change detected")
        let task = Task {
            for await content in monitor.contentStream {
                receivedContent = content
                expectation.fulfill()
                break
            }
        }

        // Wait a bit then change clipboard
        try? await Task.sleep(nanoseconds: 100_000_000) // 100ms

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString("New clipboard content \(UUID())", forType: .string)

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()

        XCTAssertNotNil(receivedContent)
        XCTAssertTrue(receivedContent?.plainText.contains("New clipboard content") ?? false)
    }

    // MARK: - App Bundle ID Tests

    func testAppBundleIDCapture() {
        // Note: This tests the current frontmost app, which may vary
        let pasteboard = NSPasteboard.general
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

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(longText, forType: .string)

        let content = monitor.readCurrentClipboard()
        XCTAssertEqual(content?.sizeBytes, 100_000)
        XCTAssertNotNil(content?.contentHash)
    }

    func testSpecialCharacters() {
        let specialText = "Hello 👋 World 🌍 \n\t\r Special \"quotes\" 'and' <html>"

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(specialText, forType: .string)

        let content = monitor.readCurrentClipboard()
        XCTAssertNotNil(content)
        XCTAssertTrue(content?.plainText.contains("👋") ?? false)
    }
}
