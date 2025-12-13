import AppKit
import Carbon.HIToolbox

/// v0.11: 日志轮转配置
private let logPath = "/tmp/scopy_hotkey.log"
private let logPathOld = "/tmp/scopy_hotkey.log.old"
private let maxLogSize = 10 * 1024 * 1024  // 10MB

/// v0.23: 使用串行队列替代锁，避免文件 I/O 阻塞调用线程
private let logQueue = DispatchQueue(label: "com.scopy.hotkey.log", qos: .utility)

/// v0.11: 调试日志函数 - 写入文件（带轮转和线程安全）
/// v0.17.1: 使用 withLock 统一锁策略
/// v0.23: 改用异步队列，避免文件 I/O 阻塞调用线程
private func logToFile(_ message: String) {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let logMessage = "[\(timestamp)] \(message)\n"

    ScopyLog.hotkey.info("\(message, privacy: .public)")

    guard let data = logMessage.data(using: .utf8) else { return }

    // 异步写入文件，不阻塞调用线程
    logQueue.async {
        // 检查文件大小，必要时轮转
        if let attrs = try? FileManager.default.attributesOfItem(atPath: logPath),
           let size = attrs[.size] as? Int, size > maxLogSize {
            // 删除旧的备份文件
            try? FileManager.default.removeItem(atPath: logPathOld)
            // 将当前日志重命名为备份
            try? FileManager.default.moveItem(atPath: logPath, toPath: logPathOld)
        }

        // 写入日志
        if FileManager.default.fileExists(atPath: logPath) {
            if let handle = try? FileHandle(forWritingTo: URL(fileURLWithPath: logPath)) {
                defer { try? handle.close() }
                try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            }
        } else {
            FileManager.default.createFile(atPath: logPath, contents: data)
        }
    }
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

    /// v0.20: 保护 eventHandlerRef 的锁（防止多线程竞态）
    private static let eventHandlerLock = NSLock()

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
    /// v0.20: 添加溢出保护，当接近 UInt32.max 时重置为 1
    private static var nextHotKeyID: UInt32 = 1

    /// v0.22: 保护 nextHotKeyID 的锁（防止多线程竞态）
    private static let nextHotKeyIDLock = NSLock()

    /// 防重复触发（按住键盘时 Carbon 会重复发送 pressed 事件）
    /// v0.22: 移除未使用的 lastFireLock，lastFire 由 handlersLock 统一保护
    /// 这是有意的设计：在 handleCarbonEvent 中，lastFire 的检查和 handlers 的查找
    /// 需要在同一个锁内完成，以确保原子性
    private static var lastFire: (id: UInt32, timestamp: CFAbsoluteTime)?

    /// v0.20: 安全递增 hotKeyID，防止溢出
    /// v0.22: 添加锁保护，确保线程安全
    private static func getNextHotKeyID() -> UInt32 {
        return nextHotKeyIDLock.withLock {
            // 如果接近溢出，重置为 1（跳过 0，因为 0 通常表示无效 ID）
            // 使用 UInt32.max - 1000 作为阈值，留出足够的安全边界
            if nextHotKeyID >= UInt32.max - 1000 {
                logToFile("⚠️ HotKeyID approaching overflow, resetting to 1")
                nextHotKeyID = 1
            }
            let id = nextHotKeyID
            nextHotKeyID += 1
            return id
        }
    }

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
    /// v0.20: 使用 eventHandlerLock 保护 eventHandlerRef 访问
    private static func installEventHandlerIfNeeded() {
        eventHandlerLock.withLock {
            guard eventHandlerRef == nil else {
                logToFile("⚠️ Event handler already installed")
                return
            }

            // 只监听按下事件，避免按下/松开各触发一次导致"按住才显示"
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
        Self.handlersLock.withLock {
            Self.handlers.removeValue(forKey: currentHotKeyID)
        }
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
        // 生成新的 hotKeyID（加锁保护静态变量）
        // v0.20: 使用 getNextHotKeyID() 防止溢出
        let handlerCount = Self.handlersLock.withLock {
            currentHotKeyID = Self.getNextHotKeyID()
            // 存储处理器
            Self.handlers[currentHotKeyID] = handler
            return Self.handlers.count
        }
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
            Self.handlersLock.withLock {
                Self.handlers.removeValue(forKey: currentHotKeyID)
            }
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

        // 查找并执行处理器（加锁保护，同时保护 lastFire）
        // v0.17.1: 使用 withLock 统一锁策略
        let result: (handler: HotKeyHandler?, shouldExecute: Bool) = handlersLock.withLock {
            let availableKeys = Array(handlers.keys)
            let handler = handlers[hotKeyID.id]

            logToFile("🔍 Looking for handler: id=\(hotKeyID.id), available handlers=\(availableKeys)")

            // 按住时会重复发 pressed 事件，做简单节流
            let now = CFAbsoluteTimeGetCurrent()
            if let last = lastFire, last.id == hotKeyID.id, now - last.timestamp < 0.25 {
                logToFile("⏩ Ignoring repeat pressed event for id=\(hotKeyID.id)")
                return (nil, false)
            }
            lastFire = (hotKeyID.id, now)

            return (handler, true)
        }

        guard result.shouldExecute else {
            return noErr
        }

        if let handler = result.handler {
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
    /// v0.20: 保护 testingMode 的锁
    private static let testingModeLock = NSLock()
    private static var _testingMode = false

    /// v0.20: 线程安全的 testingMode 访问
    private static var testingMode: Bool {
        get { testingModeLock.withLock { _testingMode } }
        set { testingModeLock.withLock { _testingMode = newValue } }
    }

    static func enableTestingMode() {
        testingMode = true
    }

    static func disableTestingMode() {
        testingMode = false
    }

    /// v0.17.1: 使用 withLock 统一锁策略
    func triggerHandlerForTesting() {
        let handler = Self.handlersLock.withLock {
            Self.handlers[currentHotKeyID]
        }

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
            return Self.handlersLock.withLock {
                Self.handlers[currentHotKeyID] != nil
            }
        }
        return hotKeyRef != nil
    }

    var hasHandler: Bool {
        Self.handlersLock.withLock {
            Self.handlers[currentHotKeyID] != nil
        }
    }

    /// v0.22: 修复竞态条件 - 使用 getNextHotKeyID() 确保线程安全
    /// v0.22.1: 修复嵌套锁死锁风险 - 在 handlersLock 外部调用 getNextHotKeyID()
    func registerHandlerOnly(_ handler: @escaping HotKeyHandler) {
        // 先获取 ID（在 handlersLock 外部），避免嵌套锁死锁
        let newID = Self.getNextHotKeyID()
        Self.handlersLock.withLock {
            currentHotKeyID = newID
            Self.handlers[currentHotKeyID] = handler
        }
    }

    func unregisterHandlerOnly() {
        Self.handlersLock.withLock {
            Self.handlers.removeValue(forKey: currentHotKeyID)
            currentHotKeyID = 0
        }
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
