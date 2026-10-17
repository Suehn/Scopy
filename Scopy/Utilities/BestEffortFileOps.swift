import Foundation
import os

enum BestEffortFileOps {
    static func removeItem(
        at url: URL,
        logger: Logger,
        operation: String,
        itemID: UUID? = nil
    ) {
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            logFailure(
                logger: logger,
                operation: operation,
                action: "remove",
                path: url.path,
                itemID: itemID,
                error: error
            )
        }
    }

    static func removeItem(
        atPath path: String,
        logger: Logger,
        operation: String,
        itemID: UUID? = nil
    ) {
        removeItem(at: URL(fileURLWithPath: path), logger: logger, operation: operation, itemID: itemID)
    }

    static func moveItem(
        from sourceURL: URL,
        to destinationURL: URL,
        logger: Logger,
        operation: String,
        itemID: UUID? = nil
    ) {
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
        } catch {
            logFailure(
                logger: logger,
                operation: operation,
                action: "move",
                path: "\(sourceURL.path) -> \(destinationURL.path)",
                itemID: itemID,
                error: error
            )
        }
    }

    private static func logFailure(
        logger: Logger,
        operation: String,
        action: String,
        path: String,
        itemID: UUID?,
        error: Error
    ) {
        if let itemID {
            logger.warning(
                "[\(operation, privacy: .public)] Failed to \(action, privacy: .public) '\(path, privacy: .private)' for item \(itemID.uuidString, privacy: .private): \(error.localizedDescription, privacy: .private)"
            )
        } else {
            logger.warning(
                "[\(operation, privacy: .public)] Failed to \(action, privacy: .public) '\(path, privacy: .private)': \(error.localizedDescription, privacy: .private)"
            )
        }
    }
}
