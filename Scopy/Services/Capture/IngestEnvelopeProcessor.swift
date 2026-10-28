import Foundation

/// Off-main-actor stage of the ingest FIFO: turns one durable envelope into `ClipboardContent`
/// (validate, load the payload, re-encode TIFF, hash, spool large payloads to a work file).
/// The FIFO itself, its worker and session scoping are owned by ClipboardMonitor.
enum IngestEnvelopeProcessor {
    enum Outcome: Sendable {
        case content(ClipboardMonitor.ClipboardContent)
        case invalid
        case unavailable
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

        let envelope: IngestSpool.Envelope
        let originalPayloadData: Data?
        do {
            envelope = try IngestSpool.loadValidatedEnvelope(
                from: envelopeURL,
                ingestDirectory: ingestDirectory,
                suffix: IngestSpool.pendingEnvelopeSuffix
            )
            guard !Task.isCancelled else { return .cancelled }
            originalPayloadData = try IngestSpool.loadPendingPayload(from: envelope, ingestDirectory: ingestDirectory)
        } catch IngestSpool.ReadError.unavailable {
            return Task.isCancelled ? .cancelled : .unavailable
        } catch {
            guard !Task.isCancelled else { return .cancelled }
            return .invalid
        }
        guard !Task.isCancelled else { return .cancelled }
        var payloadData = originalPayloadData
        var payload = CapturedPayload.original(
            originalPayloadData,
            envelope: envelope,
            ingestDirectory: ingestDirectory
        )
        var plainText = envelope.plainText
        var sizeBytes = envelope.sizeBytes

        if envelope.type == .image, let imageData = payloadData {
            if envelope.imageDataWasTIFF, let pngData = ClipboardMonitor.convertTIFFToPNG(imageData) {
                payloadData = pngData
                payload = payload.replacingData(pngData, type: .image)
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

        guard !Task.isCancelled else { return .cancelled }

        return .content(ClipboardMonitor.ClipboardContent(
            type: envelope.type,
            plainText: plainText,
            payload: payload,
            appBundleID: envelope.appBundleID,
            contentHash: hash,
            sizeBytes: sizeBytes
        ))
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
