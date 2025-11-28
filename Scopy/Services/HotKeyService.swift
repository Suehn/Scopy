import AppKit
import Carbon.HIToolbox

/// 调试日志函数 - 写入文件
private func logToFile(_ message: String) {
    let logPath = "/tmp/scopy_hotkey.log"
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    if let data = logMessage.data(using: .utf8) {
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = FileHandle(forWritingAtPath: logPath) {
                handle.seekToEndOfFile()
                handle.write(data)
                handle.closeFile()
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
    print(message)  // 同时输出到控制台
}

/// HotKeyService - 全局快捷键服务
/// v0.9.5: 完全重写，参考 soffes/HotKey 库的实现方式
/// - 使用 GetEventParameter 从事件中提取 hotKeyID
/// - 通过 hotKeyID 匹配处理器
/// - 解决快捷键录制后需要重启才能生效的问题
final class HotKeyService {
    // MARK: - Types

    typealias HotKeyHandler = () -> Void

    // MARK: - Static Properties (Carbon API 需要)

    /// 存储已注册的热键处理器 (hotKeyID -> handler)
    private static var handlers: [UInt32: HotKeyHandler] = [:]

    /// v0.10.7: 保护 handlers 字典的锁（主线程 + Carbon 事件线程并发访问）
    private static let handlersLock = NSLock()

    /// 事件处理器引用
    private static var eventHandlerRef: EventHandlerRef?

    /// 热键签名
    private static let hotKeySignature: OSType = {
        var result: OSType = 0
        for char in "SCPY".utf8.prefix(4) {
            result = (result << 8) + OSType(char)
        }
        return result
    }()

    /// 热键 ID 计数器
    private static var nextHotKeyID: UInt32 = 1

    /// 防重复触发（按住键盘时 Carbon 会重复发送 pressed 事件）
    private static var lastFire: (id: UInt32, timestamp: CFAbsoluteTime)?

    // MARK: - Instance Properties

    private var hotKeyRef: EventHotKeyRef?
    private var currentHotKeyID: UInt32 = 0

    // 默认快捷键: ⇧⌘C
    private let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_C)  // 8
    private let defaultModifiers: UInt32 = 0x0300  // shiftKey | cmdKey

    // MARK: - Initialization

    init() {
        logToFile("🔧 HotKeyService init")
        Self.installEventHandlerIfNeeded()
    }

    deinit {
        unregister()
    }

    // MARK: - Private: Event Handler Installation

    /// 安装事件处理器（只安装一次）
    private static func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else {
            logToFile("⚠️ Event handler already installed")
            return
        }

        // 只监听按下事件，避免按下/松开各触发一次导致“按住才显示”
        var eventTypes = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        ]

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            carbonEventCallback,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandlerRef
        )

        if status == noErr {
            logToFile("✅ Carbon event handler installed")
        } else {
            logToFile("❌ Failed to install event handler: \(status)")
        }
    }

    // MARK: - Public API

    /// 注册全局快捷键（使用默认快捷键）
    func register(handler: @escaping HotKeyHandler) {
        logToFile("🔧 register() called with default hotkey")
        registerHotKey(keyCode: defaultKeyCode, modifiers: defaultModifiers, handler: handler)
    }

    /// 注销全局快捷键
    func unregister() {
        guard let hotKeyRef = hotKeyRef else {
            logToFile("⚠️ unregister() called but no hotkey registered")
            return
        }

        let status = UnregisterEventHotKey(hotKeyRef)
        self.hotKeyRef = nil

        // 从静态字典中移除处理器（加锁保护）
        Self.handlersLock.lock()
        Self.handlers.removeValue(forKey: currentHotKeyID)
        Self.handlersLock.unlock()
        logToFile("🔑 Global hotkey unregistered: id=\(currentHotKeyID), status=\(status)")
        currentHotKeyID = 0
    }

    /// 更新快捷键（设置窗口使用）
    func updateHotKey(keyCode: UInt32, modifiers: UInt32, handler: @escaping HotKeyHandler) {
        logToFile("🔧 updateHotKey() called: keyCode=\(keyCode), modifiers=0x\(String(modifiers, radix: 16))")

        // 先注销旧的
        unregister()

        // 注册新的
        registerHotKey(keyCode: keyCode, modifiers: modifiers, handler: handler)
    }

    // MARK: - Private: Registration

    private func registerHotKey(keyCode: UInt32, modifiers: UInt32, handler: @escaping HotKeyHandler) {
        // 生成新的 hotKeyID
        currentHotKeyID = Self.nextHotKeyID
        Self.nextHotKeyID += 1

        // 存储处理器（加锁保护）
        Self.handlersLock.lock()
        Self.handlers[currentHotKeyID] = handler
        let handlerCount = Self.handlers.count
        Self.handlersLock.unlock()
        logToFile("📝 Handler stored: id=\(currentHotKeyID), total handlers=\(handlerCount)")

        // 创建 hotKeyID 结构
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = Self.hotKeySignature
        hotKeyID.id = currentHotKeyID

        // 注册热键
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if status == noErr {
            logToFile("✅ Hotkey registered: id=\(currentHotKeyID), keyCode=\(keyCode), modifiers=0x\(String(modifiers, radix: 16)), hotKeyRef=\(String(describing: hotKeyRef))")
        } else {
            logToFile("❌ Failed to register hotkey: status=\(status)")
            // 清理（加锁保护）
            Self.handlersLock.lock()
            Self.handlers.removeValue(forKey: currentHotKeyID)
            Self.handlersLock.unlock()
            currentHotKeyID = 0
        }
    }

    // MARK: - Static: Event Handling

    /// 处理 Carbon 事件
    fileprivate static func handleCarbonEvent(_ event: EventRef?) -> OSStatus {
        logToFile("🎯 handleCarbonEvent called")

        guard let event = event else {
            logToFile("❌ Event is nil")
            return OSStatus(eventNotHandledErr)
        }

        // 只处理 HotKey 按下事件，忽略松开
        let kind = GetEventKind(event)
        guard kind == UInt32(kEventHotKeyPressed) else {
            logToFile("⏩ Ignoring event kind=\(kind)")
            return OSStatus(eventNotHandledErr)
        }

        // 提取 hotKeyID
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

        // 验证签名
        guard hotKeyID.signature == hotKeySignature else {
            logToFile("⚠️ Signature mismatch")
            return OSStatus(eventNotHandledErr)
        }

        // 查找并执行处理器（加锁保护）
        handlersLock.lock()
        let availableKeys = Array(handlers.keys)
        let handler = handlers[hotKeyID.id]
        handlersLock.unlock()

        logToFile("🔍 Looking for handler: id=\(hotKeyID.id), available handlers=\(availableKeys)")

        // 按住时会重复发 pressed 事件，做简单节流
        let now = CFAbsoluteTimeGetCurrent()
        if let last = lastFire, last.id == hotKeyID.id, now - last.timestamp < 0.25 {
            logToFile("⏩ Ignoring repeat pressed event for id=\(hotKeyID.id)")
            return noErr
        }
        lastFire = (hotKeyID.id, now)

        if let handler = handler {
            logToFile("✅ Handler found, executing...")
            DispatchQueue.main.async {
                handler()
            }
            return noErr
        }

        logToFile("❌ No handler found for id=\(hotKeyID.id)")
        return OSStatus(eventNotHandledErr)
    }

    // MARK: - Testing Support

    #if DEBUG
    private static var testingMode = false

    static func enableTestingMode() {
        testingMode = true
    }

    static func disableTestingMode() {
        testingMode = false
    }

    func triggerHandlerForTesting() {
        Self.handlersLock.lock()
        let handler = Self.handlers[currentHotKeyID]
        Self.handlersLock.unlock()

        if let handler = handler {
            if Thread.isMainThread {
                handler()
            } else {
                DispatchQueue.main.async {
                    handler()
                }
            }
        }
    }

    var isRegistered: Bool {
        if Self.testingMode {
            Self.handlersLock.lock()
            let hasHandler = Self.handlers[currentHotKeyID] != nil
            Self.handlersLock.unlock()
            return hasHandler
        }
        return hotKeyRef != nil
    }

    var hasHandler: Bool {
        Self.handlersLock.lock()
        let result = Self.handlers[currentHotKeyID] != nil
        Self.handlersLock.unlock()
        return result
    }

    func registerHandlerOnly(_ handler: @escaping HotKeyHandler) {
        currentHotKeyID = Self.nextHotKeyID
        Self.nextHotKeyID += 1
        Self.handlersLock.lock()
        Self.handlers[currentHotKeyID] = handler
        Self.handlersLock.unlock()
    }

    func unregisterHandlerOnly() {
        Self.handlersLock.lock()
        Self.handlers.removeValue(forKey: currentHotKeyID)
        Self.handlersLock.unlock()
        currentHotKeyID = 0
    }
    #endif
}

// MARK: - Carbon Event Callback

/// Carbon API 事件处理回调（必须是 C 函数）
private func carbonEventCallback(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    return HotKeyService.handleCarbonEvent(event)
}
