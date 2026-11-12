import CoreGraphics
import Foundation

enum PersonDetectionSource: String, Sendable {
    case body
    case upperBody = "upper body"
    case face
    case yolox = "YOLOX"
    case merged
}

struct PersonDetection: Identifiable, Sendable {
    let id: UUID
    let normalizedBoundingBox: CGRect
    let source: PersonDetectionSource
    let confidence: Float
    let skeleton: PersonSkeleton?
    let scaleMeasurement: PersonScaleMeasurement?

    nonisolated init(
        id: UUID,
        normalizedBoundingBox: CGRect,
        source: PersonDetectionSource,
        confidence: Float,
        skeleton: PersonSkeleton? = nil,
        scaleMeasurement: PersonScaleMeasurement? = nil
    ) {
        self.id = id
        self.normalizedBoundingBox = normalizedBoundingBox
        self.source = source
        self.confidence = confidence
        self.skeleton = skeleton
        self.scaleMeasurement = scaleMeasurement
    }
}

struct PersonDetectionFrame: Sendable {
    let detections: [PersonDetection]
    let orientedImageSize: CGSize
    let targetPresentation: TargetPresentation?
    let trackingMetadata: TrackingFrameMetadata

    nonisolated init(
        detections: [PersonDetection],
        orientedImageSize: CGSize,
        targetPresentation: TargetPresentation? = nil,
        trackingMetadata: TrackingFrameMetadata = .fullFrame
    ) {
        self.detections = detections
        self.orientedImageSize = orientedImageSize
        self.targetPresentation = targetPresentation
        self.trackingMetadata = trackingMetadata
    }

    nonisolated static let empty = PersonDetectionFrame(
        detections: [],
        orientedImageSize: .zero
    )
}

struct DetectionMerging {
    struct Evidence {
        var boundingBox: CGRect
        var source: PersonDetectionSource
        var confidence: Float
    }

    nonisolated static func merge(
        fullBodies: [Evidence],
        upperBodies: [Evidence],
        faces: [Evidence]
    ) -> [PersonDetection] {
        var people = mergeOverlappingBodies(fullBodies + upperBodies)

        for face in faces {
            if let match = people.indices.first(where: {
                shouldAssociate(face: face.boundingBox, person: people[$0].boundingBox)
            }) {
                people[match].boundingBox = clipped(
                    people[match].boundingBox.union(face.boundingBox)
                )
                people[match].confidence = max(people[match].confidence, face.confidence)
                people[match].source = .merged
            } else {
                people.append(
                    Evidence(
                        boundingBox: expandedVisibleUpperBody(from: face.boundingBox),
                        source: .face,
                        confidence: face.confidence
                    )
                )
            }
        }

        return mergeDuplicateCandidates(people).map {
            PersonDetection(
                id: UUID(),
                normalizedBoundingBox: clipped($0.boundingBox),
                source: $0.source,
                confidence: $0.confidence
            )
        }
    }

    private nonisolated static func mergeOverlappingBodies(_ detections: [Evidence]) -> [Evidence] {
        var merged: [Evidence] = []

        for detection in detections.sorted(by: {
            area($0.boundingBox) > area($1.boundingBox)
        }) {
            if let match = merged.indices.first(where: {
                overlapRatio(detection.boundingBox, merged[$0].boundingBox) > 0.55
                    || intersectionOverUnion(detection.boundingBox, merged[$0].boundingBox) > 0.35
            }) {
                merged[match].boundingBox = clipped(
                    merged[match].boundingBox.union(detection.boundingBox)
                )
                merged[match].confidence = max(merged[match].confidence, detection.confidence)
                if merged[match].source != detection.source {
                    merged[match].source = .merged
                }
            } else {
                merged.append(detection)
            }
        }

        return merged
    }

    private nonisolated static func mergeDuplicateCandidates(_ detections: [Evidence]) -> [Evidence] {
        var merged: [Evidence] = []

        for detection in detections {
            if let match = merged.indices.first(where: {
                intersectionOverUnion(detection.boundingBox, merged[$0].boundingBox) > 0.65
            }) {
                merged[match].boundingBox = clipped(
                    merged[match].boundingBox.union(detection.boundingBox)
                )
                merged[match].confidence = max(merged[match].confidence, detection.confidence)
                merged[match].source = .merged
            } else {
                merged.append(detection)
            }
        }

        return merged
    }

    private nonisolated static func shouldAssociate(face: CGRect, person: CGRect) -> Bool {
        let faceCenter = CGPoint(x: face.midX, y: face.midY)
        let faceOverlap = area(face.intersection(person)) / max(area(face), .leastNonzeroMagnitude)
        return person.contains(faceCenter) || faceOverlap > 0.3
    }

    private nonisolated static func expandedVisibleUpperBody(from face: CGRect) -> CGRect {
        // Vision uses a bottom-left origin. Preserve a little space above the
        // head and expand primarily downward toward visible shoulders/torso.
        let width = face.width * 2.4
        let top = face.maxY + face.height * 0.15
        let bottom = face.minY - face.height * 1.8
        let candidate = CGRect(
            x: face.midX - width / 2,
            y: bottom,
            width: width,
            height: top - bottom
        )
        return clipped(candidate)
    }

    private nonisolated static func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = area(first.intersection(second))
        let union = area(first) + area(second) - intersection
        return union > 0 ? intersection / union : 0
    }

    private nonisolated static func overlapRatio(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let smallerArea = min(area(first), area(second))
        guard smallerArea > 0 else { return 0 }
        return area(first.intersection(second)) / smallerArea
    }

    private nonisolated static func area(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else {
            return 0
        }
        return rect.width * rect.height
    }

    private nonisolated static func clipped(_ rect: CGRect) -> CGRect {
        rect.standardized.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
