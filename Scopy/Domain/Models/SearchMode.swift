import Foundation

/// 搜索模式 - 对应 v0.md 中的 SearchMode
public enum SearchMode: String, Sendable, CaseIterable {
    case exact
    case fuzzy
    case fuzzyPlus  // v0.19.1: 分词 + 每词模糊匹配
    case regex
}
