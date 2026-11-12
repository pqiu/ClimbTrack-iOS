@preconcurrency import CoreImage
import CoreGraphics
@preconcurrency import CoreVideo
import Foundation
import ImageIO
import Vision

nonisolated struct GestureRecognitionConfiguration {
    // Gesture analysis runs below the person detector's nominal 8 fps.
    let analysisInterval: TimeInterval = 0.25
    // Both gestures must persist; a single Vision result can never issue a command.
    let trackMeHoldDuration: TimeInterval = 0.5
    let stopHoldDuration: TimeInterval = 0.9
    // Brief pose misses do not discard otherwise stable hold progress.
    let allowableInterruption: TimeInterval = 0.30
    // Prevents the end of one gesture from immediately becoming a new candidate.
    let cooldownDuration: TimeInterval = 1.5

    // Vision landmark floors reject low-quality joint geometry.
    let minimumBodyJointConfidence: Float = 0.30
    let minimumHandJointConfidence: Float = 0.25
    // Explicit semantic confidence thresholds are intended for device tuning.
    let minimumTrackMeBodyConfidence: Float = 0.58
    let minimumTrackMeConfidence: Float = 0.72
    let minimumStopConfidence: Float = 0.70
    // Match the current identity-association threshold used by tracking.
    let minimumLockedTargetMatchConfidence: Float = 0.50
    // Small/distant subjects are not sent through unreliable hand-pose confirmation.
    let minimumHandCropPixels: CGFloat = 48
    let minimumPersonBoxHeight: CGFloat = 0.20
    let minimumPersonBoxWidth: CGFloat = 0.08
}

/// Recognizes commands only. Recording and target lifecycle remain in CameraView.
nonisolated final class PersonGestureRecognizer: @unchecked Sendable {
    private struct HoldCandidate {
        var detectionID: UUID
        var boundingBox: CGRect
        var accumulatedDuration: TimeInterval
        var lastEvaluationTime: TimeInterval
        var lastValidTime: TimeInterval
        var confidence: Float
    }

    private enum State {
        case idle
        case startCandidate(HoldCandidate)
        case startConfirmed
        case stopCandidate(HoldCandidate)
        case stopConfirmed
        case cooldown(until: TimeInterval)
    }

    private struct PoseCandidate {
        let detection: PersonDetection
        let landmarks: BodyLandmarks
        let associationScore: CGFloat
    }

    private let configuration = GestureRecognitionConfiguration()
    private let imageContext = CIContext(options: [.cacheIntermediates: false])
    private var state: State = .idle
    private var lastAnalysisTime: TimeInterval = 0
    private var lastMode: GestureEvaluationMode?

    private(set) var currentStatus: GestureStatus?
    private(set) var currentDiagnosticText: String?

    func shouldAnalyze(mode: GestureEvaluationMode, timestamp: TimeInterval) -> Bool {
        handleModeChange(mode, timestamp: timestamp)
        guard mode != .lockedUnavailable,
              timestamp - lastAnalysisTime >= configuration.analysisInterval else {
            return false
        }
        if case .cooldown(let expiration) = state, timestamp < expiration {
            return false
        }
        lastAnalysisTime = timestamp
        return true
    }

    func process(
        bodyObservations: [VNHumanBodyPoseObservation],
        detections: [PersonDetection],
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        mode: GestureEvaluationMode,
        timestamp: TimeInterval,
        bodyObservationRegion: CGRect
    ) -> GestureAnalysisResult {
        switch mode {
        case .unlocked:
            return processTrackMe(
                bodyObservations: bodyObservations,
                detections: detections,
                pixelBuffer: pixelBuffer,
                orientation: orientation,
                timestamp: timestamp,
                bodyObservationRegion: bodyObservationRegion
            )

        case .lockedVisible(let detectionID, let matchConfidence):
            guard matchConfidence >= configuration.minimumLockedTargetMatchConfidence else {
                currentDiagnosticText = String(
                    format: "STOP · TARGET MATCH %.2f < %.2f",
                    matchConfidence,
                    configuration.minimumLockedTargetMatchConfidence
                )
                resetStopCandidate(reason: "target association confidence is insufficient")
                return GestureAnalysisResult(status: nil, command: nil)
            }
            return processStop(
                bodyObservations: bodyObservations,
                detections: detections,
                targetDetectionID: detectionID,
                timestamp: timestamp,
                bodyObservationRegion: bodyObservationRegion
            )

        case .lockedUnavailable:
            currentDiagnosticText = "STOP · TARGET AMBIGUOUS OR MISSING"
            resetCandidate(reason: "target is ambiguous or missing")
            return GestureAnalysisResult(status: nil, command: nil)
        }
    }

    func reset(timestamp: TimeInterval, usesCooldown: Bool) {
        state = usesCooldown
            ? .cooldown(until: timestamp + configuration.cooldownDuration)
            : .idle
        currentStatus = nil
        currentDiagnosticText = nil
        lastMode = nil
    }

    private func processTrackMe(
        bodyObservations: [VNHumanBodyPoseObservation],
        detections: [PersonDetection],
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval,
        bodyObservationRegion: CGRect
    ) -> GestureAnalysisResult {
        guard case .startConfirmed = state else {
            guard !bodyObservations.isEmpty else {
                currentDiagnosticText = "TRACK ME · NO BODY POSE"
                return handleStartMiss(timestamp: timestamp)
            }
            guard !detections.isEmpty else {
                currentDiagnosticText = "TRACK ME · NO PERSON BOX"
                return handleStartMiss(timestamp: timestamp)
            }

            let poseCandidates = associatedPoseCandidates(
                observations: bodyObservations,
                detections: detections,
                observationRegion: bodyObservationRegion
            )
            guard !poseCandidates.isEmpty else {
                currentDiagnosticText = "TRACK ME · BODY POSE NOT ASSOCIATED WITH PERSON BOX"
                return handleStartMiss(timestamp: timestamp)
            }

            let largeEnoughCandidates = poseCandidates.filter { candidate in
                guard let localBox = TrackingGeometry.localRectangle(
                    fromCanonical: candidate.detection.normalizedBoundingBox,
                    in: bodyObservationRegion
                ) else { return false }
                return localBox.height >= configuration.minimumPersonBoxHeight
                    && localBox.width >= configuration.minimumPersonBoxWidth
            }
            guard !largeEnoughCandidates.isEmpty else {
                currentDiagnosticText = "TRACK ME · PERSON TOO SMALL"
                return handleStartMiss(timestamp: timestamp)
            }

            let bodyEvaluations = largeEnoughCandidates.map { candidate in
                (
                    candidate,
                    candidate.landmarks.trackMeBodyEvaluation(
                        personBox: candidate.detection.normalizedBoundingBox,
                        minimumJointConfidence: configuration.minimumBodyJointConfidence
                    )
                )
            }
            let scoredBodies = bodyEvaluations.compactMap { candidate, evaluation
                -> (PoseCandidate, Float)? in
                guard let confidence = evaluation.confidence else { return nil }
                return (candidate, confidence)
            }
            guard let strongestBody = scoredBodies.max(by: { first, second in
                first.1 + Float(first.0.associationScore) * 0.15
                    < second.1 + Float(second.0.associationScore) * 0.15
            }) else {
                currentDiagnosticText = "TRACK ME · "
                    + (bodyEvaluations.first?.1.rejectionReason ?? "BODY GEOMETRY REJECTED")
                return handleStartMiss(timestamp: timestamp)
            }
            guard strongestBody.1 >= configuration.minimumTrackMeBodyConfidence else {
                currentDiagnosticText = String(
                    format: "TRACK ME · BODY SCORE %.2f < %.2f",
                    strongestBody.1,
                    configuration.minimumTrackMeBodyConfidence
                )
                return handleStartMiss(timestamp: timestamp)
            }

            let candidate = strongestBody.0
            let bodyConfidence = strongestBody.1
            let orientedImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let torsoCenter = candidate.landmarks.upperTorsoCenter
            let leftHand = analyzeTrackMeHand(
                near: candidate.landmarks.leftWrist.location,
                torsoCenter: torsoCenter,
                personBox: candidate.detection.normalizedBoundingBox,
                orientedImage: orientedImage
            )
            let rightHand = analyzeTrackMeHand(
                near: candidate.landmarks.rightWrist.location,
                torsoCenter: torsoCenter,
                personBox: candidate.detection.normalizedBoundingBox,
                orientedImage: orientedImage
            )

            guard let leftHand, let rightHand else {
                let missingHands = [
                    leftHand == nil ? "LEFT HAND" : nil,
                    rightHand == nil ? "RIGHT HAND" : nil
                ].compactMap { $0 }.joined(separator: " + ")
                currentDiagnosticText = "TRACK ME · BODY PASSED · "
                    + missingHands + " NOT RECOGNIZED"
                return handleIncompleteStart(
                    detection: candidate.detection,
                    bodyConfidence: bodyConfidence,
                    leftHandConfidence: leftHand,
                    rightHandConfidence: rightHand,
                    timestamp: timestamp
                )
            }

            let overall = bodyConfidence * 0.40 + leftHand * 0.30 + rightHand * 0.30
            guard overall >= configuration.minimumTrackMeConfidence else {
                currentDiagnosticText = String(
                    format: "TRACK ME · TOTAL %.2f < %.2f · B %.2f L %.2f R %.2f",
                    overall,
                    configuration.minimumTrackMeConfidence,
                    bodyConfidence,
                    leftHand,
                    rightHand
                )
                return handleStartMiss(timestamp: timestamp)
            }

            currentDiagnosticText = nil
            return handleValidStart(
                detection: candidate.detection,
                confidence: overall,
                bodyConfidence: bodyConfidence,
                leftHandConfidence: leftHand,
                rightHandConfidence: rightHand,
                timestamp: timestamp
            )
        }

        return GestureAnalysisResult(status: currentStatus, command: nil)
    }

    private func processStop(
        bodyObservations: [VNHumanBodyPoseObservation],
        detections: [PersonDetection],
        targetDetectionID: UUID,
        timestamp: TimeInterval,
        bodyObservationRegion: CGRect
    ) -> GestureAnalysisResult {
        guard case .stopConfirmed = state else {
            guard !bodyObservations.isEmpty else {
                currentDiagnosticText = "STOP · NO BODY POSE"
                return handleStopMiss(timestamp: timestamp)
            }
            guard let targetDetection = detections.first(where: { $0.id == targetDetectionID }) else {
                currentDiagnosticText = "STOP · MATCHED TARGET BOX NOT FOUND"
                return handleStopMiss(timestamp: timestamp)
            }
            guard let poseCandidate = associatedPoseCandidates(
                observations: bodyObservations,
                detections: [targetDetection],
                observationRegion: bodyObservationRegion
            ).max(by: { $0.associationScore < $1.associationScore }) else {
                currentDiagnosticText = "STOP · BODY POSE NOT ASSOCIATED WITH TARGET"
                return handleStopMiss(timestamp: timestamp)
            }
            let evaluation = poseCandidate.landmarks.stopEvaluation(
                personBox: targetDetection.normalizedBoundingBox,
                minimumJointConfidence: configuration.minimumBodyJointConfidence
            )
            guard let confidence = evaluation.confidence else {
                currentDiagnosticText = "STOP · " + evaluation.rejectionReason
                return handleStopMiss(timestamp: timestamp)
            }
            guard confidence >= configuration.minimumStopConfidence else {
                currentDiagnosticText = String(
                    format: "STOP · SCORE %.2f < %.2f",
                    confidence,
                    configuration.minimumStopConfidence
                )
                return handleStopMiss(timestamp: timestamp)
            }

            currentDiagnosticText = nil
            return handleValidStop(
                detection: targetDetection,
                confidence: confidence,
                timestamp: timestamp
            )
        }

        return GestureAnalysisResult(status: currentStatus, command: nil)
    }

    private func handleValidStart(
        detection: PersonDetection,
        confidence: Float,
        bodyConfidence: Float,
        leftHandConfidence: Float,
        rightHandConfidence: Float,
        timestamp: TimeInterval
    ) -> GestureAnalysisResult {
        var candidate: HoldCandidate
        if case .startCandidate(var existing) = state,
           samePersonBox(existing.boundingBox, detection.normalizedBoundingBox) {
            existing.accumulatedDuration += max(0, timestamp - existing.lastEvaluationTime)
            existing.detectionID = detection.id
            existing.boundingBox = detection.normalizedBoundingBox
            existing.lastEvaluationTime = timestamp
            existing.lastValidTime = timestamp
            existing.confidence = confidence
            candidate = existing
        } else {
            if case .startCandidate = state {
                print(
                    "Track Me candidate person changed to \(detection.id.uuidString.prefix(8)) "
                    + "(confidence \(String(format: "%.2f", confidence)))"
                )
            } else {
                print(
                    "Track Me candidate started for \(detection.id.uuidString.prefix(8)) "
                    + "(confidence \(String(format: "%.2f", confidence)))"
                )
            }
            candidate = HoldCandidate(
                detectionID: detection.id,
                boundingBox: detection.normalizedBoundingBox,
                accumulatedDuration: 0,
                lastEvaluationTime: timestamp,
                lastValidTime: timestamp,
                confidence: confidence
            )
        }

        let progress = min(candidate.accumulatedDuration / configuration.trackMeHoldDuration, 1)
        currentStatus = GestureStatus(
            kind: .trackMe,
            detectionID: detection.id,
            confidence: confidence,
            bodyConfidence: bodyConfidence,
            leftHandConfidence: leftHandConfidence,
            rightHandConfidence: rightHandConfidence,
            holdProgress: progress
        )
        guard progress >= 1 else {
            state = .startCandidate(candidate)
            return GestureAnalysisResult(status: currentStatus, command: nil)
        }

        state = .startConfirmed
        currentStatus = nil
        print(
            "Track Me confirmed after \(String(format: "%.2f", candidate.accumulatedDuration))s "
            + "(confidence \(String(format: "%.2f", confidence)))"
        )
        return GestureAnalysisResult(
            status: nil,
            command: .trackMe(detectionID: detection.id)
        )
    }

    private func handleIncompleteStart(
        detection: PersonDetection,
        bodyConfidence: Float,
        leftHandConfidence: Float?,
        rightHandConfidence: Float?,
        timestamp: TimeInterval
    ) -> GestureAnalysisResult {
        if case .startCandidate = state {
            return handleStartMiss(timestamp: timestamp)
        }
        // Surface useful body/hand evidence, but never accumulate hold time without both hands.
        currentStatus = GestureStatus(
            kind: .trackMe,
            detectionID: detection.id,
            confidence: bodyConfidence * 0.40,
            bodyConfidence: bodyConfidence,
            leftHandConfidence: leftHandConfidence,
            rightHandConfidence: rightHandConfidence,
            holdProgress: 0
        )
        return GestureAnalysisResult(status: currentStatus, command: nil)
    }

    private func handleStartMiss(timestamp: TimeInterval) -> GestureAnalysisResult {
        guard case .startCandidate(var candidate) = state else {
            currentStatus = nil
            return GestureAnalysisResult(status: nil, command: nil)
        }
        candidate.lastEvaluationTime = timestamp
        if timestamp - candidate.lastValidTime <= configuration.allowableInterruption {
            state = .startCandidate(candidate)
            currentStatus = GestureStatus(
                kind: .trackMe,
                detectionID: candidate.detectionID,
                confidence: candidate.confidence,
                bodyConfidence: candidate.confidence,
                leftHandConfidence: nil,
                rightHandConfidence: nil,
                holdProgress: min(
                    candidate.accumulatedDuration / configuration.trackMeHoldDuration,
                    1
                )
            )
            return GestureAnalysisResult(status: currentStatus, command: nil)
        }

        print("Track Me candidate reset")
        state = .idle
        currentStatus = nil
        return GestureAnalysisResult(status: nil, command: nil)
    }

    private func handleValidStop(
        detection: PersonDetection,
        confidence: Float,
        timestamp: TimeInterval
    ) -> GestureAnalysisResult {
        var candidate: HoldCandidate
        if case .stopCandidate(var existing) = state {
            existing.accumulatedDuration += max(0, timestamp - existing.lastEvaluationTime)
            existing.detectionID = detection.id
            existing.boundingBox = detection.normalizedBoundingBox
            existing.lastEvaluationTime = timestamp
            existing.lastValidTime = timestamp
            existing.confidence = confidence
            candidate = existing
        } else {
            print("Stop candidate started (confidence \(String(format: "%.2f", confidence)))")
            candidate = HoldCandidate(
                detectionID: detection.id,
                boundingBox: detection.normalizedBoundingBox,
                accumulatedDuration: 0,
                lastEvaluationTime: timestamp,
                lastValidTime: timestamp,
                confidence: confidence
            )
        }

        let progress = min(candidate.accumulatedDuration / configuration.stopHoldDuration, 1)
        currentStatus = GestureStatus(
            kind: .stop,
            detectionID: detection.id,
            confidence: confidence,
            bodyConfidence: confidence,
            leftHandConfidence: nil,
            rightHandConfidence: nil,
            holdProgress: progress
        )
        guard progress >= 1 else {
            state = .stopCandidate(candidate)
            return GestureAnalysisResult(status: currentStatus, command: nil)
        }

        state = .stopConfirmed
        currentStatus = nil
        print(
            "Stop confirmed after \(String(format: "%.2f", candidate.accumulatedDuration))s "
            + "(confidence \(String(format: "%.2f", confidence)))"
        )
        return GestureAnalysisResult(status: nil, command: .stop)
    }

    private func handleStopMiss(timestamp: TimeInterval) -> GestureAnalysisResult {
        guard case .stopCandidate(var candidate) = state else {
            currentStatus = nil
            return GestureAnalysisResult(status: nil, command: nil)
        }
        candidate.lastEvaluationTime = timestamp
        if timestamp - candidate.lastValidTime <= configuration.allowableInterruption {
            state = .stopCandidate(candidate)
            currentStatus = GestureStatus(
                kind: .stop,
                detectionID: candidate.detectionID,
                confidence: candidate.confidence,
                bodyConfidence: candidate.confidence,
                leftHandConfidence: nil,
                rightHandConfidence: nil,
                holdProgress: min(
                    candidate.accumulatedDuration / configuration.stopHoldDuration,
                    1
                )
            )
            return GestureAnalysisResult(status: currentStatus, command: nil)
        }

        print("Stop candidate reset")
        state = .idle
        currentStatus = nil
        return GestureAnalysisResult(status: nil, command: nil)
    }

    private func handleModeChange(_ mode: GestureEvaluationMode, timestamp: TimeInterval) {
        defer { lastMode = mode }
        guard mode != lastMode else { return }

        switch mode {
        case .unlocked:
            if case .stopConfirmed = state {
                state = .cooldown(until: timestamp + configuration.cooldownDuration)
            } else if case .cooldown = state {
                break
            } else {
                state = .idle
            }
        case .lockedVisible:
            if case .startConfirmed = state {
                state = .idle
            }
        case .lockedUnavailable:
            resetCandidate(reason: "target is ambiguous or missing")
        }
        currentStatus = nil
    }

    private func resetCandidate(reason: String) {
        switch state {
        case .startCandidate:
            print("Track Me candidate reset: \(reason)")
            state = .idle
        case .stopCandidate:
            print("Stop candidate reset: \(reason)")
            state = .idle
        default:
            break
        }
        currentStatus = nil
    }

    private func resetStopCandidate(reason: String) {
        if case .stopCandidate = state {
            print("Stop ignored: \(reason)")
            state = .idle
        }
        currentStatus = nil
    }

    private func samePersonBox(_ first: CGRect, _ second: CGRect) -> Bool {
        TargetAssociation.intersectionOverUnion(first, second) > 0.25
            || TargetAssociation.centersAreClose(first, second)
    }

    private func associatedPoseCandidates(
        observations: [VNHumanBodyPoseObservation],
        detections: [PersonDetection],
        observationRegion: CGRect
    ) -> [PoseCandidate] {
        observations.compactMap { observation in
            guard let landmarks = BodyLandmarks(
                observation: observation,
                observationRegion: observationRegion
            ) else { return nil }
            return detections.compactMap { detection -> PoseCandidate? in
                let box = detection.normalizedBoundingBox
                let expanded = box.insetBy(dx: -box.width * 0.12, dy: -box.height * 0.08)
                    .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
                let points = landmarks.requiredLocations
                let containedFraction = CGFloat(points.filter(expanded.contains).count)
                    / CGFloat(points.count)
                guard expanded.contains(landmarks.shoulderCenter), containedFraction >= 0.65 else {
                    return nil
                }
                let centerDistance = hypot(
                    landmarks.shoulderCenter.x - box.midX,
                    landmarks.shoulderCenter.y - (box.minY + box.height * 0.72)
                )
                let normalizedDistance = centerDistance / max(box.height, 0.01)
                let score = containedFraction * 0.70 + max(0, 1 - normalizedDistance) * 0.30
                return PoseCandidate(
                    detection: detection,
                    landmarks: landmarks,
                    associationScore: score
                )
            }.max { $0.associationScore < $1.associationScore }
        }
    }

    private func analyzeTrackMeHand(
        near wrist: CGPoint,
        torsoCenter: CGPoint,
        personBox: CGRect,
        orientedImage: CIImage
    ) -> Float? {
        let cropWidth = max(personBox.width * 0.48, 0.08)
        let cropHeight = max(personBox.height * 0.30, 0.08)
        let cropBox = CGRect(
            x: wrist.x - cropWidth / 2,
            y: wrist.y - cropHeight / 2,
            width: cropWidth,
            height: cropHeight
        ).intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        let imageRectangle = CGRect(
            x: orientedImage.extent.minX + cropBox.minX * orientedImage.extent.width,
            y: orientedImage.extent.minY + cropBox.minY * orientedImage.extent.height,
            width: cropBox.width * orientedImage.extent.width,
            height: cropBox.height * orientedImage.extent.height
        ).integral.intersection(orientedImage.extent)

        guard imageRectangle.width >= configuration.minimumHandCropPixels,
              imageRectangle.height >= configuration.minimumHandCropPixels else { return nil }

        let crop = orientedImage.cropped(to: imageRectangle)
            .transformed(by: CGAffineTransform(
                translationX: -imageRectangle.minX,
                y: -imageRectangle.minY
            ))
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1
        do {
            try VNImageRequestHandler(ciImage: crop, orientation: .up).perform([request])
        } catch {
            return nil
        }

        guard let observation = request.results?.first,
              let landmarks = HandLandmarks(
                observation: observation,
                minimumConfidence: configuration.minimumHandJointConfidence
              ) else { return nil }
        return landmarks.trackMeConfidence(
            cropBox: cropBox,
            torsoCenter: torsoCenter
        )
    }
}

nonisolated private struct PosePoint {
    let location: CGPoint
    let confidence: Float
}

nonisolated private struct BodyLandmarks {
    let leftShoulder: PosePoint
    let rightShoulder: PosePoint
    let leftElbow: PosePoint
    let rightElbow: PosePoint
    let leftWrist: PosePoint
    let rightWrist: PosePoint

    init?(
        observation: VNHumanBodyPoseObservation,
        observationRegion: CGRect
    ) {
        guard let points = try? observation.recognizedPoints(.all),
              let leftShoulder = Self.point(
                .leftShoulder, in: points, observationRegion: observationRegion
              ),
              let rightShoulder = Self.point(
                .rightShoulder, in: points, observationRegion: observationRegion
              ),
              let leftElbow = Self.point(
                .leftElbow, in: points, observationRegion: observationRegion
              ),
              let rightElbow = Self.point(
                .rightElbow, in: points, observationRegion: observationRegion
              ),
              let leftWrist = Self.point(
                .leftWrist, in: points, observationRegion: observationRegion
              ),
              let rightWrist = Self.point(
                .rightWrist, in: points, observationRegion: observationRegion
              ) else { return nil }
        self.leftShoulder = leftShoulder
        self.rightShoulder = rightShoulder
        self.leftElbow = leftElbow
        self.rightElbow = rightElbow
        self.leftWrist = leftWrist
        self.rightWrist = rightWrist
    }

    var shoulderCenter: CGPoint {
        midpoint(leftShoulder.location, rightShoulder.location)
    }

    var upperTorsoCenter: CGPoint {
        CGPoint(
            x: shoulderCenter.x,
            y: shoulderCenter.y - shoulderSpan * 0.45
        )
    }

    var shoulderSpan: CGFloat {
        distance(leftShoulder.location, rightShoulder.location)
    }

    var requiredLocations: [CGPoint] {
        [
            leftShoulder.location, rightShoulder.location,
            leftElbow.location, rightElbow.location,
            leftWrist.location, rightWrist.location
        ]
    }

    func trackMeBodyEvaluation(
        personBox: CGRect,
        minimumJointConfidence: Float
    ) -> (confidence: Float?, rejectionReason: String) {
        let namedPoints: [(String, PosePoint)] = [
            ("LEFT SHOULDER", leftShoulder),
            ("RIGHT SHOULDER", rightShoulder),
            ("LEFT ELBOW", leftElbow),
            ("RIGHT ELBOW", rightElbow),
            ("LEFT WRIST", leftWrist),
            ("RIGHT WRIST", rightWrist)
        ]
        if let weakest = namedPoints.min(by: { $0.1.confidence < $1.1.confidence }),
           weakest.1.confidence < minimumJointConfidence {
            return (
                nil,
                String(
                    format: "%@ CONF %.2f < %.2f",
                    weakest.0,
                    weakest.1.confidence,
                    minimumJointConfidence
                )
            )
        }
        guard shoulderSpan > 0.02 else {
            return (nil, "SHOULDERS NOT SEPARATED")
        }

        let leftBend = jointBendScore(
            shoulder: leftShoulder.location,
            elbow: leftElbow.location,
            wrist: leftWrist.location
        )
        let rightBend = jointBendScore(
            shoulder: rightShoulder.location,
            elbow: rightElbow.location,
            wrist: rightWrist.location
        )
        guard leftBend > 0 else {
            return (nil, "LEFT ELBOW MUST BE BENT")
        }
        guard rightBend > 0 else {
            return (nil, "RIGHT ELBOW MUST BE BENT")
        }

        let verticalTolerance = personBox.height * 0.16
        let lowerTorsoY = shoulderCenter.y - personBox.height * 0.34
        let handsNearUpperTorso = [leftWrist.location, rightWrist.location].allSatisfy {
            $0.y >= lowerTorsoY && $0.y <= shoulderCenter.y + verticalTolerance
        }
        guard handsNearUpperTorso else {
            return (nil, "KEEP BOTH WRISTS NEAR UPPER TORSO")
        }

        let centerX = shoulderCenter.x
        let leftSide = leftShoulder.location.x - centerX
        let rightSide = rightShoulder.location.x - centerX
        let handsNotCrossed = (leftWrist.location.x - centerX) * leftSide
                > -shoulderSpan * shoulderSpan * 0.10
            && (rightWrist.location.x - centerX) * rightSide
                > -shoulderSpan * shoulderSpan * 0.10
        guard handsNotCrossed else {
            return (nil, "TRACK ME ARMS MUST NOT BE CROSSED")
        }

        let symmetry = max(
            0,
            1 - abs(leftWrist.location.y - rightWrist.location.y)
                / max(personBox.height * 0.25, 0.01)
        )
        let points = namedPoints.map(\.1)
        let jointConfidence = points.reduce(Float.zero) { $0 + $1.confidence }
            / Float(points.count)
        let confidence = jointConfidence * 0.40
            + Float((leftBend + rightBend) / 2) * 0.35
            + Float(symmetry) * 0.25
        return (confidence, "BODY PASSED")
    }

    func stopEvaluation(
        personBox: CGRect,
        minimumJointConfidence: Float
    ) -> (confidence: Float?, rejectionReason: String) {
        let namedPoints: [(String, PosePoint)] = [
            ("LEFT SHOULDER", leftShoulder),
            ("RIGHT SHOULDER", rightShoulder),
            ("LEFT ELBOW", leftElbow),
            ("RIGHT ELBOW", rightElbow),
            ("LEFT WRIST", leftWrist),
            ("RIGHT WRIST", rightWrist)
        ]
        if let weakest = namedPoints.min(by: { $0.1.confidence < $1.1.confidence }),
           weakest.1.confidence < minimumJointConfidence {
            return (
                nil,
                String(
                    format: "%@ CONF %.2f < %.2f",
                    weakest.0,
                    weakest.1.confidence,
                    minimumJointConfidence
                )
            )
        }
        guard shoulderSpan > 0.02 else {
            return (nil, "SHOULDERS NOT SEPARATED")
        }

        let centerX = shoulderCenter.x
        let leftShoulderSide = leftShoulder.location.x - centerX
        let rightShoulderSide = rightShoulder.location.x - centerX
        let leftCross = -(leftWrist.location.x - centerX) * leftShoulderSide
            / (shoulderSpan * shoulderSpan)
        let rightCross = -(rightWrist.location.x - centerX) * rightShoulderSide
            / (shoulderSpan * shoulderSpan)
        guard leftCross > 0.02 else {
            return (nil, "LEFT WRIST NOT CROSSED FAR ENOUGH")
        }
        guard rightCross > 0.02 else {
            return (nil, "RIGHT WRIST NOT CROSSED FAR ENOUGH")
        }

        let lowerTorsoY = shoulderCenter.y - personBox.height * 0.40
        let wristsInTorso = [leftWrist.location, rightWrist.location].allSatisfy {
            $0.y >= lowerTorsoY && $0.y <= shoulderCenter.y + personBox.height * 0.10
        }
        guard wristsInTorso else {
            return (nil, "KEEP CROSSED WRISTS IN FRONT OF TORSO")
        }

        let forearmsIntersect = segmentsIntersect(
            leftElbow.location,
            leftWrist.location,
            rightElbow.location,
            rightWrist.location
        )
        let crossingStrength = min(1, max(0, (leftCross + rightCross) / 0.10))
        let heightSimilarity = max(
            0,
            1 - abs(leftWrist.location.y - rightWrist.location.y)
                / max(personBox.height * 0.30, 0.01)
        )
        let points = namedPoints.map(\.1)
        let jointConfidence = points.reduce(Float.zero) { $0 + $1.confidence }
            / Float(points.count)
        let confidence = jointConfidence * 0.35
            + Float(crossingStrength) * 0.35
            + Float(heightSimilarity) * 0.15
            + (forearmsIntersect ? 0.15 : 0.05)
        return (confidence, "STOP POSE PASSED")
    }

    private static func point(
        _ name: VNHumanBodyPoseObservation.JointName,
        in points: [VNHumanBodyPoseObservation.JointName: VNRecognizedPoint],
        observationRegion: CGRect
    ) -> PosePoint? {
        guard let point = points[name] else { return nil }
        return PosePoint(
            location: CGPoint(
                x: observationRegion.minX + point.location.x * observationRegion.width,
                y: observationRegion.minY + point.location.y * observationRegion.height
            ),
            confidence: point.confidence
        )
    }
}

nonisolated private struct HandLandmarks {
    let wrist: PosePoint
    let thumbCMC: PosePoint
    let thumbMP: PosePoint
    let thumbIP: PosePoint
    let thumbTip: PosePoint
    let fingers: [(mcp: PosePoint, pip: PosePoint, tip: PosePoint)]

    init?(observation: VNHumanHandPoseObservation, minimumConfidence: Float) {
        guard let points = try? observation.recognizedPoints(.all),
              let wrist = Self.point(.wrist, in: points),
              let thumbCMC = Self.point(.thumbCMC, in: points),
              let thumbMP = Self.point(.thumbMP, in: points),
              let thumbIP = Self.point(.thumbIP, in: points),
              let thumbTip = Self.point(.thumbTip, in: points) else { return nil }

        let fingerNames: [(
            VNHumanHandPoseObservation.JointName,
            VNHumanHandPoseObservation.JointName,
            VNHumanHandPoseObservation.JointName
        )] = [
            (.indexMCP, .indexPIP, .indexTip),
            (.middleMCP, .middlePIP, .middleTip),
            (.ringMCP, .ringPIP, .ringTip),
            (.littleMCP, .littlePIP, .littleTip)
        ]
        let fingers = fingerNames.compactMap { mcp, pip, tip -> (
            mcp: PosePoint,
            pip: PosePoint,
            tip: PosePoint
        )? in
            guard let mcpPoint = Self.point(mcp, in: points),
                  let pipPoint = Self.point(pip, in: points),
                  let tipPoint = Self.point(tip, in: points) else { return nil }
            return (mcpPoint, pipPoint, tipPoint)
        }
        let allPoints = [wrist, thumbCMC, thumbMP, thumbIP, thumbTip]
            + fingers.flatMap { [$0.mcp, $0.pip, $0.tip] }
        guard fingers.count == 4,
              allPoints.allSatisfy({ $0.confidence >= minimumConfidence }) else { return nil }

        self.wrist = wrist
        self.thumbCMC = thumbCMC
        self.thumbMP = thumbMP
        self.thumbIP = thumbIP
        self.thumbTip = thumbTip
        self.fingers = fingers
    }

    func trackMeConfidence(cropBox: CGRect, torsoCenter: CGPoint) -> Float? {
        let thumbPath = distance(thumbCMC.location, thumbMP.location)
            + distance(thumbMP.location, thumbIP.location)
            + distance(thumbIP.location, thumbTip.location)
        let thumbReach = distance(thumbCMC.location, thumbTip.location)
        let thumbStraightness = thumbReach / max(thumbPath, 0.001)
        let thumbLength = distance(wrist.location, thumbTip.location)
        guard thumbStraightness >= 0.62, thumbLength >= 0.24 else { return nil }

        let foldedCount = fingers.filter { finger in
            let tipToWrist = distance(finger.tip.location, wrist.location)
            let mcpToWrist = distance(finger.mcp.location, wrist.location)
            let tipToMCP = distance(finger.tip.location, finger.mcp.location)
            return tipToWrist <= mcpToWrist * 1.20
                || tipToMCP <= mcpToWrist * 0.78
        }.count
        guard foldedCount >= 3 else { return nil }

        let fullThumbBase = mapToImage(thumbCMC.location, cropBox: cropBox)
        let fullThumbTip = mapToImage(thumbTip.location, cropBox: cropBox)
        let thumbDirection = normalizedVector(from: fullThumbBase, to: fullThumbTip)
        let torsoDirection = normalizedVector(from: fullThumbBase, to: torsoCenter)
        let inwardDot = thumbDirection.dx * torsoDirection.dx
            + thumbDirection.dy * torsoDirection.dy
        guard inwardDot >= 0.20,
              distance(fullThumbTip, torsoCenter)
                <= distance(fullThumbBase, torsoCenter) + cropBox.width * 0.10 else { return nil }

        let landmarkConfidence = ([wrist, thumbCMC, thumbMP, thumbIP, thumbTip]
            + fingers.flatMap { [$0.mcp, $0.pip, $0.tip] })
            .reduce(Float.zero) { $0 + $1.confidence } / 17
        let foldedScore = Float(foldedCount) / 4
        let directionScore = Float(min(max((inwardDot - 0.20) / 0.80, 0), 1))
        return landmarkConfidence * 0.35
            + Float(thumbStraightness) * 0.25
            + foldedScore * 0.25
            + directionScore * 0.15
    }

    private static func point(
        _ name: VNHumanHandPoseObservation.JointName,
        in points: [VNHumanHandPoseObservation.JointName: VNRecognizedPoint]
    ) -> PosePoint? {
        guard let point = points[name] else { return nil }
        return PosePoint(location: point.location, confidence: point.confidence)
    }
}

nonisolated private func midpoint(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
    CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
}

nonisolated private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
    hypot(first.x - second.x, first.y - second.y)
}

nonisolated private func jointBendScore(
    shoulder: CGPoint,
    elbow: CGPoint,
    wrist: CGPoint
) -> CGFloat {
    let first = CGVector(dx: shoulder.x - elbow.x, dy: shoulder.y - elbow.y)
    let second = CGVector(dx: wrist.x - elbow.x, dy: wrist.y - elbow.y)
    let denominator = max(hypot(first.dx, first.dy) * hypot(second.dx, second.dy), 0.0001)
    let cosine = min(max((first.dx * second.dx + first.dy * second.dy) / denominator, -1), 1)
    let angle = acos(cosine) * 180 / .pi
    // Permit fists at belly or chest height while still rejecting nearly straight arms.
    guard angle >= 20, angle <= 165 else { return 0 }
    return max(0, 1 - abs(angle - 90) / 70)
}

nonisolated private func mapToImage(_ point: CGPoint, cropBox: CGRect) -> CGPoint {
    CGPoint(
        x: cropBox.minX + point.x * cropBox.width,
        y: cropBox.minY + point.y * cropBox.height
    )
}

nonisolated private func normalizedVector(from start: CGPoint, to end: CGPoint) -> CGVector {
    let length = max(distance(start, end), 0.0001)
    return CGVector(dx: (end.x - start.x) / length, dy: (end.y - start.y) / length)
}

nonisolated private func segmentsIntersect(
    _ firstStart: CGPoint,
    _ firstEnd: CGPoint,
    _ secondStart: CGPoint,
    _ secondEnd: CGPoint
) -> Bool {
    func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
    }
    let firstSide = cross(firstStart, firstEnd, secondStart)
        * cross(firstStart, firstEnd, secondEnd)
    let secondSide = cross(secondStart, secondEnd, firstStart)
        * cross(secondStart, secondEnd, firstEnd)
    return firstSide <= 0 && secondSide <= 0
}
