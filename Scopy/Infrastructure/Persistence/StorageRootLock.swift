import Darwin
import Foundation
import os

/// Cross-process single-writer guard for a storage root.
///
/// The first acquisition in a process opens `<root>/.scopy-writer.lock` and takes a non-blocking
/// exclusive `flock`. Later acquisitions of the same root in this process share that descriptor, so
/// an in-process restart (Retry, tests) can reacquire it. The kernel drops the lock when the last
/// holder closes the descriptor or the process exits.
final class StorageRootLock: Sendable {
    struct HeldByAnotherProcess: LocalizedError, Equatable {
        let rootPath: String

        var errorDescription: String? {
            "Another Scopy instance is already using the data folder at \(rootPath). Quit the other instance, then retry."
        }
    }

    static let lockFileName = ".scopy-writer.lock"

    private struct Holder {
        let descriptor: Int32
        var count: Int
    }

    private static let holders = OSAllocatedUnfairLock<[String: Holder]>(initialState: [:])

    private let rootPath: String
    private let isReleased = OSAllocatedUnfairLock(initialState: false)

    private init(rootPath: String) {
        self.rootPath = rootPath
    }

    deinit {
        release()
    }

    static func acquire(root: URL) throws -> StorageRootLock {
        let rootPath = root.standardizedFileURL.path
        try holders.withLock { holders in
            if var holder = holders[rootPath] {
                holder.count += 1
                holders[rootPath] = holder
                return
            }
            try FileManager.default.createDirectory(atPath: rootPath, withIntermediateDirectories: true)
            let descriptor = try lockFile(atPath: (rootPath as NSString).appendingPathComponent(lockFileName))
            holders[rootPath] = Holder(descriptor: descriptor, count: 1)
        }
        return StorageRootLock(rootPath: rootPath)
    }

    /// Opens `path` and takes a non-blocking exclusive `flock` on the new open file description.
    /// The returned descriptor holds the lock until it is closed.
    static func lockFile(atPath path: String) throws -> Int32 {
        let descriptor = open(path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            close(descriptor)
            if code == EWOULDBLOCK {
                throw HeldByAnotherProcess(rootPath: (path as NSString).deletingLastPathComponent)
            }
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        return descriptor
    }

    /// Idempotent; the descriptor closes when the process's last holder releases.
    func release() {
        let alreadyReleased = isReleased.withLock { released in
            defer { released = true }
            return released
        }
        guard !alreadyReleased else { return }
        let rootPath = rootPath
        Self.holders.withLock { holders in
            guard var holder = holders[rootPath] else { return }
            holder.count -= 1
            if holder.count > 0 {
                holders[rootPath] = holder
            } else {
                close(holder.descriptor)
                holders.removeValue(forKey: rootPath)
            }
        }
    }
}
