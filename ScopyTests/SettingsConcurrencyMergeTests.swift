import XCTest
import ScopyKit

@testable import Scopy

@MainActor
final class SettingsConcurrencyMergeTests: XCTestCase {

    func testUpdateDefaultSearchModeDoesNotOverrideHotkey() async {
        let suiteName = "ScopyTests.SettingsConcurrencyMergeTests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(suiteName: suiteName)
        let service = ClipboardServiceFactory.createForTesting(settingsStore: store)
        let viewModel = SettingsViewModel(service: service)

        await store.updateHotkey(keyCode: 123, modifiers: 456)

        await viewModel.updateDefaultSearchMode(.regex)

        let final = await store.load()
        XCTAssertEqual(final.hotkeyKeyCode, 123)
        XCTAssertEqual(final.hotkeyModifiers, 456)
        XCTAssertEqual(final.defaultSearchMode, .regex)
    }

    func testSettingsPatchMergePreservesExternalHotkey() async throws {
        let suiteName = "ScopyTests.SettingsConcurrencyMergeTests.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defer { UserDefaults.standard.removePersistentDomain(forName: suiteName) }

        let store = SettingsStore(suiteName: suiteName)
        let service = ClipboardServiceFactory.createForTesting(settingsStore: store)

        let baseline = await store.load()

        var draft = baseline
        draft.maxItems = max(1, baseline.maxItems + 1)
        draft.hotkeyKeyCode = baseline.hotkeyKeyCode &+ 1
        draft.hotkeyModifiers = baseline.hotkeyModifiers &+ 1

        await store.updateHotkey(keyCode: 777, modifiers: 888)
        let latest = try await service.getSettings()

        let patch = SettingsPatch.from(baseline: baseline, draft: draft)
            .droppingHotkey()

        XCTAssertFalse(patch.isEmpty)

        let merged = latest.applying(patch)
        XCTAssertEqual(merged.maxItems, draft.maxItems)
        XCTAssertEqual(merged.hotkeyKeyCode, 777)
        XCTAssertEqual(merged.hotkeyModifiers, 888)
    }

    func testSettingsPatchDroppingHotkeyIsEmptyWhenOnlyHotkeyChanges() {
        let baseline = SettingsDTO.default
        var draft = baseline
        draft.hotkeyKeyCode = baseline.hotkeyKeyCode &+ 1

        let patch = SettingsPatch.from(baseline: baseline, draft: draft)
            .droppingHotkey()

        XCTAssertTrue(patch.isEmpty)
    }
}

