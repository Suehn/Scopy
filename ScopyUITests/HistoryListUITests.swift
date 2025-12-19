import XCTest

/// History List UI Tests
/// Tests for the clipboard history list functionality
@MainActor
final class HistoryListUITests: XCTestCase {

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
        let envEnabled = ProcessInfo.processInfo.environment["SCOPY_RUN_PROFILE_UI_TESTS"] == "1"
        let flagEnabled = FileManager.default.fileExists(atPath: "/tmp/scopy_run_profile_ui_tests")
        return envEnabled || flagEnabled
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
        durationSeconds: TimeInterval = 6,
        minSamples: Int = 180
    ) throws {
        guard profileTestsEnabled else {
            throw XCTSkip("Set SCOPY_RUN_PROFILE_UI_TESTS=1 or touch /tmp/scopy_run_profile_ui_tests to enable scroll profiling UI tests")
        }

        app.terminate()
        app.launchEnvironment = [:]

        let profilePath = "/tmp/scopy_scroll_profile_\(scenario)_\(UUID().uuidString).json"
        app.launchEnvironment["USE_MOCK_SERVICE"] = "1"
        app.launchEnvironment["SCOPY_MOCK_ITEM_COUNT"] = "\(itemCount)"
        app.launchEnvironment["SCOPY_MOCK_IMAGE_COUNT"] = "\(imageCount)"
        app.launchEnvironment["SCOPY_MOCK_SHOW_THUMBNAILS"] = showThumbnails ? "1" : "0"
        app.launchEnvironment["SCOPY_MOCK_TEXT_LENGTH"] = "\(textLength)"
        app.launchEnvironment["SCOPY_SCROLL_PROFILE"] = "1"
        app.launchEnvironment["SCOPY_PROFILE_DURATION_SEC"] = "\(durationSeconds)"
        app.launchEnvironment["SCOPY_PROFILE_MIN_SAMPLES"] = "\(minSamples)"
        app.launchEnvironment["SCOPY_PROFILE_OUTPUT"] = profilePath
        app.launchEnvironment["SCOPY_PROFILE_ACCESSIBILITY"] = accessibility ? "1" : "0"
        app.launchEnvironment["SCOPY_PROFILE_SCENARIO"] = scenario

        app.launch()
        _ = prepareMainWindow()

        let list = app.anyElement("History.List")
        guard list.waitForExistence(timeout: 15) else {
            XCTFail("List not found")
            return
        }

        exerciseScroll(on: list, durationSeconds: durationSeconds)

        let predicate = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: profilePath)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let result = XCTWaiter.wait(for: [expectation], timeout: max(12, durationSeconds + 6))
        XCTAssertEqual(result, .completed, "Profile output not found at \(profilePath)")

        let data = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        let json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        let frame = json?["frame_ms"] as? [String: Any]
        let count = frame?["count"] as? Int ?? 0
        XCTAssertGreaterThan(count, 0, "Expected frame samples in profile output")

        let scenarioName = json?["profile_scenario"] as? String ?? ""
        XCTAssertEqual(scenarioName, scenario, "Profile scenario mismatch")
    }

    private func exerciseScroll(on list: XCUIElement, durationSeconds: TimeInterval) {
        let window = app.windows.firstMatch
        let endTime = Date().addingTimeInterval(durationSeconds)
        while Date() < endTime {
            let target = list.isHittable ? list : window
            target.swipeUp()
            usleep(120_000)
        }
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
