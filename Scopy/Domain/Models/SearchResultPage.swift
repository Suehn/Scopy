import Foundation

public enum SearchMatchSource: String, Sendable, Equatable, Hashable {
    case content
    case note
}

/// A highlighted range inside a bounded search-result fragment.
/// Offsets use extended grapheme clusters so UI rendering never splits user-visible characters.
public struct SearchMatchTextRange: Sendable, Equatable, Hashable {
    public let offset: Int
    public let length: Int

    public init(offset: Int, length: Int) {
        self.offset = offset
        self.length = length
    }
}

/// A short, single-line excerpt that explains one part of a search match.
public struct SearchMatchFragment: Sendable, Equatable, Hashable {
    public let source: SearchMatchSource
    public let text: String
    public let highlightedRanges: [SearchMatchTextRange]

    public init(
        source: SearchMatchSource,
        text: String,
        highlightedRanges: [SearchMatchTextRange]
    ) {
        self.source = source
        self.text = text
        self.highlightedRanges = highlightedRanges
    }
}

/// Search evidence for one result row. Fragments are already bounded and safe to render directly.
public struct SearchMatchContext: Sendable, Equatable, Hashable {
    public let mode: SearchMode
    public let fragments: [SearchMatchFragment]
    public let occurrenceCount: Int
    public let occurrenceCountIsTruncated: Bool
    public let isPositionOnly: Bool

    public init(
        mode: SearchMode,
        fragments: [SearchMatchFragment],
        occurrenceCount: Int,
        occurrenceCountIsTruncated: Bool,
        isPositionOnly: Bool
    ) {
        self.mode = mode
        self.fragments = fragments
        self.occurrenceCount = occurrenceCount
        self.occurrenceCountIsTruncated = occurrenceCountIsTruncated
        self.isPositionOnly = isPositionOnly
    }
}

/// A result item and the backend-generated evidence that made it a candidate.
public struct SearchResultHit: Sendable, Equatable, Hashable {
    public let item: ClipboardItemDTO
    public let matchContext: SearchMatchContext?

    public init(item: ClipboardItemDTO, matchContext: SearchMatchContext?) {
        self.item = item
        self.matchContext = matchContext
    }
}

public struct SearchResultPage: Sendable {
    public let hits: [SearchResultHit]
    public let total: Int
    public let hasMore: Bool
    /// Whether this page is complete, staged for refine, or intentionally limited to recent history.
    public let coverage: SearchCoverage

    public init(
        hits: [SearchResultHit],
        total: Int,
        hasMore: Bool,
        coverage: SearchCoverage
    ) {
        self.hits = hits
        self.total = total
        self.hasMore = hasMore
        self.coverage = coverage
    }
}
