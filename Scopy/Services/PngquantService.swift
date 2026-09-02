import CoreGraphics
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
        case invalidBitmap(width: Int, height: Int)

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
            case .invalidBitmap(let width, let height):
                return "pngquant cannot encode a \(width)x\(height) bitmap"
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

    /// Quantizes a bitmap without an intermediate PNG: the pixels are handed to pngquant as a raw
    /// RGBA PAM file, which it maps directly. Returns `nil` when pngquant cannot reach the quality
    /// window, in which case the caller encodes the bitmap itself.
    static func compressBitmap(_ image: CGImage, options: Options) throws -> Data? {
        let binary = try resolveBinaryPath(preferredPath: options.binaryPath)
        let io = try ScratchDirectory()
        let inputURL = io.url.appendingPathComponent("input.pam")
        let outputURL = io.url.appendingPathComponent("output.png")
        let startedAt = DispatchTime.now().uptimeNanoseconds
        try writePAM(image, to: inputURL)
        let pamWrittenAt = DispatchTime.now().uptimeNanoseconds

        let result = try runProcess(
            executablePath: binary,
            arguments: options.baseArguments + ["--output", outputURL.path, options.colorArgument, "--", inputURL.path],
            stderrURL: io.url.appendingPathComponent("stderr"),
            timeoutSeconds: options.processTimeoutSeconds
        )
        let toolFinishedAt = DispatchTime.now().uptimeNanoseconds
        logger.info(
            "pngquant bitmap \(image.width, privacy: .public)x\(image.height, privacy: .public): hand-off \(Double(pamWrittenAt &- startedAt) / 1_000_000, format: .fixed(precision: 1), privacy: .public) ms, tool \(Double(toolFinishedAt &- pamWrittenAt) / 1_000_000, format: .fixed(precision: 1), privacy: .public) ms, exit \(result.terminationStatus, privacy: .public)"
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

    /// Bytes of the PAM header written before the pixels; padded so the pixel rows start on a
    /// 64-byte boundary, which keeps Core Graphics on its fast blit path.
    static func pamHeader(width: Int, height: Int) -> Data {
        let fields = "P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\n"
        let trailer = "ENDHDR\n"
        let minimalLength = fields.utf8.count + 2 + trailer.utf8.count // "#\n" comment carries the padding
        let padding = (64 - minimalLength % 64) % 64
        return Data((fields + "#" + String(repeating: " ", count: padding) + "\n" + trailer).utf8)
    }

    /// Flattens `image` on white into an 8-bit RGBA PAM file at `url`. The file is preallocated and
    /// memory-mapped so the bitmap is drawn straight into the page cache without a second copy.
    static func writePAM(_ image: CGImage, to url: URL) throws {
        let width = image.width
        let height = image.height
        let header = pamHeader(width: width, height: height)
        let (rowBytes, rowOverflow) = width.multipliedReportingOverflow(by: 4)
        let (pixelBytes, pixelOverflow) = rowBytes.multipliedReportingOverflow(by: height)
        guard width > 0, height > 0, !rowOverflow, !pixelOverflow, pixelBytes <= Int(Int32.max) * 4 else {
            throw PngquantError.invalidBitmap(width: width, height: height)
        }
        let totalBytes = header.count + pixelBytes

        let fd = open(url.path, O_RDWR | O_CREAT | O_TRUNC, 0o600)
        guard fd >= 0 else { throw posixError("open") }
        defer { close(fd) }

        // Reserve the blocks up front so a full disk surfaces here as an error instead of a SIGBUS while drawing.
        var store = fstore_t(
            fst_flags: UInt32(F_ALLOCATEALL),
            fst_posmode: F_PEOFPOSMODE,
            fst_offset: 0,
            fst_length: off_t(totalBytes),
            fst_bytesalloc: 0
        )
        guard fcntl(fd, F_PREALLOCATE, &store) != -1 else { throw posixError("preallocate") }
        guard ftruncate(fd, off_t(totalBytes)) == 0 else { throw posixError("ftruncate") }

        guard let base = mmap(nil, totalBytes, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0), base != MAP_FAILED else {
            throw posixError("mmap")
        }
        defer { munmap(base, totalBytes) }

        header.withUnsafeBytes { bytes in
            base.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        }
        guard let context = CGContext(
            data: base.advanced(by: header.count),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: rowBytes,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PngquantError.invalidBitmap(width: width, height: height)
        }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(bounds)
        context.draw(image, in: bounds)
    }

    private static func posixError(_ operation: String, code: Int32 = errno) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(code),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(code)))"]
        )
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

    /// Quantizes a bitmap, or returns `nil` when pngquant declined or failed so the caller can encode it itself.
    public static func compressBitmapBestEffort(_ image: CGImage, options: Options) -> Data? {
        do {
            return try compressBitmap(image, options: options)
        } catch {
            logger.warning("pngquant bitmap skipped: \(error.localizedDescription, privacy: .public)")
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
