import XCTest

/// History List UI Tests
/// Tests for the clipboard history list functionality
@MainActor
final class HistoryListUITests: XCTestCase {

    private enum ScrollProfileDataSource: String {
        case mock
        case realSnapshot
    }

    private static let forwardedPerfKeys: [String] = [
        "SCOPY_PERF_HISTORY_INDEX",
        "SCOPY_PERF_SCROLL_RESOLVER_CACHE",
        "SCOPY_PERF_MARKDOWN_RESOLVER_CACHE",
        "SCOPY_PERF_PREVIEW_TASK_BUDGET",
        "SCOPY_PERF_SHORT_QUERY_DEBOUNCE"
    ]

    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        app.launch()
        _ = prepareMainWindow()
    }

    override func tearDown() async throws {
        app.terminate()
        app = nil
    }

    private var profileTestsEnabled: Bool {
        let envEnabled = envValue("SCOPY_RUN_PROFILE_UI_TESTS") == "1"
        let flagEnabled = FileManager.default.fileExists(atPath: "/tmp/scopy_run_profile_ui_tests")
        return envEnabled || flagEnabled
    }

    private var profileDurationOverrideSeconds: TimeInterval? {
        parseDouble(envValue("SCOPY_UI_PROFILE_DURATION_SEC"))
    }

    private var profileMinSamplesOverride: Int? {
        parseInt(envValue("SCOPY_UI_PROFILE_MIN_SAMPLES"))
    }

    private var profileOutputDirectory: String? {
        envValue("SCOPY_UI_PROFILE_OUTPUT_DIR")
    }

    private var profileRunID: String {
        envValue("SCOPY_UI_PROFILE_RUN_ID")
            ?? UUID().uuidString
    }

    private var profileSnapshotDBPath: String? {
        envValue("SCOPY_UI_PROFILE_DB_PATH")
    }

    // MARK: - List Display Tests

    func testHistoryListExists() throws {
        // Wait for the list to appear
        let list = app.anyElement("History.List")
        let exists = list.waitForExistence(timeout: 15)
        XCTAssertTrue(exists)
    }

    func testHistoryListHasItems() throws {
        // In UI testing mode with mock data, should have items
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 15) else {
            XCTFail("List not found")
            return
        }

        let items = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item."))
        XCTAssertGreaterThan(items.count, 0)
    }

    func testListScrolling() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 15) else {
            XCTFail("List not found")
            return
        }

        // Scroll down
        list.swipeUp()

        // List should still exist after scrolling
        let exists = list.exists
        XCTAssertTrue(exists)
    }

    func testItemSelection() throws {
        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 15) else {
            XCTFail("List not found")
            return
        }

        // Click on first item
        _ = list
        let firstItem = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).firstMatch
        if firstItem.waitForExistence(timeout: 5) {
            firstItem.click()
        }
    }

    func testListRefreshesOnSearch() throws {
        guard let searchField = waitForSearchField() else {
            XCTFail("Search field not found")
            return
        }

        searchField.click()
        searchField.typeText("test")

        // Wait for the query text to be reflected in the field value.
        waitForPredicate(
            NSPredicate(format: "value CONTAINS[c] %@", "test"),
            on: searchField,
            timeout: 6,
            message: "Search field did not receive input"
        )

        XCTAssertTrue(app.anyElement("History.List").exists)
    }

    func testEmptySearchShowsResults() throws {
        guard let searchField = waitForSearchField() else {
            XCTFail("Search field not found")
            return
        }

        // Enter search text then clear it (⌘A + ⌫) so the behavior is deterministic.
        searchField.click()
        searchField.typeText("test")

        // Delete typed characters (avoid modifier-dependent shortcuts for stability).
        searchField.typeText(String(repeating: "\u{8}", count: 4))

        waitForPredicate(
            NSPredicate(format: "value == '' OR value == nil OR value CONTAINS[c] %@", "Search"),
            on: searchField,
            timeout: 6,
            message: "Search field did not clear"
        )

        XCTAssertTrue(app.anyElement("History.List").exists)
    }

    func testScrollProfileBaseline() throws {
        try runScrollProfileScenario(
            scenario: "baseline-image-accessibility",
            itemCount: 10000,
            imageCount: 2000,
            showThumbnails: true,
            textLength: 512,
            accessibility: true
        )
    }

    func testScrollProfileTextOnly() throws {
        try runScrollProfileScenario(
            scenario: "text-only",
            itemCount: 8000,
            imageCount: 0,
            showThumbnails: false,
            textLength: 4096,
            accessibility: false
        )
    }

    func testScrollProfileImageHeavyNoAccessibility() throws {
        try runScrollProfileScenario(
            scenario: "image-heavy-no-accessibility",
            itemCount: 8000,
            imageCount: 3000,
            showThumbnails: true,
            textLength: 128,
            accessibility: false
        )
    }

    func testScrollProfileRealSnapshotAccessibility() throws {
        try runScrollProfileScenario(
            scenario: "real-snapshot-accessibility",
            itemCount: 0,
            imageCount: 0,
            showThumbnails: true,
            textLength: 0,
            accessibility: true,
            dataSource: .realSnapshot,
            durationSeconds: 10,
            minSamples: 260
        )
    }

    func testScrollProfileRealSnapshotMixed() throws {
        try runScrollProfileScenario(
            scenario: "real-snapshot-mixed",
            itemCount: 0,
            imageCount: 0,
            showThumbnails: true,
            textLength: 0,
            accessibility: false,
            dataSource: .realSnapshot,
            durationSeconds: 10,
            minSamples: 260
        )
    }

    func testScrollProfileRealSnapshotTextBias() throws {
        try runScrollProfileScenario(
            scenario: "real-snapshot-text-bias",
            itemCount: 0,
            imageCount: 0,
            showThumbnails: false,
            textLength: 0,
            accessibility: false,
            dataSource: .realSnapshot,
            durationSeconds: 10,
            minSamples: 260
        )
    }

    func testHoverPreviewDismissesOnScroll() throws {
        app.terminate()
        app.launchEnvironment = [:]
        app.launchEnvironment["USE_MOCK_SERVICE"] = "1"
        app.launchEnvironment["SCOPY_MOCK_ITEM_COUNT"] = "80"
        app.launchEnvironment["SCOPY_MOCK_IMAGE_COUNT"] = "30"
        app.launchEnvironment["SCOPY_MOCK_SHOW_THUMBNAILS"] = "1"
        app.launchEnvironment["SCOPY_MOCK_IMAGE_PREVIEW_DELAY"] = "0"
        app.launchEnvironment["SCOPY_UITEST_OPEN_PREVIEW_ON_TAP"] = "1"
        app.launch()
        _ = prepareMainWindow()

        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 15) else {
            XCTFail("List not found")
            return
        }

        let items = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item."))
        let firstItem = items.element(boundBy: 0)
        guard firstItem.waitForExistence(timeout: 5) else {
            XCTFail("History item not found")
            return
        }

        var preview: XCUIElement?
        for index in 0..<3 {
            let candidate = items.element(boundBy: index)
            guard candidate.exists else { continue }
            candidate.click()
            let textPreview = app.anyElement("History.Preview.Text")
            let imagePreview = app.anyElement("History.Preview.Image")
            if textPreview.waitForExistence(timeout: 4) {
                preview = textPreview
                break
            }
            if imagePreview.waitForExistence(timeout: 4) {
                preview = imagePreview
                break
            }
        }

        guard let preview else {
            XCTFail("Preview not shown")
            return
        }

        var attempts = 0
        while preview.exists && attempts < 3 {
            list.swipeUp()
            usleep(120_000)
            if preview.exists {
                preview.swipeUp()
                usleep(120_000)
            }
            attempts += 1
        }

        waitForPredicate(
            NSPredicate(format: "exists == 0"),
            on: preview,
            timeout: 8,
            message: "Preview did not dismiss on scroll"
        )

        XCTAssertTrue(list.exists)
    }

    private func runScrollProfileScenario(
        scenario: String,
        itemCount: Int,
        imageCount: Int,
        showThumbnails: Bool,
        textLength: Int,
        accessibility: Bool,
        dataSource: ScrollProfileDataSource = .mock,
        durationSeconds: TimeInterval = 6,
        minSamples: Int = 180
    ) throws {
        guard profileTestsEnabled else {
            throw XCTSkip("Set SCOPY_RUN_PROFILE_UI_TESTS=1 or touch /tmp/scopy_run_profile_ui_tests to enable scroll profiling UI tests")
        }

        let resolvedDuration = max(4, profileDurationOverrideSeconds ?? durationSeconds)
        let resolvedMinSamples = max(60, profileMinSamplesOverride ?? minSamples)

        app.terminate()
        app.launchEnvironment = [:]

        let testEnv = ProcessInfo.processInfo.environment
        for key in Self.forwardedPerfKeys {
            if let value = normalized(testEnv[key]) ?? normalized(testEnv["TEST_RUNNER_\(key)"]) {
                app.launchEnvironment[key] = value
            }
        }

        let profilePath = makeProfileOutputPath(scenario: scenario, runID: profileRunID)
        switch dataSource {
        case .mock:
            app.launchEnvironment["USE_MOCK_SERVICE"] = "1"
            app.launchEnvironment["SCOPY_MOCK_ITEM_COUNT"] = "\(itemCount)"
            app.launchEnvironment["SCOPY_MOCK_IMAGE_COUNT"] = "\(imageCount)"
            app.launchEnvironment["SCOPY_MOCK_SHOW_THUMBNAILS"] = showThumbnails ? "1" : "0"
            app.launchEnvironment["SCOPY_MOCK_TEXT_LENGTH"] = "\(textLength)"
            app.launchEnvironment["SCOPY_PROFILE_DATA_SOURCE"] = dataSource.rawValue
        case .realSnapshot:
            guard let dbPath = profileSnapshotDBPath else {
                throw XCTSkip("Set SCOPY_UI_PROFILE_DB_PATH to an absolute snapshot DB path for real-snapshot profiling")
            }
            guard FileManager.default.fileExists(atPath: dbPath) else {
                throw XCTSkip("Snapshot DB not found at \(dbPath)")
            }
            app.launchEnvironment["USE_MOCK_SERVICE"] = "0"
            app.launchEnvironment["SCOPY_SERVICE_DB_PATH"] = dbPath
            app.launchEnvironment["SCOPY_SERVICE_MONITOR_PASTEBOARD"] = "org.scopy.profile.\(safeFileToken(profileRunID)).\(safeFileToken(scenario))"
            // Reduce monitor wakeups during UI profile runs; keep sampling focused on list/render path.
            app.launchEnvironment["SCOPY_SERVICE_MONITOR_INTERVAL_SEC"] = "2.5"
            app.launchEnvironment["SCOPY_PROFILE_DATA_SOURCE"] = dataSource.rawValue
        }
        app.launchEnvironment["SCOPY_SCROLL_PROFILE"] = "1"
        app.launchEnvironment["SCOPY_PROFILE_DURATION_SEC"] = "\(resolvedDuration)"
        app.launchEnvironment["SCOPY_PROFILE_MIN_SAMPLES"] = "\(resolvedMinSamples)"
        app.launchEnvironment["SCOPY_PROFILE_OUTPUT"] = profilePath
        app.launchEnvironment["SCOPY_PROFILE_ACCESSIBILITY"] = accessibility ? "1" : "0"
        app.launchEnvironment["SCOPY_PROFILE_SCENARIO"] = scenario
        let autoScroll = envValue("SCOPY_PROFILE_AUTO_SCROLL") ?? "1"
        app.launchEnvironment["SCOPY_PROFILE_AUTO_SCROLL"] = autoScroll

        app.launch()
        _ = prepareMainWindow()

        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 15) else {
            XCTFail("List not found")
            return
        }

        if autoScroll == "0" {
            exerciseScroll(on: list, durationSeconds: resolvedDuration)
        } else {
            waitForAutomatedScroll(durationSeconds: resolvedDuration)
        }

        let predicate = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: profilePath)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: max(12, resolvedDuration + 6))
        XCTAssertEqual(result, .completed, "Profile output not found at \(profilePath)")

        let data = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        var json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let accessibilityQuery = measureAccessibilityQuery()
        json?["xctest_accessibility_query"] = accessibilityQuery
        if let json,
           let updatedData = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted]) {
            try updatedData.write(to: URL(fileURLWithPath: profilePath), options: .atomic)
        }
        let frame = json?["frame_ms"] as? [String: Any]
        let count = frame?["count"] as? Int ?? 0
        XCTAssertGreaterThan(count, 0, "Expected frame samples in profile output")
        let activeFrame = json?["active_frame_ms"] as? [String: Any]
        let activeCount = activeFrame?["count"] as? Int ?? 0
        XCTAssertGreaterThan(activeCount, 0, "Expected active scrolling frame samples in profile output")

        let scenarioName = json?["profile_scenario"] as? String ?? ""
        XCTAssertEqual(scenarioName, scenario, "Profile scenario mismatch")
    }

    private func exerciseScroll(on list: XCUIElement, durationSeconds: TimeInterval) {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: 5) else { return }
        if window.isHittable {
            window.click()
        }

        let endTime = Date().addingTimeInterval(durationSeconds)
        var step = 0
        while Date() < endTime {
            guard window.exists else {
                usleep(120_000)
                continue
            }
            switch step % 6 {
            case 0, 1, 4:
                dragScroll(in: list, upward: true)
            case 2:
                dragScroll(in: list, upward: false)
            case 3:
                dragScroll(in: list, upward: true)
                dragScroll(in: list, upward: true)
            default:
                dragScroll(in: list, upward: false)
            }
            usleep((step % 3 == 0) ? 90_000 : 120_000)
            step += 1
        }
    }

    private func waitForAutomatedScroll(durationSeconds: TimeInterval) {
        let endTime = Date().addingTimeInterval(durationSeconds)
        while Date() < endTime {
            usleep(120_000)
        }
    }

    private func measureAccessibilityQuery() -> [String: Any] {
        let listStart = CFAbsoluteTimeGetCurrent()
        let listExists = app.anyElement("History.List").exists
        let listQueryMs = (CFAbsoluteTimeGetCurrent() - listStart) * 1000

        let itemStart = CFAbsoluteTimeGetCurrent()
        let itemCount = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).count
        let itemQueryMs = (CFAbsoluteTimeGetCurrent() - itemStart) * 1000

        return [
            "list_exists": listExists,
            "list_query_ms": listQueryMs,
            "history_item_count": itemCount,
            "history_item_query_ms": itemQueryMs
        ]
    }

    private func dragScroll(in element: XCUIElement, upward: Bool) {
        let startY: CGFloat = upward ? 0.78 : 0.22
        let endY: CGFloat = upward ? 0.22 : 0.78
        let start = element.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: startY))
        let end = element.coordinate(withNormalizedOffset: CGVector(dx: 0.55, dy: endY))
        start.press(forDuration: 0.01, thenDragTo: end)
    }

    private func makeProfileOutputPath(scenario: String, runID: String) -> String {
        if let outputDir = profileOutputDirectory {
            let directory = URL(fileURLWithPath: outputDir, isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let token = safeFileToken(scenario)
            let runToken = safeFileToken(runID)
            return directory.appendingPathComponent("\(token)-\(runToken).json").path
        }
        return "/tmp/scopy_scroll_profile_\(safeFileToken(scenario))_\(UUID().uuidString).json"
    }

    private func safeFileToken(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "._-"))
        let mapped = raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        var token = String(mapped)
        while token.contains("--") {
            token = token.replacingOccurrences(of: "--", with: "-")
        }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return token.isEmpty ? "profile" : token
    }

    private func normalized(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func envValue(_ key: String) -> String? {
        let env = ProcessInfo.processInfo.environment
        return normalized(env[key]) ?? normalized(env["TEST_RUNNER_\(key)"])
    }

    private func parseInt(_ raw: String?) -> Int? {
        guard let normalized = normalized(raw) else { return nil }
        return Int(normalized)
    }

    private func parseDouble(_ raw: String?) -> Double? {
        guard let normalized = normalized(raw) else { return nil }
        return Double(normalized)
    }

    private func prepareMainWindow(timeout: TimeInterval = 12) -> XCUIElement? {
        let window = app.windows.firstMatch
        guard window.waitForExistence(timeout: timeout) else {
            return nil
        }
        if window.isHittable {
            window.click()
        }
        return window
    }

    private func waitForSearchField(timeout: TimeInterval = 15) -> XCUIElement? {
        _ = prepareMainWindow()
        let searchField = app.anyElement("History.SearchField")
        guard searchField.waitForExistence(timeout: timeout) else {
            return nil
        }
        return searchField
    }
}
