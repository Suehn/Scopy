import Foundation

/// Ranks the slots of a `FullFuzzyIndex` for one fuzzy request. Pure: it reads the index and
/// the request and never touches the database; the engine hydrates the returned slots.
enum FullIndexRanker {
    struct Page {
        /// Best first.
        let slots: [Int]
        /// `-1` when only a prefiltered subset was ranked.
        let total: Int
        let hasMore: Bool
        let coverage: SearchCoverage
    }

    struct ScoredSlot {
        let slot: Int
        let score: Int
    }

    /// A bounded prefix of one complete ranking so deeper pages of the same query reuse the
    /// scan instead of scoring every candidate again.
    struct SortedMatchesCache {
        struct Key: Hashable {
            let mode: SearchMode
            let sortMode: SearchSortMode
            let queryLower: String
            let appFilter: String?
            let typeFilter: ClipboardItemType?
            let typeFiltersKey: String?
            let forceFullFuzzy: Bool
            let indexContentVersion: UInt64
        }

        let key: Key
        let totalMatches: Int
        /// Already ordered best first; may be truncated for deep paging.
        let topMatches: [ScoredSlot]
    }

    private struct AdaptiveTuning {
        var prefilterMin: Int
        var prefilterMax: Int
        var prefilterScale: Int
        var deepPagingCacheTopMatches: Int
        var deepPagingCachePrefetchExtra: Int

        static let fallback = AdaptiveTuning(
            prefilterMin: 5_000,
            prefilterMax: 20_000,
            prefilterScale: 40,
            deepPagingCacheTopMatches: 50_000,
            deepPagingCachePrefetchExtra: 2_000
        )

        static func current(candidateCount: Int) -> AdaptiveTuning {
            let cores = max(2, ProcessInfo.processInfo.activeProcessorCount)
            var tuning = fallback

            if cores >= 10 {
                tuning.prefilterMax = 30_000
                tuning.prefilterScale = 48
                tuning.deepPagingCacheTopMatches = 64_000
                tuning.deepPagingCachePrefetchExtra = 3_000
            } else if cores <= 4 {
                tuning.prefilterMax = 16_000
                tuning.prefilterScale = 32
                tuning.deepPagingCacheTopMatches = 36_000
                tuning.deepPagingCachePrefetchExtra = 1_500
            }

            if candidateCount >= 20_000 {
                tuning.prefilterMax = max(tuning.prefilterMax, 36_000)
            }
            return tuning
        }
    }

    // MARK: - Candidates

    /// Slots whose text contains every distinct non-whitespace character of the query
    /// (intersection of the per-character postings, smallest list first).
    static func candidateSlots(index: FullFuzzyIndex, queryLower: String) -> [Int] {
        let queryChars = uniqueNonWhitespaceCharacters(queryLower)
        if queryChars.asciiCodes.isEmpty, queryChars.nonASCIIChars.isEmpty {
            return Array(index.items.indices)
        }

        var lists: [[UInt32]] = []
        lists.reserveCapacity(queryChars.asciiCodes.count + queryChars.nonASCIIChars.count)

        for ascii in queryChars.asciiCodes {
            let list = index.asciiCharPostings[Int(ascii)]
            if list.isEmpty {
                return []
            }
            lists.append(list)
        }

        for ch in queryChars.nonASCIIChars {
            guard let list = index.nonASCIICharPostings[ch], !list.isEmpty else {
                return []
            }
            lists.append(list)
        }

        lists.sort { $0.count < $1.count }

        var candidates = lists[0]
        for list in lists.dropFirst() {
            candidates = intersectSorted(candidates, list)
            if candidates.isEmpty { break }
        }
        return candidates.map { Int($0) }
    }

    /// The FTS prefilter limit when a large ASCII candidate set should be narrowed by FTS
    /// before scoring (first page of an interactive fuzzy query), else nil.
    static func adaptivePrefilterLimit(
        request: SearchRequest,
        mode: SearchMode,
        queryLower: String,
        candidateCount: Int
    ) -> Int? {
        guard mode == .fuzzy || mode == .fuzzyPlus,
              !request.forceFullFuzzy,
              request.offset == 0,
              queryLower.count >= 4,
              queryLower.canBeConverted(to: .ascii),
              candidateCount >= 6_000 else {
            return nil
        }
        let tuning = AdaptiveTuning.current(candidateCount: candidateCount)
        let desiredTopCount = max(0, request.offset + request.limit + 1)
        return min(
            tuning.prefilterMax,
            max(tuning.prefilterMin, desiredTopCount * tuning.prefilterScale)
        )
    }

    /// The prefiltered slots plus every pinned candidate, so pinned items never drop out of a
    /// staged page.
    static func mergePrefilter(candidateSlots: [Int], ftsSlots: [Int], index: FullFuzzyIndex) -> [Int] {
        let pinnedSlots = candidateSlots.filter { slot in
            guard slot < index.items.count, let item = index.items[slot] else { return false }
            return item.isPinned
        }
        var merged = Set(ftsSlots)
        for slot in pinnedSlots { merged.insert(slot) }
        return Array(merged)
    }

    // MARK: - Ranking

    /// Ranks a prefiltered subset: the total is unknown and the page is `stagedRefine`.
    /// Recency sorts candidates first and scores lazily until the page is full; relevance
    /// scores every candidate and keeps the top `offset + limit + 1`.
    static func rankStaged(
        index: FullFuzzyIndex,
        request: SearchRequest,
        scorer: FuzzyMatcher.Scorer,
        candidateSlots: [Int],
        perf: SearchPerfContext?
    ) throws -> Page {
        let desiredTopCount = max(0, request.offset + request.limit + 1)
        let sortMode = request.sortMode

        if sortMode == .recent {
            let sortStart = perf == nil ? 0 : CFAbsoluteTimeGetCurrent()
            var ordered = candidateSlots.filter { $0 < index.items.count && index.items[$0] != nil }
            ordered.sort { lhsSlot, rhsSlot in
                guard let lhsItem = index.items[lhsSlot], let rhsItem = index.items[rhsSlot] else { return false }
                return SearchRankKey.isBetter(
                    SearchRankKey(item: lhsItem, score: 0),
                    than: SearchRankKey(item: rhsItem, score: 0),
                    sortMode: .recent
                )
            }
            perf?.addPhase("full_index_prefilter_recent_candidate_sort", ms: (CFAbsoluteTimeGetCurrent() - sortStart) * 1000)

            var pageSlots: [Int] = []
            pageSlots.reserveCapacity(request.limit + 1)
            var matchesSeen = 0

            let scanStart = perf == nil ? 0 : CFAbsoluteTimeGetCurrent()
            for (i, slot) in ordered.enumerated() {
                if i % 1024 == 0 {
                    try Task.checkCancellation()
                }
                guard let item = index.items[slot], passesFilters(item, request: request) else { continue }
                guard scorer.score(textLower: item.plainTextLower) != nil else { continue }

                if matchesSeen >= request.offset {
                    pageSlots.append(slot)
                    if pageSlots.count >= request.limit + 1 {
                        break
                    }
                }
                matchesSeen += 1
            }
            perf?.addPhase("full_index_prefilter_recent_scan", ms: (CFAbsoluteTimeGetCurrent() - scanStart) * 1000)
            perf?.addCounter("full_index_prefilter_total_matches", value: matchesSeen)

            let hasMore = pageSlots.count > request.limit
            if hasMore {
                pageSlots.removeLast()
            }
            return Page(slots: pageSlots, total: -1, hasMore: hasMore, coverage: .stagedRefine)
        }

        var selector = makeSelector(index: index, sortMode: sortMode, capacity: desiredTopCount)
        selector.reserveCapacity(desiredTopCount)
        var totalMatches = 0

        let scoreStart = perf == nil ? 0 : CFAbsoluteTimeGetCurrent()
        for (i, slot) in candidateSlots.enumerated() {
            if i % 1024 == 0 {
                try Task.checkCancellation()
            }
            guard slot < index.items.count, let item = index.items[slot],
                  passesFilters(item, request: request) else { continue }
            guard let score = scorer.score(textLower: item.plainTextLower) else { continue }
            totalMatches += 1
            selector.offer(ScoredSlot(slot: slot, score: score))
        }
        perf?.addPhase("full_index_prefilter_scoring", ms: (CFAbsoluteTimeGetCurrent() - scoreStart) * 1000)
        perf?.addCounter("full_index_prefilter_total_matches", value: totalMatches)

        let sortStart = perf == nil ? 0 : CFAbsoluteTimeGetCurrent()
        let topItems = selector.sortedElements()
        perf?.addPhase("full_index_prefilter_sort", ms: (CFAbsoluteTimeGetCurrent() - sortStart) * 1000)

        let start = min(request.offset, topItems.count)
        let end = min(start + request.limit, topItems.count)
        let page: [ScoredSlot] = (start < end) ? Array(topItems[start..<end]) : []
        let hasMore = totalMatches > request.offset + request.limit
        return Page(slots: page.map(\.slot), total: -1, hasMore: hasMore, coverage: .stagedRefine)
    }

    /// Ranks the complete candidate set, serving deeper pages of the same query from `cache`
    /// when it still holds enough of the ranking for this index content version.
    static func rankComplete(
        index: FullFuzzyIndex,
        request: SearchRequest,
        mode: SearchMode,
        queryLower: String,
        scorer: FuzzyMatcher.Scorer,
        candidateSlots: [Int],
        indexContentVersion: UInt64,
        cache: inout SortedMatchesCache?,
        perf: SearchPerfContext?
    ) throws -> Page {
        let desiredTopCount = max(0, request.offset + request.limit + 1)
        let cacheKey = SortedMatchesCache.Key(
            mode: mode,
            sortMode: request.sortMode,
            queryLower: queryLower,
            appFilter: request.appFilter,
            typeFilter: request.typeFilter,
            typeFiltersKey: typeFiltersKey(request.typeFilters),
            forceFullFuzzy: request.forceFullFuzzy,
            indexContentVersion: indexContentVersion
        )

        let tuning = AdaptiveTuning.current(candidateCount: candidateSlots.count)
        let maxDeepPagingCacheTopMatches = tuning.deepPagingCacheTopMatches
        let cacheTopCount = min(maxDeepPagingCacheTopMatches, desiredTopCount + tuning.deepPagingCachePrefetchExtra)

        if let cached = cache,
           cached.key == cacheKey,
           cached.topMatches.count >= desiredTopCount {
            perf?.addCounter("fuzzy_sorted_matches_cache_hit", value: 1)
            return pageFromSortedMatches(cached.topMatches, totalMatches: cached.totalMatches, request: request)
        }

        var selector = makeSelector(index: index, sortMode: request.sortMode, capacity: cacheTopCount)
        selector.reserveCapacity(min(cacheTopCount, 8192))
        var totalMatches = 0

        for (i, slot) in candidateSlots.enumerated() {
            if i % 1024 == 0 {
                try Task.checkCancellation()
            }
            guard slot < index.items.count, let item = index.items[slot],
                  passesFilters(item, request: request) else { continue }
            guard let score = scorer.score(textLower: item.plainTextLower) else { continue }
            totalMatches += 1
            selector.offer(ScoredSlot(slot: slot, score: score))
        }

        let topItems = selector.sortedElements()
        if topItems.count <= maxDeepPagingCacheTopMatches {
            cache = SortedMatchesCache(key: cacheKey, totalMatches: totalMatches, topMatches: topItems)
            perf?.addCounter("fuzzy_sorted_matches_cache_store_count", value: topItems.count)
        } else {
            cache = nil
        }

        return pageFromSortedMatches(topItems, totalMatches: totalMatches, request: request)
    }

    static func hasReachableNextFuzzyPage(
        availableTopMatches: Int,
        offset: Int,
        limit: Int
    ) -> Bool {
        guard availableTopMatches > offset, offset >= 0, limit > 0 else { return false }
        return availableTopMatches - offset > limit
    }

    // MARK: - Internals

    private static func passesFilters(_ item: IndexedItem, request: SearchRequest) -> Bool {
        if let appFilter = request.appFilter, item.appBundleID != appFilter { return false }
        if let typeFilters = request.typeFilters, !typeFilters.isEmpty {
            return typeFilters.contains(item.type)
        }
        if let typeFilter = request.typeFilter, item.type != typeFilter { return false }
        return true
    }

    private static func makeSelector(
        index: FullFuzzyIndex,
        sortMode: SearchSortMode,
        capacity: Int
    ) -> TopKSelector<ScoredSlot> {
        TopKSelector(capacity: capacity) { lhs, rhs in
            guard let lhsItem = index.items[lhs.slot] else { return false }
            guard let rhsItem = index.items[rhs.slot] else { return true }
            return SearchRankKey.isBetter(
                SearchRankKey(item: lhsItem, score: lhs.score),
                than: SearchRankKey(item: rhsItem, score: rhs.score),
                sortMode: sortMode
            )
        }
    }

    private static func pageFromSortedMatches(
        _ sortedTop: [ScoredSlot],
        totalMatches: Int,
        request: SearchRequest
    ) -> Page {
        let start = min(request.offset, sortedTop.count)
        let end = min(start + request.limit, sortedTop.count)
        let page: [ScoredSlot] = (start < end) ? Array(sortedTop[start..<end]) : []
        let hasMore = hasReachableNextFuzzyPage(
            availableTopMatches: sortedTop.count,
            offset: request.offset,
            limit: request.limit
        )
        return Page(slots: page.map(\.slot), total: totalMatches, hasMore: hasMore, coverage: .complete)
    }

    private static func typeFiltersKey(_ set: Set<ClipboardItemType>?) -> String? {
        guard let set, !set.isEmpty else { return nil }
        return set.map(\.rawValue).sorted().joined(separator: ",")
    }

    private static func uniqueNonWhitespaceCharacters(_ text: String) -> (asciiCodes: [UInt8], nonASCIIChars: [Character]) {
        var asciiCodes: [UInt8] = []
        var nonASCIIChars: [Character] = []
        asciiCodes.reserveCapacity(min(text.count, 64))
        nonASCIIChars.reserveCapacity(min(text.count, 64))

        var seenASCII0: UInt64 = 0
        var seenASCII1: UInt64 = 0
        var seenNonASCII = Set<Character>()
        seenNonASCII.reserveCapacity(min(text.count, 64))

        for ch in text {
            if ch.isWhitespace { continue }

            if let ascii = ch.asciiValue {
                if ascii < 64 {
                    let bit = UInt64(1) << UInt64(ascii)
                    if (seenASCII0 & bit) == 0 {
                        seenASCII0 |= bit
                        asciiCodes.append(ascii)
                    }
                } else {
                    let bit = UInt64(1) << UInt64(ascii - 64)
                    if (seenASCII1 & bit) == 0 {
                        seenASCII1 |= bit
                        asciiCodes.append(ascii)
                    }
                }
                continue
            }

            if seenNonASCII.insert(ch).inserted {
                nonASCIIChars.append(ch)
            }
        }

        return (asciiCodes: asciiCodes, nonASCIIChars: nonASCIIChars)
    }

    private static func intersectSorted(_ a: [UInt32], _ b: [UInt32]) -> [UInt32] {
        var i = 0
        var j = 0
        var result: [UInt32] = []
        result.reserveCapacity(min(a.count, b.count))

        while i < a.count && j < b.count {
            let va = a[i]
            let vb = b[j]
            if va == vb {
                result.append(va)
                i += 1
                j += 1
            } else if va < vb {
                i += 1
            } else {
                j += 1
            }
        }

        return result
    }
}
