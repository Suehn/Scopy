import CoreGraphics
import Foundation

/// Direction-aware hover intent for the gap between a history row and its preview popover.
///
/// The policy is intentionally pure: callers provide pointer positions, target geometry, and
/// elapsed time. This keeps the hot path allocation-free and makes every edge case deterministic
/// in unit tests.
enum HoverPreviewIntentPolicy {
    struct Configuration: Equatable {
        let targetPadding: CGFloat
        let boundaryTolerance: CGFloat
        let originTolerance: CGFloat
        let activationProgress: CGFloat
        let reverseTolerance: CGFloat
        let progressEpsilon: CGFloat
        let initialGrace: TimeInterval
        let stallTimeout: TimeInterval
        let hardTimeout: TimeInterval
        let sampleIntervalNanoseconds: UInt64

        static let `default` = Configuration(
            targetPadding: 8,
            boundaryTolerance: 0.5,
            originTolerance: 4,
            activationProgress: 2,
            reverseTolerance: 6,
            progressEpsilon: 0.5,
            initialGrace: 0.120,
            stallTimeout: 0.160,
            hardTimeout: 0.500,
            sampleIntervalNanoseconds: 16_666_667
        )
    }

    enum KeepReason: Equatable {
        case initialGrace
        case movingTowardTarget
        case insideTarget
    }

    enum DismissReason: Equatable {
        case targetUnavailable
        case targetLost
        case outsideCorridor
        case noIntent
        case reversed
        case stalled
        case expired
        case invalidGeometry
    }

    enum Decision: Equatable {
        case keepAlive(KeepReason)
        case dismiss(DismissReason)
    }

    struct SafeTriangle: Equatable {
        let apex: CGPoint
        let firstTargetPoint: CGPoint
        let secondTargetPoint: CGPoint
        let targetFrame: CGRect

        func contains(_ point: CGPoint, boundaryTolerance: CGFloat) -> Bool {
            guard HoverPreviewIntentPolicy.isFinite(point) else { return false }
            if targetFrame.contains(point) { return true }

            let d1 = signedDistance(point, from: apex, to: firstTargetPoint)
            let d2 = signedDistance(point, from: firstTargetPoint, to: secondTargetPoint)
            let d3 = signedDistance(point, from: secondTargetPoint, to: apex)
            let tolerance = max(0, boundaryTolerance)
            let hasNegative = d1 < -tolerance || d2 < -tolerance || d3 < -tolerance
            let hasPositive = d1 > tolerance || d2 > tolerance || d3 > tolerance
            return !(hasNegative && hasPositive)
        }

        private func signedDistance(_ point: CGPoint, from start: CGPoint, to end: CGPoint) -> CGFloat {
            let dx = end.x - start.x
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            guard length > .ulpOfOne else { return 0 }
            return (dx * (point.y - start.y) - dy * (point.x - start.x)) / length
        }
    }

    struct Session {
        private let origin: CGPoint
        private let configuration: Configuration
        private var targetFrame: CGRect?
        private var safeTriangle: SafeTriangle?
        private var hasAcquiredTarget = false
        private var isActivated = false
        private var initialDistance: CGFloat?
        private var closestDistance: CGFloat?
        private var lastProgressElapsed: TimeInterval = 0

        init(
            origin: CGPoint,
            targetFrame: CGRect?,
            configuration: Configuration = .default
        ) {
            self.origin = origin
            self.configuration = configuration
            self.targetFrame = nil
            applyTargetFrame(targetFrame, pointer: origin, elapsed: 0)
        }

        mutating func evaluate(
            pointer: CGPoint,
            targetFrame nextTargetFrame: CGRect?,
            elapsed rawElapsed: TimeInterval
        ) -> Decision {
            guard HoverPreviewIntentPolicy.isFinite(origin), HoverPreviewIntentPolicy.isFinite(pointer) else {
                return .dismiss(.invalidGeometry)
            }

            let elapsed = max(0, rawElapsed)
            applyTargetFrame(nextTargetFrame, pointer: pointer, elapsed: elapsed)

            guard let targetFrame else {
                if hasAcquiredTarget {
                    return .dismiss(.targetLost)
                }
                return elapsed < configuration.initialGrace
                    ? .keepAlive(.initialGrace)
                    : .dismiss(.targetUnavailable)
            }

            if elapsed >= configuration.hardTimeout {
                return .dismiss(.expired)
            }

            if targetFrame.contains(pointer) {
                return .keepAlive(.insideTarget)
            }

            guard let safeTriangle else {
                return .dismiss(.invalidGeometry)
            }

            let distanceFromOrigin = hypot(pointer.x - origin.x, pointer.y - origin.y)
            guard distanceFromOrigin <= configuration.originTolerance ||
                    safeTriangle.contains(pointer, boundaryTolerance: configuration.boundaryTolerance)
            else {
                return .dismiss(.outsideCorridor)
            }

            let currentDistance = HoverPreviewIntentPolicy.distance(from: pointer, to: targetFrame)
            let initialDistance = self.initialDistance ?? HoverPreviewIntentPolicy.distance(from: origin, to: targetFrame)
            let closestDistance = self.closestDistance ?? initialDistance

            if currentDistance > closestDistance + configuration.reverseTolerance {
                return .dismiss(.reversed)
            }

            let progress = initialDistance - currentDistance
            if !isActivated, progress >= configuration.activationProgress {
                isActivated = true
                self.closestDistance = currentDistance
                lastProgressElapsed = elapsed
            }

            guard isActivated else {
                return elapsed < configuration.initialGrace
                    ? .keepAlive(.initialGrace)
                    : .dismiss(.noIntent)
            }

            if closestDistance - currentDistance >= configuration.progressEpsilon {
                self.closestDistance = currentDistance
                lastProgressElapsed = elapsed
            }

            if elapsed - lastProgressElapsed >= configuration.stallTimeout {
                return .dismiss(.stalled)
            }

            return .keepAlive(.movingTowardTarget)
        }

        private mutating func applyTargetFrame(
            _ candidate: CGRect?,
            pointer: CGPoint,
            elapsed: TimeInterval
        ) {
            guard let candidate,
                  let validated = HoverPreviewIntentPolicy.validatedTargetFrame(
                    candidate,
                    padding: configuration.targetPadding
                  )
            else {
                targetFrame = nil
                safeTriangle = nil
                return
            }

            guard targetFrame != validated else { return }
            let wasAcquired = hasAcquiredTarget
            targetFrame = validated
            safeTriangle = HoverPreviewIntentPolicy.safeTriangle(
                origin: origin,
                targetFrame: validated,
                padding: 0
            )
            hasAcquiredTarget = true

            let originDistance = HoverPreviewIntentPolicy.distance(from: origin, to: validated)
            let pointerDistance = HoverPreviewIntentPolicy.distance(from: pointer, to: validated)
            if !wasAcquired {
                initialDistance = originDistance
                closestDistance = min(originDistance, pointerDistance)
            } else {
                if !isActivated {
                    initialDistance = originDistance
                }
                closestDistance = pointerDistance
                lastProgressElapsed = elapsed
            }
        }
    }

    static func safeTriangle(
        origin: CGPoint,
        targetFrame: CGRect,
        padding: CGFloat
    ) -> SafeTriangle? {
        guard isFinite(origin),
              let targetFrame = validatedTargetFrame(targetFrame, padding: padding),
              !targetFrame.contains(origin)
        else {
            return nil
        }

        let corners = [
            CGPoint(x: targetFrame.minX, y: targetFrame.minY),
            CGPoint(x: targetFrame.minX, y: targetFrame.maxY),
            CGPoint(x: targetFrame.maxX, y: targetFrame.minY),
            CGPoint(x: targetFrame.maxX, y: targetFrame.maxY)
        ]
        let centerAngle = atan2(targetFrame.midY - origin.y, targetFrame.midX - origin.x)
        let angularCorners = corners.map { corner -> (point: CGPoint, relativeAngle: CGFloat) in
            let angle = atan2(corner.y - origin.y, corner.x - origin.x)
            let delta = angle - centerAngle
            return (corner, atan2(sin(delta), cos(delta)))
        }

        guard let first = angularCorners.min(by: { $0.relativeAngle < $1.relativeAngle }),
              let second = angularCorners.max(by: { $0.relativeAngle < $1.relativeAngle }),
              first.point != second.point
        else {
            return nil
        }

        let area = abs(cross(first.point - origin, second.point - origin))
        guard area > .ulpOfOne else { return nil }
        return SafeTriangle(
            apex: origin,
            firstTargetPoint: first.point,
            secondTargetPoint: second.point,
            targetFrame: targetFrame
        )
    }

    static func distance(from point: CGPoint, to frame: CGRect) -> CGFloat {
        let dx = max(max(frame.minX - point.x, 0), point.x - frame.maxX)
        let dy = max(max(frame.minY - point.y, 0), point.y - frame.maxY)
        return hypot(dx, dy)
    }

    private static func validatedTargetFrame(_ frame: CGRect, padding: CGFloat) -> CGRect? {
        guard isFinite(frame), frame.width > 0, frame.height > 0 else { return nil }
        let padding = max(0, padding)
        let expanded = frame.insetBy(dx: -padding, dy: -padding)
        guard isFinite(expanded), expanded.width > 0, expanded.height > 0 else { return nil }
        return expanded
    }

    private static func isFinite(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFinite(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite &&
            frame.width.isFinite && frame.height.isFinite
    }

    private static func cross(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        lhs.x * rhs.y - lhs.y * rhs.x
    }
}

private func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint {
    CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y)
}
