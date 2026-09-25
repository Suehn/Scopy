import AppKit
import Carbon.HIToolbox
import CoreGraphics
import ScopyKit
import ScopyUISupport
import Sparkle
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    struct CodexPasteShortcut {
        static let virtualKey: CGKeyCode = 9
        static let flags: CGEventFlags = .maskControl
    }

    enum QuickSlotShortcut {
        /// ⌘1–9 by layout-independent key code (kVK_ANSI_1…9), not by character: on AZERTY the
        /// unshifted "1" key types "&".
        private static let slotsByKeyCode: [UInt16: Int] = [
            UInt16(kVK_ANSI_1): 1, UInt16(kVK_ANSI_2): 2, UInt16(kVK_ANSI_3): 3,
            UInt16(kVK_ANSI_4): 4, UInt16(kVK_ANSI_5): 5, UInt16(kVK_ANSI_6): 6,
            UInt16(kVK_ANSI_7): 7, UInt16(kVK_ANSI_8): 8, UInt16(kVK_ANSI_9): 9
        ]

        static func slot(forKeyCode keyCode: UInt16) -> Int? {
            slotsByKeyCode[keyCode]
        }
    }

    enum OptionDeleteShortcut {
        /// ⌥⌫ deletes the selected history item only when pressed in the history window and no
        /// text is being edited there: the search field and note editors keep word deletion.
        @MainActor
        static func deletesItem(eventWindow: NSWindow?, historyWindow: NSWindow?) -> Bool {
            guard let eventWindow, eventWindow === historyWindow else { return false }
            let responder = eventWindow.firstResponder
            return !(responder is NSText || responder is NSTextField)
        }
    }

    var panel: FloatingPanel?
    private var uiTestWindow: NSWindow?
    private(set) var hotKeyService: HotKeyService?
    private lazy var settingsWindowCoordinator = SettingsWindowCoordinator()
    private lazy var appState = AppState.shared
    private var appliedHotKey: (keyCode: UInt32, modifiers: UInt32)?
    private var isHotKeyRegistered = false
    private let settingsStore: SettingsStore = .shared
    /// Sparkle auto-update: checks the appcast daily, reminds the user when a new version
    /// exists, and installs + relaunches on confirmation. Disabled in UI-test harnesses.
    private(set) var updaterController: SPUStandardUpdaterController?
    private var localEventMonitors: [Any] = []
    private var memoryPressureSource: DispatchSourceMemoryPressure?

    private lazy var statusItem: NSStatusItem = {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Scopy")
        statusItem.button?.action = #selector(togglePanel)
        statusItem.button?.target = self
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        return statusItem
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ScrollPerformanceProfile.isEnabled {
            ScrollPerformanceProfile.shared.prepareForLaunch()
        }
        let context = resolveLaunchContext()

        if !context.isUITesting {
            updaterController = SPUStandardUpdaterController(
                startingUpdater: true,
                updaterDelegate: nil,
                userDriverDelegate: nil
            )
        }

        #if DEBUG
        if context.isExportHarness {
            uiTestWindow = makeExportHarnessWindow()
            return
        }

        if context.isHistoryItemHarness {
            uiTestWindow = makeHistoryItemHarnessWindow()
            return
        }

        if context.isListLiveScrollObserverHarness {
            uiTestWindow = makeListLiveScrollObserverHarnessWindow()
            return
        }
        #endif

        let rootView = makeRootView(appState: appState)

        if context.isUITesting {
            uiTestWindow = makeUITestWindow(rootView: rootView)
        } else {
            panel = makeMainPanel(rootView: rootView)
        }

        _ = statusItem

        configureAppHandlers(appState: appState, isUITesting: context.isUITesting)

        ScrollCursorSetCoalescer.install()

        // Profiling harnesses drive the real panel with synthetic input; open it without a hotkey or status-item click.
        if !context.isUITesting, ProcessInfo.processInfo.environment["SCOPY_PROFILE_OPEN_PANEL"] == "1" {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.panel?.toggle(positionMode: .statusBar)
            }
        }

        Task {
            await appState.start()
        }

        if context.isUITesting, ProcessInfo.processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN"] == "1" {
            Task { @MainActor in
                await self.runUITestAutoExportMarkdown(appState: appState)
            }
        }

        setupHotKeyRegistration()
        installLocalEventMonitors()
        installMemoryPressureHandler()
    }

    private struct LaunchContext {
        let isUITesting: Bool
        let isExportHarness: Bool
        let isHistoryItemHarness: Bool
        let isListLiveScrollObserverHarness: Bool
    }

    private func resolveLaunchContext() -> LaunchContext {
        let isUITesting = ProcessInfo.processInfo.arguments.contains("--uitesting")
        #if DEBUG
        let isExportHarness = isUITesting && ProcessInfo.processInfo.environment["SCOPY_UITEST_EXPORT_HARNESS"] == "1"
        let isHistoryItemHarness = isUITesting && ProcessInfo.processInfo.environment["SCOPY_UITEST_HISTORY_ITEM_HARNESS"] == "1"
        let isListLiveScrollObserverHarness = isUITesting
            && ProcessInfo.processInfo.arguments.contains("--list-live-scroll-observer-harness")
            && ProcessInfo.processInfo.environment["SCOPY_UITEST_LIST_LIVE_SCROLL_OBSERVER_HARNESS"] == "1"
        #else
        // Harness windows and the mock service are compiled only into Debug builds.
        let isExportHarness = false
        let isHistoryItemHarness = false
        let isListLiveScrollObserverHarness = false
        #endif
        return LaunchContext(
            isUITesting: isUITesting,
            isExportHarness: isExportHarness,
            isHistoryItemHarness: isHistoryItemHarness,
            isListLiveScrollObserverHarness: isListLiveScrollObserverHarness
        )
    }

    private func makeRootView(appState: AppState) -> some View {
        ContentView()
            .environment(appState)
            .environment(appState.historyViewModel)
            .environment(appState.settingsViewModel)
    }

    #if DEBUG
    private func makeExportHarnessWindow() -> NSWindow {
        let window = makeHostingWindow(
            rootView: ExportPreviewHarnessView(),
            size: NSSize(width: 820, height: 620),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            title: "Scopy Export Harness",
            level: .floating
        )
        return window
    }

    private func makeHistoryItemHarnessWindow() -> NSWindow {
        let window = makeHostingWindow(
            rootView: HistoryItemHarnessView(),
            size: NSSize(width: 880, height: 360),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            title: "Scopy History Item Harness",
            level: .floating
        )
        return window
    }

    private func makeListLiveScrollObserverHarnessWindow() -> NSWindow {
        makeHostingWindow(
            rootView: ListLiveScrollObserverHarnessView(),
            size: NSSize(width: 920, height: 700),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            title: "Scopy List Live Scroll Observer Harness",
            level: .floating
        )
    }
    #endif

    private func makeUITestWindow<V: View>(rootView: V) -> NSWindow {
        let window = makeHostingWindow(
            rootView: rootView,
            size: NSSize(width: ScopySize.Window.mainWidth, height: ScopySize.Window.mainHeight),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            title: "Scopy",
            level: .floating
        )
        return window
    }

    private func makeMainPanel<V: View>(rootView: V) -> FloatingPanel {
        let panel = FloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: Int(ScopySize.Window.mainWidth), height: Int(ScopySize.Window.mainHeight)),
            statusBarButton: statusItem.button
        ) {
            rootView
        }
        panel.onClose = { [weak self] in
            // Hover bitmaps are only useful while the panel is open; pinned windows keep their own.
            HoverPreviewImageCache.shared.removeAll()
            // What the user last saw deleted must be deleted once the panel is gone.
            guard let self else { return }
            Task { @MainActor in
                self.appState.historyViewModel.setQuickSlotHintsVisible(false)
                await self.appState.historyViewModel.commitPendingDeletionNow()
            }
        }
        return panel
    }

    private func installMemoryPressureHandler() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler {
            MainActor.assumeIsolated { Self.purgeFrontendCaches() }
        }
        source.resume()
        memoryPressureSource = source
    }

    /// Frontend caches that rebuild on demand; dropped when the system reports memory pressure.
    static func purgeFrontendCaches() {
        HoverPreviewImageCache.shared.removeAll()
        MarkdownPreviewCache.shared.removeDocuments()
        ClipboardItemDisplayText.shared.clearCaches()
        HistoryItemPresentationCache.shared.clearCaches()
    }

    private func makeHostingWindow<V: View>(
        rootView: V,
        size: NSSize,
        styleMask: NSWindow.StyleMask,
        title: String,
        level: NSWindow.Level? = nil
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: Int(size.width), height: Int(size.height)),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        if let level {
            window.level = level
        }
        window.center()
        window.contentView = NSHostingView(rootView: rootView)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        return window
    }

    private func configureAppHandlers(appState: AppState, isUITesting: Bool) {
        appState.closePanelHandler = { [weak self] in
            if isUITesting {
                self?.uiTestWindow?.close()
            } else {
                self?.panel?.close()
            }
        }
        appState.pasteAfterCopyHandler = { [weak self] in
            self?.pasteIntoFrontmostAppAfterPanelCloses()
        }
        appState.openSettingsHandler = { [weak self] in
            self?.openSettings()
        }

        // Hotkey callbacks let SettingsView apply a recorded hotkey without knowing AppDelegate.
        appState.applyHotKeyHandler = { [weak self] keyCode, modifiers in
            self?.applyHotKey(keyCode: keyCode, modifiers: modifiers)
        }
        appState.unregisterHotKeyHandler = { [weak self] in
            self?.hotKeyService?.unregister()
            self?.isHotKeyRegistered = false
        }
    }

    private func setupHotKeyRegistration() {
        // Registers the persisted global hotkey (default ⇧⌘C).
        hotKeyService = HotKeyService()
        Task { @MainActor [weak self] in
            guard let self else { return }
            let settings = await settingsStore.load()
            applyHotKey(keyCode: settings.hotkeyKeyCode, modifiers: settings.hotkeyModifiers)
        }
    }

    /// ⌘ alone; ⇧⌘, ⌥⌘ and ⌃⌘ chords stay with the responder chain.
    private static func isPlainCommand(_ flags: NSEvent.ModifierFlags) -> Bool {
        flags.contains(.command) && flags.isDisjoint(with: [.shift, .option, .control])
    }

    /// Panel shortcuts live here rather than in SwiftUI so the first responder decides and the
    /// search field cannot consume them first.
    private func installLocalEventMonitors() {
        let keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }

            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            let historyWindow = self.panel ?? self.uiTestWindow

            // ⌥⌫ deletes the selected item unless text is being edited, where it stays word deletion.
            if flags.contains(.option),
               !flags.contains(.command),
               !flags.contains(.control),
               !flags.contains(.shift),
               (event.keyCode == 51 || event.keyCode == 117),
               OptionDeleteShortcut.deletesItem(eventWindow: event.window, historyWindow: historyWindow),
               self.appState.historyViewModel.selectedID != nil {
                Task { @MainActor in
                    await self.appState.historyViewModel.deleteSelectedItem()
                }
                return nil
            }

            let isPlainCommand = Self.isPlainCommand(flags)

            // ⌘Z undoes the last deletion only while its undo window is open; the rest of the
            // time the key stays text undo for the search field and note editors.
            if isPlainCommand,
               event.keyCode == UInt16(kVK_ANSI_Z),
               event.window === historyWindow,
               self.appState.historyViewModel.undoableDeletionID != nil {
                Task { @MainActor in
                    await self.appState.historyViewModel.undoPendingDeletion()
                }
                return nil
            }

            // ⌘1–9 copies the n-th displayed row and closes the panel, like ⏎ on that row.
            if isPlainCommand,
               event.window === historyWindow,
               let slot = QuickSlotShortcut.slot(forKeyCode: event.keyCode) {
                Task { @MainActor in
                    await self.appState.historyViewModel.selectQuickSlot(slot)
                }
                return nil
            }

            if isPlainCommand, event.charactersIgnoringModifiers == "," {
                self.openSettings()
                return nil
            }
            return event
        }

        // The ⌘n row hints follow the modifier state itself, not a key press.
        let flagsChangedMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            self.appState.historyViewModel.setQuickSlotHintsVisible(
                Self.isPlainCommand(flags) && self.panel?.isPresented == true
            )
            return event
        }

        localEventMonitors = [keyDownMonitor, flagsChangedMonitor].compactMap { $0 }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeyService?.unregister()
        isHotKeyRegistered = false
        localEventMonitors.forEach(NSEvent.removeMonitor)
        localEventMonitors.removeAll()
        memoryPressureSource?.cancel()
        memoryPressureSource = nil
        appState.stop()
    }

    @objc func togglePanel() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showStatusMenu()
            return
        }
        // A status-item click opens the panel below the menu bar.
        if let panel {
            panel.toggle(positionMode: .statusBar)
        } else if let uiTestWindow {
            if uiTestWindow.isVisible {
                uiTestWindow.close()
            } else {
                uiTestWindow.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    /// Right-click menu of the status item. Assigning the menu only for this click keeps the
    /// left click toggling the panel.
    private func showStatusMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Open Scopy"), action: #selector(openPanelFromStatusMenu), keyEquivalent: "")
            .target = self
        menu.addItem(withTitle: String(localized: "Settings…"), action: #selector(openSettingsFromStatusMenu), keyEquivalent: ",")
            .target = self
        if let updaterController {
            menu.addItem(
                withTitle: String(localized: "Check for Updates…"),
                action: #selector(SPUStandardUpdaterController.checkForUpdates(_:)),
                keyEquivalent: ""
            ).target = updaterController
        }
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Quit Scopy"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openPanelFromStatusMenu() {
        if let panel {
            if !panel.isPresented {
                panel.open(positionMode: .statusBar)
            }
        } else {
            togglePanel()
        }
    }

    @objc private func openSettingsFromStatusMenu() {
        openSettings()
    }

    func togglePanelAtMousePosition() {
        // A hotkey press opens the panel at the mouse pointer.
        if let panel {
            if !panel.isPresented,
               panel.wasClosedLongerThan(PanelReopenSearchResetPolicy.staleIntervalSeconds) {
                appState.historyViewModel.clearSearchForPanelReopen()
            }
            panel.toggle(positionMode: .mousePosition)
        } else {
            togglePanel()
        }
    }

    private func pasteIntoFrontmostAppAfterPanelCloses() {
        let targetApplication = NSWorkspace.shared.frontmostApplication

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            if let targetApplication, targetApplication.bundleIdentifier != Bundle.main.bundleIdentifier {
                targetApplication.activate(options: [])
            }

            let source = CGEventSource(stateID: .hidSystemState)
            let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: CodexPasteShortcut.virtualKey,
                keyDown: true
            )
            let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: CodexPasteShortcut.virtualKey,
                keyDown: false
            )
            keyDown?.flags = CodexPasteShortcut.flags
            keyUp?.flags = CodexPasteShortcut.flags
            keyDown?.post(tap: .cghidEventTap)
            keyUp?.post(tap: .cghidEventTap)
        }
    }

    // MARK: - UI Testing

    @MainActor
    private func runUITestAutoExportMarkdown(appState: AppState) async {
        let dumpPath = ProcessInfo.processInfo.environment["SCOPY_EXPORT_DUMP_PATH"] ?? ""
        let errorPath = ProcessInfo.processInfo.environment["SCOPY_EXPORT_ERROR_DUMP_PATH"] ?? ""

        if let markdownPath = ProcessInfo.processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_MARKDOWN_PATH"],
           !markdownPath.isEmpty,
           let markdown = try? String(contentsOfFile: markdownPath, encoding: .utf8),
           !markdown.isEmpty {
            let settings = await uiTestMarkdownExportSettings()
            let result = await HistoryItemMarkdownExportController.exportMarkdownToClipboard(
                markdownSource: markdown,
                settings: settings
            )
            if case .failure(let error) = result, !errorPath.isEmpty {
                try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
            }
            return
        }

        if let htmlPath = ProcessInfo.processInfo.environment["SCOPY_UITEST_AUTO_EXPORT_HTML_PATH"],
           !htmlPath.isEmpty,
           let html = try? String(contentsOfFile: htmlPath, encoding: .utf8),
           !html.isEmpty {
            let settings = await uiTestMarkdownExportSettings()
            let pngquantOptions = HistoryItemMarkdownExportController.pngquantOptions(settings: settings)
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                MarkdownExportService.exportToPNGClipboard(
                    html: html,
                    targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels,
                    resolutionScale: HistoryItemMarkdownExportController.defaultResolutionScale(),
                    pngquantOptions: pngquantOptions
                ) { result in
                    if case .failure(let error) = result, !errorPath.isEmpty {
                        try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
                    }
                    continuation.resume()
                }
            }
            return
        }

        // Wait for history to load.
        for _ in 0..<200 {
            if !appState.historyViewModel.items.isEmpty { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }

        guard let item = appState.historyViewModel.items.first(where: { $0.plainText.contains("SCOPY_EXPORT_TEST_MARKDOWN") }) else {
            if !errorPath.isEmpty {
                try? Data("Missing SCOPY_EXPORT_TEST_MARKDOWN fixture".utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
            }
            return
        }

        let html = MarkdownHTMLDocumentBuilder.document(source: item.plainText)

        MarkdownExportService.exportToPNGClipboard(html: html, targetWidthPixels: MarkdownExportService.defaultTargetWidthPixels) { result in
            if case .failure(let error) = result, !errorPath.isEmpty {
                try? Data(String(describing: error).utf8).write(to: URL(fileURLWithPath: errorPath), options: [.atomic])
            } else if case .success = result, !dumpPath.isEmpty {
                // exportToPNGClipboard already writes the dump; nothing else needed.
            }
        }
    }

    private func uiTestMarkdownExportSettings() async -> SettingsDTO {
        var settings = await settingsStore.load()
        let env = ProcessInfo.processInfo.environment
        if env["SCOPY_UITEST_FORCE_PNGQUANT_MARKDOWN_EXPORT"] == "0" {
            settings.pngquantMarkdownExportEnabled = false
        } else if env["SCOPY_UITEST_FORCE_PNGQUANT_MARKDOWN_EXPORT"] != nil {
            settings.pngquantMarkdownExportEnabled = true
        }
        return settings
    }

    // MARK: - Hotkey Settings

    /// Registers and persists the hotkey in one place so a change applies without a restart.
    @MainActor
    func applyHotKey(keyCode: UInt32, modifiers: UInt32) {
        let requested = (keyCode: keyCode, modifiers: modifiers)

        if hotKeyService?.isRegistered == true,
           let applied = appliedHotKey,
           applied.keyCode == requested.keyCode,
           applied.modifiers == requested.modifiers {
            return
        }

        if hotKeyService == nil {
            hotKeyService = HotKeyService()
        }

        let previousHotKey = appliedHotKey

        hotKeyService?.updateHotKey(
            keyCode: keyCode,
            modifiers: modifiers,
            handler: { [weak self] in
                self?.togglePanelAtMousePosition()
            }
        )

        guard hotKeyService?.isRegistered == true else {
            ScopyLog.hotkey.error(
                "Failed to register global hotkey, reverting. keyCode=\(keyCode, privacy: .public), modifiers=0x\(String(modifiers, radix: 16), privacy: .public)"
            )

            let fallback = previousHotKey ?? (SettingsDTO.default.hotkeyKeyCode, SettingsDTO.default.hotkeyModifiers)
            hotKeyService?.updateHotKey(
                keyCode: fallback.0,
                modifiers: fallback.1,
                handler: { [weak self] in
                    self?.togglePanelAtMousePosition()
                }
            )

            if hotKeyService?.isRegistered == true {
                appliedHotKey = (fallback.0, fallback.1)
                isHotKeyRegistered = true
                persistHotkeySettings(keyCode: fallback.0, modifiers: fallback.1)
            } else {
                appliedHotKey = nil
                isHotKeyRegistered = false
            }
            return
        }

        appliedHotKey = requested
        isHotKeyRegistered = true
        persistHotkeySettings(keyCode: requested.keyCode, modifiers: requested.modifiers)
    }

    private func persistHotkeySettings(keyCode: UInt32, modifiers: UInt32) {
        let settingsStore = settingsStore
        Task {
            await settingsStore.updateHotkey(keyCode: keyCode, modifiers: modifiers)
        }
    }

    // MARK: - Settings Window

    /// Opens the settings window, or brings the existing one to the front.
    @MainActor
    func openSettings() {
        settingsWindowCoordinator.show(
            appState: appState,
            checkForUpdates: updaterController.map { updaterController in
                { updaterController.checkForUpdates(nil) }
            }
        )
    }
}
