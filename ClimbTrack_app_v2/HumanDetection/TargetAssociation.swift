import CoreGraphics
import Foundation

nonisolated struct TargetAssociationConfiguration {
    // Field-test weights. Area and aspect remain observable but do not affect matching.
    let featureWeight: CGFloat = 0.35
    let colorWeight: CGFloat = 0.20
    let positionWeight: CGFloat = 0.275
    let overlapWeight: CGFloat = 0.175
    let sizeWeight: CGFloat = 0
    let aspectRatioWeight: CGFloat = 0
    let geometryOnlyPositionWeight: CGFloat = 0.625
    let geometryOnlyOverlapWeight: CGFloat = 0.375

    let appearanceMatchThreshold: CGFloat = 0.50
    let geometryOnlyMatchThreshold: CGFloat = 0.60
    let appearanceMinimumMargin: CGFloat = 0.05
    let geometryOnlyMinimumMargin: CGFloat = 0.05
    let maximumReacquisitionCandidateMisses = 4
    let missingAfterFrames = 3
    let appearanceInterval: TimeInterval = 0.375
    let maximumGalleryCount = 50
    let galleryNoveltyThreshold: Float = 0.12
    let galleryReplacementImprovement: Float = 0.02
    let galleryUpdateIdentityThreshold: CGFloat = 0.5
    let galleryUpdateMatchThreshold: CGFloat = 0.70
    let maximumAppearanceCandidates = 4
}

nonisolated struct TargetAssociationScore {
    let total: CGFloat
    let appearance: CGFloat?
    let feature: CGFloat?
    let color: CGFloat?
    let position: CGFloat
    let overlap: CGFloat
    let size: CGFloat
    let aspectRatio: CGFloat
    let continuityReference: ContinuityReference
}

nonisolated enum ContinuityReference: Sendable {
    case predicted
    case lastObserved
}

nonisolated enum TargetAssociation {
    static func score(
        candidate: CGRect,
        predictedTarget: CGRect,
        lastObservedTarget: CGRect,
        featureSimilarity: Float?,
        colorSimilarity: Float?,
        configuration: TargetAssociationConfiguration
    ) -> TargetAssociationScore {
        let predictedMetrics = continuityMetrics(
            candidate: candidate,
            reference: predictedTarget,
            configuration: configuration,
            usesAppearanceWeights: featureSimilarity != nil && colorSimilarity != nil
        )
        let lastObservedMetrics = continuityMetrics(
            candidate: candidate,
            reference: lastObservedTarget,
            configuration: configuration,
            usesAppearanceWeights: featureSimilarity != nil && colorSimilarity != nil
        )
        let selected = predictedMetrics.weightedScore >= lastObservedMetrics.weightedScore
            ? (predictedMetrics, ContinuityReference.predicted)
            : (lastObservedMetrics, ContinuityReference.lastObserved)
        let position = selected.0.position
        let overlap = selected.0.overlap
        let size = ratioConsistency(area(candidate), area(selected.0.reference))
        let aspect = ratioConsistency(
            candidate.width / max(candidate.height, .leastNonzeroMagnitude),
            selected.0.reference.width / max(selected.0.reference.height, .leastNonzeroMagnitude)
        )

        if let featureSimilarity, let colorSimilarity {
            let feature = CGFloat(featureSimilarity)
            let color = CGFloat(colorSimilarity)
            let total = feature * configuration.featureWeight
                + color * configuration.colorWeight
                + position * configuration.positionWeight
                + overlap * configuration.overlapWeight
                + size * configuration.sizeWeight
                + aspect * configuration.aspectRatioWeight
            let appearanceWeight = configuration.featureWeight + configuration.colorWeight
            return TargetAssociationScore(
                total: total,
                appearance: (feature * configuration.featureWeight
                    + color * configuration.colorWeight) / appearanceWeight,
                feature: feature,
                color: color,
                position: position,
                overlap: overlap,
                size: size,
                aspectRatio: aspect,
                continuityReference: selected.1
            )
        }

        // Geometry-only frames bridge the deliberately throttled appearance checks.
        let total = position * configuration.geometryOnlyPositionWeight
            + overlap * configuration.geometryOnlyOverlapWeight
        return TargetAssociationScore(
            total: total,
            appearance: nil,
            feature: nil,
            color: nil,
            position: position,
            overlap: overlap,
            size: size,
            aspectRatio: aspect,
            continuityReference: selected.1
        )
    }

    private struct ContinuityMetrics {
        let reference: CGRect
        let position: CGFloat
        let overlap: CGFloat
        let weightedScore: CGFloat
    }

    private static func continuityMetrics(
        candidate: CGRect,
        reference: CGRect,
        configuration: TargetAssociationConfiguration,
        usesAppearanceWeights: Bool
    ) -> ContinuityMetrics {
        let centerDistance = hypot(
            candidate.midX - reference.midX,
            candidate.midY - reference.midY
        )
        let position = max(0, 1 - centerDistance / 0.5)
        let overlap = intersectionOverUnion(candidate, reference)
        let positionWeight = usesAppearanceWeights
            ? configuration.positionWeight
            : configuration.geometryOnlyPositionWeight
        let overlapWeight = usesAppearanceWeights
            ? configuration.overlapWeight
            : configuration.geometryOnlyOverlapWeight
        return ContinuityMetrics(
            reference: reference,
            position: position,
            overlap: overlap,
            weightedScore: position * positionWeight + overlap * overlapWeight
        )
    }

    static func intersectionOverUnion(_ first: CGRect, _ second: CGRect) -> CGFloat {
        let intersection = area(first.intersection(second))
        let union = area(first) + area(second) - intersection
        return union > 0 ? intersection / union : 0
    }

    static func centersAreClose(_ first: CGRect, _ second: CGRect) -> Bool {
        hypot(first.midX - second.midX, first.midY - second.midY) < 0.12
    }

    private static func ratioConsistency(_ first: CGFloat, _ second: CGFloat) -> CGFloat {
        guard first > 0, second > 0 else { return 0 }
        return exp(-abs(log(first / second)))
    }

    private static func area(_ rectangle: CGRect) -> CGFloat {
        guard !rectangle.isNull, rectangle.width > 0, rectangle.height > 0 else { return 0 }
        return rectangle.width * rectangle.height
    }
}
