import Foundation

enum TestFixture {
    enum Error: Swift.Error, CustomStringConvertible {
        case missing(String, bundlePath: String)

        var description: String {
            switch self {
            case let .missing(relativePath, bundlePath):
                return "Missing test fixture '\(relativePath)' in \(bundlePath)"
            }
        }
    }

    static func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: url(relativePath), options: [.mappedIfSafe])
    }

    static func url(_ relativePath: String) throws -> URL {
        let bundle = Bundle(for: BundleToken.self)
        let path = relativePath as NSString
        let filename = path.lastPathComponent as NSString
        let pathExtension = filename.pathExtension
        let resourceName = filename.deletingPathExtension
        let subdirectory = path.deletingLastPathComponent
        let normalizedSubdirectory = subdirectory == "." || subdirectory.isEmpty
            ? nil
            : subdirectory

        // Xcode may preserve a resource subdirectory or flatten its files depending on how the
        // project is generated. Support both layouts while keeping all reads inside DerivedData;
        // reading fixtures through #filePath can block XCTest on macOS Documents TCC/file
        // coordination before the test body starts.
        let candidates = [
            bundle.url(
                forResource: resourceName,
                withExtension: pathExtension.isEmpty ? nil : pathExtension,
                subdirectory: normalizedSubdirectory
            ),
            bundle.url(
                forResource: resourceName,
                withExtension: pathExtension.isEmpty ? nil : pathExtension
            )
        ]

        guard let resolved = candidates.compactMap({ $0 }).first else {
            throw Error.missing(relativePath, bundlePath: bundle.bundlePath)
        }
        return resolved
    }

    private final class BundleToken {}
}
