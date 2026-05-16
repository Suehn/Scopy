import XCTest
import Foundation

@MainActor
final class HistoryItemViewUITests: XCTestCase {
    private static let forwardedPerfKeys: [String] = [
        "SCOPY_PERF_HISTORY_INDEX",
        "SCOPY_PERF_SCROLL_RESOLVER_CACHE",
        "SCOPY_PERF_MARKDOWN_RESOLVER_CACHE",
        "SCOPY_PERF_PREVIEW_TASK_BUDGET",
        "SCOPY_PERF_SHORT_QUERY_DEBOUNCE"
    ]

    private var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
    }

    override func tearDown() async throws {
        app?.terminate()
        app = nil
    }

    func testPrimaryActionIncrementsSelectionCountWithoutOptimizing() throws {
        launchHarness(scenario: "plain-text")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        tapMainAction()

        waitForValue("select=1", identifier: "UITest.HistoryItemHarness.SelectCount")
        waitForValue("optimize=0", identifier: "UITest.HistoryItemHarness.OptimizeCount")
    }

    func testOptimizeButtonDoesNotTriggerPrimaryAction() throws {
        launchHarness(scenario: "image")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        tapOptimizeAction()

        waitForValue("optimize=1", identifier: "UITest.HistoryItemHarness.OptimizeCount")
        waitForValue("select=0", identifier: "UITest.HistoryItemHarness.SelectCount")
    }

    func testImageScenarioCodexContextMenuTriggersCodexPasteActionOnly() throws {
        launchHarness(scenario: "image")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        triggerCodexPasteFromContextMenu()

        waitForValue("codexPaste=1", identifier: "UITest.HistoryItemHarness.CodexPasteCount")
        waitForValue("select=0", identifier: "UITest.HistoryItemHarness.SelectCount")
    }

    func testImageScenarioShowsAirDropAndOpenContainingFolderActionsForStorageRef() throws {
        launchHarness(scenario: "image")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        triggerAirDropFromContextMenu()
        waitForValue("airDrop=1", identifier: "UITest.HistoryItemHarness.AirDropCount")

        triggerOpenContainingFolderFromContextMenu()
        waitForValue("openFolder=1", identifier: "UITest.HistoryItemHarness.OpenFolderCount")
    }

    func testInlineImageScenarioShowsAirDropWithoutOpenContainingFolder() throws {
        launchHarness(scenario: "inline-image")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        triggerAirDropFromContextMenu()
        waitForValue("airDrop=1", identifier: "UITest.HistoryItemHarness.AirDropCount")

        assertOpenContainingFolderHiddenInContextMenu()
        waitForValue("openFolder=0", identifier: "UITest.HistoryItemHarness.OpenFolderCount")
    }

    func testFileScenarioShowsAirDropAndOpenContainingFolderActions() throws {
        launchHarness(scenario: "file")

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        triggerAirDropFromContextMenu()
        waitForValue("airDrop=1", identifier: "UITest.HistoryItemHarness.AirDropCount")

        triggerOpenContainingFolderFromContextMenu()
        waitForValue("openFolder=1", identifier: "UITest.HistoryItemHarness.OpenFolderCount")
    }

    func testMarkdownScenarioShowsExportPNGInContextMenu() throws {
        let dumpPath = "/tmp/scopy_uitest_history_item_export.png"
        let errorPath = "/tmp/scopy_uitest_history_item_export_error.txt"
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        launchHarness(scenario: "markdown-text", dumpPath: dumpPath, errorPath: errorPath)

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        triggerExportPNGFromContextMenu()

        waitForFile(atPath: dumpPath, timeout: 10)
        XCTAssertFalse(FileManager.default.fileExists(atPath: errorPath))
        waitForValue("pin=0", identifier: "UITest.HistoryItemHarness.PinCount")
    }

    func testMarkdownFileScenarioShowsPreviewPopover() throws {
        launchHarness(scenario: "markdown-file", openPreviewOnTap: true)

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        let filePreviewFound = triggerPreview("History.Preview.File")
        let textPreviewFound = app.anyElement("History.Preview.Text").waitForExistence(timeout: 3)
        let activePopover = displayedText(identifier: "UITest.HistoryItemHarness.ActivePopover") ?? "<missing>"
        let popoverRequest = displayedText(identifier: "UITest.HistoryItemHarness.PopoverRequest") ?? "<missing>"
        let selectCount = displayedText(identifier: "UITest.HistoryItemHarness.SelectCount") ?? "<missing>"
        XCTAssertTrue(
            filePreviewFound || textPreviewFound,
            "Expected Markdown file preview popover to appear; activePopover=\(activePopover) popoverRequest=\(popoverRequest) selectCount=\(selectCount)"
        )
    }

    func testPlainTextScenarioHidesExportPNGInContextMenu() throws {
        let dumpPath = "/tmp/scopy_uitest_history_item_plain_export.png"
        let errorPath = "/tmp/scopy_uitest_history_item_plain_export_error.txt"
        try? FileManager.default.removeItem(atPath: dumpPath)
        try? FileManager.default.removeItem(atPath: errorPath)

        launchHarness(scenario: "plain-text", dumpPath: dumpPath, errorPath: errorPath)

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        assertExportPNGHiddenInContextMenu()

        assertFileDoesNotExist(atPath: dumpPath, timeout: 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: errorPath))
        waitForValue("pin=1", identifier: "UITest.HistoryItemHarness.PinCount")
    }

    func testHoverPreviewMarkdownProfileSmoke() throws {
        try runHoverPreviewProfileScenario(
            scenario: "hover-preview-markdown-text",
            harnessScenario: "markdown-text",
            previewIdentifier: "History.Preview.Text",
            requiredBuckets: ["hover.markdown_render_ms"]
        )
    }

    func testHoverPreviewImageProfileSmoke() throws {
        try runHoverPreviewProfileScenario(
            scenario: "hover-preview-image",
            harnessScenario: "image",
            previewIdentifier: "History.Preview.Image",
            requiredBuckets: ["hover.preview_image_decode_ms"]
        )
    }

    private func launchHarness(
        scenario: String,
        dumpPath: String? = nil,
        errorPath: String? = nil,
        openPreviewOnTap: Bool = false
    ) {
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_HARNESS"] = "1"
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_SCENARIO"] = scenario
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_KEYBOARD_SELECTED"] = "1"
        if openPreviewOnTap {
            app.launchEnvironment["SCOPY_UITEST_OPEN_PREVIEW_ON_TAP"] = "1"
        }
        if let dumpPath {
            app.launchEnvironment["SCOPY_EXPORT_DUMP_PATH"] = dumpPath
        }
        if let errorPath {
            app.launchEnvironment["SCOPY_EXPORT_ERROR_DUMP_PATH"] = errorPath
        }
        app.launch()
    }

    private func launchProfileHarness(scenario: String, profileScenario: String, profilePath: String) {
        app.launchArguments = ["--uitesting"]
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_HARNESS"] = "1"
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_SCENARIO"] = scenario
        app.launchEnvironment["SCOPY_UITEST_HISTORY_ITEM_KEYBOARD_SELECTED"] = "1"
        app.launchEnvironment["SCOPY_UITEST_OPEN_PREVIEW_ON_TAP"] = "1"
        app.launchEnvironment["SCOPY_SCROLL_PROFILE"] = "1"
        app.launchEnvironment["SCOPY_PROFILE_DURATION_SEC"] = "\(profileDurationSeconds)"
        app.launchEnvironment["SCOPY_PROFILE_MIN_SAMPLES"] = "\(profileMinSamples)"
        app.launchEnvironment["SCOPY_PROFILE_OUTPUT"] = profilePath
        app.launchEnvironment["SCOPY_PROFILE_SCENARIO"] = profileScenario
        app.launchEnvironment["SCOPY_PROFILE_AUTO_SCROLL"] = "0"
        let testEnv = ProcessInfo.processInfo.environment
        for key in Self.forwardedPerfKeys {
            if let value = normalized(testEnv[key]) ?? normalized(testEnv["TEST_RUNNER_\(key)"]) {
                app.launchEnvironment[key] = value
            }
        }
        app.launch()
    }

    private func historyItemButton(identifier: String) -> XCUIElement {
        app.buttons[identifier]
    }

    private func contextMenuItem(identifier: String, title: String) -> XCUIElement {
        app.menuItems.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, title)).firstMatch
    }

    private func tapMainAction() {
        let action = historyItemButton(identifier: "HistoryItem.MainAction")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let selectCountIdentifier = "UITest.HistoryItemHarness.SelectCount"
        let clickTargets: [CGVector] = [
            CGVector(dx: 0.10, dy: 0.50),
            CGVector(dx: 0.18, dy: 0.50),
            CGVector(dx: 0.26, dy: 0.50),
            CGVector(dx: 0.35, dy: 0.50)
        ]

        for offset in clickTargets {
            action.coordinate(withNormalizedOffset: offset).click()
            if displayedText(identifier: selectCountIdentifier) == "select=1" {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
    }

    private func tapOptimizeAction() {
        let optimize = historyItemButton(identifier: "HistoryItem.OptimizeButton")
        XCTAssertTrue(optimize.waitForExistence(timeout: 5))
        optimize.click()
    }

    private func runHoverPreviewProfileScenario(
        scenario: String,
        harnessScenario: String,
        previewIdentifier: String,
        requiredBuckets: [String]
    ) throws {
        guard profileTestsEnabled else {
            throw XCTSkip("Set SCOPY_RUN_PROFILE_UI_TESTS=1 or touch /tmp/scopy_run_profile_ui_tests to enable hover profile UI tests")
        }

        let profilePath = makeProfileOutputPath(scenario: scenario, runID: profileRunID)
        launchProfileHarness(scenario: harnessScenario, profileScenario: scenario, profilePath: profilePath)

        XCTAssertTrue(app.anyElement("UITest.HistoryItemHarness").waitForExistence(timeout: 10))
        let previewAccessibilityFound = triggerPreview(previewIdentifier)

        waitForProfileOutput(atPath: profilePath, timeout: max(12, profileDurationSeconds + 8))

        let data = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        var json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let buckets = json?["buckets_ms"] as? [String: Any] ?? [:]
        let bucketCounts = Dictionary(uniqueKeysWithValues: requiredBuckets.map { key in
            (key, Self.metricBucketCount(buckets[key]))
        })
        let missingBuckets = requiredBuckets.filter { (bucketCounts[$0] ?? 0) <= 0 }
        json?["hover_preview_evidence"] = [
            "preview_identifier": previewIdentifier,
            "preview_triggered": true,
            "preview_accessibility_found": previewAccessibilityFound,
            "required_buckets": requiredBuckets,
            "bucket_counts": bucketCounts,
            "missing_required_buckets": missingBuckets,
            "harness_scenario": harnessScenario
        ]

        if let json,
           let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try updatedData.write(to: URL(fileURLWithPath: profilePath), options: .atomic)
        }

        XCTAssertTrue(missingBuckets.isEmpty, "Missing hover profile buckets: \(missingBuckets)")
        let frame = json?["frame_ms"] as? [String: Any]
        let count = frame?["count"] as? Int ?? 0
        XCTAssertGreaterThan(count, 0, "Expected frame samples in hover profile output")
        let scenarioName = json?["profile_scenario"] as? String ?? ""
        XCTAssertEqual(scenarioName, scenario, "Profile scenario mismatch")
    }

    private var profileTestsEnabled: Bool {
        let envEnabled = envValue("SCOPY_RUN_PROFILE_UI_TESTS") == "1"
        let flagEnabled = FileManager.default.fileExists(atPath: "/tmp/scopy_run_profile_ui_tests")
        return envEnabled || flagEnabled
    }

    private var profileDurationSeconds: TimeInterval {
        max(4, parseDouble(envValue("SCOPY_UI_PROFILE_DURATION_SEC")) ?? 4)
    }

    private var profileMinSamples: Int {
        max(60, parseInt(envValue("SCOPY_UI_PROFILE_MIN_SAMPLES")) ?? 80)
    }

    private var profileRunID: String {
        envValue("SCOPY_UI_PROFILE_RUN_ID") ?? UUID().uuidString
    }

    private var profileOutputDirectory: String? {
        envValue("SCOPY_UI_PROFILE_OUTPUT_DIR")
    }

    private func triggerPreview(_ previewIdentifier: String) -> Bool {
        let action = historyItemButton(identifier: "HistoryItem.MainAction")
        XCTAssertTrue(action.waitForExistence(timeout: 5))
        let clickTargets: [CGVector] = [
            CGVector(dx: 0.10, dy: 0.50),
            CGVector(dx: 0.18, dy: 0.50),
            CGVector(dx: 0.26, dy: 0.50),
            CGVector(dx: 0.35, dy: 0.50)
        ]

        for offset in clickTargets {
            action.coordinate(withNormalizedOffset: offset).click()
            if app.anyElement(previewIdentifier).waitForExistence(timeout: 1) {
                return true
            }
        }
        return false
    }

    private func waitForProfileOutput(atPath path: String, timeout: TimeInterval) {
        let predicate = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: path)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Profile output not found at \(path)")
    }

    private func makeProfileOutputPath(scenario: String, runID: String) -> String {
        if let outputDir = profileOutputDirectory {
            let directory = URL(fileURLWithPath: outputDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let token = safeFileToken(scenario)
            let runToken = safeFileToken(runID)
            return directory.appendingPathComponent("\(token)-\(runToken).json").path
        }
        return "/tmp/scopy_hover_profile_\(safeFileToken(scenario))_\(UUID().uuidString).json"
    }

    private func safeFileToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let token = String(scalars)
        return token.isEmpty ? "profile" : token
    }

    private func envValue(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return normalized(env[key]) ?? normalized(env["TEST_RUNNER_\(key)"])
    }

    private func normalized(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    private func parseInt(_ value: String?) -> Int? {
        guard let value, !value.isEmpty else { return nil }
        return Int(value)
    }

    private func parseDouble(_ value: String?) -> Double? {
        guard let value, !value.isEmpty else { return nil }
        return Double(value)
    }

    private static func metricBucketCount(_ raw: Any?) -> Int {
        guard let bucket = raw as? [String: Any] else { return 0 }
        if let count = bucket["count"] as? Int {
            return count
        }
        if let count = bucket["count"] as? Double {
            return Int(count)
        }
        return 0
    }

    private func openContextMenu() {
        let row = historyItemButton(identifier: "HistoryItem.MainAction")
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        row.rightClick()
    }

    private func triggerExportPNGFromContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let exportItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.ExportPNG", title: "Export PNG")
        XCTAssertTrue(exportItem.waitForExistence(timeout: 2))
        exportItem.click()
    }

    private func triggerCodexPasteFromContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let codexItem = contextMenuItem(
            identifier: "HistoryItem.ContextMenu.PasteOptimizedForCodex",
            title: "Paste-optimized for Codex"
        )
        XCTAssertTrue(codexItem.waitForExistence(timeout: 2))
        codexItem.click()
    }

    private func triggerAirDropFromContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let airDropItem = contextMenuItem(
            identifier: "HistoryItem.ContextMenu.SendViaAirDrop",
            title: "Send via AirDrop"
        )
        XCTAssertTrue(airDropItem.waitForExistence(timeout: 2))
        airDropItem.click()
    }

    private func triggerOpenContainingFolderFromContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let folderItem = contextMenuItem(
            identifier: "HistoryItem.ContextMenu.OpenContainingFolder",
            title: "Open Containing Folder"
        )
        XCTAssertTrue(folderItem.waitForExistence(timeout: 2))
        folderItem.click()
    }

    private func assertOpenContainingFolderHiddenInContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let airDropItem = contextMenuItem(
            identifier: "HistoryItem.ContextMenu.SendViaAirDrop",
            title: "Send via AirDrop"
        )
        XCTAssertTrue(airDropItem.waitForExistence(timeout: 2))

        let folderItem = contextMenuItem(
            identifier: "HistoryItem.ContextMenu.OpenContainingFolder",
            title: "Open Containing Folder"
        )
        XCTAssertFalse(folderItem.waitForExistence(timeout: 1))

        airDropItem.click()
    }

    private func assertExportPNGHiddenInContextMenu() {
        openContextMenu()

        let copyItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Copy", title: "Copy")
        XCTAssertTrue(copyItem.waitForExistence(timeout: 2))

        let pinItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.Pin", title: "Pin")
        XCTAssertTrue(pinItem.waitForExistence(timeout: 2))

        let exportItem = contextMenuItem(identifier: "HistoryItem.ContextMenu.ExportPNG", title: "Export PNG")
        XCTAssertFalse(exportItem.waitForExistence(timeout: 1))

        pinItem.click()
    }

    private func waitForFile(atPath path: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        XCTFail("Expected file at \(path) within \(timeout) seconds")
    }

    private func assertFileDoesNotExist(atPath path: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: path) {
                XCTFail("Did not expect file at \(path)")
                return
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
    }

    private func waitForValue(_ expected: String, identifier: String, timeout: TimeInterval = 5) {
        let element = app.anyElement(identifier)
        XCTAssertTrue(element.waitForExistence(timeout: timeout))
        let predicate = NSPredicate(format: "value == %@ OR label == %@", expected, expected)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        XCTAssertEqual(result, .completed, "Expected \(identifier) to become \(expected)")
    }

    private func displayedText(identifier: String) -> String? {
        let element = app.anyElement(identifier)
        guard element.waitForExistence(timeout: 1) else { return nil }
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label.isEmpty ? nil : element.label
    }
}
