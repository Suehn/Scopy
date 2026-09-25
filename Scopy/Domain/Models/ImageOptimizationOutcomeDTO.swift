import Foundation

/// The result of optimizing an image, for manual compression and its ratio display.
public struct ImageOptimizationOutcomeDTO: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case optimized
        case noChange
        case failed(message: String)
    }

    public let result: Result
    public let originalBytes: Int
    public let optimizedBytes: Int
    /// Non-nil only when optimization successfully persisted and emitted this exact content hash.
    public let resultingContentHash: String?

    public init(
        result: Result,
        originalBytes: Int,
        optimizedBytes: Int,
        resultingContentHash: String? = nil
    ) {
        self.result = result
        self.originalBytes = originalBytes
        self.optimizedBytes = optimizedBytes
        self.resultingContentHash = resultingContentHash
    }
}
