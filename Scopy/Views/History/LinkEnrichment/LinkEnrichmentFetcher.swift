import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bounded Open Graph fetcher. This is the only networking in the link-enrichment path;
/// the renderer itself never fetches. Every request is cookie-less, size-capped, and
/// checked against current public HTTP(S) DNS answers; imagery is downscaled into data
/// URIs that fit the strict v2 data-image limits.
struct LinkEnrichmentFetcher: Sendable {
    static let maximumHTMLBytes = 512 * 1_024
    static let maximumImageBytes = 8 * 1_024 * 1_024
    static let maximumThumbnailPixel = 576
    static let maximumFaviconPixel = 64
    static let maximumEncodedThumbnailBytes = 192 * 1_024
    static let maximumEncodedFaviconBytes = 32 * 1_024
    static let totalDecodedImageBudget = 480 * 1_024

    typealias HostResolver = @Sendable (String) -> [String]?

    private let sessionBox: LinkEnrichmentSessionBox
    private let hostResolver: HostResolver

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Scopy/LinkPreview (+https://github.com/Suehn/Scopy)"
        ]
        self.init(configuration: configuration) { host in
            Self.resolveHostAddresses(host)
        }
    }

    init(configuration: URLSessionConfiguration, hostResolver: @escaping HostResolver) {
        self.hostResolver = hostResolver
        let delegate = LinkEnrichmentSessionDelegate { url in
            Self.isPublicURL(url, hostResolver: hostResolver)
        }
        self.sessionBox = LinkEnrichmentSessionBox(configuration: configuration, delegate: delegate)
    }

    func enrich(urls: [String]) async -> [String: LinkEnrichmentEntry] {
        var entries: [String: LinkEnrichmentEntry] = [:]
        var decodedBudget = Self.totalDecodedImageBudget
        await withTaskGroup(of: (String, PageMetadata?).self) { group in
            var active = 0
            var iterator = urls.makeIterator()
            @discardableResult
            func startNext() -> Bool {
                guard !Task.isCancelled, let url = iterator.next() else { return false }
                active += 1
                group.addTask { (url, await fetchMetadata(urlString: url)) }
                return true
            }
            while active < 3 && startNext() {}
            for await (url, metadata) in group {
                active -= 1
                guard !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                startNext()
                guard let metadata else { continue }
                var entry = LinkEnrichmentEntry(title: metadata.title)
                entry.source = metadata.siteName
                entry.date = metadata.publishedDate
                entry.snippet = metadata.description
                if let imageURL = metadata.imageURL,
                   let encoded = await fetchDataImage(
                       urlString: imageURL,
                       maxPixel: Self.maximumThumbnailPixel,
                       encodedCap: Self.maximumEncodedThumbnailBytes,
                       type: .jpeg
                   ), encoded.decodedBytes <= decodedBudget {
                    decodedBudget -= encoded.decodedBytes
                    entry.image = encoded.dataURI
                }
                if let faviconURL = metadata.faviconURL,
                   let encoded = await fetchDataImage(
                       urlString: faviconURL,
                       maxPixel: Self.maximumFaviconPixel,
                       encodedCap: Self.maximumEncodedFaviconBytes,
                       type: .png
                   ), encoded.decodedBytes <= decodedBudget {
                    decodedBudget -= encoded.decodedBytes
                    entry.favicon = encoded.dataURI
                }
                entries[url] = entry
            }
        }
        return entries
    }

    func isSafePublicURL(_ urlString: String) -> Bool {
        validatedPublicURL(urlString) != nil
    }

    func isSafeRedirectURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString) else { return false }
        return sessionBox.delegate.allowedRedirectRequest(URLRequest(url: url)) != nil
    }

    // MARK: - Page metadata

    private struct PageMetadata {
        var title: String
        var siteName: String?
        var description: String?
        var publishedDate: String?
        var imageURL: String?
        var faviconURL: String?
    }

    private func fetchMetadata(urlString: String) async -> PageMetadata? {
        guard let url = validatedPublicURL(urlString) else { return nil }
        guard let (data, response) = try? await sessionBox.delegate.load(
            from: url,
            maximumBytes: Self.maximumHTMLBytes,
            session: sessionBox.session
        ),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        let head = String(decoding: data, as: UTF8.self)

        func meta(_ names: [String]) -> String? {
            for name in names {
                if let value = metaContent(in: head, name: name) { return value }
            }
            return nil
        }
        guard let rawTitle = meta(["og:title", "twitter:title"]) ?? htmlTitle(in: head) else { return nil }
        let title = Self.decodeEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let base = http.url ?? url
        var metadata = PageMetadata(title: String(title.prefix(300)))
        metadata.siteName = meta(["og:site_name"]).map { String(Self.decodeEntities($0).prefix(80)) } ?? base.host
        metadata.description = meta(["og:description", "twitter:description", "description"])
            .map { String(Self.decodeEntities($0).prefix(280)) }
        metadata.publishedDate = meta(["article:published_time", "og:updated_time"])
            .map { String($0.prefix(10)) }
        metadata.imageURL = meta(["og:image", "og:image:url", "twitter:image"])
            .flatMap { resolve($0, against: base) }
        metadata.faviconURL = faviconHref(in: head).flatMap { resolve($0, against: base) }
            ?? resolve("/favicon.ico", against: base)
        return metadata
    }

    private func metaContent(in html: String, name: String) -> String? {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "<meta[^>]+(?:property|name)=[\"']\(escaped)[\"'][^>]*content=[\"']([^\"']+)[\"']",
            "<meta[^>]+content=[\"']([^\"']+)[\"'][^>]*(?:property|name)=[\"']\(escaped)[\"']"
        ]
        for pattern in patterns {
            if let value = firstCapture(pattern, in: html) { return value }
        }
        return nil
    }

    private func htmlTitle(in html: String) -> String? {
        firstCapture("<title[^>]*>([^<]{1,400})</title>", in: html)
    }

    private func faviconHref(in html: String) -> String? {
        firstCapture(
            "<link[^>]+rel=[\"'](?:shortcut )?(?:icon|apple-touch-icon)[\"'][^>]*href=[\"']([^\"']+)[\"']",
            in: html
        ) ?? firstCapture(
            "<link[^>]+href=[\"']([^\"']+)[\"'][^>]*rel=[\"'](?:shortcut )?(?:icon|apple-touch-icon)[\"']",
            in: html
        )
    }

    private func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: text)
        else { return nil }
        return String(text[range])
    }

    /// Decodes the named and numeric HTML entities that commonly appear in Open Graph
    /// titles and descriptions. Internal so tests can pin the behavior without a network.
    static func decodeEntities(_ value: String) -> String {
        var result = value
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&nbsp;", with: "\u{00A0}")
        if result.contains("&#"),
           let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]{1,6}|[0-9]{1,7});"#) {
            let matches = regex.matches(in: result, range: NSRange(result.startIndex..., in: result))
            for match in matches.reversed() {
                guard let whole = Range(match.range, in: result),
                      let bodyRange = Range(match.range(at: 1), in: result) else { continue }
                let body = result[bodyRange]
                let scalarValue = body.hasPrefix("x")
                    ? UInt32(body.dropFirst(), radix: 16)
                    : UInt32(body)
                guard let scalarValue, scalarValue >= 0x20, let scalar = Unicode.Scalar(scalarValue) else { continue }
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")
    }

    private func resolve(_ href: String, against base: URL) -> String? {
        URL(string: href, relativeTo: base)?.absoluteString
    }

    // MARK: - Imagery

    private struct EncodedImage {
        var dataURI: String
        var decodedBytes: Int
    }

    private func fetchDataImage(
        urlString: String,
        maxPixel: Int,
        encodedCap: Int,
        type: UTType
    ) async -> EncodedImage? {
        guard let url = validatedPublicURL(urlString) else { return nil }
        guard let (data, response) = try? await sessionBox.delegate.load(
            from: url,
            maximumBytes: Self.maximumImageBytes,
            session: sessionBox.session
        ),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty,
              data.count <= Self.maximumImageBytes
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceCreateThumbnailWithTransform: true
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        let encoded = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            encoded, type.identifier as CFString, 1, nil
        ) else { return nil }
        let properties: [CFString: Any] = type == .jpeg
            ? [kCGImageDestinationLossyCompressionQuality: 0.75]
            : [:]
        CGImageDestinationAddImage(destination, thumbnail, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }

        let bytes = encoded as Data
        guard bytes.count <= encodedCap else { return nil }
        let mime = type == .jpeg ? "image/jpeg" : "image/png"
        return EncodedImage(
            dataURI: "data:\(mime);base64,\(bytes.base64EncodedString())",
            decodedBytes: bytes.count
        )
    }

    // MARK: - URL safety

    /// http(s) only, no credentials, and every address currently returned for the host
    /// must be globally routable. URLSession still owns the connection-time DNS lookup;
    /// this validation does not pin the resolver result to the socket.
    private func validatedPublicURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              Self.isPublicURL(url, hostResolver: hostResolver)
        else { return nil }
        return url
    }

    private static func isPublicURL(_ url: URL, hostResolver: HostResolver) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty,
              host != "localhost", !host.hasSuffix(".localhost"), !host.hasSuffix(".local")
        else { return false }

        if let numericAddresses = resolveAddresses(host: host, flags: AI_NUMERICHOST) {
            return !numericAddresses.isEmpty && numericAddresses.allSatisfy(isPublicAddress)
        }
        guard let resolvedAddresses = hostResolver(host), !resolvedAddresses.isEmpty else { return false }
        return resolvedAddresses.allSatisfy {
            isPublicAddress($0) || isFakeIPBenchmarkAddress($0)
        }
    }

    /// Local Fake-IP DNS proxies use RFC 2544 benchmark addresses as routing tokens for
    /// named hosts. Literal URLs in this range remain rejected by the numeric-host branch.
    private static func isFakeIPBenchmarkAddress(_ address: String) -> Bool {
        let addressWithoutZone = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v4 = in_addr()
        guard inet_pton(AF_INET, addressWithoutZone, &v4) == 1 else { return false }
        let value = UInt32(bigEndian: v4.s_addr)
        return value & 0xfffe_0000 == 0xc612_0000
    }

    private static func isPublicAddress(_ address: String) -> Bool {
        let addressWithoutZone = address.split(separator: "%", maxSplits: 1).first.map(String.init) ?? address
        var v4 = in_addr()
        if inet_pton(AF_INET, addressWithoutZone, &v4) == 1 {
            return isPublicIPv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, addressWithoutZone, &v6) == 1 {
            return isPublicIPv6(withUnsafeBytes(of: &v6) { Array($0) })
        }
        return false
    }

    private static func isPublicIPv4(_ address: UInt32) -> Bool {
        func belongs(to network: UInt32, prefix: UInt32) -> Bool {
            let mask = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
            return address & mask == network & mask
        }
        return !belongs(to: 0x0000_0000, prefix: 8)
            && !belongs(to: 0x0a00_0000, prefix: 8)
            && !belongs(to: 0x6440_0000, prefix: 10)
            && !belongs(to: 0x7f00_0000, prefix: 8)
            && !belongs(to: 0xa9fe_0000, prefix: 16)
            && !belongs(to: 0xac10_0000, prefix: 12)
            && !belongs(to: 0xc000_0000, prefix: 24)
            && !belongs(to: 0xc000_0200, prefix: 24)
            && !belongs(to: 0xc058_6300, prefix: 24)
            && !belongs(to: 0xc0a8_0000, prefix: 16)
            && !belongs(to: 0xc612_0000, prefix: 15)
            && !belongs(to: 0xc633_6400, prefix: 24)
            && !belongs(to: 0xcb00_7100, prefix: 24)
            && !belongs(to: 0xe000_0000, prefix: 4)
            && !belongs(to: 0xf000_0000, prefix: 4)
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false }
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false }
        if bytes.prefix(10).allSatisfy({ $0 == 0 }), bytes[10] == 0xff, bytes[11] == 0xff {
            let mapped = UInt32(bytes[12]) << 24
                | UInt32(bytes[13]) << 16
                | UInt32(bytes[14]) << 8
                | UInt32(bytes[15])
            return isPublicIPv4(mapped)
        }
        guard bytes[0] & 0xe0 == 0x20 else { return false }
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0d, bytes[3] == 0xb8 { return false }
        return true
    }

    private static func resolveHostAddresses(_ host: String) -> [String]? {
        resolveAddresses(host: host, flags: 0)
    }

    private static func resolveAddresses(host: String, flags: Int32) -> [String]? {
        var hints = addrinfo()
        hints.ai_flags = flags
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else { return nil }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var current: UnsafeMutablePointer<addrinfo>? = first
        while let info = current?.pointee {
            if let socketAddress = info.ai_addr {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(
                    socketAddress,
                    info.ai_addrlen,
                    &buffer,
                    socklen_t(buffer.count),
                    nil,
                    0,
                    NI_NUMERICHOST
                ) == 0 {
                    let address = String(cString: buffer)
                    if !addresses.contains(address) { addresses.append(address) }
                }
            }
            current = info.ai_next
        }
        return addresses
    }
}

private final class LinkEnrichmentSessionBox: @unchecked Sendable {
    let delegate: LinkEnrichmentSessionDelegate
    let session: URLSession

    init(configuration: URLSessionConfiguration, delegate: LinkEnrichmentSessionDelegate) {
        self.delegate = delegate
        self.session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }
}

private final class LinkEnrichmentSessionDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Int: LinkEnrichmentBoundedRequest] = [:]
    private let isAllowedRedirect: @Sendable (URL) -> Bool

    init(isAllowedRedirect: @escaping @Sendable (URL) -> Bool) {
        self.isAllowedRedirect = isAllowedRedirect
    }

    func load(from url: URL, maximumBytes: Int, session: URLSession) async throws -> (Data, URLResponse) {
        let request = LinkEnrichmentBoundedRequest(maximumBytes: maximumBytes)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let task = session.dataTask(with: url)
                lock.withLock {
                    requests[task.taskIdentifier] = request
                }
                request.start(task: task, continuation: continuation)
                task.resume()
            }
        }, onCancel: {
            request.cancel()
        })
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(allowedRedirectRequest(request))
    }

    func allowedRedirectRequest(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, isAllowedRedirect(url) else { return nil }
        return request
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let request = request(for: dataTask.taskIdentifier), request.receive(response: response) else {
            completionHandler(.cancel)
            dataTask.cancel()
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let request = request(for: dataTask.taskIdentifier), request.receive(data: data) else {
            dataTask.cancel()
            return
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let request = lock.withLock { requests.removeValue(forKey: task.taskIdentifier) }
        request?.complete(error: error)
    }

    private func request(for taskIdentifier: Int) -> LinkEnrichmentBoundedRequest? {
        lock.withLock { requests[taskIdentifier] }
    }
}

private final class LinkEnrichmentBoundedRequest: @unchecked Sendable {
    private enum Failure: Error {
        case responseTooLarge
        case missingResponse
    }

    private let lock = NSLock()
    private let maximumBytes: Int
    private var task: URLSessionTask?
    private var continuation: CheckedContinuation<(Data, URLResponse), Error>?
    private var response: URLResponse?
    private var data = Data()
    private var isCancelled = false
    private var isComplete = false
    private var pendingResult: Result<(Data, URLResponse), Error>?

    init(maximumBytes: Int) {
        self.maximumBytes = maximumBytes
    }

    func start(
        task: URLSessionTask,
        continuation: CheckedContinuation<(Data, URLResponse), Error>
    ) {
        let pendingResult: Result<(Data, URLResponse), Error>? = lock.withLock {
            self.task = task
            if let pendingResult = self.pendingResult {
                self.pendingResult = nil
                return pendingResult
            }
            self.continuation = continuation
            return nil
        }
        if let pendingResult {
            task.cancel()
            continuation.resume(with: pendingResult)
        }
    }

    func cancel() {
        let task = lock.withLock {
            isCancelled = true
            return self.task
        }
        task?.cancel()
        finish(.failure(CancellationError()))
    }

    func receive(response: URLResponse) -> Bool {
        let exceedsDeclaredSize = response.expectedContentLength > Int64(maximumBytes)
        if exceedsDeclaredSize {
            finish(.failure(Failure.responseTooLarge))
            return false
        }
        return lock.withLock {
            guard !isComplete else { return false }
            self.response = response
            return true
        }
    }

    func receive(data newData: Data) -> Bool {
        let result: Result<(Data, URLResponse), Error>? = lock.withLock {
            guard !isComplete else { return .failure(CancellationError()) }
            guard newData.count <= maximumBytes - data.count else {
                isComplete = true
                return .failure(Failure.responseTooLarge)
            }
            data.append(newData)
            return nil
        }
        guard let result else { return true }
        resume(result)
        return false
    }

    func complete(error: Error?) {
        let result: Result<(Data, URLResponse), Error>? = lock.withLock {
            guard !isComplete else { return nil }
            isComplete = true
            if isCancelled { return .failure(CancellationError()) }
            if let error { return .failure(error) }
            guard let response else { return .failure(Failure.missingResponse) }
            return .success((data, response))
        }
        if let result { resume(result) }
    }

    private func finish(_ result: Result<(Data, URLResponse), Error>) {
        let continuation: CheckedContinuation<(Data, URLResponse), Error>? = lock.withLock {
            guard !isComplete else { return nil }
            isComplete = true
            guard let continuation = self.continuation else {
                pendingResult = result
                return nil
            }
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }

    private func resume(_ result: Result<(Data, URLResponse), Error>) {
        let continuation = lock.withLock {
            let continuation = self.continuation
            self.continuation = nil
            return continuation
        }
        continuation?.resume(with: result)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
