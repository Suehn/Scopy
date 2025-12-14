import Foundation

/// SettingsStore - Settings 的唯一真相源（SSOT）
///
/// 目标：
/// - 消灭多点读写 UserDefaults（AppDelegate / RealClipboardService 等）
/// - 为后续“热键/设置变更订阅”提供统一入口
public actor SettingsStore {
    public static let shared = SettingsStore()

    private struct Constants {
        static let settingsKey = "ScopySettings"
    }

    private let userDefaults: UserDefaults
    private var cachedSettings: SettingsDTO?

    private var subscribers: [UUID: AsyncStream<SettingsDTO>.Continuation] = [:]

    public init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    /// Create an isolated SettingsStore backed by a named suite.
    ///
    /// Notes:
    /// - This avoids passing a non-Sendable `UserDefaults` instance across actor boundaries in Swift 6 strict mode.
    public init(suiteName: String) {
        self.userDefaults = UserDefaults(suiteName: suiteName) ?? .standard
    }

    public func load() -> SettingsDTO {
        let settings = Self.loadFromUserDefaults(userDefaults)
        cachedSettings = settings
        return settings
    }

    public func save(_ settings: SettingsDTO) {
        userDefaults.set(Self.encode(settings), forKey: Constants.settingsKey)
        cachedSettings = settings
        broadcast(settings)
    }

    public func updateHotkey(keyCode: UInt32, modifiers: UInt32) {
        var updated = cachedSettings ?? Self.loadFromUserDefaults(userDefaults)
        updated.hotkeyKeyCode = keyCode
        updated.hotkeyModifiers = modifiers
        save(updated)
    }

    public func observeSettings(bufferSize: Int = 1) -> AsyncStream<SettingsDTO> {
        let id = UUID()
        return AsyncStream(SettingsDTO.self, bufferingPolicy: .bufferingNewest(bufferSize)) { continuation in
            subscribers[id] = continuation

            if let current = cachedSettings ?? userDefaults.dictionary(forKey: Constants.settingsKey).map(Self.decode) {
                continuation.yield(current)
            }

            continuation.onTermination = { [weak self] _ in
                Task {
                    await self?.removeSubscriber(id: id)
                }
            }
        }
    }

    private func removeSubscriber(id: UUID) {
        subscribers.removeValue(forKey: id)
    }

    private func broadcast(_ settings: SettingsDTO) {
        for continuation in subscribers.values {
            continuation.yield(settings)
        }
    }

    // MARK: - Encoding / Decoding

    nonisolated private static func encode(_ settings: SettingsDTO) -> [String: Any] {
        [
            "maxItems": settings.maxItems,
            "maxStorageMB": settings.maxStorageMB,
            "saveImages": settings.saveImages,
            "saveFiles": settings.saveFiles,
            "defaultSearchMode": settings.defaultSearchMode.rawValue,
            "hotkeyKeyCode": settings.hotkeyKeyCode,
            "hotkeyModifiers": settings.hotkeyModifiers,
            "showImageThumbnails": settings.showImageThumbnails,
            "thumbnailHeight": settings.thumbnailHeight,
            "imagePreviewDelay": settings.imagePreviewDelay
        ]
    }

    nonisolated private static func decode(_ dict: [String: Any]) -> SettingsDTO {
        let searchModeString = dict["defaultSearchMode"] as? String ?? SettingsDTO.default.defaultSearchMode.rawValue
        let searchMode = SearchMode(rawValue: searchModeString) ?? SettingsDTO.default.defaultSearchMode

        return SettingsDTO(
            maxItems: dict["maxItems"] as? Int ?? SettingsDTO.default.maxItems,
            maxStorageMB: dict["maxStorageMB"] as? Int ?? SettingsDTO.default.maxStorageMB,
            saveImages: dict["saveImages"] as? Bool ?? SettingsDTO.default.saveImages,
            saveFiles: dict["saveFiles"] as? Bool ?? SettingsDTO.default.saveFiles,
            defaultSearchMode: searchMode,
            hotkeyKeyCode: (dict["hotkeyKeyCode"] as? NSNumber)?.uint32Value ?? SettingsDTO.default.hotkeyKeyCode,
            hotkeyModifiers: (dict["hotkeyModifiers"] as? NSNumber)?.uint32Value ?? SettingsDTO.default.hotkeyModifiers,
            showImageThumbnails: dict["showImageThumbnails"] as? Bool ?? SettingsDTO.default.showImageThumbnails,
            thumbnailHeight: dict["thumbnailHeight"] as? Int ?? SettingsDTO.default.thumbnailHeight,
            imagePreviewDelay: dict["imagePreviewDelay"] as? Double ?? SettingsDTO.default.imagePreviewDelay
        )
    }

    nonisolated private static func loadFromUserDefaults(_ userDefaults: UserDefaults) -> SettingsDTO {
        guard let dict = userDefaults.dictionary(forKey: Constants.settingsKey) else {
            return .default
        }
        return decode(dict)
    }
}
