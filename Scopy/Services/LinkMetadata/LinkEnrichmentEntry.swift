import Foundation

/// One frozen Open Graph snapshot for a link in an assistant copy. Imagery is stored as
/// bounded data URIs so the rendered envelope stays self-contained and passes the same
/// strict v2 data-image limits as every other rich surface.
public struct LinkEnrichmentEntry: Codable, Equatable, Sendable {
    public var title: String
    public var source: String?
    public var date: String?
    public var snippet: String?
    public var image: String?
    public var favicon: String?
    public init(title: String, source: String? = nil, date: String? = nil, snippet: String? = nil,
                image: String? = nil, favicon: String? = nil) {
        self.title = title
        self.source = source
        self.date = date
        self.snippet = snippet
        self.image = image
        self.favicon = favicon
    }
}

