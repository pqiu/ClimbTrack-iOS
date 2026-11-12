import CoreGraphics
import Foundation
import Vision

nonisolated enum PersonSkeletonJoint: String, CaseIterable, Sendable {
    case nose
    case neck
    case root
    case leftShoulder
    case rightShoulder
    case leftElbow
    case rightElbow
    case leftWrist
    case rightWrist
    case leftHip
    case rightHip
    case leftKnee
    case rightKnee
    case leftAnkle
    case rightAnkle

    var visionName: VNHumanBodyPoseObservation.JointName {
        switch self {
        case .nose: .nose
        case .neck: .neck
        case .root: .root
        case .leftShoulder: .leftShoulder
        case .rightShoulder: .rightShoulder
        case .leftElbow: .leftElbow
        case .rightElbow: .rightElbow
        case .leftWrist: .leftWrist
        case .rightWrist: .rightWrist
        case .leftHip: .leftHip
        case .rightHip: .rightHip
        case .leftKnee: .leftKnee
        case .rightKnee: .rightKnee
        case .leftAnkle: .leftAnkle
        case .rightAnkle: .rightAnkle
        }
    }
}

nonisolated struct PersonSkeletonPoint: Sendable {
    let location: CGPoint
    let confidence: Float
}

/// Canonical (upright, bottom-left-origin) pose geometry associated with one
/// person detection. It is display/aiming geometry, not an identity embedding.
nonisolated struct PersonSkeleton: Sendable {
    let joints: [PersonSkeletonJoint: PersonSkeletonPoint]
    let torsoCenter: CGPoint?
    let articulatedBodyLength: CGFloat?
    let boundingBox: CGRect

    static let limbConnections: [(PersonSkeletonJoint, PersonSkeletonJoint)] = [
        (.nose, .neck),
        (.neck, .leftShoulder), (.neck, .rightShoulder),
        (.leftShoulder, .leftElbow), (.leftElbow, .leftWrist),
        (.rightShoulder, .rightElbow), (.rightElbow, .rightWrist),
        (.leftShoulder, .leftHip), (.rightShoulder, .rightHip),
        (.leftHip, .rightHip),
        (.leftHip, .leftKnee), (.leftKnee, .leftAnkle),
        (.rightHip, .rightKnee), (.rightKnee, .rightAnkle)
    ]

    init?(
        observation: VNHumanBodyPoseObservation,
        canonicalRegion: CGRect,
        imageSize: CGSize,
        minimumConfidence: Float
    ) {
        guard let recognized = try? observation.recognizedPoints(.all) else { return nil }
        var mapped: [PersonSkeletonJoint: PersonSkeletonPoint] = [:]
        for joint in PersonSkeletonJoint.allCases {
            guard let point = recognized[joint.visionName],
                  point.confidence >= minimumConfidence else { continue }
            mapped[joint] = PersonSkeletonPoint(
                location: CGPoint(
                    x: canonicalRegion.minX + point.location.x * canonicalRegion.width,
                    y: canonicalRegion.minY + point.location.y * canonicalRegion.height
                ),
                confidence: point.confidence
            )
        }
        guard mapped.count >= 4 else { return nil }
        joints = mapped

        let shoulderCenter = Self.midpoint(mapped[.leftShoulder], mapped[.rightShoulder])
        let hipCenter = Self.midpoint(mapped[.leftHip], mapped[.rightHip])
            ?? mapped[.root]?.location
        if let shoulderCenter, let hipCenter {
            torsoCenter = CGPoint(
                x: (shoulderCenter.x + hipCenter.x) / 2,
                y: (shoulderCenter.y + hipCenter.y) / 2
            )
        } else if let root = mapped[.root]?.location {
            torsoCenter = root
        } else {
            torsoCenter = shoulderCenter
        }

        let locations = mapped.values.map(\.location)
        let minX = locations.map(\.x).min() ?? 0
        let maxX = locations.map(\.x).max() ?? 0
        let minY = locations.map(\.y).min() ?? 0
        let maxY = locations.map(\.y).max() ?? 0
        boundingBox = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        // Summing articulated segments makes this much less sensitive to a
        // crouch than a vertical box height. Require torso plus one complete leg.
        let torso = Self.distance(shoulderCenter, hipCenter, imageSize: imageSize)
        let leftLeg = Self.chainLength(
            [mapped[.leftHip]?.location, mapped[.leftKnee]?.location, mapped[.leftAnkle]?.location],
            imageSize: imageSize
        )
        let rightLeg = Self.chainLength(
            [mapped[.rightHip]?.location, mapped[.rightKnee]?.location, mapped[.rightAnkle]?.location],
            imageSize: imageSize
        )
        let leg = [leftLeg, rightLeg].compactMap { $0 }.reduce(0, +)
            / CGFloat(max([leftLeg, rightLeg].compactMap { $0 }.count, 1))
        if let torso, leg > 0 {
            let head = Self.distance(
                mapped[.neck]?.location,
                mapped[.nose]?.location,
                imageSize: imageSize
            ) ?? 0
            articulatedBodyLength = torso + leg + head * 1.8
        } else {
            articulatedBodyLength = nil
        }
    }

    private static func midpoint(
        _ first: PersonSkeletonPoint?,
        _ second: PersonSkeletonPoint?
    ) -> CGPoint? {
        guard let first, let second else { return nil }
        return CGPoint(
            x: (first.location.x + second.location.x) / 2,
            y: (first.location.y + second.location.y) / 2
        )
    }

    private static func chainLength(
        _ points: [CGPoint?],
        imageSize: CGSize
    ) -> CGFloat? {
        guard points.allSatisfy({ $0 != nil }) else { return nil }
        return zip(points, points.dropFirst()).compactMap {
            distance($0.0, $0.1, imageSize: imageSize)
        }.reduce(0, +)
    }

    private static func distance(
        _ first: CGPoint?,
        _ second: CGPoint?,
        imageSize: CGSize
    ) -> CGFloat? {
        guard let first, let second, imageSize.height > 0 else { return nil }
        let aspect = imageSize.width / imageSize.height
        return hypot((second.x - first.x) * aspect, second.y - first.y)
    }
}

nonisolated enum PersonScaleMeasurementKind: Sendable {
    case articulatedPose
    case fullBodyBox
    case partialLowerBound
}

nonisolated struct PersonScaleMeasurement: Sendable {
    let value: CGFloat
    let kind: PersonScaleMeasurementKind

    var isReliableForHistory: Bool {
        kind != .partialLowerBound
    }
}
