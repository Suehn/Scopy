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
    private var nonTemporaryDirectory: URL?
    private var insertedItemID: UUID?
    private var insertedLegacyImageItemID: UUID?
    private var insertedStandardPNGImageItemID: UUID?
    private var insertedPalettedImageItemID: UUID?
    private var insertedMisclassifiedTempImageFileItemID: UUID?
    private var insertedFinderImageFileItemID: UUID?
    private var insertedSingleTextFileItemID: UUID?
    private var insertedHTMLData: Data?
    private var insertedStandardPNGImageData: Data?
    private var insertedPalettedImageData: Data?

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

        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()
        guard let legacyTIFFData = image.tiffRepresentation else {
            throw XCTSkip("Failed to generate legacy TIFF payload")
        }

        let legacyImageItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .image,
                plainText: "[Image]",
                payload: .data(legacyTIFFData),
                appBundleID: "com.test.app",
                contentHash: UUID().uuidString,
                sizeBytes: legacyTIFFData.count
            )
        )
        insertedLegacyImageItemID = legacyImageItem.id

        let standardPNGData = try makeSolidColorPNGData()
        insertedStandardPNGImageData = standardPNGData
        let standardImageItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .image,
                plainText: "[Image]",
                payload: .data(standardPNGData),
                appBundleID: "com.test.app",
                contentHash: UUID().uuidString,
                sizeBytes: standardPNGData.count
            )
        )
        insertedStandardPNGImageItemID = standardImageItem.id

        let palettedPNGData = try makePalettedPNGData()
        insertedPalettedImageData = palettedPNGData
        let palettedImageItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .image,
                plainText: "[Image]",
                payload: .data(palettedPNGData),
                appBundleID: "com.test.app",
                contentHash: UUID().uuidString,
                sizeBytes: palettedPNGData.count
            )
        )
        insertedPalettedImageItemID = palettedImageItem.id

        let temporaryImageFileURL = baseURL.appendingPathComponent("wechat-\(UUID().uuidString).png")
        try makeSolidColorPNGData().write(to: temporaryImageFileURL, options: .atomic)
        let serializedFileURLs = try JSONEncoder().encode([temporaryImageFileURL.path])
        let misclassifiedFileItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .file,
                plainText: temporaryImageFileURL.path,
                payload: .data(serializedFileURLs),
                appBundleID: "com.test.app",
                contentHash: UUID().uuidString,
                sizeBytes: temporaryImageFileURL.path.utf8.count + serializedFileURLs.count
            )
        )
        insertedMisclassifiedTempImageFileItemID = misclassifiedFileItem.id

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("scopy-copy-home-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
        nonTemporaryDirectory = homeDirectory

        let finderImageFileURL = homeDirectory.appendingPathComponent("finder-image-\(UUID().uuidString).png")
        try makeSolidColorPNGData().write(to: finderImageFileURL, options: .atomic)
        let serializedFinderImageFileURLs = try JSONEncoder().encode([finderImageFileURL.path])
        let finderImageFileItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .file,
                plainText: finderImageFileURL.path,
                payload: .data(serializedFinderImageFileURLs),
                appBundleID: "com.apple.finder",
                contentHash: UUID().uuidString,
                sizeBytes: finderImageFileURL.path.utf8.count + serializedFinderImageFileURLs.count
            )
        )
        insertedFinderImageFileItemID = finderImageFileItem.id

        let textFileURL = baseURL.appendingPathComponent("note-\(UUID().uuidString).txt")
        try Data("clipboard text file".utf8).write(to: textFileURL, options: .atomic)
        let serializedTextFileURLs = try JSONEncoder().encode([textFileURL.path])
        let textFileItem = try await storage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .file,
                plainText: textFileURL.path,
                payload: .data(serializedTextFileURLs),
                appBundleID: "com.apple.finder",
                contentHash: UUID().uuidString,
                sizeBytes: textFileURL.path.utf8.count + serializedTextFileURLs.count
            )
        )
        insertedSingleTextFileItemID = textFileItem.id
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
        if let nonTemporaryDirectory {
            try? FileManager.default.removeItem(at: nonTemporaryDirectory)
        }
        tempDirectory = nil
        nonTemporaryDirectory = nil
        insertedItemID = nil
        insertedLegacyImageItemID = nil
        insertedStandardPNGImageItemID = nil
        insertedPalettedImageItemID = nil
        insertedMisclassifiedTempImageFileItemID = nil
        insertedFinderImageFileItemID = nil
        insertedSingleTextFileItemID = nil
        insertedHTMLData = nil
        insertedStandardPNGImageData = nil
        insertedPalettedImageData = nil
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

    func testCopyToClipboardImageWhenStoredPayloadIsLegacyTIFFPublishesValidPNG() async throws {
        guard let insertedLegacyImageItemID else {
            XCTFail("Missing inserted legacy image item ID")
            return
        }

        try await service.copyToClipboard(itemID: insertedLegacyImageItemID)

        guard let pngData = pasteboard.data(forType: .png) else {
            XCTFail("Expected PNG payload on pasteboard")
            return
        }
        XCTAssertTrue(isLikelyPNG(pngData))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testCopyToClipboardImageWhenStoredPayloadIsStandardPNGPreservesReplayBytes() async throws {
        guard let insertedStandardPNGImageItemID else {
            XCTFail("Missing inserted standard PNG image item ID")
            return
        }
        guard let insertedStandardPNGImageData else {
            XCTFail("Missing inserted standard PNG image data")
            return
        }

        try await service.copyToClipboard(itemID: insertedStandardPNGImageItemID)

        guard let pngData = pasteboard.data(forType: .png) else {
            XCTFail("Expected PNG payload on pasteboard")
            return
        }

        XCTAssertEqual(pngData, insertedStandardPNGImageData)
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testCopyToClipboardImageWhenStoredPayloadIsPalettedPNGPreservesOriginalPNGAndAddsTIFFFallback() async throws {
        guard let insertedPalettedImageItemID else {
            XCTFail("Missing inserted paletted image item ID")
            return
        }
        guard let insertedPalettedImageData else {
            XCTFail("Missing inserted paletted image data")
            return
        }

        try await service.copyToClipboard(itemID: insertedPalettedImageItemID)

        guard let pngData = pasteboard.data(forType: .png) else {
            XCTFail("Expected PNG payload on pasteboard")
            return
        }

        XCTAssertTrue(isLikelyPNG(pngData))
        XCTAssertEqual(pngData, insertedPalettedImageData)
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))
    }

    func testCopyToClipboardMisclassifiedTemporaryImageFilePublishesPNGInsteadOfFileURLs() async throws {
        guard let insertedMisclassifiedTempImageFileItemID else {
            XCTFail("Missing inserted misclassified file item ID")
            return
        }

        try await service.copyToClipboard(itemID: insertedMisclassifiedTempImageFileItemID)

        guard let pngData = pasteboard.data(forType: .png) else {
            XCTFail("Expected PNG payload on pasteboard")
            return
        }
        XCTAssertTrue(isLikelyPNG(pngData))
        XCTAssertNotNil(NSImage(pasteboard: pasteboard))
        XCTAssertNotNil(pasteboard.data(forType: .tiff))

        let fileListType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        XCTAssertNil(pasteboard.propertyList(forType: fileListType))
    }

    func testCopyToClipboardFinderImageFilePreservesFileURLs() async throws {
        guard let insertedFinderImageFileItemID else {
            XCTFail("Missing inserted finder image file item ID")
            return
        }

        try await service.copyToClipboard(itemID: insertedFinderImageFileItemID)

        let fileListType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let fileList = pasteboard.propertyList(forType: fileListType) as? [String]
        XCTAssertEqual(fileList?.count, 1)
        let pastedFileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(pastedFileURLs?.count, 1)
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    func testCopyToClipboardSingleTextFileStillPublishesFileURLs() async throws {
        guard let insertedSingleTextFileItemID else {
            XCTFail("Missing inserted text file item ID")
            return
        }

        try await service.copyToClipboard(itemID: insertedSingleTextFileItemID)

        let fileListType = NSPasteboard.PasteboardType("NSFilenamesPboardType")
        let fileList = pasteboard.propertyList(forType: fileListType) as? [String]
        XCTAssertEqual(fileList?.count, 1)
        let pastedFileURLs = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL]
        XCTAssertEqual(pastedFileURLs?.count, 1)
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    private func isLikelyPNG(_ data: Data) -> Bool {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return data.prefix(signature.count).elementsEqual(signature)
    }

    private func makeSolidColorPNGData() throws -> Data {
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemPurple.setFill()
        NSBezierPath(rect: NSRect(x: 0, y: 0, width: 16, height: 16)).fill()
        image.unlockFocus()

        guard let tiffData = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiffData),
              let pngData = rep.representation(using: .png, properties: [:]) else {
            throw XCTSkip("Failed to generate PNG data")
        }
        return pngData
    }

    private func makePalettedPNGData() throws -> Data {
        // Safe real screenshot fixture that reproduces Codex/arboard failure when
        // a historical palette PNG is replayed without a rasterized TIFF fallback.
        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/history-replay-real-screenshot-paletted.png")

        return try Data(contentsOf: fixtureURL, options: [.mappedIfSafe])
    }
}
