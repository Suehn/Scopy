import Foundation

/// 图片优化结果（用于手动压缩/提示压缩比）
public struct ImageOptimizationOutcomeDTO: Sendable, Equatable {
    public enum Result: Sendable, Equatable {
        case optimized
        case noChange
        case failed(message: String)
    }

    public let result: Result
    public let originalBytes: Int
    public let optimizedBytes: Int

    public init(result: Result, originalBytes: Int, optimizedBytes: Int) {
        self.result = result
        self.originalBytes = originalBytes
        self.optimizedBytes = optimizedBytes
    }
}
