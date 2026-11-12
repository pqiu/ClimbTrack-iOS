@preconcurrency import CoreVideo
import CoreGraphics
import Foundation
import ImageIO

struct TargetTrackerOutput {
    let target: TrackedTarget?
    let presentation: TargetPresentation?
    let reacquisitionCandidateBox: CGRect?
}

/// Serial-queue-confined persistent identity tracker.
nonisolated final class TargetTracker: @unchecked Sendable {
    private struct State {
        var latestBoundingBox: CGRect
        var aimingCenter: CGPoint
        var previousBoundingBoxes: [CGRect]
        var velocity: CGVector
        var detectionConfidence: Float
        var lastSeenTimestamp: TimeInterval
        var visibilityState: TargetVisibilityState
        var matchConfidence: Float
        var gallery: [PersonAppearanceSample]
        let identityBackend: IdentityMatchingBackend
        let originalColorCharacteristics: [Float]
        var bestAppearanceSampleIndex: Int?
        var missingFrames = 0
        var matchedDetectionID: UUID?
        var galleryUpdateDiagnostic: GalleryUpdateDiagnostic?
        var scaleHistory: [PersonScaleMeasurement]
        var scaleDiagnosticText: String?
        var trackingStatusReason: String?
    }

    private struct Candidate {
        let detection: PersonDetection
        let appearanceSample: PersonAppearanceSample?
        let appearanceMatch: PersonAppearanceMatch?
        let appearanceFailureReason: String?
        let score: TargetAssociationScore
        let displayNormalizedCenterDisplacement: CGFloat
        let scaleRatio: CGFloat?
    }

    private struct ReacquisitionCandidate {
        var boundingBox: CGRect
        var appearanceSample: PersonAppearanceSample
        var confirmationCount: Int
        var consecutiveMisses: Int
    }

    private enum GalleryMutation {
        case added
        case replaced
        case rejectedAsRedundant
        case rejectedWithoutReplacementImprovement
    }

    private let configuration = TargetAssociationConfiguration()
    private let tuningBridge: TrackingTuningBridge
    private let appearanceExtractor = PersonAppearanceExtractor()
    private var state: State?
    private var isSessionActive = false
    private var lastAppearanceEvaluation: TimeInterval = 0
    private var pendingReacquisition: ReacquisitionCandidate?
    private var isCameraMoving = false

    var hasTarget: Bool { state != nil }

    init(tuningBridge: TrackingTuningBridge) {
        self.tuningBridge = tuningBridge
    }

    func initialize(
        with detection: PersonDetection,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval
    ) -> Bool {
        let tuning = tuningBridge.snapshot()
        let requestedBackend = tuning.identityBackend
        guard state == nil,
              let sample = appearanceExtractor.extract(
                from: pixelBuffer,
                orientation: orientation,
                personBox: detection.normalizedBoundingBox,
                backend: requestedBackend
              ) else { return false }

        state = State(
            latestBoundingBox: detection.normalizedBoundingBox,
            aimingCenter: tuning.detectionBackend == .appleVisionSkeleton
                ? detection.skeleton?.torsoCenter ?? CGPoint(
                    x: detection.normalizedBoundingBox.midX,
                    y: detection.normalizedBoundingBox.midY
                )
                : CGPoint(
                    x: detection.normalizedBoundingBox.midX,
                    y: detection.normalizedBoundingBox.midY
                ),
            previousBoundingBoxes: [],
            velocity: .zero,
            detectionConfidence: detection.confidence,
            lastSeenTimestamp: timestamp,
            visibilityState: .lockedVisible,
            matchConfidence: 1,
            gallery: [sample],
            identityBackend: sample.identityBackend,
            originalColorCharacteristics: sample.colorHistogram,
            bestAppearanceSampleIndex: 1,
            matchedDetectionID: detection.id,
            galleryUpdateDiagnostic: GalleryUpdateDiagnostic(
                totalScore: 1,
                identityScore: 1,
                margin: nil,
                cropArea: sample.normalizedCropArea,
                cropPassed: true,
                framePassed: isSafelyInsideFrame(detection.normalizedBoundingBox),
                novelty: nil,
                noveltyPassed: nil,
                result: "INITIAL IDENTITY SAMPLE"
            ),
            scaleHistory: detection.scaleMeasurement?.isReliableForHistory == true
                ? [detection.scaleMeasurement!]
                : [],
            scaleDiagnosticText: tuning.detectionBackend == .appleVisionSkeleton
                ? "Scale: baseline established"
                : nil,
            trackingStatusReason: nil
        )
        lastAppearanceEvaluation = timestamp
        pendingReacquisition = nil
        return true
    }

    func activateSession() {
        guard state != nil else { return }
        isSessionActive = true
    }

    func clear() {
        guard state != nil else { return }
        state = nil
        isSessionActive = false
        pendingReacquisition = nil
        lastAppearanceEvaluation = 0
        isCameraMoving = false
    }

    func setCameraMotionActive(_ isActive: Bool) {
        isCameraMoving = isActive
    }

    func process(
        detections: [PersonDetection],
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval,
        continuityRegion: CGRect
    ) -> TargetTrackerOutput {
        guard let currentState = state else {
            return TargetTrackerOutput(
                target: nil,
                presentation: nil,
                reacquisitionCandidateBox: nil
            )
        }

        guard !detections.isEmpty else {
            registerMiss(from: currentState, reason: "NO PERSON DETECTIONS")
            registerReacquisitionCandidateMiss()
            return output()
        }

        let predictedBox = predictedBoundingBox(for: currentState, at: timestamp)
        let tuning = tuningBridge.snapshot()
        let isReacquiring = currentState.visibilityState == .lockedMissing
            || pendingReacquisition != nil
        // Each recovery frame may inspect a different crop. Evaluate identity
        // every time so surrounding crops cannot be skipped by the normal throttle.
        let hasSuspiciousScaleCandidate = tuning.detectionBackend == .appleVisionSkeleton
            && detections.contains {
                guard let ratio = scaleRatio(for: $0.scaleMeasurement, state: currentState) else {
                    return false
                }
                return ratio >= tuning.suspiciousScaleRatio
            }
        // A detector miss can be followed by a substantially different Vision
        // box as a climber changes posture. Force identity on that first return
        // instead of relying on geometry alone, while retaining normal tracking
        // thresholds and continuity gates until full reacquisition begins.
        let shouldEvaluateAppearance = currentState.missingFrames > 0
            || isReacquiring
            || hasSuspiciousScaleCandidate
            || timestamp - lastAppearanceEvaluation >= configuration.appearanceInterval

        let geometryRanked = detections.sorted {
            TargetAssociation.score(
                candidate: $0.normalizedBoundingBox,
                predictedTarget: predictedBox,
                lastObservedTarget: currentState.latestBoundingBox,
                featureSimilarity: nil,
                colorSimilarity: nil,
                configuration: configuration
            ).total > TargetAssociation.score(
                candidate: $1.normalizedBoundingBox,
                predictedTarget: predictedBox,
                lastObservedTarget: currentState.latestBoundingBox,
                featureSimilarity: nil,
                colorSimilarity: nil,
                configuration: configuration
            ).total
        }
        let appearanceCandidateIDs = Set(
            geometryRanked.prefix(configuration.maximumAppearanceCandidates).map(\.id)
        )

        var samples: [UUID: PersonAppearanceSample] = [:]
        var appearanceFailures: [UUID: String] = [:]
        if shouldEvaluateAppearance {
            lastAppearanceEvaluation = timestamp
            let originalImageSize = orientedImageSize(
                for: pixelBuffer,
                orientation: orientation
            )
            for detection in detections where appearanceCandidateIDs.contains(detection.id) {
                if let reason = appearanceExtractor.identityQualityFailureReason(
                    personBox: detection.normalizedBoundingBox,
                    orientedImageSize: originalImageSize
                ) {
                    appearanceFailures[detection.id] = reason
                    continue
                }
                let outcome = appearanceExtractor.extractWithDiagnostic(
                    from: pixelBuffer,
                    orientation: orientation,
                    personBox: detection.normalizedBoundingBox,
                    backend: currentState.identityBackend
                )
                if let sample = outcome.sample {
                    samples[detection.id] = sample
                } else {
                    appearanceFailures[detection.id] = outcome.failureReason
                        ?? "IDENTITY EXTRACTION RETURNED NO RESULT"
                }
            }
            if samples.isEmpty {
                setGalleryDiagnostic(
                    GalleryUpdateDiagnostic(
                        totalScore: nil,
                        identityScore: nil,
                        margin: nil,
                        cropArea: nil,
                        cropPassed: nil,
                        framePassed: nil,
                        novelty: nil,
                        noveltyPassed: nil,
                        result: "REJECTED: APPEARANCE EXTRACTION FAILED"
                    )
                )
            }
        }

        let extractedAppearance = !samples.isEmpty
        let candidates = detections.compactMap { detection -> Candidate? in
            let sample = samples[detection.id]
            if shouldEvaluateAppearance, extractedAppearance, sample == nil {
                // Do not let an uncharacterized bystander beat candidates that
                // were explicitly appearance-checked on this cycle.
                return nil
            }
            let appearanceMatch = sample.flatMap {
                appearanceExtractor.bestMatch(for: $0, in: currentState.gallery)
            }
            let appearanceFailureReason = appearanceFailures[detection.id]
                ?? (sample != nil && appearanceMatch == nil
                    ? "IDENTITY COMPARISON AGAINST GALLERY FAILED"
                    : nil)
            return Candidate(
                detection: detection,
                appearanceSample: sample,
                appearanceMatch: appearanceMatch,
                appearanceFailureReason: appearanceFailureReason,
                score: TargetAssociation.score(
                    candidate: detection.normalizedBoundingBox,
                    predictedTarget: predictedBox,
                    lastObservedTarget: currentState.latestBoundingBox,
                    featureSimilarity: appearanceMatch?.featureSimilarity,
                    colorSimilarity: appearanceMatch?.colorSimilarity,
                    configuration: configuration
                ),
                displayNormalizedCenterDisplacement: normalizedCenterDisplacement(
                    from: currentState.latestBoundingBox,
                    to: detection.normalizedBoundingBox,
                    in: continuityRegion
                ),
                scaleRatio: tuning.detectionBackend == .appleVisionSkeleton
                    ? scaleRatio(for: detection.scaleMeasurement, state: currentState)
                    : nil
            )
        }.sorted { $0.score.total > $1.score.total }

        updateScaleDiagnostic(candidates: candidates, tuning: tuning)

        if isReacquiring {
            processReacquisition(
                candidates: candidates,
                identityFailureReasons: geometryRanked.compactMap {
                    appearanceFailures[$0.id]
                },
                timestamp: timestamp,
                tuning: tuning,
                continuityRegion: continuityRegion
            )
        } else {
            processNormalAssociation(
                candidates: candidates,
                identityFailureReasons: geometryRanked.compactMap {
                    appearanceFailures[$0.id]
                },
                timestamp: timestamp,
                tuning: tuning,
                continuityRegion: continuityRegion
            )
        }

        return output()
    }

    func output() -> TargetTrackerOutput {
        guard let state else {
            return TargetTrackerOutput(
                target: nil,
                presentation: nil,
                reacquisitionCandidateBox: nil
            )
        }

        let target = TrackedTarget(
            latestBoundingBox: state.latestBoundingBox,
            previousBoundingBoxes: state.previousBoundingBoxes,
            center: CGPoint(x: state.latestBoundingBox.midX, y: state.latestBoundingBox.midY),
            aimingCenter: state.aimingCenter,
            estimatedVelocity: state.velocity,
            boundingBoxSize: state.latestBoundingBox.size,
            detectionConfidence: state.detectionConfidence,
            lastSeenTimestamp: state.lastSeenTimestamp,
            visibilityState: state.visibilityState,
            matchConfidence: state.matchConfidence,
            appearanceGalleryCount: state.gallery.count,
            bestAppearanceSampleIndex: state.bestAppearanceSampleIndex,
            originalColorCharacteristics: state.originalColorCharacteristics,
            consecutiveMisses: state.missingFrames
        )
        guard isSessionActive else {
            return TargetTrackerOutput(
                target: target,
                presentation: nil,
                reacquisitionCandidateBox: nil
            )
        }

        let uncertainBox = state.visibilityState == .lockedAmbiguous
            ? pendingReacquisition?.boundingBox ?? state.latestBoundingBox
            : nil
        return TargetTrackerOutput(
            target: target,
            presentation: TargetPresentation(
                state: state.visibilityState,
                matchedDetectionID: state.visibilityState == .lockedVisible
                    ? state.matchedDetectionID
                    : nil,
                uncertainBoundingBox: uncertainBox,
                appearanceGalleryCount: state.gallery.count,
                appearanceGalleryCapacity: configuration.maximumGalleryCount,
                bestAppearanceSampleIndex: state.bestAppearanceSampleIndex,
                galleryUpdateDiagnostic: state.galleryUpdateDiagnostic,
                scaleDiagnosticText: state.scaleDiagnosticText,
                trackingStatusReason: state.trackingStatusReason,
                consecutiveMisses: state.missingFrames
            ),
            reacquisitionCandidateBox: pendingReacquisition?.boundingBox
        )
    }

    private func processNormalAssociation(
        candidates: [Candidate],
        identityFailureReasons: [String],
        timestamp: TimeInterval,
        tuning: TrackingTuningSnapshot,
        continuityRegion: CGRect
    ) {
        let plausibleCandidates = candidates.filter {
            $0.displayNormalizedCenterDisplacement
                <= tuning.maximumCenterDisplacement
                && ($0.scaleRatio ?? 1) < tuning.rejectionScaleRatio
                && (($0.scaleRatio ?? 1) < tuning.suspiciousScaleRatio
                    || $0.score.appearance != nil)
        }
        guard let best = plausibleCandidates.first else {
            let reason = trackingCandidateRejectionReason(
                candidates: candidates,
                identityFailureReasons: identityFailureReasons,
                tuning: tuning
            )
            registerMiss(from: state, reason: reason)
            return
        }
        let runnerUpScore = plausibleCandidates.dropFirst().first?.score.total ?? 0
        let hasAppearance = best.score.appearance != nil
        let threshold = hasAppearance
            ? tuning.trackingAppearanceTotalThreshold
            : tuning.trackingGeometryOnlyTotalThreshold
        let requiredMargin = hasAppearance
            ? configuration.appearanceMinimumMargin
            : configuration.geometryOnlyMinimumMargin

        guard best.score.total >= threshold,
              !hasAppearance
                || best.score.appearance! >= tuning.trackingIdentityThreshold,
              best.score.total - runnerUpScore >= requiredMargin else {
            let reason: String
            if best.score.total < threshold {
                reason = "TRACK TOTAL \(format(best.score.total)) < \(format(threshold))"
            } else if hasAppearance,
                      let appearance = best.score.appearance,
                      appearance < tuning.trackingIdentityThreshold {
                reason = "TRACK ID \(format(appearance)) < "
                    + format(tuning.trackingIdentityThreshold)
            } else {
                reason = "TRACK MARGIN \(format(best.score.total - runnerUpScore)) < "
                    + format(requiredMargin)
            }
            registerMiss(from: state, reason: reason)
            return
        }

        accept(
            best,
            timestamp: timestamp,
            wasReacquired: false,
            tuning: tuning,
            continuityRegion: continuityRegion
        )
    }

    private func processReacquisition(
        candidates: [Candidate],
        identityFailureReasons: [String],
        timestamp: TimeInterval,
        tuning: TrackingTuningSnapshot,
        continuityRegion: CGRect
    ) {
        let appearanceCandidates = candidates
            .filter {
                $0.score.appearance != nil
                    && ($0.scaleRatio ?? 1) < tuning.rejectionScaleRatio
            }
            .sorted { ($0.score.appearance ?? 0) > ($1.score.appearance ?? 0) }
        guard let best = appearanceCandidates.first,
              let appearance = best.score.appearance else {
            registerMiss(
                from: state,
                reason: reacquisitionCandidateRejectionReason(
                    candidates: candidates,
                    identityFailureReasons: identityFailureReasons,
                    tuning: tuning
                )
            )
            registerReacquisitionCandidateMiss()
            return
        }
        setBestAppearanceSampleIndex(best.appearanceMatch?.sampleIndex)

        guard appearance >= tuning.reacquisitionIdentityThreshold else {
            registerMiss(
                from: state,
                reason: "REACQUIRE ID \(format(appearance)) < "
                    + format(tuning.reacquisitionIdentityThreshold)
            )
            pendingReacquisition = nil
            return
        }

        let runnerUpScore = appearanceCandidates.dropFirst().first?.score.appearance ?? 0
        guard appearance - runnerUpScore
                >= tuning.reacquisitionIdentityMargin else {
            transition(
                to: .lockedAmbiguous,
                matchedDetectionID: nil,
                matchConfidence: Float(appearance),
                reason: "REACQUIRE MARGIN \(format(appearance - runnerUpScore)) < "
                    + format(tuning.reacquisitionIdentityMargin)
            )
            return
        }

        guard let bestAppearanceSample = best.appearanceSample else { return }
        if var pending = pendingReacquisition {
            let confirmationMatch = appearanceExtractor.bestMatch(
                for: bestAppearanceSample,
                in: [pending.appearanceSample]
            )
            let isConsistent = CGFloat(confirmationMatch?.combinedSimilarity ?? 0)
                >= tuning.reacquisitionIdentityThreshold

            if isConsistent {
                pending.boundingBox = best.detection.normalizedBoundingBox
                pending.appearanceSample = bestAppearanceSample
                pending.confirmationCount += 1
                pending.consecutiveMisses = 0
                pendingReacquisition = pending
            } else {
                pendingReacquisition = ReacquisitionCandidate(
                    boundingBox: best.detection.normalizedBoundingBox,
                    appearanceSample: bestAppearanceSample,
                    confirmationCount: 1,
                    consecutiveMisses: 0
                )
            }
        } else {
            pendingReacquisition = ReacquisitionCandidate(
                boundingBox: best.detection.normalizedBoundingBox,
                appearanceSample: bestAppearanceSample,
                confirmationCount: 1,
                consecutiveMisses: 0
            )
        }

        guard let pendingReacquisition,
              pendingReacquisition.confirmationCount
                >= tuning.reacquisitionConfirmationFrames else {
            transition(
                to: .lockedAmbiguous,
                matchedDetectionID: nil,
                matchConfidence: Float(appearance),
                reason: "REACQUIRE CONFIRMATION \(pendingReacquisition?.confirmationCount ?? 0)/"
                    + "\(tuning.reacquisitionConfirmationFrames)"
            )
            return
        }

        self.pendingReacquisition = nil
        accept(
            best,
            timestamp: timestamp,
            wasReacquired: true,
            tuning: tuning,
            continuityRegion: continuityRegion
        )
    }

    private func accept(
        _ candidate: Candidate,
        timestamp: TimeInterval,
        wasReacquired: Bool,
        tuning: TrackingTuningSnapshot,
        continuityRegion: CGRect
    ) {
        guard var state else { return }
        let elapsed = max(timestamp - state.lastSeenTimestamp, 0.001)
        let oldCenter = CGPoint(
            x: state.latestBoundingBox.midX,
            y: state.latestBoundingBox.midY
        )
        let newBox = candidate.detection.normalizedBoundingBox
        let measuredVelocity = CGVector(
            dx: (newBox.midX - oldCenter.x) / elapsed,
            dy: (newBox.midY - oldCenter.y) / elapsed
        )

        state.previousBoundingBoxes.append(state.latestBoundingBox)
        if state.previousBoundingBoxes.count > 6 {
            state.previousBoundingBoxes.removeFirst()
        }
        state.latestBoundingBox = newBox
        let boxCenter = CGPoint(x: newBox.midX, y: newBox.midY)
        if tuning.detectionBackend == .appleVisionSkeleton {
            let desired = candidate.detection.skeleton?.torsoCenter ?? boxCenter
            state.aimingCenter = smoothedAimPoint(
                from: state.aimingCenter,
                toward: desired,
                tuning: tuning,
                continuityRegion: continuityRegion
            )
        } else {
            state.aimingCenter = boxCenter
        }
        // Platform motion shifts the entire image and must not be learned as
        // target body velocity for the next ROI prediction.
        state.velocity = wasReacquired || isCameraMoving
            ? .zero
            : CGVector(
                dx: state.velocity.dx * 0.60 + measuredVelocity.dx * 0.40,
                dy: state.velocity.dy * 0.60 + measuredVelocity.dy * 0.40
            )
        state.detectionConfidence = candidate.detection.confidence
        state.lastSeenTimestamp = timestamp
        state.visibilityState = .lockedVisible
        state.matchConfidence = Float(
            wasReacquired ? candidate.score.appearance ?? 0 : candidate.score.total
        )
        state.missingFrames = 0
        state.trackingStatusReason = nil
        state.matchedDetectionID = candidate.detection.id
        if let sampleIndex = candidate.appearanceMatch?.sampleIndex {
            state.bestAppearanceSampleIndex = sampleIndex + 1
        }
        if tuning.detectionBackend == .appleVisionSkeleton,
           !isCameraMoving,
           candidate.appearanceMatch != nil,
           let measurement = candidate.detection.scaleMeasurement,
           measurement.isReliableForHistory {
            state.scaleHistory.append(measurement)
            if state.scaleHistory.count > 30 {
                state.scaleHistory.removeFirst(state.scaleHistory.count - 30)
            }
        }

        if isCameraMoving {
            state.galleryUpdateDiagnostic = GalleryUpdateDiagnostic(
                totalScore: candidate.score.total,
                identityScore: candidate.score.appearance,
                margin: state.galleryUpdateDiagnostic?.margin,
                cropArea: candidate.appearanceSample?.normalizedCropArea,
                cropPassed: nil,
                framePassed: nil,
                novelty: nil,
                noveltyPassed: nil,
                result: "PAUSED: CAMERA MOVING"
            )
        } else if let sample = candidate.appearanceSample,
           let identityScore = candidate.score.appearance {
            let totalPassed = candidate.score.total >= configuration.galleryUpdateMatchThreshold
            let identityPassed = identityScore >= configuration.galleryUpdateIdentityThreshold
            let cropPassed = sample.normalizedCropArea >= 0.008
            let framePassed = isSafelyInsideFrame(newBox)
            let novelty = nearestDiversity(of: sample, in: state.gallery)
            let noveltyPassed = novelty >= configuration.galleryNoveltyThreshold
            let result: String

            if !totalPassed {
                result = "REJECTED: GALLERY TOTAL BELOW \(format(configuration.galleryUpdateMatchThreshold))"
            } else if !identityPassed {
                result = "REJECTED: GALLERY ID BELOW \(format(configuration.galleryUpdateIdentityThreshold))"
            } else if !cropPassed {
                result = "REJECTED: CROP BELOW 0.008"
            } else {
                switch addRepresentativeSample(
                    sample,
                    nearestDiversity: novelty,
                    to: &state.gallery
                ) {
                case .added:
                    result = "ADDED NEW GALLERY SAMPLE"
                case .replaced:
                    result = "REPLACED REDUNDANT GALLERY SAMPLE"
                case .rejectedAsRedundant:
                    result = "REJECTED: NOVELTY BELOW \(format(configuration.galleryNoveltyThreshold))"
                case .rejectedWithoutReplacementImprovement:
                    result = "REJECTED: FULL GALLERY; NO DIVERSITY IMPROVEMENT"
                }
            }

            state.galleryUpdateDiagnostic = GalleryUpdateDiagnostic(
                totalScore: candidate.score.total,
                identityScore: identityScore,
                margin: state.galleryUpdateDiagnostic?.margin,
                cropArea: sample.normalizedCropArea,
                cropPassed: cropPassed,
                framePassed: framePassed,
                novelty: novelty,
                noveltyPassed: noveltyPassed,
                result: result
            )
        }

        self.state = state
    }

    private func registerMiss(from suppliedState: State?, reason: String) {
        guard var state = suppliedState else { return }
        state.missingFrames += 1
        state.matchedDetectionID = nil
        state.matchConfidence = 0
        state.bestAppearanceSampleIndex = nil
        let nextVisibility: TargetVisibilityState = state.missingFrames
            >= configuration.missingAfterFrames ? .lockedMissing : .lockedAmbiguous
        state.visibilityState = nextVisibility
        state.trackingStatusReason = reason
        self.state = state
    }

    private func registerReacquisitionCandidateMiss() {
        guard var pending = pendingReacquisition else { return }
        pending.consecutiveMisses += 1
        if pending.consecutiveMisses > configuration.maximumReacquisitionCandidateMisses {
            // A transient candidate must not trap the surrounding-crop search.
            pendingReacquisition = nil
        } else {
            pendingReacquisition = pending
        }
    }

    private func transition(
        to visibility: TargetVisibilityState,
        matchedDetectionID: UUID?,
        matchConfidence: Float,
        reason: String
    ) {
        guard var state else { return }
        state.visibilityState = visibility
        state.matchedDetectionID = matchedDetectionID
        state.matchConfidence = matchConfidence
        state.trackingStatusReason = reason
        self.state = state

    }

    private func trackingCandidateRejectionReason(
        candidates: [Candidate],
        identityFailureReasons: [String],
        tuning: TrackingTuningSnapshot
    ) -> String {
        guard let best = candidates.first else {
            return identityFailureReasons.first
                ?? "INTERNAL: 0 ASSOCIATION CANDIDATES AND 0 EXTRACTION FAILURES"
        }
        if best.displayNormalizedCenterDisplacement > tuning.maximumCenterDisplacement {
            return "CENTER JUMP \(format(best.displayNormalizedCenterDisplacement)) > "
                + format(tuning.maximumCenterDisplacement)
        }
        if let scaleRatio = best.scaleRatio,
           scaleRatio >= tuning.rejectionScaleRatio {
            return "SCALE RATIO \(format(scaleRatio)) >= "
                + format(tuning.rejectionScaleRatio)
        }
        if let scaleRatio = best.scaleRatio,
           scaleRatio >= tuning.suspiciousScaleRatio,
           best.score.appearance == nil {
            return best.appearanceFailureReason.map {
                "SCALE \(format(scaleRatio)) NEEDS ID; \($0)"
            } ?? "SCALE \(format(scaleRatio)) NEEDS IDENTITY SAMPLE"
        }
        return best.appearanceFailureReason
            ?? "INTERNAL: TOP CANDIDATE FAILED WITHOUT A RECORDED GATE"
    }

    private func reacquisitionCandidateRejectionReason(
        candidates: [Candidate],
        identityFailureReasons: [String],
        tuning: TrackingTuningSnapshot
    ) -> String {
        if let candidate = candidates.first(where: {
            guard let ratio = $0.scaleRatio else { return false }
            return $0.score.appearance != nil && ratio >= tuning.rejectionScaleRatio
        }), let ratio = candidate.scaleRatio {
            return "REACQUIRE SCALE \(format(ratio)) >= "
                + format(tuning.rejectionScaleRatio)
        }
        if let reason = candidates.compactMap(\.appearanceFailureReason).first {
            return "REACQUIRE: \(reason)"
        }
        if let reason = identityFailureReasons.first {
            return "REACQUIRE: \(reason)"
        }
        return "REACQUIRE: MATCH RETURNED NIL WITHOUT AN EXTRACTION ERROR"
    }

    private func setBestAppearanceSampleIndex(_ zeroBasedIndex: Int?) {
        guard var state else { return }
        state.bestAppearanceSampleIndex = zeroBasedIndex.map { $0 + 1 }
        self.state = state
    }

    private func addRepresentativeSample(
        _ sample: PersonAppearanceSample,
        nearestDiversity: Float,
        to gallery: inout [PersonAppearanceSample]
    ) -> GalleryMutation {
        guard nearestDiversity >= configuration.galleryNoveltyThreshold else {
            return .rejectedAsRedundant
        }

        if gallery.count < configuration.maximumGalleryCount {
            gallery.append(sample)
            return .added
        }

        // Find the most redundant non-original sample. Index zero is the
        // permanent selection-time identity anchor and is never replaced.
        var replacementIndex: Int?
        var replacementDiversity = Float.greatestFiniteMagnitude
        for index in gallery.indices where index > 0 {
            let nearestNeighbor = gallery.indices
                .filter { $0 != index }
                .map { appearanceExtractor.diversity(
                    between: gallery[index],
                    and: gallery[$0]
                ) }
                .min() ?? 1
            if nearestNeighbor < replacementDiversity {
                replacementDiversity = nearestNeighbor
                replacementIndex = index
            }
        }

        if let replacementIndex,
           nearestDiversity >= replacementDiversity
                + configuration.galleryReplacementImprovement {
            gallery[replacementIndex] = sample
            return .replaced
        }
        return .rejectedWithoutReplacementImprovement
    }

    private func nearestDiversity(
        of sample: PersonAppearanceSample,
        in gallery: [PersonAppearanceSample]
    ) -> Float {
        gallery.map {
            appearanceExtractor.diversity(between: sample, and: $0)
        }.min() ?? 1
    }

    private func setGalleryDiagnostic(_ diagnostic: GalleryUpdateDiagnostic) {
        guard var state else { return }
        state.galleryUpdateDiagnostic = diagnostic
        self.state = state
    }

    private func updateScaleDiagnostic(
        candidates: [Candidate],
        tuning: TrackingTuningSnapshot
    ) {
        guard var state else { return }
        guard tuning.detectionBackend == .appleVisionSkeleton else {
            state.scaleDiagnosticText = nil
            self.state = state
            return
        }
        let highest = candidates.compactMap(\.scaleRatio).max()
        let status: String
        if let highest {
            if highest >= tuning.rejectionScaleRatio {
                status = "REJECT"
            } else if highest >= tuning.suspiciousScaleRatio {
                status = "VERIFY ID"
            } else {
                status = "PLAUSIBLE"
            }
            state.scaleDiagnosticText = String(
                format: "Scale: %.2f× %@ · history %d",
                highest,
                status,
                state.scaleHistory.count
            )
        } else {
            state.scaleDiagnosticText = "Scale: unavailable · history \(state.scaleHistory.count)"
        }
        self.state = state
    }

    private func format<T: BinaryFloatingPoint>(_ value: T) -> String {
        String(format: "%.2f", Double(value))
    }

    private func normalizedCenterDisplacement(
        from reference: CGRect,
        to candidate: CGRect,
        in displayCrop: CGRect
    ) -> CGFloat {
        let horizontal = (candidate.midX - reference.midX)
            / max(displayCrop.width, 0.001)
        let vertical = (candidate.midY - reference.midY)
            / max(displayCrop.height, 0.001)
        return hypot(horizontal, vertical)
    }

    private func scaleRatio(
        for measurement: PersonScaleMeasurement?,
        state: State
    ) -> CGFloat? {
        guard let measurement else { return nil }
        let sameKind = state.scaleHistory.filter { $0.kind == measurement.kind }
        let references = sameKind.isEmpty
            ? state.scaleHistory.filter(\.isReliableForHistory)
            : sameKind
        guard !references.isEmpty else { return nil }
        let sorted = references.map(\.value).sorted()
        let expected = sorted[sorted.count / 2]
        guard expected > 0 else { return nil }
        // Only a dramatically larger person is depth-like evidence of a nearby
        // passerby. A smaller candidate is not rejected by this one-way gate.
        return measurement.value / expected
    }

    private func smoothedAimPoint(
        from current: CGPoint,
        toward desired: CGPoint,
        tuning: TrackingTuningSnapshot,
        continuityRegion: CGRect
    ) -> CGPoint {
        var dx = (desired.x - current.x) * tuning.torsoAnchorSmoothing
        var dy = (desired.y - current.y) * tuning.torsoAnchorSmoothing
        let maximumX = max(0.001, continuityRegion.width * tuning.maximumTorsoAnchorStep)
        let maximumY = max(0.001, continuityRegion.height * tuning.maximumTorsoAnchorStep)
        dx = min(max(dx, -maximumX), maximumX)
        dy = min(max(dy, -maximumY), maximumY)
        return CGPoint(x: current.x + dx, y: current.y + dy)
    }

    private func predictedBoundingBox(for state: State, at timestamp: TimeInterval) -> CGRect {
        let elapsed = min(max(timestamp - state.lastSeenTimestamp, 0), 0.75)
        return state.latestBoundingBox.offsetBy(
            dx: state.velocity.dx * elapsed,
            dy: state.velocity.dy * elapsed
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }

    private func isSafelyInsideFrame(_ box: CGRect) -> Bool {
        box.minX > 0.02 && box.minY > 0.02 && box.maxX < 0.98 && box.maxY < 0.98
    }

    private func orientedImageSize(
        for pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation
    ) -> CGSize {
        let width = CGFloat(CVPixelBufferGetWidth(pixelBuffer))
        let height = CGFloat(CVPixelBufferGetHeight(pixelBuffer))
        switch orientation {
        case .left, .leftMirrored, .right, .rightMirrored:
            return CGSize(width: height, height: width)
        default:
            return CGSize(width: width, height: height)
        }
    }
}
