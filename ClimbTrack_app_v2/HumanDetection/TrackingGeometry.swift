import CoreGraphics

/// Shared geometry for Vision, preview, and recording. All rectangles use
/// upright Vision coordinates: normalized, with a bottom-left origin.
nonisolated enum TrackingGeometry {
    static let unitRectangle = CGRect(x: 0, y: 0, width: 1, height: 1)

    static func clipped(_ rectangle: CGRect) -> CGRect {
        rectangle.standardized.intersection(unitRectangle)
    }

    static func expanded(
        _ rectangle: CGRect,
        scale: CGFloat,
        minimumSize: CGSize = .zero
    ) -> CGRect {
        let width = min(1, max(rectangle.width * scale, minimumSize.width))
        let height = min(1, max(rectangle.height * scale, minimumSize.height))
        return centeredRectangle(
            center: CGPoint(x: rectangle.midX, y: rectangle.midY),
            size: CGSize(width: width, height: height)
        )
    }

    static func centeredRectangle(center: CGPoint, size: CGSize) -> CGRect {
        let width = min(max(size.width, 0), 1)
        let height = min(max(size.height, 0), 1)
        let x = min(max(center.x - width / 2, 0), 1 - width)
        let y = min(max(center.y - height / 2, 0), 1 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    static func canonicalRectangle(
        fromLocal rectangle: CGRect,
        in region: CGRect
    ) -> CGRect {
        clipped(CGRect(
            x: region.minX + rectangle.minX * region.width,
            y: region.minY + rectangle.minY * region.height,
            width: rectangle.width * region.width,
            height: rectangle.height * region.height
        ))
    }

    static func localRectangle(
        fromCanonical rectangle: CGRect,
        in region: CGRect
    ) -> CGRect? {
        guard region.width > 0, region.height > 0 else { return nil }
        let visible = rectangle.intersection(region)
        guard !visible.isNull, visible.width > 0, visible.height > 0 else { return nil }
        return CGRect(
            x: (visible.minX - region.minX) / region.width,
            y: (visible.minY - region.minY) / region.height,
            width: visible.width / region.width,
            height: visible.height / region.height
        )
    }

    static func imageRectangle(for normalizedRectangle: CGRect, in extent: CGRect) -> CGRect {
        CGRect(
            x: extent.minX + normalizedRectangle.minX * extent.width,
            y: extent.minY + normalizedRectangle.minY * extent.height,
            width: normalizedRectangle.width * extent.width,
            height: normalizedRectangle.height * extent.height
        ).intersection(extent)
    }
}
