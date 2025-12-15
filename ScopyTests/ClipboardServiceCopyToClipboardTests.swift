import AppKit
import XCTest
import ScopyKit

@MainActor
final class ClipboardServiceCopyToClipboardTests: XCTestCase {
    private var service: (any ClipboardServiceProtocol)!
    private var pasteboard: NSPasteboard!
    private var settingsStore: SettingsStore!
    private var settingsSuiteName: String?
    private var tempDirectory: URL?
    private var insertedItemID: UUID?
    private var insertedHTMLData: Data?

    override func setUp() async throws {
        let suiteName = "scopy-copy-settings-\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        settingsSuiteName = suiteName
        settingsStore = SettingsStore(suiteName: suiteName)

        pasteboard = NSPasteboard.withUniqueName()

        let baseURL = FileManager.default.temporaryDirectory.appendingPathComponent("scopy-copy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: baseURL, withIntermediateDirectories: true)
        tempDirectory = baseURL

        let dbPath = baseURL.appendingPathComponent("clipboard.db").path

        // Insert an HTML item whose stored plainText is empty (simulates older broken data).
        let html = "<html><body>你好 Hello</body></html>"
        guard let htmlData = html.data(using: .utf16) else {
            throw XCTSkip("Unable to encode HTML data as UTF-16")
        }
        insertedHTMLData = htmlData

        let storage = StorageService(databasePath: dbPath)
        try await storage.open()
        let storedItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .html,
                plainText: "",
                payload: .data(htmlData),
                appBundleID: "com.test.app",
                contentHash: UUID().uuidString,
                sizeBytes: htmlData.count
            )
        )
        insertedItemID = storedItem.id
        await storage.close()

        service = ClipboardServiceFactory.create(
            useMock: false,
            databasePath: dbPath,
            settingsStore: settingsStore,
            monitorPasteboardName: pasteboard.name.rawValue,
            monitorPollingInterval: 0.1
        )
        try await service.start()
    }

    override func tearDown() async throws {
        if let service {
            await service.stopAndWait()
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        tempDirectory = nil
        insertedItemID = nil
        insertedHTMLData = nil
        service = nil
        pasteboard = nil
        settingsStore = nil
        if let suiteName = settingsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: suiteName)
        }
        settingsSuiteName = nil
    }

    func testCopyToClipboardHTMLWhenStoredPlainTextIsEmptyWritesPlainString() async throws {
        guard let insertedItemID else {
            XCTFail("Missing inserted item ID")
            return
        }
        guard let insertedHTMLData else {
            XCTFail("Missing inserted html data")
            return
        }

        let items = try await service.fetchRecent(limit: 20, offset: 0)
        guard let item = items.first(where: { $0.id == insertedItemID }) else {
            XCTFail("Inserted item not found")
            return
        }
        XCTAssertEqual(item.type, .html)
        XCTAssertTrue(item.plainText.isEmpty)

        try await service.copyToClipboard(itemID: insertedItemID)

        XCTAssertEqual(pasteboard.data(forType: .html), insertedHTMLData)
        let plainString = pasteboard.string(forType: .string) ?? ""
        XCTAssertFalse(plainString.isEmpty)
        XCTAssertTrue(plainString.contains("你好"))
        XCTAssertTrue(plainString.contains("Hello"))
    }
}
