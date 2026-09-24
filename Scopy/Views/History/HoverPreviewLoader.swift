import AppKit
import ImageIO
import ScopyUISupport

enum HoverPreviewLoader {
    /// The displayed (EXIF-oriented) pixel size read from the image header, without decoding.
    static func displayPixelSize(fromFileAtPath path: String) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        return displayPixelSize(of: source)
    }

    static func displayPixelSize(from data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return displayPixelSize(of: source)
    }

    private static func displayPixelSize(of source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, width > 0,
              let height = props[kCGImagePropertyPixelHeight] as? Int, height > 0
        else { return nil }
        // Orientations 5-8 rotate by 90 degrees; the decoded preview applies the transform.
        let orientation = props[kCGImagePropertyOrientation] as? Int ?? 1
        return (5...8).contains(orientation)
            ? CGSize(width: height, height: width)
            : CGSize(width: width, height: height)
    }

    static func makePreviewCGImage(from data: Data, targetWidthPixels: Int, maxLongSidePixels: Int) -> CGImage? {
        guard targetWidthPixels > 0, maxLongSidePixels > 0 else { return nil }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return makePreviewCGImage(from: source, targetWidthPixels: targetWidthPixels, maxLongSidePixels: maxLongSidePixels)
    }

    static func makePreviewCGImage(fromFileAtPath path: String, targetWidthPixels: Int, maxLongSidePixels: Int) -> CGImage? {
        guard targetWidthPixels > 0, maxLongSidePixels > 0 else { return nil }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return makePreviewCGImage(from: source, targetWidthPixels: targetWidthPixels, maxLongSidePixels: maxLongSidePixels)
    }

    private static func makePreviewCGImage(from source: CGImageSource, targetWidthPixels: Int, maxLongSidePixels: Int) -> CGImage? {
        let requestedMax = computeRequestedMaxPixelSize(
            source: source,
            targetWidthPixels: targetWidthPixels,
            maxLongSidePixels: maxLongSidePixels
        )
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: requestedMax,
            kCGImageSourceShouldCacheImmediately: true
        ]
        if ScrollPerformanceProfile.isEnabled {
            let start = CFAbsoluteTimeGetCurrent()
            let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            if image != nil {
                let elapsed = (CFAbsoluteTimeGetCurrent() - start) * 1000
                ScrollPerformanceProfile.recordTiming(name: "hover.preview_image_decode_ms", elapsedMs: elapsed)
            }
            return image
        }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private static func computeRequestedMaxPixelSize(
        source: CGImageSource,
        targetWidthPixels: Int,
        maxLongSidePixels: Int
    ) -> Int {
        let fallback = min(maxLongSidePixels, max(targetWidthPixels, 1))
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return fallback
        }
        let w = props[kCGImagePropertyPixelWidth] as? Int ?? 0
        let h = props[kCGImagePropertyPixelHeight] as? Int ?? 0
        guard w > 0, h > 0 else { return fallback }
        let plan = HoverPreviewImageQualityPolicy.plan(
            sourceWidthPixels: w,
            sourceHeightPixels: h,
            idealTargetWidthPixels: targetWidthPixels,
            maxSidePixels: maxLongSidePixels
        )
        return min(maxLongSidePixels, max(1, plan.maxPixelSize))
    }
}
