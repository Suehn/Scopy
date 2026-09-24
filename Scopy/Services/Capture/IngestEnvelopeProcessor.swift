import Foundation

extension ClipboardMonitor {
    enum EnvelopeBuildResult: Sendable {
        case content(ClipboardContent)
        case invalid
        case cancelled
    }

    nonisolated static func buildEnvelopeContent(
        _ envelopeURL: URL,
        ingestDirectory: URL,
        delay: Duration
    ) async -> EnvelopeBuildResult {
        if delay > .zero {
            try? await Task.sleep(for: delay)
        }
        guard !Task.isCancelled else { return .cancelled }

        guard let envelope = loadValidatedEnvelope(
            from: envelopeURL,
            ingestDirectory: ingestDirectory,
            suffix: pendingEnvelopeSuffix
        ) else {
            return .invalid
        }

        let originalPayloadData = loadPendingPayload(from: envelope, ingestDirectory: ingestDirectory)
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
            if envelope.imageDataWasTIFF, let pngData = convertTIFFToPNG(imageData) {
                payloadData = pngData
            } else {
                payloadData = imageData
            }
            sizeBytes = payloadData?.count ?? imageData.count
            plainText = "[Image: \(formatBytes(sizeBytes))]"
        }

        let hash = contentHash(
            type: envelope.type,
            plainText: plainText,
            payloadData: payloadData,
            precomputedHash: envelope.precomputedHash
        )

        let preferredPayloadURL: URL? = {
            guard payloadData == originalPayloadData else { return nil }
            return pendingPayloadURL(for: envelope, ingestDirectory: ingestDirectory)
        }()

        let builtPayload = buildPayload(
            type: envelope.type,
            data: payloadData,
            sizeBytes: sizeBytes,
            ingestDirectory: ingestDirectory,
            spoolThresholdBytes: ScopyThresholds.ingestSpoolBytes,
            preferredFileURL: preferredPayloadURL
        )

        return .content(ClipboardContent(
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

    private struct BuiltPayload: Sendable {
        let payload: ClipboardContent.Payload
        let ownership: ClipboardContent.FileOwnership
    }

    nonisolated private static func buildPayload(
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
            "\(transientWorkPrefix)\(UUID().uuidString).\(ext)"
        )
        do {
            try StorageService.writeAtomically(data, to: fileURL.path)
            return BuiltPayload(payload: .file(fileURL), ownership: .transient)
        } catch {
            ScopyLog.monitor.warning("Failed to spool ingest payload: \(error.localizedDescription, privacy: .private)")
            return BuiltPayload(payload: .data(data), ownership: .transient)
        }
    }

    nonisolated static func cleanupPayloadIfNeeded(
        _ payload: ClipboardContent.Payload,
        ownership: ClipboardContent.FileOwnership
    ) {
        guard ownership == .transient else { return }
        guard case .file(let url) = payload else { return }
        try? FileManager.default.removeItem(at: url)
    }

    nonisolated private static func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }
}
