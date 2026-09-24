import Foundation

public enum SearchCoverage: Sendable, Equatable {
    case complete
    case stagedRefine
    case incomplete
    case recentOnly(limit: Int)

    public var isStagedRefine: Bool {
        if case .stagedRefine = self {
            return true
        }
        return false
    }
}
