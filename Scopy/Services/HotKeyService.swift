import AppKit
import Carbon.HIToolbox

/// HotKeyService - 全局快捷键服务
/// 实现 ⇧⌘C 全局快捷键呼出/隐藏窗口
/// 符合 v0.md 1.2: 菜单栏常驻图标 + 快捷键弹出主窗口
final class HotKeyService {
    // MARK: - Types

    typealias HotKeyHandler = () -> Void

    // MARK: - Properties

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: HotKeyHandler?

    // 使用单例存储当前实例引用（Carbon API 回调需要）
    fileprivate static var currentInstance: HotKeyService?

    // 默认快捷键: ⇧⌘C
    private let defaultKeyCode: UInt32 = UInt32(kVK_ANSI_C)
    private let defaultModifiers: UInt32 = UInt32(shiftKey | cmdKey)

    // MARK: - Initialization

    init() {
        HotKeyService.currentInstance = self
    }

    deinit {
        unregister()
        HotKeyService.currentInstance = nil
    }

    // MARK: - Public API

    /// 注册全局快捷键
    /// - Parameter handler: 快捷键触发时的回调
    func register(handler: @escaping HotKeyHandler) {
        self.handler = handler

        // 设置事件处理器
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        // 安装事件处理器
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        guard status == noErr else {
            print("❌ Failed to install event handler: \(status)")
            return
        }

        // 注册热键
        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = fourCharCodeFrom("SCPY")
        hotKeyID.id = 1

        let registerStatus = RegisterEventHotKey(
            defaultKeyCode,
            defaultModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )

        if registerStatus == noErr {
            print("✅ Global hotkey ⇧⌘C registered successfully")
        } else {
            print("❌ Failed to register hotkey: \(registerStatus)")
        }
    }

    /// 注销全局快捷键
    func unregister() {
        if let hotKeyRef = hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
            print("🔑 Global hotkey unregistered")
        }

        if let eventHandlerRef = eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        handler = nil
    }

    /// 更新快捷键（未来设置窗口使用）
    func updateHotKey(keyCode: UInt32, modifiers: UInt32, handler: @escaping HotKeyHandler) {
        unregister()
        self.handler = handler

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        InstallEventHandler(
            GetApplicationEventTarget(),
            hotKeyEventHandler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )

        var hotKeyID = EventHotKeyID()
        hotKeyID.signature = fourCharCodeFrom("SCPY")
        hotKeyID.id = 1

        RegisterEventHotKey(
            keyCode,
            modifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    // MARK: - Internal

    /// 触发处理器（被 C 回调调用）
    fileprivate func triggerHandler() {
        DispatchQueue.main.async { [weak self] in
            self?.handler?()
        }
    }

    // MARK: - Testing Support

    #if DEBUG
    /// 测试模式标志
    private static var testingMode = false

    /// 启用测试模式（跳过 Carbon API 调用）
    static func enableTestingMode() {
        testingMode = true
    }

    /// 禁用测试模式
    static func disableTestingMode() {
        testingMode = false
    }

    /// 测试用：手动触发处理器（避免 Carbon API 依赖）
    func triggerHandlerForTesting() {
        triggerHandler()
    }

    /// 测试用：检查是否已注册（测试模式下基于 handler 存在性）
    var isRegistered: Bool {
        if Self.testingMode {
            return handler != nil
        }
        return hotKeyRef != nil
    }

    /// 测试用：检查是否有处理器
    var hasHandler: Bool {
        handler != nil
    }

    /// 测试用：仅设置 handler 而不注册 Carbon 热键
    func registerHandlerOnly(_ handler: @escaping HotKeyHandler) {
        self.handler = handler
    }

    /// 测试用：清除 handler
    func unregisterHandlerOnly() {
        self.handler = nil
    }
    #endif

    // MARK: - Helpers

    private func fourCharCodeFrom(_ string: String) -> OSType {
        var result: OSType = 0
        for char in string.utf8.prefix(4) {
            result = (result << 8) + OSType(char)
        }
        return result
    }
}

// MARK: - Carbon Event Handler

/// Carbon API 事件处理回调（必须是 C 函数）
private func hotKeyEventHandler(
    nextHandler: EventHandlerCallRef?,
    event: EventRef?,
    userData: UnsafeMutableRawPointer?
) -> OSStatus {
    // 通过静态引用获取实例
    HotKeyService.currentInstance?.triggerHandler()
    return noErr
}
