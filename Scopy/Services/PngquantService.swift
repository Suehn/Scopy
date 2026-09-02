import Darwin
import Foundation
import os

public enum PngquantService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scopy", category: "pngquant")

    public struct Options: Sendable, Equatable {
        public static let defaultProcessTimeoutSeconds: TimeInterval = 60

        public var binaryPath: String
        public var qualityMin: Int
        public var qualityMax: Int
        public var speed: Int
        public var colors: Int
        public var processTimeoutSeconds: TimeInterval

        public init(
            binaryPath: String,
            qualityMin: Int,
            qualityMax: Int,
            speed: Int,
            colors: Int,
            processTimeoutSeconds: TimeInterval = Self.defaultProcessTimeoutSeconds
        ) {
            self.binaryPath = binaryPath
            self.qualityMin = qualityMin
            self.qualityMax = qualityMax
            self.speed = speed
            self.colors = colors
            self.processTimeoutSeconds = processTimeoutSeconds
        }

        /// Command-line arguments shared by every invocation: quality window, speed and color budget.
        fileprivate var baseArguments: [String] {
            let minQ = max(0, min(100, qualityMin))
            let maxQ = max(0, min(100, qualityMax))
            let qualityMin = min(minQ, maxQ)
            let qualityMax = max(minQ, maxQ)
            let speed = max(1, min(11, speed))
            return ["--quality", "\(qualityMin)-\(qualityMax)", "--speed", "\(speed)", "--strip"]
        }

        fileprivate var colorArgument: String {
            "\(max(2, min(256, colors)))"
        }
    }

    enum PngquantError: LocalizedError {
        case binaryNotFound
        case binaryNotExecutable(path: String)
        case timedOut(timeoutSeconds: TimeInterval)
        case cancelled
        case failed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "pngquant not found"
            case .binaryNotExecutable(let path):
                return "pngquant is not executable: \(path)"
            case .timedOut(let timeoutSeconds):
                return "pngquant timed out after \(String(format: "%.2f", timeoutSeconds)) seconds"
            case .cancelled:
                return "pngquant was cancelled"
            case .failed(let exitCode, let stderr):
                if stderr.isEmpty {
                    return "pngquant failed with exit code \(exitCode)"
                }
                return "pngquant failed with exit code \(exitCode): \(stderr)"
            }
        }
    }

    /// Exit codes pngquant uses for "left the image alone": 98 = `--skip-if-larger`, 99 = quality below the minimum.
    private static let noChangeExitCodes: Set<Int32> = [98, 99]

    private struct ProcessResult {
        let terminationStatus: Int32
        let stderr: Data
    }

    static func resolveBinaryPath(preferredPath: String) throws -> String {
        let expanded = (preferredPath as NSString).expandingTildeInPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !expanded.isEmpty {
            guard FileManager.default.fileExists(atPath: expanded) else { throw PngquantError.binaryNotFound }
            guard FileManager.default.isExecutableFile(atPath: expanded) else { throw PngquantError.binaryNotExecutable(path: expanded) }
            return expanded
        }

        if let bundledURL = Bundle.main.url(forResource: "pngquant", withExtension: nil, subdirectory: "Tools") {
            let path = bundledURL.path
            if FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
            throw PngquantError.binaryNotExecutable(path: path)
        }

        let candidates = [
            "/opt/homebrew/bin/pngquant",
            "/usr/local/bin/pngquant",
            "/usr/bin/pngquant"
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        throw PngquantError.binaryNotFound
    }

    static func isLikelyPNG(_ data: Data) -> Bool {
        // 89 50 4E 47 0D 0A 1A 0A
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        guard data.count >= signature.count else { return false }
        return data.prefix(signature.count).elementsEqual(signature)
    }

    static func isLikelyPNGFile(_ fileURL: URL) -> Bool {
        do {
            let handle = try FileHandle(forReadingFrom: fileURL)
            defer { try? handle.close() }

            let data = try handle.read(upToCount: 8) ?? Data()
            return isLikelyPNG(data)
        } catch {
            return false
        }
    }

    /// Quantizes PNG bytes. Returns the caller's exact bytes when pngquant leaves the image alone.
    static func compressPNGData(_ pngData: Data, options: Options) throws -> Data {
        guard isLikelyPNG(pngData) else { return pngData }

        let binary = try resolveBinaryPath(preferredPath: options.binaryPath)
        let io = try ScratchDirectory()
        let inputURL = io.url.appendingPathComponent("input.png")
        let outputURL = io.url.appendingPathComponent("output.png")
        try pngData.write(to: inputURL)

        let result = try runProcess(
            executablePath: binary,
            arguments: options.baseArguments + ["--skip-if-larger", "--output", outputURL.path, options.colorArgument, "--", inputURL.path],
            stderrURL: io.url.appendingPathComponent("stderr"),
            timeoutSeconds: options.processTimeoutSeconds
        )

        let exit = result.terminationStatus
        if noChangeExitCodes.contains(exit) {
            return pngData
        }
        if exit == 0 {
            guard let output = try? Data(contentsOf: outputURL), !output.isEmpty else { return pngData }
            return output
        }
        throw PngquantError.failed(exitCode: exit, stderr: stderrText(result.stderr))
    }

    /// Quantizes a raw RGBA PAM file (see `pamHeader`), which pngquant maps directly instead of decoding a PNG.
    /// Returns `nil` when pngquant cannot reach the quality window, in which case the caller encodes the pixels itself.
    static func compressPAMFile(_ inputURL: URL, options: Options) throws -> Data? {
        let binary = try resolveBinaryPath(preferredPath: options.binaryPath)
        let io = try ScratchDirectory()
        let outputURL = io.url.appendingPathComponent("output.png")

        let startedAt = DispatchTime.now().uptimeNanoseconds
        let result = try runProcess(
            executablePath: binary,
            arguments: options.baseArguments + ["--output", outputURL.path, options.colorArgument, "--", inputURL.path],
            stderrURL: io.url.appendingPathComponent("stderr"),
            timeoutSeconds: options.processTimeoutSeconds
        )
        logger.info(
            "pngquant PAM \(inputURL.lastPathComponent, privacy: .public): tool \(Double(DispatchTime.now().uptimeNanoseconds &- startedAt) / 1_000_000, format: .fixed(precision: 1), privacy: .public) ms, exit \(result.terminationStatus, privacy: .public)"
        )

        let exit = result.terminationStatus
        if noChangeExitCodes.contains(exit) {
            return nil
        }
        if exit == 0 {
            guard let output = try? Data(contentsOf: outputURL), isLikelyPNG(output) else { return nil }
            return output
        }
        throw PngquantError.failed(exitCode: exit, stderr: stderrText(result.stderr))
    }

    static func compressPNGFileInPlace(_ fileURL: URL, options: Options) throws -> Bool {
        try compressPNGFileInPlace(
            fileURL,
            options: options,
            replaceOutputAtomically: replaceFileAtomically
        )
    }

    static func compressPNGFileInPlace(
        _ fileURL: URL,
        options: Options,
        replaceOutputAtomically: (_ temporaryURL: URL, _ originalURL: URL) throws -> Void
    ) throws -> Bool {
        let binary = try resolveBinaryPath(preferredPath: options.binaryPath)

        let originalPath = fileURL.path
        guard FileManager.default.fileExists(atPath: originalPath) else { return false }
        guard FileManager.default.isReadableFile(atPath: originalPath) else { return false }

        let tmpPath = originalPath + ".pngquant-\(UUID().uuidString).tmp"
        let tmpURL = URL(fileURLWithPath: tmpPath)
        if FileManager.default.fileExists(atPath: tmpPath) {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let io = try ScratchDirectory()
        let result = try runProcess(
            executablePath: binary,
            arguments: options.baseArguments + ["--skip-if-larger", "--output", tmpPath, options.colorArgument, "--", originalPath],
            stderrURL: io.url.appendingPathComponent("stderr"),
            timeoutSeconds: options.processTimeoutSeconds
        )

        let exit = result.terminationStatus
        if exit == 0 {
            guard FileManager.default.fileExists(atPath: tmpPath) else { return false }
            let originalURL = URL(fileURLWithPath: originalPath)
            do {
                try replaceOutputAtomically(tmpURL, originalURL)
                return true
            } catch {
                throw PngquantError.failed(exitCode: -1, stderr: error.localizedDescription)
            }
        }

        if noChangeExitCodes.contains(exit) {
            return false
        }

        throw PngquantError.failed(exitCode: exit, stderr: stderrText(result.stderr))
    }

    // MARK: - Raw bitmap hand-off

    /// Byte length of every PAM header `pamHeader` produces, so pixel rows start at a fixed, 64-byte-aligned offset
    /// and a header can be rewritten in place when the image is trimmed.
    static let pamHeaderLength = 128

    /// PAM (`P7`) header for 8-bit straight-alpha RGBA pixels, padded with a comment line to `pamHeaderLength` bytes.
    static func pamHeader(width: Int, height: Int) -> Data {
        let fields = "P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\n"
        let trailer = "ENDHDR\n"
        let padding = pamHeaderLength - fields.utf8.count - 2 - trailer.utf8.count // "#" + spaces + "\n"
        precondition(padding >= 0, "PAM header does not fit \(width)x\(height)")
        return Data((fields + "#" + String(repeating: " ", count: padding) + "\n" + trailer).utf8)
    }

    private static func replaceFileAtomically(
        temporaryURL: URL,
        originalURL: URL
    ) throws {
        guard Darwin.rename(temporaryURL.path, originalURL.path) == 0 else {
            let errorCode = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errorCode))
        }
    }

    /// A private temporary directory that disappears with the value.
    private final class ScratchDirectory {
        let url: URL

        init() throws {
            url = FileManager.default.temporaryDirectory.appendingPathComponent(
                "scopy-pngquant-io-\(UUID().uuidString)",
                isDirectory: true
            )
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }

        deinit {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        stderrURL: URL,
        timeoutSeconds requestedTimeoutSeconds: TimeInterval
    ) throws -> ProcessResult {
        guard !Task.isCancelled else { throw PngquantError.cancelled }

        let timeoutSeconds = effectiveProcessTimeout(requestedTimeoutSeconds)
        try Data().write(to: stderrURL, options: .atomic)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer { try? stderrHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderrHandle

        do {
            try process.run()
        } catch {
            throw PngquantError.failed(exitCode: -1, stderr: error.localizedDescription)
        }

        let timeoutNanoseconds = UInt64(timeoutSeconds * 1_000_000_000)
        let startedAt = DispatchTime.now().uptimeNanoseconds
        let deadline = startedAt.addingReportingOverflow(timeoutNanoseconds)
        while process.isRunning {
            if Task.isCancelled {
                terminateAndWait(process)
                throw PngquantError.cancelled
            }
            let now = DispatchTime.now().uptimeNanoseconds
            if deadline.overflow || now >= deadline.partialValue {
                terminateAndWait(process)
                throw PngquantError.timedOut(timeoutSeconds: timeoutSeconds)
            }
            Thread.sleep(forTimeInterval: 0.002)
        }
        process.waitUntilExit()

        try? stderrHandle.close()

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            stderr: (try? Data(contentsOf: stderrURL)) ?? Data()
        )
    }

    private static func effectiveProcessTimeout(_ requested: TimeInterval) -> TimeInterval {
        guard requested.isFinite else { return Options.defaultProcessTimeoutSeconds }
        return min(600, max(0.01, requested))
    }

    private static func terminateAndWait(_ process: Process) {
        guard process.isRunning else {
            process.waitUntilExit()
            return
        }

        process.terminate()
        let graceDeadline = DispatchTime.now().uptimeNanoseconds + 250_000_000
        while process.isRunning, DispatchTime.now().uptimeNanoseconds < graceDeadline {
            Thread.sleep(forTimeInterval: 0.005)
        }
        if process.isRunning {
            _ = Darwin.kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }

    private static func stderrText(_ data: Data) -> String {
        String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    public static func compressBestEffort(_ pngData: Data, options: Options) -> Data {
        do {
            let output = try compressPNGData(pngData, options: options)
            if output.count > 0, output.count != pngData.count {
                logger.debug("pngquant compressed PNG: \(pngData.count, privacy: .public) -> \(output.count, privacy: .public) bytes")
            }
            return output
        } catch {
            logger.warning("pngquant skipped: \(error.localizedDescription, privacy: .public)")
            return pngData
        }
    }

    /// Quantizes a PAM file, or returns `nil` when pngquant declined or failed so the caller can encode the pixels itself.
    public static func compressPAMFileBestEffort(_ inputURL: URL, options: Options) -> Data? {
        do {
            return try compressPAMFile(inputURL, options: options)
        } catch {
            logger.warning("pngquant PAM skipped: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    static func compressFileBestEffort(_ fileURL: URL, options: Options) -> Bool {
        do {
            let replaced = try compressPNGFileInPlace(fileURL, options: options)
            if replaced {
                logger.debug("pngquant compressed PNG file in-place: \(fileURL.path, privacy: .private)")
            }
            return replaced
        } catch {
            logger.warning("pngquant file skipped: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
