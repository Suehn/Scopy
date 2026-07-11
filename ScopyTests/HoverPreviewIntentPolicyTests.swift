import CoreGraphics
import XCTest

@testable import Scopy

final class HoverPreviewIntentPolicyTests: XCTestCase {
    private let target = CGRect(x: 100, y: 100, width: 100, height: 100)

    func testSafeTriangleSupportsTargetsOnEverySide() throws {
        let cases: [(origin: CGPoint, inside: CGPoint)] = [
            (CGPoint(x: 0, y: 150), CGPoint(x: 50, y: 150)),
            (CGPoint(x: 300, y: 150), CGPoint(x: 250, y: 150)),
            (CGPoint(x: 150, y: 0), CGPoint(x: 150, y: 50)),
            (CGPoint(x: 150, y: 300), CGPoint(x: 150, y: 250))
        ]

        for value in cases {
            let triangle = try XCTUnwrap(
                HoverPreviewIntentPolicy.safeTriangle(
                    origin: value.origin,
                    targetFrame: target,
                    padding: 0
                )
            )
            XCTAssertTrue(triangle.contains(value.inside, boundaryTolerance: 0.001))
        }
    }

    func testSafeTriangleSupportsDiagonalAndNegativeScreenCoordinates() throws {
        let negativeTarget = CGRect(x: -500, y: -300, width: 180, height: 240)
        let origin = CGPoint(x: -700, y: -500)
        let triangle = try XCTUnwrap(
            HoverPreviewIntentPolicy.safeTriangle(origin: origin, targetFrame: negativeTarget, padding: 8)
        )

        XCTAssertTrue(triangle.contains(CGPoint(x: -580, y: -380), boundaryTolerance: 0.5))
        XCTAssertFalse(triangle.contains(CGPoint(x: -760, y: -350), boundaryTolerance: 0.5))
    }

    func testSafeTriangleIncludesTargetCornersAndRejectsOutsidePoint() throws {
        let origin = CGPoint(x: 0, y: 150)
        let triangle = try XCTUnwrap(
            HoverPreviewIntentPolicy.safeTriangle(origin: origin, targetFrame: target, padding: 0)
        )

        XCTAssertTrue(triangle.contains(triangle.firstTargetPoint, boundaryTolerance: 0.001))
        XCTAssertTrue(triangle.contains(triangle.secondTargetPoint, boundaryTolerance: 0.001))
        XCTAssertFalse(triangle.contains(CGPoint(x: 50, y: 250), boundaryTolerance: 0.001))
    }

    func testSafeTriangleRejectsDegenerateAndNonFiniteGeometry() {
        XCTAssertNil(
            HoverPreviewIntentPolicy.safeTriangle(
                origin: CGPoint(x: 0, y: 0),
                targetFrame: .zero,
                padding: 0
            )
        )
        XCTAssertNil(
            HoverPreviewIntentPolicy.safeTriangle(
                origin: CGPoint(x: CGFloat.nan, y: 0),
                targetFrame: target,
                padding: 0
            )
        )
        XCTAssertNil(
            HoverPreviewIntentPolicy.safeTriangle(
                origin: CGPoint(x: 0, y: 0),
                targetFrame: CGRect(x: 100, y: 100, width: CGFloat.infinity, height: 100),
                padding: 0
            )
        )
    }

    func testMissingTargetUsesGraceThenDismisses() {
        var session = HoverPreviewIntentPolicy.Session(origin: .zero, targetFrame: nil)

        XCTAssertEqual(
            session.evaluate(pointer: .zero, targetFrame: nil, elapsed: 0.119),
            .keepAlive(.initialGrace)
        )
        XCTAssertEqual(
            session.evaluate(pointer: .zero, targetFrame: nil, elapsed: 0.120),
            .dismiss(.targetUnavailable)
        )
    }

    func testDelayedTargetAcquisitionWithinGraceActivatesDirectedIntent() {
        var session = HoverPreviewIntentPolicy.Session(
            origin: CGPoint(x: 0, y: 150),
            targetFrame: nil
        )

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 1, y: 150), targetFrame: nil, elapsed: 0.04),
            .keepAlive(.initialGrace)
        )
        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 3, y: 150), targetFrame: target, elapsed: 0.08),
            .keepAlive(.movingTowardTarget)
        )
        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.14),
            .keepAlive(.movingTowardTarget)
        )
    }

    func testAcquiredTargetDisappearingDismissesImmediately() {
        var session = HoverPreviewIntentPolicy.Session(
            origin: CGPoint(x: 0, y: 150),
            targetFrame: target
        )

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 1, y: 150), targetFrame: nil, elapsed: 0.01),
            .dismiss(.targetLost)
        )
    }

    func testForwardProgressActivatesIntent() {
        var session = makeHorizontalSession()

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 3, y: 150), targetFrame: target, elapsed: 0.04),
            .keepAlive(.movingTowardTarget)
        )
        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.10),
            .keepAlive(.movingTowardTarget)
        )
        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 50, y: 150), targetFrame: target, elapsed: 0.14),
            .keepAlive(.movingTowardTarget)
        )
    }

    func testStationaryPointerDismissesAfterInitialGrace() {
        var session = makeHorizontalSession()

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 0, y: 150), targetFrame: target, elapsed: 0.119),
            .keepAlive(.initialGrace)
        )
        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 0, y: 150), targetFrame: target, elapsed: 0.120),
            .dismiss(.noIntent)
        )
    }

    func testLeavingTriangleDismissesImmediately() {
        var session = makeHorizontalSession()

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 20, y: 260), targetFrame: target, elapsed: 0.02),
            .dismiss(.outsideCorridor)
        )
    }

    func testReversingBeyondToleranceDismisses() {
        var session = makeHorizontalSession()
        _ = session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.04)

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 10, y: 150), targetFrame: target, elapsed: 0.08),
            .dismiss(.reversed)
        )
    }

    func testSmallBacktrackInsideToleranceRemainsActive() {
        var session = makeHorizontalSession()
        _ = session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.04)

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 15, y: 150), targetFrame: target, elapsed: 0.08),
            .keepAlive(.movingTowardTarget)
        )
    }

    func testActivatedIntentDismissesWhenProgressStalls() {
        var session = makeHorizontalSession()
        _ = session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.04)

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.201),
            .dismiss(.stalled)
        )
    }

    func testHardTimeoutAlwaysBoundsCorridorLifetime() {
        var session = makeHorizontalSession()
        _ = session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.04)

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 80, y: 150), targetFrame: target, elapsed: 0.500),
            .dismiss(.expired)
        )
    }

    func testHardTimeoutStopsSamplingWhenPopoverHoverCallbackNeverArrives() {
        var session = makeHorizontalSession()

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 120, y: 150), targetFrame: target, elapsed: 0.500),
            .dismiss(.expired)
        )
    }

    func testPointerInsideTargetIsKeptAlive() {
        var session = makeHorizontalSession()

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 120, y: 150), targetFrame: target, elapsed: 0.04),
            .keepAlive(.insideTarget)
        )
    }

    func testTargetResizeRebuildsGeometryWithoutLosingActivatedIntent() {
        var session = makeHorizontalSession()
        _ = session.evaluate(pointer: CGPoint(x: 20, y: 150), targetFrame: target, elapsed: 0.04)
        let resized = CGRect(x: 120, y: 80, width: 160, height: 180)

        XCTAssertEqual(
            session.evaluate(pointer: CGPoint(x: 30, y: 150), targetFrame: resized, elapsed: 0.08),
            .keepAlive(.movingTowardTarget)
        )
    }

    func testBatchGeometryEvaluationRemainsStable() throws {
        let triangle = try XCTUnwrap(
            HoverPreviewIntentPolicy.safeTriangle(
                origin: CGPoint(x: 0, y: 150),
                targetFrame: target,
                padding: 8
            )
        )
        var insideCount = 0
        for index in 0..<100_000 {
            let progress = CGFloat(index % 90) / 90
            let point = CGPoint(x: progress * 90, y: 150 + sin(progress * .pi) * 20)
            if triangle.contains(point, boundaryTolerance: 0.5) {
                insideCount += 1
            }
        }
        XCTAssertGreaterThan(insideCount, 95_000)
    }

    func testSafeTriangleContains100kPerformance() throws {
        let triangle = try XCTUnwrap(
            HoverPreviewIntentPolicy.safeTriangle(
                origin: CGPoint(x: 0, y: 150),
                targetFrame: target,
                padding: 8
            )
        )
        let points = (0..<100_000).map { index in
            let progress = CGFloat(index % 90) / 90
            return CGPoint(x: progress * 90, y: 150 + sin(progress * .pi) * 20)
        }

        measure(metrics: [XCTClockMetric()]) {
            var insideCount = 0
            for point in points where triangle.contains(point, boundaryTolerance: 0.5) {
                insideCount += 1
            }
            XCTAssertGreaterThan(insideCount, 95_000)
        }
    }

    private func makeHorizontalSession() -> HoverPreviewIntentPolicy.Session {
        HoverPreviewIntentPolicy.Session(
            origin: CGPoint(x: 0, y: 150),
            targetFrame: target
        )
    }
}

@MainActor
final class HoverPreviewIntentControllerTests: XCTestCase {
    func testControllerDismissesOnceWhenPointerLeavesCorridor() async {
        let script = CursorScript(
            points: [CGPoint(x: 0, y: 150), CGPoint(x: 20, y: 260)],
            step: 0.02
        )
        let controller = HoverPreviewIntentController(dependencies: script.dependencies)
        let dismissed = expectation(description: "dismissed")
        dismissed.expectedFulfillmentCount = 1
        var finishCount = 0

        controller.start(
            exitPoint: CGPoint(x: 0, y: 150),
            targetFrame: { CGRect(x: 100, y: 100, width: 100, height: 100) },
            shouldKeepAlive: { false },
            onDismiss: { dismissed.fulfill() },
            onFinish: { finishCount += 1 }
        )

        await fulfillment(of: [dismissed], timeout: 1)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(finishCount, 1)
    }

    func testCancelStopsControllerWithoutDismissing() async {
        let script = CursorScript(points: [CGPoint(x: 0, y: 150)], step: 0.01, suspends: true)
        let controller = HoverPreviewIntentController(dependencies: script.dependencies)
        var dismissCount = 0
        var finishCount = 0

        controller.start(
            exitPoint: CGPoint(x: 0, y: 150),
            targetFrame: { CGRect(x: 100, y: 100, width: 100, height: 100) },
            shouldKeepAlive: { false },
            onDismiss: { dismissCount += 1 },
            onFinish: { finishCount += 1 }
        )
        XCTAssertTrue(controller.isActive)

        controller.cancel()
        await Task.yield()

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertEqual(finishCount, 1)
    }

    func testControllerKeepsDirectedTravelAlivePastFixedGraceUntilTargetReached() async {
        let script = CursorScript(
            points: [
                CGPoint(x: 0, y: 150),
                CGPoint(x: 3, y: 150),
                CGPoint(x: 10, y: 150),
                CGPoint(x: 20, y: 150),
                CGPoint(x: 35, y: 150),
                CGPoint(x: 50, y: 150),
                CGPoint(x: 70, y: 150),
                CGPoint(x: 90, y: 150),
                CGPoint(x: 105, y: 150)
            ],
            step: 0.025
        )
        let controller = HoverPreviewIntentController(dependencies: script.dependencies)
        var dismissCount = 0

        controller.start(
            exitPoint: CGPoint(x: 0, y: 150),
            targetFrame: { CGRect(x: 100, y: 100, width: 100, height: 100) },
            shouldKeepAlive: { script.currentPoint.x >= 100 },
            onDismiss: { dismissCount += 1 }
        )

        for _ in 0..<100 where controller.isActive {
            await Task.yield()
        }

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(dismissCount, 0)
        XCTAssertGreaterThan(script.elapsed, 0.120)
        XCTAssertLessThan(script.elapsed, 0.500)
    }

    func testControllerStopsAtHardTimeoutWhenHoverCallbackNeverArrives() async {
        let points = (0...40).map { index in
            CGPoint(x: CGFloat(index * 3), y: 150)
        }
        let script = CursorScript(points: points, step: 0.02)
        let controller = HoverPreviewIntentController(dependencies: script.dependencies)
        let dismissed = expectation(description: "hard-timeout dismissal")
        dismissed.expectedFulfillmentCount = 1

        controller.start(
            exitPoint: CGPoint(x: 0, y: 150),
            targetFrame: { CGRect(x: 1_000, y: 100, width: 100, height: 100) },
            shouldKeepAlive: { false },
            onDismiss: { dismissed.fulfill() }
        )

        await fulfillment(of: [dismissed], timeout: 1)

        XCTAssertFalse(controller.isActive)
        XCTAssertGreaterThanOrEqual(script.elapsed, 0.500)
        XCTAssertLessThan(script.elapsed, 0.540)
        XCTAssertLessThanOrEqual(script.sleepCount, 27)
    }

    func testStartingNewIntentFinishesPreviousGenerationWithoutDismissingIt() async {
        let script = CursorScript(points: [CGPoint(x: 0, y: 150)], step: 0.01, suspends: true)
        let controller = HoverPreviewIntentController(dependencies: script.dependencies)
        var firstDismissCount = 0
        var firstFinishCount = 0
        var secondFinishCount = 0

        controller.start(
            exitPoint: CGPoint(x: 0, y: 150),
            targetFrame: { CGRect(x: 100, y: 100, width: 100, height: 100) },
            shouldKeepAlive: { false },
            onDismiss: { firstDismissCount += 1 },
            onFinish: { firstFinishCount += 1 }
        )
        controller.start(
            exitPoint: CGPoint(x: 0, y: 150),
            targetFrame: { CGRect(x: 100, y: 100, width: 100, height: 100) },
            shouldKeepAlive: { true },
            onDismiss: { XCTFail("Replacement intent should finish through liveness") },
            onFinish: { secondFinishCount += 1 }
        )

        for _ in 0..<20 where controller.isActive {
            await Task.yield()
        }

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(firstDismissCount, 0)
        XCTAssertEqual(firstFinishCount, 1)
        XCTAssertEqual(secondFinishCount, 1)
    }

    @MainActor
    private final class CursorScript {
        private var points: [CGPoint]
        private var index = 0
        private var now: TimeInterval = 0
        private(set) var sleepCount = 0
        private let step: TimeInterval
        private let suspends: Bool

        init(points: [CGPoint], step: TimeInterval, suspends: Bool = false) {
            self.points = points
            self.step = step
            self.suspends = suspends
        }

        var dependencies: HoverPreviewIntentController.Dependencies {
            HoverPreviewIntentController.Dependencies(
                cursorLocation: { [weak self] in
                    guard let self, !self.points.isEmpty else { return .zero }
                    return self.points[min(self.index, self.points.count - 1)]
                },
                uptime: { [weak self] in self?.now ?? 0 },
                sleep: { [weak self] _ in
                    guard let self else { return }
                    if self.suspends {
                        try await Task.sleep(nanoseconds: 10_000_000_000)
                    }
                    self.now += self.step
                    self.sleepCount += 1
                    self.index = min(self.index + 1, max(0, self.points.count - 1))
                    await Task.yield()
                }
            )
        }

        var currentPoint: CGPoint {
            guard !points.isEmpty else { return .zero }
            return points[min(index, points.count - 1)]
        }

        var elapsed: TimeInterval {
            now
        }
    }
}
