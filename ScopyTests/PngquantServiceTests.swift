import Foundation
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

    func testStdinModeTimesOutWithoutPipeDeadlock() throws {
        let binary = try makeExecutable(
            named: "hang-stdin",
            script: Self.hangingScript
        )
        let startedAt = Date()

        XCTAssertThrowsError(
            try PngquantService.compressPNGData(
                Self.pngData,
                options: options(binary: binary, timeout: 0.1)
            )
        ) { error in
            guard case PngquantService.PngquantError.timedOut(let timeout) = error else {
                return XCTFail("Expected typed timeout, got \(error)")
            }
            XCTAssertEqual(timeout, 0.1, accuracy: 0.001)
        }
        XCTAssertLessThan(Date().timeIntervalSince(startedAt), 2)
    }

    func testFileModeTimeoutTerminatesProcessAndRemovesPartialOutput() throws {
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

        XCTAssertThrowsError(
            try PngquantService.compressPNGFileInPlace(
                imageURL,
                options: options(binary: binary, timeout: 0.1)
            )
        ) { error in
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
            /usr/bin/touch "$0.started"
            trap 'exit 0' TERM
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
    }

    func testLargeStderrDoesNotBlockSuccessfulStdoutCollection() throws {
        let binary = try makeExecutable(
            named: "large-stderr",
            script: """
            #!/bin/sh
            /bin/cat >/dev/null
            /usr/bin/head -c 262144 /dev/zero >&2
            /usr/bin/printf '\\211PNG\\r\\n\\032\\n'
            """
        )

        let output = try PngquantService.compressPNGData(
            Self.pngData,
            options: options(binary: binary, timeout: 2)
        )

        XCTAssertEqual(output, Data(Self.pngData.prefix(8)))
    }

    func testExit98And99PreserveNoChangeSemanticsForStdinAndFileModes() throws {
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

            XCTAssertEqual(
                try PngquantService.compressPNGData(Self.pngData, options: configured),
                Self.pngData,
                "Exit \(exitCode) must ignore re-encoded stdout bytes"
            )

            let imageURL = directory.appendingPathComponent("unchanged-\(exitCode).png")
            try Self.pngData.write(to: imageURL)
            XCTAssertFalse(try PngquantService.compressPNGFileInPlace(imageURL, options: configured))
            XCTAssertEqual(try Data(contentsOf: imageURL), Self.pngData)
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            XCTAssertFalse(names.contains(where: { $0.hasPrefix("unchanged-\(exitCode).png.pngquant-") }))
        }
    }

    func testFileModeAtomicallyReplacesOriginalOnSuccess() throws {
        let replacementData = Data(Self.pngData.prefix(16))
        let binary = try makeFileModeExecutable(
            named: "successful-file-output",
            replacementData: replacementData
        )
        let imageURL = directory.appendingPathComponent("replace-success.png")
        try Self.pngData.write(to: imageURL)

        XCTAssertTrue(
            try PngquantService.compressPNGFileInPlace(
                imageURL,
                options: options(binary: binary, timeout: 2)
            )
        )

        XCTAssertEqual(try Data(contentsOf: imageURL), replacementData)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains(".pngquant-") }))
    }

    func testFileModeReplacementFailurePreservesOriginalAndCleansTemporaryOutput() throws {
        let binary = try makeFileModeExecutable(
            named: "failed-file-replacement",
            replacementData: Data(Self.pngData.prefix(16))
        )
        let imageURL = directory.appendingPathComponent("replace-failure.png")
        try Self.pngData.write(to: imageURL)

        XCTAssertThrowsError(
            try PngquantService.compressPNGFileInPlace(
                imageURL,
                options: options(binary: binary, timeout: 2),
                replaceOutputAtomically: { _, _ in
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))
                }
            )
        ) { error in
            guard case PngquantService.PngquantError.failed(let exitCode, _) = error else {
                return XCTFail("Expected typed replacement failure, got \(error)")
            }
            XCTAssertEqual(exitCode, -1)
        }

        XCTAssertEqual(try Data(contentsOf: imageURL), Self.pngData)
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(names.contains(where: { $0.contains(".pngquant-") }))
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
            try PngquantService.compressPNGData(pngData, options: options)
        }
    }

    private static let pngData = Data(
        [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A] +
            Array(repeating: 0xA5, count: 512)
    )

    private static let hangingScript = """
    #!/bin/sh
    trap 'exit 0' TERM
    while :; do :; done
    """
}
