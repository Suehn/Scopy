import AppKit
import XCTest

@testable import ScopyKit

private actor ImageOptimizationInterlockGate {
    private var isPaused = false
    private var arrivalWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func pause() async {
        isPaused = true
        let waiters = arrivalWaiters
        arrivalWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }
        await withCheckedContinuation { continuation in
            releaseWaiter = continuation
        }
    }

    func waitUntilPaused() async {
        if isPaused { return }
        await withCheckedContinuation { continuation in
            arrivalWaiters.append(continuation)
        }
    }

    func release() {
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
final class ClipboardServiceImageOptimizationTests: XCTestCase {
    private struct Fixture {
        let service: ClipboardService
        let itemID: UUID
        let originalData: Data
        let originalHash: String
        let databasePath: String
        let storageRef: String?
        let compressorURL: URL

        var compressorReadyURL: URL {
            URL(fileURLWithPath: compressorURL.path + ".ready")
        }

        var compressorGateURL: URL {
            URL(fileURLWithPath: compressorURL.path + ".continue")
        }
    }

    private var service: ClipboardService?
    private var tempDirectory: URL?
    private var settingsSuiteName: String?

    override func tearDown() async throws {
        if let service {
            await service.stop()
        }
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        if let settingsSuiteName {
            UserDefaults.standard.removePersistentDomain(forName: settingsSuiteName)
        }

        service = nil
        tempDirectory = nil
        settingsSuiteName = nil
        try await super.tearDown()
    }

    func testSuccessfulOptimizationProofMatchesPersistedAndEmittedHash() async throws {
        let fixture = try await startFixture(
            compressorScript: """
            #!/bin/sh
            tmp="${TMPDIR:-/tmp}/scopy-pngquant-$$"
            trap '/bin/rm -f "$tmp"' EXIT
            /bin/cat > "$tmp"
            /bin/dd if="$tmp" bs=1 count=8 2>/dev/null
            """
        )
        let contentUpdated = expectation(description: "optimized content event")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                contentUpdated.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let outcome = try await fixture.service.optimizeImage(itemID: fixture.itemID)
        await fulfillment(of: [contentUpdated], timeout: 2)

        XCTAssertEqual(outcome.result, .optimized)
        let resultingHash = try XCTUnwrap(outcome.resultingContentHash)
        let expectedData = Data(fixture.originalData.prefix(8))
        XCTAssertEqual(resultingHash, ClipboardMonitor.computeHashStatic(expectedData))
        XCTAssertEqual(outcome.optimizedBytes, expectedData.count)

        let persistedItems = try await fixture.service.fetchRecent(limit: 10, offset: 0)
        let persistedItem = try XCTUnwrap(
            persistedItems.first(where: { $0.id == fixture.itemID })
        )
        XCTAssertEqual(persistedItem.contentHash, resultingHash)
        XCTAssertEqual(persistedItem.sizeBytes, outcome.optimizedBytes)
        XCTAssertEqual(emittedItem?.contentHash, resultingHash)
        XCTAssertEqual(emittedItem?.sizeBytes, outcome.optimizedBytes)
    }

    func testNoChangeOutcomeHasNoResultingContentProof() async throws {
        let fixture = try await startFixture(
            compressorScript: """
            #!/bin/sh
            /bin/cat
            """
        )

        let outcome = try await fixture.service.optimizeImage(itemID: fixture.itemID)

        XCTAssertEqual(outcome.result, .noChange)
        XCTAssertNil(outcome.resultingContentHash)
        let persistedItems = try await fixture.service.fetchRecent(limit: 10, offset: 0)
        let persistedItem = try XCTUnwrap(
            persistedItems.first(where: { $0.id == fixture.itemID })
        )
        XCTAssertEqual(persistedItem.contentHash, fixture.originalHash)
    }

    func testFailedOutcomeHasNoResultingContentProof() async throws {
        let fixture = try await startFixture(
            compressorScript: """
            #!/bin/sh
            /bin/cat >/dev/null
            exit 17
            """
        )

        let outcome = try await fixture.service.optimizeImage(itemID: fixture.itemID)

        guard case .failed = outcome.result else {
            return XCTFail("Expected failed optimization outcome")
        }
        XCTAssertNil(outcome.resultingContentHash)
        let persistedItems = try await fixture.service.fetchRecent(limit: 10, offset: 0)
        let persistedItem = try XCTUnwrap(
            persistedItems.first(where: { $0.id == fixture.itemID })
        )
        XCTAssertEqual(persistedItem.contentHash, fixture.originalHash)
    }

    func testInlineOptimizationLosesSameIDPayloadRaceWithoutPublishingStaleBytes() async throws {
        let fixture = try await startFixture(compressorScript: Self.blockingInlineCompressorScript)
        let noContentUpdate = expectation(description: "no stale content event")
        noContentUpdate.isInverted = true
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                noContentUpdate.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)

        let replacementData = Self.makePNGFixtureData(fillByte: 0x3C)
        let replacementHash = ClipboardMonitor.computeHashStatic(replacementData)
        let competingStorage = StorageService(databasePath: fixture.databasePath)
        try await competingStorage.open()
        try await competingStorage.updateItemPayload(
            id: fixture.itemID,
            contentHash: replacementHash,
            sizeBytes: replacementData.count,
            storageRef: nil,
            rawData: replacementData
        )
        try Data().write(to: fixture.compressorGateURL)

        let outcome = try await optimization.value
        guard case .failed = outcome.result else {
            return XCTFail("Expected stale inline optimization to fail")
        }
        XCTAssertNil(outcome.resultingContentHash)

        let persistedResult = try await competingStorage.findByID(fixture.itemID)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.contentHash, replacementHash)
        XCTAssertEqual(persisted.rawData, replacementData)
        await competingStorage.close()
        await fulfillment(of: [noContentUpdate], timeout: 0.2)
    }

    func testExternalOptimizationLosesSameIDPayloadRaceWithoutMutatingSharedFiles() async throws {
        let originalData = Self.makePNGFixtureData(
            fillByte: 0xA5,
            totalByteCount: StorageService.externalStorageThreshold + 1_024
        )
        let fixture = try await startFixture(
            compressorScript: Self.blockingExternalCompressorScript,
            originalData: originalData
        )
        let originalURL = URL(fileURLWithPath: try XCTUnwrap(fixture.storageRef))
        let noContentUpdate = expectation(description: "no stale external content event")
        noContentUpdate.isInverted = true
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                noContentUpdate.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)

        let replacementData = Self.makePNGFixtureData(fillByte: 0x6D, totalByteCount: originalData.count)
        let replacementHash = ClipboardMonitor.computeHashStatic(replacementData)
        let replacementURL = originalURL.deletingLastPathComponent()
            .appendingPathComponent("\(UUID().uuidString).png")
        XCTAssertTrue(
            StorageService.validateStorageRef(
                replacementURL.path,
                externalStoragePath: originalURL.deletingLastPathComponent().path
            )
        )
        try replacementData.write(to: replacementURL, options: .atomic)

        let competingStorage = StorageService(databasePath: fixture.databasePath)
        try await competingStorage.open()
        try await competingStorage.updateItemPayload(
            id: fixture.itemID,
            contentHash: replacementHash,
            sizeBytes: replacementData.count,
            storageRef: replacementURL.path,
            rawData: nil
        )
        try Data().write(to: fixture.compressorGateURL)

        let outcome = try await optimization.value
        guard case .failed = outcome.result else {
            return XCTFail("Expected stale external optimization to fail")
        }
        XCTAssertNil(outcome.resultingContentHash)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
        XCTAssertEqual(try Data(contentsOf: replacementURL), replacementData)

        let persistedResult = try await competingStorage.findByID(fixture.itemID)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.contentHash, replacementHash)
        XCTAssertEqual(persisted.storageRef, replacementURL.path)
        let remainingNames = try Set(
            FileManager.default.contentsOfDirectory(
                at: originalURL.deletingLastPathComponent(),
                includingPropertiesForKeys: nil
            ).map(\.lastPathComponent)
        )
        XCTAssertEqual(remainingNames, Set([originalURL.lastPathComponent, replacementURL.lastPathComponent]))
        await competingStorage.close()
        await fulfillment(of: [noContentUpdate], timeout: 0.2)
    }

    func testExternalOptimizationPublishesNewImmutableUUIDPayloadAndLeavesOriginalForCleanup() async throws {
        let originalData = Self.makePNGFixtureData(
            fillByte: 0xA5,
            totalByteCount: StorageService.externalStorageThreshold + 1_024
        )
        let fixture = try await startFixture(
            compressorScript: Self.blockingExternalCompressorScript,
            originalData: originalData
        )
        let originalURL = URL(fileURLWithPath: try XCTUnwrap(fixture.storageRef))
        let contentUpdated = expectation(description: "optimized external content event")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                contentUpdated.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)
        try Data().write(to: fixture.compressorGateURL)

        let outcome = try await optimization.value
        await fulfillment(of: [contentUpdated], timeout: 2)
        XCTAssertEqual(outcome.result, .optimized)
        let resultingHash = try XCTUnwrap(outcome.resultingContentHash)
        let expectedOptimizedData = Data(originalData.prefix(8))
        XCTAssertEqual(resultingHash, ClipboardMonitor.computeHashStatic(expectedOptimizedData))

        let persistedItems = try await fixture.service.fetchRecent(limit: 10, offset: 0)
        let persisted = try XCTUnwrap(persistedItems.first(where: { $0.id == fixture.itemID }))
        let optimizedURL = URL(fileURLWithPath: try XCTUnwrap(persisted.storageRef))
        XCTAssertNotEqual(optimizedURL.path, originalURL.path)
        XCTAssertTrue(
            StorageService.validateStorageRef(
                optimizedURL.path,
                externalStoragePath: optimizedURL.deletingLastPathComponent().path
            )
        )
        XCTAssertEqual(try Data(contentsOf: optimizedURL), expectedOptimizedData)
        XCTAssertEqual(try Data(contentsOf: originalURL), originalData)
        XCTAssertEqual(persisted.contentHash, resultingHash)
        XCTAssertEqual(persisted.sizeBytes, expectedOptimizedData.count)
        XCTAssertEqual(emittedItem?.storageRef, optimizedURL.path)
        XCTAssertEqual(emittedItem?.contentHash, resultingHash)
        XCTAssertEqual(emittedItem?.sizeBytes, expectedOptimizedData.count)
    }

    func testInlineOptimizationPreservesConcurrentMetadataInPersistedAndEmittedItem() async throws {
        let fixture = try await startFixture(compressorScript: Self.blockingInlineCompressorScript)
        let contentUpdated = expectation(description: "optimized content event")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                contentUpdated.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)

        let competingStorage = StorageService(databasePath: fixture.databasePath)
        try await competingStorage.open()
        _ = try await competingStorage.updateNote(id: fixture.itemID, note: "concurrent note")
        try await competingStorage.setPin(fixture.itemID, pinned: true)
        try Data().write(to: fixture.compressorGateURL)

        let outcome = try await optimization.value
        await fulfillment(of: [contentUpdated], timeout: 2)
        XCTAssertEqual(outcome.result, .optimized)

        let persistedResult = try await competingStorage.findByID(fixture.itemID)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.note, "concurrent note")
        XCTAssertTrue(persisted.isPinned)
        XCTAssertEqual(emittedItem?.note, "concurrent note")
        XCTAssertEqual(emittedItem?.isPinned, true)
        XCTAssertEqual(emittedItem?.contentHash, outcome.resultingContentHash)
        await competingStorage.close()
    }

    func testDuplicateSameIDOptimizationDoesNotLaunchSecondProcess() async throws {
        let fixture = try await startFixture(compressorScript: Self.blockingInlineCompressorScript)
        let first = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)

        let duplicate = try await fixture.service.optimizeImage(itemID: fixture.itemID)
        guard case .failed(let message) = duplicate.result else {
            return XCTFail("Expected duplicate optimization to be rejected")
        }
        XCTAssertTrue(message.contains("already running"))
        XCTAssertNil(duplicate.resultingContentHash)

        try Data().write(to: fixture.compressorGateURL)
        let firstOutcome = try await first.value
        XCTAssertEqual(firstOutcome.result, .optimized)
    }

    func testAdmissionIsTwoActiveFourQueuedSeventhBusyAndDuplicateDoesNotConsumeSlot() async throws {
        let fixture = try await startFixture(
            compressorScript: """
            #!/bin/sh
            while [ ! -f "$0.admission-continue" ]; do /bin/sleep 0.01; done
            /bin/dd bs=1 count=8 2>/dev/null
            """
        )
        let admissionGateURL = URL(fileURLWithPath: fixture.compressorURL.path + ".admission-continue")

        let seedStorage = StorageService(databasePath: fixture.databasePath)
        try await seedStorage.open()
        var itemIDs = [fixture.itemID]
        for index in 1..<7 {
            let data = Self.makePNGFixtureData(fillByte: UInt8(0x20 + index))
            let stored = try await seedStorage.upsertItem(
                ClipboardMonitor.ClipboardContent(
                    type: .image,
                    plainText: "[Image \(index)]",
                    payload: .data(data),
                    appBundleID: "com.scopy.tests",
                    contentHash: ClipboardMonitor.computeHashStatic(data),
                    sizeBytes: data.count
                )
            )
            itemIDs.append(stored.id)
        }
        await seedStorage.close()
        XCTAssertEqual(itemIDs.count, 7)

        let admittedTasks = itemIDs.prefix(6).map { itemID in
            Task { try await fixture.service.optimizeImage(itemID: itemID) }
        }

        let admissionDeadline = Date().addingTimeInterval(3)
        var snapshot = await fixture.service.imageOptimizationAdmissionSnapshot()
        while snapshot.admittedRequestCount != 6 ||
            snapshot.activeProcessCount != 2 ||
            snapshot.queuedRequestCount != 4
        {
            guard Date() < admissionDeadline else {
                XCTFail("Timed out waiting for 2 active + 4 queued, got \(snapshot)")
                try Data().write(to: admissionGateURL)
                for task in admittedTasks {
                    task.cancel()
                    _ = try? await task.value
                }
                return
            }
            await Task.yield()
            snapshot = await fixture.service.imageOptimizationAdmissionSnapshot()
        }
        XCTAssertEqual(snapshot.requestCapacity, 6)

        let duplicate = try await fixture.service.optimizeImage(itemID: itemIDs[0])
        guard case .failed(let duplicateMessage) = duplicate.result else {
            return XCTFail("Expected duplicate to be rejected")
        }
        XCTAssertTrue(duplicateMessage.contains("already running"))
        let afterDuplicate = await fixture.service.imageOptimizationAdmissionSnapshot()
        XCTAssertEqual(afterDuplicate, snapshot)

        let seventh = try await fixture.service.optimizeImage(itemID: itemIDs[6])
        guard case .failed(let busyMessage) = seventh.result else {
            return XCTFail("Expected seventh distinct request to be busy")
        }
        XCTAssertTrue(busyMessage.contains("queue is busy"))
        let afterSeventh = await fixture.service.imageOptimizationAdmissionSnapshot()
        XCTAssertEqual(afterSeventh, snapshot)

        try Data().write(to: admissionGateURL)
        for task in admittedTasks {
            let outcome = try await task.value
            XCTAssertEqual(outcome.result, .optimized)
        }
        let drained = await fixture.service.imageOptimizationAdmissionSnapshot()
        XCTAssertEqual(drained.admittedRequestCount, 0)
        XCTAssertEqual(drained.activeProcessCount, 0)
        XCTAssertEqual(drained.queuedRequestCount, 0)
    }

    func testPostCASPayloadReplacementRepairsSearchAndSkipsStalePublication() async throws {
        let publicationGate = ImageOptimizationInterlockGate()
        let fixture = try await startFixture(
            compressorScript: Self.blockingInlineCompressorScript,
            imageOptimizationInterlock: { point, _ in
                guard case .beforeSearchPublication = point else { return }
                await publicationGate.pause()
            }
        )
        let replacementData = Self.makePNGFixtureData(fillByte: 0x47)
        let replacementHash = ClipboardMonitor.computeHashStatic(replacementData)
        let authoritativeReplacement = expectation(description: "authoritative replacement event")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                authoritativeReplacement.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)
        try Data().write(to: fixture.compressorGateURL)
        await publicationGate.waitUntilPaused()

        let competingStorage = StorageService(databasePath: fixture.databasePath)
        try await competingStorage.open()
        try await competingStorage.updateItemPayload(
            id: fixture.itemID,
            contentHash: replacementHash,
            sizeBytes: replacementData.count,
            storageRef: nil,
            rawData: replacementData
        )
        await publicationGate.release()

        let outcome = try await optimization.value
        guard case .failed = outcome.result else {
            return XCTFail("Expected post-CAS replacement to suppress optimized proof")
        }
        XCTAssertNil(outcome.resultingContentHash)
        let persistedResult = try await competingStorage.findByID(fixture.itemID)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.contentHash, replacementHash)
        XCTAssertEqual(persisted.rawData, replacementData)
        await fulfillment(of: [authoritativeReplacement], timeout: 2)
        XCTAssertEqual(emittedItem?.contentHash, replacementHash)
        XCTAssertEqual(emittedItem?.sizeBytes, replacementData.count)
        await competingStorage.close()
    }

    func testPostCASMetadataChangePublishesLatestMetadata() async throws {
        let publicationGate = ImageOptimizationInterlockGate()
        let fixture = try await startFixture(
            compressorScript: Self.blockingInlineCompressorScript,
            imageOptimizationInterlock: { point, _ in
                guard case .beforeSearchPublication = point else { return }
                await publicationGate.pause()
            }
        )
        let contentUpdated = expectation(description: "latest metadata content event")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                contentUpdated.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)
        try Data().write(to: fixture.compressorGateURL)
        await publicationGate.waitUntilPaused()

        let competingStorage = StorageService(databasePath: fixture.databasePath)
        try await competingStorage.open()
        _ = try await competingStorage.updateNote(id: fixture.itemID, note: "post-CAS note")
        try await competingStorage.setPin(fixture.itemID, pinned: true)
        await publicationGate.release()

        let outcome = try await optimization.value
        await fulfillment(of: [contentUpdated], timeout: 2)
        XCTAssertEqual(outcome.result, .optimized)
        XCTAssertEqual(emittedItem?.note, "post-CAS note")
        XCTAssertEqual(emittedItem?.isPinned, true)
        let persistedResult = try await competingStorage.findByID(fixture.itemID)
        let persisted = try XCTUnwrap(persistedResult)
        XCTAssertEqual(persisted.note, "post-CAS note")
        XCTAssertTrue(persisted.isPinned)
        await competingStorage.close()
    }

    func testExternalSourceChangeAfterCASPublishesAuthoritativeLiveBytesWithoutProof() async throws {
        let originalData = Self.makePNGFixtureData(
            fillByte: 0xA5,
            totalByteCount: StorageService.externalStorageThreshold + 1_024
        )
        let postCommitGate = ImageOptimizationInterlockGate()
        let fixture = try await startFixture(
            compressorScript: Self.blockingExternalCompressorScript,
            originalData: originalData,
            imageOptimizationInterlock: { point, _ in
                guard case .afterExternalPayloadCommit = point else { return }
                await postCommitGate.pause()
            }
        )
        let sourceURL = URL(fileURLWithPath: try XCTUnwrap(fixture.storageRef))
        let contentUpdated = expectation(description: "authoritative live payload after source race")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                contentUpdated.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)
        try Data().write(to: fixture.compressorGateURL)
        await postCommitGate.waitUntilPaused()

        let liveData = Self.makePNGFixtureData(
            fillByte: 0x6B,
            totalByteCount: originalData.count
        )
        try liveData.write(to: sourceURL, options: .atomic)
        await postCommitGate.release()

        let outcome = try await optimization.value
        guard case .failed = outcome.result else {
            return XCTFail("Expected post-CAS source change to suppress optimized proof")
        }
        XCTAssertNil(outcome.resultingContentHash)

        let persistedItems = try await fixture.service.fetchRecent(limit: 10, offset: 0)
        let persisted = try XCTUnwrap(persistedItems.first(where: { $0.id == fixture.itemID }))
        XCTAssertEqual(persisted.storageRef, sourceURL.path)
        XCTAssertEqual(persisted.contentHash, ClipboardMonitor.computeHashStatic(liveData))
        XCTAssertEqual(persisted.sizeBytes, liveData.count)
        XCTAssertEqual(try Data(contentsOf: sourceURL), liveData)
        await fulfillment(of: [contentUpdated], timeout: 2)
        XCTAssertEqual(emittedItem?.storageRef, sourceURL.path)
        XCTAssertEqual(emittedItem?.contentHash, ClipboardMonitor.computeHashStatic(liveData))
        XCTAssertEqual(emittedItem?.sizeBytes, liveData.count)

        let externalFiles = try FileManager.default.contentsOfDirectory(
            at: sourceURL.deletingLastPathComponent(),
            includingPropertiesForKeys: nil
        ).filter { !$0.lastPathComponent.hasPrefix(".") }
        XCTAssertGreaterThanOrEqual(externalFiles.count, 2)
        for file in externalFiles {
            XCTAssertFalse((try Data(contentsOf: file)).isEmpty)
        }
    }

    func testExternalSourceDeletionAfterCASPublishesCommittedPayloadWinner() async throws {
        let originalData = Self.makePNGFixtureData(
            fillByte: 0xA5,
            totalByteCount: StorageService.externalStorageThreshold + 1_024
        )
        let postCommitGate = ImageOptimizationInterlockGate()
        let fixture = try await startFixture(
            compressorScript: Self.blockingExternalCompressorScript,
            originalData: originalData,
            imageOptimizationInterlock: { point, _ in
                guard case .afterExternalPayloadCommit = point else { return }
                await postCommitGate.pause()
            }
        )
        let sourceURL = URL(fileURLWithPath: try XCTUnwrap(fixture.storageRef))
        let contentUpdated = expectation(description: "committed optimized payload event")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                contentUpdated.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)
        try Data().write(to: fixture.compressorGateURL)
        await postCommitGate.waitUntilPaused()
        try FileManager.default.removeItem(at: sourceURL)
        await postCommitGate.release()

        let outcome = try await optimization.value
        await fulfillment(of: [contentUpdated], timeout: 2)
        XCTAssertEqual(outcome.result, .optimized)
        let resultingHash = try XCTUnwrap(outcome.resultingContentHash)

        let persistedItems = try await fixture.service.fetchRecent(limit: 10, offset: 0)
        let persisted = try XCTUnwrap(persistedItems.first(where: { $0.id == fixture.itemID }))
        let optimizedRef = try XCTUnwrap(persisted.storageRef)
        XCTAssertNotEqual(optimizedRef, sourceURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: optimizedRef))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(persisted.contentHash, resultingHash)
        XCTAssertEqual(emittedItem?.contentHash, resultingHash)
        XCTAssertEqual(emittedItem?.storageRef, optimizedRef)
    }

    func testExternalSourceDeletionAfterAdoptionRepairsToOptimizedAndPublishesAuthority() async throws {
        let originalData = Self.makePNGFixtureData(
            fillByte: 0xA5,
            totalByteCount: StorageService.externalStorageThreshold + 1_024
        )
        let postCommitGate = ImageOptimizationInterlockGate()
        let verificationGate = ImageOptimizationInterlockGate()
        let fixture = try await startFixture(
            compressorScript: Self.blockingExternalCompressorScript,
            originalData: originalData,
            imageOptimizationInterlock: { point, _ in
                switch point {
                case .afterExternalPayloadCommit:
                    await postCommitGate.pause()
                case .afterExternalSourceAdoptionBeforeVerification(let attempt) where attempt == 0:
                    await verificationGate.pause()
                default:
                    break
                }
            }
        )
        let sourceURL = URL(fileURLWithPath: try XCTUnwrap(fixture.storageRef))
        let contentUpdated = expectation(description: "repaired optimized authority event")
        var emittedItem: ClipboardItemDTO?
        let eventTask = Task { @MainActor in
            for await event in fixture.service.eventStream {
                guard case .itemContentUpdated(let item) = event,
                      item.id == fixture.itemID else { continue }
                emittedItem = item
                contentUpdated.fulfill()
                return
            }
        }
        defer { eventTask.cancel() }

        let optimization = Task {
            try await fixture.service.optimizeImage(itemID: fixture.itemID)
        }
        try await waitForFile(fixture.compressorReadyURL)
        try Data().write(to: fixture.compressorGateURL)
        await postCommitGate.waitUntilPaused()
        let liveData = Self.makePNGFixtureData(
            fillByte: 0x7C,
            totalByteCount: originalData.count
        )
        try liveData.write(to: sourceURL, options: .atomic)
        await postCommitGate.release()

        await verificationGate.waitUntilPaused()
        try FileManager.default.removeItem(at: sourceURL)
        await verificationGate.release()

        let outcome = try await optimization.value
        guard case .failed = outcome.result else {
            return XCTFail("Expected repaired source race to suppress optimized success proof")
        }
        XCTAssertNil(outcome.resultingContentHash)
        await fulfillment(of: [contentUpdated], timeout: 2)

        let persistedItems = try await fixture.service.fetchRecent(limit: 10, offset: 0)
        let persisted = try XCTUnwrap(persistedItems.first(where: { $0.id == fixture.itemID }))
        let optimizedRef = try XCTUnwrap(persisted.storageRef)
        XCTAssertNotEqual(optimizedRef, sourceURL.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: optimizedRef))
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertEqual(emittedItem?.storageRef, optimizedRef)
        XCTAssertEqual(emittedItem?.contentHash, persisted.contentHash)
        XCTAssertEqual(emittedItem?.sizeBytes, persisted.sizeBytes)
    }

    private func startFixture(
        compressorScript: String,
        originalData: Data? = nil,
        imageOptimizationInterlock: (@Sendable (ClipboardService.ImageOptimizationInterlockPoint, UUID) async -> Void)? = nil
    ) async throws -> Fixture {
        precondition(service == nil)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("scopy-optimize-proof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory

        let binaryURL = directory.appendingPathComponent("pngquant-test-double")
        try compressorScript.write(to: binaryURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: binaryURL.path
        )

        let suiteName = "scopy-optimize-proof-settings-\(UUID().uuidString)"
        settingsSuiteName = suiteName
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        let settingsStore = SettingsStore(suiteName: suiteName)
        var settings = SettingsDTO.default
        settings.pngquantBinaryPath = binaryURL.path
        await settingsStore.save(settings)

        let originalData = originalData ?? Self.makePNGFixtureData()
        let originalHash = ClipboardMonitor.computeHashStatic(originalData)
        let databasePath = directory.appendingPathComponent("clipboard.db").path
        let seedStorage = StorageService(databasePath: databasePath)
        try await seedStorage.open()
        let storedItem = try await seedStorage.upsertItem(
            ClipboardMonitor.ClipboardContent(
                type: .image,
                plainText: "[Image]",
                payload: .data(originalData),
                appBundleID: "com.scopy.tests",
                contentHash: originalHash,
                sizeBytes: originalData.count
            )
        )
        await seedStorage.close()

        let clipboardService = ClipboardService(
            databasePath: databasePath,
            settingsStore: settingsStore,
            monitorPasteboardName: NSPasteboard.withUniqueName().name.rawValue,
            monitorPollingInterval: 60,
            imageOptimizationInterlock: imageOptimizationInterlock
        )
        service = clipboardService
        try await clipboardService.start()

        return Fixture(
            service: clipboardService,
            itemID: storedItem.id,
            originalData: originalData,
            originalHash: originalHash,
            databasePath: databasePath,
            storageRef: storedItem.storageRef,
            compressorURL: binaryURL
        )
    }

    private func waitForFile(_ url: URL, timeout: TimeInterval = 3) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !FileManager.default.fileExists(atPath: url.path) {
            if Date() >= deadline {
                throw NSError(
                    domain: "ClipboardServiceImageOptimizationTests",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Timed out waiting for \(url.lastPathComponent)"]
                )
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    nonisolated private static func makePNGFixtureData(
        fillByte: UInt8 = 0xA5,
        totalByteCount: Int = 520
    ) -> Data {
        let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        return Data(signature + Array(repeating: fillByte, count: max(0, totalByteCount - signature.count)))
    }

    nonisolated private static let blockingInlineCompressorScript = """
    #!/bin/sh
    ready="$0.ready"
    gate="$0.continue"
    /usr/bin/touch "$ready"
    while [ ! -f "$gate" ]; do /bin/sleep 0.01; done
    /bin/dd bs=1 count=8 2>/dev/null
    """

    nonisolated private static let blockingExternalCompressorScript = """
    #!/bin/sh
    output=""
    input=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --output)
                shift
                output="$1"
                ;;
            --)
                shift
                input="$1"
                break
                ;;
        esac
        shift
    done
    /usr/bin/touch "$0.ready"
    while [ ! -f "$0.continue" ]; do /bin/sleep 0.01; done
    /bin/dd if="$input" of="$output" bs=1 count=8 2>/dev/null
    """
}
