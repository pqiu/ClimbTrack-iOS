import SwiftUI

struct PersonDetectionOverlay: View {
    let frame: PersonDetectionFrame
    let gestureStatus: GestureStatus?
    let gestureDiagnosticText: String?
    let allowsSelection: Bool
    let onSelect: (UUID) -> Void

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                Color.clear
                    .contentShape(Rectangle())

                Canvas { context, size in
                    for detection in frame.detections {
                        guard let skeleton = detection.skeleton else { continue }
                        let isTarget = frame.targetPresentation?.matchedDetectionID == detection.id
                        let color = isTarget ? Color.red : Color.green
                        for connection in PersonSkeleton.limbConnections {
                            guard let first = skeleton.joints[connection.0],
                                  let second = skeleton.joints[connection.1],
                                  let start = PreviewCoordinateConverter.previewPoint(
                                    for: first.location,
                                    orientedImageSize: frame.orientedImageSize,
                                    previewSize: size,
                                    displayCrop: frame.trackingMetadata.displayCrop
                                  ),
                                  let end = PreviewCoordinateConverter.previewPoint(
                                    for: second.location,
                                    orientedImageSize: frame.orientedImageSize,
                                    previewSize: size,
                                    displayCrop: frame.trackingMetadata.displayCrop
                                  ) else { continue }
                            var path = Path()
                            path.move(to: start)
                            path.addLine(to: end)
                            context.stroke(path, with: .color(color), lineWidth: isTarget ? 4 : 3)
                        }
                        for point in skeleton.joints.values {
                            guard let location = PreviewCoordinateConverter.previewPoint(
                                for: point.location,
                                orientedImageSize: frame.orientedImageSize,
                                previewSize: size,
                                displayCrop: frame.trackingMetadata.displayCrop
                            ) else { continue }
                            let circle = CGRect(
                                x: location.x - 3,
                                y: location.y - 3,
                                width: 6,
                                height: 6
                            )
                            context.fill(Path(ellipseIn: circle), with: .color(color))
                        }
                    }
                }
                .allowsHitTesting(false)

                ForEach(frame.detections) { detection in
                    if let rectangle = PreviewCoordinateConverter.previewRectangle(
                        for: detection.normalizedBoundingBox,
                        orientedImageSize: frame.orientedImageSize,
                        previewSize: geometry.size,
                        displayCrop: frame.trackingMetadata.displayCrop
                    ) {
                        detectionBox(
                            detection,
                            isTarget: frame.targetPresentation?.matchedDetectionID == detection.id,
                            isGestureCandidate: gestureStatus?.detectionID == detection.id
                        )
                            .frame(width: rectangle.width, height: rectangle.height)
                            .offset(x: rectangle.minX, y: rectangle.minY)
                    }
                }

                if frame.targetPresentation?.state == .lockedAmbiguous,
                   let uncertainBox = frame.targetPresentation?.uncertainBoundingBox,
                   let rectangle = PreviewCoordinateConverter.previewRectangle(
                    for: uncertainBox,
                    orientedImageSize: frame.orientedImageSize,
                    previewSize: geometry.size,
                    displayCrop: frame.trackingMetadata.displayCrop
                   ) {
                    Rectangle()
                        .stroke(.orange, style: StrokeStyle(lineWidth: 3, dash: [8, 6]))
                        .frame(width: rectangle.width, height: rectangle.height)
                        .offset(x: rectangle.minX, y: rectangle.minY)
                }

                if TrackingDebugConfiguration.showsScreenOverlays,
                   frame.trackingMetadata.analysisRegion != TrackingGeometry.unitRectangle,
                   let rectangle = PreviewCoordinateConverter.previewRectangle(
                    for: frame.trackingMetadata.analysisRegion,
                    orientedImageSize: frame.orientedImageSize,
                    previewSize: geometry.size,
                    displayCrop: frame.trackingMetadata.displayCrop
                   ) {
                    Rectangle()
                        .stroke(.cyan, style: StrokeStyle(lineWidth: 2, dash: [5, 4]))
                        .frame(width: rectangle.width, height: rectangle.height)
                        .offset(x: rectangle.minX, y: rectangle.minY)
                }

                if TrackingDebugConfiguration.showsScreenOverlays {
                    VStack(spacing: 8) {
                        if let gestureStatus {
                            gestureProgressPanel(gestureStatus)
                        } else if let gestureDiagnosticText {
                            diagnosticTextPanel(gestureDiagnosticText, color: .yellow)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.top, 45)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .gesture(
                SpatialTapGesture().onEnded { value in
                    selectDetection(at: value.location, previewSize: geometry.size)
                }
            )
        }
        .accessibilityHidden(true)
    }

    private func diagnosticTextPanel(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.monospacedDigit().weight(.bold))
            .multilineTextAlignment(.center)
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity)
    }

    private func gestureProgressPanel(_ status: GestureStatus) -> some View {
        VStack(spacing: 5) {
            Text(status.displayText)
                .font(.caption2.monospacedDigit().weight(.bold))
            ProgressView(value: status.holdProgress)
                .tint(.yellow)
                .frame(width: 190)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(.black.opacity(0.70), in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity)
    }

    private func detectionBox(
        _ detection: PersonDetection,
        isTarget: Bool,
        isGestureCandidate: Bool
    ) -> some View {
        let color: Color = isTarget ? .red : (isGestureCandidate ? .yellow : .green)

        return ZStack(alignment: .topLeading) {
            Rectangle()
                .stroke(color, lineWidth: isTarget ? 3 : 2)

            Text(detectionLabel(detection, isTarget: isTarget))
                .font(.caption2.monospacedDigit().weight(.semibold))
                .foregroundStyle(.black)
                .padding(.horizontal, 4)
                .padding(.vertical, 2)
                .background(color.opacity(0.9))
        }
    }

    private func detectionLabel(_ detection: PersonDetection, isTarget: Bool) -> String {
        let confidence = Int(detection.confidence * 100)
        return isTarget
            ? "TARGET · \(detection.source.rawValue) \(confidence)%"
            : "\(detection.source.rawValue) \(confidence)%"
    }

    private func selectDetection(at location: CGPoint, previewSize: CGSize) {
        guard allowsSelection else { return }

        let selected = frame.detections.compactMap { detection -> (UUID, CGFloat)? in
            guard let rectangle = PreviewCoordinateConverter.previewRectangle(
                for: detection.normalizedBoundingBox,
                orientedImageSize: frame.orientedImageSize,
                previewSize: previewSize,
                displayCrop: frame.trackingMetadata.displayCrop
            ), rectangle.contains(location) else { return nil }
            return (detection.id, rectangle.width * rectangle.height)
        }.min { $0.1 < $1.1 }

        if let selected {
            onSelect(selected.0)
        }
    }
}
