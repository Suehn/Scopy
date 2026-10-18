import Foundation
import SQLite3

/// Builds bounded, source-aware evidence with the same matching rules used by search.
/// Prepare one matcher per request, then reuse it for every item in the returned page.
public enum SearchMatchContextBuilder {
    private enum Constants {
        static let maxOccurrencesPerTerm = 32
        static let literalScanChunkUTF16 = 64 * 1024
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
        let pattern: FuzzyPattern
    }

    /// A lowercased fuzzy term as `FuzzyMatcher` compares it: UTF-16 units for an ASCII term,
    /// characters otherwise.
    fileprivate enum FuzzyPattern {
        case utf16([UInt16])
        case characters([Character])
    }

    fileprivate struct UnicodeToken {
        /// The folded UTF-8 in `UnicodeTokens.foldedBytes`.
        let folded: Range<Int>
        let foldedIsNFCInert: Bool
        let range: NSRange
    }

    /// unicode61 tokens of one text, their folded UTF-8 kept in one buffer.
    fileprivate struct UnicodeTokens {
        let foldedBytes: [UInt8]
        let tokens: [UnicodeToken]

        func foldedText(_ token: UnicodeToken) -> String {
            foldedBytes.withUnsafeBufferPointer { buffer in
                String(decoding: UnsafeBufferPointer(rebasing: buffer[token.folded]), as: UTF8.self)
            }
        }

        /// The canonical equivalence `String ==` decides. Texts made only of NFC-inert scalars are
        /// in NFC, so for two of them it is byte equality.
        func token(at index: Int, equals term: PhraseTerm) -> Bool {
            let token = tokens[index]
            if token.folded.count == term.utf8.count {
                let sameBytes = foldedBytes.withUnsafeBufferPointer { buffer in
                    term.utf8.withUnsafeBufferPointer { termBuffer in
                        guard let base = buffer.baseAddress, let termBase = termBuffer.baseAddress else {
                            return true
                        }
                        return memcmp(base + token.folded.lowerBound, termBase, termBuffer.count) == 0
                    }
                }
                if sameBytes { return true }
            }
            if token.foldedIsNFCInert && term.isNFCInert { return false }
            return foldedText(token) == term.text
        }
    }

    /// One folded query token of an FTS evidence phrase.
    fileprivate struct PhraseTerm {
        let text: String
        let utf8: [UInt8]
        let isNFCInert: Bool

        init(_ text: String) {
            self.text = text
            utf8 = Array(text.utf8)
            isNFCInert = utf8.withUnsafeBufferPointer(SearchMatchContextBuilder.isNFCInert)
        }
    }

    /// Whether every scalar is NFC quick-check Yes with canonical combining class 0: Latin and
    /// other scalars below U+0300, kana without combining marks, CJK ideographs, and Hangul
    /// syllables. Such a text is in NFC.
    fileprivate static func isNFCInert(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        var index = 0
        while index < bytes.count {
            let lead = bytes[index]
            if lead < 0x80 {
                index += 1
            } else if lead >= 0xC2, lead < 0xCC, index + 1 < bytes.count {
                index += 2
            } else if lead >= 0xE3, lead <= 0xED, index + 2 < bytes.count {
                let scalar = UInt32(lead & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6
                    | UInt32(bytes[index + 2] & 0x3F)
                switch scalar {
                case 0x3041...0x3096, 0x30A1...0x30FA, 0x3400...0x9FFF, 0xAC00...0xD7A3:
                    index += 3
                default:
                    return false
                }
            } else {
                return false
            }
        }
        return true
    }

    /// A searchable text whose UTF-16 copy is made once, on its first literal search, and shared
    /// by every term.
    private final class EvidenceSource {
        let source: SearchMatchSource
        let text: String
        private var utf16Copy: UTF16Text?

        init(source: SearchMatchSource, text: String) {
            self.source = source
            self.text = text
        }

        var utf16Text: NSString {
            if let utf16Copy { return utf16Copy }
            let copy = UTF16Text(copying: text)
            utf16Copy = copy
            return copy
        }
    }

    /// UTF-16 units served through `getCharacters(_:range:)`. Foundation searches it on the path
    /// it takes for a bridged String, whose grapheme handling differs from a CFString copy's, so
    /// results stay those of the bridged String without its per-refill transcoding.
    private final class UTF16Text: NSString {
        private var units: [UInt16] = []

        convenience init(copying text: String) {
            self.init()
            var text = text
            units = text.withUTF8 { bytes in
                // A scalar never needs more UTF-16 units than UTF-8 bytes.
                [UInt16](unsafeUninitializedCapacity: bytes.count) { buffer, count in
                    count = 0
                    var index = 0
                    while index < bytes.count {
                        let lead = UInt32(bytes[index])
                        if lead < 0x80 {
                            buffer[count] = UInt16(lead)
                            count += 1
                            index += 1
                        } else if lead < 0xE0 {
                            buffer[count] = UInt16((lead & 0x1F) << 6 | UInt32(bytes[index + 1] & 0x3F))
                            count += 1
                            index += 2
                        } else if lead < 0xF0 {
                            buffer[count] = UInt16(
                                (lead & 0x0F) << 12 | UInt32(bytes[index + 1] & 0x3F) << 6
                                    | UInt32(bytes[index + 2] & 0x3F)
                            )
                            count += 1
                            index += 3
                        } else {
                            let scalar = ((lead & 0x07) << 18 | UInt32(bytes[index + 1] & 0x3F) << 12
                                | UInt32(bytes[index + 2] & 0x3F) << 6 | UInt32(bytes[index + 3] & 0x3F))
                                - 0x10000
                            buffer[count] = UInt16(0xD800 | scalar >> 10)
                            buffer[count + 1] = UInt16(0xDC00 | scalar & 0x3FF)
                            count += 2
                            index += 4
                        }
                    }
                }
            }
        }

        override var length: Int { units.count }

        override func character(at index: Int) -> unichar { units[index] }

        override func getCharacters(_ buffer: UnsafeMutablePointer<unichar>, range: NSRange) {
            units.withUnsafeBufferPointer { source in
                guard range.length > 0, let base = source.baseAddress else { return }
                buffer.update(from: base + range.location, count: range.length)
            }
        }
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
        let folded: Range<Int>
        let foldedIsNFCInert: Bool
        let start: Int
        let end: Int
    }

    private final class Unicode61CallbackState {
        let cancellationCheck: () throws -> Void
        var foldedBytes: [UInt8] = []
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

            let bytes = UnsafeBufferPointer(
                start: UnsafeRawPointer(rawToken).assumingMemoryBound(to: UInt8.self),
                count: Int(tokenLength)
            )
            let foldedStart = state.foldedBytes.count
            state.foldedBytes.append(contentsOf: bytes)
            state.tokens.append(
                Unicode61ByteToken(
                    folded: foldedStart..<state.foldedBytes.count,
                    foldedIsNFCInert: SearchMatchContextBuilder.isNFCInert(bytes),
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

        /// Tokenizes the contiguous UTF-8 text in one call and converts token byte offsets to
        /// UTF-16 ranges in a single forward pass.
        func tokens(
            in text: String,
            flags: Int32,
            cancellationCheck: @escaping () throws -> Void
        ) throws -> UnicodeTokens {
            try cancellationCheck()
            var contiguousText = text
            contiguousText.makeContiguousUTF8()
            let source = contiguousText

            lock.lock()
            defer { lock.unlock() }

            let tokenized = try source.utf8.withContiguousStorageIfAvailable {
                (bytes: UnsafeBufferPointer<UInt8>) throws -> UnicodeTokens in
                try self.tokens(in: source, bytes: bytes, flags: flags, cancellationCheck: cancellationCheck)
            }
            guard let tokenized else { throw BuildError.invalidUnicode61Range }
            return tokenized
        }

        private func tokens(
            in text: String,
            bytes: UnsafeBufferPointer<UInt8>,
            flags: Int32,
            cancellationCheck: @escaping () throws -> Void
        ) throws -> UnicodeTokens {
            guard let base = bytes.baseAddress, !bytes.isEmpty else {
                return UnicodeTokens(foldedBytes: [], tokens: [])
            }
            guard bytes.count <= Int(Int32.max) else { throw BuildError.contentTooLarge }

            let state = Unicode61CallbackState(cancellationCheck: cancellationCheck)
            let rawState = Unmanaged.passUnretained(state).toOpaque()
            let tokenizeCode = base.withMemoryRebound(to: CChar.self, capacity: bytes.count) {
                tokenizer.xTokenize?(
                    instance,
                    rawState,
                    flags,
                    $0,
                    Int32(bytes.count),
                    Self.tokenCallback
                ) ?? SQLITE_ERROR
            }
            if let cancellationError = state.cancellationError {
                throw cancellationError
            }
            guard tokenizeCode == SQLITE_OK else {
                throw BuildError.unicode61TokenizationFailed(tokenizeCode)
            }

            try cancellationCheck()
            var cursorByte = 0
            var cursorUTF16 = 0
            var result: [UnicodeToken] = []
            result.reserveCapacity(state.tokens.count)

            for (index, token) in state.tokens.enumerated() {
                if index % Constants.cancellationPollInterval == 0 {
                    try cancellationCheck()
                }
                guard token.start >= cursorByte,
                      token.end >= token.start,
                      token.end <= bytes.count,
                      Self.isCharacterBoundary(token.start, in: text, bytes: bytes),
                      Self.isCharacterBoundary(token.end, in: text, bytes: bytes) else {
                    throw BuildError.invalidUnicode61Range
                }

                let startUTF16 = cursorUTF16
                    + SearchMatchContextBuilder.utf16Count(bytes, from: cursorByte, to: token.start)
                let lengthUTF16 = SearchMatchContextBuilder.utf16Count(bytes, from: token.start, to: token.end)
                result.append(
                    UnicodeToken(
                        folded: token.folded,
                        foldedIsNFCInert: token.foldedIsNFCInert,
                        range: NSRange(location: startUTF16, length: lengthUTF16)
                    )
                )
                cursorByte = token.end
                cursorUTF16 = startUTF16 + lengthUTF16
            }
            return UnicodeTokens(foldedBytes: state.foldedBytes, tokens: result)
        }

        /// Whether `String.Index(_:within:)` accepts the UTF-8 offset. Scalar pairs that break in
        /// every grapheme-breaking state skip the standard library's state machine.
        private static func isCharacterBoundary(
            _ offset: Int,
            in text: String,
            bytes: UnsafeBufferPointer<UInt8>
        ) -> Bool {
            if offset == 0 || offset == bytes.count { return true }
            let followingByte = bytes[offset]
            let precedingByte = bytes[offset - 1]
            if followingByte < 0x80, precedingByte < 0x80 {
                if !(precedingByte == 0x0D && followingByte == 0x0A) { return true }
            } else if let following = scalarValue(startingAt: offset, in: bytes),
               let preceding = scalarValue(endingAt: offset, in: bytes),
               alwaysBreaksAround(preceding),
               alwaysBreaksAround(following) {
                return true
            }
            let index = text.utf8.index(text.utf8.startIndex, offsetBy: offset)
            return String.Index(index, within: text) != nil
        }

        /// Scalars without Extend, SpacingMark, Prepend, ZWJ, regional-indicator, Hangul jamo,
        /// Indic consonant, or emoji properties: two of them always form a grapheme break,
        /// except CR LF.
        private static func alwaysBreaksAround(_ scalar: UInt32) -> Bool {
            switch scalar {
            case 0x0000...0x02FF,
                 0x2010...0x2029,
                 0x3000...0x3029,
                 0x3041...0x3096,
                 0x30A1...0x30FA,
                 0x3400...0x9FFF,
                 0xAC00...0xD7A3,
                 0xFF01...0xFF9D:
                return true
            default:
                return false
            }
        }

        /// The scalar whose UTF-8 encoding starts at `offset`, or nil inside a scalar.
        private static func scalarValue(startingAt offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
            let lead = UInt32(bytes[offset])
            switch lead {
            case 0..<0x80:
                return lead
            case 0x80..<0xC0:
                return nil
            case 0xC0..<0xE0:
                return (lead & 0x1F) << 6 | UInt32(bytes[offset + 1] & 0x3F)
            case 0xE0..<0xF0:
                return (lead & 0x0F) << 12 | UInt32(bytes[offset + 1] & 0x3F) << 6
                    | UInt32(bytes[offset + 2] & 0x3F)
            default:
                return (lead & 0x07) << 18 | UInt32(bytes[offset + 1] & 0x3F) << 12
                    | UInt32(bytes[offset + 2] & 0x3F) << 6 | UInt32(bytes[offset + 3] & 0x3F)
            }
        }

        /// The scalar whose UTF-8 encoding ends at `offset`, which must start a scalar.
        private static func scalarValue(endingAt offset: Int, in bytes: UnsafeBufferPointer<UInt8>) -> UInt32? {
            var start = offset - 1
            while start > 0, bytes[start] & 0xC0 == 0x80 {
                start -= 1
            }
            return scalarValue(startingAt: start, in: bytes)
        }

    }

    public struct Matcher {
        fileprivate let mode: SearchMode
        fileprivate let coverage: SearchCoverage
        fileprivate let normalizedQuery: String
        fileprivate let exactPhrases: [[PhraseTerm]]
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
            normalizedQuery = SearchQueryNormalization.normalizedExactQuery(request.query)
        case .fuzzy, .fuzzyPlus:
            normalizedQuery = request.query.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let fuzzyTerm = request.mode == .fuzzy && !normalizedQuery.isEmpty
            ? makeFuzzyTerm(normalizedQuery)
            : nil
        let fuzzyPlusTerms = request.mode == .fuzzyPlus
            ? SearchQueryNormalization.fuzzyPlusTokens(normalizedQuery.lowercased()).map(makeFuzzyTerm)
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
            || coverage.isStagedRefine
        let unicode61Tokenizer: Unicode61Tokenizer?
        let exactPhrases: [[PhraseTerm]]
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
        let lower = text.lowercased()
        return FuzzyTerm(
            text: text,
            pattern: lower.canBeConverted(to: .ascii) ? .utf16(Array(lower.utf16)) : .characters(Array(lower))
        )
    }

    private static func exactMatches(
        query: String,
        phrases: [[PhraseTerm]],
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
        prefilterPhrases: [[PhraseTerm]],
        plainText: String,
        note: String?,
        coverage: SearchCoverage,
        tokenizer: Unicode61Tokenizer?,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        let sources = searchableSources(plainText: plainText, note: note)
        if term.text.count <= 2 {
            return try literalMatches(
                term.text,
                sources: sources,
                termIndex: 0,
                cancellationCheck: cancellationCheck
            )
        }

        if let witness = try fuzzyWitness(
            term: term,
            sources: sources,
            termIndex: 0,
            cancellationCheck: cancellationCheck
        ) {
            return MatchSet(matches: witness, occurrenceCount: 1, isTruncated: false)
        }

        guard coverage.isStagedRefine else { return MatchSet() }
        guard let tokenizer else { throw BuildError.unicode61Unavailable(SQLITE_ERROR) }
        return try ftsPhraseMatches(
            phrases: prefilterPhrases,
            sources: sources,
            tokenizer: tokenizer,
            cancellationCheck: cancellationCheck
        )
    }

    private static func fuzzyPlusMatches(
        terms: [FuzzyTerm],
        prefilterPhrases: [[PhraseTerm]],
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
                sources: sources,
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
                if coverage.isStagedRefine {
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
        for evidenceSource in searchableSources(plainText: plainText, note: note) {
            try cancellationCheck()
            let source = evidenceSource.source
            let text = evidenceSource.text
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
        sources: [EvidenceSource],
        termIndex: Int,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        guard !needle.isEmpty else { return MatchSet() }
        let options: NSString.CompareOptions = [.caseInsensitive]

        var result = MatchSet()
        for evidenceSource in sources {
            try cancellationCheck()
            let source = evidenceSource.source
            let nsText = evidenceSource.utf16Text
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

    /// The match `FuzzyMatcher` scores, over the elements it compares in `content + "\n" + note`:
    /// the leftmost greedy subsequence match, or the first contiguous occurrence when that scores
    /// higher (`FuzzySubsequence`).
    private static func fuzzyWitness(
        term: FuzzyTerm,
        sources: [EvidenceSource],
        termIndex: Int,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> [RawMatch]? {
        switch term.pattern {
        case .utf16(let units):
            return try fuzzyWitness(
                pattern: units,
                elements: { $0.utf16 },
                sources: sources,
                termIndex: termIndex,
                cancellationCheck: cancellationCheck
            )
        case .characters(let characters):
            return try fuzzyWitness(
                pattern: characters,
                elements: { $0 },
                sources: sources,
                termIndex: termIndex,
                cancellationCheck: cancellationCheck
            )
        }
    }

    /// Feeds each original character's lowercased elements to the greedy match, so every match
    /// maps back to the character it came from. When greedy completes with a gap, an
    /// `OccurrenceScan` takes over from `m - 1` elements before its last match.
    private static func fuzzyWitness<Elements: Sequence>(
        pattern: [Elements.Element],
        elements: (String) -> Elements,
        sources: [EvidenceSource],
        termIndex: Int,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> [RawMatch]? where Elements.Element: Equatable {
        guard !pattern.isEmpty else { return nil }
        var matched = 0
        var matches: [RawMatch] = []
        var position = 0
        var first = 0
        var scan: OccurrenceScan<Elements.Element>?
        var utf16Lengths: [Int] = []

        for (sourceIndex, evidenceSource) in sources.enumerated() {
            if sourceIndex > 0 {
                for element in elements("\n") {
                    if scan != nil {
                        if let outcome = scan?.consume(element, of: nil) { return outcome.matches ?? matches }
                    } else if element == pattern[matched] {
                        if matched == 0 { first = position }
                        matched += 1
                        // Fuzzy terms are trimmed, so greedy never completes on the separator.
                        if matched == pattern.count { return matches }
                    }
                    position += 1
                }
            }
            var utf16Location = 0
            var utf8Offset = 0
            for (characterIndex, character) in evidenceSource.text.enumerated() {
                if characterIndex % Constants.cancellationPollInterval == 0 {
                    try cancellationCheck()
                }
                let characterString = String(character)
                let characterLength = characterString.utf16.count
                let lowered = characterString.lowercased()
                var rawMatch: RawMatch {
                    RawMatch(
                        source: evidenceSource.source,
                        range: NSRange(location: utf16Location, length: characterLength),
                        termIndex: termIndex
                    )
                }
                for (elementIndex, element) in elements(lowered).enumerated() {
                    if scan != nil {
                        if let outcome = scan?.consume(element, of: rawMatch) { return outcome.matches ?? matches }
                        continue
                    }
                    defer { position += 1 }
                    guard element == pattern[matched] else { continue }
                    if matches.last != rawMatch {
                        matches.append(rawMatch)
                    }
                    if matched == 0 { first = position }
                    matched += 1
                    guard matched == pattern.count else { continue }
                    let start = position - (pattern.count - 1)
                    guard start > first else { return matches }
                    var occurrenceScan = OccurrenceScan(
                        pattern: pattern,
                        start: start,
                        bound: 2 * position - first - 2 * (pattern.count - 1)
                    )
                    let earlier = elementsBefore(
                        elementIndex,
                        of: lowered,
                        character: rawMatch,
                        utf8Offset: utf8Offset,
                        count: pattern.count - 1,
                        sourceIndex: sourceIndex,
                        sources: sources,
                        utf16Lengths: utf16Lengths,
                        elements: elements
                    )
                    for (earlierElement, earlierCharacter) in earlier + [(element, rawMatch)] {
                        if let outcome = occurrenceScan.consume(earlierElement, of: earlierCharacter) {
                            return outcome.matches ?? matches
                        }
                    }
                    scan = occurrenceScan
                }
                utf16Location += characterLength
                utf8Offset += characterString.utf8.count
            }
            utf16Lengths.append(utf16Location)
        }
        return scan == nil ? nil : matches
    }

    /// The `count` lowercased elements before element `elementIndex` of `lowered`, the character
    /// `character` at `utf8Offset` in `sources[sourceIndex]`, oldest first, each with the character
    /// it belongs to (nil for the separator). `utf16Lengths` holds every earlier source's length.
    private static func elementsBefore<Elements: Sequence>(
        _ elementIndex: Int,
        of lowered: String,
        character: RawMatch,
        utf8Offset: Int,
        count: Int,
        sourceIndex: Int,
        sources: [EvidenceSource],
        utf16Lengths: [Int],
        elements: (String) -> Elements
    ) -> [(element: Elements.Element, character: RawMatch?)] {
        var collected: [(element: Elements.Element, character: RawMatch?)] = elements(lowered)
            .prefix(elementIndex)
            .map { (element: $0, character: character) }
        var sourceIndex = sourceIndex
        var text = sources[sourceIndex].text
        var index = text.utf8.index(text.utf8.startIndex, offsetBy: utf8Offset)
        var location = character.range.location
        while collected.count < count {
            if index > text.startIndex {
                text.formIndex(before: &index)
                let characterString = String(text[index])
                let length = characterString.utf16.count
                location -= length
                let earlier = RawMatch(
                    source: sources[sourceIndex].source,
                    range: NSRange(location: location, length: length),
                    termIndex: character.termIndex
                )
                collected.insert(
                    contentsOf: elements(characterString.lowercased()).map { (element: $0, character: earlier) },
                    at: 0
                )
            } else if sourceIndex > 0 {
                collected.insert(contentsOf: elements("\n").map { (element: $0, character: RawMatch?.none) }, at: 0)
                sourceIndex -= 1
                text = sources[sourceIndex].text
                index = text.endIndex
                location = utf16Lengths[sourceIndex]
            } else {
                break
            }
        }
        return Array(collected.suffix(count))
    }

    /// KMP over element positions from `start` for the first whole occurrence of the pattern that
    /// starts before `bound`, remembering the character of each of the last `m` elements.
    private struct OccurrenceScan<Element: Equatable> {
        enum Outcome {
            case occurrence([RawMatch])
            case notBeforeBound

            /// The occurrence's characters; nil when the greedy match stands.
            var matches: [RawMatch]? {
                if case .occurrence(let characters) = self { return characters }
                return nil
            }
        }

        private let pattern: [Element]
        private let failure: [Int]
        private let bound: Int
        private var position: Int
        private var matched = 0
        private var characters: [RawMatch?]

        init(pattern: [Element], start: Int, bound: Int) {
            self.pattern = pattern
            failure = FuzzySubsequence.failureLinks(pattern)
            self.bound = bound
            position = start
            characters = Array(repeating: nil, count: pattern.count)
        }

        /// Scans the element at the next position; nil until the outcome is known.
        mutating func consume(_ element: Element, of character: RawMatch?) -> Outcome? {
            guard position - matched < bound else { return .notBeforeBound }
            while matched > 0, element != pattern[matched] {
                matched = failure[matched - 1]
            }
            if element == pattern[matched] {
                matched += 1
            }
            characters[position % pattern.count] = character
            position += 1
            guard matched == pattern.count else { return nil }
            var occurrence: [RawMatch] = []
            for scanned in (position - pattern.count)..<position {
                if let character = characters[scanned % pattern.count], occurrence.last != character {
                    occurrence.append(character)
                }
            }
            return .occurrence(occurrence)
        }
    }

    private static func ftsEvidencePhrases(
        _ query: String,
        tokenizer: Unicode61Tokenizer,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> [[PhraseTerm]] {
        let normalized = query
            .replacingOccurrences(of: "*", with: "")
            .replacingOccurrences(of: "-", with: " ")

        var seen: Set<[String]> = []
        var phrases: [[PhraseTerm]] = []
        for part in normalized.split(whereSeparator: \.isWhitespace) {
            try cancellationCheck()
            let tokenized = try tokenizer.tokens(
                in: String(part),
                flags: FTS5_TOKENIZE_QUERY,
                cancellationCheck: cancellationCheck
            )
            let phrase = tokenized.tokens.map(tokenized.foldedText)
            guard !phrase.isEmpty, seen.insert(phrase).inserted else { continue }
            phrases.append(phrase.map(PhraseTerm.init))
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
        sources: [EvidenceSource],
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
        phrases: [[PhraseTerm]],
        sources: [EvidenceSource],
        tokenizer: Unicode61Tokenizer,
        cancellationCheck: @escaping () throws -> Void
    ) throws -> MatchSet {
        guard !phrases.isEmpty else { return MatchSet() }
        var tokenizedSources: [(source: SearchMatchSource, tokens: UnicodeTokens)] = []
        tokenizedSources.reserveCapacity(sources.count)
        for evidenceSource in sources {
            try cancellationCheck()
            tokenizedSources.append(
                (
                    source: evidenceSource.source,
                    tokens: try tokenizer.tokens(
                        in: evidenceSource.text,
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
                let tokens = source.tokens.tokens
                guard tokens.count >= phrase.count else { continue }

                for start in 0...(tokens.count - phrase.count) {
                    if start % Constants.cancellationPollInterval == 0 {
                        try cancellationCheck()
                    }
                    var matchesPhrase = true
                    for offset in phrase.indices where
                        !source.tokens.token(at: start + offset, equals: phrase[offset]) {
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
                                range: tokens[start + offset].range,
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
    ) -> [EvidenceSource] {
        var sources = [EvidenceSource(source: .content, text: plainText)]
        if let note, !note.isEmpty {
            sources.append(EvidenceSource(source: .note, text: note))
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
            return SearchMatchFragment(source: source, text: "", highlightedRanges: [])
        }

        guard !sourceText.isEmpty,
              let firstRange = characterRange(firstMatch.range, in: sourceText) else { return nil }

        let lastMatch = matches.last ?? firstMatch
        let unionNSRange = NSRange(
            location: firstMatch.range.location,
            length: max(0, NSMaxRange(lastMatch.range) - firstMatch.range.location)
        )
        let unionRange = characterRange(unionNSRange, in: sourceText)
        let targetRange: Range<String.Index>
        if let unionRange,
           sourceText.distance(from: unionRange.lowerBound, to: unionRange.upperBound)
            <= characterBudget - leadingContextCharacters {
            targetRange = unionRange
        } else {
            targetRange = firstRange
        }

        // Walks back from the match, never from the start of a possibly multi-megabyte text.
        let sliceStart = sourceText.index(
            targetRange.lowerBound,
            offsetBy: -leadingContextCharacters,
            limitedBy: sourceText.startIndex
        ) ?? sourceText.startIndex
        let leadingCount = sourceText.distance(from: sliceStart, to: targetRange.lowerBound)
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

        // targetRange starts at firstMatch.range.location in UTF-16.
        let leadingUTF16 = sourceText[sliceStart..<targetRange.lowerBound].unicodeScalars
            .reduce(0) { $0 + UTF16.width($1) }
        let fragment = normalizedFragment(
            source: source,
            sourceText: sourceText,
            slice: sliceStart..<sliceEnd,
            sliceUTF16Offset: firstMatch.range.location - leadingUTF16,
            matches: matches,
            hasLeadingOmission: sliceStart != sourceText.startIndex,
            hasTrailingOmission: sliceEnd != sourceText.endIndex
        )
        if fragment.text.isEmpty {
            // Whitespace-only content: the presentation shows a placeholder for an empty fragment.
            return SearchMatchFragment(source: source, text: "", highlightedRanges: [])
        }
        return fragment
    }

    /// UTF-16 units of the scalars whose lead bytes lie in `bytes[start..<end]`.
    static func utf16Count(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, to end: Int) -> Int {
        var count = 0
        for index in start..<end {
            let byte = bytes[index]
            count &+= (byte & 0xC0 != 0x80 ? 1 : 0) &+ (byte >= 0xF0 ? 1 : 0)
        }
        return count
    }

    /// `Range(range, in: text)`. Bounds on Character boundaries come from one UTF-8 scan up to
    /// the range's end, so a match in a large non-ASCII text does not make the String build
    /// UTF-16 breadcrumbs for all of it. Other bounds, whose handling varies by OS release, go
    /// to Foundation.
    private static func characterRange(_ range: NSRange, in text: String) -> Range<String.Index>? {
        guard range.location != NSNotFound else { return nil }
        let lowerUTF16 = range.location
        let upperUTF16 = NSMaxRange(range)
        let byteBounds = text.utf8.withContiguousStorageIfAvailable { bytes -> (Int, Int)? in
            var units = 0
            var index = 0
            // The UTF-8 offset at `target` UTF-16 units; nil inside a surrogate pair or past the end.
            func advance(toUTF16 target: Int) -> Int? {
                while index + 64 <= bytes.count {
                    let blockUnits = utf16Count(bytes, from: index, to: index + 64)
                    guard units + blockUnits < target else { break }
                    units += blockUnits
                    index += 64
                }
                while index < bytes.count, bytes[index] & 0xC0 == 0x80 {
                    index += 1
                }
                while units < target, index < bytes.count {
                    let lead = bytes[index]
                    units += lead >= 0xF0 ? 2 : 1
                    index += lead < 0x80 ? 1 : lead < 0xE0 ? 2 : lead < 0xF0 ? 3 : 4
                }
                return units == target ? index : nil
            }
            guard let lower = advance(toUTF16: lowerUTF16),
                  let upper = advance(toUTF16: upperUTF16) else { return nil }
            return (lower, upper)
        }
        let utf8 = text.utf8
        if let (lower, upper) = byteBounds ?? nil,
           let lowerBound = String.Index(utf8.index(utf8.startIndex, offsetBy: lower), within: text),
           let upperBound = String.Index(utf8.index(utf8.startIndex, offsetBy: upper), within: text) {
            return lowerBound..<upperBound
        }
        return Range(range, in: text)
    }

    private static func normalizedFragment(
        source: SearchMatchSource,
        sourceText: String,
        slice: Range<String.Index>,
        sliceUTF16Offset: Int,
        matches: [RawMatch],
        hasLeadingOmission: Bool,
        hasTrailingOmission: Bool
    ) -> SearchMatchFragment {
        var output = hasLeadingOmission ? "…" : ""
        var outputCharacterCount = hasLeadingOmission ? 1 : 0
        var highlightedRanges: [SearchMatchTextRange] = []
        var activeHighlightStart: Int?
        var previousWasWhitespace = false
        var utf16Location = sliceUTF16Offset

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

extension SearchMatchContextBuilder {
    /// `result` with renderable match evidence per item. An item whose evidence cannot be built
    /// keeps its place without evidence; only cancellation aborts.
    static func attach(
        to result: SearchEngineImpl.SearchResult,
        request: SearchRequest
    ) throws -> SearchEngineImpl.SearchResult {
        guard request.hasSemanticQuery, !result.items.isEmpty else { return result }

        let matcher = try prepare(
            request: request,
            coverage: result.coverage,
            cancellationCheck: { try Task.checkCancellation() }
        )
        var contexts: [UUID: SearchMatchContext] = [:]
        contexts.reserveCapacity(result.items.count)

        for item in result.items {
            try Task.checkCancellation()
            do {
                if let context = try matcher.makeContext(
                    plainText: item.plainText,
                    note: item.note,
                    cancellationCheck: { try Task.checkCancellation() }
                ) {
                    contexts[item.id] = context
                }
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                continue
            }
        }

        return SearchEngineImpl.SearchResult(
            items: result.items,
            total: result.total,
            hasMore: result.hasMore,
            coverage: result.coverage,
            searchTimeMs: result.searchTimeMs,
            perf: result.perf,
            matchContexts: contexts
        )
    }
}
