import Foundation

/// Off-main-actor stage of the ingest FIFO: turns one durable envelope into `ClipboardContent`
/// (validate, load the payload, re-encode TIFF, hash, spool large payloads to a work file).
/// The FIFO itself, its worker and session scoping are owned by ClipboardMonitor.
enum IngestEnvelopeProcessor {
    enum Outcome: Sendable {
        case content(ClipboardMonitor.ClipboardContent)
        case invalid
        case cancelled
    }

    static func buildContent(
        from envelopeURL: URL,
        ingestDirectory: URL,
        delay: Duration
    ) async -> Outcome {
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled else { return .cancelled }

        guard let envelope = IngestSpool.loadValidatedEnvelope(
            from: envelopeURL,
            ingestDirectory: ingestDirectory,
            suffix: IngestSpool.pendingEnvelopeSuffix
        ) else {
            return .invalid
        }

        let originalPayloadData = IngestSpool.loadPendingPayload(from: envelope, ingestDirectory: ingestDirectory)
        if envelope.payloadFileName != nil, originalPayloadData == nil {
            ScopyLog.monitor.error(
                "Discarding pending ingest envelope because payload file is missing: \(envelopeURL.lastPathComponent, privacy: .public)"
            )
            return .invalid
        }
        var payloadData = originalPayloadData
        var plainText = envelope.plainText
        var sizeBytes = envelope.sizeBytes

        if envelope.type == .image, let imageData = payloadData {
            if envelope.imageDataWasTIFF, let pngData = ClipboardMonitor.convertTIFFToPNG(imageData) {
                payloadData = pngData
            } else {
                payloadData = imageData
            }
            sizeBytes = payloadData?.count ?? imageData.count
            plainText = "[Image: \(formatBytes(sizeBytes))]"
        }

        let hash = CapturePolicy.contentHash(
            type: envelope.type,
            plainText: plainText,
            payloadData: payloadData,
            precomputedHash: envelope.precomputedHash
        )

        let preferredPayloadURL: URL? = {
            guard payloadData == originalPayloadData else { return nil }
            return IngestSpool.pendingPayloadURL(for: envelope, ingestDirectory: ingestDirectory)
        }()

        let builtPayload = buildPayload(
            type: envelope.type,
            data: payloadData,
            sizeBytes: sizeBytes,
            ingestDirectory: ingestDirectory,
            spoolThresholdBytes: ScopyThresholds.ingestSpoolBytes,
            preferredFileURL: preferredPayloadURL
        )

        return .content(ClipboardMonitor.ClipboardContent(
            type: envelope.type,
            plainText: plainText,
            payload: builtPayload.payload,
            appBundleID: envelope.appBundleID,
            contentHash: hash,
            sizeBytes: sizeBytes,
            ingestEnvelopeURL: envelopeURL,
            ingestID: envelope.id,
            fileOwnership: builtPayload.ownership
        ))
    }

    /// Deletes a transient payload file of content that will not be delivered.
    static func cleanupPayloadIfNeeded(
        _ payload: ClipboardMonitor.ClipboardContent.Payload,
        ownership: ClipboardMonitor.ClipboardContent.FileOwnership
    ) {
        guard ownership == .transient else { return }
        guard case .file(let url) = payload else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private struct BuiltPayload: Sendable {
        let payload: ClipboardMonitor.ClipboardContent.Payload
        let ownership: ClipboardMonitor.ClipboardContent.FileOwnership
    }

    private static func buildPayload(
        type: ClipboardItemType,
        data: Data?,
        sizeBytes: Int,
        ingestDirectory: URL,
        spoolThresholdBytes: Int,
        preferredFileURL: URL?
    ) -> BuiltPayload {
        guard let data else { return BuiltPayload(payload: .none, ownership: .transient) }

        guard sizeBytes >= spoolThresholdBytes else {
            return BuiltPayload(payload: .data(data), ownership: .transient)
        }

        if let preferredFileURL, FileManager.default.fileExists(atPath: preferredFileURL.path) {
            return BuiltPayload(payload: .file(preferredFileURL), ownership: .durableSpool)
        }

        let ext: String
        switch type {
        case .image: ext = ImageFileExtension.sniff(data)
        case .rtf: ext = "rtf"
        case .html: ext = "html"
        default: ext = "dat"
        }

        let fileURL = ingestDirectory.appendingPathComponent(
            "\(IngestSpool.transientWorkPrefix)\(UUID().uuidString).\(ext)"
        )
        do {
            try StorageService.writeAtomically(data, to: fileURL.path)
            return BuiltPayload(payload: .file(fileURL), ownership: .transient)
        } catch {
            ScopyLog.monitor.warning("Failed to spool ingest payload: \(error.localizedDescription, privacy: .private)")
            return BuiltPayload(payload: .data(data), ownership: .transient)
        }
    }

    private static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}
