import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Bounded Open Graph fetcher. This is the only networking in the link-enrichment path;
/// the renderer itself never fetches. Every request is cookie-less, size-capped, and
/// restricted to public HTTP(S) hosts; imagery is downscaled into data URIs that fit the
/// strict v2 data-image limits.
struct LinkEnrichmentFetcher: Sendable {
    static let maximumHTMLBytes = 512 * 1_024
    static let maximumImageBytes = 8 * 1_024 * 1_024
    static let maximumThumbnailPixel = 576
    static let maximumFaviconPixel = 64
    static let maximumEncodedThumbnailBytes = 192 * 1_024
    static let maximumEncodedFaviconBytes = 32 * 1_024
    static let totalDecodedImageBudget = 480 * 1_024

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 6
        configuration.timeoutIntervalForResource = 12
        configuration.httpAdditionalHeaders = [
            "User-Agent": "Scopy/LinkPreview (+https://github.com/Suehn/Scopy)"
        ]
        session = URLSession(configuration: configuration)
    }

    func enrich(urls: [String]) async -> [String: LinkEnrichmentEntry] {
        var entries: [String: LinkEnrichmentEntry] = [:]
        var decodedBudget = Self.totalDecodedImageBudget
        await withTaskGroup(of: (String, PageMetadata?).self) { group in
            var active = 0
            var iterator = urls.makeIterator()
            @discardableResult
            func startNext() -> Bool {
                guard let url = iterator.next() else { return false }
                active += 1
                group.addTask { (url, await fetchMetadata(urlString: url)) }
                return true
            }
            while active < 3 && startNext() {}
            for await (url, metadata) in group {
                active -= 1
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
        guard let url = safePublicURL(urlString) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode)
        else { return nil }
        let head = String(decoding: data.prefix(Self.maximumHTMLBytes), as: UTF8.self)

        func meta(_ names: [String]) -> String? {
            for name in names {
                if let value = metaContent(in: head, name: name) { return value }
            }
            return nil
        }
        guard let rawTitle = meta(["og:title", "twitter:title"]) ?? htmlTitle(in: head) else { return nil }
        let title = decodeEntities(rawTitle).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }

        let base = http.url ?? url
        var metadata = PageMetadata(title: String(title.prefix(300)))
        metadata.siteName = meta(["og:site_name"]).map { String(decodeEntities($0).prefix(80)) } ?? base.host
        metadata.description = meta(["og:description", "twitter:description", "description"])
            .map { String(decodeEntities($0).prefix(280)) }
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

    private func decodeEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&#x27;", with: "'")
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
        guard let url = safePublicURL(urlString) else { return nil }
        guard let (data, response) = try? await session.data(from: url),
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

    /// http(s) only, no credentials, and no loopback/private/link-local literal hosts.
    private func safePublicURL(_ urlString: String) -> URL? {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil, url.password == nil,
              let host = url.host?.lowercased(), !host.isEmpty
        else { return nil }
        if host == "localhost" || host.hasSuffix(".local") { return nil }
        if isPrivateLiteralAddress(host) { return nil }
        return url
    }

    private func isPrivateLiteralAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let address = UInt32(bigEndian: v4.s_addr)
            let octet1 = (address >> 24) & 0xff
            let octet2 = (address >> 16) & 0xff
            if octet1 == 10 || octet1 == 127 || octet1 == 0 { return true }
            if octet1 == 172 && (16...31).contains(octet2) { return true }
            if octet1 == 192 && octet2 == 168 { return true }
            if octet1 == 169 && octet2 == 254 { return true }
            return false
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return true
        }
        return false
    }
}
