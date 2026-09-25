import Foundation

/// The Application Support ingest spool: envelope format, durable writes, ownership
/// validation, terminal markers, quarantine, stale-artifact sweeps and the legacy Caches
/// migration. Every function takes the spool directory explicitly and touches nothing else.
enum IngestSpool {
    /// On-disk description of one externally backed capture; the same document is read back
    /// from the pending envelope and from its terminal marker.
    struct Envelope: Codable, Sendable {
        let id: UUID
        let typeRawValue: String
        let plainText: String
        let appBundleID: String?
        let sizeBytes: Int
        let precomputedHash: String?
        let imageDataWasTIFF: Bool
        let payloadFileName: String?

        var type: ClipboardItemType {
            ClipboardItemType(rawValue: typeRawValue) ?? .other
        }
    }

    private static let terminalEnvelopeSuffix = ".envelope.acked"

    static let pendingEnvelopeSuffix = ".envelope.json"

    static let transientWorkPrefix = ".ingest-work-"

    private static let corruptEnvelopeSuffix = ".quarantine"

    private static let staleControlledArtifactAge: TimeInterval = 24 * 60 * 60

    private static let maxControlledArtifactsPerSweep = 256

    static func persistPendingEnvelope(
        for rawData: ClipboardMonitor.RawClipboardData,
        in ingestDirectory: URL
    ) throws -> URL {
        let id = UUID()
        let payloadFileName = rawData.rawData.map { _ in "\(id.uuidString).payload" }
        var payloadURL: URL?
        var envelopeCommitted = false
        defer {
            if !envelopeCommitted, let payloadURL {
                try? FileManager.default.removeItem(at: payloadURL)
            }
        }
        if let payloadData = rawData.rawData, let payloadFileName {
            let url = ingestDirectory.appendingPathComponent(payloadFileName)
            payloadURL = url
            try StorageService.writeAtomically(payloadData, to: url.path)
        }

        let envelope = Envelope(
            id: id,
            typeRawValue: rawData.type.rawValue,
            plainText: rawData.plainText,
            appBundleID: rawData.appBundleID,
            sizeBytes: rawData.sizeBytes,
            precomputedHash: rawData.precomputedHash,
            imageDataWasTIFF: rawData.imageDataWasTIFF,
            payloadFileName: payloadFileName
        )

        let envelopeURL = ingestDirectory.appendingPathComponent("\(id.uuidString).envelope.json")
        try Self.writePendingEnvelope(envelope, to: envelopeURL)
        envelopeCommitted = true
        return envelopeURL
    }

    private static func writePendingEnvelope(_ envelope: Envelope, to url: URL) throws {
        let data = try JSONEncoder().encode(envelope)
        try StorageService.writeAtomically(data, to: url.path)
    }

    private static func loadPendingEnvelope(from url: URL) -> Envelope? {
        guard let data = BestEffortFileOps.loadData(
            from: url,
            logger: ScopyLog.monitor,
            operation: "loadPendingEnvelope.read"
        ) else {
            return nil
        }
        return BestEffortFileOps.decodeJSON(
            Envelope.self,
            from: data,
            logger: ScopyLog.monitor,
            operation: "loadPendingEnvelope.decode",
            path: url.path
        )
    }

    /// Pending envelopes in capture order. Envelopes are written to a temporary file and renamed,
    /// so creation date approximates capture time; the file name breaks ties deterministically.
    static func discoverPendingEnvelopeURLs(in directory: URL) -> [URL] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        func creationDate(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
        }
        let envelopes: [(url: URL, created: Date)] = urls
            .filter { $0.lastPathComponent.hasSuffix(".envelope.json") }
            .map { ($0, creationDate($0)) }
        return envelopes
            .sorted { lhs, rhs in
                if lhs.created != rhs.created { return lhs.created < rhs.created }
                return lhs.url.lastPathComponent < rhs.url.lastPathComponent
            }
            .map { $0.url }
    }

    static func pendingPayloadURL(for envelope: Envelope, ingestDirectory: URL) -> URL? {
        guard let payloadFileName = envelope.payloadFileName else { return nil }
        guard payloadFileName == "\(envelope.id.uuidString).payload" else { return nil }
        let url = ingestDirectory.appendingPathComponent(payloadFileName)
        guard validateOwnedRegularFile(
            url,
            in: ingestDirectory,
            expectedFileName: payloadFileName
        ) else {
            return nil
        }
        return url
    }

    static func loadPendingPayload(from envelope: Envelope, ingestDirectory: URL) -> Data? {
        guard let payloadURL = pendingPayloadURL(for: envelope, ingestDirectory: ingestDirectory) else {
            return nil
        }
        return BestEffortFileOps.loadData(
            from: payloadURL,
            options: [.mappedIfSafe],
            logger: ScopyLog.monitor,
            operation: "loadPendingPayload.read"
        )
    }

    static func loadValidatedEnvelope(
        from url: URL,
        ingestDirectory: URL,
        suffix: String
    ) -> Envelope? {
        guard let pathID = validateOwnedEnvelopeURL(
            url,
            in: ingestDirectory,
            suffix: suffix,
            requireExistingRegularFile: true
        ), let envelope = loadPendingEnvelope(from: url), envelope.id == pathID else {
            return nil
        }
        if let payloadFileName = envelope.payloadFileName,
           payloadFileName != "\(envelope.id.uuidString).payload" {
            return nil
        }
        return envelope
    }

    fileprivate static func validateOwnedEnvelopeURL(
        _ url: URL,
        in ingestDirectory: URL,
        suffix: String,
        requireExistingRegularFile: Bool
    ) -> UUID? {
        let directory = ingestDirectory.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.deletingLastPathComponent().path == directory.path else { return nil }
        guard candidate.lastPathComponent.hasSuffix(suffix) else { return nil }
        let idText = String(candidate.lastPathComponent.dropLast(suffix.count))
        guard let id = UUID(uuidString: idText) else { return nil }
        guard !requireExistingRegularFile || validateOwnedRegularFile(
            candidate,
            in: directory,
            expectedFileName: candidate.lastPathComponent
        ) else {
            return nil
        }
        return id
    }

    fileprivate static func validateOwnedRegularFile(
        _ url: URL,
        in directory: URL,
        expectedFileName: String
    ) -> Bool {
        let ownedRoot = directory.standardizedFileURL
        let candidate = url.standardizedFileURL
        guard candidate.lastPathComponent == expectedFileName,
              candidate.deletingLastPathComponent().path == ownedRoot.path else {
            return false
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else { return false }
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: candidate.path),
              let fileType = attributes[.type] as? FileAttributeType,
              fileType == .typeRegular else {
            return false
        }
        let resolvedRoot = ownedRoot.resolvingSymlinksInPath().path
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        return resolvedCandidate.deletingLastPathComponent().path == resolvedRoot
    }

    static func transitionEnvelopeToTerminal(
        at pendingURL: URL,
        ingestDirectory: URL
    ) -> ClipboardMonitor.TerminalIngestAcknowledgement? {
        guard let pathID = validateOwnedEnvelopeURL(
            pendingURL,
            in: ingestDirectory,
            suffix: pendingEnvelopeSuffix,
            requireExistingRegularFile: false
        ) else {
            return nil
        }
        let markerURL = ingestDirectory.appendingPathComponent(
            "\(pathID.uuidString)\(terminalEnvelopeSuffix)"
        )

        if FileManager.default.fileExists(atPath: pendingURL.path) {
            guard loadValidatedEnvelope(
                from: pendingURL,
                ingestDirectory: ingestDirectory,
                suffix: pendingEnvelopeSuffix
            ) != nil else {
                return nil
            }
            guard !FileManager.default.fileExists(atPath: markerURL.path) else { return nil }
            do {
                try FileManager.default.moveItem(at: pendingURL, to: markerURL)
            } catch {
                ScopyLog.monitor.warning(
                    "Failed to transition ingest envelope to terminal state: \(error.localizedDescription, privacy: .private)"
                )
                return nil
            }
        }

        guard let envelope = loadValidatedEnvelope(
            from: markerURL,
            ingestDirectory: ingestDirectory,
            suffix: terminalEnvelopeSuffix
        ) else {
            return nil
        }
        return ClipboardMonitor.TerminalIngestAcknowledgement(
            ingestID: envelope.id,
            markerURL: markerURL,
            payloadFileName: envelope.payloadFileName
        )
    }

    static func discoverTerminalAcknowledgements(
        in directory: URL,
        limit: Int,
        excluding excludedIDs: Set<UUID>
    ) -> [ClipboardMonitor.TerminalIngestAcknowledgement] {
        guard limit > 0,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
              ) else {
            return []
        }
        return Array(urls
            .filter { $0.lastPathComponent.hasSuffix(terminalEnvelopeSuffix) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { markerURL in
                guard let envelope = loadValidatedEnvelope(
                    from: markerURL,
                    ingestDirectory: directory,
                    suffix: terminalEnvelopeSuffix
                ) else {
                    return nil
                }
                return ClipboardMonitor.TerminalIngestAcknowledgement(
                    ingestID: envelope.id,
                    markerURL: markerURL,
                    payloadFileName: envelope.payloadFileName
                )
            }
            .filter { !excludedIDs.contains($0.ingestID) }
            .prefix(limit))
    }

    static func validateTerminalAcknowledgement(
        _ acknowledgement: ClipboardMonitor.TerminalIngestAcknowledgement,
        ingestDirectory: URL
    ) -> Bool {
        guard let envelope = loadValidatedEnvelope(
            from: acknowledgement.markerURL,
            ingestDirectory: ingestDirectory,
            suffix: terminalEnvelopeSuffix
        ) else {
            return false
        }
        return envelope.id == acknowledgement.ingestID &&
            envelope.payloadFileName == acknowledgement.payloadFileName
    }

    static func cleanupTerminalAcknowledgement(
        _ acknowledgement: ClipboardMonitor.TerminalIngestAcknowledgement,
        ingestDirectory: URL
    ) -> Bool {
        if let payloadFileName = acknowledgement.payloadFileName,
           payloadFileName == "\(acknowledgement.ingestID.uuidString).payload" {
            let payloadURL = ingestDirectory.appendingPathComponent(payloadFileName)
            if FileManager.default.fileExists(atPath: payloadURL.path) {
                guard validateOwnedRegularFile(
                    payloadURL,
                    in: ingestDirectory,
                    expectedFileName: payloadFileName
                ) else {
                    return false
                }
                do {
                    try FileManager.default.removeItem(at: payloadURL)
                } catch {
                    ScopyLog.monitor.warning(
                        "Failed to remove terminal ingest payload: \(error.localizedDescription, privacy: .private)"
                    )
                    return false
                }
                guard !FileManager.default.fileExists(atPath: payloadURL.path) else { return false }
            }
        }
        guard validateOwnedRegularFile(
            acknowledgement.markerURL,
            in: ingestDirectory,
            expectedFileName: acknowledgement.markerURL.lastPathComponent
        ) else {
            return false
        }
        BestEffortFileOps.removeItem(
            at: acknowledgement.markerURL,
            logger: ScopyLog.monitor,
            operation: "cleanupTerminalIngest.removeMarker"
        )
        return !FileManager.default.fileExists(atPath: acknowledgement.markerURL.path)
    }

    static func quarantinePendingEnvelope(
        at url: URL,
        ingestDirectory: URL
    ) {
        guard validateOwnedEnvelopeURL(
            url,
            in: ingestDirectory,
            suffix: pendingEnvelopeSuffix,
            requireExistingRegularFile: true
        ) != nil else {
            return
        }
        let quarantineURL = ingestDirectory.appendingPathComponent(
            url.lastPathComponent + corruptEnvelopeSuffix
        )
        guard !FileManager.default.fileExists(atPath: quarantineURL.path) else { return }
        do {
            try FileManager.default.moveItem(at: url, to: quarantineURL)
        } catch {
            ScopyLog.monitor.warning(
                "Failed to quarantine corrupt ingest envelope: \(error.localizedDescription, privacy: .private)"
            )
        }
    }

    static func migrateLegacyPendingEnvelopes(
        from legacyDirectory: URL,
        to destinationDirectory: URL
    ) {
        guard legacyDirectory.standardizedFileURL.path != destinationDirectory.standardizedFileURL.path,
              FileManager.default.fileExists(atPath: legacyDirectory.path) else {
            return
        }
        let pendingURLs = discoverPendingEnvelopeURLs(in: legacyDirectory)
        for legacyEnvelopeURL in pendingURLs {
            guard let envelope = loadValidatedEnvelope(
                from: legacyEnvelopeURL,
                ingestDirectory: legacyDirectory,
                suffix: pendingEnvelopeSuffix
            ) else {
                continue
            }

            var legacyPayloadURL: URL?
            if envelope.payloadFileName != nil {
                guard let payloadURL = pendingPayloadURL(
                    for: envelope,
                    ingestDirectory: legacyDirectory
                ) else {
                    continue
                }
                legacyPayloadURL = payloadURL
                let destinationPayloadURL = destinationDirectory.appendingPathComponent(
                    payloadURL.lastPathComponent
                )
                guard copyOwnedMigrationFileIfNeeded(
                    from: payloadURL,
                    to: destinationPayloadURL,
                    destinationDirectory: destinationDirectory
                ) else {
                    continue
                }
            }

            let destinationEnvelopeURL = destinationDirectory.appendingPathComponent(
                legacyEnvelopeURL.lastPathComponent
            )
            guard copyOwnedMigrationFileIfNeeded(
                from: legacyEnvelopeURL,
                to: destinationEnvelopeURL,
                destinationDirectory: destinationDirectory
            ), loadValidatedEnvelope(
                from: destinationEnvelopeURL,
                ingestDirectory: destinationDirectory,
                suffix: pendingEnvelopeSuffix
            ) != nil else {
                continue
            }

            if let legacyPayloadURL {
                try? FileManager.default.removeItem(at: legacyPayloadURL)
            }
            try? FileManager.default.removeItem(at: legacyEnvelopeURL)
        }
    }

    private static func copyOwnedMigrationFileIfNeeded(
        from sourceURL: URL,
        to destinationURL: URL,
        destinationDirectory: URL
    ) -> Bool {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard validateOwnedRegularFile(
                destinationURL,
                in: destinationDirectory,
                expectedFileName: destinationURL.lastPathComponent
            ) else {
                return false
            }
            return FileManager.default.contentsEqual(
                atPath: sourceURL.path,
                andPath: destinationURL.path
            )
        }

        let temporaryURL = destinationDirectory.appendingPathComponent(
            "\(transientWorkPrefix)\(UUID().uuidString).migration.tmp"
        )
        defer { try? FileManager.default.removeItem(at: temporaryURL) }
        do {
            try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            guard validateOwnedRegularFile(
                destinationURL,
                in: destinationDirectory,
                expectedFileName: destinationURL.lastPathComponent
            ) else {
                return false
            }
            return FileManager.default.contentsEqual(
                atPath: sourceURL.path,
                andPath: destinationURL.path
            )
        } catch {
            ScopyLog.monitor.warning(
                "Failed to migrate a legacy ingest artifact: \(error.localizedDescription, privacy: .private)"
            )
            return false
        }
    }

    static func cleanupStaleControlledArtifacts(in directory: URL) {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: []
        ) else {
            return
        }
        let cutoff = Date().addingTimeInterval(-staleControlledArtifactAge)
        var removed = 0
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard removed < maxControlledArtifactsPerSweep else { break }
            let name = url.lastPathComponent
            let orphanPayloadID = standalonePayloadID(from: name)
            guard isControlledTransientArtifactName(name) || orphanPayloadID != nil else { continue }
            if let orphanPayloadID,
               hasEnvelopeAuthority(for: orphanPayloadID, in: directory) {
                continue
            }
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modifiedAt = values.contentModificationDate,
                  modifiedAt < cutoff,
                  validateOwnedRegularFile(url, in: directory, expectedFileName: name) else {
                continue
            }
            do {
                try FileManager.default.removeItem(at: url)
                removed += 1
            } catch {
                ScopyLog.monitor.warning(
                    "Failed to remove stale ingest work artifact: \(error.localizedDescription, privacy: .private)"
                )
            }
        }
    }

    private static func isControlledTransientArtifactName(_ name: String) -> Bool {
        if name.hasPrefix(transientWorkPrefix) { return true }
        guard name.hasSuffix(".tmp") else { return false }
        let base = String(name.dropLast(4))
        if base.hasSuffix(".payload") {
            return UUID(uuidString: String(base.dropLast(".payload".count))) != nil
        }
        if base.hasSuffix(pendingEnvelopeSuffix) {
            return UUID(uuidString: String(base.dropLast(pendingEnvelopeSuffix.count))) != nil
        }
        return false
    }

    private static func standalonePayloadID(from name: String) -> UUID? {
        guard name.hasSuffix(".payload") else { return nil }
        return UUID(uuidString: String(name.dropLast(".payload".count)))
    }

    /// A pending, terminal, or quarantined envelope remains the conservative authority for its
    /// payload. Only an aged UUID payload with no such sibling is an owned crash orphan.
    private static func hasEnvelopeAuthority(for id: UUID, in directory: URL) -> Bool {
        let base = id.uuidString
        let authorityNames = [
            base + pendingEnvelopeSuffix,
            base + terminalEnvelopeSuffix,
            base + pendingEnvelopeSuffix + corruptEnvelopeSuffix
        ]
        return authorityNames.contains { name in
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent(name).path
            )
        }
    }
}

// Referenced by ClipboardBackend as `ClipboardMonitor.createTransientWorkCopy`.
extension ClipboardMonitor {
    /// Copies a durable spool payload to a transient work file in the same directory, after
    /// re-validating that the envelope and payload are still owned spool files.
    nonisolated static func createTransientWorkCopy(
        for content: ClipboardContent,
        preferredExtension: String = "png"
    ) throws -> URL {
        guard content.fileOwnership == .durableSpool,
              case .file(let sourceURL) = content.payload,
              let ingestID = content.ingestID,
              let envelopeURL = content.ingestEnvelopeURL else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let directory = envelopeURL.deletingLastPathComponent()
        guard IngestSpool.validateOwnedEnvelopeURL(
            envelopeURL,
            in: directory,
            suffix: IngestSpool.pendingEnvelopeSuffix,
            requireExistingRegularFile: true
        ) == ingestID,
        IngestSpool.validateOwnedRegularFile(
            sourceURL,
            in: directory,
            expectedFileName: "\(ingestID.uuidString).payload"
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }

        let safeExtension = preferredExtension.lowercased().allSatisfy { $0.isLetter || $0.isNumber }
            ? preferredExtension.lowercased()
            : "dat"
        let workURL = directory.appendingPathComponent(
            "\(IngestSpool.transientWorkPrefix)\(UUID().uuidString).\(safeExtension)"
        )
        try FileManager.default.copyItem(at: sourceURL, to: workURL)
        return workURL
    }
}
