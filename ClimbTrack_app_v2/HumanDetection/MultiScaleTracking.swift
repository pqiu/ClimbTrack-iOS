import CoreGraphics
import Foundation

nonisolated enum TrackingAnalysisMode: String, Sendable {
    case fullFrame = "FULL"
    case displayCrop = "DISPLAY CROP"
    case reacquisitionCenter = "SEARCH CENTER"
    case reacquisitionFirstRing = "SEARCH RING 1"
    case reacquisitionSecondRing = "SEARCH RING 2"
    case reacquisitionConfirmation = "CONFIRMING TARGET"
}

nonisolated struct TrackingFrameMetadata: Sendable {
    let timestamp: TimeInterval
    let analysisMode: TrackingAnalysisMode
    let analysisRegion: CGRect
    let displayCrop: CGRect
    let zoomFactor: CGFloat
    let canonicalTargetBox: CGRect?
    let targetConfidence: Float?
    let targetVisibility: TargetVisibilityState?

    static let fullFrame = TrackingFrameMetadata(
        timestamp: 0,
        analysisMode: .fullFrame,
        analysisRegion: TrackingGeometry.unitRectangle,
        displayCrop: TrackingGeometry.unitRectangle,
        zoomFactor: 1,
        canonicalTargetBox: nil,
        targetConfidence: nil,
        targetVisibility: nil
    )
}

nonisolated struct TrackingAnalysisPlan {
    let mode: TrackingAnalysisMode
    let region: CGRect
}

/// Shares the user-selected idle crop with Vision's worker queue. Automatic
/// tracking keeps ownership of its own crop after a target is selected.
nonisolated final class IdleFramingBridge: @unchecked Sendable {
    static let maximumZoom: CGFloat = 15

    private let lock = NSLock()
    private var zoomFactor: CGFloat = 1

    func updateZoomFactor(_ value: CGFloat) {
        lock.lock()
        zoomFactor = min(Self.maximumZoom, max(1, value))
        lock.unlock()
    }

    func crop() -> CGRect {
        lock.lock()
        defer { lock.unlock() }
        let size = 1 / zoomFactor
        return TrackingGeometry.centeredRectangle(
            center: CGPoint(x: 0.5, y: 0.5),
            size: CGSize(width: size, height: size)
        )
    }
}

/// Chooses the analysis region and visual viewport. Identity remains exclusively
/// owned by TargetTracker; this coordinator only consumes its public snapshot.
nonisolated final class MultiScaleTrackingCoordinator: @unchecked Sendable {
    private struct SearchStep {
        let mode: TrackingAnalysisMode
        let region: CGRect
    }

    private enum ZoomAdjustmentState {
        case needsInitialFraming
        case holding
        case zoomingIn
        case zoomingOut
    }

    struct Configuration {
        // One deliberate ceiling for the entire app's digital zoom behavior.
        let maximumZoom: CGFloat = 15
        let surroundingSearchMisses = 6
        let targetSettlingTolerance: CGFloat = 0.01
        let cropBoundaryUrgentMargin: CGFloat = 0.025
        let displayedEdgePressureThreshold: CGFloat = 0.35
    }

    private let configuration = Configuration()
    private let zoomTuningBridge: ZoomTuningBridge
    private let idleFramingBridge: IdleFramingBridge
    private var displayCrop = TrackingGeometry.unitRectangle
    private var searchSteps: [SearchStep] = []
    private var searchStepIndex = 0
    private var searchCropSize = CGSize.zero
    private var zoomAdjustmentState = ZoomAdjustmentState.needsInitialFraming
    private var lastZoomTuning: ZoomTuningSnapshot?

    init(
        zoomTuningBridge: ZoomTuningBridge,
        idleFramingBridge: IdleFramingBridge
    ) {
        self.zoomTuningBridge = zoomTuningBridge
        self.idleFramingBridge = idleFramingBridge
    }

    func reset() {
        displayCrop = idleFramingBridge.crop()
        resetSearch()
        zoomAdjustmentState = .needsInitialFraming
        lastZoomTuning = nil
    }

    func analysisPlan(for tracking: TargetTrackerOutput) -> TrackingAnalysisPlan {
        guard let target = tracking.target,
              tracking.presentation != nil else {
            resetSearch()
            return TrackingAnalysisPlan(mode: .fullFrame, region: idleFramingBridge.crop())
        }

        if target.visibilityState != .lockedVisible,
           let candidateBox = tracking.reacquisitionCandidateBox {
            // Once identity has a plausible candidate, keep analyzing a crop
            // containing it until the tracker confirms or rejects it.
            return TrackingAnalysisPlan(
                mode: .reacquisitionConfirmation,
                region: TrackingGeometry.centeredRectangle(
                    center: CGPoint(x: candidateBox.midX, y: candidateBox.midY),
                    size: displayCrop.size
                )
            )
        }

        guard target.consecutiveMisses >= configuration.surroundingSearchMisses else {
            resetSearch()
            // Vision sees exactly the crop shown to the user. Motion prediction
            // remains available to identity association, but never moves this crop.
            return TrackingAnalysisPlan(mode: .displayCrop, region: displayCrop)
        }

        if searchSteps.isEmpty || searchCropSize != displayCrop.size {
            rebuildSearchSteps()
        }
        let step = searchSteps[searchStepIndex]
        searchStepIndex = (searchStepIndex + 1) % searchSteps.count
        return TrackingAnalysisPlan(mode: step.mode, region: step.region)
    }

    private func rebuildSearchSteps() {
        searchSteps = []
        searchStepIndex = 0
        searchCropSize = displayCrop.size

        let center = displayCrop
        var surroundingRegions: [CGRect] = []
        let directions = [
            CGVector(dx: 0, dy: 1),
            CGVector(dx: 1, dy: 1),
            CGVector(dx: 1, dy: 0),
            CGVector(dx: 1, dy: -1),
            CGVector(dx: 0, dy: -1),
            CGVector(dx: -1, dy: -1),
            CGVector(dx: -1, dy: 0),
            CGVector(dx: -1, dy: 1)
        ]

        for (mode, displacement) in [
            (TrackingAnalysisMode.reacquisitionFirstRing, CGFloat(0.5)),
            (TrackingAnalysisMode.reacquisitionSecondRing, CGFloat(1.0))
        ] {
            for direction in directions {
                let region = TrackingGeometry.centeredRectangle(
                    center: CGPoint(
                        x: center.midX + direction.dx * center.width * displacement,
                        y: center.midY + direction.dy * center.height * displacement
                    ),
                    size: center.size
                )
                guard !sameRegion(region, center),
                      !surroundingRegions.contains(where: { sameRegion($0, region) }) else {
                    continue
                }
                // Recheck the most likely location between every outward search.
                searchSteps.append(SearchStep(mode: .reacquisitionCenter, region: center))
                searchSteps.append(SearchStep(mode: mode, region: region))
                surroundingRegions.append(region)
            }
        }

        if searchSteps.isEmpty {
            searchSteps = [SearchStep(mode: .reacquisitionCenter, region: center)]
        }
    }

    private func resetSearch() {
        searchSteps = []
        searchStepIndex = 0
        searchCropSize = .zero
    }

    private func sameRegion(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        let tolerance: CGFloat = 0.000_001
        return abs(lhs.minX - rhs.minX) < tolerance
            && abs(lhs.minY - rhs.minY) < tolerance
            && abs(lhs.width - rhs.width) < tolerance
            && abs(lhs.height - rhs.height) < tolerance
    }

    func metadata(
        after tracking: TargetTrackerOutput,
        plan: TrackingAnalysisPlan,
        timestamp: TimeInterval
    ) -> TrackingFrameMetadata {
        let optionalTarget = tracking.target
        guard let target = optionalTarget,
              tracking.presentation != nil else {
            displayCrop = plan.region
            zoomAdjustmentState = .needsInitialFraming
            let zoom = min(configuration.maximumZoom, max(1, 1 / displayCrop.width))
            return TrackingFrameMetadata(
                timestamp: timestamp,
                analysisMode: plan.mode,
                analysisRegion: plan.region,
                displayCrop: displayCrop,
                zoomFactor: zoom,
                canonicalTargetBox: optionalTarget?.latestBoundingBox,
                targetConfidence: optionalTarget?.matchConfidence,
                targetVisibility: optionalTarget?.visibilityState
            )
        }

        if target.visibilityState == .lockedVisible {
            let tuning = zoomTuningBridge.snapshot()
            if lastZoomTuning != tuning {
                // Preserve the current crop when switching algorithms, but
                // restart the active control law so live parameter edits take
                // effect without requiring a new tracking session.
                zoomAdjustmentState = .needsInitialFraming
                lastZoomTuning = tuning
            }
            let currentZoom = min(
                configuration.maximumZoom,
                max(1, 1 / displayCrop.width)
            )
            let largerCanonicalDimension = max(
                target.boundingBoxSize.width,
                target.boundingBoxSize.height
            )
            let displayedTargetFraction = largerCanonicalDimension * currentZoom
            var desiredZoom: CGFloat
            let smoothing: CGFloat
            switch tuning.mode {
            case .hysteresis:
                updateZoomAdjustmentState(
                    for: displayedTargetFraction,
                    tuning: tuning
                )
                switch zoomAdjustmentState {
                case .holding:
                    desiredZoom = currentZoom
                case .needsInitialFraming, .zoomingIn, .zoomingOut:
                    desiredZoom = min(
                        configuration.maximumZoom,
                        max(
                            1,
                            tuning.hysteresisTargetFraction
                                / max(largerCanonicalDimension, 0.001)
                        )
                    )
                }
                smoothing = tuning.hysteresisViewportSmoothing

            case .continuous:
                let targetFraction = 1 / tuning.continuousFramingScale
                if abs(displayedTargetFraction - targetFraction)
                    <= tuning.continuousToleranceFraction {
                    desiredZoom = currentZoom
                } else {
                    desiredZoom = min(
                        configuration.maximumZoom,
                        max(
                            1,
                            1 / max(
                                largerCanonicalDimension * tuning.continuousFramingScale,
                                0.001
                            )
                        )
                    )
                }
                smoothing = tuning.continuousViewportSmoothing
            }
            if hasUrgentBoundaryPressure(target: target, crop: displayCrop) {
                // Digital framing has reached the source image boundary. Avoid
                // zooming farther in and gently recover context while physical
                // pan/tilt works to recenter the camera.
                desiredZoom = max(1, min(desiredZoom, currentZoom * 0.90))
                zoomAdjustmentState = .zoomingOut
            }
            // Keep the visible crop fixed at the optical frame center. Pan and
            // tilt—not a moving digital viewport—own target positioning.
            displayCrop = interpolatedCenteredCrop(
                from: displayCrop,
                desiredWidth: 1 / desiredZoom,
                smoothing: smoothing
            )
        }

        let zoom = min(configuration.maximumZoom, max(1, 1 / displayCrop.width))
        return TrackingFrameMetadata(
            timestamp: timestamp,
            analysisMode: plan.mode,
            analysisRegion: plan.region,
            displayCrop: displayCrop,
            zoomFactor: zoom,
            canonicalTargetBox: target.latestBoundingBox,
            targetConfidence: target.matchConfidence,
            targetVisibility: target.visibilityState
        )
    }

    private func updateZoomAdjustmentState(
        for displayedTargetFraction: CGFloat,
        tuning: ZoomTuningSnapshot
    ) {
        switch zoomAdjustmentState {
        case .needsInitialFraming:
            if displayedTargetFraction
                < tuning.hysteresisTargetFraction
                    - configuration.targetSettlingTolerance {
                zoomAdjustmentState = .zoomingIn
            } else if displayedTargetFraction
                        > tuning.hysteresisTargetFraction
                            + configuration.targetSettlingTolerance {
                zoomAdjustmentState = .zoomingOut
            } else {
                zoomAdjustmentState = .holding
            }

        case .holding:
            if displayedTargetFraction < tuning.zoomInTriggerFraction {
                zoomAdjustmentState = .zoomingIn
            } else if displayedTargetFraction > tuning.zoomOutTriggerFraction {
                zoomAdjustmentState = .zoomingOut
            }

        case .zoomingIn, .zoomingOut:
            let distanceFromTarget = abs(
                displayedTargetFraction - tuning.hysteresisTargetFraction
            )
            if distanceFromTarget <= configuration.targetSettlingTolerance {
                zoomAdjustmentState = .holding
            } else if displayedTargetFraction < tuning.hysteresisTargetFraction {
                // The person's motion can carry the box past the target while a
                // latched adjustment is active. Reverse direction instead of
                // cancelling the adjustment before the target size is reached.
                zoomAdjustmentState = .zoomingIn
            } else {
                zoomAdjustmentState = .zoomingOut
            }
        }
    }

    private func interpolatedCenteredCrop(
        from current: CGRect,
        desiredWidth: CGFloat,
        smoothing amount: CGFloat
    ) -> CGRect {
        let width = current.width + (desiredWidth - current.width) * amount
        return TrackingGeometry.centeredRectangle(
            center: CGPoint(x: 0.5, y: 0.5),
            size: CGSize(width: width, height: width)
        )
    }

    private func hasUrgentBoundaryPressure(
        target: TrackedTarget,
        crop: CGRect
    ) -> Bool {
        let horizontalError = (target.center.x - crop.midX) / max(crop.width, 0.001)
        let verticalError = (target.center.y - crop.midY) / max(crop.height, 0.001)
        let threshold = configuration.displayedEdgePressureThreshold
        let margin = configuration.cropBoundaryUrgentMargin
        return horizontalError < -threshold && crop.minX <= margin
            || horizontalError > threshold && 1 - crop.maxX <= margin
            || verticalError < -threshold && crop.minY <= margin
            || verticalError > threshold && 1 - crop.maxY <= margin
    }
}

/// Controls developer diagnostics shown on the live preview. Saved-video
/// overlays are selected independently on the Recording Output tuning page.
nonisolated enum TrackingDebugConfiguration {
    static let showsScreenOverlays = true
    static let showsMotorControlOverlay = true
}
