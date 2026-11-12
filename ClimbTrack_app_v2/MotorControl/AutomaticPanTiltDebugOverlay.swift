import SwiftUI

struct AutomaticPanTiltDebugOverlay: View {
    @ObservedObject var controller: AutomaticPanTiltController
    let frame: PersonDetectionFrame

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if controller.isSessionActive {
                    zoneRectangle(
                        horizontalThreshold: controller.configuration.horizontalOuterThreshold,
                        verticalThreshold: controller.configuration.verticalOuterThreshold,
                        color: .orange,
                        dash: [7, 5],
                        previewSize: geometry.size
                    )
                    zoneRectangle(
                        horizontalThreshold: controller.configuration.horizontalInnerThreshold,
                        verticalThreshold: controller.configuration.verticalInnerThreshold,
                        color: .green,
                        dash: [4, 4],
                        previewSize: geometry.size
                    )

                    Circle()
                        .fill(.cyan)
                        .frame(width: 8, height: 8)
                        .position(cropCenter(in: geometry.size))

                    Circle()
                        .stroke(.purple, lineWidth: 2)
                        .frame(width: 12, height: 12)
                        .position(intendedTargetCenter(in: geometry.size))

                    if let targetCenter = targetCenter(in: geometry.size) {
                        Circle()
                            .fill(.red)
                            .frame(width: 10, height: 10)
                            .position(targetCenter)
                    }

                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func zoneRectangle(
        horizontalThreshold: CGFloat,
        verticalThreshold: CGFloat,
        color: Color,
        dash: [CGFloat],
        previewSize: CGSize
    ) -> some View {
        let crop = frame.trackingMetadata.displayCrop
        let intendedCenter = intendedCanonicalCenter
        let rectangle = CGRect(
            x: intendedCenter.x - crop.width * horizontalThreshold,
            y: intendedCenter.y - crop.height * verticalThreshold,
            width: crop.width * horizontalThreshold * 2,
            height: crop.height * verticalThreshold * 2
        )
        if let previewRectangle = PreviewCoordinateConverter.previewRectangle(
            for: rectangle,
            orientedImageSize: frame.orientedImageSize,
            previewSize: previewSize,
            displayCrop: crop
        ) {
            Rectangle()
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dash))
                .frame(width: previewRectangle.width, height: previewRectangle.height)
                .offset(x: previewRectangle.minX, y: previewRectangle.minY)
        }
    }

    private func cropCenter(in previewSize: CGSize) -> CGPoint {
        let crop = frame.trackingMetadata.displayCrop
        let marker = CGRect(
            x: crop.midX - 0.002,
            y: crop.midY - 0.002,
            width: 0.004,
            height: 0.004
        )
        guard let rectangle = PreviewCoordinateConverter.previewRectangle(
            for: marker,
            orientedImageSize: frame.orientedImageSize,
            previewSize: previewSize,
            displayCrop: crop
        ) else {
            return CGPoint(x: previewSize.width / 2, y: previewSize.height / 2)
        }
        return CGPoint(x: rectangle.midX, y: rectangle.midY)
    }

    private var intendedCanonicalCenter: CGPoint {
        let crop = frame.trackingMetadata.displayCrop
        return CGPoint(
            x: crop.midX + crop.width * controller.configuration.horizontalTargetOffset,
            y: crop.midY + crop.height * controller.configuration.verticalTargetOffset
        )
    }

    private func intendedTargetCenter(in previewSize: CGSize) -> CGPoint {
        let center = intendedCanonicalCenter
        let marker = CGRect(
            x: center.x - 0.002,
            y: center.y - 0.002,
            width: 0.004,
            height: 0.004
        )
        guard let rectangle = PreviewCoordinateConverter.previewRectangle(
            for: marker,
            orientedImageSize: frame.orientedImageSize,
            previewSize: previewSize,
            displayCrop: frame.trackingMetadata.displayCrop
        ) else {
            return cropCenter(in: previewSize)
        }
        return CGPoint(x: rectangle.midX, y: rectangle.midY)
    }

    private func targetCenter(in previewSize: CGSize) -> CGPoint? {
        guard let box = frame.trackingMetadata.canonicalTargetBox else { return nil }
        let marker = CGRect(
            x: box.midX - 0.002,
            y: box.midY - 0.002,
            width: 0.004,
            height: 0.004
        )
        guard let rectangle = PreviewCoordinateConverter.previewRectangle(
            for: marker,
            orientedImageSize: frame.orientedImageSize,
            previewSize: previewSize,
            displayCrop: frame.trackingMetadata.displayCrop
        ) else { return nil }
        return CGPoint(x: rectangle.midX, y: rectangle.midY)
    }

}
