import CoreGraphics
import Foundation

enum TargetVisibilityState: String, Sendable {
    case unlocked
    case lockedVisible
    case lockedAmbiguous
    case lockedMissing
}

/// Main-thread snapshot of identity state. Appearance embeddings stay private to
/// the tracking worker, while future features can consume stable target geometry.
struct TrackedTarget: Sendable {
    let latestBoundingBox: CGRect
    let previousBoundingBoxes: [CGRect]
    let center: CGPoint
    let aimingCenter: CGPoint
    let estimatedVelocity: CGVector
    let boundingBoxSize: CGSize
    let detectionConfidence: Float
    let lastSeenTimestamp: TimeInterval
    let visibilityState: TargetVisibilityState
    let matchConfidence: Float
    let appearanceGalleryCount: Int
    let bestAppearanceSampleIndex: Int?
    let originalColorCharacteristics: [Float]
    let consecutiveMisses: Int
}

/// Latest appearance-cycle evidence explaining why the gallery did or did not update.
struct GalleryUpdateDiagnostic: Sendable {
    let totalScore: CGFloat?
    let identityScore: CGFloat?
    let margin: CGFloat?
    let cropArea: CGFloat?
    let cropPassed: Bool?
    let framePassed: Bool?
    let novelty: Float?
    let noveltyPassed: Bool?
    let result: String

    nonisolated var scoreText: String {
        let total = totalScore.map { String(format: "%.2f", $0) } ?? "—"
        let identity = identityScore.map { String(format: "%.2f", $0) } ?? "—"
        let margin = margin.map { String(format: "%.2f", $0) } ?? "—"
        return "Total: \(total) · ID: \(identity) · Margin: \(margin)"
    }

    nonisolated var gateText: String {
        let crop = passText(cropPassed, value: cropArea.map { String(format: "%.3f", $0) })
        let frame = passText(framePassed, value: nil)
        let novelty = passText(
            noveltyPassed,
            value: novelty.map { String(format: "%.3f", $0) }
        )
        return "Crop: \(crop) · Edge info: \(frame) · Novelty: \(novelty)"
    }

    nonisolated private func passText(_ passed: Bool?, value: String?) -> String {
        let displayedValue = value.map { " \($0)" } ?? ""
        return switch passed {
        case true: "PASS\(displayedValue)"
        case false: "FAIL\(displayedValue)"
        case nil: "—\(displayedValue)"
        }
    }
}

struct TargetPresentation: Sendable {
    let state: TargetVisibilityState
    let matchedDetectionID: UUID?
    let uncertainBoundingBox: CGRect?
    let appearanceGalleryCount: Int
    let appearanceGalleryCapacity: Int
    let bestAppearanceSampleIndex: Int?
    let galleryUpdateDiagnostic: GalleryUpdateDiagnostic?
    let scaleDiagnosticText: String?
    let trackingStatusReason: String?
    let consecutiveMisses: Int

    nonisolated var statusText: String? {
        switch state {
        case .unlocked, .lockedVisible:
            nil
        case .lockedAmbiguous:
            "TARGET UNCERTAIN — LOCK PRESERVED"
        case .lockedMissing:
            "TARGET MISSING — LOCK PRESERVED"
        }
    }

    nonisolated var galleryDiagnosticText: String {
        let best = bestAppearanceSampleIndex.map { "#\($0)" } ?? "—"
        return "Gallery: \(appearanceGalleryCount)/\(appearanceGalleryCapacity) · Best: \(best)"
    }

    nonisolated var statusReasonText: String? {
        guard state == .lockedAmbiguous || state == .lockedMissing else { return nil }
        let reason = trackingStatusReason ?? "INTERNAL: MISS REASON WAS NOT RECORDED"
        return "MISS \(consecutiveMisses) · \(reason)"
    }
}
