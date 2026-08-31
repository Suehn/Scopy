import Foundation
import SQLite3

/// Builds bounded, source-aware evidence with the same matching rules used by search.
/// Prepare one matcher per request, then reuse it for every item in the returned page.
public enum SearchMatchContextBuilder {
    private enum Constants {
        static let maxOccurrencesPerTerm = 32
        static let literalScanChunkUTF16 = 64 * 1024
        static let tokenizerChunkCharacters = 8 * 1024
        static let cancellationPollInterval = 256
        static let singleFragmentCharacters = 72
        static let splitFragmentCharacters = 14
        static let clusterGapUTF16 = 28
        static let leadingContextCharacters = 8
        static let splitLeadingContextCharacters = 2
    }

    private struct RawMatch: Hashable {
        let source: SearchMatchSource
        let range: NSRange
        let termIndex: Int
    }

    private struct MatchSet {
        var matches: [RawMatch] = []
        var occurrenceCount = 0
        var isTruncated = false

        mutating func append(_ other: MatchSet) {
            matches.append(contentsOf: other.matches)
            occurrenceCount += other.occurrenceCount
            isTruncated = isTruncated || other.isTruncated
        }
    }

    private struct MatchCluster {
        let source: SearchMatchSource
        let matches: [RawMatch]

        var score: Int {
            let distinctTerms = Set(matches.map(\.termIndex)).count
            return distinctTerms * 1_000 + matches.count
        }

        var location: Int {
            matches.first?.range.location ?? 0
        }
    }

    fileprivate struct FuzzyTerm {
        let text: String
        let lowercasedCharacters: [Character]
    }

    fileprivate struct UnicodeToken {
        let normalizedText: String
        let range: NSRange
    }

    public enum BuildError: Error, LocalizedError, Sendable {
        case unicode61Unavailable(Int32)
        case unicode61TokenizationFailed(Int32)
        case invalidUnicode61Range
        case contentTooLarge

        public var errorDescription: String? {
            switch self {
            case .unicode61Unavailable(let code):
                return "SQLite unicode61 tokenizer is unavailable (code \(code))"
            case .unicode61TokenizationFailed(let code):
                return "SQLite unicode61 tokenization failed (code \(code))"
            case .invalidUnicode61Range:
                return "SQLite unicode61 returned an invalid source range"
            case .contentTooLarge:
                return "Search evidence source exceeds the SQLite tokenizer limit"
            }
        }
    }

    private struct Unicode61ByteToken {
        var normalizedText: String
        let start: Int
        var end: Int
    }

    private final class Unicode61CallbackState {
        let cancellationCheck: () throws -> Void
        var tokens: [Unicode61ByteToken] = []
        var callbackCount = 0
        var cancellationError: Error?

        init(cancellationCheck: @escaping () throws -> Void) {
            self.cancellationCheck = cancellationCheck
        }
    }

    /// Uses SQLite's own built-in tokenizer instead of approximating Unicode 6.1
    /// case folding and Latin-only diacritic removal with Foundation transforms.
    fileprivate final class Unicode61Tokenizer: @unchecked Sendable {
        private let database: OpaquePointer
        private let tokenizer: fts5_tokenizer
        private let instance: OpaquePointer
        private let lock = NSLock()

        private static let tokenCallback: @convention(c) (
            UnsafeMutableRawPointer?,
            Int32,
            UnsafePointer<CChar>?,
            Int32,
            Int32,
            Int32
        ) -> Int32 = { rawState, _, rawToken, tokenLength, start, end in
            guard let rawState, let rawToken else { return SQLITE_ERROR }
            let state = Unmanaged<Unicode61CallbackState>
                .fromOpaque(rawState)
                .takeUnretainedValue()

            state.callbackCount += 1
            if state.callbackCount % Constants.cancellationPollInterval == 0 {
                do {
                    try state.cancellationCheck()
                } catch {
                    state.cancellationError = error
                    return SQLITE_INTERRUPT
                }
            }

            let bytes = UnsafeRawPointer(rawToken).assumingMemoryBound(to: UInt8.self)
            state.tokens.append(
                Unicode61ByteToken(
                    normalizedText: String(
                        decoding: UnsafeBufferPointer(start: bytes, count: Int(tokenLength)),
                        as: UTF8.self
                    ),
                    start: Int(start),
                    end: Int(end)
                )
            )
            return SQLITE_OK
        }

        init() throws {
            var openedDatabase: OpaquePointer?
            let openCode = sqlite3_open_v2(
                ":memory:",
                &openedDatabase,
                SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                nil
            )
            guard openCode == SQLITE_OK, let openedDatabase else {
                if let openedDatabase { sqlite3_close_v2(openedDatabase) }
                throw BuildError.unicode61Unavailable(openCode)
            }

            do {
                var statement: OpaquePointer?
                let prepareCode = sqlite3_prepare_v2(
                    openedDatabase,
                    "SELECT fts5(?1)",
                    -1,
                    &statement,
                    nil
                )
                guard prepareCode == SQLITE_OK, let statement else {
                    throw BuildError.unicode61Unavailable(prepareCode)
                }
                defer { sqlite3_finalize(statement) }

                var api: UnsafeMutablePointer<fts5_api>?
                let stepCode = "fts5_api_ptr".withCString { pointerType in
                    let bindCode = withUnsafeMutablePointer(to: &api) { apiPointer in
                        sqlite3_bind_pointer(statement, 1, apiPointer, pointerType, nil)
                    }
                    guard bindCode == SQLITE_OK else { return bindCode }
                    return sqlite3_step(statement)
                }
                guard stepCode == SQLITE_ROW, let api else {
                    throw BuildError.unicode61Unavailable(stepCode)
                }

                var tokenizerContext: UnsafeMutableRawPointer?
                var foundTokenizer = fts5_tokenizer()
                let findCode = "unicode61".withCString { name in
                    api.pointee.xFindTokenizer?(
                        api,
                        name,
                        &tokenizerContext,
                        &foundTokenizer
                    ) ?? SQLITE_ERROR
                }
                guard findCode == SQLITE_OK,
                      let create = foundTokenizer.xCreate,
                      foundTokenizer.xDelete != nil,
                      foundTokenizer.xTokenize != nil else {
                    throw BuildError.unicode61Unavailable(findCode)
                }

                var createdInstance: OpaquePointer?
                let createCode = "remove_diacritics".withCString { optionName in
                    "2".withCString { optionValue in
                        var arguments: [UnsafePointer<CChar>?] = [optionName, optionValue]
                        return arguments.withUnsafeMutableBufferPointer { buffer in
                            create(
                                tokenizerContext,
                                buffer.baseAddress,
                                Int32(buffer.count),
                                &createdInstance
                            )
                        }
                    }
                }
                guard createCode == SQLITE_OK, let createdInstance else {
                    throw BuildError.unicode61Unavailable(createCode)
                }

                database = openedDatabase
                tokenizer = foundTokenizer
                instance = createdInstance
            } catch {
                sqlite3_close_v2(openedDatabase)
                throw error
            }
        }

        deinit {
            tokenizer.xDelete?(instance)
            sqlite3_close_v2(database)
        }

        func tokens(
            in text: String,
            flags: Int32,
            cancellationCheck: @escaping () throws -> Void
        ) throws -> [UnicodeToken] {
            try cancellationCheck()

            lock.lock()
            defer { lock.unlock() }

            var byteTokens: [Unicode61ByteToken] = []
            var chunkStart = text.startIndex
            var chunkStartByte = 0

            while chunkStart < text.endIndex {
                try cancellationCheck()
                var chunkEnd = chunkStart
                var characterCount = 0
                while chunkEnd < text.endIndex,
                      characterCount < Constants.tokenizerChunkCharacters {
                    if characterCount % Constants.cancellationPollInterval == 0 {
                        try cancellationCheck()
                    }
                    chunkEnd = text.index(after: chunkEnd)
                    characterCount += 1
                }

                let chunk = String(text[chunkStart..<chunkEnd])
                let chunkByteCount = chunk.utf8.count
                guard chunkByteCount <= Int(Int32.max) else { throw BuildError.contentTooLarge }
                let state = Unicode61CallbackState(cancellationCheck: cancellationCheck)
                let rawState = Unmanaged.passUnretained(state).toOpaque()
                let tokenizeCode = chunk.withCString { textPointer in
                    tokenizer.xTokenize?(
                        instance,
                        rawState,
                        flags,
                        textPointer,
                        Int32(chunkByteCount),
                        Self.tokenCallback
                    ) ?? SQLITE_ERROR
                }

                if let cancellationError = state.cancellationError {
                    throw cancellationError
                }
                guard tokenizeCode == SQLITE_OK else {
                    throw BuildError.unicode61TokenizationFailed(tokenizeCode)
                }

                for (tokenIndex, token) in state.tokens.enumerated() {
                    let adjusted = Unicode61ByteToken(
                        normalizedText: token.normalizedText,
                        start: chunkStartByte + token.start,
                        end: chunkStartByte + token.end
                    )
                    if tokenIndex == 0,
                       token.start == 0,
                       var previous = byteTokens.last,
                       previous.end == adjusted.start {
                        previous.normalizedText += adjusted.normalizedText
                        previous.end = adjusted.end
                        byteTokens[byteTokens.count - 1] = previous
                    } else {
                        byteTokens.append(adjusted)
                    }
                }

                chunkStartByte += chunkByteCount
                chunkStart = chunkEnd
            }

            try cancellationCheck()
            let utf8 = text.utf8
            var cursor = utf8.startIndex
            var cursorOffset = 0
            var result: [UnicodeToken] = []
            result.reserveCapacity(byteTokens.count)

            for (index, token) in byteTokens.enumerated() {
                if index % Constants.cancellationPollInterval == 0 {
                    try cancellationCheck()
                }
                guard token.start >= cursorOffset,
                      let startUTF8 = utf8.index(
                        cursor,
                        offsetBy: token.start - cursorOffset,
                        limitedBy: utf8.endIndex
                      ),
                      let endUTF8 = utf8.index(
                        startUTF8,
                        offsetBy: token.end - token.start,
                        limitedBy: utf8.endIndex
                      ),
                      let start = String.Index(startUTF8, within: text),
                      let end = String.Index(endUTF8, within: text) else {
                    throw BuildError.invalidUnicode61Range
                }

                result.append(
                    UnicodeToken(
                        normalizedText: token.normalizedText,
                        range: NSRange(start..<end, in: text)
                    )
                )
                cursor = endUTF8
                cursorOffset = token.end
            }
            return result
        }
    }

    public struct Matcher {
        fileprivate let mode: SearchMode
        fileprivate let coverage: SearchCoverage
        fileprivate let normalizedQuery: String
        fileprivate let exactPhrases: [[String]]
        fileprivate let fuzzyTerm: FuzzyTerm?
        fileprivate let fuzzyPlusTerms: [FuzzyTerm]
        fileprivate let regex: NSRegularExpression?
        fileprivate let unicode61Tokenizer: Unicode61Tokenizer?

        public func makeContext(
            plainText: String,
            note: String?,
            cancellationCheck: @escaping () throws -> Void = {}
        ) throws -> SearchMatchContext? {
            try SearchMatchContextBuilder.makeContext(
                plainText: plainText,
                note: note,
                matcher: self,
                cancellationCheck: cancellationCheck
            )
        }
    }

    public static func prepare(
        request: SearchRequest,
        coverage: SearchCoverage,
        cancellationCheck: @escaping () throws -> Void = {}
    ) throws -> Matcher {
        try cancellationCheck()
        let normalizedQuery: String
        switch request.mode {
        case .regex:
            normalizedQuery = request.query
        case .exact:
            normalizedQuery = SearchPlanner.normalizedExactQuery(request.query)
        case .fuzzy, .fuzzyPlus:
            normalizedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let fuzzyTerm = request.mode == .fuzzy && !normalizedQuery.isEmpty
            ? makeFuzzyTerm(normalizedQuery)
            : nil
        let fuzzyPlusTerms = request.mode == .fuzzyPlus
            ? SearchPlanner.fuzzyPlusTokens(normalizedQuery.lowercased()).map(makeFuzzyTerm)
            : []
        let regex: NSRegularExpression?
        if request.mode == .regex {
            regex = try NSRegularExpression(
                pattern: request.query,
                options: [.caseInsensitive]
            )
        } else {
            regex = nil
        }
        let needsUnicode61 = (request.mode == .exact && normalizedQuery.count > 2)
            || coverage.isPrefilter
        let unicode61Tokenizer: Unicode61Tokenizer?
        let exactPhrases: [[String]]
        if needsUnicode61 {
            let tokenizer = try Unicode61Tokenizer()
            unicode61Tokenizer = tokenizer
            exactPhrases = try ftsEvidencePhrases(
                normalizedQuery,
                tokenizer: tokenizer,
                cancellationCheck: cancellationCheck
            )
        } else {
            unicode61Tokenizer = nil
            exactPhrases = []
        }

        return Matcher(
            mode: request.mode,
            coverage: coverage,
            normalizedQuery: normalizedQuery,
            exactPhrases: exactPhrases,
            fuzzyTerm: fuzzyTerm,
            fuzzyPlusTerms: fuzzyPlusTerms,
            regex: regex,
            unicode61Tokenizer: unicode61Tokenizer
        )
    }

    public static func makeContext(
        plainText: String,
        note: String?,
        request: SearchRequest,
        coverage: SearchCoverage
    ) throws -> SearchMatchContext? {
        try prepare(request: request, coverage: coverage).makeContext(
            plainText: plainText,
            note: note
        )
    }

    private static func makeContext(
        plainText: String,
        note: String?,
        matcher: Matcher,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> SearchMatchContext? {
        try cancellationCheck()

        let matchSet: MatchSet
        switch matcher.mode {
        case .exact:
            guard !matcher.normalizedQuery.isEmpty else { return nil }
            matchSet = try exactMatches(
                query: matcher.normalizedQuery,
                phrases: matcher.exactPhrases,
                plainText: plainText,
                note: note,
                tokenizer: matcher.unicode61Tokenizer,
                cancellationCheck: cancellationCheck
            )
        case .fuzzy:
            guard let fuzzyTerm = matcher.fuzzyTerm else { return nil }
            matchSet = try fuzzyMatches(
                term: fuzzyTerm,
                prefilterPhrases: matcher.exactPhrases,
                plainText: plainText,
                note: note,
                coverage: matcher.coverage,
                tokenizer: matcher.unicode61Tokenizer,
                cancellationCheck: cancellationCheck
            )
        case .fuzzyPlus:
            guard !matcher.fuzzyPlusTerms.isEmpty else { return nil }
            matchSet = try fuzzyPlusMatches(
                terms: matcher.fuzzyPlusTerms,
                prefilterPhrases: matcher.exactPhrases,
                plainText: plainText,
                note: note,
                coverage: matcher.coverage,
                tokenizer: matcher.unicode61Tokenizer,
                cancellationCheck: cancellationCheck
            )
        case .regex:
            guard !matcher.normalizedQuery.isEmpty,
                  let regex = matcher.regex else { return nil }
            matchSet = try regexMatches(
                regex: regex,
                plainText: plainText,
                note: note,
                cancellationCheck: cancellationCheck
            )
        }

        guard !matchSet.matches.isEmpty else { return nil }
        try cancellationCheck()
        let fragments = makeFragments(
            matches: matchSet.matches,
            plainText: plainText,
            note: note
        )
        guard !fragments.isEmpty else { return nil }

        return SearchMatchContext(
            mode: matcher.mode,
            fragments: fragments,
            occurrenceCount: max(matchSet.occurrenceCount, 1),
            occurrenceCountIsTruncated: matchSet.isTruncated,
            isPositionOnly: fragments.allSatisfy(\.highlightedRanges.isEmpty)
        )
    }

    private static func makeFuzzyTerm(_ text: String) -> FuzzyTerm {
        FuzzyTerm(text: text, lowercasedCharacters: Array(text.lowercased()))
    }

    private static func exactMatches(
        query: String,
        phrases: [[String]],
        plainText: String,
        note: String?,
        tokenizer: Unicode61Tokenizer?,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        if query.count <= 2 {
            return try literalMatches(
                query,
                sources: searchableSources(plainText: plainText, note: note),
                termIndex: 0,
                cancellationCheck: cancellationCheck
            )
        }

        guard let tokenizer else { throw BuildError.unicode61Unavailable(SQLITE_ERROR) }
        let sources = searchableSources(plainText: plainText, note: note)
        let phraseResult = try ftsPhraseMatches(
            phrases: phrases,
            sources: sources,
            tokenizer: tokenizer,
            cancellationCheck: cancellationCheck
        )
        if !phraseResult.matches.isEmpty {
            return phraseResult
        }

        // Exact search only falls back to substring matching when the FTS page is empty
        // for a non-ASCII query. Mirroring that fallback keeps every returned candidate
        // explainable without inventing ASCII substring hits inside larger FTS tokens.
        guard !query.canBeConverted(to: .ascii) else { return MatchSet() }
        return try requiredLiteralMatches(
            terms: substringSearchTerms(query),
            sources: sources,
            cancellationCheck: cancellationCheck
        )
    }

    private static func fuzzyMatches(
        term: FuzzyTerm,
        prefilterPhrases: [[String]],
        plainText: String,
        note: String?,
        coverage: SearchCoverage,
        tokenizer: Unicode61Tokenizer?,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        if term.text.count <= 2 {
            return try literalMatches(
                term.text,
                sources: searchableSources(plainText: plainText, note: note),
                termIndex: 0,
                cancellationCheck: cancellationCheck
            )
        }

        if let witness = try fuzzyWitness(
            term: term,
            plainText: plainText,
            note: note,
            termIndex: 0,
            cancellationCheck: cancellationCheck
        ) {
            return MatchSet(matches: witness, occurrenceCount: 1, isTruncated: false)
        }

        guard coverage.isPrefilter else { return MatchSet() }
        guard let tokenizer else { throw BuildError.unicode61Unavailable(SQLITE_ERROR) }
        return try ftsPhraseMatches(
            phrases: prefilterPhrases,
            sources: searchableSources(plainText: plainText, note: note),
            tokenizer: tokenizer,
            cancellationCheck: cancellationCheck
        )
    }

    private static func fuzzyPlusMatches(
        terms: [FuzzyTerm],
        prefilterPhrases: [[String]],
        plainText: String,
        note: String?,
        coverage: SearchCoverage,
        tokenizer: Unicode61Tokenizer?,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        let sources = searchableSources(plainText: plainText, note: note)
        var result = MatchSet()

        for (termIndex, term) in terms.enumerated() {
            try cancellationCheck()
            let termMatches: MatchSet
            if term.text.count <= 2 || term.text.canBeConverted(to: .ascii) {
                termMatches = try literalMatches(
                    term.text,
                    sources: sources,
                    termIndex: termIndex,
                    cancellationCheck: cancellationCheck
                )
            } else if let witness = try fuzzyWitness(
                term: term,
                plainText: plainText,
                note: note,
                termIndex: termIndex,
                cancellationCheck: cancellationCheck
            ) {
                termMatches = MatchSet(
                    matches: witness,
                    occurrenceCount: 1,
                    isTruncated: false
                )
            } else {
                termMatches = MatchSet()
            }

            guard !termMatches.matches.isEmpty else {
                if coverage.isPrefilter {
                    guard let tokenizer else {
                        throw BuildError.unicode61Unavailable(SQLITE_ERROR)
                    }
                    return try ftsPhraseMatches(
                        phrases: prefilterPhrases,
                        sources: sources,
                        tokenizer: tokenizer,
                        cancellationCheck: cancellationCheck
                    )
                }
                return MatchSet()
            }
            result.append(termMatches)
        }

        return result
    }

    private static func regexMatches(
        regex: NSRegularExpression,
        plainText: String,
        note: String?,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        try cancellationCheck()
        var result = MatchSet()
        for (source, text) in searchableSources(plainText: plainText, note: note) {
            try cancellationCheck()
            let nsText = text as NSString
            let fullRange = NSRange(text.startIndex..., in: text)
            var sourceOccurrenceCount = 0
            var cancellationError: Error?
            regex.enumerateMatches(
                in: text,
                options: [.reportProgress],
                range: fullRange
            ) { match, _, stop in
                do {
                    try cancellationCheck()
                } catch {
                    cancellationError = error
                    stop.pointee = true
                    return
                }
                guard let match else { return }
                if sourceOccurrenceCount >= Constants.maxOccurrencesPerTerm {
                    result.isTruncated = true
                    stop.pointee = true
                    return
                }
                let displayRange = match.range.length == 0
                    ? match.range
                    : nsText.rangeOfComposedCharacterSequences(for: match.range)
                result.matches.append(
                    RawMatch(source: source, range: displayRange, termIndex: 0)
                )
                result.occurrenceCount += 1
                sourceOccurrenceCount += 1
            }
            if let cancellationError { throw cancellationError }
        }
        try cancellationCheck()
        return result
    }

    private static func literalMatches(
        _ needle: String,
        sources: [(SearchMatchSource, String)],
        termIndex: Int,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        guard !needle.isEmpty else { return MatchSet() }
        let options: NSString.CompareOptions = [.caseInsensitive]

        var result = MatchSet()
        for (source, text) in sources {
            try cancellationCheck()
            let nsText = text as NSString
            let needleUTF16Count = max(1, (needle as NSString).length)
            let overlap = max(64, min(Int.max / 4, needleUTF16Count) * 4)
            var chunkStart = 0
            var nextAllowedLocation = 0
            var sourceOccurrenceCount = 0
            var reachedOccurrenceCap = false
            while chunkStart < nsText.length {
                try cancellationCheck()
                let coreEnd = min(nsText.length, chunkStart + Constants.literalScanChunkUTF16)
                let windowEnd = min(nsText.length, coreEnd + overlap)
                var searchLocation = max(chunkStart, nextAllowedLocation)

                while searchLocation < windowEnd {
                    try cancellationCheck()
                    let searchRange = NSRange(
                        location: searchLocation,
                        length: windowEnd - searchLocation
                    )
                    let range = nsText.range(of: needle, options: options, range: searchRange)
                    guard range.location != NSNotFound else { break }
                    guard range.location < coreEnd || coreEnd == nsText.length else { break }
                    if sourceOccurrenceCount >= Constants.maxOccurrencesPerTerm {
                        result.isTruncated = true
                        reachedOccurrenceCap = true
                        break
                    }
                    let displayRange = nsText.rangeOfComposedCharacterSequences(for: range)
                    result.matches.append(
                        RawMatch(source: source, range: displayRange, termIndex: termIndex)
                    )
                    result.occurrenceCount += 1
                    sourceOccurrenceCount += 1

                    let nextLocation = NSMaxRange(range)
                    guard range.length > 0, nextLocation < nsText.length else {
                        searchLocation = windowEnd
                        nextAllowedLocation = nsText.length
                        break
                    }
                    searchLocation = nextLocation
                    nextAllowedLocation = nextLocation
                }

                if reachedOccurrenceCap { break }
                chunkStart = coreEnd
            }
        }
        return result
    }

    private static func fuzzyWitness(
        term: FuzzyTerm,
        plainText: String,
        note: String?,
        termIndex: Int,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> [RawMatch]? {
        let queryCharacters = term.lowercasedCharacters
        guard !queryCharacters.isEmpty else { return nil }

        var queryIndex = 0
        var matches: [RawMatch] = []

        func consume(_ text: String, source: SearchMatchSource) throws {
            guard queryIndex < queryCharacters.count else { return }
            var utf16Location = 0
            for (characterIndex, character) in text.enumerated() {
                if characterIndex % Constants.cancellationPollInterval == 0 {
                    try cancellationCheck()
                }
                let characterString = String(character)
                let characterLength = characterString.utf16.count
                for foldedCharacter in characterString.lowercased() {
                    guard queryIndex < queryCharacters.count else { break }
                    if foldedCharacter == queryCharacters[queryIndex] {
                        let rawMatch = RawMatch(
                            source: source,
                            range: NSRange(location: utf16Location, length: characterLength),
                            termIndex: termIndex
                        )
                        if matches.last != rawMatch {
                            matches.append(rawMatch)
                        }
                        queryIndex += 1
                    }
                }
                if queryIndex >= queryCharacters.count { return }
                utf16Location += characterLength
            }
        }

        try consume(plainText, source: .content)
        if queryIndex < queryCharacters.count,
           queryCharacters[queryIndex] == "\n" {
            queryIndex += 1
        }
        if let note, queryIndex < queryCharacters.count {
            try consume(note, source: .note)
        }

        return queryIndex == queryCharacters.count ? matches : nil
    }

    private static func ftsEvidencePhrases(
        _ query: String,
        tokenizer: Unicode61Tokenizer,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> [[String]] {
        let normalized = query
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")

        var seen: Set<[String]> = []
        var phrases: [[String]] = []
        for part in normalized.split(whereSeparator: \.isWhitespace) {
            try cancellationCheck()
            let phrase = try tokenizer.tokens(
                in: String(part),
                flags: FTS5_TOKENIZE_QUERY,
                cancellationCheck: cancellationCheck
            ).map(\.normalizedText)
            guard !phrase.isEmpty, seen.insert(phrase).inserted else { continue }
            phrases.append(phrase)
        }
        return phrases
    }

    private static func substringSearchTerms(_ query: String) -> [String] {
        query
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    private static func requiredLiteralMatches(
        terms: [String],
        sources: [(SearchMatchSource, String)],
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        guard !terms.isEmpty else { return MatchSet() }
        var result = MatchSet()
        for (termIndex, term) in terms.enumerated() {
            try cancellationCheck()
            let matches = try literalMatches(
                term,
                sources: sources,
                termIndex: termIndex,
                cancellationCheck: cancellationCheck
            )
            guard !matches.matches.isEmpty else { return MatchSet() }
            result.append(matches)
        }
        return result
    }

    private static func ftsPhraseMatches(
        phrases: [[String]],
        sources: [(SearchMatchSource, String)],
        tokenizer: Unicode61Tokenizer,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        guard !phrases.isEmpty else { return MatchSet() }
        var tokenizedSources: [(source: SearchMatchSource, tokens: [UnicodeToken])] = []
        tokenizedSources.reserveCapacity(sources.count)
        for (source, text) in sources {
            try cancellationCheck()
            tokenizedSources.append(
                (
                    source: source,
                    tokens: try tokenizer.tokens(
                        in: text,
                        flags: FTS5_TOKENIZE_DOCUMENT,
                        cancellationCheck: cancellationCheck
                    )
                )
            )
        }
        var result = MatchSet()

        for (termIndex, phrase) in phrases.enumerated() {
            try cancellationCheck()
            var phraseWasFound = false
            for source in tokenizedSources {
                var sourceOccurrenceCount = 0
                guard source.tokens.count >= phrase.count else { continue }

                for start in 0...(source.tokens.count - phrase.count) {
                    if start % Constants.cancellationPollInterval == 0 {
                        try cancellationCheck()
                    }
                    var matchesPhrase = true
                    for offset in phrase.indices where
                        source.tokens[start + offset].normalizedText != phrase[offset] {
                        matchesPhrase = false
                        break
                    }
                    guard matchesPhrase else { continue }
                    phraseWasFound = true
                    if sourceOccurrenceCount >= Constants.maxOccurrencesPerTerm {
                        result.isTruncated = true
                        break
                    }

                    for offset in phrase.indices {
                        result.matches.append(
                            RawMatch(
                                source: source.source,
                                range: source.tokens[start + offset].range,
                                termIndex: termIndex
                            )
                        )
                    }
                    result.occurrenceCount += 1
                    sourceOccurrenceCount += 1
                }
            }
            guard phraseWasFound else { return MatchSet() }
        }

        return result
    }

    private static func searchableSources(
        plainText: String,
        note: String?
    ) -> [(SearchMatchSource, String)] {
        var sources: [(SearchMatchSource, String)] = [(.content, plainText)]
        if let note, !note.isEmpty {
            sources.append((.note, note))
        }
        return sources
    }

    private static func makeFragments(
        matches: [RawMatch],
        plainText: String,
        note: String?
    ) -> [SearchMatchFragment] {
        let uniqueMatches = Array(Set(matches)).sorted(by: rawMatchOrder)
        let clusters = selectedClusters(from: uniqueMatches)
        let characterBudget = clusters.count == 1
            ? Constants.singleFragmentCharacters
            : Constants.splitFragmentCharacters
        let leadingContextCharacters = clusters.count == 1
            ? Constants.leadingContextCharacters
            : Constants.splitLeadingContextCharacters

        return clusters.compactMap { cluster in
            let sourceText: String
            switch cluster.source {
            case .content:
                sourceText = plainText
            case .note:
                sourceText = note ?? ""
            }
            return makeFragment(
                source: cluster.source,
                sourceText: sourceText,
                matches: cluster.matches,
                characterBudget: characterBudget,
                leadingContextCharacters: leadingContextCharacters
            )
        }
    }

    private static func selectedClusters(from matches: [RawMatch]) -> [MatchCluster] {
        let contentClusters = clusters(for: .content, matches: matches)
        let noteClusters = clusters(for: .note, matches: matches)

        if let content = bestCluster(contentClusters),
           let note = bestCluster(noteClusters) {
            return [content, note]
        }

        let available = contentClusters.isEmpty ? noteClusters : contentClusters
        return available
            .sorted {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.location < $1.location
            }
            .prefix(2)
            .map { $0 }
    }

    private static func clusters(
        for source: SearchMatchSource,
        matches: [RawMatch]
    ) -> [MatchCluster] {
        let sourceMatches = matches
            .filter { $0.source == source }
            .sorted(by: rawMatchOrder)
        guard var current = sourceMatches.first.map({ [$0] }) else { return [] }

        var result: [MatchCluster] = []
        for match in sourceMatches.dropFirst() {
            let previousEnd = NSMaxRange(current[current.count - 1].range)
            if match.range.location - previousEnd <= Constants.clusterGapUTF16 {
                current.append(match)
            } else {
                result.append(MatchCluster(source: source, matches: current))
                current = [match]
            }
        }
        result.append(MatchCluster(source: source, matches: current))
        return result
    }

    private static func bestCluster(_ clusters: [MatchCluster]) -> MatchCluster? {
        clusters.max {
            if $0.score != $1.score { return $0.score < $1.score }
            return $0.location > $1.location
        }
    }

    private static func rawMatchOrder(_ lhs: RawMatch, _ rhs: RawMatch) -> Bool {
        if lhs.source != rhs.source {
            return lhs.source.rawValue < rhs.source.rawValue
        }
        if lhs.range.location != rhs.range.location {
            return lhs.range.location < rhs.range.location
        }
        return lhs.range.length < rhs.range.length
    }

    private static func makeFragment(
        source: SearchMatchSource,
        sourceText: String,
        matches: [RawMatch],
        characterBudget: Int,
        leadingContextCharacters: Int
    ) -> SearchMatchFragment? {
        guard let firstMatch = matches.first else { return nil }
        if sourceText.isEmpty, firstMatch.range.location == 0, firstMatch.range.length == 0 {
            return SearchMatchFragment(
                source: source,
                text: "（空内容）",
                highlightedRanges: []
            )
        }

        guard !sourceText.isEmpty,
              let firstRange = Range(firstMatch.range, in: sourceText) else { return nil }

        let lastMatch = matches.last ?? firstMatch
        let unionNSRange = NSRange(
            location: firstMatch.range.location,
            length: max(0, NSMaxRange(lastMatch.range) - firstMatch.range.location)
        )
        let unionRange = Range(unionNSRange, in: sourceText)
        let targetRange: Range<String.Index>
        if let unionRange,
           sourceText.distance(from: unionRange.lowerBound, to: unionRange.upperBound)
            <= characterBudget - leadingContextCharacters {
            targetRange = unionRange
        } else {
            targetRange = firstRange
        }

        let leadingCount = min(
            leadingContextCharacters,
            sourceText.distance(from: sourceText.startIndex, to: targetRange.lowerBound)
        )
        let sliceStart = sourceText.index(targetRange.lowerBound, offsetBy: -leadingCount)
        let targetCount = sourceText.distance(from: targetRange.lowerBound, to: targetRange.upperBound)
        let remainingCount = max(0, characterBudget - leadingCount - min(targetCount, characterBudget))
        let targetEnd = sourceText.index(
            targetRange.lowerBound,
            offsetBy: min(targetCount, characterBudget),
            limitedBy: sourceText.endIndex
        ) ?? sourceText.endIndex
        let sliceEnd = sourceText.index(
            targetEnd,
            offsetBy: remainingCount,
            limitedBy: sourceText.endIndex
        ) ?? sourceText.endIndex

        let fragment = normalizedFragment(
            source: source,
            sourceText: sourceText,
            slice: sliceStart..<sliceEnd,
            matches: matches,
            hasLeadingOmission: sliceStart != sourceText.startIndex,
            hasTrailingOmission: sliceEnd != sourceText.endIndex
        )
        if fragment.text.isEmpty {
            return SearchMatchFragment(
                source: source,
                text: "（空白内容）",
                highlightedRanges: []
            )
        }
        return fragment
    }

    private static func normalizedFragment(
        source: SearchMatchSource,
        sourceText: String,
        slice: Range<String.Index>,
        matches: [RawMatch],
        hasLeadingOmission: Bool,
        hasTrailingOmission: Bool
    ) -> SearchMatchFragment {
        var output = hasLeadingOmission ? "…" : ""
        var outputCharacterCount = hasLeadingOmission ? 1 : 0
        var highlightedRanges: [SearchMatchTextRange] = []
        var activeHighlightStart: Int?
        var previousWasWhitespace = false
        var utf16Location = slice.lowerBound.utf16Offset(in: sourceText)

        func closeHighlight() {
            guard let start = activeHighlightStart else { return }
            highlightedRanges.append(
                SearchMatchTextRange(
                    offset: start,
                    length: outputCharacterCount - start
                )
            )
            activeHighlightStart = nil
        }

        for character in sourceText[slice] {
            let characterString = String(character)
            let characterLength = characterString.utf16.count
            let characterRange = NSRange(location: utf16Location, length: characterLength)
            let isWhitespace = character.isWhitespace
            let isHighlighted = !isWhitespace && matches.contains { rawMatch in
                rawMatch.range.length > 0 && NSIntersectionRange(rawMatch.range, characterRange).length > 0
            }
            utf16Location += characterLength

            if isWhitespace {
                closeHighlight()
                if !previousWasWhitespace, !output.isEmpty, output.last != "…" {
                    output.append(" ")
                    outputCharacterCount += 1
                }
                previousWasWhitespace = true
                continue
            }

            if isHighlighted, activeHighlightStart == nil {
                activeHighlightStart = outputCharacterCount
            } else if !isHighlighted {
                closeHighlight()
            }
            output.append(character)
            outputCharacterCount += 1
            previousWasWhitespace = false
        }
        closeHighlight()

        if output.last == " " {
            output.removeLast()
            outputCharacterCount -= 1
        }
        if hasTrailingOmission {
            output.append("…")
        }

        return SearchMatchFragment(
            source: source,
            text: output,
            highlightedRanges: highlightedRanges
        )
    }
}
