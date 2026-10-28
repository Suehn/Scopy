import Darwin
import Foundation

/// Bytes prepared for storage, together with the durable capture that can replay them.
/// Work files follow the value's shared lifetime; only the spool acknowledges source files.
public struct CapturedPayload: Sendable {
    public struct IngestReference: Sendable {
        public let id: UUID
        let directory: URL

        public var envelopeURL: URL {
            directory.appendingPathComponent("\(id.uuidString)\(IngestSpool.pendingEnvelopeSuffix)")
        }

        var payloadURL: URL {
            directory.appendingPathComponent("\(id.uuidString).payload")
        }

        init(id: UUID, directory: URL) {
            self.id = id
            self.directory = directory
        }
    }

    public enum Storage: Sendable {
        case none
        case data(Data)
        case file(File)
    }

    public struct File: Sendable {
        fileprivate enum Location: Sendable {
            case source(IngestReference)
            case work(WorkFile)
        }

        fileprivate let location: Location

        public var url: URL {
            switch location {
            case .source(let ingest): ingest.payloadURL
            case .work(let file): file.url
            }
        }

        func validate() throws {
            switch location {
            case .source(let ingest):
                try IngestSpool.validatePendingSource(ingest)
            case .work(let file):
                try IngestSpool.validatePreparedFile(file.url, in: file.url.deletingLastPathComponent())
            }
        }

        /// Called off the main actor while storage holds the destination reservation.
        /// A source remains replayable; moving a work file never transfers the source.
        func copyOrMove(to destinationPath: String) throws {
            try validate()
            switch location {
            case .source:
                try StorageService.copyFileRetainingSource(from: url, to: destinationPath)
            case .work:
                try StorageService.moveOrCopyFile(from: url, to: destinationPath)
            }
        }
    }

    fileprivate final class WorkFile: Sendable {
        let url: URL

        init(directory: URL, fileExtension: String) {
            url = directory.appendingPathComponent(
                "\(IngestSpool.transientWorkPrefix)\(UUID().uuidString).\(fileExtension)"
            )
        }

        deinit {
            // A single unlink cannot recurse into a directory substituted for our file. The
            // temporary sibling may remain if the atomic write failed before its rename.
            _ = url.path.withCString { Darwin.unlink($0) }
            _ = (url.path + ".tmp").withCString { Darwin.unlink($0) }
        }
    }

    private enum Backing: Sendable {
        case direct(Data?)
        case durable(IngestReference, Storage)
    }

    private let backing: Backing

    public static var none: Self { Self(backing: .direct(nil)) }

    public static func data(_ data: Data) -> Self {
        Self(backing: .direct(data))
    }

    public var storage: Storage {
        switch backing {
        case .direct(let data): data.map(Storage.data) ?? .none
        case .durable(_, let storage): storage
        }
    }

    public var ingest: IngestReference? {
        guard case .durable(let ingest, _) = backing else { return nil }
        return ingest
    }

    /// The envelope and its original bytes have already passed the spool's ownership checks.
    static func original(
        _ data: Data?,
        envelope: IngestSpool.Envelope,
        ingestDirectory: URL
    ) -> Self {
        let ingest = IngestReference(id: envelope.id, directory: ingestDirectory)
        let storage: Storage
        if let data {
            storage = envelope.sizeBytes >= ScopyThresholds.ingestSpoolBytes
                ? .file(File(location: .source(ingest)))
                : .data(data)
        } else {
            storage = .none
        }
        return Self(backing: .durable(ingest, storage))
    }

    /// Retains replay identity when normalization or compression changes the prepared bytes.
    func replacingData(_ data: Data, type: ClipboardItemType) -> Self {
        guard let ingest else { return .data(data) }
        guard data.count >= ScopyThresholds.ingestSpoolBytes else {
            return Self(backing: .durable(ingest, .data(data)))
        }

        let fileExtension: String
        switch type {
        case .image: fileExtension = ImageFileExtension.sniff(data)
        case .rtf: fileExtension = "rtf"
        case .html: fileExtension = "html"
        default: fileExtension = "dat"
        }
        let work = WorkFile(directory: ingest.directory, fileExtension: fileExtension)
        do {
            try StorageService.writeAtomically(data, to: work.url.path)
            return Self(backing: .durable(ingest, .file(File(location: .work(work)))))
        } catch {
            ScopyLog.monitor.warning("Failed to spool ingest payload: \(error.localizedDescription, privacy: .private)")
            return Self(backing: .durable(ingest, .data(data)))
        }
    }

    /// Publishes a transform only after its new bytes can be read. Both the source and output
    /// stay owned until the transform returns, including cancellation and failed preparation.
    func transformingFile(
        _ transform: @Sendable (_ inputURL: URL, _ outputURL: URL) async throws -> Bool
    ) async throws -> (payload: Self, data: Data)? {
        guard case .durable(let ingest, .file(let file)) = backing else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        defer { withExtendedLifetime(file) {} }
        try file.validate()
        let work = WorkFile(directory: ingest.directory, fileExtension: "png")
        guard try await transform(file.url, work.url) else { return nil }
        try IngestSpool.validatePreparedFile(work.url, in: ingest.directory)
        let data = try Data(contentsOf: work.url, options: [.mappedIfSafe])
        let payload = Self(backing: .durable(ingest, .file(File(location: .work(work)))))
        return (payload, data)
    }
}
