import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest

@testable import ScopyKit

final class PngquantServiceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "scopy-pngquant-tests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
        directory = nil
        try super.tearDownWithError()
    }

    func testDataModeTimesOutWithoutDeadlock() async throws {
        let binary = try makeExecutable(
            named: "hang-stdin",
            script: Self.hangingScript
        )
        let startedAt = Date()

        await expectError({
            try await PngquantService.compressPNGData(
                Self.pngData,
                options: options(binary: binary, timeout: 0.1)
            )
        }) { error in
            guard case PngquantService.PngquantError.timedOut(let timeout) = error else {
                return XCTFail("Expected typed timeout, got \(error)")
            }
            XCTAssertEqual(timeout, 0.1, accuracy: 0.001)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testFileModeTimeoutTerminatesProcessAndRemovesPartialOutput() async throws {
        let binary = try makeExecutable(
            named: "hang-file",
            script: """
            #!/bin/sh
            output=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--output" ]; then
                    shift
                    output="$1"
                fi
                shift
            done
            [ -n "$output" ] && /usr/bin/printf partial > "$output"
            trap 'exit 0' TERM
            while :; do :; done
            """
        )
        let imageURL = directory.appendingPathComponent("source.png")
        try Self.pngData.write(to: imageURL)

        await expectError({
            try await PngquantService.compressPNGFileInPlace(
                imageURL,
                options: options(binary: binary, timeout: 0.1)
            )
        }) { error in
            guard case PngquantService.PngquantError.timedOut = error else {
                return XCTFail("Expected typed timeout, got \(error)")
            }
        }

        XCTAssertEqual(try Data(contentsOf: imageURL), Self.pngData)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains(".pngquant-") }))
    }

    func testCancellationTerminatesRunningProcessAndSurfacesTypedError() async throws {
        let binary = try makeExecutable(
            named: "cancel-stdin",
            script: """
            #!/bin/sh
            input=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--" ]; then shift; input="$1"; fi
                shift
            done
            /usr/bin/printf '%s' "$$" > "$0.pid"
            /usr/bin/printf '%s' "$input" > "$0.input"
            trap '[ -f "$input" ] && /usr/bin/touch "$0.input-survived"; exit 0' TERM
            /usr/bin/touch "$0.started"
            while :; do :; done
            """
        )
        let startedMarker = URL(fileURLWithPath: binary.path + ".started")
        let configured = options(binary: binary, timeout: 60)
        let task = Self.startCompressionTask(options: configured)

        try await waitForFile(startedMarker)
        let cancelledAt = Date()
        task.cancel()

        switch await task.result {
        case .success:
            XCTFail("Expected cancellation")
        case .failure(let error):
            guard case PngquantService.PngquantError.cancelled = error else {
                return XCTFail("Expected typed cancellation, got \(error)")
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(cancelledAt), 2)
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: binary.path + ".pid", encoding: .utf8)))
        XCTAssertEqual(Darwin.kill(pid, 0), -1, "returning cancellation must mean the child has exited")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertTrue(FileManager.default.fileExists(atPath: binary.path + ".input-survived"))
        let input = try String(contentsOfFile: binary.path + ".input", encoding: .utf8)
        XCTAssertFalse(FileManager.default.fileExists(atPath: input), "scratch input is removed after exit")
    }

    func testCancellationKillsProcessThatIgnoresTermination() async throws {
        let binary = try makeExecutable(named: "ignore-term", script: """
        #!/bin/sh
        trap '' TERM
        /usr/bin/printf '%s' "$$" > "$0.pid"
        while :; do :; done
        """)
        let task = Self.startCompressionTask(options: options(binary: binary, timeout: 60))
        try await waitForFile(URL(fileURLWithPath: binary.path + ".pid"))
        let pid = try XCTUnwrap(Int32(String(contentsOfFile: binary.path + ".pid", encoding: .utf8)))
        task.cancel()
        await expectError({ try await task.value }) { error in
            guard case PngquantService.PngquantError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
        XCTAssertEqual(Darwin.kill(pid, 0), -1)
        XCTAssertEqual(errno, ESRCH)
    }

    func testAlreadyCancelledTaskNeverLaunchesProcess() async throws {
        let binary = try makeExecutable(named: "must-not-start", script: "#!/bin/sh\n/usr/bin/touch \"$0.started\"\n")
        let configured = options(binary: binary, timeout: 2)
        let pngData = Self.pngData
        let task = Task.detached(priority: .utility) {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return try await PngquantService.compressPNGData(pngData, options: configured)
        }
        task.cancel()
        await expectError({ try await task.value }) { error in
            guard case PngquantService.PngquantError.cancelled = error else {
                return XCTFail("Expected cancellation, got \(error)")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: binary.path + ".started"))
    }

    func testLargeStderrDoesNotBlockSuccessfulOutputCollection() async throws {
        let binary = try makeExecutable(
            named: "large-stderr",
            script: """
            #!/bin/sh
            output=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--output" ]; then
                    shift
                    output="$1"
                fi
                shift
            done
            /usr/bin/head -c 262144 /dev/zero >&2
            /usr/bin/printf '\\211PNG\\r\\n\\032\\n' > "$output"
            """
        )
        let output = try await PngquantService.compressPNGData(
            Self.pngData,
            options: options(binary: binary, timeout: 2)
        )
        XCTAssertEqual(output, Data(Self.pngData.prefix(8)))
    }

    func testDataModePassesInputFileAndCollectsOutputFile() async throws {
        let binary = try makeExecutable(
            named: "copy-input",
            script: """
            #!/bin/sh
            output=""
            input=""
            while [ "$#" -gt 0 ]; do
                case "$1" in
                    --output) shift; output="$1" ;;
                    --) shift; input="$1" ;;
                esac
                shift
            done
            /bin/cp "$input" "$output"
            """
        )
        let output = try await PngquantService.compressPNGData(
            Self.pngData,
            options: options(binary: binary, timeout: 2)
        )
        XCTAssertEqual(output, Self.pngData)
    }

    func testPAMHeaderHasFixedLengthAndParsableFields() {
        for (width, height) in [(1, 1), (2160, 29511), (1_000_000, 7)] {
            let header = PngquantService.pamHeader(width: width, height: height)
            XCTAssertEqual(header.count, PngquantService.pamHeaderLength, "\(width)x\(height)")
            let text = String(decoding: header, as: UTF8.self)
            XCTAssertTrue(text.hasPrefix("P7\nWIDTH \(width)\nHEIGHT \(height)\nDEPTH 4\nMAXVAL 255\nTUPLTYPE RGB_ALPHA\n#"))
            XCTAssertTrue(text.hasSuffix("\nENDHDR\n"))
        }
    }

    func testPAMFileRoundTripsThroughBundledPngquant() async throws {
        let bundled = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Scopy/Resources/Tools/pngquant")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: bundled.path), "bundled pngquant not present")
        let image = try Self.flattenedOnWhite(try Self.makeTestImage(width: 64, height: 48))
        let pixels = Self.rgba(of: image)
        var pam = PngquantService.pamHeader(width: 64, height: 48)
        pam.append(contentsOf: pixels)
        let url = directory.appendingPathComponent("bitmap.pam")
        try pam.write(to: url)

        let result = try await PngquantService.compressPAMFile(url, options: options(binary: bundled, timeout: 10))
        let png = try XCTUnwrap(result)
        XCTAssertTrue(PngquantService.isLikelyPNG(png))

        let source = try XCTUnwrap(CGImageSourceCreateWithData(png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, 64)
        XCTAssertEqual(decoded.height, 48)
        XCTAssertEqual(Self.rgba(of: decoded), pixels)
    }

    func testExit98And99PreserveNoChangeSemanticsForStdinAndFileModes() async throws {
        for exitCode in [98, 99] {
            let binary = try makeExecutable(
                named: "exit-\(exitCode)",
                script: """
                #!/bin/sh
                output=""
                while [ "$#" -gt 0 ]; do
                    if [ "$1" = "--output" ]; then
                        shift
                        output="$1"
                    fi
                    shift
                done
                if [ -n "$output" ]; then
                    /usr/bin/printf partial > "$output"
                else
                    /usr/bin/printf '\\211PNG\\r\\n\\032\\nDIFFERENT'
                fi
                exit \(exitCode)
                """
            )
            let configured = options(binary: binary, timeout: 2)

            let output = try await PngquantService.compressPNGData(Self.pngData, options: configured)
            XCTAssertEqual(output, Self.pngData, "Exit \(exitCode) must ignore re-encoded stdout bytes")

            let imageURL = directory.appendingPathComponent("unchanged-\(exitCode).png")
            try Self.pngData.write(to: imageURL)
            let replaced = try await PngquantService.compressPNGFileInPlace(imageURL, options: configured)
            XCTAssertFalse(replaced)
            XCTAssertEqual(try Data(contentsOf: imageURL), Self.pngData)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(names.contains(where: { $0.hasPrefix("unchanged-\(exitCode).png.pngquant-") }))
        }
    }

    func testFileModeAtomicallyReplacesOriginalOnSuccess() async throws {
        let replacementData = Data(Self.pngData.prefix(16))
        let binary = try makeFileModeExecutable(
            named: "successful-file-output",
            replacementData: replacementData
        )
        let imageURL = directory.appendingPathComponent("replace-success.png")
        try Self.pngData.write(to: imageURL)

        let replaced = try await PngquantService.compressPNGFileInPlace(
            imageURL,
            options: options(binary: binary, timeout: 2)
        )
        XCTAssertTrue(replaced)

        XCTAssertEqual(try Data(contentsOf: imageURL), replacementData)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains(".pngquant-") }))
    }

    func testSeparateFileOutputPreservesInputAndRejectsEmptyOrNonRegularOutput() async throws {
        let input = directory.appendingPathComponent("immutable.png")
        try Self.pngData.write(to: input)
        let replacement = Data(Self.pngData.prefix(16))
        let successful = try makeFileModeExecutable(named: "separate-output", replacementData: replacement)
        let output = directory.appendingPathComponent("compressed.png")
        let created = try await PngquantService.compressPNGFile(input, to: output, options: options(binary: successful, timeout: 2))
        XCTAssertTrue(created)
        XCTAssertEqual(try Data(contentsOf: input), Self.pngData)
        XCTAssertEqual(try Data(contentsOf: output), replacement)

        for (name, command) in [("empty", ": > \"$output\""), ("directory", "/bin/mkdir \"$output\""), ("symlink", "/bin/ln -s \"$0\" \"$output\"")] {
            let binary = try makeExecutable(named: name, script: """
            #!/bin/sh
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--output" ]; then shift; output="$1"; fi
                shift
            done
            \(command)
            """)
            let invalidOutput = directory.appendingPathComponent(name + ".png")
            let created = try await PngquantService.compressPNGFile(input, to: invalidOutput, options: options(binary: binary, timeout: 2))
            XCTAssertFalse(created, name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: invalidOutput.path), name)
            XCTAssertEqual(try Data(contentsOf: input), Self.pngData)
        }
    }

    func testFileModeReplacementFailurePreservesOriginalAndCleansTemporaryOutput() async throws {
        let binary = try makeFileModeExecutable(
            named: "failed-file-replacement",
            replacementData: Data(Self.pngData.prefix(16))
        )
        let imageURL = directory.appendingPathComponent("replace-failure.png")
        try Self.pngData.write(to: imageURL)

        await expectError({
            try await PngquantService.compressPNGFileInPlace(
                imageURL,
                options: options(binary: binary, timeout: 2),
                replaceOutputAtomically: { _, _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
            )
        }) { error in
            guard case PngquantService.PngquantError.failed(let exitCode, _) = error else {
                return XCTFail("Expected typed replacement failure, got \(error)")
            }
            XCTAssertEqual(exitCode, -1)
        }

        XCTAssertEqual(try Data(contentsOf: imageURL), Self.pngData)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains(".pngquant-") }))
    }

    private func expectError<T>(_ operation: () async throws -> T, verify: (Error) -> Void) async {
        do {
            _ = try await operation()
            XCTFail("Expected operation to fail")
        } catch {
            verify(error)
        }
    }

    private func makeExecutable(named name: String, script: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: url.path
        )
        return url
    }

    private func makeFileModeExecutable(
        named name: String,
        replacementData: Data
    ) throws -> URL {
        let executable = try makeExecutable(
            named: name,
            script: """
            #!/bin/sh
            output=""
            while [ "$#" -gt 0 ]; do
                if [ "$1" = "--output" ]; then
                    shift
                    output="$1"
                fi
                shift
            done
            /bin/cp "$0.replacement" "$output"
            """
        )
        try replacementData.write(to: URL(fileURLWithPath: executable.path + ".replacement"))
        return executable
    }

    private func options(binary: URL, timeout: TimeInterval) -> PngquantService.Options {
        PngquantService.Options(
            binaryPath: binary.path,
            qualityMin: 50,
            qualityMax: 80,
            speed: 3,
            colors: 128,
            processTimeoutSeconds: timeout
        )
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 2) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            guard Date() < deadline else {
                throw NSError(
                    domain: "PngquantServiceTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(url.lastPathComponent)"]
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    private static func startCompressionTask(
        options: PngquantService.Options
    ) -> Task<Data, Error> {
        Task.detached(priority: .utility) {
            try await PngquantService.compressPNGData(pngData, options: options)
        }
    }

    /// Top third opaque red, middle third half-transparent blue, bottom third fully transparent.
    private static func makeTestImage(width: Int, height: Int) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let band = CGFloat(height) / 3
        let deviceRGB = CGColorSpaceCreateDeviceRGB()
        ctx.setFillColor(try XCTUnwrap(CGColor(colorSpace: deviceRGB, components: [0, 0, 1, 0.5])))
        ctx.fill(CGRect(x: 0, y: band, width: CGFloat(width), height: band))
        ctx.setFillColor(try XCTUnwrap(CGColor(colorSpace: deviceRGB, components: [1, 0, 0, 1])))
        ctx.fill(CGRect(x: 0, y: 2 * band, width: CGFloat(width), height: band))
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func flattenedOnWhite(_ image: CGImage) throws -> CGImage {
        let ctx = try XCTUnwrap(CGContext(
            data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(bounds)
        ctx.draw(image, in: bounds)
        return try XCTUnwrap(ctx.makeImage())
    }

    private static func rgba(of image: CGImage) -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        pixels.withUnsafeMutableBytes { buffer in
            let ctx = CGContext(
                data: buffer.baseAddress, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    nonisolated private static let pngData = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] +
            Array(repeating: 0xA5, count: 512)
    )

    private static let hangingScript = """
    #!/bin/sh
    trap 'exit 0' TERM
    while :; do :; done
    """
}
