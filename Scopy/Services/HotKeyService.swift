import AppKit
import Carbon.HIToolbox

/// The hotkey debug log, rotated past 10 MB.
private let logPath = "/tmp/scopy_hotkey.log"
private let logPathOld = "/tmp/scopy_hotkey.log.old"
private let maxLogSize = 10 * 1024 * 1024  // 10MB

/// Serializes log writes off the calling thread.
private let logQueue = DispatchQueue(label: "com.scopy.hotkey.log", qos: .utility)

/// Logs to ScopyLog and appends to the rotated debug log file asynchronously.
private func logToFile(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    ScopyLog.hotkey.info("\(message, privacy: .public)")

    guard let data = logMessage.data(using: .utf8) else { return }

    logQueue.async {
        // Rotate: the current log replaces the previous backup.
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int, size > maxLogSize {
            try? FileManager.default.removeItem(atPath: logPathOld)
            try? FileManager.default.moveItem(atPath: logPath, toPath: logPathOld)
        }

        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
}

/// Registers the global hotkey through Carbon and dispatches presses to the handler.
/// Modeled on soffes/HotKey: the event's hotKeyID (read with `GetEventParameter`) selects the
/// handler, so a newly recorded shortcut takes effect without a relaunch.
public final class HotKeyService {
    // MARK: - Types

    public typealias HotKeyHandler = @MainActor @Sendable () -> Void

    // MARK: - Static Properties (required by the Carbon API)

    private struct SharedState {
        var handlers: [UInt32: HotKeyHandler] = [:]
        var eventHandlerRef: EventHandlerRef?
        var isInstallingEventHandler = false
        var nextHotKeyID: UInt32 = 1
        var lastFire: (id: UInt32, timestamp: CFAbsoluteTime)?
        #if DEBUG
        var testingMode = false
        #endif
    }

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value

        init(_ value: Value) {
            self.value = value
        }

        func withValue<R>(_ body: (inout Value) -> R) -> R {
            lock.withLock { body(&value) }
        }
    }

    private static let sharedState = Locked(SharedState())

    /// Hotkey signature.
    private static let hotKeySignature: OSType = {
        var result: OSType = 0
        for char in "SCPY".utf8.prefix(4) {
            result = (result << 8) + OSType(char)
        }
        return result
    }()

    /// The next hotKeyID, serialized through the shared state and wrapped before overflow.
    private static func getNextHotKeyID() -> UInt32 {
        return sharedState.withValue { state in
            // Near overflow, wrap to 1 (0 usually means an invalid ID), leaving a 1000-ID margin.
            if state.nextHotKeyID >= UInt32.max - 1000 {
                logToFile("⚠️ HotKeyID approaching overflow, resetting to 1")
                state.nextHotKeyID = 1
            }
            let id = state.nextHotKeyID
            state.nextHotKeyID += 1
            return id
        }
    }

    // MARK: - Instance Properties

    private var hotKeyRef: EventHotKeyRef?
    private let currentHotKeyIDBox = Locked(UInt32(0))

    private var currentHotKeyID: UInt32 {
        get { currentHotKeyIDBox.withValue { $0 } }
        set { currentHotKeyIDBox.withValue { $0 = newValue } }
    }

    // Default shortcut: ⇧⌘C
    private let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_C)  // 8
    private let defaultModifiers: UInt32 = 0x0300  // shiftKey | cmdKey

    // MARK: - Initialization

    public init() {
        logToFile("🔧 HotKeyService init")
        Self.installEventHandlerIfNeeded()
    }

    deinit {
        unregister()
    }

    // MARK: - Private: Event Handler Installation

    /// Installs the event handler once.
    private static func installEventHandlerIfNeeded() {
        let shouldInstall = sharedState.withValue { state -> Bool in
            guard state.eventHandlerRef == nil else {
                logToFile("⚠️ Event handler already installed")
                return false
            }
            guard !state.isInstallingEventHandler else {
                logToFile("⚠️ Event handler installation already in progress")
                return false
            }
            state.isInstallingEventHandler = true
            return true
        }

        guard shouldInstall else { return }

        // Pressed events only: handling release too would fire twice and show only while held.
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]

        var handlerRef: EventHandlerRef?
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonEventCallback,
            eventTypes.count,
            &eventTypes,
            nil,
            &handlerRef
        )

        sharedState.withValue { state in
            state.isInstallingEventHandler = false
            if status == noErr {
                state.eventHandlerRef = handlerRef
            }
        }

        if status == noErr {
            logToFile("✅ Carbon event handler installed")
        } else {
            logToFile("❌ Failed to install event handler: \(status)")
        }
    }

    // MARK: - Public API

    /// Registers the default global shortcut.
    public func register(handler: @escaping HotKeyHandler) {
        logToFile("🔧 register() called with default hotkey")
        registerHotKey(keyCode: defaultKeyCode, modifiers: defaultModifiers, handler: handler)
    }

    /// Unregisters the global shortcut.
    public func unregister() {
        guard let hotKeyRef = hotKeyRef else {
            logToFile("⚠️ unregister() called but no hotkey registered")
            return
        }

        let hotKeyID = currentHotKeyID
        let status = UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil

        // Remove the handler from the shared state.
        Self.sharedState.withValue { state in
            _ = state.handlers.removeValue(forKey: hotKeyID)
        }
        logToFile("🔑 Global hotkey unregistered: id=\(hotKeyID), status=\(status)")
        currentHotKeyID = 0
    }

    /// Replaces the shortcut; used by Settings.
    public func updateHotKey(keyCode: UInt32, modifiers: UInt32, handler: @escaping HotKeyHandler) {
        logToFile("🔧 updateHotKey() called: keyCode=\(keyCode), modifiers=0x\(String(modifiers, radix: 16))")

        // Unregister the old shortcut first.
        unregister()

        // Register the new one.
        registerHotKey(keyCode: keyCode, modifiers: modifiers, handler: handler)
    }

    // MARK: - Private: Registration

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, handler: @escaping HotKeyHandler) {
        let newID = Self.getNextHotKeyID()
        currentHotKeyID = newID
        let handlerCount = Self.sharedState.withValue { state -> Int in
            state.handlers[newID] = handler
            return state.handlers.count
        }
        logToFile("📝 Handler stored: id=\(newID), total handlers=\(handlerCount)")

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = Self.hotKeySignature
        hotKeyID.id = newID

        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            logToFile("✅ Hotkey registered: id=\(newID), keyCode=\(keyCode), modifiers=0x\(String(modifiers, radix: 16)), hotKeyRef=\(String(describing: hotKeyRef))")
        } else {
            logToFile("❌ Failed to register hotkey: status=\(status)")
            Self.sharedState.withValue { state in
                _ = state.handlers.removeValue(forKey: newID)
            }
            currentHotKeyID = 0
        }
    }

    public var isRegistered: Bool {
        #if DEBUG
        let isTestingMode = Self.sharedState.withValue { state in
            state.testingMode
        }
        if isTestingMode {
            let hotKeyID = currentHotKeyID
            return Self.sharedState.withValue { state in
                state.handlers[hotKeyID] != nil
            }
        }
        #endif

        return hotKeyRef != nil
    }

    // MARK: - Static: Event Handling

    /// Handles a Carbon hotkey event.
    fileprivate static func handleCarbonEvent(_ event: EventRef?) -> OSStatus {
        logToFile("🎯 handleCarbonEvent called")

        guard let event = event else {
            logToFile("❌ Event is nil")
            return OSStatus(eventNotHandledErr)
        }

        // Handle presses only; ignore releases.
        let kind = GetEventKind(event)
        guard kind == UInt32(kEventHotKeyPressed) else {
            logToFile("⏩ Ignoring event kind=\(kind)")
            return OSStatus(eventNotHandledErr)
        }

        // Read the hotKeyID.
        var hotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            event,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &hotKeyID
        )

        guard status == noErr else {
            logToFile("❌ Failed to get hotKeyID from event: \(status)")
            return status
        }

        logToFile("📥 Event received: signature=\(hotKeyID.signature), id=\(hotKeyID.id), expected signature=\(hotKeySignature)")

        // Check the signature.
        guard hotKeyID.signature == hotKeySignature else {
            logToFile("⚠️ Signature mismatch")
            return OSStatus(eventNotHandledErr)
        }

        // Look up and run the handler; the shared state also guards `lastFire`.
        let result: (handler: HotKeyHandler?, shouldExecute: Bool) = sharedState.withValue { state in
            let availableKeys = Array(state.handlers.keys)
            let handler = state.handlers[hotKeyID.id]

            logToFile("🔍 Looking for handler: id=\(hotKeyID.id), available handlers=\(availableKeys)")

            // Holding the keys repeats pressed events; throttle them.
            let now = CFAbsoluteTimeGetCurrent()
            if let last = state.lastFire, last.id == hotKeyID.id, now - last.timestamp < 0.25 {
                logToFile("⏩ Ignoring repeat pressed event for id=\(hotKeyID.id)")
                return (nil, false)
            }
            state.lastFire = (hotKeyID.id, now)

            return (handler, true)
        }

        guard result.shouldExecute else {
            return noErr
        }

        if let handler = result.handler {
            logToFile("✅ Handler found, executing...")
            Task { @MainActor in
                handler()
            }
            return noErr
        }

        logToFile("❌ No handler found for id=\(hotKeyID.id)")
        return OSStatus(eventNotHandledErr)
    }

    // MARK: - Testing Support

    #if DEBUG
    public static func enableTestingMode() {
        sharedState.withValue { state in
            state.testingMode = true
        }
    }

    public static func disableTestingMode() {
        sharedState.withValue { state in
            state.testingMode = false
        }
    }

    public func triggerHandlerForTesting() {
        let hotKeyID = currentHotKeyID
        let handler = Self.sharedState.withValue { state in
            state.handlers[hotKeyID]
        }

        if let handler = handler {
            Task { @MainActor in
                handler()
            }
        }
    }

    public var hasHandler: Bool {
        let hotKeyID = currentHotKeyID
        return Self.sharedState.withValue { state in
            state.handlers[hotKeyID] != nil
        }
    }

    /// Takes the new ID before entering the shared state, so the two locks never nest.
    public func registerHandlerOnly(_ handler: @escaping HotKeyHandler) {
        let newID = Self.getNextHotKeyID()
        currentHotKeyID = newID
        Self.sharedState.withValue { state in
            state.handlers[newID] = handler
        }
    }

    public func unregisterHandlerOnly() {
        let hotKeyID = currentHotKeyID
        Self.sharedState.withValue { state in
            _ = state.handlers.removeValue(forKey: hotKeyID)
        }
        currentHotKeyID = 0
    }
    #endif
}

// MARK: - Carbon Event Callback

/// The Carbon event callback; it must be a C function.
private func carbonEventCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    return HotKeyService.handleCarbonEvent(event)
}
