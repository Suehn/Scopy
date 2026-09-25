import Foundation

enum BackgroundWorkPriority: Int, Sendable, Comparable {
    case utility
    case userInitiated

    static func < (lhs: BackgroundWorkPriority, rhs: BackgroundWorkPriority) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var taskPriority: TaskPriority {
        switch self {
        case .utility:
            return .utility
        case .userInitiated:
            return .userInitiated
        }
    }
}
