import CoreGraphics

struct PreviewCoordinateConverter {
    static func previewPoint(
        for visionPoint: CGPoint,
        orientedImageSize: CGSize,
        previewSize: CGSize,
        displayCrop: CGRect = TrackingGeometry.unitRectangle
    ) -> CGPoint? {
        guard displayCrop.contains(visionPoint),
              orientedImageSize.width > 0, orientedImageSize.height > 0,
              previewSize.width > 0, previewSize.height > 0 else { return nil }
        let local = CGPoint(
            x: (visionPoint.x - displayCrop.minX) / displayCrop.width,
            y: (visionPoint.y - displayCrop.minY) / displayCrop.height
        )
        let scale = max(
            previewSize.width / orientedImageSize.width,
            previewSize.height / orientedImageSize.height
        )
        let scaled = CGSize(
            width: orientedImageSize.width * scale,
            height: orientedImageSize.height * scale
        )
        return CGPoint(
            x: (previewSize.width - scaled.width) / 2 + local.x * scaled.width,
            y: (previewSize.height - scaled.height) / 2 + (1 - local.y) * scaled.height
        )
    }

    static func previewRectangle(
        for visionRectangle: CGRect,
        orientedImageSize: CGSize,
        previewSize: CGSize,
        displayCrop: CGRect = TrackingGeometry.unitRectangle
    ) -> CGRect? {
        guard orientedImageSize.width > 0,
              orientedImageSize.height > 0,
              previewSize.width > 0,
              previewSize.height > 0 else { return nil }

        guard let cropLocalRectangle = TrackingGeometry.localRectangle(
            fromCanonical: visionRectangle,
            in: displayCrop
        ) else { return nil }

        // Vision rectangles use a bottom-left origin. Convert to an upright,
        // top-left normalized rectangle before applying aspect-fill geometry.
        let normalizedTopLeft = CGRect(
            x: cropLocalRectangle.minX,
            y: 1 - cropLocalRectangle.maxY,
            width: cropLocalRectangle.width,
            height: cropLocalRectangle.height
        )

        let scale = max(
            previewSize.width / orientedImageSize.width,
            previewSize.height / orientedImageSize.height
        )
        let scaledImageSize = CGSize(
            width: orientedImageSize.width * scale,
            height: orientedImageSize.height * scale
        )
        let cropOffset = CGPoint(
            x: (previewSize.width - scaledImageSize.width) / 2,
            y: (previewSize.height - scaledImageSize.height) / 2
        )

        let previewRectangle = CGRect(
            x: cropOffset.x + normalizedTopLeft.minX * scaledImageSize.width,
            y: cropOffset.y + normalizedTopLeft.minY * scaledImageSize.height,
            width: normalizedTopLeft.width * scaledImageSize.width,
            height: normalizedTopLeft.height * scaledImageSize.height
        )
        let visibleRectangle = previewRectangle.intersection(
            CGRect(origin: .zero, size: previewSize)
        )

        guard !visibleRectangle.isNull,
              visibleRectangle.width > 1,
              visibleRectangle.height > 1 else { return nil }
        return visibleRectangle
    }
}
