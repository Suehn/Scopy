import Foundation
import os

enum ScopyLog {
    static let subsystem: String = Bundle.main.bundleIdentifier ?? "Scopy"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let monitor = Logger(subsystem: subsystem, category: "monitor")
    static let storage = Logger(subsystem: subsystem, category: "storage")
    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let search = Logger(subsystem: subsystem, category: "search")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
}

