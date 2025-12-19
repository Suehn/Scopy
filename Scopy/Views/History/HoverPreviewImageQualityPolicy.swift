import Foundation

enum HoverPreviewImageQualityPolicy {
    static let maxSidePixels: Int = 32_767
    static let maxTotalPixels: Double = 24_000_000

    struct RenderPlan: Sendable {
        let scaleFactor: Double
        let effectiveTargetWidthPixels: Int
        let effectiveTargetHeightPixels: Int
        let maxPixelSize: Int
    }

    static func plan(
        sourceWidthPixels: Int,
        sourceHeightPixels: Int,
        idealTargetWidthPixels: Int,
        maxSidePixels: Int = HoverPreviewImageQualityPolicy.maxSidePixels,
        maxTotalPixels: Double = HoverPreviewImageQualityPolicy.maxTotalPixels
    ) -> RenderPlan {
        guard sourceWidthPixels > 0, sourceHeightPixels > 0, idealTargetWidthPixels > 0 else {
            return RenderPlan(
                scaleFactor: 1.0,
                effectiveTargetWidthPixels: max(1, idealTargetWidthPixels),
                effectiveTargetHeightPixels: 1,
                maxPixelSize: max(1, idealTargetWidthPixels)
            )
        }

        let w = Double(sourceWidthPixels)
        let h = Double(sourceHeightPixels)
        let idealW = Double(idealTargetWidthPixels)
        let idealH = (h * idealW) / w
        let idealMaxDim = max(idealW, idealH)
        let idealTotal = idealW * idealH

        var scaleFactor = 1.0

        let maxSide = Double(maxSidePixels)
        if idealMaxDim > maxSide, idealMaxDim > 0 {
            scaleFactor = min(scaleFactor, maxSide / idealMaxDim)
        }

        if idealTotal > maxTotalPixels, idealTotal > 0 {
            scaleFactor = min(scaleFactor, (maxTotalPixels / idealTotal).squareRoot())
        }

        let effectiveW = max(1, Int((idealW * scaleFactor).rounded(.down)))
        let effectiveH = max(1, Int((idealH * scaleFactor).rounded(.down)))
        let maxPixelSize = max(effectiveW, effectiveH)

        return RenderPlan(
            scaleFactor: scaleFactor,
            effectiveTargetWidthPixels: effectiveW,
            effectiveTargetHeightPixels: effectiveH,
            maxPixelSize: max(1, min(maxSidePixels, maxPixelSize))
        )
    }
}

