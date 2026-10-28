import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class SettingsConcurrencyMergeTests: XCTestCase {

    func testSavingAStaleDraftPersistsItsChangesWithoutRevertingTheNewHotkey() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-settings-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }
        let suitePath = settingsDirectory.appendingPathComponent("settings").path

        let store = SettingsStore(suiteName: suitePath)
        let service = ClipboardServiceFactory.create(
            databasePath: "file:scopy_settings_merge_\(UUID().uuidString)?mode=memory&cache=shared",
            settingsStore: store
        )
        let viewModel = SettingsViewModel(service: service)
        await viewModel.loadSettings()
        let baseline = viewModel.settings

        var draft = baseline
        draft.maxItems = max(1, baseline.maxItems + 1)
        draft.hotkeyKeyCode = baseline.hotkeyKeyCode &+ 1
        draft.hotkeyModifiers = baseline.hotkeyModifiers &+ 1
        let patch = SettingsPatch.from(baseline: baseline, draft: draft)
            .droppingHotkey()

        await store.updateHotkey(keyCode: 777, modifiers: 888)
        let committed = try await viewModel.updateSettings(patch)
        let reopened = SettingsStore(suiteName: suitePath)
        let persisted = await reopened.load()

        XCTAssertEqual(persisted.maxItems, draft.maxItems)
        XCTAssertEqual(persisted.hotkeyKeyCode, 777)
        XCTAssertEqual(persisted.hotkeyModifiers, 888)
        XCTAssertEqual(committed, persisted)
        XCTAssertEqual(viewModel.settings, persisted)
    }

    func testConcurrentFieldPatchesAndHotkeyUpdateSurviveAStoreReopen() async throws {
        let settingsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-settings-merge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: settingsDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: settingsDirectory) }
        let suitePath = settingsDirectory.appendingPathComponent("settings").path
        let store = SettingsStore(suiteName: suitePath)
        var captureDraft = SettingsDTO.default
        captureDraft.saveImages = false
        let capturePatch = SettingsPatch.from(baseline: .default, draft: captureDraft)
        var appearanceDraft = SettingsDTO.default
        appearanceDraft.thumbnailHeight = 64
        let appearancePatch = SettingsPatch.from(baseline: .default, draft: appearanceDraft)

        async let capture = store.apply(capturePatch)
        async let appearance = store.apply(appearancePatch)
        async let hotkey: Void = store.updateHotkey(keyCode: 333, modifiers: 444)
        let (savedCapture, savedAppearance, _) = await (capture, appearance, hotkey)
        let reopened = SettingsStore(suiteName: suitePath)
        let persisted = await reopened.load()

        XCTAssertFalse(savedCapture.saveImages)
        XCTAssertEqual(savedAppearance.thumbnailHeight, 64)
        XCTAssertFalse(persisted.saveImages)
        XCTAssertEqual(persisted.thumbnailHeight, 64)
        XCTAssertEqual(persisted.hotkeyKeyCode, 333)
        XCTAssertEqual(persisted.hotkeyModifiers, 444)
    }
}

