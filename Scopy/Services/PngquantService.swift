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

    private struct ProcessResult {
        let terminationStatus: Int32
        let stdout: Data
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

    static func compressPNGData(_ pngData: Data, options: Options) throws -> Data {
        guard isLikelyPNG(pngData) else { return pngData }

        let binary = try resolveBinaryPath(preferredPath: options.binaryPath)
        let minQ = max(0, min(100, options.qualityMin))
        let maxQ = max(0, min(100, options.qualityMax))
        let qualityMin = min(minQ, maxQ)
        let qualityMax = max(minQ, maxQ)
        let speed = max(1, min(11, options.speed))
        let colors = max(2, min(256, options.colors))

        let result = try runProcess(
            executablePath: binary,
            arguments: [
            "--quality", "\(qualityMin)-\(qualityMax)",
            "--speed", "\(speed)",
            "--skip-if-larger",
            "--strip",
            "\(colors)",
            "-"
            ],
            standardInputData: pngData,
            timeoutSeconds: options.processTimeoutSeconds
        )

        let exit = result.terminationStatus
        if exit == 98 || exit == 99 {
            // In stdout mode pngquant may re-encode the 24-bit original for these no-change
            // exits. Always preserve the caller's exact bytes so this cannot look optimized.
            return pngData
        }
        if exit == 0 {
            guard !result.stdout.isEmpty else { return pngData }
            return result.stdout
        }

        let stderr = stderrText(result.stderr)
        throw PngquantError.failed(exitCode: exit, stderr: stderr)
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

        let minQ = max(0, min(100, options.qualityMin))
        let maxQ = max(0, min(100, options.qualityMax))
        let qualityMin = min(minQ, maxQ)
        let qualityMax = max(minQ, maxQ)
        let speed = max(1, min(11, options.speed))
        let colors = max(2, min(256, options.colors))

        let tmpPath = originalPath + ".pngquant-\(UUID().uuidString).tmp"
        let tmpURL = URL(fileURLWithPath: tmpPath)
        if FileManager.default.fileExists(atPath: tmpPath) {
            try? FileManager.default.removeItem(at: tmpURL)
        }
        defer {
            try? FileManager.default.removeItem(at: tmpURL)
        }

        let result = try runProcess(
            executablePath: binary,
            arguments: [
                "--quality", "\(qualityMin)-\(qualityMax)",
                "--speed", "\(speed)",
                "--skip-if-larger",
                "--strip",
                "--output", tmpPath,
                "\(colors)",
                "--",
                originalPath
            ],
            standardInputData: nil,
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

        if exit == 98 || exit == 99 {
            // 98: --skip-if-larger; 99: quality below min. Neither replaces the source.
            return false
        }

        let stderr = stderrText(result.stderr)
        throw PngquantError.failed(exitCode: exit, stderr: stderr)
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

    private static func runProcess(
        executablePath: String,
        arguments: [String],
        standardInputData: Data?,
        timeoutSeconds requestedTimeoutSeconds: TimeInterval
    ) throws -> ProcessResult {
        guard !Task.isCancelled else { throw PngquantError.cancelled }

        let timeoutSeconds = effectiveProcessTimeout(requestedTimeoutSeconds)
        let ioDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scopy-pngquant-io-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: ioDirectory, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: ioDirectory)
        }

        let stdoutURL = ioDirectory.appendingPathComponent("stdout")
        let stderrURL = ioDirectory.appendingPathComponent("stderr")
        try Data().write(to: stdoutURL, options: .atomic)
        try Data().write(to: stderrURL, options: .atomic)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        var inputHandle: FileHandle?
        defer {
            try? inputHandle?.close()
            try? stdoutHandle.close()
            try? stderrHandle.close()
        }

        if let standardInputData {
            let stdinURL = ioDirectory.appendingPathComponent("stdin")
            try standardInputData.write(to: stdinURL, options: .atomic)
            inputHandle = try FileHandle(forReadingFrom: stdinURL)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardInput = inputHandle
        process.standardOutput = stdoutHandle
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
            Thread.sleep(forTimeInterval: 0.01)
        }
        process.waitUntilExit()

        try? inputHandle?.close()
        inputHandle = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()

        return ProcessResult(
            terminationStatus: process.terminationStatus,
            stdout: (try? Data(contentsOf: stdoutURL)) ?? Data(),
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
