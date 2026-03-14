import Foundation

public enum SearchCoverage: Sendable, Equatable {
    case complete
    case stagedRefine
    case recentOnly(limit: Int)

    public var isPrefilter: Bool {
        self != .complete
    }

    public var isStagedRefine: Bool {
        if case .stagedRefine = self {
            return true
        }
        return false
    }

    public var recentOnlyLimit: Int? {
        if case .recentOnly(let limit) = self {
            return limit
        }
        return nil
    }
}
