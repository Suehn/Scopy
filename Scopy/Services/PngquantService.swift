import Foundation
import os

public enum PngquantService {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "Scopy", category: "pngquant")

    public struct Options: Sendable, Equatable {
        public var binaryPath: String
        public var qualityMin: Int
        public var qualityMax: Int
        public var speed: Int
        public var colors: Int

        public init(
            binaryPath: String,
            qualityMin: Int,
            qualityMax: Int,
            speed: Int,
            colors: Int
        ) {
            self.binaryPath = binaryPath
            self.qualityMin = qualityMin
            self.qualityMax = qualityMax
            self.speed = speed
            self.colors = colors
        }
    }

    enum PngquantError: LocalizedError {
        case binaryNotFound
        case binaryNotExecutable(path: String)
        case failed(exitCode: Int32, stderr: String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound:
                return "pngquant not found"
            case .binaryNotExecutable(let path):
                return "pngquant is not executable: \(path)"
            case .failed(let exitCode, let stderr):
                if stderr.isEmpty {
                    return "pngquant failed with exit code \(exitCode)"
                }
                return "pngquant failed with exit code \(exitCode): \(stderr)"
            }
        }
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

    static func compressPNGData(_ pngData: Data, options: Options) throws -> Data {
        guard isLikelyPNG(pngData) else { return pngData }

        let binary = try resolveBinaryPath(preferredPath: options.binaryPath)
        let minQ = max(0, min(100, options.qualityMin))
        let maxQ = max(0, min(100, options.qualityMax))
        let qualityMin = min(minQ, maxQ)
        let qualityMax = max(minQ, maxQ)
        let speed = max(1, min(11, options.speed))
        let colors = max(2, min(256, options.colors))

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--quality", "\(qualityMin)-\(qualityMax)",
            "--speed", "\(speed)",
            "--skip-if-larger",
            "--strip",
            "\(colors)",
            "-"
        ]

        let inputPipe = Pipe()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardInput = inputPipe
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw PngquantError.failed(exitCode: -1, stderr: error.localizedDescription)
        }

        inputPipe.fileHandleForWriting.write(pngData)
        inputPipe.fileHandleForWriting.closeFile()

        let outData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let exit = process.terminationStatus
        if exit == 0 || exit == 99 {
            if outData.isEmpty {
                return pngData
            }
            return outData
        }

        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw PngquantError.failed(exitCode: exit, stderr: stderr)
    }

    static func compressPNGFileInPlace(_ fileURL: URL, options: Options) throws -> Bool {
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

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = [
            "--quality", "\(qualityMin)-\(qualityMax)",
            "--speed", "\(speed)",
            "--skip-if-larger",
            "--strip",
            "--output", tmpPath,
            "\(colors)",
            "--",
            originalPath
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        do {
            try process.run()
        } catch {
            throw PngquantError.failed(exitCode: -1, stderr: error.localizedDescription)
        }

        let errData = errorPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let exit = process.terminationStatus
        if exit == 0 {
            guard FileManager.default.fileExists(atPath: tmpPath) else { return false }
            let originalURL = URL(fileURLWithPath: originalPath)
            do {
                if FileManager.default.fileExists(atPath: originalPath) {
                    try FileManager.default.removeItem(at: originalURL)
                }
                try FileManager.default.moveItem(at: tmpURL, to: originalURL)
                return true
            } catch {
                try? FileManager.default.removeItem(at: tmpURL)
                throw PngquantError.failed(exitCode: -1, stderr: error.localizedDescription)
            }
        }

        if exit == 99 {
            // Quality below min; pngquant won't save output file.
            try? FileManager.default.removeItem(at: tmpURL)
            return false
        }

        let stderr = String(data: errData, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        throw PngquantError.failed(exitCode: exit, stderr: stderr)
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
