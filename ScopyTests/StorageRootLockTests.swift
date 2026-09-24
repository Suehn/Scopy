import Darwin
import XCTest
@testable import ScopyKit

final class StorageRootLockTests: XCTestCase {
    /// Two independent open file descriptions stand in for two processes: `flock` must refuse the second.
    func testSecondOpenFileDescriptionCannotAcquire() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("StorageRootLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent(StorageRootLock.lockFileName).path

        let first = try StorageRootLock.lockFile(atPath: path)
        XCTAssertThrowsError(try StorageRootLock.lockFile(atPath: path)) { error in
            XCTAssertEqual(error as? StorageRootLock.HeldByAnotherProcess, .init(rootPath: root.path))
        }

        close(first)
        let reacquired = try StorageRootLock.lockFile(atPath: path)
        close(reacquired)
    }
}
