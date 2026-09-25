import AppKit
import Darwin
import Foundation
import ImageIO
import os
import UniformTypeIdentifiers
import WebKit

extension ExportCoordinator {
    func prepareForExportScrollHeightPoints(webView: WKWebView) async throws -> CGFloat {
        // `WKWebView.callAsyncJavaScript` has been observed to return `nil` (undefined) intermittently under UI testing,
        // so readiness is pushed by the page-side animation-frame watcher through the `scopyExportLayout` handler.
        let widthPoints = Double(viewportWidthPoints)

        let setupJS = "window.ScopyDocument.export.prepare()"
        let adjustWideContentJS = "window.ScopyDocument.export.adjustWideContent(\(widthPoints))"

        do {
            _ = try await readLayoutSample(webView: webView)
            _ = try await evaluateJavaScriptBool(webView: webView, javaScriptString: setupJS)
        } catch {
            throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
        }

        let readinessDeadline = CFAbsoluteTimeGetCurrent() + 12.0
        var didAdjustWideContent = false
        var adjustAttempts = 0
        var firstSettledAt: CFAbsoluteTime?
        var lastSample: ExportLayoutSample?

        while true {
            let remaining = readinessDeadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { break }
            let settled = try await awaitLayoutSettled(webView: webView, requireRenderReady: true, timeout: remaining)
            lastSample = settled.sample
            guard settled.isSettled else { break }
            let sample = settled.sample
            let now = CFAbsoluteTimeGetCurrent()
            if firstSettledAt == nil { firstSettledAt = now }

            if !didAdjustWideContent {
                // Wide-content adjustments measure code and table widths, so they wait for fonts unless the page has
                // no font API or fonts never report within 1.2 s of the first settled layout.
                let fontsSettled = sample.fonts == "loaded" || sample.fonts == "n/a" || now - (firstSettledAt ?? now) >= 1.2
                if !fontsSettled {
                    try? await Task.sleep(nanoseconds: 16_000_000)
                    continue
                }
                let adjusted = (try? await evaluateJavaScriptBool(webView: webView, javaScriptString: adjustWideContentJS)) ?? false
                if adjusted {
                    didAdjustWideContent = true
                    continue
                }
                adjustAttempts += 1
                if adjustAttempts < 3 { continue }
                MarkdownExportService.logger.warning("Wide-content adjustment did not run after \(adjustAttempts, privacy: .public) attempts; exporting the measured layout")
                didAdjustWideContent = true
                continue
            }

            return sample.height
        }

        let error = NSError(
            domain: "Scopy.MarkdownExport",
            code: 2,
            userInfo: [
                NSLocalizedDescriptionKey:
                    "Markdown did not reach terminal render readiness (last height: \(lastSample?.height ?? 0))."
            ]
        )
        throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
    }


    /// Waits for the layout to settle after a change and returns the larger of the estimate and the live measurement.
    func reconcileExportHeightPoints(
        webView: WKWebView,
        estimatedHeightPoints: CGFloat
    ) async throws -> CGFloat {
        let settled = try await awaitLayoutSettled(webView: webView, requireRenderReady: false, timeout: 1.0)
        var liveHeight = settled.sample.liveHeight
        if liveHeight <= 0,
           let scrollView = resolvedScrollView(for: webView),
           let documentView = scrollView.documentView
        {
            liveHeight = max(documentView.bounds.height, documentView.frame.height)
        }
        return max(max(1, estimatedHeightPoints), liveHeight)
    }

    func currentExportScale(webView: WKWebView) async -> CGFloat {
        let raw = try? await evaluateJavaScriptString(webView: webView, javaScriptString: "window.ScopyDocument.export.state.scale")
        guard let raw, let scale = Double(raw), scale > 0 else { return 1 }
        return CGFloat(scale)
    }

    func applyGlobalScale(webView: WKWebView, scale: CGFloat) async throws {
        let js = "window.ScopyDocument.export.applyScale(\(Double(scale)))"
        do {
            let ok = try await evaluateJavaScriptBool(webView: webView, javaScriptString: js)
            if !ok {
                let error = NSError(
                    domain: "Scopy.MarkdownExport",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "applyGlobalScale returned false"]
                )
                throw MarkdownExportService.ExportError.stageFailed(stage: .applyScale, underlying: error)
            }
        } catch {
            throw MarkdownExportService.ExportError.stageFailed(stage: .applyScale, underlying: error)
        }
        _ = try? await awaitLayoutSettled(webView: webView, requireRenderReady: false, timeout: 1.5)
    }

    // MARK: - Layout settle

    /// Reads the current sample from the page-side watcher (`ScopyDocument.export.watchLayout`), installing it on the
    /// first call; with a phase it also announces a new wait, which the watcher answers by pushing samples.
    func readLayoutSample(webView: WKWebView, phase: Int? = nil) async throws -> ExportLayoutSample {
        let argument = phase.map(String.init) ?? ""
        let value = try await evaluateJavaScriptString(
            webView: webView,
            javaScriptString: "window.ScopyDocument.export.watchLayout(\(argument))"
        )
        guard let data = value.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              let sample = ExportLayoutMessage(body: object)?.sample else {
            throw NSError(
                domain: "Scopy.MarkdownExport",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey: "Layout watcher returned an unreadable sample: \(value.prefix(120))"]
            )
        }
        return sample
    }

    /// Starts a new layout phase and waits until the page pushes that the layout has been stable for three frames
    /// (at least two frames into the phase). Late messages from earlier phases are dropped. When no push arrives,
    /// animation frames may be throttled (an occluded host window), so each quiet interval reads one sample and
    /// accepts time-based stability: frames stalled for 0.3 s and the height unchanged for 0.45 s. Returns the last
    /// sample either way; `isSettled` tells whether the condition was met before `timeout`.
    func awaitLayoutSettled(
        webView: WKWebView,
        requireRenderReady: Bool,
        timeout: TimeInterval
    ) async throws -> (sample: ExportLayoutSample, isSettled: Bool) {
        let deadline = CFAbsoluteTimeGetCurrent() + max(0, timeout)
        let phase = layoutPhases.begin()
        var sample = try await readLayoutSample(webView: webView, phase: phase)
        var lastFrames = sample.frames
        var framesChangedAt = CFAbsoluteTimeGetCurrent()
        var lastHeight = sample.height
        var heightStableSince = framesChangedAt
        while true {
            try Self.throwIfRenderFailed(sample)
            let remaining = deadline - CFAbsoluteTimeGetCurrent()
            guard remaining > 0 else { return (sample, false) }
            if let message = await nextLayoutMessage(within: min(remaining, 0.25), where: { message in
                message.sample.renderFailed
                    || (message.event == "settled" && (!requireRenderReady || message.sample.renderReady))
            }) {
                try Self.throwIfRenderFailed(message.sample)
                return (message.sample, true)
            }
            sample = try await readLayoutSample(webView: webView)
            let now = CFAbsoluteTimeGetCurrent()
            if sample.frames != lastFrames {
                lastFrames = sample.frames
                framesChangedAt = now
            }
            if abs(sample.height - lastHeight) >= 1 {
                lastHeight = sample.height
                heightStableSince = now
            }
            let ready = !requireRenderReady || sample.renderReady
            if ready, sample.height > 0, now - framesChangedAt > 0.3, now - heightStableSince >= 0.45 {
                MarkdownExportService.logger.info("Layout watcher frames stalled; accepting time-based stability")
                return (sample, true)
            }
        }
    }

    /// Waits until two animation frames have run in a new phase; best effort, bounded by `timeout`.
    func waitForAnimationFrames(webView: WKWebView, timeout: TimeInterval) async {
        let phase = layoutPhases.begin()
        guard (try? await readLayoutSample(webView: webView, phase: phase)) != nil else {
            try? await Task.sleep(nanoseconds: 50_000_000)
            return
        }
        _ = await nextLayoutMessage(within: timeout) { $0.event == "frames" || $0.event == "settled" }
    }

    /// The next pushed message of the current phase that satisfies `condition`, or nil after `interval`.
    private func nextLayoutMessage(
        within interval: TimeInterval,
        where condition: @escaping (ExportLayoutMessage) -> Bool
    ) async -> ExportLayoutMessage? {
        if let latest = layoutPhases.latest, condition(latest) { return latest }
        return await withCheckedContinuation { continuation in
            let waiter = ExportLayoutWaiter(condition: condition, continuation: continuation)
            layoutWaiter?.resume(nil)
            layoutWaiter = waiter
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
                if self?.layoutWaiter === waiter { self?.layoutWaiter = nil }
                waiter.resume(nil)
            }
        }
    }

    /// Delivers a message posted by the page to the waiting settle, if it belongs to the current phase.
    func receiveLayoutMessage(_ message: ExportLayoutMessage) {
        guard layoutPhases.receive(message), let waiter = layoutWaiter, waiter.condition(message) else { return }
        layoutWaiter = nil
        waiter.resume(message)
    }

    private static func throwIfRenderFailed(_ sample: ExportLayoutSample) throws {
        guard sample.renderFailed else { return }
        let error = NSError(
            domain: "Scopy.MarkdownExport",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: sample.renderErrorReason ?? "Markdown renderer failed"]
        )
        throw MarkdownExportService.ExportError.stageFailed(stage: .prepareLayout, underlying: error)
    }
}

/// One sample of the page-side layout watcher.
struct ExportLayoutSample: Equatable {
    let frames: Int
    let stableFrames: Int
    let height: CGFloat
    let liveHeight: CGFloat
    let fonts: String
    let renderReady: Bool
    let renderFailed: Bool
    let renderErrorReason: String?
}

/// A sample the watcher pushed (or returned) for one layout phase; `event` names why it was sent.
struct ExportLayoutMessage: Equatable {
    let phase: Int
    let event: String
    let sample: ExportLayoutSample

    init?(body: Any) {
        guard let object = body as? [String: Any],
              let phase = (object["phase"] as? NSNumber)?.intValue,
              let event = object["event"] as? String else { return nil }
        func number(_ key: String) -> CGFloat {
            (object[key] as? NSNumber).map { CGFloat(truncating: $0) } ?? 0
        }
        let reason = (object["renderErrorReason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.phase = phase
        self.event = event
        sample = ExportLayoutSample(
            frames: Int(number("frames")),
            stableFrames: Int(number("stableFrames")),
            height: max(0, number("height")),
            liveHeight: max(0, number("live")),
            fonts: (object["fonts"] as? String) ?? "n/a",
            renderReady: (object["renderReady"] as? Bool) ?? false,
            renderFailed: (object["renderFailed"] as? Bool) ?? false,
            renderErrorReason: (reason?.isEmpty ?? true) ? nil : reason
        )
    }
}

/// Numbers each settle wait and keeps only the messages of the current one.
struct ExportLayoutPhases {
    private(set) var current = 0
    private(set) var latest: ExportLayoutMessage?

    mutating func begin() -> Int {
        current += 1
        latest = nil
        return current
    }

    /// Returns false and drops `message` when it was posted for an earlier phase.
    mutating func receive(_ message: ExportLayoutMessage) -> Bool {
        guard message.phase == current else { return false }
        latest = message
        return true
    }
}

@MainActor
final class ExportLayoutWaiter {
    let condition: (ExportLayoutMessage) -> Bool
    private var continuation: CheckedContinuation<ExportLayoutMessage?, Never>?

    init(condition: @escaping (ExportLayoutMessage) -> Bool, continuation: CheckedContinuation<ExportLayoutMessage?, Never>) {
        self.condition = condition
        self.continuation = continuation
    }

    func resume(_ message: ExportLayoutMessage?) {
        continuation?.resume(returning: message)
        continuation = nil
    }
}
