import Foundation
import os

public enum ScopyLog {
    public static let subsystem: String = Bundle.main.bundleIdentifier ?? "Scopy"

    public static let app = Logger(subsystem: subsystem, category: "app")
    public static let monitor = Logger(subsystem: subsystem, category: "monitor")
    public static let storage = Logger(subsystem: subsystem, category: "storage")
    public static let persistence = Logger(subsystem: subsystem, category: "persistence")
    public static let search = Logger(subsystem: subsystem, category: "search")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}
