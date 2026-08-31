import CoreGraphics
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
        "SCOPY_PERF_SHORT_QUERY_DEBOUNCE",
        "SCOPY_PERF_PASSIVE_ROW",
        "SCOPY_PERF_MARKDOWN_MENU_SIGNAL_CACHE",
        "SCOPY_MOCK_DATASET_ID",
        "SCOPY_PROFILE_SOURCE_FINGERPRINT",
        "SCOPY_PROFILE_EXECUTABLE_FINGERPRINT",
        "SCOPY_PROFILE_MAX_SAMPLES",
        "SCOPY_PROFILE_FIXED_COMMAND_COUNT",
        "SCOPY_PROFILE_WARM_ROUNDS",
        "SCOPY_PROFILE_AUTO_SCROLL_STEP_PX"
    ]

    var app: XCUIApplication!

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["--uitesting"]
        // Release UI-test builds must never perform the setUp launch against the user's real
        // clipboard/database before a scenario relaunches with its own environment.
        app.launchEnvironment["USE_MOCK_SERVICE"] = "1"
        app.launch()
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

    private var profileSkipAXListQuery: Bool {
        envValue("SCOPY_PROFILE_SKIP_AX_LIST_QUERY") == "1"
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

    func testScrollProfileFixedWarmText() throws {
        try runScrollProfileScenario(
            scenario: "fixed-warm-text",
            itemCount: 50,
            imageCount: 0,
            showThumbnails: false,
            textLength: 4096,
            accessibility: false,
            durationSeconds: 12,
            minSamples: 120
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

    func testScrollProfileRealSnapshotSearchEvidence() throws {
        try runScrollProfileScenario(
            scenario: "real-snapshot-search-evidence",
            itemCount: 0,
            imageCount: 0,
            showThumbnails: true,
            textLength: 0,
            accessibility: false,
            dataSource: .realSnapshot,
            durationSeconds: 10,
            minSamples: 260,
            searchQuery: ".",
            searchMode: "regex"
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
        minSamples: Int = 180,
        searchQuery: String? = nil,
        searchMode: String? = nil
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
        if let searchQuery {
            app.launchEnvironment["SCOPY_PROFILE_SEARCH_QUERY"] = searchQuery
        }
        if let searchMode {
            app.launchEnvironment["SCOPY_PROFILE_SEARCH_MODE"] = searchMode
        }
        let autoScroll = envValue("SCOPY_PROFILE_AUTO_SCROLL") ?? "1"
        app.launchEnvironment["SCOPY_PROFILE_AUTO_SCROLL"] = autoScroll
        let fixedCommandCount = parseInt(envValue("SCOPY_PROFILE_FIXED_COMMAND_COUNT")) ?? 0
        if fixedCommandCount > 0, fixedCommandCount < resolvedMinSamples {
            XCTFail(
                "Fixed profile command count (\(fixedCommandCount)) must be at least "
                    + "the resolved minimum sample count (\(resolvedMinSamples))"
            )
            return
        }
        let startNotificationName: Notification.Name? = fixedCommandCount > 0 || searchQuery != nil
            ? Notification.Name("org.scopy.profile.start.\(safeFileToken(profileRunID))")
            : nil
        if let startNotificationName {
            app.launchEnvironment["SCOPY_PROFILE_START_NOTIFICATION"] = startNotificationName.rawValue
        }

        if fixedCommandCount > 0 {
            // The fixed workload is an idle-scroll benchmark. Moving the pointer to the screen
            // corner prevents rows scrolling underneath a stationary cursor from becoming real
            // hover interactions and contaminating the passive-row lifecycle counters.
            CGWarpMouseCursorPosition(.zero)
        }
        app.launch()

        let skippedAXListQuery = profileSkipAXListQuery
        if skippedAXListQuery {
            if autoScroll == "0" {
                throw XCTSkip("Manual scroll profile requires AX list access")
            }
            if searchQuery == nil {
                postProfileStartNotification(startNotificationName)
            }
            waitForAutomatedScroll(durationSeconds: resolvedDuration)
        } else {
            _ = prepareMainWindow()

            let list = app.anyElement("History.List")
            guard list.waitForExistence(timeout: 15) else {
                XCTFail("List not found")
                return
            }
            if searchQuery == nil {
                postProfileStartNotification(startNotificationName)
            }
            if autoScroll == "0" {
                exerciseScroll(on: list, durationSeconds: resolvedDuration)
            } else {
                waitForAutomatedScroll(durationSeconds: resolvedDuration)
            }
        }

        let predicate = NSPredicate { _, _ in
            FileManager.default.fileExists(atPath: profilePath)
        }
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: nil)
        let profileTimeout = fixedCommandCount > 0
            ? max(45, resolvedDuration + 30)
            : max(12, resolvedDuration + 6)
        let result = XCTWaiter.wait(for: [expectation], timeout: profileTimeout)
        XCTAssertEqual(result, .completed, "Profile output not found at \(profilePath)")

        let data = try Data(contentsOf: URL(fileURLWithPath: profilePath))
        var json = try JSONSerialization.jsonObject(with: data, options: []) as? [String: Any]
        if fixedCommandCount > 0 {
            guard let rawProfile = json else {
                XCTFail("Fixed profile output is not a JSON object")
                return
            }
            assertFixedWorkloadRawSchema(rawProfile)
        }
        let accessibilityQuery: [String: Any]
        if skippedAXListQuery {
            accessibilityQuery = [
                "list_exists": NSNull(),
                "list_query_skipped": true,
                "history_item_query_skipped": true,
                "history_item_query_skip_reason": "disabled_xcode27_ax_list_query"
            ]
        } else {
            accessibilityQuery = measureAccessibilityQuery(listAlreadyFound: true)
        }
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

        if let searchQuery {
            let workload = json?["fixed_workload"] as? [String: Any]
            let evidenceCount = workload?["search_evidence_count"] as? Int ?? 0
            let loadedCount = workload?["loaded_count"] as? Int ?? 0
            XCTAssertGreaterThan(
                loadedCount,
                0,
                "Search profile must load at least one result row"
            )
            XCTAssertEqual(
                evidenceCount,
                loadedCount,
                "Every profiled search result must render backend-provided evidence"
            )
            XCTAssertEqual(workload?["search_query"] as? String, searchQuery)
            XCTAssertEqual(workload?["search_mode"] as? String, searchMode)
            XCTAssertEqual(workload?["search_ready"] as? Bool, true)
        }

        let scenarioName = json?["profile_scenario"] as? String ?? ""
        XCTAssertEqual(scenarioName, scenario, "Profile scenario mismatch")
    }

    private func assertFixedWorkloadRawSchema(_ profile: [String: Any]) {
        let requiredCounters = [
            "interaction.session_init",
            "interaction.observer_install",
            "interaction.idle_disappear_fast_path",
            "row.descriptor_cache_hit",
            "row.descriptor_cache_miss",
            "row.relative_time_cache_hit",
            "row.relative_time_cache_miss",
            "list.load_more_attempt",
            "list.pagination_request",
            "row.markdown_menu_signal_cache_hit",
            "row.markdown_menu_signal_cache_miss",
            "row.markdown_menu_signal_uncached",
            "profile.ingress_coalesced",
            "profile.ingress_dropped"
        ]
        let requiredGauges = [
            "active_slot_current",
            "active_slot_max",
            "suppressed_candidate_current",
            "suppressed_candidate_max"
        ]

        guard let config = profile["config"] as? [String: Any],
              let workload = profile["fixed_workload"] as? [String: Any],
              let dataset = workload["dataset"] as? [String: Any],
              let counters = profile["counters"] as? [String: Any],
              let gauges = profile["gauges"] as? [String: Any],
              let buckets = profile["timing_buckets_ms"] as? [String: Any],
              let rowBucket = buckets["swiftui.row_body_ms"] as? [String: Any],
              let runLoop = profile["main_runloop_active_ms"] as? [String: Any],
              let callback = profile["animation_callback_interval_ms"] as? [String: Any],
              let sampleHealth = profile["scroll_sample_health"] as? [String: Any],
              let timingEventRetention = profile["timing_event_retention"] as? [String: Any],
              let runLoopEventRetention = profile["main_runloop_event_retention"] as? [String: Any]
        else {
            XCTFail("Fixed profile is missing its config, workload, retention, or structural schema")
            return
        }

        let datasetID = app.launchEnvironment["SCOPY_MOCK_DATASET_ID"] ?? ""
        let sourceFingerprint = app.launchEnvironment["SCOPY_PROFILE_SOURCE_FINGERPRINT"] ?? ""
        let executableFingerprint = app.launchEnvironment["SCOPY_PROFILE_EXECUTABLE_FINGERPRINT"] ?? ""
        let commandCount = Int(app.launchEnvironment["SCOPY_PROFILE_FIXED_COMMAND_COUNT"] ?? "") ?? 0
        XCTAssertFalse(datasetID.isEmpty, "Fixed profile requires SCOPY_MOCK_DATASET_ID")
        XCTAssertTrue(isSHA256Fingerprint(sourceFingerprint), "Fixed profile requires a source fingerprint")
        XCTAssertTrue(
            isSHA256Fingerprint(executableFingerprint),
            "Fixed profile requires an executable fingerprint"
        )
        XCTAssertEqual(config["mock_dataset_id"] as? String, datasetID)
        XCTAssertEqual(config["source_fingerprint"] as? String, sourceFingerprint)
        XCTAssertEqual(config["executable_fingerprint"] as? String, executableFingerprint)
        XCTAssertEqual(config["runner_executable_fingerprint"] as? String, executableFingerprint)
        XCTAssertEqual(config["build_configuration"] as? String, "Release")
        XCTAssertEqual(
            config["max_samples"] as? Int,
            Int(app.launchEnvironment["SCOPY_PROFILE_MAX_SAMPLES"] ?? "")
        )
        for key in [
            "SCOPY_PERF_HISTORY_INDEX",
            "SCOPY_PERF_SCROLL_RESOLVER_CACHE",
            "SCOPY_PERF_MARKDOWN_RESOLVER_CACHE",
            "SCOPY_PERF_SHORT_QUERY_DEBOUNCE"
        ] {
            XCTAssertEqual(config[key] as? String, "1", "Fixed profile requires config.\(key)=1")
        }

        XCTAssertEqual(dataset["schema"] as? String, "history-profile-dataset-v1")
        XCTAssertEqual(dataset["id"] as? String, datasetID)
        XCTAssertTrue(
            isSHA256Fingerprint(dataset["fingerprint"] as? String ?? ""),
            "Fixed profile requires a dataset fingerprint"
        )
        XCTAssertEqual(dataset["item_count"] as? Int, 50)
        XCTAssertEqual(dataset["text_item_count"] as? Int, 50)
        XCTAssertEqual(dataset["image_item_count"] as? Int, 0)
        XCTAssertEqual(dataset["pinned_item_count"] as? Int, 2)
        XCTAssertEqual(dataset["unique_item_id_count"] as? Int, 50)
        XCTAssertEqual(dataset["text_utf8_bytes_min"] as? Int, 4_096)
        XCTAssertEqual(dataset["text_utf8_bytes_max"] as? Int, 4_096)

        XCTAssertEqual(workload["issued_command_count"] as? Int, commandCount)
        XCTAssertEqual(workload["measured_command_response_count"] as? Int, commandCount)
        XCTAssertEqual(workload["pre_measurement_settle_callback_count"] as? Int, 1)
        XCTAssertEqual(workload["post_measurement_settle_callback_count"] as? Int, 1)
        XCTAssertEqual(workload["finalization_state"] as? String, "response_captured_and_drained")
        XCTAssertEqual(callback["retained_count"] as? Int, commandCount)
        XCTAssertEqual(callback["total_count"] as? Int, commandCount)
        XCTAssertEqual(callback["overwritten_count"] as? Int, 0)
        XCTAssertEqual(sampleHealth["animation_callback_total_count"] as? Int, commandCount)
        XCTAssertEqual(sampleHealth["animation_callback_overwritten_count"] as? Int, 0)
        assertUntruncatedMetric(rowBucket, label: "swiftui.row_body_ms")
        assertUntruncatedMetric(runLoop, label: "main_runloop_active_ms")
        assertUntruncatedRetention(timingEventRetention, label: "timing events")
        assertUntruncatedRetention(runLoopEventRetention, label: "main-run-loop events")

        for key in requiredCounters {
            XCTAssertNotNil(counters[key] as? NSNumber, "Missing explicit counter: \(key)")
        }
        for key in requiredGauges {
            XCTAssertNotNil(gauges[key] as? NSNumber, "Missing explicit gauge: \(key)")
        }
    }

    private func assertUntruncatedMetric(_ metric: [String: Any], label: String) {
        let retainedCount = metric["retained_count"] as? Int ?? -1
        let totalCount = metric["total_count"] as? Int ?? -1
        XCTAssertGreaterThan(totalCount, 0, "\(label) requires whole-run samples")
        XCTAssertEqual(retainedCount, totalCount, "\(label) must retain its full formal run")
        XCTAssertEqual(metric["overwritten_count"] as? Int, 0, "\(label) was truncated")
        XCTAssertNotNil(metric["total_ms"] as? NSNumber, "\(label) requires an O(1) whole-run total")
        XCTAssertNotNil(metric["p95"] as? NSNumber, "\(label) p95 requires an untruncated run")
    }

    private func assertUntruncatedRetention(_ retention: [String: Any], label: String) {
        let retainedCount = retention["retained_count"] as? Int ?? -1
        let totalCount = retention["total_count"] as? Int ?? -1
        XCTAssertEqual(retainedCount, totalCount, "\(label) must retain its full formal run")
        XCTAssertEqual(retention["overwritten_count"] as? Int, 0, "\(label) was truncated")
    }

    private func isSHA256Fingerprint(_ value: String) -> Bool {
        value.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
    }

    private func exerciseScroll(on list: XCUIElement, durationSeconds: TimeInterval) {
        guard list.waitForExistence(timeout: 5) else { return }
        if list.isHittable {
            list.click()
        }

        let endTime = Date().addingTimeInterval(durationSeconds)
        var step = 0
        while Date() < endTime {
            guard list.exists else {
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

    private func postProfileStartNotification(_ name: Notification.Name?) {
        guard let name else { return }
        DistributedNotificationCenter.default().postNotificationName(
            name,
            object: nil,
            userInfo: nil,
            deliverImmediately: true
        )
    }

    private func measureAccessibilityQuery(listAlreadyFound: Bool) -> [String: Any] {
        let enableUnboundedItemQuery = envValue("SCOPY_PROFILE_XCTEST_ITEM_QUERY") == "1"
        var result: [String: Any] = [
            "list_exists": listAlreadyFound,
            "history_item_query_skipped": !enableUnboundedItemQuery
        ]

        guard enableUnboundedItemQuery else {
            result["history_item_query_skip_reason"] = "disabled_unbounded_xcui_query"
            return result
        }

        let itemStart = CFAbsoluteTimeGetCurrent()
        let itemCount = app.anyElements(matching: NSPredicate(format: "identifier BEGINSWITH %@", "History.Item.")).count
        let itemQueryMs = (CFAbsoluteTimeGetCurrent() - itemStart) * 1000

        result["history_item_count"] = itemCount
        result["history_item_query_ms"] = itemQueryMs
        return result
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
        app.activate()
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
